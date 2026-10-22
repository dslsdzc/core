# Task 7 报告：grammar/EBNF 同步和全链路终验（dex+apx 迁移收尾）

日期：2026-08-16

## 结论

DONE。EBNF 已与实现同步（FLOAT_LIT 终结符改为 DEX_LIT，与 lexer 的 T_DEX 令牌名一致），全链路终验全部通过，自举成功。

## 1. EBNF 改动清单（对照实现真源）

实现真源核对（Task 7 执行时读码确认）：
- lexer.cr:387：含小数点或 f32/f64 后缀的十进制数字统一发 `add_tok_int_lex(T_DEX, str_to_scaled(num_str), str_intern(num_str), ...)`。字面量令牌名为 T_DEX（ast.cr:8，原 T_FLOAT 在 Task 3 改为 T_DEX）。int_val 是定点缩放整数，lexeme 槽是原数字串。
- lexer.cr:362-380：数字扫描只接收 DIGIT；`.` 的消费条件是下一个字符不是 `.`（保护 `0..4` 区间）；`is_alpha`（lexer.cr:30-33）包含 `_`（95）。
- parser.cr:670-714：声明标签为 mut/pub/apx（706 行 `else if tag == "apx"`）；未知标签报 TA08。
- parser.cr:84：类型名为 dex（float 已移除）。

### 改动 1：grammar/tokens.ebnf（字面量终结符定义）

```
- INT_LIT = DIGIT { DIGIT | '_' } [ INT_SUFFIX ] ;
- FLOAT_LIT = DIGIT { DIGIT | '_' } '.' DIGIT { DIGIT | '_' } [ 'f32' | 'f64' ] ;
+ (* 数字字面量不支持 '_' 分隔符（lexer.cr：数字扫描只接收 DIGIT；'_' 属于 is_alpha（95），
+    会被消费为后缀，产生无效 T_INT(-1)；bootstrap lexer 支持 '_'，两实现有分歧，
+    以实现为准，取不支持） *)
+ INT_LIT = DIGIT { DIGIT } [ INT_SUFFIX ] ;
+ (* 3.14 十进制小数生成 DEX_LIT（数值迁移：T_FLOAT 改为 T_DEX，见 core.ebnf 的 Literal 注）。
+    定点缩放精确解析（int_val = 缩放整数），lexeme 槽保留原数字串（apx 场景由
+    str_to_f64_bits 还原 binary64 位模式）。f32/f64 后缀是 apx CPU 位宽标注
+    （lexer 消费后缀后统一发 T_DEX，宽度透传为已知缺口，见 numeric-migration-inventory 争议点 7） *)
+ DEX_LIT = ( DIGIT { DIGIT } [ '.' DIGIT { DIGIT } ] | '.' DIGIT { DIGIT } ) [ 'f32' | 'f64' ] ;
```

对照实现：
- 终结符名从 FLOAT_LIT 改为 DEX_LIT（lexer 实际令牌名为 T_DEX，按 EBNF 大写命名惯例）。
- 移除 `'_'` 分隔符：self-hosted lexer 的数字扫描只接收 DIGIT；`1_000` 实测被消费为后缀（`_000` 属于 is_alpha），产生无效 T_INT(-1)，编译报错。bootstrap lexer 支持 `_`，两实现有分歧，以实现（lexer.cr）为准，注释已注明。
- 新增 `.5` 前导点形式（lexer.cr:350 入口 `c == 46 && is_digit(peek)`）；f32/f64 后缀没有点也构成 DEX_LIT（`1f32`，lexer.cr:387 条件 `has_dot != 0 || suffix == "f32" || suffix == "f64"`）。
- 保留 `[ 'f32' | 'f64' ]` 后缀（apx CPU 位宽标注角色，同 core.ebnf 注）。

### 改动 2：grammar/core.ebnf（Literal 产生式）

