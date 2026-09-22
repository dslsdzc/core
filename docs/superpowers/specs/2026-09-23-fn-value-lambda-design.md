# 函数值 / Lambda / callable 设计（**提案档**）

> **来源**：本文是对维护者 DslsDZC 四块设计输入（① 自动推导清单 ② 4 项语言表面能力 + 最小语法增量
> ③ 能推/不能推分类表 ④ 表示方案裁决）的**形式化展开 + 仓库锚定**。原文逐字件 = `/tmp/briefs/fnvalue-raw.md`
> （**未入库**，本档不复制其全文；引用处标注「原文」）。文末「附」的批次切分与三件已确认决定
> 同样来自该件（team-lead 转述、维护者确认）。
> **2026-09-23 追加（维护者）**：**不变量 5**（不新增第二种函数类型；异步/协程面全自动推导）+ 其
> **必须保留的边界**（「产生新的并发执行关系」是程序语义，不许与 realization 合并）——落 §〇 5 / §4.1 D13–D24 / §4.2 / §4.3。
>
> **本文不做的事**：不实现、不改任何既有文件、不提 PR。
> **三态标注**：`[已实现]`（在 `develop@origin` 上 file:line 实核）· `[已设计未实现]`（有裁决/设计文档、零实现）·
> `[提案]`（本文给出的设计）。**本文除「现状锚点」节的 `[已实现]` 项外，全部是 `[提案]`**。
> **引用纪律**：标「原文」= 维护者原话；标「写手展开」= 本文作者（写手）的推论/建议，**不是维护者的判断**。
>
> **基线**：`develop@origin = 6b54107e`（`docs(.ccr V8): 2026-09-23 四条裁定…`，#165）。
> 本档全部行号在**该修订**上用 `jj file show -r develop@origin <path>` 逐一实核。
> ⚠ **本仓多工作区，任何检出目录的 `@` 都可能落后**——行号**不得**用就地 `grep` 取。

---

## 〇、不变量（**放最显眼处；四段全部受其约束**）

**不变量 1–4** 来自块四裁决；**不变量 5** 为 2026-09-23 维护者追加（异步/协程收缩 + 其边界）。
**任何实现者若发现某段设计与本节冲突，停下来上报，不得就地改动这五条。**

### 不变量 1 — `fn(T...) -> R` 是**统一 callable 类型**

> 原文：「`fn(T...) -> R` 是统一 callable 类型」·「callable 由可调用实体 + 可选 capture environment 构成」
> ·「不规定机器内存布局，不规定一定是 code pointer + env pointer」。

- 语义层 callable = **可调用实体（identity/body）+ 可选捕获环境**；
- **一个类型**：用户不必知道有没有 capture（原文：「`fn(int) -> int` 永远只有一个类型，用户完全不用知道
  有没有 capture」）；
- 无捕获 lambda、`fn.name`、有捕获 lambda **可正常互相赋值**（原文）。

### 不变量 2 — `{code, env}` **只是当前 CPU 后端的 realization / ABI，不是 Core 语义**

> 原文：「两字表示 `{code, env}` 只能是当前 CPU/backend 的 realization / ABI，不是 Core 的 callable 语义本身」
> ·「不要在 CIR 类型语义里定义 `fn(int) -> int == { code_ptr, env_ptr }`」。

**它防的是**：**把经典 CPU 模型重新塞进 Core 语义**。这条不是洁癖——本仓在别处已经栽过同族，且**都判在同一侧**：

| 先例（`[已实现]` 的结构性事实，可援引） | 同一处分界线 |
|---|---|
| `grammar/core.ebnf:42-43`：`'float'` 类型名已移除；旧 float 语义 = `dex`（精确小数）+ `apx` 标签（近似授权，**后端 binary64 快路径**） | 机器数格式 = 后端快路径，**不是**语言语义 |
| `src/compiler/ast.cr:294`（`TYP_ARRAY` 注）+ `docs/superpowers/specs/2026-09-10-language-surface-narrowing-design.md` §1：`[T; N]` 退役为**「内联容量存储」表示提示**，语义归处 = product / 序列+长度约束 | 存储形态 = 表示提示，**不是**类型语义 |
| `docs/superpowers/specs/2026-08-30-type-system-direction-design.md:36`：**宽度移出语言**（「单标签单范式；机器形状归 hw-map」） | 机器宽度**不得**进语言侧 |

> **写手展开（相似性声明）**：上表三例与本案是**同一族**（语义承担者 vs 后端 realization 分家），
> **不是同一案**（float 是数值表示、`[T;N]` 是存储提示、宽度是 ABI 面）。援引的是**纪律**，不是判例的先例约束力。

**由此推出的直接禁令（写手展开）**：`TYP_FN` 行的槽**只放签名**（返回型 + 参数型），
**不放** code/env 的宽度、不放「两字」这一事实；宽度/字数是**值层与后端**的事。

### 不变量 3 — `fn.foo` 与 `@addr(foo)` **不等价**

> 原文：「`fn.foo` = typed callable value」·「`@addr(foo)` = raw machine address，仍然是现有 `int` 语义」
> ·「**两者不能互相等价**」。

现状锚点（`[已实现]`）：`@addr(fn)` 的类型 = `TI_INT`（`src/compiler/checker.cr:4190-4191`，
注释原文「function address, type int」；发射 = `IR_FNADDR`，见 §一）。本裁决**不改变** `@addr` 的现状语义。

### 不变量 4 — `sched_go(@addr(f), arg)` 留在**旧的低层接口**；并发接口演进**不得反向决定**函数值的类型模型

> 原文：「不要为了兼容它把新 callable 也定义成裸地址」·「这是并发接口自己的演进，不应该反向决定函数值的
> 类型模型」。

现状锚点（`[已实现]`）：`fn sched_go(fn_ptr: int, arg: int) -> string`（`src/stdlib/sched.cr:171`）；
`go f(a)` 的写死 lowering = `IR_CALL sched_go(@addr(f), arg)`（`src/compiler/ir_gen.cr:1921` 发 `IR_FNADDR`
取裸址，`:1933-1934` 发 `IR_CALL sched_go`）；事实面复核见
`docs/superpowers/specs/2026-09-17-concurrency-model-design.md:427`。

> **原文·表示方案裁决（整段保留，作为本档的上位约束）**：
> ```
> 选甲，但只作为当前 backend realization。
> 语言/CIR 层：
>     fn(T...) -> R 是统一 callable 类型。
>     callable 由可调用实体 + 可选 capture environment 构成。
>     不规定机器内存布局，不规定一定是 code pointer + env pointer。
> 当前 CPU backend：
>     无 capture -> {code, 0}
>     有 capture -> {code, env}
> 允许后端在证明 env 不需要时消除第二字。
> ```
> 并：块三的**乙不合适**（同一个 `fn(T)->R` 会出现两种 runtime representation）、**丙不合适**
> （把环境依赖藏到调用点之外，生命周期与并发都会变麻烦）——**甲 = 语义统一 callable；CPU realization 暂用 `(code, env)`**。

### 不变量 5 — **不新增「第二种函数类型」：异步/协程面全部自动推导**
（2026-09-23 维护者追加；**与不变量 1 同侧**：函数类型**仍然只有** `fn(T...) -> R`）

**明确不加**（7 名，逐条理由见 §4.3）：`flow fn(...) -> ...`（**类型位**）· `async fn` · `Future[T]` ·
`Coroutine[T]` · `GeneratorState` · `Suspend` · `FnAsync`。

**理由（原文）**：`fn(...) -> Future<Data>` / `async fn` / `await` 这类东西**很多是在暴露某种实现模型**——
与 Core 的取向相反。

**编译器自动推导的是**（12 项，落 §4.1 的 D13–D24）：是否可能 suspend · suspend point 在哪 · 是否需要
coroutine frame · frame 保存哪些状态 · frame 生命周期/region · 是否 escape · 何时 resume ·
是否可直接同步执行 · 能否消除 suspend/resume · 调用是否需要 scheduler · continuation 如何形成 ·
stackful/stackless 或其他 realization。

#### ⚠ 5.1 **必须保留的边界（不可与上条合并）**

> **原文**：**异步 realization 可以自动推导；程序是否要求「产生新的并发执行关系」，是另一回事。**
> 「`a(); b();` 能不能自动并行，**可由 dependency / state relation 判断并优化**；但如果某种语法
> **明确表示『我要产生一个独立并发任务并获得其生命周期/结果』**，那是**程序语义**，不只是 coroutine
> 实现细节。**现有 `go` 如果承担的是这个意义，就和『async/await 要不要暴露』是两件事**——两件都要
> 保留各自的判断，**不许合并**。」

**⇒ 操作化（写手展开）**：

| 问题 | 归属 | 判定者 |
|---|---|---|
| 「能否 suspend / frame 怎么放 / resume 何时发生 / 能否消除」 | **realization** ⇒ 自动推导，**不产生新语法、不进类型** | 编译器（不变量 5 主体）|
| 「`a(); b();` 能否自动并行」 | **优化** ⇒ 由 dependency / state relation 判断 | 编译器（与上同侧）|
| 「我要**产生一个独立并发任务**并拿到它的**生命周期/结果**」 | **程序语义** ⇒ 是语言表面，**不得**降级成 realization 细节 | 用户意图（**不猜**）|
| 现有 `go` 属于哪一栏 | **既有表面的归属判定** | **维护者**（本档**不替**其合并，见下）|

**现状锚点（`[已实现]`）**：`go f(a)` 今日的 lowering = `IR_CALL sched_go(@addr(f), arg)`
（`src/compiler/ir_gen.cr:1921` + `:1933-1934`）；`sched_go` 建 G + 1 元素 result channel
（`src/stdlib/sched.cr:171`）；range-go 另发 `IR_SPAWN`。**不变量④已定**：并发接口的演进**不得反向决定**
函数值的类型模型 ⇒ 与本条同侧，**两处判断各自保留**。

#### 5.2 与块三总原则的关系（**同一条，原文要求并排**）

> **块三原文**：「由现有关系唯一确定的，自动推导；涉及用户意图选择的，不猜。」
>
> **不变量 5 是这句话的又一次应用**：异步面的全部属性都是「由现有关系（调用图 / 状态依赖 / region /
> scheduler 绑定）唯一确定的」⇒ 自动推导；而「是否产生新的并发执行关系」是**用户意图选择** ⇒ 不猜、
> 必须由语法表达。**两条并排读，不得只留一条**。

---

## 一、现状锚点（**全部在 `develop@origin` 上实核**）

### 1.1 已核实的锚点（`[已实现]`）

