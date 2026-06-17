# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 铁律（Hard Rules）

这些规则不可违反，除非用户明确另有指示。

1. **不许绕过问题** — 找到 root cause 直接修复。不允许删掉调试输出来掩盖 bug、不允许绕路走。
2. **文件永久不允许还原（`git checkout`）** — 还原必须经过用户明确许可。任何时候都不允许自行 `git checkout` 还原文件。
3. **直接解决问题** — 不允许变通方案、不允许绕过、不允许"先合并再修"。每个问题必须彻底修复。
4. **除非彻底不可修复** — 只有在经过充分验证、确认修复不可能或不合理的情况下，才可以提出替代方案。

违反这些规则的后果：用户会极度愤怒，信任归零。

## Project Overview

Core is a new general-purpose programming language with a "semantic preservation" (语义保鲜) philosophy — its IR retains full type/semantic info throughout compilation for direct consumption by formal verification tools. Currently in bootstrap stage (compiler written in Python).

## Build & Test Commands

```bash
python3 tools/corec build FILE.cr -o OUTPUT   # Compile .cr → ARM64 native executable (Python bootstrap)
python3 tools/corec ir FILE.cr                 # Generate dataflow graph (.cir) dump (Python bootstrap)

./build/corec FILE.cr                          # Compile .cr → .ccr (self-hosted frontend)
./build/corearch FILE.ccr -S                   # Compile .ccr → assembly (self-hosted backend)
```

- `tools/corec` (Python) — ARM64 build, `.cir`/`.ccr` dump
- `build/corec` (self-hosted) — x86-64 frontend: `.cr` → `.ccr`/`.cir`
- `build/corearch` (self-hosted) — x86-64 backend: `.ccr` → assembly/ELF

### Test suites

**Bootstrap pipeline tests** (`tests/bootstrap/`): Core source → Python pipeline → interpreter.

```bash
python3 tests/bootstrap/test_pipeline.py   # ~19 tests: arithmetic, control flow, struct, enum, array, for, ref, float, string
python3 tests/bootstrap/test_borrow.py     # Borrow checker error detection tests
python3 tests/bootstrap/test_generics.py   # Generic function + generic struct tests
```

**Self-hosted compiler tests** (`tests/selfhost/`): load compiler src → compile via bootstrap → exercise via interpreter or native binary.

```bash
python3 tests/selfhost/test_compile.py     # Basic interpreter run, lexer compilation, full self-compilation
python3 tests/selfhost/test_impl.py        # Impl/method tests (interpreter + native binary paths)
python3 tests/selfhost/test_borrow.py      # Self-hosted borrow checker tests (7 rules)
```

Integration tests in `tests/suite/` are `.cr` source files — run through `build/corec` or `tools/corec`.

### Self-hosted compiler build

```bash
python3 build_selfhost.py              # Concatenate src/compiler/*.cr → run via interpreter
python3 build_selfhost_native.py       # Compile self-hosted compiler → native x86-64 binary at build/corec
```

`build_selfhost_native.py` uses the Python-speed `X86_64StackAsmGen` backend (not the interpreter) to produce two native binaries: `build/corec` (frontend) and `build/corearch` (backend). The runtime is `src/runtime/rt.s` (assembly: `_start`, bump allocator, `__builtin_get_arg`). Usage: `./build/corec file.cr → file.ccr`, then `./build/corearch file.ccr -S → file.s`.

## Architecture

The bootstrap compiler is a pure-Python, single-pass pipeline (no external dependencies). Each stage is in `bootstrap/corec/`:

