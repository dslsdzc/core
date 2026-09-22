# Core 并发模型设计（语义层规格）

日期：2026-09-17（第二轮：**裁定写进文档版**）
状态：**设计定稿**（维护者 2026-09-17 裁决）——§1–§12 为维护者原文主体，逐字写进文档，**裁定不覆写原文**；裁定一律落 §11.1 / §13.0 / §16 裁定表
范围：本文 §1–§12 = 设计权威；§11.1（次序修订）· §13（不变量条目化，含 §13.0 = G1 具体化）· §14（术语表）· §15（仓库对接与缺口）· §16（裁门**裁定表**）= 裁定与新增分析面
纪律：**只读**——零构建、零源码改动；§15 全部结论以读码 + `file:line` 为据，推断处显式标注
裁定来源：**维护者**（G1 / G2 / G8 / G9——经 team-lead 转达）· **team-lead**（G3 / G4 / G5 / G6 / G7 / G10 / G11 / G12 / G13）——13 门全部已裁，逐条见 §16.0 裁定总表

## 0. 关联与定位

| 文档 | 关系 |
|---|---|
| `docs/superpowers/specs/2026-07-30-concurrency-design.md` | GMP 简化并发**实现**设计（go/chan 端到端已实现，单 M）——本文是其**语义层**上位规格 |
| `docs/superpowers/specs/2026-09-04-message-copy-elision-design.md` | 消息边界标签 {COPY, MOVE, SHARE} + 消息子区域 + 身份重指（设计定稿，未实现）——与新 primitive 集**需要一次对齐**（§16 G7） |
| `docs/superpowers/specs/2026-09-11-semantic-safety-roadmap.md` §1.4 | 共享契约：`determinism` 轴族 + 「不确定性 = 显式请求」——本文 §5 与之同源 |
| `docs/superpowers/specs/2026-09-11-semantic-safety-obligations-design.md`（S-A） | 属性轴 + **四档义务**（①prove ②enforce ③proof-required ④reject）——本文 §8/§9 的义务落档机制 |
| `docs/superpowers/specs/2026-09-11-merge-semantics-design.md`（S-E） | 汇合语义四形态 + **物理 ⇏ 语义降级义务** + 观测面 `obs` 定义（L3）+ 顺序源白名单（L5）——本文 §5 的判据面 |
| `docs/superpowers/specs/2026-09-11-explain-predict-incremental-design.md`（S-D） | 决策记录（旁路载体）+ `explain` + `core analyze --determinism` 报告面——本文 §10 的落点 |
| `docs/maintainer/design/region-model.md` / `memory-model.md` / `execution-model.md` / `ir-op-semantics.md` | 区域/Arena/字节权限/状态链/并发 opcode 语义的现存设计面 |
| `docs/maintainer/adr/adr-0017-concurrency-gmp.md` | ADR：GMP 简化模型 accepted（单 M 端到端） |

本文的**定位**：语义层规格。它回答「Core 的并发语义是什么、编译器负责什么、什么绝不进语言」；不回答「哪一批先行实现」（实施顺序见 §11 原文，实施计划另出）。

---

## 1. 总体模型（原文）

> 按我们刚才收敛出来的方向，我会把 Core 并发规划成 "语义上确定、默认无共享可变状态、传输自动优化；共享内存只作为可选 mapping 实验策略"。
>
> **总体模型**：Core 源语言不新增 lock / mutex / atomic / ownership 语法。程序仍然只描述逻辑、状态关系和并发关系。编译器内部负责把 program graph → 并发依赖关系 → ownership / transfer planning → 必要时 synchronization planning → target mapping 整个过程自动完成。核心不变量是：**任何未显式声明的调度差异，不得改变可观察语义**。也就是说，Core 首先解决确定性，然后才解决怎么跑得快。

### 1.1 三层职责切分（由原文导出，非新增设计）

| 层 | 内容 | 载体 |
|---|---|---|
| 语义层 | 逻辑、状态关系、并发关系（哪些执行体、谁在谁的依赖上） | 源程序 + 图（HDFG：节点/边/region/state edges） |
| 计划层 | ownership / transfer planning →（必要时）synchronization planning | 编译器内部计划——**不是 IR 指令**（§7 原文） |
| 映射层 | target mapping：物理拷贝、共享内存、同步原语、调度 | 后端 / 运行时 / 部署配置 |

### 1.2 默认配置的三个「无」（原文）

默认配置保持最干净的一条路线：

- shared mutable state = **forbidden by mapping**；
- user-visible locks = **none**；
- compiler locks = **none**。

> **术语待定**：原文「compiler locks = none」有两种读法——(a) 编译器不生成任何锁；(b) 编译器自身（编译过程中）不持锁/不引入锁语义。§14 术语表标「待定」，进 §16 G11。

### 1.3 执行体与区域（原文）

执行体拥有各自 region/arena。跨执行体的数据关系由编译器做 Transfer Planning。

---

## 2. 五个 transfer primitive（原文）

核心 primitive 固定为 **MOVE / LOAN / SPLIT / FILL / COPY**：

| primitive | 语义（原文） | 代价 |
|---|---|---|
| **MOVE** | A owns R → B owns R，永久转移 | 0 copy |
| **LOAN** | A owns R → B temporarily owns R → A owns R again，任何时刻只有一个执行体可访问 | 0 copy |
| **SPLIT** | R → R1 + R2 + … + Rn，证明子区域互不重叠后分别归属不同执行体 | 0 copy |
| **FILL** | receiver reserves destination，producer directly constructs into it → receiver activates ownership，避免"producer 先构造一次、再搬一次" | 0 copy |
| **COPY** | 只复制无法通过上述方法消除的最小 subregion | 见 §3 |

> 因此 COPY 从来不应该是 COPY whole message 而应该是 **COPY CopySet**。
>
> **CopySet = Live_sender ∩ Needed_receiver ∩ NonTransferable**

**primitive 集合是闭集。** §4 原文明确：STREAM / DROP / RECOMPUTE / INLINE / BATCH / DMA / RDMA **都不应污染 transfer primitive 集合**。

---

## 3. COPY 性能目标与流水化（原文）

### 3.1 三个目标量（原文）

> 重点不是 memcpy 更快，而是同时最小化 **CopiedBytes / VisibleCopyLatency / BandwidthPressure**。

### 3.2 COPY planner 的消除瀑布（原文，次序即优先级）

1. MOVE elimination
2. SPLIT elimination
3. FILL / destination allocation
4. dead-subregion elimination
5. partial COPY
6. chunked COPY
7. async COPY
8. consumer-driven prefetch/copy
9. **synchronous full materialization（最差 fallback）**

**原文算例**：1 GiB message → 700 MiB MOVE + 200 MiB receiver-unused（eliminate）+ 90 MiB FILL + 9.99 MiB SPLIT + 4 KiB COPY ⇒ 逻辑 1 GiB，**physical copy = 4 KiB**。

### 3.3 COPY 流水化（原文）

> 即使 COPY 不可避免，也不要 copy all → wake receiver；而利用 graph 的未来访问顺序（receiver needs R7→R2→R9→R1）：copy R7 → start receiver；while receiver uses R7: copy R2 … ⇒ T_visible_copy 可能远小于 T_physical_copy。

为此增加 **Copy Scheduler**：chunk sizing / copy order / copy-computation overlap / prefetch distance / NUMA placement / DMA-CPU selection。

> **全部属 mapping，不进语言语义。**

---

## 4. STREAM 的定位（原文）

**STREAM 不作为 ownership primitive**：STREAM 保留能力但放到 scheduler（1 GiB producer→consumer 可 lowering 成 chunk0..n MOVE 或 FILL）。

> **STREAM = scheduling strategy，不是第六种 ownership mode**。同理 DROP / RECOMPUTE / INLINE / BATCH / DMA / RDMA 都不应污染 transfer primitive 集合。

---

## 5. 确定性规则（原文）

两个并行 transition T1 || T2，编译器必须判断：

- memory-independent?
- state-independent?
- commutative?
- observable-order-independent?

判定分支（原文）：

| 情形 | 处置 |
|---|---|
| T1∘T2 = T2∘T1 | **任意调度合法** |
| 不交换，但 graph 存在 T1 → T2 | **按语义顺序执行** |
| T1 ‖ T2 且 T1∘T2 ≠ T2∘T1，又无显式 nondeterminism | **reject**——不能让 scheduler 偷偷决定答案 |

> **同步实现永远不能反过来定义语义。**

---

## 6. Experimental Shared Mapping（原文，实验特性）

默认 `[concurrency] shared_mapping = false`（strict ownership / share-nothing mutable state / 无编译器生成的用户数据锁）。

实验打开 `[experimental.concurrency] shared_mapping = true` 时：

- compiler 可对原本昂贵的 COPY obligation 做 **Cost(copy) vs Cost(shared+sync)** 比较；
- **若能证明 synchronized shared representation 与原语义等价**，则允许 shared region + 自动生成的 synchronization（atomic / mutex / rwlock / spinlock / transaction / serialized owner **由后端自选**）；
- **源代码仍完全不变**。

**硬规则（原文）**：如果语义真正要求两个长期独立、分别可变的版本，那么 shared+lock **不得冒充 COPY**——那种情况必须真实产生两个状态。

---

## 7. 自动锁不进 IR 语义（原文）

保持 semantic graph → conflict/atomicity obligations → mapping planner，而不是 `IR instruction: LOCK`。

高层只产生约束（如 `T1 and T2 may not overlap on R`），mapping 决定：

| 目标 | 机制（原文举例） |
|---|---|
| x86 | atomic / mutex / TSX / futex |
| RISC-V | AMO / LR-SC / lock |
| HIC | capability / scheduler mechanism |

> 这与 Core 的 graph → lattice → encoding 完全一致。

---

## 8. 自动同步 planner（原文；shared mapping 开启后）

**输入**：ReadSet / WriteSet / Region / Provenance / Lifetime / State edge / Commutativity / Target capability / Contention estimate。

**输出**：NONE / ATOMIC / GUARD / TRANSACTION / SERIALIZE。

**优先级（原文，次序即「不要一发现 conflict 就上 mutex」）**：

1. prove independence
2. ownership transformation
3. atomic
4. fine-grained synchronization
5. transaction
6. serialization

---

