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
g_plan_merge : string, mut
g_plan_merge_count : int, mut
g_plan_merge_cap : int, mut
g_plan_share : string, mut
g_plan_share_exit : string, mut
g_plan_share_after : string, mut
g_plan_share_count : int, mut
g_plan_share_cap : int, mut
g_plan_share_reset_emitted : int, mut
g_rp_share_consumer : int, mut
g_rp_share_exit : int, mut
g_plan_active : int, mut
// Post-dominator sets for the current function (bitset rows, 63 lanes).
g_rp_pdom : string, mut
g_rp_common : string, mut
g_rp_pdom_words : int, mut
g_rp_pdom_nstart : int, mut
g_rp_pdom_ncount : int, mut
g_rp_pdom_ok : int, mut

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
    g_rp_pdom_ok = 0
    g_plan_share_reset_emitted = 0
    g_rp_share_consumer = -1
    g_rp_share_exit = -1
    // A string global starts null; cap is the allocated-size witness. Each
    // table is cleared independently: merge/share can be allocated without a
    // split table in the same process.
    if g_plan_split_cap > 0:
        i : ., mut = 0
        loop:
            if i >= g_plan_split_cap:
                break
            cell_store(g_plan_split, i * 8, 0)
            i = i + 1
    g_plan_split_count = 0
    g_plan_clear_count = 0
    if g_plan_merge_cap > 0:
        i : ., mut = 0
        loop:
            if i >= g_plan_merge_cap:
                break
            cell_store(g_plan_merge, i * 8, 0)
            i = i + 1
    g_plan_merge_count = 0
    if g_plan_share_cap > 0:
        i : ., mut = 0
        loop:
            if i >= g_plan_share_cap:
                break
            cell_store(g_plan_share, i * 8, 0)
            cell_store(g_plan_share_exit, i * 8, -1)
            cell_store(g_plan_share_after, i * 8, 0)
            i = i + 1
    g_plan_share_count = 0

fn region_plan_mark_split(sg: int):
    if sg < 0:
        return
    region_plan_grow(sg + 1)
    if cell_load(g_plan_split, sg * 8) == 0:
        cell_store(g_plan_split, sg * 8, 1)
        g_plan_split_count = g_plan_split_count + 1

fn region_plan_grow_merge(n: int):
    if n <= g_plan_merge_cap:
        return
    nc : ., mut = g_plan_merge_cap * 2
    if nc < g_sg_count + 16:
        nc = g_sg_count + 16
    loop:
        if nc >= n:
            break
        nc = nc * 2
    nb := alloc(nc * 8)
    i : ., mut = 0
    loop:
        if i >= nc:
            break
        cell_store(nb, i * 8, 0)
        i = i + 1
    if g_plan_merge_cap > 0:
        cell_copy(g_plan_merge, g_plan_merge_cap * 8, nb)
    g_plan_merge = nb
    g_plan_merge_cap = nc

fn region_plan_mark_merge(sg: int, elem_count: int):
    if sg < 0 || elem_count <= 0:
        return
    region_plan_grow_merge(sg + 1)
    if cell_load(g_plan_merge, sg * 8) == 0:
        cell_store(g_plan_merge, sg * 8, elem_count)
        g_plan_merge_count = g_plan_merge_count + 1

fn region_plan_is_merge(sg: int) -> int:
    if sg < 0 || g_plan_merge_count <= 0 || sg >= g_plan_merge_cap:
        return 0
    return cell_load(g_plan_merge, sg * 8)

// Element count of the parent copy for a merge IF (0 when not planned).
fn region_plan_merge_len(sg: int) -> int:
    return region_plan_is_merge(sg)

fn region_plan_grow_share(n: int):
    if n <= g_plan_share_cap:
        return
    nc : ., mut = g_plan_share_cap * 2
    if nc < g_sg_count + 16:
        nc = g_sg_count + 16
    loop:
        if nc >= n:
            break
        nc = nc * 2
    nb := alloc(nc * 8)
    ne := alloc(nc * 8)
    na := alloc(nc * 8)
    i : ., mut = 0
    loop:
        if i >= nc:
            break
        cell_store(nb, i * 8, 0)
        cell_store(ne, i * 8, -1)
        cell_store(na, i * 8, 0)
        i = i + 1
    if g_plan_share_cap > 0:
        cell_copy(g_plan_share, g_plan_share_cap * 8, nb)
        cell_copy(g_plan_share_exit, g_plan_share_cap * 8, ne)
        cell_copy(g_plan_share_after, g_plan_share_cap * 8, na)
    g_plan_share = nb
    g_plan_share_exit = ne
    g_plan_share_after = na
    g_plan_share_cap = nc

fn region_plan_unmark_merge(sg: int):
    if sg < 0 || g_plan_merge_count <= 0 || sg >= g_plan_merge_cap:
        return
    if cell_load(g_plan_merge, sg * 8) != 0:
        cell_store(g_plan_merge, sg * 8, 0)
        g_plan_merge_count = g_plan_merge_count - 1

fn region_plan_mark_share(sg: int, exit_node: int, consumer: int):
    if sg < 0 || consumer < 0 || exit_node < 0:
        return
    n : ., mut = sg + 1
    if consumer + 1 > n:
        n = consumer + 1
    region_plan_grow_share(n)
    if consumer >= g_plan_share_cap:
        return
    if cell_load(g_plan_share, sg * 8) == 0:
        cell_store(g_plan_share, sg * 8, 1)
        cell_store(g_plan_share_exit, sg * 8, exit_node)
        cell_store(g_plan_share_after, consumer * 8, sg + 1)
        g_plan_share_count = g_plan_share_count + 1

