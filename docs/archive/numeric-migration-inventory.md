# 数值类型迁移盘点——float 站点分类表（迁移契约）

> 定位：受众 = 维护者；状态 = archive(数值类型迁移盘点任务产物)

日期：2026-08-16
依据：[2026-08-16-numeric-types-design.md](superpowers/specs/2026-08-16-numeric-types-design.md)（已批准）
用途：Task 5/6 的迁移契约——每个站点按本表逐点执行，**禁止机械替换（sed/全局替换）**。

## 分类规则

| 分类 | 含义 | 判定标准 |
|---|---|---|
| `dex` | 用户可见 float 类型/字面量语义——默认精确（**语义变更**） | 类型常量、类型名/关键字映射、字面量节点、类型规则/错误消息、类型大小、类型名称输出（dump/LSP/IR 类型串） |
| `dex,apx` | 编译器内部浮点路径（运算/打印/指令编码）——保留 binary64 行为（它们是 apx 快路径的实现） | 字面量→binary64 位模式、float 运算 IR 生成、SSE2/XMM 指令编码、float_str_bits 打印、IR_I2F/IR_F2I |
| `保留` | 历史/注释/文档引用 | 注释、docstring、文档、`_f32`/`_f64` 后缀相关令牌/宽度常量 |
| `删除` | 迁移后应移除的残留 | 无迁移后指称的死常量/残留 |
| `_f32`/`_f64` 后缀 | → 保留 | apx 的 CPU 位宽标注（精确标注语法后议） |

注意：代码行内的内联注释随其代码站点一并处理（不单列）；独立注释行单独列出。

## 主分类表（76 站点：dex 38 / dex,apx 16 / 保留 21 / 删除 1）

> 补正（2026-08-16）：原 73 站点**分类结论不动**，补入 3 行 `保留`——core.ebnf 2 行（57-58 FLOAT_LIT 设计注释、59 Literal 产物 FLOAT_LIT 终结符）+ tokens.ebnf 1 行（FLOAT_LIT 定义）。

### src/compiler/ast.cr（10 处）

| 站点 | 角色 | 分类 | 理由 |
|---|---|---|---|
| ast.cr:8 `T_FLOAT : int = 3` | 字面量令牌 kind | `dex` | `3.14` 字面量默认语义 → 精确 dex；令牌更名/改义（T_DEX），默认路径不再产 binary64 位模式 |
| ast.cr:84 注释 | 注释 | `保留` | 后缀令牌说明（`_i32/_u64/_f32`），历史注释 |
| ast.cr:93-94 `T_FLOAT_F32/T_FLOAT_F64 = 85/86` | 后缀字面量令牌 | `保留` | `_f32/_f64` 后缀 → apx CPU 位宽标注，令牌保留 |
| ast.cr:99 `T_FLOAT_TYPE : int = 91` | 类型关键字令牌 kind | `删除` | float 关键字消亡；该常量**从未被 lexer 发射**（类型名按 lexeme 匹配，见 parser.cr:84）——死常量残留。删除时勿重编号（保持 LSP 连续区间 90..95 语义，见 analysis.cr:895 说明） |
| ast.cr:108 注释 | 注释 | `保留` | 宽度常量说明（EXPR_INT/EXPR_FLOAT） |
| ast.cr:117-118 `W_F32/W_F64 = 9/10` | 位宽常量 | `保留` | `_f32/_f64` → apx CPU 位宽标注 |
| ast.cr:122 `TY_FLOAT : int = 1` | 核心类型常量 | `dex` | 类型本身更名 TY_DEX，默认精确（语义变更）；设计 §5：float 类型名删除、类型迁为 dex |
| ast.cr:206 `EXPR_FLOAT : int = 27` | 字面量 AST 节点 kind | `dex` | 字面量节点语义 → dex；注释已预示"int_val = value (as scaled int)"（缩放整数 = dex 表示） |
| ast.cr:296 `TI_FLOAT : int = 1` | IR 类型索引 | `dex` | 随类型更名 TI_DEX；单一类型（dex 永远是 dex，apx 只是附注） |
| ast.cr:576-577 `IR_I2F=49 / IR_F2I=50` | 转换 IR 指令 | `dex,apx` | int↔binary64 转换指令（cvtsi2sd/cvttsd2si）——apx 快路径实现，保留 |

### src/compiler/lexer.cr（3 处）

| 站点 | 角色 | 分类 | 理由 |
|---|---|---|---|
| lexer.cr:121 `str_to_f64_bits` | 字面量→binary64 位模式 | `dex,apx` | 十进制→IEEE 754 转换是 apx 快路径实现（apx 授权时字面量仍需此转换）；dex 默认路径改走精确解析（Task 5 新增） |
| lexer.cr:328-329 注释 | 注释 | `保留` | 修复历史注释（float 位模式、str_int 截断史） |
| lexer.cr:331 `add_tok_int(T_FLOAT, str_to_f64_bits(...))` | 字面量令牌发射 | `dex,apx` | 发射机制保留为 apx 快路径（binary64 位模式）；令牌 kind 更名 T_DEX 后此处为 apx 授权分支 |

