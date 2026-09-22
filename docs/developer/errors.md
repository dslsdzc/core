# Core 错误码参考

> 定位:受众 = 开发者;状态 = active。
> 出处:错误码数值与注释名 = src/compiler/ast.cr 的 EC_* 常量(每码唯一检查点,注释带本文编号,如 `EC_P_EXPECTED = 1001 // P001`);**词法族(L 族)例外**——lexer.cr 的 add_error 只传消息文本不带码,L 码为本文档侧编号,以消息文本为准。改码须同步 ast.cr 注释与本文。

> **fail-closed 语义（2026-09-15，FC 批 T2 起）**：**默认阻断**——任何**不在豁免登记表**内的
> 类型面诊断 ⇒ `rc=1` + **零产物**（不落目标 ELF、不落本次 `<out>.ccr`）。豁免表 =
> `src/compiler/diag.cr::diag_gate_exempt`（码级 **8** 条：TF07 · TB01 · TM04 · TK01 · B04
> [build 面] + N01 · N06 · N11 [check 面，仅登记]；每条带位点证据/理由/退出条件，**只减不增**）。
> **TF01 已撤条（2026-09-18，批 8 A₂）**：真因 = `alloc: () -> string` 模型 vs 三处 handle 返回型 `-> int`
> （`chan_make` / `g_new` / `sched_go`）⇒ 按 (A) 对齐语料（+ 5 处 handle 形参）后 5 档并发语料不再产 TF01。
> 语法面（P/L 族）与安全检查面（B11/TU03…）本就「任一即 rc=1」；`check` 面的 rc 规则
> （计数 > 0）不消费豁免表 ⇒ check 基线不换代（裁-FC-1 = (C)）。

---

## L0xx — 词法 (Lexer)

> 注:本族码无数值常量(lexer add_error 不带码)——以消息模板为准,码为文档侧编号。

