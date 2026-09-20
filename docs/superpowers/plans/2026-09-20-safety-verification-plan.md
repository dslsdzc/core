# 安全/验证方向计划（**纸面，未实施**）——13 类安全问题三态实核 + 七方向展开 + 施工序

- **性质**：规划文档。**零源码改动、零构建、不推**。
- **基线**：`develop@origin` = **`38e6c992`**（`psnmnrln`，落盘前现查；`docs(批8 (甲) 刀4) … (#152)`）。全文 `file:line` 均在该修订上实核。
- **设计意图真源**：`/tmp/briefs/safety-verification-raw.md`（维护者 2026-09-20 原话逐字，13 类安全问题时适表 + 7 方向 + 统一模型）。**本文件不改写它**，只做形式化展开 + 仓库锚定 + 施工序。
- **同批交叉引用**（**未读、未改**）：`docs/maintainer/design/execution-mapping-design.md`（异构执行域放置）· `docs/superpowers/plans/2026-09-20-mapping-layer-separation.md`（字节偏移抽象）——两份在 `38e6c992` 上**均不存在**（本文件落盘时仅按名交叉引用，不复制其内容）。
- **纪律**：三态标注一格一核（§1）；核不到即标「未核实」（§7）；不替维护者裁决（§5 只登记不裁定）。

---

## §0 结论前置

### 0.1 三条必须写在前面的读数

1. **「规约系统 0 实现」不成立（按字面）** —— CIC+SMT 通道确为 0，但 `#check`/`#ensure` **已端到端落地**（批 6，2026-09-17）：词法 `T_HASH`、语法产生式（`grammar/core.ebnf:35`）、parser（`parser.cr:1574-1615`）、checker 六码（`ast.cr:513-518`）、VC dump（`dump.cr:504`，`main.cr:140/258`）、34 档语料 + 48 项自测（`src/ci/run.sh:298-302`）。**愿景文档自身同句即含「requires/ensures 语法已入 .cr」**（`z-vision.md:25`）——字面自相矛盾。⇒ 正确写法 = 分列两态（§1 行 6）。

2. **字节权限层不是已有能力** —— 原文「字节权限层还能表达 Readable/Writable/Freeable」**被推翻**：`pointer-model.md:112` 的节标题自带「**（设计态）**」，`:118` 明写「**实现状态:设计态**(region-model.md §5)」；`grep` 全 `src/compiler/*.cr` 对 `perm_kind|PERM_|permission` **零命中**。⇒ [已设计未实现]，非可消费能力。

3. **「已有三 pass」为真，「三 pass 有效」需重定** —— 三文件确在（`ptr_analysis.cr` 356 行 / `region_check.cr` 169 / `provenance_verify.cr` 144），越界检查已实现；但**已登记的静默缺口至少三条**：全程序 alloc 追踪 64 上限后静默失效（`TODO #2026-09-17-19`，`ptr_analysis.cr:213`）· 逃逸三点中**两点零诊断**（`region_check.cr:102` 返回值被丢弃）· `B011` 在 `tests/` **零覆盖**。⇒ §4 把这三条排在**施工序最前**（可独立、零新设计）。
   - **其中「逃逸两点零诊断」性质 = 已登记未取号**（**非本计划新发现**）：`specs/2026-09-17-concurrency-model-design.md` §15.1 **row 8** 已先记载；而同表 **row 7** 同类缺口**已取号**（`TODO #2026-09-17-19`）——**同表同列、一行取号一行未取**，见 §1.5 与 §5 **C-2 专卡**。

### 0.2 本计划与仓库既有规划的关系（**最重要的登记项**）

仓库在 **2026-09-11 已有一份路线图定稿**：`docs/superpowers/specs/2026-09-11-semantic-safety-roadmap.md`（162 行，自述「路线图定稿（用户裁决：全部起草）」），它定死了**属性轴（7 轴）+ 四档义务（prove/enforce/proof-required/reject）+ policy 接口 + 放行/声明条目 schema**，并列出 **9 份设计 spec（S-A…S-E）**，其中：

| 原文方向 | 路线图已覆盖者 |
|---|---|
| §2 authority/权限 | **S-B2** `2026-09-11-policy-authorization-design.md`（已定稿）· `authority` 轴（roadmap:33） |
| §3 信息流 | **S-B3** `2026-09-11-policy-information-flow-design.md`（已定稿）· `secrecy`/`integrity` 轴（roadmap:33）· `declassify`（roadmap:37） |
| §1 并发 | **S-E** `2026-09-11-merge-semantics-design.md` + `2026-09-17-concurrency-model-design.md`（689 行，13 门全裁） |
| §7 availability | 部分：`D_resource` 轴（roadmap 轴族）· S-C 成本模型 |
| §6 规约 | 与 `spec-design.md` v2 同一对象（本文件 §1 行 6 分列两态） |

**⇒ 本文件不新增设计**：它的价值 = 把维护者原话逐条落到**当前仓库的三态读数**上，并把施工序排成可开工的顺序。**路线图未提及的原文新增项 = CFI（§4）· trust boundary report（§5）· 时间三值化之外的 timing 面**——这三项才是真正的新增面。

---

## §1 13 类安全问题：三态逐格实核读数

**标注规则**（严格定义，防止「设计得很完整」被读成「快做完了」）：

- `[已实现]` = 在 `develop@origin` 上 `file:line` 实核到**可运行的代码路径**（含自测/语料判据）；
- `[已设计未实现]` = 仓库有设计文档或规划，`src/` **零实现**（给出处文件 + 行）；
- `[提案]` = 无对应物。

**「维护者原表」列** = `/tmp/briefs/safety-verification-raw.md:15-29` 的「当前状态」格**逐字**（不改写）。

