// === project.cr ===
// Project-level operations: reads Core.toml, resolves source files,
// provides memory layout to the backend.
// Depends on toml.cr for low-level key-value parsing.

struct ProjectConfig {
    name: string,
    mem: MemLayout,       // from toml.cr: stack_size, heap_size, text_base, data_base
    source_dir: string,
    main_source: string,
}

fn load_project(dir: string) -> ProjectConfig {
    sd : ., mut = "";
    toml_path : ., mut = dir;
    if str_eq(get_char(dir, str_len(dir) - 1), "/") != 0 {
        sd = dir;
        toml_path = dir + "Core.toml";
    } else {
        sd = dir + "/";
        toml_path = dir + "/Core.toml";
    }

    tc := read_file(toml_path);
    pname : ., mut = "";
    ml : ., mut = MemLayout { stack_size = 0, heap_size = 0, text_base = 0, data_base = 0 };
    if str_len(tc) > 0 {
        pname = extract_toml_name(tc);
        ml = toml_read_memlayout(tc);
    }

    main_path : ., mut = sd + "main.cr";
    source := read_file(main_path);
    if str_len(source) == 0 {
        main_path = "main.cr";
        source = read_file(main_path);
    }

    return ProjectConfig {
        name = pname,
        mem = ml,
        source_dir = sd,
        main_source = source,
    };
}

fn print_project_info(cfg: ProjectConfig) {
    if str_len(cfg.name) > 0 {
        print("  project: ");
        println(cfg.name);
    }
    if str_len(cfg.main_source) > 0 {
        print("  main.cr: ");
        println(cfg.source_dir + "main.cr");
    }
}
