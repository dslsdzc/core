// === region_plan.cr ===
// V2.0 split plan. Phase A generates v1 IR and runs PointerAnalysis/RegionCheck;
// this pass marks SG_IFs whose direct allocations cannot leave the IF. Phase B
// regenerates the IR and emits a child arena for each marked IF.
//
// The plan is a compile-time table keyed by SG index. It is not serialized and
// is not part of the .ccr contract.

g_plan_split : string, mut
g_plan_split_count : int, mut
g_plan_split_cap : int, mut
g_plan_clear_label : string, mut
g_plan_clear_sg : string, mut
g_plan_clear_count : int, mut
g_plan_clear_cap : int, mut
g_plan_active : int, mut

fn region_plan_grow(n: int):
    if n < g_plan_split_cap:
        return
    nc : ., mut = g_plan_split_cap * 2
    if nc < 16:
        nc = 16
    loop:
        if nc > n:
            break
        nc = nc * 2
    nb := alloc(nc * 8)
    i : ., mut = 0
    loop:
        if i >= nc:
            break
        cell_store(nb, i * 8, 0)
        i = i + 1
    if g_plan_split_cap > 0:
        cell_copy(g_plan_split, g_plan_split_cap * 8, nb)
    g_plan_split = nb
    g_plan_split_cap = nc

fn region_plan_reset():
    g_plan_active = 0
    // A string global starts null; cap is the allocated-size witness.
    if g_plan_split_cap <= 0:
        g_plan_split_count = 0
        return
    i : ., mut = 0
    loop:
        if i >= g_plan_split_cap:
            break
        cell_store(g_plan_split, i * 8, 0)
        i = i + 1
    g_plan_split_count = 0
    g_plan_clear_count = 0

fn region_plan_mark_split(sg: int):
    if sg < 0:
        return
    region_plan_grow(sg + 1)
    if cell_load(g_plan_split, sg * 8) == 0:
        cell_store(g_plan_split, sg * 8, 1)
        g_plan_split_count = g_plan_split_count + 1

fn region_plan_is_split(sg: int) -> int:
    if sg < 0:
        return 0
    if g_plan_split_count <= 0:
        return 0
    if sg >= g_plan_split_cap:
        return 0
    return cell_load(g_plan_split, sg * 8)

fn region_plan_has_split() -> int:
    if g_plan_split_count > 0:
        return 1
    return 0

fn region_plan_grow_clear(n: int):
    if n < g_plan_clear_cap:
        return
    nc : ., mut = g_plan_clear_cap * 2
    if nc < 16:
        nc = 16
    loop:
        if nc > n:
            break
        nc = nc * 2
    nb := alloc(nc * 8)
    nb2 := alloc(nc * 8)
    i : ., mut = 0
    loop:
        if i >= nc:
            break
        cell_store(nb, i * 8, 0)
        cell_store(nb2, i * 8, 0)
        i = i + 1
    if g_plan_clear_cap > 0:
        cell_copy(g_plan_clear_label, g_plan_clear_cap * 8, nb)
        cell_copy(g_plan_clear_sg, g_plan_clear_cap * 8, nb2)
    g_plan_clear_label = nb
    g_plan_clear_sg = nb2
    g_plan_clear_cap = nc

fn region_plan_mark_clear(label_id: int, sg: int):
    if label_id < 0 || sg < 0:
        return
    i : ., mut = 0
    loop:
        if i >= g_plan_clear_count:
            break
        if cell_load(g_plan_clear_label, i * 8) == label_id && cell_load(g_plan_clear_sg, i * 8) == sg:
            return
        i = i + 1
    region_plan_grow_clear(g_plan_clear_count + 1)
    cell_store(g_plan_clear_label, g_plan_clear_count * 8, label_id)
    cell_store(g_plan_clear_sg, g_plan_clear_count * 8, sg)
    g_plan_clear_count = g_plan_clear_count + 1

fn region_plan_has_clear() -> int:
    if g_plan_clear_count > 0:
        return 1
    return 0

fn region_plan_has_plan() -> int:
    if g_plan_split_count > 0 || g_plan_clear_count > 0:
        return 1
    return 0

