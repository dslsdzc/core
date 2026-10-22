# LSP Task 6 报告：semanticTokens（差分编码）

提交：`be0caa53 lsp: semanticTokens 差分编码`（commit id be0caa534975513a56100c419bf67fa2b3ee6cc6，change id wmzlmqno）

改动文件：`src/lsp/analysis.cr`、`src/lsp/lsp.cr`、`src/lsp/rpc.cr`、`tests/selfhost/test_lsp.py`
（rpc.cr 属 brief「src/lsp/」范围：能力声明 + 分发行）

---

## 1. token kind 到 tokenType 的映射表（实际清单）

唯一真源：`src/compiler/ast.cr` 常量表（执行时核对）+ `lexer.cr lookup_keyword()`/`parser.cr parse_type()`。legend 在 `rpc.cr rpc_send_initialize` 声明，顺序与 analysis.cr 下标严格一致：

| legend 下标 | tokenType | token kind（ast.cr 常量） |
|---|---|---|
| 0 | keyword | T_FN T_MUT T_IF T_ELSE T_LOOP T_FOR T_IN T_RETURN T_BREAK T_CONTINUE T_STRUCT T_ENUM T_IMPL T_PUB T_TRUE T_FALSE T_MOVE T_SELF T_MATCH T_TYPE T_MOD T_IMPORT T_AS T_GO T_AWAIT T_FLOW T_YIELD T_UNSAFE T_INTERFACE T_AUTO T_FILEID T_NONE T_SOME T_EXTERN |
| 1 | type | T_UNIT（unit 关键字令牌，parser 产 TY_UNIT）；T_INT_I8..T_FLOAT_F64（77-86）；T_INT_TYPE..T_AUTO_TYPE（90-95）；T_REF T_DYN；另：T_IDENT 且 lexeme ∈ {int,float,bool,string,char,never,dyn}（parser.cr parse_type 的 T_IDENT 分支字面量清单，`int` 等不是关键字，lexer 无对应 kind），或 find_struct_by_name / find_enum 命中 |
| 2 | function | T_IDENT 且 find_func 命中（g_funcs 快照） |
| 3 | variable | T_IDENT 后备（局部/全局/参数/未知标识符） |
| 4 | comment | 无令牌，lexer 完全跳过 `//` 与 `/* */`（验证：含注释行的源码零注释令牌输出）。保留该类仅为对齐 LSP legend |
| 5 | string | T_STRING T_CHAR |
| 6 | operator | T_LPAREN T_RPAREN T_LBRACE T_RBRACE T_COMMA T_SEMI T_COLON T_DOT T_ARROW T_EQ T_EQEQ T_BANG T_BANGEQ T_LT T_GT T_LTEQ T_GTEQ T_PLUS T_MINUS T_STAR T_SLASH T_ANDAND T_PIPEPIPE T_AMPERSAND T_UNDERSCORE T_PATHSEP T_LBRACKET T_RBRACKET T_FATARROW T_PERCENT T_DOTDOT T_DOTDOTDOT T_COLON_EQ T_AT T_QUESTION T_PLUS_EQ T_MINUS_EQ T_STAR_EQ T_SLASH_EQ |
| 7 | number | T_INT T_FLOAT（字面量令牌） |

实现：`analysis_kind_type(k)`（kind 常量链 + 连续区间，T_IDENT 返 -1）+ `analysis_token_type(ti)`（T_IDENT 按名字分类：内置类型名归为 1；find_func 命中归为 2；find_struct_by_name/find_enum 命中归为 1；后备归为 3）。

## 2. 差分编码实现要点（analysis_semantic_tokens）