## 9. Deadlock 自动证明（原文）

若决定生成锁，必须同时生成 lock dependency graph 并证明无环（如全局 partial order rank(L1)<rank(L2)<…）。

- 若发现 L1→L2 且 L2→L1 ⇒ **不能继续生成该 mapping**；
- 可依次尝试：自动 merge lock / change granularity / transactionalize / serialize / fall back to COPY；
- 再不行 ⇒ **fail-closed**。

> **不能把潜在 deadlock 扔给用户。**

---

## 10. Explain 必须跟上（原文，与既有 decision records 匹配）

`corec explain concurrency foo.cr` 输出（默认模式）：

- channel #17 的 logical payload 512 MiB
- transfer plan（MOVE 486 / SPLIT 18 / FILL 7 / COPY 1 MiB）
- copy scheduling（synchronous 64 KiB / asynchronous 960 KiB）
- visible copy latency（modeled 3.1 us）
- shared mapping（disabled）

实验模式下再输出：

- region R42 的 `selected: rwlock`
- `avoided copy: 128 MiB`
- `semantic equivalence: proved`
- `deadlock freedom: proved`

---

## 11. 实施顺序（原文，10 步）

| # | 步骤 | 依赖 |
|---|---|---|
| 1 | Transfer Analysis（MOVE/SPLIT/COPY + CopySet 精确到 subregion） | — |
| 2 | FILL / destination placement | 1 |
| 3 | LOAN | 1 |
| 4 | Copy Scheduler | 1 |
| 5 | Copy Cost Model（copied bytes / visible latency / bandwidth） | 4 |
| 6 | Experimental Shared Mapping（先只支持 compiler 自动生成 mutex/rwlock） | 1/5 |
| 7 | Automatic Synchronization Planner（atomic / transaction / serialization） | 6 |
| 8 | Commutativity + determinism proof（避免「有锁但结果依赖 lock acquisition order」） | 6/7 |
| 9 | Deadlock certificate（没有 deadlock proof 就不能启用该方案） | 7 |
| 10 | Adaptive mapping（profile-guided：COPY vs shared、mutex vs rwlock、atomic vs transaction、chunk size） | 5/6/7 |

### 11.1 实施次序（裁定修订，2026-09-17；承 G9 裁定）

**裁定（维护者 2026-09-17，经 team-lead 转达）**：地基三项**提到步 1 之前**——「先补地基再起步 1」。

| 序 | 项 | 内容 | 依据 |
|---|---|---|---|
| **0a** | 多 M 打通 | `sched_spawn_workers` 接线 + 多 M 下的 runq / 唤醒面（今日恒 1 M：`sched.cr:28-35`） | G9 |
| **0b** | 消息表示 | 跨执行体消息 = 子区域/句柄 + 值搬运面（今日只有 8 字节字 + `sched_go` 的 1 个 arg） | G9 / G10-a |
| **0c** | 并发运行时验证 | wait list「无锁」正确性在**多 M**下成立（现假设仅单 M 成立：`sched.cr:2-3`） | G9 + `TODO #2026-07-31-1` |

内部次序建议：**0b ∥ 0a → 0c**（0c 同时覆盖二者）。

**理由（裁定依据，逐条可核）**：步 1（Transfer Analysis）的**输入面**是「跨执行体边界 + 消息」——今日二者都不存在（§15.3 事实 1/5）；且 §6 的 `Cost(copy) vs Cost(shared+sync)` 与 Copy Scheduler 的 async/prefetch 都预设**真并行**（今日恒 1 M）⇒ 在单 M 上做出的等价性证明与 deadlock 证书**不覆盖真并行** = 假背书（违 I5）。

**0 未完成前，步 1 无从落地**；其后 = §11 原文 1..10 步次序不变。

#### 11.1.1 本顺序的边界、前置与判据挂钩（交叉核补注，2026-09-18）

> 本节是 §11.1 的**范围声明**（不是缺陷声明）：写明本顺序**承载什么**、**依赖什么**，以免读者误读为「`0a–0c` + 1–10 步自足」。

**① 证据载体边界**：下列判定证据的载体**不在本顺序（`0a–0c` + 原文 1–10 步）的产物上**——

| 门 | 证据载体 | 性质 |
|---|---|---|
| **G2** / **G12** | **S-E**（汇合语义四形态 + determinism 唯一执法点） | **前置**（判定与执法面） |
| **G5** / **G13(c)** / **G10-b** / **I1** / **I9** | **S-D**（决策记录 + `explain` / `analyze --determinism` 报告面） | **前置**（基础设施面） |

**② 为何声明而不增步（本批择定）**：S-D / S-E 是**已存在的独立 spec 与批次**，其排期不由本线控制。把它们塞进本顺序会（a）超出维护者原文 §11 的 1–10 步结构，（b）让读者以为本线负责实现它们。声明为**前置**（前置 ≠ 本顺序的一步）更准确地表达依赖方向。

> **其中 S-D 的记录面是步 5 的硬前置**——G13(c) 原文已写：「记录必须随缓存条目存取（`cir_cache.cr` 键今日不含记录）⇒ 是步 5 的前置」。

**③ 步 1 的 T0 前置**：
- **G7 的标签对齐表**（新 primitive 集 ↔ `2026-09-04` 的 {COPY, MOVE, SHARE} 标签 + 义务逐条对照）——G7 裁定明写「实施前须出」，而步 1 正是做 primitive 判定的地方 ⇒ **对齐表是步 1 的输入**；
- **G3 的产物**（pts 表示升级 = `TODO #2026-09-17-19` 批）——与本节理由段同源：**分析表示不到位，步 1 的 CopySet 就无从精确** ⇒ 它是步 1 的 T0，而非步 1 的内部子项。

**④ 判据面挂钩**：步 1 / 6 / 7 的验收判据须各含一句「**依 G6 ②：transfer/sync 决策与证书不进 `.ccr`**」（语义标注确需入 `.ccr` 时须 bump `CCR_VERSION`）——把已裁的约束与其**触发点**显式绑定。

**⑤ 步 10 的入口纪律**：profile-guided 适配受 **S-D L3** 约束——`heuristic` / `env` 类记录**不得跨构建复用**；步 10 起跑前须先声明其 profile 记录的**类别与失效条件**。

---

## 12. 最终定位（原文）

> 语义层只描述并发关系和状态关系；默认通过 ownership flow 实现 share-nothing concurrency；编译器自动最小化实际数据复制，并将不可避免的复制与计算重叠；可选实验 mapping 可以使用自动同步的共享内存，但**不得改变程序的确定性和状态语义**。三个目标同时保住：**确定性 / 默认无需锁 / 性能尽可能逼近共享内存**，且不把 mutex/atomic 这些机器实现细节塞回 Core 的语言模型。

---

## 13. 不变量条目化（可检验条款）

> 由原文导出，**不改设计**。每条给「可检验形式」与「取证面」；标 **[待定]** 者依赖 §16 裁门。

### 13.0 G1 裁定写进文档：可观察语义 = 值 / 效应 / 控制去向 / 终止类别 + **预算向量（含时间）**

**裁定（维护者 2026-09-17，经 team-lead 转达）**：可观察语义**包含时间**，走**预算等价（budget equivalence）**路线。**注意：这强于规划代理原推荐**（原推荐曾倾向「性能不进语义」）。

#### 13.0.1 时间以什么形式进语义（三形态；**逐微秒显式排除**）

**显式排除**：逐微秒 / 绝对墙钟时间**不进语义**——不可实现（无时基模型）、不可复现（同产物两次运行必然不同）、不可测（无覆盖全部目标平台的测量协议）。**任何以绝对时间为判据的条款一律不成立**；`modeled`（模型量）不得升格为语义条款本身（其地位见 13.0.2）。

进语义的时间量 = **预算条目（budget entry）**，逐条取三形态之一：

| 形态 | 判据式（示意） | 判定方式 |
|---|---|---|
| **B-渐进**（量级约束） | 可见延迟对 payload 的阶不超过声明阶：`T_visible(n) ∈ O(f(n))`；默认律取 f = 常数（即「可见延迟不随 payload 线性增长」的强形式） | **编译期可判**：由 transfer plan 的形状（chunk 序列 / 同步点位置）推出，不由测量 |
| **B-计数**（次数 / 字节上界） | `CopiedBytes ≤ B`、`copy ops ≤ K`、`sync waits ≤ W`、`内存上界 ≤ M` | **编译期可判**：§3.2 消除瀑布每级的产物即计数 |
| **B-等待**（同步等待上界） | 最长同步等待 ≤ 声明量级（默认 = **0**：默认无锁 ⇒ 无同步等待；shared mapping 下由同步 planner 六档输出各自的界给出） | **编译期可判**：由 sync plan 档位给出 |

**三条共同性质（缺一不可）**：
1. **声明性**：每条预算必须有来源 = 默认律 / 程序内显式标注 / policy 档。承共享契约 §1.4「不确定性 = 显式请求」——**要更强的预算必须显式声明**，编译器不替用户猜。
2. **可判定**：达成必须**编译期可判**（由 plan 推出）；判不出 ⇒ `unknown`（落 ③proof-required 或按 policy 降级），**不得**以测量充当达成证据（G4 裁定：禁运行时见证顶替）。
3. **违例不静默**：预算不满足 ⇒ 编译期诊断 / 拒绝编译（按 policy 档）；**绝不产出**「未标注却超预算」的产物（= 新不变量 **I9**）。

**默认律（默认档最小集）**：

| 条目 | 默认值 | 依据 |
|---|---|---|
| B-渐进 · 可见延迟 | 不随 payload 线性增长（COPY 流水化生效；纯同步全量 materialization 违反默认律 ⇒ 需显式声明接受） | §3.3 原文目标 |
| B-计数 · 同步等待 | 0（默认无锁） | §1.2 原文 |
| B-计数 · copied bytes | 由 plan 给出（不设额外常数上界；常数上界属显式声明） | §3.2 原文「physical copy 最小化」 |

> 上表 = **首批默认律**（team-lead 2026-09-17 裁定：取此「最弱可用律」；判据 = 可满足性实测；**违律 ⇒ 设计反馈回炉，不得调弱律**——见 §13 尾注附加纪律）。

#### 13.0.2 `explain` 的 `modeled` 值 = **待检主张**（性质变更） + 证书形态

