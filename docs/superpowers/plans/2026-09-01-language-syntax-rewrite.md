# language-syntax.md 重写实现计划

> 面向执行本计划的 agent：必须使用 superpowers:subagent-driven-development（推荐）或 superpowers:executing-plans，按任务逐项实现。用复选框（`- [ ]`）跟踪进度。

目标：将 `docs/language-syntax.md` 重写为 13 章参考手册式语法文档。文档描述定案后的完整语言，以格形态为标准解释，不标注实现状态。

结构：单文件文档重写。按内容分成 4 个任务顺序书写：框架、设计要点、词法、模块，然后是类型标注、声明、表达式、控制流，接着是函数、接口泛型、规约，最后是并发、指针、内建、全文验证。每个任务自带验证（grep 检查加章节内容核对），最后一个任务执行 spec 的完整验证清单。

技术栈：Markdown，无代码、无编译，验证用 grep。版本控制使用 `jj`，项目规则第 2 条禁止使用 git。

设计 spec：`docs/archive/2026-09-01-syntax-doc-rewrite-design.md`

## 全局约束

以下条目逐条抄自 spec，所有任务都默认包含。

1. 定位：定案后的完整语言，当前实现与未来设计统一呈现，全文不出现「已实现」「未实现」「待实现」标注。
2. 边界：语言本体，以语法为准。不含标准库表层（HashMap、HashSet、通道、Result）、IR、工具链、平台桥、HDFG 愿景。
3. 宽度类型全部不出现：u8/u16/u32/u64/i32 等宽度类型名与 `_u64` / `_i32` / `_f32` / `_f64` 后缀不在文档中出现。机器形状只用一句话说明，细节归 hw-map。
4. 不设「类型系统」概念：类型是图标注，接口是图上契约。文档只描写类型标注语法，不设类型系统章，不使用「类型系统」这一表述。
5. 要点解释标准：设计要点与语义解释以格形态为标准框架。三层映射为：图 `.cir` 对应关系空间，格 `.ccr` 对应存在空间，编码属于 hw-map 领域。语义保留指格全量表示类型和语义信息。正确性对全部可能执行成立。解释时不使用 CFG 或编译器视角。
6. 风格：以参考手册式为主，教程式为辅。每个语法构造都写语法形式、说明和示例。
7. 出处原则：关键字表以 `src/compiler/lexer.cr lookup_keyword()` 为准，优先级与语法形式以 `grammar/core.ebnf` 为准。两者冲突时，lexer.cr 和 parser.cr 优先于 EBNF。
8. 变更范围：只改 `docs/language-syntax.md` 一个文件。grammar/*.ebnf、源码和其他文档不动。
9. 提交：全部使用 `jj`（`jj commit -m "..." <path>`）。会话开始前已有未跟踪文件 `logs_90275072099.zip`，任何提交都不得包含它。

## 关键事实（已验证，直接使用）

关键字表（37 个，抄自 lexer.cr lookup_keyword()）：

```
fn mut return if else loop while for break continue
true false struct enum extern impl match import pub
go await unsafe flow yield interface type mod as
auto fileid move self in None Some unit
```

- `self` 是关键字（T_SELF）。`Self` 不是词法关键字，它是类型名，按标识符解析，checker 按上下文处理。
- `comptime` 不是关键字，`@comptime` 是 @ 内建。`requires/ensures/old/result` 不是词法关键字，属于规约语法，见 corespec.ebnf。
- 运算符记号：`*` 解引用、`&`/`&mut` 取地址、`->` 只用于返回类型、`:=` 声明、`..` 范围、`?` 可选与错误传播、`@` 内建前缀、`::` 路径、`as` 转换、`move` 移动。

表达式优先级链（grammar/core.ebnf），从低到高依次为：Assignment、LogicalOr、LogicalAnd、Equality、Comparison、Addition、Multiplication、Unary、CallOrField、Primary。

EBNF 关键产生式（grammar/core.ebnf，执行时通读全文）：

```
Type = BaseType | PathType | RefType | OptionalType | TupleType | ArrayType | SliceType ;
BaseType = 'int' | 'dex' | 'bool' | 'string' | 'char' | 'unit' | 'never' | 'Self' ;
RefType = '&' [ 'mut' ] Type ;
OptionalType = Type '?' ;
ArrayType = '[' Type ';' INT_LIT ']' ;
SliceType = '[' Type ']' ;
Let = IDENT [ ':' ( Type | 'auto' | '.' ) [ ',' Tag { ',' Tag } ] ] ( ':=' | '=' ) ;
Tag = 'mut' | 'pub' | 'apx' ;
```

拟定语法（本 spec 定稿，文档直接呈现）：

- where 值约束：`fn f(...) -> T where <布尔表达式> { ... }`，与 requires 同层。三档语义：常量约束在编译期报错或通过；符号约束成为 VC 义务；动态约束做运行时检查。
- 泛型接口绑定：`fn first[T: Eq](...)`，声明处做接口绑定，实例化时检查。编译期具体化，没有运行期字典。

---

### Task 1: 框架 + 设计要点 + 词法 + 模块（第 1-3 章）

文件：
- 重写：`docs/language-syntax.md`（整个文档从零写，本节覆盖第 1-3 章，含文件头）

接口：
- 读取：spec 的全局约束和关键事实
- 产出：文档框架（标题、13 章标题、关联文档链接），后续任务只填充各自章节

- [ ] Step 1: 通读事实源

Run: `sed -n '60,102p' grammar/core.ebnf && sed -n '71,115p' src/compiler/lexer.cr`
目的：确认 struct/enum/interface/import 等产生式与字面量 token 规则（INT_LIT/DEX_LIT/STRING_LIT/CHAR_LIT/UNIT_LIT 形式），供第 2、3 章使用。

- [ ] Step 2: 写文件头 + 第 1 章设计要点

先写 `docs/language-syntax.md` 的全文框架：13 章标题，每章放一行占位注释 `<!-- TODO taskN -->` 标记尚未写的章节。然后写以下内容：

- 标题 `# Core 语言语法`，附说明段：本文档描述 Core 语言的语法，即定案后的完整语言观。
- 一、设计要点（短文，以格形态为标准解释）：
  - 三层映射：图（`.cir`）表达结构，对应关系空间；格（`.ccr`）表达存在，对应状态空间（存在、条目、共存、驱逐）；编码是机器形状，属于 hw-map 领域。链接 `docs/memory-model-capability-lattice.md` 与 `docs/archive/2026-08-27-lattice-form-ir-design.md`。
  - 语义保留：格形态全量表示类型和语义信息，形式验证直接使用这些信息。正确性陈述对全部可能执行成立。
  - 没有独立的类型系统。类型是图标注，接口是图上契约，类型检查是图良构性验证。
  - 没有 `let` 关键字，声明使用 `:=`。没有生命周期标注，引用有效性由编译器推断。默认借用，需要时显式 `move`。
  - 编译时执行由格和图自动推导，无法推导时用 `@comptime` 标注。
- 二、词法：
  - 注释：`//` 单行，`/* */` 多行。
  - 标识符规则，对照 lexer：字母或下划线开头，后续为字母、数字、下划线。`lookup_keyword` 之外的标识符即普通标识符。
  - 关键字表：37 个，按关键事实清单列出，注明「以 lexer.cr lookup_keyword() 为准」。注明 `self` 是关键字，`Self` 不是词法关键字，comptime 不是关键字，requires/ensures 不是词法关键字。
  - 字面量：整数（十进制，进制前缀按 lexer 实际支持写）；小数（`3.14` 解析为 dex，即 DEX_LIT）；字符串（不可变 UTF-8）；字符；`true`/`false`；`()`（unit）；`None`/`Some`。
  - 运算符记号表：关键事实清单里的 10 个记号，一行一个或做成表格。
- 三、模块与导入（压缩自原 2.1-2.7，去掉「依赖裁剪」等工具链内容）：
  - `fileid "name"` 文件标识符，`mod` 模块声明，`import math` / `import math : m` / `import @acme math` / `import @acme math : m`。
  - `Path = IDENT { '::' IDENT }`，`::` 是文件内路径分隔符。
  - `_import.cr` 做目录级批量导入，继承合并，子目录覆盖，冲突报错。

- [ ] Step 3: 验证第 1-3 章

Run:
```bash
grep -n "类型系统" docs/language-syntax.md   # 除「无独立类型系统」表述外不得出现
grep -cE "^(#|##) " docs/language-syntax.md  # 检查标题结构
```
预期：「类型系统」只出现在「无独立类型系统」相关句。标题层级结构完整，有 13 个二级章标题，从 `## 一、` 到 `## 十三、`。

