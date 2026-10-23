# 数值类型实现计划：dex + apx（float 移除，手动迁移）

> 受众：执行本计划的 agentic worker。必需子技能：`superpowers:subagent-driven-development`（推荐）或 `superpowers:executing-plans`，按任务逐项实施。进度以复选框（`- [ ]`）跟踪。
> 执行性质：手动迁移。每个 float 站点逐点判断语义归属（dex 或 dex,apx），禁止机械替换（sed 或全局替换）。

目标：实现 dex（精确小数，默认实数语义）与 apx（近似授权标签，后端变换许可），移除 float 类型，全仓库手动迁移。

架构：dex 是核心类型（定点缩放整数实现，精确运算）；apx 是变量级标签（与 mut/pub 同族），生成 IR_APPROX 注解，由后端实现（CPU 使用 binary64 快路径，使用现成浮点指令；其他范式忽略该标签，按精确处理）。迁移契约是任务 1 的分类表（人工审）；编译器内部浮点路径保留为 dex,apx（行为不变），用户可见的 float 类型迁移为 dex（默认精确）。

技术栈：Core 语言（编译器自身与 stdlib）、ELF 后端（现成 FPU 指令编码 instr.cr）、测试套件（tests/bootstrap、tests/selfhost、tests/suite）。

规格：`docs/superpowers/specs/2026-08-16-numeric-types-design.md`

## 全局约束

- 禁止 git，全部用 `jj`；提交信息中文
- 长时间编译/构建必须 `nice -n 19` 或 `cpulimit -l 10`（铁律 #6）
- 手动迁移：每个 float 站点逐点判断，禁止全局替换；分类表（任务 1 产出）是迁移契约，人工审
- 语义归属规则：编译器内部浮点路径（运算、打印、指令编码）使用 `dex, apx`（保留 binary64 行为，即 apx 快路径）；用户可见的 `float` 类型改为 `dex`（默认精确，这是语义变更，不是改名）；`_f32`/`_f64` 后缀保留（apx 的 CPU 位宽标注）
- 构建测试：`python3 build_selfhost_native.py`（自举编译是回归的基本要求，编译器自身迁移后必须能自举）
- 现有 API 保持不变（print/println/read_file 等），float 移除是设计确定的唯一例外

---

### 任务 1：迁移盘点与分类表（迁移契约）

涉及文件：
- 创建：`docs/numeric-migration-inventory.md`（分类表，任务 2-7 的契约）

接口：
- 产出：全仓库 float 站点清单，每个站点分类为 `dex`（精确）、`dex,apx`（保持行为）、`保留`（历史或注释）、`删除`（移除）

- [ ] 步骤 1：盘点源码站点

对以下文件逐处 grep `float`（含 TY_FLOAT、float 关键字、浮点指令助记符、float_str_bits、I2F/F2I 等变体），列出每个站点的文件与行号、上下文、角色（类型声明、运算、指令编码、打印、字面量、关键字、注释）：

- `src/compiler/ast.cr`（TY_FLOAT 常量、IR 指令）、`lexer.cr`（float 关键字、浮点字面量扫描）、`parser.cr`（float 类型解析）、`checker.cr`（float 类型规则、I2F/F2I 检查）、`ir_gen.cr`（float 运算生成、字面量）、`monomorph.cr`、`module.cr`、`dump.cr`、`ccr_io.cr`（序列化）
- `src/stdlib/fmt.cr`（float_str_bits）
- `src/arch/linux/ld/elf.cr`、`instr.cr`（addsd/subsd/mulsd/divsd/comisd/cvtsi2sd/cvttsd2si 编码 + XMM 栈帧）
- `src/lsp/analysis.cr`（semanticTokens 相关，共 5 处，逐处判断）
- `tests/bootstrap/test_pipeline.py`、`tests/selfhost/test_native_strings.py`、`tests/suite/` 相关
- `grammar/core.ebnf`

- [ ] 步骤 2：逐点分类

按全局约束中的语义归属规则给每个站点标分类，并写一句判定理由。编译器内部的运算、打印、指令使用 `dex,apx`；用户可见类型使用 `dex`；`_f32/_f64` 保留；注释与历史记录保留。

