# 批 8（静默面收尾）T0 实测报告（**独立文件**；计划文件归 `plan-verikernel` 独占）

> **性质**：T0 侦查（只读 + 最小件探针）与实施期**实测反证**的汇总。计划 `2026-09-17-silence-closure.md`
> 的原文**不在此改动**（其更正轮由 `plan-verikernel` 承担）；本文件与其并列，供交叉引用。
> **工具**：**前态二进制** `/tmp/corec2`（develop 树、无批 8 任何改动；用于「修前读数」）· **本链** `build/corec`
> （批 8 逐条提交后构建）。所有读数均 `nice -n 19`、`cwd` = 仓库根（避 `--static` 的 `rt.cr` 解析陷阱）。
> **锚点纪律**：行号按本树实读；跨树漂移时以**符号锚**为准（每条都给了符号）。

---

## §T0-1 条目 1（泛型 `dex?`）：计划机理**被实测推翻** ⇒ 分裂为 (甲)/(乙)

### 判定 A｜「callee 按实例判 ⇒ `W3` 命中 ⇒ 槽 = `TI_DEX_S`」**不成立**

- **符号锚**：`monomorph.cr` 的 `if k == EXPR_FN { d2 := gen_clone_tree(d); … }`（本树 `:600`）。
- **实测（编译期 trace）**：实例 `g[dex]` / `h[dex]` 的**形参节点号与声明逐一相同**（13/16）——即
  **`EXPR_FN` 克隆只深克隆体 `d`**，`a/b/c`（名 / 首形参 / 形参数）**原样复制** ⇒ 实例与声明**共用形参节点**。
- ⇒ 实例形参序言读 `ast_type_val(pn)` = 0（`T`/`T?` **未替换**）⇒ **槽恒 `TI_INT`（GP 类）**；
  `W3`（`dex_opt_type_node(ast_data(pn))`）在实例上**不命中**（inner 是**未替换的泛型参数**，非 `TK_DEX`）。
- ⇒ 调用点按**实参 IR 型**分类（`dex` apx bits = **XMM 类**）与 callee（GP）失配。

### 判定 B｜(甲) 的真面目 = **直调实参类型完全不校验**（= 已登记的 F3）

判别实验（前态二进制；形参 ∈ {`int`,`int?`,`dex`,`dex?`} × 实参 ∈ {apx dex, scaled dex, int, `None`, `Some(7)`}）：

- **14/14 组合 `check=0` 零诊断**；**对照 7 例同样零诊断**（`string→int` · `bool→int` · `int→string` ·
  `string→int?` · `string→dex` · 数组→`int` · 结构体→`int`）。
- ⇒ 不是 dex/可选专属缺口，而是**调用位点实参类型不校验**；**已登记** = `TODO #2026-09-16-1`
  （F3：`unify_types` 返回值被丢弃；锚点 = `checker.cr` 定义 `:1912` / 丢弃点 `:2021`，读码复核过）。
- **计划探针 `g(1, d)` 的真实形态**：实例键实测 **`g[int]`**（`T` 由首实参绑为 `int`）⇒ 形参 `x: int?`，
  第 2 实参 dex 被静默接受 ⇒ 期望「7/7」建立在错机理上（lead 已裁：**判据改「拒绝」**）。

### 判定 C｜「重定向点是否唯一」三形态实测（lead 追加 T0 必答）

| 形态 | 落地路径 | check | build | run | 结论 |
|---|---|---|---|---|---|
| 直调 `g(1, d)` | `EXPR_IDENT` ⇒ **进**重定向块（`ir_gen.cr` `ast_kind(func_node) == EXPR_IDENT`） | 0 | 0 | ELF 63–247（漂移）/ interp 15 | 在册（(甲)/(乙)） |
| **模块限定** `ml.g(1, d)` | `EXPR_FIELD` + `is_module_call` ⇒ **不进**重定向块 | **1（TF01 误报）** | **0（TF01 在构建豁免表内）** | **139（SIGSEGV）** | **新实测**：同一「泛型实例化」面在模块限定形**另走一条路**，且表现为条目 6 的 TF01 家族 |
| 方法形 `x.m(…)` | 泛型 callee 的方法形**不可表达**（`impl X[T]` 全仓 **0 处**；方法体内调泛型自由函数 = 直调路径） | — | — | — | 形态不存在，无需对齐 |

> ⇒ 「环改动零效果」的结论**在直调形成立**；模块限定形是**另一条缺陷路径**（TF01 误报 + 豁免 ⇒ 坏产物 rc=0），
> 归入条目 6 的实证。

### 最小复现与落点

