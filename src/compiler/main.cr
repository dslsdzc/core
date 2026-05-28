// === main.cr ===
// Compiler entry point: ties all stages together

fn is_cr_file(path: string) -> int {
    slen := __builtin_str_len(path);
    if slen < 3 { return 0; }
    ext := __builtin_str_sub(path, slen - 3, 3);
    if __builtin_str_eq(ext, ".cr") != 0 { return 1; }
    return 0;
}

fn read_source_file(path: string) -> string {
    g_source_dir = dirname(path);
    source := __builtin_read_file(path);
    if __builtin_str_len(source) > 0 {
        __builtin_print("source: ");
        __builtin_print(__builtin_int_to_str(__builtin_str_len(source)));
        __builtin_println(" bytes");
    }
    return source;
}

fn read_project_dir(dir: string) -> string {
    g_source_dir = "";
    toml_path : ., mut = dir;
    if __builtin_str_eq(__builtin_str_get(dir, __builtin_str_len(dir) - 1), "/") != 0 {
        g_source_dir = dir;
        toml_path = dir + "Core.toml";
    } else {
        g_source_dir = dir + "/";
        toml_path = dir + "/Core.toml";
    }
    // Check Core.toml
    tc := __builtin_read_file(toml_path);
    if __builtin_str_len(tc) > 0 {
        pn := extract_toml_name(tc);
        if __builtin_str_len(pn) > 0 {
            __builtin_print("  project: ");
            __builtin_println(pn);
        }
    }
    main_path : ., mut = g_source_dir + "main.cr";
    source := __builtin_read_file(main_path);
    if __builtin_str_len(source) > 0 {
        __builtin_print("  main.cr: ");
        __builtin_println(main_path);
    } else {
        __builtin_println("error: no main.cr found in directory");
    }
    return source;
}

// Entry point
fn corec_main() -> int {
    cli_init("corec", "Core compiler frontend");
    cli_flag_bool("cir", "", "Output dataflow graph (.cir)");
    cli_flag_bool("ccr", "", "Output linear CFG (.ccr) [default]");
    cli_flag_bool("check", "", "Type-check only, no output");
    cli_flag("output", "o", "Output path");

    if cli_parse() != 0 { return 1; }
    if cli_arg_count() < 1 {
        __builtin_println("usage: corec <file.cr> [options]");
        __builtin_println("  compile Core source to .ccr (default) or .cir");
        __builtin_println("  --cir     output dataflow graph (.cir)");
        __builtin_println("  --ccr     output linear CFG (.ccr)");
        __builtin_println("  --check   type-check only");
        __builtin_println("  -o FILE   output path");
        return 1;
    }

    src_path := cli_arg(0);
    emit_cir := cli_has("cir");
    check_only := cli_has("check");

    // Read source
    g_source = __builtin_read_file(src_path);
    if __builtin_str_len(g_source) == 0 {
        __builtin_print("error: cannot read ");
        __builtin_println(src_path);
        return 1;
    }
    g_source_dir = dirname(src_path);

    // Frontend pipeline
    tokenize();
    g_str_count = 0;
    resolve_imports();
    parse_all();
    check_all();
    if g_check_error_count > 0 { return 1; }

    if check_only != 0 {
        __builtin_println("ok");
        return 0;
    }

    ir_gen_all();

    if emit_cir != 0 {
        // .cir output (dataflow graph)
        dot := df_graph_to_dot();
        out := cli_get("output");
        if __builtin_str_len(out) == 0 {
            out = src_path;
            sl := __builtin_str_len(src_path);
            if sl > 3 {
                ext := __builtin_str_sub(src_path, sl - 3, 3);
                if __builtin_str_eq(ext, ".cr") != 0 {
                    out = __builtin_str_sub(src_path, 0, sl - 3) + ".cir";
                }
            }
        }
        written := __builtin_write_file(out, dot);
        if written < 0 {
            __builtin_print("error: could not write ");
            __builtin_println(out);
            return 1;
        }
        __builtin_print(" -> ");
        __builtin_println(out);
    } else {
        // .ccr output (linear CFG, default)
        lower_to_ccr();
        out := cli_get("output");
        if __builtin_str_len(out) == 0 {
            out = src_path;
            sl := __builtin_str_len(src_path);
            if sl > 3 {
                ext := __builtin_str_sub(src_path, sl - 3, 3);
                if __builtin_str_eq(ext, ".cr") != 0 {
                    out = __builtin_str_sub(src_path, 0, sl - 3) + ".ccr";
                }
            }
        }
        r := save_ccr(out);
        if r != 0 {
            __builtin_print("error: could not write ");
            __builtin_println(out);
            return 1;
        }
        __builtin_print(" -> ");
        __builtin_print(out);
        __builtin_print(" (");
        __builtin_print(__builtin_int_to_str(g_ir_func_count));
        __builtin_print(" funcs, ");
        __builtin_print(__builtin_int_to_str(g_ir_instr_count));
        __builtin_println(" instrs)");
    }

    return 0;
}

