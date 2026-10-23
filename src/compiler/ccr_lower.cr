// === ccr_lower.cr ===
// HDFG linear schedule lowering. This is the only frontend step that turns
// graph nodes into the linear instruction stream stored in .ccr.

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
        iri_set_op(idx, r64(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE))
        iri_set_dest(idx, r64(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_DEST))
        iri_set_s1(idx, r64(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1))
        iri_set_s2(idx, r64(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S2))
        iri_set_s3(idx, r64(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S3))
        // iri_tk is the derived code, not the stored slot value. The node slot
        // holds a type-term reference; sh_dfn_code_of_slots combines it with the
        // auxiliary code. The derived code preserves the previous mixed code.
        iri_set_tk(idx, sh_dfn_code_of_slots(
                r64(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_TK),
                r64(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_AUX)))
        g_ir_instr_count = idx + 1
        ni = ni + 1

    // Rebuilt g_ir_instrs means g_ir_func_instr_start/count are stale.
    // Node i -> instruction i, so df boundaries = ir boundaries.
    fi : ., mut = 0
    loop:
        if fi >= g_ir_func_count:
            break
        w64(g_ir_func_instr_start, fi * 8,
            r64(g_df_func_node_start, fi * 8))
        w64(g_ir_func_instr_count, fi * 8,
            r64(g_df_func_node_count, fi * 8))
        fi = fi + 1

    // After lowering, compute per-variable usage counts for optimization passes
    compute_usage_counts()

    // Register allocation lives in the backend. The .ccr ENT section is empty
    // in this path; corearch computes live ranges and entries after loading the
    // NOD stream.
