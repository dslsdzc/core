import io

fn test_sizeof_int() -> int {
    sz := @sizeOf(int);
    if sz != 8 { return 1; }
    return 0;
}

fn main() -> int {
    r1 := test_sizeof_int();  if r1 != 0 { print("FAIL sizeof_int: "); println(int_str(r1)); return r1; }
    println("ALL PASS");
    return 0;
}
