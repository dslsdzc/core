# Core 语言语法

> 定位：受众 = 开发者；状态 = active  
> 基线：`develop` @ `7cf724f6c1577e29879c37493b87e90ad061af57`  
> 版本：v4 目标语法

本文档记录 Core 语言本体的目标语法。v4 正在从现有 `develop` 实现迁移；迁移期间，编译器源码可能暂时接受旧语法，但新增代码与语法实现以本文档为目标。

---

## 一、词法与布局

### 1.1 注释

```core
// 单行注释
/* 多行注释 */
```

多行注释可以嵌套。

### 1.2 标识符

```text
IDENT = LETTER (LETTER | DIGIT | '_' | '\'')*
```

字母（a-z / A-Z / `_`）开头，后续可含字母、数字、下划线与单引号。`_` 本身是通配符。

### 1.3 关键字

v4 目标语法使用下列核心关键字：

```text
fn mut return if else loop while for break continue
true false struct enum extern impl match import pub
go await unsafe flow yield interface type mod as
auto fileid self in none unit never dyn
catch fail spec
```

- `self` 用于方法接收者（`self` / `&self` / `&mut self`）。
- `Self` 是接口/实现上下文中的类型名。
- `@comptime` 等 `@` 形式属于内建原语，不作为普通关键字处理。
- `#check` / `#ensure` / `#invariant` / `#variant` 属于规约指令；`#smt`、`#induct`、`#simp` 等属于证明战术标签。它们都不占用普通代码的全局关键字。（**注**：战术标签里**没有**「策略/标签定义」这一形——Core 不引入用户可见的策略定义机制，战术库的扩展走普通模块与导入，见 §10.6/§10.8。）
- `forall`、`exists`、`result`、`old` 只在规约上下文中具有特殊含义，不作为普通代码的全局保留字。
- v4 不使用 `move` 关键字。

### 1.4 字面量

| 字面量 | 示例 | 说明 |
|--------|------|------|
| 整数 | `42` `0` `-7` | 十进制；机器位宽由编码层按目标决定 |
| 小数 | `3.14` `.5` | 精确小数，默认 `dex` 语义 |
| 字符串 | `"Core"` `"a\nb"` | 不可变 UTF-8 |
| 字符 | `'x'` `'\n'` `'\x41'` | Unicode 标量值 |
| 布尔 | `true` `false` | |
| 单元 | `()` | `unit` 的唯一值 |
| 空可选值 | `none` | `T?` 的无值形态 |

普通 `T` 值可以作为 `T?` 的有值形态，不需要 `Some(...)` 包装。

### 1.5 运算符与结构记号

| 记号 | 含义 |
|------|------|
| `:` | 类型标注；在完整语法头部末尾开启 layout region |
| `:=` | 变量声明与绑定 |
| `=` | 赋值 / 显式初始化 |
| `+=` `-=` `*=` `/=` | 复合赋值 |
| `->` | 显式返回类型 / 函数类型结果 |
| `=>` | match / catch 臂映射到结果；规约量词体分隔 |
| `==>` | 规约蕴含，右结合 |
| `|` | alternative / pattern arm |
| `|>` | 管道阶段连接；只用于真实 pipeline |
| `...` | 变参前缀 |
| `*` | 乘 / 解引用 / 裸指针类型前缀 |
| `&` `&mut` | 引用 |
| `+ - / %` | 算术 |
| `== != < > <= >=` | 比较 |
| `&& \|\| !` | 逻辑 |
| `.` | 字段访问 / 类型推断占位 |
| `::` | 路径分隔符 |
| `,` | 分隔 |
| `?` | 可选类型标记 |
| `..` | 范围 |
| `@` | 内建原语前缀 |
| `_` | 通配符 |

`?` 不用于错误传播。错误传播由错误边与 `catch` 语法处理。

### 1.6 Layout region

v4 不使用 `{ ... }` 作为语言块结构。块由 `:` 与相对缩进建立。

```core
fn add(a: int, b: int) -> int:
    return a + b
```

缩进宽度本身没有语义。解析器只比较相对列关系：

```text
更深      = 当前结构的从属内容
同列      = 当前 region 的 sibling
更浅      = 退出一个或多个 region
```

同一 sibling group 必须对齐。第一个子项建立该 group 的 layout anchor。

下面两段结构等价：

```core
match x:
 | A => a
 | B => b
```

```core
match x:
    | A => a
    | B => b
```

但同一个 arm group 内不得错位：

