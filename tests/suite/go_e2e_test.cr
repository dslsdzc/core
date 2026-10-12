// go_e2e_test.cr — end-to-end goroutine test.
//
// Spawns square(21) via `go`, waits on the result channel, and checks 441.
// Full runtime path: `go f(args)` → sched_go(@addr(f), arg) → g_new stores
// saved_fn/saved_arg in the G struct → fiber_switch → goroutine_entry_wrapper
// (backend-emitted) calls saved_fn(saved_arg) → result sent to result_ch →
// caller chan_recv gets the result.
import io
import sched

fn square(n: int) -> int:
    return n * n

fn main() -> int:
    sched_init()
    ch := go square(21)
    result := chan_recv(ch)
    if result != 441:
        return 1
    println("ALL PASS")
    return 0