// === CCR dump helpers ===

fn ir_var_str(var_idx: int) -> string {
    if var_idx < 0 { return ""; }
    n := get_ir_var_name(var_idx);
    if __builtin_str_len(n) > 0 { return n; }
    return __builtin_int_to_str(var_idx);
}

fn type_kind_name(tk: int) -> string {
    if tk == 0 { return "int"; }
    if tk == 1 { return "float"; }
    if tk == 2 { return "bool"; }
    if tk == 3 { return "str"; }
    if tk == 4 { return "unit"; }
    if tk == 5 { return "never"; }
    if tk == 6 { return "char"; }
    return "?";
}

fn binop_name(op: int) -> string {
    if op == 1 { return "+"; }
    if op == 2 { return "-"; }
    if op == 3 { return "*"; }
    if op == 4 { return "/"; }
    if op == 5 { return "%"; }
    if op == 6 { return "=="; }
    if op == 7 { return "!="; }
    if op == 8 { return "<"; }
    if op == 9 { return ">"; }
    if op == 10 { return "<="; }
    if op == 11 { return ">="; }
    if op == 12 { return "&&"; }
    if op == 13 { return "||"; }
    return "?";
}

fn ir_instr_str(instr: IRInstr) -> string {
    opname := df_opcode_name(instr.opcode);
    s : ., mut = "  ";
    s = s + opname;
    pa : ., mut = __builtin_str_len(opname);
    loop {
        if pa >= 18 { break; }
        s = s + " ";
        pa = pa + 1;
    }

    if instr.opcode == IR_CONST {
        s = s + ir_var_str(instr.dest) + " = " + __builtin_int_to_str(instr.src1);
        return s;
    }
    if instr.opcode == IR_BINARY {
        s = s + ir_var_str(instr.dest) + " = " + ir_var_str(instr.src1) + " " + binop_name(instr.src3) + " " + ir_var_str(instr.src2);
        return s;
    }
    if instr.opcode == IR_UNARY {
        s = s + ir_var_str(instr.dest) + " = unary(" + ir_var_str(instr.src1) + ")";
        return s;
    }
    if instr.opcode == IR_CALL {
        s = s + ir_var_str(instr.dest) + " = call " + g_strs[instr.src3] + "(";
        ai : ., mut = 0;
        a_first : ., mut = 1;
        loop {
            if ai >= instr.src2 { break; }
            if a_first == 0 { s = s + ", "; }
            s = s + ir_var_str(instr.src1 + ai);
            a_first = 0;
            ai = ai + 1;
        }
        s = s + ")";
        return s;
    }
    if instr.opcode == IR_RETURN {
        if instr.src1 >= 0 { s = s + ir_var_str(instr.src1); }
        else { s = s + "void"; }
        return s;
    }
    if instr.opcode == IR_ALLOC {
        s = s + ir_var_str(instr.dest) + " : " + type_kind_name(instr.type_kind);
        return s;
    }
    if instr.opcode == IR_ALLOC_STRUCT {
        s = s + ir_var_str(instr.dest) + " : struct " + g_strs[instr.src3];
        return s;
    }
    if instr.opcode == IR_ALLOC_ARRAY {
        s = s + ir_var_str(instr.dest) + "[" + __builtin_int_to_str(instr.src1) + "]";
        return s;
    }
    if instr.opcode == IR_STORE {
        s = s + ir_var_str(instr.src1) + " <- " + ir_var_str(instr.src2);
        return s;
    }
    if instr.opcode == IR_LOAD {
        s = s + ir_var_str(instr.dest) + " = " + ir_var_str(instr.src1);
        return s;
    }
    if instr.opcode == IR_LOAD_FIELD {
        s = s + ir_var_str(instr.dest) + " = " + ir_var_str(instr.src1) + "." + __builtin_int_to_str(instr.src3);
        return s;
    }
    if instr.opcode == IR_STORE_FIELD {
        s = s + ir_var_str(instr.src1) + "." + __builtin_int_to_str(instr.src3) + " <- " + ir_var_str(instr.src2);
        return s;
    }
    if instr.opcode == IR_LOAD_INDEX {
        s = s + ir_var_str(instr.dest) + " = " + ir_var_str(instr.src1) + "[" + __builtin_int_to_str(instr.src3) + "]";
        return s;
    }
    if instr.opcode == IR_STORE_INDEX {
        s = s + ir_var_str(instr.src1) + "[" + __builtin_int_to_str(instr.src3) + "] <- " + ir_var_str(instr.src2);
        return s;
    }
    if instr.opcode == IR_LOAD_INDEX_VAR {
        s = s + ir_var_str(instr.dest) + " = " + ir_var_str(instr.src1) + "[" + ir_var_str(instr.src2) + "]";
        return s;
    }
    if instr.opcode == IR_STORE_INDEX_VAR {
        s = s + ir_var_str(instr.src1) + "[" + ir_var_str(instr.src2) + "] <- " + ir_var_str(instr.dest);
        return s;
    }
    if instr.opcode == IR_MAKE_ENUM {
        s = s + ir_var_str(instr.dest) + " = make_enum(" + g_strs[instr.src1] + ")";
        return s;
    }
    if instr.opcode == IR_REF {
        s = s + ir_var_str(instr.dest) + " = ref " + ir_var_str(instr.src1);
        return s;
    }
    if instr.opcode == IR_DEREF {
        s = s + ir_var_str(instr.dest) + " = deref " + ir_var_str(instr.src1);
        return s;
    }
    if instr.opcode == IR_STORE_PTR {
        s = s + ir_var_str(instr.src1) + " := " + ir_var_str(instr.src2);
        return s;
    }
    if instr.opcode == IR_BRANCH {
        s = s + "if " + ir_var_str(instr.src1) + " goto label" + __builtin_int_to_str(instr.src2) + " else label" + __builtin_int_to_str(instr.src3);
        return s;
    }
    if instr.opcode == IR_JUMP {
        s = s + "goto label" + __builtin_int_to_str(instr.src1);
        return s;
    }
    if instr.opcode == IR_LABEL {
        s = s + "label" + __builtin_int_to_str(instr.src1) + ":";
        return s;
    }
    if instr.opcode == IR_PHI {
        s = s + ir_var_str(instr.dest) + " = phi(";
        pi : ., mut = 0;
        p_first : ., mut = 1;
        loop {
            if pi >= instr.src2 { break; }
            if p_first == 0 { s = s + ", "; }
            s = s + ir_var_str(instr.src1 + pi);
            p_first = 0;
            pi = pi + 1;
        }
        s = s + ")";
        return s;
    }
    if instr.opcode == IR_LOAD_ENUM_TAG {
        s = s + ir_var_str(instr.dest) + " = tag " + ir_var_str(instr.src1);
        return s;
    }
    if instr.opcode == IR_SLICE {
        s = s + ir_var_str(instr.dest) + " = slice " + ir_var_str(instr.src1) + "[" + ir_var_str(instr.src2) + ":" + ir_var_str(instr.src3) + "]";
        return s;
    }

    s = s + "dest=" + ir_var_str(instr.dest) + " s1=" + __builtin_int_to_str(instr.src1) + " s2=" + __builtin_int_to_str(instr.src2) + " s3=" + __builtin_int_to_str(instr.src3);
    return s;
}

