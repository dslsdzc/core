// chan.cr — buffered channel for fiber communication.
//
// send blocks when full, recv blocks when empty. Uses fiber_wait/wake
// from scheduler.cr to park/resume fibers.

// ── Import ──
import scheduler;

// Channel layout (per-slot, 56 bytes):
//   offset 0:  ring_ptr (8)  — ring buffer (separate allocation)
//   offset 8:  capacity (8)  — max items
//   offset 16: head (8)      — read position
//   offset 24: tail (8)      — write position
//   offset 32: count (8)     — current items
//   offset 40: send_wait (8) — fiber blocked on send (-1 = none)
//   offset 48: recv_wait (8) — fiber blocked on recv (-1 = none)

g_channels : string, mut;
g_chan_count : int, mut;
g_chan_cap : int, mut;

fn chan_init() {
    g_chan_cap = 32;
    g_channels = alloc(g_chan_cap * 56);
    g_chan_count = 0;
}

fn chan_new(capacity: int) -> int {
    cap : ., mut = capacity;
    if cap <= 0 { cap = 1; }
    if g_chan_count >= g_chan_cap {
        nc := g_chan_cap * 2;
        nb := alloc(nc * 56);
        _dyncpy(g_channels, g_chan_cap * 56, nb);
        g_chan_cap = nc;
        g_channels = nb;
    }
    ci := g_chan_count;
    g_chan_count = g_chan_count + 1;
    off := ci * 56;
    // Allocate ring buffer separately (capacity × 8 bytes)
    ring := alloc(cap * 8);
    // Zero-init the ring
    ri : ., mut = 0;
    loop { if ri >= cap { break; } w64(ring, ri * 8, 0); ri = ri + 1; }
    w64(g_channels, off + 0, ring);  // save pointer to ring
    w64(g_channels, off + 8, cap);
    w64(g_channels, off + 16, 0);   // head
    w64(g_channels, off + 24, 0);   // tail
    w64(g_channels, off + 32, 0);   // count
    w64(g_channels, off + 40, -1);  // send_wait
    w64(g_channels, off + 48, -1);  // recv_wait
    return ci;
}

// ── Internal helpers ──
fn _ch_field(ci: int, field_off: int) -> int { return r64(g_channels, ci * 56 + field_off); }
fn _ch_set(ci: int, field_off: int, v: int) { w64(g_channels, ci * 56 + field_off, v); }

fn chan_send(ci: int, val: int) {
    loop {
        if _ch_field(ci, 32) < _ch_field(ci, 8) { break; }
        // Full — park
        _ch_set(ci, 40, g_cur_fiber);
        fiber_wait(ci);
        fiber_yield();
    }
    ring := _ch_field(ci, 0);
    tail := _ch_field(ci, 24);
    cap := _ch_field(ci, 8);
    w64(ring, tail * 8, val);
    _ch_set(ci, 24, (tail + 1) % cap);
    _ch_set(ci, 32, _ch_field(ci, 32) + 1);
    // Wake recv waiter
    rw := _ch_field(ci, 48);
    if rw >= 0 { _ch_set(ci, 48, -1); fiber_wake(rw); }
}

fn chan_recv(ci: int) -> int {
    loop {
        if _ch_field(ci, 32) > 0 { break; }
        // Empty — park
        _ch_set(ci, 48, g_cur_fiber);
        fiber_wait(ci);
        fiber_yield();
    }
    ring := _ch_field(ci, 0);
    head := _ch_field(ci, 16);
    cap := _ch_field(ci, 8);
    val := r64(ring, head * 8);
    _ch_set(ci, 16, (head + 1) % cap);
    _ch_set(ci, 32, _ch_field(ci, 32) - 1);
    // Wake send waiter
    sw := _ch_field(ci, 40);
    if sw >= 0 { _ch_set(ci, 40, -1); fiber_wake(sw); }
    return val;
}
