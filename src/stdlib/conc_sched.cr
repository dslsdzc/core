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
CONC_ACT_SIZE : int = 144
CONC_ACT_RUNNABLE : int = 0
CONC_ACT_RUNNING : int = 1
CONC_ACT_WAITING : int = 2
CONC_ACT_DEAD : int = 3
CONC_ACT_YIELDING : int = 4

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
g_conc_preempt_disable_m : string, mut
g_conc_yield_claim_m : string, mut
g_conc_queue_lock_m : string, mut
g_conc_steal_attempts : int, mut = 0
g_conc_steal_count : int, mut = 0

fn _conc_sched_alloc(size: int) -> string:
    // Scheduler arrays are shared across Ms; allocate them from the reserved
    // shared partition. Callers hold the conc lock while mutating them.
    return arena_shared_alloc(size)

fn conc_preempt_signal():
    // The handler first publishes a pending flag (always safe). When the
    // interrupted thread is running an activation, is not inside a disabled
    // critical section, and is actually on that activation's stack, it may
    // switch directly. The per-M claim word prevents a nested switch while a
    // cooperative yield is already in flight.
    if g_conc_signal_preempt != 0:
        g_conc_preempt_flag = 1
        if g_conc_inited != 0:
            if _conc_raw(g_conc_preempt_disable_m) != 0:
                m := rt_m_idx()
                if m >= 0 && m < 64:
                    if cell_load(g_conc_preempt_disable_m, m * 8) == 0:
                        id := cell_load(g_conc_cur_m, m * 8)
                        if id >= 0:
                            a := _conc_act_at(id)
                            if _conc_word(a) != 0:
                                if cell_load(a, 8) != CONC_ACT_RUNNING:
                                    return
                                stack := cell_load(a, 24)
                                if stack > 0:
                                    sp := rt_sp()
                                    if sp >= stack && sp < stack + CONC_SCHED_STACK:
                                        if rt_atomic_cas(g_conc_yield_claim_m,
                                                         m * 8, 0, 1) != 0:
                                            g_conc_preempt_flag = 0
                                            _conc_yield_try(1)

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

fn conc_steal_count() -> int, pub:
    return g_conc_steal_count

fn conc_steal_attempts() -> int, pub:
    return g_conc_steal_attempts

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
    // under the same per-M queue lock the waker uses, so a push between unlock
    // and the futex call is observed as EAGAIN rather than a lost wakeup.
    if _conc_raw(g_conc_queue_lock_m) == 0:
        return
    slots : ., mut = g_conc_slots
    if slots < 1:
        slots = 1
    if slots > 64:
        slots = 64
    _conc_queue_lock(m)
    ready : ., mut = 0
    k : ., mut = 0
    loop:
        if k >= slots:
            break
        if _conc_queue_has_slot(m + k * g_conc_m_count, 0) != 0:
            ready = 1
            break
        k = k + 1
    s := rt_atomic_load(g_conc_seq_m, m * 8)
    _conc_queue_unlock(m)
    if ready != 0:
        return
    // If another M has an unstarted activation, return so conc_schedule can
    // steal it instead of sleeping through the work.
    mc : ., mut = g_conc_m_count
    if mc > 64:
        mc = 64
    vk : ., mut = 1
    loop:
        if vk >= mc:
            break
        victim : ., mut = m + vk
        if victim >= mc:
            victim = victim - mc
        _conc_queue_lock(victim)
        vs : ., mut = 0
        found : ., mut = 0
        loop:
            if vs >= slots:
                break
            if _conc_queue_has_slot(victim + vs * mc, 1) != 0:
                found = 1
                break
            vs = vs + 1
        _conc_queue_unlock(victim)
        if found != 0:
            return
        vk = vk + 1
    _conc_futex_wait(_conc_seq_addr(m), s)

fn _conc_act_at(id: int) -> string:
    if id < 0 || id >= g_conc_act_count:
        return ""
    return load_str_ptr(g_conc_acts, id * 8)

