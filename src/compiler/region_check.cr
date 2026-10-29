// === region_check.cr ===
// RegionCheck verifies that every DEREF target is in a live subgraph. It runs
// after PointerAnalysis (ptr_analysis.cr), which builds g_pts.

// Last store/phi to each IR variable in the function currently being checked.
// RegionCheck walks nodes in order, so this is the exact reaching definition
// for the current use; recursive lifetime traces read it when their query point
// is at or before the current node.
g_rc_last_store : string, mut

// CFG and reaching-definition state for the current function. The linear node
// order is not a CFG; branches carry case targets in g_lat_case and jumps carry
// label ids. These tables are rebuilt per function and used only for scalar
// pointer lifetime queries.
g_rc_cfg_ready : int, mut
g_rc_cfg_nstart : int, mut
g_rc_cfg_ncount : int, mut
g_rc_label_ids : string, mut
g_rc_label_nodes : string, mut
g_rc_label_count : int, mut
g_rc_rd_in : string, mut
g_rc_rd_out : string, mut
g_rc_rd_stack : string, mut
g_rc_rd_queued : string, mut
g_rc_rd_visited : string, mut
g_rc_rd_var : int, mut = -1
g_rc_rd_words : int, mut
g_rc_rd_def_count : int, mut
g_rc_rd_cache : string, mut
g_rc_rd_defs : string, mut

fn subgraph_containing(node_seq: int) -> int:
    // O(1) region lookup. df_create_node writes g_df_node_region.
    if node_seq >= 0 && node_seq < g_df_node_count:
        return cell_load(g_df_node_region, node_seq * 8)
    return -1

fn is_in_unsafe(node_seq: int) -> int:
    // Reuse the SG_UNSAFE map precomputed by PointerAnalysis. The old scan was
    // O(regions) per node and dominated RegionCheck on large programs.
    return pa_in_unsafe(node_seq)

// Escape judgment shared by the three checks below.
// An allocation is dead at node ni when it was allocated in a region whose exit
// actually releases memory and ni is at or after that region's EXIT node.
// EXIT is the index of the first node after the region closes, written by sg_pop
// from g_df_node_count. The interval is [NSTART, EXIT), so closed means
// ni >= EXIT.
//
// Only regions that emit IR_ARENA_RESET at their exit release memory: SG_LOOP,
// SG_FOR, and SG_UNSAFE. SG_IF only pushes and pops; SG_FUNC's arena is reset
// when the function returns, so values returned to the caller remain valid. For
// an allocation inside SG_IF, walk parent links to the region that releases it
// (rc_releasing_region).
//
// Address types are TYP_PTR and TYP_REF. `&x` has TYP_REF, so accepting only
// TYP_PTR would miss escapes derived from it. This check reads only the type
// kind, not extra, so adding TYP_REF is safe. On the current base, `&local` is
// always TYP_REF, and casting it to *T is itself a TF01 error, so the PTR half
// is inactive for region-local shapes. The union remains because PTR still
// covers values derived from alloc() and FFI.
fn rc_sg_releases(sg: int) -> int:
    if sg < 0:
        return 0
    k := cell_load(g_sgs, sg * ESZ_SG + OFF_SG_KIND)
    if k == SG_LOOP || k == SG_FOR || k == SG_UNSAFE:
        return 1
    return 0

// Nearest ancestor region that releases memory, including the allocation's own
// region. -1 means none; such an allocation lives for the whole function and
// cannot escape a region.
fn rc_releasing_region(alloc_node: int) -> int:
    sg : ., mut = subgraph_containing(alloc_node)
    loop:
        if sg < 0:
            return -1
        if rc_sg_releases(sg) != 0:
            return sg
        sg = cell_load(g_sgs, sg * ESZ_SG + OFF_SG_PARENT)

// Whether `anc` is `sg` itself or one of its ancestors. Region membership is
// read from the SG tree, not inferred from node index ranges: a return inside a
// nested region is still inside every enclosing releasing region.
fn rc_sg_is_ancestor(anc: int, sg: int) -> int:
    cur : ., mut = sg
    loop:
        if cur < 0:
            return 0
        if cur == anc:
            return 1
        cur = cell_load(g_sgs, cur * ESZ_SG + OFF_SG_PARENT)

// Release node for allocation bit bi, mapped through g_pa_alloc_nodes to a DF
// node. Returns the EXIT ordinal, or -1 when no region releases the allocation.
fn rc_bit_exit(bi: int) -> int:
    alloc_node := cell_load(g_pa_alloc_nodes, bi * 8)
    sg := rc_releasing_region(alloc_node)
    if sg < 0:
        return -1
    return cell_load(g_sgs, sg * ESZ_SG + OFF_SG_EXIT)

// Escape judgment for one allocation bit. mode 0 = ordinary use at or after
// the releasing region's exit. mode 1 = return: a return inside the releasing
// region also ends the allocation's lifetime for the caller, even though the
// RETURN node is before EXIT.
fn rc_bit_escapes(bi: int, ni: int, mode: int) -> int:
    alloc_node := cell_load(g_pa_alloc_nodes, bi * 8)
    sg := rc_releasing_region(alloc_node)
    if sg < 0:
        return 0
    ex := cell_load(g_sgs, sg * ESZ_SG + OFF_SG_EXIT)
    if ni >= ex:
        return 1
    if mode != 0:
        ret_sg := subgraph_containing(ni)
        if rc_sg_is_ancestor(sg, ret_sg) != 0:
            return 1
    return 0

// Whether any allocation in pts escapes at node ni. Pure set query; the
// variable-level reassignment clearing lives in rc_var_escapes.
fn rc_pts_escapes(pts: int, ni: int, mode: int) -> int:
    if pts < 0:
        return 0
    ai : ., mut = 0
    loop:
        if ai >= g_pa_alloc_count:
            break
        if pa_pts_has(pts, ai) != 0:
            if rc_bit_escapes(ai, ni, mode) != 0:
                return 1
        ai = ai + 1
    return 0

