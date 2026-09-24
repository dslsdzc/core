# v4 布局规格（T0 产物）

> **本档的地位**：本档是施工计划 §三（T0）的产物。计划是权威，本档是它的落成文本。
> 计划出处 = `docs/superpowers/plans/2026-09-24-v4-syntax-migration.md`（已合入 `develop`）。
> **写裁定的事在这里写死；不要在本档里重新论证维护者已经定下的裁定。**
>
> **基线**：本档全部读数在 `develop@origin` = `e08df3d9` 上取。
> 每一条 `file:line` 与每一个计数都附了取数命令（§9）。**任何一处读数在别的修订上都要现查现用**。

---

## 0. 边界、术语与纪律

### 0.1 本档管什么、不管什么

| 管 | 不管 |
|---|---|
| 判定 ①–⑤ 的**唯一措辞**（§1–§5） | 实现（T1/T2 的 Python 前端、T5 的自源 parser） |
| 判据 J-T0-1…J-T0-5 与 J-T0-2b 的定义（§6） | 判据的实现（除本档新建的探针，见 §6.1/§6.2b） |
| 拼接场景（45 档 → 1 单元）的 layout 成立条件 | 语料改写的机械化（T4）与 `tokenize()` 逐点复核（T5） |

**五条判定的裁定状态：全部已落。** 判定 ② 原为占位（计划留给维护者），
**维护者已裁定取 (b) 词法位置决定**，本档据裁定把 §2 写成完整判定，
并写死它带来的两条连带后果（§2.2 行尾标注的处置 · §2.3 行尾判定穿过注释）。
其余四条按原裁定写死。

### 0.2 术语

本档用 #160 之后的词：**出处**（不写「真源」）· **清单**（不写「台账」）· **约定**（不写「口径」）·
**正反两条断言**（不写「两向钉子」）· **检查 / 标记 / 探针**（不写「哨兵」）·
**写进文档**（不写「落纸」）· **收尾**（不写「收口」）。

沿用计划 §二 的 `[我·实核]` / `[代读]` / `[推理]` 三级标注。**本档新增的读数一律 `[T0·实核]`**，
并附命令；**未复核的一律进 §8**。

### 0.3 零构建纪律

本档**零构建**（不跑 `python3 build_selfhost_native.py`，不跑 `./build/corec`）。
需构建才能定论的条目写「**需构建才能定论**」+ 命令，命令一律带 `nice -n 19`（铁律 6）。

### 0.4 一条贯穿全档的技术事实（layout 的机件现状）

`[T0·实核]` `src/compiler/lexer.cr`：`g_line`/`g_col` 存在、列维护正确、逐 token 带行列；
**INDENT/DEDENT/NEWLINE 发射 = 0 处**。⇒ layout 的成本是「把 `skip_ws`（`lexer.cr:338-360`）
从无状态改成有状态」，不是造列号机制。本档的判定全部落在这条现状之上。

---

## 1. 判定 ①：空行与注释行在 layout 里的地位

**为什么它排第一**：`[T0·实核]` `build_selfhost_native.py:154` 在**列 0** 插分隔符
`// === {f} ===`，把 45 档拼成 1 个编译单元；`:155` 用 `'\n\n'.join(parts)`；
`:157` 追加 wrapper 行。**45 档拼接处若被 layout 吞掉下一个档的首行，是静默错答案，不是 parse error。**

### 1.1 判定（三条，每条唯一措辞）

**①-1 空行**（只含空白字符的行，含只含 `\r` 的行）：

1. **不产生任何 token**；
2. **不改变当前 layout anchor**；
3. **不参与「首个非空行建立 anchor」的计数**。

**①-2 只含注释的行**（行内除注释外无 code；**包括** `/* */` 块注释的续行、以及一行里只有多个注释的情形）：
**完全等同于空行** —— ①-1 的三条**全部适用**，一字不改。

**①-3 行尾注释**（形如 `code() // note` 或 `code() /* note */`）：
**不改变该行的 anchor 列**。anchor 列 ≡ 该行**首个 token** 的列（不是注释的列，也不是行首空白的宽度）。

### 1.2 由三条判定推出的两条结论（都已实测，见 §6.1）

**结论 A（T3 必须知道）**：拼接分隔符 `// === {f} ===` 的**列不影响 layout**。
由 ①-2 直接推出，并已由 J-T0-1 的两格实测确认：分隔符在**列 0** 与在**列 4** 都得同一个结果（§6.1 矩阵第 1、3 行）。
⇒ **T3 不需要为了 layout 把分隔符钉在列 0**；钉在列 0 仍然是对的，但理由是「可读性」，不是 layout 正确性。

**结论 B（真正的承重条件）**：拼接分隔符**必须保持「只含注释」这一属性**。
一旦它不是注释行（例如变成 `x := 1`），它就成为**一条真实的顶层语句** ⇒
拼接后的顶层声明数比两个档之和多出「分隔符条数」（§6.1 矩阵「非注释分隔符」格：35 → 37）。

### 1.3 对 T3 的硬约束（写死）

| # | 约束 | 判据 |
|---|---|---|
| 1 | 分隔符行**必须只含注释**（现行 `// === {f} ===` 满足） | J-T0-1 |
| 2 | 拼接的每一档内容仍须**行级剥 `import `**（`build_selfhost_native.py:150-153`），三处 concat 同改 | 计划 §五 |
| 3 | **wrapper 行必须改成 v4 形**（`build_selfhost_native.py:157` 是 f-string 发的 v3 花括号源） | 计划 §五（承重的一行） |

> ⚠ 约束 3 是**拼接面唯一会让链在第一步就断的一行**：它是 Python 直接发出的 Core 源，
> 不经过任何语料改写。本档只登记它，不改它（T3 的工作）。

---

## 2. 判定 ②：`:` 的双义消解

### 2.1 裁定：取 (b) 词法位置决定（唯一措辞）

> **lexer 按「`:` 之后同一物理行内是否还有 token」发两种 token：**
> **行尾 `:` ⇒ `T_COLON_BLOCK`（region 开启）· 行内 `:` ⇒ `T_COLON_DECL`（类型标注分隔符）。**
> **这两种 token 的集合互斥且穷尽 ⇒ parser 侧零前瞻。**

原 `T_COLON`（`src/compiler/ast.cr`）由这两个 token 取代；`T_COLON_EQ`（`:=`）不受影响
（`:=` 是**单个** token，见 §2.3 的扫描：`:` 后紧跟 `=` 时不属于本判定）。

**「行内/行尾」的精确判定（写死）**：

> `:` **是行尾的** ⟺ 该 **`:` 之后、到该物理行行尾为止，不存在任何 token**。

空白不计；**注释不计**（见 §2.4）。

### 2.2 连带后果 ①：「行尾的类型标注」的处置（唯一措辞）

> **条款：声明标注的 `:` **必须**行内有后继 token；行尾 `:` **一律**是 region 开启。**

⇒ **「行尾标注」这种写法不是本语言的合法文本**：lexer 必然把它读成 `T_COLON_BLOCK`，
而该位置不是合法 region 头 ⇒ **parser 必须响亮拒绝**（`rc=1` + 诊断码，**不得**静默改判成声明）。
⇒ 因此 (b) 的判别是**完备的**：`:` 的行内/行尾与 DECL/BLOCK **一一对应**，规格不需要任何例外表。

**逐形扫描（现行形 + v4 目标形，逐形给出 `:` 落在行内还是行尾）**：