fn _conc_queue_lock(m: int):
    if m < 0 || m >= 64:
        m = 0
    if _conc_raw(g_conc_queue_lock_m) == 0:
        return
    // The queue link is a multi-word update. A signal must not switch in the
    // middle of it, or a second M can pop a node that is still being linked.
    cur := _conc_m()
    if _conc_raw(g_conc_preempt_disable_m) != 0:
        cell_store(g_conc_preempt_disable_m, cur * 8,
                   cell_load(g_conc_preempt_disable_m, cur * 8) + 1)
    loop:
        if rt_atomic_load(g_conc_queue_lock_m, m * 8) == 0:
            if rt_atomic_cas(g_conc_queue_lock_m, m * 8, 0, 1) != 0:
                return
        syscall3(24, 0, 0, 0)

fn _conc_queue_unlock(m: int):
    if m < 0 || m >= 64:
        m = 0
    if _conc_raw(g_conc_queue_lock_m) != 0:
        rt_atomic_store(g_conc_queue_lock_m, m * 8, 0)
    cur := _conc_m()
    if _conc_raw(g_conc_preempt_disable_m) != 0:
        d := cell_load(g_conc_preempt_disable_m, cur * 8)
        if d > 0:
            cell_store(g_conc_preempt_disable_m, cur * 8, d - 1)

fn _conc_queue_append(slot: int, id: int):
    // Caller holds the owning M's queue lock.
    a := _conc_act_at(id)
    if _conc_word(a) == 0:
        return
    if cell_load(a, 120) != 0:
        // Defensive: never link the same activation twice.
        return
    cell_store(a, 120, 1)
    cell_store(a, 88, -1)
    tail := cell_load(g_conc_ready_tail_s, slot * 8)
    if tail < 0:
        cell_store(g_conc_ready_head_s, slot * 8, id)
    else:
        ta := _conc_act_at(tail)
        if _conc_word(ta) != 0:
            cell_store(ta, 88, id)
    cell_store(g_conc_ready_tail_s, slot * 8, id)

fn _conc_queue_pop_slot(slot: int, unstarted_only: int) -> int:
    // Caller holds the owning M's queue lock. Skips YIELDING entries (their
    // yielding stack is still live) and, for stealing, started activations
    // (they are pinned to their home M).
    head := cell_load(g_conc_ready_head_s, slot * 8)
    prev : ., mut = -1
    cur : ., mut = head
    loop:
        if cur < 0:
            return -1
        a := _conc_act_at(cur)
        nxt : ., mut = -1
        if _conc_word(a) != 0:
            nxt = cell_load(a, 88)
        take : ., mut = 0
        if _conc_word(a) != 0:
            st := cell_load(a, 8)
            if st == CONC_ACT_RUNNABLE:
                if unstarted_only == 0 || cell_load(a, 64) < 0:
                    take = 1
        if take != 0:
            if prev < 0:
                cell_store(g_conc_ready_head_s, slot * 8, nxt)
            else:
                pa := _conc_act_at(prev)
                if _conc_word(pa) != 0:
                    cell_store(pa, 88, nxt)
            if cell_load(g_conc_ready_tail_s, slot * 8) == cur:
                cell_store(g_conc_ready_tail_s, slot * 8, prev)
            if _conc_word(a) != 0:
                cell_store(a, 120, 0)
                cell_store(a, 88, -1)
            return cur
        if _conc_word(a) == 0:
            // Drop a dead table entry from the queue.
            if prev < 0:
                cell_store(g_conc_ready_head_s, slot * 8, nxt)
            else:
                pa := _conc_act_at(prev)
                if _conc_word(pa) != 0:
                    cell_store(pa, 88, nxt)
            if cell_load(g_conc_ready_tail_s, slot * 8) == cur:
                cell_store(g_conc_ready_tail_s, slot * 8, prev)
            cur = nxt
        else:
            prev = cur
            cur = nxt
    return -1

