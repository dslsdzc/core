fn check(x: bool) -> bool { return x; }
fn f() -> int #check(1 < 0) { return 1; }
fn main() -> int { return f(); }