| # | 形 | 例（v4 目标形） | 该 `:` 的位置 | 目标出处 |
|---|---|---|---|---|
| D1 | 变量标注 | `x : int = 5` | **行内**（Type 随后） | v4 §4 |
| D2 | 标签形 | `count : int, mut = 0` | **行内**（Type + `,` 标签随后） | v4 §3.8 |
| D3 | 批量形 | `a, b : int = 1, 2` | **行内** | v4 §4 |
| D4 | 字段形 | `id: int` | **行内** | v4 §9.1 |
| D5 | 形参形 | `a: int` | **行内** | v4 §8.1 |
| D6 | 形参表跨行 | `fn f(a: int,` ／ `     b: int):` | 第 1 行的 `:` **行内**；**终结 `:` 在续行行尾**（region 开启） | v4 §8.1 |
| D7 | import 别名 | `import math : m` | **行内**（别名随后） | v4 §2.3 |
| D8 | `mod` 路径 | `mod examples::pi` | **无单 `:`**（`::` 是路径分隔符，不是 `T_COLON`） | v4 §2.2 |
| D9 | 函数体开启 | `fn add(a: int, b: int) -> int:` | **行尾（有意 = region 开启）** | v4 §8.1 |
| D10 | 无体函数 | `extern fn read(fd: int) -> int` | **无 `:`** | v4 §8.1 |
| D11 | 接口方法 | `fn eq(&self, o: &Self) -> bool` | **无 `:`** | v4 §9.3 |
| D12 | lambda | `f := fn(x: int) -> int:` | **行尾（有意）** | v4 §5.4 |
| D13 | region 开启 | `if c:` `loop:` `match x:` `struct S:` `enum E:` `impl T:` `catch:` `unsafe:` | **行尾（有意）** | v4 §1.6 等 |

**反例扫描结果（`[T0·实核]`，命令见 §9）：零反例。**

| 面 | 规模 | 行尾 `:` | 其中「声明标注」 |
|---|---|---|---|
| 现行语料（v3） | **227 档** `.cr` | **0** | **0**（v3 用花括号开 region，连 region 开启都没有行尾 `:`） |
| v4 目标（原档的 core 代码块） | 77 个块 | **57** | **0**（57 处逐处是 region 开启：`fn`/`struct`/`enum`/`impl`/`match`/`catch`/lambda/`spec fn`） |

⇒ **条款无需例外**。D1–D7 的 `:` 后面**语法上必有** Type / 别名 / 标签，
所以「行内」是语法强制的，不是书写风格问题；**若作者把 Type 写到下一行，那段文本非法**（响亮拒绝）。

> ⚠ **一处必须写明的实现风险（扫描发现）**：形如
> ```
> fn f(a:
>      int):
> ```
> 的**形参标注**断行，**lexer 层无法与** `fn f() -> int:` 的**头部终结**区分
> —— 两者都是「`fn` 开头、行尾 `:`」，lexer 只看位置 ⇒ 两者都发 `T_COLON_BLOCK`。
> **这个形态的正确处置不是「让 lexer 变聪明」，而是靠语法面兜住**：
> parser 在形参位期望 `T_COLON_DECL` 却拿到 `T_COLON_BLOCK` ⇒ **亮错**（正是 §2.2 条款要的「响亮拒绝」）。
> ⇒ **lexer 不需要括号配平，规格也不要求它配平**（这是 (b) 之所以便宜的原因）。
> 「括号是否配平」只是**本档探针**在离线判定时用来把这一格从「合法头部终结」里挑出来的方法
> （见 `tools/v4_layout_probe.py` 的 `_balanced`），**不是给实现的约束**。
> ⇒ **判据 J-T0-2b 的族一夹具里就有这一格**，且它**必须红**。

### 2.3 连带后果 ②：行尾判定必须穿过行尾注释（与判定 ① 对齐）

> **条款：判「行尾」时，从 `:` 之后跳过空白与注释；若再无 token ⇒ 行尾。**

| 输入 | 判定 | 结果 |
|---|---|---|
| `fn f(): // note` | `// note` 是注释 ⇒ 不计 token ⇒ 无后继 token | **行尾** ⇒ `T_COLON_BLOCK`（region 开启） |
| `x : int = 5 // note` | `int` 已是后继 token | **行内** ⇒ `T_COLON_DECL` |
| `fn f(): /* note */` | 块注释 ⇒ 不计 token | **行尾** |
| `fn f(): /* note` ＋ 下一行 ` more */` | 跨行块注释：`:` 之后到**该物理行行尾**只有注释字符 | **行尾**（region 从注释结束后的首个 token 起算） |

**与判定 ① 的关系：同源，无冲突。** 两条规则出自同一条原理 —— **注释不是 token**：

- ①-3 说「行尾注释不改变该行的 anchor（anchor = 该行首个 **token** 的列）」；
- ②-2 说「注释不计为后继 **token**」。

⇒ 二者是同一原则在两个位置的应用，**不冲突**。

**但有一处必须点明的交互（不掩盖）**：① 与 ② 用的「注释」概念必须**同一份实现**。
⇒ **写死的实现约束**：lexer 里 ① 的 anchor 计算与 ② 的行尾判定**必须共用同一个
注释/字符串感知扫描器**（`//`、**可嵌套** `/* */`、以及「字符串与字符字面量里的 `//` 不是注释」）。
两处各写一份 ⇒ 两条规则**必然漂**（本仓已有同槽不同义的前科）。

**再一处交互（顺带写死，因为它跨两个判定）**：判定 ③ 的「**紧邻**其前」按 ① 判定之后数 ——
空行与只含注释的行**不插入**到「紧邻」关系里。例：

```core
text := read_file(path)
// 准备配置
catch:
 | FileNotFound => fail "config not found"
```

⇒ `catch` 仍绑定**紧邻的可失败语句 `text := read_file(path)`**（注释行是 no-op，不打断紧邻）。

### 2.4 裁定落地后，J-T0-2 里随之确定的两行

裁定为 (b) 之后，§6.2 清单里两行由「随裁定而定」变为**已定**（表内已就地改写）：

- **A3（`is_new_var_decl` / `_is_var_decl_start`）**：改判 `T_COLON_DECL`
  （`:=` 仍走 `T_COLON_EQ`，批量仍走 `T_COMMA`）；**`T_COLON_BLOCK` 不进声明分支**
  ⇒ 该消解器在 (b) 下**比今天更简单**（零前瞻）。
- **A9（两套前端的标签终止符集分歧）**：与 `:` 无关，仍按本档 §6.2 的替代判定处理（行边界），
  但 **T1/T2 必须先对齐自源 `:871` 与 bootstrap `:137,140` 这一格**。

`;` 的存活面不变（§2.5）。

### 2.5 与裁定无关、本档已写死的一条

> **`;` 在 v4 只在 `[T; N]` 与 `[v; N]` 两个产生式里合法；语句位、字段位、臂位、声明位的 `;` 全部退场。**

`;` 的**唯一存活面** = 方括号内的数组分隔符：v4 §3.1 `ArrayType = '[' Type ';' INT_LIT ']'`，
且 `v4-syntax-raw.md:142` 逐字「`;` 不要求用于**普通源码布局**」。

⇒ 由此产生 **J-T0-2**：逐条列出所有今天靠 `;` 判定歧义的消解器，并给出每一条在 v4 下的替代判定（§6.2）。

---

## 3. 判定 ③：`catch` 的绑定对象与 layout 层级

### 3.1 绑定规则（唯一措辞）

> **`catch` 绑定「同一 layout 层级内、最邻近其前的那一条可失败语句或声明」——
> 绑定的是那条语句/声明**整个**，不是它内部最深、或词法上最靠近的某个子表达式。
> 该语句/声明的值取恢复分支给出的替代值。**

**依据**：v4 §6.2 两句话的交集。`catch:` 与被处理语句同层（`v4-syntax-raw.md:541`），
且「绑定到紧邻其前的可失败表达式或语句」（`:557`）。两条合起来唯一确定的读法就是本条的措辞：
**取「同层」限定「紧邻」**。

