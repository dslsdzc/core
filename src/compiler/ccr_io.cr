// === ccr_io.cr ===
// .ccr binary serialization, the interface between corec and corearch.
//
// Version 10 only. The loader checks version == CCR_V10_VERSION (0x000A0000)
// and rejects v9 (589825) and every other version; there is no conversion path.
// The format has 9 segments in canonical order:
// STR, TYPE, IFACE, SYM, NOD, ENT, REG, EDG, CASE (tags 1..9).
//
// Header 16B: magic "CCR1", version 0x000A0000, segment count 9, flags.
// Segment table: 9 entries of {tag u32, offset u32, size u32}. Tags are in
// canonical order, offsets are contiguous and start at the end of the table.
// The loader consumes the bodies in this same order with a forward-only cursor;
// it uses the table entries only to validate bounds and contiguity.
//
// STR(1): [count][{len, data}].
// SYM(4):
//   globals: [count][{name u32, type u32, init_val i64}] 16B each.
//   functions: [count][{name u32, param_count u32, ret_type u32,
//     root_region i32, first_ent i32, last_ent i32} 24B
//     + param_ents[param_count] i32
//     + var_count u32 + var_decls[var_count]{name u32, type u32}].
//   string constants: [count][u32...].
//   structs: [count][{name u32, field_count u32,
//     fields[field_count]{name u32, type u32}}].
//   enums: [count][{name u32, variant_count u32,
//     variants[variant_count]{name u32, type_count u32,
//     types[type_count] u32}}].
//   opt metadata: [count][{key u32, len u32, data len bytes}].
// NOD(5): [count][40B {op i32, dest i32, src1 i64, src2 i32, src3 i32,
//   type_id i32, flags u32, first_edge u32, edge_count u32}].
//   src2/src3 never carry width, byte offset, stride, or alignment.
// EDG(8): [count][8B {to_nod u32, kind u32}].
// ENT(6): [count][24B {var_id i32, version u32, def_nod i32, live_start u32,
//   live_end u32, flags u32}]. home is not part of v10.
// REG(7): [count][24B {kind u32, parent i32, enter_nod u32, exit_nod u32,
//   first_ent i32, last_ent i32}].
// TYPE(2): type rows and the type-term DAG.
//   Layout: [row_count u32]
//           [row_count * 24B {kind i64, data i64, extra i64}]
//           [term_count u32]
//           [term_count * 40B {tag i64, a i64, b i64, c i64, d i64}]
//
//   Rows are g_types[0..row_count-1] verbatim, using the same 24B memory layout:
//   kind, data, extra. Primitive rows 0..8 and dynamic rows use the same record;
//   the loader rebuilds the table directly and does not rerun type construction.
//
//   Terms are the type-term DAG in file order. The hash slot is not stored. The
//   loader recomputes it with tt_hash5 and rebuilds g_tt_index. Field meaning by
//   tag:
//     TT_BOT(0), TT_TOP(1), TT_NIL(9): no references.
//     TT_TOP_K(2): a = atom class k.
//     TT_UNION(3), TT_INTER(4): a and b = child term indices.
//     TT_NOT(5): a = child term index.
//     TT_MU(6): a = bound variable id, b = body term index.
//     TT_ATOM(7): a = AK_* atom class; b = annotation (canonical type row, fixedness
//       marker, token value, or mut marker); c = parameter chain head or -1.
//     TT_VAR(8): a = variable id.
//     TT_CONS(10): a = head term, b = tail chain.
//
//   Validation in the loader:
//     - row_count must fit the remaining segment; every row is read as 24B.
//     - term_count must fit; tag is in 0..10; a, b, c, d are >= -1.
//     - Child references must be -1 or less than the current term row. This covers
//       UNION/INTER a and b, NOT a, MU b, CONS a and b, and every element of an
//       ATOM c chain. The DAG is therefore acyclic in file order.
//     - Annotation slots are not checked as row references: ATOM a and b, TOP_K a,
//       MU a, and VAR a store class ids, annotations, or variable ids.
//     - The segment must end exactly at its table boundary. A mismatch rejects the
//       file.
//
//   NOD.type_id is a TYPE row (-1 = none). The v10 loader checks every NOD
//   type_id after TYPE loads: it must be -1 or an existing row.
//
//   TYPE is required. An empty, truncated, or non-translatable TYPE segment rejects
//   the whole file; it is never treated as an empty table. Content is built by
//   corec-only ccr_types.cr from the type rows and interface table, independent of
//   judgment history. Hashes are omitted because they are a pure function of the
//   five fields.
//
// IFACE(3): five sections, each prefixed by a u32 count.
//   1. Native entries:
//      [count = IFACE_ENTRY_COUNT][24B {ak i32, ti_row i32, name_ni i32,
//       lit_code i32, ops i64}].
//   2. Cross-cutting shapes: [count][8B {name_ni i32, term i32}].
//   3. User interfaces:
//      [count][16B {name_ni i32, method_count i32, generic_count i32, pad i32}
//       + method_count * 80B {name_ni i32, param_count i32, self_mode i32,
//       ret_term i32, param_terms[8] i32, param_codes[8] i32}].
//   4. Impl edges: [count][8B {trait_ni i32, type_ni i32}].
//   5. Method table: [count][12B {type_ni i32, method_ni i32, mangled_ni i32}].
//   name_ni, method_ni, and mangled_ni are STR indices. ti_row is -1 or a TYPE
//   row; term is -1 or a TYPE term. Counts must fit the segment and the walk must
//   end exactly at its table boundary.
//
// Invariants:
// - Node ids are file order. Edges are stored per node in a contiguous range;
//   every to_nod is greater than the owning node.
// - ENT is the verification and semantic source. version is the 1-based
//   definition ordinal within a var group; live_end is half-open. flags is 0 in
//   files produced by the current writer, and v10 has no home field.
// - REG is required; function instruction ranges derive from the SG_FUNC root
//   region span. ENT may be absent, treated as an empty table.
// - TYPE and IFACE are required. The loader rejects missing segments rather
//   than treating them as empty.
//
// Memory reconstruction after load: g_ir_vars, g_ir_globals, function arrays,
// g_sgs, g_ir_entries, g_types, g_type_terms, g_tt_index, and interface tables.
//
// All integers are little-endian, and offsets are relative to the file start.

// --- Byte buffer helpers ---
// No bitwise ops in Core; use arithmetic instead.

CCR_MAGIC : int = 827474755  // "CCR1" (0x31524343)

// Set by save_ccr from corec (compiler-source detection) and used to compute
// the SYSTEM header bit and to pass --raw-int to the backend. It is not a wire
// field and does not select int mode by itself.
g_ccr_emit_raw_int : int, mut

// NOD record: 40 bytes.
// {op i32, dest i32, s1 i64, src2 i32, src3 i32, type_id i32, flags u32,
//  first_edge u32, edge_count u32}.
// type_id is a TYPE row (-1 = none); flags is the semantic-node feature word
// (CCR_NOD_FLAG_*). Widths, strides, and byte extents are target facts and are
// reconstructed by corearch, never stored here. first_edge and edge_count locate
// this node's outgoing edges in EDG. The in-memory object record keeps the same
// eight semantic fields without the adjacency pair. CCR_V10_NOD_DISK = 40.

// EDG record: 8 bytes, {to_nod u32, kind u32}. The source node is implicit:
// node i's outgoing edges are the contiguous range
// [first_edge, first_edge + edge_count).

// REG record: 24 bytes, {kind i32, parent i32, enter_nod u32, exit_nod u32,
// first_ent i32, last_ent i32}. nstart and ncount are not stored; the loader
// derives nstart = enter and ncount = exit - enter.
// The in-memory SG entry is ESZ_SG (48 bytes, u64 fields), which is not the wire
// format. Use CCR_V10_REG_DISK for .ccr size math.

// SYM 落盘记录尺寸：
//   global records: 16B {name u32, type u32, init_val i64}.
//   函数记录 = 24B 定长头 {name, param_count, ret_type, root_region,
//                first_ent, last_ent} + param_ents[i32 × param_count]
//              + {var_count u32} + var_decls[8B × var_count]
ESZ_GLOBAL_DISK : int = 16
ESZ_FUNC_HEAD_DISK : int = 24
ESZ_VARDECL_DISK : int = 8

// On-disk ENT record: 6 × 4B = 24 bytes (var_id/version/def_nod/live_start/
// live_end/flags; version + 半开 live_end 由内存 24B 表转换，见文件头注释).
// The in-memory entry table is ESZ_ENTRY (24 bytes, no version field，the
// per-var ordinal is derivable from group order); disk record != memory record.
// CCR_V10_ENT_DISK = 24.

fn bw_byte(val: int, shift: int) -> int:
    if shift == 0:
        return val % 256
    if shift >= 24:
        return (val / 16777216) % 256
    if shift >= 16:
        return (val / 65536) % 256
    if shift >= 8:
        return (val / 256) % 256
    return 0

fn buf_write_u32(buf: string, pos: int, val: int):
    cell_store32(buf, pos, val)

fn buf_write_i32(buf: string, pos: int, val: int):
    cell_store32(buf, pos, val)

fn buf_write_i64(buf: string, pos: int, val: int):
    cell_store(buf, pos, val)

fn buf_read_u32(buf: string, pos: int) -> int:
    b0 := cell_load_byte(buf, pos)
    b1 := cell_load_byte(buf, pos + 1)
    b2 := cell_load_byte(buf, pos + 2)
    b3 := cell_load_byte(buf, pos + 3)
    return b0 + b1 * 256 + b2 * 65536 + b3 * 16777216

fn buf_read_i32(buf: string, pos: int) -> int:
    b0 := cell_load_byte(buf, pos)
    b1 := cell_load_byte(buf, pos + 1)
    b2 := cell_load_byte(buf, pos + 2)
    b3 := cell_load_byte(buf, pos + 3)
    val := b0 + b1 * 256 + b2 * 65536
    if b3 >= 128:
        return val + (b3 - 256) * 16777216
    return val + b3 * 16777216

fn buf_read_i64(buf: string, pos: int) -> int:
    // Little-endian signed 64-bit. The low dword must be read UNSIGNED:
    // reading it signed (buf_read_i32) would double-subtract for negatives
    // (e.g. -7 = lo -7 + hi -1 -> -7 + -2^32, not -7).
    b0 := cell_load_byte(buf, pos)
    b1 := cell_load_byte(buf, pos + 1)
    b2 := cell_load_byte(buf, pos + 2)
    b3 := cell_load_byte(buf, pos + 3)
    lo := b0 + b1 * 256 + b2 * 65536 + b3 * 16777216
    h0 := cell_load_byte(buf, pos + 4)
    h1 := cell_load_byte(buf, pos + 5)
    h2 := cell_load_byte(buf, pos + 6)
    h3 := cell_load_byte(buf, pos + 7)
    hi : ., mut = h0 + h1 * 256 + h2 * 65536
    if h3 >= 128:
        hi = hi + (h3 - 256) * 16777216
    else:
        hi = hi + h3 * 16777216
    // 修复 15：h3 < 128 时漏加 h3×2^24 -> bit 56-62 丢失
    // Keep the factor within the parser's supported integer-literal range.
    hi_part := hi * 65536
    hi_part = hi_part * 65536
    return lo + hi_part

// Check a byte range without forming an overflowing end position. CCR counts
// come from the file, so every variable-length section must use this helper
// before reading or growing an array from its count.
fn ccr_has_bytes(pos: int, need: int, fsize: int) -> int:
    if pos < 0 || need < 0 || pos > fsize:
        return 0
    if need > fsize - pos:
        return 0
    return 1

fn ccr_i32_fits(val: int) -> int:
    if val < -2147483648 || val > 2147483647:
        return 0
    return 1

fn ccr_validate_i32_fields() -> int:
    ii : ., mut = 0
    loop:
        if ii >= g_ir_instr_count:
            break
        if ccr_i32_fits(iri_dest(ii)) == 0 || ccr_i32_fits(iri_s2(ii)) == 0 || ccr_i32_fits(iri_s3(ii)) == 0:
            return 0
        ii = ii + 1
    // REG stores kind, parent, enter, and exit. nstart and ncount are derived
    // from enter and exit and are not written.
    si : ., mut = 0
    loop:
        if si >= g_sg_count:
            break
        f := si * ESZ_SG
        if ccr_i32_fits(cell_load(g_sgs, f + OFF_SG_KIND)) == 0 || ccr_i32_fits(cell_load(g_sgs, f + OFF_SG_ENTER)) == 0 || ccr_i32_fits(cell_load(g_sgs, f + OFF_SG_EXIT)) == 0 || ccr_i32_fits(cell_load(g_sgs, f + OFF_SG_PARENT)) == 0:
            return 0
        si = si + 1
    return 1

// 函数 fi 的根 region = REG 记录顺序第 fi 个 SG_FUNC 行（压栈序：每个已编译函数
// df_begin_func 推 SG_FUNC，嵌套行紧随其根记录，根记录按函数序 1:1）。
// 返回记录 id；-1 = 越界/结构不一致。
fn ccr_func_root_sg(func_i: int) -> int:
    if func_i < 0:
        return -1
    k : ., mut = 0
    si : ., mut = 0
    loop:
        if si >= g_sg_count:
            break
        if cell_load(g_sgs, si * ESZ_SG + OFF_SG_KIND) == SG_FUNC:
            if k == func_i:
                return si
            k = k + 1
        si = si + 1
    return -1

// Segment size calculation. Header plus segment table = 16 + 12*8 = 112 bytes.
// Each segment carries a u32 count. The writer and size calculation must agree;
// the final segment end must equal the file size.

fn ccr_str_seg_size() -> int:
    sz : ., mut = 4  // str_count
    si : ., mut = 0
    loop:
        if si >= g_str_count:
            break
        sz = sz + 4 + istr_len(si)
        si = si + 1
    return sz

fn ccr_sym_seg_size() -> int:
    // 布局 = ccr_sym_seg_size/save_ccr/load_ccr 三方逐字节一致（见头注释）：
    //   globals(16B) -> funcs(24B 头 + param_ents + var_count + var_decls 8B)
    //   -> str_consts -> structs -> enums -> opt_meta
    sz : ., mut = 4 + g_ir_global_count * ESZ_GLOBAL_DISK   // global_count + globals
    sz = sz + 4  // func_count
    fi : ., mut = 0
    loop:
        if fi >= g_ir_func_count:
            break
        pc := cell_load(g_ir_func_param_count, fi * 8)
        vc := cell_load(g_ir_func_var_count, fi * 8)
        sz = sz + ESZ_FUNC_HEAD_DISK + pc * 4 + 4 + vc * ESZ_VARDECL_DISK
        fi = fi + 1
    sz = sz + 4 + g_ir_str_const_count * 4     // str_const_count + str_consts
    // structs: struct_count + {name, field_count, fields×8B}
    sz = sz + 4
    sti : ., mut = 0
    loop:
        if sti >= g_struct_count:
            break
        sz = sz + 8 + si_field_count(sti) * 8
        sti = sti + 1
    // enums: enum_count + {name, variant_count, variants×{name, tc, types×4B}}
    sz = sz + 4
    ei : ., mut = 0
    loop:
        if ei >= g_enum_count:
            break
        vc := ei_variant_count(ei)
        sz = sz + 8  // name + variant_count
        vi : ., mut = 0
        loop:
            if vi >= vc:
                break
            tc := ei_variant_type_count(ei, vi)
            sz = sz + 8 + tc * 4  // variant name + tc + types
            vi = vi + 1
        ei = ei + 1
    // opt_meta: opt_count + {key, len, data}
    sz = sz + 4
    mi : ., mut = 0
    loop:
        if mi >= g_opt_meta_count:
            break
        sz = sz + 8 + cell_load32(g_opt_meta, mi * OPT_META_STRIDE + 4)
        mi = mi + 1
    return sz

