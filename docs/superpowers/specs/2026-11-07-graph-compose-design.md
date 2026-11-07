# Graph Composition `>|` Design (v1)

> 定位：受众 = 维护者；状态 = 设计态；出处 = 本页。

## Goal

Add `f >| g` as a pending graph closure: it does not execute anything when
defined; calling it executes `f` then `g`.

```text
f >| g  ≡  λx. g(f(x))
```

This is graph/function composition, not a first-class runtime function value.
The operands are compile-time graph references.

## Type rule

```text
f : fn(A) -> B
g : fn(B) -> C
⟹ f >| g : fn(A) -> C
```

- Both operands must be unary.
- The middle types must be exactly equal; no implicit conversion.
- `>|` is left-associative; `f >| g >| h` is equivalent to either grouping.
- `f` and `g` may be named functions (`fn.square` or a bare top-level name),
  lambdas, or local graph aliases.

## Lowering

- `fn.name`, lambdas, and compositions become hidden top-level functions with
  unique names (`__graph$...`).
- A composition hidden function has one parameter `x` and body
  `return right(left(x))`.
- The value is materialized with `IR_FNADDR` into a local variable of the graph
  alias. Calls are still rewritten to direct calls to the hidden/original
  function, so no indirect-call ABI is needed.
- `@addr(fn)` remains a raw `int` and is not interchangeable with a function
  type.

## Restrictions (v1)

- No capture of outer local variables or parameters. The compiler checks the
  lambda body against its own parameter set and rejects a capture.
- No passing, returning, or storing a graph alias as a value.
- No callable parameters or callable return types.
- No graph expressions inside generic functions.
- No function-value equality; composition is a compile-time graph identity.
- No generic function references and no methods (`fn.Type.method`).
- Nested lambdas are not a supported surface in this version.

## Type representation

Function signatures use a synthetic `TYP_NAMED` row whose name is a canonical
signature key (`fn(int) -> int`). A checker side table maps the row back to its
parameter and return types. The row is created on demand and deduplicated by
name; programs that do not use graph syntax do not add rows or change `.ccr`
output.

## Diagnostics

- `TF07` for composition type mismatch, non-graph operands, missing lambda
  parameter types, captures, unsupported callable parameters, and graph use in
  a generic function.
- `N06` for an undefined function reference.

## Non-goals

- First-class runtime function values.
- Closures with captured environments.
- Currying, partial application, operator sections.
- Higher-order callable parameters.