**推论（写死）**：`catch` 的有效前件只在**同一个 sibling 组**里找。
若同层紧邻的前一条语句**不可失败**，则 `catch` 是**错误**（不是「继续往上层找」）。

### 3.2 回填时序（写死）

parser 看到 `catch:` 时，被绑定的声明节点**已经建成** ⇒ 必须**回头**把 initializer 槽包进错误边包裹器。
语义是 `cfg := (parse_config(text) catch …)`。

| # | 时序约束 | 理由 |
|---|---|---|
| 1 | 回填**必须在解糖（`desugar`）/ 常量折叠（`pass.cr`）之前** | 否则回填落在已被优化的树上 |
| 2 | 回填**必须在语句边界判定之后** | `;` 退场后边界由换行/缩进给出 |
| 3 | 回填**必须在 region 收尾判定之前** | 否则 `catch` 被当成 region 结束信号 |

⇒ 三者的相对次序写死为：**语句边界判定 → `catch` 回接 → region 收尾判定 → 解糖 → 常量折叠**。

### 3.3 用例表（至少 3 个，含计划的歧义反例；每条给期望绑定）

**C1 —— 同层紧邻声明（计划 §6.2 首个例子，含空行）**

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

- 期望：第 1 个 `catch` 绑定**声明 `text := read_file(path)`**；第 2 个绑定**声明 `cfg := parse_config(text)`**。
- **空行不改变绑定**（由判定 ①-1）：第 1 个 `catch` 与 `cfg := …` 之间的空行是 no-op，`catch` 组仍是 `text := …` 的后置子句。

**C2 —— 歧义最小反例（计划 §3.3；`catch` 与 `loop` 同列）**

```core
fn f():
    loop:
        do_thing()
    catch:
     | E => break
```

- 期望：**绑定 `loop` 语句**（整个 `loop:` 语句），**不绑定 `do_thing()`**。
- 理由：`do_thing()` 的锚点列比 `loop:` 深 ⇒ 它在 `loop` 的 region 内，与 `catch:` **不同层**；
  `catch:` 与 `loop:` 同列 ⇒ 同层 ⇒ 同层内最邻近的可失败语句 = `loop`。

**C3 —— 替代值形（`catch` 给值）**

```core
cfg := parse_config(text)
catch:
 | ParseError => default_config()
```

- 期望：绑定**声明 `cfg := parse_config(text)`**；`cfg` 的值 = `(parse_config(text) catch | ParseError => default_config())`。
- 这是 §3.2 回填时序的判据用例（`cfg` 的 initializer 槽被回头包裹）。

**C4 —— 未匹配错误继续传播（绑定 `_` 与绑定标识符）**

```core
value := operation()
catch:
 | KnownError => recover()
 | e          => log_and_fail(e)
```

- 期望：绑定**声明 `value := operation()`**；`_` 匹配任意错误，标识符模式绑定错误值；
  `operation()` 的其余错误**不被该 `catch` 吞掉**，继续自动传播（`v4-syntax-raw.md:575-577`）。

**C5 —— 同层紧邻者不可失败（负例）**

```core
fn g():
    x := 1
    catch:
     | E => break
```

- 期望：**错误**（`x := 1` 不可失败 ⇒ 同层内没有可绑定的可失败语句）。
  **不得**向上层找、**不得**静默把 `catch` 当空语句吞掉。

### 3.4 J-T0-3 的正反两条断言

- **正向**：C1–C5 的期望绑定逐条成立。
- **反向（本案的鉴别力证明）**：把 §3.1 的规则换成另一读（「绑定词法上紧邻其前的可失败**表达式**」）
  ⇒ **C2 的结论必须翻转**：从 `loop` 变成 `do_thing()`。
  C2 是唯一能分辨两读的用例（C1/C3/C4 两读同解，C5 在另一读下变成「绑定 `x := 1` 的 initializer `1`」——
  仍不可失败 ⇒ 仍错误，故 C5 不是鉴别用例）。**C2 不翻转 ⇒ J-T0-3 退回重写。**

---

## 4. 判定 ④：struct 字面量

### 4.1 判定（唯一措辞）

> **v4 的 struct 字面量形 = `Type { field = value , ... }`**
> （`{ }` 是**字面量定界符**，不是块结构；块结构已由 `:` + 缩进取代）。
> **字段分隔符必须是 `=`；`:` 形在整个语言里不存在。**
> 字段之间以 `,` 分隔，**`,` 可选**（与现行一致，`src/compiler/parser.cr:568` 逐字
> `if check(T_COMMA) { advance_tok(); }`）；**字面量内部不参与 layout region**（`{ }` 已定界）。

### 4.2 必须写死的一条：分隔符要在解析器里校验

> **parser 必须在字段分隔符位点校验 `=`（`check(T_EQ)`），未选定的 `:` 形必须响亮拒绝
> （`rc=1` + 诊断码 `P030`）。**

**为什么现在就要写死**（计划 §3.4 逐字要求）：今天的实现是**盲跳一个 token** ——
`[T0·实核]` `src/compiler/parser.cr:552-554`：

```core
ft := advance_tok();
fni := str_intern(tok_lx(ft));
advance_tok();          // ← 返回值被丢弃：`=` 与 `:` 两形今天都收
```

⇒ 若 T5 不把这一行改成带校验的消费，v4 下「两形都收」会**静默保留**，而 v4 是单形语言。
⇒ **实现是 T5 的事，规格在本档写死**；本档同时给出零构建可判的那一半（§6.4）。

**诊断码**：新增 `EC_P_STRUCT_LIT_SEP = 1030`（P030）。
出处：`src/compiler/ast.cr:335-359` 的解析器码表当前最大 = `EC_P_INTERP_HOLE_LEAK = 1029`（P029）
`[T0·实核]` ⇒ 下一个自由号是 **1030**。

> ⚠ **不得用 `EC_P_SEMI`（P007，`src/compiler/ast.cr:337`）承担本判定**：
> `[T0·实核]` 全仓 grep 该码**只有定义行、零 raise 点**。
> 判据点名一个零 raise 点的码 ⇒ 该判据**不可能靠自己的机制变红**（「空壳绿」形态）。

### 4.3 `{ }` 在 v4 里的地位（必须写进 v4 语法档）

`[T0·实核]` 通读 `v4-syntax-raw.md`：**全文出现 `{` 只有 2 处，且两处都是禁止**
（`:101`「v4 不使用 `{ ... }` 作为语言块结构」· `:696`「函数体……不使用 `{ ... }` 作为函数体分隔符」）。
⇒ **v4 原档今天没有字面量形，也默认没有任何 `{`**。

**⇒ 本判定把 `{ }` 作为「只用于字面量的定界符」重新引入 v4。** 这件事必须写进 v4 语法档
（计划 §3.4 末句：不写进去，规格仍缺）。写进去以后，v4 里 `{` 的**唯一**合法出现位置就是结构体字面量。

### 4.4 与 L2 读数表的交叉影响（登记，供 T4 用）

计划的 L2 表写「`src/compiler/*.cr` 花括号 15,771 ⇒ 改后应为 **0**」。
由判定 ④，**该格必须拆成三格**，否则 T4 会去追一个错的 0：

| 格 | 改前 | 改后 | 出处 |
|---|---|---|---|
| **块**花括号 | 15,771（含后两格） | **0** | 计划 §2.5 L2 |
| **字面量**花括号（`src/compiler` 内） | `[T0·实核]` **2 个**（唯一一处 = `src/compiler/elf.cr:45` 的 `ElfCtx { … }`） | **2**（不退场） | §6.4 的探针逐处清单 |
| **字符串字面量内**的花括号 | 计划写 **77 个不动** | **不动** | 计划 §2.5 L2 |

⇒ **本档给出的字面量格实测值 = 2**（不是 15,771、也不是 0）。T4 的 L2 计数表按本表拆格。

### 4.5 消解器的退场（J-T0-2 的一行结论，详见 §6.2）

