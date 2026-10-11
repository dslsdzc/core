// Low-level runtime globals — used by rt.s (assembly) and ELF backend.
import arena_globals

g_rt_argc : int, mut
g_rt_argv_ptr : string, mut

// Bump allocator globals — must be Core globals so the ELF backend's
// rip_patch mechanism resolves their BSS addresses correctly.
g_heap_ptr : string, mut
g_heap_end : string, mut

// Hotpatch runtime state
g_hp_config  : string, mut
g_hp_inflight : string, mut
