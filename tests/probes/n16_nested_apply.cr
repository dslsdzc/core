struct Box[T] { v: T }
fn g(a: Box[Box[int]], b: Box[Box[int]]) -> int { a = b; return 0; }
fn main() -> int { return 0; }
