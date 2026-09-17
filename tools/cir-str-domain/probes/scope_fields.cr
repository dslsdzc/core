import io

struct Point { x: int, y: int }
struct Pair { a: int, b: str }

fn fields_helper() -> int {
    print("F_POINT="); println(@fields(Point));
    print("F_PAIR="); println(@fields(Pair));
    return 0;
}

fn main() -> int {
    print("F_MAIN="); println(@fields(Point));
    fields_helper();
    return 0;
}
