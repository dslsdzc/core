// === corearch.cr ===
// Backend: .ccr → ELF/assembly/SO
// Supports: --elf (static), --shared (DSO), --link (dynamic linking)

fn init_backend_arrays() {
    g_x86_var_count = 0; g_x86_stack_size = 0; g_x86_func_idx = 0; g_x86_is_enum_count = 0;
    g_x86_var_cap = 0; g_x86_is_enum_cap = 0; g_stack_map = ""; }

fn split_links(val: string) {
    sl := __builtin_str_len(val); start : ., mut = 0; i : ., mut = 0;
    loop { if i > sl { break; }
        if i == sl || __builtin_load8(val, i) == 44 {
            if i > start { p := __builtin_str_sub(val, start, i - start); ctx_add_so(p); }
            start = i + 1; }
        i = i + 1; } }

fn corearch_main() -> int {
    cli_init("corearch", "Core architecture backend");
    cli_flag_bool("elf", "", "Output ELF binary (default)");
    cli_flag_bool("shared", "", "Output shared library (.so)");
    cli_flag_bool("static", "", "Static linking (embed runtime)");
    cli_flag("link", "l", "Comma-sep .so files, or 'auto' for ~/.core/lib/");
    cli_flag("output", "o", "Output path");

    if cli_parse() != 0 { return 1; }
    if cli_arg_count() < 1 {
        __builtin_println("usage: corearch <file.ccr> [options]");
        __builtin_println("  --elf           ELF binary (default: dynamic)");
        __builtin_println("  --static        static linking (embed runtime)");
        __builtin_println("  --shared        shared library (.so)");
        __builtin_println("  --link auto     link ~/.core/lib/*.so (default)");
        __builtin_println("  --link s1,s2   link specific .so files");
        __builtin_println("  -o FILE         output path");
        return 1; }

    src_path := cli_arg(0);
    fd := __builtin_syscall3(2, src_path, 0, 0);
    if fd < 0 { __builtin_print("error: cannot open "); __builtin_println(src_path); return 1; }
    fsize := __builtin_syscall3(8, fd, 0, 2);
    __builtin_syscall3(8, fd, 0, 0);
    buf := __builtin_alloc(fsize + 1);
    nread := __builtin_syscall3(0, fd, buf, fsize);
    __builtin_syscall3(3, fd, 0, 0);
    if nread != fsize { __builtin_println("error: cannot read"); return 1; }
    r := load_ccr(buf, fsize); __builtin_syscall3(1, 1, "D
", 2);
    if r != 0 { __builtin_println("error: invalid .ccr file"); return 1; }
    init_backend_arrays();

    emit_so := cli_has("shared");
    link_val := cli_get("link");
    out_path := cli_get("output");

    // --shared: emit as ET_DYN
    if emit_so != 0 {
        if __builtin_str_len(out_path) == 0 { out_path = "core_lib.so"; }
        g_elf_buf = __builtin_alloc(16777216);
        sz := x86_64_elf_generate(g_elf_buf);
        w16(g_elf_buf, 16, 3);
        fd := __builtin_syscall3(2, out_path, 577, 420);
        if fd < 0 { __builtin_print("error: cannot write "); __builtin_println(out_path); return 1; }
        __builtin_syscall3(1, fd, g_elf_buf, sz);
        __builtin_syscall3(3, fd, 0, 0);
        __builtin_print(" -> "); __builtin_println(out_path);
        return 0; }

    // Default: ELF (static or dynamic)
    if __builtin_str_len(out_path) == 0 { out_path = "a.out"; }
    g_elf_buf = __builtin_alloc(16777216);

    is_static := cli_has("static");
    if is_static == 0 && __builtin_str_len(link_val) == 0 {
        // Default: auto-detect dynamic linking
        link_val = "auto";
    }

    if __builtin_str_len(link_val) > 0 {
        ctx_init();
        if __builtin_str_eq(link_val, "auto") != 0 {
            so_paths : [string; 4], mut;
            so_paths[0] = "./core_rt.so";
            so_paths[1] = "/usr/local/lib/core/core_rt.so";
            sxi : ., mut = 0;
            loop { if sxi >= 4 { break; }
                if __builtin_str_len(so_paths[sxi]) == 0 { break; }
                if __builtin_str_len(__builtin_read_file(so_paths[sxi])) > 0 {
                    ctx_add_so(so_paths[sxi]); }
                sxi = sxi + 1; }
        } else {
            split_links(link_val);
        }
        sz := x86_64_elf_generate(g_elf_buf);
        cs : ., mut = sz - 176;
        if cs <= 0 { __builtin_println("error: empty code"); return 1; }
        cd := __builtin_alloc(cs);
        ci : ., mut = 0; loop { if ci >= cs { break; }
            __builtin_store8(cd, ci, __builtin_load8(g_elf_buf, 176+ci)); ci = ci + 1; }

        if is_static != 0 && g_so_count > 0 {
            // Static linking: embed .so code directly
            ctx_set_user_code(cd, cs);
            sz = ctx_emit_static(g_elf_buf, out_path);
        } else {
            // Dynamic linking: PLT/GOT
            ri : ., mut = 0; loop { if ri >= g_x86_ext_rel_count { break; }
                fn_name := str_get(r64(g_x86_ext_rel_name, ri * 8));
                ctx_add_plt(fn_name, 0); ri = ri + 1; }
            ctx_set_user_code(cd, cs);
            sz = ctx_emit_dyn(g_elf_buf, out_path);
        }
        if sz <= 0 { __builtin_println("error: linking failed"); return 1; }
    } else {
        sz := x86_64_elf_generate(g_elf_buf);
        fd := __builtin_syscall3(2, out_path, 577, 420);
        if fd < 0 { __builtin_print("error: cannot write "); __builtin_println(out_path); return 1; }
        __builtin_syscall3(1, fd, g_elf_buf, sz);
        __builtin_syscall3(3, fd, 0, 0); }
    __builtin_print(" -> "); __builtin_println(out_path);
    return 0; }
