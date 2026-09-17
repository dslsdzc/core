fn g() -> int { return 3; }
fn f() -> int {
    x := g();
    #check(1 > 0)
    return x;
}
fn main() -> int { return f(); }
