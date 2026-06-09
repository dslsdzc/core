# TODO

## Pre-existing bugs (found but not yet fixed)

### ~~Parser: `if a > b { return 1; } return 0;` — codegen returns wrong result~~

✅ **Fixed** (2025-06-09): Was caused by the parser struct-literal false match
(parser consumed `{` in `if a > b { ... }`). The struct-literal guard
(`g_parse_no_struct_literal = 1`) fixed both the hang and the wrong result.
Confirmed with native binary tests for both `==`/`!=`/`>`/`<` comparisons with
and without `else`, with local variables and function parameters.

### ~~Python interpreter: `%` operator not supported~~

✅ **Fixed** (2025-06-09): Added `elif instr.op == '%': res = left % right` to
`bootstrap/corec/backend/interpreter.py`.

### Self-hosted compiler: `let` keyword not supported in checker

The self-hosted checker (`src/compiler/checker.cr`) doesn't recognize `let`
variable declarations, producing `Undefined name 'let'`. The Python bootstrap
compiler handles `let` fine.

- The self-hosted parser emits `EXPR_LET` nodes for `let x: T = val;`
- But the self-hosted checker doesn't handle `EXPR_LET` in `infer_expr()`

### Build: `build_selfhost.py` broken

Concatenates compiler sources and runs through the Python interpreter.
Broken due to missing `diag.cr` in file list AND the `%` operator issue above.

## Architecture debts

### Text assembly path (`x86_64.cr`) to be removed

The `x86_64_generate()` function in `src/compiler/backend/x86_64.cr` generates
GAS `.intel_syntax noprefix` text assembly. This path is superseded by the
direct ELF output via `x86_64/elf.cr` + `x86_64/instr.cr`.

Once the ELF path is fully validated (allocation, strings, all IR opcodes),
the text assembly path can be removed.

### ELF path: `__builtin_alloc` calls are placeholders

In `x86_64/instr.cr`, `IR_ALLOC_STRUCT`, `IR_ALLOC_ARRAY`, and `IR_MAKE_ENUM`
emit `call __builtin_alloc` with relative offset 0 (effectively a NOP).
Heap allocation doesn't actually work in the ELF output.

Fix options:
1. Inline a bump allocator in the ELF output
2. Link `src/runtime/rt.s` into the ELF binary
3. Write a minimal `_start` that includes `__builtin_alloc`

### Self-hosted compilation (self-bootstrapping)

The compiler can compile simple programs to native ELF binaries, but cannot
yet compile its own source code. The three missing pieces:

1. Heap allocation in ELF path (see above)
2. String constant support in ELF path (partially done: `g_x86_rodata_base`)
3. Full IR opcode coverage in `x86_emit_instr`