| # | 安全问题 | 维护者原表「当前状态」 | 本计划三态 | 实核锚点（`file:line`） |
|---|---|---|---|---|
| 1 | 空间/时间内存安全 | 已有实现主体 | `[已实现]`（**带 1 条已登记静默缺口**） | `provenance_verify.cr:52-133`（越界：静态 `:88-96` / 运行时回填 `:117-129`）· `test_pointer_safety.py`（**16** 个 `test_*`，含 4 个动态运行时 trap 例）· **缺口** = `TODO #2026-09-17-19` |
| 2 | 指针 provenance / 越界 / UAF | 已有三 pass | `[已实现]`（**覆盖面窄于字面**，见 1.2 三条） | `ptr_analysis.cr`（356 行）· `region_check.cr`（169）· `provenance_verify.cr`（144） |
| 3 | 并发 data race / 原子性 | HDFG/state edge 有基础，还需完整 checker | **混合**：state edge `[已实现]`（**单执行体程序序链**）· 并发语义规格 `[已设计未实现]` · race checker `[提案]` | `dataflow.cr:156-173`（`df_connect_state`）· `:207-256`（`df_replay_state_chain`）· `:238`（每函数单链头）· `specs/2026-09-17-concurrency-model-design.md`（689 行） |
| 4 | 权限 / authority 泄漏 | 已有设计基础，治理层未完全落地 | `[已设计未实现]` | roadmap:33（`authority` 轴）· `specs/2026-09-11-policy-authorization-design.md`· **`src/compiler` 零命中** |
| 5 | FFI/MMIO/unsafe 边界 | 已有明确边界模型 | **混合**：unsafe 语法 + 三 pass 感知 `[已实现]` · 边界模型文档在 · **`alloc_at` `[已设计未实现]`** | `grammar/core.ebnf:90`·`ir_gen.cr:3146`·`ptr_analysis.cr:15-27`/`region_check.cr:13-27`/`provenance_verify.cr:36-50`·`pointer-model.md:92-110`·`alloc_at` 零命中 |
| 6 | 功能正确性 / 安全不变量 | CIC+SMT 方案已设计，当前还未实现 | **混合**：`#check`/`#ensure` C1 切片 `[已实现]` · CIC+SMT 通道 + `.csr` + 翻译桥 + 内核 `[已设计未实现]` | 见 §1.2 行 6 分列 |
| 7 | 信息流 / 机密数据泄漏 | 需要新增 pass | `[已设计未实现]`（**非新增提案**） | `specs/2026-09-11-policy-information-flow-design.md`·roadmap:33/37·**`src/compiler` 零命中** |
| 8 | 控制流完整性 CFI | 可从图和目标集合自然推导 | `[提案]`（**且前置载体缺失**，见 1.3） | `ast.cr:558`（`IR_CALL` 唯一）·`CALL_INDIRECT` 全仓零命中·`ir_gen.cr:2133`·`checker.cr:4180` |
| 9 | 资源耗尽 / DoS | deployment quota + termination/resource proof 可做 | `[已设计未实现]`（**两部分皆设计态**） | `execution-model.md:178`（§五 自述设计态）、`:197-199`（§5.3 配额）· `spec-design.md:148-157`·**`grammar` 零命中** |
| 10 | 整数溢出 / 除零 / 数值异常 | 可由图分析+规约处理 | **部分消解**：溢出 = 语言语义上**已无对象** · 除零 `[提案]` | `adr-0012-int-unbounded.md`（accepted）·`spec-design.md:322`（2026-08-23 修订）·`checker.cr:4468` |
| 11 | timing / cache side-channel | 困难但可建模 | `[已设计未实现]` | roadmap:86（`D_timing` 三值化）·`specs/2026-09-11-performance-without-commitment-design.md` |
| 12 | Spectre 类微架构攻击 | 不能靠语言单独解决 | **非目标**（与 roadmap §1.3 第 2 类同归） | roadmap §1.3（「恶意/失陷外部实体」） |
| 13 | 依赖投毒 / 供应链 | 不是语言本体问题 | **非目标**（同上） | roadmap §1.3 第 2 类 |

### 1.1 被**推翻**或**需重定**的格（最有价值的部分）

| 格 | 维护者原话 | 实核 | 判定 |
|---|---|---|---|
| 字节权限层 | 「字节权限层**还能表达** Readable/Writable/Freeable 等权限」 | `pointer-model.md:112` 标题自带「（设计态）」；`:118`「实现状态:设计态」；`src/compiler` 对 `perm_kind\|PERM_\|permission` **零命中** | **推翻**：从「已可表达的能力」降为 `[已设计未实现]` |
| 规约系统 | 「仓库当前愿景文档仍明确写着规约系统是 **0 实现**」（原文自述为「需要区分」） | CIC+SMT 通道确 0（`.csr` 在 `src/` 零命中）；但 `#check`/`#ensure` **C1 已实现**；`z-vision.md:25` 同句内含「requires/ensures 语法已入 .cr」 | **部分推翻**：须分列「C1 子集已实现 / CIC+SMT 未实现」；「0 实现」按字面为假 |
| 三 pass 覆盖面 | 「PointerAnalysis + RegionCheck + ProvenanceVerify 已经分别覆盖**来源**、**生命周期**和**边界**」 | 见 1.2 | **需重定**：三词对应关系成立，但「来源」的过程间部分为保守桩 · 「生命周期」的逃逸三点 2/3 零诊断 |
| state edge「有基础」 | 「HDFG/state edge **有基础**，还需完整 checker」 | `dataflow.cr:156-173`：入链判据 = 改内存或调不纯函数；`:207-256` 每函数**单链头**（`:238` `g_last_state_node = -1`）；**无执行体/线程维度** | **方向属实、力度高估**：race 判定的 `Concurrent(A,B)` 合取项**当前不可从图上导出**（见 1.4） |
| authority「未完全落地」 | 「已有设计基础，治理层**未完全落地**」 | `src/compiler` 对 `authority`/capability **零命中**；且 `memory-model-capability-lattice` v4 的 **M1 定论 = 「能力不提升一等公民，授权归治理层」**（`roadmap:17` 引用）——即「治理层」是**刻意的语言层之外**，不是「没做完」 | **需重定**：是 **0 实现 + 有意分层**，不是「落地七成」 |

### 1.2 三 pass 实际证明什么 / 漏什么（对应原文「已有三 pass」）

