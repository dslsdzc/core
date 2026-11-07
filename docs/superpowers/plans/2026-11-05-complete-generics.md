# Complete Generics Implementation Plan

> 定位：受众 = 维护者；状态 = 已完成；出处 = 本页。

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Implement the design in `docs/superpowers/specs/2026-11-05-complete-generics-design.md`: inferred generic parameters, interface constraints, primitive impls, deterministic solving, monomorphization, exported summaries, and generic `print`/`println`.

**Architecture:** Keep V4 inferred generics. Add constraint records beside the existing `g_generic_constr` side table. Generate constraints when generic method calls are resolved. Solve them while creating monomorphized instances. Static dispatch only. Primitive impl targets get the same method-table identity as named types.

**Tech Stack:** Core self-hosted compiler (`src/compiler/*.cr`), jj, targeted selfhost tests.

**Spec:** `docs/superpowers/specs/2026-11-05-complete-generics-design.md`

## Global Constraints

- Do not reintroduce explicit `fn f<T>` / `struct Box<T>` / `Box[int]` syntax.
- Keep the V4 inferred-generic corpus green (`test_v4_inference.py`, `test_v4_no_generic_syntax.py`).
- v1 scope: rank-1, non-overlapping impls, structurally decreasing instance chains, no type families, no higher-rank.
- Static generics must not add runtime tags or dictionary overhead when the impl is statically known.
- Every inferred constraint must be exported in the symbol table; no inference may depend on a private body at a call site.
- Existing `print_i` / `println_i` remain compatible during migration.
- Run targeted tests only; do not run the full suite after every edit.

## Review Focus

- Primitive receiver resolution: `impl Printable for int` must resolve `self` to `int`, not a named type.
- Method-name ambiguity: a generic method name matching multiple interfaces must fail closed.
- Missing impl: `println(true)` without `Printable(bool)` must be a compile error, not a runtime fault.
- Overlap/coherence: duplicate or overlapping impls must be rejected deterministically.
- Instance recursion: recursive impl/instance chains must terminate or fail with a diagnostic.
- Cache identity: an instance cache hit must include the impl solution ids.

---

### Task 1: Primitive impl targets

**Files:**
- Modify: `src/compiler/parser.cr` (impl branch, ~2666; `parse_body` ~1821)
- Modify: `src/compiler/checker.cr` (`check_impl_for` ~4133; `check_impl_coherence` ~2199)
- Modify: `src/compiler/iface_axis.cr` (`iface_user_satisfies` ~131)
- Test: `tests/selfhost/test_impl.py`

**Interfaces:**
- Produces: `impl Interface for int|string|bool|char|dex` parses, registers `g_impl_for`, and resolves `self` as the primitive type.
- Produces: `iface_user_satisfies` accepts `TYP_BASE` rows by mapping them to the same name key used by `g_methods`.

- [x] **Step 1: Add failing tests to `tests/selfhost/test_impl.py`**

Add a case that compiles and runs:

```core
interface P:
    fn r(self) -> string

impl P for int:
    fn r(self) -> string:
        return "int"

fn main() -> int:
    if 1.r() != "int":
        return 1
    return 0
```

Also add a negative case: `impl P for int` twice must be rejected.

- [x] **Step 2: Run the test and confirm it fails**

Run: `python3 tests/selfhost/test_impl.py`
Expected: failure mentioning `Undefined type 'int'`.

- [x] **Step 3: Parse the impl target as a type node**

In the `T_IMPL` branch, parse the target with `parse_type()` instead of
`advance_tok()`; keep the name-index key needed by `g_methods` (map base rows
to `int`/`string`/`bool`/`char`/`dex`). Pass the type node into `parse_body` so
the synthesized `self` node is a base-type node for primitives and an
`EXPR_IDENT` for named types.

- [x] **Step 4: Accept primitive rows in interface satisfaction**

In `iface_user_satisfies`, map `TYP_BASE` to its name key before
`iface_user_satisfies_ii`. Do not call `str_intern` for missing names; the
primitive names are already interned by the parser.

- [x] **Step 5: Fix coherence/orphan handling for primitive targets**

Treat a primitive type as local to the current library for orphan purposes, or
allow an impl when the interface is local. Keep duplicate/overlap detection.

- [x] **Step 6: Run and commit**

Run: `python3 tests/selfhost/test_impl.py`
Expected: PASS.

```bash
jj commit -m "generics: allow primitive impl targets"
```

### Task 2: Generic method constraint generation

**Files:**
- Modify: `src/compiler/checker.cr` (method call inference, `infer_expr` around the `EXPR_FIELD` method branch)
- Modify: `src/compiler/globals.cr` / `src/compiler/dyn_arr.cr` (inferred constraint side table)
- Test: `tests/selfhost/test_iface_ops.py`, new `tests/selfhost/test_generic_constraints.py`

**Interfaces:**
- Consumes: Task 1 primitive impl lookup.
- Produces: `infer_expr` records `Interface(TypeParam)` when a method is called on a generic parameter, and returns the method's declared return type.

