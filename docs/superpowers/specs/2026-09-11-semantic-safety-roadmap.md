# 语义安全路线图与八份设计 spec 的共享契约

日期：2026-09-11
状态：**路线图定稿（用户裁决：全部起草）**——本文件不是设计本身，而是 8 份设计 spec 的**共享契约 + 清单 + 起草/实施节奏**。
性质：战略层路线文档（用户与外部 AI 讨论收敛后的方向确认）+ 后续各 spec 的术语与边界基准。

关联：
- `docs/superpowers/specs/2026-08-30-type-system-direction-design.md`（14 条定案：类型 = 图标注 / 接口 = 契约 / where 三档）
- `docs/superpowers/specs/2026-09-10-type-interface-unification-design.md`（R2：双轴接口注册表 + 语义子类型引擎——本路线图的**判定器地基**）
- `docs/memory-model-capability-lattice.md` v4（能力 = ⟨身份符号, 授权集, 域约束, 派生源⟩；**M1 定论：能力不提升一等公民，授权归治理层**）
- `docs/memory-model.md`（缓存语义七条 / 条款 4b 图内不可重算）/ `docs/pointer-model.md`（provenance / asp）
- `docs/superpowers/specs/2026-08-23-hw-map-design.md`（设备层）+ `specs/2026-09-05-hardware-interface-table.md`（指令/运行层）
- `TODO.md` 性能自动化 / 验证与工具自动化两族（2026-08-30 记）

---

## 0. 论题（为什么安全线不是新方向）

两条表面无关的线索（① CWE/OWASP 里内存安全之外仍站着一大批类别；② C++/SO 调查里依赖管理/构建时间/并发复杂度比 UAF 更痛的工程问题）在 Core 上收敛到**同一个机制**：

> **图上的正交属性轴 + 义务阶梯**——把尽可能多的漏洞/风险类别，从「程序员规范」变成「非法语义或不可静默消失的义务」。

- **义务阶梯**已有半成品：定案 5 的 where 三档（常量 → 编译错 / 符号 → VC / 动态 → 运行时检查）；本路线图把它补成**四档**（+ 拒编）。
- **属性轴**是定案 1「类型 = 图标注」的直接推广。
- **判定器**在 R2 落地（P0 引擎 + P2a 判定替换：引擎已成为判定权威）。

## 1. 共享契约（8 份 spec 必须逐字遵守）

### 1.1 术语

| 术语 | 定义 |
|---|---|
| **属性轴**（attribute axis） | 图对象/边上的**开放标注**维度：`trust`（可信度）/ `secrecy`（机密性）/ `integrity`（完整性）/ `authority`（授权）/ `lifetime`（生命周期）/ `state-version`（状态版本）/ `effect`（副作用） |
| **义务**（obligation） | 由属性轴导出的、必须在编译/验证期被处置的判定要求 |
| **四档义务** | ① **prove**（静态可证 → 零成本通过）② **enforce**（不可证但可运行时强制 → 插入 enforcement）③ **proof-required**（不可证也不可强制 → 要求用户提供 proof/contract）④ **reject**（高安全模式下仍无法处置 → 拒绝编译） |
| **policy** | 一组图上约束（`G + P ⊢ Safe` 里的 `P`）：**数据而非语法**——新增安全模型不改 Graph 本体、不加关键字 |
| **declassify** | 显式降密/放行节点：`Secret → Public` 的唯一合法通道（同构地：`Untrusted → Trusted` 的净化节点） |
| **sink / source 模型** | 领域侧的「危险落入点 / 不可信来源」声明——**由领域库提供**（类型化构造器），语言只给流纪律与义务阶梯 |

**轴语义真源（2026-09-11 用户裁决 D1(a)）**：`trust` = **可判的传播轴**（来源 = 库声明 + 自动推导 + 净化节点）；**来源真实性的 attestation 不可判**（属 §1.3 第 2 类），但**程序内传播可判**——该传播面即 `trust` 轴。`integrity`（= 可篡改性，与 `trust` 对偶但**不同轴**）不因「不可判」改写；S-B3 的 `Secret ↛ Public` 对偶方向（`Untrusted ↛ Trusted`）**消费 `trust` 轴**，不单列第二判定面。三份消费方（S-A / S-B1 / S-B3）各写「谁定义 / 谁判定 / 谁是消费者」对表（承 D1 共同要求）。

