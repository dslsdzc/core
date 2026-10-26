// === arch/x86_64/frontend_abi.cr ===
// Architecture-axis frontend ABI builtins.
//
// SYSTEM / RAW RUNTIME ABI BOUNDARY — NOT ORDINARY LANGUAGE API.
// The fixed-width raw memory and string-header view builtins below are part of
// the SYSTEM runtime ABI, not the public language surface. They remain registered
// because the stdlib scheduler/arena and the compiler runtime still use them.
// Programs that call them must be declared SYSTEM at the header level. The
// fixed-width raw aliases w64/r64 are retired; use the cell accessors instead.
// Replacing these with a public `Bytes` layer is a separate, stdlib-wide task.
//
// Fixed-width raw memory and string-header view names are x86-64 facts. The
// semantic checker does not own them; it consumes the target composition table
// through prelude_builtin_*.

fn x86_frontend_builtin_register():
    prelude_builtin_add("load8", TI_INT, 1)
    prelude_builtin_add("store8", TI_INT, 1)
    prelude_builtin_add("load64", TI_INT, 1)
    prelude_builtin_add("cell_load", TI_INT, 0)
    prelude_builtin_add("w32", TI_UNIT, 1)
    prelude_builtin_add("cell_store", TI_UNIT, 0)
    prelude_builtin_add("_dyncpy", TI_UNIT, 1)
    prelude_builtin_add("load_str_ptr", TI_STR, 1)
    prelude_builtin_add("store_str_ptr", TI_INT, 1)

fn x86_frontend_builtin_is_str_ptr_load(name: string) -> int:
    if name == "load_str_ptr":
        return 1
    return 0

fn x86_frontend_builtin_is_str_ptr_store(name: string) -> int:
    if name == "store_str_ptr":
        return 1
    return 0
