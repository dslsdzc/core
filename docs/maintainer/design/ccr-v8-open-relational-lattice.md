# Core V8 — Open Relational Lattice

> 定位：受众 = 维护者（`ccr_io` / `corearch` / verifier / mapper 实现者）；状态 = **设计定稿（未实现）**
> ——全文除显式标注 `[已实现]` 处外，**均无仓库对应物**。
> 设计意图真源 = **一份**维护者 2026-09-22 会话口述输入（**逐字，本文不改写它**）：
> - `/tmp/briefs/ccr-v8-raw.md` —— 31 节 + 八条公理（§30）+ 验收标准（§31）+ **文末两处已裁决**。
> 本文 = 其**形式化展开 + 仓库锚定 + 冲突登记**。
>
> **核验基线 = `develop@origin` @ `0eb1efd3`**（本会话 `jj git fetch` 后实读；**所有 `file:line` 以该修订为准，非手边检出**）。
> 读本文时须区分**三种声音**：① **原文**（维护者原话，带引号或标「原文」）；② **本文展开**（写手的形式化，标「展开」）；
> ③ **现状实核**（带 `file:line`）。三者不得混读——**尤其不得把 ① 读成 ②，把 ② 读成现状**。
>
> 关联：
> - [existence-structure.md](existence-structure.md) —— 被取代的 ENT/NOD/REG 语义承载（见 §二十三 C-3）
> - [materialization-space.md](materialization-space.md) —— 存在格层定义（ADR-0021）——**V8 与它的关系见 §二十三 C-3**
> - [execution-mapping-design.md](execution-mapping-design.md) —— **同批同伴**：其「Mapping 是一等层」与本文 §二十九「Mapping 非本体」的张力见 §二十三 C-4
> - [2026-09-09-lattice-ir-v7-format.md](../../superpowers/specs/2026-09-09-lattice-ir-v7-format.md) —— 现行字节权威（段表架构）——**V8 取代它**
> - [adr-0002-ccr-v6-segment-table.md](../adr/adr-0002-ccr-v6-segment-table.md) —— v6 段表架构决策（accepted）——**V8 需要新 ADR supersede（建议，不裁决，见 §二十五）**

---

## 〇、三态标注约定（全文强制）

本文档凡陈述「仓库现在有什么」的句子，**逐句**带下列标记之一：

| 标记 | 含义 | 举证义务 |
|---|---|---|
| `[已实现]` | 核验基线上有实现 | **必须给 `file:line`**（本会话实核，非记忆） |
| `[已设计未实现]` | 仓库有设计文档/规划但无实现 | 必须给出处文件 |
| `[提案]` | 本文新提出，仓库无对应物 | 无（**默认档**） |

**默认必须是 `[提案]`**：核不到行号的句子一律不得标前两档。

> ⚠ **本设计的特殊性（读前必读）**：V8 **几乎全是 `[提案]`**——它是一套**尚未落地的格式与语义重定义**。
> 本仓库现存的一切 `.ccr` 机制（8 段表、`CCR_VERSION = 9`、NOD/ENT/REG 承载）**都是 V8 要替换的对象**，
> 不是 V8 的前身实现。故本文的 `[已实现]` 只出现在**「现状锚点」与「判据网现状」两类句子上**，
> **绝不出现在任何描述 V8 本身的句子上**。三态计数见 §二十六。

### 〇.1 术语护栏（四处同名不同义，先钉死）

| 词 | 本文档的义 | 仓库既有文档的义 | 处置 |
|---|---|---|---|
| **Lattice / 格** | **模型精化偏序**（`T ⊑ T' ⟺ Models(T') ⊆ Models(T)`，§六）——**不承诺任何硬件语义** | `materialization-space.md` 的**存在格**（Materialization/Existence Space，ADR-0021）`[已设计未实现]`；`memory-model-capability-lattice.md`（archive）的**能力格**（mapper 内部组织参数） | 本文一律写「**精化格**」（refinement lattice）；指既有义时写全称「存在格」/「能力格」 |
| **Theory** | V8 的**模块单位**（§三 3.6 / §十八），无 Core 特权 | 仓库无此概念（**本会话实核零命中**：`grep -rin theory src/compiler/ grammar/` = **0 行**） | 无冲突，但**不得**与 `theory` 关键字（若将来入语法）混谈；本文 `theory` 块**是设计语法，不是现行语法** |
| **Algebra** | **局部可选**的更强结构（§十二），挂在单个 relation 上 | 无此物（archive 的「无格承诺」约束见 §二十三 C-5） | 本文 `algebra` 块 = `[提案]` |
| **Mapping** | **relation theory 的一个应用**，非 CCR 本体（§二十九） | `execution-mapping-design.md` 的**一等层**（计算 → 执行域放置）`[已设计未实现]` | ⚠ **同批直接冲突** → §二十三 C-4 登记，本文**不裁决** |

### 〇.2 记法约定

- `T` = theory；`Models(T)` = T 的模型类；`𝓛(G, CCR)` = HDFG `G` 与呈现 `CCR` 共同刻画的**关系宇宙**（原文记号，本文沿用）。
- `.ccr` = 盘上字节；`𝓛` 一般**不可写、不可展开**（§十八）；`Projection_Q(𝓛)` = 查询 Q 下有限投影。
- 语法块一律用 ` ``` ` 包裹；**现行语法**与**设计语法**在块首行注明（本设计全部为后者）。

---

## 一、设计的总结构（原文 §1）

原文核心一句话（**逐字**）：

> V8 的 .ccr 是一个有限的关系理论描述；它定义的关系空间、模型空间和格都可以是无限的。

结构（原文图，逐字转写）：

```
HDFG
  │  semantic facts / symbols
  ▼
┌──────────────────────────────┐
│             .ccr             │
│   symbols · relations · rules · constraints
│   optional algebra · optional fixpoints
└──────────────┬───────────────┘
               ▼
       Relational Universe  𝓛(G, CCR)
               │
     ┌─────────┼─────────┐
     ↓         ↓         ↓
 verification mapping  analysis
     └─────────┼─────────┘
               ▼
            encoding
