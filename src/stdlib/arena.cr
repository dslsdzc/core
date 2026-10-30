import io

// Arena memory model — per-subgraph bump allocator.
// Each subgraph (function/loop/for/unsafe) gets its own Arena.
// alloc() checks g_current_arena and uses the arena chunk when set.

// Arena metadata — dynamic arrays (no fixed limit, grows like g_df_nodes)
g_arena_cursors : string, mut     // int[] — bump cursor offset per arena
g_arena_sizes   : string, mut     // int[] — chunk capacity per arena
g_arena_parents : string, mut     // int[] — parent arena ID (for nesting restore)

g_arena_max_size : int, mut       // default chunk size per arena
g_arena_count : int, mut = 0      // total slots allocated
g_arena_cap : int, mut = 0        // metadata array capacity
// ── Internal: grow metadata arrays ──
// Shared arena state used by the runtime allocator and arena stdlib.
// These globals live with the arena library, not in the compiler implementation
// tree: user code cannot see them, while every arena function shares them.
g_current_arena : int, mut = -1
g_arena_pool_data : string, mut
g_arena_free_list : int, mut = -1

// Size-class sub-regions (spec: docs/superpowers/specs/2026-10-28-arena-size-classes.md).
// Each arena owns ARENA_CLASS_COUNT entries: 25 size classes plus the large-object
// path. base/cursor/limit are offsets inside the class chunk; -1 means "no chunk".
ARENA_CLASS_COUNT : int = 26

g_arena_slot_cursor : string, mut   // int[] — bytes carved from the current slot per arena
g_arena_slot : string, mut          // int[] — current slot id per arena
g_arena_static : string, mut        // int[] — 1 when the arena uses a static peak
g_arena_live : string, mut          // int[] — 1 while the arena id is allocated
g_arena_scalars : string, mut       // raw scalar cells shared with the stub
g_arena_scalars_ready : int, mut = 0 // 1 after the scalar buffer exists
g_arena_suspend : int, mut = 0     // 1 while arena metadata is being rebuilt
// V2.4 deployment switch: zero each slot's used prefix before returning it to
// the pool. Default off; set by arena_set_zero_on_reset or --arena-zero-on-reset.
g_arena_zero_on_reset : int, mut = 0
g_arena_large_head : string, mut    // string[] — mmap extent list per arena
g_arena_large_count : string, mut   // int[] — extent count per arena
g_arena_slot_next : string, mut     // int[] — next slot in an arena chain
g_arena_slot_free : int, mut = -1
g_arena_slot_count : int, mut = 0
g_arena_pool_slots : int, mut = 0
g_segment_base : string, mut        // string[] — 1MB pool segments
g_segment_count : int, mut = 0
g_arena_pool_limit : int, mut = 1073741824
g_segment_cap : int, mut = 0
g_slot_next_cap : int, mut = 0
g_class_base : string, mut          // int[] — class chunk absolute address, [arena * K + class]
g_class_cursor : string, mut        // int[] — class chunk used bytes
g_class_limit : string, mut         // int[] — class chunk capacity
g_class_sizes : string, mut         // int[] — 25 class sizes, 1.25x steps
g_class_lookup : string, mut        // int[] — aligned/16 -> class, 256 entries

// Allocation-failure witness. Written before the runtime trap; a core dump or a
// debugger can read these four values.
g_alloc_fail_request : int, mut = 0
g_alloc_fail_class : int, mut = -1
g_alloc_fail_cursor : int, mut = 0
g_alloc_fail_limit : int, mut = 0

// Home slot for the spilled class-index value in the runtime allocator stub.
g_alloc_home_idx : int, mut = 0

// Shared scalar cells. Both the allocator stub and the library see raw machine
// words; the getter uses load64 and the setter uses cell_store.
fn arena_scalar_get(off: int) -> int:
    // load64 keeps the access raw: cell_load converts the offset through the
    // big-int runtime, which can allocate and re-enter the arena.
    if off == 0:
        return load64(g_arena_scalars, 0)
    if off == 8:
        return load64(g_arena_scalars, 8)
    if off == 16:
        return load64(g_arena_scalars, 16)
    if off == 24:
        return load64(g_arena_scalars, 24)
    if off == 32:
        return load64(g_arena_scalars, 32)
    if off == 40:
        return load64(g_arena_scalars, 40)
    return 0

