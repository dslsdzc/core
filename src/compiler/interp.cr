// === interp.cr ===
// Minimal IR interpreter for -c (eval) mode.

g_i_opcode : [int; 2048], mut;
g_i_dest : [int; 2048], mut;
g_i_s1 : [int; 2048], mut;
g_i_s2 : [int; 2048], mut;
g_i_s3 : [int; 2048], mut;
g_i_count : int, mut;
g_ir_vals : [int; 1024], mut;

fn ir_interpret() -> int {
    main_idx : ., mut = -1;
    fi : ., mut = 0;
    loop { if fi >= g_ir_func_count { break; }
        ni := g_ir_func_name_idx[fi];
        if __builtin_str_eq(g_strs[ni], "main") != 0 { main_idx = fi; break; }
        fi = fi + 1; }
    if main_idx < 0 { return -1; }

    start := g_ir_func_instr_start[main_idx];
    cnt := g_ir_func_instr_count[main_idx];
    g_i_count = cnt;

    vi : ., mut = 0; loop { if vi >= 1024 { break; } g_ir_vals[vi] = 0; vi = vi + 1; }
    ii : ., mut = 0;
    loop { if ii >= cnt { break; }
        src := g_ir_instrs[start + ii];
        g_i_opcode[ii] = src.opcode; g_i_dest[ii] = src.dest;
        g_i_s1[ii] = src.src1; g_i_s2[ii] = src.src2; g_i_s3[ii] = src.src3;
        ii = ii + 1; }

    // Build label map
    g_label_count = 0;
    ii = 0; loop { if ii >= cnt { break; }
        if g_i_opcode[ii] == 21 {  // IR_LABEL
            ln := g_i_s1[ii];
            if ln >= 0 && ln < 32 { g_label_poses[ln] = ii; if ln+1 > g_label_count { g_label_count = ln+1; } }
        }
        ii = ii + 1; }

    ip : ., mut = 0;
    loop {
        if ip >= cnt { break; }
        op := g_i_opcode[ip]; d := g_i_dest[ip];
        s1 := g_i_s1[ip]; s2 := g_i_s2[ip]; s3 := g_i_s3[ip];

        if op == 1 { if d >= 0 { g_ir_vals[d] = s1; } }  // IR_CONST
        if op == 5 { if s1 >= 0 { return g_ir_vals[s1]; } return 0; }  // IR_RETURN

        if op == 2 {  // IR_BINARY
            lv := g_ir_vals[s1]; rv := g_ir_vals[s2];
            if s3 == 1 { g_ir_vals[d] = lv + rv; }
            if s3 == 2 { g_ir_vals[d] = lv - rv; }
            if s3 == 3 { g_ir_vals[d] = lv * rv; }
            if s3 == 4 { g_ir_vals[d] = lv / rv; }
            if s3 == 5 { g_ir_vals[d] = lv % rv; }
            if s3 == 6 { if lv == rv { g_ir_vals[d] = 1; } else { g_ir_vals[d] = 0; } }
            if s3 == 7 { if lv != rv { g_ir_vals[d] = 1; } else { g_ir_vals[d] = 0; } }
            if s3 == 8 { if lv < rv { g_ir_vals[d] = 1; } else { g_ir_vals[d] = 0; } }
            if s3 == 9 { if lv > rv { g_ir_vals[d] = 1; } else { g_ir_vals[d] = 0; } }
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

        // Allocate / store / load
        if op >= 6 && op <= 8 { if d >= 0 { g_ir_vals[d] = 0; } }
        if op == 9 || op == 12 { if s1 >= 0 && s2 >= 0 { g_ir_vals[s1] = g_ir_vals[s2]; } }
        if op == 10 || op == 11 { if d >= 0 { g_ir_vals[d] = g_ir_vals[s1]; } }

        // Enum / ref
        if op == 17 || op == 18 || op == 25 || op == 23 { if d >= 0 { g_ir_vals[d] = g_ir_vals[s1]; } }

        // Branch
        if op == 19 {
            cv := g_ir_vals[s1];
            if cv != 0 { if s2 >= 0 && s2 < g_label_count { ip = g_label_poses[s2]; } }
            else { if s3 >= 0 && s3 < g_label_count { ip = g_label_poses[s3]; } }
            if ip < cnt { continue; } else { break; }
        }
        if op == 20 {  // IR_JUMP
            if s1 >= 0 && s1 < g_label_count { ip = g_label_poses[s1]; }
            else { ip = ip + 1; }
            if ip < cnt { continue; } else { break; }
        }
        // IR_LABEL (21) - noop

        if op == 4 {  // IR_CALL
            fn_ni := s3;
            fn_name := g_strs[fn_ni];
            if __builtin_str_eq(fn_name, "__builtin_print") != 0 {
                if s2 >= 1 { str_idx := g_ir_vals[s1]; sval := g_strs[str_idx]; __builtin_print(sval); }
            } else {
                if __builtin_str_eq(fn_name, "__builtin_println") != 0 {
                    if s2 >= 1 { str_idx := g_ir_vals[s1]; sval := g_strs[str_idx]; __builtin_println(sval); }
                }
            }
        }

        ip = ip + 1;
    }
    return 0;
}
