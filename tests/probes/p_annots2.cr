fn add(a: int, b: int) -> int { return a + b; }
fn main() -> int {
    @no_bounds_check();
    @fast();
    r := @inline(add)(3, 4);
    return r;
}
