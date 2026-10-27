# 执行映射设计：修订记录与冲突登记

> 对应设计：[execution-mapping-design.md](../../maintainer/design/execution-mapping-design.md)

本文保存执行映射设计的原始 30 节展开、从 v1 到 v2 的修订、字段级实核、冲突登记、未核实清单和三态计数。设计正文只保留当前方案。

# 执行映射设计（Execution Mapping Design）

> 定位：受众 = 维护者/贡献者；状态 = 设计定稿（未实现），全文除显式标注 `[已实现]` 处外，均无仓库对应物。
> 设计意图出处 = 两份维护者 2026-09-20 口述输入（本文档均不改写它们）：
> - `/tmp/briefs/execution-mapping-raw.md`，主输入（30 节 + 能力格 + M0–M11）；本文 = 其形式化展开 + 仓库引用 + 不变量收紧 + 冲突登记。
> - `/tmp/briefs/materialization-space-raw.md`，对已定稿定义的修订（「格 = 缓存」，「格 = Materialization / Existence Space，缓存是其中一类映射实例」）。本文第 3 节/第 6 节/第 8 节已按其重述。
> 注意：时态更正（2026-09-20 复核后）：原写「既有「定稿」文档一律不改，只登记」，已不准确。
> 现况：那 7 处正由另一名撰写者就地修订（维护者裁「同阶段就地改」）；本文（本文件）仍全程未改它们（第 11 节 C-11 已同步缩小范围）。
> 凡读 C-11 的表，须按「修订前的原快照」读，不是现状。
> 核验基线 = `develop@origin` @ `38e6c9923ea4`（所有 file:line 以该修订为准，非手边检出）。
> 关联：
> - 层定义本体（不由本文承担）：`docs/maintainer/design/materialization-space.md`（存在格 / Materialization Space 的本体定义，另一撰写者 `existdoc` 负责）。本文引用它、不重复定义它；本文只承担「计算到执行域放置」这一面。
> 该文件已于 2026-09-20 写入仓库（此前本文按预定名引用）。两侧已做过逐节对拍（11 节：8 重叠 / 3 不重叠），重叠处的权威关系已逐条建立：
> | 命题 | 权威版本（权威侧） | 本文侧处置 |
> |---|---|---|
> | 格层四问 | 第 2.1 节（含两套措辞的权威标注） | 第 0.2 节 / 第 6.7 节 / 第 8 节9 引用，不复述 |
> | 七字段取值域 | 第 2.3 节字段级模型（七字段） | 第 3.4.2 节逐字引，只留实例取值列 |
> | 驱逐不变量的式 | `cache-semantics.md` 规则 2′（权威侧第 4.2 节亦标同权威版本） | 第 6.4 节 / 第 8 节8 引用 |
> | 式的检查形状 / fail-closed / 显式约束 | 第 4.3 节 / 第 4.4 节 / 第 4.5 节 | 第 8 节8 的检查与之互补 |
> | 逐字段实现距离审计 | 第 7.0 节–第 7.4 节 | 第 3.4.5 节删去重复表，只留执行映射侧两条结论 |
> | cache policy 划界 | 第 5 节（第 5.1 节明写 + 第 5.2 节可检验检查） | 第 0.2 节 / 第 6.7 节引用，只留「也不属执行域层」那句 |
> | 与既有定稿的兼容性声明 | 第 10 节 | 本文引用（本文侧不另立） |
> | 三节不重叠：第 4.3 节断言形状 · 第 7.4 节 `.ccr` 分层结论 · 第 10 节兼容性 | 权威侧 | 本文第 3.4.5 节 / 第 9.2 节 / C-3 与之互证（第 7.4 节独立支持本文“REG 全满”复核） |
> 注意：两侧若仍不一致，一律以 `materialization-space.md` 为准。
> - [existence-structure.md](existence-structure.md)，存在格的 IR 表示（ENT/NOD/REG）；本文第 3.4 节/第 13.3 节的字段距离实核以它为准。
> - 同层设计：[execution-model.md](execution-model.md)（图/region/并发）、[region-model.md](region-model.md)（图绑定区域 = 内存字节域）、[memory-model.md](memory-model.md)（存储语义导航）
> - 缓存语义：[cache-semantics.md](../../academic/cache-semantics.md)（七条规则），注意：本文起不再称其为“存储语义本体”：按新输入它是「缓存」这一映射实例的规律（“经典可再生值的一种映射规律”），层本体归 `materialization-space.md`。既有的“本体”措辞保持原样不改（第 11 节 C-11）。
> - 最相关的同类 spec：[2026-09-11-performance-without-commitment-design.md](../../superpowers/specs/2026-09-11-performance-without-commitment-design.md)（S-C，下称 S-C），本文第 5 节/第 7 节/第 8 节3 与它同构，且受其裁决约束
> - 编码层：[2026-09-05-hardware-interface-table.md](../../superpowers/specs/2026-09-05-hardware-interface-table.md)（HIT）、[2026-08-23-hw-map-design.md](../../superpowers/specs/2026-08-23-hw-map-design.md)（MMIO 设备表）
> - 交叉引用（勿混）：`docs/superpowers/plans/2026-09-20-mapping-layer-separation.md`，那份是字节偏移抽象（语义到布局的投影，`offset ∈ extent(entry)`），管的是同一执行域内「值落在哪几个字节」；本文是计算到执行域放置，管的是「这段计算在哪个域发生、跨域怎么物化」。按维护者管线图两者同落 `Lattice -> Mapping -> Encoding` 的 Mapping 格，分工 = 投影面 vs 放置面，粒度/语义/消费方均不同，不得合并、不得互相覆盖。
> 注意：该文件在核验基线上尚不存在（`docs/superpowers/plans/` 无 `*-mapping-layer-*`），本条交叉引用是预定依据，待其写入仓库后双向对齐（本文只加本行，不改那份文件）。

---

## 〇、三态标注约定（全文强制）

本文档凡陈述「仓库现在有什么」的句子，逐句带下列标记之一：

| 标记 | 含义 | 举证义务 |
|---|---|---|
| `[已实现]` | 核验基线上有实现 | 必须给 `file:line`（本会话实核，非记忆） |
| `[已设计未实现]` | 仓库有设计文档/规划但无实现 | 必须给出处文件 |
| `[提案]` | 本文新提出，仓库无对应物 | 无（默认档） |

默认必须是 `[提案]`：核不到行号的句子一律不得标前两档。三态计数见第 13 节。

### 〇.1 四个必须先明确的术语约束

本文档与既有文档存在四处同名不同义，开始前必须明确，否则后续所有讨论都会混淆：

| 词 | 本文档的义 | 仓库既有文档的义 | 处置 |
|---|---|---|---|
| Region | Execution Region = 放置单位（`flow`/`loop`/`fn` 对应的语义区域） | [region-model.md](region-model.md) 的图绑定区域 = 内存字节域（arena），“区域是子图节点的字节域，不是词法作用域的对应物” `[已实现]` 分配器面 | 本文一律写全称 `ExecutionRegion`，不只写 `Region`；单独的 `Region` 保留给内存义 |
| HIT | 原文假定 = baseline universal execution target（一个执行域） | Hardware Interface Table = 表驱动编码机制（`src/arch/hit/hit.cr:2`），`[已实现]`；其“替换表 = 换目标平台”（HIT spec 第 1 节）表明 HIT 是机制不是域 | 见第 11 节冲突 C-1；本文凡引用原文假设处写 `HIT`（原文假设义），引用仓库物处写 `HIT（表机制）` |
| 格 / Lattice | 注意：两义并存，必须分写：<br>1 存在格 / Materialization Space = 格层本体（本文第 6 节用它，本体定义归 `materialization-space.md`）<br>2 Capability Lattice = mapper 内部的能力偏序组织参数（本文第 4 节） | [memory-model-capability-lattice.md](../../archive/memory-model-capability-lattice.md)（archive，v4 定稿）的「无格承诺」：格代数不进入语义本体，是映射实例的组织参数 | 1 本文写「存在格」；2 本文写「能力格」，永不同用一“格”字。两者都受「无格承诺」约束（第 11 节 C-6） |
| 缓存 / cache | 注意：本次降级：「缓存」= 存在格在经典机器上的一类映射规则（“经典可再生值的一种映射规律”），不是层本体 | 既有定稿措辞，因此修订前的措辞（过去式，2026-09-20 复核后改时态）：`project-book.md:216`「存储语义本体为缓存语义」、`z-vision.md:15`「存储半边已定稿（语义本体 = 缓存语义）」，该两处已被就地修订（不再以现在时引用）；`cache-semantics.md:4`「本文件是 Core 存储语义本体的唯一权威」亦在修订面内 | 本文（本文件）未改它们；改动由另一名撰写者就地执行（第 11 节 C-11 原快照 + 已裁）。本文不再写“缓存 = 存储语义本体”；凡须指既有规则处写「缓存语义规则（映射实例规律）」并给出处 |

### 〇.2 层归属：格层不承担 policy（本次新增的硬边界）

> 注意：权威关系声明（2026-09-20 二次复核后补）：本条与权威侧同命题，
> 权威版本 = `materialization-space.md` 第 5 节（划界：cache policy 不属于格层），其第 5.1 节明写归属、第 5.2 节给可检验的划界检查
> （「格层描述里出现『何时/多久/顺序』这类词 = 格层管了该归 mapper 的事」）。
> 本文不复述权威的检查（避免第三份拷贝）；本节只保留本文特有的那一句：
> 「policy 也不属本文的执行域层」，因为本文（执行映射层）自己也声明不承担 policy，同样不承担 policy，故须双向写明。
> 取数/取检查一律以第 5 节为准。

新输入明确划出的一条界，本文全程遵守（四问编号与权威第 2.1 节「格层回答的四问（原文逐条）」 一致，该节是四问的权威版本）：

```
格层（存在格）只回答四问：          全部给 mapper（本文 第五）：
  1 哪些 materialization 合法          · 什么时候驱逐
  2 哪些可以共存                        · 放寄存器还是 RAM
  3 哪些代表同一 Entry/version          · GPU 是否保留 residency
  4 哪些转换保持语义                    · LRU / write-back / write-through / prefetch
```

因此 LRU / write-back / write-through / prefetch / 「GPU 是否保留 residency」一律是 `mapping strategy`，既不属格层、也不属本文的执行域层。
因此本文第 5.2 节的 `Cost(R,D)`、第 5.5 节的调度算法、第 5.7 节的动态 mapper 全部落在 mapper 侧，这一点在旧稿里是隐含的，本次显式划界（见第 8 节不变量 9）。
因此可检验检查（本文采用权威第 5.2 节的，并落成本文侧的一条检查）：本文第 8 节9 检查 2「策略词零命中」须与权威同一判法，格层面不得出现「何时/多久/顺序」类词；该条检查怎么判以权威第 5.2 节为准。

---

## 一、目标与范围

### 1.1 一句话目标

> Core 程序只描述计算；Execution Mapping 决定计算在哪个执行域发生，跨域的数据如何物化和迁移；任何未指定或无法优化的计算始终存在通用下降路径。

### 1.2 架构边界（七层链）

```
Source
  ↓
Semantic HDFG                    ← 语义的定义处；不知道 CPU/GPU
  ↓
存在格 / Materialization Space    ← 不知道 CPU/GPU；本体定义归 materialization-space.md
  ↓                                （旧稿此行写 `Lattice / Existence` ， 本次具体化为「存在格」，
  ↓                                 层名与既有「图 -> 格 -> 编码」的「格」同一，见 第十一 C-12）
Execution Mapping                ← 本文档
  ├─ region partition
  ├─ execution placement
  ├─ data residency
  ├─ transfer planning
  └─ scheduling
  ↓
Encoding / Backend               ← 唯一允许出现机器名词的层
  ├─ HIT（表机制）
  ├─ CPU
  ├─ GPU
  ├─ NPU
  └─ future domains
```

三条禁令（原文，本文不改其强度）：

```
HDFG 不知道 CPU/GPU
Lattice 不知道 CPU/GPU
HIT 不需要为了异构计算修改语义
```

- 前两条 `[提案]`（无实现，但方向与既有分层一致）。
- 第三条 `[已实现]` 的制度面：HIT spec 第 7 节已明文「优化不进表（判定/分配 = 格形态层）」，且 HIT 位于发射层、位于 placement 下游，因此 placement 不进表是既有规则，不是本文新提。
注意：但该条的内容面有实现缺口，见第 11 节冲突 C-1。

### 1.3 五层定稿（论文核查后）

```
Semantic HDFG
      │
      ↓ infer
Region Requirements
      │
      ↓ compatibility proof
Capability Model
      │
      ↓ candidate domains
Execution Mapping
      ├── Cost
      ├── Topology
      ├── Residency
      ├── Criticality
      └── Runtime state
      ↓
Mapped HDFG                      ← = HDFG + mapping overlay，不是第二份语义 IR
      ↓
Backend / Encoding
```

`Mapped HDFG` 的定义 `[提案]`：`Mapped HDFG = HDFG ⊕ mapping overlay`。原 HDFG 仍是 semantic truth；overlay 可整体摘除（第 8 节不变量 1）。

### 1.4 v1 明确不做（原文第 30 节，逐条保留）

```
CUDA 风格 kernel 语法；      gpu fn；        cpu fn；
显式 memcpy；                GPU pointer 类型；  host/device 两套语言；
用户级 capability tag 大全；  每 DFNode 动态迁移；  全局最优 ILP scheduler；
ML scheduler；               自动 profiling database；
distributed execution；      多 GPU 复杂复制策略。
```

---

## 二、用户接口

### 2.1 三态（唯一允许的 placement 关键字）

```core
flow compute { ... }                    // automatic
@preferredDomain(gpu) flow compute { … }  // soft constraint
@executionDomain(gpu) flow compute { … }  // hard constraint
```

| 源码形态 | 语义 | 无法满足时 |
|---|---|---|
| 无注解 | `placement = automatic` | 必有解（第 8 节不变量 7） |
| `@preferredDomain(X)` | soft：进 cost function 的偏置项 | fallback，automatic，通用路径 |
| `@executionDomain(X)` | hard：部署约束，非程序语义 | 编译/部署错（mapping failure），绝会报错回落 |

`[提案]`，三个关键字、两种注解，仓库零对应物。v1 不再增加任何 placement 关键字。

### 2.2 作用范围

原文支持：`fn` · `flow` · `loop`/`for` · 显式 region。

```core
fn pipeline(...):
    prepare()

    @executionDomain(gpu)
    flow compute:
        ...

    finish()
```

产出：

```
prepare
   │
   ▼
compute [gpu]
   │
   ▼
finish
```

因此不强迫整个函数进入同一 domain。

注意：语法现状（实核）：

| 形态 | 仓库现状 |
|---|---|
| `flow fn name(...) { }`（顶层 flow 函数） | `[已实现]`：`lexer.cr:94`（`"flow" -> T_FLOW`）；`parser.cr:1726-1749`（`is_flow` 置位后要求紧跟 `T_FN`）；`SG_FLOW : int = 3`（`dyn_arr.cr:157`）；region 名 `"flow"`（`dataflow.cr:533`）；`grammar/core.ebnf:22` `FlowDecl = 'flow' IDENT [GenericParams] '(' [ParamList] ')' '->' Type` |
| `flow compute { ... }`（函数体内的 flow 块，原文主例） | 不存在，且被硬拒：`parser.cr:1002-1010` 对语句位 `T_FLOW` 直接发 `EC_P_NESTED_FN`（P021，`ast.cr:351`）「Nested function declaration is not supported； declare it at top level」 |

因此原文第 2 节的主例在今天是一条 P021 语法错。M1 的「flow 块」是新增语法，不是接线既有语法。
因此而且 `grammar/core.ebnf` 的 `Statement` 不含 `FunctionDecl`（`parser.cr:995-996` 注已写明），故这是语法面变更，须同阶段改 EBNF + 文档 + 负例档。

### 2.3 嵌套规则（一开始确定）

```
@preferredDomain(gpu)
fn foo():
    ...
    @executionDomain(bigCpu)
    flow x:
        ...
    // 生效 = bigCpu，不继承 gpu
```

规则：
1. 离当前 ExecutionRegion 最近的 annotation 生效；
2. hard > soft（同近度下硬约束压软约束）；
3. 父 region 与子 region 允许跨 domain，对应数据迁移自动产生。

`[提案]`。规则 3 的例：

```core
@executionDomain(gpu)
fn foo():
    @executionDomain(cpu)
    flow x:
        ...
    // 合法；自动产生 gpu->cpu 的 materialization
```

注意：规则 3 与既有 `region_check` 的「活子图」义务可能交互（跨域后 Entry 的 kind 属性是否随域改变），未核实，登记在第 12 节。

### 2.4 Domain 名不是语言内建

Core 不内建 `cpu` / `gpu` / `npu` / `cuda` / `vulkan`。语言只认识 `DomainName`。

`@executionDomain(gpu)` 里的 `gpu` 是逻辑名，来自部署配置：

```toml
[executionDomain.cpu]
backend = "hit"
device  = "cpu0"

[executionDomain.bigCpu]
backend = "hit"
device  = "cpu-big"

[executionDomain.gpu]
backend = "gpu"
device  = "0"
```

换机器只改配置，Core 源码不用修改。甚至：

```
@executionDomain(fast)     // 某平台 -> CPU 大核；另一平台 -> GPU
```

`[提案]`，但受既有裁决约束（这是硬约束不是建议）：

- S-C L1 裁决 `[已设计未实现]`：「机器形状不进程序意义：源码/图零机器名词（无宽度、无寄存器、无 SIMD 宽度、无设备名）」
- S-C 第 3.2 节反向泄漏检测 `[已设计未实现]`：`c) 源/图中出现机器名词`，因此违反，登记为「泄漏待归一」

因此本节的逻辑名纪律不是风格建议，而是已有裁决的操作面。注意：但原文自己给的例子（`cpu` / `gpu` / `bigCpu`）全部是机器名词；只有 `fast` 是合规形态。登记为冲突 C-7，不替维护者裁决（可能裁决是“逻辑名允许与机器同形”）。

---

## 三、数据结构定稿

> 本节把原文散落的结构收紧到字段级。所有结构 `[提案]`（仓库无对应物）；
> 但表示方式 `[已实现]`：Core 编译器侧表一律是扁平定长记录 + `OFF_*` 槽偏移的字节缓冲（先例 = `ESZ_SG : int = 48` + `OFF_SG_KIND/ENTER/EXIT/PARENT/NSTART/NCOUNT`，`dyn_arr.cr:146-152`），故本文也用同一种写法规定。
> `u64` 槽宽与 `OFF_*` 命名沿用仓库惯例；尺寸标注为本文规范（实施阶段可改，须同阶段改本节）。

### 3.1 ExecutionDomain

```
ExecutionDomain {
    id                        // 逻辑名（部署配置键），非机器名
    backend                   // 后端标识；backend 自己回答 canLower(region)
    attachedMemoryDomains[]   // 见 第八 不变量 2
    dispatchModel
    profile                   // -> PerformanceProfile（第3.8）
    capabilities              // -> CapabilityDomain（第3.7）
    limits                    // 数值上限（见下）
}
```

原文第 5 节第一版形态与「论文核查后」形态（加 `capabilities`/`limits`/`executionProfile`）合并为本节；差异见下注。

| 槽 | 名 | 类型 | 含义 |
|---|---|---|---|
| 0 | `ed_id` | 名索引 | 逻辑域名（部署配置键） |
| 8 | `ed_backend` | 名索引 | 后端标识；`canLower/estimateCost/emitVariant` 的派发键（第 5 节） |
| 16 | `ed_mem_head` | 下标 | 附着 MemoryDomain 链头（`-1` = 无） |
| 24 | `ed_cap` | 下标 | CapabilityDomain（第 3.7 节） |
| 32 | `ed_limits` | 下标 | 数值上限表（`matrixTile <= 128` / `localStorage <= 96KiB` 之类） |
| 40 | `ed_profile` | 下标 | PerformanceProfile（第 3.8 节） |
| 48 | `ed_dispatch_model` | 码 | 派发模型（v1 只用于诊断/dump，不参与判定） |
| 56 | `ed_flags` | 位域 | 保留 |

两条设计约束（原文明确）：1 不做复杂 capability taxonomy，`backend` 自己回答 `canLower(region)`，语言不维护 `supportsMatrix`/`supportsBranch`/`supportsPointer` 大全；2 `capabilities`（离散合法性）与 `limits`（数值上限）分开，「96 KiB」不得被丑化成 `hasLargeSharedMemory`。

`[提案]`；`backend 自己回答 canLower` 这一条有仓库前件：HIT spec 第 3.2 节「无实现：条目缺失，编译期拒绝或 unsafe 外部入口」`[已设计未实现]`，即“能力协商在表/后端侧，不在语言侧”已是既有立场。

### 3.2 MemoryDomain

```
CPU0 ─┐
CPU1 ─┼── DDR
NPU  ─┘

GPU ───── VRAM
```