| # | 锚点 | 结论 | file:line |
|---|---|---|---|
| A1 | `fn` 关键字 | 已有词法关键字 | `src/compiler/lexer.cr:72`（`if s == "fn" { return T_FN; }`）；`T_FN : int = 5`（`src/compiler/ast.cr:10`）|
| A2 | `FunctionDecl` 产生式 | **已有** | `grammar/core.ebnf:12-14` |
| A3 | `FunctionType` / `FunctionRef` / `LambdaExpr` 产生式 | **全缺**（`core.ebnf` 逐名 grep 零命中） | `grammar/core.ebnf`（`Type` 候选表 = `:38`）|
| A4 | `Type` 候选表 | `BaseType \| PathType \| RefType \| OptionalType \| TupleType \| ArrayType \| SliceType`——**无函数型** | `grammar/core.ebnf:38`；各产生式 `:41`/`:44`/`:45`/`:46`/`:47`/`:48`/`:49` |
| A5 | `Primary` 候选表 | `Literal \| IDENT \| ProjectAccess \| '(' Expr ')' \| 'move' Primary \| BlockExpr \| ...`——**无 `fn` 形态**（`fn` 是关键字、不是 `IDENT`） | `grammar/core.ebnf:65` |
| A6 | 调用后缀 | `CallOrField = Primary { '(' [ArgList] ')' \| '.' IDENT \| '[' Expr ']' \| '?' }`——**`f(args)` 形态已通用**，不绑定函数名 | `grammar/core.ebnf:64` |
| A7 | `TYP_*` 全表 | **0/1/2/3/4 · 7/8/9/10/11/12/13**（= `TYP_BASE`/`NAMED`/`ARRAY`/`REF`/`PTR` / `GENERIC_PARAM`/`GENERIC_APPLY`/`SLICE`/`TUPLE`/`DYN`/`OPTIONAL`/`NULL`）——**无函数类型 kind**；**空位 = 5 与 6** | `src/compiler/ast.cr:291-309`（逐常量行）|
| A8 | 空位 5/6 复核 | 全仓（`src/` + `bootstrap/`）无 `TYP_*` 取 5 或 6 ⇒ **5 确为空位**（附确认 #2 成立） | grep `TYP_[A-Z_]* *: *int *= *(5\|6);` 零命中 |
| A9 | 类型行分配器 | `alloc_type(kind, data, extra)` = **裸分配器、不去重**（原文注释保留） | `src/compiler/checker.cr:10-18`；去重先例 = `TYP_NAMED` 的 `named_dedup`（`src/compiler/checker.cr:20-33`）|
| A10 | 规范行占位 | `init_types()` **在表头建 8 行原生行**（`:248-255`：`TI_INT..TI_DYN`）+ **1 行占位**（`:260` `alloc_type(TYP_BASE, TY_DEX_S, 0)`）| `src/compiler/checker.cr:231`、`:248-260`；设计注 `src/compiler/ast.cr:284-288` |
| A11 | 调用 opcode | `IR_CALL = 4`（`dest=result, s1=first_arg, s2=arg_count, s3=func_name_ni`）——**直接调用** | `src/compiler/ast.cr:558`；发射 `src/compiler/ir_gen.cr:2377` |
| A12 | 间接调用 opcode | **不存在**。全仓 `CALL_PTR` / `CALL_INDIRECT` / `IR_INVOKE` **零命中**（仅 docs 引用其缺席）；最接近的是 `IR_DYN_DISPATCH = 44`（`s1=dyn_var, s2=dispatch_table_ni`，语义 = **`dyn` 值的动态分派**，非 callable 间接调用）| `src/compiler/ast.cr:597`；独立复核 `docs/superpowers/plans/2026-09-20-safety-verification-plan.md:88-90` |
| A13 | `IR_FNADDR` | `= 48`，`dest=addr_var, s1=fn_name_ni`——`movabs` + **链接期回填** | `src/compiler/ast.cr:601`；发射 `src/compiler/ir_gen.cr:2149`（`@addr`）/ `:1921`（`go` 路径）；后端 `src/arch/x86_64/instr.cr:971`、尺寸 `src/arch/x86_64/sizes.cr:80`、回填 `src/format/elf/elf.cr:1353` |
| A14 | opcode 号段 | 已用 0–39 · 41–51（**最大 = `IR_APPROX` = 51**）；**40 在 `IR_*` 号段内空缺** | `src/compiler/ast.cr:554-604`（逐行）|
| A15 | `@addr(fn)` 的类型 | **`TI_INT`**（`ast_set_type_val(node, TI_INT); return TI_INT;`）| `src/compiler/checker.cr:4190-4191`（唯一 checker 侧站点）|
| A16 | `@addr` 的 IR 发射 | `IR_FNADDR`，新变量定型 `TI_INT` | `src/compiler/ir_gen.cr:2144-2149`（`new_ir_var("_fnaddr", TI_INT)`）|
| A17 | `AK_FN` 原子类 | **已存在**：`AK_FN : int = 13`；注册表第 15 行，名 `"fn"`、`ti_row = -1`（类级）、`ops = 0` | `src/compiler/type_engine.cr:29`；`src/compiler/iface_registry.cr:158`（`iface_put(15, AK_FN, -1, str_intern("fn"), -1, 0)`）|
| A18 | 桥接层**已有**函数项构造 | `sh_func_sig_term(fi)`（**入参 = 函数下标**，非类型行）构造 `tt_atom(AK_FN, -1, [返回项, 参数项…])`，链序 = **返回在首** | `src/compiler/ty_shadow.cr:1042`、`:1057`；同形构造亦见于接口形状成员 `src/compiler/ty_shadow.cr:1092` |
| A19 | **不对称（本档要点）** | 类型项层**已有** `AK_FN` 原子 + 已有函数签名→fn 项构造；但 **AST 类型行层无对应 `TYP_*` kind** ⇒ 「行 → 类」映射（`iface_kind_of`）**没有函数行的入口** | A7 + A17 + A18；`src/compiler/iface_axis.cr:196-210` |
| A20 | 行→类分派 | `iface_kind_of(ti)` 逐 kind 分派，**末尾 `return -1`（未知 kind）** | `src/compiler/iface_axis.cr:196`，`:209` |
| A21 | 桥接双构造点 | **两个**行→项构造点必须同改：`sh_term_of_ti`（`:321`，含「未知 kind 保守归入命名类」兜底 `:378-382`）与 `sh_sig_term_of_ti`（`:880`）| `src/compiler/ty_shadow.cr:321`、`:880`（「双构造点契约」注在 `:893-895`）|
| A22 | 纯度/效应表 | `purity_op_effect(op)`：store 族 + `IR_CALL_EXTERN` + `IR_HOTPATCH_ROUTE` + **`IR_DYN_DISPATCH`（间接调用）** + `IR_SPAWN`/`IR_YIELD`/`IR_AWAIT` 入链 | `src/compiler/checker.cr:4533-4546`；消费点 `src/compiler/dataflow.cr:156`（`df_connect_state`；⚠ 多份文档记 `:146`，见 §1.2 D-4）|
| A23 | 诊断族前缀表 | `error_cat_prefix(cat)`：1..17 → `P/N/I/TA/TF/TB/TU/TC/TM/TK/TS/TG/B/R/E/ICE/V`；**落空 `return "E"`** | `src/compiler/diag.cr:86-105`（`:104` = 兜底）|
| A24 | 诊断渲染 | `cat = ec / 1000`、`num = ec % 1000`、`error[<prefix><2 位 num>]` | `src/compiler/diag.cr:123`、`:133-137`（`pad_diag_num` `:107`）|
| A25 | 诊断 fail-closed 闸门 | `diag_gate_exempt(code, scope)` 豁免表（**默认阻断**，逐条带位点/理由/退出条件）| `src/compiler/diag.cr:172`；牙 = `tests/selfhost/test_diag_gate.py`（挂 `selfhost-tests`，`src/ci/run.sh:176`）|
| A26 | 错误码常量计数 | **按锚定 grep** `^EC_[A-Z_]+ *: *int *=` = **149**（非锚定 = 152）。⚠ `docs/developer/errors.md:327` 记「③ … = **137**」= **已过期**（+12）| `src/compiler/ast.cr`（本档实测）· `docs/developer/errors.md:325-329`（三种数法注）|
| A27 | `.ccr` 版本 / 段表 | `CCR_VERSION = 9`；`CCR_SEG_COUNT = 8`（STR/SYM/NOD/ENT/REG/EDG + TYPE(7)/IFACE(8)）| `src/compiler/ccr_io.cr:135`、`:138-139` |
| A28 | `TYPE(7)` 段体结构 | `[row_count u32][row_count × 24B {kind,data,extra}][term_count u32][term_count × 40B {tag,a,b,c,d}]`——**`g_types` 内存行表原样** + 项 DAG | `src/compiler/ccr_types.cr:9-14`；写侧 `src/compiler/ccr_io.cr:601`、`:896`；读侧 `:1534-1584`（逐条硬校验）|
| A29 | `IFACE(8)` 段原生条目 | 计数 = `IFACE_ENTRY_COUNT = 16`，**`AK_FN` 已占第 15 行** ⇒ 不新增原子则 IFACE 段零变化 | `src/compiler/dyn_arr.cr:215`；`src/compiler/ccr_types.cr:197`、`:211-217` |
| A30 | 桥接 selftest 的**有意闸** | `ts_ccr2_kind_domain_ok`：**全类型行枚举**，任何行命中 `AK_NULL/AK_SUM/AK_FN` ⇒ 返回 0（注释：「若未来给某行新映射到 … 本用例转红 = **有意的闸**」）| `src/compiler/type_selftest.cr:1635-1646`（断言行 `:1642`）|
| A31 | 零 ops 行计数钉 | `ops.entry_row_consistent`：零 ops 行 **恰 3 行**（`AK_NULL`/`AK_SUM`/`AK_FN`），多一行即红 | `src/compiler/type_selftest.cr:2744-2745`（`:2739-2740` 计数）|
| A32 | `AK_FN` 条目断言 | `iface_count() == 16` · `iface_ops(AK_FN) == 0` · `iface_ti_of(AK_FN) == -1` · `iface_name_of(AK_FN) == "fn"` | `src/compiler/type_selftest.cr:1603`、`:1609`、`:1612`、`:1629` |
| A33 | `sched_go` 签名 | `fn sched_go(fn_ptr: int, arg: int) -> string`（**裸 `int` 函数地址**）| `src/stdlib/sched.cr:171` |
| A34 | 内建返回型表 | `bi_add("sched_go", TI_INT)`（checker 侧内建模型）| `src/compiler/checker.cr:299` |
| A35 | 解释器对未支持 op 的政策 | **响亮报错**（非静默错值）：`IR_DYN_DISPATCH` / `IR_CALL_EXTERN` 两处均显式 `println("error: interp 不支持…")` | `src/compiler/interp.cr:406-411`、`:736-741` |
| A36 | 编译期缓存双档 | `.cir` 快照版本常量 **`CIR_CACHE_VER : int = 22`**（⚠ `src/ci/run.sh:162` 的注释写「`CIR_CACHE_VER 19→20`」= **该批当时的代**，非当前值）| `src/compiler/cir_cache.cr:135` |
| A42 | RegionCheck 判定面 | 头注原文：「RegionCheck pass — verifies **DEREF targets are in live subgraphs**」；接线 `main.cr:639 region_check_all()` | `src/compiler/region_check.cr:1-3`；`src/compiler/main.cr:639` |
| A37 | CI 门 | `src/ci/run.sh` 共 **5 个 job**：`check` / `bootstrap-tests` / `selfhost-tests` / `suite` / `full-bootstrap`；canary 载体挂 `selfhost-tests` 内 | `src/ci/run.sh:70-71`、`:76`、`:114`、`:218`、`:345`、`:350` |
| A38 | canary 锁定值真源 | `tools/baseline/canary_values.tsv`（5 条 = ELF canary + `.ccr` 四条）；闸门 = `tools/baseline/canary_check.sh`；**两级契约** + **D1 确定性闸门** + 重锁前置 | `tools/baseline/canary_values.tsv`（头注）· `tools/baseline/canary_check.sh:35-59` |
| A39 | 既有「函数值」陈述 | TODO 记「**函数值设计为 YAGNI 挂起**」（该句嵌在「嵌套 `fn` 声明不属语言面」条目里）| `TODO.md:426` |
| A40 | 既有方向陈述 | 类型系统方向第 11 条「**函数类型隐式化**」：…「函数值 = 子图引用（`@addr` 机制已有）」；「**明确不做**：HKTs（高阶泛型）」 | `docs/superpowers/specs/2026-08-30-type-system-direction-design.md:29`、`:41` |
| A41 | CFI 的前置缺失登记 | 「IR 层无间接调用 opcode … ⇒ `possibleTargets` **当前不可从图上导出**；本项 … 属**前置缺失**，不是增量接线」 | `docs/superpowers/plans/2026-09-20-safety-verification-plan.md:88-90`、`:114`、`:176`、`:276` |

