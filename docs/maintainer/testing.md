# 测试与回归操作手册（testing）

> 定位：受众 = maintainers；状态 = active；出处 = [tests/](../../tests/) 与 [src/ci/run.sh](../../src/ci/run.sh)（命令以仓库现状为准，有出入时先修改源码注释或本文）。
> 仓库结构、构建和分支见 [onboarding.md](onboarding.md)；命令速览另见 [CLAUDE.md](../../CLAUDE.md) 的 Build & Test 一节；未完成项见 [TODO.md](../../TODO.md)。

## 一、三套测试的用途与运行方法

### tests/bootstrap/：Python bootstrap 管线回归

用途：纯 Python 驱动，import `bootstrap/corec` 模块，走完整管线（lex、parse、resolve、desugar、typecheck、ir_gen），然后解释执行并比较结果；诊断类用例比较错误数。不依赖 build/corec。

核心文件：test_pipeline.py（核心管线：词法、字面量、表达式、控制流）、test_borrow.py（借用检查错误检测）、test_generics.py（泛型函数 + 泛型结构体）；同目录的 test_apx_tag/test_dex_arith/test_dex_type/test_modules 等脚本，以目录实际情况为准。

运行方法（仓库根目录，无需先构建）：

```bash
python3 tests/bootstrap/test_pipeline.py
python3 tests/bootstrap/test_borrow.py
python3 tests/bootstrap/test_generics.py
```

### tests/selfhost/：自举/原生编译器回归

用途：主要驱动原生 `build/corec` 子进程；test_compile.py 另演示“拼接 src/compiler 和 src/stdlib 源码，用 Python bootstrap 全管线编译，再由解释器执行”。前置条件：先运行 `python3 build_selfhost_native.py`。build/corec 缺失时，脚本直接报 `[FAIL] missing native compiler`。

核心文件有三个：

- test_compile.py：自举管线的基本检查（拼接编译器源码并编译，执行示例程序并比对结果）
- test_impl.py：impl/方法接收者/self 字段。CHECK_CASES（check 必须通过）和 NATIVE_CASES（编译成 ELF 运行，断言退出码）
- test_borrow.py：借用检查的 7 条规则（分类见第二节）。用例是 `(名称, 内联源码, 期望是否报借用错)`，测试写临时 `.cr` 文件并运行 `corec check`。约定：期望有诊断时退出码为 1，无诊断时为 0（check 命令按“有诊断即失败”处理；断言以当前约定为准，见文件内注释）

运行方法：

```bash
python3 tests/selfhost/test_compile.py
python3 tests/selfhost/test_impl.py
python3 tests/selfhost/test_borrow.py
```

同目录其余脚本（test_backend_bootstrap/test_lsp/test_pointer_safety/test_native_*/test_region_cfg 等）使用同一模式，以目录实际情况为准。test_backend_bootstrap.py 已内置 `nice -n 19` 和 180 秒超时。

### tests/suite/：集成用例（.cr 源码）

