import io

fn test_inline_hint() -> int:
    fn add(a: int, b: int) -> int:
        return a + b
    result := add(3, 4)
    if result != 7:
        return 1
    return 0

fn main() -> int:
    r6 := test_inline_hint()
    if r6 != 0:
        print("FAIL inline: ")
        println(int_str(r6))
        return r6
    println("ALL PASS")
    return 0