### 1.2 锚点漂移与**陈旧陈述**登记（**引用他人文档前必读**）

本仓文档里的行号与计数随修订漂移。本档实核时发现**七处**既有陈述与当前修订不符
（**语义结论均不受影响**，但直接引用会取到错值）：

| # | 出处 | 其陈述 | 当前修订实核 | 差 / 性质 |
|---|---|---|---|---|
| D-1 | `2026-09-20-safety-verification-plan.md:88`、`:276` 引「`checker.cr:4180` 注明 function address, type int」 | `:4180` | `:4189-4191`（`:4180` 现为**空行**）| +9 行号漂移 |
| D-2 | 同件 `:88` 引「`ir_gen.cr:2133`」 | `:2133` | `:2144-2149` | +11 行号漂移 |
| D-3 | `2026-09-17-concurrency-model-design.md:390`、`:427` 引 go lowering「`ir_gen.cr:1672-1673` / `:1697`」；`:400` 引「`ast.cr:546-548`」 | `:1672`/`:1697`/`ast.cr:546` | `sched_go` 调用 = **`:1933-1934`**；`IR_FNADDR` = **`:1921`**；range-go 的 `IR_SPAWN` = **`:1958`**；`IR_SPAWN=27`/`IR_YIELD=28`/`IR_AWAIT=29` = **`ast.cr:582-584`** | +261 / +261 / +36 行号漂移 |
| D-4 | 多份文档引 `df_connect_state` 在 `dataflow.cr:146`（如 `2026-09-11-merge-semantics-design.md:101`）| `:146` | **`:156`** | +10 行号漂移 |
| D-5 | `src/compiler/diag.cr:184`、`:188` 的豁免理由：「`EC_TF_ARG_TYPE` **全仓唯一 raise 点**在 `@raw_int` 内建位（**`checker.cr:3727`**）」| 唯一 / `:3727` | raise 点 = **3 处**：`checker.cr:4265`（`@raw_int`）· `:4334`（`@ptr_of`）· `:4340`（`@str_of`）；`:3727` 现为 `EXPR_FIELD` 分支 | **计数 + 行号双漂移**；且该条目在 `diag.cr` 内**文本重复两条**（`:186` 与 `:190` 全同）|
| D-6 | `tools/baseline/canary_values.tsv` 头注：「**不得** unset 或置空 `HOME`——`module.cr:526` 有硬编码 `/home/DslsDZC` 兜底」| 「有硬编码兜底」 | **该兜底已被移除**（第 4 批 #83）：`src/compiler/module.cr:557-566` 原文「**不再**兜底到硬编码家目录 … 字面已从源码移除，判据 J4 要求 `src/` 内该串零命中 ⇒ 此处亦不得回引」；现路径读取**以 `HOME` 非空为前提**（`:568-575` 嵌套 if）| **机制已变**（纪律本身见 §8.2 第 5 条）|
| D-7 | `docs/developer/errors.md:327`：「③ `ast.cr` 实际定义的 `EC_*` 常量 = **137**」| 137 | **149**（锚定 grep）| +12 计数漂移 |

> **D-5/D-7 的一般化（写手展开）**：本仓的「**唯一 raise 点**」「**N 处**」这类**枚举型计数随细看只会变多**
> ⇒ 引用时写「**至少 N**」+ 带 file:line 的清单，别写裸的「唯一」。
> 本档因此对同类断言一律附**出处与口径**（§8.2 第 3 条的契约、§八 的段体结构均如此）。
>
> ⚠ 这些**不是**那些文档的错误结论，只是**取值时代的读数**。本档一律用当前修订的值；
> 反过来，**引用本档时也应按当时的 `develop@origin` 复核**（本仓既有教训：逐字节相同的两个检出
> 可能一个已落后，而读数看不出异常）。

### 1.3 **未核实清单**（见 §十一汇总）

---

## 二、语法（块二最小增量 × `grammar/core.ebnf` 现状**逐条对齐**）

### 2.1 四项能力 × 现状 × 增量

| 块二能力 | 现状 | 增量性质 | 新产生式 |
|---|---|---|---|
| ① 函数类型 | `Type` 候选表无函数型（A4） | **全新** | `FunctionType` |
| ② 命名函数值 | `fn` 是关键字、`Primary` 不含它（A5） | **全新** | `FunctionRef` |
| ③ Lambda | 无（A5） | **全新** | `LambdaExpr` + `LambdaParamList` + `LambdaParam` |
| ④ callable 调用 | `CallOrField` 的 `'(' [ArgList] ')'` **已通用**（A6）| **零语法增量** | 无 |

> **原文**：「**不新增**：`indirect_call(...)` · `f.call(...)` · `(*f)(...)`」·「除此之外，这一轮不需要再加别的函数语法」。
> **写手展开**：④ 之所以零增量，是 A6 已经给了——调用后缀挂在 `Primary` 上、不认被调者的类别。
> ⇒ 实现侧**唯一**要动的是 checker/ir_gen 对「被调者是 callable 值」的分派（见 §3.4），**不是文法**。

### 2.2 增量 EBNF（**原文逐字**）

```ebnf
FunctionType =
    'fn' '(' [ Type { ',' Type } ] ')' '->' Type ;

FunctionRef =
    'fn' '.' IDENT ;

LambdaExpr =
    'fn' '(' [ LambdaParamList ] ')'
    (
        '=>' Expr
      | '->' Type Block
    ) ;

LambdaParamList =
    LambdaParam { ',' LambdaParam } ;

LambdaParam =
    IDENT [ ':' Type ] ;
```

接线（**原文**）：

```ebnf
Type    += FunctionType
Primary += FunctionRef
Primary += LambdaExpr
```

落点：

- `Type += FunctionType` ⇒ `grammar/core.ebnf:38` 的候选表追加一项；产生式插在 `(*** 类型 ***)` 段内。
- `Primary += FunctionRef | LambdaExpr` ⇒ `grammar/core.ebnf:65` 的候选表追加两项。

### 2.3 与现状的**逐条对齐结论**

| 项 | 对齐结论 |
|---|---|
| `FunctionDecl` | **已有**（A2），本轮**不动**。`FunctionType` 与 `FunctionDecl` 的 `'->' Type` 部分**同形**（`:12`）⇒ 实现者可复用返回型解析 |
| `Type` 递归 | `FunctionType` 的返回位是 `Type` ⇒ **自嵌套**合法（`fn(int) -> fn(int) -> int`）。结合性**必须定死**（见 §十 待裁 T-8）|
| 与 `OptionalType` 的冲突 | `OptionalType = Type '?'`（`:46`）⇒ 裸 `fn(int) -> int?` **歧义**（返回 `int?` 还是「函数类型可选」）。**原文用例一律带括号**：`(fn(int) -> int)?` ⇒ **写手展开**：规定「函数类型整体加括号后才可参与 `?`/`[...]`/元组等组合」，裸形报错 |
| 与 `CallOrField` 的关系 | 块二原文用例 `f: fn(int) -> int` · `[fn(int) -> int]` · `(fn(int) -> int, int)` 均落在 `Type` 位 ⇒ 不经过 `CallOrField` |
| `LambdaParam` 的 `[: Type]` | 「可选类型」= 由 expected type 推导（块一）⇒ **推导失败即新诊断码**（§七），**不得**退化成 `auto`/`dyn` |
| `LambdaExpr` 的块形 `'->' Type Block` | 与 `FunctionDecl` 的 `'->' Type FunctionBody`（`:12-14`）同形；块 lambda **本体是 `Block`**，`{` 一出现即与表达式形（`=>`）分派 |

### 2.4 `flow` 的撞名分离（**三义**；不变量 5 的直接前置）

> **为什么单列**：不变量 5 否决了一个名为 `flow fn(...)` 的候选，而本仓**已经有 `flow`**。
> 若不分开写明，读者会以为 `flow` 这个词被动了。

| 义 | 是什么 | 现状（`develop@origin` 实核）| 本次收缩的影响 |
|---|---|---|---|
| **① region 种类** | 数据流图里的 region kind `SG_FLOW` | `src/compiler/dataflow.cr:533`（DOT 名 = `"flow"`）；种类常量族 = `src/compiler/dyn_arr.cr:155-159`（`SG_LOOP=1`/`SG_FOR=2`/**`SG_FLOW=3`**/`SG_UNSAFE=4`/`SG_IF=5`）| **不在收缩范围**（既有、不动）|
| **② 声明前缀** | `flow` 作**顶层声明**关键字 | ① 文法：`FlowDecl = 'flow' IDENT [GenericParams] '(' [ParamList] ')' '->' Type {Annotation} (FunctionBody \| '=' Expr ';')`（`grammar/core.ebnf:22-24`），且在 `TopLevelDecl`（`:9`）；② **parser 另接受 `flow fn name()` 拼写**（`src/compiler/parser.cr:1726-1748`，注释原文「F5c：`flow fn name()` 语法」，`is_flow` 置位后由 checker 按 body 内 `yield` 处理——`src/compiler/checker.cr:2310-2313`）；③ 关键字 = `T_FLOW : int = 66`（`src/compiler/ast.cr:70`）· `lexer.cr:94` | **不在收缩范围**。⚠ **`flow fn name(...) -> R { … }` 是既有声明，不得读成「被取消」**；被否决的只是**它在类型位**的用法 |
| **③ 函数类型前缀** | 类型位上的 `flow fn(T) -> R` | **今日零实现**：`parse_type()`（`src/compiler/parser.cr:41`）的分支只有 `[` / `(` / `&` / `*` / …，**无 `T_FN` 也无 `T_FLOW` 分支** | **本次收缩 = 否决该候选**（它从未存在过 ⇒ 这条收缩是**对未来候选的否决**，不是移除既有能力）|

**三条结论**：

1. **块二的「最小语法增量」不变**——本来只有那三个产生式（`FunctionType`/`FunctionRef`/`LambdaExpr`），
   收缩**不增不减**（不变量 5 的 7 个「不加」项**从未进入**该增量）。
2. **`flow` 的 ①② 义与本轮正交**：它们属**声明面/图面**，不是类型面。
3. ⚠ **`yield` 面的既存事实（须与实现者对齐，见 §十 T-10）**：`yield` 已是关键字（`T_YIELD : int = 67`，
   `ast.cr:71`；`lexer.cr:95`），`IR_YIELD = 28`（`ast.cr:583`，注释「emit value from flow to consumer
   channel」）在 `ir_gen.cr:2878` 发射；但后端与解释器都是**近似/空操作**（`src/arch/x86_64/sizes.cr:77`
   原文「no-op (for now)」⇒ 尺寸 **0**；`interp.cr:385`「eager 值传递近似」）；语料
   `tests/test_flow.cr`（`flow counter()` + `yield` + `go counter();`）**在 `tests/` 根、未被任何
   runner 引用**（已 grep：仅一份报告提到它）⇒ 属**半实现表面 + 无 CI 挂点**。

