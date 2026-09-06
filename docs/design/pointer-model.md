# Core 指针模型

> 定位：受众 = 维护者；状态 = active

## 问题

C 风格的裸指针表达能力极强，但完全没有安全保障。Rust 用 borrow checker 和生命周期标注来保障安全，代价是陡峭的学习曲线和表达力的损失。

Core 的目标：**指针和 C 一样自由，安全保障不依赖用户标注。**

## 方案

Core 的编译器内部维护一张完整的HDFG（dataflow graph）。图中每个值的出生节点记录了它的来源（provenance），每个解引用操作记录在 DEREF 节点中。编译器通过分析图上的路径自动验证指针安全，不需要类型系统层面的 borrow 规则。

验证逻辑由三个编译期 pass 完成，全部是图上的稀疏分析：

| Pass | 功能 | 输入 | 输出 |
|------|------|------|------|
| PointerAnalysis | 建 points-to 关系 | HDFG | pointer-induced flow 的边 |
| RegionCheck | 子图存活检查 | HDFG + 子图边界 | 每个 DEREF 的存活判定 |
| ProvenanceVerify | 越界检查 | HDFG + points-to | 每个 DEREF 的偏移判定 |

## 术语

| 术语 | 含义 |
|------|------|
| provenance | 指针的来源——它来自哪个分配操作（ALLOC、ALLOC_STRUCT 等） |
| points-to | 指针可能指向哪些内存位置 |
| direct flow | 值通过赋值直接传递：`a = b` |
| pointer-induced flow | 值通过指针间接传递：`*p = x`，需要 points-to 才能追踪 |
| 子图 | HDFG上与一个执行上下文（函数、loop、flow）对应的连通子图 |
| DEREF 节点 | 表示一次指针解引用操作的图节点 |
| 图边界 | 编译器无法追踪 provenance 的入口点（外部地址、FFI 返回值等） |

## 地址 = 映射（2026-08-15 语义定稿）

**语义本体**：`&x` = (条目标识, 偏移)——条目由产生它的图节点定义（值 = 配方），偏移是条目内的位移（数组元素、结构体字段）。

**经典映射**：字节地址。编译器和后端把条目标识投影为经典机器上的基地址；在非经典范式（如量子存储）上投影为别的物理表示。

字节地址从来不是语义对象——它只是"缓存"（`docs/design/cache-semantics.md` 七条）在经典硬件上的映射实例。本文件三个 pass（PointerAnalysis / RegionCheck / ProvenanceVerify）的判定全部在条目标识 + 偏移域上进行，与物理地址表示无关。

## 用户可见的语法

```core
p := &arr[0];      // 取地址
p = p + n;         // 偏移
x := *p;           // 解引用
p = p - 1;         // 往回偏移
casted := cast<int*>(p);  // 类型转换

unsafe {
    mmio := 0x7fff0000 as *int;  // 外部地址，编译器没有 provenance
    *mmio = 42;
}
```

用户不需要学习 borrow lifetime、RawRef、Arena tag 等概念，不需要 `@ptrFromInt` 之类的内置函数。指针的操作和 C 一样自由。动态类型（`dyn`）作为类型标注时，指针的行为也由图自动管理。

## Pass 1: PointerAnalysis

### 解决的问题

HDFG天然记录了 direct flow。`a = b`、`a = &x`、`a = a + n` 这些操作在图上有直接的边。但 pointer-induced flow（`*p = x`）需要通过 points-to 关系才能追踪：编译器必须先知道 `*p` 可能指向哪些分配块，才能建立 p→target 的边。

### 算法

PointerAnalysis 遍历HDFG，收集每个指针变量的 points-to 信息。分析是流敏感的，按图上的拓扑序进行。

```
输入: HDFG
处理:
  1. 对每个 ADDR 节点 (p = &x):
     record points-to(p) ∪= {x}

  2. 对每个 COPY 节点 (q = p):
     record points-to(q) ∪= points-to(p)

  3. 对每个 ADD/SUB 节点 (p = p + n):
     points-to(p) 不变（偏移不影响 points-to 集）
     record offset(p) += n

  4. 对每个 STORE 节点 (*p = x):
     对每个 t ∈ points-to(p):
       record store(t, x)
       在图上添加一条从 x 到 t 的边（pointer-induced flow）

  5. 对每个 LOAD 节点 (x = *p):
     对每个 t ∈ points-to(p):
       record x ∈ points-to(t 的成员)
       在图上添加一条从 t 到 x 的边

  6. 对每个 CALL 节点 (f(args)):
     保守处理：假设函数可能修改任何通过参数可达的内存
     （内联后可精确化）

输出: 补充了 pointer-induced flow 边的HDFG
```

### 复杂度

O(N × P)，其中 N 为指针变量数，P 为 points-to 集平均大小。Core 的图是 flat array，可以按子图独立分析，不需要全程序统一求解。

## Pass 2: RegionCheck

### 解决的问题

跨子图引用：子图 A 分配的内存被子图 B 引用。当子图 A 退出后，B 中的指针变成悬垂指针。

