// === region_check.cr ===
// RegionCheck verifies that every DEREF target is in a live subgraph. It runs
// after PointerAnalysis (ptr_analysis.cr), which builds g_pts.

// Last store/phi to each IR variable in the function currently being checked.
// RegionCheck walks nodes in order, so this is the exact reaching definition
// for the current use; recursive lifetime traces read it when their query point
// is at or before the current node.
g_rc_last_store : string, mut

// Control adjacency and reaching-definition state for the current function.
// The linear node order is not execution order; branches carry case targets in
// g_lat_case and jumps carry label ids. The adjacency is derived from those
// HDFG nodes and cached per function; it is not a second graph. RegionCheck and
// BytePermission query it for reaching definitions.
g_rc_ctl_ready : int, mut
g_rc_ctl_nstart : int, mut
g_rc_ctl_ncount : int, mut
g_rc_ctl_label_ids : string, mut
g_rc_ctl_label_nodes : string, mut
g_rc_ctl_label_count : int, mut
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
g_rc_param_alias : string, mut
g_rc_param_escape : string, mut
g_rc_ret_alias : string, mut
// For each function/parameter j, a 64-bit mask of parameters i such that the
// value passed for j may be stored through the pointer passed for i. The call
// site resolves the pair against the actual destination lifetime instead of
// treating every out-parameter store as an escape.
g_rc_out_pairs : string, mut
// A value loaded through `*p` carries p's parameter identity in this mask. A
// store of that value into program/unknown memory means the pointee content of
// the parameter escapes (`gp = *pp`).
g_rc_param_content_alias : string, mut
g_rc_param_content_escape : string, mut
// Parameters forwarded to an extern call outside `unsafe`; callers must either
// pass program-lifetime pointers or put the call in an unsafe block.
g_rc_param_ffi : string, mut
// Content counterpart of `g_rc_out_pairs`: the pointee content of parameter j
// may be stored through parameter i (`*dst = *pp`).
g_rc_content_out_pairs : string, mut
g_rc_param_changed : int, mut

// Recursion budget for value/definition traces. The trace follows compiler
// generated copy chains (call result -> lazy thunk -> force -> store) in
// addition to user-level aliases, so a small fixed budget is not enough; the
// depth also selects a dedicated slot in g_rc_rd_defs so nested RD collections
// cannot overwrite an outer iteration.
RC_MAX_DEPTH : int = 32

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
    if k == SG_IF && (region_plan_is_split(sg) != 0 || region_plan_is_merge(sg) != 0 || region_plan_is_share(sg) != 0):
        return 1
    return 0

// Nearest ancestor region that releases memory, including the allocation's own
// region. -1 means none; such an allocation lives for the whole function and
// cannot escape a region.
fn rc_releasing_region(alloc_node: int) -> int:
    aop := cell_load(g_df_nodes, alloc_node * ESZ_DFNODE + OFF_DF_OPCODE)
    if aop == IR_ALLOC_AT:
        // Fixed-address placement is external/program-lifetime memory; a
        // surrounding loop or if must never be treated as its release point.
        return -1
    sg : ., mut = subgraph_containing(alloc_node)
    loop:
        if sg < 0:
            return -1
        if rc_sg_releases(sg) != 0:
            return sg
        sg = cell_load(g_sgs, sg * ESZ_SG + OFF_SG_PARENT)

// Lifetime exit for a releasing region. A share IF's slot lives until the last
// consumer loop's exit, not until the IF merge label.
fn rc_sg_lexit(sg: int) -> int:
    lbl := region_plan_share_exit(sg)
    if lbl >= 0:
        n := rc_ctl_label_node(lbl)
        if n >= 0:
            return n
    return cell_load(g_sgs, sg * ESZ_SG + OFF_SG_EXIT)

// True when every allocation bit is a fixed-address placement. Such memory is
// external/program-lifetime, never callee-owned storage, so a store through it
// must not be classified as a local out-parameter write.
fn rc_pts_is_fixed_address(var: int) -> int:
    if var < 0:
        return 0
    saw : ., mut = 0
    ai : ., mut = 0
    loop:
        if ai >= g_pa_alloc_count:
            return saw
        if pa_pts_has(var, ai) != 0:
            saw = 1
            an := cell_load(g_pa_alloc_nodes, ai * 8)
            aop := cell_load(g_df_nodes, an * ESZ_DFNODE + OFF_DF_OPCODE)
            if aop != IR_ALLOC_AT:
                return 0
        ai = ai + 1
    return saw

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
    return rc_sg_lexit(sg)

// Escape judgment for one allocation bit. mode 0 = ordinary use at or after
// the releasing region's exit. mode 1 = return: a return inside the releasing
// region also ends the allocation's lifetime for the caller, even though the
// RETURN node is before EXIT.
fn rc_bit_escapes(bi: int, ni: int, mode: int) -> int:
    alloc_node := cell_load(g_pa_alloc_nodes, bi * 8)
    sg := rc_releasing_region(alloc_node)
    if sg < 0:
        return 0
    ex := rc_sg_lexit(sg)
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
    if ptr_var < 0 || depth > RC_MAX_DEPTH:
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
    if op == IR_ALLOC_STRUCT || op == IR_ALLOC_ARRAY || op == IR_ALLOC_AT:
        return rc_releasing_region(prod)
    if op == IR_BINARY && (s3 == OP_PTR_ADD || s3 == OP_PTR_SUB):
        return rc_stack_release_sg_rec(s1, use_ni, lo, depth + 1)
    return -2

fn rc_stack_value_escapes(val: int, at_node: int, ni: int, lo: int, mode: int, depth: int) -> int:
    if depth > RC_MAX_DEPTH:
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
    ex := rc_sg_lexit(sg)
    if ni >= ex:
        return 1
    if mode != 0 && rc_sg_is_ancestor(sg, subgraph_containing(ni)) != 0:
        return 1
    return 0

// Conservative check across every definition of a scalar pointer variable.
// A conditional/PHI definition cannot be represented by one last-store trace;
// report if any possible definition escapes.
fn rc_stack_any_escapes(ptr_var: int, ni: int, lo: int, mode: int, depth: int) -> int:
    if depth > RC_MAX_DEPTH:
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
    if depth > RC_MAX_DEPTH:
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
    vexit := rc_sg_lexit(sg)
    if dest == -1 || dest > vexit:
        return 1
    return 0

fn rc_stack_any_outlives(ptr_var: int, dest: int, use_ni: int, lo: int, depth: int) -> int:
    if depth > RC_MAX_DEPTH:
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
// Derive the control adjacency from IR_JUMP labels and IR_MATCH CASE targets
// (the nodes themselves are HDFG nodes; this is a cached index, not a second
// graph), then run a forward may-reaching-definitions dataflow. This replaces
// the path-insensitive all-definition heuristics for scalar pointer values
// while leaving heap points-to sets on their existing lattice.

fn rc_ptr_nonzero(s: string) -> int:
    p : ., mut = 0
    unsafe:
        p = @ptr_of(s)
    return p

fn rc_ctl_label_node(label: int) -> int:
    if label < 0:
        return -1
    i : ., mut = 0
    loop:
        if i >= g_rc_ctl_label_count:
            return -1
        if cell_load(g_rc_ctl_label_ids, i * 8) == label:
            return cell_load(g_rc_ctl_label_nodes, i * 8)
        i = i + 1
    return -1

// Invalidate the derived adjacency when the IR is regenerated. The cache key is
// the node range; Phase A and Phase B can share a range while the labels and
// MATCH tables differ.
fn rc_ctl_invalidate():
    g_rc_ctl_ready = 0
    g_rc_rd_var = -1
    g_rc_rd_cache = ""

