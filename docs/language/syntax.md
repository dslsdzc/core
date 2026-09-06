# Core 语言语法

> 定位：受众 = 用户；状态 = active

本文档描述 Core 语言**本体**的语法：词法、类型标注、声明、表达式、控制流、接口与泛型、规约、并发。语法形式以 `grammar/core.ebnf` 与 `src/compiler/` 源码为准（冲突时以源码为准）；语义以格形态为标准框架解释。

---

## 一、设计要点

Core 的语义保鲜（semantic preservation）由三层映射承载：

| 层 | 形态 | 格式 | 职责 |
|----|------|------|------|
| 图 | 结构表达（关系空间） | `.cir` | 程序的结构：节点、边、region |
| 格 | 存在表达（状态空间） | `.ccr` | 存在：状态、条目、共存、驱逐 |
| 编码 | 机器形状 | ELF | 目标实现细节，由 hw-map 领域决定 |

编译把图降为格的线性投影（`lower_to_ccr()`），格的线性投影承载全部类型与语义信息，形式验证直接消费——这就是语义保鲜：正确性陈述对全部可能执行成立，不按控制流路径陈述。详见 `docs/archive/memory-model-capability-lattice.md`（三层映射 v4 §四）与 `docs/superpowers/specs/2026-08-27-lattice-form-ir-design.md`（格形态 IR）。

语言层面的设计要点：

- **无独立类型系统**：类型 = 图上的标注，接口 = 图上的契约，类型检查 = 图的良构性验证（与指针三 pass 同级）。本文档只描写类型标注的**语法**。
- **无 `let` 关键字**：变量用 `:=` 或 `: Type =` 声明。
- **无生命周期标注**：引用有效性由编译器全权推断。
- **一切自动推断，无关键字**——编译器看图自动做，用户零标注负担：
  - **类型推断**：`:=` / `auto` / `.` 推断；类型/接口是图的投影，标注可自动算出（语义保鲜，见类型方向定案）
  - **所有权推断**：默认借用——传参、赋值自动借用，显式 `move` 转移所有权
  - **编译时执行**：图见全常量输入即自动执行，`@comptime` 兜底（"算不了就报错"）
  - **惰性求值**：控制流分支自动惰性——未执行路径不求值，多路径需要时自动升级 eager，**无 `lazy()` 关键字**（见 `docs/proposals/lazy.md`）
  - **指针安全**：裸地址与 C 同级自由，provenance 自动推导，编译器自动验证
  - **动态类型转换**：`dyn` 边界自动插转换，无需 cast
  - **概率推导**：编译期自动进行（probabilistic pass）
  - **机器形状**：整数位宽、浮点格式由编码层按目标自动决定（hw-map 领域）
- **并发 = 流的构造**：`go` / `await` / `flow` / `yield` 构成数据流网络。

---

## 二、词法

### 2.1 注释

```core
// 单行注释
/* 多行注释 */
```

多行注释可以嵌套（`/* /* */ */`）。

### 2.2 标识符

```
IDENT = LETTER { LETTER | DIGIT | '_' | '\'' }
```

字母（a-z / A-Z / `_`）开头，后续可含字母、数字、下划线与单引号。`_` 本身是通配符（match 分支、占位）。

### 2.3 关键字

共 37 个（以 `src/compiler/lexer.cr lookup_keyword()` 为准）：

```
fn mut return if else loop while for break continue
true false struct enum extern impl match import pub
go await unsafe flow yield interface type mod as
auto fileid move self in None Some unit
```

- `self` 是词法关键字，用于方法接收者（`self` / `&self` / `&mut self`）。
- `Self` 不是词法关键字——它是接口/方法签名中的上下文类型名，按标识符解析，由 checker 按上下文处理。
- `comptime` 不是关键字（`@comptime` 是 @ 内建原语）。
- `requires` / `ensures` / `old` / `result` 不是词法关键字——它们是规约层的语法（见第 10 章与 `grammar/corespec.ebnf`）。

### 2.4 字面量

