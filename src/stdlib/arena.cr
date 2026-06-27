// Arena memory model — per-goroutine bump allocator with free-list recycling.
//
// Each `go` node gets its own Arena. Allocation is linear pointer-bump (O(1)).
// When the node completes, its Arena is reset (cursor → start) and returned to
// a global free list for reuse.

import panic;

// ── Arena slot layout (24 bytes each: cursor:8, size:8, next_free:8) ──
g_arena_free_list : int, mut;      // linked list head (-1 = empty)
g_arena_count : int, mut;
g_arena_capacity : int, mut;
g_arenas : string, mut;            // arena metadata: 24 bytes per slot

// Arena data pool — fixed total heap for all arenas.
// Each arena slot gets a fixed chunk from this pool: arena_idx * arena_max_size.
g_arena_pool : string, mut;        // actual backing memory
g_arena_pool_size : int, mut;      // total pool size
g_arena_max_size : int, mut;       // max size per arena

fn arena_init(pool_size: int, arena_size: int) {
    g_arena_free_list = -1;
    g_arena_count = 0;
    g_arena_capacity = 64;
    g_arenas = alloc(g_arena_capacity * 24);
    g_arena_max_size = arena_size;
    g_arena_pool_size = pool_size;
    g_arena_pool = alloc(pool_size);
}

fn arena_new() -> int {
    // Try free list first
    if g_arena_free_list >= 0 {
        ai := g_arena_free_list;
        off := ai * 24;
        g_arena_free_list = r64(g_arenas, off + 16);  // pop
        w64(g_arenas, off, 0);                        // cursor = 0
        return ai;
    }
    if g_arena_count >= g_arena_capacity {
        nc := g_arena_capacity * 2;
        nb := alloc(nc * 24);
        _dyncpy(g_arenas, g_arena_capacity * 24, nb);
        g_arena_capacity = nc;
        g_arenas = nb;
    }
    ai := g_arena_count;
    off := ai * 24;
    // Verify pool space
    if (ai + 1) * g_arena_max_size > g_arena_pool_size {
        panic.raise("arena pool exhausted");
    }
    w64(g_arenas, off, 0);                     // cursor = 0
    w64(g_arenas, off + 8, g_arena_max_size);   // size
    w64(g_arenas, off + 16, -1);                // next_free
    g_arena_count = g_arena_count + 1;
    return ai;
}

// Returns pointer to allocated memory within the arena pool
fn arena_alloc(ai: int, size: int) -> int {
    off := ai * 24;
    cursor := r64(g_arenas, off);
    limit := r64(g_arenas, off + 8);
    aligned := (size + 7) & -8;  // 8-byte alignment (same as & ~7)
    if cursor + aligned > limit {
        panic.raise("arena OOM");
    }
    w64(g_arenas, off, cursor + aligned);
    // Return actual address: pool base + arena_offset + old_cursor
    return ai * g_arena_max_size + cursor;
}

fn arena_reset(ai: int) {
    if ai < 0 || ai >= g_arena_count { return; }
    off := ai * 24;
    w64(g_arenas, off, 0);
    w64(g_arenas, off + 16, g_arena_free_list);
    g_arena_free_list = ai;
}
