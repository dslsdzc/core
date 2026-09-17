// Channel: typed FIFO, goroutine-safe with wait queues
import sched

// Auto-initialization: any channel op triggers sched_init if needed.
g_chan_inited : int, mut = 0;

fn _chan_ensure_init() {
    if g_chan_inited == 0 {
        sched_init();
        g_chan_inited = 1;
    }
}

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

fn chan_make(elemsize: int, cap: int) -> string {
    _chan_ensure_init();
    ch := alloc(64);
    buf := alloc(cap * elemsize);
    w64(ch, 0, buf);        // buf
    w64(ch, 8, cap);         // cap
    w64(ch, 16, 0);          // len
    w64(ch, 24, 0);          // head
    w64(ch, 32, elemsize);   // elemsize
    w64(ch, 40, -1);         // send_wait = empty
    w64(ch, 48, -1);         // recv_wait = empty
    w64(ch, 56, 0);          // closed = false
    return ch;
}

fn chan_send(ch: string, val: int) {
    _chan_ensure_init();
    buf := r64(ch, 0);
    cap := r64(ch, 8);
    len := r64(ch, 16);
    head := r64(ch, 24);
    esize := r64(ch, 32);

    // Check for waiting receivers first (direct handoff)
    recv_wait := r64(ch, 48);
    if recv_wait >= 0 {
        // Direct handoff: copy value to the waiting receiver's temp_val
        nxt := r64(recv_wait, 48);          // save next before overwriting
        w64(recv_wait, 72, val);             // store value in receiver's temp_val
        w64(recv_wait, 8, 0);               // set to _Grunnable
        sched_enqueue(recv_wait);
        w64(ch, 48, nxt);                   // remove from recv_wait list
        return;
    }

    if len < cap {
        // Buffer has space
        tail := (head + len) % cap;
        w64(buf, tail * esize, val);
        w64(ch, 16, len + 1);
        return;
    }

    // Buffer full: block on send_wait list
    g := sched_get_curg();
    if g >= 0 {
        w64(g, 72, val);         // store value for later delivery (temp_val)
        w64(g, 8, 2);            // _Gwaiting
        w64(g, 48, -1);          // next = -1

        // Add to channel's send_wait list
        sw := r64(ch, 40);
        if sw < 0 {
            w64(ch, 40, g);
        } else {
            loop {
                nxt := r64(sw, 48);
                if nxt < 0 { w64(sw, 48, g); break; }
                sw = nxt;
            }
        }
    }

    // Yield — scheduler will wake us when receiver comes
    sched_yield();
}

fn chan_recv(ch: string) -> int {
    _chan_ensure_init();
    buf := r64(ch, 0);
    cap := r64(ch, 8);
    len := r64(ch, 16);
    head := r64(ch, 24);
    esize := r64(ch, 32);
    closed := r64(ch, 56);

    // Check for waiting senders first (direct handoff)
    send_wait := r64(ch, 40);
    if send_wait >= 0 {
        // Direct handoff: take value from the waiting sender's temp_val
        val := r64(send_wait, 72);           // read sender's stored value
        nxt := r64(send_wait, 48);
        w64(send_wait, 8, 0);               // set to _Grunnable
        sched_enqueue(send_wait);
        w64(ch, 40, nxt);                   // remove from send_wait list
        return val;
    }

    if len > 0 {
        // Buffer has data
        val := r64(buf, head * esize);
        w64(ch, 24, (head + 1) % cap);
        w64(ch, 16, len - 1);
        return val;
    }

    if closed != 0 { return 0; }

    // Buffer empty: block on recv_wait list
    g := sched_get_curg();
    if g >= 0 {
        w64(g, 8, 2);            // _Gwaiting
        w64(g, 48, -1);          // next = -1

        rw := r64(ch, 48);
        if rw < 0 {
            w64(ch, 48, g);
        } else {
            loop {
                nxt := r64(rw, 48);
                if nxt < 0 { w64(rw, 48, g); break; }
                rw = nxt;
            }
        }
    }

    sched_yield();

    // After wakeup, value should be in this G's temp_val (delivered by sender)
    val := r64(g, 72);
    return val;
}

fn chan_close(ch: string) {
    _chan_ensure_init();
    w64(ch, 56, 1);  // closed = true

    // Wake up all waiting senders
    sw := r64(ch, 40);
    loop {
        if sw < 0 { break; }
        nxt := r64(sw, 48);
        w64(sw, 8, 0);         // _Grunnable
        sched_enqueue(sw);
        sw = nxt;
    }
    w64(ch, 40, -1);  // clear send_wait

    // Wake up all waiting receivers
    rw := r64(ch, 48);
    loop {
        if rw < 0 { break; }
        nxt := r64(rw, 48);
        w64(rw, 8, 0);         // _Grunnable
        sched_enqueue(rw);
        rw = nxt;
    }
    w64(ch, 48, -1);  // clear recv_wait
}
