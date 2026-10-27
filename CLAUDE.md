# CLAUDE.md

本文件为 Claude Code 提供在本仓库中处理代码时的指引。

## 硬性规则（Hard Rules）

这些规则不可违反，除非用户明确另有指示。

1. 不许绕过问题，找到 root cause 直接修复。
2. 禁止使用 `git`。版本控制统一使用 `jj`，所有版本控制操作都用 `jj` 命令。
3. 文件永久不允许还原。还原必须经过用户明确许可。
4. 直接解决问题，不变通、不绕过、不掩盖。
5. 除非彻底不可修复，充分验证后才可提替代方案。
6. 编译任务限制 CPU。任何长时间编译或测试任务必须用 `cpulimit -l 10` 或 `nice -n 19` 限制 CPU 占用不超过 10%，避免风扇噪音影响用户体验。

违反这些规则的后果：用户会非常愤怒，并且不再信任你。

## Project Overview

Core 是一门新的通用编程语言，设计取向是「语义保留」（semantic preservation）。它的 IR 在编译全过程中保留完整的类型和语义信息，供形式验证工具直接使用。

编译器有两个：

- Python bootstrap（`bootstrap/corec/`）：初始编译器，用 Python 编写，用于构建自举编译器。
- 自举编译器（`src/compiler/`）：用 Core 自身编写的 Core 编译器，由 Python bootstrap 构建。

## 版本控制流程（GitFlow）

- 版本控制统一使用 `jj`（硬性规则 #2，hook 自动拦截 git）。分支模型分三级：feature、develop、main。
- main 是正式版线，只有维护者 DslsDZC 可以合入（ruleset：update 规则，无管理员绕过）。
- develop 是集成分支，日常 PR 的目标（ruleset：PR 通道、审阶段、merge queue、CI 检查要求）。
- 日常开发（feature 合入 develop）：

```bash
jj bookmark create feature/xxx        # 每个改动独立分支（base = develop）
# ...开发提交（SSH 自动签名）...
jj git push -b feature/xxx
gh pr create --base develop --fill    # PR 指向 develop（"不能指向 main"）
# 审查通过且 CI 通过后，手动 squash 合入 develop（merge queue 因免费计划降级，见 spec 的 3.3 节）
jj git fetch && jj bookmark move develop -r develop@origin
```

- 发布（develop 合入 main，仅维护者）：

```bash
jj git push -b develop
gh pr create --base main --fill       # required reviewers = 你，你批准后手动 squash 合入
```

- 合入 main 后（发布线）：

```bash
jj git fetch && jj bookmark move main -r main@origin
```

## Build & Test Commands

```bash
# 构建自举编译器（从 Python bootstrap 到原生二进制）
python3 build_selfhost_native.py       # 产出三个：build/corec、build/corearch、build/corelsp

# 自举前端：.cr 生成 .ccr/.cir
./build/corec build FILE.cr -o OUTPUT --static

# 自举后端：.ccr 生成 ELF 二进制（由 corec 自动调用）
./build/corearch FILE.ccr --elf --static -o OUTPUT

# 只做类型检查
./build/corec check FILE.cr

# 解释执行（内联代码）
./build/corec run 'fn main()->int{return 42;}'

# 数据流图 dump
./build/corec cir FILE.cr

# 格形态 IR dump（v9 = 段表 8 段：STR/SYM/NOD/ENT/REG/EDG + TYPE(7)/IFACE(8)；
# 版本定义以 src/compiler/ccr_io.cr::CCR_VERSION 为准，load 校验 ==9 且拒收 v8 及更早）
./build/corec ccr FILE.cr

# Project mode：目录（Core.toml + main.cr + _import.cr）整体构建
./build/corec build src/targets/x86_64-linux -o OUT --static

# 增量缓存和引擎自测通道（判定面自测，非构建）
./build/corec clean-cache
./build/corec selftest-types           # 类型项引擎用例表（400+ 例）
./build/corec selftest-purity          # 真纯度计算自测通道
```

构建脚本有两个结构性事实（只有读 `build_selfhost_native.py` 才能看到，不要根据文件名推断）：

