# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 铁律（Hard Rules）

这些规则不可违反，除非用户明确另有指示。

1. **不许绕过问题** — 找到 root cause 直接修复。
2. **禁止使用 `git`** — 全面使用 `jj`。所有版本控制操作都用 `jj` 命令。
3. **文件永久不允许还原** — 还原必须经过用户明确许可。
4. **直接解决问题** — 不变通、不绕过、不掩盖。
5. **除非彻底不可修复** — 充分验证后才可提替代方案。
6. **编译任务限制 CPU** — 任何长时间编译/测试任务必须用 `cpulimit -l 10` 或 `nice -n 19` 限制 CPU 占用不超过 10%，避免风扇噪音影响用户体验。

违反这些规则的后果：用户会极度愤怒，信任归零。

## Project Overview

Core is a new general-purpose programming language with a "semantic preservation" (语义保鲜) philosophy — its IR retains full type/semantic info throughout compilation for direct consumption by formal verification tools.

There are two compilers:
- **Python bootstrap** (`bootstrap/corec/`) — the initial compiler, written in Python, used to build the self-hosted compiler
- **Self-hosted compiler** (`src/compiler/`) — the Core compiler written in Core itself, built by the Python bootstrap

## 版本控制流程（GitFlow）

- 全面使用 `jj`（铁律 #2，hook 机械拦截 git）。分支模型：feature → develop → main
- **main = 正式版线**：仅维护者 DslsDZC 可合入（ruleset：update 规则 + 无管理员绕过）
- **develop = 集成分支**：日常 PR 目标（ruleset：PR 通道 + 审批 + merge queue + CI 门槛）
- 日常开发（feature → develop）：

```bash
jj bookmark create feature/xxx        # 每个改动独立分支（base = develop）
# ...开发提交（SSH 自动签名）...
jj git push -b feature/xxx
gh pr create --base develop --fill    # PR 指向 develop（"不能指向 main"）
# → 审查（审批+CI 绿）→ **手动 squash 合入 develop**（merge queue 因免费计划降级，见 spec §3.3）
jj git fetch && jj bookmark move develop -r develop@origin
```

- 发布（develop → main，仅维护者）：

```bash
jj git push -b develop
gh pr create --base main --fill       # required reviewers = 你 → 你批准 → 手动 squash 合入
```

- 合入 main 后（发布线）：

```bash
jj git fetch && jj bookmark move main -r main@origin
```

## Build & Test Commands

```bash
# Build self-hosted compiler (Python bootstrap → native binary)
python3 build_selfhost_native.py       # Produces build/corec + build/corearch

# Self-hosted frontend: .cr → .ccr/.cir
./build/corec build FILE.cr -o OUTPUT --static

# Self-hosted backend: .ccr → ELF binary (called by corec automatically)
./build/corearch FILE.ccr --elf --static -o OUTPUT

# Type-check only
./build/corec check FILE.cr

# Interpreter execution (inline code)
./build/corec run 'fn main()->int{return 42;}'

# Dataflow graph dump
./build/corec cir FILE.cr

# 格形态 IR dump（v8 = 段表 8 段：STR/SYM/NOD/ENT/REG/EDG + TYPE(7)/IFACE(8)）
./build/corec ccr FILE.cr
```

### Test suites

**Bootstrap pipeline tests** (`tests/bootstrap/`):
```bash
python3 tests/bootstrap/test_pipeline.py   # core pipeline: lex → parse → check → ir → interp
python3 tests/bootstrap/test_borrow.py     # Borrow checker error detection
python3 tests/bootstrap/test_generics.py   # Generic function + generic struct
```

**Self-hosted compiler tests** (`tests/selfhost/`):
```bash
python3 tests/selfhost/test_compile.py     # Self-compilation pipeline test
python3 tests/selfhost/test_impl.py        # Impl/method tests
python3 tests/selfhost/test_borrow.py      # Self-hosted borrow checker (7 rules)
```
> **清单口径（2026-09-16 文档审计修订）**：上面三行只是**入口示例**，不是全集——
> `tests/selfhost/test_*.py` 实为 **50+** 套件、`tests/bootstrap/*.py` **7** 套件。
> **套件全集真源 = `ls tests/selfhost/test_*.py tests/bootstrap/*.py`；CI 挂点真源 = `src/ci/run.sh`
> 的 `selfhost-tests` / `bootstrap-tests` job**（逐档挂点 + 计数注）。全枚举口径见
> `src/ci/run.sh`（每档 rc 汇总）与 `.superpowers/sdd/` 各批报告。

