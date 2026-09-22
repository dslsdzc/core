# Core V8 — Entity + Relation + Open Relation Domain + Optional Refinement Algebra

> **（标题已按 v2 换；文件名**不动**——改名会让已有引用悬空。变更依据与差分见 §〇。）**
>
> 定位：受众 = 维护者（`ccr_io` / `corearch` / verifier / mapper 实现者）；状态 = **设计定稿（未实现）· 第二版（v2）**
> ——全文除显式标注 `[已实现]` 处外，**均无仓库对应物**。
>
> 设计意图真源 = **一份**维护者 2026-09-22 会话口述输入（**逐字，本文不改写它**）：
> - `/tmp/briefs/ccr-v8-raw-v2.md` —— **第二版（本版真源，14 个标题 + 那张 19 行对照表）**。
>   它**取代** `/tmp/briefs/ccr-v8-raw.md`（第一版 31 节 + 八公理 + 验收标准 + 文末两处裁决）。
> - 第一版**不是废纸**：它是 v1 的记录，本档 §二 逐条登记「v1 里是什么 → v2 怎么处置 → 为什么 → 去了哪」。
>
> 本文 = v2 原文的**形式化展开 + 仓库锚定 + 与 v1 的差分登记 + 冲突登记**。
>
> **核验基线 = `0eb1efd3`**（`jj file show -r` 实读；**所有 `file:line` 以该修订为准，非手边检出**）。
> ⚠ **本修订（2026-09-23）已把基线换成当前 tip 复核**（本仓纪律：复核任何清单的第一步 = 把它的声明基线换成当前基线）：
> `develop@origin` 此后前进到 **`90d8a5cd`**（PR #163，**130 文件 / +5750 −1948**），
> 但本文锚定的 **14 个代码/CI/判据文件在两修订间逐字节相同**，2 处设计文档引用亦按新 tip 逐行重读、**落点不变**
> ⇒ **本文全部锚点在今日 tip 上仍成立**（实测见 §八.0 第 5 条）。**`0eb1efd3` 仍是 `develop@origin` 的祖先**。
> 本次另对**最承重的 16 组锚点做了抽样复核**，逐条见 §八.0。
>
> ⚠ **本修订含维护者 2026-09-23 的裁定**（四条 + 一条文字修正）——**变更源与落点见 §〇.6**；
> **凡本文其他章节与该节冲突，以 §〇.6 为准**。
>
> 读本文时须区分**四种声音**（v1 是三种，v2 多出第 ④）：
> ① **v2 原文**（维护者原话，带引号或标「v2 原文」）；
> ② **v1 原文**（维护者第一版原话——**只作差分对照用**，凡与 ① 冲突一律以 ① 为准）；
> ③ **本文展开**（写手的形式化/推导，标「展开」）；
> ④ **现状实核**（带 `file:line`）。
> **四者不得混读**——尤其不得把 ① 读成 ③，不得把 ③ 读成现状，**也不得把 ② 读成本版主张**。
>
> 关联（**本修订新增两条**）：
> - [coi-optimization-knowledge-sidecar.md](coi-optimization-knowledge-sidecar.md)
>   —— ⚠ **本修订新增（裁-4 的直接对象）**：`.coi` = **优化知识旁挂格式**，`[已设计未实现]`。
>   分工 = **`.ccr` = relation storage · `.coi` = optimization knowledge**。
>   **它对本档有两处实质影响**：① **C-2** 的「读 relations ≠ 执行 inference」由它加固；
>   ② **C-10 被它消解**（`opt_meta` 整节搬出 `.ccr` ⇒ 「同名不同物」不存在）——**该档 §〇.1 自己就这么写**。详见 §九 C-2/C-10 与 §十一.3。
> - [2026-09-22-ccr-v8-blast-radius.md](../../superpowers/specs/2026-09-22-ccr-v8-blast-radius.md)
>   —— **爆炸半径只读侦查（另一位写手，`develop@origin` 上还没有，按名引用）**。其对象 = **编码/承载层**（谁产谁读谁搬运、段级消费者矩阵、后端函数级清单、判据面作废清单、间接依赖）。
>   **本文与它的分工见 §十一.3**（本文管**语义面**，它管**承载面**）。⚠ 其标题仍写 v1 名「Open Relational Lattice」（见 §〇.0 命名说明）；⚠ **它引了本文 CCR-4 的旧措辞，须同步**（见 §〇.6 文修-1）。
> - [existence-structure.md](existence-structure.md) —— 被取代的 ENT/NOD/REG 语义承载（见 §九 C-3）
> - [materialization-space.md](materialization-space.md) —— 存在格层定义（ADR-0021）——**与 V8 的关系见 §九 C-3**
> - [execution-mapping-design.md](execution-mapping-design.md) —— **同批同伴**：其「Mapping 是一等层」与本文 §二「Mapping 非本体（v2 保留 v1 结论）」的张力见 §九 C-4
> - [2026-09-09-lattice-ir-v7-format.md](../../superpowers/specs/2026-09-09-lattice-ir-v7-format.md) —— 现行字节权威（段表架构）——**V8 取代它（承载面去向见 §十 待裁）**
> - [adr-0002-ccr-v6-segment-table.md](../adr/adr-0002-ccr-v6-segment-table.md) —— v6 段表架构决策（accepted）——**V8 需要新 ADR supersede（建议，不裁决，见 §十一.2）**

---

## 〇、本次修订（v2 + 2026-09-23 裁定）的元信息

### 〇.0 标题变更与文件名不动（**本文展开 + 依据**）

- **文件名不动**：仍是 `docs/maintainer/design/ccr-v8-open-relational-lattice.md`。理由（任务约束，**非 v2 原文**）：改名会让已有引用悬空。
- **标题已换**为 `Core V8 — Entity + Relation + Open Relation Domain + Optional Refinement Algebra`
  —— 这**正是 v2 原文的定性句**（逐字）：
  > **Entity + Relation + Open Relation Domain + Optional Refinement Algebra**
  >
  > **只有四件事。**
- **为什么旧名必须换**（**本文展开，非原话**）：旧名 `Open Relational Lattice` 的核心词是 **Lattice**，
  而 v2 明确把「全局完备格」列为**「这是目前最危险的过度承诺」并删除**（§二 表末行）。
  名字若不动，**标题会比内容承诺更多**——这正是 v2 要收掉的那类过度承诺。
- ⚠ **连带事实（登记，不处置）**：`docs/superpowers/specs/2026-09-22-ccr-v8-blast-radius.md` 的标题仍写旧名
  （「`.ccr` → V8（Open Relational Lattice）爆炸半径侦查」）。**本文不改他人产物**；其标题是否随改，由该档作者/维护者定。

### 〇.1 v1 → v2 的一句话差分（**本文展开**）

v1 的核心一句话是「`.ccr` 是一个**有限的关系理论描述**；它定义的关系空间、模型空间和格都可以是无限的」——
一个**理论**（theory-first）。v2 的核心一句话是
「**以足够弱、开放的结构表达 HDFG 及其分析/映射产生的关系**」（v2 原文）——一份**关系记录**（relation-first）。

由此产生的**结构性**差分（不是条目删减，是**本体换向**）：