fn arena_scalar_set(off: int, val: int):
    if off == 0:
        cell_store(g_arena_scalars, 0, val)
        return
    if off == 8:
        cell_store(g_arena_scalars, 8, val)
        return
    if off == 16:
        cell_store(g_arena_scalars, 16, val)
        return
    if off == 24:
        cell_store(g_arena_scalars, 24, val)
        return
    if off == 32:
        cell_store(g_arena_scalars, 32, val)
        return
    if off == 40:
        cell_store(g_arena_scalars, 40, val)
        return

// Keep the legacy current-arena global in sync for programs that read it
// directly (the test suite redeclares it to check activation).
fn arena_set_current(val: int):
    arena_scalar_set(0, val)
    g_current_arena = val

fn arena_set_zero_on_reset(v: int), pub:
    g_arena_zero_on_reset = v

fn _arena_zero_reset_slots(ai: int):
    if g_arena_zero_on_reset == 0:
        return
    slot : ., mut = cell_load(g_arena_slot, ai * 8)
    first : ., mut = 1
    loop:
        if slot < 0:
            return
        base := _arena_slot_base(slot)
        if _arena_word(base) != 0:
            used : ., mut = 1048576
            if first != 0:
                if cell_load(g_arena_static, ai * 8) != 0:
                    used = cell_load(g_arena_cursors, ai * 8)
                else:
                    used = cell_load(g_arena_slot_cursor, ai * 8)
                if used < 0:
                    used = 0
                if used > 1048576:
                    used = 1048576
                first = 0
            if used > 0:
                _memzero(base, used)
        slot = cell_load(g_arena_slot_next, slot * 8)

fn _grow_arena_meta(needed: int):
    if needed < g_arena_cap:
        return
    nc : ., mut = g_arena_cap * 2
    if nc < 64:
        nc = 64
    if nc < needed:
        nc = needed + 64
    saved_arena := arena_scalar_get(0)
    arena_set_current(-1)
    // cursors
    nb := alloc(nc * 8)
    zi : ., mut = 0
    loop:
        if zi >= nc * 8:
            break
        store8(nb, zi, 0)
        zi = zi + 1
    if g_arena_cap > 0:
        _dyncpy(g_arena_cursors, g_arena_cap * 8, nb)
    g_arena_cursors = nb
    // sizes
    nb2 := alloc(nc * 8)
    zi = 0
    loop:
        if zi >= nc * 8:
            break
        store8(nb2, zi, 0)
        zi = zi + 1
    if g_arena_cap > 0:
        _dyncpy(g_arena_sizes, g_arena_cap * 8, nb2)
    g_arena_sizes = nb2
    // parents
    nb3 := alloc(nc * 8)
    zi = 0
    loop:
        if zi >= nc * 8:
            break
        store8(nb3, zi, 0)
        zi = zi + 1
    if g_arena_cap > 0:
        _dyncpy(g_arena_parents, g_arena_cap * 8, nb3)
    g_arena_parents = nb3
    // slot cursor
    nb4 := alloc(nc * 8)
    zi = 0
    loop:
        if zi >= nc * 8:
            break
        store8(nb4, zi, 0)
        zi = zi + 1
    if g_arena_cap > 0:
        _dyncpy(g_arena_slot_cursor, g_arena_cap * 8, nb4)
    g_arena_slot_cursor = nb4
    // current slot id
    nb4b := alloc(nc * 8)
    zi = 0
    loop:
        if zi >= nc * 8:
            break
        store8(nb4b, zi, 0)
        zi = zi + 1
    if g_arena_cap > 0:
        _dyncpy(g_arena_slot, g_arena_cap * 8, nb4b)
    g_arena_slot = nb4b
    // static peak flag
    nb4c := alloc(nc * 8)
    zi = 0
    loop:
        if zi >= nc * 8:
            break
        store8(nb4c, zi, 0)
        zi = zi + 1
    if g_arena_cap > 0:
        _dyncpy(g_arena_static, g_arena_cap * 8, nb4c)
    g_arena_static = nb4c
    nb4c2 := alloc(nc * 8)
    zi = 0
    loop:
        if zi >= nc * 8:
            break
        store8(nb4c2, zi, 0)
        zi = zi + 1
    if g_arena_cap > 0:
        _dyncpy(g_arena_live, g_arena_cap * 8, nb4c2)
    g_arena_live = nb4c2
    nb4d := alloc(nc * 8)
    zi = 0
    loop:
        if zi >= nc * 8:
            break
        store8(nb4d, zi, 0)
        zi = zi + 1
    if g_arena_cap > 0:
        _dyncpy(g_arena_large_head, g_arena_cap * 8, nb4d)
    g_arena_large_head = nb4d
    nb4e := alloc(nc * 8)
    zi = 0
    loop:
        if zi >= nc * 8:
            break
        store8(nb4e, zi, 0)
        zi = zi + 1
    if g_arena_cap > 0:
        _dyncpy(g_arena_large_count, g_arena_cap * 8, nb4e)
    g_arena_large_count = nb4e
    // class base / cursor / limit
    cn := nc * ARENA_CLASS_COUNT * 8
    nb5 := alloc(cn)
    zi = 0
    loop:
        if zi >= cn:
            break
        store8(nb5, zi, 0)
        zi = zi + 1
    if g_arena_cap > 0:
        _dyncpy(g_class_base, g_arena_cap * ARENA_CLASS_COUNT * 8, nb5)
    g_class_base = nb5
    nb6 := alloc(cn)
    zi = 0
    loop:
        if zi >= cn:
            break
        store8(nb6, zi, 0)
        zi = zi + 1
    if g_arena_cap > 0:
        _dyncpy(g_class_cursor, g_arena_cap * ARENA_CLASS_COUNT * 8, nb6)
    g_class_cursor = nb6
    nb7 := alloc(cn)
    zi = 0
    loop:
        if zi >= cn:
            break
        store8(nb7, zi, 0)
        zi = zi + 1
    if g_arena_cap > 0:
        _dyncpy(g_class_limit, g_arena_cap * ARENA_CLASS_COUNT * 8, nb7)
    g_class_limit = nb7
    g_arena_cap = nc
    arena_set_current(saved_arena)

