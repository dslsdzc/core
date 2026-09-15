# Core Programming Language

**English** | [中文](README.zh-CN.md)

![self-hosted](https://img.shields.io/badge/self--hosted-yes-blue)
![target](https://img.shields.io/badge/target-x86--64-lightgrey)
![license](https://img.shields.io/badge/license-GPLv3-blue)
![status](https://img.shields.io/badge/status-experimental-orange)

Core is an experimental programming language built around a semantic graph IR.
The compiler is self-hosted, emits native x86-64 ELF directly, and keeps regions,
state relations, provenance, and other program semantics through its IR instead of
reducing them early to a conventional machine model.

Core's compilation model is organized around graph → lattice → encoding: computation
is represented as relations first, state/storage is mapped separately, and machine
representation comes last.

```core
import io;

fn fib(n: int) -> int {
    if n < 2 {
        return n;
    }
    return fib(n - 1) + fib(n - 2);
}

fn main() -> int {
    io.println_i(fib(10));   // 55
    return 0;
}
```

Core is under active development.

## Features

- Self-hosting compiler with a reproducible three-stage bootstrap
- Native x86-64 ELF generation without an external assembler or linker
- Semantic graph IR with explicit regions, state edges, and provenance
- Graph → lattice → target encoding compilation model
- Raw pointers with compile-time pointer, region, and provenance analysis
- Arena-based memory management tied to program regions
- Cooperative fibers and channels
- Function-level incremental compilation through `.cir` snapshots
- Hardware Interface Tables for target-specific operations
- Generics, interfaces, enums, pattern matching, tuples, arrays, and slices
- Specifications use Core syntax; the verification backend is still under development

## Design

The **graph** represents computation and program relationships. The **lattice**
layer represents state and storage mappings. **Target encodings** map those
semantics onto a concrete execution model. Type, provenance, and specification
information remains available in the semantic IR through lowering, allowing
verification and optimization to operate before final target encoding.

See the [Project Book](docs/project-book.md),
[Execution Model](docs/maintainer/design/execution-model.md), and
[Memory Model](docs/maintainer/design/memory-model.md) for the full design.

## Status

Core is under active development and not ready for production use.

- The bootstrap chain is stable: the compiler builds itself in three stages, and
  stages 2 and 3 are byte-identical.
- The specification layer is designed but not implemented; the verification
  backend is a placeholder.
- Language, standard library, and tooling gaps are tracked in [TODO.md](TODO.md).

## Building

```bash
python3 build_selfhost_native.py
```

This produces `build/corec` (frontend) and `build/corearch` (backend).

## Usage

```bash
./build/corec run 'fn main() -> int { return 42; }'    # execute code (interpreter)
./build/corec check FILE.cr                             # type-check only
./build/corec build FILE.cr -o OUT --static             # compile to a native ELF binary
./build/corec cir FILE.cr                               # dump the dataflow graph
./build/corec ccr FILE.cr                               # dump the lattice-form IR
./build/corec clean-cache                               # clear the incremental cache
```

## Documentation

- [Project Book](docs/project-book.md) — design and rationale
- [Developer documentation](docs/developer/) — syntax reference and internals
- [Execution Model](docs/maintainer/design/execution-model.md) · [Memory Model](docs/maintainer/design/memory-model.md)
- [Error codes](docs/developer/errors.md)

## Contributing

The project is at an early stage; design discussion and experimental
implementation are welcome. See `docs/` for the current design documents.

## License

GNU General Public License v3.0 (with the GPLv3 §7 additional permission).
