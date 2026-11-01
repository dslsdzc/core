// M:N scheduler — 0A lock-free foundation.
//
// Gs are pinned to their home M (G+88). Each M owns one tagged Treiber stack
// (M+16). Producers CAS-push; the owner is the only popper. The 15-bit tag in
// bits 48..62 prevents ABA while keeping the value positive in Core ints.
//
// 0A is still single-M by default (sched_init); sched_init_n(n) is the
// explicit multi-M entry point. Work stealing and futex idling are 0C.
import conc_sched
import goroutine
import chan
import arena

// M struct (48 bytes): id(0), cur_g(8), ready_head(16), sched_sp(24),
// spawn_head(32), pad(40).
g_machines : string, mut
g_machine_count : int, mut
g_num_workers : int, mut = 0
g_sched_inited : int, mut = 0

// Per-M deferred-reclamation list and per-M G id counter.
g_dead_head_m : string, mut
g_next_id_m : string, mut

// 0A spawn distribution: a G must be created on its home M, so a spawn for
// another M is a request node {fn,arg,result_ch,next} pushed to that M.
MAX_SPAWN_REQ : int = 8192
g_spawn_req_buf : string, mut
g_spawn_req_next : string, mut
g_spawn_rr : string, mut

// Per-M bump block for persistent runtime objects (result channels).
PERSIST_PER_M : int = 4194304   // 4 MiB per M
PERSIST_ALIGN : int = 16
g_persist_base : string, mut
g_persist_ptr : string, mut
g_persist_cap : string, mut


// Tagged head: (tag << 48) | 48-bit user address.
PTR_MASK : int = 281474976710656   // 2^48
TAG_MAX : int = 32767

fn sched_init(), pub:
    sched_init_n(1)

fn sched_init_n(n: int), pub:
    if g_sched_inited != 0:
        return
    if n < 1:
        n = 1

    arena_init_m(g_arena_pool_limit, 1048576, n)

    m := alloc(n * 48)
    g_dead_head_m = alloc(n * 8)
    g_next_id_m = alloc(n * 8)
    g_spawn_req_buf = alloc(MAX_SPAWN_REQ * 32)
    g_spawn_req_next = alloc(8)
    g_spawn_rr = alloc(8)
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
    rt_atomic_store(g_spawn_req_next, 0, 0)
    rt_atomic_store(g_spawn_rr, 0, 0)

    mi : ., mut = 0
    loop:
        if mi >= n:
            break
        cell_store(m, mi * 48, mi)        // id
        cell_store(m, mi * 48 + 8, -1)    // cur_g
        cell_store(m, mi * 48 + 16, 0)    // ready_head = (tag 0, ptr 0)
        cell_store(m, mi * 48 + 24, 0)    // sched_sp
        cell_store(m, mi * 48 + 32, 0)    // spawn_head (Task 5)
        cell_store(g_dead_head_m, mi * 8, -1)
        cell_store(g_next_id_m, mi * 8, 1)
        mi = mi + 1

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

    g_machines = m
    g_machine_count = n
    g_num_workers = n - 1
    cell_store(m, 8, main_g)
    g_set_curg(main_g)
    g_sched_inited = 1

    if n > 1:
        sched_spawn_workers(n)

fn sched_current_m_idx() -> int:
    return rt_m_idx()

fn sched_get_curg() -> int, pub:
    return g_get_curg()

fn sched_enqueue(g: string):
    hm : ., mut = cell_load(g, 88)
    if hm < 0:
        hm = 0
    m := g_machines + hm * 48
    gp : ., mut = 0
    unsafe:
        gp = @ptr_of(g)
    loop:
        old := rt_atomic_load(m, 16)
        tag : ., mut = old / PTR_MASK + 1
        if tag > TAG_MAX:
            tag = 1
        ptr := old % PTR_MASK
        cell_store(g, 48, ptr)
        newv := tag * PTR_MASK + gp
        if rt_atomic_cas(m, 16, old, newv) != 0:
            return

fn sched_dequeue(m_idx: int) -> int:
    if m_idx < 0:
        m_idx = 0
    m := g_machines + m_idx * 48
    loop:
        old := rt_atomic_load(m, 16)
        ptr := old % PTR_MASK
        if ptr == 0:
            return -1
        nxt := cell_load(ptr, 48)
        tag : ., mut = old / PTR_MASK + 1
        if tag > TAG_MAX:
            tag = 1
        newv := tag * PTR_MASK + nxt
        if rt_atomic_cas(m, 16, old, newv) != 0:
            cell_store(ptr, 48, -1)
            return ptr