```

原文最强调的一句（**逐字**）：

> 这里最重要的是：**`.ccr ≠ 𝓛`**。`.ccr` 只是有限 presentation。真正的 `𝓛(G, CCR)` 可以无限。

**本文展开（非原话）**：这条区分是 V8 全部设计的支点。它把 `.ccr` 从「IR 的一种序列化」重新定义为**一个理论的有限呈现（finite presentation）**，
而把「IR 是什么」交给呈现的**指称**（denotation）承担。由此直接得到三个后果：

1. `.ccr` 的**文件大小**与其**所指称的结构规模**解耦——文件可以很小而指称无界（CCR-4）。
2. 对 `.ccr` 的**消费者**，正确的接口是**查询**而不是**展开**（§十八）。
3. `.ccr` **不能**是其指称的唯一来源——因为指称由理论 + 宿主图共同决定，`.ccr` 只是其中一半（CCR-8 的雏形）。

---

## 二、八条公理（CCR-1 … CCR-8）——本设计的根

> 原文 §30 逐字：「如果要我最终压缩成规格，我只保留这八条」「我认为这八条已经足够定义 V8 的根」。
> **下文每条 = 形式陈述（原文逐字引）+ 它禁止了什么（本文展开）+ 可机械检查的判据形状（本文展开）。**
> ⚠ 判据形状栏**全部是 `[提案]`**——核不到任何实现，且**当前无实现可跑**。

### CCR-1 Open Symbols（开放符号）

- **形式陈述（原文）**：符号宇宙不封闭；新增 symbol 不修改 Core。
- **它禁止了什么（展开）**：
  - 禁止任何**符号命名空间白名单**（`enum SymbolKind`、`@hdfg.*` / `@target.*` / `@external.*` 之外的注册表）；
  - 禁止 Core 对符号**语义**做任何承诺——原文 §3：「CCR Core 不知道 `gpu0` 是设备、`r12` 是寄存器、`timer0` 是时钟——**只有相应 theory 知道**」。
- **判据形状（展开）**：
  1. 给一个 Core 从未见过的符号（如 `@future.domain.qubit7`）⇒ 定义 relation / fact / rule 全部通过，`CCR_VERSION`、段集合、`CCR_SEG_COUNT` **零变化**；
  2. 机械检查：kernel 源码对**符号前缀字面量**零命中（`grep -c '@target\.\|@hdfg\.' <kernel>` == 0）；
  3. **负向钉子**：内核里出现任一硬编码符号前缀或符号种类枚举 ⇒ 判据红。

### CCR-2 Open Relations（开放关系）

- **形式陈述（原文）**：关系集合不封闭；新增 relation 不修改 Core。
- **它禁止了什么（展开）**：
  - 禁止 `enum Theory { Memory, Time, Security, Execution }` 这类**硬编码理论/关系命名空间**（原文 §15）；
  - 禁止对 relation **元数**做固定（原文 §5「不固定元数」）；
  - 禁止关系名的**注册表**——relation 由 theory 局部声明，不与 Core 协商。
- **判据形状（展开）**：
  1. 新 domain 的 `theory weird.future.domain`（§二十一 21.1）能定义任意元数 relation 并给出规则 ⇒ 加载 + 查询通过，**文件格式零修改**；
  2. 机械检查：Core 中不存在 relation 名清单（`grep` relation 名白名单 / kind 枚举 == 0）；
  3. **负向钉子**：新增 relation 需要改 `CCR_VERSION` 或段集合 ⇒ 判据红（这正是 §二十一 21.1 主验收）。

### CCR-3 Open World（开放世界）

- **形式陈述（原文）**：缺失事实表示 unknown，不表示 false。
- **它禁止了什么（展开）**：
  - 禁止 **closed world assumption**：`R(a,b) ∉ CCR` **绝不能**推出 `¬R(a,b)`；
  - 禁止「未证明 = 已否证」的推理链——原文 §6 逐字：「没有 `proves(alias(a,b))` **不能**说明 `noAlias(a,b)`，**必须显式获得反向证据**」；
  - 禁止任何把 negative 作为 **default** 的合取/求解语义。
- **判据形状（展开）**：
  1. 查询一个**未给出**的事实 `R(a,b)` ⇒ 信息状态 = `unknown`（**既非** true **也非** negative）；
  2. 机械检查：信息状态类型的最小值域含 `unknown` 且 **`unknown` 是默认构造值**（不得默认 `false`）；
  3. **负向钉子**（最强）：故意问一个未给的事实，返回 `negative` ⇒ 判据红（这条是 CWA 回归的唯一可靠探测器）。

### CCR-4 Finite Presentation, Unbounded Denotation（有限呈现，无界指称）

- **形式陈述（原文）**：`.ccr` 有限，但其 term/relation/model 空间可以无限。
- **它禁止了什么（展开）**：
  - 禁止**任何 `MAX_*` 式的上界**参与语义（原文 §4 逐字：「**有限规则可以生成无限结构**」——`0, succ(0), succ(succ(0)), …` 理论上没有上限；原文明确否定了「无界性 = 文件可以无限大」这种误读）；
  - 禁止把「可表示的闭包大小」与「文件尺寸」绑定。
- **判据形状（展开）**：
  1. **尺寸不变量**：`.ccr` 字节数与推导闭包规模**无关**（同一 theory 下，`edge` 链从 3 个 fact 扩到 3000 个 fact，规则部分字节数不变）；
  2. **无界性探测**：一条递归规则下的查询结果集 > 显式 fact 数（证明闭包真被算出来，而非只回声输入的 fact）；
  3. 机械检查：kernel 中与结构规模相关的 `MAX_*` 常数 == 0（**注意**：本仓有 `MAX_FN_PARAMS` 类**既有**实现常数——它们属旧实现，本判据测的是 **V8 kernel**，不是全仓 `grep`）。

### CCR-5 No Universal Relation Algebra（无普适关系代数）

- **形式陈述（原文）**：所有 relation 默认无代数性质；性质必须显式声明。
- **它禁止了什么（展开）**：
  - 禁止 Core **默认**注入 reflexive / symmetric / transitive / antisymmetric / functional / total **六性质中任何一个**（原文 §5 逐字：「**全部默认为未知**」）；
  - 禁止「因为名字像 `before` 所以给传递性」这类**命名启发式**；
  - 禁止把 `compose` 这类偏运算静默补全成全运算。
- **判据形状（展开）**：
  1. 对未声明代数的 relation，六个性质查询**全部**返回「未声明」（不是 `false`，不是 `true`）；
  2. **负向钉子**：任一性质查询在无声明时返回 `true` ⇒ 判据红；
  3. 机械检查：默认性质表在加载期恒空（结构性断言，非值断言）。

### CCR-6 Explicit Derivation（显式推导）

- **形式陈述（原文）**：新事实只能来自 given / assumption / external 或 rule derivation。
- **它禁止了什么（展开）**：
  - 禁止**来源不明的 fact**（任何进入关系宇宙的事实必须带 origin，见 §十七）；
  - 禁止把「solver 算出来的」与「假设的」**混为一谈**（原文 §17 逐字：「`assume deviceSupports(gpu0, fp64);` 和 `prove deviceSupports(gpu0, fp64);` **不能混**」）；
  - 禁止 derivation 不记 rule 出处（`derived` 必须带 `via`）。
- **判据形状（展开）**：
  1. 每条 fact 的 origin ∈ {`given`, `derived`, `assumed`, `external`} **四值闭合**，且 `derived` 必带 `via`（rule 名）；
  2. **fail-closed**：origin 缺失的事实 ⇒ **拒绝加载**（不得默认成 `given`——那是静默升格）；
  3. **负向钉子**：把 origin 缺失的 fact 静默接受 ⇒ 判据红。

### CCR-7 Local Consistency（局部一致）

- **形式陈述（原文）**：冲突不能产生逻辑爆炸；是否非法由相应 constraint/theory 判断。
- **它禁止了什么（展开）**：
  - 禁止 classical logic 的爆炸律（`R(a) ∧ ¬R(a) ⊢ anything`）进入 relation store——原文 §20 逐字：「这对 compiler relation store 是**灾难**」；
  - 禁止 Core **自行**把冲突判为非法（合法性归 constraint/theory，不归 kernel）；
  - 禁止把冲突**静默丢弃**（丢弃 = 另一种谎；冲突必须显式可观测）。
- **判据形状（展开）**：
  1. 注入 `R(a)` 与 `¬R(a)` ⇒ 加载/查询**正常返回**（不崩、不爆炸），信息状态 = `conflict`，且**冲突本身可被查询到**；
  2. **爆炸探测**（关键）：在该冲突下查询一个**完全无关**的事实 `Q(b)` ⇒ 必须仍为 `unknown`；若变成 `true` ⇒ 判据红（爆炸发生）；
  3. 冲突是否导致「非法」由**声明的 constraint** 决定；无相应 constraint 时加载必须成功。

### CCR-8 Semantic Non-Authority（语义非权威）——**本设计最容易被违反的一条**

- **形式陈述（原文）**：`.ccr` 不替代 HDFG 的程序语义；它描述**关于**语义及其映射/分析的关系。
- **它禁止了什么（展开）**：
  - 禁止 `.ccr` 成为**第二语义权威**：程序「实际算什么」只能由 HDFG 决定，`.ccr` 只能**描述**它；
  - 禁止发射路径依赖 theory/relation 段（否则 `.ccr` 的关系面就变成了新的语义来源）；
  - 禁止 `.ccr` 与 HDFG 冲突时「以 `.ccr` 为准」的任一默认方向；
  - 禁止 `.ccr` 携带**不可从 HDFG + theory 重导出**的信息（否则它就成了唯一来源）。
- **判据形状（展开）——「怎么证明 `.ccr` 没有偷偷变成第二语义权威」**（四条，须全绿）：

  | # | 判据 | 观测方式 | 反例（红）条件 |
  |---|---|---|---|
  | **N-1 发射无关** | 发射路径对 theory/relation/fact/rule/constraint 段的消费者数 == 0 | 调用图上逐段消费者清点（或更强的**截断实验**：把关系段整体置空，ELF **逐字节不变**） | 任一段被发射路径读取，或截断后 ELF 变 |
  | **N-2 可弃性** | 丢弃 `.ccr` 全部关系面后，程序语义仍完整可得 | 从 HDFG 独立重放 ⇒ 与带 `.ccr` 的产物语义等价 | 语义只在 `.ccr` 里（HDFG 侧缺） |
  | **N-3 交叉一致** | `.ccr` 的 fact 与 HDFG 蕴含**冲突时判据必须红** | 交叉一致性检查 pass（显式存在，非「自然会对上」） | 冲突共存、以任一方向静默消解 |
  | **N-4 可重建** | `.ccr` 不含 HDFG+theory 无法重导出的信息 | 删除 `.ccr` 后从源码+theory 重建，关系面**同构** | 存在只有 `.ccr` 才有的信息 |

  > ⚠ **N-1 的截断实验是本条唯一不可伪造的形式**。凡「结构上不会读到」这类论证一律不算——
  > 本仓已有先例：**结构不对但闸门放行 ⇒ 静默当空表**（D10 原文见 §二十三 C-1）。
  > 判据必须做成**负向可观测**（截断后仍绿才算绿），不得只做正向断言。

---

## 三、五个原语 + Theory（原文 §2 / §3 / §4 / §5 / §7 / §8 / §14）

> 原文 §2 逐字：V8 首先禁止 `LatticeNode { kind: CacheEntry | Value | Memory | ... }` 这种设计——
> 「格层不应该知道这些」。V8 Core 的原语面**极小**，其余一切（含 Algebra）都是可选扩展。

### 3.0 计数口径登记（原文与展开的差异，**必读**）

原文 §2 逐字为：**「V8 Core 只有五个原语：Symbol / Term / Relation / Rule / Constraint / Theory」**——
列举 **6 个名字**而称「五个」。维护者在派发本设计的任务书中给定口径为
**「五原语 = Symbol / Term / Relation / Rule / Constraint」+「Theory 的组合语义」单列（§14/§27/§28）**。

**本文采用任务书口径**（5 + Theory 作组合单位），并把原文的 6 名列举**原样登记于此**，不改写原文、不自作裁决。
本条属**枚举型计数**，按本仓纪律（枚举计数随细看只会变多）应读作「**至少 5 个原语**」而非精确基数。

### 3.1 Symbol（最小身份）

- **定义（原文 §3）**：Symbol 是最小身份。来源 = HDFG / CCR 内部构造 / 外部环境 / backend / deployment **五类**（原文列举，非闭集）。
- **概念表示（原文逐字）**：`@hdfg.node.17` · `@hdfg.value.31` · `@target.gpu0` · `@target.reg.r12` · `@external.timer0`。
- **核心不规定它是什么（原文逐字）**：「但这些只是名字。CCR Core 不知道 `gpu0` 是设备、`r12` 是寄存器、`timer0` 是时钟——只有相应 theory 知道。」
- **[提案] 字段级定义（本文展开，按现行 `.ccr` 命名习惯给字段形状；**不落盘、不声称已定**）：

  | 字段 | 含义 | 约束 |
  |---|---|---|
  | `ns` | 命名空间前缀（`hdfg` / `target` / `external` / theory 内名） | **开放字符串**，非枚举（CCR-1）；Core 不解释 |
  | `local` | 命名空间内局部名 | 开放字符串 |
  | `name_ni` | STR 段串索引（若沿用现行池化惯例） | 编码层细节，**不定义语义** |

- **[已实现] 现状对照**：现行 `.ccr` **无 symbol 段**——最接近的是 `STR(1)` 段（字符串池，`src/compiler/ccr_io.cr:38`）
  与 `SYM(2)` 段（符号面，`:39-59`），但两者的语义是**编译器内部命名**（函数/全局/结构/枚举），**不是** V8 的开放身份。**不得**把 SYM 段读成 V8 的 Symbol。

### 3.2 Term（无界结构的构造子）

- **定义（原文 §4）**：`t ::= s | f(t₁,…,tₙ)`（`s` = Symbol，`f` = 函数符号）。
- **例（原文逐字）**：`version(x, 3)` · `offset(x, 16)` · `next(event)` · `interval(t0, t1)` · `path(A, B)` · `domain(gpu, 0)`。
- **无界性（原文逐字）**：「这样有限 CCR 就能描述无限 term universe：`0, succ(0), succ(succ(0)), …` 理论上没有上限。」
  并明确否定了误读：「所以 V8 的无界性**不是**"文件可以无限大"，而是"**有限规则可以生成无限结构**"。」
- **[提案] 字段级定义（本文展开）**：

  | 字段 | 含义 | 约束 |
  |---|---|---|
  | `tag` | 构造子（Symbol 引用）或变量 | 开放；Core 不枚举构造子集合 |
  | `args` | 子项列表（可为空 = 常量项） | 元数由构造子的 theory 局部声明 |
  | `is_var` | 是否为绑定变量（查询/规则里的 `?x`） | 与「项」区分，**不另立原语** |

- **[已实现] 现状对照**：现行编译器有大量**项结构**的应用（如 `g_type_terms` 的类型项 DAG、`src/compiler/type_terms.cr`；
  盘面 = `TYPE(7)` 段，`src/compiler/ccr_io.cr:97-111`），但它是**判定引擎内部**的项表，**不是** V8 意义的通用 term universe（无开放构造子、无规则生成）。
  两者**形状相似、地位完全不同**：V8 的 Term 是原语，现行的类型项是某一 theory 的内部数据（属 V8 后 §十六 16.2 的降级对象）。

### 3.3 Relation（关系）

- **定义（原文 §5）**：核心形式 `R(t₁,…,tₙ)`，**不固定元数**。
- **例（原文逐字）**：`depends(A,B)` · `coexists(x,y)` · `before(a,b)` · `located(x,gpu0)` · `compatible(R,D)` · `producedBy(x,n)` · `flow(secret,network)` · `distance(a,b,d)`。
- **无预设性质（原文逐字，V8 铁律）**：「Relation 本身**没有预设性质**。V8 Core **不得默认**：reflexive / symmetric / transitive / antisymmetric / functional / total。**全部默认为未知**。这就是"规则足够弱"的第一层。」（= CCR-5）
- **[提案] 字段级定义（本文展开）**：

  | 字段 | 含义 | 约束 |
  |---|---|---|
  | `name_ni` | 关系名（STR 池索引） | 开放；**无 Core 注册表**（CCR-2） |
  | `arity` | 元数 | 由声明处**显式或从声明推断**；可为 0（命题式 relation） |
  | `fixpoint` | **μ / ν / 无** 三态（见 §五） | **默认 = 无**（原文 §9：这是最关键的一刀） |
  | `algebra_ref` | 可选局部代数引用（见 §十二） | **默认缺席**（CCR-5） |
  | `theory` | 声明它的 theory id | 归属单位（§十 / §十九） |

### 3.4 Rule（推导规则）

- **定义（原文 §7）**：基本形式 `P₁ ∧ P₂ ∧ … ∧ Pₙ ⇒ Q`，负责**生成无限关系**。
- **例（原文逐字）**：

  ```
  edge(x,y)                     => reachable(x,y)
  reachable(x,y) && edge(y,z)   => reachable(x,z)
  ```

  「只有两条规则，但 `reachable` 可以定义任意大的闭包。」
- **Cache 的定位（原文逐字，重要）**：`producedBy(x,n) && replayable(n) => reconstructible(x)`。
  「**Cache 以后就只是这种 theory，不是 Core 公理。**」（→ §十六 16.1）
- **[提案] 字段级定义（本文展开）**：

  | 字段 | 含义 | 约束 |
  |---|---|---|
  | `head` | 结论（单个 relation 应用，**本文按原文形式取单头**） | 多头（`Q₁ ∧ Q₂`）**未在原文出现** ⇒ §二十四 待裁 |
  | `body` | 前提合取（relation 应用列表 + 等词/绑定） | 元数不限；变量作用域 = 规则局部 |
  | `theory` | 归属 theory | 规则**不得**跨 theory 引用 relation，跨域须显式 bridge（§十九） |

### 3.5 Constraint（合法性要求）

- **定义（原文 §8）**：`C(R₁,…,Rₙ)`——「哪些关系配置**不允许**」（admissibility）。
- **它不是新事实（原文逐字）**：「它不是新的程序事实，它是**合法性要求**」。
- **[提案] 字段级定义（本文展开）**：

  | 字段 | 含义 | 约束 |
  |---|---|---|
  | `body` | 关系/条件合取 | 与 Rule 同形，**语义完全不同**（§四） |
  | `verdict` | 违反时的判定结果 | 原文示例用 `=> invalid`；**是否只有 `invalid` 一个值** ⇒ §二十四 待裁 |
  | `theory` | 归属 theory | 是否触发「非法」由该 theory 决定（CCR-7） |

### 3.6 Theory（组合单位，V8 真正的模块）

- **定义（原文 §14）**：Theory 是 V8 真正的模块单位——「以后不要搞 `CacheModel` / `MemoryModel` / `GPUModel` …… **都做成 Theory**」。
- **组成（原文示例逐字转写）**：

  ```
  theory classic.regalloc {
      relation coexists(x, y);
      relation located(x, r);
      relation register(r);
      constraint ...
  }

  theory temporal {
      relation before(a, b);
      relation delta(a, b, interval);
      rule ...
      constraint ...
  }

  theory cache {
      relation producedBy(x, n);
      relation replayable(n);
      relation reconstructible(x);
      rule producedBy(x,n) && replayable(n) => reconstructible(x);
  }
  ```

- **能力与边界（原文逐字）**：「Theory 可以 import / extend / parameterize，**但不能拥有 Core 特权**。」
- **组合语义见 §十九**（原文 §27/§28）——**组合默认只是并列**，跨域耦合必须显式 bridge。

---

## 四、Rule vs Constraint —— deduction vs admissibility（原文 §8 专节）

> 原文 §8 逐字：「这个区别很重要。」「**不要混在一起。**」
> 本节把它写死为一节，并给**同一事实在两侧各自的例子**。

| 面 | **Rule** | **Constraint** |
|---|---|---|
| 问句（原文逐字） | 「已知这些，**可以推出什么**？」 | 「哪些关系配置**不允许**？」 |
| 逻辑角色（原文逐字） | **deduction**（推导） | **admissibility**（可容许性） |
| 形式（原文） | `P₁ ∧ … ∧ Pₙ ⇒ Q` | `C(R₁,…,Rₙ)` |
| 产物 | **新事实**（进关系宇宙，带 origin=`derived`） | **合法性判定**（不进事实集） |
| 用途（原文逐字） | 生成闭包（§3.4 例） | 验证 / mapping / 求解 / backend legality |
| 违反时 | 无「违反」概念——不触发即不推导 | 触发 constraint failure（**显式诊断**，§十五） |
| 与 CCR-6 | **唯一**能产生新事实的两条途径之一（rule derivation） | **不产生**任何事实 |

### 同一事实的两侧例子（本文展开）

取一个事实：**「x 与 y 同处一个寄存器的存在区间」**。

- **Rule 侧**（推导出「可共存」这一事实）：
  ```
  rule located(x, r) && located(y, r) && disjoint_interval(x, y) => coexists(x, y);
  ```
  ⇒ 产出新事实 `coexists(x,y)`，origin = `derived`，`via` = 该规则。
- **Constraint 侧**（判定「不可共存的两者同处一寄存器」为非法）：
  ```
  constraint coexists(x, y) && located(x, r) && located(y, r) => invalid;
  ```
  原文逐字给出的正是这一条：「例如 `coexists(x,y) && located(x,r) && located(y,r) => invalid`。它不是新的程序事实，它是**合法性要求**。」

**两例的关系（本文展开，重要）**：两者**语法同形**（都是 body ⇒ 结论），**语义相反**——
Rule 是**单调增长**事实集，Constraint 是**对配置的过滤**。因此：

> ⚠ **把 Constraint 实现成 Rule**（即把 `=> invalid` 做成一条产生 `invalid` 事实的规则）在**语义上是错的**：
> 它会让「非法」变成关系宇宙里的普通事实，从而 (a) 可被后续规则消费、(b) 可与其他事实一起被推导，
> 最终使合法性判定重新落回推导层 —— 这正是原文要求分家的那件事。
> **机械判据**：`invalid` 不得出现在任何 rule 的 `head`；`constraint` 的结论不得被任何 body 引用。

---

## 五、μ / ν / 默认三态 —— 固定点语义的三态（原文 §9 专节）

> 原文称这是「**最关键的一刀**」：「如果直接模仿 Datalog（rules ↓ 求 least fixed point），Core 又会被锁死。」
> 理由（原文逐字）：「有些东西确实应该是归纳定义 `μF`（例如 reachable），但有些可能是共归纳 `νF`，
> 还有很多关系**根本不应该由 fixed point 定义**，而只是**约束未知模型**。」

### 5.1 语法形状（原文逐字，**写死**）

```
relation reachable(...) inductive;     // μ
relation observable(...) coinductive;  // ν
relation compatible(...);              // 默认：没有 μ/ν
```

- 声明关键字**只有两个**：`inductive;` / `coinductive;`（**行内、分号结尾、跟在 relation 声明后**）。
- **无声明 = 默认态**（第三态）——**不是**「默认 least fixed point」。

### 5.2 三态语义（原文 + 本文展开）

| 态 | 语法 | 语义（原文） | 本文展开（判据形状） |
|---|---|---|---|
| **μ** | `inductive;` | 归纳定义（least fixed point，`μF`） | 查询 = 求**最小**不动点；**必须终止**（§二十一 反例 1）；充分性 = 闭包是「已推导事实的最小集合」 |
| **ν** | `coinductive;` | 共归纳（`νF`） | 查询 = 求**最大**不动点；**终产物/无限行为**类关系适用（如「永远可观测」）；与 μ 对偶，**不得**用 μ 的实现替代 |
| **默认** | 无声明 | **CCR 只定义「所有满足这些 axioms/constraints 的模型」，即 `Models(T)`**，而不是强迫它拥有唯一 interpretation | 查询 = **约束求解**（可能多解 / 欠定）；**不得**悄悄取最小或最大不动点——那是把默认态偷换成 μ/ν |

原文对默认态的重要性（**逐字**）：

> 默认时 CCR 只定义"所有满足这些 axioms/constraints 的模型"，也就是 `Models(T)`，而不是强迫它拥有唯一 interpretation。**这一点非常重要。**

### 5.3 实现禁令（本文展开）

1. **禁止全局默认求 least fixed point**（原文点名的锁死风险）；
2. 禁止在默认态返回单一 interpretation 并**不声明**它只是「一个」模型；
3. 三态**互斥**：同一 relation 不得同时声明 `inductive;` 与 `coinductive;`（加载期 fail-closed，非语义歧义）；
4. **μ/ν 是 relation 的属性，不是 theory 的属性**——同一 theory 内可混存三态。

---

## 六、精化格：格在模型精化上（原文 §10）

- **定义（原文逐字）**：设 theory 为 `T`，它允许一组模型 `Models(T)`。新增关系、规则、constraint 后得到 `T'`。
  **如果 `Models(T') ⊆ Models(T)`，那么 `T ⊑ T'`**，意思是「`T'` 比 `T` 更精确」。