```
syntax/ast.py          → AST node dataclasses (~120 lines, 20+ Expr/Decl/Type variants)
syntax/tokens.py       → Token + TokenKind definitions
syntax/keywords.py     → Keyword list

frontend/lexer.py      → Tokenizes .cr source
frontend/parser.py     → Recursive-descent parser → AST
frontend/name_resolver.py → First pass: collects declarations, resolves names
frontend/desugar.py    → Desugars match → if-else chains
frontend/type_checker.py → Second pass: type inference + checking (also handles borrow checking)
frontend/ir_gen.py     → AST → Core IR (.cir dataflow graph → .ccr linear CFG)
frontend/control_flow.py → Control flow graph utilities
frontend/spec_checker.py → Contract/spec specification checker

ir/cir.py              → Dataflow graph IR definitions (DataflowNode, DataflowEdge, DataflowGraph)
ir/ccr.py              → Linear CFG IR instruction definitions (20+ instr types: ConstInstr, BinaryInstr, BranchInstr, PhiInstr, etc.)
ir/base.py             → IRNode base class, IRVar, VarKind enum
ir/symbol_table.py     → Scoped symbol table (Scope/Symbol/SymbolTable) shared across passes
ir/graph.py            → Dataflow graph utilities (placeholder)
ir/corespecir.py       → Spec-level IR definitions

backend/interpreter.py → Executes IR directly (Python eval — main testing path)
backend/arm64_asm.py   → ARM64 code generation (complete pipeline)
backend/arm64.py       → ARM64 ABI/helper utilities
backend/x86_64_stack_asm.py → x86-64 stack-based codegen (used for native self-hosted build, runs at Python speed)
backend/x86_64_asm.py  → x86-64 code generation (partial, being replaced by stack variant)
backend/x86_64.py      → x86-64 helper utilities
backend/base.py        → Backend base class

verifier/conditions.py → Formal verification conditions (placeholder)
verifier/prover.py     → Theorem prover (placeholder)
verifier/smt.py        → SMT solver interface (placeholder)

utils/diagnostics.py   → Compiler diagnostics (placeholder)
utils/span.py          → Source span tracking (placeholder)
```

Pipeline flow: `Lexer → Parser → NameResolver → MatchDesugarer → TypeChecker → IRGen → DataflowGraph → Linearize → Backend`

**Self-hosted frontend** (`corec`, entry in `main.cr`): `tokenize() → resolve_imports() → parse_all() → check_all() → ir_gen_all() → lower_to_ccr() → save_ccr()`

**Self-hosted backend** (`corearch`, entry in `corearch.cr`): `load_ccr() → x86_64_generate()`

### Module/Import System

Core uses a flattening module system based on **file identifiers** and **project identifiers**, decoupling file paths from logical names.

**File identifiers**: By default, a file's identifier is its filename without `.cr` extension. Can be manually overridden with `fileid` at the top of the file:
```core
fileid "my_math"
```
Identifiers must be unique within a project.

**Project identifiers**: Defined in `Core.toml` (`name = "acme"`). Referenced in code with `@` prefix: `@acme`.

**Import syntax**:
```core
import math                // local file by identifier
import math : m            // with alias (used as m.symbol)
import @acme math          // external project
import @acme math : m      // external project with alias
```

**Symbol access**: Use dot notation: `m.add(3, 5)`. Unqualified full paths (`math::add`) are also recognized but importing is preferred.

**_import.cr**: A special file at any directory level. Its imports apply to all `.cr` files in that directory and subdirectories (unless overridden by a child `_import.cr`). Merged from parent to child; conflicts are errors.

**Dependency pruning**: At compile time, the linker traces referenced symbols starting from `main`, extracts only what's used, and merges them into a single binary — suitable for kernel/embedded targets.

**Current implementation** (bootstrap):
- `corec/utils/module_loader.py` — `resolve_imports(ast, search_paths)` flattens imports before name resolution.

**Self-hosted compiler**: `main.cr`'s `resolve_imports()` scans tokens for `T_IMPORT`, reads imported `.cr` files, appends source to `g_source`, and re-tokenizes. Search order: `src/stdlib/` then current directory.

The standard library is in `src/stdlib/`. Currently implemented:
- `io.cr` — `print()`, `println()`, `print_int()`, `println_int()` wrapping `__builtin_*`
- `math.cr`, `collections.cr`, `chan.cr` — stubs

### Key design points

- All IR instructions carry destination variables (`dest: IRVar`) and full type info
- IR uses basic blocks with explicit `BranchInstr`/`JumpInstr` — forms a CFG
- `PhiInstr` for SSA-form φ-nodes at block joins
- The type checker is a second pass (not interleaved with parsing), also handles borrow checking
- Errors are accumulated in `resolver.errors` / `checker.errors` (not exceptions)
- Parser reports errors via `Parser.error(msg, token)` which sets a flag
- Testing goes through the interpreter (not native execution), enabling fast iteration
- Interpreter uses `id(var)`-based variable store with max-steps guard to prevent infinite loops
- `MatchDesugarer` is always run between name resolution and type checking — it transforms `match` expressions into `if`-`else` chains