1. 清单是判断单元归属的依据。脚本按 `common_files` / `hit_engine_files` / `kernel_files` /
   `arch_x86_64_files` / `format_elf_files` / `os_linux_files` / `backend_support_files` /
   `corec_files` / `corelsp_files` / `x86_linux_target_files` 逐条列出全路径，然后 concat 成
   一个扁平编译单元（逐文件去掉 `import` 行）。段内和段间的相对顺序决定行为（平铺单元的声明序和
   全局序），搬迁文件时必须保持顺序。因此，判断某个文件属于谁、是否参与编译，以这个脚本为准，
   不以目录位置或 `_import.cr` 为准。
2. 两道构建检查（根据 ld 单元不报错地缺陷这一问题增加）。第一道是 `guard_manifest`，检查清单中的
   文件是否存在；第二道是 `guard_build_log`，检查本阶段日志中的 `error[` 计数和未定义符号计数
   必须为 0。project-mode 路径（`corec build <dir>`）不经过这两道检查，对应的检查是
   `tests/selfhost/test_backend_bootstrap.py` 的 `run_checked`（rc=0 时仍扫描 stdout 和 stderr
   中的 `error[`）。两处检查互为补充，改一处必须同步另一处。

### 本地复现 CI（首选入口，与 CI 运行同一条命令）

CI 和本地使用同一条命令，唯一来源是 `src/ci/run.sh`（按 `CI_JOB_NAME` 的 case 分发，每一档都带
计数说明）。workflow 只负责事件分层和 matrix 派发（`.github/workflows/core-ci.yml`）。PR 层包括
`check`、`bootstrap-tests`、`selfhost-tests`；完整层包括 `suite`、`full-bootstrap`（merge queue
因免费计划降级，完整层目前通过 `workflow_dispatch` 手动派发）。

```bash
CI_JOB_NAME=check src/ci/run.sh             # 构建 + ./build/corec check src/compiler（最快）
CI_JOB_NAME=bootstrap-tests src/ci/run.sh   # 纯 Python：bootstrap 套件、harness 自动检查、canary 实现方式负例
CI_JOB_NAME=selfhost-tests src/ci/run.sh    # 耗时最长：构建，加 40 多个套件和检查调用（含 canary）
CI_JOB_NAME=suite src/ci/run.sh             # tests/suite/*.cr 逐个编译成 ELF 并运行（rc=0 为过）
CI_JOB_NAME=full-bootstrap src/ci/run.sh    # 三阶段自举：corec2 与 corec3 的 cmp 结果必须逐字节相同
```

> 判断标准：修改 `src/compiler/**` 时，至少运行 `selfhost-tests` 和 `full-bootstrap`；只改文档或注释时，`check` 足够。
> 长编译遵守硬性规则 #6。

### Test suites

`tests/` 共有 8 个目录，职责不同。只有前三个是测试套件：

| 目录 | 形态 | 说明 |
|------|------|------|
| `bootstrap/` | 7 个 `.py` | 纯 Python 驱动，import `bootstrap/corec` 走全管线后解释执行。不需要构建 |
| `selfhost/` | 59 个 `.py` | 驱动原生 `build/corec` 子进程。前置条件：先运行 `build_selfhost_native.py`（缺失时报 `[FAIL] missing native compiler`） |
| `suite/` | `.cr` 源码 | 端到端集成：逐个编译成 ELF 并运行，main 返回 0 为通过；`*_mini*.cr` 被 CI 跳过 |
| `harness/` | 5 个 `.py` | 元测试，验证检查本身是否有效。覆盖 git 拦截、CI 接入点覆盖、检查突变自证、canary 实现方式负例、TODO 标识迁移 |
| `probes/` | 29 档 `.cr` | 行为探针语料（以 `check` 面负例为主），不是编译单元；runner = `tools/baseline/probes_run.sh` |
| `fixtures/` | 夹具 | 检查项自带的夹具（如 `so_index/` 两态索引） |
| `kernel/` | 语料 + 驱动 | McTT 到 Core 内核差分测试；需要仓库外的 OCaml 参考实现 `~/mctt`（见 `tools/mctt_ref/`），因此不进入 CI |
| `hit/` | `.cr` + `.ccr` | HIT 表快速验证语料 |

