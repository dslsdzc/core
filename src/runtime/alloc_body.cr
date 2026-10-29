// Raw allocator bodies. Compiled by tools/gen_alloc_blob.py with raw-int
// semantics; the blob generator supplies cell_load/cell_store and patches the
// globals listed in EXTERNAL_GLOBALS.

g_heap_ptr : string, mut
g_heap_end : string, mut
g_alloc_fail_request : int, mut
g_alloc_fail_class : int, mut
g_alloc_fail_cursor : int, mut
g_alloc_fail_limit : int, mut

fn alloc_ptr(v: int) -> string:
    p : ., mut = ""
    unsafe:
        p = @str_of(v)
    return p

fn alloc_uword(s: string) -> int:
    v : ., mut = 0
    unsafe:
        v = @ptr_of(s)
    return v

fn alloc_fail(size: int, cls: int, cursor: int, limit: int) -> string:
    g_alloc_fail_request = size
    g_alloc_fail_class = cls
    g_alloc_fail_cursor = cursor
    g_alloc_fail_limit = limit
    syscall3(60, 132, 0, 0)
    return alloc_ptr(0)

fn zero_alloc(p: string, n: int):
    addr := alloc_uword(p)
    // Large page-aligned regions come from a fresh anonymous mapping. Ask the
    // kernel to drop the pages instead of writing every byte from Core.
    if n >= 4096 && addr % 4096 == 0:
        syscall3(28, addr, n, 4)
        return
    i : ., mut = 0
    loop:
        if i >= n:
            break
        store8(p, i, 0)
        i = i + 1

fn alloc_global(size: int, aligned: int, heap_start: string) -> string:
    need : ., mut = aligned
    if aligned >= 4096:
        need = ((aligned + 4095) / 4096) * 4096
    hp := g_heap_ptr
    hp_raw : ., mut = alloc_uword(hp)
    he_raw : ., mut = alloc_uword(g_heap_end)
    if hp_raw == 0:
        hp_raw = alloc_uword(heap_start)
        he_raw = hp_raw + 1073741824
        g_heap_ptr = alloc_ptr(hp_raw)
        g_heap_end = alloc_ptr(he_raw)
    if need >= 4096:
        hp_raw = ((hp_raw + 4095) / 4096) * 4096
    new_raw : ., mut = hp_raw + need
    if new_raw > he_raw:
        heap_expand()
        hp_raw = alloc_uword(g_heap_ptr)
        he_raw = alloc_uword(g_heap_end)
        if need >= 4096:
            hp_raw = ((hp_raw + 4095) / 4096) * 4096
        new_raw = hp_raw + need
        if new_raw > he_raw:
            return alloc_fail(size, -1, hp_raw, he_raw)
    g_heap_ptr = alloc_ptr(new_raw)
    p := alloc_ptr(hp_raw)
    zero_alloc(p, need)
    cell_store(p, 0, size)
    return alloc_ptr(hp_raw + 8)

fn alloc_simple(size: int, heap_start: string) -> string:
    if size < 0:
        return alloc_ptr(0)
    if size > 67108864:
        return alloc_ptr(0)
    aligned := (size + 15) / 8 * 8
    return alloc_global(size, aligned, heap_start)

g_arena_scalars : string, mut
g_arena_scalars_ready : int, mut
g_arena_suspend : int, mut
g_arena_slot : string, mut
g_arena_slot_cursor : string, mut
g_arena_slot_next : string, mut
g_arena_static : string, mut
g_arena_sizes : string, mut
g_arena_cursors : string, mut
g_segment_base : string, mut
g_class_base : string, mut
g_class_cursor : string, mut
g_class_limit : string, mut
g_class_lookup : string, mut

fn arena_slot_base(slot: int) -> string:
    seg := load_str_ptr(g_segment_base, (slot / 64) * 8)
    return alloc_ptr(alloc_uword(seg) + (slot % 64) * 1048576)

fn arena_fail_slot(size: int, cursor: int, limit: int) -> int:
    g_alloc_fail_request = size
    g_alloc_fail_class = -1
    g_alloc_fail_cursor = cursor
    g_alloc_fail_limit = limit
    syscall3(60, 132, 0, 0)
    return 0