---

## 三、四段（① 函数类型 ② `fn.name` ③ Lambda + 推导 ④ 间接调用 + 后端）

> ⚠ **顺序 ≠ 分期**。**原文（附）**：「一份计划，**分四段一次做完**」。
> 分段**只为可独立提交评审**——四段的判据必须在**同一条自举链**上一起绿，不得把后面段留成"以后再说"。

### 3.0 四段总表

| 段 | 入口（文法 / 文件·函数） | 依赖 |
|---|---|---|
| ① 函数类型 | `core.ebnf:38` `Type` + 新 `FunctionType` · `parser.cr:41 parse_type()` · `checker.cr:971 res_type_node()` · `ast.cr:291-309`（新 `TYP_FN`）· `ty_shadow.cr:321/:880` · `iface_axis.cr:196` | 无 |
| ② `fn.name` | `core.ebnf:65` `Primary` + 新 `FunctionRef` · parser 表达式主元 · checker 新节点 · ir_gen（`IR_FNADDR` 复用） | ① |
| ③ Lambda + 推导 | `core.ebnf:65` + 新 `LambdaExpr`/`LambdaParamList`/`LambdaParam` · parser 表达式主元 · checker（含 capture 分析） | ① ② |
| ④ 间接调用 + 后端 | 新 IR opcode（`ast.cr:554-604` 号段）· `ir_gen.cr`（调用点 `:2377` 同域）· `arch/x86_64/instr.cr`/`sizes.cr`/`regalloc.cr` · `interp.cr` · `dataflow.cr`/`ent_kernel.cr`/`opt.cr` · `checker.cr:4533` | ① ② ③ |

### 3.1 段① 函数类型

**入口**

- 文法：`grammar/core.ebnf:38`（`Type` 候选表 +1）+ 新产生式 `FunctionType`。
- parser：`src/compiler/parser.cr:41 fn parse_type()`（新增 `T_FN` 分支；`T_FN` 已存在 = A1）。
- 名字/类型解析：`src/compiler/checker.cr:971 fn res_type_node(node)`（类型节点 → `ti`）。
- 类型行：`src/compiler/ast.cr:291-309` 新增 `TYP_FN : int = 5`（**附确认 #2**：空位 5 经 A8 复核确实空闲）。
  - 建行点必须走 **「只查不建」**（先问「是否已建过同签名行」，照 `TYP_NAMED` 的 `named_dedup` 先例，`checker.cr:20-33`）——`alloc_type` 是裸分配器（A9）。
  - **不得**在 `init_types()` 里给 `TYP_FN` 预建规范行（A10 的占位先例）——理由见 §八 的足迹分析。
- 桥接（**双构造点，同改**）：`src/compiler/ty_shadow.cr:321 sh_term_of_ti` + `:880 sh_sig_term_of_ti`
  ⇒ `TYP_FN` 分支构造 `tt_atom(AK_FN, -1, [返回项, 参数项…])`，**链序 = 返回在首**（与 A18 的 `sh_func_sig_term` 同形）。
  - ⚠ **不给分支的后果是静默的**：`sh_term_of_ti` 的兜底把未知 kind 译作 `tt_atom(AK_NAMED, ti, -1)`（无链）⇒ 引擎判「命名面域外」= `-1`（A21）。**不报错、不崩**，只是判不了。
- 行→类：`src/compiler/iface_axis.cr:196 iface_kind_of` 新增 `if k == TYP_FN { return AK_FN; }`（在 `:209` 兜底之前）。
- **同批必改的判据载体**：`src/compiler/type_selftest.cr:1635-1646 ts_ccr2_kind_domain_ok` ——
  该用例**按设计**会在本段转红（A30：「有意的闸」）。重定形状：排除面 3 原子 → 2 原子（`AK_NULL`/`AK_SUM`）
  + **新增一条正钉**（`TYP_FN` 行 → `AK_FN`，且**只有** `TYP_FN` 行能命中 `AK_FN`）。
  - 同批复核 `type_selftest.cr:2744-2745`（`o4_zero == 3`）：**只要 `AK_FN` 的 `ops` 保持 0，该钉不动**。
    若实现者决定给函数类型任何 ops 位 ⇒ 该用例必红 ⇒ **停下上报**（这是「零 ops 行恰三行」的既有契约）。

**做完的判据**

| 面 | 判据 |
|---|---|
| 绿·类型位 | `fn(int) -> int` / `fn(int, int) -> bool` / `fn() -> unit` 三形作类型位，`check` **rc=0** |
| 绿·组合 | 原文三组合 `(fn(int) -> int)?` · `[fn(int) -> int]` · `(fn(int) -> int, int)` 各 `check` rc=0 |
| 绿·别名 | `type Handler = fn(int) -> unit;` + 用 `Handler` 作形参型，`check`/`build`/`run` rc=0 |
| 绿·高阶形参 | 原文 `fn apply(f: fn(int) -> int, x: int) -> int { return f(x); }` —— 本段只要求**签名可解析、类型可判定**（调用语义归段④）|
| 红·缺返回 | `fn(int)`（缺 `'->' Type`）⇒ `check` rc=1 + 定位 + **零产物**；`build` rc=1 + 零产物 |
| 红·裸组合歧义 | 裸 `fn(int) -> int?` ⇒ rc=1 + 定位（按 §2.3 的加括号规定）|
| 判定面 | `ty_sub(T, T) = 1`（同签名同型）；`ty_sub(fn(int)->int, fn(int)->bool) = 0`（不同签名不互含）|
| **两向钉子** | 一条**必须红**的负钉：`fn(int) -> int` 与 `int` 互赋 ⇒ rc=1 + `error[TA01]` + 零产物（防「函数类型静默退化成 int」——正是不变量③的同族风险）|
| selftest | `selftest-types` 新用例 + `ts_ccr2_kind_domain_ok` 重定后全绿（`corec selftest-types`）|

**依赖**：无（本段可独立成立，不触碰 IR）。

### 3.2 段② `fn.name`（命名函数值）

**入口**

- 文法：`grammar/core.ebnf:65`（`Primary` 候选表 + `FunctionRef`）+ 新产生式 `FunctionRef = 'fn' '.' IDENT`。
- parser：表达式主元分派处（现 `Primary` 无 `fn` 形态 ⇒ 现状下 `fn.square` 无产生式；**注意**：这是**文法推导**，非实跑，见 §十一）。
- checker：新 AST kind（`EXPR_FNREF` 或等价）⇒ 类型 = 段① 的 `TYP_FN` 行；名字解析：函数必须存在，否则 `EC_N_FUNC`（`checker.cr:3297` 同族，`error[N06]`）。
- ir_gen：callable 值的**取址**原语复用 `IR_FNADDR`（A13）——它给出的正是 `{code, 回填后绝对址}`；
  `env = 0`（不变量④的 CPU realization：「无 capture -> `{code, 0}`」）。
  - ⚠ **类型必须写 `TYP_FN`，不得写 `TI_INT`**。现状 `@addr` 路径写的是 `TI_INT`（A15/A16）——**照抄它就等于把不变量③做废**。

**做完的判据**

| 面 | 判据 |
|---|---|
| 绿·取值 | `f := fn.square;` `check`/`build`/`run` rc=0 |
| 绿·调用 | `f := fn.square; f(10);` 运行结果 = `100`（`square(10)`）|
| 绿·直接调用 | 原文 `fn.square(10);` 同 rc=0 + 同结果 |
| 绿·无名字歧义 | 原文 `square := 123; f := fn.square;` ⇒ rc=0（变量 `square` 与函数 `square` 并存不冲突——这正是 `fn.` 前缀要买的东西）|
| 红·函数不存在 | `fn.nope;` ⇒ `check` rc=1 + `error[N06]` + 定位 + **零产物** |
| **两向钉子（不变量③）** | ① 断言 `fn.square` 的类型 **== 「`@addr` 表达式」的类型** ⇒ 必须红（现状 `@addr` = `int`，A15）② 断言两者**可互赋**（`f: fn(int)->int = @addr(square);` 与 `p: int = fn.square;`）⇒ **两条都必须 rc=1**。钉子双侧都点名，防「单向判据对反向缺陷恒绿」 |
| 类型面 | `fn.square` 的类型行 kind == `TYP_FN`（可用 `corec ccr` / `cir` 通道或 selftest 断言；**判据点须与 §八 的字节面分开**）|

**依赖**：段①（需要 `TYP_FN` 行承载类型）。

### 3.3 段③ Lambda + 推导

**入口**

- 文法：`grammar/core.ebnf:65`（`Primary` 候选表 + `LambdaExpr`）+ 三个新产生式（`LambdaExpr`/`LambdaParamList`/`LambdaParam`）。
- parser：表达式主元分派处；两种形（`'=>' Expr` / `'->' Type Block`）按 `{` 分派。
- checker：新 AST kind（`EXPR_LAMBDA`）+ 三件分析（块一）：
  1. **capture 集合**（引用了哪些外部值）——不写 capture list；
  2. **capture 访问性质**（只读/修改/转移）——**不引入 `Fn`/`FnMut`/`FnOnce` 概念**（块一原文）；
  3. **参数/返回型推导**（expected type 优先；无上下文 ⇒ 新诊断码）。
- capture 环境：**§六**（已确认：默认按引用、外层栈帧、逃逸判不了即报错）。

**做完的判据**

| 面 | 判据 |
|---|---|
| 绿·表达式形 | `f := fn(x: int) => x * 2;` `check`/`build`/`run` rc=0 |
| 绿·expected type 推导 | `f: fn(int) -> int = fn(x) => x * 2;` ⇒ rc=0（`x` 由 expected type 得 `int`）|
| 绿·块形 | `f := fn(x: int) -> int { y := x * 2; return y + 1; };` rc=0 + 运行值正确 |
| 绿·自动捕获 | `base := 10; f := fn(x: int) => x + base;` rc=0 + **运行值 = `x + 10`**（这条同时证明 capture 真被读到；若实现把 `base` 丢成 0，运行值会错——**值断言不可省**）|
| 绿·可变捕获 | `f := fn(y: int) => { x = x + y; return x; };` ⇒ rc=0，且**源码零 `mut` 之外的新标记** |
| **红·无上下文不猜** | `f := fn(x) => x * 2;` ⇒ `check` rc=1 + **新诊断码**（§七）+ 定位 + 零产物。⚠ 这是块一原文：「**如果参数类型没有任何上下文可推，也应该报无法推导，而不是偷偷猜一个类型**」——**它必须不是类型错**（附确认 #3）|
| 红·逃逸报错 | 含捕获 lambda 逃出 region 可判定域（如存进返回位/堆结构）⇒ rc=1 + 定位（§六；**不得**静默堆分配、**不得**静默通过）|
| **零新标记判据** | 全部 lambda 用例源码中**不出现**：`move` 作 capture 标记 · `capture[...]` · `Fn`/`FnMut`/`FnOnce` · `closure<...>` · `Callable<...>`。判据 = 语料 grep 零命中 + 上表全绿 |
| 与段②互赋 | 原文「无 capture lambda、`fn.name`、有 capture lambda 可以正常互相赋值」⇒ **三三互赋 6 向**全 `check` rc=0 + 至少一对 `run` 值正确（不变量①的直接判据）|

**依赖**：段①（lambda 的类型就是 `TYP_FN` 行）+ 段②（同 realization ⇒ 互赋才有意义）。

