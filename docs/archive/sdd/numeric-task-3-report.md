# 数值 Task 3 报告：dex 类型核心（TY_DEX、dex 关键字、字面量、类型规则，与 float 并存期）

状态：完成
提交：`qwsonoqk 0848ccdb`，信息为 "core: dex 类型，TY_DEX + 字面量 + 类型规则（与 float 并存期）"（17 文件，+288/-81）

## 1. float 路径调研结果（确认 dex 可以走同一条路）

### 自举编译器（src/compiler/）

float 的完整路径（全部逐行读码确认）：

| 层 | 站点 | 角色 |
|---|---|---|
| ast.cr | `T_FLOAT=3`(8) / `TY_FLOAT=1`(122) / `EXPR_FLOAT=27`(206) / `TI_FLOAT=1`(296) | 字面量令牌 / 类型常量 / 字面量节点 / IR 类型索引 |
| lexer.cr:328-331 | `str_to_f64_bits(num_str)` 生成 `add_tok_int(T_FLOAT, bits)` | 浮点字面量扫描（唯一发射点）；`3.14` 生成 binary64 位模式 |
| parser.cr:84 | `lex == "float"` 生成 `TY_FLOAT` | 类型名解析（按 lexeme 匹配，不是关键字 token；float 不是 lookup_keyword 成员，T_FLOAT_TYPE=91 从未被发射） |
| parser.cr:405-411 | `T_FLOAT/T_FLOAT_F32/F64` 生成 `EXPR_FLOAT` 节点 | 字面量节点构建（_f32/_f64 宽度分支是死代码，w 恒为 0，Task 1 盘点已确认） |
| checker.cr | 12 处：类型表注册(22)/类型解析管道(368)/名称输出(474)/返回类型管道(672,696,748,1196)/调用推断(877)/参数管道(1143)/字面量推断(1363)/算术规则(1416-1420)/接口分派(1597) | 全部是常量引用或名称串，没有独立逻辑 |
| ir_gen.cr | 150/196/279/291/312/363（常量管道）、482-483（字面量生成 IR_CONST）、685-696（二元运算和隐式 I2F）、974/1093（类型串） | 类型大小、逃逸判定、字面量发射、运算生成、名称输出 |
| monomorph.cr | 101（基类型名解析）、220（EXPR_FLOAT 克隆） | 泛型专用化 |
| module.cr | 366/380（extern 类型名编码） | FFI ABI 编码 |
| dump.cr:52 | `tk == 1` 生成 "float" | dump 类型名（魔数） |
| instr.cr / elf.cr | 8 处 TI_FLOAT 的 SSE2/XMM/SysV 分派 | 后端指令编码（binary64 机制） |
| lsp/analysis.cr | 36/312/900/908/955 | 类型名显示、legend 分派、内置类型名清单、令牌跨度 |

关键事实：编译器自身源码没有 `: float` 或 `-> float` 变量声明，float 只以常量、名称串和规则的形式存在。因此修改 float 类型语义不会破坏自举（编译器自己不消费 float 类型的值）。

### Python bootstrap（bootstrap/corec/，8 文件 22 处）

float 实现使用内部类型名字符串 `'float'`（`BaseType('float')`），Parser 直接按 type_name lexeme 构造 `BaseType(lexeme)`（parser.py:336）；算术提升和比较规则按 `.name` 字符串匹配；解释器和 stack_asm 使用 Python float 值（binary64 参考实现）。

## 2. TY_FLOAT 引用点数量和改名或并存决策

引用点数量：`TY_FLOAT` 19 处（6 文件）加 `TI_FLOAT` 41 处（5 文件）加 `T_FLOAT`/`EXPR_FLOAT` 约 13 处，合计约 73 处。决策：直接改名（rename）。理由：

