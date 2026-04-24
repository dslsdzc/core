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

## Architecture

The bootstrap compiler is a single-pass pipeline (no external dependencies). Each stage is in `bootstrap/corec/`:

```
syntax/ast.py          → AST node dataclasses
frontend/lexer.py      → Tokenizes .core source
frontend/parser.py     → Recursive-descent parser → AST
frontend/name_resolver.py → First pass: collects declarations, resolves names
frontend/desugar.py    → Desugars match → if-else chains
frontend/type_checker.py → Second pass: type inference + checking
frontend/ir_gen.py     → AST → Core IR (Module → FunctionDef → BasicBlock → Instr)
ir/coreir.py           → IR instruction definitions (ConstInstr, BinaryInstr, etc.)
ir/symbol_table.py     → Scoped symbol table shared across passes
backend/interpreter.py → Executes IR directly (Python eval)
backend/arm64_asm.py   → ARM64 code generation (~224 lines, complete pipeline)
backend/x86_64_asm.py  → x86-64 code generation (partial)
```

Pipeline flow: `Lexer → Parser → NameResolver → Desugarer → TypeChecker → IRGen → Interpreter/Backend`

Key design points:
- All IR instructions carry destination variables and full type info
- The type checker is a second pass (not interleaved with parsing)
- Errors are accumulated in `resolver.errors` / `checker.errors` (not exceptions)
- Parser reports errors via `Parser.error(msg, token)` which sets a flag
- `src/` directory holds the planned self-hosted compiler (Core source), not yet implemented
- `spec/` holds formal specification files (`.corespec`) for future verifier

## Language Syntax

Rust-adjacent: `fn`, `let`/`let mut`, `struct`, `enum`, `impl`, `match`, `loop`, `move`. Contracts use `requires`/`ensures` in `.corespec` files. Full grammar: `grammar/core.ebnf`.

## Key Conventions

- File extensions: `.core` (source), `.coreir` (IR dump), `.corespec` (spec), `.s`/`.o` (generated asm/obj)
- Tests in `test_all.py` define inline Core source strings and compare interpreter output
- Python bootstrap code uses `sys.path.insert(0, 'bootstrap')` to import compiler modules
- VS Code extension in `vscode-core/` provides TextMate-based syntax highlighting for `.core`, `.corespec`, `.coreir`
