# Core 指针模型：图上的三个验证 pass

指针安全建立在 HDFG 上，不引入借用检查器和生命周期标注。地址语义是条目标识加偏移，见 `docs/academic/cache-semantics.md` 规则 6。层定义见 `docs/maintainer/design/materialization-space.md`，经典映射见 `docs/maintainer/design/region-model.md`。

本文件描述当前实现行为。实现与文档冲突时以源码为准。实现核对的详细记录见 `docs/superpowers/implementation/2026-09-20-pointer-model-audit.md`。

## 问题与方案

C 风格原始指针表达力强，但没有安全保障。Rust 用借用检查器换取安全，代价是学习成本和表达力限制。Core 的目标是保留 C 风格指针的自由，同时不要求用户写安全标注。

编译器维护完整的 HDFG。图中每个值的产生节点记录来源（provenance），每个解引用是 DEREF 或 STORE_PTR 节点。三个 pass 在图上验证指针安全，与类型系统解耦：

| Pass | 文件 | 功能 |
|---|---|---|
| PointerAnalysis | `ptr_analysis.cr` | 建立 points-to 关系，做约束求解，跟踪 alloc content |
| RegionCheck | `region_check.cr` | 检查内存是否离开分配区域。过期解引用、返回值离开区域、存储离开区域三种情况已实现；参数离开区域未实现 |
| ProvenanceVerify | `provenance_verify.cr` | 检查 DEREF 和 STORE_PTR 是否越界，静态证明或插入运行时检查 |

## 术语

| 术语 | 含义 |
|---|---|
| provenance | 指针的来源，即它出自哪个分配（ALLOC、ALLOC_STRUCT、ALLOC_ARRAY 等），沿 provenance 边追踪 |
| points-to（pts） | 指针可能指向哪些分配块，用动态宽度位集表示 |
| alloc content | 存入某个分配块的值集合，记为 `g_alloc_pts`，是 Store 和 Load 规则的中介 |
| direct flow | 值沿 def-use 关系直接传递 |
| pointer-induced flow | 值经 STORE_PTR 或 DEREF 间接传递，需要 pts 才能追踪 |
| 区域（SG region） | 以图为依据的执行域，包括函数、loop、for、flow 和 unsafe，见 `execution-model.md` |
| 图边界 | 编译器没有 provenance 的输入，包括外部地址、FFI 返回值和 inline asm，位于 `unsafe` 内 |

## 输入形状

开发者可见的语法和保证见 `docs/developer/syntax.md` 的指针一节。这里只列 pass 的输入形状：

```core
p := &arr[0]          // REF 或 ADDR_INDEX，产生 self-pointer
p = p + n             // 偏移，不影响 pts；偏移写入 g_offsets
x := *p               // DEREF，读取 alloc content
*p = v                // STORE_PTR，把 v 的 pts 写入 alloc content
q := p cast *int     // 类型转换，pts 不变，视图变化

unsafe:
    mmio := 0x7fff0000 cast *int   // 图边界输入：整数转指针，asp=1
    *mmio = 42
```

类型双关（例如 `*(dex*)&i`）不需要 `unsafe`。地址语义是条目标识加偏移，经典映射是字节序列加宽度和边界。provenance、offset 和 alloc_size 与类型无关。`cast` 保留值流，provenance 边不断。检查内容是边界和宽度。

## Pass 1：PointerAnalysis

算法是在数据流图上运行**过程内** Andersen 风格约束求解，参考 SVF（Sui 和 Xue，CC 2016）；`IR_CALL` 结果保守置空，过程间函数摘要尚未实现。

| 规则 | 触发 | 动作 |
|---|---|---|
| Addr | ALLOC、REF、ADDR_INDEX | 产生 self-pointer，把分配块自身放入 pts |
| Copy | LOAD、STORE 沿 def-use | 沿 def-use 关系传播 pts |
| Store | STORE_PTR | 对每个 alloc 属于 ptr 的 pts，把 val 的 pts 并入 `g_alloc_pts[alloc]` |
| Load | DEREF | dest 的 pts 并入每个 alloc 的 `g_alloc_pts[alloc]` |
| Call | 调用 | 结果置空，参数不传播（函数摘要未实现） |

