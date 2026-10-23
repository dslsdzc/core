import io

fn expensive(n: int) -> int:
    // Side-effect-free pure function
    return n * n

fn test_lazy_basic() -> int:
    // expensive() is pure → compiler may defer it
    x := expensive(42)
    if x != 1764:
        return 1
    return 0

fn main() -> int:
    r1 := test_lazy_basic()
    if r1 != 0:
        print("FAIL: ")
        println(int_str(r1))
        return r1
    println("ALL PASS")
    return 0