- [x] **Step 1: Write the failing test**

```python
def test_generic_method_records_constraint():
    src = """interface P:
    fn r(self) -> string

impl P for int:
    fn r(self) -> string:
        return "int"

fn show(v):
    return v.r()

fn main() -> int:
    if show(1) != "int":
        return 1
    return 0
"""
    # compile, build, run; expect rc 0
```

Add a negative: calling `show(true)` without an impl must be rejected.

- [x] **Step 2: Run and observe the current failure**

Run: `python3 tests/selfhost/test_generic_constraints.py`
Expected: failure resolving `.r()` on the inferred generic parameter.

- [x] **Step 3: Record the constraint**

When the receiver type is `TYP_GENERIC_PARAM` (or the function's inferred
`__inferN`), search user interfaces for exactly one interface declaring the
method. Record `(function, type-param-index, interface-ni)` in the constraint
side table. If more than one interface matches, emit an ambiguity diagnostic.

- [x] **Step 4: Substitute the method return type**

Instantiate the interface method's return type with the receiver's type
parameter so the generic body type-checks without knowing the concrete type.

- [x] **Step 5: Export the constraint**

Include the inferred constraints in the function's generic metadata so later
call-site instantiation can check them.

- [x] **Step 6: Run and commit**

Run: `python3 tests/selfhost/test_generic_constraints.py`
Expected: positive case PASS; missing-impl negative rejected.

```bash
jj commit -m "generics: infer interface constraints from generic method calls"
```

### Task 3: Constraint solver and instance selection

**Files:**
- Modify: `src/compiler/checker.cr` (`gen_constr_satisfied`, `gen_inst_constr_satisfied`)
- Modify: `src/compiler/iface_axis.cr` (impl lookup by concrete row)
- Modify: `src/compiler/monomorph.cr` (constraint substitution before instance creation)
- Test: `tests/selfhost/test_generic_constraints.py`

**Interfaces:**
- Consumes: Task 2 exported constraints.
- Produces: `solve_constraints(instance_key)` returning a deterministic impl
  solution or a diagnostic; same input gives same solution.

- [x] **Step 1: Add failing tests**

Cover `Printable(int)`, `Printable(string)`, missing `Printable(bool)`,
duplicate impls, and a method name matching two interfaces.

- [x] **Step 2: Implement the finite solver**

For each instantiated constraint, find exactly one matching impl. Return
`1/0/-1` consistently: `1` solved, `0` missing/overlap, `-1` internal
uncertainty. Reject `-1` at the call site; never default silently.

- [x] **Step 3: Add cycle/termination guard**

Reject instance chains that revisit the same `(generic, type args)` without
structural decrease. Emit a diagnostic instead of looping.

- [x] **Step 4: Run and commit**

Run: `python3 tests/selfhost/test_generic_constraints.py`
Expected: all positive/negative cases pass.

```bash
jj commit -m "generics: solve interface constraints at instantiation"
```

### Task 4: Monomorphization with impl solutions

**Files:**
- Modify: `src/compiler/monomorph.cr` (instance key/cache)
- Modify: `src/compiler/ir_gen.cr` (method call emission inside generic bodies)
- Test: `tests/selfhost/test_generic_constraints.py`, `tests/selfhost/test_impl.py`

**Interfaces:**
- Consumes: Task 3 solver result.
- Produces: specialized functions whose method calls target the selected impl;
  cache key includes `(generic, type args, impl solution ids)`.

- [x] **Step 1: Add a failing nested-generic test**

```core
fn outer(v):
    return inner(v)

fn inner(v):
    return v.r()
```

Call with `int` and `string`; both must dispatch to the right impl.

- [x] **Step 2: Specialize method calls**

When generating a generic instance, replace the generic receiver method call
with a direct call to the mangled impl function selected by the solver.

- [x] **Step 3: Extend the cache key**

Include the solver's impl ids. Add a test that changes an impl selection and
proves the old instance is not reused.

- [x] **Step 4: Run and commit**

Run: `python3 tests/selfhost/test_generic_constraints.py`
Expected: PASS.

```bash
jj commit -m "generics: specialize impl calls during monomorphization"
```

### Task 5: Printable and generic print/println

**Files:**
- Modify: `src/stdlib/io.cr`
- Test: new `tests/selfhost/test_print_generic.py`

**Interfaces:**
- Consumes: Tasks 1-4.
- Produces: `println(fib(10))`, `println("x")`, `println(true)` work; missing
  printable types are compile errors; `print_i`/`println_i` still work.

- [x] **Step 1: Add the failing test**

```core
import io

fn fib(n: int) -> int:
    if n < 2:
        return n
    return fib(n - 1) + fib(n - 2)

fn main() -> int:
    println(fib(10))   // 55
    println("ok")
    println(true)
    return 0
```

Expected output: `55`, `ok`, `true`.

- [x] **Step 2: Add the interface and impls**

Implement `Printable` with `render` for `int`, `string`, and `bool`; use private
syscall wrappers (`write`) so `print`/`println` do not recurse.

