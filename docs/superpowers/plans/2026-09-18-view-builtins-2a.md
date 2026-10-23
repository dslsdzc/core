# 2(a) 视图内建批（`@ptr_of` / `@str_of`）：计划（规划轮，只读侦查并写入文档；未实施）

> 实施记录：[implementation/2026-09-18-view-builtins-2a.md](../implementation/2026-09-18-view-builtins-2a.md)

日期：2026-09-18 · 工作区：`core-optdex-ws` · 性质：纸面计划（team-lead 裁定「2(a) 立批，先出计划」）

前置：bool 类 171 处已完成（PR #128）；S2 残桶 68 点 `string↔int` 待完成；S3 硬错等本批。

---

## 0. 一句话

S2 残桶 68 点全部是「同一个 64 位字的两种看法」，不是数值转换。一类是 intern 索引（route 1，用 `istr_get` 即可，不需要新语法），一类是裸字或指针（route 2，bootstrap 面没有可用的转换）。因此需要新内建 `@ptr_of`/`@str_of`（视图语义，零代码生成），同时给 Python bootstrap 补 `@name(args)` 产生式和发射，否则编译器源码写不出这两个内建，自源必须能被 bootstrap 编译。

## 1. 裁定与范围

- team-lead 裁定：route 1（intern 索引载荷）批准；route 2（原始指针）没有现成的 bootstrap-safe 转换，因此 2(a) 新内建另批，先出计划，不夹带例外表。
- 本批范围：1 `@ptr_of`/`@str_of` 两面实现（bootstrap + 自托管）；2 68 点按类归位（route 1 用 `istr_get`，route 2 用视图内建）；3 值面 e2e（`cli.cr` 类目前语料零覆盖，见 2.3 节）；4 `-17` 的分流写进文档（第 6 节）。
- 不在本批：S3 硬错（本批验收后才具备前置）；泛型、表示位等既有线。

## 2. 影响面（实测，不是文本扫描）

### 2.1 读数与坐标约定

`CORE_S1P=1 ./build/corec check src/compiler/main.cr`（改后）得到 68 点。

约定：S1P 的 `line` 是拼接源坐标（corec 清单 45 档顺序拼接），不是档内行号。定档方法为片段标定偏移：用 ` @@ ` 源行片段在候选档中匹配，投票取众数偏移。实测偏移与票数如下：

| 档 | concat 偏移 | 票数 |
|---|---|---|
| `src/stdlib/cli.cr` | +783 | 29 |
| `src/compiler/parser.cr` | +4369 | 9 |
| `src/compiler/interp.cr` | +28322 | 30 |

因此 68 点全部落在 3 档：`cli.cr` 29 点、`interp.cr` 30 点、`parser.cr` 9 点。三档都在 `corec_files`，因此 bootstrap 必然编译，见第 5 节。

### 2.2 两类的判别特征（同族先例为 bool←int）

| 类 | 特征（实测样例） | 语义 | 修法 |
|---|---|---|---|
| I intern 索引 | `print(cmd_name_ni)`、`str_len(f_short_ni)`、`println(cmd_desc_ni)`（`_ni` 为 name-index，来自 `str_intern`） | 该 int 就是 intern 表索引 | `istr_get(i)`（route 1，不需要新语法） |
| II 裸字或指针 | `w64(g_cli_cmds, off, name)`（`fn w64(buf: string, pos: int, val: int)`，`dyn_arr.cr:28`）· `ln := r64(g_cli_flags, i * 48)` 紧接 `str_len(ln)` · `w64(names, nc * 8, tok_lx(nt))` / `str_intern(r64(names, i * 8))` · `return r64(ptr, 0)`（`interp.cr:63`，`ptr` 是地址 int） | 缓冲里存的是字符串字面值（指针字），读写都是同一个 64 位字 | 视图内建（route 2） |

根因：`r64`/`w64` 是无类型裸字访问器（`buf: string` 只是「一段内存」的写法），`val` 和返回值声明为 `int`。因此任何「把字当串用」的点都依靠 int↔string 隐式同字成立，这与 bool←int 同族的隐式转换接缝。注意，这不是「值错了」，所以不能用「运行不出错」证明修好了；必须按类给出语义依据（7.4 节）。

