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
CONC_ACT_SIZE : int = 160
CONC_ACT_RUNNABLE : int = 0
CONC_ACT_RUNNING : int = 1
CONC_ACT_WAITING : int = 2
CONC_ACT_DEAD : int = 3
CONC_ACT_YIELDING : int = 4

CONC_RESULT_CANCELLED : int, pub = -2
CONC_RESULT_TIMEOUT : int, pub = -3
CONC_TRY_EMPTY : int, pub = -9223372036854775807
CONC_TRY_CLOSED : int, pub = -9223372036854775806
CONC_CHAN_OK : int, pub = 0
CONC_CHAN_CLOSED : int, pub = -1
CONC_CHAN_INVALID : int, pub = -2

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
g_conc_ch_lock : string, mut
g_conc_region_lock : string, mut
g_conc_arena_lock : string, mut
g_conc_tid_m : string, mut
g_conc_timer_m : string, mut
g_conc_m_count : int, mut = 1
g_conc_slots : int, mut = 1
g_conc_global_region : int, mut = -1
g_conc_ch_states : string, mut
g_conc_ch_count : int, mut = 0
g_conc_ch_cap : int, mut = 0
g_conc_free : string, mut
g_conc_free_count : int, mut = 0
g_conc_free_cap : int, mut = 0
// Dedicated free-list lock: spawn/free reuse no longer takes the global
// scheduler lock. The global lock is only used for table growth/new ids.
g_conc_free_lock : string, mut
g_conc_spawn_rr_buf : string, mut
// New activation ids are issued atomically; only table growth/install takes
// this lock. This removes the global scheduler lock from the spawn path.
g_conc_table_lock : string, mut
g_conc_act_id_buf : string, mut
g_conc_quantum : int, mut = 2000
g_conc_quantum_m : string, mut
g_conc_quantum_cfg_m : string, mut
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
g_conc_spawn_count : int, mut = 0
g_conc_yield_count : int, mut = 0
g_conc_ready_push_count : int, mut = 0
g_conc_ready_pop_count : int, mut = 0
g_conc_park_count : int, mut = 0
g_conc_futex_wait_count : int, mut = 0
g_conc_wake_count : int, mut = 0
g_conc_preempt_signal_count : int, mut = 0
g_conc_preempt_direct_count : int, mut = 0
g_conc_preempt_tick_count : int, mut = 0
g_conc_send_count : int, mut = 0
g_conc_recv_count : int, mut = 0
// Atomic counters: sends/recvs happen on different Ms, so plain int
// increments lose updates and make metrics tests nondeterministic.
g_conc_metric_send : string, mut
g_conc_metric_recv : string, mut
g_conc_close_count : int, mut = 0
g_conc_wait_count : int, mut = 0
g_conc_wait_ms_total : int, mut = 0
g_conc_wait_ms_max : int, mut = 0
g_conc_main_parked : int, mut = 0
g_conc_flow_cancel : int, mut = 0
g_conc_pipeline_cancel : int, mut = 0
g_conc_plan_cancel : int, mut = 0
g_conc_sig_ts : string, mut
g_conc_now_ts_m : string, mut
g_conc_preempt_pending_ms : int, mut = 0
g_conc_preempt_latency_max : int, mut = 0
g_conc_flow_ych : string, mut
g_conc_flow_rch : string, mut
g_conc_cancel_used : string, mut
g_conc_cancel_flags : string, mut
g_conc_cancel_a : string, mut
g_conc_cancel_b : string, mut
g_conc_cancel_n : string, mut
g_conc_cancel_mode : string, mut

fn _conc_sched_alloc(size: int) -> string:
    // Scheduler arrays are shared across Ms; allocate them from the reserved
    // shared partition. The shared arena allocator is not reentrant, and callers
    // now hold different domain locks (global/channel/queue), so serialize the
    // allocation itself here.
    if _conc_raw(g_conc_arena_lock) == 0:
        return arena_shared_alloc(size)
    if g_conc_pi_locks != 0:
        conc_pi_lock(g_conc_arena_lock)
        p := arena_shared_alloc(size)
        conc_pi_unlock(g_conc_arena_lock)
        return p
    loop:
        if rt_atomic_load(g_conc_arena_lock, 0) == 0:
            if rt_atomic_cas(g_conc_arena_lock, 0, 0, 1) != 0:
                break
        syscall3(24, 0, 0, 0)
    p := arena_shared_alloc(size)
    rt_atomic_store(g_conc_arena_lock, 0, 0)
    return p

fn _conc_now_ms_sig() -> int:
    if _conc_raw(g_conc_sig_ts) == 0:
        return -1
    cell_store(g_conc_sig_ts, 0, 0)
    cell_store(g_conc_sig_ts, 8, 0)
    r := syscall3(228, 1, g_conc_sig_ts, 0)
    if r < 0:
        return -1
    return cell_load(g_conc_sig_ts, 0) * 1000 + cell_load(g_conc_sig_ts, 8) / 1000000

fn _conc_preempt_latency_record():
    if g_conc_preempt_pending_ms <= 0:
        return
    now := _conc_now_ms_sig()
    if now < g_conc_preempt_pending_ms:
        return
    d := now - g_conc_preempt_pending_ms
    if d > g_conc_preempt_latency_max:
        g_conc_preempt_latency_max = d
    g_conc_preempt_pending_ms = 0

fn conc_preempt_signal():
    // The handler first publishes a pending flag (always safe). When the
    // interrupted thread is running an activation, is not inside a disabled
    // critical section, and is actually on that activation's stack, it may
    // switch directly. The per-M claim word prevents a nested switch while a
    // cooperative yield is already in flight.
    if g_conc_signal_preempt != 0:
        g_conc_preempt_signal_count = g_conc_preempt_signal_count + 1
        g_conc_preempt_pending_ms = _conc_now_ms_sig()
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
                                            g_conc_preempt_direct_count = g_conc_preempt_direct_count + 1
                                            _conc_yield_try(1)
                                            _conc_preempt_latency_record()

fn _conc_preempt_install():
    act := _conc_sched_alloc(32)
    cell_store(act, 0, @addr(conc_preempt_signal))
    // SA_RESTART | SA_RESTORER
    cell_store(act, 8, 335544320)
    cell_store(act, 16, @addr(rt_sigreturn_stub))
    cell_store(act, 24, 0)
    r := syscall4(13, 14, _conc_addr(act), 0, 8)

fn _conc_preempt_timers_start():
    if _conc_raw(g_conc_tid_m) == 0 || _conc_raw(g_conc_timer_m) == 0:
        return
    mc : ., mut = g_conc_m_count
    if mc > 64:
        mc = 64
    started : ., mut = 0
    m : ., mut = 0
    loop:
        if m >= mc:
            break
        tid := cell_load(g_conc_tid_m, m * 8)
        if tid > 0 && cell_load(g_conc_timer_m, m * 8) < 0:
            sev := alloc(64)
            cell_store(sev, 0, 0)
            cell_store(sev, 8, 14)   // SIGALRM
            cell_store(sev, 12, 4)   // SIGEV_THREAD_ID
            cell_store(sev, 16, tid)
            tp := alloc(8)
            r := syscall3(222, 1, sev, tp)  // timer_create(CLOCK_MONOTONIC)
            if r == 0:
                t := cell_load(tp, 0)
                its := alloc(32)
                cell_store(its, 0, 0)
                cell_store(its, 8, 5000000)
                cell_store(its, 16, 0)
                cell_store(its, 24, 5000000)
                r2 := syscall4(223, t, 0, its, 0)  // timer_settime
                if r2 == 0:
                    cell_store(g_conc_timer_m, m * 8, t)
                    started = started + 1
        m = m + 1
    if started == 0:
        // Fallback for kernels without SIGEV_THREAD_ID: process-wide timer.
        iv := _conc_sched_alloc(32)
        cell_store(iv, 0, 0)
        cell_store(iv, 8, 5000000)
        cell_store(iv, 16, 0)
        cell_store(iv, 24, 5000000)
        syscall3(38, 0, _conc_addr(iv), 0)

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
            cell_store(g_conc_quantum_cfg_m, i * 8, n)
            i = i + 1

fn conc_set_quantum_m(m: int, n: int) -> int, pub:
    if m < 0 || m >= 64:
        return -1
    if n < 1:
        n = 1
    if _conc_raw(g_conc_quantum_cfg_m) == 0:
        return -1
    cell_store(g_conc_quantum_cfg_m, m * 8, n)
    cell_store(g_conc_quantum_m, m * 8, n)
    return 0

fn conc_get_quantum_m(m: int) -> int, pub:
    if m < 0 || m >= 64:
        return -1
    if _conc_raw(g_conc_quantum_cfg_m) == 0:
        return g_conc_quantum
    return cell_load(g_conc_quantum_cfg_m, m * 8)

fn _conc_seq_addr(m: int) -> int:
    return _conc_addr(g_conc_seq_m) + m * 8

fn _conc_wake_main_seq():
    if g_conc_m_count <= 1:
        return
    if g_conc_main_parked == 0:
        return
    seq := rt_atomic_load(g_conc_seq_m, 0)
    rt_atomic_store(g_conc_seq_m, 0, seq + 1)
    _conc_futex_wake(_conc_seq_addr(0))

