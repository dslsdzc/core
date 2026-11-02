// conc_sched — plan-first CPU mapping for `go`/`chan` (CP-4, multi-M in CP-5).
//
// Each M owns a ready queue and a current-activation slot. Activation fibers
// are pinned to their home M, so the compiler arena/TLS for an activation is
// only ever touched by one thread. A single spinlock protects the shared ready
// queues, channel wait lists, and scheduler arrays; it is never held across a
// fiber switch. Runtime metadata lives in the reserved shared arena partition.
import conc
import arena

CONC_SCHED_STACK : int = 16384
CONC_ACT_SIZE : int = 112
CONC_ACT_RUNNABLE : int = 0
CONC_ACT_RUNNING : int = 1
CONC_ACT_WAITING : int = 2
CONC_ACT_DEAD : int = 3

CONC_CH_STATE_SIZE : int = 48
CONC_WAIT_SEND : int = 0
CONC_WAIT_RECV : int = 1

g_conc_inited : int, mut = 0
g_conc_acts : string, mut
g_conc_act_count : int, mut = 0
g_conc_act_cap : int, mut = 0
g_conc_cur_m : string, mut
g_conc_ready_head_s : string, mut
g_conc_ready_tail_s : string, mut
g_conc_slot_rr_m : string, mut
g_conc_spawn_rr : int, mut = 0
g_conc_sched_sp_m : string, mut
g_conc_lock : string, mut
g_conc_m_count : int, mut = 1
g_conc_slots : int, mut = 1
g_conc_global_region : int, mut = -1
g_conc_ch_states : string, mut
g_conc_ch_count : int, mut = 0
g_conc_ch_cap : int, mut = 0
g_conc_free : string, mut
g_conc_free_count : int, mut = 0
g_conc_free_cap : int, mut = 0
g_conc_quantum : int, mut = 2000
g_conc_quantum_m : string, mut
g_conc_seq_m : string, mut
g_conc_timespec : string, mut
g_conc_preempt_flag : int, mut = 0
g_conc_shutdown : int, mut = 0
g_conc_workers_done : int, mut = 0
g_conc_workers_started : int, mut = 0
g_conc_worker_failures : int, mut = 0
g_conc_signal_preempt : int, mut = 1

fn _conc_sched_alloc(size: int) -> string:
    // Scheduler arrays are shared across Ms; allocate them from the reserved
    // shared partition. Callers hold the conc lock while mutating them.
    return arena_shared_alloc(size)

fn conc_preempt_signal():
    // Async-signal-safe: one global store, no locks, no allocation, no TLS.
    if g_conc_signal_preempt != 0:
        g_conc_preempt_flag = 1

fn _conc_preempt_install():
    act := _conc_sched_alloc(32)
    cell_store(act, 0, @addr(conc_preempt_signal))
    // SA_RESTART | SA_RESTORER
    cell_store(act, 8, 335544320)
    cell_store(act, 16, @addr(rt_sigreturn_stub))
    cell_store(act, 24, 0)
    r := syscall4(13, 14, _conc_addr(act), 0, 8)
    iv := _conc_sched_alloc(32)
    cell_store(iv, 0, 0)
    cell_store(iv, 8, 5000)
    cell_store(iv, 16, 0)
    cell_store(iv, 24, 5000)
    r2 := syscall3(38, 0, _conc_addr(iv), 0)

fn conc_set_signal_preempt(on: int), pub:
    g_conc_signal_preempt = on

fn conc_set_quantum(n: int), pub:
    if n < 1:
        n = 1
    g_conc_quantum = n
    if g_conc_inited != 0:
        i : ., mut = 0
        loop:
            if i >= 64:
                break
            cell_store(g_conc_quantum_m, i * 8, n)
            i = i + 1

fn _conc_seq_addr(m: int) -> int:
    return _conc_addr(g_conc_seq_m) + m * 8

fn _conc_futex_wait(addr: int, val: int) -> int:
    // futex(uaddr, FUTEX_WAIT, val, timeout, uaddr2, val3). The 2 ms timeout
    // is a safety net for channel polling (the main thread is not a channel
    // waiter), so a missed notification delays but never deadlocks.
    return syscall6(202, addr, 0, val, _conc_addr(g_conc_timespec), 0, 0)

fn _conc_futex_wake(addr: int) -> int:
    // futex(uaddr, FUTEX_WAKE, 1, 0, 0, 0)
    return syscall6(202, addr, 1, 1, 0, 0, 0)

fn conc_workers_done() -> int, pub:
    return g_conc_workers_done

fn conc_workers_started() -> int, pub:
    return g_conc_workers_started

