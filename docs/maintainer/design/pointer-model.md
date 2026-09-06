# Core 指针模型:图上的三点验证 pass

> 定位:受众 = 维护者(改/验证三点 pass 的人);状态 = active;真源 = 源码(src/compiler/ptr_analysis.cr、region_check.cr、provenance_verify.cr)——本文描述的是已实现行为,文档与源码冲突时以源码为准,并请更新本文。
> 语义定位:指针安全建立在 HDFG 上,不引入 borrow checker/生命周期标注。存储语义本体(条目标识 + 偏移)见 docs/academic/cache-semantics.md 条款 6;经典映射见 docs/maintainer/design/region-model.md。
> 本文 2026-09 重写:三 pass 描述与实现对齐(Andersen 约束求解、逃逸三点检查、双路径边界验证)。

---

## 一、问题与方案

C 风格裸指针表达力强但无保障;Rust 用 borrow checker 换安全,代价是学习曲线与表达力。Core 的目标:**指针和 C 一样自由,安全保障不依赖用户标注**——编译器维护完整 HDFG,图中每个值的出生节点记录来源(provenance),每个解引用是 DEREF/STORE_PTR 节点;三点 pass 在图上验证,与类型系统解耦:

| Pass | 文件 | 功能 |
|---|---|---|
| PointerAnalysis | ptr_analysis.cr | 建 points-to(约束求解)→ alloc content 跟踪 |
| RegionCheck | region_check.cr | 逃逸检查(传参/返回/存储三点),按 region(SG)区间 |
| ProvenanceVerify | provenance_verify.cr | DEREF/STORE_PTR 越界检查(静态证明或运行时检查) |

## 二、术语

| 术语 | 含义 |
|---|---|
| provenance | 指针的来源——出自哪个分配(ALLOC/ALLOC_STRUCT/ALLOC_ARRAY/…),经 provenance 边追踪 |
| points-to(pts) | 指针可能指向哪些分配块(位图表示) |
| alloc content | 存进某分配块的值集合(g_alloc_pts)——Store/Load 规则的中介 |
| direct flow | 值沿 def-use 链直接传递 |
| pointer-induced flow | 经 STORE_PTR/DEREF 间接传递——需要 pts 才能追踪 |
| 子图/SG region | 图锚定的执行域(函数/loop/for/flow/unsafe,见 execution-model.md §二) |
| 图边界 | 编译器无 provenance 的入口(外部地址、FFI 返回、inline asm)→ unsafe |

## 三、用户可见语法(开发者的形状)

开发者视角的语法与保证见 docs/developer/syntax.md 指针节;此处只列 pass 输入形状:

```core
p := &arr[0];          // REF/ADDR_INDEX → self-pointer
p = p + n;             // 偏移(不影响 pts;偏移入 g_offsets)
x := *p;               // DEREF → 读 alloc content
*p = v;                // STORE_PTR → v 的 pts 写入 alloc content
q := cast<int*>(p);    // 类型转换(pts 不变,视图变化)

unsafe {
    mmio := 0x7fff0000 as *int;   // 图边界入口:整数转指针,asp=1
    *mmio = 42;
}
```

类型双关(`*(dex*)&i`)不需要 unsafe——存储语义是条目标识 + 偏移(cache-semantics 条款 6),经典映射是"字节序列 + 宽度 + 边界",provenance/offset/alloc_size 与类型无关;cast 保留值流,provenance 边不断。判据 = 边界 + 宽度。

## 四、Pass 1:PointerAnalysis(ptr_analysis.cr)

**算法**:interprocedural Andersen-style 约束求解(参考 SVF, Sui & Xue CC 2016——inclusion constraints + interprocedural function summaries),在数据流图上跑。规则(源码注释):

| 规则 | 触发 | 动作 |
|---|---|---|
| Addr | ALLOC/REF/ADDR_INDEX | 产生 self-pointer(alloc 自身入 pts) |
| Copy | LOAD/STORE 沿 def-use | 沿 def-use 链传播 pts |
| Store | STORE_PTR | ∀alloc ∈ pts(ptr):val 的 pts 并入 g_alloc_pts[alloc](alloc content) |
| Load | DEREF | dest 的 pts ∪= g_alloc_pts[alloc],∀alloc ∈ pts(ptr) |
| Call | 调用 | 函数摘要传播 + 参数保守处理(interprocedural) |

实现要点:
- pts 为**位图**(pa_set_bit 等,grow_pa_alloc_nodes 动态扩容)——非逐对象列表
- **alloc content 跟踪**:g_alloc_pts[alloc_id] 记录"存进该分配块的值集合",DEREF 读它——pointer-induced flow 的实现形态(不是图上物理加边,是位图数据)
- unsafe 感知:pa_in_unsafe 使 unsafe 域内指针不参与正常约束

按子图独立分析 + 函数摘要跨子图——不需要全程序统一求解。

