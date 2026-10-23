# 组 7 审查报告：ext_mgr / ext_safety / monomorph / provenance_verify / ptr_analysis / region_check（psd-audit-g7）

> 只读审查，未修改任何 docs/pseudocode/、src/、tools/ 文件。本报告是唯一写入物。
> 审查日期：2026-08-09

## 审查范围与方法

- 文档：`docs/pseudocode/compiler/ext_mgr.md`（176 行）、`ext_safety.md`（74 行）、`monomorph.md`（877 行）、`provenance_verify.md`（183 行）、`ptr_analysis.md`（459 行）、`region_check.md`（287 行）。
- 源码：`src/compiler/ext_mgr.cr`（93 行）、`ext_safety.cr`（37 行）、`monomorph.cr`（438 行）、`provenance_verify.cr`（90 行）、`ptr_analysis.cr`（283 行）、`region_check.cr`（156 行）。
- 基准：`docs/pseudocode/标识符对照表.md`（总表）、`docs/pseudocode/README.md`，并对照全库惯例（lexer/checker/ir_gen/module 等基准文档）。
- 方法：
  1. 覆盖率：逐个源文件枚举全部 fn，对照“## 函数”节。
  2. 语义等价：抽查 25 个以上函数节（grow_ext_reg、ext_init、ext_has、ext_reg、两个分发函数、ext_safety_init、ext_safety_on_array_access、get_alloc_size、pv_is_in_unsafe、provenance_verify_func 三分支、gen_build_subst、gen_lookup_subst、gen_base_type_tv、gen_clone_block/consecutive、gen_clone_tree 全部分支、gen_find_cached、gen_create_instance、grow_alloc_pts、pa_set_bit/has_bit、pa_merge_pts、pa_merge_alloc_pts、pa_store_to_alloc、pa_load/store、ptr_analysis_func 全部操作码分支、subgraph_containing、is_in_unsafe、alloc_seq_to_sg、rc_pts_has_escaped、rc_return_escape、rc_store_escape、region_check_func），核对条件方向、边界值和返回路径。
  3. 样式合规：作用/逻辑/测试要点三小节，无英文关键字和裸英文标识符，比较词规范。
  4. 术语一致性：文档中的共享标识符与总表逐条比对。
  5. 功能性字符串字面量：环境变量名、字符串比较字面量、错误消息、格式串是否被改写。

## 各维度结论

### 1. 覆盖率：通过（6 文件 46/46 fn 全覆盖）

- ext_mgr.md：6/6（扩展注册表容量、扩展初始化、扩展检查存在、扩展注册、扩展分发数组访问、扩展分发二元运算）。
- ext_safety.md：3/3（扩展安全初始化、扩展安全数组访问检查、扩展安全二元运算检查）。
- monomorph.md：14/14（3 个扩展函数，构建替换/查询替换/基础类型变量，去重查找/添加，克隆代码块/连续克隆/克隆树，查找缓存/查找或创建/创建实例）。
- provenance_verify.md：4/4；ptr_analysis.md：11/11；region_check.md：8/8（包含全部 3 个 unsafe 判断函数）。
- 各文档头部的源行数标注（93/37/438/90/283/156）与源码实际行数全部吻合。

### 2. 语义等价：通过（无 Critical；1 处 Important 命名自相矛盾，1 处 Minor 测试要点失实）

- 抽查全部通过：条件方向（`needed < cap` 提前返回、`count <= 0 || start < 0` 返回 -1、`iter >= 10` 上限、`off >= alloc_size` 报错、`ni > alloc_exit` 严格大于）、边界值（最小容量 8/16/64、余量 +8/+16/+64、24 字节实例条目、64 位位图循环）、返回路径（三分支检查、SG_FUNC continue、空指针集或负参数提前返回）都与源码逐条等价。
- 死代码如实保留：provenance_verify_func 中未使用的精确偏移量（prec_off）、rc_return_escape 中未使用的当前子图（cur_sg）、ext_safety_on_array_access 场景一中死条件“索引字面量 < 0”，都忠实记录。
- 例外：I-1（monomorph gen_clone_tree 引用未定义变量）和 M-4（grow_alloc_pts 测试要点失实）。