- data 格式：`{"data":[delta_line, delta_start, length, tokenType, tokenModifiers, ...]}`，每组 5 整数；首令牌相对 (0,0)；delta 恒相对上一令牌起点（LSP 规范）；行/列 从 1-based 换算为 0-based（减 1）后取差；tokenModifiers 恒 0。
- 范围过滤（关键发现）：`res_imports()` 会把 stdlib `_import.cr` 的导入（如 fmt.cr）拼接进 `g_source` 并在末尾重 tokenize，`g_tokens` 覆盖全部拼接源（主文件 + 所有导入文件，测试源实测 1866 组 vs 主文件 11 组）。LSP 文档即主文件，故按「令牌起始字节偏移 < `g_seg_starts[1]`」（段 1 = 首个导入文件的拼接坐标偏移；无导入时 g_seg_count==1，覆盖全源）过滤，与 documentSymbol 的「段偏移 0」约定同构。
- 定位：令牌按源顺序，单遍扫 `g_source` 求每个令牌的起始字节偏移（列按字节计，与 lexer `skip_ws` 的 g_col 口径一致；'\r' 计列、'\n' 换行，与 skip_ws 相同）。
- 长度（三个问题，执行时实测确认）：
  1. 运算符与 int/float 字面量令牌 `lexeme = -1`（`add_tok`/`add_tok_int`）；
  2. 字符串/字符令牌 lexeme 是解码后的值（转义使源长度 ≠ 词素长度，`"hi\n"` 源长 6 ≠ 词素 4）；
  3. 「下一令牌起点 − 本令牌起点」的朴素差分会把令牌间空白计入长度（`fn ` 得 3）。
  解法 `analysis_tok_span(ti, st, sl)`：字符串/字符扫到未转义闭合引号（镜像 lexer：`\x` 4 字节、`${...}` 插值跳至 '}' 并多吃一字节、换行终止未闭合串）；数字镜像 lexer 数字分支（'.' 起始、hex/oct/bin 前缀、小数、字母后缀）；lexeme ≥ 0 者直接取 `str_len(istr_get(lex))`（标识符/关键字 = 源文本）；运算符按 kind 定长表（2 字符 15 个 + T_DOTDOTDOT 3 + 其余 1）。
- 验证过的 lexer 特殊行为：`0xFFu8` 被 lexer 切成 `0xFFu` + `8` 两个令牌（后缀扫描仅收 alpha，'8' 另起数字令牌），span 函数逐字节镜像，输出与 lexer 一致。

## 3. TDD 证据

- RED（实现前，仅加测试）：`test_semantic_tokens` 失败，`AssertionError: {'jsonrpc': '2.0', 'id': 2, 'error': {'code': -32601, 'message': 'Method not found'}}`（semanticTokens/full 未接入）。
- GREEN（实现后）：`lsp lifecycle: ALL PASS`。
- 过程中修复 2 个实现 bug（见自审）：initialize 能力 JSON 少一个闭括号（测试断言失败于 char 314 的 JSONDecodeError）、长度含空白 + 拼接源越界（assert len(groups)==10 失败，改为 11 组精确断言后全部通过）。

## 4. 测试结果（六组全部通过）

```
test_lifecycle               PASS
test_jsonrpc_error_codes     PASS
test_diagnostics_and_reset   PASS
test_hover_and_definition    PASS
test_completion_and_document_symbol  PASS
test_semantic_tokens         PASS（新增）
得到 lsp lifecycle: ALL PASS（连跑 3 次稳定）
```

新增断言：data 非空、5 的倍数、首令牌 delta_line==0 且 delta_start==0、11 组（主文件令牌数，尾空格 + 收尾 `}` 计入）、差分重建后逐令牌核对 `fn@0:0 len2 keyword`、`main@0:3 len4 function`、`int@0:13 len3 type`、`return@0:19 len6 keyword`、`42@0:26 len2 number`、`;@0:28`、`}@0:30`。

另做了手工探针验证：多行源码、字符串转义（源长 6）、hex+后缀、注释零令牌、struct/函数/局部变量分类。

## 5. 对 brief 的偏差与原因

1. 新增 rpc.cr 改动（brief 文件清单只列 analysis.cr/lsp.cr）：分发行 `textDocument/semanticTokens/full` 调用 `lsp_semantic_tokens` 在 `rpc_dispatch` 里（Task 4/5 同构），且 initialize 能力声明加 `semanticTokensProvider{legend,full:true}`，客户端据此才发 semanticTokens 请求。均在 `src/lsp/` 路径内，提交覆盖。
2. legend 增加 number(7) 类：brief 列了 keyword/type/function/variable/comment/string/operator 七类，但 T_INT/T_FLOAT 字面量必须归类，采用 LSP 标准 `number` 类（客户端主题可直接上色）。
3. 范围限定主文件：brief 未提拼接源问题，但 res_imports 拼接 stdlib 使 g_tokens 含全部导入文件令牌（行号超出文档），不滤则输出 1800+ 组无效令牌。按 documentSymbol 既有「主文件」约定过滤。
4. 长度实现变更：brief 泛称「差分编码」，未指定长度来源，lexeme 不可用（见第 2 节的三个问题），改按 kind 扫源文本（逐字节镜像 lexer）。
5. 测试源带尾空格：`fn main() -> int { return 42; }` 实为 31 字符（`42; }`），`}` 在 (0,30)，断言按实际 11 令牌写。