| 字面量 | 示例 | 说明 |
|--------|------|------|
| 整数 | `42` `0` `-7` | 十进制。无进制前缀、无 `_` 分隔符、无宽度后缀；机器位宽由编码层按目标决定 |
| 小数 | `3.14` `.5` | 精确小数，默认 `dex` 语义（`3.` 不是合法小数） |
| 字符串 | `"Core"` `"a\nb"` | 不可变 UTF-8 |
| 字符 | `'x'` `'\n'` `'\x41'` | Unicode 标量值 |
| 布尔 | `true` `false` | |
| 单元 | `()` | `unit` 类型的唯一值 |
| 可选 | `None` `Some(expr)` | 可选类型构造器（见 4.1） |

转义序列：`\n` `\t` `\r` `\0` `\\` `\"` `\'` `\xHH`（两位十六进制）。

### 2.5 运算符记号

| 记号 | 含义 |
|------|------|
| `:=` | 变量声明（无 `let`） |
| `=` | 赋值（含声明初始化 `: T =`） |
| `->` | 返回类型（仅此用途） |
| `*` | 乘 / 解引用 |
| `&` `&mut` | 取地址（引用） |
| `+ - / %` | 算术 |
| `== != < > <= >=` | 比较 |
| `&& \|\| !` | 逻辑 |
| `.` | 字段访问 / 类型推断占位 |
| `::` | 路径分隔符（文件内路径） |
| `,` | 分隔 |
| `;` | 语句结束（可省略） |
| `?` | 可选标记 / 错误传播 |
| `..` | 范围 |
| `@` | 内建原语前缀 |
| `_` | 通配符 |

---

## 三、模块与导入

模块系统基于**文件标识符**与**项目标识符**，不使用文件物理路径。

### 3.1 文件标识符

默认使用文件名（不含 `.cr`）作为标识符，可在文件头部覆盖：

```core
fileid "my_helper";

fn greet(name: string) -> string = "hi " + name;
```

同一项目内标识符必须唯一，重复报错。

### 3.2 模块声明

```core
mod examples::pi;
```

`mod` 声明路径（`Path = IDENT { '::' IDENT }`），`::` 是文件内路径分隔符。

### 3.3 导入

```core
import math;              // 同一项目的文件（文件标识符）
import math : m;          // 重命名，之后用 m.符号
import @acme math;        // 外部项目 acme 中的 math 文件
import @acme math : m;    // 并重命名
```

`@项目名` 前缀区分本地符号与外部项目符号，不可省略。项目名在项目根的 `Core.toml` 中声明（`name = "acme"`）。

### 3.4 符号访问

```core
import math : m;

result := m.add(3, 5);    // 点号访问导入符号
```

未导入时可用完整路径 `math::add(3, 5)` 直接访问（不推荐）。

### 3.5 目录级批量导入

目录下的 `_import.cr` 自动应用于该目录及子目录（子目录自己的 `_import.cr` 覆盖；继承合并，冲突报错）：

```core
// _import.cr
import @acme math : m;
import @std io;
```

```core
// main.cr——无需重复 import
fn main() {
    result := m.add(3, 5);
    io.println("result = {result}");
}
```

`_import.cr` 本身不生成代码，只起导入声明作用。

## 四、类型标注

Core 没有独立的类型系统：类型是图上的**标注**（`x : int` 标注 x 的节点），接口是图上的**契约**。本节描写类型标注的语法形式。

### 4.1 类型表达式

```
Type = BaseType | PathType | RefType | OptionalType | TupleType | ArrayType | SliceType
```

**基础类型**：

| 类型 | 说明 |
|------|------|
| `int` | 整数（精确） |
| `dex` | 精确小数（默认实数语义，缩放整数/定点实现） |
| `bool` | `true` / `false` |
| `string` | 不可变 UTF-8 字符串 |
| `char` | Unicode 标量值 |
| `unit` | 空值 `()` |
| `never` | 发散类型 |
| `dyn` | 动态类型——图全量已知所有分支，边界自动插转换（详见 `docs/proposals/dynamic-typing.md`） |
| `Self` | 上下文类型名，仅在接口/方法签名内有效（实现类型本身） |

