# kernel-spec.md — McTT → Core 内核移植契约

> 定位:受众 = 维护者(内核移植 Task 3/6 实现者);状态 = active(移植契约,对应 McTT 快照);真源 = ~/mctt 源文件(本文件为行号对照转换层)。

> 本文件由 Task 2 生成，行号对应 McTT icfp25 分支。
> 源仓库：`~/mctt`（只读参考，非 git 拷贝）。所有行号均为对应源文件的实际行号，
> 格式为「文件基名:行号」；文件全路径见下表。
> 本文件是 Task 6（Core 手写移植）与 Task 3（协议设计）的**唯一权威**——任何规则实现
> 以本文件为准，任何歧义回到源文件核对。

## 源文件清单

| 简称 | 路径（~/mctt 下） | 内容 |
|------|-------------------|------|
| Syntax.v | `theories/Core/Syntactic/Syntax.v` | 语法构造子（exp/sub/nf/ne）、`q` 替换 |
| System.v | `theories/Core/Syntactic/System.v` | 仅 re-export（System.v:1） |
| System/Definitions.v | `theories/Core/Syntactic/System/Definitions.v` | 类型系统规则（判断/推导） |
| SystemOpt.v | `theories/Core/Syntactic/SystemOpt.v` | 去冗余前提的推论规则（算法层依赖） |
| AlgTyp/Definitions.v | `theories/Algorithmic/Typing/Definitions.v` | 双向类型检查算法规则 |
| AlgSub/Definitions.v | `theories/Algorithmic/Subtyping/Definitions.v` | 算法子类型规则 |
| Domain.v | `theories/Core/Semantic/Domain.v` | 语义域定义 |
| Eval/Definitions.v | `theories/Core/Semantic/Evaluation/Definitions.v` | 求值关系 |
| Readback/Definitions.v | `theories/Core/Semantic/Readback/Definitions.v` | 读出关系 |
| NbE.v | `theories/Core/Semantic/NbE.v` | nbe / nbe_ty / initial_env |
| PER/Definitions.v | `theories/Core/Semantic/PER/Definitions.v` | 语义 PER（逻辑关系层） |
| Completeness.v | `theories/Core/Completeness.v` | 完备性定理 |
| Soundness.v | `theories/Core/Soundness.v` | 健全性定理 |

---

## 0. 全局约定（移植前必读）

### 0.1 de Bruijn 索引方向与上下文序（Task 3/6 以此为唯一基准）

- **上下文是「头部 = 最右（最近绑定）」的 list**。记号 `Γ , A` 定义为
  `cons A Γ`（Syntax.v:151 `Notation "x , y" := (cons y x)`），即 `Γ , A` 把 `A`
  追加到 Γ 的**头部**。上下文 `⋅ , A , B` 读作先绑 A 再绑 B，B 为最右。
- **var 0 = 上下文最右（最近绑定）元素**，索引随绑定深度向外递增。
  依据是查找规则（System/Definitions.v:20-23）：

  ```
  here :  #0 : A[Wk] ∈ Γ , A                    （System/Definitions.v:21）
  there : #n : A ∈ Γ  ⟹  #(S n) : A[Wk] ∈ Γ , B （System/Definitions.v:22）
  ```
  在 `Γ , A` 中 `#0` 指向头部 `A`（其类型经 Wk 提升，因为 `A` 所在上下文比 `Γ` 深一层）；
  外层的 `#n` 变成 `#(S n)`。这与 var 0 = 最右元素完全一致。
- 语义侧同样：`extend_env ρ d := fun n => match n with 0 => d | S n' => ρ n' end`
  （Domain.v:32-37）——环境头部（索引 0）是最近扩展的值；`drop_env ρ := ρ (S _)`
  （Domain.v:41）删除头部。

### 0.2 替换记号与 `q`

- `σ ,, M` := `a_extend σ M`（Syntax.v:147）——替换头部延长。
- `σ ∘ τ` := `a_compose σ τ`（Syntax.v:146）——**右结合；求值时 τ 先作用、σ 后作用**
  （Eval/Definitions.v:73-76：先 `⟦ τ ⟧s ρ ↘ ρτ`，再 `⟦ σ ⟧s ρτ ↘ ρτσ`）。
- **`q` 的定义**（Syntax.v:113）：
  ```
  q σ := a_extend (a_compose σ a_weaken) (a_var 0)
  ```
  即 `q σ = (σ ∘ Wk) ,, #0`：先穿透头部再压入变量 0。用于把「在 Δ 上定义的替换 σ」
  提升为「在 Δ , A 上定义的替换」，使 `M[q σ]` 中 M 的自由变量映射一致
  （用途见 2.3 的 wf_exp_eq_natrec_sub / pi_sub / fn_sub）。
- `Id` := `a_id`，`Wk` := `a_weaken`（Syntax.v:143-144）。

### 0.3 符号约定（本文件规则中使用）

| 记号 | 定义 | 出处 |
|------|------|------|
| `#n` | `a_var n` | Syntax.v:142 |
| `Type@i` | `a_typ i` | Syntax.v:137 |
| `ℕ` | `a_nat` | Syntax.v:136 |
| `Π A B` | `a_pi A B`（B 的上下文 = A 延长后的上下文） | Syntax.v:138 |
| `λ A M` | `a_fn A M` | Syntax.v:134 |
| `succ e` | `a_succ e` | Syntax.v:140 |
| `rec M return A \| zero -> MZ \| succ -> MS end` | `a_natrec A MZ MS M`（注意参数序！） | Syntax.v:141 |
| `M [σ]` | `a_sub M σ` | Syntax.v:130 |
| `⇑ M`（nf 层） | `nf_neut M` | Syntax.v:166 |
| `⇑ a m`（domain 层） | `d_neut a m` | Domain.v:64 |
| `⇓ a m` | `d_dom a m`（domain_nf：类型 + 值 的配对） | Domain.v:65 |
| `⇑! a n` | `d_neut a (d_var n)`（neutral 变量） | Domain.v:66 |
| `ρ ↦ m` | `extend_env ρ m` | Domain.v:68 |
| `ρ ↯` | `drop_env ρ` | Domain.v:69 |
| `λ ρ M`（domain） | `d_fn ρ M` | Domain.v:55 |
| `Π a ρ B`（domain） | `d_pi a ρ B` | Domain.v:59 |
| `$| f & a \|↘ r` | 应用求值（domain 层） | Eval/Definitions.v:7 |
| `⟦ M ⟧ ρ ↘ r` | 求值 | Eval/Definitions.v:5 |
| `Rnf/Rne/Rtyp m in s ↘ M` | 读出（s = 深度 = 上下文长度） | Readback/Definitions.v:6-8 |

### 0.4 移植边界提示

- 记号 `Γ , A ⊢ …` 中 `A` 是**头部**（0.1），因此 `Γ , A ⊢ M : B` 意为「M 在
  上下文 Γ 延长 A 后良型」。Core 移植时若用自身上下文表示（如右扩展 list），
  需将「头部扩展」映射为 Core 的「尾部/头部扩展」并固定一个方向（本文件全部以
  McTT 头部扩展为准）。
