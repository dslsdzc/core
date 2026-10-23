// === ext_mgr.cr ===
// Compiler extension manager: plugin registry and hook dispatch.
//
// Plugins register the hooks they handle through ext_reg. pass.cr dispatches
// hooks through ext_dispatch, which walks the registry and calls each matching
// plugin. Plugin ids are defined in ext_plugins.cr; EXT_PLUGIN_SAFETY is 1.

g_ext_flags : int, mut = 0
g_ext_inited : int, mut = 0

// Plugin registry: flat array of [hook_type, plugin_id] pairs.
g_ext_reg : string, mut
g_ext_reg_count : int, mut
g_ext_reg_cap : int, mut

// Hook types.
EXT_HOOK_ARRAY_ACCESS : int = 1  // before an array access
EXT_HOOK_BINARY_OP    : int = 2  // after a binary operation

fn grow_ext_reg(needed: int):
    if needed < g_ext_reg_cap:
        return
    ncap : ., mut = g_ext_reg_cap * 2
    if ncap < 8:
        ncap = 8
    if ncap < needed:
        ncap = needed + 8
    // Each record is 16 bytes: hook_type at offset 0 and plugin_id at offset 8.
    // An 8-byte stride would overlap the two fields and break dispatch.
    nb := alloc(ncap * 16)
    cell_copy(g_ext_reg, g_ext_reg_cap * 16, nb)
    g_ext_reg = nb
    g_ext_reg_cap = ncap

fn ext_init():
    if g_ext_inited != 0:
        return
    g_ext_inited = 1
    g_ext_reg_cap = 0
    g_ext_reg_count = 0
    // Bounds checks are part of Core's safety contract and are on by default.
    // CORE_SAFE=0 disables them for unsafe debugging; CORE_SAFE=1 keeps them on.
    ev := get_env("CORE_SAFE")
    if str_len(ev) > 0 && ev == "0":
        g_ext_flags = 0
    else:
        g_ext_flags = 1
    // Initialize built-in plugins. Future plugins may load from shared objects.
    ext_safety_init()

fn ext_has(flag: int) -> int:
    if g_ext_inited == 0:
        ext_init()
    return g_ext_flags

// Register a plugin for a hook.
fn ext_reg(hook_type: int, plugin_id: int):
    grow_ext_reg(g_ext_reg_count + 1)
    cell_store(g_ext_reg, g_ext_reg_count * 16, hook_type)
    cell_store(g_ext_reg, g_ext_reg_count * 16 + 8, plugin_id)
    g_ext_reg_count = g_ext_reg_count + 1

// Dispatch an array access hook. arr_var, idx_var, idx_lit, and arr_len_lit are
// the access operands. Returns 0 to continue and 1 to skip the access.
fn ext_dispatch_array_access(arr_var: int, idx_var: int, idx_lit: int, arr_len_lit: int) -> int:
    if g_ext_inited == 0:
        ext_init()
    ri : ., mut = 0
    loop:
        if ri >= g_ext_reg_count:
            break
        ht := cell_load(g_ext_reg, ri * 16)
        pid := cell_load(g_ext_reg, ri * 16 + 8)
        if ht == EXT_HOOK_ARRAY_ACCESS:
            if pid == 1:
                // EXT_PLUGIN_SAFETY
                r := ext_safety_on_array_access(arr_var, idx_var, idx_lit, arr_len_lit)
                if r != 0:
                    return r
        ri = ri + 1
    return 0

// Dispatch a binary operation hook.
fn ext_dispatch_binary_op(op: int, lv: int, rv: int, result_var: int) -> int:
    if g_ext_inited == 0:
        ext_init()
    ri : ., mut = 0
    loop:
        if ri >= g_ext_reg_count:
            break
        ht := cell_load(g_ext_reg, ri * 16)
        pid := cell_load(g_ext_reg, ri * 16 + 8)
        if ht == EXT_HOOK_BINARY_OP:
            if pid == 1:
                return ext_safety_on_binary_op(op, lv, rv, result_var)
        ri = ri + 1
    return 0