fn rc_ctl_prepare(nstart: int, ncount: int):
    if g_rc_ctl_ready != 0 && g_rc_ctl_nstart == nstart && g_rc_ctl_ncount == ncount:
        return
    g_rc_ctl_nstart = nstart
    g_rc_ctl_ncount = ncount
    g_rc_ctl_ready = 1
    g_rc_rd_var = -1
    count : ., mut = 0
    ni : ., mut = nstart
    loop:
        if ni >= nstart + ncount:
            break
        if cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE) == IR_LABEL:
            count = count + 1
        ni = ni + 1
    g_rc_ctl_label_count = count
    g_rc_ctl_label_ids = alloc(count * 8)
    g_rc_ctl_label_nodes = alloc(count * 8)
    if g_ir_var_count > 0:
        g_rc_rd_cache = alloc(g_ir_var_count * 8)
    else:
        g_rc_rd_cache = ""
    if ncount > 0:
        g_rc_rd_defs = alloc((RC_MAX_DEPTH + 1) * ncount * 8)
    else:
        g_rc_rd_defs = ""
    i : ., mut = 0
    ni = nstart
    loop:
        if ni >= nstart + ncount:
            break
        if cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE) == IR_LABEL:
            cell_store(g_rc_ctl_label_ids, i * 8,
                cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1))
            cell_store(g_rc_ctl_label_nodes, i * 8, ni)
            i = i + 1
        ni = ni + 1

fn rc_ctl_succ_count(ni: int) -> int:
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
    if ni + 1 < g_rc_ctl_nstart + g_rc_ctl_ncount:
        return 1
    return 0

fn rc_ctl_succ_at(ni: int, k: int) -> int:
    op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
    if op == IR_JUMP:
        label := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)
        return rc_ctl_label_node(label)
    if op == IR_MATCH:
        base := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S2)
        if base < 0 || k < 0 || base + k >= g_lat_case_count:
            return -1
        label := cell_load_i32(g_lat_case,
            (base + k) * CCR_V10_CASE_DISK + CCR_CASE_TARGET)
        return rc_ctl_label_node(label)
    if ni + 1 < g_rc_ctl_nstart + g_rc_ctl_ncount:
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
    n := g_rc_ctl_ncount
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
        if rc_node_defines(g_rc_ctl_nstart + idx, var) != 0:
            rc_rd_set(g_rc_rd_out, 0, idx)
        else:
            w = 0
            loop:
                if w >= words:
                    break
                cell_store(g_rc_rd_out, w * 8,
                    cell_load(g_rc_rd_in, (idx * words + w) * 8))
                w = w + 1
        sc := rc_ctl_succ_count(g_rc_ctl_nstart + idx)
        k : ., mut = 0
        loop:
            if k >= sc:
                break
            s := rc_ctl_succ_at(g_rc_ctl_nstart + idx, k)
            if s >= 0:
                sidx := s - g_rc_ctl_nstart
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
    if use_ni < g_rc_ctl_nstart || use_ni >= g_rc_ctl_nstart + g_rc_ctl_ncount:
        return 0
    rc_rd_compute(var)
    row := use_ni - g_rc_ctl_nstart
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
    row := use_ni - g_rc_ctl_nstart
    base : ., mut = depth * g_rc_ctl_ncount
    if base + g_rc_ctl_ncount > (RC_MAX_DEPTH + 1) * g_rc_ctl_ncount:
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
                               g_rc_ctl_nstart + w * 63 + lane)
                    count = count + 1
                mask = mask * 2
                lane = lane + 1
        w = w + 1
    g_rc_rd_def_count = count
    return base

// Does one reaching definition of `var` hold an escaping value at use_ni?
fn rc_scalar_def_escapes(var: int, def_node: int, escape_ni: int, lo: int,
                         mode: int, depth: int) -> int:
    if depth > RC_MAX_DEPTH:
        return 0
    op := cell_load(g_df_nodes, def_node * ESZ_DFNODE + OFF_DF_OPCODE)
    d  := cell_load(g_df_nodes, def_node * ESZ_DFNODE + OFF_DF_DEST)
    s1 := cell_load(g_df_nodes, def_node * ESZ_DFNODE + OFF_DF_S1)
    s2 := cell_load(g_df_nodes, def_node * ESZ_DFNODE + OFF_DF_S2)
    s3 := cell_load(g_df_nodes, def_node * ESZ_DFNODE + OFF_DF_S3)
    if op == IR_LAZY_THUNK || op == IR_LAZY_FORCE:
        if s1 >= 0:
            return rc_scalar_value_escapes(s1, def_node, escape_ni, lo, mode, depth + 1)
        return 0
    if op == IR_CALL:
        callee := rc_func_by_name(s3)
        if callee >= 0:
            pc := cell_load(g_ir_func_param_count, callee * 8)
            j : ., mut = 0
            loop:
                if j >= pc || j >= s2 || j >= 64:
                    break
                if rc_mask_has(g_rc_ret_alias, callee * 2, j) != 0:
                    arg := s1 + j
                    if rc_scalar_value_escapes(arg, def_node, escape_ni, lo, mode, depth + 1) != 0:
                        return 1
                j = j + 1
        return 0
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

// Compiler-generated lazy thunks are transparent copies: following the
// producer directly avoids spending the recursion budget on wrapper nodes.
fn rc_lazy_source(val: int) -> int:
    if val < 0 || val >= g_ir_var_count:
        return -1
    prod := cell_load(g_df_var_producer, val * 8)
    if prod < 0:
        return -1
    op := cell_load(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_OPCODE)
    if op != IR_LAZY_THUNK && op != IR_LAZY_FORCE:
        return -1
    s1 := cell_load(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_S1)
    if s1 < 0 || s1 >= g_ir_var_count:
        return -1
    return s1

fn rc_scalar_value_escapes(val: int, at_node: int, escape_ni: int, lo: int,
                           mode: int, depth: int) -> int:
    if val < 0 || depth > RC_MAX_DEPTH:
        return 0
    lazy := rc_lazy_source(val)
    if lazy >= 0:
        return rc_scalar_value_escapes(lazy, at_node, escape_ni, lo, mode, depth + 1)
    if pa_pts_empty(val) == 0:
        return rc_pts_escapes(val, escape_ni, mode)
    if rc_node_defines(at_node, val) == 0 && rc_rd_any(val, at_node) != 0:
        return rc_rd_defs_escape(val, at_node, escape_ni, lo, mode, depth + 1)
    sg := rc_stack_release_sg_rec(val, at_node, lo, 1)
    if sg < 0:
        return 0
    ex := rc_sg_lexit(sg)
    if escape_ni >= ex:
        return 1
    if mode != 0 && rc_sg_is_ancestor(sg, subgraph_containing(escape_ni)) != 0:
        return 1
    return 0