Integration tests in `tests/suite/` are `.cr` source files — run through `./build/corec`.

**行为探针语料**（`tests/probes/`，29 档 `check` 面负例为主，**非编译单元**）与**回归网配方**（`tools/baseline/`：冻结基线重建 + sha 白名单 + 两条 runner）见 `tools/baseline/REBUILD.md`——判定面回归网 = 冻结基线同源对拍 + 行为探针 + 突变控制 + 三态纪律（R2 P6 Task 1 起；影子通道已下线，不得引用其计数）。

## Architecture

### Python Bootstrap Compiler

The bootstrap is a pure-Python, single-pass pipeline in `bootstrap/corec/` (no external dependencies):

```
bootstrap/corec/syntax/ast.py          → AST node dataclasses
bootstrap/corec/syntax/tokens.py       → Token + TokenKind definitions
bootstrap/corec/syntax/keywords.py     → Keyword list

bootstrap/corec/frontend/lexer.py      → Tokenizes .cr source
bootstrap/corec/frontend/parser.py     → Recursive-descent parser → AST
bootstrap/corec/frontend/name_resolver.py → Declaration collection + name resolution
bootstrap/corec/frontend/desugar.py    → Desugars match → if-else chains
bootstrap/corec/frontend/type_checker.py → Type inference + checking + borrow checking
bootstrap/corec/frontend/ir_gen.py     → AST → Core IR

bootstrap/corec/ir/cir.py              → Dataflow graph IR definitions
bootstrap/corec/ir/ccr.py              → 格形态 IR（注：该文件实际不存在——.ccr 仅由 self-hosted ccr_io.cr 读写；现行 = v8 八段段表，见 specs/2026-09-09-lattice-ir-v7-format.md；v6 版历史设计见 specs/2026-09-05-lattice-ir-v6-format.md）
bootstrap/corec/ir/base.py             → IRNode base class, IRVar, VarKind
bootstrap/corec/ir/symbol_table.py     → Scoped symbol table

bootstrap/corec/backend/interpreter.py → Executes IR directly (Python eval)
bootstrap/corec/backend/x86_64_stack_asm.py → x86-64 stack-based codegen
bootstrap/corec/backend/arm64_asm.py   → ARM64 code generation
bootstrap/corec/utils/module_loader.py → Import resolution
```

Pipeline flow:
```
Lexer → Parser → NameResolver → MatchDesugarer → TypeChecker → IRGen → Backend
```

### Self-Hosted Compiler

The self-hosted compiler is written in Core and lives in `src/compiler/`. Built by `build_selfhost_native.py` which runs the Python bootstrap on all `src/compiler/*.cr` files.