- `a_natrec` 的参数序为 `A MZ MS M`（motif、zero 分支、succ 分支、被归纳项），
  与记号 `rec M return A | zero -> MZ | succ -> MS end` 中 M 的位置不同，移植时
  注意按构造子序（Syntax.v:27）。
- d_var 的编号**不是 de Bruijn 索引而是绝对名**（Domain.v:16-19 注释）——在读出时
  通过深度 s 转换为 de Bruijn 索引：`Rne !x in s ↘ #(s - x - 1)`（Readback/Definitions.v:39）。

---

## 1. 构造子清单（Syntax.v）

### 1.1 具体语法 Cst.obj（Syntax.v:7-16，仅语法糖，不移植）

| 构造子 | 类型 | 行号 |
|--------|------|------|
| `typ : nat -> obj` | 宇宙 | Syntax.v:8 |
| `nat : obj` | 自然数类型 | Syntax.v:9 |
| `zero : obj` | 零 | Syntax.v:10 |
| `succ : obj -> obj` | 后继 | Syntax.v:11 |
| `natrec : obj -> string -> obj -> obj -> string -> string -> obj -> obj` | 归纳（含绑定名） | Syntax.v:12 |
| `pi : string -> obj -> obj -> obj` | Π（含绑定名） | Syntax.v:13 |
| `fn : string -> obj -> obj -> obj` | λ（含绑定名） | Syntax.v:14 |
| `app : obj -> obj -> obj` | 应用 | Syntax.v:15 |
| `var : string -> obj` | 具名变量 | Syntax.v:16 |

### 1.2 抽象语法 exp（Syntax.v:20-35）

| 构造子 | 类型 | 含义 | 行号 |
|--------|------|------|------|
| `a_typ : nat -> exp` | `Type@i` | 第 i 个宇宙 | Syntax.v:22 |
| `a_nat : exp` | `ℕ` | 自然数类型 | Syntax.v:24 |
| `a_zero : exp` | `zero` | 零 | Syntax.v:25 |
| `a_succ : exp -> exp` | `succ M` | 后继 | Syntax.v:26 |
| `a_natrec : exp -> exp -> exp -> exp -> exp` | `rec M return A \| zero -> MZ \| succ -> MS end`，参数序 `A MZ MS M` | 自然数归纳 | Syntax.v:27 |
| `a_pi : exp -> exp -> exp` | `Π A B` | 依赖函数类型 | Syntax.v:29 |
| `a_fn : exp -> exp -> exp` | `λ A M` | λ 抽象 | Syntax.v:30 |
| `a_app : exp -> exp -> exp` | `M N` | 应用 | Syntax.v:31 |
| `a_var : nat -> exp` | `#n` | de Bruijn 变量 | Syntax.v:33 |
| `a_sub : exp -> sub -> exp` | `M[σ]` | 替换应用（显式替换！） | Syntax.v:35 |

附：`ctx := list exp`，`typ := exp`（Syntax.v:42-43）。

### 1.3 显式替换 sub（Syntax.v:36-40）

| 构造子 | 类型 | 含义 | 行号 |
|--------|------|------|------|
| `a_id : sub` | `Id` | 恒等替换 | Syntax.v:37 |
| `a_weaken : sub` | `Wk` | 弱化（丢弃头部变量） | Syntax.v:38 |
| `a_compose : sub -> sub -> sub` | `σ ∘ τ`（τ 先作用） | 复合 | Syntax.v:39 |
| `a_extend : sub -> exp -> sub` | `σ ,, M` | 延长 | Syntax.v:40 |

### 1.4 正规形 nf（Syntax.v:69-76）

| 构造子 | 类型 | 含义 | 行号 |
|--------|------|------|------|
| `nf_typ : nat -> nf` | `Type@i` | 宇宙正规形 | Syntax.v:70 |
| `nf_nat : nf` | `ℕ` | 自然数类型正规形 | Syntax.v:71 |
| `nf_zero : nf` | `zero` | 零正规形 | Syntax.v:72 |
| `nf_succ : nf -> nf` | `succ M` | 后继正规形 | Syntax.v:73 |
| `nf_pi : nf -> nf -> nf` | `Π A B` | Π 正规形 | Syntax.v:74 |
| `nf_fn : nf -> nf -> nf` | `λ A M` | λ 正规形 | Syntax.v:75 |
| `nf_neut : ne -> nf` | `⇑ M` | 中性形（嵌入） | Syntax.v:76 |

### 1.5 中性形 ne（Syntax.v:77-80）

| 构造子 | 类型 | 含义 | 行号 |
|--------|------|------|------|
| `ne_natrec : nf -> nf -> nf -> ne -> ne` | `rec M return A \| zero -> MZ \| succ -> MS end`（参数序 `A MZ MS M`） | 中性 natrec（参数均正规） | Syntax.v:78 |
| `ne_app : ne -> nf -> ne` | `M N` | 中性应用 | Syntax.v:79 |
| `ne_var : nat -> ne` | `#n` | 变量 | Syntax.v:80 |

nf/ne 到 exp 有强制嵌入（Syntax.v:101-102），nf/ne 有可判定相等（Syntax.v:104-111）。

---

## 2. 类型系统规则（System/Definitions.v）

### 2.0 判定形式（System/Definitions.v:8-16）

| 判定 | 含义 | 行号 |
|------|------|------|
| `⊢ Γ` | 上下文良构 | System/Definitions.v:8 |
| `⊢ Γ ≈ Γ'` | 上下文等价 | System/Definitions.v:9 |
| `Γ ⊢ M ≈ M' : A` | 项等价 | System/Definitions.v:10 |
| `Γ ⊢ M : A` | 项良型 | System/Definitions.v:11 |
| `Γ ⊢s σ : Δ` | 替换良构 | System/Definitions.v:12 |
| `Γ ⊢s σ ≈ σ' : Δ` | 替换等价 | System/Definitions.v:13 |
| `⊢ Γ ⊆ Γ'` | 上下文子型 | System/Definitions.v:14 |
| `Γ ⊢ A ⊆ A'` | 类型子型 | System/Definitions.v:15 |
| `#x : A ∈ Γ` | 上下文查找 | System/Definitions.v:16 |

全部为互归纳定义（`Scheme … mut_ind`，System/Definitions.v:351-373）。

### 2.1 上下文查找 ctx_lookup（System/Definitions.v:20-23）

```
here :  #0 : A[Wk] ∈ Γ , A                                   (System/Definitions.v:21)
there : #n : A ∈ Γ  ⟹  #(S n) : A[Wk] ∈ Γ , B                (System/Definitions.v:22)
```

### 2.2 上下文良构 wf_ctx（System/Definitions.v:25-31）

```
wf_ctx_empty :  ⊢ ⋅                                                          (System/Definitions.v:26)
wf_ctx_extend : ⊢ Γ   Γ ⊢ A : Type@i  ⟹  ⊢ Γ , A                           (System/Definitions.v:27-30)
```

### 2.3 项良型 wf_exp（System/Definitions.v:43-98）—— 11 条