fn region_plan_is_share(sg: int) -> int:
    if sg < 0 || g_plan_share_count <= 0 || sg >= g_plan_share_cap:
        return 0
    return cell_load(g_plan_share, sg * 8)

// Lifetime exit for a share slot: the last consumer's exit label id.
fn region_plan_share_exit(sg: int) -> int:
    if region_plan_is_share(sg) == 0:
        return -1
    return cell_load(g_plan_share_exit, sg * 8)

// Consumer SG -> share owner SG (or -1). The owner's reset is emitted after
// the consumer's own arena reset.
fn region_plan_share_after(cg: int) -> int:
    if cg < 0 || g_plan_share_count <= 0 || cg >= g_plan_share_cap:
        return -1
    v := cell_load(g_plan_share_after, cg * 8)
    if v <= 0:
        return -1
    return v - 1

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
    if g_plan_split_count > 0 || g_plan_clear_count > 0 || g_plan_merge_count > 0 || g_plan_share_count > 0:
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
            if sg >= 0 && sg < g_sg_arena_var_cap && sg < g_sg_count:
                k := cell_load(g_sgs, sg * ESZ_SG + OFF_SG_KIND)
                if k == SG_FUNC || k == SG_LOOP || k == SG_FOR || k == SG_UNSAFE:
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

// A stack slot can carry a points-to set even when its IR type row is TI_UNIT
// (the slot's declared type lives on the variable, not the alloc node). Any
// non-empty pts set is therefore a pointer carrier for escape/liveness scans.
fn rp_var_may_point(var: int) -> int:
    if var < 0:
        return 0
    if pa_pts_empty(var) == 0:
        return 1
    return rp_var_is_pointer(var)

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
        if s1 >= 0 && rp_var_may_point(s1) != 0 && pa_pts_has(s1, alloc_id) != 0:
            uses_alloc = 1
        if s2 >= 0 && rp_var_may_point(s2) != 0 && pa_pts_has(s2, alloc_id) != 0:
            uses_alloc = 1
        if s3 >= 0 && rp_var_may_point(s3) != 0 && pa_pts_has(s3, alloc_id) != 0:
            uses_alloc = 1
        if d >= 0 && rp_var_may_point(d) != 0 && op == IR_STORE_INDEX_VAR && pa_pts_has(d, alloc_id) != 0:
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

// True when the allocation is owned by a nested releasing region (loop, for,
// unsafe, or an already planned split/merge IF). Such an allocation never lands
// in the current IF's arena and its lifetime is handled by that region.
fn rp_alloc_has_nested_release(an: int, sg: int) -> int:
    csg : ., mut = subgraph_containing(an)
    loop:
        if csg < 0 || csg == sg:
            return 0
        if rc_sg_releases(csg) != 0:
            return 1
        csg = cell_load(g_sgs, csg * ESZ_SG + OFF_SG_PARENT)
    return 0

// Returns 1 when the IF has at least one direct allocation and every allocation
// that lands in its arena stays inside.
fn rp_if_eligible(sg: int, sg_start: int, sg_count: int,
                  nstart: int, ncount: int) -> int:
    found : ., mut = 0
    ai : ., mut = 0
    loop:
        if ai >= g_pa_alloc_count:
            return found
        an := cell_load(g_pa_alloc_nodes, ai * 8)
        aop := cell_load(g_df_nodes, an * ESZ_DFNODE + OFF_DF_OPCODE)
        if aop == IR_ALLOC_ARRAY || aop == IR_ALLOC_STRUCT:
            csg := subgraph_containing(an)
            if csg == sg:
                found = 1
            // Nested non-releasing allocations land in this IF's arena too, so
            // they must not escape this IF. A nested release owns its bytes.
            if csg == sg || rc_sg_is_ancestor(sg, csg) != 0:
                if rp_alloc_has_nested_release(an, sg) == 0:
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
        op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
        s1 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)
        s2 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S2)
        s3 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S3)
        if s1 == var || s2 == var || s3 == var:
            return 1
        if op == IR_STORE_INDEX_VAR:
            d := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_DEST)
            if d == var:
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

RP_FULL : int = 9223372036854775807

fn rp_bit_set(buf: string, base: int, bit: int):
    if bit < 0:
        return
    w := bit / 63
    m := pa_bit_mask(bit % 63)
    idx := (base + w) * 8
    cur := cell_load(buf, idx)
    if (cur / m) % 2 == 0:
        cell_store(buf, idx, cur + m)

fn rp_bit_has(buf: string, base: int, bit: int) -> int:
    if bit < 0:
        return 0
    w := bit / 63
    m := pa_bit_mask(bit % 63)
    return (cell_load(buf, (base + w) * 8) / m) % 2

fn rp_bits_clear(buf: string, base: int, words: int):
    w : ., mut = 0
    loop:
        if w >= words:
            return
        cell_store(buf, (base + w) * 8, 0)
        w = w + 1

fn rp_bits_fill(buf: string, base: int, words: int):
    w : ., mut = 0
    loop:
        if w >= words:
            return
        cell_store(buf, (base + w) * 8, RP_FULL)
        w = w + 1