`bootstrap/corec/frontend/parser.py:684-716` 的 `_is_struct_lit` 靠 `;` 判定「`{` 是块还是字面量」
（`:714` 逐字 `if tt == TokenType.SEMI and depth == 1: return False  # ; at top level -> block`）。
⇒ **v4 下该消解器整体退场**：块花括号不存在 ⇒ `Name {` 之后**必**是字面量 ⇒ 无需向前看。
⇒ 自源侧的对应机制 `g_parse_no_struct_literal`（`src/compiler/parser.cr:11`，9 处读写）
**应随块花括号一起删除**；其存在理由（抑制贪婪字面量分支）随歧义一起消失。

---

## 5. 判定 ⑤：洞内 `tokenize` 的缩进基准

### 5.1 事实与危险

`[T0·实核]` `src/compiler/parser.cr:433-450` `interp_parse_holes()`：字符串插值的洞内文本被
**重新 `tokenize()` + `parse_expr()`**，注释逐字自陈「**必须在 token 流用毕后调用**（会覆盖 `g_tokens`）」。

**危险**：layout 的 INDENT/DEDENT 是上下文相关的（缩进栈依赖「当前在第几层」），
而洞是**从源里切出的一小段表达式**（如 `n`），**没有 layout 上下文** ⇒ 会产生伪造的缩进状态；
且洞内嵌套插值会**递归重入**。

### 5.2 判定（本档选 (b)：显式旁路旗标）

> **判定：在该路径上显式旁路 layout 发射。**
> 新增全局 `g_layout_bypass`（int，通用约定：**0 = 发射 INDENT/DEDENT（默认，fail-closed）**；
> **1 = 不发射，且不读不写缩进栈**）。所有「调用后不进入 layout 消费者的 `tokenize()` 调用点」
> 必须传 1。

**规则（可机械判定，不留「视情况」）**：

> 一个 `tokenize()` 调用点**必须传旁路** ⟺ 该调用之后，**在同一控制流里**该 token 流**不由**
> `parse_all` / `parse_expr` 消费。
> （⟺ 它只做转储、重扫、自测、LSP 分析，或是重入路径。）

### 5.3 选 (b) 而非 (a) 的理由

1. **(a) 的「规定基准列」在它要管的地方不可执行**：洞文本是源里切出的一段，
   「强制以列 1 为基准」要求 lexer 按一个**合成列**重新编号 —— 那就是一个「列原点」参数，
   **本身就是旗标**，只是隐式、且在调用点看不出来（正是要防的静默形态）。
2. **(a) 不阻止发射**：洞文本自身若含缩进（多行洞、或以空白开头的洞），
   缩进栈照样被写 ⇒ (a) **把问题挪位，没有移走**。
3. **(b) 在本文件里已有同款先例**：`g_parse_no_struct_literal`（`src/compiler/parser.cr:11`）
   就是「在重入路径上用一个模式旗标抑制贪婪分支」——
   **复用仓里已确立的模式，优于为同一类问题发明第二套约定**（也是 §0.4「同槽/同值不同义」纪律要求的先例核对）。
4. **(b) 使 J-T0-5 的零构建那一半成为机械可判**（§6.5）：判据变成「每个无 layout 上下文的调用点都传了旗标」，
   读调用点即可判，不需要跑编译器。

### 5.4 调用点清单（必须逐点给判定）

`[T0·实核]` `src/` 下 `tokenize(` **调用点 = 10 处**（+ 定义 1 处）：

```text
src/compiler/module.cr:456,693,704   src/compiler/dump.cr:232,438
src/compiler/main.cr:129,758         src/compiler/parser.cr:443   ← 唯一的重入点
src/compiler/purity_selftest.cr:40   src/lsp/lsp.cr:173
定义: src/compiler/lexer.cr:362
```

> **对计划的更正（登记）**：计划 §7.2 与 `mech.md §2.3` 都写「**12 处**」。
> `[T0·实核]` 实际 **10 处**（`mech.md` 自己括号里列的也正是这 10 个行号）。
> 本档按「**至少 10**」写入并附上面的清单；「12」这个数没有出处支持。

**唯一的重入点 = `src/compiler/parser.cr:443`**（洞内）。其余 9 处按 §5.2 的规则逐点判定，
判定的产物 = T5 的 J-T5-1（计划 §7.2 已把「逐处给出是否需要改 + 理由」定为 T5 的交付）。

### 5.5 J-T0-5 的用例（含嵌套插值）

```core
fn f(a: int, b: int, c: int, d: int) -> string:
    return "a${b}${"c${d}"}"
```

- 断言：**洞内重入不改变外层缩进栈**——重入前后缩进栈深度相同
  （规格形状：`indent_depth_before == indent_depth_after`）。
- 本档**零构建**能判的那一半 = §6.5 的静态断言；深度相等那一半**需构建才能定论**。

---

## 6. 判据 J-T0-1 … J-T0-5

**共同约定**：每条给「判据形状 · 精确命令 · 正反两条断言 · 零构建还是需构建」。
命令一律从仓库根跑；`--rev develop@origin` 让探针走 `jj file show` 取数（不读工作副本）。

### 6.0 判据总览

| 判据 | 零构建？ | 载体 | 反向对照（改坏一处 ⇒ 必红） |
|---|---|---|---|
| **J-T0-1** | ✅ 零构建 | `tools/v4_layout_probe.py concat-layout` | 见 §6.1 矩阵（3 格红） |
| **J-T0-2** | ✅ 零构建 | 同探针 `semi-resolvers --spec` | 从本档删掉一行清单 ⇒ 报 MISSING |
| **J-T0-2b** | ✅ 零构建 | 同探针 `colon-positions` | 见 §6.2b（两族：行尾标注注入 / 注释当 token） |
| **J-T0-3** | ⚠ 需构建才能定论 | `catch` 用例（§3.3） | 换绑定规则 ⇒ C2 结论翻转 |
| **J-T0-4 正向** | ⚠ 需构建才能定论 | `nice -n 19 ./build/corec check <档>` | — |
| **J-T0-4 反向** | ✅ 零构建（+ 需构建半） | 探针 `struct-lit-forms --form` / `--require-guard` | 见 §6.4 |
| **J-T0-5** | ✅ 零构建（+ 需构建半） | 探针 `tokenize-sites --require-bypass` | 见 §6.5 |

⇒ 计划 §3.6 验收第 2 条要求「J-T0-1 / J-T0-2 / J-T0-4(反向) / J-T0-5 四条**零构建可判**」**已满足**：
四条各有一个零构建可判的形态（J-T0-4 反向与 J-T0-5 另有一个需构建的加强形态，不是替代）。
**J-T0-2b 是维护者裁定 ② 时新增的判据（计划里没有），它同样零构建可判。**

### 6.1 J-T0-1（拼接 layout 探针）—— **本档新建**

**判据形状**：取两个档，按 `concat()` 的规则拼（`build_selfhost_native.py:138-158`：
`'\n\n'.join` + 列 0 分隔符 + 行级剥 `import `），断言三条：

- **A1** 拼接后的顶层声明数 = 两档各自顶层声明数之和；
- **A2** 拼接结果**零 layout 错误**（无「锚点比单元基准锚点更浅」的行）；
- **A3** **逐档**核对（不只是总数）：每一档在其行区间内的顶层行数 = 该档单独扫的顶层行数。

**精确命令**：

```bash
cd /home/DslsDZC/core-v4-ws
python3 tools/v4_layout_probe.py concat-layout --rev develop@origin
python3 tools/v4_layout_probe.py concat-layout --rev develop@origin --wrapper-fn compiler_main
```

**实测（`[T0·实核]`，本档跑了）**：默认两档 = `src/compiler/project.cr`（4 顶层行）+
`src/compiler/dump.cr`（31）⇒ 期望 35，拼接得 35 ⇒ **A1/A2/A3 全 PASS，rc=0**。