- [ ] 步骤 3：编写分类表文档

`docs/numeric-migration-inventory.md`：表格（站点、分类、理由）与迁移后的目标形态描述。自检：无遗漏站点（再 grep 一遍 float 对照）；每个分类都有理由。

- [ ] 步骤 4：提交

```bash
cd /home/DslsDZC/core && jj commit -m "docs: 数值类型迁移盘点：float 站点分类表（迁移契约）" docs/numeric-migration-inventory.md
```

---

### 任务 2：apx 标签机制（新功能）

涉及文件：
- 修改：`src/compiler/lexer.cr`（apx 关键字）、`src/compiler/parser.cr`（变量标签列表增加 apx）、`src/compiler/checker.cr`（识别标签并让类型信息携带 apx 位）、`src/compiler/ast.cr`（IR_APPROX 指令常量）、`src/compiler/ir_gen.cr`（在 apx 变量的运算处发射 IR_APPROX）、`src/compiler/dataflow.cr`、`dump.cr`、`ccr_io.cr`（IR_APPROX 注册，执行时按现有个别 IR 指令的注册点清单核对）、`src/arch/linux/ld/instr.cr`、`interp.cr`（IR_APPROX 处理：只作注解，没有运算语义）
- 测试：`tests/selfhost/test_apx_tag.py`（新增）

接口：
- 使用：分类表（任务 1）
- 产出：`apx` 变量标签（`x : int, apx` 语法合法、checker 识别、类型信息带 apx 位）；`IR_APPROX` 指令（无操作数，只有附注语义，后端可忽略，interp 跳过）

- [ ] 步骤 1：编写失败测试

`tests/selfhost/test_apx_tag.py`（Python 驱动自举编译器，参照既有 selfhost 测试结构）：
```python
def test_apx_tag_parses():
    # x : int, apx = 42; 应编译通过（check 子命令 exit 0）
    # x : int, bogus_tag = 42; 应报错（非法标签）
def test_apx_tag_no_semantic_change():
    # apx 标签不改变类型检查/IR 生成语义，带与不带 apx 的同一程序
    # 生成的 .ccr 仅在 apx 标记的运算处多 IR_APPROX 指令
```
（完整测试代码在实现时按既有 selfhost 测试模式编写；先失败：apx 标签解析失败。）

- [ ] 步骤 2：运行测试确认失败

```bash
cd /home/DslsDZC/core && python3 tests/selfhost/test_apx_tag.py
```
预期：FAIL（apx 未被 parser 识别）。

- [ ] 步骤 3：实现标签机制

- lexer.cr：`apx` 加入 lookup_keyword（若标签按关键字解析）或按标识符处理（执行时按 mut/pub 的实际实现路径处理：mut/pub 如何被 parser 识别，apx 就使用同一机制）
- parser.cr：变量声明的标签解析列表加 apx（与 mut/pub 同槽位）
- checker.cr：apx 标签认可（不报错）；类型信息或变量记录携带 apx 位（执行时按 mut 位的存储方式加 apx 位）
- ir_gen.cr：在 apx 变量的运算处发射 `IR_APPROX`（无操作数注解，执行时确认 ir_gen 里读取变量标签的位置）
- ast.cr：IR_APPROX 常量（执行时按 IR 指令编号段分配，先查现有最大 opcode 号）
- dataflow、dump、ccr_io、interp、ELF：IR_APPROX 注册（dump 打印、ccr 序列化、interp 跳过、ELF 不生成代码。执行时按现有个别 IR 指令的注册点清单逐一核对，interp 必须跳过，不能崩溃）

- [ ] 步骤 4：测试通过并回归

```bash
cd /home/DslsDZC/core && python3 tests/selfhost/test_apx_tag.py && python3 tests/selfhost/test_compile.py && nice -n 19 python3 build_selfhost_native.py
```
预期：apx 测试全部通过；test_compile 回归通过；自举构建成功（编译器自身尚不使用 apx，但 IR 新增指令不影响现有行为）。

- [ ] 步骤 5：提交

```bash
cd /home/DslsDZC/core && jj commit -m "core: apx 标签机制：变量标签 + IR_APPROX 注解（新功能，迁移前置）" src/compiler/ tests/selfhost/test_apx_tag.py
```

