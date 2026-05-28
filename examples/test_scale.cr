struct Point { x: int, y: int }
impl Point {
    fn sum(self: Point) -> int { return self.x + self.y; }
    fn scale(self: Point, factor: int) -> int { return (self.x + self.y) * factor; }
}
fn main() -> int {
    p := = Point { x = 10, y = 20 };
    s := = p.sum();
    scaled := = p.scale(3);
    return s + scaled;
}