fn rp_bits_and(dst: string, dbase: int, src: string, sbase: int, words: int) -> int:
    changed : ., mut = 0
    w : ., mut = 0
    loop:
        if w >= words:
            return changed
        a := cell_load(dst, (dbase + w) * 8)
        b := cell_load(src, (sbase + w) * 8)
        out : ., mut = 0
        mask : ., mut = 1
        k : ., mut = 0
        loop:
            if k >= 63:
                break
            if (a / mask) % 2 == 1 && (b / mask) % 2 == 1:
                out = out + mask
            mask = mask * 2
            k = k + 1
        if out != a:
            cell_store(dst, (dbase + w) * 8, out)
            changed = 1
        w = w + 1
    return changed

fn rp_bits_copy(dst: string, dbase: int, src: string, sbase: int, words: int):
    w : ., mut = 0
    loop:
        if w >= words:
            return
        cell_store(dst, (dbase + w) * 8, cell_load(src, (sbase + w) * 8))
        w = w + 1

fn rp_bits_same(a: string, abase: int, b: string, bbase: int, words: int) -> int:
    w : ., mut = 0
    loop:
        if w >= words:
            return 1
        if cell_load(a, (abase + w) * 8) != cell_load(b, (bbase + w) * 8):
            return 0
        w = w + 1

// Post-dominators over the HDFG-derived control adjacency. Exits are nodes with
// no successors; pdom[exit] = {exit}. The worklist starts with every node and
// re-enqueues predecessors when a row shrinks. A size/iteration cap keeps the
// pass bounded; exceeding it disables early clear for this function (v1).
fn rp_pdom_prepare(nstart: int, ncount: int):
    if g_rp_pdom_ok != 0 && g_rp_pdom_nstart == nstart && g_rp_pdom_ncount == ncount:
        return
    g_rp_pdom_nstart = nstart
    g_rp_pdom_ncount = ncount
    g_rp_pdom_ok = 0
    if ncount <= 0 || ncount > 2000:
        return
    words : ., mut = (ncount + 62) / 63
    if words < 1:
        words = 1
    g_rp_pdom_words = words
    g_rp_pdom = alloc(ncount * words * 8)
    i : ., mut = 0
    loop:
        if i >= ncount:
            break
        rp_bits_fill(g_rp_pdom, i * words, words)
        i = i + 1
    // Exit rows contain only the exit itself.
    i = 0
    loop:
        if i >= ncount:
            break
        if rc_ctl_succ_count(nstart + i) == 0:
            rp_bits_clear(g_rp_pdom, i * words, words)
            rp_bit_set(g_rp_pdom, i * words, i)
        i = i + 1
    // Predecessor lists.
    edge_total : ., mut = 0
    i = 0
    loop:
        if i >= ncount:
            break
        edge_total = edge_total + rc_ctl_succ_count(nstart + i)
        i = i + 1
    pred_head := alloc(ncount * 8)
    pred_from := alloc((edge_total + 1) * 8)
    pred_next := alloc((edge_total + 1) * 8)
    i = 0
    loop:
        if i >= ncount:
            break
        cell_store(pred_head, i * 8, -1)
        i = i + 1
    e : ., mut = 0
    i = 0
    loop:
        if i >= ncount:
            break
        sc := rc_ctl_succ_count(nstart + i)
        k : ., mut = 0
        loop:
            if k >= sc:
                break
            v := rc_ctl_succ_at(nstart + i, k)
            if v >= nstart && v < nstart + ncount:
                vi := v - nstart
                cell_store(pred_from, e * 8, i)
                cell_store(pred_next, e * 8, cell_load(pred_head, vi * 8))
                cell_store(pred_head, vi * 8, e)
                e = e + 1
            k = k + 1
        i = i + 1
    work := alloc(ncount * 8)
    queued := alloc(ncount * 8)
    i = 0
    loop:
        if i >= ncount:
            break
        cell_store(work, i * 8, i)
        cell_store(queued, i * 8, 1)
        i = i + 1
    top : ., mut = ncount
    temp := alloc(words * 8)
    guard : ., mut = 0
    loop:
        if top <= 0:
            break
        top = top - 1
        u := cell_load(work, top * 8)
        cell_store(queued, u * 8, 0)
        sc := rc_ctl_succ_count(nstart + u)
        if sc <= 0:
            rp_bits_clear(temp, 0, words)
        else:
            rp_bits_fill(temp, 0, words)
            k : ., mut = 0
            loop:
                if k >= sc:
                    break
                v := rc_ctl_succ_at(nstart + u, k)
                if v >= nstart && v < nstart + ncount:
                    rp_bits_and(temp, 0, g_rp_pdom, (v - nstart) * words, words)
                k = k + 1
        rp_bit_set(temp, 0, u - nstart)
        if rp_bits_same(temp, 0, g_rp_pdom, u * words, words) == 0:
            rp_bits_copy(g_rp_pdom, u * words, temp, 0, words)
            pe : ., mut = cell_load(pred_head, u * 8)
            loop:
                if pe < 0:
                    break
                pv := cell_load(pred_from, pe * 8)
                if cell_load(queued, pv * 8) == 0:
                    cell_store(work, top * 8, pv)
                    top = top + 1
                    cell_store(queued, pv * 8, 1)
                pe = cell_load(pred_next, pe * 8)
        guard = guard + 1
        if guard > ncount * 8 + 2000:
            return
    // common[alloc] = intersection of pdom[use] over every use of that alloc.
    if g_pa_alloc_count > 0:
        g_rp_common = alloc(g_pa_alloc_count * words * 8)
        ai : ., mut = 0
        loop:
            if ai >= g_pa_alloc_count:
                break
            rp_bits_fill(g_rp_common, ai * words, words)
            ai = ai + 1
        ni : ., mut = nstart
        loop:
            if ni >= nstart + ncount:
                break
            op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
            s1 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)
            s2 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S2)
            s3 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S3)
            if s1 >= 0 && rp_var_may_point(s1) != 0:
                ai2 : ., mut = 0
                loop:
                    if ai2 >= g_pa_alloc_count:
                        break
                    if pa_pts_has(s1, ai2) != 0 && ni != cell_load(g_pa_alloc_nodes, ai2 * 8):
                        rp_bits_and(g_rp_common, ai2 * words, g_rp_pdom, (ni - nstart) * words, words)
                    ai2 = ai2 + 1
            if s2 >= 0 && rp_var_may_point(s2) != 0:
                ai3 : ., mut = 0
                loop:
                    if ai3 >= g_pa_alloc_count:
                        break
                    if pa_pts_has(s2, ai3) != 0 && ni != cell_load(g_pa_alloc_nodes, ai3 * 8):
                        rp_bits_and(g_rp_common, ai3 * words, g_rp_pdom, (ni - nstart) * words, words)
                    ai3 = ai3 + 1
            if s3 >= 0 && rp_var_may_point(s3) != 0:
                ai4 : ., mut = 0
                loop:
                    if ai4 >= g_pa_alloc_count:
                        break
                    if pa_pts_has(s3, ai4) != 0 && ni != cell_load(g_pa_alloc_nodes, ai4 * 8):
                        rp_bits_and(g_rp_common, ai4 * words, g_rp_pdom, (ni - nstart) * words, words)
                    ai4 = ai4 + 1
            ni = ni + 1
    g_rp_pdom_ok = 1

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

