// === prelude.cr ===
// Frontend prelude: configuration read at process start and the small set of
// externally provided builtins. The concrete ABI names live in the target's
// frontend_abi.cr; this file only owns the table and its reset.

g_rt_builtin_count : int, mut
g_rt_builtin_names : string, mut
g_rt_builtin_ret_types : string, mut
// 0 = public ABI (visible to user libraries), 1 = raw/system ABI
// (std/core only; user symbol tables must not contain the name).
g_rt_builtin_vis : string, mut

BUILTIN_VIS_PUBLIC : int = 0
BUILTIN_VIS_INTERNAL : int = 1

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
    g_rt_builtin_vis = alloc(8 * 8)
    target_builtin_register()

fn prelude_builtin_add(name: string, ret_ti: int, vis: int):
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
    if g_rt_builtin_count * 8 + 8 > str_len(g_rt_builtin_vis):
        nc := g_rt_builtin_count * 2 + 16
        nb := alloc(nc * 8)
        cell_copy(g_rt_builtin_vis, g_rt_builtin_count * 8, nb)
        g_rt_builtin_vis = nb
    cell_store(g_rt_builtin_names, g_rt_builtin_count * 8, ni)
    cell_store(g_rt_builtin_ret_types, g_rt_builtin_count * 8, ret_ti)
    cell_store(g_rt_builtin_vis, g_rt_builtin_count * 8, vis)
    g_rt_builtin_count = g_rt_builtin_count + 1

fn prelude_builtin_find(name_ni: int) -> int:
    i : ., mut = 0
    loop:
        if i >= g_rt_builtin_count:
            return -1
        if cell_load(g_rt_builtin_names, i * 8) == name_ni:
            return i
        i = i + 1
    return -1

fn prelude_builtin_visible_to_current_lib(vis: int) -> int:
    if vis == BUILTIN_VIS_PUBLIC:
        return 1
    // The raw/system ABI is deliberately absent from user symbol tables even
    // when the pub layer is off (ordinary user programs). Only code owned by
    // the standard library or the compiler may name it.
    if g_cur_lib < 0:
        return 1
    if g_cur_lib == lib_find("@std") || g_cur_lib == lib_find("@core"):
        return 1
    return 0

fn prelude_builtin_return_ti(name_ni: int) -> int:
    bi := prelude_builtin_find(name_ni)
    if bi >= 0:
        if prelude_builtin_visible_to_current_lib(cell_load(g_rt_builtin_vis, bi * 8)) != 0:
            return cell_load(g_rt_builtin_ret_types, bi * 8)
        return -1
    return target_builtin_return_ti(name_ni)

