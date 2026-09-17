// M:N scheduler — M OS threads, N goroutines
// Channels are single-producer/single-consumer edges, so the runtime needs
// no locks: each M owns its run queue and only its own thread touches it.
import goroutine
import chan
import arena

// M struct layout (32 bytes): id(0), cur_g(8), runq_head(16), runq_tail(24)
g_machines : string, mut;    // M array
g_machine_count : int, mut;

// Index of the M running the current thread. Each worker sets it on entry
// (sched_worker_run); the scheduler uses it to enqueue/dequeue on the
// current M's LOCAL queue instead of contending on a shared global one.
g_current_m_idx : int, mut = 0;

g_num_workers : int, mut = 0;        // number of worker threads
g_sched_inited : int, mut = 0;       // 0 = not initialized, 1 = initialized

fn sched_init() {
    if g_sched_inited != 0 { return; }

    // Initialize arena system (required by goroutine/chan)
    arena_init(1048576, 65536);  // 1MB pool, 64KB chunks

    // Initialize M workers (one per CPU)
    // For now: single-threaded (1 M, cooperative)
    m := alloc(32);
    w64(m, 0, 0);     // id = 0
    w64(m, 8, -1);     // cur_g = none
    w64(m, 16, -1);    // runq_head = empty
    w64(m, 24, -1);    // runq_tail = empty
    g_machines = m;
    g_machine_count = 1;
    g_current_m_idx = 0;

    // Register the main thread as G 0 so it can block/wake via channels.
    // Its stack_ptr is filled in by fiber_switch the first time it yields
    // (fiber_switch saves the current RSP into [G+16]).
    main_g := alloc(80);
    w64(main_g, 0, 0);     // id = 0
    w64(main_g, 8, 1);     // _Grunning
    w64(main_g, 16, 0);    // stack_ptr (filled on first yield)
    w64(main_g, 24, 0);    // stack_lo (thread stack — no arena)
    w64(main_g, 32, -1);   // arena_id = none
    w64(main_g, 40, -1);   // result_ch = none (never dispatched by a wrapper)
    w64(main_g, 48, -1);   // next = -1
    w64(main_g, 56, 0);    // saved_fn = 0 (never dispatched by a wrapper)
    w64(main_g, 64, 0);    // saved_arg = 0
    w64(main_g, 72, 0);    // temp_val = 0
    w64(m, 8, main_g);     // M[0].cur_g = main_g
    g_set_curg(main_g);
    g_sched_inited = 1;
}

// sched_current_m_idx: index of the M currently executing (set by
// sched_worker_run / sched_init). The asm goroutine wrapper calls
// sched_schedule without an argument, so the scheduler always resolves the
// current M through this.
fn sched_current_m_idx() -> int {
    return g_current_m_idx;
}

fn sched_enqueue(g: string) {
    // Add to the CURRENT M's local queue (no shared global queue → no
    // cross-thread contention; each M only touches its own list).
    m_idx := sched_current_m_idx();
    if m_idx < 0 { m_idx = 0; }
    m := g_machines + m_idx * 32;
    head := r64(m, 16);
    if head < 0 {
        w64(m, 16, g);      // runq_head = g
        w64(m, 24, g);      // runq_tail = g
    } else {
        tail := r64(m, 24);
        w64(tail, 48, g);   // tail.next = g
        w64(m, 24, g);      // runq_tail = g
    }
    w64(g, 48, -1);
}

fn sched_dequeue(m_idx: int) -> int {
    if m_idx < 0 { m_idx = 0; }
    m := g_machines + m_idx * 32;
    head := r64(m, 16);
    if head < 0 { return -1; }
    w64(m, 16, r64(head, 48));
    if r64(m, 16) < 0 { w64(m, 24, -1); }
    w64(head, 48, -1);
    return head;
}

fn sched_get_curg() -> int {
    return g_get_curg();
}

