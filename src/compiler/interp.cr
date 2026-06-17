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
        if __builtin_str_eq(str_get(ni), "main") != 0 { main_idx = fi; break; }
        fi = fi + 1;
    }
    if main_idx < 0 { return -1; }

    node_start := r64(g_df_func_node_start, main_idx * 8);
    node_count := r64(g_df_func_node_count, main_idx * 8);
    if node_start < 0 || node_count <= 0 { return -1; }

    // Initialize value store
    vi : ., mut = 0;
    loop {
        if vi >= 1024 { break; }
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
                dyn_grow_label_poses(ln + 1);
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

        if op == 4 {  // IR_CALL
            fn_ni := s3;
            fn_name := str_get(fn_ni);
            if __builtin_str_eq(fn_name, "__builtin_print") != 0 ||
               __builtin_str_eq(fn_name, "print") != 0 {
                if s2 >= 1 { str_idx := r64(g_ir_vals, s1 * 8); sval := str_get(str_idx); __builtin_print(sval); }
            }
            if __builtin_str_eq(fn_name, "__builtin_println") != 0 ||
               __builtin_str_eq(fn_name, "println") != 0 {
                if s2 >= 1 { str_idx := r64(g_ir_vals, s1 * 8); sval := str_get(str_idx); __builtin_println(sval); }
            }
            if __builtin_str_eq(fn_name, "__builtin_print_int") != 0 ||
               __builtin_str_eq(fn_name, "print_int") != 0 {
                if s2 >= 1 { __builtin_print(__builtin_int_to_str(r64(g_ir_vals, s1 * 8))); }
            }
            if __builtin_str_eq(fn_name, "__builtin_println_int") != 0 ||
               __builtin_str_eq(fn_name, "println_int") != 0 {
                if s2 >= 1 { __builtin_println(__builtin_int_to_str(r64(g_ir_vals, s1 * 8))); }
            }
            // __builtin_syscall3 — 解释器模式下返回 0（字符串常量在值存储中是指针还是索引不明确）
            if __builtin_str_eq(fn_name, "__builtin_syscall3") != 0 {
                if d >= 0 { w64(g_ir_vals, d * 8, 0); }
            }
            if __builtin_str_eq(fn_name, "__builtin_load_str_ptr") != 0 {
                // Load string pointer from byte buffer at given offset
                if d >= 0 && s2 >= 2 {
                    b := r64(g_ir_vals, s1 * 8); p := r64(g_ir_vals, s1 + 1 * 8);
                    lo := __builtin_load8(b, p) + __builtin_load8(b, p+1)*256 +
                          __builtin_load8(b, p+2)*65536 + __builtin_load8(b, p+3)*16777216;
                    hi := __builtin_load8(b, p+4) + __builtin_load8(b, p+5)*256 +
                          __builtin_load8(b, p+6)*65536 + __builtin_load8(b, p+7)*16777216;
                    if hi < 0 { hi = hi + 4294967296; }
                    w64(g_ir_vals, d * 8, lo + hi * 4294967296);
                }
            }
            if __builtin_str_eq(fn_name, "__builtin_store_str_ptr") != 0 {
                // Store string pointer (as 8 bytes) into byte buffer at given offset
                if s2 >= 3 {
                    b := r64(g_ir_vals, s1 * 8); p := r64(g_ir_vals, s1 + 1 * 8); v := r64(g_ir_vals, s1 + 2 * 8);
                    lo : ., mut = v % 4294967296; hi : ., mut = v / 4294967296;
                    if v < 0 { lo = v; hi = -1; }
                    __builtin_store8(b, p, lo%256);     __builtin_store8(b, p+1, (lo/256)%256);
                    __builtin_store8(b, p+2, (lo/65536)%256); __builtin_store8(b, p+3, (lo/16777216)%256);
                    __builtin_store8(b, p+4, hi%256);   __builtin_store8(b, p+5, (hi/256)%256);
                    __builtin_store8(b, p+6, (hi/65536)%256); __builtin_store8(b, p+7, (hi/16777216)%256);
                }
                if d >= 0 { w64(g_ir_vals, d * 8, 0); }
            }
        }

        ip = ip + 1;
    }
    return 0;
}