fn sched_reap_dead(m_idx: int, cur_g: int), pub:
    prev : ., mut = -1
    g : ., mut = cell_load(g_dead_head_m, m_idx * 8)
    loop:
        if g < 0:
            break
        nxt := cell_load(g, 96)
        if g == cur_g:
            prev = g
            g = nxt
            continue
        if prev < 0:
            cell_store(g_dead_head_m, m_idx * 8, nxt)
        else:
            cell_store(prev, 96, nxt)
        aid := cell_load(g, 32)
        saved := rt_current_arena()
        arena_reset(aid)
        rt_set_current_arena(saved)
        g = nxt

fn sched_yield():
    cur_g := sched_get_curg()
    if cur_g >= 0:
        st := rt_atomic_load(cur_g, 8)
        if st != 2 && st != 3:
            rt_atomic_store(cur_g, 8, 0)
            sched_enqueue(cur_g)
    sched_schedule()

// sched_schedule: switch from the current G to the next queued G on this M.
// Blocking paths must call this directly, not sched_yield: a waker may have
// already pushed the blocked G, and re-enqueueing would duplicate it.
fn sched_schedule():
    m_idx := sched_current_m_idx()
    old_g := sched_get_curg()
    sched_reap_dead(m_idx, old_g)

    next_g : ., mut = -1
    loop:
        sched_process_spawns(m_idx)
        next_g = sched_dequeue(m_idx)
        if next_g >= 0:
            if next_g == old_g:
                if rt_atomic_load(old_g, 8) == 3:
                    // Dead self-entry left by a spurious wake: discard.
                    continue
                return
            break
        if old_g < 0:
            return
        if m_idx == 0:
            // main M has no scheduler stack; spin until work/wake.
            continue
        // Worker with no runnable G: park on the scheduler stack.
        m := g_machines + m_idx * 48
        cell_store(old_g, 80, arena_current_unchecked())
        cell_store(m, 8, -1)
        g_set_curg(-1)
        fiber_switch(@ptr_add(old_g, 16), cell_load(m, 24))
        return

    m := g_machines + m_idx * 48
    cell_store(m, 8, next_g)
    g_set_curg(next_g)
    rt_atomic_store(next_g, 8, 1)

    if old_g >= 0:
        cell_store(old_g, 80, arena_current_unchecked())
    next_cur : ., mut = cell_load(next_g, 80)
    if next_cur < 0:
        next_cur = cell_load(next_g, 32)
    arena_set_current_unchecked(next_cur)

    if old_g >= 0:
        old_sp_addr := @ptr_add(old_g, 16)
        next_sp := cell_load(next_g, 16)
        fiber_switch(old_sp_addr, next_sp)
        arena_set_current_unchecked(cell_load(old_g, 80))

// Worker entry: scheduler stack runs here; Gs are entered by fiber_switch.
fn sched_worker_run(m_idx: int):
    cell_store(g_machines, m_idx * 48, m_idx)
    loop:
        sched_process_spawns(m_idx)
        sched_reap_dead(m_idx, -1)
        next_g := sched_dequeue(m_idx)
        if next_g >= 0:
            m := g_machines + m_idx * 48
            cell_store(m, 8, next_g)
            g_set_curg(next_g)
            rt_atomic_store(next_g, 8, 1)
            next_cur : ., mut = cell_load(next_g, 80)
            if next_cur < 0:
                next_cur = cell_load(next_g, 32)
            arena_set_current_unchecked(next_cur)
            fiber_switch(@ptr_add(m, 24), cell_load(next_g, 16))
            g_set_curg(-1)

fn sched_push_spawn(m_idx: int, req: string):
    m := g_machines + m_idx * 48
    rp : ., mut = 0
    unsafe:
        rp = @ptr_of(req)
    loop:
        old := rt_atomic_load(m, 32)
        tag : ., mut = old / PTR_MASK + 1
        if tag > TAG_MAX:
            tag = 1
        ptr := old % PTR_MASK
        cell_store(req, 24, ptr)
        newv := tag * PTR_MASK + rp
        if rt_atomic_cas(m, 32, old, newv) != 0:
            return

fn sched_process_spawns(m_idx: int):
    m := g_machines + m_idx * 48
    loop:
        old := rt_atomic_load(m, 32)
        ptr := old % PTR_MASK
        if ptr == 0:
            return
        nxt := cell_load(ptr, 24)
        tag : ., mut = old / PTR_MASK + 1
        if tag > TAG_MAX:
            tag = 1
        newv := tag * PTR_MASK + nxt
        if rt_atomic_cas(m, 32, old, newv) != 0:
            cell_store(ptr, 24, 0)
            saved := rt_current_arena()
            g := g_new(cell_load(ptr, 0), cell_load(ptr, 8), 0)
            rt_set_current_arena(saved)
            cell_store(g, 40, cell_load(ptr, 16))
            sched_enqueue(g)

fn sched_go_direct(fn_ptr: int, arg: int, ch: string):
    saved_cur := arena_current_unchecked()
    g := g_new(fn_ptr, arg, 0)
    arena_set_current_unchecked(saved_cur)
    cell_store(g, 40, ch)
    sched_enqueue(g)

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


