# 执行映射设计（Execution Mapping Design）

> 定位：受众 = 维护者/贡献者；状态 = **设计定稿（未实现）**——全文除显式标注 `[已实现]` 处外，**均无仓库对应物**。
> 设计意图真源 = **两份**维护者 2026-09-20 口述输入（**本文档均不改写它们**）：
> - `/tmp/briefs/execution-mapping-raw.md` —— 主输入（30 节 + 能力格 + M0–M11）；本文 = 其**形式化展开 + 仓库锚定 + 不变量收紧 + 冲突登记**。
> - `/tmp/briefs/materialization-space-raw.md` —— **对已定稿教义的修订**（「格 = 缓存」→「格 = Materialization / Existence Space，缓存是其中一类映射实例」）。本文 §三/§六/§八 已按其重述；**既有「定稿」文档一律不改**，只登记（§十一 C-11/C-12/C-13）。
> 核验基线 = `develop@origin` @ `38e6c9923ea4`（**所有 file:line 以该修订为准**，非手边检出）。
> 关联：
> - **层定义本体（不由本文承担）**：`docs/maintainer/design/materialization-space.md`（存在格 / Materialization Space 的**本体定义**，另一写手 `existdoc` 负责）。**本文引用它、不重复定义它**；本文只承担「计算 → 执行域放置」这一面。
>   ⚠ **该文件在核验基线上尚不存在**——本条交叉引用是**预定锚点**，待其落盘后双向对齐（本文只加本行，不改那份文件）。
> - [existence-structure.md](existence-structure.md) —— **存在格的 IR 承载**（ENT/NOD/REG）；本文 §3.4/§13.3 的字段距离实核以它为准。
> - 同层设计：[execution-model.md](execution-model.md)（图/region/并发）、[region-model.md](region-model.md)（图锚定区域 = 内存字节域）、[memory-model.md](memory-model.md)（存储语义导航）
> - **缓存语义**：[cache-semantics.md](../../academic/cache-semantics.md)（七条条款）—— ⚠ **本文起不再称其为"存储语义本体"**：按新输入它是**「缓存」这一映射实例的规律**（"经典可再生值的一种映射规律"），层本体归 `materialization-space.md`。既有的"本体"措辞**保持原样不改**（§十一 C-11）。
> - **最紧的兄弟 spec**：[2026-09-11-performance-without-commitment-design.md](../../superpowers/specs/2026-09-11-performance-without-commitment-design.md)（S-C，下称 **S-C**）——本文 §五/§七/§八③ 与它**同构**，且受其裁决约束
> - 编码层：[2026-09-05-hardware-interface-table.md](../../superpowers/specs/2026-09-05-hardware-interface-table.md)（HIT）、[2026-08-23-hw-map-design.md](../../superpowers/specs/2026-08-23-hw-map-design.md)（MMIO 设备表）
> - **交叉引用（勿混）**：`docs/superpowers/plans/2026-09-20-mapping-layer-separation.md` —— 那份是**字节偏移抽象**（语义 → 布局的投影，`offset ∈ extent(entry)`），管的是**同一执行域内**「值落在哪几个字节」；本文是**计算 → 执行域放置**，管的是「这段计算在哪个域发生、跨域怎么物化」。按维护者管线图两者同落 `Lattice → Mapping → Encoding` 的 Mapping 格，**分工 = 投影面 vs 放置面**，粒度/语义/消费方均不同，不得合并、不得互相覆盖。
>   ⚠ **该文件在核验基线上尚不存在**（`docs/superpowers/plans/` 无 `*-mapping-layer-*`）——本条交叉引用是**预定锚点**，待其落盘后双向对齐（本文只加本行，不改那份文件）。

---

## 〇、三态标注约定（全文强制）

本文档凡陈述「仓库现在有什么」的句子，**逐句**带下列标记之一：

| 标记 | 含义 | 举证义务 |
|---|---|---|
| `[已实现]` | 核验基线上有实现 | **必须给 `file:line`**（本会话实核，非记忆） |
| `[已设计未实现]` | 仓库有设计文档/规划但无实现 | 必须给出处文件 |
| `[提案]` | 本文新提出，仓库无对应物 | 无（默认档） |

**默认必须是 `[提案]`**：核不到行号的句子一律不得标前两档。三态计数见 §十三。

### 〇.1 四个必须先立的术语护栏

本文档与既有文档存在**四处同名不同义**，开工前必须钉死，否则后续所有讨论都会串线：

| 词 | 本文档的义 | 仓库既有文档的义 | 处置 |
|---|---|---|---|
| **Region** | **Execution Region** = 放置单位（`flow`/`loop`/`fn` 对应的语义区域） | [region-model.md](region-model.md) 的**图锚定区域** = **内存字节域**（arena），"区域是子图节点的字节域，不是词法作用域的影子" `[已实现]` 分配器面 | **本文一律写全称 `ExecutionRegion`**，不写裸 `Region`；裸 `Region` 保留给内存义 |
| **HIT** | 原文假定 = **baseline universal execution target**（一个执行域） | **Hardware Interface Table** = 表驱动**编码**机制（`src/arch/hit/hit.cr:2`），`[已实现]`；其"替换表 = 换目标平台"（HIT spec §1）表明 HIT 是**机制**不是**域** | 见 §十一 冲突 C-1；本文凡引用原文假设处写 **`HIT`（原文假设义）**，引用仓库物处写 **`HIT（表机制）`** |
| **格 / Lattice** | ⚠ **两义并存，必须分写**：<br>① **存在格 / Materialization Space** = 格层**本体**（本文 §六 用它，本体定义归 `materialization-space.md`）<br>② **Capability Lattice** = **mapper 内部**的能力偏序组织参数（本文 §四） | [memory-model-capability-lattice.md](../../archive/memory-model-capability-lattice.md)（archive，v4 定稿）的「**无格承诺**」：格代数不进入语义本体，是映射实例的**组织参数** | ① 本文写「**存在格**」；② 本文写「**能力格**」，**永不同用一"格"字**。两者都受「无格承诺」约束（§十一 C-6） |
| **缓存 / cache** | ⚠ **本批降级**：「缓存」= **存在格在经典机器上的一类映射实例**（"经典可再生值的一种映射规律"），**不是层本体** | 既有**定稿**措辞：`project-book.md:216`「存储语义**本体**为**缓存语义**」；`z-vision.md:15`「存储半边已定稿（语义本体 = 缓存语义）」；`cache-semantics.md:4`「本文件是 Core 存储语义**本体**的**唯一权威**」 | **既有文档一律不改**（§十一 C-11 逐条行号）。本文**不再写**"缓存 = 存储语义本体"；凡须指既有条款处写「**缓存语义条款**（映射实例规律）」并给出处 |

### 〇.2 层归属：格层不承担 policy（本批新增的硬边界）

新输入明确划出的一条界，**本文全程遵守**：

```
格层（存在格）只回答四问：          全部给 mapper（本文 §五）：
  ① 哪些 materialization 合法          · 什么时候驱逐
  ② 哪些可以共存                        · 放寄存器还是 RAM
  ③ 哪些代表同一 Entry/version          · GPU 是否保留 residency
  ④ 哪些转换保持语义                    · LRU / write-back / write-through / prefetch
```

⇒ **LRU / write-back / write-through / prefetch / 「GPU 是否保留 residency」一律是 `mapping strategy`，既不属格层、也不属本文的执行域层。**
⇒ 本文 §5.2 的 `Cost(R,D)`、§5.5 的调度算法、§5.7 的动态 mapper 全部落在 **mapper** 侧——这一点在旧稿里是隐含的，本批**显式划界**（见 §八 不变量 ⑨）。

---

## 一、目标与范围

### 1.1 一句话目标

> Core 程序只描述计算；Execution Mapping 决定计算在哪个执行域发生，跨域的数据如何物化和迁移；任何未指定或无法优化的计算始终存在通用下降路径。

### 1.2 架构边界（七层链）

```
Source
  ↓
Semantic HDFG                    ← 语义真源；不知道 CPU/GPU
  ↓
存在格 / Materialization Space    ← 不知道 CPU/GPU；**本体定义归 materialization-space.md**
  ↓                                （旧稿此行写 `Lattice / Existence` —— 本批具体化为「存在格」，
  ↓                                 层名与既有「图 → 格 → 编码」的「格」同一，见 §十一 C-12）
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

**三条禁令**（原文，本文不改其强度）：

```
HDFG 不知道 CPU/GPU
Lattice 不知道 CPU/GPU
HIT 不需要为了异构计算修改语义
```

- 前两条 `[提案]`（无实现，但方向与既有分层一致）。
- 第三条 `[已实现]` 的**制度面**：HIT spec §7 已明文「优化不进表（判定/分配 = 格形态层）」，且 HIT 位于发射层、位于 placement 下游 ⇒ **placement 不进表是既有条款**，不是本文新提。
  ⚠ 但该条的**内容面**有实现缺口，见 §十一 冲突 C-1。

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

**`Mapped HDFG` 的定义** `[提案]`：`Mapped HDFG = HDFG ⊕ mapping overlay`。原 HDFG 仍是 semantic truth；overlay 可整体摘除（§八 不变量 ①）。

### 1.4 v1 明确不做（原文 §30，逐条保留）

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
| 无注解 | `placement = automatic` | 必有解（§八 不变量 ⑦） |
| `@preferredDomain(X)` | soft：进 cost function 的偏置项 | fallback → automatic → 通用路径 |
| `@executionDomain(X)` | hard：**部署约束**，非程序语义 | **编译/部署错**（mapping failure），**绝不静默回落** |

`[提案]` —— 三个关键字、两种注解，仓库零对应物。v1 不再增加任何 placement 关键字。

### 2.2 作用范围

原文支持：`fn` · `flow` · `loop`/`for` · 显式 region。

```core
fn pipeline(...) {
    prepare();

    @executionDomain(gpu)
    flow compute { ... }

    finish();
}
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

⇒ **不强迫整个函数进入同一 domain**。

**⚠ 语法现状（实核）**：

| 形态 | 仓库现状 |
|---|---|
| `flow fn name(...) { }`（顶层 flow **函数**） | `[已实现]`：`lexer.cr:94`（`"flow" → T_FLOW`）；`parser.cr:1726-1749`（`is_flow` 置位后**要求**紧跟 `T_FN`）；`SG_FLOW : int = 3`（`dyn_arr.cr:157`）；region 名 `"flow"`（`dataflow.cr:533`）；`grammar/core.ebnf:22` `FlowDecl = 'flow' IDENT [GenericParams] '(' [ParamList] ')' '->' Type` |
| `flow compute { ... }`（函数体内的 flow **块**，原文主例） | **不存在，且被硬拒**：`parser.cr:1002-1010` 对语句位 `T_FLOW` 直接发 `EC_P_NESTED_FN`（P021，`ast.cr:351`）「Nested function declaration is not supported; declare it at top level」 |

⇒ 原文 §2 的**主例在今天是一条 P021 语法错**。M1 的「flow 块」是**新增语法**，不是接线既有语法。
⇒ 而且 `grammar/core.ebnf` 的 `Statement` **不含** `FunctionDecl`（`parser.cr:995-996` 注已写明），故这是**语法面变更**，须同批改 EBNF + 文档 + 负例档。

### 2.3 嵌套规则（一开始定死）

```
@preferredDomain(gpu)
fn foo() {
    ...
    @executionDomain(bigCpu)
    flow x { ... }        // 生效 = bigCpu，不继承 gpu
}
```

**规则**：
1. **离当前 ExecutionRegion 最近的 annotation 生效**；
2. **hard > soft**（同近度下硬约束压软约束）；
3. 父 region 与子 region **允许跨 domain**，对应数据迁移自动产生。

`[提案]`。规则 3 的例：

```core
@executionDomain(gpu)
fn foo() {
    @executionDomain(cpu)
    flow x { ... }        // 合法；自动产生 gpu→cpu 的 materialization
}
```

⚠ 规则 3 与既有 `region_check` 的「活子图」义务**可能交互**（跨域后 Entry 的 kind 属性是否随域改变）——**未核实**，登记在 §十二。

### 2.4 Domain 名不是语言内建

**Core 不内建 `cpu` / `gpu` / `npu` / `cuda` / `vulkan`。语言只认识 `DomainName`。**

`@executionDomain(gpu)` 里的 `gpu` 是**逻辑名**，来自部署配置：

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

换机器只改配置，**Core 源码不用修改**。甚至：

```
@executionDomain(fast)     // 某平台 → CPU 大核；另一平台 → GPU
```

**`[提案]`，但受既有裁决约束（这是硬约束不是建议）**：

- S-C **L1 裁决** `[已设计未实现]`：「**机器形状不进程序意义**：源码/图零机器名词（无宽度、无寄存器、无 SIMD 宽度、**无设备名**）」
- S-C §3.2 反向泄漏检测 `[已设计未实现]`：`c) 源/图中出现机器名词` ⇒ **违反，登记为「泄漏待归一」**

⇒ 因此本节的逻辑名纪律不是风格建议，而是**已有裁决的操作面**。⚠ 但原文自己给的例子（`cpu` / `gpu` / `bigCpu`）**全部是机器名词**；只有 `fast` 是合规形态。**登记为冲突 C-7，不替维护者裁决**（可能裁决是"逻辑名允许与机器同形"）。

---

## 三、数据结构定稿

> 本节把原文散落的结构收紧到**字段级**。所有结构 `[提案]`（仓库无对应物）；
> 但**承载方式** `[已实现]`：Core 编译器侧表一律是**扁平定长记录 + `OFF_*` 槽偏移**的字节缓冲（先例 = `ESZ_SG : int = 48` + `OFF_SG_KIND/ENTER/EXIT/PARENT/NSTART/NCOUNT`，`dyn_arr.cr:146-152`），故本文也用同一idiom写死。
> `u64` 槽宽与 `OFF_*` 命名沿用仓库惯例；尺寸标注为本文规范（实施批可改，须同批改本节）。

### 3.1 ExecutionDomain

```
ExecutionDomain {
    id                        // 逻辑名（部署配置键），非机器名
    backend                   // 后端标识；backend 自己回答 canLower(region)
    attachedMemoryDomains[]   // 见 §八 不变量 ②
    dispatchModel
    profile                   // → PerformanceProfile（§3.8）
    capabilities              // → CapabilityDomain（§3.7）
    limits                    // 数值上限（见下）
}
```

原文 §5 第一版形态与「论文核查后」形态（加 `capabilities`/`limits`/`executionProfile`）**合并**为本节；差异见下注。

| 槽 | 名 | 类型 | 含义 |
|---|---|---|---|
| 0 | `ed_id` | 名索引 | 逻辑域名（部署配置键） |
| 8 | `ed_backend` | 名索引 | 后端标识；`canLower/estimateCost/emitVariant` 的派发键（§五） |
| 16 | `ed_mem_head` | 下标 | 附着 MemoryDomain 链头（`-1` = 无） |
| 24 | `ed_cap` | 下标 | CapabilityDomain（§3.7） |
| 32 | `ed_limits` | 下标 | 数值上限表（`matrixTile <= 128` / `localStorage <= 96KiB` 之类） |
| 40 | `ed_profile` | 下标 | PerformanceProfile（§3.8） |
| 48 | `ed_dispatch_model` | 码 | 派发模型（v1 只用于诊断/dump，不参与判定） |
| 56 | `ed_flags` | 位域 | 保留 |

**两条设计约束**（原文明确）：① 不做复杂 capability taxonomy —— `backend` 自己回答 `canLower(region)`，**语言不维护 `supportsMatrix`/`supportsBranch`/`supportsPointer` 大全**；② `capabilities`（离散合法性）与 `limits`（数值上限）**分开**——「96 KiB」不得被丑化成 `hasLargeSharedMemory`。

`[提案]`；`backend 自己回答 canLower` 这一条**有仓库前件**：HIT spec §3.2「无实现：条目缺失 → 编译期拒绝或 unsafe 外部入口」`[已设计未实现]`——即"能力协商在表/后端侧，不在语言侧"已是既有立场。

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

**公理**：`ExecutionDomain ≠ MemoryDomain`，**不得合并**（§八 不变量 ②）。

`[提案]`。⚠ **最近但不同的既有物**：`docs/maintainer/design/region-model.md` 的「图锚定区域」= **字节域** `[已实现]` 分配器面；那是内存侧的**一个经典映射实例**（cache-semantics 条款 7 `[已实现]` 文档面），**不是** domain 表。不要把两者混为一谈。

### 3.3 TopologyLink

原文初版 `{fromMemory, toMemory, latency, bandwidth, setupCost, coherent, shared}`；
论文核查后**加强**为：

| 槽 | 名 | 类型 | 含义 |
|---|---|---|---|
| 0 | `tl_src` | 下标 | 源 MemoryDomain |
| 8 | `tl_dst` | 下标 | 目标 MemoryDomain |
| 16 | `tl_setup_latency` | u64 | 建立延迟（→ `setupCost` 的更名形态） |
| 24 | `tl_bandwidth` | u64 | 带宽 |
| 32 | `tl_coherent` | 0/1 | 一致性 |
| 40 | `tl_shared` | 0/1 | 共享内存（`CPU0↔CPU1: shared=true, coherent=true`） |
| 48 | `tl_async` | 0/1 | 支持异步传输 |
| 56 | `tl_bidir` | 0/1 | 双向 |
| 64 | `tl_max_inflight` | u64 | 在飞传输上限 |
| 72 | `tl_engines` | u64 | transfer engine 数 |

**加强的理由**（原文）：两个看似相同的 32 GB/s 连接，若 A 只能同步复制、B 有两个 DMA engine 可双向并行，**调度行为完全不同** ⇒ latency/bandwidth 两项不足。
反向证据 `[已实现]` 级别的同型论证：`sched.cr` 的队列是**每 M 一条本地 run queue**（`sched_enqueue(g: string)` / `sched_dequeue(m_idx: int)`，`src/stdlib/sched.cr:64,82`）——即"通道的并行度"在仓库里确实被显式建模，不是被带宽吞掉。

`[提案]`。

### 3.4 Materialization

> ⚠ **本批重写**：旧稿此处是 `Entry X: DDR valid / VRAM valid`（**缓存副本**措辞——隐含"有权威值 / 可复制 / 副本同值"三假设）。按新输入 `/tmp/briefs/materialization-space-raw.md` 升级为**两级结构 + 七字段**（`Semantic Entry → Materialization`）。
> **本体定义不在此处**——归 `docs/maintainer/design/materialization-space.md`（另一写手）。本节只写**本文消费到的字段面**与**仓库距离实核**。

#### 3.4.1 两级结构（不是"Entry 的两份副本"）

```
Semantic Entry                      ← 语义对象（身份 + 版本），不是存储物
    │
    ├── Materialization M0 @ location
    │       recipe / identity / version / authority / persistence / replicability
    │
    └── Materialization M1 @ location
            recipe / identity / version / authority / persistence / replicability
```