fn rc_rd_defs_escape(var: int, query_ni: int, escape_ni: int, lo: int, mode: int, depth: int) -> int:
    if depth > RC_MAX_DEPTH:
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
    if val < 0 || depth > RC_MAX_DEPTH:
        return 0
    lazy := rc_lazy_source(val)
    if lazy >= 0:
        return rc_scalar_value_outlives_rd(lazy, at_node, dest, lo, depth + 1)
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
    if depth > RC_MAX_DEPTH:
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
        s3 := cell_load(g_df_nodes, def_node * ESZ_DFNODE + OFF_DF_S3)
        if op == IR_LAZY_THUNK || op == IR_LAZY_FORCE:
            if s1 >= 0 && rc_scalar_value_outlives_rd(s1, def_node, dest, lo, depth + 1) != 0:
                return 1
        else if op == IR_CALL:
            callee := rc_func_by_name(s3)
            if callee >= 0:
                pc := cell_load(g_ir_func_param_count, callee * 8)
                j : ., mut = 0
                loop:
                    if j >= pc || j >= s2 || j >= 64:
                        break
                    if rc_mask_has(g_rc_ret_alias, callee * 2, j) != 0:
                        arg := s1 + j
                        if rc_scalar_value_outlives_rd(arg, def_node, dest, lo, depth + 1) != 0:
                            return 1
                    j = j + 1
        else if op == IR_STORE && s1 == var:
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
    if val < 0 || depth > RC_MAX_DEPTH:
        return -2
    lazy := rc_lazy_source(val)
    if lazy >= 0:
        return rc_scalar_value_max_rd(lazy, at_node, lo, depth + 1)
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
    if depth > RC_MAX_DEPTH:
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
        s3 := cell_load(g_df_nodes, def_node * ESZ_DFNODE + OFF_DF_S3)
        ex : ., mut = -2
        if op == IR_LAZY_THUNK || op == IR_LAZY_FORCE:
            if s1 >= 0:
                ex = rc_scalar_value_max_rd(s1, def_node, lo, depth + 1)
        else if op == IR_CALL:
            callee := rc_func_by_name(s3)
            if callee >= 0:
                pc := cell_load(g_ir_func_param_count, callee * 8)
                j : ., mut = 0
                loop:
                    if j >= pc || j >= s2 || j >= 64:
                        break
                    if rc_mask_has(g_rc_ret_alias, callee * 2, j) != 0:
                        arg := s1 + j
                        e := rc_scalar_value_max_rd(arg, def_node, lo, depth + 1)
                        if e == -1:
                            return -1
                        if e > ex:
                            ex = e
                    j = j + 1
        else if op == IR_STORE && s1 == var:
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

// ── Interprocedural parameter escape summaries ──
// A function summary marks parameters that may be stored into a location that
// outlives the callee frame: a global, another function's memory (a pointer
// parameter), or an unknown destination. Stores into callee-local slots or
// callee-created heap objects do not escape. Calls propagate summaries through
// their arguments. Masks use two 32-bit cells so all 64 legal parameters are
// representable without touching signed bit 63.

fn rc_func_by_name(name_ni: int) -> int:
    i : ., mut = 0
    loop:
        if i >= g_ir_func_count:
            return -1
        if cell_load(g_ir_func_name_idx, i * 8) == name_ni:
            return i
        i = i + 1
    return -1

fn rc_mask_has(buf: string, base: int, bit: int) -> int:
    if base < 0 || bit < 0 || bit >= 64:
        return 0
    w := bit / 32
    m := pa_bit_mask(bit % 32)
    return (cell_load(buf, (base + w) * 8) / m) % 2

fn rc_mask_set(buf: string, base: int, bit: int):
    if base < 0 || bit < 0 || bit >= 64:
        return
    w := bit / 32
    m := pa_bit_mask(bit % 32)
    idx := (base + w) * 8
    cur := cell_load(buf, idx)
    if (cur / m) % 2 == 0:
        cell_store(buf, idx, cur + m)

fn rc_mask_or_from(out: string, dst_base: int, src_buf: string, src_base: int) -> int:
    if dst_base < 0 || src_base < 0:
        return 0
    changed : ., mut = 0
    w : ., mut = 0
    loop:
        if w >= 2:
            break
        if pa_cell_merge(out, dst_base + w, src_buf, src_base + w) != 0:
            changed = 1
        w = w + 1
    return changed

fn rc_mask_or(buf: string, dst_base: int, src_base: int) -> int:
    return rc_mask_or_from(buf, dst_base, buf, src_base)

fn rc_mask_nonempty(buf: string, base: int) -> int:
    if base < 0:
        return 0
    if cell_load(buf, base * 8) != 0:
        return 1
    if cell_load(buf, (base + 1) * 8) != 0:
        return 1
    return 0

// A value may be stored through an out-parameter into a destination whose
// lifetime is resolved at the call site. If the destination is a parameter,
// record the (source, destination) pair; a global or unknown destination is an
// immediate escape.
fn rc_summary_store(fi: int, out: string, dest_var: int, val_var: int,
                    ni: int, nstart: int):
    if dest_var < 0 || val_var < 0 || val_var >= g_ir_var_count:
        return
    if rc_dest_is_local(dest_var, ni, nstart, fi) != 0:
        return
    if rc_mask_nonempty(g_rc_param_alias, val_var * 2) == 0:
        if rc_mask_nonempty(g_rc_param_content_alias, val_var * 2) == 0:
            return
    if rc_mask_nonempty(g_rc_param_alias, dest_var * 2) == 0:
        rc_mask_or_from(out, 0, g_rc_param_alias, val_var * 2)
        rc_mask_or_from(g_rc_param_content_escape, fi * 2,
                        g_rc_param_content_alias, val_var * 2)
        return
    j : ., mut = 0
    loop:
        if j >= 64:
            return
        if rc_mask_has(g_rc_param_alias, val_var * 2, j) != 0:
            i : ., mut = 0
            loop:
                if i >= 64:
                    break
                if rc_mask_has(g_rc_param_alias, dest_var * 2, i) != 0:
                    rc_mask_set(g_rc_out_pairs, fi * 128 + j * 2, i)
                i = i + 1
        if rc_mask_has(g_rc_param_content_alias, val_var * 2, j) != 0:
            i : ., mut = 0
            loop:
                if i >= 64:
                    break
                if rc_mask_has(g_rc_param_alias, dest_var * 2, i) != 0:
                    rc_mask_set(g_rc_content_out_pairs, fi * 128 + j * 2, i)
                i = i + 1
        j = j + 1

