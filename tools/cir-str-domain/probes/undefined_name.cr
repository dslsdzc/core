import io

fn a(x: int, y: int) -> int {
    return x + y;
}

fn b() -> int {
    return zzz;
}

fn main() -> int {
    print("A="); println(int_str(a(1, 2)));
    return b();
}