**正反两条断言（矩阵；`[T0·实核]` 逐格跑过）**：

| # | 分隔符列 | 注释约定 | A1 | A2 | A3 | 结论 | rc |
|---|---|---|---|---|---|---|---|
| 1 | 0（现行） | 注释行为 no-op（判定 ①） | PASS | PASS | PASS | **GREEN（要求的正控）** | 0 |
| 2 | 4 | 注释行为 no-op（判定 ①） | PASS | PASS | PASS | **GREEN —— 见下面的更正** | 0 |
| 3 | 0 | 注释行参与 layout（突变） | FAIL | PASS | FAIL | RED | 1 |
| 4 | 4 | 注释行参与 layout（突变） | FAIL | FAIL | FAIL | RED | 1 |
| 5 | 0，**非注释分隔符** | no-op | FAIL | PASS | FAIL | RED | 1 |
| 6 | 4，**非注释分隔符** | no-op | FAIL | PASS | FAIL | RED | 1 |

```bash
# 第 2 格（计划逐字给的那条反向对照）
python3 tools/v4_layout_probe.py concat-layout --rev develop@origin --sep-col 4
# 第 3 / 4 格
python3 tools/v4_layout_probe.py concat-layout --rev develop@origin --comment-policy participate
python3 tools/v4_layout_probe.py concat-layout --rev develop@origin --sep-col 4 --comment-policy participate
# 第 5 / 6 格
python3 tools/v4_layout_probe.py concat-layout --rev develop@origin --sep-kind code --sep-col 0
python3 tools/v4_layout_probe.py concat-layout --rev develop@origin --sep-kind code --sep-col 4
```

> **⚠ 对计划 §3.1 反向对照的更正（本档实测）**：计划写「把分隔符改成带缩进（`    // === f ===`）
> ⇒ 该判据**必须红**」。**实测第 2 格不红（rc=0）**。
> 机理：该行仍是**只含注释的行** ⇒ 判定 ①-2 使它成为 no-op ⇒ 它的列不参与 anchor。
> **即：在判定 ① 之下，「分隔符带缩进」不是一处「改坏」** —— 它什么都不改变。
> ⇒ **计划的这条反向对照作为字面命令没有鉴别力**（它测的是一个恒真命题）。
> **本档把它替换成有鉴别力的两族**：
> - **族一（第 3/4 格）**：把**注释约定**改成「注释行参与 layout」——
>   这一族正是计划 §3.1 真正担心的坏规则（「注释行参与缩进」），且两格都红；
> - **族二（第 5/6 格）**：把分隔符改成**非注释行** —— 直接测结论 B（§1.2）那条承重条件。
>
> **第 2 格仍然保留并断言 GREEN**：它不是反向对照，而是**判定 ①-2 的正控**
> （证明「分隔符的列不影响 layout」这条结论 A）。**把它从「必红」改成「必绿」，是本档对计划的一处实测更正。**

**零构建**：✅ 纯文本/计数，不碰 `build/`，不跑编译器。它同时是计划 §十一 U-9 的收尾。

**边界（必须写进文档，防止被读成「模型即实现」）**：探针是**判定 ①②③ 的可执行模型**，
它证明**规格自洽**且**拼接技术在该模型下 layout 透明**；
它**不证明 T5 的 lexer 真的实现了该模型**。编译器侧的闸门仍是 J-T5-3 / J-T5-2（均需构建）。
⇒ **J-T0-1 绿不得被当作用 T5 结论的替代。**

### 6.2 J-T0-2（`;` 依赖消解器：逐条列全）

**判据形状**：本档的清单**必须覆盖**两个 parser 里**每一处** `T_SEMI` / `SEMI` 出现点；
出现点未在清单里 ⇒ **T0 未完成**（计划 §3.2 逐字：「列不全 = T0 未完成」）。

**精确命令**：

```bash
cd /home/DslsDZC/core-v4-ws
python3 tools/v4_layout_probe.py semi-resolvers --rev develop@origin \
  --spec docs/maintainer/design/v4-layout-spec.md
```

**判据覆盖断言**：探针读下面这个**显式清单块**（机器可读、逐行 `路径:行号`，无范围无散文），
与扫到的出现点做**双向**比对：`MISSING`（出现点未列）与 `stale`（列了但该行无出现点）任一非零 ⇒ `rc=1`。

<!-- semi-sites -->
# J-T0-2 导出清单：两个 parser 里每一处 T_SEMI / SEMI 出现点（行号，逗号分隔）
src/compiler/parser.cr:54,647,711,871,914,982,1021,1022,1028,1029,1034,1039,1043,1721,2082,2188
bootstrap/corec/frontend/parser.py:50,137,140,175,191,205,259,350,625,714,741,746,748,753,758,763,945,971,977
<!-- /semi-sites -->

**实测（`[T0·实核]`）**：`src/compiler/parser.cr` **16 处** + `bootstrap/corec/frontend/parser.py` **19 处** = **至少 35 处**。
下面逐处给判定。**分类（兜底格在最后，防止穷举漏项）**：

#### A 类 —— 真消解器：`;` 的有无决定走哪条产生式（**必须重新设计**）

| # | 位点 | 今天的判定 | v4 替代判定 |
|---|---|---|---|
| **A1** | `src/compiler/parser.cr:1043-1046`（同款 `bootstrap/…/parser.py:761-766`） | `e := parse_expr(); if check(T_SEMI) { … EXPR_STMT } return e;` —— **有 `;` = 语句，无 `;` = 块的尾表达式**（`ast.cr:204` 逐字「expression used as statement (with `;`), returns unit」） | **region 的最后一项 = 该 region 的值，其余各项按语句处理**。判据：项之后若是**同层或更浅**的 anchor（含 DEDENT / region 收尾），则它是最后一项。**这是本类里最承重的一条**——它决定每个 `:` region 的产出类型 |
| **A2** | `bootstrap/…/parser.py:684-716`，判别位 `:714` | `_is_struct_lit`：扫到**深度 1 的 `;`** ⇒ 该 `{` 是块，不是字面量 | **消解器退场**：v4 无块花括号 ⇒ `Name {` 之后必是字面量（§4.5）。自源侧 `g_parse_no_struct_literal`（`parser.cr:11`，9 处读写）随之删除 |
| **A3** | `src/compiler/parser.cr:798-813` `is_new_var_decl`（同款 `bootstrap/…/parser.py:95-114` `_is_var_decl_start`） | **不读 `;`**：`IDENT` 后接 `:=` / `:` / `,`…`:` 即提交为声明 | **改判 `T_COLON_DECL`**（裁定 (b)，§2.1）：`IDENT` 后接 `T_COLON_DECL` / `T_COLON_EQ` / `,`…`T_COLON_DECL` ⇒ 声明；**`T_COLON_BLOCK` 不进声明分支**。⇒ (b) 使两种 `:` 互斥且穷尽 ⇒ 该消解器**比今天更简单（零前瞻）**，`;` 退场不改变本条 |
| **A4** | `bootstrap/…/parser.py:41-61` `_scan_constants`（判别位 `:50` 的序列末尾 `TokenType.SEMI`） | **token 级预扫**，认 `IDENT : IDENT = INT_LIT ;` 六元组，把名字→值收进 `const_values`，供 `:356` 解 `[T; N]` 的具名长度 | **序列末元改成「行尾」**：六元组改为五元组 `IDENT COLON IDENT EQ INT_LIT`，终止条件由 `SEMI` 改为**行边界**（`col` 或换行 token）。**漏改 ⇒ 具名长度静默解成 0**（`:356` 的 `.get(name, 0)` 兜底），**是静默错答案** |
| **A5** | `src/compiler/parser.cr:982` `skip_nested_fn` | **错误恢复路径**：`;`（且未见 `{`）⇒ 结束整段跳过 | 换成 **DEDENT / region 收尾** |
| **A6** | `src/compiler/parser.cr:1021-1022`（`return`）/ `:1028-1029`（`yield`）（同款 `bootstrap/…/parser.py:746-749`） | `;`/`}` 紧跟 ⇒ **无值返回**；否则解析表达式 | **行边界**：关键字之后**同一逻辑行内**无 token ⇒ 无值 |
| **A7** | `src/compiler/parser.cr:647`（`go`） | `;` / `}` / EOF 紧跟 ⇒ 报「`go` 后缺表达式」 | **行边界**（同上） |
| **A8** | `src/compiler/parser.cr:871`（声明标签表终止） | `T_EQ` / `T_SEMI` / `T_EOF` ⇒ 停止收标签 | **行边界**；`T_EQ` 仍保留（`x : int, mut = e` 的 `=`） |
| **A9** | `bootstrap/…/parser.py:137,140`（同一处的两条） | 终止符集 = `EQ` / `SEMI` / `COMMA` / `COLON` / `EOF` | **与自源不同形**（自源 `:871` 只认 `EQ`/`SEMI`/`EOF`，**不含 `COMMA`/`COLON`**）⇒ **T1/T2 必须先对齐两套前端的这一格**，否则双前端行为分歧 |

