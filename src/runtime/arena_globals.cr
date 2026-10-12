// Shared arena state used by the runtime allocator and arena stdlib.
g_current_arena : int, mut = -1
g_arena_pool_data : string, mut
g_arena_free_list : int, mut = -1