fn sched_yield() {
    // Current goroutine yields
    cur_g := sched_get_curg();

    // Re-enqueue current G only if it is still runnable.
    // Blocked (_Gwaiting) Gs stay on their channel wait lists until a
    // sender/receiver handoff wakes them — re-enqueueing would double-schedule.
    // Dead (_Gdead) Gs must never be re-enqueued (goroutine exit path).
    if cur_g >= 0 {
        st := r64(cur_g, 8);
        if st != 2 && st != 3 {  // not _Gwaiting, not _Gdead
            w64(cur_g, 8, 0);  // _Grunnable
            sched_enqueue(cur_g);
        }
    }

    // Schedule next
    sched_schedule();
}

// sched_schedule: switch to the next runnable G from the current M's local
// queue. No m_idx parameter: the current M index is tracked in
// g_current_m_idx, and the assembly goroutine_entry_wrapper calls this
// directly (rdi is unspecified there) on the goroutine exit path.
fn sched_schedule() {
    m_idx := sched_current_m_idx();
    next_g := sched_dequeue(m_idx);
    if next_g >= 0 {
        old_g := r64(g_machines, m_idx * 32 + 8);
        w64(g_machines, m_idx * 32 + 8, next_g);
        g_set_curg(next_g);
        w64(next_g, 8, 1);  // _Grunning

        if old_g >= 0 {
            // Save old_g's sp, switch to next_g's sp
            old_sp_addr := old_g + 16;  // &g.stack_ptr
            next_sp := r64(next_g, 16);  // g.stack_ptr
            fiber_switch(old_sp_addr, next_sp);
        }
        // else: first goroutine, just start it
    }
}

// sched_worker_run: main loop for worker threads.
// Each worker dequeues and runs goroutines from ITS OWN M's local queue.
fn sched_worker_run(m_idx: int) {
    // Store this worker's index in its M struct
    w64(g_machines, m_idx * 32, m_idx);  // m.id = m_idx
    g_current_m_idx = m_idx;

    loop {
        next_g := sched_dequeue(m_idx);
        if next_g >= 0 {
            old_g := r64(g_machines, m_idx * 32 + 8);
            w64(g_machines, m_idx * 32 + 8, next_g);
            g_set_curg(next_g);
            w64(next_g, 8, 1);  // _Grunning

            if old_g >= 0 {
                old_sp_addr := old_g + 16;
                next_sp := r64(next_g, 16);
                fiber_switch(old_sp_addr, next_sp);
            }
            // else: first goroutine on this M, start it
        }
        // If no work, yield to OS
        // For now: spin-wait (will add proper blocking later)
        // yield(); // sched_yield_to_os() — future
    }
}

// sched_go: spawn a goroutine that calls fn_ptr(arg), return a channel for the result.
// fn_ptr is the function's address (resolved by the backend at link time).
// arg is the single argument passed to the spawned function.
fn sched_go(fn_ptr: int, arg: int) -> string {
    // Create a 1-element channel for collecting the result
    ch := chan_make(8, 1);

    // Create a new goroutine via g_new
    g := g_new(fn_ptr, arg, 0);

    // Store result channel in G struct (offset 40)
    w64(g, 40, ch);

    // Enqueue goroutine to the scheduler
    sched_enqueue(g);

    // Return the channel so the caller can await the result
    return ch;
}

// sched_spawn_workers: create n worker threads via m_start_workers (rt.s)
fn sched_spawn_workers(n: int) {
    if n <= 1 { return; }
    total_ms := alloc(n * 32);
    mi : ., mut = 0;
    loop {
        if mi >= n { break; }
        w64(total_ms, mi * 32, mi);          // m.id
        w64(total_ms, mi * 32 + 8, -1);      // m.cur_g = none
        w64(total_ms, mi * 32 + 16, -1);     // runq_head
        w64(total_ms, mi * 32 + 24, -1);     // runq_tail
        mi = mi + 1;
    }
    g_machines = total_ms;
    g_machine_count = n;
    g_num_workers = n - 1;
    m_start_workers(n);  // launch workers (assembly in rt.s)
}