### 3.4 段④ 间接调用 + 后端

**入口**

- 新 IR opcode（**待裁 T-6**：编号取 `IR_*` 号段的空位 **40** 或 **≥52**；A14；⚠ 号段 `IR_*` 的 40 与 `T_GTEQ = 40`（token 段）、`EXPR_TUPLE = 40`（AST 段）**同名不同段**，勿混读）。
- 发射：`src/compiler/ir_gen.cr` 的调用点（现 `:2377` 发 `IR_CALL`，`:2358` 发 `IR_CALL_EXTERN`）；被调者不是「已解析函数名」时走新 op。
- 后端（x86-64）：`src/arch/x86_64/instr.cr`（新 op 的发射体；间接 `call r/m64`）· `src/arch/x86_64/sizes.cr`（**尺寸必须精确**——标签/偏移按它算）· `src/arch/x86_64/regalloc.cr`（若涉及寄存器类/冲突位，照 `IR_DYN_DISPATCH` 的 `:448/:453` 先例）· `src/os/linux/callseq.cr`（SysV 参数分派宿主；**若** realization 采「env 作隐藏首参」，必须在**这一层**表达，且不得打乱既有三处同源合流）。
- 链接期：`code` 字由 `IR_FNADDR` 提供 ⇒ 复用 `src/format/elf/elf.cr:1353` 的回填。
- 解释器：`src/compiler/interp.cr`（政策 = A35：不支持的 op **响亮报错**，绝不静默错值）。
- **分析面（最易漏的一族，逐处都要认新 opcode）**——以 `IR_CALL_EXTERN` 的全仓站点为模板（同一套位置）：

  | 面 | 站点模式 | 现状参照 |
  |---|---|---|
  | 纯度/效应 | `checker.cr:4533-4546 purity_op_effect` ⇒ 间接调用**必须入链**（= 效应）| `IR_DYN_DISPATCH` 已在表内（A22）|
  | 图/use-def + DOT 名 | `dataflow.cr:307/:402`（use 面）、`:638-639`（opcode→名）| `IR_DYN_DISPATCH` = `"dyn_dispatch"` |
  | 格层 opcode→名 | `src/lattice/ent_kernel.cr:350/:366`、特判 `:271` | 同上 |
  | 优化器跳过模式 | `src/compiler/opt.cr:271-275` | 同上 |
  | 尺寸表 | `src/arch/x86_64/sizes.cr:78/:80/:84` | 同上 |
  | 解释器 | `interp.cr:406-411`、`:736-741` | 同上 |

- **CFI/验证面**：本段是 `2026-09-20-safety-verification-plan.md` §1.3（A41）登记的「间接调用表示缺失」的**前置载体** ⇒ 本段落地后须回头更新该件的 §1.3/§4 行（**该更新属另一批**，本档只登记义务）。

**做完的判据**

| 面 | 判据 |
|---|---|
| 绿·间接调用 | `f := fn.square; f(10)` 三面（`check`/`build`/`run`）= rc=0，运行 = `100`；ELF 可执行 |
| 绿·有捕获 | `base := 10; f := fn(x: int) => x + base; f(32)` ⇒ rc=0 + 值 = `42`（**env 双字路径**：这条是「有 capture -> `{code, env}`」唯一能被观测的地方）|
| 绿·互赋后调用 | 段②/③ 的 6 向互赋各取一对**真调用**，值正确 |
| 静态化 | 块一原文：「`f(x)` 到底能静态化成直接调用，还是必须保持动态 callable 调用，由编译器判断；用户语法相同」⇒ 判据 = **行为不可观测差异**（开关两态结果相同，见 待裁 T-9）|
| 红·未解析目标 | 调用一个**非 callable** 的变量（如 `n : int = 1; n(2);`）⇒ rc=1 + 定位 + 零产物（**不得**静默发间接 call 打崩后端）|
| 红·效应面 | 含间接调用的函数**不得被判纯** ⇒ 负控 = 构造「间接调用夹在两 store 之间」的用例，断言 state 链 `touch` 计数非 0（照 `purity_selftest.cr:292-294` 的 extern 负控形状）|
| 红·解释器 | `run` 面遇到新 op：**响亮报错**（rc≠0 + 文案）或实现之；**不得**静默落空（A35 政策）|
| 尺寸面 | `sizes.cr` 的新 op 尺寸与实际发射字节数**逐一相等**（否则标签/偏移错位 ⇒ 静默错码）|
| 暖态 | `.cir` 暖态重放：新 op 的项派生（`sh_tk_term_of_code` 家族）必须覆盖 ⇒ 冷/暖 `(op,tk,term,tag,a,b,c)` 逐行相同（否则暖态分歧）|
| `.ccr` | 见 §八 |
| 自举链 | `corec2 == corec3`（`cmp`）+ `error[N06] = 0` + 冒烟程序 rc=0（本仓既有自举判据组）|

**依赖**：段①（类型行）② （取值）③ （lambda 值）。

---

## 四、自动推导清单与分类表

### 4.1 自动推导清单（块一 —— 落成可查条目）

> **原文总原则**：「凡是能从函数签名、expected type、函数体、capture 使用方式、borrow / region / state /
> provenance 关系中唯一推出的 callable 属性，默认全部自动推导，不新增用户标记。」

| # | 项 | 原文要点 | 落点（段）|
|---|---|---|---|
| D1 | 命名函数值的函数类型 | `f := fn.square;` 直接从签名得 `fn(...) -> ...` | ② |
| D2 | Lambda 参数类型 | 有 expected type 时推导；**没有足够上下文则不猜** | ③ |
| D3 | Lambda 返回类型 | 表达式形从表达式推；块形若将来允许省略 `-> R`，从所有返回路径推 | ③（块形 `-> R` 本轮**仍必写**，原文块形用例带 `-> int`）|
| D4 | capture 集合 | 自动分析，不写 capture list | ③ |
| D5 | capture 访问性质 | 只读/修改/转移自动分析；**不引入 `Fn`/`FnMut`/`FnOnce`** | ③ |
| D6 | capture 生命周期 / region 要求 | 由 lambda 自身与外部值的 region/borrow 关系推 | ③ + §六 |
| D7 | escape 情况 | 自动判断，**不让用户写 `move` 一类 closure 标记** | ③ + §六 |
| D8 | 调用方式（静态化 vs 动态） | 编译器判断，**用户语法相同** | ④（待裁 T-9）|
| D9 | 无捕获 lambda 的简化 | 自动视为更简单 realization，**不要求用户区分「函数指针」与「closure」** | ③ ④ |
| D10 | 具体 closure realization | 环境是否独立存在/放哪/能否消掉自动决定，**不暴露 closure object** | ④（不变量②）|
| D11 | 泛型/约束唯一确定的部分 | 上下文能唯一确定就直接推，不要求重复写类型 | ①②③ |
| D12 | 可调用性约束 | 由已有语义关系推出，不要求用户选 callable 类别 | ③ ④ |

**D13–D24（异步/协程面，2026-09-23 追加）**——**全部自动推导、全部不产生新语法、全部不进函数类型**
（不变量 5 主体）。原文列名逐条落档：

| # | 自动推导项 | # | 自动推导项 |
|---|---|---|---|
| D13 | 是否可能 suspend | D19 | 是否 escape |
| D14 | suspend point 在哪 | D20 | 何时 resume |
| D15 | 是否需要 coroutine frame | D21 | 是否可直接同步执行 |
| D16 | frame 保存哪些状态 | D22 | 能否消除 suspend/resume |
| D17 | frame 生命周期 / region | D23 | 调用是否需要 scheduler |
| D18 | continuation 如何形成 | D24 | stackful / stackless 或其他 realization |

> ⚠ **与不变量 5.1 的边界**：D13–D24 是 **realization 面**；「是否**产生新的并发执行关系**」
> **不在此表内**（它是程序语义 ⇒ 由语法表达、由用户意图决定，见 §〇 5.1）。
> 也正因如此，`go` 的归属**不得**由本表推出。

### 4.2 分类表（块三 —— **全表落档**）

| 项目 | 能否自动推导 | 结论 |
|---|---|---|
| Currying | ❌ | 是**调用模型选择**，不是从现有代码唯一推出的事实 |
| Partial application | ❌ | 哪些参数要固定、哪些留空属于**用户意图** |
| `Fn` / `FnMut` / `FnOnce` | ✅ | 可从 capture 的读取/修改/消耗关系自动推出 |
| 显式 closure object 类型 | ✅ | closure 环境结构、capture 字段等可由编译器自动生成 |
| 独立 Callable trait | 基本 ✅ 可消掉 | 「能否调用、签名是什么」已经能由 `fn(...) -> ...` 类型确定 |
| Higher-kinded function abstraction | ❌ | 是类型系统**额外表达能力**，不是分析结果 |
| 复杂 capture list | ✅ | capture 集合、方式、生命周期等都可以自动分析 |
| Operator sections | ❌ | 纯语法糖，用户意图不能从普通表达式自动猜 |
| 专门函数组合语法 | ❌ | 也是语法糖，不是可推导属性 |
| **异步/协程 realization** | ✅ | （2026-09-23 追加，原文）**可从调用图 / 状态依赖 / region / scheduler 绑定唯一推出** ⇒ **不进函数类型**（不变量 5）|

原文的压缩表（**逐字**）：

```
自动推导：
    Fn/FnMut/FnOnce 类能力
    closure object/environment
    capture list/mode/lifetime
    callable signature/capability

不要加入：
    currying
    higher-kinded function abstraction
    operator sections
    专门函数组合语法

以后视使用频率决定：
    partial application
```

> 原文对「Callable trait」的进一步裁定：「没必要再写 `interface Callable[T, R] ...`——这不是『推导一个 trait』
> 那么简单，而是**根本可以不建立第二套概念**」。

### 4.3 显式非目标（**「不加入」≠「没想到」——每条给一句为什么**）

| 非目标 | 为什么（原文理由，逐条） |
|---|---|
| **Currying** | 原文：「是调用模型选择，不是从现有代码唯一推出的事实」；`fn add(a,b)->int` 无法唯一判断用户要 `add(1,2)`、`add(1)(2)` 还是固定 `a` ⇒ 「不是『编译器够不够聪明』，而是**信息根本不存在**」 |
| **Higher-kinded function abstraction** | 原文：「是类型系统额外表达能力，不是分析结果」。**旁证（`[已实现]` 的既有裁决）**：`2026-08-30-type-system-direction-design.md:41`「明确不做：HKTs（高阶泛型）」——本非目标与既有方向**一致**，不是新立的限制 |
| **Operator sections** | 原文：「纯语法糖，用户意图不能从普通表达式自动猜」 |
| **专门函数组合语法** | 原文：「也是语法糖，不是可推导属性」 |
| **Partial application**（半非目标） | 原文：「**以后视使用频率决定**」。原文并给了**明确的否决理由**：即便技术上做上下文转换（`f: fn(int)->int = add(1);` ⇒ `fn(x) => add(1, x)`），也「**不建议第一版这么干**」——会让 `add(1)` 同时意味着参数数量错误/partial application/某种 overload，增加隐式规则、反而提高学习成本 |

### 4.4 「不新增第二种函数类型」的 7 个名字（2026-09-23 追加；**逐个列，各给一句为什么**）

