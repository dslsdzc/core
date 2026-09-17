fn add(a: int, b: int) -> int { return a + b; }
fn main() -> int {
    @NoBoundsCheck();
    @fast();
    r := @inline(add)(3, 4);
    return r;
}