- [x] **Step 3: Keep compatibility aliases**

Keep `print_i` / `println_i` calling the same implementation until all
callers/tests migrate.

- [x] **Step 4: Run and commit**

Run: `python3 tests/selfhost/test_print_generic.py`
Expected: PASS.

```bash
jj commit -m "stdlib: make print/println generic via Printable"
```

### Task 6: Cross-module and FFI constraint summaries

**Files:**
- Modify: `src/compiler/lib_manager.cr`, `src/compiler/module.cr`,
  `src/compiler/project.cr` (symbol/export summaries)
- Test: new `tests/selfhost/test_generic_modules.py`

**Interfaces:**
- Consumes: Tasks 2-4.
- Produces: a caller in another library can instantiate an exported generic
  function only when its exported constraint set is satisfied.

- [x] **Step 1: Add failing module test**

A library defines `fn show(v): return v.r()`, exports it, and a caller imports
it. `show(1)` succeeds when the library exports `P(int)`; `show(true)` fails
with a missing-impl diagnostic, not a runtime fault.

- [x] **Step 2: Export inferred constraints**

Store type-parameter count and constraint names with the exported function
symbol; load them in the importing compilation.

- [x] **Step 3: Require explicit constraints for extern/FFI**

Extern functions have no body, so inference cannot produce constraints. Add a
fail-closed diagnostic when a caller supplies a type that cannot be checked.

- [x] **Step 4: Run and commit**

Run: `python3 tests/selfhost/test_generic_modules.py`
Expected: PASS.

```bash
jj commit -m "generics: export constraints across modules"
```

### Task 7: Diagnostics, coherence, and the full matrix

**Files:**
- Modify: `src/compiler/checker.cr`, `src/compiler/diag.cr`
- Test: `tests/selfhost/test_generic_constraints.py`,
  `tests/selfhost/test_impl.py`, `tests/selfhost/test_iface_ops.py`,
  `tests/selfhost/test_v4_inference.py`

**Interfaces:**
- Produces: diagnostics for missing impl, ambiguous method, overlapping impl,
  orphan impl, and non-terminating instance chains.

- [x] **Step 1: Add negative cases**

Cover each diagnostic with a source fixture and assert code + location + zero
artifact.

- [x] **Step 2: Implement diagnostics**

Emit stable codes and include the concrete type/interface names; do not report
a missing impl as a generic runtime failure.

- [x] **Step 3: Run the targeted matrix**

Run each of the four test files. Expected: PASS, no regression in V4 inference
or primitive impl tests.

- [x] **Step 4: Commit**

```bash
jj commit -m "generics: diagnostics and coherence coverage"
```

## Self-Review

- Spec coverage: Tasks 1-7 cover primitive impls, inference, solving,
  monomorphization, Printable, cross-module, diagnostics.
- Type consistency: `Printable`/`render`, `solve_constraints`, instance key
  shape, and inferred constraint table names are used consistently.
- Review Focus: primitive self resolution, ambiguity, missing impl, overlap,
  recursion, cache identity each have a test in Tasks 1-4/7.
- Not covered by this plan: higher-rank types, type families, associated types,
  overlapping instance priorities. They are explicit non-goals in the spec.

## Implementation Status (2026-11-05)

Tasks 1-7 are implemented on top of PR #227 (`e1ddcee8`) with these concrete
choices:

- Constraint solving lives in `monomorph.cr`. `gen_compute_solution_key` maps
  each inferred `Interface(TypeParam)` to the concrete method-table identities
  (`Interface.method`) selected for the instance. A missing, ambiguous, or
  unjudgeable constraint returns an unsolved status and is never cached.
- The instance cache record is 32 bytes and includes the solution key string.
  A hit requires the same generic, type arguments, and solution key.
- `gen_creating_*` tracks in-progress instance keys and emits TG04 on a
  re-entered key. In the current rank-1 fragment the instance cache already
  breaks ordinary recursion; TG04 is the defensive guard for future instance
  chains. No source-level program in this fragment can force it today.
- Diagnostic codes: TG02 (missing/unsatisfied), TG03 (ambiguous generic method
  name across interfaces), TG04 (non-terminating instance chain). Duplicate
  impls keep N11; orphan impls were already covered by
  `test_pub_visibility.py`.
- `iface_user_satisfies` now maps `TYP_BASE` rows through the native registry,
  so primitive impls are judged directly instead of through the checker's
  fallback. `dyn` and generic-parameter rows remain unjudged (-1).
- Function checking visits generic templates before other functions. This is
  required for module order: the main unit is parsed before imported library
  functions, so a call site would otherwise miss a later template's inferred
  constraints and inferred return row.
- `tests/selfhost/test_generic_modules.py` covers exported generics and the
  missing-impl rejection across modules; inferred generic `extern`
  declarations are rejected by the parser (types are mandatory at the FFI
  boundary).
- Canary `gt_*` values were re-locked with attribution: PR #227's Printable
  implementation adds stdlib entities to every `import io` program. `pa` and
  the canary ELF are unchanged, and D1 determinism passes 5/5.
