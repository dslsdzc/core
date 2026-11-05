import io

// Arena memory model — per-subgraph bump allocator.
// Each subgraph (function/loop/for/unsafe) gets its own Arena.
// alloc() checks g_current_arena and uses the arena chunk when set.

// Arena metadata — dynamic arrays (no fixed limit, grows like g_df_nodes)
g_arena_cursors : string, mut     // int[] — bump cursor offset per arena
g_arena_sizes   : string, mut     // int[] — chunk capacity per arena
g_arena_parents : string, mut     // int[] — parent arena ID (for nesting restore)

g_arena_max_size : int, mut       // default chunk size per arena
g_arena_count : int, mut = 0      // total capacity (validation)
g_arena_cap : int, mut = 0        // metadata array capacity

// 0A per-M partition. Gs never migrate, so every arena operation for a G
// happens on its home M. Metadata arrays are preallocated; per-M free lists and
// high-water counters are owner-private.
//
// SLOTS_PER_M/SEGMENTS_PER_M must match the slot math compiled into the
// allocator blob (src/runtime/alloc_body.cr: slot = m * 256 + count, 64 slots
// per 1MiB segment). A mismatch aliases two Ms onto the same slot: with
// SLOTS_PER_M = 1024 here, M1's slot 256 landed in M0's segment 4.
ARENA_PER_M : int = 1024
SLOTS_PER_M : int = 256
SEGMENTS_PER_M : int = 4

g_arena_m_count : int, mut = 1
// Dedicated arena for runtime/shared metadata (scheduler arrays, channel
// regions). It lives in the last M partition, which sched_init_n reserves by
// initializing n+1 partitions. Only shared_alloc touches it, and callers
// serialize on the conc lock, so no worker ever races another M's slot pools.
g_arena_shared_arena : int, mut = -1
g_arena_count_m : string, mut
g_arena_free_list_m : string, mut
g_slot_count_m : string, mut
g_slot_free_m : string, mut
g_segment_count_m : string, mut
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

fn arena_pool_limit() -> int, pub:
    return g_arena_pool_limit
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
    rt_set_current_arena(val)
    g_current_arena = val
    // The interpreter and the allocator blob read the current arena from the
    // raw scalar slot; keep it in lockstep with TLS and the legacy global.
    if g_arena_scalars_ready != 0:
        arena_scalar_set(0, val)

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

// Compiler builtins: intercepted at the call site and lowered to raw cell
// load/store + g_current_arena. Calling these indirectly is not supported; the
// fallback bodies exist so the type checker resolves the names.
fn arena_current_unchecked() -> int, pub:
    return arena_scalar_get(0)

fn arena_set_current_unchecked(v: int), pub:
    arena_set_current(v)

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

// 0A: preallocate one metadata partition per M. Gs are pinned to their home
// M, so no two threads write the same arena/slot/free-list cell.
fn arena_init_m(pool_size: int, arena_size: int, m_count: int), pub:
    if m_count < 1:
        m_count = 1
    g_arena_suspend = 1
    if arena_size < 131072:
        arena_size = 131072
    prev : ., mut = -1
    if g_arena_scalars_ready != 0:
        prev = arena_scalar_get(0)
    arena_set_current(-1)
    g_arena_scalars_ready = 0
    g_arena_shared_arena = -1
    g_arena_scalars = alloc(64)
    g_arena_m_count = m_count
    total := m_count * ARENA_PER_M
    g_arena_cursors = alloc(total * 8)
    g_arena_sizes = alloc(total * 8)
    g_arena_parents = alloc(total * 8)
    g_arena_slot = alloc(total * 8)
    g_arena_slot_cursor = alloc(total * 8)
    g_arena_static = alloc(total * 8)
    g_arena_live = alloc(total * 8)
    g_arena_large_head = alloc(total * 8)
    g_arena_large_count = alloc(total * 8)
    g_class_base = alloc(total * ARENA_CLASS_COUNT * 8)
    g_class_cursor = alloc(total * ARENA_CLASS_COUNT * 8)
    g_class_limit = alloc(total * ARENA_CLASS_COUNT * 8)
    g_arena_slot_next = alloc(m_count * SLOTS_PER_M * 8)
    g_segment_base = alloc(m_count * SEGMENTS_PER_M * 8)
    g_arena_count_m = alloc(m_count * 8)
    g_arena_free_list_m = alloc(m_count * 8)
    g_slot_count_m = alloc(m_count * 8)
    g_slot_free_m = alloc(m_count * 8)
    g_segment_count_m = alloc(m_count * 8)

    i : ., mut = 0
    loop:
        if i >= total:
            break
        cell_store(g_arena_slot, i * 8, -1)
        cell_store(g_arena_large_head, i * 8, -1)
        i = i + 1
    i = 0
    loop:
        if i >= m_count * SLOTS_PER_M:
            break
        cell_store(g_arena_slot_next, i * 8, -1)
        i = i + 1
    i = 0
    loop:
        if i >= total * ARENA_CLASS_COUNT:
            break
        cell_store(g_class_base, i * 8, -1)
        i = i + 1
    mi : ., mut = 0
    loop:
        if mi >= m_count:
            break
        cell_store(g_arena_count_m, mi * 8, 0)
        cell_store(g_arena_free_list_m, mi * 8, -1)
        cell_store(g_slot_count_m, mi * 8, 0)
        cell_store(g_slot_free_m, mi * 8, -1)
        seg := mi * SEGMENTS_PER_M
        cell_store(g_segment_count_m, mi * 8, seg)
        p := syscall6(9, 0, 67108864, 3, 34, -1, 0)
        ps : ., mut = ""
        if p > 0:
            unsafe:
                ps = @str_of(p)
        if _arena_word(ps) == 0:
            // The interpreter maps syscall6 to 0; use the host heap there.
            ps = alloc(67108864)
        if _arena_word(ps) != 0:
            store_str_ptr(g_segment_base, seg * 8, ps)
            cell_store(g_segment_count_m, mi * 8, seg + 1)
        mi = mi + 1

    g_arena_pool_limit = pool_size
    if g_arena_pool_limit > 0 && g_arena_pool_limit < 67108864:
        g_arena_pool_limit = 67108864
    arena_size = 1048576
    arena_scalar_set(8, arena_size)

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

    g_arena_cap = total
    g_arena_count = total
    g_arena_scalars_ready = 1
    g_arena_suspend = 0
    arena_set_current(prev)