也可能：

```
CPU ─┐
GPU ─┼── UnifiedMemory
NPU ─┘
```

| 槽 | 名 | 类型 | 含义 |
|---|---|---|---|
| 0 | `md_id` | 名索引 | 逻辑内存域名 |
| 8 | `md_kind` | 码 | 内存范式（线性/统一/…）；v1 仅诊断 |
| 16 | `md_capacity` | u64 | 容量（度量，非判定） |
| 24 | `md_flags` | 位域 | `coherent`/`shared`/… |

公理：`ExecutionDomain ≠ MemoryDomain`，不得合并（第 8 节不变量 2）。

`[提案]`。注意：最近但不同的既有物：`docs/maintainer/design/region-model.md` 的「图绑定区域」= 字节域 `[已实现]` 分配器面；那是内存侧的一个经典映射实例（cache-semantics 规则 7 `[已实现]` 文档面），不是 domain 表。不要把两者混为一谈。

### 3.3 TopologyLink

原文初版 `{fromMemory, toMemory, latency, bandwidth, setupCost, coherent, shared}`；
论文核查后加强为：

| 槽 | 名 | 类型 | 含义 |
|---|---|---|---|
| 0 | `tl_src` | 下标 | 源 MemoryDomain |
| 8 | `tl_dst` | 下标 | 目标 MemoryDomain |
| 16 | `tl_setup_latency` | u64 | 建立延迟（`setupCost` 的更名形态） |
| 24 | `tl_bandwidth` | u64 | 带宽 |
| 32 | `tl_coherent` | 0/1 | 一致性 |
| 40 | `tl_shared` | 0/1 | 共享内存（`CPU0↔CPU1: shared=true, coherent=true`） |
| 48 | `tl_async` | 0/1 | 支持异步传输 |
| 56 | `tl_bidir` | 0/1 | 双向 |
| 64 | `tl_max_inflight` | u64 | 在飞传输上限 |
| 72 | `tl_engines` | u64 | transfer engine 数 |

加强的理由（原文）：两个看似相同的 32 GB/s 连接，若 A 只能同步复制、B 有两个 DMA engine 可双向并行，调度行为完全不同，因此 latency/bandwidth 两项不足。
反向证据 `[已实现]` 级别的同型论证：`sched.cr` 的队列是每 M 一条本地 run queue（`sched_enqueue(g: string)` / `sched_dequeue(m_idx: int)`，`src/stdlib/sched.cr:64,82`），即“通道的并行度”在仓库里确实被显式建模，不是被带宽跳过。

`[提案]`。

### 3.4 Materialization

> 注意：本次重写：旧稿此处是 `Entry X: DDR valid / VRAM valid`（缓存副本措辞，隐含“有权威值 / 可复制 / 副本同值”三假设）。按新输入 `/tmp/briefs/materialization-space-raw.md` 升级为两级结构 + 七字段（`Semantic Entry -> Materialization`）。
> 本体定义不在此处，归 `docs/maintainer/design/materialization-space.md`（另一撰写者）。本节只写本文消费到的字段面与仓库距离实核。

#### 3.4.1 两级结构（不是“Entry 的两份副本”）

```
Semantic Entry                      ← 语义对象（身份 + 版本），不是存储物
    │
    ├── Materialization M0 @ location
    │       recipe / identity / version / authority / persistence / replicability
    │
    └── Materialization M1 @ location
            recipe / identity / version / authority / persistence / replicability
```

注意：与旧稿的措辞差异（本文阶段要点）：旧稿写 `Entry X` 直接挂 `DDR valid / VRAM valid`，那是把 Entry 当存储物。新结构里 Entry 是语义对象，`location` 才在 Materialization 上；且没有全局 `valid` 位（“哪份新鲜”的检查被 `authority` 取代）。

#### 3.4.2 七字段（本表 = 执行映射侧视图；取值域权威 = `materialization-space.md` 第 2.3 节）

> 注意：权威关系声明（2026-09-20 复核后缩小范围，本条是“同一命题两处说法”的第一类命中，已按权威关系统一）
> 七字段的取值域（枚举成员）由层定义侧给出，权威 = `docs/maintainer/design/materialization-space.md` 第 2.3 节
> （表题「字段级模型（七字段）」（该表题本轮已由权威侧改名，原为「字段级定稿」，改名是为消「定稿」与「本表整体 = [提案]」两说），四列 = 语义 · 取值域 · 谁写 · 谁读，另附两条蕴含关系）。
> 本表不另立取值域：`取值域` 列逐字引那份；本文独有的内容 = 最右两列（两个映射实例的取值，取自本文输入）
> ＋「本文三态」列。冲突时以 `materialization-space.md` 为准。
> 注意：修正记录：本表原写了一份自立的取值域（`recipe` = `0/1`、`authority` = 可转移/可重建、`persistence` = 否/`external`、
> `replicability` = `yes`/`no/limited`），与权威 4/7 行不等，那正是本条要消灭的“两处各自给一份、互不指向”。
> 已按权威关系统一（见第 12 节未核实项 15 的状态变更）。

| # | 字段 | 取值域（逐字引 `materialization-space.md` 第 2.3 节） | 含义 | 缓存实例取值 | MMIO 实例取值 | 本文三态 |
|---|---|---|---|---|---|---|
| 1 | `recipe` | `{recomputable, unrecomputable}`（二元） | 存在能否由图内方法重新导出等价状态 | `recomputable` | `unrecomputable` | `[已设计未实现]` |
| 2 | `identity` | Entry 标识 = （变量标识，版本序）；匿名条目 = 产生节点身份 | 这是哪一条 Entry（同一性） | 产生节点 | 产生节点（= 设备读数节点） | `[已实现]`（`def_nod`） |
| 3 | `version` | 1-based 组内序（现行实现的做法） | 同一 identity 版本序列中的位置 | 版本序数 | 版本序数 | `[已实现]`（仅盘面） |
| 4 | `authority` | `{single(ref), shared-readonly, unresolved}` | 同 Entry/version 有多份时哪一份算数 | `single(ref)` | `single(ref)`（本文读法：ref = 设备侧物化，对应原输入的 `authority = device`） | `[提案]` |
| 5 | `location` | mapper 的位置域（格层不定义位置代数；现行约定：位置域 = 实例侧声明） | 当前在哪里存在 | DDR / VRAM / 寄存器 | 设备寄存器窗口 | `[提案]` |
| 6 | `persistence` | `{free, transfer-required, externally-owned}` | 消失前其状态是否必须被转移到合法实现方式 | `free` | `externally-owned`（原输入写 `persistent = external`） | `[已设计未实现]` |
| 7 | `replicability` | `{free, readonly-share, forbidden}` | 是否允许存在多份 | `free` | `forbidden`（原输入写 `no/limited`；`limited` 一档对应 `readonly-share`） | `[提案]` |

注意：最右两列的定性：它们是映射实例的示例取值（取自本文输入），不是取值域定义，取值域以第 2.3 节为唯一来源。
注意：上表第 4/6/7 行的实例映射是本文的读法（把原文的 `device` / `external` / `no|limited` 落到权威枚举上），如与第 2.3 节的解释冲突，以那份为准。

权威第 2.3 节另给的两条蕴含关系（不是等价），本文必须服从（逐字引）：

```
recipe = unrecomputable        ⟹  persistence ∈ {transfer-required, externally-owned}
replicability = forbidden      ⟹  authority = single           # 多份不合法 => 权威不可能有歧义
```

注意：对本文第 8 节8（`Evictable`）的直接后果（本文补的分析）：`Evictable` 的第二支 `PreserveRequiredState` 与
`persistence` 直接挂钩，因此上述两条蕴含给出两条可机械检查的交叉约束，应作为第 8 节8 检查 4 的一部分：
- 凡 `recipe = unrecomputable`，因此 `persistence` 不得为 `free`；
- 凡 `replicability = forbidden`，因此 `authority` 必须是 `single`。
因此二者都应在实现侧作为断言（违反 = 硬错，不是“退化”）。

原文给的两个实例（照录，供对照，注意：原文用的是自述词 `yes/no/external`，权威现已给规范枚举，以权威为准）：

```
缓存：  recipe = yes   replicable = yes   evictable = yes   authority 可转移/可重建
MMIO：  recipe = no    replicable = no/limited   persistent = external   authority = device
```

#### 3.4.3 本文的 mapper 侧附加槽（`[提案]`，非格层）

以下两槽不属存在格，是本设计为 mapper 加的（第 0.2 节划界；本体字段以上表七项为准）：

| 槽 | 名 | 类型 | 含义 |
|---|---|---|---|
| `mt_materialize_op` | 下标 | 可调度 operation 句柄，使 materialization 可 prefetch/async/overlap（第 6.4 节） |
| `mt_memd` | 下标 | 所在 MemoryDomain，域归属，属放置层（第 3.2 节） |

注意：`location`（格层，语义位置）与 `mt_memd`（放置层，具体内存域）不是同一槽：前者回答“存在形式”，后者回答“在哪个域”。合并会把格层与放置层搅在一起。

#### 3.4.4 「缓存」降级为特例（六个假设 + 反例）

新输入点名的、被“缓存”一词偷偷带进的六个假设，它们在经典 CPU/GPU 内存/寄存器分配/异构 residency 上成立，但在列举的反例上不成立：

| # | 假设 | 反例（新输入列举，含既有文档佐证） |
|---|---|---|
| 1 | 有一个原始/权威值 | 分布式唯一 authority（无单点权威） |
| 2 | 可以复制 | 一次性 token / 线性资源（复制本身非法） |
| 3 | 可以驱逐 | 事务中的临时状态 |
| 4 | 可以重新物化 | 不可重复 oracle / 随机数 / 量子测量（重跑 ≠ 原结果） |
| 5 | 通常存在 backing store | MMIO read / 外部输入 |
| 6 | 不同副本原则上表示同一个值 | 同上第 2/4 条的反例 |

`[提案]`。注意：仓库侧已有独立佐证：cache-semantics 规则 4b 已把「图内不可重算」条目单列，并规定「驱逐不变量/再生等价对其不成立」（`docs/academic/cache-semantics.md:28`；细读 `:50-59` 给两类：边界 MMIO/FFI/输入/测量、图内不可重算 神谕/BSS/FIXPT/模糊融合）。
因此本次的新框架把规则 4b 从“例外规则”升格为“一般规则的支柱”：规则 2/3（可驱逐/可再生）成了 `recipe = recomputable` 那一档的特例。

#### 3.4.5 与仓库的引用（逐字段距离，权威版本在权威侧，本处只留执行映射侧结论）

> 注意：权威关系声明（2026-09-20 二次复核后缩小范围，本条是“同一份审计工作的两份拷贝”的处置结论）
> 逐字段实现距离的「权威版本」= `materialization-space.md` 第 7 节（实核：新定义与实现的距离），其四节分工：
> 第 7.0 节结论摘要（七字段一行一览）· 第 7.1 节 `recipe` 是不是真 bit · 第 7.2 节其余六字段逐格读数 · 第 7.3 节版本面 · 第 7.4 节 flag 位预算。
> 本文原也有自己的一份逐字段表（本会话独立做的），结论与权威一致但是同一份工作的第二份拷贝，因此必然变化。
> 本处已删去重复的逐字段表，只保留本文（执行映射侧）特有的两条结论 ＋ 一处对本文第 9.2 节有直接后果的引用。
> 取数一律以第 7 节为准（它比原表更细：多了 `src/lattice/ent_kernel.cr` 的生产者/消费者面、`replicability` 的设计面出处、`location` 的旁路表）。
> 注意：两处说法有一处不一致（以权威为准）：`persistence` 权威判「无独立字段（义务被『必须有 home』隐式承担）」，
> 本文原表写作「槽位在、值恒默认」，以权威的说法为准。`recipe` 权威判「槽位就位，语义未实现（恒 0，零生产者、零语义消费者）」，与本文「预留位 + 恒零值」同义，以权威措辞为准。

本文（执行映射侧）保留的两条结论（分析归本文，依据数据取第 7 节）：

1. `recipe` 与 `persistence` 是同一形态：槽位已预留、值恒为默认，`flags = 0` / `home = -1`；且原因同一，
 `ccr_io.cr:83-84` 明写「分配决策不写回格式」，因此二者不是“未设计”，而是“设计了槽位但写侧不做决策回填”。
因此对实施阶段的含义：变活位不需要改布局（位已预留），需要的是一个写点 + 一个消费点。
注意：但本条须与权威第 7.4 节合读才完整（见下），「不需改布局」不等于「记录里还有地方放别的」。
2. 七字段里绝大多数落在 `[提案]`/`[已设计未实现]`，只有 `identity` / `version` 是实打实的 `[已实现]`（且各自只是“部分”）
因此新框架不是对既有实现的重新描述，而是一次真实的抽象升级，不要把“ENT 里已经有 version 和 home 了”读成“新框架已实现”。

注意：对本文第 9.2 节 / C-3 有直接后果的引用（权威第 7.4 节，本文采纳其更严结论）：
权威第 7.4 节「flag 位预算」的结论是，位确实预留了，但那个字段所在的记录没地方再放别的。
因此本文第 9.2 节结论 1 的「变活位不需改布局」成立，但不得据它推出「ENT 记录还有富余可表示新字段」：
`ent_kernel`/`ccr_io` 侧的 ENT 记录槽位全满（本文独立复核亦得同结论，见第 11 节 C-3 表）。
两者不冲突，权威那条更严；本文按其结论缩小范围。
因此另：权威第 7.4 节确认「全 `.ccr` 只有 ENT 一处有 flags 字段」（NOD/REG/EDG/TYPE/IFACE 均无），
这正好独立支持本文 C-3 的「REG 盘面 6×i32 全满、MAP 若按 region 表示须改布局」，两处结论互证。

- `[已实现]` state edges 本体：`DFEdge` 的 `kind=1` 边 = state edge（`docs/maintainer/design/execution-model.md:36,57`），“副作用链与循环终止依赖”。
- 注意：`version` 的既有解释须改口：旧稿此处写“本节的版本化…是规则 5 在多内存域下的展开”。按新输入，规则 5 属缓存映射实例的规律，因此正确措辞 = “存在格的版本性在缓存实例上的投影恰好是规则 5”。结论（版本化成立）不变，归属变了（第 11 节 C-11）。

### 3.5 ResidencyState

本次重写（旧稿是 `{memoryDomain, version, valid}`，`valid` 是缓存假设 #6「不同副本同值」的残留）：

```
ResidencyState {
    entry                      // 语义对象
    materializations[]         // 该 Entry 在当前时刻的物化集合
}
```

= `Materialization` 的索引视图（`entry -> [materialization]`），不另立本体结构。每个元素带第 3.4.2 节的七字段。

注意：`valid` 位被删除（本次要点）：旧稿的 `X2: DDR valid / VRAM stale` 是“哪份新鲜”的副本有效性模型；新框架用 `authority` 取代它（“哪份有权威性”），因为对无方法条目（`recipe = unrecomputable`），“VRAM 那份比 DDR 那份旧”这句话没有意义（两份可能都不是可再生的；且 `replicability = forbidden` 时根本不该有两份）。

`[提案]`；`version` 面 `[已实现]`（盘面，第 3.4.5 节）；`authority` 面零命中（第 3.4.5 节第 4 行）。

### 3.6 RegionRequirement

```
RegionRequirement {
    operations
    control
    addressing
    synchronization
    effects
    guarantees
    parallelism
    storage
    dynamism
    communication
}
```

（原文“四对象”节给的是六项 `operations/control/addressing/synchronization/effects/guarantees`；
能力维度给的十项。本文合并为十项，与第 4 节的十个能力轴一一对应，原文两处不一致，本文按能力维度为准，见第 11 节冲突 C-8。）

关键约束：RegionRequirement 不由程序员写，须从 HDFG 自动推导最小能力集 `minimalRequirements(region)`（原文 第 “Requirement 应该从 HDFG 自动推导最小能力集”）。

推导例：

```
flow x { for i in 0..n { out[i] = a[i] + b[i]; } }
   => { Computation: int32/add, Control: loop, Parallelism: data,
        Addressing: indexed, Effects: none }

while p != null { x = x + p.value; p = p.next; }
   => { Control: dynamicLoop, Addressing: indirect+pointerLike,
        Storage: persistent }
```

最小 basis 而不是全量附载：若 `generalIndirectAddressing` 已隐含 `load`/`addressMapping`/`randomAccess`，就不要全部重复存，否则 `.ccr` / mapping metadata 膨胀。

`[提案]`。
注意：但推导的原料面大量 `[已实现]`：`effects` 可从 state 链 + 真纯度取（`compute_all_purity`，`checker.cr:4555`；opcode 的唯一定义处 `purity_op_effect`，`checker.cr:4508`）；`control` 可从 region kind 取（`SG_LOOP/SG_FOR/SG_IF/SG_FLOW/SG_UNSAFE`，`dyn_arr.cr:154-159`）；`addressing` 可从指针分析取（`ptr_analysis.cr`）；`storage` 可从 region 的 arena 归属取（`g_df_node_region`）。

> 注意：行号变化告警（本文实核）：S-C 第 1 节表同两处引用写的是 `checker.cr:2959` / `:2912`，在核验基线 `38e6c9923ea4` 上已指向无关代码（恰好是 `}`）。真值 = `:4555` / `:4508`。因此凡从 S-C 转引 `file:line` 处一律须现查，不得直接搬运（既有纪律：修订已不是当前基线，因此复核任何清单的第一步 = 把声明基线换成当前基线）。本文其余引用均为本会话现查值。
因此 requirement 推导不是从零开始，是消费既有 pass 输出。这一条应在实施阶段当第一刀（见第 7 节）。

### 3.7 CapabilityDomain

原文最终定稿（“四部分”）：

```
CapabilityDomain {
    SemanticCapabilities      // 离散“能不能”
    NumericLimits             // 数值上限
    Guarantees                // 语义保证（非性能）
    Extensions                // 后端扩展
}
```

内部最好不是平表而是：

```
Capability {
    id
    parents[]        // 依赖闭包：generalIndirectAddressing -> indexed -> linear
    constraints[]    // parameter + range + set + predicate
}
```

闭包优先：设备只声明 `generalIndirectAddressing`，不需要重复声明三层（SPIR-V capability 机制的借用）。同理 `fp64Atomic -> fp64, atomic`。

约束形态支持 parameter + range + set + predicate（不只是枚举）：

```
VectorWidth >= 8
Float ∈ {fp16, fp32}
LocalStorage >= 48KiB
Atomic ∋ compareExchange
Addressing >= indexed
```

因此 region 可推 `Requires: LocalStorage >= 32KiB`；GPU A 有 64KiB，合法；GPU B 有 16KiB，非法。

合法性条件：`Req(R) ⊑ Cap(D)`（`⪯` = 偏序：`C₁ ⪯ C₂` 表示 C₂ 至少能正确实现 C₁ 所要求的语义）。

命名空间纪律：`core.*` 只描述跨硬件通用语义能力；vendor capability 只允许“优化 specialization”，不能成为普通 Core 程序正确运行的必要前提（除非用户明确选择 vendor-specific deployment），否则会慢慢变成 CUDA feature table。

`[提案]`。注意：与档案的硬约束见第 11 节 C-6。

### 3.8 PerformanceProfile

```
PerformanceProfile {
    scalarThroughput  vectorThroughput  matrixThroughput
    branchPenalty     divergencePenalty
    memoryLatency     memoryBandwidth
    dispatchLatency
    energyPerOperation
}
```

`[提案]`。与 Capability 的分家 = 第 8 节不变量 3。

注意：S-C 已给该对象的接口契约，本文必须服从而不是另立 `[已设计未实现]`（S-C 第 2.3 节）：

- 必填四项：`band`（不确定带，单点数字给人“精确”错觉 = 过度承诺）/ `model_id` / `model_ver` / `assumptions[]`
- 接口形态以 S-D 第 1.7.3 节的 `cost_model_query` 为准，本文不另立
- 契约 1（事实/模型分离）：成本事实 = 表条目字段；“如何用事实决策” = 编译器侧可替换件（HIT spec 第 3.3 节「表只描述材料，不描述放置策略」`[已设计未实现]`）
- 契约 2：缺失 = 保守退化，不猜
- 契约 3：相对量纲，不承诺绝对值、不承诺最优
- 契约 5 硬性：估计值不得呈现为 WCET 证明 / 时间上界；`MODELED` 必须明标“模型估计，非证明”
- 契约 6：成本估计只进 `MODELED` 层，不得与 `PROVED` 数字合并/覆盖/相减

因此本文的 `Cost(R,D)`（第 5.3 节）是 MODELED 层的量，其输出面必须按上述四项与两层不混报纪律交付。原文未提这一层，本文补上（这是写作义务，不是新增设计）。

### 3.9 RuntimeState

```
RuntimeState {
    Residency
    Queues
    Load
    Availability
}
```