```
wf_typ :
    ⊢ Γ
    ────────────────        (System/Definitions.v:44-46)
    Γ ⊢ Type@i : Type@(S i)

wf_nat :
    ⊢ Γ
    ──────────              (System/Definitions.v:47-49)
    Γ ⊢ ℕ : Type@0

wf_zero :
    ⊢ Γ
    ──────────              (System/Definitions.v:50-52)
    Γ ⊢ zero : ℕ

wf_succ :
    Γ ⊢ M : ℕ
    ──────────────          (System/Definitions.v:53-55)
    Γ ⊢ succ M : ℕ

wf_natrec :
    Γ , ℕ ⊢ A : Type@i
    Γ ⊢ MZ : A[Id,,zero]
    Γ , ℕ , A ⊢ MS : A[Wk∘Wk,,succ(#1)]
    Γ ⊢ M : ℕ
    ─────────────────────────────────────────────────────   (System/Definitions.v:56-61)
    Γ ⊢ rec M return A | zero -> MZ | succ -> MS end : A[Id,,M]

wf_pi :
    Γ ⊢ A : Type@i
    Γ , A ⊢ B : Type@i
    ───────────────────────   (System/Definitions.v:62-65)
    Γ ⊢ Π A B : Type@i

wf_fn :
    Γ ⊢ A : Type@i
    Γ , A ⊢ M : B
    ───────────────────────   (System/Definitions.v:66-69)
    Γ ⊢ λ A M : Π A B

wf_app :
    Γ ⊢ A : Type@i
    Γ , A ⊢ B : Type@i
    Γ ⊢ M : Π A B
    Γ ⊢ N : A
    ─────────────────────────   (System/Definitions.v:70-75)
    Γ ⊢ M N : B[Id,,N]

wf_vlookup :
    ⊢ Γ
    #x : A ∈ Γ
    ──────────────             (System/Definitions.v:76-79)
    Γ ⊢ #x : A

wf_exp_sub :
    Γ ⊢s σ : Δ
    Δ ⊢ M : A
    ────────────────           (System/Definitions.v:80-83)
    Γ ⊢ M[σ] : A[σ]

wf_exp_subtyp :
    Γ ⊢ M : A
    Γ ⊢ A' : Type@i            (i 存在即可；A 的类型**不**检查——
                               不对称，理由见 System/Definitions.v:86-94 注释)
    Γ ⊢ A ⊆ A'
    ────────────────           (System/Definitions.v:84-97)
    Γ ⊢ M : A'
```

### 2.4 替换良构 wf_sub（System/Definitions.v:100-125）—— 5 条

```
wf_sub_id :
    ⊢ Γ
    ────────────            (System/Definitions.v:101-103)
    Γ ⊢s Id : Γ

wf_sub_weaken :
    ⊢ Γ , A
    ────────────────        (System/Definitions.v:104-106)
    Γ , A ⊢s Wk : Γ

wf_sub_compose :
    Γ1 ⊢s σ2 : Γ2
    Γ2 ⊢s σ1 : Γ3
    ────────────────────    (System/Definitions.v:107-110)
    Γ1 ⊢s σ1 ∘ σ2 : Γ3

wf_sub_extend :
    Γ ⊢s σ : Δ
    Δ ⊢ A : Type@i
    Γ ⊢ M : A[σ]
    ────────────────────    (System/Definitions.v:111-115)
    Γ ⊢s (σ ,, M) : Δ , A

wf_sub_subtyp :
    Γ ⊢s σ : Δ
    ⊢ Δ'
    ⊢ Δ ⊆ Δ'
    ────────────────        (System/Definitions.v:116-124)
    Γ ⊢s σ : Δ'
```

### 2.5 项等价 wf_exp_eq（System/Definitions.v:127-259）—— 27 条

记号：`Γ ⊢ M ≈ M' : A`。全部规则：

**替换同余（sub 规则族）**：

```
wf_exp_eq_typ_sub :
    Γ ⊢s σ : Δ
    ────────────────────────────      (System/Definitions.v:128-130)
    Γ ⊢ Type@i[σ] ≈ Type@i : Type@(S i)

wf_exp_eq_nat_sub :
    Γ ⊢s σ : Δ
    ────────────────────              (System/Definitions.v:131-133)
    Γ ⊢ ℕ[σ] ≈ ℕ : Type@0

wf_exp_eq_zero_sub :
    Γ ⊢s σ : Δ
    ────────────────────              (System/Definitions.v:134-136)
    Γ ⊢ zero[σ] ≈ zero : ℕ

wf_exp_eq_succ_sub :
    Γ ⊢s σ : Δ
    Δ ⊢ M : ℕ
    ──────────────────────────────    (System/Definitions.v:137-140)
    Γ ⊢ (succ M)[σ] ≈ succ (M[σ]) : ℕ

wf_exp_eq_succ_cong :
    Γ ⊢ M ≈ M' : ℕ
    ──────────────────────            (System/Definitions.v:141-143)
    Γ ⊢ succ M ≈ succ M' : ℕ

wf_exp_eq_natrec_cong :
    Γ , ℕ ⊢ A : Type@i
    Γ , ℕ ⊢ A ≈ A' : Type@i
    Γ ⊢ MZ ≈ MZ' : A[Id,,zero]
    Γ , ℕ , A ⊢ MS ≈ MS' : A[Wk∘Wk,,succ(#1)]
    Γ ⊢ M ≈ M' : ℕ
    ─────────────────────────────────────────────────────────────────   (System/Definitions.v:144-150)
    Γ ⊢ rec M return A | zero -> MZ | succ -> MS end
           ≈ rec M' return A' | zero -> MZ' | succ -> MS' end : A[Id,,M]

wf_exp_eq_natrec_sub :
    Γ ⊢s σ : Δ
    Δ , ℕ ⊢ A : Type@i
    Δ ⊢ MZ : A[Id,,zero]
    Δ , ℕ , A ⊢ MS : A[Wk∘Wk,,succ(#1)]
    Δ ⊢ M : ℕ
    ─────────────────────────────────────────────────────────────────   (System/Definitions.v:151-157)
    Γ ⊢ rec M return A | zero -> MZ | succ -> MS end[σ]
           ≈ rec M[σ] return A[q σ] | zero -> MZ[σ] | succ -> MS[q (q σ)] end
           : A[σ,,M[σ]]

wf_exp_eq_nat_beta_zero :
    Γ , ℕ ⊢ A : Type@i
    Γ ⊢ MZ : A[Id,,zero]
    Γ , ℕ , A ⊢ MS : A[Wk∘Wk,,succ(#1)]
    ─────────────────────────────────────────────   (System/Definitions.v:158-162)
    Γ ⊢ rec zero return A | zero -> MZ | succ -> MS end ≈ MZ : A[Id,,zero]

wf_exp_eq_nat_beta_succ :
    Γ , ℕ ⊢ A : Type@i
    Γ ⊢ MZ : A[Id,,zero]
    Γ , ℕ , A ⊢ MS : A[Wk∘Wk,,succ(#1)]
    Γ ⊢ M : ℕ
    ─────────────────────────────────────────────────────────────────   (System/Definitions.v:163-168)
    Γ ⊢ rec (succ M) return A | zero -> MZ | succ -> MS end
           ≈ MS[Id,,M,,rec M return A | zero -> MZ | succ -> MS end] : A[Id,,succ M]

wf_exp_eq_pi_sub :
    Γ ⊢s σ : Δ
    Δ ⊢ A : Type@i
    Δ , A ⊢ B : Type@i
    ────────────────────────────────────────────────   (System/Definitions.v:169-173)
    Γ ⊢ (Π A B)[σ] ≈ Π (A[σ]) (B[q σ]) : Type@i

wf_exp_eq_pi_cong :
    Γ ⊢ A : Type@i
    Γ ⊢ A ≈ A' : Type@i
    Γ , A ⊢ B ≈ B' : Type@i
    ──────────────────────────────────   (System/Definitions.v:174-178)
    Γ ⊢ Π A B ≈ Π A' B' : Type@i

wf_exp_eq_fn_cong :
    Γ ⊢ A : Type@i
    Γ ⊢ A ≈ A' : Type@i
    Γ , A ⊢ M ≈ M' : B
    ──────────────────────────────────   (System/Definitions.v:179-183)
    Γ ⊢ λ A M ≈ λ A' M' : Π A B

wf_exp_eq_fn_sub :
    Γ ⊢s σ : Δ
    Δ ⊢ A : Type@i
    Δ , A ⊢ M : B
    ─────────────────────────────────────────────   (System/Definitions.v:184-188)
    Γ ⊢ (λ A M)[σ] ≈ λ A[σ] M[q σ] : (Π A B)[σ]

wf_exp_eq_app_cong :
    Γ ⊢ A : Type@i
    Γ , A ⊢ B : Type@i
    Γ ⊢ M ≈ M' : Π A B
    Γ ⊢ N ≈ N' : A
    ────────────────────────────────   (System/Definitions.v:189-194)
    Γ ⊢ M N ≈ M' N' : B[Id,,N]

wf_exp_eq_app_sub :
    Γ ⊢s σ : Δ
    Δ ⊢ A : Type@i
    Δ , A ⊢ B : Type@i
    Δ ⊢ M : Π A B
    Δ ⊢ N : A
    ────────────────────────────────   (System/Definitions.v:195-201)
    Γ ⊢ (M N)[σ] ≈ M[σ] N[σ] : B[σ,,N[σ]]
```

