# language-syntax.md 重写实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 `docs/language-syntax.md` 重写为 13 章参考手册式语法文档（定案后的完整语言，以格形态为标准解释，不标实现状态）。

**Architecture:** 单文件文档重写。按内容群分 4 个任务顺序书写：骨架+设计要点+词法+模块 → 类型标注+声明+表达式+控制流 → 函数+接口泛型+规约 → 并发+指针+内建+全文验证。每个任务自带验证（grep 检查 + 章节内容核对），最后一个任务执行 spec 的完整验证清单。

**Tech Stack:** Markdown（无代码、无编译；验证用 grep）。版本控制用 `jj`（铁律 #2，禁止 git）。

**Spec:** `docs/superpowers/specs/2026-09-01-syntax-doc-rewrite-design.md`

## Global Constraints

（逐条抄自 spec，所有任务隐式包含）

1. **定位**：定案后的完整语言，当前实现与未来设计统一呈现，全文不出现「已实现 / 未实现 / 待实现」标注。
2. **边界**：语言本体（语法为准）。不含标准库表层（HashMap / HashSet / 通道 / Result）、IR、工具链、平台桥、HDFG 愿景。
3. **宽度类型全面消失**：u8/u16/u32/u64/i32 等宽度类型名与 `_u64` / `_i32` / `_f32` / `_f64` 后缀不在文档中出现；机器形状一句话带过（归 hw-map）。
4. **无「类型系统」概念**：类型 = 图标注、接口 = 图上契约；文档只描写「类型标注语法」，不设类型系统章、不使用「类型系统」表述。
5. **要点解释标准**：设计要点与语义解释以格形态为标准框架（三层映射：图 `.cir` = 关系空间 / 格 `.ccr` = 存在空间 / 编码 = hw-map 领域；语义保鲜 = 格全量承载类型/语义信息；正确性对全部可能执行成立），不用 CFG/编译器视角。
6. **风格**：参考手册式为主，教程式为辅。每个语法构造 = 语法形式 + 说明 + 示例。
7. **出处原则**：关键字表以 `src/compiler/lexer.cr lookup_keyword()` 为准；优先级与语法形式以 `grammar/core.ebnf` 为准；冲突时 lexer.cr / parser.cr 优先于 EBNF。
8. **变更范围**：仅改 `docs/language-syntax.md` 一个文件。grammar/*.ebnf、源码、其他文档不动。
9. **提交**：全部用 `jj`（`jj commit -m "..." <path>`）。会话开始前已有未跟踪文件 `logs_90275072099.zip`，任何提交不得包含它。

## 关键事实（已验证，直接使用）

**关键字表（37 个，抄自 lexer.cr lookup_keyword()）：**

```
fn mut return if else loop while for break continue
true false struct enum extern impl match import pub
go await unsafe flow yield interface type mod as
auto fileid move self in None Some unit
```

- `self` 是关键字（T_SELF）；`Self` 非词法关键字（类型名，按标识符解析，checker 按上下文处理）。
- `comptime` 不是关键字（`@comptime` 是 @ 内建）；`requires/ensures/old/result` 非词法关键字（规约语法，见 corespec.ebnf）。
- 运算符记号：`*` 解引用、`&`/`&mut` 取地址、`->` 仅返回类型、`:=` 声明、`..` 范围、`?` 可选与错误传播、`@` 内建前缀、`::` 路径、`as` 转换、`move` 移动。

**表达式优先级链（grammar/core.ebnf）：**

```
Assignment → LogicalOr → LogicalAnd → Equality → Comparison
→ Addition → Multiplication → Unary → CallOrField → Primary
```

**EBNF 关键产生式（grammar/core.ebnf，执行时通读全文）：**

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

**拟定语法（本 spec 定稿，文档直接呈现）：**

- where 值约束：`fn f(...) -> T where <布尔表达式> { ... }`（与 requires 同层），三档语义：常量约束 → 编译错误/通过；符号约束 → VC 义务；动态约束 → 运行时检查。
- 泛型接口绑定：`fn first[T: Eq](...)`，声明处接口绑定 + 实例化检查，编译期具体化，无运行期字典。

---

### Task 1: 骨架 + 设计要点 + 词法 + 模块（第 1-3 章）

**Files:**
- Rewrite: `docs/language-syntax.md`（本文档整个重写，从零写；本节覆盖第 1-3 章，含文件头）

**Interfaces:**
- Consumes: spec 的 Global Constraints + 关键事实
- Produces: 文档骨架（标题 + 13 章标题 + 关联文档链接），后续任务只填充各自章节

- [ ] **Step 1: 通读事实源**

Run: `sed -n '60,102p' grammar/core.ebnf && sed -n '71,115p' src/compiler/lexer.cr`
目的：确认 struct/enum/interface/import 等产生式与字面量 token 规则（INT_LIT/DEX_LIT/STRING_LIT/CHAR_LIT/UNIT_LIT 形式），供第 2、3 章使用。

- [ ] **Step 2: 写文件头 + 第 1 章设计要点**

写 `docs/language-syntax.md` 全文框架（13 章标题 + 每章占位注释行 `<!-- TODO taskN -->` 标记未写章节），然后立即写：

- 标题 `# Core 语言语法` + 说明段：本文档描述 Core 语言的语法（定案后的完整语言观）。
- **一、设计要点**（短文，以格形态为标准解释）：
  - 三层映射：图（`.cir`）= 结构表达（关系空间）→ 格（`.ccr`）= 存在表达（状态空间：存在/条目/共存/驱逐）→ 编码 = 机器形状（hw-map 领域）。链接 `docs/memory-model-capability-lattice.md` 与 `docs/superpowers/specs/2026-08-27-lattice-form-ir-design.md`。
  - 语义保鲜：格形态全量承载类型/语义信息，形式验证直接消费；正确性陈述对全部可能执行成立。
  - 无独立类型系统（类型 = 图标注、接口 = 图上契约、类型检查 = 图良构性验证）。
  - 无 `let` 关键字（`:=` 声明）、无生命周期标注（引用有效性编译器全权推断）、默认借用 + 显式 `move`。
  - 编译时执行由格/图自动推导，`@comptime` 兜底。
- **二、词法**：
  - 注释：`//` 单行、`/* */` 多行。
  - 标识符规则（对照 lexer：字母/下划线开头，字母数字下划线；`lookup_keyword` 之外的即标识符）。
  - 关键字表：37 个，按关键事实清单列出，注明「以 lexer.cr lookup_keyword() 为准」；注 `self` 是关键字、`Self` 非词法关键字、comptime 非关键字、requires/ensures 非词法关键字。
  - 字面量：整数（十进制；进制前缀按 lexer 实际支持写）、小数（`3.14` → dex，DEX_LIT）、字符串（不可变 UTF-8）、字符、`true`/`false`、`()`（unit）、`None`/`Some`。
  - 运算符记号表（关键事实清单里 10 个记号，一行一个或表格）。
- **三、模块与导入**（压缩自原 2.1-2.7，去「依赖裁剪」等工具链内容）：
  - `fileid "name"` 文件标识符、`mod` 模块声明、`import math` / `import math : m` / `import @acme math` / `import @acme math : m`。
  - `Path = IDENT { '::' IDENT }`（`::` 文件内路径分隔符）。
  - `_import.cr` 目录级批量导入（继承合并，子目录覆盖，冲突报错）。

- [ ] **Step 3: 验证第 1-3 章**

Run:
```bash
grep -n "类型系统" docs/language-syntax.md   # 除「无独立类型系统」表述外不得出现
grep -cE "^(#|##) " docs/language-syntax.md  # 检查标题结构
```
Expected: 「类型系统」仅出现在「无独立类型系统」相关句；标题层级结构完整（13 个二级章标题 `## 一、` 到 `## 十三、`）。