- **信息含义（原文逐字）**：「weak / unknown → more relations/constraints → more precise → fully sufficient for some consumer」「这就是格的真正信息含义。」
- **关键否定（原文逐字，本文强调）**：「**它跟 RAM / cache / register / GPU 没有任何关系。**」
- **[提案] 判据形状（本文展开）**：
  1. 偏序的**反对称性**只在「模型类相等」意义下成立——即 `T ⊑ T'` 且 `T' ⊑ T` ⇒ `Models(T) = Models(T')`（**不是**「同一个 theory 对象」）；
  2. 「更精确」是**可检验**的：给定一个**被 T 允许而被 T' 禁止**的模型见证，即可证 `T ⊏ T'`；反之需要全模型类的证明（一般不可判定 ⇒ 判据只能做**单向见证**，不能做全称判定）；
  3. **负向钉子**：把「更精确」实现成「事实更多」（语法计数）⇒ 判据红（两者不等价：加一条无用 fact 不改变模型类）。

---

## 七、least-informed / most-constrained（原文 §11）——**方向陷阱专节**

- **两端（原文逐字）**：完全无约束 `⊤_open`（允许所有 interpretation）；矛盾理论 `⊥_inconsistent`（没有任何模型，`Models(⊥)=∅`）。
- **原文的告诫（逐字）**：「不过命名最好注意 orientation。」「**我建议 V8 文档不要过早依赖 ⊤/⊥ 的视觉方向**，统一说 **least-informed / most-constrained**，避免数学 convention 搞乱。」

### 7.1 方向陷阱的形式化（本文展开——原文只给了告诫，这里给它算术）

按 §六 的偏序定义 `T ⊑ T' ⟺ Models(T') ⊆ Models(T)`：

| 端 | 模型类 | 在子集格（⊆）中的位置 | 在**精化序**（⊑）中的位置 |
|---|---|---|---|
| `⊤_open`（无约束） | 全部 interpretation | **最大** | **最小**（least-informed） |
| `⊥_inconsistent`（矛盾） | `∅` | **最小** | **最大**（most-constrained） |

⇒ **两套方向恰好相反**。原文的 `⊤`/`⊥` 命名按**模型集大小**取向（open = 全部 = ⊤），
而信息量按**精化序**取向（open = 信息最少 = 底）。原文说的「Unknown ↑ Refined ↑ … ↑ Contradiction」正是**后一套**。

**本文处置（依原文建议）**：

- 全文**不写** ⊤/⊥ 的视觉方向；一律写 **least-informed**（= open）与 **most-constrained**（= inconsistent）。
- 必须用符号时，写 **`⊑`-least** / **`⊑`-greatest** 并附「按精化序」限定语。
- **负向钉子（判据形状）**：文档中任何「⊤ = 信息最多」式的句子 ⇒ 视为方向错误，必须改为 least-informed/most-constrained 表述。

---

## 八、Relation 的局部代数（原文 §12）

- **动机（原文逐字）**：「这时才引入 Algebra，但不是全局要求。」
- **例（原文逐字）**：permission：`Empty < Read < Write`，可声明 `order(permission,…)` / `join(…)` / `meet(…)`；
  `coexists(x,y)` 可能只有 symmetric；`before` 有 transitive + irreflexive；某种资源 `compose(a,b)` 可能是 **partial composition**。
- **分层铁律（原文，排版即强调）**：

  ```
  Global CCR:     weak relational theory
  Local domain:   optional stronger algebra
  ```

  「**不能倒过来。**」
- **[提案] 判据形状（本文展开）**：
  1. 代数声明**只影响声明的那个 relation**，不得外溢（测试：给 `permission` 声明 `order` 后，另一个 relation 的性质查询仍全部「未声明」）；
  2. **partial composition** 必须有「无定义」返回值——不得伪造一个有定义的结果（对应 §二十一 反例 2）；
  3. **局部性强于全局**（可倒过来吗？**不能**）：即不得用「全局代数」去补全局部——机械判据 = 无全局 `join`/`meet` 符号。

---

## 九、高阶关系：支持，但不做完整 HOL（原文 §13）

- **需求（原文逐字）**：Core 以后肯定会需要 `preserves(mapping, relation)` / `refines(relationA, relationB)`，所以 **Relation 必须能够被引用**。
- **不做完整高阶逻辑（原文逐字）**：「我不建议 V8 直接变成完整高阶逻辑。」
- **机制（原文逐字）= reification**：

  ```
  relation R(a, b);
  @relation(R)
  ```

  把关系定义自身变成一个 symbol。于是可以 `preserves(map0, @relation(R))`，
  「仍然是一阶 relation `preserves(m,r)`，只不过 `r` 是"代表 Relation R 的 symbol"」。
- **收益（原文逐字）**：「这样表达能力很高，同时 Core kernel 不需要完整 higher-order unification。」
- **[提案] 判据形状（本文展开）**：
  1. `@relation(R)` 产出的 symbol 与普通 symbol **同等**（CCR-1 的开放符号面）——即 `preserves(m, r)` 里的 `r` **不特殊**；
  2. **负向钉子**：kernel 出现「relation 型参数」这种二阶类型构造 ⇒ 判据红（表示已越界到 HOL）；
  3. reification 必须**不改变**被引用 relation 的外延（引用 ≠ 重新定义）。

---

## 十、Theory 是模块单位，不是 Core 特权（原文 §14 / §15）

- **§14（见 §三 3.6）**：一切 `*Model` 都做成 Theory。
- **§15 无硬编码 relation namespace（原文逐字）**：「不能 `enum Theory { Memory, Time, Security, Execution }`，而应该 `theory foo.bar` **完全开放**。」
- **十年论证（原文逐字）**：「于是十年以后新增 `theory analog.signal` / `theory quantum.entanglement` / `theory distributed.consistency`，**V8 文件格式不变**。这才叫没有被现有范式封顶。」
- **[提案] 判据形状（本文展开）**：
  1. theory 名 = **开放点分字符串**（无白名单、无枚举）；
  2. 新增 theory 后 `CCR_VERSION` / 段集合 / 文件格式**零变化**；
  3. **负向钉子**：源码出现 theory 名枚举或内建 theory 表 ⇒ 判据红。

---

## 十一、Evidence 一等但可选（原文 §16）

- **来源（原文逐字）**：assertion / derivation / solver / external fact / mapping / proof。
- **语法形状（原文逐字）**：

  ```
  fact coexists(x,y) evidence proof42;
  derived reachable(a,b) via reachability_rule;
  ```

- **核心区分（原文逐字）**：区分 `Claim` 与 `VerifiedClaim`。
- **铁律（原文逐字）**：「**不能要求所有 relation 都有 proof**，否则 `.ccr` 又变成证明系统，而不是关系层。」
- **正确设计（原文逐字）**：`Relation Fact` 的 `evidence = optional`。具体 consumer 决定：
  heuristic accepted? / certificate required? / trusted assumption accepted?
- **[提案] 判据形状（本文展开）**：
  1. 无 evidence 的 fact **可加载**（不得 fail-closed）——**与 §十二 的 origin 强制形成对照**：**origin 必填，evidence 可选**；
  2. `Claim` vs `VerifiedClaim` 是**查询可分辨**的（consumer 能按需过滤）；
  3. **负向钉子**：把「无 proof」实现成「不可加载」 ⇒ 判据红（变成了证明系统）。

---

## 十二、Assumption 必须显式（原文 §17）

- **铁律（原文逐字）**：`assume deviceSupports(gpu0, fp64);` 和 `prove deviceSupports(gpu0, fp64);` **不能混**。
- **origin 分类（原文逐字，建议非常少）**：**given / derived / assumed / external** ——「不要硬编码几十种。然后 evidence 独立。」
- **[提案] 判据形状（本文展开）**：
  1. origin 值域 = 恰四值（枚举型计数 ⇒ 读作「**至少四值**」，若将来扩展须同批登记）；
  2. `assumed` 的 fact 在「要求证明」的 consumer 下**必须可被拒**（即 assumed 不得被当成 proven）；
  3. **负向钉子**：`assume` 与 `prove` 落到同一 origin 值 ⇒ 判据红；
  4. origin 与 evidence **正交**（`assumed` 也可有 evidence；`derived` 的 evidence = rule 出处）。

---

## 十三、Query 也是一等部分（原文 §18）

- **要求（原文逐字）**：「`.ccr` 不能要求 consumer 把整个关系宇宙展开。应该支持 projection」。
- **形状（原文逐字）**：

  ```
  query reachable(A, ?)
  query compatible(region0, ?domain)
  query { coexists(?x,?y) && located(?x,?r) && located(?y,?r) }
  ```

- **工程论断（原文逐字）**：「消费者只求自己需要的 fragment。也就是说 `𝓛` 可以无限，但 `Projection_Q(𝓛)` **通常有限**。**这才工程可行。**」
- **[提案] 判据形状（本文展开）**：
  1. 三种查询形态（单关系绑定 / 部分绑定 / 合取连接）**都能求**；
  2. 查询**不得**要求先物化全宇宙（机械判据：内存占用/时间与 `Projection_Q` 规模相关，与 `|𝓛|` 无关——`|𝓛|` 可能无限，故「与 `|𝓛|` 无关」本身就是可判定的强断言）；
  3. 未绑定位（`?`）的返回是**多解集**，不是一个「猜出来的」值。

---

## 十四、Incremental 只是实现，不进语义（原文 §19）

- **机制（原文逐字）**：增加事实 `T → T'` 时，只重新计算受影响 closure：`changed symbols ↓ dependent rules ↓ affected relations`。
- **明确边界（原文逐字）**：「因此依赖关系本身也应该可以被编译（Rule Dependency Graph）。**这个只是实现，不进 V8 语义。**」
- **[提案] 判据形状（本文展开）**：
  1. Rule Dependency Graph 是**可选**产物（不进 `.ccr` 语义面——否则会违反 CCR-8 的 N-4「可重建」测试，因为它会成为只有 `.ccr` 才有的信息）；
  2. 增量与全量**结果必须相同**（等价性判据，非性能判据）；
  3. **负向钉子**：把 RDG 写进 `.ccr` 语义段 ⇒ 判据红。