1. 引用虽多，但全部是机械的常量引用（同一值换名，编号不变），不是逻辑分派，改名不触碰任何行为。
2. 并存期语义：改名后 float 和 dex 是同一类型（编号 1 不变），`x : float = 3.14` 与 `x : dex = 3.14` 都合法。bootstrap 既有的 float 测试（'Float Add'/'Int Float Mix'）无需迁移即可通过，遵守契约「本任务只加 dex，不改 float 站点」。
3. 后端零翻倍：TI_DEX=1 同值，instr.cr/elf.cr 的 SSE2/XMM/SysV 分派原样工作（验证：dex ELF 端到端 exit=42）。
4. 与契约终点一致：分类表的「迁移后目标形态」为「TY_FLOAT 改为 TY_DEX、TI_FLOAT 改为 TI_DEX（单一类型，dex 永远是 dex）」。本任务即达到类型层终点，Task 5/6 只需移除 float 关键字并迁移剩余名称串。
5. 计划 Task 3 的主选项就是「TY_FLOAT 改为 TY_DEX」（「新增并存」是备选）。

代价：类型名输出从 "float" 变为 "dex"（dump、LSP、错误消息），float 用户代码的诊断会显示新名。这符合过渡期语义（类型本来就是 dex 了）。

## 3. 字面量处理决策（token 层归属）

决策：token 带类型，因此直接使用 dex 字面量 token（brief 决策树的第二支）。
- `T_FLOAT=3`（字面量 token，携带类型，parser 由 token kind 直接建 EXPR 节点）改名为 `T_DEX`，编号不变。
- lexer 发射：`add_tok_int(T_DEX, str_to_f64_bits(num_str))`，保留 binary64 位模式（分类表 `dex,apx`：apx 快路径的字面量表示；精确解析是 Task 4）。
- parser：`T_DEX/T_FLOAT_F32/F64` 生成 `EXPR_DEX` 节点（type_val 为 `TY_DEX`）；后缀宽度分支原样保留（死代码，Task 6 处理）。
- checker：`EXPR_DEX` 生成 `TI_DEX`；算术规则为 int|dex；消息为 "Arithmetic operation requires int or dex"。
- ir_gen：`new_ir_var("dex", TI_DEX)` 发射 IR_CONST（cir dump 显示 `const dex = bits`，这是测试的类型层证据）。

「dex 关键字」不需要加入 lexer：float 类型名走 parser 的 lexeme 匹配（`tok_lx` 字符串比较，T_FLOAT_TYPE 是死常量，从未发射），dex 走同一条路（parser.cr:85 的 `lex == "float" || lex == "dex"`）。加关键字反而会占用标识符（`dex` 作为变量名将非法），并且与 int/bool/string 等不一致。与 Task 2 的 apx 同型（brief 的条件式要求，实测不需要）。

## 4. 改动清单

### 自举编译器（src/compiler/ + src/lsp/ + src/arch/）

| 文件 | 改动 |
|---|---|
| ast.cr | `T_FLOAT` 改为 `T_DEX`(8)、`TY_FLOAT` 改为 `TY_DEX`(122)、`EXPR_FLOAT` 改为 `EXPR_DEX`(206)、`TI_FLOAT` 改为 `TI_DEX`(296)（编号全部不变，.ccr 兼容；注释同步，含 T_FLOAT_TYPE=91 的删除说明指引） |
| lexer.cr | 331：`add_tok_int(T_DEX, ...)`；328-329 修复历史注释保留（分类表 `保留`） |
| parser.cr | 84-85：`lex == "float" \|\| lex == "dex"` 生成 `TY_DEX`（float 关键字在并存期保留，Task 6 移除）；405/412：`T_DEX` 生成 `EXPR_DEX`/`TY_DEX` |
| checker.cr | 12 处常量更名，474 名称改为 "dex"，1416-1420 消息改为 "int or dex" |
| ir_gen.cr | 常量更名 7 处，291 加 "dex"，482 变量名改为 "dex"，974/1093 类型串改为 "dex"，685 注释更新（binary64 快路径说明） |
| monomorph.cr | 101：`"float" \|\| "dex"` 生成 `TY_DEX`；220 使用 `EXPR_DEX` |
| module.cr | 366/380：`"float" \|\| "dex"` 生成 code 3（extern ABI 编码，binary64 跨 C 边界属于 apx 授权行为） |
| dump.cr | 52：`tk==1` 生成 "dex" |
| instr.cr / elf.cr | TI_FLOAT 改为 TI_DEX，共 12 处（SSE2/XMM/SysV 分派，行为零变化） |
| lsp/analysis.cr | 36/312 名称改为 "dex"；900/955 使用 `T_DEX`；908 内置类型清单加 "dex"（float 保留）；881 注释同步 |