| 码 | 检查点 | 消息模板 | 触发条件 |
|----|--------|---------|---------|
| L001 | 字符串终止 | `Unterminated string literal` | 引号未闭合就到行尾 |
| L002 | 块注释终止 | `Unterminated block comment` | `/*` 未闭合就到文件尾 |
| L003 | 转义序列 | `Invalid escape sequence: \{c}` | `\` 后跟了非法字符 |
| L004 | 字符字面量空 | `Empty character literal` | `''` |
| L005 | 字符字面量多字节 | `Multi-character character literal` | `'ab'` |
| L006 | 十六进制转义 | `Invalid hex escape: {seq}` | `\x` 后不是合法十六进制 |
| L007 | 整数后缀非法 | `Invalid integer suffix: {suffix}` | `42_xyz` 之类 |
| L008 | 整数后缀溢出 | `Integer literal out of range for suffix {suffix}` | `999999_i8` |
| L009 | 小数（dex）字面量格式 | `Invalid float literal`（消息文本随代码迁移改 dex 表述） | `1.` 或 `.e5` 等 |
| L010 | 小数后缀非法（f32/f64 = apx 的 CPU 位宽标注） | `Invalid float suffix: {suffix}` | 非 f32/f64 后缀 |
| L011 | 无法识别的字符 | `Unknown character: '{c}'` | 源码中出现 ASCII 控制字符或全角空格等 |

## P0xx — 语法 (Parser)

| 码 | 检查点 | 消息模板 |
|----|--------|---------|
| P001 | 期望 token 不匹配 | `Expected {X}, got {Y}` |
| P002 | 顶层意外 token | `Unexpected token {X} at top level` |
| P003 | 表达式内意外 token | `Unexpected token in expression` |
| P004 | 数组大小非编译期常量 | `Expected integer literal or constant name for array size` |
| P005 | 模式内意外 token | `Unexpected token in pattern` |
| P006 | 缺少闭合括号 | `Missing closing delimiter: expected {X}` |
| P007 | 缺少分号 | `Expected semicolon after {stmt}` |
| P008 | 结构体体为空 | `Empty struct body` |
| P009 | 枚举体为空 | `Empty enum body` |
| P010 | 函数体为空 | `Function body is empty` |
| P011 | 参数缺少类型标注 | `Parameter {name} requires type annotation` |
| P012 | 泛型列表语法 | `Invalid generic parameter list` |
| P013 | 结构体字段/值配对错误 | `Invalid field syntax in struct literal` |
| P014 | match 体为空 | `Match body cannot be empty` |
| P015 | 绑定模式格式 | `Invalid pattern binding` |
| P016 | import 路径格式 | `Invalid import path` |
| P017 | fileid 声明格式 | `Invalid fileid declaration` |
| P018 | 变量声明语法 | `Invalid variable declaration syntax` |
| P019 | 字面量后缀溢出 | `Numeric literal overflow` |
| P020 | 形参数目超上限（> `MAX_FN_PARAMS=64`） | `too many parameters`（TODO #2026-09-10-4 修复：修复前 ≥18 形参静默误编译——写入超出参数槽区、覆盖 return_type/ast_node） |
| P021 | 函数体内嵌套 `fn` 声明（不属语言面） | 定位拒绝（TODO #2026-09-10-12 修复：修复前 parse 失步 → bump allocator 耗尽 → `rep movsb` 向 NULL 拷 → rc=139） |
| P022 | 枚举变体数 / 变体载荷类型数超上限（> `MAX_ENUM_VARIANTS=16` / `MAX_VARIANT_TYPES=16`） | `Enum has too many variants (17 > 16)` / `Enum variant has too many payload types (17 > 16)`（TODO #2026-09-12-2 修复：修复前写入侧**无界**——第 17 变体槽起点 = `variant_count` 自身、槽尾超出记录尾 224B，写入无任何诊断） |
| P023 | 结构体字段数超上限（> `MAX_STRUCT_FIELDS=16`） | `Struct has too many fields (17 > 16)`（TODO #2026-09-12-2 同族：第 17 字段踩 `OFF_SI_FIELD_COUNT`/泛型槽与邻记录；修复前 check rc=0 零诊断） |
| P024 | `extern` 声明含**可选**（`?`）——形参或返回（C ABI 无可选表示） | `extern declaration cannot use optional type ('?') - no C ABI representation`（常量 `EC_P_EXTERN_OPTIONAL = 1024`（`ast.cr`）· 检查点 = `parser.cr` 的 extern 分支：**形参与返回同判同码**；修复前 check rc=0 零诊断、`build` rc=0、运行期 139） |
| P025 | **无法识别的顶层 token**（顶层兜底不再静默吞） | `unexpected top-level token '{tok}'`（常量 `EC_P_TOPLEVEL_TOKEN = 1025` · 检查点 = `parser.cr` 的 `parse_declaration` 尾兜底：**报错后仍消费该 token**（避免 `parse_all` 空转），**EOF 不报**；修复前该 token 被无声吞掉 ⇒ 声明被无声丢弃 / 后续误归 `error[TF01]`） |
| P026 | `apx` 标签**不适用于**该声明（白名单 = **显式 `dex`** / **显式 `int`**） | `'apx' tag is only allowed on an explicit 'dex' or 'int' declaration`（常量 `EC_P_APX_TAG = 1026` · 检查点 = `parser.cr` 的声明标签分支；修复前为**静默忽略**——`. + apx` / `auto` / `dex?` / `string` / `bool` + `apx` 的标签被吞、零诊断） |

> **打印形**：上表三位族号（P024/P025/P026）供文档索引；实际输出为 `error[P24]` / `error[P25]` / `error[P26]`
> （打印器取 `码 % 1000`）。三者均属**语法族（P 族）** ⇒ 按本文件开头的 fail-closed 语义：**前端任一即 `rc=1` + 零产物**
> （不进入 lower / 不写 `.ccr` / 不产 ELF）。出处（本轮实读，`develop` = `662ff87d`）：`ast.cr` 常量三行 + `parser.cr` 三处 `check_error` 调用点。

## N0xx — 名字解析 (Name Resolution)

| 码 | 检查点 | 消息模板 |
|----|--------|---------|
| N001 | 名称未定义 | `Undefined name '{name}'` |
| N002 | 结构体未定义 | `Undefined struct '{name}'` |
| N003 | 字段不存在于结构体 | `Undefined field '{name}' in struct {struct}` |
| N004 | 枚举构造器未定义 | `Undefined enum constructor '{name}'` |
| N005 | 枚举变体不存在 | `Undefined variant '{name}' in enum {enum}` |
| N006 | 函数未定义 | `Undefined function '{name}'` |
| N007 | 类型名未定义 | `Undefined type '{name}'` |
| N008 | 方法不存在于类型 | `Undefined method '{name}' for type {type}` |
| N009 | 泛型实例化类型找不到 | `Undefined type in generic application` |
| N010 | 泛型参数未定义 | `Undefined generic parameter '{name}'` |
| N011 | 同一作用域重复定义 | `Duplicate definition of '{name}'` |
| N012 | 结构体字段重复定义 | `Duplicate field '{field}' in struct {struct}` |
| N013 | 枚举变体重复定义 | `Duplicate variant '{variant}' in enum {enum}` |
| N014 | 函数重复定义 | `Duplicate function definition '{name}'` |
| N015 | 文件标识符冲突 | `File identifier '{id}' already in use` |
| N016 | 模块路径未定义 | `Undefined module '{path}'` |
| N017 | 外部项目未定义 | `Undefined project '{name}'` |
| N018 | 导入循环 | `Cyclic import detected: {path}` |
| N019 | import 文件未找到 | `Cannot find file for import '{id}'` |
| N020 | 导入文件读取失败 | `Failed to read import '{id}'` |
| N021 | 符号重导出冲突 | `Name '{name}' re-exported from multiple modules` |

## I0xx — 类型推断 (Inference)

| 码 | 检查点 | 消息模板 |
|----|--------|---------|
| I001 | 变量类型无法推导 | `Cannot infer type of variable '{name}'` |
| I002 | 全局变量类型无法推导 | `Cannot infer type of global '{name}'` |
| I003 | 函数返回类型无法推导 | `Cannot infer return type of function '{name}'` |
| I004 | 泛型参数类型无法推导 | `Cannot infer type for generic parameter '{name}'` |
| I005 | 类型歧义 | `Ambiguous type: {expr} could be more than one type` |
| I006 | 无限类型 | `Infinite type: type {T} contains itself` |

## TA0xx — 类型检查：赋值与绑定

> TA02 自 2026-09-13（R2 P5 Task 6 / TODO #2026-09-11-14）起**实现**并列入 run_frontend 硬错误名单
> （rc=1 且不产出产物）：修复前 `EXPR_LET` 站点**无任何兼容检查**（符号取注解行、后端按注解
> 行发射 = 静默错产物；`EC_TA_DECL` 定义零 raise）。判定点 = `checker.cr::check_let_annot_compat`
> （局部 `EXPR_LET` + 全局 `check_global_let` 两调用点共用），组合函数 = `type_compat_strict`
> （身份 + 常量档长度 + 可选目标注入）。豁免：无注解/auto/无初值 · 注解 `dyn` · 值 `never`
> （底部 + 错误标记=级联抑制）· 注解为泛型形参。report-only 全语料零命中后开门。

| 码 | 检查点 | 消息模板 |
|----|--------|---------|
| TA01 | 赋值号类型不匹配 | `Cannot assign {T2} to {T1}` |
| TA02 | 变量声明类型与初始值不符（**2026-09-13 R2 P5 Task 6 起实现**：`EXPR_LET` 判定点——局部与全局初始化器共用；`-1` 分支 = 常量档数组长度约束，措辞同 TS03/TK02） | `Variable declared as {T1}, got {T2}` / `Array length constraint not satisfied` |
| TA03 | 批量声明类型不一致 | `Batch declaration has mixed types: {T1} vs {T2}` |
| TA04 | 赋值给不可变变量 | `Cannot assign to immutable variable '{name}'` |
| TA05 | 变量未声明 mutable | `Variable '{name}' is not mutable` |
| TA06 | 全局变量未声明 mutable | `Global '{name}' must be `mut` to reassign` |
| TA07 | 元组解构数量不匹配 | `Tuple destructuring has {M} variables but tuple has {N} elements` |
| TA08 | 未知声明标签 | `unknown declaration tag '{tag}'`（已知：mut/pub/apx + 插件标签） |

## TF0xx — 类型检查：函数与调用

| 码 | 检查点 | 消息模板 |
|----|--------|---------|
| TF01 | 返回值类型不匹配 | `Expected return type {T1}, got {T2}` |
| TF02 | 缺少返回值 | `Missing return expression; expected {T}` |
| TF03 | 多余返回值 | `Expected return type unit, got value` |
| TF04 | 多返回值中类型不一致 | `Return values in different branches have different types` |
| TF05 | 实参个数少于形参 | `Expected {N} arguments, got {M}` |
| TF06 | 实参个数多于形参 | `Too many arguments: expected {N}, got {M}` |
| TF07 | 第 N 个实参类型不匹配 | `Argument {N}: expected {T1}, got {T2}` |
| TF08 | 方法不存在于类型 | `Method '{name}' not found for type {T}` |
| TF09 | 方法参数个数不匹配 | `Expected {N} arguments for method '{name}', got {M}` |
| TF10 | 方法参数类型不匹配 | `Argument {N} of method '{name}': expected {T1}, got {T2}` |
| TF11 | 方法调用于非结构体 | `Method call on non-struct type {T}` |
| TF12 | 缺少 main 函数 | `No `main` function found` |
| TF13 | main 函数签名错误 | ``main` function must return `int` or `unit`` |
| TF14 | self 参数格式非法 | `Invalid `self` parameter type` |
| TF15 | 方法需要 self 参数 | `Method '{name}' requires a `self` parameter` |
| TF16 | 函数调用名未定义 | `Cannot find function '{name}' in scope` |
| TF17 | 函数名歧义 | `Ambiguous function call: multiple candidates for '{name}'` |

## TB0xx — 类型检查：二元运算

| 码 | 检查点 | 消息模板 |
|----|--------|---------|
| TB01 | `+` 左右类型不兼容 | `Cannot add {T1} and {T2}` |
| TB02 | `-` 左右类型不兼容 | `Cannot subtract {T2} from {T1}` |
| TB03 | `*` 左右类型不兼容 | `Cannot multiply {T1} and {T2}` |
| TB04 | `/` 左右类型不兼容 | `Cannot divide {T2} by {T1}` |
| TB05 | `%` 左右类型不兼容 | `Cannot mod {T1} by {T2}` |
| TB06 | `==`/`!=` 左右类型不兼容 | `Cannot compare {T1} and {T2}` |
| TB07 | `<`/`>`/`<=`/`>=` 左右类型不兼容 | `Cannot order {T1} and {T2}` |
| TB08 | `&&`/`||` 操作数不是 bool | ``&&` requires `bool` operands, got {T}` |
| TB09 | `+` 字符串与非字符串混用 | `Cannot concatenate string and {T}` |

## TU0xx — 类型检查：一元运算

| 码 | 检查点 | 消息模板 |
|----|--------|---------|
| TU01 | `-` 取负于非数值类型 | `Cannot negate type {T}` |
| TU02 | `!` 非 bool 类型 | ``!` requires `bool`, got {T}` |
| TU03 | `*` 解引用于非引用 | `Cannot dereference non-reference type {T}` |

## TC0xx — 类型检查：控制流

| 码 | 检查点 | 消息模板 |
|----|--------|---------|
| TC01 | if 条件不是 bool | `If condition must be `bool`, got {T}` |
| TC02 | if/else 分支类型不一致（**2026-09-14 起带「else 支发散」豁免**：`EXPR_RETURN` 推断 = 所返回值类型 ⇒ `{ return X; }` 支的「类型」是幻影，而 if 的值类型定义为 `then_ti` ⇒ **else 支确定发散时不判**；判定谓词 = `stmt_diverges`（checker.cr，**只服务本判定点**）。**不对称是有意的**：then 支发散时 `then_ti` 本身即幻影（模型面）⇒ 仍报，保留真信号） | `If branches have different types: {T1} vs {T2}` |
| TC03 | if 单分支不能有返回值 | `If without `else` cannot return value` |
| TC04 | while 条件不是 bool | `While condition must be `bool`, got {T}` |
| TC05 | loop 内 break 带值不一致 | ``break` with value conflicts with previous `break` without value` |
| TC06 | break 在循环外 | ``break` outside of loop` |
| TC07 | continue 在循环外 | ```continue` outside of loop` |