```core
match x:
 | A => a
   | B => b     // error: sibling 未对齐
```

空行与只含注释的行不改变 layout。格式化器可以按语法角色使用不同的视觉缩进宽度，但不能改变 anchor 关系。

换行是通常的语句分隔方式。`;` 不要求用于普通源码布局。

---

## 二、模块与导入

模块系统基于**文件标识符**与**项目标识符**，不使用文件物理路径。

### 2.1 文件标识符

默认使用文件名（不含 `.cr`）作为标识符，可在文件头部覆盖：

```core
fileid "my_helper"

fn greet(name: string) -> string:
    return "hi " + name
```

同一项目内标识符必须唯一。

### 2.2 模块声明

```core
mod examples::pi
```

`::` 是文件内路径分隔符。

### 2.3 导入

```core
import math
import math : m
import @acme math
import @acme math : m
```

`@项目名` 前缀区分本地符号与外部项目符号。项目名在项目根的 `Core.toml` 中声明。

### 2.4 符号访问

```core
import math : m

result := m.add(3, 5)
```

未导入时可用完整路径 `math::add(3, 5)` 直接访问。

### 2.5 目录级批量导入

目录下的 `_import.cr` 自动应用于该目录及子目录：

```core
// _import.cr
import @acme math : m
import @std io
```

`_import.cr` 本身不生成代码，只起导入声明作用。

---

## 三、类型标注与自动类型关系

类型语法只保留用户需要主动表达的区别；能够由程序关系唯一恢复的信息由编译器推导。

### 3.1 类型表达式

目标语法：

```text
Type = BaseType
     | PathType
     | RefType
     | PtrType
     | OptionalType
     | FunctionType
     | TupleType
     | ArrayType
     | SliceType
     | InferredType
     | TypeOf

RefType      = '&' ['mut'] Type
PtrType      = '*' Type
OptionalType = Type '?'
FunctionType = 'fn' '(' [Type (',' Type)*] ')' '->' Type
TupleType    = '(' [Type (',' Type)*] ')'
ArrayType    = '[' Type ';' INT_LIT ']'
SliceType    = '[' Type ']'
InferredType = '.'
TypeOf       = 'typeof' '(' Expr ')'
```

`PtrType` 是可用的显式边界类型形式，不表示普通裸指针必须标注类型；由 `&`、指针算术或其他可追踪关系产生的指针默认自动推断。

基础类型：

| 类型 | 说明 |
|------|------|
| `int` | 精确整数 |
| `dex` | 精确小数 |
| `bool` | `true` / `false` |
| `string` | 不可变 UTF-8 字符串 |
| `char` | Unicode 标量值 |
| `unit` | 空值 `()` |
| `never` | 发散类型 |
| `dyn` | 运行时开放值域 |
| `Self` | 当前接口或实现类型 |

复合类型示例：

```core
coords : (int, int)
zeros  : [int; 16]
view   : [int]
parent : User?
cb     : fn(int) -> int
```

引用与裸指针通常不需要显式类型标注。`&`、解引用、指针算术以及数据流关系足以确定其指向类型、来源与偏移；只有外部地址、FFI、固定 ABI 等无法由程序关系恢复的边界才需要显式写出指针类型。

### 3.2 可选类型 `T?`

`?` 表示该位置允许“有值”或“无值”。

```core
parent : User? = none
value  : int? = 5
```

普通值直接构成有值分支，不使用 `Some(...)` 包装。

函数体能够唯一推出可选返回时，返回标注可以省略：

```core
fn find_user(id: int):
    if exists(id):
        return load_user(id)

    return none
```

显式 `-> User?` 仍可用于 API 契约。

### 3.3 引用、裸指针与动态值域

引用与裸指针的具体类型由表达式和 HDFG 自动推断，不要求为普通指针值重复写 `&T` / `*T` 标注：

```core
p := &arr[0]
q := p + n
x := *q
value : dyn = x
```

编译器从取地址对象、指针算术、解引用和数据流中恢复指向类型，并同时维护 provenance、offset 与可用区域。

`&T` / `&mut T` 仍可在函数边界等位置显式表达“引用既有实体”的接口关系；`*T` 是低层裸指针的显式类型形式，主要用于外部地址、FFI、固定 ABI 或显式转换等无法从安全程序关系唯一恢复类型的边界。`dyn` 表达运行时开放值域。

### 3.4 推断占位 `.` 与 `auto`

