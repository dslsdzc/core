struct Point { x: int, y: int }
impl Point {
    fn sum(self: Point) -> int { return self.x + self.y; }
}
fn main() -> int {
    p := = Point { x = 10, y = 20 };
    return p.sum();
}
