# 数值 Task 5 报告：编译器内部迁移，编译器自身的 float 站点按分类表逐点迁移为 dex/apx（自举通过）

状态：完成。
提交：`ssonuuow ff5ae2ec`，信息为 `core: 编译器内部 float 改为 dex,apx 迁移（按分类表逐点，自举通过）`。13 个文件，+80/-62。

## 1. 任务边界（读码确认）

Task 2-4 已经把全部常量更名（T_FLOAT 改为 T_DEX、TY_FLOAT 改为 TY_DEX、EXPR_FLOAT 改为 EXPR_DEX、TI_FLOAT 改为 TI_DEX），并实现了定点运算（TI_DEX_S=8），binary64 机制保持原样。因此本任务的实际剩余工作是分类表中的 `dex` 站点（类型名和常量名字符串 “float” 改为 “dex”）、`删除` 站点（T_FLOAT_TYPE）、`dex,apx` 站点的术语收尾，以及 bootstrap 同步。

- 代码层的 “float” 站点只剩 6 行类型名词素匹配，分布在 parser/ir_gen/monomorph/module 两处/analysis。全部移除 “float”，保留 “dex”。
- `保留` 站点（历史或机制注释）逐一核对，未改动。
- `dex,apx` 机制站点（str_to_f64_bits、T_DEX 发射、EXPR_DEX 双载、三路运算分派、SSE2/XMM/SysV、float_str_bits）在 Task 3/4 已就位。本任务只更新内联注释术语，行为零变化。
- bootstrap（Python）剩余 1 处 “float” 别名，在 parser.py，已移除，与自举侧同步。

## 2. 迁移站点清单（按分类表逐点）

### src/compiler/（6 文件）

| 站点 | 分类 | 改动 |
|---|---|---|
| ast.cr:99 `T_FLOAT_TYPE : int = 91` | `删除` | 删除常量，不重编号，保持 LSP 区间 T_INT_TYPE..T_AUTO_TYPE 90..95 的语义，见 analysis.cr:895。原位留删除说明注释。该常量从未被 lexer 发射，grep 确认零引用 |
| ast.cr:122 TY_DEX 内联注释 | `dex` | “float 关键字并存期映射到此类型”改为“Task 5：float 类型名移除，用户写 dex” |
| ast.cr:581-582 IR_I2F/IR_F2I 注释 | `dex,apx` | “int 到 float / float 到 int”改为“int 与 binary64 互转（cvtsi2sd/cvttsd2si，apx 快路径）”，指令保留 |
| parser.cr:84-85 类型名解析 | `dex` | `lex == "float" \|\| lex == "dex"` 改为 `lex == "dex"`；注释更新，说明 float 类型名已移除 |
| ir_gen.cr:300 EXPR_IDENT 类型名解析 | `dex` | 移除 `str_eq(name, "float")` 分支，仅保留 “dex” |
| ir_gen.cr:762 运算分流内联注释 | `dex,apx` | “现成 float 路径”改为“apx 标准答案”。三路分派本身在 Task 4 已就位 |
| monomorph.cr:101 泛型基类型名解析 | `dex` | 移除 `s == "float"`，仅保留 “dex” |
| module.cr:361 编码表注释 | `保留`（顺带修正，表理由已明示） | 注释与代码不符：原注释 float=2，实际 unit=2、dex=3。修正为实际编码 “int=0, string=1, unit=2, dex=3, bool=4, other=5”，编码未动 |
| module.cr:366/380 extern 类型名编码 | `dex` | 移除 `pname/ret_type == "float"`。dex 仍编码 3，binary64 跨 C 边界属于 apx 授权 ABI |
| dump.cr:52 | `dex` | Task 3 已就位，tk==1 输出 “dex”，复核无改动 |

### src/lsp/analysis.cr（1 处）

| 站点 | 分类 | 改动 |
|---|---|---|
| analysis.cr:908 内置类型名清单 | `dex` | 移除 `str_eq(s, "float")`，与 parser.cr:84 同源清单 |

### src/arch/linux/ld/（2 文件，术语收尾，行为零变化）

| 站点 | 分类 | 改动 |
|---|---|---|
| instr.cr 336/344/352/419/427/456/459/467/584/605/861 内联注释 | `dex,apx` | “float”改为“binary64/apx 快路径”。涉及 SSE2 运算、cvtsi2sd/cvttsd2si、XMM 参数和返回、栈参数阈值。机制全部保留，逐位未动 |
| elf.cr:1262 内联注释 | `dex,apx` | “9+ float 参数在栈上”改为“9+ binary64 参数在栈上”。XMM 落槽机制保留 |

### bootstrap/corec（同步，1 文件）

| 站点 | 分类 | 改动 |
|---|---|---|
| parser.py:360-368 type_name 词素 | `dex` 同步 | 移除 `'float'` 别名，`base_types` 仅保留 `{'int','dex','bool','string','char','unit','never'}`，条件和返回简化（`return BaseType(self.advance().lexeme)`） |