| Pass | 实际证明 | 实际**漏**（实核） |
|---|---|---|
| **PointerAnalysis**<br>`ptr_analysis.cr` | Andersen 式 inclusion 约束的**过程内**求解（`Addr/Copy/Store/Load` 四规则，`:204-339`）；`g_offsets` 常量偏移精确求值（`:230-297`） | ① **过程间是保守桩**：`IR_CALL` → `pts=0`（`:316-319`），头注 `:7-13` 声称 "interprocedural function summaries" **与实现不符**（`TODO #2026-09-17-20(b)` 已登记）；② **64 上限**：`:213` `if g_pa_alloc_count < 64` ⇒ 第 65 个分配起**不登记、零诊断**（`TODO #2026-09-17-19`，判 **S 静默**）；③ 计数器不在 `reset_frontend_state` 复位 ⇒ 长驻进程**跨编译消耗额度**（同条，team-lead 定性「比上限本身更严重」）；④ 迭代上限 `iter >= 10`（`:188`） |
| **RegionCheck**<br>`region_check.cr` | ① **DEREF 悬垂**（`:115-144`）→ `EC_B_LIFETIME`（`:134`）；② **返回逃逸**（`:59-92`）→ `EC_B_LIFETIME`（`:83`） | ① **存储逃逸零诊断**：`rc_store_escape`（`:94-103`）调用 `rc_pts_has_escaped` 后**丢弃返回值**（`:102`，注释自承 "simplified check"），全函数**无 `check_error`**；② **传参逃逸零诊断**：`rc_pts_has_escaped`（`:34-57`）**唯一调用者**即上述 `:102` ⇒ 该检查**整条死**；③ 全文件仅 2 处 `check_error`（`:83`/`:134`）；④ `tests/selfhost/*.py` 对 `B011`/`lifetime` **零覆盖**；⑤ `pointer-model.md:78` 仍把「存储逃逸」列为三点之一（**文档 vs 实现漂移**）。⇒ **本条已被先记载**（该规格 §15.1 row 8，无 TODO 号）——见 **§1.5** 与 **§5 C-2 专卡** |
| **ProvenanceVerify**<br>`provenance_verify.cr` | ① `DEREF`/`STORE_PTR` 的**越界**（偏移 + 宽度 vs 分配大小）：静态可判定 → `EC_TK_INDEX`（`:88-96`）；不可判定但目标唯一 → 回填运行时检查（`:117-129`）；② **外部指针解引需 unsafe**（`:66-73`）→ `EC_TU_DEREF` | ① 只覆盖 `DEREF`/`STORE_PTR` 两 op（`:62`）；② 分配信息未知时**不填充**运行时检查且**零诊断**（`:108-111`，仅注释说明保留 null 陷阱）；③ 多目标时 `runtime_targets > 1` → `EC_TK_INDEX`（`:125-129`）＝**报错**而非精确检查 |

> **对「三 pass」的一句判决**：三 pass 的**结构性骨架在**（约束求解 → 逃逸 → 边界，三层分工清楚），但**至少 3 处安全网静默失效**（1.2 表①②③与 §1.1 表）——这正是本计划 §4 把「收口」排在**最前**的理由。

### 1.3 CFI 的前置缺失（对应原文 §4）

原文称 `possibleTargets(callsite)` 可「从图分析出」，「比符号表猜测更精确」。实核：

- **IR 层无间接调用 opcode**：`ast.cr` 的 opcode 表中 `IR_CALL = 4`（`:558`）是**唯一**调用 opcode；全仓 `grep CALL_INDIRECT` **零命中**。
- **函数地址无 provenance**：`@addr(fn)` 求值为 `int`（`ir_gen.cr:2133`；`checker.cr:4180` 注明「function address, **type int**」），而 `ptr_analysis` 的 pts **只跟踪 `IR_ALLOC_STRUCT`/`IR_ALLOC_ARRAY` 节点**（`:205-222`）⇒ **int 型的函数地址不进 pts、无 provenance 边**。
- ⇒ `possibleTargets` **当前不可从图上导出**；本项不是「自然推导」，而是**需先补间接调用/函数指针的图表示**（新 opcode 或新节点类 + 其 pts 语义）——属**前置缺失**，不是增量接线。这解释了为何 §4 把它排在最后。

### 1.4 race 判定的当前可导性（对原文 §1 三元式的核对）

原文三元式：`Concurrent(A,B) ∧ Conflict(A,B) ∧ ¬Ordered(A,B) ⇒ Race`。

| 合取项 | 当前图上可导出？ | 依据 |
|---|---|---|
| `Conflict(A,B)`（write/write 或 read/write） | **是**（部分）：`IR_STORE_PTR`/`IR_STORE` 为写、`IR_DEREF`/`IR_LOAD` 为读；地址同一性经 `g_pts` + `g_offsets` 判定 | `ptr_analysis.cr:299-339`（pts/offset 表即现成载体） |
| `Ordered(A,B)`（存在 state 边路径） | **是**：kind=1 状态边 + 其传递闭包 | `dataflow.cr:156-173`·`:171`（`df_add_edge_kind(…, 1)`） |
| `Concurrent(A,B)` | **否** | state 链**每函数单头单链**（`dataflow.cr:238`），无执行体（goroutine/fiber）维度；`go expr`（`parser.cr:645`·`ir_gen.cr:1885`）生成的体与主链**无隔离维度** ⇒ 「并发」在图上**无表示** |

> ⇒ race 方向的工作量**不在 checker**，而在**给图加执行体维度**（= 原文所称「HDFG/state edge 有基础」的**真实缺口面**）。这与 `specs/2026-09-17-concurrency-model-design.md` 的范围重叠（该规格已 689 行、13 门全裁，**原文未提及它存在**）。

### 1.5 与 2026-09-17 定稿设计的交叉核对（本计划读数的独立佐证）

`docs/superpowers/specs/2026-09-17-concurrency-model-design.md` §15.1「**已有设施（事实清单）**」（`:385-400`，12 行）**独立复述了本计划的多条读数**。按「谁先记载」列如下（**该表先于本计划**，起草于 2026-09-17，本计划落于 2026-09-20）：

| 本计划读数 | 该表对应行 | 关系与时序 |
|---|---|---|
| §1.2 PointerAnalysis 三项（intra-procedural 桩 · 64 上限 · 计数器不复位） | **row 7**（`:396`，结尾「⇒ **已立 `TODO #2026-09-17-19`**」） | **该表先记载**；本计划**独立复核确认**（见下方坐标重定） |
| §1.2 RegionCheck「存储逃逸丢弃返回值 ⇒ 无诊断路径」 | **row 8**（`:396`，**结尾无 TODO 号**） | **该表先记载**——即 **C-2 不是本计划的新发现，是「已登记未取号」**（见 §5 C-2） |
| §1.4 `Concurrent` 不可导 | **row 12**（`IR_YIELD`/`IR_AWAIT` 在 interp 与 ELF **皆 no-op** ⇒「**今日无跨执行体值通道语义**」）· **row 6**（state edges「只有「序」没有「交换性」；无 ReadSet/WriteSet」）· **row 8**（「无跨执行体概念」） | 该表**更强**（给出 opcode 级证据）；据该表，本计划未独立复核 |
| §1.1 字节权限层为设计态 | **row 4**（arena「无 size class、无 split、无跨 arena 迁移、**无页权限（COW/冻结）**、无预留」） | 该表佐证；据该表，本计划未独立复核 |
| §1.3 CFI 前置缺失 | row 12 记 `IR_FNADDR=48` 存在，但**无间接调用 opcode** 条目 | 与该表一致，未冲突 |

**坐标重定（该表的行号已相对当前基线陈旧）**（承「复核任何清单的第一步 = 把它的声明基线换成当前基线」）：