---

## 十五、冲突不能默认爆炸（原文 §20）

- **问题（原文逐字）**：`R(a)` 与 `¬R(a)` 同时出现时，classical logic 可推出任何东西。「这对 compiler relation store 是**灾难**。」
- **铁律（原文逐字）**：**局部矛盾不允许逻辑爆炸**。「至少在 relation database 层应该如此。」
- **四态（原文逐字）**：记录 positive evidence / negative evidence，得到 **unknown / positive / negative / conflict**，
  「即概念上类似 `{⊥,T,F,⊤}`」（注意：**类似**，不是同一个代数）。
- **边界（原文逐字）**：「但这里**不要强迫每个 domain 使用完整四值逻辑**。Core 最低保证只是：**conflict ≠ arbitrary truth**；冲突作为显式诊断/constraint failure 处理。」
- **动机（原文逐字）**：「这对多分析器合并非常重要。」
- **[提案] 判据形状（本文展开）**：见 CCR-7 的爆炸探测 + 信息状态四值闭合；另加：
  1. 冲突**必须可观测**（查询可区分 `unknown` 与 `conflict`）——静默合并 = 红；
  2. **不得**要求所有 domain 用四值（Core 只保证最低面）——故判据只测 kernel 的最小面，不测 domain。

---

## 十六、领域论域重建：Cache / Memory / Time / Execution 降为 Theory（原文 §21–§24）

> 原文的落点：**没有领域有特殊地位**。四节逐条转写如下。

### 16.1 Cache（原文 §21）

```
theory cache {
    relation producer(value, node);
    relation replayable(node);
    relation preserved(value, location);
    relation reconstructible(value);
    rule producer(v,n) && replayable(n) => reconstructible(v);
}
```

「是否可以 drop：`reconstructible(v) || exists l: preserved(v,l) => removable(currentRepresentation(v));`」
——原文逐字：**「这已经不是 CCR root semantics。」**
**架构隔离的兑现（原文逐字）**：「如果未来发现 Cache Theory 设计错了：**删掉 cache theory，V8 根本不动**。」

### 16.2 Memory（原文 §22）

「Classic memory 可以只是 `theory classic.memory`」——含 `byte(...)` / `offset(...)` / `contains(...)` / `permission(...)` / `address(...)`。
指针：`pointsTo(p,x)` / `offsetOf(p,n)` / `provenance(p,x)` **全部是 relation**。
原文否定（逐字）：「**并不意味着整个格是 memory lattice。**」

### 16.3 Time（原文 §23）

```
theory temporal {
    relation before(a,b);
    relation duration(a, interval);
    relation deadline(a,t);
}
```

规则 `before(a,b) ∧ before(b,c) ⇒ before(a,c)`；constraint `before(a,a) ⇒ invalid`。
「如果物理时间需要 interval arithmetic，再挂自己的 domain algebra。**CCR Core 不改。**」

### 16.4 Execution（原文 §24）

`requires(region, capability)` / `provides(domain, capability)` / `placed(region, domain)`；
规则 `requires(r,c) && placed(r,d) => require provides(d,c)`。
「具体 capability 怎么表示，也不是 CCR Core 的事情。它甚至可以以后换成 numeric ranges / sets / logical formulas。**核心不动。**」

---

## 十七、`.ccr` 文件的分节形状（原文 §25）

- **概念格式（原文逐字）**：

  ```
  ccr 8

  symbols { ... }
  relations { ... }
  facts { ... }
  rules { ... }
  constraints { ... }
  theories { ... }
  ```

- **可选节（原文逐字）**：`algebras { ... }` / `evidence { ... }`。
- **层界铁律（原文逐字）**：「但这里是序列化层，**不应该反过来定义语义**。」
- **§25 与 §2 的口径差（本文登记，不裁决）**：§25 的六节里出现了 **`facts`**（§三 的原语清单里没有它），
  而 **`terms` 无独立节**（Term 只在 facts/rules 内部出现）。两种读法都可自洽（facts = relation 应用的落盘单位；terms 是内联结构），
  但**原文未裁决** ⇒ §二十四 待裁。另注：首行 `ccr 8` 与 §二十二 A-1 的版本事实直接相关（见 §二十三 C-1）。

---

## 十八、最小 Kernel 与「设计失败」的判据（原文 §26）

- **Kernel 只需理解（原文逐字）**：**Term formation / Relation application / Substitution / Rule application / Constraint satisfaction / Theory composition / Evidence checking hook**（7 项）。
- **Kernel 不需要懂（原文逐字）**：cache / pointer / memory / GPU / time / precision。
- **失败条件（原文逐字，最强的一句）**：「**如果 Kernel 里出现这些词，V8 就设计失败了。**」
- **[提案] 判据形状（本文展开）**：
  1. 机械检查：kernel 源码对 `cache` / `pointer` / `memory` / `gpu` / `time` / `precision`（及其同义标识符）**零命中**——这是一条**可 grep 的**判据，也是 V8 「足够弱」的最强机械钉子。
     ⚠ **执行细则（本文展开）**：若按**子串** grep，`time`/`memory` 会大量误命中（`runtime`、`g_timer`、`memory.cr` 之类）⇒ 判据必须落成**标识符级**匹配（整词/声明位），否则这条判据会因假阳而**不可用**（本仓纪律：不可执行的判据等于没有判据）；
  2. Kernel 的公开面 ⊆ 上述 7 项（多一项即需登记理由）；
  3. **负向钉子**：kernel 里出现任一领域词 ⇒ 判据红。

---

## 十九、Theory Composition（原文 §27 / §28）

### 19.1 组合是并列，不是融合（原文 §27）

- 设 `T_memory` / `T_time` / `T_exec`，组合 `T = T_memory ∪ T_time ∪ T_exec`。
- **原文逐字**：「原则上它们**互不认识**。只有显式 bridge theory 才建立跨域关系」：

  ```
  theory gpu-time-bridge {
      executionCost(region, domain, duration)
      placed(r,d) && executionCost(r,d,t) => duration(r,t);
  }
  ```

- **禁止（原文逐字，加粗强调）**：「**不要让 temporal theory 内置 GPU 知识，也不要让 GPU theory 内置时间。跨域耦合由 Bridge Theory 专门解决。**」
- **收益（原文逐字）**：「这样复杂度才不会指数污染整个系统。」

### 19.2 组合原则（原文 §28）

- **形式（原文逐字）**：`T_A ⊕ T_B` **默认只是并列**。只有 `T_{A↔B}` 显式引入时才发生耦合。
- **结构（原文图，逐字转写）**：

  ```
  Memory
     │
     └── Memory↔Execution bridge
  Execution
     │
     └── Execution↔Time bridge
  Time
  ```

- **原文逐字结论**：「**这应该成为 V8 的核心工程原则之一。**」
- **[提案] 判据形状（本文展开）**：
  1. **无 bridge ⇒ 无耦合**（机械检查：`T_A ∪ T_B` 中，A 的规则 body 引用的 relation **全部**归属 A；跨域引用 = 红）；
  2. **耦合可定位**：任一跨域推导必须经过且仅经过显式 bridge theory（推导链可在 bridge 处被切断）；
  3. **负向钉子**：任一 theory 的声明里出现另一域的 relation 名 ⇒ 判据红（这正是「内置」的定义）。

---

## 二十、Mapping 不再是核心概念（原文 §29）

- **原文逐字**：之前一直试图找 `Mapping Model` / `Realization Model`，**现在都不需要**。
  Mapping 只是在关系空间里增加一组关系：`mapsTo(a,b)` / `locatedAt(x,d)` / `representedAs(x,r)` / `scheduledAt(e,t)`，对应 checker 验证它们。
- **原文结论（逐字，带加粗）**：

  > **Mapping 是 relation theory 的一个应用，不是 CCR 本体。**

  「**这一刀很重要。**」
- **[提案] 判据形状（本文展开）**：
  1. 机械检查：Core 无 `Mapping` / `Realization` / `Mapper` 型一等构造（零命中）；
  2. 「mapping 存在」本身是一个可查询的事实（relation），不是一种**构造**；
  3. **负向钉子**：出现 mapping 专用段/专用段位 ⇒ 判据红。
- ⚠ **与同批同伴的张力**：`execution-mapping-design.md` 把 Mapping 当作**一等层** `[已设计未实现]`。
  两者**直接对立**（一个是「非本体」，一个是「一等层」）⇒ 见 §二十三 C-4，**本文不裁决**。

---

## 二十一、验收标准（原文 §31）——**本节单独成节**

> 原文 §31 逐字（总纲）：「**不要看"能不能表达现在的功能"。要拿完全未知的东西测试。**」

### 21.1 主验收：全新的 domain（原文逐字）

一个全新的 domain：`theory weird.future.domain`。只要它能：
**定义 symbol / 定义 relation / 给规则 / 给 constraint / 可选自己的 algebra**，
就能进入 CCR，而 **CCR kernel、file format、HDFG 全部零修改**。那么 V8 才算成功。

**本文展开（关键读法，必读）**：句中的「file format 零修改」指**新 domain 入场时**零修改，
**不是**指 V8 的落地本身零修改——V8 落地**恰恰是一次格式与语义的重定义**（它取代 8 段表架构，见 §二十二/§二十三）。
把这两件事混读会把验收标准变成自相矛盾。**本条为本文展开，非原话。**

**可执行形状（本文展开，`[提案]`——当前无实现可跑）**：

| 步 | 动作 | 断言 |
|---|---|---|
| 1 | 写 `theory weird.future.domain { relation <任意名>(a,b,c); rule ...; constraint ...; relation <另一名>(x) inductive; }` | 语法接受（**该语法本身就是 `[提案]`**） |
| 2 | 加载该 `.ccr` | rc 正常 |
| 3 | 查询三类 query 形态 | 三种都可求 |
| 4 | 与入场前对比 | `CCR_VERSION` / 段集合 / `CCR_SEG_COUNT` / HDFG 字节 **全不变** |

### 21.2 三个反例测试（原文逐字点名）

原文：「另外三个重要反例测试：**无限递归关系 · 非格关系 · 相互矛盾的分析事实**。三者**都必须能表示**。
**如果其中任何一个要求 Core 加特殊 case，说明规则还是太强。**」

> ⚠ **本节全部为 `[提案]`**——三个测试**当前无实现可跑**，下面给的是**测试规格形状**（用什么 theory、断言什么），
> 以及**每条对应的「特殊 case 探测」**（原文的失败条件 = 要求 Core 加特殊 case）。