裁定前「modeled 3.1us」是描述性输出；裁定后它**是对语义的主张（claim）** ⇒ 必须有证书形态：

- **谁证**：编译期 **prove**（Transfer / Copy planner 自身产出预算义务，判定走 S-A 四档）；**测量不得作为义务解除凭证**（G4），只作报告面证据与回归判据。
- **什么形式**：预算证书条目 = `{budget_id, kind(B-渐进|B-计数|B-等待), declared_by(默认律|标注|policy), plan_evidence(transfer/sync plan 引用), value(class 或 bound), status(proved|unknown|violated|measured), model_ver}`；三态呈现不得把 `unknown` 渲染成通过（**未证明必须可见**）。
- **在哪落盘**：决策记录**旁路表**（G5 裁定：不新开通道、等 S-D；G6 裁定：**不进 `.ccr`**），随缓存条目存取（S-D L8）。

#### 13.0.3 三问的判定形态（收尾）

| 问 | 裁定形态 |
|---|---|
| ④ 终止 / panic | **可观察，且取类别形式**：{正常终止, 显式 panic/abort, 不终止}。mapping **不得**改变类别——尤其不得把「会终止」变成「可能不终止」（这正是 §9 deadlock 证明要挡的），反之亦然 |
| ⑤ 内存占用 / 分配点 | **分级**：分配**点 / 地址 / 次数**不可观察（承 cache 语义条款 2 order-free）；**内存上界**作为**预算条目**可观察（B-计数族） |
| ⑥ 性能 | **进语义**（本次裁定），但仅以 13.0.1 的三形态出现；**绝对时间与逐微秒排除** |

> ⑥ 的落法顺带解决了 §1 不变量与 §3 性能目标之间的结构性张力：`VisibleCopyLatency` 以**预算条目**（而非实测微秒）进语义 ⇒ Copy Scheduler 的自由度以「不使已声明预算由满足变不满足」为界（= I5 的强化形态）。

| # | 不变量（原文依据） | 可检验形式 | 取证面 |
|---|---|---|---|
| **I1** | **确定性（预算等价，G1 裁定）**：任何**未显式声明**的调度差异，不得改变可观察语义；**可观察语义 = `(值输出, 效应, 控制去向, 终止类别, 预算向量)`**（§1 + §13.0） | ∀ 合法调度选择 s₁,s₂：五项**逐项**相等；**预算向量按声明粒度比较**（同一声明条目 ⇒ 两次运行都必须满足该条目），**不含绝对墙钟时间** | 差分执行（同产物多次运行 + 强制不同调度 + payload 标度律检查）+ 报告面逐条 `proved/unknown/violated` 状态（§10 / S-D） |
| **I2** | **零用户锁**：源语言不新增 lock / mutex / atomic / ownership 语法（§1） | 关键字表 / grammar / 语法面**新增零项**；存量 `move` 由 **G8 裁定（维护者）= 删除**消解（`TODO #2026-09-17-18`）⇒ 本不变量无例外、无待定 | `src/compiler/lexer.cr` 关键字表 + `grammar/core.ebnf` 逐条核对 |
| **I3** | **默认 share-nothing**：默认 mapping 下跨执行体无共享可变状态（§1.2） | 默认配置下，不存在「同一可变 subregion 同时落入两个执行体访问集」的实例——由 Transfer Planning 的义务面给出 | Transfer Analysis 输出 + 义务清单 |
| **I4** | **保守性单向**：COPY 永可行；分析不精确只亏性能，**不得**产生错误拒绝（§3.2 第 9 项 + 2026-09-04 spec §设计原则 3） | 任意分析精度档下：取消分析 ⇒ **非预算分量**结果不变（全 COPY 语义等价）；分析失败 ⇒ 只允许落「预算 `unknown` → ③proof-required / 按 policy 降级」，**不得**产生错误拒绝，**也不得**静默放过预算违例（见 I9） | 行为探针：强制全 COPY 与精细计划对拍 |
| **I5** | **语义优先（强化）**：同步实现 / mapping 选择永远不能反过来定义语义（§5） | 任何 mapping 选项（copy chunk/order、锁种类、调度器选择）翻转 ⇒ ①**非预算分量不变**；②**不使已声明的预算条目由满足变不满足** | 同上 I1（含预算条目逐条状态） |
| **I6** | **锁不进 IR**：高层只产生约束，不产生 `IR instruction: LOCK`（§7） | IR opcode 表零新增锁类；`.ccr` 的 NOD 面零新增（G6） | `src/compiler/ast.cr` opcode 表 + `.ccr` 逐字节判据 |
| **I7** | **fail-closed**：潜在 deadlock 不得扔给用户（§9） | 无法证明无环 ⇒ 该 mapping 不启用（回落 COPY / 序列化），或拒绝编译；无「warning 后照常生成」路径 | lock dependency graph 证书 + 负控用例 |
| **I8** | **状态语义不可篡改**：shared mapping 不得冒充 COPY（§6 硬规则） | 「两个长期独立、分别可变的版本」的语义要求 ⇒ 必须产生两个真实状态（shared+lock 方案在此处必须被拒） | 等价性证明面（G4）+ 负控用例 |
| **I9** | **预算不静默**（G1 裁定的推论，新增）：预算条目未达成（`violated`）或未证明（`unknown`）**必须可见** | 任意编译产物：不存在「未标注却超预算」的路径；`unknown` 必须在报告面显式呈现，**不得**渲染为通过；高安全/policy 档可升为拒绝编译 | 预算证书条目（§13.0.2）+ 报告面 + 负控用例 |

> **G1 已裁（维护者 2026-09-17）**：可观察语义**包含时间**，走**预算等价**——形式化落 §13.0（时间量的三形态 + 排除逐微秒 + 三问判定形态）。**13 门全部已裁**，逐条见 §16.0 裁定总表。
>
> **默认律裁定（team-lead 2026-09-17，残余风险收尾）**：**取 §13.0.1 的当前默认律为首批默认**——「可见延迟不随 payload 线性增长 + 同步等待 = 0」= **仍能说事的最弱律**（再弱则「含时间」形同虚设；更强（常数上界）会逼出当期不可行的义务集）。**判据 = 默认律可满足性实测**（§16 G10-b 照办）。
>
> **附加纪律（同上裁定）**：若实测发现**某类常见形态必然违律** ⇒ **那是设计反馈，回炉讨论，不是放宽律**——「为了让实测通过而悄悄调弱律」= 本仓最忌的**移动球门**。

---

## 14. 术语表

> 逐条给定义或标「**待定**」。定义来源三分：**原文**（维护者原文直接给出）/ **仓内既有**（引既有文档，附锚点）/ **待定**（原文未给，进 §16）。

| 术语 | 定义 | 来源 |
|---|---|---|
| **执行体（execution body）** | 拥有独立 region/arena、可与其他执行体并行的执行单位。今日实现 = goroutine（G） | 原文 + `src/stdlib/goroutine.cr` |
| **region** | ⚠ **两义，须先判语境**：(a) 控制流嵌套（SG_FUNC/SG_IF/SG_LOOP/SG_FOR/SG_UNSAFE，`g_sgs`）；(b) 内存字节域（区域/Arena）。既有文档已显式登记此歧义 | 仓内既有：`docs/maintainer/design/region-model.md:60-62` |
| **subregion** | 原文字面："R → R1 + R2 + … + Rn"（SPLIT）、"最小 subregion"（COPY）、"CopySet 精确到 subregion"（§11 步 1）。**粒度/边界判据/表示仍为设计细节**；**G3 裁定 = 分析表示先升级**（pts 动态化，不选「接受退化」——理由：G1 取含时间立场 ⇒ 预算可证明性依赖分析精度） | 原文 + G3 裁定（`TODO #2026-09-17-19`） |
| **Live_sender** | CopySet 第一项（发送侧仍存活的部分） | 定义待设计；分析地基由 G3 裁定固定（pts 表示升级） |
| **Needed_receiver** | CopySet 第二项（接收侧真正需要的部分） | 同上 |
| **NonTransferable** | CopySet 第三项（无法经 MOVE/LOAN/SPLIT/FILL 消除的部分）。**注意**：既有 2026-09-04 spec 有一组近似概念——「无配方条目（不可重算，必须有 home，永不重建材料）」，语义不完全相同（那是**身份**不可复制，这里更像**可转移性**） | **待定** → G3 / G7 |
| **CopySet** | `Live_sender ∩ Needed_receiver ∩ NonTransferable`（原文逐字） | 原文 |
| **transfer obligation** | 由「跨执行体数据关系」导出的、必须被处置的判定要求（处置 = 五 primitive 之一；处置不了 ⇒ COPY）。**形态未定**（图标注 / 义务表 / 证书） | 原文 + 推断（S-A 义务阶梯词汇） |
| **synchronization obligation** | shared mapping 开启后，由「T1 与 T2 可能不可重叠于 R」一类约束导出的判定要求；处置 = 同步 planner 的六档输出 | 原文 §7/§8 |
| **MOVE / LOAN / SPLIT / FILL / COPY** | 见 §2 表（原文） | 原文 |
| **Copy Scheduler** | copy chunking/ordering/overlap/prefetch/NUMA/DMA-CPU 的调度器（§3.3）；**属 mapping** | 原文 |
| **CopiedBytes / VisibleCopyLatency / BandwidthPressure** | COPY 的三个目标量（§3.1） | 原文（**度量模型待定** → G10-b） |
| **STREAM** | **scheduling strategy**，不是 ownership mode（§4） | 原文 |
| **shared mapping** | 实验特性：经等价性证明后允许 shared region + 自动同步（§6） | 原文 |
| **可观察语义（observable semantics）** | **裁定定义（G1，维护者 2026-09-17）**：= **①值输出 ②效应（STORE / 通道 send / extern 调用 / YIELD）③控制去向 ④终止类别（正常/显式 panic/不终止）⑤预算向量（含时间，预算等价）**。前三项承 S-E L3；「到达位置/时刻/顺序本身」仍**不在**观测面内——时间只以**预算条目**（量级/计数/等待上界）进语义，**绝对墙钟与逐微秒排除** | 指定稿 + §13.0 |
| **显式声明的调度差异** | **裁定（G2，维护者 2026-09-17）分层**：(a) `go` 声明「存在并发执行体」= 显式声明；(b) 交叉**执行顺序**未声明 ⇒ 不属显式声明；(c) **通道 FIFO 升格为语义序**（单产单消面；多产/多消面须写明「无跨发送者全局序」或给 `ordered(src)` 标注）；(d) 未标注且顺序可观察 ⇒ **reject**（承 S-E L2 执法点，迁移承 S-E W1 模板） | 裁定（G2） |
| **顺序源（σ）** | 图上显式定序对象。S-E L5 白名单（首版即终版）= **state 边链 ∪ region 迭代序**；白名单外一律不算 | 仓内既有：S-E L5 |
| **deadlock certificate** | lock dependency graph + 无环证明（§9）。**载体未定**（判定产物 / 决策记录） | 原文 + G5 |
| **decision record** | 决策旁路载体（pass 产出 → 记录表 → 落盘），`explain` 只查不重算 | 仓内既有：S-D L1/L2 |
| **compiler locks** | **裁定（G11，team-lead 2026-09-17）**：取「**编译器不为用户数据生成锁**」——默认档下对用户数据**零锁生成**；**编译器自身内部的同步不受此限**（两条是不同层：前者是语言/语义承诺，后者是实现细节，**文档与 spec 必须写明此区分**，不得混述） | 裁定（G11） |
| **预算等价（budget equivalence）** | G1 裁定的等价路线：两个调度/mapping 等价 = 非预算分量逐项相等 **且** 各自满足**同一声明**的预算条目集 | §13.0 |
| **预算条目（budget entry）** | 进语义的时间/资源量的最小单位；三形态 = B-渐进（量级）/ B-计数（上界）/ B-等待（同步等待上界）；性质 = 声明性 + 可判定 + 违例不静默 | §13.0.1 |
| **待检主张（modeled claim）** | `explain` 输出的模型量（如 `modeled 3.1us`）的**新性质**：它是对语义的主张，须有证书与状态（`proved/unknown/violated/measured`），不得作描述性输出混过 | §13.0.2 |
| **预算证书** | 待检主张的证明/证据载体：`{budget_id, kind, declared_by, plan_evidence, value, status, model_ver}`；落**决策记录旁路**（不进 `.ccr`） | §13.0.2 + G5/G6 裁定 |

