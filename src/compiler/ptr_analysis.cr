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

// Precompute SG_UNSAFE coverage once per compile. The old per-node query scanned
// every region for every node and every fixed-point iteration.
fn pa_prepare_unsafe():
    if g_df_node_count <= 0:
        g_node_unsafe = ""
        return
    g_node_unsafe = alloc((g_df_node_count + 1) * 8)
    ni : ., mut = 0
    loop:
        if ni >= g_df_node_count:
            break
        cell_store(g_node_unsafe, ni * 8, 0)
        ni = ni + 1
    si : ., mut = 0
    loop:
        if si >= g_sg_count:
            break
        if cell_load(g_sgs, si * ESZ_SG + OFF_SG_KIND) == SG_UNSAFE:
            ns := cell_load(g_sgs, si * ESZ_SG + OFF_SG_NSTART)
            nc := cell_load(g_sgs, si * ESZ_SG + OFF_SG_NCOUNT)
            ni2 : ., mut = ns
            loop:
                if ni2 >= ns + nc:
                    break
                if ni2 >= 0 && ni2 < g_df_node_count:
                    cell_store(g_node_unsafe, ni2 * 8, 1)
                ni2 = ni2 + 1
        si = si + 1

fn pa_in_unsafe(node_seq: int) -> int:
    if node_seq < 0 || node_seq >= g_df_node_count:
        return 0
    return cell_load(g_node_unsafe, node_seq * 8)

// Allocation content tracking for the Andersen store and load rules.
// g_alloc_pts[alloc_id] is the set of values stored into the allocation through
// IR_STORE_PTR and read through IR_DEREF.

fn grow_alloc_pts(n: int):
    if n < g_alloc_pts_cap:
        return
    nc : ., mut = g_alloc_pts_cap
    if nc == 0:
        nc = 16
    loop:
        if nc > n:
            break
        nc = nc * 2
    words : ., mut = g_pts_words
    if words <= 0:
        words = 1
    nb := alloc(nc * words * 8)
    if g_alloc_pts_cap > 0:
        cell_copy(g_alloc_pts, g_alloc_pts_cap * words * 8, nb)
    g_alloc_pts = nb
    g_alloc_pts_cap = nc

fn grow_pa_alloc_nodes(n: int):
    if n < g_pa_alloc_nodes_cap:
        return
    nc : ., mut = g_pa_alloc_nodes_cap
    if nc == 0:
        nc = 16
    loop:
        if nc > n:
            break
        nc = nc * 2
    nb := alloc(nc * 8)
    if g_pa_alloc_nodes_cap > 0:
        cell_copy(g_pa_alloc_nodes, g_pa_alloc_nodes_cap * 8, nb)
    g_pa_alloc_nodes = nb
    g_pa_alloc_nodes_cap = nc

// ── Points-to sets ──
// A set is a row of g_pts_words cells. Each cell uses 63 lanes, not 64: the
// language has no unsigned int, so bit 63 would make the word negative and the
// division-based mask tests ambiguous. The row width comes from the allocation
// pre-scan, so allocation IDs are not capped. Masks are built by doubling and
// unions walk the lanes of each word. The representation is hidden behind this
// API so the rest of the passes never assume a single-word bitmap.
fn pa_bit_mask(bit: int) -> int:
    mask : int, mut = 1
    i : ., mut = 0
    loop:
        if i >= bit:
            break
        mask = mask * 2
        i = i + 1
    return mask

fn pa_set_index(handle: int, alloc: int) -> int:
    return (handle * g_pts_words + alloc / 63) * 8

fn pa_pts_has(handle: int, alloc: int) -> int:
    if handle < 0 || handle >= g_pts_cap || alloc < 0 || alloc >= g_pa_alloc_max:
        return 0
    m := pa_bit_mask(alloc % 63)
    return (cell_load(g_pts, pa_set_index(handle, alloc)) / m) % 2

fn pa_alloc_pts_has(handle: int, alloc: int) -> int:
    if handle < 0 || handle >= g_alloc_pts_cap || alloc < 0 || alloc >= g_pa_alloc_max:
        return 0
    m := pa_bit_mask(alloc % 63)
    return (cell_load(g_alloc_pts, pa_set_index(handle, alloc)) / m) % 2