```
- (* 注：FLOAT_LIT（`3.14` 十进制小数）默认产生 dex（精确小数）；f32/f64 后缀暂作 apx 的
-    CPU 位宽标注（见数值类型设计，2026-08-16） *)
- Literal = INT_LIT | FLOAT_LIT | STRING_LIT | CHAR_LIT | BOOL_LIT | UNIT_LIT | 'None' | 'Some' '(' Expr ')' ;
+ (* 注：DEX_LIT（`3.14` 十进制小数，词法令牌名 T_DEX，原 T_FLOAT）默认产生 dex（精确
+    定点小数，数值迁移 Task 4）；f32/f64 后缀是 apx CPU 位宽标注（见数值类型设计，
+    2026-08-16；lexer 消费后缀后只发 T_DEX，宽度透传为已知缺口） *)
+ Literal = INT_LIT | DEX_LIT | STRING_LIT | CHAR_LIT | BOOL_LIT | UNIT_LIT | 'None' | 'Some' '(' Expr ')' ;
```

### 已同步站点（Task 2-6 完成，本轮核实无残留）

- core.ebnf:28 的 `BaseType = 'int' | 'dex' | ...`（float 已移除）已同步
- core.ebnf:29-30 的历史注释（'float' 类型名已移除……）已同步
- core.ebnf:85 的 `Tag = 'mut' | 'pub' | 'apx'`（对照 parser.cr:706）已同步
- grammar/corespec.ebnf：float 命中 0 次

## 2. 验收清单逐项结果

| 验收项 | 结果 | 证据 |
|---|---|---|
| 分类表所有站点已迁移（grep float 仅剩历史注释或文档引用） | 通过 | `grep -rn "float" src/ tests/ grammar/`：命中 16 个文件，全部为注释、守卫测试或保留机制名（float_str_bits 函数名），与 inventory 完整性自检口径一致（src 9 个文件含注释、tests 守卫或 docstring、grammar 仅 core.ebnf:29 历史注释）；`grep -rn "FLOAT_LIT" grammar/` 为 0 命中（原 tokens.ebnf:24、core.ebnf:57/59 三个保留站点已迁移）；corespec.ebnf 为 0 |
| dex 精确语义测试通过（0.1+0.2==0.3、打印 "0.1"） | 通过 | tests/suite/dex_test.cr 编译运行得到 `ALL PASS` exit 0（13 个断言含 0.1+0.2==0.3、1/10 打印 "0.1"、3.14+2.86==6.0、1/3 判别子 0.333333 不等于 binary64）；tests/bootstrap/test_dex_arith.py 14/14；tests/selfhost/test_dex_arith.py 9/9 |
| apx 行为测试通过（binary64 结果） | 通过 | tests/selfhost/test_dex_arith.py：apx print 为 6 位舍入（0.1 显示 '0.1'、1/3 显示 '0.333333'、1.0000006 显示 '1.000001'、-0.1 显示 '-0.1'），apx 跨函数边界精确；tests/selfhost/test_apx_tag.py 2/2（cir dump 中每个 apx 声明恰好 1 条 approx 指令）；tests/bootstrap/test_apx_tag.py 5/5 |
| 自举构建成功（编译器用 dex,apx 编译自己） | 通过 | `nice -n 19 python3 build_selfhost_native.py` exit 0，BUILD SUCCESS（build/corec、build/corearch、build/corelsp）；新 build/corec 冒烟：run 0.1+0.2 完成（run 子命令不打印裸返回值，属于既有 CLI 行为）；suite dex_test 用新编译器构建运行 ALL PASS |
| LSP/内核测试不回归 | 通过 | tests/selfhost/test_lsp.py 8/8（含 stdout 污染守卫）；tests/selfhost/test_compile.py（native ELF 编译运行 PASS）；tests/selfhost/test_native_strings.py PASS；tests/bootstrap/test_pipeline.py 24/24 |

Step 2 全套命令（brief）：`test_pipeline` 24/24 通过，`test_compile` 通过，`test_lsp` 8/8 通过，`build_selfhost_native.py` exit 0 通过（`cpulimit` 本机未安装，按硬性规则 #6 的备选方案使用 `nice -n 19`）。

## 3. 对 brief 的偏差和原因

