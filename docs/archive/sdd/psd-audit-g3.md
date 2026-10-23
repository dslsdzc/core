# 伪代码全量翻译审查报告：组 3（ir_gen-1.md 到 ir_gen-4.md）

> 审查方式：只读。对照 `src/compiler/ir_gen.cr`（2032 行，40 个 fn）逐一核对 4 份文档的 42 个“## 函数”节，做了全量逐节语义比对、样式基准核查，以及与 `docs/pseudocode/标识符对照表.md`（1147 行）的术语一致性核查。
> 审查对象：`docs/pseudocode/compiler/ir_gen-1.md`（第 1-226 行）、`ir_gen-2.md`（第 228-648 行）、`ir_gen-3.md`（第 650-1117 行）、`ir_gen-4.md`（第 1119-2032 行）。
> 结论：有条件通过。存在 1 处 Critical 语义错误，需要修正。

---

## 一、覆盖率（通过）

源文件的 40 个 fn 全部有对应函数节，没有遗漏：

| 文档 | 函数节数 | 覆盖源函数 |
|------|---------|-----------|
| ir_gen-1.md | 19 | grow_sg_alloc、grow_sg_arena_var、sg_alloc_push、sg_alloc_pop、track_alloc_size、new_ir_var、emit、new_label、bind_local、find_local、find_global、find_global_const_node、push_ir_scope、pop_ir_scope、is_ptr_var、is_byte_buf_var、ir_call_return_type、get_ir_var_name、track_str |
| ir_gen-2.md | 12 | push_loop_labels、pop_loop_labels、get_variant_name_idx、ti_from_type_expr、type_size、type_align、ti_resolve_struct、ti_has_field、ti_field_offset、is_hotpatch_func、force_if_thunk、gen_expr（第 431-648 行） |
| ir_gen-3.md | 1 | gen_expr（续，第 650-1117 行） |
| ir_gen-4.md | 10 | gen_expr（续，第 1119-1628 行）、ir_gen_func、global_init_val、reg_one_global、ir_gen_globals、ast_patch_node、find_or_create_mono_func、ir_gen_all、func_fingerprint、sig_fingerprint |

行号范围标注与源文件逐行对应（1-226 / 228-648 / 650-1117 / 1119-2032），正确。

## 二、语义等价核对（38/40 通过，1 处 Critical）

逐条核对了全部 40 个函数，超过 8 个抽查的下限。重点核对条件方向、边界值、返回路径和 IR 操作码引用。

核对通过的重点函数如下，语义逐条等价：grow_sg_alloc（翻倍、下限 64、补 64 的逻辑）、sg_alloc_push/pop（包括 sg_alloc_pop 先读后弹再发射的顺序）、emit（六字段加 df_create_node 并行）、find_local/find_global（24 字节步长）、find_global_const_node（ast_data==0 且为 EXPR_INT/BOOL）、is_ptr_var（基本类型 IR_ALLOC 返回 0 的四类型集合）、ir_call_return_type（alloc 哨兵、内建表、TY_* 到 TI_* 的六种映射、SYM_SO_FN 编码尾两位 0-4）、type_size/type_align（TI_CHAR=4、TYP_SLICE=16/8、TYP_NAMED=64/8）、is_hotpatch_func（int_val/256 且大于 0）、gen_expr 第 2 部分（OP_AND/OP_OR 分支目标方向与短路常量 0/1、str_eq 的 OP_NE 取反为“等于 0”比较、concat、指针算术仅在两侧均非字节缓冲时改写、PTR_DIFF 仅双指针）、gen_expr 第 3 部分（EXPR_ASSIGN 的 EXPR_NONE 解包、&arr[i] 到 IR_ADDR_INDEX 的第三操作数 3、range go 的 range_count<=0 返回 -1、@fields 逗号拼接、@typeInfo 六分支、方法调用 self 压参、参数连续性检查 cur != prev+1、IR_DYN_DISPATCH/IR_HOTPATCH_ROUTE/IR_CALL_EXTERN 条件、lazy thunk 的 use_count<=1）、gen_expr 第 4 部分（EXPR_LOOP/EXPR_FOR 的 post_lbl 语义、for 条件 OP_LT、match 枚举子值绑定 fi+1 偏移、EXPR_FIELD 的 fi>0 则减 1、EXPR_LET 的 dyn/数组标注 19、IR_MAKE_ENUM/IR_ALLOC_STRUCT/IR_ALLOC_ARRAY 参数、tuple 的 alloc N*8 且 IR_STORE_FIELD、break/continue 栈顶取标签）、ir_gen_func（泛型跳过、参数扫描跳类型节点、竞技场 s1 修补、末尾 IR_RETURN）、global_init_val（UOP_NEG 折叠 0-x）、reg_one_global（24 字节三字段）、ir_gen_globals（6 个 SG、3 个 CIR、11 个运行时全局，逐个核对 17 个 str_intern 名单与源码一致）、ast_patch_node（前缀匹配加 46 判定、13 类节点递归分支逐一对应）、find_or_create_mono_func（$ 拼接、fi_set_generic_count(0)）、ir_gen_all（9 个计数器重置、g_next_label=1）、func_fingerprint/sig_fingerprint（FNV 2166136261/16777619、取模 256）。