fn arena_init(pool_size: int, arena_size: int), pub:
    arena_init_m(pool_size, arena_size, 1)

fn arena_ensure_init(), pub:
    if g_arena_scalars_ready == 0:
        arena_init(0, 1048576)

// Shared metadata arena. arena_init_m(n+1) reserves the last partition for it;
// with a single partition it falls back to partition 0 (single-threaded use).
fn arena_shared_m() -> int:
    m : ., mut = g_arena_m_count - 1
    if m < 0:
        m = 0
    return m

fn arena_shared_init(), pub:
    if g_arena_shared_arena >= 0:
        return
    saved_m := rt_m_idx()
    saved := rt_current_arena()
    rt_set_m_idx(arena_shared_m())
    rt_set_current_arena(-1)
    aid := arena_new()
    rt_set_current_arena(saved)
    rt_set_m_idx(saved_m)
    if aid >= 0:
        g_arena_shared_arena = aid

// Caller must serialize concurrent calls (the conc lock does). The temporary
// m_idx switch makes the allocator use the reserved partition's slot pools
// instead of the calling worker's.
fn arena_shared_alloc(size: int) -> string, pub:
    saved_m := rt_m_idx()
    saved := rt_current_arena()
    if g_arena_shared_arena < 0:
        rt_set_current_arena(-1)
        p0 := alloc(size)
        rt_set_current_arena(saved)
        return p0
    rt_set_m_idx(arena_shared_m())
    rt_set_current_arena(g_arena_shared_arena)
    p := alloc(size)
    rt_set_current_arena(saved)
    rt_set_m_idx(saved_m)
    return p

fn _arena_copy_cells(src: string, nbytes: int, dst: string):
    i : ., mut = 0
    loop:
        if i >= nbytes:
            break
        cell_store(dst, i, cell_load(src, i))
        i = i + 8

fn arena_grow_pool_m(m: int), pub:
    if m < 0:
        m = 0
    seg := cell_load(g_segment_count_m, m * 8)
    if seg >= (m + 1) * SEGMENTS_PER_M:
        return
    local_seg := seg - m * SEGMENTS_PER_M
    if g_arena_pool_limit > 0 && (local_seg + 1) * 67108864 > g_arena_pool_limit:
        println_str("arena: pool limit exceeded")
        return
    saved := arena_scalar_get(0)
    arena_set_current(-1)
    p := syscall6(9, 0, 67108864, 3, 34, -1, 0)
    ps : ., mut = ""
    if p > 0:
        unsafe:
            ps = @str_of(p)
    if _arena_word(ps) == 0:
        ps = alloc(67108864)
    if _arena_word(ps) == 0:
        arena_set_current(saved)
        return
    store_str_ptr(g_segment_base, seg * 8, ps)
    cell_store(g_segment_count_m, m * 8, seg + 1)
    arena_set_current(saved)

