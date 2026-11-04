// === ccr_types.cr ===
// Build the contents of the TYPE(7) and IFACE(8) segments. This file is
// corec-only: filling uses the type bridge and checker tables. ccr_io.cr, which
// corearch also links, only copies the buffers.
//
// TYPE segment layout (little-endian, offsets relative to the segment):
//   [row_count u32]
//   [row_count x 24B {kind, data, extra} as i64]
//   [term_count u32]
//   [term_count x 40B {tag, a, b, c, d} as i64]
// The term hash is not stored; the loader recomputes it.
// Child references must be -1 or less than the current row, which keeps the DAG
// acyclic. Atom annotations such as ak, a type row, a fixed-length flag, a token,
// or a mut marker are not child references and are exempt from that check.
// tag must be in 0..10; a..d must be >= -1.
//
// IFACE segment layout, five sections, each with a count:
//   1. native entries: count, then 24B {ak i32, ti_row i32, name_ni i32,
//      lit_code i32, ops i64}
//   2. shapes: count, then 8B {name_ni i32, term i32}
//   3. user interfaces: count, then 16B headers
//      {name_ni, method_count, generic_count, pad}, each followed by
//      method_count x 80B {name_ni, param_count, self_mode, ret_term,
//      param_terms[8], param_codes[8]}
//   4. impl edges: count, then 8B {trait_ni, type_ni}
//   5. method table: count, then 12B {type_ni, method_ni, mangled_ni}
// The loader checks counts and lengths, requires the scan to end at seg_end8,
// requires native_count == IFACE_ENTRY_COUNT, and validates every cross-segment
// reference.

fn ccr_type_populate() -> int:
    // Reset the term layer, engine state, and both bridge caches. All three hold
    // caches keyed by old row numbers; leaving one reset would reuse stale terms.
    tt_layer_reset()
    sh_map_reset()            // clear the ti-to-term bridge cache
    sh_unf_map_reset()        // clear the expanded-term cache
    // Re-register the six builtin shapes before filling rows. This is idempotent
    // and keeps their term rows in a fixed prefix of the construction order. The
    // shape table itself is stored in IFACE section 2.
    iface_shape_builtin_init()
    // Fill rows 0..g_type_count-1. The nine native rows use the sh_native_ak fast
    // path and do not enter the cache. An untranslatable row refuses the save; a
    // missing term would mean the carrier is incomplete.
    i : ., mut = 0
    loop:
        if i >= g_type_count:
            break
        if sh_term_of_ti(i) < 0:
            print("error: TYPE segment: type row ")
            print(int_str(i))
            println(" is not translatable to a type term (save refused)")
            return -1
        i = i + 1
    // Fill interface signature terms in declaration order. The values go into the
    // term slots in g_ifaces and are read by IFACE section 3.
    return ccr_iface_populate()

// Fill IFACE section 3. For each interface in declaration order, each method and
// parameter, build the canonical signature term and write it to ret_term and
// param_terms. Unused parameter slots are -1.
// If a term cannot be built, refuse to save. The only reachable case is a dyn
// bitmap row, for which sh_sig_term_to_ti returns -1. The receiver uses a unit
// placeholder term and does not trigger rejection.
fn ccr_iface_populate() -> int:
    iface_ensure()   // the entry table may be queried before init_types; idempotent
    ii : ., mut = 0
    loop:
        if ii >= g_iface_count:
            break
        mc := cell_load(g_ifaces, ii * ESZ_IFACEINFO + OFF_IF_METHOD_COUNT)
        if mc < 0 || mc > MAX_IFACE_METHODS:
            print("error: IFACE segment: interface ")
            print(int_str(ii))
            print(" method count ")
            print(int_str(mc))
            println(" out of range (save refused)")
            return -1
        mi : ., mut = 0
        loop:
            if mi >= mc:
                break
            mbase := ii * ESZ_IFACEINFO + OFF_IF_METHODS + mi * ESZ_IFMETHOD
            pc := cell_load(g_ifaces, mbase + OFF_IFM_PARAM_COUNT)
            if pc < 0 || pc > MAX_IFACE_METHOD_PARAMS:
                print("error: IFACE segment: method ")
                print(int_str(mi))
                print(" of interface ")
                print(int_str(ii))
                print(" param count ")
                print(int_str(pc))
                println(" out of range (save refused)")
                return -1
            rt := sh_iface_sig_ret_term(ii, mi)
            if rt < 0:
                print("error: IFACE segment: interface ")
                print(int_str(ii))
                print(" method ")
                print(int_str(mi))
                println(" return signature is not translatable to a type term (save refused)")
                return -1
            cell_store(g_ifaces, mbase + OFF_IFM_RET_TERM, rt)
            pj : ., mut = 0
            loop:
                if pj >= MAX_IFACE_METHOD_PARAMS:
                    break
                cell_store(g_ifaces, mbase + OFF_IFM_PARAM_TERMS + pj * 8, -1)   // 未用槽 = -1
                pj = pj + 1
            pk : ., mut = 0
            loop:
                if pk >= pc:
                    break
                pt := sh_iface_sig_param_term(ii, mi, pk)
                if pt < 0:
                    print("error: IFACE segment: interface ")
                    print(int_str(ii))
                    print(" method ")
                    print_i(mi)
                    print(" param ")
                    print_i(pk)
                    println(" signature is not translatable to a type term (save refused)")
                    return -1
                cell_store(g_ifaces, mbase + OFF_IFM_PARAM_TERMS + pk * 8, pt)
                pk = pk + 1
            mi = mi + 1
        ii = ii + 1
    return 0