`.` 和 `auto` 表示由上下文和程序关系确定的类型。

```core
x : auto = 42
y : . = 3.14
z : ., mut = 20
```

`.` 可用于参数、字段、枚举 payload、切片元素与函数类型：

```core
fn identity(x: .):
    return x

struct Event:
    name: string
    payload: .

extern fn transform(fn(.) -> .) -> .
```

每个独立的 `.` 初始表示独立未知类型；只有程序关系要求时才建立等式或其他约束。

### 3.5 同一类型关系 `typeof(...)`

当声明本身需要显式表达同型关系、且没有实现可供推导时，可以引用已有位置的类型：

```core
extern fn clone_value(x: .) -> typeof(x)
```

不引入类型参数。

### 3.6 无显式泛型参数与泛型应用

v4 不包含 `<T>`、`[T]` 或其他显式泛型参数 / 类型实参语法。

```core
fn identity(x: .):
    return x
```

编译器可以从该实现得到参数与返回值的同型关系并自动泛化。

### 3.7 结构语义与物理布局分离

递归结构可以直接写出：

```core
struct Node:
    value: int
    next: Node?
```

普通类型语法不要求 `Box`、`Rc`、`Arc`、`Owned`、`Heap` 等存储或所有权包装。

### 3.8 标签

变量与字段可带 `mut`、`pub`、`apx` 等标签：

```core
count   : int, mut = 0
pub_val : int, pub = 42
speed   : dex, apx = 3.14
```

---

## 四、变量声明与赋值

无 `let` 关键字。`:=` 进行声明与绑定，`: Type =` 显式标注：

```core
x := 42
name : string = "Core"
count : int, mut = 0
shared : auto, pub, mut = 42
a, b : int = 1, 2
```

赋值使用 `=`：

```core
count = count + 1
count += 1
```

v4 不使用显式 `move`。region、借用有效性、escape、capture 与存储 realization 由程序关系推导。

### 4.1 region 作声明右值

声明的右值可以是一个 region。region 的值 = 它最后一项的值（与函数体一致：只有最后一项是值，其余按语句处理）：

```core
raw := unsafe:
    @str_of(buf)
```

这条形式的用途是把**只能以 region 书写**的构造（`unsafe` 等）放进一个值的位置。
它不引入新的表达式种类：region 仍是 region，只是在右值位被读取其尾值。

⚠ **实现态（2026-10-11 实测）**：目前只有 `unsafe` region 作右值能真正取到值（运行期验证过）。
`total := if ready: … else: …` 这类**块值 `if`** 能解析、能过检，但**发射面丢值**——
`bootstrap/corec/frontend/ir_gen.py` 的 `gen_if` 无条件 `return None`（既有缺陷，与 v4 迁移无关）。
⇒ 该形在文档里按**设计态**记，未实现前不要依赖。

⚠ 反向不成立：`f(unsafe: …)` —— 把 region 直接塞进**实参位** —— 不是合法文本（实参位是表达式位，
region 不是表达式）。需要时先把 region 的值绑定到一个名字，再把名字传进去。

---

## 五、表达式与运算符

### 5.1 基本优先级

从低到高：

```text
Assignment
Pipeline
LogicalOr
LogicalAnd
Equality
Comparison
Addition
Multiplication
Unary
CallOrField
Primary
```

`|>` 是独立的 pipeline 关系，不是普通函数调用的替代写法。其语义检查见 5.6。

### 5.2 基本表达式

```core
42
3.14
"Core"
'x'
true
()
none
(1 + 2) * 3
```

### 5.3 调用、字段与下标

```core
result := m.add(3, 5)
p.x
arr[0]
```

直接命名函数与 callable 值使用同一调用语法：

```core
f := fn.square
y := f(10)
```

### 5.4 函数引用与 Lambda

命名函数作为值使用 `fn.name`：

```core
fn square(x: int) -> int:
    return x * x

f : fn(int) -> int = fn.square
```

`fn.square` 是有类型 callable；`@addr(square)` 是低层机器地址。

表达式 lambda：

```core
double := fn(x: int) => x * 2
```

多行 lambda 使用 layout，并要求显式 `return`：

```core
f := fn(x: int) -> int:
    y := x * 2
    return y + 1
```

expected type 已知时参数类型可以省略：

```core
f : fn(int) -> int = fn(x) => x * 2
```

### 5.5 转换 `as`

```core
x : int = 3
d : dex = x as dex
ptr : *int = addr as *int
```

