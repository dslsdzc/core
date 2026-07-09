// === main.cr ===
// Compiler entry point: CLI, pipeline orchestration, and test API.

// Global flags for project/directory mode
g_is_project_mode : int, mut;
g_ccr_out_path : string, mut;
g_cir_out_path : string, mut;
g_binary_out_path : string, mut;

fn is_cr_file(path: string) -> int {
    slen := str_len(path);
    if slen < 3 { return 0; }
    ext := str_sub(path, slen - 3, 3);
    if str_eq(ext, ".cr") != 0 { return 1; }
    return 0;
}

fn read_source_file(path: string) -> string {
    g_source_dir = dirname(path);
    source := read_file(path);
    if str_len(source) > 0 {
    }
    return source;
}

fn read_project_dir(dir: string) -> string {
    cfg := load_project(dir);
    g_source_dir = cfg.source_dir;
    if str_len(cfg.main_source) > 0 {
        print_project_info(cfg);
        return cfg.main_source;
    }
    println("error: no main.cr found in directory");
    return "";
}

fn is_decl_stmt(s: string) -> int {
    slen := str_len(s);
    i : ., mut = 0;
    loop {
        if i >= slen { return 0; }
        cb := load8(s, i);
        if cb == 32 || cb == 9 || cb == 10 || cb == 13 { i = i + 1; }
        else { break; }
    }
    if i < slen {
        cb := load8(s, i);
        if (cb >= 97 && cb <= 122) || (cb >= 65 && cb <= 90) || cb == 95 {
            j : ., mut = i + 1;
            loop {
                if j >= slen { return 0; }
                c2b := load8(s, j);
                if c2b == 32 || c2b == 9 || c2b == 10 || c2b == 13 { j = j + 1 }
                else if c2b == 58 { return 1; }
                else if (c2b >= 97 && c2b <= 122) || (c2b >= 65 && c2b <= 90) || (c2b >= 48 && c2b <= 57) || c2b == 95 { j = j + 1 }
                else { return 0; }
            }
        }
    }
    return 0;
}

// Detect imports (uses res_imports which is already called before this point)
fn detect_imports(src: string) -> int {
    sl := str_len(src); i : ., mut = 0; cnt : ., mut = 0;
    loop { if i + 6 >= sl { break; }
        if load8(src,i) == 105 && load8(src,i+1) == 109 &&
           load8(src,i+2) == 112 && load8(src,i+3) == 111 &&
           load8(src,i+4) == 114 && load8(src,i+5) == 116 {
            cnt = cnt + 1;
            i = i + 6; continue; }
        i = i + 1; }
    return cnt;
}

// Read source from a file path or project directory; returns 0 on success
fn read_source_or_project(src_path: string) -> int {
    sl := str_len(src_path);
    g_is_project_mode = 0;
    if sl >= 4 {
        ext := str_sub(src_path, sl - 3, 3);
        if str_eq(ext, ".cr") == 0 { g_is_project_mode = 1; }
    } else {
        g_is_project_mode = 1;
    }

    if g_is_project_mode != 0 {
        g_source = read_project_dir(src_path);
        if str_len(g_source) > 0 {
            return 0;
        }
        g_is_project_mode = 0;
        g_source = read_file(src_path);
        if str_len(g_source) == 0 {
            print("error: cannot read ");
            println(src_path);
            return 1;
        }
        g_source_dir = dirname(src_path);
        return 0;
    }

    g_source = read_file(src_path);
    if str_len(g_source) == 0 {
        print("error: cannot read ");
        println(src_path);
        return 1;
    }
    g_source_dir = dirname(src_path);
    return 0;
}

// Run the shared frontend pipeline: tokenize → resolve → parse → check
// Returns 0 on success, 1 on error.
fn run_frontend() -> int {
    println("[1/5] tokenize...");
    tokenize(g_source);
    println("[2/5] resolve imports...");
    res_imports();
    println("[3/5] parse...");
    parse_all();
    if g_diag_count > 0 { print_diagnostics(); return 1; }
    if g_error_count > 0 { print_parse_errors(); return 1; }
    println("[4/5] type check...");
    check_all();
    // Diagnostics are non-fatal (match Python bootstrap behavior)
    if g_diag_count > 0 { print_diagnostics(); }
    // AST-level constant folding and optimization (O1+)
    /*
if g_opt_level >= 1 && g_func_count > 0 {
        fi : ., mut = 0;
        loop { if fi >= g_func_count { break; }
            fn_node := fi_ast_node(fi);
            body := ast_data(fn_node);
            ast_optimize_body(body);
        fi = fi + 1; }
    }
    
*/
        println("[5/5] frontend done");
    return 0;
}

// Determine default output path from source path (strip .cr, add extension)
fn default_out_path(src_path: string, ext: string) -> string {
    out : ., mut = "";
    if g_is_project_mode != 0 {
        out = basename(src_path) + ext;
    } else {
        out = src_path;
        sl := str_len(src_path);
        if sl > 3 {
            e := str_sub(src_path, sl - 3, 3);
            if str_eq(e, ".cr") != 0 {
                out = str_sub(src_path, 0, sl - 3) + ext;
            }
        }
    }
    return out;
}