fn _conc_futex_wait(addr: int, val: int) -> int:
    g_conc_futex_wait_count = g_conc_futex_wait_count + 1
    // futex(uaddr, FUTEX_WAIT, val, timeout, uaddr2, val3). The 2 ms timeout
    // is a safety net for channel polling (the main thread is not a channel
    // waiter), so a missed notification delays but never deadlocks.
    return syscall6(202, addr, 0, val, _conc_addr(g_conc_timespec), 0, 0)

fn _conc_futex_wake(addr: int) -> int:
    g_conc_wake_count = g_conc_wake_count + 1
    // futex(uaddr, FUTEX_WAKE, 1, 0, 0, 0)
    return syscall6(202, addr, 1, 1, 0, 0, 0)

fn conc_spawn_count() -> int, pub:
    return g_conc_spawn_count

fn conc_yield_count() -> int, pub:
    return g_conc_yield_count

fn conc_ready_push_count() -> int, pub:
    return g_conc_ready_push_count

fn conc_ready_pop_count() -> int, pub:
    return g_conc_ready_pop_count

fn conc_park_count() -> int, pub:
    return g_conc_park_count

fn conc_futex_wait_count() -> int, pub:
    return g_conc_futex_wait_count

fn conc_wake_count() -> int, pub:
    return g_conc_wake_count

fn conc_preempt_signal_count() -> int, pub:
    return g_conc_preempt_signal_count

fn conc_preempt_direct_count() -> int, pub:
    return g_conc_preempt_direct_count

fn conc_preempt_tick_count() -> int, pub:
    return g_conc_preempt_tick_count

fn conc_preempt_latency_max() -> int, pub:
    return g_conc_preempt_latency_max

fn conc_timer_count() -> int, pub:
    if _conc_raw(g_conc_timer_m) == 0:
        return 0
    n : ., mut = 0
    i : ., mut = 0
    loop:
        if i >= 64:
            return n
        if cell_load(g_conc_timer_m, i * 8) >= 0:
            n = n + 1
        i = i + 1
    return n

fn conc_send_count() -> int, pub:
    if _conc_raw(g_conc_metric_send) == 0:
        return 0
    return rt_atomic_load(g_conc_metric_send, 0)

fn conc_recv_count() -> int, pub:
    if _conc_raw(g_conc_metric_recv) == 0:
        return 0
    return rt_atomic_load(g_conc_metric_recv, 0)

fn conc_close_count() -> int, pub:
    return g_conc_close_count

fn conc_wait_count() -> int, pub:
    return g_conc_wait_count

fn conc_wait_ms_total() -> int, pub:
    return g_conc_wait_ms_total

fn conc_wait_ms_max() -> int, pub:
    return g_conc_wait_ms_max

fn conc_metrics_reset() -> int, pub:
    g_conc_spawn_count = 0
    g_conc_yield_count = 0
    g_conc_ready_push_count = 0
    g_conc_ready_pop_count = 0
    g_conc_park_count = 0
    g_conc_futex_wait_count = 0
    g_conc_wake_count = 0
    g_conc_steal_attempts = 0
    g_conc_steal_count = 0
    g_conc_preempt_signal_count = 0
    g_conc_preempt_direct_count = 0
    g_conc_preempt_tick_count = 0
    g_conc_send_count = 0
    g_conc_recv_count = 0
    if _conc_raw(g_conc_metric_send) != 0:
        rt_atomic_store(g_conc_metric_send, 0, 0)
    if _conc_raw(g_conc_metric_recv) != 0:
        rt_atomic_store(g_conc_metric_recv, 0, 0)
    g_conc_close_count = 0
    g_conc_wait_count = 0
    g_conc_wait_ms_total = 0
    g_conc_wait_ms_max = 0
    return 0

fn conc_metrics_explain() -> string, pub:
    out : ., mut = "spawn=" + _conc_num_str(g_conc_spawn_count)
    out = out + " yield=" + _conc_num_str(g_conc_yield_count)
    out = out + " push=" + _conc_num_str(g_conc_ready_push_count)
    out = out + " pop=" + _conc_num_str(g_conc_ready_pop_count)
    out = out + " park=" + _conc_num_str(g_conc_park_count)
    out = out + " futexwait=" + _conc_num_str(g_conc_futex_wait_count)
    out = out + " wake=" + _conc_num_str(g_conc_wake_count)
    out = out + " steal=" + _conc_num_str(g_conc_steal_count)
    out = out + " steal_try=" + _conc_num_str(g_conc_steal_attempts)
    out = out + " sig=" + _conc_num_str(g_conc_preempt_signal_count)
    out = out + " direct=" + _conc_num_str(g_conc_preempt_direct_count)
    out = out + " tick=" + _conc_num_str(g_conc_preempt_tick_count)
    out = out + " send=" + _conc_num_str(conc_send_count())
    out = out + " recv=" + _conc_num_str(conc_recv_count())
    out = out + " close=" + _conc_num_str(g_conc_close_count)
    out = out + " waits=" + _conc_num_str(g_conc_wait_count)
    out = out + " wait_ms=" + _conc_num_str(g_conc_wait_ms_total)
    out = out + " wait_max=" + _conc_num_str(g_conc_wait_ms_max)
    return out

fn conc_ready_len(m: int) -> int, pub:
    if m < 0 || m >= 64:
        return -1
    if _conc_raw(g_conc_queue_lock_m) == 0:
        return 0
    slots : ., mut = g_conc_slots
    if slots < 1:
        slots = 1
    if slots > 64:
        slots = 64
    _conc_queue_lock(m)
    total : ., mut = 0
    si : ., mut = 0
    loop:
        if si >= slots:
            break
        cur : ., mut = cell_load(g_conc_ready_head_s, (m + si * g_conc_m_count) * 8)
        lim : ., mut = 0
        loop:
            if cur < 0:
                break
            lim = lim + 1
            if lim > 100000:
                msg : ., mut = "QCYCLE len m=" + _conc_num_str(m)
                msg = msg + " cur=" + _conc_num_str(cur) + "\n"
                syscall3(1, 2, msg, str_len(msg))
                syscall3(60, 77, 0, 0)
            total = total + 1
            ca := _conc_act_at(cur)
            if _conc_word(ca) == 0:
                break
            cur = cell_load(ca, 88)
            lim = lim + 1
        si = si + 1
    _conc_queue_unlock(m)
    return total

fn conc_runtime_target_name() -> string, pub:
    return "cpu"

fn conc_runtime_slots() -> int, pub:
    return g_conc_m_count

fn conc_runtime_memory() -> int, pub:
    return g_arena_pool_limit

fn conc_plan_target_compatible(plan: int) -> int, pub:
    // Runtime probe: a plan is compatible when its declared target is cpu and
    // its slot/memory request does not exceed this process's configured
    // runtime. An empty target is treated as target-neutral.
    if conc_plan_validate(plan) == 0:
        return 0
    prof := conc_plan_profile(plan)
    if prof >= 0:
        return conc_target_profile_compatible(prof, plan)
    name := conc_plan_target_name(plan)
    if _conc_word(name) != 0:
        if name != "cpu":
            return 0
    slots := conc_plan_target_slots(plan)
    if slots > 0 && slots > g_conc_m_count:
        return 0
    mem := conc_plan_target_memory(plan)
    if mem > 0 && g_arena_pool_limit > 0 && mem > g_arena_pool_limit:
        return 0
    return 1

fn conc_state_explain() -> string, pub:
    out : ., mut = "ms=" + _conc_num_str(g_conc_m_count)
    out = out + " acts=" + _conc_num_str(g_conc_act_count)
    out = out + " waiting=" + _conc_num_str(conc_waiting_count())
    out = out + " deadlock=" + _conc_num_str(conc_deadlock_suspect())
    out = out + " shutdown=" + _conc_num_str(g_conc_shutdown)
    mc : ., mut = g_conc_m_count
    if mc > 64:
        mc = 64
    m : ., mut = 0
    loop:
        if m >= mc:
            break
        out = out + "\nM" + _conc_num_str(m)
        out = out + " cur=" + _conc_num_str(cell_load(g_conc_cur_m, m * 8))
        out = out + " ready=" + _conc_num_str(conc_ready_len(m))
        out = out + " quantum=" + _conc_num_str(conc_get_quantum_m(m))
        m = m + 1
    return out

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
    _conc_preempt_timers_start()

fn conc_shutdown(), pub:
    // Cancel idle workers: set the stop flag and wake every M's futex word.
    _conc_lock()
    if g_conc_shutdown != 0:
        _conc_unlock()
        return
    g_conc_shutdown = 1
    // Cancellation propagation: close every registered channel and wake its
    // send/receive waiters before parking workers. A blocked activation then
    // returns through its normal close path instead of disappearing.
    _conc_ch_lock()
    ci : ., mut = 0
    loop:
        if ci >= g_conc_ch_count:
            break
        _conc_ch_set_closed(ci)
        _conc_wake_all(ci, CONC_WAIT_SEND)
        _conc_wake_all(ci, CONC_WAIT_RECV)
        ci = ci + 1
    _conc_ch_unlock()
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
    g_conc_park_count = g_conc_park_count + 1
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
            if _conc_queue_has_slot(victim + vs * mc, 0) != 0:
                found = 1
                break
            vs = vs + 1
        _conc_queue_unlock(victim)
        if found != 0:
            return
        vk = vk + 1
    if m == 0:
        g_conc_main_parked = 1
    t0 := _conc_now_ms()
    _conc_futex_wait(_conc_seq_addr(m), s)
    if m == 0:
        g_conc_main_parked = 0
    _conc_wait_record(t0)

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
    if g_conc_pi_locks != 0:
        w := _conc_ptr(_conc_addr(g_conc_queue_lock_m) + m * 8)
        conc_pi_lock(w)
        return
    loop:
        if rt_atomic_load(g_conc_queue_lock_m, m * 8) == 0:
            if rt_atomic_cas(g_conc_queue_lock_m, m * 8, 0, 1) != 0:
                return
        syscall3(24, 0, 0, 0)

