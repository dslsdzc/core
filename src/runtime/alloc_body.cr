// === alloc_body.cr ===
// Raw allocator bodies. Compiled by tools/gen_alloc_blob.py with raw-int
// semantics; the blob generator supplies cell_load/cell_store and patches the
// globals listed in EXTERNAL_GLOBALS.
//
// ABI: rdi = size, rsi = heap_start, rdx = heap_end (the end of the writable
// data segment). The trampoline in elf.cr supplies the last two values.

g_heap_ptr : string, mut
g_heap_end : string, mut
g_alloc_fail_request : int, mut
g_alloc_fail_class : int, mut
g_alloc_fail_cursor : int, mut
g_alloc_fail_limit : int, mut

// Reinterpret a raw machine word as a string pointer without allocation.
fn alloc_ptr(v: int) -> string:
    p : ., mut = ""
    unsafe:
        p = @str_of(v)
    return p

// Reinterpret a string pointer as a raw machine word without dereferencing it.
fn alloc_uword(s: string) -> int:
    v : ., mut = 0
    unsafe:
        v = @ptr_of(s)
    return v

// Record the failed size and allocator state in the g_alloc_fail_* witness
// globals, then terminate with exit status 132. The trailing return is unreachable.
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
    // kernel to drop the pages instead of writing every byte from Core. If the
    // hint fails, fall through to the byte loop so the block is still zeroed.
    if n >= 4096 && addr % 4096 == 0:
        r := syscall3(28, addr, n, 4)
        if r == 0:
            return
    i : ., mut = 0
    loop:
        if i >= n:
            break
        store8(p, i, 0)
        i = i + 1

// Bump allocator used when no arena is active. The heap window comes from the
// trampoline arguments on first use; callers pass an aligned size that includes
// the 8-byte block header, and large blocks are page-rounded here. On exhaustion
// heap_expand is called once; if the window still cannot fit, alloc_fail records
// the request and exits. The size header is stored at the block start and the
// payload begins at +8.
fn alloc_global(size: int, aligned: int, heap_start: string,
                heap_end: string) -> string:
    need : ., mut = aligned
    if aligned >= 4096:
        need = ((aligned + 4095) / 4096) * 4096
    hp := g_heap_ptr
    hp_raw : ., mut = alloc_uword(hp)
    he_raw : ., mut = alloc_uword(g_heap_end)
    if hp_raw == 0:
        hp_raw = alloc_uword(heap_start)
        he_raw = alloc_uword(heap_end)
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

// Size-limited wrapper around alloc_global. Negative requests and requests over
// 64 MiB return the null pointer. The aligned size also covers the 8-byte block
// header left by the (size + 15) / 8 * 8 rounding.
fn alloc_simple(size: int, heap_start: string, heap_end: string) -> string:
    if size < 0:
        return alloc_ptr(0)
    if size > 67108864:
        return alloc_ptr(0)
    aligned := (size + 15) / 8 * 8
    return alloc_global(size, aligned, heap_start, heap_end)

// Arena state shared with the stdlib arena implementation. Per-arena arrays are
// indexed by arena id; class metadata uses arena * 26 + class. Each M owns 256
// slots laid out in 64-slot, 1 MiB segments.
g_arena_scalars : string, mut
g_arena_scalars_ready : int, mut
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
g_arena_large_head : string, mut
g_arena_large_count : string, mut
g_slot_free_m : string, mut
g_slot_count_m : string, mut
g_segment_count_m : string, mut


// Slot id to the base address of its 1 MiB region: segment = slot / 64,
// offset within the segment = (slot % 64) * 1 MiB.
fn arena_slot_base(slot: int) -> string:
    seg := load_str_ptr(g_segment_base, (slot / 64) * 8)
    return alloc_ptr(alloc_uword(seg) + (slot % 64) * 1048576)

// Arena counterpart of alloc_fail: record the request, class index -1, cursor,
// and limit, then exit with status 132.
fn arena_fail_slot(size: int, cursor: int, limit: int) -> int:
    g_alloc_fail_request = size
    g_alloc_fail_class = -1
    g_alloc_fail_cursor = cursor
    g_alloc_fail_limit = limit
    syscall3(60, 132, 0, 0)
    return 0

// Return a slot for arena ai on the current M: pop the per-M free list, or bump
// the high-water count and grow the segment pool when needed. The chosen slot is
// linked at the head of ai's slot chain and becomes current. Pool exhaustion
// records a witness and exits; failure paths never return.
fn arena_get_slot(ai: int, size: int) -> int:
    m := rt_m_idx()
    if m < 0:
        m = 0
    sf := cell_load(g_slot_free_m, m * 8)
    slot : ., mut = -1
    if sf >= 0:
        slot = sf
        cell_store(g_slot_free_m, m * 8, cell_load(g_arena_slot_next, sf * 8))
    else:
        count := cell_load(g_slot_count_m, m * 8)
        if count >= 256:
            return arena_fail_slot(size, count, 256)
        slot = m * 256 + count
        cell_store(g_slot_count_m, m * 8, count + 1)
        seg := slot / 64
        if seg >= cell_load(g_segment_count_m, m * 8):
            arena_grow_pool()
        if seg >= cell_load(g_segment_count_m, m * 8):
            return arena_fail_slot(size, seg, 0)
    // Both the free-list and bump paths must link the new slot into this
    // arena's chain and make it current. arena_reset walks that chain to
    // return slots, so a missing link leaks the slot and lets the next
    // allocation reuse the old slot's cursor.
    old := cell_load(g_arena_slot, ai * 8)
    if old >= 0:
        cell_store(g_arena_slot_next, slot * 8, old)
    else:
        cell_store(g_arena_slot_next, slot * 8, -1)
    cell_store(g_arena_slot, ai * 8, slot)
    cell_store(g_arena_slot_cursor, ai * 8, 0)
    return slot