| 该表 row 7 的声明 | 在 `38e6c992` 上实测 | 判定 |
|---|---|---|
| `reset_frontend_state` = `globals.cr:509-540` | 实为 **`globals.cr:552`** | **行号陈旧** |
| 「复位了 `g_alloc_pts_cap:538`」 | 实为 **`globals.cr:584`**（函数体内 `g_alloc_pts_cap = 0;`） | **行号陈旧** |
| 「却未含 `g_pa_alloc_count`」 | **实质成立**：`g_pa_alloc_count` 全仓仅 2 处出现——声明 `globals.cr:398` + 唯一写点 `ptr_analysis.cr:217`；`reset_frontend_state` 体内**无它** | **实质确认**（行号需重定，结论不变） |

> **⇒ 一句话**：本计划 §1.1/§1.2/§1.4 的读数与 2026-09-17 定稿设计的 §15.1 事实清单**一致**；其中 **C-2（RegionCheck 存储逃逸）该表 row 8 已先于本计划记载**——本计划的作用是把它的**处置状态**（无号）与**同行邻居的处置**（row 7 有号）并列出来（§5 C-2）。

---

## §2 统一模型：原文展开为「图上的可证明约束」

原文统一模型（`/tmp/briefs/safety-verification-raw.md:259-296`）为三层流 + 一个 Trust Boundary。下表把它**逐项展开成约束式 + 仓库锚点 + 可判性状态**（约束式一律写成「图上的可证明约束」形态）：

| 流 | 性质 | 图上约束式 | 仓库锚点 | 当前可判性 |
|---|---|---|---|---|
| **Value Flow** | provenance | `∀ p ∈ Ptr : pts(p) ≠ ∅ ⇒ origin(p) ∈ Allocs` | `ptr_analysis.cr:205-222`（pts 位图 + `g_pa_alloc_nodes` 映射） | 可判（过程内）；过程间保守 |
| | bounds | `∀ d ∈ DEFEREF∪STORE_PTR : 0 ≤ off(d) ∧ off(d)+width(d) ≤ size(alloc)`，`alloc ∈ pts(d.s1)` | `provenance_verify.cr:88-96`（静态）`/ :117-129`（运行时回填） | 可判（已实现） |
| | lifetime | `∀ d : use_interval(d) ⊆ live_interval(alloc)`，`alloc ∈ pts(d.s1)` | `region_check.cr:115-144`（SG exit 比较） | 部分（2/3 逃逸零诊断，见 1.2） |
| **State Flow** | concurrency | `Concurrent(A,B) ≜ ¬(A ─hb→ B) ∧ ¬(B ─hb→ A)` | **无执行体维度**（`dataflow.cr:238`） | **不可判**（前置缺失） |
| | ordering | `Ordered(A,B) ≜ A ─state*→ B ∨ B ─state*→ A` | `dataflow.cr:156-173` | 可判（已实现） |
| | atomicity | `#atomic(a,b) ⇒ ∀ o ∈ Obs : ¬(a ─hb→ o ∧ a ≺ o ≺ b ∧ o ─hb→ b)` | `spec-design.md:157`（`#atomic` 只在标签表） | **不可判**（标签未实现） |
| **Authority Flow** | permission / effect | `E(f) = ⋃_{n ∈ body(f)} eff(n) ∪ ⋃_{c ∈ calls(f)} E(c)`；判定 `E(f) ⊆ Allowed(module)` | **接缝**：`checker.cr:4508`（`purity_op_effect`，**opcode→效应单源表**）·`:4555`（`compute_all_purity`，**沿调用图传播**） | **可扩展**（表已存在，当前值域 = 布尔） |
| | information flow | `label(v) = ⊔_{u ∈ pred(v)} label(u)`；`FlowLabel(src) ⪯ AllowedLabel(sink)`；`declassify` = 唯一重设点 | 无实现；设计 = `specs/2026-09-11-policy-information-flow-design.md` | **可判子集存在**（值流 `pred` 就是 HDFG 的入边） |
| **Trust Boundary** | 边界归档 | `TrustedSurface = {unsafe} ∪ {FFI} ∪ {MMIO} ∪ {external input} ∪ {hardware contract} ∪ {unverified backend}` | `grammar/core.ebnf:90`·`ir_gen.cr:3146`（`SG_UNSAFE`）·`pointer-model.md:92-110` | **部分可枚举**（unsafe/FFI 有载体；见 §5 方向 5） |

**「只把不可证明的部分留下为显式信任边界」**（原文结语）的机械形态 = **边界清单可枚举 + 每条有出处**——这正好是原文 §5 的 Trust Boundary Report，也是本方向唯一**不需要新分析**、纯靠既有结构就能产出的东西。

---

## §3 七个方向：不变量 / 判据形状

**格式**：每条给「图上约束式 → 判据形态（怎么算做完）→ 现有接缝 → 规模」。

### 方向 1：并发安全（data race / atomicity）

- **约束式**：见 §1.4 三元式；原子性见 §2 表 State Flow 行。
- **判据形态**：① **正控** = 语料中「同址写写」且无 state 边 → 必须报；② **负控** = 有 state 边的同址读写 → **不得报**（反向钉子）；③ 显式并发源（`race`/`select_any`，见 S-E）→ 落**报告面**不报错；④ 隐式竞争 → reject。
- **接缝**：`dataflow.cr`（state 链，需加执行体维度）· `ptr_analysis.cr`（同址判定复用 pts/offsets）· 新增 pass 与三 pass 同级。
- **规模**：**大**（图表示变更 + 新 pass + 语料）。且与已定稿的 `2026-09-17-concurrency-model-design.md` 强重叠——**开工前须先裁「沿用该规格还是另起」**。

### 方向 2：Authority / 权限（effect confinement）

- **约束式**：`effects(f) ⊆ {memory.read}`（原文例）；一般式 `E(f) ⊆ Allowed(module)`。
- **判据形态**：① **正控** = 标注 `#allow(memory)` 的函数体内出现 `network.send` 边界节点 → rc=1 且报出**具体边**（`decoder → network.send`，原文要求「直接拒绝」）；② **负控** = 合法集合内调用 → 不报；③ 效应集合须**沿调用图传递闭包**（防「经中间函数绕过」——这正是本仓 `#2026-09-17-20` 类漏检的高发形态）。
- **接缝**：**最好的一条**——`purity_op_effect`（`checker.cr:4508`）已是「opcode→效应」的**唯一真源表**（`dataflow.cr:157-163` 注释明写 D7「效应清单收敛为一份」）；`compute_all_purity`（`:4555`）已做沿调用图传播。**扩展方向 = 值域由布尔升为效应集合**，不新增第二张表。
- **规模**：**中**（表扩容 + 标注语法 + 集合判定）。**低风险**：不动发射面。

### 方向 3：信息流（confidentiality）