#### 反例 1：无限递归关系

- **用什么 theory**（最小递归 + 环）：

  ```
  theory t.reach {
      relation edge(x, y);
      relation reach(x, y) inductive;     // μ：闭包无界
      rule edge(x,y) => reach(x,y);
      rule reach(x,y) && edge(y,z) => reach(x,z);
  }
  ```

  fact 集：`edge(a,b)`, `edge(b,c)`, `edge(c,a)`（**成环**——这是「无限递归」的关键：迭代不终止的表象）。
- **断言什么**：
  1. `query reach(a, ?)` **终止**且返回有限集合 `{b, c, a}`（环不破坏 μ 的有限性——**这正是「不要求 Core 加深度上限」**的证明点）；
  2. **非回声输入**：`reach` 的**显式 fact 数为 0**，而查询返回 **3 个** ⇒ 结果只能来自规则推导，不是把输入 fact 回声一遍；
  3. `.ccr` **字节数与闭包规模无关**（CCR-4 的判据 1）。
- **特殊 case 探测（原文的失败条件）**：kernel 中**不得**出现递归深度常数 / 迭代上限 / `reach` 之类的名特判。
  **任一命中 ⇒ 原文判「规则还是太强」⇒ 判据红。**
- **加强版（本文补）**：把 fact 换成**非环但无界**的形式（`succ` 链：`p(0)`, `rule p(n) => p(succ(n))`）⇒ 查询必须允许**按需**取有限前缀，而**不得**尝试物化无限集（否则永不终止）。**该加强版把「无限指称 + 有限投影」（§十三）与 CCR-4 缝在一起，是比成环更强的钉子。**

#### 反例 2：非格关系

- **用什么 theory**（无任何代数性质 + 一个只有对称性的 + 一个偏运算）：

  ```
  theory t.chaos {
      relation likes(a, b);                    // 零代数：不 reflexive/symmetric/transitive/...
      relation coexists(x, y) algebra { symmetric; };
      relation compose(a, b) algebra { partial; };   // 部分合成：结果可能不存在
  }
  ```

- **断言什么**（**四条负向断言是本节的主体**）：
  1. `query symmetric(likes)` ⇒ **「未声明」**（不是 `false`，不是 `true`）——CCR-5；
  2. `likes(a,b)` 与 `likes(b,a)` **互不推出**（给一个，另一个仍是 `unknown`）；
  3. 对 `coexists` 声明 `symmetric` 后，**只有** `symmetric` 可查为真；`transitive` 仍「未声明」（**无外溢**，§八 判据 1）；
  4. `compose(a,b)` 无定义时必须返回**「无定义」**，**不得**伪造一个结果——**也不得**返回一个「⊥ 元素」冒充（§八 判据 2）。
- **特殊 case 探测**：Core 中**不得**存在「默认性质表」或按 relation **名字**推性质的启发式。
- **附加钉子（本文补）**：真正的「非格」含义 = **该 relation 不构成格**（join/meet 可能不存在）。
  故断言应包含：**对无 `join`/`meet` 声明的 relation 查询 join/meet ⇒ 返回「未声明」**，
  **不得**为它临时合成一个格结构（合成 = 偷偷注入了 universal algebra，违反 CCR-5）。

#### 反例 3：相互矛盾的分析事实

- **用什么 theory**（正向 + 负向证据并存）：

  ```
  theory t.conflict {
      relation located(x, r);
      relation p(a);
      // 无 constraint：冲突本身不非法（CCR-7：是否非法由 constraint 决定）
  }
  ```

  fact 集：`fact located(x, r1) evidence a1;` + `fact located(x, r2) evidence a2;`（**两个分析器给出互斥位置**）；
  以及最强形式：`fact p(a);` + `fact !p(a);`（原文 §20 的正负并存）。
- **断言什么**：
  1. **两者都被保留**（不得后写覆盖先写、不得静默取一）——信息状态 = `conflict`；
  2. **无爆炸**（本节最关键的一条）：在该冲突下 `query q(a)`（`q` 完全未涉及）⇒ 必须仍为 `unknown`；**变成 `true` ⇒ 红**；
  3. 冲突**可观测**：查询可区分 `unknown` 与 `conflict`；
  4. **加载本身成功**（无相应 constraint ⇒ 冲突不导致非法）——CCR-7 的「是否非法由 constraint 决定」；
  5. **变体**：加上 `constraint located(x,r1) && located(x,r2) => invalid;` 后，同样的输入 ⇒ **转为显式诊断/constraint failure**，
     且**仍然不爆炸**（失败是判定结果，不是任意真）。
- **特殊 case 探测**：Core 中不得为「冲突」加专用数据类型特判——四态是**信息状态**的最小面，不是新的原语。
- **多分析器动机（原文逐字）**：「这对多分析器合并非常重要」——故本测试应包含**两个来源**的冲突（不是同一来源自相矛盾）。

### 21.3 验收的三态与判据强度（本文补，方法论）

1. 三个反例**全部是 `[提案]`**——它们是**将来**的测试规格，**不得**被读成现有测试（现有测试见 §二十二 C）。
2. 每条判据都配了**负向钉子**（返回 `true` / 落 `false` / 爆炸 / 特殊 case 命中）——
   按本仓纪律：**单向判据对反向缺陷恒绿**，故每条必须有一个「本不该发生」的方向。
3. 三态纪律：三个反例当前**不可执行** ⇒ 计数上它们属 `[提案]`，其「可执行」本身是**将来**的交付物。

---

## 二十二、现状锚点实核（`develop@origin` @ `0eb1efd3`）

> 本节全部 `[已实现]`（逐条 `file:line`），且**全部是 V8 要替换掉的东西**。

### A. `ccr_io.cr` —— 版本、段集合、闸门

| # | 事实 | 锚点 |
|---|---|---|
| A-1 | **`CCR_VERSION = 9`**（现行真源） | `src/compiler/ccr_io.cr:135` |
| A-2 | `CCR_MAGIC = 827474755`（`"CCR1"` = `0x31524343`） | `src/compiler/ccr_io.cr:134` |
| A-3 | `CCR_SEG_COUNT = 8`；段名与规范序 = `STR SYM NOD ENT REG EDG TYPE IFACE`（tag 1..8） | `src/compiler/ccr_io.cr:138` |
| A-4 | `CCR_SEG_TYPE = 7` / `CCR_SEG_IFACE = 8`（数值权威 = 段序，D9） | `src/compiler/ccr_io.cr:139-140` |
| A-5 | header 16B 布局（写入侧）：magic / version / seg_count / reserved 四 u32 | `src/compiler/ccr_io.cr:570-573` |
| A-6 | 段表 12B × 8：`{tag, offset, size}`，规范序、段体紧随段表连续 | `src/compiler/ccr_io.cr:35-36`（注释形态）+ 写侧 `:586` 起 |
| A-7 | **load 版本闸**：`ver := buf_read_u32(...)` → `if ver != CCR_VERSION { return -1; }`（**严格等值，整类拒收**） | `src/compiler/ccr_io.cr:978-979` |
| A-8 | load magic 闸：`if magic != CCR_MAGIC { return -1; }` | `src/compiler/ccr_io.cr:974-975` |
| A-9 | 段表三闸：tag 域 `tg<1\|\|tg>CCR_SEG_COUNT` · 规范序 `tg != ri+1` · 连续 `soff != cursor` · 越界 `ssz > fsize-cursor` | `src/compiler/ccr_io.cr:1006-1009` |
| A-10 | 段必备集：`have1..have3,5,6`（STR/SYM/NOD/REG/EDG）**必备**；`have7,8`（TYPE/IFACE）**必备**；**ENT(have4) 可缺**（「旧段缺失 = 空」） | `src/compiler/ccr_io.cr:1030-1031` + `:1025`（注释） |
| A-11 | 记录尺寸常量：`ESZ_NOD_DISK = 40` · `ESZ_EDGE_DISK = 8` · `ESZ_SG_DISK = 24` · `ESZ_ENTRY_DISK = 28` · `ESZ_GLOBAL_DISK = 16` · `ESZ_FUNC_HEAD_DISK = 24` · `ESZ_VARDECL_DISK = 8` | `:150` · `:155` · `:162` · `:177` · `:169-171` |

### B. 谁读写 `.ccr`（段级消费者）

**写侧（corec，`save_ccr`）**：`fn save_ccr(path: string) -> int` = `src/compiler/ccr_io.cr:532`；逐段写点：

| 段 | 写点 | 来源（内存态） |
|---|---|---|
| STR | `ccr_io.cr:604` | 字符串池 |
| SYM | `ccr_io.cr:621`（globals）· `:636`（funcs）· `:697`（str_consts）· `:706`（structs）· `:724`（enums）· `:749`（opt_meta） | `g_ir_globals` / `g_ir_func_*` / 声明表 |
| NOD | `ccr_io.cr:768` | `g_ir_instrs`（坐标化） |
| ENT | `ccr_io.cr:793` | `g_ir_entries`（内核 `compute_live_ranges`） |
| REG | `ccr_io.cr:824` | `g_sgs` |
| EDG | `ccr_io.cr:883` | `g_df_edges`（按节点序单遍收集） |
| TYPE | `ccr_io.cr:896` | **缓冲搬运**：`g_ccr_type_seg`（内容构造 = `ccr_types.cr`，D18） |
| IFACE | `ccr_io.cr:910` | **缓冲搬运**：`g_ccr_iface_seg`（内容构造 = `ccr_types.cr`，D18） |

> 写侧**拒绝落盘**两次：TYPE 段未装填 `if g_ccr_type_seg_len <= 0 { return -1; }`（`ccr_io.cr:901`）、
> IFACE 段未装填（`:915`）——「不得产出两小节/五小节缺席的半成品」。

**读侧（corearch，`load_ccr`）**：`fn load_ccr(data: string, fsize: int) -> int` = `src/compiler/ccr_io.cr:968`；解析序与段消费点：

| 段 | 读点 | 重建目标 |
|---|---|---|
| STR | `ccr_io.cr:1061` | 串池（`g_strs`） |
| SYM | `ccr_io.cr:1085`（globals）· `:1113`（funcs）· `:1177`（str_consts）· `:1191`（structs）· `:1227`（enums）· `:1269`（opt_meta） | `g_ir_globals` / var 行序 / 函数七数组 |
| REG | `ccr_io.cr:1294` | `g_sgs`（nstart/ncount 由 enter/exit 派生）+ 函数指令边界回填 |
| NOD | `ccr_io.cr:1356` | 语义对象缓冲（28B 语义字段）+ 邻接域（**不写线性流**） |
| ENT | `ccr_io.cr:1413` | 内存 24B 表（去 version、live_end 半开转回闭区间） |
| EDG | `ccr_io.cr:1484` | 邻接连续段 + **拓扑不变量校验**（`to_nod > 所属节点`，规则 1） |
| TYPE | `ccr_io.cr:1534` | `g_types` / `g_type_terms` / `g_tt_index`；失败 = **整体拒绝**（「**不得**留空表」） |
| IFACE | `ccr_io.cr:1592` | `g_iface_entries` / `g_iface_shape_*` / `g_ifaces` / `g_impl_for` / `g_methods` |
| —— | `ccr_io.cr:1758` | **NOD 项索引一致性硬校验**（P6 T3 β；域外 / `atom_of(项) ≠ 盘上码` ⇒ 拒绝） |

**第三/第四消费者**：

| 消费者 | 锚点 | 角色 |
|---|---|---|
| `corearch`（concat 清单入口） | `src/compiler/corearch.cr:376`（`r := load_ccr(buf, fsize);`） | 后端主入口；load 成功后 `build_linear_schedule()`（`corearch.cr:410-413` 注 + `src/arch/x86_64/regalloc.cr:867`） |
| 组合根（project-mode 入口） | `src/targets/x86_64-linux/main.cr:64`（`load_ccr`）→ `:71`（`build_linear_schedule()`） | 自举 stage 链入口（该文件 `:5-19` 的双入口注记） |
| `ccr_types.cr` | `src/compiler/ccr_types.cr:1-8`（头注：corec-only，D18 解耦）· `:7`（读侧重建「在 `ccr_io.cr` 的 `load_ccr` 内」） | **只做内容构造**，按段表搬运缓冲 |
| `main.cr` | `src/compiler/main.cr:682`（`ccr` 分支 `ccr_seg_prepare_save`）· `:691`（`save_ccr(out)`）· `:717` · `:721`（`build` 分支 `save_ccr(ccr_path)`） | 写侧唯一调用点（两处） |

### C. 判据面现状

> 本表行号前缀 = **`J-`（判据锚点）**——与 §二十三 的 **`C-`（冲突登记）** 是**两个命名空间**，勿混。