---

## 15. 仓库对接与缺口分析（B 节；逐条实读源码）

> 方法：全部结论来自读码，锚点 `file:line`。**今日实现与本文模型之间没有任何一层是现成的**——本节给出可以复用的地基、以及每一步缺什么。所有「无」= 仓内不存在对应实现或数据结构。

### 15.1 已有设施（事实清单）

| # | 设施 | 锚点 | 事实（它能做什么） | 它做不到什么 |
|---|---|---|---|---|
| 1 | channel 运行时 | `src/stdlib/chan.cr` | 64B 头 + 环形缓冲 + send_wait/recv_wait 两条 FIFO 等待链；`chan_make(elemsize, cap)` / `chan_send` / `chan_recv` / `chan_close`；直接 handoff（有等待者时不经缓冲）；发送/接收的值一律是**单个 8 字节字**（`w64`/`r64` 全程） | 无消息/子区域概念；无所有权转移；跨边界只搬 8 字节；无 SPLIT/LOAN/FILL 任何痕迹；无锁——依赖单 M 协作（`chan.cr:1` 的 "goroutine-safe" 由 `sched.cr:2-3` 的 SPSC 假设背书） |
| 2 | 调度器 | `src/stdlib/sched.cr` | M 结构 32B；**恒建 1 个 M**（`sched.cr:28-35` 注释 "For now: single-threaded (1 M, cooperative)"）；runq 是 per-M FIFO 链表（`sched_enqueue` 尾插 `:64-80` / `sched_dequeue` 头取 `:82-91`）；协作切换 = `sched_yield`（`:97-115`）；`sched_go(fn_ptr, arg)` 建 G + 1 元素 result channel（`:171-186`）；`sched_spawn_workers` 存在（`:189-205`） | 多 M 未接（TODO #2026-07-31-1：静态构建未内联发射 `m_start_workers`）；无偷取/全局队列；无异步/预取/DMA |
| 3 | goroutine 生命周期 | `src/stdlib/goroutine.cr` | G 80B 布局（id/status/sp/stack_lo/arena_id/result_ch/next/saved_fn/saved_arg/temp_val）；`g_new` **先建 G 自己的 arena** 再分配 16KB 栈（`:28-45`）；`g_free` 复位 arena + 标 dead（`:64-70`） | 无所有权/转移语义；`sched_go` 只传 **1 个 8 字节 arg**（`goroutine.cr:64`） |
| 4 | arena | `src/stdlib/arena.cr` | 每子图一 arena；`arena_init/new/reset`；`g_current_arena` 路由 `alloc()`；free list 复用；嵌套 parent 记录 | 无 size class、无 split（子区域）、无跨 arena 迁移/换基址、无页权限（COW/冻结）、无预留（FILL 需要的 destination reserve） |
| 5 | 图与 region | `src/compiler/dataflow.cr` | SG 记录（kind/enter/exit/parent/nstart/ncount）+ `g_df_node_region` 显式归属（`subgraph_containing` O(1)）；`SG_FUNC/SG_IF/SG_LOOP/SG_FOR/SG_UNSAFE` 有产生点；**`SG_FLOW` 无任何产生点**（S-E B-N1 实测） | region 是**控制流**嵌套，不是内存区域；无「内存子区域」表 |
| 6 | state edges | `src/compiler/dataflow.cr:156-266` | 副作用链：`df_connect_state`（opcode 级效应清单唯一依据 = `purity_op_effect`）+ 循环终止依赖；**全部 IR 生成后重建**（`df_replay_state_chain`）——因为入链判据依赖 `compute_all_purity`；`kind=1` | 只有「序」没有「交换性」；无 ReadSet/WriteSet |
| 7 | 指针分析 | `src/compiler/ptr_analysis.cr` | Andersen 式：Addr/Copy/Store/Load 四规则；pts 表 `g_pts`；offset 表 `g_offsets`（单标量，-1=未知）；alloc→节点映射 `g_pa_alloc_nodes` | **intra-procedural**：`IR_CALL` 分支"leave pts=0 for now (conservative)"（`:316-319`）——头注声称 "interprocedural function summaries"，**代码无该实现**；pts 是**单 int 64 位位图**（`pa_merge_pts` 循环 `bi<64`）；**全程序 alloc 追踪上限 64**（`:213` `if g_pa_alloc_count < 64`）⇒ 第 65 个分配起静默不追踪；**且计数器从不复位**（`reset_frontend_state` `globals.cr:509-540` 复位了 `g_alloc_pts_cap:538` 却未含它）⇒ 额度**按进程累计**、随编译序漂移；unsafe 块整块跳过（`:201`）。⇒ 已立 `TODO #2026-09-17-19` |
| 8 | 区域检查 | `src/compiler/region_check.cr` | DEREF 目标分配的 subgraph 是否已 exit（`ni > alloc_exit` 节点序比较，`:34-57`）；返回逃逸（`:59-92`）；存储逃逸调 `rc_pts_has_escaped` 但**丢弃返回结果**（`:102`）⇒ 无诊断路径 | 无 liveness/use 集（仓内无该 pass）；无跨执行体概念 |
| 9 | provenance 校验 | `src/compiler/provenance_verify.cr` | offset vs alloc size 界限；运行期检查回填 s2/s3（`:117-129`） | 与 transfer 无关；alloc size 只覆盖 `IR_ALLOC_ARRAY`/`IR_ALLOC_STRUCT`（`:17-26`） |
| 10 | `.ccr` 载体 | `src/compiler/ccr_io.cr` | EDG 段每条 `{to_nod u32, kind u32}`，kind **只允许 ∈ {0 def-use, 1 state}**，`>1` 直接拒绝落盘（`:412`/`:428`）；`CCR_VERSION = 9`（`:135`，load 严格 `==9`） | 无第 3 类边、无标注段（S-E 说 determinism 标注要与 R2 P4 同波进 `.ccr` 段——**尚未落**） |
| 11 | `.cir` 快照缓存 | `src/compiler/cir_cache.cr` | 函数级快照；`CIR_CACHE_VER = 18`（`:56`）；缓存键 = 源路径::函数名 + 纯 AST 指纹 | 键**不含编译器身份**（TODO #2026-09-05 系；S-D L8 要求「决策记录随缓存条目一起存取」= 未实现） |
| 12 | 并发 opcode | `src/compiler/ast.cr:546-548` + 三后端 | `IR_SPAWN=27` / `IR_YIELD=28` / `IR_AWAIT=29` / `IR_FNADDR=48`；`go` 单发降为 `IR_CALL sched_go`（`ir_gen.cr:1672-1673`），range-go 才发 `IR_SPAWN`（`:1697`） | IR_YIELD 在 interp 与 ELF **都是 no-op/eager 值搬运**（`interp.cr:385-387`、`instr.cr:1481-1490` dest=-1 ⇒ 值被丢弃）；IR_AWAIT 同理（`interp.cr:389-390`、`instr.cr:1413-1417`）⇒ **今日无跨执行体值通道语义** |
| 13 | `move` 关键字 | `src/compiler/lexer.cr:102` / `grammar/core.ebnf:42` / `ast.cr:200` | `move x` 是合法表达式：checker 透传（`checker.cr:3679-3680`）、ir_gen 透传（`ir_gen.cr:2878-2879`）⇒ **零语义** | 与 MOVE primitive **同名不同物**，须裁（G8） |
| 14 | 配置面 | `src/compiler/project.cr` / `Core.toml` | 只解析 `name = "..."`（`extract_toml_name`） | **无段解析**——`[concurrency]` / `[experimental.concurrency]` 是全新面（§6 的两条配置） |
| 15 | CLI 面 | `src/compiler/main.cr:234-241` | 8 命令：`build`/`check`/`cir`/`ccr`/`run`/`clean-cache`/`selftest-types`/`selftest-purity` | **无 `explain`、无 `analyze`、无 `--dump-vcs`**（后两者分别只有 spec 与 plan + 在飞分支，见 15.4） |

### 15.2 十步逐条对接（缺什么 / 可复用 / 数据结构有无）

