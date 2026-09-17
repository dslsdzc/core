// @ builtins test suite
import io

fn test_sizeof_int() -> int {
    sz := @sizeOf(int);
    // @sizeOf(int) should return 8 on x86-64
    if sz != 8 { return 1; }
    return 0;
}

fn test_sizeof_bool() -> int {
    sz := @sizeOf(bool);
    if sz != 1 { return 1; }
    return 0;
}

fn test_alignof_int() -> int {
    al := @alignOf(int);
    if al != 8 { return 1; }
    return 0;
}

// Struct type for field tests
struct Point { x: int, y: int }

fn test_sizeof_struct() -> int {
    sz := @sizeOf(Point);
    // 终审 M1 收紧：Point = 2×int = 16（旧实现首个用户类型拿下标 8 = TI_DEX_S
    // 哨兵，@sizeOf 恒返回 8——弱断言 sz < 8 漏检）
    if sz != 16 { return 1; }
    return 0;
}

// M1 回归（终审）：3 字段 struct 的首个动态类型场景——@sizeOf 必须返回 24
struct P3 { a: int, b: int, c: int }

fn test_sizeof_3field_struct() -> int {
    sz := @sizeOf(P3);
    if sz != 24 { return 1; }
    return 0;
}

fn test_no_bounds_check() -> int {
    @NoBoundsCheck;
    return 0;  // just verifies it compiles
}

fn add(a: int, b: int) -> int { return a + b; }

fn test_inline_hint() -> int {
    result := @inline(add)(3, 4);
    if result != 7 { return 1; }
    return 0;
}

fn test_fields_basic() -> int {
    flds := @fields(Point);
    if str_len(flds) < 3 { return 1; }  // "x,y"
    return 0;
}

fn main() -> int {
    r1 := test_sizeof_int();  if r1 != 0 { print("FAIL sizeof_int: "); println(int_str(r1)); return r1; }
    r2 := test_sizeof_bool();  if r2 != 0 { print("FAIL sizeof_bool: "); println(int_str(r2)); return r2; }
    r3 := test_alignof_int();  if r3 != 0 { print("FAIL alignof_int: "); println(int_str(r3)); return r3; }
    r4 := test_sizeof_struct();  if r4 != 0 { print("FAIL sizeof_struct: "); println(int_str(r4)); return r4; }
    r8 := test_sizeof_3field_struct();  if r8 != 0 { print("FAIL sizeof_3field: "); println(int_str(r8)); return r8; }
    r5 := test_no_bounds_check();  if r5 != 0 { print("FAIL no_bounds_check: "); println(int_str(r5)); return r5; }
    r6 := test_inline_hint();  if r6 != 0 { print("FAIL inline: "); println(int_str(r6)); return r6; }
    r7 := test_fields_basic();  if r7 != 0 { print("FAIL fields: "); println(int_str(r7)); return r7; }
    println("ALL PASS");
    return 0;
}