// Reassignment clearing. pts is a flow-insensitive union. A reassignment in
// [lo, hi) means the union no longer describes what the variable holds, and
// using it would report false positives.
// Clear when every write to ptr_var in the range has a value that clearly does
// not escape: pts is empty, or every allocation in pts is still live. At least
// one such write must exist. If any write may escape or its value is unknown
// (s2 < 0), keep the union and report conservatively.
// Known gap: a value returned from a call has empty pts because ptr_analysis
// does not propagate call summaries. Such a value is treated as safe and a true
// positive is missed. The cause is the flow-insensitive pts model.
// `use_ni` is the node whose escape query matters, not the write node. A write
// inside the same releasing region stores a value that is still live at the
// write but escapes at the later use; checking deadness at the write node
// would clear that true positive.
fn rc_reassign_clears(ptr_var: int, lo: int, hi: int, use_ni: int, mode: int) -> int:
    if mode != 0:
        // A return inside the releasing region is dominated by the last write
        // before the return. Keep the last store/phi only; an earlier unsafe
        // write that is overwritten does not make the returned value escape.
        last_kind : ., mut = 0
        last_s1 : ., mut = -1
        last_s2 : ., mut = -1
        i : ., mut = lo
        loop:
            if i >= hi:
                break
            op := cell_load(g_df_nodes, i * ESZ_DFNODE + OFF_DF_OPCODE)
            d  := cell_load(g_df_nodes, i * ESZ_DFNODE + OFF_DF_DEST)
            s1 := cell_load(g_df_nodes, i * ESZ_DFNODE + OFF_DF_S1)
            s2 := cell_load(g_df_nodes, i * ESZ_DFNODE + OFF_DF_S2)
            if op == IR_STORE && s1 == ptr_var:
                last_kind = 1
                last_s1 = -1
                last_s2 = s2
                if rc_node_in_if(i) != 0:
                    last_kind = 3
            if op == IR_PHI && d == ptr_var:
                last_kind = 2
                last_s1 = s1
                last_s2 = s2
                if rc_node_in_if(i) != 0:
                    last_kind = 3
            i = i + 1
        if last_kind == 1:
            if last_s2 < 0:
                return 0
            if rc_pts_escapes(last_s2, use_ni, mode) != 0:
                return 0
            return 1
        if last_kind == 2:
            if last_s1 < 0 || last_s2 < 0:
                return 0
            if rc_pts_escapes(last_s1, use_ni, mode) != 0:
                return 0
            if rc_pts_escapes(last_s2, use_ni, mode) != 0:
                return 0
            return 1
        // last_kind 3 = the last write is conditional and may not execute.
        return 0

    saw_safe : int, mut = 0
    i : ., mut = lo
    loop:
        if i >= hi:
            break
        op := cell_load(g_df_nodes, i * ESZ_DFNODE + OFF_DF_OPCODE)
        d  := cell_load(g_df_nodes, i * ESZ_DFNODE + OFF_DF_DEST)
        s1 := cell_load(g_df_nodes, i * ESZ_DFNODE + OFF_DF_S1)
        s2 := cell_load(g_df_nodes, i * ESZ_DFNODE + OFF_DF_S2)
        if op == IR_STORE && s1 == ptr_var:
            if s2 < 0:
                return 0
            if rc_pts_escapes(s2, use_ni, mode) != 0:
                return 0
            if rc_node_in_conditional(i) != 0:
                return 0
            saw_safe = 1
        if op == IR_PHI && d == ptr_var:
            if s1 < 0 || s2 < 0:
                return 0
            if rc_pts_escapes(s1, use_ni, mode) != 0:
                return 0
            if rc_pts_escapes(s2, use_ni, mode) != 0:
                return 0
            if rc_node_in_conditional(i) != 0:
                return 0
            saw_safe = 1
        i = i + 1
    return saw_safe

// Whether ptr_var holds a dead pointer at node ni. Address types are TYP_PTR and
// TYP_REF; only the kind is checked. A non-address value is accepted because an
// integer read through a dereference is ordinary data, not another pointer.
fn rc_is_global_var(var: int) -> int:
    if var < 0:
        return 0
    i : ., mut = 0
    loop:
        if i >= g_ir_global_count:
            return 0
        if cell_load(g_ir_globals, i * 24 + 8) == var:
            return 1
        i = i + 1
    return 0

fn rc_func_nstart(ni: int) -> int:
    sg : ., mut = subgraph_containing(ni)
    loop:
        if sg < 0:
            return 0
        if cell_load(g_sgs, sg * ESZ_SG + OFF_SG_KIND) == SG_FUNC:
            return cell_load(g_sgs, sg * ESZ_SG + OFF_SG_NSTART)
        sg = cell_load(g_sgs, sg * ESZ_SG + OFF_SG_PARENT)
    return 0

fn rc_node_in_if(node_seq: int) -> int:
    sg : ., mut = subgraph_containing(node_seq)
    loop:
        if sg < 0:
            return 0
        if cell_load(g_sgs, sg * ESZ_SG + OFF_SG_KIND) == SG_IF:
            return 1
        sg = cell_load(g_sgs, sg * ESZ_SG + OFF_SG_PARENT)
    return 0

fn rc_node_in_conditional(node_seq: int) -> int:
    sg : ., mut = subgraph_containing(node_seq)
    loop:
        if sg < 0:
            return 0
        k := cell_load(g_sgs, sg * ESZ_SG + OFF_SG_KIND)
        if k == SG_IF || k == SG_LOOP || k == SG_FOR:
            return 1
        sg = cell_load(g_sgs, sg * ESZ_SG + OFF_SG_PARENT)
    return 0