fn conc_worker_failures() -> int, pub:
    return g_conc_worker_failures

fn conc_check_workers(expected: int):
    spins : ., mut = 0
    loop:
        if g_conc_workers_started >= expected:
            break
        if spins >= 100000:
            break
        syscall3(24, 0, 0, 0)
        spins = spins + 1
    if expected > g_conc_workers_started:
        g_conc_worker_failures = expected - g_conc_workers_started

fn conc_shutdown(), pub:
    // Cancel idle workers: set the stop flag and wake every M's futex word.
    _conc_lock()
    if g_conc_shutdown != 0:
        _conc_unlock()
        return
    g_conc_shutdown = 1
    m : ., mut = 0
    loop:
        if m >= 64:
            break
        seq := rt_atomic_load(g_conc_seq_m, m * 8)
        rt_atomic_store(g_conc_seq_m, m * 8, seq + 1)
        _conc_futex_wake(_conc_seq_addr(m))
        m = m + 1
    _conc_unlock()

fn conc_park(m: int):
    // Park until the home M's queue or sequence changes. The sequence is read
    // under the same lock the waker uses, so a push between unlock and the
    // futex call is observed as EAGAIN rather than a lost wakeup.
    _conc_lock()
    slots : ., mut = g_conc_slots
    if slots < 1:
        slots = 1
    if slots > 64:
        slots = 64
    k : ., mut = 0
    loop:
        if k >= slots:
            break
        if cell_load(g_conc_ready_head_s, (m + k * g_conc_m_count) * 8) >= 0:
            _conc_unlock()
            return
        k = k + 1
    s := rt_atomic_load(g_conc_seq_m, m * 8)
    _conc_unlock()
    _conc_futex_wait(_conc_seq_addr(m), s)

fn _conc_act_at(id: int) -> string:
    if id < 0 || id >= g_conc_act_count:
        return ""
    return load_str_ptr(g_conc_acts, id * 8)

fn _conc_ready_push(id: int):
    a := _conc_act_at(id)
    if _conc_word(a) == 0:
        return
    m : ., mut = cell_load(a, 80)
    if m < 0 || m >= 64:
        m = 0
    slot : ., mut = cell_load(a, 104)
    if slot < 0 || slot >= 4096:
        slot = m
    cell_store(a, 88, -1)
    tail := cell_load(g_conc_ready_tail_s, slot * 8)
    if tail < 0:
        cell_store(g_conc_ready_head_s, slot * 8, id)
    else:
        ta := _conc_act_at(tail)
        if _conc_word(ta) != 0:
            cell_store(ta, 88, id)
    cell_store(g_conc_ready_tail_s, slot * 8, id)
    // futex protocol: bump the home M's sequence while still under the conc
    // lock, then wake. A waiter that read the old sequence gets EAGAIN instead
    // of sleeping through the wake.
    seq := rt_atomic_load(g_conc_seq_m, m * 8)
    rt_atomic_store(g_conc_seq_m, m * 8, seq + 1)
    _conc_futex_wake(_conc_seq_addr(m))

fn _conc_ready_pop() -> int:
    m := _conc_m()
    slots : ., mut = g_conc_slots
    if slots < 1:
        slots = 1
    if slots > 64:
        slots = 64
    start : ., mut = cell_load(g_conc_slot_rr_m, m * 8)
    if start < 0 || start >= slots:
        start = 0
    k : ., mut = 0
    loop:
        if k >= slots:
            return -1
        si : ., mut = start + k
        if si >= slots:
            si = si - slots
        slot := m + si * g_conc_m_count
        id := cell_load(g_conc_ready_head_s, slot * 8)
        if id >= 0:
            nxt : ., mut = -1
            a := _conc_act_at(id)
            if _conc_word(a) != 0:
                nxt = cell_load(a, 88)
            cell_store(g_conc_ready_head_s, slot * 8, nxt)
            if nxt < 0:
                cell_store(g_conc_ready_tail_s, slot * 8, -1)
            cell_store(g_conc_slot_rr_m, m * 8, si + 1)
            return id
        k = k + 1
    return -1

fn _conc_acts_grow():
    if g_conc_act_count < g_conc_act_cap:
        return
    nc : ., mut = g_conc_act_cap * 2
    if nc < 16:
        nc = 16
    nb := _conc_sched_alloc(nc * 8)
    i : ., mut = 0
    loop:
        if i >= g_conc_act_count:
            break
        store_str_ptr(nb, i * 8, _conc_act_at(i))
        i = i + 1
    g_conc_acts = nb
    g_conc_act_cap = nc