**放行 / 声明条目（2026-09-11 用户裁决 D2(a)）**：任何**绕过义务的通道**（`¬义务 → 义务`）**只**经 S-A §3.1 的「放行 / 声明条目」栏（`kind{declassify｜grant｜deny｜stability} · 主体/身份 · 目标/范围 · 理由 · 派生源 · 义务引用`），且**必须落台账**。**形态默认 = 图上显式节点**；偏离节点形态者（`grant`/`deny` 边集合、`stability` 注解）须在 S-A **显式豁免并补审计字段**——不得沉默。

### 1.2 原则（硬性）

1. **属性不升格为语言 primitive**（承 M1 定论与定案 1/12）：属性 = 开放 semantic annotation / relation；只有**义务**可能拒绝编译。
2. **策略面归库，纪律面归语言**：SQL/HTML/shell 的语法正确性由**领域库**用类型化构造器表达（`SQL<Structure>` 等）；语言只负责「不可信数据不能到达解释器语法位」这类**流纪律**与义务阶梯。**禁止**把某类漏洞做成内建特判（那是 lint 换皮）。
3. **义务不静默消失**（可承诺的强 claim）：证不出 → 落 ②/③/④ 之一，**绝不静默当通过**。**不承诺**「能自动证明所有程序安全」（Rice/halting 边界）。
4. **判定统一走引擎**：义务判定 = R2 引擎的类型项判定（`ty_sub`/`ty_equiv` 等），策略 = 附加的形状项/约束，不另建判定体系。
5. **声明式上限 + 命令式下限**（定案 14）：本路线图只碰声明式上限；执行/副作用/内存的命令式下限（state edges / region / 调度）不动。

### 1.4 确定性轴与「不确定性 = 显式请求」（用户 2026-09-11 追加裁决）

**论题**：目标**不是**「Core 是最确定的语言」（标量式 claim 必然在局部维度被 Esterel/Lustre/SPARK-Ravenscar 打败），而是——

> **每条可观测的不确定性，必须可归因到「显式语义源」或「已证明的汇合无关性」。**
> 即：`物理不确定性 ⇏ 语义不确定性`，除非源码语义明确允许。（claim 形态：「Core = 不确定性最难偷偷混进程序的语言」）

**轴族**（并入 §1.1 的轴表，作为 `determinism` 族）：

| 轴 | 含义 | Core 现状 |
|---|---|---|
| `D_value` | 值/结果确定性 | 强（纯函数语言层面） |
| `D_effect` | 副作用顺序确定性 | 有基础（state edges 显式） |
| `D_memory` | 内存行为/生命周期确定性 | 强（region 锚定 + bump/reset） |
| `D_timing` | 时间/WCET | **三值化**（见下）——不许撒谎 |
| `D_resource` | 资源上界确定性 | 有基础（需静态 bound；接 bounds-inference） |
| `D_external` | 外部输入依赖确定性 | 边界节点可归档（图上有边界） |
| `D_mapping` | **跨机器语义确定性** | **Core 特有轴**（语义 ≥ 映射；映射换而语义不变）——最强的差异化面 |

**执法 = 四档义务**（与 §1.1 四档同构）：

| 情形 | 落档 |
|---|---|
| 依赖/状态边足证「汇合与调度无关」 | **prove**（零成本） |
| 顺序由显式顺序源固定（`merge_ordered`） | 落到确定实现 |
| 语义明文允许（`race` / `select_any`） | **显式不确定**——必须进报告面，不得偷偷发生 |
| 既未证明也未标注（**隐式竞争**） | **reject** ← 真正的执法点 |

**迁移窗口 W1（2026-09-11 用户裁决 D3）**：`select` 重定给出**显式迁移窗口**——默认 **1 个发布周期**：窗口内 lenient（保留现语义 + 具名诊断），窗口后**强制标注**（未标注即按隐式竞争处理）。**不承诺永久 lenient**；窗口的语义实现归 **S-E**。窗口内 `select` 仍受 S-A §2.6 的判定侧禁令（不得作为「显式顺序源」输入 prove）。