// Releasing region of the object a pointer variable points to, for pointers
// without allocation bits (scalar slots addressed by `&x`). The trace follows
// the last store before the use, then the producer/REF declaration. -1 =
// function-level, -2 = unknown. Heap pointers are handled by their pts bits and
// return -2 here.
fn rc_stack_release_sg_rec(ptr_var: int, use_ni: int, lo: int, depth: int) -> int:
    if ptr_var < 0 || depth > 8:
        return -2
    if pa_pts_empty(ptr_var) == 0:
        return -2
    si := rc_last_store_before(ptr_var, lo, use_ni)
    if si >= 0:
        val := cell_load(g_df_nodes, si * ESZ_DFNODE + OFF_DF_S2)
        return rc_stack_release_sg_rec(val, si, lo, depth + 1)
    prod := cell_load(g_df_var_producer, ptr_var * 8)
    if prod < 0:
        return -2
    op := cell_load(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_OPCODE)
    s1 := cell_load(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_S1)
    s3 := cell_load(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_S3)
    if op == IR_REF:
        if rc_is_global_var(s1) != 0:
            return -1
        decl := cell_load(g_df_var_producer, s1 * 8)
        if decl >= 0:
            dop := cell_load(g_df_nodes, decl * ESZ_DFNODE + OFF_DF_OPCODE)
            if dop == IR_ALLOC || dop == IR_ALLOC_STRUCT || dop == IR_ALLOC_ARRAY:
                return rc_releasing_region(decl)
        // A global or parameter has no local IR_ALLOC declaration. Its slot
        // lives for the whole function/program, not for the region where `&`
        // happens to be evaluated.
        return -1
    if op == IR_ADDR_INDEX || op == IR_SLICE:
        return rc_stack_release_sg_rec(s1, use_ni, lo, depth + 1)
    if op == IR_ALLOC_STRUCT || op == IR_ALLOC_ARRAY:
        return rc_releasing_region(prod)
    if op == IR_BINARY && (s3 == OP_PTR_ADD || s3 == OP_PTR_SUB):
        return rc_stack_release_sg_rec(s1, use_ni, lo, depth + 1)
    return -2

fn rc_stack_value_escapes(val: int, at_node: int, ni: int, lo: int, mode: int, depth: int) -> int:
    if depth > 8:
        return 0
    si := rc_last_store_before(val, lo, at_node)
    if si >= 0:
        sop := cell_load(g_df_nodes, si * ESZ_DFNODE + OFF_DF_OPCODE)
        if rc_node_in_conditional(si) != 0 || sop == IR_PHI:
            // The value itself has conditional/loop definitions. Recurse over
            // every possible definition instead of trusting one last store.
            if rc_stack_any_escapes(val, ni, lo, mode, depth + 1) != 0:
                return 1
    sg := rc_stack_release_sg_rec(val, at_node, lo, 1)
    if sg < 0:
        return 0
    ex := cell_load(g_sgs, sg * ESZ_SG + OFF_SG_EXIT)
    if ni >= ex:
        return 1
    if mode != 0 && rc_sg_is_ancestor(sg, subgraph_containing(ni)) != 0:
        return 1
    return 0

// Conservative check across every definition of a scalar pointer variable.
// A conditional/PHI definition cannot be represented by one last-store trace;
// report if any possible definition escapes.
fn rc_stack_any_escapes(ptr_var: int, ni: int, lo: int, mode: int, depth: int) -> int:
    if depth > 8:
        return 0
    i : ., mut = lo
    loop:
        if i >= ni:
            break
        op := cell_load(g_df_nodes, i * ESZ_DFNODE + OFF_DF_OPCODE)
        d  := cell_load(g_df_nodes, i * ESZ_DFNODE + OFF_DF_DEST)
        s1 := cell_load(g_df_nodes, i * ESZ_DFNODE + OFF_DF_S1)
        s2 := cell_load(g_df_nodes, i * ESZ_DFNODE + OFF_DF_S2)
        if op == IR_STORE && s1 == ptr_var:
            if rc_stack_value_escapes(s2, i, ni, lo, mode, depth + 1) != 0:
                return 1
        if op == IR_PHI && d == ptr_var:
            if s1 >= 0 && rc_stack_value_escapes(s1, i, ni, lo, mode, depth + 1) != 0:
                return 1
            if s2 >= 0 && rc_stack_value_escapes(s2, i, ni, lo, mode, depth + 1) != 0:
                return 1
        i = i + 1
    return 0

fn rc_stack_value_outlives(val: int, at_node: int, dest: int, lo: int, depth: int) -> int:
    if depth > 8:
        return 0
    si := rc_last_store_before(val, lo, at_node)
    if si >= 0:
        sop := cell_load(g_df_nodes, si * ESZ_DFNODE + OFF_DF_OPCODE)
        if rc_node_in_conditional(si) != 0 || sop == IR_PHI:
            if rc_stack_any_outlives(val, dest, at_node, lo, depth + 1) != 0:
                return 1
    sg := rc_stack_release_sg_rec(val, at_node, lo, 1)
    if sg < 0:
        return 0
    vexit := cell_load(g_sgs, sg * ESZ_SG + OFF_SG_EXIT)
    if dest == -1 || dest > vexit:
        return 1
    return 0

fn rc_stack_any_outlives(ptr_var: int, dest: int, use_ni: int, lo: int, depth: int) -> int:
    if depth > 8:
        return 0
    i : ., mut = lo
    loop:
        if i >= use_ni:
            break
        op := cell_load(g_df_nodes, i * ESZ_DFNODE + OFF_DF_OPCODE)
        d  := cell_load(g_df_nodes, i * ESZ_DFNODE + OFF_DF_DEST)
        s1 := cell_load(g_df_nodes, i * ESZ_DFNODE + OFF_DF_S1)
        s2 := cell_load(g_df_nodes, i * ESZ_DFNODE + OFF_DF_S2)
        if op == IR_STORE && s1 == ptr_var:
            if rc_stack_value_outlives(s2, i, dest, lo, depth + 1) != 0:
                return 1
        if op == IR_PHI && d == ptr_var:
            if s1 >= 0 && rc_stack_value_outlives(s1, i, dest, lo, depth + 1) != 0:
                return 1
            if s2 >= 0 && rc_stack_value_outlives(s2, i, dest, lo, depth + 1) != 0:
                return 1
        i = i + 1
    return 0