fn corec_main() -> int {
    cli_init("corec", "Core compiler frontend");
    cli_cmd("build", "Compile .cr or directory to ELF binary");
    cli_cmd("check", "Type-check only, no output");
    cli_cmd("cir",   "Output dataflow graph (.cir)");
    cli_cmd("ccr",   "Output linear CFG (.ccr)");
    cli_cmd("run",   "Execute code directly (interpreter mode)");
    cli_flag("output", "o", "Output path");
    cli_flag_bool("static", "", "Static linking (embed runtime)");
    cli_flag("opt-level", "O", "Optimization level (0,1,2,3; default=1)");

    if cli_parse() != 0 { return 1; }
    // Parse -O flag (default O1)
    g_opt_level = 1;
    ol : ., mut = cli_get("opt-level");
    if str_len(ol) > 0 { g_opt_level = str_int(ol); if g_opt_level > 3 { g_opt_level = 3; } if g_opt_level < 0 { g_opt_level = 0; } }
    cmd := cli_cmd_name();

    if str_len(cmd) == 0 {
        cli_help();
        println("");
        println("examples:");
        println("  corec build file.cr          compile to ELF binary");
        println("  corec check file.cr          type-check only");
        println("  corec cir file.cr            dump dataflow graph");
        println("  corec ccr file.cr            dump linear CFG");
        println("  corec run 'code'             execute directly");
        return 1;
    }

    // === run subcommand — inline code, no file ===
    if cli_eq(cmd, "run") {
        if cli_arg_count() < 1 {
            println("error: run requires code to execute");
            println("usage: corec run '<code>'");
            return 1;
        }
        g_source = cli_arg(0);
        g_source_dir = dirname(cli_arg(0));

        // Check if source already has 'fn main'
        has_main : ., mut = 0;
        si2 : ., mut = 0;
        sl2 := str_len(g_source);
        loop {
            if si2 >= sl2 { break; }
            c0 := load8(g_source, si2);
            if c0 == 102 {
                if si2 + 6 < sl2 {
                    if load8(g_source, si2)     == 102 &&
                       load8(g_source, si2 + 1) == 110 &&
                       load8(g_source, si2 + 2) == 32  &&
                       load8(g_source, si2 + 3) == 109 &&
                       load8(g_source, si2 + 4) == 97  &&
                       load8(g_source, si2 + 5) == 105 &&
                       load8(g_source, si2 + 6) == 110 {
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
            ilen := str_len(g_source);
            loop {
                if ii >= ilen { break; }
                if ii + 6 < ilen {
                    c := load8(g_source, ii);
                    c_prev : ., mut = 59;
                    if ii > 0 { c_prev = load8(g_source, ii - 1); }
                    if (ii == 0 || c_prev == 59 || c_prev == 10) &&
                       load8(g_source, ii)     == 105 &&
                       load8(g_source, ii + 1) == 109 &&
                       load8(g_source, ii + 2) == 112 &&
                       load8(g_source, ii + 3) == 111 &&
                       load8(g_source, ii + 4) == 114 &&
                       load8(g_source, ii + 5) == 116 {
                        ij : ., mut = ii;
                        loop {
                            if ij >= ilen { break; }
                            if load8(g_source, ij) == 59 { ij = ij + 1; break; }
                            ij = ij + 1;
                        }
                        imports = imports + str_sub(g_source, ii, ij - ii);
                        ii = ij;
                        continue;
                    }
                }
                src2 = src2 + get_char(g_source, ii);
                ii = ii + 1;
            }
            g_source = src2;

            has_semi : ., mut = 0;
            si2 : ., mut = 0;
            loop {
                if si2 >= str_len(g_source) { break; }
                if get_char(g_source, si2) == ";" { has_semi = 1; break; }
                si2 = si2 + 1;
            }
            if has_semi != 0 {
                last_semi : ., mut = -1;
                ls : ., mut = 0;
                loop {
                    if ls >= str_len(g_source) { break; }
                    if get_char(g_source, ls) == ";" { last_semi = ls; }
                    ls = ls + 1;
                }
                if last_semi >= 0 {
                    last_expr := str_sub(g_source, last_semi + 1,
                        str_len(g_source) - last_semi - 1);
                    body := str_sub(g_source, 0, last_semi + 1);
                    if is_decl_stmt(last_expr) != 0 {
                        g_source = imports + "fn main() -> int {\n" + body + "\n" + last_expr + ";\nreturn 0;\n}\n";
                    } else {
                        has_lcall : ., mut = 0;
                        lci : ., mut = 0;
                        lclen := str_len(last_expr);
                        loop {
                            if lci >= lclen { break; }
                            if load8(last_expr, lci) == 40 { has_lcall = 1; break; }
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
                    clen := str_len(g_source);
                    loop {
                        if ci3 >= clen { break; }
                        if load8(g_source, ci3) == 40 { has_call = 1; break; }
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

        if run_frontend() != 0 { return 1; }
        ir_gen_all();
        return ir_interpret();
    }

    // === File-based subcommands: build | check | cir | ccr ===
    if cli_arg_count() < 1 {
        print("error: ");
        print(cmd);
        println(" requires a source file or directory");
        return 1;
    }
    src_path := cli_arg(0);

    if read_source_or_project(src_path) != 0 { return 1; }

    // --static: prepend rt.cr so * functions inline
    if cli_has("static") != 0 {
        rt_src := read_file("src/runtime/rt.cr");
        if str_len(rt_src) > 0 { g_source = rt_src + "\n" + g_source; }
    }

    if run_frontend() != 0 { return 1; }

    // === check: type-check only ===
    if cli_eq(cmd, "check") {
        println("ok");
        return 0;
    }

    // === build | cir | ccr all need IR gen ===
    println("ir gen...");
    ir_gen_all();

    // === cir: output dataflow graph ===
    if cli_eq(cmd, "cir") {
        dot := df_graph_to_dot();
        out := cli_get("output");
        if str_len(out) == 0 {
            out = default_out_path(src_path, ".cir");
        }
        written := write_file(out, dot);
        if written < 0 {
            print("error: could not write ");
            println(out);
            return 1;
        }
        print(" -> ");
        println(out);
        return 0;
    }

    // === build | ccr need lower_to_ccr ===
    if g_opt_level >= 1 {
        pass_cse();
        alloc_registers();
        if g_opt_level >= 2 { pass_stack_share(); }
    }
    println("lower to ccr...");
    lower_to_ccr();
    print("lower done: ");
    print(int_str(g_ir_func_count));
    print(" funcs, ");
    print(int_str(g_ir_instr_count));
    println(" instrs");

    // === ccr: output linear CFG ===
    if cli_eq(cmd, "ccr") {
        out := cli_get("output");
        if str_len(out) == 0 {
            out = default_out_path(src_path, ".ccr");
        }
        r := save_ccr(out);
        if r != 0 {
            print("error: could not write ");
            println(out);
            return 1;
        }
        print(" -> ");
        print(out);
        print(" (");
        print(int_str(g_ir_func_count));
        print(" funcs, ");
        print(int_str(g_ir_instr_count));
        println(" instrs)");
        return 0;
    }

    // === build: compile + link to ELF ===
    out_path : ., mut = cli_get("output");
    if str_len(out_path) == 0 {
        if g_is_project_mode != 0 { out_path = basename(src_path); }
        else {
            sp := src_path;
            slen := str_len(sp);
            if slen > 3 {
                ext := str_sub(sp, slen - 3, 3);
                if str_eq(ext, ".cr") != 0 { out_path = str_sub(sp, 0, slen - 3); }
                else { out_path = sp; }
            } else { out_path = sp; }
        }
    }
    // Save .ccr alongside output (real IR artifact)
    println("save .ccr...");
    ccr_path : ., mut = out_path + ".ccr";
    r := save_ccr(ccr_path);
    if r != 0 { println("error: could not write .ccr"); return 1; }
    println("generate ELF...");
    // Call corearch to produce ELF
    cmd2 : ., mut = "corearch ";
    cmd2 = cmd2 + ccr_path + " --elf";
    if g_opt_level > 0 { cmd2 = cmd2 + " --opt-level " + int_str(g_opt_level); }
    if cli_has("static") != 0 {
        cmd2 = cmd2 + " --static";
    } else {
        cmd2 = cmd2 + " --link auto";
    }
    cmd2 = cmd2 + " -o " + out_path;
    self_path := get_arg(0);
    sl2 := str_len(self_path);
    if sl2 > 0 {
        last_slash : ., mut = -1;
        si : ., mut = 0; loop { if si >= sl2 { break; }
            if load8(self_path, si) == 47 { last_slash = si; } si = si + 1; }
        if last_slash >= 0 {
            dir2 := str_sub(self_path, 0, last_slash + 1);
            cmd2 = dir2 + cmd2;
        }
    }
    exit_code := system(cmd2);
    return exit_code;
}

// Full compilation: source -> assembly (used by tests and programmatic API)
fn compile_source(source: string) -> string {
    g_source = source;
    tokenize(g_source);
    res_imports();
    parse_all();
    check_all();
    if g_diag_count > 0 {
        err_msg : ., mut = "check errors:";
        ei : ., mut = 0;
        loop {
            if ei >= g_diag_count { break; }
            diag_code := r64(g_diags, ei * 32);
            diag_msg := load_str_ptr(g_diags, ei * 32 + 8);
            err_msg = err_msg + " [" + int_str(diag_code) + "] " + diag_msg;
            ei = ei + 1;
        }
        return err_msg;
    }
    ir_gen_all();
    lower_to_ccr();
    return "ok";
}

// Entry point
fn compiler_main() -> int {
    return corec_main();
}