- **约束式**：`label(v) = ⊔_{u ∈ pred(v)} label(u)`；`FlowLabel(source) ⪯ AllowedLabel(sink)`；格 = `Public → Sensitive → Secret → TopSecret`（原文）≡ roadmap `secrecy` 轴。
- **判据形态**：① **正控** = `password ──→ log`（原文例）→ 报；`password ──→ hash` → **不报**（hash 视为降密？**此点须裁**，见 §6）；② `secret → network.public` → 报；③ `declassify` 边界 → 不报（**唯一合法通道**）；④ **隐式流**（branch 上的 secret 影响非 secret 输出）—— roadmap 已把隐式流列入 S-B3 的「可判定子集」边界。
- **接缝**：值流 `pred` **就是 HDFG 入边**（`dataflow.cr` 的 DFEdge）⇒ 传播可用现成的图遍历；**零新 IR op**（标签可作图标注/侧表）；`declassify` 可复用 `#` 标注通道（`parser.cr:1574-1615` 已能解 `#name(expr)`，新增 kind 即可）。
- **规模**：**中小**。**最独立**：不依赖并发、不依赖 authority、不依赖引擎判定扩展。

### 方向 4：CFI

- **约束式**：`possibleTargets(cs) ⊆ allowedTargets(cs)`（原文）；统一为 `Control provenance`（原文 §4 末三行）。
- **判据形态**：**当前写不出**——见 §1.3，`possibleTargets` 的前置载体（间接调用表示 + 函数地址 provenance）缺失。
- **接缝**：需新增 opcode 或节点类；后端需生成 `target ∈ allowedTargets` 检查。
- **规模**：**大**（前置缺失，非增量）。

### 方向 5：unsafe 作为真正的 trust boundary（Trust Boundary Report）

- **约束式**：`TrustedSurface` 可枚举 + 每条有出处（§2 表末行）。
- **判据形态**：① `corec` 输出结构化报告（unsafe 块数 / FFI 入口数 / MMIO / 未核验后端 / 未核验假设）；② **正控** = 语料含 3 个 unsafe、2 个 FFI → 读数 3/2；③ **负控** = 零 unsafe 的程序 → 读数 0（防空扫假阳）；④ 每条须能**回溯到源坐标**。
- **接缝**：`SG_UNSAFE` 区已建（`ir_gen.cr:3146`）且三 pass 均能枚举（`ptr_analysis.cr:15-27` 的 `pa_in_unsafe` 就是「枚举 unsafe 区」的现成代码）；结构**已足够**，只差一个报告出口。
- **规模**：**小**。**最高性价比**：零新分析、零发射面变更，纯读取既有结构 + 新 CLI 出口（先例 = `--dump-vcs`，`main.cr:258`）。

### 方向 6：规约系统（业务逻辑不变量）

- **约束式**：`∀ 可达状态 s : G(s) ⊨ P`（原文「证明图的所有可达状态满足图上的约束」）；实现侧 = 翻译到 CIC + SMT 证书。
- **判据形态（分两层，须分别写）**：
  - **C1（已实现面）**：`#check(常量假)` → rc=1 + 零产物（`V01`，`checker.cr:4468`）；其余标注 → 三态（绿/黄/红）不阻断（`ast.cr:521-523`）。判据已在：`test_spec_grammar.py`（48 项）+ `tests/spec/`（34 档）+ `run.sh:298-302`。
  - **CIC+SMT（未实现面）**：绿 = 内核验证通过的证明项；黄 = 部分；红 = 反例或未证（`spec-design.md:380`）。
- **接缝**：`#` 标注通道已通（parser/checker/dump 三处）；缺失 = 编图（裁-S4「本刀不编图」）、`.csr`、翻译桥、内核绑定（`spec-design.md:526-532` 五里程碑**全部未启动**）。
- **规模**：**极大**（CIC 内核 + SMT 证书 = 多年期）。

### 方向 7：Availability / DoS

- **约束式**：`∃ 变体 μ : 每循环迭代 μ 严格递减 ∧ μ 有下界`（终止性）；`alloc_count ≤ N ∧ maxMemory ≤ M`（配额）。
- **判据形态**：① 终止性 —— `#terminating` 需 `variant` 语法，**`grammar` 现为零命中**（`spec-design.md:46/288/306` 三处 2026-09-16 修订均已记「EBNF 尚未定义——待实现」）；② 配额 —— 落在**部署层**（`execution-model.md:197-199`「可选声明，不声明即无限制」），**静态证明未设计**（原文提议的 `maxMemory(...)`/`maxIterations(...)` 在仓库无对应物）⇒ 该子项才是 `[提案]`。
- **接缝**：`#` 标注通道（同方向 6）+ 部署配置读取（`project.cr`）。
- **规模**：终止性 = **大**（变体语法 + 良基递归判定）；配额证明 = **中**（若走「图上界」路线，region 结构可提供分配次数上界）。

---

## §4 施工序（可开工顺序）

**排序原则**（来自任务要求，非我的偏好）：**先做的必须能独立**——不排成「必须一起做」。原文建议的三项（race/authority/information-flow）**独立性并不相同**（见 §1.4 与下方 P1/P2/P3 的前置栏），故本表**按独立性**而非按原文列举顺序排。

### P0 —— 收口已登记的静默缺口（**零新设计、零语义争议、可立即开工**）

> 理由：这三条都是**已登记、已定性（S = 静默）**、且**不动设计**的缺陷。在它们收口前，「内存安全已成形」这个前提本身是虚的——而它是原文全部推理的起点（`/tmp/briefs/…:11`）。

| 序 | 任务 | 前置依赖 | 判据形态 | 与现有 pass 的接缝 | 预估规模 |
|---|---|---|---|---|---|
| **P0-1** | `ptr_analysis` 64 上限 + 计数器不复位（`TODO #2026-09-17-19`） | **无** | ① RED：>64 个分配的语料，第 65 个上带可判定越界 → 修复前观测「≤64 对照有诊断 / ≥65 无诊断」的**静默差**；② pts 表示升级后该差消失；③ `g_pa_alloc_count` 随 `reset_frontend_state` 复位（长驻进程同源重复编译**读数一致**）；④ 三点 pass 既有判据逐项不变 | `ptr_analysis.cr:213`（上限）·`globals.cr` 的 `reset_frontend_state`（复位）·`region_check.cr:122-143`+`provenance_verify.cr:77-129`（受影响消费点） | 中 |
| **P0-2** | `region_check` 存储/传参逃逸零诊断（`region_check.cr:102` 返回值丢弃） | **先裁一项**：该检查是「有意简化（有契约）」还是「静默谎（无契约）」——**本计划不裁决**（§5 C-2） | 若裁为「缺陷」：**两向钉子**——真逃逸必须报 + 合法返回/传参**不得**报；若裁为「有意简化」：`pointer-model.md:77` 的「三点」表述须改，并在豁免表登记 | `region_check.cr:34-57`/`:94-103`；文档 `pointer-model.md:73-79` | 小 |
| **P0-3** | `B011` 零测试覆盖 → 补判据网 | 无 | 返回逃逸 + DEREF 悬垂（两条**已在报**的路径）各至少 1 正控 + 1 负控 | `tests/selfhost/test_pointer_safety.py`（**16** 个 `test_*`，**全为 bounds/unsafe 面，无 lifetime 面**）· 全 `tests/` 对 `B011`/`lifetime` **零命中** | 小 |
| **P0-4** | 文档漂移同步（`pointer-model.md:87` 错误码写错：越界实报 `EC_TK_INDEX` 非 `EC_TU_DEREF`；§1.2 表所列三处） | 无 | 逐条 `file:line` 复核 + 改文档（**只改事实，不改设计**） | 纯文档面 | 小 |

