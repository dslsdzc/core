fn square(x: int) -> int { return x * x; }
fn main() -> int {
    arr := go i 0..3 square(i);
    return arr[0] + arr[1] + arr[2];
}
