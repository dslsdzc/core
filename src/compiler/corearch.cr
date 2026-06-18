// === corearch.cr ===
// Backend: .ccr → ELF/assembly/SO
// Supports: --elf (static), --shared (DSO), --link (dynamic linking)

fn init_backend_arrays() {
    g_x86_var_count = 0; g_x86_stack_size = 0; g_x86_func_idx = 0; g_x86_is_enum_count = 0;
    g_x86_var_cap = 0; g_x86_is_enum_cap = 0; g_stack_map = ""; }

fn split_links(val: string) {
    sl := str_len(val); start : ., mut = 0; i : ., mut = 0;
    loop { if i > sl { break; }
        if i == sl || load8(val, i) == 44 {
            if i > start { p := str_sub(val, start, i - start); ctx_add_so(p); }
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
        println("usage: corearch <file.ccr> [options]");
        println("  --elf           ELF binary (default: dynamic)");
        println("  --static        static linking (embed runtime)");
        println("  --shared        shared library (.so)");
        println("  --link auto     link ~/.core/lib/*.so (default)");
        println("  --link s1,s2   link specific .so files");
        println("  -o FILE         output path");
        return 1; }

    src_path := cli_arg(0);
    fd := syscall3(2, src_path, 0, 0);
    if fd < 0 { print("error: cannot open "); println(src_path); return 1; }
    fsize := syscall3(8, fd, 0, 2);
    syscall3(8, fd, 0, 0);
    buf := alloc(fsize + 1);
    nread := syscall3(0, fd, buf, fsize);
    syscall3(3, fd, 0, 0);
    if nread != fsize { println("error: cannot read"); return 1; }
    r := load_ccr(buf, fsize);
    if r != 0 { println("error: invalid .ccr file"); return 1; }
    init_backend_arrays();

    emit_so := cli_has("shared");
    link_val := cli_get("link");
    out_path := cli_get("output");

    // --shared: emit as ET_DYN
    if emit_so != 0 {
        if str_len(out_path) == 0 { out_path = "core_lib.so"; }
        g_elf_buf = alloc(16777216);
        sz := x86_64_elf_generate(g_elf_buf);
        w16(g_elf_buf, 16, 3);
        fd := syscall3(2, out_path, 577, 420);
        if fd < 0 { print("error: cannot write "); println(out_path); return 1; }
        syscall3(1, fd, g_elf_buf, sz);
        syscall3(3, fd, 0, 0);
        print(" -> "); println(out_path);
        return 0; }

    // Default: ELF (static or dynamic)
    if str_len(out_path) == 0 { out_path = "a.out"; }
    g_elf_buf = alloc(16777216);

    is_static := cli_has("static");

    if str_len(link_val) > 0 {
        ctx_init();
        if str_eq(link_val, "auto") != 0 {
            // Look for core_rt.so relative to compiler binary
            sp := get_arg(0);
            sllen := str_len(sp);
            last_sl : ., mut = -1;
            sli : ., mut = 0;
            loop { if sli >= sllen { break; }
                if load8(sp, sli) == 47 { last_sl = sli; }
                sli = sli + 1; }
            if last_sl >= 0 {
                libp := str_sub(sp, 0, last_sl + 1) + "core_rt.so";
                if str_len(read_file(libp)) > 0 { ctx_add_so(libp); } }
            // Also try ./build/, ./, and ~/.core/lib/
            if str_len(read_file("./build/core_rt.so")) > 0 {
                ctx_add_so("./build/core_rt.so"); }
            else if str_len(read_file("./core_rt.so")) > 0 {
                ctx_add_so("./core_rt.so"); }
            if str_len(read_file("~/.core/lib/core_rt.so")) > 0 {
                ctx_add_so("~/.core/lib/core_rt.so"); }
        } else {
            split_links(link_val);
        }
        sz := x86_64_elf_generate(g_elf_buf);
        cs : ., mut = sz - 176;
        if cs <= 0 { println("error: empty code"); return 1; }
        cd := alloc(cs);
        ci : ., mut = 0; loop { if ci >= cs { break; }
            store8(cd, ci, load8(g_elf_buf, 176+ci)); ci = ci + 1; }
        // Clear rip-relative patches in user code (they point to original BSS)
        // NOP the mov [r10],rXX that follows each lea r10,[rip+...]
        rpi : ., mut = 0;
        loop { if rpi >= g_x86_rip_patch_count { break; }
            ppos := r64(g_x86_rip_patch_pos, rpi * 8);
            if ppos >= 176 && ppos - 176 + 4 <= cs {
                w32(cd, ppos - 176, 0);
                w8(cd, ppos + 4 - 176, 144); w8(cd, ppos + 5 - 176, 144); w8(cd, ppos + 6 - 176, 144); }
            rpi = rpi + 1; }


        if is_static != 0 {
            if g_so_count > 0 {
                ctx_set_user_code(cd, cs);
                sz = ctx_emit_static(g_elf_buf, out_path);
            } else {
                // Pure static: write directly (rt.cr prepended by frontend)
                fd := syscall3(2, out_path, 577, 420);
                if fd < 0 { print("error: cannot write "); println(out_path); return 1; }
                syscall3(1, fd, g_elf_buf, sz);
                syscall3(3, fd, 0, 0); }
        } else {
            // Dynamic linking: PLT/GOT
            ri : ., mut = 0; loop { if ri >= g_x86_ext_rel_count { break; }
                fn_name := istr_get(r64(g_x86_ext_rel_name, ri * 8));
                ctx_add_plt(fn_name, 0); ri = ri + 1; }
            ctx_set_user_code(cd, cs);
            sz = ctx_emit_dyn(g_elf_buf, out_path);
        }
        if sz <= 0 { println("error: linking failed"); return 1; }
    } else {
        sz := x86_64_elf_generate(g_elf_buf);
        fd := syscall3(2, out_path, 577, 420);
        if fd < 0 { print("error: cannot write "); println(out_path); return 1; }
        syscall3(1, fd, g_elf_buf, sz);
        syscall3(3, fd, 0, 0); }
    print(" -> "); println(out_path);
    return 0; }
