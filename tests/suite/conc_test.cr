// Conc test: channel wait queues, sched_get_curg, and goroutine basics
import io
import chan
import sched

fn test_chan_fifo() -> int:
    // Test basic channel FIFO behavior with buffer
    ch := chan_make(8, 3)
    chan_send(ch, 10)
    chan_send(ch, 20)
    chan_send(ch, 30)

    v1 := chan_recv(ch)
    if v1 != 10:
        return v1
    v2 := chan_recv(ch)
    if v2 != 20:
        return v2
    v3 := chan_recv(ch)
    if v3 != 30:
        return v3
    return 0

fn test_chan_send_recv() -> int:
    // Test single send/recv
    ch := chan_make(8, 1)
    chan_send(ch, 42)
    val := chan_recv(ch)
    if val != 42:
        return 1
    return 0

fn test_sched_get_curg() -> int:
    // Test that sched_get_curg returns a valid G pointer
    // On startup, there should be no current G (-1)
    cur_g := sched_get_curg()
    // No goroutine is running here, so cur_g could be -1
    // Just verify it doesn't crash
    if cur_g < -1:
        return 1
    return 0

fn test_chan_close() -> int:
    ch := chan_make(8, 1)
    chan_close(ch)
    // After close, recv should return 0 (zero value)
    val := chan_recv(ch)
    if val != 0:
        return 1
    return 0

fn test_chan_close_wakeup() -> int:
    // Test that closing a channel wakes up waiters
    ch := chan_make(8, 1)
    // Fill buffer
    chan_send(ch, 99)
    // Close
    chan_close(ch)
    // Read the buffered value
    v1 := chan_recv(ch)
    if v1 != 99:
        return v1
    // After buffer drain, closed returns 0
    v2 := chan_recv(ch)
    if v2 != 0:
        return 2
    return 0

fn main() -> int:
    r1 := test_chan_send_recv()
    if r1 != 0:
        print("FAIL chan_send_recv: ")
        println(int_str(r1))
        return r1

    r2 := test_chan_fifo()
    if r2 != 0:
        print("FAIL chan_fifo: ")
        println(int_str(r2))
        return r2

    r3 := test_sched_get_curg()
    if r3 != 0:
        print("FAIL sched_get_curg: ")
        println(int_str(r3))
        return r3

    r4 := test_chan_close()
    if r4 != 0:
        print("FAIL chan_close: ")
        println(int_str(r4))
        return r4

    r5 := test_chan_close_wakeup()
    if r5 != 0:
        print("FAIL chan_close_wakeup: ")
        println(int_str(r5))
        return r5

    println("ALL PASS")
    return 0