fn rp_prior_uses_pdom(qn: int, sg: int, nstart: int) -> int:
    if g_rp_pdom_ok == 0:
        return 0
    words := g_rp_pdom_words
    ai : ., mut = 0
    loop:
        if ai >= g_pa_alloc_count:
            return 1
        an := cell_load(g_pa_alloc_nodes, ai * 8)
        if an < qn && rp_alloc_slot(an) == sg:
            if rp_bit_has(g_rp_common, ai * words, qn - nstart) == 0:
                return 0
        ai = ai + 1

fn rp_clear_candidate(sg: int, nstart: int, ncount: int, sg_start: int, sg_end: int) -> int:
    qn : ., mut = sg_start
    loop:
        if qn >= sg_end:
            return -1
        op := cell_load(g_df_nodes, qn * ESZ_DFNODE + OFF_DF_OPCODE)
        if op == IR_LABEL:
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
                ai = ai + 1
            if before != 0 && rp_prior_uses_pdom(qn, sg, nstart) != 0:
                if rp_same_block_alloc_after(qn, sg, sg_end) != 0:
                    if rp_clear_suffix_safe(qn, sg_end) != 0:
                        return cell_load(g_df_nodes, qn * ESZ_DFNODE + OFF_DF_S1)
        qn = qn + 1
    return -1

// IR_CALL/IR_SPAWN carry contiguous argument vars starting at s1.
fn rp_call_arg_uses_alloc(s1: int, s2: int, ai_sel: int) -> int:
    if s1 < 0 || s2 <= 0:
        return 0
    ac : ., mut = 0
    loop:
        if ac >= s2:
            return 0
        av := s1 + ac
        if av >= 0 && rp_var_may_point(av) != 0 && pa_pts_has(av, ai_sel) != 0:
            return 1
        ac = ac + 1
    return 0

fn rp_scalar_elem(ti: int) -> int:
    if ti < 0 || ti >= g_type_count:
        return 0
    if get_type_kind(ti) != TYP_BASE:
        return 0
    d := get_type_data(ti)
    if d == TY_INT || d == TY_BOOL || d == TY_CHAR || d == TY_DEX || d == TY_DEX_S:
        return 1
    return 0

fn rp_if_merge_ancestors_ok(sg: int) -> int:
    p : ., mut = cell_load(g_sgs, sg * ESZ_SG + OFF_SG_PARENT)
    loop:
        if p < 0:
            return 1
        k := cell_load(g_sgs, p * ESZ_SG + OFF_SG_KIND)
        if k == SG_FUNC:
            return 1
        if k == SG_LOOP || k == SG_FOR || k == SG_UNSAFE:
            return 0
        // The merge copy is allocated in the current slot. An enclosing IF arena
        // would reset it at the outer merge while the rebound slot may live on.
        if k == SG_IF && (region_plan_is_split(p) != 0 || region_plan_is_merge(p) != 0):
            return 0
        p = cell_load(g_sgs, p * ESZ_SG + OFF_SG_PARENT)