fn _conc_queue_has_slot(slot: int, unstarted_only: int) -> int:
    // Caller holds the owning M's queue lock.
    cur : ., mut = cell_load(g_conc_ready_head_s, slot * 8)
    loop:
        if cur < 0:
            return 0
        a := _conc_act_at(cur)
        if _conc_word(a) != 0:
            if cell_load(a, 8) == CONC_ACT_RUNNABLE:
                if unstarted_only == 0 || cell_load(a, 64) < 0:
                    return 1
            cur = cell_load(a, 88)
        else:
            cur = -1
    return 0

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
    if g_conc_m_count > 0 && slot % g_conc_m_count != m:
        slot = m
    _conc_queue_lock(m)
    _conc_queue_append(slot, id)
    _conc_queue_unlock(m)
    // The sequence bump follows the queue insert, so a waiter that sampled
    // the old sequence either sees the non-empty queue or gets EAGAIN.
    rt_atomic_fetch_add(g_conc_seq_m, m * 8, 1)
    _conc_futex_wake(_conc_seq_addr(m))

fn _conc_ready_pop() -> int:
    m := _conc_m()
    if _conc_raw(g_conc_queue_lock_m) == 0:
        return -1
    slots : ., mut = g_conc_slots
    if slots < 1:
        slots = 1
    if slots > 64:
        slots = 64
    start : ., mut = cell_load(g_conc_slot_rr_m, m * 8)
    if start < 0 || start >= slots:
        start = 0
    _conc_queue_lock(m)
    k : ., mut = 0
    loop:
        if k >= slots:
            break
        si : ., mut = start + k
        if si >= slots:
            si = si - slots
        slot := m + si * g_conc_m_count
        id := _conc_queue_pop_slot(slot, 0)
        if id >= 0:
            cell_store(g_conc_slot_rr_m, m * 8, si + 1)
            _conc_queue_unlock(m)
            return id
        k = k + 1
    _conc_queue_unlock(m)
    // Work stealing: take an unstarted activation from another M and re-home
    // it here, so its lazy arena/stack is created by the new owner. Started
    // activations stay pinned to their home M.
    mc : ., mut = g_conc_m_count
    if mc > 64:
        mc = 64
    if mc <= 1:
        return -1
    vk : ., mut = 1
    loop:
        if vk >= mc:
            return -1
        victim : ., mut = m + vk
        if victim >= mc:
            victim = victim - mc
        g_conc_steal_attempts = g_conc_steal_attempts + 1
        _conc_queue_lock(victim)
        vs : ., mut = 0
        stolen : ., mut = -1
        loop:
            if vs >= slots:
                break
            vslot := victim + vs * mc
            id2 := _conc_queue_pop_slot(vslot, 1)
            if id2 >= 0:
                stolen = id2
                break
            vs = vs + 1
        if stolen >= 0:
            sa := _conc_act_at(stolen)
            if _conc_word(sa) != 0:
                cell_store(sa, 80, m)
                cell_store(sa, 104, m)
        _conc_queue_unlock(victim)
        if stolen >= 0:
            // The steal removed the activation from the victim queue. Return
            // it directly to conc_schedule; do not append it to this M's queue
            // and also run it, or the queue would retain a link to a running
            // (later dead) activation.
            g_conc_steal_count = g_conc_steal_count + 1
            return stolen
        vk = vk + 1
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
    // Disable direct signal preemption while waiting for or holding the global
    // scheduler lock. The depth is per-M and read by the signal handler.
    m := _conc_m()
    cur := _conc_m()
    if _conc_raw(g_conc_preempt_disable_m) != 0:
        cell_store(g_conc_preempt_disable_m, cur * 8,
                   cell_load(g_conc_preempt_disable_m, cur * 8) + 1)
    loop:
        if rt_atomic_load(g_conc_lock, 0) == 0:
            if rt_atomic_cas(g_conc_lock, 0, 0, 1) != 0:
                return
        syscall3(24, 0, 0, 0)

