// === main.cr ===
// Compiler entry point: CLI, pipeline orchestration, and test API.

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
    }
    return source;
}

fn read_project_dir(dir: string) -> string {
    cfg := load_project(dir);
    g_source_dir = cfg.source_dir;
    if __builtin_str_len(cfg.main_source) > 0 {
        print_project_info(cfg);
        return cfg.main_source;
    }
    __builtin_println("error: no main.cr found in directory");
    return "";
}

fn is_decl_stmt(s: string) -> int {
    slen := __builtin_str_len(s);
    i : ., mut = 0;
    loop {
        if i >= slen { return 0; }
        cb := __builtin_load8(s, i);
        if cb == 32 || cb == 9 || cb == 10 || cb == 13 { i = i + 1; }
        else { break; }
    }
    if i < slen {
        cb := __builtin_load8(s, i);
        if (cb >= 97 && cb <= 122) || (cb >= 65 && cb <= 90) || cb == 95 {
            j : ., mut = i + 1;
            loop {
                if j >= slen { return 0; }
                c2b := __builtin_load8(s, j);
                if c2b == 32 || c2b == 9 || c2b == 10 || c2b == 13 { j = j + 1 }
                else if c2b == 58 { return 1; }
                else if (c2b >= 97 && c2b <= 122) || (c2b >= 65 && c2b <= 90) || (c2b >= 48 && c2b <= 57) || c2b == 95 { j = j + 1 }
                else { return 0; }
            }
        }
    }
    return 0;
}