// V2.2 narrow merge: exactly one direct constant-size scalar array is stored
// directly into an outer local slot. Element reads and writes may reach the
// child through any alias inside the IF; outside the IF they must go through
// that slot. The copy runs at the end of the assigning branch and rebinds it.
fn rp_if_merge_eligible(sg: int, sg_start: int, sg_count: int,
                        nstart: int, ncount: int) -> int:
    // Flow-insensitive points-to cannot order uses across a loop backedge, so a
    // merge IF inside a loop stays v1. Unsafe blocks are also identity-observable.
    if rp_if_merge_ancestors_ok(sg) == 0:
        return 0
    alloc_count : ., mut = 0
    an : ., mut = -1
    ai_sel : ., mut = -1
    ai : ., mut = 0
    loop:
        if ai >= g_pa_alloc_count:
            break
        an2 := cell_load(g_pa_alloc_nodes, ai * 8)
        if subgraph_containing(an2) == sg:
            aop := cell_load(g_df_nodes, an2 * ESZ_DFNODE + OFF_DF_OPCODE)
            if aop != IR_ALLOC_ARRAY:
                return 0
            alloc_count = alloc_count + 1
            an = an2
            ai_sel = ai
        ai = ai + 1
    if alloc_count != 1 || an < 0:
        return 0
    // Every other allocation that lands in this IF's arena must stay inside;
    // only the selected array is copied out to the parent slot.
    ai = 0
    loop:
        if ai >= g_pa_alloc_count:
            break
        if ai != ai_sel:
            an2 := cell_load(g_pa_alloc_nodes, ai * 8)
            aop2 := cell_load(g_df_nodes, an2 * ESZ_DFNODE + OFF_DF_OPCODE)
            if aop2 == IR_ALLOC_ARRAY || aop2 == IR_ALLOC_STRUCT:
                csg2 := subgraph_containing(an2)
                if csg2 == sg || rc_sg_is_ancestor(sg, csg2) != 0:
                    if rp_alloc_has_nested_release(an2, sg) == 0:
                        if rp_alloc_escapes(ai, sg, nstart, ncount, sg_start, sg_count) != 0:
                            return 0
        ai = ai + 1
    alloc_dest := cell_load(g_df_nodes, an * ESZ_DFNODE + OFF_DF_DEST)
    at := irv_type(alloc_dest)
    if at < 0 || at >= g_type_count || get_type_kind(at) != TYP_ARRAY:
        return 0
    cnt := cell_load(g_df_nodes, an * ESZ_DFNODE + OFF_DF_S1)
    if cnt <= 0 || cnt > 64:
        return 0
    elem := get_type_data(at)
    if rp_scalar_elem(elem) == 0:
        return 0
    // Exactly one store into an outer local slot.
    dest : ., mut = -1
    stores : ., mut = 0
    ni : ., mut = sg_start
    loop:
        if ni >= sg_start + sg_count:
            break
        op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
        s1 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)
        s2 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S2)
        if op == IR_STORE && s2 == alloc_dest:
            if subgraph_containing(ni) != sg:
                return 0
            dest = s1
            stores = stores + 1
        ni = ni + 1
    if stores != 1 || dest < 0 || rc_is_global_var(dest) != 0:
        return 0
    prod := cell_load(g_df_var_producer, dest * 8)
    if prod < 0:
        return 0
    if rc_sg_is_ancestor(sg, subgraph_containing(prod)) != 0:
        return 0
    // The outer slot must not be overwritten again inside the IF.
    ni = sg_start
    loop:
        if ni >= sg_start + sg_count:
            break
        op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
        s1 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)
        s2 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S2)
        if op == IR_STORE && s1 == dest && s2 != alloc_dest:
            return 0
        ni = ni + 1
    // Precise use scan. For load/store-index the base is a use-through of the
    // child array; the stored value is an escape if it names the child. Every
    // other opcode that mentions the child is an observation and blocks.
    ni = nstart
    loop:
        if ni >= nstart + ncount:
            return cnt
        op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
        dv := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_DEST)
        s1 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)
        s2 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S2)
        s3 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S3)
        if ni > an:
            base : ., mut = -1
            value : ., mut = -1
            extra : ., mut = 0
            known : ., mut = 0
            if op == IR_LOAD_INDEX || op == IR_LOAD_INDEX_VAR:
                // s2 is the index variable for the _VAR form; s3 is a literal
                // index or element tag, never a pointer carrier.
                base = s1
                known = 1
                if op == IR_LOAD_INDEX_VAR && s2 >= 0 && rp_var_may_point(s2) != 0 && pa_pts_has(s2, ai_sel) != 0:
                    extra = 1
            else if op == IR_STORE_INDEX:
                base = s1
                value = s2
                known = 1
            else if op == IR_STORE_INDEX_VAR:
                base = s1
                value = dv
                known = 1
                if s2 >= 0 && rp_var_may_point(s2) != 0 && pa_pts_has(s2, ai_sel) != 0:
                    extra = 1
            if known == 0:
                if op == IR_STORE && s1 == dest && s2 == alloc_dest && subgraph_containing(ni) == sg:
                    // The one bind of the child into the outer slot.
                    ni = ni + 1
                    continue
                // Literal-only opcodes: their source fields are values, label
                // ids, or type tags, not variable slots.
                literal_only : ., mut = 0
                if op == IR_CONST || op == IR_CONST_BIG || op == IR_LABEL || op == IR_JUMP || op == IR_ALLOC || op == IR_ALLOC_ARRAY || op == IR_ALLOC_STRUCT || op == IR_BOUNDS_CHECK:
                    // Bounds checks carry only integer indices and lengths; the
                    // array pointer is not an operand.
                    literal_only = 1
                if literal_only == 0:
                    // IR_BINARY/IR_UNARY/IR_MATCH keep an operator or label
                    // range in the high fields; check only the value slots.
                    if op == IR_CALL || op == IR_SPAWN:
                        if rp_call_arg_uses_alloc(s1, s2, ai_sel) != 0:
                            return 0
                    else if op == IR_MATCH:
                        if s1 >= 0 && rp_var_may_point(s1) != 0 && pa_pts_has(s1, ai_sel) != 0:
                            return 0
                    else if op == IR_BINARY:
                        if s1 >= 0 && rp_var_may_point(s1) != 0 && pa_pts_has(s1, ai_sel) != 0:
                            return 0
                        if s2 >= 0 && rp_var_may_point(s2) != 0 && pa_pts_has(s2, ai_sel) != 0:
                            return 0
                    else if op == IR_UNARY:
                        if s1 >= 0 && rp_var_may_point(s1) != 0 && pa_pts_has(s1, ai_sel) != 0:
                            return 0
                    else:
                        if s1 >= 0 && rp_var_may_point(s1) != 0 && pa_pts_has(s1, ai_sel) != 0:
                            return 0
                        if s2 >= 0 && rp_var_may_point(s2) != 0 && pa_pts_has(s2, ai_sel) != 0:
                            return 0
                        if s3 >= 0 && rp_var_may_point(s3) != 0 && pa_pts_has(s3, ai_sel) != 0:
                            return 0
                        if dv >= 0 && rp_var_may_point(dv) != 0 && pa_pts_has(dv, ai_sel) != 0:
                            return 0
            else:
                if extra != 0:
                    return 0
                if value >= 0 && rp_var_may_point(value) != 0 && pa_pts_has(value, ai_sel) != 0:
                    return 0
                if base >= 0 && rp_var_may_point(base) != 0 && pa_pts_has(base, ai_sel) != 0:
                    if rc_sg_is_ancestor(sg, subgraph_containing(ni)) == 0 && base != dest:
                        return 0
        ni = ni + 1
    return cnt

