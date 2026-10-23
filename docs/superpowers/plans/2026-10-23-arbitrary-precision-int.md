# 任意精度整数实施计划

## 基线

设计文档：`docs/superpowers/specs/2026-10-23-arbitrary-precision-int-design.md`

实现从设计提交之后开始。工作区中 `docs/superpowers/specs/2026-10-23-pattern-matching-ir-design.md`、`src/compiler/main.cr`、`src/stdlib/cli.cr` 是用户未提交内容，不纳入本计划的提交。

## 目标

把语言 `int` 从固定 64 位改成完整任意精度整数。前端保存精确值；`.ccr` 保存完整值和是否超过有符号 64 位的编码标记；后端负责立即数、装箱、机器字边界和运行期检查。

## 全局约束

1. 不新增用户可见的 `word`、`usize` 或 `i64` 类型。
2. 每个任务先写失败测试，再写实现。测试通过后才进入下一个任务。
3. 任务提交只包含该任务的源码、测试和必要的构建清单。
4. 任何 `.ccr`、`.cir`、ELF 或 canary 变化必须在该任务中明确说明原因。
5. 不使用全局字符串替换修改代码。移动或重命名时保留函数名和参数名。
6. 解释器和 ELF 路径对同一程序必须给出相同结果。
7. 超出机器字边界的值必须报运行期错误，不能截断或回绕。

## 阶段开关

实现期间使用 `BIGINT=1` 构建 `build/corec-big` 和 `build/corearch-big`：

- 不设置时，现有 `build/corec` 和 `build/corearch` 保持旧 64 位路径，现有测试和 canary 不变。
- 设置时，Python bootstrap 使用新的任意精度前端和后端，Core 新代码用新语义编译。
- 开关只用于保持主干可构建，不是产品模式。最后一个任务删除旧路径和开关。

## 任务 1：BigInt 运行时对象和算术

### 文件

- 新建 `src/runtime/bigint.cr`
- 新建 `src/runtime/bigint.LICENSE`
- 新建 `tests/runtime/bigint_driver.cr`
- 新建 `tests/runtime/test_bigint.py`

### 接口

```text
bi_from_word
bi_from_dec
bi_to_dec
bi_add
bi_sub
bi_mul
bi_div
bi_mod
bi_cmp
bi_neg
bi_is_zero
bi_to_word_checked
bi_to_uword_checked
```

### 步骤

1. 在 `src/runtime/bigint.cr` 实现 30 位 digit 的 BigInt 对象：
   - 对象头为 `sign`、`len`，每个字段占一个 Core 槽。
   - digit 小端序，每个 digit 保存 0..2^30-1。
   - 零规范化为 `sign=0`、`len=0`。
   - 非零对象去掉高位零 digit。
   - limb 中间值保持在 2^62 以内，不触发 BigInt 递归。
   - 使用 GMP 风格的规范化表示、schoolbook 乘加、Knuth 除法和小整数快路径。
2. 实现 tagged value：
   - 最高位 0 是立即数，低 63 位二补码。
   - 最高位 1 是 BigInt 指针。
   - 立即数范围 `[-2^62, 2^62-1]`。
3. 实现加减乘、向零截断的除法和取模、比较、取负、零判断、十进制读写和机器字范围检查。
4. 所有对象从 `alloc` 分配，分配失败走现有 OOM 路径。
5. `bigint_driver.cr` 提供最小测试入口，通过退出码报告结果。测试程序用现有 `corec` 编译，驱动只使用 30 位 digit 和 64 位以内的中间值。
6. 在 `bigint.cr` 头注和 `bigint.LICENSE` 保留 imath 的 MIT 许可与来源说明。GMP 只参考优化思想，不复制源码。移植代码不包含 C 源文件，也不链接 C 目标文件。

### 测试

`tests/runtime/test_bigint.py` 覆盖：

- 0、1、-1、立即数边界、2^62、-2^62-1。
- 2^100 的加减乘。
- 正负除法截断和余数符号。
- 除零。
- 十进制 `10^30` 往返。
- 有符号、无符号和地址三种机器字转换。
- 立即数加装箱、装箱加立即数、装箱加装箱。

### 验收

```bash
python3 tests/runtime/test_bigint.py
```

此任务不修改编译器。

## 任务 2：Python 前端和 IR 的大整数字面量

### 文件

