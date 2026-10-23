import io
import chan

fn test_chan_basic() -> int:
    ch := chan_make(8, 10)
    if ch < 0:
        return 1
    chan_send(ch, 42)
    val := chan_recv(ch)
    if val != 42:
        return 2
    return 0

fn main() -> int:
    r1 := test_chan_basic()
    if r1 != 0:
        print("FAIL: ")
        println(int_str(r1))
        return r1
    println("ALL PASS")
    return 0