// ── Public API ──

fn arena_init(pool_size: int, arena_size: int), pub:
    // Metadata rebuilds allocate tagged big-int boxes. Those must go to the
    // global heap, never into a half-built arena.
    g_arena_suspend = 1
    // The backing pool outlives the caller's automatic function arena.
    // The 25 class slices are 4KB each, so a slot must hold at least 100KB.
    if arena_size < 131072:
        arena_size = 131072
    // Retire the active arena from before this init. main's automatic function
    // arena is created before user code runs, so it can be live here. Resetting
    // the current arena is enough: the compiler creates at most one automatic
    // arena per active function.
    prev_arena : ., mut = 0
    have_scalars := g_arena_scalars_ready
    if have_scalars != 0:
        prev_arena = arena_scalar_get(0)
        arena_set_current(-1)
    // alloc() returns a zero-filled block. Park the current arena on -1
    // before any further allocation: tagged arithmetic in the rest of this
    // function can allocate big-int boxes, and those must not enter the arena
    // before its metadata arrays exist.
    g_arena_scalars_ready = 0
    g_arena_scalars = alloc(64)
    arena_set_current(-1)
    if have_scalars != 0 && prev_arena >= 0:
        arena_reset(prev_arena)
    g_arena_pool_limit = pool_size
    // A zero limit means "no limit"; only positive values below one segment
    // are raised to the minimum segment size.
    if g_arena_pool_limit > 0 && g_arena_pool_limit < 67108864:
        g_arena_pool_limit = 67108864
    // Pool segments are 64MB each and hold sixty-four 1MB slots.
    arena_size = 1048576
    arena_scalar_set(8, arena_size)
    g_segment_base = alloc(256 * 8)
    g_segment_cap = 256
    arena_scalar_set(24, 1)
    seg0 := alloc(67108864)
    g_arena_pool_data = seg0
    store_str_ptr(g_segment_base, 0, seg0)
    g_class_sizes = alloc(25 * 8)
    cell_store(g_class_sizes, 0, 16)
    cell_store(g_class_sizes, 8, 20)
    cell_store(g_class_sizes, 16, 25)
    cell_store(g_class_sizes, 24, 31)
    cell_store(g_class_sizes, 32, 39)
    cell_store(g_class_sizes, 40, 49)
    cell_store(g_class_sizes, 48, 61)
    cell_store(g_class_sizes, 56, 76)
    cell_store(g_class_sizes, 64, 95)
    cell_store(g_class_sizes, 72, 119)
    cell_store(g_class_sizes, 80, 149)
    cell_store(g_class_sizes, 88, 186)
    cell_store(g_class_sizes, 96, 232)
    cell_store(g_class_sizes, 104, 290)
    cell_store(g_class_sizes, 112, 362)
    cell_store(g_class_sizes, 120, 452)
    cell_store(g_class_sizes, 128, 565)
    cell_store(g_class_sizes, 136, 706)
    cell_store(g_class_sizes, 144, 882)
    cell_store(g_class_sizes, 152, 1102)
    cell_store(g_class_sizes, 160, 1377)
    cell_store(g_class_sizes, 168, 1721)
    cell_store(g_class_sizes, 176, 2151)
    cell_store(g_class_sizes, 184, 2689)
    cell_store(g_class_sizes, 192, 3361)
    arena_scalar_set(16, 64)
    g_arena_slot_next = alloc(2048 * 8)
    g_slot_next_cap = 2048
    si : ., mut = 0
    loop:
        if si >= arena_scalar_get(16):
            break
        cell_store(g_arena_slot_next, si * 8, -1)
        si = si + 1
    arena_scalar_set(40, -1)
    arena_scalar_set(32, 0)
    g_class_lookup = alloc(256 * 8)
    lb : ., mut = 0
    loop:
        if lb >= 256:
            break
        aligned_b := lb * 16
        lc : ., mut = -1
        lci : ., mut = 0
        loop:
            if lci >= 25:
                break
            if aligned_b <= cell_load(g_class_sizes, lci * 8):
                lc = lci
                break
            lci = lci + 1
        if lc < 0:
            lc = 25
        cell_store(g_class_lookup, lb * 8, lc)
        lb = lb + 1
    g_arena_free_list = -1
    g_arena_count = 0
    g_arena_scalars_ready = 1
    g_arena_suspend = 0
    // Keep g_arena_cap: the metadata arrays are still allocated and all arenas
    // were retired above. Dropping the capacity would reallocate them zeroed and
    // leave stale ids (such as main's automatic arena) pointing at zero cells.

