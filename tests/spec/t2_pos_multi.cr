fn f(a: int) -> int
    #check(a >= 0)
    #check(a <= 100)
    #ensure(result >= 0)
{
    return a;
}
fn main() -> int { return f(7); }