// ── Reaching definitions for scalar pointers ──
// The linear node order is not a CFG. Build successors from IR_JUMP labels and
// IR_MATCH CASE targets, then run a forward may-reaching-definitions dataflow.
// This replaces the path-insensitive all-definition heuristics for scalar
// pointer values while leaving heap points-to sets on their existing lattice.

fn rc_ptr_nonzero(s: string) -> int:
    p : ., mut = 0
    unsafe:
        p = @ptr_of(s)
    return p

fn rc_label_node(label: int) -> int:
    if label < 0:
        return -1
    i : ., mut = 0
    loop:
        if i >= g_rc_label_count:
            return -1
        if cell_load(g_rc_label_ids, i * 8) == label:
            return cell_load(g_rc_label_nodes, i * 8)
        i = i + 1
    return -1

fn rc_cfg_prepare(nstart: int, ncount: int):
    if g_rc_cfg_ready != 0 && g_rc_cfg_nstart == nstart && g_rc_cfg_ncount == ncount:
        return
    g_rc_cfg_nstart = nstart
    g_rc_cfg_ncount = ncount
    g_rc_cfg_ready = 1
    g_rc_rd_var = -1
    count : ., mut = 0
    ni : ., mut = nstart
    loop:
        if ni >= nstart + ncount:
            break
        if cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE) == IR_LABEL:
            count = count + 1
        ni = ni + 1
    g_rc_label_count = count
    g_rc_label_ids = alloc(count * 8)
    g_rc_label_nodes = alloc(count * 8)
    if g_ir_var_count > 0:
        g_rc_rd_cache = alloc(g_ir_var_count * 8)
    else:
        g_rc_rd_cache = ""
    if ncount > 0:
        g_rc_rd_defs = alloc(9 * ncount * 8)
    else:
        g_rc_rd_defs = ""
    i : ., mut = 0
    ni = nstart
    loop:
        if ni >= nstart + ncount:
            break
        if cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE) == IR_LABEL:
            cell_store(g_rc_label_ids, i * 8,
                cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1))
            cell_store(g_rc_label_nodes, i * 8, ni)
            i = i + 1
        ni = ni + 1

fn rc_succ_count(ni: int) -> int:
    op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
    if op == IR_RETURN:
        return 0
    if op == IR_JUMP:
        return 1
    if op == IR_MATCH:
        sc := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S3)
        if sc < 0:
            return 0
        return sc
    if ni + 1 < g_rc_cfg_nstart + g_rc_cfg_ncount:
        return 1
    return 0

fn rc_succ_at(ni: int, k: int) -> int:
    op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
    if op == IR_JUMP:
        label := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)
        return rc_label_node(label)
    if op == IR_MATCH:
        base := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S2)
        if base < 0 || k < 0 || base + k >= g_lat_case_count:
            return -1
        label := cell_load_i32(g_lat_case,
            (base + k) * CCR_V10_CASE_DISK + CCR_CASE_TARGET)
        return rc_label_node(label)
    if ni + 1 < g_rc_cfg_nstart + g_rc_cfg_ncount:
        return ni + 1
    return -1

fn rc_node_defines(ni: int, var: int) -> int:
    if var < 0:
        return 0
    op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
    d  := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_DEST)
    s1 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)
    if op == IR_STORE:
        return interp_b2i(s1 == var)
    if d == var:
        return 1
    return 0

fn rc_rd_has(row: int, bit: int) -> int:
    if row < 0 || bit < 0:
        return 0
    w := bit / 63
    m := pa_bit_mask(bit % 63)
    return (cell_load(g_rc_rd_in, (row * g_rc_rd_words + w) * 8) / m) % 2

fn rc_rd_set(buf: string, row: int, bit: int):
    if row < 0 || bit < 0:
        return
    w := bit / 63
    m := pa_bit_mask(bit % 63)
    idx := (row * g_rc_rd_words + w) * 8
    cur := cell_load(buf, idx)
    if (cur / m) % 2 == 0:
        cell_store(buf, idx, cur + m)

fn rc_rd_compute(var: int):
    if g_rc_rd_var == var:
        return
    if var >= 0 && var < g_ir_var_count && rc_ptr_nonzero(g_rc_rd_cache) != 0:
        cached := load_str_ptr(g_rc_rd_cache, var * 8)
        if rc_ptr_nonzero(cached) != 0:
            g_rc_rd_in = cached
            g_rc_rd_var = var
            return
    g_rc_rd_var = var
    n := g_rc_cfg_ncount
    if n <= 0:
        g_rc_rd_words = 1
        return
    words : ., mut = (n + 62) / 63
    if words < 1:
        words = 1
    g_rc_rd_words = words
    g_rc_rd_in = alloc(n * words * 8)
    g_rc_rd_out = alloc(words * 8)
    g_rc_rd_stack = alloc(n * 8)
    g_rc_rd_queued = alloc(n * 8)
    g_rc_rd_visited = alloc(n * 8)
    top : ., mut = 1
    cell_store(g_rc_rd_stack, 0, 0)
    cell_store(g_rc_rd_queued, 0, 1)
    cell_store(g_rc_rd_visited, 0, 1)
    loop:
        if top <= 0:
            break
        top = top - 1
        idx := cell_load(g_rc_rd_stack, top * 8)
        cell_store(g_rc_rd_queued, idx * 8, 0)
        w : ., mut = 0
        loop:
            if w >= words:
                break
            cell_store(g_rc_rd_out, w * 8, 0)
            w = w + 1
        if rc_node_defines(g_rc_cfg_nstart + idx, var) != 0:
            rc_rd_set(g_rc_rd_out, 0, idx)
        else:
            w = 0
            loop:
                if w >= words:
                    break
                cell_store(g_rc_rd_out, w * 8,
                    cell_load(g_rc_rd_in, (idx * words + w) * 8))
                w = w + 1
        sc := rc_succ_count(g_rc_cfg_nstart + idx)
        k : ., mut = 0
        loop:
            if k >= sc:
                break
            s := rc_succ_at(g_rc_cfg_nstart + idx, k)
            if s >= 0:
                sidx := s - g_rc_cfg_nstart
                if sidx >= 0 && sidx < n:
                    changed : ., mut = 0
                    w = 0
                    loop:
                        if w >= words:
                            break
                        if pa_cell_merge(g_rc_rd_in, sidx * words + w,
                                         g_rc_rd_out, w) != 0:
                            changed = 1
                        w = w + 1
                    need : ., mut = changed
                    if cell_load(g_rc_rd_visited, sidx * 8) == 0:
                        need = 1
                        cell_store(g_rc_rd_visited, sidx * 8, 1)
                    if need != 0 && cell_load(g_rc_rd_queued, sidx * 8) == 0:
                        cell_store(g_rc_rd_stack, top * 8, sidx)
                        top = top + 1
                        cell_store(g_rc_rd_queued, sidx * 8, 1)
            k = k + 1
    if var >= 0 && var < g_ir_var_count && rc_ptr_nonzero(g_rc_rd_cache) != 0:
        store_str_ptr(g_rc_rd_cache, var * 8, g_rc_rd_in)

