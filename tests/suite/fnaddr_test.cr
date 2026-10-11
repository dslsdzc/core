// fnaddr_test.cr — @addr(fn) function-address mechanism.
//
// `@addr(fn)` evaluates to the function's runtime address (an int), resolved
// at ELF link time by the backend. This is the last piece needed for `go f()`
// end-to-end: goroutine_entry_wrapper needs a function pointer to call.

import io

fn square(n: int) -> int:
    return n * n

fn main() -> int:
    addr := @addr(square)
    if addr == 0:
        return 1
    // address should be non-zero
    return 0