| # | 步骤（§11 原文） | 可复用 | 缺什么 | 对应数据结构 |
|---|---|---|---|---|
| 1 | **Transfer Analysis**（MOVE/SPLIT/COPY + CopySet 精确到 subregion） | 别名：`ptr_analysis`（粗）；生存/逃逸序：`region_check`；副作用序：state edges；边界点：channel send/recv、go 参数、result_ch | **全部核心**：跨执行体边界枚举（今日只有 chan 4 个函数 + `sched_go` 调用点）；Live/Needed 集；subregion 划分与不重叠证明（SPLIT 前提）；CopySet；NonTransferable 判据；消息闭包（可达闭包 + 身份重指） | **无**（`g_pts`/`g_offsets` 承载不了子区域；无 region→subregion 表；`alloc_seq→节点` 映射存在但**上限 64**） |
| 2 | **FILL / destination placement** | arena bump 分配；`IR_ALLOC_ARRAY/STRUCT` | 接收侧「预留 → 生产者直构 → 接收者激活所有权」协议；今日 `go` 只传 1 个 8 字节（`ir_gen.cr:1672-1673`）⇒ **先要有"消息"概念** | **无** |
| 3 | **LOAN** | 无直接可复用（`region_check` 的 outlives 序判定是最近的概念） | 借用区间（loan span）的图表示与归还点；与 borrow checker 的关系须裁（借出期间发送侧禁访问 = **新的义务类型**） | **无** |
| 4 | **Copy Scheduler** | 协作调度切换点（chan 空/满 + yield） | 部分就绪的接收（chunk 级 handoff）、copy/compute 重叠的执行机制、prefetch、NUMA、DMA | **无**（推荐：先按 §4 原文 lowering 成 chunk 序列复用现有 chan 语义——见 G10-a） |
| 5 | **Copy Cost Model** | 无 | 三目标量的度量模型与参数表（bandwidth/latency 从哪来）；`model_ver` 版本面（S-D 决策记录 schema 已有该字段位） | **无** |
| 6 | **Experimental Shared Mapping** | 无 | 配置面（`project.cr` 无段解析）；**真并行**（今日恒 1 M，见 G9）；等价性证明（G4）；mutex/rwlock 生成面 | **无** |
| 7 | **Automatic Synchronization Planner** | 义务阶梯（S-A，设计态）；state edges | ReadSet/WriteSet/Contention estimate 的产出面；六档输出（NONE/ATOMIC/GUARD/TRANSACTION/SERIALIZE）的判定核 | **无** |
| 8 | **Commutativity + determinism proof** | **S-E 已定四形态语义**（`merge_deterministic`/`ordered`/`race`/`select_any`）+ 观测面定义（L3）+ 顺序源白名单（L5）+ 「未证明未标注 ⇒ reject」（L2）；purity（`compute_all_purity`） | 交换性判定本身（无 pass）；与 S-E 的接线（S-E 覆盖「汇合点」，本文覆盖「并行 transition」——**同一判据的两个投影，须裁归口**，G12） | **无** |
| 9 | **Deadlock certificate** | 判定产物先例：`existence-structure.md:111`「证书等判定产物独立于 `.ccr`，不落本文件」；决策记录（S-D，设计态） | lock dependency graph 生成 + 无环证明 + 证书载体 + fail-closed 出口 | **无** |
| 10 | **Adaptive mapping** | TODO「PGO 自动剖析」（2026-08-30 记）——**仅登记，无实现** | profile 采集/反馈面 | **无** |

> **次序修订（G9 裁定，维护者 2026-09-17）**：上表按维护者**原文**次序；**实施次序已由 §11.1 修订**——步 1 之前插入地基三项（0a 多 M / 0b 消息表示 / 0c 并发运行时验证）。
> **G3 裁定（team-lead 2026-09-17）**：步 1 的 Live/Needed 分析**先做 pts 表示升级**（不选「接受退化」）；64 上限静默截断已立 `TODO #2026-09-17-19`。

### 15.3 `go` / `chan` 现状的语义定位（读码事实，不含推断）

> 问题：现有调度下消息顺序是**语义给定**的，还是**调度产物**？

**事实 1（`go` 的今日 lowering）**：单发 `go f(args)` 降为 `IR_CALL sched_go(@addr(f), arg)`（`ir_gen.cr:1634-1676`），`sched_go` 建 G + 1 元素 result channel 后入队（`sched.cr:171-186`）；返回的 channel 即「future」。range-go 才发 `IR_SPAWN`（`ir_gen.cr:1697`）。

**事实 2（执行序）**：调度是协作式、**恒 1 M**（`sched.cr:28-35`）；run queue 是 FIFO（尾插 `:71-79` / 头取 `:87-91`）；`sched_yield` 把当前 G 重新尾插（`:105-111`）⇒ **同一 M 上 runnable G 的执行顺序 = 入队顺序**。入队顺序由「谁先 yield/被唤醒」决定 ⇒ 是**调度产物**。

**事实 3（消息序）**：channel 内部顺序由**数据结构给定**——环形缓冲 head/len（`chan.cr:68-74` 写侧 / `:121-127` 读侧）是 FIFO；等待链也是 FIFO 追加（`chan.cr:88-93` / `:141-146`）。⇒ 单产单消时**消息序 = 发送序**；多产/多消时「谁先入队」由调度决定，**通道只保证数据结构的 FIFO，不保证跨发送者的全局序**。

**事实 4（SPSC 是约定不是保证）**：`sched.cr:2-3` 声明 "Channels are single-producer/single-consumer edges, so the runtime needs no locks"。该断言**无任何强制**：`chan.cr` 不检查生产/消费者数；checker/parser 无限制（无 chan 类型、无相关诊断）。⇒ 今日「SPSC」是**（未写进语法/类型的）设计约定**。

**事实 5（值通道）**：所有跨边界值 = **单个 8 字节字**（`chan.cr` 全程 `w64`/`r64`）；`sched_go` 只传 1 个 arg（`goroutine.cr:64`）。⇒ 今日不存在「消息拷贝」这件事——既有 2026-09-04 spec 要消除的「消息边界拷贝」在当前实现里连形态都没有。

**事实 6（顺序承诺的书面面）**：`docs/maintainer/proposals/concurrency.md`（flow/go/yield/await/walk）**未给任何跨执行体顺序承诺**；`2026-07-30-concurrency-design.md:12` 只写「Cooperative 调度：只在 channel send/recv 和显式 yield 时切换」。

**事实 7（同类缺陷已有判例）**：`select` 的现语义 = 「最早到达的令牌」（`docs/dataflow-design.md:102`、`docs/project-book.md:241`）已被用户 2026-09-11 定性为**「把物理调度顺序泄进了语义」的待修缺陷**（S-E §3.1；roadmap「现有语义缺陷」条）——即：**该仓库已经否定过**「物理序 = 语义」的做法，且给出了重定模板（`select` → `race(1)` 糖衣 + 兼容窗口 W1）。

**结论（事实陈述，非设计裁决）**：今日**唯一**可依赖的顺序是通道数据结构的 FIFO（单产单消面）；跨执行体的**执行序/交错**是调度产物，且无任何书面语义承诺。这恰是 §1 不变量（「未显式声明的调度差异不得改变可观察语义」）要清理的存量面；是否把「通道 FIFO」升格为语义序、以及 `go` 是否算「显式声明的调度差异」⇒ **裁门 G2**。

### 15.4 与在飞工作面/判据面的接口（事实）

| 面 | 状态（2026-09-17 实核） | 对本文的影响 |
|---|---|---|
| `corec explain` | **仅设计**：S-D spec（`2026-09-11-explain-predict-incremental-design.md`）已定 L1/L2/L8；`main.cr:234-241` 无该命令 | §10 的落点 = S-D，不另起通道（G5） |
| `core analyze --determinism` | **仅设计**（S-D §1.7 + L12「只读，不执法」） | I1 的取证面；「隐式竞争 ⇒ reject」的**执法**点按契约归 S-A/S-E，不归报告面 |
| `--dump-vcs` | **不在 develop**：仅 plan（`docs/superpowers/plans/2026-09-16-verification-slice.md:97`）+ 在飞分支 `feature/spec-grammar` 的 T4 提交（该提交 diff 含 9 处 `dump-vcs`） | deadlock 证书若走 dump，须等它合入；否则先只定记录 schema（G5） |
| 决策记录 | **仅设计**（S-D）；`cir_cache.cr` 的缓存键**不含**记录，L8 要求的「记录随条目存取」未实现 | explain 冷/热两态一致性是 §10 的隐藏前置 |
| `.ccr` 判据 | `CCR_VERSION=9`；EDG 只许 kind∈{0,1}；行为判据网 = `.ccr` 逐字节 + ELF canary（冻结 sha `95084e7b…d475`） | transfer/sync 若进 `.ccr` ⇒ 判据面必翻（G6） |
| 多 M | `sched_spawn_workers` 存在但静态构建未接（TODO #2026-07-31-1）；wait list 的正确性依赖单 M（`sched.cr:2-3`） | shared mapping（§6）与「Cost(copy) vs Cost(shared+sync)」都预设真并行（G9） |

### 15.5 文档漂移登记（读码发现，非设计问题）

1. **TODO #2026-07-31-1 的 G 字段重叠注记已过时**：该条称「offset 56 同时用作 saved_fn 与 temp_val」；现行代码 temp_val 在 **offset 72**，且 `chan.cr:29-31` 明确警告「offset 56 is saved_fn — never write it from channel code」。⇒ 该注记应从 TODO 移除或改标「已修」。
2. **`ptr_analysis.cr` 头注与实现不符**：头注第 6 行写 "Call: function summary propagation + arg conservatism"，实现是 `IR_CALL` → pts=0 保守（`:316-319`）。CLAUDE.md 记该 pass 为「过程间 Andersen 式」——**代码是过程内**。
3. **`SG_FLOW` 无产生点**（S-E B-N1 已实测）——`docs/maintainer/proposals/concurrency.md` 的 `flow` 设计与 region 面尚未接线。

> 以上三处已登记为 **`TODO #2026-09-17-20`**（登记批，未修；零源码语义）。

---

## 16. 裁门裁定表（C 节）

