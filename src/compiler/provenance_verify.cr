// === provenance_verify.cr ===
// ProvenanceVerify pass — checks DEREF offset against allocation size.
// Runs after PointerAnalysis (ptr_analysis.cr) and RegionCheck (region_check.cr).
// Detects out-of-bounds pointer accesses at compile time.

fn get_alloc_size(alloc_seq: int) -> int {
    // 修复 3：alloc_seq 是 pts 位号（第几个 alloc），经映射表查 DF 节点序号再算大小。
    // 修复前直接当节点序号用 → 查到节点 0 → 恒返回 -1 → 运行时检查永不生成。
    if alloc_seq < 0 || alloc_seq >= g_pa_alloc_count { return -1; }
    an := r64(g_pa_alloc_nodes, alloc_seq * 8);
    op := r64(g_df_nodes, an * ESZ_DFNODE + OFF_DF_OPCODE);
    s1 := r64(g_df_nodes, an * ESZ_DFNODE + OFF_DF_S1);
    s3 := r64(g_df_nodes, an * ESZ_DFNODE + OFF_DF_S3);

    // 修复 12：IR_ALLOC（标量变量槽标记）不是堆分配——不返回 8（修复前把
    // 变量槽当 8 字节堆块，误报/误取 size）
    if op == IR_ALLOC_ARRAY { return s1 * 8; }   // count * 8（元素恒 8 字节，见 instr.cr IR_ALLOC_ARRAY）
    if op == IR_ALLOC_STRUCT {
        // 与 instr.cr IR_ALLOC_STRUCT 一致：fc * 8（field count × 8）
        fi : int = -1; si2 : ., mut = 0;
        loop { if si2 >= g_struct_count { break; }
            if si_name(si2) == s3 { fi = si2; break; }
            si2 = si2 + 1; }
        if fi >= 0 { return si_field_count(fi) * 8; }
        return 8;
    }
    return -1;  // unknown (defer to runtime check)
}

fn get_alloc_var(alloc_seq: int) -> int {
    if alloc_seq < 0 || alloc_seq >= g_pa_alloc_count { return -1; }
    an := r64(g_pa_alloc_nodes, alloc_seq * 8);
    return r64(g_df_nodes, an * ESZ_DFNODE + OFF_DF_DEST);
}

fn pv_is_in_unsafe(node_seq: int) -> int {
    si : ., mut = 0;
    loop { if si >= g_sg_count { break; }
        kind := r64(g_sgs, si * ESZ_SG + OFF_SG_KIND);
        if kind == SG_UNSAFE {
            nstart := r64(g_sgs, si * ESZ_SG + OFF_SG_NSTART);
            ncount := r64(g_sgs, si * ESZ_SG + OFF_SG_NCOUNT);
            if node_seq >= nstart && node_seq < nstart + ncount {
                return 1;
            }
        }
        si = si + 1;
    }
    return 0;
}

fn provenance_verify_func(nstart: int, ncount: int) {
    ni : ., mut = nstart;
    loop { if ni >= nstart + ncount { break; }
        op := r64(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE);
        s1 := r64(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1);
        // R2 P5 Task 2（D19）：本处读的是**访问宽度**（字节数）——单槽化前它住在混用
        // tk 槽，现居**辅码**槽（OFF_DF_AUX）。值域/语义零变化（仅 IR_DEREF/IR_STORE_PTR
        // 消费；两 op 均属辅码面）。读 40 槽（类型项引用）会把项行号当宽度 = 静默错值。
        width : ., mut = r64(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_AUX);

        if (op == IR_DEREF || op == IR_STORE_PTR) && s1 >= 0 {
            // Skip checks in unsafe blocks
            if pv_is_in_unsafe(ni) != 0 { ni = ni + 1; continue; }

            ptr_ti := irv_type(s1);
            if ptr_ti >= 0 && get_type_kind(ptr_ti) == TYP_PTR && get_type_extra(ptr_ti) != 0 {
                check_error(EC_TU_DEREF,
                    "external pointer dereference requires unsafe",
                    0, 0);
                ni = ni + 1;
                continue;
            }

            if width <= 0 { width = 8; }

            pts := r64(g_pts, s1 * 8);
            off := r64(g_offsets, s1 * 8);
            runtime_targets : ., mut = 0;
            runtime_size : ., mut = 0;
            runtime_base : ., mut = -1;

            // Check each potential allocation target in the points-to set
            mask : int, mut = 1;
            bi : ., mut = 0;
            loop { if bi >= 64 { break; }
                if (pts / mask) % 2 != 0 {
                    alloc_size := get_alloc_size(bi);
                    if alloc_size >= 0 && off >= 0 {
                        if width > alloc_size || off > alloc_size - width {
                            check_error(EC_TK_INDEX,
                                "pointer out of bounds: offset " + int_str(off) +
                                " + width " + int_str(width) +
                                " > size " + int_str(alloc_size),
                                0, 0);
                        }
                    } else if alloc_size >= 0 {
                        if width > alloc_size {
                            check_error(EC_TK_INDEX,
                                "pointer access width " + int_str(width) +
                                " exceeds allocation size " + int_str(alloc_size),
                                0, 0);
                        } else {
                            runtime_targets = runtime_targets + 1;
                            runtime_size = alloc_size;
                            runtime_base = get_alloc_var(bi);
                        }
                    } else {
                        // 分配信息未知 → 不填充 s2/s3；编码器（instr.cr）对 s3=0
                        // 保留 null 陷阱（F6 修复——此前 s3=0 连 null 陷阱都没有）
                    }
                }
                mask = mask * 2;
                bi = bi + 1;
            }

            if off < 0 && runtime_targets == 1 && runtime_base >= 0 {
                w64(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S3, runtime_size);
                if op == IR_DEREF {
                    w64(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S2, runtime_base);
                } else {
                    // IR_STORE_PTR has no result, so dest carries the runtime base.
                    w64(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_DEST, runtime_base);
                }
            } else if off < 0 && runtime_targets > 1 {
                check_error(EC_TK_INDEX,
                    "runtime pointer bounds check has multiple allocation targets",
                    0, 0);
            }
        }
        ni = ni + 1;
    }
}

fn provenance_verify_all() {
    // Safety pass — always runs
    fi : ., mut = 0;
    loop { if fi >= g_ir_func_count { break; }
        nstart := r64(g_df_func_node_start, fi * 8);
        ncount := r64(g_df_func_node_count, fi * 8);
        provenance_verify_func(nstart, ncount);
        fi = fi + 1;
    }
}