### src/compiler/parser.cr（2 处）

| 站点 | 角色 | 分类 | 理由 |
|---|---|---|---|
| parser.cr:84 `lex == "float"` → TY_FLOAT | 类型名解析 | `dex` | 用户可见类型名；`float` → `dex`（默认精确，语义变更） |
| parser.cr:405-411 `T_FLOAT/T_FLOAT_F32/F64` 字面量解析 | 字面量节点构建 | `dex` | 字面量节点 EXPR_FLOAT 语义 → dex（默认精确）；其中 409-410 的 W_F32/W_F64 宽度传递保留（后缀标注不动，parser 404 行的 T_FLOAT_F32/F64 分支配对保留） |

### src/compiler/checker.cr（12 处，全部 `dex`）

| 站点 | 角色 | 理由 |
|---|---|---|
| checker.cr:22 `alloc_type(TYP_BASE, TY_FLOAT, 0)` | 类型表注册 | TY_FLOAT→TY_DEX，单一类型 |
| checker.cr:368 `res_type_node` TY_FLOAT→TI_FLOAT | 类型解析管道 | 常量更名随类型 |
| checker.cr:474 `get_type_name` 返回 "float" | 类型名输出（错误消息/hover） | 名字改 "dex" |
| checker.cr:672 / 696 | 函数返回类型→TI 管道 | 常量更名随类型（696 为 @hotpatch 签名核对，同规则） |
| checker.cr:748 | extern 返回类型→TI 管道 | 常量更名随类型 |
| checker.cr:877 `res_call_type` | 调用推断 | 常量更名随类型 |
| checker.cr:1143 | 参数类型→TI 管道 | 常量更名随类型 |
| checker.cr:1196 | 返回类型→TI 管道 | 常量更名随类型 |
| checker.cr:1363 `infer_expr` EXPR_FLOAT→TI_FLOAT | 字面量类型推断 | 字面量语义 → dex |
| checker.cr:1416-1420 算术规则 + 消息 | 类型规则/错误消息 | "Arithmetic operation requires int or float" → int or dex；结果类型 TI_DEX（规则本身不变，类型名变） |
| checker.cr:1597 `iface_ret2 == TY_FLOAT` | 接口方法返回类型分派 | 常量更名随类型 |

### src/compiler/ir_gen.cr（10 处）

| 站点 | 角色 | 分类 | 理由 |
|---|---|---|---|
| ir_gen.cr:150 `ti == TI_FLOAT`（IR_ALLOC 小值判定） | 逃逸分析判定 | `dex` | TI_FLOAT→TI_DEX（dex 同为寄存器值类） |
| ir_gen.cr:196 调用返回类型 TY_FLOAT→TI_FLOAT | 类型管道 | `dex` | 常量更名随类型 |
| ir_gen.cr:279 `res_type_node` | 类型管道 | `dex` | 常量更名随类型 |
| ir_gen.cr:291 `str_eq(name, "float")` | 类型名解析（EXPR_IDENT） | `dex` | 用户可见类型名；改 "dex" |
| ir_gen.cr:312 / 363 `type_size` TY_FLOAT = 8 | 类型大小 | `dex` | 大小随 dex（默认缩放整数 8 字节，尺寸语义不变）；常量更名 |
| ir_gen.cr:482-483 EXPR_FLOAT→IR_CONST（TI_FLOAT + 位模式） | 字面量常量发射 | `dex,apx` | 现有发射 = binary64 位模式（apx 快路径表示，保留）；dex 默认精确路径需新增缩放整数常量发射；变量名 "float"→"dex" |
| ir_gen.cr:685-696 float 二元运算生成（含隐式 I2F 插入） | 浮点运算 IR 生成 | `dex,apx` | 保留 binary64 运算路径（SSE2 分派 + cvtsi2sd 隐式转换）为 apx 快路径；dex 默认精确运算改走缩放整数序列（新增路径）；"int 操作数隐式转换"仅在 apx 路径成立（设计 §6 显式转换原则下默认精确路径不插入） |
| ir_gen.cr:974 `type_str = "float"`（IR dump 类型串） | 类型名输出 | `dex` | 名字改 "dex" |
| ir_gen.cr:1093 `type_args + "float"`（monomorph 签名串） | 类型名输出 | `dex` | 名字改 "dex" |

### src/compiler/monomorph.cr（3 处）