### P1 —— 信息流（**最独立**：不依赖并发、不依赖 authority、不依赖引擎扩展）

- **前置依赖**：无（值流即 HDFG 入边；标注通道 `#` 已通）。**唯一待裁** = 「派生值是否自动继承秘密性」（§6 未决 U-1）。
- **判据形态**：见 §3 方向 3 的 ①②③④（含**负控**：`password → hash` 必须不报）。
- **接缝**：新增 pass（与三 pass 同级，读 `g_df_nodes`/DFEdge）；标签落侧表（先例 = `g_spec_*`，`globals.cr:298-307`）；`declassify` 复用 `#` 标注通道（`parser.cr:1588-1593` 的 kind 分派处加一支）。
- **规模**：中小。**为何排 P1**：它是原文三项中唯一**不需要动图表示**的（`Concurrent` 那条需要，见 §1.4），且「义务不静默」可独立验证。

### P2 —— Authority / effect confinement（**次独立**：接缝最好，但需先裁一处）

- **前置依赖**：裁「效应集合怎么进图/类型项」（roadmap 把 `authority`/`effect` 归到 S-A 的轴机制；若沿用，则依赖 S-A 最小切片；若走「纯函数摘要」路线，则**不依赖 S-A**——**两条路都可开工，须择一**，本计划不裁决）。
- **判据形态**：见 §3 方向 2 的 ①②③（**③ 传递闭包是重点**）。
- **接缝**：`checker.cr:4508` `purity_op_effect`（唯一真源表）+ `:4555` `compute_all_purity`（沿调用图传播）——**现成，只需值域扩容**。
- **规模**：中。**风险点**：`purity_op_effect` 是**双消费点共用表**（`dataflow.cr:163` 的 state 链分类 + 纯度判定），扩容须保证**两个消费点同改**，否则两条判据漂移（这正是该表 D7 收敛要防的）。

### P3 —— 并发 data race / atomicity（**最不独立**）

- **前置依赖**（三条，缺一不可）：① 图需**执行体维度**（§1.4：`dataflow.cr:238` 单链头 ⇒ `Concurrent` 不可导出）；② 裁「沿用 `2026-09-17-concurrency-model-design.md`（689 行定稿）还是另起」；③ S-A 的 `determinism` 轴族（roadmap §1.4）——**否则「隐式竞争 → reject」这个执法点无处落**。
- **判据形态**：见 §3 方向 1 的 ①②③④（**② 反向钉子最关键**：有 state 边不得报）。
- **接缝**：`dataflow.cr`（state 链）· `ptr_analysis.cr`（同址复用 pts/offsets）· `sched.cr`/`chan.cr`（运行时而非检查面）。
- **规模**：大（图表示变更 + 新 pass + 语料）。**为何排最后**：它是原文三项中唯一「前置在别处」的。

### P4 —— Trust Boundary Report（**可与 P1/P2 并行，零冲突**）

- **前置依赖**：无。
- **判据形态**：见 §3 方向 5 的 ①②③④（**③ 零 unsafe 负控**是防空扫的关键）。
- **接缝**：`SG_UNSAFE` 枚举代码已存在（`ptr_analysis.cr:15-27`）；出口照 `--dump-vcs` 先例（`main.cr:140/258`）。
- **规模**：小。**为何列入**：它是原文统一模型里**信噪比最高**的一块（把「审 100 万行」变成「审边界清单」），而成本是**读已有结构**——性价比远高于 P3，故**不因排位靠后而推迟**。

### P5 —— 规约 CIC+SMT 通道 / Availability 证明 / CFI（**明确不排期**）

- 三者分别受制于：CIC 内核绑定（多年期，`spec-design.md:526-532` 五里程碑全未启动）· `variant` 语法未定义（`grammar` 零命中）· 间接调用表示缺失（§1.3）。
- **处置**：**登记不排期**，理由各见 §3 方向 6/7/4。**不建议作为下一批开工对象**。

### 施工序总图

```
P0（收口静默缺口，零新设计）──┬─ P1 信息流（最独立）
                              ├─ P2 Authority（接缝最好，须先择路）
                              └─ P4 Trust Boundary Report（小、可并行）
                                     │
                                     └─→ P3 data race（前置三缺一不可）
P5（CIC+SMT / Availability / CFI）＝ 登记不排期
```

---

## §5 冲突登记（**逐条列出 + 核实结论；不替维护者裁决**）

