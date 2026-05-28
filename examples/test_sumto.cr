fn sum_to(n: int) -> int {
    i : ., mut = 1;
    s : ., mut = 0;
    loop {
        if i > n { break; }
        s = s + i;
        i = i + 1;
    }
    return s;
}
fn main() -> int { return sum_to(5); }