fn _conc_queue_unlock(m: int):
    if m < 0 || m >= 64:
        m = 0
    if g_conc_pi_locks != 0:
        w := _conc_ptr(_conc_addr(g_conc_queue_lock_m) + m * 8)
        conc_pi_unlock(w)
    else:
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
    cell_store(a, 152, tail)
    if tail < 0:
        cell_store(g_conc_ready_head_s, slot * 8, id)
    else:
        ta := _conc_act_at(tail)
        if _conc_word(ta) != 0:
            cell_store(ta, 88, id)
    cell_store(g_conc_ready_tail_s, slot * 8, id)

fn _conc_queue_append_front(slot: int, id: int):
    // Caller holds the owning M's queue lock.
    a := _conc_act_at(id)
    if _conc_word(a) == 0:
        return
    if cell_load(a, 120) != 0:
        return
    cell_store(a, 120, 1)
    head := cell_load(g_conc_ready_head_s, slot * 8)
    cell_store(a, 88, head)
    cell_store(a, 152, -1)
    if head >= 0:
        ha := _conc_act_at(head)
        if _conc_word(ha) != 0:
            cell_store(ha, 152, id)
    cell_store(g_conc_ready_head_s, slot * 8, id)
    if head < 0:
        cell_store(g_conc_ready_tail_s, slot * 8, id)

fn _conc_queue_pop_slot(slot: int, unstarted_only: int) -> int:
    // Caller holds the owning M's queue lock. Skips YIELDING entries (their
    // yielding stack is still live) and, when unstarted_only is set, started
    // activations. A runnable yielded activation can be taken and re-homed.
    head := cell_load(g_conc_ready_head_s, slot * 8)
    prev : ., mut = -1
    cur : ., mut = head
    qlim : ., mut = 0
    loop:
        if cur < 0:
            return -1
        qlim = qlim + 1
        if qlim > 100000:
            msg : ., mut = "QCYCLE pop slot=" + _conc_num_str(slot)
            msg = msg + " cur=" + _conc_num_str(cur) + "\n"
            syscall3(1, 2, msg, str_len(msg))
            syscall3(60, 77, 0, 0)
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
            if nxt >= 0:
                na := _conc_act_at(nxt)
                if _conc_word(na) != 0:
                    cell_store(na, 152, prev)
            if cell_load(g_conc_ready_tail_s, slot * 8) == cur:
                cell_store(g_conc_ready_tail_s, slot * 8, prev)
            if _conc_word(a) != 0:
                cell_store(a, 120, 0)
                cell_store(a, 88, -1)
                cell_store(a, 152, -1)
            return cur
        if _conc_word(a) == 0:
            // Drop a dead table entry from the queue.
            if prev < 0:
                cell_store(g_conc_ready_head_s, slot * 8, nxt)
            else:
                pa := _conc_act_at(prev)
                if _conc_word(pa) != 0:
                    cell_store(pa, 88, nxt)
            if nxt >= 0:
                na := _conc_act_at(nxt)
                if _conc_word(na) != 0:
                    cell_store(na, 152, prev)
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
    hlim : ., mut = 0
    loop:
        if cur < 0:
            return 0
        hlim = hlim + 1
        if hlim > 100000:
            msg : ., mut = "QCYCLE has slot=" + _conc_num_str(slot)
            msg = msg + " cur=" + _conc_num_str(cur) + "\n"
            syscall3(1, 2, msg, str_len(msg))
            syscall3(60, 77, 0, 0)
        a := _conc_act_at(cur)
        if _conc_word(a) != 0:
            if cell_load(a, 8) == CONC_ACT_RUNNABLE:
                if unstarted_only == 0 || cell_load(a, 64) < 0:
                    return 1
            cur = cell_load(a, 88)
        else:
            cur = -1
    return 0

fn _conc_queue_steal_tail_slot(slot: int, unstarted_only: int) -> int:
    // Caller holds the owning M's queue lock. Doubly linked, so the common
    // case takes the tail in O(1); only YIELDING/dead entries walk backward.
    cur : ., mut = cell_load(g_conc_ready_tail_s, slot * 8)
    qlim : ., mut = 0
    loop:
        if cur < 0:
            return -1
        qlim = qlim + 1
        if qlim > 100000:
            msg : ., mut = "QCYCLE steal slot=" + _conc_num_str(slot)
            msg = msg + " cur=" + _conc_num_str(cur) + "\n"
            syscall3(1, 2, msg, str_len(msg))
            syscall3(60, 77, 0, 0)
        a := _conc_act_at(cur)
        prv := cell_load(a, 152)
        nxt := cell_load(a, 88)
        take : ., mut = 0
        if _conc_word(a) != 0:
            st := cell_load(a, 8)
            if st == CONC_ACT_RUNNABLE:
                if unstarted_only == 0 || cell_load(a, 64) < 0:
                    take = 1
        if take != 0:
            if prv < 0:
                cell_store(g_conc_ready_head_s, slot * 8, nxt)
            else:
                pa := _conc_act_at(prv)
                if _conc_word(pa) != 0:
                    cell_store(pa, 88, nxt)
            if nxt >= 0:
                na := _conc_act_at(nxt)
                if _conc_word(na) != 0:
                    cell_store(na, 152, prv)
            if cell_load(g_conc_ready_tail_s, slot * 8) == cur:
                cell_store(g_conc_ready_tail_s, slot * 8, prv)
            if _conc_word(a) != 0:
                cell_store(a, 120, 0)
                cell_store(a, 88, -1)
                cell_store(a, 152, -1)
            return cur
        if _conc_word(a) == 0:
            // Drop a dead table entry; continue from its predecessor.
            if prv < 0:
                cell_store(g_conc_ready_head_s, slot * 8, nxt)
            else:
                pa := _conc_act_at(prv)
                if _conc_word(pa) != 0:
                    cell_store(pa, 88, nxt)
            if nxt >= 0:
                na := _conc_act_at(nxt)
                if _conc_word(na) != 0:
                    cell_store(na, 152, prv)
            if cell_load(g_conc_ready_tail_s, slot * 8) == cur:
                cell_store(g_conc_ready_tail_s, slot * 8, prv)
        cur = prv
    return -1

fn _conc_ready_push(id: int):
    g_conc_ready_push_count = g_conc_ready_push_count + 1
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
    if cell_load(a, 144) > 0:
        _conc_queue_append_front(slot, id)
    else:
        _conc_queue_append(slot, id)
    _conc_queue_unlock(m)
    // The sequence bump follows the queue insert, so a waiter that sampled
    // the old sequence either sees the non-empty queue or gets EAGAIN.
    rt_atomic_fetch_add(g_conc_seq_m, m * 8, 1)
    _conc_futex_wake(_conc_seq_addr(m))

fn _conc_ready_pop() -> int:
    g_conc_ready_pop_count = g_conc_ready_pop_count + 1
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
    // Work stealing: re-home a runnable activation from another M. Unstarted
    // activations get their lazy arena/stack from the thief. Started-but-
    // yielded activations keep their saved fiber stack/arena; only the home M
    // and slot move, so the next resume runs on this thread.
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
            id2 := _conc_queue_steal_tail_slot(vslot, 0)
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
    loop:
        if nc >= g_conc_act_count:
            break
        nc = nc * 2
    nb := _conc_sched_alloc(nc * 8)
    // Clear new slots explicitly: alloc is not guaranteed to return zeros.
    i : ., mut = 0
    loop:
        if i >= nc:
            break
        cell_store(nb, i * 8, 0)
        i = i + 1
    i = 0
    loop:
        if i >= g_conc_act_count:
            break
        if i < g_conc_act_cap:
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
    if g_conc_pi_locks != 0:
        conc_pi_lock(g_conc_lock)
        return
    loop:
        if rt_atomic_load(g_conc_lock, 0) == 0:
            if rt_atomic_cas(g_conc_lock, 0, 0, 1) != 0:
                return
        syscall3(24, 0, 0, 0)

fn _conc_unlock():
    if g_conc_pi_locks != 0:
        conc_pi_unlock(g_conc_lock)
    else:
        rt_atomic_store(g_conc_lock, 0, 0)
    m := _conc_m()
    if _conc_raw(g_conc_preempt_disable_m) != 0:
        d := cell_load(g_conc_preempt_disable_m, m * 8)
        if d > 0:
            cell_store(g_conc_preempt_disable_m, m * 8, d - 1)

fn _conc_ch_lock():
    cur := _conc_m()
    if _conc_raw(g_conc_preempt_disable_m) != 0:
        cell_store(g_conc_preempt_disable_m, cur * 8,
                   cell_load(g_conc_preempt_disable_m, cur * 8) + 1)
    if g_conc_pi_locks != 0:
        conc_pi_lock(g_conc_ch_lock)
        return
    loop:
        if rt_atomic_load(g_conc_ch_lock, 0) == 0:
            if rt_atomic_cas(g_conc_ch_lock, 0, 0, 1) != 0:
                return
        syscall3(24, 0, 0, 0)

