fn helper(x: bool) -> bool { return x; }
fn f(a: int) -> int #check(helper(true)) { return a; }
fn main() -> int { return f(1); }
