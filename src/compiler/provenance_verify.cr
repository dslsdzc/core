// === provenance_verify.cr ===
// ProvenanceVerify pass — checks the DEREF/STORE_PTR element interval against
// the allocation extent. Runs after PointerAnalysis (ptr_analysis.cr) and
// RegionCheck (region_check.cr). Detects out-of-bounds pointer accesses at
// compile time.
//
// Units are IR cells (element indices), never target bytes. PointerAnalysis
// stores element offsets and this pass derives the allocation extent from the
// ALLOC node's semantic count. corearch computes the matching byte extent from
// the same node plus the target layout, so this decision is target-independent.

// Semantic extent of an allocation in IR cells.
// -1 = unknown; leave the check to run time. Never approximate unknown as 0.
fn get_alloc_extent(alloc_seq: int) -> int:
    // alloc_seq is a pts allocation bit, not a DF node index. Map it through
    // g_pa_alloc_nodes before reading the allocation node.
    if alloc_seq < 0 || alloc_seq >= g_pa_alloc_count:
        return -1
    an := cell_load(g_pa_alloc_nodes, alloc_seq * 8)
    op := cell_load(g_df_nodes, an * ESZ_DFNODE + OFF_DF_OPCODE)
    s1 := cell_load(g_df_nodes, an * ESZ_DFNODE + OFF_DF_S1)
    s3 := cell_load(g_df_nodes, an * ESZ_DFNODE + OFF_DF_S3)

    // IR_ALLOC marks a scalar variable slot, not a heap allocation, so it has no
    // allocation extent.
    if op == IR_ALLOC_ARRAY:
        // s1 is the semantic element count; one element occupies one IR cell.
        return s1
    if op == IR_ALLOC_STRUCT:
        // Field count is the struct's cell extent. An unknown struct name falls
        // back to a single cell, matching the scalar placeholder in the IR.
        fi : int, mut = -1
        si2 : ., mut = 0
        loop:
            if si2 >= g_struct_count:
                break
            if si_name(si2) == s3:
                fi = si2
                break
            si2 = si2 + 1
        if fi >= 0:
            return si_field_count(fi)
        return 1
    return -1  // unknown; leave the check to run time

// Semantic cell span of one value of type `ti`. Arrays and tuples are
// contiguous element sequences, structs cover their fields, a slice view is a
// (data, len) pair, and every scalar occupies one cell. This is the IR value
// model, not a target byte size.
// -1 = the type row is unavailable (negative or outside the loaded TYPE table,
// e.g. a warm cache that does not carry it). Unknown must stay unknown so the
// caller keeps the runtime bounds check instead of assuming one cell.
fn pv_value_span(ti: int) -> int:
    if ti < 0 || ti >= g_type_count:
        return -1
    k := get_type_kind(ti)
    if k == TYP_ARRAY:
        elem := pv_value_span(get_type_data(ti))
        if elem < 0:
            return -1
        cnt := get_type_extra(ti)
        if cnt <= 0:
            return 1
        return elem * cnt
    if k == TYP_NAMED:
        name_ni := get_type_data(ti)
        si : ., mut = 0
        loop:
            if si >= g_struct_count:
                break
            if si_name(si) == name_ni:
                fc := si_field_count(si)
                if fc > 0:
                    return fc
                return 1
            si = si + 1
        return 1
    if k == TYP_TUPLE:
        n := get_type_data(ti)
        if n > 0:
            return n
        return 1
    if k == TYP_SLICE:
        return 2
    return 1

// Cell span of the value a dereference reads or writes, derived from the
// pointer's pointee type. The frontend no longer stores an access width code.
// -1 = unknown: the pointer variable has no usable type row (negative or
// outside the loaded TYPE table) or its pointee row is unavailable. Callers
// then fall back to the runtime bounds check (fail closed, never widen).
fn pv_access_span(ptr_var: int) -> int:
    ti := irv_type(ptr_var)
    if ti < 0 || ti >= g_type_count:
        return -1
    k := get_type_kind(ti)
    if k == TYP_PTR || k == TYP_REF:
        return pv_value_span(get_type_data(ti))
    return 1

fn get_alloc_var(alloc_seq: int) -> int:
    if alloc_seq < 0 || alloc_seq >= g_pa_alloc_count:
        return -1
    an := cell_load(g_pa_alloc_nodes, alloc_seq * 8)
    return cell_load(g_df_nodes, an * ESZ_DFNODE + OFF_DF_DEST)