1. 一并修改 tokens.ebnf（brief Step 4 的提交命令只列了 core.ebnf）：brief Step 1 明确包含「tokens.ebnf：FLOAT_LIT 定义按实现更新」。同一提交包含两个文法文件，提交命令的路径参数补上 tokens.ebnf，没有实质偏差。
2. 顺带修正 INT_LIT（`{ DIGIT | '_' }` 改为 `{ DIGIT }`）：这不是 float 迁移站点，但同属数字字面量，与 DEX_LIT 共享同一个 lexer 扫描循环。实测 `1_000` 被消费为后缀，产生无效 T_INT(-1)（编译报 TF01），原 EBNF 与 self-hosted 实现不符。按「EBNF 以实现为准」修正并加注释说明（bootstrap 支持 `_`，分歧已注明）。如果需要保守，可以还原这一行，注释和 DEX_LIT 不受影响。
3. `.5` 前导点形式和 `1f32` 无点后缀形式写入文法：lexer 实际接受（lexer.cr:350/387），原 FLOAT_LIT 定义没有覆盖，按实现补齐。
4. 未改动：bootstrap/corec 的 FLOAT_LIT 保留点（tokens.py:7、lexer.py:108、parser.py:542），inventory 附录明确分类为「保留」（bootstrap 内部令牌名，范围外）；`float_str_bits` 函数名未改（保留机制名，inventory 主表为 dex,apx）。

## 4. 自审发现

1. EBNF 终态与实现一致：`DEX_LIT` 的产生式逐一对照 lexer.cr:350-389 的各分支（前导点、小数点加数字、f32/f64 后缀、`..` 区间保护不写入文法）；Tag/BaseType 对照 parser.cr:706/84。
2. 已知缺口如实注释：f32/f64 后缀的宽度透传缺失（lexer 消费后缀后只发 T_DEX；parser.cr:406-411 的 T_FLOAT_F32/F64 分支是死代码，w 恒为 0），这是 inventory 争议点 7 的既有缺口，EBNF 注释按实际情况描述（「宽度透传为已知缺口」），没有虚称标注生效。
3. lexer 宽容性和文法规范：lexer 接受 `1.`（点后没有数字也构成 T_DEX）；bootstrap 要求点后必须有数字。EBNF 取规范形式 `'.' DIGIT { DIGIT }`（点后必须有数字），注释没有展开这个宽容分支，属于可接受的口径选择。
4. inventory 文档自身有过时点：inventory 完整性自检的 `grep FLOAT_LIT grammar/` 期望 3 命中，而 Task 7 迁移后 grammar/ 为 0（预期结果）。inventory 是历史记录，未回改；如需可以补记说明。
5. 文档级改动零回归：本次改动只涉及 grammar/ 两个文件（纯文档），编译器源码未动；全链路测试通过，证明没有回归面。

---

## Fix F（终审修复，2026-08-16）

### M1（必须，回归阻塞）：TI_DEX_S=8 标记值与类型表首个动态类型下标碰撞，已修复

- 修复：`init_types`（checker.cr:19-29）末尾追加真实占位表项 `alloc_type(TYP_BASE, TY_DEX_S, 0)`，新增常量 `TY_DEX_S = 8`（ast.cr，与 TY_* 系列并列），用户类型从 9 起，`type_size`/`type_align`/`is_ptr_var` 三处标记值守卫（ir_gen.cr:142/315/367）永远不会再命中真实类型。`TI_DEX_S` 常量注释同步改写（ast.cr:304-311，8 不再是对撞下标，而是占位表项下标）。三个守卫保留（dex 精确变量仍然需要拦截）。
- 验证：
  - `struct P { a,b,c: int }` 的 `@sizeOf(P)` 为 24（修复前恒为 8）
  - 首个动态类型为 ref（`&int`）时，`p+1` 按 8 字节元素缩放，`@raw_int(q)-@raw_int(p)` 为 8（修复前为 1）
  - `tests/suite/at_test.cr:26-30` 的弱断言收紧：Point（2×int）从 `sz < 8` 改为 `sz != 16`；新增 `P3`（3×int）断言为 24，suite at_test 得到 ALL PASS
  - 新增 `tests/suite/ptr_ref_first.cr` 回归测试（ref 为编译单元首个动态类型的场景；用 `@raw_int` 字节差断言，确定性强，不依赖局部槽布局；初版依赖相邻槽的断言已被 IR 变量序中的中间临时变量证伪）
  - 无 dex 程序（at_test/ptr_arith/generics/lazy/arena/chan/go 等全部 suite）不回归

### M2（必须）：extern dex 实参字面量直传垃圾，已修复（IR 层验证）；运行时实测 BLOCKED

