// === region_check.cr ===
// RegionCheck verifies that every DEREF target is in a live subgraph. It runs
// after PointerAnalysis (ptr_analysis.cr), which builds g_pts.

fn subgraph_containing(node_seq: int) -> int:
    // O(1) region lookup. df_create_node writes g_df_node_region.
    if node_seq >= 0 && node_seq < g_df_node_count:
        return r64(g_df_node_region, node_seq * 8)
    return -1

fn is_in_unsafe(node_seq: int) -> int:
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
    k := r64(g_sgs, sg * ESZ_SG + OFF_SG_KIND)
    if k == SG_LOOP || k == SG_FOR || k == SG_UNSAFE:
        return 1
    return 0

// Nearest ancestor region that releases memory, including the allocation's own
// region. -1 means none; such an allocation lives for the whole function and
// cannot escape a region.
fn rc_releasing_region(alloc_node: int) -> int:
    sg := subgraph_containing(alloc_node)
    loop:
        if sg < 0:
            return -1
        if rc_sg_releases(sg) != 0:
            return sg
        sg = r64(g_sgs, sg * ESZ_SG + OFF_SG_PARENT)

// Release node for allocation bit bi, mapped through g_pa_alloc_nodes to a DF
// node. Returns the EXIT ordinal, or -1 when no region releases the allocation.
fn rc_bit_exit(bi: int) -> int:
    alloc_node := r64(g_pa_alloc_nodes, bi * 8)
    sg := rc_releasing_region(alloc_node)
    if sg < 0:
        return -1
    return r64(g_sgs, sg * ESZ_SG + OFF_SG_EXIT)

fn rc_bit_dead(bi: int, ni: int) -> int:
    ex := rc_bit_exit(bi)
    if ex < 0:
        return 0
    if ni < ex:
        return 0
    return 1

// Whether any allocation in pts is dead at node ni. This is a pure check; reassignment clearing is separate.
fn rc_pts_dead(pts: int, ni: int) -> int:
    mask : int, mut = 1
    bi : ., mut = 0
    loop:
        if bi >= 64:
            break
        if (pts / mask) % 2 == 1:
            if rc_bit_dead(bi, ni) != 0:
                return 1
        mask = mask * 2
        bi = bi + 1
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
fn rc_reassign_clears(ptr_var: int, lo: int, hi: int) -> int:
    saw_safe : int, mut = 0
    i : ., mut = lo
    loop:
        if i >= hi:
            break
        op := r64(g_df_nodes, i * ESZ_DFNODE + OFF_DF_OPCODE)
        d  := r64(g_df_nodes, i * ESZ_DFNODE + OFF_DF_DEST)
        s1 := r64(g_df_nodes, i * ESZ_DFNODE + OFF_DF_S1)
        s2 := r64(g_df_nodes, i * ESZ_DFNODE + OFF_DF_S2)
        if op == IR_STORE && s1 == ptr_var:
            if s2 < 0:
                return 0
            if rc_pts_dead(r64(g_pts, s2 * 8), i) != 0:
                return 0
            saw_safe = 1
        if op == IR_PHI && d == ptr_var:
            if s1 < 0 || s2 < 0:
                return 0
            if rc_pts_dead(r64(g_pts, s1 * 8), i) != 0:
                return 0
            if rc_pts_dead(r64(g_pts, s2 * 8), i) != 0:
                return 0
            saw_safe = 1
        i = i + 1
    return saw_safe

// Whether ptr_var holds a dead pointer at node ni. Address types are TYP_PTR and
// TYP_REF; only the kind is checked. A non-address value is accepted because an
// integer read through a dereference is ordinary data, not another pointer.
fn rc_var_dead(ptr_var: int, ni: int) -> int:
    if ptr_var < 0:
        return 0
    ti := irv_type(ptr_var)
    if ti < 0 || (get_type_kind(ti) != TYP_PTR && get_type_kind(ti) != TYP_REF):
        return 0
    pts := r64(g_pts, ptr_var * 8)
    if pts == 0:
        return 0
    mask : int, mut = 1
    bi : ., mut = 0
    loop:
        if bi >= 64:
            break
        if (pts / mask) % 2 == 1:
            ex := rc_bit_exit(bi)
            if ex >= 0 && ni >= ex:
                if rc_reassign_clears(ptr_var, ex, ni) == 0:
                    return 1
        mask = mask * 2
        bi = bi + 1
    return 0

// A returned pointer points to an allocation in an exited subgraph. The
// diagnostic is B010 EC_B_ESCAPE. Function-level allocations pass because
// rc_releasing_region finds no releasing region for them.
fn rc_return_escape(ni: int, s1: int):
    if rc_var_dead(s1, ni) != 0:
        check_error(EC_B_ESCAPE,
            "region escape: returning pointer to exited subgraph allocation",
            0, 0)

// A stored pointer points to an allocation in an exited subgraph, so the stored
// reference would dangle. The check reports EC_B_LIFETIME. The previous body
// discarded the result, so the check could never fire; it is now connected like
// the DEREF and return checks.
// ptr_var is unused because the outlives comparison on the destination side is
// not implemented.
fn rc_store_escape(ni: int, ptr_var: int, val_var: int):
    if rc_var_dead(val_var, ni) != 0:
        check_error(EC_B_LIFETIME,
            "store escape: storing pointer to exited subgraph allocation",
            0, 0)

fn region_check_func(nstart: int, ncount: int):
    ni : ., mut = nstart
    loop:
        if ni >= nstart + ncount:
            break
        op := r64(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
        d  := r64(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_DEST)
        s1 := r64(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)
        s2 := r64(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S2)

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
            rc_store_escape(ni, s1, s2)

        ni = ni + 1

fn region_check_all():
    // Safety pass; always runs.
    fi : ., mut = 0
    loop:
        if fi >= g_ir_func_count:
            break
        nstart := r64(g_df_func_node_start, fi * 8)
        ncount := r64(g_df_func_node_count, fi * 8)
        region_check_func(nstart, ncount)
        fi = fi + 1
