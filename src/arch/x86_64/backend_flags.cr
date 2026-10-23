// 后端 CLI 旗标注册单源。
// concat 入口（corearch.cr）与组合根 project-mode 入口
// （src/targets/x86_64/linux/elf/main.cr）共用本函数，避免两处注册表漂移。
fn register_backend_flags():
    cli_flag_bool("elf", "", "Output ELF binary (default)")
    cli_flag_bool("shared", "", "Output shared library (.so)")
    cli_flag_bool("static", "", "Static linking (embed runtime)")
    cli_flag("link", "l", "Comma-sep .so files, or 'auto' for ~/.core/lib/")
    cli_flag("output", "o", "Output path")
    cli_flag("opt-level", "O", "Optimization level (0-3, default=0)")
    cli_flag_bool("big-int", "", "Arbitrary precision int semantics for user programs")
    cli_flag_bool("raw-int", "", "Force raw machine-int semantics (compiler/self-host builds)")
    cli_flag("table", "", "HIT table file (load & emit mapped ops through it)")
    cli_flag_debug("hit-events-file", "", "Debug: inject text event stream file")
    cli_flag_bool("dump-events", "", "Dump lowered HIT event stream + const pool")
    cli_flag_bool_debug("dump-table", "", "Debug: dump loaded HIT table state")
    cli_flag_bool_debug("dump-entries", "", "Debug: dump versioned entries summary")
    cli_flag_bool_debug("dump-coexist", "", "Debug: dump coexistence summary")
    cli_flag_bool_debug("dump-regassign", "", "Debug: dump var-to-reg after O2")
    cli_flag_bool_debug("check-regalloc", "", "Debug: O2 regalloc consistency check")
    cli_flag_bool_debug("inject-home-conflict", "", "Debug hook: inject home-slot conflict")
    cli_flag_bool_debug("inject-reg-conflict", "", "Debug hook: inject register conflict")
    cli_flag_bool_debug("inject-read-gap", "", "Debug hook: truncate last version interval")
    cli_flag_bool_debug("inject-coexist-oob", "", "Debug hook: probe entries_coexist out of bounds")
    cli_flag_bool_debug("dump-objects", "", "Debug: dump NOD/EDG objects")
    cli_flag_bool_debug("dump-nod-types", "", "Debug: dump NOD type_id/flags")
    cli_flag_bool_debug("dump-types", "", "Debug: dump TYPE segment")
    cli_flag_bool_debug("dump-ifaces", "", "Debug: dump IFACE segment")

// Select the int representation. The .ccr header carries no raw-int bit (only
// program flags); the frontend passes --raw-int explicitly for compiler and
// self-host artifacts. Ordinary user programs use tagged mathematical ints.
fn backend_select_int_mode():
    if cli_has("raw-int") != 0:
        g_x86_big_enabled = 0
    else:
        g_x86_big_enabled = 1