| # | 冲突 | 原文/文档处 | 实核结论 | 处置建议（**待裁**） |
|---|---|---|---|---|
| **C-1** | 「规约系统 0 实现」 | `z-vision.md:25`·`project-book.md:84` | **按字面为假**：C1 切片已端到端实现（§1 行 6 锚点）。`z-vision.md:25` 同句内自含「requires/ensures 语法已入 .cr」（**文档内部自相矛盾**）。`project-book.md:84` 的「零实现」**限定于 `.csr` 序列化**——该限定**成立**（`src/` 对 `.csr` 零命中） | 分列两态「C1 已实现 / CIC+SMT 未实现」；两处文档改写（**涉及已存在文档正文，须维护者许可**，本计划不擅自改） |
| **C-2** | 「逃逸三点检查」（存储/传参逃逸） | `pointer-model.md:73-79`（列三点） | **两点零诊断，且已被先记载**——**性质 = 已登记未取号**，**非本计划新发现**（详见下方 C-2 专卡） | 见 C-2 专卡 |
| **C-3** | 字节权限层「还能表达」 | 原文 `:11` | `pointer-model.md:112` 标题「（设计态）」·`:118`「实现状态:设计态」·`src/compiler` 零命中 | 改原文表述为 `[已设计未实现]`（原文在 `/tmp`，**不改**——本文件登记即可） |
| **C-4** | 「已有三 pass」的覆盖面 | 原文 `:11,18` | 三 pass 文件在；但过程间为桩（`TODO #2026-09-17-20(b)` 已登记头注/`CLAUDE.md` 与实现不符）· 2/3 逃逸零诊断 · 64 上限静默 | 引用时须写成「三 pass 骨架在 + 三条已登记静默缺口」，**不得**直接引用为「来源/生命周期/边界已覆盖」 |
| **C-5** | 「state edge 有基础」的力度 | 原文 `:19` | 单执行体程序序链（`dataflow.cr:238`）；`Concurrent` 不可导出（§1.4） | 重定为「顺序面有基础，**并发维度无表示**」 |
| **C-6** | 「authority：治理层未完全落地」 | 原文 `:20` | `src/compiler` 零命中；且 M1 定论 =「能力**不提升一等公民，授权归治理层**」⇒ 语言层无能力是**刻意设计** | 重定为「0 实现 + 有意分层」，删去「未完全落地」的完成度暗示 |
| **C-7** | 「CFI 可从图自然推导」 | 原文 `:24/167` | 无间接调用 opcode（`ast.cr:558` 唯一 `IR_CALL`）· `@addr` 返 int 且无 pts ⇒ **前置缺失** | 明确为「需先补图表示」，不是增量接线 |
| **C-8** | 「FFI/MMIO/unsafe 已有明确边界模型」 | 原文 `:21` | unsafe 语法 + 三 pass 感知**已实现**（`grammar/core.ebnf:90` 等）；但 `alloc_at`（`pointer-model.md:102-110` 的声明式放置）在**整个 `src/`**（非仅 `src/compiler`）**零命中** | 拆成「unsafe 边界已实现 / `alloc_at` 设计态」 |
| **C-9** | 整数溢出「可由图分析+规约处理」 | 原文 `:26` | `int` 为无界数学整数（`adr-0012`，accepted；`spec-design.md:322` 2026-08-23 修订）⇒ **溢出在语言语义上已无对象** | 该行「图分析」对溢出**无对象**；除零仍未实现 |
| **C-10** | roadmap §4 的引用悬空 | `semantic-safety-roadmap.md:134` 等 | 引用的 `.superpowers/sdd/{decisions-sheet,safety-review-a,safety-review-b}.md` 在 `38e6c992` **不存在**（`.superpowers/` 全目录 **0 tracked 文件**） | 引用该路线图时**不得**据其编号（`D<n>`/`A 线 M1` 等）追溯——追溯面已断 |
| **C-11** | 文档错误码漂移 | `pointer-model.md:87` | 该行写「越界 → 编译错误(**EC_TU_DEREF** 错误码)」；实核越界报 **`EC_TK_INDEX`**（`provenance_verify.cr:91/99/126`），`EC_TU_DEREF` 只在 `:68` 用于「外部指针解引需 unsafe」 | 改文档（P0-4）。**附带**：`ast.cr` 中 `EC_TU_DEREF=7003` 注释义 =「Cannot deref non-ref」、`EC_TK_INDEX=10001` 注释义 =「Cannot index」——**两码被 pass 借用为不同语义**，新码设计时须避让 |
| **C-12** | 原文与 roadmap 的边界坐标系不同 | 原文 `:29` vs roadmap §1.3 | 供应链/Spectre：原文归「非语言本体问题」/「不能靠语言单独解决」；roadmap 归「不可消残留**第 2 类**（恶意/失陷外部实体）」。**结论一致、坐标系不同** | 施工序引用时**择一**，勿混用两套术语 |
| **C-13** | 新诊断码无家可归 | `diag.cr:86-104`（`error_cat_prefix`） | 现用 cat **1–17**（每类前缀见该函数）；cat ≥18 **落到默认分支 `"E"`**——与 cat 15 的 `"E"` **撞前缀** | 新增安全类码须**同时**：选新 cat 号 + 在 `error_cat_prefix` 加分支 + 评 `diag_gate_exempt` 是否需登记（`diag.cr:172-212`，现 build 面 5 条 + check 面 3 条） |

### C-2 专卡：`region_check` 两条逃逸检查无诊断路径（**供维护者一眼裁**）

**性质**：**已登记未取号**——事实已被先记载，但**未立 TODO 条目**。**故本项不是「新发现的缺陷」，是「处置状态缺一条」的问题。**

**① 事实（三样，逐样锚点；均在 `38e6c992` 上核）**

| # | 事实 | 锚点 |
|---|---|---|
| 1 | **被调函数的唯一调用者就是这里**（⇒ 不存在「另一条路在用」） | `grep -rn "rc_pts_has_escaped" .` 命中 14 处，**代码面仅 2 处**：定义 `region_check.cr:34` + **唯一调用点 `region_check.cr:102`**（其余 12 处 = 文档/伪代码/本计划自身） |
| 2 | **注释自承 simplified** | `region_check.cr:102`：`rc_pts_has_escaped(val_pts, ni, 0);  // simplified check`——整行即语句，**返回值未赋给任何变量** |
| 3 | **`pointer-model.md:73-79` 三点并列** | `:73` 列「`rc_pts_has_escaped` / `rc_return_escape` / `rc_store_escape`」· `:75` 传参逃逸 · `:76` 返回逃逸 · `:78` 存储逃逸；该文档 `:3` 自述状态 = active，且写明「本文描述的是**已实现行为**」 |

**② 增强事实（非必须，但更硬）**

- 被调函数 `region_check.cr:34-57` 体内 **`check_error` 计数 = 0**（只有 `return 1`/`return 0`）⇒ 该调用**无任何可观察效果**（函数纯 + 返回值丢弃 + 体内无诊断）。
- 全文件**仅 2 处 `check_error`**：`:83`（返回逃逸）· `:134`（DEREF 悬垂）⇒ **三点中只有第 2 点有产出**。
- **伪代码镜像照实记录**：`docs/pseudocode/compiler/region_check.md:191` 同记该行 + 注释「**// 简化检查**」⇒「丢弃」是**被有意镜像下来的**，非转写笔误。

**③ 先记载之处**（这一栏是裁量关键）

`docs/superpowers/specs/2026-09-17-concurrency-model-design.md` §15.1「已有设施（事实清单）」**row 8**（`:396`）已逐字记载：

> 区域检查 · `src/compiler/region_check.cr` · …存储逃逸调 `rc_pts_has_escaped` 但**丢弃返回结果**（`:102`）⇒ **无诊断路径** ‖ 「它做不到什么」列：无 liveness/use 集；**无跨执行体概念**

**④ 同行邻居的处置**（客观判别信号，在仓库内自证）

| 该表行 | 对象 | 条目结尾 |
|---|---|---|
| **row 7** | `ptr_analysis.cr`（同类静默缺口：64 上限 + 计数器不复位） | 「⇒ **已立 `TODO #2026-09-17-19`**」 |
| **row 8** | `region_check.cr`（本条 C-2） | **无任何 TODO 号** |