```
src/compiler/     （**全 38 个 .cr**；2026-09-16 文档审计修订：原清单只列 20 个，R2 各批新增的
                    类型引擎/载体/分析文件全缺——修订依据 = `ls src/compiler/*.cr`（38）逐个人工注；
                    单元归属 = build_selfhost_native.py 的 corec_files(45)/corelsp_files(31)/
                    backend_support_files(9)/common_files(9) 清单，按**全路径**核定）
├── ast.cr          → AST node kinds, IR opcodes, type constants（common+corec+corelsp）
├── ccr_io.cr       → .ccr binary serialization/deserialization（backend_support+corec）
├── ccr_types.cr    → TYPE(7)/IFACE(8) 两段**内容构造**（corec-only；D18 解耦）
├── checker.cr      → Type checker, borrow checker, declaration collector（corec+corelsp）
├── cir_cache.cr    → 函数级 `.cir` 快照缓存 save/load（corec）
├── corearch.cr     → Backend entry point (corearch binary)（backend_support）
├── dataflow.cr     → HDFG 构建：DFNode/DFEdge（含 state edges）+ 嵌套 region（SG_IF/LOOP/FOR/FLOW/UNSAFE）+ g_df_node_region 显式映射 + DOT（corec）
├── diag.cr         → Compiler diagnostics（corec+corelsp；含 fail-closed 豁免表 `diag_gate_exempt`）
├── dump.cr         → Debug dump utilities（corec）
├── dyn_arr.cr      → Dynamic array grow helpers + string interning（common+corec+corelsp）
├── elf.cr          → ⚠ **死文件**（566 行、零 importer、三面清单皆无——TODO #7；**勿引**）
├── entry.cr        → project-mode 入口 shim（`fn main() { return compiler_main(); }`）
├── ext_mgr.cr      → 编译器扩展管理器——插件注册表 + 钩子调度（corec）
├── ext_safety.cr   → 运行时安全检查插件（经 ext_mgr 注册到编译钩子）（corec）
├── globals.cr      → All global variable declarations（common+corec+corelsp）
├── iface_axis.cr   → iface 满足判定簇 + `iface_kind_of`（R2 P4 T0 引擎核纯化拆分；corec-only 宿主）
├── iface_registry.cr → 本质条目表（原生条目）+ `iface_*` 查询 API（corec+corelsp）
├── _import.cr      → src/compiler **全文件共享导入**（`load_imports` 直读；不在 concat 清单）
├── interp.cr       → IR interpreter (for `run` command)（corec）
├── ir_gen.cr       → AST → IR instruction generation（corec）
├── lexer.cr        → Tokenizer (int-based char access, no string allocs)（corec+corelsp）
├── linker.cr       → ⚠ **空文件**（0 字节、零引用；2026-09-16 审计登记，建议清理或填实）
├── main.cr         → CLI + pipeline orchestration (corec binary)（corec）
├── module.cr       → Import resolution, file ID management（corec+corelsp）
├── monomorph.cr    → Generic monomorphization: instance cache + AST specialization（corec）
├── opt.cr          → Optimization passes (CSE, register allocation, stack sharing)（corec）
├── parser.cr       → Recursive-descent parser → flat AST（corec+corelsp）
├── pass.cr         → AST-level optimization (constant folding)（corec）
├── project.cr      → Core.toml project config loading（corec）
├── provenance_verify.cr → ProvenanceVerify pass——DEREF 偏移对 allocation size 校验（corec；`main.cr:614-615` 接线）
├── ptr_analysis.cr → PointerAnalysis pass——过程间 Andersen 式约束求解（corec）
├── purity_selftest.cr → 真纯度计算自测通道（`corec selftest-purity`）（corec）
├── regalloc-consistency.cr → 分配器（CAG 贪心放置）逻辑正确性契约——**文档载体，不入任何清单**
├── region_check.cr → RegionCheck pass——DEREF 目标须在活子图（corec）
├── ty_shadow.cr    → 判定桥接层/类型项构造（R2 P2a 起；**P5 T5 后不含影子层**，`sh_` = 历史前缀）（corec+corelsp）
├── type_engine.cr  → R2 P0 类型项判定引擎（语义包含；spec §1/§3）（backend_support+corec+corelsp）
├── type_selftest.cr → 类型引擎判定用例表 + `corec selftest-types`（corec）
└── type_terms.cr   → R2 P0 类型项表（集合语义 DAG）（backend_support+corec+corelsp）
```

### Backend（x86 实例化三轴布局：架构 × 格式 × OS；`src/arch/linux/ld/` 已退役）

Direct ELF binary output for x86-64, used by `corearch`. 三轴目录 = 跨轴 import 的
唯一通道（`module.cr` 回退链），组合根 = `src/targets/x86_64-linux/`（target triple 命名）：

```
src/arch/x86_64/          → regalloc.cr（CAG 寄存器分配）· sizes.cr（指令字节尺寸单源）· instr.cr（指令编码 REX/ModRM/SIB + 全 IR opcode 发射 + e2_* 原语）· frame.cr（帧布局/序言尾声——帧公式单入口 pf_frame_size）· tag2l.cr（int 多字 M1 tag/2L 编码族）· core-x86.toml（HIT 表数据）
src/format/elf/           → elf.cr（ELF 头/phdr/段发射 + elf_gen）· resolve.cr（标签解析 res_labels）· ld.cr（动态链接 PLT/GOT/.so 装载）
src/os/linux/             → entry.cr（_start 发射序 emit_start/emit_start_size）· callseq.cr（SysV AMD64 参数/栈/返回/调用序列）· syscall.cr（syscall3/4 内置体——rax 号 + rdi/rsi/rdx(/r10) 参数序）（三件均波 1 落位：Task 2/5/6）
src/targets/x86_64-linux/ → 组合根（target triple）：main.cr + _import.cr + Core.toml（`corec build <dir>` 的 project-mode 入口）
```

### Standard Library (`src/stdlib/`)

```
src/stdlib/       （**全 19 个 .cr**；2026-09-16 文档审计修订：原清单只列 8 个，缺 11 个）
├── arena.cr        → 子图 arena（函数/loop/for/unsafe 各一个；分配器面已实现）
├── assert.cr       → 运行时检查系统（assert!/debug_assert!/unreachable!/todo! 风格）
├── chan.cr         → 通道运行时（单产单消边；`sched_init` 自动初始化）
├── cli.cr          → CLI argument parsing
├── collections.cr  → Collections (stub)
├── dex.cr          → dex 定点方案（执行时定稿 2026-08-16）
├── fmt.cr          → String formatting (int_str, chr, str_eq, str_hash, etc.)
├── goroutine.cr    → goroutine 入口包装地址（`goroutine_entry_wrapper`）
├── hotpatch.cr     → Hotpatch runtime: config file management, in-flight request tracking
├── io.cr           → I/O (print, println, read_file, write_file)
├── math.cr         → Math functions (stub)
├── os.cr           → OS utilities (get_env)
├── panic.cr        → Rust-style panic handler (dev only)
├── sched.cr        → 调度器核心（G0 = 主线程；协作切换，单 M）
├── scheduler.cr    → `go node` = 独立 Fiber + Arena 的轮转调度
├── toml.cr         → TOML config parsing
├── trace.cr        → 运行时诊断（RUST_BACKTRACE/dbg! 风格）
├── variadic.cr     → 运行时变参工具
├── _import.cr      → Shared imports for stdlib modules
├── 平台桥抽象设计：I/O 流 / 随机 / 哈希 / 时钟（语义接口 + 后端实现，程序 IO = 流转导器）——设计定案待实现（docs/superpowers/specs/2026-08-16-platform-abstract-design.md）
└── 注：`assert.cr`/`collections.cr`/`dex.cr`/`math.cr`/`scheduler.cr`/`trace.cr`/`variadic.cr`
        **不在 build_selfhost_native.py 的任何清单**（corec_files/corelsp_files/backend_support_files…）
        ——单元归属真源 = 该脚本按**全路径**核定的清单（2026-09-16 审计实核）
```

### Runtime (`src/runtime/`)

```
src/runtime/
├── rt.s    → Assembly: _start, bump allocator, __builtin_* functions
└── rt.cr   → Core runtime globals (g_rt_argc, g_rt_argv_ptr)
```

### Key design points (self-hosted)

- All arrays are **dynamic byte buffers** (`string` + grow functions), no `MAX_*` limits
- Flat AST: every node is `{kind, a, b, c, int_val, type_val, data, line, col}` in `g_ast`
- Flat IR: every instruction is `{opcode, dest, src1, src2, src3, type_kind}` in `g_ir_instrs`
- The checker runs two passes: first registers struct/enum/function declarations, then type-checks bodies
- Tokenizer uses integer character codes (no `get_char` string allocs in hot path)
- Global variables are IR variables with indices tracked in `g_ir_globals` + `g_x86_is_global` for the ELF backend
- The ELF backend uses RIP-relative addressing for globals, stack offsets for locals

### Backend status

| Backend | Status |
|---------|--------|
| Interpreter (Python eval) | Complete — primary test target |
| x86-64 ELF (self-hosted) | Active — `./build/corec build` pipeline |
| x86-64 StackAsmGen (Python) | Used only for bootstrap build (`build_selfhost_native.py`) |
| ARM64 (Python) | Complete — generates `.s` → `as`/`ld` |
| Legacy ASM backend | Moved to `legacy_asm_backend/` (replaced by ELF backend) |

### Variable declaration syntax

Core uses `:=` / `: type` declarations (no `let` keyword):

| Syntax | Meaning |
|--------|---------|
| `x := expr;` | Infer type, immutable |
| `x : Type = expr;` | Explicit type, immutable |
| `x : ., mut = expr;` | Mutable, type inferred (`.` = auto) |
| `x : int, mut, pub = expr;` | Explicit type + tags |
| `x : auto = 42;` | `auto` keyword, type inferred |
| `a, b : int = 1, 2;` | Batch declaration |

Tags: `mut` (mutable), `pub` (public).

### Module/Import System

- Import by file identifier: `import math`
- With alias: `import math : m`
- External project: `import @acme math`
- `_import.cr` — shared imports for all `.cr` files in a directory
- Import resolution (`res_imports()` in `module.cr`) scans tokens for `T_IMPORT`, loads files, re-tokenizes
- Search order: `g_source_dir` → `src/stdlib/` → current directory

## Language Grammar

Formal EBNF definitions in `grammar/`:
- `core.ebnf` — Full language grammar
- `corespec.ebnf` — Specification/contract grammar
- `tokens.ebnf` — Token definitions

Design documents (Chinese):
- `docs/project-book.md` — Philosophy, IR system, formal verification architecture
- `docs/dataflow-design.md` — Dataflow execution model design
- `docs/developer/syntax.md` — Language syntax reference
- `docs/execution-model.md` — Execution model
- `docs/maintainer/design/memory-model.md` — Arena memory model design
- `docs/developer/errors.md` — Compiler error code reference

## Known Issues

### ~~corec2 tokenizer 死循环（自举阻塞项）~~ —— **历史条目，当前不复现**（2026-09-16 文档审计修订）
~~`./build/corec2 check FILE.cr` 卡在 tokenizer。根因：约 9 个全局变量（`g_tok_cap`, `g_tokens`, `g_str_count`, `g_line`, `g_source_len`, `g_x86_is_global`, `g_x86_global_cap`, `g_str_hash`, `g_error_count`）未被 parser 注册到 `g_ir_globals`，赋值语句静默丢弃。已在 PR #9（RhineIris）中通过 tokenizer 参数化（`tokenize(_src: string)`）规避了 `g_source` 全局变量依赖，但其他未注册全局变量问题仍待解决。~~
> **现状（审计实核，2026-09-16）**：`corec2` 链**可跑通且逐字节稳定**——`src/ci/run.sh` 的
> `full-bootstrap` job 用 `./build/corec` 构 `corec2`、再由 `corec2` 构 `corec3` 并 `cmp`；
> R2 P6 Task 7 实测 **`corec2 == corec3` IDENTICAL + N06=0 + 冒烟 42**（若 tokenizer 死循环，该 job 必挂）。
> ⇒ 本条目**不再作为阻塞项**；保留原文仅供追溯（「未注册全局变量」的历史教训仍属审计资产）。

### pass_cse / O1 稳定性（**未复核**；2026-09-16 审计标注）
`--opt-level 1` 在自举编译时可能崩溃（`pass_cse` 大函数问题，`alloc_registers` 元数据交互异常）。
> **审计状态**：本条目为**推测式断言**（「可能崩溃」），2026-09-16 审计**未能实核**（审计零构建）⇒
> **须一次 `-O 1` 自举链实测**才能判定存废（判据：`corec build src/compiler/main.cr -O 1` 的 rc + 产物）；
> 在此之前**按「未复核」对待**，不得据它推断 O1 可用或不可用。

## Key Conventions

- File extensions: `.cr` (source), `.cir` (dataflow graph IR / 图形态), `.ccr`（格形态 IR，**v9 = 段表架构 8 段**：STR/SYM/NOD/ENT/REG/EDG + TYPE(7)/IFACE(8)（R2 P4 载体批起；R2 P6 T3 起 **v9**——NOD 40B 承载 TYPE 段项索引；版本真源 = `src/compiler/ccr_io.cr::CCR_VERSION`；文件名/测试名保留「v7」= 段表架构代号，见 specs/2026-09-09-lattice-ir-v7-format.md）。**2026-09-16 审计修订：原文写 v8（陈旧）**）, `.corespec`（已退役 2026-09-06——规约并入 .cr 语法，见 grammar/core.ebnf 迁移事项）
- Tests in `tests/bootstrap/` and `tests/selfhost/` define inline Core source strings and compare output
- Python bootstrap: `sys.path.insert(0, 'bootstrap')` to import compiler modules
- VS Code extension in `vscode-core/`
- Spec files in `spec/`（.corespec 已退役——规约语法并入 .cr，图即验证承载于 TagNode/.csr）
- Examples in `examples/`

## Known Issues & TODO

See [TODO.md](TODO.md) for current status.