fn _arena_copy_cells(src: string, nbytes: int, dst: string):
    i : ., mut = 0
    loop:
        if i >= nbytes:
            break
        cell_store(dst, i, cell_load(src, i))
        i = i + 8

fn arena_grow_pool(), pub:
    if g_arena_pool_limit > 0 && (arena_scalar_get(24) + 1) * 67108864 > g_arena_pool_limit:
        println("arena: pool limit exceeded")
        return
    saved := arena_scalar_get(0)
    arena_set_current(-1)
    if arena_scalar_get(24) >= g_segment_cap:
        nc := g_segment_cap * 2
        nb := alloc(nc * 8)
        _arena_copy_cells(g_segment_base, g_segment_cap * 8, nb)
        g_segment_base = nb
        g_segment_cap = nc
    if (arena_scalar_get(24) + 1) * 64 > g_slot_next_cap:
        nc2 := g_slot_next_cap * 2
        nb2 := alloc(nc2 * 8)
        _arena_copy_cells(g_arena_slot_next, g_slot_next_cap * 8, nb2)
        g_arena_slot_next = nb2
        g_slot_next_cap = nc2
    arena_set_current(-1)
    seg := alloc(67108864)
    store_str_ptr(g_segment_base, arena_scalar_get(24) * 8, seg)
    arena_scalar_set(24, arena_scalar_get(24) + 1)
    arena_scalar_set(16, arena_scalar_get(16) + 64)
    arena_set_current(saved)