// Build the TYPE segment body into g_ccr_type_seg and g_ccr_type_seg_len.
// The buffer includes row_count, so ccr_type_seg_size() equals this length.
// ccr_type_populate must have run first; the segment is the filled result, not
// the live table.
fn ccr_type_seg_build() -> int:
    rc := g_type_count
    tc := tt_count()
    need : ., mut = 4 + rc * ESZ_TYPE_ROW + 4 + tc * ESZ_TYPE_TERM_DISK
    buf := alloc(need + 64)
    pos : ., mut = 0
    cell_store32(buf, pos, rc)
    pos = pos + 4
    i : ., mut = 0
    loop:
        if i >= rc:
            break
        cell_store(buf, pos, cell_load(g_types, i * ESZ_TYPE_ROW + OFF_TR_KIND))
        pos = pos + 8
        cell_store(buf, pos, cell_load(g_types, i * ESZ_TYPE_ROW + OFF_TR_DATA))
        pos = pos + 8
        cell_store(buf, pos, cell_load(g_types, i * ESZ_TYPE_ROW + OFF_TR_EXTRA))
        pos = pos + 8
        i = i + 1
    cell_store32(buf, pos, tc)
    pos = pos + 4
    j : ., mut = 0
    loop:
        if j >= tc:
            break
        cell_store(buf, pos, tt_tag(j))
        pos = pos + 8
        cell_store(buf, pos, tt_a(j))
        pos = pos + 8
        cell_store(buf, pos, tt_b(j))
        pos = pos + 8
        cell_store(buf, pos, tt_c(j))
        pos = pos + 8
        cell_store(buf, pos, tt_d(j))
        pos = pos + 8
        j = j + 1
    g_ccr_type_seg = buf
    g_ccr_type_seg_len = need
    return 0

