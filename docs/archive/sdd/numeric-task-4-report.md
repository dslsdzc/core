# 数值 Task 4 报告：dex 精确运算（定点缩放实现，本批最大的新代码块）

状态：完成
提交：`xuxmwmmw d2f1acc4`，提交信息为 "core: dex 精确运算，定点缩放实现（无 apx 走定点，有 apx 走 binary64）"（15 个文件，新增 893 行，删除 27 行）

## 1. 定点方案定稿（Task 6 验收依据）

### 表示
- dex 值使用缩放整数 int64，内部精度 S = 10^6（6 位小数）。值 x 存为 x·S，例如 3.14 存为 3140000。
- 精度常量选择从 10^9 改为 10^6 的偏差和理由：任务说明建议 10^9，但 int64 没有 128 位中间值的约束下会出现以下问题：
  - 乘法中间值 (a·S)(b·S) ≤ 9.2e18。10^9 下要求 |a|·|b| ≤ 9.2，3.14×2.86 已到边缘，10×10 溢出；10^6 下要求 ≤ 9.2e6，两个操作数都可以到 3033。
  - 除法中间值 a·S² ≤ 9.2e18。10^9 下要求 |a| ≤ 9.2，打印 10.5 都会溢出；10^6 下要求 ≤ 9.2e6。
  - 打印循环 fp×10：10^9 下 fp≥0.92 溢出，10^6 下安全。
  - 结论：10^6 让乘、除、打印在实用范围内成立，代价是 6 位小数精度，文档化为既有精度。
- IR 层区分：新增哨兵 IR 类型常量 `TI_DEX_S = 8`（精确形式），既有 `TI_DEX = 1` 表示 apx 位模式。注意 8 也是类型表首个动态类型下标，TI_DEX_S 不查类型表，type_size/type_align/is_ptr_var 三处显式守卫。后端其余分派（XMM/SSE2）按 `== TI_DEX` 判断，8 自然落入整数路径，后端零改动。

### 运算规则（ir_gen 编译为缩放整数指令序列）
| 运算 | 序列 | 约束 |
|---|---|---|
| 加/减 | 缩放整数直接加减 | \|结果\| ≤ 9.2e12 |
| 乘 | (a·b)/S | \|a\|·\|b\| ≤ 9.2e6 |
| 除 | (a·S)/b | \|a\| ≤ 9.2e6，b≠0 |
| 模 | a - trunc(a/b)·b（截断除法恒等式，5 条指令） | 同除法 |
| 比较 | 缩放整数直接比较（结果 0/1，TI_INT） | 无额外约束 |

溢出规则：int64 越界时环绕，与 int 一致，没有陷阱。这是文档化限制。
舍入规则：除法和模向零截断，与 cvttsd2si/IR_F2I 一致；字面量从第 7 位小数起四舍五入（半进，与 float_str_bits 一致）；打印去掉尾零。

### 字面量
- `3.14` 存为缩放整数 3140000。按十进制逐位构造，不使用二进制近似，lexer 新增 `str_to_scaled`。
- 字面量节点双载：`int_val` 存缩放整数，走默认路径；`a` 字段存 binary64 位模式，供 apx 路径重发射。lexer 把数字串 intern 到 token 的 lexeme 槽，parser 调用 str_to_f64_bits 还原。lexer 的位模式转换本身保留，属于 `dex,apx` 站点，不动。

### 打印
- `src/stdlib/dex.cr` 提供 `dex_str(v: dex) -> string`。它用 `@raw_int(v)` 取缩放整数原值，用纯整数运算提取整数位和小数位，去掉尾零（6.0 输出 "6"，0.1 输出 "0.1"，-0.7 输出 "-0.7"）。

## 2. apx 分流实现

- apx 形式的来源：`x : dex, apx` 变量。LET 处把初始值转成 bits，字面量直接重发射 lexer 位模式，计算值走 I2F/S 转换序列。变量的 IR 类型是 TI_DEX。
- 运算分流（ir_gen 的二元运算三路分派）：
  - 任一操作数是 TI_DEX 时走 binary64 快路径。现成的 SSE2 路径零改动。字面量操作数重发射 bits；定点（TI_DEX_S）操作数经 I2F/divsd 转成 bits，这是“apx 授权近似”契约；int 操作数经 I2F 隐式转换。
  - 任一操作数是 TI_DEX_S 时走定点路径，使用上表的指令序列。int 操作数乘 S 隐式缩放，与 apx 路径的 I2F 位置对应。