fn _conc_m() -> int:
    m : ., mut = rt_m_idx()
    if m < 0:
        m = 0
    if m >= 64:
        m = 0
    return m

fn _conc_cur_id() -> int:
    return cell_load(g_conc_cur_m, _conc_m() * 8)

fn _conc_set_cur(id: int):
    cell_store(g_conc_cur_m, _conc_m() * 8, id)

fn _conc_sched_sp_cell() -> string:
    return _conc_ptr(_conc_addr(g_conc_sched_sp_m) + _conc_m() * 8)

fn _conc_lock():
    loop:
        if rt_atomic_load(g_conc_lock, 0) == 0:
            if rt_atomic_cas(g_conc_lock, 0, 0, 1) != 0:
                return
        syscall3(24, 0, 0, 0)

fn _conc_unlock():
    rt_atomic_store(g_conc_lock, 0, 0)

fn conc_sched_set_m(n: int), pub:
    if n < 1:
        n = 1
    g_conc_m_count = n

fn conc_sched_set_slots(n: int), pub:
    if n < 1:
        n = 1
    g_conc_slots = n

fn conc_sched_init():
    arena_ensure_init()
    arena_shared_init()
    if g_conc_inited != 0:
        return
    g_conc_acts = _conc_sched_alloc(16 * 8)
    g_conc_act_cap = 16
    g_conc_ready_head_s = _conc_sched_alloc(4096 * 8)
    g_conc_ready_tail_s = _conc_sched_alloc(4096 * 8)
    g_conc_slot_rr_m = _conc_sched_alloc(64 * 8)
    i0 : ., mut = 0
    loop:
        if i0 >= 4096:
            break
        cell_store(g_conc_ready_head_s, i0 * 8, -1)
        cell_store(g_conc_ready_tail_s, i0 * 8, -1)
        i0 = i0 + 1
    i1 : ., mut = 0
    loop:
        if i1 >= 64:
            break
        cell_store(g_conc_slot_rr_m, i1 * 8, 0)
        i1 = i1 + 1
    g_conc_sched_sp_m = _conc_sched_alloc(64 * 8)
    g_conc_lock = _conc_sched_alloc(8)
    cell_store(g_conc_lock, 0, 0)
    g_conc_cur_m = _conc_sched_alloc(64 * 8)
    i : ., mut = 0
    loop:
        if i >= 64:
            break
        cell_store(g_conc_cur_m, i * 8, -1)
        i = i + 1
    g_conc_ch_states = _conc_sched_alloc(16 * CONC_CH_STATE_SIZE)
    g_conc_ch_cap = 16
    g_conc_free = _conc_sched_alloc(64 * 8)
    g_conc_free_cap = 64
    g_conc_quantum_m = _conc_sched_alloc(64 * 8)
    g_conc_seq_m = _conc_sched_alloc(64 * 8)
    g_conc_timespec = _conc_sched_alloc(16)
    cell_store(g_conc_timespec, 0, 0)
    cell_store(g_conc_timespec, 8, 2000000)
    _conc_preempt_install()
    iq : ., mut = 0
    loop:
        if iq >= 64:
            break
        cell_store(g_conc_quantum_m, iq * 8, g_conc_quantum)
        cell_store(g_conc_seq_m, iq * 8, 0)
        iq = iq + 1
    g_conc_inited = 1

fn _conc_free_push(id: int):
    if g_conc_free_count >= g_conc_free_cap:
        nc : ., mut = g_conc_free_cap * 2
        if nc < 64:
            nc = 64
        nb := _conc_sched_alloc(nc * 8)
        i : ., mut = 0
        loop:
            if i >= g_conc_free_count:
                break
            cell_store(nb, i * 8, cell_load(g_conc_free, i * 8))
            i = i + 1
        g_conc_free = nb
        g_conc_free_cap = nc
    cell_store(g_conc_free, g_conc_free_count * 8, id)
    g_conc_free_count = g_conc_free_count + 1

fn _conc_free_pop() -> int:
    if g_conc_free_count <= 0:
        return -1
    g_conc_free_count = g_conc_free_count - 1
    return cell_load(g_conc_free, g_conc_free_count * 8)

