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
    g_arena_cap = nc
    g_current_arena = saved_arena

// ── Public API ──

fn arena_init(pool_size: int, arena_size: int), pub:
    // The backing pool outlives the caller's automatic function arena.
    g_current_arena = -1
    g_arena_pool_data = alloc(pool_size)
    g_arena_max_size = arena_size
    g_arena_free_list = -1
    g_arena_count = 0
    g_arena_cap = 0

fn arena_new() -> int, pub:
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
    cell_store(g_arena_sizes, ai * 8, g_arena_max_size)
    cell_store(g_arena_parents, ai * 8, -1)

    // Set parent = previous current arena
    if g_current_arena >= 0:
        cell_store(g_arena_parents, ai * 8, g_current_arena)

    // Activate
    g_current_arena = ai
    return ai

fn arena_reset(ai: int), pub:
    if ai < 0 || ai >= g_arena_count:
        return

    // Save parent BEFORE free list overwrites g_arena_parents[ai]
    parent := cell_load(g_arena_parents, ai * 8)

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
    cursor := cell_load(g_arena_cursors, ai * 8)
    limit := cell_load(g_arena_sizes, ai * 8)
    return limit - cursor