| 槽 | 名 | 含义 | 仓库现状 |
|---|---|---|---|
| 0 | `rs_residency` | Materialization 索引视图 | `[提案]` |
| 8 | `rs_queues` | 每 domain 的待派发队列 | `[提案]`；最近既有物 = 每 M 一条本地 run queue（`sched.cr:64,82`）`[已实现]`，粒度不同（M = OS 线程，不是 domain） |
| 16 | `rs_load` | 域负载 | `[提案]` |
| 24 | `rs_avail` | 可用性（域当前是否可派发） | `[提案]` |

### 3.10 MAP 段条目

原文建议（第 21 节）：placement 信息附着在 region metadata，或单独增加 MAP section：

```
MAP entry:
    regionId
    mode              // AUTO / PREFER / REQUIRE
    domainName
```

最大原则（原文如此）：

> placement metadata 不应该改变 HDFG 的语义 identity。

即 `flow x { ... }` 与 `@preferredDomain(gpu) flow x { ... }` 语义图是同一张图，区别只进入 mapping。

| 槽 | 名 | 类型 | 含义 |
|---|---|---|---|
| 0 | `mp_region` | 下标 | region 标识（对应 `g_sgs` 下标或 DFNode 区间，实施阶段定） |
| 8 | `mp_mode` | 码 | `0=AUTO 1=PREFER 2=REQUIRE` |
| 16 | `mp_domain` | 名索引 | 逻辑域名（`AUTO` 时 `-1`） |
| 24 | `mp_flags` | 位域 | 保留 |

`[提案]`。表示代价 `[已实现]` 级实核见第 9 节，新增段不是免费的。

三态的实现建议（本文补）：原文说“或更干净地单独增加 MAP 映射 section”。本文倾向独立段，理由 = 不变量 1 的逐字节检查在独立段下可写成“摘除 MAP 段后其余段逐字节同”，而附着在 REG 记录内时该检查退化为“REG 记录字段数不变”，检查强度更弱。记入第 11 节 C-3（不裁决）。

---

## 四、能力格（Capability Lattice）

### 4.1 关系

```
HDFG Region
    ↓ infer
RequirementSet

ExecutionDomain
    ↓ declare
CapabilitySet

合法映射条件：RequirementSet ⊑ CapabilitySet
```

只有满足该条件的 domain 才进入 cost model。

严格分家：

```
Capability Model    解决：能不能运行
Cost Model          解决：在哪里运行更好
```

### 4.2 十个能力维度（不是 CPU/GPU/NPU 分类）

```
ExecutionCapability
├── Computation       scalar{int:[8,16,32,64] float:[16,32,64] } vector{widths,ops}
│                     matrix{elementTypes,tileShapes}  special{transcendental,complex,reduction,scan}
├── Control           branch loop dynamicLoop indirectCall recursion dynamicDispatch divergentControl
├── Parallelism       task data vector lane pipeline nested  maxConcurrency maxGroupSize
├── Storage           private groupShared domainShared persistent coherent
├── Addressing        direct indexed indirect random gather scatter pointerLike
├── Synchronization   event barrier groupBarrier  atomic{load,store,exchange,CAS,add,min,max}
│                     ordering{relaxed,acquire,release,sequential}
├── Communication     message stream peerTransfer asyncTransfer directRemoteAccess
├── Effects           externalCall syscall mmio deviceIO fileIO networkIO timer
├── Dynamism          dynamicAllocation dynamicGraph dynamicSpawn dynamicShape
│                     dynamicDispatch variableWorkgroup
└── Guarantees        deterministic preciseException orderedEffects
                      floatingPoint{ieee754,roundingModes,denormalHandling}
                      memoryConsistency{...}
```

`[提案]`。三条取自原文的设计要点：

1. `divergentControl` 不是说它“快”，只是“这种执行域能正确表示 lane 之间不同的控制流”。具体 divergence 多贵，由 profile 决定（= 不变量 3 的又一处实现）。
2. `Storage` 与 `Addressing` 必须分开，前者描述“可以有什么存储”，后者描述“计算如何访问数据”。一个 NPU 可能 `Storage: private, domainShared` / `Addressing: indexed`，但不支持 `indirect`/`pointerLike`，因此这种 region 直接被排除。
3. `Guarantees` 是合法性条件，不是性能条件，某段代码的规约要求 strict IEEE FP，某 accelerator 只有 relaxed FP，因此即使它再快也不能进入候选集。

### 4.3 格与闭包（论文核查后的加强）

- `Cap(D)` 应首先做闭包 `closure(Cap(D))`（第 3.7 节）。
- 偏序例：`FP16 ⪯ FP16+FP32 ⪯ FP16+FP32+FP64`；`indexed ⪯ gatherScatter ⪯ generalIndirect`。
- 因此合法映射 = `Req(R) ⪯ Cap(D)`。比几十个 `if capability_x` 干净。

### 4.4 不要照搬 SYCL 的设备类别

借用 SYCL 的“设备可查询自身能力”；不借“设备必须属于 cpu/gpu/accelerator 分类”。
因此不要 `Cap { gpu = true }`，而是 `Cap { fp64 indirectAddress dynamicControl matrix ... }`。
因此“两个都是通用 CPU，只不过 A 某类计算快、B 稍慢”完全没有特殊情况：相同 CapabilitySet，不同 Profile。

`[提案]`。

---

## 五、Placement 模型

### 5.1 基本单位

不要逐 DFNode 调度。基本单位 = Execution Region。

来源：HDFG region · `flow` · `loop` · `function`。之后 compiler 可进一步 region fusion / region split 得 ExecutionCluster。

```
DFNodes -> semantic regions -> execution clusters -> placement
```

例：

```
N1 N2 N3 N4
└────┬─────┘
   Region A          mapper 处理的是  A -> CPU / B -> GPU
N5 N6 N7
└───┬────┘
 Region B
```

而不是 `N1 CPU / N2 GPU / N3 CPU ...`，否则 transfer / dispatch 成本急剧增加。

`[提案]`。距仓库现状的距离（本文实核，见第 7 节）：region 归属数据 `[已实现]`，但现有 pass 的形状是函数粒度 + 逐 DFNode 区间扫描。

### 5.2 Cost Model

```
Cost(R,D) = C_compute + C_dispatch + C_input + C_sync + C_policy
```

| 项 | 含义 |
|---|---|
| `C_compute` | 该 region 在目标 domain 的执行时间 |
| `C_dispatch` | 启动/提交成本 |
| `C_input` | 所有输入 materialization / transfer 成本 |
| `C_sync` | 跨 domain 同步成本 |
| `C_policy` | 部署策略与 preferredDomain 的 penalty |

关键反模式：`preferredDomain` 不要作为绝对规则：

```
preferredDomain(gpu)  =>  cost(gpu) -= preferenceBonus
                      或  other domains += preferencePenalty
```

因此 GPU 极度不划算时仍然可以选 CPU。

论文核查后（加强）：

```
Score(R,D) = EFT(R,D) + FutureCost(R,D) + PolicyPenalty(R,D) + PreferencePenalty(R,D)
```

其中 `@preferredDomain(gpu)` 只改变 `PreferencePenalty`。因此用户指定 `@preferredDomain(gpu)` 但“GPU currently overloaded / transfer = 80ms / CPU = 2ms”时仍然可以 CPU，这个行为应明确写进 spec。

`[提案]`。

### 5.3 不只优化单个区域（避免 greedy 陷阱）

`A -> B -> C`，单独看 B：`CPU = 10 / GPU = 2`，似乎应该 GPU。但 `A CPU->B GPU = 8`、`B GPU->C CPU = 8`：

```
CPU: 10
GPU: 8 + 2 + 8 = 18
```

因此 B 应该留 CPU。

### 5.4 目标函数 = Makespan（论文核查后定稿）

```
min Makespan(G, P)        P : Region -> ExecutionDomain
约束：Req(R) ⪯ Cap(P(R))
再考虑：C_exec / C_materialize / C_sync / C_dispatch
以及这些操作之间是否可以 overlap
```

比 `min Σ Cost(R,D)` 更合理。

### 5.5 第一版算法：Residency-Aware HEFT，PEFT look-ahead

原文第 14 节流程：

```
1. 得到 ExecutionCluster DAG
2. 为每个 cluster：estimate execution cost on each domain
3. 为每条跨 cluster edge：estimate transfer cost
4. 按 criticality / upward rank 排序
5. 逐个选择 earliest finish domain
6. 应用 hard/soft placement constraints
```

Core 版比传统 HEFT 多一个 Residency，因此 Residency-Aware HEFT。

论文核查后（加强）：

```
HEFT baseline -> PEFT-style optimistic future cost -> Residency-aware adjustment
```

而不是只写 `pick minimum EFT`：`A -> B -> C`，B 是 `CPU = 10 / GPU = 2`，但若 C 只能在 CPU 上很好执行、`GPU -> CPU transfer = 20`，PEFT-style look-ahead 比纯 local EFT 更容易避免错误迁移。

### 5.6 Criticality 应该是 runtime 状态

`fastCpu` / `slowCpu` 例：若 region 不在 critical path，`R -> slowCpu` 可能完全没问题；把 `fastCpu` 留给 critical region 可能反而让整个程序更快。
因此 cost model 里应明确增加 `criticality(region)`，不要仅仅比较 region 自己完成时间。

### 5.7 静态 + 动态两阶段（职责划分）

```
Compile Time
├── infer requirements
├── enumerate legal domains
├── generate variants
├── optimistic costs
└── initial schedule

Runtime
├── actual sizes
├── current residency
├── current queues/load
├── dynamic criticality
└── final placement

静态部署：runtime mapper = erased
```

编译时知道：HDFG · dependency · region · operation · estimated data volume · static N · state edges。
编译时不知道：GPU 当前负载 · 输入的实际大小 · 实际 residency · 温度/功耗限制 · 其他任务负载。

原文 runtime 例：

```
R: CPU = 5ms, GPU = 1ms;  input = 400MB, currently DDR;  DDR->VRAM = 7ms
=> CPU 5ms / GPU 8ms => CPU
下一次数据已在 VRAM => GPU 1ms => GPU
```

因此这就是为什么 Residency 必须是一等映射信息。

`[提案]`。

### 5.8 Placement 约束的失效语义（原文第 6 节，本节最硬的一条）

```
automatic mapping
      │
      ├── 找到更优 execution domain -> use it
      │
      └── 没找到 -> 通用下降路径（HIT 原文假设义）
```

但 `@executionDomain(gpu)` 不同：

| 注解 | 目标域不存在时 |
|---|---|
| `@executionDomain(gpu)` | ERROR，不能不报错地 fallback，否则硬指定失去意义 |
| `@preferredDomain(gpu)` | fallback，automatic，通用路径 |

因此见第 8 节不变量 5。

### 5.9 `@executionDomain` 的性质：deployment constraint，不是 program semantics

```
⟦R_HIT⟧ = ⟦R_CPU⟧ = ⟦R_GPU⟧
```

语义完全相同，只是 execution mapping 不同。因此：

- semantic equivalence 不应因 CPU vs GPU 改变；
- 若 deployment 无法满足 `@executionDomain(gpu)`，那是 mapping failure，不是 semantic/type error；
- 诊断最好单独归类 `EMAP…`，而不是 TF/TK 一类类型错误。

因此本文补：`EMAP` 开族在仓库里有明确的制度位置 `[已实现]`：错误码分块（`docs/developer/errors.md` 分节 L0xx/P0xx/N0xx/I0xx/TA0xx/TF0xx/TB0xx/TU0xx/TC0xx/TM0xx/TK0xx/TS0xx/TG0xx/B0xx/R0xx/V0xx）与 fail-closed 门（`diag.cr` 的豁免表 `diag_gate_exempt`）+ 常量块（`ast.cr:331+`，P0xx = 1001–1029 / N0xx = 2001+）。
因此实施阶段须同阶段：新常量块（数值 + 文档节 + 门注册 + 豁免表重定）。这是既有纪律，不是本文新增要求。

### 5.10 variant 与避免组合数量激增

一个 region 可存在多个 lowering：

```
Region R
Variant:   HIT（原文假设义） / CPU / GPU
```

语义相同，只是 mapping 不同。第一版规则（原文第 17 节）：

```
HIT variant              -> 永远存在
hard executionDomain     -> 只生成指定 domain + HIT 验证参考（可选）
preferred / automatic    -> 只生成 Top-K 候选      例如 K = 2
```

因此正常桌面 `R: HIT / CPU optimized / GPU` 已经够了。不能每个 region × 每个 domain × 每种 optimization 全生成。

### 5.11 Backend 接口（概念面）

```
canLower(region, domain)
estimateCost(region, domain)
emitVariant(region, domain)
```

不要让 mapper 直接 `if GPU ...` / `if CPU ...`，因此新增硬件只需要实现 backend。

`[提案]`。注意：与 S-C 第 0.0 节的硬约束一致：`禁止为 SIMD / CUDA / NPU 各开特判通道（与 第 1.2.2 节「禁止内建特判」同构）` `[已设计未实现]`。

### 5.12 静态部署模式

```toml
[execution]
mapping = "static"
```

编译时直接 `R1 -> CPU0` / `R2 -> accelerator0` / `R3 -> CPU0`，binary 里没有 dynamic mapper。
因此同一模型同时支持：desktop dynamic · server dynamic · embedded static · bare-metal static。

### 5.13 部署策略（职责分离）

```toml
[execution]
objective = "performance"      # 以后可：performance / latency / energy / balanced
```

源码：`@preferredDomain(gpu)` 描述 placement 偏好。
部署：`objective = energy` 描述环境策略。
因此这两个职责必须分开；不要把这些变成源代码 annotation。

---

## 六、Residency 与 Materialization

### 6.1 数据不属于 CPU 或 GPU

假设 Entry X：语义仍然只有 `X`，不存在 `X_cpu` / `X_gpu`。

注意：本次措辞升级（旧稿此处写 `DDR -> valid / VRAM -> valid`，那是缓存副本措辞，隐含“有权威值 + 可复制 + 副本同值”三假设）。新形态：

```
Semantic Entry X                ← 语义对象：identity + version（不挂在任何域上）
    │
    ├── Materialization @ DDR    recipe / identity / version / authority / location / persistence / replicability
    └── Materialization @ VRAM   同上七字段
```

因此 CPU，GPU 数据迁移的语义不是 `copy X into another X`，而是 materialize X in target memory domain。
因此源码永远不应该出现 `copyToGpu()` / `copyToCpu()` / `cudaMemcpy()`。
因此注意：并且：新框架下还需检查 `replicability`，若该 Entry `replicability = forbidden`（一次性 token / 线性资源），则“在 VRAM 再物化一份”本身非法，不是“贵”。旧稿的 `valid` 位模型无法表达这一档（它默认副本总是允许的）。

### 6.2 自动 transfer

图 `Region A -> Region B`，placement `A -> CPU` / `B -> GPU`：mapper 检查依赖 Entry（`A produces X` / `B consumes X`），因此自动规划 `materialize X in VRAM`。
最终后端可能下降成 DMA / PCIe transfer / shared memory mapping / zero-copy / unified memory，这些都不是 Core 语义。

### 6.3 Materialization 是可调度 operation（不是成本项）

原文 第 “Transfer 不能只是成本”：

```
CPU compute
       \
        Materialize(X, VRAM)
                \
                GPU compute
```

因此 materialization 可以 prefetch / async / overlap compute / pipeline。
因此未来不是 `T = Compute + Transfer` 这么简单，而可能 `T ≈ max(Compute_A, Transfer)`（若二者能 overlap），这会极大影响 mapper。

注意：本次划界：`prefetch` / `async` / `overlap` 是 mapper strategy（第 0.2 节），不属格层。格层只回答“这个 materialization 合法吗 / 与谁可共存 / 代表哪个 Entry+version / 这个转换保语义吗”；“要不要预取”是 mapper 的决定。

### 6.4 驱逐不变量的改写（新输入的核心修订）

>  式的权威版本 = `docs/academic/cache-semantics.md` 规则 2′（改式先改权威版本；本处为引用）。
> 同标注见 `materialization-space.md` 第 4.2 节（权威侧已标）。本文按同一权威版本引用，不另立。
> 注意：与权威侧的分工：第 4.2 节 = 新式与旧规则的逐条对照（R1–Rn 反例表）+ 权威版本指针；
> 第 4.3 节 = 该式的检查形状（怎么测）；第 4.4 节 = 该式的 fail-closed 规则（必配）；第 4.5 节 = `recipe = unrecomputable` 的显式约束。
> 本文第 6.4 节只保留执行映射侧要用的那句式 + 第 8 节8 的检查（其检查与权威第 4.3 节的「断言形状」互补，不重复）。

旧表述（本文旧稿，照 cache-semantics 规则 2/3）：

> 所有东西都可以驱逐，只要能重算或写回。

新表述：

```
Evictable(x)  ⟺  Recoverable(x) ∨ PreserveRequiredState(x)
```

即一个 materialization 能消失，当且仅当：

- 之后能重新得到等价状态（`Recoverable` = 缓存实例里的“有方法可重算”）；或者
- 消失前已经把必须保留的状态转移到其他合法 materialization（`PreserveRequiredState`）。

`[提案]`。这比“缓存驱逐”更一般，它不预设“有 backing store”（假设 5）也不预设“副本同值”（假设 6）。

与既有规则的关系（本文分析）：旧规则 2/3（驱逐不变量 `⟦G ∖ storage(e)⟧ = ⟦G⟧` / 再生等价）对应新式的第一支 `Recoverable`；规则 4b 的“驱逐必写回”对应第二支 `PreserveRequiredState`。
因此规则 2/3/4b 并未被推翻，它们是新式在缓存实例上的取值。这正是“缓存降级为特例”在驱逐面上的对应位置。
因此，旧稿第 6.5 节登记的那条“实质张力”（规则 4b vs 副本模型）在新框架下解除：规则 4b 是第二支的正例，不是例外规则。见第 11 节 C-2（状态由“待裁”改为“已被新框架涵盖，仅待维护者确认”）。

### 6.5 接缓存语义，注意：方向反转（本次最重要的改写）

原文第 8 节说“应该直接和 Core 已经有的 cache semantics 接起来”。旧稿的解释是错的，它把 cache-semantics 规则当成层本体，于是写成“本文的 Materialization 模型 = 规则 5 + 规则 6 的展开，不是新本体”。

新输入下的正确方向：

```
旧（错）：  materialization 模型  ⊂  缓存语义规则        （缓存 = 本体，materialization 是它的实例）
新（对）：  缓存语义规则  ⊂  存在格 / Materialization Space（缓存 = 映射实例，materialization 是本体）
```

原文的直接引语：

> 图，存在格 / Materialization Space，编码
> 缓存语义 = 经典可再生值的一种映射规律

因此本文旧稿第 6.4 节的“逐条对表”必须反向读，那些规则不是本文的语义依据，而是缓存这一映射实例的规律。改写后的对照表（列序已反转，并标出哪些规则在新框架里不再是普遍的）：

| 缓存语义规则（映射实例规律） | 在存在格中的位置 | 出处 |
|---|---|---|
| 规则 1 值 = 方法 | 对应 `recipe = recomputable` 一档的身份来源；`recipe = unrecomputable` 档不适用 | `cache-semantics.md:24` |
| 规则 2 驱逐不变量 | `Evictable` 的第一支 `Recoverable` 的一个实例 | `:25` |
| 规则 3 再生等价 | 同上（`Recoverable` 的机制保证） | `:26` |
| 规则 4 边界公理 | 对应 `recipe = unrecomputable` + `authority = device/external` | `:27` |
| 规则 4b 图内不可重算 | 对应 `recipe = unrecomputable` + `persistence = 必须` + `authority` 不可转移 | `:28,50-59` |
| 规则 5 赋值 = 版本化 | 存在格的版本性在缓存实例上的投影（第 3.4.5 节末注） | `:29,61-67` |
| 规则 6 地址 = 映射 | 属编码/映射面，不入存在格 | `:30,69-71` |
| 规则 7 映射实例正确性 | 正是“缓存是映射实例”这条的既有规则形态，它本来就是“任何映射实例的正确性标准” | `:31,73-75` |

因此规则 7 是新旧框架的接缝：它早已写成“任何映射实例（区域/arena/字节权限/寄存器）的正确性标准是同一个”，而不是“缓存是本体”。新输入把这个早已写下的普遍性提到了层名上。
因此规则 7 已给出 `mapping preservation proof` 的既有定理形态（“映射正确性定理”），原文说“甚至可以以后接形式化验证”，仓库已经把这条通路写成规则了。
因此本文旧稿“本文的 Materialization 模型不是新本体”这句已作废：按新输入，存在格就是本体层，而缓存才是实例。

### 6.6 缓存 = 特例（七字段取值表）

新输入给的检查（照录）：缓存只是

```
recipe = yes
replicable = yes
evictable = yes
authority 可转移/可重建
```

的特例。MMIO 例：`recipe = no / replicable = no|limited / persistent = external / authority = device`。