fn arena_new_sized(peak: int) -> int, pub:
    if peak > arena_scalar_get(8):
        peak = 0
    ai : ., mut = -1

    // Try free list first
    if g_arena_free_list >= 0:
        ai = g_arena_free_list
        g_arena_free_list = cell_load(g_arena_parents, ai * 8)  // pop head

    if ai < 0:
        // Allocate new slot (grow metadata arrays)
        need := g_arena_count + 1
        _grow_arena_meta(need)
        ai = g_arena_count
        g_arena_count = need

    // Initialize slot
    cell_store(g_arena_cursors, ai * 8, 0)
    if peak > 0:
        cell_store(g_arena_sizes, ai * 8, peak)
        cell_store(g_arena_static, ai * 8, 1)
    else:
        cell_store(g_arena_sizes, ai * 8, arena_scalar_get(8))
        cell_store(g_arena_static, ai * 8, 0)
    cell_store(g_arena_parents, ai * 8, -1)
    cell_store(g_arena_live, ai * 8, 1)
    sl : ., mut = arena_scalar_get(40)
    if sl >= 0:
        arena_scalar_set(40, cell_load(g_arena_slot_next, sl * 8))
    else:
        sl = arena_scalar_get(32)
        arena_scalar_set(32, sl + 1)
        if sl >= arena_scalar_get(16):
            arena_grow_pool()
        if sl >= arena_scalar_get(16):
            sl = -1
    cell_store(g_arena_slot, ai * 8, sl)
    if sl >= 0:
        cell_store(g_arena_slot_next, sl * 8, -1)
    cell_store(g_arena_slot_cursor, ai * 8, 0)
    cell_store(g_arena_large_head, ai * 8, -1)
    cell_store(g_arena_large_count, ai * 8, 0)
    // No class chunk is attached until the first allocation of that class.
    ci : ., mut = 0
    loop:
        if ci >= ARENA_CLASS_COUNT:
            break
        cell_store(g_class_base, (ai * ARENA_CLASS_COUNT + ci) * 8, -1)
        cell_store(g_class_cursor, (ai * ARENA_CLASS_COUNT + ci) * 8, 0)
        cell_store(g_class_limit, (ai * ARENA_CLASS_COUNT + ci) * 8, 0)
        ci = ci + 1

    // Set parent = previous current arena
    if arena_scalar_get(0) >= 0:
        cell_store(g_arena_parents, ai * 8, arena_scalar_get(0))

    // Activate
    arena_set_current(ai)
    return ai

fn arena_new() -> int, pub:
    return arena_new_sized(0)

fn arena_reset(ai: int), pub:
    if ai < 0 || ai >= g_arena_count:
        return
    // A second reset must not push the same id into the free list again.
    if cell_load(g_arena_live, ai * 8) == 0:
        return
    cell_store(g_arena_live, ai * 8, 0)
    g_arena_suspend = 1

    // Save parent BEFORE free list overwrites g_arena_parents[ai]
    parent := cell_load(g_arena_parents, ai * 8)

    // Unmap dedicated large-object extents. The count is a tagged int read
    // through cell_load; the chain values are raw string pointers and are never
    // compared as integers.
    ln : ., mut = cell_load(g_arena_large_count, ai * 8)
    loop:
        if ln <= 0:
            break
        lp := load_str_ptr(g_arena_large_head, ai * 8)
        lnxt := load_str_ptr(lp, 0)
        lsz := cell_load(lp, 8)
        r1 := syscall3(11, lp, lsz, 0)
        store_str_ptr(g_arena_large_head, ai * 8, lnxt)
        ln = ln - 1
    cell_store(g_arena_large_count, ai * 8, 0)
    cell_store(g_arena_large_head, ai * 8, -1)

    _arena_zero_reset_slots(ai)

    // Return every slot in the arena chain to the pool free list.
    sl : ., mut = cell_load(g_arena_slot, ai * 8)
    loop:
        if sl < 0:
            break
        nxt := cell_load(g_arena_slot_next, sl * 8)
        cell_store(g_arena_slot_next, sl * 8, arena_scalar_get(40))
        arena_scalar_set(40, sl)
        sl = nxt
    cell_store(g_arena_slot, ai * 8, -1)
    cell_store(g_arena_slot_cursor, ai * 8, 0)
    ci : ., mut = 0
    loop:
        if ci >= ARENA_CLASS_COUNT:
            break
        cell_store(g_class_base, (ai * ARENA_CLASS_COUNT + ci) * 8, -1)
        cell_store(g_class_cursor, (ai * ARENA_CLASS_COUNT + ci) * 8, 0)
        cell_store(g_class_limit, (ai * ARENA_CLASS_COUNT + ci) * 8, 0)
        ci = ci + 1

    // Push to free list
    cell_store(g_arena_parents, ai * 8, g_arena_free_list)
    g_arena_free_list = ai

    // Restore parent. Keep the allocator suspended until the scalar write is
    // complete: cell_store itself can allocate a tagged box.
    if parent >= 0:
        arena_set_current(parent)
    else:
        arena_set_current(-1)
    g_arena_suspend = 0

