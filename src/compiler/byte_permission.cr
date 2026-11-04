// === byte_permission.cr ===
// BytePermission pass — verifier-side byte permissions.
//
// The classic mapping adds one permission state per byte. Core only has two
// independent bits (readable, writable); Nonempty/Empty belong to the ENT/REG
// layer, Freeable to region ownership. A state can only be lowered, never
// raised:
//
//   BP_RW = BP_READ | BP_WRITE
//
// The representation is per allocation / per slot today because no operation
// lowers a sub-range. A per-byte override table can be added without changing
// the lattice or the checks.
//
// Inference sources:
//   - string literals (IR_CONST with string type) are read-only;
//   - immutable globals are read-only (`ast_data(let) == 0`);
//   - everything allocated by Core (IR_ALLOC_ARRAY/STRUCT, alloc() buffers) is
//     read-write;
//   - unknown values default to read-write so the verifier only rejects a
//     write when every reaching definition is read-only.
//
// Checks are skipped inside `unsafe`: that is the declared graph boundary.

BP_NONE  : int = 0
BP_READ  : int = 1
BP_WRITE : int = 2
BP_RW    : int = 3

g_bp_alloc_perm : string, mut
g_bp_global_perm : string, mut
g_bp_var_perm : string, mut
g_bp_last_store : string, mut
g_bp_param_write : string, mut
g_bp_param_alias : string, mut

fn bp_meet(a: int, b: int) -> int:
    r : ., mut = 0
    if (a % 2) == 1 && (b % 2) == 1:
        r = 1
    if ((a / 2) % 2) == 1 && ((b / 2) % 2) == 1:
        r = r + 2
    return r

fn bp_can_read(state: int) -> int:
    return state % 2

fn bp_can_write(state: int) -> int:
    return (state / 2) % 2

fn bp_meet_var(var: int, state: int) -> int:
    if var < 0 || var >= g_ir_var_count:
        return 0
    cur := cell_load(g_bp_var_perm, var * 8)
    nxt := bp_meet(cur, state)
    if nxt != cur:
        cell_store(g_bp_var_perm, var * 8, nxt)
        return 1
    return 0

fn bp_type_is_string(ti: int) -> int:
    if ti < 0 || ti >= g_type_count:
        return 0
    if get_type_kind(ti) == TYP_BASE && get_type_data(ti) == TY_STRING:
        return 1
    return 0

fn bp_var_is_string(var: int) -> int:
    if var < 0:
        return 0
    return bp_type_is_string(irv_type(var))

fn bp_global_row_of_var(var: int) -> int:
    if var < 0:
        return -1
    gi : ., mut = 0
    loop:
        if gi >= g_ir_global_count:
            return -1
        if cell_load(g_ir_globals, gi * 24 + 8) == var:
            return gi
        gi = gi + 1

// Global slots are writable bytes. `mut` on a global only restricts assignment
// by name (TA06); taking `&g` yields writable storage, matching the optional
// slot rules. The table stays as the hook for future read-only regions
// (`alloc_at` with declared permissions).
fn bp_global_var_is_ro(var: int) -> int:
    row := bp_global_row_of_var(var)
    if row < 0 || row >= g_ir_global_count:
        return 0
    if g_bp_global_perm == "":
        return 0
    if cell_load(g_bp_global_perm, row * 8) == BP_READ:
        return 1
    return 0

fn bp_pts_can_read(var: int) -> int:
    if var < 0:
        return 1
    ai : ., mut = 0
    loop:
        if ai >= g_pa_alloc_count:
            return 1
        if pa_pts_has(var, ai) != 0:
            if bp_can_read(cell_load(g_bp_alloc_perm, ai * 8)) == 0:
                return 0
        ai = ai + 1
    return 1

fn bp_pts_can_write(var: int) -> int:
    if var < 0:
        return 1
    ai : ., mut = 0
    loop:
        if ai >= g_pa_alloc_count:
            return 1
        if pa_pts_has(var, ai) != 0:
            if bp_can_write(cell_load(g_bp_alloc_perm, ai * 8)) == 0:
                return 0
        ai = ai + 1
    return 1