> **共同理由（原文）**：`fn(...) -> Future<Data>` / `async fn` / `await` 这类东西**很多是在暴露某种实现模型**
> ——与 Core 的取向相反。**不加入 ≠ 没想到**：7 个名字都是**讨论中被点名否决**的，不是遗漏。
> ⚠ **边界**：本表的否决**不触及** §2.4 的 `flow` ①②义（region kind / 声明前缀）——那是既有的。

| # | 不加入的名字 | 一句为什么 |
|---|---|---|
| N1 | **`flow fn(...) -> ...`**（**类型位**）| 这就是「第二种函数类型」本体：同一个可调用体会有两个类型（`fn(T)->R` 与 `flow fn(T)->R`）⇒ 直接违反不变量 1「一个类型」。⚠ 与 §2.4 义② 的**声明** `flow fn name(...)` 是两件事 |
| N2 | **`async fn`** | 同上（Rust/JS 形）：把「可能挂起」编码进**声明/类型** ⇒ 暴露实现模型；且会连锁要求 `await` 表面 |
| N3 | **`Future[T]`** | 把「尚未完成的结果」提为**一等类型构造器** ⇒ 结果是用户必须显式 `await`/poll；而「何时 resume」本可由关系推导（D20）|
| N4 | **`Coroutine[T]`** | 同上，且更重：把 coroutine frame 的**存在**变成类型的一部分；而 frame 是否需要、存什么状态本可自动定（D15/D16）|
| N5 | **`GeneratorState`** | 把生成器的**内部状态机**摆到类型面上 ⇒ 直接暴露 realization；状态集应由编译器生成（照 D10「不暴露 closure object」的同侧纪律）|
| N6 | **`Suspend`** | 把「挂起能力」做成**标记/类型**（≈ `Fn`/`FnMut`/`FnOnce` 的反面教材）：块一已裁定 callable 类别**自动推导**，挂起面同理（D13）|
| N7 | **`FnAsync`** | 与 N6 同类，且是**第二套 callable 类别体系**的入口 ⇒ 违反块三「根本可以不建立第二套概念」（Callable trait 同判）|

---

## 五、表示方案（块四裁决）与后端 realization

| 层 | 内容 | 状态 |
|---|---|---|
| 语义 / CIR 类型层 | `fn(T...) -> R` = **统一 callable 类型**；callable = 可调用实体 + **可选** capture environment；**不规定**机器布局 | 不变量①②（原文）|
| 当前 CPU 后端 realization | 无 capture → `{code, 0}`；有 capture → `{code, env}`；**允许在证明 env 不需要时消除第二字** | 不变量②（原文）|
| 其它硬件（GPU / dataflow / …） | **不需要继承「两个机器字」这个假设** | 原文好处 4 |

> 原文列的好处（逐条）：① `fn(int) -> int` 永远只有一个类型，用户不用知道有没有 capture；② 无 capture lambda、
> `fn.name`、有 capture lambda 可互相赋值；③ 后端可把 `{code, 0}` 优化成裸 code，**但这只是优化，不影响类型**；
> ④ 将来 GPU / dataflow / 其他硬件不需要继承「两个机器字」；⑤ 不会因 callable representation 把经典 CPU 模型
> 重新塞进 Core 语义。

**写手展开（IR 值层承载，标注为本文建议，非原文）**：

- `TYP_FN` 行的槽只放**签名**（返回型 + 参数型），**不放** code/env 宽度（不变量②的直接推论）。
- 「两字」是当前后端的值层事实 ⇒ 承载方式应落在**值层/后端**，且**不得**回写进类型行；
  候选见 待裁 **T-1**（本文不替实现者选）。

---

## 六、capture 语义（附：**已确认、直接写死**的三件之一）

> **来源**：team-lead 提出、维护者以「ye」确认 ⇒ **不再当待裁**。

1. **capture 默认按引用**（与现有 region/borrow 一致）；
2. **环境放外层栈帧**；
3. **逃逸由 region 分析判定**；**判不了就报错**——不猜、**不偷偷堆分配**。

**写手展开（须与实现者对齐的两点，列为待裁 T-7）**：

- ① 「逃逸」这里的判定面**未必**等于现有 `RegionCheck` 的判定面：`RegionCheck` 的现状对象是
  **DEREF 目标是否在活子图**（`src/compiler/region_check.cr:1-3` 头注原文；接线 `main.cr:639`），
  而本条要判的是 **「一个含 env 的 callable 值是否逃出外层栈帧的活域」**——两者的判据形态不同。
  **本档未逐行核** `region_check.cr` 是否可承载（§十一 未核实项 U-3）。
- ② 与不变量①的相互作用：环境「可选」⇒ **无捕获 lambda 不需要环境** ⇒ 逃逸判定对它是恒假；
  实现者不得为统一而给无捕获 lambda 也造一个空 env（那会让 D9「无捕获简化」落空）。

---

## 七、诊断面（附：**已确认、直接写死**的三件之三）

> **原文（附确认 #3）**：「『无法推导』要有**新诊断码、单独一类**——它是『我们不知道，请你写』，
> **不是类型错**」。

**为什么必须单独一类（写手展开，含本仓机制证据）**：

1. 语义上它不是错误：代码没有错，只是**信息不足**（块一原文：「如果参数类型没有任何上下文可推，
   也应该报无法推导，而不是偷偷猜一个类型」）。把它塞进既有「类型错」族会让**下游工具与用户**都无法区分
   「你写错了」与「请补一个标注」。
2. **本仓机制面有一条独立的理由（`[已实现]` 事实）**：`error_cat_prefix(cat)` 的兜底是 `return "E"`
   （`src/compiler/diag.cr:104`）。**新增族而不补分支 ⇒ 静默印成 `E` 族**——按 `cat = ec / 1000`、
   `num = ec % 1000`、2 位补零（`diag.cr:133-137`）渲染，`18001` 会印成 **`error[E01]`**。
   这不是假设：兜底分支**不报错、不告警**。⇒ 新族必须**同批**补：`error_cat_prefix` 分支 +
   `ast.cr:311-328` 的类别注释表 + `docs/developer/errors.md` 的族节与统计表（`:302-329`，含「总计 150」
   与三种数法注）——**四处同改**（本仓既有纪律：修/加一类能力要同批清点引用面）。
   ⚠ 这四处**本身就有漂移史**（§1.2 的 D-5/D-7：`diag.cr` 的「唯一 raise 点」计数与行号、
   `errors.md` 的 `EC_*` 计数均已过期）⇒ 改的时候**现查现用**，别抄旧数。
3. **fail-closed 闸门面（`[已实现]`）**：新码必须在 `diag_gate_exempt`（`diag.cr:172`）的语义下有确定归属——
   要么有真 raise 点（默认阻断路径自然覆盖），要么按表内格式（位点/理由/退出条件三件）入豁免。
   牙 = `tests/selfhost/test_diag_gate.py`（挂 `selfhost-tests`，`src/ci/run.sh:176`）。

**候选（待裁 T-5）**：族号 **18**（1000 段未被占；现有最大族 = 17「V」）· 前缀字母建议 **`U`**（Unresolved）。
**本档不替维护者定字母与码值**——只落「必须有、且必须单独一类、且四处同改」这三条硬约束。

---

## 八、`.ccr` 影响面（**单独一节**）

> 本仓对「产物字节变化」有明确纪律。本节只讲**影响传导链**与**纪律**，**不声称实测结果**
> （本档零构建 ⇒ 见 §十一 U-4）。

### 8.1 传导链（机制事实，全部 `[已实现]`）

`TYPE(7)` 段体 = `[row_count u32][row_count × 24B {kind,data,extra}][term_count u32][term_count × 40B {tag,a,b,c,d}]`
（A28）——即 **`g_types` 内存行表原样** + 类型项 DAG。由此：

| 改动 | 是否动 `.ccr` 字节 | 依据 |
|---|---|---|
| 新增 `TYP_FN` **常量**（`ast.cr`） | **否**（常量不入段） | A7/A28 |
| 新增**建行点**且锁定语料上真建了行 | **是**：`+24B/行`（TYPE 段） | A28 |
| 同时建类型**项** | **是**：`+40B/项` | A28 |
| 新增 interned 串（新诊断文案若含新词/新名） | **是**：STR 段按 `4 + len` 增长/条 | `canary_values.tsv` 的 28B 先例（2 串 = 2×(4+len)）|
| **`init_types()` 里预建规范行** | **是**：**每一档** `.ccr` 都 +24B ⇒ **四条锁定值全变** | A10（占位先例）|
| 新 opcode **在锁定语料上发射** | **是**：NOD 段字节变 | A28/A14 |
| 新增 `AK_*` 原子 | **是**：IFACE 段 native 条目 +24B/条 | A29 |
| **只**给 `AK_FN` 用既有注册行（不新增原子） | **否**：`AK_FN` 已占第 15 行，`IFACE_ENTRY_COUNT = 16` 不变 | A17/A29 |

**⇒ 本档最重要的一条设计约束（写手展开）**：**不在 `init_types()` 里给 `TYP_FN` 预建规范行**
（A10 的 `TY_DEX_S` 占位先例是**允许**这么做的先例，但代价是全局足迹）。改成**按需建 + 同签名去重**
（A9 的 `TYP_NAMED` 先例）。

### 8.2 纪律（本仓既有，逐条带出处）

1. **零足迹纪律先例**：新增类型面查询**必须先核是否 `alloc_type`**——本仓已有一次因此使
   **非可选语料** `.ccr` **+168B** 的实测（优化-表示批报告 §3 的「新增类型面查询…首判门控」）。
2. **锁定值真源 = `tools/baseline/canary_values.tsv`**（A38），**不是**任何文档里的文字值；
   闸门 = `tools/baseline/canary_check.sh`（挂 `selfhost-tests` 内，`src/ci/run.sh:218`）。
3. **两级契约（不得写成「永远不该变」，也不得写成「随便变」）**：
   - **canary ELF** = **发射面零泄漏检测器** ⇒ 不应变；**变 = 越界 ⇒ 停下上报**（除非维护者显式声明发射面变更并同批重锁）；
   - **`.ccr` 四条** = **格式+内容形状检测器** ⇒ **值变 ≠ 必然回归**，但必须「**显式归因 + 同批重锁 + 旧值留痕**」；
     **无归因的变化 = 红**。「本闸门禁止的不是变化，是**无声变化**」。
4. **D1 确定性闸门（重锁前置，硬要求）**：重锁前必须先见 **D1 绿**（同一 canary ELF **两次构建逐字节相同**）——
   否则会把**非确定值**锁进表（此后全绿而产物每次都不同）。**D1 红 ⇒ 不得重锁**。
   **覆盖面 = 5 个条目全做**（ELF + `.ccr` 四条），不只是 ELF。
5. **环境归一化**：`.ccr` 四条中的 `gt` 两条 = **空 `HOME` 归一化后**的值（`canary_values.tsv` 头注：
   编译器解析 `import` 会读 `$HOME/.core/lib/<模块>/index`，命中则注册函数名进串表，实测 ±28B）。
   - **机制（当前修订实核）**：`src/compiler/module.cr:557-575`——索引读取**以 `HOME` 非空为前提**；
     索引缺席属「可选输入不存在」⇒ **静默降级到确定态**（不注册），而真正用到索引独有名字时仍**响亮失败**
     （查不到 ⇒ `-1` ⇒ `N06`）。
   - ⚠ **陈旧陈述（§1.2 的 D-6）**：`canary_values.tsv` 头注给的**理由**（「`module.cr:526` 有硬编码
     `/home/DslsDZC` 兜底，置空会去读原开发者家目录」）**已被第 4 批 #83 移除**，且该字面今日
     **被判据禁止**出现在 `src/` 内（J4）。
   - **纪律不变**：采集侧一律把 `HOME` 钉到采集目录内的**空 `home/`**（`canary_check.sh` 已如此做）。
     理由是**产物可复现**（锁定值必须能在别的机器上复现），**不再**是「防硬编码兜底」。