fn _conc_unlock():
    rt_atomic_store(g_conc_lock, 0, 0)
    m := _conc_m()
    if _conc_raw(g_conc_preempt_disable_m) != 0:
        d := cell_load(g_conc_preempt_disable_m, m * 8)
        if d > 0:
            cell_store(g_conc_preempt_disable_m, m * 8, d - 1)

fn conc_preempt_disable(), pub:
    if g_conc_inited == 0:
        conc_sched_init()
    m := _conc_m()
    if _conc_raw(g_conc_preempt_disable_m) != 0:
        cell_store(g_conc_preempt_disable_m, m * 8,
                   cell_load(g_conc_preempt_disable_m, m * 8) + 1)

fn conc_preempt_enable(), pub:
    if _conc_raw(g_conc_preempt_disable_m) == 0:
        return
    m := _conc_m()
    d := cell_load(g_conc_preempt_disable_m, m * 8)
    if d > 0:
        cell_store(g_conc_preempt_disable_m, m * 8, d - 1)

fn conc_preempt_depth() -> int, pub:
    if _conc_raw(g_conc_preempt_disable_m) == 0:
        return 0
    m := _conc_m()
    return cell_load(g_conc_preempt_disable_m, m * 8)

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
    g_conc_preempt_disable_m = _conc_sched_alloc(64 * 8)
    g_conc_yield_claim_m = _conc_sched_alloc(64 * 8)
    g_conc_queue_lock_m = _conc_sched_alloc(64 * 8)
    i : ., mut = 0
    loop:
        if i >= 64:
            break
        cell_store(g_conc_cur_m, i * 8, -1)
        cell_store(g_conc_preempt_disable_m, i * 8, 0)
        cell_store(g_conc_yield_claim_m, i * 8, 0)
        cell_store(g_conc_queue_lock_m, i * 8, 0)
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

fn _conc_act_new(entry: int, arg: int, result_ch: string, yield_ch: string) -> int:
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
    store_str_ptr(a, 112, yield_ch)
    cell_store(a, 56, -1)
    cell_store(a, 64, -1)
    cell_store(a, 72, 0)
    cell_store(a, 80, home)
    cell_store(a, 88, -1)
    cell_store(a, 96, -1)
    cell_store(a, 104, slot)
    cell_store(a, 120, 0)
    cell_store(a, 128, slot)
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
    id := _conc_act_new(entry, arg, result_ch, "")
    _conc_unlock()
    if id >= 0:
        _conc_ready_push(id)
    return id

fn conc_spawn_flow(entry: int, arg: int, result_ch: string,
                   yield_ch: string) -> int, pub:
    conc_sched_init()
    _conc_lock()
    id := _conc_act_new(entry, arg, result_ch, yield_ch)
    _conc_unlock()
    if id >= 0:
        _conc_ready_push(id)
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
    return cell_load(a, 128)

fn conc_schedule() -> int, pub:
    ran : ., mut = 0
    if _conc_cur_id() < 0:
        saved := arena_current_unchecked()
        loop:
            id := _conc_ready_pop()
            if id < 0:
                return ran
            a := _conc_act_at(id)
            if _conc_word(a) == 0:
                continue
            if cell_load(a, 64) < 0:
                // First run on the home M (or on a thief that re-homed an
                // unstarted activation): create the activation arena and
                // fiber stack here, so the owning partition is only touched
                // by its own thread.
                aidp := arena_new()
                if aidp < 0:
                    cell_store(a, 8, CONC_ACT_DEAD)
                    _conc_lock()
                    _conc_free_push(id)
                    _conc_unlock()
                    continue
                stack := alloc(CONC_SCHED_STACK)
                arena_set_current_unchecked(saved)
                if _conc_word(stack) == 0:
                    arena_reset(aidp)
                    cell_store(a, 8, CONC_ACT_DEAD)
                    _conc_lock()
                    _conc_free_push(id)
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
            arena_set_current_unchecked(cell_load(a, 64))
            fiber_switch(_conc_ptr_addr(_conc_sched_sp_cell()), cell_load(a, 16))
            arena_set_current_unchecked(saved)
            _conc_lock()
            st := cell_load(a, 8)
            root := cell_load(a, 96)
            if st == CONC_ACT_DEAD:
                rt_atomic_store(g_conc_yield_claim_m, _conc_m() * 8, 0)
                arena_reset(root)
                _conc_free_push(id)
            else:
                if st == CONC_ACT_YIELDING:
                    // The yielding stack is now suspended; release the
                    // per-M claim before making it stealable.
                    rt_atomic_store(g_conc_yield_claim_m, _conc_m() * 8, 0)
                    cell_store(a, 8, CONC_ACT_RUNNABLE)
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