- 边界规则（已文档化）：函数参数、返回值、调用点和全局变量一律使用精确形式（缩放整数，整数寄存器 ABI）。函数返回处和调用参数处把 TI_DEX 转成 F2I(bits×S)。`ir_call_return_type` 对 Core 函数返回 dex 时给 TI_DEX_S，extern 保留 TI_DEX（C ABI binary64，FFI 属于 apx 授权场景）。`x = z` 和 LET 存储按槽位形式转换（`dex_store_adjust`）。apx 计算在函数体内生效，跨边界时按定点 6 位截断或舍入。
- 新增 `@raw_int(expr)` 内置（checker 加 ir_gen）：把 dex 表达式显式转换为缩放整数原值，兑现设计第六节“所有数值转换显式”的要求。结果复制到 TI_INT 定型变量，因为直接返回内层变量会携带 TI_DEX_S 类型，导致后续 int 运算被误分派。实现时踩过这个坑，已修。dex.cr 的打印依赖它。
- 一元负保持操作数类型（TI_DEX_S 走整数取负，通过）。apx 负值仍是整型取负，binary64 符号位翻转未实现，属于既有限制，已文档化。

## 3. 改动清单

### 自举编译器（src/compiler/ 加 src/stdlib/）
| 文件 | 改动 |
|---|---|
| ast.cr | `TI_DEX_S : int = 8`（哨兵注释：不查类型表） |
| lexer.cr | `str_to_scaled`（十进制转缩放，第 7 位半进）；T_DEX 令牌 int_val 存缩放值，lexeme 槽存数字串；`add_tok_int_lex` |
| parser.cr | EXPR_DEX 节点：`a` 存 bits（由 lexeme 槽还原），int_val 存缩放值 |
| ir_gen.cr | 字面量转 TI_DEX_S 常量；`dex_bits_to_scaled`/`dex_scaled_to_bits`/`dex_scale_int`/`dex_store_adjust`；二元运算三路分派（apx/定点/int）；MUL/DIV/MOD 指令序列；LET/ASSIGN/返回/调用参数的边界转换；参数绑定 TI_DEX 到 TI_DEX_S；`ir_call_return_type`（Core 返回 TI_DEX_S，extern 返回 TI_DEX）；全局变量类型按声明（TI_DEX_S/TI_DEX）加 dex 初始化值；一元负保持类型；@raw_int；monomorph 的 type_args/@typeInfo/type_size/type_align/is_ptr_var 处理 TI_DEX_S |
| checker.cr | @raw_int 分支。其余 dex 规则在 Task 3 已就位：dex op dex 得到 dex，int 参与得到 dex，零改动 |
| globals.cr | `g_cur_ret_ti`（返回边界转换用） |
| dump.cr | type_kind_name 的 8 输出 "dex" |
| dex.cr（新） | dex_str 加定点方案、溢出、舍入文档。文件头注释是方案定稿的权威文本 |

后端（instr.cr/elf.cr/interp.cr/dataflow/opt/ccr_io/monomorph）零改动，TI_DEX_S 落入整数路径。

### Python bootstrap（bootstrap/corec/，控制器确认的范围）
| 文件 | 改动 |
|---|---|
| ir/coreir.py | `Dex(int)` 值类加 `DEX_SCALE`。`__eq__` 对 float 按缩放语义比较，测试期望值（6.0/3.14/2.75）保持十进制语义不变，既有用例的期望值无需修改 |
| frontend/parser.py | `_str_to_scaled`，与自举侧同规则：6 位，第 7 位半进。FLOAT_LIT 转缩放整数 |
| frontend/ir_gen.py | gen_literal 和全局常量 dex 用 Dex 包装 |
| backend/interpreter.py | dex 运算分派，由 isinstance Dex 驱动：加、减、乘((a·b)/S)、除((a·S)/b，向零截断，用 `_trunc_div`，因为 Python `//` 向下取整需要修正)、模（截断恒等式）、比较；一元负保持 Dex；打印和 format 走 `_dex_str`（缩放值转十进制再去尾零）；默认值为 Dex(0) |