// Early clear (V2.1): reset the current slot's cursor, size-class metadata and
// dedicated large extents, but keep the arena id live and current. Older slots
// in the chain stay attached until the final arena_reset; the current slot is
// the hot path and is reused immediately.
fn arena_clear(ai: int), pub:
    if ai < 0 || ai >= g_arena_count:
        return
    if cell_load(g_arena_live, ai * 8) == 0:
        return
    g_arena_suspend = 1

    ln : ., mut = cell_load(g_arena_large_count, ai * 8)
    loop:
        if ln <= 0:
            break
        lp := load_str_ptr(g_arena_large_head, ai * 8)
        lnxt := load_str_ptr(lp, 0)
        lsz := cell_load(lp, 8)
        r1 := syscall3(11, lp, lsz, 0)
        store_str_ptr(g_arena_large_head, ai * 8, lnxt)
        ln = ln - 1
    cell_store(g_arena_large_count, ai * 8, 0)
    cell_store(g_arena_large_head, ai * 8, -1)

    cell_store(g_arena_cursors, ai * 8, 0)
    cell_store(g_arena_slot_cursor, ai * 8, 0)
    ci : ., mut = 0
    loop:
        if ci >= ARENA_CLASS_COUNT:
            break
        cell_store(g_class_base, (ai * ARENA_CLASS_COUNT + ci) * 8, -1)
        cell_store(g_class_cursor, (ai * ARENA_CLASS_COUNT + ci) * 8, 0)
        cell_store(g_class_limit, (ai * ARENA_CLASS_COUNT + ci) * 8, 0)
        ci = ci + 1
    g_arena_suspend = 0

// ── Interpreter allocation path ──
// The ELF backend uses the precompiled raw blob. `corec run` interprets this
// Core function instead, so both paths share the arena metadata and the same
// class/slot rules. The interpreter's `alloc` builtin calls this function only
// while an arena is active; metadata and >1MiB extents go to the host heap.

fn _arena_ptr(v: int) -> string:
    p : ., mut = ""
    unsafe:
        p = @str_of(v)
    return p

fn _arena_word(s: string) -> int:
    v : ., mut = 0
    unsafe:
        v = @ptr_of(s)
    return v

fn _arena_slot_base(slot: int) -> string:
    seg := load_str_ptr(g_segment_base, (slot / 64) * 8)
    if _arena_word(seg) == 0:
        return _arena_ptr(0)
    return _arena_ptr(_arena_word(seg) + (slot % 64) * 1048576)

// _memzero fills nbytes at buf with zero. The interpreter executes this loop
// in compiled code (the per-node path is too slow for 1MiB slots); native
// code compiles the loop here.
fn _memzero(buf: string, nbytes: int):
    i : ., mut = 0
    loop:
        if i >= nbytes:
            break
        store8(buf, i, 0)
        i = i + 1

fn _arena_zero(p: string, n: int):
    _memzero(p, n)

fn _arena_get_slot(ai: int, size: int) -> int:
    sf := arena_scalar_get(40)
    slot : ., mut = -1
    if sf >= 0:
        slot = sf
        arena_scalar_set(40, cell_load(g_arena_slot_next, sf * 8))
    else:
        count : ., mut = arena_scalar_get(32)
        pool : ., mut = arena_scalar_get(16)
        if count >= pool:
            arena_grow_pool()
            count = arena_scalar_get(32)
            pool = arena_scalar_get(16)
        if count >= pool:
            return -1
        slot = count
        arena_scalar_set(32, count + 1)
    old := cell_load(g_arena_slot, ai * 8)
    if old >= 0:
        cell_store(g_arena_slot_next, slot * 8, old)
    else:
        cell_store(g_arena_slot_next, slot * 8, -1)
    cell_store(g_arena_slot, ai * 8, slot)
    cell_store(g_arena_slot_cursor, ai * 8, 0)
    return slot