> 格式：**问题 / 事实 / 推荐（决策输入，留痕）** / **裁定**。**13 门全部已裁**（2026-09-17）：维护者裁 G1 / G2 / G8 / G9（经 team-lead 转达）；team-lead 裁 G3 / G4 / G5 / G6 / G7 / G10 / G11 / G12 / G13。

### 16.0 裁定总表

| 门 | 裁定人 | 裁定值 | 落点 |
|---|---|---|---|
| **G1** | 维护者 | **含时间——预算等价**（**强于**代理推荐：原推荐倾向「性能不进语义」） | **§13.0**（新建）、§13 I1/I4/I5/**I9**、§14 术语 |
| **G2** | 维护者 | **分层**：`go` 声明并发不声明顺序 · **通道 FIFO 升格为语义序** · 未标注的可观察顺序 ⇒ **reject** | §14 术语「显式声明的调度差异」、§13 I1 |
| **G3** | team-lead | **pts 表示升级**（不选「接受退化」）；64 上限静默截断立 TODO | §15.2 注、`TODO #2026-09-17-19` |
| **G4** | team-lead | **静态证明 + 证书；禁运行时见证顶替** | §13.0.2 |
| **G5** | team-lead | **不新开通道、等 S-D** | §13.0.2 |
| **G6** | team-lead | **`.ccr` 三分法**：语义标注可入；**transfer/sync 决策与证书不进**；copy scheduler 输出纯后端 | G6 条内 |
| **G7** | team-lead | **SHARE 降级为 mapping 优化、不扩 primitive** | G7 条内 |
| **G8** | 维护者 | **删掉 `move` 关键字** | `TODO #2026-09-17-18`、§13 I2 |
| **G9** | 维护者 | **地基三项提到步 1 之前**（先补地基再起步 1） | **§11.1**（新建） |
| **G10** | team-lead | **两前置照立**（chunk handoff 复用通道语义；模型量 vs 实测划界） | G10 条内、§13.0.2 |
| **G11** | team-lead | 取「**编译器不为用户数据生成锁**」；**编译器自身内部同步不受此限**（spec 须写明区分） | §14 术语「compiler locks」 |
| **G12** | team-lead | **S-E 为唯一执法点** | G12 条内 |
| **G13** | team-lead | **五小项全部登记** | G13 条内 |

> **追裁（team-lead 2026-09-17）**：G1 之下的**默认律强弱**——取 §13.0.1 当前默认律为首批默认；判据 = **默认律可满足性实测**（G10-b）；**若某类常见形态必然违律 ⇒ 设计反馈回炉，不得调弱律**（防移动球门）。

### 16.1 逐门详录（含裁定）

> **证据载体边界（交叉核补注，2026-09-18）**：**G2 / G12 的证据载体在 S-E**（执法点）；**G5 / G13(c) / G10-b / I1 / I9 在 S-D**（决策记录 + 报告面）——两者**均不在本顺序（§11.1 的 `0a–0c` + 原文 1–10 步）的产物上**，属独立并行批次且为本顺序的**前置**。详见 §11.1.1。

### G1 可观察语义的定义（**头号开放问题**）

**裁定（维护者 2026-09-17，经 team-lead 转达）**：**含时间——预算等价**（**强于**本代理推荐；原推荐曾倾向「性能不进语义」）。四项具体化全部落 **§13.0**：① 时间量的三形态（B-渐进 / B-计数 / B-等待；**逐微秒显式排除**——既不可实现也不可测）；② `modeled` 值 = **待检主张** + 证书形态（与 G4/G5 合流）；③ I1/I4/I5 **重写** + 新增 **I9**；④ 三问判定形态（终止 = 类别可观察；内存 = 仅上界作预算条目；性能 = 进语义但仅三形态）。

- **问题**：I1 的全部力量压在「可观察语义」上，而原文未给定义。等价性判据（CopySet 正确性、shared mapping 等价证明、copy scheduler 自由度上界、deadlock fallback 的可接受性）全部以它为界。
- **事实**：仓内已有两份可直接复用的材料——S-E L3 的 `obs(·)` = ①值输出 ②效应（STORE / 通道 send / extern 调用 / YIELD）③控制去向，且明言「唯一不在观测面内的量 = 到达位置/到达时刻/到达顺序本身」；cache-semantics 条款 2「驱逐不变量 = order-free」同形态。
- **推荐**：**承袭 S-E L3 为唯一定义，不另立第二套**；补齐三个必答项：④ 终止/panic 是否可观察（今日 `chan_close` 后 recv 返回 0、无 panic 路径——须定）；⑤ 内存占用/分配点是否可观察（cache 语义现约定 = 否）；⑥ **性能是否可观察 = 否**（否则 §3 的 Copy Scheduler 与「deterministic」自相矛盾）。⑥ 是 §1 与 §3 之间的隐性张力点，建议显式写死。
- **影响**：全部下游判据。

### G2 `go` / `chan` 是否属于「显式声明的调度差异」

**裁定（维护者 2026-09-17，经 team-lead 转达）**：**分层**——(a) `go` 声明的是「**存在并发执行体**」= 显式声明；**交叉执行顺序未声明** ⇒ 不属显式声明；(b) **通道 FIFO 升格为语义序**（单产单消面：消息序 = 发送序；多产/多消面须写明「无跨发送者全局序」或给 `ordered(src)` 标注）；(c) **未标注且顺序可观察 ⇒ reject**（执法点归 S-E，承 G12）。推荐中的 (d) 迁移模板（S-E W1：默认 1 个发布周期 lenient + 具名诊断）保留为迁移细节。

- **问题**：不变量只保护**未**显式声明的差异；`go`/`chan` 是显式语法，但「显式并发」≠「显式调度」。
- **事实**：§15.3 事实 2/3/6/7——执行序是调度产物且无书面承诺；通道 FIFO 是数据结构序；`select`（最早到达）已被判为「物理序泄进语义」的待修缺陷并给了迁移模板。
- **推荐**（分层，四小项）：
  - (a) `go` 声明的是「**存在并发执行体**」——属显式声明；**交叉执行顺序未声明**——不属显式声明；
  - (b) 通道内部 FIFO **升格为语义序并写明**（单产单消面；多产/多消面须显式定「无跨发送者全局序」或给 `ordered(src)` 标注）；
  - (c) 未标注且顺序可观察的并发 ⇒ 按 §5 落 **reject**（与 S-E L2 同款执法点）；
  - (d) 存量迁移承 **S-E W1 模板**（默认 1 个发布周期 lenient + 具名诊断，strict/CI 档不放宽）。
- **影响**：存量 6 个 go/chan 测试（`tests/suite/go_*.cr` / `conc_test.cr` / `chan_test.cr`）是否重锁；§5 reject 是否会打到自家语料。

### G3 CopySet 的 `Live` / `Needed` / `NonTransferable` 从哪来

**裁定（team-lead 2026-09-17）**：**pts 表示升级**（不选「接受退化」）——理由：G1 取强立场（含时间）⇒ **分析精度是预算可证明性的前提**；且「第 65 个 alloc 起静默不追踪」本身即**静默缺陷**（本仓最忌类）⇒ 已立 **`TODO #2026-09-17-19`**（含 `ptr_analysis.cr:213` 与「64 上限」的**实测**判据要件；本轮只读未跑 RED）。

- **问题**：三项均无定义、无产出面。
- **事实**：`ptr_analysis` 是**过程内** + call 保守 + pts 单 int 64 位 + 全程序 alloc 上限 **64**（`:213`）；offset 是单标量；**无 liveness/use 集 pass**（仓内 grep 无）；`region_check` 只有 outlives 序判定。
- **推荐**：**新 pass 不可避免**（Transfer Analysis = 独立后置 pass，落在 state 链重建之后），但**分级落地**：
  - L1（粗）：整 alloc 粒度 + 现 pts ⇒ 只能做 MOVE/COPY 二分；
  - L2：`g_offsets` 单标量升级为**区间集**（子区域雏形）；
  - L3：真子区域（SPLIT 的不重叠证明在此级才成立）。
  理由：原文 + 2026-09-04 spec §设计原则 3 均认可「分析不精确只亏性能，COPY 永可行」（= 本文 I4）。**先裁表示升级**：pts 的 64 上限是**硬阻断点**——超过 64 个分配点后 pts 静默不追踪，对 transfer 决策等于「未知」（保守 COPY，不致命，但会让大程序的分析结果退化为全 COPY）。
- **影响**：`ptr_analysis` 是否要动（bitset 动态化 or 接受退化）。

### G4 实验 shared mapping 的「语义等价证明」由谁做、什么形态

**裁定（team-lead 2026-09-17）**：**静态证明 + 证书；禁运行时见证顶替** ✓（= 代理推荐）。证明主体 = 编译期 prove（Transfer/Copy planner 产义务，判定走 S-A 四档）；形态 = 证书条目（§13.0.2）；测量只作报告证据。

- **问题**：§6 只写「若能证明…则允许」——主体、形态、失败出口均未定。
- **事实**：S-A 四档义务已就位（设计态）；S-E **L8 明确确定性族无 enforce 档**（事后检测太晚，不得用「插运行时检查」充数）；证书先例 = `existence-structure.md:111`（判定产物独立于 `.ccr`）。
- **推荐**：**静态证明为主 + 证书旁路**，三态输出（proved / unknown / refuted）与 R2 引擎一致：proved ⇒ 启用该 mapping；unknown ⇒ 落 ③proof-required（要求声明/合同）**或回落 COPY**；refuted ⇒ 回落 COPY。**不得**用「运行时见证」顶替证明（= 把语义交还调度，违 I5）。
- **影响**：§11 的 6/7/9 步实施顺序（先证明器还是先锁生成）。

### G5 deadlock 证书与 `explain` / `--dump-vcs` 合流

**裁定（team-lead 2026-09-17）**：**不新开通道、等 S-D** ✓——deadlock 证书 = decision record 之一种（`qclass = concurrency.deadlock`），随 S-D 的 L8（记录随缓存条目存取）落地；在 S-D 落地前**不落任何新 dump 旗标**。

- **问题**：证书载体与报告通道未定。
- **事实**：`--dump-vcs` **不在 develop**（仅 plan + 在飞分支 T4）；决策记录**仅设计**（S-D L1/L2/L8）；explain spec §1 明确反对「再造一个无锚点 dump 旗标」。
- **推荐**：**不新开通道**——deadlock 证书 = decision record 的一种（`qclass = concurrency.deadlock`），随 S-D 的 L8（记录随缓存条目存取）一起落地；dump 面等 `--dump-vcs`/`explain` 合入后按同一记录表接线。**在 S-D 落地前，不落任何新 dump 旗标**。
- **影响**：与在飞分支 `feature/spec-grammar` 的接口顺序。

### G6 与既有 `.ccr` / canary 判定面的关系

**裁定（team-lead 2026-09-17）**：**`.ccr` 三分法** ✓——① 语义标注可入（须 bump 版本）；② **transfer/sync 决策与证书不进**；③ copy scheduler 输出纯后端。判据面随之重定：`.ccr` 逐字节不变 = **语义层未被 mapping 污染**（强判据）；ELF canary 在 mapping 批落地时**按既定流程重冻**（不是「必须不变」）。**并入**：§13.0.2 的预算证书同受 ② 约束（落决策记录旁路）。

- **问题**：transfer/sync 都在 mapping 面 ⇒ 是否应完全不进 `.ccr`？
- **事实**：`.ccr` EDG 只许 kind∈{0,1}，`CCR_VERSION=9`，load 严格等值；S-E L1 说 determinism **标注**「与 R2 P4 同波进 `.ccr` 段」；`existence-structure.md:111` 说**证书**不落 `.ccr`；判据网 = `.ccr` 逐字节 + ELF canary（冻结 sha）。
- **推荐**：**三分法**，按「是不是语义」划界——
  - ① **语义标注**（图上标注：merge 形态、`ordered(src)` 等）⇒ 可入 `.ccr`（承 S-E L1；须 bump `CCR_VERSION`）；
  - ② **transfer/sync 决策与证书**（mapping 面）⇒ **不进 `.ccr`**，走决策记录旁路（承 `existence-structure.md:111`）；
  - ③ **copy scheduler 输出**（chunk/order）⇒ 不进任何 IR，纯后端。
  判据面随之重定：`.ccr` 逐字节不变 = **语义层未被 mapping 污染**（强判据，可长期用）；ELF canary 在 mapping 批落地时**按既定流程重冻**（不是「必须不变」）。
- **影响**：新 pass 的落点、判据设计与版本号序列。

### G7 新模型与 2026-09-04 边界标签 spec 的对齐（SHARE 消失）

**裁定（team-lead 2026-09-17）**：**SHARE 降级为 mapping 优化、不扩 primitive** ✓——实施前须出**对齐表**（标签 ↔ primitive + 义务逐条对照 + 「无配方条目/身份重指」归入 NonTransferable 还是独立面）；`2026-09-04` spec 状态行随实施批标「被本文修订」。

- **问题**：两份活跃 spec 的 primitive/标签集不一致。
- **事实**：2026-09-04 spec 的标签集 = {COPY, MOVE, SHARE}（SHARE = 双侧只读共享、永久冻结、引用计数）；新模型 = {MOVE, LOAN, SPLIT, FILL, COPY}——**SHARE 无对应物**；两边的 MOVE 定义一致（永久转移、0 copy）。
- **推荐**：**以新模型为准**；SHARE 降级为**mapping 面可选优化**（多消费者只读可由「MOVE 到共享只读区 + 引用计数」表达），**不得**作为第六 primitive（§4 原文反对扩集合）；实施前出一份**对齐表**（标签↔primitive + 义务逐条对照 + 「无配方条目/身份重指」归入 NonTransferable 还是独立面）。
- **影响**：避免双轨并行；`docs/superpowers/specs/2026-09-04-*.md` 的状态行需标「被本文修订」。

### G8 `move` 关键字已存在且零语义

**裁定（维护者 2026-09-17，经 team-lead 转达）**：**删掉 `move` 关键字**（独立小批）⇒ 本门「先裁再动」已满足；实施锚点（词法/语法/AST + 6 处消费者）与**负控判据**（删后 `move := 1` 类「此前非法、删后合法」形态必须有用例锁定，防语法错误变静默接受）落 **`TODO #2026-09-17-18`**。

- **问题**：`move x` 今日是 no-op，而 MOVE 是新模型的第一个 primitive。
- **事实**：`lexer.cr:102`（T_MOVE）、`grammar/core.ebnf:42`（`Move = 'move' IDENT '='`）、`ast.cr:200`（EXPR_MOVE）、checker 透传（`checker.cr:3679-3680`）、ir_gen 透传（`ir_gen.cr:2878-2879`）⇒ **写与不写完全等价**。
- **推荐**：**先裁再动，裁前不动**。选项：(a) 删除关键字（守「零新增语法」+ 清理零语义存量）；(b) 定义为「用户**强制要求** MOVE 计划」的显式提示（则须定：提示无法满足时是诊断还是拒绝；与「编译器自动推断、零用户标注」是否冲突）。**倾向 (a)**——原文的 MOVE 是编译器内部计划，不需要用户标注，留着会与「Zero user annotation」冲突。裁前文档（含 grammar）不得暗示 `move` 有语义。
- **影响**：语言面干净度；存量语料中 `move` 的使用面需先清点。

### G9 多 M 与 shared mapping 的前提

**裁定（维护者 2026-09-17，经 team-lead 转达）**：**先补地基再起步 1**——地基三项（**多 M / 消息表示 / 并发运行时验证**）**提到步 1 之前** ⇒ 落 **§11.1**（含内部次序建议 0b ∥ 0a → 0c）。理由（裁定依据）：单 M 上做出的等价性证明与 deadlock 证书**不覆盖真并行** = 假背书（违 I5）。

- **问题**：§6 的 `Cost(copy) vs Cost(shared+sync)` 比较、以及 Copy Scheduler 的 async/prefetch 都预设真并行，而运行时今日恒 1 M。
- **事实**：`sched_init` 恒建 1 M（`sched.cr:28-35`）；`sched_spawn_workers` 未被静态构建接线（TODO #2026-07-31-1）；wait list 的无锁正确性依赖单 M（`sched.cr:2-3`）。
- **推荐**：把「多 M 打通 + 并发运行时验证」列为 **§11 步 6 的硬前置**（不是步 6 内部子任务）——理由：锁/原子的收益与 deadlock 风险都在真并行下才出现；单 M 下「shared+lock」无意义，做出来的等价性证明也不覆盖真并行（假的 I5 背书）。
- **影响**：步 6 的可行性排序。

### G10 Copy Scheduler 的两个前置

**裁定（team-lead 2026-09-17）**：**两前置照立** ✓——G10-a 取「chunk 序列**复用现有通道语义**」（与 §4 原文一致 ⇒ 不需新运行时原语）；G10-b 定「**模型量 vs 实测**」界限，`model_ver` 随**预算证书**（§13.0.2）与 S-D 记录 schema 的既有字段位。

- **G10-a（chunk handoff 的表示）**：§3.3 要求「copy R7 → start receiver → 继续 copy」，需要「部分就绪的接收」。**推荐**：先按 §4 原文 lowering 成 `chunk0..n` 的 MOVE/FILL 序列**复用现有通道语义**（则 Copy Scheduler 无需新运行时原语，只是 lowering 策略）。若裁「需要新原语」⇒ 得先做 15.1#2 缺的「消息」概念。
- **G10-b（三目标量可测吗）**：CopiedBytes / VisibleCopyLatency / BandwidthPressure 今日**无度量面**（解释器/ELF 无计时、无带宽模型）。**推荐**：先定「模型量（modeled）」与「实测」的界限（§10 原文的 "modeled 3.1 us" 已暗示模型量），并把 `model_ver` 纳入 S-D 记录 schema 的既有字段位；**不得**把模型量当实测输出（否则 I1/I5 的报告面会撒谎）。
- **影响**：步 4/5 的验收判据设计。

### G11 「compiler locks = none」的读法

**裁定（team-lead 2026-09-17）**：取「**编译器不为用户数据生成锁**」——默认档下对用户数据**零锁生成**；**编译器自身内部的同步不受此限**（如编译期数据结构的并发访问属实现细节）。**spec 必须写明这层区分**——已落 §14 术语表「compiler locks」行。

- **问题**：§1.2 三项「无」中，「compiler locks = none」二义（不生成任何锁 / 编译过程不持锁）。
- **推荐**：按上下文（与 "shared mutable state" / "user-visible locks" 并列）读作 **(a) 编译器不生成锁**，并建议原文改为「compiler-generated locks = none」以免读者误读为编译期并发。另注：`compiler.lock` 类文件锁在 CI/构建面是否存在，须另查（本轮未核）。
- **影响**：术语表的定义条目。

### G12 §5 确定性与 S-E 的归口

**裁定（team-lead 2026-09-17）**：**S-E 为唯一执法点** ✓——本文只声明「并发关系产生 determinism 义务」这一**来源**；判定 / 执法 / 报告全走 S-A / S-E / S-D 既有机制（§5 判据表保留为 S-E 判定序在「transition 对」上的实例化文本）。

- **问题**：本文 §5（并行 transition 的交换性/reject）与 S-E（汇合点四形态 + 「未证明未标注 ⇒ reject」）是**同一判据的两个投影**，谁定义、谁消费未定。
- **事实**：S-E L2「未证明且未标注 → reject（唯一执法点——并发面）」；S-E L7「自动并发只搬运已证明的 `merge_deterministic`」；本文 §5 判据面 = 「两个并行 transition」。
- **推荐**：**归口 S-E**——本文只声明「并发关系产生 determinism 义务」这一**来源**，判定/执法/报告全部走 S-A/S-E/S-D 既有机制（避免两套 reject 面）。本文 §5 的表格作为 S-E 判定序在「transition 对」上的实例化文本保留。
- **影响**：实现批只需一套判定核。

### G13 其它待定（较小，一并列出）

**裁定（team-lead 2026-09-17）**：**五小项全部登记** ✓——(a) FILL reserve 与 arena 生命周期、(b) LOAN 与 borrow checker 关系、(c) `explain concurrency` 冷热两态一致（前置 = 记录随缓存条目存取，S-D L8 / `cir_cache.cr` 键今日不含记录）、(d) `[concurrency]` 配置面（`project.cr` 无段解析）、(e) 存量 6 个 go/chan 测试重锁（待 G2 的通道 FIFO 语义定义落地后统一处理）。

| # | 项 | 推荐 |
|---|---|---|
| a | FILL 的 destination reserve 与 arena 的关系（预留区如何与 `arena_reset` 生命周期对齐） | 在步 2 计划里先裁；今日 `arena_reset` 会整体复位（`arena.cr:83-96`），预留区须与 G 的 arena 同生命周期 |
| b | LOAN 与 borrow checker 的关系（借出期间的访问禁令 = 新义务类型） | 复用 borrow checker 的既有义务面（`tests/selfhost/test_borrow.py` 覆盖 7 规则）；先裁「LOAN 是否只用于编译器内部计划、用户不可见」 |
| c | §10 的 `explain concurrency` 输出**跨冷热两态一致**（S-D L8 要求） | 记录必须随缓存条目存取；`cir_cache.cr` 键今日不含记录 ⇒ 是步 5 的前置 |
| d | `[concurrency]` 配置面 | `project.cr` 无段解析 ⇒ 需扩 TOML 面；建议与步 6 同批 |
| e | 存量 6 个 go/chan 测试的重锁 | 待 G2 裁决后统一重定（避免先改后裁） |

### 16.2 未裁项（登记；**不自行裁**）

| 项 | 事实（读码实核） | 处置（本批） |
|---|---|---|
| **多 M 打通的安全前提：「SPSC」是约定还是强制？** | 今日「Channels are single-producer/single-consumer edges, so the runtime needs no locks」**仅为** `src/stdlib/sched.cr:2-3` 的**注释约定**——`chan.cr` 不检查生产者/消费者数，checker / parser 无任何限制（§15.3 事实 4）；而**多 M 打通（§11.1 步 `0a` / `0c`）的安全前提正是这条约定** | **未裁项，待维护者裁**（升格为语法/类型/诊断强制 **vs** 保持约定 + 文档化）。**未裁前**：按「约定」登记；运行时按**多产/多消不安全**注记（不得据无锁假设推出安全结论）。跟踪：`TODO #2026-09-18-1` |

---

## 附录 A：实读锚点清单（本轮只读证据）

| 事实 | 锚点 |
|---|---|
| channel 64B 布局 + FIFO 环形缓冲 + 等待链 | `src/stdlib/chan.cr:14-46, 68-74, 88-93, 121-127, 141-146` |
| channel 值恒为 8 字节字 | `src/stdlib/chan.cr:35-45, 61, 71` |
| SPSC 断言（无强制） | `src/stdlib/sched.cr:2-3` |
| 恒 1 M（协作式） | `src/stdlib/sched.cr:28-35` |
| runq FIFO | `src/stdlib/sched.cr:64-91` |
| 协作切换点 | `src/stdlib/sched.cr:97-115` |
| `sched_go` → 1 元素 result channel | `src/stdlib/sched.cr:171-186` |
| worker 线程面（未接） | `src/stdlib/sched.cr:189-205` + TODO #2026-07-31-1 |
| G 80B 布局 + per-G arena | `src/stdlib/goroutine.cr:16-26, 28-45` |
| arena 生命周期 | `src/stdlib/arena.cr:41-49, 51-81, 83-96, 98-103` |
| state 链（kind=1）+ 重建时点 | `src/compiler/dataflow.cr:152-175, 207-257, 259-266` |
| `.ccr` EDG kind 限制 + 版本 | `src/compiler/ccr_io.cr:65-73, 135, 412, 428` |
| `.cir` 缓存版本 | `src/compiler/cir_cache.cr:56` |
| pts 64 位位图 + alloc 上限 64 + call 保守 | `src/compiler/ptr_analysis.cr:72-94, 213, 316-319` |
| offset 单标量 | `src/compiler/ptr_analysis.cr:230-297` |
| 区域检查（节点序 outlives） | `src/compiler/region_check.cr:34-57, 105-158` |
| provenance 界限 + 运行期回填 | `src/compiler/provenance_verify.cr:52-133` |
| 并发 opcode | `src/compiler/ast.cr:546-548, 565` |
| `go` lowering | `src/compiler/ir_gen.cr:1634-1700` |
| IR_YIELD/IR_AWAIT = eager 近似 | `src/compiler/interp.cr:385-390, 794`; `src/arch/x86_64/instr.cr:1413-1417, 1481-1490` |
| `move` 关键字 | `src/compiler/lexer.cr:102`; `grammar/core.ebnf:42`; `src/compiler/ast.cr:200`; `src/compiler/checker.cr:3679-3680`; `src/compiler/ir_gen.cr:2878-2879` |
| CLI 8 命令（无 explain/analyze/dump-vcs） | `src/compiler/main.cr:234-241` |
| 配置面仅 `name` | `src/compiler/project.cr:11-25`; `src/compiler/Core.toml` |
| `--dump-vcs` 仅 plan + 在飞分支 | `docs/superpowers/plans/2026-09-16-verification-slice.md:97`; `feature/spec-grammar` T4（`zkymqkqy`） |
| 决策记录/explain/analyze（仅设计） | `docs/superpowers/specs/2026-09-11-explain-predict-incremental-design.md` §1/L1/L2/L8/§1.7 |
| 四形态 + obs + 顺序源白名单 + 无 enforce 档 | `docs/superpowers/specs/2026-09-11-merge-semantics-design.md` L1-L8、§1.0、§2、§4.1、§4.2 |
| `select` = 最早到达，已定性待修 | `docs/dataflow-design.md:102`; `docs/project-book.md:241`; S-E §3.1 |
| 证书不落 `.ccr` | `docs/maintainer/design/existence-structure.md:111` |
| region 两义登记 | `docs/maintainer/design/region-model.md:60-62` |
| 每 G arena / Yield-Recv 消息区域 | `docs/maintainer/design/region-model.md:41-52` |
| 消息边界标签 spec（SHARE） | `docs/superpowers/specs/2026-09-04-message-copy-elision-design.md:37-45, 90-98` |
| GMP ADR | `docs/maintainer/adr/adr-0017-concurrency-gmp.md` |
| TODO 并发条（含过时注记） | `TODO.md:221-226` |
| alloc 计数器生命周期（从不复位） | `src/compiler/globals.cr:351`（声明）· `:509-540`（`reset_frontend_state` 未含它，仅复位 `g_alloc_pts_cap:538`）· `src/compiler/ptr_analysis.cr:213-217`（唯一写点） |
| 本轮登记的三条 TODO | `TODO.md` → `#2026-09-17-18`（`move` 删除）· `#2026-09-17-19`（64 上限静默截断 + 计数器不复位）· `#2026-09-17-20`（文档漂移三处） |

## 附录 B：本轮方法与边界

- **只读**：零构建、零源码改动；未跑任何编译/测试命令（所有事实来自读码）。
- **不改设计**：全文对维护者原文的处理 = 写进文档 + 条目化 + 对接 + 提问；**无一处**改写、补充或缩减原设计。
- **推断标注**：§15 中标「推断」的仅 15.2 少数行（可复用性判断），事实行均可回溯到附录 A 锚点。
- **未覆盖面（本轮显式不做）**：多 M 运行时的实测行为、`go`/`chan` 语料的运行时行为验证、性能量级评估、`.ccr`/ELF canary 的实跑复核、`TODO #2026-09-17-19` 的 64 上限 **RED 实测**（判据要件已列，未跑）。
- **裁定轮边界**：13 门裁定值由维护者 / team-lead 给出，本文只做**写进文档与落点**（§11.1 / §13.0 / §14 / §16.0）；裁定值本身未经本文复核，若与裁决原文有出入以裁决原文为准。

---

## 附录 C：并行批次摩擦点登记（`TODO.md` 结构性序列化点）

> 本附录**不属于并发模型设计**——只登记本批（2026-09-17/18）实测到的**仓库协作摩擦点**，供后续裁决。**本批不做任何改动**（纯登记）。

- **事实**：`TODO.md` 是每批都要追加的共享清单 ⇒ **谁后合谁冲突**。2026-09-17/18 两日内实测 **7 次**同族冲突：批 5 × 批 6 · 批 5 × 并发 · at-rename × 并发 · `#101` × 本批 · `#103`（批 6）× 本批 · `#104`（缓存批）× 本批 · **`#107` × 本批**（09-18，本 spec 的补注 PR）。其中第 6 次连带逼出一次**取号顺移**（本批 `16–18` → `18–20`，依常设规则「先合者保留、后合者整体连续顺移」）。各轮均按「**两侧全保**」消解（develop 侧号段与本批号段全留、复跑 J 判据）。
- **频次证据（可核锚点）**：7 次全部落在 **09-17 晚间至 09-18 凌晨的两日窗口**（跨午夜）；其中**四次 merge 级冲突集中在 09-18 `00:22–01:16` 的 54 分钟窗口**——merge 时间戳可核：`#101` 00:22 · `#103` 00:39 · `#104` 00:48 · `#107` 01:13（每次各逼出本批一次 rebase）。单轮成本 ≈ rebase + 冲突消解 + 复跑 J ≈ **10–15 分钟/轮**（另含两次因 jj 工作副本语义触发的额外恢复——已另行落长期记忆，不在此展开）。
- **结论（频次更新后不变）**：分布**未改变结论方向**——① 「只追加 + 两侧全保 + 复跑 J」仍是够用的缓解（每轮成本可预期、判据机械可复用）；②/③（分片 / 索引-条目分离）仍不上。**触发条件**：单日同族冲突 ≥ 5 次或单轮成本显著上升（>30 分钟/轮）时重议。
- **性质**：**结构性**（不是任何一批的失误）——编号空间已用日期段分区（见 `TODO.md` 头部约定），但**文件本身仍是单点**：索引表（映射表）与条目体同文件、且都在同一区段追加。
- **候选缓解方向（择一，均未实施）**：① 每批只追加 + 合并冲突一律「**两侧全保**」+ 复跑 `tests/harness/test_todo_id_migration.py`（**当前实践，够用**——本批三轮均以此消解，J1–J5 5/5）；② 拆分片 `TODO/<date>.md`（按日期分区下沉到文件系统）；③ 条目体与索引表分离（索引由脚本生成，消除同区段碰撞）。
- **倾向**：**①**（成本最低，且已有机械判据兜底）；若冲突频度继续上升再议 ②/③。