## 6. 自审发现

- 能力 JSON 闭括号缺失：初版 `"full":true}}}` 少一层（semanticTokensProvider 是对象需自闭一括号），JSONDecodeError 暴露，已修。
- 长度含空白 bug：初版用「下一令牌起点 − 本令牌起点」，令牌间空白计入（`fn `=3），改为按 kind 扫源。
- 拼接源越界：初版未滤主文件范围，输出了全部 stdlib 令牌，加 `g_seg_starts[1]` 过滤。
- span 函数初版分支错误：`k >= T_FN` 误覆盖运算符（T_LPAREN=24 ≥ 5），改为「lexeme ≥ 0 即源文本」不变量 + 定长表。
- 边界安全：所有扫描读均在 [0, sl]（含终止符）内，`load8(sl+1)` 因短路不执行；`alloc(0)` 防（n==0 早退）；walker 越界钳制在 sl。
- 已知问题规避：不使用名为 `match` 的变量（保留字会导致 SIGSEGV）；字符串累加全部字面量初始化累加器；本次未改被 import 的编译器文件（仅 src/lsp/），无需 clean-cache。

---

## Fix 1（补审修复）：T_WHILE 补入 keyword 映射

审查发现：`while` 关键字（T_WHILE=57，`lexer.cr` lookup_keyword 返回、`parser.cr:499` parse_while_expr 证实为活关键字）在 `analysis_kind_type` 的 kind 到 tokenType 的映射中缺失，落入默认分支返回 operator(6)。

修复内容（`src/lsp/analysis.cr` 两处同步）：
- keyword 判断链：`k == T_LOOP ||` 后插入 `k == T_WHILE ||`
- 注释映射表：`T_FN T_MUT T_IF T_ELSE T_LOOP T_WHILE T_FOR T_IN`（重排换行，与链一致）

对照 `lexer.cr lookup_keyword()` 全表核对结果：函数共返回 36 个活关键字（fn/mut/return/if/else/loop/while/for/break/continue/true/false/struct/enum/extern/impl/match/import/pub/go/await/unsafe/flow/yield/interface/type/mod/as/auto/fileid/move/self/in/None/Some/unit），逐项对照映射链，唯一遗漏项是 T_WHILE，其余 35 个均已覆盖（T_UNIT 在 type 类，语义一致）。另核实：T_ELIF/T_CONST/T_RECV/T_SELECT 在任何源中不存在；T_LET=89 为死常量（lookup_keyword 不返回、lexer 不产出）；`never`/`dyn` 等经 T_IDENT 分支由 `analysis_is_builtin_type` 处理，不受影响。

验证证据：
1. 重建：`nice -n 19 python3 build_selfhost_native.py` 得到 BUILD SUCCESS（corec、corearch、corelsp 三个产物都生成，告警均为既有的非致命项）。
2. 测试：`nice -n 19 python3 tests/selfhost/test_lsp.py`，六组全部通过（lifecycle / jsonrpc_error_codes / diagnostics_and_reset / hover_and_definition / completion_and_document_symbol / semantic_tokens），输出 `lsp lifecycle: ALL PASS`。
3. while 专项断言（临时脚本，协议同测试）：didOpen 源码 `fn main() -> int { i := 0; while i < 10 { i = i + 1; } return i; }`，semanticTokens/full 差分重建后唯一 len5 令牌 `(0,27,5,0,0)`，tokenType=0=legend['keyword']（legend: keyword/type/function/variable/comment/string/operator/number）。修复前该令牌应为 6（operator）。同流中 `return@0:55 len6` 亦为 keyword、`int` 为 type、`i` 为 variable、`10`/`42` 为 number，分类全对。列 27 符合服务器列口径（与既有测试 `int@13` 一致）。

提交：`bafde1a3 lsp: semanticTokens，T_WHILE 补入 keyword 映射（补审修复）`（change id vzwxpmnr，父提交 = develop tip vttkztyt）