| 站点 | 角色 | 分类 | 理由 |
|---|---|---|---|
| monomorph.cr:101 `s == "float"` → TY_FLOAT | 泛型基类型名解析 | `dex` | 用户可见类型名；改 "dex" |
| monomorph.cr:192 注释 "(int, float, etc.)" | 注释 | `保留` | 注释 |
| monomorph.cr:220 `k == EXPR_FLOAT` 克隆分支 | 泛型 AST 克隆 | `dex` | 节点 kind 更名随字面量语义（EXPR_FLOAT→EXPR_DEX 或保持 kind 号） |

### src/compiler/module.cr（3 处）

| 站点 | 角色 | 分类 | 理由 |
|---|---|---|---|
| module.cr:361 注释 "int=0, string=1, float=2..." | 注释 | `保留` | 编码表注释（注意：注释与代码已有出入——注释写 float=2，代码 L366 写 `ptype_code = 3`，既有 bug，Task 5 顺带修正注释即可，勿动编码） |
| module.cr:366 `pname == "float"` → code 3 | extern 参数类型名编码 | `dex` | 用户可见类型名（extern 声明里的类型字符串）；改 "dex"。ABI 语义：dex 跨 C 边界按 binary64 传递属 apx 授权行为，编码 3 保留给 apx 场景 |
| module.cr:380 `ret_type == "float"` → code 3 | extern 返回类型名编码 | `dex` | 同上 |

### src/compiler/dump.cr（1 处）

| 站点 | 角色 | 分类 | 理由 |
|---|---|---|---|
| dump.cr:52 `type_kind_name` tk==1 → "float" | 类型名输出（dump） | `dex` | 名字改 "dex" |

### src/compiler/ccr_io.cr（1 处）

| 站点 | 角色 | 分类 | 理由 |
|---|---|---|---|
| ccr_io.cr:210-211 注释（修复 14：IR_CONST float 位模式 64 位化） | 注释 | `保留` | 修复历史注释；序列化本身无 float 分支（裸 i64），无需改动 |

### src/stdlib/fmt.cr（2 处）

| 站点 | 角色 | 分类 | 理由 |
|---|---|---|---|
| fmt.cr:194 注释 "float 打印（IEEE 754 double → 十进制）" | 注释 | `保留` | 注释 |
| fmt.cr:203 `float_str_bits(bits)` | 打印（binary64 位模式→十进制） | `dex,apx` | 设计 §5 明示："float_str_bits → dex 打印，保留为 apx 路径实现"——binary64 打印保留为 apx 快路径；dex 默认打印 = 缩放整数→十进制（新增） |

### src/arch/linux/ld/instr.cr（10 处）

| 站点 | 角色 | 分类 | 理由 |
|---|---|---|---|
| instr.cr:298 注释（SSE2 段头 "float 支持"）+ 323 注释（movsd SysV float 参数） | 注释 | `保留` | 注释 |
| instr.cr:336-340 `e2_store_ret`（TI_FLOAT → movsd [slot], xmm0） | 指令编码（返回值存放） | `dex,apx` | SysV XMM0 返回路径保留为 apx 快路径；TI_FLOAT→TI_DEX 更名后按附注分派 |
| instr.cr:344-346 `e2_push_xmm0`（sub rsp,8 + movsd [rsp],xmm0） | 指令编码（float 参数压栈） | `dex,apx` | apx 参数栈传递路径，保留 |
| instr.cr:352-360 `e2_sd_cvt`（cvtsi2sd） | 指令编码（int→float 转换） | `dex,apx` | cvtsi2sd = apx 快路径转换，保留 |
| instr.cr:418-425 IR_I2F 发射（cvtsi2sd + movsd 存回） | 指令编码 | `dex,apx` | IR_I2F 是 apx 路径指令，保留 binary64 行为 |
| instr.cr:426-432 IR_F2I 发射（movsd + cvttsd2si + 存回） | 指令编码 | `dex,apx` | 同上（cvttsd2si 截断语义 = binary64 行为，保留） |
| instr.cr:456-475 IR_BINARY TI_FLOAT（addsd/subsd/mulsd/divsd/comisd） | 指令编码（浮点运算/比较） | `dex,apx` | SSE2 double 运算 = apx 快路径核心实现（IEEE 754 标准答案），逐位保留；内联注释（456/459/467）随行 |
| instr.cr:584-625 IR_CALL SysV 分派（XMM0-7 参数、fr_cnt、9+ float 栈参数） | 指令编码（调用约定） | `dex,apx` | SysV float 参数传递保留为 apx 快路径；内联注释（584/605）随行 |
| instr.cr:784 注释（"int 超 6 + float 超 8" 压栈数） | 注释 | `保留` | 注释 |
| instr.cr:860-862 IR_RETURN（TI_FLOAT → movsd xmm0） | 指令编码（返回值） | `dex,apx` | XMM0 返回路径保留（apx 快路径）；内联注释（861）随行 |

### src/arch/linux/ld/elf.cr（2 处）