### Backend status

| Backend | Status |
|---------|--------|
| Interpreter (Python eval) | Complete — primary test target |
| ARM64 (aarch64) | Complete — generates `.s` → `as`/`ld` → native binary |
| x86-64 (stack-based) | Active — used in `build_selfhost_native.py` for native compiler build |
| x86-64 (register-based) | Partial |

## Self-Hosted Compiler (`src/`)

The `src/` directory holds the self-hosted compiler written in Core source:

```
src/compiler/          → Compiler modules in Core (ast.cr, lexer.cr, parser.cr, checker.cr, ir_gen.cr, main.cr)
src/compiler/backend/  → Backend modules (x86_64.cr)
src/compiler/ccr_io.cr → .ccr binary serialization/deserialization
src/compiler/corearch.cr → Backend entry point (corearch binary)
src/compiler/globals.cr → Shared global declarations
src/stdlib/            → Standard library (cli.cr, io.cr, math.cr, collections.cr, chan.cr)
src/runtime/           → Runtime support (rt.cr, rt.s — Core + assembly: bump allocator + __builtin_* functions)
```

The self-hosted compiler can compile Core source to x86-64 assembly. Build it with `build_selfhost_native.py` which compiles all `src/compiler/*.cr` files through the Python bootstrap pipeline and emits a native `build/corec` binary.

### Self-hosted flat IR design

Unlike the Python bootstrap (which uses Python objects), the self-hosted compiler packs everything into pre-allocated integer-indexed arrays. This avoids dynamic allocation — critical since the compiler runs on its own runtime with a bump allocator.

**Data model**: everything is an integer index into a global array.

| Array | Element type | Purpose |
|-------|-------------|---------|
| `g_ast[MAX_AST]` | `ASTNode { kind, a, b, c, int_val, type_val, data, line, col }` | Flat AST — fields `a`/`b`/`c` are child indices or opcodes |
| `g_ir_instrs[MAX_IRINSTRUCTIONS]` | `IRInstr { opcode, dest, src1, src2, src3, type_kind }` | Flat IR — all operands packed into integer slots |
| `g_ir_vars[MAX_IREXPRS]` | `IRVar { name, id, type_kind }` | IR variables |
| `g_strs[MAX_STRS]` | `string` | String interning table |
| `g_tokens[MAX_TOKENS]` | `Token { kind, lexeme, int_val, line, col }` | Token stream |
| `g_syms[MAX_SYMS]` | `SymEntry { name_idx, kind, type_idx, node_idx }` | Symbol table (scoped) |
| `g_types[MAX_TYPES*3]` | `int` triples of `(kind, data, extra)` | Type table |
| `g_structs[MAX_STRUCTS]` | `StructInfo { name, field_names, field_types, field_count, ... }` | Struct definitions |
| `g_enums[MAX_ENUMS]` | `EnumInfo { name, variants, variant_count, ... }` | Enum definitions |
| `g_funcs[MAX_FUNCS]` | `FuncInfo { name, param_count, param_types, return_type, ast_node, ... }` | Function signatures |

**IR opcodes** (defined in `ast.cr`): `IR_CONST(1)`, `IR_BINARY(2)`, `IR_UNARY(3)`, `IR_CALL(4)`, `IR_RETURN(5)`, `IR_ALLOC(6)`, `IR_ALLOC_STRUCT(7)`, `IR_ALLOC_ARRAY(8)`, `IR_STORE(9)`, `IR_LOAD(10)`, `IR_LOAD_FIELD(11)`, `IR_STORE_FIELD(12)`, `IR_LOAD_INDEX(13)`, `IR_STORE_INDEX(14)`, `IR_LOAD_INDEX_VAR(15)`, `IR_STORE_INDEX_VAR(16)`, `IR_MAKE_ENUM(17)`, `IR_REF(18)`, `IR_BRANCH(19)`, `IR_JUMP(20)`, `IR_LABEL(21)`, `IR_PHI(22)`, `IR_LOAD_ENUM_TAG(23)`, `IR_SLICE(24)`, `IR_DEREF(25)`, `IR_STORE_PTR(26)`.

