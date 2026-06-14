// === interp.cr ===
// Dataflow graph interpreter for -c (eval) mode.
// Interprets g_df_nodes[] (the .cir graph) instead of linear g_ir_instrs[] (.ccr).
// The DFG preserves type/semantic information throughout execution.

g_ir_vals : [int; 1024], mut;

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

    node_start := g_df_func_node_start[main_idx];
    node_count := g_df_func_node_count[main_idx];
    if node_start < 0 || node_count <= 0 { return -1; }

    // Initialize value store
    vi : ., mut = 0;
    loop {
        if vi >= 1024 { break; }
        g_ir_vals[vi] = 0;
        vi = vi + 1;
    }

    // Pre-scan: build label→node mapping (for branches)
    g_label_count = 0;
    li : ., mut = 0;
    loop {
        if li >= node_count { break; }
        nd := g_df_nodes[node_start + li];
        if nd.opcode == 21 {  // IR_LABEL
            ln := nd.src1;  // label number
            if ln >= 0 && ln < 32 {
                g_label_poses[ln] = li;
                if ln + 1 > g_label_count { g_label_count = ln + 1; }
            }
        }
        li = li + 1;
    }

    // Execute nodes in order (dataflow: sequential order = valid topological order for straight-line)
    ip : ., mut = 0;
    loop {
        if ip >= node_count { break; }
        nd := g_df_nodes[node_start + ip];
        op := nd.opcode; d := nd.dest_var;
        s1 := nd.src1; s2 := nd.src2; s3 := nd.src3;

        if op == 1  { if d >= 0 { g_ir_vals[d] = s1; } }  // IR_CONST
        if op == 5  { if s1 >= 0 { return g_ir_vals[s1]; } return 0; }  // IR_RETURN

        if op == 2 {  // IR_BINARY
            lv := g_ir_vals[s1]; rv := g_ir_vals[s2];
            if s3 == 1  { g_ir_vals[d] = lv + rv; }
            if s3 == 2  { g_ir_vals[d] = lv - rv; }
            if s3 == 3  { g_ir_vals[d] = lv * rv; }
            if s3 == 4  { g_ir_vals[d] = lv / rv; }
            if s3 == 5  { g_ir_vals[d] = lv % rv; }
            if s3 == 6  { if lv == rv { g_ir_vals[d] = 1; } else { g_ir_vals[d] = 0; } }
            if s3 == 7  { if lv != rv { g_ir_vals[d] = 1; } else { g_ir_vals[d] = 0; } }
            if s3 == 8  { if lv < rv { g_ir_vals[d] = 1; } else { g_ir_vals[d] = 0; } }
            if s3 == 9  { if lv > rv { g_ir_vals[d] = 1; } else { g_ir_vals[d] = 0; } }
            if s3 == 10 { if lv <= rv { g_ir_vals[d] = 1; } else { g_ir_vals[d] = 0; } }
            if s3 == 11 { if lv >= rv { g_ir_vals[d] = 1; } else { g_ir_vals[d] = 0; } }
            if s3 == 12 { if lv != 0 && rv != 0 { g_ir_vals[d] = 1; } else { g_ir_vals[d] = 0; } }
            if s3 == 13 { if lv != 0 || rv != 0 { g_ir_vals[d] = 1; } else { g_ir_vals[d] = 0; } }
        }

        if op == 3 {  // IR_UNARY
            ov := g_ir_vals[s1];
            if s3 == 1 { g_ir_vals[d] = -ov; }
            if s3 == 2 { if ov == 0 { g_ir_vals[d] = 1; } else { g_ir_vals[d] = 0; } }
        }

        // Alloc / Store / Load
        if op >= 6 && op <= 8 { if d >= 0 { g_ir_vals[d] = 0; } }
        if op == 9  || op == 12 { if s1 >= 0 && s2 >= 0 { g_ir_vals[s1] = g_ir_vals[s2]; } }
        if op == 10 || op == 11 { if d >= 0 { g_ir_vals[d] = g_ir_vals[s1]; } }
        if op == 17 || op == 18 || op == 25 || op == 23 { if d >= 0 { g_ir_vals[d] = g_ir_vals[s1]; } }

        // IR_STORE_PTR
        if op == 26 { if d >= 0 && s1 >= 0 { g_ir_vals[s1] = g_ir_vals[d]; } }

        // Branch (node-index based)
        if op == 19 {
            cv := g_ir_vals[s1];
            if cv != 0 { if s2 >= 0 && s2 < g_label_count { ip = g_label_poses[s2]; } }
            else       { if s3 >= 0 && s3 < g_label_count { ip = g_label_poses[s3]; } }
            if ip < node_count { continue; } else { break; }
        }
        if op == 20 {  // IR_JUMP
            if s1 >= 0 && s1 < g_label_count { ip = g_label_poses[s1]; }
            else { ip = ip + 1; }
            if ip < node_count { continue; } else { break; }
        }
        // IR_LABEL (21) - noop

        if op == 4 {  // IR_CALL
            fn_ni := s3;
            fn_name := str_get(fn_ni);
            if __builtin_str_eq(fn_name, "__builtin_print") != 0 ||
               __builtin_str_eq(fn_name, "print") != 0 {
                if s2 >= 1 { str_idx := g_ir_vals[s1]; sval := str_get(str_idx); __builtin_print(sval); }
            }
            if __builtin_str_eq(fn_name, "__builtin_println") != 0 ||
               __builtin_str_eq(fn_name, "println") != 0 {
                if s2 >= 1 { str_idx := g_ir_vals[s1]; sval := str_get(str_idx); __builtin_println(sval); }
            }
            if __builtin_str_eq(fn_name, "__builtin_print_int") != 0 ||
               __builtin_str_eq(fn_name, "print_int") != 0 {
                if s2 >= 1 { __builtin_print(__builtin_int_to_str(g_ir_vals[s1])); }
            }
            if __builtin_str_eq(fn_name, "__builtin_println_int") != 0 ||
               __builtin_str_eq(fn_name, "println_int") != 0 {
                if s2 >= 1 { __builtin_println(__builtin_int_to_str(g_ir_vals[s1])); }
            }
            // __builtin_syscall3 — 解释器模式下返回 0（字符串常量在值存储中是指针还是索引不明确）
            if __builtin_str_eq(fn_name, "__builtin_syscall3") != 0 {
                if d >= 0 { g_ir_vals[d] = 0; }
            }
        }

        ip = ip + 1;
    }
    return 0;
}
