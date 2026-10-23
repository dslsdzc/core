// === arch/x86_64/frontend_abi.cr ===
// Architecture-axis frontend ABI builtins.
//
// Fixed-width raw memory and string-header view names are x86-64 facts. The
// semantic checker does not own them; it consumes the target composition table
// through prelude_builtin_*.

fn x86_frontend_builtin_register():
    prelude_builtin_add("load8", TI_INT)
    prelude_builtin_add("store8", TI_INT)
    prelude_builtin_add("load64", TI_INT)
    prelude_builtin_add("cell_load", TI_INT)
    prelude_builtin_add("w32", TI_UNIT)
    prelude_builtin_add("cell_store", TI_UNIT)
    prelude_builtin_add("_dyncpy", TI_UNIT)
    prelude_builtin_add("load_str_ptr", TI_STR)
    prelude_builtin_add("store_str_ptr", TI_INT)

fn x86_frontend_builtin_is_str_ptr_load(name: string) -> int:
    if name == "load_str_ptr":
        return 1
    return 0

fn x86_frontend_builtin_is_str_ptr_store(name: string) -> int:
    if name == "store_str_ptr":
        return 1
    return 0