### Critical 1（语义错误）

- 文件：ir_gen-3.md，函数节“生成表达式（gen_expr）（续）”的泛型重定向分支（第 444 行）；同文件“测试要点”第 18 条（第 549 行）。
- 问题：源码第 1034 行实际调用的是 `gen_find_or_create(func_ni, type_args)`，术语表中的中文名是“泛型实例化：查找或创建”，定义在 monomorph.cr。文档却写成“查找或创建单态化函数（find_or_create_mono_func）”。`find_or_create_mono_func` 是 ir_gen.cr 中的另一个函数（第 1869 行，签名是 (fi, call_node)），gen_expr 从未调用它。伪代码调用了错误的函数，ir_gen-3 的标识符对照表因此把 find_or_create_mono_func 的“首次出现函数”错标为 gen_expr，同时漏掉了真正被调用的 gen_find_or_create。这会给后续形式化工作带来错误的依赖关系。

## 三、术语一致性（部分通过，2 组冲突）

与 `docs/pseudocode/标识符对照表.md` 的定位点点核对后，本组涉及的约 50 个共享标识符（ir_gen 的全部函数、g_* 全局、访问器、stdlib 函数）中文名绝大多数与全局表一致，例如“查找gsym”“压入looplabels”“数据流图：创建节点”“扩展 IR 变量数组”“变量使用计数数组”“竞技场游标数组”。

### Important 1（术语冲突：ast_a/ast_b/ast_c 命名）

- 文件：ir_gen-2.md、ir_gen-3.md、ir_gen-4.md。ir_gen-1.md 全部使用表内名“第一/第二/第三子节点访问器”。
- 问题：全局术语表和 ir_gen-1 的对照表都写“第一子节点访问器（ast_a）”，但 ir_gen-2/3/4 的逻辑节大量使用“AST 访问器：变量甲（a）（ast_a）”，并且同一文件内两种叫法混用。ir_gen-2 中“变量甲”出现 3 处，“第一子节点访问器”3 处；ir_gen-3 为 15 对 20；ir_gen-4 为 31 对 22。ir_gen-2 第 399 行还出现第三种写法“AST 访问器：第一子节点（ast_a）”。共享标识符名称冲突，且前后矛盾。

### Important 2（术语冲突：force_if_thunk 命名）

- 文件：ir_gen-2.md 的“## 函数 强制 如果（if）-那么（then） 块（force_if_thunk）”。
- 问题：全局术语表的名称为“强制 if-then 块（force_if_thunk）”，ir_gen-3/4 也一致使用。ir_gen-2 的函数节标题和逻辑节改成了“强制 如果（if）-那么（then） 块”，并且 ir_gen-2 的标识符对照表遗漏了 force_if_thunk 一行。同一文件内的表和正文也对不上。