**Assembly output**: `x86_64.cr` emits GAS `.intel_syntax noprefix`. Functions get `.globl` for function symbols. `_start` in `rt.s` calls `_init_globals` then `main`. The bump allocator (`__builtin_alloc`) and `__builtin_get_arg` are in `rt.s`.

**Key invariants of the flat IR**:
- `IR_MAKE_ENUM` stores variant tag at heap offset 0; `IR_STORE_FIELD`/`IR_LOAD_FIELD` auto-offset by +8 for enum targets (tracked via `g_x86_is_enum` array in the backend)
- The checker runs two passes: first registers struct/enum/function declarations, then type-checks bodies
- Parser creates `EXPR_ASSIGN` nodes for `=`, handled separately from `EXPR_BINARY`
- Parameters arrive in registers (`rdi, rsi, rdx, rcx, r8, r9`) and must be saved to stack slots in function prologue
- Builtin functions (`__builtin_*`) are either inlined by the backend or provided by `rt.s`/`rt.cr`

### Variable declaration syntax

Core uses `:=` / `: type` declarations (no `let` keyword). Variants:

| Syntax | Meaning |
|--------|---------|
| `x := expr;` | Infer type, immutable |
| `x : Type = expr;` | Explicit type, immutable |
| `x : ., mut = expr;` | Mutable, type inferred (`.` = auto) |
| `x : int, mut, pub = expr;` | Explicit type + tags |
| `x : auto = 42;` | `auto` keyword, type inferred |
| `a, b : int = 1, 2;` | Batch declaration |

类型推断占位符有两种：`.`（点号）和 `auto` 关键字，均在类型位置上表示"让编译器推断类型"。`.` 更简洁，常用于 `: ., mut` 模式。

推荐正式代码中使用 `auto` 提高可读性，个人脚本或快速原型可使用 `.` 简写。

Tags are parsed as identifiers or keywords before the first `=`. Available tags: `mut` (mutable), `pub` (public).

**Self-hosted parser** (`src/compiler/parser.cr`):
- `is_new_var_decl()` — lookahead function checking `tok_k(p+n)` for `:=` / `:` pattern
- `parse_new_var_decl()` — handles all variants, stores names in `g_extra_lets[16]` buffer for batch overflow
- Creates `EXPR_LET` nodes with `a=name_idx, b=type_node, c=value_node, data=is_mut`

## Language Grammar

Formal EBNF definitions in `grammar/`:
- `core.ebnf` — Full language grammar (`fn`, `:=`/`: type` declarations, `struct`, `enum`, `impl`, `match`, `loop`, `for`, `go`/`await`)
- `corespec.ebnf` — Specification/contract grammar
- `tokens.ebnf` — Token definitions

Design documents (Chinese):
- `docs/project-book.md` — Philosophy, IR system, formal verification architecture
- `docs/dataflow-design.md` — Dataflow execution model design
- `docs/language-syntax.md` — Language syntax reference
- `docs/execution-model.md` — Execution model: DAG, static cyclic graphs, dynamic graphs, deployment configs

## Key Conventions

- File extensions: `.cr` (source), `.cir` (dataflow graph IR), `.ccr` (linear CFG IR), `.corespec` (spec), `.s`/`.o` (generated asm/obj)
- Tests in `tests/bootstrap/` and `tests/selfhost/` define inline Core source strings and compare output
- Python bootstrap code uses `sys.path.insert(0, 'bootstrap')` to import compiler modules
- VS Code extension in `vscode-core/` provides TextMate-based syntax highlighting for `.cr`, `.corespec`, `.cir`, `.ccr`
- Spec files in `spec/` (`.corespec`) for future formal verifier consumption
- Examples in `examples/` with per-subdirectory projects
- Native binary tests use `tests/selfhost/minimal_rt.s` (minimal bump allocator + `_start`) for test linking with `ld`

## Known Issues & TODO

See [TODO.md](.claude/projects/-home-DslsDZC-core/memory/todo.md) (persistent memory) for:
- Pre-existing bugs (variable decl `x : type;` crash, ELF builtins missing)
- Performance/refactoring work (dynamic buffer allocation for all `MAX_*` tables)
- Bootstrapping roadmap

When starting work, always read the TODO first to check what's pending.