fn _conc_yield_try(claimed: int) -> int:
    if g_conc_inited == 0:
        return 0
    if _conc_raw(g_conc_yield_claim_m) == 0:
        return 0
    m := _conc_m()
    if claimed == 0:
        if rt_atomic_cas(g_conc_yield_claim_m, m * 8, 0, 1) == 0:
            return 0
    id := _conc_cur_id()
    if id < 0:
        rt_atomic_store(g_conc_yield_claim_m, m * 8, 0)
        return 0
    a := _conc_act_at(id)
    if _conc_word(a) == 0:
        rt_atomic_store(g_conc_yield_claim_m, m * 8, 0)
        return 0
    cell_store(a, 8, CONC_ACT_YIELDING)
    _conc_ready_push(id)
    conc_schedule()
    return 1

fn conc_yield(), pub:
    _conc_yield_try(0)

fn conc_plan_run(plan: int, root: int, channels: string) -> int, pub:
    // Edge-driven CPU executor. The caller is already executing `root`; this
    // function spawns the transitive SPAWN/JOIN graph, uses SPAWN and JOIN
    // edges as start dependencies, and joins every activation exactly once.
    // SEND/RECV edges carry channel bindings; the bodies perform those
    // operations themselves on the handles in `channels`. DATA_PARALLEL
    // bodies execute through conc_run_range.
    if conc_plan_validate(plan) == 0:
        return -1
    if conc_plan_apply_layouts(plan) < 0:
        return -1
    n := conc_plan_body_count(plan)
    if root < 0 || root >= n:
        return -1
    if _conc_is_null(channels) != 0:
        return -1
    reach := alloc(n * 8)
    indeg := alloc(n * 8)
    placed := alloc(n * 8)
    handles := alloc(n * 8)
    recv_done := alloc(n * 8)
    i : ., mut = 0
    loop:
        if i >= n:
            break
        cell_store(reach, i * 8, 0)
        cell_store(indeg, i * 8, 0)
        cell_store(placed, i * 8, 0)
        cell_store(handles, i * 8, -1)
        cell_store(recv_done, i * 8, 0)
        i = i + 1
    // Reachability follows every edge kind; only SPAWN/JOIN impose start
    // ordering. SEND/RECV are channel bindings.
    q := alloc(n * 8)
    qh : ., mut = 0
    qt : ., mut = 0
    cell_store(q, 0, root)
    qt = 1
    cell_store(reach, root * 8, 1)
    ne := conc_plan_edge_count(plan)
    loop:
        if qh >= qt:
            break
        b := cell_load(q, qh * 8)
        qh = qh + 1
        be : ., mut = 0
        loop:
            if be >= ne:
                break
            if conc_plan_edge_from(plan, be) == b:
                to := conc_plan_edge_to(plan, be)
                if to >= 0 && to < n:
                    if cell_load(reach, to * 8) == 0:
                        cell_store(reach, to * 8, 1)
                        cell_store(q, qt * 8, to)
                        qt = qt + 1
            be = be + 1
    reachable : ., mut = 0
    i = 0
    loop:
        if i >= n:
            break
        if cell_load(reach, i * 8) != 0:
            reachable = reachable + 1
        i = i + 1
    // In-degree for SPAWN/JOIN edges; the root is considered already placed.
    ie : ., mut = 0
    loop:
        if ie >= ne:
            break
        kind := conc_plan_edge_kind(plan, ie)
        if kind == CONC_EDGE_SPAWN || kind == CONC_EDGE_JOIN:
            f := conc_plan_edge_from(plan, ie)
            t := conc_plan_edge_to(plan, ie)
            if f >= 0 && f < n && t >= 0 && t < n:
                if cell_load(reach, f * 8) != 0 && cell_load(reach, t * 8) != 0:
                    cell_store(indeg, t * 8, cell_load(indeg, t * 8) + 1)
        ie = ie + 1
    order := alloc(n * 8)
    on : ., mut = 0
    cell_store(order, 0, root)
    on = 1
    cell_store(placed, root * 8, 1)
    re : ., mut = 0
    loop:
        if re >= ne:
            break
        if conc_plan_edge_kind(plan, re) == CONC_EDGE_SPAWN || conc_plan_edge_kind(plan, re) == CONC_EDGE_JOIN:
            if conc_plan_edge_from(plan, re) == root:
                t := conc_plan_edge_to(plan, re)
                if t >= 0 && t < n:
                    cell_store(indeg, t * 8, cell_load(indeg, t * 8) - 1)
        re = re + 1
    loop:
        if on >= reachable:
            break
        pick : ., mut = -1
        i = 0
        loop:
            if i >= n:
                break
            if cell_load(reach, i * 8) != 0 && cell_load(placed, i * 8) == 0:
                if cell_load(indeg, i * 8) == 0:
                    pick = i
                    break
            i = i + 1
        if pick < 0:
            return -1
        cell_store(order, on * 8, pick)
        on = on + 1
        cell_store(placed, pick * 8, 1)
        te : ., mut = 0
        loop:
            if te >= ne:
                break
            if conc_plan_edge_from(plan, te) == pick:
                if conc_plan_edge_kind(plan, te) == CONC_EDGE_SPAWN || conc_plan_edge_kind(plan, te) == CONC_EDGE_JOIN:
                    t := conc_plan_edge_to(plan, te)
                    if t >= 0 && t < n && cell_load(reach, t * 8) != 0:
                        cell_store(indeg, t * 8, cell_load(indeg, t * 8) - 1)
            te = te + 1
    total : ., mut = 0
    oi : ., mut = 1
    loop:
        if oi >= on:
            break
        b := cell_load(order, oi * 8)
        // JOIN: wait for each incoming source that has already run.
        je : ., mut = 0
        loop:
            if je >= ne:
                break
            if conc_plan_edge_kind(plan, je) == CONC_EDGE_JOIN:
                if conc_plan_edge_to(plan, je) == b:
                    src := conc_plan_edge_from(plan, je)
                    if src != root:
                        if cell_load(handles, src * 8) >= 0:
                            if cell_load(recv_done, src * 8) == 0:
                                total = total + conc_sched_recv_int(cell_load(handles, src * 8))
                                cell_store(recv_done, src * 8, 1)
            je = je + 1
        kind := conc_plan_body_kind(plan, b)
        if kind == CONC_BODY_DATA_PARALLEL:
            rn := conc_plan_range_count(plan)
            ri : ., mut = 0
            loop:
                if ri >= rn:
                    break
                if conc_plan_range_body(plan, ri) == b:
                    start := conc_plan_range_start(plan, ri)
                    cnt := conc_plan_range_len(plan, ri)
                    if cnt > 0:
                        out := alloc(cnt * 8)
                        if conc_run_range(plan, b, start, start + cnt, out) != 0:
                            return -1
                        j : ., mut = 0
                        loop:
                            if j >= cnt:
                                break
                            total = total + cell_load(out, j * 8)
                            j = j + 1
                ri = ri + 1
        else:
            if kind != CONC_BODY_TASK && kind != CONC_BODY_PIPELINE:
                return -1
            arg : ., mut = 0
            ch := conc_plan_param_channel(plan, b, 0)
            if ch >= 0:
                handle := load_str_ptr(channels, ch * 8)
                if _conc_is_null(handle) != 0:
                    return -1
                unsafe:
                    arg = @ptr_of(handle)
            entry := conc_plan_body_entry(plan, b)
            if entry <= 0:
                return -1
            h := conc_go(entry, arg)
            if _conc_word(h) == 0:
                return -1
            cell_store(handles, b * 8, h)
        oi = oi + 1
    // Receive the results of bodies that were not consumed by a JOIN.
    i = 0
    loop:
        if i >= n:
            break
        if cell_load(handles, i * 8) >= 0:
            if cell_load(recv_done, i * 8) == 0:
                total = total + conc_sched_recv_int(cell_load(handles, i * 8))
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

