fn f(a: int) -> int
    #check(a >= 0)
    #ensure(result > a)
{
    return a + 1;
}
fn main() -> int { return f(1); }
