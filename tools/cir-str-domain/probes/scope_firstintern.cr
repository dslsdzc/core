import io

struct One { x: int }
struct Two { x: int, y: int }

fn main() -> int {
    print("ONE="); println(@fields(One));
    print("TWO="); println(@fields(Two));
    return 0;
}