// Called from df_create_node for every IR_LABEL during Phase B. Emits the
// planned early clears after the label. The clear node itself is not a label,
// so this cannot recurse.
fn region_plan_emit_clears(label_id: int):
    if g_plan_clear_count <= 0:
        return
    i : ., mut = 0
    loop:
        if i >= g_plan_clear_count:
            return
        if cell_load(g_plan_clear_label, i * 8) == label_id:
            sg := cell_load(g_plan_clear_sg, i * 8)
            if sg >= 0 && sg < g_sg_arena_var_cap:
                slot := cell_load(g_sg_arena_var, sg * 8)
                if slot >= 0:
                    emit(IR_ARENA_CLEAR, -1, slot, 0, 0, 0)
        i = i + 1

fn rp_var_is_pointer(var: int) -> int:
    if var < 0:
        return 0
    ti := irv_type(var)
    if ti < 0 || ti >= g_type_count:
        return 0
    k := get_type_kind(ti)
    if k == TYP_PTR || k == TYP_REF:
        return 1
    return 0

fn rp_slot_inside(slot: int, sg: int) -> int:
    if slot < 0 || rc_is_global_var(slot) != 0:
        return 0
    prod := cell_load(g_df_var_producer, slot * 8)
    if prod < 0:
        return 0
    return rc_sg_is_ancestor(sg, subgraph_containing(prod))

// A local slot whose address is taken can be read after the IF through an
// alias; storing a split pointer into it is an escape even when the slot itself
// is declared inside the IF.
fn rp_slot_addr_taken(slot: int, nstart: int, ncount: int) -> int:
    if slot < 0:
        return 0
    ni : ., mut = nstart
    loop:
        if ni >= nstart + ncount:
            return 0
        op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
        s1 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)
        if op == IR_REF && s1 == slot:
            return 1
        ni = ni + 1

// Is the storage reached by `ptr_var` declared inside `sg`? Used for stores of
// split allocation pointers into outer slots.
fn rp_target_inside(ptr_var: int, at_node: int, sg: int, nstart: int, ncount: int, depth: int) -> int:
    if ptr_var < 0 || depth > RC_MAX_DEPTH:
        return 0
    if rc_is_global_var(ptr_var) != 0:
        return 0
    if pa_pts_empty(ptr_var) == 0:
        saw : ., mut = 0
        ai : ., mut = 0
        loop:
            if ai >= g_pa_alloc_count:
                return saw
            if pa_pts_has(ptr_var, ai) != 0:
                saw = 1
                an := cell_load(g_pa_alloc_nodes, ai * 8)
                if rc_sg_is_ancestor(sg, subgraph_containing(an)) == 0:
                    return 0
            ai = ai + 1
        return saw
    prod := cell_load(g_df_var_producer, ptr_var * 8)
    if prod < 0:
        return 0
    op := cell_load(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_OPCODE)
    s1 := cell_load(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_S1)
    s2 := cell_load(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_S2)
    if op == IR_REF:
        if rp_slot_inside(s1, sg) == 0:
            return 0
        if rp_slot_addr_taken(s1, nstart, ncount) != 0:
            return 0
        return 1
    if op == IR_PHI:
        if s1 < 0 || rp_target_inside(s1, prod, sg, nstart, ncount, depth + 1) == 0:
            return 0
        if s2 < 0 || rp_target_inside(s2, prod, sg, nstart, ncount, depth + 1) == 0:
            return 0
        return 1
    if op == IR_LAZY_THUNK || op == IR_LAZY_FORCE:
        if s1 >= 0:
            return rp_target_inside(s1, prod, sg, nstart, ncount, depth + 1)
    return 0

fn rp_if_has_unsafe(sg_start: int, sg_count: int) -> int:
    ni : ., mut = sg_start
    loop:
        if ni >= sg_start + sg_count:
            return 0
        if is_in_unsafe(ni) != 0:
            return 1
        ni = ni + 1

fn rp_label_inside(target: int, sg_start: int, sg_count: int) -> int:
    if target < 0:
        return 0
    if target >= sg_start && target < sg_start + sg_count:
        return 1
    return 0

