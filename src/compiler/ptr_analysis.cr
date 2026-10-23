// === ptr_analysis.cr ===
// PointerAnalysis: Andersen-style constraint-based points-to analysis over the
// dataflow graph.
//
// Reference: SVF (Sui & Xue, CC 2016).
//
// Rules:
// - Addr: ALLOC, REF, and ADDR_INDEX create a self-pointer.
// - Copy: LOAD and STORE propagate points-to sets along def-use edges.
// - Store: STORE_PTR propagates the value's set into allocation contents for
//   each allocation in the pointer's set.
// - Load: DEREF propagates allocation contents to the destination.
// - Call: results are conservatively left empty; function summaries are not
//   implemented.

fn pa_in_unsafe(node_seq: int) -> int:
    si : ., mut = 0
    loop:
        if si >= g_sg_count:
            break
        kind := r64(g_sgs, si * ESZ_SG + OFF_SG_KIND)
        if kind == SG_UNSAFE:
            nstart := r64(g_sgs, si * ESZ_SG + OFF_SG_NSTART)
            ncount := r64(g_sgs, si * ESZ_SG + OFF_SG_NCOUNT)
            if node_seq >= nstart && node_seq < nstart + ncount:
                return 1
        si = si + 1
    return 0

// Allocation content tracking for the Andersen store and load rules.
// g_alloc_pts[alloc_id] is the set of values stored into the allocation through
// IR_STORE_PTR and read through IR_DEREF.

fn grow_alloc_pts(n: int):
    if n < g_alloc_pts_cap:
        return
    nc := g_alloc_pts_cap
    if nc == 0:
        nc = 16
    loop:
        if nc > n:
            break
        nc = nc * 2
    nb := alloc(nc * 8)
    if g_alloc_pts_cap > 0:
        _dyncpy(g_alloc_pts, g_alloc_pts_cap * 8, nb)
    g_alloc_pts = nb
    g_alloc_pts_cap = nc

fn grow_pa_alloc_nodes(n: int):
    if n < g_pa_alloc_nodes_cap:
        return
    nc := g_pa_alloc_nodes_cap
    if nc == 0:
        nc = 16
    loop:
        if nc > n:
            break
        nc = nc * 2
    nb := alloc(nc * 8)
    if g_pa_alloc_nodes_cap > 0:
        _dyncpy(g_pa_alloc_nodes, g_pa_alloc_nodes_cap * 8, nb)
    g_pa_alloc_nodes = nb
    g_pa_alloc_nodes_cap = nc

// Set a bit in a points-to bitmap.
fn pa_set_bit(bitmap: int, bitpos: int) -> int:
    // Build the mask by doubling; the language has no shift or bitwise operators.
    mask : int, mut = 1
    bi : ., mut = 0
    loop:
        if bi >= bitpos:
            break
        mask = mask * 2
        bi = bi + 1
    return bitmap + mask  // set the bit by addition

// Check whether a bit is set.
fn pa_has_bit(bitmap: int, bitpos: int) -> int:
    mask : int, mut = 1
    bi : ., mut = 0
    loop:
        if bi >= bitpos:
            break
        mask = mask * 2
        bi = bi + 1
    return (bitmap / mask) % 2

// Merge src into dst and return 1 when dst changed.
fn pa_merge_pts(dst_var: int, src_var: int) -> int:
    if dst_var < 0 || src_var < 0:
        return 0
    if g_pts_cap <= dst_var:
        grow_pts(dst_var + 1)
    if g_pts_cap <= src_var:
        grow_pts(src_var + 1)
    dst := r64(g_pts, dst_var * 8)
    src := r64(g_pts, src_var * 8)
    if src == 0:
        return 0
    // Union: start from dst and add src bits that are not set.
    out_val : int, mut = dst
    changed : int, mut = 0
    mask : int, mut = 1
    bi : ., mut = 0
    loop:
        if bi >= 64:
            break
        if (src / mask) % 2 == 1 && (out_val / mask) % 2 == 0:
            out_val = out_val + mask
            changed = 1
        mask = mask * 2
        bi = bi + 1
    if changed != 0:
        w64(g_pts, dst_var * 8, out_val)
    return changed

// Merge alloc_pts[alloc_seq] into pts[dst_var] and return 1 when changed.
fn pa_merge_alloc_pts(dst_var: int, alloc_seq: int) -> int:
    if dst_var < 0 || alloc_seq < 0:
        return 0
    if g_pts_cap <= dst_var:
        grow_pts(dst_var + 1)
    if g_alloc_pts_cap <= alloc_seq:
        grow_alloc_pts(alloc_seq + 1)
    src := r64(g_alloc_pts, alloc_seq * 8)
    if src == 0:
        return 0
    prev := r64(g_pts, dst_var * 8)
    changed : int, mut = 0
    mask : int, mut = 1
    bi : ., mut = 0
    loop:
        if bi >= 64:
            break
        if (src / mask) % 2 == 1 && (prev / mask) % 2 == 0:
            prev = pa_set_bit(prev, bi)
            changed = 1
        mask = mask * 2
        bi = bi + 1
    if changed != 0:
        w64(g_pts, dst_var * 8, prev)
    return changed

