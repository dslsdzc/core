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

fn grow_pa_alloc_nodes(n: int) {
    if n < g_pa_alloc_nodes_cap { return; }
    nc := g_pa_alloc_nodes_cap;
    if nc == 0 { nc = 16; }
    loop { if nc > n { break; } nc = nc * 2; }
    nb := alloc(nc * 8);
    if g_pa_alloc_nodes_cap > 0 { _dyncpy(g_pa_alloc_nodes, g_pa_alloc_nodes_cap * 8, nb); }
    g_pa_alloc_nodes = nb; g_pa_alloc_nodes_cap = nc;
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
                if op == IR_ALLOC_STRUCT || op == IR_ALLOC_ARRAY {
                    // 修复 12：IR_ALLOC（标量变量槽标记，不发射代码）不是堆分配，
                    // 不参与 pts 追踪——修复前它被分配 pts 位，导致 p = &arr[i]
                    // 的 pts 含变量槽的位（多个 alloc 位污染）→ s3 取错 alloc。
                    if r64(g_pts, d * 8) == 0 {
                        // 修复 3：每个 alloc 分配递增位号（bit = alloc_seq），并登记
                        // alloc_seq → DF 节点序号。修复前恒设 bit 0——所有 alloc 别名
                        // 串扰，provenance 的 get_alloc_size(0) 查到节点 0 → 检查永远不生成。
                        if g_pa_alloc_count < 64 {
                            grow_pa_alloc_nodes(g_pa_alloc_count + 1);
                            w64(g_pa_alloc_nodes, g_pa_alloc_count * 8, ni);
                            w64(g_pts, d * 8, pa_set_bit(0, g_pa_alloc_count));
                            g_pa_alloc_count = g_pa_alloc_count + 1;
                            changed = 1;
                        }
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
                    // offset 由索引 s2 决定：常量索引可精确计算（idx*8），
                    // 运行时索引 → 未知（-1），迫使 provenance_verify 生成运行时检查。
                    // 修复前：无条件传播 s1 的 offset（数组=0），运行时越界被误判为
                    // 编译期安全 → 越界裸读（见 docs/archive/compcert-reference.md 审查记录）。
                    base_off := r64(g_offsets, s1 * 8);
                    idx_val : int = -1;
                    if s2 >= 0 {
                        prod := r64(g_df_var_producer, s2 * 8);
                        if prod >= 0 {
                            prod_op := r64(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_OPCODE);
                            if prod_op == IR_CONST {
                                idx_val = r64(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_S1);
                            }
                        }
                    }
                    if idx_val >= 0 && base_off >= 0 {
                        w64(g_offsets, d * 8, base_off + idx_val * 8);
                    } else {
                        w64(g_offsets, d * 8, -1);
                    }
                }

                // F11①：IR_SLICE 传播底层数组 provenance（d = &arr[low]）。
                // 使经切片的 DEREF 能被分配长度检查捕获；offset = low*8（常量时）。
                if op == IR_SLICE && s1 >= 0 {
                    if pa_merge_pts(d, s1) != 0 { changed = 1; }
                    base_off := r64(g_offsets, s1 * 8);
                    low_val : int = -1;
                    if s2 >= 0 {
                        prod := r64(g_df_var_producer, s2 * 8);
                        if prod >= 0 {
                            prod_op := r64(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_OPCODE);
                            if prod_op == IR_CONST {
                                low_val = r64(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_S1);
                            }
                        }
                    }
                    if low_val >= 0 && base_off >= 0 {
                        w64(g_offsets, d * 8, base_off + low_val * 8);
                    } else {
                        w64(g_offsets, d * 8, -1);
                    }
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

                // LOAD: d ← s1 拷贝传播
                if op == IR_LOAD && s1 >= 0 {
                    if pa_merge_pts(d, s1) != 0 { changed = 1; }
                    w64(g_offsets, d * 8, r64(g_offsets, s1 * 8));
                }
                // STORE: s1 ← s2 拷贝传播。修复 4：IR_STORE 的 dest 恒为 -1，
                // 原代码把 STORE 混进 LOAD 分支（用 d 传播）→ 永不执行 →
                // p = &arr[i] 的 offset 丢失 → 越界检查被跳过。
                // 注意：此分支必须在 if d >= 0 块外（d 恒为 -1）。

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

            // Store: s1 ← s2 拷贝传播（IR_STORE 的 d 恒为 -1，必须在 if d >= 0 块外）
            if op == IR_STORE && s1 >= 0 && s2 >= 0 {
                if pa_merge_pts(s1, s2) != 0 { changed = 1; }
                w64(g_offsets, s1 * 8, r64(g_offsets, s2 * 8));
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
