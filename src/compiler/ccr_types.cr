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
    need := 4 + rc * ESZ_TYPE_ROW + 4 + tc * ESZ_TYPE_TERM_DISK
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
    // Fill NOD term indexes after ccr_type_populate, because that call rebuilds the
    // term table and invalidates emit-time indexes. This runs after both segment
    // bodies: it only queries the bridge cache, and all rows are already built, so
    // it adds no terms and does not change segment bytes. Failure uses the same
    // type-face gate.
    if ccr_nod_item_populate() != 0:
        return -1
    // Derive the v10 NOD semantic type ids from the same save-time type state.
    // This is side data for the v10 cutover: the v9 NOD wire keeps `item` at +28
    // and does not gain a type_id field here.
    return ccr_nod_type_populate()

// Fill NOD term indexes. For each node in global instruction order, look up the
// file-space term index from the stored derived code.
// Face 0 (a type row whose term is reversible) uses sh_term_of_ti(tk); the loader
// checks tt_atom_of_term(term) == tk. All other cases use -1. The tk slot still
// preserves the code byte for byte.
// Classification and term construction use only the existing bridge entry points.
// This is a pure query and does not set the build-failure bit.
// The index is rederived at save time because ccr_type_populate resets the term
// layer and invalidates emit-time references.
fn ccr_nod_item_populate() -> int:
    n := g_ir_instr_count
    g_ccr_nod_item = alloc((n + 8) * 4)
    g_ccr_nod_item_count = n
    ii : ., mut = 0
    loop:
        if ii >= n:
            break
        tk := iri_tk(ii)
        it : ., mut = -1
        if sh_tk_face_of_code(iri_op(ii), tk) == 0:
            it = sh_term_of_ti(tk)
        cell_store32(g_ccr_nod_item, ii * 4, it)
        ii = ii + 1
    return 0

// Fill NOD semantic type ids into the v10 side buffer. For each node in global
// instruction order, apply the fixed rule:
//   sh_tk_face_of_code(op, tk) == 0 -> type_id = tk   (tk is a TYPE row)
//   otherwise                        -> type_id = -1
// The companion flags word is constant 0 in this task; Task 4 classifies semantic
// node features into it.
// This is a pure query/derivation: it does not mutate the type tables, the term
// table, or g_tk_face_fail, and it does not change the v9 wire. The 40B NOD record
// still carries `item` at +28 for diagnostics and for the current v9 loader.
fn ccr_nod_type_populate() -> int:
    n := g_ir_instr_count
    g_ccr_nod_type = alloc((n + 8) * 4)
    g_ccr_nod_type_count = n
    ii : ., mut = 0
    loop:
        if ii >= n:
            break
        tk := iri_tk(ii)
        tid : ., mut = -1
        if sh_tk_face_of_code(iri_op(ii), tk) == 0:
            tid = tk
        cell_store32(g_ccr_nod_type, ii * 4, tid)
        ii = ii + 1
    return 0

// --dump-types test channel. The shared surface dump in ccr_io.cr uses the same
// print path as corearch, so line formats match across processes. This corec-only
// section adds the row-to-term mapping and the NOD semantic type-id side buffer
// (v10 preparation; the v9 wire does not carry it); tests split on "rowterms:"
// and "nodtypes:".
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
    // v10 NOD semantic type ids (v9 wire frozen): read the side buffer through the
    // shared accessors so tests see exactly what nod_type_id returns. One
    // deterministic line per node; flags is the constant 0 companion word.
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
