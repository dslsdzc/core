# 验证内核选型与融合架构（Verifier Kernel）

> 定位：受众 = 学术(兼维护者)；状态 = active

> 信任根 = CIC 内核。表达力 = CIC + 公理 + HoTT 库。自动化 = 证书形态（计算在外、健全性在内）。
> 融合各家之长，不选边——每个维度取最优，其他体系全部变成方法贡献。

## 一、问题

规约系统（`docs/design/spec-design.md`）需要 Coq 级别的表达力（依赖类型/归纳/高阶量词）。表达力由**验证内核**承载——内核是信任根：**内核有 bug = 一切证明皆空**。本文档记录内核选型论证与融合架构决策（2026-08-10）。

## 二、理论体系全谱系（选型时的候选）

| 体系 | 代表 | 表达力 | 内核规模 | 数学完备性 | 自动化生态 |
|---|---|---|---|---|---|
| **CIC**（归纳构造演算） | Rocq / Lean 4 |  依赖类型+归纳+高阶 | 中等（Rocq 7.8k 行 / **Lean 3k 行**） |  函数外延性/商类型要公理 |  SMTCoq（Rocq）、hammer |
| **MLTT**（Martin-Löf） | Agda / McTT |  同 CIC 族（归纳族更精确） | 中等 |  同 CIC |  弱 |
| **HoTT/Cubical** | Cubical Agda、redtt |  + 商类型/外延性定理可证 | 大（归一化复杂） |  理论最优 |  生态小 |
| **HOL**（简单类型论） | Isabelle/HOL、HOL Light |  无依赖类型（表达力上限） | 极小（HOL Light ~500 行） |  外延性天然 |  sledgehammer 自动化领先 |
| **LF/公理拼装** | Metamath |  靠公理 | 极小（~600 行） | 依赖公理集 |  |

**选型结论**：对 Core 的约束（依赖类型表达力 + 自举路线 + SMT 证书架构）——
- 理论最优是 HoTT，**工程最优是 CIC 系**
- HOL 系出局（无依赖类型）；MLTT 与 CIC 同族（CIC 的归纳类型更完整）；HoTT 的完备性用公理 + 库层补
- CIC 系中 Lean 4 内核（~3k 行）是自举最友好的实现

## 三、2025–2026 最新扫描（无全新竞争体系，全新的是方法）

| 工作 | 年份 | 贡献 | 对 Core 的意义 |
|---|---|---|---|
| **McTT**（Jang/Gaulin/Hu/Pientka, ICFP'25） | 2025 | **全验证**的 MLTT 内核（含 NbE 归一化证明，OCaml 提取；除 lexer/pretty-printer 全管线验证） | 内核"全验证"从口号变工程——自举路线终点的参考方法 |
| **Andromeda 2**（Bauer/Petković） | 2022+ | **证书内核形态**：归一化/等式检查在内核外，内核只构造 judgement + 验证证书；用户可定义理论 | 与 SMT 证书架构**同构**——确认"计算在外、健全性在内"是当代前沿 |
| **Definitional Proof Irrelevance**（Felicissimo 等, LICS'26） | 2026 | CIC + 观察等式 + 严格命题（定义性证明无关），一致性与 canonicity 证明，Rocq 实现 | CIC 系在活跃演进（不是停滞旧技术） |
| **Lean4Less**（Vaishnav, 2026） | 2026 | Lean 内核缩小化翻译（去掉 K 归约等便利定义性等式，Lean− 更小理论） | 抄 Lean 内核可抄缩小版——内核最小化参考 |
| **Lean 内核 bug 事件**（Collatz/AI） | 2025 | AI 利用嵌套归纳类型的**无规范内核 bug** 产出假证明；外部检查器复制同一 bug（代码即规范） | **教训：自举内核必须有正式规范**——先规范后实现，或用 Rocq 验证（MetaRocq 路径） |

**扫描结论**：没有推翻 CIC 的全新理论体系；全新的是**内核形态**（证书化、验证化）和**元方法**（NbE 验证）——全部可以吸收进既有架构。

## 四、融合架构（决策，2026-08-10）

不选边——**每个维度取最优，其他体系降级为方法贡献**：