### Python bootstrap（bootstrap/corec/，与自举侧一致）

| 文件 | 改动 |
|---|---|
| parser.py | base_types 改为 `{'int','dex',...}`；`"float"` lexeme 别名指向 `BaseType('dex')`（并存期）；FLOAT_LIT 生成 `Literal(..., 'dex')`；:24 注释同步 |
| type_checker.py | kind_map 的 'float' 改为 'dex'；算术提升 ('int','dex') 得到 dex；比较规则 ('int','dex','string') |
| interpreter.py | 默认值和常量指令使用 'dex'（Python float 值等于 binary64 参考实现） |
| ir_gen.py | gen_literal 和 2 处 kind_map 使用 'dex' |
| 保留（契约） | tokens.py 的 FLOAT_LIT、lexer.py 的 is_float/FLOAT_LIT 发射、x86_64_stack_asm.py 的 `isinstance(val, float)`、cir.py:42 docstring |

## 5. TDD 证据（RED 到 GREEN）

RED（改动前）：
- `tests/selfhost/test_dex_type.py` 为 1/2（cir dump 断言 FAIL：字面量常量名是 "float" 而不是 "dex"，`const float = 4614253070214989086`。注：`x : dex = 3.14` 在旧编译器上不报错地通过，是因为未知类型名走了宽松的 TYP_NAMED 路径；真正的类型级 RED 在 cir 断言和 bootstrap 侧）。
- `tests/bootstrap/test_dex_type.py` 为 1/3（Dex Declare/Arithmetic FAIL：`PathType(path=['dex'])`，dex 被当作未知命名类型；Float Co-existence 守卫通过）。

GREEN（实现后加自举重建）：
- 自举侧 2/2（5 个断言：dex 声明、返回、并存守卫、推断、cir `const dex`）。
- bootstrap 侧 3/3（dex 声明加字面量 3.14、dex 算术 2.75、float 并存 3.14）。

## 6. 测试和自举回归结果

| 项 | 结果 |
|---|---|
| tests/selfhost/{dex,compile,borrow,impl,apx_tag,native_strings} | 2/2、全部通过、7/7、7/7、2/2、全部通过 |
| tests/selfhost/{native_memory,region_cfg,directory_build,lsp} | 6/6、16/16、PASS、8/8 ALL PASS |
| tests/selfhost/test_pointer_safety | 全部 PASS（Task 2 记录的偶发浮动，本次通过） |
| tests/selfhost/test_backend_bootstrap | 既有失败（stage1 产物 0644 没有执行位，Task 2 已记录） |
| tests/bootstrap/{pipeline,borrow,generics,apx_tag,dex_type} | 24/24（含 Float Add/Int Float Mix 并存通过）、4/4、2/2、5/5、3/3 |
| `build_selfhost_native.py`（nice -n 19） | BUILD SUCCESS（corec、corearch、corelsp 三个产物），bootstrap 编译改名后的编译器源码成功 |
| dex 端到端 ELF（`--static`） | `x : dex = 3.14` 加 SSE2 加/比较，exit 42（TI_DEX 后端分派验证） |
| float 关键字端到端 | `fn main() -> float` 的构建和运行与 dex 完全一致（并存） |

## 7. 对 brief 的偏差和原因