fn pv_is_in_unsafe(node_seq: int) -> int:
    si : ., mut = 0
    loop:
        if si >= g_sg_count:
            break
        kind := cell_load(g_sgs, si * ESZ_SG + OFF_SG_KIND)
        if kind == SG_UNSAFE:
            nstart := cell_load(g_sgs, si * ESZ_SG + OFF_SG_NSTART)
            ncount := cell_load(g_sgs, si * ESZ_SG + OFF_SG_NCOUNT)
            if node_seq >= nstart && node_seq < nstart + ncount:
                return 1
        si = si + 1
    return 0

fn provenance_verify_func(nstart: int, ncount: int):
    ni : ., mut = nstart
    loop:
        if ni >= nstart + ncount:
            break
        op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
        s1 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)

        if (op == IR_DEREF || op == IR_STORE_PTR) && s1 >= 0:
            // Skip checks in unsafe blocks
            if pv_is_in_unsafe(ni) != 0:
                ni = ni + 1
                continue

            // Access span in IR cells, from the pointee semantic type. -1 means
            // the type row is unavailable: keep the runtime bounds check.
            span := pv_access_span(s1)

            ptr_ti := irv_type(s1)
            // This check applies only to TYP_PTR values with a non-zero extra field,
            // which marks an external address space. It does not apply to TYP_REF:
            // REF extra is the mut flag, so treating it as an address space would
            // reject every &mut dereference. The four EC_TU_DEREF cases in
            // tests/selfhost/test_pointer_safety.py all use `as *T` casts; none use
            // `&x`. Extending the check to REF would create false positives.
            if ptr_ti >= 0 && get_type_kind(ptr_ti) == TYP_PTR && get_type_extra(ptr_ti) != 0:
                check_error(EC_TU_DEREF,
                    "external pointer dereference requires unsafe",
                    0, 0)
                ni = ni + 1
                continue

            off := cell_load(g_offsets, s1 * 8)
            runtime_targets : ., mut = 0
            runtime_size : ., mut = 0
            runtime_base : ., mut = -1

            // Check each potential allocation target in the points-to set
            bi : ., mut = 0
            loop:
                if bi >= g_pa_alloc_count:
                    break
                if pa_pts_has(s1, bi) != 0:
                    alloc_extent := get_alloc_extent(bi)
                    if alloc_extent >= 0 && off >= 0 && span > 0:
                        if span > alloc_extent || off > alloc_extent - span:
                            check_error(EC_TK_INDEX,
                                "pointer out of bounds: index " + int_str(off) +
                                " + span " + int_str(span) +
                                " > extent " + int_str(alloc_extent) +
                                " (IR cells)",
                                0, 0)
                    else if alloc_extent >= 0:
                        if span > 0 && span > alloc_extent:
                            check_error(EC_TK_INDEX,
                                "pointer access span " + int_str(span) +
                                " exceeds allocation extent " + int_str(alloc_extent) +
                                " (IR cells)",
                                0, 0)
                        else:
                            runtime_targets = runtime_targets + 1
                            runtime_size = alloc_extent
                            runtime_base = get_alloc_var(bi)
                        // Unknown allocation information leaves s2 and s3 unset. The
                        // encoder keeps a null trap for s3 = 0.

                bi = bi + 1

            // A constant offset plus a known span can be proven statically. A
            // dynamic offset (off < 0) or an unknown span (span <= 0: missing or
            // out-of-range type row, e.g. a warm cache without it) cannot. Both
            // must keep the runtime bound, otherwise the backend would emit only
            // a null check and the access would be fail-open. `span` is never 0
            // from pv_value_span/pv_access_span; treating 0 as unknown is
            // intentionally conservative.
            needs_runtime : ., mut = 0
            if off < 0 || span <= 0:
                needs_runtime = 1

            if needs_runtime != 0 && runtime_targets == 1 && runtime_base >= 0:
                cell_store(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S3, runtime_size)
                if op == IR_DEREF:
                    cell_store(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S2, runtime_base)
                else:
                    // IR_STORE_PTR has no result, so dest carries the runtime base.
                    cell_store(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_DEST, runtime_base)
            else if needs_runtime != 0 && runtime_targets > 1:
                check_error(EC_TK_INDEX,
                    "runtime pointer bounds check has multiple allocation targets",
                    0, 0)
        ni = ni + 1

fn provenance_verify_all():
    // Safety pass; always runs.
    fi : ., mut = 0
    loop:
        if fi >= g_ir_func_count:
            break
        nstart := cell_load(g_df_func_node_start, fi * 8)
        ncount := cell_load(g_df_func_node_count, fi * 8)
        provenance_verify_func(nstart, ncount)
        fi = fi + 1