// Allocate a dedicated anonymous mapping for a large object and prepend it to
// the arena's extent list. The payload starts at +24 and munmap uses the length
// at +8. A failed mmap records a witness and exits.
fn alloc_arena_extent(size: int, aligned: int, ai: int) -> string:
    // Dedicated anonymous mapping. Layout matches arena.cr:
    //   +0  next extent pointer
    //   +8  total mapping length for munmap
    //   +16 hidden length header
    //   +24 payload
    total := aligned + 16
    p := syscall6(9, 0, total, 3, 16418, -1, 0)
    base := alloc_ptr(p)
    if p < 0:
        head := load_str_ptr(g_arena_large_head, ai * 8)
        return alloc_fail(size, -2, alloc_uword(head), 0)
    head := load_str_ptr(g_arena_large_head, ai * 8)
    store_str_ptr(base, 0, head)
    cell_store(base, 8, total)
    cell_store(base, 16, size)
    store_str_ptr(g_arena_large_head, ai * 8, base)
    cell_store(g_arena_large_count, ai * 8,
               cell_load(g_arena_large_count, ai * 8) + 1)
    return alloc_ptr(alloc_uword(base) + 24)

// Arena allocator. Negative sizes and requests over 1 TiB go to alloc_fail.
// Fall back to alloc_global when arenas are suspended, metadata is not ready, no
// current arena exists on the main M, or the scalar buffer is missing. Static
// arenas bump within one slot; non-static arenas use dedicated mmap extents
// above 1 MiB, otherwise a 26-class suballocator that carves slot chunks and
// retries when a class is full.
fn alloc_arena(size: int, heap_start: string, heap_end: string) -> string:
    if size < 0:
        return alloc_fail(size, -1, 0, 0)
    if size > 1099511627776:
        return alloc_fail(size, -1, 0, 0)
    aligned := (size + 15) / 8 * 8
    if rt_arena_suspend() != 0 || g_arena_scalars_ready == 0:
        return alloc_global(size, aligned, heap_start, heap_end)
    if alloc_uword(g_arena_scalars) == 0:
        return alloc_global(size, aligned, heap_start, heap_end)
    ai := rt_current_arena()
    if ai < 0:
        if rt_m_idx() != 0:
            return alloc_fail(size, -3, 0, 0)
        return alloc_global(size, aligned, heap_start, heap_end)

    slot : ., mut = cell_load(g_arena_slot, ai * 8)
    if slot < 0:
        // arena_new_sized could not obtain a first slot (pool limit). The
        // legacy body traps here instead of silently allocating a new one.
        return alloc_fail(size, -1, slot, 1024)
    max_size := cell_load(g_arena_scalars, 8)
    slot_base : ., mut = arena_slot_base(slot)
    // A static arena has a fixed peak recorded by arena_new_sized; bump within
    // the current slot and trap instead of requesting another slot.
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

    // Large objects get a dedicated mmap extent. The check stays after the
    // static branch: a static arena's peak is at most one slot, so a larger
    // request must trap exactly as the legacy body does.
    if aligned > 1048576:
        return alloc_arena_extent(size, aligned, ai)

    // Size-class path: map the aligned size to one of 25 small classes (or the
    // large class), carve class metadata from the current slot when empty, then
    // bump the class cursor. A full class is invalidated and the loop retries.
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
                    // Class metadata holds absolute addresses. Storing a
                    // slot-relative offset would alias when the arena moves
                    // to a different slot while this chunk is still live.
                    base = alloc_uword(slot_base) + slot_cur
                    cell_store(g_class_base, idx * 8, base)
                    cell_store(g_class_limit, idx * 8,
                               alloc_uword(slot_base) + max_size)
                    cell_store(g_class_cursor, idx * 8, 0)
                    cell_store(g_arena_slot_cursor, ai * 8, max_size)
            else:
                slot_cur := cell_load(g_arena_slot_cursor, ai * 8)
                newcur := slot_cur + 4096
                if newcur > max_size:
                    slot = arena_get_slot(ai, size)
                    slot_base = arena_slot_base(slot)
                else:
                    base = alloc_uword(slot_base) + slot_cur
                    cell_store(g_arena_slot_cursor, ai * 8, newcur)
                    cell_store(g_class_base, idx * 8, base)
                    cell_store(g_class_limit, idx * 8,
                               alloc_uword(slot_base) + newcur)
                    cell_store(g_class_cursor, idx * 8, 0)
        base = cell_load(g_class_base, idx * 8)
        cur := cell_load(g_class_cursor, idx * 8)
        limit := cell_load(g_class_limit, idx * 8)
        if base >= 0 && cur + aligned <= limit - base:
            cell_store(g_class_cursor, idx * 8, cur + aligned)
            p := alloc_ptr(base + cur)
            zero_alloc(p, aligned)
            cell_store(p, 0, size)
            return alloc_ptr(alloc_uword(p) + 8)
        if base >= 0:
            cell_store(g_class_base, idx * 8, -1)

    return alloc_ptr(0)