**β/η 规则**：

```
wf_exp_eq_pi_beta :
    Γ ⊢ A : Type@i
    Γ , A ⊢ B : Type@i
    Γ , A ⊢ M : B
    Γ ⊢ N : A
    ────────────────────────────   (System/Definitions.v:202-207)
    Γ ⊢ (λ A M) N ≈ M[Id,,N] : B[Id,,N]

wf_exp_eq_pi_eta :
    Γ ⊢ A : Type@i
    Γ , A ⊢ B : Type@i
    Γ ⊢ M : Π A B
    ─────────────────────────────   (System/Definitions.v:208-212)
    Γ ⊢ M ≈ λ A (M[Wk] #0) : Π A B
```

**变量规则**：

```
wf_exp_eq_var :
    ⊢ Γ
    #x : A ∈ Γ
    ──────────────             (System/Definitions.v:213-216)
    Γ ⊢ #x ≈ #x : A

wf_exp_eq_var_0_sub :
    Γ ⊢s σ : Δ
    Δ ⊢ A : Type@i
    Γ ⊢ M : A[σ]
    ────────────────────       (System/Definitions.v:217-221)
    Γ ⊢ #0[σ ,, M] ≈ M : A[σ]

wf_exp_eq_var_S_sub :
    Γ ⊢s σ : Δ
    Δ ⊢ A : Type@i
    Γ ⊢ M : A[σ]
    #x : B ∈ Δ
    ────────────────────────   (System/Definitions.v:222-227)
    Γ ⊢ #(S x)[σ ,, M] ≈ #x[σ] : B[σ]

wf_exp_eq_var_weaken :
    ⊢ Γ , B
    #x : A ∈ Γ
    ────────────────────────   (System/Definitions.v:228-231)
    Γ , B ⊢ #x[Wk] ≈ #(S x) : A[Wk]
```

**替换代数**：

```
wf_exp_eq_sub_cong :
    Δ ⊢ M ≈ M' : A
    Γ ⊢s σ ≈ σ' : Δ
    ────────────────────────   (System/Definitions.v:232-235)
    Γ ⊢ M[σ] ≈ M'[σ'] : A[σ]

wf_exp_eq_sub_id :
    Γ ⊢ M : A
    ────────────────────       (System/Definitions.v:236-238)
    Γ ⊢ M[Id] ≈ M : A

wf_exp_eq_sub_compose :
    Γ ⊢s τ : Γ'
    Γ' ⊢s σ : Γ''
    Γ'' ⊢ M : A
    ──────────────────────────────   (System/Definitions.v:239-243)
    Γ ⊢ M[σ ∘ τ] ≈ M[σ][τ] : A[σ ∘ τ]
```

**子型与等价关系**：

```
wf_exp_eq_subtyp :
    Γ ⊢ M ≈ M' : A
    Γ ⊢ A' : Type@i
    Γ ⊢ A ⊆ A'
    ────────────────────────   (System/Definitions.v:244-251)
    Γ ⊢ M ≈ M' : A'

wf_exp_eq_sym :
    Γ ⊢ M ≈ M' : A
    ──────────────────         (System/Definitions.v:252-254)
    Γ ⊢ M' ≈ M : A

wf_exp_eq_trans :
    Γ ⊢ M ≈ M' : A
    Γ ⊢ M' ≈ M'' : A
    ──────────────────         (System/Definitions.v:255-258)
    Γ ⊢ M ≈ M'' : A
```

`wf_exp_eq` 是 PER（System/Definitions.v:391-397）。

### 2.6 替换等价 wf_sub_eq（System/Definitions.v:261-317）—— 13 条

