# TODO

## Pre-existing bugs (found but not yet fixed)

### Parser: `if a > b { return 1; } return 0;` — codegen returns wrong result

The parser correctly handles `if a > b { ... }` now (struct-literal false match fixed).
But when the condition compares two variables (e.g. function parameters `a > b`),
the generated code returns the wrong value when the `if` has no `else` clause.

- ✅ `if a > b { return 1; } else { return 0; }` → correct (returns 1 for `gt(5,3)`)
- ❌ `if a > b { return 1; } return 0;` → wrong (returns 0 for `gt(5,3)`)

Suspected root cause: checker or IR gen produces inverted branch logic for
two-variable comparisons without an else path. The self-hosted checker
(`src/compiler/checker.cr`) may handle the condition type (`TI_BOOL` vs `TI_INT`)
inconsistently.

### Python interpreter: `%` operator not supported

`build_selfhost.py` uses the Python bootstrap interpreter which doesn't
support the `%` (modulo) operator, raised as `NotImplementedError: op %`.
This affects `elf.cr` (byte encoding: `val % 256`) and `diag.cr` (error code
formatting: `ec % 1000`).

- `build_selfhost.py` has been broken since `diag.cr` was added
- The native build path (`build_selfhost_native.py`) is unaffected since
  it goes through the Python bootstrap's `X86_64StackAsmGen`, not the interpreter
- Fix: add `%` support to `bootstrap/corec/backend/interpreter.py`

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