| 维度 | v1 | v2 |
|---|---|---|
| Core 的**性质** | 一套**开放关系理论**（含 Rule / Constraint / Theory / μν / 四值 / Query / Bridge） | **四件事**：Entity + Relation + Open Relation Domain + Optional Refinement Algebra |
| 增长方式 | 靠**规则**生成无限闭包（「有限规则可以生成无限结构」）**（v1 主张，已删——裁-2）** | 靠**开放的关系域**：**open-ended**（**外延开放**）——relation / domain / entity 均可扩展，Core 不封顶（v2 原话：「开放 relation universe 本身已经足够不封顶」）。⚠ **不是** internally infinite（裁-2） |
| 数学承诺 | 模型类 + 精化格 + ⊤/⊥ 两端 + 四值信息状态 | **最多**：per-domain preorder / partial order + **可选** join；`⊤`/`⊥` **Core 都不要求** |
| 谁求值 | **CCR 内**（Rule ⇒ 闭包，μ/ν 硬编码） | **CCR 外**（analyzer / spec / compiler；「**CCR stores relations, not inference programs**」） |
| 文件面 | 六节（symbols/relations/**facts/rules/constraints/theories**） | 四面（Entities / Relation Domains / Relations / **Relation Metadata**） |
| 定位定名 | `Core V8 — Open Relational Lattice` | `Entity + Relation + Open Relation Domain + Optional Refinement Algebra` |

> ⚠ **v2 原文的一句自我警告，本文原样转写**（它是本版的验收心态）：
> 「这版比我们前面那个 V8 小了差不多一半，但实际表达能力我认为基本没损失；反而 verifier、compiler 和文件格式都会更容易真正做出来。」

### 〇.2 v1 记录在哪里（**不重写历史**）

本档的**父修订**即 v1 全文（1234 行、标题 `Core V8 — Open Relational Lattice`）。读法：

```bash
jj file show -r <v1 修订> docs/maintainer/design/ccr-v8-open-relational-lattice.md
```

- **v1 修订的定位方式（按内容，不按 id）**：本文件的**父修订**，特征 = 标题为 `# Core V8 — Open Relational Lattice`、
  含 `## 二、八条公理（CCR-1 … CCR-8）——本设计的根` 一节、共 **1234** 行。
  > ⚠ 本仓纪律：**commit id 每次重写都会变、且旧 id 可能被复用解析到别的对象** ⇒ 引用历史修订时**给出内容特征**，
  > 不要只给一个裸 id（本文因此不把 id 写死在这里；`jj log` 现查现用）。
- **为什么保留而不改写**（任务约束）：**v1 是 v1 的记录**。本文不是在 v1 上打补丁，是**换了一版**；
  两者都要能各自被读到，否则「v2 砍了什么」将无从对照。

### 〇.3 三态标注约定（**沿用 v1，全文强制**）

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
> **绝不出现在任何描述 V8 本身的句子上**。三态计数见 §十二。

> 🔴 **本版最容易被混读的一句（v2 原文逐字，加粗是原文的）——先钉在这里，展开见 §四**：
>
> > **Unknown 是 CCR 的信息状态，不等于 relation domain 的数学 ⊥。**
>
> v1 把「unknown」放在一个**四值信息状态** `{⊥,T,F,⊤}` 里（v1 §20）；
> v2 **删掉四值**，同时**保留**「缺失事实 = unknown」。两版都出现「unknown」这个词，
> **但 v2 的 unknown 是「CCR 没说」，不是「domain 的底元素」**。混读会导致「为了方便实现，反过来限制数学空间」——
> 而这正是 v2 原文点名要避免的事。

### 〇.4 术语护栏（**v2 重写：七处易混**）

> v1 此表有四行（Lattice / Theory / Algebra / Mapping）。v2 的删除与改名使其中三行的**义项本身变了**，
> 并新增三行（EntityRef / RelationDomain / metadata）。逐行重写如下。

| 词 | **本文档（v2）的义** | 仓库既有文档/代码的义 | 处置 |
|---|---|---|---|
| **EntityRef** | V8 的**稳定身份**（= v1 的 Symbol，**改名**）。「CCR 不理解这些是什么。它只保证：**同一个 ID = 同一个被引用对象**」 | 无此概念。**本会话实核**：`EntityRef` / `entity_ref` 在 `src/` **零命中** | 本文一律写 **EntityRef**；提 v1 时注明「v1 称 Symbol」 |
| **Entity tag**（`hdfg.value` / `target.register` / `foo.bar.whatever`） | **开放点分提示**——v2 原文：作为「**工具提示**，而不是 Core ontology」 | 无 | ⚠ **不得**读成类型系统或 kind 枚举：v2 明说「甚至 EntityKind 都不要封闭枚举」 |
| **RelationDomain** | V8 的**关系域**：`id · version · arity · argument_shape · value_shape · optional refinement/merge` | 无。**本会话实核**：`RelationDomain` / `relation_domain` 在 `src/` **零命中** | ⚠⚠ **与 `execution-mapping-design.md` 的「执行域」不是一回事**（该档「执行域」**14 处**，指计算→执行域放置，如 `gpu0`）——两者都叫「域」，**不得混读** |
| **格 / Lattice** | **v2 下不再是 Core 要求**。Core 最多要求 per-domain **preorder / partial order**；`⊤`/`⊥` **都不要求**（§三 3.4） | ① **存在格**（`materialization-space.md` / ADR-0021）`[已设计未实现]`；② **能力格**（`memory-model-capability-lattice.md`，archive） | 本文**不写「格」作 Core 承诺**；一律写「**refinement 偏序**」。指既有义时写全称「存在格」/「能力格」。⚠ v1 的「**精化格**」（定义域 = `Models(T)`）在 v2 下**作废**，见 §二 2.2 |
| **Theory** | **降级为模块/包**：v2 原文「就类似 **namespace + schema bundle + tooling hooks**」——**不是核心语义对象** | 无此概念。**本会话实核**：`\btheory\b` 在 `src/compiler/` + `grammar/` = **0 行**（与 v1 同结论） | 本文写「模块/包」；`theory` 关键字**是否入语法**见 §十四 U-4（v2 未提） |
| **metadata** | V8 的 relation 元数据（`producer` / `epoch` / `evidence_ref`），**不进 relation 的数学含义** | ⚠ **同名不同物**：现行 `g_opt_meta`（`.ccr v3+` 优化元数据缓冲、SYM 段第 6 子节）`[已实现]`（§八 A/B 表） | **不得读成一个**：现行 opt_meta 是**编译器优化参数**，V8 metadata 是**关系溯源**。登记见 §九 C-10 |
| **Unknown / ⊥** | **两个不同的东西**：前者 = CCR 的**信息状态**（没说过）；后者 = **数学 domain 的底元素**（如果有） | 无 | §四 专节钉死 |

### 〇.5 记法约定（沿用 v1，两处随 v2 更新）

- `E` / `D` / `R` = v2 的三元组记法：`CCR = (E, D, R)`（原文引入，§三 3.0）。
- ⚠ **v1 记号 `T`（theory）/ `Models(T)` / `𝓛(G, CCR)` / `Projection_Q(𝓛)` 在 v2 下不再是 Core 记号**——
  它们随「Theory 降级 / Query 移出」一并出 Core（§二）。本文**仅在引述 v1 时**出现这些记号，并逐处标明。
- `.ccr` = 盘上字节；**落盘形态（文本 or 二进制）v2 未定**，与 v1 同（§十 待裁 8）。
- 语法块一律用 ` ``` ` 包裹；**现行语法**与**设计语法**在块首行注明（本设计全部为后者）。

### 〇.6 本修订（2026-09-23）：四条裁定 + 一条文字修正（**维护者已裁，全文据此改**）

> 本节是本修订的**变更源**。逐条给**原文 · 语义 · 落点 · 影响面**；
> **凡本文其他章节与本节的措辞冲突，以本节为准**（这是一次**解冻后**的裁定批，不是新提议）。

#### 裁-1　`checker` = 外部工具钩子（**定死**）

**原文（逐字）**：

> `checker = <external checker identity>`
> Core 只知道「**这个 relation domain 的额外合法性检查交给谁**」，**不把 checker 本身变成 CCR 的逻辑语言**。

- **显式排除**：`checker` **不是可求值声明**。
- ⚠ **防误读句（原文要求加上）**：**名字以后可以考虑叫 `checkerRef` / `validatorRef`**——
  防止实现者理解成「Core 要执行它」。
- **理由（原文要求写明，逐字）**：**一旦 Core 需要理解/执行 checker 的内部逻辑，
  Constraint、Rule、推理语义就会从侧门重新回来。**
- **落点**：§五 5.2（原「本文按工具钩子读（非原话）」的**悬置段 → 改为定案**）· §十 待裁 **新-10 已裁决** ·
  §七.3（**新增一条 v2 反例**）· §二 2.1 **#7**（Constraint 的「去处 = domain checker」由此获得**确定性**：
  去向是**外部** checker，**不是 Core 的一部分**）。

#### 裁-2　CCR-4 选 **(乙)**：删掉 v1 那条旧承诺

- **删的是什么**：v1 的「**有限文件表示无限结构**」（`0 / succ(0) / succ(succ(0)) …`）——
  它随 **自由项代数**（§二 2.1 #2）与 **规则闭包**（#6）一起没了，**不再宣称**。
- **v2 真正成立的（原文逐字）**：

  > **`.ccr` 本身有限，但 relation universe 是开放的**——Core 不封顶 relation / domain / entity 的扩展。

- ⚠ **两个「无限」不能混着写（原文点名）**：
  这是 **open-ended**（**外延开放**），**不是** v1 意义上的 **internally infinite**（**内部指称无限**）。
- **落点**：§二 2.2 **S-1d**（整行重写）· **S-2**（连带改写）· §五 标题与 5.1 · §六 6.3（补句）·
  §十 待裁 **新-9 已裁决**。

#### 裁-3　v1 三个反例：**继承一条、退休两条，并另设 v2 反例**

- **无限递归关系** ⇒ **退休**（**不再是 CCR 必须内部表达的对象**）；
- **非格关系** ⇒ **退休**（**本来就已经合法，不再构成压力测试**）；
- **保留**：`relation(A)` 与一个矛盾事实**可以共存**，**CCR 不自行推出任何东西、也不发生逻辑爆炸**。
  它测的是：

  > **CCR stores relations, not truth closure.**

- ⚠ **写法（原文点名）**：是「**退休两条 + 保留一条 + 另设 v2 测试**」——
  **不是**「v2 以后只剩一个反例」。退休的两条**要留痕**（写明**为什么失去测试力**），**别静默删**。
- **落点**：§七.2（重写：退休两条各带留痕 + 保留条改述）· §七.3（**另设的 v2 反例**）·
  §十 待裁 **新-11 已裁决**。

#### 裁-4　两项附带裁决**沿用**（v1 澄清的两条**未被撤销**）

- **版本**：`V8` / `V8.x` / `V8-<suffix>`；**magic/version 必须显式进入格式身份**——
  **不许靠「解析失败大概就不是这个版本」**（这是**文件格式工程**）。
- **后端**：**读 relations ≠ 执行 CCR inference**。这条**现在比 v1 更重要**——
  **`.coi` 刚拆出去**（`.ccr` = relation storage，`.coi` = optimization knowledge），
  **更没有理由让 CCR reader 偷偷演变成推理机**。
- **落点**：§九 **C-1**（版本：命名形态定死 + 显式身份硬约束）· **C-2**（后端 + `.coi` 分工）·
  §十 待裁 **1**（收窄：命名已定，编码落点未定）· §十一.3（`.coi` 联动登记）· §十四 **U-12**（已裁决：两条均沿用）。

#### 文修-1　⚠ 文字修正（**全文贯彻**）：不要再说 `.ccr`「表示无限结构」

**原文（逐字；作为本档此后唯一合法的该义表述）**：

> **`.ccr` stores a finite set of relations in an open, extensible relational universe.**

- **要求**：全文搜一遍「无限 / unbounded / infinite」的用法，**凡指 `.ccr` 自身能力的，按上面这句改**。
- **清点结果**：见 §〇.7（逐处给「保留 / 改写」与理由）。
- ⚠ **连带**：`docs/superpowers/specs/2026-09-22-ccr-v8-blast-radius.md`（爆炸半径档）**引了本文 CCR-4 的措辞**
  ⇒ **改完须告知该档作者同步**。本文已把新表述固化在本节与 §二 S-1d，**供其直接引用**。

### 〇.7 「无限 / 无界 / unbounded / infinite」全文清点（**文修-1 的落实记录**）

> **先定规则、后取数**（本仓纪律）。规则 = 「凡把『无限 / 无界 / 不封顶』**归给 `.ccr` 自身能力**的句子 ⇒ 改写」；
> 以下两类**保留**：**① v1/v2 原文引用**（它们描述的是**当时的主张**，改了就是篡改引文）；
> **② 数学 domain 自身的性质**（如 `D = ℕ` 无最大元——**domain 的无界 ≠ `.ccr` 的指称无界**，恰是裁-2 要区分的那对）。

| # | 处 | 原文（节选） | 判定 | 处置 |
|---|---|---|---|---|
| 1 | §〇.1 差分表「增长方式」行（v2 侧） | 「靠**开放的关系域**不封顶」 | ⚠ **改写** | 改为「**open-ended**（外延开放）：relation / domain / entity 均可扩展，Core 不封顶」 |
| 2 | §〇.1 差分表「增长方式」行（v1 侧） | 「靠**规则**生成无限闭包（「有限规则可以生成无限结构」）」 | **保留**（**v1 引文**） | 加 `（v1 主张，已删）` 标记 |
| 3 | §二 2.2 **S-1d** | CCR-4 行 | ⚠ **整行重写** | 见 裁-2。英文原名 `Unbounded Denotation` **保留为历史名**，但其**承诺已删** |
| 4 | §二 2.2 **S-2** | 「有限 presentation，指称可无限」 | **保留**（**v1 引文**） | 处置栏改为「**v1 旧承诺，已删**（裁-2）」 |
| 5 | §二 2.1 **#2** | 「有限 CCR 描述无限 term universe」 | **保留**（**v1 引文**） | 不动——**它正是被删那条主张的原文出处** |
| 6 | §三 3.2 | 「开放 relation universe 本身已经足够不封顶」 | **保留**（**v2 原话**） | 不动——**原话逐字**，且其义 = **open-ended**（与裁-2 一致） |
| 7 | §三 3.4 · §十二 自查 | 「无界域必须能声明」·「`D = ℕ` 无最大元」 | **保留**（**数学 domain 的性质**） | 不动——**domain 的**无界 |
| 8 | §五 标题 + 5.1 | 「v2 保留的『不封顶』及其边界」 | ⚠ **改写** | 标题改「**open-ended**：v2 保留的『外延开放』及其边界」 |
| 9 | §六 6.3 | 「v1 尚可用『`.ccr` 是有限呈现、指称无界』来解释落差」 | ⚠ **补一句** | 补：**v2 已删除该承诺（裁-2）** ⇒ 落差只能由「CCR 是关系的**一处记录**、不是关系总和」承担 |
| 10 | §七.2 | 反例名「无限递归关系」 | **保留**（**v1 反例名**） | 该反例**已退休**（裁-3），**留痕见 §七.2** |
| 11 | §十五 | v1 定性句引文（`potentially unbounded family of relational models`） | **保留**（**v1 引文**，已标注「已由 v2 取代」） | 不动 |

**合计**：清点 **11 处** ⇒ **改写 4 处**（#1 / #3 / #8 / #9）· **保留 7 处**（其中 **5 处是对原文的引用**、**2 处是数学 domain 的性质**）。
⇒ **无一处**把「无限 / 无界」**作为 `.ccr` 自身能力**保留下来——**符合文修-1**。

---

## 一、工程目标：`.ccr` 必须做到的，与明确不属于它的（**v2 原文首节**）

### 1.1 一句话目标（**v2 原文逐字**）

> **以足够弱、开放的结构表达 HDFG 及其分析/映射产生的关系**

### 1.2 五条满足条件（**v2 原文逐字，本文只加编号**）

并满足：

1. **能合并**
2. **能查询**
3. **能验证结构合法性**
4. **能被不同 consumer 消费**
5. **不封死未来 relation domain**

### 1.3 明确**不属于** CCR 的五件事（**v2 原文逐字**）

> 至于：怎么推导关系 · 怎么证明关系 · 怎么求 fixed point · 怎么尝试 mapping · 怎么表达假设 —— **不一定是 CCR 的工作**。

**本文展开（把这句读成工作量表）**：这五件事**不是被否定**，而是被**指派**——
它们的实现者分别是 analyzer（推导/fixed point）、Spec/CSR（证明）、mapper（mapping）、规约上下文（假设）。
CCR 对它们的义务只剩一条：**把结果装得下**（见 §二 2.4「去处」栏）。

### 1.4 反目标：不要做成「第四门通用逻辑语言」（**v2 原文，本文加节**）

v2 原文点名了它要避免的错误——为了做到「什么都能表达」，最后做成：

```
symbols / terms / relations / rules / constraints / fixed points /
higher order / proofs / queries / contexts / modules / algebra / …
```

> 那实际上是在 Core 里面重新实现**一门通用逻辑语言**。

v2 原文给出的理由（**逐字**）：

> 完全没必要。Core 已经有：
>
> ```
> HDFG   —— 程序语义
> Spec   —— 命题与证明
> Core   —— 通用编程
> ```
>
> **CCR 再成为第四门完整语言是非常糟糕的工程选择。**

**本文展开**：§一.4 是本版的**总闸门**——它比 v1 的任何一条公理都强，因为它是**否证式**的：
新增任何概念时，只要该概念让 CCR 更像一门语言（而不是一份记录），即触发本闸门。
v1 的 §十八「**如果 Kernel 里出现这些词，V8 就设计失败了**」是同一闸门的一个特例；v2 把它提到**设计目标**层。

---

## 二、**删除了什么、为什么**（v2 对照表逐条）——**本版核心的「不静默覆盖」节**

> 体例：**v1 里它是什么 · v2 的结论 · 理由 · 去处**。四栏齐备，**一条不省**。
> 「理由」栏尽量用 **v2 原文逐字**；凡由本文补的推理，明确标「**展开**」。
> ⚠ **「删除」不等于「这东西不存在了」**——多数条目的结论是**移出 Core**（§二 2.4 给五个去向）。

### 2.1 v2 原文对照表逐条（**19 条，逐行**）

| # | v1 里它是什么 | v2 的结论 | 理由（v2 原文 / 展开） | 去处 |
|---|---|---|---|---|
| **1** | **Entity / Symbol**（v1 §三 3.1「最小身份」；开放 `ns`/`local` 字段 + STR 池索引） | **保留**（改名 **EntityRef**） | 原文：「没有稳定引用，关系没法成立」 | **V8 Core 第 1 组件**（§三 3.1） |
| **2** | **Term 通用代数**（v1 §三 3.2：`t ::= s \| f(t₁,…,tₙ)`，「有限 CCR 描述无限 term universe」；是 v1 的**原语之一**） | **删除核心地位** | 原文：「太容易演变成完整逻辑语言」。展开理由（原文）：一旦有它「再加 Rule：`f(x)` / `g(f(x))` …… CCR 很快就会拥有 unification / term rewriting / occurs check / recursive construction / normalization，然后它已经不是"关系层"了。**工程成本暴涨。**」 | **不需要**（通用自由项代数）。替代表达式见 §三 3.2：`relation offset(x) = 16`（value 挂在 relation 上） |
| **3** | **Relation**（v1 §三 3.3：`R(t₁,…,tₙ)` 不固定元数） | **绝对保留** | 原文：「V8 的核心」「**这是 V8 真正不可删的核心。**」 | **V8 Core 第 2 组件**（§三 3.2） |
| **4** | **N 元 relation**（v1 §三 3.3「不固定元数」） | **保留** | 原文：「二元关系明显不够」 | **V8 Core 的一部分**（`arity` 进 RelationDomain，§三 3.3） |
| **5** | **Relation schema / domain**（v1 无独立组件；schema 散在 §三 3.3 的字段表 + Theory 声明里） | **保留，但做得很薄** | 原文：「工程上需要 arity、索引、格式校验、consumer compatibility」 | **V8 Core 第 3 组件**（**RelationDomain**，§三 3.3） |
| **6** | **Rule**（v1 §三 3.4：`P₁ ∧ … ∧ Pₙ ⇒ Q`；配 §五 的 μ/ν） | **移出 CCR 核心** | 原文：「analyzer/spec/compiler 可以推导；CCR 没必要自己运行逻辑程序」。展开理由（原文整段）：一旦有 Rule 就「**谁负责求值？**」⇒ 必须回答 eager/lazy · μ/ν · termination · stratification · negation · incremental invalidation · rule priority ⇒「一下子整个 V8 都被一个 relation engine 拖走」 | **移出**（analyzer / spec / compiler）。CCR 侧只收**结果**：`reachable(A,B); reachable(A,C); …`，或**句柄** `reachabilitySource = analyzer/result handle`（原文），或让 consumer 自己从 `edge` 查 |
| **7** | **Constraint 通用语言**（v1 §三 3.5 + §四 专节 + CCR-7 的载体） | **移出核心** | 原文：「程序约束属于 Spec；domain invariant 属于 checker」 | **两分**：程序级约束 → **Spec**（`#ensure ...`）；domain invariant → **domain checker**（「regalloc checker consumes CCR relations」） |
| **8** | **Theory**（v1 §三 3.6 / §十 / §十九：V8 的**模块单位** + 组合语义 + bridge） | **降级成模块/包** | 原文：「很有工程价值，但不是数学 primitive」「**Theory 不应该是新的逻辑语义对象**」 | **V8 Core 外**：等价于 **namespace + schema bundle + tooling hooks**（§五 5.2） |
| **9** | **Algebra**（v1 §八：per-relation 局部代数 `order`/`join`/`meet`/`compose`） | **保留扩展接口，不进根语义** | 原文：「某些 relation 需要，绝不能要求所有 relation 有」 | **V8 Core 第 4 组件的可选半**（**Refinement**，§三 3.4） |
| **10** | **μ/ν fixed point**（v1 §五：`inductive;` / `coinductive;` / 默认三态；v1 称「最关键的一刀」） | **删除** | 原文：「solver/analyzer 的职责，不应该硬编码 CCR」 | **移出**（solver / analyzer）。CCR 不再有「三态」这一维 |
| **11** | **Evidence**（v1 §十一：`fact … evidence proof42;` / `derived … via …;`；`Claim` vs `VerifiedClaim`） | **降级成 metadata/reference** | 原文：「真证明进入 Spec/CSR；CCR 只需可引用证据」 | **降级**：`metadata { producer · epoch · evidence_ref }`（§三 3.5 引）。真证明 → **Spec / CSR** |
| **12** | **Assumption**（v1 §十二：`assume …` vs `prove …` 不能混；origin 四值之一） | **删除** | 原文：「明确属于规约上下文」 | **移出**（**规约上下文 / Spec**）。CCR 不再有 `assumed` 这一 origin |
| **13** | **Query language**（v1 §十三：三种查询形态 + `Projection_Q(𝓛)`，「也是一等部分」） | **不属于格式语义** | 原文：「是工具/API」「**Query Language ≠ CCR Semantics.**」+「否则以后你会为了 query optimizer 反过来修改 IR」 | **变成工具 API**（§五 5.1）。工具接口只需三条（原文）：find relations by predicate / find relations involving entity / find relations produced by pass |
| **14** | **Higher-order relation**（v1 §九：`@relation(R)` reification，「不做完整 HOL」） | **不做真正高阶逻辑**（**思路保留、机制简化**） | 原文：「给 relation 一个 ID，即可让 relation 引用 relation」 | **保留为 first-class relation identity**（§三 3.2 的 relation ID）。⚠ 明令不做：lambda relation / higher-order unification / quantification over arbitrary predicates |
| **15** | **Bridge Theory**（v1 §十九.1：跨域耦合的**专门机制**，`theory gpu-time-bridge`） | **删除核心概念** | 原文：「本质就是普通 analyzer/spec 模块」 | **移出**（analyzer / spec 模块）。§五 5.3 |
| **16** | **四值 conflict logic**（v1 §十五 / CCR-7：`unknown / positive / negative / conflict`，概念上类似 `{⊥,T,F,⊤}`） | **删除** | 原文：「太重；冲突交给 relation domain/checker」 | **移出**（relation domain / checker）。⚠ **但 v1 的「不爆炸」底线**被 v2 明确保留，见 §四.4 |
| **17** | **Open World**（v1 §二 CCR-3 / §六：`R(a,b) ∉ CCR` 只意味 unknown） | **保留** | 原文：「没有事实 ≠ 假 必须明确」 | **V8 Core 的性质**（§四）。这条是**两版共识**，v2 一字未改其义 |
| **18** | **Negation**（v1 §二 CCR-3 的「必须显式获得反向证据」+ §20 负证据） | **不内建** | 原文：「noAlias 可以就是另一 relation」 | **不需要 Core 机制**：负向知识用**另一条 relation** 表达（consumer 自己定义），而不是 Core 的 `¬` |
| **19** | **全局 complete lattice**（v1 §六 精化格 + §七 ⊤/⊥ 两端；CCR 层面的完备格承诺） | **删除** | 原文：「**这是目前最危险的过度承诺**」 | **不需要**。替代 = per-domain **可选** refinement（§三 3.4）。⚠ 连带作废的 v1 内容见 §二 2.2 #2 / #4 / #5 |

### 2.2 v2 **未点名**、但被上述三刀蕴含的 v1 内容（**12 条；本表全部是「本文展开」**）

> ⚠ **本表的性质**：v2 原文**没有逐条谈**这些；它们是被 #2（Term 砍）、#6（Rule 删）、#7（Constraint 砍）、
> #13（Query 移出）、#19（完备格删）**连带**处置的 v1 内容。
> **本文不静默丢弃它们**——逐条给处置与理由。**凡本表结论，一律不得当作 v2 原话引用。**

| # | v1 里它是什么 | 本版处置 | 理由（**展开**，非原话） | 去处 |
|---|---|---|---|---|
| **S-1** | **八条公理 CCR-1 … CCR-8**（v1 §二，v1 自称「本设计的根」） | **逐条处置**（下 8 子行） | v2 **通篇未提这八条**，但四刀砍完后它们**各归各位** | 见下 8 子行 |
| S-1a | CCR-1 **Open Symbols** | **保留**（改称 Open Entities） | Entity 保留 = #1；「符号宇宙不封闭」与「开放 tag」同义（§三 3.1） | V8 Core 性质 |
| S-1b | CCR-2 **Open Relations** | **保留**（并入 Open Relation Domain） | Relation 保留 = #3；#5 的「薄 schema」仍**不含白名单**（§五 5.1） | V8 Core 性质 |
| S-1c | CCR-3 **Open World** | **保留**（= 表 #17） | v2 原文明确「没有事实 ≠ 假 必须明确」 | V8 Core 性质（§四） |
| S-1d | CCR-4 **（v1 名：Finite Presentation, Unbounded Denotation）** | ✅ **已裁（裁-2 选「(乙)」）：删掉 v1 那条旧承诺**——**不再宣称**「有限文件表示无限结构」（`0 / succ(0) / succ(succ(0)) …`）。**保留的**是「**有限呈现**」这半边 | **v1 的两个支点都随三刀消失**：①「无限结构」由**自由项代数**（#2）承载——已删核心地位；②「由规则生成」由**规则闭包**（#6）承载——已移出 Core。⇒ v1 那条承诺**已无承载机制，故不再宣称**（不是「降级」，是**删除该承诺**） | **不需要**（旧承诺删除，不搬去任何地方）——**替代表述 = 裁-2 原文逐字，本档此后唯一合法写法**：**`.ccr` 本身有限，但 relation universe 是开放的**（Core 不封顶 relation / domain / entity 的扩展）。⚠ **两个「无限」不得混写**：这是 **open-ended**（**外延开放**），**不是** v1 的 **internally infinite**（内部指称无限） |
| S-1e | CCR-5 **No Universal Relation Algebra** | **保留**（强一致） | v2 #9 原话「绝不能要求所有 relation 有」——与 CCR-5「默认无代数性质」同义（§三 3.4） | V8 Core 性质 |
| S-1f | CCR-6 **Explicit Derivation**（新事实只能来自 given/assumption/external/**rule derivation**；origin 四值 **fail-closed**） | ⚠ **作废一半、降级一半** | 「rule derivation」随 #6 消失；「assumption」随 #12 消失 ⇒ 四值 origin 只剩 given/external；**fail-closed 的 origin 强制**不再有对象（v2 改以 `metadata.producer` 承担**溯源**，且 v2 未要求它必填） | 溯源 → `metadata`（#11）；「谁产生的」的增量用途见 §三 3.5 |
| S-1g | CCR-7 **Local Consistency**（冲突不爆炸；**是否非法由 constraint/theory 判断**） | ⚠ **前半保留、后半换主** | 前半 = v2 **唯一底线**「CCR 本身绝不采用逻辑爆炸」（§四.4）；后半的判定者 constraint/theory 随 #7/#8 出 Core ⇒ 判定归属改为 **relation domain / checker**（v2 #16 原话） | 底线留 Core；判定 → domain/checker |
| S-1h | CCR-8 **Semantic Non-Authority**（`.ccr` 不替代 HDFG 程序语义） | **精神延续**（v2 未逐字重述） | v2 的 §一.4 反目标（「CCR 再成为第四门完整语言」）+「Core 已经有 HDFG —— 程序语义」是同一命题的另一种说法；且 v1 §二 CCR-8 的四条机械判据（N-1…N-4）在 v2 下**仍是可用的验收工具** | V8 Core 性质（§十二 自查引用） |
| **S-2** | **`.ccr ≠ 𝓛`** / 「有限 presentation，指称可无限」（v1 §一，v1 自称「全部设计的支点」） | **改写**（且**后半被裁-2 明确删除**） | 支点的**后半**（指称可无限）**不是「失去机制」，是 v1 旧承诺已被删**（裁-2）——**不再宣称**；**前半**（`.ccr` ≠ 它所指的关系总和）**仍然成立且更重要**——因为关系由 analyzer/checker 产生，「盘上写的」与「成立的关系」在 v2 下**天然不等**（`reachabilitySource` 句柄即是显例） | 「`.ccr` ≠ 关系总和」→ §六 6.3；原记号 `𝓛(G, CCR)` **退出 Core 记号**（§〇.5）；「指称可无限」**进 §〇.7 #4（保留为 v1 引文 + 标注已删）** |
| **S-3** | **五原语计数口径**（v1 §三 3.0：原文列举 6 个名字而称「五个」，v1 登记了这处不自洽） | **作废**（无对象） | 计数对象（Symbol/Term/Relation/Rule/Constraint/Theory）中 **Term/Rule/Constraint/Theory 四个已出 Core** ⇒ 新旧清单无可比性。v2 给的是「**四件事**」且**列举恰四项**（无 v1 那种「N 个名字称 N-1」的不自洽） | **不需要**。本版计数口径见 §三 3.0 |
| **S-4** | **「精化格」= 模型类包含**（v1 §六：`T ⊑ T' ⟺ Models(T') ⊆ Models(T)`） | **删除** | 其定义域是 `Models(T)`——**T（theory）与模型类都不是 Core 对象了**（#8 降级、#19 删格）。v2 的 refinement 是**另一件事**：作用在 **relation domain 的信息**上（`a ⪯ b` = b 至少细化 a），不是理论间模型类包含 | **不需要**（记号与定义一并退出）。替代 = §三 3.4 |
| **S-5** | **⊤/⊥ 方向陷阱专节**（v1 §七：两套方向相反 + 全文不写视觉方向） | **作废**（其对象消失） | v1 §七 的存在前提是「两端**总存在**」；v2 明确「Core 根本没必要要求 `⊤`，甚至不需要要求 `⊥`」⇒ **没有两端，就没有方向陷阱** | **不需要**。⚠ 但 v1 §七 的**方法论**（「不要过早依赖 ⊤/⊥ 的视觉方向」）被 v2 以更强的形式继承：**Core 层面根本不出现 ⊤/⊥**（§三 3.4） |
| **S-6** | **origin 四值 + fail-closed**（v1 §十二 / CCR-6：`given`/`derived`/`assumed`/`external`，缺失即拒载） | **删除**（并入 S-1f） | 四值中两值（`derived`/`assumed`）的**产生者**已出 Core；v2 改以 metadata 承担溯源，**且未要求必填** | 见 #11。⚠ **「缺失即拒载」这条 fail-closed 纪律随之消失**——若将来要恢复，须作为**新**裁决，不得当作 v1 遗留 |
| **S-7** | **Incremental / Rule Dependency Graph**（v1 §十四：`changed symbols ↓ dependent rules ↓ affected relations`；「只是实现，不进 V8 语义」） | **删除**（随 #6） | RDG 的「rule」随 #6 出 Core ⇒ **无对象**。v2 保留了动机却换了承载：**「尤其做增量编译：AliasAnalysis v17 产生的关系，source 改了以后必须知道删哪些 stale facts」**——它的答案现在是 `metadata.producer` + `epoch`（#11），而不是 RDG | **移出**（analyzer / 实现层）。增量正确性仍须自证，但**不再经 `.ccr` 语义面** |
| **S-8** | **Cache / Memory / Time / Execution 四域重建**（v1 §十六 16.1–16.4：四个 `theory` 示例块） | **整节删除** | 四个 `theory` 块是 v1 的**示例性内容**，随 #8（Theory 降级）出 Core。v2 的「不属于 V8 Core」清单**点名了 Cache / Time / Execution / Security** | **移出**（普通 relation domain / analyzer / spec 模块）。⚠ v2 原文对 Security 的处置见 §二 2.3 |
| **S-9** | **`.ccr` 六节形状**（v1 §十七：`ccr 8` + symbols/relations/facts/rules/constraints/theories + 可选 algebras/evidence） | **换成四面**（§六） | `rules`/`constraints`/`theories` 三节随 #6/#7/#8 消失；`facts` 与 `relations` 合并；新增 `Relation Domains` 与 `Relation Metadata`（#5/#11） | 见 §六 6.1（含与 v1 的逐节差分） |
| **S-10** | **最小 Kernel 七项**（v1 §十八：Term formation / Relation application / Substitution / Rule application / Constraint satisfaction / Theory composition / Evidence checking hook） | **收缩为四项**（本文重算） | 逐项：Term formation（#2 删）· Rule application（#6 删）· Constraint satisfaction（#7 删）· Theory composition（#8 降级）· Evidence checking hook（#11 降为引用）**五项出 Core**；Substitution 的存在理由是规则/查询变量（#6/#13 出 Core）⇒ 亦无对象。**剩**：Entity 引用解析 · Relation 应用（含 value） · RelationDomain 形状校验 · refinement 关系（`⪯` 可选 `⊔`） | §三 3.0 的「Core 必须理解的四件事」 |
| **S-11** | **验收标准 §31 + 三个反例测试**（v1 §二十一：新 domain 入场零修改；无限递归 / 非格 / 矛盾三例「都必须能表示」） | ✅ **已裁（裁-3）**：**退休两条 · 继承一条 · 另设 v2 反例** | v2 砍掉 Rule/Constraint 后，两条反例的**对象消失**（⇒**失去测试力**，见 §七.2 的逐条留痕）；继承的那条**性质也变了**——它现在测的是「**CCR stores relations, not truth closure**」 | §七.2（退休两条 + 继承一条）· §七.3（**另设的 v2 反例**，全部 `[提案]`） |
| **S-12** | **定性句与案名**（v1 §二十九：`CCR = finite presentation of an open relational theory` / `[CCR] = a potentially unbounded family of relational models` / 案名 `Core V8 — Open Relational Lattice`） | **换定性**（§〇.0 / §十五） | 该定性的两个支点（theory 为核心 · 模型族无界）分别在 #8 与 S-1d 处置 | 新定性 = v2 原文那句（§〇.0） |

### 2.3 v2 明确**未**改变的 v1 结论（**防误读为「v1 全砍」**）

> 本表**不是**删除登记，是**对照**：下列 v1 结论在 v2 下**继续成立**（多为 v2 原文正面重述）。

| v1 结论 | v2 的对应原话 |
|---|---|
| **Relation 是核心，且**无预设性质（reflexive/symmetric/transitive/… 全默认未知） | #3「**这是 V8 真正不可删的核心**」+ #9「绝不能要求所有 relation 有」（代数） |
| **N 元**（不固定元数） | #4「二元关系明显不够」 |
| **Open World**：没有事实 ≠ 假 | #17「没有事实 ≠ 假 必须明确」 |
| **Mapping 非本体**（v1 §二十：「Mapping 是 relation theory 的一个应用，不是 CCR 本体」） | v2 的「不属于 V8 Core」清单**含 Mapping**（§二 2.4 表），且 #19 的替代路线与之相容 |
| **无普适关系代数**（v1 CCR-5 / §八 分层铁律「不能倒过来」） | #9「保留扩展接口，不进根语义」「绝不能要求所有 relation 有」 |
| **语义非权威**（v1 CCR-8：`.ccr` 不替代 HDFG 程序语义） | §一.4「Core 已经有 HDFG —— 程序语义」「CCR 再成为第四门完整语言是非常糟糕的工程选择」 |
| **冲突不爆炸**（v1 CCR-7 前半 / §十五「**CCR 本身绝不采用逻辑爆炸**」） | v2 原文「**只有一个底线**：**CCR 本身绝不采用逻辑爆炸。**」+ 理由「因为它根本就不是 classical theorem prover」 |
| **序列化层不定义语义**（v1 §十七 层界铁律） | v2 未提，但 v2 的四面清单**同样只是文件面**（§六 6.3 登记为沿用） |

### 2.4 「去处」一览：五个去向各自收什么（**本文汇总**）

| 去处 | 收哪些（本档条目号） |
|---|---|
| **移到 Spec** | 程序级约束（#7 前半）· 证明与证据本体（#11 后半）· 假设（#12） |
| **移到 domain checker / relation domain** | domain invariant（#7 后半）· 冲突的合法性判定（#16 后半）· 负向知识（#18，以另一 relation 表达） |
| **移到 analyzer / solver / compiler** | 规则求值（#6）· fixed point 与 μ/ν（#10）· 增量失效与 RDG（S-7）· bridge 逻辑（#15）· 三个 `*Model` 领域论域（S-8） |
| **变成工具 API** | 查询语言（#13）· 溯源查询（#11 前半，`producer`） |
| **V8 Core 内需要，但作为「扩展接口/可选」** | 局部代数（#9 → Refinement 的可选半）· relation 引用 relation（#14 → relation ID） |
| **不需要**（不搬去任何地方，直接消失） | 通用自由项代数（#2）· 全局完备格（#19）· ⊤/⊥ 两端与方向陷阱（S-5）· 精化格记号（S-4）· 五原语计数口径（S-3） |

---

## 三、V8 Core 的四组件（**v2 §「我认为真正需要的只有四个语义组件」**，字段级）

> v2 原文：「删完之后，其实 V8 核心已经非常小了。」

### 3.0 `CCR = (E, D, R)` 与「Core 必须理解什么」的计数口径（**先立口径，后取数**）

**v2 原文逐字（两种写法都给）**：

```
CCR V8

Entities
Relation Domains
Relations
Relation Metadata
```

> 没了。更抽象地：
>
> > **CCR = (E, D, R)**
> >
> > 其中 `E`：开放实体引用集合；`D`：开放 relation domains；`R`：建立在实体上的关系实例。

**口径登记（**本文展开**——v1 曾在同类处栽过一次，故先钉）**：

1. **v2 的文件面是四行**（Entities / Relation Domains / Relations / Relation Metadata），**但语义三元组是三**（`E, D, R`）。
   `Relation Metadata` 是 **R 的附属面**，不是第四个语义集合。**两个数字都对，但不可互换引用。**
   > ⚠ v1 §三 3.0 登记过一次同类不自洽（原文列举 6 名而称「五个」）。**v2 这两处不是同类问题**——
   > 一处讲**文件分节**，一处讲**语义元组**，二者不必相等。本文因此把两个口径**并列写出**，不合并、不取其一。
2. **「Core 必须理解的四件事」（本文按 S-10 重算，非原话）**：① Entity 引用解析 ② Relation 应用（含可选 value）
   ③ RelationDomain 形状校验 ④ refinement 关系（`⪯`，可选 `⊔`）。**这是 v1「最小 Kernel 七项」收缩后的结果**，收缩理由逐项见 S-10。
3. 计数纪律（本仓）：**一律读作「至少 N」**。

### 3.1 EntityRef（**V8 Core 第 1 组件**）

- **定义（v2 原文）**：稳定身份。
- **形态（v2 原文逐字转写）**：

  ```
  @hdfg.node.17
  @hdfg.value.42
  @target.reg.r12
  @deploy.gpu0
  ```

- **Core 的唯一承诺（v2 原文逐字，加粗是原文的）**：

  > CCR 不理解这些是什么。它只保证：**同一个 ID = 同一个被引用对象**。

- **开放 tag（v2 原文逐字）**：

  > 甚至 EntityKind 都不要封闭枚举。最多允许开放 tag：`hdfg.value` / `target.register` / `foo.bar.whatever`——作为**工具提示**，而不是 Core ontology。

- **[提案] 字段级定义（本文展开，按现行 `.ccr` 命名习惯给形状；不落盘、不声称已定）**：

  | 字段 | 含义 | 约束 |
  |---|---|---|
  | `id` | 稳定身份（Core 只认它） | **opaque**：Core 不解析、不解释、不比大小；唯一语义 = 相等性（CCR-1a 的「同一个 ID」） |
  | `tag` | 开放点分提示（`hdfg.value` / `target.register` / `foo.bar.whatever`） | **可选**；**开放字符串，非枚举**；**只有工具读它**——Core 与任何其他工具**不得**要求它被解释 |
  | `name_ni` | STR 段串索引（若沿用现行池化惯例） | 编码层细节，**不定义语义**（沿用 v1 同名注） |

- ⚠ **[提案] tag 与 id 的切分点未定（本文登记，见 §十 待裁 新-4）**：v2 的例子里 `@hdfg.node.17` 是「`@` + 点分串」，
  而 tag 例子是 `hdfg.value`（**无 `@`**）。两者关系有两种读法——(甲) 整串 = id、点分前缀**兼作** tag（提示是**派生的**）；
  (乙) 前缀 = tag、末段 = id（提示是**携带的**）。**v2 未裁决。**
  另注：v2 同一份原文里出现过 `target.reg`（实体例）与 `target.register`（tag 例）**两种拼写**，
  在 tag 编码定死前**须先统一**（否则正是 #5 要防的那类「一个拼写差异造出两种东西」）。
- **[已实现] 现状对照**：现行 `.ccr` **无 entity/symbol 语义段**——最接近的是 `STR(1)`（字符串池，`src/compiler/ccr_io.cr:38`）
  与 `SYM(2)`（编译器内部命名：函数/全局/结构/枚举，`:39-59`）。**不得**把 SYM 段读成 V8 的 EntityRef（沿用 v1 结论）。

### 3.2 Relation（**V8 Core 第 2 组件——v2 称「真正不可删的核心」**）

- **基本形态（v2 原文逐字）**：`R(a₁,a₂,…,aₙ)`。加一个可选 value：`R(a₁,…,aₙ) = v`。
- **例（v2 原文逐字转写）**：`depends(A, B)` · `coexists(x, y)` · `locatedAt(x, r12)` · `latency(A, B) = [2, 7]` · `permission(x) = Writable`。
- **不特殊区分（v2 原文逐字，加粗是原文的）**：

  > 我甚至不建议 Core 特殊区分：fact / mapping / analysis / storage / time —— **都是 relation**。

  **本文展开（这条的含义比字面大）**：v1 的 `facts` **不是** v2 的一个类别——它就是 Relation 的实例。
  v1 §三 3.0 的「facts 节 vs 原语清单」口径差（v1 待裁 9）**因此作废**（§十）。
- **通用 Term 砍掉之后的**替代表达（v2 原文逐字转写）：

  ```
  relation offset(x) = 16
  relation interval(eventA,eventB) = [0,2ms]
  relation version(x) = 3
  ```

  > 或者由某 domain 定义自己的 opaque/symbolic value。

  v2 原文的结论（逐字）：「所以：**不要为了理论无限性，引入通用自由项代数。** 开放 relation universe 本身已经足够不封顶。」
- **[提案] 字段级定义（本文展开）**：

  | 字段 | 含义 | 约束 |
  |---|---|---|
  | `domain_ref` | 所属 RelationDomain（**v2 新增，v1 无此字段**） | **必填**？v2 未明说 —— 见 §十 待裁 新-3（关系域外是否允许「无域 relation」） |
  | `args` | 实体引用列表（长度 = 域的 `arity`） | 元素是 **EntityRef**（或域声明的 `argument_shape` 允许者）；**不是**任意 term |
  | `value` | 可选值 `R(…) = v` | **可缺席**（缺席 ≠ 假，见 §四）；形态由域的 `value_shape` 约束 |
  | `id` | **relation ID**（v2 新增，见下） | 用于「relation 引用 relation」（#14）；**具体形态未定** ⇒ §十 待裁 新-2 |
  | `metadata` | 溯源（`producer`/`epoch`/`evidence_ref`） | **不进数学含义**（§三 3.5） |

- **relation 引用 relation（v2 原文，即 #14 的「思路保留、机制简化」）**：

  > 真正的高阶逻辑不要。但 relation record 可以有 ID：
  >
  > ```
  > %r42 = depends(A,B)
  > ```
  >
  > 然后 `preserves(mapping0, %r42)`。这成本非常低，却能满足大量"关于关系的关系"。
  >
  > 所以：**First-class relation identity 值得有。** 但不要因此实现 lambda relation / higher-order unification / quantification over arbitrary predicates。

  **本文展开（与 v1 的差分）**：v1 走的是 **reification**——`@relation(R)` 把关系**定义**变成一个 symbol，
  于是 `preserves(map0, @relation(R))`「仍然是一阶 relation」。v2 走的是 **relation record 带 ID**（`%r42 = …`）。
  两者都「不做真高阶」，但 v2 的方案**不需要新建 reification 原语**（v1 的 `@relation` 是 Core 语法），
  **成本更低且不碰 `@` 内建位**（v1 U-6 的疑问随之转化为 §十 待裁 新-2）。

### 3.3 RelationDomain（**V8 Core 第 3 组件——v2 明说保留它是「工程原因，不是哲学原因」**）

- **为什么需要它（v2 原文逐字，两条理由都转写）**：

  > 如果完全没有 schema：`locatdAt(x,r12)` / `locatedAt(x,r12)` —— 一个 typo 都可能生成两种 relation。而且 consumer 不知道怎么索引、怎么反序列化、value 是什么类型。

  即：**① 防拼写差异造出两种关系；② 给 consumer 索引/反序列化/value 类型所必需的信息。**
- **字段级（v2 原文逐字转写）**：

  ```
  RelationDomain {
      id
      version

      arity
      argument_shape
      value_shape

      optional refinement/merge semantics
  }
  ```

- **v2 原文的禁令（逐字，加粗是原文的）**：

  > **仅此而已。** 不要塞：proof rules / fixed points / solver / backend implementation 进去。

  **本文展开（这条禁令的形状）**：它是**否定式清单**——列出的四类是「一塞进去，RelationDomain 就会重新长成 v1 的 Theory/Rule/Constraint」的东西。
  故它同时是 §一.4 反目标的**局部落地**：任何新增字段，若其消费者是 solver/引擎/后端实现，即触发该禁令。
- **[提案] 字段级语义（本文展开——原文只给字段名，不给各字段的语义）**：

  | 字段 | 本文给的含义 | 约束 / 未定处 |
  |---|---|---|
  | `id` | 域的稳定名（**开放字符串，无白名单**） | 取代 v1 的 `theory` 归属（#8）；命名是否点分（`classic.regalloc`）v2 只给了 Theory 的例子 ⇒ 见 §十 待裁 新-3 |
  | `version` | 域自身的版本 | ⚠ **与 `.ccr` 的文件版本（`CCR_VERSION`）不是一回事**（§八 A-1）——同现于一处时须分开写 |
  | `arity` | 元数 | 由声明处显式给出或从声明推断；**可为 0**（命题式 relation） |
  | `argument_shape` | 实参允许面 | **形式未定**（是否引用 EntityRef 的 tag？是否闭集？）⇒ §十 待裁 新-6 |
  | `value_shape` | value 允许面 | 同上；且须容纳 v2 允许的 **opaque/symbolic value**（§三 3.2） |
  | `optional refinement/merge` | 本域**可选**提供的 `⪯` / `⊔`（§三 3.4） | **默认缺席**（CCR-5）。⚠ 原文此行把 refinement 与 merge **并写**，两者的关系见 §三 3.4 末 |
- **[已实现] 现状对照（承重差异）**：现行 `.ccr` **无 relation domain 概念**。
  现行最接近的「形状声明」是 `TYPE(7)` / `IFACE(8)` 两段（内容构造 = `src/compiler/ccr_types.cr`，D18 解耦）——
  但那是**编译器的类型判定引擎**的内部表，**不是**开放的 relation domain。
  ⚠ **不得**把 `TYPE`/`IFACE` 读成 RelationDomain 的雏形：前者是**某一实现**的封闭表，后者是**开放**的域声明（§五 5.1）。

### 3.4 Refinement（**V8 Core 第 4 组件——v2 称「唯一真正值得保留的『格』部分」，但随即自我收窄**）

- **v2 的自我收窄（原文逐字）**：

  > 但我现在甚至认为 V8 **不应该要求完整 lattice**。
  >
  > 完整格要求 `a ⊔ b` 和 `a ⊓ b` 总存在；甚至如果要求 complete lattice，还要任意集合的 sup/inf。**完全没必要。**
  >
  > 工程上真正频繁需要的其实是：**已有信息 + 新分析结果 → 更精确的信息**。

- **最弱要求（v2 原文逐字）**：

  > 所以最弱可以只要求：`a ⪯ b`，表示 **b 至少包含/细化 a 所表达的信息**。
  >
  > 某些 domain 如果需要 merge，再提供 `a ⊔ b` 即可。也就是最多要求：**partial order + optional join**。

- **分层（v2 原文逐字转写）**：

  ```
  core:             preorder / partial order
  domain optional:  bottom · join · meet · top · complete lattice
  ```

  > 这样才真的弱。

- **为什么可以不要求 `⊤`/`⊥`（v2 原文逐字，两条例证都转写）**：

  > 比如某 relation domain `D = ℕ`，正常就是无界的；或者 `D = {所有有限 relation structures}`，按 refinement 排序，也可以没有全局最大元素。所以 Core 根本没必要要求 `⊤`，甚至不需要要求 `⊥`。

  形式化（**本文展开**）：`D = ℕ` 在通常序下**无最大元** ⇒ 若 Core 要求 `⊤`，**数学上就直接把 ℕ 这类域排除掉了**。
  这正是 v2 说的「不会为了方便实现，反过来限制数学空间」。
- **unknown 的处置（衔接 §四，v2 原文逐字）**：

  > 当然工程上 unknown 很有用，所以可以规定 `relation absence = unknown`，但**这不是要求每个 mathematical domain 都有 bottom value**。这一区别非常重要：
  >
  > > **Unknown 是 CCR 的信息状态，不等于 relation domain 的数学 ⊥。**

  ⇒ `relation absence = unknown` 是**CCR 层的一条约定**，**不是**域层面的 `⊥` 存在性要求。
- **[提案] 判据形状（本文展开）**：
  1. 对未声明 refinement 的域查 `⪯` ⇒ 返回「**未声明**」（**不是** `false`、**不是** identity、**更不得**临时合成一个偏序）——与 CCR-5 同款钉子；
  2. 声明了 `⪯` 但**未**声明 `⊔` 的域，查 `⊔` ⇒ 「未声明」（**不得**用「取上确界」之类默认实现补全）；
  3. **负向钉子**：任一处出现全局 `⊔` / `⊓` / `⊤` / `⊥` 符号（即 Core 层级的格运算）⇒ 判据红（这正是 #19 的回归探测器）；
  4. **无界域必须能声明**：给一个数学上无最大元的域（`D = ℕ`）配 `⪯` ⇒ 声明通过，**不要求**提供 `⊤`（#19 与 S-5 的联合钉子）。
- ⚠ **[提案] 两处未定（本文登记，见 §十 待裁 新-7 / 新-8）**：
  - 「`preorder` / `partial order`」是 v2 原文的**斜杠并列**——**是否要求反对称（即 partial order 而非 preorder）未定**。
    这是实质性差异（preorder 下 `a ⪯ b ⪯ a` 不蕴含 `a = b`）；
  - 原文把 `refinement` 与 `merge` **并写**（`optional refinement/merge semantics`）。本文读作：`⪯` 是 refinement，
    `⊔` 是 merge（v2 正文只给了 `⪯` 与 `⊔` 两个记号）⇒ **两个词是否等同、是否各需一套，未定**。

### 3.5 Relation Metadata（v2 §「Evidence：不要删文件字段，但删语义地位」）

- **v2 的两个判断（原文逐字，都转写）**：

  > 工程上我不建议彻底扔。因为以后你会非常想知道：**这个 relation 是谁产生的？** 尤其做增量编译：AliasAnalysis v17 产生的关系，source 改了以后必须知道删哪些 stale facts。

  > 但这些**不进入 relation 的数学含义**。即 `Semantics(R)` 与 `producer = pass42` 无关。这就是正确的工程权衡。

- **形状（v2 原文逐字转写）**：

  ```
  relation ...
  metadata {
      producer
      epoch
      evidence_ref
  }
  ```

- **[提案] 判据形状（本文展开）**：
  1. **数学中立判据（本条的关键）**：改变任一 relation 的 `metadata`（含清空）⇒ 该 relation 的**语义判定结果不得变化**
     （对拍：两个 `.ccr` 仅 metadata 不同 ⇒ 一切非 metadata 查询逐条相同）。这是「不进数学含义」的**可机械检验形式**；
  2. **负向钉子**：某条规则/判定读了 `producer`/`epoch` 并因此改变结论 ⇒ 判据红（metadata 已泄漏进语义）；
  3. 三条字段**是否恰三条、是否可扩展**未定 ⇒ §十 待裁 新-5。

---

## 四、`Unknown` 是信息状态，不是数学 `⊥`（**v2 最容易被混读的一条，单独成节**）

> v2 原文自己说：「这一区别**非常重要**」；本文的判断：**这是 v2 与被它砍掉的 v1 之间最容易混读的一处**——
> 因为两版都出现「unknown」，且 v1 曾把 unknown 明确放进一个四值代数里。本节的唯一目的 = **把这两个 unknown 拆开**。

### 4.1 两个不同的东西（**本文展开的形式化**）

| | **CCR 的信息状态 `unknown`** | **relation domain 的数学 `⊥`** |
|---|---|---|
| 它是什么 | 「**CCR 没说过** `R(a,b)`」——一个**关于文件/库的陈述** | 「本 domain 按 refinement 序**存在最小元**」——一个**关于 domain 的数学事实** |
| 谁拥有它 | **CCR 层**（对**任何**域都成立，与域的数学结构无关） | **某个域**（有的域有、有的域没有——`D = ℕ` 就没有） |
| 存在性 | **无条件存在**（v2：「可以规定 `relation absence = unknown`」） | **不要求存在**（v2：「Core 根本没必要要求 `⊤`，甚至不需要要求 `⊥`」） |
| 若混读会怎样 | 把「CCR 没说」**升格**成「域的最小元」⇒ 于是**每个域都必须造一个 `⊥`** ⇒ | **正是 v2 点名要避免的**：「不会为了方便实现，反过来限制数学空间」 |

**一句话（本文概括，非原话）**：`unknown` 住在**文件语义**里，`⊥` 住在**域的数学**里；前者**人人都有**，后者**可遇不可求**。

### 4.2 为什么这条区分在 v1 → v2 之间变得更要紧（**本文展开**）

- v1 里两者**本来就容易混**，但 v1 至少给 unknown 指定了一个**代数位置**（四值 `{⊥,T,F,⊤}` 里的一个格点）——
  混读的后果是「把 unknown 读成四值里的某个点」。
- v2 **删掉了那个代数**（#16），unknown **只剩「信息状态」这一个身份**。
  ⇒ 此时若仍按 v1 的直觉去找它的「代数位置」，就会**自发地**把 `⊥` 重新引入 Core——**这不是 v2 的裁决，是对 v1 记忆的残留**。
- 因此本节的钉子**同时是 v1→v2 迁移期的守则**：迁移时**先问「这里的 unknown 是哪一个」**，再写实现。

### 4.3 与 v1 四值的关系：四值删了，底线留着（**本文展开**）

| v1 的东西 | v2 处置 | 依据 |
|---|---|---|
| 四值 `unknown / positive / negative / conflict` | **删除** | #16（「太重；冲突交给 relation domain/checker」） |
| `R(a) ∧ ¬R(a)` 时的**逻辑爆炸禁令** | **保留**（v2 明称「**只有一个底线**」） | §四.4 |
| 冲突的**合法性判定** | **换主**：constraint/theory → **relation domain / checker** | #16 + S-1g |
| 负向知识（`negative`） | **不内建**：用另一条 relation 表达 | #18 |

### 4.4 CCR 绝不逻辑爆炸（**v2 唯一底线，原文逐字**）

- **冲突怎么处理（v2 原文逐字）**：

  > 假设 `locatedAt(x,r12)` 与 `locatedAt(x,r13)`。CCR：**两个关系都存在。** 结束。
  >
  > 至于：合法的两个副本？两个 mapping candidate？错误的寄存器冲突？——由 `locatedAt` 的 consumer/checker 判定。这远远比搞 `unknown / true / false / both` 四值逻辑省事。

- **底线（v2 原文逐字，加粗是原文的）**：

  > **只有一个底线**：
  >
  > > **CCR 本身绝不采用逻辑爆炸。**

  理由（v2 原文逐字）：「因为它根本就不是 classical theorem prover。」
- **[提案] 判据形状（本文展开，沿用 v1 的爆炸探测并收窄到 v2 的最小面）**：
  1. 注入 `p(a)` 与「另一条表达其否定的 relation」（v2 无内建 `¬` ⇒ 用两条**互斥**域关系或同一域两条冲突记录）⇒
     **两条都保留**（不得后写覆盖先写、不得静默取一）；
  2. **爆炸探测（最强的一条）**：在该冲突下查询一个**完全无关**的 `q(a)` ⇒ 必须仍为 `unknown`；
     **变成 `true` ⇒ 判据红**；
  3. **加载本身成功**（无相应 checker ⇒ 冲突不导致非法）——判定权在 domain/checker，不在 kernel；
  4. ⚠ **判据的边界（承 §四.1）**：本判据只能测**第 2 条的信息状态**，**不得**写成「冲突 ⇒ 返回 `⊥`」或「冲突 ⇒ 返回四值中的某值」——
     那会把刚删掉的四值从判据面重新引回来。

---

## 五、开放关系域：v2 保留的「**open-ended（外延开放）**」及其边界

> ⚠ **本节标题已按裁-2 / 文修-1 改**：原写「v2 保留的『**不封顶**』」——那是含混说法，
> 容易被读成 v1 的 **internally infinite**（指称无限，**已删**）。**v2 保留的只有 open-ended**（§〇.7 #8）。

### 5.1 Open Relation Domain（**v2 对 v1「无硬编码 namespace」的继承**）

- v2 的对应表述是**否定式**的（原文）：Core **不**特殊区分 fact / mapping / analysis / storage / time（#3/#4），
  RelationDomain 的 `id` 是**开放**的（#5），且新增域**不改 Core**（§一.2 第 5 条「不封死未来 relation domain」）。
- **v1 §十 的「十年论证」在 v2 下的地位（**本文展开**）**：v1 原文「于是十年以后新增 `theory analog.signal` / `theory quantum.entanglement` /
  `theory distributed.consistency`，**V8 文件格式不变**。这才叫没有被现有范式封顶。」
  —— **论证的结论保留、承载词换掉**：v2 下新增的不是 `theory` 而是 **relation domain**；
  「文件格式不变」这一**检验方式仍然有效**，故本文把它作为 §七.1 主验收的断言（**但承载词按 v2 写**）。
  ⚠ **措辞注（裁-2 / 文修-1）**：引文里的「**没有被现有范式封顶**」= **open-ended**（外延开放），
  **不是** v1 的 internally infinite ⇒ 本条与 §〇.7 #8 的改写**同向**，**不构成保留「指称无限」的口子**。
- **[提案] 判据形状（本文展开）**：
  1. 域 `id` = **开放字符串**（无白名单、无枚举）；
  2. 新增域后文件版本 / 分节集合**零变化**；
  3. **负向钉子**：源码出现域名的枚举或内建域表 ⇒ 判据红。

### 5.2 Theory 的降级：模块/包（**#8**）

- **v2 原文逐字**：

  > 比如 `classic.regalloc` / `temporal` / `execution` / `security` 仍然很实用。但是：**Theory 不应该是新的逻辑语义对象**。它就类似 **namespace + schema bundle + tooling hooks**：

  ```
  theory classic.regalloc
      exports relation coexists
      exports relation locatedAt
      checker = ...
  ```

  > 这样足够。

- **本文展开（这个降级的确切含义）**：Theory 从「**V8 的模块单位 + 组合语义 + bridge**」（v1 §三 3.6/§十/§十九）
  降为**三个纯工程职能**：命名空间（避免域名撞车）· schema 打包（一次导出多个 RelationDomain）· 工具钩子（`checker = ...` 挂接点）。
  **它不再定义语义**——语义全在 RelationDomain 与 Relation 里。
- ⚠ **`checker = ...` 一行的地位 —— ✅ 已裁（裁-1，定死，不再是本文的读法）**：
  **`checker` = 外部工具钩子，不是可求值声明。** 语义（裁-1 原文逐字）：

  > `checker = <external checker identity>`
  > Core 只知道「**这个 relation domain 的额外合法性检查交给谁**」，**不把 checker 本身变成 CCR 的逻辑语言**。

  1. **名字（裁-1 要求的防误读句）**：**以后可以考虑叫 `checkerRef` / `validatorRef`**——
     防止实现者理解成「Core 要执行它」。
  2. **理由（裁-1 原文逐字，本版最重要的一条回退防线）**：**一旦 Core 需要理解/执行 checker 的内部逻辑，
     Constraint、Rule、推理语义就会从侧门重新回来。**
  3. ⇒ **它不构成本文档 v1→v2 意义上的回退**：Core 侧只保存一个**指称**（identity），
     求值发生在**外部工具**里，与 §一.4 的反目标（不做第四门语言）一致。
  4. **联动的待裁项**：原「`checker` 是工具钩子还是语义声明」= §十 待裁 **新-10，本裁定已收口**。

### 5.3 随之下线的机制（**本文汇总**）

| v1 §十九 的机制 | v2 处置 | 依据 |
|---|---|---|
| **Theory Composition**（`T = T_memory ∪ T_time ∪ T_exec`；「组合默认只是并列」） | **随 #8 出 Core** | 组合语义属语义对象；Theory 已降为包 ⇒ 打包/命名空间层面的事 |
| **Bridge Theory**（跨域耦合的专门机制 `theory gpu-time-bridge`） | **删除核心概念**（#15）——「本质就是普通 analyzer/spec 模块」 | §二 2.1 #15 |
| **「无 bridge ⇒ 无耦合」的铁律 + 判据** | **随之作废**（无 bridge 概念，即无可判之对象） | 本文展开 |
| Rule Dependency Graph（§十四） | **删除**（S-7） | 随 #6 |

> ⚠ **不要把「无 bridge ⇒ 无耦合」当成 v2 的隐含要求**：v2 没有说跨域耦合必须走某个 Core 机制，
> 它说的是**这件事不由 CCR 管**。判据面因此**少了一条**（不是变成自动满足）。

### 5.4 「无格承诺」的兑现（**v1 冲突登记 C-5 的消解，本文展开**）

- **v1 的处境**：archive 档 `memory-model-capability-lattice.md` 有「**无格承诺**」（格代数不进入语义本体，
  是映射实例的**组织参数**），而 v1 §八 允许 relation **显式声明** `order`/`join`/`meet` ⇒ v1 需要论证「表面冲突、实际相容」。
- **v2 的处置**：v2 原文自己把这一条**接上了**——

  > 这也符合你原来所谓「**无格承诺**」的真正含义。

  即：v2 的「Core **不要求**格，域**可选**提供 `⪯`/`⊔`」**就是**「无格承诺」的真正含义。
- ⇒ **v1 的 C-5 冲突在本版消解**（§九 C-5 保留条目、更新结论）。**登记而不动 archive 文件。**

---

## 六、`.ccr` 的语义面（**v2 §「所以删完以后 V8 可以非常小」**）

### 6.1 四个面（**v2 原文逐字转写**）

```
CCR V8

Entities
Relation Domains
Relations
Relation Metadata
```

> 没了。

**本文展开（面与组件的对应，供实现者对表）**：

| 文件面 | 对应语义 | 本档章节 |
|---|---|---|
| **Entities** | `E`——EntityRef 集合（稳定 ID + 可选开放 tag） | §三 3.1 |
| **Relation Domains** | `D`——RelationDomain 声明（`id`/`version`/`arity`/两 shape/可选 refinement） | §三 3.3 |
| **Relations** | `R`——`R(a₁,…,aₙ)` 与 `R(…) = v` 的实例；**含** v1 的「facts」（#3/#4：不特殊区分） | §三 3.2 |
| **Relation Metadata** | `R` 的附属面（`producer`/`epoch`/`evidence_ref`）；**不构成第四个语义集合** | §三 3.5 + §三 3.0 口径 1 |

### 6.2 与 v1 六节形状的逐节差分（**本文展开——S-9 的落地**）

| v1 §十七 的节 | v2 的去向 |
|---|---|
| 首行 `ccr 8` | **形态未定**（文本/二进制未定 ⇒ 首行是否保留未定）⇒ §十 待裁 8；**版本裁决本身**见 §九 C-1 |
| `symbols { ... }` | → **Entities** |
| `relations { ... }` | → **Relations**（关系**实例**）+ **Relation Domains**（关系**声明**）——⚠ **v1 把这两件事混在一节里**，v2 拆开 |
| `facts { ... }` | → **并入 Relations**（#3/#4「都是 relation」）⇒ v1 待裁 9 **作废** |
| `rules { ... }` | **删除**（#6） |
| `constraints { ... }` | **删除**（#7） |
| `theories { ... }` | **降级**（#8）——是否仍占一节未定（⇒ §十 待裁 新-3 的邻项） |
| 可选 `algebras { ... }` | → **并入 Relation Domains 的 `optional refinement/merge`**（#9）——**不再是独立节** |
| 可选 `evidence { ... }` | → **并入 Relation Metadata**（#11） |
| （v1 无） | **新增**：`metadata` 是否独立节未定 ⇒ §十 待裁 新-5 |

### 6.3 层界铁律（**v1 保留项**）

- v1 §十七 逐字：「但这里是序列化层，**不应该反过来定义语义**。」——**v2 未提，本文按沿用处理并登记**（§二 2.3 表末行）。
- ⚠ **本版的重申（本文展开）**：v2 的四个面**同样是文件面**。故 §六 的任何一行
  **都不得**被读成「Core 的语义由这四行穷尽」——语义在 §三，文件面只是它的**呈现**。
  这条在 v2 下比 v1 更吃紧：因为 v1 尚可用「`.ccr` 是有限呈现、指称无界」来解释落差（`𝓛`），
  而 v2 **没有 `𝓛` 这个记号了**（§〇.5）⇒ 落差改由「**CCR 只是关系的一处记录，不是关系总和**」承担（§二 S-2）。
  ⚠ **补（裁-2 / 文修-1）**：**v1 那句「指称无界」已被明确删除、不再宣称**（不是"换个说法保留"）。
  ⇒ 本节的落差解释**只剩**「一处记录 ≠ 关系总和」这一条腿，**不得**再借用「指称无界」当第二条腿。

---

## 七、验收与反例（**主验收 = 本文重算；反例处置 = 裁-3 已定**）

> ⚠ **先声明性质（本节的三个部分来源不同，不得混读）**：
> - **7.1 主验收 = 本文重算**（`[提案]`）：v1 有验收节（§31），**v2 通篇没有验收节** ⇒ 7.1 不是转写，是本文按 v2 四组件重算的。
> - **7.2 反例处置 = 维护者已裁**（**裁-3**）：**退休两条 · 继承一条**，退休者**带留痕**（不是静默删除）。
> - **7.3「另设 v2 反例」= 本文展开**（`[提案]`）：裁-3 要求「另设」但**未逐条列举** ⇒ 三条由本文导出，逐条标了依据。
>
> 凡与 v1 §二十一 不同处，**逐处给依据**。**全部 `[提案]`，当前无实现可跑**（7.2 的处置本身除外——那是裁定）。

### 7.1 主验收（本文按 v2 重算）

**断言**：一个**全新的** relation domain 入场，**Core 零修改**。

| 步 | 动作 | 断言 |
|---|---|---|
| 1 | 写一个此前不存在的域：`RelationDomain { id = "weird.future.domain", version = 1, arity = 3, argument_shape = …, value_shape = … }` | 语法接受（**该语法本身是 `[提案]`**） |
| 2 | 用该域写**任意** relation 实例（含可选 value） | 接受 |
| 3 | 给该域可选 refinement（先不声明，再声明 `⪯`，再声明 `⊔`） | 三种都能接受；**不声明时查 `⪯` 返回「未声明」** |
| 4 | 加载该 `.ccr` | rc 正常 |
| 5 | 与入场前对比 | **文件版本 / 分节集合 / HDFG 字节 全不变** |

**与 v1 主验收的差异（本文展开，逐条给依据）**：

| v1 §二十一 21.1 的步 | v2 | 依据 |
|---|---|---|
| 「定义 symbol」 | → **实体引用**（EntityRef 是**引用**，不是「定义」——v2 的 Core 不规定实体有哪些种类） | §三 3.1 |
| 「定义 relation」 | **保留** | #3 |
| 「**给规则**」 | **删除该步** | #6（Rule 出 Core） |
| 「**给 constraint**」 | **删除该步** | #7 |
| 「可选自己的 **algebra**」 | **保留但改名**：可选 refinement（`⪯` 必选、`⊔` 可选） | #9 + §三 3.4 |
| （v1 无） | **新增**：RelationDomain 声明本身（v1 把它藏在 theory 里） | #5 |

### 7.2 v1 三个反例的处置 —— **裁-3：退休两条 · 继承一条**（**留痕节**）

> v1 §二十一 21.2 的三个反例来自 v1 的失败判据：
> 「三者都必须能表示。**如果其中任何一个要求 Core 加特殊 case，说明规则还是太强。**」
>
> ⚠ **裁-3 的写法是「退休两条 + 保留一条 + 另设 v2 测试」**——**不是**「v2 以后只剩一个反例」。
> **退休的两条必须留痕**：下表「为什么失去测试力」栏**即留痕本体**，它们**不是被静默删掉的**。

| v1 反例 | 处置 | 为什么失去测试力（**留痕**） |
|---|---|---|
| **① 无限递归关系** | 🔻 **退休** | **不再是 CCR 必须内部表达的对象**（裁-3 原文）。v1 该例测的是「**规则闭包**能否在 Core 内表达无界推导」；**v2 已无 Rule**（§二 2.1 #6）⇒ CCR 里**不再有「递归关系」这个对象** ⇒ **该例没有可失败的对象了**。它所测的**整体搬到了 analyzer**（v2 给了替代路径：收结果 `reachable(A,B); reachable(A,C); …`，或收句柄 `reachabilitySource = analyzer/result handle`） |
| **② 非格关系** | 🔻 **退休** | **本来就已经合法，不再构成压力测试**（裁-3 原文）。v1 该例测的是「Core 会不会偷偷给 relation 注入格结构」（v1 的 CCR-5 钉子）；v2 **连 Core 级格承诺都没有了**（§二 #19 + S-4 + §三 3.4）⇒ 该性质**已成默认**，测试**恒绿**，**没有要反的东西**。⚠ **但它的判据面没消失**——「未声明即『未声明』」这条钉子**仍在**（§三 3.4 判据 1/2），只是**不再以「反例」身份存在** |
| **③ 相互矛盾的分析事实** | ✅ **继承**（**性质已变，见下**） | —— |

**继承的那一条（裁-3 原文逐字）**：

> `relation(A)` 与一个矛盾事实**可以共存**，**CCR 不自行推出任何东西、也不发生逻辑爆炸**。

**它测的东西变了**（v1→v2 最实质的一处重述，裁-3 原文给出的判据句）：

> **CCR stores relations, not truth closure.**

- **v1 版测的是**：冲突**不导致非法**，且四值信息状态（`unknown / positive / negative / conflict`）**可分辨**
  —— 一个**关于冲突分类**的测试。
- **v2 版测的是**：**CCR 不做真值闭包**——「**存了关系**」≠「**推断了真值**」。
  四值面**已作废**（§二 2.1 #16）⇒ **判据不得再写成四值形态**（§四.4 判据 4 已把这钉死）。
- **保留的判据**：§四.4 的**爆炸探测**（在该冲突下查一个**完全无关**的 `q(a)` ⇒ 必须仍为 `unknown`）。
- **负向钉子**：冲突**静默合并 / 消灭**（§四.4 判据 1）· **爆炸**（判据 2）⇒ 任一命中即红。
- **可观测性**：两条冲突记录**都必须可被查询到**（不是"后写覆盖先写"）。

> ⚠ **v1 那三条测试的文本仍完整存留**（在父修订里，读法见 §〇.2）。本文**不删**它们，**只标处置**。

### 7.3 另设的 v2 反例（**裁-3 要求「另设 v2 自己的反例」**——本小节全部 `[提案]`）

> ⚠ **来源声明**：裁-3 要求「另设」，但**未逐条列举是哪几条** ⇒ 下列 **3 条由本文从 v2 自身的失败条件导出**，
> 标为**本文展开**（**非原话**）。三条的共性 = **每条都对准一个「v2 若失守就会退回 v1」的口子**。

#### v2-反例 ① 一个拼写差异**不得**造出两种 relation

- **依据（v2 原文逐字）**：「`locatdAt(x,r12)` / `locatedAt(x,r12)` —— 一个 typo 都可能生成两种 relation。」
- **测试形状**：在同一 `.ccr` 里写 `locatedAt(x,r12)` 与 `locatdAt(x,r12)` ⇒ **必须可判定为「后者不属于任何已声明域」**
  （fail-closed：拒载或显式诊断），**不得**静默接受为第二条独立 relation。
- **负向钉子**：把未声明域的 relation 静默接受 ⇒ 判据红。
- **为什么是 v2 反例**：它是 v2 **唯一**由「工程原因」驱动的 Core 组件（§二 2.1 #5）的**存在理由**；
  若这条红了，RelationDomain 就没有存在的必要，v2 的「四件事」会退化成「三件事」。

#### v2-反例 ② 把 solver / fixed point / proof rules **塞进 RelationDomain**

- **依据（v2 原文逐字，禁令）**：「**仅此而已。** 不要塞：proof rules / fixed points / solver / backend implementation 进去。」
- **测试形状**：尝试给任一 RelationDomain 声明一个 proof rule / 一个 fixed point / 一个 solver / 一个后端实现
  ⇒ **必须在 Core 内无法表达**（拒载或显式诊断），**不得**存在容纳它们的"侧门"字段。
- **负向钉子**：RelationDomain 出现任何**其消费者是引擎 / 求解器 / 后端**的字段 ⇒ 判据红。
- **它守的是**：`RelationDomain` 一旦长成 v1 的 `Theory`（可声明规则、约束），**#6 / #7 / #8 三刀全部作废**。

#### v2-反例 ③ Core **不得求值** `checker`

- **依据（裁-1 原文逐字，本版新增的裁定）**：「Core 只知道『这个 relation domain 的额外合法性检查交给谁』，
  **不把 checker 本身变成 CCR 的逻辑语言**」；理由「**一旦 Core 需要理解/执行 checker 的内部逻辑，
  Constraint、Rule、推理语义就会从侧门重新回来**」。
- **测试形状**：给某域写 `checker = <identity>` ⇒ Core **只保存该指称**（§五 5.2 裁-1）。
- **负向钉子**：Core 侧出现**对 checker 内容的解析 / 求值**入口（哪怕只叫"预检"）⇒ 判据红。
- **可观测性（本条最利落的一刀）**：把 `checker` 的 identity 换成一个**指向不存在工具**的串
  ⇒ **加载必须仍成功**（因为 Core 不该解析它）；**若加载失败或行为改变 ⇒ 说明 Core 已在求值它 ⇒ 红**。
- **为什么单列**：这是**唯一**一条能机械探测「Core 有没有偷偷变成推理机」的反例，
  与裁-4 的「**读 relations ≠ 执行 CCR inference**」是**同一命题的两面**（§九 C-2）。

---

## 八、现状锚点实核（**声明基线 = `0eb1efd3`；本修订已按当前 tip `90d8a5cd` 重核，全部成立**）

> 本节全部 `[已实现]`（逐条 `file:line`），且**全部是 V8 要替换掉的东西**。
> **与 v1 的关系**：本节的 A/B/C/D 四张表**逐行沿用 v1**（任务约束：现状锚点全部保留——它们说的是**当前** `.ccr` 与 `ccr_io.cr`，
> 与 V8 长什么样无关）。**基线的同一性论证与本次抽样复核见 §八.0。**

### 八.0 核验基线与本次抽样复核（**先立口径，后取数**）

1. **基线未变**：本会话 `jj git fetch` 后实读，`develop@origin` = **`0eb1efd3`**——**与 v1 的核验基线是同一修订**。
   ⇒ v1 的逐条 `file:line` **按修订同一性继续有效**（不是「凭记忆沿用」，是**同一修订的同一读数**）。
2. **本次另做的抽样复核（16 组，逐组列出，均可复现）**：

| # | 复核对象 | 结果 |
|---|---|---|
| 1 | `CCR_MAGIC : int = 827474755` | `ccr_io.cr:134` ✓ |
| 2 | `CCR_VERSION : int = 9` | `ccr_io.cr:135` ✓ |
| 3 | `CCR_SEG_COUNT : int = 8` + 规范序注释 | `ccr_io.cr:138` ✓ |
| 4 | `CCR_SEG_TYPE = 7` / `CCR_SEG_IFACE = 8` | `ccr_io.cr:139-140` ✓ |
| 5 | load magic 闸 `if magic != CCR_MAGIC { return -1; }` | `ccr_io.cr:974-975` ✓ |
| 6 | load 版本闸 `if ver != CCR_VERSION { return -1; }`（**严格等值**） | `ccr_io.cr:978-979` ✓ |
| 7 | `ESZ_NOD_DISK : int = 40` | `ccr_io.cr:150` ✓ |
| 8 | 四条 `.ccr` 锁定值 + ELF canary 一行 | `tools/baseline/canary_values.tsv:180-184` ✓（值与 sha 逐字符核对） |
| 9 | C-6 的 **9 处陈标**（`:5` `:12` `:33` `:60` `:501` `:768` `:947` `:956` `:1356`） | 逐处读原文，**9/9 仍写 v8/36B** ✓ |
| 10 | C-9 的两处行号（clean-cache / `--static`） | `main.cr:415-421` ✓ · `:440-448` ✓ |
| 11 | 三档 CI 挂点 | `src/ci/run.sh:136` ✓ · `:137` ✓ · `:199` ✓ |
| 12 | 两个测试档行数 | `test_ccr_v7.py` = **2204** 行 ✓ · `test_ccr_types.py` = **2362** 行 ✓ |
| 13 | `existence-structure.md` D1/D2/D3 与 v6-only / 格层-编码层 | `:13` `:14` `:15` `:16` `:17` ✓ |
| 14 | 同上档「共存 = 对称、无传递性（最弱理论——最多模型）」 | `:109` ✓ |
| 15 | `materialization-space.md` §7.4：单独立项 / `CCR_VERSION 现 = 9` / §九 F 待裁 | `:784` ✓ · `:786` ✓ · `:846` ✓ |
| 16 | 术语零命中：`\btheory\b`（`src/compiler/` + `grammar/`）· `EntityRef`/`RelationDomain`（`src/`） | **均 0 行** ✓（`\brelation` 在 `src/compiler/` 仅 2 处注释，无关） |

3. ⚠ **未逐条复核的部分（诚实声明）**：§八 A/B/C 三表的**其余行**（B 表各读写点行号、C 表 `--dump-*` 锚点等）
   本次**没有逐行重读**，依第 1 条的修订同一性沿用。**若需全量复核，应作为 V8 落地批的前置步骤单独执行。**
4. 🔴 **一条本会话踩到并纠正的陷阱（务必写进任何后续复现指令）**：**主检出 `/home/DslsDZC/core` 不在此基线上**——
   它当前位于另一修订（本会话实测 `f4625ec4`），且 `src/compiler/{globals,ast,ccr_io}.cr` **逐文件与 `develop@origin` 不同**。
   ⇒ **凡对「源码现状」的 grep，必须走 `jj file show -r develop@origin <path>`（或等价地先取该修订的文件内容），
   绝不可在检出目录里就地 grep**——就地 grep 得到的是**另一个修订的行号**，而它与基线的**文件名相同、行号不同**，
   **读数看不出任何异常**。
   本会话的实例：C-10 的两处锚点（`globals.cr` 的 `g_opt_meta`、`ast.cr` 的 metadata 键表）**初稿取自就地 grep**
   （得 `:331` / `:620`），**按修订复核后改为 `:378` / `:659`**（`:376` / `:379` 亦已按修订补）。
   同批按修订复核并**结论不变**的另有 3 组（`theory` 零命中 · `EntityRef`/`RelationDomain` 零命中 ·
   `` `relation` `` 仅 2 处注释——**该 2 处的行号在基线上是 `checker.cr:4417` / `parser.cr:2026`**，与检出目录不同，本文未引用其行号）。
   > 本仓既有纪律对此有专名（「**判据真源 ≠ 手边检出**」）：**锁定值/行号的真源是修订**；多工作区下每个检出都可能落后，
   > **而落后检出与「上一代值」常常逐字节相同，看不出异常**。
5. ✅ **本修订（2026-09-23）把声明基线换成当前 tip 重核了一遍**（本仓纪律：复核任何清单的第一步 =
   把它的声明基线换成当前基线）。**结果：全部锚点在今日 tip 上仍成立**——

   | 检查 | 结果 |
   |---|---|
   | `develop@origin` 现值 | **`90d8a5cd`**（PR #163）；原基线 `0eb1efd3` **仍是其祖先** ✓ |
   | 两修订间的规模 | **130 文件 / +5750 −1948**（所以「换基线复核」不是形式动作） |
   | 本文锚定的 **14 个代码/CI/判据文件** | **逐字节相同** ✓（`ccr_io.cr` · `main.cr` · `corearch.cr` · `ccr_types.cr` · `globals.cr` · `ast.cr` · `canary_values.tsv` · `run.sh` · `test_ccr_v7.py` · `test_ccr_types.py` · `test_region_cfg.py` · `targets/x86_64-linux/main.cr` · `regalloc.cr` · `existence-structure.md` 等）⇒ **§八 A/B/C 与 C-6/C-7/C-9/C-10 的每条 `file:line` 在今日 tip 上原样成立** |
   | 2 个**已变动**的设计文档引用 | `materialization-space.md`（`:784`/`:786`/`:846`）· `execution-mapping-design.md`（`执行域` ×14 · `:640` · `:1613`）——**逐行按新 tip 重读，四处落点全部不变** ✓ |

   ⇒ **本文的锚点强度由「对 `0eb1efd3` 有效」升为「对今日 `develop@origin` 有效」**。
   ⚠ 唯二**未按新 tip 逐行重读**的仍是 §八.0 第 3 条声明的那批（B 表其余读写点行号等）——
   **但其中属「14 个文件」的已由逐字节相同覆盖**，故实际未覆盖面比第 3 条写的更小。

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

> 本表行号前缀 = **`J-`（判据锚点）**——与 §九 的 **`C-`（冲突登记）** 是**两个命名空间**，勿混。

| # | 事实 | 锚点 |
|---|---|---|
| J-1 | **`.ccr` 四条锁定值**（`canary_values.tsv` 数据行；另含 ELF canary 一条） | `tools/baseline/canary_values.tsv:180-184` |
| J-1a | `pa_ccr`（`tests/suite/ptr_arith.cr`，`ccr` 口径）= `d6ebe3d1…` / **96985 B** | `tools/baseline/canary_values.tsv:181` |
| J-1b | `pa_static_ccr`（`--static` 口径）= `041b6e3e…` / **97128 B** | `tools/baseline/canary_values.tsv:182` |
| J-1c | `gt_ccr`（`tests/suite/generics_test.cr`，`ccr` 口径）= `edfd8e98…` / **143687 B** | `tools/baseline/canary_values.tsv:183` |
| J-1d | `gt_static_ccr` = `bbfe4789…` / **143830 B** | `tools/baseline/canary_values.tsv:184` |
| J-2 | 锁定值表的**重锁前置**：重锁前必跑 `canary_check.sh` 并确认 D1 确定性闸门绿（同 canary ELF 两次构建逐字节相同）——否则会把非确定值锁进表 | `tools/baseline/canary_values.tsv:8-9` |
| J-3 | 口径：一律**冷态**（编译前 `clean-cache` = `rm -rf .core/cache/cir/`，相对 cwd）——**实核位置 = `src/compiler/main.cr:415-421`**（TSV 原文写 `:408-414`，**已陈旧**，见 C-9）；cwd = 仓库根 | `tools/baseline/canary_values.tsv:11-13` |
| J-4 | 两口径差**恒 143B** 的根因 = `--static` 前置 `rt.cr`（⇒ 4 全局 + 1 串进 `.ccr`；STR +79B / SYM +64B） | 归因出处 `tools/baseline/canary_values.tsv:24-25`；**代码位置实核 = `src/compiler/main.cr:440-448`**（TSV 原文写 `:433-437`，**已陈旧**，见 C-9） |
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

### D2. V8 与 D1/D2/D3 的替换关系（**本文展开——它们是 V8 要替换掉的东西**）

> ⚠ **本表的 v2 更新（与 v1 的差异）**：v1 表里这三行的落点用了 v1 的概念（默认态 relation / theory / bridge）；
> v2 砍掉 Rule/Constraint/Theory 后，落点**改述**。**改述为本文展开，非 v2 原话。**

| 原则 | 现行角色 | V8 下的地位（v2 口径） |
|---|---|---|
| **D1 图节点坐标** | `.ccr` 全文件以 NOD id 为坐标；「图 = 唯一真相层」 | **保留其精神、失去其垄断**：坐标仍是 HDFG 侧的，但 `.ccr` 的语义面不再由坐标承载——**EntityRef / Relation / RelationDomain 才是语义面**；NOD id 退化为**某个 relation domain 内的命名**（该域自行解释） |
| **D2 执行序重建** | corearch 从 NOD+REG 重建线性投影；「文件序即合法拓扑序」 | **降为一种消费者行为**：调度合法性 = 一组 relation + 该域的 checker，不再由**段布局**保障；且重建是**查询**而非「按段直读」（见 §九 C-2） |
| **D3 共存不落盘** | 共存从存在区间 sweep 推导（对称、无传递性，「最弱理论——最多模型」） | **被吸收为一条「无声明即最弱」的关系**：D3 的「不落盘 + 最弱理论」与 v2 的「**Core 不要求代数性质**」（CCR-5 / #9）**同构**——D3 是 v2「refinement 默认缺席」的一个**特例**。V8 的增益 = 该原则**可被扩展**（域可声明 `⪯`/`⊔`），而 D3 是固定的 |

> ⚠ **替换的性质**：V8 **不否定** D1/D2/D3 的**技术内容**（它们描述的机制仍可作为某个域的规则/消费者行为存在），
> 它否定的是**它们作为 `.ccr` 本体论的资格**——即「`.ccr` 是什么」不再由「图坐标 / 执行序投影 / 共存推导」定义。

---

## 九、冲突登记（**逐条列出 + 我的核实结论；不替维护者裁决**）

> 体例 = `execution-mapping-design.md` §十一。每条给：冲突内容 · 双方出处 · **我的核实结论**。
> **编号纪律：不重排。** v1 有 **C-1…C-9**；本版**新增 C-10**；并把 **C-5** 与 **C-10** 分别标为「**消解**」
> （逐条给理由：**C-5** = v2 把「无格承诺」接上了 · **C-10** = 本版裁-4 的 `.coi` 拆分**连带**）。
> **C-6…C-9 的序号与内容一字未动**——重排会让已引用的编号指错对象。

### C-1 ⚠ 最重要：**版本标识形态（裁-4 定死）与现行 `CCR_VERSION = 9` 的碰撞**

- **维护者裁决（v1 澄清，**原文，已定**）**：**版本整数 = 8**（不用 10）；用**「改进版加后缀」**区分；`.ccr` 零持久生态 ⇒ 旧 v8 文件的现实风险不存在。
  同一裁决附一条**硬约束**（**逐字**）：「⚠ 但 **判别式必须进"身份标识"（magic 或版本串）**，**不得只靠"结构不对会自然解析失败"自证**——D10 的教训正是"结构不对但闸门放行 ⇒ 静默当空表"。」
- ✅ **本版追加裁决（裁-4，2026-09-23，逐字）**：

  > **版本**：`V8` / `V8.x` / `V8-<suffix>`；**magic/version 必须显式进入格式身份**——
  > **不许靠「解析失败大概就不是这个版本」**（这是**文件格式工程**）。

  - **它定死了什么**：① **命名形态**（三式：裸 `V8` · 次版本 `V8.x` · 后缀 `V8-<suffix>`）；
    ② 「**身份必须显式**」这条**从"教训/约束"升为"裁决原文"**。
  - **它没有定死什么**：**三式如何映射到盘上字节**（u32 版本字段装不下字符串）⇒ 仍见下方第 3 点 / §十 待裁 1。
  - ⚠ **与 D10 同源**：裁-4 的「不许靠解析失败自证」**就是** D10 教训的正面陈词
    （D10 = 「结构不对但闸门放行 ⇒ 静默当空表」）。**V8 落地批不得以「反正解析会失败」为由省略身份判别式。**
- **D10 教训原文（逐字，出处 `docs/superpowers/plans/2026-09-12-r2-p4-carrier.md:58`）**：

  > 「若留 7，则「v7 = 恰六段规范序」语义必须放宽为「6 或 8 段」，**旧 6 段文件会被新 corearch 静默接受**（TYPE/IFACE 缺席 = 空表）——正是三态纪律要消灭的静默类（C.5-3）。」

- **我的核实结论（重要，非裁决）**：
  1. **现行整数是 9，不是 8**（`ccr_io.cr:135`，本会话复核 ✓）。故「版本整数 = 8」在数值上是**从 9 回退**，不是「保持 8」。
     原文裁决的语境（「为什么整数不能用八 **退回**不就完事了」）与该事实**一致**——「退回」即指回退版本号。
     **此读法为本文展开，原文未逐字说明「从 9 退回」**（并见 §十四 U-1）。
  2. 若新格式写 `version = 8` 而闸门仍为**等值**判定（`ccr_io.cr:978-979`，本会话复核 ✓），则
     **判别式的全部重量落在「后缀/身份标识」上**——这正是维护者附的那条硬约束，两者必须一起落地，
     **缺一即构成 D10 形态**（旧 v8 结构不对但闸门放行 ⇒ 静默当空表）。
  3. **「后缀」的编码形态未定**（u32 版本字段装不下字符串）⇒ §十 待裁 1。可行方向（**本文仅列举，不推荐、不裁决**）：
     magic 变体（`"CCR1"` → 另一 4B 串）/ 版本字段打包（整数 + 后缀位段）/ 独立身份小节。
     **三者对 `canary_values.tsv` 的影响面不同（magic 变 ⇒ 全产物 `.ccr` 头部变），须在选定时一并评估。**
  4. **与既有文档的联动**：`materialization-space.md` §7.4 已立「承载方案与 `CCR_VERSION` **一并单独立项**」且实核「`CCR_VERSION` 现 `= 9`」
     （`:784` / `:786`，本会话复核 ✓，见 §八.0）——**V8 落地批必须与那条立项对齐**（两处不得各自定版本策略）。
  5. ⚠ **本版新增的联动观察（本文展开）**：`materialization-space.md:846`（本会话复核 ✓）记有
     「`.ccr` 段位 tag 9+ **已有两个具名主张者**（驱逐标注段 / 证书段）」（其自注「lead 转来，**未经我复核**」）。
     若 V8 的承载面**不再使用段表**，该争用**自然消失**；但**是否弃用段表属 §十 待裁 8/10**（文本-二进制 / 切换方式），
     **本文不预设结论**。⇒ 与爆炸半径档的 §5「间接依赖：谁假定 `.ccr` 是段表」**同一对象**，见 §十一.3。

### C-2 后端跟着变（**v1 澄清已裁决**）——`corearch` 从「按段直读」改为「查询/求解消费者」

- **原文（v1 澄清，逐字）**：维护者答「后端也可以跟着变，反正就全改了」；任务书裁定为 **已裁决第 2 条**：
  「`corearch` 从"按段直读"改为**查询/求解消费者**。」
- ✅ **本版追加裁决（裁-4，2026-09-23，逐字）**：**读 relations ≠ 执行 CCR inference**。

  > 这条**现在比 v1 更重要**——**`.coi` 刚拆出去**（`.ccr` = relation storage，`.coi` = optimization knowledge），
  > **更没有理由让 CCR reader 偷偷演变成推理机**。

  - **与上文「查询消费者」裁决的关系（本文展开）**：两条**互补，不冲突**——
    上文说后端的**接口形态**可以是查询；裁-4 说**查询 ≠ 推理**（读到 relations 只准**取用**，**不准据此推导新关系**）。
  - **现状实核（`.coi` 落地程度）**：**`.coi` 格式尚未实现**——`develop@origin` 上**无任何 `.coi` 文件**；
    现存的是设计档 `docs/maintainer/design/coi-optimization-knowledge-sidecar.md`（其 **K-3** 自述「`.coi` 在本仓**零对应物**」）
    与计划档 `docs/superpowers/plans/2026-09-23-coi-implementation.md`（**日期 = 本裁定同日**）⇒ **`.coi` 是进行中的批**，`[已设计未实现]`。
  - **它加固的正是 §七 的 v2-反例 ③**（Core 不得求值 `checker`）：两者是**同一命题的两面**（不推理 / 不求值）。
- **我的核实结论（现状锚点，支撑「全改」的代价判断）**：
  1. 现行 `corearch` 的消费面**确实是按段直读**：`load_ccr` 逐段解析并重建内存表（§八 B 全表），
     随后 `build_linear_schedule()` 从对象缓冲重建线性流（`corearch.cr:410-413`；`regalloc.cr:867`）；
     另有四条 `--dump-*` 读回通道**直接按段**打印（`corearch.cr:309/310/380-403`）。
  2. 故「改为查询消费者」**不是局部改造**：它触及 load 侧全部 8 段的重建语义 + 发射前的调度重建 + 四条调试通道。
     **原文的「反正就全改了」在此得到现状支持。**
  3. **但（v2 更新，本文展开）**：`CCR-8` 的 N-1（发射无关）要求发射路径**不得**依赖关系面。若后端改为「查询消费者」，
     **必须**划清「查询哪些面」——**发射所需的 NOD/REG/SYM/ENT 承载面**与 **V8 的 Entities/Relation Domains/Relations 语义面**是两回事。
     **v2 砍掉 Rule/Constraint/Theory 后这条边界比 v1 更窄**（不必再问「要不要消费规则/约束/理论」——**它们已不在 Core**），
     但**边界本身仍未划** ⇒ §十 待裁 2（**已收窄**）。
  4. ✅ **是否复议：已裁（裁-4）——`沿用`** ⇒ §十四 **U-12 已裁决（v1 两条裁决均沿用，未被撤销）**。
     ⚠ 但**裁定的内容**与 v1 不同：v1 只说「后端跟着变」，裁-4 追加了**边界**（读 relations ≠ 执行 inference）⇒ 见上。

### C-3 与存在格层（ADR-0021 / `materialization-space.md`）的层归属

- **冲突内容**：`existence-structure.md:17`（原文逐字，本会话复核 ✓）把 **ENT/NOD/REG 的语义**（条目数学结构/版本/区间/共存）定为**「格层」**；ADR-0021 把格层本体定为**存在格**。
  而 V8 把「格」降为**每域可选的 refinement**（§三 3.4），且 v1 就明确过「**它跟 RAM / cache / register / GPU 没有任何关系**」。
- **我的核实结论（v2 更新）**：
  1. **两个「格」不是同一个数学对象**：存在格 = 载体侧的存在/物化结构；V8 = 域侧的**可选 refinement 偏序**。**二者可以共存，但不得同用一「格」字**（§〇.4 已钉）。
  2. **v2 使这条冲突的「数学侧压力」下降**（本文展开）：v1 尚在 Core 层主张一个「精化格」（model-class 偏序），
     与存在格构成**两个 Core 级格承诺**的对峙；v2 **删除 Core 级格承诺**（#19 + S-4）⇒ 只剩**层归属**之争。
  3. **真实冲突点（未变）**：`existence-structure.md` 把 ENT/NOD/REG 当作**范式无关的语义承载**；V8 把它们降为**某一实现/域的内部数据**。
     这是**层归属之争**，不是术语之争——**本文不裁决**，登记为 §十 待裁 3。
  4. **共同点（可作为协调基础，本会话复核 ✓）**：`existence-structure.md:109`「共存 = 对称、无传递性（**最弱理论——最多模型**）」
     与 V8 的「**Core 不要求代数性质**」**用词同源**，说明两侧共享同一「弱理论」直觉。**这是两批可以对齐的接口。**

### C-4 ⚠ `execution-mapping-design.md`（同批）与「Mapping 非本体」的直接对立

- **冲突内容**：`execution-mapping-design.md` 的定位是「**异构 Execution Mapping 层**」`[已设计未实现]`（该档 §9.1–§9.3 论证「MAP 段的真实代价」与承载方案；
  本会话复核：该档确在 `develop@origin` 上，其「执行域」出现 **14 处**，「MAP 段」见 `:640`，§十一 C-6 见 `:1613`）；
  而 V8（v1 §二十 与 v2 的**非核心清单**一致）断言「**Mapping 是 relation theory 的一个应用，不是 CCR 本体**」。
- **我的核实结论（v2 更新）**：
  1. 两者**在层归属上正相反**：一个把 Mapping 立为层，一个把它降为应用。**本文不裁决。**
  2. **v2 未加剧冲突**（本文展开）：v2 的「不属于 V8 Core」清单**明确含 Mapping**
     （「Rule / Fixed Point / Constraint / Proof / Assumption / Query / Mapping / Cache / Time / Execution / Security」）
     ⇒ 与 v1 §29 **同结论**，故本冲突**在两版之间没有变化**。
  3. **但两者仍可同时为真**（关键观察，本文展开，**非任一原话**）：`execution-mapping-design.md` 的 Mapping 是**实现侧的一层工程组织**（谁算、放哪、什么代价）；
     V8 说的是**本体论地位**（Mapping 不进入 Core 语义面）。「工程上分层」与「本体上非核心」**不矛盾**——
     **若**两档同批接受此读法，则 C-4 可降级为**措辞冲突**。**须由维护者确认或否决。** ⇒ §十 待裁 4。
  4. **可机械检验的收窄判据**（若采纳上述读法）：**MAP 段不得被发射路径读取**（= CCR-8 的 N-1 同款判据）——这一条同时满足两档。

### C-5 档案「无格承诺」对 V8 局部代数的约束 —— ✅ **本版消解**

- **v1 的处境**：`docs/archive/memory-model-capability-lattice.md`（v4 定稿，archive）有「**无格承诺**」——格代数不进入语义本体，是映射实例的**组织参数**；
  而 v1 §八 允许 relation **显式声明** `order`/`join`/`meet` ⇒ v1 需要论证「表面冲突、实际相容」。
- **v2 的处置（本文展开；依据 = v2 原文一句）**：v2 原文自己把这条接上了——

  > 这也符合你原来所谓「**无格承诺**」的真正含义。

  即：v2 的「Core **不要求**格、域**可选**提供 `⪯`/`⊔`」**就是**「无格承诺」的真正含义（§五 5.4）。
- **我的核实结论**：**冲突消解，不再是张力**。**登记而不动 archive 文件**（archive 文件不改）。
  ⚠ 消解的是**冲突**，不是**措辞问题**：archive 档与本文仍**共用「格」字**（§〇.4 已钉）。

### C-6 `ccr_io.cr` 头注释与常量不一致（**已知陈旧**，核实并登记）——**本会话 9/9 复核 ✓**

- **事实**：头注释多处仍写「v8 / version==8」，与常量 `CCR_VERSION = 9`（`:135`）及写侧 `:571` 冲突。**实核清单（9 处；本会话逐行重读，9/9 仍写 v8 或 36B）**：

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
     ⚠ **v2 追加（本文展开）**：v2 把语义面换成 Entity/Relation/Domain 后，**这 9 处陈标全部会成为「描述一个已退役架构」的注释**——
     刷新**不能只改数字**（v9→v8 之类），须与承载面决策（§十 待裁 8/10）**同批**决定「这些注释还该不该存在」。
  3. **本文不动该文件**（任务约束：只动本档一个文件）⇒ 登记，作为 V8 落地批的必做前置项。

### C-7 `ccr_types.cr` 头注的调用点行号已漂移（同类，附登记）

- **事实**：`src/compiler/ccr_types.cr:50` 写「save_ccr 两处调用点（`main.cr:612` `ccr` / `main.cr:636` `build`）」；
  实核现行行号 = **`main.cr:691`**（`ccr` 分支）与 **`main.cr:721`**（`build` 分支）。
- **我的核实结论**：性质同 C-6（注释陈迹），**危险度低**（引用的是调用点而非闸门语义）。登记，不改。

### C-8 `--dump-types` 等通道在 V8 下的存续未定

- **冲突内容**：现行四条 `--dump-*` 读回通道（`J-8`/`J-9` 锚点）**按段** dump 内容，是现行判据网的主体（`test_ccr_types.py` 的跨进程对拍依赖它们）。
  V8 若把语义面改为 Entities/Relation Domains/Relations/Relation Metadata，**这些段的 dump 通道将无对象**。
- **我的核实结论（v2 更新）**：
  1. **判据网与 V8 的关系没有被原文触及**（v1/v2 皆未）。这是 V8 落地批的**漏检风险面**：新格式不能只带新语义，
     **必须同批给出新的读回通道**（否则 §七 的验收标准**无法机械化**——「能表示」需要可观测证据）。⇒ §十 待裁 5。
  2. ⚠ **v2 使这条比 v1 更容易满足，但要求更硬**（本文展开）：v2 的语义面**只有四类对象**（v1 是六个原语 + 规则 + 约束 + 理论），
     故新读回通道的**对象面更小**；但 v2 的验收（§七）**依赖 4 条负向钉子**（未声明即「未声明」/ 未声明域拒载 / metadata 中立 / 爆炸探测），
     这些**全部需要读回通道**才能观测 ⇒ **通道不是可选项**。

### C-9 判据载体自身的**引用行号已陈旧**（v1 会话发现，同类第三例）——**本会话复核 ✓**

- **冲突内容**：`tools/baseline/canary_values.tsv` 在注释里给出两条**代码位置引用**，在 `develop@origin` 上**逐条实核，两者都已陈旧**：

  | TSV 原文引用 | 实核（`develop@origin`） | 漂移 | 实核依据（本会话重读 ✓） |
  |---|---|---|---|
  | `src/compiler/main.cr:408-414`（clean-cache 口径） | **`:415-421`** | +7 | `main.cr:415` = `// === clean-cache: delete incremental compilation cache ===`；`:416` = `if cli_eq(cmd, "clean-cache") {`；`:417` = `system("rm -rf .core/cache/cir/");` |
  | `src/compiler/main.cr:433-437`（`--static` 前置 `rt.cr`） | **`:440-448`** | +7 | `main.cr:440` = `// --static: prepend rt.cr so * functions inline`；`:441` = `if cli_has("static") != 0 {`；`:447` = `g_source = rt_src + "\n" + g_source;` |

- **我的核实结论**：
  1. **性质属本仓已登记的一类**（「文档引用行号随代码漂移」——`existence-structure.md:135` 有同类校正先例，`ccr_types.cr:50` 的调用点行号亦已漂移，见 C-7）。**危险度中等**：
     TSV 引用的**值**（四条 `.ccr` 锁定值）不受影响，受影响的只是「配方出处」的可核查性。
  2. **对 V8 的直接意义**：本设计**主张 `.ccr` 判据网要大改**（C-8），故这些引用**即将再次失效**——**V8 落地批不应逐条修补旧引用，而应改为「锁定值 + 判据形状」分离**：
     值仍锁在 TSV，而**口径配方**（怎么跑）以**可执行脚本**承载（`canary_check.sh` 已有此形），
     使行号引用不再是判据成立的必要条件。
  3. **本文只登记，不改 `canary_values.tsv`**（任务约束：只动本档一个文件）。

### C-10 ⚠ **本版新增**：`metadata` 与现行 `g_opt_meta` **同名不同物**（且同处一个 `.ccr` 内）

- **冲突内容**：V8 引入 `metadata { producer · epoch · evidence_ref }`（§三 3.5）；
  而现行 `.ccr` **已经有**一个叫 metadata 的东西——`g_opt_meta`（**声明 + 同行注 = `src/compiler/globals.cr:378`**
  「`metadata buffer for .ccr v3+`」；节注释 `:376`；计数/容量 `:379`），
  由 SYM 段的第 6 子节承载（写点 `ccr_io.cr:749` · 读点 `:1269`；键表见 `src/compiler/ast.cr:659`
  「Optimization metadata keys (.ccr v3+ extensible section)」）。
  **两者都在 `.ccr` 里、都叫 metadata、语义完全不同**（一个是编译器优化参数，一个是关系溯源）。
- **我的核实结论**：
  1. **这是术语撞车，不是设计冲突**（本文展开）：现行 `opt_meta` 是**某一实现**的优化参数袋，V8 metadata 是**关系溯源**。
     两者**可以共存**，但**不得共用一个名字**——否则「`.ccr` 里的 metadata」将无法被无歧义引用，
     而这恰是 #5（RelationDomain 的防 typo 动机）要防的那类**歧义**，只是发生在**文档/接口层**而非关系名层。
  2. **危险度：中**（本文展开）。它不会立刻造成错误行为，但它会让**判据/接口文档**无法精确指称，
     并且在 V8 落地批「刷新 `ccr_io.cr` 注释」（C-6）时**极易写错对象**。
  3. **处置建议（建议，不裁决）**：V8 侧的对外名称至少加限定（如 `relation metadata` / `relations.metadata`），
     或在承载面决策（§十 待裁 8/10）时一并改名。**本文不改任何代码。**
  4. ⚠ **与 C-6 的联动**：C-6 的 9 处陈标里有 2 处直指版本闸；本条则会在**同一批注释刷新**中被再次触碰 ⇒ **两条应同批处置**。
  5. ✅ **本版更新（2026-09-23，裁-4 的连带）：本条已被 `.coi` 拆分解消——但消解的是「撞车」，不是「无需处置」。**
     - **依据（`.coi` 设计档 §〇.1 自己给出的结论，本文引用而非自创）**：该档**直接引用了本条**，
       并判定「**`.coi` 把 opt_meta 整节搬出 `.ccr` 之后，C-10 从「改名问题」降级为「不存在问题」**：
       `.ccr` 里只剩 relation metadata 一个候选者，「metadata」一词在 `.ccr` 语境下**恢复无歧义**」。
     - **⇒ 本条的最终形态**：**条件性消解**——**一旦 `.coi` 落地**（`opt_meta` 整节移出 `.ccr`），
       「`.ccr` 内两个 metadata」**不再存在**；**在 `.coi` 落地之前**，本条**照旧成立**。
     - **⚠ 因此处置建议随之改**（本文展开）：**不要再按「给 V8 侧改名（`relation metadata` 等）」推进**——
       改名是治症；**治本 = 让 `opt_meta` 搬出 `.ccr`**（正是 `.coi` 在做的事）。两者**不要同时做**，
       否则会在迁移期引入**第三种叫法**。
     - **交叉引用**：`.coi` 设计档 §〇.1 的标题即「`metadata`——⚠ 与 V8 规格的 C-10 **是同一个冲突**」，
       ⇒ **两档在这一条上已对齐**，本档不必再单独立项。
     - ⚠ **独立佐证（顺带，非本档结论）**：该档在复述本条锚点时写的是
       「声明 `src/compiler/globals.cr:378`（注释原文 `metadata buffer for .ccr v3+`）、节注 `:376`、计数/容量 `:379`」
       —— **与本修订按 `develop@origin` 复核后的值逐字一致**（本档曾据落后检出写成 `:331`，已改，见 §八.0 第 4 条）。

---

## 十、待裁（真正的未定项，**逐条列出，本文不替维护者裁决**）

> **本版重算**（v1 有 10 项）。体例：**v1 十项逐条给处置**（保留 / 收窄 / **作废**——作废项**不删行**，给理由），
> 其后**新增项**。⚠ 按本仓枚举计数纪律，**两表一律读作「至少 N 项」**，且**表内各项互不依赖**，可分别裁决。

### 10.1 v1 十项的处置（**作废项保留行 + 给消失理由**）

| v1 # | 待裁项 | v2 处置 | 为什么（对作废项：为什么消失） | 影响面 |
|---|---|---|---|---|
| 1 | 「改进版后缀」的编码形态 | ⚠ **收窄保留**（裁-4 定死了一半） | **已定的那一半**：命名形态 = **`V8` / `V8.x` / `V8-<suffix>`**（三式），且「**身份必须显式进 magic/version**」由裁决原文钉死（不许靠解析失败自证）。**仍未定的那一半**：**三式如何映射到盘上字节**（u32 版本字段装不下字符串） | 决定 `CCR_MAGIC`/`CCR_VERSION` 的**类型** → 触发 `canary_values.tsv` 重锁 |
| 2 | 后端查询的**范围界** | ⚠ **收窄保留** | **消失的那部分** = 「发射路径要不要消费规则/约束/理论」——**三者已不在 Core**（#6/#7/#8）⇒ 无对象。**剩下的核心问题** = 「发射所需的 NOD/REG/SYM/ENT 承载面」与「V8 的 Entity/Relation 语义面」的边界 | 决定 corearch 改造的最小面（全改 vs 分层改） |
| 3 | ENT/NOD/REG 在 V8 下的层归属 | **保留** | v2 未触及；且 v2 删掉 Core 级格承诺后（#19/S-4），此争**只剩层归属**、数学侧压力下降（§九 C-3） | 决定 `existence-structure.md` / ADR-0002 / ADR-0021 的地位变化（§十一） |
| 4 | Mapping 的层归属（C-4） | **保留** | v2 的非核心清单**含 Mapping**，与 v1 §29 同结论 ⇒ 冲突未变（§九 C-4） | 决定 `execution-mapping-design.md` 与 V8 的共存方式 |
| 5 | 新格式的读回/判据通道 | **保留**（要求更硬） | 见 C-8 结论 2：v2 的验收依赖 4 条负向钉子，**全部需要读回通道** | 决定 §七 验收能否机械化 |
| ~~6~~ | ~~多结论规则（多头）~~ | **作废** | **Rule 整体移出 Core（#6）** ⇒ 无对象 | —— |
| ~~7~~ | ~~Constraint 结论值域~~ | **作废** | **Constraint 整体移出 Core（#7）** ⇒ 无对象 | —— |
| 8 | `.ccr` 是文本还是二进制 | **保留**（**任务点名：v1 就未定，仍然未定**） | v2 只给**四面清单**，未说落盘形态；现行 `.ccr` 是二进制、现行 STR/SYM 池化编码与之无关 | 决定 V8 落地的**编码层全盘**（含是否保留段表） |
| ~~9~~ | ~~§25 的 `facts` 节 vs 原语清单~~ | **作废**（**有后继项**） | v1 该口径差的两个对象（`facts` 节 / 原语清单）**双双消失**：`facts` 并入 Relations（#3/#4），原语清单被「四件事」取代。**后继项**见 新-5（metadata 是独立节还是挂在 relation 上） | —— |
| 10 | V8 与现行 v9 的切换方式 | **保留** | v2 未触及；「全改」（v1 澄清）× 「零转换工具」（`existence-structure.md:16`）的矛盾原样存在 | 决定切换批规模与回退面 |

### 10.2 新增待裁项（**任务点名 7 项 + 本文派生 4 项**）

| # | 待裁项 | 来源 | 为什么未定 | 影响面 |
|---|---|---|---|---|
| **新-1** | **`R(…) = v` 的 value 语法与类型** | **任务点名**（v2 #3） | v2 只给形态 `R(a₁,…,aₙ) = v` 与两个例子（`latency(A,B) = [2,7]`、`permission(x) = Writable`），未给 value 的**语法类**（字面量？标识符？区间？）与**类型系统**；且明说可由域定义 **opaque/symbolic value** ⇒ 开放面更大 | 决定 value_shape 的编码；决定 consumer 如何反序列化（#5 的动机之一） |
| **新-2** | **relation ID / reification 的具体形态** | **任务点名**（v2 #14） | v2 只给 `%r42 = depends(A,B)` 一例，未说：ID 是**局部还是全局**、是否入 STR 池、`%` 是否为新语法位、**与 v1 的 `@relation(R)` 是什么关系**（替代？并存？） | 决定「relation 引用 relation」的编码；决定是否新占语法位（承 v1 U-6） |
| **新-3** | **域外 relation（无域可归）是否允许** | 本文派生 | v2 说 RelationDomain 是为**防 typo 与索引**（#5），但**未明说** `domain_ref` 是否必填、`arity = 0` 的域是否要显式声明 | 决定「§七.3 反例 4」的判据方向（拒载 vs 诊断）；决定 `arity` 的语义严格度 |
| **新-4** | **EntityRef 的开放 tag 编码** | **任务点名**（v2 #1） | v2 给例不给形式：`@hdfg.node.17`（**带 `@`**）vs `hdfg.value`（**不带**）⇒ tag 是**派生前缀**还是**携带字段**未定；且同一份原文出现 `target.reg` / `target.register` **两种拼写**（§三 3.1） | 决定 EntityRef 的编码面；**拼写不统一会直接造出「两种 tag」**（= #5 要防的形态） |
| **新-5** | **`metadata` 字段集 + 是否独立节** | **任务点名**（v2 #11）+ 承 v1 待裁 9 | v2 给了 `producer`/`epoch`/`evidence_ref` 三个名字，未说：**是否恰三条**、是否可扩展、是否**每条 relation 各带**还是**独立一节**（v2 的四面清单把它**单列一行**，倾向于独立面） | 决定文件分节；决定 §三 3.5 判据 1 的对拍口径 |
| **新-6** | **`argument_shape` / `value_shape` 的形式** | 本文派生 | v2 只给字段名（#5 的动机是「consumer 不知道怎么索引、怎么反序列化、value 是什么类型」），**未给这两个 shape 的语言**：是引用 Entity 的 tag？是闭集？可否为空（= 任意）？ | 决定 RelationDomain 的落盘形状（新-7）与校验强度 |
| **新-7** | **RelationDomain 的落盘形状** | **任务点名**（v2 #5） | v2 只给字段清单，未说：各字段如何编码、是否沿用**段表**、`version` 与 `.ccr` 的文件版本如何共存（§三 3.3 的表已标二者不是一回事） | 决定编码层全盘（与待裁 8 强耦合） |
| **新-8** | **refinement 的声明面：谁声明、写在哪** | **任务点名**（v2 #9） | v2 说 `optional refinement/merge semantics` 是 RelationDomain 的一个字段，但未说**声明的载体**：域声明处内联？独立节？还是工具侧提供（域只给 id 引用）？ | 决定 `⪯`/`⊔` 的归属与实现位置（Core vs 工具） |
| ~~**新-9**~~ | ~~「无界指称」在 v2 下是否仍成立/是否仍需要~~ | **✅ 已裁决（裁-2 选「(乙)」）** | **裁定内容**：**删掉 v1 那条旧承诺**（不再宣称「有限文件表示无限结构」）；**保留的**是「`.ccr` 本身有限，但 relation universe 是开放的」= **open-ended（外延开放）**，**不是** internally infinite | **落点**：§二 S-1d · §五 标题+5.1 · §六 6.3 · §〇.7（清点） |
| ~~**新-10**~~ | ~~`checker = ...` 是工具钩子还是语义声明~~ | **✅ 已裁决（裁-1，定死）** | **裁定内容**：`checker` = **外部工具钩子**，**不是可求值声明**；语义 = `checker = <external checker identity>`；**名字以后可考虑叫 `checkerRef` / `validatorRef`**（防误读）；理由 = **一旦 Core 需要理解/执行 checker 的内部逻辑，Constraint、Rule、推理语义就会从侧门重新回来** | **落点**：§五 5.2 · §七.3 **v2-反例 ③**（Core 不得求值 checker——本条因此**有了机械判据**） |
| ~~**新-11**~~ | ~~v1 的三个反例测试是否仍保留为验收项~~ | **✅ 已裁决（裁-3）** | **裁定内容**：**退休两条**（无限递归 · 非格）· **继承一条**（矛盾不爆炸，改述为「**CCR stores relations, not truth closure**」）· **另设 v2 反例**；⚠ **不是「只剩一个反例」**；**退休两条必须留痕** | **落点**：§七.2（留痕节）· §七.3（另设 3 条，本文导出） |

> ⚠ **五项「随 Rule/Constraint/Query 消失」的登记完整性核查（本版必做，逐项给落点）**：
> 其中三项**在 v1 里不是待裁项、而是设计内容**（故不在上表，而在 §二 的删除登记里）——**逐项指路，防漏**：
>
> | 项 | v1 里的身份 | 本版落点 |
> |---|---|---|
> | **Rule Dependency Graph** | v1 §十四 设计内容 + v1 未核实 U-7 | 删除登记 **§二 2.2 S-7** + 未核实 **~~U-7~~ 作废**（§十四.1） |
> | **Constraint 结论值域** | v1 待裁 **#7** | 上表 **~~7~~ 作废** |
> | **四值 conflict logic** | v1 §十五 / CCR-7 设计内容 | 删除登记 **§二 2.1 #16** + 底线保留与换主 **§二 S-1g** + **§四.3** |
> | **μ/ν fixed point** | v1 §五 设计内容（v1 自称「最关键的一刀」） | 删除登记 **§二 2.1 #10** |
> | **后端查询范围界的「一部分」** | v1 待裁 **#2** 的一部分 | 上表 **#2 收窄保留**（消失的那部分 = 规则/约束/理论的消费问题） |
>
> ⇒ **五项全部有落点**，且**消失的理由逐项给出**（不静默）。

> ⚠ **两表合计 21 项——但其中 3 项已由 2026-09-23 裁定收口**（行内划掉 + 给裁定内容，**不删行**）。明细：
> **v1 十项** = **保留 5**〔#3/#4/#5/#8/#10〕· **收窄保留 2**〔#1：命名已定 / 编码未定 · #2：消失的那部分是规则/约束/理论的消费问题〕· **作废 3**〔#6/#7/#9，其中 #9 有后继项〕= 10；
> **新增 11**〔新-1…新-11〕，其中 **已裁决 3**〔新-9（裁-2）· 新-10（裁-1）· 新-11（裁-3）〕⇒ **仍待裁 8**。
> ⇒ **当前实际待裁 = `(5+2) + 8` = 15 项**（其余 3 项作废 + 3 项已裁）。**逐行已机械重数 ✓**，各项互不依赖，可分别裁决。
> **本文不含任何对上述各项的裁决**；凡本文给出的读法，均已标「本文展开」。

---

## 十一、与既有文档的关系（**只登记与建议，不动任何既有文件**）

> 任务约束：本节**只登记**，**不改**任何既有文件的正文。以下「建议」均为**建议**，不是已执行。
> ⚠ **v2 更新**：v1 此节的核心对象（`.ccr` 的语义承载）**基本未变**，但 v1 §25.1 表里的「V8 取代段表架构」一句
> 在 v2 下**须加限定**——v2 **未定**承载面（§十 待裁 8/10）⇒ 「取代」的是**语义面**，承载面去向另裁。

### 11.1 三份文件的地位变化

| 文件 | 现行地位（实核） | V8 下的地位变化 | 处置建议（**不执行**） |
|---|---|---|---|
| `docs/superpowers/specs/2026-09-09-lattice-ir-v7-format.md` | **现行字节权威**（其 §1 表把 v9 列为现行版本 `:24`；§4 规则 5 写「`version == 9`，`version ≠ 9` 整类拒收」`:184`）`[已实现]` | **语义面被取代**；**承载面去留未定**（§十 待裁 8/10）。**V8 未落地前它仍是字节真源**——本文不改写它 | V8 落地批同批新起字节 spec（文件名建议 `2026-09-22-lattice-ir-v8-<...>.md`），该 spec **头部追加**「已由 … 取代」标注，**正文保留**（本仓先例：ADR supersede 保留原文） |
| `docs/maintainer/design/existence-structure.md` | ENT/NOD/REG 的**语义承载**文档（`:17` 明写这三者的语义属**格层**，范式无关）`[已设计未实现]` | **语义承载地位被取代**（**若**采 §十 待裁 3 的该侧读法）；**字段/字节描述仍有效**（它们描述的是现行 v9 盘面） | **不删**。待 ADR 裁决后：或（甲）降为「历史承载描述 + 指向 V8」，或（乙）保留为某个域实现的字段参考。**两案都要求先裁 C-3** |
| `docs/maintainer/adr/adr-0002-ccr-v6-segment-table.md` | `accepted`（2026-09-05，决策者 DslsDZC）`[已实现]` | **被取代**（若 §十 待裁 8/10 裁为「弃用段表」）；**若承载面保留段表，则本 ADR 不动** | 按 `docs/maintainer/adr/README.md` 的规则（**逐字**：「从 0001 起递增;新决策落地时追加,**不修改已 accepted 的历史记录**」「状态:accepted / **superseded by ADR-000N(被取代)——被取代的保留原文,新决策另起新号**」）⇒ **保留 ADR-0002 原文**，新起一号记录 V8 |

### 11.2 是否需要新 ADR ——**建议：需要，且不止一份可考虑**

- **建议（主）：新起一号 ADR**（按 README 索引，**本会话实核现行最大号 = ADR-0022**，故建议 **ADR-0023**；**取号前须再核当天 `docs/maintainer/adr/` 现值**）
  —— 内容 = 「`.ccr` V8 = Entity + Relation + Open Relation Domain + Optional Refinement Algebra（开放关系域 + 可选 refinement）；v1 的 Rule/Constraint/Theory/μν/四值/Query/Bridge 与全局完备格均不在 Core」；
  状态 `accepted`；**`supersedes ADR-0002 仅在承载面弃用段表时成立**（见 11.1 第三行）。
- **建议（次，须先裁）**：
  - `ADR-0020`（IR 双形态：`.cir` 图 / `.ccr` 格）——其「双形态」命题与 V8 **不冲突**（V8 换的是 `.ccr` 的**内涵**，不是「有两种形态」这件事），
    但 `.ccr` 的描述「格形态线性投影」会失准 ⇒ **建议仅追加状态注**（不 supersede）。**须先裁 §十 待裁 3。**
  - `ADR-0021`（存在格层定义）——与 V8 的关系取决于 C-3 的裁决。**本设计不预设两者冲突**（§九 C-3 已说明两个「格」是不同数学对象）。
- **不做的事**：本文**不写**任何 ADR 草稿、**不改** ADR README 索引（那会动已存在文件）。

### 11.3 与其他文档/产物的联动登记（**v2 新增两行；本修订再加一行**）

| 文档 | 联动点 | 性质 |
|---|---|---|
| **`docs/maintainer/design/coi-optimization-knowledge-sidecar.md`**（**本修订新增；`develop@origin` 上已存在**） | ⚠ **裁-4 的第二半直接指向它**：**`.ccr` = relation storage · `.coi` = optimization knowledge**。两处实质交互：① **C-2**（读 relations ≠ 执行 inference——`.coi` 的拆出**加固**了这条边界）② **C-10**（`opt_meta` 搬出 `.ccr` ⇒ 「同名不同物」**条件性消解**，**该档 §〇.1 自己就这么判定，并直接引用了本档 C-10**） | **互补且已对齐**。⚠ **落地程度**：`[已设计未实现]`——`develop@origin` 上**无任何 `.coi` 文件**（该档 K-3 自述「零对应物」）；另有同日计划档 `docs/superpowers/plans/2026-09-23-coi-implementation.md`。⚠ **本文只读了该档的节标题、§〇.1 与 K-1/K-3 若干行**（全文 1515+ 行），**未逐条对账** ⇒ §十四 **U-18** |
| **`docs/superpowers/specs/2026-09-22-ccr-v8-blast-radius.md`**（**另一位写手；`develop@origin` 上尚无**，按名引用） | **分工**：它管**承载面**（谁产谁读谁搬运 · 段级消费者矩阵 · 后端函数级清单 · 判据面作废清单 · 假定段表的间接依赖），本文管**语义面**（四组件 + 删除登记 + 冲突/待裁/未核实） | **互补，不重复**。⚠ **两处必须对齐的接缝**：① **版本/身份标识**（本文 C-1 = 它的 §5 对象之一）② **段表去留**（本文 §十 待裁 8/10 = 它的 §5 主题）③ **判据面作废范围**（本文 C-8 = 它的 §4）。⚠ **它的标题仍用 v1 名**（§〇.0 已登记）；⚠ **它引了本文 CCR-4 的旧措辞 ⇒ 须同步**（§〇.6 文修-1）；⚠ 本文**只读了它的标题/节标题与若干行**，未逐条对账 ⇒ §十四 U-16 |
| `docs/maintainer/design/materialization-space.md` | §7.4 已立「承载方案与 `CCR_VERSION` 一并单独立项」，且实核 `CCR_VERSION 现 = 9`（`:786`）；`:846` 记「tag 9+ 两个具名主张者」。**本修订按新 tip 复读，四处引用落点不变**（§八.0 第 5 条） | **必须对齐**：V8 的版本策略（C-1）与承载面决策（§十 8/10）不得与该立项各自为政 |
| `docs/maintainer/design/execution-mapping-design.md` | 其「Mapping 一等层」 vs V8「Mapping 非本体」 | **直接对立**（C-4），待裁 4。**本修订按新 tip 复读，其「执行域」14 处 / `:640` / `:1613` 落点不变** |
| `docs/academic/cache-semantics.md`（条款 1–7） | `existence-structure.md` 的条款权威；v1 §十六 16.1 曾把 Cache 降为普通 theory，**该节本版已删**（§二 S-8） | ⚠ **本版变更**：v1 说「条款 1–7 的适用范围收窄为 `theory cache`（**不废除**）」；**v2 没有 `theory cache` 这个 Core 对象了** ⇒ 该收窄表述**失去对象**。**建议改为**：条款 1–7 的适用范围 = 「某个 cache 相关的 relation domain + 其 checker」（⚠ 该 checker 现在有确定语义了——**外部工具**，裁-1）。**登记，不改**；⚠ 这条**属本文展开**，须维护者确认 |
| `src/compiler/ccr_io.cr` 头注释 | C-6 的 9 处陈标（含 2 处直指版本闸）+ C-10 的 metadata 撞车 | V8 落地批的**必做前置**（否则读侧真源被陈标遮蔽）；**两条应同批处置**。⚠ **C-10 侧更新**：处置方向**改为「等 `.coi` 搬走 `opt_meta`」，不再走「V8 侧改名」**（见 C-10 第 5 点） |

---

## 十二、三态计数与自查

### 12.1 计数

> ⚠ **自指陷阱**（本仓既有纪律）：本节若把三态标记写成**字面方括号形态**，会被自己的 `grep` 计入 ⇒ 计数每次重数都变。
> 故本节内标记一律写作 `〔已实现〕` / `〔已设计未实现〕` / `〔提案〕`（**全角括号**，不匹配计数正则），**其余章节保留方括号形态**。
> 复现口径：`grep -o '\[已实现\]' <file> | wc -l`（方括号形态）。

> **读数纪律（先立，后取数）**：本表数字**全部由本会话实测**，复现命令逐条给出。
> 取数**在 §12.1 自身写成全角 `〔〕` 之后**执行——即**自述文字不进计数**。

| 档 | A（内联标记出现次数） | B（清单行数，**权威口径**） | 说明 |
|---|---|---|---|
| 〔已实现〕 | **9** | **46** | B = §八 A/B/C 三表的**数据行**（每条带 `file:line`），**与 v1 同值**（同表同行、基线同一）；**本会话机械重数 ✓**（§12.3） |
| 〔已设计未实现〕 | **7** | 无成表清单（散落 7 处，见下） | B 档不适用——本档主张不集中在单一清单。⚠ **本修订 +3**（全是 `.coi`：裁-4 引入的新设计档） |
| 〔提案〕 | **21** | 其余全部（**默认档**） | A 只数**显式写出**的标记；**未含**默认推断档。⚠ **本修订 +2**（§七 的 7.1/7.3 来源声明） |

**B 口径（〔已实现〕= 46 的构成，可逐表核，**与 v1 逐行相同**）**：§八 A 表 **11** 行（A-1…A-11）· B 写侧表 **8** 行 · B 读侧表 **9** 行 · B 消费者表 **4** 行 · C 表 **14** 行（C-1 + C-1a…C-1d + C-2…C-10）⇒ `11+8+9+4+14 = 46`。

**口径纪律（五条，缺任一条则数不可复现）**：

1. **A 含方法论自述，故 A 不是主张数**：〔已实现〕的 9 处里 **4 处不是主张**（前言的三态说明 · §〇.3 三态表的表头行 · §〇.3 后的「本设计的特殊性」说明 · §八 节首「本节全部…」说明），**余 5 处是真主张**；另两档同样混有口径自述（**§12.3 逐处列出**）。**A 只能当「标记用了多少次」，不能当「核了几件事」。**
   > ⚠ **按内容定位，不按行号定位**（本仓纪律：行号随编辑漂移，见 §九 C-6/C-7/C-9）——本清单因此**不含行号**。
2. **B 才是权威**（对〔已实现〕而言）：每条带 `file:line`，可逐条复核。**本版的 B 沿用了 v1 的 46 行**——依据是 §八.0 第 1 条的**修订同一性**（基线未变）+ 第 2 条的 **16 组抽样复核**；**其余行未逐行重读**（§八.0 第 3 条已声明）。
3. **`A < B` 是正常的**：清单行**本身不带标记**（只有事实文本 + 锚点）⇒ 一个主张可以只有清单行、没有行内标记。**不得据此认为漏标。**
4. **读作「至少 N」**：按本仓纪律（枚举型计数随细看只会变多），三档一律读作「至少」。
5. ⚠ **v2 新增的一条口径纪律**：**本版的计数不得与 v1 的计数直接比较**——v1 记为 8/6/30 的三档是**另一篇文档**的读数（v1 已存留于父修订，§〇.2）。
   两版**章节结构不同**（v2 删了 12 个 v1 章节、新增了删除登记与四组件两节），**差值无意义**。要比，只能比**同一口径下的同表**（即 B=46 那张）。

**〔已设计未实现〕的分布**（无成表清单，逐处给，**合计 7 处**）：§〇.4 术语护栏表 **1 处**（`存在格`——同行的「能力格」**无独立标记**）· §关联列表 **1 处**（`.coi` 设计档，**本修订新增**）· §九 C-2 **1 处**（`.coi` 落地程度，**本修订新增**）· §九 C-4 **1 处**（`execution-mapping-design.md`）· §十一.1 表 **1 处**（`existence-structure.md`）· §十一.3 表 **1 处**（`.coi`，**本修订新增**）· §〇.3 定义表 **1 处**（**方法论自述，非主张**）⇒ **6 真主张 + 1 自述**。

> ⚠ **时点**：以上读数为**本文件当前修订**的读数。本文若后续增删章节，**须重跑上列命令并同批改本表**
> （否则本表立刻变成陈旧锚点——本仓已有此类事故，见 §九 C-6/C-7/C-9）。

**实测读数（本会话 2026-09-23，`f` = 本文件）**：

```
grep -o '\[已实现\]'        $f | wc -l    # → 9
grep -o '\[已设计未实现\]'  $f | wc -l    # → 7
grep -o '\[提案\]'          $f | wc -l    # → 21
```

（构成与复核见 §12.3；**先写成命令、取数后才回填**——避免「先写数、后取证」。）

### 12.2 自查（逐条对 v2 原文与任务要求）

| # | 要求 | 落点 | 状态 |
|---|---|---|---|
| 1 | v2 原文 14 个标题全覆盖 | §十三 覆盖表 | ✅ 逐节可查 |
| 2 | **「删除了什么、为什么」**逐条（对照表 19 条） | §二 2.1 | ✅ 19/19，四栏齐备（v1 里是什么 / 结论 / 理由 / 去处） |
| 3 | v2 未点名的 v1 内容亦不静默丢弃 | §二 2.2 | ✅ 12 条（含八公理 8 子行） |
| 4 | v2 未改变的 v1 结论有对照（防误读为全砍） | §二 2.3 | ✅ 8 条 |
| 5 | **`Unknown ≠ 数学 ⊥`** 写在显眼处 | §〇.3 后的 🔴 提示块 + **§四 专节** | ✅ 两处 |
| 6 | 四组件字段级（EntityRef / Relation / RelationDomain / Refinement） | §三 3.1–3.4 | ✅ 四组件各带字段表 + 未定处指针 |
| 7 | RelationDomain 的「不要塞什么」+ 理由 | §三 3.3 | ✅ 禁令逐字 + 两条工程理由 + 本文对禁令形状的展开 |
| 8 | Refinement：`⪯` 必需 / `⊔` 可选 / `core` vs `domain optional` | §三 3.4 | ✅ 分层块逐字转写 + 无界域例证 + 4 条判据 |
| 9 | 待裁重算（v1 十项处置 + 新增 ≥7） | §十 | ✅ v1 10 项（**保留 5 / 收窄保留 2 / 作废 3**【其中 1 项有后继】）+ **新增 11 项**（任务点名 7 + 本文派生 4）⇒ 合计 **21 项**；其中 **3 项已由 2026-09-23 裁定收口**（新-9/新-10/新-11，行内划掉 + 给裁定内容）⇒ **当前仍待裁 15 项**。逐行机械重数 ✓ |
| 10 | 现状锚点全部保留 | §八 A/B/C/D | ✅ 逐行沿用 + 基线同一性论证 + 16 组抽样复核 |
| 11 | 三态标注（默认 `[提案]`） | §〇.3 + §十二 | ✅ 全文强制；本设计几乎全 `[提案]` |
| 12 | 交叉引用爆炸半径档 | 头部关联列表 + §十一.3 | ✅ 按名引用（该档不在 `develop@origin`）；分工与三处接缝已列 |
| 13 | **维护者判断与本文展开分清** | 全文 | ✅ 四种声音（v2 原文 / v1 原文 / 本文展开 / 现状实核）逐处标注 |
| 14 | 未核实项照旧列清单（v2 下作废的划掉、仍有效的保留） | §十四 | ✅ v1 **十一项**逐个处置（**保留 7**〔U-1/2/3/8/9/10/11〕· 转化保留 1〔U-6〕· 部分作废 1〔U-4〕· 降级移出本档 1〔U-5〕· **作废 1**〔U-7〕= 11）+ **新增 7 项**（U-12…U-18）⇒ 合计 **18 项**，逐行机械重数 ✓。**本修订按裁-4 更新 3 项**：**U-12 已裁决**（两条均沿用）· U-1 已澄清（V8 系命名）· U-2 收窄（命名已定/编码未定） |
| 15 | 不重写历史 / 文件名不动 / 标题变更入正文 | §〇.0 + §〇.2 | ✅ v1 存留父修订 + 读取方式给内容特征 |
| 16 | 不动其他文件 | 全文 | ✅ 只改了本档一个文件（`jj diff` 两段式核过） |
| 17 | **裁-1**：`checker` 定死为外部工具钩子（+ `checkerRef`/`validatorRef` 防误读句 + 理由） | §〇.6 裁-1 · §五 5.2 · §七.3 v2-反例 ③ · §十 新-10（已裁） | ✅ 逐条落地 |
| 18 | **裁-2**：CCR-4 选 (乙)，删旧承诺；open-ended ≠ internally infinite | §〇.6 裁-2 · §二 S-1d · §五 标题+5.1 · §六 6.3 · §十 新-9（已裁） | ✅ |
| 19 | **裁-3**：反例「退休两条 + 继承一条 + 另设 v2 测试」；退休者留痕 | §〇.6 裁-3 · **§七.2（留痕节）** · §七.3（另设 3 条）· §十 新-11（已裁） | ✅ 两条各带「为什么失去测试力」栏；继承条改述为 `CCR stores relations, not truth closure` |
| 20 | **裁-4**：版本标识形态定死 + 显式身份；后端「读 relations ≠ 执行 inference」 | §〇.6 裁-4 · §九 C-1 · §九 C-2（+ `.coi`）· §十 待裁 1（收窄）· §十一.3 · §十四 U-12（已裁） | ✅ |
| 21 | **文修-1**：全文禁「`.ccr` 表示无限结构」；给出唯一合法英文表述 | §〇.6 文修-1 · **§〇.7（11 处清点：改写 4 / 保留 7）** · §十五 自我约束 5 | ✅ 清点表逐处给判定与理由 |
| 22 | **基线换成当前 tip 重核**（复核任何清单的第一步） | §八.0 第 5 条 · §八 标题 · 头部基线块 | ✅ `90d8a5cd`；14 个代码文件逐字节相同 · 2 处文档引用重读落点不变 |

### 12.3 实测读数回填

**取数时点** = §12.1 写成全角 `〔〕` **之后**（自述文字不进计数）；复现命令见 §12.1 末（`$f` = 本文件）。

#### A 口径的构成（**逐处列，按内容定位、不按行号**）

| 档 | A（实测） | 构成 |
|---|---|---|
| 〔已实现〕 | **9** | **4 处方法论自述**（前言「全文除显式标注…」句 · §〇.3 三态表的表头行 · §〇.3 后「本设计的特殊性」说明 · §八 节首「本节全部…」说明）+ **5 处真主张**（§〇.4 术语护栏的 `metadata` 行 · §三 3.1 现状对照 · §三 3.3 现状对照 · §十一.1 表 `2026-09-09-lattice-ir-v7-format.md` 行 · §十一.1 表 `adr-0002` 行）——**本修订未增减** |
| 〔已设计未实现〕 | **7** | 1 处方法论自述（§〇.3 表头行）+ **6 处真主张**（§〇.4 术语护栏的 `格/Lattice` 行 · §关联列表的 `.coi` 行〔**新**〕 · §九 C-2 的 `.coi` 落地程度〔**新**〕 · §九 C-4 · §十一.1 表 `existence-structure.md` 行 · §十一.3 表的 `.coi` 行〔**新**〕） |
| 〔提案〕 | **21** | 3 处口径自述（§〇.3 表头行 · 「默认必须是…」句 · 「本设计的特殊性」说明）+ 18 处正文/来源声明/自查/自我约束标记 |

#### B 口径（**权威**）实测 = **46**——**本会话机械重数，不引用 v1 的既有读数**

```
§八 A 表    行首匹配 `| A-<数字>`                        → 11
§八 B 写侧  表数据行（表头行、分隔行除外）                →  8
§八 B 读侧  表数据行（表头行、分隔行除外）                →  9
§八 B 消费者表数据行（表头行、分隔行除外）                →  4
§八 C 表    行首匹配 `| J-`                             → 14
                                                  合计 = 46  ✓（11+8+9+4+14）
```

> ⚠ **本修订（2026-09-23）对 B 的影响 = 零**：§八 的四张表**一行未动**（新增内容全部落在 §八.0 的声明段与 §九 的 C-1/C-2/C-10）。
> 且 §八.0 第 5 条已证明**这些锚点在当前 tip 上逐字节成立**（14 个文件相同）。

#### 三条计数纪律的实现注记（**如实登记，含一处巧合**）

1. ⚠ **一处容易误判的计数细节**：§12.1 末尾的复现命令块把三条命令的**方括号都转义**了（`\[` … `\]`）——
   **转义后不再构成三档标记的字面子串**，故该命令块**不会被自己计入**。
   ⚠ 这是**巧合而非设计**：若将来有人把命令块改成**不带转义**的形态，**三档会各 +1**。
   ⇒ **复现时若读数与本表不符，先查这一处，再怀疑漏标。**
2. **A 不是主张数（本版实测再次印证）**：〔已实现〕的 9 里 4 处、〔已设计未实现〕的 4 里 1 处、〔提案〕的 19 里 3 处
   均为**口径/方法论自述**。**权威口径始终是 B=46。**
3. **本版 B 的举证边界（承 §八.0）**：46 行**沿用 v1 的同名同表同修订**，依据 = 修订同一性 + **16 组抽样复核**；
   **其余行未逐行重读**。故本表的强度是「**B 的构成被机械重数 ✓** + **B 的锚点被抽样复核（16 组）**」，
   **不是**「46 条锚点本会话全部重读」——后者应作为 V8 落地批的前置步骤单独执行。

---

## 十三、覆盖表（**机械可查**）

### 13.1 v2 原文（14 个标题）→ 本文章节

| v2 原文标题 | 本文章节 |
|---|---|
| 先定一个工程目标（+ 19 行对照表） | **§一** + **§二 2.1**（19 行逐条） |
| 我认为真正需要的只有四个语义组件 | **§三** |
| ├ 1. EntityRef | §三 3.1 |
| ├ 2. Relation | §三 3.2 |
| ├ 3. RelationDomain | §三 3.3 |
| └ 4. Refinement | §三 3.4 + **§四**（unknown 专节） |
| 通用 Term 我认为应该砍 | §二 2.1 #2 + §三 3.2（替代表达式） |
| Rule 我现在也明确建议从 CCR 中删除 | §二 2.1 #6 + §二 2.4（去处） |
| Constraint 也应该砍 | §二 2.1 #7 |
| Theory 还值得留，但只是「包」 | §五 5.2 + §二 2.1 #8 |
| Evidence：不要删文件字段，但删语义地位 | §三 3.5 + §二 2.1 #11 |
| Relation 引用 Relation：值得保留 | §三 3.2（relation ID）+ §二 2.1 #14 |
| Conflict system 也不需要专门设计 | **§四 4.4** + §二 2.1 #16 |
| Query 也不要污染格式 | §二 2.1 #13 + §五 5.1 |
| 所以删完以后 V8 可以非常小（四面清单） | **§六 6.1** + §三 3.0（`CCR = (E, D, R)` 口径） |
| 那「格」还剩多少？ | §三 3.4 + **§五 5.4**（无格承诺的兑现） |
| 我认为 V8 最应该避免的一个错误 | **§一.4**（反目标：第四门语言） |
| 所以现在如果让我真正冻结 V8，我会定（四件事） | **§〇.0**（标题）+ §一.1 + §二 2.4 |

**未落表**：v2 的抬头段（「有。重新逐项审查后……」与「我会把 V8 再砍一轮」）→ 本档 §〇.1 的差分表。

### 13.2 v1 的 31 节 → v2 的处置（**供 v1 读者迁移**）

| v1 节 | v2 处置 | 本档落点 |
|---|---|---|
| §1 总结构 | 改写（S-2） | §〇.1 / §六 6.3 |
| §2 不定义格里的对象 | 精神延续 | §三 3.0 |
| §3 Symbol | **保留（改名 EntityRef）** | §三 3.1 |
| §4 Term | **删除核心地位** | §二 2.1 #2 |
| §5 Relation | **绝对保留** | §三 3.2 |
| §6 不采用 Closed World | **保留** | §四 |
| §7 Rule | **移出核心** | §二 2.1 #6 |
| §8 Rule vs Constraint | **整节作废**（两者皆出 Core） | §二 2.1 #6/#7 |
| §9 μ/ν/默认三态 | **删除** | §二 2.1 #10 |
| §10 格在模型精化上 | **删除**（S-4） | §二 2.2 S-4 |
| §11 ⊤/⊥ 方向 | **整节作废**（S-5） | §二 2.2 S-5 |
| §12 局部代数 | **保留为可选半** | §三 3.4 |
| §13 高阶与 reification | **思路保留、机制简化** | §三 3.2（relation ID） |
| §14 Theory 是模块 | **降级为模块/包** | §五 5.2 |
| §15 无硬编码 namespace | 保留（承载词换为 relation domain） | §五 5.1 |
| §16 Evidence | **降级为 metadata** | §三 3.5 |
| §17 Assumption | **删除** | §二 2.1 #12 |
| §18 Query | **移出为工具 API** | §二 2.1 #13 |
| §19 Incremental | **删除**（S-7） | §二 2.2 S-7 |
| §20 冲突不爆炸 | **前半保留（唯一底线）、后半换主** | §四.4 / §二 2.2 S-1g |
| §21 Cache | **随 §16 整节删除** | §二 2.2 S-8 |
| §22 Memory | 同上 | §二 2.2 S-8 |
| §23 Time | 同上 | §二 2.2 S-8 |
| §24 Execution | 同上 | §二 2.2 S-8 |
| §25 六节文件形状 | **换成四面** | §六 6.2 |
| §26 最小 Kernel | **收缩为四项** | §三 3.0 口径 2 / §二 S-10 |
| §27 Theory Composition | **随 Theory 降级出 Core** | §五 5.3 |
| §28 组合原则 | 同上 | §五 5.3 |
| §29 Mapping 非核心 | **保留** | §二 2.3 表 |
| §30 八条公理 | **逐条处置** | §二 2.2 S-1a…S-1h |
| §31 验收标准 | **须重算**（v2 未给） | §七 |
| 文末两处已裁决 | **保留**（v2 未复议） | §九 C-1 / C-2 |

---

## 十四、未核实清单（**宁可交白卷也不猜**）

> 体例 = `execution-mapping-design.md` §十二。以下各项**本会话未核实**，**不得**被读成已核实。
> **v2 重算**：v1 十一项逐个处置（保留 / 部分作废 / 作废），其后新增。

### 14.1 v1 十一项的处置

| v1 # | 未核实项 | v2 处置 |
|---|---|---|
| U-1 | 「版本整数 = 8」是否意为从现行 9 回退 | ⚠ **已由裁-4 澄清（2026-09-23）**——裁定给的标识形态是 **`V8` / `V8.x` / `V8-<suffix>`**，即**版本号就是 8 系** ⇒ 「**退回**（回退版本号）」读法成立。⚠ **但裁定原文只给标识形态、未逐字说「从 9 退回」** ⇒ **该推论仍标为本文展开**（§九 C-1 第 1 点） |
| U-2 | 「改进版加后缀」的后缀具体形态 | ⚠ **收窄（裁-4 定死了一半）**：**命名形态已定** = `V8` / `V8.x` / `V8-<suffix>`（三式）+「身份必须显式进 magic/version」；**仍未定** = 三式**如何映射到盘上字节**（= §十 待裁 1 的剩余半） |
| U-3 | V8 是文本还是二进制格式 | **保留**（= §十 待裁 8；**任务点名：v1 就未定，仍然未定**） |
| U-4 | `theory`/`relation`/`rule`/`constraint`/`inductive`/`coinductive` 是否入 Core 语言语法 | ⚠ **部分作废**：`rule`/`constraint`/`inductive`/`coinductive` **不再是 V8 概念**（#6/#7/#10）⇒ 其语法面问题**无对象**。**仍有效部分** = `relation`（v2 仍用）与 `theory`（降为模块/包后是否入语法未定）。**新增部分**见 U-12 |
| U-5 | `query` 的消费接口形态 | ⚠ **降级并移出本档范围**：v2 明说 Query **不属于格式语义**、是工具/API（#13）⇒ 该问题**不再由格式设计回答**。**登记去处 = 工具侧**，本档不再作为未核实项维护 |
| U-6 | `@relation(R)` 的 `@` 前缀是否复用现行 `@` 内建位 | **转化保留**：v2 改用 `%r42` 记法 ⇒ 问题变成「**`%` 是否为新语法位**」，转为 §十 待裁 新-2 |
| ~~U-7~~ | ~~Rule Dependency Graph 是否需要独立落盘通道~~ | **作废**：Rule 移出核心（#6）⇒ RDG 无对象（§二 S-7） |
| U-8 | 四个反例测试的期望值 | **保留且更未定**：v2 未给验收标准，三例对象已变（§七.2）⇒ 期望值须重算 |
| U-9 | `canary_values.tsv` 在 V8 下的重锁策略 | **保留**（取决于 §十 待裁 1 与 8；**本文不给预测**） |
| U-10 | ADR-0023 的取号是否可用 | **保留**（本会话实核 README 索引最大号 = ADR-0022，与 v1 同；取号前须再核当天现值） |
| U-11 | `existence-structure.md` / `materialization-space.md` 是否有本文未读到的 V8 相关预设 | **保留且范围明确**：本会话读了 `existence-structure.md` 的 `:13-17` 与 `:109`、`materialization-space.md` 的 `:784/:786/:846`；**两者全文均未通读**（后者 872 行） |

### 14.2 新增未核实项

| # | 未核实项 | 为什么没核 | 谁需要它 |
|---|---|---|---|
| **U-12** | **v2 是否撤销 v1 的两条裁决**（版本整数 = 8 + 后缀 / corearch 改为查询消费者） | ✅ **已裁决（裁-4，2026-09-23）：两条均`沿用`，未被撤销**——且**内容被加厚**：版本侧追加了**标识形态**（`V8`/`V8.x`/`V8-<suffix>`）+「身份必须显式」；后端侧追加了**边界**（读 relations ≠ 执行 inference）。**原「本文按未撤销处理、非原话」的悬置已由裁定解除** | 裁决人（已收口）；V8 落地批 |
| **U-13** | **v2 是否有意保留 v1 的「语义非权威」（CCR-8）与四条判据 N-1…N-4** | v2 未逐字重述该原则；本文按「精神延续」处理（§二 S-1h 给了依据），但那**是本文的推理** | 裁决人 |
| **U-14** | **`@deploy.gpu0` 的 `deploy` 是否属 Core 承认的东西** | v2 例中出现该前缀，但 v2 同时说 tag「**只是工具提示**，而不是 Core ontology」⇒ 「Core 的例子用了它」与「它不是 Core 的」之间的**关系未定** | 语法/编码设计 |
| **U-15** | **`existence-structure.md` / `materialization-space.md` 与 v2 有无新冲突** | v2 删了 Core 级格承诺与 theory，**可能**使既有文档里的一些句子失去对象（本文只改了 §十一.3 的 cache 一行，**其余未逐句对账**） | 裁决人；文档批 |
| **U-16** | **爆炸半径档（另一位写手）与 v2 的相容性** | 该档**不在 `develop@origin`**，且本文**只读了它的标题、节标题与若干行**（共 272 行），未逐条对账；其侦查语境是 v1 的「取代段表」框架 | 两档作者；V8 落地批 |
| **U-18** | **`.coi` 设计档与本文的相容性**（**本修订新增**） | 本文**只读了该档的节标题、§〇.1 与 K-1/K-3 若干行**（全文 1500+ 行）⇒ **未逐条对账**。已核实的只有两点：① 其 §〇.1 **直接引用了本档 C-10** 并给出「条件性消解」结论（本文据此更新 C-10，**属引用而非自创**）；② 其 **K-3 自述「`.coi` 在本仓零对应物」**与本文实测「`develop@origin` 上无任何 `.coi` 文件」**一致** ✓。⚠ **未核**：其 §五「与 `.ccr` 的边界对照表」是否与本文 §六 的四面清单**有第二份权威** | 两档作者；裁决人 |
| **U-17** | **v2 的「四件事」是否与 v1 的 `type_engine` / `type_terms` 现状构成第三个「域」问题** | ⚠ 本文**未展开**：现行 `TYPE(7)`/`IFACE(8)`（`ccr_types.cr` 构造）在 v2 下应归为**某个 relation domain**、还是**另一套独立机制**，v2 未提，本文亦未核（§三 3.3 只登记了「不得读成雏形」） | 裁决人；承载面设计 |

---

## 十五、定位与自我约束

**v2 原文的定性句（逐字）**：

> 所以现在如果让我真正冻结 V8，我会定：
>
> > **Entity + Relation + Open Relation Domain + Optional Refinement Algebra**
>
> **只有四件事。** 其他所有东西——Rule / Fixed Point / Constraint / Proof / Assumption / Query / Mapping / Cache / Time / Execution / Security——**全部建立在这四件事上面，但不属于 V8 Core**。

**v2 原文的收束（逐字）**：

> 这版比我们前面那个 V8 小了差不多一半，但实际表达能力我认为基本没损失；反而 verifier、compiler 和文件格式都会更容易真正做出来。

**v1 的定性句（保留于此，仅供对照 / 已由上式取代）**：

> 所以 V8 最终不应该叫 "Cache Semantics V2"，也不应该叫 "Existence Lattice"。我会直接定性为：
> **Core V8 — Open Relational Lattice**
> 最简数学描述：**CCR = finite presentation of an open relational theory** / **[CCR] = a potentially unbounded family of relational models**

**本文的自我约束（展开）**：

1. 本文**不**为本设计添加任何原文之外的**承诺**。凡本文补入的（判据形状、字段级定义、冲突登记、删除登记、重算的验收/待裁/未核实），一律标「**本文展开**」且**默认 `[提案]`**。
2. 凡涉及「仓库现在有什么」，一律给 `file:line`；凡未核实，一律进 §十四。
3. **本文不含任何对 §十 待裁项或 §九 冲突的裁决。**
   ⚠ **补（2026-09-23）**：§〇.6 记录的四条裁定 + 一条文字修正**是维护者所裁**，**不是本文的裁决**——
   本文在该节的角色仅为「**记录原文 + 标注落点**」。凡本文对裁定内容的**推论**（如 U-1 的「退回」读法），
   仍逐处标「本文展开」。
4. ⚠ **本版新增的一条自我约束（因为 v2 砍掉了大量 v1 内容）**：
   **本文不得以「v2 已经砍掉了」为理由跳过任何 v1 条目的处置**——每一条 v1 内容都必须在 §二 出现，
   并给「结论 + 理由 + 去处」。**这是本档对「不许静默覆盖」的兑现方式**（§二 2.1 十九行 + §二 2.2 十二行，共 31 行）。
5. ⚠ **本修订新增的一条自我约束（文修-1 的长期效力）**：**本档此后不得出现把「无限 / 无界」归给 `.ccr` 自身能力的句子**。
   该义**只有一种合法表述**（裁-4 文修-1 原文）：

   > **`.ccr` stores a finite set of relations in an open, extensible relational universe.**

   新增章节若需表达该义，**一律用这一句**（或其中文对应「`.ccr` 本身有限，但 relation universe 是开放的」）。
   **引文不在此限**（引 v1/v2 原话时可以原样保留其措辞——见 §〇.7 的两类保留）。