fn _conc_act_new(entry: int, arg: int, result_ch: string) -> int:
    conc_sched_init()
    _conc_acts_grow()
    id : ., mut = _conc_free_pop()
    if id < 0:
        id = g_conc_act_count
        g_conc_act_count = id + 1
    slots : ., mut = g_conc_slots
    if slots < 1:
        slots = 1
    slot := g_conc_spawn_rr % (g_conc_m_count * slots)
    home : ., mut = slot % g_conc_m_count
    g_conc_spawn_rr = g_conc_spawn_rr + 1
    // Control blocks live in the shared partition and are reused through the
    // free list. Stacks and activation arenas are created lazily by the home
    // M on first run (conc_schedule), so a spawner never touches another M's
    // slot pools and every M allocates only in its own partition.
    a : ., mut = _conc_act_at(id)
    if _conc_raw(a) == 0:
        a = arena_shared_alloc(CONC_ACT_SIZE)
        if _conc_word(a) == 0:
            g_conc_act_count = id
            return -1
    cell_store(a, 0, id)
    cell_store(a, 8, CONC_ACT_RUNNABLE)
    cell_store(a, 16, 0)
    cell_store(a, 24, 0)
    cell_store(a, 32, entry)
    cell_store(a, 40, arg)
    store_str_ptr(a, 48, result_ch)
    cell_store(a, 56, -1)
    cell_store(a, 64, -1)
    cell_store(a, 72, 0)
    cell_store(a, 80, home)
    cell_store(a, 88, -1)
    cell_store(a, 96, -1)
    cell_store(a, 104, slot)
    store_str_ptr(g_conc_acts, id * 8, a)
    return id

fn _conc_raw(s: string) -> int:
    // Raw data pointer. Unlike _conc_word this does not read the length word,
    // so it is safe on a zero word from the acts table.
    v : ., mut = 0
    unsafe:
        v = @ptr_of(s)
    return v

fn _conc_word(s: string) -> int:
    if str_len(s) <= 0:
        return 0
    v : ., mut = 0
    unsafe:
        v = @ptr_of(s)
    return v

fn conc_spawn(entry: int, arg: int, result_ch: string) -> int, pub:
    conc_sched_init()
    _conc_lock()
    id := _conc_act_new(entry, arg, result_ch)
    if id >= 0:
        _conc_ready_push(id)
    _conc_unlock()
    return id

fn conc_sched_curg() -> int, pub:
    return _conc_cur_id()

fn conc_current_slot() -> int, pub:
    id := _conc_cur_id()
    if id < 0:
        return -1
    a := _conc_act_at(id)
    if _conc_word(a) == 0:
        return -1
    return cell_load(a, 104)

fn conc_schedule() -> int, pub:
    ran : ., mut = 0
    if _conc_cur_id() < 0:
        saved := arena_current_unchecked()
        loop:
            _conc_lock()
            id := _conc_ready_pop()
            if id < 0:
                _conc_unlock()
                return ran
            a := _conc_act_at(id)
            if _conc_word(a) == 0:
                _conc_unlock()
                continue
            if cell_load(a, 64) < 0:
                // First run on the home M: create the activation arena and
                // fiber stack here, so the owning partition is only touched
                // by its own thread.
                aidp := arena_new()
                if aidp < 0:
                    cell_store(a, 8, CONC_ACT_DEAD)
                    _conc_unlock()
                    continue
                stack := alloc(CONC_SCHED_STACK)
                arena_set_current_unchecked(saved)
                if _conc_word(stack) == 0:
                    arena_reset(aidp)
                    cell_store(a, 8, CONC_ACT_DEAD)
                    _conc_unlock()
                    continue
                sp := fiber_init(stack + CONC_SCHED_STACK - 8, @addr(_conc_activation_entry))
                cell_store(a, 16, sp)
                cell_store(a, 24, stack)
                cell_store(a, 64, aidp)
                cell_store(a, 96, aidp)
            ran = 1
            _conc_set_cur(id)
            cell_store(a, 8, CONC_ACT_RUNNING)
            _conc_unlock()
            arena_set_current_unchecked(cell_load(a, 64))
            fiber_switch(_conc_ptr_addr(_conc_sched_sp_cell()), cell_load(a, 16))
            arena_set_current_unchecked(saved)
            _conc_lock()
            st := cell_load(a, 8)
            root := cell_load(a, 96)
            if st == CONC_ACT_DEAD:
                arena_reset(root)
                _conc_free_push(id)
            _conc_set_cur(-1)
            _conc_unlock()
    else:
        a := _conc_act_at(_conc_cur_id())
        if _conc_word(a) == 0:
            _conc_set_cur(-1)
            return 0
        cell_store(a, 64, arena_current_unchecked())
        fiber_switch(@ptr_add(a, 16), cell_load(_conc_sched_sp_cell(), 0))
    return ran

fn _conc_ptr_addr(s: string) -> int:
    v : ., mut = 0
    unsafe:
        v = @ptr_of(s)
    return v