fn pa_pts_add(handle: int, alloc: int):
    if handle < 0 || handle >= g_pts_cap || alloc < 0 || alloc >= g_pa_alloc_max:
        return
    idx := pa_set_index(handle, alloc)
    m := pa_bit_mask(alloc % 63)
    cur := cell_load(g_pts, idx)
    if (cur / m) % 2 == 0:
        cell_store(g_pts, idx, cur + m)

fn pa_pts_clear(handle: int):
    if handle < 0 || handle >= g_pts_cap:
        return
    w : ., mut = 0
    loop:
        if w >= g_pts_words:
            break
        cell_store(g_pts, (handle * g_pts_words + w) * 8, 0)
        w = w + 1

fn pa_pts_empty(handle: int) -> int:
    if handle < 0 || handle >= g_pts_cap:
        return 1
    w : ., mut = 0
    loop:
        if w >= g_pts_words:
            break
        if cell_load(g_pts, (handle * g_pts_words + w) * 8) != 0:
            return 0
        w = w + 1
    return 1

// Merge one 63-lane cell from src into dst. Returns 1 when the cell changed.
fn pa_cell_merge(db: string, di: int, sb: string, si: int) -> int:
    a := cell_load(db, di * 8)
    b := cell_load(sb, si * 8)
    out : ., mut = a
    changed : ., mut = 0
    mask : ., mut = 1
    bi : ., mut = 0
    loop:
        if bi >= 63:
            break
        if (b / mask) % 2 == 1 && (out / mask) % 2 == 0:
            out = out + mask
            changed = 1
        mask = mask * 2
        bi = bi + 1
    if changed != 0:
        cell_store(db, di * 8, out)
    return changed

// Merge a whole set from `sb[sh]` into `db[dh]`. Both buffers use the same row
// width; the caller passes the right global for var/alloc sets.
fn pa_cross_merge(db: string, dh: int, sb: string, sh: int) -> int:
    if dh < 0 || sh < 0:
        return 0
    changed : ., mut = 0
    w : ., mut = 0
    loop:
        if w >= g_pts_words:
            break
        if pa_cell_merge(db, dh * g_pts_words + w, sb, sh * g_pts_words + w) != 0:
            changed = 1
        w = w + 1
    return changed

// Merge src_var into dst_var and return 1 when dst changed.
fn pa_merge_pts(dst_var: int, src_var: int) -> int:
    if dst_var < 0 || src_var < 0:
        return 0
    if g_pts_cap <= dst_var:
        grow_pts(dst_var + 1)
    if g_pts_cap <= src_var:
        grow_pts(src_var + 1)
    return pa_cross_merge(g_pts, dst_var, g_pts, src_var)

// Merge alloc_pts[alloc_seq] into pts[dst_var] and return 1 when changed.
fn pa_merge_alloc_pts(dst_var: int, alloc_seq: int) -> int:
    if dst_var < 0 || alloc_seq < 0:
        return 0
    if g_pts_cap <= dst_var:
        grow_pts(dst_var + 1)
    if g_alloc_pts_cap <= alloc_seq:
        grow_alloc_pts(alloc_seq + 1)
    return pa_cross_merge(g_pts, dst_var, g_alloc_pts, alloc_seq)

// Propagate pts[src_var] into alloc_pts[alloc_seq] and return 1 when changed.
fn pa_store_to_alloc(alloc_seq: int, src_var: int) -> int:
    if alloc_seq < 0 || src_var < 0:
        return 0
    if g_alloc_pts_cap <= alloc_seq:
        grow_alloc_pts(alloc_seq + 1)
    if g_pts_cap <= src_var:
        grow_pts(src_var + 1)
    return pa_cross_merge(g_alloc_pts, alloc_seq, g_pts, src_var)

// Load rule: for each allocation in pts(p), add alloc_pts[alloc] to pts(r).
fn pa_load(deref_node: int, dst_var: int, ptr_var: int) -> int:
    changed : ., mut = 0
    ai : ., mut = 0
    loop:
        if ai >= g_pa_alloc_count:
            break
        if pa_pts_has(ptr_var, ai) != 0:
            if pa_merge_alloc_pts(dst_var, ai) != 0:
                changed = 1
        ai = ai + 1
    return changed

// Store rule: for each allocation in pts(p), add pts(v) to alloc_pts[alloc].
fn pa_store(ptr_var: int, val_var: int) -> int:
    changed : ., mut = 0
    ai : ., mut = 0
    loop:
        if ai >= g_pa_alloc_count:
            break
        if pa_pts_has(ptr_var, ai) != 0:
            if pa_store_to_alloc(ai, val_var) != 0:
                changed = 1
        ai = ai + 1
    return changed