// Non-local exit or an opaque effect: return, calls, spawn/await, address
// observation, or a jump/match target outside the IF. Conservative on purpose.
fn rp_if_has_exit_or_effect(sg_start: int, sg_count: int) -> int:
    ni : ., mut = sg_start
    loop:
        if ni >= sg_start + sg_count:
            return 0
        op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
        s1 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)
        if op == IR_RETURN || op == IR_CALL || op == IR_CALL_EXTERN || op == IR_SPAWN || op == IR_YIELD || op == IR_AWAIT || op == IR_PTR_OF || op == IR_STR_OF:
            return 1
        if op == IR_JUMP:
            t := rc_ctl_label_node(s1)
            if rp_label_inside(t, sg_start, sg_count) == 0:
                return 1
        ni = ni + 1

fn rp_alloc_escapes(alloc_id: int, sg: int, nstart: int, ncount: int,
                    sg_start: int, sg_count: int) -> int:
    an := cell_load(g_pa_alloc_nodes, alloc_id * 8)
    ni : ., mut = nstart
    loop:
        if ni >= nstart + ncount:
            return 0
        op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
        d  := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_DEST)
        s1 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)
        s2 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S2)
        s3 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S3)
        uses_alloc : ., mut = 0
        if s1 >= 0 && rp_var_is_pointer(s1) != 0 && pa_pts_has(s1, alloc_id) != 0:
            uses_alloc = 1
        if s2 >= 0 && rp_var_is_pointer(s2) != 0 && pa_pts_has(s2, alloc_id) != 0:
            uses_alloc = 1
        if s3 >= 0 && rp_var_is_pointer(s3) != 0 && pa_pts_has(s3, alloc_id) != 0:
            uses_alloc = 1
        if d >= 0 && rp_var_is_pointer(d) != 0 && op == IR_STORE_INDEX_VAR && pa_pts_has(d, alloc_id) != 0:
            uses_alloc = 1
        if uses_alloc != 0 && ni != an:
            nsg := subgraph_containing(ni)
            if rc_sg_is_ancestor(sg, nsg) == 0:
                return 1
            if op == IR_STORE_PTR && s2 >= 0 && pa_pts_has(s2, alloc_id) != 0:
                if rp_target_inside(s1, ni, sg, nstart, ncount, 0) == 0:
                    return 1
            if op == IR_STORE && s2 >= 0 && pa_pts_has(s2, alloc_id) != 0:
                if rp_slot_inside(s1, sg) == 0:
                    return 1
                if rp_slot_addr_taken(s1, nstart, ncount) != 0:
                    return 1
            if op == IR_STORE_INDEX && s2 >= 0 && pa_pts_has(s2, alloc_id) != 0:
                if rp_target_inside(s1, ni, sg, nstart, ncount, 0) == 0:
                    return 1
            if op == IR_STORE_FIELD && s2 >= 0 && pa_pts_has(s2, alloc_id) != 0:
                if rp_target_inside(s1, ni, sg, nstart, ncount, 0) == 0:
                    return 1
            if op == IR_STORE_INDEX_VAR && d >= 0 && pa_pts_has(d, alloc_id) != 0:
                if rp_target_inside(s1, ni, sg, nstart, ncount, 0) == 0:
                    return 1
        ni = ni + 1

// Returns 1 when the IF has at least one direct allocation and every direct
// allocation stays inside.
fn rp_if_eligible(sg: int, sg_start: int, sg_count: int,
                  nstart: int, ncount: int) -> int:
    found : ., mut = 0
    ai : ., mut = 0
    loop:
        if ai >= g_pa_alloc_count:
            return found
        an := cell_load(g_pa_alloc_nodes, ai * 8)
        aop := cell_load(g_df_nodes, an * ESZ_DFNODE + OFF_DF_OPCODE)
        if (aop == IR_ALLOC_ARRAY || aop == IR_ALLOC_STRUCT) && subgraph_containing(an) == sg:
            found = 1
            if rp_alloc_escapes(ai, sg, nstart, ncount, sg_start, sg_count) != 0:
                return 0
        ai = ai + 1
    return found

fn rp_global_var_named(name: string) -> int:
    gi : ., mut = 0
    loop:
        if gi >= g_ir_global_count:
            return -1
        if str_eq(istr_get(cell_load(g_ir_globals, gi * 24)), name) != 0:
            return cell_load(g_ir_globals, gi * 24 + 8)
        gi = gi + 1
    return -1