fn rc_alias_compute(fi: int):
    pc := cell_load(g_ir_func_param_count, fi * 8)
    if pc <= 0:
        return
    nstart := cell_load(g_df_func_node_start, fi * 8)
    ncount := cell_load(g_df_func_node_count, fi * 8)
    rc_ctl_prepare(nstart, ncount)
    vstart := cell_load(g_ir_func_var_start, fi * 8)
    vcount := cell_load(g_ir_func_var_count, fi * 8)
    vi : ., mut = vstart
    loop:
        if vi >= vstart + vcount:
            break
        if vi >= 0 && vi < g_ir_var_count:
            cell_store(g_rc_param_alias, vi * 2 * 8, 0)
            cell_store(g_rc_param_alias, (vi * 2 + 1) * 8, 0)
            cell_store(g_rc_param_content_alias, vi * 2 * 8, 0)
            cell_store(g_rc_param_content_alias, (vi * 2 + 1) * 8, 0)
        vi = vi + 1
    j : ., mut = 0
    loop:
        if j >= pc || j >= 64:
            break
        pv := vstart + j
        if pv >= 0 && pv < g_ir_var_count:
            rc_mask_set(g_rc_param_alias, pv * 2, j)
        j = j + 1
    changed : ., mut = 1
    loop:
        if changed == 0:
            break
        changed = 0
        ni : ., mut = nstart
        loop:
            if ni >= nstart + ncount:
                break
            if is_in_unsafe(ni) != 0:
                ni = ni + 1
                continue
            op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
            d  := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_DEST)
            s1 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)
            s2 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S2)
            s3 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S3)
            if op == IR_STORE && s1 >= 0 && s2 >= 0:
                if s1 < g_ir_var_count && s2 < g_ir_var_count:
                    if rc_mask_or(g_rc_param_alias, s1 * 2, s2 * 2) != 0:
                        changed = 1
                    if rc_mask_or(g_rc_param_content_alias, s1 * 2, s2 * 2) != 0:
                        changed = 1
            if op == IR_PHI && d >= 0 && d < g_ir_var_count:
                if s1 >= 0 && s1 < g_ir_var_count:
                    if rc_mask_or(g_rc_param_alias, d * 2, s1 * 2) != 0:
                        changed = 1
                    if rc_mask_or(g_rc_param_content_alias, d * 2, s1 * 2) != 0:
                        changed = 1
                if s2 >= 0 && s2 < g_ir_var_count:
                    if rc_mask_or(g_rc_param_alias, d * 2, s2 * 2) != 0:
                        changed = 1
                    if rc_mask_or(g_rc_param_content_alias, d * 2, s2 * 2) != 0:
                        changed = 1
            if (op == IR_LAZY_THUNK || op == IR_LAZY_FORCE) && d >= 0 && s1 >= 0:
                if d < g_ir_var_count && s1 < g_ir_var_count:
                    if rc_mask_or(g_rc_param_alias, d * 2, s1 * 2) != 0:
                        changed = 1
                    if rc_mask_or(g_rc_param_content_alias, d * 2, s1 * 2) != 0:
                        changed = 1
            if op == IR_DEREF && d >= 0 && s1 >= 0:
                if d < g_ir_var_count && s1 < g_ir_var_count:
                    if rc_mask_or_from(g_rc_param_content_alias, d * 2,
                                       g_rc_param_alias, s1 * 2) != 0:
                        changed = 1
            if op == IR_CALL && d >= 0 && d < g_ir_var_count && s2 > 0:
                callee := rc_func_by_name(s3)
                if callee >= 0:
                    j : ., mut = 0
                    loop:
                        if j >= s2 || j >= 64:
                            break
                        if rc_mask_has(g_rc_ret_alias, callee * 2, j) != 0:
                            arg := s1 + j
                            if arg >= 0 && arg < g_ir_var_count:
                                if rc_mask_or(g_rc_param_alias, d * 2, arg * 2) != 0:
                                    changed = 1
                        j = j + 1
            ni = ni + 1

fn rc_is_param_var(fi: int, var: int) -> int:
    if fi < 0 || var < 0:
        return 0
    vstart := cell_load(g_ir_func_var_start, fi * 8)
    pc := cell_load(g_ir_func_param_count, fi * 8)
    if var >= vstart && var < vstart + pc:
        return 1
    return 0

// Is the destination pointer pointing into storage owned by the callee?
// A local scalar/heap object is safe; a global, a pointer parameter, or an
// unknown destination is not.
fn rc_dest_is_local_rec(ptr_var: int, use_ni: int, lo: int, fi: int, depth: int) -> int:
    if ptr_var < 0 || depth > RC_MAX_DEPTH:
        return 0
    if rc_is_param_var(fi, ptr_var) != 0:
        return 0
    if pa_pts_empty(ptr_var) == 0:
        if rc_pts_is_fixed_address(ptr_var) != 0:
            return 0
        return 1
    if rc_is_global_var(ptr_var) != 0:
        return 0
    si := rc_last_store_before(ptr_var, lo, use_ni)
    if si >= 0:
        val := cell_load(g_df_nodes, si * ESZ_DFNODE + OFF_DF_S2)
        return rc_dest_is_local_rec(val, si, lo, fi, depth + 1)
    prod := cell_load(g_df_var_producer, ptr_var * 8)
    if prod < 0:
        return 0
    op := cell_load(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_OPCODE)
    s1 := cell_load(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_S1)
    s3 := cell_load(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_S3)
    if op == IR_REF:
        if rc_is_global_var(s1) != 0:
            return 0
        if rc_is_param_var(fi, s1) != 0:
            // &param is the callee's local parameter slot, not the caller's
            // memory reached through the parameter.
            return 1
        decl := cell_load(g_df_var_producer, s1 * 8)
        if decl >= 0:
            dop := cell_load(g_df_nodes, decl * ESZ_DFNODE + OFF_DF_OPCODE)
            if dop == IR_ALLOC || dop == IR_ALLOC_STRUCT || dop == IR_ALLOC_ARRAY:
                return 1
        return 0
    if op == IR_ADDR_INDEX || op == IR_SLICE:
        return rc_dest_is_local_rec(s1, use_ni, lo, fi, depth + 1)
    if op == IR_ALLOC_STRUCT || op == IR_ALLOC_ARRAY:
        return 1
    if op == IR_LAZY_THUNK || op == IR_LAZY_FORCE:
        if s1 >= 0:
            return rc_dest_is_local_rec(s1, use_ni, lo, fi, depth + 1)
        return 0
    if op == IR_CALL:
        s2 := cell_load(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_S2)
        callee := rc_func_by_name(s3)
        if callee >= 0:
            pc := cell_load(g_ir_func_param_count, callee * 8)
            seen : ., mut = 0
            j : ., mut = 0
            loop:
                if j >= pc || j >= s2 || j >= 64:
                    break
                if rc_mask_has(g_rc_ret_alias, callee * 2, j) != 0:
                    seen = 1
                    arg := s1 + j
                    if rc_dest_is_local_rec(arg, prod, lo, fi, depth + 1) == 0:
                        return 0
                j = j + 1
            if seen != 0:
                return 1
        if s3 >= 0 && str_eq(istr_get(s3), "alloc") != 0:
            return 1
    if op == IR_UNARY && s1 >= 0:
        return rc_dest_is_local_rec(s1, use_ni, lo, fi, depth + 1)
    if op == IR_BINARY && (s3 == OP_PTR_ADD || s3 == OP_PTR_SUB):
        return rc_dest_is_local_rec(s1, use_ni, lo, fi, depth + 1)
    return 0

fn rc_rd_dest_local(var: int, use_ni: int, lo: int, fi: int, depth: int) -> int:
    if depth > RC_MAX_DEPTH:
        return 0
    base := rc_rd_collect(var, use_ni, depth)
    dc := g_rc_rd_def_count
    if dc <= 0:
        return 0
    i : ., mut = 0
    loop:
        if i >= dc:
            return 1
        dn := cell_load(g_rc_rd_defs, (base + i) * 8)
        op := cell_load(g_df_nodes, dn * ESZ_DFNODE + OFF_DF_OPCODE)
        d  := cell_load(g_df_nodes, dn * ESZ_DFNODE + OFF_DF_DEST)
        s1 := cell_load(g_df_nodes, dn * ESZ_DFNODE + OFF_DF_S1)
        s2 := cell_load(g_df_nodes, dn * ESZ_DFNODE + OFF_DF_S2)
        if op == IR_STORE && s1 == var:
            lv : ., mut = 0
            if s2 >= 0:
                lv = rc_dest_is_local_rec(s2, dn, lo, fi, depth + 1)
            if s2 < 0 || lv == 0:
                return 0
        else if op == IR_PHI && d == var:
            if s1 < 0 || rc_dest_is_local_rec(s1, dn, lo, fi, depth + 1) == 0:
                return 0
            if s2 < 0 || rc_dest_is_local_rec(s2, dn, lo, fi, depth + 1) == 0:
                return 0
        else:
            if rc_dest_is_local_rec(var, dn, lo, fi, depth + 1) == 0:
                return 0
        i = i + 1
    return 1

fn rc_dest_is_local(ptr_var: int, use_ni: int, lo: int, fi: int) -> int:
    if fi >= 0 && fi < g_ir_func_count:
        rc_ctl_prepare(cell_load(g_df_func_node_start, fi * 8),
                       cell_load(g_df_func_node_count, fi * 8))
    if rc_rd_any(ptr_var, use_ni) != 0:
        return rc_rd_dest_local(ptr_var, use_ni, lo, fi, 0)
    return rc_dest_is_local_rec(ptr_var, use_ni, lo, fi, 0)