### 5.6 管道 `|>`

`|>` 只连接真实 pipeline 的 source / stage / sink。它不是 `f(x)` 的语法糖，也不用于普通值连续调用。

纵向形式：

```core
records(path)
|> valid
|> normalize
|> store
```

连续形式：

```core
records(path) |> valid |> normalize |> store
```

两种形式语义相同。

下面的写法不是 pipeline，用普通函数调用表达：

```core
name := normalize_text(trim(user.name))

text := read_file(path)
cfg := parse_config(text)
```

不能仅因为类型首尾可连接就使用 `|>`。类型可接不等于存在 pipeline relation。HDFG 必须能够确认各端构成管道关系。

### 5.7 @ 内建调用

```core
n := @sizeOf(Point)
```

---

## 六、错误与恢复

错误不通过 `Result<T, E>`、`Ok(...)`、`Err(...)` 或后缀 `?` 表达。可失败计算具有独立错误边；未处理错误自动向调用方传播。

### 6.1 产生错误

```core
fn parse(text: string) -> Config:
    if text == "":
        fail "empty input"

    return parse_impl(text)
```

`fail expr` 产生错误值。错误值不要求继承统一的 `Error` / `Exception` 基类。

### 6.2 `catch` 后置子句

`catch:` 位于被处理语句的下一行，与该语句处于同一 layout 层级：

```core
fn load_config(path: string) -> Config:
    text := read_file(path)
    catch:
     | FileNotFound => fail "config not found"

    cfg := parse_config(text)
    catch:
     | ParseError => fail "invalid config"

    validate_config(cfg)
    return cfg
```

`catch` 绑定到紧邻其前的可失败表达式或语句。

恢复分支可以产生替代值：

```core
cfg := parse_config(text)
catch:
 | ParseError => default_config()
```

未匹配的错误继续自动传播：

```core
cfg := load(path)
catch:
 | FileNotFound => default_config()
```

如果 `load(path)` 还可能产生其他错误，它们不会被该 `catch` 吞掉。

`_` 可以匹配任意错误；标识符模式可以绑定错误值：

```core
value := operation()
catch:
 | KnownError => recover()
 | e          => log_and_fail(e)
```

v4 不提供 `try` 关键字，也不提供错误传播用的 `?`。

---

## 七、语句与控制流

### 7.1 条件

```core
if x > 0:
    println("positive")
else if x < 0:
    println("negative")
else:
    println("zero")
```

### 7.2 循环

```core
for i in 0..10:
    println(i)

for item in items:
    println(item)

loop:
    if done:
        break

while condition:
    work()
```

### 7.3 匹配

```core
match value:
 | none => println("nothing")
 | x    => println(x)
```

字符串常量分支：

```core
match cmd:
 | "start"   => start_server()
 | "stop"    => stop_server()
 | "restart" => restart_server()
 | _          => println("unknown command")
```

`match` 臂使用 `| Pattern => Expr`。需要多行 arm body 时，`=>` 后换行并进入更深 layout：

```core
match cmd:
 | "start" =>
    prepare()
    start_server()
 | _ => println("unknown command")
```

### 7.4 返回

函数没有 implicit tail return。函数返回值必须由 `return` 明确产生。

```core
fn add(a: int, b: int) -> int:
    return a + b
```

下面的写法不是返回：

```core
fn add(a: int, b: int) -> int:
    a + b
```

如果函数声明了非 `unit` 结果但所有可达路径没有显式 `return`，属于静态错误。

返回类型仍可以由所有显式 `return` 路径推导：

```core
fn same(x: .):
    return x
```

### 7.5 不安全区域

```core
unsafe:
    ptr : *int = addr as *int
    *ptr = 42
```

---

## 八、函数与方法

### 8.1 函数定义

目标语法：

```text
FunctionDecl = ['pub'] 'fn' IDENT
               '(' [ParamList] ')'
               ['->' Type]
               ':' Layout
```

函数体统一由 `:` 开启，不使用 `=`、`:=`、`in` 或 `{ ... }` 作为函数体分隔符。

```core
fn add(a: int, b: int) -> int:
    return a + b

fn add_inferred(a: int, b: int):
    return a + b

fn identity(x: .):
    return x
```

只有签名、没有函数体的声明不写末尾 `:`：

```core
extern fn read(fd: int, buf: *char, len: int) -> int
```

接口中的方法声明同样只写签名。

### 8.2 方法