**复合类型**：

```core
pair  : (int, bool);        // 元组
zeros : [int; 16];          // 数组（长度是常量）
slice : [int];              // 切片
maybe : int?;               // 可选
ref   : &Point;             // 引用
mutr  : &mut Point;         // 可变引用
```

**接口作类型**：任何接口名可作为类型标注（`PathType`），见第 9 章。

**机器形状不在语言内**：整数位宽、浮点格式等机器形状由编码层按目标自动决定，不进入类型/标签体系；未来显式控制走 hw-map。

### 4.2 标注位置

类型标注出现在：变量声明（`x : int = 42`）、函数参数（`fn f(a: int)`）、返回类型（`-> int`）、泛型参数（`[T: Eq]`，见第 9 章）。

### 4.3 标签

变量与字段可带标签，`mut`（可变）/ `pub`（公开）/ `apx`（近似授权）：

```core
count   : int, mut = 0;     // 可变
pub_val : int, pub = 42;    // 公开字段
speed   : ., apx = 3.14;    // apx：授权后端把 dex 运算降级为 binary64 快路径
```

`apx` 与 `mut` / `pub` 同族。不带 `apx` 时 `dex` 恒精确。

### 4.4 推断占位：`auto` 与 `.`

类型推断占位，两者完全等价，可用于变量声明与返回类型：

```core
x : auto = 42;              // 推断为 int
y : . = 3.14;               // 推断为 dex
z : ., mut = 20;
a, b, c : auto, mut = 0;
```

`auto` 更显式、`.` 更简洁——注意 `: ., mut` 模式中 `.` 是类型占位。

---

## 五、变量声明

无 `let` 关键字。声明即语句，`:=` 推断类型（不可变），`: Type =` 显式类型：

```core
x := 42;                    // 推断为 int，不可变
name : string = "Core";     // 显式类型
count : int, mut = 0;       // 显式 + 可变
shared : auto, pub, mut = 42;   // 全局公开可变
a, b : int = 1, 2;          // 批量声明
```

`move` 显式移动所有权（默认借用语义，见第 1 章设计要点——无生命周期标注，引用有效性编译器全权推断）：

```core
b := move a;                // a 的所有权转移到 b，a 失效
consume(move b);            // 参数移动传入
```

复制类型（`int`、`dex`、`bool` 等实现 Copy 接口的类型）赋值时自动复制，不需 `move`。

---

## 六、表达式与运算符

### 6.1 优先级

从低到高（`grammar/core.ebnf` 的推导链）：

```
Assignment → LogicalOr → LogicalAnd → Equality → Comparison
→ Addition → Multiplication → Unary → CallOrField → Primary
```

| 优先级 | 运算符 | 结合性 |
|--------|--------|--------|
| 最低 | `=`（赋值）`:=`（声明） | 右 |
| | `\|\|` | 左 |
| | `&&` | 左 |
| | `==` `!=` | 左 |
| | `<` `>` `<=` `>=` | 左 |
| | `+` `-` | 左 |
| | `*` `/` `%` | 左 |
| | 一元 `-` `!` `&` `&mut` | — |
| 最高 | 调用 `f(...)`、字段 `.x`、下标 `[i]`、`?` | 左 |

### 6.2 基本表达式

```core
// 字面量与标识符
42; 3.14; "Core"; 'x'; true; (); None; Some(5);

// 括号
(1 + 2) * 3;

// 块表达式——块的值 = 最后一条语句的值
x := { a := 1; a + 2 };

// if 表达式
category := if x > 0 { "positive"; } else { "not positive"; };

// match / loop / for / go / await / unsafe 也是表达式（见第 7、11、12 章）
```

### 6.3 调用、字段与下标

```core
result := m.add(3, 5);      // 函数调用
p.x;                        // 字段访问
arr[0];                     // 下标
```

