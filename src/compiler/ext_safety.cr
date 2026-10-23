// === ext_safety.cr ===
// Run-time safety checks registered as compiler hooks through ext_mgr.
// ext_mgr_init calls ext_safety_init to register this plugin. When a hook fires,
// ext_mgr calls the plugin handler.

// Plugin initialization: register hooks.
fn ext_safety_init():
    if ext_has(0) == 0:
        return
    // ext_mgr must be initialized first.
    ext_reg(EXT_HOOK_ARRAY_ACCESS, 1)  // array access
    ext_reg(EXT_HOOK_BINARY_OP, 1)     // binary operations

// Array bounds handler.
// Called before IR_LOAD_INDEX or IR_STORE_INDEX. idx_lit and arr_len_lit are
// compile-time values when non-negative. Returns 0 to continue. A compile-time
// out-of-bounds access still emits a trap check; it must not be skipped.
fn ext_safety_on_array_access(arr_var: int, idx_var: int, idx_lit: int, arr_len_lit: int) -> int:
    // Literal index and literal length: check at compile time. idx_var < 0 means
    // the index is a literal. idx_lit may be negative for arr[-1] and must be
    // rejected too.
    if arr_len_lit >= 0 && idx_var < 0:
        if idx_lit < 0 || idx_lit >= arr_len_lit:
            // Compile-time out-of-bounds access: emit the index constant and a
            // bounds check so the program traps at run time.
            tmp := new_ir_var("_oob_idx", TI_INT)
            emit(IR_CONST, tmp, idx_lit, 0, 0, TI_INT)
            emit(IR_BOUNDS_CHECK, -1, tmp, arr_len_lit, 0, 0)
        return 0
    // Variable index and literal length: emit a bounds check.
    if arr_len_lit >= 0 && idx_var >= 0:
        emit(IR_BOUNDS_CHECK, -1, idx_var, arr_len_lit, 0, 0)
        return 0
    return 0

// Arithmetic overflow handler (reserved).
fn ext_safety_on_binary_op(op: int, lv: int, rv: int, result_var: int) -> int:
    return 0
