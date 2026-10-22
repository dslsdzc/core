# 伪代码全量翻译 审查报告，组 2（checker-1~5、ast）

审查人：只读审查员（组 2）
审查日期：2026-08-09
审查范围：docs/pseudocode/compiler/checker-1.md ~ checker-5.md、ast.md（共 6 文件）
对照源码：src/compiler/checker.cr（2405 行，51 个 fn）、src/compiler/ast.cr（629 行，无 fn，纯常量/结构体/全局变量）
审查方法：覆盖率逐 fn 核对；语义等价逐条对照（抽查覆盖全部 51 个函数节）；样式金标准核对；术语与 docs/pseudocode/标识符对照表.md 一致性核对；并运行机械 QA（tools/pseudocode_check.py，exit 0，71 文档全通过）。

## 一、结论总览

| 维度 | 结果 |
|------|------|
| 函数覆盖率 | 通过（51/51，无遗漏） |
| 语义等价（条件方向/边界/返回路径） | 通过（未发现条件反转或差一；仅字符串字面量内容被改写，见 Important-2） |
| 样式合规（作用/逻辑/测试要点三小节、比较词） | 通过（三小节齐备、比较词合规）；例外：checker-3/5 存在裸英文标识符，见 Important-1 |
| 术语一致性（与全局术语表） | 通过（文件内对照表与全局表一致）；例外：同一系列内跨文档命名冲突，见 Important-5 |
| Critical | 0 |
| Important | 5 |
| Minor | 9 |

## 二、逐维度结果

### 1. 函数覆盖率（通过）

checker.cr 共 51 个 fn，6 个文档共 51 个「## 函数」节，一一对应、无遗漏、无多出：

- checker-1（10）：分配类型、初始化类型列表（init_types）、初始化内建、bi_add、获取类型类别/数据/额外、类型相等（type_equal）、扫描让出、检查错误
- checker-2（15）：压入/弹出作用域、定义符号、查找符号、查找gsym、查找.so函数、查找借用条目、检查借用、检查使用、压入/弹出借用作用域、压入/弹出不安全作用域、记录借用持有者、借用变量名称
- checker-3（8）：解析类型节点、查找结构体/枚举/接口、获取类型名称、类型has方法、检查接口、收集声明
- checker-4（11）：判断函数泛型、查找函数、判断结构体泛型、查找结构体按字节名称、解析调用类型、统一types、替换返回类型、类型推断泛型调用、检查函数、检查实现、检查全局声明
- checker-5（7）：扩展动态类型集数组、动态设置类型、动态has类型、联合位图、验证动态方法、类型推断表达式、检查全部

ast.cr 无函数（纯常量/结构体定义），ast.md 以常量表+结构体节覆盖全部内容（T_* 0~100、W_*、TY_*/TI_*/TYP_*/SYM_*/TAG_*、OP_*/UOP_*、EC_* 全套、IR_*、DF 结构体、ASTNode/Token/FuncInfo/StructInfo/EnumInfo/LoopInfo/FieldPair/Diag/IRVar/IRInstr/DFNode/DFEdge），数值全部与源码一致（抽查 EXPR_* 全 33 个、OP_* 全 19 个、错误码 P001~ICE03），无缺项。

### 2. 语义等价抽查（通过，>8 个函数节，实际全量对照）

抽查并全量核对：分配类型、类型相等（type_equal 各分支含元组/泛型应用递归）、扫描让出、检查借用/检查使用/弹出借用作用域（含引用计数减一与条目前移紧凑化）、解析类型节点、收集声明（14 步含热补丁 .vN 加工名/签名校验/重复定义检查/模块函数表行号边界 `fn_line <= g_line_count`）、检查函数（self_mode -1/0/1/2/3 全分支、点号扫描 load8==46、返回类型 TY_NEVER/TY_CHAR）、检查实现（含 `pti >= 8` 上限）、类型推断泛型调用（`pi >= param_count || pi >= arg_count`）、统一types、替换返回类型、动态位图四函数（2^ti 循环、`(set/bit)%2 != 0`）、类型推断表达式（全节点分支，含 if 分支 dyn 合并、go 范围 `rn <= 0`、let 借用持有者记录、@ 内建 14 个）、检查全部（SYM_SO_FN 先存后恢复、内建后注册）。

所有比较方向（大于/小于/大于等于/小于等于/等于/不等于）、边界值（-1、+1、>=0、<0、<=0、*8、*24、*32、+16）、返回路径与源码逐条等价。未发现条件反转或边界差一。

### 3. 样式合规（基本通过）

- 每个函数节均含「作用/逻辑/测试要点」三小节（脚本核对 51 节无缺）。
- 比较只用 大于等于/小于等于/大于/小于/等于/不等于，无「不小于」类双重否定。
- 逻辑节内中文名首次出现均带「（原名）」对照，无英文关键字、无 `{ } ;`。
- 例外：checker-3/checker-5 逻辑节有 6 处裸英文标识符（见 Important-1）。

### 4. 术语一致性（基本通过）