---

### 任务 3：dex 类型核心（TY_DEX 与字面量）

涉及文件：
- 修改：`src/compiler/ast.cr`（把 TY_FLOAT 改为 TY_DEX 常量；TYP 相关）、`src/compiler/lexer.cr`（`dex` 关键字，浮点字面量解析为 dex 字面量）、`src/compiler/parser.cr`（dex 类型解析）、`src/compiler/checker.cr`（dex 类型规则，执行时按 float 规则改名并微调语义）
- 测试：`tests/selfhost/test_dex_type.py`（新增）

接口：
- 使用：分类表（任务 1）
- 产出：`dex` 类型（TY_DEX，精确小数语义标记）；`3.14` 字面量解析为 dex 类型；`x : dex` 合法；float 关键字在 lexer/parser 移除（迁移站点按分类表处理。注意顺序：先加 dex，再移除 float，保持编译器可自举）

- [ ] 步骤 1：编写失败测试

`tests/selfhost/test_dex_type.py`：
```python
def test_dex_type_declares():
    # x : dex = 3.14; 编译通过（check exit 0）
    # fn f() -> dex { return 3.14; } 编译通过
def test_dex_literal_type():
    # fn main() -> int { x := 3.14; return 1; }：3.14 推断为 dex（不报错）
```

- [ ] 步骤 2：运行测试确认失败

预期：FAIL（dex 是未知类型，或 3.14 未被推断为 dex）。

- [ ] 步骤 3：实现 dex 类型

- ast.cr：把 TY_FLOAT 改为 TY_DEX（或新增 TY_DEX 并逐步迁移引用，执行时按 TY_FLOAT 的引用点数判断：引用少就直接改名，引用多就分步）
- lexer.cr：`dex` 加入关键字；浮点字面量扫描产出 dex 字面量 token（保留现有字面量解析逻辑：位模式与 ±1ulp 的处理属于 apx 快路径的字面量，先保留；dex 精确字面量的解析放在任务 4）
- parser.cr：dex 类型名解析（float 的解析路径改为 dex）
- checker.cr：dex 类型规则（float 规则改名；dex 默认精确语义的规则差异在任务 4 的运算实现中体现，此处类型层面先通）

- [ ] 步骤 4：测试通过并做自举回归

```bash
cd /home/DslsDZC/core && python3 tests/selfhost/test_dex_type.py && python3 tests/selfhost/test_compile.py && nice -n 19 python3 build_selfhost_native.py
```
预期：dex 测试通过；自举构建成功（编译器自身代码里的 float 站点尚未迁移，float 关键字还在，处于两种类型并存期）。

- [ ] 步骤 5：提交

```bash
cd /home/DslsDZC/core && jj commit -m "core: dex 类型：TY_DEX + 字面量 + 类型规则（与 float 并存期）" src/compiler/ tests/selfhost/test_dex_type.py
```

---

### 任务 4：dex 精确运算（定点缩放实现，新代码）

涉及文件：
- 修改：`src/compiler/ir_gen.cr`（dex 运算生成：无 apx 时生成定点缩放整数指令序列，有 apx 时使用现成浮点路径）、`src/compiler/checker.cr`（dex 运算类型规则，精确语义）
- 创建：`src/stdlib/dex.cr`（定点缩放运算：表示为缩放整数加精度；支持加减乘除、比较、打印。执行时设计定点方案：从固定缩放（如 10^9 内部精度）起步，溢出与舍入规则写入文档）
- 测试：`tests/suite/dex_test.cr` 与 `tests/selfhost/test_dex_arith.py`

接口：
- 使用：dex 类型（任务 3）
- 产出：dex 精确运算（字面量精确解析、加减乘除与比较、打印）；无 apx 的 dex 运算编译为定点整数指令序列；`dex.cr` 提供打印与转换辅助函数

- [ ] 步骤 1：编写失败测试

`tests/suite/dex_test.cr`（Core 程序，编译执行断言）：
```core
// 3.14 + 2.86 == 6.0（精确）
// 0.1 + 0.2 == 0.3（精确，浮点做不到）
// 1/10 打印为 "0.1"
```
（完整用例在实现时按 tests/suite 的既有模式编写；期望值为精确十进制。）