// Build the IFACE segment body into g_ccr_iface_seg and g_ccr_iface_seg_len.
// The buffer includes native_count, so ccr_iface_seg_size() equals this length.
// ccr_type_populate must have run first; section 3 reads the filled term slots.
// Size is 4 + 16*24 for section 1, plus 4 + sc*8, 4 + sum(16 + mc*80),
// 4 + ic*8, and 4 + gc*12 for sections 2..5. The calculator reads this function.
fn ccr_iface_seg_build() -> int:
    need : ., mut = 4 + IFACE_ENTRY_COUNT * 24
    need = need + 4 + g_iface_shape_count * 8
    need = need + 4
    ii : ., mut = 0
    loop:
        if ii >= g_iface_count:
            break
        mc := cell_load(g_ifaces, ii * ESZ_IFACEINFO + OFF_IF_METHOD_COUNT)
        need = need + 16 + mc * 80
        ii = ii + 1
    need = need + 4 + g_impl_for_count * 8
    need = need + 4 + g_method_count * 12
    buf := alloc(need + 64)
    pos : ., mut = 0
    // Section 1: native entries. The count is the constant IFACE_ENTRY_COUNT, not
    // g_iface_entry_count, so writer and loader use the same value.
    cell_store32(buf, pos, IFACE_ENTRY_COUNT)
    pos = pos + 4
    ei : ., mut = 0
    loop:
        if ei >= IFACE_ENTRY_COUNT:
            break
        eo := ei * ESZ_IFACE_ENTRY
        buf_write_i32(buf, pos, cell_load(g_iface_entries, eo + OFF_IE_AK))
        pos = pos + 4
        buf_write_i32(buf, pos, cell_load(g_iface_entries, eo + OFF_IE_TI))
        pos = pos + 4
        buf_write_i32(buf, pos, cell_load(g_iface_entries, eo + OFF_IE_NAME))
        pos = pos + 4
        buf_write_i32(buf, pos, cell_load(g_iface_entries, eo + OFF_IE_LIT))
        pos = pos + 4
        buf_write_i64(buf, pos, cell_load(g_iface_entries, eo + OFF_IE_OPS))
        pos = pos + 8
        ei = ei + 1
    // Section 2: cross-cutting shapes {name_ni, term}.
    cell_store32(buf, pos, g_iface_shape_count)
    pos = pos + 4
    si : ., mut = 0
    loop:
        if si >= g_iface_shape_count:
            break
        buf_write_i32(buf, pos, cell_load(g_iface_shape_names, si * 8))
        pos = pos + 4
        buf_write_i32(buf, pos, cell_load(g_iface_shape_terms, si * 8))
        pos = pos + 4
        si = si + 1
    // Section 3: user interfaces, 16-byte header plus 80 bytes per method.
    cell_store32(buf, pos, g_iface_count)
    pos = pos + 4
    fi : ., mut = 0
    loop:
        if fi >= g_iface_count:
            break
        fo := fi * ESZ_IFACEINFO
        buf_write_i32(buf, pos, cell_load(g_ifaces, fo + OFF_IF_NAME))
        pos = pos + 4
        buf_write_i32(buf, pos, cell_load(g_ifaces, fo + OFF_IF_METHOD_COUNT))
        pos = pos + 4
        buf_write_i32(buf, pos, cell_load(g_ifaces, fo + OFF_IF_GENERIC_COUNT))
        pos = pos + 4
        buf_write_i32(buf, pos, 0)
        pos = pos + 4   // pad for alignment
        mc2 := cell_load(g_ifaces, fo + OFF_IF_METHOD_COUNT)
        mj : ., mut = 0
        loop:
            if mj >= mc2:
                break
            mo := fo + OFF_IF_METHODS + mj * ESZ_IFMETHOD
            buf_write_i32(buf, pos, cell_load(g_ifaces, mo + OFF_IFM_NAME))
            pos = pos + 4
            buf_write_i32(buf, pos, cell_load(g_ifaces, mo + OFF_IFM_PARAM_COUNT))
            pos = pos + 4
            buf_write_i32(buf, pos, cell_load(g_ifaces, mo + OFF_IFM_SELF_MODE))
            pos = pos + 4
            buf_write_i32(buf, pos, cell_load(g_ifaces, mo + OFF_IFM_RET_TERM))
            pos = pos + 4
            pk2 : ., mut = 0
            loop:
                if pk2 >= MAX_IFACE_METHOD_PARAMS:
                    break
                buf_write_i32(buf, pos, cell_load(g_ifaces, mo + OFF_IFM_PARAM_TERMS + pk2 * 8))
                pos = pos + 4
                pk2 = pk2 + 1
            pq : ., mut = 0
            loop:
                if pq >= MAX_IFACE_METHOD_PARAMS:
                    break
                buf_write_i32(buf, pos, cell_load(g_ifaces, mo + OFF_IFM_PARAM_TYPES + pq * 8))
                pos = pos + 4
                pq = pq + 1
            mj = mj + 1
        fi = fi + 1
    // Section 4: impl edges {trait_ni, type_ni}; declaration metadata only.
    cell_store32(buf, pos, g_impl_for_count)
    pos = pos + 4
    gi2 : ., mut = 0
    loop:
        if gi2 >= g_impl_for_count:
            break
        buf_write_i32(buf, pos, cell_load(g_impl_for, gi2 * 16))
        pos = pos + 4
        buf_write_i32(buf, pos, cell_load(g_impl_for, gi2 * 16 + 8))
        pos = pos + 4
        gi2 = gi2 + 1
    // Section 5: method table {type_ni, method_ni, mangled_ni}, the data behind
    // iface_find_method.
    cell_store32(buf, pos, g_method_count)
    pos = pos + 4
    mi2 : ., mut = 0
    loop:
        if mi2 >= g_method_count:
            break
        buf_write_i32(buf, pos, cell_load(g_methods, mi2 * 24))
        pos = pos + 4
        buf_write_i32(buf, pos, cell_load(g_methods, mi2 * 24 + 8))
        pos = pos + 4
        buf_write_i32(buf, pos, cell_load(g_methods, mi2 * 24 + 16))
        pos = pos + 4
        mi2 = mi2 + 1
    g_ccr_iface_seg = buf
    g_ccr_iface_seg_len = need
    return 0