// V2.3 narrow share: a top-level IF allocates one scalar array into its child
// slot and every use after the IF is a read through the rebound outer slot.
// The child slot stays live, is not reused, and is reset after the last
// consumer loop's own reset (the LCPD of the readers).
// Node of the SG's own IR_ARENA_NEW (the arena is not current before it).
fn rp_sg_arena_new_node(sg: int) -> int:
    av := cell_load(g_sg_arena_var, sg * 8)
    if av < 0:
        return -1
    ns := cell_load(g_sgs, sg * ESZ_SG + OFF_SG_NSTART)
    ne := cell_load(g_sgs, sg * ESZ_SG + OFF_SG_EXIT)
    ni : ., mut = ns
    loop:
        if ni >= ne:
            return -1
        op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
        d := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_DEST)
        if op == IR_ARENA_NEW && d == av:
            return ni
        ni = ni + 1
    return -1

// The consumer must reach its exit with only its own arena reset (or no arena
// created) active: no break/return, no nested loop/unsafe whose arena could be
// left live by a non-local exit. A nested split IF is fine: its reset restores
// the consumer arena before the consumer exits.
fn rp_share_consumer_simple(cons: int) -> int:
    cs := cell_load(g_sgs, cons * ESZ_SG + OFF_SG_NSTART)
    ce := cell_load(g_sgs, cons * ESZ_SG + OFF_SG_EXIT)
    d : ., mut = 0
    loop:
        if d >= g_sg_count:
            break
        if d != cons:
            ds := cell_load(g_sgs, d * ESZ_SG + OFF_SG_NSTART)
            if ds >= cs && ds < ce:
                k := cell_load(g_sgs, d * ESZ_SG + OFF_SG_KIND)
                if k == SG_LOOP || k == SG_FOR || k == SG_UNSAFE:
                    return 0
                if region_plan_is_merge(d) != 0:
                    return 0
        d = d + 1
    ni : ., mut = cs
    loop:
        if ni >= ce:
            return 1
        op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
        s1 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)
        if op == IR_RETURN:
            return 0
        if op == IR_JUMP:
            t := rc_ctl_label_node(s1)
            if t < cs || t >= ce:
                return 0
            if t == ce - 1:
                return 0
        ni = ni + 1
    return 0

