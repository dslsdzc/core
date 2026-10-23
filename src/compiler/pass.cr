// === pass.cr ===
// Compiler extension hook dispatcher between the core and plugins.
// The core calls pass_* at key points. Each pass_* forwards to registered plugins
// through ext_mgr.
// Adding a plugin does not require editing this file; register its handler in
// ext_plugins.cr. The core only needs a pass_* call site.

// Before an array access; called by ir_gen before IR_LOAD_INDEX and
// IR_STORE_INDEX. Returns 0 to continue and 1 to skip the access.
fn pass_before_array_access(arr_var: int, idx_var: int, idx_lit: int, arr_len_lit: int) -> int:
    return ext_dispatch_array_access(arr_var, idx_var, idx_lit, arr_len_lit)

// After a binary operation, for overflow checks.
fn pass_after_binary(op: int, lv: int, rv: int, result_var: int) -> int:
    return ext_dispatch_binary_op(op, lv, rv, result_var)

// Builtin expansion registered by shared-object or stdlib plugins.
fn dispatch_call(fn_ni: int, ac: int, arg_vars: string) -> int:
    return -1