- [ ] **Step 4: 提交**

```bash
jj commit -m "docs: 语法文档重写（第 1-3 章：设计要点/词法/模块）" docs/language-syntax.md
```

---

### Task 2: 类型标注 + 变量声明 + 表达式 + 语句（第 4-7 章）

**Files:**
- Modify: `docs/language-syntax.md`（替换 Task 1 的占位注释行）

**Interfaces:**
- Consumes: Task 1 的骨架与第 1-3 章
- Produces: 第 4-7 章内容；第 4 章的类型表达式语法被第 8-10 章引用（函数返回类型、接口、规约）

- [ ] **Step 1: 写第 4 章类型标注语法**

标题用「**类型标注**」或「**类型语法**」，不得叫「类型系统」。内容：
- 类型表达式：基础类型 `int`（整数，精确）/ `dex`（精确小数，默认实数语义）/ `bool` / `string`（不可变 UTF-8）/ `char`（Unicode 标量）/ `unit`（`()`）/ `never`（发散）+ `dyn`（动态类型，链接 `docs/dynamic-typing.md`）+ `Self`（上下文类型，接口/方法签名内）。
- 复合类型：元组 `(T1, T2)`、数组 `[T; n]`、切片 `[T]`、可选 `T?`、引用 `&T` / `&mut T`。
- 接口作类型（`PathType`，链接第 9 章）。
- 标注位置：变量声明、函数参数、返回类型、泛型参数。
- 标签体系：`mut` / `pub` / `apx`（apx = 近似授权，授权后端把 dex 运算降级 binary64 快路径；与 mut/pub 同族）。
- `auto` 与 `.`：类型推断占位，两者等价；用于变量与返回类型。
- 宽度说明一句：机器形状（位宽）由编码层按目标自动决定，未来显式控制走 hw-map——不出现任何宽度类型名。