## TM0xx — 类型检查：Match/模式匹配

| 码 | 检查点 | 消息模板 |
|----|--------|---------|
| TM01 | match 目标不是枚举 | `Match expression must be enum, got {T}` |
| TM02 | 分支类型不一致 | `Match arms have different types: {T1} vs {T2}` |
| TM03 | 非穷尽匹配 | `Non-exhaustive match: missing variant(s): {names}` |
| TM04 | 冗余分支 | `Redundant arm: variant '{name}' already matched above` |
| TM05 | 通配符前置 | `Wildcard `_` arm must be the last arm` |
| TM06 | 枚举构造参数个数不匹配 | `Expected {N} arguments for variant '{name}', got {M}` |
| TM07 | 枚举构造参数类型不匹配 | `Argument {N}: expected {T1}, got {T2}` |
| TM08 | 模式绑定冲突 | `Binding '{name}' appears more than once in the same arm` |
| TM09 | 模式中非法嵌套 | `Complex pattern not allowed in this position` |

## TK0xx — 类型检查：数组与切片

| 码 | 检查点 | 消息模板 |
|----|--------|---------|
| TK01 | 下标索引非数组 | `Cannot index type {T}` |
| TK02 | 数组元素类型不一致（2026-09-11 TODO #2026-09-11-11 起字面量处**实现**：元素类型取首元素，后续逐个比对；硬错误） | `Expected array element type {T1}, got {T2}` |
| TK03 | 数组大小不是整数 | `Array size must be `int`` |
| TK04 | 数组大小为负数 | `Array size must be positive, got {size}` |
| TK05 | 切片起点超出范围 | `Slice start {N} is out of bounds (length {L})` |
| TK06 | 切片长度非法 | `Slice length must be non-negative` |
| TK07 | `for` 迭代目标不是数组或范围 | `Cannot iterate over type {T}` |
| TK08 | `for` 迭代变量与元素类型不匹配 | ``for` variable type {T1} does not match element type {T2}` |