- [ ] Step 4: 提交

```bash
jj commit -m "docs: 语法文档重写（第 1-3 章：设计要点/词法/模块）" docs/language-syntax.md
```

---

### Task 2: 类型标注 + 变量声明 + 表达式 + 语句（第 4-7 章）

文件：
- 修改：`docs/language-syntax.md`（替换 Task 1 的占位注释行）

接口：
- 读取：Task 1 的框架与第 1-3 章
- 产出：第 4-7 章内容。第 4 章的类型表达式语法会被第 8-10 章引用，用于函数返回类型、接口和规约。

- [ ] Step 1: 写第 4 章类型标注语法

标题用「类型标注」或「类型语法」，不得叫「类型系统」。内容：

- 类型表达式：基础类型 `int`（整数，精确）、`dex`（精确小数，默认实数语义）、`bool`、`string`（不可变 UTF-8）、`char`（Unicode 标量）、`unit`（`()`）、`never`（发散）；另有 `dyn`（动态类型，链接 `docs/dynamic-typing.md`）和 `Self`（上下文类型，用于接口和方法签名内）。
- 复合类型：元组 `(T1, T2)`、数组 `[T; n]`、切片 `[T]`、可选 `T?`、引用 `&T` / `&mut T`。
- 接口作类型（`PathType`，链接第 9 章）。
- 标注位置：变量声明、函数参数、返回类型、泛型参数。
- 标签体系：`mut` / `pub` / `apx`。apx 表示近似授权，授权后端把 dex 运算降级到 binary64 快路径，与 mut、pub 同族。
- `auto` 与 `.`：类型推断占位，两者等价，用于变量与返回类型。
- 宽度只写一句：机器形状（位宽）由编码层按目标自动决定，将来需要显式控制时走 hw-map。文档中不出现任何宽度类型名。