⚠ **与旧稿的措辞差异（本文批次要点）**：旧稿写 `Entry X` 直接挂 `DDR valid / VRAM valid`——那是**把 Entry 当存储物**。新结构里 **Entry 是语义对象，`location` 才在 Materialization 上**；且**没有全局 `valid` 位**（"哪份新鲜"的判据被 `authority` 取代）。

#### 3.4.2 字段定稿（新输入 §"一个 Entry 可以有"七项）

| # | 字段 | 类型 | 含义 | 缓存实例取值 | MMIO 实例取值 |
|---|---|---|---|---|---|
| 1 | `recipe` | 0/1 | **是否可再生**（有配方 ⇒ 可重算） | `yes` | `no` |
| 2 | `identity` | 下标 | **语义身份** | 产生节点 | 产生节点（= 设备读数节点） |
| 3 | `version` | u64 | **哪个版本** | 版本序数 | 版本序数 |
| 4 | `authority` | 枚举 | **哪份 materialization 有权威性** | 可转移 / 可重建 | `device`（设备侧权威） |
| 5 | `location` | 下标 | **当前在哪里存在** | DDR / VRAM / 寄存器 | 设备寄存器窗口 |
| 6 | `persistence` | 枚举 | **是否必须持久保留** | 否（可驱逐） | `external`（外部持久） |
| 7 | `replicability` | 枚举 | **能不能复制** | `yes` | `no/limited` |

原文给的两个实例（照录，供对照）：

```
缓存：  recipe = yes   replicable = yes   evictable = yes   authority 可转移/可重建
MMIO：  recipe = no    replicable = no/limited   persistent = external   authority = device
```

#### 3.4.3 本文的 mapper 侧附加槽（`[提案]`，非格层）

以下两槽**不属存在格**，是本设计为 mapper 加的（§〇.2 划界；本体字段以上表七项为准）：

| 槽 | 名 | 类型 | 含义 |
|---|---|---|---|
| `mt_materialize_op` | 下标 | **可调度 operation 句柄** —— 使 materialization 可 prefetch/async/overlap（§6.4） |
| `mt_memd` | 下标 | 所在 **MemoryDomain** —— 域归属，属放置层（§3.2） |

⚠ `location`（格层，语义位置）与 `mt_memd`（放置层，具体内存域）**不是同一槽**：前者回答"存在形式"，后者回答"在哪个域"。合并会把格层与放置层搅在一起。

#### 3.4.4 「缓存」降级为特例（六个假设 + 反例）

新输入点名的、被"缓存"一词偷偷带进的**六个假设**——它们在经典 CPU/GPU 内存/寄存器分配/异构 residency 上成立，但在列举的反例上**不成立**：

| # | 假设 | 反例（新输入列举，含既有文档佐证） |
|---|---|---|
| 1 | 有一个原始/权威值 | **分布式唯一 authority**（无单点权威） |
| 2 | 可以复制 | **一次性 token** / **线性资源**（复制本身非法） |
| 3 | 可以驱逐 | **事务中的临时状态** |
| 4 | 可以重新物化 | **不可重复 oracle** / **随机数** / **量子测量**（重跑 ≠ 原结果） |
| 5 | 通常存在 backing store | **MMIO read** / **外部输入** |
| 6 | 不同副本原则上表示同一个值 | 同上第 2/4 条的反例 |

`[提案]`。⚠ **仓库侧已有独立佐证**：cache-semantics **条款 4b** 已把「图内不可重算」条目单列，并规定「驱逐不变量/再生等价**对其不成立**」（`docs/academic/cache-semantics.md:28`；细读 `:50-59` 给两类：边界 MMIO/FFI/输入/测量、图内不可重算 神谕/BSS/FIXPT/模糊融合）。
⇒ **本批的新框架把条款 4b 从"例外条款"升格为"一般规则的支柱"**：条款 2/3（可驱逐/可再生）成了 `recipe = yes` 那一档的**特例**。

#### 3.4.5 与仓库的锚定（**逐字段距离实核**——本批最有价值的结果）

⚠ 先纠正一个**容易误判**的说法：`recipe` **不是**"实现里已经是一个真 bit"。**精确结论 = 「预留位 + 恒零值」**：

| # | 字段 | 设计文档对应物 | **实现对应物** | 三态 |
|---|---|---|---|---|
| 1 | `recipe` | `existence-structure.md:45` flags `bit0 无配方`；`:59` 规范陈述「bit0 = 无配方（图内不可重算）——**必须有 home**」 | ⚠ **槽位在、值恒零**：`OFF_ENTRY_FLAGS : int = 20;   // 位 0 **预留**：无配方（条款 4b）`（`dyn_arr.cr:143`）；`flags(20) u32 = 0（位 0 预留：无配方，条款 4b）`（`globals.cr:232`）；`flags **恒 0**（无配方/参数/全局/驱逐位**零实例**——位语义保留）`（`ccr_io.cr:85`） | **`[已设计未实现]`** |
| 2 | `identity` | 条款 4b「**身份 = 产生节点**」（`cache-semantics.md:28,59`）；`existence-structure.md:42`「`def_nod` = 定值节点 id」 | `OFF_ENTRY_DEF : int = 4`（`dyn_arr.cr:139`）；盘面 28B 第 3 字段（`ccr_io.cr:173-176`） | **`[已实现]`** |
| 3 | `version` | 条款 5（`cache-semantics.md:29,61-67`）；`existence-structure.md:41` | 盘面 `version`（`ccr_io.cr:173-176`，同 var 组内 1-based 序数，`ccr_io.cr:82-83`）；⚠ **内存态无该槽**（24B，靠组序推导，`ccr_io.cr:175`） | **`[已实现]`（盘面）/ 推导（内存态）** |
| 4 | `authority` | 条款 4b 的"home 保有材料"**隐含**权威，但**无该名词** | ⚠ **零命中**：全仓 `authority` 在 `src/` 与 `docs/maintainer/design/`、`docs/academic/` **无任何出现**（本会话 grep 实测） | **`[提案]`** |
| 5 | `location` | [region-model.md](region-model.md) 的字节域归属（`g_df_node_region`）；REG 段存在区间 | ⚠ **ENT 无 location 字段**；最近物 = `home`（槽位）+ REG 段存在区间（`existence-structure.md:73-86`） | **`[提案]`** |
| 6 | `persistence` | 条款 4b + `home`（`existence-structure.md:44`「条款 4b + 条款 7 的接口」） | ⚠ **槽位在、值恒默认**：`OFF_ENTRY_HOME : int = 16`（`dyn_arr.cr:142`），但 **`home 恒 -1`**（`ccr_io.cr:83-84`「home 恒 -1（实例注记——**分配决策不写回格式**，字节 spec §3.5）」） | **`[已设计未实现]`** |
| 7 | `replicability` | **无对应物** | **零命中** | **`[提案]`** |

**两条由本表得出的结构性结论**（本文分析，非原文）：

1. **`recipe` 与 `persistence` 是同一形态**：**槽位已预留、值恒为默认**——`flags = 0` / `home = -1`。且**原因同一**，`ccr_io.cr:83-84` 明写："**分配决策不写回格式**"。⇒ 二者**不是"未设计"，而是"设计了槽位但写侧不做决策回填"**。
   ⚠ 这对实施批的含义：`recipe` 若要变成活位，**不需要改布局**（位已预留），需要的是**一个写点 + 一个消费点**；`persistence` 同理（`home` 回填的既有计划见 `existence-structure.md` §八开放点 3「ENT home 回填方式」）。
2. **七个字段里四个落在 `[提案]`/`[已设计未实现]`，只有 `identity` / `version` 两字段是实打实的 `[已实现]`**。⇒ 新框架**不是对既有实现的重新描述**，而是一次**真实的抽象升级**——不要把"ENT 里已经有 version 和 home 了"读成"新框架已实现"。

- `[已实现]` state edges 本体：`DFEdge` 的 `kind=1` 边 = state edge（`docs/maintainer/design/execution-model.md:36,57`）——"副作用链与循环终止依赖"。
- ⚠ **`version` 的既有解释须改口**：旧稿此处写"本节的版本化…是**条款 5** 在**多内存域**下的展开"。按新输入，条款 5 属**缓存映射实例**的规律 ⇒ 正确措辞 = "**存在格的版本性**在缓存实例上的投影恰好是条款 5"。**结论（版本化成立）不变，归属变了**（§十一 C-11）。

### 3.5 ResidencyState

**本批重写**（旧稿是 `{memoryDomain, version, valid}`——`valid` 是**缓存假设 #6「不同副本同值」**的残留）：

```
ResidencyState {
    entry                      // 语义对象
    materializations[]         // 该 Entry 在当前时刻的物化集合
}
```

= **`Materialization` 的索引视图**（`entry → [materialization]`），不另立本体结构。每个元素带 §3.4.2 的七字段。

⚠ **`valid` 位被删除**（本批要点）：旧稿的 `X2: DDR valid / VRAM stale` 是"哪份新鲜"的**副本有效性**模型；新框架用 **`authority`** 取代它（"哪份有权威性"）——因为对**无配方条目**（`recipe = no`），"VRAM 那份比 DDR 那份旧"这句话**没有意义**（两份可能都不是可再生的；且 `replicability = no` 时根本不该有两份）。

`[提案]`；`version` 面 `[已实现]`（盘面，§3.4.5）；`authority` 面**零命中**（§3.4.5 第 4 行）。

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

（原文"四对象"节给的是六项 `operations/control/addressing/synchronization/effects/guarantees`；
能力维度给的十项。**本文合并为十项**，与 §四 的十个能力轴一一对应——原文两处不一致，本文按能力维度为准，见 §十一 冲突 C-8。）

**关键约束**：RegionRequirement **不由程序员写**，须从 **HDFG 自动推导最小能力集** `minimalRequirements(region)`（原文 §"Requirement 应该从 HDFG 自动推导最小能力集"）。

推导例：

```
flow x { for i in 0..n { out[i] = a[i] + b[i]; } }
   ⇒ { Computation: int32/add, Control: loop, Parallelism: data,
        Addressing: indexed, Effects: none }

while p != null { x = x + p.value; p = p.next; }
   ⇒ { Control: dynamicLoop, Addressing: indirect+pointerLike,
        Storage: persistent }
```

**最小 basis 而不是全量附载**：若 `generalIndirectAddressing` 已隐含 `load`/`addressMapping`/`randomAccess`，就**不要全部重复存**——否则 `.ccr` / mapping metadata 膨胀。

`[提案]`。
⚠ **但推导的原料面大量 `[已实现]`**：`effects` 可从 state 链 + 真纯度取（`compute_all_purity`，**`checker.cr:4555`**；opcode 单一真源 `purity_op_effect`，**`checker.cr:4508`**）；`control` 可从 region kind 取（`SG_LOOP/SG_FOR/SG_IF/SG_FLOW/SG_UNSAFE`，`dyn_arr.cr:154-159`）；`addressing` 可从指针分析取（`ptr_analysis.cr`）；`storage` 可从 region 的 arena 归属取（`g_df_node_region`）。

> ⚠ **行号漂移告警（本文实核）**：S-C §1 表同两处引用写的是 `checker.cr:2959` / `:2912`，在核验基线 `38e6c9923ea4` 上**已指向无关代码**（恰好是 `}`）。真值 = `:4555` / `:4508`。⇒ 凡从 S-C 转引 `file:line` 处**一律须现查**，不得直接搬运（既有纪律：修订已不是当前基线 ⇒ 复核任何清单的第一步 = 把声明基线换成当前基线）。**本文其余引用均为本会话现查值。**
⇒ **requirement 推导不是从零开始**，是**消费既有 pass 输出**。这一条应在实施批当第一刀（见 §七）。

### 3.7 CapabilityDomain

原文最终定稿（"四部分"）：

```
CapabilityDomain {
    SemanticCapabilities      // 离散"能不能"
    NumericLimits             // 数值上限
    Guarantees                // 语义保证（非性能）
    Extensions                // 后端扩展
}
```

内部最好不是平表而是：

```
Capability {
    id
    parents[]        // 依赖闭包：generalIndirectAddressing → indexed → linear
    constraints[]    // parameter + range + set + predicate
}
```

**闭包优先**：设备只声明 `generalIndirectAddressing`，**不需要重复声明三层**（SPIR-V capability 机制的借用）。同理 `fp64Atomic → fp64, atomic`。

**约束形态支持 parameter + range + set + predicate**（不只是枚举）：

```
VectorWidth >= 8
Float ∈ {fp16, fp32}
LocalStorage >= 48KiB
Atomic ∋ compareExchange
Addressing >= indexed
```

⇒ region 可推 `Requires: LocalStorage >= 32KiB`；GPU A 有 64KiB → 合法；GPU B 有 16KiB → 非法。

**合法性条件**：`Req(R) ⊑ Cap(D)`（`⪯` = 偏序：`C₁ ⪯ C₂` 表示 C₂ 至少能正确实现 C₁ 所要求的语义）。

**命名空间纪律**：`core.*` 只描述跨硬件通用语义能力；vendor capability 只允许"优化 specialization"，**不能成为普通 Core 程序正确运行的必要前提**（除非用户明确选择 vendor-specific deployment）——否则会慢慢变成 CUDA feature table。

`[提案]`。⚠ **与档案的硬约束**见 §十一 C-6。

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

`[提案]`。**与 Capability 的分家 = §八 不变量 ③。**

⚠ **S-C 已给该对象的接口契约，本文必须服从而不是另立** `[已设计未实现]`（S-C §2.3）：

- 必填四项：`band`（不确定带——**单点数字给人"精确"错觉 = 过度承诺**）/ `model_id` / `model_ver` / `assumptions[]`
- 接口形态**以 S-D §1.7.3 的 `cost_model_query` 为准**，本文不另立
- 契约 1（事实/模型分离）：成本事实 = 表条目字段；"如何用事实决策" = 编译器侧可替换件（HIT spec §3.3「表只描述材料，不描述放置策略」`[已设计未实现]`）
- 契约 2：缺失 = 保守退化，**不猜**
- 契约 3：**相对量纲**，不承诺绝对值、不承诺最优
- 契约 5 **硬性**：估计值**不得**呈现为 WCET 证明 / 时间上界；`MODELED` 必须明标"模型估计，非证明"
- 契约 6：成本估计只进 `MODELED` 层，**不得**与 `PROVED` 数字合并/覆盖/相减

⇒ 本文的 `Cost(R,D)`（§5.3）**是 MODELED 层的量**，其输出面必须按上述四项与两层不混报纪律交付。原文未提这一层，**本文补上**（这是写作义务，不是新增设计）。

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
| 8 | `rs_queues` | 每 domain 的待派发队列 | `[提案]`；最近既有物 = **每 M 一条本地 run queue**（`sched.cr:64,82`）`[已实现]`——**粒度不同**（M = OS 线程，不是 domain） |
| 16 | `rs_load` | 域负载 | `[提案]` |
| 24 | `rs_avail` | 可用性（域当前是否可派发） | `[提案]` |

### 3.10 MAP 段条目

原文建议（§21）：placement 信息**附着在 region metadata**，或**单独增加 MAP section**：

```
MAP entry:
    regionId
    mode              // AUTO / PREFER / REQUIRE
    domainName
```

**最大原则**（原文加粗）：

> **placement metadata 不应该改变 HDFG 的语义 identity。**

即 `flow x { ... }` 与 `@preferredDomain(gpu) flow x { ... }` **语义图是同一张图**，区别只进入 mapping。

| 槽 | 名 | 类型 | 含义 |
|---|---|---|---|
| 0 | `mp_region` | 下标 | region 标识（对应 `g_sgs` 下标或 DFNode 区间，实施批定） |
| 8 | `mp_mode` | 码 | `0=AUTO 1=PREFER 2=REQUIRE` |
| 16 | `mp_domain` | 名索引 | 逻辑域名（`AUTO` 时 `-1`） |
| 24 | `mp_flags` | 位域 | 保留 |

`[提案]`。**承载代价 `[已实现]` 级实核**见 §九——新增段**不是免费**的。

**三态的落地建议**（本文补）：原文说"或更干净地单独增加 MAP 映射 section"。本文**倾向独立段**，理由 = 不变量 ① 的逐字节判据在独立段下可写成"摘除 MAP 段后其余段逐字节同"，而附着在 REG 记录内时该判据退化为"REG 记录字段数不变"，**判据强度更弱**。→ 记入 §十一 C-3（不裁决）。

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

**严格分家**：

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

`[提案]`。**三条取自原文的设计要点**：

1. **`divergentControl` 不是说它"快"**——只是"这种执行域能正确表示 lane 之间不同的控制流"。具体 divergence 多贵，由 **profile** 决定（= 不变量 ③ 的又一处落地）。
2. **`Storage` 与 `Addressing` 必须分开**——前者描述"可以有什么存储"，后者描述"计算如何访问数据"。一个 NPU 可能 `Storage: private, domainShared` / `Addressing: indexed`，但不支持 `indirect`/`pointerLike` ⇒ **这种 region 直接被排除**。
3. **`Guarantees` 是合法性条件，不是性能条件**——某段代码的规约要求 strict IEEE FP，某 accelerator 只有 relaxed FP ⇒ **即使它再快也不能进入候选集**。

### 4.3 格与闭包（论文核查后的加强）

- `Cap(D)` 应首先做闭包 `closure(Cap(D))`（§3.7）。
- 偏序例：`FP16 ⪯ FP16+FP32 ⪯ FP16+FP32+FP64`；`indexed ⪯ gatherScatter ⪯ generalIndirect`。
- ⇒ 合法映射 = `Req(R) ⪯ Cap(D)`。**比几十个 `if capability_x` 干净**。

### 4.4 不要照搬 SYCL 的设备类别

借用 SYCL 的"设备可查询自身能力"；**不借**"设备必须属于 cpu/gpu/accelerator 分类"。
⇒ 不要 `Cap { gpu = true }`，而是 `Cap { fp64 indirectAddress dynamicControl matrix ... }`。
⇒ "两个都是通用 CPU，只不过 A 某类计算快、B 稍慢"**完全没有特殊情况**：**相同 CapabilitySet，不同 Profile**。

`[提案]`。

---

## 五、Placement 模型

### 5.1 基本单位

**不要逐 DFNode 调度。基本单位 = Execution Region。**

来源：HDFG region · `flow` · `loop` · `function`。之后 compiler 可进一步 **region fusion / region split** 得 **ExecutionCluster**。

```
DFNodes → semantic regions → execution clusters → placement
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

**而不是** `N1 CPU / N2 GPU / N3 CPU ...`——否则 transfer / dispatch 成本直接爆炸。

`[提案]`。**距仓库现状的距离**（本文实核，见 §七）：region 归属数据 `[已实现]`，但现有 pass 的形状是**函数粒度 + 逐 DFNode 区间扫描**。

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

**关键反模式**：`preferredDomain` **不要作为绝对规则**：

```
preferredDomain(gpu)  ⇒  cost(gpu) -= preferenceBonus
                      或  other domains += preferencePenalty