**胜者身份（witness，2026-09-11 用户裁决 D9）**：`race` 的胜者身份**允许**作为显式出参（witness）——落在既有机制内：witness = 显式语义源，登记为 `EXPLICIT` 不确定源 + 报告义务（本表行 3 的实例），不新增语义。

**默认强度分层（2026-09-11 用户裁决 D3，总口径）**：本地开发 = 登记 + 继续编译；**strict 档 / CI 门槛 = 严（拒编）**；② **enforce 默认启用**（可 enforce 的一律 enforce，高安全档关闭）；**未声明的边界条目取 `unknown`（保守判定方向）但不拒编**，报告面可见。细则落 S-A §2.2 附。

**时间三值化（`D_timing`，硬性）**：`PROVED`（机器无关上界：分配次数/字节、在飞任务数、通信量——可从 region/图证明）｜`MODELED`（机器相关时间 = **成本模型估计，明确标注"模型非证明"**，复用 S-C 成本模型）｜`UNKNOWN`。**禁止**把 MODELED 呈现为 WCET 证明。

**现有语义缺陷（2026-09-11 用户定性 = 待修）**：`select` 现语义 = **「最早到达的令牌」**（`docs/dataflow-design.md:102`；`docs/project-book.md:241` 同款）——**把物理调度顺序泄进了语义**，而 `docs/execution-model.md:15` 同时宣称「DAG ⟹ 确定性」。两句互相拆台 → 按本节的「不确定性 = 显式请求」重定（迁移路径与兼容窗口见 S-E）。

**先例（本原则已在仓内成立）**：`apx` = **显式**放宽数值精度（opt-in）；把同一模式推广到并发/时间/外部输入即本节主张。

**边界**：报告面（`core analyze --determinism` + 不确定性 provenance 链）属 **S-D**；轴族/义务落档属 **S-A**；**汇合语义本身（`merge_deterministic`/`merge_ordered`/`race`/`select_any`）属 S-E**——它改的是执行模型，不得稀释进通用机器。

### 1.3 三类**不可消**的残留（每份 spec 的「不承诺」节必须引用并逐条说明本族落在哪类）

- **错误 specification**：Core 只能证明"程序忠实实现了规则"，不能证明规则本身正确。
- **恶意/失陷外部实体**：供应链、编译机、密钥、硬件后门——用可复现构建/签名/provenance/最小权限**缩小**，不能用语言语义**证明**。
- **需求本身允许危险行为**：shell/browser/kernel/JIT 必须执行外来代码——目标不是禁止能力，而是**证明隔离边界**。

## 2. 清单（8 份设计 spec）