```
wf_sub_eq_id :
    ⊢ Γ
    ──────────────────            (System/Definitions.v:262-264)
    Γ ⊢s Id ≈ Id : Γ

wf_sub_eq_weaken :
    ⊢ Γ , A
    ──────────────────────        (System/Definitions.v:265-267)
    Γ , A ⊢s Wk ≈ Wk : Γ

wf_sub_eq_compose_cong :
    Γ ⊢s τ ≈ τ' : Γ'
    Γ' ⊢s σ ≈ σ' : Γ''
    ──────────────────────────    (System/Definitions.v:268-271)
    Γ ⊢s σ ∘ τ ≈ σ' ∘ τ' : Γ''

wf_sub_eq_extend_cong :
    Γ ⊢s σ ≈ σ' : Δ
    Δ ⊢ A : Type@i
    Γ ⊢ M ≈ M' : A[σ]
    ────────────────────────────  (System/Definitions.v:272-276)
    Γ ⊢s (σ ,, M) ≈ (σ' ,, M') : Δ , A

wf_sub_eq_id_compose_right :
    Γ ⊢s σ : Δ
    ────────────────────          (System/Definitions.v:277-279)
    Γ ⊢s Id ∘ σ ≈ σ : Δ

wf_sub_eq_id_compose_left :
    Γ ⊢s σ : Δ
    ────────────────────          (System/Definitions.v:280-282)
    Γ ⊢s σ ∘ Id ≈ σ : Δ

wf_sub_eq_compose_assoc :
    Γ' ⊢s σ : Γ
    Γ'' ⊢s σ' : Γ'
    Γ''' ⊢s σ'' : Γ''
    ─────────────────────────────────────   (System/Definitions.v:283-287)
    Γ''' ⊢s (σ ∘ σ') ∘ σ'' ≈ σ ∘ (σ' ∘ σ'') : Γ

wf_sub_eq_extend_compose :
    Γ' ⊢s σ : Γ''
    Γ'' ⊢ A : Type@i
    Γ' ⊢ M : A[σ]
    Γ ⊢s τ : Γ'
    ──────────────────────────────────     (System/Definitions.v:288-293)
    Γ ⊢s (σ ,, M) ∘ τ ≈ ((σ ∘ τ) ,, M[τ]) : Γ'' , A

wf_sub_eq_p_extend :
    Γ' ⊢s σ : Γ
    Γ ⊢ A : Type@i
    Γ' ⊢ M : A[σ]
    ──────────────────────────             (System/Definitions.v:294-298)
    Γ' ⊢s Wk ∘ (σ ,, M) ≈ σ : Γ

wf_sub_eq_extend :
    Γ' ⊢s σ : Γ , A
    ──────────────────────────────────     (System/Definitions.v:299-301)
    Γ' ⊢s σ ≈ ((Wk ∘ σ) ,, #0[σ]) : Γ , A

wf_sub_eq_sym :
    Γ ⊢s σ ≈ σ' : Δ
    ──────────────────                     (System/Definitions.v:302-304)
    Γ ⊢s σ' ≈ σ : Δ

wf_sub_eq_trans :
    Γ ⊢s σ ≈ σ' : Δ
    Γ ⊢s σ' ≈ σ'' : Δ
    ──────────────────                     (System/Definitions.v:305-308)
    Γ ⊢s σ ≈ σ'' : Δ

wf_sub_eq_subtyp :
    Γ ⊢s σ ≈ σ' : Δ
    ⊢ Δ'
    ⊢ Δ ⊆ Δ'
    ──────────────────────                 (System/Definitions.v:309-316)
    Γ ⊢s σ ≈ σ' : Δ'
```

`wf_sub_eq` 是 PER（System/Definitions.v:399-405）。

### 2.7 类型子型 wf_subtyp（System/Definitions.v:319-349）—— 4 条

```
wf_subtyp_refl :
    Γ ⊢ M' : Type@i
    Γ ⊢ M ≈ M' : Type@i
    ────────────────────         (System/Definitions.v:320-332)
    Γ ⊢ M ⊆ M'

wf_subtyp_trans :
    Γ ⊢ M ⊆ M'
    Γ ⊢ M' ⊆ M''
    ────────────────             (System/Definitions.v:333-336)
    Γ ⊢ M ⊆ M''

wf_subtyp_univ :
    ⊢ Γ
    i < j
    ──────────────────           (System/Definitions.v:337-340)
    Γ ⊢ Type@i ⊆ Type@j

wf_subtyp_pi :
    Γ ⊢ A : Type@i
    Γ ⊢ A' : Type@i
    Γ ⊢ A ≈ A' : Type@i
    Γ , A ⊢ B : Type@i
    Γ , A' ⊢ B' : Type@i
    Γ , A' ⊢ B ⊆ B'
    ──────────────────────────   (System/Definitions.v:341-348)
    Γ ⊢ Π A B ⊆ Π A' B'
```

**注意**：Π 子型的域要求**等价**（`A ≈ A'`）而非逆变子型；余域协变
（`Γ , A' ⊢ B ⊆ B'`）。这是 McTT 子类型的设计，移植时必须保持一致
（算法层 asnf_pi 同样，见 4.2；语义层 per_subtyp_pi 同，见 5.6）。
`wf_subtyp` 传递（System/Definitions.v:414-417）。

### 2.8 上下文等价 wf_ctx_eq（System/Definitions.v:375-386）—— 2 条

```
wf_ctx_eq_empty :  ⊢ ⋅ ≈ ⋅                                                (System/Definitions.v:376)
wf_ctx_eq_extend :
    ⊢ Γ ≈ Δ
    Γ ⊢ A : Type@i
    Γ ⊢ A' : Type@i
    Δ ⊢ A : Type@i
    Δ ⊢ A' : Type@i
    Γ ⊢ A ≈ A' : Type@i
    Δ ⊢ A ≈ A' : Type@i
    ────────────────────         (System/Definitions.v:377-385)
    ⊢ Γ , A ≈ Δ , A'
```

### 2.9 上下文子型 wf_ctx_sub（System/Definitions.v:33-41）—— 2 条

```
wf_ctx_sub_empty :  ⊢ ⋅ ⊆ ⋅                                              (System/Definitions.v:34)
wf_ctx_sub_extend :
    ⊢ Γ ⊆ Δ
    Γ ⊢ A : Type@i
    Δ ⊢ A' : Type@i
    Γ ⊢ A ⊆ A'
    ────────────────────         (System/Definitions.v:35-40)
    ⊢ Γ , A ⊆ Δ , A'
```

### 2.10 SystemOpt.v：去冗余前提版本（供算法层参考，不必移植）

SystemOpt.v 是 System/Definitions.v 规则的推论版本，去掉了可由预设（presupposition）
推出的多余前提，例如 `wf_pi_max`（SystemOpt.v:121，Π 的宇宙为 `max i j`）、
`wf_conv'`（SystemOpt.v:51，用子型取代类型前提）。算法层（AlgSub/Definitions.v:3
`Require Export SystemOpt`）依赖它；移植时算法规则与 `max i j` 的对应见 3.2 的 ati_pi。

---

## 3. 算法化类型规则（AlgTyp/Definitions.v）

判定形式（AlgTyp/Definitions.v:5-6）：
- **推断模式**：`Γ ⊢a M ⟹ A`（A 为 **nf**！）— `alg_type_infer Γ A M`（AlgTyp/Definitions.v:16）
- **检查模式**：`Γ ⊢a M ⟸ A`（A 为任意 exp）— `alg_type_check Γ A M`（AlgTyp/Definitions.v:10）

互归纳定义（AlgTyp/Definitions.v:10-51）。

### 3.1 检查模式（1 条）

```
atc_ati :
    Γ ⊢a M ⟹ A
    Γ ⊢a A ⊆ B
    ──────────────────         (AlgTyp/Definitions.v:11-14)
    Γ ⊢a M ⟸ B
```
（唯一检查规则：推断 + 子类型，双向检查的标准「转换」入口。）

### 3.2 推断模式（9 条）