- [ ] Step 2: 写第 5 章变量声明

- `x := 42;` 推断为不可变；`x : int = 42;` 显式类型；`x : ., mut = 0;` 带标签；`a, b : int = 1, 2;` 批量声明。
- `auto` 与 `.` 占位，引用第 4 章。
- `move x` 显式移动。默认借用语义，没有 let，没有生命周期标注。

- [ ] Step 3: 写第 6 章表达式与运算符

- 优先级链按关键事实清单写，Assignment 最低，Primary 最高。用表格或层级列表，每个运算符配一行示例：
  - `=` 赋值、`:=` 声明、`||`、`&&`、`==`/`!=`、`<`/`>`/`<=`/`>=`、`+`/`-`、`*`/`/`/`%`、`-`/`!`/`&`/`&mut`（一元）、调用/字段/下标/`?`。
  - `as` 类型转换（`expr as T`）。
  - 语句性表达式：block、if、match、loop、for、go、await、unsafe（链接第 7、11、12 章）。
  - `?` 错误传播只能用于返回 Result 的函数。Result 是语言内建概念，按定案接口注册表 int/dex/string 原生条目处理。这里只写「错误传播 `?`」的语法行为，不写 Result 枚举定义。

- [ ] Step 4: 写第 7 章语句与控制流

- `if` / `else if` / `else`，含表达式用法；`loop`，含 `break`/`continue`；`while`；`for`，形式为 `for i in 0..10` 和 `for item in items`。
- `match` 做穷尽匹配。字符串常量分支自动生成哈希跳转表，这段作为语义说明保留原文档的写法。
- `return`；`unsafe { }` 块（链接第 12 章）。
- 所有示例只用 int/dex/string/bool/char 加复合类型。

- [ ] Step 5: 验证第 4-7 章

Run:
```bash
grep -nE "u8|u16|u32|u64|i8|i16|i32|i64|f32|f64" docs/language-syntax.md
grep -nE "vec!|HashMap|HashSet|chan" docs/language-syntax.md
```
预期：两组都没有输出，宽度类型与标准库示例零残留。

- [ ] Step 6: 提交

```bash
jj commit -m "docs: 语法文档重写（第 4-7 章：类型标注/声明/表达式/控制流）" docs/language-syntax.md
```

---

### Task 3: 函数 + 接口泛型 + 规约（第 8-10 章）

文件：
- 修改：`docs/language-syntax.md`

接口：
- 读取：第 4 章的类型表达式语法，用于返回类型、泛型参数和接口作类型。
- 产出：第 9 章接口与泛型、第 10 章规约。第 9 章会被第 12 章 RawRef 和第 13 章 @typeInfo 引用，第 10 章由第 6 章 `?` 的错误语义支撑。

- [ ] Step 1: 写第 8 章函数与方法

- `fn name(params) -> Type { ... }`；单行形式 `fn name(params) -> Type = expr;`；`-> auto` 表示返回类型推断。
- 参数列表写作 `name: Type`。
- `impl Type { fn ... }` 定义方法，接收者为 `self` / `&self` / `&mut self`。
- 示例：`fn add(a: int, b: int) -> int { return a + b; }`、`fn pi() -> auto = 3.14159;`、`impl Point { fn norm(&self) -> dex { ... } }`。

- [ ] Step 2: 写第 9 章接口与泛型

- `interface Name { fn sig; ... }` 声明，`impl Name for Type { ... }` 实现。
- 泛型：`fn first[T](...)`，声明处绑定接口 `[T: Eq]`，这是拟定语法，直接呈现。实例化时检查接口实现，编译期具体化，没有运行期字典。
- 示例：`interface Eq { fn eq(&self, other: &Self) -> bool; }` 加 `fn first[T: Eq](list: &[T]) -> T?`。不使用宽度类型，`?` 链接第 6 章。
- 链接类型方向的定案 `docs/superpowers/specs/2026-08-30-type-system-direction-design.md`，其中接口是图上契约。

