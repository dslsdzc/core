fn f(a: int) -> int
    #check(1 > 0)
    #check(a >= 0)
    #check(1 < 0)
{
    return a;
}
fn main() -> int { return f(1); }
