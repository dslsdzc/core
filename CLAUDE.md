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

# Linear CFG dump
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

Integration tests in `tests/suite/` are `.cr` source files — run through `./build/corec`.

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
bootstrap/corec/ir/ccr.py              → Linear CFG IR instruction definitions
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
src/compiler/
├── ast.cr          → AST node kinds, IR opcodes, type constants
├── lexer.cr        → Tokenizer (int-based char access, no string allocs)
├── parser.cr       → Recursive-descent parser → flat AST
├── checker.cr      → Type checker, borrow checker, declaration collector
├── ir_gen.cr       → AST → IR instruction generation
├── dataflow.cr     → Dataflow graph construction (.cir)
├── ccr_io.cr       → .ccr binary serialization/deserialization
├── opt.cr          → Optimization passes (CSE, register allocation, stack sharing)
├── pass.cr         → AST-level optimization (constant folding)
├── diag.cr         → Compiler diagnostics
├── module.cr       → Import resolution, file ID management
├── project.cr      → Core.toml project config loading
├── interp.cr       → IR interpreter (for `run` command)
├── dump.cr         → Debug dump utilities
├── dyn_arr.cr      → Dynamic array grow helpers + string interning
├── globals.cr      → All global variable declarations
├── entry.cr        → Entry point wrapper
├── main.cr         → CLI + pipeline orchestration (corec binary)
├── corearch.cr     → Backend entry point (corearch binary)
└── _import.cr      → Shared imports for all compiler modules
```

### ELF Backend (`src/arch/linux/ld/`)

Direct ELF binary output for x86-64, used by `corearch`:

```
src/arch/linux/ld/
├── elf.cr      → ELF header + program header generation, _start emission
├── instr.cr    → Instruction encoding: REX, ModRM, SIB, all IR opcode emitters
├── sizes.cr    → Instruction byte size helpers (sz_* functions)
├── resolve.cr  → Label resolution pass (res_labels)
└── ld.cr       → Dynamic linking (PLT/GOT, .so loading)
```

### Standard Library (`src/stdlib/`)

```
src/stdlib/
├── cli.cr      → CLI argument parsing
├── fmt.cr      → String formatting (int_str, chr, str_eq, str_hash, etc.)
├── io.cr       → I/O (print, println, read_file, write_file)
├── os.cr       → OS utilities (get_env)
├── toml.cr     → TOML config parsing
├── panic.cr    → Rust-style panic handler (dev only)
├── math.cr     → Math functions (stub)
├── collections.cr → Collections (stub)
└── _import.cr  → Shared imports for stdlib modules
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
- `docs/language-syntax.md` — Language syntax reference
- `docs/execution-model.md` — Execution model
- `docs/memory-model.md` — Arena memory model design
- `docs/error-codes.md` — Compiler error code reference

## Known Issues

### corec2 tokenizer 死循环（自举阻塞项）
`./build/corec2 check FILE.cr` 卡在 tokenizer。根因：约 9 个全局变量（`g_tok_cap`, `g_tokens`, `g_str_count`, `g_line`, `g_source_len`, `g_x86_is_global`, `g_x86_global_cap`, `g_str_hash`, `g_error_count`）未被 parser 注册到 `g_ir_globals`，赋值语句静默丢弃。已在 PR #9（RhineIris）中通过 tokenizer 参数化（`tokenize(_src: string)`）规避了 `g_source` 全局变量依赖，但其他未注册全局变量问题仍待解决。

### corec2 前端性能（~1000x 慢于 build/corec）
ELF 后端全栈操作无寄存器分配是直接原因。寄存器分配器只作用于用户程序 IR，不影响编译器自身代码。

### pass_cse / O1 稳定性
`--opt-level 1` 在自举编译时可能崩溃（`pass_cse` 大函数问题，`alloc_registers` 元数据交互异常）。

## Key Conventions

- File extensions: `.cr` (source), `.cir` (dataflow graph IR), `.ccr` (linear CFG IR), `.corespec` (spec)
- Tests in `tests/bootstrap/` and `tests/selfhost/` define inline Core source strings and compare output
- Python bootstrap: `sys.path.insert(0, 'bootstrap')` to import compiler modules
- VS Code extension in `vscode-core/`
- Spec files in `spec/` (`.corespec`) for formal verifier
- Examples in `examples/`

## Known Issues & TODO

See [TODO.md](TODO.md) for current status.