fn ccr_nod_seg_size() -> int:
    return 4 + g_ir_instr_count * CCR_V10_NOD_DISK

fn ccr_edg_seg_size(edge_total: int) -> int:
    return 4 + edge_total * CCR_V10_EDG_DISK

fn ccr_ent_seg_size() -> int:
    return 4 + g_entry_count * CCR_V10_ENT_DISK

fn ccr_reg_seg_size() -> int:
    return 4 + g_sg_count * CCR_V10_REG_DISK

fn ccr_case_seg_size() -> int:
    // CASE is an empty table until match lowering writes it: 4B case_count = 0.
    return 4

// ── Header flag classification (spec §3.1) ──────────────────────────────
// SYSTEM boundary ops: runtime/FFI/ABI surfaces. ARENA_NEW only counts when the
// scope actually allocates (s1 == 0 means "no arena", per instr.cr); the
// matching ARENA_RESET is then a no-op and need not be counted separately.
// CONCURRENT ops: execution-policy nodes.
fn ccr_op_is_system(op: int, arena_count: int) -> int:
    if op == IR_ARENA_NEW:
        if arena_count > 0:
            return 1
        return 0
    if op == IR_SPAWN || op == IR_YIELD || op == IR_AWAIT || op == IR_HOTPATCH_ROUTE || op == IR_FNADDR || op == IR_CALL_EXTERN || op == IR_INLINE || op == IR_PTR_OF || op == IR_STR_OF:
        return 1
    return 0

fn ccr_op_is_concurrent(op: int) -> int:
    if op == IR_SPAWN || op == IR_YIELD || op == IR_AWAIT:
        return 1
    return 0

// v10 src3 is an id/op/index/symbol for these ops. Every other op must carry 0
// in src3: a nonzero value would be a legacy width/scale/byte-extent target
// fact. ALLOC_ARRAY/ADDR_INDEX/DEREF/STORE_PTR are handled explicitly because
// their old src2/src3 facts are the migration's critical cases.
fn ccr_nod_src3_semantic(op: int) -> int:
    if op == IR_UNARY || op == IR_BINARY || op == IR_CALL || op == IR_ALLOC_STRUCT || op == IR_LOAD_FIELD || op == IR_STORE_FIELD || op == IR_STORE_INDEX || op == IR_BRANCH || op == IR_SLICE || op == IR_SPAWN || op == IR_HOTPATCH_ROUTE || op == IR_CALL_EXTERN || op == IR_LOAD_INDEX:
        return 1
    return 0

fn ccr_compute_header_flags() -> int:
    hsys : ., mut = 0
    hconc : ., mut = 0
    if g_ccr_emit_raw_int != 0:
        hsys = 1
    ii : ., mut = 0
    loop:
        if ii >= g_ir_instr_count:
            break
        if ccr_op_is_system(iri_op(ii), iri_s1(ii)) != 0:
            hsys = 1
        if ccr_op_is_concurrent(iri_op(ii)) != 0:
            hconc = 1
        ii = ii + 1
    flags : ., mut = 0
    if hsys == 0:
        flags = flags + CCR_FLAG_PORTABLE
    else:
        flags = flags + CCR_FLAG_SYSTEM
    if hconc != 0:
        flags = flags + CCR_FLAG_CONCURRENT
    return flags

// Post-NOD validation: the header must not claim PORTABLE while the graph has a
// SYSTEM boundary, and CONCURRENT must match the graph both ways. SYSTEM without
// a boundary node is allowed because raw-int build mode also sets SYSTEM.
fn ccr_validate_header_flags(rsv: int) -> int:
    hsys := (rsv / CCR_FLAG_SYSTEM) % 2
    hconc := (rsv / CCR_FLAG_CONCURRENT) % 2
    nsys : ., mut = 0
    nconc : ., mut = 0
    ii : ., mut = 0
    loop:
        if ii >= g_v7_nod_count:
            break
        if ccr_op_is_system(nod_op(ii), nod_s1(ii)) != 0:
            nsys = 1
        if ccr_op_is_concurrent(nod_op(ii)) != 0:
            nconc = 1
        ii = ii + 1
    if nsys != 0 && hsys == 0:
        return -1
    if nconc != 0 && hconc == 0:
        return -1
    if hconc != 0 && nconc == 0:
        return -1
    if hconc != 0 && hsys == 0:
        return -1
    return 0

// TYPE(2) segment size is the prepared buffer length. The content is built by
// corec-only ccr_types.cr. ccr_io.cr is shared with corearch and must not refer
// to frontend symbols. The buffer includes row_count, so segment size equals
// buffer length.
fn ccr_type_seg_size() -> int:
    return g_ccr_type_seg_len

// IFACE(3) segment size is the prepared buffer length. The five sub-sections are
// built by corec-only ccr_iface_populate and ccr_iface_seg_build in ccr_types.cr.
// This file, which corearch also links, only copies and parses the segment. The
// buffer includes native_count, so segment size equals buffer length.
fn ccr_iface_seg_size() -> int:
    return g_ccr_iface_seg_len

// Size calculation: 16B header + 9*12B segment table + segment bodies.
// edge_total = EDG 记录总数（save_ccr 先行收集，见 ccr_collect_edges）。

fn calc_ccr_size(edge_total: int) -> int:
    sz : ., mut = 16 + CCR_V10_SEG_COUNT * 12
    sz = sz + ccr_str_seg_size()
    sz = sz + ccr_type_seg_size()
    sz = sz + ccr_iface_seg_size()
    sz = sz + ccr_sym_seg_size()
    sz = sz + ccr_nod_seg_size()
    sz = sz + ccr_ent_seg_size()
    sz = sz + ccr_reg_seg_size()
    sz = sz + ccr_edg_seg_size(edge_total)
    sz = sz + ccr_case_seg_size()
    return sz

// EDG collection on the write side.
// g_df_edges is a per-node head-inserted out-edge list (dataflow.cr,
// OFF_DFE_NEXT). Before saving, walk nodes in order and build each node's
// contiguous out-edge range (first_edge = prefix sum) plus a flat {to, kind}
// buffer (8B per edge, packed as to + kind*2^32). The write guard matches the
// loader: a wrong owner, a backward or self edge (to_nod <= source), or
// kind > 1 rejects the file. The in-memory graph is the only source for EDG.
fn ccr_collect_edges(edge_counts: string, edge_offs: string) -> int:
    total : ., mut = 0
    ni : ., mut = 0
    loop:
        if ni >= g_ir_instr_count:
            break
        cell_store(edge_offs, ni * 8, total)
        cnt : ., mut = 0
        eid : ., mut = cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_FIRST_EDGE)
        loop:
            if eid < 0:
                break
            if eid >= g_df_edge_count:
                return -1
            // Edge record out of range; reject a corrupted cache restore.
            if cell_load(g_df_edges, eid * ESZ_DFEDGE + OFF_DFE_FROM) != ni:
                return -1
            eto := cell_load(g_df_edges, eid * ESZ_DFEDGE + OFF_DFE_TO)
            if eto <= ni:
                return -1
            // Rule: to_nod must be greater than the source node.
            if cell_load(g_df_edges, eid * ESZ_DFEDGE + OFF_DFE_KIND) > 1:
                return -1
            cnt = cnt + 1
            eid = cell_load(g_df_edges, eid * ESZ_DFEDGE + OFF_DFE_NEXT)
        cell_store(edge_counts, ni * 8, cnt)
        total = total + cnt
        ni = ni + 1
    return total

// 第二遍：按节点序把出边写入扁平缓冲（slot = edge_offs[i] 起连续）
fn ccr_fill_edge_buf(buf: string, edge_offs: string):
    ni : ., mut = 0
    loop:
        if ni >= g_ir_instr_count:
            break
        slot : ., mut = cell_load(edge_offs, ni * 8)
        eid : ., mut = cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_FIRST_EDGE)
        loop:
            if eid < 0:
                break
            eto := cell_load(g_df_edges, eid * ESZ_DFEDGE + OFF_DFE_TO)
            ekind := cell_load(g_df_edges, eid * ESZ_DFEDGE + OFF_DFE_KIND)
            cell_store(buf, slot * 8, eto + ekind * 4294967296)
            slot = slot + 1
            eid = cell_load(g_df_edges, eid * ESZ_DFEDGE + OFF_DFE_NEXT)
        ni = ni + 1

// EDG load buffer. After validation, keep the flat edge records for the object
// API v7_edge_to and v7_edge_kind in ent_kernel.cr. The corearch build does not
// include dataflow.cr, so this is a separate buffer.
g_v7_edges : string, mut         // EDG 扁平记录（8B/条，文件序 = 节点运记录顺序）
g_v7_edge_count : int, mut

// Entry table accessors for the in-memory 24B table. These are local aliases for
// the writer and loader; ent_kernel.cr has equivalent ent_* accessors.
// buf_read_i32 sign-extends the same way as the kernel.
fn ccr_ent_var(e: int) -> int:
    return buf_read_i32(g_ir_entries, e * ESZ_ENTRY + OFF_ENTRY_VAR)
fn ccr_ent_def(e: int) -> int:
    return buf_read_i32(g_ir_entries, e * ESZ_ENTRY + OFF_ENTRY_DEF)
fn ccr_ent_ls(e: int) -> int:
    return buf_read_i32(g_ir_entries, e * ESZ_ENTRY + OFF_ENTRY_LS)
fn ccr_ent_le(e: int) -> int:
    return buf_read_i32(g_ir_entries, e * ESZ_ENTRY + OFF_ENTRY_LE)
fn ccr_ent_home(e: int) -> int:
    return buf_read_i32(g_ir_entries, e * ESZ_ENTRY + OFF_ENTRY_HOME)
fn ccr_ent_flags(e: int) -> int:
    return buf_read_i32(g_ir_entries, e * ESZ_ENTRY + OFF_ENTRY_FLAGS)

// Entry table growth. compute_entries_v7 and the ccr_grow_* mirrors are gone.
// The corec writer calls compute_live_ranges(), which calls compute_entries per
// function. Growth uses the kernel grow_entries and grow_func_entry_meta functions
// in ent_kernel.cr, shared by both concat builds. The corearch loader calls the
// same kernel functions.

// 函数条目块 [es, es+ec) 内 var 的 def=-1 条目 id（SYM func param_ents 回填
// 用，参数入参条目 = 该参数 def=-1 条目；被重定值/从未引用 -> 无 = -1；
// def=-1 补丁每 var 至多一条）。写侧检查：返回 id 恒 >= es 且在块内。
fn ccr_param_entry_id(var_id: int, es: int, ec: int) -> int:
    e : ., mut = 0
    loop:
        if e >= ec:
            break
        ei := es + e
        if ccr_ent_var(ei) == var_id && ccr_ent_def(ei) < 0:
            return ei
        e = e + 1
    return -1

// Write-side object mirror. corec does not load through the loader, and the
// kernel compute functions read NOD objects through nod_*. Before compute, copy
// g_ir_instrs into g_v7_nod_sem (32B semantic fields: op, dest, s1, s2, s3,
// type_id, flags). Values come from the same g_ir_instrs that save_ccr writes,
// after ccr_validate_i32_fields. The loader builds the same mirror from the file,
// so both processes call compute_entries on identical inputs and produce the same
// ENT data. type_id/flags come from the ccr_types.cr side buffers, which Task 3
// derives from the same save-time type state.
fn populate_nod_objects():
    g_v7_nod_sem = alloc((g_ir_instr_count + 8) * ESZ_NOD_SEM)
    g_v7_nod_count = g_ir_instr_count
    ii : ., mut = 0
    loop:
        if ii >= g_ir_instr_count:
            break
        cell_store32(g_v7_nod_sem, ii * ESZ_NOD_SEM + OFF_NS_OP, iri_op(ii))
        cell_store32(g_v7_nod_sem, ii * ESZ_NOD_SEM + OFF_NS_DEST, iri_dest(ii))
        cell_store(g_v7_nod_sem, ii * ESZ_NOD_SEM + OFF_NS_S1, iri_s1(ii))
        cell_store32(g_v7_nod_sem, ii * ESZ_NOD_SEM + OFF_NS_S2, iri_s2(ii))
        cell_store32(g_v7_nod_sem, ii * ESZ_NOD_SEM + OFF_NS_S3, iri_s3(ii))
        tid0 : ., mut = -1
        if ii < g_ccr_nod_type_count:
            tid0 = buf_read_i32(g_ccr_nod_type, ii * 4)
        fl0 : ., mut = 0
        if ii < g_ccr_nod_flags_count:
            fl0 = buf_read_u32(g_ccr_nod_flags, ii * 4)
        cell_store32(g_v7_nod_sem, ii * ESZ_NOD_SEM + OFF_NS_TYPE_ID, tid0)
        cell_store32(g_v7_nod_sem, ii * ESZ_NOD_SEM + OFF_NS_FLAGS, fl0)
        ii = ii + 1

// --- Save（写侧与 calc 侧一致；段表规范序、段体连续）---