6. **覆盖域警告（本仓原话精神）**：「`.ccr` 没变 ≠ 生成面没变」**且**「`.ccr` 没变 ≠ 这个面被覆盖了」——
   两条合起来：**判据的「绿」只在它的覆盖域内有意义**。本档的覆盖域 = `tests/suite/ptr_arith.cr`
   + `tests/suite/generics_test.cr` **两档**（A38）⇒ 「两条语料没变」**不构成**「函数值面零足迹」的证明。

### 8.3 本档对第④段的**预期**（**预测，非实测**）

- **预期**：若实现遵守 8.1 末条（不预建规范行）且**两档锁定语料不含函数值用法**，则
  「**零函数值语料 ⇒ 零足迹**」成立 ⇒ canary 5 条 **IDENTICAL**，**不需重锁**。
- **若变**：按 8.2 第 3 条的 `.ccr` 契约办（归因 + D1 绿 + 重锁 + 旧值留痕），并**逐段定位**差分
  （本仓先例：差异可精确到「仅 STR 段」「仅 3 字节」这种粒度——段级定位是标准动作）。
- ⚠ **ELF canary 与 `.ccr` 的关系**：TYPE/IFACE 两段是**纯信息面、不参与 ELF 发射**
  （`docs/superpowers/specs/2026-09-09-lattice-ir-v7-format.md:193` 的原话「发射面零泄漏判据 = ELF canary 不变」）
  ⇒ **TYPE 段变而 ELF 不变是可能的**，反之（ELF 变）才是越界信号。

---

## 九、与既有设计/文档的关系（先例 · 冲突 · **须同批修订的陈述**）

| # | 既有件 | 关系 | 处置 |
|---|---|---|---|
| R1 | `docs/superpowers/specs/2026-08-30-type-system-direction-design.md:29`（第 11 条「函数类型隐式化」：…「函数值 = 子图引用（**`@addr` 机制已有**）」）| **与不变量③冲突**：新裁决明确「两者不能互相等价」，且「不要为了兼容它把新 callable 也定义成裸地址」 | **不得就地改写该件**（本档只新增）。登记为**须修订陈述**；修订措辞建议 = 「`@addr` 保留为 raw machine address（`int` 语义）；typed callable value 另立（`fn(T...)->R`）」——**待维护者裁（T-3）** |
| R2 | `TODO.md:426`（「…**函数值设计为 YAGNI 挂起** ⇒ 正确结局 = 定位拒绝 `P021`」）| **本档解除了「函数值」的挂起** ⇒ 该括号句成为**陈旧陈述**。⚠ 该句所在的**主结论不受影响**（嵌套 `fn` 声明仍不属语言面：`grammar/core.ebnf` 的 `Statement` 不含 `FunctionDecl`，`P021` 仍是正解）| 同批**只改括号句**（「函数值设计为 YAGNI 挂起」→ 指向本档），主结论与判据（`tests/selfhost/test_nested_fn.py`）**不动**。属「修了前置能力的批次必须同批清点把该缺口当现状写的陈述」纪律 |
| R3 | `docs/superpowers/specs/2026-08-30-…:41`「明确不做：HKTs（高阶泛型）」| **一致**（§4.3 的非目标旁证）| 无需改；本档引用为一致证据 |
| R4 | `docs/superpowers/plans/2026-09-20-safety-verification-plan.md:88-90`（CFI 前置缺失）| 段④是其**前置载体** | 段④ 落地后回头更新该件 §1.3/§4（**另一批**；本档登记义务）|
| R5 | `docs/superpowers/specs/2026-09-17-concurrency-model-design.md:390`、`:427`（`sched_go` 事实面）| **一致**（不变量④：并发接口自己的演进）| 无需改；其行号已漂移（§1.2）|
| R6 | 解引用/视图/类型引擎诸批（`TYP_OPTIONAL`/`TYP_NULL` 先例）| **方法先例**：新增行 kind 的完整接线面 = AST 常量 + 建行点 + 双构造点桥接 + `iface_kind_of` + selftest 重定 + `.ccr` 足迹 | 照此清单逐项落 |
| R7 | `flow` 作 **region kind** `SG_FLOW`（`dataflow.cr:533`）与作 **声明前缀** `FlowDecl`（`grammar/core.ebnf:22-24`；parser 另接受 `flow fn name()`，`parser.cr:1726-1748`）| **既有、与本轮正交**（不是类型面）| **不动**；但 §2.4 已写明「被否决的只是类型位」，防读者误读为 `flow` 被移除 |
| R8 | `flow`/`yield` 的**半实现**状态（`IR_YIELD = 28` 发射于 `ir_gen.cr:2878`，但后端 `sizes.cr:77` = 0 字节 no-op、`interp.cr:385` = eager 近似；语料 `tests/test_flow.cr` **无 runner 引用**）| **先于本轮的既存面**；不变量 5 的收缩**不清理也不扩大**它 | 登记为**待裁 T-10 / 未核实 U-11**（本档不改其语义）|
| R9 | `docs/superpowers/specs/2026-09-17-concurrency-model-design.md`（`go` 的 lowering 与事实面：单 M 协作、`sched_go` 只传 1 个 8 字节 arg、「今日无跨执行体值通道语义」）| 与不变量 5.1 的边界**同侧**（并发接口的判断独立保留，不许与 async/await 合并）| 无需改；引用为**边界依据** |

---

## 十、待裁清单（**T-1 … T-9**）

> 判定原则：**能从原文唯一推出的**已写死（§二/§五/§六/§七）；**需要维护者拍板**的在此列。
> 「附」里三件已确认的（capture 默认按引用 · `TYP_FN` 取空位 5 · 「无法推导」新码单独一类）**不在此列**。

| # | 待裁项 | 本文建议（写手展开，**非维护者判断**）| 影响面 |
|---|---|---|---|
| **T-1** | **IR 值层如何承载「第二字（env）」**：IR 变量是单 64 位槽（多字走 `tag2l` 的 M1 编码族）。候选：(甲) 值层新增「两槽值」类别；(乙) 复用多字 int 编码把 `{code,env}` 打包（类型仍是 `TYP_FN`，布局只是值层事实）；(丙) IR 层引入隐式 product `(code, env)` 但不写进类型语义 | **本档不选**。**硬约束**：无论选哪个，`TYP_FN` 行的槽**只放签名**（不变量②）| 段③④ 的 ir_gen + 后端 + `.cir`/`.ccr` 足迹 |
| **T-2** | `TYP_FN` 行的**槽分配**：`{kind,data,extra}` 三槽不够放「参数列表 + 返回型」。候选：(甲) 照 `TYP_TUPLE` 先例（`data` = 计数、`extra` = `g_gen_apply_data` 起点）；(乙) `data` = 返回型、参数列表走侧表 | 建议 (甲)（既有先例、零新机制），且**返回型在链首**与 A18 的 `sh_func_sig_term` 保持同序 | TYPE 段字节、桥接链序 |
| **T-3** | R1 的修订措辞（`2026-08-30` 第 11 条）| 见 R1 行 | 文档一致性 |
| **T-4** | `fn.name` 对**泛型函数**/方法/`self` 方法是否支持 | 建议：本轮**只支持非泛型顶层函数**；`fn.Type::method` / `fn.obj.method` 列为**非目标**（块二原文只给 `fn.NAME`）| 段② |
| **T-5** | 新诊断族的**族号/前缀字母**（+ 是否新增族 vs 并入 I 族）| 建议族 18、前缀 `U`（Unresolved）；**硬约束**：无论取什么，四处同改（§七）| 段③ + 诊断面 |
| **T-6** | 新间接调用 opcode 的**编号与槽序**：号取 `IR_*` 的 40 或 ≥52；槽序须在 `IR_CALL`（`s1=first_arg,s2=count,s3=fn_ni`）与 `IR_CALL_EXTERN`（`s1=fn_ni,s2=first_arg,s3=count`）之间**明选一种**（两者现状不一致）| 建议号取 **52**（不占用历史空缺 40，避免与「已退役 opcode」误认）；槽序建议 `s1=callable_var, s2=first_arg, s3=arg_count` | 段④ + 全部分析面 |
| **T-7** | 段③逃逸判定的**落点 pass**：`region_check.cr` 能否承载「callable 值逃出外层栈帧」判定（其现状对象 = DEREF 目标在活子图）| **本档未核**（U-3）⇒ 需一次针对性复核后再定 | 段③ 判据面 |
| **T-8** | `FunctionType` 的**结合性与组合规则**：`fn(int) -> fn(int) -> int` 结合方向；裸形 `fn(int) -> int?` 是否一律要求括号 | 建议：`->` **右结合**；组合（`?`/`[...]`/元组）**必须加括号**（与原文用例的写法一致）| 文法 + parser |
| **T-9** | D8 静态化的**判据形态**：是否需要「强制动态」开关以证明「两态行为相同」 | 建议需要（否则 D8 无法被判据覆盖；只测一态无法区分「静态化正确」与「动态化正确」）| 段④ 判据 |
| **T-10** | **`flow` 声明面在新体系下的类型身份**：`flow counter()` 的函数**类型**是什么？被 `fn.counter` 取用时（段②）得到什么类型？现状 `checker.cr:2310-2313` 对 flow 函数**跳过返回型检查**、`checker.cr:3443`「In a flow, the yield type is the flow's result type」⇒ 类型位语义**未定** | **本档不选**。可选：(甲) flow 函数的类型 = `fn(T...) -> R`（`R` = yield 型）⇒ 与不变量 1 一致，`fn.counter` 可用；(乙) flow 函数**不可**作 callable value（段② 拒绝 `fn.counter`）。**维护者裁**（与不变量 5.1 的「`go` 归属」相邻，但**是另一问**：那问是语义归属，这问是类型身份）| 段② + §2.4 义② |
| **T-11** | `flow fn name(...)`（parser 接受）与 `flow name(...)`（grammar 形、语料实形）两种拼写的**规范形**：grammar `:22` 只写 `'flow' IDENT`；per-parser 两者皆通；语料只用后者 | 建议：**规范形 = `flow name(...)`**（与 grammar 一致）；`flow fn name(...)` 按本仓 fail-closed 纪律**要么升级为规范形并同时补 grammar，要么响亮拒绝**——**不得**保持「两者皆通而 grammar 只写一个」 | §2.4 义② + 文法一致性 |

---

## 十一、未核实清单（**优先级最高的一节**）

> 本档**零构建、零实跑**（任务限定）；下表列出**所有**未由本档实核的断言。