// Propagate pts[src_var] into alloc_pts[alloc_seq] and return 1 when changed.
fn pa_store_to_alloc(alloc_seq: int, src_var: int) -> int:
    src := r64(g_pts, src_var * 8)
    if src == 0:
        return 0
    grow_alloc_pts(alloc_seq + 1)
    prev := r64(g_alloc_pts, alloc_seq * 8)
    changed : int, mut = 0
    mask : int, mut = 1
    bi : ., mut = 0
    loop:
        if bi >= 64:
            break
        if (src / mask) % 2 == 1 && (prev / mask) % 2 == 0:
            prev = pa_set_bit(prev, bi)
            changed = 1
        mask = mask * 2
        bi = bi + 1
    if changed != 0:
        w64(g_alloc_pts, alloc_seq * 8, prev)
    return changed

// Load rule: for each allocation in pts(p), add alloc_pts[alloc] to pts(r).
fn pa_load(deref_node: int, dst_var: int, ptr_var: int) -> int:
    changed : int, mut = 0
    pts_ptr := r64(g_pts, ptr_var * 8)
    mask : int, mut = 1
    bi : ., mut = 0
    loop:
        if bi >= 64:
            break
        if (pts_ptr / mask) % 2 == 1:
            if pa_merge_alloc_pts(dst_var, bi) != 0:
                changed = 1
        mask = mask * 2
        bi = bi + 1
    return changed

// Store rule: for each allocation in pts(p), add pts(v) to alloc_pts[alloc].
fn pa_store(ptr_var: int, val_var: int) -> int:
    changed : int, mut = 0
    pts_ptr := r64(g_pts, ptr_var * 8)
    mask : int, mut = 1
    bi : ., mut = 0
    loop:
        if bi >= 64:
            break
        if (pts_ptr / mask) % 2 == 1:
            if pa_store_to_alloc(bi, val_var) != 0:
                changed = 1
        mask = mask * 2
        bi = bi + 1
    return changed