fn save_ccr(path: string) -> int:
    // The wire format stores the checked fields as signed i32. Refuse to emit a
    // lossy file instead of letting w32 keep only the low bits.
    if ccr_validate_i32_fields() == 0:
        return -1

    // ENT data is computed first. The corec writer calls compute_live_ranges(),
    // which calls compute_entries per function and fills the in-memory 24B
    // half-open table g_ir_entries, g_entry_count, and the per-function entry
    // block bounds g_ir_func_entry_start/count. The corearch verifier and
    // allocator call the same kernel. The file ENT section is the verification
    // and semantic source; the half-open conversion live_end + 1 happens at the
    // write site below.
    // Before compute, populate the NOD object mirror from g_ir_instrs. The loader
    // builds the same mirror, so ENT bytes match the loader's view.
    populate_nod_objects()
    compute_live_ranges()

    // EDG content is collected first because NOD adjacency and segment sizes
    // depend on it. g_df_edges is an in-memory head-inserted list; walking nodes
    // in order builds each node's contiguous out-edge range (first_edge is the
    // prefix sum).
    edge_counts := alloc((g_ir_instr_count + 8) * 8)
    edge_offs := alloc((g_ir_instr_count + 8) * 8)
    edge_total := ccr_collect_edges(edge_counts, edge_offs)
    if edge_total < 0:
        return -1
    edge_buf : string, mut = ""
    if edge_total > 0:
        edge_buf = alloc(edge_total * 8)
        ccr_fill_edge_buf(edge_buf, edge_offs)

    tsz := calc_ccr_size(edge_total)
    buf := alloc(tsz)
    pos : ., mut = 0

    // Header（16B）
    buf_write_u32(buf, pos, CCR_MAGIC)
    pos = pos + 4
    buf_write_u32(buf, pos, CCR_V10_VERSION)
    pos = pos + 4
    buf_write_u32(buf, pos, CCR_V10_SEG_COUNT)
    pos = pos + 4
    // Header flags describe the program, not the integer representation.
    // Raw-int build mode is a SYSTEM property and is passed to corearch via
    // --raw-int, never through this word.
    buf_write_u32(buf, pos, ccr_compute_header_flags())
    pos = pos + 4

    // 段体大小（与 calc_ccr_size 同一来源逐段一致；canonical order）
    s_str := ccr_str_seg_size()
    s_type := ccr_type_seg_size()      // 内容（缓冲长度）
    s_iface := ccr_iface_seg_size()    // 内容（缓冲长度）
    s_sym := ccr_sym_seg_size()
    s_nod := ccr_nod_seg_size()
    s_ent := ccr_ent_seg_size()
    s_reg := ccr_reg_seg_size()
    s_edg := ccr_edg_seg_size(edge_total)
    s_case := ccr_case_seg_size()

    // Seg table（9 × 12B；offset = 前段尾，从段表后起；规范序 tag 1..9）
    o_str : ., mut = 16 + CCR_V10_SEG_COUNT * 12
    o_type : ., mut = o_str + s_str
    o_iface : ., mut = o_type + s_type
    o_sym : ., mut = o_iface + s_iface
    o_nod : ., mut = o_sym + s_sym
    o_ent : ., mut = o_nod + s_nod
    o_reg : ., mut = o_ent + s_ent
    o_edg : ., mut = o_reg + s_reg
    o_case : ., mut = o_edg + s_edg

    buf_write_u32(buf, pos, CCR_V10_SEG_STR)
    buf_write_u32(buf, pos + 4, o_str)
    buf_write_u32(buf, pos + 8, s_str)
    pos = pos + 12
    buf_write_u32(buf, pos, CCR_V10_SEG_TYPE)
    buf_write_u32(buf, pos + 4, o_type)
    buf_write_u32(buf, pos + 8, s_type)
    pos = pos + 12
    buf_write_u32(buf, pos, CCR_V10_SEG_IFACE)
    buf_write_u32(buf, pos + 4, o_iface)
    buf_write_u32(buf, pos + 8, s_iface)
    pos = pos + 12
    buf_write_u32(buf, pos, CCR_V10_SEG_SYM)
    buf_write_u32(buf, pos + 4, o_sym)
    buf_write_u32(buf, pos + 8, s_sym)
    pos = pos + 12
    buf_write_u32(buf, pos, CCR_V10_SEG_NOD)
    buf_write_u32(buf, pos + 4, o_nod)
    buf_write_u32(buf, pos + 8, s_nod)
    pos = pos + 12
    buf_write_u32(buf, pos, CCR_V10_SEG_ENT)
    buf_write_u32(buf, pos + 4, o_ent)
    buf_write_u32(buf, pos + 8, s_ent)
    pos = pos + 12
    buf_write_u32(buf, pos, CCR_V10_SEG_REG)
    buf_write_u32(buf, pos + 4, o_reg)
    buf_write_u32(buf, pos + 8, s_reg)
    pos = pos + 12
    buf_write_u32(buf, pos, CCR_V10_SEG_EDG)
    buf_write_u32(buf, pos + 4, o_edg)
    buf_write_u32(buf, pos + 8, s_edg)
    pos = pos + 12
    buf_write_u32(buf, pos, CCR_V10_SEG_CASE)
    buf_write_u32(buf, pos + 4, o_case)
    buf_write_u32(buf, pos + 8, s_case)
    pos = pos + 12

    // === STR: strings ===
    buf_write_u32(buf, pos, g_str_count)
    pos = pos + 4
    si : ., mut = 0
    loop:
        if si >= g_str_count:
            break
        sl := istr_len(si)
        buf_write_u32(buf, pos, sl)
        pos = pos + 4
        ci : ., mut = 0
        loop:
            if ci >= sl:
                break
            cell_store_byte(buf, pos, str_load8(si, ci))
            pos = pos + 1
            ci = ci + 1
        si = si + 1

    // === TYPE(2): copy the prepared segment buffer. Content is built by
    // corec-only ccr_types.cr ccr_type_prepare_save; this file only copies it.
    // 缓冲含首字段 row_count，因此大小 == ccr_type_seg_size()（同一来源）。空缓冲 =
    // 未装填（调用点漏调 prepare），因此拒绝落盘：不得产出两小节缺席的
    // 半成品文件（判定约定；记录表恒含原生 9 行，空缓冲只可能是程序错误）。
    if g_ccr_type_seg_len <= 0:
        return -1
    ct : ., mut = 0
    loop:
        if ct >= g_ccr_type_seg_len:
            break
        cell_store_byte(buf, pos, cell_load_byte(g_ccr_type_seg, ct))
        pos = pos + 1
        ct = ct + 1

    // === IFACE(3): copy the prepared segment buffer. Content is built by
    // corec-only ccr_iface_populate and ccr_iface_seg_build in ccr_types.cr;
    // this file only copies it.
    // 缓冲含首字段 native_count，因此大小 == ccr_iface_seg_size()（同一来源）。空缓冲 =
    // 未装填（调用点漏调 prepare），因此拒绝落盘（不得产出五小节缺席的半成品；
    // 条目表恒 16 行，因此空缓冲只可能是程序错误，判定约定）。
    if g_ccr_iface_seg_len <= 0:
        return -1
    ict : ., mut = 0
    loop:
        if ict >= g_ccr_iface_seg_len:
            break
        cell_store_byte(buf, pos, cell_load_byte(g_ccr_iface_seg, ict))
        pos = pos + 1
        ict = ict + 1

    // === SYM: globals（16B each: name u32, type u32, init_val i64）===
    // The global record stores type, not var_idx: var_idx always equals the row
    // order because reg_one_global creates one var row per global and keeps row
    // order in lockstep. The check below rejects a mismatch, so a future layout
    // change cannot silently produce a file with the wrong row order. Global rows
    // are the prefix 0..G-1 of the var namespace.
    buf_write_u32(buf, pos, g_ir_global_count)
    pos = pos + 4
    gi : ., mut = 0
    loop:
        if gi >= g_ir_global_count:
            break
        if cell_load(g_ir_globals, gi * 24 + 8) != gi:
            return -1
        buf_write_u32(buf, pos, cell_load(g_ir_globals, gi * 24))
        pos = pos + 4     // name
        buf_write_u32(buf, pos, irv_type(gi))
        pos = pos + 4                   // type
        buf_write_i64(buf, pos, cell_load(g_ir_globals, gi * 24 + 16))
        pos = pos + 8 // init_val
        gi = gi + 1

    // === SYM: functions ===
    // Header 24B plus param_ents plus the var declaration area. The function
    // instruction range is derived from root_region span, and var_start/count are
    // derived from the declaration-area cursor. Variable rows are in creation
    // order, and the first param_count rows are parameters.
    // The guard is positional: each function declaration block must start at the
    // prefix sum (global rows plus previous function var counts), and blocks must
    // cover g_ir_vars without gaps. A count-only check cannot detect a block
    // shifted by one row when the total is unchanged; that would silently shift
    // file row order and corrupt the ENT var_id namespace. A mismatch means the
    // function was not emitted in order and the file is rejected.
    vcursor : ., mut = g_ir_global_count
    buf_write_u32(buf, pos, g_ir_func_count)
    pos = pos + 4
    fi : ., mut = 0
    loop:
        if fi >= g_ir_func_count:
            break
        froot := ccr_func_root_sg(fi)
        if froot < 0:
            return -1
        vc := cell_load(g_ir_func_var_count, fi * 8)
        vs := cell_load(g_ir_func_var_start, fi * 8)
        if vs != vcursor:
            return -1
        // 声明区起点 != 前缀累计 -> 记录顺序错位
        vcursor = vcursor + vc
        pc := cell_load(g_ir_func_param_count, fi * 8)
        if pc > vc:
            return -1
        // 条目块界实回填（内核 compute_live_ranges 已先行），函数条目
        // 块 = ENT 文件序连续段 [es, es+ec)（SYM func 与 REG 根记录同源双写；
        // loader 块对照消费：pcnt==0 ↔ -1、ffe == 块首、fle == 块末）
        es := cell_load(g_ir_func_entry_start, fi * 8)
        ec := cell_load(g_ir_func_entry_count, fi * 8)
        fe2 : ., mut = -1
        le2 : ., mut = -1
        if ec > 0:
            fe2 = es
            le2 = es + ec - 1
        buf_write_u32(buf, pos, cell_load(g_ir_func_name_idx, fi * 8))
        pos = pos + 4
        buf_write_u32(buf, pos, pc)
        pos = pos + 4
        buf_write_u32(buf, pos, cell_load(g_ir_func_ret_type, fi * 8))
        pos = pos + 4
        buf_write_i32(buf, pos, froot)
        pos = pos + 4
        buf_write_i32(buf, pos, fe2)
        pos = pos + 4
        buf_write_i32(buf, pos, le2)
        pos = pos + 4
        // param_ents 实回填：参数入参条目 = 该参数 var 的 def=-1 条目 id
        // （函数内被重定值/从未引用 -> -1；头注释 3.2 语义）。loader 只做
        // 界拒绝（pid < -1），与 ENT 的一致性由 Python 侧/测试网对照。
        pp : ., mut = 0
        loop:
            if pp >= pc:
                break
            buf_write_i32(buf, pos, ccr_param_entry_id(vs + pp, es, ec))
            pos = pos + 4
            pp = pp + 1
        // var 声明区（记录顺序声明，name/type；ENT存在即声明的名称/类型投影）
        buf_write_u32(buf, pos, vc)
        pos = pos + 4
        vv : ., mut = 0
        loop:
            if vv >= vc:
                break
            row := vs + vv
            if row < 0 || row >= g_ir_var_count:
                return -1
            buf_write_u32(buf, pos, irv_name(row))
            pos = pos + 4
            buf_write_u32(buf, pos, irv_type(row))
            pos = pos + 4
            vv = vv + 1
        fi = fi + 1
    if vcursor != g_ir_var_count:
        return -1
    // 末块未铺满命名空间 -> 洞

    // === SYM: string constants ===
    buf_write_u32(buf, pos, g_ir_str_const_count)
    pos = pos + 4
    sci : ., mut = 0
    loop:
        if sci >= g_ir_str_const_count:
            break
        buf_write_u32(buf, pos, cell_load(g_ir_str_consts, sci * 8))
        pos = pos + 4
        sci = sci + 1

    // === SYM: structs ===
    buf_write_u32(buf, pos, g_struct_count)
    pos = pos + 4
    sti : ., mut = 0
    loop:
        if sti >= g_struct_count:
            break
        fc := si_field_count(sti)
        buf_write_u32(buf, pos, si_name(sti))
        pos = pos + 4
        buf_write_u32(buf, pos, fc)
        pos = pos + 4
        fii : ., mut = 0
        loop:
            if fii >= fc:
                break
            buf_write_u32(buf, pos, si_field_name(sti, fii))
            pos = pos + 4
            buf_write_u32(buf, pos, si_field_type(sti, fii))
            pos = pos + 4
            fii = fii + 1
        sti = sti + 1

    // === SYM: enums ===
    buf_write_u32(buf, pos, g_enum_count)
    pos = pos + 4
    ei2 : ., mut = 0
    loop:
        if ei2 >= g_enum_count:
            break
        vc := ei_variant_count(ei2)
        buf_write_u32(buf, pos, ei_name(ei2))
        pos = pos + 4
        buf_write_u32(buf, pos, vc)
        pos = pos + 4
        vi2 : ., mut = 0
        loop:
            if vi2 >= vc:
                break
            tcnt := ei_variant_type_count(ei2, vi2)
            buf_write_u32(buf, pos, ei_variant_name(ei2, vi2))
            pos = pos + 4
            buf_write_u32(buf, pos, tcnt)
            pos = pos + 4
            tf : ., mut = 0
            loop:
                if tf >= tcnt:
                    break
                buf_write_u32(buf, pos, ei_variant_type(ei2, vi2, tf))
                pos = pos + 4
                tf = tf + 1
            vi2 = vi2 + 1
        ei2 = ei2 + 1

    // === SYM: opt_meta ===
    buf_write_u32(buf, pos, g_opt_meta_count)
    pos = pos + 4
    mi : ., mut = 0
    loop:
        if mi >= g_opt_meta_count:
            break
        mo := mi * OPT_META_STRIDE
        mk := cell_load32(g_opt_meta, mo)       // key (u8 padded to u64)
        md_len := cell_load32(g_opt_meta, mo + 4) // data length
        buf_write_u32(buf, pos, mk)
        pos = pos + 4
        buf_write_u32(buf, pos, md_len)
        pos = pos + 4
        di : ., mut = 0
        loop:
            if di >= md_len:
                break
            cell_store_byte(buf, pos, cell_load_byte(g_opt_meta, mo + 8 + di))
            pos = pos + 1
            di = di + 1
        mi = mi + 1

    // === NOD: instructions ===
    // 40B each. NOD id is file order and equals global instruction order. Each
    // record has the eight semantic fields plus first_edge and edge_count for the
    // adjacency range. src2/src3 never carry a width, stride, or byte extent:
    // IR_ALLOC_ARRAY's stride and IR_ADDR_INDEX's scale are target facts, and
    // IR_DEREF/IR_STORE_PTR store only the runtime-base reference. EDG is written
    // from edge_buf after the NOD body.
    buf_write_u32(buf, pos, g_ir_instr_count)
    pos = pos + 4
    ii : ., mut = 0
    loop:
        if ii >= g_ir_instr_count:
            break
        nop := iri_op(ii)
        buf_write_u32(buf, pos, nop)
        pos = pos + 4
        buf_write_i32(buf, pos, iri_dest(ii))
        pos = pos + 4
        // s1 is 64-bit so IR_CONST large int constants and float bit patterns are
        // not truncated to 32 bits.
        buf_write_i64(buf, pos, iri_s1(ii))
        pos = pos + 8
        ns2 : ., mut = iri_s2(ii)
        ns3 : ., mut = iri_s3(ii)
        if nop == IR_ALLOC_ARRAY:
            // element stride is a target fact; corearch reconstructs it
            ns2 = 0
            ns3 = 0
        else if nop == IR_ADDR_INDEX:
            // SIB scale exponent is a target fact; the instance fixes it
            ns3 = 0
        else if nop == IR_DEREF || nop == IR_STORE_PTR:
            // allocation byte size is a target fact; the semantic flag records
            // that a runtime bound exists and corearch recomputes the size
            ns3 = 0
        buf_write_i32(buf, pos, ns2)
        pos = pos + 4
        buf_write_i32(buf, pos, ns3)
        pos = pos + 4
        // type_id: TYPE row (-1 = none). flags: semantic node features only.
        tid1 : ., mut = -1
        if ii < g_ccr_nod_type_count:
            tid1 = buf_read_i32(g_ccr_nod_type, ii * 4)
        buf_write_i32(buf, pos, tid1)
        pos = pos + 4
        fl1 : ., mut = 0
        if ii < g_ccr_nod_flags_count:
            fl1 = buf_read_u32(g_ccr_nod_flags, ii * 4)
        buf_write_u32(buf, pos, fl1)
        pos = pos + 4
        buf_write_u32(buf, pos, cell_load(edge_offs, ii * 8))
        pos = pos + 4   // first_edge
        buf_write_u32(buf, pos, cell_load(edge_counts, ii * 8))
        pos = pos + 4 // edge_count
        ii = ii + 1

    // === ENT: entries（24B each；内存闭区间 -> 盘上：version 组内序数、live_end+1 半开）===
    // 版本序数：每 var 一张计数槽（var 全局槽 id 唯一属一个函数，组内序 = 全局序）
    buf_write_u32(buf, pos, g_entry_count)
    pos = pos + 4
    vcnt : string, mut = alloc((g_ir_var_count + 8) * 8)
    vz : ., mut = 0
    loop:
        if vz >= g_ir_var_count + 8:
            break
        cell_store(vcnt, vz * 8, 0)
        vz = vz + 1
    ej : ., mut = 0
    loop:
        if ej >= g_entry_count:
            break
        ev := ccr_ent_var(ej)
        ed := ccr_ent_def(ej)
        els := ccr_ent_ls(ej)
        ele := ccr_ent_le(ej)
        efl := ccr_ent_flags(ej)
        ord := cell_load(vcnt, ev * 8) + 1
        cell_store(vcnt, ev * 8, ord)
        buf_write_i32(buf, pos, ev)
        pos = pos + 4      // var_id
        buf_write_u32(buf, pos, ord)
        pos = pos + 4     // version（1-based）
        buf_write_i32(buf, pos, ed)
        pos = pos + 4      // def_nod（-1 = 无定值）
        buf_write_u32(buf, pos, els)
        pos = pos + 4     // live_start（含定值）
        buf_write_u32(buf, pos, ele + 1)
        pos = pos + 4 // live_end（半开 = 内存闭区间 +1）
        buf_write_u32(buf, pos, efl)
        pos = pos + 4     // flags；home 不属于 v10
        ej = ej + 1

    // === REG: regions ===
    // 24B each: {kind, parent, enter_nod, exit_nod, first_ent, last_ent}.
    // nstart and ncount are not stored; they derive from enter and exit. A region
    // with exit < enter is unclosed and is rejected.
    // first/last semantics: entries in the region have def_nod in [enter, exit).
    // Definition order keeps the file range contiguous. The root region
    // (kind=SG_FUNC, function k is the k-th root row) covers the whole function
    // entry block, including def=-1 parameter entries. No entries means -1.
    buf_write_u32(buf, pos, g_sg_count)
    pos = pos + 4
    rfunc : ., mut = -1  // 当前根 region 的函数号（记录顺序 = 压栈序）
    si2 : ., mut = 0
    loop:
        if si2 >= g_sg_count:
            break
        f := si2 * ESZ_SG
        sk2 := cell_load(g_sgs, f + OFF_SG_KIND)
        sen := cell_load(g_sgs, f + OFF_SG_ENTER)
        sex := cell_load(g_sgs, f + OFF_SG_EXIT)
        spa := cell_load(g_sgs, f + OFF_SG_PARENT)
        if sex < sen:
            return -1
        // 未闭合 -> ncount 不可派生
        if sk2 == SG_FUNC:
            rfunc = rfunc + 1
        if rfunc < 0 || rfunc >= g_ir_func_count:
            return -1
        // 记录顺序结构失配
        // 条目范围实回填（内核 compute_live_ranges 已先行），根 region
        // （SG_FUNC）= 整个函数条目块（含 def=-1 参数条目；与 SYM func
        // first/last 同源双写，loader 逐根记录对照）；嵌套 region = 定值点
        // def_nod in [enter, exit) 的条目段（块内定值点升序 -> 文件条目序连续
        // 一段；无 = -1）。头注释 3.5 语义：区间 = def_nod 归属，非全块。
        fe2 : ., mut = -1
        le2 : ., mut = -1
        bes := cell_load(g_ir_func_entry_start, rfunc * 8)
        bec := cell_load(g_ir_func_entry_count, rfunc * 8)
        if sk2 == SG_FUNC:
            if bec > 0:
                fe2 = bes
                le2 = bes + bec - 1
        else:
            kk : ., mut = 0
            loop:
                if kk >= bec:
                    break
                eid2 := bes + kk
                ed2 := ccr_ent_def(eid2)
                if ed2 >= sen && ed2 < sex:
                    if fe2 < 0:
                        fe2 = eid2
                    le2 = eid2
                kk = kk + 1
        if sk2 == SG_FUNC:
            // 根 region span = 函数指令范围（REG = 文件里函数边界的唯一真源，
            // 与 func 表一致性校验，失配 = 内部状态漂移）
            is2 := cell_load(g_ir_func_instr_start, rfunc * 8)
            ic2 := cell_load(g_ir_func_instr_count, rfunc * 8)
            if sen != is2 || sex != is2 + ic2:
                return -1
        buf_write_i32(buf, pos, sk2)
        pos = pos + 4
        buf_write_i32(buf, pos, spa)
        pos = pos + 4
        buf_write_i32(buf, pos, sen)
        pos = pos + 4
        buf_write_i32(buf, pos, sex)
        pos = pos + 4
        buf_write_i32(buf, pos, fe2)
        pos = pos + 4
        buf_write_i32(buf, pos, le2)
        pos = pos + 4
        si2 = si2 + 1

    // === EDG: edges ===
    // 8B each: {to_nod u32, kind u32}. The source node is implicit: node i's
    // outgoing edges are the contiguous range [first_edge, first_edge+edge_count).
    // edge_buf holds the flat records from the collection pass, packed as
    // to + kind*2^32; this loop unpacks them into u32 pairs.
    buf_write_u32(buf, pos, edge_total)
    pos = pos + 4
    ei3 : ., mut = 0
    loop:
        if ei3 >= edge_total:
            break
        ev := cell_load(edge_buf, ei3 * 8)
        buf_write_u32(buf, pos, ev % 4294967296)
        pos = pos + 4   // to_nod
        buf_write_u32(buf, pos, ev / 4294967296)
        pos = pos + 4   // kind
        ei3 = ei3 + 1

    // === CASE: empty table for now (4B case_count = 0). CASE is last because it
    // may reference every NOD target once match lowering fills it in.
    buf_write_u32(buf, pos, 0)
    pos = pos + 4

    // Use syscall directly (write_file uses str_len which stops at null)
    fd := syscall3(2, path, 577, 420)  // open(O_WRONLY|O_CREAT|O_TRUNC, 0644)
    if fd < 0:
        return -1
    written : ., mut = 0
    written = syscall3(1, fd, buf, tsz)  // write(fd, buf, tsz)
    r2 := syscall3(3, fd, 0, 0)  // close(fd)
    if written != tsz:
        return -1
    return 0

