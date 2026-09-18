# 2(a) 视图内建批（`@ptr_of` / `@str_of`）—— 计划（**规划轮：只读侦查 + 落纸**；未实施）

**日期**：2026-09-18 · **工作区**：`core-optdex-ws` · **性质**：纸面（team-lead 裁定「2(a) 立批先出计划」）
**前置**：bool 类 171 处已收口（PR #128）；S2 残桶 = 68 点 string↔int 待收口；S3 硬错等本批。

---

## §0 一句话

S2 残桶 68 点全部是 **「同一个 64 位字的两种看法」**（不是数值转换）：一类是 **intern 索引**（route 1，`istr_get` 即可，**不需要新语法**），
一类是 **裸字/指针**（route 2，**没有任何 bootstrap 面可用的转换**）⇒ 需**新内建 `@ptr_of`/`@str_of`**（视图语义、零代码生成），
并**同时**给 Python bootstrap 补 `@name(args)` 产生式与发射——否则**编译器源码写不出这两个内建**（自源必须能被 bootstrap 编）。

## §1 裁定与范围

- **team-lead 裁定**：route 1（intern 索引载荷）批准；route 2（裸指针）无现成 bootstrap-safe 转换 ⇒ **2(a) 新内建另批，先出计划**（不夹带例外表）。
- **本批范围**：① `@ptr_of`/`@str_of` 两面实现（bootstrap + 自托管）；② 68 点按类归位（route 1 用 `istr_get`，route 2 用视图内建）；
  ③ 值面 e2e（**cli.cr 类目前语料零覆盖**，见 §2.3）；④ `-17` 的分流落纸（§6）。
- **不在本批**：S3 硬错（本批验收后才具备前置）；泛型/表示位等既有线。

## §2 影响面（**实测，非文本扫描**）

### §2.1 读数与坐标口径

`CORE_S1P=1 ./build/corec check src/compiler/main.cr`（改后）→ **68 点**。

⚠ **口径**：S1P 的 `line` 是**拼接源坐标**（corec 清单 45 档顺序拼接），不是档内行号。
定档方法 = **片段标定偏移**（用 ` @@ ` 源行片段在候选档中匹配，投票取众数偏移），实测偏移与票数：

| 档 | concat 偏移 | 票数 |
|---|---|---|
| `src/stdlib/cli.cr` | +783 | 29 |
| `src/compiler/parser.cr` | +4369 | 9 |
| `src/compiler/interp.cr` | +28322 | 30 |

⇒ **68 点全部落在 3 档**：`cli.cr` 29 · `interp.cr` 30 · `parser.cr` 9（三档**都在 `corec_files`** ⇒ bootstrap 必编，见 §5）。

### §2.2 两类的判别特征（同族先例 = bool←int）

| 类 | 特征（实测样例） | 语义 | 修法 |
|---|---|---|---|
| **I intern 索引** | `print(cmd_name_ni)`、`str_len(f_short_ni)`、`println(cmd_desc_ni)`（`_ni` = name-index，来自 `str_intern`） | 该 int **就是** intern 表索引 | `istr_get(i)`（**route 1，不需要新语法**） |
| **II 裸字/指针** | `w64(g_cli_cmds, off, name)`（`fn w64(buf: string, pos: int, val: int)`，`dyn_arr.cr:28`）· `ln := r64(g_cli_flags, i * 48)` 紧接 `str_len(ln)` · `w64(names, nc * 8, tok_lx(nt))` / `str_intern(r64(names, i * 8))` · `return r64(ptr, 0)`（`interp.cr:63`，`ptr` 是地址 int） | 缓冲里存的是**字符串字面值（指针字）**，读写都是同一个 64 位字 | **视图内建**（route 2） |

**根因**：`r64`/`w64` 是**无类型裸字访问器**（`buf: string` 只是「一段内存」的写法），
`val`/`返回值` 声明为 `int` ⇒ 任何「把字当串用」的点都靠 **int↔string 隐式同字**活着——与 bool←int 同族的**隐式转换接缝**。
**注意**：这不是「值错了」，所以**不能**用「跑不出错」证明修好了；必须按类给语义依据（§7.4）。

### §2.2bis **硬证据：运行期 `string` 值 = 指针**（2026-09-18 实测；决定 A/B 取舍）