fn ptr_analysis_func(nstart: int, ncount: int, vstart: int, vcount: int):
    // Initialize points-to sets and semantic element offsets for this function's
    // variables. Offsets are element indices, never target byte addresses.
    vi : ., mut = 0
    loop:
        if vi >= vcount:
            break
        var_idx := vstart + vi
        grow_pts(var_idx + 1)
        pa_pts_clear(var_idx)
        grow_offsets(var_idx + 1)
        cell_store(g_offsets, var_idx * 8, 0)
        vi = vi + 1

    // Monotone set growth: each pass only adds allocation bits, so the
    // fixed point terminates without an arbitrary iteration cap.
    changed : int, mut = 1
    loop:
        if changed == 0:
            break
        changed = 0

        ni : ., mut = nstart
        loop:
            if ni >= nstart + ncount:
                break
            op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
            d  := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_DEST)
            s1 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)
            s2 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S2)
            s3 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S3)

            // Suppress pointer tracking inside unsafe blocks.
            if pa_in_unsafe(ni) != 0:
                ni = ni + 1
                continue

            if d >= 0:
                // Addr: ALLOC, REF, and ADDR_INDEX create a self-pointer.
                if op == IR_ALLOC_STRUCT || op == IR_ALLOC_ARRAY || op == IR_ALLOC_AT:
                    // IR_ALLOC marks a scalar slot and is not tracked. Heap and
                    // fixed-address allocations receive points-to bits.
                    if pa_pts_empty(d) != 0:
                        // Give each allocation its own bit and record the mapping
                        // from bit to DF node for size queries. The set width is
                        // pre-scanned, so there is no 64-allocation cap.
                        grow_pa_alloc_nodes(g_pa_alloc_count + 1)
                        cell_store(g_pa_alloc_nodes, g_pa_alloc_count * 8, ni)
                        pa_pts_add(d, g_pa_alloc_count)
                        g_pa_alloc_count = g_pa_alloc_count + 1
                        changed = 1
                    cell_store(g_offsets, d * 8, 0)

                if op == IR_REF && s1 >= 0:
                    if pa_merge_pts(d, s1) != 0:
                        changed = 1
                    // Propagate the offset.
                    cell_store(g_offsets, d * 8, cell_load(g_offsets, s1 * 8))

                if op == IR_ADDR_INDEX && s1 >= 0:
                    if pa_merge_pts(d, s1) != 0:
                        changed = 1
                    // The index decides the semantic element offset. A constant
                    // index adds that many elements; a dynamic index gives -1,
                    // which makes provenance_verify emit a runtime check. Byte
                    // scaling is a target fact and belongs to corearch.
                    base_off := cell_load(g_offsets, s1 * 8)
                    idx_val : int, mut = -1
                    if s2 >= 0:
                        prod := cell_load(g_df_var_producer, s2 * 8)
                        if prod >= 0:
                            prod_op := cell_load(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_OPCODE)
                            if prod_op == IR_CONST:
                                idx_val = cell_load(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_S1)
                    if idx_val >= 0 && base_off >= 0:
                        cell_store(g_offsets, d * 8, base_off + idx_val)
                    else:
                        cell_store(g_offsets, d * 8, -1)

                // IR_SLICE propagates the underlying array provenance for
                // d = &arr[low]. A constant low adds that many elements; the
                // target scale is not part of the analysis.
                if op == IR_SLICE && s1 >= 0:
                    if pa_merge_pts(d, s1) != 0:
                        changed = 1
                    base_off := cell_load(g_offsets, s1 * 8)
                    low_val : int, mut = -1
                    if s2 >= 0:
                        prod := cell_load(g_df_var_producer, s2 * 8)
                        if prod >= 0:
                            prod_op := cell_load(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_OPCODE)
                            if prod_op == IR_CONST:
                                low_val = cell_load(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_S1)
                    if low_val >= 0 && base_off >= 0:
                        cell_store(g_offsets, d * 8, base_off + low_val)
                    else:
                        cell_store(g_offsets, d * 8, -1)

                // Pointer add and subtract propagate provenance and offset.
                if op == IR_BINARY && (s3 == OP_PTR_ADD || s3 == OP_PTR_SUB) && s1 >= 0:
                    if pa_merge_pts(d, s1) != 0:
                        changed = 1
                    // Evaluate a constant offset precisely.
                    base_off := cell_load(g_offsets, s1 * 8)
                    off_val : ., mut = 0
                    // Check whether s2 comes from a CONST instruction.
                    if s2 >= 0:
                        prod := cell_load(g_df_var_producer, s2 * 8)
                        if prod >= 0:
                            prod_op := cell_load(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_OPCODE)
                            if prod_op == IR_CONST:
                                off_val = cell_load(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_S1)
                    // Pointer add and subtract propagate provenance and the
                    // semantic element offset. Constant offsets are exact.
                    if s3 == OP_PTR_ADD:
                        cell_store(g_offsets, d * 8, base_off + off_val)
                    else:
                        cell_store(g_offsets, d * 8, base_off - off_val)

                // LOAD: copy provenance from s1 to d.
                if op == IR_LOAD && s1 >= 0:
                    if pa_merge_pts(d, s1) != 0:
                        changed = 1
                    cell_store(g_offsets, d * 8, cell_load(g_offsets, s1 * 8))
                // IR_STORE is handled outside the d >= 0 block because its dest
                // is always -1.

                // PHI: merge points-to sets from both predecessors.
                if op == IR_PHI:
                    if s1 >= 0 && pa_merge_pts(d, s1) != 0:
                        changed = 1
                    if s2 >= 0 && pa_merge_pts(d, s2) != 0:
                        changed = 1
                    cell_store(g_offsets, d * 8, 0)  // approximate offset after the merge

                // CALL: leave the result set empty.
                if op == IR_CALL:
                    cell_store(g_offsets, d * 8, 0)

            // STORE: copy provenance from s2 to s1.
            if op == IR_STORE && s1 >= 0 && s2 >= 0:
                if pa_merge_pts(s1, s2) != 0:
                    changed = 1
                cell_store(g_offsets, s1 * 8, cell_load(g_offsets, s2 * 8))

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

