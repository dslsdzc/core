// === interp.cr ===
// Dataflow graph interpreter for -c (eval) mode.
// Interprets g_df_nodes[] (the .cir graph) instead of linear g_ir_instrs[] (.ccr).
// The DFG preserves type/semantic information throughout execution.

g_ir_vals : string, mut;    g_ir_vals_cap : int, mut;

fn ir_interpret() -> int {
    // Find main function in the dataflow graph
    main_idx : ., mut = -1;
    fi : ., mut = 0;
    loop {
        if fi >= g_ir_func_count { break; }
        ni := r64(g_ir_func_name_idx, fi * 8);
        if str_eq(istr_get(ni), "main") != 0 { main_idx = fi; break; }
        fi = fi + 1;
    }
    if main_idx < 0 { return -1; }

    node_start := r64(g_df_func_node_start, main_idx * 8);
    node_count := r64(g_df_func_node_count, main_idx * 8);
    if node_start < 0 || node_count <= 0 { return -1; }

    // Initialize value store (size = node_count + padding for destinations)
    need := node_count + 64;
    if g_ir_vals_cap < need {
        g_ir_vals = alloc(need * 8);
        g_ir_vals_cap = need;
    }
    vi : ., mut = 0;
    loop {
        if vi >= need { break; }
        w64(g_ir_vals, vi * 8, 0);
        vi = vi + 1;
    }

    // Pre-scan: build label→node mapping (for branches)
    g_label_count = 0;
    li : ., mut = 0;
    loop {
        if li >= node_count { break; }
        n_op := r64(g_df_nodes, (node_start + li) * ESZ_DFNODE + OFF_DF_OPCODE);
        n_s1 := r64(g_df_nodes, (node_start + li) * ESZ_DFNODE + OFF_DF_S1);
        if n_op == 21 {  // IR_LABEL
            ln := n_s1;  // label number
            if ln >= 0 {
                grow_label_poses(ln + 1);
                w64(g_label_poses, ln * 8, li);
                if ln + 1 > g_label_count { g_label_count = ln + 1; }
            }
        }
        li = li + 1;
    }

    // Execute nodes in order (dataflow: sequential order = valid topological order for straight-line)
    ip : ., mut = 0;
    loop {
        if ip >= node_count { break; }
        op := r64(g_df_nodes, (node_start + ip) * ESZ_DFNODE + OFF_DF_OPCODE);
        d := r64(g_df_nodes, (node_start + ip) * ESZ_DFNODE + OFF_DF_DEST);
        s1 := r64(g_df_nodes, (node_start + ip) * ESZ_DFNODE + OFF_DF_S1);
        s2 := r64(g_df_nodes, (node_start + ip) * ESZ_DFNODE + OFF_DF_S2);
        s3 := r64(g_df_nodes, (node_start + ip) * ESZ_DFNODE + OFF_DF_S3);

        if op == 1  { if d >= 0 { w64(g_ir_vals, d * 8, s1); } }  // IR_CONST
        if op == 5  { if s1 >= 0 { return r64(g_ir_vals, s1 * 8); } return 0; }  // IR_RETURN

        if op == 2 {  // IR_BINARY
            lv := r64(g_ir_vals, s1 * 8); rv := r64(g_ir_vals, s2 * 8);
            if s3 == 1  { w64(g_ir_vals, d * 8, lv + rv); }
            if s3 == 2  { w64(g_ir_vals, d * 8, lv - rv); }
            if s3 == 3  { w64(g_ir_vals, d * 8, lv * rv); }
            if s3 == 4  { w64(g_ir_vals, d * 8, lv / rv); }
            if s3 == 5  { w64(g_ir_vals, d * 8, lv % rv); }
            if s3 == 6  { if lv == rv { w64(g_ir_vals, d * 8, 1); } else { w64(g_ir_vals, d * 8, 0); } }
            if s3 == 7  { if lv != rv { w64(g_ir_vals, d * 8, 1); } else { w64(g_ir_vals, d * 8, 0); } }
            if s3 == 8  { if lv < rv { w64(g_ir_vals, d * 8, 1); } else { w64(g_ir_vals, d * 8, 0); } }
            if s3 == 9  { if lv > rv { w64(g_ir_vals, d * 8, 1); } else { w64(g_ir_vals, d * 8, 0); } }
            if s3 == 10 { if lv <= rv { w64(g_ir_vals, d * 8, 1); } else { w64(g_ir_vals, d * 8, 0); } }
            if s3 == 11 { if lv >= rv { w64(g_ir_vals, d * 8, 1); } else { w64(g_ir_vals, d * 8, 0); } }
            if s3 == 12 { if lv != 0 && rv != 0 { w64(g_ir_vals, d * 8, 1); } else { w64(g_ir_vals, d * 8, 0); } }
            if s3 == 13 { if lv != 0 || rv != 0 { w64(g_ir_vals, d * 8, 1); } else { w64(g_ir_vals, d * 8, 0); } }
        }

        if op == 3 {  // IR_UNARY
            ov := r64(g_ir_vals, s1 * 8);
            if s3 == 1 { w64(g_ir_vals, d * 8, -ov); }
            if s3 == 2 { if ov == 0 { w64(g_ir_vals, d * 8, 1); } else { w64(g_ir_vals, d * 8, 0); } }
        }

        // Alloc / Store / Load
        if op >= 6 && op <= 8 { if d >= 0 { w64(g_ir_vals, d * 8, 0); } }
        if op == 9  || op == 12 { if s1 >= 0 && s2 >= 0 { w64(g_ir_vals, s1 * 8, r64(g_ir_vals, s2 * 8)); } }
        if op == 10 || op == 11 { if d >= 0 { w64(g_ir_vals, d * 8, r64(g_ir_vals, s1 * 8)); } }
        if op == 17 || op == 18 || op == 25 || op == 23 { if d >= 0 { w64(g_ir_vals, d * 8, r64(g_ir_vals, s1 * 8)); } }

        // IR_YIELD — suspend current fiber with output value
        if op == 28 {
            // Store yield value in fiber output slot
            if s1 >= 0 {
                w64(g_ir_vals, 0, r64(g_ir_vals, s1 * 8));  // stash in slot 0
            }
            // Sequential fallback: continue to next instruction
        }

        // IR_STORE_PTR
        if op == 26 { if d >= 0 && s1 >= 0 { w64(g_ir_vals, s1 * 8, r64(g_ir_vals, d * 8)); } }

        // Branch (node-index based)
        if op == 19 {
            cv := r64(g_ir_vals, s1 * 8);
            if cv != 0 { if s2 >= 0 && s2 < g_label_count { ip = r64(g_label_poses, s2 * 8); } }
            else       { if s3 >= 0 && s3 < g_label_count { ip = r64(g_label_poses, s3 * 8); } }
            if ip < node_count { continue; } else { break; }
        }
        if op == 20 {  // IR_JUMP
            if s1 >= 0 && s1 < g_label_count { ip = r64(g_label_poses, s1 * 8); }
            else { ip = ip + 1; }
            if ip < node_count { continue; } else { break; }
        }
        // IR_LABEL (21) - noop

        if op == 29 { if d >= 0 { w64(g_ir_vals, d * 8, r64(g_ir_vals, s1 * 8)); } }  // IR_AWAIT
        if op == 4 || op == 27 {  // IR_CALL or IR_SPAWN (sequential fallback)
            fn_ni := s3;
            fn_name := istr_get(fn_ni);
            sfi := find_so_fn(fn_ni);
            if sfi >= 0 && s2 >= 1 {
                tf := sym_type(sfi);
                if tf == 1 || tf == 3 {  // TAG_VARIADIC: print/println
                    str_idx := r64(g_ir_vals, s1 * 8);
                    sval := istr_get(str_idx);
                    fn_name2 := istr_get(fn_ni);
                    is_ln : ., mut = 0;
                    fnl := str_len(fn_name2);
                    if fnl >= 4 && load8(fn_name2, fnl-2) == 108 && load8(fn_name2, fnl-1) == 110 { is_ln = 1; }
                    if is_ln != 0 { println(sval); } else { print(sval); }
                } else if tf == 2 || tf == 3 {  // TAG_AUTO_STR: print_i/println_i
                    val := r64(g_ir_vals, s1 * 8);
                    fn_name2 := istr_get(fn_ni);
                    is_ln : ., mut = 0;
                    fnl := str_len(fn_name2);
                    if fnl >= 4 && load8(fn_name2, fnl-2) == 108 && load8(fn_name2, fnl-1) == 110 { is_ln = 1; }
                    if is_ln != 0 { println(int_str(val)); } else { print(int_str(val)); }
                }
            }
            // syscall3 — 解释器模式下返回 0（字符串常量在值存储中是指针还是索引不明确）
            if str_eq(fn_name, "syscall3") != 0 {
                if d >= 0 { w64(g_ir_vals, d * 8, 0); }
            }
            if str_eq(fn_name, "load_str_ptr") != 0 {
                // Load string pointer from byte buffer at given offset
                if d >= 0 && s2 >= 2 {
                    b := r64(g_ir_vals, s1 * 8); p := r64(g_ir_vals, s1 + 1 * 8);
                    lo := load8(b, p) + load8(b, p+1)*256 +
                          load8(b, p+2)*65536 + load8(b, p+3)*16777216;
                    hi := load8(b, p+4) + load8(b, p+5)*256 +
                          load8(b, p+6)*65536 + load8(b, p+7)*16777216;
                    if hi < 0 { hi = hi + 4294967296; }
                    w64(g_ir_vals, d * 8, lo + hi * 4294967296);
                }
            }
            if str_eq(fn_name, "store_str_ptr") != 0 {
                // Store string pointer (as 8 bytes) into byte buffer at given offset
                if s2 >= 3 {
                    b := r64(g_ir_vals, s1 * 8); p := r64(g_ir_vals, s1 + 1 * 8); v := r64(g_ir_vals, s1 + 2 * 8);
                    lo : ., mut = v % 4294967296; hi : ., mut = v / 4294967296;
                    if v < 0 { lo = v; hi = -1; }
                    store8(b, p, lo%256);     store8(b, p+1, (lo/256)%256);
                    store8(b, p+2, (lo/65536)%256); store8(b, p+3, (lo/16777216)%256);
                    store8(b, p+4, hi%256);   store8(b, p+5, (hi/256)%256);
                    store8(b, p+6, (hi/65536)%256); store8(b, p+7, (hi/16777216)%256);
                }
                if d >= 0 { w64(g_ir_vals, d * 8, 0); }
            }
        }

        ip = ip + 1;
    }
    return 0;
}
