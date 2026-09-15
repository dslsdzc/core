struct NA { x: int }
struct NB { x: int }
fn main() -> int {
    a : [NA; 2] = [NA { x: 1 }, NA { x: 2 }];
    b : [NB; 2] = [NB { x: 3 }, NB { x: 4 }];
    a = b;
    return 0;
}