// Propagate "the pointee content of a caller value escapes" through a call in
// the summary. The interesting shapes are `&slot` (inspect what slot holds) and
// forwarding a parameter (the caller owns the pointee).
fn rc_summary_content_escape(fi: int, arg: int, ni: int, nstart: int):
    if arg < 0 || arg >= g_ir_var_count:
        return
    if rc_is_param_var(fi, arg) != 0:
        rc_mask_set(g_rc_param_content_escape, fi * 2,
                    arg - cell_load(g_ir_func_var_start, fi * 8))
        return
    prod := cell_load(g_df_var_producer, arg * 8)
    if prod < 0:
        return
    op := cell_load(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_OPCODE)
    s1 := cell_load(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_S1)
    if op == IR_REF && s1 >= 0:
        if rc_is_param_var(fi, s1) != 0:
            rc_mask_set(g_rc_param_content_escape, fi * 2, s1 - cell_load(g_ir_func_var_start, fi * 8))
        if rc_rd_any(s1, ni) != 0:
            base := rc_rd_collect(s1, ni, 0)
            dc := g_rc_rd_def_count
            i : ., mut = 0
            loop:
                if i >= dc:
                    return
                dn := cell_load(g_rc_rd_defs, (base + i) * 8)
                dop := cell_load(g_df_nodes, dn * ESZ_DFNODE + OFF_DF_OPCODE)
                ds1 := cell_load(g_df_nodes, dn * ESZ_DFNODE + OFF_DF_S1)
                ds2 := cell_load(g_df_nodes, dn * ESZ_DFNODE + OFF_DF_S2)
                if dop == IR_STORE && ds1 == s1:
                    if ds2 >= 0 && ds2 < g_ir_var_count:
                        rc_mask_or_from(g_rc_param_content_escape, fi * 2,
                                        g_rc_param_alias, ds2 * 2)
                        rc_mask_or_from(g_rc_param_content_escape, fi * 2,
                                        g_rc_param_content_alias, ds2 * 2)
                i = i + 1
        return
    rc_mask_or_from(g_rc_param_content_escape, fi * 2, g_rc_param_alias, arg * 2)

// Update one function's summary. Returns 1 when the summary grew.
// Propagate a callee content pair (source pointee -> destination parameter)
// through the current function's own parameters.
fn rc_summary_content_pair(fi: int, src_arg: int, dst_arg: int,
                           ni: int, nstart: int):
    if src_arg < 0 || dst_arg < 0:
        return
    if rc_mask_nonempty(g_rc_param_alias, dst_arg * 2) == 0:
        return
    if rc_is_param_var(fi, src_arg) != 0:
        sp := src_arg - cell_load(g_ir_func_var_start, fi * 8)
        d : ., mut = 0
        loop:
            if d >= 64:
                return
            if rc_mask_has(g_rc_param_alias, dst_arg * 2, d) != 0:
                rc_mask_set(g_rc_content_out_pairs, fi * 128 + sp * 2, d)
            d = d + 1
        return
    prod := cell_load(g_df_var_producer, src_arg * 8)
    if prod < 0:
        return
    op := cell_load(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_OPCODE)
    s1 := cell_load(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_S1)
    if op != IR_REF || s1 < 0:
        return
    if rc_rd_any(s1, ni) == 0:
        return
    base := rc_rd_collect(s1, ni, 0)
    dc := g_rc_rd_def_count
    i : ., mut = 0
    loop:
        if i >= dc:
            return
        dn := cell_load(g_rc_rd_defs, (base + i) * 8)
        dop := cell_load(g_df_nodes, dn * ESZ_DFNODE + OFF_DF_OPCODE)
        ds1 := cell_load(g_df_nodes, dn * ESZ_DFNODE + OFF_DF_S1)
        ds2 := cell_load(g_df_nodes, dn * ESZ_DFNODE + OFF_DF_S2)
        if dop == IR_STORE && ds1 == s1:
            if ds2 >= 0 && ds2 < g_ir_var_count:
                x : ., mut = 0
                loop:
                    if x >= 64:
                        break
                    if rc_mask_has(g_rc_param_alias, ds2 * 2, x) != 0:
                        d : ., mut = 0
                        loop:
                            if d >= 64:
                                break
                            if rc_mask_has(g_rc_param_alias, dst_arg * 2, d) != 0:
                                rc_mask_set(g_rc_content_out_pairs, fi * 128 + x * 2, d)
                            d = d + 1
                    x = x + 1
        i = i + 1