## 4. TDD 证据（RED 到 GREEN）

RED（改动前，旧 build/corec 加未修改的 bootstrap）：
- bootstrap：`0.1+0.2==0.3` FAIL，binary64 给出 False，这是精确语义缺失的核心证据，5/10。
- selfhost：exact arith FAIL（1/3 判别子在 binary64 下为 False，定点下为 True），cir dump 没有缩放常量，corec run FAIL，1/4。
- suite：`import dex` 解析失败，因为还没有 dex.cr。

GREEN（实现加 3 轮重建）：
- selfhost test_dex_arith 4/4（精确 ELF、apx binary64 判别、cir `const dex = 3140000`、interp 42）。
- bootstrap test_dex_arith 10/10（含 1/10 打印和格式化单测）。
- suite dex_test ALL PASS（13 个断言：3.14+2.86==6.0、0.1+0.2==0.3、1/10 打印 "0.1"、乘、除、模、负、去尾零、整数参与、变量、函数边界、1/3 判别子）。

## 5. 测试和自举回归结果

| 项 | 结果 |
|---|---|
| tests/selfhost/{dex_arith,dex_type,apx_tag,borrow,impl} | 4/4, 2/2, 2/2, 7/7, 7/7 |
| tests/selfhost/{native_strings,native_memory,region_cfg,directory_build,pointer_safety,lsp} | 全部通过 / 6/6, 16/16, PASS, 全部通过，8/8 |
| tests/selfhost/test_compile.py | All selfhost compile tests passed |
| tests/bootstrap/{pipeline,borrow,generics,apx_tag,dex_type,dex_arith} | 24/24, 4/4, 2/2, 5/5, 3/3, 10/10 |
| `build_selfhost_native.py`（nice -n 19，4 轮） | BUILD SUCCESS（corec/corearch/corelsp） |
| suite：dex_test 加 arena_test/fnaddr_test/ptr_arith/at_test | 全部 PASS（回归） |
| 额外验证 | apx 结果打印（边界截断 "0.333333"）、dex 全局变量（比较加打印）、dex mod（含负数）、@raw_int 语义 |
| test_backend_bootstrap.py | 预存在失败（stage1 权限 0644 没有执行位，Task 2/3 已记录） |
| 泛型加 dex | 预存在失败，与 float 关键字版本逐位一致，Task 3 报告 #1 已记录，未恶化 |

## 6. 与任务说明的偏差和原因

1. 精度常量从 10^9 改为 10^6：int64 没有 128 位中间值时，10^9 会使乘、除、打印在 |值|>9.2 时溢出，详见第 1 节。10^6 是实用范围，已文档化。任务说明明确写了“执行时定”。
2. dex.cr 只包含打印。加减乘除和比较在 ir_gen 的指令序列中。任务说明建议“dex.cr 提供运算辅助，如果运行时辅助需要”，实测不需要，纯指令序列可以表达；打印需要访问原始整数，所以放在 dex.cr。
3. 新增 @raw_int 内置（任务说明未列）：打印需要 dex 值的原始缩放整数，而语言没有 int 转换语法。@raw_int 是最小的显式转换，与设计第六节“所有数值转换显式”一致。checker 和 ir_gen 各一处。
4. 新增 TI_DEX_S 哨兵 IR 类型（任务说明未列）：精确形式和 apx 形式（bits）在 IR 层必须可区分，否则运算分流和 ABI 无从谈起。8 号位经过守卫处理，后端零改动，见第 1 节。
5. 边界一律使用精确形式（参数、返回、调用、全局走缩放整数和整数寄存器）：任务说明没有定义函数边界语义。这是让“精确”端到端成立的最小一致规则。apx 限于函数体内，与设计“apx 是后端变换许可”的精神一致。
6. extern dex 保留 TI_DEX 位模式直传（FFI 的二元路径不变）：binary64 跨 C 边界属于 apx 授权场景，FFI 的 dex 迁移以后再议，当前没有 in-tree 用户，已文档化。
7. bootstrap 测试期望值不变：`Dex.__eq__` 对 float 按缩放语义比较（Dex(6000000)==6.0），既有用例（'Float Add' 等）零改动通过，守住了“期望值不变”的契约。
8. checker.cr 只加 @raw_int。任务说明列的“dex 运算类型规则”经核实 Task 3 已就位（dex op dex 得到 dex，int 参与得到 dex 由同一规则覆盖），转换规则在 ir_gen 兑现，与 apx 路径的 I2F 位置对应。

