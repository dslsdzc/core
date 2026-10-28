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
g_arena_slot_next : string, mut     // int[] — next slot in an arena chain
g_arena_slot_free : int, mut = -1
g_arena_slot_count : int, mut = 0
g_arena_pool_slots : int, mut = 0
g_class_base : string, mut          // int[] — class chunk start offset, [arena * K + class]
g_class_cursor : string, mut        // int[] — class chunk used bytes
g_class_limit : string, mut         // int[] — class chunk capacity
g_class_sizes : string, mut         // int[] — 25 class sizes, 1.25x steps

// Allocation-failure witness. Written before the runtime trap; a core dump or a
// debugger can read these four values.
g_alloc_fail_request : int, mut = 0
g_alloc_fail_class : int, mut = -1
g_alloc_fail_cursor : int, mut = 0
g_alloc_fail_limit : int, mut = 0

// Home slot for the spilled class-index value in the runtime allocator stub.
g_alloc_home_idx : int, mut = 0

fn _grow_arena_meta(needed: int):
    if needed < g_arena_cap:
        return
    nc : ., mut = g_arena_cap * 2
    if nc < 64:
        nc = 64
    if nc < needed:
        nc = needed + 64
    saved_arena := g_current_arena
    g_current_arena = -1
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
    g_current_arena = saved_arena

// ── Public API ──

fn arena_init(pool_size: int, arena_size: int), pub:
    // The backing pool outlives the caller's automatic function arena.
    // The 25 class slices are 4KB each, so a slot must hold at least 100KB.
    if arena_size < 131072:
        arena_size = 131072
    g_current_arena = -1
    g_arena_pool_data = alloc(pool_size)
    g_arena_max_size = arena_size
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
    g_arena_pool_slots = pool_size / arena_size
    g_arena_slot_next = alloc(g_arena_pool_slots * 8)
    si : ., mut = 0
    loop:
        if si >= g_arena_pool_slots:
            break
        cell_store(g_arena_slot_next, si * 8, -1)
        si = si + 1
    g_arena_slot_free = -1
    g_arena_slot_count = 0
    g_arena_free_list = -1
    g_arena_count = 0
    g_arena_cap = 0

fn arena_new_sized(peak: int) -> int, pub:
    if peak > g_arena_max_size:
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
        cell_store(g_arena_sizes, ai * 8, g_arena_max_size)
        cell_store(g_arena_static, ai * 8, 0)
    cell_store(g_arena_parents, ai * 8, -1)
    sl : ., mut = g_arena_slot_free
    if sl >= 0:
        g_arena_slot_free = cell_load(g_arena_slot_next, sl * 8)
    else:
        sl = g_arena_slot_count
        g_arena_slot_count = sl + 1
        if sl >= g_arena_pool_slots:
            sl = -1
    cell_store(g_arena_slot, ai * 8, sl)
    if sl >= 0:
        cell_store(g_arena_slot_next, sl * 8, -1)
    cell_store(g_arena_slot_cursor, ai * 8, 0)
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
    if g_current_arena >= 0:
        cell_store(g_arena_parents, ai * 8, g_current_arena)

    // Activate
    g_current_arena = ai
    return ai

fn arena_new() -> int, pub:
    return arena_new_sized(0)

fn arena_reset(ai: int), pub:
    if ai < 0 || ai >= g_arena_count:
        return

    // Save parent BEFORE free list overwrites g_arena_parents[ai]
    parent := cell_load(g_arena_parents, ai * 8)

    // Return every slot in the arena chain to the pool free list.
    sl : ., mut = cell_load(g_arena_slot, ai * 8)
    loop:
        if sl < 0:
            break
        nxt := cell_load(g_arena_slot_next, sl * 8)
        cell_store(g_arena_slot_next, sl * 8, g_arena_slot_free)
        g_arena_slot_free = sl
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

    // Restore parent
    if parent >= 0:
        g_current_arena = parent
    else:
        g_current_arena = -1

fn arena_avail(ai: int) -> int, pub:
    if ai < 0 || ai >= g_arena_count:
        return 0
    used := cell_load(g_arena_slot_cursor, ai * 8)
    return g_arena_max_size - used