## 四、样式合规（部分通过）

- 通过项：4 份文档都没有 `{` `}` `;` 残留；逻辑节主体没有条件反转或边界差一问题；测试要点都是纯数字编号列表，没有 emoji；逻辑节主体中的比较词只使用“大于/小于/大于等于/小于等于/等于/不等于”。
- 部分通过项：函数节的“作用/逻辑/测试要点”三小节，ir_gen-1 和 ir_gen-2 全部完整；ir_gen-3 的 gen_expr 续节缺“作用”；ir_gen-4 的 gen_expr 续节缺“作用”和“测试要点”。该文档 10 个函数节中只有 9 个作用节、9 个测试要点节。

### Important 3（逻辑节系统性裸写英文操作码）

- 文件：ir_gen-2.md（IR_BRANCH、IR_LABEL、IR_JUMP、IR_STORE_INDEX_VAR、IR_BINARY 等）、ir_gen-3.md（IR_INLINE、IR_NO_BOUNDS_CHECK、IR_FAST、IR_UNROLL、IR_SECTION、IR_SPAWN、IR_DYN_DISPATCH 等）、ir_gen-4.md（IR_LABEL、IR_ARENA_NEW、IR_ARENA_RESET、IR_ALLOC、IR_LOAD_FIELD、IR_MAKE_ENUM、IR_SLICE、IR_AWAIT、IR_YIELD 等）。
- 问题：IR 操作码没有使用已经建立的“首次对照”中文名。第 1 部分已经给出“标签指令（IR_LABEL）”“跳转指令（IR_JUMP）”“条件分支指令（IR_BRANCH）”“竞技场重置指令（IR_ARENA_RESET）”等对照，第 2-4 部分多数位置直接写英文 opcode，违反“首次对照后只用中文名”的要求。另有 OP_NE（ir_gen-2 第 575 行）和 OP_LT（ir_gen-4 第 238 行）裸用，而同一文档中 OP_EQ/OP_ADD/OP_SUB/OP_PTR_ADD 等都带对照，前后矛盾。

### Important 4（@builtin 字符串字面量翻译不一致）

- 文件：ir_gen-3.md（第 265、289、300、311、339、346、351、356、362 行）、ir_gen-2.md（“concat”/“str_eq”/“sched_go”）、ir_gen-4.md（ir_gen_globals 节第 805-825 行）。
- 问题：同样是内建名或驻留字符串，有的带中文对照，例如“sizeOf”写成大小计算（sizeOf）、“alignOf”写成对齐计算（alignOf）、“addr”写成地址（addr）、“int”写成整数（int）；有的直接写英文，例如“fields”/“hasField”/“field”/“typeInfo”/“inline”/“no_bounds_check”/“fast”/“unroll”/“section”/“unknown”/“concat”/“str_eq”/“sched_go”。ir_gen_globals 中的 17 个 `字符串驻留（str_intern）（"g_sg_alloc_total"）` 等裸字符串没有翻译，也没有列入本文件的标识符对照表，对照表中没有“堆指针/竞技场游标数组”等行。处理标准不统一。

## 五、Minor（小问题）