//  测试钩子（corec ccr --inject-var-shift 测试钩子；真实构建路径永不调用）：
// func0 var 声明区起点左移 1 行（globals >= 1 时新块 [vs-1, vs-1+vc0) 恒留在
// 命名空间内，行首行被 globals 末行顶替、行尾少写 func0 末行）。Σ 计数级
// 检查（Σ func var_count == g_ir_var_count，总量守恒）察觉不到；位置级检查
// (vs == prefix sum) must reject the save; otherwise a future out-of-order
// function emission would silently shift row order.
fn inject_var_shift() -> int:
    if g_ir_func_count < 1:
        return 1
    vs := cell_load(g_ir_func_var_start, 0)
    if vs < 1:
        return 1
    // 无 globals 行可借位 -> 注入前置不满足
    cell_store(g_ir_func_var_start, 0, vs - 1)
    return 0

// Load: v10 only. Validate the header and canonical segment table, reject
// out-of-range segments, and reject every version other than 0x000A0000 (v9 is
// rejected outright). The table has 9 segments in canonical order. All nine are
// required; ENT may carry an empty record table but its 4B count is present.
// Loader output is semantic objects plus guards. The linear NOD-to-g_ir_instrs
// rebuild is outside this file: build_linear_schedule in regalloc.cr is called by
// corearch.cr or src/targets/x86_64/linux/elf/main.cr after a successful load.
// Parse order (canonical file order, forward-only cursor):
// STR -> TYPE (rebuild type rows/terms and the term index) -> IFACE (rebuild the
// interface tables from STR indices and TYPE/term domains) -> SYM (globals and
// funcs rebuild the var namespace; fn_meta stays local for ENT/REG) -> NOD (40B;
// eight semantic fields into g_v7_nod_sem, adjacency into g_v7_nod_meta) -> ENT
// (24B to the in-memory table; version dropped, half-open live_end closed) -> REG
// (derive nstart/ncount and function instruction bounds) -> EDG (contiguous
// ranges and topology checks into g_v7_edges) -> CASE.
// The segment table validates boundaries and contiguity only. Every body is
// consumed from the running cursor; there is no seek back to a table offset.
// Guards use only NOD counts, adjacency, and REG-derived bounds; the loader does
// not depend on the linear stream.

