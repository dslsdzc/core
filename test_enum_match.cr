// Test enum match
enum Color {
    Red;
    Blue;
    Green;
}

fn main() -> int {
    let x := Color.Red;
    let y := match x {
        Color.Red => 10,
        Color.Blue => 20,
        Color.Green => 30,
    };
    return y;
}