```

⇒ GPU 极度不划算时**仍然可以选 CPU**。

论文核查后（加强）：

```
Score(R,D) = EFT(R,D) + FutureCost(R,D) + PolicyPenalty(R,D) + PreferencePenalty(R,D)
```

其中 `@preferredDomain(gpu)` **只改变 `PreferencePenalty`**。⇒ 用户指定 `@preferredDomain(gpu)` 但"GPU currently overloaded / transfer = 80ms / CPU = 2ms"时**仍然可以 CPU**——**这个行为应明确写进 spec**。

`[提案]`。

### 5.3 不只优化单个区域（避免 greedy 陷阱）

`A → B → C`，单独看 B：`CPU = 10 / GPU = 2`，似乎应该 GPU。但 `A CPU→B GPU = 8`、`B GPU→C CPU = 8`：

```
CPU: 10
GPU: 8 + 2 + 8 = 18
```

⇒ **B 应该留 CPU**。

### 5.4 目标函数 = Makespan（论文核查后定稿）

```
min Makespan(G, P)        P : Region → ExecutionDomain
约束：Req(R) ⪯ Cap(P(R))
再考虑：C_exec / C_materialize / C_sync / C_dispatch
以及这些操作之间是否可以 overlap
```

**比 `min Σ Cost(R,D)` 更合理。**

### 5.5 第一版算法：Residency-Aware HEFT → PEFT look-ahead

原文 §14 流程：

```
1. 得到 ExecutionCluster DAG
2. 为每个 cluster：estimate execution cost on each domain
3. 为每条跨 cluster edge：estimate transfer cost
4. 按 criticality / upward rank 排序
5. 逐个选择 earliest finish domain
6. 应用 hard/soft placement constraints
```

Core 版比传统 HEFT 多一个 **Residency** ⇒ **Residency-Aware HEFT**。

论文核查后（加强）：

```
HEFT baseline → PEFT-style optimistic future cost → Residency-aware adjustment
```

**而不是只写 `pick minimum EFT`**：`A → B → C`，B 是 `CPU = 10 / GPU = 2`，但若 C 只能在 CPU 上很好执行、`GPU → CPU transfer = 20`，PEFT-style look-ahead 比纯 local EFT 更容易避免错误迁移。

### 5.6 Criticality 应该是 runtime 状态

`fastCpu` / `slowCpu` 例：若 region **不在 critical path**，`R → slowCpu` 可能完全没问题；把 `fastCpu` 留给 critical region 可能反而让整个程序更快。
⇒ cost model 里应明确增加 `criticality(region)`，**不要仅仅比较 region 自己完成时间**。

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

编译时**知道**：HDFG · dependency · region · operation · estimated data volume · static N · state edges。
编译时**不知道**：GPU 当前负载 · 输入的实际大小 · 实际 residency · 温度/功耗限制 · 其他任务负载。

原文 runtime 例：

```
R: CPU = 5ms, GPU = 1ms;  input = 400MB, currently DDR;  DDR→VRAM = 7ms
⇒ CPU 5ms / GPU 8ms ⇒ CPU
下一次数据已在 VRAM ⇒ GPU 1ms ⇒ GPU
```

⇒ **这就是为什么 Residency 必须是一等映射信息。**

`[提案]`。

### 5.8 Placement 约束的失效语义（原文 §6 —— 本节最硬的一条）

```
automatic mapping
      │
      ├── 找到更优 execution domain → use it
      │
      └── 没找到 → 通用下降路径（HIT 原文假设义）
```

**但 `@executionDomain(gpu)` 不同**：

| 注解 | 目标域不存在时 |
|---|---|
| `@executionDomain(gpu)` | **ERROR**——不能静默 fallback，否则硬指定失去意义 |
| `@preferredDomain(gpu)` | fallback → automatic → 通用路径 |

⇒ 见 §八 不变量 ⑤。

### 5.9 `@executionDomain` 的性质：deployment constraint，不是 program semantics

```
⟦R_HIT⟧ = ⟦R_CPU⟧ = ⟦R_GPU⟧
```

语义完全相同，只是 execution mapping 不同。因此：

- semantic equivalence **不应**因 CPU vs GPU 改变；
- 若 deployment 无法满足 `@executionDomain(gpu)`，那是 **mapping failure**，**不是 semantic/type error**；
- 诊断**最好单独归类 `EMAP…`**，而不是 TF/TK 一类类型错误。

⇒ **本文补**：`EMAP` 开族在仓库里有**明确的制度位置** `[已实现]`：错误码分块（`docs/developer/errors.md` 分节 L0xx/P0xx/N0xx/I0xx/TA0xx/TF0xx/TB0xx/TU0xx/TC0xx/TM0xx/TK0xx/TS0xx/TG0xx/B0xx/R0xx/V0xx）与 fail-closed 门（`diag.cr` 的豁免表 `diag_gate_exempt`）+ 常量块（`ast.cr:331+`，P0xx = 1001–1029 / N0xx = 2001+）。
⇒ 实施批须**同批**：新常量块（数值 + 文档节 + 门注册 + 豁免表重定）。**这是既有纪律，不是本文新增要求**。

### 5.10 variant 与避免爆炸

一个 region 可存在多个 lowering：

```
Region R
Variant:   HIT（原文假设义） / CPU / GPU
```

语义相同，只是 mapping 不同。**第一版规则**（原文 §17）：

```
HIT variant              → 永远存在
hard executionDomain     → 只生成指定 domain + HIT 验证参考（可选）
preferred / automatic    → 只生成 Top-K 候选      例如 K = 2
```

⇒ 正常桌面 `R: HIT / CPU optimized / GPU` 已经够了。**不能**每个 region × 每个 domain × 每种 optimization 全生成。

### 5.11 Backend 接口（概念面）

```
canLower(region, domain)
estimateCost(region, domain)
emitVariant(region, domain)
```

**不要让 mapper 直接 `if GPU ...` / `if CPU ...`** ⇒ 新增硬件只需要实现 backend。

`[提案]`。⚠ 与 S-C §0.0 的**硬约束**一致：`禁止为 SIMD / CUDA / NPU 各开特判通道（与 §1.2.2「禁止内建特判」同构）` `[已设计未实现]`。

### 5.12 静态部署模式

```toml
[execution]
mapping = "static"
```

编译时直接 `R1 → CPU0` / `R2 → accelerator0` / `R3 → CPU0`，**binary 里没有 dynamic mapper**。
⇒ 同一模型同时支持：desktop dynamic · server dynamic · embedded static · bare-metal static。

### 5.13 部署策略（职责分离）

```toml
[execution]
objective = "performance"      # 以后可：performance / latency / energy / balanced
```

**源码**：`@preferredDomain(gpu)` 描述 placement 偏好。
**部署**：`objective = energy` 描述环境策略。
⇒ **这两个职责必须分开**；**不要把这些变成源代码 annotation**。

---

## 六、Residency 与 Materialization

### 6.1 数据不属于 CPU 或 GPU

假设 Entry X：语义仍然只有 `X`，**不存在** `X_cpu` / `X_gpu`。

⚠ **本批措辞升级**（旧稿此处写 `DDR -> valid / VRAM -> valid`——**那是缓存副本措辞**，隐含"有权威值 + 可复制 + 副本同值"三假设）。新形态：

```
Semantic Entry X                ← 语义对象：identity + version（不挂在任何域上）
    │
    ├── Materialization @ DDR    recipe / identity / version / authority / location / persistence / replicability
    └── Materialization @ VRAM   同上七字段
```

⇒ CPU → GPU 数据迁移的语义**不是** `copy X into another X`，而是 **materialize X in target memory domain**。
⇒ **源码永远不应该出现 `copyToGpu()` / `copyToCpu()` / `cudaMemcpy()`。**
⇒ ⚠ **并且**：新框架下还需检查 **`replicability`**——若该 Entry `replicability = no`（一次性 token / 线性资源），则"在 VRAM 再物化一份"本身**非法**，不是"贵"。旧稿的 `valid` 位模型**无法表达这一档**（它默认副本总是允许的）。

### 6.2 自动 transfer

图 `Region A → Region B`，placement `A → CPU` / `B → GPU`：mapper 检查依赖 Entry（`A produces X` / `B consumes X`）⇒ 自动规划 `materialize X in VRAM`。
最终后端可能下降成 DMA / PCIe transfer / shared memory mapping / zero-copy / unified memory——**这些都不是 Core 语义**。

### 6.3 Materialization 是可调度 operation（不是成本项）

原文 §"Transfer 不能只是成本"：

```
CPU compute
       \
        Materialize(X, VRAM)
                \
                GPU compute