```core
// 直调形（本批实测 RED）：期望「拒绝」（类型错误）；修前 check=0 · build=0 · ELF 垃圾 / interp 15
fn g[T](t: T, x: T?) -> int { return match x { Some(v) => { return @raw_int(v) / 1000000; } None => { return 0; } }; }
fn main() -> int { d : dex, apx = 7.0; return g(1, d); }
```
- **(甲) 落点**：`checker.cr` 的 `unify_types` 丢弃点（F3 面）——按 lead 三阶段 S1（report-only）→ S2（修站点）→ S3（升硬错）。
- **(乙) 落点**：`monomorph.cr` `EXPR_FN` 分支**连形参链一起克隆**（`gen_clone_consecutive(b, c)`）；
  **半成品留痕**：`ir_gen.cr` 已有「环抽函数 `dex_align_call_args` + 重定向后按实例签名再跑」的改动
  （**对本条零效果**，对 (乙) 可能是必需的一半），以**未提交形态**留在 working copy（铁律 #3）。

---

## §T0-2 条目 2（可选 `==` 恒假）：现象坐实，机理**行锚更正**

- **现象（修前实测，位码 rc 可读）**：五读数 `0/0/0/1/1` ⇒ 位码 **24**（`bit3 = a==b`、`bit4 = a==7` 置位）；
  修复后 **30**（`bit1/bit2/bit3/bit4` 置位；`bit0 = n==Some(7)` 恒 0、`bit5 = None==7` 恒 0）。
- **机理**：`==` 走**通用二元落点**（符号锚 `emit(IR_BINARY, v, left_var, right_var, op, fti)`，本树 `ir_gen.cr:1620`
  与 `:1677` 两处；计划原引 `:1453` 是 **dex 定点分支内**的比较，非通用落点）——**不读 `irv_rep`** ⇒ 逐槽比原始值：
  裸（rep=0，槽值=载荷）⇒ 比对正确；**装箱**（`Some`/`None` 对象）⇒ 比**指针** ⇒ 恒假。
- **修复**（已落地）：比较点归一 `(absent, payload)` 后按值比（`opt_cmp_optish` / `opt_cmp_enc` / `opt_cmp_norm` /
  `opt_cmp_extract_boxed` + 分派块）；**解引用可选指针**按 INV-1 判装箱（`*p` 形态，同 `match *p` 假定）。
- **换代（条件式判据）**：本条目**改变**了含可选比较程序的 IR，但**实测无复活通道**——含可选值的程序
  `.cir` 条目 = **0**（缓存门 `main.cr` 的 `g_optrep_on != 0 ⇒ cache_enabled = 0`）⇒ **不换代** ✓
  （「前态二进制写缓存 → 后态同 cwd 编译」实测 post = 30，无误复活）。

---

## §T0-3 条目 3（extern 含可选 ⇒ P24）：Q1/Q2 读数

- **Q1 逐形态（**修前** `/tmp/corec2`；`run = -11` = SIGSEGV/139）**：

| 形态 | check | build | run |
|---|---|---|---|
| `extern fn e(x: dex?) -> int;`（+调用） | 0 | 0 | **-11** |
| `extern fn e(x: int?) -> int;`（+调用） | 0 | 0 | **-11** |
| `extern fn e(s: string?) -> int;`（+调用） | 0 | 0 | **-11** |
| `extern fn e() -> int?;`（+使用） | 0 | 0 | **-11** |
| `extern fn e() -> dex?;`（+使用） | **1（TA02）** | 1 | — |

⇒ **无任何可选形态「预存可用」**（全部崩或先报 TA02）⇒ **停条件不触发**，一律硬错有据。
修复后五形态齐一：`check=1 P24` · `build=1` · 零产物。
- **Q2 根因未收（洞仍在）**：**非可选** extern 四形态（`dex`←`int` · `int`←dex · `int`←string · 返回型不符）
  **check=0 · build=0 · run=-11**（修复前后同）⇒ **登记 `TODO #2026-09-18-5`**；属 F3 家族在 extern 侧的实例。
- **落点说明**：修复选 **parser 的签名规则位**（同 `P020` 先例；返回类型节点在 parser 内可用、`EXPR_EXTERN`
  节点不存返回节点 ⇒ **不新增 AST 字段**、零指纹/`.ccr` 扰动）。

---

## §T0-4 条目 4（顶层兜底）：**新发现「import 半步解析」** + 全语料对拍

- **发现**：`parse_all` 的 import 跳过段**只吞 `import` 关键字本身**（符号锚 = `parser.cr`「Skip import/fileid tokens」段），
  其后的**路径/别名 token 一直靠顶层兜底静默吞**——**全语料普遍**（`import io` 的 `io`；注入的运行时源
  `src/runtime/rt.cr:2` 的 `import arena_globals`）⇒ 新硬错若不先补此处，会把**每一条合法 import** 判红。
  **修复** = 按 `module.cr` res_imports 的扫描形状**逐字**消费 `[@proj] [a(::b)*] [: alias] [;]`
  （**有界**；首版「吞到分号/吞任意 IDENT」放宽后误吞紧随的 `g_rt_argc : int` ⇒ 已在注释留痕）。
