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
import conc_sched
import sched

g_chan_inited : int, mut = 0

fn _chan_ensure_init():
    if g_chan_inited == 0:
        sched_init()
        g_chan_inited = 1

fn chan_make(elemsize: int, cap: int) -> string, pub:
    // CP-4 default path: the channel surface is backed by the conc runtime.
    return conc_chan_make(elemsize, cap)

fn chan_send(ch: string, val: int), pub:
    conc_sched_send_int(ch, val)
    return

fn chan_recv(ch: string) -> int, pub:
    return conc_sched_recv_int(ch)

fn chan_close(ch: string), pub:
    conc_sched_close(ch)
    return
