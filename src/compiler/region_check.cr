// === region_check.cr ===
// RegionCheck pass — verifies DEREF targets are in live subgraphs.
// Runs after PointerAnalysis (ptr_analysis.cr) which builds g_pts table.

fn subgraph_containing(node_seq: int) -> int {
    // 显式映射：O(1) 归属查询（g_df_node_region 由 df_create_node 写入）
    if node_seq >= 0 && node_seq < g_df_node_count {
        return r64(g_df_node_region, node_seq * 8);
    }
    return -1;
}

fn is_in_unsafe(node_seq: int) -> int {
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

fn alloc_seq_to_sg(alloc_seq: int) -> int {
    // Map ALLOC node sequence number to its subgraph
    return subgraph_containing(alloc_seq);
}

fn rc_pts_has_escaped(pts: int, ni: int, nstart: int) -> int {
    // Check if any allocation targeted by pts escapes its parent subgraph
    mask : int, mut = 1;
    bi : ., mut = 0;
    loop { if bi >= 64 { break; }
        if (pts / mask) % 2 == 1 {
            // 修复 3 配套：pts 位号 = 全局 alloc 序号（g_pa_alloc_count），
            // 经映射表查 DF 节点序号（旧代码 bi+nstart 是错误语义——alloc 序号
            // 不是"函数内第 nstart+bi 个节点"）。
            alloc_node := r64(g_pa_alloc_nodes, bi * 8);
            alloc_sg := alloc_seq_to_sg(alloc_node);
            deref_sg := subgraph_containing(ni);
            if alloc_sg >= 0 && deref_sg >= 0 {
                alloc_exit := r64(g_sgs, alloc_sg * ESZ_SG + OFF_SG_EXIT);
                if alloc_exit >= 0 && ni > alloc_exit {
                    return 1;  // escaped — alloc subgraph already exited
                }
            }
        }
        mask = mask * 2;
        bi = bi + 1;
    }
    return 0;
}

fn rc_return_escape(ni: int, s1: int, nstart: int) {
    // Siebert: check if a returned pointer escapes its region
    if s1 < 0 { return; }
    ptr_ti := irv_type(s1);
    // S6 (a)（2026-09-20，维护者裁）：**地址型 = `TYP_PTR` ∪ `TYP_REF`**。
    // 裁定二把 `&x` 改判 `TYP_REF` ⇒ 只认 PTR 会让本门对 `&x` 派生的值**静默失效**
    // （实测红：`test_region_check_pointer_escape` 的 `return &x;` 不再报 B010）。
    // 本处**只判 kind、不读 `extra`** ⇒ 加一个 `|| TYP_REF` 是**等价扩**
    // （不触碰「REF 的 `extra` = mut 标记」那个坑——那是 `provenance_verify` 独有的问题，见其 (b′)）。
    if ptr_ti < 0 || (get_type_kind(ptr_ti) != TYP_PTR && get_type_kind(ptr_ti) != TYP_REF) { return; }
    pts := r64(g_pts, s1 * 8);
    if pts == 0 { return; }
    cur_sg := subgraph_containing(ni);
    if cur_sg < 0 { return; }
    // Check if any target allocation is in a subgraph that will exit
    // before the caller can use the returned value
    mask : int, mut = 1;
    bi : ., mut = 0;
    loop { if bi >= 64 { break; }
        if (pts / mask) % 2 == 1 {
            alloc_node := r64(g_pa_alloc_nodes, bi * 8);
            alloc_sg := alloc_seq_to_sg(alloc_node);
            if alloc_sg >= 0 {
                alloc_sg_kind := r64(g_sgs, alloc_sg * ESZ_SG + OFF_SG_KIND);
                if alloc_sg_kind == SG_FUNC {  // function-level alloc = ok to return
                    bi = bi + 1; mask = mask * 2; continue;
                }
                alloc_exit := r64(g_sgs, alloc_sg * ESZ_SG + OFF_SG_EXIT);
                if alloc_exit >= 0 && ni > alloc_exit {
                    check_error(EC_B_LIFETIME,
                        "region escape: returning pointer to exited subgraph allocation",
                        0, 0);
                }
            }
        }
        mask = mask * 2;
        bi = bi + 1;
    }
}

fn rc_store_escape(ni: int, ptr_var: int, val_var: int) {
    // Siebert: check if storing a pointer creates a dangling reference
    // *ptr = val — val's target allocations must have lifetime >= ptr's
    if val_var < 0 { return; }
    val_ti := irv_type(val_var);
    // S6 (a)：同上——地址型 = `TYP_PTR` ∪ `TYP_REF`（本处只判 kind、不读 `extra`）。变量名是 `val_ti`。
    if val_ti < 0 || (get_type_kind(val_ti) != TYP_PTR && get_type_kind(val_ti) != TYP_REF) { return; }
    val_pts := r64(g_pts, val_var * 8);
    if val_pts == 0 { return; }
    rc_pts_has_escaped(val_pts, ni, 0);  // simplified check
}

fn region_check_func(nstart: int, ncount: int) {
    ni : ., mut = nstart;
    loop { if ni >= nstart + ncount { break; }
        op := r64(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE);
        d  := r64(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_DEST);
        s1 := r64(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1);
        s2 := r64(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S2);

        if is_in_unsafe(ni) != 0 { ni = ni + 1; continue; }

        if op == IR_DEREF && d >= 0 && s1 >= 0 {
            // Only pointer-typed values carry provenance. An integer loaded
            // through a pointer is ordinary data, not another pointer.
            ptr_ti := irv_type(s1);
            // S6 (a)：同上——地址型 = `TYP_PTR` ∪ `TYP_REF`（`IR_DEREF` 的被解引用者）。
            if ptr_ti < 0 || (get_type_kind(ptr_ti) != TYP_PTR && get_type_kind(ptr_ti) != TYP_REF) {
                ni = ni + 1; continue;
            }
            pts := r64(g_pts, s1 * 8);
            if pts != 0 {
                mask : int, mut = 1;
                bi : ., mut = 0;
                loop { if bi >= 64 { break; }
                    if (pts / mask) % 2 == 1 {
                        alloc_node := r64(g_pa_alloc_nodes, bi * 8);
                        alloc_sg := alloc_seq_to_sg(alloc_node);
                        deref_sg := subgraph_containing(ni);
                        if alloc_sg >= 0 && deref_sg >= 0 {
                            alloc_exit := r64(g_sgs, alloc_sg * ESZ_SG + OFF_SG_EXIT);
                            if alloc_exit >= 0 && ni > alloc_exit {
                                check_error(EC_B_LIFETIME,
                                    "dangling pointer: allocation subgraph exited before deref",
                                    0, 0);
                            }
                        }
                    }
                    mask = mask * 2;
                    bi = bi + 1;
                }
            }
        }

        // Siebert: interprocedural escape via return
        if op == IR_RETURN && s1 >= 0 {
            rc_return_escape(ni, s1, nstart);
        }

        // Siebert: interprocedural escape via store
        if op == IR_STORE_PTR {
            rc_store_escape(ni, s1, s2);
        }

        ni = ni + 1;
    }
}

fn region_check_all() {
    // Safety pass — always runs
    fi : ., mut = 0;
    loop { if fi >= g_ir_func_count { break; }
        nstart := r64(g_df_func_node_start, fi * 8);
        ncount := r64(g_df_func_node_count, fi * 8);
        region_check_func(nstart, ncount);
        fi = fi + 1;
    }
}
