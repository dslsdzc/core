# McTT 到 Core 验证内核移植设计（M1）

> 目标：将 McTT（ICFP'25 全验证 MLTT 内核）原样移植为 Core 实现，作为语义保留验证管线的信任根（M1）。
> 信任根原则：规范先行 + 验证继承（McTT 的 Rocq 定理）+ 差分对拍（OCaml 参考与 Core 实现）。

## 背景与决策链

本设计是「语义保留到形式化验证」路线的第 1 个阶段目标。前置讨论（2026-08-15）确定的决策链：

1. 归纳不可绕过：有限证明覆盖无穷域，必须有「基础情形 + 传播」结构（等价于良基性/最小不动点/ω-规则有限化）
2. 信任根 = 能描述归纳的最小机器：不实施归纳，只检查归纳
3. W-类型是方向，但 M1 原样移植 McTT：McTT 的原生归纳方案是 ℕ（唯一），不是 W；M1 优先继承验证，W 扩展留作后续独立议题
4. 不采用证书管线：M1 只做内核本身（类型判定），SMT 证书/自动化是后续阶段目标
5. 基准是已经验证过的内核：不手写 C 版，以 McTT 为基准
6. 规范先行（2025 Lean 内核 bug 事件的教训）：先有规范，后实现；信任根是规范（几百行可审计），不是代码

## McTT 理论范围（已核对 artifact）

来源：McTT（Jang/Gaulin/Hu/Pientka，ICFP'25，DOI 10.1145/3747511）
仓库：https://github.com/Beluga-lang/McTT/tree/icfp25
artifact：https://zenodo.org/records/15712175

术语构造子（`theories/Core/Syntactic/Syntax.v`，已核实）：

```
exp:
  (typ N)     宇宙 Type_N（nat 索引的层级）
  (nat)       ℕ
  (zero)      ℕ 构造子 0
  (succ t)    ℕ 构造子 successor
  (natrec A mz ms n)   ℕ 消除子（recursor，唯一归纳方案）
  (pi A B)    Π 类型
  (fn A M)    λ 抽象
  (app M N)   应用
  (var x)     de Bruijn 变量
  (sub t s)   显式替换应用
sub:
  (id) | (weaken) | (compose s1 s2) | (extend s t)
正规形：nf（typ/nat/zero/succ/pi/fn/neut）+ ne（natrec/app/var）
```

没有 Σ、没有 Id、没有 W-类型。唯一的归纳方案是 ℕ + natrec。

验证覆盖（Rocq 机械化）：

- 健全性 + 完备性：算法检查器 ⟺ 声明式规范（良构 ⟺ 被接受）
- NbE 归一化证明（untyped domain model，Abel 2013 路线）
- 累积宇宙 + 协变子类型
- 一致性（推论）
- 提取：可读的 OCaml 代码（人类可读质量，无证明见证）；唯一未验证组件 = lexer/pretty-printer

## 架构

```
src/kernel/                    Core 版内核（用户手工移植）
├── mctt.cr                    术语表示：exp/sub/nf/ne + 上下文（对应 Syntax.v）
├── subst.cr                   显式替换操作（对应替换引理）
├── nbe.cr                     求值 + 读出（对应 Semantic/Evaluation + Readback）
├── subtype.cr                 协变子类型 + 累积宇宙（对应 Algorithmic/Subtyping）
├── check.cr                   双向类型检查：检查 + 推断（对应 Algorithmic/Typing）
├── term_io.cr                 共享文本格式读取器（测试工具，Claude 写）
└── kernel_main.cr             CLI：术语文件到判定，再输出规范化结果（用户写）
tools/mctt_ref/                OCaml 参考侧（McTT 提取 + 薄 harness，Claude 写）
tests/kernel/                  语料生成器 + 差分对拍脚本（Claude 写）
docs/verifier/kernel-spec.md   规范转写（Claude 写，M1 第一步）
```

组件划分原则：每个单元一个职责、接口清晰、可独立测试；与 McTT 源文件一一对应（`mctt.cr` 对应 `Syntax.v`，`nbe.cr` 对应 `Semantic/`，`check.cr` 对应 `Algorithmic/Typing`），差分失败时可以直接定位到参考实现的对应行。

