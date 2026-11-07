// fnaddr_test.cr — subgraph reference and typed call test.
//
// `fn.square` is a subgraph reference. It can be called directly; the
// compiler lowers the reference to IR_FNADDR only at runtime boundaries.

import io

fn square(n: int) -> int:
    return n * n

fn main() -> int:
    f := fn.square
    if f(9) != 81:
        return 1
    return 0
