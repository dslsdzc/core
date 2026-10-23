# 伪代码审查报告：组 1（lexer 和 parser-1 到 parser-4）

- 审查日期：2026-08-09
- 审查对象：
  - `docs/pseudocode/compiler/lexer.md`，源文件 `src/compiler/lexer.cr`，393 行
  - `docs/pseudocode/compiler/parser-1.md`，源行 1 到 264
  - `docs/pseudocode/compiler/parser-2.md`，源行 265 到 964
  - `docs/pseudocode/compiler/parser-3.md`，源行 966 到 1227
  - `docs/pseudocode/compiler/parser-4.md`，源行 1229 到 1691
- 对照基准：`src/compiler/lexer.cr`、`src/compiler/parser.cr`、`docs/pseudocode/标识符对照表.md`、`docs/archive/sdd/psd-translation-conventions.md`，后者为基准文档
- 审查方式：只读，没有修改 `docs/pseudocode/`、`src/`、`tools/` 中的任何文件

## 一、覆盖率（fn 到“## 函数”节）

通过。

- lexer.cr 共 14 个函数，lexer.md 有 14 个函数节，一一对应，无遗漏：is_digit、is_alpha、is_ident_char、add_error、cur_char、peek、cur_char_at、peek_at、lookup_keyword、add_tok、add_tok_int、add_tok_str、skip_ws、tokenize。
- parser.cr 共 42 个函数，parser-1 到 parser-4 合计 42 个函数节，一一对应，无遗漏：
  - parser-1（17 个）：alloc_node, cur_tok, tok_k, tok_lx, tok_iv, tok_ln, tok_cl, advance_tok, check, expect, parse_type, unpack_type, prec, tok2op, parse_expr, parse_binary, parse_unary
  - parser-2（13 个）：parse_postfix, is_upper_first, parse_primary, parse_block, is_new_var_decl, parse_new_var_decl, parse_stmt, parse_if_expr, parse_loop_expr, parse_while_expr, parse_for_expr, parse_match_expr, parse_pattern
  - parser-3（10 个）：parse_generics, parse_generics_into, save_func_generics, save_func_gen_constrs, add_func, add_struct, add_enum, extract_hotpatch_ver, parse_body, parse_ffi_annotation
  - parser-4（2 个）：parse_declaration, parse_all
- 各拆分文档标注的源行号范围与源码实际位置吻合：1 到 264、265 到 964、966 到 1227、1229 到 1691。

## 二、语义等价抽查（条件方向、边界值、返回路径、参数位）

抽查了 15 个函数节的全文，逐条对照：tokenize、lookup_keyword、skip_ws、add_tok、add_tok_int、add_tok_str、cur_char、peek，来自 lexer.md；parse_type、prec、tok2op、parse_expr、parse_binary、parse_unary，来自 parser-1.md；parse_postfix、parse_primary、parse_block、is_new_var_decl、parse_new_var_decl、parse_stmt、parse_if_expr、parse_loop_expr、parse_while_expr、parse_for_expr、parse_match_expr、parse_pattern，来自 parser-2.md；parse_generics、parse_generics_into、save_func_generics、save_func_gen_constrs、add_func、add_struct、add_enum、extract_hotpatch_ver、parse_body、parse_ffi_annotation，来自 parser-3.md；parse_declaration、parse_all，来自 parser-4.md。

除下列 1 条 Critical 外，条件方向，即大于、小于、等于，边界值，即 >=、<=、>、< 的差一，返回路径，节点字段位，即 a、b、c、iv、tv、d，以及行号列号来源，都与源码等价，没有发现条件反转或边界差一。

### Critical-1：parser-1.md 的解析一元表达式（parse_unary），UOP_NEG 节点参数位错位

- 文档第 384 行写的是：`分配 AST 节点（alloc_node）（一元表达式（EXPR_UNARY），操作数节点，取反一元操作（UOP_NEG），0，0，0，0，行，列）`。也就是 a 为操作数，b 为 UOP_NEG，c 为 0。
- 源码 `parser.cr` 第 229 行是：`return alloc_node(EXPR_UNARY, op, 0, UOP_NEG, 0, 0, 0, tok_ln(t), tok_cl(t));`。也就是 a 为 op，b 为 0，c 为 UOP_NEG。
- 证实：`ir_gen.cr` 通过 `ast_c(target) == UOP_DEREF`、`ast_c(value_node) == UOP_NEG` 读取操作码，操作码在 c 字段。
- 同一文档中 UOP_REF（b=0、c=UOP_REF）、UOP_NOT、UOP_DEREF 分支都是 b=0、c=UOP_X，只有取反分支错位，文档内部自相矛盾。
- 影响：按文档实现的一元取负节点会把操作码写入 b 字段，IR 生成会读错操作码，负号表达式被当作其他一元运算或无法识别，属于会产出错误编译结果的语义错误。