```core
impl Point:
    fn norm(&self) -> dex:
        return sqrt(self.x * self.x + self.y * self.y)

    fn move_by(&mut self, dx: dex, dy: dex):
        self.x += dx
        self.y += dy
```

接收者形式：`self` / `&self` / `&mut self`。

---

## 九、结构、枚举与接口

### 9.1 结构体

```core
struct User:
    id: int
    name: string
    parent: User?
```

字段属于结构体 layout region，不使用逗号结束字段。

### 9.2 枚举

枚举分支使用 `|`：

```core
enum Mode:
 | Server
 | Client
```

带 payload 的分支：

```core
enum Message:
 | Text(string)
 | Data([char])
 | Closed
```

### 9.3 接口声明与实现

```core
interface Eq:
    fn eq(&self, other: &Self) -> bool

impl Eq for Point:
    fn eq(&self, other: &Self) -> bool:
        return self.x == other.x && self.y == other.y
```

接口签名中的 `Self` 指实现类型本身。

### 9.4 自动多态

```core
fn first(list: &[.]):
    if list.len() > 0:
        return list[0]

    return none
```

函数体产生的接口需求直接形成约束：

```core
fn output(x: .):
    x.print()
```

无需显式类型参数或泛型约束列表。

### 9.5 类型别名

```core
type Point3 = (dex, dex, dex)
```

类型别名只提供名称，不引入泛型参数。

---

## 十、规约

规约直接写在 `.cr` 中，不存在独立的 `.corespec` / `.csp` 源语言。规约只描述不能从实现唯一恢复、或需要主动保证的性质；能够从 HDFG 自动推导的性质不要求用户重复标注。`#` 同时承载规约指令与战术标签：前者产生证明目标，后者向证明引擎提供能力、领域知识与搜索约束。

### 10.1 规约指令 `#check` / `#ensure`

函数规约位于函数 layout region 的开头：

```core
fn divide(a: int, b: int) -> int?:
    #check(b != 0)
    #ensure(result != none)

    if b == 0:
        return none

    return a / b
```

- `#check(...)`：调用方必须满足的前提条件。
- `#ensure(...)`：函数保证的后置条件。
- `result` 指当前规约所描述函数的返回值。
- `old(expr)` 指函数入口时表达式的值。

```core
fn transfer(from: &mut Account, to: &mut Account, amount: int):
    #check(amount >= 0)
    #ensure(from.balance + to.balance == old(from.balance + to.balance))

    from.balance -= amount
    to.balance += amount
```

`#check` / `#ensure` 是函数契约的一部分，不是附加的独立定理声明。证明一个函数，就是证明其前置条件蕴含后置条件。

### 10.2 循环规约 `#invariant` / `#variant`

循环不变量和终止度量写在循环 region 开头：

```core
i : int, mut = 0

loop:
    #invariant(i >= 0 && i <= count)
    #variant(count - i)

    if i == count:
        break

    consume(items[i])
    i += 1
```

- `#invariant(expr)`：每次进入循环与完成一次迭代后都必须保持的性质。
- `#variant(expr)`：用于终止性证明的递减度量。

### 10.3 可复用命题与纯函数

Core **不引入 `spec fn`**。**所有函数都是 `fn`**。规约表达式中可以调用任何被编译器判定为**纯、终止、可判定**的函数。纯性由 HDFG 自动推导，不需要用户标记。

```core
fn valid(x: int) -> bool:
    return x >= 0

fn divide(a: int, b: int) -> int?:
    #check(b != 0)
    #ensure(result != none)

    if b == 0:
        return none

    return a / b
```

`valid` 是普通 `fn`，但编译器证明它纯、终止、可判定，因此可以在 `#check` / `#ensure` / `#invariant` 中调用：

```core
#ensure(forall(i: int) => i >= 0 ==> valid(i))
```

如果某个函数有副作用、不终止或不可判定，就不能出现在规约中，编译器直接报错。用户不需要主动标记 spec。

函数契约本身就是可复用的命题。已证明的函数可以通过 `#apply` / `#rewrite` 在其他证明中引用：

```core
fn append_assoc(xs: List, ys: List, zs: List) -> bool:
    #ensure(append(append(xs, ys), zs) == append(xs, append(ys, zs)))
    return append(append(xs, ys), zs) == append(xs, append(ys, zs))

fn append_nil(xs: List) -> bool:
    #apply(append_assoc)
    #ensure(append(xs, Nil) == xs)
    return append(xs, Nil) == xs
```

