# Task 1 报告：迁移盘点，float 站点分类表

## 提交

- `zrlvxxtr 9ef63d46`，提交信息 `docs: 数值类型迁移盘点——float 站点分类表（迁移契约）`。只包含 `docs/numeric-migration-inventory.md`，工作区没有其他改动。

## 站点总数与分类分布

主表 73 个站点行，加上 docs 汇总 1 行，共 21 个文件 84 处：

| 分类 | 数量 | 占比 |
|---|---|---|
| dex（用户可见类型/字面量语义，默认精确） | 38 | 52% |
| dex,apx（编译器内部浮点路径，保留 binary64） | 16 | 22% |
| 保留（注释/历史/文档/_f32/_f64 后缀） | 18 | 25% |
| 删除（T_FLOAT_TYPE 死常量） | 1 | 1% |

范围外附录：bootstrap/corec（Python 自举编译器）有 7 个文件、约 14 处 float，未计入主表。它是构建的关键依赖，已写入文档，见“争议点 6”。

## 逐文件清单摘要（站点数：分类明细）

| 文件 | 站点数 | 明细 |
|---|---|---|
| src/compiler/ast.cr | 10 | dex 4（T_FLOAT/EXPR_FLOAT/TY_FLOAT/TI_FLOAT）、保留 4（注释+后缀令牌+W_F32/W_F64）、删除 1（T_FLOAT_TYPE）、dex,apx 1（IR_I2F/F2I） |
| src/compiler/lexer.cr | 3 | dex,apx 2（str_to_f64_bits + 字面量发射）、保留 1（注释） |
| src/compiler/parser.cr | 2 | dex 2（“float”类型名、字面量节点；后缀宽度传递注明保留） |
| src/compiler/checker.cr | 12 | 全部 dex（类型注册/解析管道/名称输出/推断/算术规则与消息/接口分派） |
| src/compiler/ir_gen.cr | 10 | dex 8（管道/大小/名称串）、dex,apx 2（字面量 IR_CONST、浮点运算生成含隐式 I2F） |
| src/compiler/monomorph.cr | 3 | dex 2（基类型名、EXPR_FLOAT 克隆）、保留 1（注释） |
| src/compiler/module.cr | 3 | dex 2（extern 参数/返回类型名编码）、保留 1（注释） |
| src/compiler/dump.cr | 1 | dex（type_kind_name） |
| src/compiler/ccr_io.cr | 1 | 保留（注释；序列化本身没有 float 分支） |
| src/stdlib/fmt.cr | 2 | dex,apx 1（float_str_bits）、保留 1（注释） |
| src/arch/linux/ld/instr.cr | 10 | dex,apx 8（e2_store_ret/e2_push_xmm0/e2_sd_cvt/IR_I2F/IR_F2I/IR_BINARY SSE2/IR_CALL SysV/IR_RETURN XMM0）、保留 2（注释） |
| src/arch/linux/ld/elf.cr | 2 | dex,apx 1（参数 XMM 落槽）、保留 1（注释） |
| src/lsp/analysis.cr | 8 | dex 5（类型名/字面量显示/legend 分派两处/内置类型名清单）、保留 3（注释块/区间检查）。预扫的“5 处”是字面量 “float” 命中，本表补齐 T_FLOAT/T_FLOAT_F64 变体 3 处 |
| tests/bootstrap/test_pipeline.py | 3 | dex 2（Float Add、Int Float Mix，dex 精确算术下期望值仍成立）、保留 1（docstring） |
| tests/selfhost/test_native_strings.py | 1 | dex,apx（float_str_bits 位模式断言，用于 apx 打印路径回归） |
| grammar/core.ebnf | 1 | 保留（设计注释；文法本体已迁到 dex） |
| docs/（汇总） | 1 行 | 保留（21 文件 84 处 + 3 个 pseudocode 文件变体） |

零站点确认：tests/suite/（30 文件）、interp/opt/pass/dataflow/diag/globals/entry/main/corearch/project/dyn_arr/_import.cr、ld/resolve/sizes.cr、src/runtime、src/lsp 其余文件、examples、vscode-core、spec、tokens.ebnf/corespec.ebnf、legacy_asm_backend。

## 分类争议点（详见文档末尾章节）

