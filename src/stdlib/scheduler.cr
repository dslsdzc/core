// scheduler.cr — cooperative fiber scheduler for `go` spawns
//
// Each `go node` is a Fiber with its own Arena. The scheduler round-robins
// through runnable fibers. Fibers yield cooperatively — no preemption.

import arena

// ── Legacy: dispatch table for .so extensions ──

fn sched_create(n: int) -> string, pub:
    return alloc(n * 8)

fn sched_set(entries: string, idx: int, val: int), pub:
    p := idx * 8
    v : ., mut = val
    i : ., mut = 0
    loop:
        if i >= 8:
            break
        store8(entries, p + i, v % 256)
        v = v / 256
        i = i + 1

fn sched_get(entries: string, idx: int) -> int, pub:
    p := idx * 8
    r : ., mut = 0
    i : ., mut = 7
    loop:
        if i < 0:
            break
        b := load8(entries, p + i)
        if b < 0:
            b = b + 256
        r = r * 256 + b
        i = i - 1
    return r

// ── Fiber states ──
FIBER_FREE : int = 0
FIBER_RUNNABLE : int = 1
FIBER_WAITING : int = 2
FIBER_DONE : int = 3

// ── Fiber table (32 bytes each: fn_idx:8, arena:8, state:8, data:8) ──
g_fibers : string, mut
g_fiber_count : int, mut
g_fiber_cap : int, mut

// ── Run queue (ring buffer of fiber indices) ──
g_runq : string, mut
g_runq_head : int, mut
g_runq_tail : int, mut
g_runq_count : int, mut
g_runq_cap : int, mut

// ── Current executing fiber ──
g_cur_fiber : int, mut

fn fiber_init(), pub:
    g_fiber_cap = 64
    g_fibers = alloc(g_fiber_cap * 32)
    g_fiber_count = 0
    g_runq_cap = 64
    g_runq = alloc(g_runq_cap * 8)
    g_runq_head = 0
    g_runq_tail = 0
    g_runq_count = 0
    g_cur_fiber = -1

fn runq_push(fi: int), pub:
    if g_runq_count >= g_runq_cap:
        nc := g_runq_cap * 2
        nb := alloc(nc * 8)
        ci : ., mut = 0
        pos := g_runq_head
        loop:
            if ci >= g_runq_count:
                break
            cell_store(nb, ci * 8, cell_load(g_runq, pos * 8))
            pos = (pos + 1) % g_runq_cap
            ci = ci + 1
        g_runq = nb
        g_runq_head = 0
        g_runq_tail = g_runq_count
        g_runq_cap = nc
    cell_store(g_runq, g_runq_tail * 8, fi)
    g_runq_tail = (g_runq_tail + 1) % g_runq_cap
    g_runq_count = g_runq_count + 1

fn runq_pop() -> int, pub:
    if g_runq_count <= 0:
        return -1
    fi := cell_load(g_runq, g_runq_head * 8)
    g_runq_head = (g_runq_head + 1) % g_runq_cap
    g_runq_count = g_runq_count - 1
    return fi

fn fiber_spawn(fn_idx: int) -> int, pub:
    i : ., mut = 0
    loop:
        if i >= g_fiber_count:
            break
        if cell_load(g_fibers, i * 32 + 16) == FIBER_FREE:
            cell_store(g_fibers, i * 32, fn_idx)
            cell_store(g_fibers, i * 32 + 8, arena.arena_new())
            cell_store(g_fibers, i * 32 + 16, FIBER_RUNNABLE)
            runq_push(i)
            return i
        i = i + 1
    if g_fiber_count >= g_fiber_cap:
        nc := g_fiber_cap * 2
        nb := alloc(nc * 32)
        _dyncpy(g_fibers, g_fiber_cap * 32, nb)
        g_fiber_cap = nc
        g_fibers = nb
    fi := g_fiber_count
    g_fiber_count = g_fiber_count + 1
    off := fi * 32
    cell_store(g_fibers, off, fn_idx)
    cell_store(g_fibers, off + 8, arena.arena_new())
    cell_store(g_fibers, off + 16, FIBER_RUNNABLE)
    cell_store(g_fibers, off + 24, 0)
    runq_push(fi)
    return fi

fn fiber_yield(), pub:
    if g_cur_fiber < 0:
        return
    off := g_cur_fiber * 32
    if cell_load(g_fibers, off + 16) == FIBER_RUNNABLE:
        runq_push(g_cur_fiber)

fn fiber_wait(target: int), pub:
    if g_cur_fiber < 0:
        return
    off := g_cur_fiber * 32
    cell_store(g_fibers, off + 16, FIBER_WAITING)
    cell_store(g_fibers, off + 24, target)

fn fiber_wake(fi: int), pub:
    if fi < 0:
        return
    off := fi * 32
    if cell_load(g_fibers, off + 16) == FIBER_WAITING:
        cell_store(g_fibers, off + 16, FIBER_RUNNABLE)
        cell_store(g_fibers, off + 24, 0)
        runq_push(fi)

fn fiber_done(fi: int), pub:
    if fi < 0 || fi >= g_fiber_count:
        return
    off := fi * 32
    ai := cell_load(g_fibers, off + 8)
    if ai >= 0:
        arena.arena_reset(ai)
    cell_store(g_fibers, off + 16, FIBER_DONE)

fn sched_run(), pub:
    loop:
        fi := runq_pop()
        if fi < 0:
            break
        g_cur_fiber = fi
        off := fi * 32
        if cell_load(g_fibers, off + 16) != FIBER_RUNNABLE:
            continue
        // Placeholder: fibers complete immediately in interpreter mode.
        // Native backend (corearch) will call the actual function pointer
        // stored at g_fibers[fi].fn_idx via the dispatch table.
        fiber_done(fi)
    g_cur_fiber = -1