### 6.4 转换 `as`

```core
x : int = 3;
d : dex = x as dex;         // 显式转换
ptr : RawRef<int> = addr as RawRef<int>;
```

### 6.5 错误传播 `?`

`?` 后缀：表达式失败时立即从当前函数返回错误，只能用于返回可传播错误类型（如 `Result`）的函数中：

```core
fn fetch() -> Result<string, IoError> {
    data := read_file("config.txt")?;   // 出错则立刻返回 Err
    Ok(data)
}
```

### 6.6 @ 内建调用

`@` 开头是编译器内建原语（见第 13 章）：

```core
n := @sizeOf(Point);
```

---

## 七、语句与控制流

语句以 `;` 结束（可省略）。`Statement = Expr ';' | LetStmt | ReturnStmt | YieldStmt | BreakStmt | ContinueStmt`。

### 7.1 条件

```core
if x > 0 {
    println("positive");
} else if x < 0 {
    println("negative");
} else {
    println("zero");
}
```

### 7.2 循环

```core
for i in 0..10 {            // 范围 0..10（含 0 不含 10）
    println(i);
}

for item in items {
    println(item);
}

loop {                      // 无限循环
    if done { break; }
}

while condition {
    // ...
}
```

`break` / `continue` 用于 `loop` / `while` / `for`。

### 7.3 匹配

```core
match opt {
    Some(x) => println("got {x}"),
    None    => println("nothing"),
}
```

匹配必须穷尽所有情况。模式（Pattern）可以是字面量、标识符、元组/结构体/枚举模式、`_` 通配。

当 scrutinee 是字符串表达式且所有分支是字符串常量时，编译器自动生成基于哈希的跳转表——计算一次哈希，与各分支预计算哈希比较，冲突时再检查相等：

```core
match cmd {
    "start"   => start_server(),
    "stop"    => stop_server(),
    "restart" => restart_server(),
    _         => println("unknown command"),
}
```

### 7.4 返回

```core
fn add(a: int, b: int) -> int {
    return a + b;           // 显式返回
}
```

### 7.5 不安全块

```core
unsafe {
    ptr : RawRef<int> = addr as RawRef<int>;
    ptr.write(42);
}
```

`unsafe` 块隔离不安全操作（见第 12 章）。

---

## 八、函数与方法

### 8.1 函数定义

```core
fn add(a: int, b: int) -> int {
    return a + b;
}

fn pi() -> auto = 3.14159;  // 单行形式；返回类型推断
```

`FunctionDecl = [ 'pub' ] 'fn' IDENT [ GenericParams ] '(' [ ParamList ] ')' '->' Type ( FunctionBody | '=' Expr ';' )`。参数 `Param = IDENT ':' Type`。返回类型可以是 `auto`（或 `.`），由函数体推导。

### 8.2 方法

`impl` 为类型挂接方法，接收者 `self` 是第一个参数：

```core
impl Point {
    fn norm(&self) -> dex {
        (self.x * self.x + self.y * self.y).sqrt()
    }

    fn move_by(&mut self, dx: dex, dy: dex) {
        self.x += dx;
        self.y += dy;
    }
}
```

接收者形式：`self`（按值）/ `&self`（借用）/ `&mut self`（可变借用）。

---

## 九、接口与泛型

接口是图上的**契约**（见类型方向定案 `docs/superpowers/specs/2026-08-30-type-system-direction-design.md`）：声明一组方法签名，实现类型必须满足。

### 9.1 接口声明与实现

```core
interface Eq {
    fn eq(&self, other: &Self) -> bool;
}

impl Eq for Point {
    fn eq(&self, other: &Self) -> bool {
        self.x == other.x && self.y == other.y
    }
}
```

接口签名中的 `Self` 指实现类型本身。基础类型（`int` / `dex` / `string` 等）对标准接口（`Eq`、`Copy`、`Hash` 等）内建实现。

### 9.2 泛型 = 编译期接口具体化

泛型参数 `[T]` 声明，接口绑定 `[T: Eq]` 约束 T 必须实现该接口：