// Every reaching definition must point at the same read-only global. A single
// writable or unknown definition keeps the write legal (must-analysis).
fn bp_pointer_is_readonly(var: int, at_node: int, lo: int, depth: int) -> int:
    if var < 0 || depth > RC_MAX_DEPTH:
        return 0
    if rc_is_global_var(var) != 0:
        return bp_global_var_is_ro(var)
    ti := irv_type(var)
    if ti < 0 || ti >= g_type_count:
        return 0
    if get_type_kind(ti) != TYP_PTR && get_type_kind(ti) != TYP_REF:
        return 0
    if rc_rd_any(var, at_node) != 0:
        base := rc_rd_collect(var, at_node, depth)
        dc := g_rc_rd_def_count
        if dc <= 0:
            return 0
        all_ro : ., mut = 1
        i : ., mut = 0
        loop:
            if i >= dc:
                if all_ro != 0:
                    return 1
                return 0
            dn := cell_load(g_rc_rd_defs, (base + i) * 8)
            op := cell_load(g_df_nodes, dn * ESZ_DFNODE + OFF_DF_OPCODE)
            d  := cell_load(g_df_nodes, dn * ESZ_DFNODE + OFF_DF_DEST)
            s1 := cell_load(g_df_nodes, dn * ESZ_DFNODE + OFF_DF_S1)
            s2 := cell_load(g_df_nodes, dn * ESZ_DFNODE + OFF_DF_S2)
            if op == IR_REF && d == var:
                ro_ref : ., mut = 0
                if s1 >= 0 && rc_is_global_var(s1) != 0 && bp_global_var_is_ro(s1) != 0:
                    ro_ref = 1
                if ro_ref == 0:
                    all_ro = 0
            else if op == IR_STORE && s1 == var:
                if s2 < 0 || bp_pointer_is_readonly(s2, dn, lo, depth + 1) == 0:
                    all_ro = 0
            else if op == IR_PHI && d == var:
                if s1 < 0 || bp_pointer_is_readonly(s1, dn, lo, depth + 1) == 0:
                    all_ro = 0
                if s2 < 0 || bp_pointer_is_readonly(s2, dn, lo, depth + 1) == 0:
                    all_ro = 0
            else if (op == IR_LAZY_THUNK || op == IR_LAZY_FORCE) && d == var:
                if s1 < 0 || bp_pointer_is_readonly(s1, dn, lo, depth + 1) == 0:
                    all_ro = 0
            else:
                all_ro = 0
            i = i + 1
        return 0
    prod := cell_load(g_df_var_producer, var * 8)
    if prod < 0:
        return 0
    op := cell_load(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_OPCODE)
    s1 := cell_load(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_S1)
    if op == IR_REF && s1 >= 0:
        if rc_is_global_var(s1) != 0 && bp_global_var_is_ro(s1) != 0:
            return 1
        return 0
    if (op == IR_LAZY_THUNK || op == IR_LAZY_FORCE) && s1 >= 0:
        return bp_pointer_is_readonly(s1, prod, lo, depth + 1)
    return 0

fn bp_reset_last_store(vstart: int, vcount: int):
    vi : ., mut = vstart
    loop:
        if vi >= vstart + vcount:
            return
        if vi >= 0 && vi < g_ir_var_count:
            cell_store(g_bp_last_store, vi * 8, -1)
        vi = vi + 1

fn bp_init_var_range(vstart: int, vcount: int):
    vi : ., mut = vstart
    loop:
        if vi >= vstart + vcount:
            return
        if vi >= 0 && vi < g_ir_var_count && rc_is_global_var(vi) == 0:
            cell_store(g_bp_var_perm, vi * 8, BP_RW)
        vi = vi + 1

fn bp_note_def(ni: int, op: int, d: int, s1: int):
    if op == IR_STORE && s1 >= 0 && s1 < g_ir_var_count:
        cell_store(g_bp_last_store, s1 * 8, ni)
    if d >= 0 && d < g_ir_var_count:
        cell_store(g_bp_last_store, d * 8, ni)