fn _conc_ch_unlock():
    if g_conc_pi_locks != 0:
        conc_pi_unlock(g_conc_ch_lock)
    else:
        if _conc_raw(g_conc_ch_lock) != 0:
            rt_atomic_store(g_conc_ch_lock, 0, 0)
    cur := _conc_m()
    if _conc_raw(g_conc_preempt_disable_m) != 0:
        d := cell_load(g_conc_preempt_disable_m, cur * 8)
        if d > 0:
            cell_store(g_conc_preempt_disable_m, cur * 8, d - 1)

fn _conc_region_lock():
    cur := _conc_m()
    if _conc_raw(g_conc_preempt_disable_m) != 0:
        cell_store(g_conc_preempt_disable_m, cur * 8,
                   cell_load(g_conc_preempt_disable_m, cur * 8) + 1)
    if g_conc_pi_locks != 0:
        conc_pi_lock(g_conc_region_lock)
        return
    loop:
        if rt_atomic_load(g_conc_region_lock, 0) == 0:
            if rt_atomic_cas(g_conc_region_lock, 0, 0, 1) != 0:
                return
        syscall3(24, 0, 0, 0)

fn _conc_region_unlock():
    if g_conc_pi_locks != 0:
        conc_pi_unlock(g_conc_region_lock)
    else:
        if _conc_raw(g_conc_region_lock) != 0:
            rt_atomic_store(g_conc_region_lock, 0, 0)
    cur := _conc_m()
    if _conc_raw(g_conc_preempt_disable_m) != 0:
        d := cell_load(g_conc_preempt_disable_m, cur * 8)
        if d > 0:
            cell_store(g_conc_preempt_disable_m, cur * 8, d - 1)

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

// Opt-in PI futex mode for the runtime's internal locks. The kernel tracks the
// owner and applies priority inheritance, which the spin path cannot do.
g_conc_pi_locks : int, mut = 0

fn conc_sched_set_pi(v: int) -> int, pub:
    if v != 0 && v != 1:
        return -1
    g_conc_pi_locks = v
    return 0

fn conc_sched_pi_enabled() -> int, pub:
    return g_conc_pi_locks

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
    g_conc_arena_lock = _conc_sched_alloc(8)
    cell_store(g_conc_arena_lock, 0, 0)
    g_conc_tid_m = _conc_sched_alloc(64 * 8)
    g_conc_timer_m = _conc_sched_alloc(64 * 8)
    iti : ., mut = 0
    loop:
        if iti >= 64:
            break
        cell_store(g_conc_tid_m, iti * 8, -1)
        cell_store(g_conc_timer_m, iti * 8, -1)
        iti = iti + 1
    cell_store(g_conc_tid_m, 0, syscall3(186, 0, 0, 0))
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
    g_conc_ch_lock = _conc_sched_alloc(8)
    cell_store(g_conc_ch_lock, 0, 0)
    g_conc_region_lock = _conc_sched_alloc(8)
    cell_store(g_conc_region_lock, 0, 0)
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
    g_conc_free_lock = _conc_sched_alloc(8)
    cell_store(g_conc_free_lock, 0, 0)
    g_conc_spawn_rr_buf = _conc_sched_alloc(8)
    cell_store(g_conc_spawn_rr_buf, 0, 0)
    g_conc_table_lock = _conc_sched_alloc(8)
    cell_store(g_conc_table_lock, 0, 0)
    g_conc_act_id_buf = _conc_sched_alloc(8)
    cell_store(g_conc_act_id_buf, 0, 0)
    g_conc_quantum_m = _conc_sched_alloc(64 * 8)
    g_conc_quantum_cfg_m = _conc_sched_alloc(64 * 8)
    g_conc_seq_m = _conc_sched_alloc(64 * 8)
    g_conc_metric_send = _conc_sched_alloc(8)
    g_conc_metric_recv = _conc_sched_alloc(8)
    cell_store(g_conc_metric_send, 0, 0)
    cell_store(g_conc_metric_recv, 0, 0)
    g_conc_timespec = _conc_sched_alloc(16)
    g_conc_sig_ts = _conc_sched_alloc(16)
    g_conc_now_ts_m = _conc_sched_alloc(64 * 16)
    g_conc_cancel_used = _conc_sched_alloc(64 * 8)
    g_conc_cancel_flags = _conc_sched_alloc(64 * 8)
    g_conc_cancel_a = _conc_sched_alloc(64 * 8)
    g_conc_cancel_b = _conc_sched_alloc(64 * 8)
    g_conc_cancel_n = _conc_sched_alloc(64 * 8)
    g_conc_cancel_mode = _conc_sched_alloc(64 * 8)
    cell_store(g_conc_timespec, 0, 0)
    cell_store(g_conc_timespec, 8, 50000)
    _conc_preempt_install()
    _conc_preempt_timers_start()
    iq : ., mut = 0
    loop:
        if iq >= 64:
            break
        cell_store(g_conc_quantum_m, iq * 8, g_conc_quantum)
        cell_store(g_conc_quantum_cfg_m, iq * 8, g_conc_quantum)
        cell_store(g_conc_cancel_used, iq * 8, 0)
        cell_store(g_conc_cancel_flags, iq * 8, 0)
        cell_store(g_conc_cancel_a, iq * 8, 0)
        cell_store(g_conc_cancel_b, iq * 8, 0)
        cell_store(g_conc_cancel_n, iq * 8, 0)
        cell_store(g_conc_cancel_mode, iq * 8, 0)
        cell_store(g_conc_seq_m, iq * 8, 0)
        iq = iq + 1
    g_conc_inited = 1

fn _conc_free_lock():
    if _conc_raw(g_conc_free_lock) == 0:
        return
    loop:
        if rt_atomic_load(g_conc_free_lock, 0) == 0:
            if rt_atomic_cas(g_conc_free_lock, 0, 0, 1) != 0:
                return
        syscall3(24, 0, 0, 0)

fn _conc_free_unlock():
    if _conc_raw(g_conc_free_lock) != 0:
        rt_atomic_store(g_conc_free_lock, 0, 0)

fn _conc_table_lock():
    if _conc_raw(g_conc_table_lock) == 0:
        return
    if g_conc_pi_locks != 0:
        conc_pi_lock(g_conc_table_lock)
        return
    loop:
        if rt_atomic_load(g_conc_table_lock, 0) == 0:
            if rt_atomic_cas(g_conc_table_lock, 0, 0, 1) != 0:
                return
        syscall3(24, 0, 0, 0)

fn _conc_table_unlock():
    if _conc_raw(g_conc_table_lock) == 0:
        return
    if g_conc_pi_locks != 0:
        conc_pi_unlock(g_conc_table_lock)
    else:
        rt_atomic_store(g_conc_table_lock, 0, 0)

fn _conc_free_push(id: int):
    if _conc_raw(g_conc_free) == 0:
        return
    _conc_free_lock()
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
    _conc_free_unlock()

fn _conc_free_pop() -> int:
    if _conc_raw(g_conc_free) == 0:
        return -1
    _conc_free_lock()
    if g_conc_free_count <= 0:
        _conc_free_unlock()
        return -1
    g_conc_free_count = g_conc_free_count - 1
    id := cell_load(g_conc_free, g_conc_free_count * 8)
    _conc_free_unlock()
    return id

fn _conc_act_init(id: int, a: string, entry: int, arg: int, result_ch: string, yield_ch: string, token: int, priority: int, forced_slot: int):
    slots : ., mut = g_conc_slots
    if slots < 1:
        slots = 1
    if slots > 64:
        slots = 64
    span : ., mut = g_conc_m_count * slots
    if span < 1:
        span = 1
    slot : ., mut = forced_slot
    if slot < 0:
        rr : ., mut = 0
        if _conc_raw(g_conc_spawn_rr_buf) != 0:
            rr = rt_atomic_fetch_add(g_conc_spawn_rr_buf, 0, 1)
        slot = rr % span
    else:
        slot = slot % span
    home : ., mut = slot % g_conc_m_count
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
    cell_store(a, 136, token)
    cell_store(a, 144, priority)
    cell_store(a, 152, -1)   // ready-queue prev link (doubly linked)
    store_str_ptr(g_conc_acts, id * 8, a)

fn _conc_act_new(entry: int, arg: int, result_ch: string, yield_ch: string, token: int, priority: int, forced_slot: int) -> int:
    // New ids are issued atomically; the table lock only covers growth and the
    // control-block install. Free-list reuse never reaches here.
    id : ., mut = 0
    if _conc_raw(g_conc_act_id_buf) != 0:
        id = rt_atomic_fetch_add(g_conc_act_id_buf, 0, 1)
    else:
        id = g_conc_act_count
    _conc_table_lock()
    if id + 1 > g_conc_act_count:
        g_conc_act_count = id + 1
    _conc_acts_grow()
    a : ., mut = _conc_act_at(id)
    if _conc_raw(a) == 0:
        a = arena_shared_alloc(CONC_ACT_SIZE)
        if _conc_word(a) == 0:
            _conc_table_unlock()
            return -1
    _conc_act_init(id, a, entry, arg, result_ch, yield_ch, token, priority, forced_slot)
    _conc_table_unlock()
    return id