fn rc_rd_any(var: int, use_ni: int) -> int:
    if use_ni < g_rc_cfg_nstart || use_ni >= g_rc_cfg_nstart + g_rc_cfg_ncount:
        return 0
    rc_rd_compute(var)
    row := use_ni - g_rc_cfg_nstart
    w : ., mut = 0
    loop:
        if w >= g_rc_rd_words:
            return 0
        if cell_load(g_rc_rd_in, (row * g_rc_rd_words + w) * 8) != 0:
            return 1
        w = w + 1
    return 0

fn rc_rd_collect(var: int, use_ni: int, depth: int) -> int:
    rc_rd_compute(var)
    row := use_ni - g_rc_cfg_nstart
    base : ., mut = depth * g_rc_cfg_ncount
    if base + g_rc_cfg_ncount > 9 * g_rc_cfg_ncount:
        base = 0
    count : ., mut = 0
    w : ., mut = 0
    loop:
        if w >= g_rc_rd_words:
            break
        word := cell_load(g_rc_rd_in, (row * g_rc_rd_words + w) * 8)
        if word != 0:
            lane : ., mut = 0
            mask : ., mut = 1
            loop:
                if lane >= 63:
                    break
                if (word / mask) % 2 == 1:
                    cell_store(g_rc_rd_defs, (base + count) * 8,
                               g_rc_cfg_nstart + w * 63 + lane)
                    count = count + 1
                mask = mask * 2
                lane = lane + 1
        w = w + 1
    g_rc_rd_def_count = count
    return base

// Does one reaching definition of `var` hold an escaping value at use_ni?
fn rc_scalar_def_escapes(var: int, def_node: int, escape_ni: int, lo: int,
                         mode: int, depth: int) -> int:
    if depth > 8:
        return 0
    op := cell_load(g_df_nodes, def_node * ESZ_DFNODE + OFF_DF_OPCODE)
    d  := cell_load(g_df_nodes, def_node * ESZ_DFNODE + OFF_DF_DEST)
    s1 := cell_load(g_df_nodes, def_node * ESZ_DFNODE + OFF_DF_S1)
    s2 := cell_load(g_df_nodes, def_node * ESZ_DFNODE + OFF_DF_S2)
    if op == IR_STORE && s1 == var:
        if s2 < 0:
            return 0
        return rc_scalar_value_escapes(s2, def_node, escape_ni, lo, mode, depth + 1)
    if op == IR_PHI && d == var:
        if s1 >= 0 && rc_scalar_value_escapes(s1, def_node, escape_ni, lo, mode, depth + 1) != 0:
            return 1
        if s2 >= 0 && rc_scalar_value_escapes(s2, def_node, escape_ni, lo, mode, depth + 1) != 0:
            return 1
        return 0
    return rc_scalar_value_escapes(var, def_node, escape_ni, lo, mode, depth + 1)

fn rc_scalar_value_escapes(val: int, at_node: int, escape_ni: int, lo: int,
                           mode: int, depth: int) -> int:
    if val < 0 || depth > 8:
        return 0
    if pa_pts_empty(val) == 0:
        return rc_pts_escapes(val, escape_ni, mode)
    if rc_node_defines(at_node, val) == 0 && rc_rd_any(val, at_node) != 0:
        return rc_rd_defs_escape(val, at_node, escape_ni, lo, mode, depth + 1)
    sg := rc_stack_release_sg_rec(val, at_node, lo, 1)
    if sg < 0:
        return 0
    ex := cell_load(g_sgs, sg * ESZ_SG + OFF_SG_EXIT)
    if escape_ni >= ex:
        return 1
    if mode != 0 && rc_sg_is_ancestor(sg, subgraph_containing(escape_ni)) != 0:
        return 1
    return 0

fn rc_rd_defs_escape(var: int, query_ni: int, escape_ni: int, lo: int, mode: int, depth: int) -> int:
    if depth > 8:
        return 0
    base := rc_rd_collect(var, query_ni, depth)
    dc := g_rc_rd_def_count
    i : ., mut = 0
    loop:
        if i >= dc:
            return 0
        dn := cell_load(g_rc_rd_defs, (base + i) * 8)
        if rc_scalar_def_escapes(var, dn, escape_ni,
                                  lo, mode, depth + 1) != 0:
            return 1
        i = i + 1
    return 0

fn rc_scalar_value_outlives_rd(val: int, at_node: int, dest: int, lo: int,
                               depth: int) -> int:
    if val < 0 || depth > 8:
        return 0
    if pa_pts_empty(val) == 0:
        ai : ., mut = 0
        loop:
            if ai >= g_pa_alloc_count:
                break
            if pa_pts_has(val, ai) != 0:
                vexit := rc_bit_exit(ai)
                if vexit >= 0 && (dest == -1 || dest > vexit):
                    return 1
            ai = ai + 1
        return 0
    if rc_node_defines(at_node, val) == 0 && rc_rd_any(val, at_node) != 0:
        return rc_rd_defs_outlives(val, dest, at_node, lo, depth + 1)
    return rc_stack_value_outlives(val, at_node, dest, lo, 1)