- `fn str_len(s: string) -> int { hdr := load64(s, -8); … }`（`src/stdlib/fmt.cr:4`）⇒ 长度存在**指针前 8 字节的头**里 ⇒ **string 值是内存指针**。
- `str_intern` 的查表用 `load_str_ptr(g_strs, si * 8)`（`dyn_arr.cr`）⇒ intern 表是**索引 → 指针**。
- ⇒ **裸字缓冲里存的是指针（默认语义）**；机制 B（改存 intern 索引）**必须同时改写入端与全部读出端**，
  且「全部读出端」不能用文本扫描枚举（调用派生的传递闭包看不见，见 [[verify-command-traps]] 第 9 条）。
  **⇒ B 不是等价替换，是**存储语义变更**；A（视图）才是零语义变更的那条。**

### §2.3 语料覆盖（空白面，必须先补）

`grep -rln "cli_cmd\|cli_flag" tests/ examples/` = **0** ⇒ `cli.cr` 类（29 点）**值面零覆盖**：
该档的「视图正确」今天**没有任何判据**，改完也无从分辨「修好了」与「没测到」（方法论第 4 类失效形态）。

## §3 机制 A（推荐）：视图内建 `@ptr_of` / `@str_of`

### §3.1 形式与语义

```core
@ptr_of(s: string) -> int      // 视图：取该串值的 64 位字（无转换、无拷贝、无运行期动作）
@str_of(p: int) -> string      // 视图：把该 64 位字看作串（同上）
```

- **不是转换**：不判空、不拷贝、不改表示；`@ptr_of(@str_of(p)) == p` 恒成立（同字往返，值面判据见 §7.3）。
- **命名**：与既有 `@` 内建风格一致（小写驼峰/下划线混用现状：`raw_int`·`sizeOf`·`NoBoundsCheck`）；建议 `ptr_of`/`str_of`。

### §3.2 四个实现点（自托管面）

| 层 | 落点（现状） | 改法 |
|---|---|---|
| parser | `parser.cr:517` 表达式位 `T_AT` → `EXPR_AT(name_ni, args=-1)`，`(args)` 由 `parse_postfix` 包成 `EXPR_CALL` | **无需改**（形态已支持） |
| checker | `checker.cr:4062` 起 `if str_eq(name, …)` 链（未知名**已 fail-closed**：`error[N01]: unknown @ builtin`，实测 rc=1） | 加两条分支：实参类型校验（`ptr_of` 收 string / `str_of` 收 int）+ 返回 `TI_INT`/`TI_STR` |
| ir_gen | `ir_gen.cr:1971` 起同形链 | 加两条：**直通**——`ast_a(args)` 求值后把同一 IR 变量按视图类型返回（**不发射指令**） |
| backend | `src/arch/x86_64/*` | 预期**零改动**（视图 = 类型登记，寄存器类是同一个 GP 字；须由判据证明而非假定，见 §7.5） |

### §3.3 为什么是「零代码生成」

`@addr(fn) -> int` 是既有同类先例（`checker.cr:4071` 只置类型；`ir_gen` 不发射机器动作）。
但**须实测**：本批要用判据证明「用了视图内建的函数，其 `.ccr`/ELF 与手写同字程序逐字节一致」，而不是靠类比。

## §4 备选机制（**枚举后逐条否**，避免「绕过问题」之嫌）

| # | 机制 | 代价 / 为何不取（或何时才取） |
|---|---|---|
| **B** | **全 route 1**：把裸字缓冲改成存 **intern 索引**（`w64(buf, off, str_intern(s))` + `r64` 读出后 `istr_get`） | **不需要任何新语法**（可**立即**修完 route 2 点），但**改变存储语义**（§2.2bis 硬证据：string 值 = 指针，默认不是索引）⇒ 需逐点证「该字从不被当作指针消费」（syscall/FFI/长度头）；**intern 表增长**（长跑内存面）；且把「无类型裸字」问题**藏进**索引约定。**适用**：仅当某点的字确实只在本档内往返（可作为 route 2 的**子集**手段） |
| **C** | 让 bootstrap 支持 **`as`**（自托管已支持：`p as string`） | `as` 是**语言级语法**（4/4 形态 bootstrap 全不支持，见 §6）；补它是**更大的面**（parser+checker+codegen 的转换语义），且 `as` 的**语义**（转换 vs 视图）本批尚未定义 ⇒ 不适合当 route 2 的载体 |
| **D** | 改 `r64`/`w64` 签名为**泛型/字类型** | 语言层缺「任意字类型」概念；等于设计新类型系统件，**远超收口批** |
| **E** | **不修**（登记为已知静默面） | 与 S3 硬错直接冲突（硬错一开，自源 68 点**当场变红**）⇒ 只是延后，不解决 |

