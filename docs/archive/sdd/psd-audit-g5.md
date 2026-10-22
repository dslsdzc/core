# 组 5 审查报告：opt / pass / dyn_arr / interp / dump（psd-audit-g5）

> 只读审查，未修改任何 docs/pseudocode/、src/、tools/ 文件（本报告为唯一写入物）。
> 审查日期：2026-08-09

## 审查范围与方法

- 文档：`docs/pseudocode/compiler/opt.md`（718 行）、`pass.md`（48 行）、`dyn_arr.md`（755 行）、`interp.md`（482 行）、`dump.md`（460 行）
- 源码：`src/compiler/opt.cr`（525 行）、`pass.cr`（24 行）、`dyn_arr.cr`（786 行）、`interp.cr`（384 行）、`dump.cr`（334 行）
- 基准：`docs/pseudocode/标识符对照表.md`、`docs/pseudocode/README.md`
- 方法：
  1. 覆盖率：源文件逐一枚举 fn，对照文档函数节；
  2. 语义等价：抽查 20+ 函数节（字节辅助 w8/bu8/w32/r32/w64/r64、字符串表 str_hash/str_intern/_grow_str_hash、grow_opt_meta/grow_sg、ast_fold_binary、ast_optimize_body 全部分支、alloc_registers、pass_stack_share、pass_cse、optimize_all、ir_interpret 全部操作码与调用内联、ir_var_str/type_kind_name/binop_name/ir_instr_str/cmd_ir/cmd_cir/cir_text_dump），核对条件方向、边界值、返回路径；
  3. 样式合规：作用/逻辑/测试要点三小节、无英文关键字/裸英文标识符、比较用 大于等于/小于等于/大于/小于/等于/不等于；
  4. 术语一致性：各文档「标识符对照表」与全局对照表逐条比对。

## 各维度结论

### 1. 覆盖率：部分通过（见 I-3）
- opt.md：9/9 fn 全覆盖（ast_is_const_int、ast_const_val、ast_bool_as_int、ast_fold_binary、ast_optimize_body、alloc_registers、pass_stack_share、pass_cse、optimize_all）
- pass.md：3/3（pass_before_array_access、pass_after_binary、dispatch_call）
- interp.md：1/1（ir_interpret）
- dump.md：7/7（ir_var_str、type_kind_name、binop_name、ir_instr_str、cmd_ir、cir_text_dump、cmd_cir）
- dyn_arr.md：字节辅助 6 函数、_dyncpy、grow_ir_func_meta、grow_opt_meta、grow_sg/grow_pts/grow_offsets、ast_alloc、字符串表 7 函数有独立函数节；约 60 个 grow_* 与 7 个访问器族（ast_/sym_/irv_/iri_/fi_/si_/ei_）仅以参数表/偏移表形式覆盖，`_grow` 桩函数完全未提及（文档第 118 行自声明省略，但阈值参数全部准确）。

### 2. 语义等价：未通过（C-1、I-1、I-2、I-4）
- 绝大多数函数节逐语句核对与源码等价，保真度较高的地方：pass_cse 替换映射表 16 字节/项溢出 bug、grow_ir_func_meta 双重边界检查、ir_interpret 中 hi<0 死分支、ast_optimize_body EXPR_IF 空操作标记等死代码/已知 bug 均如实保留并注释说明。
- 但 dump.md 两个命令函数的中文名-原名映射与源码对调（Critical），另有 3 处语义偏差（Important）。

### 3. 样式合规：通过（仅 Minor）
- 各函数节均含 作用/逻辑/测试要点；比较运算符全部使用中文词；逻辑节无英文关键字（interp.md 的 "（op == N：…）" 为注释性标注，可接受）。个别疑问句/命名混杂见 Minor。

### 4. 术语一致性：通过（仅 Minor）
- 各文档「标识符对照表」与全局对照表共享标识符命名一致，包括 dump.md 的 cmd_ir/cmd_cir 行（与总表一致，但两者均与源码不符，总表本身需一并修正，见 C-1）。个别文档内部不一致见 Minor。

## 分级问题清单