fn rc_summary_func(fi: int) -> int:
    pc := cell_load(g_ir_func_param_count, fi * 8)
    if pc <= 0:
        return 0
    nstart := cell_load(g_df_func_node_start, fi * 8)
    ncount := cell_load(g_df_func_node_count, fi * 8)
    vstart := cell_load(g_ir_func_var_start, fi * 8)
    vcount := cell_load(g_ir_func_var_count, fi * 8)
    vi : ., mut = vstart
    loop:
        if vi >= vstart + vcount:
            break
        if vi >= 0 && vi < g_ir_var_count && rc_ptr_nonzero(g_rc_last_store) != 0:
            cell_store(g_rc_last_store, vi * 8, -1)
        vi = vi + 1
    old0 := cell_load(g_rc_param_escape, fi * 2 * 8)
    old1 := cell_load(g_rc_param_escape, (fi * 2 + 1) * 8)
    ret_old0 := cell_load(g_rc_ret_alias, fi * 2 * 8)
    ret_old1 := cell_load(g_rc_ret_alias, (fi * 2 + 1) * 8)
    out := alloc(16)
    cell_store(out, 0, old0)
    cell_store(out, 8, old1)
    ret := alloc(16)
    cell_store(ret, 0, ret_old0)
    cell_store(ret, 8, ret_old1)
    ni : ., mut = nstart
    loop:
        if ni >= nstart + ncount:
            break
        op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
        d  := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_DEST)
        s1 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)
        s2 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S2)
        s3 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S3)
        if rc_ptr_nonzero(g_rc_last_store) != 0:
            if op == IR_STORE && s1 >= 0 && s1 < g_ir_var_count:
                cell_store(g_rc_last_store, s1 * 8, ni)
            if op == IR_PHI && d >= 0 && d < g_ir_var_count:
                cell_store(g_rc_last_store, d * 8, ni)
        if is_in_unsafe(ni) != 0:
            ni = ni + 1
            continue
        if op == IR_STORE && s1 >= 0 && s2 >= 0:
            if s2 < g_ir_var_count && rc_is_global_var(s1) != 0:
                rc_mask_or_from(out, 0, g_rc_param_alias, s2 * 2)
                rc_mask_or_from(g_rc_param_content_escape, fi * 2,
                                g_rc_param_content_alias, s2 * 2)
        if op == IR_STORE_PTR && s1 >= 0 && s2 >= 0:
            rc_summary_store(fi, out, s1, s2, ni, nstart)
        if op == IR_STORE_INDEX && s1 >= 0 && s2 >= 0:
            rc_summary_store(fi, out, s1, s2, ni, nstart)
        if op == IR_STORE_INDEX_VAR && s1 >= 0 && d >= 0:
            rc_summary_store(fi, out, s1, d, ni, nstart)
        if op == IR_STORE_FIELD && s1 >= 0 && s2 >= 0:
            rc_summary_store(fi, out, s1, s2, ni, nstart)
        if op == IR_CALL_EXTERN && is_in_unsafe(ni) == 0 && s2 >= 0 && s3 > 0:
            j : ., mut = 0
            loop:
                if j >= s3:
                    break
                arg := s2 + j
                if arg >= 0 && arg < g_ir_var_count:
                    rc_mask_or_from(g_rc_param_ffi, fi * 2,
                                    g_rc_param_alias, arg * 2)
                j = j + 1
        if op == IR_RETURN && s1 >= 0 && s1 < g_ir_var_count:
            rc_mask_or_from(ret, 0, g_rc_param_alias, s1 * 2)
        if op == IR_CALL && s2 > 0:
            callee := rc_func_by_name(s3)
            if callee >= 0:
                cpc := cell_load(g_ir_func_param_count, callee * 8)
                j : ., mut = 0
                loop:
                    if j >= cpc || j >= s2 || j >= 64:
                        break
                    if rc_mask_has(g_rc_param_escape, callee * 2, j) != 0:
                        arg := s1 + j
                        if arg >= 0 && arg < g_ir_var_count:
                            rc_mask_or_from(out, 0, g_rc_param_alias, arg * 2)
                    if rc_mask_has(g_rc_param_content_escape, callee * 2, j) != 0:
                        arg := s1 + j
                        if arg >= 0 && arg < g_ir_var_count:
                            rc_summary_content_escape(fi, arg, ni, nstart)
                    if rc_mask_has(g_rc_param_ffi, callee * 2, j) != 0:
                        arg := s1 + j
                        if arg >= 0 && arg < g_ir_var_count:
                            rc_mask_or_from(g_rc_param_ffi, fi * 2,
                                            g_rc_param_alias, arg * 2)
                    if rc_mask_nonempty(g_rc_content_out_pairs, callee * 128 + j * 2) != 0:
                        src := s1 + j
                        if src >= 0 && src < g_ir_var_count:
                            i : ., mut = 0
                            loop:
                                if i >= cpc || i >= 64:
                                    break
                                if rc_mask_has(g_rc_content_out_pairs, callee * 128 + j * 2, i) != 0:
                                    di := s1 + i
                                    if di >= 0 && di < g_ir_var_count:
                                        if rc_is_param_var(fi, di) != 0:
                                            rc_summary_content_pair(fi, src, di, ni, nstart)
                                        else if rc_dest_is_local(di, ni, nstart, fi) == 0:
                                            rc_summary_content_escape(fi, src, ni, nstart)
                                i = i + 1
                    if rc_mask_nonempty(g_rc_out_pairs, callee * 128 + j * 2) != 0:
                        arg := s1 + j
                        if arg >= 0 && arg < g_ir_var_count:
                            i : ., mut = 0
                            loop:
                                if i >= cpc || i >= 64:
                                    break
                                if rc_mask_has(g_rc_out_pairs, callee * 128 + j * 2, i) != 0:
                                    di := s1 + i
                                    if di >= 0 && di < g_ir_var_count:
                                        if rc_mask_nonempty(g_rc_param_alias, di * 2) != 0:
                                            x : ., mut = 0
                                            loop:
                                                if x >= 64:
                                                    break
                                                if rc_mask_has(g_rc_param_alias, arg * 2, x) != 0:
                                                    y : ., mut = 0
                                                    loop:
                                                        if y >= 64:
                                                            break
                                                        if rc_mask_has(g_rc_param_alias, di * 2, y) != 0:
                                                            rc_mask_set(g_rc_out_pairs, fi * 128 + x * 2, y)
                                                        y = y + 1
                                                x = x + 1
                                        else if rc_dest_is_local(di, ni, nstart, fi) == 0:
                                            rc_mask_or_from(out, 0, g_rc_param_alias, arg * 2)
                                i = i + 1
                    j = j + 1
        ni = ni + 1
    new0 := cell_load(out, 0)
    new1 := cell_load(out, 8)
    new_ret0 := cell_load(ret, 0)
    new_ret1 := cell_load(ret, 8)
    changed : ., mut = 0
    if new0 != old0 || new1 != old1:
        cell_store(g_rc_param_escape, fi * 2 * 8, new0)
        cell_store(g_rc_param_escape, (fi * 2 + 1) * 8, new1)
        changed = 1
    if new_ret0 != ret_old0 || new_ret1 != ret_old1:
        cell_store(g_rc_ret_alias, fi * 2 * 8, new_ret0)
        cell_store(g_rc_ret_alias, (fi * 2 + 1) * 8, new_ret1)
        changed = 1
    return changed

fn rc_param_summaries():
    g_rc_param_alias = alloc(g_ir_var_count * 2 * 8)
    g_rc_param_escape = alloc(g_ir_func_count * 2 * 8)
    g_rc_ret_alias = alloc(g_ir_func_count * 2 * 8)
    g_rc_out_pairs = alloc(g_ir_func_count * 128 * 8)
    g_rc_param_content_alias = alloc(g_ir_var_count * 2 * 8)
    g_rc_param_content_escape = alloc(g_ir_func_count * 2 * 8)
    g_rc_param_ffi = alloc(g_ir_func_count * 2 * 8)
    g_rc_content_out_pairs = alloc(g_ir_func_count * 128 * 8)
    i : ., mut = 0
    loop:
        if i >= g_ir_var_count * 2:
            break
        cell_store(g_rc_param_alias, i * 8, 0)
        i = i + 1
    i = 0
    loop:
        if i >= g_ir_func_count * 2:
            break
        cell_store(g_rc_param_escape, i * 8, 0)
        cell_store(g_rc_ret_alias, i * 8, 0)
        cell_store(g_rc_param_content_escape, i * 8, 0)
        cell_store(g_rc_param_ffi, i * 8, 0)
        i = i + 1
    i = 0
    loop:
        if i >= g_ir_func_count * 128:
            break
        cell_store(g_rc_out_pairs, i * 8, 0)
        cell_store(g_rc_content_out_pairs, i * 8, 0)
        i = i + 1
    fi : ., mut = 0
    loop:
        if fi >= g_ir_func_count:
            break
        rc_alias_compute(fi)
        fi = fi + 1
    changed : ., mut = 1
    loop:
        if changed == 0:
            break
        changed = 0
        fi = 0
        loop:
            if fi >= g_ir_func_count:
                break
            rc_alias_compute(fi)
            fi = fi + 1
        fi = 0
        loop:
            if fi >= g_ir_func_count:
                break
            if rc_summary_func(fi) != 0:
                changed = 1
            fi = fi + 1

fn rc_value_has_release(val: int, at_node: int, lo: int, depth: int) -> int:
    if val < 0 || depth > RC_MAX_DEPTH:
        return 0
    lazy := rc_lazy_source(val)
    if lazy >= 0:
        return rc_value_has_release(lazy, at_node, lo, depth + 1)
    if rc_node_defines(at_node, val) == 0 && rc_rd_any(val, at_node) != 0:
        return rc_rd_defs_release(val, at_node, lo, depth + 1)
    if pa_pts_empty(val) == 0:
        ai : ., mut = 0
        loop:
            if ai >= g_pa_alloc_count:
                return 0
            if pa_pts_has(val, ai) != 0 && rc_bit_exit(ai) >= 0:
                return 1
            ai = ai + 1
        return 0
    sg := rc_stack_release_sg_rec(val, at_node, lo, 1)
    if sg >= 0:
        return 1
    return 0