其余抽查维度全部通过。

## 三、样式合规（基准：作用、逻辑、测试要点三小节；逻辑节无英文关键字、无裸英文标识符；比较只用大于等于、小于等于、大于、小于、等于、不等于）

- 三小节结构：56 个函数节都有作用、逻辑、测试要点三小节，通过。
- 比较词：扫描全部逻辑节，没有发现“不小于”“不大于”“不足”等双重否定或非标准比较词，通过。
- 发现的问题如下。

### Important-2：parser-3.md 的逻辑节系统性出现裸英文标识符（全部 10 个函数节）

- “逻辑”节中，词法单元常量大量以裸英文形式出现，且从未给中文名：`T_LBRACKET`、`T_RBRACKET`、`T_LT`、`T_GT`、`T_COMMA`、`T_COLON`、`T_RPAREN`、`T_SELF`、`T_AMPERSAND`、`T_MUT`、`T_DOTDOTDOT`、`T_ARROW`、`T_LBRACE`、`T_STRING`、`T_EOF`、`T_EQ`、`T_SEMI`、`T_INT`、`T_RBRACE`、`T_FN`、`T_FLOW`、`T_PUB`、`T_EXTERN`、`T_AT`、`T_IDENT` 等，例如“如果检查（check）（T_LBRACKET）”。
- 违反基准文档“逻辑节无裸英文标识符，首次对照括号内的原名除外”的要求。lexer.md、parser-1.md、parser-2.md 都采用“左方括号词法单元类别（T_LBRACKET）”式的中英对照，parser-3 的风格与全组不一致。另有函数调用大量省略原名，例如“前进词法单元（）”，与同组文档“首次对照后仍以中文名（原名）混用”的做法不统一。
- 注意：这些裸常量大多位于全角括号内，QA 脚本 `pseudocode_check.py` 按括号豁免，可能放行，但按基准文档仍属样式偏离。

### Important-3：parser-4.md 的逻辑节同样存在裸英文词法单元常量和裸全局变量

- 词法单元常量裸写：`T_AT`、`T_FN`、`T_FLOW`、`T_PUB`、`T_EXTERN`、`T_FOR`、`T_IDENT`、`T_COMMA`、`T_RBRACE`、`T_LBRACE`、`T_RPAREN`、`T_SEMI`、`T_ARROW`、`T_EOF`、`T_INTERFACE`、`T_IMPL`、`T_TYPE`、`T_MOD`、`T_PATHSEP`、`T_EOF` 等，例如“如果检查（check）（T_AT）”。
- 全局变量裸写：`g_structs`、`g_enums`、`g_ifaces`、`g_methods`、`g_impl_for`、`g_mod_path_names`、`g_global_lets` 等在“写 64 位（g_methods, 方法计数 * 24, ...）”中以原名出现，没有使用中文名。对照表已给出中文名，例如方法数组、枚举数组。这同样属于样式偏离。

### Minor-4：parser-2、parser-3、parser-4.md 的“全局状态”节内容为空

- 三个拆分文档的“## 全局状态”都写“（本部分未单独列出全局变量；涉及的全局变量含义见「标识符对照表」）”。骨架要求逐条说明全局变量含义和初始值，lexer.md 和 parser-1.md 是完整版。拆分文档可以简化，但至少应补一句初始值或引用说明。

### Minor-5：parser-2、parser-3、parser-4.md 的“逻辑”节整体使用代码限制包裹，格式与 lexer.md 和 parser-1.md 不一致

- parser-2、parser-3、parser-4 的“逻辑”节整块包在代码限制内。parser-2 的逻辑中还有反引号嵌套，例如“Expected expression after `协程启动（go）`”，会破坏 Markdown 渲染和后续工具解析。属于格式不统一。

### Minor-6：lexer.md 的查关键字表（lookup_keyword）有 5 个关键字没有中文对照

- “true”“false”“type”“mod”“auto”“move”“in”以裸英文字符串出现，例如关键字文本（"true"）。同节其余 30 个关键字都采用“关键字文本（"函数（fn）"）”模式。数字后缀一行中 i8 和 i16 裸写，i32 和 i64 有对照，例如“32位整数（i32）”，同一句内规则不一致。

### Minor-7：lexer.md 的转义符中文名前后不一致

- 功能概要中换行和制表转义写作“数量（n）”“类型值（t）”，测试要点 8 又写作“换行转义符（n）”。同一标识符 n、t 有两种译名，而且“数量”“类型值”没有体现换行和制表的语义。