`#apply(append_assoc)` 引用的是已证明的函数契约，即全称命题：

```text
forall(xs: List, ys: List, zs: List) => append(append(xs, ys), zs) == append(xs, append(ys, zs))
```

### 10.4 量词与蕴含

规约表达式支持全称、存在量词和逻辑蕴含：

```core
#ensure(forall(i: int) => i >= 0 ==> valid(i))
#check(exists(i: int) => table[i] == target)
```

量词形式：

```text
forall(name: Type) => SpecExpr
exists(name: Type) => SpecExpr
```

规约表达式中的自由变量自动泛化为全称闭包。例如 `#ensure(append(xs, Nil) == xs)` 自动等价于 `forall(xs: List) => append(xs, Nil) == xs`。

`==>` 是规约层蕴含运算符，优先级低于 `||`，右结合：

```text
A ==> B ==> C
```

等价于：

```text
A ==> (B ==> C)
```

### 10.5 战术标签

战术标签不是命令式 proof script。它们向证明引擎提供候选能力、领域提示或搜索限制；证明引擎根据目标结构、成本模型和已推导事实自动选择实际执行顺序，并可以在更便宜的方法已经关闭目标时忽略未使用的提示。

**提示标签**

提示标签缩小证明搜索范围，验证器可以忽略。

```text
#induct(x)        指定归纳对象
#cases(x)         指定情况分析对象
#unfold(f)        指定展开函数
#rewrite(lemma)   指定重写引理
#apply(lemma)     指定应用引理
#exists(witness)  提供存在量词见证
```

示例：

```core
fn append_nil(xs: List) -> bool:
    #induct(xs)
    #simp
    #ensure(append(xs, Nil) == xs)
    return append(xs, Nil) == xs
```

`#induct(xs)` 的含义是：如果当前证明需要归纳，将 `xs` 作为明确的归纳对象；它不要求验证器立刻执行归纳。如果化简或已有定理已经关闭目标，则不需要实际执行归纳。

**语义范围标签**

语义范围标签读取 HDFG 语义信息，将证明问题缩到有限图切片。这些标签只能读取、裁剪和分析 HDFG，并产生子目标、可验证事实或证书；不能修改源程序、HDFG 或 backend mapping。

```text
#graph.provenance(...)
#graph.dependencies(...)
#graph.reachability(...)
#graph.scc(...)
#graph.region(...)
#graph.effects(...)
#graph.alias(...)
#graph.state(...)
#graph.dataflow(...)
#graph.slice(...)
```

示例：

```core
fn output_independent(secret: ., output: .) -> bool:
    #graph.dependencies(secret, output)
    #ensure(no_dependency(secret, output))
    return no_dependency(secret, output)
```

如果相应分析属于已证明最坏情况线性的 ONLINE 能力，它可以在普通构建中生成语义事实；如果其证明过程需要非线性搜索，则只能在 VERIFY 阶段消费这些事实。

**判定与求解标签**

判定与求解标签提供专用证明能力。**它们只能在 VERIFY 阶段执行。**

```text
#ring
#field
#lia
#lra
#nia
#nra
#bitvec
#congruence
#sat
#smt
```

这些名字描述 proof capability，不意味着它们都能进入 ONLINE。每个战术必须登记自己的执行等级、适用目标、证据形式和成本信息。

`#smt` 是一个 VERIFY 战术标签：

```core
#smt
fn bounded(x: int, lo: int, hi: int) -> bool:
    #ensure(x >= lo && x <= hi)
    return x >= lo && x <= hi
```

它表示当前目标允许或优先使用 SMT 证明能力；`corec build` 仍不会因此启动 SMT。

**预算标签**

预算标签只约束 VERIFY 搜索，不改变普通 `corec build` 的线性复杂度边界。

```text
#budget(fast)
#budget(normal)
#budget(deep)
```

### 10.6 证明自动化与复杂度边界

`fn` 描述要证明什么；战术标签描述证明引擎可以使用什么能力、知识或搜索约束。普通情况下不要求用户手写战术：验证器先根据目标结构自动选择适用能力，只有无法低成本唯一决定策略、需要缩小搜索空间或需要显式授权昂贵证明时才写标签。

```core
fn distributive(a: int, b: int, c: int) -> bool:
    #ensure(a * (b + c) == a * b + a * c)
    return a * (b + c) == a * b + a * c
```

若目标可被代数正规化直接关闭，验证器可以自动使用对应战术；用户不需要重复写 `#ring`。