fn rc_rd_defs_outlives(var: int, dest: int, use_ni: int, lo: int, depth: int) -> int:
    if depth > 8:
        return 0
    base := rc_rd_collect(var, use_ni, depth)
    dc := g_rc_rd_def_count
    i : ., mut = 0
    loop:
        if i >= dc:
            return 0
        def_node := cell_load(g_rc_rd_defs, (base + i) * 8)
        op := cell_load(g_df_nodes, def_node * ESZ_DFNODE + OFF_DF_OPCODE)
        d  := cell_load(g_df_nodes, def_node * ESZ_DFNODE + OFF_DF_DEST)
        s1 := cell_load(g_df_nodes, def_node * ESZ_DFNODE + OFF_DF_S1)
        s2 := cell_load(g_df_nodes, def_node * ESZ_DFNODE + OFF_DF_S2)
        if op == IR_STORE && s1 == var:
            if s2 >= 0 && rc_scalar_value_outlives_rd(s2, def_node, dest, lo, depth + 1) != 0:
                return 1
        else if op == IR_PHI && d == var:
            if s1 >= 0 && rc_scalar_value_outlives_rd(s1, def_node, dest, lo, depth + 1) != 0:
                return 1
            if s2 >= 0 && rc_scalar_value_outlives_rd(s2, def_node, dest, lo, depth + 1) != 0:
                return 1
        else:
            if rc_scalar_value_outlives_rd(var, def_node, dest, lo, depth + 1) != 0:
                return 1
        i = i + 1
    return 0

fn rc_scalar_value_max_rd(val: int, at_node: int, lo: int, depth: int) -> int:
    if val < 0 || depth > 8:
        return -2
    if pa_pts_empty(val) == 0:
        max_exit : ., mut = -2
        seen : ., mut = 0
        ai : ., mut = 0
        loop:
            if ai >= g_pa_alloc_count:
                break
            if pa_pts_has(val, ai) != 0:
                seen = 1
                ex := rc_bit_exit(ai)
                if ex < 0:
                    return -1
                if ex > max_exit:
                    max_exit = ex
            ai = ai + 1
        if seen == 0:
            return -2
        return max_exit
    if rc_node_defines(at_node, val) == 0 && rc_rd_any(val, at_node) != 0:
        return rc_rd_defs_max(val, at_node, lo, depth + 1)
    return rc_dest_max_exit_rec(val, at_node, lo, 1)

fn rc_rd_defs_max(var: int, use_ni: int, lo: int, depth: int) -> int:
    if depth > 8:
        return -2
    base := rc_rd_collect(var, use_ni, depth)
    dc := g_rc_rd_def_count
    max_exit : ., mut = -2
    i : ., mut = 0
    loop:
        if i >= dc:
            return max_exit
        def_node := cell_load(g_rc_rd_defs, (base + i) * 8)
        op := cell_load(g_df_nodes, def_node * ESZ_DFNODE + OFF_DF_OPCODE)
        d  := cell_load(g_df_nodes, def_node * ESZ_DFNODE + OFF_DF_DEST)
        s1 := cell_load(g_df_nodes, def_node * ESZ_DFNODE + OFF_DF_S1)
        s2 := cell_load(g_df_nodes, def_node * ESZ_DFNODE + OFF_DF_S2)
        ex : ., mut = -2
        if op == IR_STORE && s1 == var:
            if s2 >= 0:
                ex = rc_scalar_value_max_rd(s2, def_node, lo, depth + 1)
        else if op == IR_PHI && d == var:
            if s1 >= 0:
                ex = rc_scalar_value_max_rd(s1, def_node, lo, depth + 1)
            if s2 >= 0:
                e2 := rc_scalar_value_max_rd(s2, def_node, lo, depth + 1)
                if e2 == -1:
                    return -1
                if e2 > ex:
                    ex = e2
        else:
            ex = rc_scalar_value_max_rd(var, def_node, lo, depth + 1)
        if ex == -1:
            return -1
        if ex > max_exit:
            max_exit = ex
        i = i + 1
    return max_exit

fn rc_var_escapes(ptr_var: int, ni: int, mode: int) -> int:
    if ptr_var < 0:
        return 0
    ti := irv_type(ptr_var)
    if ti < 0 || (get_type_kind(ti) != TYP_PTR && get_type_kind(ti) != TYP_REF):
        return 0
    if pa_pts_empty(ptr_var) != 0:
        lo := rc_func_nstart(ni)
        if rc_rd_any(ptr_var, ni) != 0:
            if rc_rd_defs_escape(ptr_var, ni, ni, lo, mode, 0) != 0:
                return 1
            return 0
        si := rc_last_store_before(ptr_var, lo, ni)
        if si >= 0:
            sop := cell_load(g_df_nodes, si * ESZ_DFNODE + OFF_DF_OPCODE)
            if rc_node_in_conditional(si) != 0 || sop == IR_PHI:
                if rc_stack_any_escapes(ptr_var, ni, lo, mode, 0) != 0:
                    return 1
        sg := rc_stack_release_sg_rec(ptr_var, ni, lo, 0)
        if sg < 0:
            return 0
        ex := cell_load(g_sgs, sg * ESZ_SG + OFF_SG_EXIT)
        escaped : ., mut = 0
        if ni >= ex:
            escaped = 1
        if mode != 0 && rc_sg_is_ancestor(sg, subgraph_containing(ni)) != 0:
            escaped = 1
        if escaped != 0:
            // The trace already followed the last store before this use.
            return 1
        return 0
    ai : ., mut = 0
    loop:
        if ai >= g_pa_alloc_count:
            break
        if pa_pts_has(ptr_var, ai) != 0:
            if rc_bit_escapes(ai, ni, mode) != 0:
                // Ordinary uses clear reassignments after the region exit.
                // A return inside the region must also inspect writes between
                // the allocation and the return.
                lo : ., mut = rc_bit_exit(ai)
                if mode != 0 && ni < lo:
                    lo = cell_load(g_pa_alloc_nodes, ai * 8)
                    if lo < 0:
                        lo = 0
                if lo < 0:
                    lo = 0
                if rc_reassign_clears(ptr_var, lo, ni, ni, mode) == 0:
                    return 1
        ai = ai + 1
    return 0

