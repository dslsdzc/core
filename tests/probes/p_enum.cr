enum Color { Red, Green, Blue }
fn main() -> int {
    x := Green();
    return match x { Red => 0, Green => 1, Blue => 2, };
}
