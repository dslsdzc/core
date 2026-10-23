// go_parallel_test.cr — M:N concurrency end-to-end test.
//
// Two goroutines spawned via `go`, each yielding to the scheduler before
// computing, results collected through their per-goroutine result channels.
// Exercises: per-M local run queues, goroutine exit/reclamation
// (g_free + sched_schedule), and channel result handoff under yield.
import io
import sched
import chan

fn compute(n: int) -> int:
    yield  // give others a chance
    return n + 1

fn main() -> int:
    sched_init()
    c1 := go compute(1)
    c2 := go compute(2)
    r1 := chan_recv(c1)
    r2 := chan_recv(c2)
    if r1 != 2:
        print("FAIL r1=")
        println(int_str(r1))
        return 1
    if r2 != 3:
        print("FAIL r2=")
        println(int_str(r2))
        return 2
    println("ALL PASS")
    return 0
