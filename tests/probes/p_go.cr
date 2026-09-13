fn work() -> int { return 1; }
fn main() -> int {
    f := go work();
    r := await f;
    return r;
}