fn ptr_analysis_func(nstart: int, ncount: int, vstart: int, vcount: int):
    // Initialize points-to sets and offsets for this function's variables.
    vi : ., mut = 0
    loop:
        if vi >= vcount:
            break
        var_idx := vstart + vi
        grow_pts(var_idx + 1)
        w64(g_pts, var_idx * 8, 0)
        grow_offsets(var_idx + 1)
        w64(g_offsets, var_idx * 8, 0)
        vi = vi + 1

    changed : int, mut = 1
    iter : ., mut = 0
    loop:
        if changed == 0:
            break
        if iter >= 10:
            break
        // Bound the fixed-point iterations.
        changed = 0
        iter = iter + 1

        ni : ., mut = nstart
        loop:
            if ni >= nstart + ncount:
                break
            op := r64(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
            d  := r64(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_DEST)
            s1 := r64(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)
            s2 := r64(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S2)
            s3 := r64(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S3)

            // Suppress pointer tracking inside unsafe blocks.
            if pa_in_unsafe(ni) != 0:
                ni = ni + 1
                continue

            if d >= 0:
                // Addr: ALLOC, REF, and ADDR_INDEX create a self-pointer.
                if op == IR_ALLOC_STRUCT || op == IR_ALLOC_ARRAY:
                    // IR_ALLOC marks a scalar slot and is not tracked. Only heap
                    // allocations receive points-to bits.
                    if r64(g_pts, d * 8) == 0:
                        // Give each allocation its own bit and record the mapping
                        // from bit to DF node for size queries.
                        if g_pa_alloc_count < 64:
                            grow_pa_alloc_nodes(g_pa_alloc_count + 1)
                            w64(g_pa_alloc_nodes, g_pa_alloc_count * 8, ni)
                            w64(g_pts, d * 8, pa_set_bit(0, g_pa_alloc_count))
                            g_pa_alloc_count = g_pa_alloc_count + 1
                            changed = 1
                    w64(g_offsets, d * 8, 0)

                if op == IR_REF && s1 >= 0:
                    if pa_merge_pts(d, s1) != 0:
                        changed = 1
                    // Propagate the offset.
                    w64(g_offsets, d * 8, r64(g_offsets, s1 * 8))

                if op == IR_ADDR_INDEX && s1 >= 0:
                    if pa_merge_pts(d, s1) != 0:
                        changed = 1
                    // The index decides the offset. A constant index gives
                    // index times the mapping stride; a dynamic index gives -1,
                    // which makes provenance_verify emit a runtime check.
                    base_off := r64(g_offsets, s1 * 8)
                    idx_val : int = -1
                    if s2 >= 0:
                        prod := r64(g_df_var_producer, s2 * 8)
                        if prod >= 0:
                            prod_op := r64(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_OPCODE)
                            if prod_op == IR_CONST:
                                idx_val = r64(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_S1)
                    if idx_val >= 0 && base_off >= 0:
                        w64(g_offsets, d * 8, base_off + mp_offset(idx_val, TI_INT))
                    else:
                        w64(g_offsets, d * 8, -1)

                // IR_SLICE propagates the underlying array provenance for
                // d = &arr[low]. A constant low gives low times the mapping stride.
                if op == IR_SLICE && s1 >= 0:
                    if pa_merge_pts(d, s1) != 0:
                        changed = 1
                    base_off := r64(g_offsets, s1 * 8)
                    low_val : int = -1
                    if s2 >= 0:
                        prod := r64(g_df_var_producer, s2 * 8)
                        if prod >= 0:
                            prod_op := r64(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_OPCODE)
                            if prod_op == IR_CONST:
                                low_val = r64(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_S1)
                    if low_val >= 0 && base_off >= 0:
                        w64(g_offsets, d * 8, base_off + mp_offset(low_val, TI_INT))
                    else:
                        w64(g_offsets, d * 8, -1)

                // Pointer add and subtract propagate provenance and offset.
                if op == IR_BINARY && (s3 == OP_PTR_ADD || s3 == OP_PTR_SUB) && s1 >= 0:
                    if pa_merge_pts(d, s1) != 0:
                        changed = 1
                    // Evaluate a constant offset precisely.
                    base_off := r64(g_offsets, s1 * 8)
                    off_val : ., mut = 0
                    // Check whether s2 comes from a CONST instruction.
                    if s2 >= 0:
                        prod := r64(g_df_var_producer, s2 * 8)
                        if prod >= 0:
                            prod_op := r64(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_OPCODE)
                            if prod_op == IR_CONST:
                                off_val = r64(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_S1)
                    if s3 == OP_PTR_ADD:
                        w64(g_offsets, d * 8, base_off + off_val * 8)
                    else:
                        w64(g_offsets, d * 8, base_off - off_val * 8)

                // LOAD: copy provenance from s1 to d.
                if op == IR_LOAD && s1 >= 0:
                    if pa_merge_pts(d, s1) != 0:
                        changed = 1
                    w64(g_offsets, d * 8, r64(g_offsets, s1 * 8))
                // IR_STORE is handled outside the d >= 0 block because its dest
                // is always -1.

                // PHI: merge points-to sets from both predecessors.
                if op == IR_PHI:
                    if s1 >= 0 && pa_merge_pts(d, s1) != 0:
                        changed = 1
                    if s2 >= 0 && pa_merge_pts(d, s2) != 0:
                        changed = 1
                    w64(g_offsets, d * 8, 0)  // approximate offset after the merge

                // CALL: leave the result set empty.
                if op == IR_CALL:
                    w64(g_offsets, d * 8, 0)

            // STORE: copy provenance from s2 to s1.
            if op == IR_STORE && s1 >= 0 && s2 >= 0:
                if pa_merge_pts(s1, s2) != 0:
                    changed = 1
                w64(g_offsets, s1 * 8, r64(g_offsets, s2 * 8))

            // Store rule: s1 is the pointer and s2 the value.
            if op == IR_STORE_PTR && s1 >= 0 && s2 >= 0:
                if pa_store(s1, s2) != 0:
                    changed = 1

            // Load rule: d is the destination and s1 the pointer.
            if op == IR_DEREF && d >= 0 && s1 >= 0:
                // Also propagate pts(ptr) as a conservative base.
                if pa_merge_pts(d, s1) != 0:
                    changed = 1
                // Merge allocation contents from each pointee.
                if pa_load(ni, d, s1) != 0:
                    changed = 1

            ni = ni + 1

fn ptr_analysis_all():
    fi : ., mut = 0
    loop:
        if fi >= g_ir_func_count:
            break
        nstart := r64(g_df_func_node_start, fi * 8)
        ncount := r64(g_df_func_node_count, fi * 8)
        vstart := r64(g_ir_func_var_start, fi * 8)
        vcount := r64(g_ir_func_var_count, fi * 8)
        ptr_analysis_func(nstart, ncount, vstart, vcount)
        fi = fi + 1
