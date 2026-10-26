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

fn runtime_frontend_builtin_is_alloc(name_ni: int) -> int:
    if name_ni < 0:
        return 0
    if istr_get(name_ni) == "alloc":
        return 1
    return 0