## TS0xx — 类型检查：结构体字面量

> 四码自 2026-09-11（TODO #2026-09-11-11）起**全部实现**并列入 run_frontend 硬错误名单（rc=1 且不产出
> 产物）：修复前字段名被丢弃（值按声明位序绑定 = 静默错值），四校验均不存在。字段值现按
> **名字**绑定（与 Python bootstrap 的 gen_struct_lit 同语义；求值顺序仍为源序）。

| 码 | 检查点 | 消息模板 |
|----|--------|---------|
| TS01 | 缺少必要字段 | `Missing field '{name}' in struct literal {struct}` |
| TS02 | 不存在的字段 | `Unknown field '{name}' in struct literal {struct}` |
| TS03 | 字段类型不匹配 | `Field '{name}': expected {T1}, got {T2}` |
| TS04 | 字段重复初始化 | `Field '{name}' initialized more than once` |

## TG0xx — 类型检查：泛型

| 码 | 检查点 | 消息模板 |
|----|--------|---------|
| TG01 | 泛型实参个数不匹配 | `Expected {N} generic arguments, got {M}` |
| TG02 | 泛型参数约束不满足 | `Type {T} does not satisfy the required interface` |

## B0xx — 所有权与借用

### 借用冲突

| 码 | 消息模板 | 场景 |
|----|---------|------|
| B001 | `Cannot borrow `{name}` as mutable — already borrowed as immutable` | `r := &x; rm := &mut x;` |
| B002 | `Cannot borrow `{name}` as immutable — already borrowed as mutable` | `rm := &mut x; r := &x;` |
| B003 | `Cannot borrow `{name}` as mutable — already mutably borrowed` | `r1 := &mut x; r2 := &mut x;` |
| B004 | `Cannot use `{name}` while it is borrowed` | `r := &x; x = 42;` |