## 7. 自审发现

### 本任务范围内（实现中踩坑，均已修）
1. parser 的 `tok_lx` 返回 string 而不是下标：`tl := tok_lx(t)` 后执行 `tl >= 0` 会变成字符串指针比较，运行时 istr_get 双重解引用导致 SIGSEGV。改用 `r64(g_tokens, t*ESZ_TOKEN + OFF_TK_LEXEME)`。
2. str_to_scaled 的小数位没有补齐：fp 累加原始数字（"3.14" 得到 14），必须乘以 10^(6-nd) 补足 6 位。首版 3.14 得到 3000014。bootstrap 版用 ljust，没有这个问题，两侧测试交叉验证。
3. @raw_int 返回的变量携带 TI_DEX_S 类型：`n := @raw_int(v)` 后 `n < 0` 被分派到 dex 精确路径（0 被乘 S）。必须复制为 TI_INT 定型变量。
4. cir 缓存问题：修改 ir_gen 后，dex_str 的缓存 cir 仍是旧 IR（没有 _raw 复制），clean-cache 后正确。这是三个问题之一，测试源已注入 uuid 注释规避。
5. corec run 取内联代码而不是文件：selfhost 测试传文件路径会被当作代码解析，失败。改为直接传代码串。
6. 测试驱动的 ELF 二进制权限为 0644，没有执行位，这是既有问题，测试内 chmod 0o755。

### 设计边界（已文档化，不是缺陷）
- apx 变量参与非二元上下文（例如 `dex_str(x)`、函数参数）时，在边界按 6 位定点舍入。apx 全精度显示需要 float_str_bits 这类路径，属于 Task 6 的 apx 打印迁移话题。当前 apx 结果的 binary64 行为在比较和运算中完整保留，测试断言 z == 0.3333333 为假。
- 一元负对 apx（bits）是整型取负，不是符号位翻转。这是既有 float 路径的限制，测试避开了。
- extern dex 参数原样直传缩放整数。FFI binary64 授权场景以后再议。
- `str_to_f64_bits` 有 1-2 ulp 截断，使 `0.1+0.2==0.3` 在 apx 世界可能为真，原因是字面量位模式偏移。因此 binary64/精确判别测试使用 1/3 与 0.3333333（跨多个 ulp，判别稳健）。字面量转换本身属于 `dex,apx` 站点，未动。

### 遗留（建议 Task 5/6 处理）
- `docs/numeric-migration-inventory.md` 范围外附录的 bootstrap 描述已经过时。现在使用精确缩放语义，不再是“binary64 参考实现”。建议 Task 5 顺带更新该附录。
- 泛型加 dex 的返回类型预存在 bug（Task 3 报告 #1）仍在，未恶化。
- 未初始化 dex 变量的类型传播沿用既有 TI_UNIT 怪癖（Task 3 报告 #3）。

---

## Fix 1（审查发现修复：Important 1 项加 Minor 3 项）

提交：`ttovpxlk 74094d97`，提交信息为 "core: dex LET 初始化边界转换修复 + 模运算/raw_int/跨边界测试"

### Important：LET 初始化路径跳过边界转换（ir_gen.cr LET 分支）

根因：`y : dex = x`（x 是 apx 变量，存 binary64 bits）时，LET 初始值原样存 bits，并且 `irv_set_type(var, irv_type(val_var))` 把 var 定型为 TI_DEX。y 没有 apx 标签却永久走 binary64，违反“存储和边界处按槽位形式转换”的契约。ASSIGN 路径经 dex_store_adjust 截断，是正确对照。RED 证据：修复前 `y : dex = x; 1.0/y == 0.3333333` 返回 1，因为 y 槽被塞入 3.0 的 bits，当作缩放整数使用。

修复：LET 初始值按声明类型（type 节点的 ast_type_val == TI_DEX）走槽位形式转换，与 ASSIGN 路径的 dex_store_adjust 位置对应：
- apx 声明（TI_DEX 槽）：缩放值转 bits，字面量重发射，保留原行为。
- 精确声明（TI_DEX_S 槽）：bits 值转 6 位定点缩放（F2I(bits×S)），本次新增。
- 非 dex 形式的初始值（int 等）保持原来的“保留初始值类型”行为，零回归。