| 站点 | 角色 | 分类 | 理由 |
|---|---|---|---|
| elf.cr:1250-1251 注释（"float 参数在 XMM"） | 注释 | `保留` | 注释 |
| elf.cr:1252-1262 TI_FLOAT 参数 XMM 落槽（movsd [rbp+po2], xmm{frn}；9+ float 栈参数边缘路径） | 指令编码（函数序言参数搬移） | `dex,apx` | SysV XMM 参数搬移保留为 apx 快路径 |

### src/lsp/analysis.cr（8 处；预扫报"5 处"为字面量 "float" 命中：36/312/848/865/908，本表补 T_FLOAT 变体 3 处）

| 站点 | 角色 | 分类 | 理由 |
|---|---|---|---|
| analysis.cr:36 `analysis_tyname` TY_FLOAT → "float" | 类型名输出（hover/documentSymbol 显示） | `dex` | 名字改 "dex" |
| analysis.cr:312 `analysis_type_of_expr` EXPR_FLOAT → "float" | 字面量类型显示 | `dex` | 字面量语义 → dex，显示 "dex" |
| analysis.cr:848 注释（"运算符与 int/float 字面量令牌的 lexeme = -1"） | 注释 | `保留` | 注释（令牌跨度扫描说明） |
| analysis.cr:864-881 注释块（tokenType 映射表：864 含 T_FLOAT_F64、865 内置类型名 int/float/…、881 "number (7): T_INT T_FLOAT"） | 注释 | `保留` | 映射表注释；legend 结构本身不改（number 类保留） |
| analysis.cr:895 `(k >= T_INT_I8 && k <= T_FLOAT_F64)` 区间 | semanticTokens legend 分派 | `保留` | 区间含 T_FLOAT_F32/F64（后缀令牌保留 → 区间保持有效，无需改动）；另含 T_INT_TYPE..T_AUTO_TYPE 区间——若 T_FLOAT_TYPE 删除但不重编号，区间仍正确（见 ast.cr:99 行理由） |
| analysis.cr:900 `k == T_FLOAT` → number legend(7) | 令牌→legend 分派 | `dex` | T_FLOAT 令牌更名 T_DEX 后同步（仍映射 number） |
| analysis.cr:908 `str_eq(s, "float")` 内置类型名判定 | 内置类型名清单 | `dex` | 名字改 "dex"（与 parser.cr:84 同源清单） |
| analysis.cr:955 `k == T_FLOAT` 令牌跨度扫描 | 令牌长度计算（镜像 lexer） | `dex` | 随令牌更名同步；后缀令牌分支（956 起小数扫描）保留 |

### 测试（4 处）

| 站点 | 角色 | 分类 | 理由 |
|---|---|---|---|
| tests/bootstrap/test_pipeline.py:46 docstring "non-int return types (string, float)" | 注释 | `保留` | docstring |
| tests/bootstrap/test_pipeline.py:187-190 'Float Add'（`fn main() -> float`，3.14+2.86=6.0） | 用户可见类型用例 | `dex` | 测精确语义：dex 精确算术 3.14+2.86=6.0 精确成立，用例改为 dex 后仍通过（期望值不变）；注意该用例跑在 Python bootstrap 解释器上——bootstrap 需先认识 dex（见范围外附录） |
| tests/bootstrap/test_pipeline.py:196-199 'Int Float Mix'（`fn main() -> float`，2+3.5=5.5） | 用户可见类型用例 | `dex` | 同上：2+3.5=5.5 精确成立；混合 int+dex 在 dex 世界无隐式转换问题（缩放整数对齐） |
| tests/selfhost/test_native_strings.py:47-52 float_str_bits 位模式断言（3.14/2/10/1/100/-2 的 binary64 位→十进制串） | 打印快路径用例 | `dex,apx` | 测 binary64 行为 → 保留为 apx 打印路径的回归用例（float_str_bits 保留） |

### grammar/core.ebnf（3 处）

| 站点 | 角色 | 分类 | 理由 |
|---|---|---|---|
| core.ebnf:29-31 注释（"'float' 类型名已移除（2026-08-16 数值类型设计）；旧 float 语义 = 'dex' + 'apx'"） | 注释 | `保留` | 设计决策注释；BaseType 已含 'dex'。**修正原断言**：文法并非"无残留语法"——FLOAT_LIT 终结符仍在（见下行），文法同步归 Task 7 |
| core.ebnf:57-58 注释（"FLOAT_LIT（`3.14` 十进制小数）默认产生 dex（精确小数）；f32/f64 后缀暂作 apx 的 CPU 位宽标注"） | 注释 | `保留` | FLOAT_LIT 设计注释——字面量在 dex 世界继续存在（默认精确），非残留 |
| core.ebnf:59 `Literal = INT_LIT \| FLOAT_LIT \| STRING_LIT \| ...` | 文法产物 | `保留` | FLOAT_LIT 终结符仍在文法产物中：3.14 字面量在 dex 世界继续存在（默认精确语义），文法同步归 Task 7——**非残留，不删** |

