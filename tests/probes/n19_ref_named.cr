struct NA { x: int }
struct NB { x: int }
fn g(a: &NA, b: &NB) -> int { return 0; }
fn main() -> int {
    x : ., mut = NA { x: 1 };
    y : ., mut = NB { x: 2 };
    p := &x;
    q := &y;
    g(p, q);
    return 0;
}
