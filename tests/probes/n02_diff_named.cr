struct NA { x: int }
struct NB { x: int }
fn main() -> int {
    a : ., mut = NA { x: 1 };
    b : ., mut = NB { x: 2 };
    a = b;
    return a.x;
}