完整取值对照见第 3.4.2 节；六个被“缓存”带进的假设及其反例见第 3.4.4 节。

### 6.7 policy 不属格层、也不属执行域层（本次显式划界）

> 注意：与第 0.2 节同命题，权威版本同上：`materialization-space.md` 第 5 节（含第 5.1 节明写归属 + 第 5.2 节可检验划界检查）。
> 本节 = 执行映射侧的归属表（本文特有），检查不在此复述。

新输入点名四类 mapping strategy，LRU / write-back / write-through / prefetch，以及问题“GPU 是否保留 residency”：

> 这些都应该是 mapping strategy，不是格层语义。

因此本文的归属：

| 事项 | 归属 |
|---|---|
| 哪些 materialization 合法 / 哪些可共存 / 哪些代表同一 Entry+version / 哪些转换保持语义 | 存在格（本体，归 `materialization-space.md` 第 2.1 节四问） |
| 什么时候驱逐 · 放寄存器还是 RAM · GPU 是否保留 residency · LRU / write-back / write-through / prefetch | mapper（本文第 5 节；检查见权威第 5.2 节） |
| 换域要付多少代价 | mapper cost model（第 5.2 节，S-C 第 2.3 节契约） |

因此见第 8 节不变量 9。旧稿把这四类策略混在第 6 节里叙述（例如第 6.3 节原文的 prefetch/overlap 段落），本次已划出。

### 6.8 与并发的统一（原文第 29 节）

`go f()` 和 execution mapping 不应该冲突。动态 HDFG 产生的新 region 依然可以 runtime placement：

```
spawn region R -> mapper -> CPU1 / CPU2 / GPU
```

因此异构 execution model 与现有动态图模型统一，而不是另造 GPU concurrency。

注意：本次重述（旧稿此处写“缓存语义”作为统一依据，按第 6.5 节的层归属已过时）：统一所依据的不是缓存语义，而是存在格，`spawn` 产生的新 region 只是新的语义对象，其 Entry 的物化/迁移与静态 region 走同一套 `materialization` 规则（第 3.4 节七字段对两者一视同仁：`recipe` / `authority` / `replicability` 与“是否并发产生”无关）。
因此这正是新框架的收益之一：并发不是缓存的特殊情形，因此不需要“GPU 专用并发模型”。

`[提案]`。最近既有物 `[已实现]`：并发 = Go 风格 GMP 简化（P 并入 M，M 数量 = CPU 核数；`docs/maintainer/design/execution-model.md:75-77`）；`go f(args)` 语义 = 分配 G + 16KB 栈 + 新 arena，状态 `_Grunnable`，投递到 M 的 local run queue（同文档第 3 节 3.2）；实现 = `sched_go`（`src/stdlib/sched.cr:171`）= `g_new + sched_enqueue`。
因此接线点 = `sched_enqueue`（放置决策的插入位置），但队列是 per-M 而非 per-domain，因此距离 = “队列键从 M 换成 ExecutionDomain”，不是新增调度器。

---

## 七、与既有 pass 的接线（本文补，原文无）

### 7.1 三个安全 pass 的实核消费面

| pass | 入口 | 形状 | 区间 | 接线 |
|---|---|---|---|---|
| `ptr_analysis.cr` | `ptr_analysis_all()`（`:346`），`ptr_analysis_func(nstart, ncount, vstart, vcount)`（`:172`） | 函数粒度：`loop { if fi >= g_ir_func_count { break; }`，内层 `loop { if ni >= nstart + ncount { break; }`（`:193`） | 逐 DFNode |
| `region_check.cr` | `region_check_all()`（`:160`），`region_check_func(nstart, ncount)`（`:105`） | 函数粒度：内层 `loop { if ni >= nstart + ncount { break; }`（`:107`） | 逐 DFNode |
| `provenance_verify.cr` | `provenance_verify_all()`（`:135`），`provenance_verify_func(nstart, ncount)`（`:52`） | 函数粒度：内层 `loop { if ni >= nstart + ncount { break; }`（`:54`） | 逐 DFNode |

接线点 `[已实现]`：`src/compiler/main.cr:638-640` 顺序调用三者。

### 7.2 region 归属数据 已存在（原文第 7 节的“基本单位”有现成基础）

| 物 | 位置 | 内容 |
|---|---|---|
| `g_df_node_region` | 写点 `dataflow.cr:103`（`w64(g_df_node_region, nid * 8, g_cur_sg)`，`-1 = none`）；增长 `dyn_arr.cr:811-813`；消费 `region_check.cr:5-10` | node，owning SG，O（1） 查询（`subgraph_containing()`） |
| `g_sgs` region 表 | `ESZ_SG : int = 48` + `OFF_SG_KIND/ENTER/EXIT/PARENT/NSTART/NCOUNT`（`dyn_arr.cr:146-152`） | region 已带 `[NSTART, NSTART+NCOUNT)` 节点区间 |
| region kinds | `SG_FUNC=0 / LOOP=1 / FOR=2 / FLOW=3 / UNSAFE=4 / IF=5`（`dyn_arr.cr:154-159`） | 原文第 7 节的“来源：HDFG region · flow · loop · function”逐一对得上 |

### 7.3，因此距离判定（诚实版）

原文第 7 节「不要逐 DFNode 调度」：