### grammar/tokens.ebnf（1 处）

| 站点 | 角色 | 分类 | 理由 |
|---|---|---|---|
| tokens.ebnf:24 `FLOAT_LIT = DIGIT { DIGIT \| '_' } '.' DIGIT { DIGIT \| '_' } [ 'f32' \| 'f64' ] ;` | 终结符定义 | `保留` | FLOAT_LIT 终结符——3.14 字面量在 dex 世界继续存在（默认精确）；`[ 'f32' \| 'f64' ]` 后缀 = apx CPU 位宽标注。原盘点漏列原因：FLOAT_LIT 全大写，大小写敏感的 "float" grep 不命中 |

### docs/（1 条汇总，21 文件 89 处）

| 站点 | 角色 | 分类 | 理由 |
|---|---|---|---|
| docs/ 21 个文件 89 处 "float"（词边界 `\bfloat\b` 口径，2026-08-16 复查；compcert-reference 8、error-codes 2、pseudocode 10 文件 21、superpowers specs 5 文件 13、superpowers plans 4 文件 45；不含本清单自身 74 处）；另有 3 个 pseudocode 文件（checker-4/checker-5/parser-2）仅含 TY_FLOAT/TI_FLOAT/EXPR_FLOAT 变体 | 文档引用 | `保留` | 文档/历史引用（含本设计 spec 本身与 Task 计划）——按规则保留为历史；后续文档刷新属独立任务。原"84 处"口径不可复现（plans 文档演化增补、pseudocode 复核为 21），以词边界复查值为准；子串口径（含 float_str_bits 等复合词）为 98 |

零站点文件（预扫范围内确认无 float）：`tests/suite/`（30 个 .cr 全部无 float 字面量/类型）、`src/compiler/{dataflow,opt,pass,diag,interp,globals,entry,main,corearch,project,dyn_arr,_import}.cr`、`src/arch/linux/ld/{ld,resolve,sizes}.cr`、`src/runtime/`、`src/lsp/`（除 analysis.cr 外的 rpc.cr 等）、`examples/`、`vscode-core/`、`spec/`、`grammar/corespec.ebnf`（tokens.ebnf:24 的 FLOAT_LIT 定义已补入表）、`legacy_asm_backend/`。
注：interp.cr 值存储为裸 64 位（无 float 分支），TI_FLOAT→TI_DEX 更名不触及；dex 精确运算的解释执行属 Task 5 新增。

## 迁移后目标形态（dex/apx 双语义落点）

| 层 | dex（默认精确，语义变更） | apx（授权近似，binary64 快路径保留） | 涉及站点 |
|---|---|---|---|
| 字面量 | `3.14` → 缩放整数常量（精确解析，新路径） | `3.14` → binary64 位模式（str_to_f64_bits 保留） | lexer:121/331、ir_gen:482-483、parser:405-411、ast:8/206 |
| 词法令牌 | T_FLOAT → T_DEX（字面量令牌） | T_FLOAT_F32/F64 保留（apx CPU 位宽标注） | ast:8/93-94 |
| 类型系统 | TY_FLOAT→TY_DEX、TI_FLOAT→TI_DEX（单一类型，dex 永远是 dex） | —（apx 是变量级标签，不进类型） | ast:122/296、checker:22 |
| 类型名解析 | "float"→"dex"（parser/monomorph/ir_gen/module/LSP 清单同源改） | — | parser:84、monomorph:101、ir_gen:291、module:366/380、lsp:908 |
| 检查器 | 算术规则 int\|dex、消息更新、推断 TI_DEX；apx 标签透传零规则 | — | checker 12 处 |
| IR | dex 运算 = 缩放整数指令序列（新后端路径）；IR_APPROX 附注（非语义） | IR_I2F/IR_F2I 保留；TI_FLOAT 分派 SSE2 | ir_gen:685-696、ast:576-577 |
| 后端 | 默认 dex → 整数指令序列（新增） | SSE2/XMM/SysV 全路径保留（addsd…comisd、cvtsi2sd/cvttsd2si、XMM0-7 参数/返回） | instr.cr 8 处代码、elf.cr:1252-1262 |
| 打印 | dex → 十进制（缩放整数长除，新路径） | float_str_bits 保留为 apx 打印实现 | fmt.cr:203 |
| 名称输出 | "float"→"dex"（dump/IR 类型串/LSP 显示） | — | dump:52、ir_gen:974/1093、lsp:36/312 |
| FFI | extern 类型名字符串 "float"→"dex" | 跨 C 边界 binary64 ABI 属 apx 授权行为（编码 3 保留） | module:366/380 |
| 测试 | float 用例 → dex（3.14+2.86、2+3.5 精确成立） | float_str_bits 位模式用例保留 | test_pipeline:187-199、test_native_strings:47-52 |
| EBNF/文档 | 文法已迁移（dex 入 BaseType）；FLOAT_LIT 终结符同步归 Task 7 | — | core.ebnf:29-31/57-59、tokens.ebnf:24（均保留） |