| # | 未核实项 | 为什么没核 | 若要核，怎么核 |
|---|---|---|---|
| **U-1** | **一切"实跑行为"**：`fn.square` / `fn(x:int)=>x*2` / `fn.nope` 在当前编译器上到底报什么码、是否崩 | ① 本档零构建；② 仓内 `/home/DslsDZC/core/build/corec` 时间戳 = **2026-09-16 04:54**，**落后 `develop@origin`（2026-09-23）7 天** ⇒ 其行为**不构成**对当前修订的证据。本档所有「现状下无此产生式」结论均为 **`grammar/core.ebnf` + `Primary` 候选表**的**结构化推导**（`fn` 是关键字、不在 `Primary` 的 `IDENT` 面）| 在 `develop@origin` 上构建后，对各形跑 `check`/`build`，记 rc + 码 + 零产物 |
| **U-2** | 裸函数名（**不带 `fn.`**）作表达式的当前行为（`f := square;`）| 未逐行核 `EXPR_IDENT` 的 `find_sym`→`sym_type` 对 `SYM_FN` 这一路的取值（`checker.cr:2810-2822` 只读到"有符号即返回其型"这一层）| 读 `sym_type` 对 `SYM_FN` 的写入点，或实跑一例 |
| **U-3** | `region_check.cr` 的判定面能否承载 T-7 的「callable 逃逸」 | 本档只核了头注与接线（A42），**未逐行读**其判定对象与实现 | 读该文件判定对象 + 与「值逃逸」的差异 |
| **U-4** | `.ccr` 四条锁定值的**实际**变化（§8.3 是**预测**）| 零构建 ⇒ 无 pre/post 产物 | 实拍 pre/post + D1 + 段级定位 |
| **U-5** | `IR_DYN_DISPATCH` 的 pts/CFI 关系（段④可能要与它合并或并行）| 未读 `ptr_analysis.cr` 对它的处理；`2026-09-20-safety-verification-plan.md:90` 明确 `@addr` 的 int 值**不进 pts** | 读 `ptr_analysis.cr` 的约束求解面 |
| **U-6** | `2026-09-17-concurrency-model-design.md` 全文与不变量④是否**逐句**相容 | 只核了 `sched_go` 相关的 4 行（`:235`/`:390`/`:427`/`:435`/`:640`）| 全文对读 |
| **U-7** | 段④ 是否需要 bump `CIR_CACHE_VER`（新 opcode 是否影响 `.cir` 记录面）| 当前值已核 = **22**（A36）；但「新 opcode 的项派生是否覆盖」需读 `cir_cache.cr` 的落盘槽与 `sh_tk_term_of_code` 家族 | 读 `cir_cache.cr` 槽布局 + 项派生表 |
| **U-8** | 是否有**其它工作区/分支**已在做函数值（防撞车） | 本档只在自己的工作区核 `develop@origin` | `jj bookmark list --all-remotes` + 各工作区 `@` 的描述扫一遍 |
| **U-9** | `@addr` 是否有**第三个**语义站点（除 `checker.cr:4190` / `ir_gen.cr:2144` 之外）| 已全仓 grep `"addr"` 字面量，命中 3 处（含 `ir_gen.cr:1831` 的 `&x` 路径变量命名，语义无关）⇒ 判定为 2 处语义站点 | 复核 `@raw_int`/`@ptr_of`/`@str_of` 家族是否有同类站点——**已核**：三者的 `TF07` raise 点 = `checker.cr:4265`/`:4334`/`:4340`（§1.2 D-5）|
| **U-10** | §1.2 的七条陈旧陈述是否已有人登记（避免重复登记/撞车）| 本档只在 `develop@origin` 上核了**陈述本身**，未查 TODO.md / 各工作区是否已有同项登记 | 查 `TODO.md` 与各工作区 `@` 描述 |
| **U-11** | `flow`/`yield` 的**实跑**状态（`tests/test_flow.cr` 是否 `check`/`build`/`run` 三面 rc=0；`go counter()` 是否真跑得动）| 零构建（U-1 同因）；且该语料**无 runner 引用**（已 grep：仅一份报告提到它）⇒ 现状 = **无 CI 挂点** | 构建后跑三面 + 记 rc/产物；若确认可用，**同批补挂点**（否则它是「不进门的语料」）|
| **U-12** | 不变量 5.1 里「`a(); b();` 可由 dependency / state relation 判断并优化」的**实现面**：现状是否已有任何自动并行/合并的实现或判据 | 本档只核了 state 链的**分类表**（`checker.cr:4533-4546` + `dataflow.cr:156 df_connect_state`）与 merge-semantics 设计件，**未核实现**（不构建、不读全 `opt.cr`）| 读 `opt.cr`/`dataflow.cr` 的合并面 + `2026-09-11-merge-semantics-design.md` 的实现状态节 |
| **U-13** | 「异步 realization 自动推导」的 12 项（D13–D24）需要哪些**前置载体**（scheduler 绑定 / continuation 表示 / frame 布局是否已有承载）| 本档未核（只核了 `IR_YIELD`/`IR_SPAWN`/`IR_AWAIT` 三个 opcode 的现状与 `sched_go` 接口）| 读 `2026-09-17-concurrency-model-design.md` 的「前置载体」节 + `src/stdlib/scheduler.cr` |

---

## 十二、锚点速查（file:line，全部在 `develop@origin = 6b54107e`）

```
grammar/core.ebnf:12-14     FunctionDecl（已有）        :38 Type 候选表
grammar/core.ebnf:41/44/45/46/47/48/49   Base/Path/Ref/Optional/Tuple/Array/SliceType
grammar/core.ebnf:64        CallOrField（'(' 已通用）   :65 Primary 候选表
src/compiler/lexer.cr:72    T_FN 关键字
src/compiler/ast.cr:10      T_FN = 5   :534-540 SYM_*（SYM_FN=0）
src/compiler/ast.cr:291-309 TYP_* 全表（5/6 空）  :284-288 占位先例注
src/compiler/ast.cr:554-604 IR_* 号段（IR_CALL=4 :558 · IR_CALL_EXTERN=45 :598 ·
                            IR_FNADDR=48 :601 · IR_DYN_DISPATCH=44 :597 · IR_APPROX=51 :604）
src/compiler/ast.cr:311-328 错误码族注释表（17 族）
src/compiler/ast.cr:70-71    T_FLOW = 66 · T_YIELD = 67（flow/yield 关键字码）
src/compiler/lexer.cr:94-95  "flow" / "yield" 关键字
src/compiler/checker.cr:10-18   alloc_type（裸分配器）
src/compiler/checker.cr:20-33   TYP_NAMED 建表去重先例
src/compiler/checker.cr:231/248-260  init_types（8 原生行 + 1 占位行）
src/compiler/checker.cr:299     bi_add("sched_go", TI_INT)
src/compiler/checker.cr:971     res_type_node
src/compiler/checker.cr:2810-2822 EXPR_IDENT 推断   :2993 EXPR_CALL 推断   :3297 EC_N_FUNC
src/compiler/checker.cr:4190-4191  @addr → TI_INT
src/compiler/checker.cr:4265/4334/4340  EC_TF_ARG_TYPE 三 raise 点（@raw_int/@ptr_of/@str_of）
src/compiler/checker.cr:4533-4546  purity_op_effect
src/compiler/ir_gen.cr:1921    IR_FNADDR（go 路径）  :1933-1934 IR_CALL sched_go
src/compiler/ir_gen.cr:2144-2149 @addr → IR_FNADDR   :2358 IR_CALL_EXTERN   :2377 IR_CALL
src/compiler/parser.cr:41      parse_type()
src/compiler/ty_shadow.cr:321  sh_term_of_ti（兜底 :378-382）  :880 sh_sig_term_of_ti
src/compiler/ty_shadow.cr:1042 sh_func_sig_term（入参 = 函数下标）  :1057 AK_FN 项构造
src/compiler/type_engine.cr:29 AK_FN = 13   :38 AK_NULL = 15
src/compiler/iface_registry.cr:158  AK_FN 注册行（第 15 行）
src/compiler/iface_axis.cr:196-210  iface_kind_of（兜底 :209）
src/compiler/dyn_arr.cr:215    IFACE_ENTRY_COUNT = 16
src/compiler/type_selftest.cr:1603/1609/1612/1629 AK_FN 条目断言
src/compiler/type_selftest.cr:1635-1646 ts_ccr2_kind_domain_ok（有意闸，:1642）
src/compiler/type_selftest.cr:2744-2745 ops.entry_row_consistent（零 ops 恰 3 行）
src/compiler/diag.cr:86-105    error_cat_prefix（兜底 "E" :104）
src/compiler/diag.cr:123/133-137 print_diagnostics / cat·num 渲染
src/compiler/diag.cr:172       diag_gate_exempt（:184/:188 的理由文本陈旧 + 重复两条，见 §1.2 D-5）
src/compiler/ccr_io.cr:135/138-139  CCR_VERSION=9 / 段表 8 段 / TYPE=7
src/compiler/ccr_io.cr:601/896  TYPE 段写侧   :1534-1584 读侧
src/compiler/ccr_types.cr:9-14  TYPE 段体结构   :197/211-217 IFACE 原生条目
src/compiler/cir_cache.cr:135   CIR_CACHE_VER = 22
src/compiler/module.cr:557-575  $HOME 索引读取（硬编码兜底已移除，见 §1.2 D-6）
src/compiler/dataflow.cr:156    df_connect_state   :307/:402 use 面   :638-639 opcode→名
src/compiler/dataflow.cr:533    SG_FLOW → DOT 名 "flow"（region 三义之①）
src/compiler/parser.cr:1726-1748 flow fn name() 拼写（is_flow 置位；checker 按 body 内 yield 处理）
src/compiler/checker.cr:2310-2313 scan_for_yield → is_flow_fn（跳过返回型检查）  :3443 flow 的 yield 型 = 结果型
src/compiler/ir_gen.cr:2878    emit(IR_YIELD, -1, val_var, …)   ast.cr:583 IR_YIELD = 28
src/compiler/ir_gen.cr:1958    emit(IR_SPAWN, …)（range-go）  :2887 emit(IR_AWAIT, …)
src/compiler/ast.cr:582-584    IR_SPAWN = 27 · IR_YIELD = 28 · IR_AWAIT = 29
src/arch/x86_64/sizes.cr:77    IR_YIELD = 0 字节「no-op (for now)」  interp.cr:385「eager 值传递近似」
tests/test_flow.cr             flow counter() + yield + go counter()（**无 runner 引用**）
src/compiler/interp.cr:406-411/736-741  未支持 op 响亮报错
src/compiler/opt.cr:271-275     跳过模式
src/compiler/region_check.cr:1-3 判定面（DEREF 目标在活子图）  main.cr:639 接线
src/arch/x86_64/instr.cr:754 IR_CALL   :906 IR_CALL_EXTERN   :971 IR_FNADDR   :1523 IR_DYN_DISPATCH
src/arch/x86_64/sizes.cr:78/80/84
src/arch/x86_64/regalloc.cr:448/453
src/os/linux/callseq.cr:39-60   SysV 分派三处同源
src/format/elf/elf.cr:1305/1353 IR_FNADDR 链接期回填
src/lattice/ent_kernel.cr:271/350/366
src/stdlib/sched.cr:171          sched_go(fn_ptr: int, arg: int) -> string
src/ci/run.sh:70-71/76/114/218/345/350  五 job + canary 挂点
tools/baseline/canary_values.tsv · tools/baseline/canary_check.sh:35-59
TODO.md:426                       「函数值设计为 YAGNI 挂起」（陈旧陈述）
docs/superpowers/specs/2026-08-30-type-system-direction-design.md:29/41
docs/superpowers/specs/2026-09-09-lattice-ir-v7-format.md:193（TYPE/IFACE 不参与 ELF 发射）
docs/superpowers/specs/2026-09-17-concurrency-model-design.md:390/427/435/640
docs/superpowers/plans/2026-09-20-safety-verification-plan.md:88-90/114/176/276
docs/developer/errors.md:302-329  统计表 + 三种数法注
```