Core 对自动化有一条硬复杂度边界：

```text
ONLINE
    允许普通 corec build 隐式执行
    必须具有已知的最坏情况 O(N) 或图上的 O(V + E) 上界

VERIFY
    不要求线性最坏情况保证
    只能在显式验证阶段执行
```

其中 `N` 表示当前处理对象的线性表示规模，`V` / `E` 表示 HDFG 的节点数与边数。普通构建不得因为某个规约或战术标签启动 SMT、归纳搜索、定理搜索或其他没有线性最坏情况保证的过程。

因此：

```text
corec build
    source
      ↓
    仅 ONLINE 分析
      ↓
    HDFG / CIR / codegen

corec verify
    已生成的语义对象 + 函数契约
      ↓
    ONLINE + VERIFY 战术
      ↓
    proof / certificate
      ↓
    CIC kernel
```

已经验证的证明结果可以作为带依赖身份的 proof artifact 缓存；后续普通构建可以读取和校验其身份，但不能为了重新得到该结果而隐式启动 VERIFY 搜索。

每个战术至少登记：

```text
name
applicability
execution_class   ONLINE | VERIFY
complexity        已知上界或未承诺
cost              cheap | medium | expensive | unbounded
required_context
produced_evidence
```

组合策略的执行等级由其成员自动传播。但 **Core 不引入用户可见的策略定义机制**；战术库的扩展通过**普通模块和导入**完成。

编译器自动推导的 `pure`、`deterministic`、`terminating`、`no_alloc`、`safe_index` 等性质首先属于内部 FactDB / 验证结果，不要求用户在普通源码中重复书写同名标签。只有需要给证明引擎增加无法自动恢复的信息时才使用显式战术标签。

### 10.7 证明对象与元编程不形成用户类型

Core 不引入 `Fragment<...>`、`Relation`、`Goal<...>`、`Proof<...>`、`Rewrite<...>` 等用户可见元对象类型。证明状态、战术参数角色、证明项、语义切片与重写对象可以存在于验证器内部，但源码仍使用普通 Core 语法、`fn`、`#` 战术标签和 `@` 编译/映射控制表达。

### 10.8 战术库与扩展

战术库可以包含：

```text
primitive tactics
semantic tactics
decision procedures
lemma / rewrite databases
goal classifiers
reflection procedures
```

标准库可以按领域组织，例如：

```text
std::proof::logic
std::proof::arithmetic
std::proof::algebra
std::proof::collections
std::proof::graph
std::proof::memory
std::proof::concurrency
```

第三方战术库继续使用**普通 Core 模块与包管理机制**，不建立独立的 proof package manager。可见 theorem / lemma 数据库由普通 `import` 范围限制，避免默认把整个生态的规则都送入 proof search。

## 十一、并发与执行流

### 11.1 异步启动 `go`

```core
handle := go some_work(arg1, arg2)
```

### 11.2 等待 `await`

```core
result := await handle
```

等待关系可以由值依赖自动推导；`await` 保留为显式控制点。

### 11.3 长期执行流 `flow` / `yield`

```core
flow counter(start: int) -> int:
    n : int, mut = start

    loop:
        yield n
        n += 1
```

`flow` 与普通 `fn` 一样使用 `:` 开启 layout region。

### 11.4 Pipeline

`flow`、channel、stream 或其他能够形成管道关系的实体可以通过 `|>` 组合：

```core
records(path)
|> valid
|> normalize
|> store
```

或者：

```core
records(path) |> valid |> normalize |> store
```

是否构成合法 pipeline 由语义关系判定，不由“函数签名刚好能接上”决定。

---

## 十二、指针与 unsafe

### 12.1 裸指针自动推断

普通裸指针操作不需要显式指针类型声明：

```core
p := &arr[0]      // 自动推断指向类型，并记录来源与初始偏移
p = p + n         // 指针算术继续传播 provenance / offset 关系
x := *p           // 解引用时由编译器验证可访问范围
```

指针和 C 一样允许直接取地址、算术与解引用；安全性不依赖用户写生命周期、所有权类型或裸指针类型标注。PointerAnalysis、RegionCheck 与 ProvenanceVerify 从 HDFG 自动恢复并验证这些关系。

显式 `*T` 不是普通指针代码的必需标注。它只在类型无法从程序关系恢复时作为边界类型使用，例如整数机器地址、FFI 或固定 ABI：