### Critical

- C-1 dump.md：cmd_ir / cmd_cir 中文名-原名映射与源码对调
  - 位置：功能概要（第 3 行）、标识符对照表（第 13-14 行）、函数节「命令：输出数据流图文件（cmd_cir）」（第 284-336 行）、「命令：输出控制流图文件（cmd_ir）」（第 407-455 行）、cir_text_dump 作用（第 341 行）。
  - 源码事实（dump.cr）：`cmd_ir`（第 183 行）执行 ir_gen_all + df_graph_to_dot，写出 .cir（DOT），打印 "nodes, edges"；`cmd_cir`（第 292 行）执行 lower_to_ccr + cir_text_dump，写出 .ccr 文本，打印 "functions, instrs"；cir_text_dump 的调用方是 cmd_cir（第 309 行，且第 227 行注释明确 "Shared by cmd_cir"）。
  - 文档现状：把 .cir/DOT 逻辑挂在 cmd_cir 名下（文档第 284 行起的「命令：输出数据流图文件（cmd_cir）」节内容是源码 cmd_ir 的函数体），把 .ccr 逻辑挂在 cmd_ir 名下；cir_text_dump 作用称其被「命令：输出控制流图文件（cmd_ir）」调用。
  - 影响：破坏「中文名可无歧义回源」硬性约定，按文档查 cmd_cir 会得到 .cir 逻辑，而源码中 cmd_cir 实际输出 .ccr。注意全局对照表（标识符对照表.md 第 284-285 行：命令：输出 .ccr | cmd_ir、命令：输出 .cir | cmd_cir）同样如此映射，需与文档一并修正。

### Important

- I-1 opt.md「AST 优化函数体（ast_optimize_body）」：递归调用实参被写成（body），实际应为子节点访问器
  - 位置：第 189 行（EXPR_RETURN）、194-196 行（EXPR_IF）、216 行（EXPR_UNARY）、221 行（EXPR_CALL）、246 行（EXPR_LET）、251 行（EXPR_GO）、256 行（EXPR_YIELD）、261 行（EXPR_LOOP/WHILE）、266-267 行（EXPR_FOR）、272 行（EXPR_MATCH）、282 行（EXPR_STMT）、299 行（EXPR_AS）。
  - 源码：如 `ast_optimize_body(ast_a(body))`（条件）、`ast_optimize_body(ast_b(body))`（真分支）等；文档写成 "AST 优化函数体（body）（优化条件表达式）"，既直接使用英文标识符 body，又把递归目标误写为函数自身参数，使"优化哪个子节点"语义错误。对照：EXPR_MATCH 分支体（第 275-276 行）写法正确，可作为修复示例。
- I-2 dyn_arr.md「扩展结构图数组（grow_sg）」：分配大小漏掉容量倍数
  - 位置：逻辑节第 730 行 "令 新缓冲区（nb）= 分配内存（48）"。
  - 源码：`nb := alloc(nc * ESZ_SG)`（nc 为新容量，ESZ_SG=48）。文档写成常量 48，分配大小语义错误（其余 grow_sg/grow_pts/grow_offsets 的翻倍策略描述正确）。
- I-3 dyn_arr.md 覆盖率缺口（文档自声明，第 118 行）
  - 约 60 个 grow_* 函数与 ast_/sym_/irv_/iri_/fi_/si_/ei_ 访问器族无独立「函数」节：参数表虽含准确的 每元素字节数/最小初始容量/余量 阈值，但无逐函数 作用/逻辑/测试要点，TDD 测试要点无法逐函数推导；`_grow` 空桩函数在本文档完全未提及（全局对照表已登记为「内部：扩展数组」）。
  - 另：dyn_arr.md 函数节统一用 "###" 三级标题（字节辅助函数/扩容函数族下），与其余 4 份文档的 "## 函数" 二级标题结构不统一。