// Count allocation nodes before the fixed point so each points-to row has a
// stable, sufficiently wide bitset. This removes the old 64-allocation cap.
fn pa_count_allocs() -> int:
    count : ., mut = 0
    fi : ., mut = 0
    loop:
        if fi >= g_ir_func_count:
            break
        nstart := cell_load(g_df_func_node_start, fi * 8)
        ncount := cell_load(g_df_func_node_count, fi * 8)
        ni : ., mut = nstart
        loop:
            if ni >= nstart + ncount:
                break
            op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
            if (op == IR_ALLOC_STRUCT || op == IR_ALLOC_ARRAY || op == IR_ALLOC_AT) && pa_in_unsafe(ni) == 0:
                count = count + 1
            ni = ni + 1
        fi = fi + 1
    return count

fn pa_zero_cells(buf: string, n: int):
    if str_len(buf) == 0:
        return
    i : ., mut = 0
    loop:
        if i >= n:
            break
        cell_store(buf, i * 8, 0)
        i = i + 1

fn ptr_analysis_all():
    // Phase B replaces the whole IR graph. Old points-to rows describe deleted
    // nodes; drop the buffers instead of zeroing rows that no longer align.
    if g_pts_force_rebuild != 0:
        g_pts = ""
        g_alloc_pts = ""
        g_pts_cap = 0
        g_alloc_pts_cap = 0
        g_pts_force_rebuild = 0
    pa_prepare_unsafe()
    g_pa_alloc_count = 0
    g_pa_alloc_max = pa_count_allocs()
    new_words : ., mut = (g_pa_alloc_max + 62) / 63
    if new_words < 1:
        new_words = 1
    if g_pts_words != new_words:
        // The row layout changed; old rows cannot be reused.
        g_pts_words = new_words
        g_pts_cap = 0
        g_alloc_pts_cap = 0
    else:
        // Same layout: keep the buffers and clear the used rows. This avoids
        // orphaning the previous compile's tables in a long-lived process.
        pa_zero_cells(g_pts, g_pts_cap * g_pts_words)
        pa_zero_cells(g_alloc_pts, g_alloc_pts_cap * g_pts_words)
    g_pts_count = 0
    fi : ., mut = 0
    loop:
        if fi >= g_ir_func_count:
            break
        nstart := cell_load(g_df_func_node_start, fi * 8)
        ncount := cell_load(g_df_func_node_count, fi * 8)
        vstart := cell_load(g_ir_func_var_start, fi * 8)
        vcount := cell_load(g_ir_func_var_count, fi * 8)
        ptr_analysis_func(nstart, ncount, vstart, vcount)
        fi = fi + 1