fn _arena_alloc_extent(size: int, aligned: int, ai: int) -> string:
    base := alloc(aligned + 16)
    if _arena_word(base) == 0:
        return _arena_ptr(0)
    total := aligned + 16
    head := load_str_ptr(g_arena_large_head, ai * 8)
    store_str_ptr(base, 0, head)
    cell_store(base, 8, total)
    cell_store(base, 16, size)
    store_str_ptr(g_arena_large_head, ai * 8, base)
    cell_store(g_arena_large_count, ai * 8,
               cell_load(g_arena_large_count, ai * 8) + 1)
    return _arena_ptr(_arena_word(base) + 24)

fn arena_alloc(size: int) -> string:
    if size < 0:
        return _arena_ptr(0)
    if size > 1099511627776:
        return _arena_ptr(0)
    if g_arena_suspend != 0 || g_arena_scalars_ready == 0:
        return _arena_ptr(0)
    if _arena_word(g_arena_scalars) == 0:
        return _arena_ptr(0)
    ai := arena_scalar_get(0)
    if ai < 0:
        return _arena_ptr(0)
    aligned := (size + 15) / 8 * 8
    slot : ., mut = cell_load(g_arena_slot, ai * 8)
    if slot < 0:
        return _arena_ptr(0)
    slot_base : ., mut = _arena_slot_base(slot)
    if _arena_word(slot_base) == 0:
        return _arena_ptr(0)
    if cell_load(g_arena_static, ai * 8) != 0:
        cur := cell_load(g_arena_cursors, ai * 8)
        limit := cell_load(g_arena_sizes, ai * 8)
        if cur + aligned > limit:
            return _arena_ptr(0)
        cell_store(g_arena_cursors, ai * 8, cur + aligned)
        p := _arena_ptr(_arena_word(slot_base) + cur)
        _arena_zero(p, aligned)
        cell_store(p, 0, size)
        return _arena_ptr(_arena_word(p) + 8)

    if aligned > 1048576:
        return _arena_alloc_extent(size, aligned, ai)

    max_size := arena_scalar_get(8)
    loop:
        lookup := aligned / 16
        cls : ., mut = 25
        if lookup <= 255:
            cls = cell_load(g_class_lookup, lookup * 8)
        idx := ai * 26 + cls
        base : ., mut = cell_load(g_class_base, idx * 8)
        if base < 0:
            if cls == 25:
                slot_cur := cell_load(g_arena_slot_cursor, ai * 8)
                if aligned > max_size - slot_cur:
                    slot = _arena_get_slot(ai, size)
                    if slot < 0:
                        return _arena_ptr(0)
                    slot_base = _arena_slot_base(slot)
                else:
                    base = _arena_word(slot_base) + slot_cur
                    cell_store(g_class_base, idx * 8, base)
                    cell_store(g_class_limit, idx * 8,
                               _arena_word(slot_base) + max_size)
                    cell_store(g_class_cursor, idx * 8, 0)
                    cell_store(g_arena_slot_cursor, ai * 8, max_size)
            else:
                slot_cur := cell_load(g_arena_slot_cursor, ai * 8)
                newcur := slot_cur + 4096
                if newcur > max_size:
                    slot = _arena_get_slot(ai, size)
                    if slot < 0:
                        return _arena_ptr(0)
                    slot_base = _arena_slot_base(slot)
                else:
                    base = _arena_word(slot_base) + slot_cur
                    cell_store(g_arena_slot_cursor, ai * 8, newcur)
                    cell_store(g_class_base, idx * 8, base)
                    cell_store(g_class_limit, idx * 8,
                               _arena_word(slot_base) + newcur)
                    cell_store(g_class_cursor, idx * 8, 0)
        base = cell_load(g_class_base, idx * 8)
        cur := cell_load(g_class_cursor, idx * 8)
        limit := cell_load(g_class_limit, idx * 8)
        if base >= 0 && cur + aligned <= limit - base:
            cell_store(g_class_cursor, idx * 8, cur + aligned)
            p := _arena_ptr(base + cur)
            _arena_zero(p, aligned)
            cell_store(p, 0, size)
            return _arena_ptr(_arena_word(p) + 8)
        if base >= 0:
            cell_store(g_class_base, idx * 8, -1)

    return _arena_ptr(0)

fn arena_avail(ai: int) -> int, pub:
    if ai < 0 || ai >= g_arena_count:
        return 0
    used := cell_load(g_arena_slot_cursor, ai * 8)
    return arena_scalar_get(8) - used