// Resolve the immediate source value stored into a call-argument temp. `_arg`
// variables are reused per call, so their own permission is not trusted; the
// store that prepared this call names the real value.
fn bp_arg_value(arg: int, at_node: int, lo: int, depth: int) -> int:
    if arg < 0 || depth > RC_MAX_DEPTH:
        return arg
    si := cell_load(g_bp_last_store, arg * 8)
    if si >= 0 && si < at_node:
        op := cell_load(g_df_nodes, si * ESZ_DFNODE + OFF_DF_OPCODE)
        s1 := cell_load(g_df_nodes, si * ESZ_DFNODE + OFF_DF_S1)
        s2 := cell_load(g_df_nodes, si * ESZ_DFNODE + OFF_DF_S2)
        if op == IR_STORE && s1 == arg && s2 >= 0:
            return bp_arg_value(s2, si, lo, depth + 1)
    prod := cell_load(g_df_var_producer, arg * 8)
    if prod >= 0:
        op := cell_load(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_OPCODE)
        s1 := cell_load(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_S1)
        s2 := cell_load(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_S2)
        if op == IR_STORE && s1 == arg && s2 >= 0:
            return bp_arg_value(s2, prod, lo, depth + 1)
    return arg

fn bp_def_state(def_node: int, var: int, depth: int) -> int:
    if depth > RC_MAX_DEPTH:
        return BP_RW
    op := cell_load(g_df_nodes, def_node * ESZ_DFNODE + OFF_DF_OPCODE)
    d  := cell_load(g_df_nodes, def_node * ESZ_DFNODE + OFF_DF_DEST)
    s1 := cell_load(g_df_nodes, def_node * ESZ_DFNODE + OFF_DF_S1)
    s2 := cell_load(g_df_nodes, def_node * ESZ_DFNODE + OFF_DF_S2)
    s3 := cell_load(g_df_nodes, def_node * ESZ_DFNODE + OFF_DF_S3)
    if op == IR_CONST && d == var && bp_var_is_string(var) != 0:
        return BP_READ
    if op == IR_STORE && s1 == var:
        if s2 >= 0:
            return bp_value_state_at(s2, def_node, depth + 1)
        return BP_RW
    if op == IR_PHI && d == var:
        st : ., mut = BP_RW
        if s1 >= 0:
            st = bp_value_state_at(s1, def_node, depth + 1)
        if s2 >= 0:
            st = bp_meet(st, bp_value_state_at(s2, def_node, depth + 1))
        return st
    if (op == IR_LAZY_THUNK || op == IR_LAZY_FORCE) && d == var:
        if s1 >= 0:
            return bp_value_state_at(s1, def_node, depth + 1)
        return BP_RW
    if op == IR_CALL && d == var:
        if bp_is_builtin_name(s3, "alloc") != 0:
            return BP_RW
        callee := rc_func_by_name(s3)
        if callee >= 0:
            pc := cell_load(g_ir_func_param_count, callee * 8)
            st2 : ., mut = BP_RW
            seen : ., mut = 0
            j : ., mut = 0
            loop:
                if j >= pc || j >= s2 || j >= 64:
                    break
                if rc_mask_has(g_rc_ret_alias, callee * 2, j) != 0:
                    arg := s1 + j
                    if arg >= 0:
                        a := bp_value_state_at(arg, def_node, depth + 1)
                        if seen == 0:
                            st2 = a
                            seen = 1
                        else:
                            st2 = bp_meet(st2, a)
                j = j + 1
            if seen != 0:
                return st2
        return BP_RW
    return BP_RW