```
ati_typ :
    ──────────────────────     (AlgTyp/Definitions.v:17-18)
    Γ ⊢a Type@i ⟹ Type@(S i)

ati_nat :
    ──────────────────         (AlgTyp/Definitions.v:19-20)
    Γ ⊢a ℕ ⟹ Type@0

ati_zero :
    ──────────────────         (AlgTyp/Definitions.v:21-22)
    Γ ⊢a zero ⟹ ℕ

ati_succ :
    Γ ⊢a M ⟸ ℕ
    ────────────────────       (AlgTyp/Definitions.v:23-25)
    Γ ⊢a succ M ⟹ ℕ

ati_natrec :
    Γ , ℕ ⊢a A ⟹ Type@i
    Γ ⊢a MZ ⟸ A[Id,,zero]
    Γ , ℕ , A ⊢a MS ⟸ A[Wk∘Wk,,succ #1]
    Γ ⊢a M ⟸ ℕ
    nbe_ty Γ {{{ A[Id,,M] }}} B
    ────────────────────────────────────────────────────────────────   (AlgTyp/Definitions.v:26-32)
    Γ ⊢a rec M return A | zero -> MZ | succ -> MS end ⟹ B

ati_pi :
    Γ ⊢a A ⟹ Type@i
    Γ , A ⊢a B ⟹ Type@j
    ──────────────────────────   (AlgTyp/Definitions.v:33-36)
    Γ ⊢a Π A B ⟹ Type@(max i j)

ati_fn :
    Γ ⊢a A ⟹ Type@i
    Γ , A ⊢a M ⟹ B
    nbe_ty Γ A C
    ──────────────────────────   (AlgTyp/Definitions.v:37-41)
    Γ ⊢a λ A M ⟹ Π C B

ati_app :
    Γ ⊢a M ⟹ Π A B
    Γ ⊢a N ⟸ A
    nbe_ty Γ {{{ B[Id,,N] }}} C
    ──────────────────────────   (AlgTyp/Definitions.v:42-46)
    Γ ⊢a M N ⟹ C

ati_vlookup :
    #x : A ∈ Γ
    nbe_ty Γ A B
    ──────────────────           (AlgTyp/Definitions.v:47-50)
    Γ ⊢a #x ⟹ B
```

要点：
- 推断结果一律是 **nf**（由 `nbe_ty` 把类型规范化：ati_natrec / ati_fn / ati_app /
  ati_vlookup 中均有 `nbe_ty` 前提）。
- `ati_pi` 的 `Type@(max i j)` 对应 SystemOpt.v:121 的 `wf_pi_max`。
- `nbe_ty Γ A B` 定义见 5.5（NbE.v:137-142）。

---

## 4. 算法子类型（AlgSub/Definitions.v）

### 4.1 非 Π/宇宙判定（AlgSub/Definitions.v:9-13）

```
not_univ_pi : nf -> Prop
  not_univ_pi (nf_typ _) = False      (AlgSub/Definitions.v:11)
  not_univ_pi (nf_pi _ _) = False
  not_univ_pi _          = True
```

### 4.2 正规形子类型 alg_subtyping_nf（AlgSub/Definitions.v:15-27）—— 3 条

```
asnf_refl :
    not_univ_pi A
    A = A'
    ──────────────         (AlgSub/Definitions.v:16-19)
    ⊢anf A ⊆ A'

asnf_univ :
    i <= j
    ──────────────────     (AlgSub/Definitions.v:20-22)
    ⊢anf Type@i ⊆ Type@j

asnf_pi :
    A = A'
    ⊢anf B ⊆ B'
    ────────────────────── (AlgSub/Definitions.v:23-26)
    ⊢anf Π A B ⊆ Π A' B'
```

**注意**：asnf_pi 的域要求**语法相等**（`A = A'`），无逆变前提；余域协变。与
System/Definitions.v:341-348 的 wf_subtyp_pi 一致（域等价 + 余域协变）。
McTT 没有 Π 逆变子类型规则——移植时不得添加。

### 4.3 算法子类型 alg_subtyping（AlgSub/Definitions.v:29-35）—— 1 条

```
alg_subtyp_run :
    nbe_ty Γ A A'
    nbe_ty Γ B B'
    ⊢anf A' ⊆ B'
    ──────────────         (AlgSub/Definitions.v:30-34)
    Γ ⊢a A ⊆ B
```

算法结构：**先规范化两侧到 nf，再在 nf 上比较**（`alg_subtyp_run` 是唯一入口）。

---

## 5. NbE 结构（Semantic）

### 5.1 语义域 Domain.v

```
domain : Set                                                               (Domain.v:7)
| d_nat : domain                                        ℕ 的语义值           (Domain.v:8)
| d_pi : domain -> env -> exp -> domain                 Π a ρ B             (Domain.v:9)
| d_univ : nat -> domain                                𝕌@i                  (Domain.v:10)
| d_zero : domain                                       zero                 (Domain.v:11)
| d_succ : domain -> domain                             succ m               (Domain.v:12)
| d_fn : env -> exp -> domain                           λ ρ M                (Domain.v:13)
| d_neut : domain -> domain_ne -> domain                ⇑ a m（类型标注 a）  (Domain.v:14)

domain_ne : Set                                                            (Domain.v:15)
| d_var : nat -> domain_ne                              !x —— 绝对名，非 de Bruijn 索引（Domain.v:20，注释见 Domain.v:16-19）
| d_app : domain_ne -> domain_nf -> domain_ne           m n                  (Domain.v:21)
| d_natrec : env -> typ -> domain -> exp -> domain_ne   rec m under ρ return P | zero -> mz | succ -> MS end（Domain.v:22，参数序 ρ P mz MS m）

domain_nf : Set                                                             (Domain.v:23)
| d_dom : domain -> domain -> domain_nf                 ⇓ a m（类型+值配对） (Domain.v:24)

env := nat -> domain                                                        (Domain.v:25)
empty_env := fun _ => d_zero                                               (Domain.v:29-30)
extend_env ρ d := fun n => match n with 0 => d | S n' => ρ n' end          (Domain.v:32-37)
drop_env  ρ   := fun n => ρ (S n)                                          (Domain.v:41-43)
```

关键性质：`(ρ ↦ a) ↯ = ρ`（Domain.v:74-78，定义上成立）。

### 5.2 求值 Eval/Definitions.v

关系：`⟦ M ⟧ ρ ↘ r`（eval_exp，Eval/Definitions.v:12）、
`rec m ⟦return A | zero -> MZ | succ -> MS end⟧ ρ ↘ r`（eval_natrec，Eval/Definitions.v:43）、
`$| m & n |↘ r`（eval_app，Eval/Definitions.v:56）、
`⟦ σ ⟧s ρ ↘ ρσ`（eval_sub，Eval/Definitions.v:64）。互归纳，共 19 条。

**eval_exp（10 条）**：

