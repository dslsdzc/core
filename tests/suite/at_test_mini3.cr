import io

struct Point:
    x: int, y: int

fn test_sizeof_int() -> int:
    sz := @sizeOf(int)
    if sz != 8:
        return 1
    return 0

fn test_sizeof_bool() -> int:
    sz := @sizeOf(bool)
    if sz != 1:
        return 1
    return 0

fn test_sizeof_struct() -> int:
    sz := @sizeOf(Point)
    if sz < 8:
        return 1
    return 0

fn main() -> int:
    r1 := test_sizeof_int()
    if r1 != 0:
        print("FAIL sizeof_int: ")
        println(int_str(r1))
        return r1
    r2 := test_sizeof_bool()
    if r2 != 0:
        print("FAIL sizeof_bool: ")
        println(int_str(r2))
        return r2
    r4 := test_sizeof_struct()
    if r4 != 0:
        print("FAIL sizeof_struct: ")
        println(int_str(r4))
        return r4
    println("ALL PASS")
    return 0
