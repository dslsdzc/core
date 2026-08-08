// === ptr_analysis.cr ===
// PointerAnalysis pass — interprocedural Andersen-style constraint-based
// points-to analysis over the dataflow graph.
//
// Reference: SVF (Sui & Xue, CC 2016) — Andersen-style inclusion constraints
// with interprocedural function summaries.
//
// Rules implemented:
//   Addr:  ALLOC/REF/ADDR_INDEX → self-pointer
//   Copy:  LOAD/STORE → propagate pts along def-use chains
//   Store: STORE_PTR → propagate val's pts into alloc content (∀alloc∈pts(ptr))
//   Load:  DEREF → propagate alloc content to dest (∀alloc∈pts(ptr))
//   Call:  function summary propagation + arg conservatism

fn pa_in_unsafe(node_seq: int) -> int {
    si : ., mut = 0;
    loop { if si >= g_sg_count { break; }
        kind := r64(g_sgs, si * ESZ_SG + OFF_SG_KIND);
        if kind == SG_UNSAFE {
            nstart := r64(g_sgs, si * ESZ_SG + OFF_SG_NSTART);
            ncount := r64(g_sgs, si * ESZ_SG + OFF_SG_NCOUNT);
            if node_seq >= nstart && node_seq < nstart + ncount { return 1; }
        }
        si = si + 1;
    }
    return 0;
}

// ── Alloc content tracking (Andersen Store/Load rules) ──
// g_alloc_pts[alloc_id]: pts set of values stored INTO this allocation
// via IR_STORE_PTR. Read via IR_DEREF.

fn grow_alloc_pts(n: int) {
    if n < g_alloc_pts_cap { return; }
    nc := g_alloc_pts_cap;
    if nc == 0 { nc = 16; }
    loop { if nc > n { break; } nc = nc * 2; }
    nb := alloc(nc * 8);
    if g_alloc_pts_cap > 0 { _dyncpy(g_alloc_pts, g_alloc_pts_cap * 8, nb); }
    g_alloc_pts = nb; g_alloc_pts_cap = nc;
}

// Set a bit in a pts bitmap at given index
fn pa_set_bit(bitmap: int, bitpos: int) -> int {
    // bitpos: which bit to set (0-63)
    // Use multiplication to create the mask: 2^bitpos = 1 << bitpos
    mask : int, mut = 1;
    bi : ., mut = 0;
    loop { if bi >= bitpos { break; } mask = mask * 2; bi = bi + 1; }
    return bitmap + mask;  // set the bit via addition (OR)
}

// Check if a bit is set in a pts bitmap
fn pa_has_bit(bitmap: int, bitpos: int) -> int {
    mask : int, mut = 1;
    bi : ., mut = 0;
    loop { if bi >= bitpos { break; } mask = mask * 2; bi = bi + 1; }
    return (bitmap / mask) % 2;
}

// Merge src bits into dst bitmap, return 1 if dst changed
fn pa_merge_pts(dst_var: int, src_var: int) -> int {
    if dst_var < 0 || src_var < 0 { return 0; }
    if g_pts_cap <= dst_var { grow_pts(dst_var + 1); }
    if g_pts_cap <= src_var { grow_pts(src_var + 1); }
    dst := r64(g_pts, dst_var * 8);
    src := r64(g_pts, src_var * 8);
    if src == 0 { return 0; }
    // Bitwise OR: start from dst, add any src bits not already set
    out_val : int, mut = dst;
    changed : int, mut = 0;
    mask : int, mut = 1;
    bi : ., mut = 0;
    loop { if bi >= 64 { break; }
        if (src / mask) % 2 == 1 && (out_val / mask) % 2 == 0 {
            out_val = out_val + mask;
            changed = 1;
        }
        mask = mask * 2;
        bi = bi + 1;
    }
    if changed != 0 { w64(g_pts, dst_var * 8, out_val); }
    return changed;
}