#### B 类 —— 可选 `;` 消费：不是消解器，但**代码必须删/改**（否则在 v4 报错）

| # | 位点 | v4 处置 |
|---|---|---|
| B1 | `src/compiler/parser.cr:914` | 删（语句末可选 `;` 退场） |
| B2 | `src/compiler/parser.cr:1721` | 删（`extern` 声明末） |
| B3 | `src/compiler/parser.cr:2082` | 删（`mod` 声明末） |
| B4 | `src/compiler/parser.cr:2188` | 删（`import`/`fileid` 声明末） |
| B5 | `src/compiler/parser.cr:1034`（`break`）/ `:1039`（`continue`） | 删 |
| B6 | `bootstrap/…/parser.py:350` / `:625` | 删（`[T; N]` 类型与 `[v; N]` 值**除外**——见 C 类） |
| B7 | `bootstrap/…/parser.py:175,191,205,259,741,945,971,977`（8 处 `expect(SEMI)`） | **硬要求**改行边界（不改 = 直接 parse error） |

#### C 类 —— `;` 在 v4 **存活**的面（**不动**）

| # | 位点 | 说明 |
|---|---|---|
| C1 | `src/compiler/parser.cr:54` | `[T; N]` **类型**（v4 §3.1 保留） |
| C2 | `src/compiler/parser.cr:711` | `[v; N]` **值**（重复数组） |
| C3 | `bootstrap/…/parser.py:50` | A4 的位点（已归 A 类，此处仅注明它也是 `[T;N]` 的输入面） |

#### 兜底格

> 本清单的分类**不重不漏**：A 类 = 判定被 `;` 改变；B 类 = 判定不被 `;` 改变但代码含 `;` 消费；
> C 类 = `;` 合法存活。**探针的 `MISSING` 断言是这一格的机械保障**：
> 未来任何一处新的 `T_SEMI` 没被归入上面任一类，`semi-resolvers --spec` 立刻 `rc=1`。

### 6.2b J-T0-2b（`:` 行内/行尾判定）—— 裁定 (b) 的连带后果 ①②

**判据形状**：给出「`:` 的行内/行尾 + 行尾者是否为合法 region 头」的机械判定，并对
**规格自带的夹具表**与**全仓语料**各断言一次。

**精确命令（零构建）**：

```bash
cd /home/DslsDZC/core-v4-ws
python3 tools/v4_layout_probe.py colon-positions --rev develop@origin
python3 tools/v4_layout_probe.py colon-positions --rev develop@origin --fixture-only
```

**实测（`[T0·实核]`，本档跑了）**：
A1 夹具 **19 个 / 28 个 `:` 逐个标签正确**；A2 扫 **227 档** ⇒
`LINE_INTERNAL` **7354** ／ `LINE_END/region-opener` **0** ／ `LINE_END/CANDIDATE` **0** ⇒ rc=0。

> ⚠ **A2 今天在现行语料上是「真但空」的**：v3 用花括号开 region ⇒ 语料里**行尾 `:` 一处都没有**
> ⇒ `0 == 0`。**它要到 T4 之后才有输入**（届时应是「行尾 `:` = 全部 region 开启，CANDIDATE = 0」）。
> ⇒ **今天承载鉴别力的是 A1（夹具表）**，A2 的鉴别力由下面的反向对照证明（注入坏输入后必红）。

**A1 夹具表（在内存里，不写盘 —— 与 `tests/harness/test_criteria_mutations.py` 同款约定）**：
每条给「源文本 · 每个 `:` 的期望标签」。
覆盖 D1–D13 全部形（`x : int = 5` · `count : int, mut = 0` · `a, b : int = 1, 2` · `id: int` ·
`import math : m` · `mod examples::pi` · 形参表跨行两行 · `fn add(...) -> int:` · `spec fn ...:` ·
`f := fn(...) -> int:` · `match x:` · `catch:` · `struct User:` · `enum Mode:` · `impl Eq for Point:`），
外加连带后果 ② 的四格（`fn f(): // note` · `x : int = 5 // note` · `fn f(): /* note */` ·
**跨行块注释** `fn f(): /* note\n still note */`）。

**正反两条断言（两族，都要红）**：

```bash
# 族一（连带后果 ①）：注入行尾标注
python3 tools/v4_layout_probe.py colon-positions --rev develop@origin \
  --mutate annotation-line-end --fixture-only        # 期望 rc=1，报到 3 处 CANDIDATE
# 族二（连带后果 ②）：把注释当 token
python3 tools/v4_layout_probe.py colon-positions --rev develop@origin \
  --no-skip-trailing-comment                          # 期望 rc=1，3 个夹具标签错
```

**实测（`[T0·实核]`）**：族一 rc=1，报到 **3 处** CANDIDATE——
`x :`（标注断行）· `struct User:` 后的 `id:`（字段标注断行）· **`fn f(a:`（形参标注断行，§2.2 那个
「lexer 判不出」的形态）**；族二 rc=1，3 个夹具的 `:` 被判成行内。

**备注（判据的载体纪律）**：夹具是**内存内**的（不新建 `.cr` 档、不改 runner 计数），
所以本判据不触碰 `tools/baseline/probes_run.sh` 的 `PROBE_TOTAL`。

### 6.3 J-T0-3（`catch` 绑定）

**判据形状**：§3.3 的 C1–C5 **逐条**给出期望绑定，用例文本入仓。

**精确命令（需构建才能定论）**：

```bash
nice -n 19 ./build/corec check tests/probes/<catch 用例档>.cr   # 逐档取 rc + 诊断码集
```

**正反两条断言**：
- 正向：C1–C5 的期望成立（C1–C4 rc=0；C5 rc=1 + 具体码）。
- 反向：把 §3.1 的规则换成「绑定词法上紧邻其前的可失败**表达式**」⇒ **C2 的结论必须翻转**
  （`loop` → `do_thing()`）。**C2 不翻转 ⇒ 退回重写**。

**零构建那半**：C1–C5 的**期望绑定表**本身是零构建可审的（本档 §3.3 已给出，逐条唯一措辞）。
⇒ 计划的「零构建可判」对 J-T0-3 **不适用**（计划也没要求它），本档如实标注为**需构建**。

### 6.4 J-T0-4（struct 字面量：正反两条断言）

**正向（需构建才能定论）**：选定形（`=`）在全仓语料上 `rc=0`。

```bash
nice -n 19 ./build/corec check <逐档>     # 32 处 / 17 档
```