### 生命周期

| 码 | 消息模板 | 场景 |
|----|---------|------|
| B010 | `Reference to local `{name}` escapes the function` | `fn f() -> &int { x := 42; return &x; }` |
| B011 | `Borrowed value does not live long enough` | 引用比原对象存活时间更长 |

### Move

| 码 | 消息模板 | 场景 |
|----|---------|------|
| B020 | `Use of moved value `{name}`` | `move y = x; print(x);` |
| B021 | `Cannot move `{name}` — was already moved` | `move a = x; move b = x;` |
| B022 | `Cannot move `{name}` while borrowed` | `r := &x; move y = x;` |

## R0xx — 运行时检查

| 码 | 检查点 | 消息模板 |
|----|--------|---------|
| R001 | 编译期除零 | `Division by zero in constant expression` |
| R002 | 编译期下标超出数组长度 | `Index {idx} out of bounds for array of length {len}` |
| R003 | 编译期整数溢出 | `Integer overflow in constant expression: {expr}` |
| R004 | 数值转换损失精度 | `Conversion from {T1} to {T2} loses precision` |

## I/O 错误

| 码 | 检查点 | 消息模板 |
|----|--------|---------|
| E001 | 源码文件不可读 | `Cannot read source file '{path}'` |
| E002 | 输出文件不可写 | `Cannot write output file '{path}'` |
| E003 | CCR 文件格式损坏 | `Invalid .ccr file: {reason}` |
| E004 | CCR 文件不可读 | `Cannot open .ccr file '{path}'` |