1. parser.cr:405-411 的字面量节点标为 dex，后缀宽度传递保留，按节点语义归属判定。
2. ir_gen.cr:482-483 的字面量到 IR_CONST 标为 dex,apx，binary64 位模式保留属于 apx 表示，TI_FLOAT 更名属于 dex 侧。
3. ast.cr:99 的 T_FLOAT_TYPE 标为删除。它从未被 lexer 发射，是死常量，float 关键字实际由词素匹配。删除后不重编号，则 LSP 区间 T_INT_TYPE..T_AUTO_TYPE（90..95）的语义不变。
4. 计划文件 Task 5 的括号示例把 monomorph/module/dump/ccr_io/parser/lexer 整体列为 dex,apx。本表按 Global Constraints 逐点判定：类型名和常量更名站点属于 dex，即用户可见语义；只有 binary64 机制部分属于 dex,apx。以本表为准。
5. module.cr:361 的注释写 float=2，与代码 366 行的 =3 不符。这是既有 bug，不在本任务修复，已备注。
6. bootstrap/corec 不在预扫范围内，但它是构建的关键依赖。`build_selfhost_native.py` 依赖它，并且 bootstrap 不支持 dex，包括 float 算术、提升规则和解释器中的 Python float。Task 2 增加 dex 时必须同步修改 bootstrap，否则自举会中断。已作为附录写入文档，建议按 dex,apx 处理，任务归属需要维护者确认。

## 完整性自检结果

9 条 grep 复查命令全部与主表一一对应：TY_FLOAT 6 文件、TI_FLOAT 41 处 5 文件、T_FLOAT/T_FLOAT_TYPE、EXPR_FLOAT 6 处、IR_I2F/F2I 3 文件、T_FLOAT_F32/F64、W_F32/W_F64、_f32/_f64 仅 ast.cr:84 注释、tests/suite 等零命中、docs 21 文件。没有未列入站点的 float 出现。文档包含完整的自检命令清单和计数核对。

## Fix 1：审查修复（2026-08-16）

提交：`ktulwqnq 20d4d9b5`，信息为 `docs: 迁移盘点修正——core.ebnf/tokens.ebnf 补全 + 自检计数修正`。只包含 `docs/numeric-migration-inventory.md`。

分类结论不变，原来的 73 个站点全部核验正确。本次只补充完整性并修正计数：

1. core.ebnf 从 1 处改为 3 处，全部为“保留”：原表只有 core.ebnf:29-31 的注释。补入 57-58（FLOAT_LIT 设计注释）和 59（`Literal = INT_LIT | FLOAT_LIT | ...`，终结符仍在文法产物中）。同时修正 29-31 行理由中“无残留语法”的错误断言：FLOAT_LIT 终结符仍然存在，字面量在 dex 世界中继续存在，3.14 默认精确；文法同步归 Task 7，不是残留，也不删除。
2. tokens.ebnf 补一行，1 处“保留”：tokens.ebnf:24 的 `FLOAT_LIT = ...` 终结符定义。原盘点漏列的原因已注明：FLOAT_LIT 全大写，大小写敏感的 “float” grep 不会命中。
3. 自检计数修正：
   - “21 文件 84 处”改为 21 文件 89 处。口径为词边界 `\bfloat\b`，2026-08-16 复查：compcert-reference 8、error-codes 2、pseudocode 10 文件 21、specs 5 文件 13、plans 4 文件 45，不含本清单自身 74 处；docs 全量为 22 文件 163 处。原来的“84 处”无法复现，原因是 plans 文档演化增补、pseudocode 复核为 21。口径已写入文档。子串口径（包含 float_str_bits 等复合词）为 98。
   - “13+3+1 个源码文件”改为 13+2+1=16：src 13 个，tests 2 个（test_pipeline.py 和 test_native_strings.py），grammar 1 个（core.ebnf）。
   - `_f32/_f64 仅 ast.cr:84` 的断言修正为 3 处：ast.cr:84（注释）、lexer.cr:121（str_to_f64_bits）、lexer.cr:331（str_to_f64_bits 调用）。后两者已列入主表的 lexer 行，这里只修正自检文字。
   - 零站点清单剔除 tokens.ebnf，因为它的 FLOAT_LIT 定义已入表。自检 grep 清单增加 `FLOAT_LIT` 复查行。