## 分工

| 方 | 交付 |
|---|---|
| Claude | kernel-spec.md 规范转写、共享格式协议定义、tools/mctt_ref/ OCaml harness、tests/kernel/ 语料生成器（穷举+随机+案卷）、差分对拍脚本、term_io.cr（测试工具，非内核本体） |
| 用户（手工） | src/kernel/ 内核本体全部移植：mctt/subst/nbe/subtype/check + kernel_main.cr，对照 kernel-spec.md + OCaml 参考 |

规范转写文档（kernel-spec.md）的地位是移植契约：规则逐条、签名、关键条件精确到可以直接对照编写代码；严格对照 McTT Rocq 源码（`theories/Core/Syntactic/System.v` 规则、`Algorithmic/` 算法），不依赖二手转述。

## 数据流与共享格式

```
语料文本（术语查询 + 判定目标）
   ├── tools/mctt_ref/（OCaml：读取器 -> McTT 提取检查器）得到结果 A
    └── kernel CLI（Core：term_io 读取器 -> 检查器）得到结果 B
差分对拍：A ≡ B 逐位一致
```

查询类型（四种，覆盖内核全部判定面）：

| 查询 | 输入 | 输出 |
|---|---|---|
| `check` | Γ ⊢ t : T | accept / reject |
| `infer` | Γ ⊢ t ⇒ ? | 推断类型（正规化后规范化打印） |
| `convert` | t ≡ u : T | yes / no |
| `subtype` | A ≤ B | yes / no |

共享文本格式（S-表达式风格，与 exp 构造子对应）：

```
exp: (typ N) | (nat) | (zero) | (succ t) | (natrec A mz ms n)
   | (pi A B) | (fn A M) | (app M N) | (var x) | (sub t s)
sub: (id) | (weaken) | (compose s1 s2) | (extend s t)
```

关键约束：输出必须规范化（推断类型先正规化再打印），否则两侧同一类型写法不同，差分结果会大量假阳性。规范化打印本身也是差分测试的一部分，打印器出错也会被对拍发现。

## 测试语料策略

语料全部由 OCaml 侧生成并确认期望值（McTT 检查器作为判定依据），Core 侧只读同一文件：

| 层 | 内容 | 检查重点 |
|---|---|---|
| 穷举 | 大小 ≤ N 的全部语法项 | 小空间全覆盖，接受/拒绝/推断逐位一致 |
| 随机 | 坏项为主（随机构造，大多非良构）+ 类型导向生成合法项 | 拒绝路径 + 推断路径 |
| 案卷 | Nat_ind 证明项、λx.xx 拒绝、宇宙违规、natrec 归约、Π 逆变/协变子类型、显式替换组合（每类 ≥ 3 条） | 经典难项 |

## 错误处理

- 读取器格式错误时按行号报错（语料静态生成，不算差分失败）
- 检查器拒绝路径输出统一 `reject` + 原因类别
- 差分只比较 accept/reject 和规范化推断类型，不比较错误消息文本（避免措辞差异造成假阳性）
- 穷举小项无资源风险；随机生成限深度

## M1 阶段目标顺序

```
1. 规范转写 docs/verifier/kernel-spec.md（Claude）
2. 格式协议 + OCaml 参考 harness tools/mctt_ref/（Claude）
3. 语料生成器 + 案卷（Claude）
4. src/kernel/*.cr 手工移植（用户，对照 spec + OCaml 参考）
5. term_io.cr + 差分对拍脚本（Claude）
6. 全语料对拍全部通过 = M1 完成
```

## 验收标准

1. 差分全部通过：穷举层全部通过，随机 ≥ 1000 条全部通过，案卷 ≥ 20 条全部通过
2. kernel-spec.md 与 McTT Rocq 源码逐规则对应（可审计）
3. McTT 理论范围原样继承：Π + ℕ + 累积宇宙 + NbE + 显式替换，无增删

## 参考

- McTT 论文：https://dl.acm.org/doi/full/10.1145/3747511
- McTT 仓库：https://github.com/Beluga-lang/McTT/tree/icfp25
- McTT artifact：https://zenodo.org/records/15712175
- 前置设计：docs/verifier-kernel.md、docs/spec-design.md