fn _conc_spawn_common(entry: int, arg: int, result_ch: string, yield_ch: string, token: int, priority: int, forced_slot: int) -> int:
    conc_sched_init()
    id : ., mut = _conc_free_pop()
    if id >= 0:
        a := _conc_act_at(id)
        if _conc_raw(a) != 0:
            _conc_act_init(id, a, entry, arg, result_ch, yield_ch, token, priority, forced_slot)
        else:
            id = -1
    if id < 0:
        id = _conc_act_new(entry, arg, result_ch, yield_ch, token, priority, forced_slot)
    if id >= 0:
        g_conc_spawn_count = g_conc_spawn_count + 1
        _conc_ready_push(id)
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
    return _conc_spawn_common(entry, arg, result_ch, "", -1, 0, -1)

fn conc_spawn_slot(entry: int, arg: int, result_ch: string, slot: int) -> int, pub:
    return _conc_spawn_common(entry, arg, result_ch, "", -1, 0, slot)

fn conc_spawn_priority(entry: int, arg: int, result_ch: string,
                      priority: int) -> int, pub:
    return _conc_spawn_common(entry, arg, result_ch, "", -1, priority, -1)

fn conc_spawn_flow(entry: int, arg: int, result_ch: string,
                   yield_ch: string) -> int, pub:
    return _conc_spawn_common(entry, arg, result_ch, yield_ch, -1, 0, -1)

fn conc_spawn_flow_token(entry: int, arg: int, result_ch: string,
                        yield_ch: string, token: int) -> int, pub:
    return _conc_spawn_common(entry, arg, result_ch, yield_ch, token, 0, -1)

fn conc_go_slot(entry: int, arg: int, slot: int) -> string, pub:
    conc_sched_init()
    out := _conc_global_channel(8, 1)
    if _conc_word(out) == 0:
        return ""
    if conc_spawn_slot(entry, arg, out, slot) < 0:
        return ""
    return out

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
    // M0 is the main/caller thread. With multiple Ms it must return after a
    // bounded amount of activation work, otherwise an endless cooperative
    // flow can monopolize M0 and starve the caller's own receive/join loop.
    limit : ., mut = 100000000
    if g_conc_m_count > 1 && _conc_m() == 0:
        limit = 1
    if _conc_cur_id() < 0:
        saved := arena_current_unchecked()
        loop:
            if ran >= limit:
                return ran
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
                    _conc_free_push(id)
                    continue
                stack := alloc(CONC_SCHED_STACK)
                arena_set_current_unchecked(saved)
                if _conc_word(stack) == 0:
                    arena_reset(aidp)
                    cell_store(a, 8, CONC_ACT_DEAD)
                    _conc_free_push(id)
                    continue
                sp := fiber_init(stack + CONC_SCHED_STACK - 8, @addr(_conc_activation_entry))
                cell_store(a, 16, sp)
                cell_store(a, 24, stack)
                cell_store(a, 64, aidp)
                cell_store(a, 96, aidp)
            ran = ran + 1
            _conc_set_cur(id)
            cell_store(a, 8, CONC_ACT_RUNNING)
            arena_set_current_unchecked(cell_load(a, 64))
            fiber_switch(_conc_ptr_addr(_conc_sched_sp_cell()), cell_load(a, 16))
            arena_set_current_unchecked(saved)
            // The activation is no longer in any ready queue. State, arena
            // reset, per-M current slot, and the free-list (own lock) are all
            // owned by this M, so the global scheduler lock is not needed here.
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
    g_conc_yield_count = g_conc_yield_count + 1
    _conc_ready_push(id)
    conc_schedule()
    return 1

fn conc_yield(), pub:
    _conc_yield_try(0)

// Write the observed wall time back into every WAIT budget of the plan. This
// is evidence, not a proof: status becomes MEASURED, and only the executor can
// produce it. Plans without WAIT rows are untouched.
fn _conc_plan_measure_wait(plan: int, t0: int):
    n := conc_plan_budget_count(plan)
    i : ., mut = 0
    loop:
        if i >= n:
            break
        if conc_plan_budget_kind(plan, i) == CONC_BUDGET_WAIT:
            conc_plan_budget_measure(plan, i, _conc_now_ms() - t0)
        i = i + 1

fn conc_plan_run(plan: int, root: int, channels: string) -> int, pub:
    if g_conc_plan_cancel != 0:
        return CONC_RESULT_CANCELLED
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
    wait_t0 := _conc_now_ms()
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
        if g_conc_plan_cancel != 0:
            return CONC_RESULT_CANCELLED
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
        if g_conc_plan_cancel != 0:
            return CONC_RESULT_CANCELLED
        oi = oi + 1
    // Receive the results of bodies that were not consumed by a JOIN.
    i = 0
    loop:
        if i >= n:
            break
        if cell_load(handles, i * 8) >= 0:
            if cell_load(recv_done, i * 8) == 0:
                total = total + conc_sched_recv_int(cell_load(handles, i * 8))
                if g_conc_plan_cancel != 0:
                    return CONC_RESULT_CANCELLED
        i = i + 1
    _conc_plan_measure_wait(plan, wait_t0)
    return total

fn conc_plan_run_all(plan: int, channels: string) -> int, pub:
    // Dataflow mode: spawn every body at once and let the channel operations
    // themselves provide SEND/RECV ordering. JOIN/SPAWN edges are not needed;
    // a body that consumes a channel simply blocks until the producer sends.
    if g_conc_plan_cancel != 0:
        return CONC_RESULT_CANCELLED
    if conc_plan_validate(plan) == 0:
        return -1
    if conc_plan_apply_layouts(plan) < 0:
        return -1
    if _conc_is_null(channels) != 0:
        return -1
    n := conc_plan_body_count(plan)
    if n <= 0:
        return -1
    wait_t0 := _conc_now_ms()
    hs := alloc(n * 8)
    i : ., mut = 0
    loop:
        if i >= n:
            break
        cell_store(hs, i * 8, -1)
        i = i + 1
    total : ., mut = 0
    b : ., mut = 0
    loop:
        if b >= n:
            break
        if g_conc_plan_cancel != 0:
            return CONC_RESULT_CANCELLED
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
            cell_store(hs, b * 8, h)
        b = b + 1
    i = 0
    loop:
        if i >= n:
            break
        if cell_load(hs, i * 8) >= 0:
            total = total + conc_sched_recv_int(cell_load(hs, i * 8))
            if g_conc_plan_cancel != 0:
                return CONC_RESULT_CANCELLED
        i = i + 1
    _conc_plan_measure_wait(plan, wait_t0)
    return total

fn conc_plan_run_mapped(mapping_id: int, channels: string) -> int, pub:
    // MappingPlan-aware executor: the slot kind chosen by the mapping is
    // translated into a logical slot id and passed to conc_go_slot.
    if conc_mapping_plan_applied(mapping_id) == 0:
        return -1
    plan := conc_mapping_plan_plan(mapping_id)
    if conc_plan_apply_layouts(plan) < 0:
        return -1
    if _conc_is_null(channels) != 0:
        return -1
    n := conc_plan_body_count(plan)
    if n <= 0:
        return -1
    slots : ., mut = g_conc_slots
    if slots < 1:
        slots = 1
    if slots > 64:
        slots = 64
    span : ., mut = g_conc_m_count * slots
    if span < 1:
        span = 1
    wait_t0 := _conc_now_ms()
    hs := alloc(n * 8)
    i : ., mut = 0
    loop:
        if i >= n:
            break
        cell_store(hs, i * 8, -1)
        i = i + 1
    total : ., mut = 0
    b : ., mut = 0
    loop:
        if b >= n:
            break
        if g_conc_plan_cancel != 0:
            return CONC_RESULT_CANCELLED
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
            chosen := conc_mapping_plan_choose_slot(mapping_id, b)
            if chosen < 0:
                return -1
            si : ., mut = 0
            if chosen == CONC_SLOT_FIBER && slots > 1:
                si = 1
            slot := (b + si * g_conc_m_count) % span
            h := conc_go_slot(entry, arg, slot)
            if _conc_word(h) == 0:
                return -1
            cell_store(hs, b * 8, h)
        b = b + 1
    i = 0
    loop:
        if i >= n:
            break
        if cell_load(hs, i * 8) >= 0:
            total = total + conc_sched_recv_int(cell_load(hs, i * 8))
            if g_conc_plan_cancel != 0:
                return CONC_RESULT_CANCELLED
        i = i + 1
    _conc_plan_measure_wait(plan, wait_t0)
    return total

fn conc_flow_cancelled() -> int, pub:
    return g_conc_flow_cancel

fn conc_flow_cancel() -> int, pub:
    g_conc_flow_cancel = 1
    if _conc_word(g_conc_flow_ych) != 0:
        conc_sched_close(g_conc_flow_ych)
    if _conc_word(g_conc_flow_rch) != 0:
        conc_sched_close(g_conc_flow_rch)
    return 0

fn conc_flow_reset() -> int, pub:
    g_conc_flow_cancel = 0
    g_conc_flow_ych = ""
    g_conc_flow_rch = ""
    return 0

fn conc_pipeline_cancelled() -> int, pub:
    return g_conc_pipeline_cancel

fn conc_pipeline_cancel(plan: int, channels: string) -> int, pub:
    g_conc_pipeline_cancel = 1
    if conc_plan_validate(plan) != 0 && _conc_is_null(channels) == 0:
        n := conc_plan_channel_count(plan)
        i : ., mut = 0
        loop:
            if i >= n:
                break
            h := load_str_ptr(channels, i * 8)
            if _conc_word(h) != 0:
                conc_sched_close(h)
            i = i + 1
    return 0

fn conc_pipeline_reset() -> int, pub:
    g_conc_pipeline_cancel = 0
    return 0