### Minor-8：lexer.md 的添加词法单元（add_tok）“作用”表述不精确

- “作用”写“写入类别、词素（-1）、整数值（0）”。函数实际是透传词素参数，调用方传 -1，并非固定写 -1。“逻辑”节本身正确，写的是词素，只有“作用”有误导。

## 四、术语一致性（标识符对照表对照 `docs/pseudocode/标识符对照表.md`）

- 把 lexer.md 和 parser-1 到 parser-4 的“标识符对照表”中共享标识符逐一与全局术语表比对：分词、查关键字表、跳过空白、当前字符、预读字符、预读字符（指定偏移）、判断数字、判断字母、判断标识符字符、添加错误、添加词法单元、添加整数词法单元、添加字符串词法单元、分配 AST 节点、当前词法单元、词法单元类别、词法单元词素索引、词法单元整数值、词法单元行号、词法单元列号、前进词法单元、检查（入口）、期望词法单元、解析类型、解包类型、运算符优先级、词法单元转操作码、解析表达式、解析二元表达式、解析一元表达式、解析后缀表达式、解析基本表达式、解析代码块、判断新变量声明、解析新变量声明、解析语句、解析 if、loop、while、for、match 表达式、解析模式、解析泛型参数、解析泛型参数到容器、保存函数泛型参数、保存函数泛型约束、添加函数、添加结构体、添加枚举、提取热补丁版本号、解析函数体、解析声明、解析全部、压入作用域、查找插件入口，以及全部 g_* 全局变量，包括 g_source、g_pos、g_line、g_col、g_source_len、g_tokens、g_token_count、g_errors、g_error_count、g_ast_count、g_token_pos、g_diags、g_diag_count、g_block_stmts、g_block_stmt_count、g_extra_lets、g_extra_lets_cap、g_extra_let_count、g_loop_depth、g_parse_no_struct_literal、g_plugin_tags、g_plugin_tag_count 等，还有 stdlib 工具，包括字符串驻留、驻留字符串获取、字符串切片、字符串转整数、字符串长度、字符串比较、字符串相等比较、字符构造、写 64 位、读 64 位、写单字节、扩展词法单元数组、扩展错误数组等。以上都与全局术语表一致。
- 发现的问题如下。

### Important-9：ast_a 的中文名与全局术语表冲突（parser-3.md 和 parser-4.md 逻辑节）

- 全局术语表与 parser-1、parser-2 自身的对照表都使用“第一子节点访问器（ast_a）”。但 parser-3 的提取热补丁版本号（extract_hotpatch_ver）和 parser-4 的解析声明（parse_declaration）逻辑节写作“AST访问器：变量甲（a）（ast_a）”，例如“令被调者节点（callee）等于 AST 访问器：变量甲（a）（ast_a）（注解节点）”。
- 共享标识符的中文名自行拟定，违反“共享标识符必须使用表内中文名，禁止自造”的要求。按文档实现会出现对不上术语表的命名。ast_b，即第二子节点访问器，在 parser-3 的逻辑中同样被写成“AST访问器：变量乙（b）”或“AST访问器：变量乙（b）（ast_b）”。

### Important-10：字符 'A' 被误译为“左操作数（A）”（lexer.md 和 parser-2.md）

- parser-2 的解析后缀表达式和判断首字母大写逻辑中写：“字符串比较（str_cmp）（首字符, "左操作数（A）"）大于等于 0 且…（首字符, "Z"）小于等于 0”。lexer.md 的测试要点写“大写字母（字符（'左操作数（A）'），码值 65）”。
- “左操作数”是 left operand 的误译，字符 'A' 的中文表达应为“大写字母 A”一类。同一条件中 "Z" 保持裸英文，没有对应中文表达，规则不一致。该误译跨 3 处重复出现。

### Minor-11：取字符串第 N 字符（get_char）中文名偏离

- 全局术语表为“取字符串第 N 字符 | get_char”。parser-2 的逻辑写作“取字符串第次数（N）字符（get_char（名称, 0））”。“次数（N）”是误译，N 是位置占位，不是次数，而且与术语表不一致。

### Minor-12：函数节标题出现伪原名“ffiannotation”

- parser-3 的函数节标题为“## 函数 解析外部函数接口注解（ffiannotation）（parse_ffi_annotation）”。原名应为 parse_ffi_annotation，中间的“（ffiannotation）”是伪原名，全局术语表的中文名为“解析ffiannotation”，原名只有 parse_ffi_annotation。标题格式违反“## 函数 中文名（原名）”。parser-4 的逻辑第 103 行同样出现“解析外部函数接口注解（ffiannotation）（parse_ffi_annotation）（）”。

### Minor-13：parser-3 的解析外部函数接口注解错误消息译文错乱

