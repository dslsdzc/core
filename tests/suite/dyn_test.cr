import io

fn test_dyn_basic() -> int:
    x : dyn = 42
    // Single-path dyn should work like normal value
    if x != 42:
        return 1
    return 0

fn test_dyn_reassign() -> int:
    x : dyn = 42
    x = "hello"
    // After reassignment, x should be string
    if str_len(x) < 1:
        return 1
    return 0

fn test_dyn_multi_path() -> int:
    cond : int = 1
    x : dyn = 0
    if cond != 0:
        x = 42
    else:
        x = "hello"
    // x could be int or string
    // Just verify it compiles and runs
    return 0

fn main() -> int:
    r1 := test_dyn_basic()
    if r1 != 0:
        print("FAIL basic: ")
        println(int_str(r1))
        return r1
    r2 := test_dyn_reassign()
    if r2 != 0:
        print("FAIL reassign: ")
        println(int_str(r2))
        return r2
    r3 := test_dyn_multi_path()
    if r3 != 0:
        print("FAIL multipath: ")
        println(int_str(r3))
        return r3
    println("ALL PASS")
    return 0
