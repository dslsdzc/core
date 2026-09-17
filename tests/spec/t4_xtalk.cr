struct A { v: int }
struct B { v: int }
impl A {
    fn get(self, alpha: int) -> int #check(alpha >= 0) { return self.v + alpha; }
}
impl B {
    fn get(self, beta: int) -> int #check(beta >= 0) { return self.v + beta; }
}
fn main() -> int { return A { v: 1 }.get(2); }