连带根因修复（b2 返回点转换失效）：`ret_ti := ast_type_val(fn_node)` 读的是返回类型的节点下标，不是类型常量。parser 把类型节点存在 tv，TY_* 常量存在 FuncInfo 的 `fi_return_type(fi)`。`g_cur_ret_ti == TI_DEX` 只在 dex 类型节点下标恰好为 1 时碰巧成立。apx 返回点的 bits 到 scaled 转换因此从未可靠生效，b2 场景暴露了这个问题：跨函数 apx 返回传回 bits 垃圾。改为使用 `fi_return_type(fi)`（TY_* 与 TI_* 数值一致，0-6 全同）。main.cr 缓存命中路径的元数据写入也在同一位置修复。g_ir_func_ret_type 后端不消费，只用于元数据。

### Minor 修复
1. dex 模运算自动化测试：% 使用 5 条指令的截断恒等式，包含负数（7.0%2.5=2.0、-7.0%2.5=-2.0、1.0%0.3=0.1、-1.0%0.3=-0.1）。加入 selfhost test_dex_arith.py、suite dex_test.cr（#14-17）和 bootstrap test_dex_arith.py（新增 4 个用例）。
2. @raw_int 参数校验（checker.cr）：参数类型必须是 dex 或 int，否则报 `EC_TF_ARG_TYPE`（TF07）。`@raw_int("str")` 现在编译期报错并带位置。TI_NEVER 透传，已有错误不级联。
3. apx 跨函数边界转换测试：b1 调用点（apx 参数转 F2I(bits×S)，callee 收到精确形式）和 b2 返回点（apx bits 转 scaled）各补一条已提交断言。b2 测试暴露了上面的返回类型读取根因。

### 验证
| 项 | 结果 |
|---|---|
| tests/selfhost/test_dex_arith.py | 7/7（新增 LET 边界、MOD 恒等式、跨边界） |
| tests/suite/dex_test.cr | ALL PASS（21 个断言，#14-20 为新增） |
| tests/bootstrap/test_dex_arith.py | 14/14（原 10 加 4 个 MOD；bootstrap 没有 bits 形式，LET 没有同缺口） |
| tests/selfhost/{dex_type,apx_tag,borrow,impl} | 2/2, 2/2, 7/7, 7/7 |
| tests/selfhost/test_compile.py | All selfhost compile tests passed |
| tests/bootstrap/{pipeline,borrow,generics,apx_tag,dex_type} | 24/24, 4/4, 2/2, 5/5, 3/3 |
| suite 回归（arena/fnaddr/ptr_arith/at） | 全部 PASS |
| build_selfhost_native.py（nice -n 19，clean-cache 后 2 轮） | BUILD SUCCESS |
| `@raw_int("str")` | TF07 编译期报错（带源码位置） |

注意：修改编译器源码后必须 clean-cache（`.core/cache/cir/`）再重建。cir 增量缓存有问题，Task 4 第 7.4 节已记录，本次复现。

### 遗留
- `y : dex = <int 表达式>` 的槽内仍存未缩放原值。int 到 dex 槽的隐式缩放没有规则，与 ASSIGN 路径的 dex_store_adjust 行为一致（int 不在转换对内），是预存问题，未动。
- `corec run` 解释器没有 binary64 值语义（预存问题，本次修复暴露）：apx 边界转换（LET、调用点、返回点）可靠发射 IR_F2I/IR_I2F 后，解释器不处理 op 49/50，而且它的 IR_BINARY 对 TI_DEX 操作数做整数运算，把 bits 当整数乘。apx 场景在 `run` 中本来就不在契约内，没有二进制位语义，`int_mul(bits(3.0), bits(1e6)) ≡ 0 (mod 2^64)`，即使实现 F2I 也无法救回，需要完整的软浮点解释器，属于 Task 6“apx 打印迁移”邻域。所有已提交测试都走 ELF 路径（test_dex_run_interp 只测精确路径），不受影响。
- 连带修复的 `ret_ti` 读取（fi_return_type）：main.cr 缓存命中路径同位修复。g_ir_func_ret_type 后端不消费，只用于 .ccr/.cir 元数据往返，没有 ABI 影响。
