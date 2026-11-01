// Channel: SPSC lock-free ring.
//
// head is consumer-owned and only advanced by recv; tail is producer-owned and
// only advanced by send. The two wait slots hold at most one G each (SPSC
// contract). `xchg` claims a waiter, so close and the opposite side cannot wake
// the same G twice.
//
// Layout (64 bytes):
//   0 buf, 8 cap, 16 head, 24 tail, 32 esize,
//  40 send_wait, 48 recv_wait, 56 closed.
import sched

g_chan_inited : int, mut = 0

fn _chan_ensure_init():
    if g_chan_inited == 0:
        sched_init()
        g_chan_inited = 1

fn chan_make(elemsize: int, cap: int) -> string, pub:
    _chan_ensure_init()
    ch := alloc(64)
    buf := alloc(cap * elemsize)
    cell_store(ch, 0, buf)
    cell_store(ch, 8, cap)
    cell_store(ch, 16, 0)       // head
    cell_store(ch, 24, 0)       // tail
    cell_store(ch, 32, elemsize)
    cell_store(ch, 40, 0)       // send_wait = none
    cell_store(ch, 48, 0)       // recv_wait = none
    cell_store(ch, 56, 0)       // closed
    return ch

fn chan_send(ch: string, val: int), pub:
    _chan_ensure_init()
    loop:
        cap := cell_load(ch, 8)
        head : ., mut = rt_atomic_load(ch, 16)
        tail : ., mut = rt_atomic_load(ch, 24)
        if tail - head < cap:
            buf := cell_load(ch, 0)
            esize := cell_load(ch, 32)
            cell_store(buf, (tail % cap) * esize, val)
            rt_atomic_store(ch, 24, tail + 1)
            rw := rt_atomic_xchg(ch, 48, 0)
            if rw != 0:
                rt_atomic_store(rw, 8, 0)   // runnable
                sched_enqueue(rw)
            return

        if rt_atomic_load(ch, 56) != 0:
            return

        g := sched_get_curg()
        if g < 0:
            return
        rt_atomic_store(g, 8, 2)            // waiting
        rt_atomic_xchg(ch, 40, g)

        // Recheck after publishing the waiter. The xchg is the barrier.
        head = rt_atomic_load(ch, 16)
        tail = rt_atomic_load(ch, 24)
        if tail - head < cap:
            if rt_atomic_xchg(ch, 40, 0) == g:
                rt_atomic_store(g, 8, 1)
                continue
        if rt_atomic_load(ch, 56) != 0:
            if rt_atomic_xchg(ch, 40, 0) == g:
                rt_atomic_store(g, 8, 1)
                return

        // Blocking path: never sched_yield here. A waker may already have
        // pushed this G; sched_yield would enqueue it a second time.
        sched_schedule()

fn chan_recv(ch: string) -> int, pub:
    _chan_ensure_init()
    loop:
        cap := cell_load(ch, 8)
        head : ., mut = rt_atomic_load(ch, 16)
        tail : ., mut = rt_atomic_load(ch, 24)
        if head < tail:
            buf := cell_load(ch, 0)
            esize := cell_load(ch, 32)
            val := cell_load(buf, (head % cap) * esize)
            rt_atomic_store(ch, 16, head + 1)
            sw := rt_atomic_xchg(ch, 40, 0)
            if sw != 0:
                rt_atomic_store(sw, 8, 0)
                sched_enqueue(sw)
            return val

        if rt_atomic_load(ch, 56) != 0:
            return 0

        g := sched_get_curg()
        if g < 0:
            return 0
        rt_atomic_store(g, 8, 2)
        rt_atomic_xchg(ch, 48, g)

        head = rt_atomic_load(ch, 16)
        tail = rt_atomic_load(ch, 24)
        if head < tail:
            if rt_atomic_xchg(ch, 48, 0) == g:
                rt_atomic_store(g, 8, 1)
                continue
        if rt_atomic_load(ch, 56) != 0:
            if rt_atomic_xchg(ch, 48, 0) == g:
                rt_atomic_store(g, 8, 1)
                return 0

        sched_schedule()

fn chan_close(ch: string), pub:
    _chan_ensure_init()
    rt_atomic_store(ch, 56, 1)
    rw := rt_atomic_xchg(ch, 48, 0)
    if rw != 0:
        rt_atomic_store(rw, 8, 0)
        sched_enqueue(rw)
    sw := rt_atomic_xchg(ch, 40, 0)
    if sw != 0:
        rt_atomic_store(sw, 8, 0)
        sched_enqueue(sw)
