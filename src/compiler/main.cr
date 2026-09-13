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
    source := load_project(dir);
    g_source_dir = g_project_source_dir;
    if str_len(source) > 0 {
        return source;
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

fn read_static_runtime_source() -> string {
    source := read_file("src/runtime/rt.cr");
    if str_len(source) > 0 { return source; }

    exe_path := get_exe_path();
    exe_dir := dirname(exe_path);
    if str_len(exe_dir) > 0 {
        source = read_file(exe_dir + "../src/runtime/rt.cr");
    }
    return source;
}

// Run the shared frontend pipeline: tokenize → resolve → parse → check
// Returns 0 on success, 1 on error.
fn run_frontend() -> int {
    g_error_count = 0;  // 会话起点清词法/语法错误（tokenize 多轮累积，见 lexer.cr）
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
    // Type-check diagnostics are non-fatal (match Python bootstrap behavior).
    // Only parse errors and resolver errors are fatal.
    // 例外（F2）：编译期确定的常量索引越界（R002）与字面量切片界越界（TK05/TK06）
    // 是硬错误——拦截编译（修复前静默生成越界二进制）。
    // 例外（TODO #29）：聚合字面量三校验（TS01-04 + TK02）同为硬错误——修复前全部 rc=0
    // 静默通过并照常产出二进制：未知字段/缺字段 ⇒ 字段从未被写入（读到垃圾值）、字段类型
    // 不匹配 ⇒ 按错宽度存（静默错值）、数组元素异质 ⇒ 类型随末元素漂移（soundness 漏放）。
    // 判定继续 = 产出**静默错产物**，与 R002 同类。
    if g_diag_count > 0 {
        hard : ., mut = 0;
        di : ., mut = 0;
        loop {
            if di >= g_diag_count { break; }
            ec := r64(g_diags, di * DIAG_REC_SIZE);
            if ec == EC_R_OOB || ec == EC_TK_SLICE_BOUNDS || ec == EC_TK_SLICE_LEN { hard = 1; }
            if ec == EC_TS_MISSING_FIELD || ec == EC_TS_UNKNOWN_FIELD || ec == EC_TS_FIELD_TYPE || ec == EC_TS_FIELD_DUP { hard = 1; }
            if ec == EC_TK_ELEM_TYPE { hard = 1; }
            // 例外（R2 P3 Task 3）：match 非穷尽（TM03）为硬错误——穷尽性判定的消费面。
            // 修复前 match **零检查**（EC_TM_* 仅定义零 raise）：缺臂 ⇒ rc=0 + 产物照出，
            // 未匹配值静默得 0（探针 p1b 实测 rc=100 = 0 + 100，无任何信号）。开门依据 =
            // 全语料 report-only 清单为空（72 档 check 日志与基线逐字节同，见 Task 3 报告 §）。
            // TM04（冗余臂）**不入**本名单 = 软面登记（同 Rust unreachable-pattern 的警告口径）。
            if ec == EC_TM_EXHAUST { hard = 1; }
            // 例外（R2 P5 Task 4 / P-A）：类型判定不可判（ICE04）为硬错误——三态纪律：
            // 「未知」不得当 0/1（legacy 回落面已删，判定 = 引擎唯一权威）⇒ 判定不可进行时
            // 产出的代码不可信（返回 false 只是 bool 面唯一保守出口，不是结论）⇒ 拒绝落盘。
            // 开门依据 = report-only 全语料零命中（72 档 check/shadow 日志与基线逐条同 +
            // `replace_*=0`；Task 3 Step 2 清零判据 + T3b 残留收口，见 p5-task4-report §1）。
            if ec == EC_ICE_TY_INDET { hard = 1; }
            di = di + 1;
        }
        print_diagnostics();
        if hard != 0 { return 1; }
    }
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
    // R2 P2a Task 3（C-4）：侧表 ↔ res_type_node 管线内断言（隐藏调试通道，默认关）。
    // 必须跑在 check_all 之后（类型表/侧表已成型）；不一致 → rc≠0（判据可挂）。默认关 =
    // 一次全局读 + 返回（产物/输出零影响）。
    if cli_has("verify-named-dedup") != 0 {
        if named_dedup_verify() != 0 { return 1; }
    }
    // R2 P3 Task 4：枚举载荷**类型节点**列入库断言（隐藏调试通道，默认关；与上一条同址同式）。
    // 断言 = 每个载荷槽都有类型节点（parser 同写；缺口复发即 rc≠0）；`collapses` 计数 = 裸码
    // 列丢失真实载荷类型的槽数（信息量，非失败）。见 ty_shadow.cr 的 sh_evp_verify。
    if cli_has("verify-evp-nodes") != 0 {
        if sh_evp_verify() != 0 { return 1; }
    }
    return 0;
}

// Determine default output path from source path (strip .cr, add extension)
fn default_out_path(src_path: string, ext: string) -> string {
    out : ., mut = "";
    if g_is_project_mode != 0 {
        out = g_project_name + ext;
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

// **R2 P5 Task 5 删除**：`sh_finish`（R2 P1 影子对拍收尾 = 摘要行 + `--type-shadow-dump` 时的
// 差异条目转储）与其两处调用点（run/build 路径各一）随影子通道整体下线；`--type-shadow` /
// `--type-shadow-dump` 两个 CLI 通道同删（D27）。运行期不再有任何影子收尾钩子。

fn corec_main() -> int {
    cli_init("corec", "Core compiler frontend");
    cli_cmd("build", "Compile .cr or directory to ELF binary");
    cli_cmd("check", "Type-check only, no output");
    cli_cmd("cir",   "Output dataflow graph (.cir)");
    cli_cmd("ccr",   "Output linear CFG (.ccr)");
    cli_cmd("run",   "Execute code directly (interpreter mode)");
    cli_cmd("clean-cache", "Delete incremental compilation cache");
    cli_cmd("selftest-types", "Run type-engine self tests (R2 P0)");
    cli_cmd("selftest-purity", "Run effect-purity self tests (Task 1)");
    cli_flag("output", "o", "Output path");
    cli_flag_bool("static", "", "Static linking (embed runtime)");
    cli_flag("opt-level", "O", "Optimization level (0,1,2,3; default=1) — O1 CSE(corec 进程内)；O2 寄存器分配+判定在 corearch（corec build 透传 --opt-level，.ccr 不承载分配结果）");
    cli_flag_bool("inject-var-shift", "", "Hidden debug: shift func0 var decl block left by 1, then save (GC-4 test hook)");
    cli_flag_bool("dump-types", "", "Hidden debug: dump TYPE segment content (row table + term DAG + cross-process judgment probe) after populate (R2 P4 Task 2 test channel)");
    cli_flag_bool("dump-ifaces", "", "Hidden debug: dump IFACE segment content (entry table + shapes + user ifaces + impls + method table + cross-segment term probe) after populate (R2 P4 Task 3 test channel)");
    cli_flag_bool("dump-tk-terms", "", "Hidden debug: dump per-DFNode tk + type-term slot (cir; R2 P4 Task 4 test channel — cold/warm snapshot symmetry)");
    // **R2 P5 Task 5 删除**：`--type-shadow` / `--type-shadow-dump`（R2 P1 影子对拍的两个隐藏
    // 通道）随影子层整体下线（D27/TODO #24 同族清偿）；判定路径不再有开关（无条件经引擎）。
    cli_flag_bool("verify-named-dedup", "", "R2 P2a: assert side-table == res_type_node for all named types (debug)");
    cli_flag_bool("verify-evp-nodes", "", "R2 P3 T4: assert enum variant payload type nodes recorded (debug)");

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

        run_rc := run_frontend();
        if run_rc != 0 { return 1; }
        ir_gen_all();
        return ir_interpret();
    }

    // === clean-cache: delete incremental compilation cache ===
    if cli_eq(cmd, "clean-cache") {
        system("rm -rf .core/cache/cir/");
        print("cleaned ");
        println(".core/cache/cir/");
        return 0;
    }

    // === selftest-types: 类型项引擎自测（R2 P0）——不读源文件、不产生产物 ===
    if cli_eq(cmd, "selftest-types") { return type_selftest_run(); }

    // === selftest-purity: 效应纯度自测（Task 1）——自建内联源 + 完整前端/IR ===
    if cli_eq(cmd, "selftest-purity") { return purity_selftest_run(); }

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
        rt_src := read_static_runtime_source();
        if str_len(rt_src) == 0 {
            println("error: cannot locate src/runtime/rt.cr");
            return 1;
        }
        g_source = rt_src + "\n" + g_source;
    }

    fe_rc := run_frontend();
    if fe_rc != 0 { return 1; }

    // === check: type-check only ===
    if cli_eq(cmd, "check") {
        // F19：type-check 诊断非致命（run_frontend 已打印，build 路径行为不变），
        // 但 check 命令必须以非零退出码反映诊断——修复前诊断后仍无条件 return 0。
        // 无诊断 → rc=0（"ok"）。
        if g_diag_count > 0 { return 1; }
        println("ok");
        return 0;
    }

    // === build | cir | ccr all need IR gen ===
    // Initialize IR state
    g_ir_var_count = 0;
    g_ir_instr_count = 0;
    g_ir_func_count = 0;
    g_ir_local_count = 0;
    g_ir_local_depth = 0;
    g_ir_global_count = 0;
    g_next_label = 1;
    g_ir_loop_depth = 0;
    g_ir_str_const_count = 0;
    g_ir_source_hash = 0;
    g_ir_source_hash_ready = 0;
    init_df();
    // 可选表示面（R2 P4 Task 5）：本路径不经过 ir_gen_all ⇒ 必须自行初始化（侧表复位
    // + 启用扫描），且**先于 ir_gen_globals**（隐藏信道的 var 行序依赖）。
    optrep_begin();
    ir_gen_globals();

    // Incremental cache: ensure cache directory exists
    make_cir_cache_dir();

    // A cached caller does not replay monomorphization, so its specialized
    // callee FuncInfo entries would be missing on the next compile.
    cache_enabled : int, mut = 1;
    cache_scan : ., mut = 0;
    loop {
        if cache_scan >= g_func_count { break; }
        if fi_generic_count(cache_scan) > 0 { cache_enabled = 0; break; }
        cache_scan = cache_scan + 1;
    }
    // 可选表示面启用 ⇒ **关 .cir 快照缓存**（R2 P4 Task 5）：表示位侧表是**编译期
    // 进程内状态**（var → 表示位 var 映射），快照只存指令/节点不存侧表 ⇒ 命中恢复的
    // 函数解包点会回落既有装箱路径，与冷路径**产物分歧**（冷/热分歧类，同 Task 4 的
    // bad_term 教训）。关缓存 = 每次全量重建 = 正确性优先；非可选程序照常缓存。
    if g_optrep_on != 0 {
        cache_enabled = 0;
    }

    // Generate IR for each function, checking cache first
    fi : ., mut = 0;
    loop {
        if fi >= g_func_count { break; }

        // Skip generic functions — they are monomorphized at call sites
        if fi_generic_count(fi) > 0 {
            fi = fi + 1;
            continue;
        }

        // DFG metadata uses the compact IR function index. Source FuncInfo
        // indices diverge as soon as a generic function is skipped.
        ir_func_idx := g_ir_func_count;
        df_begin_func(ir_func_idx);

        // Build cache key from source path + function name
        fn_node := fi_ast_node(fi);
        name_ni := ast_a(fn_node);
        name := istr_get(name_ni);
        func_id := src_path + "::" + name;

        // Sanitize func_id for filesystem: replace / with _
        cache_path : ., mut = ".core/cache/cir/";
        ci : ., mut = 0;
        loop {
            if ci >= str_len(func_id) { break; }
            c := load8(func_id, ci);
            if c == 47 { cache_path = cache_path + "_"; }
            else { cache_path = cache_path + chr(c); }
            ci = ci + 1;
        }
        cache_path = cache_path + ".cir";

        // Capture current state before cache load
        instr_start := g_ir_instr_count;
        var_start := g_ir_var_count;

        // Try loading from cache (pass func_idx for signature verification)
        cached : int, mut = -1;
        if cache_enabled != 0 { cached = load_cir_cache(cache_path, fi); }
        if cached == 0 {
            // Cache hit: setup function metadata for restored data
            func_idx := g_ir_func_count;
            grow_ir_func_meta(func_idx + 1);
            w64(g_ir_func_name_idx, func_idx * 8, name_ni);
            w64(g_ir_func_ret_type, func_idx * 8, fi_return_type(fi));
            w64(g_ir_func_instr_start, func_idx * 8, instr_start);
            w64(g_ir_func_var_start, func_idx * 8, var_start);
            w64(g_ir_func_param_count, func_idx * 8, ast_c(fn_node));
            w64(g_ir_func_instr_count, func_idx * 8, g_ir_instr_count - instr_start);
            w64(g_ir_func_var_count, func_idx * 8, g_ir_var_count - var_start);
            g_ir_func_count = func_idx + 1;

            df_end_func(ir_func_idx);
        } else {
            // Cache miss: do full frontend IR gen
            ir_gen_func(fi);
            df_end_func(ir_func_idx);

            // Save cache for future compilations
            if cache_enabled != 0 { save_cir_cache(cache_path, fi, ir_func_idx); }
        }

        fi = fi + 1;
    }

    // === 纯度 + state 链最终化（IR 生成结束、任何链消费者之前）===
    // 真纯度只能由全程序 IR 体算（checker.cr compute_all_purity 头注），链的连接
    // 依赖真纯度 ⇒ 两者同点时后移（dataflow.cr df_replay_state_chain 头注）。
    df_state_finalize();

    // === cir: output dataflow graph ===
    if cli_eq(cmd, "cir") {
        // regalloc 判定/条目调试通道（--dump-entries/--dump-coexist/--check-regalloc/
        // --inject-*）已随编码决策层迁 corearch（2026-09-07 regalloc 移后端）——
        // corearch load .ccr 后自算自检（src/arch/x86_64/regalloc.cr），载体 =
        // corearch 同名隐藏 flag。
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
        // Text dump with region annotations (g_sgs fully populated by the
        // df_begin_func/df_end_func + sg_push/sg_pop calls in the IR gen loop above)
        print(cir_text_dump());
        print(" -> ");
        println(out);
        // R2 P4 Task 4 测试通道（hidden）：逐节点 tk/项槽 dump——冷路径（emit 填槽）
        // 与暖路径（.cir 快照读回）用同一通道对拍（test_ccr_types.py 的 T4 节）。
        // 时点 = 全图构建完（含命中恢复）；只读，不产产物。
        if cli_has("dump-tk-terms") != 0 { print(df_tk_term_dump()); }
        return 0;
    }

    // === Pointer analysis + safety passes (always run, even at opt_level 0) ===
    base_diags := g_diag_count;
    ptr_analysis_all();
    region_check_all();
    provenance_verify_all();
    // 修复 5：编译期确定的越界（provenance 诊断）是硬错误——拦截编译。
    // 修复前诊断只记录不拦截，越界程序照常生成。
    if g_diag_count > base_diags {
        print_diagnostics();
        return 1;
    }

    // === build | ccr need lower_to_ccr ===
    // regalloc 移后端（2026-09-07）：O2 分配 + 一致性判定已归位 corearch——
    // corearch load .ccr 后自算自检（违反 = 编译错误）；corec 只留语义层 CSE。
    if g_opt_level >= 1 {
        pass_cse();
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
        // Hidden debug (--inject-var-shift): GC-4 test hook — shift func0's var decl
        // block start left by 1 (count-level guards can't see it; the position-level
        // guard in save_ccr must reject). Real build paths never inject.
        if cli_has("inject-var-shift") != 0 {
            if inject_var_shift() != 0 {
                print("error: inject-var-shift: precondition failed (func0 block start < 1)");
                println("");
                return 1;
            }
        }
        // R2 P4 Task 2/3（D13/D14）：TYPE/IFACE 段内容构造 = 确定性装填（项层/引擎/
        // 桥接复位 → 形状重注册 → 行序装填 → 接口签名项装填）+ 两段体缓冲；save_ccr
        // 只按段表搬运缓冲（D18）。装填失败（不可译行/签名项）= 拒绝落盘（rc=1 +
        // 诊断——不得产出缺项的类型/接口段）。
        if ccr_seg_prepare_save() != 0 {
            println("error: could not build TYPE/IFACE segments");
            return 1;
        }
        // 测试通道（hidden）：载入前 dump 段内容面（行表/项 DAG/probe；接口表/形状/
        // 签名项/跨段引用域探针）——与 corearch --dump-types/--dump-ifaces 同一条打印
        // 路径（跨进程对拍），见 test_ccr_types.py。
        if cli_has("dump-types") != 0 { ccr_type_selftest_dump(); }
        if cli_has("dump-ifaces") != 0 { ccr_iface_selftest_dump(); }
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
        out_path = default_out_path(src_path, "");
    }
    // Save .ccr alongside output (real IR artifact)
    println("save .ccr...");
    ccr_path : ., mut = out_path + ".ccr";
    // R2 P4 Task 2/3（D13/D14/D18）：TYPE/IFACE 段装填 + 段体缓冲（同 ccr 分支；
    // 前置核查 = 本点之后无类型项/接口消费者——其后仅拼 corearch 命令行并子进程执行）。
    if ccr_seg_prepare_save() != 0 {
        println("error: could not build TYPE/IFACE segments");
        return 1;
    }
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
            diag_code := r64(g_diags, ei * DIAG_REC_SIZE);
            diag_msg := load_str_ptr(g_diags, ei * DIAG_REC_SIZE + 8);
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