fn cmd_ir(src_path: string) -> int {
    g_source = __builtin_read_file(src_path);
    if __builtin_str_len(g_source) == 0 {
        __builtin_print("error: cannot read ");
        __builtin_println(src_path);
        return 1;
    }
    g_source_dir = dirname(src_path);
    tokenize();
    g_str_count = 0;
    resolve_imports();
    parse_all();
    check_all();
    if g_check_error_count > 0 { return 1; }
    ir_gen_all();
    dot := df_graph_to_dot();

    cir_path : ., mut = src_path;
    slen := __builtin_str_len(src_path);
    if slen > 3 {
        ext := __builtin_str_sub(src_path, slen - 3, 3);
        if __builtin_str_eq(ext, ".cr") != 0 {
            cir_path = __builtin_str_sub(src_path, 0, slen - 3) + ".cir";
        }
    }

    written := __builtin_write_file(cir_path, dot);
    if written < 0 {
        __builtin_print("error: could not write ");
        __builtin_println(cir_path);
        return 1;
    }
    __builtin_print(" -> ");
    __builtin_print(cir_path);
    __builtin_print(" (");
    __builtin_print(__builtin_int_to_str(g_df_node_count));
    __builtin_print(" nodes, ");
    __builtin_print(__builtin_int_to_str(g_df_edge_count));
    __builtin_println(" edges)");
    return 0;
}

