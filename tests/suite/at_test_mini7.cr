import io

fn test_no_bounds_check() -> int {
    @NoBoundsCheck;
    return 0;
}

fn main() -> int {
    r5 := test_no_bounds_check();  if r5 != 0 { print("FAIL no_bounds_check: "); println(int_str(r5)); return r5; }
    println("ALL PASS");
    return 0;
}