- [ ] Step 3: 写第 10 章规约

- `requires` / `ensures` / `old(expr)` / `result`：附加在函数签名后的规约，例如 `fn divide(...) -> int? requires b != 0 ensures ... { ... }`。规约参与静态检查，不影响运行时性能。链接 `docs/spec-design.md` 与 `grammar/corespec.ebnf`。
- where 值约束（拟定语法）：`fn f(x: int) where x > 0 { ... }`，与 requires 同层。三档语义：常量约束在编译期报错或通过；符号约束成为 VC 义务，由验证管线消费；动态约束做运行时检查，避免证明不了时不报错地通过。与 .corespec 前置条件映射，一条语法，两层消费：checker 和 VC。

- [ ] Step 4: 验证第 8-10 章

Run:
```bash
grep -nE "u8|u16|u32|u64|i8|i16|i32|i64|f32|f64" docs/language-syntax.md
```
预期：无输出。另外通读第 9、10 章，检查接口示例没有宽度类型，where 语法形式为 `where <expr>`。

- [ ] Step 5: 提交

```bash
jj commit -m "docs: 语法文档重写（第 8-10 章：函数/接口泛型/规约）" docs/language-syntax.md
```

---

### Task 4: 并发 + 指针 unsafe + @ 内建 + 全文验证（第 11-13 章 + 结束）

文件：
- 修改：`docs/language-syntax.md`

接口：
- 读取：Task 1-3 的全部章节
- 产出：完整文档，即最终交付物

- [ ] Step 1: 写第 11 章并发

- `go expr` 异步启动，例如 `handle := go f(...)`；`await handle` 阻塞等待，需要时自动等待。
- `flow name(...) -> T { yield v; }` 定义长期执行流；`recv()` 接收。
- 示例：`flow counter(start: int) -> int { ... yield n; ... }`、`f := go counter(0);`、`v := f.recv();`。
- 只写语法与行为，不写「HDFG 视图」愿景节。

- [ ] Step 2: 写第 12 章指针与 unsafe

- `&expr` 取地址并记录 provenance；`*p` 解引用，验证 offset ∈ [0, len)；指针偏移运算；`cast<T*>(addr)` 显式转换。
- 原始指针的自由度与 C 相同，编译器通过格和图自动验证安全（链接 `docs/pointer-model.md`）。
- `unsafe { }` 块用于 RawRef 使用、外部 C 调用和编译器固有操作。RawRef 不能逃逸到安全代码。
- 示例：`p := &arr[0]; x := *p;` 等，不使用宽度类型。

- [ ] Step 3: 写第 13 章 @ 内建原语

- 三类：元数据查询（`@sizeOf` `@alignOf` `@fields` `@field` `@hasField` `@typeInfo`）、编译控制（`@inline` `@unroll` `@section` `@comptime`）、安全检查（`@no_bounds_check`，属 unsafe 范畴）。链接 `docs/at-intrinsics.md`。

- [ ] Step 4: 全文验证（逐条执行 spec 验证清单）

Run:
```bash
echo "=== 1. 宽度/标准库残留 ===" && grep -nE "u8|u16|u32|u64|i8|i16|i32|i64|f32|f64|vec!|HashMap|HashSet|chan" docs/language-syntax.md
echo "=== 2. 实现状态标注 ===" && grep -nE "已实现|未实现|待实现" docs/language-syntax.md
echo "=== 3. 类型系统概念（仅允许「无独立类型系统」句）===" && grep -n "类型系统" docs/language-syntax.md
echo "=== 4. 章结构 ===" && grep -nE "^## " docs/language-syntax.md
echo "=== 5. 关键字表 ===" && grep -n "37" docs/language-syntax.md
echo "=== 6. 表格断裂检查 ===" && grep -n "| unit" docs/language-syntax.md
```
预期：
1. 无输出
2. 无输出
3. 只出现在第 1 章「无独立类型系统」句
4. 输出 13 个二级标题：一、设计要点 … 十三、@ 内建原语
5. 「37 个关键字」字样出现在词法章
6. 没有孤立表格行，表格内行 `| unit |` 前后有表头或分隔行

- [ ] Step 5: 通读全文最终校对

Read: `docs/language-syntax.md`（全文）
检查：没有占位注释残留（`<!-- TODO taskN -->` 全部清除）；每个构造都有语法形式、说明和示例；示例可读；没有标准库或愿景内容；第 1 章以格形态解释。

- [ ] Step 6: 提交

```bash
jj commit -m "docs: 语法文档重写完成（第 11-13 章 + 全文验证通过）" docs/language-syntax.md
```