### 2.2ter 两套表示并存（已写入文档的既有事实），分类时必须逐点判断属于哪一套

`interp.cr:70-72` 的原文注释（既有文档，不是本批新写）：

> `// Interpreter string values are intern-table indices (IR_CONST stores the index, while native ELF stores a pointer).`

即：解释器（`corec run` 或 IR 解释路径）里，string IR 值是 intern 索引（int）；原生 ELF 路径里是指针。配套面也一致：`istr_get(idx: int) -> string`、`istr_len(idx: int) -> int`、`str_load8(idx: int, ci: int) -> int`（`dyn_arr.cr:776-786`）全部接收 int 索引。

因此对 68 点的分类规则细化如下：

- 命中点在 `interp.cr`：值遵循解释器语义。若该字是 intern 索引，正解是 route 1（`istr_get`/`istr_len`，不需要新内建）；若是 `alloc(...)` 产出的地址字（构造、索引数组等），才是 route 2。
- 命中点在 `cli.cr`/`parser.cr`：这两档在两种运行路径下都要成立（解释器 + 原生），裸字缓冲存的必须是同一套表示，否则两条检查分歧。因此逐点须回答「这条路径下这个字是什么」，不得只按一个面判断。这正是 7.3 节要求值面 e2e 运行两条检查的原因。

### 2.2bis 硬证据：原生 ELF 路径下 `string` 值是指针（2026-09-18 实测；决定 A/B 取舍）

- `fn str_len(s: string) -> int { hdr := load64(s, -8); … }`（`src/stdlib/fmt.cr:4`），长度存在指针前 8 字节的头里，因此 string 值是内存指针。
- `str_intern` 的查表使用 `load_str_ptr(g_strs, si * 8)`（`dyn_arr.cr`），因此 intern 表是索引到指针。
- 因此裸字缓冲里存的是指针（默认语义）。机制 B（改存 intern 索引）必须同时修改写入端和全部读出端，而「全部读出端」不能用文本扫描枚举（调用派生的传递闭包看不见，见 [[verify-command-traps]] 第 9 条）。因此 B 不是等价替换，而是存储语义变更；A（视图）才是零语义变更的方案。

### 2.3 语料覆盖（空白面，必须先补）

`grep -rln "cli_cmd\|cli_flag" tests/ examples/` = 0，因此 `cli.cr` 类（29 点）的值面零覆盖。该档的「视图正确」今天没有任何检查，改完也无从分辨「修好了」与「没测到」，属于方法论第 4 类失效形态。

## 3. 机制 A（推荐）：视图内建 `@ptr_of` / `@str_of`

### 3.1 形式与语义

```core
@ptr_of(s: string) -> int      // 视图：取该串值的 64 位字（无转换、无拷贝、无运行期动作）
@str_of(p: int) -> string      // 视图：把该 64 位字看作串（同上）
```

- 不是转换：不判空、不拷贝、不改表示；`@ptr_of(@str_of(p)) == p` 恒成立（同字往返，值面检查见 7.3 节）。
- 命名与既有 `@` 内建风格一致（现状混用小写驼峰和下划线：`raw_int`、`sizeOf`、`NoBoundsCheck`）；建议使用 `ptr_of`/`str_of`。

### 3.2 四个实现点（自托管面）

| 层 | 落点（现状） | 改法 |
|---|---|---|
| parser | `parser.cr:517` 表达式位 `T_AT` 转为 `EXPR_AT(name_ni, args=-1)`，`(args)` 由 `parse_postfix` 包成 `EXPR_CALL` | 无需改（形态已支持） |
| checker | `checker.cr:4062` 起 `if str_eq(name, …)` 链（未知名已 fail-closed：`error[N01]: unknown @ builtin`，实测 rc=1） | 增加两条分支：实参类型校验（`ptr_of` 接收 string，`str_of` 接收 int）+ 返回 `TI_INT`/`TI_STR` |
| ir_gen | `ir_gen.cr:1971` 起同形链 | 增加两条：直通，`ast_a(args)` 求值后把同一 IR 变量按视图类型返回，不发射指令 |
| backend | `src/arch/x86_64/*` | 预期零改动（视图只登记类型，寄存器类是同一个 GP 字；须由检查证明，不能假定，见 7.5 节） |