执行顺序提示（与计划一致）：**先加 dex（Task 2-4）再移 float（Task 5-6）**，保持编译器自举；每个 `dex,apx` 站点只改名不改行为（binary64 路径不变）。

## 范围外附录：bootstrap/corec（Python 自举编译器，预扫范围外但构建关键）

`build_selfhost_native.py` 用 bootstrap 编译 src/compiler——**bootstrap 的 dex 支持已随 Task 2-5 同步落地**（2026-08-16 更新）：Task 3 认识 dex 类型名/字面量（base_types 含 'dex'、kind_map 'dex'、算术/比较规则 int|dex），Task 4 落地定点缩放语义（`Dex(int)` 值类 + `DEX_SCALE`，`Dex.__eq__` 对 float 期望值按缩放语义比较——测试期望值保持十进制语义），Task 5 移除 'float' 类型名别名（与自举侧同步拒绝 float）。

Task 5 迁移后 bootstrap 的 float 残留（均按分类表 `保留`/`dex,apx` 处理，不属移除项）：

- `bootstrap/corec/syntax/tokens.py:7`（`FLOAT_LIT = auto()` 枚举成员——FLOAT_LIT 终结符保留，3.14 字面量在 dex 世界继续存在）
- `bootstrap/corec/frontend/lexer.py:81/94/107-108`（is_float 字面量扫描 + FLOAT_LIT 令牌发射——字面量扫描机制保留）
- `bootstrap/corec/frontend/parser.py:508-509`（FLOAT_LIT 分支检查 + dex 字面量节点——Task 5 后该分支产出 `Literal(..., 'dex')`，见 `_str_to_scaled`）
- `bootstrap/corec/ir/cir.py:43`（docstring）
- `bootstrap/corec/backend/x86_64_stack_asm.py:145`（`isinstance(val, float)`——Python float 值 = binary64 参考实现，apx 快路径）
- `bootstrap/corec/ir/coreir.py:14-19`（`Dex.__eq__` 对 float 期望值比较——测试支撑，非编译器路径）

bootstrap 内部类型名统一为 'dex'（type_checker/ir_gen/interpreter 的 kind_map、提升规则、默认值、常量发射）；'float' 仅存在于上述机制性保留点与历史 docstring。

## 完整性自检

复查 grep（全仓库，2026-08-16）：

```bash
grep -rn "float" src/ tests/ grammar/            # 命中文件与主表 13+2+1=16 个源码文件一一对应（src 13、tests 2、grammar 1；原 "13+3+1" 中 tests 应为 2——test_pipeline.py + test_native_strings.py；grammar 仅 core.ebnf）
grep -rn "TY_FLOAT" src/                          # 6 文件：ast/checker/ir_gen/monomorph/parser/analysis ✓
grep -rn "TI_FLOAT" src/                          # 41 处，5 文件：ast/ir_gen/checker/instr/elf ✓（均入表）
grep -rn "T_FLOAT\b\|T_FLOAT_TYPE" src/           # ast:8/99、lexer:331、lsp:881(注)/900/955、parser:405 ✓
grep -rn "EXPR_FLOAT" src/                        # ast:206、parser:411、checker:1363、ir_gen:481、monomorph:220、lsp:312 ✓
grep -rn "IR_I2F\|IR_F2I" src/                    # ast:576-577、ir_gen:691/696、instr:418/426 ✓
grep -rn "T_FLOAT_F32\|T_FLOAT_F64" src/          # ast:93-94、parser:405/409-410、lsp:864(注)/895 ✓
grep -rn "W_F32\|W_F64" src/                      # ast:117-118、parser:409-410 ✓
grep -rn "_f32\|_f64" src/ tests/ grammar/        # 3 处：ast.cr:84（注释）、lexer.cr:121（str_to_f64_bits）、lexer.cr:331（str_to_f64_bits 调用）——后两者已入主表（lexer 行），原"仅 ast.cr:84"断言修正 ✓
grep -rn "FLOAT_LIT" grammar/                     # tokens.ebnf:24、core.ebnf:57/59——全大写，原大小写敏感 "float" grep 不命中，本轮补入表（保留×3）✓
grep -rn "float" tests/suite/ examples/ vscode-core/ spec/ src/runtime/   # 0 命中 ✓
grep -rno "\bfloat\b" docs/                       # 22 文件 163 处（含本清单自身 74 处）→ 其余 21 文件 89 处 → docs 汇总行 ✓（另 3 个 pseudocode 文件仅含 TY_FLOAT 等变体）
grep -rn "FLOAT_LIT" bootstrap/corec/             # tokens.py:7、lexer.py:108、parser.py:508——全大写不命中 "float" grep，附录口径须含大小写（小写 grep 仅 19 行）✓
grep -rn "float\|FLOAT_LIT" bootstrap/corec/ | wc -l   # 22——附录 8 文件 22 处闭合（清单逐行核对）✓
```