fn rp_if_reads_var(sg_start: int, sg_count: int, var: int) -> int:
    if var < 0:
        return 0
    ni : ., mut = sg_start
    loop:
        if ni >= sg_start + sg_count:
            return 0
        s1 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)
        s2 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S2)
        s3 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S3)
        if s1 == var || s2 == var || s3 == var:
            return 1
        ni = ni + 1

// Slot owner for an allocation. `rc_releasing_region` returns -1 for
// function-level allocations because a function exit is not a RegionCheck
// release point; early clear still needs the owning SG_FUNC.
fn rp_alloc_slot(an: int) -> int:
    s := rc_releasing_region(an)
    if s >= 0:
        return s
    sg : ., mut = subgraph_containing(an)
    loop:
        if sg < 0:
            return -1
        if cell_load(g_sgs, sg * ESZ_SG + OFF_SG_KIND) == SG_FUNC:
            return sg
        sg = cell_load(g_sgs, sg * ESZ_SG + OFF_SG_PARENT)
    return -1

fn rp_alloc_last_use(alloc_id: int, nstart: int, ncount: int) -> int:
    an := cell_load(g_pa_alloc_nodes, alloc_id * 8)
    last : ., mut = nstart
    ni : ., mut = nstart
    loop:
        if ni >= nstart + ncount:
            return last
        op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
        d  := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_DEST)
        s1 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)
        s2 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S2)
        s3 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S3)
        use : ., mut = 0
        if s1 >= 0 && rp_var_is_pointer(s1) != 0 && pa_pts_has(s1, alloc_id) != 0:
            use = 1
        if s2 >= 0 && rp_var_is_pointer(s2) != 0 && pa_pts_has(s2, alloc_id) != 0:
            use = 1
        if s3 >= 0 && rp_var_is_pointer(s3) != 0 && pa_pts_has(s3, alloc_id) != 0:
            use = 1
        if d >= 0 && op == IR_STORE_INDEX_VAR && rp_var_is_pointer(d) != 0 && pa_pts_has(d, alloc_id) != 0:
            use = 1
        if use != 0 && ni != an && ni > last:
            last = ni
        ni = ni + 1

// No later jump/match may reach a node at or before the clear point. A backedge
// to a use after the clear would make the clear unsound.
fn rp_clear_suffix_safe(qn: int, sg_end: int) -> int:
    ni : ., mut = qn + 1
    loop:
        if ni >= sg_end:
            return 1
        op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
        s1 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)
        s2 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S2)
        s3 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S3)
        if op == IR_JUMP:
            t := rc_ctl_label_node(s1)
            if t >= 0 && t <= qn:
                return 0
        if op == IR_MATCH:
            base := s2
            cnt := s3
            k : ., mut = 0
            loop:
                if k >= cnt:
                    break
                if base >= 0 && base + k < g_lat_case_count:
                    lbl := cell_load_i32(g_lat_case, (base + k) * CCR_V10_CASE_DISK + CCR_CASE_TARGET)
                    t := rc_ctl_label_node(lbl)
                    if t >= 0 && t <= qn:
                        return 0
                k = k + 1
        ni = ni + 1
    return 1

// A later allocation in the same basic block makes the clear immediately
// useful on this path. An allocation in another branch does not: clearing here
// would only add an instruction without enabling reuse on the current path.
fn rp_same_block_alloc_after(qn: int, sg: int, sg_end: int) -> int:
    ni : ., mut = qn + 1
    loop:
        if ni >= sg_end:
            return 0
        op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
        if op == IR_LABEL || op == IR_JUMP || op == IR_MATCH || op == IR_RETURN:
            return 0
        if op == IR_ALLOC_ARRAY || op == IR_ALLOC_STRUCT:
            if rp_alloc_slot(ni) == sg:
                return 1
        ni = ni + 1