- [ ] **Step 2: 写第 5 章变量声明**

- `x := 42;` 推断不可变；`x : int = 42;` 显式类型；`x : ., mut = 0;` 标签；`a, b : int = 1, 2;` 批量。
- `auto` 与 `.` 占位（引用第 4 章）。
- `move x` 显式移动（默认借用语义，无 let、无生命周期标注）。

- [ ] **Step 3: 写第 6 章表达式与运算符**

- 优先级链按关键事实清单（Assignment 最低到 Primary 最高），表格或层级列表 + 每个运算符一行示例：
  - `=`（赋值）、`:=`（声明）、`||`、`&&`、`==`/`!=`、`<`/`>`/`<=`/`>=`、`+`/`-`、`*`/`/`/`%`、`-`/`!`/`&`/`&mut`（一元）、调用/字段/下标/`?`。
  - `as` 类型转换（`expr as T`）。
  - 语句性表达式：block、if、match、loop、for、go、await、unsafe（链接第 7、11、12 章）。
  - `?` 错误传播：只能用于返回 Result 的函数中（Result 是语言内建概念——按定案接口注册表 int/dex/string 原生条目，「错误传播 `?`」写语法行为即可，不写 Result 枚举定义）。

- [ ] **Step 4: 写第 7 章语句与控制流**

- `if` / `else if` / `else`（含表达式用法）；`loop`（含 `break`/`continue`）；`while`；`for`（`for i in 0..10`、`for item in items`）。
- `match` 穷尽匹配；字符串常量分支自动哈希跳转表（作为语义说明保留原文档这段）。
- `return`；`unsafe { }` 块（链接第 12 章）。
- 所有示例只用 int/dex/string/bool/char + 复合类型。

- [ ] **Step 5: 验证第 4-7 章**

Run:
```bash
grep -nE "u8|u16|u32|u64|i8|i16|i32|i64|f32|f64" docs/language-syntax.md
grep -nE "vec!|HashMap|HashSet|chan" docs/language-syntax.md
```
Expected: 两组均无输出（宽度类型与标准库示例零残留）。

- [ ] **Step 6: 提交**

```bash
jj commit -m "docs: 语法文档重写（第 4-7 章：类型标注/声明/表达式/控制流）" docs/language-syntax.md
```

---

### Task 3: 函数 + 接口泛型 + 规约（第 8-10 章）

**Files:**
- Modify: `docs/language-syntax.md`

**Interfaces:**
- Consumes: 第 4 章类型表达式语法（返回类型、泛型参数、接口作类型）
- Produces: 第 9 章接口与泛型（被第 12 章 RawRef 与第 13 章 @typeInfo 引用）、第 10 章规约（被第 6 章 `?` 的错误语义支撑）

- [ ] **Step 1: 写第 8 章函数与方法**

- `fn name(params) -> Type { ... }`；单行形式 `fn name(params) -> Type = expr;`；`-> auto` 返回推断。
- 参数 `name: Type` 列表。
- `impl Type { fn ... }` 方法；`self` / `&self` / `&mut self` 接收者。
- 示例：`fn add(a: int, b: int) -> int { return a + b; }`、`fn pi() -> auto = 3.14159;`、`impl Point { fn norm(&self) -> dex { ... } }`。

- [ ] **Step 2: 写第 9 章接口与泛型**

- `interface Name { fn sig; ... }` 声明；`impl Name for Type { ... }` 实现。
- 泛型：`fn first[T](...)` 声明处接口绑定 `[T: Eq]`（拟定语法，直接呈现）；实例化时检查接口实现，编译期具体化，无运行期字典。
- 示例：`interface Eq { fn eq(&self, other: &Self) -> bool; }` + `fn first[T: Eq](list: &[T]) -> T?`（不用宽度类型，`?` 链接第 6 章）。
- 链接类型方向定案 `docs/superpowers/specs/2026-08-30-type-system-direction-design.md`（接口 = 图上契约）。

- [ ] **Step 3: 写第 10 章规约**