运行单个套件：直接运行对应的 `.py`。多数套件不支持过滤参数，用例表写在文件内的
`CASES` / `CHECK_CASES` 列表里，因此运行单个用例需要修改列表或临时注释。

```bash
python3 tests/bootstrap/test_pipeline.py   # 核心管线：lex、parse、check、ir、interp
python3 tests/selfhost/test_impl.py        # Impl/method 测试
python3 tests/selfhost/test_borrow.py      # 自举借用检查器（7 条规则）
```
> 清单以什么为准（2026-09-16 文档审计修订）：上面三行只是入口示例，不是全集。
> `tests/selfhost/test_*.py` 实际有 50 多个套件，`tests/bootstrap/*.py` 有 7 个套件。
> 套件全集以 `ls tests/selfhost/test_*.py tests/bootstrap/*.py` 为准，CI 接入点以 `src/ci/run.sh`
> 的 `selfhost-tests` / `bootstrap-tests` job 为准（每一档都有接入点和计数说明）。完整枚举见
> `src/ci/run.sh`（每档 rc 汇总）和 `docs/archive/sdd/` 的各阶段报告。

`tests/suite/` 的集成测试是 `.cr` 源文件，通过 `./build/corec` 运行。

行为探针语料（`tests/probes/`，29 档，以 `check` 面负例为主，不是编译单元）和回归测试的配置与步骤
（`tools/baseline/`：固定基线重建、sha 允许清单、两条 runner）见 `tools/baseline/REBUILD.md`。判定面回归检查
由四项组成：固定基线同源对拍、行为探针、突变控制和三态纪律（R2 P6 Task 1 起；影子通道已下线，
不得引用其计数）。

修改单个 suite 语料：

```bash
./build/corec build tests/suite/at_test.cr -o /tmp/bin --static && chmod +x /tmp/bin && /tmp/bin
```

> 新增测试文件必须同时登记，否则 CI 会失败（`test_ci_hook_coverage.py` 自动判定）：
> 新建 `tests/{selfhost,bootstrap,harness}/*.py` 后，要在 `src/ci/run.sh` 加接入点，
> 或者在 `tests/harness/ci_hook_allowlist.txt` 逐条登记一行理由（`路径<TAB>理由`）。
> 两个方向都会检查：已挂或已删的条目留在允许清单里也会 FAIL。这项检查存在的原因见 `run.sh:71-79`
> （曾因「自称已挂而 run.sh 零命中」导致 `error[N06]` 跨 5 个任务漏检 33 次）。

### 检查集合（回归检查四要素 + canary 检查）

判定面回归检查包含四项：固定基线同源对拍、行为探针、突变控制、三态纪律（R2 P6 Task 1 起；
影子通道已下线，不得引用其计数或摘要）。

- 固定基线：二进制不入库，由 `bash tools/baseline/rebuild.sh <outdir>` 从 pinned revision
  重建。重建步骤和三份 sha 允许清单见 `tools/baseline/REBUILD.md`；对拍 runner 是
  `tools/baseline/parity_run.sh`（逐档执行 `clean-cache`）。CI 内不运行，因为浅检出没有 jj。
- 行为探针：语料在 `tests/probes/`（29 档，不是编译单元），加上行为套件；runner 是
  `tools/baseline/probes_run.sh`。
- 突变控制：改坏派生面后，探针和对拍必须失败（`tests/harness/test_criteria_mutations.py`
  是这项要求的自动检查形式）。
- 三态纪律：引擎返回 -1 时按 ICE04 硬错处理（`main.cr` 硬名单）。

