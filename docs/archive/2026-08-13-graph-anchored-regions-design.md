# 图固定区域内存模型设计（Graph-Anchored Regions）


> 术语注记（2026-08-15）：本规格为历史设计记录，其中「数据流图」（及「RVSDG 式」）为当时术语；该结构后定名为 HDFG（Holographic Dataflow Graph，全息数据流图），术语演进见 `docs/project-book.md`。正文保留历史原样。

> 当前区域模型见 [region-model.md](../maintainer/design/region-model.md)。本文是 2026-08-13 的历史设计记录，术语和实现已经演进，保留作为设计依据。

## 概述

在现有 Arena 内存模型（`docs/memory-model.md` + `docs/superpowers/specs/2026-07-28-arena-model-design.md`）基础上修改，不新增模型。

核心命题：区域（Region）固定在数据流图上。区域是子图节点的字节域，不跟随词法作用域。传统区域内存管理（Tofte-Talpin 区域栈、Cyclone、Verona）都固定词法作用域（LIFO 嵌套）；Core 的执行模型是数据流图，区域应当与图同构。

保留 Arena 的两个核心价值（放弃它们的代价不可接受）：

1. 无碎片：静态已知大小的分配路径保持纯 bump
2. 动态模式下工程可控的极低碎片：动态大小分配路径使用分档子区域，浪费上界由 size class 表决定

用户侧没有内存管理负担：区域划分、生命周期、回收时机、碎片策略、跨区域合法性全部由图自动推导和验证。用户只表达两件只有用户自己知道的事实：布局（例外入口）与放置（地址声明）。

## 设计动机

### 论文依据