**正向的反向对照**：同一条命令换成**未选定形**的那一档（`tests/probes/p_struct_lit_sep.cr`）
⇒ 必须 `rc=1` + `error[P030]`。**两形同绿 ⇒ 判据无鉴别力，退回重写**
（今天正是两形同绿：`src/compiler/parser.cr:552-554` 盲跳 ⇒ 两形都收）。

**反向（零构建半 + 需构建半）**：未选定的 `:` 形必须响亮拒绝。

零构建半 —— 两条断言：

```bash
cd /home/DslsDZC/core-v4-ws
# ① 迁移后：未选定形在整个语料里的出现数 = 0（负例探针档除外）
python3 tools/v4_layout_probe.py struct-lit-forms --rev develop@origin \
  --form eq --allow-file tests/probes/p_struct_lit_sep.cr
# ② parser 必须校验分隔符（今天的盲跳必须消失）
python3 tools/v4_layout_probe.py struct-lit-forms --rev develop@origin --require-guard
```

需构建半 —— 负例探针必须 `rc=1` 且含 `P030`：

```bash
nice -n 19 ./build/corec check tests/probes/p_struct_lit_sep.cr   # 期望 rc=1 + error[P030]
```

**负例探针档（T5/T6 建，本档只指定）**：`tests/probes/p_struct_lit_sep.cr`，
内容 = 一个用 `:` 形字段分隔符的结构体字面量。
⚠ **同批必须把 `tools/baseline/probes_run.sh:29` 的 `PROBE_TOTAL=29` 改成 30**
（本仓纪律：档数变化必须同批改本行与其注释）。
`[T0·实核]` `tests/probes/*.cr` 的 glob 实为 **29** 档（`PROBE_TOTAL=29` 是对的；
计划 U-7 提到的「36」= 29 + `tests/probes/warm/*.cr` 的 7 档，后者不被该 glob 收）。

**语料计数（`[T0·实核]`，探针复现了计划的数）**：

| 形 | 处 | 档 | 分布 |
|---|---|---|---|
| `=`（选定） | **14** | **8** | `src/` 2（`elf.cr:45`、`toml.cr:268`）· `tests/suite` 3 · `examples` 3 |
| `:`（未选定） | **18** | **9** | `tests/probes` 8 · `tests/spec` 1 |
| 合计 | **32** | **17** | — |

> **数法必须随数走**：剥注释/串 + 花括号配平 + **与 struct 声明表求交**（名字在声明表内**且**首个字段名是该 struct 的声明字段名）
> ⇒ 这一条交是必需的：没有它，`fn f() -> ElfCtx {` 这种「返回型以 `{` 结尾」的签名会被算成字面量。
> **本档第一次扫描（按行、每行只算一处、无字段表）得 15/16，与计划不符；换成计划的数法后逐格复现 14/18/32。**
> ⇒ 记录在案：**计数差不是计划的错，是数法的错**（本仓纪律：计数必带数法）。

### 6.5 J-T0-5（洞内重入不改变缩进栈）

**零构建半 —— 静态断言**（今天必红，T5 后须绿）：

```bash
cd /home/DslsDZC/core-v4-ws
python3 tools/v4_layout_probe.py tokenize-sites --rev develop@origin \
  --require-bypass g_layout_bypass
```

断言：`parser.cr:443`（唯一重入点）的 `tokenize(txt)` 调用**传 `g_layout_bypass`**。
**实测（`[T0·实核]`）今天 rc=1**（该旗标尚不存在）——**这是预期的红**，与 J-T0-4 反向的零构建半同款。

**需构建半 —— 深度相等**：

```bash
nice -n 19 ./build/corec selftest-layout    # T5 新增自测通道（先例：selftest-types / selftest-purity）
```

用例 = §5.5 的 `"a${b}${"c${d}"}"`（嵌套插值）。断言输出 `indent_depth_before == indent_depth_after`。

**正反两条断言**：
- 正向：上面两条都过。
- 反向：把 §5.2 的规则改成候选 (a)（**只**规定基准列、**不**旁路发射）⇒
  用一个**洞文本自身含缩进**的用例（例：`"a${  n  }"`，洞文本首字符为空格）⇒ 静态断言**必红**
  （该路径仍会发射 INDENT/DEDENT）。**这一格就是 §5.3 第 2 条理由的可执行证据。**

---

## 7. 本档登记的更正与交叉影响

| # | 对象 | 计划/报告原文 | 本档实测 | 处置 |
|---|---|---|---|---|
| 1 | 计划 §3.1 的反向对照 | 「分隔符改成带缩进 ⇒ 该判据**必须红**」 | **不红**（rc=0）：该行仍是注释行 ⇒ 判定 ①-2 使其为 no-op | §6.1：保留该格并断言 **GREEN**（改作判定 ①-2 的正控），另立两族有鉴别力的反向对照 |
| 2 | 计划 §7.2 / `mech.md §2.3` | `tokenize()` 调用点「**12 处**」 | **10 处**（附逐点清单，§5.4） | 按「至少 10」写入；「12」无出处支持 |
| 3 | 计划 §2.5 L2 计数表 | 「`src/compiler` 花括号 15,771 ⇒ 改后应为 **0**」 | 由判定 ④，`{ }` 保留作字面量定界符 ⇒ **`src/compiler` 内另有 2 个字面量花括号不退场**（唯一一处 `elf.cr:45`） | §4.4：该格拆成三格（块 / 字面量 / 串内），字面量格实测 **2** |
| 4 | 计划 §十一 U-7 | 「`tests/probes` 的 `PROBE_TOTAL=29` 与实际 36 档的关系」未核 | glob `tests/probes/*.cr` = **29** ⇒ `PROBE_TOTAL=29` **正确**；「36」= 29 + `warm/` 7 档（不被该 glob 收） | §6.4 注明；**U-7 可结** |
| 5 | 裁定 (b) 的连带后果 ①（本档扫描发现） | 计划未提 | 形参标注断行（`fn f(a:` ＋ 续行 `int):`）与头部终结（`fn f() -> int:`）**在 lexer 层不可区分**（都是「`fn` 开头 + 行尾 `:`」） | §2.2 点明；判据 J-T0-2b 的族一**必须包含这一格并红**（它是本判定唯一的盲点，靠语法面兜住） |
| 6 | 判定 ② 与判定 ① 的一致性 | 计划未提 | **无冲突**（同源于「注释不是 token」）；但引出**一条实现约束**：两处必须共用同一个注释/字符串扫描器 | §2.3 写死该约束，并写死 `catch` 的「紧邻」按 ① 计数 |

---

## 8. 本档未核实

> 纪律：下列每条都是「**我确实没做**」，不是「做了但不确定」。零构建是硬约束，凡需构建才能定论的写命令。

