fn main() -> int {
    x : int? = Some(5);
    y := x?;
    z : int? = None;
    return y;
}