### 测试（3 文件，语义变更的必要闭包，分类表把 test_pipeline 用例列为 `dex`）

| 站点 | 分类 | 改动 |
|---|---|---|
| tests/bootstrap/test_pipeline.py:187-201 'Float Add'/'Int Float Mix' | `dex` | 用例体 `-> float` 改为 `-> dex`。改成 dex 后仍然通过，期望值 6.0/5.5 不变，bootstrap 的 `Dex.__eq__` 按缩放语义比较。测试名同步为 'Dex Add'/'Int Dex Mix' |
| tests/bootstrap/test_dex_type.py 'Float Keyword Co-existence' | 移除守卫 | 并存期用例改为 `expect_float_rejected()`：`x : float = 3.14` 必须报类型错误。实测得到 PathType 未知类型错误 |
| tests/selfhost/test_dex_type.py 并存期守卫 | 移除守卫 | 守卫改为断言 TF01，即 `fn f() -> float` 按未知类型名报错；docstring 同步 |

### 文档（顺带，Task 4 审查建议）

| 站点 | 改动 |
|---|---|
| docs/numeric-migration-inventory.md 范围外附录 | 更新 bootstrap 描述。原来写“不认识 dex、保留完整 float 实现”，已过时；改为 Task 2-5 已同步实施的现状，并列出保留点：FLOAT_LIT/is_float/cir docstring/isinstance(val,float)/Dex.__eq__ |

### 保留未动（按表核对）

ast.cr:84/108（后缀令牌说明）、ccr_io.cr:210-211（修复史）、fmt.cr:194 注释和 203 的 `float_str_bits` 函数名（apx 打印路径保留，test_native_strings 回归通过）、lexer.cr:184/328-329/385（修复史和 str_to_f64_bits 机制本身）、instr.cr:298/323/784（表列 `保留` 注释）、elf.cr:1250-1251、monomorph.cr:192、analysis.cr:848/864-881/895（映射表注释和区间）、core.ebnf:29-31/57-59、tokens.ebnf:24（FLOAT_LIT 终结符，Task 7 收文法）。

## 3. 与分类表的出入

1. parser.cr:84 的 “float” 词素直接移除。分类表理由写的是“float 改为 dex”，实施为 float 类型名消亡，`fn f() -> float` 不再映射 TY_DEX，与表中“迁移后目标形态：类型名解析 float 改为 dex（parser/monomorph/ir_gen/module/LSP 清单同源改）”一致。Task 3 的“移除是 Task 6”注释是当时的假设，以分类表这一核心契约为准。
2. instr.cr/elf.cr 的内联注释术语更新。分类表写明内联注释随其代码站点一并处理，`dex,apx` 站点“类型/常量名 float 改为 dex”的落实方式是注释中的 float 指称随站点迁移为 binary64/apx，指令编码逐位未动。表列 `保留` 的独立注释行（298/323/784/1250-1251）未动。
3. 测试迁移提前于计划 Task 6。计划 Task 6 的 Files 列了 test_pipeline.py/test_native_strings.py，但分类表是权威，已经把 test_pipeline 的两个用例列为 `dex`，并写明“用例改为 dex 后仍通过”。自举侧移除 float 后，这两处和两个并存期守卫必然断裂，属于语义变更的必要闭包，不是计划外工作。test_native_strings.py 的 float_str_bits 用例（`dex,apx`）保留未动。
4. module.cr:361 注释修正。分类表理由明示“Task 5 顺带修正注释即可，勿动编码”，本次按实际编码修正，编码零改动。
5. T_FLOAT_TYPE 删除。grep 确认零引用，只有 ast.cr 定义处，按 `删除` 执行，且不重编号。

## 4. 编译器代码的 dex/apx 写法模式（迁移后的形态）

```cr
// 类型名解析（5 处同源清单，均只认 "dex"）：
else if lex == "dex" { res = alloc_node(0, 0, 0, 0, 0, TY_DEX, 0, line, col); }        // parser.cr
if str_eq(name, "dex") != 0 { return TI_DEX; }                                          // ir_gen.cr
if s == "dex" { return TY_DEX; }                                                        // monomorph.cr
else if pname == "dex" { ptype_code = 3; }   // module.cr——binary64 跨 C 边界 = apx 授权 ABI

// 转换指令注释（apx 快路径语义）：
IR_I2F : int = 49;  // dest=dex_var(bits), s1=int_var — int 转换为 binary64（cvtsi2sd，apx 快路径）
IR_F2I : int = 50;  // dest=int_var, s1=dex_var(bits) — binary64 转换为 int（cvttsd2si 截断，apx 快路径）
```

模式总结：

