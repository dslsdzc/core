import io

struct Point { x: int, y: int }

fn tinfo_helper() -> int {
    print("T_POINT="); println(@typeInfo(Point));
    print("T_INT="); println(@typeInfo(int));
    return 0;
}

fn main() -> int {
    tinfo_helper();
    return 0;
}
