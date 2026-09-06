# 测试与回归操作手册（testing）

> 定位：受众 = maintainers；状态 = active；真源 = [tests/](../../tests/) 与 [src/ci/run.sh](../../src/ci/run.sh)（命令以仓库现状为准，有出入先改源码注释/本文）。
> 仓库地图/构建/分支见 [onboarding.md](onboarding.md)；命令速览另见 [CLAUDE.md](../../CLAUDE.md) Build & Test 段；未竟项见 [TODO.md](../../TODO.md)。

## 一、三套测试的定位与跑法

### tests/bootstrap/ —— Python bootstrap 管线回归

定位：纯 Python 驱动，import `bootstrap/corec` 模块走全管线（lex → parse → resolve → desugar → typecheck → ir_gen）后解释执行，比较结果；诊断类比较错误数。**不依赖 build/corec**。

核心文件：test_pipeline.py（核心管线：词法/字面量/表达式/控制流）、test_borrow.py（借用检查错误检测）、test_generics.py（泛型函数 + 泛型结构体）；同目录 test_apx_tag/test_dex_arith/test_dex_type/test_modules 等（以目录实况为准）。

跑法（仓库根，无需先构建）：

```bash
python3 tests/bootstrap/test_pipeline.py
python3 tests/bootstrap/test_borrow.py
python3 tests/bootstrap/test_generics.py
```

### tests/selfhost/ —— 自举/原生编译器回归

定位：驱动原生 `build/corec` 子进程为主；test_compile.py 另演示「拼接 src/compiler + src/stdlib 源 → Python bootstrap 全管线编译 → 解释器执行」。**前置**：先跑 `python3 build_selfhost_native.py`——build/corec 缺失时脚本直接报 `[FAIL] missing native compiler`。

核心三件：

- test_compile.py — 自举管线冒烟（编译器源拼接编译 + 示例程序执行比对）
- test_impl.py — impl/方法接收者/self 字段：CHECK_CASES（check 必须通过）+ NATIVE_CASES（编译成 ELF 运行，断言退出码）
- test_borrow.py — 借用检查 7 规则（分类见 §二）；用例 = (名称, 内联源码, 期望是否报借用错)，写临时 .cr 跑 `corec check`。契约：期望诊断 → 退出码 1、无诊断 → 0（check 命令「诊断即失败」；F19 修复后断言随契约更新，见文件内注释）

跑法：

```bash
python3 tests/selfhost/test_compile.py
python3 tests/selfhost/test_impl.py
python3 tests/selfhost/test_borrow.py
```

同目录其余（test_backend_bootstrap / test_lsp / test_pointer_safety / test_native_* / test_region_cfg 等）同一模式、以目录实况为准；test_backend_bootstrap.py 已内置 `nice -n 19` 与 180s 超时。

### tests/suite/ —— 集成用例（.cr 源码）

