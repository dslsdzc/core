fn main() -> int {
    let x := 42;
    let y := match x {
        1 => 10,
        2 => 20,
        _ => 99,
    };
    return y;
}
