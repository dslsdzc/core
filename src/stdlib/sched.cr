// Scheduler compatibility entry.
//
// CP-6 retired the legacy 0A G queues and goroutine wrapper. `sched_init` /
// `sched_init_n` now configure the conc scheduler, and workers delegate to
// conc_worker_run. Only the persistent-object bump block remains here.
import conc_sched
import chan
import arena

g_num_workers : int, mut = 0
g_sched_inited : int, mut = 0

// Per-M bump block for persistent runtime objects (result channels).
PERSIST_PER_M : int = 4194304   // 4 MiB per M
PERSIST_ALIGN : int = 16
g_persist_base : string, mut
g_persist_ptr : string, mut
g_persist_cap : string, mut


fn sched_init(), pub:
    sched_init_n(1)

fn sched_init_slots(m: int, slots: int), pub:
    conc_sched_set_slots(slots)
    sched_init_n(m)

fn sched_init_n(n: int), pub:
    if g_sched_inited != 0:
        return
    if n < 1:
        n = 1
    // Reserve one extra M partition for shared runtime metadata (scheduler
    // arrays, channel regions). Worker homes stay in 0..n-1.
    arena_init_m(g_arena_pool_limit, 1048576, n + 1)
    conc_sched_set_m(n)
    conc_sched_init()


    g_persist_base = alloc(n * 8)
    g_persist_ptr = alloc(n * 8)
    g_persist_cap = alloc(n * 8)
    pi : ., mut = 0
    loop:
        if pi >= n:
            break
        blk := alloc(PERSIST_PER_M)
        cell_store(g_persist_base, pi * 8, blk)
        cell_store(g_persist_ptr, pi * 8, blk)
        cell_store(g_persist_cap, pi * 8, PERSIST_PER_M)
        pi = pi + 1
    // Main thread is G0, permanently pinned to M0. Its stack_ptr is filled
    // by fiber_switch on the first yield.
    main_g := alloc(104)
    cell_store(main_g, 0, 0)      // id
    cell_store(main_g, 8, 1)      // _Grunning
    cell_store(main_g, 16, 0)     // stack_ptr
    cell_store(main_g, 24, 0)     // stack_lo (OS thread stack)
    cell_store(main_g, 32, -1)    // arena_id
    cell_store(main_g, 40, -1)    // result_ch
    cell_store(main_g, 48, -1)    // next
    cell_store(main_g, 56, 0)     // saved_fn
    cell_store(main_g, 64, 0)     // saved_arg
    cell_store(main_g, 72, 0)     // temp_val
    cell_store(main_g, 80, -1)    // saved_current_arena
    cell_store(main_g, 88, 0)     // home_m
    cell_store(main_g, 96, -1)    // dead_next

    g_num_workers = n - 1
    g_set_curg(main_g)
    g_sched_inited = 1

    if n > 1:
        sched_spawn_workers(n)

fn sched_current_m_idx() -> int:
    return rt_m_idx()

fn sched_get_curg() -> int, pub:
    return g_get_curg()

fn sched_worker_run(m_idx: int):
    // CP-5 multi-M: worker threads run the conc scheduler with per-M TLS.
    conc_worker_run(m_idx)

fn rt_alloc_persistent(size: int) -> string:
    m : ., mut = rt_m_idx()
    if m < 0:
        m = 0
    base := cell_load(g_persist_base, m * 8)
    ptr := cell_load(g_persist_ptr, m * 8)
    cap := cell_load(g_persist_cap, m * 8)
    aligned := (size + 15) / 8 * 8
    if ptr + aligned > base + cap:
        return ""
    cell_store(g_persist_ptr, m * 8, ptr + aligned)
    p : ., mut = ""
    unsafe:
        p = @str_of(ptr)
    return p

fn sched_go(fn_ptr: int, arg: int) -> string, pub:
    // CP-4 default path: go/chan run on the conc activation scheduler.
    conc_sched_init()
    return conc_go(fn_ptr, arg)

fn sched_spawn_workers(n: int), pub:
    if n <= 1:
        return
    g_num_workers = n - 1
    m_start_workers(n)


