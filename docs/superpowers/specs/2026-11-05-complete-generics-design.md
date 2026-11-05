# Complete Generics Design (V4+)

## Goal

Make Core generics complete for closed-world programs without reintroducing
the V4-removed explicit generic syntax:

- inferred type parameters (`fn f(x)`, `x: .`, `x: auto`, `field: .`)
- interfaces as constraints
- `impl Interface for Type`, including primitive types
- constraint inference from generic bodies
- deterministic constraint solving during monomorphization
- exported constraint summaries for separate compilation and FFI
- static dispatch (dictionaries or direct impl calls); no runtime tags for
  static generics

## Non-goals (v1)

- higher-rank polymorphism
- type families / associated types
- overlapping instance selection
- runtime type introspection for static generics
- explicit `fn f<T>` / `struct Box<T>` syntax

These can be added later only after their decidability/coherence rules are
specified.

## Syntax

Keep V4 inference:

```core
fn id(v):
    return v

struct Box:
    val: .
```

Optional boundary constraint syntax may be added later for public APIs and
ambiguous cases; it is not required for ordinary code. The exact spelling is
deliberately not fixed in this design.

## Semantic model

```text
TypeParam      inferred or boundary-declared type variable
Constraint     Interface(TypeParam)
Interface      method set; usable as a constraint
Impl           impl Interface for Type (primitive or named)
Instance       generic symbol + concrete type arguments + impl solution
Dictionary     static evidence passed to a monomorphized instance
```

## Inference

Generate constraints while checking a generic body:

- method call `x.m()` on a generic `x` → `x: InterfaceWithM`
- call to another generic function → merge its constraint set
- operators/index/deref → built-in constraints or dedicated rules
- `print(x)` / `println(x)` → `Printable(x)` once print is generic

If a method name matches more than one interface, require an explicit
boundary annotation or reject as ambiguous. Never silently choose one.

## Solving

At each instantiation:

1. substitute concrete type arguments into the constraint set
2. look up exactly one impl per constraint
3. reject missing, overlapping, or ambiguous impls
4. reject recursive instance chains that do not decrease structurally
5. cache the solution with the instance

The v1 fragment (rank-1, non-overlapping, structurally decreasing instances,
no type families) is intended to be decidable.

## Monomorphization

Instance key:

```text
(generic symbol, concrete type arguments, impl solution ids)
```

The body is specialized with direct impl calls (or explicit dictionaries).
Polymorphic recursion requires a boundary signature; otherwise reject infinite
instance growth. Cache keys include the impl solution so changing an impl
invalidates dependent instances.

## Separate compilation / FFI

Exported generic symbols carry:

- type parameter count
- inferred or declared constraint set
- interface/impl visibility metadata

Callers instantiate against that summary. Extern/FFI symbols have no body and
must declare their constraints; inference cannot invent them.

## Printable / print

```core
interface Printable:
    fn render(self) -> string

impl Printable for int:
    fn render(self) -> string:
        return int_str(self)

impl Printable for string:
    fn render(self) -> string:
        return self

impl Printable for bool:
    fn render(self) -> string:
        return bool_str(self)

fn println(v):
    write(v.render())
    write("\n")
```

`write` is the private syscall wrapper; `print`/`println` become generic.
The old `print_i`/`println_i` names remain compatibility aliases during the
migration.

## Migration order

1. primitive impl targets and primitive satisfaction
2. generic method constraint generation
3. constraint side table and exported signatures
4. solver, coherence, termination
5. monomorphization dictionaries/instance keys
6. Printable and generic print
7. cross-module/FFI summaries
8. diagnostics and full matrix