- `requires` / `ensures` / `old(expr)` / `result`：附加在函数签名后的规约（`fn divide(...) -> int? requires b != 0 ensures ... { ... }`），参与静态检查，不影响运行时性能。链接 `docs/spec-design.md` 与 `grammar/corespec.ebnf`。
- **where 值约束（拟定语法）**：`fn f(x: int) where x > 0 { ... }`——与 requires 同层；三档语义：常量约束 → 编译错误/通过；符号约束 → VC 义务（验证管线消费）；动态约束 → 运行时检查（防「证明不了也不静默」）。与 .corespec 前置条件映射（一条语法，两层消费：checker + VC）。

- [ ] **Step 4: 验证第 8-10 章**

Run:
```bash
grep -nE "u8|u16|u32|u64|i8|i16|i32|i64|f32|f64" docs/language-syntax.md
```
Expected: 无输出。另通读第 9、10 章检查：接口示例无宽度类型、where 语法形式为 `where <expr>`。

- [ ] **Step 5: 提交**

```bash
jj commit -m "docs: 语法文档重写（第 8-10 章：函数/接口泛型/规约）" docs/language-syntax.md
```

---

### Task 4: 并发 + 指针 unsafe + @ 内建 + 全文验证（第 11-13 章 + 收尾）

**Files:**
- Modify: `docs/language-syntax.md`

**Interfaces:**
- Consumes: Task 1-3 全部章节
- Produces: 完整文档（最终交付物）

- [ ] **Step 1: 写第 11 章并发**

- `go expr`（异步启动，`handle := go f(...)`）；`await handle`（阻塞等待；按需自动等待）。
- `flow name(...) -> T { yield v; }` 长期执行流；`recv()` 接收。
- 示例：`flow counter(start: int) -> int { ... yield n; ... }` + `f := go counter(0);` + `v := f.recv();`。
- 只写语法与行为，不写「HDFG 视图」愿景节。

- [ ] **Step 2: 写第 12 章指针与 unsafe**

- `&expr` 取地址（provenance 记录）、`*p` 解引用（验证 offset ∈ [0, len)）、指针偏移运算、`cast<T*>(addr)` 显式转换。
- 裸指针自由与 C 同级，编译器通过格/图自动验证安全（链接 `docs/pointer-model.md`）。
- `unsafe { }` 块：RawRef 使用、外部 C 调用、编译器固有；RawRef 无法逃逸到安全代码。
- 示例：`p := &arr[0]; x := *p;` 等（无宽度类型）。

- [ ] **Step 3: 写第 13 章 @ 内建原语**

- 三类：元数据查询（`@sizeOf` `@alignOf` `@fields` `@field` `@hasField` `@typeInfo`）/ 编译控制（`@inline` `@unroll` `@section` `@comptime`）/ 安全检查（`@no_bounds_check`，unsafe 范畴）。链接 `docs/at-intrinsics.md`。

- [ ] **Step 4: 全文验证（spec 验证清单逐条执行）**

Run:
```bash
echo "=== 1. 宽度/标准库残留 ===" && grep -nE "u8|u16|u32|u64|i8|i16|i32|i64|f32|f64|vec!|HashMap|HashSet|chan" docs/language-syntax.md
echo "=== 2. 实现状态标注 ===" && grep -nE "已实现|未实现|待实现" docs/language-syntax.md
echo "=== 3. 类型系统概念（仅允许「无独立类型系统」句）===" && grep -n "类型系统" docs/language-syntax.md
echo "=== 4. 章结构 ===" && grep -nE "^## " docs/language-syntax.md
echo "=== 5. 关键字表 ===" && grep -n "37" docs/language-syntax.md
echo "=== 6. 表格断裂检查 ===" && grep -n "| unit" docs/language-syntax.md
```
Expected:
1. 无输出
2. 无输出
3. 仅出现在第 1 章「无独立类型系统」句
4. 输出 13 个二级标题：一、设计要点 … 十三、@ 内建原语
5. 「37 个关键字」字样出现于词法章
6. 无孤立表格行（表格内行 `| unit |` 前后有表头/分隔行）

- [ ] **Step 5: 通读全文最终校对**

Read: `docs/language-syntax.md`（全文）
检查：无占位注释残留（`<!-- TODO taskN -->` 全部清除）、每个构造有「语法形式 + 说明 + 示例」、示例可读、无标准库/愿景内容、第 1 章以格形态解释。

- [ ] **Step 6: 提交**

```bash
jj commit -m "docs: 语法文档重写完成（第 11-13 章 + 全文验证通过）" docs/language-syntax.md
```