fn corec_main() -> int {
    cli_init("corec", "Core compiler frontend");
    cli_flag_bool("cir", "", "Output dataflow graph (.cir)");
    cli_flag_bool("ccr", "", "Output linear CFG (.ccr) [default]");
    cli_flag_bool("check", "", "Type-check only, no output");
    cli_flag_bool("c", "", "Execute code directly (interpreter mode)");
    cli_flag("output", "o", "Output path");

    if cli_parse() != 0 { return 1; }
    if cli_arg_count() < 1 {
        __builtin_println("usage: corec <file.cr | -c code> [options]");
        __builtin_println("  compile Core source to .ccr or .cir, or run with -c");
        __builtin_println("  -c CODE   execute code directly (interpreter)");
        __builtin_println("  --cir     output dataflow graph (.cir)");
        __builtin_println("  --ccr     output linear CFG (.ccr)");
        __builtin_println("  --check   type-check only");
        __builtin_println("  -o FILE   output path");
        return 1;
    }

    eval_mode := cli_has("c");
    src_path := cli_arg(0);
    emit_cir := cli_has("cir");
    check_only := cli_has("check");

    if eval_mode != 0 {
        g_source = src_path;
        g_source_dir = dirname(src_path);
        has_main : ., mut = 0;
        si2 : ., mut = 0;
        sl2 := __builtin_str_len(g_source);
        loop {
            if si2 >= sl2 { break; }
            c0 := __builtin_load8(g_source, si2);
            if c0 == 102 {
                if si2+6 < sl2 {
                    if __builtin_load8(g_source, si2) == 102 &&
                       __builtin_load8(g_source, si2+1) == 110 &&
                       __builtin_load8(g_source, si2+2) == 32 &&
                       __builtin_load8(g_source, si2+3) == 109 &&
                       __builtin_load8(g_source, si2+4) == 97 &&
                       __builtin_load8(g_source, si2+5) == 105 &&
                       __builtin_load8(g_source, si2+6) == 110 {
                        has_main = 1;
                        break;
                    }
                }
            }
            si2 = si2 + 1;
        }
        if has_main == 0 {
            imports : ., mut = "";
            src2 : ., mut = "";
            ii : ., mut = 0;
            ilen := __builtin_str_len(g_source);
            loop {
                if ii >= ilen { break; }
                if ii + 6 < ilen {
                    c := __builtin_load8(g_source, ii);
                    c_prev : ., mut = 59;
                    if ii > 0 { c_prev = __builtin_load8(g_source, ii-1); }
                    if (ii == 0 || c_prev == 59 || c_prev == 10) &&
                       __builtin_load8(g_source, ii) == 105 &&
                       __builtin_load8(g_source, ii+1) == 109 &&
                       __builtin_load8(g_source, ii+2) == 112 &&
                       __builtin_load8(g_source, ii+3) == 111 &&
                       __builtin_load8(g_source, ii+4) == 114 &&
                       __builtin_load8(g_source, ii+5) == 116 {
                        ij : ., mut = ii;
                        loop {
                            if ij >= ilen { break; }
                            if __builtin_load8(g_source, ij) == 59 { ij = ij + 1; break; }
                            ij = ij + 1;
                        }
                        imports = imports + __builtin_str_sub(g_source, ii, ij - ii);
                        ii = ij;
                        continue;
                    }
                }
                src2 = src2 + __builtin_str_get(g_source, ii);
                ii = ii + 1;
            }
            g_source = src2;

            has_semi : ., mut = 0;
            si2 : ., mut = 0;
            loop { if si2 >= __builtin_str_len(g_source) { break; } if __builtin_str_get(g_source, si2) == ";" { has_semi = 1; break; } si2 = si2 + 1; }
            if has_semi != 0 {
                last_semi : ., mut = -1;
                ls : ., mut = 0;
                loop { if ls >= __builtin_str_len(g_source) { break; } if __builtin_str_get(g_source, ls) == ";" { last_semi = ls; } ls = ls + 1; }
                if last_semi >= 0 {
                    last_expr := __builtin_str_sub(g_source, last_semi + 1, __builtin_str_len(g_source) - last_semi - 1);
                    body := __builtin_str_sub(g_source, 0, last_semi + 1);
                    if is_decl_stmt(last_expr) != 0 {
                        g_source = imports + "fn main() -> int {\n" + body + "\n" + last_expr + ";\nreturn 0;\n}\n";
                    } else {
                        has_lcall : ., mut = 0;
                        lci : ., mut = 0;
                        lclen := __builtin_str_len(last_expr);
                        loop {
                            if lci >= lclen { break; }
                            if __builtin_load8(last_expr, lci) == 40 { has_lcall = 1; break; }
                            lci = lci + 1;
                        }
                        if has_lcall != 0 {
                            g_source = imports + "fn main() -> int {\n" + body + last_expr + ";\nreturn 0;\n}\n";
                        } else {
                            g_source = imports + "fn main() -> int {\n" + body + "\nreturn " + last_expr + ";\n}\n";
                        }
                    }
                } else {
                    g_source = imports + "fn main() -> int {\n" + g_source + ";\nreturn 0;\n}\n";
                }
            } else {
                if is_decl_stmt(g_source) != 0 {
                    g_source = imports + "fn main() -> int {\n" + g_source + ";\nreturn 0;\n}\n";
                } else {
                    has_call : ., mut = 0;
                    ci3 : ., mut = 0;
                    clen := __builtin_str_len(g_source);
                    loop {
                        if ci3 >= clen { break; }
                        if __builtin_load8(g_source, ci3) == 40 { has_call = 1; break; }
                        ci3 = ci3 + 1;
                    }
                    if has_call != 0 {
                        g_source = imports + "fn main() -> int {\n" + g_source + ";\nreturn 0;\n}\n";
                    } else {
                        g_source = imports + "fn main() -> int {\nreturn " + g_source + ";\n}\n";
                    }
                }
            }
        }
    } else {
        g_source = __builtin_read_file(src_path);
        if __builtin_str_len(g_source) == 0 {
            __builtin_print("error: cannot read ");
            __builtin_println(src_path);
            return 1;
        }
        g_source_dir = dirname(src_path);
    }

    // Frontend pipeline
    tokenize();
    g_str_count = 0;
    resolve_imports();
    parse_all();
    __builtin_print(__builtin_int_to_str(g_diag_count));
    __builtin_print(" err=");
    __builtin_print(__builtin_int_to_str(g_error_count));
    __builtin_print("\n");
    if g_diag_count > 0 { print_diagnostics(); return 1; }
    if g_error_count > 0 { print_parse_errors(); return 1; }
    check_all();
    if g_diag_count > 0 { print_diagnostics(); return 1; }

    if check_only != 0 {
        __builtin_println("ok");
        return 0;
    }

    ir_gen_all();

    if eval_mode != 0 {
        return ir_interpret();
    }

    if emit_cir != 0 {
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
        __builtin_print(" ("));
        __builtin_print(__builtin_int_to_str(g_ir_func_count));
        __builtin_print(" funcs, ");
        __builtin_print(__builtin_int_to_str(g_ir_instr_count));
        __builtin_println(" instrs)");
    }

    return 0;
}

// Full compilation: source -> assembly (used by tests and programmatic API)
fn compile_source(source: string) -> string {
    g_source = source;
    tokenize();
    g_str_count = 0;
    resolve_imports();
    parse_all();
    check_all();
    if g_diag_count > 0 {
        err_msg : ., mut = "check errors:";
        ei : ., mut = 0;
        loop {
            if ei >= g_diag_count { break; }
            err_msg = err_msg + " [" + __builtin_int_to_str(g_diags[ei].code) + "] " + g_diags[ei].msg;
            ei = ei + 1;
        }
        return err_msg;
    }
    ir_gen_all();
    lower_to_ccr();
    return x86_64_generate();
}

// Entry point
fn compiler_main() -> int {
    return corec_main();
}