fn conc_shutdown_requested() -> int, pub:
    return g_conc_shutdown

fn conc_activation_count() -> int, pub:
    return g_conc_act_count

fn conc_waiting_count() -> int, pub:
    n : ., mut = 0
    i : ., mut = 0
    loop:
        if i >= g_conc_act_count:
            break
        a := _conc_act_at(i)
        if _conc_word(a) != 0:
            if cell_load(a, 8) == CONC_ACT_WAITING:
                n = n + 1
        i = i + 1
    return n

fn conc_deadlock_suspect() -> int, pub:
    // Conservative diagnostic: waiting activations, no ready work on any M,
    // and no activation currently running. External events can still make
    // this a false positive, so it is a suspect flag, not a proof.
    if g_conc_inited == 0:
        return 0
    if conc_waiting_count() == 0:
        return 0
    mc : ., mut = g_conc_m_count
    if mc > 64:
        mc = 64
    ready : ., mut = 0
    m : ., mut = 0
    loop:
        if m >= mc:
            break
        ready = ready + conc_ready_len(m)
        if cell_load(g_conc_cur_m, m * 8) >= 0:
            return 0
        m = m + 1
    if ready > 0:
        return 0
    return 1

fn conc_pipeline_run_token(plan: int, channels: string,
                           token: int) -> int, pub:
    if token < 0 || token >= 64 || _conc_raw(g_conc_cancel_used) == 0:
        return conc_pipeline_run(plan, channels)
    if conc_cancelled(token) != 0:
        return CONC_RESULT_CANCELLED
    if conc_plan_validate(plan) == 0:
        return -1
    if conc_plan_apply_layouts(plan) < 0:
        return -1
    if _conc_is_null(channels) != 0:
        return -1
    n := conc_plan_stage_count(plan)
    if n <= 0 || n > 64:
        return -1
    conc_cancel_bind_pipeline(token, channels, conc_plan_channel_count(plan))
    hs := alloc(64 * 8)
    i : ., mut = 0
    loop:
        if i >= n:
            break
        if conc_cancelled(token) != 0:
            return CONC_RESULT_CANCELLED
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
        if conc_cancelled(token) != 0:
            return CONC_RESULT_CANCELLED
        i = i + 1
    if conc_cancelled(token) != 0:
        return CONC_RESULT_CANCELLED
    return total

fn conc_pipeline_run_timeout(plan: int, channels: string,
                             timeout_ms: int) -> int, pub:
    // Same stage spawn/join as conc_pipeline_run, but the join polls result
    // channels with a monotonic deadline and cancels the pipeline on expiry.
    if timeout_ms <= 0:
        return CONC_RESULT_TIMEOUT
    if g_conc_pipeline_cancel != 0:
        return CONC_RESULT_CANCELLED
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
        if g_conc_pipeline_cancel != 0:
            return CONC_RESULT_CANCELLED
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
    done := alloc(n * 8)
    i = 0
    loop:
        if i >= n:
            break
        cell_store(done, i * 8, 0)
        i = i + 1
    deadline := _conc_now_ms() + timeout_ms
    total : ., mut = 0
    remaining : ., mut = n
    loop:
        if remaining <= 0:
            break
        i = 0
        loop:
            if i >= n:
                break
            if cell_load(done, i * 8) == 0:
                v : ., mut = conc_sched_try_recv_int(cell_load(hs, i * 8))
                if v != CONC_TRY_EMPTY:
                    if v == CONC_TRY_CLOSED:
                        v = 0
                    total = total + v
                    cell_store(done, i * 8, 1)
                    remaining = remaining - 1
            i = i + 1
        if remaining <= 0:
            break
        if g_conc_pipeline_cancel != 0:
            return CONC_RESULT_CANCELLED
        if _conc_now_ms() >= deadline:
            conc_pipeline_cancel(plan, channels)
            return CONC_RESULT_TIMEOUT
        if conc_schedule() == 0:
            _conc_sleep_ms(1)
    return total

fn conc_flow_run_timeout(entry: int, arg: int, out: string,
                         timeout_ms: int) -> int, pub:
    // Time-bounded flow driver. Yields are collected with try_recv; on expiry
    // the flow is cancelled cooperatively and the driver returns TIMEOUT.
    if timeout_ms <= 0:
        return CONC_RESULT_TIMEOUT
    conc_sched_init()
    ych := _conc_global_channel(8, 1)
    rch := _conc_global_channel(8, 1)
    if _conc_word(ych) == 0 || _conc_word(rch) == 0:
        return -1
    if g_conc_flow_cancel != 0:
        return CONC_RESULT_CANCELLED
    g_conc_flow_ych = ych
    g_conc_flow_rch = rch
    id := conc_spawn_flow(entry, arg, rch, ych)
    if id < 0:
        return -1
    deadline := _conc_now_ms() + timeout_ms
    n : ., mut = 0
    closed : ., mut = 0
    loop:
        if closed != 0:
            break
        v := conc_sched_try_recv_int(ych)
        if v == CONC_TRY_CLOSED:
            closed = 1
        else:
            if v != CONC_TRY_EMPTY:
                cell_store(out, n * 8, v)
                n = n + 1
        if g_conc_flow_cancel != 0:
            return CONC_RESULT_CANCELLED
        if _conc_now_ms() >= deadline:
            conc_flow_cancel()
            return CONC_RESULT_TIMEOUT
        if conc_schedule() == 0:
            _conc_sleep_ms(1)
    loop:
        v := conc_sched_try_recv_int(rch)
        if v != CONC_TRY_EMPTY:
            if g_conc_flow_cancel != 0:
                return CONC_RESULT_CANCELLED
            return n
        if g_conc_flow_cancel != 0:
            return CONC_RESULT_CANCELLED
        if _conc_now_ms() >= deadline:
            conc_flow_cancel()
            return CONC_RESULT_TIMEOUT
        if conc_schedule() == 0:
            _conc_sleep_ms(1)
    return n

fn conc_plan_cancelled() -> int, pub:
    return g_conc_plan_cancel

fn conc_plan_cancel(plan: int, channels: string) -> int, pub:
    g_conc_plan_cancel = 1
    if conc_plan_validate(plan) != 0 && _conc_is_null(channels) == 0:
        n := conc_plan_channel_count(plan)
        i : ., mut = 0
        loop:
            if i >= n:
                break
            h := load_str_ptr(channels, i * 8)
            if _conc_word(h) != 0:
                conc_sched_close(h)
            i = i + 1
    return 0

fn conc_plan_reset() -> int, pub:
    g_conc_plan_cancel = 0
    return 0

fn _conc_plan_timeout_entry(ctx: string) -> int:
    plan := cell_load(ctx, 0)
    root := cell_load(ctx, 8)
    chs := load_str_ptr(ctx, 16)
    rch := load_str_ptr(ctx, 24)
    rc := conc_plan_run(plan, root, chs)
    if _conc_word(rch) != 0:
        conc_sched_send_int(rch, rc)
    return 0

fn conc_plan_run_timeout(plan: int, root: int, channels: string,
                         timeout_ms: int) -> int, pub:
    if timeout_ms <= 0:
        return CONC_RESULT_TIMEOUT
    if g_conc_plan_cancel != 0:
        return CONC_RESULT_CANCELLED
    if conc_plan_validate(plan) == 0:
        return -1
    if root < 0 || root >= conc_plan_body_count(plan):
        return -1
    if _conc_is_null(channels) != 0:
        return -1
    rch := _conc_global_channel(8, 1)
    if _conc_word(rch) == 0:
        return -1
    ctx := alloc(32)
    cell_store(ctx, 0, plan)
    cell_store(ctx, 8, root)
    store_str_ptr(ctx, 16, channels)
    store_str_ptr(ctx, 24, rch)
    arg : ., mut = 0
    unsafe:
        arg = @ptr_of(ctx)
    h := conc_spawn(@addr(_conc_plan_timeout_entry), arg, "")
    if h < 0:
        return -1
    deadline := _conc_now_ms() + timeout_ms
    loop:
        v := conc_sched_try_recv_int(rch)
        if v != CONC_TRY_EMPTY:
            if v == CONC_TRY_CLOSED:
                return -1
            return v
        if g_conc_plan_cancel != 0:
            return CONC_RESULT_CANCELLED
        if _conc_now_ms() >= deadline:
            conc_plan_cancel(plan, channels)
            return CONC_RESULT_TIMEOUT
        if conc_schedule() == 0:
            _conc_sleep_ms(1)
    return CONC_RESULT_TIMEOUT

fn conc_plan_spawn(plan: int, body: int, channels: string) -> string, pub:
    if conc_plan_validate(plan) == 0:
        return ""
    if body < 0 || body >= conc_plan_body_count(plan):
        return ""
    kind := conc_plan_body_kind(plan, body)
    if kind != CONC_BODY_TASK && kind != CONC_BODY_PIPELINE:
        return ""
    entry := conc_plan_body_entry(plan, body)
    if entry <= 0:
        return ""
    arg : ., mut = 0
    ch := conc_plan_param_channel(plan, body, 0)
    if ch >= 0:
        if _conc_is_null(channels) != 0:
            return ""
        handle := load_str_ptr(channels, ch * 8)
        if _conc_is_null(handle) != 0:
            return ""
        unsafe:
            arg = @ptr_of(handle)
    return conc_go(entry, arg)

