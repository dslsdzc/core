// Arena boundary regression: size-class edges, large objects, slot/pool edges,
// duplicate reset, and free-list reuse.
import arena

fn check_size(size: int, code: int) -> int:
    a := arena_new()
    p := alloc(size)
    if p == 0:
        return code
    if size > 0:
        cell_store(p, 0, code)
        if cell_load(p, 0) != code:
            return code + 1000
    if size > 8:
        cell_store(p, size - 8, code + 1)
        if cell_load(p, size - 8) != code + 1:
            return code + 2000
    arena_reset(a)
    return 0

fn main() -> int:
    // A zero pool limit means "no limit".
    arena_init(0, 1048576)

    r : ., mut = check_size(0, 1)
    if r != 0:
        return r
    r = check_size(3361, 10)
    if r != 0:
        return r
    r = check_size(3362, 20)
    if r != 0:
        return r
    r = check_size(4088, 30)
    if r != 0:
        return r
    r = check_size(4089, 40)
    if r != 0:
        return r
    r = check_size(4096, 50)
    if r != 0:
        return r
    r = check_size(1048568, 60)
    if r != 0:
        return r
    r = check_size(1048576, 70)
    if r != 0:
        return r
    r = check_size(1048584, 80)
    if r != 0:
        return r
    r = check_size(67108856, 90)
    if r != 0:
        return r
    r = check_size(67108864, 100)
    if r != 0:
        return r
    r = check_size(67108865, 110)
    if r != 0:
        return r

    // Three dedicated mmap extents in one arena.
    big := arena_new()
    p0 := alloc(104857600)
    p1 := alloc(104857600)
    p2 := alloc(104857600)
    if p0 == 0 || p1 == 0 || p2 == 0:
        return 120
    if p0 == p1 || p1 == p2 || p0 == p2:
        return 121
    cell_store(p0, 0, 1)
    cell_store(p1, 0, 2)
    cell_store(p2, 0, 3)
    if cell_load(p0, 0) != 1 || cell_load(p1, 0) != 2 || cell_load(p2, 0) != 3:
        return 122
    arena_reset(big)

    // Duplicate reset must not corrupt the free list.
    a := arena_new()
    arena_reset(a)
    arena_reset(a)
    b := arena_new()
    if b != a:
        return 130
    arena_reset(b)

    // Slots above 63 come from the second 64MB segment.
    i : ., mut = 0
    loop:
        if i >= 70:
            break
        ai := arena_new()
        p := alloc(64)
        cell_store(p, 0, i + 1)
        if cell_load(p, 0) != i + 1:
            return 140
        i = i + 1

    return 0