| # | 事实 | 锚点 |
|---|---|---|
| J-1 | **`.ccr` 四条锁定值**（`canary_values.tsv` 数据行；另含 ELF canary 一条） | `tools/baseline/canary_values.tsv:180-184` |
| J-1a | `pa_ccr`（`tests/suite/ptr_arith.cr`，`ccr` 口径）= `d6ebe3d1…` / **96985 B** | `tools/baseline/canary_values.tsv:181` |
| J-1b | `pa_static_ccr`（`--static` 口径）= `041b6e3e…` / **97128 B** | `tools/baseline/canary_values.tsv:182` |
| J-1c | `gt_ccr`（`tests/suite/generics_test.cr`，`ccr` 口径）= `edfd8e98…` / **143687 B** | `tools/baseline/canary_values.tsv:183` |
| J-1d | `gt_static_ccr` = `bbfe4789…` / **143830 B** | `tools/baseline/canary_values.tsv:184` |
| J-2 | 锁定值表的**重锁前置**：重锁前必跑 `canary_check.sh` 并确认 D1 确定性闸门绿（同 canary ELF 两次构建逐字节相同）——否则会把非确定值锁进表 | `tools/baseline/canary_values.tsv:8-9` |
| J-3 | 口径：一律**冷态**（编译前 `clean-cache` = `rm -rf .core/cache/cir/`，相对 cwd）——**本会话实核位置 = `src/compiler/main.cr:415-421`**（TSV 原文写 `:408-414`，**已陈旧**，见 C-9）；cwd = 仓库根 | `tools/baseline/canary_values.tsv:11-13` |
| J-4 | 两口径差**恒 143B** 的根因 = `--static` 前置 `rt.cr`（⇒ 4 全局 + 1 串进 `.ccr`；STR +79B / SYM +64B） | 归因出处 `tools/baseline/canary_values.tsv:24-25`；**代码位置本会话实核 = `src/compiler/main.cr:440-448`**（TSV 原文写 `:433-437`，**已陈旧**，见 C-9） |
| J-5 | `tests/selfhost/test_ccr_v7.py`（**2204 行**）= v7/.ccr 结构族测试（段表/版本拒收/NOD 邻接/EDG 必落/ENT 实记录/roundtrip） | 文件头 `tests/selfhost/test_ccr_v7.py:1-60`；CI 挂点 `src/ci/run.sh:136` |
| J-6 | `tests/selfhost/test_ccr_types.py`（**2362 行**）= 段机制 + TYPE/IFACE 内容面；`run.sh` 注记**实测 49/49** | `src/ci/run.sh:137`（**本任务未复跑，按注记引**） |
| J-7 | 同族第三档：`tests/selfhost/test_region_cfg.py`（`.ccr`/`.cir` 区域结构 + **段表/版本断言**）——格式批的漏检面 | `src/ci/run.sh:199` |
| J-8 | `--dump-types` 通道（跨进程读回对拍）：写侧 `ccr_type_selftest_dump()` / 读侧 `ccr_type_surface_dump()` | `src/compiler/main.cr:250`（flag 注册）· `:689`（写侧）· `src/compiler/corearch.cr:309`（flag）· `:380-387`（读侧） |
| J-9 | 同族另两条读回通道 `--dump-ifaces` / `--dump-nod-items` | `src/compiler/corearch.cr:310` · `:398-403` |
| J-10 | 现行 `.ccr` 的**唯一 flags 字段**在 ENT 记录（位预算见 `materialization-space.md` §7.4） | `src/compiler/ccr_io.cr:76` · 语义注 `:85` |

### D. 既有文档中的三种设计原则（D1/D2/D3，**逐条原文**）

出处 = `docs/maintainer/design/existence-structure.md`「一、设计原则（v6 与 v5 的分野）」，**原文逐字**：

| # | 原文逐字 | 行 |
|---|---|---|
| **D1 图节点坐标** | 「**图节点坐标(D1)**：存在区间端点、region 边界、条目定值点全部以 NOD id（图节点序）为坐标——与 .cir（图形态）同坐标系，兑现"图 = 唯一真相层"。」 | `existence-structure.md:13` |
| **D2 执行序重建** | 「**执行序重建(D2)**：corearch 从 NOD + REG 重建线性投影——图节点文件序即合法拓扑序，重建 = 文件序直出 + region 边界标注，无排序成本。」 | `existence-structure.md:14` |
| **D3 共存不落盘** | 「**共存不落盘(D3)**：判定消费时从存在区间推导，sweep O(n log n)，不超线性、不冗余存储。」 | `existence-structure.md:15` |

同节另两条（原文逐字，与 V8 直接冲突）：

- `existence-structure.md:16`：「**v6-only**：不兼容 v5、无转换工具（.ccr 为管线中间产物，零持久生态）。」
- `existence-structure.md:17`：「**格层 vs 编码层**：ENT/NOD/REG 的语义（条目数学结构/版本/区间/共存）属**格层**，范式无关；字节宽/段表布局是编码层投影，可按编码空间调整。」

### D2. V8 与 D1/D2/D3 的替换关系（本文展开——**它们是 V8 要替换掉的东西**）

| 原则 | 现行角色 | V8 下的地位 |
|---|---|---|
| **D1 图节点坐标** | `.ccr` 全文件以 NOD id 为坐标；「图 = 唯一真相层」 | **保留其精神、失去其垄断**：坐标仍是 HDFG 侧的，但 `.ccr` 的语义面不再由坐标**承载**——符号/关系/规则/约束才是语义面；NOD id 退化为**一类 theory（`classic.memory` / 执行域）内的命名**，由该 theory 解释（§十六） |
| **D2 执行序重建** | corearch 从 NOD+REG 重建线性投影；「文件序即合法拓扑序」 | **降为一条规则/约束的实例**：调度合法性 = 一组 relation + constraint，不再由**段布局**保障；且重建本身是**查询**（§十三），不是「按段直读」（见 §二十三 C-2 的裁决） |
| **D3 共存不落盘** | 共存从存在区间 sweep 推导（对称、无传递性，「最弱理论——最多模型」） | **被吸收为 V8 的一条默认态 relation**：D3 的「不落盘 + 最弱理论」与 V8 的「无声明 = 默认态（最多模型）」**同构**——D3 事实上是 V8 §九 第三态的一个**特例**。V8 的增益 = 该原则**可被扩展**（可声明 `inductive` / 局部代数 / 显式 constraint），而 D3 是固定的 |

> ⚠ **替换的性质**：V8 **不否定** D1/D2/D3 的**技术内容**（它们描述的机制仍可作为某个 theory 的规则存在），
> 它否定的是**它们作为 `.ccr` 本体论的资格**——即「`.ccr` 是什么」不再由「图坐标 / 执行序投影 / 共存推导」定义。

---

## 二十三、冲突登记（**逐条列出 + 我的核实结论；不替维护者裁决**）

> 体例 = `execution-mapping-design.md` §十一。每条给：冲突内容 · 双方出处 · **我的核实结论**。

### C-1 ⚠ 最重要：**版本整数裁决（= 8）与现行 `CCR_VERSION = 9` 的碰撞**

- **维护者裁决（原文，已定）**：**版本整数 = 8**（不用 10）；用**「改进版加后缀」**区分；`.ccr` 零持久生态 ⇒ 旧 v8 文件的现实风险不存在。
  同一裁决附一条**硬约束**（**逐字**）：「⚠ 但 **判别式必须进"身份标识"（magic 或版本串）**，**不得只靠"结构不对会自然解析失败"自证**——D10 的教训正是"结构不对但闸门放行 ⇒ 静默当空表"。」
- **D10 教训原文（逐字，出处 `docs/superpowers/plans/2026-09-12-r2-p4-carrier.md:58`）**：

  > 「若留 7，则「v7 = 恰六段规范序」语义必须放宽为「6 或 8 段」，**旧 6 段文件会被新 corearch 静默接受**（TYPE/IFACE 缺席 = 空表）——正是三态纪律要消灭的静默类（C.5-3）。」

- **我的核实结论（重要，非裁决）**：
  1. **现行整数是 9，不是 8**（`ccr_io.cr:135`）。故「版本整数 = 8」在数值上是**从 9 回退**，不是「保持 8」。原文裁决的语境（「为什么整数不能用八 **退回**不就完事了」）与该事实**一致**——「退回」即指回退版本号。**此读法为本文展开，原文未逐字说明「从 9 退回」。**
  2. 若新格式写 `version = 8` 而闸门仍为**等值**判定，则**判别式的全部重量落在「后缀/身份标识」上**——这正是维护者附的那条硬约束，两者必须一起落地，**缺一即构成 D10 形态**（旧 v8 结构不对但闸门放行 ⇒ 静默当空表）。
  3. **「后缀」的编码形态未定**（u32 版本字段装不下字符串）⇒ §二十四 待裁第 1 项。可行方向（**本文仅列举，不推荐、不裁决**）：magic 变体（`"CCR1"` → 另一 4B 串）/ 版本字段打包（整数 + 后缀位段）/ 独立身份小节。**三者对 `canary_values.tsv` 的影响面不同（magic 变 ⇒ 全产物 `.ccr` 头部变），须在选定时一并评估。**
  4. **与既有文档的联动**：`materialization-space.md` §7.4 已立「承载方案与 `CCR_VERSION` **一并单独立项**」且实核「`CCR_VERSION` 现 `= 9`」——
     **V8 落地批必须与那条立项对齐**（两处不得各自定版本策略）。

### C-2 后端跟着变（**已裁决**）——`corearch` 从「按段直读」改为「查询/求解消费者」

- **原文（逐字）**：维护者答「后端也可以跟着变，反正就全改了」；任务书裁定为 **已裁决第 2 条**：「`corearch` 从"按段直读"改为**查询/求解消费者**。」
- **我的核实结论（现状锚点，支撑「全改」的代价判断）**：
  1. 现行 `corearch` 的消费面**确实是按段直读**：`load_ccr` 逐段解析并重建内存表（§二十二 B 全表），随后 `build_linear_schedule()` 从对象缓冲重建线性流（`corearch.cr:410-413`；`regalloc.cr:867`）；另有四条 `--dump-*` 读回通道**直接按段**打印（`corearch.cr:309/310/380-403`）。
  2. 故「改为查询消费者」**不是局部改造**：它触及 load 侧全部 8 段的重建语义 + 发射前的调度重建 + 四条调试通道。**原文的「反正就全改了」在此得到现状支持。**
  3. **但**：`CCR-8` 的 N-1（发射无关）要求发射路径**不得**依赖关系段。若后端改为「查询消费者」，**必须**划清「查询哪些段」——**发射所需的 NOD/REG/SYM/ENT 面**与**V8 关系面**是两回事。**这条边界未在原文展开** ⇒ §二十四 待裁第 2 项（后端查询的**范围界**）。

### C-3 与存在格层（ADR-0021 / `materialization-space.md`）的层归属

- **冲突内容**：`existence-structure.md:17`（原文逐字）把 **ENT/NOD/REG 的语义**（条目数学结构/版本/区间/共存）定为**「格层」**；ADR-0021 把格层本体定为**存在格**。
  而 V8 把「格」重新定义为**模型精化偏序**（§十），且明确「**它跟 RAM / cache / register / GPU 没有任何关系**」。
- **我的核实结论**：
  1. **两个「格」不是同一个数学对象**：存在格 = 载体侧的存在/物化结构；V8 精化格 = 理论侧的模型精化序。**二者可以共存，但不得同用一「格」字**（本文 §〇.1 已钉）。
  2. **真实冲突点**：`existence-structure.md` 把 ENT/NOD/REG 当作**范式无关的语义承载**；V8 把它们降为**某一 theory 的内部数据**。
     这是**层归属之争**，不是术语之争——**本文不裁决**，登记为 §二十四 待裁第 3 项。
  3. **共同点（可作为协调基础）**：`existence-structure.md:109`「共存 = 对称、无传递性（**最弱理论——最多模型**）」与 V8 的「默认态 = 最多模型」**用词同源**，说明两侧共享同一「弱理论」直觉。**这是两批可以对齐的接口。**

### C-4 ⚠ `execution-mapping-design.md`（同批）与 §二十九 的直接对立

- **冲突内容**：`execution-mapping-design.md` 的定位是「**异构 Execution Mapping 层**」`[已设计未实现]`（该档 §9.1–§9.3 专门论证「MAP 段的真实代价」与承载方案）；
  而 V8 原文 §29 逐字断言「**Mapping 是 relation theory 的一个应用，不是 CCR 本体**」。
- **我的核实结论**：
  1. 两者**在层归属上正相反**：一个把 Mapping 立为层，一个把它降为应用。**本文不裁决。**
  2. **但两者可以同时为真**（关键观察）：`execution-mapping-design.md` 的 Mapping 是**实现侧的一层工程组织**（谁算、放哪、什么代价）；
     V8 说的是**本体论地位**（Mapping 不进入 Core 语义面）。「工程上分层」与「本体上非核心」**不矛盾**——**若**两档同批接受此读法，则 C-4 可降级为**措辞冲突**。
     该读法**是我的展开，不是任一原话**；须由维护者确认或否决。⇒ §二十四 待裁第 4 项。
  3. **可机械检验的收窄判据**（若采纳上述读法）：**MAP 段不得被发射路径读取**（= CCR-8 的 N-1 同款判据）——这一条同时满足两档。

