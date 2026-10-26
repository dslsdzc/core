// === hotpatch.cr ===
// Hotpatch runtime: config file management, in-flight request tracking.
//
// Uses g_hp_config / g_hp_inflight globals declared in runtime/rt.cr.
// Called from the SIGHUP handler in runtime/rt.s.
//
// Config format (.hotpatch.toml):
//   [hotpatch]
//   # Fields are read with toml_get_str / toml_get_int on g_hp_config.

// Re-read .hotpatch.toml into g_hp_config.
// Safe to call from signal handler context (kernel saves/restores registers).
fn hp_load_config():
    tc := read_file(".hotpatch.toml")
    if str_len(tc) > 0:
        g_hp_config = tc

// Increment the in-flight counter for a given function version.
// fn_ver: 0-based index into the 64-slot in-flight buffer.
fn hp_inflight_inc(fn_ver: int):
    cur := cell_load(g_hp_inflight, fn_ver * 8)
    cell_store(g_hp_inflight, fn_ver * 8, cur + 1)

// Decrement the in-flight counter for a given function version.
// Saturates at 0 (never goes negative).
fn hp_inflight_dec(fn_ver: int):
    cur := cell_load(g_hp_inflight, fn_ver * 8)
    if cur > 0:
        cell_store(g_hp_inflight, fn_ver * 8, cur - 1)

// Initialize hotpatch system at startup.
// Allocates the in-flight counter buffer and loads the initial config.
fn hp_init(), pub:
    g_hp_config = ""
    g_hp_inflight = alloc(64 * 8)  // 64 version slots, each 8 bytes
    // Zero-initialise all slots
    i : ., mut = 0
    loop:
        if i >= 64:
            break
        cell_store(g_hp_inflight, i * 8, 0)
        i = i + 1
    hp_load_config()
