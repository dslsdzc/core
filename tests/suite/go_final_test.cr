// go_final_test.cr — end-to-end goroutine test.
//
// `go f(args)` → sched_go(@addr(f), args) → g_new stores the function
// address in G.saved_fn (offset 56) → goroutine_entry_wrapper calls
// saved_fn(saved_arg) → result sent to result_ch → caller chan_recv gets it.
import io
import sched
import chan

fn square(n: int) -> int:
    return n * n

fn main() -> int:
    sched_init()
    ch := go square(21)
    result := chan_recv(ch)
    if result != 441:
        print("FAIL: ")
        println(int_str(result))
        return 1
    println("ALL PASS")
    return 0