- 数据面：`[已实现]`，region 区间 + node，region 映射都在，且 region 已经是索引区间。
- pass 形状：不是 per-region。三个 pass 都是“遍历函数节点区间、按需调 `subgraph_containing()` / `pa_in_unsafe()`”。
注意：且 `pa_in_unsafe()`（`ptr_analysis.cr:15-30`）每次调用都全扫 `g_sg_count` 个 SG，O（SG） per node，已被 QC 化为 O(nodes × SGs）。
- 因此距离 = pass 重构（把“逐节点 + 内层查归属”改成“逐 region 外循环”），不是新增 IR 或新增归属数据。
- 因此且重构顺带修一个既有复杂度问题（上条 O（nodes×SGs）），实施阶段应把这条作为收益而非纯成本记入。

### 7.4 与 S-C 六段流程对齐（不要另立第二条流程）

S-C 第 2.1 节 `[已设计未实现]`：

```
1 事实推导（图 pass）      依赖闭包 / 效应集 / 使用计数 / 索引来源 / 生命周期
2 候选生成（可判定性门）    每条变换附合法性前提清单；前提不可判 -> 候选缺席（保守）
3 成本评分（成本模型接口 ← 表成本事实 + 资源约束）
4 选择（策略数据：目标描述 + 阈值/约束）
5 记录（决策记录 -> 第5）
6 发射（实例层：编码 / 布局 / 调度）
```

本文的 placement 流水线逐段对齐：

| 本文段 | S-C 段 |
|---|---|
| Requirement Inference | 1 事实推导 |
| capability compatibility（`Req ⊑ Cap`） | 2 候选生成 |
| Cost + Topology + Residency + Criticality + FutureCost | 3 成本评分 |
| Placement Solver + `@preferredDomain`/`@executionDomain` | 4 选择 |
| Mapped HDFG | 5 记录 |
| Variant Selection，Backend | 6 发射 |

因此本文不另立流程；placement 是 S-C 六段在“跨执行域”方向的实例化。实施阶段必须服从 S-C 的 L1–L7 裁决与第 2.3 节成本模型契约。

### 7.5 S-C 第 2.2 节的分界 = 本文第 8 节不变量 3 的既有契约

S-C 第 2.2 节表（`[已设计未实现]`）：

| 层 | 检查 | 性质 | 失效后果 |
|---|---|---|---|
| 合法性 soundness | 图前提（无依赖路径 / 无效应 / 索引仿射可证 / …） | 可判定（保守：unknown = 否） | 该变换不选，语义不变 |
| 收益 profitability | 成本估计 + 阈值 | 启发式（可错，待论证） | 只影响性能，绝不影响语义 |

关键性质（S-C L3）：任何变换的缺失都可接受，直接形态恒合法。

因此本文的 `Req ⊑ Cap` 必须落在“合法性”行，`Cost(R,D)` 必须落在“收益”行。这就是不变量 3 的完整形式。

---

## 八、不变量表（本文核心交付）

> 每条给：形式陈述 / 可执行检查的形状 / 三态 / 违反后果 / 反向断言。
> 检查写法遵既有纪律：检查组须有正反两条断言（反向断言当场失败 = 最好的诊断）；单向检查对反向缺陷总是通过。

### 不变量 1：placement metadata 不改变 HDFG 的语义 identity

- 形式陈述
  ```
  对任意 ExecutionRegion R 与任意 placement 注解集 A：
      ⟦HDFG(erase(A) ⊕ R)⟧ ≡ ⟦HDFG(R)⟧
  加强（逐字节）：serialize(HDFG(erase(A) ⊕ R)) == serialize(HDFG(R))
  其中 erase(A) 删除全部 AUTO/PREFER/REQUIRE 元数据，不动任何值流/state edge/region 结构
  ```
 等价于：`erase(annotations)` 后语义图逐字节同（原文原则：“`flow x { }` 和 `@preferredDomain(gpu) flow x { }` 语义图是同一张图”）。

- 可执行检查的形状（将来怎么测）
 1. 正向检查（同源对拍）：同一 `flow` 区域取两版源码（有/无 placement 注解），`corec cir` 产物 `.cir` 逐字节 `cmp`；`corec ccr` 产物同理。
注意：必须限定条件（本文实核的陷阱）：新增的逻辑域名是编译期 interned 串，若域名进 STR 段，`.ccr` 会多一条串，检查“逐字节同”必假。检查须写成 「摘除 MAP 段后，其余段逐字节同」（或域名不进 STR 段、改走部署配置侧索引）。这是一条会让检查误报失败的已知机制，必须写进检查文本。
 2. 反向检查（正控 = 注解确实生效）：MAP 段非空 + dump 面确实显示 domain constraint（否则“什么都不做”也总是通过 = 覆盖为零）。
因此检查对 = {其余段逐字节同} × {MAP 段非空}；缺任一条 = 检查集合失效。
 3. 结构检查：`erase(A)` 后 `.ccr` 段数回到基线、版本不变。
 4. 端到端检查：两版源码 `build` 产物在同一目标描述下，值/效应序/rc/输出一致（对齐 S-C 第 3.2 节检查 1「观测等价：同程序 + 不同目标描述，值/效应序/rc/输出一致」的镜像方向）。

- 三态：`[提案]`（无 MAP 段）。但语义半边的定位点 `[已设计未实现]`：S-C 第 3.2 节反向泄漏检测 `b) 决策结果被写回图/源码语义 => 违反，登记为「泄漏待归一」`，仓库已定义该不变量，只是没有表示物。
- 违反后果：placement 泄漏进语义 = 换部署改语义，因此直接击穿 S-C L2 裁决（“优化 = 映射选择，非图修改”）与 L1（机器形状不进程序意义）。
- 反向断言：构造一个故意把 domain 名写进值流/类型的最小改动，断言检查 1 当场失败。做不到，因此检查是真空的。

### 不变量 2：`ExecutionDomain ≠ MemoryDomain`（不得合并）

- 形式陈述
  ```
  ¬∃ 双射 f : ExecutionDomain -> MemoryDomain 使得 f 保持全部映射语义
  更强的可观测形式（存在性证明，反证合并）：
    (i)  ∃ d₁ ≠ d₂, ∃ m :  d₁ attach m  ∧  d₂ attach m          （多执行域共一内存域）
    (ii) ∃ d, ∃ m₁ ≠ m₂ :  d attach m₁  ∧  d attach m₂          （一执行域多内存域）
  两者皆可满足 => 合并会丢信息 => 不得合并
  ```
 原文例：`CPU0/CPU1/NPU -> DDR` 且 `GPU -> VRAM` 满足 (i）；`CPU/GPU/NPU -> UnifiedMemory` 满足 （i）+(ii）。

- 可执行检查的形状
 1. 配置检查：部署配置构造 （i）/（ii） 两例，断言 mapper 的候选域索引与 residency 键空间是两个独立 id 空间（不共用 id 分配器、不互相索引）。
 2. 检索检查：给 `(d, m)` 对，`attachedMemoryDomains(d)` 与 `attachedExecutionDomains(m)` 是两个分别回答的函数（一域多内存、一内存多域都能答）。断言二者不同构（存在 （i） 例，因此前者非单射）。
 3. 负控（关键）：把两表合成单表（强制一一对应），上述配置检查必须当场失败。若合成后仍通过，说明检查没有真正约束合并。
 4. 前端检查：`@executionDomain(X)` 的 X 只能解析到 ExecutionDomain 命名空间；解析到 MemoryDomain 名必须是硬错（且不是 TF/TK 码，第 5.9 节）。

- 三态：公理 `[提案]`。仓库无 `MemoryDomain` 名词（本会话全仓 grep `MemoryDomain|TopologyLink|ExecutionDomain` 零命中）。注意：最接近但不同的既有物 = [region-model.md](region-model.md) 的图绑定区域（字节域，`[已实现]` 分配器面），它只是内存侧的一个映射实例（规则 7），不是 domain 表，不可拿它充当 MemoryDomain。
- 违反后果：合并后无法表达“统一内存”与“两 CPU 共一 DDR”两类真实硬件，因此模型对第一版就要覆盖的 CPU↔CPU 假异构（第 10 节 M4）直接失效。
- 反向断言：见负控 3。

### 不变量 3：`Capability ≠ Performance`（合法性 vs 优劣分家）

- 形式陈述
  ```
  合法性判定  legal(R, D) := Req(R) ⊑ closure(Cap(D))      ，只读 CapabilityDomain
  收益评分    score(R, D) := f(Profile(D), Topology, Residency, Criticality, RuntimeState)
                                                            ，只读性能/物理/运行期面

  组合规则 = 先后过滤（不是加权和）：
      candidates(R) = { D : legal(R, D) }
      placement(R)  = argmax_{D ∈ candidates(R)} score(R, D)

  两个方向都必须成立：
    (a) Capability 缺失 => D ∉ candidates(R)，且不能被 score 翻盘
    (b) 性能缺失 => D 仍 ∈ candidates(R)（退化用默认形态），且不得使非法 D 成为候选
  ```
注意：硬性：`legal` 是可判定量（unknown，因此否，保守）；`score` 是启发式量（可错）。二者不得进入同一个加权和，否则“极便宜的非法域”会被选中。

- 可执行检查的形状
 1. 检查 (a）：构造 `Req ⊄ Cap(D)` 但 `score(D)` 极小（如成本恒 0）的配置，断言 `D ∉ candidates` 且 `placement ≠ D`。防“成本翻盘合法性”。
 2. 检查 (b）：构造 `Req ⊑ Cap(D)` 但 profile 全缺失（或 `UNKNOWN`），断言 `D` 仍可被选中、程序仍编译、行为正确。防“缺成本 = 不可执行”。
注意：此检查须与 S-C 第 2.3 节契约 2/5 对账：缺失 = 保守退化，不猜；且不得用“经验常数”默认成 `MODELED`。
 3. 正反两条断言：检查 1 与检查 2 互为反向断言，只写检查 1 会把实现逼成“成本永远不生效”；只写检查 2 会放过“成本翻盘”。必须同时在场。
 4. Guarantees 单独一条检查：构造 `Guarantees` 不满足（如 strict IEEE FP vs relaxed FP 域）但 `score` 极优，断言不入选。这是“合法性条件不是性能条件”的专项断言。

- 三态：仓库已有对应分界的明文 `[已设计未实现]`，S-C 第 2.2 节「合法性 soundness = 可判定 / 收益 profitability = 启发式」表 + L3 裁决（“合法性可判定、收益启发式（分离原则）”）+ 关键性质“任何变换的缺失都可接受，直接形态恒合法”。
因此本条的检查形态直接对齐 S-C 第 2.2 节的列语义，不另立分界。
- 违反后果：击穿 S-C L3；且把“能否正确执行”与“哪个更快”混成一个数，因此引入不报错地错误映射（非法域被选中），这是本设计最危险的失效形态（不报错地 rc=0 类）。
- 反向断言：见检查 3。

### 不变量 4：materialization 只回答「是哪个 Entry Version 的物化」＋ 七字段完备

- 本次加强：旧稿此条只有 `(entry, version, memory_domain, home?, valid)`。按新输入升级为七字段（第 3.4.2 节），并删除 `valid`（它是缓存假设 #6 的残留，被 `authority` 取代）。

- 形式陈述
  ```
  Materialization := (recipe, identity, version, authority, location, persistence, replicability)
                     + mapper 侧附加（mt_materialize_op, mt_memd ， 不属格层，第〇.2）

  必须（正）：
    每个 Materialization 携带精确的 (identity, version)
    每个 consumer 的读必须指定 version（版本来自图，不来自运行期比较）
    version 是定义性字段（存在格的版本性），不是被观测出来的
    authority 唯一确定：任一时刻至多一个 authoritative materialization（或其权威在 device/external）

  禁止（负）：
    ¬∃ 谓词 newer(m₁, m₂)   ，不存在"哪份更新"的全局比较
    ¬∃ 查询 latest(entry)   ，不存在"取最新副本"的接口
    ¬∃ valid 位             ，"新鲜度"不是格层谓词（authority 取代之）
    ¬∃ 消费者按「值相等」判定可复用（值比较不是版本代数）
    ¬∃ 对 replicability = no 的 Entry 生成第二份 materialization（复制本身非法，第3.4.4 #2）

  驱逐/再生语义按字段分档（旧稿写"按配方案别"，本次改为字段驱动）：
    recipe = yes            -> 可跨域再生（Recoverable，第6.4 第一支）
    recipe = no  ∧ persistence = 必须 -> home 必填、驱逐必写回（PreserveRequiredState，第二支）
    replicability = no      -> 不得复制；迁移若非"移动"语义则非法
  ```
- 可执行检查的形状
 1. 正向检查（原子性）：构造 `X1@DDR` 与 `X2@VRAM` 同时存在，断言 GPU 消费 `X2` 时必须产生 `materialize(X2 -> VRAM)`，不得复用 `X2@DDR`（域错）也不得误用 `X1@VRAM`（版本错）。两向都给期望值（域错与版本错各一条档）。
 2. 接口检查（结构性）：静态扫消费面，断言不存在 `latest()` / `newest()` / `valid` 位 / 跨域 `max(version)` 之类的查询点。注意：检查须限定为“跨 MemoryDomain 的比较”，同域内的版本推进比较（存在格的版本性）不违反本条。不加限定 = 检查会对合法实现总是失败（过判）。
 3. 分档检查（本次按字段重述）：对 `recipe = unrecomputable` 条目断言：`persistence` 必填、跨域“再生”路径不可用（必须写回而非重跑）；反向对 `recipe = recomputable` 断言可驱逐可再生。正反两条断言：只写前一条会把所有条目都当不可再生（过判）。
 4. `authority` 检查（本次新增）：断言至多一个 authoritative materialization（或权威显式落在 `device`/`external`）；反向：构造两份都标 authoritative，因此必须硬错。注意：这是唯一能抓住“副本同值”假设回归的检查。
 5. `replicability` 检查（本次新增）：对 `replicability = forbidden` 的 Entry，断言“再物化一份”路径不存在/被拒（而不仅是“贵”）；反向：对 `replicability = free` 断言复制合法。这是旧框架完全无法表达的一档（旧 `valid` 位模型默认副本总是允许）。
 6. 版本可折叠（防过判）：`X1` 与 `X2` 在版本代数上可证等价（如 `x = x + 0` 类），因此允许复用。注意：但不得靠值比较实现，检查要能区分“按代数折叠”与“按值相等折叠”（后者须红）。
 7. 逐字节检查：物化动作的注入不得改变语义图（与不变量 1 共用正向检查）。

- 三态（本次实核修正）：注意：不是“核心字段都已实现”，逐字段距离见第 3.4.5 节。摘要：七字段中 `identity`（`def_nod`，`dyn_arr.cr:139`）与 `version`（仅盘面，`ccr_io.cr:173-176`）是 `[已实现]`；`recipe` 与 `persistence` 是 `[已设计未实现]`（槽位预留、值恒默认）；`authority` / `location` / `replicability` 零命中，`[提案]`。
注意：盘面/内存不同构（`ccr_io.cr:175`：内存 `ESZ_ENTRY` = 24B 无 version 字段），实施阶段须显式处理这个不对称。
- 违反后果：退回“哪块内存最新”的 mutable-memory reasoning，因此跨域读错版本 = 不报错地错误值；或对不可复制资源生成第二份副本 = 语义非法却 rc=0。
- 反向断言：见检查 3 的双向、检查 4、检查 5。

### 不变量 5：hard constraint 不可不报错地降级

- 形式陈述：`@executionDomain(X)` ∧ `X` 不可用，因此 mapping failure（硬错，rc=1，零产物）。不得回落 automatic、不得回落通用路径、不得 rc=0。
- 检查形状：负控档 = 目标域不存在（部署配置里无该键），断言 `rc=1` + 诊断含 `EMAP` 码 + 零产物。
注意：面纪律（既有裁决）：被 build-scope 豁免的码在 build 面「零产物」恒假，因此负控须写 `check` 面 rc=1 + 含码；豁免表须随硬错化重定。
 正反两条断言：`@preferredDomain(X)` 同配置，因此 rc=0 + 回落（防“一律报”）。
- 三态：`[提案]`。检查纪律 `[已实现]`（fail-closed 门 + 豁免表 `diag_gate_exempt`）。
- 违反后果：硬指定失去意义（原文：“否则硬指定就失去意义”）；且是不报错地类缺陷（rc=0），本仓最重视的失效形态。

### 不变量 6：静态部署下 runtime mapper = erased（同一语义，无第二条路径）

- 形式陈述：`mapping = "static"` 时，`R -> D` 在编译期确定；产物中不含 dynamic mapper；且判定结果与 dynamic 模式一致（同一 `Req ⊑ Cap` 判定，同一 hard/soft 语义）。
- 检查形状：同源码两种 `mapping` 模式，断言 （i） static 产物中无 mapper 符号/无运行期域查询；（ii） 两者都不违反不变量 1（语义图同）；（iii） static 下 `@executionDomain` 不可满足仍是硬错（与 5 同判）。
 正反两条断言：（i） 的正控 = dynamic 产物确实含 mapper（否则“删了 mapper”和“从未生成”不可区分）。
- 三态：`[提案]`。
- 违反后果：嵌入式/裸机支持变成第二条代码路径，因此语义分叉。

### 不变量 7：未指定，因此恒存在合法映射

- 形式陈述：AUTO（无注解）的 region 恒存在至少一个合法域。这是“通用下降路径”的形式化。
- 检查形状：对全语料（`tests/suite/*.cr` + `src/compiler/*.cr` 自身）断言 AUTO region 的 `candidates(R) ≠ ∅`。覆盖为零的检查只会失效不报错，故须挂到既有语料 runner 而非独立小档。
 反向断言：构造一个 `candidates(R) = ∅` 的畸形配置，因此断言它是硬错而非不报错地。
- 三态：`[提案]`。注意：依赖 C-1 的裁决，若通用路径不是 HIT（表机制），则本条的“通用域”身份待定（C-1 待裁点 （b）/（c））。
 本次记录：本注一度被改为“本条目前不可判定”（依据维护者口述「HIT M2 早已淘汰」）；经四处书面记载校正后已回退到本句（维护者改裁「以书面为准」，详见 C-1 的裁决反转记录）。

---

### 不变量 8：`Evictable(x) ⟺ Recoverable(x) ∨ PreserveRequiredState(x)`（本次新增）

>  式的权威版本 = `docs/academic/cache-semantics.md` 规则 2′（同第 6.4 节；改式先改权威版本）。
> 本条的检查 = 执行映射侧视角；权威侧的断言形状见 `materialization-space.md` 第 4.3 节（怎么测）、第 4.4 节（fail-closed 必配）、第 4.5 节（`recipe = unrecomputable` 的显式约束），三者互补，不互为替代。

- 形式陈述
  ```
  Evictable(x) ⟺ Recoverable(x) ∨ PreserveRequiredState(x)

  Recoverable(x)           := recipe(x) = yes ∧ 存在合法路径重新得到等价状态
  PreserveRequiredState(x) := 在 x 消失前，必须保留的状态已转移到其他合法 materialization
                              （"合法"由不变量 4 的七字段判定，尤其 authority 与 replicability）

  推论（负向，必须同时成立）：
    ¬Recoverable(x) ∧ ¬PreserveRequiredState(x) => ¬Evictable(x)   ， 驱逐非法，不是"昂贵"
  ```
注意：关键：`Evictable` 是合法性谓词，不是性能谓词（与不变量 3 同类）。“驱逐它可以，但很慢”与“驱逐它不合法”是两个不同档，不得混。

- 可执行检查的形状
 1. 正反两条断言：（a） 构造 `recipe = unrecomputable` 且 state 未转移的条目，因此断言驱逐被拒（硬错/零产物），不是“执行了但慢”；（b） 构造 `recipe = recomputable`，因此断言驱逐合法。只写 （a） 会把所有条目当不可驱逐。
 2. 第二支专项断言：构造 `recipe = unrecomputable` 但 state 已转移到合法 materialization，因此断言驱逐合法。注意：这是“第二支”的唯一断言；缺它则第二支形同虚设（实现可以永远只走第一支而检查全部通过）。
 3. 合法性 ≠ 性能 的分离断言：构造 `Evictable = 真` 但成本极高，因此断言决策仍是 mapper 的选择（可能选择不驱逐），而不是格层把它标为非法。反向：`Evictable = 假`，因此断言任何成本都不能让它被驱逐（与不变量 3 检查 （a） 同形）。
 4. 与旧规则的一致性检查：对 `recipe = recomputable` 条目，断言新式与规则 2/3 的判定逐条一致（防“新式松到把缓存实例判错”）；对 `recipe = unrecomputable`，断言与规则 4b 的“必写回”一致。

- 三态：`[提案]`。既有规则 2/3/4b 是它在缓存实例上的取值 `[已设计未实现]`（文档面 `cache-semantics.md:25-28`）。
- 违反后果：把“非法驱逐”实现成“合法但慢”，因此不可再生状态被丢弃 = 不报错地语义破坏（本仓最重视的失效形态）。
- 反向断言：见检查 2（第二支）与检查 3（合法性/性能分离）。

### 不变量 9：格层不承担 policy（本次新增）

- 形式陈述
  ```
  格层判定的值域 ⊆ {合法 / 可共存 / 同一 Entry+version / 保语义}      ， 四问，全是判定性问题
  mapper 决定   ⊇ {何时驱逐, 放寄存器还是 RAM, 是否保留 residency,
                    LRU, write-back, write-through, prefetch}          ， 全是有向退化的策略

  禁止（负）：
    格层的判定输出不得依赖任何 policy 参数（阈值/历史/负载/时钟）
    格层不得出现 "preferred" / "hot" / "recently used" 之类策略谓词
    policy 缺失不得改变格层判定结果（可缺席性）
  ```
- 可执行检查的形状
 1. 可缺席性检查：清空全部 policy 配置（无 `objective`、无阈值、无 PGO 数据），因此断言格层判定结果逐条不变（与带 policy 时对拍）。这是本条最关键的一条检查，若格层判定随 policy 变，则 policy 泄漏进了格层。
 2. 策略词零命中检查：静态扫格层面（`materialization-space.md` 的规则 + 第 3.4 节字段 + 第 8 节148），断言无 `LRU` / `prefetch` / `hot` / `recent` / `write-back` 等策略词。注意：检查须限定在格层面，mapper 侧（第 5 节）必然有这些词，不加限定会总是失败。
 3. 正反两条断言：反向构造一个必须靠 policy 才能决定的问题（如“这两份等价 materialization 该保留哪份”），因此断言格层拒绝回答（返回“二者皆合法”），把选择留给 mapper。这说明格层判定里确实没有 policy。
- 三态：`[提案]`。既有同型纪律 `[已设计未实现]`：S-C L5「成本模型 = 数据 + 可替换组件…不进表；HIT spec 第 3.3 节「优化不走表」」，本条是它的姊妹规则（“策略不进格”）。
- 违反后果：policy 进格层，因此换部署改语义判定的可观测部分，因此击穿不变量 1 与 S-C L2。
- 反向断言：见检查 3。

## 九、表示：IR 与 `.ccr` 格式（代价实核）

### 9.1 `.ccr` 格式现状 `[已实现]`

| 项 | 值 | 位置 |
|---|---|---|
| `CCR_VERSION` | 9 | `src/compiler/ccr_io.cr:135` |
| `CCR_SEG_COUNT` | 8 | `src/compiler/ccr_io.cr:138` |
| 段 tag | `1=STR 2=SYM 3=NOD 4=ENT 5=REG 6=EDG` + `7=TYPE 8=IFACE` | `ccr_io.cr:138-140`；`docs/.../2026-09-09-lattice-ir-v7-format.md:50` |
| 头 | 16B = `{magic u32, version u32, seg_count u32, reserved u32}` | `ccr_io.cr:570-573`；格式文档第 2 节 |
| 段表 | `seg_count × 12B = {tag u32, offset u32, size u32}`，offset 相对文件头 | `ccr_io.cr:586,601-602`；格式文档第 2 节 |
| 版本检查 | `if ver != CCR_VERSION { return -1; }` | `ccr_io.cr:979` |
| 段号检查 | `if tg < 1 || tg > CCR_SEG_COUNT { return -1; }` | `ccr_io.cr:1006` |
| 段序检查 | loader 按规范序校验（`tg == ri+1` + 段体连续两检查） | 格式文档第 2 节注 |

### 9.2 新增 MAP 段的真实代价（原文只说“或者更干净地单独增加 MAP 映射 section”）

> 注意：本次前置更正（2026-09-20）：本节原按“加 MAP 段是既定路线”写的。现按 C-3 的下调，
> 七字段已确认不需要段（复用 `ENT.flags` 空闲位，另见 C-3 的 `location` 保留项），
> 且placement 按不变量 1 本就不该进 `.ccr`（它是语义 IR 实现方式）。
> 因此本节读作“若最终仍决定加段，代价是这些”，不是“将要加段”。

`[提案]` + `[已实现]` 代价面：

1. 必须 bump `CCR_VERSION` 9，10。
 理由：`CCR_SEG_COUNT` 8，9 使段表从 `96B` 变 `108B`，其后所有段的 offset 全部平移，文件布局整体改变。旧阅读器（v9）遇到 v10 会走 `ver != CCR_VERSION -> -1` 整类拒收，这是既有先例（`ccr_io.cr:135` 注：“v9-only（load 校验 ==9；拒 version≠9，D10 先例：v8 及更早整类拒收，不得不报错地当「段/字段缺席 = 空表」）”）。
2. `CCR_SEG_COUNT` 必须同步改（否则段号检查 `tg > CCR_SEG_COUNT -> -1` 会拒掉 MAP 段）。
3. `calc_ccr_size` + 段尺寸函数 + 写侧 + 读侧四处同改，这是既有“加段四面”纪律（先例：R2 P4 Task 2/3 加 TYPE/IFACE 两段的实施形态，见 `test_ccr_types.py` 结构断言）。
4. 不是“预留槽”：`reserved u32 = 0` 是唯一的 4 字节松弛，不是段指针；`9+` 只是编号空间（“预留 9+ 不占空间”，`ccr_io.cr:138`），加段必然改布局。
5. 两个既有占位主张（端口冲突） `[已设计未实现]`：`9+` 的既有注明用途 = 「驱逐标注段 v6.1 延续、证书段」（格式文档第 2 节注）。MAP 段将是第三个主张者。因此本次下调：MAP 不必加段（见第 9.2 节前置注 + C-3），因此 MAP 退出该争用；其余三者之间的争用本文未核（C-3 待裁点 （c））。
注意：另一条本次实核（与“加段”无关但同等重要）：REG 记录亦无空余槽（`ESZ_SG_DISK = 24` = 6×i32 全满，`ccr_io.cr:157-162`；内存 `ESZ_SG = 48` = 6×u64 全满，`dyn_arr.cr:146-152`），因此若 placement 确需进 `.ccr` 且按 region 表示，扩 REG 与加段代价同量级（两者都是布局变更 + 版本检查整类拒收）。
6. 测试面：`tests/selfhost/test_ccr_v7.py`（段结构断言）+ `tests/selfhost/test_ccr_types.py`（段机制 + 内容面 + 版本检查，实测 49/49）须同阶段重定；`--dump-types` / `--dump-ifaces`（`main.cr:687`）是 dump 面的先例。
7. `.cir` 缓存面 `[已实现]`：`CIR_CACHE_VER : int = 22`（`src/compiler/cir_cache.cr:135`）是与 `CCR_VERSION` 独立的手工粗粒度版本常量（`cir_cache.cr:170` 注：“VER = 手工粗粒度（格式/语义生成代）”）。若 placement 元数据落进 `.cir` 快照，须独立 bump `CIR_CACHE_VER`。
注意：且检查须过 clean-cache / 有缓存状态纪律：缓存键 = 源路径：函数名 + 纯 AST 指纹，不含编译器身份，因此“改了编译器但源指纹不变”会命中旧快照。文档面须显式写这条。

### 9.3 三态实现建议（本文补，不裁决）

> 本次更新（2026-09-20）：原倾向 A（独立 MAP 段）。按 C-3 的实核下调，倾向改为 C，
> 理由不是省事，而是不变量 1 本身：`.ccr` 是语义 IR 实现方式，而 placement 元数据按定义不得改变语义 identity
> 因此把 placement 放进 `.ccr` 是与该不变量相抵的做法（哪怕检查写得出来，也等于在语义实现方式里放了非语义物）。
> A 的“检查强度高”仍是事实（见下表），但它换来的是“能证明没有改变语义”，而 C 直接“不改变语义”。

| 选项 | 不变量 1 的检查强度 | 代价 | 本次评价 |
|---|---|---|---|
| A. 独立 MAP 段 | 强，“摘除 MAP 段后其余段逐字节同”可直接写 | 第 9.2 节全部七项 | 注意：与不变量 1 相抵（语义实现方式放非语义物） |
| B. 附着在 REG 记录（原文第 21 节首选） | 弱，REG 记录字段数/尺寸变了，逐字节检查退化为“字段数不变” | 免 bump，因此本次更正：不免（REG 记录 6×i32 全满，改尺寸 = 布局变，因此同款拒收） | 双重不利 |
| C. 只进 `.cir` 快照，不进 `.ccr` | 中，`.cir` 缓存面独立 bump（`CIR_CACHE_VER`） | `corearch` 读不到 placement，因此只支撑 M0–M3，M4 起不够 | 本文倾向（与不变量 1 同向） |

因此本文现倾向 C，并配一条裁决前提：若 M4 起确需 `corearch` 读 placement，则应另立一个非语义侧的表示（部署配置 / mapper 自有表 / 独立 side file），而不是回落到 A 或 B。
因此三选项的共同前提：placement 不是语义，故任何“把它塞进语义实现方式”的方案都须先答“为什么非它不可”。

---

## 十、阶段目标 M0–M11

> 原文 12 档，逐条保留。本文补：每档的“检查形状”与“依赖”，以及顺序上的两条硬约束。

注意：术语撞名警告：本表的 `M2`（IR metadata）与 HIT 的 `M2`（全表驱动）是两个不同的阶段目标，编号空间独立。凡见只写 `M2` 须先判是哪一族，HIT 那族一律写全称「HIT M2」（本次 C-1 的裁决反转记录涉及 HIT M2，尤须区分）。

| # | 阶段目标 | 内容 | 检查形状（本文补） | 依赖 |
|---|---|---|---|---|
| M0 | Specification | 定义 ExecutionDomain · MemoryDomain · TopologyLink · Residency · AUTO/PREFER/REQUIRE；明确 placement 非语义本体。<br>〔本次追加〕 存在格本体（Materialization 七字段 + `Evictable` 改写）归 `materialization-space.md`；本文只承担放置面 | 本文档第 3 节/第 8 节写入文档（本文即 M0 的放置面产物）<br>并列产物 = `docs/maintainer/design/materialization-space.md`（本体面） | — |
| M1 | Syntax | `@preferredDomain(name)` · `@executionDomain(name)`；支持 `fn`/`flow`/`loop`/`region`；parser/checker 只做名字与结构处理 | 正：四类位置各一档，注解被解析进侧表；负：未知域名/非法位置，因此 rc=1 + 码 + 零产物（`check` 面）；结构检查：注解不产生任何 IR（`--dump-*` 前后逐字节同） | M0 |
| M2 | IR metadata | annotation，region mapping metadata；HDFG byte/semantic identity 不因 placement 改变；dump 支持显示 domain constraint | = 不变量 1 的四条检查（含“摘除 MAP 段后逐字节同”的限定条件） | M1 |
| M3 | Logical domain config | 部署配置定义 execution domains；domain alias，backend/device；默认域 | 配置解析单元档：别名解析/未知别名硬错/默认域回退；`Core.toml` 现只有 `name`（`src/compiler/project.cr:56` 全文仅读 name），因此须扩 schema | M0 |
| M4 | Static placement | AUTO/PREFER/REQUIRE；先 CPU-domain ↔ CPU-domain；不涉及 GPU | = 不变量 3 的正反两条断言 + 5；同后端两域（原文第 25 节例）全链路可跑 | M2,M3 |
| M5 | Memory topology | MemoryDomain；Link latency/bandwidth；Entry residency；materialization planner | = 不变量 2（含合并负控）+ 4 | M4 |
| M6 | Cost model | compute · dispatch · transfer · sync · preferred penalty；baseline HEFT-like scheduler | S-C 第 2.3 节契约六条：`band` 必填 / 缺失保守退化 / 相对量纲 / 模型非证明 / 与 `PROVED` 不混报 | M5 |
| M7 | Variant infrastructure | HIT baseline variant；多 backend variant；candidate pruning | variant 数上界（Top-K）断言 + 不变量 1（variant 不改变语义） | M6 |
| M8 | Minimal GPU backend | for/array/arithmetic 子集；一个 GPU execution domain；CPU↔GPU transfer 自动生成 | 目标子集端到端：`@executionDomain(gpu) flow test { for i in 0..n { out[i] = a[i]*b[i]+c[i]; } }` 值检查；自动 transfer 存在性断言（源码零 `copyToGpu`） | M7 |
| M9 | Runtime mapper | runtime N；actual residency；device load；CPU/GPU 动态选择 | 原文第 18 节例（`400MB @DDR`，因此 CPU；数据已在 VRAM，因此 GPU）作为行为检查 | M8 |
| M10 | Optimization | region fusion；transfer overlap；asynchronous materialization；residency retention；repeated execution profile | 各优化可缺席（S-C L3：缺失可接受）；每项独立正/负档 | M9 |
| M11 | Verification | 每个 variant 与原 HDFG 观测等价；transfer/materialization 保持 Entry identity；execution mapping 不改变 state-edge semantics | = 不变量 14 + S-C 第 3.2 节五条可迁移检查（观测等价/源码零改动/义务判定不变/决策自由/可移植子集） | M10 |

### 10.1 两条顺序硬约束（原文未显式写，本文补）

1. CPU↔CPU 假异构必须早于任何真实 GPU（原文第 25 节/第 26 节的顺序明确，本文升格为约束）：
   ```
   ExecutionDomain abstraction -> CPU↔CPU fake heterogeneous test -> MemoryDomain
     -> Topology -> Residency -> Transfer planner -> GPU backend
   ```
 而不是先 CUDA 再倒推架构，“否则很容易受 CUDA execution model 影响”。
因此结构性理由：原文第 25 节的 TOML 用 `backend = "hit"` 两次，正是“证明 ExecutionDomain 模型本身不依赖 GPU”的最小实验。这一点非常重要（原文如此）。
2. M2 先于 M4：不变量 1 若无表示物（M2），M4 起的任何 placement 都无法证明没有改变语义图。

### 10.2 原深度约束（原文“明确不做”）

见第 1.4 节；M10 之前不得引入其中任何一项。

---

## 十一、冲突登记（逐条列出 + 本次核实结论；不替维护者裁决）

> 格式：原文断言 / 仓库现状（file:line） / 本次核实结论 / 待裁点。

### C-1注意：最重要：HIT = baseline universal execution target ？

- 原文断言：`HIT = baseline universal execution target`；`HIT backend: canLower(R) -> true`；“没找到更优域，HIT”；同时又说 “HIT 不需要为了异构计算修改语义”。
- 仓库现状（本会话实核）：
 - HIT = Hardware Interface Table（“硬件接口表”），是一个表驱动编码机制，不是执行域：
 - `src/arch/hit/hit.cr:2`：「硬件接口表（HIT）：core-x86.toml，内存表 加载器」；`:8-10`：「表 = corearch 运行的唯一平台依赖：`load_hit_table` 把 toml 表文件读成 事件/投影/步 三块紧凑 buffer 表 + 运行时条目，表驱动编码器直读」
 - `src/arch/hit/lower_to_core.cr:2-3`：「合成层…IR 直线子集，4 核事件流 + 常量池」；`:21`：「未映射指令（RET/ALLOC/ARENA_*/…），无事件，旧路径（M1 混合模式）」
 - HIT spec 的定位是“接口”不是“域”：`2026-09-05-hardware-interface-table.md:11`「替换表 = 换目标平台/范式：同一 Core 程序配不同表直接运行」；`:26`「命名：接口表而非映射表，接口 = 语义契约（签名），实现 = 范式投影」
 - HIT 自身声明它可以在非经典范式上投影：HIT spec 第 3.2 节「投影不一定是“编码成字节”，投影 = 事件，范式资源的实例化；经典行恰好是 ISA 编码」（含“通道类范式/连续量子类/无实现”）
 - HIT 的“通用性”是“程序只用最小核事件，因此任意表可跑”（HIT spec 第 4 节「可移植子集」），不是“任意 region 都能下降”。程序用扩展事件时：「该表须含对应投影（查表缺失 = 编译期拒绝，或编译器降级合成）」（HIT spec 第 4 节）
 - 构建归属：`hit_engine_files`（`build_selfhost_native.py:49-51`）只进 corearch（`:388` `corearch_files = common_files + hit_engine_files + kernel_files + …`），corec 不需要（`hit.cr:21` 注）
- 注意：裁决反转记录（2026-09-20，两轮；本节是本次最有价值的一处记录）

 第一轮（口述）：维护者经 team-lead 转达「HIT M2 早已淘汰」（本文未见原话，来源 = 经 lead 转达）。
 依据该口述，本节曾把结论改成“M2 不是未完成而是不做；硬编码旧路径是永久设计”，并删去待裁项 （c）、改判「通用下降路径 = 设计空缺」。

 第二轮（书面校正）：本文按纪律去实核书面记录（不把口述写成已证事实），因此找到四处反向记载：

 | 位置 | 原文 | 与口述的关系 |
 |---|---|---|
 | `TODO.md:2211` | 节标题「HIT 最小核（2026-09-06 M1 完成，M2 挂账）」 | 相反（仍记挂账） |
 | `TODO.md:2215` | 「M2 挂账：」+ 五条 bullet（含「全量切换：无 `--table` 旧路径废弃（emit 循环门控翻转）」） | 相反（且该条正是“旧路径废弃”的计划） |
 | `docs/superpowers/plans/2026-09-07-hit-m2.md:3` | 「> 状态：待执行（2026-09-07 计划定稿）」 | 相反 |
 | `docs/superpowers/specs/2026-09-07-hit-m2-design.md` | 全篇 M2 设计（含 M2a–d 分段） | 相反 |

因此维护者据这四处改裁：「以书面为准」。 本节据此回退（逐条见下）。

注意：四处记载自本次起 = 以此为准，不再是待了结的对象（原“待裁：如何处理”一栏作废）。
注意：本文的处理纪律（经维护者确认“做法是对的”，须保留）：1 只登记，不改那四个文件；2 凡口述一律写明「未见原话，来源 = 经 lead 转达」；3 去实核记录，不把口述当已证事实。

- 本次核实结论（已按“以书面为准”回退为进度问题）：
 1. “HIT 不需要为了异构计算修改语义”，成立（`[已实现]` 级）：HIT 位于发射层、在 placement 下游；HIT spec 第 7 节「优化不进表（判定/分配 = 格形态层）」已是既有规则。本设计不需要改 HIT。
 2. “HIT = baseline universal execution target”，不成立（作为今天的事实）。理由是范畴错位：原文把 HIT 当作一个域（`backend = "hit"` 的 ExecutionDomain），仓库里 HIT 是机制（“替换表 = 换目标平台”）。一个机制不能同时是它自己的一张表。
注意：本论点（机制 ≠ 域）作为独立论点保留，但不得用来支撑“永久”，它说明的是范畴问题，不是进度问题（见结论 3）。
 3. “canLower（R） -> true”，今天为假，但这是进度性的（M2 挂账未做）：表模式覆盖直线子集（`const/store/load/add/sub` + 4 核事件），其余指令形状今天走硬编码 `e2_*` 路径。
因此该硬编码路径是「临时缺口」，不是「永久设计」，`TODO.md:2215` 明列「全量切换：无 `--table` 旧路径废弃」，M2 完成后即消除。
 4. 前提失效的登记随之撤回：HIT spec 第 1 节「硬件接口表 = 运行的唯一平台依赖」「替换表 = 换目标平台/范式」并未失效，它是待 M2 达成的目标；S-C 第 0.3 节「HIT M2 复启…实现归属不变（HIT 线）」同样有效。（第一轮据口述写的“不成立/须重定”已作废。）
 5. 原文方向的前件：S-C 第 0.0 节「单 CPU 上的 SIMD/cache/NUMA/… 与异构 placement 是同一个问题…机制同一，无第二条性能路线」成立；S-C 第 3.1 节把“目标描述”写成「表：语义表 + 投影条目 + 运行时条目 + 设备/投影表（hw-map）+ 成本事实」成立。

- 「通用下降路径」的归属（第一轮的“设计空缺”判定已撤回）：
 - HIT 仍是该位置的既定承担者，只是要等 M2 完成才成立。这正是待裁项 （c） 的内容（第一轮删错了，本次恢复）。
 - 第一轮据口述写的“今天没有一个被明确命名的通用执行目标 / 本文判定为设计空缺”撤回；`instr.cr` 硬编码发射器是待废弃的临时过渡路径，不是“未被命名的空缺”。
 - 因此第 8 节不变量 7（“未指定，因此恒存在合法映射”）恢复为“依赖 C-1 待裁点 （b）/（c） 的落定”，不再标注“不可判定”。

- 待裁点：
 - （a） 原文的 `backend = "hit"` 是否应改述为「`backend = "classic"`（其编码由 HIT 表 + 尚未废弃的旧路径共同实现）」？还是保留 `"hit"` 但在文档里显式声明“此处 hit = 表机制所在的默认域”（即接受一次术语重载）？
 - （b） 通用下降路径的身份：是 HIT 表模式（须先完成 M2），还是今天的硬编码路径（已可用但不在表内）？这直接决定第 8 节不变量 7 的“通用域”是什么。
 - （c） （本次恢复）若采 （b） 的前者，则 M4 前置应增加「HIT M2 完成」，原文阶段目标无此项。
注意：记录：该项曾于本次第一轮按维护者口述「M2 已淘汰」被删去；经四处书面记载校正后恢复（维护者改裁「以书面为准」）。不是新增项，是恢复项。

- 注意：本节作为方法论实例（本次新增，勿淡化为一次普通修订），「口述 vs 书面记载冲突，因此以书面为准」的一个完整实例：

  ```
  1 收到口述裁决（"M2 早已淘汰"）
  2 未把口述写成已证事实：写明"未见原话、来源 = 经 lead 转达"
  3 按纪律去实核书面记录 => 找到四处反向记载
  4 维护者据书面改裁 => 本节整轮回退，且回退本身记录
  ```

 要点（下游可复用）：
 - 口述与书面冲突时，书面优先；实核记录是可操作的一步，不是形式主义，本次正是它把结论翻了过来。
 - 回退要记录、不要不报错地改回：删掉的待裁项写出“曾删、因何恢复”；作废的结论标“已作废”而不是抹掉。
 - 如实记录是关键的一条：若第 2 步把口述写成事实，第 3 步的实核就失去触发理由（“已证”的前提会让反证显得像无关干扰）。
 - 因此本文档全程适用：凡 team-lead 转达的维护者裁决，一律写「未见原话，来源 = 经 lead 转达」（维护者已确认此做法）。

### C-2 cache-semantics 规则 4b vs 原文的副本有效性模型

- 原文断言（第 28 节）：`X2: DDR valid / VRAM stale`，即所有条目按“哪份新鲜”管理；materialization 的 `valid` 位统一处理。
- 仓库现状：`docs/academic/cache-semantics.md:28`（规则 4b，v4 并入，M4 输入）：「图内不可重算…存在图内无方法条目，非边界、不可重算。驱逐不变量/再生等价对其不成立（重跑神谕 ≠ 原结果）：其存储必须持久（home 保有材料），驱逐必须写回；身份 = 产生节点」；`:50-59` 细读给两类：边界（MMIO/FFI/输入/测量，语法层 `unsafe`）/ 图内不可重算（神谕/BSS 实数/FIXPT 声明/模糊融合），并明言「不按范式枚举，新增范式时无方法规则不变」。
- 本次核实结论：
 1. 两者不是矛盾，但原文的统一 `valid` 位模型不覆盖无方法条目，对它们“VRAM 那份可由 DDR 再生”是错的（规则 3 不成立），且存在权威副本（home）概念，原文模型里没有这一位。
 2. 仓库侧是更强的要求：规则 4b 对无方法条目给的是义务（必须有 home、驱逐必写回），而原文把 residency 整体当优化。因此若不区分，实施阶段会把“必写回”实现成“可丢”= 不报错地语义破坏。
 3. `home` 字段已在 `.ccr` ENT 盘面上（`ccr_io.cr:173-176`），因此表示面已存在，缺的是模型侧的分档规则。
- 注意：本次状态变更（materialization-space 输入后）：本条由“待裁”改为“已被新框架涵盖”。
 理由：新输入的 `Evictable(x) ⟺ Recoverable(x) ∨ PreserveRequiredState(x)`（第 6.4 节）第二支正是规则 4b 的位置，规则 4b 不再是“例外规则”，而是第二支的正例。
 且新框架用 `authority` 取代 `valid`（第 3.5 节），“权威副本”这个概念已在七字段里有位（第 3.4.5 节第 4 行）。
因此本文已按此重写第 3.5 节（删 `valid`）、第 6.4 节（`Evictable` 新式）、第 6.5 节（方向反转）、第 8 节4（按字段分档 + 新增 `authority`/`replicability` 检查）、第 8 节8（新不变量）。
- 剩余待裁点（只剩一条，不裁决）：规则 4b 自身的措辞是否要改，它现在写在 `cache-semantics.md`（被定位为“缓存映射实例的规律”）里，而它讲的其实是存在格的一般规则（any `recipe = unrecomputable`）。因此是"规则 4b 应上移到 `materialization-space.md`“，还是”保留在原处、由存在格文档引用它"？本次不裁决，也不改那份文件（C-11）。

### C-3 `.ccr` 段位主张冲突：MAP 段 vs 驱逐标注段 vs 证书段

- 原文断言（第 21 节）：“或者更干净地单独增加 MAP 映射 section”。
- 仓库现状 `[已设计未实现]`：`docs/superpowers/specs/2026-09-09-lattice-ir-v7-format.md:50` 注：「`9+` 预留顺移：驱逐标注段 v6.1 延续、证书段」，即 tag 9+ 已有两个具名主张者。S-C 第 3.1 节又主张 `.ccr` 新段表示成本事实（"实现方式 = `.ccr` 新段，随 R2 P4 同波"，引同一处 `7+` 未固定分配）。
- 本次核实结论（本次下调，见下“实核与下调”）：MAP 段将是 tag 9+ 的第三个主张者…，因此多次加段 = 多次全局格式破坏。
- 注意：实核与下调（2026-09-20）：另一名撰写者核出 `.ccr` 不需要加段、不需要 bump `CCR_VERSION`，七字段复用 `ENT.flags` 空闲位 + 现有 4B 槽。本文独立复核（部分证实、部分须留待）：

 | 主张 | 本文复核 | 依据 |
 |---|---|---|
 | 七字段复用 `ENT.flags` 空闲位 |证实（位数足够） | `ENT.flags` 是 u32，bit0–3 已定（无方法/参数/全局/驱逐候选），因此 bit4–31 空余 28 位；`recipe`/`persistence`/`replicability`/`authority` 都是小枚举（`existence-structure.md:45`） |
 | 且值域现为空（可自由启用） |证实 | `flags 恒 0`、零实例（`ccr_io.cr:85`；第 3.4.5 节 / C-13） |
 | 七字段复用“现有 4B 槽” |注意：未证实，本文未找到任何空余 4B | ENT 内存态 = `ESZ_ENTRY 24` = 6×4B，六槽全命名（`var/def/ls/le/home/flags`，`dyn_arr.cr:137-143`）；盘面 = `ESZ_ENTRY_DISK 28` = 7×4B，七槽全命名（`ccr_io.cr:173-176`），其中 `version` 是由组序导出的（`ccr_io.cr:175`「derivable from group order」），已被占用，因此无空槽可复用 |
 | MAP（region 放置）也无需新段 |注意：未证实/不成立 | MAP 是 region 侧（regionId/mode/域名），归 REG 段；REG 盘面记录 `ESZ_SG_DISK = 24` = 6 × i32 六字段全满（`{kind, parent, enter_nod, exit_nod, first_ent, last_ent}`，`ccr_io.cr:157-162`），未见空余槽；内存态 `ESZ_SG = 48` = 6 × u64 亦满（`dyn_arr.cr:146-152`） |

注意：由本表得出的一个附加约束（本文补，其他撰写者未提），位打包路线可行的前提是“字段值域有界”：
 - `recipe` / `persistence` / `replicability` / `authority` 有界（小枚举），因此位打包无问题。
 - `location`（“当前在哪里存在” = 内存域索引）是唯一的例外：它需要一个域编号，位打包只能容纳 `⌈log₂ D⌉` 位，因此给内存域数量设了一个硬上限（如 4 位 = 16 个域）。
 - 因此这正是仓库一直在废弃的 `MAX_*` 模式（先例：容量阶段 E-3 三 `MAX_*` 废弃、`MAX_FN_PARAMS` 越界写修复）。“不加段”与“不设上限”在本字段上不可兼得，须二选一（或 `location` 走侧表/独立表示）。
因此本文结论：位打包路线在五字段上成立、在 `location` 上有代价，“完全不需要新增表示”的说法在本字段上未获证实。

因此下调范围（本文结论）：“段位资源争用”在材料化七字段面消失（那部分确不需要段）；MAP 自身是否入 `.ccr`、以何表示，仍待定，但优先解不是“加段”：
 - 更贴合的解法（本文建议，不裁决）：由 不变量 1（placement metadata 不得改变 HDFG 语义 identity）反推，placement 本就不该进 `.ccr`（`.ccr` 是语义 IR 实现方式）。因此 placement 归部署配置 + mapper 自有表，编译期面可放 `.cir` 快照（第 9.3 节选项 C）。
 - 若采此解，C-3 的“段位争用”整体解除（连 MAP 也不加段），因此 tag 9+ 的两个具名主张者（驱逐标注段 / 证书段）与 S-C 的成本事实段不产生争用。
- 待裁点：
 - （a） MAP 段与成本事实段是否合并，改问：placement 是否根本不应进 `.ccr`（本文倾向“不应”，理由 = 不变量 1）？
 - （b） 若 placement 确需进 `.ccr`，则 REG 记录无空余槽，因此须改 REG 记录尺寸（仍是一次格式变更），此时“加段”与“扩 REG”代价同量级，比较基准须重算。
 - （c） tag 9+ 的两个既有主张者（驱逐标注段 / 证书段）与 S-C 成本事实段之间是否仍有争用，本次只下调了 MAP 这一项，其余三者的关系本文未核。

### C-4 原文第 2 节的 `flow` 块语法 vs 仓库的 P021 硬拒

- 原文断言（第 1 节/第 2 节，主例）：`fn pipeline(...) { ... @executionDomain(gpu) flow compute { ... } ... }`，函数体内的 `flow` 块。
- 仓库现状 `[已实现]`：
 - `parser.cr:1002-1010`：语句位遇 `T_FN`/`T_FLOW`（含 `pub` 形态），因此 `check_error(EC_P_NESTED_FN, "Nested function declaration … is not supported; declare it at top level")`（P021，`ast.cr:351`）。
 - `parser.cr:995-996` 注：「嵌套 `fn`/`flow` 声明不属语言面，`grammar/core.ebnf` 的 `Statement` 不含 `FunctionDecl`（函数声明仅顶层 `TopLevelDecl`），bootstrap 参考实现亦以 positioned error 拒绝。」
 - 现有 `flow` 形态 = 顶层 `flow fn name(...) { }`（`parser.cr:1726-1749`；EBNF `grammar/core.ebnf:22`）。
- 本次核实结论：原文主例在今天是一条语法错。M1 的“flow 块”是语法面新增（不只是注解新增）：须同阶段改 `parser.cr` 语句分支 + `grammar/core.ebnf` 的 Statement + 负例档（P021 的既有负控 `tests/selfhost/test_nested_fn.py` 仍在 `src/ci/run.sh` 挂钩，`run.sh:47`），且须注意：放开 `flow` 块会削弱 P021 的既有语义（`flow` 不再是“嵌套声明”），两处必须同阶段重定才不会一边放开一边误报。
- 待裁点：`flow` 块的合法性边界，`@ann flow x { }` 与既有 `flow fn` 是否共用 `SG_FLOW`（`dyn_arr.cr:157`）？`flow` 块是否有名字（`flow compute {`）还是匿名？名字进哪个命名空间？

### C-5 原文的 `Region` / 仓库的 `Region`（术语）

- 原文断言："来源：HDFG region · `flow` · `loop` · `function`"（第 7 节），把 region 当执行放置单位。
- 仓库现状 `[已实现]`：`docs/maintainer/design/region-model.md:3`：「Core 采用图绑定区域的统一内存管理：区域（Region）绑定在 HDFG 上，区域是子图节点的字节域，不是词法作用域的对应物」；`第 3.1 节` 表逐子图类型给内存策略（DAG，栈式区域 / 静态循环，固定区域 / Flow，独立区域 / Go，独立区域 / Yield-Recv，消息区域）。
- 本次核实结论：同名不同义，且两者共用同一个物理表示候选（`g_sgs` / `SG_*`），这是实施阶段最容易踩的坑：把“ExecutionRegion 加槽”加到 `ESZ_SG`（48B，`dyn_arr.cr:146`）上，会同时改变内存区域的语义实现方式。本文第 0.1 节已立术语约束（一律写 `ExecutionRegion`）；建议实施阶段也一律用 `ExecutionDomain`/`ExecutionRegion` 前缀命名，不要复用 `sg_*`/`REG`（`REG` 已被 `.ccr` 第 5 段占用）。
- 待裁点：`ExecutionRegion` 与 `g_sgs` 的 region 是一对一（直接复用下标）、一对多（fusion 后合并）、还是独立表 + 映射？原文的 `region fusion / region split` 暗示不是一对一。

### C-6 档案「无格承诺」对 Capability Lattice 的约束

- 原文断言：Capability Model 应做成格（`Req(R) ⪯ Cap(D)`，闭包，偏序）。
- 仓库现状 `[已设计未实现]`（archive，v4 定稿）：`docs/archive/memory-model-capability-lattice.md:11`「2 无格承诺：格（Lattice 代数）不进入语义本体，是映射实例的组织参数，判定/定理只在关系层面陈述（最弱理论，函子式构造防枚举）」；`:14`「任何具体格 = 签名 + 恒等式 = 封顶…语义写在比格更弱的理论里」；`:15`（v4 第零.3 节）「语义保留线不需要「能力」独立概念…不提升且可逆，零成本 YAGNI，选项永远保留」。
- 本次核实结论：两者相容，但有一个硬边界，原文的能力格位于 mapper/backend 内部（“复杂性都藏在 mapper/backend 里面”，用户侧三态），这与档案“格 = 映射实例的组织参数”同指。因此能力格可以存在，但不得进入语义本体（不得成为语言原语、不得进入规则集、不得让 `Req`/`Cap` 出现在图或源码里）。
注意：与 S-C L6 裁决 亦一致：`[已设计未实现]`「标注 = 开放标注/事实来源，不是新 primitive：不新建属性轴、不新增语言关键字」。因此能力格不得渗出为源码级 capability tag，原文第 30 节「用户级 capability tag 大全」已在“不做”清单，档案给出了它“不做”的第二条理由。
- 待裁点（本文建议但不裁决）：本文第 5 节/第 8 节3 的 `Req ⊑ Cap` 陈述已按“关系层面”写（不写格公理、不写恒等式），与档案“最弱理论”一致，是否要求实施阶段也遵守“只陈述关系、不引入格代数”？若是，第 3.7 节的 `parents[]`/`constraints[]` 应明确为实现内部组织，不得文档化为语义公理。

### C-7 逻辑域名 vs “源码零机器名词”

- 原文断言：`@executionDomain(gpu)` / `@preferredDomain(gpu)`；例子用 `cpu` / `gpu` / `bigCpu` / `littleCpu`。
- 仓库现状 `[已设计未实现]`：S-C L1「机器形状不进程序意义：源码/图零机器名词（无宽度、无寄存器、无 SIMD 宽度、无设备名）」+ 第 3.2 节反向泄漏检测「`c) 源/图中出现机器名词`，因此违反，登记为「泄漏待归一」」；一致性佐证 `[已实现]` 文档面 `docs/z-vision.md:41`「范式无关的语义层是尚未被占据的位置（现有语言都绑定经典执行模型）」。
- 本次核实结论：原文第 4 节的机制（域名是逻辑名、来自部署配置、换机器不改源码）完全符合 L1；但原文给的示例字面量（`gpu`/`cpu`/`bigCpu`）全是机器名词。因此这是表述与自身机制的摩擦，不是设计矛盾：`fast` 一例即合规形态。
- 待裁点（不裁决）：是否要求 v1 文档/示例一律改用非机器名词（`fast`/`slow`/`big`/`little`）？还是接受“逻辑名允许与机器同形”（那 L1 的“设备名”需重述为“硬编码的设备名”）？这条会影响全仓文档与所有示例，应尽早裁。

### C-8 原文两处的结构清单不一致

- 原文断言：（“四对象”节）`RegionRequirement { operations, control, addressing, synchronization, effects, guarantees }`（6 项）；（“能力维度”节）`ExecutionCapability` 十项（Computation/Control/Parallelism/Storage/Addressing/Synchronization/Communication/Effects/Dynamism/Guarantees）。
- 本次核实结论：两处同一对象的两份清单，6 项版缺 `Parallelism`/`Storage`/`Communication`/`Dynamism` 四项，而分量最重的一条判例（NPU 的 `Storage: private, domainShared` + `Addressing: indexed` 但不支持 `indirect`/`pointerLike`）恰好依赖 `Storage`。因此6 项版是不完整的中间稿。
- 本文的处置：第 3.6 节采十项（与能力维度一一对应）。不替维护者裁决，若维护者要求 6 项是 v1 收敛范围，第 3.6 节/第 4 节须同步缩小范围，且须评估“NPU 判例是否仍可表达”。

### C-9 部署配置面：仓库只有 `name`，而第 5 节/第 19 节/第 20 节假设一整棵配置树

- 原文断言：`[executionDomain.cpu] backend = "hit" device = "cpu0"`；`[execution] mapping = "static"` / `objective = "performance"`。
- 仓库现状 `[已实现]`：`src/compiler/project.cr`（全文 56 行）只做 `read_file(dir + "/Core.toml")`，`extract_toml_name(tc)`；两个 `Core.toml` 在仓（`src/compiler/Core.toml`、`src/targets/x86_64-linux/Core.toml`）各只有一行 `name = "…"`。无 `[execution]`、无 `[executionDomain.*]`（全仓 grep 零命中）。
 原则面已有前件 `[已设计未实现]`：`docs/maintainer/design/execution-model.md:180-183`（第 5.1 节）「Core 代码只描述计算逻辑与数据结构，不规定内存从哪来…物理约束在部署配置中声明（TOML，如 `allocation = "static"/"dynamic"`），编译器据此检查兼容性并生成适配代码」；`:199-201`（第 5.3 节）资源配额同理；`:203`（第 6 节）「代码与部署分离…同一份代码…代码不改。图语义唯一。部署配置不同。」
- 本次核实结论：原文的配置面与第 5.1 节/第 6 节的既有设计意图同向，但基础设施为零（56 行 + 单键）。因此 M3 的规模被原文低估：需要完整的 TOML 段/嵌套表解析，而不是“读一个键”。
- 未核实（重要）：`src/stdlib/toml.cr`（274 行）的现有能力边界，本会话只核到其导出函数为 `toml_get_str` / `toml_get_int` / `toml_get_int_list` / `toml_read_memlayout` + 私有 `_skip_whitespace` / `_is_at_line_start` / `_next_line_start` / `_toml_hex_digit` / `extract_toml_name`。
因此是否支持 `[section]` 嵌套表 / `[[array-of-tables]]` / 点号键，本会话未核实（记入第 12 节）。若只支持平键，M3 须先扩 TOML 解析器（或改用 hw-map 线的现成表机制，见 C-1 结论 4）。

### C-10 部署策略 objective 与 S-C 裁决的边界

- 原文断言（第 20 节）：`[execution] objective = "performance"`，以后可 performance/latency/energy/balanced；“不要把这些变成源代码 annotation”。
- 仓库现状 `[已设计未实现]`：S-C L5「成本模型 = 数据 + 可替换组件：成本事实随表走；成本模型（加权/阈值/搜索）是编译器侧可替换件，不进图语义，也不进表的「放置策略」面」（依据 = HIT spec 第 3.3 节「优化不走表」）；S-C 第 1 节表把“资源约束”列为 `policy 数据`。
- 本次核实结论：原文“部署策略不进源码”与 L5/第 1 节同向。但边界待定：`objective` 属于部署配置（原文），而 L5 说“放置策略不进表”，部署配置 ≠ 表吗？在仓库的术语里 `Core.toml` 是部署配置、HIT 表文件是表，二者是不同物 `[已实现]`（前者 `project.cr` 读，后者 `--table` 传入，`hit.cr:4`）。因此不冲突，但文档须显式写“部署配置与目标描述表是两处，L5 只约束后者”。
- 待裁点：`objective` 是否应落部署配置（原文）还是目标描述表（S-C 第 3.1 节的“目标描述”三轴 + 表）？若落表，则与 L5“策略不进表”直接冲突，须先裁 L5 的适用范围。

### C-11注意：「格 = 缓存」定义的既有对应位置（原快照；2026-09-20 起已由另一名撰写者就地修订）

> 注意：读法（本批复核后补）：本节的表 = 修订前的原快照，用于记录（记录“改之前是什么样”），
> 不是现状。2026-09-20 起这 7 处正被就地修订（维护者裁定「同阶段就地改」，见本节末“已裁”）。
> 本文全程未改那 7 个文件；下游若要用现状，请读那些文件本身，不要读本节表。

- 新输入断言（`materialization-space-raw.md`）：把「格 = 缓存」当本体定义「可能太窄」；正确的层关系是 `格层 = Materialization / Existence Space`，缓存只是其中一类映射实例；「“缓存”这个词都可以降级，不再作为整个层的总名字」。
- 仓库现状（既有「定稿」措辞，本会话逐条实核行号）：

| # | 位置 | 原句（节录） | 与输入的冲突点 |
|---|---|---|---|
| 1 | `docs/academic/cache-semantics.md:4` | 「本文件是 Core 存储语义本体的唯一权威」 | 把缓存规则升为本体；新输入要把本体归 Materialization Space |
| 2 | `docs/project-book.md:216` | 「存储语义本体为缓存语义（值 = 方法、条目可驱逐可再生、图边界为唯一不可再生来源）；字节内存是其在经典硬件上的映射实例」 | 1 本体 = 缓存（要改）；2 但“字节内存 = 映射实例”这半句方向正确，是新旧框架共有的 |
| 3 | `docs/project-book.md:109` | 「图也是存储语义的实现方式，值即条目（方法可重算），存储即缓存（范式无关），内存只是经典映射」；同段「格负责表示计算（内存模型 = 中间存在空间）」 | 「存储即缓存（范式无关）」是最强的冲突句，新输入恰恰指出缓存是范式相关的（那六个假设在别的范式不成立）；同段的「中间存在空间」反而与新层名同向 |
| 4 | `docs/z-vision.md:15` | 「范式映射表，存储半边已定稿（语义本体 = 缓存语义，字节内存 = 经典映射实例）」 | 「已定稿」= 本次要修订的对象本身 |
| 5 | `docs/maintainer/design/memory-model.md`（标题 + 第 1 节分工表） | 「存储语义总览：缓存，存在结构，经典映射」；「规则来源 = cache-semantics.md」 | 层名以「缓存」起头；分工表把 cache-semantics 列为「规则来源」 |
| 6 | `docs/maintainer/design/existence-structure.md`（标题 + 第 3 节表头） | 「存在结构：v6 格形态 IR 的语义表示」；「ENT 记录字段与缓存规则的对应」 | 注意：标题里已经是「存在结构」，与新层名同向；但字段表以「缓存规则」为列标题（要改列名，不改字段） |
| 7 | `docs/maintainer/design/region-model.md:3-5` | 「本文件 = 缓存语义（权威 = docs/academic/cache-semantics.md）在经典字节硬件上的映射实例详细设计」 | 方向已经正确（“映射实例”），唯一无需修订的一处，可作为其余各处的改写范本 |

- 本次核实结论：`[已设计未实现]`。冲突不是全仓一致性的问题，7 处里至少 2 处（#2 后半、#7）方向已对，且 #6 标题已用「存在结构」。因此修订面比输入预估的窄：核心是 #1/#2/#3/#4/#5 的“本体”一词与层名，而不是整套语义。
- 待裁点（不裁决，且本次一律不改这些文件，因此见本节末“已裁”：已裁决 = 同阶段就地改，改由另一名撰写者执行；本文仍一律未改）：
 - （a） `cache-semantics.md` 的文件名是否改（它是 7 条的规则来源不变，但标题「缓存语义：存储语义本体」要改）？
 - （b） `memory-model.md` 标题的「缓存，存在结构，经典映射」是否改为「存在格，存在结构，缓存映射」？
 - （c） `existence-structure.md` 第 3 节表头「与缓存规则的对应」是否改为「与存在格规则的对应」（字段与取值不动）？
 - （d） 三步修订的顺序与同阶段性，既有纪律「修了前置能力的阶段必须同阶段清点把该缺口当现状写的陈述」，故 （a）–（c） 宜一组同改。
- 已裁（2026-09-20，维护者经 team-lead 转达）：
 1. 上述 7 处正由另一名撰写者就地修订（维护者裁定「同阶段就地改」），因此（a）–（d） 四项从本文的待裁清单移除，改由那份就地修订负责。
注意：本文未见过维护者原话（经 team-lead 转达），故上表 （a）–（c） 的具体改法仍以就地修订者的裁定为准；本次仍一律未动这些文件。
 2. 本文的职责边界（维护者明确）：引用它，不要重复定义。因此本文第 6 节/第 8 节凡涉及存在格本体的陈述一律以 `materialization-space.md` 为准；本文只承担放置面（第 0.2 节层归属）。两侧命名若不一致，以那份为准（未核实项 15）。

### C-12 三层映射链的层名（不是层定义）

- 新输入断言：`图 -> 存在格 / Materialization Space -> 编码`；`缓存语义 = 经典可再生值的一种映射规律`。
- 仓库现状（两处现行层名，措辞几乎相同）：
 - `docs/project-book.md:109`：「三层映射（2026-08-27 正式晋升）：语义，图，格，编码，图负责表达计算（关系空间），格负责表示计算（内存模型 = 中间存在空间），编码负责实现计算（物理编码空间）」
 - `docs/z-vision.md:15`：「范式，图，格，编码，图 = 关系空间…格 = 状态/存储空间（内存模型 = 中间存在空间）…编码 = 物理编码空间」
- 本次核实结论：注意：层名早已是「格」，不是「缓存」，两处都写「图，格，编码」，且都注明「中间存在空间」「状态/存储空间」。
因此新输入要的层名（“存在格 / Materialization Space”）与既有层名（“格 / 存在空间”）几乎重合，差别只在具体化：既有写“格”，新输入写“存在格”并给英名。这是术语具体化，不是层结构变更。
因此真正变更的是层内本体（C-11 的“缓存，Materialization”），不是层的数量或位置（四段链 `语义->图->格->编码` 不动）。
- 待裁点：层名是否统一为「存在格」（中文正式名）+ `Materialization Space`（英文）；`格` 作为简称保留。
- 已裁（2026-09-20，维护者经 team-lead 转达）：`格` 保留作简称。理由（与原话一致）：既有链名本来就是「图，格，编码」且注明「中间存在空间」，维护者原话也是「格层 = Materialization / Existence Space」，因此这是术语具体化，不是层结构变更，四段链不动。
因此本文的实现做法：正式名用「存在格」（首次出现处附英名 `Materialization Space`），简称用「格」，与既有文档的「格」字不冲突、无需全仓替换。C-12 判断（层名几乎重合）经维护者确认成立。

### C-13 `ENT flags` 位语义（设计文档）vs 恒零值（实现）

- 设计文档断言：`existence-structure.md:45`「`flags` | bit0 无方法 / bit1 参数 / bit2 全局 / bit3 驱逐候选（v6.1） | 规则 4b / 规则 2」；`:59`「ENT flags bit0 = 无方法（图内不可重算），必须有 home」。
- 仓库现状（本会话逐行实核）：
 - 槽位：`OFF_ENTRY_FLAGS : int = 20;   // 位 0 预留：无方法（规则 4b）`（`dyn_arr.cr:143`）
 - 值（内存态）：`flags(20) u32 = 0（位 0 预留：无方法，规则 4b）`（`globals.cr:232`）
 - 值（盘面）：`flags 恒 0（无方法/参数/全局/驱逐位零实例，位语义保留）`（`ccr_io.cr:85`）
 - 写点穷举：`OFF_ENTRY_FLAGS` 全仓仅三处，`dyn_arr.cr:143`（常量）、`ccr_io.cr:473`（读）、`ccr_io.cr:1447`（loader 回写从盘面读到的 `efl`，即往返，非新决策）。因此无任何一处写入非零值。
- 本次核实结论：注意：设计文档的措辞与实现有可观测落差：文档写「bit0 = 无方法」（陈述式，读起来像已生效），实现是「位 0 预留」（`dyn_arr.cr:143` 原文用词）+「零实例、位语义保留」（`ccr_io.cr:85`）。
因此 `recipe` 的正确三态 = `[已设计未实现]`（预留槽位 + 恒零值），不是 `[已实现]`。
因此这不是缺陷，是“写侧不做决策回填”的有意设计（同注：`home 恒 -1`，理由「分配决策不写回格式」）。
- 待裁点：
 - （a） `existence-structure.md:45/59` 是否应把「bit0 = 无方法」改述为「bit0 预留（位语义已定，零实例）」以对齐实现？（本次不改）
 - （b） `recipe` 要变成活位时，是否确认不需改布局（位已预留），只需一个写点 + 一个消费点？（本文第 3.4.5 节结论 1 倾向“是”，但未核写点的插入位置，见第 12 节）

---

## 十二、未核实清单（宁可交白卷也不猜）

以下依据本会话未能核实，交付阶段须补：

1. `src/stdlib/toml.cr` 的嵌套/数组表/点号键能力（C-9），只核到导出函数名，未核语法覆盖面。这是 M3 规模判断的关键未知。
2. HIT 表模式的逐 op 覆盖清单：本会话核到「直线子集 = const/store/load/add/sub」（`lower_to_core.cr` 头注）+「未映射指令，旧路径」，未逐条核 IR 的 38 op 中哪些走表/哪些走旧路径。
注意：本次记录：本句一度被改为「这不再是“完成百分比”问题（M2 已淘汰，因此覆盖率不会再变）」；经四处书面记载校正后已回退，该清单仍是完成百分比问题（HIT M2 挂账未做，`TODO.md:2215`），其近期用途 = 划定表模式当前覆盖边界（供第 5.10 节 variant 与第 5.11 节 backend 接口使用），不是“永久边界”。
3. `core-x86.toml` 的完整 schema，本会话读的是 `hit.cr` 的内存表布局注释（事件 40B / 投影 12B / 步 108B 及其 `OFF_*`），未读 toml 文件本体的条目形态与 `[runtime.x86]` 小节实例。
4. `.ccr` loader 的段序检查精确形态，本会话核到版本检查（`ccr_io.cr:979`）、段号检查（`:1006`）、TYPE/IFACE 重复检查（`:1017-1018`）与格式文档"`tg == ri+1` + 段体连续两检查"的文字，未逐行核该两检查的代码实现（`ccr_io.cr:1000+` 段未逐行读）。
5. 跨 domain 后 Entry 的 kind 属性是否随域改变（第 2.3 节规则 3 的交互），与 `region_check` 的活子图义务的关系未核。
6. `@executionDomain` 硬错是否已与 fail-closed 门/豁免表兼容，本会话核到门与豁免表存在（`diag.cr` 头注 + `diag_gate_exempt`）与 `test_diag_gate.py` 的存在，未核新增码族的注册流程细节。
7. `grammar/core.ebnf` 的 `Statement` 全文，只核到 `FlowDecl`（`:22`）与“Statement 不含 FunctionDecl”（来自 `parser.cr:995-996` 的注，非 EBNF 原文）。放开 `flow` 块须以 EBNF 原文为准。
8. `docs/maintainer/design/execution-annotation-space.md`的“执行标注空间”，原文 第 “无方法条目”与 S-C 第 1 节都引它（神谕/BSS 实数/FIXPT/模糊融合），本会话未读该节；第 3.6 节的 `storage`/`dynamism` 推导可能与之强相关。
9. `docs/maintainer/design/existence-structure.md` 的 ENT/NOD/REG 语义视角，第 3.4 节/第 3.5 节的 version/home 只核到 `.ccr` 盘面字段与 cache-semantics 规则，未读该文档对“存在区间（live range）是版本级别的”（`cache-semantics.md:67` 指向它）的展开。这对第 3.5 节 ResidencyState 的 live range 表示可能是必需的。（注意：本次部分补核：第 3 节 ENT 字段表 `:36-46`、无方法节 `:57-59`、开放点 `:115-123` 已读；第 4 节–第 9 节仍未读。）
10. `src/stdlib/goroutine.cr`（70 行）的 G 结构体字段全集，`execution-model.md` 第 3.2 节给了设计态 `struct Goroutine {…}`，未与实现核对（第 6.8 节的 per-domain 队列改动面取决于此）。

本次（materialization-space 输入）新增的未核实项：

11. `recipe` 变活位所需的写点位置，第 3.4.5 节结论 1 说“位已预留、只需一写点 + 一消费点”，但未核该写点应插在哪（`compute_entries` 内核？`ccr_io` 写侧？还是 `checker` 的类别判定处），也未核谁在编译期知道“这条目无方法”（最接近 = cache-semantics 规则 4 的边界标注 `unsafe`，及 `execution-annotation-space.md`的执行标注，后者本会话未读，见第 8 项）。因此 `recipe` 的“只差一个写点”这个判断，其可行性未验证。
12. `authority` 的仓库侧最近物，本次只做了零命中核验（`authority` 在 `src/` 与 `docs/maintainer/design/`、`docs/academic/` 无出现）。未核它是否以别的词存在（候选：`home`／`SG_UNSAFE` 的边界通道／`IR_CALL_EXTERN` 的返回值语义／`volatile` 类标注）。因此若它其实以别名词存在，第 3.4.5 节第 4 行的 `[提案]` 判定须下调。
13. `replicability` 的仓库侧最近物，同第 12 项，只做零命中核验。未核是否有等价约束（候选：`Linear`/一次性类型的既有设计、`chan` 的单产单消边语义 `chan.cr`、arena 的 `share` 规则 `region-model.md` 第 3.2 节推论 B）。
14. `location` 与 `mt_memd` 的区分是否有既有实现阻力，第 3.4.3 节断言二者是不同槽（格层 vs 放置层）。未核现有 ENT/REG 面是否已经把两者混用（若 `home` 同时被当“槽位”与“域”，实施阶段会撞上既有消费者）。
15. `docs/maintainer/design/materialization-space.md`（existdoc 的产物）写入文档后的接口面，…未核该文档实际用的字段名/层名是否与本文第 3.4.2 节的七字段一致。
本次结案（2026-09-20 复核），状态由「未核」升为「实测不等，因此已按权威关系统一」：
 该文档已写入仓库（`docs/maintainer/design/materialization-space.md`，65719B；核验时在 `core-existdoc-ws` 工作区，尚未进 develop@origin）。
 实测：其第 2.3 节「字段级模型（七字段）」（本轮改名；本文旧引作「字段级定稿」，已随之更新）给出取值域两列（语义 · 取值域 · 谁写 · 谁读 + 两条蕴含关系），
 与本文第 3.4.2 节原表的取值域 4/7 行不等（`recipe` / `authority` / `persistence` / `replicability`），
 且两处原互不指向，命中本文自己命名的「同一命题两处说法」第一类。
 处置（已完成）：建立权威关系，层定义那份为权威；本文第 3.4.2 节改为引用（取值域列逐字引第 2.3 节，只保留本文真正多出来的两列实例取值），
 并全文术语对齐（`recipe = recomputable|unrecomputable` 等，替换掉原自述词 `yes/no/external`），
 第 8 节4/第 8 节8 的检查措辞随之对齐。详细统一说明见第 3.4.2 节顶部的「权威关系声明」。
注意：仍未核实：该文档的其余章节（本次只读了第 2.3 节及其前后各十行）是否还有与本文重叠的命题尚未统一。

---

## 十三、三态计数与自查

### 13.1 计数

> 注意：自指陷阱（本节自身的坑，须先说明）：本节若把三态标记写成字面方括号形态，就会被自己的 `grep` 计入一次，因此计数每次重数都变 1（“计数不可复现”）。故本节内标记一律写作 `〔已实现〕` / `〔已设计未实现〕` / `〔提案〕`（全角括号，不匹配计数正则），其余章节保留方括号形态。
> 复现方式：`grep -o '\[已实现\]' <file> | wc -l`（方括号形态，包含第 13.2 节自查段的引用）。

两种统计方式都给（见既有纪律「枚举型计数随细看只会变多」，因此写「至少 N」+ 清单，不写穷举断言）：

| 统计方式 | 定义 | 复现方式 |
|---|---|---|
| A. 内联标记出现次数 | 全文方括号形态标记的出现次数（同一主张在表内 + 行内会各记一次） | `grep -o '\[已实现\]' <file> \| wc -l` |
| B. 去重主张条数 | 下方索引表的行数（一行 = 一条独立主张 且该行本身不带标记） | `a=$(grep -n '^〔已实现〕逐条索引' <file> \| cut -d: -f1); b=$(grep -n '^〔已设计未实现〕逐条索引' <file> \| cut -d: -f1); sed -n "$a,${b}p" <file> \| grep -c '^| [0-9]'`（注意：必须带 `^` 定位方式：否则会先匹配到本节说明行自身里的同一串，范围起点前移，因此读数虚高，本会话实测过 55 vs 真值 14） |

| 档 | A（出现次数） | B（去重条数） | 说明 |
|---|---|---|---|
| 〔已实现〕 | 39 | 45 | B 档每条带 `file:line`，见下清单 |
| 〔已设计未实现〕 | 27 | 14 | B 档每条带出处文件 |
| 〔提案〕 | 47 | 其余全部（默认档） | A 只数显式写出的标记；未含默认推断档（散落各处、无标记即为提案） |

注意：A 档与 B 档的关系（两阶段合并说明，避免被读成漏登）：
- 上一组 A +2/+2/+3：给第 3.4.2 节七字段表加了「本文三态」列（7 行各带标记），该表是第 3.4.5 节的摘要视图，逐条依据已在索引表第 35–44 条，因此不重复登记为新索引行。
- 本次 A −2/−2/−2：删去了第 3.4.5 节的重复逐字段表（与权威第 7 节是同一份审计工作的两份拷贝，已按权威关系统一），该表原有的标记随之消失；索引表第 35–44 条不变（那是本文独有的实核，仍有效）。
因此两阶段都是“表格增删”，不是主张增删，因此 B 档两次均未变（45 / 14）。A 只随呈现形态浮动，B 才反映主张条数。

读数的三条纪律（实测确立，缺任一条则数不可复现）：

1. 自指：本节方法论若含方括号形态的标记，会被自己的 `grep` 计入，因此本节内一律写全角 `〔〕`。本节改写前的 A 读数为 49 / 22 / 38，改写后为 46 / 19 / 36（那两次），差额恰为方法论自身所含量，非文档内容变化。
2. `A < B` 是正常的（本次起）：索引表的行本身不带标记（只有主张文本 + 位置），故第 13.1 节曾把索引表头写成方括号时 A 会虚高；归一为全角后，一个主张在全文中可以只有索引行、没有行内标记，因此 `A < B` 成立。不要据此判定漏标。
3. 不得反推凑旧数（既有纪律）：本次新增了 C-11…C-13、不变量 89、15 项未核实清单，计数上升是内容增加的必然；若某档数字与本次之前的读数接近或相同，须核是否真未新增，而不是照抄旧值。

> 三态计数随细看只会变多（既有纪律），因此上表读作「至少」；权威 = 下方索引清单，非本表数字。
A 与 B 的差额来源（可复现，不是错）：同一主张常在一处表格 + 一处行内各标一次；索引表本身也是标记出处。差额不是计数错误，是两种统计方式的定义差。

〔已实现〕逐条索引（便于复核；每条均可 `jj file show -r develop@origin <path>` 复现）：

| # | 主张 | 位置 |
|---|---|---|
| 1 | HIT = 硬件接口表，表驱动编码机制 | `src/arch/hit/hit.cr:2,8-10` |
| 2 | HIT 合成层只覆盖直线子集，其余走旧路径 | `src/arch/hit/lower_to_core.cr:2-3,21` |
| 3 | HIT 引擎只进 corearch 清单 | `build_selfhost_native.py:49-51,388` |
| 4 | `flow` 是 token | `src/compiler/lexer.cr:94` |
| 5 | 顶层 `flow fn name()` 语法 | `src/compiler/parser.cr:1726-1749` |
| 6 | 语句位 `flow` 硬拒 P021 | `src/compiler/parser.cr:1002-1010`；`src/compiler/ast.cr:351` |
| 7 | `flow` 的 EBNF 产生式 | `grammar/core.ebnf:22` |
| 8 | `SG_FLOW = 3` 与 region kind 全集 | `src/compiler/dyn_arr.cr:154-159` |
| 9 | region 名映射含 `"flow"` | `src/compiler/dataflow.cr:533` |
| 10 | `T_AT = 70` | `src/compiler/ast.cr:76` |
| 11 | `@` 词法 | `src/compiler/lexer.cr:680` |
| 12 | `EXPR_AT = 46`（表达式位 `@name`） | `src/compiler/ast.cr:218` |
| 13 | 声明级 `@hotpatch(ver=N)` 先例（单槽 + 收 AST 后回退） | `src/compiler/parser.cr:1635-1658` |
| 14 | `@ffi("lang")` on `extern` | `src/compiler/parser.cr:1614-1631,1670` |
| 15 | `@` 内建派发点（`typeInfo`/`raw_int`/`NoBoundsCheck`/`hotpatch`/`ptr_of`/`str_of`） | `src/compiler/checker.cr:4216,4227,4264,4286,4297,4307` |
| 16 | `CCR_VERSION = 9` | `src/compiler/ccr_io.cr:135` |
| 17 | `CCR_SEG_COUNT = 8` + tag 1..8 | `src/compiler/ccr_io.cr:138-140` |
| 18 | `.ccr` 头 16B 布局 | `src/compiler/ccr_io.cr:570-573` |
| 19 | 段表 `seg_count × 12B` | `src/compiler/ccr_io.cr:586,601-602` |
| 20 | 版本检查 `ver != CCR_VERSION -> -1` | `src/compiler/ccr_io.cr:979` |
| 21 | 段号检查 `tg > CCR_SEG_COUNT -> -1` | `src/compiler/ccr_io.cr:1006` |
| 22 | ENT 盘面 28B = `{var_id, version, def_nod, live_start, live_end, home, flags}` | `src/compiler/ccr_io.cr:173-176` |
| 23 | `CIR_CACHE_VER = 22`（独立常量） | `src/compiler/cir_cache.cr:135,170` |
| 24 | `ESZ_SG = 48` + SG 槽偏移 | `src/compiler/dyn_arr.cr:146-152` |
| 25 | `g_df_node_region` 写点 | `src/compiler/dataflow.cr:103`；增长 `dyn_arr.cr:811-813` |
| 26 | `subgraph_containing()` O（1） 归属查询 | `src/compiler/region_check.cr:5-10` |
| 27 | 三 pass 接线 | `src/compiler/main.cr:638-640` |
| 28 | `pa_in_unsafe()` 每调用全扫 SG | `src/compiler/ptr_analysis.cr:15-30` |
| 29 | 三 pass 均为函数粒度 + 逐 DFNode 区间 | `ptr_analysis.cr:172,193,346`；`region_check.cr:105,107,160`；`provenance_verify.cr:52,54,135` |
| 30 | `Core.toml` 只有 `name` | `src/compiler/project.cr`（56 行全文）；`src/compiler/Core.toml` |
| 31 | 调度 = GMP 简化 + 每 M 本地 run queue | `docs/maintainer/design/execution-model.md:75-77`；`src/stdlib/sched.cr:64,82,171` |
| 32 | CLI dump 面（`cir`/`ccr`/`--dump-types`/`--dump-ifaces`/`--dump-params`） | `src/compiler/main.cr:237-240,262,608-609,687` |
| 33 | 错误码分块 + `EC_*` 常量块 + P0xx 号段 | `docs/developer/errors.md`（分节）；`src/compiler/ast.cr:331-357` |
| 34 | cache-semantics 七条 + 范式映射表 | `docs/academic/cache-semantics.md:24-31,79-87` |
| 35 | ENT 内存布局 24B + `OFF_ENTRY_*` 六槽 | `src/compiler/dyn_arr.cr:135-143` |
| 36 | 注意：`flags 恒 0` / `home 恒 -1`（零实例；理由 = 分配决策不写回格式） | `src/compiler/ccr_io.cr:83-85`；`src/compiler/globals.cr:232` |
| 37 | ENT 字段↔规则对应表 + 无方法条目节（`flags bit0 = 无方法` 的设计文档陈述） | `docs/maintainer/design/existence-structure.md:36-46,57-59` |
| 38 | 存在结构的三段总览 + ENT 为“存在结构核心” | `docs/maintainer/design/existence-structure.md:20-34` |
| 39 | 纯度函数真值（`compute_all_purity` / `purity_op_effect`），第 3.6 节推导原料 | `src/compiler/checker.cr:4555,4508` |
| 40 | 注意：零命中核验：`authority` / `replicability` 在 `src/` + `docs/maintainer/design/` + `docs/academic/` 无任何出现 | 本会话 grep 实测（负结果也是实核结果） |
| 41 | 注意：零命中核验：`ExecutionDomain` / `MemoryDomain` / `TopologyLink` 全仓无出现 | 本会话 grep 实测 |
| 42 | `ENT.flags` = u32，bit0–3 已定，因此 bit4–31 空余 28 位 | `src/compiler/dyn_arr.cr:143`；`docs/maintainer/design/existence-structure.md:45` |
| 43 | 注意：ENT 两态记录槽全命名、无空余 4B（内存 6×4B 全满 / 盘面 7×4B 全满，`version` 由组序导出） | `src/compiler/dyn_arr.cr:136-143`；`src/compiler/ccr_io.cr:173-177` |
| 44 | 注意：REG 盘面记录 6×i32 全满、无空余槽（内存 `ESZ_SG` 6×u64 亦满） | `src/compiler/ccr_io.cr:157-162`；`src/compiler/dyn_arr.cr:146-152` |
| 45 | 注意：HIT M2 的四处记载（自本次起 = 以此为准）：仍记「挂账 / 待执行」，无淘汰记载；正是它们把口述裁决翻了过来（维护者改裁「以书面为准」） | `TODO.md:2211`、`TODO.md:2215`；`docs/superpowers/plans/2026-09-07-hit-m2.md:3`；`docs/superpowers/specs/2026-09-07-hit-m2-design.md` |

〔已设计未实现〕逐条索引：

| # | 主张 | 出处 |
|---|---|---|
| 1 | S-C L1–L7 裁决（含 L1 零机器名词 / L2 优化=映射选择 / L3 合法性可判定+收益启发式 / L5 成本模型=数据 / L6 守零新语法） | `docs/superpowers/specs/2026-09-11-performance-without-commitment-design.md` 第 0.2 节 |
| 2 | S-C 第 2.1 节六段流程 | 同上第 2.1 节 |
| 3 | S-C 第 2.2 节合法性/收益分界表 | 同上第 2.2 节 |
| 4 | S-C 第 2.3 节成本模型契约六条（`band` 必填 / 模型非证明 / 与 `PROVED` 不混报） | 同上第 2.3 节 |
| 5 | S-C 第 3.1 节目标描述形态 + `.ccr` 新段表示成本事实 | 同上第 3.1 节 |
| 6 | S-C 第 3.2 节五条可迁移检查 + 三项反向泄漏检测 | 同上第 3.2 节 |
| 7 | S-C 第 0.0 节「机制同一，无第二条性能路线」/ 禁为 SIMD-CUDA-NPU 开特判通道 | 同上第 0.0 节，第 0.5 节 |
| 8 | HIT spec「替换表 = 换目标平台」+ 接口非映射 + 第 3.2 节三范式投影 + 第 4 节可移植子集 + 第 7 节优化不进表 | `docs/superpowers/specs/2026-09-05-hardware-interface-table.md` 第 1 节，第 3.2 节，第 4 节，第 7 节 |
| 9 | `.ccr` tag `9+` 既有主张 = 驱逐标注段 / 证书段 | `docs/superpowers/specs/2026-09-09-lattice-ir-v7-format.md:50` |
| 10 | execution-model 第 5.1 节/第 5.3 节/第 6 节部署配置原则 | `docs/maintainer/design/execution-model.md:180-183,199-201,203` |
| 11 | archive「无格承诺」v4 定稿 | `docs/archive/memory-model-capability-lattice.md:11,14,15` |
| 12 | 〔本次新增〕「格 = 缓存」定义的 7 处既有对应位置（C-11 表逐条行号） | `cache-semantics.md:4`；`project-book.md:109,216`；`z-vision.md:15`；`memory-model.md`（标题 + 第 1 节）；`existence-structure.md`（标题 + 第 3 节表头）；`region-model.md:3-5` |
| 13 | 〔本次新增〕三层映射链的既有层名「图，格，编码」+「中间存在空间」 | `docs/project-book.md:109`；`docs/z-vision.md:15` |
| 14 | 〔本次新增〕`existence-structure.md` 的 `flags` 位语义（bit0–bit3），陈述式，与实现的「预留 + 零实例」有落差 | `docs/maintainer/design/existence-structure.md:45,59` |

### 13.2 自查

- 不变量表：1–4 齐（第 8 节），另补 567 + 〔本次新增〕8（`Evictable` 定义）9（格层不承担 policy）。每条含形式陈述 + 检查形状 + 三态 + 违反后果 + 反向断言。1 的检查已显式处理 STR 段陷阱（否则检查会误报失败）；3489 给的是正反两条断言而非单向。
注意：4 本次加强：七字段完备 + 删除 `valid` 位 + 新增 `authority`/`replicability` 两条专项检查（这两条是旧框架无法表达的档）。
 8 的关键断言 = 第二支 `PreserveRequiredState` 的单独检查（缺它则第二支形同虚设）。
 9 的关键断言 = 可缺席性（清空 policy 后格层判定逐条不变）。
- 数据结构定稿：第 3 节十节，字段级（槽偏移 + 类型 + 含义）。第 3.4 节本次重写为两级结构 + 七字段 + 逐字段距离实核；第 3.5 节删除 `valid` 位。
- 三态标注：第 13.1 节计数；默认 `[提案]`；`[已实现]` 全带 `file:line`。
注意：本次最重要的一条三态修正：`recipe` 不标 `[已实现]`，精确结论 = 「预留槽位 + 恒零值」，`[已设计未实现]`（第 3.4.5 节 / 第 11 节 C-13）。七字段里只有 `identity` / `version` 是 `[已实现]`（且 `version` 仅盘面）。
- 冲突登记：C-1…C-10 + C-11（「格 = 缓存」7 处对应位置）/ C-12（层名）/ C-13（flags 位语义 vs 零实例），每条给断言 / 仓库现状 / 本次结论 / 待裁点，未替维护者裁决；既有「定稿」文档一律未改。
- 〔最新阶段〕HIT M2 淘汰的落实（C-1 重写 + C-3 下调）：
 - C-1 的裁决反转（本节最重的一条，须按“两轮”读）：
 - 第一轮（口述）：维护者经 team-lead 转达「HIT M2 早已淘汰」（未见原话，来源 = 经 lead 转达），因此本节曾据此 1 删去“M4 前补 HIT M2 完成”待裁项；2 论证去进度化；3 判「通用下降路径 = 未被命名的设计空缺」。
 - 第二轮（书面校正，因此整轮回退）：本文按纪律去实核书面记录，找到四处反向记载（`TODO.md:2211/2215`、`plans/2026-09-07-hit-m2.md:3`、`specs/2026-09-07-hit-m2-design.md`），因此维护者改裁「以书面为准」，因此1 待裁项 （c） 恢复（记录式）；2 论证回退到进度化（`lower_to_core.cr:21` 是临时缺口，非永久设计）；3“设计空缺”判定撤回（HIT 仍是既定承担者，待 M2 完成）；4 四处记载自本次起 = 以此为准。
 - 连带登记全部撤回：HIT spec 第 1 节与 S-C 第 0.3 节的“前提失效”不成立（那些是待 M2 达成的目标）。
 - 第 8 节7 恢复为“依赖 C-1 待裁点 （b）/（c）”（不再标注“不可判定”）。
 - 方法论实例已写进文档（C-1 末节）：「口述 vs 书面记载冲突，因此以书面为准」的完整四步实例；要点 = 1 不把口述写成已证事实 2 实核记录是可操作的翻案步骤 3 回退记录、会报错改回。
 - C-3 下调（部分，不受 C-1 反转影响，它是独立的格式实核）：七字段确不需要段（`ENT.flags` 空余 28 位，实测）；注意：但 1 “现有 4B 槽”本文未找到（ENT 内存 6 槽 / 盘面 7 槽全命名）；2 `location` 需域编号，因此位打包给内存域数量设硬上限（= 仓库一直在废弃的 `MAX_*` 模式）；3 REG 记录全满，因此 MAP 若按 region 表示仍须改布局。第 9.3 节倾向由 A 改为 C（placement 不进 `.ccr`，理由 = 不变量 1 本身）。
- 未核实清单：第 12 节十五条（第 15 项 = 与 `materialization-space.md` 的命名对齐义务，已结案，见下）。
- 〔本次〕与权威侧的逐节对拍结果（11 节：8 重叠 / 3 不重叠），权威关系表见文档头：
 - 1 双份实核：本文第 3.4.5 节与权威第 7.2 节各自独立做过「七字段实现距离实核」，因此同一份工作的两份拷贝，必然变化。
 处置：权威版本 = 权威第 7.0 节–第 7.4 节；本文删去重复的逐字段表，只留执行映射侧的两条结论
 ＋ 一处对本文第 9.2 节有直接后果的引用（权威第 7.4 节「位预留了，但记录里没地方再放别的」，其更严，本文采其结论）。
 另：本文原表对 `persistence` 判「槽位在、值恒默认」，权威判「无独立字段」，因此以权威说法为准。
 - 2 政策边界无互指：本文第 0.2 节 / 第 6.7 节与权威第 5 节同命题各写一遍，因此权威版本 = 第 5 节（第 5.1 节明写 + 第 5.2 节可检验检查）；
 本文只保留特有的一句「policy 也不属本文的执行域层」，检查不复述。
 - 3 2′ 公式权威版本：权威第 4.2 节已标「权威版本 = `cache-semantics.md` 规则 2′」，本文未标，因此已补（第 6.4 节与第 8 节8 各一处，写明“改式先改权威版本”）。
 - 4 四问只指文档未指节号，因此已补 `第 2.1 节`（第 0.2 节与第 6.7 节归属表各一处）。
 - 5 陈旧引用：本文原引权威表题为「字段级定稿」，其本轮已改名「字段级模型」（消「定稿」与“本表整体 = [提案]”两说），因此已更新（两处，并留改名记录）。
 - 6 三节不重叠的处置（本文判断）：
 - 第 7.4 节（`.ccr` 分层结论），因此引：它独立支持本文 C-3 的「REG 盘面 6×i32 全满、MAP 若按 region 表示须改布局」，两处互证；
 且它更严（「位预留 ≠ 记录还有地方」），因此本文第 9.2 节结论 1 已按其缩小范围。
 - 第 4.3 节（式的检查形状/断言形状），因此引：与本文第 8 节8 的检查互补（断言形状 = 该式自己的测法；检查 = 不变量族内的正反两条断言），已互相注明不替代。
 - 第 10 节（兼容性声明），因此引（文档头权威关系表），本文侧不另立。
- 〔末阶段〕复核处理（2026-09-20，两条，均为“同一命题两处说法”）：
 - 1 七字段取值域权威关系建立（重）：复核发现权威 `materialization-space.md` 第 2.3 节与本文第 3.4.2 节各给一份取值域、互不指向，
 4/7 行不等（`recipe`/`authority`/`persistence`/`replicability`），正是本文自己命名的第一类命中。
 本文在第 12 节项 15 预告过这条（“未核该文档实际用的字段名是否一致”），因此该文档写入仓库后由「未核」升为「实测不等」。
 处置：第 3.4.2 节改标题为执行映射侧视图 + 顶部加权威关系声明（取值域逐字引第 2.3 节，只保留本文独有的两列实例取值）
 ＋ 全文术语对齐（`recipe = recomputable|unrecomputable` 等，替换原自述词 `yes/no/external`；第 8 节4/第 8 节8 检查措辞随之对齐）
 ＋ 补记权威的两条蕴含关系并导出两条可机械检查的交叉约束。修正记录写在第 3.4.2 节顶部。
 - 2 C-11 标题/时态与自身“已裁”注相反（轻但最易先读到）：标题原写「一律不改」、待裁行写「不裁决…本次一律不改」，
 而 8 行后已写「正由另一名撰写者就地修订」；且文件头 `:6` 与第 0.1 节表仍以现在时引 `project-book.md:216`/`z-vision.md:15`
 为“既有定稿措辞”，那两处已被改。
 处置：标题加「原快照；2026-09-20 起已由另一名撰写者就地修订」＋ 表前加读法说明（表 = 修订前快照，下游要现状请看那些文件本身）；
 待裁行加删除线并指向“已裁”；文件头 `:6` 与第 0.1 节表的时态改为过去式并注明已改。本文（本文件）仍全程未改那 7 个文件。
- 交叉引用：文档头三处，1 `materialization-space.md`（本体定义归它，本文不重复定义，并注明该文件尚不存在）；2 `mapping-layer-separation.md`（投影面 vs 放置面，亦注明尚不存在）；3 `existence-structure.md`（存在格的 IR 表示）。
- 层归属（本次新增）：第 0.2 节 + 第 6.7 节 + 第 8 节9 三处说法一致地划界「格层只答四问 / policy 全归 mapper」。
- 本文档未修改任何既有文件（新增单文件；`/tmp/briefs/*` 两份原始输入亦未动）。
