struct Box[T] { v: T }
fn g(a: Box[int], b: Box[int]) -> int {
    a = b;
    return a.v;
}
fn main() -> int { return 0; }