fn conc_yield(), pub:
    if _conc_cur_id() < 0:
        return
    a := _conc_act_at(_conc_cur_id())
    if _conc_word(a) == 0:
        return
    cell_store(a, 8, CONC_ACT_RUNNABLE)
    _conc_lock()
    _conc_ready_push(_conc_cur_id())
    _conc_unlock()
    conc_schedule()

fn conc_plan_run(plan: int, root: int, channels: string) -> int, pub:
    // CPU edge executor: spawn every body reachable by a SPAWN edge from
    // `root`, pass its bound channel handle, then join the result channels and
    // sum body return values. SEND/RECV edges are documentation; the body
    // itself performs those operations on the bound channel.
    if conc_plan_validate(plan) == 0:
        return -1
    if conc_plan_apply_layouts(plan) < 0:
        return -1
    if root < 0 || root >= conc_plan_body_count(plan):
        return -1
    if _conc_is_null(channels) != 0:
        return -1
    hs := alloc(64 * 8)
    n : ., mut = 0
    ne := conc_plan_edge_count(plan)
    e : ., mut = 0
    loop:
        if e >= ne:
            break
        if conc_plan_edge_kind(plan, e) == CONC_EDGE_SPAWN:
            if conc_plan_edge_from(plan, e) == root:
                to := conc_plan_edge_to(plan, e)
                if n >= 64:
                    return -1
                kind := conc_plan_body_kind(plan, to)
                if kind != CONC_BODY_TASK && kind != CONC_BODY_PIPELINE:
                    return -1
                arg : ., mut = 0
                ch := conc_plan_param_channel(plan, to, 0)
                if ch >= 0:
                    handle := load_str_ptr(channels, ch * 8)
                    if _conc_is_null(handle) != 0:
                        return -1
                    unsafe:
                        arg = @ptr_of(handle)
                entry := conc_plan_body_entry(plan, to)
                if entry <= 0:
                    return -1
                h := conc_go(entry, arg)
                if _conc_word(h) == 0:
                    return -1
                cell_store(hs, n * 8, h)
                n = n + 1
        e = e + 1
    total : ., mut = 0
    i : ., mut = 0
    loop:
        if i >= n:
            break
        total = total + conc_sched_recv_int(cell_load(hs, i * 8))
        i = i + 1
    return total

fn conc_pi_lock(word: string) -> int, pub:
    // Linux PI futex: FUTEX_LOCK_PI = 6. The kernel handles owner tracking and
    // priority inheritance; the word must be 4-byte aligned and zeroed first.
    return syscall6(202, _conc_addr(word), 6, 0, 0, 0, 0)

fn conc_pi_trylock(word: string) -> int, pub:
    // FUTEX_TRYLOCK_PI = 8
    return syscall6(202, _conc_addr(word), 8, 0, 0, 0, 0)

fn conc_pi_unlock(word: string) -> int, pub:
    // FUTEX_UNLOCK_PI = 7
    return syscall6(202, _conc_addr(word), 7, 0, 0, 0, 0)

fn conc_ctx_ch(ctx: string, off: int) -> string, pub:
    // Stage context convention: +0 input channel, +8 output channel.
    return load_str_ptr(ctx, off)

fn conc_pipeline_run(plan: int, channels: string) -> int, pub:
    // CPU pipeline executor: each stage is a PIPE body taking a 16-byte
    // context (in/out channel handles). Stages run as activations; bounded
    // channels provide backpressure. Returns the sum of stage return values.
    if conc_plan_validate(plan) == 0:
        return -1
    if conc_plan_apply_layouts(plan) < 0:
        return -1
    if _conc_is_null(channels) != 0:
        return -1
    n := conc_plan_stage_count(plan)
    if n <= 0 || n > 64:
        return -1
    hs := alloc(64 * 8)
    i : ., mut = 0
    loop:
        if i >= n:
            break
        body := conc_plan_stage_body(plan, i)
        entry := conc_plan_body_entry(plan, body)
        if entry <= 0:
            return -1
        ctx := alloc(16)
        cell_store(ctx, 0, 0)
        cell_store(ctx, 8, 0)
        in_ch := conc_plan_stage_in(plan, i)
        if in_ch >= 0:
            ih := load_str_ptr(channels, in_ch * 8)
            if _conc_is_null(ih) != 0:
                return -1
            store_str_ptr(ctx, 0, ih)
        out_ch := conc_plan_stage_out(plan, i)
        if out_ch >= 0:
            oh := load_str_ptr(channels, out_ch * 8)
            if _conc_is_null(oh) != 0:
                return -1
            store_str_ptr(ctx, 8, oh)
        arg : ., mut = 0
        unsafe:
            arg = @ptr_of(ctx)
        h := conc_go(entry, arg)
        if _conc_word(h) == 0:
            return -1
        cell_store(hs, i * 8, h)
        i = i + 1
    total : ., mut = 0
    i = 0
    loop:
        if i >= n:
            break
        total = total + conc_sched_recv_int(cell_load(hs, i * 8))
        i = i + 1
    return total