fn rp_if_share_eligible(sg: int, sg_start: int, sg_count: int,
                        nstart: int, ncount: int) -> int:
    g_rp_share_consumer = -1
    g_rp_share_exit = -1
    // Same hard gates as the split/merge candidate scan.
    if rp_if_has_unsafe(sg_start, sg_count) != 0:
        return 0
    if rp_if_has_exit_or_effect(sg_start, sg_count) != 0:
        return 0
    cav0 := rp_global_var_named("g_current_arena")
    if rp_if_reads_var(sg_start, sg_count, cav0) != 0:
        return 0
    p := cell_load(g_sgs, sg * ESZ_SG + OFF_SG_PARENT)
    if p < 0 || cell_load(g_sgs, p * ESZ_SG + OFF_SG_KIND) != SG_FUNC:
        return 0
    cnt := rp_if_merge_eligible(sg, sg_start, sg_count, nstart, ncount)
    if cnt <= 0:
        return 0
    // The selected allocation and its outer slot.
    ai_sel : ., mut = -1
    ai : ., mut = 0
    loop:
        if ai >= g_pa_alloc_count:
            break
        an := cell_load(g_pa_alloc_nodes, ai * 8)
        if subgraph_containing(an) == sg:
            ai_sel = ai
        ai = ai + 1
    if ai_sel < 0:
        return 0
    an := cell_load(g_pa_alloc_nodes, ai_sel * 8)
    alloc_dest := cell_load(g_df_nodes, an * ESZ_DFNODE + OFF_DF_DEST)
    dest : ., mut = -1
    ni : ., mut = sg_start
    loop:
        if ni >= sg_start + sg_count:
            break
        op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
        s1 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)
        s2 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S2)
        if op == IR_STORE && s2 == alloc_dest:
            dest = s1
        ni = ni + 1
    if dest < 0:
        return 0
    s_end := sg_start + sg_count
    func_end := nstart + ncount
    umax : ., mut = -1
    ni = s_end
    loop:
        if ni >= func_end:
            break
        op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
        dv := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_DEST)
        s1 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)
        s2 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S2)
        s3 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S3)
        base : ., mut = -1
        value : ., mut = -1
        known : ., mut = 0
        if op == IR_LOAD_INDEX || op == IR_LOAD_INDEX_VAR:
            base = s1
            known = 1
        else if op == IR_STORE_INDEX:
            base = s1
            value = s2
            known = 1
        else if op == IR_STORE_INDEX_VAR:
            base = s1
            value = dv
            known = 1
        if known != 0:
            if value >= 0 && rp_var_may_point(value) != 0 && pa_pts_has(value, ai_sel) != 0:
                return 0
            if base >= 0 && rp_var_may_point(base) != 0 && pa_pts_has(base, ai_sel) != 0:
                if op == IR_STORE_INDEX || op == IR_STORE_INDEX_VAR:
                    return 0
                if base != dest:
                    return 0
                umax = ni
        else:
            literal_only : ., mut = 0
            if op == IR_CONST || op == IR_CONST_BIG || op == IR_LABEL || op == IR_JUMP || op == IR_ALLOC || op == IR_ALLOC_ARRAY || op == IR_ALLOC_STRUCT || op == IR_BOUNDS_CHECK:
                literal_only = 1
            if literal_only == 0:
                if op == IR_CALL || op == IR_SPAWN:
                    if rp_call_arg_uses_alloc(s1, s2, ai_sel) != 0:
                        return 0
                else if op == IR_MATCH:
                    if s1 >= 0 && rp_var_may_point(s1) != 0 && pa_pts_has(s1, ai_sel) != 0:
                        return 0
                else if op == IR_BINARY:
                    if s1 >= 0 && rp_var_may_point(s1) != 0 && pa_pts_has(s1, ai_sel) != 0:
                        return 0
                    if s2 >= 0 && rp_var_may_point(s2) != 0 && pa_pts_has(s2, ai_sel) != 0:
                        return 0
                else if op == IR_UNARY:
                    if s1 >= 0 && rp_var_may_point(s1) != 0 && pa_pts_has(s1, ai_sel) != 0:
                        return 0
                else:
                    if s1 >= 0 && rp_var_may_point(s1) != 0 && pa_pts_has(s1, ai_sel) != 0:
                        return 0
                    if s2 >= 0 && rp_var_may_point(s2) != 0 && pa_pts_has(s2, ai_sel) != 0:
                        return 0
                    if s3 >= 0 && rp_var_may_point(s3) != 0 && pa_pts_has(s3, ai_sel) != 0:
                        return 0
                    if dv >= 0 && rp_var_may_point(dv) != 0 && pa_pts_has(dv, ai_sel) != 0:
                        return 0
        ni = ni + 1
    if umax < 0:
        return 0
    // Outermost releasing consumer below the function region.
    cons : ., mut = -1
    cur : ., mut = subgraph_containing(umax)
    loop:
        if cur < 0 || cur == p:
            break
        if rc_sg_releases(cur) != 0:
            cons = cur
        cur = cell_load(g_sgs, cur * ESZ_SG + OFF_SG_PARENT)
    if cons < 0:
        return 0
    k := cell_load(g_sgs, cons * ESZ_SG + OFF_SG_KIND)
    if k != SG_LOOP && k != SG_FOR:
        return 0
    cexit := cell_load(g_sgs, cons * ESZ_SG + OFF_SG_EXIT)
    if cexit <= s_end || cexit >= func_end:
        return 0
    if umax >= cexit:
        return 0
    // Labels are stable across Phase A/B; node indices are not. Store the
    // consumer's exit label id and resolve it again in the Phase B graph.
    eln := cexit - 1
    eop := cell_load(g_df_nodes, eln * ESZ_DFNODE + OFF_DF_OPCODE)
    if eop != IR_LABEL:
        return 0
    eexit := cell_load(g_df_nodes, eln * ESZ_DFNODE + OFF_DF_S1)
    if eexit < 0:
        return 0
    if rp_share_consumer_simple(cons) == 0:
        return 0
    // Calls in the window may allocate through the current slot and may read
    // g_current_arena; this slice keeps the window call-free. Any return or
    // jump to a loop exit label can leave a nested/sibling arena current at the
    // share reset point, so those stay v1 too.
    ni = s_end
    loop:
        if ni >= cexit:
            break
        op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
        if op == IR_CALL || op == IR_SPAWN:
            return 0
        if op == IR_RETURN:
            return 0
        if op == IR_JUMP:
            t := rc_ctl_label_node(cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1))
            if t < s_end || t >= cexit:
                return 0
            d : ., mut = 0
            loop:
                if d >= g_sg_count:
                    break
                ds := cell_load(g_sgs, d * ESZ_SG + OFF_SG_NSTART)
                if ds >= s_end && ds < cexit:
                    dk := cell_load(g_sgs, d * ESZ_SG + OFF_SG_KIND)
                    if dk == SG_LOOP || dk == SG_FOR:
                        de := cell_load(g_sgs, d * ESZ_SG + OFF_SG_EXIT)
                        if t == de - 1:
                            return 0
                d = d + 1
        ni = ni + 1
    cav := rp_global_var_named("g_current_arena")
    if cav >= 0 && rp_if_reads_var(s_end, cexit - s_end, cav) != 0:
        return 0
    // Nothing allocated in the window may land in the share slot. An
    // allocation belongs to the nearest releasing ancestor whose own
    // IR_ARENA_NEW precedes it; a loop condition runs before its arena exists,
    // so those allocations land in the parent and are rejected here.
    ai = 0
    loop:
        if ai >= g_pa_alloc_count:
            break
        an2 := cell_load(g_pa_alloc_nodes, ai * 8)
        if an2 > s_end && an2 < cexit:
            cur2 : ., mut = subgraph_containing(an2)
            owned : ., mut = 0
            loop:
                if cur2 < 0 || cur2 == p:
                    break
                if rc_sg_releases(cur2) != 0:
                    an_new := rp_sg_arena_new_node(cur2)
                    if an_new >= 0 && an2 > an_new:
                        owned = 1
                        break
                cur2 = cell_load(g_sgs, cur2 * ESZ_SG + OFF_SG_PARENT)
            if owned == 0:
                return 0
        ai = ai + 1
    g_rp_share_consumer = cons
    g_rp_share_exit = eexit
    return cnt