fn cmd_cir(src_path: string) -> int {
    g_source = __builtin_read_file(src_path);
    if __builtin_str_len(g_source) == 0 {
        __builtin_print("error: cannot read ");
        __builtin_println(src_path);
        return 1;
    }
    g_source_dir = dirname(src_path);
    tokenize();
    g_str_count = 0;
    resolve_imports();
    parse_all();
    check_all();
    if g_check_error_count > 0 { return 1; }
    ir_gen_all();
    lower_to_ccr();

    ccr : ., mut = "";
    fi : ., mut = 0;
    loop {
        if fi >= g_ir_func_count { break; }
        name_ni := g_ir_func_name_idx[fi];
        ccr = ccr + "Function: " + g_strs[name_ni] + "\n";
        start := g_ir_func_instr_start[fi];
        count := g_ir_func_instr_count[fi];
        in_block : ., mut = 0;
        ii : ., mut = 0;
        loop {
            if ii >= count { break; }
            instr := g_ir_instrs[start + ii];
            if instr.opcode == IR_LABEL {
                if in_block != 0 { ccr = ccr + "\n"; }
                ccr = ccr + "  Block: label" + __builtin_int_to_str(instr.src1) + "\n";
                in_block = 1;
            } else {
                ccr = ccr + "    " + ir_instr_str(instr) + "\n";
            }
            ii = ii + 1;
        }
        ccr = ccr + "\n";
        fi = fi + 1;
    }

    ccr_path : ., mut = src_path;
    slen := __builtin_str_len(src_path);
    if slen > 3 {
        ext := __builtin_str_sub(src_path, slen - 3, 3);
        if __builtin_str_eq(ext, ".cr") != 0 {
            ccr_path = __builtin_str_sub(src_path, 0, slen - 3) + ".ccr";
        }
    }

    written := __builtin_write_file(ccr_path, ccr);
    if written < 0 {
        __builtin_print("error: could not write ");
        __builtin_println(ccr_path);
        return 1;
    }
    __builtin_print(" -> ");
    __builtin_print(ccr_path);
    __builtin_print(" (");
    __builtin_print(__builtin_int_to_str(g_ir_func_count));
    __builtin_print(" functions, ");
    __builtin_print(__builtin_int_to_str(g_ir_instr_count));
    __builtin_println(" instrs)");
    return 0;
}

// Entry point
fn compiler_main() -> int {
    return corec_main();
}

fn count_newlines(s: string) -> int {
    slen := __builtin_str_len(s);
    n : ., mut = 0;
    i : ., mut = 0;
    loop {
        if i >= slen { break; }
        if __builtin_str_eq(__builtin_str_get(s, i), "\n") != 0 { n = n + 1; }
        i = i + 1;
    }
    return n;
}