// Permission of the value that actually reaches `at_node`. Uses reaching
// definitions so a mutable global reassigned to a writable buffer is not
// rejected because its initializer was a literal.
fn bp_value_state_at(var: int, at_node: int, depth: int) -> int:
    if var < 0 || var >= g_ir_var_count || depth > RC_MAX_DEPTH:
        return BP_RW
    if rc_rd_any(var, at_node) != 0:
        base := rc_rd_collect(var, at_node, depth)
        dc := g_rc_rd_def_count
        if dc > 0:
            st : ., mut = BP_RW
            i : ., mut = 0
            loop:
                if i >= dc:
                    return st
                dn := cell_load(g_rc_rd_defs, (base + i) * 8)
                ds := bp_def_state(dn, var, depth + 1)
                if i == 0:
                    st = ds
                else:
                    st = bp_meet(st, ds)
                i = i + 1
            return st
    prod := cell_load(g_df_var_producer, var * 8)
    if prod >= 0:
        return bp_def_state(prod, var, depth + 1)
    return bp_value_perm(var)

fn bp_arg_state(arg: int, at_node: int, lo: int, depth: int) -> int:
    val := bp_arg_value(arg, at_node, lo, 0)
    return bp_value_state_at(val, at_node, depth)

fn bp_value_perm(var: int) -> int:
    if var < 0 || var >= g_ir_var_count:
        return BP_RW
    return cell_load(g_bp_var_perm, var * 8)

fn bp_is_builtin_name(s3: int, name: string) -> int:
    if s3 < 0:
        return 0
    // A user-defined function with the same name has a body; its own body is
    // checked instead of treating the call as the runtime builtin.
    if rc_func_by_name(s3) >= 0:
        return 0
    if str_eq(istr_get(s3), name) != 0:
        return 1
    return 0

fn bp_is_write_builtin(s3: int) -> int:
    if bp_is_builtin_name(s3, "cell_store") != 0:
        return 1
    if bp_is_builtin_name(s3, "store8") != 0:
        return 1
    return 0

fn bp_is_read_builtin(s3: int) -> int:
    if bp_is_builtin_name(s3, "cell_load") != 0:
        return 1
    if bp_is_builtin_name(s3, "load8") != 0:
        return 1
    if bp_is_builtin_name(s3, "str_len") != 0:
        return 1
    return 0

// Infer string permissions for one function. Permissions only decrease, so a
// small fixed point over the linear node list reaches the meet of all reaching
// definitions; loops need no special case.
fn bp_infer_strings(nstart: int, ncount: int, vstart: int, vcount: int):
    changed : ., mut = 1
    rounds : ., mut = 0
    loop:
        if changed == 0 || rounds > RC_MAX_DEPTH:
            return
        changed = 0
        rounds = rounds + 1
        ni : ., mut = nstart
        loop:
            if ni >= nstart + ncount:
                break
            op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
            d  := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_DEST)
            s1 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)
            s2 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S2)
            s3 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S3)
            if op == IR_CONST && d >= 0 && bp_var_is_string(d) != 0:
                if bp_meet_var(d, BP_READ) != 0:
                    changed = 1
            if op == IR_STORE && s1 >= 0 && s2 >= 0:
                if s1 < g_ir_var_count && s2 < g_ir_var_count && bp_var_is_string(s1) != 0:
                    if bp_meet_var(s1, bp_value_perm(s2)) != 0:
                        changed = 1
            if op == IR_PHI && d >= 0 && bp_var_is_string(d) != 0:
                if s1 >= 0 && bp_meet_var(d, bp_value_perm(s1)) != 0:
                    changed = 1
                if s2 >= 0 && bp_meet_var(d, bp_value_perm(s2)) != 0:
                    changed = 1
            if (op == IR_LAZY_THUNK || op == IR_LAZY_FORCE) && d >= 0 && s1 >= 0:
                if bp_var_is_string(d) != 0 && bp_meet_var(d, bp_value_perm(s1)) != 0:
                    changed = 1
            if op == IR_CALL && d >= 0:
                callee := rc_func_by_name(s3)
                if callee >= 0:
                    pc := cell_load(g_ir_func_param_count, callee * 8)
                    j : ., mut = 0
                    loop:
                        if j >= pc || j >= s2 || j >= 64:
                            break
                        if rc_mask_has(g_rc_ret_alias, callee * 2, j) != 0:
                            arg := s1 + j
                            if arg >= 0 && bp_meet_var(d, bp_value_perm(arg)) != 0:
                                changed = 1
                        j = j + 1
            ni = ni + 1
    return