1. gen_expr 续节缺少小节：ir_gen-3.md 续节缺“### 作用”；ir_gen-4.md 续节缺“### 作用”和“### 测试要点”。第 2 部分已经给出作用和测试要点，续节没有延续。
2. new_ir_var 省略名字参数：多处只写 `新建 IR 变量（new_ir_var）（TI_STR）`/`（TI_INT）`，省略了源码中的变量名（“str”/“zero”/“tag”/“vtag”/“cmp”/“pval”/“fld”/“elem”/“one”/“inc” 等，例如 ir_gen-2 第 425、586、601、620 行，ir_gen-4 第 257、259、304-318 行），没有做到“全量逐语句”。
3. 测试要点和注释中使用符号比较词：ir_gen-2 测试要点中的“变量甲（a） != 节点（node）”“局部变量 -> 编译时常量 -> 全局变量 -> 占位变量”“字符串 ==/!= 调用…”，以及 ir_gen-4 逻辑节注释中的“数组（arr）[low..high] -> 切片，指向 数组[low] 的指针”。基准要求比较一律使用中文词。
4. 文本问题：ir_gen-2 第 102 行“取字符串第 次数（N） 字符（get_char）”表述错乱，应为“第 N 字符”；ir_gen-1 的“动态扩展SG 分配槽总数”缺空格（第 148、177 行），测试要点“.线性指令流（ccr）”行首多一个点号（第 300 行），“驻留（Intern）池”在测试要点第 577 行裸写英文；ir_gen-4 功能概要中的“move/wildcard/enumpat/structpat/stmt/tuple”裸写英文，没有给出对照；ir_gen-3 第 504 行注释“外部函数调用：emit 外部调用指令”裸写“emit”。
5. ir_gen-2 全局状态节表述不符合事实：文中称循环标签全局“均在第 1 部分全局状态节中已有说明”，但第 1 部分全局状态节只列了 6 个 SG 全局，循环标签栈（g_ir_loop_header 等）只出现在第 1 部分的对照表中。
6. 对照表首次出现归属错误：ir_gen-2 表中“字符串按字节读取 | str_load8”和“当前源码字符串 | g_source”的首次出现函数指向第 4 部分的 ast_patch_node/func_fingerprint；ir_gen-3 表中“查找或创建单态化函数”归属 gen_expr，但该函数实际独立成节，gen_expr 调用的是另一个函数，见 Critical 1。
7. ast_patch_node 测试要点计数错误：第 3 条写“共 13 个 否则-如果 分支”，实际是 1 个主分支加 11 个否则-如果，共 12 个。
8. TY_*/TI_*/EXPR_INT 中文名跨部分不一致：ir_gen-1 使用“整数字面量类型值（TY_INT）”“单元类型值（TY_UNIT）”“单元类型索引（TI_UNIT）”“整数字面量表达式类型（EXPR_INT）”，ir_gen-2/3/4 使用“整数类型（TY_INT）”“单元类型（TY_UNIT）”“类型信息：单元（TI_UNIT）”“整数字面量表达式（EXPR_INT）”。同类常量有两种叫法。
9. find_gsym 中文名不一致：ir_gen-1 表内写“查找gsym”，ir_gen-2 逻辑节用“全局符号查找（find_gsym）”（第 151、537 行）。
10. load8 命名存疑，虽然一致，但没有声明等价：源码在 ast_patch_node/func_fingerprint/sig_fingerprint 中调用的是内建 `load8`，文档统一译作“字符串按字节读取（str_load8）”，即 dyn_arr.cr 的包装函数。术语表没有声明两者等价，存在标识符混淆风险。

## 六、通过项汇总

- 覆盖率：通过，40/40，没有遗漏函数。
- 语义等价：通过，38/40 逐条等价，Critical 1 除外。
- 样式基准（三小节、无符号残留、比较词）：第 1、2 部分通过；第 3、4 部分的 gen_expr 续节例外，见 Minor 1。
- 无 `{` `}` `;`，逻辑节主体无英文关键字（Important 3/4 所列除外）：通过。
- 术语一致性：除 Important 1、2 和 Minor 8/9 所列条目外，通过。

## 七、总结论

组 3 的四份文档整体质量较高：40/40 函数全覆盖，38 个函数语义逐条等价，没有遗漏函数，没有符号残留。但存在 1 处 Critical，即 gen_expr 泛型分支把 gen_find_or_create 误写为 find_or_create_mono_func，调用关系错误；还有 4 组 Important，分别是 ast_a 系列命名冲突、force_if_thunk 命名冲突、逻辑节裸写英文操作码、builtin 字符串字面量翻译标准不一；另有 10 项 Minor。建议修正 Critical 和 Important 后再交付。