定位：端到端集成——tests/suite/*.cr 逐个经 `./build/corec build` 编译成 ELF 并运行，**main 返回 0 为通过**；`*_mini*.cr` 视为开发草稿，CI 跳过。

跑法（单文件）：

```bash
./build/corec build tests/suite/at_test.cr -o /tmp/core_suite_bin --static
chmod +x /tmp/core_suite_bin && /tmp/core_suite_bin
```

全量走 CI job：`CI_JOB_NAME=suite src/ci/run.sh`（job 一览见 §三）。

## 二、怎么加用例

通用形态：文件头部 helper + 用例列表或内联调用 + 结尾汇总（passed/failed → sys.exit）。加完先跑单文件，再跑该套件全量；动了编译器本体还要走 §三 full-bootstrap。

- **bootstrap 管线类**：模块体直接调 `run_test(name, src, expected)`（int 结果）或 `run_test_raw(name, src, expected)`（string/float）：
  ```python
  run_test("add", "fn add(a: int, b: int) -> int { return a + b; } fn main() -> int { return add(2, 3); }", 5)
  ```
  借用错误类用 `check_errors(src, desc, expect_errors)`（断言错误数有无）。
- **selfhost 借用检查**（test_borrow.py）：向 `CASES` 加元组 `(名称, 内联源码, 期望是否报借用错)`。7 规则现状（以 CASES 用例名为准，每条含放行/报错两个方向的样本；规则语义真源 = [src/compiler/checker.cr](../../src/compiler/checker.cr) 的 check_borrow 等）：
  1. immutable borrow then use original
  2. mutable borrow then use original
  3. multiple immutable borrows allowed
  4. immutable then mutable borrow
  5. borrow released after block scope exit
  6. normal copy use
  7. mutable then immutable borrow
- **selfhost impl/编译**（test_impl.py）：CHECK_CASES 加 `(名称, 源码)`（check 须过）；NATIVE_CASES 加 `(名称, 源码, 期望退出码)`（原生 ELF 运行）。
- **suite 集成**：新建 `tests/suite/xxx_test.cr`，`fn main() -> int` 正常路径 `return 0`；崩溃/非零退出 = 失败。注意别用 `*_mini*.cr` 命名（CI 跳过）。

## 三、回归流程

**快检**（改动小/未动编译器核心）：`./build/corec check src/compiler`（编译器全源整目录类型检查，不触发 ELF 后端）。

**自举三阶段 + 字节一致验证**（src/ci/run.sh full-bootstrap job 实录）：

```bash
python3 build_selfhost_native.py                                        # Stage 0：Python bootstrap → build/corec(+corearch/corelsp)
./build/corec build src/compiler/main.cr -o /tmp/corec2 --static -O 0   # Stage 1：corec 编译编译器 → corec2
cp ./build/corearch /tmp/corearch && chmod +x /tmp/corec2 /tmp/corearch
/tmp/corec2 build src/compiler/main.cr -o /tmp/corec3 --static -O 0     # Stage 2：corec2 编译编译器 → corec3
cmp /tmp/corec2 /tmp/corec3                                             # 判据：两代编译器输出逐字节一致
```

说明：固定 `-O 0`（CI 实录；O1 现状见 §四）；corec3 生成后做一次 `--help` 冒烟。后端独立回归（ELF 后端/自举 corearch）：`python3 tests/selfhost/test_backend_bootstrap.py`（三阶段自举 corearch 并比对，内置 nice + 超时）。

**CI job 一览**（本地复现 = `CI_JOB_NAME=<job> src/ci/run.sh`；run.sh 已内置 `ulimit -c 0`）：

| CI_JOB_NAME | 内容 |
|---|---|
| check | build_selfhost + `./build/corec check src/compiler` |
| bootstrap-tests | 三个 bootstrap 套件（§一） |
| selfhost-tests | 构建 + test_compile / test_impl / test_borrow / test_pointer_safety |
| suite | 构建 + run_suite（逐 .cr 编译运行） |
| full-bootstrap | 三阶段自举 + cmp 字节一致 |

**CPU 限制**:长时间构建/测试任务(无人值守/共享机器)建议 `cpulimit -l 10` 或 `nice -n 19`,防风扇噪音与卡顿(注:CLAUDE.md 铁律 #6 约束的是 AI 会话;人类交互式短任务不必限):

```bash
nice -n 19 python3 build_selfhost_native.py
nice -n 19 python3 tests/selfhost/test_compile.py
# 或安装 cpulimit 后整条命令包 cpulimit -l 10（等效）
```

CI 环境无此约束；本地桌面必守。CI job 的本地复现同样要先包一层：`nice -n 19 src/ci/run.sh` 场景下用 `nice -n 19 env CI_JOB_NAME=full-bootstrap src/ci/run.sh`。

## 四、常见失败定位

### tokenizer 死循环（自举第二代起）

- 症状：`build/corec build` 挂起无输出（或 CPU 空转）。
- 机理：约 9 个全局变量（`g_tok_cap`/`g_tokens`/`g_str_count`/`g_line`/`g_source_len`/`g_x86_is_global`/`g_x86_global_cap`/`g_str_hash`/`g_error_count`）未被注册到 `g_ir_globals` 时，对其赋值被静默丢弃 → tokenize 循环推进变量不增长。全文见 [CLAUDE.md Known Issues](../../CLAUDE.md)。
- 排查：先确认卡点确在 tokenize（tokenizer 循环内临时打印 `g_pos`/`g_tok_cap` 是否递增）；新增全局变量时核对注册链路（注册点以源码为准）。历史规避：tokenizer 参数化 `tokenize(_src)` 消除 `g_source` 全局依赖（PR #9），残留项待根治。

### O1 崩溃（--opt-level 1）

- 症状：自举编译大函数时崩溃（pass_cse 与 alloc_registers 元数据交互异常）。
- 处理：回归/CI 固定 O0（§三实录）；定位优化问题时单独 `-O 1` 复现并二分到函数；相关文件：[src/compiler/opt.cr](../../src/compiler/opt.cr)（pass_cse/alloc_registers）、pass.cr。

### ELF 字节不一致或产物错乱

- 先查指令编码层再怀疑逻辑：[src/arch/linux/ld/](../../src/arch/linux/ld/) 下 instr.cr（指令发射编码）、sizes.cr（`sz_*` 字节数预估——label 前向引用依赖它）、resolve.cr（label 解析后置填充）。改指令发射必须同步 instr 与 sizes 两处。
- 比对法：O0 下 corec2 ≠ corec3 = 编译不自洽；排除输出差异（路径/环境）后缩到最小复现，修完先 suite 后 full-bootstrap。

### trap 类测试挂起（桌面环境）

- 机理：core_pattern = systemd-coredump 管道，trap 程序（SIGILL）core dump 写入拥堵时进程挂起。
- 处理：先 `ulimit -c 0` 或测试内设 `RLIMIT_CORE=0`（src/ci/run.sh 已内置）；根治方向见 [TODO.md](../../TODO.md)（图推导边界判定 pass——检查前移编译期，缩小运行时 trap 面）。