ELF 基准和 `.ccr` 四项检查（CI `selfhost-tests` 内，`bash tools/baseline/canary_check.sh` +
`tests/harness/test_canary_carrier.py --require-compiler`）：基准值的唯一来源是
`tools/baseline/canary_values.tsv`。检查规则分两类。ELF 基准检查要求生成结果不变；值发生变化表示
超出范围，应停止并上报。`.ccr` 四项检查格式和内容形状；值变化不一定是回归，但需要说明原因，在同一组
更新基准值并保留旧值。
> 注：更新基准值的规则：运行结果不一致时先查明原因。原因无法确定时按回归处理，停止并上报。
> 不要修改值表去匹配输出。
> 详见 `docs/superpowers/plans/2026-09-16-criteria-carrier.md` 的「更新基准值的规则」。另注：`.ccr` 四项
> 以空缓存状态的值为基准，并且 `.so` 索引方面需要环境归一化（检查脚本已将 `HOME` 固定为采集目录内的
> 空 `home/`）。

## Architecture

### Python Bootstrap Compiler

bootstrap 是 `bootstrap/corec/` 下的纯 Python 单遍管线，不依赖外部库：

```
bootstrap/corec/syntax/ast.py          AST 节点 dataclass 定义
bootstrap/corec/syntax/tokens.py       Token 和 TokenKind 定义
bootstrap/corec/syntax/keywords.py     关键字列表

bootstrap/corec/frontend/lexer.py      对 .cr 源码做词法分析
bootstrap/corec/frontend/parser.py     递归下降 parser，输出 AST
bootstrap/corec/frontend/name_resolver.py 声明收集和名称解析
bootstrap/corec/frontend/desugar.py    把 match 展开为 if-else 链
bootstrap/corec/frontend/type_checker.py 类型推断、类型检查和借用检查
bootstrap/corec/frontend/ir_gen.py     AST 到 Core IR

bootstrap/corec/ir/cir.py              数据流图 IR 定义
bootstrap/corec/ir/ccr.py              格形态 IR（注：该文件实际不存在。.ccr 只由自举编译器的 ccr_io.cr 读写；现行格式是 v9 八段段表（NOD 40B），见 specs/2026-09-09-lattice-ir-v7-format.md；v6 版历史设计见 archive/2026-09-05-lattice-ir-v6-format.md）
bootstrap/corec/ir/base.py             IRNode 基类、IRVar、VarKind
bootstrap/corec/ir/symbol_table.py     作用域符号表

bootstrap/corec/backend/interpreter.py 直接执行 IR（Python eval）
bootstrap/corec/backend/x86_64_stack_asm.py x86-64 栈式代码生成
bootstrap/corec/backend/arm64_asm.py   ARM64 代码生成
bootstrap/corec/utils/module_loader.py import 解析
```

管线顺序：Lexer、Parser、NameResolver、MatchDesugarer、TypeChecker、IRGen、Backend。

### Self-Hosted Compiler

自举编译器用 Core 编写，位于 `src/compiler/`。它由 `build_selfhost_native.py` 构建，该脚本用
Python bootstrap 编译所有 `src/compiler/*.cr` 文件。