fn rc_rd_defs_release(var: int, use_ni: int, lo: int, depth: int) -> int:
    if depth > RC_MAX_DEPTH:
        return 0
    base := rc_rd_collect(var, use_ni, depth)
    dc := g_rc_rd_def_count
    i : ., mut = 0
    loop:
        if i >= dc:
            return 0
        dn := cell_load(g_rc_rd_defs, (base + i) * 8)
        op := cell_load(g_df_nodes, dn * ESZ_DFNODE + OFF_DF_OPCODE)
        d  := cell_load(g_df_nodes, dn * ESZ_DFNODE + OFF_DF_DEST)
        s1 := cell_load(g_df_nodes, dn * ESZ_DFNODE + OFF_DF_S1)
        s2 := cell_load(g_df_nodes, dn * ESZ_DFNODE + OFF_DF_S2)
        s3 := cell_load(g_df_nodes, dn * ESZ_DFNODE + OFF_DF_S3)
        if op == IR_LAZY_THUNK || op == IR_LAZY_FORCE:
            if s1 >= 0 && rc_value_has_release(s1, dn, lo, depth + 1) != 0:
                return 1
        else if op == IR_CALL:
            callee := rc_func_by_name(s3)
            if callee >= 0:
                pc := cell_load(g_ir_func_param_count, callee * 8)
                j : ., mut = 0
                loop:
                    if j >= pc || j >= s2 || j >= 64:
                        break
                    if rc_mask_has(g_rc_ret_alias, callee * 2, j) != 0:
                        arg := s1 + j
                        if rc_value_has_release(arg, dn, lo, depth + 1) != 0:
                            return 1
                    j = j + 1
        else if op == IR_STORE && s1 == var:
            if s2 >= 0 && rc_value_has_release(s2, dn, lo, depth + 1) != 0:
                return 1
        else if op == IR_PHI && d == var:
            if s1 >= 0 && rc_value_has_release(s1, dn, lo, depth + 1) != 0:
                return 1
            if s2 >= 0 && rc_value_has_release(s2, dn, lo, depth + 1) != 0:
                return 1
        else:
            if rc_value_has_release(var, dn, lo, depth + 1) != 0:
                return 1
        i = i + 1
    return 0

// Inspect the value held in a local slot that a `&slot` argument points to.
// `dest` is the destination lifetime; -1 = program/function-level.
fn rc_slot_content_outlives(slot: int, dest: int, at_node: int, nstart: int,
                            fi: int, depth: int) -> int:
    if slot < 0 || depth > RC_MAX_DEPTH:
        return 0
    if rc_is_param_var(fi, slot) != 0 || rc_is_global_var(slot) != 0:
        return 0
    if rc_rd_any(slot, at_node) == 0:
        return 0
    base := rc_rd_collect(slot, at_node, depth)
    dc := g_rc_rd_def_count
    i : ., mut = 0
    loop:
        if i >= dc:
            return 0
        dn := cell_load(g_rc_rd_defs, (base + i) * 8)
        op := cell_load(g_df_nodes, dn * ESZ_DFNODE + OFF_DF_OPCODE)
        d  := cell_load(g_df_nodes, dn * ESZ_DFNODE + OFF_DF_DEST)
        s1 := cell_load(g_df_nodes, dn * ESZ_DFNODE + OFF_DF_S1)
        s2 := cell_load(g_df_nodes, dn * ESZ_DFNODE + OFF_DF_S2)
        if op == IR_STORE && s1 == slot:
            if s2 >= 0 && rc_scalar_value_outlives_rd(s2, dn, dest, nstart, depth + 1) != 0:
                return 1
        else if op == IR_PHI && d == slot:
            if s1 >= 0 && rc_scalar_value_outlives_rd(s1, dn, dest, nstart, depth + 1) != 0:
                return 1
            if s2 >= 0 && rc_scalar_value_outlives_rd(s2, dn, dest, nstart, depth + 1) != 0:
                return 1
        i = i + 1
    return 0

// Does the pointee content of `ptr_var` outlive `dest`? Used for `gp = *pp`
// (dest = -1) and for content passed through out-parameters.
fn rc_pointee_content_outlives(ptr_var: int, dest: int, at_node: int,
                               nstart: int, fi: int, depth: int) -> int:
    if ptr_var < 0 || depth > RC_MAX_DEPTH:
        return 0
    if rc_is_global_var(ptr_var) != 0:
        return 0
    if pa_pts_empty(ptr_var) == 0:
        ai : ., mut = 0
        loop:
            if ai >= g_pa_alloc_count:
                return 0
            if pa_pts_has(ptr_var, ai) != 0:
                ex := rc_bit_exit(ai)
                if ex >= 0 && (dest == -1 || dest > ex):
                    return 1
            ai = ai + 1
        return 0
    if rc_rd_any(ptr_var, at_node) != 0:
        base := rc_rd_collect(ptr_var, at_node, depth)
        dc := g_rc_rd_def_count
        i : ., mut = 0
        loop:
            if i >= dc:
                return 0
            dn := cell_load(g_rc_rd_defs, (base + i) * 8)
            op := cell_load(g_df_nodes, dn * ESZ_DFNODE + OFF_DF_OPCODE)
            d  := cell_load(g_df_nodes, dn * ESZ_DFNODE + OFF_DF_DEST)
            s1 := cell_load(g_df_nodes, dn * ESZ_DFNODE + OFF_DF_S1)
            s2 := cell_load(g_df_nodes, dn * ESZ_DFNODE + OFF_DF_S2)
            if op == IR_REF && d == ptr_var:
                if s1 >= 0 && rc_slot_content_outlives(s1, dest, at_node, nstart, fi, depth + 1) != 0:
                    return 1
            else if op == IR_STORE && s1 == ptr_var:
                if s2 >= 0 && rc_pointee_content_outlives(s2, dest, dn, nstart, fi, depth + 1) != 0:
                    return 1
            else if op == IR_PHI && d == ptr_var:
                if s1 >= 0 && rc_pointee_content_outlives(s1, dest, dn, nstart, fi, depth + 1) != 0:
                    return 1
                if s2 >= 0 && rc_pointee_content_outlives(s2, dest, dn, nstart, fi, depth + 1) != 0:
                    return 1
            i = i + 1
        return 0
    prod := cell_load(g_df_var_producer, ptr_var * 8)
    if prod >= 0:
        op := cell_load(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_OPCODE)
        s1 := cell_load(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_S1)
        if op == IR_REF && s1 >= 0:
            return rc_slot_content_outlives(s1, dest, at_node, nstart, fi, depth + 1)
        if op == IR_LAZY_THUNK || op == IR_LAZY_FORCE:
            if s1 >= 0:
                return rc_pointee_content_outlives(s1, dest, prod, nstart, fi, depth + 1)
    return 0

fn rc_pointee_content_escapes(ptr_var: int, at_node: int, nstart: int,
                              fi: int, depth: int) -> int:
    return rc_pointee_content_outlives(ptr_var, -1, at_node, nstart, fi, depth)

