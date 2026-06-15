// === main.cr ===
// Compiler entry point: CLI, pipeline orchestration, and test API.

// Global flags for project/directory mode
g_is_project_mode : int, mut;
g_ccr_out_path : string, mut;
g_cir_out_path : string, mut;
g_binary_out_path : string, mut;

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

// Detect imports (uses resolve_imports which is already called before this point)
fn detect_imports(src: string) -> int {
    sl := __builtin_str_len(src); i : ., mut = 0; cnt : ., mut = 0;
    loop { if i + 6 >= sl { break; }
        if __builtin_load8(src,i) == 105 && __builtin_load8(src,i+1) == 109 &&
           __builtin_load8(src,i+2) == 112 && __builtin_load8(src,i+3) == 111 &&
           __builtin_load8(src,i+4) == 114 && __builtin_load8(src,i+5) == 116 {
            cnt = cnt + 1;
            i = i + 6; continue; }
        i = i + 1; }
    return cnt;
}

fn corec_main() -> int {
    cli_init("corec", "Core compiler frontend");
    cli_flag_bool("cir", "", "Output dataflow graph (.cir)");
    cli_flag_bool("ccr", "", "Output linear CFG (.ccr) [default]");
    cli_flag_bool("check", "", "Type-check only, no output");
    cli_flag_bool("c", "", "Execute code directly (interpreter mode)");
    cli_flag_bool("build", "b", "Compile and link to ELF (auto-detect imports)");
    cli_flag("output", "o", "Output path");

    if cli_parse() != 0 { return 1; }
    if cli_arg_count() < 1 {
        __builtin_println("usage: corec <file.cr | project_dir/ | -c code> [options]");
        __builtin_println("  compile Core source to .ccr or .cir, or run with -c");
        __builtin_println("  -c CODE   execute code directly (interpreter)");
        __builtin_println("  --cir     output dataflow graph (.cir)");
        __builtin_println("  --ccr     output linear CFG (.ccr) [default]");
        __builtin_println("  --check   type-check only");
        __builtin_println("  -o FILE   output path");
        __builtin_println("");
        __builtin_println("project_dir/  point to a directory containing Core.toml + .cr files");
        __builtin_println("              to build a multi-file project");
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
        // 检测是否为项目目录（路径不以 .cr 结尾 → 尝试项目构建）
        sl := __builtin_str_len(src_path);
        g_is_project_mode = 0;
        if sl >= 4 {
            ext := __builtin_str_sub(src_path, sl - 3, 3);
            if __builtin_str_eq(ext, ".cr") == 0 { g_is_project_mode = 1; }
        } else {
            g_is_project_mode = 1;  // 没有 .cr 扩展名，可能是目录名
        }

        if g_is_project_mode != 0 {
            g_source = read_project_dir(src_path);
            if __builtin_str_len(g_source) > 0 {
            } else {
                // 项目加载失败，回退到文件模式
                g_is_project_mode = 0;
                g_source = __builtin_read_file(src_path);
                if __builtin_str_len(g_source) == 0 {
                    __builtin_print("error: cannot read ");
                    __builtin_println(src_path);
                    return 1;
                }
                g_source_dir = dirname(src_path);
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
    }

    // Frontend pipeline
    tokenize();
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

    build_mode := cli_has("build");
    if build_mode != 0 && check_only == 0 && eval_mode == 0 {
        // --build: compile + link to ELF in one step
        // Auto-detect imports for linking
        links := detect_imports(g_source);
        // Determine output path
        out_path : ., mut = cli_get("output");
        if __builtin_str_len(out_path) == 0 {
            if g_is_project_mode != 0 { out_path = basename(src_path); }
            else {
                sp := src_path; slen := __builtin_str_len(sp);
                if slen > 3 { ext := __builtin_str_sub(sp, slen-3, 3);
                    if __builtin_str_eq(ext, ".cr") != 0 { out_path = __builtin_str_sub(sp, 0, slen-3); }
                    else { out_path = sp; } }
                else { out_path = sp; } }
        }
        // Save .ccr to temp file
        tmp_path : ., mut = "/tmp/corec_build_";
        tmp_path = tmp_path + __builtin_int_to_str(__builtin_syscall3(201, 0, 0, 0));  // getpid
        tmp_path = tmp_path + ".ccr";
        ir_gen_all();
        lower_to_ccr();
        r := save_ccr(tmp_path);
        if r != 0 { __builtin_println("error: could not write temp .ccr"); return 1; }
        // Build corearch command (static ELF — imports resolved at compile time)
        cmd : ., mut = "corearch ";
        cmd = cmd + tmp_path + " --elf -o " + out_path;
        // Also try using the same directory as corec
        self_path := __builtin_get_arg(0);
        sl2 := __builtin_str_len(self_path);
        if sl2 > 0 {
            last_slash : ., mut = -1;
            si : ., mut = 0; loop { if si >= sl2 { break; }
                if __builtin_load8(self_path, si) == 47 { last_slash = si; } si = si + 1; }
            if last_slash >= 0 {
                dir2 := __builtin_str_sub(self_path, 0, last_slash + 1);
                cmd = dir2 + cmd; }
        }
        // Execute!
        exit_code := system(cmd);
        // Cleanup
        __builtin_syscall3(87, tmp_path, 0, 0);  // unlink temp .ccr
        return exit_code;
    }

    ir_gen_all();

    if eval_mode != 0 {
        return ir_interpret();
    }

    if emit_cir != 0 {
        dot := df_graph_to_dot();
        out := cli_get("output");
        if __builtin_str_len(out) == 0 {
            if g_is_project_mode != 0 {
                out = basename(src_path) + ".cir";
            } else {
                out = src_path;
                sl := __builtin_str_len(src_path);
                if sl > 3 {
                    ext := __builtin_str_sub(src_path, sl - 3, 3);
                    if __builtin_str_eq(ext, ".cr") != 0 {
                        out = __builtin_str_sub(src_path, 0, sl - 3) + ".cir";
                    }
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
            if g_is_project_mode != 0 {
                out = basename(src_path) + ".ccr";
            } else {
                out = src_path;
                sl := __builtin_str_len(src_path);
                if sl > 3 {
                    ext := __builtin_str_sub(src_path, sl - 3, 3);
                    if __builtin_str_eq(ext, ".cr") != 0 {
                        out = __builtin_str_sub(src_path, 0, sl - 3) + ".ccr";
                    }
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

// Full compilation: source -> assembly (used by tests and programmatic API)
fn compile_source(source: string) -> string {
    g_source = source;
    tokenize();
    resolve_imports();
    parse_all();
    check_all();
    if g_diag_count > 0 {
        err_msg : ., mut = "check errors:";
        ei : ., mut = 0;
        loop {
            if ei >= g_diag_count { break; }
            diag_code := r64(g_diags, ei * 32);
            diag_msg := __builtin_load_str_ptr(g_diags, ei * 32 + 8);
            err_msg = err_msg + " [" + __builtin_int_to_str(diag_code) + "] " + diag_msg;
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
