struct NA { x: int }
struct NB { x: int }
fn main() -> int {
    a : NA? = NA { x: 1 };
    b : NB? = NB { x: 2 };
    a = b;
    return 0;
}