fn conc_plan_join(handle: string) -> int, pub:
    if _conc_word(handle) == 0:
        return -1
    return conc_sched_recv_int(handle)

fn conc_deadlock_break() -> int, pub:
    // Cooperative recovery: if the conservative detector sees waiting work with
    // no ready activation, close every registered channel and wake its
    // send/receive waiters. The waiting bodies return through the normal close
    // path; the process keeps running (unlike conc_shutdown).
    if conc_deadlock_suspect() == 0:
        return 0
    _conc_ch_lock()
    i : ., mut = 0
    loop:
        if i >= g_conc_ch_count:
            break
        _conc_ch_set_closed(i)
        _conc_wake_all(i, CONC_WAIT_SEND)
        _conc_wake_all(i, CONC_WAIT_RECV)
        i = i + 1
    _conc_ch_unlock()
    return 1

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
    if g_conc_pipeline_cancel != 0:
        return CONC_RESULT_CANCELLED
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
        if g_conc_pipeline_cancel != 0:
            return CONC_RESULT_CANCELLED
        i = i + 1
    if g_conc_pipeline_cancel != 0:
        return CONC_RESULT_CANCELLED
    return total

fn conc_cancel_new() -> int, pub:
    if _conc_raw(g_conc_cancel_used) == 0:
        return -1
    i : ., mut = 0
    loop:
        if i >= 64:
            return -1
        if cell_load(g_conc_cancel_used, i * 8) == 0:
            cell_store(g_conc_cancel_used, i * 8, 1)
            cell_store(g_conc_cancel_flags, i * 8, 0)
            cell_store(g_conc_cancel_a, i * 8, 0)
            cell_store(g_conc_cancel_b, i * 8, 0)
            cell_store(g_conc_cancel_n, i * 8, 0)
            cell_store(g_conc_cancel_mode, i * 8, 0)
            return i
        i = i + 1
    return -1

fn conc_cancel_free(token: int) -> int, pub:
    if token < 0 || token >= 64:
        return -1
    if _conc_raw(g_conc_cancel_used) == 0:
        return -1
    cell_store(g_conc_cancel_used, token * 8, 0)
    cell_store(g_conc_cancel_flags, token * 8, 0)
    return 0

fn conc_cancel_bind_flow(token: int, ych: string, rch: string) -> int, pub:
    if token < 0 || token >= 64 || _conc_raw(g_conc_cancel_used) == 0:
        return -1
    cell_store(g_conc_cancel_mode, token * 8, 1)
    store_str_ptr(g_conc_cancel_a, token * 8, ych)
    store_str_ptr(g_conc_cancel_b, token * 8, rch)
    return 0

fn conc_cancel_bind_pipeline(token: int, channels: string, count: int) -> int, pub:
    if token < 0 || token >= 64 || _conc_raw(g_conc_cancel_used) == 0:
        return -1
    cell_store(g_conc_cancel_mode, token * 8, 2)
    store_str_ptr(g_conc_cancel_a, token * 8, channels)
    cell_store(g_conc_cancel_n, token * 8, count)
    return 0

fn conc_cancelled(token: int) -> int, pub:
    if token < 0 || token >= 64 || _conc_raw(g_conc_cancel_used) == 0:
        return 0
    return cell_load(g_conc_cancel_flags, token * 8)

fn conc_cancel_token(token: int) -> int, pub:
    if token < 0 || token >= 64 || _conc_raw(g_conc_cancel_used) == 0:
        return -1
    cell_store(g_conc_cancel_flags, token * 8, 1)
    mode := cell_load(g_conc_cancel_mode, token * 8)
    if mode == 1:
        a := load_str_ptr(g_conc_cancel_a, token * 8)
        b := load_str_ptr(g_conc_cancel_b, token * 8)
        if _conc_word(a) != 0:
            conc_sched_close(a)
        if _conc_word(b) != 0:
            conc_sched_close(b)
    else:
        if mode == 2:
            chs := load_str_ptr(g_conc_cancel_a, token * 8)
            n := cell_load(g_conc_cancel_n, token * 8)
            i : ., mut = 0
            loop:
                if i >= n:
                    break
                h := load_str_ptr(chs, i * 8)
                if _conc_word(h) != 0:
                    conc_sched_close(h)
                i = i + 1
    return 0

fn conc_flow_yield(v: int), pub:
    id := _conc_cur_id()
    if id < 0:
        return
    a := _conc_act_at(id)
    if _conc_word(a) == 0:
        return
    ych := load_str_ptr(a, 112)
    tok := cell_load(a, 136)
    if tok >= 0:
        if conc_cancelled(tok) != 0:
            if _conc_word(ych) != 0:
                conc_sched_close(ych)
            _conc_abort_current()
            return
    if tok < 0 && g_conc_flow_cancel != 0:
        if _conc_word(ych) != 0:
            conc_sched_close(ych)
        _conc_abort_current()
        return
    if _conc_word(ych) != 0:
        conc_sched_send_int(ych, v)
    conc_yield()

fn conc_sched_is_closed(ch: string) -> int, pub:
    conc_sched_init()
    if conc_channel_len(ch) < 0:
        return 1
    _conc_ch_lock()
    slot := _conc_ch_slot_locked(ch)
    out := _conc_ch_closed(slot)
    _conc_ch_unlock()
    return out

fn conc_flow_run(entry: int, arg: int, out: string) -> int, pub:
    // Drive a coroutine flow to completion, collecting each yielded int in
    // `out`. The flow fiber preserves arbitrary control flow and locals across
    // yields; no compiler stage splitting is required.
    conc_sched_init()
    ych := _conc_global_channel(8, 1)
    rch := _conc_global_channel(8, 1)
    if _conc_word(ych) == 0 || _conc_word(rch) == 0:
        return -1
    if g_conc_flow_cancel != 0:
        return CONC_RESULT_CANCELLED
    g_conc_flow_ych = ych
    g_conc_flow_rch = rch
    id := conc_spawn_flow(entry, arg, rch, ych)
    if id < 0:
        return -1
    n : ., mut = 0
    loop:
        v := conc_sched_recv_int(ych)
        if g_conc_flow_cancel != 0:
            conc_sched_close(ych)
            conc_sched_close(rch)
            return CONC_RESULT_CANCELLED
        if conc_sched_is_closed(ych) != 0:
            break
        cell_store(out, n * 8, v)
        n = n + 1
    rv := conc_sched_recv_int(rch)
    if g_conc_flow_cancel != 0:
        return CONC_RESULT_CANCELLED
    return n

fn conc_flow_run_token(entry: int, arg: int, out: string,
                       token: int) -> int, pub:
    if token < 0 || token >= 64 || _conc_raw(g_conc_cancel_used) == 0:
        return conc_flow_run(entry, arg, out)
    if conc_cancelled(token) != 0:
        return CONC_RESULT_CANCELLED
    conc_sched_init()
    ych := _conc_global_channel(8, 1)
    rch := _conc_global_channel(8, 1)
    if _conc_word(ych) == 0 || _conc_word(rch) == 0:
        return -1
    conc_cancel_bind_flow(token, ych, rch)
    id := conc_spawn_flow_token(entry, arg, rch, ych, token)
    if id < 0:
        return -1
    n : ., mut = 0
    loop:
        v := conc_sched_recv_int(ych)
        if conc_cancelled(token) != 0:
            conc_sched_close(ych)
            conc_sched_close(rch)
            return CONC_RESULT_CANCELLED
        if conc_sched_is_closed(ych) != 0:
            break
        cell_store(out, n * 8, v)
        n = n + 1
    rv := conc_sched_recv_int(rch)
    if conc_cancelled(token) != 0:
        return CONC_RESULT_CANCELLED
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
            g_conc_preempt_tick_count = g_conc_preempt_tick_count + 1
            _conc_preempt_latency_record()
        return
    m := _conc_m()
    q := cell_load(g_conc_quantum_m, m * 8) - 1
    if q <= 0:
        cell_store(g_conc_quantum_m, m * 8, cell_load(g_conc_quantum_cfg_m, m * 8))
        if _conc_yield_try(0) != 0:
            g_conc_preempt_tick_count = g_conc_preempt_tick_count + 1
            _conc_preempt_latency_record()
    else:
        cell_store(g_conc_quantum_m, m * 8, q)

fn conc_worker_run(m_idx: int), pub:
    // The clone trampoline already installs the per-worker TLS block; set the
    // index again so this loop is correct even on a runtime that starts a
    // worker through a different path.
    rt_set_m_idx(m_idx)
    if _conc_raw(g_conc_tid_m) != 0:
        cell_store(g_conc_tid_m, m_idx * 8, syscall3(186, 0, 0, 0))
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

fn _conc_abort_current():
    // Terminate the current activation at a safe point. Used by cooperative
    // cancellation at a flow yield. The fiber is never resumed; the scheduler
    // resets its arena and returns the control block to the free list.
    id := _conc_cur_id()
    if id < 0:
        return
    a := _conc_act_at(id)
    if _conc_word(a) == 0:
        return
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
    _conc_abort_current()
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

fn _conc_ch_slot_locked(ch: string) -> int:
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

fn _conc_ch_slot(ch: string) -> int:
    conc_sched_init()
    _conc_ch_lock()
    slot := _conc_ch_slot_locked(ch)
    _conc_ch_unlock()
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

fn _conc_global_region_get_locked() -> int:
    if g_conc_global_region >= 0:
        return g_conc_global_region
    r := conc_region_new(1048576)
    if r >= 0:
        g_conc_global_region = r
    return r