### 3. 样式合规：通过（只有 Minor）

- 46 个函数节全部包含作用/逻辑/测试要点三小节，标题统一为“## 函数”。
- 逻辑节没有英文关键字，没有裸英文标识符；比较一律使用“大于等于/小于等于/大于/小于/等于/不等于”。`/`、`%`、`*` 等算术符号按约定保留，字符码 44 保留数值。
- 少量问题见 M-2（签名格式三种风格混用、中文名重复）和 M-5（测试要点出现裸比较符号，同库 dataflow/dyn_arr 的测试要点也有同类用法，需要统一口径）。

### 4. 术语一致性：未通过（I-2、I-3）

- 全部 g_* 全局变量名与总表逐条一致，包括扩展标志、扩展已初始化标记、扩展注册数组、泛型实例表、泛型替换旧值数组、泛型去重表计数、指针集数组、偏移量数组、结构图数组、数据流节点所属 region。
- 函数名 40/46 与总表一致；6 个偏离见 I-2（monomorph 访问器族）和 I-3（3 个 unsafe 判断函数）。
- 常量名（ESZ_DFNODE/OFF_DF_*/OFF_SG_*/SG_UNSAFE/IR_*/OP_PTR_*）以“中文（原名）”形式保留，可以回源，与 cir_cache/ccr_io 等文档相同。

### 5. 功能性字符串字面量：未通过（I-4、I-5、I-6）

- 保留正确：修饰名 `"[" + 类型参数字符串 + "]"`、字符码 44（逗号）、`"1"`、`" "` 拼接结构。
- 被改写：环境变量名 “CORE_SAFE”（I-5）、基础类型名 “int”/“float”/…（I-4）、check_error 消息（I-6，与组 2 审查 I-2 同类判例）。

## 分级问题清单

### Critical

无。没有发现条件反转、边界差一或函数名错配。函数节标题与源码 fn 一一对应，没有错位。

### Important

- I-1：monomorph.md 的“泛型实例化：克隆树（gen_clone_tree）”逻辑节引用未定义变量，命名三方自相矛盾。
  - 位置：逻辑节约 40 处定义行（例如第 411、463、524-525、589-591、732-735 行）和约 26 处引用行（例如第 412、464、526、592、736 行）；标识符对照表第 54-56 行。
  - 源码事实：源码局部变量是 `a2 := gen_clone_tree(a)`、`b2`、`c2`、`d2`，ast_alloc 以 a2/b2/c2/d2 引用。
  - 文档现状：定义处写“令 克隆第一子节点（a2）”/“克隆第二子节点（b2）”/“克隆第三子节点（c2）”/“克隆数据字段（d2）”，但同一分支的 ast_alloc 调用处引用“克隆变量甲2”/“克隆变量乙2”/“克隆变量丙2”。这些名字从未定义。标识符对照表登记的又是“克隆变量甲 | a2”。定义名、引用名、对照表名三方不一致。
  - 影响：伪代码存在未定义变量引用，逐语句实现或 TDD 推导时需要自行推断“甲”到“第一子节点”的机械映射。按（a2）原名可以还原，所以不升为 Critical，但破坏了“全量逐语句”标准。建议统一为一种命名，例如对照表名“克隆变量甲（a2）”。

