// Arena large-object extents: allocation, payload, list count, reset cleanup.
import arena
import io

g_current_arena : int, mut = -1
g_arena_pool_data : string, mut
g_arena_free_list : int, mut = -1
g_arena_large_head : string, mut
g_arena_large_count : string, mut

fn main() -> int:
    arena_init(67108864, 65536)
    a := arena_new()
    p := alloc(104857600)
    if p == 0:
        return 1
    if cell_load(g_arena_large_count, a * 8) != 1:
        return 2
    h := cell_load(g_arena_large_head, a * 8)
    if h == -1:
        return 3
    cell_store(p, 0, 7)
    cell_store(p, 104857592, 9)
    if cell_load(p, 0) != 7:
        return 4
    if cell_load(p, 104857592) != 9:
        return 5
    arena_reset(a)
    if cell_load(g_arena_large_count, a * 8) != 0:
        return 6
    if cell_load(g_arena_large_head, a * 8) != -1:
        return 7
    return 0
