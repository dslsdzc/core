import io

fn test_go_basic() -> int:
    // Just verify go compiles
    go 42  // minimal go expression
    return 0

fn main() -> int:
    r1 := test_go_basic()
    if r1 != 0:
        print("FAIL: ")
        println(int_str(r1))
        return r1
    println("ALL PASS")
    return 0
