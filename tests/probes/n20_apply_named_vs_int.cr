struct NA { x: int }
struct Box[T] { v: T }
fn g(a: Box[NA], b: Box[int]) -> int { a = b; return 0; }
fn main() -> int { return 0; }