```
┌─ 内核层（信任根）───────────────────────────────────┐
│  CIC（Lean 4 风格，~3k 行，可 Lean4Less 式缩小化）        │
│  ├─ 表达力：依赖类型/归纳/高阶量词 ← CIC 原生               │
│  ├─ 理论扩展：公理层 + HoTT 库（用 CIC 证明 HoTT）          │
│  │    ← Voevodsky 路线（HoTT/Coq、UniMath 先例）            │
│  └─ 远期：McTT 式 NbE 全验证（自举后给内核机械证明）          │
│       ← ICFP'25 McTT                                       │
└────────────────────────────────────────────────────┘
┌─ 验证层（计算在外，内核只验证证书）─────────────────┐
│  ├─ SMT 证书 → 证明项 → 内核验证 ← SMTCoq (CAV'17)         │
│  ├─ 归一化/等式检查外置，judgement 证书化                    │
│  │    ← Andromeda 2（同构确认）                              │
│  └─ 复杂检查器反射化（库层实现 + 一次证明）                   │
│       ← SMTCoq 检查器模式                                    │
└────────────────────────────────────────────────────┘
```

### 决策要点：三个维度各自最优，互不妥协

| 维度 | 取谁的 | 为什么 |
|---|---|---|
| 信任根 | CIC 内核（最小）+ McTT 验证方法（远期机械证明） | 表达力 + 可验证性兼得 |
| 表达力 | CIC + 公理 + HoTT 库（不换理论，挂载） | 数学完备性用库层拿，内核零增长 |
| 自动化 | 证书形态（SMTCoq + Andromeda 同构） | 计算在外、健全性在内——与自举/验证路线天然兼容 |

### 为什么 HoTT 不换内核：用 CIC 证明 HoTT

- HoTT/Coq 与 UniMath 的先例：标准 CIC 内核 + Univalence 公理（Voevodsky 模型证明一致）
- 公理化 UA 不可计算（含 UA 消除的证明项归一化会 stuck）——但**日常规约验证不用 UA**，它只在数学库层需要——工程分层天然隔离
- Lean 4 内核原生支持 quotient + proof irrelevance（Rocq 无）——Lean 内核 + UA 公理 ≈ 更完整的 HoTT 基础
- 结论：**HoTT 是挂在 CIC 上的公理 + 库层，不是竞争体系**

## 五、信任根与自举路线

1. **初期**：绑定成熟内核（候选：Rocq / Lean 4，开放决策）
2. **自举**：用 Core 写出 CIC 内核（Lean 4 风格，可缩小化）→ 替换外部依赖（与 corec 自举同构）
3. **验证**（远期）：McTT 式 NbE 全验证——给自举内核机械正确性证明
4. **规范先行**（内核 bug 事件教训）：自举内核**先有正式规范，后实现**——避免"代码即规范"；规范可用 Rocq 验证（MetaRocq 路径）

先例：Coq Coq Correct!（被证明正确的 Coq 内核）、Milawa（链式自举：A 验证 B，B 验证 C…）、McTT（全验证管线）、MetaRocq / lean4lean / agda-core（验证内核进行中——"验证内核时代即将到来"）。

## 六、开放决策点（挂起，待外部贡献者参与）

| 决策点 | 状态 |
|---|---|
| **内核选择：Rocq vs Lean 4** |  挂起——两者都是 CIC 类，规约语言/SMT 证书/翻译桥/自举路线不受影响，等社区参与 |
| 整数语义（数学整数 vs 机器整数，见 spec-design §9.4） |  倾向"默认数学整数 + 显式位宽标注"，与内核选择一并决策 |
| 自举内核的规范语言 |  随自举进度演化（候选：Core 规约语言自身 / Rocq） |
| 证明项逃逸的最终形态 |  随内核选择与自举进度演化 |

## 参考

- **SMTCoq**（Ekici/Mebsout/…, CAV'17）— SMT 证书 → Coq 证明项，求解器不可信、健全性只在内核
- **McTT**（Jang/Gaulin/Hu/Pientka, ICFP'25）— 全验证 MLTT 内核，NbE 归一化证明，OCaml 提取
- **Andromeda 2**（Bauer/Petković Komel, LMCS'22）— 证书内核形态：归一化在内核外，judgement 证书化，用户可定义理论
- **Definitional Proof Irrelevance Made Accessible**（Felicissimo 等, LICS'26）— CIC + 观察等式 + 严格命题
- **Lean4Less**（Vaishnav, 2026）— Lean 内核缩小化翻译（extensional-to-intensional）
- **Coq Coq Correct!**（Sozeau 等, 2020）— 被 Coq 证明正确的 Coq 内核
- **Milawa / Self-certification**（Strub 等, POPL'12）— 链式自举，信任降到最小可审计内核
- **MetaRocq / lean4lean / agda-core** — 验证内核进行中项目（INRIA 2026 综述）
- **HoTT/Coq、UniMath** — CIC + Univalence 公理形式化 HoTT 的先例