// Materialize the V2.2 merge copy at the end of the assigning branch. The copy
// allocation was emitted before the child arena, so it lives in the parent slot.
// The child array is copied element by element and the outer slot is rebound
// before the branch jumps to the merge label; the other path keeps the old value.
fn region_plan_emit_merge(sg: int, copy_var: int, copy_instr: int,
                          range_start: int, range_end: int) -> int:
    if copy_var < 0 || copy_instr < 0:
        return 0
    an : ., mut = -1
    ni : ., mut = range_start
    loop:
        if ni >= range_end:
            break
        op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
        if op == IR_ALLOC_ARRAY && subgraph_containing(ni) == sg:
            an = ni
            break
        ni = ni + 1
    if an < 0:
        return 0
    alloc_dest := cell_load(g_df_nodes, an * ESZ_DFNODE + OFF_DF_DEST)
    at := irv_type(alloc_dest)
    if at < 0 || at >= g_type_count || get_type_kind(at) != TYP_ARRAY:
        return 0
    cnt := cell_load(g_df_nodes, an * ESZ_DFNODE + OFF_DF_S1)
    elem := get_type_data(at)
    if cnt <= 0 || cnt > 64 || rp_scalar_elem(elem) == 0:
        return 0
    dest : ., mut = -1
    ni = range_start
    loop:
        if ni >= range_end:
            break
        op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
        s1 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)
        s2 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S2)
        if op == IR_STORE && s2 == alloc_dest && s1 >= 0:
            dest = s1
            break
        ni = ni + 1
    if dest < 0:
        return 0
    // The copy allocation was emitted with the planned element count and its
    // size already charged to the parent arena; only the type row is patched.
    irv_set_type(copy_var, alloc_type(TYP_ARRAY, elem, cnt))
    i : ., mut = 0
    loop:
        if i >= cnt:
            break
        ev := new_ir_var("_merge_elem", elem)
        emit(IR_LOAD_INDEX, ev, alloc_dest, 0, i, elem)
        emit(IR_STORE_INDEX, -1, copy_var, ev, i, 0)
        i = i + 1
    emit(IR_STORE, -1, dest, copy_var, 0, 0)
    return 1

// Emit the delayed reset of a share slot after consumer SG `cg` has closed its
// own arena. The share slot is current again at this point; resetting it
// returns the runtime to the parent before the next parent allocation.
fn region_plan_emit_share_after(cg: int):
    s := region_plan_share_after(cg)
    if s < 0:
        return
    if s >= g_sg_count:
        check_error(EC_B_LIFETIME, "share reset points outside the SG table", 0, 0)
        return
    av := cell_load(g_sg_arena_var, s * 8)
    if av < 0:
        check_error(EC_B_LIFETIME, "share reset lost its slot variable", 0, 0)
        return
    emit(IR_ARENA_RESET, -1, av, 0, 0, 0)
    g_plan_share_reset_emitted = 1

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
                                else:
                                    mc := rp_if_merge_eligible(sg, sg_start, sg_count, nstart, ncount)
                                    if mc > 0:
                                        region_plan_mark_merge(sg, mc)
            sg = sg + 1
        fi = fi + 1

    // V2.3 share pass. Run after split/merge marks so the consumer's releasing
    // status and any competing merge copy are known. This slice allows at most
    // one share per program and requires the candidate's function to have no
    // other merge plan (a merge copy in the same function could land in the
    // shared slot). The candidate's own merge mark is replaced by share.
    if g_plan_share_count == 0:
        fi = 0
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
                        if region_plan_is_split(sg) == 0:
                            if rp_if_share_eligible(sg, sg_start, sg_count, nstart, ncount) != 0:
                                own : ., mut = 0
                                if region_plan_is_merge(sg) != 0:
                                    own = 1
                                mcount : ., mut = 0
                                pj : ., mut = 0
                                loop:
                                    if pj >= g_sg_count:
                                        break
                                    ps := cell_load(g_sgs, pj * ESZ_SG + OFF_SG_NSTART)
                                    if ps >= nstart && ps < nstart + ncount:
                                        if region_plan_is_merge(pj) != 0:
                                            mcount = mcount + 1
                                    pj = pj + 1
                                if mcount == own:
                                    if own != 0:
                                        region_plan_unmark_merge(sg)
                                    region_plan_mark_share(sg, g_rp_share_exit, g_rp_share_consumer)
                                    return
                sg = sg + 1
            fi = fi + 1

    // Early clear is not combined with share in this slice: the shared slot is
    // current across the consumer window, so a parent-slot clear there would be
    // out of the clear pass's model.
    if g_plan_share_count > 0:
        return

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
        rp_pdom_prepare(nstart, ncount)
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
