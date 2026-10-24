// === ccr_lower.cr ===
// HDFG linear schedule lowering. This is the only frontend step that turns
// graph nodes into the linear instruction stream stored in .ccr, and the only
// producer of the wire CASE table.

// ── wire CASE helpers ────────────────────────────────────────────────────
// The wire table is a flat 24B-row buffer. ccr_lower derives it from the
// semantic model (g_lat_case); rows keep the wire layout named by CCR_CASE_*.
fn grow_ccr_case(needed: int):
    if needed < g_ccr_case_cap:
        return
    nc : ., mut = g_ccr_case_cap * 2
    if nc < 16:
        nc = 16
    if nc < needed:
        nc = needed + 16
    nb := alloc(nc * CCR_V10_CASE_DISK)
    cell_copy(g_ccr_case, g_ccr_case_cap * CCR_V10_CASE_DISK, nb)
    g_ccr_case = nb
    g_ccr_case_cap = nc

fn ccr_case_append(value: int, kind: int, str_index: int, target: int, flags: int) -> int:
    idx := g_ccr_case_count
    grow_ccr_case(idx + 1)
    base := idx * CCR_V10_CASE_DISK
    cell_store(g_ccr_case, base + CCR_CASE_VALUE, value)
    cell_store32(g_ccr_case, base + CCR_CASE_KIND, kind)
    cell_store32(g_ccr_case, base + CCR_CASE_STR, str_index)
    cell_store32(g_ccr_case, base + CCR_CASE_TARGET, target)
    cell_store32(g_ccr_case, base + CCR_CASE_FLAGS, flags)
    g_ccr_case_count = idx + 1
    return idx

fn lower_to_ccr():
    // The graph was built in parallel with linear IR during emit().
    // For now: clear and rebuild g_ir_instrs from graph nodes.
    // Since nodes are in creation order (AST walk order), sequential
    // walk is already a valid topological schedule.
    g_ir_instr_count = 0

    ni : ., mut = 0
    loop:
        if ni >= g_df_node_count:
            break
        idx := g_ir_instr_count
        grow_ir_instrs(idx + 1)
        iri_set_op(idx, cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE))
        iri_set_dest(idx, cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_DEST))
        iri_set_s1(idx, cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1))
        iri_set_s2(idx, cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S2))
        iri_set_s3(idx, cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S3))
        // iri_tk is the derived code, not the stored slot value. The node slot
        // holds a type-term reference; sh_dfn_code_of_slots combines it with the
        // auxiliary code. The derived code preserves the previous mixed code.
        iri_set_tk(idx, sh_dfn_code_of_slots(
                cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_TK),
                cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_AUX)))
        g_ir_instr_count = idx + 1
        ni = ni + 1

    // Rebuilt g_ir_instrs means g_ir_func_instr_start/count are stale.
    // Node i -> instruction i, so df boundaries = ir boundaries.
    fi : ., mut = 0
    loop:
        if fi >= g_ir_func_count:
            break
        cell_store(g_ir_func_instr_start, fi * 8,
            cell_load(g_df_func_node_start, fi * 8))
        cell_store(g_ir_func_instr_count, fi * 8,
            cell_load(g_df_func_node_count, fi * 8))
        fi = fi + 1

    // Derive the wire CASE table from the semantic model. The model stores body
    // label numbers; resolve each target against the IR_LABEL nodes of the same
    // function. Matches are visited in instruction order, so the wire rows keep
    // the model's reservation order. An unresolved label stays -1 and the
    // .ccr loader/saver rejects the malformed wire row. Only this function
    // writes g_ccr_case.
    g_ccr_case_count = 0

    fi = 0
    loop:
        if fi >= g_ir_func_count:
            break
        f_nstart := cell_load(g_df_func_node_start, fi * 8)
        f_ncount := cell_load(g_df_func_node_count, fi * 8)
        f_nend := f_nstart + f_ncount

        lbl_n : ., mut = 0
        ni = f_nstart
        loop:
            if ni >= f_nend:
                break
            if cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE) == IR_LABEL:
                lbl_n = lbl_n + 1
            ni = ni + 1

        lbl_id : string, mut = ""
        lbl_nod : string, mut = ""
        if lbl_n > 0:
            lbl_id = alloc(lbl_n * 8)
            lbl_nod = alloc(lbl_n * 8)
        li : ., mut = 0
        ni = f_nstart
        loop:
            if ni >= f_nend:
                break
            if cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE) == IR_LABEL:
                cell_store(lbl_id, li * 8,
                    cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1))
                cell_store(lbl_nod, li * 8, ni)
                li = li + 1
            ni = ni + 1

        istart := cell_load(g_ir_func_instr_start, fi * 8)
        icount := cell_load(g_ir_func_instr_count, fi * 8)
        ii : ., mut = 0
        loop:
            if ii >= icount:
                break
            inst := istart + ii
            if iri_op(inst) == IR_MATCH:
                ms := iri_s2(inst)
                mn := iri_s3(inst)
                if ms >= 0 && mn >= 0 && ms + mn <= g_lat_case_count:
                    wire_start := g_ccr_case_count
                    rj : ., mut = 0
                    loop:
                        if rj >= mn:
                            break
                        cbase := (ms + rj) * CCR_V10_CASE_DISK
                        cval := cell_load(g_lat_case, cbase + CCR_CASE_VALUE)
                        ckind := cell_load32(g_lat_case, cbase + CCR_CASE_KIND)
                        csidx := cell_load_i32(g_lat_case, cbase + CCR_CASE_STR)
                        cflags := cell_load32(g_lat_case, cbase + CCR_CASE_FLAGS)
                        clabel := cell_load_i32(g_lat_case, cbase + CCR_CASE_TARGET)
                        cnod : ., mut = -1
                        if clabel >= 0:
                            lj : ., mut = 0
                            loop:
                                if lj >= lbl_n:
                                    break
                                if cell_load(lbl_id, lj * 8) == clabel:
                                    cnod = cell_load(lbl_nod, lj * 8)
                                    break
                                lj = lj + 1
                        ccr_case_append(cval, ckind, csidx, cnod, cflags)
                        rj = rj + 1
                    // IR_MATCH s2/s3 become the derived wire range. The NOD
                    // mirror is rebuilt into g_ir_instrs above, but downstream
                    // readers (interp) also consume it, so keep both in sync.
                    iri_set_s2(inst, wire_start)
                    iri_set_s3(inst, mn)
                    cell_store(g_df_nodes, inst * ESZ_DFNODE + OFF_DF_S2, wire_start)
                    cell_store(g_df_nodes, inst * ESZ_DFNODE + OFF_DF_S3, mn)
            ii = ii + 1
        fi = fi + 1

    // After lowering, compute per-variable usage counts for optimization passes
    compute_usage_counts()

    // Register allocation lives in the backend. The .ccr ENT section is empty
    // in this path; corearch computes live ranges and entries after loading the
    // NOD stream.
