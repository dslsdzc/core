struct NA { x: int }
fn main() -> int {
    a : NA = NA { x: 1 };
    b : int = 2;
    a = b;
    return a.x;
}