```
eval_exp_typ :    ⟦ Type@i ⟧ ρ ↘ 𝕌@i                                        (Eval/Definitions.v:13-14)
eval_exp_var :    ⟦ # x ⟧ ρ ↘ ^(ρ x)                                         (Eval/Definitions.v:15-16)
eval_exp_nat :    ⟦ ℕ ⟧ ρ ↘ ℕ                                                (Eval/Definitions.v:17-18)
eval_exp_zero :   ⟦ zero ⟧ ρ ↘ zero                                          (Eval/Definitions.v:19-20)
eval_exp_succ :   ⟦ M ⟧ ρ ↘ m  ⟹  ⟦ succ M ⟧ ρ ↘ succ m                     (Eval/Definitions.v:21-23)
eval_exp_natrec : ⟦ M ⟧ ρ ↘ m
                  rec m ⟦return A | zero -> MZ | succ -> MS end⟧ ρ ↘ r
                  ─────────────────────────────────────────────────        (Eval/Definitions.v:24-27)
                  ⟦ rec M return A | zero -> MZ | succ -> MS end ⟧ ρ ↘ r
eval_exp_pi :     ⟦ A ⟧ ρ ↘ a  ⟹  ⟦ Π A B ⟧ ρ ↘ Π a ρ B                      (Eval/Definitions.v:28-30)
eval_exp_fn :     ⟦ λ A M ⟧ ρ ↘ λ ρ M        （A 不参与求值！）              (Eval/Definitions.v:31-32)
eval_exp_app :    ⟦ M ⟧ ρ ↘ m   ⟦ N ⟧ ρ ↘ n   $| m & n |↘ r
                  ─────────────────────────────────                        (Eval/Definitions.v:33-37)
                  ⟦ M N ⟧ ρ ↘ r
eval_exp_sub :    ⟦ σ ⟧s ρ ↘ ρ'   ⟦ M ⟧ ρ' ↘ m
                  ─────────────────────────                                (Eval/Definitions.v:38-41)
                  ⟦ M[σ] ⟧ ρ ↘ m
```

**eval_natrec（3 条）**：

```
eval_natrec_zero : ⟦ MZ ⟧ ρ ↘ mz
                   ─────────────────────────────────────────────────────   (Eval/Definitions.v:44-46)
                   rec zero ⟦return A | zero -> MZ | succ -> MS end⟧ ρ ↘ mz

eval_natrec_succ : rec b ⟦return A | zero -> MZ | succ -> MS end⟧ ρ ↘ r
                   ⟦ MS ⟧ ρ ↦ b ↦ r ↘ ms
                   ─────────────────────────────────────────────────────   (Eval/Definitions.v:47-50)
                   rec succ b ⟦return A | zero -> MZ | succ -> MS end⟧ ρ ↘ ms

eval_natrec_neut : ⟦ MZ ⟧ ρ ↘ mz
                   ⟦ A ⟧ ρ ↦ ⇑ b m ↘ a
                   ─────────────────────────────────────────────────────   (Eval/Definitions.v:51-54)
                   rec ⇑ b m ⟦return A | zero -> MZ | succ -> MS end⟧ ρ
                     ↘ ⇑ a (rec m under ρ return A | zero -> mz | succ -> MS end)
```

**eval_app（2 条）**：

```
eval_app_fn :   ⟦ M ⟧ ρ ↦ n ↘ m
                ────────────────────   (Eval/Definitions.v:57-59)
                $| λ ρ M & n |↘ m

eval_app_neut : ⟦ B ⟧ ρ ↦ n ↘ b
                ─────────────────────────────────   (Eval/Definitions.v:60-62)
                $| ⇑ (Π a ρ B) m & n |↘ ⇑ b (m (⇓ a n))
```
（`m (⇓ a n)` 是 d_app：把 neutral 应用到类型标注的值上。）

**eval_sub（4 条）**：

```
eval_sub_id :      ⟦ Id ⟧s ρ ↘ ρ                                            (Eval/Definitions.v:65-66)
eval_sub_weaken :  ⟦ Wk ⟧s ρ ↘ ρ ↯                                          (Eval/Definitions.v:67-68)
eval_sub_extend :  ⟦ σ ⟧s ρ ↘ ρσ   ⟦ M ⟧ ρ ↘ m
                   ─────────────────────────────                            (Eval/Definitions.v:69-72)
                   ⟦ σ ,, M ⟧s ρ ↘ ρσ ↦ m
eval_sub_compose : ⟦ τ ⟧s ρ ↘ ρτ   ⟦ σ ⟧s ρτ ↘ ρτσ
                   ─────────────────────────────                            (Eval/Definitions.v:73-76)
                   ⟦ σ ∘ τ ⟧s ρ ↘ ρτσ
```

求值是**确定性**的（functional，见 Eval/Lemmas.v；互归纳原理 Eval/Definitions.v:80-88）。

### 5.3 读出 Readback/Definitions.v

关系：`Rnf m in s ↘ M`（read_nf，Readback/Definitions.v:12）、
`Rne m in s ↘ M`（read_ne，Readback/Definitions.v:37）、
`Rtyp m in s ↘ M`（read_typ，Readback/Definitions.v:63）。
`s` = 深度（上下文长度）；读出把 domain（含绝对名）转回带 de Bruijn 索引的 nf/ne。
互归纳，共 13 条（read_nf 6 + read_ne 3 + read_typ 4；2026-08-28 修正：原「12 条」漏计 read_nf_neut）。

**read_nf（6 条）**：

```
read_nf_type :
    Rtyp a in s ↘ A
    ────────────────────   (Readback/Definitions.v:13-15)
    Rnf ⇓ 𝕌@i a in s ↘ A

read_nf_zero :
    ──────────────────────   (Readback/Definitions.v:16-17)
    Rnf ⇓ ℕ zero in s ↘ zero

read_nf_succ :
    Rnf ⇓ ℕ m in s ↘ M
    ──────────────────────────   (Readback/Definitions.v:18-20)
    Rnf ⇓ ℕ (succ m) in s ↘ succ M

read_nf_nat_neut :
    Rne m in s ↘ M
    ──────────────────────────   (Readback/Definitions.v:21-23)
    Rnf ⇓ ℕ (⇑ a m) in s ↘ ⇑ M

read_nf_fn :
    Rtyp a in s ↘ A
    $| m & ⇑! a s |↘ m'
    ⟦ B ⟧ ρ ↦ ⇑! a s ↘ b
    Rnf ⇓ b m' in S s ↘ M
    ──────────────────────────────────   (Readback/Definitions.v:24-32)
    Rnf ⇓ (Π a ρ B) m in s ↘ λ A M
    （η 展开：应用到一个新鲜绝对名 s 上，深度 +1 后读出）

read_nf_neut :
    Rne m in s ↘ M
    ──────────────────────────────────   (Readback/Definitions.v:33-35)
    Rnf ⇓ (⇑ a b) (⇑ c m) in s ↘ ⇑ M
```

**read_ne（3 条）**：

```
read_ne_var :
    ──────────────────────────   (Readback/Definitions.v:38-39)
    Rne !x in s ↘ #(s - x - 1)
    （绝对名 x → de Bruijn 索引 s - x - 1）

read_ne_app :
    Rne m in s ↘ M
    Rnf n in s ↘ N
    ────────────────────   (Readback/Definitions.v:40-43)
    Rne m n in s ↘ M N

read_ne_natrec :
    ⟦ B ⟧ ρ ↦ ⇑! ℕ s ↘ b
    Rtyp b in S s ↘ B'
    ⟦ B ⟧ ρ ↦ zero ↘ bz
    Rnf ⇓ bz mz in s ↘ MZ
    ⟦ B ⟧ ρ ↦ succ (⇑! ℕ s) ↘ bs
    ⟦ MS ⟧ ρ ↦ ⇑! ℕ s ↦ ⇑! b (S s) ↘ ms
    Rnf ⇓ bs ms in S (S s) ↘ MS'
    Rne m in s ↘ M
    ─────────────────────────────────────────────────────────────────   (Readback/Definitions.v:44-61)
    Rne rec m under ρ return B | zero -> mz | succ -> MS end in s
      ↘ rec M return B' | zero -> MZ | succ -> MS' end
```