1. lexer.cr 没有加 "dex" 关键字：brief 的条件式要求是「dex 关键字」。实测 float 类型名走 parser 的 lexeme 匹配（不是关键字机制，T_FLOAT_TYPE 是死常量，从未发射），dex 走同一条路。加入关键字反而占用标识符，并且与 int/bool/string 不一致。
2. 没有做「移除 float 关键字」：brief 的 Interfaces 写了「float 关键字在 lexer/parser 移除」，但这与 brief 自身 Step 4（「float 关键字还在，两型并存期」）和控制器指示（「float 还保留，并存期」「本任务只加 dex，不改 float 站点」）矛盾。判定为过期样板（移除属于 Task 6），按控制器和 Step 4 执行。
3. 变更范围包含 src/lsp/ 和 src/arch/linux/ld/：brief 的 Files 只列了 ast/lexer/parser/checker，但四个常量（T_FLOAT/TY_FLOAT/EXPR_FLOAT/TI_FLOAT）的引用遍布 lsp/arch，不改名会导致编译断裂（常量不存在）。这是改名的必然闭包，不是越界（均为同一语义）。
4. 字面量 token 改名（T_FLOAT 改为 T_DEX）而不是新增：brief 决策树说「若 token 带类型则新增 dex 字面量 token」，而 T_FLOAT 实测携带类型（parser 直接按 kind 建 EXPR_FLOAT）。「新增」会造成 float/dex 两个字面量 token 没有区别（float 关键字仍存在，float 字面量无处归属）；改名加 float 关键字映射同一类型，实现并存，与分类表「令牌 kind 更名 T_DEX」一致。
5. 测试文件包含并存期守卫断言（`fn f() -> float` 仍通过）：brief 的测试没有列，但「两型并存期」是明确要求，补守卫以防回归。

## 8. 自审发现

### 本任务范围内

- 未知类型名的宽松路径：`x : dex = 3.14` 在旧编译器上就会不报错地通过（TYP_NAMED 前向注册），RED 依赖 cir dump 断言（真实类型证据）和 bootstrap 侧（严格报错）来证明。报告已注明，避免以后误读 RED 阶段。
- 常量更名完整性：全仓库 grep `TY_FLOAT|TI_FLOAT|EXPR_FLOAT|T_FLOAT\b` 零残留（仅历史注释）；魔数检查（`== 1`/`== 3` 类型上下文）零残留；dump.cr:52 的 `tk == 1` 魔数已改为 "dex"。
- 注释同步策略：常量更名的注释中标识符引用同步更新（ir_gen:685、analysis:881、ast.cr:108）；描述 binary64 机制的说明文字（「float 参数在 XMM」等）保留，因为分类表标记为 `保留`，机制未变。
- `.core/cache/cir` 缓存问题：测试源注入 uuid 注释规避（沿用 Task 2 模式）。
- `build_selfhost_native.py` 输出大量 checker warnings，与改动前同型同量（bootstrap checker 宽松），不是本任务引入。

### 与本任务无关的既有问题（验证时发现，均未改）

1. 自举编译器泛型加 float/dex 返回类型 bug：`fn id[T](x:T)->T` 以 float/dex 实例化后，调用点结果被按 int 处理（IR 显示 `call id[dex](a)` 后比较前插入了 IR_I2F 隐式转换），导致泛型 dex/float 比较结果错误。证明是既有问题：float 关键字版本行为逐位一致（IR 相同）；bootstrap 侧同程序结果正确（42）；本任务 diff 全是机械更名（语义零变化）。影响面是自举编译器的泛型加浮点组合（tests/suite 没有 float 用例，无回归面）。建议 Task 4/5 立项。
2. corec run 解释器的 dex/float 运算：interp 没有浮点分支（裸 64 位整数运算），float 和 dex 行为一致（均为既有问题，Task 1 盘点已注明「interp.cr 值存储为裸 64 位（无 float 分支）」）。Task 4 实现精确运算时需要一并处理。
3. `alloc x : unit` 的 dump 显示：ir_gen 的 LET alloc 类型带载为 unit（int/float 变量同样），是既有显示问题，不影响执行（后端按值槽工作）。
4. test_backend_bootstrap 的 stage1 产物 0644 没有执行位（Task 2 已记录）；corec build 输出 0644 同源（手动 chmod 后运行正常）。