## ICE — 编译器内部错误

| 码 | 检查点 | 消息模板 |
|----|--------|---------|
| ICE01 | 不应该发生的状况 | `Internal compiler error: {detail}` |
| ICE02 | 全局缓冲区溢出 | `Compiler limit: {buffer} overflow (max {max})` |
| ICE03 | IR 生成缺实现 | `Unsupported expression: {kind}` |
| ICE04 | 类型判定不可判（引擎 `-1`：未覆盖面/预算耗尽；或桥接缺口 = 该行译不成类型项）——R2 P5 Task 4 的 P-A 政策：**未知不当 0/1**（legacy 回落面已删），硬错拒绝落盘；反例（两侧类型项文本）随消息，判定点无 AST 位置 ⇒ `--> 0:0` | `type judgment indeterminate: {term_a} vs {term_b} ({cause})` / `type judgment indeterminate: no type term for type row {t1} / {t2} (bridge gap)` |

## V0xx — 规约语法 / 验证面（批 6「正式规约语法」开族；2026-09-17）

> **语义边界（裁-V6 / 裁-S5）**：本族**只收「可判定且必错」**的规约错误。
> **未证（yellow）不是错误**——它只进 `corec … --dump-vcs` 通道（T4），**绝不走诊断**：
> fail-closed 闸门（`main.cr:146-175`）默认阻断 ⇒ 若把「没证明」报成诊断，会把
> 「未证不阻断编译」直接变成 rc=1（违反裁-V6）。
> 码值以 `src/compiler/ast.cr` 的 `EC_V_*` 为准（17xxx；`error_cat_prefix` 的 `cat == 17 ⇒ "V"`）。