⇒ **同表、同列、同类静默缺口，一行取号、一行未取**。而 `TODO #2026-09-17-19` 对同类问题的定性原文是「**S（静默）**——安全网静默失效属本仓最忌类」。**若该政策是普遍的，row 8 按一致性应补一条号**——此判据比「有没有既有契约」（本仓另一条既有口径）更硬，**因为它就是本仓自己的既往处置**。

**⑤ 请裁两问（一句话式）**

1. 存储逃逸 / 传参逃逸是「**有意简化**」（→ 改 `pointer-model.md:75`/`:78` 表述 + 按豁免表登记）还是「**静默缺陷**」（→ 修 + 两向钉子）？
2. 若是后者：**是否按 row 7 先例补一个 TODO 号**？

> **本计划不裁决**：以上只并列事实与两条既有口径（「有无契约」与「row 7 先例」），**处置权归维护者**。

---

## §6 非目标（三类不排进施工序）

**共同理由**：它们**不是「现在不做」，而是「语言语义证明不了」**——roadmap §1.3 已把它们归为「**不可消的残留**」，并规定每份 spec 的「不承诺」节必须引用。原文与其结论一致（只说坐标系不同，见 C-12）。

| 类别 | 原文定性 | 为什么现在不排 | 将来入口 |
|---|---|---|---|
| **timing / cache side-channel** | 「困难但可建模」「需要额外威胁模型」（原文 `:27`） | 它**不是**「不可消残留」而是「可建模但需威胁模型」——`D_timing` 三值化（`roadmap:86`）已给出**不许撒谎**的呈现纪律（`MODELED` 不得当 WCET 呈现），但**模型本身未设计**；先做会产出无法判定的报告面 | roadmap S-C 成本模型（`specs/2026-09-11-performance-without-commitment-design.md`）+ `hw-map`（`specs/2026-08-23-hw-map-design.md`）——**成本模型落地之日**即入口 |
| **Spectre 类微架构攻击** | 「**不能靠语言单独解决**」「必须有硬件/backend 模型」（原文 `:28`） | 语言层无对应物可证明——roadmap §1.3 第 2 类（**恶意/失陷外部实体**）已定「用可复现构建/签名/provenance/最小权限**缩小**，不能用语言语义**证明**」 | **硬件合同**（原文统一模型的 Trust Boundary 第 5 项）——即有 `hardware contract` 载体之后；本仓现有边界模型（`pointer-model.md:92-110`）尚未含硬件合同条目 |
| **依赖投毒 / 供应链** | 「**不是语言本体问题**」「需要构建/签名/依赖体系」（原文 `:29`） | 同上（第 2 类）——语言能做的只有「缩小」；把构建/签名体系塞进语言本体 = 违反 roadmap §1.1 原则 2「**策略面归库，纪律面归语言**」与「**禁止**把某类漏洞做成内建特判（那是 lint 换皮）」 | **构建/签名/依赖体系**（本仓外）——可复用的是 `provenance` 概念（原文 §4 末「Authority provenance」的三统一），但那是**概念复用**，不是实现路径 |

---

## §7 未核实清单（**显式登记，不得据此推断**）

以下在 `38e6c992` 上**未亲自实核**，本文件凡引用处均以「引用」而非「实核」对待：

| # | 未核实项 | 原因 |
|---|---|---|
| U-1 | `docs/academic/cache-semantics.md` 条款 6/7、`docs/academic/verifier-kernel.md` 全文 | 只经二级引用（`pointer-model.md:4/136`、`spec-design.md:357`）接触，未读原文 |
| U-2 | S-A / S-B1 / S-B2 / S-B3 / S-B4 / S-B5 / S-C / S-D / S-E **九份 spec 全文** | 只读 roadmap 的清单行（`:104-112`）。其**实施切片细节、判据编号（`L<n>`）、验收门**未核 |
| U-3 | `2026-09-17-concurrency-model-design.md` 除 §0/§1/**§15.1**（`:385-400`，16 行）外的其余部分 | 只读头部 60 行 + **§15.1 事实清单表**——后者是为核实该表 row 7/8 的具体坐标而读其邻域（**非**系统性通读）。该表其余行（row 1-6/9-12）**其结论未独立复核**，本计划引用处均已标「据该表」 |
| U-4 | `docs/maintainer/proposals/` 下各提案（`distributed.md` 等） | 未列目录 |
| U-5 | `src/arch/x86_64/instr.cr` 的 DEREF/STORE_PTR 运行时检查**编码侧** | 只从 `provenance_verify.cr:56-60/117-129` 的注释知「回填 s2/s3」，未核发射 |
| U-6 | `src/stdlib/{sched,chan}.cr` 是否真无锁 | `TODO #2026-09-18-1` 称「SPSC 仅为 `sched.cr:2-3` 注释约定」——**未独立复核** |
| U-7 | `tests/probes/`（29 档）与 `tools/baseline/` 的**安全面覆盖度** | 未逐档核；本文件关于「覆盖为零」的断言**只针对 `B011`**（该条以 `grep` 实测） |
| U-8 | `spec/` 目录（与 `docs/` 并存的规格面）内容 | 未读 |
| U-9 | 13 类表中「适合度」列（非常适合/适合/部分适合…）的**技术判断** | 本文件只核「当前状态」列，**不评**适合度列 |
| U-10 | `alloc_at` 是否有 **bootstrap 侧**（Python）支持 | 只核了 `src/compiler/*.cr` |
| U-11 | 新诊断码所需的 cat 号是否存在**外部约定**（如 `tools/` 或 CI 对 cat 号的依赖） | 未扫 |

---

## §附 一句话总结（承原文结语）

> Core 尽可能把安全问题从「语言规则和程序员纪律」转化成「**图上的可证明性质**」，只把不可证明的部分留下为**显式信任边界**。

本文件的实核结论是：这条路线**骨架成立、且已有相当多的既有物**（三 pass 骨架 · `#` 标注通道 · 单一效应表 · state 链 · 区域结构）——但**当前状态下不能声称任何一条安全性质「已经完成」**，因为既存的静默缺口（P0 四项）尚未收口；而在原文建议的三项中，**只有信息流是可以立刻独立开工的**（并发需先给图加执行体维度，authority 需先择路）。

**一处性质更正（§1.5/§5 C-2）**：P0 四条中，「逃逸两点零诊断」**不是本计划的新发现**——`specs/2026-09-17-concurrency-model-design.md` §15.1 **row 8** 已先记载；问题在**处置状态**：同表 **row 7**（同类静默缺口）已取 `TODO #2026-09-17-19`，**row 8 未取号**。⇒ 该项**裁起来比修起来快**：先裁「有意简化 vs 静默缺陷」，再按 row 7 先例决定是否补号。

**本文件不实施任何改动**：零源码/文档改动、零构建、不推。