- 6 文档「标识符对照表」中所有共享标识符（fn、g_* 全局）的中文名与 docs/pseudocode/标识符对照表.md 完全一致（初始化types、类型equal、统一types、查找.so函数、bi加上 等均一致；QA 第 5 项检查亦通过）。
- 例外：同一系列内对同一常量出现不同中文名（见 Important-5）。

## 三、问题清单

### Critical（0）
无。未发现条件反转、边界差一、遗漏函数或错误返回路径。

### Important（5）

I-1. 裸英文标识符（checker-5.md / checker-3.md，逻辑节）
checker-5.md「类型推断表达式」函数节（EXPR_CALL 分支）：
- 第 462 行：`* ESZ_FUNCINFO + OFF_FI_GENERIC_NAMES +`（两处裸写）
- 第 470 行：`+ OFF_IF_METHOD_COUNT）`
- 第 475 行：`+ OFF_IFM_NAME）`
- 第 483 行：`+ OFF_IFM_RET_TI）`
checker-3.md「查找接口」函数节第 253 行：`+ OFF_IF_NAME）`
违反金标准「逻辑节无裸英文标识符（首次对照括号内的原名除外）」。注意：机械 QA 未报错是因为这些词被外层调用括号（如 `读写全局（r64）（…）`）包裹、剥括号后一并被移除，QA 盲区，人工审查必须补位。checker-4.md 同一批常量均已正确译为「函数信息条目大小（ESZ_FUNCINFO）」「接口方法：名称偏移（OFF_IFM_NAME）」等，应以 checker-4 为基准修正。

I-2. 功能性字符串字面量内容被翻译改写（语义偏差，checker-1/3/5）
字符串字面量是数据而非标识符，改写其内容会破坏运行时匹配，照抄即错；原名虽在括号内可恢复，但作为「完全形式化」目标文档属语义偏差：
- checker-1.md「初始化内建」：`bi_add` 的字符串实参被改写，`"r64"到"读 64 位（r64）"`、`"w32"到"写 32 位（w32）"`、`"w64"到"写 64 位（w64）"`、`"_dyncpy"到"内部：动态拷贝（_dyncpy）"`、`"load_str_ptr"到"字符串指针加载（load_str_ptr）"`、`"store_str_ptr"到"存储字符串指针（store_str_ptr）"`、`"fiber_init"到"纤程初始化（fiber_init）"`、`"sched_go"到"调度启动协程（sched_go）"`、`"g_set_curg"到"设置当前协程函数索引（g_set_curg）"`、`"g_get_curg"到"获取当前协程函数索引（g_get_curg）"`；且与同函数内保持原样的 `"load8"`、`"store8"`、`"load64"`、`"get_arg"`、`"sched_call_0"`、`"fiber_switch"`、`"m_start_workers"` 自相矛盾。
- checker-3.md「收集声明」第 426、432 行：`str_intern("Option")` 写成 `字符串驻留（str_intern）（"可选类型（Option）"）`（2 处），按此照抄，与用户枚举名 `"Option"` 永不相等，Option 自动注册逻辑失效。
- checker-5.md「类型推断表达式」：`str_eq` 的 14 个 @ 内建名（sizeOf/addr/alignOf/fields/hasField/field/typeInfo/comptime/inline/no_bounds_check/fast/unroll/section/hotpatch）、`"Option"`/`"Result"` 判定、`istr_get(var_ni) != "_"` 的下划线字面量均被改写为「大小计算（sizeOf）」等。同一节内 `"syscall3"` 却保留原文，处理标准不一。
建议：字面量一律保留原文（如 `"r64"`、`"Option"`、`"_"`），仅在旁注说明语义。

I-3. 局部变量 bi 误译（checker-2.md，检查借用/检查使用/弹出借用作用域）
借用索引变量 bi 在 3 处被译作「借用索引（二元信息）」（检查借用第 257、265 行，检查使用第 298 行，弹出借用作用域第 354、357 行），与同函数内其它位置的「借用索引（bi）」混用。「二元信息」不与任何标识符对应（系 bi_add 中「二元信息（bi）」的串台），破坏「每条中文名可无歧义回源」规则；语义可恢复（读/写仍指向 bi），但必须统一为「借用索引（bi）」。

I-4. 新容量 nc 误译（checker-5.md，扩展动态类型集数组）
第 114、115 行及测试要点第 125、127 行：`nc`（新容量）被误译「名称计数」，`令 新容量（名称计数） = 64`。原名为「新容量（nc）」，第 113 行已正确对照，后续行跑偏。另参数名「需求（needed）」与正文「所需条目数（needed）」不一致。语义可恢复（值正确），属命名串台。

I-5. 同一系列内跨文档术语冲突（checker-1~5 / ast.md）
以下常量不在全局术语表内，但同系列文档对同一符号给出不同中文名，需统一（建议以 checker-4 / ast.md 为准）：
- TY_INT 系基础类型：checker-1/3 用「整数（TY_INT）」，checker-4/5、ast.md 用「整数类型（TY_INT）」（TY_FLOAT/TY_BOOL/TY_STRING/TY_UNIT/TY_CHAR 同理）。
- ESZ_IFACEINFO：「接口信息大小」（checker-3/5）vs「接口信息条目大小」（checker-4）。
- ESZ_IFMETHOD：「接口方法条目大小」（checker-4）vs「接口方法大小」（checker-5）。
- OFF_IF_METHODS：「接口信息：方法列表偏移」（checker-4）vs「接口方法表偏移」（checker-5）。
- 符号类别前缀：逻辑节用「符号类别：函数（SYM_FN）」（checker-2/3/4），checker-4 测试要点第 662/663 行用「符号：类型（SYM_TYPE）」。