fn load_ccr(data: string, fsize: int) -> int:
    if fsize < 16:
        return -1
    // header

    pos : ., mut = 0

    // Magic
    magic := buf_read_u32(data, pos)
    pos = pos + 4
    if magic != CCR_MAGIC:
        return -1

    // Version: v10 only, with no compatibility or conversion path.
    ver := buf_read_u32(data, pos)
    pos = pos + 4
    if ver != CCR_V10_VERSION:
        return -1

    // Seg count + header flags
    seg_cnt := buf_read_u32(data, pos)
    pos = pos + 4
    rsv := buf_read_u32(data, pos)
    pos = pos + 4
    if seg_cnt != CCR_V10_SEG_COUNT:
        return -1
    // Only PORTABLE/SYSTEM/CONCURRENT (bits 0..2) are defined; reserved bits
    // must be zero. PORTABLE excludes SYSTEM; CONCURRENT implies SYSTEM.
    if rsv > CCR_FLAG_KNOWN_MASK:
        return -1
    if (rsv % 2 == 1) && ((rsv / CCR_FLAG_SYSTEM) % 2 == 1):
        return -1
    if (rsv % 2 == 1) && ((rsv / CCR_FLAG_CONCURRENT) % 2 == 1):
        return -1
    if ((rsv / CCR_FLAG_CONCURRENT) % 2 == 1) && ((rsv / CCR_FLAG_SYSTEM) % 2 == 0):
        return -1
    if seg_cnt > (fsize - 16) / 12:
        return -1

    // Segment table: canonical layout. tag must equal the row number (1..9),
    // offset must equal the previous segment end, and segments must stay in
    // bounds. The loader rejects any non-canonical layout.
    seg_off1 : ., mut = 0
    seg_off2 : ., mut = 0
    seg_off3 : ., mut = 0
    seg_off4 : ., mut = 0
    seg_off5 : ., mut = 0
    seg_off6 : ., mut = 0
    seg_off7 : ., mut = 0
    seg_off8 : ., mut = 0
    seg_off9 : ., mut = 0
    seg_end1 : ., mut = 0
    seg_end2 : ., mut = 0
    seg_end3 : ., mut = 0
    seg_end4 : ., mut = 0
    seg_end5 : ., mut = 0
    seg_end6 : ., mut = 0
    seg_end7 : ., mut = 0
    seg_end8 : ., mut = 0
    seg_end9 : ., mut = 0
    have1 : ., mut = 0
    have2 : ., mut = 0
    have3 : ., mut = 0
    have4 : ., mut = 0
    have5 : ., mut = 0
    have6 : ., mut = 0
    have7 : ., mut = 0
    have8 : ., mut = 0
    have9 : ., mut = 0
    cursor : ., mut = 16 + seg_cnt * 12
    ri : ., mut = 0
    loop:
        if ri >= seg_cnt:
            break
        if !ccr_has_bytes(pos, 12, fsize):
            return -1
        tg := buf_read_u32(data, pos)
        pos = pos + 4
        soff := buf_read_u32(data, pos)
        pos = pos + 4
        ssz := buf_read_u32(data, pos)
        pos = pos + 4
        if tg < 1 || tg > CCR_V10_SEG_COUNT:
            return -1
        if tg != ri + 1:
            return -1
        // 规范 tag 序
        if soff != cursor:
            return -1
        // 段体连续
        if ssz > fsize - cursor:
            return -1
        // 越界拒绝
        // 重复 tag 防御（规范序下不可能，双保险）
        if tg == 1:
            if have1 != 0:
                return -1
            seg_off1 = soff
            seg_end1 = soff + ssz
            have1 = 1
        if tg == 2:
            if have2 != 0:
                return -1
            seg_off2 = soff
            seg_end2 = soff + ssz
            have2 = 1
        if tg == 3:
            if have3 != 0:
                return -1
            seg_off3 = soff
            seg_end3 = soff + ssz
            have3 = 1
        if tg == 4:
            if have4 != 0:
                return -1
            seg_off4 = soff
            seg_end4 = soff + ssz
            have4 = 1
        if tg == 5:
            if have5 != 0:
                return -1
            seg_off5 = soff
            seg_end5 = soff + ssz
            have5 = 1
        if tg == 6:
            if have6 != 0:
                return -1
            seg_off6 = soff
            seg_end6 = soff + ssz
            have6 = 1
        if tg == 7:
            if have7 != 0:
                return -1
            seg_off7 = soff
            seg_end7 = soff + ssz
            have7 = 1
        if tg == 8:
            if have8 != 0:
                return -1
            seg_off8 = soff
            seg_end8 = soff + ssz
            have8 = 1
        if tg == 9:
            if have9 != 0:
                return -1
            seg_off9 = soff
            seg_end9 = soff + ssz
            have9 = 1
        cursor = soff + ssz
        ri = ri + 1

    // All nine segments are required in v10. TYPE/IFACE are content segments;
    // ENT/REG/EDG/CASE are structural. There is no "absent = empty" variant.
    if have1 == 0 || have2 == 0 || have3 == 0 || have4 == 0 || have5 == 0:
        return -1
    if have6 == 0 || have7 == 0 || have8 == 0 || have9 == 0:
        return -1
    if cursor != fsize:
        return -1
    // 无尾随字节（最后一段尾 == 文件大小）

    // 状态重置（corearch 单次加载；保持可重入）
    g_str_count = 0
    g_ir_var_count = 0
    g_ir_instr_count = 0
    g_ir_func_count = 0
    g_ir_str_const_count = 0
    g_struct_count = 0
    g_enum_count = 0
    g_sg_count = 0
    g_ir_global_count = 0
    g_opt_meta_count = 0
    g_entry_count = 0
    g_v7_edge_count = 0
    g_v7_nod_count = 0   // NOD 对象缓冲计数（NOD 段载入后置位）
    // TYPE 段有真实内存表（g_types 记录表 + 项层 g_type_terms/
    // g_tt_index），复位在 TYPE 段解析处（记录表大小随段内容，且需与项层 memo
    // 同步作废；见该段注释）。
    // IFACE 段同理有真实内存表（g_iface_entries/g_iface_shape_*/
    // g_ifaces/g_impl_for/g_methods），计数复位在此（表缓冲随段内容重建；
    // g_iface_registry_ok 清 0 = 表未建立，本段解析末尾置 1 = 段真源）。
    g_iface_count = 0
    g_iface_entry_count = 0
    g_iface_registry_ok = 0
    g_iface_shape_count = 0
    g_impl_for_count = 0
    g_method_count = 0

    // The table walk consumed exactly 16 + seg_cnt*12 bytes, so `pos` is
    // already at the first body (tag STR). Every block below continues from this
    // running cursor; the segment table only supplies boundary ends.
    // === STR: strings ===
    if !ccr_has_bytes(pos, 4, seg_end1):
        return -1
    str_cnt := buf_read_u32(data, pos)
    pos = pos + 4
    si : ., mut = 0
    loop:
        if si >= str_cnt:
            break
        if !ccr_has_bytes(pos, 4, seg_end1):
            return -1
        sl := buf_read_u32(data, pos)
        pos = pos + 4
        if !ccr_has_bytes(pos, sl, seg_end1):
            return -1
        // Allocate buffer for string content
        s := alloc(sl + 1)
        ci : ., mut = 0
        loop:
            if ci >= sl:
                break
            cell_store_byte(s, ci, cell_load_byte(data, pos))
            pos = pos + 1
            ci = ci + 1
        cell_store_byte(s, sl, 0)
        str_intern(s)
        si = si + 1
    if pos != seg_end1:
        return -1

    // === TYPE(2)：类型信息===
    //  字节：row_count -> 记录表（24B/条）-> term_count -> 项 DAG（40B/条；哈希
    // 不落盘、本处 tt_hash5 重算）。重建 = g_types 行 + g_type_terms 项 +
    // g_tt_index 索引重放（grow_tt_index -> tt_reindex）。
    // 逐条校验（违规 = 拒绝，不得当作空表或截断表，判定约定 C.5-3）：
    //   1 计数/长度自洽（计数 × 记录尺寸 <= 段余量）；2 段体恰两小节（行走完
    //   == seg_end2，无尾随字节）；3 tag in 0..10（TT_*）+ a..d >= -1；4 子项引用
    //   -1 或 < 自身行号（拓扑无环；标注槽按 tag 分派跳过，字段表见
    //   ccr_type_term_ref_ok，ATOM 的 b = 自类型表记录编号可达数千，不得误拒）。
    // 复位：记录表/项层（含引擎预算/memo/lits，见 tt_layer_reset 注记）全部作废
    // 重建（旧行号语义的缓存一并清；记录表大小随段内容，此处为唯一复位点）。
    // corearch 侧无桥接/checker 层：记录表 = 数据（消费者 = --dump-types 通道 +
    // 未来判定原语），本处不做语义解释。
    g_type_count = 0
    tt_layer_reset()
    if !ccr_has_bytes(pos, 4, seg_end2):
        return -1
    trow_cnt := buf_read_u32(data, pos)
    pos = pos + 4
    if trow_cnt > (seg_end2 - pos) / ESZ_TYPE_ROW:
        return -1
    grow_types(trow_cnt)
    trow : ., mut = 0
    loop:
        if trow >= trow_cnt:
            break
        if !ccr_has_bytes(pos, ESZ_TYPE_ROW, seg_end2):
            return -1
        cell_store(g_types, trow * ESZ_TYPE_ROW + OFF_TR_KIND, buf_read_i64(data, pos))
        pos = pos + 8
        cell_store(g_types, trow * ESZ_TYPE_ROW + OFF_TR_DATA, buf_read_i64(data, pos))
        pos = pos + 8
        cell_store(g_types, trow * ESZ_TYPE_ROW + OFF_TR_EXTRA, buf_read_i64(data, pos))
        pos = pos + 8
        trow = trow + 1
    g_type_count = trow_cnt
    if !ccr_has_bytes(pos, 4, seg_end2):
        return -1
    tterm_cnt := buf_read_u32(data, pos)
    pos = pos + 4
    if tterm_cnt > (seg_end2 - pos) / ESZ_TYPE_TERM_DISK:
        return -1
    grow_type_terms(tterm_cnt + 1)
    tj : ., mut = 0
    loop:
        if tj >= tterm_cnt:
            break
        if !ccr_has_bytes(pos, ESZ_TYPE_TERM_DISK, seg_end2):
            return -1
        ttag := buf_read_i64(data, pos)
        pos = pos + 8
        ta := buf_read_i64(data, pos)
        pos = pos + 8
        tb := buf_read_i64(data, pos)
        pos = pos + 8
        tc2 := buf_read_i64(data, pos)
        pos = pos + 8
        td := buf_read_i64(data, pos)
        pos = pos + 8
        if ttag < 0 || ttag > TT_CONS:
            return -1
        if ta < -1 || tb < -1 || tc2 < -1 || td < -1:
            return -1
        if ccr_type_term_ref_ok(ttag, ta, tb, tc2, td, tj) == 0:
            return -1
        cell_store(g_type_terms, tj * ESZ_TYPE_TERM + OFF_TT_TAG, ttag)
        cell_store(g_type_terms, tj * ESZ_TYPE_TERM + OFF_TT_A, ta)
        cell_store(g_type_terms, tj * ESZ_TYPE_TERM + OFF_TT_B, tb)
        cell_store(g_type_terms, tj * ESZ_TYPE_TERM + OFF_TT_C, tc2)
        cell_store(g_type_terms, tj * ESZ_TYPE_TERM + OFF_TT_D, td)
        cell_store(g_type_terms, tj * ESZ_TYPE_TERM + OFF_TT_HASH, tt_hash5(ttag, ta, tb, tc2, td))
        g_type_term_count = tj + 1
        tj = tj + 1
    if pos != seg_end2:
        return -1
    // 段体恰两小节（无尾随字节）
    grow_tt_index(g_type_term_count + 1)        // 索引重建（cap 已清零 -> 必走重建）

    // === IFACE(3)：接口数据===
    // 重建 = g_iface_entries（条目表；并置 g_iface_registry_ok = 1，段 = corearch
    // 侧真源，防常量表覆盖段内容）+ g_iface_shape_names/terms + g_ifaces
    // （ESZ_IFACEINFO 布局；corearch 侧无 AST，因此节点槽恒 -1、项槽 = 段值）
    // + g_impl_for + g_methods。
    // 逐条校验（违规 = 拒绝；判定约定 C.5-3，不得当作空表或截断表）：
    //   1 五小节计数/长度自洽（计数 × 记录尺寸 <= 段余量）+ 行走完 == seg_end3（无尾随）；
    //   2 native_count == IFACE_ENTRY_COUNT（表内容 = 常量表，计数漂移 = 损坏）；
    //   3 跨段引用域：name_ni/type_ni/method_ni/mangled_ni in [0, g_str_count)（STR
    //      段先于本段解析）；ti_row in {-1} ∪ [0, g_type_count)；term in {-1} ∪ [0, tt_count())
    //      （TYPE(2) 段先于本段解析，因此两域已建立）；
    //   4 结构域：ak in 0..AK_NULL、method_count <= MAX_IFACE_METHODS、
    //      param_count <= MAX_IFACE_METHOD_PARAMS、self_mode in 0..3。
    // IFACE 段 = 纯信息（不参与 ELF 发射）；本段解析失败 = 整体拒绝（load_ccr -1）。
    if !ccr_has_bytes(pos, 4, seg_end3):
        return -1
    ifc_nat := buf_read_u32(data, pos)
    pos = pos + 4
    if ifc_nat != IFACE_ENTRY_COUNT:
        return -1
    if !ccr_has_bytes(pos, ifc_nat * 24, seg_end3):
        return -1
    g_iface_entries = alloc(ifc_nat * ESZ_IFACE_ENTRY)
    ifr : ., mut = 0
    loop:
        if ifr >= ifc_nat:
            break
        fak := buf_read_i32(data, pos)
        pos = pos + 4
        fti := buf_read_i32(data, pos)
        pos = pos + 4
        fname := buf_read_i32(data, pos)
        pos = pos + 4
        flit := buf_read_i32(data, pos)
        pos = pos + 4
        fops := buf_read_i64(data, pos)
        pos = pos + 8
        if fak < 0 || fak > AK_NULL:
            return -1
        // 原子类域
        if fti < -1 || fti >= g_type_count:
            return -1
        // 类型行引用域（跨段）
        if fname < 0 || fname >= g_str_count:
            return -1
        // 名字引用域（跨段）
        if flit < -1:
            return -1
        fo2 := ifr * ESZ_IFACE_ENTRY
        cell_store(g_iface_entries, fo2 + OFF_IE_AK, fak)
        cell_store(g_iface_entries, fo2 + OFF_IE_TI, fti)
        cell_store(g_iface_entries, fo2 + OFF_IE_NAME, fname)
        cell_store(g_iface_entries, fo2 + OFF_IE_LIT, flit)
        cell_store(g_iface_entries, fo2 + OFF_IE_OPS, fops)
        ifr = ifr + 1
    g_iface_entry_count = ifc_nat
    g_iface_registry_ok = 1

    // 2 横切形状（名 ni + 形状项）
    if !ccr_has_bytes(pos, 4, seg_end3):
        return -1
    ifc_shn := buf_read_u32(data, pos)
    pos = pos + 4
    if ifc_shn > (seg_end3 - pos) / 8:
        return -1
    iface_shape_grow(ifc_shn)
    ifs : ., mut = 0
    loop:
        if ifs >= ifc_shn:
            break
        sname := buf_read_i32(data, pos)
        pos = pos + 4
        sterm := buf_read_i32(data, pos)
        pos = pos + 4
        if sname < 0 || sname >= g_str_count:
            return -1
        if sterm < 0 || sterm >= tt_count():
            return -1
        // 项引用域（跨段）
        cell_store(g_iface_shape_names, ifs * 8, sname)
        cell_store(g_iface_shape_terms, ifs * 8, sterm)
        ifs = ifs + 1
    g_iface_shape_count = ifc_shn

    // 3 用户接口（头 16B + 方法 80B × method_count）
    if !ccr_has_bytes(pos, 4, seg_end3):
        return -1
    ifc_usn := buf_read_u32(data, pos)
    pos = pos + 4
    if ifc_usn > (seg_end3 - pos) / 16:
        return -1
    grow_ifaces(ifc_usn)
    ifu : ., mut = 0
    loop:
        if ifu >= ifc_usn:
            break
        if !ccr_has_bytes(pos, 16, seg_end3):
            return -1
        uname := buf_read_i32(data, pos)
        pos = pos + 4
        umc := buf_read_i32(data, pos)
        pos = pos + 4
        ugc := buf_read_i32(data, pos)
        pos = pos + 4
        pos = pos + 4                                                    // pad（预留）
        if uname < 0 || uname >= g_str_count:
            return -1
        if umc < 0 || umc > MAX_IFACE_METHODS:
            return -1
        if ugc < 0:
            return -1
        if !ccr_has_bytes(pos, umc * 80, seg_end3):
            return -1
        ub := ifu * ESZ_IFACEINFO
        // 先清零整条记录（防上轮残留；节点槽/项槽的初值 = -1 由下方逐槽写）
        uz : ., mut = 0
        loop:
            if uz >= ESZ_IFACEINFO:
                break
            cell_store8(g_ifaces, ub + uz, 0)
            uz = uz + 1
        cell_store(g_ifaces, ub + OFF_IF_NAME, uname)
        cell_store(g_ifaces, ub + OFF_IF_METHOD_COUNT, umc)
        cell_store(g_ifaces, ub + OFF_IF_GENERIC_COUNT, ugc)
        ium : ., mut = 0
        loop:
            if ium >= umc:
                break
            mb := ub + OFF_IF_METHODS + ium * ESZ_IFMETHOD
            mname := buf_read_i32(data, pos)
            pos = pos + 4
            mpc := buf_read_i32(data, pos)
            pos = pos + 4
            msm := buf_read_i32(data, pos)
            pos = pos + 4
            mrt := buf_read_i32(data, pos)
            pos = pos + 4
            if mname < 0 || mname >= g_str_count:
                return -1
            if mpc < 0 || mpc > MAX_IFACE_METHOD_PARAMS:
                return -1
            if msm < 0 || msm > 3:
                return -1
            if mrt < -1 || mrt >= tt_count():
                return -1
            // 项引用域（跨段）
            cell_store(g_ifaces, mb + OFF_IFM_NAME, mname)
            cell_store(g_ifaces, mb + OFF_IFM_PARAM_COUNT, mpc)
            cell_store(g_ifaces, mb + OFF_IFM_SELF_MODE, msm)
            cell_store(g_ifaces, mb + OFF_IFM_RET_TERM, mrt)
            cell_store(g_ifaces, mb + OFF_IFM_RET_NODE, -1)    // corearch 无 AST，因此节点槽恒 -1
            mq : ., mut = 0
            loop:
                if mq >= MAX_IFACE_METHOD_PARAMS:
                    break
                mt := buf_read_i32(data, pos)
                pos = pos + 4
                if mt < -1 || mt >= tt_count():
                    return -1
                // 项引用域（跨段）
                cell_store(g_ifaces, mb + OFF_IFM_PARAM_TERMS + mq * 8, mt)
                cell_store(g_ifaces, mb + OFF_IFM_PARAM_NODES + mq * 8, -1)     // 节点槽恒 -1
                mq = mq + 1
            mp : ., mut = 0
            loop:
                if mp >= MAX_IFACE_METHOD_PARAMS:
                    break
                mc2 := buf_read_i32(data, pos)
                pos = pos + 4            // 裸码（信息）
                if mc2 < -1:
                    return -1
                cell_store(g_ifaces, mb + OFF_IFM_PARAM_TYPES + mp * 8, mc2)
                mp = mp + 1
            ium = ium + 1
        ifu = ifu + 1
    g_iface_count = ifc_usn

    // 4 impl 边（g_impl_for：{trait_ni, type_ni}，声明元数据）
    if !ccr_has_bytes(pos, 4, seg_end3):
        return -1
    ifc_imp := buf_read_u32(data, pos)
    pos = pos + 4
    if ifc_imp > (seg_end3 - pos) / 8:
        return -1
    grow_impl_for(ifc_imp)
    ifi : ., mut = 0
    loop:
        if ifi >= ifc_imp:
            break
        itr := buf_read_i32(data, pos)
        pos = pos + 4
        ity := buf_read_i32(data, pos)
        pos = pos + 4
        if itr < 0 || itr >= g_str_count:
            return -1
        if ity < 0 || ity >= g_str_count:
            return -1
        cell_store(g_impl_for, ifi * 16, itr)
        cell_store(g_impl_for, ifi * 16 + 8, ity)
        ifi = ifi + 1
    g_impl_for_count = ifc_imp

    // 5 方法表（g_methods：{type_ni, method_ni, mangled_ni}，iface_find_method 数据源）
    if !ccr_has_bytes(pos, 4, seg_end3):
        return -1
    ifc_met := buf_read_u32(data, pos)
    pos = pos + 4
    if ifc_met > (seg_end3 - pos) / 12:
        return -1
    grow_methods(ifc_met)
    ifm : ., mut = 0
    loop:
        if ifm >= ifc_met:
            break
        mtn := buf_read_i32(data, pos)
        pos = pos + 4
        mmn := buf_read_i32(data, pos)
        pos = pos + 4
        mmg := buf_read_i32(data, pos)
        pos = pos + 4
        if mtn < 0 || mtn >= g_str_count:
            return -1
        if mmn < 0 || mmn >= g_str_count:
            return -1
        if mmg < 0 || mmg >= g_str_count:
            return -1
        cell_store(g_methods, ifm * 24, mtn)
        cell_store(g_methods, ifm * 24 + 8, mmn)
        cell_store(g_methods, ifm * 24 + 16, mmg)
        ifm = ifm + 1
    g_method_count = ifc_met

    if pos != seg_end3:
        return -1
    // 五小节行走完 == 段体（无尾随字节）

    // === SYM: globals（16B each: name u32, type u32, init_val i64）===
    // var 命名空间重建（流式）：全局行 = 记录序 0..G-1（行名/型随本记录携带，
    // var rows are the same source); id = row order. Function declaration areas
    // follow in row order.
    if !ccr_has_bytes(pos, 4, seg_end4):
        return -1
    gc := buf_read_u32(data, pos)
    pos = pos + 4
    if gc > (seg_end4 - seg_off4) / ESZ_GLOBAL_DISK:
        return -1
    grow_ir_globals(gc)
    gi : ., mut = 0
    loop:
        if gi >= gc:
            break
        if !ccr_has_bytes(pos, ESZ_GLOBAL_DISK, seg_end4):
            return -1
        gname_ni := buf_read_u32(data, pos)
        pos = pos + 4
        gtype := buf_read_u32(data, pos)
        pos = pos + 4
        ginit_val := buf_read_i64(data, pos)
        pos = pos + 8
        grow_ir_vars(g_ir_var_count + 1)
        gvar := g_ir_var_count
        irv_set_name(gvar, gname_ni)
        irv_set_id(gvar, gvar)
        irv_set_type(gvar, gtype)
        g_ir_var_count = gvar + 1
        cell_store(g_ir_globals, gi * 24, gname_ni)
        cell_store(g_ir_globals, gi * 24 + 8, gvar)
        cell_store(g_ir_globals, gi * 24 + 16, ginit_val)
        g_ir_global_count = gi + 1
        gi = gi + 1

    // === SYM: funcs（24B 头 + param_ents + var 声明区）===
    // 头字段 = spec 3.2：name/param_count/ret_type/root_region（REG 记录 id）/
    // first_ent/last_ent（本函数条目文件范围）。instr/var 范围不落盘：instr =
    // root_region span（REG 段解析后回填），var_start = 声明区记录顺序游标。
    if !ccr_has_bytes(pos, 4, seg_end4):
        return -1
    func_cnt := buf_read_u32(data, pos)
    pos = pos + 4
    if func_cnt > (seg_end4 - pos) / ESZ_FUNC_HEAD_DISK:
        return -1
    grow_ir_func_meta(func_cnt)
    // func 记录临时元数据（REG 段回填/ENT 块界校验用）：{root i64, first i64, last i64}
    fn_meta := alloc((func_cnt + 8) * 24)
    fi : ., mut = 0
    loop:
        if fi >= func_cnt:
            break
        if !ccr_has_bytes(pos, ESZ_FUNC_HEAD_DISK, seg_end4):
            return -1
        fname := buf_read_u32(data, pos)
        pos = pos + 4
        fpc := buf_read_u32(data, pos)
        pos = pos + 4
        fret := buf_read_u32(data, pos)
        pos = pos + 4
        froot := buf_read_i32(data, pos)
        pos = pos + 4
        ffe := buf_read_i32(data, pos)
        pos = pos + 4
        fle := buf_read_i32(data, pos)
        pos = pos + 4
        if froot < 0:
            return -1
        // 每函数必有根 region（df_begin_func）
        if ffe < -1 || fle < -1 || (ffe == -1) != (fle == -1):
            return -1
        cell_store(g_ir_func_name_idx, fi * 8, fname)
        cell_store(g_ir_func_param_count, fi * 8, fpc)
        cell_store(g_ir_func_ret_type, fi * 8, fret)
        cell_store(fn_meta, fi * 24, froot)
        cell_store(fn_meta, fi * 24 + 8, ffe)
        cell_store(fn_meta, fi * 24 + 16, fle)
        // param_ents（i32 each；内存无消费者，只做越界拒绝）
        pj : ., mut = 0
        loop:
            if pj >= fpc:
                break
            if !ccr_has_bytes(pos, 4, seg_end4):
                return -1
            pid := buf_read_i32(data, pos)
            pos = pos + 4
            if pid < -1:
                return -1
            pj = pj + 1
        // var 声明区（记录顺序 = 创建序，前 param_count 个 = 参数）
        if !ccr_has_bytes(pos, 4, seg_end4):
            return -1
        fvc := buf_read_u32(data, pos)
        pos = pos + 4
        if fpc > fvc:
            return -1
        if fvc > (seg_end4 - pos) / ESZ_VARDECL_DISK:
            return -1
        fvs2 := g_ir_var_count
        cell_store(g_ir_func_var_start, fi * 8, fvs2)
        dj : ., mut = 0
        loop:
            if dj >= fvc:
                break
            if !ccr_has_bytes(pos, ESZ_VARDECL_DISK, seg_end4):
                return -1
            dname := buf_read_u32(data, pos)
            pos = pos + 4
            dtype := buf_read_u32(data, pos)
            pos = pos + 4
            grow_ir_vars(g_ir_var_count + 1)
            drow := g_ir_var_count
            irv_set_name(drow, dname)
            irv_set_id(drow, drow)
            irv_set_type(drow, dtype)
            g_ir_var_count = drow + 1
            dj = dj + 1
        if g_ir_var_count - fvs2 != fvc:
            return -1
        cell_store(g_ir_func_var_count, fi * 8, fvc)
        g_ir_func_count = fi + 1
        fi = fi + 1

    // === SYM: string constants（4B each）===
    if !ccr_has_bytes(pos, 4, seg_end4):
        return -1
    str_const_cnt := buf_read_u32(data, pos)
    pos = pos + 4
    if str_const_cnt > (seg_end4 - seg_off4) / 4:
        return -1
    grow_ir_str_consts(str_const_cnt)
    sci : ., mut = 0
    loop:
        if sci >= str_const_cnt:
            break
        if !ccr_has_bytes(pos, 4, seg_end4):
            return -1
        scv := buf_read_u32(data, pos)
        pos = pos + 4
        cell_store(g_ir_str_consts, sci * 8, scv)
        g_ir_str_const_count = sci + 1
        sci = sci + 1

    // === SYM: structs ===
    if !ccr_has_bytes(pos, 4, seg_end4):
        return -1
    struct_cnt := buf_read_u32(data, pos)
    pos = pos + 4
    if struct_cnt > (seg_end4 - seg_off4) / 8:
        return -1
    grow_structs(struct_cnt)
    g_struct_count = struct_cnt
    sti : ., mut = 0
    loop:
        if sti >= struct_cnt:
            break
        if !ccr_has_bytes(pos, 8, seg_end4):
            return -1
        sname_ni := buf_read_u32(data, pos)
        pos = pos + 4
        fc := buf_read_u32(data, pos)
        pos = pos + 4
        // 字段数无硬上限（侧表承载），因此旧 MAX_STRUCT_FIELDS
        // 读回检查与 16 槽清零循环一并删除；段界核算保留（fc 越段，因此拒绝，判定约定）。
        if fc > (seg_end4 - pos) / 8:
            return -1
        cell_store(g_structs, sti * ESZ_STRUCTINFO + OFF_SI_NAME, sname_ni)
        cell_store(g_structs, sti * ESZ_STRUCTINFO + OFF_SI_FIELD_COUNT, fc)
        si_set_field_base(sti, g_si_f_used)
        // Zero generic slots
        cell_store(g_structs, sti * ESZ_STRUCTINFO + OFF_SI_GENERIC_COUNT, 0)
        zgi : ., mut = 0
        loop:
            if zgi >= 4:
                break
            cell_store(g_structs, sti * ESZ_STRUCTINFO + OFF_SI_GENERIC_NAMES + zgi * 8, 0)
            zgi = zgi + 1
        // Write field data（侧表；磁盘布局逐字段变长，格式不变）
        fi2 : ., mut = 0
        loop:
            if fi2 >= fc:
                break
            fn_ni := buf_read_u32(data, pos)
            pos = pos + 4
            ft := buf_read_u32(data, pos)
            pos = pos + 4
            si_set_field_name(sti, fi2, fn_ni)
            si_set_field_type(sti, fi2, ft)
            fi2 = fi2 + 1
        si_commit_fields(sti, fc)
        sti = sti + 1

    // === SYM: enums ===
    if !ccr_has_bytes(pos, 4, seg_end4):
        return -1
    enum_cnt := buf_read_u32(data, pos)
    pos = pos + 4
    if enum_cnt > (seg_end4 - seg_off4) / 8:
        return -1
    grow_enums(enum_cnt)
    g_enum_count = enum_cnt
    ei : ., mut = 0
    loop:
        if ei >= enum_cnt:
            break
        if !ccr_has_bytes(pos, 8, seg_end4):
            return -1
        ename_ni := buf_read_u32(data, pos)
        pos = pos + 4
        vc := buf_read_u32(data, pos)
        pos = pos + 4
        // 变体/携带值数无硬上限（侧表），因此两处旧检查与 16 槽清零
        // 循环删除；段界核算保留（判定约定）
        if vc > (seg_end4 - pos) / 8:
            return -1
        cell_store(g_enums, ei * ESZ_ENUMINFO + OFF_EI_NAME, ename_ni)
        cell_store(g_enums, ei * ESZ_ENUMINFO + OFF_EI_VARIANT_COUNT, vc)
        ei_set_variant_base(ei, g_ei_v_used)
        cell_store(g_enums, ei * ESZ_ENUMINFO + OFF_EI_GENERIC_COUNT, 0)
        zgi2 : ., mut = 0
        loop:
            if zgi2 >= 4:
                break
            cell_store(g_enums, ei * ESZ_ENUMINFO + OFF_EI_GENERIC_NAMES + zgi2 * 8, 0)
            zgi2 = zgi2 + 1
        // Write variant data
        vi3 : ., mut = 0
        loop:
            if vi3 >= vc:
                break
            vni := buf_read_u32(data, pos)
            pos = pos + 4
            tc := buf_read_u32(data, pos)
            pos = pos + 4
            if tc > (seg_end4 - pos) / 4:
                return -1
            ei_set_variant_name(ei, vi3, vni)
            ei_set_variant_type_count(ei, vi3, tc)
            tf : ., mut = 0
            loop:
                if tf >= tc:
                    break
                tval := buf_read_u32(data, pos)
                pos = pos + 4
                ei_set_variant_type(ei, vi3, tf, tval)
                tf = tf + 1
            vi3 = vi3 + 1
        ei = ei + 1

    // === SYM: opt_meta ===
    if !ccr_has_bytes(pos, 4, seg_end4):
        return -1
    mc := buf_read_u32(data, pos)
    pos = pos + 4
    mi : ., mut = 0
    loop:
        if mi >= mc:
            break
        if !ccr_has_bytes(pos, 8, seg_end4):
            return -1
        mk := buf_read_u32(data, pos)
        pos = pos + 4
        md_len := buf_read_u32(data, pos)
        pos = pos + 4
        if md_len > OPT_META_STRIDE - 8 || !ccr_has_bytes(pos, md_len, seg_end4):
            return -1
        // Allocate and store entry
        grow_opt_meta(mi + 1)
        mo := mi * OPT_META_STRIDE
        cell_store32(g_opt_meta, mo, mk)
        cell_store32(g_opt_meta, mo + 4, md_len)
        di : ., mut = 0
        loop:
            if di >= md_len:
                break
            cell_store_byte(g_opt_meta, mo + 8 + di, cell_load_byte(data, pos))
            pos = pos + 1
            di = di + 1
        g_opt_meta_count = mi + 1
        mi = mi + 1
    if pos != seg_end4:
        return -1

    // === NOD: instructions（40B each）===
    // loader 产出 = 对象载入 + 检查，32B
    // Semantic fields go to the kernel object buffer g_v7_nod_sem (the in-memory
    // record mirrors the disk record without adjacency, with the same offsets).
    // type_id is a TYPE row (-1 = none); flags is the semantic feature word.
    // src2/src3 are opaque auxiliary ids: the producer never writes a width,
    // stride, or byte extent there. Adjacency first_edge/edge_count go to
    // g_v7_nod_meta.
    // （EDG 段校验 + 对象数据 nod_edge_first/count 消费）。NOD->g_ir_instrs
    // 线性重建段已移出本函数（调度重建 = 实例事务 build_linear_schedule，
    // regalloc.cr，load 返回后、发射/分派前由入口调用）；g_ir_instrs/
    // g_ir_instr_count 本段不再触碰（重建段原写点全清）。
    if !ccr_has_bytes(pos, 4, seg_end5):
        return -1
    // instr_cnt consumers: ENT (live_end domain), REG (root span upper bound),
    // EDG (to_nod domain). It stays a local until those segments are consumed.
    instr_cnt := buf_read_u32(data, pos)
    pos = pos + 4
    if instr_cnt > (seg_end5 - seg_off5) / CCR_V10_NOD_DISK:
        return -1
    g_v7_nod_sem = alloc((instr_cnt + 8) * ESZ_NOD_SEM)
    g_v7_nod_meta = alloc((instr_cnt + 8) * ESZ_NOD_META)
    ii : ., mut = 0
    loop:
        if ii >= instr_cnt:
            break
        if !ccr_has_bytes(pos, CCR_V10_NOD_DISK, seg_end5):
            return -1
        opcode := buf_read_u32(data, pos)
        pos = pos + 4
        dest := buf_read_i32(data, pos)
        pos = pos + 4
        s1 := buf_read_i64(data, pos)
        pos = pos + 8   // 修复 14：s1 64 位
        s2 := buf_read_i32(data, pos)
        pos = pos + 4
        s3 := buf_read_i32(data, pos)
        pos = pos + 4
        tid2 := buf_read_i32(data, pos)
        pos = pos + 4  // type_id（TYPE row；-1 = 无）
        fl2 := buf_read_u32(data, pos)
        pos = pos + 4  // flags（语义特性；非目标事实）
        // src2/src3 may not carry v9 target facts. The writer normalizes them;
        // the loader rejects old/foreign files instead of silently accepting.
        if opcode == IR_ALLOC_ARRAY:
            if s2 != 0 || s3 != 0:
                return -1
        else if opcode == IR_ADDR_INDEX:
            if s3 != 0:
                return -1
        else if opcode == IR_DEREF || opcode == IR_STORE_PTR:
            if s3 != 0:
                return -1
        else if ccr_nod_src3_semantic(opcode) == 0:
            if s3 != 0:
                return -1
        nfe := buf_read_u32(data, pos)
        pos = pos + 4  // first_edge（邻接索引）
        nec := buf_read_u32(data, pos)
        pos = pos + 4  // edge_count
        // Reserved flag bits must be zero. A future feature bit needs a reader,
        // so rejecting here keeps old loaders from silently ignoring meaning.
        if fl2 > CCR_NOD_FLAG_KNOWN_MASK:
            return -1
        // 对象缓冲写（语义字段 = 盘字节镜像，w32/w64 低 32/64 位存储，存取
        // 经 nod_* 访问器 buf_read_* 符号扩展，数值与原重建段消费完全一致）
        cell_store32(g_v7_nod_sem, ii * ESZ_NOD_SEM + OFF_NS_OP, opcode)
        cell_store32(g_v7_nod_sem, ii * ESZ_NOD_SEM + OFF_NS_DEST, dest)
        cell_store(g_v7_nod_sem, ii * ESZ_NOD_SEM + OFF_NS_S1, s1)
        cell_store32(g_v7_nod_sem, ii * ESZ_NOD_SEM + OFF_NS_S2, s2)
        cell_store32(g_v7_nod_sem, ii * ESZ_NOD_SEM + OFF_NS_S3, s3)
        cell_store32(g_v7_nod_sem, ii * ESZ_NOD_SEM + OFF_NS_TYPE_ID, tid2)
        cell_store32(g_v7_nod_sem, ii * ESZ_NOD_SEM + OFF_NS_FLAGS, fl2)
        cell_store(g_v7_nod_meta, ii * ESZ_NOD_META, nfe)
        cell_store(g_v7_nod_meta, ii * ESZ_NOD_META + 8, nec)
        ii = ii + 1
    g_v7_nod_count = instr_cnt
    if pos != seg_end5:
        return -1

    // Header SYSTEM/CONCURRENT bits must agree with the graph. This needs NOD
    // only, so it runs here (TYPE is already rebuilt; ENT/REG/EDG are not).
    if ccr_validate_header_flags(rsv) != 0:
        return -1

    // === ENT: entries（24B each -> 内存 24B 表）===
    // 盘上半开 live_end -> 内存闭区间 −1；version 字段不入内存（组内序可推）。
    // v10 has no home field. The in-memory slot stays -1 until Task 8 retires it;
    // the loader never reads that slot from disk.
    if have6 != 0:
        if !ccr_has_bytes(pos, 4, seg_end6):
            return -1
        ent_cnt := buf_read_u32(data, pos)
        pos = pos + 4
        if ent_cnt > (seg_end6 - seg_off6) / CCR_V10_ENT_DISK:
            return -1
        grow_entries(ent_cnt)
        eii : ., mut = 0
        loop:
            if eii >= ent_cnt:
                break
            if !ccr_has_bytes(pos, CCR_V10_ENT_DISK, seg_end6):
                return -1
            ev := buf_read_i32(data, pos)
            pos = pos + 4   // var_id
            evr := buf_read_u32(data, pos)
            pos = pos + 4  // version（盘上仅校验用）
            ed := buf_read_i32(data, pos)
            pos = pos + 4   // def_nod
            els := buf_read_u32(data, pos)
            pos = pos + 4  // live_start（含定值）
            ele := buf_read_u32(data, pos)
            pos = pos + 4  // live_end（半开）
            efl := buf_read_u32(data, pos)
            pos = pos + 4  // flags
            // Semantic validation: reject out-of-range values.
            if evr < 1:
                return -1
            if efl > 0xF:
                return -1
            // ENT flags bits 4+ are reserved.
            if ev < 0 || ev >= g_ir_var_count:
                return -1
            // var 命名空间 = SYM 行重建总量
            if els >= ele || ele > instr_cnt:
                return -1
            if ed >= 0:
                if ed >= instr_cnt:
                    return -1
                if ed != els:
                    return -1
                // 定值条目 live_start == def
            // 内存闭区间表
            mo2 := eii * ESZ_ENTRY
            cell_store32(g_ir_entries, mo2 + OFF_ENTRY_VAR, ev)
            cell_store32(g_ir_entries, mo2 + OFF_ENTRY_DEF, ed)
            cell_store32(g_ir_entries, mo2 + OFF_ENTRY_LS, els)
            cell_store32(g_ir_entries, mo2 + OFF_ENTRY_LE, ele - 1)
            cell_store32(g_ir_entries, mo2 + OFF_ENTRY_HOME, -1)
            cell_store32(g_ir_entries, mo2 + OFF_ENTRY_FLAGS, efl)
            g_entry_count = eii + 1
            eii = eii + 1
        // The record walk must consume the ENT body exactly (no trailing bytes).
        if pos != seg_end6:
            return -1
        // 函数条目段界重建：条目按函数升序成块落盘（compute_entries func_i 升序），
        // 每函数一段 [start, count)，块判定 = var 槽 in 该函数 var 区间（var 槽
        // 全属唯一函数，段序与函数序一致）。重建结果与 SYM func 记录
        // first_ent/last_ent 逐函数对照（同信息双写，失配 = 格式不一致）。
        grow_func_entry_meta(func_cnt)
        pf : ., mut = 0
        pe : ., mut = 0
        loop:
            if pf >= func_cnt:
                break
            fvs := cell_load(g_ir_func_var_start, pf * 8)
            fvc := cell_load(g_ir_func_var_count, pf * 8)
            pstart := pe
            cell_store(g_ir_func_entry_start, pf * 8, pe)
            loop:
                if pe >= g_entry_count:
                    break
                pv := buf_read_i32(g_ir_entries, pe * ESZ_ENTRY + OFF_ENTRY_VAR)
                if fvc <= 0 || pv < fvs || pv >= fvs + fvc:
                    break
                pe = pe + 1
            pcnt := pe - pstart
            cell_store(g_ir_func_entry_count, pf * 8, pcnt)
            ffe := cell_load(fn_meta, pf * 24 + 8)
            fle := cell_load(fn_meta, pf * 24 + 16)
            if pcnt == 0:
                if ffe != -1 || fle != -1:
                    return -1
            else:
                if ffe != pstart || fle != pstart + pcnt - 1:
                    return -1
            pf = pf + 1
        if pe != g_entry_count:
            return -1

    // === REG: region（24B each，spec 3.5 字段序 {kind, parent, enter_nod,
    // exit_nod, first_ent, last_ent}）===
    // nstart and ncount are not stored; the loader derives nstart = enter and
    // ncount = exit - enter. A record with exit < enter is unclosed and has no
    // valid representation, so the file is rejected.
    // first/last 校验：SG_FUNC 根记录（记录顺序第 k 个 = 函数 k）的区内条目范围必须
    // 与 SYM func 记录 first/last 一致（同信息双写，失配 = 格式不一致）。
    // 函数指令边界重建：func root_region（SYM）-> REG span = [enter, exit)。
    if !ccr_has_bytes(pos, 4, seg_end7):
        return -1
    sg_n := buf_read_u32(data, pos)
    pos = pos + 4
    if sg_n > (seg_end7 - seg_off7) / CCR_V10_REG_DISK:
        return -1
    sg_i : ., mut = 0
    rfcnt : ., mut = 0  // 已见 SG_FUNC 根记录数（记录顺序 = 函数序 1:1）
    loop:
        if sg_i >= sg_n:
            break
        grow_sg(sg_i + 1)
        f := sg_i * ESZ_SG
        rk := buf_read_i32(data, pos)
        pos = pos + 4
        rp := buf_read_i32(data, pos)
        pos = pos + 4
        ren := buf_read_i32(data, pos)
        pos = pos + 4
        rex := buf_read_i32(data, pos)
        pos = pos + 4
        rfe := buf_read_i32(data, pos)
        pos = pos + 4
        rle := buf_read_i32(data, pos)
        pos = pos + 4
        if rex < ren:
            return -1
        // 未闭合 -> ncount 不可派生
        if rfe < -1 || rle < -1 || (rfe == -1) != (rle == -1):
            return -1
        cell_store(g_sgs, f + OFF_SG_KIND, rk)
        cell_store(g_sgs, f + OFF_SG_ENTER, ren)
        cell_store(g_sgs, f + OFF_SG_EXIT, rex)
        cell_store(g_sgs, f + OFF_SG_PARENT, rp)
        cell_store(g_sgs, f + OFF_SG_NSTART, ren)
        cell_store(g_sgs, f + OFF_SG_NCOUNT, rex - ren)
        if rk == SG_FUNC:
            if rfcnt >= func_cnt:
                return -1
            // 根记录多于函数记录
            if rfe != cell_load(fn_meta, rfcnt * 24 + 8) || rle != cell_load(fn_meta, rfcnt * 24 + 16):
                return -1  // REG 根记录条目范围 != SYM func 记录
            rfcnt = rfcnt + 1
        sg_i = sg_i + 1
    if rfcnt != func_cnt:
        return -1
    // 根记录少于函数记录（每函数必有根）
    g_sg_count = sg_n

    // 函数指令边界回填：instr_start = root_region enter, instr_count = exit − enter
    // The root region span is the function node range and is the single source for
    // function instruction bounds.
    bfi : ., mut = 0
    loop:
        if bfi >= func_cnt:
            break
        rid := cell_load(fn_meta, bfi * 24)
        if rid < 0 || rid >= sg_n:
            return -1
        fr := rid * ESZ_SG
        if cell_load(g_sgs, fr + OFF_SG_KIND) != SG_FUNC:
            return -1
        ren := cell_load(g_sgs, fr + OFF_SG_ENTER)
        rex := cell_load(g_sgs, fr + OFF_SG_EXIT)
        if rex < ren:
            return -1
        cell_store(g_ir_func_instr_start, bfi * 8, ren)
        cell_store(g_ir_func_instr_count, bfi * 8, rex - ren)
        bfi = bfi + 1

    // REG root span upper-bound check. Function instruction bounds (root_region
    // span) are backfilled above, and instr_cnt is already known because NOD is
    // consumed before REG. Only rex >= ren was checked per record, not the upper
    // bound. An out-of-range span would make ELF emission read outside the NOD
    // space. For each function, check instr_start + count <= instr_cnt and reject
    // negative values. EDG and CASE are still consumed after this gate.
    rfi : ., mut = 0
    loop:
        if rfi >= func_cnt:
            break
        ris := cell_load(g_ir_func_instr_start, rfi * 8)
        ric := cell_load(g_ir_func_instr_count, rfi * 8)
        if ris < 0 || ric < 0 || ris + ric > instr_cnt:
            return -1
        rfi = rfi + 1
    if pos != seg_end7:
        return -1

    // === EDG: edges（v7 必落；8B each {to_nod u32, kind u32}，所属节点 =
    // 邻接隐含：节点 i 出边连续段 [first_edge, first_edge+edge_count)，first_edge
    // = 前缀累计（spec 3.3 邻接约定）。校验（spec 4 + 检查强度保持）：
    //   1 连续段与 NOD 邻接域逐节点对照（first_edge == 前缀累计；段界不出 EDG）
    //   2 Σ edge_count == edg_count（规则 3；行走完 == 段体大小）
    //   3 每条边 to_nod < instr_cnt（NOD 引用界内）+ to_nod > 所属节点
    //      （规则 1 拓扑不变量，数据/state 边前向；自环/后向 = 文件损坏拒绝）
    //   4 kind <= 1（0=数据、1=state；2+ 预留 = 未知边类拒绝）
    // 校验通过后边表入 g_v7_edges 缓冲（文件序连续段，图语义消费通道/调试）。
    // branch/jump 目标 = 操作数引用非边（v7 4 边界声明），NOD 操作数不参与
    // 本段校验。
    if !ccr_has_bytes(pos, 4, seg_end8):
        return -1
    edg_cnt := buf_read_u32(data, pos)
    pos = pos + 4
    if edg_cnt > (seg_end8 - seg_off8) / CCR_V10_EDG_DISK:
        return -1
    v7_buf : string, mut = ""
    if edg_cnt > 0:
        v7_buf = alloc(edg_cnt * 8)
    g_v7_edges = v7_buf
    g_v7_edge_count = edg_cnt
    ei4 : ., mut = 0
    run_off : ., mut = 0
    loop:
        if ei4 >= instr_cnt:
            break
        // 邻接域读内核对象缓冲 g_v7_nod_meta（原 nod_edge_meta loader 局部，
        // 对象 = 内核持有物，EDG 检查
        // 与对象数据 nod_edge_first/count 同源；检查逻辑零改动）
        nfe := cell_load(g_v7_nod_meta, ei4 * ESZ_NOD_META)
        nec := cell_load(g_v7_nod_meta, ei4 * ESZ_NOD_META + 8)
        if nfe != run_off:
            return -1
        // 1 前缀累计失配（段错位/伪造）
        if run_off + nec > edg_cnt:
            return -1
        // 1 节点段越出 EDG 空间
        rec : ., mut = 0
        loop:
            if rec >= nec:
                break
            if !ccr_has_bytes(pos, CCR_V10_EDG_DISK, seg_end8):
                return -1
            eto := buf_read_u32(data, pos)
            pos = pos + 4
            ekind := buf_read_u32(data, pos)
            pos = pos + 4
            if ekind > 1:
                return -1
            // 4 未知边类
            if eto >= instr_cnt:
                return -1
            // 3 to 出 NOD 空间
            if eto <= ei4:
                return -1
            // 3 后向/自环（拓扑不变量）
            cell_store(v7_buf, (run_off + rec) * 8, eto + ekind * 4294967296)
            rec = rec + 1
        run_off = run_off + nec
        ei4 = ei4 + 1
    if run_off != edg_cnt:
        return -1
    // 2 Σ edge_count == edg_count
    if pos != seg_end8:
        return -1
    // 2 行走完 == 段体大小

    // === CASE: empty table for now ===
    // The loader requires case_count == 0 until match lowering writes CASE. Any
    // other count is an unknown shape, so reject instead of treating it as empty.
    if !ccr_has_bytes(pos, 4, seg_end9):
        return -1
    case_cnt := buf_read_u32(data, pos)
    pos = pos + 4
    if case_cnt != 0:
        return -1
    if pos != seg_end9:
        return -1

    // === NOD type_id domain check ===
    // TYPE is consumed before NOD, so the row domain is already rebuilt. The
    // check stays at the end as one summary gate over g_v7_nod_sem. type_id is
    // -1 or a TYPE row; anything else is an unknown type domain and rejects the
    // file.
    ni : ., mut = 0
    loop:
        if ni >= g_v7_nod_count:
            break
        tidv := nod_type_id(ni)
        if tidv < -1 || tidv >= g_type_count:
            return -1
        ni = ni + 1

    return 0