用途：端到端集成测试。tests/suite/*.cr 逐个经 `./build/corec build` 编译成 ELF 并运行，main 返回 0 为通过；`*_mini*.cr` 视为开发草稿，CI 跳过。

单文件运行方法：

```bash
./build/corec build tests/suite/at_test.cr -o /tmp/core_suite_bin --static
chmod +x /tmp/core_suite_bin && /tmp/core_suite_bin
```

全量测试通过 CI job 运行：`CI_JOB_NAME=suite src/ci/run.sh`（job 列表见第三节）。

## 二、添加用例

通用结构：文件头部定义 helper，中间是用例列表或内联调用，结尾汇总结果（passed/failed，然后调用 sys.exit）。添加后先运行单文件，再运行该套件的全部用例；修改编译器本体后还要执行第三节的 full-bootstrap。

- bootstrap 管线类：模块体直接调用 `run_test(name, src, expected)`（int 结果）或 `run_test_raw(name, src, expected)`（string/float）：
  ```python
  run_test("add", "fn add(a: int, b: int) -> int { return a + b; } fn main() -> int { return add(2, 3); }", 5)
  ```
  借用错误类使用 `check_errors(src, desc, expect_errors)`（断言错误数的有无）。
- selfhost 借用检查（test_borrow.py）：向 `CASES` 添加元组 `(名称, 内联源码, 期望是否报借用错)`。7 条规则的现状如下（以 CASES 用例名为准，每条包含放行和报错两个方向的样本；规则语义以 [src/compiler/checker.cr](../../src/compiler/checker.cr) 的 check_borrow 等为准）：
  1. immutable borrow then use original
  2. mutable borrow then use original
  3. multiple immutable borrows allowed
  4. immutable then mutable borrow
  5. borrow released after block scope exit
  6. normal copy use
  7. mutable then immutable borrow
- selfhost impl/编译（test_impl.py）：CHECK_CASES 添加 `(名称, 源码)`（check 必须通过）；NATIVE_CASES 添加 `(名称, 源码, 期望退出码)`（运行原生 ELF）。
- suite 集成：新建 `tests/suite/xxx_test.cr`，`fn main() -> int` 的正常路径 `return 0`；崩溃或非零退出为失败。注意不要使用 `*_mini*.cr` 命名（CI 会跳过）。

## 三、回归流程

快速检查（改动小或未修改编译器核心）：`./build/corec check src/compiler`（对编译器全部源码做整目录类型检查，不触发 ELF 后端）。

自举三阶段和字节一致验证（src/ci/run.sh 的 full-bootstrap job 实录）：

```bash
python3 build_selfhost_native.py                                        # Stage 0：Python bootstrap 生成 build/corec(+corearch/corelsp)
./build/corec build src/compiler/main.cr -o /tmp/corec2 --static -O 0   # Stage 1：corec 编译编译器，生成 corec2
cp ./build/corearch /tmp/corearch && chmod +x /tmp/corec2 /tmp/corearch
/tmp/corec2 build src/compiler/main.cr -o /tmp/corec3 --static -O 0     # Stage 2：corec2 编译编译器，生成 corec3
cmp /tmp/corec2 /tmp/corec3                                             # 检查：两代编译器输出逐字节一致
```

说明：固定使用 `-O 0`（CI 实录；O1 现状见第四节）。生成 corec3 后运行一次 `--help` 做基本检查。后端独立回归（ELF 后端/自举 corearch）：`python3 tests/selfhost/test_backend_bootstrap.py`（三阶段自举 corearch 并比对，内置 nice 和超时）。

CI job 列表（本地复现命令为 `CI_JOB_NAME=<job> src/ci/run.sh`；run.sh 已内置 `ulimit -c 0`）：

| CI_JOB_NAME | 内容 |
|---|---|
| check | build_selfhost + `./build/corec check src/compiler` |
| bootstrap-tests | 三个 bootstrap 套件（第一节） |
| selfhost-tests | 构建 + test_compile / test_impl / test_borrow / test_pointer_safety |
| suite | 构建 + run_suite（逐 .cr 编译运行） |
| full-bootstrap | 三阶段自举 + cmp 字节一致 |

CPU 限制：长时间构建或测试（无人值守或共享机器）建议使用 `cpulimit -l 10` 或 `nice -n 19`，防止风扇噪音和卡顿。注：CLAUDE.md 的硬性规则 #6 约束的是 AI 会话，人类交互式短任务不必限制。

```bash
nice -n 19 python3 build_selfhost_native.py
nice -n 19 python3 tests/selfhost/test_compile.py
# 或安装 cpulimit 后包住整条命令：cpulimit -l 10（等效）
```

CI 环境没有此约束；本地桌面环境必须遵守。本地复现 CI job 时也要在命令前加限制：在 `nice -n 19 src/ci/run.sh` 的场景下，使用 `nice -n 19 env CI_JOB_NAME=full-bootstrap src/ci/run.sh`。

## 四、常见失败定位

### tokenizer 死循环（自举第二代起）

- 现象：`build/corec build` 挂起且无输出（或 CPU 忙等）。
- 机理：约 9 个全局变量（`g_tok_cap`/`g_tokens`/`g_str_count`/`g_line`/`g_source_len`/`g_x86_is_global`/`g_x86_global_cap`/`g_str_hash`/`g_error_count`）未注册到 `g_ir_globals` 时，对它们的赋值会被丢弃且不报错，tokenize 循环中的推进变量不再增长。全文见 [CLAUDE.md Known Issues](../../CLAUDE.md)。
- 排查：先确认停滞发生在 tokenize（在 tokenizer 循环内临时打印 `g_pos`/`g_tok_cap`，观察是否递增）；新增全局变量时核对注册路径（注册点以源码为准）。现有规避方法：tokenizer 参数化 `tokenize(_src)`，消除 `g_source` 全局依赖；残留问题仍未根治。

### O1 崩溃（--opt-level 1）

- 现象：自举编译大函数时崩溃（pass_cse 与 alloc_registers 元数据交互异常）。
- 处理：回归和 CI 固定 O0（第三节实录）；定位优化问题时单独用 `-O 1` 复现，并二分到函数；相关文件：[src/compiler/opt.cr](../../src/compiler/opt.cr)（pass_cse/alloc_registers）、pass.cr。

### ELF 字节不一致或产物错乱

- 先检查指令编码层，再怀疑逻辑：[src/arch/x86_64/](../../src/arch/x86_64/) 下的 instr.cr（指令发射编码）、sizes.cr（`sz_*` 字节数预估，label 前向引用依赖它）；[src/format/elf/](../../src/format/elf/) 下的 resolve.cr（label 解析后的填充）。修改指令发射时必须同步修改 instr 和 sizes 两处。
- 比对方法：O0 下 corec2 与 corec3 不一致，说明编译不自洽。排除输出差异（路径或环境）后缩小到最小复现，修复后先运行 suite，再运行 full-bootstrap。

### trap 类测试挂起（桌面环境）

- 机理：core_pattern 为 systemd-coredump 管道，trap 程序（SIGILL）写 core dump 时发生拥堵，进程挂起。
- 处理：先设置 `ulimit -c 0`，或在测试内设置 `RLIMIT_CORE=0`（src/ci/run.sh 已内置）；根治方向见 [TODO.md](../../TODO.md)（图推导边界判定 pass：把检查前移到编译期，缩小运行时的 trap 范围）。