fn arena_grow_pool(), pub:
    arena_grow_pool_m(rt_m_idx())

fn arena_new_sized(peak: int) -> int, pub:
    if peak > arena_scalar_get(8):
        peak = 0
    m : ., mut = rt_m_idx()
    if m < 0:
        m = 0
    ai : ., mut = -1
    free := cell_load(g_arena_free_list_m, m * 8)
    if free >= 0:
        ai = free
        cell_store(g_arena_free_list_m, m * 8, cell_load(g_arena_parents, ai * 8))
    else:
        local := cell_load(g_arena_count_m, m * 8)
        if local >= ARENA_PER_M:
            return -1
        ai = m * ARENA_PER_M + local
        cell_store(g_arena_count_m, m * 8, local + 1)

    cell_store(g_arena_cursors, ai * 8, 0)
    if peak > 0:
        cell_store(g_arena_sizes, ai * 8, peak)
        cell_store(g_arena_static, ai * 8, 1)
    else:
        cell_store(g_arena_sizes, ai * 8, arena_scalar_get(8))
        cell_store(g_arena_static, ai * 8, 0)
    cell_store(g_arena_parents, ai * 8, -1)
    cell_store(g_arena_live, ai * 8, 1)

    sl := _arena_get_slot(ai, 0)
    if sl < 0:
        cell_store(g_arena_live, ai * 8, 0)
        cell_store(g_arena_parents, ai * 8, cell_load(g_arena_free_list_m, m * 8))
        cell_store(g_arena_free_list_m, m * 8, ai)
        return -1

    cell_store(g_arena_large_head, ai * 8, -1)
    cell_store(g_arena_large_count, ai * 8, 0)
    ci : ., mut = 0
    loop:
        if ci >= ARENA_CLASS_COUNT:
            break
        cell_store(g_class_base, (ai * ARENA_CLASS_COUNT + ci) * 8, -1)
        cell_store(g_class_cursor, (ai * ARENA_CLASS_COUNT + ci) * 8, 0)
        cell_store(g_class_limit, (ai * ARENA_CLASS_COUNT + ci) * 8, 0)
        ci = ci + 1

    cur := arena_scalar_get(0)
    if cur >= 0:
        cell_store(g_arena_parents, ai * 8, cur)
    arena_set_current(ai)
    return ai

fn arena_new() -> int, pub:
    return arena_new_sized(0)

fn arena_reset(ai: int), pub:
    if ai < 0 || ai >= g_arena_cap:
        return
    if cell_load(g_arena_live, ai * 8) == 0:
        return
    m := ai / ARENA_PER_M
    cell_store(g_arena_live, ai * 8, 0)
    g_arena_suspend = 1

    parent := cell_load(g_arena_parents, ai * 8)

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

    sl : ., mut = cell_load(g_arena_slot, ai * 8)
    loop:
        if sl < 0:
            break
        nxt := cell_load(g_arena_slot_next, sl * 8)
        cell_store(g_arena_slot_next, sl * 8, cell_load(g_slot_free_m, m * 8))
        cell_store(g_slot_free_m, m * 8, sl)
        sl = nxt
    // The chain walk is newest -> oldest and prepends each slot, so the
    // per-M head ends up at the oldest slot. Mirror that head in the legacy
    // global used by the interpreter/tests.
    g_arena_free_list = cell_load(g_slot_free_m, m * 8)
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

    cell_store(g_arena_parents, ai * 8, cell_load(g_arena_free_list_m, m * 8))
    cell_store(g_arena_free_list_m, m * 8, ai)

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
    if ai < 0 || ai >= g_arena_cap:
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
    m : ., mut = rt_m_idx()
    if m < 0:
        m = 0
    sf := cell_load(g_slot_free_m, m * 8)
    slot : ., mut = -1
    if sf >= 0:
        slot = sf
        cell_store(g_slot_free_m, m * 8, cell_load(g_arena_slot_next, sf * 8))
    else:
        count := cell_load(g_slot_count_m, m * 8)
        if count >= SLOTS_PER_M:
            return -1
        slot = m * SLOTS_PER_M + count
        cell_store(g_slot_count_m, m * 8, count + 1)
        seg := slot / 64
        if seg >= cell_load(g_segment_count_m, m * 8):
            arena_grow_pool_m(m)
        if seg >= cell_load(g_segment_count_m, m * 8):
            return -1
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
    if ai < 0 || ai >= g_arena_cap:
        return 0
    used := cell_load(g_arena_slot_cursor, ai * 8)
    return arena_scalar_get(8) - used