// ─── TYPE 段项引用拓扑───
// 项引用 = -1（无）或 < 自身行号（DAG 由 tt_term 追加式构造，因此子项恒先建）。
// 字段表按 tag 分派（不得全槽施检，标注槽会被误拒）：
//   TT_UNION/TT_INTER/TT_CONS：a, b          （两子项）
//   TT_NOT：a                                 ；TT_MU：b（a = 绑定变量标注）
//   TT_ATOM：c（参数列表首项，-1 = 无参）         ；a = ak、b = 标注（自类型表记录编号/固定性位/
//                                               令牌值/mut 标记，可达数千）、d = 保留
//   TT_BOT/TT_TOP/TT_NIL：无引用槽           ；TT_TOP_K：a = k；TT_VAR：a = 绑定变量
// 构造点单源见 ty_shadow.cr 的 sh_ref_mut_marker/sh_name_token/sh_seq_term 三处注记。
fn ccr_type_ref_before(r: int, row: int) -> int:
    if r < 0:
        return 1
    // -1 = 无引用
    if r < row:
        return 1
    // 子项恒先建（DAG 无环）
    return 0

fn ccr_type_term_ref_ok(tag: int, a: int, b: int, c: int, d: int, row: int) -> int:
    if tag == TT_UNION || tag == TT_INTER || tag == TT_CONS:
        if ccr_type_ref_before(a, row) == 0:
            return 0
        return ccr_type_ref_before(b, row)
    if tag == TT_NOT:
        return ccr_type_ref_before(a, row)
    if tag == TT_MU:
        return ccr_type_ref_before(b, row)
    if tag == TT_ATOM:
        return ccr_type_ref_before(c, row)
    return 1   // ⊥ / ⊤ / ⊤ₖ / VAR / NIL：无引用槽（a 为标注）