- I-2：monomorph.md 的 AST 访问器和函数信息访问器有 6 个共享标识符偏离总表，使用了自造名。
  - 位置：标识符对照表第 42-49 行，只登记变量甲/变量乙/变量丙/克隆变量甲等，未列访问器名；逻辑节大量出现（第 377-384、395-404 行等）、第 828 行、第 818/851 行。
  - 总表基准：ast_a 为“第一子节点访问器”，ast_b 为“第二子节点访问器”，ast_c 为“第三子节点访问器”，ast_set_a 为“AST 访问器：设置a”，fi_ast_node 为“函数信息访问器：ast节点”，fi_set_ast_node 为“函数信息访问器：设置ast节点”。
  - 文档现状：ast_a/b/c 写成“AST子节点甲/乙/丙访问器”，ast_set_a 写成“AST子节点甲设置器”，fi_ast_node 写成“函数信息访问器：语法树节点”，fi_set_ast_node 写成“函数信息访问器：设置语法树节点”。全库其余文档（ir_gen-1~4、checker-3、opt、parser-2/3、dyn_arr、cir_cache）都使用总表名。
  - 影响：违反总表“共享标识符必须使用本表名字，禁止自造”的要求。同文件测试要点又使用“第一子节点”（第 751 行），自相矛盾。按总表名统一即可。

- I-3：三个 unsafe 判断函数名偏离总表（provenance_verify.md / ptr_analysis.md / region_check.md）。
  - 位置：provenance_verify.md 第 14-17、68、118 行；ptr_analysis.md 第 9-12、55、359 行；region_check.md 第 9-12、62、220 行；以及各自标识符对照表的首次出现列。
  - 总表基准：“来源验证：判断 unsafe 块内 | pv_is_in_unsafe”“指针分析：判断 unsafe 块内 | pa_in_unsafe”“判断 unsafe 块内 | is_in_unsafe”（总表第 463/420/197 行）。
  - 文档现状：三处统一译作“判断/指针分析：判断/来源验证：判断 不安全块内”。
  - 影响：三份文档内部自洽，语义无歧义，原名在括号内。但函数节标题是主要检索键，与总表不一致会导致跨文件检索失配。建议与总表统一，或者在总表中同步登记“不安全块内”别名。

- I-4：monomorph.md 的“泛型实例化：基础类型变量（gen_base_type_tv）”中，功能性字符串比较字面量被改写。
  - 位置：逻辑节第 243-249 行。
  - 源码事实：`if s == "int" { return TY_INT; }` 等，与 “float”/“bool”/“string”/“char”/“unit”/“never” 逐字比较。这些字面量是运行时数据（类型检查器驻留的字符串）的匹配键，照抄才正确。
  - 文档现状：写成“驻留字符串 等于 整数/浮点/布尔/字符串/字符/单元/空”，原名丢失，只有 TY_INT 等返回值保留原名。
  - 影响：按伪代码实现会写出 `s == "整数"` 这种永远失配的比较。基准对照：lexer.md 的关键字比较写作“关键字文本（"函数（fn）"）”，保留原文。建议改为 “整数（int）” 这种形式。

- I-5：ext_mgr.md 的“扩展：初始化（ext_init）”中，环境变量名 “CORE_SAFE” 字面量被改写。
  - 位置：逻辑节第 74 行，写作 `获取环境变量（get_env）（参数 = "核心安全标记"）`。全局状态节第 26 行虽然有“核心安全标记（CORE_SAFE）”对照，但逻辑节没有保留原名。
  - 源码事实：`get_env("CORE_SAFE")`。环境变量名是功能性字面量，改写后会读不到该变量。
  - 基准对照：module.md 第 636 行同场景写作“获取环境变量（"HOME"）”，保留原文。建议逻辑节写作 “核心安全标记（CORE_SAFE）” 或直接写 “CORE_SAFE”。

- I-6：provenance_verify.md / region_check.md 的 check_error 消息字面量被译成中文。
  - 位置：provenance_verify.md 第 140-141 行，将 `pointer out of bounds: offset … >= size …` 改为“指针越界：偏移量 … 大于等于 分配大小 …”；region_check.md 第 166 行，将 `region escape: returning pointer to exited subgraph allocation` 改为“区域逃逸：返回指向已退出子图分配的指针”；第 241 行，将 `dangling pointer: allocation subgraph exited before deref` 改为“悬垂指针：分配子图在解引用前已退出”。
  - 影响：与组 2 审查 I-2（checker-1/3/5 同类问题判为 Important）同一判例。运行时诊断输出被改写，TDD 输出比对和形式化回源会失配。注意 checker 系列基准文档也有同样处理，属于项目级口径问题，建议统一决策：保留英文原文，或者明确消息可以翻译。按既有判例列为 Important。