- dex 类型名：全部词素和字符串匹配只认 “dex”，float 消亡。后端 SSE2/XMM 分派按 TI_DEX 常量，也就是 binary64，即 apx 快路径。
- apx 机制保留原样：`str_to_f64_bits`（字面量转位模式，lexer）、`float_str_bits`（位模式转十进制打印，fmt.cr）、`IR_I2F/IR_F2I`（cvtsi2sd/cvttsd2si）、addsd 到 comisd 序列、SysV XMM0-7 参数和返回。这些就是 apx 快路径实现，注释统一标注为 “binary64/apx 快路径”。
- 历史注释：修复史（例如“修复前 float 走 str_int”）和段头说明（例如“SSE2 double 运算…float 支持”）按 `保留` 原样保留。

## 5. 自举硬验收证据

| 项 | 结果 |
|---|---|
| `python3 tests/selfhost/test_compile.py` | 全部通过。新 corec 编译 .cr 为 ELF，exit 42 |
| `nice -n 19 python3 build_selfhost_native.py`（clean-cache 后） | BUILD SUCCESS。corec/corearch/corelsp 三个产物；warnings 与改动前同型同量 |
| `./build/corec check src/compiler/main.cr` | ok |
| 新产物再编译自身：`./build/corec build src/compiler/main.cr -o /tmp/corec_self_t5 --static` | 成功。自编译二进制运行：`run` int 得到 exit 42；dex 精确 0.1+0.2==0.3 得到 1；dex 除 1.0/3.0==0.333333（6 位截断）得到 1 |
| float 移除生效：`fn f() -> float { return 3.14; }` | TF01 未知类型错误，与 `fn f() -> zzz` 行为逐位一致，float 不再特殊 |
| selfhost 全套 | dex_type 2/2、dex_arith 7/7、apx_tag 2/2、borrow 7/7、impl 7/7、native_strings（float_str_bits 保留）通过、lsp 8/8、pointer_safety 通过、native_memory 6/6、region_cfg 16/16、directory_build 通过 |
| bootstrap 全套 | pipeline 24/24（含迁移后的 Dex Add/Int Dex Mix）、borrow 4/4、generics 2/2、apx_tag 5/5、dex_type 3/3（含移除守卫）、dex_arith 14/14 |
| suite | dex_test ALL PASS、ptr_arith/arena_test/fnaddr_test/at_test exit 0，generics/dyn/lazy/cache/chan/go_e2e/go/fnaddr 回归 8 文件全部通过。test_generics.cr/test_control_flow.cr 是 4 月的零字节占位文件，属于既有问题，不是本任务 |

## 6. 对 brief 的偏差与原因

1. 提交路径包含 src/lsp/、bootstrap/、tests/、docs/，brief 只列了 src/compiler/、src/stdlib/、src/arch/。analysis.cr:908 是分类表的 `dex` 站点，清单同源改，不改会导致 LSP 语义不一致。bootstrap 同步是任务明确要求的。测试和附录是语义变更的必要闭包，见 §3.3。
2. Step 2“编译器自身的 float 用法迁移”：编译器源码本来就没有 `: float` 或 `-> float` 声明，Task 3 已确认。“用法”就是类型名清单和机制站点，全部覆盖在 §2。float_str_bits 是 apx 打印路径，保留，不是调用方。
3. 未动 grammar/（core.ebnf/tokens.ebnf）。分类表明确 `保留`，FLOAT_LIT 终结符仍在文法产物中，3.14 字面量在 dex 世界继续存在，文法同步归 Task 7。
4. corec2 路径：`build/corec2` 是历史产物，没有重新构建。`build_selfhost_native.py` 产出 build/corec/corearch/corelsp，就是当前自举链。“用新产物再编译自身”已用新的 build/corec 完成。

## 7. 自审发现

1. module.cr:361 注释与代码不符，是既有 bug。原注释写 “float=2, bool=3, unit=4”，实际编码是 unit=2、dex/float=3、bool=4。按表理由顺带修正为实际编码，编码未动，分类表要求勿动编码。
2. `fn f() -> float` 在自举侧 exit 0，TF01 非致命。float 移除后按未知类型名走既有的宽松 TYP_NAMED 路径，错误信息照常输出，但非致命。已实证与 `fn f() -> zzz`（任意未知名）逐位一致，属于既有的未知类型行为，不是 float 残留。移除守卫按 TF01 断言，这条路径不能用 exit code 断言。
3. instr.cr:784 的 “int 超 6 + float 超 8”按表 `保留` 分类未动，与 298/323 同属表列注释。
4. T_FLOAT_TYPE 删除安全。grep 零引用，只有定义处；不重编号后 analysis.cr:895 区间（90..95，91 空缺）语义不变；test_lsp 8/8 验证。
5. 测试命名：'Float Add'/'Int Float Mix' 改为 'Dex Add'/'Int Dex Mix'。用例体迁移，名称同步，避免误导。
6. 遗留，不属于本任务：interp.cr 的裸 64 位值存储（表注“TI_FLOAT 改为 TI_DEX 更名不触及”）；apx 结果打印边界 6 位截断（Task 4 已文档化）；泛型加 dex 返回类型的既有 bug（Task 3 记录，未恶化）；grammar EBNF 同步归 Task 7。