// ─── --dump-types 通道（段内容打印 ───
// 写侧（corec `ccr --dump-types`，经 ccr_types.cr 的 ccr_type_selftest_dump 调
// 本函数）与读侧（corearch `--dump-types`）共用同一条打印路径，跨进程行
// 格式零分歧；行格式契约见 tests/selfhost/test_ccr_types.py:parse_type_dump。
// 读侧意义 = 6.3 的读回证据：载入段重建后的记录表/项 DAG 与写侧逐条记录一致，
// 且 probe 行的跨进程同值 = 项层原语（tt_norm/tt_is_dnf/tt_is_literal）在同构
// 重建表上逐点同值（下标含新建项，因此索引重建/去重行为的实证）。
CCR_TYPE_PROBE_N : int = 16   // probe 窗口（前 N 项）

fn ccr_type_surface_dump():
    print("rows: ")
    print_i(g_type_count)
    println("")
    i : ., mut = 0
    loop:
        if i >= g_type_count:
            break
        print("row ")
        print_i(i)
        print(" kind ")
        print_i(cell_load(g_types, i * ESZ_TYPE_ROW + OFF_TR_KIND))
        print(" data ")
        print_i(cell_load(g_types, i * ESZ_TYPE_ROW + OFF_TR_DATA))
        print(" extra ")
        print_i(cell_load(g_types, i * ESZ_TYPE_ROW + OFF_TR_EXTRA))
        println("")
        i = i + 1
    print("terms: ")
    print_i(tt_count())
    println("")
    j : ., mut = 0
    loop:
        if j >= tt_count():
            break
        print("term ")
        print_i(j)
        print(" tag ")
        print_i(tt_tag(j))
        print(" a ")
        print_i(tt_a(j))
        print(" b ")
        print_i(tt_b(j))
        print(" c ")
        print_i(tt_c(j))
        print(" d ")
        print_i(tt_d(j))
        println("")
        j = j + 1
    ccr_type_probe_dump()