计数核对：主表 76 行 = dex 38 + dex,apx 16 + 保留 21 + 删除 1（原 73 行**分类结论不动**，补入 3 行保留：core.ebnf 57-58/59、tokens.ebnf:24）；docs 汇总 1 行（21 文件 89 处，词边界口径）；范围外附录 22 处（8 文件，未计入主表）。无未列入的 float 站点。

## 分类争议点

1. **parser.cr:405-411（字面量节点）标 `dex`**：该行同时含后缀宽度传递（W_F32/W_F64，保留）与 T_FLOAT 分支（dex 语义）。按"节点语义归属"标 dex，后缀部分在理由中注明不动。
2. **ir_gen.cr:482-483（字面量→IR_CONST）标 `dex,apx`**：发射的 binary64 位模式是 apx 表示（保留），但 TI_FLOAT→TI_DEX 更名属 dex 侧。若执行时希望整体按语义层处理可改 `dex`——建议以"位模式保留 = 快路径"为准标 dex,apx。
3. **ast.cr:99 T_FLOAT_TYPE 标 `删除`**：从未被发射的死常量（float 关键字实际按 lexeme 匹配）。唯一风险是 LSP 连续区间 `T_INT_TYPE..T_AUTO_TYPE`（90..95）——删除不重编号则区间语义不变，故删除安全。若保守处理可标保留，但契约建议删除。
4. **计划文件 Task 5 的括号示例把 monomorph/module/dump/ccr_io/parser/lexer 列为 `dex,apx` 站点**：本表按 Global Constraints 逐点判定——这些文件的**类型名/常量更名**站点属用户可见类型语义（`dex`），仅其**binary64 机制**部分（lexer 位转换、ir_gen 运算生成）为 `dex,apx`。计划原文"按分类表逐点执行"，以本表为准。
5. **module.cr:361/366 编码表注释与代码不符**（注释 float=2、代码 =3）：既有 bug，非本任务修复项；Task 5 改注释时需核对实际 ABI 编码。
6. **bootstrap 范围外但构建关键**（见附录）：若 Task 5 按表迁移 src/compiler 而 bootstrap 未先支持 dex，`build_selfhost_native.py` 自举失败——需在计划层面确认 bootstrap 的 dex 落地任务归属。
7. **T_FLOAT_TYPE 删除 vs T_FLOAT_F32/F64 保留的判据对称性**：三者同为"从未被发射"的令牌常量——lexer **只发 `T_FLOAT`**（lexer.cr:330-331 唯一发射点：小数点或 `f32/f64` 后缀一律汇入 `add_tok_int(T_FLOAT, str_to_f64_bits(...))`）；parser.cr:409-410 的 `T_FLOAT_F32→W_F32 / T_FLOAT_F64→W_F64` 宽度分支是**死代码**（两个后缀令牌从未到达 parser，`w` 恒为 0）；`_f32/_f64` 后缀在 lexer 即被消费（num_str 已剔除后缀，见 lexer.cr:325-327），位宽信息在词法层丢失。分类差异的判据：`保留` 是约束原文（"_f32/_f64 后缀 → 保留"）的明确要求，且后缀令牌在设计中有迁移后指称（apx CPU 位宽标注角色）；T_FLOAT_TYPE 无任何迁移后指称（float 关键字消亡、从未发射），故标 `删除`。**风险提示**：当前 `_f32/_f64` 后缀标注实际不生效（宽度丢失、w=0）——apx 位宽标注需在 lexer 增加发射路径（suffix 分支发射 T_FLOAT_F32/F64 或等价标注令牌），属 Task 5/6 实现项；本表分类仅按约束原文执行，不改变此实现缺口。

## Task 6 执行补记（2026-08-16，float 移除收尾 + 测试迁移）

### 删除站点核实（零残留证据）

分类表唯一 `删除` 站点 ast.cr:99 `T_FLOAT_TYPE`：Task 5 已删除（注释占位、不重编号，LSP 区间
90..95 连续语义保持）。Task 6 复查 grep 证据：

```bash
grep -rn "T_FLOAT_TYPE" src/                       # 0 命中（仅 ast.cr:99 删除占位注释）
grep -rn "TY_FLOAT\b" src/ tests/ bootstrap/       # 0 命中（仅 TY_DEX 更名 + 历史注释）
grep -rn "TI_FLOAT\b" src/                         # 0 命中（仅 TI_DEX / TI_DEX_S）
grep -rn "T_FLOAT\b" src/                          # 0 命中（仅 T_DEX；T_FLOAT_F32/F64 后缀令牌保留）
grep -rn "\bfloat\b" src/compiler/ src/stdlib/ src/arch/ src/lsp/   # 全为保留注释/dex,apx 机制站点
grep -rn "\bfloat\b" tests/                        # test_pipeline docstring（保留）+ float_str_bits 位模式回归（保留）+ 移除守卫测试
```