// Parameter aliases for the byte-write summary (copies, phis, lazy wrappers,
// and call results that return a parameter).
fn bp_alias_compute(fi: int):
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
            cell_store(g_bp_param_alias, vi * 2 * 8, 0)
            cell_store(g_bp_param_alias, (vi * 2 + 1) * 8, 0)
        vi = vi + 1
    j : ., mut = 0
    loop:
        if j >= pc || j >= 64:
            break
        pv := vstart + j
        if pv >= 0 && pv < g_ir_var_count:
            rc_mask_set(g_bp_param_alias, pv * 2, j)
        j = j + 1
    changed : ., mut = 1
    loop:
        if changed == 0:
            return
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
            if op == IR_STORE && s1 >= 0 && s2 >= 0:
                if s1 < g_ir_var_count && s2 < g_ir_var_count:
                    if rc_mask_or(g_bp_param_alias, s1 * 2, s2 * 2) != 0:
                        changed = 1
            if op == IR_PHI && d >= 0 && d < g_ir_var_count:
                if s1 >= 0 && s1 < g_ir_var_count:
                    if rc_mask_or(g_bp_param_alias, d * 2, s1 * 2) != 0:
                        changed = 1
                if s2 >= 0 && s2 < g_ir_var_count:
                    if rc_mask_or(g_bp_param_alias, d * 2, s2 * 2) != 0:
                        changed = 1
            if (op == IR_LAZY_THUNK || op == IR_LAZY_FORCE) && d >= 0 && s1 >= 0:
                if d < g_ir_var_count && s1 < g_ir_var_count:
                    if rc_mask_or(g_bp_param_alias, d * 2, s1 * 2) != 0:
                        changed = 1
            if op == IR_CALL && d >= 0 && d < g_ir_var_count && s2 > 0:
                callee := rc_func_by_name(s3)
                if callee >= 0:
                    cpc := cell_load(g_ir_func_param_count, callee * 8)
                    jj : ., mut = 0
                    loop:
                        if jj >= cpc || jj >= s2 || jj >= 64:
                            break
                        if rc_mask_has(g_rc_ret_alias, callee * 2, jj) != 0:
                            arg := s1 + jj
                            if arg >= 0 && arg < g_ir_var_count:
                                if rc_mask_or(g_bp_param_alias, d * 2, arg * 2) != 0:
                                    changed = 1
                        jj = jj + 1
            ni = ni + 1

fn bp_summary_func(fi: int) -> int:
    pc := cell_load(g_ir_func_param_count, fi * 8)
    if pc <= 0:
        return 0
    nstart := cell_load(g_df_func_node_start, fi * 8)
    ncount := cell_load(g_df_func_node_count, fi * 8)
    vstart := cell_load(g_ir_func_var_start, fi * 8)
    vcount := cell_load(g_ir_func_var_count, fi * 8)
    rc_ctl_prepare(nstart, ncount)
    bp_reset_last_store(vstart, vcount)
    old0 := cell_load(g_bp_param_write, fi * 2 * 8)
    old1 := cell_load(g_bp_param_write, (fi * 2 + 1) * 8)
    out := alloc(16)
    cell_store(out, 0, 0)
    cell_store(out, 8, 0)
    ni : ., mut = nstart
    loop:
        if ni >= nstart + ncount:
            break
        op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
        d  := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_DEST)
        s1 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)
        s2 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S2)
        s3 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S3)
        bp_note_def(ni, op, d, s1)
        if is_in_unsafe(ni) != 0:
            ni = ni + 1
            continue
        if op == IR_CALL:
            if bp_is_write_builtin(s3) != 0:
                val := bp_arg_value(s1, ni, nstart, 0)
                if val >= 0 && val < g_ir_var_count:
                    rc_mask_or_from(out, 0, g_bp_param_alias, val * 2)
            else:
                callee := rc_func_by_name(s3)
                if callee >= 0:
                    cpc := cell_load(g_ir_func_param_count, callee * 8)
                    j : ., mut = 0
                    loop:
                        if j >= cpc || j >= s2 || j >= 64:
                            break
                        if rc_mask_has(g_bp_param_write, callee * 2, j) != 0:
                            arg := s1 + j
                            val := bp_arg_value(arg, ni, nstart, 0)
                            if val >= 0 && val < g_ir_var_count:
                                rc_mask_or_from(out, 0, g_bp_param_alias, val * 2)
                        j = j + 1
        ni = ni + 1
    new0 := cell_load(out, 0)
    new1 := cell_load(out, 8)
    if new0 == old0 && new1 == old1:
        return 0
    cell_store(g_bp_param_write, fi * 2 * 8, new0)
    cell_store(g_bp_param_write, (fi * 2 + 1) * 8, new1)
    return 1