fn conc_flow_yield(v: int), pub:
    id := _conc_cur_id()
    if id < 0:
        return
    a := _conc_act_at(id)
    if _conc_word(a) == 0:
        return
    ych := load_str_ptr(a, 112)
    if _conc_word(ych) != 0:
        conc_sched_send_int(ych, v)
    conc_yield()

fn conc_sched_is_closed(ch: string) -> int, pub:
    conc_sched_init()
    if conc_channel_len(ch) < 0:
        return 1
    slot := _conc_ch_slot(ch)
    return _conc_ch_closed(slot)

fn conc_flow_run(entry: int, arg: int, out: string) -> int, pub:
    // Drive a coroutine flow to completion, collecting each yielded int in
    // `out`. The flow fiber preserves arbitrary control flow and locals across
    // yields; no compiler stage splitting is required.
    conc_sched_init()
    r := _conc_global_region_get()
    if r < 0:
        return -1
    ych := conc_channel_new(r, 8, 1)
    rch := conc_channel_new(r, 8, 1)
    if _conc_word(ych) == 0 || _conc_word(rch) == 0:
        return -1
    id := conc_spawn_flow(entry, arg, rch, ych)
    if id < 0:
        return -1
    n : ., mut = 0
    loop:
        v := conc_sched_recv_int(ych)
        if conc_sched_is_closed(ych) != 0:
            break
        cell_store(out, n * 8, v)
        n = n + 1
    rv := conc_sched_recv_int(rch)
    return n