// 项层原语跨进程同值检查（项层，type_terms.cr 数据；判定原语 ty_sub 族不入
// corearch 清单，见 build_selfhost_native.py 的 backend_support_nodes 注记）：
// 预算状态复位（两侧同起点）-> 前 N 项逐个 tt_norm（规范化 = 判定算法输入形态，
// spec 1.3）-> 折叠规范化结果的项下标 + 形态位（tt_is_dnf/tt_is_literal）
// 成摘要。两侧表同构（记录表/项表/probe 前各节逐条记录同），因此调用序、步数消耗、
// 新建项的下标逐点同，因此摘要同。下标入摘要即重建后的索引（g_tt_index）
// 与去重行为的实证：索引未重建/重建错位，因此tt_norm 的去重退化/错配，因此新建项
// 下标漂移，因此摘要变。
// 本检查会向项表追加规范化新项（tt_norm 的构造），在 dump 的 terms 节
// 之后运行，故不影响打印输出（序列化缓冲早在 dump 前已生成，见 ccr_type_prepare_save）。
// ─── --dump-ifaces 通道（IFACE 段内容打印 ───
// 写侧（corec `ccr --dump-ifaces`，经 ccr_types.cr 的 ccr_iface_selftest_dump 调本
// 函数）与读侧（corearch `--dump-ifaces`）共用同一条打印路径，跨进程行格式零
// 分歧；行格式契约见 tests/selfhost/test_ccr_types.py:parse_iface_dump。
// 读侧意义 = 6.3 的读回证据：载入段重建后的条目表/形状表/接口表/impl 边/方法表与
// 写侧逐条记录一致；`ifaceprobe` 行 = 跨段引用域的可解析性（每个项槽在重建的项表上
// 解析：tag/a/c 折叠成摘要，两侧同值即段内项索引在 corearch 侧解析到同构项）。
// 零建项（纯读：不动项表/预算/memo，与 TYPE 的 probe 不同，本处无需构造项）。
fn ccr_iface_surface_dump():
    print("ifacenative: ")
    print_i(g_iface_entry_count)
    println("")
    ei2 : ., mut = 0
    loop:
        if ei2 >= g_iface_entry_count:
            break
        eo2 := ei2 * ESZ_IFACE_ENTRY
        print("native ")
        print_i(ei2)
        print(" ak ")
        print_i(cell_load(g_iface_entries, eo2 + OFF_IE_AK))
        print(" ti ")
        print_i(cell_load(g_iface_entries, eo2 + OFF_IE_TI))
        print(" name ")
        print_i(cell_load(g_iface_entries, eo2 + OFF_IE_NAME))
        print(" lit ")
        print_i(cell_load(g_iface_entries, eo2 + OFF_IE_LIT))
        print(" ops ")
        print_i(cell_load(g_iface_entries, eo2 + OFF_IE_OPS))
        println("")
        ei2 = ei2 + 1
    print("ifaceshapes: ")
    print_i(g_iface_shape_count)
    println("")
    sh2 : ., mut = 0
    loop:
        if sh2 >= g_iface_shape_count:
            break
        print("shape ")
        print_i(sh2)
        print(" name ")
        print_i(cell_load(g_iface_shape_names, sh2 * 8))
        print(" term ")
        print_i(cell_load(g_iface_shape_terms, sh2 * 8))
        println("")
        sh2 = sh2 + 1
    print("ifaceuser: ")
    print_i(g_iface_count)
    println("")
    iu2 : ., mut = 0
    loop:
        if iu2 >= g_iface_count:
            break
        bo := iu2 * ESZ_IFACEINFO
        mc3 := cell_load(g_ifaces, bo + OFF_IF_METHOD_COUNT)
        print("iface ")
        print_i(iu2)
        print(" name ")
        print_i(cell_load(g_ifaces, bo + OFF_IF_NAME))
        print(" methods ")
        print_i(mc3)
        print(" generics ")
        print_i(cell_load(g_ifaces, bo + OFF_IF_GENERIC_COUNT))
        println("")
        mj2 : ., mut = 0
        loop:
            if mj2 >= mc3:
                break
            mbo := bo + OFF_IF_METHODS + mj2 * ESZ_IFMETHOD
            mpc := cell_load(g_ifaces, mbo + OFF_IFM_PARAM_COUNT)
            print("method ")
            print_i(iu2)
            print(" ")
            print_i(mj2)
            print(" name ")
            print_i(cell_load(g_ifaces, mbo + OFF_IFM_NAME))
            print(" params ")
            print_i(mpc)
            print(" self ")
            print_i(cell_load(g_ifaces, mbo + OFF_IFM_SELF_MODE))
            print(" ret ")
            print_i(cell_load(g_ifaces, mbo + OFF_IFM_RET_TERM))
            println("")
            mq2 : ., mut = 0
            loop:
                if mq2 >= MAX_IFACE_METHOD_PARAMS:
                    break
                print("mparam ")
                print_i(iu2)
                print(" ")
                print_i(mj2)
                print(" ")
                print_i(mq2)
                print(" code ")
                print_i(cell_load(g_ifaces, mbo + OFF_IFM_PARAM_TYPES + mq2 * 8))
                print(" term ")
                print_i(cell_load(g_ifaces, mbo + OFF_IFM_PARAM_TERMS + mq2 * 8))
                println("")
                mq2 = mq2 + 1
            mj2 = mj2 + 1
        iu2 = iu2 + 1
    print("ifaceimpl: ")
    print_i(g_impl_for_count)
    println("")
    ip2 : ., mut = 0
    loop:
        if ip2 >= g_impl_for_count:
            break
        print("impl ")
        print_i(ip2)
        print(" trait ")
        print_i(cell_load(g_impl_for, ip2 * 16))
        print(" type ")
        print_i(cell_load(g_impl_for, ip2 * 16 + 8))
        println("")
        ip2 = ip2 + 1
    print("ifacemethods: ")
    print_i(g_method_count)
    println("")
    im2 : ., mut = 0
    loop:
        if im2 >= g_method_count:
            break
        print("gmethod ")
        print_i(im2)
        print(" type ")
        print_i(cell_load(g_methods, im2 * 24))
        print(" method ")
        print_i(cell_load(g_methods, im2 * 24 + 8))
        print(" mangled ")
        print_i(cell_load(g_methods, im2 * 24 + 16))
        println("")
        im2 = im2 + 1
    // 跨段引用域检查：逐接口/方法/有效形参的项槽
    //   resolved = 0 <= t < tt_count()（在重建项表上可解析）；unbuilt = t == -1；
    //   bad = t < -1 || t >= tt_count()（必须为 0，写侧不产、loader 拒绝）。
    //   摘要 = Σ (tt_tag×31 + tt_a) 与 (tt_c×31 + 2) 的混入（两侧同值 = 段内项索引
    //   解析到同构项；TYPE 段的跨进程同构由 --dump-types 的 probe 行独立承担）。
    slots : ., mut = 0
    built : ., mut = 0
    unbuilt : ., mut = 0
    bad : ., mut = 0
    hsh : ., mut = 0
    ipc : ., mut = 0
    loop:
        if ipc >= g_iface_count:
            break
        boc := ipc * ESZ_IFACEINFO
        mcc := cell_load(g_ifaces, boc + OFF_IF_METHOD_COUNT)
        mic : ., mut = 0
        loop:
            if mic >= mcc:
                break
            mbc := boc + OFF_IF_METHODS + mic * ESZ_IFMETHOD
            pcc := cell_load(g_ifaces, mbc + OFF_IFM_PARAM_COUNT)
            slots = slots + 1
            rtc := cell_load(g_ifaces, mbc + OFF_IFM_RET_TERM)
            if rtc == -1:
                unbuilt = unbuilt + 1
            if rtc >= 0:
                if rtc >= tt_count():
                    bad = bad + 1
                if rtc < tt_count():
                    built = built + 1
                    hsh = hsh * 31 + tt_tag(rtc)
                    hsh = hsh * 31 + tt_a(rtc)
                    hsh = hsh * 31 + tt_c(rtc)
            if rtc < -1:
                bad = bad + 1
            pqc : ., mut = 0
            loop:
                if pqc >= pcc:
                    break
                slots = slots + 1
                ptc := cell_load(g_ifaces, mbc + OFF_IFM_PARAM_TERMS + pqc * 8)
                if ptc == -1:
                    unbuilt = unbuilt + 1
                if ptc >= 0:
                    if ptc >= tt_count():
                        bad = bad + 1
                    if ptc < tt_count():
                        built = built + 1
                        hsh = hsh * 31 + tt_tag(ptc)
                        hsh = hsh * 31 + tt_a(ptc)
                        hsh = hsh * 31 + tt_c(ptc)
                if ptc < -1:
                    bad = bad + 1
                pqc = pqc + 1
            mic = mic + 1
        ipc = ipc + 1
    print("ifaceprobe: slots ")
    print_i(slots)
    print(" built ")
    print_i(built)
    print(" unbuilt ")
    print_i(unbuilt)
    print(" bad ")
    print_i(bad)
    print(" digest ")
    println(int_str(hsh))

fn ccr_type_probe_dump():
    n := tt_count()
    if n > CCR_TYPE_PROBE_N:
        n = CCR_TYPE_PROBE_N
    tt_budget_state_reset()
    nn_ok : ., mut = 0
    nn_bad : ., mut = 0
    dnf_ok : ., mut = 0
    lit_ok : ., mut = 0
    h : ., mut = 0
    i : ., mut = 0
    loop:
        if i >= n:
            break
        norm := tt_norm(i)
        if norm < 0:
            nn_bad = nn_bad + 1
        else:
            nn_ok = nn_ok + 1
        d := -1
        if norm >= 0:
            d = tt_is_dnf(norm)
        if d == 1:
            dnf_ok = dnf_ok + 1
        if tt_is_literal(i) == 1:
            lit_ok = lit_ok + 1
        // 摘要 = 规范化结果下标 + DNF 位（-1 = 预算耗尽，下标用 -1 表示）
        h = h * 31 + (norm + 2)
        h = h * 31 + (d + 2)
        i = i + 1
    print("probe: n ")
    print_i(n)
    print(" norm_ok ")
    print_i(nn_ok)
    print(" norm_unknown ")
    print_i(nn_bad)
    print(" dnf_ok ")
    print_i(dnf_ok)
    print(" lit_ok ")
    print_i(lit_ok)
    print(" exhausted ")
    print_i(g_ty_exhausted)
    print(" digest ")
    println(int_str(h))