fn bp_check_call(ni: int, first_arg: int, argc: int, fn_ni: int,
                 nstart: int, fi: int):
    callee := rc_func_by_name(fn_ni)
    if callee < 0:
        return
    pc := cell_load(g_ir_func_param_count, callee * 8)
    j : ., mut = 0
    loop:
        if j >= pc || j >= argc || j >= 64:
            return
        if rc_mask_has(g_bp_param_write, callee * 2, j) != 0:
            arg := first_arg + j
            if bp_can_write(bp_arg_state(arg, ni, nstart, 0)) == 0:
                check_error(EC_B_PERMISSION,
                    "byte permission: read-only string passed to a writing parameter",
                    0, 0)
        j = j + 1

fn bp_check_func(nstart: int, ncount: int, vstart: int, vcount: int, fi: int):
    rc_ctl_prepare(nstart, ncount)
    bp_reset_last_store(vstart, vcount)
    ni : ., mut = nstart
    loop:
        if ni >= nstart + ncount:
            break
        op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
        d  := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_DEST)
        s1 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)
        s2 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S2)
        s3 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S3)
        bp_note_def(ni, op, d, s1)
        if is_in_unsafe(ni) != 0:
            ni = ni + 1
            continue

        if op == IR_DEREF && s1 >= 0:
            if bp_pts_can_read(s1) == 0:
                check_error(EC_B_PERMISSION,
                    "byte permission: read from a write-only allocation",
                    0, 0)

        if op == IR_STORE_PTR && s1 >= 0:
            if bp_pointer_is_readonly(s1, ni, nstart, 0) != 0:
                check_error(EC_B_PERMISSION,
                    "byte permission: write through a read-only pointer",
                    0, 0)
            else if bp_pts_can_write(s1) == 0:
                check_error(EC_B_PERMISSION,
                    "byte permission: write to a read-only allocation",
                    0, 0)

        if op == IR_STORE_INDEX && s1 >= 0:
            if bp_pointer_is_readonly(s1, ni, nstart, 0) != 0:
                check_error(EC_B_PERMISSION,
                    "byte permission: write through a read-only object",
                    0, 0)
            else if bp_pts_can_write(s1) == 0:
                check_error(EC_B_PERMISSION,
                    "byte permission: write to a read-only allocation",
                    0, 0)
        if op == IR_STORE_INDEX_VAR && s1 >= 0:
            if bp_pointer_is_readonly(s1, ni, nstart, 0) != 0:
                check_error(EC_B_PERMISSION,
                    "byte permission: write through a read-only object",
                    0, 0)
            else if bp_pts_can_write(s1) == 0:
                check_error(EC_B_PERMISSION,
                    "byte permission: write to a read-only allocation",
                    0, 0)
        if op == IR_STORE_FIELD && s1 >= 0:
            if bp_pointer_is_readonly(s1, ni, nstart, 0) != 0:
                check_error(EC_B_PERMISSION,
                    "byte permission: write through a read-only object",
                    0, 0)
            else if bp_pts_can_write(s1) == 0:
                check_error(EC_B_PERMISSION,
                    "byte permission: write to a read-only allocation",
                    0, 0)

        if op == IR_CALL:
            if bp_is_write_builtin(s3) != 0:
                if bp_can_write(bp_arg_state(s1, ni, nstart, 0)) == 0:
                    check_error(EC_B_PERMISSION,
                        "byte permission: write to a read-only string",
                        0, 0)
            else if bp_is_read_builtin(s3) != 0:
                if bp_can_read(bp_arg_state(s1, ni, nstart, 0)) == 0:
                    check_error(EC_B_PERMISSION,
                        "byte permission: read from a write-only string",
                        0, 0)
            else:
                bp_check_call(ni, s1, s2, s3, nstart, fi)

        ni = ni + 1

