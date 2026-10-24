// Channel: typed FIFO, goroutine-safe with wait queues
import sched

// Auto-initialization: any channel op triggers sched_init if needed.
g_chan_inited : int, mut = 0

fn _chan_ensure_init():
    if g_chan_inited == 0:
        sched_init()
        g_chan_inited = 1

// Channel layout (64 bytes):
//   0: buf        — pointer to ring buffer
//   8: cap        — capacity
//  16: len        — current length
//  24: head       — head index
//  32: esize      — element size
//  40: send_wait  — linked list of goroutines blocked on send (-1 = empty)
//  48: recv_wait  — linked list of goroutines blocked on recv (-1 = empty)
//  56: closed     — 0 = open, 1 = closed
//
// Goroutine (G) struct fields used by wait queues:
//   8: status     — 0=Grunnable, 1=Grunning, 2=Gwaiting, 3=Gdead
//  40: result_ch  — result channel (set by sched_go; NOT used as chan_wait —
//      the wait lists live on the channel itself, so writing offset 40 here
//      would clobber result_ch and redirect the wrapper's chan_send)
//  48: next       — next waiter in linked list (-1 = end)
//  72: temp_val   — temporary value storage for handoff (offset 56 is
//      saved_fn — never write it from channel code)

fn chan_make(elemsize: int, cap: int) -> string:
    _chan_ensure_init()
    ch := alloc(64)
    buf := alloc(cap * elemsize)
    cell_store(ch, 0, buf)        // buf
    cell_store(ch, 8, cap)         // cap
    cell_store(ch, 16, 0)          // len
    cell_store(ch, 24, 0)          // head
    cell_store(ch, 32, elemsize)   // elemsize
    cell_store(ch, 40, -1)         // send_wait = empty
    cell_store(ch, 48, -1)         // recv_wait = empty
    cell_store(ch, 56, 0)          // closed = false
    return ch

fn chan_send(ch: string, val: int):
    _chan_ensure_init()
    buf := cell_load(ch, 0)
    cap := cell_load(ch, 8)
    len := cell_load(ch, 16)
    head := cell_load(ch, 24)
    esize := cell_load(ch, 32)

    // Check for waiting receivers first (direct handoff)
    recv_wait := cell_load(ch, 48)
    if recv_wait >= 0:
        // Direct handoff: copy value to the waiting receiver's temp_val
        nxt := cell_load(recv_wait, 48)          // save next before overwriting
        cell_store(recv_wait, 72, val)             // store value in receiver's temp_val
        cell_store(recv_wait, 8, 0)               // set to _Grunnable
        sched_enqueue(recv_wait)
        cell_store(ch, 48, nxt)                   // remove from recv_wait list
        return

    if len < cap:
        // Buffer has space
        tail := (head + len) % cap
        cell_store(buf, tail * esize, val)
        cell_store(ch, 16, len + 1)
        return

    // Buffer full: block on send_wait list
    g := sched_get_curg()
    if g >= 0:
        cell_store(g, 72, val)         // store value for later delivery (temp_val)
        cell_store(g, 8, 2)            // _Gwaiting
        cell_store(g, 48, -1)          // next = -1

        // Add to channel's send_wait list
        sw := cell_load(ch, 40)
        if sw < 0:
            cell_store(ch, 40, g)
        else:
            loop:
                nxt := cell_load(sw, 48)
                if nxt < 0:
                    cell_store(sw, 48, g)
                    break
                sw = nxt

    // Yield — scheduler will wake us when receiver comes
    sched_yield()

fn chan_recv(ch: string) -> int:
    _chan_ensure_init()
    buf := cell_load(ch, 0)
    cap := cell_load(ch, 8)
    len := cell_load(ch, 16)
    head := cell_load(ch, 24)
    esize := cell_load(ch, 32)
    closed := cell_load(ch, 56)

    // Check for waiting senders first (direct handoff)
    send_wait := cell_load(ch, 40)
    if send_wait >= 0:
        // Direct handoff: take value from the waiting sender's temp_val
        val := cell_load(send_wait, 72)           // read sender's stored value
        nxt := cell_load(send_wait, 48)
        cell_store(send_wait, 8, 0)               // set to _Grunnable
        sched_enqueue(send_wait)
        cell_store(ch, 40, nxt)                   // remove from send_wait list
        return val

    if len > 0:
        // Buffer has data
        val := cell_load(buf, head * esize)
        cell_store(ch, 24, (head + 1) % cap)
        cell_store(ch, 16, len - 1)
        return val

    if closed != 0:
        return 0

    // Buffer empty: block on recv_wait list
    g := sched_get_curg()
    if g >= 0:
        cell_store(g, 8, 2)            // _Gwaiting
        cell_store(g, 48, -1)          // next = -1

        rw := cell_load(ch, 48)
        if rw < 0:
            cell_store(ch, 48, g)
        else:
            loop:
                nxt := cell_load(rw, 48)
                if nxt < 0:
                    cell_store(rw, 48, g)
                    break
                rw = nxt

    sched_yield()

    // After wakeup, value should be in this G's temp_val (delivered by sender)
    val := cell_load(g, 72)
    return val

fn chan_close(ch: string):
    _chan_ensure_init()
    cell_store(ch, 56, 1)  // closed = true

    // Wake up all waiting senders
    sw := cell_load(ch, 40)
    loop:
        if sw < 0:
            break
        nxt := cell_load(sw, 48)
        cell_store(sw, 8, 0)         // _Grunnable
        sched_enqueue(sw)
        sw = nxt
    cell_store(ch, 40, -1)  // clear send_wait

    // Wake up all waiting receivers
    rw := cell_load(ch, 48)
    loop:
        if rw < 0:
            break
        nxt := cell_load(rw, 48)
        cell_store(rw, 8, 0)         // _Grunnable
        sched_enqueue(rw)
        rw = nxt
    cell_store(ch, 48, -1)  // clear recv_wait