### Minor（9）

M-1. 「索引（索引）」类翻译伪影（checker-3/4/5，多处循环自增）
如 checker-3 第 213 行「索引（i） = 索引（索引） + 1」、checker-4 第 133/176 行、checker-5 第 589/1249/1256 行「函数遍历索引（i） = 函数遍历索引（索引） + 1」、第 213 行「位索引（pos） = 位索引（位置） + 1」、第 873 行「索引值（索引） 小于 元组元素个数」。均为局部变量 i/pos/idx 被二次翻译，语义可恢复，应统一为原名。

M-2. 函数节标题与文件内对照表命名不一致（checker-1/2/4）
标题为「## 函数 初始化类型列表（types）（init_types）」但表内为「初始化types」；「类型相等（equal）（type_equal）」vs「类型equal」；「统一类型列表（types）（unify_types）」vs「统一types」（checker-4）；「查找泛型符号（gsym）（find_gsym）」vs「查找gsym」（checker-2）。标题中「（types）」「（gsym）」为多余伪成分，偏离金标准「## 函数 中文名（原名）」格式。

M-3. checker-3 读写函数命名不一致
checker-3 逻辑节用「读写字：读 64 位（r64）/写 64 位（w64）」前缀，而其对照表与 checker-4/5 均用「读写全局（r64 / w64）」。

M-4. checker-1 对照表「首次出现函数」列指向本文档外
「驻留字符串长度 istr_len」「字符串拼接 concat」标注首次出现于「类型has方法」（在 checker-3）、「字符串哈希 str_hash」标注「驻留」（不存在该函数）。属表内信息错误。

M-5. checker-4 对照表列出未用项
「字符串拼接 concat」（infer_gen_call 实际用 `+`）、「扩展符号数组 grow_syms」「扩展函数数组 grow_funcs」标「检查全部」，checker-4 逻辑节未出现这些调用，列表与本部分内容不符。

M-6. 错误码命名风格不统一
checker-3 裸码名「EC_N_GENERIC_TYPE」；checker-5 后缀式「未定义名称错误码（EC_N_UNDEFINED）」「借用期间使用错误码（EC_B_USE_WHILE_BORROWED）」；checker-4 前缀式「类型函数错误：方法未找到（EC_TF_METHOD_NOT_FOUND）」「类型泛型错误：泛型约束不满足（EC_TG_BOUND）」。

M-7. 「类型表预分配：X（类型信息：X）」双写伪影（checker-5）
第 320、328~330、338 行等处将 TI_BOOL/TI_STR/TI_FLOAT/TI_INT 写成「类型表预分配：布尔（类型信息：布尔）」，与标准写法「类型表预分配：布尔（TI_BOOL）」混用；checker-3 测试要点第 190 行「类型信息：整数（TI_INT）」亦与逻辑节「类型表预分配：整数（TI_INT）」不一致。

M-8. 测试要点表述伪影（checker-1/3/5）
checker-1 第 333 行「向量类型（向量类型）[整数（整数）]」；checker-3 测试要点第 196~197 行「*泛型参数 泛型参数（T）（泛型参数 T）」（T 被翻译为「泛型参数」后括号内再重复）；checker-5 第 1160 行「返回 类型信息：整数（类型信息：整数）」。

M-9. ast.md 两处小瑕疵
第 364 行「整数（整数）字面量」重复伪影；第 367 行 T_FN 含义写「非保留字 `函数`（fn）」，与事实相反（fn 是关键字），疑为「保留字」笔误。

## 四、QA 工具盲区（供协调者参考，非文档缺陷）

tools/pseudocode_check.py 有两处盲区导致组 2 文档虽 exit 0 仍有上述问题漏网：
1. 函数节结构检查用 `^### 函数` 正则，而所有文档实际用 `## 函数`（两个 #），「函数节必须含作用/测试要点」检查从未生效（本次人工核对补齐）。
2. 英文残留检查在剥离「最内层括号」时会把整个外层调用表达式一并剥掉，表达式中间的裸英文（如 `* ESZ_FUNCINFO + OFF_FI_GENERIC_NAMES`）随之消失，不报错。

## 五、总结论

组 2（checker-1~5、ast）六份文档函数覆盖率 100%（51/51）、语义等价全量核对通过（无条件反转、无边界差一、无遗漏返回路径）、三小节结构与比较词合规、与全局术语表一致，机械 QA 全绿；存在 0 Critical、5 Important（裸英文标识符、功能性字符串字面量被改写、bi/nc 局部变量误译、同系列术语冲突）与 9 Minor，均为可修复的局部瑕疵，建议修复后放行。