### 3.3 为什么是零代码生成

`@addr(fn) -> int` 是既有同类先例（`checker.cr:4071` 只置类型；`ir_gen` 不发射机器动作）。但须实测：本批要用检查证明「使用了视图内建的函数，其 `.ccr`/ELF 与手写同字程序逐字节一致」，不能靠类比。

## 4. 备选机制（枚举后逐条否定，避免「回避问题」之嫌）

| # | 机制 | 代价或为何不取（以及何时才取） |
|---|---|---|
| B | 全 route 1：把裸字缓冲改成存 intern 索引（`w64(buf, off, str_intern(s))` + `r64` 读出后 `istr_get`） | 不需要任何新语法，可立即修完 route 2 点。但会改变存储语义（2.2bis 节硬证据：string 值是指针，默认不是索引），因此需逐点证明「该字从不被当作指针消费」（syscall/FFI/长度头）；intern 表增长（长运行内存面）；并且把「无类型裸字」问题藏进索引约定。适用：仅当某点的字确实只在本档内往返，可作为 route 2 的子集手段 |
| C | 让 bootstrap 支持 `as`（自托管已支持 `p as string`） | `as` 是语言级语法（4/4 形态 bootstrap 全不支持，见第 6 节）。补它是更大的面（parser、checker、codegen 的转换语义），且 `as` 的语义（转换还是视图）本批尚未定义，因此不适合作为 route 2 的实现方式 |
| D | 改 `r64`/`w64` 签名为泛型或字类型 | 语言层缺少「任意字类型」概念，等于设计新的类型系统件，远超完成批 |
| E | 不修（登记为已知不报错地面） | 与 S3 硬错直接冲突（硬错一开，自源 68 点立即失败），只是延后，不解决 |

建议：A 为主。它把「同一个字」的两种看法显式化，不改变存储语义。B 作为可选子集：若某点经语义核对确实只在档内往返，且不想扩大语言面，可先用 route 1 收掉，逐点给出依据，不得整批套用。

## 5. bootstrap 面硬约束（本批真正的成本所在）

约束：`src/compiler/parser.cr`、`interp.cr` 和 `src/stdlib/cli.cr` 都在 `corec_files`（bootstrap 必编）。因此自源里一旦写 `@str_of(p)`，Python bootstrap 必须认识它，否则 `build_selfhost_native.py` 或 `CI_JOB_NAME=check` 会立即失败。

实测（bootstrap 解析面，今日）：

| 探针 | bootstrap 结果 |
|---|---|
| `@raw_int(v)`（既有内建 + 实参） | `SyntaxError: 1:46: Expected TokenType.IDENT, got TokenType.LPAREN '('` |
| `@str_of(p)`（拟新增） | `SyntaxError: 1:45: Expected TokenType.IDENT, got TokenType.LPAREN '('` |
| `@sizeOf(int)` | `SyntaxError: 1:32: Expected TokenType.IDENT, got TokenType.LPAREN '('` |
| `@fast`（表达式位，无实参） | `SyntaxError: 1:30: Expected TokenType.IDENT, got TokenType.SEMI ';'` |

因此 bootstrap 表达式位的 `@` 只有 `@project file::symbol`（`parser.py:557` ProjectAccess）一种产生式：`@name` 后必须跟 IDENT，所以任何 `@name(...)` 与裸 `@name` 都在同一处失败。

> 〔加注（2026-09-18 实施批；原文一字未改，只增不删）〕本节的「约束」已随本批解除：`parser.py` 现有三种形态分流（`@name(args)`、`@name`、`@project file::symbol`，按紧随 token 判断），并有 `Builtin` 节点和未知名 fail-closed。上面三行实测信号（`got LPAREN`/`got SEMI`）只对「本批之前的 bootstrap」成立。同批新增能力面：bootstrap 侧补了 `unsafe` 支持（此前完全缺失：checker 报 `Unsupported expression`，ir_gen 报 `NotImplementedError`），凡把「bootstrap 无 unsafe」当作现状的陈述同样失效。