**建议**：**A 为主**（根因面：把「同一个字」的两种看法**显式化**，不改变存储语义）；
**B 作为可选子集**——若某点经语义核对确实只在档内往返、且不想扩大语言面，可先用 route 1 收掉（**逐点给依据**，不得整批套用）。

## §5 bootstrap 面硬约束（本批真正的成本所在）

**约束**：`src/compiler/parser.cr`·`interp.cr` 与 `src/stdlib/cli.cr` **都在 `corec_files`**（bootstrap 必编）
⇒ **自源里一旦写 `@str_of(p)`，Python bootstrap 必须认识它**，否则 `build_selfhost_native.py` / `CI_JOB_NAME=check` 当场红。

**实测（bootstrap 解析面，今日）**：

| 探针 | bootstrap 结果 |
|---|---|
| `@raw_int(v)`（既有内建+实参） | `SyntaxError: 1:46: Expected TokenType.IDENT, got TokenType.LPAREN '('` |
| `@str_of(p)`（拟新增） | `SyntaxError: 1:45: Expected TokenType.IDENT, got TokenType.LPAREN '('` |
| `@sizeOf(int)` | `SyntaxError: 1:32: Expected TokenType.IDENT, got TokenType.LPAREN '('` |
| `@fast`（**表达式位**、无实参） | `SyntaxError: 1:30: Expected TokenType.IDENT, got TokenType.SEMI ';'` |

⇒ bootstrap 表达式位的 `@` **只有** `@project file::symbol`（`parser.py:557` ProjectAccess）一种产生式：
`@name` 后必须跟 IDENT，所以**任何** `@name(...)` 与裸 `@name` 都断在同一处。
**佐证（自源面）**：corec 清单 45 档**去注释去字符串后含 `@` 的行 = 0**（实测）⇒ 自源今天对 `@` 内建面**零触碰**，
这也解释了为什么这个缺口一直不可见。

**⇒ 2(a) 的必做项（bootstrap 侧）**：
1. `parser.py`：表达式位新增 `@name`（可带 `(args)`）产生式，产出与自托管同构的「内建调用」节点（或复用 call 形态）；
2. bootstrap `type_checker.py` / `ir_gen.py`：识别这两个内建名（**未知名 fail-closed**，与自托管 `N01` 对齐——不得静默当 0）；
3. `backend/x86_64_stack_asm.py`：视图直通（不发射指令）；
4. **两面一致性判据**：同一探针在 corec 与 bootstrap 两面的**行为**（rc + 运行值）必须一致（§7.2）。

## §6 `-17` 分流：两种机制 + **可执行判定程序**

`-17`（bootstrap 面限制）必须**分开记**，因为「怎么发现」与「怎么修」都不同：

| 机制 | 形态 | bootstrap 实测信号 | 自托管面 |
|---|---|---|---|
| **语法层** | `as` | `Expected SEMI, got AS 'as'`（**token 级**，且**无 `@`**） | 绿 |
| **语法层（后端算子）** | `\|` / `&` | **parse OK**，构建期 `NotImplementedError: Binary op \|`（**后端**，不是 parser） | 绿 |
| **内建表/形态** | `@name` / `@name(args)` | `Expected IDENT, got LPAREN`（带括号）或 `got SEMI`（无括号）；**判定要点 = 与「同名不带括号」对照** | `@name(args)` 已支持；**未注册名 fail-closed**（`error[N01]: unknown @ builtin` rc=1，实测） |

**判定程序（30 秒，两面各一次）**：
1. **自托管面**：`./build/corec check <探针>` → 绿 ⇒ 语言没缺，只是 bootstrap 缺；
2. **bootstrap 面**：`python3 -c` 直接用 `corec.frontend.parser.Parser(Lexer(src).tokenize()).parse_compilation_unit()`（模板见本批侦查脚本）→ 记**异常形态**；
3. **对号**：`got AS` ⇒ 语法层；parse OK 而构建期 `NotImplementedError` ⇒ 后端算子；**`Expected IDENT, got LPAREN/SEMI` ⇒ 内建形态面**；
4. **最小对拍**（把「名字」与「形态」分开）：同名两档 `@name` / `@name(x)` —— **只有带括号档红** ⇒ 缺产生式；**两档皆红** ⇒ 该 `@` 在表达式位根本不成立（如 `@fast`）。

**误读纠正（必须一并落纸）**：`@sizeOf(...)` **在语料（自托管面）可用**——`tests/suite/opt_dex_test.cr`（15 处 `@raw_int`）等档就是活证；
**在编译器源码（bootstrap 面）不可用**。「不可用」永远**要带面**说，否则会把语料面能力误判成语言缺口。

