// === prelude.cr ===
// Frontend prelude: configuration read at process start and the small set of
// externally provided builtins.

fn prelude_init():
    g_s1p_seen = 1
    g_s1p_on = 0
    ev2 := get_env("CORE_S1P")
    if str_len(ev2) > 0 && ev2 == "1":
        g_s1p_on = 1

fn prelude_builtin_return_ti(name_ni: int) -> int:
    if name_ni < 0:
        return -1
    s := istr_get(name_ni)
    if s == "syscall3":
        return TI_INT
    if s == "syscall4":
        return TI_INT
    return -1