**2026-08-13 修订**：跨区域引用不再一刀切禁止——安全当且仅当**被引用区域的存活区间 ⊇ 引用的使用区间**（outlives 顺序判定，Cyclone 区域子类型的图形式）。RegionCheck 的 `cur_seq < exit_seq` 判定就是这个顺序判定。见 `docs/design/region-model.md` §3.3(逃逸规则 4)。

### 算法

RegionCheck 为每个子图分配递增的序号（由控制流决定，不是运行时值）。每个 ALLOC 节点标记它所属的子图 ID。每个 DEREF 节点检查目标子图是否存活。

```
输入: 带有子图边界标记的HDFG

处理:
  为每个子图分配范围 [enter_seq, exit_seq]

  对每个 DEREF 节点:
    1. 从 DEREF 沿指针来源倒推 ALLOC 节点
    2. 获取 ALLOC 所在的子图 ID
    3. 获取该子图的 exit_seq
    4. 获取当前指令的序号 cur_seq

    if cur_seq < exit_seq:
      → 目标子图存活，安全
    else:
      → 目标子图已退出，编译错误
```

### 子图确定

| 结构 | 子图范围 |
|------|---------|
| 函数 | [函数入口, 函数返回] |
| loop | [loop 开始, loop 退出] |
| for | [for 开始, for 结束] |
| flow/go | [创建, 回收] |

子图的入口和出口节点在 IR 生成时已存在（df_begin_func / df_end_func 等）。RegionCheck 只是消费这些信息。

## Pass 3: ProvenanceVerify

### 解决的问题

指针算术后的解引用是否越界。`p = &arr[0]; p = p + 100; *p`——编译器需要知道 `arr` 的长度是否大于 100。

### 算法

ProvenanceVerify 从每个 DEREF/STORE_PTR 节点出发，沿指针来源倒推，找到最初的 ALLOC 节点，比较偏移量与访问宽度。

```
输入: 带有 points-to 信息的完整HDFG

处理:
  对每个 DEREF/STORE_PTR 节点:
    1. 沿 pointer 的 def 链倒推到 ALLOC 节点
       (经过 COPY、ADD、SUB、LOAD 等中间节点)

    2. 累计偏移量：
       - ADD n:    offset += n
       - SUB n:    offset -= n
       - LOAD:     偏移重置（解引用一个指针，取其指向的成员的偏移）
       - COPY:     偏移不变，沿来源继续

    3. 获取 ALLOC 节点的大小 alloc_size 和本次访问宽度 width

    if alloc_size 是编译期已知的:
      if 0 <= offset && offset + width <= alloc_size:
        → 安全（编译期证明，零运行时开销）
      else:
        → 编译错误
    else:
      → 插入运行时边界检查（由后端 emit）
```

### 运行时边界检查

当 allocation 大小已知、但指针偏移由运行时索引决定时，编译器为 DEREF/STORE_PTR 编码 allocation base、size 和 access width：

```
offset = pointer - allocation_base
check offset >= 0 && offset + width <= alloc_size
fail → panic
```

后端将其编译为 `sub` + `cmp` + `jae` + `ud2` 序列。points-to 只有一个 allocation 目标时可生成精确基址检查；多目标且偏移无法静态证明时保守拒绝编译。

### ALLOC_AT：声明式放置（2026-08-13）

`alloc_at(addr, size, align)` 是**声明式进图节点**：固定地址区域以（地址+大小+对齐）声明，与 ALLOC 同路径获得 provenance。声明之后全图追踪，ProvenanceVerify 照常验证边界+宽度：

```core
mmio := alloc_at(0x7fff0000, 4096, align(4096));  // MMIO 页，声明式进图
*mmio = 42;              // 安全代码即可，边界内照常验证
p := mmio + 4096;        // 越界 → 编译错误或运行时 check
```

- **声明是唯一信任点**（等价于一次受控的图边界入口），之后编译器重新获得追踪权——与 `unsafe` 的"标注图边界入口"语义一致，但进图后是普通 ALLOC 的验证路径
- 与 2026-08-10 定论（不扩展 0x 字面量直接指内部对象）**不冲突**：0x 字面量仍是 unsafe 外部入口；`alloc_at` 是声明式进图，用户必须给出地址+大小+对齐三个事实

## unsafe 边界

`unsafe` 是编译器无法追踪 provenance 时的唯一退路。发生在图边界：

| 场景 | 原因 |
|------|------|
| 外部硬件地址 | 裸 `0x7fff0000 as *int` 没有 ALLOC 节点；声明式放置用 `alloc_at`（见上节，进图后不需要 unsafe） |
| FFI 返回值 | 外部函数返回的指针没有 Core 的 provenance |
| inline assembly | 汇编的输出指针没有来源 |

### 类型双关

`*(dex*)&i` **不需要 unsafe**。图的存储语义是条目标识 + 偏移（`docs/design/cache-semantics.md` 条款 6）；经典映射下表现为"字节序列 + 宽度 + 边界"——provenance
（alloc 归属）、offset（字节偏移）、alloc_size（字节大小）全部与类型无关，类型只是
DEREF 处的"视图"。cast 以有类型的 `IR_LOAD` 保留值流，provenance 边不断：