- 源码消息 "expected string literal for FFI language" 中的介词 "for" 被误作关键字，译成“遍历（for）”，整句译作“期望（expected）字符串（string）字面量（literal）遍历（for）外部函数接口（FFI）language”。extract_hotpatch_ver 中的字符串 "ver" 也是裸英文。属于字符串译文质量问题，不影响控制流语义。

## 五、测试要点抽查

- 各函数节的测试要点齐备，覆盖边界、代表性输入、错误路径。抽查结果与源码行为一致，例如 tokenize 把 "0..4" 拆为 T_INT(0)、T_DOTDOT、T_INT(4)，带后缀 "100u32" 得到 ival=-1，parse_binary 的复合赋值展开，parse_new_var_decl 批量声明溢出到 g_extra_lets，parse_declaration 的 impl 方法 "Type.method" 拼接等。通过。
- 发现 1 处测试样例笔误。

### Minor-14：parser-3.md 的解析函数体测试要点 4 样例串错误

- 测试要点 4 第二行写“"函数（fn） f（self） 「」" 参数数据（data）=2”。data=2 对应的是 `&自身（self）`，源码注释为 &self 到 2、&mut self 到 3，而 "f（self）" 是 data=1 的样例。应写 "f（&self）"。第一行 "f（self）" 的 data=1 是正确的，两行样例互相重复。

## 分级问题清单汇总

| 级别 | 编号 | 文件 | 函数节或位置 | 问题 |
|---|---|---|---|---|
| Critical | 1 | parser-1.md | 解析一元表达式（parse_unary） | UOP_NEG 写入 b 字段，源码为 c 字段，`ast_c` 读取操作码；同节其余 UOP 分支都正确，只有取反分支错位 |
| Important | 2 | parser-3.md | 全部 10 个函数节逻辑 | 词法单元常量裸英文，如 T_LBRACKET、T_COMMA 等，没有中文对照，违反基准文档“逻辑节无裸英文标识符” |
| Important | 3 | parser-4.md | 解析声明、解析全部逻辑 | 同 Important-2，另有 g_structs、g_methods 等全局变量裸写 |
| Important | 4 | parser-2、parser-3、parser-4.md | “全局状态”节 | 内容为空，写“本部分未单独列出”，没有说明全局变量含义和初始值 |
| Important | 9 | parser-3、parser-4.md | 提取热补丁版本号、解析声明逻辑 | ast_a、ast_b 的中文名自造为“变量甲（a）”等，与全局术语表“第一子节点访问器”冲突 |
| Important | 10 | lexer.md、parser-2.md | is_alpha 测试要点、parse_postfix 和 is_upper_first 逻辑 | 字符 'A' 误译“左操作数（A）”，跨 3 处，"Z" 裸英文 |
| Minor | 5 | parser-2、parser-3、parser-4.md | 逻辑节格式 | 代码限制包裹且含反引号嵌套，与 lexer 和 parser-1 不统一 |
| Minor | 6 | lexer.md | 查关键字表（lookup_keyword） | true、false、type、mod、auto、move、in 没有中文对照，同节其余 30 个关键字都有 |
| Minor | 7 | lexer.md | tokenize 功能概要和测试要点 | 转义符 n、t 的中文名不一致，分别为“数量（n）”和“换行转义符（n）” |
| Minor | 8 | lexer.md | 添加词法单元（add_tok）作用 | “词素（-1）”表述不精确，实际是透传参数 |
| Minor | 11 | parser-2.md | parse_postfix 和 is_upper_first 逻辑 | get_char 的中文名偏离术语表，写成“取字符串第次数（N）字符” |
| Minor | 12 | parser-3、parser-4.md | 函数节标题、解析声明 | 伪原名“ffiannotation”混入“中文名（原名）”格式 |
| Minor | 13 | parser-3.md | 解析外部函数接口注解（parse_ffi_annotation） | 错误消息中的 "for" 误译“遍历（for）”；"ver" 裸英文 |
| Minor | 14 | parser-3.md | 解析函数体（parse_body）测试要点 4 | &self（data=2）的样例串误写为 "f（self）" |

## 总结论

组 1（lexer.md 加 parser-1 到 parser-4.md）覆盖率完整，14/14、42/42 个函数节，行号范围吻合；绝大多数语义逐条等价。但存在 1 处 Critical：parser-1.md 的解析一元表达式 UOP_NEG 节点 b/c 参数位错位，会产出错误 AST。另有 3 类 Important 样式和术语偏离：parser-3、parser-4 逻辑节裸英文标识符，ast_a 中文名与全局术语表冲突，'A' 误译“左操作数”。此外有 10 处 Minor 瑕疵。需按清单返工后重跑 QA。