4. 争议点补充第 7 条，即判据对称性：T_FLOAT_TYPE（删除）和 T_FLOAT_F32/F64（保留）都是从未被发射的令牌常量。lexer 只发 T_FLOAT（lexer.cr:330-331 是唯一发射点），parser.cr:409-410 的宽度分支是死代码，w 恒为 0，`_f32/_f64` 后缀在词法层就被消费，位宽丢失。判据是：“保留”是约束原文（_f32/_f64 保留）的明确要求，并且迁移后有指称，即 apx CPU 位宽标注；T_FLOAT_TYPE 没有任何指称，所以删除。同时提示：apx 位宽标注需要在 lexer 增加发射路径，当前不生效，属于 Task 5/6 的实现项。
5. bootstrap 附录的“约 14 处”改为 21 处，7 文件。口径是含大小写 float/FLOAT_LIT 的站点行数，type_checker.py:230 一行双命中计 1 处，小写 grep 为 19 行。补入 lexer.py:108（FLOAT_LIT 令牌发射）、parser.py:508（FLOAT_LIT 分支检查）、type_checker.py:230（比较规则）三处。

修正后计数：主表 76 个站点行，其中 dex 38、dex,apx 16、保留 21、删除 1。原 73 行的分类结论不变，新增 3 行保留。docs 汇总 1 行，21 文件 89 处。范围外附录 21 处，未计入主表。

验证：9+3 条 grep 复查与文档完全一致。`grep -rln "float" src/ tests/ grammar/` 得到 16 文件；`grep -rn "FLOAT_LIT" grammar/` 得到 tokens.ebnf:24、core.ebnf:57/59；`grep -rno "\bfloat\b" docs/` 得到 163 处/22 文件，其余 21 文件 89 处；`grep -rn "_f32\|_f64" src/ tests/ grammar/` 得到 3 处；`grep -rn "float" bootstrap/corec/` 得到 19 行，即 21 个站点行。

## Fix 2：复审修复（2026-08-16）

提交：`vuxzkonz 5b409ba5`，信息为 `docs: 迁移盘点——bootstrap 附录计数修正（tokens.py FLOAT_LIT + stack_asm 条目）`。只包含 `docs/numeric-migration-inventory.md`。

Fix 1 的 bootstrap 附录计数（21 处/7 文件）与全大小写 grep 口径不一致。`grep -rn "float\|FLOAT_LIT" bootstrap/corec/` 实际为 22 行/8 文件，其中小写 “float” 19 行，FLOAT_LIT 专属 3 行：tokens.py:7、lexer.py:108、parser.py:508。tokens.py:7 被计入口径却没有列条目，清单和计数不闭合。本次修复：

1. 补 `bootstrap/corec/syntax/tokens.py:7`（`FLOAT_LIT = auto()`）条目。它是 FLOAT_LIT 枚举成员定义，全大写，不会命中大小写敏感的 “float” grep，是 3 个 FLOAT_LIT 专属行之一。另外两个是 lexer.py:108 的发射和 parser.py:508 的分支检查，已在 Fix 1 补列。
2. 计数从 21 处/7 文件改为 22 处/8 文件。附录导语和“计数核对”段同步修正。“小写 grep 仅 19 行”仍然成立，并注明 FLOAT_LIT 专属 3 行。
3. 给 `x86_64_stack_asm.py:145` 条目补充精确代码（`isinstance(val, float)`）。该条目从初版就在列，表示 float 常量发射，本次按复审意见用实际代码精确描述，确保可追溯。
4. 自查命令补上大小写覆盖。`FLOAT_LIT` grep 清单新增两行：`grep -rn "FLOAT_LIT" bootstrap/corec/`，结果为 tokens.py:7、lexer.py:108、parser.py:508；以及 `grep -rn "float\|FLOAT_LIT" bootstrap/corec/ | wc -l`，结果为 22，附录 8 文件 22 处闭合。

修正后附录为 bootstrap/corec 8 文件 22 处。口径是含大小写 float/FLOAT_LIT 的站点行数，type_checker.py:230 一行双命中计 1 处，小写 grep 为 19 行。主表和 docs 汇总计数不变，仍是 76 个站点行、21 文件 89 处。

验证：`grep -rn "float\|FLOAT_LIT" bootstrap/corec/ | wc -l` 为 22，文件数为 8。逐文件核对：tokens.py 1、lexer.py 4、parser.py 4、type_checker.py 5、ir_gen.py 3、cir.py 1、interpreter.py 3、x86_64_stack_asm.py 1，清单条目与计数完全闭合。