fn conc_plan_mark_range(entry: int, start: int, count: int), pub:
    // Compiler-to-plan marker; the default runtime uses the IR loop.
    return

fn conc_preempt_tick(), pub:
    // Inserted at user loop backedges. No-op when the conc scheduler is not
    // active, so ordinary programs and compiler/stdlib loops are untouched.
    if g_conc_inited == 0:
        return
    if g_conc_preempt_flag != 0:
        g_conc_preempt_flag = 0
        conc_yield()
        return
    m := _conc_m()
    q := cell_load(g_conc_quantum_m, m * 8) - 1
    if q <= 0:
        cell_store(g_conc_quantum_m, m * 8, g_conc_quantum)
        conc_yield()
    else:
        cell_store(g_conc_quantum_m, m * 8, q)

fn conc_worker_run(m_idx: int), pub:
    // The clone trampoline already installs the per-worker TLS block; set the
    // index again so this loop is correct even on a runtime that starts a
    // worker through a different path.
    rt_set_m_idx(m_idx)
    _conc_lock()
    g_conc_workers_started = g_conc_workers_started + 1
    _conc_unlock()
    loop:
        if g_conc_shutdown != 0:
            _conc_lock()
            g_conc_workers_done = g_conc_workers_done + 1
            _conc_unlock()
            return
        if conc_schedule() == 0:
            conc_park(m_idx)

fn _conc_activation_entry():
    id := _conc_cur_id()
    a := _conc_act_at(id)
    if _conc_word(a) == 0:
        return
    entry := cell_load(a, 32)
    arg := cell_load(a, 40)
    tbl := alloc(8)
    cell_store(tbl, 0, entry)
    rc := sched_call_1(tbl, 0, arg)
    ch := load_str_ptr(a, 48)
    if _conc_word(ch) != 0:
        conc_sched_send_int(ch, rc)
    cell_store(a, 8, CONC_ACT_DEAD)
    loop:
        conc_schedule()
    return

fn _conc_ch_grow():
    if g_conc_ch_count < g_conc_ch_cap:
        return
    nc : ., mut = g_conc_ch_cap * 2
    if nc < 16:
        nc = 16
    nb := _conc_sched_alloc(nc * CONC_CH_STATE_SIZE)
    i : ., mut = 0
    loop:
        if i >= g_conc_ch_count * CONC_CH_STATE_SIZE:
            break
        store8(nb, i, load8(g_conc_ch_states, i))
        i = i + 1
    g_conc_ch_states = nb
    g_conc_ch_cap = nc

fn _conc_ch_slot(ch: string) -> int:
    conc_sched_init()
    i : ., mut = 0
    loop:
        if i >= g_conc_ch_count:
            break
        p := load_str_ptr(g_conc_ch_states, i * CONC_CH_STATE_SIZE)
        if _conc_word(p) == _conc_word(ch):
            return i
        i = i + 1
    _conc_ch_grow()
    slot := g_conc_ch_count
    store_str_ptr(g_conc_ch_states, slot * CONC_CH_STATE_SIZE, ch)
    cell_store(g_conc_ch_states, slot * CONC_CH_STATE_SIZE + 8, 0)
    cell_store(g_conc_ch_states, slot * CONC_CH_STATE_SIZE + 16, -1)
    cell_store(g_conc_ch_states, slot * CONC_CH_STATE_SIZE + 24, -1)
    cell_store(g_conc_ch_states, slot * CONC_CH_STATE_SIZE + 32, -1)
    cell_store(g_conc_ch_states, slot * CONC_CH_STATE_SIZE + 40, -1)
    g_conc_ch_count = slot + 1
    return slot

fn _conc_wait_push(slot: int, kind: int, id: int):
    base := slot * CONC_CH_STATE_SIZE
    head_off : ., mut = 16
    if kind == CONC_WAIT_RECV:
        head_off = 32
    tail_off := head_off + 8
    head := cell_load(g_conc_ch_states, base + head_off)
    tail := cell_load(g_conc_ch_states, base + tail_off)
    a := _conc_act_at(id)
    cell_store(a, 56, -1)
    if head < 0:
        cell_store(g_conc_ch_states, base + head_off, id)
        cell_store(g_conc_ch_states, base + tail_off, id)
    else:
        t := _conc_act_at(tail)
        cell_store(t, 56, id)
        cell_store(g_conc_ch_states, base + tail_off, id)