fn byte_permission_all():
    if g_pa_alloc_count > 0:
        g_bp_alloc_perm = alloc(g_pa_alloc_count * 8)
    else:
        g_bp_alloc_perm = ""
    if g_ir_global_count > 0:
        g_bp_global_perm = alloc(g_ir_global_count * 8)
    else:
        g_bp_global_perm = ""
    if g_ir_var_count > 0:
        g_bp_var_perm = alloc(g_ir_var_count * 8)
        g_bp_last_store = alloc(g_ir_var_count * 8)
        g_bp_param_alias = alloc(g_ir_var_count * 2 * 8)
    else:
        g_bp_var_perm = ""
        g_bp_last_store = ""
        g_bp_param_alias = ""
    if g_ir_func_count > 0:
        g_bp_param_write = alloc(g_ir_func_count * 2 * 8)
    else:
        g_bp_param_write = ""

    ai : ., mut = 0
    loop:
        if ai >= g_pa_alloc_count:
            break
        cell_store(g_bp_alloc_perm, ai * 8, BP_RW)
        ai = ai + 1

    gi : ., mut = 0
    loop:
        if gi >= g_ir_global_count:
            break
        cell_store(g_bp_global_perm, gi * 8, BP_RW)
        gi = gi + 1

    vi : ., mut = 0
    loop:
        if vi >= g_ir_var_count:
            break
        // Immutable string globals were lowered to BP_READ above; everything
        // else starts read-write. Uninitialized cells must never be mistaken
        // for a lowered state.
        cur := cell_load(g_bp_var_perm, vi * 8)
        if rc_is_global_var(vi) == 0 || cur != BP_READ:
            cell_store(g_bp_var_perm, vi * 8, BP_RW)
        cell_store(g_bp_last_store, vi * 8, -1)
        cell_store(g_bp_param_alias, vi * 2 * 8, 0)
        cell_store(g_bp_param_alias, (vi * 2 + 1) * 8, 0)
        vi = vi + 1

    fi : ., mut = 0
    loop:
        if fi >= g_ir_func_count:
            break
        cell_store(g_bp_param_write, fi * 2 * 8, 0)
        cell_store(g_bp_param_write, (fi * 2 + 1) * 8, 0)
        fi = fi + 1

    fi = 0
    loop:
        if fi >= g_ir_func_count:
            break
        nstart := cell_load(g_df_func_node_start, fi * 8)
        ncount := cell_load(g_df_func_node_count, fi * 8)
        vstart := cell_load(g_ir_func_var_start, fi * 8)
        vcount := cell_load(g_ir_func_var_count, fi * 8)
        rc_ctl_prepare(nstart, ncount)
        bp_init_var_range(vstart, vcount)
        bp_infer_strings(nstart, ncount, vstart, vcount)
        bp_alias_compute(fi)
        fi = fi + 1

    changed : ., mut = 1
    rounds : ., mut = 0
    loop:
        if changed == 0 || rounds > RC_MAX_DEPTH:
            break
        changed = 0
        rounds = rounds + 1
        fi = 0
        loop:
            if fi >= g_ir_func_count:
                break
            if bp_summary_func(fi) != 0:
                changed = 1
            fi = fi + 1

    fi = 0
    loop:
        if fi >= g_ir_func_count:
            break
        nstart := cell_load(g_df_func_node_start, fi * 8)
        ncount := cell_load(g_df_func_node_count, fi * 8)
        vstart := cell_load(g_ir_func_var_start, fi * 8)
        vcount := cell_load(g_ir_func_var_count, fi * 8)
        bp_check_func(nstart, ncount, vstart, vcount, fi)
        fi = fi + 1
