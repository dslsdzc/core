// === corearch.cr ===
// Backend-only binary: reads .ccr → generates binary
// No frontend (no tokenize/parse/check/ir_gen)
// (globals in globals.cr)

// Backend state (declared in backend/x86_64.cr)

// Minimal str_intern for backend use (struct name lookup)
fn str_intern(s: string) -> int {
    i : ., mut = 0;
    loop {
        if i >= g_str_count { break; }
        if __builtin_str_eq(g_strs[i], s) != 0 { return i; }
        i = i + 1;
    }
    if g_str_count < MAX_STRS {
        g_strs[g_str_count] = s;
        g_str_count = g_str_count + 1;
    }
    return g_str_count - 1;
}

fn get_ir_var_name(var_idx: int) -> string {
    if var_idx >= 0 && var_idx < g_ir_var_count {
        return g_ir_vars[var_idx].name;
    }
    return "";
}

fn init_backend_arrays() {
    vi : ., mut = 0;
    loop {
        if vi >= MAX_IREXPRS { break; }
        g_x86_vars[vi] = 0;
        g_x86_is_enum[vi] = 0;
        vi = vi + 1;
    }
    g_x86_var_count = 0;
    g_x86_stack_size = 0;
    g_x86_func_idx = 0;
    g_x86_is_enum_count = 0;
}

// Include the x86-64 backend
// (the backend functions are defined in backend/x86_64.cr and use the globals above)

fn corearch_main() -> int {
    cli_init("corearch", "Core architecture backend");
    cli_flag_bool("S", "", "Output assembly text");
    cli_flag_bool("elf", "", "Output ELF binary (experimental)");
    cli_flag("output", "o", "Output path");
    cli_flag_bool("verbose", "v", "Verbose");

    if cli_parse() != 0 { return 1; }
    if cli_arg_count() < 1 {
        __builtin_println("usage: corearch <file.ccr> [-S] [--elf] [-o output]");
        __builtin_println("  reads .ccr IR and generates assembly/binary");
        __builtin_println("  -S    output assembly text (.s)");
        __builtin_println("  --elf output ELF binary (experimental)");
        __builtin_println("  -o    output path");
        return 1;
    }

    src_path := cli_arg(0);

    fd := __builtin_syscall3(2, src_path, 0, 0);
    if fd < 0 { __builtin_print("error: cannot open "); __builtin_println(src_path); return 1; }
    fsize := __builtin_syscall3(8, fd, 0, 2);
    r1 := __builtin_syscall3(8, fd, 0, 0);
    buf := __builtin_alloc(fsize + 1);
    nread := __builtin_syscall3(0, fd, buf, fsize);
    r2 := __builtin_syscall3(3, fd, 0, 0);
    if nread != fsize { __builtin_print("error: cannot read "); __builtin_println(src_path); return 1; }

    r := load_ccr(buf, fsize);
    if r != 0 { __builtin_println("error: invalid .ccr file"); return 1; }

    init_backend_arrays();

    asm := x86_64_generate();

    emit_elf := cli_has("elf");
    out_path := cli_get("output");

    if emit_elf != 0 {
        if __builtin_str_len(out_path) == 0 { out_path = "a.out"; }
        code := asm_to_bytes(asm);
        layout : ., mut = MemLayout { stack_size = 0, heap_size = 0, text_base = 0, data_base = 0 };
        ctx := elf_begin(layout);
        ctx.code_start = 176;
        total_size : ., mut = 176 + g_asm_code_size;
        elf_write_header(ctx, layout, total_size);
        elf_write_code(ctx, code);
        written := elf_finish(ctx, out_path, total_size);
        if written < 0 { __builtin_print("error: could not write "); __builtin_println(out_path); return 1; }
    } else {
        if __builtin_str_len(out_path) == 0 { out_path = "output.s"; }
        written := __builtin_write_file(out_path, asm);
        if written < 0 { __builtin_print("error: could not write "); __builtin_println(out_path); return 1; }
    }

    __builtin_print(" -> ");
    __builtin_println(out_path);
    return 0;
}