fn rc_var_dead(ptr_var: int, ni: int) -> int:
    return rc_var_escapes(ptr_var, ni, 0)

// A returned pointer points to an allocation in an exited subgraph. The
// diagnostic is B010 EC_B_ESCAPE. Function-level allocations pass because
// rc_releasing_region finds no releasing region for them.
fn rc_return_escape(ni: int, s1: int):
    if rc_var_escapes(s1, ni, 1) != 0:
        check_error(EC_B_ESCAPE,
            "region escape: returning pointer to exited subgraph allocation",
            0, 0)

// The destination's lifetime. -1 = function-level (never released before
// return), -2 = unknown, >=0 = the nearest releasing region's EXIT. A non-empty
// pts set describes a heap destination; otherwise the most recent store to the
// pointer variable before the use supplies the value whose pointee is the
// destination. This covers `slotp := &slot` without modelling every stack slot
// as an allocation. The walk is bounded because a pointer can be defined from
// itself through a loop phi.
fn rc_node_exit(node_seq: int) -> int:
    sg := rc_releasing_region(node_seq)
    if sg < 0:
        return -1
    return cell_load(g_sgs, sg * ESZ_SG + OFF_SG_EXIT)

fn rc_last_store_before(ptr_var: int, lo: int, hi: int) -> int:
    if ptr_var < 0 || hi <= lo:
        return -1
    if ptr_var < g_ir_var_count:
        cached := cell_load(g_rc_last_store, ptr_var * 8)
        if cached < hi:
            // The cached definition is the latest before the current node. If
            // it is below the query interval, there is no definition in range;
            // if it is inside, it is the answer. A definition at or after hi
            // belongs to a later point and must fall back to the scan.
            if cached >= lo:
                return cached
            return -1
    i : ., mut = hi - 1
    loop:
        if i < lo:
            return -1
        op := cell_load(g_df_nodes, i * ESZ_DFNODE + OFF_DF_OPCODE)
        s1 := cell_load(g_df_nodes, i * ESZ_DFNODE + OFF_DF_S1)
        d := cell_load(g_df_nodes, i * ESZ_DFNODE + OFF_DF_DEST)
        if (op == IR_STORE && s1 == ptr_var) || (op == IR_PHI && d == ptr_var):
            return i
        i = i - 1
    return -1

fn rc_dest_max_exit_rec(ptr_var: int, use_ni: int, lo: int, depth: int) -> int:
    if ptr_var < 0 || depth > 8:
        return -2
    if pa_pts_empty(ptr_var) == 0:
        max_exit : ., mut = -2
        seen : ., mut = 0
        ai : ., mut = 0
        loop:
            if ai >= g_pa_alloc_count:
                break
            if pa_pts_has(ptr_var, ai) != 0:
                seen = 1
                ex := rc_bit_exit(ai)
                if ex < 0:
                    return -1
                if ex > max_exit:
                    max_exit = ex
            ai = ai + 1
        if seen == 0:
            return -2
        return max_exit
    si := rc_last_store_before(ptr_var, lo, use_ni)
    if si >= 0:
        sop := cell_load(g_df_nodes, si * ESZ_DFNODE + OFF_DF_OPCODE)
        if sop == IR_PHI:
            ps1 := cell_load(g_df_nodes, si * ESZ_DFNODE + OFF_DF_S1)
            ps2 := cell_load(g_df_nodes, si * ESZ_DFNODE + OFF_DF_S2)
            e1 := rc_dest_max_exit_rec(ps1, si, lo, depth + 1)
            e2 := rc_dest_max_exit_rec(ps2, si, lo, depth + 1)
            if e1 == -1 || e2 == -1:
                return -1
            if e1 == -2:
                return e2
            if e2 == -2:
                return e1
            if e1 > e2:
                return e1
            return e2
        if rc_node_in_if(si) != 0:
            // A conditional last store does not dominate the use. Take the
            // maximum lifetime over every possible destination definition; a
            // function-level branch (-1) wins.
            max_def : ., mut = -2
            j : ., mut = lo
            loop:
                if j >= si:
                    break
                op2 := cell_load(g_df_nodes, j * ESZ_DFNODE + OFF_DF_OPCODE)
                d2  := cell_load(g_df_nodes, j * ESZ_DFNODE + OFF_DF_DEST)
                q1 := cell_load(g_df_nodes, j * ESZ_DFNODE + OFF_DF_S1)
                q2 := cell_load(g_df_nodes, j * ESZ_DFNODE + OFF_DF_S2)
                if op2 == IR_STORE && q1 == ptr_var:
                    ex2 := rc_dest_max_exit_rec(q2, j, lo, depth + 1)
                    if ex2 == -1:
                        return -1
                    if ex2 > max_def:
                        max_def = ex2
                if op2 == IR_PHI && d2 == ptr_var:
                    e1 := rc_dest_max_exit_rec(q1, j, lo, depth + 1)
                    e2 := rc_dest_max_exit_rec(q2, j, lo, depth + 1)
                    if e1 == -1 || e2 == -1:
                        return -1
                    if e1 > max_def:
                        max_def = e1
                    if e2 > max_def:
                        max_def = e2
                j = j + 1
            val := cell_load(g_df_nodes, si * ESZ_DFNODE + OFF_DF_S2)
            single := rc_dest_max_exit_rec(val, si, lo, depth + 1)
            if single == -1 || max_def == -1:
                return -1
            if max_def > single:
                return max_def
            return single
        val := cell_load(g_df_nodes, si * ESZ_DFNODE + OFF_DF_S2)
        return rc_dest_max_exit_rec(val, si, lo, depth + 1)
    prod := cell_load(g_df_var_producer, ptr_var * 8)
    if prod < 0:
        return -2
    op := cell_load(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_OPCODE)
    s1 := cell_load(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_S1)
    s3 := cell_load(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_S3)
    if op == IR_REF:
        if rc_is_global_var(s1) != 0:
            return -1
        decl := cell_load(g_df_var_producer, s1 * 8)
        if decl >= 0:
            dop := cell_load(g_df_nodes, decl * ESZ_DFNODE + OFF_DF_OPCODE)
            if dop == IR_ALLOC || dop == IR_ALLOC_STRUCT || dop == IR_ALLOC_ARRAY:
                return rc_node_exit(decl)
        return -1
    if op == IR_ALLOC_STRUCT || op == IR_ALLOC_ARRAY:
        return rc_node_exit(prod)
    if op == IR_ADDR_INDEX || op == IR_SLICE:
        return rc_dest_max_exit_rec(s1, use_ni, lo, depth + 1)
    if op == IR_BINARY && (s3 == OP_PTR_ADD || s3 == OP_PTR_SUB):
        return rc_dest_max_exit_rec(s1, use_ni, lo, depth + 1)
    return -2