fn _conc_wait_pop(slot: int, kind: int) -> int:
    base := slot * CONC_CH_STATE_SIZE
    head_off : ., mut = 16
    if kind == CONC_WAIT_RECV:
        head_off = 32
    tail_off := head_off + 8
    head := cell_load(g_conc_ch_states, base + head_off)
    if head < 0:
        return -1
    a := _conc_act_at(head)
    nxt : ., mut = -1
    if _conc_word(a) != 0:
        nxt = cell_load(a, 56)
    cell_store(g_conc_ch_states, base + head_off, nxt)
    if nxt < 0:
        cell_store(g_conc_ch_states, base + tail_off, -1)
    return head

fn _conc_wake_one(slot: int, kind: int):
    id := _conc_wait_pop(slot, kind)
    if id < 0:
        return
    a := _conc_act_at(id)
    if _conc_word(a) == 0:
        return
    cell_store(a, 8, CONC_ACT_RUNNABLE)
    _conc_ready_push(id)

fn _conc_wake_all(slot: int, kind: int):
    loop:
        id := _conc_wait_pop(slot, kind)
        if id < 0:
            return
        a := _conc_act_at(id)
        if _conc_word(a) != 0:
            cell_store(a, 8, CONC_ACT_RUNNABLE)
            _conc_ready_push(id)

fn _conc_ch_closed(slot: int) -> int:
    return cell_load(g_conc_ch_states, slot * CONC_CH_STATE_SIZE + 8)

fn _conc_ch_set_closed(slot: int):
    cell_store(g_conc_ch_states, slot * CONC_CH_STATE_SIZE + 8, 1)

fn _conc_ch_cap(ch: string) -> int:
    return cell_load(ch, 16)

fn _conc_ch_head(ch: string) -> int:
    return cell_load(ch, 32)

fn _conc_ch_len(ch: string) -> int:
    return cell_load(ch, 24)

fn _conc_ch_buf(ch: string) -> string:
    return load_str_ptr(ch, 8)

fn _conc_ch_esize(ch: string) -> int:
    return cell_load(ch, 40)

fn _conc_global_region_get() -> int:
    if g_conc_global_region >= 0:
        return g_conc_global_region
    r := conc_region_new(1048576)
    if r >= 0:
        g_conc_global_region = r
    return r

fn conc_chan_make(elemsize: int, cap: int) -> string, pub:
    conc_sched_init()
    _conc_lock()
    out : ., mut = ""
    if elemsize > 0:
        if cap >= 0:
            if cap <= 1099511627776 / elemsize:
                r : ., mut = _conc_global_region_get()
                if r >= 0:
                    need : ., mut = 128 + cap * elemsize
                    if need < 1048576:
                        need = 1048576
                    ch : ., mut = conc_channel_new(r, elemsize, cap)
                    if _conc_word(ch) == 0:
                        r = conc_region_new(need)
                        if r >= 0:
                            g_conc_global_region = r
                            ch = conc_channel_new(r, elemsize, cap)
                    if _conc_word(ch) != 0:
                        out = ch
    _conc_unlock()
    return out

fn conc_sched_send_int(ch: string, val: int) -> int, pub:
    conc_sched_init()
    loop:
        _conc_lock()
        if conc_channel_len(ch) < 0:
            _conc_unlock()
            return -1
        esize := _conc_ch_esize(ch)
        if esize < 8:
            _conc_unlock()
            return -1
        slot := _conc_ch_slot(ch)
        if _conc_ch_closed(slot) != 0:
            _conc_unlock()
            return 0
        cap := _conc_ch_cap(ch)
        n := _conc_ch_len(ch)
        if cap == 0:
            rid := _conc_wait_pop(slot, CONC_WAIT_RECV)
            if rid >= 0:
                ra := _conc_act_at(rid)
                if _conc_word(ra) != 0:
                    cell_store(ra, 72, val)
                    cell_store(ra, 8, CONC_ACT_RUNNABLE)
                    _conc_ready_push(rid)
                    _conc_unlock()
                    return 0
                _conc_unlock()
                continue
            if _conc_cur_id() < 0:
                _conc_unlock()
                if conc_schedule() == 0:
                    if g_conc_m_count <= 1:
                        return 0
                    conc_park(_conc_m())
                continue
            ca := _conc_act_at(_conc_cur_id())
            cell_store(ca, 72, val)
            _conc_wait_push(slot, CONC_WAIT_SEND, _conc_cur_id())
            cell_store(ca, 8, CONC_ACT_WAITING)
            _conc_unlock()
            conc_schedule()
            return 0
        if n < cap:
            buf := _conc_ch_buf(ch)
            head := _conc_ch_head(ch)
            pos : ., mut = head + n
            if pos >= cap:
                pos = pos - cap
            cell_store(buf, pos * esize, val)
            cell_store(ch, 24, n + 1)
            _conc_wake_one(slot, CONC_WAIT_RECV)
            _conc_unlock()
            return 0
        if _conc_cur_id() < 0:
            _conc_unlock()
            if conc_schedule() == 0:
                if g_conc_m_count <= 1:
                    return 0
                conc_park(_conc_m())
            continue
        _conc_wait_push(slot, CONC_WAIT_SEND, _conc_cur_id())
        a := _conc_act_at(_conc_cur_id())
        cell_store(a, 8, CONC_ACT_WAITING)
        _conc_unlock()
        conc_schedule()