// Single entry before save: fill tables, build both segment bodies, and return -1
// to refuse the save. The type-face failure gate is checked first. The splitter
// records failures during emit or .cir load; saving is the last gate, and neither
// filling nor segment construction looks at that counter.
fn ccr_seg_prepare_save() -> int:
    if g_tk_face_fail != 0:
        print("error: ")
        print_i(g_tk_face_fail)
        println(" type-face DF node(s) with untranslatable type row — refusing to save .ccr (D23)")
        return -1
    if ccr_type_populate() != 0:
        return -1
    if ccr_type_seg_build() != 0:
        return -1
    if ccr_iface_seg_build() != 0:
        return -1
    // Derive the v10 NOD semantic type ids and feature flags from the same
    // save-time type state, then copy them into the in-memory object record.
    // Task 3's item side buffer is retired with the v10 disk field.
    if ccr_nod_type_populate() != 0:
        return -1
    populate_nod_objects()
    return 0

// Fill NOD semantic type ids and feature flags into the v10 side buffers. For
// each node in global instruction order, apply the fixed rule:
//   sh_tk_face_of_code(op, tk) == 0 -> type_id = tk   (tk is a TYPE row)
//   otherwise                        -> type_id = -1
// Flags carry semantic node features only:
//   IR_BOUNDS_CHECK, tk != 0        -> DYNAMIC_LIMIT
//   IR_SPAWN, tk < 0                -> DYNAMIC_SPAWN
//   IR_DEREF/IR_STORE_PTR, s3 > 0   -> RUNTIME_PTR_BOUNDS
// The width/stride/byte extent behind those facts is a target fact and is not
// written; corearch reconstructs it from type_id and the target layout.
// A legacy aux code outside this classification rejects the save instead of
// silently dropping meaning. IR_STR_OF's TI_STR scratch code has no consumer
// and no semantic feature, so it is explicitly classified as featureless.
// This is a pure query/derivation: it does not mutate the type tables, the term
// table, or g_tk_face_fail.
// Semantic type row for a variable id (-1 when untyped/out of range).
fn ccr_var_type_row(v: int) -> int:
    if v < 0 || v >= g_ir_var_count:
        return -1
    t := irv_type(v)
    if t < 0 || t >= g_type_count:
        return -1
    return t

// Pointee/element row of a pointer/reference/array/slice row.
fn ccr_inner_type_row(t: int) -> int:
    if t < 0 || t >= g_type_count:
        return -1
    k := get_type_kind(t)
    if k == TYP_PTR || k == TYP_REF || k == TYP_ARRAY || k == TYP_SLICE || k == TYP_OPTIONAL:
        d := get_type_data(t)
        if d >= 0 && d < g_type_count:
            return d
    return -1

// Named/struct row matching a type-name string index.
fn ccr_named_row_of_name(ni: int) -> int:
    if ni < 0:
        return -1
    i : ., mut = 0
    loop:
        if i >= g_type_count:
            break
        if get_type_kind(i) == TYP_NAMED && get_type_data(i) == ni:
            return i
        i = i + 1
    return -1