佐证（自源面）：corec 清单 45 档去注释、去字符串后含 `@` 的行 = 0（实测）。因此自源今天对 `@` 内建面零触碰，这也解释了这个缺口为什么一直不可见。

因此 2(a) 的必做项（bootstrap 侧）为：

1. `parser.py`：表达式位新增 `@name`（可带 `(args)`）产生式，产出与自托管同构的「内建调用」节点（或复用 call 形态）；
2. bootstrap `type_checker.py` / `ir_gen.py`：识别这两个内建名（未知名 fail-closed，与自托管 `N01` 对齐，不得不报错地当作 0）；
3. `backend/x86_64_stack_asm.py`：视图直通，不发射指令；
4. 两面一致性检查：同一探针在 corec 与 bootstrap 两面的行为（rc + 运行值）必须一致（7.2 节）。

## 6. `-17` 分流：两种机制与可执行判定程序

`-17`（bootstrap 面限制）必须分开记录，因为「怎么发现」和「怎么修」都不同：

| 机制 | 形态 | bootstrap 实测信号 | 自托管面 |
|---|---|---|---|
| 语法层 | `as` | `Expected SEMI, got AS 'as'`（token 级，且无 `@`） | 通过 |
| 语法层（后端算子） | `\|` / `&` | parse OK，构建期 `NotImplementedError: Binary op \|`（后端，不是 parser） | 通过 |
| 内建表/形态 | `@name` / `@name(args)` | `Expected IDENT, got LPAREN`（带括号）或 `got SEMI`（无括号）；判定要点是与「同名不带括号」对照 | `@name(args)` 已支持；未注册名 fail-closed（`error[N01]: unknown @ builtin` rc=1，实测） |

> 〔加注（2026-09-18 实施批；表内原文一字未改，只增不删）〕本行「内建表/形态」面已随本批（PR #132）闭合：bootstrap 侧补了 `@name(args)` 产生式、`Builtin` 节点和未知名 fail-closed，因此该信号不再是现状缺口。本表剩余有效行为上面两条语法层（`as` token 级、`|` 和 `&` 后端算子）。

判定程序（30 秒，两面各一次）：

1. 自托管面：`./build/corec check <探针>` 通过，说明语言不缺，只是 bootstrap 缺；
2. bootstrap 面：用 `python3 -c` 直接调用 `corec.frontend.parser.Parser(Lexer(src).tokenize()).parse_compilation_unit()`（模板见本批侦查脚本），记录异常形态；
3. 对号：`got AS` 属于语法层；parse OK 而构建期 `NotImplementedError` 属于后端算子；`Expected IDENT, got LPAREN/SEMI` 属于内建形态面。注意后者已随本批闭合，见上注；
4. 最小对比（把「名字」与「形态」分开）：同名两档 `@name` / `@name(x)`。只有带括号档失败，说明缺产生式；两档皆失败，说明该 `@` 在表达式位根本不成立（如 `@fast`）。

误读纠正（必须一并写入文档）：`@sizeOf(...)` 在语料（自托管面）可用，`tests/suite/opt_dex_test.cr`（15 处 `@raw_int`）等档就是活证；在编译器源码（bootstrap 面）不可用。「不可用」必须带面说明，否则会把语料面能力误判成语言缺口。

## 7. 验收要求（实施批的验收线）

