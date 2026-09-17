import io

struct Point { x: int, y: int }

fn test_fields_basic() -> int {
    flds := @fields(Point);
    print("fields=[");
    print(flds);
    print("] len=");
    println(int_str(str_len(flds)));
    if str_len(flds) != 3 { return 1; }
    return 0;
}

fn main() -> int {
    r := test_fields_basic();
    println(int_str(r));
    return r;
}
