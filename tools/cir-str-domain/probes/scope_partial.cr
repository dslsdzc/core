import io

struct Two { x: int, y: int }

fn main() -> int {
    print("TWO="); println(@fields(Two));
    return 0;
}
