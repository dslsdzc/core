struct Point:
    x: int, y: int

fn test_sizeof_int() -> int:
    if @sizeOf(int) != 8:
        return 1
    return 0

fn test_fields_struct() -> int:
    flds := @fields(Point)
    if str_len(flds) < 3:
        return 1
    return 0

fn test_hasfield() -> int:
    if @hasField(Point, "x") == 0:
        return 1
    if @hasField(Point, "z") != 0:
        return 2
    return 0

fn test_field_offset() -> int:
    off := @field(Point, "x")
    if off < 0:
        return 1
    if off % 8 != 0:
        return 2
    return 0

fn test_typeinfo() -> int:
    ti := @typeInfo(Point)
    if str_len(ti) == 0:
        return 1
    ti2 := @typeInfo(int)
    if str_len(ti2) == 0:
        return 2
    return 0

fn main() -> int:
    r1 := test_sizeof_int()
    if r1 != 0:
        return r1
    r2 := test_fields_struct()
    if r2 != 0:
        return r2
    r3 := test_hasfield()
    if r3 != 0:
        return r3
    r4 := test_field_offset()
    if r4 != 0:
        return r4
    r5 := test_typeinfo()
    if r5 != 0:
        return r5
    return 0
