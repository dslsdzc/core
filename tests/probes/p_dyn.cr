fn main() -> int {
    cond : int = 1;
    x : dyn = 0;
    if cond != 0 { x = 42; } else { x = "hello"; }
    return 0;
}