| 码 | 检查点 | 消息模板 |
|----|--------|---------|
| V01 | `#check(常量假)`——**本批唯一「红」**：常量折叠判为假（可判定且必错） | `#check(...) is statically false` |
| V02 | 未知 `#` 标签 / `#` 后非 IDENT（本批只认 `#check` / `#ensure`；`check`/`ensure` 是**普通 IDENT**，非关键字——见 `grammar/core.ebnf` 的 `Annotation` 注） | `Expected annotation name after '#'` / `Unknown annotation '#{name}' (expected '#check' or '#ensure')` |
| V03 | 标注形态错：缺 `(` / 未闭合 `)` | `Expected '(' after '#{name}'` / `Expected ')' to close '#{name}' annotation` |
| V04 | `#ensure` 的 `result` 绑定与既有作用域名冲突（裁-S8：**硬错**，不静默择一/不静默遮蔽） | `'result' is already bound in this scope (#ensure binding would shadow it)` |
| V05 | 标注表达式类型**非 bool**（本批子集：须**恰为** `TI_BOOL`；三态纪律——`infer_expr` 给不出 bool 一律硬错，**不得**「未知当通过」） | `annotation expression must be bool` |
| V06 | 标注表达式**含调用**（裁-V5：C1 子集**先禁调用**——避开纯度时序坑；本批**未解决**该时序，只绕开） | `annotation expression must not contain calls (C1 subset)` |

---

## 统计

| 段 | 范围 | 数量 | 说明 |
|----|------|------|------|
| L | L001–L011 | 11 | 词法 |
| P | P001–P023 | 23 | 语法 |
| N | N001–N021 | 21 | 名字解析 |
| I | I001–I006 | 6 | 类型推断 |
| TA | TA01–TA08 | 8 | 赋值与绑定 |
| TF | TF01–TF17 | 17 | 函数与调用 |
| TB | TB01–TB09 | 9 | 二元运算 |
| TU | TU01–TU03 | 3 | 一元运算 |
| TC | TC01–TC07 | 7 | 控制流 |
| TM | TM01–TM09 | 9 | Match/模式 |
| TK | TK01–TK08 | 8 | 数组与切片 |
| TS | TS01–TS04 | 4 | 结构体字面量 |
| TG | TG01–TG02 | 2 | 泛型 |
| B | B001–B010 | 10 | 借用 |
| R | R001–R004 | 4 | 运行时 |
| E | E001–E004 | 4 | I/O |
| ICE | ICE01–ICE04 | 4 | 编译器内部 |
| **总计** | | **150** | 计数约定见下注（2026-09-16 文档审计修正：原写「~146」，与本表加和不符） |

> **计数约定注（2026-09-16 文档审计）**——本仓「错误码数量」有**三种不同数法**，引用时**必须说明按哪种数法**：
> ① **本表加和 = 150**（17 族「编号容量」之和）；② **本文档明细码行 = 149**；
> ③ **`src/compiler/ast.cr` 实际定义的 `EC_*` 常量 = 137**（`grep -cE '^EC_[A-Z_]+ *: *int *='`）。
> 三者不等的**已知成因**：**L 族（11）无数值常量**（`lexer.cr::add_error` 只传消息文本，见本文件头部「L 族例外」）
> + 其余族个别编号在文档侧占位而未落常量。**两者的出处**：码值以 `ast.cr` 为准；**文档侧编号**以本文件为准。