- `bootstrap/corec/frontend/lexer.py`
- `bootstrap/corec/frontend/parser.py`
- `bootstrap/corec/syntax/ast.py`
- `bootstrap/corec/frontend/type_checker.py`
- `bootstrap/corec/frontend/ir_gen.py`
- `bootstrap/corec/ir/coreir.py`
- 新建 `tests/bootstrap/test_bigint_frontend.py`

### 步骤

1. Python lexer 不再拒绝超宽字面量。Python `int` 直接保存精确值。
2. AST 支持大整数字面量，不把值截断到 64 位。
3. Python 类型检查器对 big 常量返回 `int`。数组长度、索引、`@unroll` 等边界在超出机器字时给编译错误。
4. Python IR 常量节点可以保存 Python 大整数。
5. 常量折叠保持精确。

### 验收

```bash
python3 tests/bootstrap/test_bigint_frontend.py
```

覆盖字面量、常量折叠、边界诊断和 IR 常量。

## 任务 3：Python 后端 tagged value 和 BigInt 调用

### 文件

- `bootstrap/corec/backend/x86_64_stack_asm.py`
- `bootstrap/corec/backend/interpreter.py`
- `bootstrap/corec/backend/base.py`
- `tests/bootstrap/test_bigint_pipeline.py`
- `build_selfhost_native.py`

### 步骤

1. Python 后端为小整数生成 tagged 立即数。
2. 超出立即数范围的常量生成静态 BigInt 对象。
3. 加减乘除、取模、比较生成立即数快路径和 BigInt 运行时调用。
4. 指针、FFI、`w64/r64`、`@ptr_of`、`@str_of` 生成范围检查。
5. 编译器自身保持 raw；`build_selfhost_native.py` 不生成 tagged 的 `corec-big`。tagged Python 代码生成只用于用户程序测试。
6. `test_bigint_pipeline.py` 用 Python 后端编译并运行一个 Core 程序，覆盖大整数字面量、算术、函数调用和返回；BigInt 运行时单独以 raw 语义编译并链接。

### 验收

```bash
python3 build_selfhost_native.py
python3 tests/bootstrap/test_bigint_pipeline.py
bash tools/baseline/canary_check.sh
```

不设置任何开关时编译器仍以 raw 语义构建和运行。

## 任务 4：Core 前端和 `.ccr` 大常量

### 文件

- `src/compiler/lexer.cr`
- `src/compiler/ast.cr`
- `src/compiler/parser.cr`
- `src/compiler/checker.cr`
- `src/compiler/opt.cr`
- `src/compiler/ir_gen.cr`
- `src/compiler/ccr_io.cr`
- `src/compiler/cir_cache.cr`
- `src/compiler/ccr_schema.cr`
- 新建 `tests/selfhost/test_bigint_literals.py`

### 接口

- `T_BIGINT` token，词素是规范十进制字符串。
- `EXPR_BIGINT`，`a` 是字符串下标，`type_val=TY_INT`。
- `IR_CONST_BIG = 34`，`d=目标变量`，`s1=字符串下标`，`tk=TI_INT`。
- `.ccr` 版本 v9.1，编码为 `(9 << 16) | 1`。
- `CIR_CACHE_VER = 23`。

### 步骤

1. 词法不再在 64 位处报错。超出有符号 64 位的字面量生成 `T_BIGINT`，保留规范十进制文本。
2. parser 生成 `EXPR_BIGINT`。小常量继续 `EXPR_INT`。
3. checker 对 `EXPR_BIGINT` 返回 `TI_INT`。需要机器字的位置转换成机器字，越界报编译错误。
4. 常量折叠使用 new compiler 的 `int` 运算。此任务由 `corec-big` 编译和验证，因此折叠本身可以使用任意精度。
5. `ir_gen` 生成 `IR_CONST_BIG`，字符串通过现有 STR 段 intern。
6. `ccr_io` 写入和读取 `IR_CONST_BIG`。NOD 记录大小不变。
7. `cir_cache` 保存和恢复 `IR_CONST_BIG`。
8. 版本号提升，旧版本拒绝。

### 测试

`test_bigint_literals.py` 覆盖：

- `9223372036854775807`、`9223372036854775808`、`-9223372036854775809`。
- 十六进制、八进制、二进制大常量。
- 大常量作为普通表达式、函数参数和返回值。
- 大常量作为数组长度或索引时报编译错误。
- `corec-big check` 通过。
- `corec-big ccr` 输出包含 `IR_CONST_BIG` 和规范十进制字符串。
- `corec-big cir` 输出包含大常量。