```
src/compiler/     （共 38 个 .cr；2026-09-16 文档审计修订：原清单只列 20 个，R2 各阶段新增的
                    类型引擎、实现方式、分析文件全部缺失。修订依据是 `ls src/compiler/*.cr`（38 个）
                    逐个手工加注；单元归属按 `build_selfhost_native.py` 的 corec_files(45)/
                    corelsp_files(31)/backend_support_files(9)/common_files(9) 清单，
                    按全路径核定）
├── ast.cr          AST 节点种类、IR 操作码、类型常量（common+corec+corelsp）
├── ccr_io.cr       .ccr 二进制序列化和反序列化（backend_support+corec）
├── ccr_types.cr    TYPE(7)/IFACE(8) 两段内容构造（仅 corec；D18 解耦）
├── checker.cr      类型检查、借用检查、声明收集（corec+corelsp）
├── cir_cache.cr    函数级 `.cir` 快照缓存 save/load（corec）
├── corearch.cr     后端入口（corearch 二进制）（backend_support）
├── dataflow.cr     HDFG 构建：DFNode/DFEdge（含 state edges）、嵌套 region（SG_IF/LOOP/FOR/FLOW/UNSAFE）、g_df_node_region 显式映射、DOT（corec）
├── diag.cr         编译器诊断（corec+corelsp；含 fail-closed 豁免表 `diag_gate_exempt`）
├── dump.cr         调试 dump 工具（corec）
├── dyn_arr.cr      动态数组扩容辅助函数、字符串驻留（common+corec+corelsp）
├── elf.cr          未被引用的文件（566 行、零 importer、三面清单都没有；TODO #2026-09-10-3；不要引用）
├── entry.cr        project-mode 入口 shim（`fn main() { return compiler_main(); }`）
├── ext_mgr.cr      编译器扩展管理器：插件注册表和钩子调度（corec）
├── ext_safety.cr   运行时安全检查插件（通过 ext_mgr 注册到编译钩子）（corec）
├── globals.cr      所有全局变量声明（common+corec+corelsp）
├── iface_axis.cr   iface 满足判定簇和 `iface_kind_of`（R2 P4 T0 引擎核纯化拆分；仅 corec 主机）
├── iface_registry.cr 本质条目表（原生条目）和 `iface_*` 查询 API（corec+corelsp）
├── _import.cr      src/compiler 全文件共享导入（`load_imports` 直读；不在 concat 清单）
├── interp.cr       IR 解释器（用于 `run` 命令）（corec）
├── ir_gen.cr       AST 到 IR 指令生成（corec）
├── lexer.cr        词法分析器（使用整数访问字符，不做字符串分配）（corec+corelsp）
├── main.cr         CLI 和管线编排（corec 二进制）（corec）
├── module.cr       import 解析、文件 ID 管理（corec+corelsp）
├── monomorph.cr    泛型单态化：实例缓存和 AST 特化（corec）
├── opt.cr          优化 pass（CSE、寄存器分配、栈槽复用）（corec）
├── parser.cr       递归下降 parser，输出扁平 AST（corec+corelsp）
├── pass.cr         AST 级优化（常量折叠）（corec）
├── project.cr      Core.toml 项目配置加载（corec）
├── provenance_verify.cr ProvenanceVerify pass，校验 DEREF 偏移是否在 allocation size 内（corec；`main.cr:614-615` 接线）
├── ptr_analysis.cr PointerAnalysis pass，过程间 Andersen 式约束求解（corec）
├── purity_selftest.cr 真纯度计算自测通道（`corec selftest-purity`）（corec）
├── regalloc-consistency.cr 分配器（CAG 贪心放置）逻辑正确性契约，文档实现方式，不进入任何清单
├── region_check.cr RegionCheck pass，DEREF 目标必须在活子图内（corec）
├── ty_shadow.cr    类型判定衔接和类型项构造（R2 P2a 起；P5 T5 后并行的对照实现已下线，`sh_` 是历史前缀）（corec+corelsp）
├── type_engine.cr  R2 P0 类型项判定引擎（语义包含；spec 的 1/3 节）（backend_support+corec+corelsp）
├── type_selftest.cr 类型引擎判定用例表 + `corec selftest-types`（corec）
└── type_terms.cr   R2 P0 类型项表（集合语义 DAG）（backend_support+corec+corelsp）
```

### 其他 src 子树（不在 `src/compiler/` 内，容易遗漏）

```
src/lattice/ent_kernel.cr 语义内核（与范式无关），corec 和 corearch 双 concat 共享（`kernel_files`）
src/arch/hit/             HIT 表引擎（hit.cr + lower_to_core.cr），与架构轴的表数据 `core-x86.toml` 分工
src/kernel/               McTT 到 Core 验证内核移植（bytes/term_io/mctt/subst/nbe/subtype/check/kernel_main）
                          由根目录 `build_kernel.py` 单独构建出 `build/kernel`（复用 bootstrap 管线的
                          `concat`/`compile_and_assemble`，不在 build_selfhost_native.py 的任何清单内）
                          差分语料在 `tests/kernel/`（需要仓库外的 OCaml 参考实现 `~/mctt`，不进入 CI）
src/lsp/                  corelsp：json.cr、rpc.cr、lsp.cr、analysis.cr、main.cr（+ `_import.cr`）
                          由自举脚本的 `corelsp_files` 清单构建成 `build/corelsp`
src/scheduler/            sched.s + example.cr（调度器汇编侧原型）
```

### Backend（x86 实例化三轴布局：架构、格式、OS；`src/arch/linux/ld/` 已退役）

`corearch` 直接输出 x86-64 ELF 二进制。三轴目录是跨轴 import 的唯一通道（`module.cr` 回退链），
组合根是 `src/targets/x86_64-linux/`（按 target triple 命名）：

```
src/arch/x86_64/          regalloc.cr（CAG 寄存器分配）、sizes.cr（指令字节尺寸单源）、instr.cr（指令编码 REX/ModRM/SIB + 全 IR opcode 发射 + e2_* 原语）、frame.cr（帧布局、序言和尾声，帧公式单入口 pf_frame_size）、tag2l.cr（int 多字 M1 tag/2L 编码族）、core-x86.toml（HIT 表数据）
src/format/elf/           elf.cr（ELF 头、phdr、段发射 + elf_gen）、resolve.cr（标签解析 res_labels）、ld.cr（动态链接 PLT/GOT/.so 装载）
src/os/linux/             entry.cr（_start 发射序 emit_start/emit_start_size）、callseq.cr（SysV AMD64 参数、栈、返回、调用序列）、syscall.cr（syscall3/4 内置体：rax 号 + rdi/rsi/rdx(/r10) 参数序）（三项均在波 1 完成：Task 2/5/6）
src/targets/x86_64-linux/ 组合根（target triple）：main.cr + _import.cr + Core.toml（`corec build <dir>` 的 project-mode 入口）
```

### Standard Library (`src/stdlib/`)

```
src/stdlib/       （共 19 个 .cr；2026-09-16 文档审计修订：原清单只列 8 个，缺 11 个）
├── arena.cr        子图 arena（函数、loop、for、unsafe 各一个；分配器部分已实现）
├── assert.cr       运行时检查系统（assert!/debug_assert!/unreachable!/todo! 风格）
├── chan.cr         通道运行时（单产单消边；`sched_init` 自动初始化）
├── cli.cr          CLI 参数解析
├── collections.cr  集合类型（stub）
├── dex.cr          dex 定点方案（执行时定稿 2026-08-16）
├── fmt.cr          字符串格式化（int_str、chr、str_eq、str_hash 等）
├── goroutine.cr    goroutine 入口包装地址（`goroutine_entry_wrapper`）
├── hotpatch.cr     Hotpatch 运行时：配置文件管理、在途请求跟踪
├── io.cr           I/O（print、println、read_file、write_file）
├── math.cr         数学函数（stub）
├── os.cr           OS 工具（get_env）
├── panic.cr        Rust 风格 panic handler（仅开发用）
├── sched.cr        调度器核心（G0 = 主线程；协作切换，单 M）
├── scheduler.cr    `go node` 对应独立 Fiber 加 Arena 的轮转调度
├── toml.cr         TOML 配置解析
├── trace.cr        运行时诊断（RUST_BACKTRACE/dbg! 风格）
├── variadic.cr     运行时变参工具
├── _import.cr      stdlib 模块的共享导入
├── 平台桥抽象设计：I/O 流、随机、哈希、时钟（语义接口和后端实现，程序 IO = 流转导器）。设计已定案，待实现（docs/superpowers/specs/2026-08-16-platform-abstract-design.md）
└── 注：`assert.cr`/`collections.cr`/`dex.cr`/`math.cr`/`scheduler.cr`/`trace.cr`/`variadic.cr`
        不在 build_selfhost_native.py 的任何清单（corec_files/corelsp_files/backend_support_files 等）。
        单元归属以该脚本按全路径核定的清单为准（2026-09-16 审计实核）
```

### Runtime (`src/runtime/`)

```
src/runtime/
├── rt.s    汇编：_start、bump 分配器、__builtin_* 函数
└── rt.cr   Core 运行时全局变量（g_rt_argc、g_rt_argv_ptr）
```

### Key design points (self-hosted)

- 所有数组都是动态字节缓冲区（`string` 加扩容函数），没有 `MAX_*` 上限。
- 扁平 AST：每个节点是 `{kind, a, b, c, int_val, type_val, data, line, col}`，存放在 `g_ast`。
- 扁平 IR：每条指令是 `{opcode, dest, src1, src2, src3, type_kind}`，存放在 `g_ir_instrs`。
- 检查器运行两遍：第一遍注册 struct、enum、函数声明，第二遍检查函数体类型。
- 词法分析器使用整数字符编码，热路径中不做 `get_char` 字符串分配。
- 全局变量是 IR 变量，索引记录在 `g_ir_globals` 和 `g_x86_is_global` 中，供 ELF 后端使用。
- ELF 后端对全局变量使用 RIP 相对寻址，对局部变量使用栈偏移。

### Backend status

| Backend | Status |
|---------|--------|
| Interpreter (Python eval) | 完成，主要测试目标 |
| x86-64 ELF (self-hosted) | 现行，`./build/corec build` 管线 |
| x86-64 StackAsmGen (Python) | 只用于 bootstrap 构建（`build_selfhost_native.py`） |
| ARM64 (Python) | 完成，生成 `.s`，再由 `as`/`ld` 处理 |
| Legacy ASM backend | 移到 `legacy_asm_backend/`（已由 ELF 后端替代） |

### Variable declaration syntax

Core 使用 `:=` 和 `: type` 声明，没有 `let` 关键字：

| Syntax | Meaning |
|--------|---------|
| `x := expr;` | 推断类型，不可变 |
| `x : Type = expr;` | 显式类型，不可变 |
| `x : ., mut = expr;` | 可变，类型推断（`.` 表示自动） |
| `x : int, mut, pub = expr;` | 显式类型加标签 |
| `x : auto = 42;` | `auto` 关键字，类型推断 |
| `a, b : int = 1, 2;` | 批量声明 |

标签：`mut`（可变）、`pub`（公开）。

### Module/Import System

- 按文件标识符导入：`import math`
- 使用别名：`import math : m`
- 外部项目：`import @acme math`
- `_import.cr`：目录内所有 `.cr` 文件共享的导入
- import 解析（`module.cr` 中的 `res_imports()`）扫描 token 中的 `T_IMPORT`，加载文件并重新做词法分析
- 搜索顺序：`g_source_dir`、`src/stdlib/`、当前目录

## Language Grammar

`grammar/` 中的形式化 EBNF 定义：

- `core.ebnf`：完整语言语法
- `corespec.ebnf`：规约和契约语法
- `tokens.ebnf`：token 定义

设计文档（中文）：

- `docs/project-book.md`：项目理念、IR 系统、形式验证架构
- `docs/dataflow-design.md`：数据流执行模型设计
- `docs/developer/syntax.md`：语言语法参考
- `docs/execution-model.md`：执行模型
- `docs/maintainer/design/memory-model.md`：Arena 内存模型设计
- `docs/developer/errors.md`：编译器错误码参考

## Known Issues

### corec2 tokenizer 死循环（自举阻塞项）：历史条目，当前不复现（2026-09-16 文档审计修订）

`./build/corec2 check FILE.cr` 会卡在 tokenizer。根因：约 9 个全局变量（`g_tok_cap`, `g_tokens`,
`g_str_count`, `g_line`, `g_source_len`, `g_x86_is_global`, `g_x86_global_cap`, `g_str_hash`,
`g_error_count`）没有被 parser 注册到 `g_ir_globals`，赋值语句被不报错地丢弃。PR #9（RhineIris）已通过
tokenizer 参数化（`tokenize(_src: string)`）避开 `g_source` 全局变量依赖，但其他未注册全局变量的问题
仍待解决。

> 现状（审计实核，2026-09-16）：`corec2` 链可以正常执行，并且逐字节稳定。`src/ci/run.sh` 的
> `full-bootstrap` job 用 `./build/corec` 构建 `corec2`，再由 `corec2` 构建 `corec3` 并执行 `cmp`；
> R2 P6 Task 7 实测 `corec2 == corec3` IDENTICAL、N06=0、快速验证 42（如果 tokenizer 死循环，这个 job
> 一定失败）。因此本条目不再作为阻塞项，原文保留仅供追溯（「未注册全局变量」的历史记录仍是审计资料）。

### pass_cse / O1 稳定性（未复核；2026-09-16 审计标注）

`--opt-level 1` 在自举编译时可能崩溃（`pass_cse` 大函数问题，`alloc_registers` 元数据交互异常）。

> 审计状态：本条目是推测性断言（「可能崩溃」），2026-09-16 审计未能实核（审计期间没有构建）。要判定
> 是否保留，需要实测一次 `-O 1` 自举链（检查：`corec build src/compiler/main.cr -O 1` 的 rc 和产物）。
> 在此之前按「未复核」对待，不能据此推断 O1 可用或不可用。

## Key Conventions

- 文件扩展名：`.cr`（源码）、`.cir`（数据流图 IR，图形态）、`.ccr`（格形态 IR，v9 是段表架构的
  8 段：STR/SYM/NOD/ENT/REG/EDG + TYPE(7)/IFACE(8)。R2 P4 实现方式阶段起使用段表，R2 P6 T3 起为 v9，
  NOD 40B 表示 TYPE 段项索引；版本以 `src/compiler/ccr_io.cr::CCR_VERSION` 为准；文件名和测试名
  保留「v7」，它是段表架构的代号，见 specs/2026-09-09-lattice-ir-v7-format.md。2026-09-16 审计修订：
  原文写 v8，已过时）、`.corespec`（2026-09-06 退役，规约并入 .cr 语法，见 grammar/core.ebnf
  迁移事项）
- `tests/bootstrap/` 和 `tests/selfhost/` 的测试在代码中内联 Core 源码字符串，并比较输出
- Python bootstrap：用 `sys.path.insert(0, 'bootstrap')` 导入编译器模块
- 编辑器集成在 `editor/` 下（不是仓库根的 `vscode-core/`）：`vscode-core/`（VS Code 扩展）、
  `nvim/`（Neovim：syntax/ftdetect/ftplugin/snippets）、`core.mtsx`（Zed 用 grammar）、
  `corecheck`（脚本）
- 规约文件在 `spec/`（.corespec 已退役，规约语法并入 .cr，图即验证由 TagNode/.csr 表示）
- 示例在 `examples/`

## Known Issues & TODO

当前状态见 [TODO.md](TODO.md)。文件有 371 KB、1300 多行，不要整篇阅读，用 `rg` 或 `grep` 定位条目。

### TODO 标识约定（自动检查，写错会导致 CI 失败）

新条目标识是 `#YYYY-MM-DD-N`（日期是创建日期；`N` 是当天序号，按标题行行号升序取「当天最大 +1」）。
旧「全局单调号 `#NN`」已永久封存，不复用，也不重新编号。历史 commit 和文档里的旧号按 TODO.md 头部的
「编号迁移对照表」解析。`tests/harness/test_todo_id_migration.py` 自动执行以下检查：
J1 全仓没有旧形态残留；J2 新 id 与 TODO.md 标题双向一致，没有悬空；J3 映射完备；J4 突变自证。

> 注：J4 的突变样本取自本文件，`elf.cr` 未被引用文件条目里的 `TODO #2026-09-10-3` 引用就是这个实现方式。
> 删除或修改它会让 J4 失去自证能力（运行 `python3 tests/harness/test_todo_id_migration.py` 可以立即确认）。

### 会话级硬性规则的自动检查（不能绕过）

- 硬性规则 #2（禁用 git）：`.claude/settings.json` 的 PreToolUse hook 指向 `.claude/hooks/block-git.py`，
  拦截任意位置的 git 调用（分隔符后、命令替换、`bash -c`、前缀命令后）。引号内的文本和 heredoc 体
  不会被误拦，`jj git push` 放行。回归测试是 `tests/harness/test_block_git.py`。hook 自身异常时
  一律放行（宁可不拦截，也不阻塞会话），因此不要依赖它作为安全边界，只把它当作习惯约束。
- 硬性规则 #3（文件永久不允许还原）：`jj restore`、`jj abandon`、覆盖回退既有文件，都必须先取得明确许可。