fn _conc_global_region_get() -> int:
    _conc_region_lock()
    r := _conc_global_region_get_locked()
    _conc_region_unlock()
    return r

fn _conc_global_channel(elemsize: int, cap: int) -> string:
    _conc_region_lock()
    out : ., mut = ""
    r : ., mut = _conc_global_region_get_locked()
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
        out = ch
    _conc_region_unlock()
    return out

fn conc_chan_make(elemsize: int, cap: int) -> string, pub:
    conc_sched_init()
    if elemsize <= 0:
        return ""
    if cap < 0:
        return ""
    if cap > 1099511627776 / elemsize:
        return ""
    return _conc_global_channel(elemsize, cap)

fn conc_sched_send_int(ch: string, val: int) -> int, pub:
    if _conc_raw(g_conc_metric_send) != 0:
        rt_atomic_fetch_add(g_conc_metric_send, 0, 1)
    conc_sched_init()
    loop:
        _conc_ch_lock()
        if conc_channel_len(ch) < 0:
            _conc_ch_unlock()
            return -1
        esize := _conc_ch_esize(ch)
        if esize < 8:
            _conc_ch_unlock()
            return -1
        slot := _conc_ch_slot_locked(ch)
        if _conc_ch_closed(slot) != 0:
            _conc_ch_unlock()
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
                    _conc_ch_unlock()
                    _conc_wake_main_seq()
                    return 0
                _conc_ch_unlock()
                continue
            if _conc_cur_id() < 0:
                _conc_ch_unlock()
                if conc_schedule() == 0:
                    if g_conc_m_count <= 1:
                        return 0
                    conc_park(_conc_m())
                continue
            ca := _conc_act_at(_conc_cur_id())
            cell_store(ca, 72, val)
            _conc_wait_push(slot, CONC_WAIT_SEND, _conc_cur_id())
            cell_store(ca, 8, CONC_ACT_WAITING)
            _conc_ch_unlock()
            t0 := _conc_now_ms()
            conc_schedule()
            _conc_wait_record(t0)
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
            _conc_ch_unlock()
            _conc_wake_main_seq()
            return 0
        if _conc_cur_id() < 0:
            _conc_ch_unlock()
            if conc_schedule() == 0:
                if g_conc_m_count <= 1:
                    return 0
                conc_park(_conc_m())
            continue
        _conc_wait_push(slot, CONC_WAIT_SEND, _conc_cur_id())
        a := _conc_act_at(_conc_cur_id())
        cell_store(a, 8, CONC_ACT_WAITING)
        _conc_ch_unlock()
        t0 := _conc_now_ms()
        conc_schedule()
        _conc_wait_record(t0)

fn conc_sched_recv_int(ch: string) -> int, pub:
    if _conc_raw(g_conc_metric_recv) != 0:
        rt_atomic_fetch_add(g_conc_metric_recv, 0, 1)
    conc_sched_init()
    loop:
        _conc_ch_lock()
        if conc_channel_len(ch) < 0:
            _conc_ch_unlock()
            return 0
        esize := _conc_ch_esize(ch)
        if esize < 8:
            _conc_ch_unlock()
            return 0
        slot := _conc_ch_slot_locked(ch)
        n := _conc_ch_len(ch)
        cap := _conc_ch_cap(ch)
        if cap == 0:
            if _conc_ch_closed(slot) != 0:
                _conc_ch_unlock()
                return 0
            sid := _conc_wait_pop(slot, CONC_WAIT_SEND)
            if sid >= 0:
                sa := _conc_act_at(sid)
                v : ., mut = 0
                if _conc_word(sa) != 0:
                    v = cell_load(sa, 72)
                    cell_store(sa, 8, CONC_ACT_RUNNABLE)
                    _conc_ready_push(sid)
                _conc_ch_unlock()
                return v
            if _conc_cur_id() < 0:
                _conc_ch_unlock()
                if conc_schedule() == 0:
                    if g_conc_m_count <= 1:
                        return 0
                    conc_park(_conc_m())
                continue
            ra := _conc_act_at(_conc_cur_id())
            _conc_wait_push(slot, CONC_WAIT_RECV, _conc_cur_id())
            cell_store(ra, 8, CONC_ACT_WAITING)
            _conc_ch_unlock()
            t0 := _conc_now_ms()
            conc_schedule()
            _conc_wait_record(t0)
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
            _conc_ch_unlock()
            return v
        if _conc_ch_closed(slot) != 0:
            _conc_ch_unlock()
            return 0
        if _conc_cur_id() < 0:
            _conc_ch_unlock()
            if conc_schedule() == 0:
                if g_conc_m_count <= 1:
                    return 0
                conc_park(_conc_m())
            continue
        _conc_wait_push(slot, CONC_WAIT_RECV, _conc_cur_id())
        a := _conc_act_at(_conc_cur_id())
        cell_store(a, 8, CONC_ACT_WAITING)
        _conc_ch_unlock()
        t0 := _conc_now_ms()
        conc_schedule()
        _conc_wait_record(t0)

fn conc_sched_try_recv_int(ch: string) -> int, pub:
    // Non-blocking receive used by timeout executors. The sentinel values are
    // not valid channel payloads in the timeout API contract.
    conc_sched_init()
    _conc_ch_lock()
    if conc_channel_len(ch) < 0:
        _conc_ch_unlock()
        return CONC_TRY_CLOSED
    esize := _conc_ch_esize(ch)
    if esize < 8:
        _conc_ch_unlock()
        return CONC_TRY_CLOSED
    slot := _conc_ch_slot_locked(ch)
    n := _conc_ch_len(ch)
    cap := _conc_ch_cap(ch)
    if cap == 0:
        if _conc_ch_closed(slot) != 0:
            _conc_ch_unlock()
            return CONC_TRY_CLOSED
        sid := _conc_wait_pop(slot, CONC_WAIT_SEND)
        if sid >= 0:
            sa := _conc_act_at(sid)
            v : ., mut = 0
            if _conc_word(sa) != 0:
                v = cell_load(sa, 72)
                cell_store(sa, 8, CONC_ACT_RUNNABLE)
                _conc_ready_push(sid)
            _conc_ch_unlock()
            return v
        _conc_ch_unlock()
        return CONC_TRY_EMPTY
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
        _conc_ch_unlock()
        return v
    if _conc_ch_closed(slot) != 0:
        _conc_ch_unlock()
        return CONC_TRY_CLOSED
    _conc_ch_unlock()
    return CONC_TRY_EMPTY

fn _conc_now_ms() -> int:
    // Per-M scratch timespec: this is called from every worker in park/wait
    // accounting, so allocating here both raced and polluted the bump heap.
    ts : ., mut = ""
    if _conc_raw(g_conc_now_ts_m) != 0:
        ts = _conc_ptr(_conc_addr(g_conc_now_ts_m) + _conc_m() * 16)
    else:
        ts = alloc(16)
    cell_store(ts, 0, 0)
    cell_store(ts, 8, 0)
    r := syscall3(228, 1, ts, 0)  // clock_gettime(CLOCK_MONOTONIC)
    if r < 0:
        return -1
    return cell_load(ts, 0) * 1000 + cell_load(ts, 8) / 1000000

fn _conc_wait_record(t0: int):
    if t0 < 0:
        return
    now := _conc_now_ms()
    if now < t0:
        return
    d := now - t0
    g_conc_wait_count = g_conc_wait_count + 1
    g_conc_wait_ms_total = g_conc_wait_ms_total + d
    if d > g_conc_wait_ms_max:
        g_conc_wait_ms_max = d

fn conc_now_ms() -> int, pub:
    return _conc_now_ms()

fn _conc_sleep_ms(ms: int):
    if ms <= 0:
        return
    ts := alloc(16)
    cell_store(ts, 0, ms / 1000)
    cell_store(ts, 8, (ms % 1000) * 1000000)
    r := syscall3(35, ts, 0, 0)  // nanosleep
    return

fn conc_sched_send_int_status(ch: string, val: int) -> int, pub:
    if conc_channel_len(ch) < 0:
        return CONC_CHAN_INVALID
    if conc_sched_is_closed(ch) != 0:
        return CONC_CHAN_CLOSED
    conc_sched_send_int(ch, val)
    return CONC_CHAN_OK

fn conc_sched_recv_int_status(ch: string, out: string) -> int, pub:
    if conc_channel_len(ch) < 0:
        return CONC_CHAN_INVALID
    if conc_sched_is_closed(ch) != 0:
        if conc_channel_len(ch) <= 0:
            return CONC_CHAN_CLOSED
    v := conc_sched_recv_int(ch)
    cell_store(out, 0, v)
    return CONC_CHAN_OK

fn conc_sched_close(ch: string), pub:
    g_conc_close_count = g_conc_close_count + 1
    conc_sched_init()
    _conc_ch_lock()
    if conc_channel_len(ch) < 0:
        _conc_ch_unlock()
        return
    slot := _conc_ch_slot_locked(ch)
    _conc_ch_set_closed(slot)
    _conc_wake_all(slot, CONC_WAIT_SEND)
    _conc_wake_all(slot, CONC_WAIT_RECV)
    _conc_ch_unlock()

fn conc_go(entry: int, arg: int) -> string, pub:
    conc_sched_init()
    out := _conc_global_channel(8, 1)
    if _conc_word(out) == 0:
        return ""
    if conc_spawn(entry, arg, out) < 0:
        return ""
    return out
