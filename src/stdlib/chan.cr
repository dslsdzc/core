// Channel surface backed by the CP-4 conc runtime.
//
// chan_make/send/recv/close keep the existing source-level signatures, but the
// storage and waiting protocol live in conc/conc_sched: a conc channel payload
// (magic, buf, cap, len, head, esize, owner region, epoch) plus per-channel
// cooperative wait queues. send/recv block the current activation when the
// channel is full/empty; close wakes all waiters.
import conc_sched

fn chan_make(elemsize: int, cap: int) -> string, pub:
    return conc_chan_make(elemsize, cap)

fn chan_send(ch: string, val: int), pub:
    conc_sched_send_int(ch, val)
    return

fn chan_recv(ch: string) -> int, pub:
    return conc_sched_recv_int(ch)

fn chan_close(ch: string), pub:
    conc_sched_close(ch)
    return
