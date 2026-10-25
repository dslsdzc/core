// V4 generic surface smoke test.
// Inferred parameters/fields are covered by tests/selfhost/test_v4_inference.py.
import io
import fmt

struct Box:
    val: int

struct SBox:
    val: string

fn id_int(x: int) -> int:
    return x

fn id_len(x: string) -> int:
    return str_len(x)

fn box_int(b: Box) -> int:
    return b.val

fn box_len(b: SBox) -> int:
    return str_len(b.val)

fn pair(a: int, b: string) -> int:
    if a != 1:
        return 1
    if str_len(b) < 1:
        return 1
    return 0

fn main() -> int:
    r1 := id_int(42)
    if r1 != 42:
        print("FAIL id_int: ")
        println(int_str(r1))
        return 1

    r2 := id_len("hello")
    if r2 != 5:
        print("FAIL id_len: ")
        println(int_str(r2))
        return 2

    b1 := Box { val = 100 }
    if box_int(b1) != 100:
        return 3

    b2 := SBox { val = "world" }
    if box_len(b2) != 5:
        return 4

    if pair(1, "two") != 0:
        return 5

    println("ALL PASS")
    return 0
