// === interp.cr ===
// Dataflow graph interpreter for -c (eval) mode.
// Interprets g_df_nodes[] (the .cir graph) instead of linear g_ir_instrs[] (.ccr).
// The DFG preserves type/semantic information throughout execution.
//
// Limitations:
// - String constants: 解释器不调用 syscall3，alloc/print/syscall 相关函数返回 0
// - 递归/跨函数调用：inline 执行不支持 IR_CALL，只处理 main→callee 的单层调用
// - for 循环：dataflow 图按顺序执行，label/branch 机制不与 for 循环兼容

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
    need := g_ir_var_count + 64;
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
            if s3 == 8  { if lv < rv  { w64(g_ir_vals, d * 8, 1); } else { w64(g_ir_vals, d * 8, 0); } }
            if s3 == 9  { if lv > rv  { w64(g_ir_vals, d * 8, 1); } else { w64(g_ir_vals, d * 8, 0); } }
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

        // Alloc / Store / Load / Field / Index
        if op == 6 { if d >= 0 { w64(g_ir_vals, d * 8, 0); } }  // IR_ALLOC
        if op == 7 {  // IR_ALLOC_STRUCT
            if d >= 0 {
                si := find_struct(s3);
                fc : ., mut = 0;
                if si >= 0 { fc = si_field_count(si); }
                need2 := fc * 8 + 8;
                bp := alloc(need2);
                vi2 : ., mut = 0;
                loop { if vi2 >= need2 { break; } store8(bp, vi2, 0); vi2 = vi2 + 1; }
                w64(g_ir_vals, d * 8, bp);
            }
        }
        if op == 8 {  // IR_ALLOC_ARRAY
            if d >= 0 {
                cnt := s1; esz := s2;
                if esz <= 0 { esz = 8; }
                need2 := cnt * esz + 8;
                bp := alloc(need2);
                vi2 : ., mut = 0;
                loop { if vi2 >= need2 { break; } store8(bp, vi2, 0); vi2 = vi2 + 1; }
                w64(g_ir_vals, d * 8, bp);
            }
        }
        if op == 9 { if s1 >= 0 && s2 >= 0 { w64(g_ir_vals, s1 * 8, r64(g_ir_vals, s2 * 8)); } }  // IR_STORE
        if op == 10 { if d >= 0 { w64(g_ir_vals, d * 8, r64(g_ir_vals, s1 * 8)); } }  // IR_LOAD
        if op == 11 {  // IR_LOAD_FIELD: s1=struct_var, s3=field_idx
            if d >= 0 && s1 >= 0 {
                ptr := r64(g_ir_vals, s1 * 8);
                if ptr != 0 { w64(g_ir_vals, d * 8, r64(ptr, s3 * 8)); }
                else { w64(g_ir_vals, d * 8, r64(g_ir_vals, s1 * 8)); }
            }
        }
        if op == 12 {  // IR_STORE_FIELD: s1=struct_var, s2=val_var, s3=field_idx
            if s1 >= 0 && s2 >= 0 {
                ptr := r64(g_ir_vals, s1 * 8);
                if ptr != 0 { w64(ptr, s3 * 8, r64(g_ir_vals, s2 * 8)); }
                else { w64(g_ir_vals, s1 * 8, r64(g_ir_vals, s2 * 8)); }
            }
        }
        if op == 13 {  // IR_LOAD_INDEX: s1=arr_var, s3=literal_idx
            if d >= 0 && s1 >= 0 {
                arr_ptr := r64(g_ir_vals, s1 * 8);
                w64(g_ir_vals, d * 8, r64(arr_ptr, s3 * 8));
            }
        }
        if op == 14 {  // IR_STORE_INDEX: s1=arr_var, s2=val_var, s3=literal_idx
            if s1 >= 0 && s2 >= 0 {
                arr_ptr := r64(g_ir_vals, s1 * 8);
                w64(arr_ptr, s3 * 8, r64(g_ir_vals, s2 * 8));
            }
        }
        if op == 15 {  // IR_LOAD_INDEX_VAR: s1=arr_var, s2=idx_var
            if d >= 0 && s1 >= 0 && s2 >= 0 {
                arr_ptr := r64(g_ir_vals, s1 * 8);
                idx := r64(g_ir_vals, s2 * 8);
                w64(g_ir_vals, d * 8, r64(arr_ptr, idx * 8));
            }
        }
        if op == 16 {  // IR_STORE_INDEX_VAR: d=val_var, s1=arr_var, s2=idx_var
            if d >= 0 && s1 >= 0 && s2 >= 0 {
                arr_ptr := r64(g_ir_vals, s1 * 8);
                idx := r64(g_ir_vals, s2 * 8);
                w64(arr_ptr, idx * 8, r64(g_ir_vals, d * 8));
            }
        }
        if op == 17 || op == 18 || op == 25 || op == 23 { if d >= 0 { w64(g_ir_vals, d * 8, r64(g_ir_vals, s1 * 8)); } }

        // IR_YIELD
        if op == 28 {
            if s1 >= 0 { w64(g_ir_vals, d * 8, r64(g_ir_vals, s1 * 8)); }
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

        // IR_AWAIT
        if op == 29 { if d >= 0 { w64(g_ir_vals, d * 8, r64(g_ir_vals, s1 * 8)); } }

        // IR_CALL or IR_SPAWN — only handles direct calls from main's graph
        // Inline-executed callee graphs do NOT support nested calls.
        if op == 4 || op == 27 {
            fn_ni := s3;
            fn_name := istr_get(fn_ni);
            sfi := find_so_fn(fn_ni);
            if sfi >= 0 && s2 >= 1 {
                tf := sym_type(sfi);
                if tf == 1 || tf == 3 {  // TAG_VARIADIC: print/println — NOOP (syscall3 returns 0)
                } else if tf == 2 || tf == 3 {  // TAG_AUTO_STR: print_i/println_i — NOOP (syscall3 returns 0)
                }
            }
            // syscall3 — interpreter returns 0
            if str_eq(fn_name, "syscall3") != 0 {
                if d >= 0 { w64(g_ir_vals, d * 8, 0); }
            }
            if str_eq(fn_name, "load_str_ptr") != 0 {
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
            // Regular function call (single level — no recursive/nested call support)
            if d >= 0 {
                cfi : ., mut = 0;
                loop {
                    if cfi >= g_ir_func_count { break; }
                    if r64(g_ir_func_name_idx, cfi * 8) == fn_ni {
                        f_start := r64(g_df_func_node_start, cfi * 8);
                        f_count := r64(g_df_func_node_count, cfi * 8);
                        if f_start >= 0 && f_count > 0 {
                            // Save label state
                            old_lc := g_label_count;
                            old_poses := g_label_poses;
                            old_poses_cap := g_label_cap;
                            g_label_poses = alloc(64 * 8); g_label_cap = 64;
                            // Build label map for callee
                            li2 : ., mut = 0;
                            loop { if li2 >= f_count { break; }
                                n_op := r64(g_df_nodes, (f_start + li2) * ESZ_DFNODE + OFF_DF_OPCODE);
                                n_s1 := r64(g_df_nodes, (f_start + li2) * ESZ_DFNODE + OFF_DF_S1);
                                if n_op == 21 { if n_s1 >= 0 {
                                    grow_label_poses(n_s1 + 1);
                                    w64(g_label_poses, n_s1 * 8, li2);
                                    if n_s1 + 1 > g_label_count { g_label_count = n_s1 + 1; }
                                }}
                            li2 = li2 + 1; }
                            // Copy args from caller positions to callee param vars
                            pstart := r64(g_ir_func_var_start, cfi * 8);
                            pai : ., mut = 0;
                            loop { if pai >= s2 { break; }
                                w64(g_ir_vals, (pstart + pai) * 8, r64(g_ir_vals, (s1 + pai) * 8));
                            pai = pai + 1; }
                            // Execute callee graph (inline)
                            ip2 : ., mut = 0;
                            loop {
                                if ip2 >= f_count { break; }
                                op2 := r64(g_df_nodes, (f_start + ip2) * ESZ_DFNODE + OFF_DF_OPCODE);
                                d2 := r64(g_df_nodes, (f_start + ip2) * ESZ_DFNODE + OFF_DF_DEST);
                                t1 := r64(g_df_nodes, (f_start + ip2) * ESZ_DFNODE + OFF_DF_S1);
                                t2 := r64(g_df_nodes, (f_start + ip2) * ESZ_DFNODE + OFF_DF_S2);
                                t3 := r64(g_df_nodes, (f_start + ip2) * ESZ_DFNODE + OFF_DF_S3);
                                if op2 == 1 && d2 >= 0 { w64(g_ir_vals, d2 * 8, t1); }
                                if op2 == 2 && t1 >= 0 && t2 >= 0 {
                                    lv2 := r64(g_ir_vals, t1 * 8); rv2 := r64(g_ir_vals, t2 * 8);
                                    if t3 == 1  { w64(g_ir_vals, d2 * 8, lv2 + rv2); }
                                    else if t3 == 2  { w64(g_ir_vals, d2 * 8, lv2 - rv2); }
                                    else if t3 == 3  { w64(g_ir_vals, d2 * 8, lv2 * rv2); }
                                    else if t3 == 4  { w64(g_ir_vals, d2 * 8, lv2 / rv2); }
                                    else if t3 == 5  { w64(g_ir_vals, d2 * 8, lv2 % rv2); }
                                    else if t3 == 6  { if lv2 == rv2 { w64(g_ir_vals, d2 * 8, 1); } else { w64(g_ir_vals, d2 * 8, 0); } }
                                    else if t3 == 7  { if lv2 != rv2 { w64(g_ir_vals, d2 * 8, 1); } else { w64(g_ir_vals, d2 * 8, 0); } }
                                    else if t3 == 8  { if lv2 < rv2  { w64(g_ir_vals, d2 * 8, 1); } else { w64(g_ir_vals, d2 * 8, 0); } }
                                    else if t3 == 9  { if lv2 > rv2  { w64(g_ir_vals, d2 * 8, 1); } else { w64(g_ir_vals, d2 * 8, 0); } }
                                    else if t3 == 10 { if lv2 <= rv2 { w64(g_ir_vals, d2 * 8, 1); } else { w64(g_ir_vals, d2 * 8, 0); } }
                                    else if t3 == 11 { if lv2 >= rv2 { w64(g_ir_vals, d2 * 8, 1); } else { w64(g_ir_vals, d2 * 8, 0); } }
                                    else if t3 == 12 { if lv2 != 0 && rv2 != 0 { w64(g_ir_vals, d2 * 8, 1); } else { w64(g_ir_vals, d2 * 8, 0); } }
                                    else if t3 == 13 { if lv2 != 0 || rv2 != 0 { w64(g_ir_vals, d2 * 8, 1); } else { w64(g_ir_vals, d2 * 8, 0); } } }
                                if op2 == 3 && t1 >= 0 {
                                    ov2 := r64(g_ir_vals, t1 * 8);
                                    if t3 == 1 { w64(g_ir_vals, d2 * 8, -ov2); }
                                    else if t3 == 2 { if ov2 == 0 { w64(g_ir_vals, d2 * 8, 1); } else { w64(g_ir_vals, d2 * 8, 0); } } }
                                if op2 == 5 { if t1 >= 0 { w64(g_ir_vals, 0, r64(g_ir_vals, t1 * 8)); } }  // IR_RETURN
                                if op2 == 19 && t1 >= 0 {
                                    cv2 := r64(g_ir_vals, t1 * 8);
                                    if cv2 != 0 { if t2 >= 0 && t2 < g_label_count { ip2 = r64(g_label_poses, t2 * 8); } }
                                    else { if t3 >= 0 && t3 < g_label_count { ip2 = r64(g_label_poses, t3 * 8); } } }
                                if op2 == 20 { if t1 >= 0 && t1 < g_label_count { ip2 = r64(g_label_poses, t1 * 8); } }
                                ip2 = ip2 + 1;
                            }
                            rval := r64(g_ir_vals, 0 * 8);
                            // Restore label state
                            g_label_count = old_lc;
                            g_label_poses = old_poses;
                            g_label_cap = old_poses_cap;
                            w64(g_ir_vals, d * 8, rval);
                        }
                        break;
                    }
                cfi = cfi + 1; }
            }
        }

        ip = ip + 1;
    }
    return 0;
}