| # | 文件 | 范围 | 依赖 | 关键判据/交付 |
|---|---|---|---|---|
| **S-A** | `2026-09-11-semantic-safety-obligations-design.md` | 属性轴（7 轴，开放标注）+ 四档义务 + policy 接口（挂 R2 接口注册表旁）+ **放行/声明条目统一 schema（D2）** + 未证明义务的落法（诊断/拒绝/强制通道）+ 与 where 三档的关系 | **R2 引擎（已就位）** | 轴/档/接口的定稿 + 「义务不静默」的判定流程 + 最小可实施切片（**A 簇裁决索引见 S-A §0.4**） |
| **S-B1** | `2026-09-11-policy-injection-design.md` | 注入族：`untrusted → interpreter 语法位` 为非法边；参数化通道（值位 vs 语法位） | S-A | 非法边判据（**裸位置判据消费 `trust` 轴，D1(a)**）+ 领域库接口约定（SQL/HTML/shell 三例）+ 正/负控语义 + **切片 1 硬前置拆解（D5/I5）** |
| **S-B2** | `2026-09-11-policy-authorization-design.md` | 授权族：`Can(a,o,r,v) ⟺ ∃合法 capability path`（**带状态版本参数**，D13）；effectful op 须产出证明 | S-A + **capability-lattice v4** | capability path 判定（**唯一 owner = S-B2 §2.1 步①**，D22；def 链倒推不二处实现）+ 与 M1「授权归治理层」的边界（**代价已接受，D14**：无运行期授予/撤销 ⇒ 延伸走能力对象 + 版本见证）+ 与 effect 轴的耦合 |
| **S-B3** | `2026-09-11-policy-information-flow-design.md` | 信息流族：`Secret ↛ Public`，除 `declassify`；含隐式流（branch/timing 面登记） | S-A（**`trust` 轴消费面**，D1(a)：对偶方向 `Untrusted ↛ Trusted` 判的就是 `trust` 的传播） | 流纪律判定 + declassify 语义（**S-A §3.1 放行/声明条目 `kind=declassify`**，D2）+ 隐式流边界（可判定子集） |
| **S-B4** | `2026-09-11-policy-resource-confinement-design.md` | 围栏族：`Path<Root>` / capability-scoped namespace；`../..` = 无法构造目标 capability | S-A + provenance/asp | namespace 判定 + 与 pointer-model 的 reuse + TOCTOU 衔接（**根声明治理 = 装载期校验 + policy 授权，D6**；派生链判定的 owner 归 S-B2，D22） |
| **S-B5** | `2026-09-11-policy-state-version-toctou-design.md` | 状态版本族：check/use 分离版本 = 图上两版本；handle 绑定身份而非 pathname 重查 | S-A | 版本等价判定（κ 粒度 = **对象身份 + 版本见证**，D13）+ 与 state edges/条目的 reuse + 模式清单 + **与 S-E 的执法分界（D23：按变更源身份可判定）** |
| **S-C** | `2026-09-11-performance-without-commitment-design.md` | 性能无实现承诺 + 可移植：纯度/效应/依赖/局部性/精度标注 → 优化器 → 目标描述（**成本模型**接 hw-map）；收纳 TODO 性能自动化家族 | hw-map + **R3/实例化波 2-3 合批** | 标注面 + 成本模型接口 + 「不把机器写进程序意义」的可迁移判据 |
| **S-D** | `2026-09-11-explain-predict-incremental-design.md` | 可解释（`core explain` 决策通道：图→源码 + 映射决策）+ 可预测（内存/任务/通信/deadline 上界）+ 语义增量（ΔSource→ΔGraph→ΔProof→ΔBinary）**+ §1.4 的报告面（`core analyze --determinism` + 不确定性 provenance 链）** | engine + LSP 基建 + 现有 cir cache | 三者各自的可实施切片 + explain 输出契约 + 增量失效面（含 TODO #5 缓存键家族） |
| **S-E** | `2026-09-11-merge-semantics-design.md` | **汇合语义定稿**：`merge_deterministic` / `merge_ordered` / `race` / `select_any` 四形态的**图级**定义 + **物理⇏语义降级义务**（lowering/调度不得引入未声明的不确定）+ `select` 现语义（最早到达）的**迁移路径**（用户定性＝待修）+ 与「自动并发」TODO（可判定性）的接口 | **S-A（轴/四档）；被 S-A 的 determinism 轴族引用** | 四形态语义 + 每形态的义务落档 + `select` 重定与兼容窗口 + 正/负控判据（隐式竞争必须 reject） |

## 3. 起草与实施节奏（用户裁决：全部起草；S-B 一族一份）

1. **起草阶段（本次）**：8 份 spec 全部起草（本路线图 = 共享契约，各 spec 只填自己的范围，**不得**重定义 §1.1 术语或 §1.3 不承诺）。
2. **实施顺序（建议）**：
   - **S-A 先定稿并实施最小切片**（属性轴 + 四档 + 义务判定走引擎）——它是其余 7 份的地基，没有它每族都会退化成特判。
   - **S-B×5**：S-A 定稿后**逐族**出实施计划（每族独立验收；不并行开工，避免语义争议交叉）。
   - **S-C**：与 x86 实例化波 2/3、R3 映射侧**合批**（同一件事的两个名字）。
   - **S-D**：可解释面可先做（用户可见收益直接）；语义增量依赖缓存键修复（TODO #5 家族）。
3. **与在飞工作线的关系**：本路线图**不打断** R2 剩余批（P2b：`iface_ops` 查表接线 + `res_type_node` 两表合一；R3：映射侧/载体）——S-A 的实施排在 R2 收线之后。