### C-5 档案「无格承诺」对 V8 局部代数的约束

- **冲突内容**：`docs/archive/memory-model-capability-lattice.md`（v4 定稿，archive）有「**无格承诺**」——格代数不进入语义本体，是映射实例的**组织参数**；
  而 V8 §12 允许 relation **显式声明** `order`/`join`/`meet`。
- **我的核实结论**：**表面冲突，实际相容**——「无格承诺」约束的是**不注入全局格**；V8 §12 的代数**恰恰是局部的、显式的、可缺席的**（「Global CCR: weak relational theory」）。
  即 V8 的局部代数**落在「无格承诺」允许的一侧**（组织参数、非本体）。**该相容性论证由 `execution-mapping-design.md` §十一 C-6 已建立过一次**（其对象是 Capability Lattice），本文与之同构。
  **登记而不动档案**（archive 文件不改）。

### C-6 `ccr_io.cr` 头注释与常量不一致（**已知陈旧**，核实并登记）

- **事实**：头注释多处仍写「v8 / version==8」，与常量 `CCR_VERSION = 9`（`:135`）及写侧 `:571` 冲突。**实核清单（9 处）**：

  | 类别 | 行 | 现写 | 应为 |
  |---|---|---|---|
  | 版本陈标 | `:5` | 「v8 format（…v8-only——load 校验 version==8…」 | v9 / `== 9` |
  | 版本陈标 | `:33` | 「`version u32 = 8`」 | `9` |
  | 版本陈标 | `:947` | 「Load（v8-only：…`version ≠ 8`」 | v9 / `≠ 9` |
  | 尺寸陈标 | `:12` | 「NOD 36B 邻接」 | 40B |
  | 尺寸陈标 | `:60` | 「`[×36B {op i32, dest i32, src1 i64,`」 | 40B（语义区 32B + 邻接 8B） |
  | 尺寸陈标 | `:501` | 「布局 = 盘 36B」 | 40B |
  | 尺寸陈标 | `:768` | 「NOD: instructions（36B each；…」 | 40B |
  | 尺寸陈标 | `:956` | 「NOD（36B——28B 语义字段…」 | 40B（32B 语义区） |
  | 尺寸陈标 | `:1356` | 「NOD: instructions（36B each）===」 | 40B |

- **我的核实结论**：
  1. **真源 = 常量与写侧，不是注释**（`CCR_VERSION` `:135` 与写侧 `:570-573` 一致；`ESZ_NOD_DISK = 40` `:150` 与 `:143` 的 32B 语义区注一致）。注释是陈迹。
  2. **危险度**：`ccr_io.cr:5`/`:947` 这两处**恰好说的是「load 版本闸」**——而 V8 的版本裁决（C-1）**正是要动这个闸**。
     任何读注释而不读常量的人，会拿到**错误的闸门语义**。**这正是 V8 落地批必须先刷新注释的理由**（读侧真源被陈标遮蔽）。
  3. **本文不动该文件**（任务约束：只新增一个文件）⇒ 登记，作为 V8 落地批的必做前置项。

### C-7 `ccr_types.cr` 头注的调用点行号已漂移（同类，附登记）

- **事实**：`src/compiler/ccr_types.cr:50` 写「save_ccr 两处调用点（`main.cr:612` `ccr` / `main.cr:636` `build`）」；
  实核现行行号 = **`main.cr:691`**（`ccr` 分支）与 **`main.cr:721`**（`build` 分支）。
- **我的核实结论**：性质同 C-6（注释陈迹），**危险度低**（引用的是调用点而非闸门语义）。登记，不改。

### C-8 `--dump-types` 等通道在 V8 下的存续未定

- **冲突内容**：现行四条 `--dump-*` 读回通道（`J-8`/`J-9` 锚点）**按段** dump 内容，是现行判据网的主体（`test_ccr_types.py` 的跨进程对拍依赖它们）。
  V8 若把语义面改为 symbols/relations/rules/constraints，**这些段的 dump 通道将无对象**。
- **我的核实结论**：**判据网与 V8 的关系没有被原文触及**。这是 V8 落地批的**漏检风险面**：新格式不能只带新语义，
  **必须同批给出新的读回通道**（否则 §二十一 的验收标准**无法机械化**——「能表示」需要可观测证据）。⇒ §二十四 待裁第 5 项。

### C-9 判据载体自身的**引用行号已陈旧**（本会话新发现，同类第三例）

- **冲突内容**：`tools/baseline/canary_values.tsv` 在注释里给出两条**代码位置引用**，本会话在 `develop@origin` 上**逐条实核，两者都已陈旧**：

  | TSV 原文引用 | 本会话实核（`develop@origin`） | 漂移 | 实核依据 |
  |---|---|---|---|
  | `src/compiler/main.cr:408-414`（clean-cache 口径） | **`:415-421`** | +7 | `main.cr:415` = `// === clean-cache: delete incremental compilation cache ===`；`:416` = `if cli_eq(cmd, "clean-cache") {`；`:417` = `system("rm -rf .core/cache/cir/");` |
  | `src/compiler/main.cr:433-437`（`--static` 前置 `rt.cr`） | **`:440-448`** | +7 | `main.cr:440` = `// --static: prepend rt.cr so * functions inline`；`:441` = `if cli_has("static") != 0 {`；`:447` = `g_source = rt_src + "\n" + g_source;` |

- **我的核实结论**：
  1. **性质属本仓已登记的一类**（「文档引用行号随代码漂移」——`existence-structure.md:135` 有同类校正先例，`ccr_types.cr:50` 的调用点行号亦已漂移，见 C-7）。**危险度中等**：
     TSV 引用的**值**（四条 `.ccr` 锁定值）不受影响，受影响的只是「配方出处」的可核查性。
  2. **对 V8 的直接意义**：本设计**主张 `.ccr` 判据网要大改**（C-8），故这些引用**即将再次失效**——**V8 落地批不应逐条修补旧引用，而应改为「锁定值 + 判据形状」分离**：
     值仍锁在 TSV，而**口径配方**（怎么跑）以**可执行脚本**承载（`canary_check.sh` 已有此形），
     使行号引用不再是判据成立的必要条件。
  3. **本文只登记，不改 `canary_values.tsv`**（任务约束：只新增一个文件）。

---

## 二十四、待裁（真正的未定项，**逐条列出，本文不替维护者裁决**）

| # | 待裁项 | 为什么未定（实测/原文缺） | 影响面 |
|---|---|---|---|
| 1 | **「改进版后缀」的编码形态** | 裁决只说「加后缀」；u32 版本字段装不下字符串。可行方向至少三种（magic 变体 / 版本字段打包 / 独立身份小节），**原文未选** | 决定 `CCR_MAGIC`/`CCR_VERSION` 的**类型**→ 决定 `.ccr` 头部字节 → 触发 `canary_values.tsv` 重锁 |
| 2 | **后端查询的范围界** | 已裁决「corearch 改为查询消费者」，但**发射所需的 NOD/REG/SYM/ENT 面**与 **V8 关系面**的边界未划（CCR-8 的 N-1 要求发射路径不依赖关系段） | 决定 corearch 改造的**最小面**（全改 vs 分层改） |
| 3 | **ENT/NOD/REG 在 V8 下的层归属** | 「存在格的语义承载」（`existence-structure.md:17`）vs「某一 theory 的内部数据」（V8 §十六）——两种归属**都自洽** | 决定 `existence-structure.md` / ADR-0002 / ADR-0021 的**地位如何变化**（见 §二十五） |
| 4 | **Mapping 的层归属**（C-4） | 同批两档直接对立；「工程分层 vs 本体非核心」的可调和读法**是我的展开，非原话** | 决定 `execution-mapping-design.md` 与 V8 的**共存方式** |
| 5 | **新格式的读回/判据通道** | 现行四条 `--dump-*` 通道以「段」为对象；新语义面下无对应物（`J-8`） | 决定 §二十一 验收标准**能否机械化** |
| 6 | **多结论规则（多头）** | 原文 Rule 形式一律单头 `⇒ Q`；**多头是否允许未定** | 影响 Rule 的字段级定义（§三 3.4） |
| 7 | **Constraint 结论值域** | 原文只出现 `⇒ invalid`；是否有第二/第三判定值（如 `warn`/`defer`）未定 | 影响 Constraint 的字段级定义（§三 3.5） |
| 8 | **`.ccr` 是文本还是二进制** | §25 给的是**概念格式**（`symbols { ... }`），原文未说落盘形态；而现行 `.ccr` 是二进制、现行 STR/SYM 池化编码与之无关 | 决定 V8 落地的**编码层全盘**（含是否保留段表） |
| 9 | **§25 的 `facts` 节 vs §2 原语清单** | §25 六节含 `facts`，§三 原语面含 Term 而无 `facts`；两种读法都自洽（§十七已给） | 影响文件分节与 Symbol/Term 的落盘方式 |
| 10 | **V8 与现行 v9 的切换方式** | 「全改」（原文）× 「零转换工具」（`existence-structure.md:16` 的既有原则）——**新旧是否同批切换、是否保留 v9 读路径**未定 | 决定切换批的规模与回退面 |

> ⚠ **本表读作「至少 10 项」**（枚举型计数纪律）。**表内各项互不依赖**，可分别裁决。

---

## 二十五、与既有文档的关系（**只登记与建议，不动那三份文件**）

> 任务约束：本节**只登记**，**不改**任何既有文件的正文。以下「建议」均为**建议**，不是已执行。

### 25.1 三份文件的地位变化

| 文件 | 现行地位（实核） | V8 下的地位变化 | 处置建议（**不执行**） |
|---|---|---|---|
| `docs/superpowers/specs/2026-09-09-lattice-ir-v7-format.md` | **现行字节权威**（其 §1 表把 v9 列为现行版本 `:24`；§4 规则 5 写「`version == 9`，`version ≠ 9` 整类拒收」`:184`）`[已实现]` | **被取代**：8 段表架构整体退役（V8 不承诺保留段表；§二十四 待裁 8 决定编码层去向）。**但 V8 未落地前它仍是字节真源**——本文不改写它 | V8 落地批同批新起字节 spec（文件名建议 `2026-09-22-lattice-ir-v8-<...>.md`），该 spec **头部追加**「已由 … 取代」标注，**正文保留**（本仓先例：ADR supersede 保留原文） |
| `docs/maintainer/design/existence-structure.md` | ENT/NOD/REG 的**语义承载**文档（`:17` 明写这三者的语义属**格层**，范式无关）`[已设计未实现]`（其 §三 末自注 flags 位「已预留未实现」） | **语义承载地位被取代**（V8 把三者降为 theory 内部数据——**若**采 §二十四 待裁 3 的该侧读法）；**字段/字节描述仍有效**（它们描述的是现行 v9 盘面） | **不删**。待 ADR 裁决后：或（甲）降为「历史承载描述 + 指向 V8」，或（乙）保留为「`classic.memory` 等 theory 的字段参考」。**两案都要求先裁 C-3** |
| `docs/maintainer/adr/adr-0002-ccr-v6-segment-table.md` | `accepted`（2026-09-05，决策者 DslsDZC）`[已实现]` | **被取代**：该 ADR 的决策内容就是「.ccr v6 段表架构 + ENT 存在结构段 + REG 坐标化」——V8 取代段表架构，故**必须 supersede** | 按 `docs/maintainer/adr/README.md` 的规则（**逐字**：「从 0001 起递增;新决策落地时追加,**不修改已 accepted 的历史记录**」「状态:accepted / **superseded by ADR-000N(被取代)——被取代的保留原文,新决策另起新号**」）⇒ **保留 ADR-0002 原文**，新起一号记录 V8 |

### 25.2 是否需要新 ADR ——**建议：需要，且不止一份可考虑**

- **建议（主）：新起一号 ADR**（按 README 索引，现行最大号 = **ADR-0022**，故建议 **ADR-0023**；**取号前须再核当天 `docs/maintainer/adr/` 现值**）
  —— 内容 = 「.ccr V8 = 开放关系理论（Open Relational Lattice）；段表架构退役」；状态 `accepted`；`supersedes ADR-0002`。
- **建议（次，须先裁）**：
  - `ADR-0020`（IR 双形态：`.cir` 图 / `.ccr` 格）——其「双形态」命题与 V8 **不冲突**（V8 换的是 `.ccr` 的**内涵**，不是「有两种形态」这件事），
    但 `.ccr` 的描述「格形态线性投影」会失准 ⇒ **建议仅追加状态注**（不 supersede）。**须先裁 §二十四 待裁 3。**
  - `ADR-0021`（存在格层定义）——与 V8 的关系取决于 C-3 的裁决。**本设计不预设两者冲突**（§二十三 C-3 已说明两个「格」是不同数学对象）。
- **不做的事**：本文**不写**任何 ADR 草稿、**不改** ADR README 索引（那会动已存在文件）。

### 25.3 与其他文档的联动登记

