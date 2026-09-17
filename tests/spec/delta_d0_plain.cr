fn check(x: bool) -> bool { return x; }
fn g() -> bool { return true; }
fn f(a: int) -> int { return a; }
fn main() -> int { if check(g()) { return f(1); } return 0; }