fn rc_call_check(ni: int, first_arg: int, argc: int, fn_ni: int,
                 nstart: int, fi: int):
    callee := rc_func_by_name(fn_ni)
    if callee < 0:
        return
    pc := cell_load(g_ir_func_param_count, callee * 8)
    j : ., mut = 0
    loop:
        if j >= pc || j >= argc || j >= 64:
            return
        arg := first_arg + j
        if rc_mask_has(g_rc_param_escape, callee * 2, j) != 0:
            if arg >= 0 && arg < g_ir_var_count:
                if rc_value_has_release(arg, ni, nstart, 0) != 0:
                    check_error(EC_B_LIFETIME,
                        "parameter escape: callee stores a region-local pointer",
                        0, 0)
        if is_in_unsafe(ni) == 0 && rc_mask_has(g_rc_param_ffi, callee * 2, j) != 0:
            if arg >= 0 && arg < g_ir_var_count:
                if rc_value_has_release(arg, ni, nstart, 0) != 0:
                    check_error(EC_B_LIFETIME,
                        "extern call: region-local pointer argument requires unsafe",
                        0, 0)
        if rc_mask_has(g_rc_param_content_escape, callee * 2, j) != 0:
            if arg >= 0 && arg < g_ir_var_count:
                if rc_pointee_content_escapes(arg, ni, nstart, fi, 0) != 0:
                    check_error(EC_B_LIFETIME,
                        "parameter escape: callee leaks the pointee into a global",
                        0, 0)
        if rc_mask_nonempty(g_rc_out_pairs, callee * 128 + j * 2) != 0:
            i : ., mut = 0
            loop:
                if i >= pc || i >= argc || i >= 64:
                    break
                if rc_mask_has(g_rc_out_pairs, callee * 128 + j * 2, i) != 0:
                    di := first_arg + i
                    if di >= 0 && di < g_ir_var_count && arg >= 0:
                        // A destination supplied by our own caller is resolved
                        // at the next call site, not here.
                        if rc_is_param_var(fi, di) == 0:
                            if rc_store_outlives(di, arg, ni, nstart) != 0:
                                check_error(EC_B_LIFETIME,
                                    "parameter escape: callee stores a region-local pointer",
                                    0, 0)
                i = i + 1
        if rc_mask_nonempty(g_rc_content_out_pairs, callee * 128 + j * 2) != 0:
            i : ., mut = 0
            loop:
                if i >= pc || i >= argc || i >= 64:
                    break
                if rc_mask_has(g_rc_content_out_pairs, callee * 128 + j * 2, i) != 0:
                    di := first_arg + i
                    if di >= 0 && di < g_ir_var_count && arg >= 0:
                        if rc_is_param_var(fi, di) == 0:
                            dest : ., mut = rc_dest_max_exit(di, ni, nstart)
                            if dest == -2:
                                dest = -1
                            if rc_pointee_content_outlives(arg, dest, ni, nstart, fi, 0) != 0:
                                check_error(EC_B_LIFETIME,
                                    "parameter escape: callee leaks the pointee into an out-parameter",
                                    0, 0)
                i = i + 1
        j = j + 1

fn rc_var_escapes(ptr_var: int, ni: int, mode: int) -> int:
    if ptr_var < 0:
        return 0
    ti := irv_type(ptr_var)
    if ti < 0 || (get_type_kind(ti) != TYP_PTR && get_type_kind(ti) != TYP_REF):
        return 0
    lo := rc_func_nstart(ni)
    // Reaching definitions make both heap and scalar pointer uses flow
    // sensitive: evaluate the value(s) that actually reach this use instead of
    // the flow-insensitive pts union / last-store heuristic.
    if rc_rd_any(ptr_var, ni) != 0:
        if rc_rd_defs_escape(ptr_var, ni, ni, lo, mode, 0) != 0:
            return 1
        return 0
    if pa_pts_empty(ptr_var) != 0:
        si := rc_last_store_before(ptr_var, lo, ni)
        if si >= 0:
            sop := cell_load(g_df_nodes, si * ESZ_DFNODE + OFF_DF_OPCODE)
            if rc_node_in_conditional(si) != 0 || sop == IR_PHI:
                if rc_stack_any_escapes(ptr_var, ni, lo, mode, 0) != 0:
                    return 1
        sg := rc_stack_release_sg_rec(ptr_var, ni, lo, 0)
        if sg < 0:
            return 0
        ex := rc_sg_lexit(sg)
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
    return rc_sg_lexit(sg)

fn rc_last_store_before(ptr_var: int, lo: int, hi: int) -> int:
    if ptr_var < 0 || hi <= lo:
        return -1
    if ptr_var < g_ir_var_count && rc_ptr_nonzero(g_rc_last_store) != 0:
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
    if ptr_var < 0 || depth > RC_MAX_DEPTH:
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
            vexit := rc_sg_lexit(vsg)
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
fn rc_store_value_is_pointer(val: int) -> int:
    if val < 0:
        return 0
    ti := irv_type(val)
    if ti >= 0 && (get_type_kind(ti) == TYP_PTR || get_type_kind(ti) == TYP_REF):
        return 1
    if pa_pts_empty(val) == 0:
        return 1
    return 0

fn rc_store_escape(ni: int, ptr_var: int, val_var: int, nstart: int):
    if rc_var_dead(val_var, ni) != 0:
        check_error(EC_B_LIFETIME,
            "store escape: storing pointer to exited subgraph allocation",
            0, 0)
    else if rc_store_outlives(ptr_var, val_var, ni, nstart) != 0:
        check_error(EC_B_LIFETIME,
            "store escape: destination outlives the stored allocation",
            0, 0)

fn region_check_func(nstart: int, ncount: int, vstart: int, vcount: int, fi: int):
    rc_ctl_prepare(nstart, ncount)
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
        s3 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S3)

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

        // Direct global assignment of a region-local pointer.
        if op == IR_STORE && s1 >= 0 && s2 >= 0 && rc_is_global_var(s1) != 0:
            if rc_value_has_release(s2, ni, nstart, 0) != 0:
                check_error(EC_B_LIFETIME,
                    "store escape: global outlives the stored allocation",
                    0, 0)

        // Element/field stores go through a base object instead of IR_STORE_PTR.
        if op == IR_STORE_INDEX && s1 >= 0 && s2 >= 0:
            if rc_store_value_is_pointer(s2) != 0:
                if rc_is_global_var(s1) != 0:
                    if rc_value_has_release(s2, ni, nstart, 0) != 0:
                        check_error(EC_B_LIFETIME,
                            "store escape: global outlives the stored allocation",
                            0, 0)
                else:
                    rc_store_escape(ni, s1, s2, nstart)
        if op == IR_STORE_INDEX_VAR && s1 >= 0 && d >= 0:
            if rc_store_value_is_pointer(d) != 0:
                if rc_is_global_var(s1) != 0:
                    if rc_value_has_release(d, ni, nstart, 0) != 0:
                        check_error(EC_B_LIFETIME,
                            "store escape: global outlives the stored allocation",
                            0, 0)
                else:
                    rc_store_escape(ni, s1, d, nstart)
        if op == IR_STORE_FIELD && s1 >= 0 && s2 >= 0:
            if rc_store_value_is_pointer(s2) != 0:
                if rc_is_global_var(s1) != 0:
                    if rc_value_has_release(s2, ni, nstart, 0) != 0:
                        check_error(EC_B_LIFETIME,
                            "store escape: global outlives the stored allocation",
                            0, 0)
                else:
                    rc_store_escape(ni, s1, s2, nstart)

        // Interprocedural escape through a call argument.
        if op == IR_CALL_EXTERN && is_in_unsafe(ni) == 0 && s2 >= 0 && s3 > 0:
            j : ., mut = 0
            loop:
                if j >= s3:
                    break
                arg := s2 + j
                if arg >= 0 && arg < g_ir_var_count:
                    if rc_store_value_is_pointer(arg) != 0:
                        if rc_value_has_release(arg, ni, nstart, 0) != 0:
                            check_error(EC_B_LIFETIME,
                                "extern call: region-local pointer argument requires unsafe",
                                0, 0)
                j = j + 1

        if op == IR_CALL:
            rc_call_check(ni, s1, s2, s3, nstart, fi)

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
    rc_param_summaries()
    fi : ., mut = 0
    loop:
        if fi >= g_ir_func_count:
            break
        nstart := cell_load(g_df_func_node_start, fi * 8)
        ncount := cell_load(g_df_func_node_count, fi * 8)
        vstart := cell_load(g_ir_func_var_start, fi * 8)
        vcount := cell_load(g_ir_func_var_count, fi * 8)
        region_check_func(nstart, ncount, vstart, vcount, fi)
        fi = fi + 1
