enum EA { X, Y }
enum EB { X, Y }
fn main() -> int {
    a : ., mut = EA.X;
    b : ., mut = EB.X;
    a = b;
    return 0;
}