- 修复：ir_gen.cr 调用点的 dex 边界转换循环（1266-1310）扩展，`EXPR_EXTERN` 分支对 `TI_DEX_S` 实参补 `dex_scaled_to_bits` 转换（字面量重发射 binary64 位模式常量；计算值走 I2F/S 序列），与 Core 函数分支（bits 到 scaled）方向相反，落实 module.cr:361 的 ABI 契约（dex 编码 3 等于 binary64 跨 C 边界）。并行走 EXPR_ARG 链取实参节点，以命中字面量重发射快路径。
- 验证（IR 层，确定性）：`extern fn dex_ffi_bits_check(d: dex) -> int;` 加 `f(3.14)`，cir dump 的调用点序列为 `const dex = 3140000`（缩放字面量），然后 `const dex = 4614253070214989086`（3.14 的 binary64 位模式），最后 `call_extern`。新增 `tests/selfhost/test_dex_arith.py::test_extern_dex_arg_cir`（10/10 全部通过）。`tests/suite/ffi_test.cr` 补了 dex extern 声明面（仅声明，编译运行 ALL PASS）。
- BLOCKED（如实报告，写入 TODO）：运行时 C 侧实测被既有的 corearch `--link <so> --static` 路径崩溃阻塞。corearch 在 `ctx_emit_static`/`so_parse_text`（src/arch/linux/ld/ld.cr）内触发 SIGILL/SIGSEGV，堆栈已经被破坏（自举编译器自身的代码生成不稳定，疑似 IR_LAZY_THUNK 等指令在 sizes.cr 中的尺寸与实际发射字节数不一致，导致错位）。判定为既有缺陷：崩溃位于本分支零触碰的后端源码编译产物；`--link` 路径自始至终没有任何测试覆盖（仓库没有 core_rt.so 产物，也没有 .so 链接测试）；对照实验：int 型 extern 参数、apx 变量（TI_DEX）实参的 `--link` 链接都正常，只有「字面量经 M2 转换后直传」触发。C shim（用 union 位模式判等 3.14）已备好，待 `--link` 路径修复后启用（TODO 条目见下）。
- TODO：修复 corearch 的 `--link` 静态嵌入路径（so_parse_text 崩溃，以及只拷贝 .text、不拷贝 rodata/PLT 的脆弱性），补 C 侧位模式实测。

### Minors（随本分支）

1. 删除 `tests/selfhost/test_dex_arith.py:183` 的 `os.chmod("/tmp/dex_arith_bin", 0o755)`（Task 6 已修 ELF 输出为 0755，chmod 没有作用且注释过时）。
2. 收紧 `tests/selfhost/test_dex_type.py:83-88` 的 float 移除守卫：断言 `check` exit==0 且出现 TF01（TF01 非致命，防止双向变化）。

### 回归验证（全套件）

- tests/bootstrap/：pipeline 24/24、borrow 4/4、generics 2/2、apx_tag 5/5
- tests/selfhost/：dex_arith 10/10、dex_type 2/2、compile 通过、apx_tag 2/2、impl 7/7、borrow 7/7、lsp 8/8、native_strings 通过、native_memory 6/6、pointer_safety 通过、region_cfg 16/16、directory_build 通过、backend_bootstrap 通过
- tests/suite/：at_test（收紧加 P3）ALL PASS、ptr_ref_first 通过、ffi_test 通过、dex_test/ptr_arith/arena/fnaddr/generics/lazy/chan/conc/go_e2e/go_parallel/go_final/cache/hotpatch/dyn 全部 exit 0
- 自举：`nice -n 19 python3 build_selfhost_native.py` BUILD SUCCESS（新 build/corec 冒烟：@sizeOf(P)=24，interp dex 通过）
- 既有失败项（已核实与本分支无关，均为历史遗留 scratch）：
  - tests/suite/at_test_mini（没有 `import io` 却使用 println，运行期段错误）、at_test_mini4/mini6（嵌套 fn 语法使 corec 在解析期崩溃，parser.cr 未被本分支触碰，gdb 确认崩溃点在解析代码）
  - tests/ 根目录的 test_flow/test_go/test_go_range（旧 go/flow 语法，是没有 sched_init 的无主测试；规范的 suite go 测试（go_final/go_e2e/go_parallel）全部通过；崩溃是 go 派发的零地址间接调用，与类型表无关）

### 提交

`core: 终审修复，TI_DEX_S 占位消除下标碰撞 + extern dex 字面量转换 + 测试收紧`
（改动：src/compiler/{ast,checker,ir_gen}.cr 加 tests/{suite,selfhost}，共 8 文件，+117/-18）