- [ ] 步骤 2：运行测试确认失败

预期：FAIL（dex 运算未实现，出现编译错误或结果错误）。

- [ ] 步骤 3：实现定点运算

- 定点表示：缩放整数（内部精度常量，执行时确定，建议 10^9，溢出规则写入文档）
- ir_gen：dex 运算（无 apx）生成定点指令序列（缩放乘法与加法，执行时按现有整数运算指令组合）；dex 运算（有 apx）走现有浮点路径（binary64）
- checker：dex 运算类型规则（dex op dex 得到 dex；int 参与时的转换规则，执行时按现有 float 的 int 隐式转换模式修改）
- dex 打印：`dex.cr` 或 fmt.cr（把定点数转为十进制字符串，去掉尾零）
- 字面量精确解析：`3.14` 转为定点整数（十进制转为缩放整数，不做二进制近似）

- [ ] 步骤 4：测试通过并回归

```bash
cd /home/DslsDZC/core && ./build/corec build tests/suite/dex_test.cr -o /tmp/dex_test --static && /tmp/dex_test && python3 tests/selfhost/test_dex_arith.py && python3 tests/selfhost/test_compile.py
```
预期：dex 精确语义全部通过（0.1+0.2==0.3）；回归通过。

- [ ] 步骤 5：提交

```bash
cd /home/DslsDZC/core && jj commit -m "core: dex 精确运算：定点缩放实现（无 apx 使用定点，有 apx 使用 binary64）" src/compiler/ src/stdlib/dex.cr tests/suite/dex_test.cr tests/selfhost/test_dex_arith.py
```

---

### 任务 5：编译器内部迁移（按分类表逐点执行）

涉及文件：
- 修改：分类表中所有 `dex,apx` 站点（`src/stdlib/fmt.cr` 的 float_str_bits、`src/arch/linux/ld/instr.cr` 的浮点指令、`src/arch/linux/ld/elf.cr`、`src/compiler/ir_gen.cr` 的 I2F/F2I、`monomorph.cr`、`module.cr`、`dump.cr`、`ccr_io.cr`、`parser.cr`、`lexer.cr`），按分类表逐个站点修改

接口：
- 使用：分类表（任务 1）与 dex/apx（任务 2-4）
- 产出：编译器自身的全部 float 站点迁移完毕，编译器代码里不再有 float（历史注释除外）；自举构建成功

- [ ] 步骤 1：按分类表逐站点迁移

按 `docs/numeric-migration-inventory.md` 的分类逐站点执行（手动、逐点：每个站点先读上下文，再按分类修改，然后记录）：
- `dex,apx` 站点：类型与常量名从 float 改为 dex，语义保持（binary64 路径不变，它们就是 apx 快路径）
- `保留` 站点：不动
- `删除` 站点：移除
- 每改完一个文件：`./build/corec check`（单文件语法/类型）

- [ ] 步骤 2：编译器自举迁移

编译器自身的 float 用法（如 float_str_bits 的调用、浮点测试代码）迁移为 dex/apx 写法（编译器代码使用 dex,apx，它本身就是 apx 快路径的消费者）。

- [ ] 步骤 3：自举全部通过

```bash
cd /home/DslsDZC/core && python3 tests/selfhost/test_compile.py && nice -n 19 python3 build_selfhost_native.py && ./build/corec check src/compiler/main.cr
```
预期：自举构建成功，编译器用 dex/apx 编译自己；corec2 路径照常（若可行）。

- [ ] 步骤 4：提交

```bash
cd /home/DslsDZC/core && jj commit -m "core: 编译器内部 float 到 dex,apx 迁移（按分类表逐点，自举通过）" src/compiler/ src/stdlib/ src/arch/
```

---

### 任务 6：移除 float 并迁移测试

涉及文件：
- 修改：分类表中 `删除` 的站点（用户可见 float 关键字与类型的残留）；`tests/bootstrap/test_pipeline.py`、`tests/selfhost/test_native_strings.py`、`tests/suite/` 的 float 用例（逐点判断：测精确语义的用 dex，测 binary64 行为的用 dex,apx）
- 测试：全测试套件

