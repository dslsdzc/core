# Core 错误码参考

每一个错误码对应编译器中 **一个唯一可区分的检查点**。
同一条性质但不同上下文（赋值 vs 传参 vs 初始化）的报错各占独立码。

---

## L0xx — 词法 (Lexer)

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
| L009 | 浮点数格式 | `Invalid float literal` | `1.` 或 `.e5` 等 |
| L010 | 浮点数后缀非法 | `Invalid float suffix: {suffix}` | 非 f32/f64 后缀 |
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

| 码 | 检查点 | 消息模板 |
|----|--------|---------|
| TA01 | 赋值号类型不匹配 | `Cannot assign {T2} to {T1}` |
| TA02 | 变量声明类型与初始值不符 | `Variable declared as {T1}, got {T2}` |
| TA03 | 批量声明类型不一致 | `Batch declaration has mixed types: {T1} vs {T2}` |
| TA04 | 赋值给不可变变量 | `Cannot assign to immutable variable '{name}'` |
| TA05 | 变量未声明 mutable | `Variable '{name}' is not mutable` |
| TA06 | 全局变量未声明 mutable | `Global '{name}' must be `mut` to reassign` |
| TA07 | 元组解构数量不匹配 | `Tuple destructuring has {M} variables but tuple has {N} elements` |

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
| TC02 | if/else 分支类型不一致 | `If branches have different types: {T1} vs {T2}` |
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
| TK02 | 数组元素类型不一致 | `Expected array element type {T1}, got {T2}` |
| TK03 | 数组大小不是整数 | `Array size must be `int`` |
| TK04 | 数组大小为负数 | `Array size must be positive, got {size}` |
| TK05 | 切片越界 | `Slice start {N} is out of bounds (length {L})` |
| TK06 | 切片长度非法 | `Slice length must be non-negative` |
| TK07 | `for` 迭代目标不是数组或范围 | `Cannot iterate over type {T}` |
| TK08 | `for` 迭代变量与元素类型不匹配 | ``for` variable type {T1} does not match element type {T2}` |

## TS0xx — 类型检查：结构体字面量

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
| R002 | 编译期越界 | `Index {idx} out of bounds for array of length {len}` |
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

---

## 统计

| 段 | 范围 | 数量 | 说明 |
|----|------|------|------|
| L | L001–L011 | 11 | 词法 |
| P | P001–P019 | 19 | 语法 |
| N | N001–N021 | 21 | 名字解析 |
| I | I001–I006 | 6 | 类型推断 |
| TA | TA01–TA07 | 7 | 赋值与绑定 |
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
| ICE | ICE01–ICE03 | 3 | 编译器内部 |
| **总计** | | **~145** | |