**read_typ（4 条）**：

```
read_typ_univ :    Rtyp 𝕌@i in s ↘ Type@i                                    (Readback/Definitions.v:64-65)
read_typ_nat :     Rtyp ℕ in s ↘ ℕ                                            (Readback/Definitions.v:66-67)
read_typ_pi :
    Rtyp a in s ↘ A
    ⟦ B ⟧ ρ ↦ ⇑! a s ↘ b
    Rtyp b in S s ↘ B'
    ──────────────────────────   (Readback/Definitions.v:68-76)
    Rtyp Π a ρ B in s ↘ Π A B'
read_typ_neut :
    Rne b in s ↘ B
    ──────────────────────   (Readback/Definitions.v:77-79)
    Rtyp ⇑ a b in s ↘ ⇑ B
```

### 5.4 初始环境 initial_env（NbE.v:9-14）

```
initial_env_nil  : initial_env nil empty_env                                 (NbE.v:10)
initial_env_cons : initial_env Γ ρ
                   ⟦ A ⟧ ρ ↘ a
                   ────────────────────────────────                           (NbE.v:11-14)
                   initial_env (A :: Γ) ρ ↦ ⇑! a (length Γ)
```

性质（NbE.v:38-41，initial_env_spec）：若 `initial_env Γ ρ` 且 `#x : A ∈ Γ`，
则 `ρ x = ⇑! a (length Γ - x - 1)`——第 x 个变量映射为绝对名 `length Γ - x - 1`
的 neutral（类型为 a 的求值结果）。即上下文头部（x=0）映射到绝对名 `length Γ - 1`。

### 5.5 规范化 nbe / nbe_ty（NbE.v:59-65, 137-142）

```
nbe_run :                       （nbe Γ M A w：M : A 规范化为 w ∈ nf）
    initial_env Γ ρ
    ⟦ A ⟧ ρ ↘ a
    ⟦ M ⟧ ρ ↘ m
    Rnf ⇓ a m in (length Γ) ↘ w
    ────────────────────────────   (NbE.v:60-65)
    nbe Γ M A w

nbe_ty_run :                    （nbe_ty Γ M W：类型 M 规范化为 W ∈ nf）
    initial_env Γ ρ
    ⟦ M ⟧ ρ ↘ m
    Rtyp m in (length Γ) ↘ W
    ────────────────────────────   (NbE.v:138-142)
    nbe_ty Γ M W
```

两者均**确定性**（functional_nbe NbE.v:70-81、functional_nbe_ty NbE.v:147-158）。
`nbe` 的读入深度恒为 `length Γ`。

### 5.6 转换判定（语义转换 = 规范化到同一正规形）

McTT 没有独立的 `t ≡ u : T` 判定；转换由下述双向定理刻画：

```
completeness :  ∀ Γ M M' A,   Γ ⊢ M ≈ M' : A  ⟹  ∃ W, nbe Γ M A W ∧ nbe Γ M' A W
                                                              (Completeness.v:9-10)
soundness :     ∀ Γ M A,      Γ ⊢ M : A  ⟹  ∃ W, nbe Γ M A W ∧ Γ ⊢ M ≈ W : A
                                                              (Soundness.v:9-10)
```

即：**两表达式转换当且仅当它们在初始环境下求值并读出到同一个正规形**
（completeness 给出 ⇒，soundness 给出 nf 与原文的语法等价，二者合起来是 ⇔）。
算法实现上，转换判定 = 两侧分别 `nbe`/`nbe_ty` + nf 的语法相等
（nf_eq_dec，Syntax.v:104-111）。

### 5.7 语义子类型 per_subtyp（PER/Definitions.v:237-258，soundness 侧，4 条）

算法子类型（4.3）之上还定义语义子类型（用于 PER 逻辑关系/健全性证明，移植 kernel
时如不做证明可只参照）：

```
per_subtyp_neut :  Dom b ≈ b' ∈ per_bot  ⟹  Sub ⇑ a b <: ⇑ a' b' at i            (PER/Definitions.v:238-240)
per_subtyp_nat :   Sub ℕ <: ℕ at i                                                 (PER/Definitions.v:241-242)
per_subtyp_univ :  i <= j  ∧  j < k  ⟹  Sub 𝕌@i <: 𝕌@j at k                        (PER/Definitions.v:243-246)
per_subtyp_pi :    DF a ≈ a' ∈ per_univ_elem i ↘ in_rel
                   （∀ c ≈ c' ∈ in_rel,  ⟦ B ⟧ ρ ↦ c ↘ b, ⟦ B' ⟧ ρ' ↦ c' ↘ b'  ⟹  Sub b <: b' at i）
                   DF Π a ρ B ≈ Π a ρ B ∈ per_univ_elem i ↘ elem_rel
                   DF Π a' ρ' B' ≈ Π a' ρ' B' ∈ per_univ_elem i ↘ elem_rel'
                   ─────────────────────────────────────────────────────────        (PER/Definitions.v:247-257)
                   Sub Π a ρ B <: Π a' ρ' B' at i
```

辅助 PER（PER/Definitions.v:38-60）：
- `per_bot : relation domain_ne`：`∀ s, ∃ L, Rne m in s ↘ L ∧ Rne n in s ↘ L`（读到同一中性形）
- `per_top : relation domain_nf`：`∀ s, ∃ L, Rnf m in s ↘ L ∧ Rnf n in s ↘ L`
- `per_top_typ : relation domain`：`∀ s, ∃ C, Rtyp a in s ↘ C ∧ Rtyp b in s ↘ C`

（per_nat PER/Definitions.v:62-70、per_ne PER/Definitions.v:74-78、
per_univ_elem PER/Definitions.v:161-164 为逻辑关系构造，移植 kernel 算法本身不需要。）

---

## 6. 自检清单（Task 2 生成时逐项核对，见 task-2-report.md）

1. 每个构造子有来源行号：Syntax.v（10 exp + 4 sub + 7 nf + 3 ne）、Domain.v（7 domain + 3 ne + 1 nf）。
2. 每条规则有来源行号：System/Definitions.v（69 条推导规则 + 2 条查找 + 判定形式）、
   AlgTyp/Definitions.v（10 条）、AlgSub/Definitions.v（4 条）、Eval/Definitions.v（19 条）、
   Readback/Definitions.v（12 条）、NbE.v（2 条 + initial_env 2 条）、PER/Definitions.v（4 条）。
3. 无「待定」「类似上面」类描述。
4. de Bruijn/上下文约定在 §0.1 明确写出（var 0 = 上下文头部 = 最右元素；
   `Γ , A := cons A Γ`；d_var 为绝对名，读出时 `s - x - 1` 转换）。