- **全语料对拍（212 档 `.cr` × `corec check`；前态 vs 本链）**：差异 **7 档，且全部本就 `rc=1`**
  （`tests/spec/t2_neg_*` 5 · `tests/probes/p_ffi.cr` 1 · `tests/test_flow.cr` 1）；原期望码 **V02/V03 仍在**、
  仅新增 P25 并列 ⇒ **合法语料零差异**（`test_spec_grammar.py` 48/48 复跑绿）。
- **判据要件**（已落地）：拒收 ⇒ `check=1` + `error[P25]` + 定位 + `build=1` + **零产物**；合法对照 7 例三面 0；
  **不挂起**（P6：报错仍消费 token；套件每例 60s 限时，实测 ≈0.0s）。

---

## §T0-5 条目 5（标签不适用组合）：**按对抗复核转述，未独立复跑**

- 复核结论（`plan-verikernel`，只读、`jj file show -r develop`）：**真作用点 3 处**——`ir_gen.cr` 的槽型处
  （**有** `declared_ti == TI_DEX` 门）· dyn 分支 · 通用 LET 尾（后两处是 `if is_apx != 0 { emit(IR_APPROX, …) }`，
  **无类型门**）；⇒ **值面/ELF 面零作用**（`IR_APPROX` 尺寸 0 · 不发射 · interp/opt 跳过）而 **IR 面非零作用**
  （`int, apx` 照样多一条 `IR_APPROX`，dump 显示名 `approx`）。
- 判据改**条件式**（`is_apx != 0 && declared_ti != TI_DEX ⇒ 硬错`）+ 补 `. + apx` / `auto + apx` 探针（期望 rc=1）；
  ⚠ 登记：bootstrap 侧 `int, apx` **有语义**（`ApproxInstr`）⇒ 两前端接受集分歧（`#2026-09-17-10` 家族）。
- **本报告未独立复跑该条**（避免与 `plan-verikernel` 的更正轮重复构建）；实施时按**实测三处**落点，
  机制断言 = `.cir`/dump 里 `approx` 的**有无**。

---

## §T0-6 条目 6（TF01 误报 + 豁免）：**新增实证（模块限定泛型调用）**

- `ml.g(1, d)`（模块限定形 + 泛型 callee）实测：**`error[TF01]`（误报类）+ `build rc=0`**（TF01 在构建豁免表内）
  ⇒ **产物照出 + 运行 139**。⇒ 这是「TF01 误报 ⇒ 豁免 ⇒ 坏产物 rc=0」的**具体案例**（计划 §1-6 现象类），
  且与条目 1 的模块限定形同源。
- 判据修正（P1）承接：`tests/selfhost/test_diag_gate.py:77` 现为**正控**（断言 chan_test 产假 TF01 且被豁免）
  ⇒ 条目 6 修完根因后**该档必 FAIL** ⇒ 改造为**负控**；另补 5 处载体（`diag.cr` 豁免行 · 该测试 docstring ·
  `docs/developer/errors.md`「码级 9 条」· doc-reality-audit 的机械计数 9→8 · `TODO.md` FC 批行）。

---

## §T0-7 版本面（本批**不换代**，条件式判据 + 实测通道）

- **条件式判据**：「本批 diff 是否改变**任一被接受程序**的 IR？」——(甲)/(条目 3)/(条目 4) 均为**拒绝面**
  （只把静默接受转成响亮拒绝，不改变被接受程序的 IR）⇒ 条件**不成立** ⇒ **不 bump**。
- **条目 2** 会改变含可选比较程序的 IR，但**实测无复活通道**（`g_optrep_on ⇒ cache_enabled=0`，`.cir` 条目 = 0）⇒ 不 bump。
- **成本项引用**：本批因此**省下**全量重建代价（`#2026-09-17-16`：旧制 ≈ **1011 条 / 1.4 GB**；批 7 后已降至
  ≈ **37.9 MiB**，即便如此仍无必要换代）。
- **(乙) 条目（`#2026-09-18-3`）的换代判据**：实施前**实测受影响语料的 `.cir` 条目数**（前态写缓存 → 后态同 cwd 编译）；
  注意 `main.cr` 的 `fi_generic_count > 0 ⇒ cache_enabled = 0`（符号锚）⇒ 含泛型单元整体关缓存 ⇒ 很可能同样不换。
