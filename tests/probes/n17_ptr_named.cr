struct NA { x: int }
struct NB { x: int }
fn g(a: *NA, b: *NB) -> int { a = b; return 0; }
fn main() -> int { return 0; }