// Per-op semantic domain for the v10 NOD type_id. Type-face ops keep the
// existing reversible-row rule; the ops below carry a domain even though their
// legacy type code was a target/aux fact. -1 means the domain is genuinely
// unavailable (fail closed: corearch may then only fall back to the variable
// table, never to a guessed machine width).
fn ccr_nod_type_domain(ii: int, op: int, d: int, s1: int, s2: int, s3: int) -> int:
    if op == IR_DEREF:
        p := ccr_var_type_row(s1)
        if p >= 0:
            k := get_type_kind(p)
            if k == TYP_PTR || k == TYP_REF:
                pin := ccr_inner_type_row(p)
                if pin >= 0:
                    return pin
        return ccr_var_type_row(d)
    if op == IR_STORE_PTR:
        return ccr_var_type_row(s2)
    if op == IR_ALLOC_AT:
        t := ccr_var_type_row(d)
        ein := ccr_inner_type_row(t)
        if ein >= 0:
            return ein
        return TI_INT
    if op == IR_ALLOC_ARRAY:
        t := ccr_var_type_row(d)
        ein := ccr_inner_type_row(t)
        if ein >= 0:
            return ein
        // Some literal/tuple allocations get their array row after the node.
        // Fall back to the first value stored into this base.
        j : ., mut = 0
        loop:
            if j >= g_ir_instr_count:
                break
            jop := iri_op(j)
            if (jop == IR_STORE_INDEX || jop == IR_STORE_INDEX_VAR) && iri_s1(j) == d:
                vt := ccr_var_type_row(iri_s2(j))
                if vt >= 0:
                    return vt
            j = j + 1
        return -1
    if op == IR_ALLOC_STRUCT:
        t := ccr_var_type_row(d)
        if t >= 0:
            k := get_type_kind(t)
            if k == TYP_NAMED || k == TYP_GENERIC_APPLY:
                return t
        return ccr_named_row_of_name(s3)
    if op == IR_LOAD:
        return ccr_var_type_row(d)
    if op == IR_STORE:
        return ccr_var_type_row(s2)
    if op == IR_ALLOC:
        return ccr_var_type_row(d)
    if op == IR_ADDR_INDEX:
        t := ccr_var_type_row(d)
        ain := ccr_inner_type_row(t)
        if ain >= 0:
            return ain
        return t
    if op == IR_LOAD_INDEX || op == IR_LOAD_INDEX_VAR:
        return ccr_var_type_row(d)
    if op == IR_STORE_INDEX:
        return ccr_var_type_row(s2)
    if op == IR_STORE_INDEX_VAR:
        return ccr_var_type_row(d)
    if op == IR_LOAD_FIELD:
        return ccr_var_type_row(d)
    if op == IR_STORE_FIELD:
        return ccr_var_type_row(s2)
    if op == IR_SLICE:
        return ccr_var_type_row(d)
    if op == IR_MAKE_ENUM:
        return ccr_var_type_row(d)
    if op == IR_LOAD_ENUM_TAG:
        return ccr_var_type_row(d)
    if op == IR_MATCH:
        // The scrutinee's semantic type is the meaningful domain; the CASE
        // table carries no width or layout fact.
        return ccr_var_type_row(s1)
    // Listed ops whose domain is genuinely unavailable from the current IR
    // state. They remain -1 rather than guessing.
    return -1