- I-4 dump.md 输出字符串字面量被译为中文，与程序实际输出不符
  - cir_text_dump 逻辑："函数："（第 349 行）、"区域："（369）、"块：标签"（378）、"状态边："（388）、"  状态：节点"（394），源码输出英文字面量 "Function: "、"Region: "、"Block: label"、"State edges:"、"  state: n"；
  - cmd_cir/cmd_ir 节："（节点数、边数）"（第 329-330 行）、"（函数数、指令数）"（第 453-454 行），源码输出 "(N nodes, M edges)"、"(N functions, M instrs)"；
  - 同节内 " -> "、" nodes, "、" edges)" 等字面量又保留原文（第 323-329 行），自相矛盾。影响 TDD 输出比对与回源。

### Minor

- M-1 opt.md 标识符对照表 原名列 8 行带中文夹注（"IR函数个数（g_ir_func_count）" 等，第 35-41、47 行），与其他文档裸原名格式不一致。
- M-2 opt.md 全局状态第 76 行 "优化元数据数组（g_opt_meta）_cap（优化元数据容量）" 命名别扭，应为「优化元数据容量（g_opt_meta_cap）」。
- M-3 opt.md ast_fold_binary 逻辑第 140-146 行（OP_NE/OP_LT/OP_GT/OP_LE/OP_GE/OP_AND/OP_OR）漏写 "（ast_bool_as_int）" 原名（OP_EQ 行第 139 行有）。
- M-4 opt.md 同一文档内 g_stack_map 两种名：标识符对照表 "x86 栈映射数组"（与总表一致）vs 全局状态（第 78 行）/逻辑（第 493 行）/测试要点（第 583 行）"栈映射数组（g_stack_map）"；alloc_registers 测试要点 7（第 481 行）"后端槽位分配（g2_slot）" 与总表「全局变量槽位（g2_slot）」不一致。
- M-5 opt.md ast_fold_binary 测试要点 5（第 164 行）"第一/第二/变量丙 字段清零" 命名混杂（变量丙 = c 的中文名，应统一为 第三子节点）；作用节（第 117 行）"表达式：整数常量（整数字面量表达式）" 与第 152 行 "整数字面量表达式（EXPR_INT）" 夹注不一致。
- M-6 dyn_arr.md str_intern/_grow_str_hash 中字符串参数 s 译为 "状态（s）"（第 537、575、581 行），同文档 str_hash 节为 "字符串指针（s）"（第 489 行），同一参数两种译名且"状态"语义错误。
- M-7 dyn_arr.md str_load8 签名 "字符位置（ci）"（第 623 行）vs 逻辑 "声明索引（ci）"（第 628 行）。
- M-8 dyn_arr.md r32 测试要点 2（第 172 行）"字节3（字节3） - 256" 重复夹注。
- M-9 dyn_arr.md _dyncpy 测试要点 2（第 217 行）"源和目标缓冲区可以重叠吗"，疑问句、模糊表述，违反禁止模糊词约定。
- M-10 dyn_arr.md 节标题 "哈希值（hash）字节（hash_bytes）"（第 506 行）与自身对照表及总表 "hash字节" 不一致。
- M-11 dyn_arr.md ast_alloc 参数 kind：签名 "类别（kind）"（第 343 行）vs 逻辑 "种类（kind）"（第 350 行）。
- M-12 interp.md load_str_ptr/store_str_ptr 节把缓冲区基址变量 b 译为 "变量乙（b）"（第 339-340、353 行），语义应为「缓冲区基址（b）」。
- M-13 pass.md dispatch_call 逻辑节（第 44 行）"参数 函数名索引（fn_ni）（函数名索引）…" 重复夹注。

## 总结论

组 5 五份文档整体保真度高（interp.md 的 ir_interpret 全部操作码、opt.md 的 alloc_registers/pass_stack_share/pass_cse 边界条件与死代码均逐语句吻合，样式与术语基本达标），但存在 1 个 Critical（dump.md 的 cmd_ir/cmd_cir 中文名-原名与源码对调，全局对照表同错需一并修）、4 个 Important（ast_optimize_body 递归实参误写为 body、grow_sg 分配大小漏容量倍数、dyn_arr 约 60 个 grow 函数无逐函数节、dump 输出字面量被汉译）及 13 个 Minor，修正后方可合入。