| 论文 | 结论 | 对 Core 的意义 |
|------|------|---------------|
| Tofte & Talpin, *Region-Based Memory Management* (POPL'94 / I&C 1997) | 存储 = 区域的栈；区域分配/回收点由类型-效果分析自动推断；形式化可靠性证明。已知弱点：区域存在时间过长会导致内存泄漏 | 自动推断可行且可证明；泄漏弱点需要显式提前释放（见 Cyclone） |
| Gay & Aiken, *Memory Management with Explicit Regions* (PLDI'98)；*Language Support for Regions* (PLDI'01) | 显式区域与 malloc/free 性能相当；区域子类型（outlives）；多级区域层次；提前释放是工程可用的关键 | "指定回收"作为编译器内部机制（IR 层生成回收点），不暴露语法 |
| *Reference Capabilities for Flexible Memory Management* (OOPSLA'24, Verona 线) | 区域 = dominator scope，内部对象生命周期相同；内存按区域局部管理；底层 snmalloc 使用分档 bump 分配（size class） | size class 是动态碎片控制的工程标准做法 |
| Leroy et al., *The CompCert Memory Model, Version 2* (2012) | 块 + (块 ID, 字节偏移) 指针；每字节权限（Freeable > Writable > Readable > Nonempty > Empty）；`loadbytes`/`storebytes`；块按构造分离；Coq 机器验证 | 每字节权限层是语义面（验证器）的范式 |

### 与传统模型的差异

传统模型固定词法作用域：区域随函数或块进入而创建，退出而回收（LIFO）。Core 的区域固定图结构：

```
传统（词法绑定）：
fn f() {
  let x = ...;   // 区域 = 词法块
  ...
}                // LIFO 弹出

Core（图绑定）：
        SG_IF
       /     \
  branch1   branch2
       \     /
        join
区域 = 子图节点，生命周期 = 图活性
```

## 核心概念：图固定区域

区域 = 子图节点（`DFNode`）的字节域。现有设计的「每个 `DFNode` 可关联一个 Arena」「子图绑定」「Arena 嵌套」原样继承，概念升级为区域。

### 推论 A：生命周期 = 图活性（非 LIFO）

RegionCheck 的 `cur_seq < exit_seq` 判定（`pointer-model.md` Pass 2）就是图版本的生命周期定义。这种定义支持 `flow`/`go` 的独立区域（区域栈做不到非 LIFO 生命周期），也给出跨区域引用的合法性检查（`outlives` 的图形式）。

### 推论 B：沿图边的区域操作

区域既可以嵌套（树），也可以沿数据流边操作：

- `split`：一块字节沿边划给子消费者，字节块可以独立回收；子区域是图边的子块，有自己的游标和重置点
- `merge`：汇合点两个子区域的数据汇入（拷贝或区域合并）
- `share`：分叉点的一个区域由多个消费者只读共享，共享者必须 `outlive` 引用

### 推论 C：每字节归属 = 图的 `provenance` 边

`pointer-model.md` 已定义内存模型为「字节序列 + 宽度 + 边界」，`provenance`（归属）、`offset`（字节偏移）、`alloc_size`（字节大小）全部与类型无关。"控制每一个字节"不是新语法，是图上已有的信息。

### 与传统的关系

区域树是图区域的特例（无汇合、无分叉的图就是树，也就是词法嵌套）；Tofte-Talpin 的区域栈是更窄的特例（树 + LIFO）。本设计是推广，不是发明。

### 术语注记

`dataflow` 模块已有「region」一词指控制流嵌套（`SG_IF`/`LOOP`/`FOR`/`FLOW`/`UNSAFE`）。本文的「区域」指内存字节域。文档中按上下文区分；需要精确时，内存区域全称「内存区域」。

## 机制总图

| # | 需求 | 图上的机制 | 验证/推导者 |
|---|------|-----------|-----------|
| 1 | 字节块独立回收 | 区域 = 子图节点；子区域 = 沿图边 split；显式提前释放（回收点）由 IR 层生成；merge/share 处理汇合/分叉 | 图活性（RegionCheck） |
| 2 | 逐字节布局 | 布局元数据进图：字段字节偏移/packed/对齐，后端与验证器同一来源（语义保留） | 编译期计算，图节点存储 |
| 3 | 固定地址放置 | ALLOC_AT 节点（地址+大小+对齐）进图，与 ALLOC 同路径获得 provenance | ProvenanceVerify（边界+宽度） |
| 4 | 碎片有界 | 策略推导：子图全部为静态大小时使用纯 bump（零碎片）；混有动态大小时使用分档子区域（size class 表由图上分配大小分布推导） | 图分析（大小预计算扩展） |
| 5 | 跨区域 | outlives 顺序判定：引用者有效区间 ⊆ 被引用区域有效区间（RegionCheck 现有机制，从"禁止"放宽为"顺序判定"） | RegionCheck |

三条不变规则：

1. 静态已知大小路径 = 纯 bump，零碎片
2. 动态路径 = 分档子区域，浪费上界由 size class 表决定（工程可控：档位越细上界越低，如 pow2 档约 50%、细分档约 12.5%）
3. Arena Pool / 嵌套 / 子图绑定 = 原样继承，概念升级为"区域"

## 用户面（零管理负担）

用户不参与、全部由图推导的事项：

| 事项 | 谁做 |
|------|------|
| 区域划分/生命周期 | 图活性推导（子图边界即区域） |
| 回收时机（含"指定回收"需求） | 图分析生成回收点，推断在编译器内部完成，用户看不到 |
| 碎片策略 / size class | 图分析推导分配策略 |
| 跨区域合法性 | RegionCheck 自动判定 |
| 所有验证 | 三个 pass 自动完成 |

用户只表达两件只有用户自己知道的事实：

```core
// 1. 布局声明（例外入口）。默认布局全自动：编译器按类型推导自然布局
//    （字段顺序 + 自然对齐），用户不写任何东西。
//    layout(...) 仅在默认布局不合用时才需要：packed（FFI）、强制对齐、硬件结构。
struct PackedHeader layout(packed, align(4)):
    a: u8,       // 偏移 0
    b: u32,      // 偏移 4
    c: u16,      // 偏移 8

// 2. 放置声明。地址是物理事实，只有用户知道。
//    声明式进图（地址+大小+对齐），之后全图追踪，ProvenanceVerify 照常验证。
mmio := alloc_at(0x7fff0000, 4096, align(4096))
```

- v1 不提供显式区域或回收语法（YAGNI）。「指定回收」是编译器内部机制（IR 层生成回收点，相当于 Cyclone early deallocation 的自动版本）。
- 与 `pointer-model.md` 2026-08-10 定论的关系：0x 字面量仍是 `unsafe` 外部入口；`alloc_at` 是声明式进图（获得 `provenance` 的节点），不冲突。声明是唯一信任点，之后全图追踪。

## 语义面（验证器）

内存模型 = 图 + 字节权限层（CompCert v2 范式）：

- 每字节内容 = 字节序列（已有）
- 每字节权限 = Freeable > Writable > Readable > Nonempty > Empty（新加）
- 区域树 = 图的子图结构；布局元数据、`ALLOC_AT` 边界、`outlives` 结论全部从图导出。验证器消费图，就消费了全部内存语义
- 前置缺口：宽度检查（`off + width <= alloc_size`）待补（对应 TODO 预存 bug 7）

## 分配器面（实现）

现有 2026-07-28 arena 实现设计（arena pool、bump 双路径、链式扩容、子图绑定、大小预计算）原样继承，作为区域的实现层：

| 机制 | 实现 |
|------|------|
| 纯 bump 路径（零碎片） | 现有 arena_new/arena_reset + 大小预计算 |
| 分档子区域（有界碎片） | 池内 size-classed 子分配器（档位表由图分析推导，链式扩容沿用） |
| ALLOC_AT（固定放置） | 固定映射区（mmap/段），不进池 |
| 策略推导 | 图分析输出（大小预计算扩展：全静态时使用 bump，混动态时使用分档） |

## 与现有文档的关系

| 文档 | 改动 |
|------|------|
| `docs/memory-model.md` | 重写：Arena 改为图固定区域（本设计的语义核心） |
| `docs/pointer-model.md` | 修订：ALLOC_AT 节点、跨区域从"禁止"放宽为 outlives 顺序判定、补字节权限层 |
| `docs/ir-schema/coreir-schema.md` | 补：布局元数据、ALLOC_AT 节点定义 |
| `docs/spec-design.md` | 检查涉内存条目（#no_alloc 等）是否需要同步 |
| `docs/superpowers/specs/2026-07-28-arena-model-design.md` | 保留不动（分配器面实现设计），新设计在其上增加语义层 |

## 本阶段范围

只改文档，不实现（用户明确指示）。交付物 = 上述文档改动。

## 后续实施方向（不在本阶段）

| 阶段目标 | 内容 | 前置 |
|--------|------|------|
| M1 生命周期+碎片 | memory-model.md 重写实施；子区域 split；IR 层回收点生成；size class 策略推导 | 现有 arena 基础；TODO 预存 bug 5（arena 运行时死循环）为阻塞项 |
| M2 布局+放置 | 布局元数据进图（IR schema）；ALLOC_AT 节点；ProvenanceVerify 宽度检查 | M1；接 TODO 预存 bug 7 |
| M3 跨区域 | RegionCheck 从"禁止"放宽为 outlives 顺序判定；pointer-model.md 逃逸规则修订 | M1/M2 |

## 参考

- Tofte & Talpin, *Region-Based Memory Management*, POPL'94 / Information and Computation 132(2), 1997，[ACM](https://dl.acm.org/doi/10.1006/inco.1996.2613)
- Gay & Aiken, *Memory Management with Explicit Regions*, PLDI'98，[ACM](https://dl.acm.org/doi/10.1145/277652.277748)
- Gay & Aiken, *Language Support for Regions*, PLDI'01，[ACM](https://dl.acm.org/doi/abs/10.1145/378795.378815)
- *Reference Capabilities for Flexible Memory Management*, OOPSLA'24（Verona 线），[arXiv:2309.02983](https://arxiv.org/pdf/2309.02983)
- *The CompCert Memory Model, Version 2*，[Semantic Scholar](https://www.semanticscholar.org/paper/The-CompCert-Memory-Model%2C-Version-2-Leroy-Appel/a90495f9f586298a7424df15fb1308b42a373b5a)
