struct NA { x: int }
struct NB { x: int }
fn main() -> int {
    a : ., mut = (NA { x: 1 }, 2);
    b : ., mut = (NB { x: 3 }, 4);
    a = b;
    return 0;
}