fn extract_fileid(s: string) -> string {
    // Scan for: fileid "name"
    slen := __builtin_str_len(s);
    i : ., mut = 0;
    loop {
        if i + 6 >= slen { return ""; }
        sub := __builtin_str_sub(s, i, 6);
        if __builtin_str_eq(sub, "fileid") != 0 {
            // Found keyword, scan for "
            j : ., mut = i + 6;
            loop {
                if j >= slen { return ""; }
                if __builtin_str_eq(__builtin_str_get(s, j), "\"") != 0 {
                    start := j + 1;
                    k : ., mut = start;
                    loop {
                        if k >= slen { return ""; }
                        if __builtin_str_eq(__builtin_str_get(s, k), "\"") != 0 {
                            return __builtin_str_sub(s, start, k - start);
                        }
                        k = k + 1;
                    }
                }
                j = j + 1;
            }
        }
        i = i + 1;
    }
    return "";
}

// Extract project name from Core.toml content: name = "..."
fn extract_toml_name(content: string) -> string {
    slen := __builtin_str_len(content);
    i : ., mut = 0;
    loop {
        if i + 6 >= slen { return ""; }
        // Check if we're at start of line (pos 0 or after \n)
        at_line_start : ., mut = 0;
        if i == 0 { at_line_start = 1; }
        else {
            prev := __builtin_str_get(content, i - 1);
            if __builtin_str_eq(prev, "\n") != 0 { at_line_start = 1; }
        }
        if at_line_start == 0 {
            // Not at line start, skip to next line
            loop {
                if i >= slen { return ""; }
                if __builtin_str_eq(__builtin_str_get(content, i), "\n") != 0 { break; }
                i = i + 1;
            }
            i = i + 1;
            continue;
        }
        // At line start: skip leading whitespace, then check for "name"
        ws_end : ., mut = i;
        loop {
            if ws_end >= slen { return ""; }
            ch := __builtin_str_get(content, ws_end);
            if __builtin_str_eq(ch, " ") != 0 || __builtin_str_eq(ch, "\t") != 0 {
                ws_end = ws_end + 1;
            } else { break; }
        }
        sub := __builtin_str_sub(content, ws_end, 4);
        if __builtin_str_eq(sub, "name") != 0 {
            j : ., mut = ws_end + 4;
            loop {
                if j >= slen { return ""; }
                if __builtin_str_eq(__builtin_str_get(content, j), "=") != 0 {
                    // Found =, scan for opening quote
                    k : ., mut = j + 1;
                    loop {
                        if k >= slen { return ""; }
                        if __builtin_str_eq(__builtin_str_get(content, k), "\"") != 0 {
                            start := k + 1;
                            end : ., mut = start;
                            loop {
                                if end >= slen { return ""; }
                                if __builtin_str_eq(__builtin_str_get(content, end), "\"") != 0 {
                                    return __builtin_str_sub(content, start, end - start);
                                }
                                end = end + 1;
                            }
                        }
                        k = k + 1;
                    }
                }
                j = j + 1;
            }
        }
        i = i + 1;
    }
    return "";
}

// Get directory part of a file path (everything before last /)
fn dirname(path: string) -> string {
    slen := __builtin_str_len(path);
    last_slash : ., mut = -1;
    i : ., mut = 0;
    loop {
        if i >= slen { break; }
        if __builtin_str_eq(__builtin_str_get(path, i), "/") != 0 { last_slash = i; }
        i = i + 1;
    }
    if last_slash >= 0 {
        return __builtin_str_sub(path, 0, last_slash + 1);
    }
    return "";
}

// Try to load _import.cr from a directory, returns content or empty string
fn load_import_core(dir_path: string) -> string {
    imp_path : ., mut = dir_path + "_import.cr";
    content := __builtin_read_file(imp_path);
    if __builtin_str_len(content) > 0 {
        __builtin_print("  _import.cr: ");
        __builtin_println(imp_path);
    }
    return content;
}

