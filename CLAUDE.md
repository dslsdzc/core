# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Core is a new general-purpose programming language with a "semantic preservation" (语义保鲜) philosophy — its IR retains full type/semantic info throughout compilation for direct consumption by formal verification tools. Currently in bootstrap stage (compiler written in Python).

## Build & Test Commands

```bash
python3 test_all.py              # Run all integration tests (requires Python 3.10+)
python3 tools/corec build FILE.core -o OUTPUT   # Compile .core → ARM64 native executable
python3 tools/corec ir FILE.core                 # Generate IR dump only
```

The `tools/corec` CLI expects `as` and `ld` on PATH for ARM64 assembly/linking.

Individual test files at repo root (each is standalone):
```bash
python3 test_borrow.py           # Borrow checker tests
python3 test_generics.py         # Generic function/struct tests
python3 test_for.py              # For loop tests
python3 test_references.py       # Reference semantics tests
python3 test_array.py            # Array tests
python3 test_array2.py           # Additional array tests
python3 test_builtin_opt.py      # Built-in optimization tests
```

Test pattern: each file imports compiler modules directly via `sys.path.insert(0, 'bootstrap')`, runs inline Core source through the full pipeline (lex → parse → resolve → desugar → typecheck → ir_gen → interpret), and prints `[PASS]`/`[FAIL]`.

Integration tests in `tests/` are `.core` source files — run through `tools/corec ir` or `tools/corec build`.

## Architecture

The bootstrap compiler is a pure-Python, single-pass pipeline (no external dependencies). Each stage is in `bootstrap/corec/`:

```
syntax/ast.py          → AST node dataclasses (~120 lines, 20+ Expr/Decl/Type variants)
syntax/tokens.py       → Token + TokenKind definitions
syntax/keywords.py     → Keyword list

frontend/lexer.py      → Tokenizes .core source
frontend/parser.py     → Recursive-descent parser → AST
frontend/name_resolver.py → First pass: collects declarations, resolves names
frontend/desugar.py    → Desugars match → if-else chains
frontend/type_checker.py → Second pass: type inference + checking (also handles borrow checking)
frontend/ir_gen.py     → AST → Core IR (Module → FunctionDef → BasicBlock → Instr)
frontend/control_flow.py → Control flow graph utilities
frontend/spec_checker.py → Contract/spect specification checker

ir/coreir.py           → IR instruction definitions (20+ instr types: ConstInstr, BinaryInstr, BranchInstr, PhiInstr, etc.)
ir/base.py             → IRNode base class, IRVar, VarKind enum
ir/symbol_table.py     → Scoped symbol table (Scope/Symbol/SymbolTable) shared across passes
ir/graph.py            → CFG graph utilities (placeholder)
ir/corespecir.py       → Spec-level IR definitions

backend/interpreter.py → Executes IR directly (Python eval — main testing path)
backend/arm64_asm.py   → ARM64 code generation (~224 lines, complete pipeline)
backend/arm64.py       → ARM64 ABI/helper utilities
backend/x86_64_asm.py  → x86-64 code generation (partial)
backend/x86_64.py      → x86-64 helper utilities
backend/c_backend.py   → C code generation backend
backend/base.py        → Backend base class

verifier/conditions.py → Formal verification conditions (placeholder)
verifier/prover.py     → Theorem prover (placeholder)
verifier/smt.py        → SMT solver interface (placeholder)

utils/diagnostics.py   → Compiler diagnostics (placeholder)
utils/span.py          → Source span tracking (placeholder)
```

Pipeline flow: `Lexer → Parser → NameResolver → Desugarer → TypeChecker → IRGen → Interpreter/Backend`

### Key design points

- All IR instructions carry destination variables (`dest: IRVar`) and full type info
- IR uses basic blocks with explicit `BranchInstr`/`JumpInstr` — forms a CFG
- `PhiInstr` for SSA-form φ-nodes at block joins
- The type checker is a second pass (not interleaved with parsing), also handles borrow checking
- Errors are accumulated in `resolver.errors` / `checker.errors` (not exceptions)
- Parser reports errors via `Parser.error(msg, token)` which sets a flag
- Testing goes through the interpreter (not native execution), enabling fast iteration
- Interpreter uses `id(var)`-based variable store with max-steps guard to prevent infinite loops

### Backend status

| Backend | Status |
|---------|--------|
| Interpreter (Python eval) | Complete — primary test target |
| ARM64 (aarch64) | Complete — generates `.s` → `as`/`ld` → native binary |
| x86-64 | Partial |
| C | Partial (c_backend.py) |

## Self-Hosted Compiler (`src/`)

The `src/` directory holds the planned self-hosted compiler written in Core source:

```
src/compiler/          → Compiler modules in Core (lexer.core, parser.core, checker.core, ir_gen.core, etc.)
src/stdlib/            → Standard library (io.core, math.core, collections.core, chan.core)
src/runtime/           → Runtime support (rt.core, bootstrap.c)
```

Not yet functional — the bootstrap Python compiler is the current active implementation.

## Language Grammar

Formal EBNF definitions in `grammar/`:
- `core.ebnf` — Full language grammar (Rust-adjacent: `fn`, `let`/`let mut`, `struct`, `enum`, `impl`, `match`, `loop`, `for`, `go`/`await`)
- `corespec.ebnf` — Specification/contract grammar
- `tokens.ebnf` — Token definitions

## Key Conventions

- File extensions: `.core` (source), `.coreir` (IR dump), `.corespec` (spec), `.s`/`.o` (generated asm/obj)
- Tests in `test_*.py` define inline Core source strings and compare interpreter output
- Python bootstrap code uses `sys.path.insert(0, 'bootstrap')` to import compiler modules
- VS Code extension in `vscode-core/` provides TextMate-based syntax highlighting for `.core`, `.corespec`, `.coreir`
- Spec files in `spec/` (`.corespec`) for future formal verifier consumption
- Examples in `examples/` with per-subdirectory projects