| 文档 | 联动点 | 性质 |
|---|---|---|
| `docs/maintainer/design/materialization-space.md` | §7.4 已立「承载方案与 `CCR_VERSION` 一并单独立项」，且实核 `CCR_VERSION 现 = 9` | **必须对齐**：V8 的版本策略（C-1）不得与该立项各自为政 |
| `docs/maintainer/design/execution-mapping-design.md` | 其「Mapping 一等层」 vs V8 §29「Mapping 非本体」 | **直接对立**（C-4），待裁 4 |
| `docs/academic/cache-semantics.md`（条款 1–7） | `existence-structure.md` 的条款权威；V8 §21 把 Cache 降为普通 theory | V8 下条款 1–7 的**适用范围**收窄为 `theory cache`（**不废除**）；**登记，不改** |
| `src/compiler/ccr_io.cr` 头注释 | C-6 的 9 处陈标（含 2 处直指版本闸） | V8 落地批的**必做前置**（否则读侧真源被陈标遮蔽） |

---

## 二十六、三态计数与自查

### 26.1 计数

> ⚠ **自指陷阱**（本仓既有纪律）：本节若把三态标记写成**字面方括号形态**，会被自己的 `grep` 计入 ⇒ 计数每次重数都变。
> 故本节内标记一律写作 `〔已实现〕` / `〔已设计未实现〕` / `〔提案〕`（**全角括号**，不匹配计数正则），**其余章节保留方括号形态**。
> 复现口径：`grep -o '\[已实现\]' <file> | wc -l`（方括号形态）。

> **读数纪律（先立，后取数）**：本表数字**全部由本会话实测**，复现命令逐条给出。
> 取数**在 §26.1 自身写成全角 `〔〕` 之后**执行——即**自述文字不进计数**（否则读数每改一次变一次）。

| 档 | A（内联标记出现次数） | B（清单行数，**权威口径**） | 说明 |
|---|---|---|---|
| 〔已实现〕 | **8** | **46** | B = §二十二 A/B/C 三表的**数据行**（每条带 `file:line`） |
| 〔已设计未实现〕 | **6** | 无成表清单（散落 6 处，见下） | B 档不适用——本档主张不集中在单一清单 |
| 〔提案〕 | **30** | 其余全部（**默认档**） | A 只数**显式写出**的标记；**未含**默认推断档 |

**复现命令**（`f` = 本文件；`A` 口径）：

```
grep -o '\[已实现\]'        $f | wc -l    # → 8
grep -o '\[已设计未实现\]'  $f | wc -l    # → 6
grep -o '\[提案\]'          $f | wc -l    # → 30
```

**B 口径（〔已实现〕= 46 的构成，可逐表核）**：§二十二 A 表 **11** 行（A-1…A-11）· B 写侧表 **8** 行 · B 读侧表 **9** 行 · B 消费者表 **4** 行 · C 表 **14** 行（C-1 + C-1a…C-1d + C-2…C-10）⇒ `11+8+9+4+14 = 46`。

**口径纪律（四条，缺任一条则数不可复现）**：

1. **A 含方法论自述，故 A 不是主张数**：A=8 中 **4 处不是主张**（前言「全文除显式标注…均无仓库对应物」· §〇 三态表的表头行 · §〇 后「本设计的特殊性」说明 · §二十二 节首「本节全部…」说明），**4 处是真主张**（§三 3.1/3.2 两处「现状对照」· §二十五 表两行「现行地位」）⇒ `4+4=8`。**A 只能当"标记用了多少次"，不能当"核了几件事"。**
   > ⚠ **本条自身有修订史**：初稿 A=10（含本行的自指标记），改写本行为内容指称后 A=9；§二十八 U-4 的措辞从「全仓 `grep` 无此语法『已实现』面」改为「作为原语的语法面不存在」后 A=**8**（该行不再含标记）。**读数随措辞变化，正说明 A 不是主张数**——这也是本表坚持「B 为权威」的实证理由。
   > ⚠ **按内容定位，不按行号定位**（本仓纪律：行号随编辑漂移，见 §二十三 C-6/C-7/C-9）——本清单因此**不含行号**。
   > ⚠ **本表曾有一个自指边**：初稿的本行含方括号标记 ⇒ 被自己的 `grep` 计入（读数 10）。改写为内容指称后，本行**不再含标记**，读数归 **9**。这类「说明计数的话自己被计数」的坑，本仓已在 `execution-mapping-design.md` §13.1 记录过同款。
2. **B 才是权威**（对〔已实现〕而言）：每条带 `file:line`，可逐条复核。
3. **`A < B` 是正常的**：清单行**本身不带标记**（只有事实文本 + 锚点）⇒ 一个主张可以只有清单行、没有行内标记。**不得据此认为漏标。**
4. **读作「至少 N」**：本文是**新文件**，无历史读数可对齐，本次为**首次读数**；按本仓纪律（枚举型计数随细看只会变多），三档一律读作「至少」。

**〔已设计未实现〕的 6 处分布**（无成表清单，逐处给）：§〇.1 术语护栏表 2 处（存在格 / Mapping 一等层）· §二十 与 §二十三 C-4 各 1 处（`execution-mapping-design.md`）· §二十五 表 1 处（`existence-structure.md`）· §〇 定义表 1 处（方法论自述，非主张）。

> ⚠ **时点**：以上读数为**本文件当前修订**的读数。本文若后续增删章节，**须重跑上列命令并同批改本表**（否则本表立刻变成陈旧锚点——本仓已有此类事故，见 §二十三 C-6/C-7）。

### 26.2 自查（逐条对任务要求）

| # | 要求 | 落点 | 状态 |
|---|---|---|---|
| 1 | 31 节全覆盖 | §二十七 覆盖表 | ✅ 逐节可查 |
| 2 | 八条公理显眼 + 每条三栏（形式/禁止/判据） | §二 | ✅ |
| 3 | CCR-8 的「不成为第二语义权威」证法 | §二 CCR-8 的 N-1…N-4 表 | ✅ |
| 4 | 五原语字段级 + Theory 组合（§14/§27/§28） | §三 + §十九 | ✅ |
| 5 | §8 Rule vs Constraint 独立成节 + 同事实两侧例子 | §四 | ✅ |
| 6 | §9 三态语法形状写死 | §五 | ✅ |
| 7 | §31 独立成节 + 三个反例各给最小可执行形状 | §二十一 | ✅（三例各带 theory + 断言 + 特殊 case 探测） |
| 8 | 三态标注（默认 `[提案]`，现状逐条 `file:line`） | §〇 + §二十二 | ✅ |
| 9 | 待裁逐条列，不替维护者裁决 | §二十四（10 项） | ✅ |
| 10 | 与既有文档的关系（取代矩阵 + ADR 建议） | §二十五 | ✅（只登记，未动那三份文件） |
| 11 | 已裁决两条写死 | §二十三 C-1 / C-2 | ✅（含与现状碰撞的核实） |
| 12 | 现状锚点在 `develop@origin` 上实核 | 全文 `file:line` 均基于 `0eb1efd3` | ✅ |
| 13 | 没能核实的锚点单列 | §二十八 | ✅ |

---

## 二十七、覆盖表：原文 31 节 → 本文章节（**机械可查**）

| 原文节 | 本文章节 | 原文节 | 本文章节 |
|---|---|---|---|
| §1 总结构 | §一 | §17 Assumption | §十二 |
| §2 不定义格里的对象 | §三（+3.0 计数登记） | §18 Query | §十三 |
| §3 Symbol | §三 3.1 | §19 Incremental | §十四 |
| §4 Term | §三 3.2 | §20 冲突不爆炸 | §十五 |
| §5 Relation | §三 3.3 | §21 Cache | §十六 16.1 |
| §6 不采用 Closed World | §二 CCR-3 | §22 Memory | §十六 16.2 |
| §7 Rule | §三 3.4 | §23 Time | §十六 16.3 |
| §8 Rule vs Constraint | **§四（独立成节）** | §24 Execution | §十六 16.4 |
| §9 μ/ν/默认 | **§五（独立成节）** | §25 六节文件形状 | §十七 |
| §10 格在模型精化上 | §六 | §26 最小 Kernel | §十八 |
| §11 ⊤/⊥ 方向 | **§七（方向陷阱专节）** | §27 Theory Composition | §十九 19.1 |
| §12 局部代数 | §八 | §28 组合原则 | §十九 19.2 |
| §13 高阶与 reification | §九 | §29 Mapping 非核心 | §二十 |
| §14 Theory 是模块 | §三 3.6 + §十 | §30 八条公理 | **§二** |
| §15 无硬编码 namespace | §十 | §31 验收标准 | **§二十一（独立成节）** |
| §16 Evidence | §十一 | 文末两处已裁决 | §二十三 C-1 / C-2 |

**未落表**：原文的抬头「核心一句话」与文末「所以 V8 最终不应该叫 …」定性段 → 本文标题 + §一（逐字引）。

---

## 二十八、未核实清单（**宁可交白卷也不猜**）

> 体例 = `execution-mapping-design.md` §十二。以下各项**本会话未核实**，**不得**被读成已核实。

| # | 未核实项 | 为什么没核 | 谁需要它 |
|---|---|---|---|
| U-1 | **「版本整数 = 8」是否意为从现行 9 回退** | 原文只有「为什么整数不能用八 **退回**不就完事了」——「退回」指「回退版本号」还是「退回该提问」，**原话歧义**；本文 §二十三 C-1 采取**回退**读法并已标为展开 | 裁决人；V8 落地批 |
| U-2 | **「改进版加后缀」的后缀具体形态** | 原文只有这一句，无任何形式说明 | 裁决人（§二十四 待裁 1） |
| U-3 | **V8 是文本还是二进制格式** | §25 只给「概念格式」，未说落盘形态（§二十四 待裁 8） | 编码层设计 |
| U-4 | **`theory` / `relation` / `rule` / `constraint` / `inductive` / `coinductive` 是否入 Core 语言语法** | 原文一律给**块形态**，未说这些是 `.ccr` 的内部语法还是 `.cr` 源语言关键字。**本会话实核**：`theory` 与 `inductive`/`coinductive` 在 `src/` + `grammar/` **零命中**；`constraint` 有 50 命中但**全是无关义**（数组长度约束 `array_len_constraint_*`、计划期的「Global Constraints」引用、边排序注释）⇒ **作为原语的语法面不存在**，但「零命中」不可对 `constraint` 一词整体断言 | 语法设计 |
| U-5 | **`query` 的消费接口形态** | 原文只给三种查询形状，未说消费者是 CLI 子命令 / 库调用 / 进程协议 | corearch 改造（C-2） |
| U-6 | **`@relation(R)` 的 `@` 前缀是否复用现行 `@` 内建位** | 现行 `@` 是内建派发（`T_AT = 70`，`src/compiler/ast.cr:76`）；V8 的 `@relation` 与之关系**未定** | 语法设计；本文不假设 |
| U-7 | **Rule Dependency Graph 是否需要独立落盘通道** | §19 明说「不进 V8 语义」，但**是否需要缓存/旁路**未说 | 增量实现 |
| U-8 | **四个反例测试的期望值** | 三种反例**当前无实现可跑**（§二十一 已标 `[提案]`）；本节列的是**规格**不是读数 | V8 落地批 |
| U-9 | **`canary_values.tsv` 在 V8 下的重锁策略** | 取决于 §二十四 待裁 1（后缀形态）与 8（文本/二进制）；**本文不给预测** | 判据网维护 |
| U-10 | **ADR-0023 的取号是否可用** | 本文实核 README 索引最大号 = ADR-0022，但**取号前须再核当天现值**（本仓多写手并发） | ADR 撰写者 |
| U-11 | **`existence-structure.md` / `materialization-space.md` 是否有本文未读到的 V8 相关预设** | 本会话只读了前者的全文（149 行）与后者的**目录 + §7.4**（未读全文 872 行） | 裁决人 |

---

## 二十九、定位与自我约束（原文文末定性）

原文逐字：

> 所以 V8 最终不应该叫 "Cache Semantics V2"，也不应该叫 "Existence Lattice"。我会直接定性为：
>
> **Core V8 — Open Relational Lattice**
>
> 最简数学描述：
>
> **CCR = finite presentation of an open relational theory**
> **[CCR] = a potentially unbounded family of relational models**
>
> 而 lattice 是对这些关系事实、约束和 refinement 进行组织的数学结构，**不是对内存、缓存或任何现有计算范式的承诺**。

原文结尾（逐字）：

> 这一版我认为已经足够弱，弱到未来加入什么并不重要；同时又足够强，能真正给 verifier、mapper、optimizer、backend 使用。
>
> **这个就作为 v8 吧。**

**本文的自我约束（展开）**：本文**不**为本设计添加任何原文之外的**承诺**。
凡本文补入的（判据形状、冲突登记、字段级定义），一律标「本文展开」且**默认 `[提案]`**；
凡涉及「仓库现在有什么」，一律给 `file:line`；凡未核实，一律进 §二十八。
**本文不含任何对 §二十四 待裁项的裁决。**