接口：
- 使用：分类表与任务 2-5 的产物
- 产出：语言里的 float 完全移除；测试套件全部通过

- [ ] 步骤 1：移除 float 关键字与类型

lexer/parser/checker 的 float 关键字与 TY_FLOAT 引用全部移除（分类表中 `删除` 的站点；确认编译器内部无残留，编译器自身已迁移到 dex,apx）。

- [ ] 步骤 2：逐点迁移测试

- 测浮点行为的用例按语义处理：精确断言用 dex；binary64 行为断言（位模式与舍入）用 dex,apx
- 新增 dex 精确断言（0.1+0.2==0.3 类）与 apx 行为断言（binary64 结果）

- [ ] 步骤 3：全套件回归

```bash
cd /home/DslsDZC/core && python3 tests/bootstrap/test_pipeline.py && python3 tests/selfhost/test_compile.py && python3 tests/selfhost/test_apx_tag.py && python3 tests/selfhost/test_dex_type.py && python3 tests/selfhost/test_dex_arith.py && python3 tests/selfhost/test_lsp.py && nice -n 19 python3 build_selfhost_native.py
```
预期：全部通过，自举成功。

- [ ] 步骤 4：提交

```bash
cd /home/DslsDZC/core && jj commit -m "core: float 移除：用户可见类型删除 + 测试逐点迁移（dex/apx 双语义）" src/compiler/ tests/
```

---

### 任务 7：grammar/EBNF 与结束验证

涉及文件：
- 修改：`grammar/core.ebnf`（float 移除、dex 类型、apx 标签、字面量产生式）

接口：
- 使用：任务 1-6 的产物
- 产出：EBNF 与实现一致；完整链路验证完成

- [ ] 步骤 1：同步 EBNF

`grammar/core.ebnf`：移除 float 产生式，改为 dex；标签产生式增加 apx；字面量产生式（3.14 解析为 dex 字面量）。对照 lexer.cr/parser.cr 的实际实现。

- [ ] 步骤 2：完整链路终验

```bash
cd /home/DslsDZC/core && python3 tests/bootstrap/test_pipeline.py && python3 tests/selfhost/test_compile.py && python3 tests/selfhost/test_lsp.py && nice -n 19 python3 build_selfhost_native.py
```

- [ ] 步骤 3：验收清单

- [ ] 分类表所有站点已迁移（grep float 仅剩历史注释/文档引用）
- [ ] dex 精确语义测试通过（0.1+0.2==0.3、打印 "0.1"）
- [ ] apx 行为测试通过（binary64 结果）
- [ ] 自举构建成功（编译器用 dex,apx 编译自己）
- [ ] LSP/内核测试不回归

- [ ] 步骤 4：提交

```bash
cd /home/DslsDZC/core && jj commit -m "docs: EBNF 同步 + 数值类型迁移终验" grammar/core.ebnf
```

---

## 执行前自查记录

- 规格覆盖：第二节的 dex 类型对应任务 3/4；第三节的 apx 标签对应任务 2；第四节的落点（字面量、检查器、IR、后端）对应任务 3/4/5；第五节的 float 移除迁移对应任务 1/5/6；第七节的命名对应任务 3/6；EBNF 对应任务 7。YAGNI（第六节）：隐式转换、字面量重载、扩展类型注册不做，计划未包含。
- 占位符：任务 4 的定点实现细节（内部精度常量、溢出规则）标注为「执行时定」。这是设计决策点，不是占位（计划给出建议值 10^9 与文档化要求）；各任务的「执行时按现有模式」标注表示现有代码的具体行号需要执行者读代码确认（与 LSP 计划同一惯例）。
- 类型一致性：TY_FLOAT 改为 TY_DEX 在任务 3 定义，任务 5/6 使用；apx 标签与 IR_APPROX 在任务 2 定义，任务 5 使用；分类表（任务 1）是任务 5/6 的逐点契约。
- 手动迁移性质：计划没有 sed 或全局替换步骤，每个站点单独列出、单独判定；编译器自举（任务 5 步骤 3）是迁移正确性必须通过的验收。
