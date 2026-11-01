// === runtime/frontend_abi.cr ===
// Runtime/execution-strategy frontend ABI builtins.
//
// Allocation and scheduler/fiber entry points are runtime policy, not target
// value layout. They stay on the runtime axis and are composed by the target
// root; the checker only receives their return types.
//
// The same names are SYSTEM boundaries in the graph classifier
// (ccr_io.cr:ccr_raw_abi_builtin). A direct call must mark the .ccr header
// SYSTEM, so adding a name here requires adding it there too.

fn runtime_frontend_builtin_register():
    prelude_builtin_add("alloc", TI_STR, 0)
    prelude_builtin_add("load_str_ptr", TI_STR, 0)
    prelude_builtin_add("store_str_ptr", TI_INT, 0)
    prelude_builtin_add("sched_call_0", TI_INT, 0)
    prelude_builtin_add("sched_call_1", TI_INT, 0)
    prelude_builtin_add("sched_call_2", TI_INT, 0)
    prelude_builtin_add("sched_call_3", TI_INT, 0)
    prelude_builtin_add("sched_call_4", TI_INT, 0)
    prelude_builtin_add("fiber_switch", TI_INT, 0)
    prelude_builtin_add("fiber_init", TI_INT, 0)
    prelude_builtin_add("sched_go", TI_INT, 0)
    prelude_builtin_add("m_start_workers", TI_UNIT, 0)
    prelude_builtin_add("g_set_curg", TI_UNIT, 0)
    prelude_builtin_add("g_get_curg", TI_INT, 0)
    prelude_builtin_add("rt_m_idx", TI_INT, 0)
    prelude_builtin_add("rt_current_arena", TI_INT, 0)
    prelude_builtin_add("rt_set_current_arena", TI_UNIT, 0)
    prelude_builtin_add("rt_arena_suspend", TI_INT, 0)
    prelude_builtin_add("rt_set_arena_suspend", TI_UNIT, 0)
    prelude_builtin_add("rt_atomic_load", TI_INT, 0)
    prelude_builtin_add("rt_atomic_store", TI_UNIT, 0)
    prelude_builtin_add("rt_atomic_xchg", TI_INT, 0)
    prelude_builtin_add("rt_atomic_cas", TI_INT, 0)
    prelude_builtin_add("rt_atomic_fetch_add", TI_INT, 0)

fn runtime_frontend_builtin_is_alloc(name_ni: int) -> int:
    if name_ni < 0:
        return 0
    if istr_get(name_ni) == "alloc":
        return 1
    return 0