- 双关合法判据 = 边界 + 宽度：`offset >= 0` 且 `offset + width <= alloc_size`
- 越界双关由 DEREF/STORE_PTR 的统一边界检查拦截
- 整数转指针产生 `asp=1`；该外部地址空间的解引必须在 `unsafe` 边界内

### 字节权限层（2026-08-13）

经典映射在"字节序列 + 宽度 + 边界"之上补充**每字节权限**（CompCert v2 范式——经典机器的权限投影，见 `docs/design/cache-semantics.md` 条款 7）：

```
Freeable > Writable > Readable > Nonempty > Empty
```

- Freeable：可比较、可读、可写、可释放；Writable：可比较、可读、可写、不可释放；
  Readable：可比较、可读、不可写；Nonempty：仅可比较（指针有效性）；Empty：无权限
- 分配后默认 Freeable；`drop_perm` 可收窄（如 const 数据降为 Readable）
- 权限与 provenance/offset/size 一样是**图数据**——验证器消费图即获得每字节控制

`unsafe` 是外部地址空间的显式边界。整数转指针会保留 `asp=1`，因此该指针即使流出块外，后续解引仍需要另一个 `unsafe` 边界；需要在 safe 代码中持续验证的固定地址应通过 `alloc_at` 声明式进图。

```core
unsafe {
    p := 0x7fff0000 as *int;  // 入口，编译器接受用户保证
    *p = 42;
}
// 块外再次解引 p 仍需要 unsafe
```

## 与其它语言的对比

| | C | Rust | Zig | Core |
|--|---|------|-----|------|
| 指针算术 | 随便 | `*T` 不行 | `[*]T` 可以 | 裸指针随便 |
| 越界检查 | 无 | bounds check | bounds check | 编译期证明或运行时 check |
| 生命周期验证 | 无 | borrow checker | 编译时 | RegionCheck |
| 别名分析 | 无 | 独占&共享引用 | 编译时 | PointerAnalysis |
| 验证时机 | 无 | 类型检查 | 编译时 | 图 pass |
| 用户需标注 | 无 | lifetimes | 有时 | 无 |
| unsafe | 整个语言 | 关键字 | 关键字 | 关键字 |

## 当前状态

Core 编译器已有HDFG（`src/compiler/dataflow.cr`）和线性扫描寄存器分配器（`src/compiler/opt.cr`）。

**更新（2026-07-28）**：三个 pass 已全部实现——
`src/compiler/ptr_analysis.cr`（PointerAnalysis）、`src/compiler/region_check.cr`（RegionCheck）、
`src/compiler/provenance_verify.cr`（ProvenanceVerify）。DEREF/STORE_PTR 后端发射
allocation-base-relative 的 `sub+cmp+jae+ud2` 边界检查，配合 2026-07-28 的 Arena 内存模型
（`src/stdlib/arena.cr`）。细节见 `TODO.md`。

**更新（2026-08-10）**：设计定论——
1. 类型双关由图自动验证（见上"类型双关"节），不需要 unsafe
2. **不扩展"程序内部地址直接指"（0x 字面量指内部对象）**——YAGNI：内部对象用 `&` 取址
   更优（无漂移、类型全、验证无条件）；外部契约地址 unsafe 已够用。0x 字面量仅保留
   unsafe 外部入口角色（上表前三行），详见 TODO 预存 bug 7

**更新（2026-08-13）**：设计修订（图锚定区域内存模型，只改文档不实现）——
1. **ALLOC_AT 声明式放置节点**进图（见上节）：固定地址区域声明式获得 provenance，
   与 2026-08-10 定论不冲突（0x 字面量仍是 unsafe 入口）
2. **跨区域引用放宽**：从"禁止"改为 outlives 顺序判定（RegionCheck 图活性判定即该检查）
3. **字节权限层**：每字节 Freeable/Writable/Readable/Nonempty/Empty（见上节）

**更新（2026-08-16）**：访问宽度、store 边界检查和 `asp` 外部地址约束已落地。
动态偏移检查使用 points-to 定位的实际 allocation base，不再使用页内偏移近似。

设计依据:`docs/superpowers/specs/2026-08-13-graph-anchored-regions-design.md` + `docs/design/region-model.md`。

**更新（2026-08-15）**：`&` 所指定稿——条目标识 + 偏移是语义，字节地址是经典投影（见上"地址 = 映射"节）。与三个 pass 无行为冲突（判定域本就是条目标识 + 偏移）。

## 参考

- **SVF** (SVF-tools): LLVM 上的值流图框架，自动检测 use-after-free、double-free、buffer overflow。Core 的HDFG是更统一的形式——同一张图同时做 regalloc、调度、验证。
- **Fridtjof Siebert** (2006): 全程序 context-sensitive flow-sensitive 指针分析，静态检测区域内存中的悬垂指针。RegionCheck 的直接参考。
- **Prov-GC** (Banerjee 2020): 动态 pointer provenance 追踪，实现 C 的声浪 GC。ProvenanceVerify 的 provenance 追踪概念来源。