## 五、Pass 2:RegionCheck(region_check.cr)

**功能**:逃逸检查——子图 A 分配的内存不能逃逸出 A 的存活域。判定基准 = SG region 区间(enter/nstart/ncount/exit,dataflow.cr 的 sg 表)。

三点逃逸检查(rc_pts_has_escaped / rc_return_escape / rc_store_escape):

1. **传参逃逸**:把 alloc 的指针作参数传给外部 → 检查 alloc 所在 SG 的 exit 是否覆盖使用点(pts 中任一 alloc 逃逸即报)
2. **返回逃逸**:返回 alloc 指针——函数级(SG_FUNC)alloc 允许返回(与调用者共享区间语义);函数内子 region 的 alloc 返回 → 逃逸(除非该 region 存活域覆盖调用者)
3. **存储逃逸**:把 alloc 指针存入外部可达位置(store)→ 同样按 SG 区间判定

判定的图活性语义:引用者使用区间 ⊆ 被引用区域存活区间(outlives)——2026-08-13 修订从"一刀切禁止"放宽为顺序判定,RegionCheck 的 SG exit 比较就是这个判定的实现。

## 六、Pass 3:ProvenanceVerify(provenance_verify.cr)

**功能**:DEREF/STORE_PTR 越界检查——偏移 + 访问宽度 vs 分配大小。

处理(per DEREF/STORE_PTR,per 函数 provenance_verify_func):
1. 从 s1(指针变量)取 pts 目标集合;经 g_offsets 取累计偏移
2. 对每个目标 alloc:get_alloc_size(编译期已知大小)且偏移可静态定 → `0 <= off && off + width <= alloc_size`?通过则**编译期证明**;越界 → 编译错误(EC_TU_DEREF 错误码)
3. 未知大小或动态偏移 → **运行时检查**:编码 allocation base/size/width,`sub+cmp+jae+ud2` 序列(panic);多 pts 目标时按目标定位实际 base(runtime_targets),不再用页内偏移近似(2026-08-16 落地)

宽度取 tk(类型码→宽度,宽 ≤ 0 时默认 8)。

## 七、unsafe 边界与 ALLOC_AT

`unsafe` = 编译器无法追踪 provenance 的唯一退路,发生在**图边界**:

| 场景 | 原因 |
|---|---|
| 外部硬件地址 | 裸 `0x7fff0000 as *int` 无 ALLOC;整数转指针带 asp=1——解引需在 unsafe 域内(pa/pv 的 unsafe 感知) |
| FFI 返回值 | 外部指针无 Core provenance |
| inline asm | 输出指针无来源 |

**ALLOC_AT(声明式放置,2026-08-13 定稿)**:`alloc_at(addr, size, align)` 是声明式进图节点——固定地址区域以(地址+大小+对齐)声明,与 ALLOC 同路径获得 provenance,之后全图追踪、照常验证:

```core
mmio := alloc_at(0x7fff0000, 4096, align(4096));  // MMIO 页
*mmio = 42;              // safe 代码即可,边界内照常验证
p := mmio + 4096;        // 越界 → 编译错误或运行时 check
```

声明是唯一信任点(等价受控图边界入口);与 2026-08-10 定论不冲突(0x 字面量仍只作 unsafe 外部入口)。

## 八、字节权限层(设计态)

经典映射在"字节序列 + 宽度 + 边界"之上补充每字节权限(CompCert v2 投影,cache-semantics 条款 7):

Freeable > Writable > Readable > Nonempty > Empty

权限与 provenance/offset/size 一样是图数据(验证器消费图即获得每字节控制)。实现状态:设计态(region-model.md §5)。

## 九、与其它语言的对比

| | C | Rust | Zig | Core |
|--|---|------|-----|------|
| 指针算术 | 随便 | *T 不行 | [*]T 可以 | 裸指针随便 |
| 越界检查 | 无 | bounds check | bounds check | 编译期证明或运行时 check |
| 生命周期验证 | 无 | borrow checker | 编译时 | RegionCheck(逃逸三点) |
| 别名分析 | 无 | 独占/共享引用 | 编译时 | PointerAnalysis(Andersen) |
| 用户需标注 | 无 | lifetimes | 有时 | 无 |
| unsafe | 整个语言 | 关键字 | 关键字 | 关键字(图边界) |

## 十、参考与谱系

- SVF(Sui & Xue, CC 2016):Andersen inclusion + interprocedural summaries——PointerAnalysis 直接参考
- Fridtjof Siebert(2006):全程序 context/flow-sensitive 指针分析检区域悬垂——RegionCheck 概念来源
- Prov-GC(Banerjee 2020):provenance 追踪——ProvenanceVerify 概念来源
- 存储语义:docs/academic/cache-semantics.md(条款 6 地址 = 映射)
- 经典映射:docs/maintainer/design/region-model.md