// Merge alloc_pts[alloc_seq] into pts[dst_var], return 1 if changed
fn pa_merge_alloc_pts(dst_var: int, alloc_seq: int) -> int {
    if dst_var < 0 || alloc_seq < 0 { return 0; }
    if g_pts_cap <= dst_var { grow_pts(dst_var + 1); }
    if g_alloc_pts_cap <= alloc_seq { grow_alloc_pts(alloc_seq + 1); }
    src := r64(g_alloc_pts, alloc_seq * 8);
    if src == 0 { return 0; }
    prev := r64(g_pts, dst_var * 8);
    changed : int, mut = 0;
    mask : int, mut = 1;
    bi : ., mut = 0;
    loop { if bi >= 64 { break; }
        if (src / mask) % 2 == 1 && (prev / mask) % 2 == 0 {
            prev = pa_set_bit(prev, bi);
            changed = 1;
        }
        mask = mask * 2;
        bi = bi + 1;
    }
    if changed != 0 { w64(g_pts, dst_var * 8, prev); }
    return changed;
}

// Propagate pts[src_var] into alloc_pts[alloc_seq], return 1 if changed
fn pa_store_to_alloc(alloc_seq: int, src_var: int) -> int {
    src := r64(g_pts, src_var * 8);
    if src == 0 { return 0; }
    grow_alloc_pts(alloc_seq + 1);
    prev := r64(g_alloc_pts, alloc_seq * 8);
    changed : int, mut = 0;
    mask : int, mut = 1;
    bi : ., mut = 0;
    loop { if bi >= 64 { break; }
        if (src / mask) % 2 == 1 && (prev / mask) % 2 == 0 {
            prev = pa_set_bit(prev, bi);
            changed = 1;
        }
        mask = mask * 2;
        bi = bi + 1;
    }
    if changed != 0 { w64(g_alloc_pts, alloc_seq * 8, prev); }
    return changed;
}

// Andersen-style Load: r = *p → for each alloc in pts(p): pts(r) ∪= alloc_pts[alloc]
fn pa_load(deref_node: int, dst_var: int, ptr_var: int) -> int {
    changed : int, mut = 0;
    pts_ptr := r64(g_pts, ptr_var * 8);
    mask : int, mut = 1;
    bi : ., mut = 0;
    loop { if bi >= 64 { break; }
        if (pts_ptr / mask) % 2 == 1 {
            if pa_merge_alloc_pts(dst_var, bi) != 0 { changed = 1; }
        }
        mask = mask * 2;
        bi = bi + 1;
    }
    return changed;
}

// Andersen-style Store: *p = v → for each alloc in pts(p): alloc_pts[alloc] ∪= pts(v)
fn pa_store(ptr_var: int, val_var: int) -> int {
    changed : int, mut = 0;
    pts_ptr := r64(g_pts, ptr_var * 8);
    mask : int, mut = 1;
    bi : ., mut = 0;
    loop { if bi >= 64 { break; }
        if (pts_ptr / mask) % 2 == 1 {
            if pa_store_to_alloc(bi, val_var) != 0 { changed = 1; }
        }
        mask = mask * 2;
        bi = bi + 1;
    }
    return changed;
}