### Minor

- M-1：ext_mgr.md 的“扩展注册表容量（grow_ext_reg）”作用句表述错乱。第 37 行写“确保扩展注册数组容量大于等于所需条目数 增长所需条数。”两个草稿短语叠加，句子不通，应为“确保容量大于等于增长所需条数”。
- M-2：函数签名格式混乱，中文名重复或自造。
  - ext_mgr.md 第 41 行“函数 扩展注册表容量（增长所需条数 增长所需条数：整数）”，中文名重复，原名 needed 丢失。同文件其他位置是“钩子类型 hook_type：整数”这种空格式。
  - monomorph.md 第 174/764/789/813 行“函数索引 函数原生内建索引（func_ni）”。“函数原生内建索引”是自造名；ni 在本文件惯例为名称索引，例如“名称驻留索引 name_ni”“修饰名索引 mangled_ni”“类型参数驻留索引 type_args_ni”。同一签名内与“类型参数字符串 type_args”的格式也不一致，前者是中文名（原名）嵌套，后者是中文名 原名 空格式。
  - ext_safety.md 第 41 行“数组变量（arr_var）”使用括号式。三个文件有三种签名风格，建议统一为“中文名 原名：整数”。
- M-3：ext_safety.md 的全局状态模块引用表述错乱。第 14 行“语法树模块（AST 数组（ast）.cr）”，“AST 数组”不是模块名，应写作“语法树模块（ast.cr）”。
- M-4：ptr_analysis.md 的“扩展分配指针集数组（grow_alloc_pts）”测试要点 2 与源码不符。第 102 行写“需要容量 小于容量时不扩展”，源码没有提前返回，容量充足时仍会重新分配新缓冲区并拷贝，只是翻倍循环被跳过。逻辑节本身忠实，仅测试要点失实。
- M-5：测试要点出现裸比较符号。ext_safety.md 第 57/60 行“索引字面量 >= 0”“0 >= 0”；monomorph.md 第 205 行“泛型计数 <= 0”、第 345 行“起始索引 < 0”、第 741 行“节点（node） < 0”。这与“比较只用中文词”的基准不完全一致。同库 dataflow/dyn_arr 的测试要点也有同类用法，属于口径问题。
- M-6：局部变量命名问题。
  - provenance_verify.md（第 19 行）/ region_check.md（第 24 行）/ ptr_analysis.md（第 26 行）把源码局部 `d` 记作“目标变量（d_dest）”。原名 d_dest 在源码中不存在，回源需要推断。这属于可接受的改名，但建议忠实记作（d）。
  - ptr_analysis.md 第 328-332 行的初始化循环中，vi 和 var_idx 都译为“变量索引”，同名冲突。原名可以区分，中文名应当区分。
  - 同一变量 bi 在 ptr_analysis.md 译为“位计数”，在另两个文件译为“位序号”，跨文件不一致。
- M-7：monomorph.md 的常量命名模式与全库不一致，但文件内部自洽。EXPR_* 写成“表达式类别：标识符（EXPR_IDENT）”/“表达式类别：空（EXPR_NONE）”，其他位置是“标识符表达式（EXPR_IDENT）”“空表达式（EXPR_NONE）”；TY_* 写成“类型类别：整数（TY_INT）”，其他位置是“整数类型（TY_INT）”；load8 译为“按字节读取”，ccr_io.md 译为“无符号单字节读取”，ir_gen 系列也有同类存疑先例。

## 总结论

组 7 的六份文档函数覆盖完整（46/46），语义逐条等价度高，没有 Critical，条件方向、边界和返回路径全部正确。但存在 6 项 Important：monomorph.md 克隆树逻辑节引用未定义变量，三方命名矛盾；monomorph 访问器族和三个 unsafe 判断函数名偏离总表；4 处功能性字符串字面量被改写，包括 CORE_SAFE、“int” 系列基础类型名和错误消息。修正 Important 清单后可以交付。
