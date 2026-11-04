// === project.cr ===
// Project-level operations: reads Core.toml, resolves source files,
// provides memory layout to the backend.
// Depends on toml.cr for low-level key-value parsing.

// Set by load_project() — used by read_project_dir in main.cr
g_project_source_dir : string, mut
g_project_name : string, mut

// Load project config. Returns main_source, sets g_project_source_dir as side effect.
fn load_project(dir: string) -> string:
    sd : ., mut = ""
    toml_path : ., mut = dir
    if str_eq(get_char(dir, str_len(dir) - 1), "/") != 0:
        sd = dir
        toml_path = dir + "Core.toml"
    else:
        sd = dir + "/"
        toml_path = dir + "/Core.toml"

    tc := read_file(toml_path)
    pname : ., mut = ""
    if str_len(tc) > 0:
        pname = extract_toml_name(tc)
        lim := toml_get_int(tc, "arena_pool_limit")
        if lim > 0:
            g_arena_pool_limit_cfg = lim

    g_project_name = pname
    if str_len(g_project_name) == 0:
        fallback_name : ., mut = basename(dir)
        if str_eq(fallback_name, ".") != 0:
            cwd := get_cwd()
            if str_len(cwd) > 0:
                fallback_name = basename(cwd)
        if str_len(fallback_name) == 0 || str_eq(fallback_name, ".") != 0 || str_eq(fallback_name, "..") != 0 || str_eq(fallback_name, "/") != 0:
            fallback_name = "a.out"
        g_project_name = fallback_name

    main_path : ., mut = sd + "main.cr"
    source := read_file(main_path)

    g_project_source_dir = sd
    if str_len(pname) > 0:
        print("  project: ")
        println(pname)
    if str_len(source) > 0:
        print("  main.cr: ")
        println(main_path)

    return source