```

⇒ materialization 可以 **prefetch / async / overlap compute / pipeline**。
⇒ 未来不是 `T = Compute + Transfer` 这么简单，而可能 `T ≈ max(Compute_A, Transfer)`（若二者能 overlap）——**这会极大影响 mapper**。

⚠ **本批划界**：`prefetch` / `async` / `overlap` 是 **mapper strategy**（§〇.2），**不属格层**。格层只回答"这个 materialization 合法吗 / 与谁可共存 / 代表哪个 Entry+version / 这个转换保语义吗"；**"要不要预取"是 mapper 的决定**。

### 6.4 驱逐不变量的改写（新输入的核心修订）

**旧表述（本文旧稿，照 cache-semantics 条款 2/3）**：

> 所有东西都可以驱逐，只要能**重算**或**写回**。

**新表述**：

```
Evictable(x)  ⟺  Recoverable(x) ∨ PreserveRequiredState(x)
```

即一个 materialization 能消失，当且仅当：

- 之后能**重新得到等价状态**（`Recoverable` = 缓存实例里的"有配方可重算"）；**或者**
- 消失前**已经把必须保留的状态转移到其他合法 materialization**（`PreserveRequiredState`）。

`[提案]`。**这比"缓存驱逐"更一般**——它不预设"有 backing store"（假设 5）也不预设"副本同值"（假设 6）。

**与既有条款的关系（本文分析）**：旧条款 2/3（驱逐不变量 `⟦G ∖ storage(e)⟧ = ⟦G⟧` / 再生等价）对应新式的**第一支 `Recoverable`**；条款 4b 的"驱逐必写回"对应**第二支 `PreserveRequiredState`**。
⇒ **条款 2/3/4b 并未被推翻**——它们是新式在**缓存实例**上的取值。**这正是"缓存降级为特例"在驱逐面上的落点。**
⇒ 且旧稿 §6.5 登记的那条"实质张力"（条款 4b vs 副本模型）**在新框架下消解**：条款 4b 是第二支的正例，不是例外条款。见 §十一 C-2（状态由"待裁"改为"已被新框架涵盖，仅待维护者确认"）。

### 6.5 接缓存语义 —— ⚠ **方向反转（本批最重要的改写）**

原文 §8 说"应该直接和 Core 已经有的 cache semantics 接起来"。**旧稿的解释是错的**——它把 cache-semantics 条款当成**层本体**，于是写成"本文的 Materialization 模型 = 条款 5 + 条款 6 的展开，不是新本体"。

**新输入下的正确方向**：

```
旧（错）：  materialization 模型  ⊂  缓存语义条款        （缓存 = 本体，materialization 是它的实例）
新（对）：  缓存语义条款  ⊂  存在格 / Materialization Space（缓存 = 映射实例，materialization 是本体）
```

原文的直接引语：

> 图 → 存在格 / Materialization Space → 编码
> **缓存语义 = 经典可再生值的一种映射规律**

**因此本文旧稿 §6.4 的"逐条对表"必须反向读**——那些条款**不是本文的语义依据，而是缓存这一映射实例的规律**。改写后的对照表（列序已反转，并标出**哪些条款在新框架里不再是普遍的**）：

| 缓存语义条款（**映射实例规律**） | 在存在格中的位置 | 出处 |
|---|---|---|
| 条款 1 值 = 配方 | 对应 `recipe = yes` 一档的**身份来源**；`recipe = no` 档**不适用** | `cache-semantics.md:24` |
| 条款 2 驱逐不变量 | `Evictable` 的**第一支** `Recoverable` 的一个实例 | `:25` |
| 条款 3 再生等价 | 同上（`Recoverable` 的机制保证） | `:26` |
| 条款 4 边界公理 | 对应 `recipe = no` + `authority = device/external` | `:27` |
| 条款 4b 图内不可重算 | 对应 `recipe = no` + `persistence = 必须` + `authority` 不可转移 | `:28,50-59` |
| 条款 5 赋值 = 版本化 | 存在格的**版本性**在缓存实例上的投影（§3.4.5 末注） | `:29,61-67` |
| 条款 6 地址 = 映射 | 属**编码/映射**面，不入存在格 | `:30,69-71` |
| 条款 7 映射实例正确性 | **正是"缓存是映射实例"这条的既有条款形态**——它本来就是"任何映射实例的正确性标准" | `:31,73-75` |

⇒ **条款 7 是新旧框架的接缝**：它早已写成"**任何**映射实例（区域/arena/字节权限/寄存器）的正确性标准是同一个"，而不是"缓存是本体"。**新输入把这个早已写下的普遍性提到了层名上。**
⇒ 条款 7 已给出 `mapping preservation proof` 的**既有定理形态**（"映射正确性定理"）——原文说"甚至可以以后接形式化验证"，**仓库已经把这条通路写成条款了**。
⇒ 本文旧稿"本文的 Materialization 模型**不是新本体**"这句**已作废**：按新输入，存在格**就是**本体层，而**缓存才是实例**。

### 6.6 缓存 = 特例（七字段取值表）

新输入给的判据（照录）：缓存只是

```
recipe = yes
replicable = yes
evictable = yes
authority 可转移/可重建
```

的特例。MMIO 例：`recipe = no / replicable = no|limited / persistent = external / authority = device`。

完整取值对照见 §3.4.2；六个被"缓存"带进的假设及其反例见 §3.4.4。

### 6.7 policy 不属格层、也不属执行域层（本批显式划界）

新输入点名**四类 mapping strategy**——LRU / write-back / write-through / prefetch——以及问题"GPU 是否保留 residency"：

> 这些都应该是 **mapping strategy**，不是格层语义。

⇒ 本文的归属：

| 事项 | 归属 |
|---|---|
| 哪些 materialization 合法 / 哪些可共存 / 哪些代表同一 Entry+version / 哪些转换保持语义 | **存在格**（本体，归 `materialization-space.md`） |
| 什么时候驱逐 · 放寄存器还是 RAM · GPU 是否保留 residency · LRU / write-back / write-through / prefetch | **mapper**（本文 §五） |
| 换域要付多少代价 | **mapper cost model**（§5.2，S-C §2.3 契约） |

⇒ 见 §八 不变量 ⑨。**旧稿把这四类策略混在 §六 里叙述**（例如 §6.3 原文的 prefetch/overlap 段落），**本批已划出**。

### 6.8 与并发的统一（原文 §29）

`go f()` 和 execution mapping **不应该冲突**。动态 HDFG 产生的新 region 依然可以 runtime placement：

```
spawn region R → mapper → CPU1 / CPU2 / GPU
```

⇒ 异构 execution model 与现有动态图模型**统一**，而不是另造 GPU concurrency。

⚠ **本批重述**（旧稿此处写"缓存语义"作为统一依据——按 §6.5 的层归属已过时）：统一所依据的**不是缓存语义**，而是**存在格**——`spawn` 产生的新 region 只是**新的语义对象**，其 Entry 的物化/迁移与静态 region 走**同一套** `materialization` 规则（§3.4 七字段对两者一视同仁：`recipe` / `authority` / `replicability` 与"是否并发产生"无关）。
⇒ 这正是新框架的收益之一：**并发不是缓存的特殊情形**，因此不需要"GPU 专用并发模型"。

`[提案]`。**最近既有物** `[已实现]`：并发 = Go 风格 GMP 简化（P 并入 M，M 数量 = CPU 核数；`docs/maintainer/design/execution-model.md:75-77`）；`go f(args)` 语义 = 分配 G + 16KB 栈 + 新 arena → 状态 `_Grunnable` → **投递到 M 的 local run queue**（同文档 §三 3.2）；实现 = `sched_go`（`src/stdlib/sched.cr:171`）= `g_new + sched_enqueue`。
⇒ **接线点 = `sched_enqueue`**（放置决策的插入位置），但**队列是 per-M 而非 per-domain** ⇒ 距离 = "队列键从 M 换成 ExecutionDomain"，不是新增调度器。

---

## 七、与既有 pass 的接线（本文补，原文无）

### 7.1 三个安全 pass 的**实核消费面**

| pass | 入口 | 形状 | 区间 | 接线 |
|---|---|---|---|---|
| `ptr_analysis.cr` | `ptr_analysis_all()`（`:346`）→ `ptr_analysis_func(nstart, ncount, vstart, vcount)`（`:172`） | **函数粒度**：`loop { if fi >= g_ir_func_count { break; }`，内层 `loop { if ni >= nstart + ncount { break; }`（`:193`） | 逐 **DFNode** |
| `region_check.cr` | `region_check_all()`（`:160`）→ `region_check_func(nstart, ncount)`（`:105`） | 函数粒度：内层 `loop { if ni >= nstart + ncount { break; }`（`:107`） | 逐 **DFNode** |
| `provenance_verify.cr` | `provenance_verify_all()`（`:135`）→ `provenance_verify_func(nstart, ncount)`（`:52`） | 函数粒度：内层 `loop { if ni >= nstart + ncount { break; }`（`:54`） | 逐 **DFNode** |

接线点 `[已实现]`：`src/compiler/main.cr:638-640` 顺序调用三者。

### 7.2 region 归属数据 **已存在**（原文 §7 的"基本单位"有现成地基）

| 物 | 位置 | 内容 |
|---|---|---|
| `g_df_node_region` | 写点 `dataflow.cr:103`（`w64(g_df_node_region, nid * 8, g_cur_sg)`，`-1 = none`）；增长 `dyn_arr.cr:811-813`；消费 `region_check.cr:5-10` | **node → owning SG**，O(1) 查询（`subgraph_containing()`） |
| `g_sgs` region 表 | `ESZ_SG : int = 48` + `OFF_SG_KIND/ENTER/EXIT/PARENT/NSTART/NCOUNT`（`dyn_arr.cr:146-152`） | **region 已带 `[NSTART, NSTART+NCOUNT)` 节点区间** |
| region kinds | `SG_FUNC=0 / LOOP=1 / FOR=2 / FLOW=3 / UNSAFE=4 / IF=5`（`dyn_arr.cr:154-159`） | 原文 §7 的"来源：HDFG region · flow · loop · function"**逐一对得上** |

### 7.3 ⇒ 距离判定（诚实版）

原文 §7「不要逐 DFNode 调度」：

- **数据面**：`[已实现]`——region 区间 + node→region 映射都在，**且 region 已经是索引区间**。
- **pass 形状**：**不是** per-region。三个 pass 都是"遍历函数节点区间、按需调 `subgraph_containing()` / `pa_in_unsafe()`"。
  ⚠ 且 `pa_in_unsafe()`（`ptr_analysis.cr:15-30`）**每次调用都全扫 `g_sg_count` 个 SG**——O(SG) per node，**已被 QC 化为 O(nodes × SGs)**。
- ⇒ **距离 = pass 重构（把"逐节点 + 内层查归属"改成"逐 region 外循环"），不是新增 IR 或新增归属数据。**
- ⇒ 且重构**顺带修一个既有复杂度问题**（上条 O(nodes×SGs)）——实施批应把这条作为**收益**而非纯成本记入。

### 7.4 与 S-C 六段流程对齐（**不要另立第二条流程**）

S-C §2.1 `[已设计未实现]`：

```
① 事实推导（图 pass）      依赖闭包 / 效应集 / 使用计数 / 索引来源 / 生命周期
② 候选生成（可判定性门）    每条变换附合法性前提清单；前提不可判 → 候选缺席（保守）
③ 成本评分（成本模型接口 ← 表成本事实 + 资源约束）
④ 选择（策略数据：目标描述 + 阈值/约束）
⑤ 记录（决策记录 → §5）
⑥ 发射（实例层：编码 / 布局 / 调度）
```

本文的 placement 流水线**逐段对齐**：

| 本文段 | S-C 段 |
|---|---|
| Requirement Inference | ① 事实推导 |
| capability compatibility（`Req ⊑ Cap`） | ② 候选生成 |
| Cost + Topology + Residency + Criticality + FutureCost | ③ 成本评分 |
| Placement Solver + `@preferredDomain`/`@executionDomain` | ④ 选择 |
| Mapped HDFG | ⑤ 记录 |
| Variant Selection → Backend | ⑥ 发射 |

⇒ **本文不另立流程**；placement 是 S-C 六段在"跨执行域"方向的实例化。**实施批必须服从 S-C 的 L1–L7 裁决与 §2.3 成本模型契约。**

### 7.5 S-C §2.2 的分界 = 本文 §八 不变量 ③ 的既有契约

S-C §2.2 表（`[已设计未实现]`）：

| 层 | 判据 | 性质 | 失效后果 |
|---|---|---|---|
| **合法性** soundness | 图前提（无依赖路径 / 无效应 / 索引仿射可证 / …） | **可判定**（保守：unknown = 否） | 该变换不选——**语义不变** |
| **收益** profitability | 成本估计 + 阈值 | **启发式**（可错，待论证） | **只影响性能，绝不影响语义** |

承重属性（S-C L3）：**任何变换的缺失都可接受——直接形态恒合法。**

⇒ 本文的 `Req ⊑ Cap` **必须落在"合法性"行**，`Cost(R,D)` **必须落在"收益"行**。这就是不变量 ③ 的完整形式。

---

## 八、不变量表（本文核心交付）

> 每条给：**形式陈述** / **可执行判据的形状** / **三态** / **违反后果** / **反向钉子**。
> 判据写法遵既有纪律：**判据组须两向钉子**（反向钉当场红 = 最好的诊断）；**单向判据对反向缺陷恒绿**。

### 不变量 ①：placement metadata 不改变 HDFG 的语义 identity

- **形式陈述**
  ```
  对任意 ExecutionRegion R 与任意 placement 注解集 A：
      ⟦HDFG(erase(A) ⊕ R)⟧ ≡ ⟦HDFG(R)⟧
  加强（逐字节）：serialize(HDFG(erase(A) ⊕ R)) == serialize(HDFG(R))
  其中 erase(A) 删除全部 AUTO/PREFER/REQUIRE 元数据，不动任何值流/state edge/region 结构
  ```
  等价于：**`erase(annotations)` 后语义图逐字节同**（原文原则："`flow x { }` 和 `@preferredDomain(gpu) flow x { }` 语义图是同一张图"）。

- **可执行判据的形状**（将来怎么测）
  1. **正腿（同源对拍）**：同一 `flow` 区域取两版源码（有/无 placement 注解）→ `corec cir` 产物 `.cir` **逐字节 `cmp`**；`corec ccr` 产物同理。
     ⚠ **必须限定口径（本文实核的陷阱）**：新增的**逻辑域名是编译期 interned 串** ⇒ 若域名进 STR 段，`.ccr` 会多一条串 ⇒ **"逐字节同"必假**。判据须写成 **「摘除 MAP 段后，其余段逐字节同」**（或域名不进 STR 段、改走部署配置侧索引）。**这是一条会让判据假红的已知机制，必须写进判据文本。**
  2. **负腿（正控 = 注解确实生效）**：MAP 段**非空** + dump 面**确实显示** domain constraint（否则"什么都不做"也恒绿 = 覆盖为零）。
     ⇒ **判据对 = {其余段逐字节同} × {MAP 段非空}**；缺任一条 = 判据网失效。
  3. **结构腿**：`erase(A)` 后 `.ccr` **段数**回到基线、**版本不变**。
  4. **端到端腿**：两版源码 `build` 产物在**同一目标描述**下，值/效应序/rc/输出一致（对齐 S-C §3.2 判据 1「观测等价：同程序 + 不同目标描述 → 值/效应序/rc/输出一致」的镜像方向）。

- **三态**：`[提案]`（无 MAP 段）。**但语义半边的锚 `[已设计未实现]`**：S-C §3.2 反向泄漏检测 `b) 决策结果被写回图/源码语义 ⇒ 违反，登记为「泄漏待归一」`——**仓库已定义该不变量，只是没有承载物**。
- **违反后果**：placement 泄漏进语义 = 换部署改语义 ⇒ 直接击穿 S-C **L2 裁决**（"优化 = 映射选择，非图修改"）与 L1（机器形状不进程序意义）。
- **反向钉子**：构造一个**故意**把 domain 名写进值流/类型的最小改动，断言判据 1 **当场红**。做不到 ⇒ 判据是真空的。

### 不变量 ②：`ExecutionDomain ≠ MemoryDomain`（不得合并）

- **形式陈述**
  ```
  ¬∃ 双射 f : ExecutionDomain → MemoryDomain 使得 f 保持全部映射语义
  更强的可观测形式（存在性证明，反证合并）：
    (i)  ∃ d₁ ≠ d₂, ∃ m :  d₁ attach m  ∧  d₂ attach m          （多执行域共一内存域）
    (ii) ∃ d, ∃ m₁ ≠ m₂ :  d attach m₁  ∧  d attach m₂          （一执行域多内存域）
  两者皆可满足 ⇒ 合并会丢信息 ⇒ 不得合并
  ```
  原文例：`CPU0/CPU1/NPU → DDR` 且 `GPU → VRAM` 满足 (i)；`CPU/GPU/NPU → UnifiedMemory` 满足 (i)+(ii)。

- **可执行判据的形状**
  1. **配置腿**：部署配置构造 (i)/(ii) 两例 → 断言 mapper 的**候选域索引**与 **residency 键空间**是**两个独立 id 空间**（不共用 id 分配器、不互相索引）。
  2. **检索腿**：给 `(d, m)` 对，`attachedMemoryDomains(d)` 与 `attachedExecutionDomains(m)` 是**两个分别回答的函数**（一域多内存、一内存多域都能答）。断言二者**不同构**（存在 (i) 例 ⇒ 前者非单射）。
  3. **负控（关键）**：把两表**合成单表**（强制一一对应）⇒ 上述配置腿必须**当场红**。若合成后仍绿 ⇒ 判据没有真正约束合并。
  4. **前端腿**：`@executionDomain(X)` 的 X **只能**解析到 ExecutionDomain 命名空间；解析到 MemoryDomain 名必须是**硬错**（且**不是** TF/TK 码——§5.9）。

- **三态**：公理 `[提案]`。仓库**无 `MemoryDomain` 名词**（本会话全仓 grep `MemoryDomain|TopologyLink|ExecutionDomain` 零命中）。⚠ **最接近但不同的既有物** = [region-model.md](region-model.md) 的图锚定区域（**字节域**，`[已实现]` 分配器面）——它只是**内存侧的一个映射实例**（条款 7），**不是** domain 表，**不可拿它充当 MemoryDomain**。
- **违反后果**：合并后无法表达"统一内存"与"两 CPU 共一 DDR"两类真实硬件 ⇒ 模型对**第一版就要覆盖的** CPU↔CPU 假异构（§十 M4）直接失效。
- **反向钉子**：见负控 3。

### 不变量 ③：`Capability ≠ Performance`（合法性 vs 优劣分家）

- **形式陈述**
  ```
  合法性判定  legal(R, D) := Req(R) ⊑ closure(Cap(D))      ——只读 CapabilityDomain
  收益评分    score(R, D) := f(Profile(D), Topology, Residency, Criticality, RuntimeState)
                                                            ——只读性能/物理/运行期面

  组合规则 = 先后过滤（不是加权和）：
      candidates(R) = { D : legal(R, D) }
      placement(R)  = argmax_{D ∈ candidates(R)} score(R, D)

  两个方向都必须成立：
    (a) Capability 缺失 ⇒ D ∉ candidates(R)，且**不能被 score 翻盘**
    (b) 性能缺失 ⇒ D 仍 ∈ candidates(R)（退化用默认形态），且**不得使非法 D 成为候选**
  ```
  ⚠ **硬性**：`legal` 是**可判定**量（unknown ⇒ 否，保守）；`score` 是**启发式**量（可错）。二者**不得**进入同一个加权和——否则"极便宜的非法域"会被选中。

- **可执行判据的形状**
  1. **腿 (a)**：构造 `Req ⊄ Cap(D)` 但 `score(D)` 极小（如成本恒 0）的配置 → 断言 `D ∉ candidates` 且 `placement ≠ D`。**防"成本翻盘合法性"。**
  2. **腿 (b)**：构造 `Req ⊑ Cap(D)` 但 profile 全缺失（或 `UNKNOWN`）→ 断言 `D` 仍可被选中、程序仍编译、行为正确。**防"缺成本 = 不可执行"。**
     ⚠ 此腿须与 S-C §2.3 契约 2/5 对账：缺失 = **保守退化，不猜**；且**不得**用"经验常数"兜底成 `MODELED`。
  3. **两向钉子**：腿 1 与腿 2 **互为反向钉**——只写腿 1 会把实现逼成"成本永远不生效"；只写腿 2 会放过"成本翻盘"。**必须同时在场。**
  4. **Guarantees 单列腿**：构造 `Guarantees` 不满足（如 strict IEEE FP vs relaxed FP 域）但 `score` 极优 → 断言不入选。**这是"合法性条件不是性能条件"的专项钉子。**

- **三态**：**仓库已有对应分界的明文** `[已设计未实现]`——S-C §2.2「合法性 soundness = 可判定 / 收益 profitability = 启发式」表 + **L3 裁决**（"合法性可判定、收益启发式（分离原则）"）+ 承重属性"任何变换的缺失都可接受——直接形态恒合法"。
  ⇒ **本条的判据形态直接对齐 S-C §2.2 的列语义，不另立分界。**
- **违反后果**：击穿 S-C L3；且把"能否正确执行"与"哪个更快"混成一个数 ⇒ 引入**静默错误映射**（非法域被选中）——这是本设计最危险的失效形态（静默 rc=0 类）。
- **反向钉子**：见腿 3。

### 不变量 ④：materialization 只回答「是哪个 Entry Version 的物化」＋ 七字段完备

- **本批加强**：旧稿此条只有 `(entry, version, memory_domain, home?, valid)`。按新输入升级为**七字段**（§3.4.2），并**删除 `valid`**（它是缓存假设 #6 的残留，被 `authority` 取代）。

- **形式陈述**
  ```
  Materialization := (recipe, identity, version, authority, location, persistence, replicability)
                     + mapper 侧附加（mt_materialize_op, mt_memd —— 不属格层，§〇.2）

  必须（正）：
    每个 Materialization 携带精确的 (identity, version)
    每个 consumer 的读必须**指定 version**（版本来自图，不来自运行期比较）
    version 是**定义性字段**（存在格的版本性），不是被观测出来的
    authority 唯一确定：任一时刻至多一个 authoritative materialization（或其权威在 device/external）

  禁止（负）：
    ¬∃ 谓词 newer(m₁, m₂)   ——不存在"哪份更新"的全局比较
    ¬∃ 查询 latest(entry)   ——不存在"取最新副本"的接口
    ¬∃ valid 位             ——"新鲜度"不是格层谓词（authority 取代之）
    ¬∃ 消费者按「值相等」判定可复用（值比较不是版本代数）
    ¬∃ 对 replicability = no 的 Entry 生成第二份 materialization（复制本身非法，§3.4.4 #2）

  驱逐/再生语义**按字段分档**（旧稿写"按配方案别"，本批改为字段驱动）：
    recipe = yes            → 可跨域再生（Recoverable，§6.4 第一支）
    recipe = no  ∧ persistence = 必须 → home 必填、驱逐必写回（PreserveRequiredState，第二支）
    replicability = no      → 不得复制；迁移若非"移动"语义则非法
  ```
- **可执行判据的形状**
  1. **正腿（原子性）**：构造 `X1@DDR` 与 `X2@VRAM` **同时存在**，断言 GPU 消费 `X2` 时**必须**产生 `materialize(X2 → VRAM)`——**不得**复用 `X2@DDR`（域错）也**不得**误用 `X1@VRAM`（版本错）。两向都给期望值（域错与版本错各一条档）。
  2. **接口腿（结构性）**：静态扫消费面，断言**不存在** `latest()` / `newest()` / **`valid` 位** / 跨域 `max(version)` 之类的查询点。⚠ 判据须**限定为"跨 MemoryDomain 的比较"**——**同域内**的版本推进比较（存在格的版本性）**不违反**本条。**不加限定 = 判据会对合法实现恒红（过判）。**
  3. **分档腿（本批按字段重述）**：对 `recipe = no` 条目断言：`persistence` 必填、跨域"再生"路径**不可用**（必须写回而非重跑）；**反向**对 `recipe = yes` 断言可驱逐可再生。**两向钉子**：只写前一条会把所有条目都当不可再生（过判）。
  4. **`authority` 腿（本批新增）**：断言**至多一个** authoritative materialization（或权威显式落在 `device`/`external`）；反向：构造两份都标 authoritative ⇒ 必须**硬错**。⚠ 这是唯一能抓住"副本同值"假设回归的判据。
  5. **`replicability` 腿（本批新增）**：对 `replicability = no` 的 Entry，断言"再物化一份"路径**不存在/被拒**（而不仅是"贵"）；反向：对 `replicability = yes` 断言复制合法。**这是旧框架完全无法表达的一档**（旧 `valid` 位模型默认副本总是允许）。
  6. **版本可折叠（防过判）**：`X1` 与 `X2` 在**版本代数**上可证等价（如 `x = x + 0` 类）⇒ **允许**复用。⚠ 但**不得**靠值比较实现——判据要能区分"按代数折叠"与"按值相等折叠"（后者须红）。
  7. **逐字节腿**：物化动作的注入**不得**改变语义图（与不变量 ① 共用正腿）。

- **三态（本批实核修正）**：⚠ **不是**"核心字段都已实现"——逐字段距离见 §3.4.5。摘要：七字段中 `identity`（`def_nod`，`dyn_arr.cr:139`）与 `version`（**仅盘面**，`ccr_io.cr:173-176`）是 `[已实现]`；`recipe` 与 `persistence` 是 **`[已设计未实现]`（槽位预留、值恒默认）**；`authority` / `location` / `replicability` **零命中 → `[提案]`**。
  ⚠ 盘面/内存不同构（`ccr_io.cr:175`：内存 `ESZ_ENTRY` = 24B **无 version 字段**）——实施批须显式处理这个不对称。
- **违反后果**：退回"哪块内存最新"的 mutable-memory reasoning ⇒ 跨域读错版本 = **静默错误值**；或对不可复制资源生成第二份副本 = **语义非法却 rc=0**。
- **反向钉子**：见腿 3 的双向、腿 4、腿 5。

### 不变量 ⑤：hard constraint 不可静默降级

- **形式陈述**：`@executionDomain(X)` ∧ `X` 不可用 ⇒ **mapping failure（硬错，rc=1，零产物）**。**不得**回落 automatic、**不得**回落通用路径、**不得** rc=0。
- **判据形状**：负控档 = 目标域**不存在**（部署配置里无该键）→ 断言 `rc=1` + 诊断含 `EMAP` 码 + **零产物**。
  ⚠ **面纪律（既有裁决）**：被 build-scope 豁免的码在 **build 面**「零产物」恒假 ⇒ 负控须写 **`check` 面 rc=1 + 含码**；豁免表须随硬错化重定。
  两向钉：`@preferredDomain(X)` 同配置 ⇒ **rc=0** + 回落（防"一律报"）。
- **三态**：`[提案]`。**判据纪律 `[已实现]`**（fail-closed 门 + 豁免表 `diag_gate_exempt`）。
- **违反后果**：硬指定失去意义（原文："否则硬指定就失去意义"）；且是**静默类**缺陷（rc=0）——本仓最重视的失效形态。

### 不变量 ⑥：静态部署下 runtime mapper = erased（同一语义，无第二条路径）

- **形式陈述**：`mapping = "static"` 时，`R → D` 在编译期定死；产物中**不含** dynamic mapper；且**判定结果与 dynamic 模式一致**（同一 `Req ⊑ Cap` 判定，同一 hard/soft 语义）。
- **判据形状**：同源码两种 `mapping` 模式 → 断言 (i) static 产物中无 mapper 符号/无运行期域查询；(ii) **两者都不违反不变量 ①**（语义图同）；(iii) static 下 `@executionDomain` 不可满足仍是硬错（与 ⑤ 同判）。
  两向钉：(i) 的正控 = dynamic 产物**确实含** mapper（否则"删了 mapper"和"从未生成"不可区分）。
- **三态**：`[提案]`。
- **违反后果**：嵌入式/裸机支持变成第二条代码路径 ⇒ 语义分叉。

### 不变量 ⑦：未指定 ⇒ 恒存在合法映射

- **形式陈述**：AUTO（无注解）的 region 恒存在至少一个合法域。**这是"通用下降路径"的形式化。**
- **判据形状**：对**全语料**（`tests/suite/*.cr` + `src/compiler/*.cr` 自身）断言 AUTO region 的 `candidates(R) ≠ ∅`。**覆盖为零的判据只会腐烂不报错**，故须挂到既有语料 runner 而非独立小档。
  反向钉：构造一个 `candidates(R) = ∅` 的畸形配置 ⇒ 断言它是**硬错**而非静默。
- **三态**：`[提案]`。⚠ **依赖 C-1 的裁决**——若通用路径不是 HIT（表机制），则本条的"通用域"身份待定（C-1 待裁点 (b)/(c)）。
  **本批留痕**：本注一度被改为"**本条目前不可判定**"（依据维护者口述「HIT M2 早已淘汰」）；**经四处书面记载校正后已回退到本句**（维护者改裁「以书面为准」，详见 C-1 的裁决反转留痕）。

---

### 不变量 ⑧：`Evictable(x) ⟺ Recoverable(x) ∨ PreserveRequiredState(x)`（本批新增）

- **形式陈述**
  ```
  Evictable(x) ⟺ Recoverable(x) ∨ PreserveRequiredState(x)

  Recoverable(x)           := recipe(x) = yes ∧ 存在合法路径重新得到等价状态
  PreserveRequiredState(x) := 在 x 消失前，必须保留的状态已转移到其他**合法** materialization
                              （"合法"由不变量 ④ 的七字段判定——尤其 authority 与 replicability）

  推论（负向，必须同时成立）：
    ¬Recoverable(x) ∧ ¬PreserveRequiredState(x) ⇒ ¬Evictable(x)   —— 驱逐**非法**，不是"昂贵"
  ```
  ⚠ 关键：**`Evictable` 是合法性谓词，不是性能谓词**（与不变量 ③ 同族）。"驱逐它可以，但很慢"与"驱逐它不合法"是**两个不同档**，不得混。

- **可执行判据的形状**
  1. **两向钉子**：(a) 构造 `recipe = no` 且 state 未转移的条目 ⇒ 断言驱逐**被拒**（硬错/零产物），**不是**"执行了但慢"；(b) 构造 `recipe = yes` ⇒ 断言驱逐**合法**。只写 (a) 会把所有条目当不可驱逐。
  2. **第二支专项钉**：构造 `recipe = no` 但 state **已**转移到合法 materialization ⇒ 断言驱逐**合法**。⚠ 这条是"第二支"的唯一钉子；**缺它则第二支形同虚设**（实现可以永远只走第一支而判据全绿）。
  3. **合法性 ≠ 性能 的分离钉**：构造 `Evictable = 真` 但成本极高 ⇒ 断言决策仍是 **mapper** 的选择（可能选择不驱逐），而**不是**格层把它标为非法。**反向**：`Evictable = 假` ⇒ 断言**任何**成本都不能让它被驱逐（与不变量 ③ 腿 (a) 同形）。
  4. **与旧条款的一致性腿**：对 `recipe = yes` 条目，断言新式与条款 2/3 的判定**逐条一致**（防"新式松到把缓存实例判错"）；对 `recipe = no`，断言与条款 4b 的"必写回"一致。

- **三态**：`[提案]`。既有条款 2/3/4b 是它在**缓存实例**上的取值 `[已设计未实现]`（文档面 `cache-semantics.md:25-28`）。
- **违反后果**：把"非法驱逐"实现成"合法但慢" ⇒ **不可再生状态被丢弃** = 静默语义破坏（本仓最重视的失效形态）。
- **反向钉子**：见腿 2（第二支）与腿 3（合法性/性能分离）。

### 不变量 ⑨：格层不承担 policy（本批新增）

- **形式陈述**
  ```
  格层判定的值域 ⊆ {合法 / 可共存 / 同一 Entry+version / 保语义}      —— 四问，全是**判定性**问题
  mapper 决定   ⊇ {何时驱逐, 放寄存器还是 RAM, 是否保留 residency,
                    LRU, write-back, write-through, prefetch}          —— 全是有向退化的**策略**

  禁止（负）：
    格层的判定输出**不得**依赖任何 policy 参数（阈值/历史/负载/时钟）
    格层**不得**出现 "preferred" / "hot" / "recently used" 之类策略谓词
    policy 缺失**不得**改变格层判定结果（可缺席性）
  ```
- **可执行判据的形状**
  1. **可缺席性腿**：清空全部 policy 配置（无 `objective`、无阈值、无 PGO 数据）⇒ 断言**格层判定结果逐条不变**（与带 policy 时对拍）。**这是本条的承重钉**——若格层判定随 policy 变，则 policy 泄漏进了格层。
  2. **策略词零命中腿**：静态扫格层面（`materialization-space.md` 的规则 + §3.4 字段 + §八①④⑧），断言无 `LRU` / `prefetch` / `hot` / `recent` / `write-back` 等策略词。⚠ 判据须**限定在格层面**——mapper 侧（§五）**必然**有这些词，不加限定会恒红。
  3. **两向钉**：反向构造一个**必须**靠 policy 才能决定的问题（如"这两份等价 materialization 该保留哪份"）⇒ 断言格层**拒绝回答**（返回"二者皆合法"），把选择留给 mapper。**这说明格层没有越界。**
- **三态**：`[提案]`。**既有同型纪律** `[已设计未实现]`：S-C **L5**「成本模型 = 数据 + 可替换组件…不进表；HIT spec §3.3「优化不走表」」——本条是它的姊妹条款（"策略不进格"）。
- **违反后果**：policy 进格层 ⇒ 换部署改语义判定的**可观测部分** ⇒ 击穿不变量 ① 与 S-C L2。
- **反向钉子**：见腿 3。

## 九、承载：IR 与 `.ccr` 格式（代价实核）

### 9.1 `.ccr` 格式现状 `[已实现]`

| 项 | 值 | 位置 |
|---|---|---|
| `CCR_VERSION` | **9** | `src/compiler/ccr_io.cr:135` |
| `CCR_SEG_COUNT` | **8** | `src/compiler/ccr_io.cr:138` |
| 段 tag | `1=STR 2=SYM 3=NOD 4=ENT 5=REG 6=EDG` + `7=TYPE 8=IFACE` | `ccr_io.cr:138-140`；`docs/.../2026-09-09-lattice-ir-v7-format.md:50` |
| 头 | 16B = `{magic u32, version u32, seg_count u32, reserved u32}` | `ccr_io.cr:570-573`；格式文档 §2 |
| 段表 | `seg_count × 12B = {tag u32, offset u32, size u32}`，offset 相对文件头 | `ccr_io.cr:586,601-602`；格式文档 §2 |
| 版本闸 | `if ver != CCR_VERSION { return -1; }` | `ccr_io.cr:979` |
| 段号闸 | `if tg < 1 || tg > CCR_SEG_COUNT { return -1; }` | `ccr_io.cr:1006` |
| 段序闸 | loader 按规范序校验（`tg == ri+1` + 段体连续两闸） | 格式文档 §2 注 |

### 9.2 新增 MAP 段的**真实代价**（原文只说"或者更干净地单独增加 MAP 映射 section"）

> ⚠ **本批前置更正（2026-09-20）**：本节原按"**加 MAP 段是既定路线**"写的。现按 **C-3 的下调**——
> **七字段已确认不需要段**（复用 `ENT.flags` 空闲位，另见 C-3 的 `location` 保留项），
> 且**placement 按不变量 ① 本就不该进 `.ccr`**（它是语义 IR 载体）。
> ⇒ **本节读作"若最终仍决定加段，代价是这些"**，**不是"将要加段"**。

**`[提案]` + `[已实现]` 代价面**：

1. **必须 bump `CCR_VERSION` 9 → 10。**
   理由：`CCR_SEG_COUNT` 8→9 使段表从 `96B` 变 `108B`，**其后所有段的 offset 全部平移**，文件布局整体改变。旧阅读器（v9）遇到 v10 会走 `ver != CCR_VERSION → -1` **整类拒收**——这是**既有先例**（`ccr_io.cr:135` 注："v9-only（load 校验 ==9；拒 version≠9——D10 先例：v8 及更早整类拒收，**不得**静默当「段/字段缺席 = 空表」）"）。
2. **`CCR_SEG_COUNT` 必须同步改**（否则段号闸 `tg > CCR_SEG_COUNT → -1` 会拒掉 MAP 段）。
3. **`calc_ccr_size` + 段尺寸函数 + 写侧 + 读侧四处同改**——这是既有"加段四面"纪律（先例：R2 P4 Task 2/3 加 TYPE/IFACE 两段的实施形态，见 `test_ccr_types.py` 结构断言）。
4. **不是"预留槽"**：`reserved u32 = 0` 是**唯一**的 4 字节松弛，**不是段指针**；`9+` 只是**编号空间**（"预留 9+ 不占空间"，`ccr_io.cr:138`），**加段必然改布局**。
5. **两个既有占位主张（端口冲突）** `[已设计未实现]`：`9+` 的既有注明用途 = 「**驱逐标注段** v6.1 延续、**证书段**」（格式文档 §2 注）。~~MAP 段将是**第三个**主张者。~~ ⇒ **本批下调**：MAP 不必加段（见 §9.2 前置注 + C-3）⇒ **MAP 退出该争用**；其余三者之间的争用**本文未核**（C-3 待裁点 (c)）。
   ⚠ **另一条本批实核（与"加段"无关但同等重要）**：**REG 记录亦无空余槽**（`ESZ_SG_DISK = 24` = 6×i32 全满，`ccr_io.cr:157-162`；内存 `ESZ_SG = 48` = 6×u64 全满，`dyn_arr.cr:146-152`）⇒ **若 placement 确需进 `.ccr` 且按 region 承载，扩 REG 与加段代价同量级**（两者都是布局变更 + 版本闸整类拒收）。
6. **测试面**：`tests/selfhost/test_ccr_v7.py`（段结构断言）+ `tests/selfhost/test_ccr_types.py`（段机制 + 内容面 + 版本闸，实测 49/49）须**同批重定**；`--dump-types` / `--dump-ifaces`（`main.cr:687`）是 dump 面的先例。
7. **`.cir` 缓存面** `[已实现]`：`CIR_CACHE_VER : int = 22`（`src/compiler/cir_cache.cr:135`）是与 `CCR_VERSION` **独立**的手工粗粒度版本常量（`cir_cache.cr:170` 注："VER = 手工粗粒度（格式/语义生成代）"）。**若 placement 元数据落进 `.cir` 快照，须独立 bump `CIR_CACHE_VER`。**
   ⚠ 且判据须过 **clean-cache / 暖态**纪律：缓存键 = 源路径::函数名 + 纯 AST 指纹，**不含编译器身份** ⇒ "改了编译器但源指纹不变"会**命中旧快照**。文档面须显式写这条。

### 9.3 三态落地建议（本文补，不裁决）

> **本批更新（2026-09-20）**：原倾向 **A（独立 MAP 段）**。按 C-3 的实核下调，**倾向改为 C**——
> 理由不是省事，而是**不变量 ① 本身**：`.ccr` 是**语义 IR 载体**，而 placement 元数据**按定义不得改变语义 identity**
> ⇒ **把 placement 放进 `.ccr` 是与该不变量相抵的做法**（哪怕判据写得出来，也等于在语义载体里放了非语义物）。
> A 的"判据强度高"仍是事实（见下表），但**它换来的是"能证明没有污染"，而 C 直接"不去污染"**。

| 选项 | 不变量 ① 的判据强度 | 代价 | 本批评价 |
|---|---|---|---|
| A. 独立 MAP 段 | **强**——"摘除 MAP 段后其余段逐字节同"可直接写 | §9.2 全部七项 | ⚠ **与不变量 ① 相抵**（语义载体放非语义物） |
| B. 附着在 REG 记录（原文 §21 首选） | **弱**——REG 记录字段数/尺寸变了，逐字节判据退化为"字段数不变" | ~~免 bump~~ ⇒ **本批更正：不免**（REG 记录 6×i32 全满，改尺寸 = 布局变 ⇒ 同款拒收） | **双重不利** |
| **C. 只进 `.cir` 快照，不进 `.ccr`** | 中——`.cir` 缓存面独立 bump（`CIR_CACHE_VER`） | `corearch` 读不到 placement ⇒ **只支撑 M0–M3**，M4 起不够 | ✅ **本文倾向**（与不变量 ① 同向） |

⇒ **本文现倾向 C**，并配一条**裁决前提**：若 M4 起确需 `corearch` 读 placement，则应**另立一个非语义侧的承载**（部署配置 / mapper 自有表 / 独立 side file），**而不是回落到 A 或 B**。
⇒ 三选项的共同前提：**placement 不是语义**——故任何"把它塞进语义载体"的方案都须先答"为什么非它不可"。

---

## 十、里程碑 M0–M11

> 原文 12 档，逐条保留。**本文补**：每档的"判据形状"与"依赖"，以及**顺序上的两条硬约束**。

⚠ **术语撞名警告**：本表的 **`M2`（IR metadata）与 HIT 的 `M2`（全表驱动）是两个不同的里程碑**，编号空间独立。**凡见裸 `M2` 须先判是哪一族**——HIT 那族一律写全称「**HIT M2**」（本批 C-1 的裁决反转留痕涉及 HIT M2，尤须区分）。

| # | 里程碑 | 内容 | 判据形状（本文补） | 依赖 |
|---|---|---|---|---|
| **M0** | **Specification** | 定义 ExecutionDomain · MemoryDomain · TopologyLink · Residency · AUTO/PREFER/REQUIRE；明确 placement 非语义本体。<br>**〔本批追加〕** 存在格本体（Materialization 七字段 + `Evictable` 改写）归 `materialization-space.md`；本文只承担**放置面** | 本文档 §三/§八 落盘（**本文即 M0 的放置面产物**）<br>**并列产物** = `docs/maintainer/design/materialization-space.md`（本体面） | — |
| **M1** | **Syntax** | `@preferredDomain(name)` · `@executionDomain(name)`；支持 `fn`/`flow`/`loop`/`region`；**parser/checker 只做名字与结构处理** | 正：四类位置各一档，注解被解析进侧表；负：未知域名/非法位置 ⇒ rc=1 + 码 + 零产物（`check` 面）；**结构腿**：注解**不产生任何 IR**（`--dump-*` 前后逐字节同） | M0 |
| **M2** | **IR metadata** | annotation → region mapping metadata；**HDFG byte/semantic identity 不因 placement 改变**；dump 支持显示 domain constraint | **= 不变量 ① 的四条腿**（含"摘除 MAP 段后逐字节同"的限定口径） | M1 |
| **M3** | **Logical domain config** | 部署配置定义 execution domains；domain alias → backend/device；**默认域** | 配置解析单元档：别名解析/未知别名硬错/默认域回退；`Core.toml` 现只有 `name`（`src/compiler/project.cr:56` 全文仅读 name）⇒ **须扩 schema** | M0 |
| **M4** | **Static placement** | AUTO/PREFER/REQUIRE；**先 CPU-domain ↔ CPU-domain；不涉及 GPU** | **= 不变量 ③ 两向钉子 + ⑤**；同后端两域（原文 §25 例）全链路可跑 | M2,M3 |
| **M5** | **Memory topology** | MemoryDomain；Link latency/bandwidth；Entry residency；materialization planner | **= 不变量 ②（含合并负控）+ ④** | M4 |
| **M6** | **Cost model** | compute · dispatch · transfer · sync · preferred penalty；baseline HEFT-like scheduler | S-C §2.3 契约六条：`band` 必填 / 缺失保守退化 / 相对量纲 / **模型非证明** / 与 `PROVED` 不混报 | M5 |
| **M7** | **Variant infrastructure** | HIT baseline variant；多 backend variant；candidate pruning | variant 数上界（Top-K）断言 + **不变量 ①**（variant 不改变语义） | M6 |
| **M8** | **Minimal GPU backend** | for/array/arithmetic 子集；一个 GPU execution domain；CPU↔GPU transfer 自动生成 | 目标子集端到端：`@executionDomain(gpu) flow test { for i in 0..n { out[i] = a[i]*b[i]+c[i]; } }` 值判据；**自动 transfer 存在性**断言（源码零 `copyToGpu`） | M7 |
| **M9** | **Runtime mapper** | runtime N；actual residency；device load；CPU/GPU 动态选择 | 原文 §18 例（`400MB @DDR` ⇒ CPU；数据已在 VRAM ⇒ GPU）作为**行为判据** | M8 |
| **M10** | **Optimization** | region fusion；transfer overlap；asynchronous materialization；residency retention；repeated execution profile | 各优化**可缺席**（S-C L3：缺失可接受）；每项独立正/负档 | M9 |
| **M11** | **Verification** | 每个 variant 与原 HDFG 观测等价；transfer/materialization 保持 Entry identity；execution mapping 不改变 state-edge semantics | **= 不变量 ①④ + S-C §3.2 五条可迁移判据**（观测等价/源码零改动/义务判定不变/决策自由/可移植子集） | M10 |

### 10.1 两条顺序硬约束（原文未显式写，本文补）

1. **CPU↔CPU 假异构必须早于任何真实 GPU**（原文 §25/§26 的顺序明确，本文升格为约束）：
   ```
   ExecutionDomain abstraction → CPU↔CPU fake heterogeneous test → MemoryDomain
     → Topology → Residency → Transfer planner → GPU backend
   ```
   **而不是**先 CUDA 再倒推架构——"否则很容易被 CUDA execution model 污染"。
   ⇒ 结构性理由：原文 §25 的 TOML 用 `backend = "hit"` **两次**，正是"证明 ExecutionDomain 模型本身不依赖 GPU"的最小实验。**这一点非常重要**（原文加粗）。
2. **M2 先于 M4**：不变量 ① 若无承载物（M2），M4 起的任何 placement 都**无法证明**没有污染语义图。

### 10.2 原深度约束（原文"明确不做"）

见 §1.4；M10 之前不得引入其中任何一项。

---

## 十一、冲突登记（**逐条列出 + 我的核实结论；不替维护者裁决**）

> 格式：**原文断言** / **仓库现状（file:line）** / **我的核实结论** / **待裁点**。

### C-1 ⚠ 最重要：HIT = baseline universal execution target ？

- **原文断言**：`HIT = baseline universal execution target`；`HIT backend: canLower(R) -> true`；"没找到更优域 → HIT"；同时又说 "HIT 不需要为了异构计算修改语义"。
- **仓库现状**（本会话实核）：
  - **HIT = Hardware Interface Table**（"硬件接口表"），是一个**表驱动编码机制**，不是执行域：
    - `src/arch/hit/hit.cr:2`：「硬件接口表（HIT）：**core-x86.toml → 内存表 加载器**」；`:8-10`：「表 = corearch 运行的**唯一平台依赖**：`load_hit_table` 把 toml 表文件读成 事件/投影/步 三块紧凑 buffer 表 + 运行时条目，**表驱动编码器直读**」
    - `src/arch/hit/lower_to_core.cr:2-3`：「合成层…**IR 直线子集 → 4 核事件流 + 常量池**」；`:21`：「未映射指令（RET/ALLOC/ARENA_*/…）→ 无事件 → **旧路径（M1 混合模式）**」
  - **HIT spec 的定位**是"接口"不是"域"：`2026-09-05-hardware-interface-table.md:11`「**替换表 = 换目标平台/范式**：同一 Core 程序配不同表直接运行」；`:26`「命名：**接口**表而非映射表——接口 = 语义契约（签名），实现 = 范式投影」
  - **HIT 自身声明它可以在非经典范式上投影**：HIT spec §3.2「投影不一定是"编码成字节"——投影 = 事件 → 范式资源的实例化；经典行恰好是 ISA 编码」（含"通道类范式/连续量子类/无实现"）
  - **HIT 的"通用性"是**"程序只用最小核事件 ⇒ 任意表可跑"（HIT spec §4「**可移植子集**」），**不是**"任意 region 都能下降"。程序用扩展事件时：「该表须含对应投影（**查表缺失 = 编译期拒绝**，或编译器降级合成）」（HIT spec §4）
  - **构建归属**：`hit_engine_files`（`build_selfhost_native.py:49-51`）**只进 corearch**（`:388` `corearch_files = common_files + hit_engine_files + kernel_files + …`），**corec 不需要**（`hit.cr:21` 注）
- **⚠⚠ 裁决反转留痕（2026-09-20，两轮；**本节是本批最有价值的一处记录**）**

  **第一轮（口述）**：维护者经 team-lead 转达「**HIT M2 早已淘汰**」（**本文未见原话，来源 = 经 lead 转达**）。
  依据该口述，本节曾把结论改成"M2 不是未完成而是不做；硬编码旧路径是**永久设计**"，并**删去**待裁项 (c)、改判「通用下降路径 = 设计空缺」。

  **第二轮（书面校正）**：本文按纪律去**实核书面留痕**（**不把口述写成已证事实**）⇒ 找到**四处反向记载**：

  | 位置 | 原文 | 与口述的关系 |
  |---|---|---|
  | `TODO.md:2211` | 节标题「HIT 最小核（2026-09-06 M1 完成 → **M2 挂账**）」 | **相反**（仍记挂账） |
  | `TODO.md:2215` | 「**M2 挂账**：」+ 五条 bullet（含「**全量切换：无 `--table` 旧路径退役**（emit 循环门控翻转）」） | **相反**（且该条正是"旧路径退役"的计划） |
  | `docs/superpowers/plans/2026-09-07-hit-m2.md:3` | 「> **状态：待执行**（2026-09-07 计划定稿）」 | **相反** |
  | `docs/superpowers/specs/2026-09-07-hit-m2-design.md` | 全篇 M2 设计（含 M2a–d 分段） | **相反** |

  ⇒ **维护者据这四处改裁：「以书面为准」。** 本节**据此回退**（逐条见下）。

  **⚠ 四处记载自本批起 = 真源，不是待收口对象**（原"待裁：如何收口"一栏**作废**）。
  **⚠ 本文的处理纪律（经维护者确认"做法是对的"，须保留）**：① **只登记，不改那四个文件**；② 凡口述一律写明「**未见原话，来源 = 经 lead 转达**」；③ **去实核留痕**，不把口述当已证事实。

- **我的核实结论（**已按"以书面为准"回退到进度化口径**）**：
  1. **"HIT 不需要为了异构计算修改语义" —— 成立**（`[已实现]` 级）：HIT 位于发射层、在 placement 下游；HIT spec §7「优化不进表（判定/分配 = 格形态层）」已是既有条款。本设计**不需要改 HIT**。
  2. **"HIT = baseline universal execution target" —— 不成立（**作为"今天的事实**）**。理由是**范畴错位**：原文把 HIT 当作**一个域**（`backend = "hit"` 的 ExecutionDomain），仓库里 HIT 是**机制**（"替换表 = 换目标平台"）。**一个机制不能同时是它自己的一张表。**
     ⚠ **本论点（机制 ≠ 域）作为独立论点保留**，但**不得**用来支撑"永久"——它说明的是**范畴**问题，不是**进度**问题（见结论 3）。
  3. **"canLower(R) -> true" —— 今天为假，但这是进度性的（M2 挂账未做）**：表模式覆盖**直线子集**（`const/store/load/add/sub` + 4 核事件），其余指令形状今天走硬编码 `e2_*` 路径。
     ⇒ **该硬编码路径是「临时缺口」，不是「永久设计」**——`TODO.md:2215` 明列「全量切换：无 `--table` 旧路径退役」，**M2 收口后即消除**。
  4. **前提失效的登记随之撤回**：HIT spec §1「硬件接口表 = 运行的**唯一**平台依赖」「替换表 = 换目标平台/范式」**并未失效**——它是**待 M2 达成的目标**；S-C §0.3「HIT M2 复启…实现归属不变（HIT 线）」**同样有效**。（第一轮据口述写的"不成立/须重定"**已作废**。）
  5. **原文方向的前件**：S-C §0.0「单 CPU 上的 SIMD/cache/NUMA/… 与异构 placement 是**同一个问题**…机制同一，**无第二条性能路线**」成立；S-C §3.1 把"目标描述"写成「表：语义表 + 投影条目 + 运行时条目 + 设备/投影表（hw-map）+ 成本事实」成立。

- **「通用下降路径」的归属（**第一轮的"设计空缺"判定已撤回**）**：
  - **HIT 仍是该位置的既定承担者**——只是**要等 M2 收口才成立**。这正是待裁项 (c) 的内容（第一轮删错了，本批恢复）。
  - 第一轮据口述写的"今天没有一个被明确命名的通用执行目标 / 本文判定为设计空缺"**撤回**；`instr.cr` 硬编码发射器是**待退役的临时过渡路径**，不是"未被命名的空缺"。
  - ⇒ **§八 不变量 ⑦**（"未指定 ⇒ 恒存在合法映射"）**恢复为"依赖 C-1 待裁点 (b)/(c) 的落定"**，**不再标注"不可判定"**。

- **待裁点**：
  - (a) 原文的 `backend = "hit"` 是否**应改述**为「`backend = "classic"`（其编码由 HIT 表 + 未收口的旧路径共同实现）」？还是保留 `"hit"` 但**在文档里显式声明**"此处 hit = 表机制所在的默认域"（即接受一次术语重载）？
  - (b) **通用下降路径的身份**：是 HIT 表模式（**须先完成 M2**），还是今天的硬编码路径（**已可用但不在表内**）？这直接决定 §八 不变量 ⑦ 的"通用域"是什么。
  - **(c) 【本批恢复】若采 (b) 的前者，则 M4 前置应增加「HIT M2 收口」——原文里程碑无此项。**
    ⚠ **留痕**：该项曾于本批第一轮按维护者口述「M2 已淘汰」被删去；**经四处书面记载校正后恢复**（维护者改裁「以书面为准」）。**不是新增项，是恢复项。**

- **⚠ 本节作为方法论实例（本批新增，勿淡化为一次普通修订）**——**「口述 vs 书面记载冲突 ⇒ 以书面为准」**的一个**完整实例**：

  ```
  ① 收到口述裁决（"M2 早已淘汰"）
  ② 未把口述写成已证事实：写明"未见原话、来源 = 经 lead 转达"
  ③ 按纪律去实核书面留痕 ⇒ 找到四处反向记载
  ④ 维护者据书面改裁 ⇒ 本节整轮回退，且回退本身留痕
  ```

  **要点（下游可复用）**：
  - **口述与书面冲突时，书面优先**；**实核留痕是可操作的一步**，不是形式主义——本批正是它把结论翻了过来。
  - **回退要留痕、不要静默改回**：删掉的待裁项写出"曾删、因何恢复"；作废的结论标"已作废"而不是抹掉。
  - **诚实口径是承重件**：若第 ② 步把口述写成事实，第 ③ 步的实核就失去触发理由（**"已证"的前提会让反证显得像噪音**）。
  - ⇒ **本文档全程适用**：凡 team-lead 转达的维护者裁决，一律写「**未见原话，来源 = 经 lead 转达**」（维护者已确认此口径）。

### C-2 cache-semantics 条款 4b vs 原文的副本有效性模型

- **原文断言**（§28）：`X2: DDR valid / VRAM stale`——即所有条目按"哪份新鲜"管理；materialization 的 `valid` 位统一处理。
- **仓库现状**：`docs/academic/cache-semantics.md:28`（条款 4b，v4 并入，M4 输入）：「**图内不可重算**…存在**图内**无配方条目——非边界、不可重算。**驱逐不变量/再生等价对其不成立**（重跑神谕 ≠ 原结果）：其存储**必须持久**（home 保有材料），**驱逐必须写回**；身份 = 产生节点」；`:50-59` 细读给两类：**边界**（MMIO/FFI/输入/测量，语法层 `unsafe`）/ **图内不可重算**（神谕/BSS 实数/FIXPT 声明/模糊融合），并明言「**不按范式枚举**——新增范式时无配方规则不变」。
- **我的核实结论**：
  1. 两者**不是矛盾**，但原文的**统一 `valid` 位模型不覆盖**无配方条目——对它们"VRAM 那份可由 DDR 再生"是**错的**（条款 3 不成立），且存在**权威副本（home）**概念，原文模型里**没有这一位**。
  2. **仓库侧是更强的要求**：条款 4b 对无配方条目给的是**义务**（必须有 home、驱逐必写回），而原文把 residency 整体当**优化**。⇒ 若不区分，实施批会把"必写回"实现成"可丢"= **静默语义破坏**。
  3. `home` 字段**已在 `.ccr` ENT 盘面上**（`ccr_io.cr:173-176`）⇒ 承载面已存在，缺的是模型侧的**分档规则**。
- **⚠ 本批状态变更（materialization-space 输入后）**：本条**由"待裁"改为"已被新框架涵盖"**。
  理由：新输入的 `Evictable(x) ⟺ Recoverable(x) ∨ PreserveRequiredState(x)`（§6.4）**第二支**正是条款 4b 的位置——条款 4b 不再是"例外条款"，而是第二支的**正例**。
  且新框架用 **`authority`** 取代 `valid`（§3.5），"权威副本"这个概念**已在七字段里有位**（§3.4.5 第 4 行）。
  ⇒ 本文已按此**重写** §3.5（删 `valid`）、§6.4（`Evictable` 新式）、§6.5（方向反转）、§八④（按字段分档 + 新增 `authority`/`replicability` 判据）、§八⑧（新不变量）。
- **剩余待裁点（**只剩一条**，不裁决）**：**条款 4b 自身的措辞是否要改**——它现在写在 `cache-semantics.md`（被定位为"缓存映射实例的规律"）里，而它讲的其实是**存在格的一般规则**（any `recipe = no`）。⇒ 是"条款 4b 应**上移**到 `materialization-space.md`"，还是"保留在原处、由存在格文档引用它"？**本批不裁决，也不改那份文件**（C-11）。

### C-3 `.ccr` 段位主张冲突：MAP 段 vs 驱逐标注段 vs 证书段

- **原文断言**（§21）："或者更干净地单独增加 MAP 映射 section"。
- **仓库现状** `[已设计未实现]`：`docs/superpowers/specs/2026-09-09-lattice-ir-v7-format.md:50` 注：「`9+` 预留顺移：**驱逐标注段 v6.1 延续、证书段**」——即 tag 9+ 已有**两个**具名主张者。S-C §3.1 又主张 `.ccr` 新段承载**成本事实**（"载体 = `.ccr` 新段，随 R2 P4 同波"，引同一处 `7+` 未固定分配）。
- **我的核实结论（本批下调 —— 见下"实核与下调"）**：~~**MAP 段将是 tag 9+ 的第三个主张者**…⇒ **多次加段 = 多次全局格式破坏**。~~
- **⚠ 实核与下调（2026-09-20）**：另一名写手核出 **`.ccr` 不需要加段、不需要 bump `CCR_VERSION`**——**七字段复用 `ENT.flags` 空闲位 + 现有 4B 槽**。**本文独立复核（部分证实、部分须留待）**：

  | 主张 | 本文复核 | 依据 |
  |---|---|---|
  | 七字段**复用 `ENT.flags` 空闲位** | ✅ **证实（位数足够）** | `ENT.flags` 是 **u32**，bit0–3 已定（无配方/参数/全局/驱逐候选）⇒ **bit4–31 空余 28 位**；`recipe`/`persistence`/`replicability`/`authority` 都是**小枚举**（`existence-structure.md:45`） |
  | 且**值域现为空**（可自由启用） | ✅ **证实** | `flags 恒 0`、**零实例**（`ccr_io.cr:85`；§3.4.5 / C-13） |
  | 七字段**复用"现有 4B 槽"** | ⚠ **未证实 —— 本文未找到任何空余 4B** | ENT **内存态** = `ESZ_ENTRY 24` = 6×4B，六槽**全命名**（`var/def/ls/le/home/flags`，`dyn_arr.cr:137-143`）；**盘面** = `ESZ_ENTRY_DISK 28` = 7×4B，七槽**全命名**（`ccr_io.cr:173-176`），其中 `version` 是**由组序导出的**（`ccr_io.cr:175`「derivable from group order」），已被占用 ⇒ **无空槽可复用** |
  | ~~**MAP（region 放置）也无需新段**~~ | ⚠ **未证实/不成立** | MAP 是 **region 侧**（regionId/mode/域名），归 **REG 段**；**REG 盘面记录 `ESZ_SG_DISK = 24` = 6 × i32 六字段全满**（`{kind, parent, enter_nod, exit_nod, first_ent, last_ent}`，`ccr_io.cr:157-162`），**未见空余槽**；内存态 `ESZ_SG = 48` = 6 × u64 亦满（`dyn_arr.cr:146-152`） |

  **⚠ 由本表得出的一个附加约束（本文补，其他写手未提）**——**位打包路线可行的前提是"字段值域有界"**：
  - `recipe` / `persistence` / `replicability` / `authority` **有界**（小枚举）⇒ 位打包**无问题**。
  - **`location`（"当前在哪里存在" = 内存域索引）是唯一的例外**：它需要一个**域编号**，位打包只能容纳 `⌈log₂ D⌉` 位 ⇒ **给内存域数量设了一个硬上限**（如 4 位 = 16 个域）。
  - ⇒ **这正是仓库一直在退役的 `MAX_*` 模式**（先例：容量批 E-3 三 `MAX_*` 退役、`MAX_FN_PARAMS` 越界写修复）。**"不加段"与"不设上限"在本字段上不可兼得**，须二选一（或 `location` 走侧表/独立承载）。
  ⇒ **本文结论：位打包路线在五字段上成立、在 `location` 上有代价**——"完全不需要新增承载"的说法**在本字段上未获证实**。

  ⇒ **下调范围（本文口径）**：**"段位资源争用"在材料化七字段面消失**（那部分确不需要段）；**MAP 自身**是否入 `.ccr`、以何承载，**仍待定**——但**优先解不是"加段"**：
  - **更贴合的解法（本文建议，不裁决）**：由 **不变量 ①**（placement metadata 不得改变 HDFG 语义 identity）反推——**placement 本就不该进 `.ccr`**（`.ccr` 是语义 IR 载体）。⇒ placement 归**部署配置 + mapper 自有表**，编译期面可放 `.cir` 快照（§9.3 选项 C）。
  - 若采此解，**C-3 的"段位争用"整体消解**（连 MAP 也不加段）⇒ tag 9+ 的两个具名主张者（驱逐标注段 / 证书段）与 S-C 的成本事实段**不产生争用**。
- **待裁点**：
  - (a) ~~MAP 段与成本事实段是否合并~~ → **改问**：placement **是否根本不应进 `.ccr`**（本文倾向"不应"，理由 = 不变量 ①）？
  - (b) 若 placement 确需进 `.ccr`，则 REG 记录**无空余槽** ⇒ 须改 REG 记录尺寸（**仍是一次格式变更**）——此时"加段"与"扩 REG"**代价同量级**，比较基准须重算。
  - (c) tag 9+ 的两个既有主张者（驱逐标注段 / 证书段）与 S-C 成本事实段之间**是否仍有争用**——**本批只下调了 MAP 这一项**，其余三者的关系**本文未核**。

### C-4 原文 §2 的 `flow` 块语法 vs 仓库的 P021 硬拒

- **原文断言**（§1/§2，主例）：`fn pipeline(...) { ... @executionDomain(gpu) flow compute { ... } ... }`——**函数体内**的 `flow` 块。
- **仓库现状** `[已实现]`：
  - `parser.cr:1002-1010`：语句位遇 `T_FN`/`T_FLOW`（含 `pub` 形态）⇒ `check_error(EC_P_NESTED_FN, "Nested function declaration … is not supported; declare it at top level")`（P021，`ast.cr:351`）。
  - `parser.cr:995-996` 注：「嵌套 `fn`/`flow` 声明**不属语言面**——`grammar/core.ebnf` 的 `Statement` **不含** `FunctionDecl`（函数声明仅顶层 `TopLevelDecl`），bootstrap 参考实现亦以 positioned error 拒绝。」
  - 现有 `flow` 形态 = **顶层** `flow fn name(...) { }`（`parser.cr:1726-1749`；EBNF `grammar/core.ebnf:22`）。
- **我的核实结论**：原文主例在今天**是一条语法错**。M1 的"flow 块"是**语法面新增**（不只是注解新增）：须同批改 `parser.cr` 语句分支 + `grammar/core.ebnf` 的 Statement + 负例档（P021 的既有负控 `tests/selfhost/test_nested_fn.py` 仍在 `src/ci/run.sh` 挂钩，`run.sh:47`）——**且须注意：放开 `flow` 块会削弱 P021 的既有语义（`flow` 不再是"嵌套声明"）**，两处必须同批重定才不会一边放开一边误报。
- **待裁点**：`flow` 块的**合法性边界**——`@ann flow x { }` 与既有 `flow fn` 是否共用 `SG_FLOW`（`dyn_arr.cr:157`）？`flow` 块是否有名字（`flow compute {`）还是匿名？名字进哪个命名空间？

### C-5 原文的 `Region` / 仓库的 `Region`（术语）

- **原文断言**："来源：HDFG region · `flow` · `loop` · `function`"（§7）——把 region 当执行放置单位。
- **仓库现状** `[已实现]`：`docs/maintainer/design/region-model.md:3`：「Core 采用**图锚定区域**的统一内存管理：区域(Region)锚定在 HDFG 上——**区域是子图节点的字节域**，不是词法作用域的影子」；`§3.1` 表逐子图类型给**内存**策略（DAG→栈式区域 / 静态循环→固定区域 / **Flow→独立区域** / Go→独立区域 / Yield-Recv→消息区域）。
- **我的核实结论**：**同名不同义**，且**两者共用同一个物理载体候选**（`g_sgs` / `SG_*`）——**这是实施批最容易踩的坑**：把"ExecutionRegion 加槽"加到 `ESZ_SG`（48B，`dyn_arr.cr:146`）上，会同时改变**内存区域**的语义载体。本文 §〇.1 已立术语护栏（一律写 `ExecutionRegion`）；**建议实施批也一律用 `ExecutionDomain`/`ExecutionRegion` 前缀命名，不要复用 `sg_*`/`REG`**（`REG` 已被 `.ccr` 第 5 段占用）。
- **待裁点**：`ExecutionRegion` 与 `g_sgs` 的 region 是**一对一**（直接复用下标）、**一对多**（fusion 后合并）、还是**独立表 + 映射**？原文的 `region fusion / region split` 暗示**不是**一对一。

### C-6 档案「无格承诺」对 Capability Lattice 的约束

- **原文断言**：Capability Model 应做成**格**（`Req(R) ⪯ Cap(D)`，闭包，偏序）。
- **仓库现状** `[已设计未实现]`（archive，v4 **定稿**）：`docs/archive/memory-model-capability-lattice.md:11`「**② 无格承诺**：格（Lattice 代数）**不进入语义本体**，是**映射实例的组织参数**，判定/定理只在关系层面陈述（最弱理论，函子式构造防枚举）」；`:14`「任何具体格 = 签名 + 恒等式 = 封顶…语义写在比格更弱的理论里」；`:15`（v4 §零.3）「**语义保鲜线不需要「能力」独立概念**…**不提升且可逆**——零成本 YAGNI，选项永远保留」。
- **我的核实结论**：**两者相容，但有一个硬边界**——原文的能力格位于 **mapper/backend 内部**（"复杂性都藏在 mapper/backend 里面"，用户侧三态），这与档案"格 = 映射实例的组织参数"**同指**。⇒ **能力格可以存在，但不得进入语义本体**（不得成为语言原语、不得进入条款集、不得让 `Req`/`Cap` 出现在图或源码里）。
  ⚠ 与 S-C **L6 裁决** 亦一致：`[已设计未实现]`「**标注 = 开放标注/事实来源，不是新 primitive**：不新建属性轴、不新增语言关键字」。⇒ **能力格不得渗出为源码级 capability tag**——原文 §30「用户级 capability tag 大全」已在"不做"清单，**档案给出了它"不做"的第二条理由**。
- **待裁点（**本文建议但不裁决**）**：本文 §五/§八③ 的 `Req ⊑ Cap` 陈述**已按"关系层面"写**（不写格公理、不写恒等式），与档案"最弱理论"一致——**是否要求实施批也遵守"只陈述关系、不引入格代数"**？若是，§3.7 的 `parents[]`/`constraints[]` 应明确为**实现内部组织**，不得文档化为语义公理。

### C-7 逻辑域名 vs "源码零机器名词"

- **原文断言**：`@executionDomain(gpu)` / `@preferredDomain(gpu)`；例子用 `cpu` / `gpu` / `bigCpu` / `littleCpu`。
- **仓库现状** `[已设计未实现]`：S-C **L1**「**机器形状不进程序意义**：源码/图零机器名词（无宽度、无寄存器、无 SIMD 宽度、**无设备名**）」+ §3.2 反向泄漏检测「`c) 源/图中出现机器名词` ⇒ 违反，登记为「泄漏待归一」」；一致性佐证 `[已实现]` 文档面 `docs/z-vision.md:41`「范式无关的语义层是尚未被占据的位置（现有语言都绑定经典执行模型）」。
- **我的核实结论**：原文 §4 的**机制**（域名是逻辑名、来自部署配置、换机器不改源码）**完全符合** L1；但原文给的**示例字面量**（`gpu`/`cpu`/`bigCpu`）**全是机器名词**。⇒ 这是**表述与自身机制的摩擦**，不是设计矛盾：`fast` 一例即合规形态。
- **待裁点（不裁决）**：是否**要求** v1 文档/示例一律改用非机器名词（`fast`/`slow`/`big`/`little`）？还是接受"逻辑名允许与机器同形"（那 L1 的"设备名"需重述为"**硬编码的**设备名"）？**这条会影响全仓文档与所有示例，应尽早裁。**

### C-8 原文两处的结构清单不一致

- **原文断言**：（"四对象"节）`RegionRequirement { operations, control, addressing, synchronization, effects, guarantees }`（6 项）；（"能力维度"节）`ExecutionCapability` 十项（Computation/Control/Parallelism/Storage/Addressing/Synchronization/Communication/Effects/Dynamism/Guarantees）。
- **我的核实结论**：两处**同一对象的两份清单**，6 项版缺 `Parallelism`/`Storage`/`Communication`/`Dynamism` 四项——而分量最重的一条判例（NPU 的 `Storage: private, domainShared` + `Addressing: indexed` 但不支持 `indirect`/`pointerLike`）**恰好依赖 `Storage`**。⇒ 6 项版是**不完整的中间稿**。
- **本文的处置**：§3.6 采**十项**（与能力维度一一对应）。**不替维护者裁决**——若维护者要求 6 项是 v1 收敛范围，§3.6/§四 须同步收窄，且须评估"NPU 判例是否仍可表达"。

### C-9 部署配置面：仓库只有 `name`，而 §五/§19/§20 假设一整棵配置树

- **原文断言**：`[executionDomain.cpu] backend = "hit" device = "cpu0"`；`[execution] mapping = "static"` / `objective = "performance"`。
- **仓库现状** `[已实现]`：`src/compiler/project.cr`（**全文 56 行**）只做 `read_file(dir + "/Core.toml")` → `extract_toml_name(tc)`；两个 `Core.toml` 在仓（`src/compiler/Core.toml`、`src/targets/x86_64-linux/Core.toml`）**各只有一行 `name = "…"`**。**无 `[execution]`、无 `[executionDomain.*]`**（全仓 grep 零命中）。
  **原则面已有前件** `[已设计未实现]`：`docs/maintainer/design/execution-model.md:180-183`（§5.1）「Core 代码只描述计算逻辑与数据结构，不规定内存从哪来…物理约束在**部署配置**中声明（TOML，如 `allocation = "static"/"dynamic"`），编译器据此检查兼容性并生成适配代码」；`:199-201`（§5.3）资源配额同理；`:203`（§六）「代码与部署分离…同一份代码…代码不改。图语义唯一。**部署配置不同。**」
- **我的核实结论**：原文的配置面**与 §5.1/§六 的既有设计意图同向**，但**基础设施为零**（56 行 + 单键）。⇒ M3 的规模被原文低估：需要**完整的 TOML 段/嵌套表解析**，而不是"读一个键"。
- **未核实（重要）**：`src/stdlib/toml.cr`（274 行）的**现有能力边界**——本会话只核到其导出函数为 `toml_get_str` / `toml_get_int` / `toml_get_int_list` / `toml_read_memlayout` + 私有 `_skip_whitespace` / `_is_at_line_start` / `_next_line_start` / `_toml_hex_digit` / `extract_toml_name`。
  ⇒ **是否支持 `[section]` 嵌套表 / `[[array-of-tables]]` / 点号键——本会话未核实**（记入 §十二）。若只支持平键，M3 须先扩 TOML 解析器（**或改用 hw-map 线的现成表机制**，见 C-1 结论 4）。

### C-10 部署策略 objective 与 S-C 裁决的边界

- **原文断言**（§20）：`[execution] objective = "performance"`，以后可 performance/latency/energy/balanced；"不要把这些变成源代码 annotation"。
- **仓库现状** `[已设计未实现]`：S-C **L5**「成本模型 = **数据 + 可替换组件**：成本事实随表走；成本模型（加权/阈值/搜索）是编译器侧可替换件——**不进图语义，也不进表的「放置策略」面**」（依据 = HIT spec §3.3「优化不走表」）；S-C §1 表把"资源约束"列为 `policy 数据`。
- **我的核实结论**：原文"部署策略不进源码"与 L5/§1 **同向**。但**边界待钉**：`objective` 属于**部署配置**（原文）→ 而 L5 说"放置策略不进**表**"——**部署配置 ≠ 表**吗？在仓库的术语里 `Core.toml` 是**部署配置**、HIT 表文件是**表**，二者是不同物 `[已实现]`（前者 `project.cr` 读，后者 `--table` 传入，`hit.cr:4`）。⇒ **不冲突**，但文档须显式写"部署配置与目标描述表是两处，L5 只约束后者"。
- **待裁点**：`objective` 是否应落**部署配置**（原文）还是**目标描述表**（S-C §3.1 的"目标描述"三轴 + 表）？若落表，则与 L5"策略不进表"直接冲突，须先裁 L5 的适用范围。

### C-11 ⚠ 「格 = 缓存」教义的既有落点（**逐条列出，一律不改**）

- **新输入断言**（`materialization-space-raw.md`）：把「格 = 缓存」当**本体定义**「可能太窄」；正确的层关系是 `格层 = Materialization / Existence Space`，**缓存只是其中一类映射实例**；「"缓存"这个词都可以降级，不再作为整个层的总名字」。
- **仓库现状（既有「定稿」措辞，本会话逐条实核行号）**：

| # | 位置 | 原句（节录） | 与输入的冲突点 |
|---|---|---|---|
| 1 | `docs/academic/cache-semantics.md:4` | 「本文件是 Core 存储语义**本体**的**唯一权威**」 | 把缓存条款**升为本体**；新输入要把本体归 Materialization Space |
| 2 | `docs/project-book.md:216` | 「存储语义**本体**为**缓存语义**（值 = 配方、条目可驱逐可再生、图边界为唯一不可再生来源）；字节内存是其在经典硬件上的**映射实例**」 | ① 本体 = 缓存（要改）；② **但"字节内存 = 映射实例"这半句方向正确**，是新旧框架**共有的** |
| 3 | `docs/project-book.md:109` | 「图也是存储语义的载体——值即条目（配方可重算），**存储即缓存（范式无关）**，内存只是经典映射」；同段「**格负责承载计算**（内存模型 = 中间存在空间）」 | 「存储即缓存（**范式无关**）」是**最强的冲突句**——新输入恰恰指出缓存**是**范式相关的（那六个假设在别的范式不成立）；同段的「中间存在空间」**反而**与新层名同向 |
| 4 | `docs/z-vision.md:15` | 「范式映射表——**存储半边已定稿**（语义本体 = 缓存语义，字节内存 = 经典映射实例）」 | 「已定稿」= 本批要修订的对象本身 |
| 5 | `docs/maintainer/design/memory-model.md`（标题 + §一分工表） | 「存储语义总览:**缓存** → 存在结构 → 经典映射」；「条款权威 = cache-semantics.md」 | 层名以「缓存」起头；分工表把 cache-semantics 列为「条款权威」 |
| 6 | `docs/maintainer/design/existence-structure.md`（标题 + §三表头） | 「存在结构:v6 **格形态** IR 的语义承载」；「ENT 记录字段与**缓存条款**的对应」 | ⚠ **标题里已经是「存在结构」**——与新层名**同向**；但字段表以「缓存条款」为列标题（要改列名，不改字段） |
| 7 | `docs/maintainer/design/region-model.md:3-5` | 「本文件 = 缓存语义（权威 = docs/academic/cache-semantics.md）在经典字节硬件上的**映射实例**详细设计」 | ✅ **方向已经正确**（"映射实例"）——**唯一无需修订的一处**，可作为其余各处的改写范本 |

- **我的核实结论**：`[已设计未实现]`。冲突**不是全仓一致性的问题**——**7 处里至少 2 处（#2 后半、#7）方向已对，且 #6 标题已用「存在结构」**。⇒ 修订面比输入预估的**窄**：核心是 **#1/#2/#3/#4/#5 的"本体"一词**与**层名**，而不是整套语义。
- **待裁点（不裁决，且本批一律不改这些文件）**：
  - (a) `cache-semantics.md` 的**文件名**是否改（它是 7 条的**条款权威**不变，但标题「缓存语义:存储语义**本体**」要改）？
  - (b) `memory-model.md` 标题的「**缓存** → 存在结构 → 经典映射」是否改为「**存在格** → 存在结构 → 缓存映射」？
  - (c) `existence-structure.md` §三表头「与**缓存条款**的对应」是否改为「与**存在格规则**的对应」（字段与取值**不动**）？
  - (d) 三步修订的**顺序与同批性**——既有纪律「修了前置能力的批次必须同批清点把该缺口当现状写的陈述」，故 (a)–(c) 宜**一批同改**。
- **✅ 已裁（2026-09-20，维护者经 team-lead 转达）**：
  1. **上述 7 处正由另一名写手就地修订**（维护者裁定「**同批就地改**」）⇒ (a)–(d) 四项**从本文的待裁清单移除**，改由那份就地修订负责。
     ⚠ 本文**未见过维护者原话**（经 team-lead 转达），故上表 (a)–(c) 的**具体改法**仍以就地修订者的裁定为准；**本批仍一律未动这些文件**。
  2. **本文的职责边界（维护者明确）**：**引用它，不要重复定义**。⇒ 本文 §六/§八 凡涉及存在格本体的陈述**一律以 `materialization-space.md` 为准**；本文只承担**放置面**（§〇.2 层归属）。两侧命名若不一致，**以那份为准**（未核实项 15）。

### C-12 三层映射链的**层名**（不是层定义）

- **新输入断言**：`图 → 存在格 / Materialization Space → 编码`；`缓存语义 = 经典可再生值的一种映射规律`。
- **仓库现状**（两处现行层名，措辞几乎相同）：
  - `docs/project-book.md:109`：「三层映射（2026-08-27 正式晋升）：语义 → 图 → 格 → 编码——图负责表达计算（关系空间），**格负责承载计算（内存模型 = 中间存在空间）**，编码负责实现计算（物理编码空间）」
  - `docs/z-vision.md:15`：「范式 → 图 → 格 → 编码——图 = 关系空间…**格 = 状态/存储空间（内存模型 = 中间存在空间）**…编码 = 物理编码空间」
- **我的核实结论**：⚠ **层名早已是「格」，不是「缓存」**——两处都写「图 → **格** → 编码」，且都注明「**中间存在空间**」「**状态/存储空间**」。
  ⇒ **新输入要的层名（"存在格 / Materialization Space"）与既有层名（"格 / 存在空间"）几乎重合**，差别只在**具体化**：既有写"格"，新输入写"**存在格**"并给英名。**这是术语具体化，不是层结构变更。**
  ⇒ 真正变更的是**层内本体**（C-11 的"缓存 → Materialization"），**不是层的数量或位置**（四段链 `语义→图→格→编码` 不动）。
- **待裁点**：层名是否统一为「**存在格**」（中文正式名）+ `Materialization Space`（英文）；`格` 作为简称保留。
- **✅ 已裁（2026-09-20，维护者经 team-lead 转达）**：**`格` 保留作简称**。理由（与原话一致）：既有链名本来就是「图 → **格** → 编码」且注明「中间存在空间」，维护者原话也是「**格层** = Materialization / Existence Space」⇒ **这是术语具体化，不是层结构变更**，四段链不动。
  ⇒ **本文的落地口径**：正式名用「**存在格**」（首次出现处附英名 `Materialization Space`），简称用「**格**」，**与既有文档的「格」字不冲突、无需全仓替换**。C-12 判断（层名几乎重合）经维护者确认成立。

### C-13 `ENT flags` 位语义（设计文档）vs 恒零值（实现）

- **设计文档断言**：`existence-structure.md:45`「`flags` | **bit0 无配方 / bit1 参数 / bit2 全局 / bit3 驱逐候选(v6.1)** | 条款 4b / 条款 2」；`:59`「ENT flags bit0 = 无配方(图内不可重算)——**必须有 home**」。
- **仓库现状**（本会话逐行实核）：
  - **槽位**：`OFF_ENTRY_FLAGS : int = 20;   // 位 0 **预留**：无配方（条款 4b）`（`dyn_arr.cr:143`）
  - **值（内存态）**：`flags(20) u32 = **0**（位 0 预留：无配方，条款 4b）`（`globals.cr:232`）
  - **值（盘面）**：`flags **恒 0**（无配方/参数/全局/驱逐位**零实例**——位语义保留）`（`ccr_io.cr:85`）
  - **写点穷举**：`OFF_ENTRY_FLAGS` 全仓仅三处——`dyn_arr.cr:143`（常量）、`ccr_io.cr:473`（读）、`ccr_io.cr:1447`（loader 回写**从盘面读到的** `efl`，即往返，**非新决策**）。⇒ **无任何一处写入非零值。**
- **我的核实结论**：⚠ **设计文档的措辞与实现有可观测落差**：文档写「bit0 = 无配方」（**陈述式**，读起来像已生效），实现是「位 0 **预留**」（`dyn_arr.cr:143` 原文用词）+「**零实例**、位语义保留」（`ccr_io.cr:85`）。
  ⇒ **`recipe` 的正确三态 = `[已设计未实现]`（预留槽位 + 恒零值），不是 `[已实现]`**。
  ⇒ 这不是缺陷——**是"写侧不做决策回填"的有意设计**（同注：`home 恒 -1`，理由「分配决策不写回格式」）。
- **待裁点**：
  - (a) `existence-structure.md:45/59` 是否应把「bit0 = 无配方」改述为「**bit0 预留**（位语义已定，零实例）」以对齐实现？（**本批不改**）
  - (b) `recipe` 要变成**活位**时，是否确认**不需改布局**（位已预留）——只需**一个写点 + 一个消费点**？（本文 §3.4.5 结论 1 倾向"是"，但**未核**写点的插入位置，见 §十二）

---

## 十二、未核实清单（**宁可交白卷也不猜**）

以下锚点本会话**未能核实**，交付批须补：

1. **`src/stdlib/toml.cr` 的嵌套/数组表/点号键能力**（C-9）——只核到导出函数名，未核语法覆盖面。**这是 M3 规模判断的关键未知。**
2. **HIT 表模式的逐 op 覆盖清单**：本会话核到「直线子集 = const/store/load/add/sub」（`lower_to_core.cr` 头注）+「未映射指令 → 旧路径」，**未逐条核** IR 的 38 op 中哪些走表/哪些走旧路径。
   ⚠ **本批留痕**：本句一度被改为「这**不再是"完成百分比"问题**（M2 已淘汰 ⇒ 覆盖率不会再变）」；**经四处书面记载校正后已回退**——该清单**仍是完成百分比问题**（HIT M2 挂账未做，`TODO.md:2215`），其**近期用途** = 划定表模式**当前**覆盖边界（供 §5.10 variant 与 §5.11 backend 接口使用），**不是"永久边界"**。
3. **`core-x86.toml` 的完整 schema**——本会话读的是 `hit.cr` 的**内存表布局注释**（事件 40B / 投影 12B / 步 108B 及其 `OFF_*`），**未读 toml 文件本体**的条目形态与 `[runtime.x86]` 小节实例。
4. **`.ccr` loader 的段序闸精确形态**——本会话核到版本闸（`ccr_io.cr:979`）、段号闸（`:1006`）、TYPE/IFACE 重复闸（`:1017-1018`）与格式文档"`tg == ri+1` + 段体连续两闸"的**文字**，**未逐行核**该两闸的代码实现（`ccr_io.cr:1000+` 段未逐行读）。
5. **跨 domain 后 Entry 的 kind 属性是否随域改变**（§2.3 规则 3 的交互）——与 `region_check` 的活子图义务的关系**未核**。
6. **`@executionDomain` 硬错是否已与 fail-closed 门/豁免表兼容**——本会话核到门与豁免表**存在**（`diag.cr` 头注 + `diag_gate_exempt`）与 `test_diag_gate.py` 的存在，**未核**新增码族的注册流程细节。
7. **`grammar/core.ebnf` 的 `Statement` 全文**——只核到 `FlowDecl`（`:22`）与"Statement 不含 FunctionDecl"（来自 `parser.cr:995-996` 的**注**，**非** EBNF 原文）。放开 `flow` 块须以 EBNF 原文为准。
8. **`docs/maintainer/design/dataflow-design.md` §8 的"执行标注空间"**——原文 §"无配方条目"与 S-C §1 都引它（神谕/BSS 实数/FIXPT/模糊融合），本会话**未读该节**；§3.6 的 `storage`/`dynamism` 推导可能与之强相关。
9. **`docs/maintainer/design/existence-structure.md` 的 ENT/NOD/REG 语义视角**——§3.4/§3.5 的 version/home 只核到 `.ccr` 盘面字段与 cache-semantics 条款，**未读**该文档对"存在区间（live range）是版本级别的"（`cache-semantics.md:67` 指向它）的展开。这对 §3.5 ResidencyState 的 live range 承载**可能是必需的**。（⚠ **本批部分补核**：§三 ENT 字段表 `:36-46`、无配方节 `:57-59`、开放点 `:115-123` 已读；**§四–§九 仍未读**。）
10. **`src/stdlib/goroutine.cr`（70 行）的 G 结构体字段全集**——`execution-model.md` §3.2 给了设计态 `struct Goroutine {…}`，**未与实现核对**（§6.8 的 per-domain 队列改动面取决于此）。

**本批（materialization-space 输入）新增的未核实项**：

11. **`recipe` 变活位所需的写点位置**——§3.4.5 结论 1 说"位已预留、只需一写点 + 一消费点"，但**未核**该写点应插在哪（`compute_entries` 内核？`ccr_io` 写侧？还是 `checker` 的类别判定处），也**未核**谁在编译期知道"这条目无配方"（最接近 = cache-semantics 条款 4 的边界标注 `unsafe`，及 `dataflow-design.md` §8 的执行标注——**后者本会话未读**，见第 8 项）。⇒ **`recipe` 的"只差一个写点"这个判断，其可行性未验证。**
12. **`authority` 的仓库侧最近物**——本批只做了**零命中**核验（`authority` 在 `src/` 与 `docs/maintainer/design/`、`docs/academic/` 无出现）。**未核**它是否以**别的词**存在（候选：`home`／`SG_UNSAFE` 的边界通道／`IR_CALL_EXTERN` 的返回值语义／`volatile` 类标注）。⇒ 若它其实以别名词存在，§3.4.5 第 4 行的 `[提案]` 判定**须下调**。
13. **`replicability` 的仓库侧最近物**——同第 12 项，只做零命中核验。**未核**是否有等价约束（候选：`Linear`/一次性类型的既有设计、`chan` 的单产单消边语义 `chan.cr`、arena 的 `share` 规则 `region-model.md` §3.2 推论 B）。
14. **`location` 与 `mt_memd` 的区分是否有既有实现阻力**——§3.4.3 断言二者是不同槽（格层 vs 放置层）。**未核**现有 ENT/REG 面是否**已经**把两者混用（若 `home` 同时被当"槽位"与"域"，实施批会撞上既有消费者）。
15. **`docs/maintainer/design/materialization-space.md`（existdoc 的产物）落盘后的接口面**——本文按**预定名**交叉引用（§文档头 / §〇.1 / §一）。**未核**该文档实际用的字段名/层名是否与本文 §3.4.2 的七字段一致。⚠ **两侧命名若不一致，本文 §3.4.2 与 §八④ 须同批改名**（本文**不重复定义**本体，故**以那份为准**）。

---

## 十三、三态计数与自查

### 13.1 计数

> ⚠ **自指陷阱（本节自身的坑，须先说明）**：本节若把三态标记**写成字面方括号形态**，就会被自己的 `grep` 计入一次 ⇒ 计数**每次重数都变 1**（"计数不可复现"）。故本节内标记一律写作 `〔已实现〕` / `〔已设计未实现〕` / `〔提案〕`（**全角括号**，不匹配计数正则），**其余章节保留方括号形态**。
> 复现口径：`grep -o '\[已实现\]' <file> | wc -l`（方括号形态，**包含 §13.2 自查段的引用**）。

**两种口径都给**（见既有纪律「枚举型计数随细看只会变多」⇒ 写「至少 N」+ 清单，不写穷举断言）：

| 口径 | 定义 | 复现方式 |
|---|---|---|
| **A. 内联标记出现次数** | 全文**方括号形态**标记的出现次数（**同一主张在表内 + 行内会各记一次**） | `grep -o '\[已实现\]' <file> \| wc -l` |
| **B. 去重主张条数** | 下方索引表的行数（一行 = 一条独立主张 **且该行本身不带标记**） | `a=$(grep -n '^〔已实现〕逐条索引' <file> \| cut -d: -f1); b=$(grep -n '^〔已设计未实现〕逐条索引' <file> \| cut -d: -f1); sed -n "$a,${b}p" <file> \| grep -c '^| [0-9]'`（⚠ **必须带 `^` 锚**：否则会先匹配到**本节说明行自身**里的同一串，范围起点前移 ⇒ 读数虚高——本会话实测过 55 vs 真值 14） |

| 档 | A（出现次数） | B（去重条数） | 说明 |
|---|---|---|---|
| 〔已实现〕 | **39** | **45** | B 档每条带 `file:line`，见下清单 |
| 〔已设计未实现〕 | **27** | **14** | B 档每条带出处文件 |
| 〔提案〕 | **45** | 其余全部（**默认档**） | A 口径只数**显式写出**的标记；**未含**默认推断档（散落各处、无标记即为提案） |

**读数的三条口径纪律（实测确立，缺任一条则数不可复现）**：

1. **自指**：本节方法论若含**方括号形态**的标记，会被自己的 `grep` 计入 ⇒ 本节内一律写全角 `〔〕`。本节改写前的 A 读数为 49 / 22 / 38，改写后为 46 / 19 / 36（那两次），差额恰为方法论自身所含量——**非文档内容变化**。
2. **`A < B` 是正常的**（本批起）：索引表的行**本身不带标记**（只有主张文本 + 位置），故 §13.1 曾把索引表头写成方括号时 A 会虚高；归一为全角后，**一个主张在全文中可以只有索引行、没有行内标记** ⇒ `A < B` 成立。**不要据此认为漏标**。
3. **不得反推凑旧数**（既有纪律）：本批新增了 C-11…C-13、不变量 ⑧⑨、15 项未核实清单，**计数上升是内容增加的必然**；若某档数字与本批之前的读数接近或相同，须核**是否真未新增**，而不是照抄旧值。

> 三态计数**随细看只会变多**（既有纪律）⇒ 上表读作「**至少**」；**权威 = 下方索引清单**，非本表数字。
**A 与 B 的差额来源**（可复现，不是错）：同一主张常在一处表格 + 一处行内各标一次；索引表本身也是标记出处。**差额不是计数错误**，是两种口径的定义差。

〔已实现〕逐条索引（便于复核；**每条均可 `jj file show -r develop@origin <path>` 复现**）：

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
| 20 | 版本闸 `ver != CCR_VERSION → -1` | `src/compiler/ccr_io.cr:979` |
| 21 | 段号闸 `tg > CCR_SEG_COUNT → -1` | `src/compiler/ccr_io.cr:1006` |
| 22 | ENT 盘面 28B = `{var_id, version, def_nod, live_start, live_end, home, flags}` | `src/compiler/ccr_io.cr:173-176` |
| 23 | `CIR_CACHE_VER = 22`（独立常量） | `src/compiler/cir_cache.cr:135,170` |
| 24 | `ESZ_SG = 48` + SG 槽偏移 | `src/compiler/dyn_arr.cr:146-152` |
| 25 | `g_df_node_region` 写点 | `src/compiler/dataflow.cr:103`；增长 `dyn_arr.cr:811-813` |
| 26 | `subgraph_containing()` O(1) 归属查询 | `src/compiler/region_check.cr:5-10` |
| 27 | 三 pass 接线 | `src/compiler/main.cr:638-640` |
| 28 | `pa_in_unsafe()` 每调用全扫 SG | `src/compiler/ptr_analysis.cr:15-30` |
| 29 | 三 pass 均为函数粒度 + 逐 DFNode 区间 | `ptr_analysis.cr:172,193,346`；`region_check.cr:105,107,160`；`provenance_verify.cr:52,54,135` |
| 30 | `Core.toml` 只有 `name` | `src/compiler/project.cr`（56 行全文）；`src/compiler/Core.toml` |
| 31 | 调度 = GMP 简化 + 每 M 本地 run queue | `docs/maintainer/design/execution-model.md:75-77`；`src/stdlib/sched.cr:64,82,171` |
| 32 | CLI dump 面（`cir`/`ccr`/`--dump-types`/`--dump-ifaces`/`--dump-params`） | `src/compiler/main.cr:237-240,262,608-609,687` |
| 33 | 错误码分块 + `EC_*` 常量块 + P0xx 号段 | `docs/developer/errors.md`（分节）；`src/compiler/ast.cr:331-357` |
| 34 | cache-semantics 七条 + 范式映射表 | `docs/academic/cache-semantics.md:24-31,79-87` |
| 35 | ENT **内存**布局 24B + `OFF_ENTRY_*` 六槽 | `src/compiler/dyn_arr.cr:135-143` |
| 36 | ⚠ `flags 恒 0` / `home 恒 -1`（**零实例**；理由 = 分配决策不写回格式） | `src/compiler/ccr_io.cr:83-85`；`src/compiler/globals.cr:232` |
| 37 | ENT 字段↔条款对应表 + 无配方条目节（`flags bit0 = 无配方` 的**设计文档**陈述） | `docs/maintainer/design/existence-structure.md:36-46,57-59` |
| 38 | 存在结构的三段总览 + ENT 为"存在结构核心" | `docs/maintainer/design/existence-structure.md:20-34` |
| 39 | 纯度函数真值（`compute_all_purity` / `purity_op_effect`）——§3.6 推导原料 | `src/compiler/checker.cr:4555,4508` |
| 40 | ⚠ **零命中核验**：`authority` / `replicability` 在 `src/` + `docs/maintainer/design/` + `docs/academic/` **无任何出现** | 本会话 grep 实测（负结果也是实核结果） |
| 41 | ⚠ **零命中核验**：`ExecutionDomain` / `MemoryDomain` / `TopologyLink` 全仓无出现 | 本会话 grep 实测 |
| 42 | `ENT.flags` = **u32，bit0–3 已定 ⇒ bit4–31 空余 28 位** | `src/compiler/dyn_arr.cr:143`；`docs/maintainer/design/existence-structure.md:45` |
| 43 | ⚠ **ENT 两态记录槽全命名、无空余 4B**（内存 6×4B 全满 / 盘面 7×4B 全满，`version` 由组序导出） | `src/compiler/dyn_arr.cr:136-143`；`src/compiler/ccr_io.cr:173-177` |
| 44 | ⚠ **REG 盘面记录 6×i32 全满、无空余槽**（内存 `ESZ_SG` 6×u64 亦满） | `src/compiler/ccr_io.cr:157-162`；`src/compiler/dyn_arr.cr:146-152` |
| 45 | ⚠ **HIT M2 的四处记载（自本批起 = 真源）**：仍记「挂账 / 待执行」，**无淘汰记载**；正是它们把口述裁决翻了过来（维护者改裁「以书面为准」） | `TODO.md:2211`、`TODO.md:2215`；`docs/superpowers/plans/2026-09-07-hit-m2.md:3`；`docs/superpowers/specs/2026-09-07-hit-m2-design.md` |

〔已设计未实现〕逐条索引：

| # | 主张 | 出处 |
|---|---|---|
| 1 | S-C L1–L7 裁决（含 L1 零机器名词 / L2 优化=映射选择 / L3 合法性可判定+收益启发式 / L5 成本模型=数据 / L6 守零新语法） | `docs/superpowers/specs/2026-09-11-performance-without-commitment-design.md` §0.2 |
| 2 | S-C §2.1 六段流程 | 同上 §2.1 |
| 3 | S-C §2.2 合法性/收益分界表 | 同上 §2.2 |
| 4 | S-C §2.3 成本模型契约六条（`band` 必填 / 模型非证明 / 与 `PROVED` 不混报） | 同上 §2.3 |
| 5 | S-C §3.1 目标描述形态 + `.ccr` 新段承载成本事实 | 同上 §3.1 |
| 6 | S-C §3.2 五条可迁移判据 + 三项反向泄漏检测 | 同上 §3.2 |
| 7 | S-C §0.0「机制同一，无第二条性能路线」/ 禁为 SIMD-CUDA-NPU 开特判通道 | 同上 §0.0, §0.5 |
| 8 | HIT spec「替换表 = 换目标平台」+ 接口非映射 + §3.2 三范式投影 + §4 可移植子集 + §7 优化不进表 | `docs/superpowers/specs/2026-09-05-hardware-interface-table.md` §1,§3.2,§4,§7 |
| 9 | `.ccr` tag `9+` 既有主张 = 驱逐标注段 / 证书段 | `docs/superpowers/specs/2026-09-09-lattice-ir-v7-format.md:50` |
| 10 | execution-model §5.1/§5.3/§六 部署配置原则 | `docs/maintainer/design/execution-model.md:180-183,199-201,203` |
| 11 | archive「无格承诺」v4 定稿 | `docs/archive/memory-model-capability-lattice.md:11,14,15` |
| 12 | **〔本批新增〕**「格 = 缓存」教义的 7 处既有落点（C-11 表逐条行号） | `cache-semantics.md:4`；`project-book.md:109,216`；`z-vision.md:15`；`memory-model.md`（标题 + §一）；`existence-structure.md`（标题 + §三表头）；`region-model.md:3-5` |
| 13 | **〔本批新增〕**三层映射链的既有层名「图 → **格** → 编码」+「中间存在空间」 | `docs/project-book.md:109`；`docs/z-vision.md:15` |
| 14 | **〔本批新增〕**`existence-structure.md` 的 `flags` 位语义（bit0–bit3）——**陈述式**，与实现的「预留 + 零实例」有落差 | `docs/maintainer/design/existence-structure.md:45,59` |

### 13.2 自查

- **不变量表**：①–④ 齐（§八），另补 ⑤⑥⑦ + **〔本批新增〕⑧（`Evictable` 定义）⑨（格层不承担 policy）**。每条含**形式陈述 + 判据形状 + 三态 + 违反后果 + 反向钉子**。① 的判据**已显式处理 STR 段陷阱**（否则判据会假红）；③④⑧⑨ 给的是**两向钉子**而非单向。
  ⚠ ④ 本批**加强**：七字段完备 + **删除 `valid` 位** + 新增 `authority`/`replicability` 两条专项判据（这两条是旧框架**无法表达**的档）。
  ⑧ 的关键钉子 = **第二支 `PreserveRequiredState` 的单独判据**（缺它则第二支形同虚设）。
  ⑨ 的关键钉子 = **可缺席性**（清空 policy 后格层判定逐条不变）。
- **数据结构定稿**：§三 十节，字段级（槽偏移 + 类型 + 含义）。§3.4 **本批重写**为**两级结构 + 七字段 + 逐字段距离实核**；§3.5 删除 `valid` 位。
- **三态标注**：§13.1 计数；默认 `[提案]`；`[已实现]` 全带 `file:line`。
  ⚠ **本批最重要的一条三态修正**：`recipe` **不标 `[已实现]`**——精确结论 = **「预留槽位 + 恒零值」→ `[已设计未实现]`**（§3.4.5 / §十一 C-13）。七字段里只有 `identity` / `version` 是 `[已实现]`（且 `version` 仅盘面）。
- **冲突登记**：C-1…C-10 + C-11（「格 = 缓存」7 处落点）/ C-12（层名）/ C-13（flags 位语义 vs 零实例），每条给断言 / 仓库现状 / 我的结论 / 待裁点，**未替维护者裁决**；**既有「定稿」文档一律未改**。
- **〔最新批〕HIT M2 淘汰的落实（C-1 重写 + C-3 下调）**：
  - **C-1 的裁决反转（本节最重的一条，须按"两轮"读）**：
    - **第一轮（口述）**：维护者经 team-lead 转达「**HIT M2 早已淘汰**」（**未见原话，来源 = 经 lead 转达**）⇒ 本节曾据此 ① 删去"M4 前补 HIT M2 收口"待裁项；② 论证**去进度化**；③ 判「通用下降路径 = **未被命名的设计空缺**」。
    - **第二轮（书面校正 ⇒ 整轮回退）**：本文按纪律**去实核书面留痕**，找到**四处反向记载**（`TODO.md:2211/2215`、`plans/2026-09-07-hit-m2.md:3`、`specs/2026-09-07-hit-m2-design.md`）⇒ 维护者改裁「**以书面为准**」⇒ ① 待裁项 (c) **恢复**（留痕式）；② 论证**回退到进度化**（`lower_to_core.cr:21` 是**临时缺口**，非永久设计）；③"设计空缺"判定**撤回**（HIT 仍是既定承担者，待 M2 收口）；④ **四处记载自本批起 = 真源**。
    - 连带登记**全部撤回**：HIT spec §1 与 S-C §0.3 的"前提失效"**不成立**（那些是**待 M2 达成的目标**）。
    - **§八⑦ 恢复**为"依赖 C-1 待裁点 (b)/(c)"（**不再标注"不可判定"**）。
    - **方法论实例已落纸**（C-1 末节）：**「口述 vs 书面记载冲突 ⇒ 以书面为准」**的完整四步实例；要点 = ① 不把口述写成已证事实 ② **实核留痕是可操作的翻案步骤** ③ **回退留痕、不静默改回**。
  - C-3 **下调**（部分，**不受 C-1 反转影响**——它是独立的格式实核）：七字段**确不需要段**（`ENT.flags` 空余 **28 位**，实测）；⚠ 但 ① "现有 4B 槽"**本文未找到**（ENT 内存 6 槽 / 盘面 7 槽**全命名**）；② `location` 需**域编号** ⇒ 位打包**给内存域数量设硬上限**（= 仓库一直在退役的 `MAX_*` 模式）；③ REG 记录**全满** ⇒ MAP 若按 region 承载仍须改布局。§9.3 倾向**由 A 改为 C**（placement 不进 `.ccr`，理由 = 不变量 ① 本身）。
- **未核实清单**：§十二 十五条（本批新增 11–15，其中第 15 项 = **与 `materialization-space.md` 的命名对齐义务**）。
- **交叉引用**：文档头三处——① `materialization-space.md`（**本体定义归它，本文不重复定义**，并注明该文件尚不存在）；② `mapping-layer-separation.md`（投影面 vs 放置面，亦注明尚不存在）；③ `existence-structure.md`（存在格的 IR 承载）。
- **层归属（本批新增）**：§〇.2 + §6.7 + §八⑨ 三处**同口径**划界「格层只答四问 / policy 全归 mapper」。
- **本文档未修改任何既有文件**（新增单文件；`/tmp/briefs/*` 两份真源亦未动）。