fn ccr_nod_type_populate() -> int:
    n := g_ir_instr_count
    g_ccr_nod_type = alloc((n + 8) * 4)
    g_ccr_nod_type_count = n
    g_ccr_nod_flags = alloc((n + 8) * 4)
    g_ccr_nod_flags_count = n
    ii : ., mut = 0
    loop:
        if ii >= n:
            break
        op := iri_op(ii)
        tk := iri_tk(ii)
        tid : ., mut = -1
        fl : ., mut = 0
        if sh_tk_face_of_code(op, tk) == 0:
            tid = tk
        else:
            // Non-face ops carry a semantic domain when the variable table can
            // supply it (DEREF pointee, STORE value, ALLOC element/struct,
            // field/index value domains). -1 stays "unavailable".
            dt := ccr_nod_type_domain(ii, op, iri_dest(ii), iri_s1(ii), iri_s2(ii), iri_s3(ii))
            if dt >= 0:
                tid = dt
        if sh_tk_is_type_face(op) != 0:
            // Type-face nodes carry no semantic feature bits. A composite row
            // stays -1 (not a reversible atom row).
            fl = 0
        else if op == IR_BOUNDS_CHECK:
            if tk != 0:
                fl = fl + CCR_NOD_FLAG_DYNAMIC_LIMIT
        else if op == IR_SPAWN:
            if tk < 0:
                fl = fl + CCR_NOD_FLAG_DYNAMIC_SPAWN
            else if tk != 0:
                return -1
        else if op == IR_DEREF || op == IR_STORE_PTR:
            if iri_s3(ii) > 0:
                fl = fl + CCR_NOD_FLAG_RUNTIME_PTR_BOUNDS
        else if op == IR_HOTPATCH_ROUTE || op == IR_STR_OF:
            // HOTPATCH_ROUTE carries tk == 0. IR_STR_OF's TI_STR scratch code is
            // not read by any backend consumer; neither is a node feature.
            fl = 0
        else if op == IR_LOAD_INDEX || op == IR_LOAD_INDEX_VAR || op == IR_CONST_BIG || op == IR_PTR_OF:
            // These ops pass a semantic type row as their legacy type_kind
            // (INDEX element domain, CONST_BIG/PTR_OF int domain). Task 3 fixes
            // type_id to reversible atom rows only and no backend consumer reads
            // this code, so it is classified as intentionally not persisted.
            // It is not a target fact and not an unclassifiable aux code.
            fl = 0
        else if tk != 0:
            // Unclassified legacy aux code: refuse to save rather than invent a
            // wire meaning for it.
            return -1
        cell_store32(g_ccr_nod_type, ii * 4, tid)
        cell_store32(g_ccr_nod_flags, ii * 4, fl)
        ii = ii + 1
    return 0

// --dump-types test channel. The shared surface dump in ccr_io.cr uses the same
// print path as corearch, so line formats match across processes. This corec-only
// section adds the row-to-term mapping and the NOD semantic type-id/flags side
// data; tests split on "rowterms:" and "nodtypes:".
fn ccr_type_selftest_dump():
    ccr_type_surface_dump()
    print("rowterms: ")
    print_i(g_type_count)
    println("")
    i : ., mut = 0
    loop:
        if i >= g_type_count:
            break
        print("rowterm ")
        print_i(i)
        print(" ")
        println(int_str(sh_term_of_ti(i)))
        i = i + 1
    // v10 NOD semantic type ids and feature flags. Read the in-memory object
    // record through the shared accessors so tests see exactly what the writer
    // emits. One deterministic line per node.
    print("nodtypes: ")
    print_i(g_ccr_nod_type_count)
    println("")
    ni : ., mut = 0
    loop:
        if ni >= g_ccr_nod_type_count:
            break
        print("nodtype ")
        print_i(ni)
        print(" op ")
        print_i(iri_op(ni))
        print(" tk ")
        print_i(iri_tk(ni))
        print(" tid ")
        print_i(nod_type_id(ni))
        print(" flags ")
        print_i(nod_type_flags(ni))
        println("")
        ni = ni + 1

// --dump-ifaces test channel. The shared surface dump uses the same print path as
// corearch. This corec-only section recomputes signature terms after the segment
// buffer is built, using an independent read path. Tests compare the stored values
// with these live values; tests split on "ifacesig:".
fn ccr_iface_selftest_dump():
    ccr_iface_surface_dump()
    print("ifacesig: ")
    print_i(g_iface_count)
    println("")
    ii : ., mut = 0
    loop:
        if ii >= g_iface_count:
            break
        mc := cell_load(g_ifaces, ii * ESZ_IFACEINFO + OFF_IF_METHOD_COUNT)
        mi : ., mut = 0
        loop:
            if mi >= mc:
                break
            mbase := ii * ESZ_IFACEINFO + OFF_IF_METHODS + mi * ESZ_IFMETHOD
            pc := cell_load(g_ifaces, mbase + OFF_IFM_PARAM_COUNT)
            print("ifacesig ")
            print_i(ii)
            print(" ")
            print_i(mi)
            print(" ret ")
            print_i(sh_iface_sig_ret_term(ii, mi))
            print(" pc ")
            print_i(pc)
            println("")
            pj : ., mut = 0
            loop:
                if pj >= pc:
                    break
                print("ifacesigp ")
                print_i(ii)
                print(" ")
                print_i(mi)
                print(" ")
                print_i(pj)
                print(" ")
                println(int_str(sh_iface_sig_param_term(ii, mi, pj)))
                pj = pj + 1
            mi = mi + 1
        ii = ii + 1