fn conc_sched_recv_int(ch: string) -> int, pub:
    conc_sched_init()
    loop:
        _conc_lock()
        if conc_channel_len(ch) < 0:
            _conc_unlock()
            return 0
        esize := _conc_ch_esize(ch)
        if esize < 8:
            _conc_unlock()
            return 0
        slot := _conc_ch_slot(ch)
        n := _conc_ch_len(ch)
        cap := _conc_ch_cap(ch)
        if cap == 0:
            if _conc_ch_closed(slot) != 0:
                _conc_unlock()
                return 0
            sid := _conc_wait_pop(slot, CONC_WAIT_SEND)
            if sid >= 0:
                sa := _conc_act_at(sid)
                v : ., mut = 0
                if _conc_word(sa) != 0:
                    v = cell_load(sa, 72)
                    cell_store(sa, 8, CONC_ACT_RUNNABLE)
                    _conc_ready_push(sid)
                _conc_unlock()
                return v
            if _conc_cur_id() < 0:
                _conc_unlock()
                if conc_schedule() == 0:
                    if g_conc_m_count <= 1:
                        return 0
                    conc_park(_conc_m())
                continue
            ra := _conc_act_at(_conc_cur_id())
            _conc_wait_push(slot, CONC_WAIT_RECV, _conc_cur_id())
            cell_store(ra, 8, CONC_ACT_WAITING)
            _conc_unlock()
            conc_schedule()
            ra2 := _conc_act_at(_conc_cur_id())
            if _conc_word(ra2) == 0:
                return 0
            return cell_load(ra2, 72)
        if n > 0:
            buf := _conc_ch_buf(ch)
            head : ., mut = _conc_ch_head(ch)
            v := cell_load(buf, head * esize)
            head = head + 1
            if head >= _conc_ch_cap(ch):
                head = 0
            cell_store(ch, 32, head)
            cell_store(ch, 24, n - 1)
            _conc_wake_one(slot, CONC_WAIT_SEND)
            _conc_unlock()
            return v
        if _conc_ch_closed(slot) != 0:
            _conc_unlock()
            return 0
        if _conc_cur_id() < 0:
            _conc_unlock()
            if conc_schedule() == 0:
                if g_conc_m_count <= 1:
                    return 0
                conc_park(_conc_m())
            continue
        _conc_wait_push(slot, CONC_WAIT_RECV, _conc_cur_id())
        a := _conc_act_at(_conc_cur_id())
        cell_store(a, 8, CONC_ACT_WAITING)
        _conc_unlock()
        conc_schedule()

fn conc_sched_close(ch: string), pub:
    conc_sched_init()
    _conc_lock()
    if conc_channel_len(ch) < 0:
        _conc_unlock()
        return
    slot := _conc_ch_slot(ch)
    _conc_ch_set_closed(slot)
    _conc_wake_all(slot, CONC_WAIT_SEND)
    _conc_wake_all(slot, CONC_WAIT_RECV)
    _conc_unlock()

fn conc_go(entry: int, arg: int) -> string, pub:
    conc_sched_init()
    _conc_lock()
    out : ., mut = ""
    r : ., mut = _conc_global_region_get()
    if r >= 0:
        ch : ., mut = conc_channel_new(r, 8, 1)
        if _conc_word(ch) == 0:
            r = conc_region_new(1048576)
            if r >= 0:
                g_conc_global_region = r
                ch = conc_channel_new(r, 8, 1)
        if _conc_word(ch) != 0:
            out = ch
    _conc_unlock()
    if _conc_word(out) == 0:
        return ""
    if conc_spawn(entry, arg, out) < 0:
        return ""
    return out