实现要点：

- pts 是**动态宽度位集**：分配预扫描决定每行的 64 位 lane 数（`g_pts_words`），`g_pts`/`g_alloc_pts` 按集合数扩容，不再有 64 个分配的硬上限。访问统一走 `pa_pts_has`/`pa_pts_add`/`pa_pts_empty`，不暴露位图布局。`grow_pa_alloc_nodes` 动态扩容。
- alloc content 跟踪使用 `g_alloc_pts[alloc_id]` 记录存入该分配块的值集合。DEREF 读取它，这是 pointer-induced flow 的实现形式，不在图上物理加边。
- `pa_in_unsafe` 使 `unsafe` 域内的指针不参与正常约束。

分析按函数独立进行；`IR_CALL` 结果保守置空，函数摘要尚未实现（TODO `#2026-09-17-20(b)`）。跨函数逃逸因此仍是已知缺口。

## Pass 2：RegionCheck

功能是检查内存是否离开分配区域。子图 A 分配的内存不能离开 A 的有效范围。判定基准是 SG 区域区间，字段为 `enter`、`nstart`、`ncount`、`exit`，见 `dataflow.cr` 的 SG 表。

四种判定：

1. 过期 DEREF（`IR_DEREF`），错误码 `B011`（`EC_B_LIFETIME`）。
2. 返回值离开区域（`IR_RETURN`，`rc_return_escape`），错误码 `B010`（`EC_B_ESCAPE`）。错误信息见 `errors.md:245`，例子是 `return &x`。
3. 存储离开区域（`IR_STORE_PTR`，`rc_store_escape`），错误码 `B011`。除“值在 store 时已死”外，还比较**目标寿命**：值的区域先于目标区域退出 ⇒ 目标将来持有悬垂指针，报 `destination outlives the stored allocation`。目标寿命取 pts；无 pts 的 `&slot`/标量槽位沿最后写入与声明区追踪；条件/PHI 定义取所有可能分支的保守最大寿命。全局/参数槽位无本地 `IR_ALLOC` 时按程序/函数级寿命。
4. 参数离开区域：把分配指针作为参数传给外部。该检查尚未实现；需要函数摘要，当前 `IR_CALL` 的 pts 为空。

区域活性语义：

- 区间是半开区间 `[OFF_SG_NSTART, OFF_SG_EXIT)`。`OFF_SG_EXIT` 由 `sg_pop()` 写成当时的 `g_df_node_count`，即区域关闭后第一个节点的下标，见 `dataflow.cr:78-82`。因此使用点在区域外等价于 `ni >= EXIT`。
- 只有出口归还内存的区域才是离开点。`SG_LOOP`、`SG_FOR` 和 `SG_UNSAFE` 在出口发射 `IR_ARENA_RESET`，后端 `src/arch/x86_64/instr.cr` 确实调用 `arena_new` 和 `arena_reset`。`SG_IF` 只做 `sg_push` 和 `sg_pop`，不建 arena，见 `ir_gen.cr:2414` 和 `ir_gen.cr:2437`。`SG_FUNC` 的 arena 在函数出口才重置，返回给调用者时仍然有效。分配点在 `if` 内时，沿父区域向上查找到真正归还内存的区域。
- 类型门是 `TYP_PTR` 和 `TYP_REF` 的并集。当前实际生效的是 REF 一侧，因为 `&局部` 一律判为 REF，而 `&局部 as *T` 本身会触发 TF01。并集保留，PTR 一侧对 `alloc()` 和 FFI 派生值仍然有效。
- 重赋值清除：pts 是流不敏感并集。普通使用在 `[EXIT, ni)` 内检查重赋值；条件分支（`SG_IF`）或循环内的安全写入**不清除**，避免“条件写可能不执行”的假阴性。区域内 return 取分配点到 return 之间的**最后一次**写入，并按使用点判定写入值是否逃逸；标量指针的 `SG_IF`/PHI 定义改走全定义保守检查。已知不完整：当值是跨调用结果时 pts 为空，会被当作明确不离开区域而清除；循环内先写死指针、再写活指针后循环外使用仍保守误报（缺支配关系）。原因是 pts 流不敏感 / 非路径敏感。