1. 清单逐桶：`CORE_S1P=1 … check src/compiler/main.cr`，要求 68 变为 0，或仅剩已声明的残点；bool 桶仍为 0（PR #128 的检查7不得回退）。
2. 两面一致：同一探针在两面的 rc 和运行值一致；bootstrap 面未知内建名必须 fail-closed（正控和负控各一条）。
3. 值面 e2e（新增，必做）：`tests/suite/` 新增「裸字缓冲往返」档，把串存进裸缓冲，再读回并打印比较；`cli.cr` 类必须有一档（今日零覆盖，2.3 节）；`@ptr_of(@str_of(p)) == p` 恒等检查。必须运行两条检查：解释器（`corec run`）和原生 ELF（`build --static`）。由于 2.2ter 节的两套表示，单条检查通过不证明另一条通过，这正是本类缺陷的风险面。
4. 逐点语义依据（清单归零不等于语义正确）：每个点必须写出「这个字是索引还是指针」的依据（赋值链、消费点）。两类修法不同，不得按文件整批套用。
5. 零行为变化：canary 5/5 + `.ccr` 四条固定值不动；`selftest-types`/`selftest-purity` 与基线逐字节相同；视图内建不得改变既有程序的 IR（3.3 节的实测要求：同字手写程序与视图写法，产物逐字节一致）。
6. 突变自证：视图内建（只回退 ir_gen 直通，必然失败）、`istr_get` 改点（各 1 处）均须「命中目标且必然失败」。
7. S3 前置：本批完成后 `check src/compiler` 仍须干净（今日实测 `^error[` = 0、rc=0），S3 才有前置。

## 8. 版本位、缓存与安全面

- `CIR_CACHE_VER` 不动：新内建只影响使用它的程序，既有程序 IR 不变（7.5 节有可执行检查背书）。自源三档（`parser.cr`/`interp.cr`/`cli.cr`）的 AST 变化，因此其 `.cir` 条目 miss 并重建，其余条目等价命中，身份检查作为后备（同 PR #128 的论证）。
- 安全面（须裁）：视图内建绕过类型系统（任意字与串互看）。建议二选一：
  (i) 仅编译期可见：`@ptr_of` 在 checker 里要求实参是「已知为字的表达式」，如 `r64(...)` 或局部 int。软约束，容易漏；
  (ii) 标注为 unsafe 面：要求出现在 `unsafe` 块内，与既有 `unsafe` 区域检查挂钩。强约束，但要查 `region_check.cr` 的既有语义。
  建议 (ii)，并在计划批准时决定，不得两可。

## 9. 分期与停条件

| 期 | 内容 | 检查 |
|---|---|---|
| P1 | bootstrap 面：parser 产生式 + 两内建 + fail-closed；探针不碰自源 | 两面一致 + 未知名 rc=1 + `CI_JOB_NAME=check` 干净 |
| P2 | 自托管面：checker 两条分支 + ir_gen 直通 + 后端零改动实证 | 7.5 节检查逐字节 |
| P3 | route 1 点先归位（`istr_get`，逐点给依据） | 清单桶下降且逐点记录 |
| P4 | route 2 点归位（视图内建）+ 新 e2e + 突变自证 | 清单 0 + 值面通过 |
| P5 | 写入文档（`-17` 分流、覆盖边界、版本位）+ 登记 | 文档 + CI 接入点 |

停条件（触发即停，报 lead）：1 P1 出现「自源语法面新增」的任何别处依赖（如 LSP 档需同步）；2 值面 e2e 出现既有语义分歧（说明某点实际是 route 1，或存储语义必须改变）；3 canary 或 `.ccr` 任一固定值变化；4 需要例外表才能通过（本批禁止）。

---

### 附：本批侦查用到的实测命令（可复现）

```bash
# 台账（拼接源坐标）
CORE_S1P=1 ./build/corec check src/compiler/main.cr | grep -E '^991[78] ' > /tmp/led.txt
# 自托管面：未注册内建名 则 fail-closed（实测 rc=1 · error[N01]）
./build/corec check /tmp/probe_view.cr
# bootstrap 面：@ 形态（实测 Expected IDENT, got LPAREN）
python3 -c "import sys;sys.path.insert(0,'bootstrap');from corec.frontend.lexer import Lexer;from corec.frontend.parser import Parser;Parser(Lexer('fn main() -> int { n := @sizeOf(int); return n; }').tokenize()).parse_compilation_unit()"
# 自源 @ 触碰面（去注释去字符串后）实测 = 0 行
```

---