fn build_line_fileid() {
    // Build line→fileid mapping by scanning g_source for newlines
    // and matching byte positions to segment boundaries.
    g_line_count = 0;
    slen := __builtin_str_len(g_source);
    seg_idx : ., mut = 0;
    g_line_fileid[g_line_count] = g_seg_fileids[0];
    g_line_count = g_line_count + 1;
    pos : ., mut = 0;
    loop {
        if pos >= slen { break; }
        if __builtin_str_eq(__builtin_str_get(g_source, pos), "\n") != 0 {
            next_start := 0;
            next_fileid := -1;
            if seg_idx + 1 < g_seg_count {
                next_start = g_seg_starts[seg_idx + 1];
                next_fileid = g_seg_fileids[seg_idx + 1];
            }
            // pos is the \n byte position; the next line starts at pos+1
            // If pos+1 >= next segment's start_byte, we've crossed the boundary
            if next_fileid >= 0 && pos + 1 >= next_start {
                seg_idx = seg_idx + 1;
            }
            g_line_fileid[g_line_count] = g_seg_fileids[seg_idx];
            g_line_count = g_line_count + 1;
        }
        pos = pos + 1;
    }
}

fn register_fileid(fileid_str: string, path: string) -> int {
    // Register a fileid in g_files, return its name index.
    // Check duplicates first.
    fni := str_intern(fileid_str);
    fi : ., mut = 0;
    loop {
        if fi >= g_file_count { break; }
        if g_files[fi].fileid_ni == fni {
            // Already registered with this fileid, return existing
            return fni;
        }
        fi = fi + 1;
    }
    if g_file_count < MAX_FILES {
        g_files[g_file_count] = FileEntry { fileid_ni = fni, path = path };
        g_file_count = g_file_count + 1;
    }
    return fni;
}

fn parent_dir(dir: string) -> string {
    // Remove trailing /
    slen := __builtin_str_len(dir);
    if slen <= 1 { return ""; }
    trimmed : ., mut = dir;
    last_ch := __builtin_str_get(dir, slen - 1);
    if __builtin_str_eq(last_ch, "/") != 0 {
        trimmed = __builtin_str_sub(dir, 0, slen - 1);
    }
    // Find last /
    last_slash : ., mut = -1;
    i : ., mut = 0;
    tlen := __builtin_str_len(trimmed);
    loop {
        if i >= tlen { break; }
        if __builtin_str_eq(__builtin_str_get(trimmed, i), "/") != 0 { last_slash = i; }
        i = i + 1;
    }
    if last_slash >= 0 {
        return __builtin_str_sub(trimmed, 0, last_slash + 1);
    }
    return "";
}

