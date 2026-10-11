import io

fn test_alignof_int() -> int:
    al := @alignOf(int)
    if al != 8:
        return 1
    return 0

fn main() -> int:
    r3 := test_alignof_int()
    if r3 != 0:
        print("FAIL alignof_int: ")
        println(int_str(r3))
        return r3
    println("ALL PASS")
    return 0
