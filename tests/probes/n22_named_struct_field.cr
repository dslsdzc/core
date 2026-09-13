struct NA { x: int }
fn take(v: NA) -> int { return v.x; }
fn main() -> int {
    a : ., mut = NA { x: 1 };
    b : ., mut = NA { x: 2 };
    a = b;
    return take(a);
}