```core
unsafe:
    ptr := addr as *int
    *ptr = 42
```

这里写 `*int` 是因为 `addr` 本身只有机器地址信息，编译器无法从来源关系推出被指向对象的类型。

### 12.2 unsafe region

普通硬件能力优先通过 HIT 表达；具体机器 realization 与 HIT 实现层由 `.crasm` / backend 负责。

### 12.3 固定地址放置 `alloc_at`

固定物理地址、MMIO 页或其他由外部世界给出的地址事实使用声明式放置：

```core
mmio := alloc_at(0x7fff0000, 4096, align(4096))
```

`alloc_at(addr, size, align)` 将地址、大小和对齐作为一个可追踪的分配关系送入图中；之后的 provenance、offset、边界和生命周期继续由普通指针分析处理。它不是显式区域/回收语法。

---

## 十三、@ 内建原语

`@` 开头的标识符是编译器能力入口，不通过标准库实现。`@` 只用于查询、编译/映射控制和低层边界；它不建立独立的元编程语言。

### 13.1 元数据与语义查询

```core
@sizeOf(Point)
@alignOf(Point)
@fields(Point)
@field(Point, "x")
@hasField(Point, "x")
@typeInfo(Point)
```

这些结果可以在普通 Core 的编译期执行环境中使用，不要求 `Fragment`、`Relation` 等专用元类型。

### 13.2 编译控制

```core
@inline(fn.square)
@unroll(4)
@section("text.hot")
@comptime(expr)
@fast
```

块形式使用普通 layout：

```core
@comptime:
    for field in @fields(User):
        inspect(field)
```

`@fast` 是优化提示；忽略它不能改变程序语义。允许结果近似使用 `apx`，不由 `@fast` 授权。

### 13.3 函数地址

```core
@addr(square)
```

`@addr(square)` 返回机器地址；普通函数值使用 `fn.square`。

### 13.4 安全检查

```core
@NoBoundsCheck
```

`@NoBoundsCheck` 只用于调用方明确承担边界安全责任的低层区域。

### 13.5 FFI

C ABI 是 `extern fn` 的默认外部接口；需要指定其他运行时互操作方式时使用 `@ffi(...)`：

```core
extern fn write(fd: int, buf: *char, len: int) -> int

@ffi("Python")
extern fn py_call(obj: dyn, method: string) -> dyn

@ffi("Java")
extern fn java_call(env: dyn, obj: dyn, method: string) -> dyn
```

`@ffi` 描述外部调用边界的编组/ABI 方式，不引入另一种 Core 类型系统。

### 13.6 Hotpatch

函数多版本共存使用 `@hotpatch(...)`：

```core
@hotpatch(ver=1)
fn handle(x: dyn) -> dyn:
    return handle_v1(x)

@hotpatch(ver=2)
fn handle(x: dyn) -> dyn:
    return handle_v2(x)
```

所有同名 hotpatch 版本必须保持兼容签名；版本选择与 rollout 属于运行时映射，不改变调用处的源语言类型。

### 13.7 异构执行域

异构执行默认完全自动：没有注解时，编译器根据 HDFG、HIT 能力、拓扑、数据驻留和代价模型选择执行域。源码只在确实需要约束映射时写注解。

软偏好：

```core
@preferredDomain(gpu)
fn transform(data: [dex]) -> [dex]:
    return compute(data)
```

`@preferredDomain(name)` 表示优先映射到该逻辑执行域；不可用或代价不合适时允许回退。

硬约束：

```core
@executionDomain(fpgaA)
flow encode(input: Frame) -> Packet:
    yield encode_frame(input)
```

`@executionDomain(name)` 要求映射到指定逻辑执行域；目标不存在或不能满足该 region 的语义要求时必须报错，不得静默回退。

注解也可以约束局部执行 region：

```core
@preferredDomain(gpu)
loop:
    process_batch()
```

执行域名由部署环境提供，不是语言内建类型。`gpu`、`fastCpu`、`fpgaA`、`remoteNode7` 等都只是逻辑 domain 名称。Core 不提供 CUDA 风格 kernel 语法，也不要求显式 memcpy/host-device transfer；数据 residency、materialization 和传输由 Execution Mapping 与 HIT 决定。

映射模式只有三种：

```text
无注解                       AUTO
@preferredDomain(name)       PREFER
@executionDomain(name)       REQUIRE
```

这些注解只约束 realization/mapping，不改变函数、flow、loop 或 region 在 HDFG 中的语义身份。