用户可见 float 关键字/类型：lexer 不发射 float 令牌、parser/monomorph/ir_gen/module/LSP 类型名
清单均为 "dex"（Task 5）；`x : float = ...` 报 TF01 未知类型（test_dex_type 移除守卫）。

### 测试迁移清单（Task 6 收尾）

| 用例 | 迁移方向 | 状态 |
|---|---|---|
| test_pipeline 'Float Add'/'Int Float Mix' → 'Dex Add'/'Int Dex Mix' | dex 精确断言（期望值不变） | Task 5 已迁移 ✓ |
| test_pipeline docstring "string, float" | 保留（docstring） | 不动 ✓ |
| test_native_strings float_str_bits 位模式 | 保留（dex,apx 打印快路径回归） | 不动 ✓ |
| test_dex_type 移除守卫（float 拒绝） | 保留（守卫测试） | Task 5 已迁移 ✓ |
| **新增** test_dex_arith test_apx_print_rounding | apx 打印 = 6 位定点舍入（0.1→"0.1"、1/3→"0.333333"、1.0000006→"1.000001"、-0.1→"-0.1"） | 本任务 ✓ |
| **新增** test_dex_arith test_interp_rejects_apx_dex | interp 显式报错（exit 255 + binary64 消息） | 本任务 ✓ |

### interp 改动（Task 4 审查建议）

interp.cr：op 49/50（IR_F2I/IR_I2F）显式报错——"interpreter lacks binary64 semantics"（消息：
`IR_I2F/IR_F2I needs binary64 semantics (apx dex)`），return -1（exit 255）。替代静默跳过
（目的槽残留 0/脏值 → 后续除法可能 SIGFPE）。`corec run` 精确 dex/int-apx 不受影响（无 49/50）。

### apx 打印行为定稿（Task 4 concern）

**v1 定稿：apx 变量经 dex_str 打印 = 6 位定点舍入（四舍五入半进）**，非截断、非全精度。
实现：ir_gen.cr `dex_bits_to_scaled` 由 F2I(bits×S) 截断改为 round-half-away——
m < 0 分支 −0.5 / m ≥ 0 分支 +0.5 后再 F2I（comisd 比较 + 分支，与字面量 str_to_scaled
半进一致；-0.5 → -1）。单点规则：打印（@raw_int）与跨函数边界转换共用同一函数，
行为一致。全精度打印（Ryu 式）留待后续版本。文档：dex.cr 头注释。

**发现（Task 6）**：str_to_f64_bits 字面量转换按 ~2ulp 截断（保留站点，lexer.cr:121 注释为
文档化限制）——经典 binary64 演示「0.1b+0.2b != 0.3」因此不成立（0.1/0.2 各低 1ulp，
相加恰好落在 0.3 位模式）。非回归；binary64 行为断言以 1/3 判别子为准（±2ulp 下鲁棒）。

**顺带修复（bootstrap bug）**：bootstrap/corec/backend/x86_64_stack_asm.py 字符串长度头按
Python 字符数写（len(sval)+1），运行时 str_len 按字节读——非 ASCII 串（本任务报错消息
的 UTF-8 破折号）被截尾 2 字节。修复：改 len(sval.encode('utf-8'))+1。自举侧根因修复。

### 全套件回归证据

bootstrap 6 文件全过（24/24 + 14/14 + 5/5 + 3/3 + 4/4 + 2/2）；selfhost 全过
（test_compile 全过、test_dex_arith 9/9、test_lsp 8/8、test_region_cfg 16/16、apx/dex_type
2/2 等）；build_selfhost_native.py 自举成功（corec/corearch/corelsp 三二进制）。

### 顺带修复（全绿要求，非 float 站点）

`corec build`/`corearch` ELF 输出 0644 → 0755：既有怪癖（Task 3 已记录"corec build 输出
0644"），导致 test_backend_bootstrap stage1/2/3 链不可执行（exit 126），全部测试被迫
chmod 兜底。根因修复：src/compiler/corearch.cr 2 处 + src/arch/linux/ld/main.cr 2 处 +
src/arch/linux/ld/ld.cr 3 处（ctx_emit_static/ctx_emit_dyn/elf_gen 写路径）open mode
420→493（0755；umask 仍生效）。.so 输出（emit_so）与 .ccr/缓存写保持 0644。修复后
test_backend_bootstrap 全过（含 stage1/2/3 逐字节一致复现校验）。
