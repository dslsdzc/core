struct NA { x: int }
struct NB { x: int }
struct Box[T] { v: T }
fn g(a: Box[NA], b: Box[NA]) -> int { a = b; return a.v.x; }
fn h(a: Box[NA], b: Box[NB]) -> int { a = b; return a.v.x; }
fn main() -> int { return 0; }