// Earliest label where every allocation before it is dead, and at least one
// allocation follows (so the clear actually enables reuse).
fn rp_clear_candidate(sg: int, nstart: int, ncount: int, sg_start: int, sg_end: int) -> int:
    qn : ., mut = sg_start
    loop:
        if qn >= sg_end:
            return -1
        op := cell_load(g_df_nodes, qn * ESZ_DFNODE + OFF_DF_OPCODE)
        if op == IR_LABEL:
            max_last : ., mut = nstart
            before : ., mut = 0
            ai : ., mut = 0
            loop:
                if ai >= g_pa_alloc_count:
                    break
                an := cell_load(g_pa_alloc_nodes, ai * 8)
                aop := cell_load(g_df_nodes, an * ESZ_DFNODE + OFF_DF_OPCODE)
                if rp_alloc_slot(an) == sg && (aop == IR_ALLOC_ARRAY || aop == IR_ALLOC_STRUCT):
                    if an < qn:
                        before = 1
                        lu := rp_alloc_last_use(ai, nstart, ncount)
                        if lu > max_last:
                            max_last = lu
                ai = ai + 1
            if before != 0 && max_last < qn && rp_same_block_alloc_after(qn, sg, sg_end) != 0:
                if rp_clear_suffix_safe(qn, sg_end) != 0:
                    return cell_load(g_df_nodes, qn * ESZ_DFNODE + OFF_DF_S1)
        qn = qn + 1
    return -1

fn region_plan_analyze():
    region_plan_reset()
    // Phase B currently regenerates with ir_gen_all, which does not reproduce
    // the per-function monomorph/optional representation path. Keep those
    // programs on v1 until the shared generator is extracted.
    if g_optrep_on != 0:
        return
    // Monomorph instances are appended during Phase A; ir_gen_all does not
    // reproduce the per-function instance path exactly, so keep them on v1.
    if g_gen_instance_count > 0:
        return
    gs : ., mut = 0
    loop:
        if gs >= g_func_count:
            break
        if fi_generic_count(gs) > 0:
            return
        gs = gs + 1
    fi : ., mut = 0
    loop:
        if fi >= g_ir_func_count:
            break
        nstart := cell_load(g_df_func_node_start, fi * 8)
        ncount := cell_load(g_df_func_node_count, fi * 8)
        if nstart < 0 || ncount <= 0:
            fi = fi + 1
            continue
        rc_ctl_prepare(nstart, ncount)
        sg : ., mut = 0
        loop:
            if sg >= g_sg_count:
                break
            sg_start := cell_load(g_sgs, sg * ESZ_SG + OFF_SG_NSTART)
            sg_count := cell_load(g_sgs, sg * ESZ_SG + OFF_SG_NCOUNT)
            if sg_start >= nstart && sg_start < nstart + ncount:
                if cell_load(g_sgs, sg * ESZ_SG + OFF_SG_KIND) == SG_IF:
                    if rp_if_has_unsafe(sg_start, sg_count) == 0:
                        if rp_if_has_exit_or_effect(sg_start, sg_count) == 0:
                            cav := rp_global_var_named("g_current_arena")
                            if rp_if_reads_var(sg_start, sg_count, cav) == 0:
                                if rp_if_eligible(sg, sg_start, sg_count, nstart, ncount) != 0:
                                    region_plan_mark_split(sg)
            sg = sg + 1
        fi = fi + 1

    // Second pass: early clear for FUNC/LOOP/FOR/UNSAFE slots. Run after all
    // split marks so allocations in a split IF are not counted for the parent.
    fi = 0
    loop:
        if fi >= g_ir_func_count:
            return
        nstart := cell_load(g_df_func_node_start, fi * 8)
        ncount := cell_load(g_df_func_node_count, fi * 8)
        if nstart < 0 || ncount <= 0:
            fi = fi + 1
            continue
        rc_ctl_prepare(nstart, ncount)
        sg : ., mut = 0
        loop:
            if sg >= g_sg_count:
                break
            sg_start := cell_load(g_sgs, sg * ESZ_SG + OFF_SG_NSTART)
            sg_count := cell_load(g_sgs, sg * ESZ_SG + OFF_SG_NCOUNT)
            if sg_start >= nstart && sg_start < nstart + ncount:
                k := cell_load(g_sgs, sg * ESZ_SG + OFF_SG_KIND)
                if k == SG_FUNC || k == SG_LOOP || k == SG_FOR || k == SG_UNSAFE:
                    lbl := rp_clear_candidate(sg, nstart, ncount, sg_start, sg_start + sg_count)
                    if lbl >= 0:
                        region_plan_mark_clear(lbl, sg)
            sg = sg + 1
        fi = fi + 1