## §7 判据要件（实施批的验收线）

1. **台账逐桶**：`CORE_S1P=1 … check src/compiler/main.cr` ⇒ 68 → **0/或仅有已声明的残点**；**bool 桶仍为 0**（PR #128 的判据⑦不得回退）。
2. **两面一致**：同一探针在两面的 rc + 运行值一致；bootstrap 面**未知内建名必须 fail-closed**（正控 + 负控各一条）。
3. **值面 e2e（新增，必做）**：`tests/suite/` 新增「裸字缓冲往返」档——把串存进裸缓冲 → 读回 → 打印比较；
   **`cli.cr` 类必须有一档**（今日零覆盖，§2.3）；`@ptr_of(@str_of(p)) == p` 恒等腿。
4. **逐点语义依据**（**台账归零 ≠ 语义正确**）：每个点必须写「这个字是**索引**还是**指针**」的依据（赋值链/消费点），
   两类的修法不同；不得按文件整批套用。
5. **零行为变化**：canary 5/5 + `.ccr` 四条锁定值不动；`selftest-types`/`selftest-purity` 逐字节同基线；
   **视图内建不得改变既有程序的 IR**（§3.3 的实测要求：同字手写程序 vs 视图写法，产物逐字节一致）。
6. **突变自证**：视图内建（只回退 ir_gen 直通 ⇒ 必红）、`istr_get` 改点（各 1 处）均须「命中目标 + 必红」。
7. **S3 前置**：本批完成后 `check src/compiler` 仍须干净（今日实测 `^error[` = 0、rc=0），S3 才有前置。

## §8 版本位 / 缓存 / 安全面

- **`CIR_CACHE_VER` 不动**：新内建**只影响使用它的程序**；既有程序 IR 不变（§7.5 可执行判据背书）。
  自源两档（parser.cr/interp.cr/cli.cr）AST 变 ⇒ 其 `.cir` 条目 miss 重建，其余等价命中，身份闸兜底（同 PR #128 的论证）。
- **安全面（须裁）**：视图内建**绕过类型系统**（任意字 ↔ 串）。建议二选一：
  **(i) 仅编译期可见**（`@ptr_of` 在 checker 里要求实参为「已知为字的表达式」，如 `r64(...)`/局部 int）——软约束，易漏；
  **(ii) 标注为 unsafe 面**（要求出现在 `unsafe` 块内，与既有 `unsafe` 区域检查挂钩）——强约束，但要查 `region_check.cr` 的既有语义。
  ⇒ **建议 (ii)**，并在计划批准时定；**不得**两可。

## §9 分期与停条件

| 期 | 内容 | 判据 |
|---|---|---|
| P1 | bootstrap 面：parser 产生式 + 两内建 + fail-closed；**探针**（不碰自源） | 两面一致 + 未知名 rc=1 + `CI_JOB_NAME=check` 干净 |
| P2 | 自托管面：checker 两条分支 + ir_gen 直通 + 后端零改动**实证** | 判据 §7.5 逐字节 |
| P3 | route 1 点先归位（`istr_get`，**逐点给依据**） | 台账桶下降且逐点留痕 |
| P4 | route 2 点归位（视图内建）+ 新 e2e + 突变自证 | 台账 0 + 值面绿 |
| P5 | 落纸（`-17` 分流、覆盖边界、版本位）+ 登记 | 文档 + CI 挂点 |

**停条件**（命中即停、报 lead）：① P1 出现「自源语法面新增」的任何**别处**依赖（如 LSP 档需同步）；② 值面 e2e 出现**既有语义**分歧（说明某点实为 route 1 / 存储语义必须变）；③ canary/`.ccr` 任一锁定值漂移；④ 需要**例外表**才能过（本批禁止）。

---

### 附：本批侦查用到的实测命令（可复现）

```bash
# 台账（拼接源坐标）
CORE_S1P=1 ./build/corec check src/compiler/main.cr | grep -E '^991[78] ' > /tmp/led.txt
# 自托管面：未注册内建名 ⇒ fail-closed（实测 rc=1 · error[N01]）
./build/corec check /tmp/probe_view.cr
# bootstrap 面：@ 形态（实测 Expected IDENT, got LPAREN）
python3 -c "import sys;sys.path.insert(0,'bootstrap');from corec.frontend.lexer import Lexer;from corec.frontend.parser import Parser;Parser(Lexer('fn main() -> int { n := @sizeOf(int); return n; }').tokenize()).parse_compilation_unit()"
# 自源 @ 触碰面（去注释去字符串后）实测 = 0 行
```
