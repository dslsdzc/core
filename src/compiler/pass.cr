// === pass.cr ===
// IR-level pass dispatcher.
//
// Future: .so plugin hooks registered here. Currently empty.

fn dispatch_call(fn_ni: int, ac: int, arg_vars: string) -> int {
    return -1;  // no builtin expansions — all handled by stdlib/.so
}