fn rc_dest_max_exit(ptr_var: int, use_ni: int, lo: int) -> int:
    if rc_rd_any(ptr_var, use_ni) != 0:
        return rc_rd_defs_max(ptr_var, use_ni, lo, 0)
    return rc_dest_max_exit_rec(ptr_var, use_ni, lo, 0)

// Storing a value into a destination that outlives the value creates a
// dangling reference once the value's region exits, even while the value is
// still alive at the store node. This is the missing half of the store check.
fn rc_store_outlives(ptr_var: int, val_var: int, use_ni: int, lo: int) -> int:
    dest := rc_dest_max_exit(ptr_var, use_ni, lo)
    if dest == -2:
        return 0
    if rc_rd_any(val_var, use_ni) != 0:
        return rc_rd_defs_outlives(val_var, dest, use_ni, lo, 0)
    ai : ., mut = 0
    loop:
        if ai >= g_pa_alloc_count:
            break
        if pa_pts_has(val_var, ai) != 0:
            vexit := rc_bit_exit(ai)
            if vexit >= 0:
                if dest == -1 || dest > vexit:
                    return 1
        ai = ai + 1
    if pa_pts_empty(val_var) != 0:
        lo := rc_func_nstart(use_ni)
        vsg := rc_stack_release_sg_rec(val_var, use_ni, lo, 0)
        if vsg >= 0:
            vexit := cell_load(g_sgs, vsg * ESZ_SG + OFF_SG_EXIT)
            if dest == -1 || dest > vexit:
                return 1
        si := rc_last_store_before(val_var, lo, use_ni)
        if si >= 0:
            sop := cell_load(g_df_nodes, si * ESZ_DFNODE + OFF_DF_OPCODE)
            if rc_node_in_conditional(si) != 0 || sop == IR_PHI:
                if rc_stack_any_outlives(val_var, dest, use_ni, lo, 0) != 0:
                    return 1
    return 0

// A stored pointer points to an allocation that is already dead or will die
// before the destination. Both cases report EC_B_LIFETIME; the messages keep
// the two causes distinguishable.
fn rc_store_escape(ni: int, ptr_var: int, val_var: int, nstart: int):
    if rc_var_dead(val_var, ni) != 0:
        check_error(EC_B_LIFETIME,
            "store escape: storing pointer to exited subgraph allocation",
            0, 0)
    else if rc_store_outlives(ptr_var, val_var, ni, nstart) != 0:
        check_error(EC_B_LIFETIME,
            "store escape: destination outlives the stored allocation",
            0, 0)

fn region_check_func(nstart: int, ncount: int, vstart: int, vcount: int):
    rc_cfg_prepare(nstart, ncount)
    // Reset only this function's variable range. The map itself is allocated
    // once per pass, not once per function; global/other-function entries stay
    // at their initial -1.
    vi : ., mut = vstart
    loop:
        if vi >= vstart + vcount:
            break
        if vi >= 0 && vi < g_ir_var_count:
            cell_store(g_rc_last_store, vi * 8, -1)
        vi = vi + 1
    ni : ., mut = nstart
    loop:
        if ni >= nstart + ncount:
            break
        op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
        d  := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_DEST)
        s1 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)
        s2 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S2)

        // Keep the reaching definition map current in node order. Query nodes
        // use the entries written by earlier nodes only.
        if op == IR_STORE && s1 >= 0 && s1 < g_ir_var_count:
            cell_store(g_rc_last_store, s1 * 8, ni)
        if op == IR_PHI && d >= 0 && d < g_ir_var_count:
            cell_store(g_rc_last_store, d * 8, ni)

        if is_in_unsafe(ni) != 0:
            ni = ni + 1
            continue

        if op == IR_DEREF && d >= 0 && s1 >= 0:
            if rc_var_dead(s1, ni) != 0:
                check_error(EC_B_LIFETIME,
                    "dangling pointer: allocation subgraph exited before deref",
                    0, 0)

        // Interprocedural escape through a return.
        if op == IR_RETURN && s1 >= 0:
            rc_return_escape(ni, s1)

        // Interprocedural escape through a store.
        if op == IR_STORE_PTR:
            rc_store_escape(ni, s1, s2, nstart)

        ni = ni + 1

fn region_check_all():
    // Safety pass; always runs. Allocate the reaching-definition map once for
    // the whole pass; resetting it per function would be O(functions*vars).
    if g_ir_var_count > 0:
        g_rc_last_store = alloc(g_ir_var_count * 8)
        vi : ., mut = 0
        loop:
            if vi >= g_ir_var_count:
                break
            cell_store(g_rc_last_store, vi * 8, -1)
            vi = vi + 1
    else:
        g_rc_last_store = ""
    fi : ., mut = 0
    loop:
        if fi >= g_ir_func_count:
            break
        nstart := cell_load(g_df_func_node_start, fi * 8)
        ncount := cell_load(g_df_func_node_count, fi * 8)
        vstart := cell_load(g_ir_func_var_start, fi * 8)
        vcount := cell_load(g_ir_func_var_count, fi * 8)
        region_check_func(nstart, ncount, vstart, vcount)
        fi = fi + 1