## Pass 3：ProvenanceVerify

功能是检查 DEREF 和 STORE_PTR 是否越界，比较偏移加访问宽度与分配大小。

对每个 DEREF 和 STORE_PTR，按函数执行 `provenance_verify_func`：

1. 从指针变量 s1 取得 pts 目标集合，经 `g_offsets` 取得累计偏移。
2. 对每个目标 alloc，用 `get_alloc_size` 取得编译期已知大小。偏移可以静态确定时，检查 `0 <= off` 且 `off + width <= alloc_size`。通过则编译期证明；越界则报编译错误 `EC_TU_DEREF`。
3. 大小未知或偏移动态时，插入运行时检查。编码分配基址、大小和宽度，运行 `sub`、`cmp`、`jae`、`ud2` 序列，失败时 panic。多目标时按运行时目标定位实际基址，不使用页内偏移近似。

宽度取自 `tk`，即类型码。宽度小于等于 0 时默认 8。

## unsafe 边界与 ALLOC_AT

`unsafe` 是编译器无法追踪 provenance 时唯一允许的方式，发生在图边界：

| 场景 | 原因 |
|---|---|
| 外部硬件地址 | 直接写 `0x7fff0000 cast *int`，没有 ALLOC。整数转指针带 `asp=1`，解引用必须在 `unsafe` 域内，由 pa 和 pv 的 `unsafe` 感知处理 |
| FFI 返回值 | 外部指针没有 Core provenance |
| inline asm | 输出指针没有来源 |

ALLOC_AT 是声明式放置，2026-08-13 定稿。`alloc_at(addr, size, align)` 是声明式进图节点，用地址、大小和对齐声明固定地址区域。它和 ALLOC 走同一路径获得 provenance，之后在全图范围内追踪，并按同一流程验证：

```core
mmio := alloc_at(0x7fff0000, 4096, align(4096))  // MMIO 页
*mmio = 42              // safe 代码即可，边界内照常验证
p := mmio + 4096        // 越界，编译错误或运行时检查
```

声明是唯一可信来源。它与 2026-08-10 的结论不冲突：`0x` 字面量仍然只作为 `unsafe` 的外部输入。

## 字节权限层

字节权限层仍在设计阶段。经典映射在字节序列、宽度和边界之上增加每字节权限，来源是 CompCert v2 投影和 `cache-semantics` 规则 7：

```text
Freeable > Writable > Readable > Nonempty > Empty
```

权限和 provenance、offset、size 一样是图数据。验证器读取图数据即可获得每字节的控制。实现状态见 `region-model.md` 第 5 节，当前为设计阶段。

## 与其他语言的对比

| | C | Rust | Zig | Core |
|---|---|---|---|---|
| 指针算术 | 允许 | `*T` 不行 | `[*]T` 可以 | 原始指针允许 |
| 越界检查 | 无 | 边界检查 | 边界检查 | 编译期证明或运行时检查 |
| 生命周期验证 | 无 | 借用检查器 | 编译期 | RegionCheck。过期、返回值、存储三种情况已实现；参数情况未实现 |
| 别名分析 | 无 | 独占和共享引用 | 编译期 | PointerAnalysis，Andersen 风格 |
| 用户标注 | 无 | 生命周期 | 有时 | 无 |
| unsafe | 整个语言 | 关键字 | 关键字 | 关键字，表示图边界 |

## 参考

- SVF（Sui 和 Xue，CC 2016）：Andersen 包含约束和过程间摘要。PointerAnalysis 直接参考。
- Fridtjof Siebert（2006）：全程序上下文敏感和流敏感指针分析检测区域过期。RegionCheck 的概念来源。
- Prov-GC（Banerjee 2020）：provenance 追踪。ProvenanceVerify 的概念来源。
- 存储语义：`docs/academic/cache-semantics.md` 规则 6，地址等于映射。
- 经典映射：`docs/maintainer/design/region-model.md`。
- 实现核对记录：`docs/superpowers/implementation/2026-09-20-pointer-model-audit.md`。