### 验收

```bash
python3 tests/selfhost/test_bigint_literals.py
./build/corec-big check src/compiler
```

此任务只验证前端和载体，不要求 ELF 后端能执行大整数。

## 任务 5：self-hosted 后端常量和算术

### 文件

- 新建 `src/arch/x86_64/int_rep.cr`
- `src/arch/x86_64/instr.cr`
- `src/arch/x86_64/frame.cr`
- `src/arch/x86_64/regalloc.cr`
- `src/arch/x86_64/corearch.cr`
- `src/targets/x86_64-linux/main.cr`
- 新建 `tests/selfhost/test_bigint_arith.py`

### 步骤

1. `int_rep.cr` 提供 tagged value 的立即数判断、拆装、范围检查和常量对象布局。
2. `instr.cr` 实现 `IR_CONST_BIG`，生成静态 BigInt 对象或运行期解析调用。
3. 整数加减乘除、取模、比较、取负接入立即数快路径和 BigInt 运行时。
4. 除法按向零截断和余数符号规则生成。
5. 除零进入统一运行期错误入口。
6. corearch 和 project-mode 入口支持 `--big-int`，未启用时保持旧路径。

### 测试

`test_bigint_arith.py` 覆盖：

- 小整数仍走立即数快路径。
- 立即数边界加减。
- 2^100 的加减乘。
- 正负除法、取模、除零。
- 大整数比较和取负。
- 同一条 `.ccr` 用新旧后端分别执行小整数程序，结果相同。

### 验收

```bash
python3 build_selfhost_native.py
python3 tests/selfhost/test_bigint_arith.py
```

`corearch --big-int` 只改变用户程序；不设置该旗标时旧的 raw 路径和 canary 保持不变。

## 任务 6：容器、调用和全局变量

### 文件

- `src/arch/x86_64/instr.cr`
- `src/os/linux/callseq.cr`
- `src/compiler/ir_gen.cr`
- 新建 `tests/selfhost/test_bigint_containers.py`

### 步骤

1. `int` 局部变量、参数、返回值、全局变量保存 tagged value。
2. `IR_ALLOC`、`IR_LOAD`、`IR_STORE` 按 8 字节槽搬运。
3. `IR_ALLOC_ARRAY`、`IR_ALLOC_STRUCT`、字段和索引操作保存 tagged value。
4. 数组长度、索引、切片边界在进入机器字运算前做范围检查。
5. 大整数经过递归、函数调用和全局初始化后结果不变。

### 测试

覆盖局部变量、参数、返回值、递归、全局变量、数组、结构体、元组和枚举 payload。

### 验收

```bash
python3 tests/selfhost/test_bigint_containers.py
```

## 任务 7：指针、FFI 和原始字边界

### 文件

- `src/arch/x86_64/instr.cr`
- `src/os/linux/callseq.cr`
- `src/compiler/checker.cr`
- `src/compiler/ir_gen.cr`
- 新建 `tests/selfhost/test_bigint_boundaries.py`

### 步骤

1. `@ptr_of` 返回地址的数学整数。
2. `@str_of`、`w64`、`r64`、`syscall3/4` 的参数和返回值做机器字范围检查。
3. 指针加减和 `IR_ADDR_INDEX` 的偏移先转机器字。
4. `extern` 的 `int` 参数和返回值在调用边界转换。
5. 越界值输出包含操作名和原值的运行期错误。

### 测试

覆盖地址往返、指针偏移、大整数传给 `w64`、`@str_of`、`syscall3`、`extern` 时失败、C 返回值转换和合法范围内不误报。

### 验收

```bash
python3 tests/selfhost/test_bigint_boundaries.py
```

## 任务 8：解释器

### 文件

- `src/compiler/interp.cr`
- `src/compiler/ir_gen.cr`
- 新建 `tests/selfhost/test_bigint_interp.py`

### 步骤

1. `g_ir_vals` 的 `int` 槽保存 tagged value。
2. 解释器自己的 `int` 运算使用任意精度语义。
3. `IR_CONST_BIG` 从字符串或静态对象装入。
4. 指针、`w64/r64`、`@str_of` 使用与 ELF 后端相同的检查。
5. 修正解释器现有的 64 位槽假设。

### 测试