```core
fn first[T: Eq](list: &[T]) -> T? {
    if list.len() > 0 {
        return Some(list[0]);
    }
    None
}
```

实例化时检查类型参数满足接口绑定，**编译期具体化**——无运行期字典。

### 9.3 类型别名

```core
type Point3 = (dex, dex, dex);
```

---

## 十、规约

规约（requires / ensures）与函数体并列，可选编写，参与静态检查，不影响运行时性能。规约语法详见 `docs/design/spec-design.md` 与 `grammar/corespec.ebnf`。

### 10.1 requires / ensures

```core
fn divide(a: int, b: int) -> int?
    requires b != 0
    ensures result.is_some() implies (a / b) == result.unwrap()
{
    if b == 0 {
        return None;
    }
    return Some(a / b);
}
```

- `requires` —— 调用方必须满足的前提条件
- `ensures` —— 保证的后置条件；`result` 指返回值，`old(expr)` 指函数入口时表达式的值

### 10.2 where 值约束

`where` 实现内联轻量前置条件，与 `requires` 同层：

```core
fn sqrt(x: dex) -> dex where x >= 0 {
    // ...
}
```

值约束按表达式形态分三档语义（一条语法，两层消费：checker + 验证管线）：

| 约束形态 | 语义 |
|----------|------|
| 常量约束 | 编译期求值——不满足 → 编译错误；满足 → 通过 |
| 符号约束 | 生成 VC（验证义务），由验证管线消费 |
| 动态约束 | 运行时检查——「证明不了也不静默」 |

与 `.corespec` 前置条件互相映射。

---

## 十一、并发

### 11.1 异步启动 `go`

```core
handle := go some_work(arg1, arg2);   // handle: Flow<T>
```

### 11.2 等待 `await`

```core
result := await handle;   // 阻塞直到完成
```

按需自动等待——当值被需要时自动等待：

```core
val := go fetch(url) + go fetch(other);   // 两个 flow 自动等待
```

### 11.3 长期执行流 `flow` / `yield` / `recv`

```core
flow counter(start: int) -> int {
    n : ., mut = start;
    loop {
        yield n;          // 产出数据
        n += 1;
    }
}

f := go counter(0);
for i in 0..5 {
    v := f.recv();        // 接收一个值
    println(v);
}
```

---

## 十二、指针与 unsafe

### 12.1 指针

指针是裸地址，与 C 同级自由，编译器通过格/图自动验证安全（详见 `docs/design/pointer-model.md`）：

```core
p := &arr[0];     // 取地址，编译器记下 provenance
p = p + n;        // 偏移，随便算
x := *p;          // 解引用，编译器验证 offset ∈ [0, len)
ptr := addr as RawRef<int>;   // 显式转换
```

### 12.2 unsafe 块

`unsafe { }` 块内允许：

- 使用 `RawRef<T>`
- 调用外部 C 函数
- 编译器固有

```core
unsafe {
    ptr : RawRef<int> = addr as RawRef<int>;
    ptr.write(42);
}
```

`RawRef<T>` 无法逃逸到安全代码。

---

## 十三、@ 内建原语

`@` 开头的标识符是编译器内建的能力入口，不通过标准库实现。分三类（详见 `docs/design/at-intrinsics.md`）。

**元数据查询**——编译期查询类型信息，零运行时开销：

```core
@sizeOf(T)            // 类型大小
@alignOf(T)           // 类型对齐
@fields(T)            // 字段名列表
@field(T, name)       // 字段偏移和类型
@hasField(T, name)    // 字段是否存在
@typeInfo(T)          // 完整类型结构
```

**编译控制**——不改变语义，只改变编译方式：

```core
@inline(fn)           // 提示内联
@unroll(n)            // 展开循环
@section(name)        // 指定代码段
@comptime(expr)       // 强制编译期执行
```

**安全检查**——unsafe 范畴，调用方自己保证：

```core
@no_bounds_check      // 跳过边界检查
```