fn arena_get_slot(ai: int, size: int) -> int:
    sf := cell_load(g_arena_scalars, 40)
    slot : ., mut = -1
    if sf >= 0:
        slot = sf
        cell_store(g_arena_scalars, 40, cell_load(g_arena_slot_next, sf * 8))
    else:
        count := cell_load(g_arena_scalars, 32)
        pool := cell_load(g_arena_scalars, 16)
        if count >= pool:
            arena_grow_pool()
            count = cell_load(g_arena_scalars, 32)
            pool = cell_load(g_arena_scalars, 16)
        if count >= pool:
            return arena_fail_slot(size, count, pool)
        slot = count
        cell_store(g_arena_scalars, 32, count + 1)
        old := cell_load(g_arena_slot, ai * 8)
        if old >= 0:
            cell_store(g_arena_slot_next, slot * 8, old)
        else:
            cell_store(g_arena_slot_next, slot * 8, -1)
        cell_store(g_arena_slot, ai * 8, slot)
    cell_store(g_arena_slot_cursor, ai * 8, 0)
    return slot

fn alloc_arena(size: int, heap_start: string) -> string:
    if size < 0:
        return alloc_ptr(0)
    if size > 1099511627776:
        return alloc_fail(size, -1, 0, 0)
    aligned := (size + 15) / 8 * 8
    if g_arena_suspend != 0 || g_arena_scalars_ready == 0:
        return alloc_global(size, aligned, heap_start)
    if alloc_uword(g_arena_scalars) == 0:
        return alloc_global(size, aligned, heap_start)
    ai := cell_load(g_arena_scalars, 0)
    if ai < 0:
        return alloc_global(size, aligned, heap_start)
    // Large objects use the global bump heap. Kernel-backed extents are a
    // separate follow-up; this keeps the raw body free of six-argument
    // syscalls while preserving allocation correctness.
    if aligned > 1048576:
        return alloc_global(size, aligned, heap_start)

    slot : ., mut = cell_load(g_arena_slot, ai * 8)
    if slot < 0:
        slot = arena_get_slot(ai, size)
    max_size := cell_load(g_arena_scalars, 8)
    slot_base : ., mut = arena_slot_base(slot)
    if cell_load(g_arena_static, ai * 8) != 0:
        cur := cell_load(g_arena_cursors, ai * 8)
        limit := cell_load(g_arena_sizes, ai * 8)
        if cur + aligned > limit:
            return alloc_fail(size, -1, cur, limit)
        cell_store(g_arena_cursors, ai * 8, cur + aligned)
        p := alloc_ptr(alloc_uword(slot_base) + cur)
        zero_alloc(p, aligned)
        cell_store(p, 0, size)
        return alloc_ptr(alloc_uword(p) + 8)

    loop:
        lookup := aligned / 16
        cls : ., mut = 25
        if lookup <= 255:
            cls = cell_load(g_class_lookup, lookup * 8)
        idx := ai * 26 + cls
        base := cell_load(g_class_base, idx * 8)
        if base < 0:
            if cls == 25:
                slot_cur := cell_load(g_arena_slot_cursor, ai * 8)
                if aligned > max_size - slot_cur:
                    slot = arena_get_slot(ai, size)
                    slot_base = arena_slot_base(slot)
                else:
                    base = slot_cur
                    cell_store(g_class_base, idx * 8, base)
                    cell_store(g_class_limit, idx * 8, max_size)
                    cell_store(g_class_cursor, idx * 8, 0)
                    cell_store(g_arena_slot_cursor, ai * 8, max_size)
            else:
                slot_cur := cell_load(g_arena_slot_cursor, ai * 8)
                newcur := slot_cur + 4096
                if newcur > max_size:
                    slot = arena_get_slot(ai, size)
                    slot_base = arena_slot_base(slot)
                else:
                    base = slot_cur
                    cell_store(g_arena_slot_cursor, ai * 8, newcur)
                    cell_store(g_class_base, idx * 8, base)
                    cell_store(g_class_limit, idx * 8, newcur)
                    cell_store(g_class_cursor, idx * 8, 0)
        base = cell_load(g_class_base, idx * 8)
        cur := cell_load(g_class_cursor, idx * 8)
        limit := cell_load(g_class_limit, idx * 8)
        if base >= 0 && cur + aligned <= limit - base:
            cell_store(g_class_cursor, idx * 8, cur + aligned)
            p := alloc_ptr(alloc_uword(slot_base) + base + cur)
            zero_alloc(p, aligned)
            cell_store(p, 0, size)
            return alloc_ptr(alloc_uword(p) + 8)
        if base >= 0:
            cell_store(g_class_base, idx * 8, -1)

    return alloc_ptr(0)
