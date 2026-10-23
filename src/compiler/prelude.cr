// === prelude.cr ===
// Frontend prelude: configuration read at process start and the small set of
// externally provided builtins. The concrete ABI names live in the target's
// frontend_abi.cr; this file only owns the table and its reset.

g_rt_builtin_count : int, mut
g_rt_builtin_names : string, mut
g_rt_builtin_ret_types : string, mut

fn prelude_init():
    g_s1p_seen = 1
    g_s1p_on = 0
    ev2 := get_env("CORE_S1P")
    if str_len(ev2) > 0 && ev2 == "1":
        g_s1p_on = 1

fn prelude_builtin_init():
    g_rt_builtin_count = 0
    g_rt_builtin_names = alloc(8 * 8)
    g_rt_builtin_ret_types = alloc(8 * 8)
    target_builtin_register()

fn prelude_builtin_add(name: string, ret_ti: int):
    ni := str_intern(name)
    if g_rt_builtin_count * 8 + 8 > str_len(g_rt_builtin_names):
        nc := g_rt_builtin_count * 2 + 16
        nb := alloc(nc * 8)
        cell_copy(g_rt_builtin_names, g_rt_builtin_count * 8, nb)
        g_rt_builtin_names = nb
    if g_rt_builtin_count * 8 + 8 > str_len(g_rt_builtin_ret_types):
        nc := g_rt_builtin_count * 2 + 16
        nb := alloc(nc * 8)
        cell_copy(g_rt_builtin_ret_types, g_rt_builtin_count * 8, nb)
        g_rt_builtin_ret_types = nb
    cell_store(g_rt_builtin_names, g_rt_builtin_count * 8, ni)
    cell_store(g_rt_builtin_ret_types, g_rt_builtin_count * 8, ret_ti)
    g_rt_builtin_count = g_rt_builtin_count + 1

fn prelude_builtin_return_ti(name_ni: int) -> int:
    return target_builtin_return_ti(name_ni)