| # | 未核实项 | 为什么没核 | 怎么核 |
|---|---|---|---|
| **T0-U-1** | 任何构建结果（判定 ③④ 的正向、J-T0-5 的深度相等） | 本档零构建 | `nice -n 19 python3 build_selfhost_native.py`，再 `nice -n 19 ./build/corec check <档>` |
| **T0-U-2** | 判定 ① 的模型与 T5 实际 lexer 是否逐位一致 | 需先有 T5 实现 | J-T5-3 + `corec2 == corec3`（均需构建） |
| **T0-U-3** | A 类里 A6/A7/A8 的替代判定（「行边界」）在**多行表达式**上的确切行为 | 裁定 ② 已落（不再是阻塞），但仍需 T5 实现 | 逐条构造多行表达式探针，取 rc + 码 |
| **T0-U-4** | `bootstrap/…/parser.py:137,140` 与自源 `:871` 的终止符集分歧（A9）在真实语料上是否可观测 | 未跑两套前端对拍 | `python3 tests/bootstrap/test_pipeline.py` 与 `tests/selfhost/test_lexer_parity.py`（如存在；计划 U-4 也未核该档是否存在） |
| **T0-U-5** | §4.2 的 `EC_P_STRUCT_LIT_SEP = 1030` 是否与**别的**并行批次冲突（号段占用） | 只看了解析器码表 `ast.cr:335-359`，未核全仓所有 `EC_*` 号段 | `grep -rn '= 1030' src/compiler/*.cr`（取号前现查；本仓纪律：取号查当天最大号） |
| **T0-U-6** | 判定 ④ 的「字段 `,` 可选」在**多行字面量**下与 layout 的交互（`toml.cr:268` 是跨 5 行的字面量） | 未构造多行字面量探针 | 需构建：`nice -n 19 ./build/corec check src/stdlib/toml.cr` |
| **T0-U-7** | J-T0-1 的 A3 相对 A1 的**独立**分辨力（「A1 绿而 A3 红」的输入） | 未构造出该输入 | A3 ⟹ A1（A3 更强），矩阵里两者同红；A3 的附加价值 = **定位到档**。若要独立那一格，需造「A 档多一行 + B 档少一行」的输入 |
| **T0-U-8** | `catch` 的 C1–C5 里，`fail`（v4 §6.1）自身的语义面 | `fail` 今天在自源零产生式（计划 §一.10） | T5/T6 |
| **T0-U-9** | 判定 ② 的「行内/行尾」与 §2.2 那张逐形表在**真实 v4 语料**上的完备性 | v4 语料尚不存在（T4 产出）；本档只扫了 v3 语料（227 档）与 v4 原档的 77 个代码块 | T4 后重跑 `colon-positions`（期望：行尾 `:` 全部是 region 开启，CANDIDATE = 0）；**T4 若引入新形，本表必须同批补行** |
| **T0-U-10** | §2.3 那条「两处共用同一个扫描器」的实现约束是否真的做到了 | 需先有 T5 实现 | 读 T5 的 lexer：① 的 anchor 计算与 ② 的行尾判定是否调用同一函数（**不得是两份实现**） |

---

## 9. 复现命令（可粘可跑；**零构建**）

```bash
cd /home/DslsDZC/core-v4-ws          # 本档的工作区；@ = develop@origin = e08df3d9
jj log -r develop@origin --no-graph -T 'commit_id ++ "\n"'   # 先印基线是谁

# ── J-T0-1 拼接 layout 探针（正控 + 两族反向对照）────────────────────────
python3 tools/v4_layout_probe.py concat-layout --rev develop@origin
python3 tools/v4_layout_probe.py concat-layout --rev develop@origin --sep-col 4          # 期望 GREEN（判定 ①-2 的正控）
python3 tools/v4_layout_probe.py concat-layout --rev develop@origin --comment-policy participate   # 期望 RED rc=1
python3 tools/v4_layout_probe.py concat-layout --rev develop@origin --sep-col 4 --comment-policy participate
python3 tools/v4_layout_probe.py concat-layout --rev develop@origin --sep-kind code --sep-col 0
python3 tools/v4_layout_probe.py concat-layout --rev develop@origin --sep-kind code --sep-col 4
python3 tools/v4_layout_probe.py concat-layout --rev develop@origin --wrapper-fn compiler_main    # 期望 GREEN

# ── J-T0-2 消解器清单覆盖断言 ────────────────────────────────────────────
python3 tools/v4_layout_probe.py semi-resolvers --rev develop@origin \
  --spec docs/maintainer/design/v4-layout-spec.md

# ── J-T0-2b ':' 行内/行尾判定（裁定 (b) 的连带后果 ①②）────────────────
python3 tools/v4_layout_probe.py colon-positions --rev develop@origin             # 期望 rc=0
python3 tools/v4_layout_probe.py colon-positions --rev develop@origin --fixture-only   # 期望 rc=0
python3 tools/v4_layout_probe.py colon-positions --rev develop@origin \
  --mutate annotation-line-end --fixture-only                                      # 期望 rc=1（族一）
python3 tools/v4_layout_probe.py colon-positions --rev develop@origin \
  --no-skip-trailing-comment                                                       # 期望 rc=1（族二）

# ── J-T0-4 零构建半（语料单形 + 分隔符守卫）──────────────────────────────
python3 tools/v4_layout_probe.py struct-lit-forms --rev develop@origin
python3 tools/v4_layout_probe.py struct-lit-forms --rev develop@origin --form colon --subset tests/probes/  # 期望 rc=0（单形）
python3 tools/v4_layout_probe.py struct-lit-forms --rev develop@origin --form eq --subset tests/probes/      # 反向，期望 rc=1
python3 tools/v4_layout_probe.py struct-lit-forms --rev develop@origin --require-guard                       # 今天 rc=1（T5 后须 rc=0）

# ── J-T0-5 零构建半 ─────────────────────────────────────────────────────
python3 tools/v4_layout_probe.py tokenize-sites --rev develop@origin --require-bypass g_layout_bypass

# ── 需构建才能定论的全部命令（本档不跑；铁律 6 限 CPU）──────────────────
# nice -n 19 python3 build_selfhost_native.py
# nice -n 19 ./build/corec check <档>
# nice -n 19 ./build/corec selftest-layout
```

---

## 附：本档引用的实核锚点（逐条带命令）

| 锚点 | 值 | 命令 |
|---|---|---|
| 拼接分隔符（列 0） | `build_selfhost_native.py:154` | `jj file show -r develop@origin build_selfhost_native.py \| sed -n '138,158p'` |
| `'\n\n'.join` | `:155` | 同上 |
| wrapper 行（v3 花括号源） | `:157` | 同上 |
| 盲跳字段分隔符 | `src/compiler/parser.cr:552-554` | `jj file show -r develop@origin src/compiler/parser.cr \| sed -n '552,554p'` |
| 逗号可选 | `src/compiler/parser.cr:568` | 同上 |
| `EXPR_STMT` 契约 | `src/compiler/ast.cr:204` | `jj file show -r develop@origin src/compiler/ast.cr \| sed -n '204p'` |
| `EC_P_SEMI` 零 raise 点 | 只有 `ast.cr:337` | `grep -rn 'EC_P_SEMI' src/compiler/*.cr` |
| 解析器码表上界 | `EC_P_INTERP_HOLE_LEAK = 1029`（`ast.cr:359`） | `jj file show -r develop@origin src/compiler/ast.cr \| sed -n '335,359p'` |
| `tokenize()` 调用点 = 10 | §5.4 清单 | `grep -rn 'tokenize(' src/` |
| `g_parse_no_struct_literal` 先例 | `parser.cr:11` + 9 处 | `grep -rn 'g_parse_no_struct_literal' src/compiler/*.cr` |
| `_is_struct_lit` 的 `;` 位 | `bootstrap/corec/frontend/parser.py:714` | `jj file show -r develop@origin bootstrap/corec/frontend/parser.py \| sed -n '684,716p'` |
| `_scan_constants` 六元组 | `bootstrap/corec/frontend/parser.py:41-61` | 同上 `sed -n '41,61p'` |
| `PROBE_TOTAL=29` | `tools/baseline/probes_run.sh:29` | `jj file show -r develop@origin tools/baseline/probes_run.sh \| sed -n '29p'` |
| v4 无 `{`（只两处，皆禁止） | `v4-syntax-raw.md:101,696` | `grep -n '{' /tmp/briefs/v4-syntax-raw.md` |
| 裁定 (b) 的 `:` 双 token | 本档 §2.1（维护者裁定） | — |
| 现行语料行尾 `:` = 0 | 227 档 · 0 处 | `python3 tools/v4_layout_probe.py colon-positions --rev develop@origin` |
| v4 目标行尾 `:` = 57 处，全是 region 开启 | 77 个 core 代码块 | 同上（`--fixture-only` 不含语料；v4 侧扫描见 §2.2 表） |