// Resolve imports: scan token stream for T_IMPORT/T_FILEID, load imported files,
// build file registry and segment boundaries for line→fileid mapping,
// append sources, re-tokenize.
fn resolve_imports() {
    g_file_count = 0;
    g_mod_count = 0;
    g_seg_count = 0;

    // Step 1: collect _import.cr from source directory and ancestor directories
    import_core_acc : ., mut = "";
    search_dir : ., mut = g_source_dir;
    loop {
        ic := load_import_core(search_dir);
        if __builtin_str_len(ic) > 0 {
            // Prepend: ancestors first, so closer overrides win
            import_core_acc = ic + "\n" + import_core_acc;
        }
        pd := parent_dir(search_dir);
        if __builtin_str_len(pd) == 0 { break; }
        if __builtin_str_eq(pd, search_dir) != 0 { break; }  // reached root
        search_dir = pd;
    }
    if __builtin_str_len(import_core_acc) > 0 {
        g_source = import_core_acc + "\n" + g_source;
        tokenize();
        __builtin_print("  _import.cr tokens: ");
        __builtin_println(__builtin_int_to_str(g_token_count));
    }

    // Determine main file's fileid from source (fileid "name;" or default "main")
    main_fileid_str : ., mut = extract_fileid(g_source);
    if __builtin_str_len(main_fileid_str) == 0 { main_fileid_str = "main"; }
    main_fni := register_fileid(main_fileid_str, "");
    main_len := __builtin_str_len(g_source);

    // First segment: main source [0, main_len)
    g_seg_starts[g_seg_count] = 0;
    g_seg_fileids[g_seg_count] = main_fni;
    g_seg_count = g_seg_count + 1;

    extra_src : ., mut = "";
    extra_bytes : ., mut = 0;  // total extra bytes added (excluding original g_source)

    // Scan imports
    i : ., mut = 0;
    loop {
        if i >= g_token_count { break; }
        tk := g_tokens[i].kind;

        if tk == T_IMPORT {
            // Parse: import [@project] fileid [: alias];
            pos : ., mut = i + 1;
            is_project : ., mut = false;
            project_name : ., mut = "";
            if pos < g_token_count && g_tokens[pos].kind == T_AT {
                is_project = true;
                pos = pos + 1;
                if pos < g_token_count && g_tokens[pos].kind == T_IDENT {
                    project_name = g_tokens[pos].lexeme;
                    pos = pos + 1;
                }
            }
            // Read the fileid
            import_fileid : ., mut = "";
            if pos < g_token_count && g_tokens[pos].kind == T_IDENT {
                import_fileid = g_tokens[pos].lexeme;
                pos = pos + 1;
            }
            // Read optional : alias
            alias_str : ., mut = "";
            if pos < g_token_count && g_tokens[pos].kind == T_COLON {
                pos = pos + 1;
                if pos < g_token_count && g_tokens[pos].kind == T_IDENT {
                    alias_str = g_tokens[pos].lexeme;
                    pos = pos + 1;
                }
            }
            // Resolve file path
            path : ., mut = "";
            content : ., mut = "";
            if __builtin_str_len(import_fileid) > 0 {
                if is_project {
                    // Validate project via Core.toml if accessible
                    proj_toml : ., mut = "src/" + project_name + "/Core.toml";
                    ptc := __builtin_read_file(proj_toml);
                    if __builtin_str_len(ptc) > 0 {
                        pn := extract_toml_name(ptc);
                        if __builtin_str_len(pn) > 0 && __builtin_str_eq(pn, project_name) == 0 {
                            __builtin_print("  warning: @");
                            __builtin_print(project_name);
                            __builtin_print(" toml name='");
                            __builtin_print(pn);
                            __builtin_println("' mismatch");
                        }
                    }
                    path = "src/" + project_name + "/" + import_fileid + ".cr";
                    content = __builtin_read_file(path);
                } else {
                    // Search order: source dir → src/stdlib/ → current dir
                    path = g_source_dir + import_fileid + ".cr";
                    content = __builtin_read_file(path);
                    if __builtin_str_len(content) == 0 {
                        path = "src/stdlib/" + import_fileid + ".cr";
                        content = __builtin_read_file(path);
                    }
                    if __builtin_str_len(content) == 0 {
                        path = import_fileid + ".cr";
                        content = __builtin_read_file(path);
                    }
                }
            }
            // Process if content was loaded
            if __builtin_str_len(content) > 0 {
                content_len := __builtin_str_len(content);
                // Determine fileid for loaded file
                loaded_fid : ., mut = extract_fileid(content);
                if __builtin_str_len(loaded_fid) == 0 { loaded_fid = import_fileid; }
                loaded_fni := register_fileid(loaded_fid, path);
                // Track segment boundary for this file's content
                // It will be at: main_len + extra_bytes + 1 (after the \n separator)
                seg_byte := main_len + extra_bytes + 1;
                g_seg_starts[g_seg_count] = seg_byte;
                g_seg_fileids[g_seg_count] = loaded_fni;
                g_seg_count = g_seg_count + 1;
                extra_bytes = extra_bytes + 1 + content_len;
                // Register alias
                alias_ni : ., mut = -1;
                if __builtin_str_len(alias_str) > 0 {
                    alias_ni = str_intern(alias_str);
                } else {
                    // Default alias = loaded fileid
                    alias_ni = loaded_fni;
                }
                if g_mod_count < MAX_MODS {
                    g_mods[g_mod_count] = ModEntry { alias_ni = alias_ni, fileid_ni = loaded_fni, path = path };
                    g_mod_count = g_mod_count + 1;
                }
                extra_src = extra_src + "\n" + content;
            }
        }
        i = i + 1;
    }
    if __builtin_str_len(extra_src) > 0 {
        g_source = g_source + extra_src;  // extra_src starts with \n
        tokenize();
        __builtin_print("  re-tokenized: ");
        __builtin_println(__builtin_int_to_str(g_token_count));
    }
    build_line_fileid();
}