同一组大整数程序分别用 `corec-big run` 和 ELF 路径执行，比较返回值、输出和错误文本。

### 验收

```bash
python3 tests/selfhost/test_bigint_interp.py
```

## 任务 9：切换默认语义和移除 2-limb

### 文件

- `src/arch/x86_64/tag2l.cr`
- `src/arch/x86_64/frame.cr`
- `src/arch/x86_64/instr.cr`
- `src/arch/x86_64/backend_globals.cr`
- `src/arch/x86_64/backend_arrays.cr`
- `src/compiler/*`
- `tests/selfhost/test_mw_*.py`
- `tests/selfhost/test_dex_type.py`
- `tests/selfhost/test_lexer_parity.py`
- `tools/baseline/canary_values.tsv`

### 步骤

1. 默认构建启用 BigInt，删除 `BIGINT` 开关和旧 64 位路径。
2. 删除 `tag2l.cr`、`g_x86_mw_*` 状态和帧中的 tag 区。
3. 重写依赖 64 位溢出和 2-limb 的测试：
   - 原先期望 i64 溢出的测试改为期望精确大整数。
   - 原先测试 2-limb 快慢路径的测试改为测试 tagged 立即数/装箱路径。
   - `test_dex_type.py` 的大十进制字面量溢出测试改为成功用例。
   - `test_lexer_parity.py` 的字面量溢出预期同步修改。
4. 更新 `.ccr` v9.1 和 `.cir` v23 的测试。
5. 重新采集 canary 值，记录每个值变化的原因。
6. 全量自举并比较阶段产物。

### 验收

```bash
python3 build_selfhost_native.py
./build/corec check src/compiler
python3 tests/selfhost/test_bigint_arith.py
python3 tests/selfhost/test_bigint_containers.py
python3 tests/selfhost/test_bigint_boundaries.py
python3 tests/selfhost/test_bigint_interp.py
python3 tests/selfhost/test_backend_bootstrap.py
bash tools/baseline/canary_check.sh
```

三阶段自举：

```bash
./build/corec build src/compiler/main.cr -o /tmp/corec2 --static -O 0
/tmp/corec2 build src/compiler/main.cr -o /tmp/corec3 --static -O 0
cmp /tmp/corec2 /tmp/corec3
```

## 集成顺序

1. 任务 1 只改运行时，不进入编译器。
2. 任务 2 到 3 改 Python bootstrap 前端和后端：编译器仍 raw，tagged 代码生成只用于用户程序测试。
3. 任务 4 到 8 用 raw 的 `corec` 和 `corearch --big-int` 逐步替换 Core 前端、后端和解释器。
4. 任务 9 才切换默认语义，删除旧路径，更新 canary。

## 不包含

1. 不新增用户可见的机器字类型。
2. 不实现大整数到 C ABI 的自动多字传递；超出 64 位报错。
3. 不改变 `dex` 的 binary64 语义。
4. 不保证大整数运算与立即数运算有相同性能。
5. 不改变 arena 生命周期模型。

## 风险

1. Python bootstrap 后端是最大瓶颈。它必须同时支持 tagged value、BigInt 常量和算术，否则 stage0 无法生成 corec-big。
2. 编译器自身广泛使用 `int` 作为索引和计数。立即数快路径必须在任务 5 就位，否则自举会非常慢。
3. 现有 `test_mw_*` 测试依赖 2-limb 实现细节，不能直接保留。需要按语义重写，而不是改期望值。
4. `.ccr` 和 `.cir` 版本变化后，旧 corearch 和旧缓存必须拒绝，不能静默读错。
5. 指针、FFI 和原始字边界如果漏掉范围检查，会把大整数对象的指针传给外部代码，造成难定位的运行期错误。

## 任务 9 当前裁决

已落地默认切换，但保留 raw 回退用于编译器自举：

- 用户程序的 `.ccr` header reserved 字段为 0，`corearch` 默认按 tagged BigInt 发射。
- 编译器/自举链的 `.ccr` header 写 `CCR_FLAG_RAW_INT`；`corearch` 自动按 raw 发射，也支持显式 `--raw-int`。
- `.ccr` 版本为 v9.1 `(9 << 16) | 1`；`.cir` 缓存版本为 23。
- 2-limb `tag2l` 仍作为 raw 编译器/回退路径保留，尚未删除；默认用户程序不经过它。
- canary 已按 v9.1、默认 tagged ELF 和全局整数初始化重新锁定。