fn conc_plan_mark_range(entry: int, start: int, count: int), pub:
    // Compiler-to-plan marker; the default runtime uses the IR loop.
    return

fn conc_preempt_tick(), pub:
    // Inserted at user loop backedges. No-op when the conc scheduler is not
    // active, so ordinary programs and compiler/stdlib loops are untouched.
    if g_conc_inited == 0:
        return
    if _conc_raw(g_conc_preempt_disable_m) != 0:
        if cell_load(g_conc_preempt_disable_m, _conc_m() * 8) != 0:
            return
    if g_conc_preempt_flag != 0:
        if _conc_yield_try(0) != 0:
            g_conc_preempt_flag = 0
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
    ych := load_str_ptr(a, 112)
    if _conc_word(ych) != 0:
        conc_sched_close(ych)
    ch := load_str_ptr(a, 48)
    if _conc_word(ch) != 0:
        conc_sched_send_int(ch, rc)
    // Claim this M's yield slot for the teardown so a signal cannot push the
    // dying activation back onto a ready queue between DEAD and the switch.
    m := _conc_m()
    if _conc_raw(g_conc_yield_claim_m) != 0:
        loop:
            if rt_atomic_cas(g_conc_yield_claim_m, m * 8, 0, 1) != 0:
                break
            syscall3(24, 0, 0, 0)
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