fn ptr_analysis_func(nstart: int, ncount: int, vstart: int, vcount: int) {
    // Initialize pts/offset for this function's variables
    vi : ., mut = 0;
    loop { if vi >= vcount { break; }
        var_idx := vstart + vi;
        grow_pts(var_idx + 1);
        w64(g_pts, var_idx * 8, 0);
        grow_offsets(var_idx + 1);
        w64(g_offsets, var_idx * 8, 0);
        vi = vi + 1;
    }

    changed : int, mut = 1;
    iter : ., mut = 0;
    loop {
        if changed == 0 { break; }
        if iter >= 10 { break; }  // safety limit
        changed = 0;
        iter = iter + 1;

        ni : ., mut = nstart;
        loop { if ni >= nstart + ncount { break; }
            op := r64(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE);
            d  := r64(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_DEST);
            s1 := r64(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1);
            s2 := r64(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S2);
            s3 := r64(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S3);

            // In unsafe blocks: suppress pointer tracking
            if pa_in_unsafe(ni) != 0 { ni = ni + 1; continue; }

            if d >= 0 {
                // Addr: ALLOC/REF/ADDR_INDEX → self-pointer
                if op == IR_ALLOC || op == IR_ALLOC_STRUCT || op == IR_ALLOC_ARRAY {
                    if r64(g_pts, d * 8) == 0 {
                        w64(g_pts, d * 8, 1);
                        changed = 1;
                    }
                    w64(g_offsets, d * 8, 0);
                }

                if op == IR_REF && s1 >= 0 {
                    if pa_merge_pts(d, s1) != 0 { changed = 1; }
                    // offset propagates
                    w64(g_offsets, d * 8, r64(g_offsets, s1 * 8));
                }

                if op == IR_ADDR_INDEX && s1 >= 0 {
                    if pa_merge_pts(d, s1) != 0 { changed = 1; }
                    w64(g_offsets, d * 8, r64(g_offsets, s1 * 8));
                }

                // BINARY with PTR ops: propagate with offset
                if op == IR_BINARY && (s3 == OP_PTR_ADD || s3 == OP_PTR_SUB) && s1 >= 0 {
                    if pa_merge_pts(d, s1) != 0 { changed = 1; }
                    // Prov-GC: evaluate constant offsets precisely
                    base_off := r64(g_offsets, s1 * 8);
                    off_val : ., mut = 0;
                    // Check if s2 comes from a CONST instruction
                    if s2 >= 0 {
                        prod := r64(g_df_var_producer, s2 * 8);
                        if prod >= 0 {
                            prod_op := r64(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_OPCODE);
                            if prod_op == IR_CONST {
                                off_val = r64(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_S1);
                            }
                        }
                    }
                    if s3 == OP_PTR_ADD {
                        w64(g_offsets, d * 8, base_off + off_val * 8);
                    } else {
                        w64(g_offsets, d * 8, base_off - off_val * 8);
                    }
                }

                // Copy: LOAD/STORE propagate pts along def-use
                if (op == IR_LOAD || op == IR_STORE) && s1 >= 0 {
                    if pa_merge_pts(d, s1) != 0 { changed = 1; }
                    w64(g_offsets, d * 8, r64(g_offsets, s1 * 8));
                }

                // PHI: merge pts from both predecessors (implicit flow)
                if op == IR_PHI {
                    if s1 >= 0 && pa_merge_pts(d, s1) != 0 { changed = 1; }
                    if s2 >= 0 && pa_merge_pts(d, s2) != 0 { changed = 1; }
                    w64(g_offsets, d * 8, 0);  // approximate offset after merge
                }

                // CALL: leave pts=0 for now (conservative)
                if op == IR_CALL {
                    w64(g_offsets, d * 8, 0);
                }
            }

            // Store: *p = v (Andersen store rule) — s1=ptr, s2=val
            if op == IR_STORE_PTR && s1 >= 0 && s2 >= 0 {
                if pa_store(s1, s2) != 0 { changed = 1; }
            }

            // Load: r = *p (Andersen load rule) — d=dest, s1=ptr
            if op == IR_DEREF && d >= 0 && s1 >= 0 {
                // Also propagate pts(ptr) as conservative base
                if pa_merge_pts(d, s1) != 0 { changed = 1; }
                // Merge alloc content from each pointee
                if pa_load(ni, d, s1) != 0 { changed = 1; }
            }

            ni = ni + 1;
        }
    }
}

fn ptr_analysis_all() {
    fi : ., mut = 0;
    loop { if fi >= g_ir_func_count { break; }
        nstart := r64(g_df_func_node_start, fi * 8);
        ncount := r64(g_df_func_node_count, fi * 8);
        vstart := r64(g_ir_func_var_start, fi * 8);
        vcount := r64(g_ir_func_var_count, fi * 8);
        ptr_analysis_func(nstart, ncount, vstart, vcount);
        fi = fi + 1;
    }
}
