// === dyn_arr.cr ===
// Compiler table constants + grow functions + string pool.
// Byte helpers (w8/bu8/w32/r32/w64/r64/_dyncpy) live in src/kernel/bytes.cr;
// they are the low-level cell layer, not frontend semantics.

// ============================================================
// Element sizes (bytes per element)
// ============================================================
ESZ_TOKEN    : int = 40     // kind,lexeme,int_val,line,col = 5×8
ESZ_ASTNODE  : int = 72    // kind,a,b,c,int_val,type_val,data,line,col = 9×8
ESZ_SYMENTRY : int = 32    // name_idx,kind,type_idx,node_idx = 4×8
ESZ_IRVAR    : int = 24    // name_idx,id,type_kind = 3×8
ESZ_IRINSTR  : int = 48    // opcode,dest,src1,src2,src3,type_kind = 6×8
ESZ_FUNCINFO : int = 688
ESZ_STRUCTINFO : int = 440
ESZ_ENUMINFO : int = 4408  // name, variants[16] with payload type nodes, counts, generic names

// Token field offsets
OFF_TK_KIND : int = 0
OFF_TK_LEXEME : int = 8
OFF_TK_INTVAL : int = 16
OFF_TK_LINE : int = 24
OFF_TK_COL : int = 32

// ASTNode field offsets
OFF_AS_KIND : int = 0
OFF_AS_A : int = 8
OFF_AS_B : int = 16
OFF_AS_C : int = 24
OFF_AS_INTVAL : int = 32
OFF_AS_TYPEVAL : int = 40
OFF_AS_DATA : int = 48
OFF_AS_LINE : int = 56
OFF_AS_COL : int = 64

// SymEntry field offsets
OFF_SY_NAME : int = 0
OFF_SY_KIND : int = 8
OFF_SY_TYPE : int = 16
OFF_SY_NODE : int = 24

// IRVar field offsets
OFF_IRV_NAME : int = 0
OFF_IRV_ID : int = 8
OFF_IRV_TYPE : int = 16

// IRInstr field offsets
OFF_IRI_OP : int = 0
OFF_IRI_DEST : int = 8
OFF_IRI_S1 : int = 16
OFF_IRI_S2 : int = 24
OFF_IRI_S3 : int = 32
OFF_IRI_TK : int = 40

// FuncInfo offsets.
// param_types is a fixed inline array between param_count and return_type. The old
// limit of 16 with unbounded writes let parameter 17 overwrite return_type and
// ast_node, producing a silent miscompile. MAX_FN_PARAMS is 64, matching the
// [int; 64] mirror in ast.cr and covering signatures with 16 stack arguments plus
// 6 register arguments. A larger signature is parser error P020, and the accessors
// below guard the array as a second layer.
MAX_FN_PARAMS : int = 64
OFF_FI_NAME : int = 0
OFF_FI_PARAM_COUNT : int = 8
OFF_FI_PARAM_TYPES : int = 16                        // 64 slots x 8B = 512 bytes, ending at 527
OFF_FI_RETURN_TYPE : int = 528
OFF_FI_AST_NODE : int = 536
OFF_FI_GENERIC_NAMES : int = 544
OFF_FI_GENERIC_COUNT : int = 672
OFF_FI_ISPURE : int = 680  // 1 = pure (no side effects), 0 = impure

// StructInfo offsets. Field storage moved to side tables: OFF_SI_FIELD_BASE is the
// starting row and OFF_SI_FIELD_TYPES / OFF_SI_FIELD_TYPE_NODES are unused padding.
// The record size is unchanged, so on-disk layout and external arithmetic are
// unaffected.
OFF_SI_NAME : int = 0
OFF_SI_FIELD_BASE : int = 8
OFF_SI_FIELD_TYPES : int = 136
OFF_SI_FIELD_TYPE_NODES : int = 264   // 保留未用
OFF_SI_FIELD_COUNT : int = 392
OFF_SI_GENERIC_NAMES : int = 400
OFF_SI_GENERIC_COUNT : int = 432

// DFNode sizes and offsets. Type information has one source:
//   OFF_DF_TK (40) = type-term reference (a g_type_terms row), or -1.
//   OFF_DF_AUX (64) = auxiliary code (flags, widths, counts, or an original type
//                     row code that cannot be represented as a term), or 0.
// The two slots are mutually exclusive: auxiliary code means term = -1, and a term
// means auxiliary code = 0. The splitter guarantees this.
// The stored type code in iri_tk, .ccr NOD records, and .cir snapshots is always
// derived through sh_dfn_code_of_slots(term, aux). It is not an independent source.
// Byte layout is unchanged: ESZ_DFNODE is still 72 bytes, and .ccr NOD / .cir node
// layouts are unchanged.
// The splitter is sh_tk_split in ty_shadow.cr. Consumers read the derived code.
// Write points are df_create_node and the .cir loader's rederivation; the snapshot
// stores only the derived code, never process-local term references.
ESZ_DFNODE : int = 72   // opcode,dest_var,src1,src2,src3,tk_term,first_edge,edge_count,tk_aux = 9x8
OFF_DF_OPCODE : int = 0
OFF_DF_DEST : int = 8
OFF_DF_S1 : int = 16
OFF_DF_S2 : int = 24
OFF_DF_S3 : int = 32
OFF_DF_TK : int = 40   // type-term reference (-1 = none)
OFF_DF_FIRST_EDGE : int = 48
OFF_DF_EDGE_COUNT : int = 56
OFF_DF_AUX : int = 64   // auxiliary code (0 = none)

// DFEdge sizes and offsets
ESZ_DFEDGE : int = 32   // from_node,to_node,next_out,kind = 4x8
OFF_DFE_FROM : int = 0
OFF_DFE_TO : int = 8
OFF_DFE_NEXT : int = 16
OFF_DFE_KIND : int = 24 // 0=data (def-use), 1=state (ordering/termination)

// Entry record, filled by compute_entries. It splits variables into versions at
// definition points. The in-memory record is 24 bytes, six 4-byte fields, read
// and written little-endian. It is NOT the v10 wire record: on disk ENT is also
// 24 bytes but stores `version` in the slot where memory keeps the runtime-only
// allocator home. var_idx u32, def_instr i32, live_start i32, live_end i32,
// runtime_home i32, flags u32.
ESZ_ENTRY   : int = 24
OFF_ENTRY_VAR   : int = 0    // 全局 IR 变量索引
OFF_ENTRY_DEF   : int = 4    // 定值指令全局索引（-1 = 无定值）
OFF_ENTRY_LS    : int = 8    // 版本存在区间起点（全局指令序）
OFF_ENTRY_LE    : int = 12   // 版本存在区间终点（全局指令序）
// Runtime/instance-only allocator slot (-1 = unassigned). This is never
// serialized into `.ccr`; v10 ENT has no home field.
OFF_ENTRY_RUNTIME_HOME : int = 16
OFF_ENTRY_FLAGS : int = 20   // 位 0 预留：无配方（条款 4b）

// Subgraph entry (48 bytes each)
ESZ_SG   : int = 48
OFF_SG_KIND   : int = 0   // 0=func, 1=loop, 2=for, 3=flow, 4=unsafe
OFF_SG_ENTER  : int = 8   // enter seq number (instruction index)
OFF_SG_EXIT   : int = 16  // exit seq number
OFF_SG_PARENT : int = 24  // parent subgraph index
OFF_SG_NSTART : int = 32  // first DFNode index
OFF_SG_NCOUNT : int = 40  // node count

SG_FUNC   : int = 0
SG_LOOP   : int = 1
SG_FOR    : int = 2
SG_FLOW   : int = 3
SG_UNSAFE : int = 4
SG_IF     : int = 5  // conditional region: covers [condition, merge)

// InterfaceInfo: one fixed-size entry per interface.
// Header 24 bytes plus 16 method entries of 240 bytes = 3864 bytes.
ESZ_IFACEINFO : int = 3864
OFF_IF_NAME : int = 0
OFF_IF_METHOD_COUNT : int = 8
OFF_IF_GENERIC_COUNT : int = 16
OFF_IF_METHODS : int = 24  // first method entry
// Each method entry: name_idx(8) + param_count(8) + ret_ti(8) + param_types[8](64)
//   + param_nodes[8](64) + ret_node(8) + self_mode(8) + param_terms[8](64) + ret_term(8) = 240 bytes
// Raw code slots param_types and ret_ti are kept because checker's generic-method
// return mapping uses their TY_* encoding. Type-node slots are added as the faithful
// signature source: raw code collapses non-native types to 0 (TY_INT). A node slot
// of -1 means no node; 0 is a valid node index and cannot be the sentinel. The
// receiver slot has no node on either side.
ESZ_IFMETHOD : int = 240
OFF_IFM_NAME : int = 0
OFF_IFM_PARAM_COUNT : int = 8
OFF_IFM_RET_TI : int = 16
OFF_IFM_PARAM_TYPES : int = 24   // first of up to 8 param types (8B each), covers 24..87
OFF_IFM_PARAM_NODES : int = 88   // first of up to 8 param type nodes (8B each), covers 88..151
OFF_IFM_RET_NODE : int = 152     // return type node（-1 = 无，= unit）
OFF_IFM_SELF_MODE : int = 160    // 接收者模式：0 = 无接收者（首参为普通形参）/ 1 = self /
                                  //   2 = &self / 3 = &mut self（照 EXPR_PARAM 的 int_val 约定）
// Signature type-term slots, or -1 when not buildable:
//   param_terms[8]: one signature term per parameter; the receiver uses unit.
//   ret_term: return signature term.
// Node slots are the corec-side signature source from the AST. Term slots are the
// carrier form stored in the IFACE segment and read back by corearch, which has no
// AST. The two representations are distinct and must not be reused for each other.
// ccr_iface_populate fills them; load_ccr reads them back. They are not stored in
// .cir snapshots.
OFF_IFM_PARAM_TERMS : int = 168  // first of up to 8 param terms (8B each), covers 168..231
OFF_IFM_RET_TERM : int = 232     // return signature term (-1 = 不可建)
MAX_IFACE_METHOD_PARAMS : int = 8
// Method limit. It is tied to the fixed method slots in ESZ_IFACEINFO. Exceeding it
// is a hard error, not a silent truncation. Removing the limit requires moving the
// method table to side storage and updating all readers.
MAX_IFACE_METHODS : int = 16

// Native interface entry layout. These constants live here because the IFACE
// segment loader in corearch needs them, and iface_registry.cr is corec-only.
// Each entry is {ak, ti_row, name_ni, lit_code, ops}:
//   ak: atom class (AK_*).
//   ti_row: canonical checker type row for the eight native types; -1 for
//           structural or named classes.
//   name_ni: name index for display and lookup.
//   lit_code: literal AST kind, or -1.
//   ops: operation-permission bits.
ESZ_IFACE_ENTRY : int = 40
OFF_IE_AK : int = 0
OFF_IE_TI : int = 8
OFF_IE_NAME : int = 16
OFF_IE_LIT : int = 24
OFF_IE_OPS : int = 32
// 16 entries: 13 original entries plus AK_NULL, AK_SUM, and AK_FN. The last three
// are informational and have ops = 0.
IFACE_ENTRY_COUNT : int = 16

// Grow the shape entry table. It lives here because the corearch IFACE loader also
// rebuilds g_iface_shape_*, and this file is the shared host for grow helpers.
fn iface_shape_grow(needed: int):
    if needed <= g_iface_shape_cap:
        return
    nc : ., mut = g_iface_shape_cap * 2
    if nc < 8:
        nc = 8
    if nc < needed:
        nc = needed + 8
    nb := alloc(nc * 8)
    cell_copy(g_iface_shape_names, g_iface_shape_cap * 8, nb)
    g_iface_shape_names = nb
    nt := alloc(nc * 8)
    cell_copy(g_iface_shape_terms, g_iface_shape_cap * 8, nt)
    g_iface_shape_terms = nt
    g_iface_shape_cap = nc

// EnumInfo offsets.
// Variant payload type nodes are stored separately from raw codes. Raw codes
// collapse non-native payloads to 0 (TY_INT), so they cannot distinguish int from
// string, a named type, or a generic parameter. The node slots hold the parse_type
// result, or -1/0 when there is no information.
// Variant storage moved to side tables: OFF_EI_VARIANTS is now variant_base, and
// OFF_EV_* and the 272-byte slot area are unused padding. The record size is
// unchanged, so external arithmetic is unaffected.
OFF_EI_NAME : int = 0
OFF_EI_VARIANTS : int = 8    // = variant_base
OFF_EI_VARIANT_COUNT : int = 4360
OFF_EI_GENERIC_NAMES : int = 4368
OFF_EI_GENERIC_COUNT : int = 4400
OFF_EV_NAME : int = 0
OFF_EV_TYPES : int = 8
OFF_EV_TYPE_COUNT : int = 136
OFF_EV_TYPE_NODES : int = 144
OFF_EV_SIZE : int = 272

// ============================================================
// Grow helpers for all arrays
// ============================================================
// _grow is a placeholder. The language has no generics, and cap_name is passed by
// value, so each array has its own grow function. All follow the same pattern:
// double the capacity, enforce a minimum, and copy the old contents.
fn _grow(buf_name: string, cap_name: int, esz: int, min_init: int):
    return

fn grow_tokens(needed: int):
    if needed < g_tok_cap:
        return
    nc : ., mut = g_tok_cap * 2
    if nc < 128:
        nc = 128
    if nc < needed:
        nc = needed + 128
    nb := alloc(nc * ESZ_TOKEN)
    cell_copy(g_tokens, g_tok_cap * ESZ_TOKEN, nb)
    g_tokens = nb
    g_tok_cap = nc

fn grow_ast(needed: int):
    if needed < g_ast_cap:
        return
    nc : ., mut = g_ast_cap * 2
    if nc < 128:
        nc = 128
    if nc < needed:
        nc = needed + 128
    nb := alloc(nc * ESZ_ASTNODE)
    cell_copy(g_ast, g_ast_cap * ESZ_ASTNODE, nb)
    g_ast = nb
    g_ast_cap = nc

fn grow_syms(needed: int):
    if needed < g_sym_cap:
        return
    nc : ., mut = g_sym_cap * 2
    if nc < 64:
        nc = 64
    if nc < needed:
        nc = needed + 64
    nb := alloc(nc * ESZ_SYMENTRY)
    cell_copy(g_syms, g_sym_cap * ESZ_SYMENTRY, nb)
    g_syms = nb
    g_sym_cap = nc

fn grow_types(needed: int):
    if needed < g_type_cap:
        return
    nc : ., mut = g_type_cap * 2
    if nc < 64:
        nc = 64
    if nc < needed:
        nc = needed + 64
    // Row size comes from ESZ_TYPE_ROW in globals.cr, shared with alloc_type and
    // TYPE-segment serialization.
    nb := alloc(nc * ESZ_TYPE_ROW)
    cell_copy(g_types, g_type_cap * ESZ_TYPE_ROW, nb)
    g_types = nb
    g_type_cap = nc

// Type-row readers. They live here (shared by corec and corearch) because the
// target layout helpers in x86_mapping.cr consume them and corearch has no
// checker layer. Out-of-range rows return the same sentinels as before.
fn get_type_kind(ti: int) -> int:
    if ti >= 0 && ti < g_type_count:
        return cell_load(g_types, ti * ESZ_TYPE_ROW + OFF_TR_KIND)
    return -1

fn get_type_data(ti: int) -> int:
    if ti >= 0 && ti < g_type_count:
        return cell_load(g_types, ti * ESZ_TYPE_ROW + OFF_TR_DATA)
    return 0

fn get_type_extra(ti: int) -> int:
    if ti >= 0 && ti < g_type_count:
        return cell_load(g_types, ti * ESZ_TYPE_ROW + OFF_TR_EXTRA)
    return 0

fn grow_funcs(needed: int):
    if needed < g_func_cap:
        return
    nc : ., mut = g_func_cap * 2
    if nc < 64:
        nc = 64
    if nc < needed:
        nc = needed + 64
    nb := alloc(nc * ESZ_FUNCINFO)
    cell_copy(g_funcs, g_func_cap * ESZ_FUNCINFO, nb)
    g_funcs = nb
    g_func_cap = nc

fn grow_structs(needed: int):
    if needed < g_struct_cap:
        return
    nc : ., mut = g_struct_cap * 2
    if nc < 32:
        nc = 32
    if nc < needed:
        nc = needed + 32
    nb := alloc(nc * ESZ_STRUCTINFO)
    cell_copy(g_structs, g_struct_cap * ESZ_STRUCTINFO, nb)
    g_structs = nb
    g_struct_cap = nc

fn grow_enums(needed: int):
    if needed < g_enum_cap:
        return
    nc : ., mut = g_enum_cap * 2
    if nc < 16:
        nc = 16
    if nc < needed:
        nc = needed + 16
    nb := alloc(nc * ESZ_ENUMINFO)
    cell_copy(g_enums, g_enum_cap * ESZ_ENUMINFO, nb)
    g_enums = nb
    g_enum_cap = nc

fn grow_ifaces(needed: int):
    if needed < g_iface_cap:
        return
    nc : ., mut = g_iface_cap * 2
    if nc < 4:
        nc = 4
    if nc < needed:
        nc = needed + 4
    nb := alloc(nc * ESZ_IFACEINFO)
    cell_copy(g_ifaces, g_iface_cap * ESZ_IFACEINFO, nb)
    g_ifaces = nb
    g_iface_cap = nc

fn grow_ir_vars(needed: int):
    if needed < g_ir_var_cap:
        return
    nc : ., mut = g_ir_var_cap * 2
    if nc < 128:
        nc = 128
    if nc < needed:
        nc = needed + 128
    nb := alloc(nc * ESZ_IRVAR)
    cell_copy(g_ir_vars, g_ir_var_cap * ESZ_IRVAR, nb)
    g_ir_vars = nb
    g_ir_var_cap = nc

fn grow_ir_instrs(needed: int):
    if needed < g_ir_instr_cap:
        return
    nc : ., mut = g_ir_instr_cap * 2
    if nc < 128:
        nc = 128
    if nc < needed:
        nc = needed + 128
    nb := alloc(nc * ESZ_IRINSTR)
    cell_copy(g_ir_instrs, g_ir_instr_cap * ESZ_IRINSTR, nb)
    g_ir_instrs = nb
    g_ir_instr_cap = nc

fn grow_ir_locals(needed: int):
    if needed < g_ir_local_cap:
        return
    nc : ., mut = g_ir_local_cap * 2
    if nc < 64:
        nc = 64
    if nc < needed:
        nc = needed + 64
    nb := alloc(nc * 16)
    cell_copy(g_ir_locals, g_ir_local_cap * 16, nb)
    g_ir_locals = nb
    g_ir_local_cap = nc

fn grow_ir_globals(needed: int):
    if needed < g_ir_global_cap:
        return
    nc : ., mut = g_ir_global_cap * 2
    if nc < 16:
        nc = 16
    if nc < needed:
        nc = needed + 16
    nb := alloc(nc * 24)
    cell_copy(g_ir_globals, g_ir_global_cap * 24, nb)
    g_ir_globals = nb
    g_ir_global_cap = nc

fn grow_ir_str_consts(needed: int):
    if needed < g_ir_str_const_cap:
        return
    nc : ., mut = g_ir_str_const_cap * 2
    if nc < 64:
        nc = 64
    if nc < needed:
        nc = needed + 64
    nb := alloc(nc * 8)
    cell_copy(g_ir_str_consts, g_ir_str_const_cap * 8, nb)
    g_ir_str_consts = nb
    g_ir_str_const_cap = nc

fn grow_errors(needed: int):
    if needed < g_err_cap:
        return
    nc : ., mut = g_err_cap * 2
    if nc < 16:
        nc = 16
    if nc < needed:
        nc = needed + 16
    nb := alloc(nc * 8)
    cell_copy(g_errors, g_err_cap * 8, nb)
    g_errors = nb
    g_err_cap = nc

fn grow_block_stmts(needed: int):
    if needed < g_block_stmt_cap:
        return
    nc : ., mut = g_block_stmt_cap * 2
    if nc < 64:
        nc = 64
    if nc < needed:
        nc = needed + 64
    nb := alloc(nc * 8)
    cell_copy(g_block_stmts, g_block_stmt_cap * 8, nb)
    g_block_stmts = nb
    g_block_stmt_cap = nc

fn grow_ir_func_meta(needed: int):
    if needed < g_ir_func_name_idx_cap:
        return
    if needed < g_ir_func_name_idx_cap:
        return
    nc : ., mut = g_ir_func_name_idx_cap * 2
    if nc < 64:
        nc = 64
    if nc < needed:
        nc = needed + 64
    sz := nc * 8
    n1 := alloc(sz)
    cell_copy(g_ir_func_name_idx, g_ir_func_name_idx_cap*8, n1)
    g_ir_func_name_idx = n1
    n2 := alloc(sz)
    cell_copy(g_ir_func_ret_type, g_ir_func_ret_type_cap*8, n2)
    g_ir_func_ret_type = n2
    n3 := alloc(sz)
    cell_copy(g_ir_func_instr_start, g_ir_func_instr_start_cap*8, n3)
    g_ir_func_instr_start = n3
    n4 := alloc(sz)
    cell_copy(g_ir_func_instr_count, g_ir_func_instr_count_cap*8, n4)
    g_ir_func_instr_count = n4
    n5 := alloc(sz)
    cell_copy(g_ir_func_var_start, g_ir_func_var_start_cap*8, n5)
    g_ir_func_var_start = n5
    n6 := alloc(sz)
    cell_copy(g_ir_func_var_count, g_ir_func_var_count_cap*8, n6)
    g_ir_func_var_count = n6
    n7 := alloc(sz)
    cell_copy(g_ir_func_param_count, g_ir_func_param_count_cap*8, n7)
    g_ir_func_param_count = n7
    g_ir_func_name_idx_cap=nc
    g_ir_func_ret_type_cap=nc
    g_ir_func_instr_start_cap=nc
    g_ir_func_instr_count_cap=nc
    g_ir_func_var_start_cap=nc
    g_ir_func_var_count_cap=nc
    g_ir_func_param_count_cap=nc

// ============================================================
// Accessor helpers for AST node fields
// ============================================================
fn ast_kind(n: int) -> int:
    return cell_load(g_ast, n * ESZ_ASTNODE + OFF_AS_KIND)
fn ast_a(n: int) -> int:
    return cell_load(g_ast, n * ESZ_ASTNODE + OFF_AS_A)
fn ast_b(n: int) -> int:
    return cell_load(g_ast, n * ESZ_ASTNODE + OFF_AS_B)
fn ast_c(n: int) -> int:
    return cell_load(g_ast, n * ESZ_ASTNODE + OFF_AS_C)
fn ast_int_val(n: int) -> int:
    return cell_load(g_ast, n * ESZ_ASTNODE + OFF_AS_INTVAL)
fn ast_type_val(n: int) -> int:
    return cell_load(g_ast, n * ESZ_ASTNODE + OFF_AS_TYPEVAL)
fn ast_data(n: int) -> int:
    return cell_load(g_ast, n * ESZ_ASTNODE + OFF_AS_DATA)
fn ast_line(n: int) -> int:
    return cell_load(g_ast, n * ESZ_ASTNODE + OFF_AS_LINE)
fn ast_col(n: int) -> int:
    return cell_load(g_ast, n * ESZ_ASTNODE + OFF_AS_COL)

fn ast_set_kind(n: int, v: int):
    cell_store(g_ast, n * ESZ_ASTNODE + OFF_AS_KIND, v)
fn ast_set_a(n: int, v: int):
    cell_store(g_ast, n * ESZ_ASTNODE + OFF_AS_A, v)
fn ast_set_b(n: int, v: int):
    cell_store(g_ast, n * ESZ_ASTNODE + OFF_AS_B, v)
fn ast_set_c(n: int, v: int):
    cell_store(g_ast, n * ESZ_ASTNODE + OFF_AS_C, v)
fn ast_set_int_val(n: int, v: int):
    cell_store(g_ast, n * ESZ_ASTNODE + OFF_AS_INTVAL, v)
fn ast_set_type_val(n: int, v: int):
    cell_store(g_ast, n * ESZ_ASTNODE + OFF_AS_TYPEVAL, v)
fn ast_set_data(n: int, v: int):
    cell_store(g_ast, n * ESZ_ASTNODE + OFF_AS_DATA, v)
fn ast_set_line(n: int, v: int):
    cell_store(g_ast, n * ESZ_ASTNODE + OFF_AS_LINE, v)
fn ast_set_col(n: int, v: int):
    cell_store(g_ast, n * ESZ_ASTNODE + OFF_AS_COL, v)

fn ast_alloc(kind: int, a: int, b: int, c: int, iv: int, tv: int, d: int, line: int, col: int) -> int:
    idx := g_ast_count
    grow_ast(idx + 1)
    cell_store(g_ast, idx * ESZ_ASTNODE + OFF_AS_KIND, kind)
    cell_store(g_ast, idx * ESZ_ASTNODE + OFF_AS_A, a)
    cell_store(g_ast, idx * ESZ_ASTNODE + OFF_AS_B, b)
    cell_store(g_ast, idx * ESZ_ASTNODE + OFF_AS_C, c)
    cell_store(g_ast, idx * ESZ_ASTNODE + OFF_AS_INTVAL, iv)
    cell_store(g_ast, idx * ESZ_ASTNODE + OFF_AS_TYPEVAL, tv)
    cell_store(g_ast, idx * ESZ_ASTNODE + OFF_AS_DATA, d)
    cell_store(g_ast, idx * ESZ_ASTNODE + OFF_AS_LINE, line)
    cell_store(g_ast, idx * ESZ_ASTNODE + OFF_AS_COL, col)
    g_ast_count = idx + 1
    return idx

// SymEntry accessors. Reads check n against [0, g_sym_count) and return -1 without
// touching memory when out of range. The guard is needed because the bootstrap
// build does not short-circuit &&: a check such as `existing_si >= 0 &&
// sym_kind(existing_si)` still evaluates sym_kind(-1), which would read a negative
// offset from a NULL g_syms when no type declaration has been registered yet.
fn sym_name(n: int) -> int:
    if n < 0 || n >= g_sym_count:
        return -1
    return cell_load(g_syms, n * ESZ_SYMENTRY + OFF_SY_NAME)
fn sym_kind(n: int) -> int:
    if n < 0 || n >= g_sym_count:
        return -1
    return cell_load(g_syms, n * ESZ_SYMENTRY + OFF_SY_KIND)
fn sym_type(n: int) -> int:
    if n < 0 || n >= g_sym_count:
        return -1
    return cell_load(g_syms, n * ESZ_SYMENTRY + OFF_SY_TYPE)
fn sym_node(n: int) -> int:
    if n < 0 || n >= g_sym_count:
        return -1
    return cell_load(g_syms, n * ESZ_SYMENTRY + OFF_SY_NODE)
fn sym_set_name(n: int, v: int):
    cell_store(g_syms, n * ESZ_SYMENTRY + OFF_SY_NAME, v)
fn sym_set_kind(n: int, v: int):
    cell_store(g_syms, n * ESZ_SYMENTRY + OFF_SY_KIND, v)
fn sym_set_type(n: int, v: int):
    cell_store(g_syms, n * ESZ_SYMENTRY + OFF_SY_TYPE, v)
fn sym_set_node(n: int, v: int):
    cell_store(g_syms, n * ESZ_SYMENTRY + OFF_SY_NODE, v)

// IRVar helpers
fn irv_name(n: int) -> int:
    return cell_load(g_ir_vars, n * ESZ_IRVAR + OFF_IRV_NAME)
fn irv_id(n: int) -> int:
    return cell_load(g_ir_vars, n * ESZ_IRVAR + OFF_IRV_ID)
fn irv_type(n: int) -> int:
    return cell_load(g_ir_vars, n * ESZ_IRVAR + OFF_IRV_TYPE)
fn irv_set_name(n: int, v: int):
    cell_store(g_ir_vars, n * ESZ_IRVAR + OFF_IRV_NAME, v)
fn irv_set_id(n: int, v: int):
    cell_store(g_ir_vars, n * ESZ_IRVAR + OFF_IRV_ID, v)
fn irv_set_type(n: int, v: int):
    cell_store(g_ir_vars, n * ESZ_IRVAR + OFF_IRV_TYPE, v)

// IRInstr helpers
fn iri_op(n: int) -> int:
    return cell_load(g_ir_instrs, n * ESZ_IRINSTR + OFF_IRI_OP)
fn iri_dest(n: int) -> int:
    return cell_load(g_ir_instrs, n * ESZ_IRINSTR + OFF_IRI_DEST)
fn iri_s1(n: int) -> int:
    return cell_load(g_ir_instrs, n * ESZ_IRINSTR + OFF_IRI_S1)
fn iri_s2(n: int) -> int:
    return cell_load(g_ir_instrs, n * ESZ_IRINSTR + OFF_IRI_S2)
fn iri_s3(n: int) -> int:
    return cell_load(g_ir_instrs, n * ESZ_IRINSTR + OFF_IRI_S3)
fn iri_tk(n: int) -> int:
    return cell_load(g_ir_instrs, n * ESZ_IRINSTR + OFF_IRI_TK)
fn iri_set_op(n: int, v: int):
    cell_store(g_ir_instrs, n * ESZ_IRINSTR + OFF_IRI_OP, v)
fn iri_set_dest(n: int, v: int):
    cell_store(g_ir_instrs, n * ESZ_IRINSTR + OFF_IRI_DEST, v)
fn iri_set_s1(n: int, v: int):
    cell_store(g_ir_instrs, n * ESZ_IRINSTR + OFF_IRI_S1, v)
fn iri_set_s2(n: int, v: int):
    cell_store(g_ir_instrs, n * ESZ_IRINSTR + OFF_IRI_S2, v)
fn iri_set_s3(n: int, v: int):
    cell_store(g_ir_instrs, n * ESZ_IRINSTR + OFF_IRI_S3, v)
fn iri_set_tk(n: int, v: int):
    cell_store(g_ir_instrs, n * ESZ_IRINSTR + OFF_IRI_TK, v)

// Variable-name lookup. It lives here because regalloc.cr in corearch consumes it,
// and the corearch build does not include ir_gen.cr.
fn get_ir_var_name(var_idx: int) -> string:
    if var_idx >= 0 && var_idx < g_ir_var_count:
        ni := irv_name(var_idx)
        return istr_get(ni)
    return ""

// FuncInfo helpers
fn fi_name(n: int) -> int:
    return cell_load(g_funcs, n * ESZ_FUNCINFO + OFF_FI_NAME)
fn fi_param_count(n: int) -> int:
    return cell_load(g_funcs, n * ESZ_FUNCINFO + OFF_FI_PARAM_COUNT)
fn fi_return_type(n: int) -> int:
    return cell_load(g_funcs, n * ESZ_FUNCINFO + OFF_FI_RETURN_TYPE)
fn fi_ast_node(n: int) -> int:
    return cell_load(g_funcs, n * ESZ_FUNCINFO + OFF_FI_AST_NODE)
fn fi_generic_count(n: int) -> int:
    return cell_load(g_funcs, n * ESZ_FUNCINFO + OFF_FI_GENERIC_COUNT)
fn fi_param_type(n: int, pi: int) -> int:
    if pi < 0 || pi >= MAX_FN_PARAMS:
        return 0
    // Out of range: read guard only; writes have the same guard plus parser P020.
    return cell_load(g_funcs, n * ESZ_FUNCINFO + OFF_FI_PARAM_TYPES + pi * 8)
fn fi_generic_name(n: int, gi: int) -> int:
    return cell_load(g_funcs, n * ESZ_FUNCINFO + OFF_FI_GENERIC_NAMES + gi * 8)
fn fi_set_name(n: int, v: int):
    cell_store(g_funcs, n * ESZ_FUNCINFO + OFF_FI_NAME, v)
fn fi_set_param_count(n: int, v: int):
    cell_store(g_funcs, n * ESZ_FUNCINFO + OFF_FI_PARAM_COUNT, v)
fn fi_set_param_type(n: int, pi: int, v: int):
    if pi < 0 || pi >= MAX_FN_PARAMS:
        return
    // Slot guard. An out-of-range write would overwrite return_type, ast_node,
    // generic_*, and ispure.
    cell_store(g_funcs, n * ESZ_FUNCINFO + OFF_FI_PARAM_TYPES + pi*8, v)
fn fi_set_return_type(n: int, v: int):
    cell_store(g_funcs, n * ESZ_FUNCINFO + OFF_FI_RETURN_TYPE, v)
fn fi_set_ast_node(n: int, v: int):
    cell_store(g_funcs, n * ESZ_FUNCINFO + OFF_FI_AST_NODE, v)
fn fi_set_generic_name(n: int, gi: int, v: int):
    cell_store(g_funcs, n * ESZ_FUNCINFO + OFF_FI_GENERIC_NAMES + gi*8, v)
fn fi_set_generic_count(n: int, v: int):
    cell_store(g_funcs, n * ESZ_FUNCINFO + OFF_FI_GENERIC_COUNT, v)

fn fi_ispure(n: int) -> int:
    return cell_load(g_funcs, n * ESZ_FUNCINFO + OFF_FI_ISPURE)
fn fi_set_ispure(n: int, v: int):
    cell_store(g_funcs, n * ESZ_FUNCINFO + OFF_FI_ISPURE, v)

// StructInfo helpers
fn si_name(n: int) -> int:
    return cell_load(g_structs, n * ESZ_STRUCTINFO + OFF_SI_NAME)
fn si_field_count(n: int) -> int:
    return cell_load(g_structs, n * ESZ_STRUCTINFO + OFF_SI_FIELD_COUNT)
fn si_generic_count(n: int) -> int:
    return cell_load(g_structs, n * ESZ_STRUCTINFO + OFF_SI_GENERIC_COUNT)
// Struct field side tables. OFF_SI_FIELD_BASE is the starting row and
// OFF_SI_FIELD_COUNT is the true count. Three flat tables are addressed by record
// base + field index. si_commit_fields advances g_si_f_used, reserving the whole
// field range so records do not overlap.
fn grow_si_fields(needed: int):
    if needed <= g_si_f_cap:
        return
    nc := g_si_f_cap * 2
    if nc < 64:
        nc = 64
    if nc < needed:
        nc = needed + 64
    nb := alloc(nc * 8)
    cell_copy(g_si_f_names, g_si_f_cap * 8, nb)
    g_si_f_names = nb
    tb := alloc(nc * 8)
    cell_copy(g_si_f_types, g_si_f_cap * 8, tb)
    g_si_f_types = tb
    ob := alloc(nc * 8)
    cell_copy(g_si_f_nodes, g_si_f_cap * 8, ob)
    g_si_f_nodes = ob
    g_si_f_cap = nc
fn si_field_base(n: int) -> int:
    return cell_load(g_structs, n * ESZ_STRUCTINFO + OFF_SI_FIELD_BASE)
fn si_set_field_base(n: int, v: int):
    cell_store(g_structs, n * ESZ_STRUCTINFO + OFF_SI_FIELD_BASE, v)
// Commit the field range, advancing the high-water mark to base + count. parser and
// the ccr_io loader share this.
fn si_commit_fields(n: int, fc: int):
    b := si_field_base(n)
    if b < 0:
        return
    if fc < 0:
        return
    if b + fc > g_si_f_used:
        g_si_f_used = b + fc
// Read guard. fi outside [0, count) returns -1 without touching memory; an in-range
// read returns the side-table value.
fn si_field_row(n: int, fi: int) -> int:
    if fi < 0:
        return -1
    if fi >= si_field_count(n):
        return -1
    b := si_field_base(n)
    if b < 0:
        return -1
    return b + fi
fn si_field_name(n: int, fi: int) -> int:
    r := si_field_row(n, fi)
    if r < 0:
        return -1
    return cell_load(g_si_f_names, r * 8)
fn si_field_type(n: int, fi: int) -> int:
    r := si_field_row(n, fi)
    if r < 0:
        return -1
    return cell_load(g_si_f_types, r * 8)
fn si_field_type_node(n: int, fi: int) -> int:
    r := si_field_row(n, fi)
    if r < 0:
        return -1
    return cell_load(g_si_f_nodes, r * 8)
fn si_generic_name(n: int, gi: int) -> int:
    return cell_load(g_structs, n*ESZ_STRUCTINFO + OFF_SI_GENERIC_NAMES + gi*8)

// EnumInfo helpers
fn ei_name(n: int) -> int:
    return cell_load(g_enums, n * ESZ_ENUMINFO + OFF_EI_NAME)
fn ei_variant_count(n: int) -> int:
    return cell_load(g_enums, n * ESZ_ENUMINFO + OFF_EI_VARIANT_COUNT)
fn ei_generic_count(n: int) -> int:
    return cell_load(g_enums, n * ESZ_ENUMINFO + OFF_EI_GENERIC_COUNT)
fn ei_generic_name(n: int, gi: int) -> int:
    return cell_load(g_enums, n*ESZ_ENUMINFO + OFF_EI_GENERIC_NAMES + gi*8)
// Read guard: out-of-range reads return -1 for names, type codes, and type nodes,
// and 0 for counts. They never read the neighboring record.
// Enum variant side tables, the same shape as struct fields.
fn grow_ei_variants(needed: int):
    if needed <= g_ei_v_cap:
        return
    nc := g_ei_v_cap * 2
    if nc < 64:
        nc = 64
    if nc < needed:
        nc = needed + 64
    a := alloc(nc * 8)
    cell_copy(g_ei_v_names, g_ei_v_cap * 8, a)
    g_ei_v_names = a
    b := alloc(nc * 8)
    cell_copy(g_ei_v_tbase, g_ei_v_cap * 8, b)
    g_ei_v_tbase = b
    c := alloc(nc * 8)
    cell_copy(g_ei_v_tcount, g_ei_v_cap * 8, c)
    g_ei_v_tcount = c
    z : ., mut = g_ei_v_cap
    loop:
        if z >= nc:
            break
        cell_store(b, z * 8, -1)
        z = z + 1
    // tbase 新槽 = -1 哨兵
    g_ei_v_cap = nc
fn grow_ei_vtypes(needed: int):
    if needed <= g_ei_vt_cap:
        return
    nc := g_ei_vt_cap * 2
    if nc < 64:
        nc = 64
    if nc < needed:
        nc = needed + 64
    a := alloc(nc * 8)
    cell_copy(g_ei_vt_types, g_ei_vt_cap * 8, a)
    g_ei_vt_types = a
    b := alloc(nc * 8)
    cell_copy(g_ei_vt_nodes, g_ei_vt_cap * 8, b)
    g_ei_vt_nodes = b
    g_ei_vt_cap = nc
fn ei_variant_base(n: int) -> int:
    return cell_load(g_enums, n * ESZ_ENUMINFO + OFF_EI_VARIANTS)
fn ei_set_variant_base(n: int, v: int):
    cell_store(g_enums, n * ESZ_ENUMINFO + OFF_EI_VARIANTS, v)
fn ei_commit_variants(n: int, vc: int):
    b := ei_variant_base(n)
    if b < 0:
        return
    if vc < 0:
        return
    if b + vc > g_ei_v_used:
        g_ei_v_used = b + vc
fn ei_variant_row(n: int, vi: int) -> int:
    if vi < 0:
        return -1
    if vi >= ei_variant_count(n):
        return -1
    b := ei_variant_base(n)
    if b < 0:
        return -1
    return b + vi
fn ei_variant_name(n: int, vi: int) -> int:
    r := ei_variant_row(n, vi)
    if r < 0:
        return -1
    return cell_load(g_ei_v_names, r * 8)
fn ei_variant_type_count(n: int, vi: int) -> int:
    r := ei_variant_row(n, vi)
    if r < 0:
        return 0
    return cell_load(g_ei_v_tcount, r * 8)
fn ei_variant_type(n: int, vi: int, ti: int) -> int:
    r := ei_variant_row(n, vi)
    if r < 0:
        return -1
    if ti < 0 || ti >= cell_load(g_ei_v_tcount, r * 8):
        return -1
    tb := cell_load(g_ei_v_tbase, r * 8)
    if tb < 0:
        return -1
    return cell_load(g_ei_vt_types, (tb + ti) * 8)
// Type node of payload ti, or -1/0 when there is no information. The .ccr does not
// store this column, so a loader read returns 0. Consumers must bound ti by
// type_count and must not interpret 0 as node 0.
fn ei_variant_type_node(n: int, vi: int, ti: int) -> int:
    r := ei_variant_row(n, vi)
    if r < 0:
        return -1
    if ti < 0 || ti >= cell_load(g_ei_v_tcount, r * 8):
        return -1
    tb := cell_load(g_ei_v_tbase, r * 8)
    if tb < 0:
        return -1
    return cell_load(g_ei_vt_nodes, (tb + ti) * 8)

// Guarded enum and struct accessors.
// Field and variant storage now lives in side tables. The setters below are the
// only write points and all parser writes go through them, so a future call site
// cannot write out of bounds. Read accessors return -1 for names and nodes and 0
// for counts when out of range. User-facing rejection is parser P022/P023; this
// layer only guarantees memory safety.
// Count slots are not guarded: the true count is needed for diagnostics, and an
// over-limit declaration is rejected by the parser.
fn ei_set_variant_name(n: int, vi: int, v: int):
    if vi < 0:
        return
    b := ei_variant_base(n)
    if b < 0:
        return
    grow_ei_variants(b + vi + 1)
    if b + vi + 1 > g_ei_v_used:
        g_ei_v_used = b + vi + 1
    cell_store(g_ei_v_names, (b + vi) * 8, v)
// Payload bases are allocated lazily: the first payload write reserves from the high-water mark.

fn ei_variant_tbase_ensure(n: int, vi: int) -> int:
    b := ei_variant_base(n)
    if b < 0:
        return -1
    grow_ei_variants(b + vi + 1)
    r := b + vi
    tb := cell_load(g_ei_v_tbase, r * 8)
    if tb < 0:
        tb = g_ei_vt_used
        cell_store(g_ei_v_tbase, r * 8, tb)
    return tb
fn ei_set_variant_type(n: int, vi: int, ti: int, v: int):
    if vi < 0 || ti < 0:
        return
    tb := ei_variant_tbase_ensure(n, vi)
    if tb < 0:
        return
    grow_ei_vtypes(tb + ti + 1)
    cell_store(g_ei_vt_types, (tb + ti) * 8, v)
    if tb + ti + 1 > g_ei_vt_used:
        g_ei_vt_used = tb + ti + 1
fn ei_set_variant_type_count(n: int, vi: int, v: int):
    if vi < 0:
        return
    b := ei_variant_base(n)
    if b < 0:
        return
    grow_ei_variants(b + vi + 1)
    cell_store(g_ei_v_tcount, (b + vi) * 8, v)
    if v > 0:
        tb := ei_variant_tbase_ensure(n, vi)   // 申报区间整体占位（未写槽亦不与他人重叠）
        if tb >= 0 && tb + v > g_ei_vt_used:
            g_ei_vt_used = tb + v
fn ei_set_variant_type_node(n: int, vi: int, ti: int, v: int):
    if vi < 0 || ti < 0:
        return
    tb := ei_variant_tbase_ensure(n, vi)
    if tb < 0:
        return
    grow_ei_vtypes(tb + ti + 1)
    cell_store(g_ei_vt_nodes, (tb + ti) * 8, v)
    if tb + ti + 1 > g_ei_vt_used:
        g_ei_vt_used = tb + ti + 1
fn si_set_field_name(n: int, fi: int, v: int):
    if fi < 0:
        return
    b := si_field_base(n)
    if b < 0:
        return
    grow_si_fields(b + fi + 1)
    if b + fi + 1 > g_si_f_used:
        g_si_f_used = b + fi + 1
    cell_store(g_si_f_names, (b + fi) * 8, v)
fn si_set_field_type(n: int, fi: int, v: int):
    if fi < 0:
        return
    b := si_field_base(n)
    if b < 0:
        return
    grow_si_fields(b + fi + 1)
    if b + fi + 1 > g_si_f_used:
        g_si_f_used = b + fi + 1
    cell_store(g_si_f_types, (b + fi) * 8, v)
fn si_set_field_type_node(n: int, fi: int, v: int):
    if fi < 0:
        return
    b := si_field_base(n)
    if b < 0:
        return
    grow_si_fields(b + fi + 1)
    if b + fi + 1 > g_si_f_used:
        g_si_f_used = b + fi + 1
    cell_store(g_si_f_nodes, (b + fi) * 8, v)

// ============================================================
// String table helpers (dynamic byte buffer)
// ============================================================
fn grow_g_strs(needed: int):
    if needed < g_str_cap:
        return
    nc : ., mut = g_str_cap * 2
    if nc < 64:
        nc = 64
    if nc < needed:
        nc = needed + 64
    nb := alloc(nc * 8)
    cell_copy(g_strs, g_str_cap * 8, nb)
    g_strs = nb
    g_str_cap = nc

fn str_hash(s: string) -> int:
    h : ., mut = 5381
    i : ., mut = 0
    loop:
        c := cell_load_byte(s, i)
        if c == 0:
            break
        h = h * 33 + c
        i = i + 1
    return h

// Hash arbitrary bytes (for function body content fingerprinting).
// Uses a multiplicative hash similar to str_hash but with FNV-inspired
// constants for better distribution over byte ranges.
fn hash_bytes(data: string, len: int) -> int:
    h : ., mut = 2166136261  // FNV offset basis
    i : ., mut = 0
    loop:
        if i >= len:
            break
        h = h * 16777619  // FNV prime
        h = h + (cell_load_byte(data, i) % 256)
        i = i + 1
    return h

fn _grow_str_hash(ncap: int):
    // Allocate new table filled with -1, rehash all existing strings
    nb := alloc(ncap * 8)
    i : ., mut = 0
    loop:
        if i >= ncap:
            break
        cell_store(nb, i * 8, -1)
        i = i + 1

    // Rehash all strings already in g_strs into new table
    si : ., mut = 0
    loop:
        if si >= g_str_count:
            break
        s := cell_load_str(g_strs, si * 8)
        h := str_hash(s)
        pos := h % ncap
        if pos < 0:
            pos = -pos
        loop:
            if cell_load(nb, pos * 8) < 0:
                cell_store(nb, pos * 8, si)
                break
            pos = (pos + 1) % ncap
        si = si + 1
    g_str_hash = nb
    g_str_hash_cap = ncap

fn str_intern(s: string) -> int:
    // Lazy init hash table
    if g_str_hash_cap == 0:
        _grow_str_hash(64)

    // Hash lookup
    h := str_hash(s)
    cap := g_str_hash_cap
    pos := h % cap
    if pos < 0:
        pos = -pos
    loop:
        si := cell_load(g_str_hash, pos * 8)
        if si < 0:
            break
        // Empty slot means not found.
        if str_eq(cell_load_str(g_strs, si * 8), s) != 0:
            return si
        pos = (pos + 1) % cap

    // Not found: insert
    grow_g_strs(g_str_count + 1)
    cell_store_str(g_strs, g_str_count * 8, s)
    g_str_count = g_str_count + 1

    // This is the only insertion path for interned strings, so every new string
    // created during generation enters the journal. See globals.cr.
    if g_cir_rec_on != 0:
        cir_rec_push(g_str_count - 1)

    // Insert into hash table (pos is the empty slot we found)
    cell_store(g_str_hash, pos * 8, g_str_count - 1)

    // Auto-rehash if load > 70%
    if g_str_count * 10 > g_str_hash_cap * 7:
        _grow_str_hash(g_str_hash_cap * 2)
    return g_str_count - 1

// Append one journal entry. The only caller is str_intern's insertion path.
// It records the local id; cir_cache.cr resolves it to the string content when
// saving, because ids are not meaningful across processes.
fn cir_rec_push(si: int):
    if g_cir_rec_count >= g_cir_rec_cap:
        nc := g_cir_rec_cap * 2
        if nc < 64:
            nc = 64
        nb := alloc(nc * 8)
        cell_copy(g_cir_rec_ids, g_cir_rec_cap * 8, nb)
        g_cir_rec_ids = nb
        g_cir_rec_cap = nc
    cell_store(g_cir_rec_ids, g_cir_rec_count * 8, si)
    g_cir_rec_count = g_cir_rec_count + 1

fn istr_get(idx: int) -> string:
    if idx < 0 || idx >= g_str_count:
        return ""
    return cell_load_str(g_strs, idx * 8)

fn istr_len(idx: int) -> int:
    if idx < 0 || idx >= g_str_count:
        return 0
    return str_len(istr_get(idx))

fn str_load8(idx: int, ci: int) -> int:
    if idx < 0 || idx >= g_str_count:
        return 0
    return cell_load_byte(istr_get(idx), ci)

fn grow_line_file(needed: int):
    if needed < g_line_cap:
        return
    nc : ., mut = g_line_cap * 2
    if nc < 128:
        nc = 128
    if nc < needed:
        nc = needed + 128
    nb := alloc(nc * 8)
    cell_copy(g_line_fileid, g_line_cap * 8, nb)
    g_line_fileid = nb
    g_line_cap = nc
fn grow_segs(needed: int):
    if needed < g_seg_cap:
        return
    nc : ., mut = g_seg_cap * 2
    if nc < 16:
        nc = 16
    if nc < needed:
        nc = needed + 16
    sz := nc * 8
    n1 := alloc(sz)
    cell_copy(g_seg_starts, g_seg_cap * 8, n1)
    g_seg_starts = n1
    n2 := alloc(sz)
    cell_copy(g_seg_fileids, g_seg_cap * 8, n2)
    g_seg_fileids = n2
    g_seg_cap = nc
fn grow_gen_apply_data(needed: int):
    if needed < g_gen_apply_data_cap:
        return
    nc : ., mut = g_gen_apply_data_cap * 2
    if nc < 64:
        nc = 64
    if nc < needed:
        nc = needed + 64
    nb := alloc(nc * 8)
    cell_copy(g_gen_apply_data, g_gen_apply_data_cap * 8, nb)
    g_gen_apply_data = nb
    g_gen_apply_data_cap = nc
fn grow_df_nodes(needed: int):
    if needed < g_df_node_cap:
        return
    nc : ., mut = g_df_node_cap * 2
    if nc < 128:
        nc = 128
    if nc < needed:
        nc = needed + 128
    nb := alloc(nc * ESZ_DFNODE)
    cell_copy(g_df_nodes, g_df_node_cap * ESZ_DFNODE, nb)
    g_df_nodes = nb
    g_df_node_cap = nc
fn grow_df_node_region(needed: int):
    if needed < g_df_node_region_cap:
        return
    nc : ., mut = g_df_node_region_cap * 2
    if nc < 128:
        nc = 128
    if nc < needed:
        nc = needed + 128
    nb := alloc(nc * 8)
    cell_copy(g_df_node_region, g_df_node_region_cap * 8, nb)
    g_df_node_region = nb
    g_df_node_region_cap = nc
fn grow_df_edges(needed: int):
    if needed < g_df_edge_cap:
        return
    nc : ., mut = g_df_edge_cap * 2
    if nc < 128:
        nc = 128
    if nc < needed:
        nc = needed + 128
    nb := alloc(nc * ESZ_DFEDGE)
    cell_copy(g_df_edges, g_df_edge_cap * ESZ_DFEDGE, nb)
    g_df_edges = nb
    g_df_edge_cap = nc
fn grow_df_arrays(needed: int):
    if needed < g_df_cap:
        return
    nc : ., mut = g_df_cap * 2
    if nc < 128:
        nc = 128
    if nc < needed:
        nc = needed + 128
    sz := nc * 8
    n1 := alloc(sz)
    cell_copy(g_df_var_producer, g_df_cap * 8, n1)
    // Initialize producer slots to -1. Newly allocated memory is not guaranteed to
    // be zeroed, and a zero would mean node 0, creating ghost edges 0->X and a
    // self-loop. The new range is filled explicitly; the copied range keeps its
    // values. df_create_node overwrites producers for variables it defines.
    zi : ., mut = g_df_cap
    loop:
        if zi >= nc:
            break
        cell_store(n1, zi * 8, -1)
        zi = zi + 1
    g_df_var_producer = n1
    n2 := alloc(sz)
    cell_copy(g_df_func_node_start, g_df_cap * 8, n2)
    g_df_func_node_start = n2
    n3 := alloc(sz)
    cell_copy(g_df_func_node_count, g_df_cap * 8, n3)
    g_df_func_node_count = n3
    // Per-function edge starts grow with g_df_cap. df_begin_func overwrites the
    // slot for each function, and readers only access it afterwards.
    n4 := alloc(sz)
    cell_copy(g_df_func_edge_start, g_df_cap * 8, n4)
    g_df_func_edge_start = n4
    g_df_cap = nc

fn grow_gen_map(needed: int):
    if needed < g_gen_map_cap:
        return
    nc : ., mut = g_gen_map_cap * 2
    if nc < 8:
        nc = 8
    if nc < needed:
        nc = needed + 8
    sz := nc * 8
    n1 := alloc(sz)
    cell_copy(g_gen_map_names, g_gen_map_cap*8, n1)
    g_gen_map_names = n1
    n2 := alloc(sz)
    cell_copy(g_gen_map_types, g_gen_map_cap*8, n2)
    g_gen_map_types = n2
    g_gen_map_cap = nc
fn grow_borrow_vars(needed: int):
    if needed < g_borrow_cap:
        return
    nc : ., mut = g_borrow_cap * 2
    if nc < 16:
        nc = 16
    if nc < needed:
        nc = needed + 16
    sz := nc * 8
    n1 := alloc(sz)
    cell_copy(g_borrow_vars, g_borrow_cap*8, n1)
    g_borrow_vars = n1
    n2 := alloc(sz)
    cell_copy(g_borrow_refs, g_borrow_cap*8, n2)
    g_borrow_refs = n2
    n3 := alloc(sz)
    cell_copy(g_borrow_muts, g_borrow_cap*8, n3)
    g_borrow_muts = n3
    g_borrow_cap = nc
fn grow_holder(needed: int):
    if needed < g_holder_cap:
        return
    nc : ., mut = g_holder_cap * 2
    if nc < 16:
        nc = 16
    if nc < needed:
        nc = needed + 16
    sz := nc * 8
    n1 := alloc(sz)
    cell_copy(g_holder_borrowers, g_holder_cap*8, n1)
    g_holder_borrowers = n1
    n2 := alloc(sz)
    cell_copy(g_holder_borrowed, g_holder_cap*8, n2)
    g_holder_borrowed = n2
    n3 := alloc(sz)
    cell_copy(g_holder_is_mut, g_holder_cap*8, n3)
    g_holder_is_mut = n3
    g_holder_cap = nc

fn grow_global_lets(needed: int):
    if needed < g_global_lets_cap:
        return
    nc : ., mut = g_global_lets_cap * 2
    if nc < 64:
        nc = 64
    if nc < needed:
        nc = needed + 64
    nb := alloc(nc * 8)
    cell_copy(g_global_lets, g_global_lets_cap * 8, nb)
    g_global_lets = nb
    g_global_lets_cap = nc
fn grow_loop_stack(needed: int):
    if needed < g_loop_stack_cap:
        return
    nc : ., mut = g_loop_stack_cap * 2
    if nc < 64:
        nc = 64
    if nc < needed:
        nc = needed + 64
    nb := alloc(nc * 24)
    cell_copy(g_loop_stack, g_loop_stack_cap * 24, nb)
    g_loop_stack = nb
    g_loop_stack_cap = nc
fn grow_type_aliases(needed: int):
    if needed < g_type_alias_cap:
        return
    nc : ., mut = g_type_alias_cap * 2
    if nc < 32:
        nc = 32
    if nc < needed:
        nc = needed + 32
    nb := alloc(nc * 16)
    cell_copy(g_type_aliases, g_type_alias_cap * 16, nb)
    g_type_aliases = nb
    g_type_alias_cap = nc
fn grow_scope_bounds(needed: int):
    if needed < g_scope_bounds_cap:
        return
    nc : ., mut = g_scope_bounds_cap * 2
    if nc < 64:
        nc = 64
    if nc < needed:
        nc = needed + 64
    nb := alloc(nc * 8)
    cell_copy(g_scope_bounds, g_scope_bounds_cap * 8, nb)
    g_scope_bounds = nb
    g_scope_bounds_cap = nc
fn grow_methods(needed: int):
    if needed < g_method_cap:
        return
    nc : ., mut = g_method_cap * 2
    if nc < 64:
        nc = 64
    if nc < needed:
        nc = needed + 64
    nb := alloc(nc * 24)
    cell_copy(g_methods, g_method_cap * 24, nb)
    g_methods = nb
    g_method_cap = nc
fn grow_borrow_markers(needed: int):
    if needed < g_borrow_scope_markers_cap:
        return
    nc : ., mut = g_borrow_scope_markers_cap * 2
    if nc < 64:
        nc = 64
    if nc < needed:
        nc = needed + 64
    nb := alloc(nc * 8)
    cell_copy(g_borrow_scope_markers, g_borrow_scope_markers_cap * 8, nb)
    g_borrow_scope_markers = nb
    g_borrow_scope_markers_cap = nc

fn istr_eq(idx: int, lit: string) -> int:
    if idx < 0 || idx >= g_str_count:
        return 0
    if str_eq(istr_get(idx), lit) != 0:
        return 1
    return 0

fn grow_so_side(needed: int):
    if needed < g_so_side_cap:
        return
    nc : ., mut = g_so_side_cap * 2
    if nc < 32:
        nc = 32
    if nc < needed:
        nc = needed + 32
    sz := nc * 8
    n1 := alloc(sz)
    cell_copy(g_so_side_name, g_so_side_cap*8, n1)
    g_so_side_name = n1
    n2 := alloc(sz)
    cell_copy(g_so_side_tags, g_so_side_cap*8, n2)
    g_so_side_tags = n2
    n3 := alloc(sz)
    cell_copy(g_so_side_type, g_so_side_cap*8, n3)
    g_so_side_type = n3
    g_so_side_cap = nc

// Spec annotation side table. It grows dynamically with no fixed limit.
fn grow_spec_side(needed: int):
    if needed < g_spec_cap:
        return
    nc : ., mut = g_spec_cap * 2
    if nc < 16:
        nc = 16
    if nc < needed:
        nc = needed + 16
    sz := nc * 8
    n1 := alloc(sz)
    cell_copy(g_spec_fn, g_spec_cap*8, n1)
    g_spec_fn = n1
    n6 := alloc(sz)
    cell_copy(g_spec_fnode, g_spec_cap*8, n6)
    g_spec_fnode = n6
    n7 := alloc(sz)
    cell_copy(g_spec_status, g_spec_cap*8, n7)
    g_spec_status = n7
    n2 := alloc(sz)
    cell_copy(g_spec_kind, g_spec_cap*8, n2)
    g_spec_kind = n2
    n3 := alloc(sz)
    cell_copy(g_spec_expr, g_spec_cap*8, n3)
    g_spec_expr = n3
    n4 := alloc(sz)
    cell_copy(g_spec_line, g_spec_cap*8, n4)
    g_spec_line = n4
    n5 := alloc(sz)
    cell_copy(g_spec_col, g_spec_cap*8, n5)
    g_spec_col = n5
    g_spec_cap = nc

// Append one annotation record. This is the only write point; records are in source order.
fn spec_add(fn_ni: int, kind: int, expr: int, line: int, col: int):
    grow_spec_side(g_spec_count + 1)
    i := g_spec_count
    cell_store(g_spec_fn, i * 8, fn_ni)
    cell_store(g_spec_fnode, i * 8, -1)   // 由 parser 在 EXPR_FN 分配后回填（spec_set_fnode）
    cell_store(g_spec_status, i * 8, SPEC_ST_YELLOW)
    cell_store(g_spec_kind, i * 8, kind)
    cell_store(g_spec_expr, i * 8, expr)
    cell_store(g_spec_line, i * 8, line)
    cell_store(g_spec_col, i * 8, col)
    g_spec_count = i + 1

// Guarded read accessors: out-of-range indexes return the sentinel and never read a neighboring record.
fn spec_fn(i: int) -> int:
    if i < 0 || i >= g_spec_count:
        return -1
    return cell_load(g_spec_fn, i * 8)
fn spec_fnode(i: int) -> int:
    if i < 0 || i >= g_spec_count:
        return -1
    return cell_load(g_spec_fnode, i * 8)
fn spec_status(i: int) -> int:
    if i < 0 || i >= g_spec_count:
        return -1
    return cell_load(g_spec_status, i * 8)
// Status write: red is sticky. A later green must not erase a hard error.
fn spec_set_status(i: int, st: int):
    if i < 0 || i >= g_spec_count:
        return
    cur := cell_load(g_spec_status, i * 8)
    if cur == SPEC_ST_RED:
        return
    cell_store(g_spec_status, i * 8, st)
fn spec_set_fnode(i: int, v: int):
    if i < 0 || i >= g_spec_count:
        return
    cell_store(g_spec_fnode, i * 8, v)
fn spec_kind(i: int) -> int:
    if i < 0 || i >= g_spec_count:
        return -1
    return cell_load(g_spec_kind, i * 8)
fn spec_expr(i: int) -> int:
    if i < 0 || i >= g_spec_count:
        return -1
    return cell_load(g_spec_expr, i * 8)
fn spec_line(i: int) -> int:
    if i < 0 || i >= g_spec_count:
        return -1
    return cell_load(g_spec_line, i * 8)
fn spec_col(i: int) -> int:
    if i < 0 || i >= g_spec_count:
        return -1
    return cell_load(g_spec_col, i * 8)

fn grow_pending(needed: int):
    if needed < g_pending_cap:
        return
    nc : ., mut = g_pending_cap * 2
    if nc < 64:
        nc = 64
    if nc < needed:
        nc = needed + 64
    nb := alloc(nc * 8)
    cell_copy(g_pending_pos, g_pending_cap * 8, nb)
    g_pending_pos = nb
    nb2 := alloc(nc * 8)
    cell_copy(g_pending_label, g_pending_cap * 8, nb2)
    g_pending_label = nb2
    g_pending_cap = nc
fn grow_opt_meta(needed: int):
    if needed <= g_opt_meta_cap:
        return
    nc : ., mut = g_opt_meta_cap * 2
    if nc < 16:
        nc = 16
    if nc < needed:
        nc = needed + 16
    nb := alloc(nc * OPT_META_STRIDE)
    cell_copy(g_opt_meta, g_opt_meta_count * OPT_META_STRIDE, nb)
    g_opt_meta = nb
    g_opt_meta_cap = nc
fn grow_ir_local_scopes(needed: int):
    if needed < g_ir_local_scopes_cap:
        return
    nc : ., mut = g_ir_local_scopes_cap * 2
    if nc < 64:
        nc = 64
    if nc < needed:
        nc = needed + 64
    nb := alloc(nc * 8)
    cell_copy(g_ir_local_scopes, g_ir_local_scopes_cap * 8, nb)
    g_ir_local_scopes = nb
    g_ir_local_scopes_cap = nc

fn grow_ir_loop_stacks(needed: int):
    if needed < g_ir_loop_stacks_cap:
        return
    nc : ., mut = g_ir_loop_stacks_cap * 2
    if nc < 64:
        nc = 64
    if nc < needed:
        nc = needed + 64
    n1 := alloc(nc * 8)
    cell_copy(g_ir_loop_header, g_ir_loop_stacks_cap * 8, n1)
    g_ir_loop_header = n1
    n2 := alloc(nc * 8)
    cell_copy(g_ir_loop_exit, g_ir_loop_stacks_cap * 8, n2)
    g_ir_loop_exit = n2
    g_ir_loop_stacks_cap = nc

fn grow_label_poses(needed: int):
    if needed < g_label_cap:
        return
    nc : ., mut = g_label_cap * 2
    if nc < 64:
        nc = 64
    if nc < needed:
        nc = needed + 64
    nb := alloc(nc * 8)
    cell_copy(g_label_poses, g_label_cap * 8, nb)
    g_label_poses = nb
    g_label_cap = nc

// ============================================================
// Grow functions for newly-converted arrays
// ============================================================

// Diag struct: code(8) + msg(8) + line(8) + col(8) + file_id(8) = 40 bytes
fn grow_diags(needed: int):
    if needed < g_diag_cap:
        return
    nc : ., mut = g_diag_cap * 2
    if nc < 16:
        nc = 16
    if nc < needed:
        nc = needed + 16
    nb := alloc(nc * DIAG_REC_SIZE)
    cell_copy(g_diags, g_diag_cap * DIAG_REC_SIZE, nb)
    g_diags = nb
    g_diag_cap = nc

// FileEntry: fileid_ni(8) + path(8) = 16 bytes
fn grow_files(needed: int):
    if needed < g_file_cap:
        return
    nc : ., mut = g_file_cap * 2
    if nc < 16:
        nc = 16
    if nc < needed:
        nc = needed + 16
    nb := alloc(nc * 16)
    cell_copy(g_files, g_file_cap * 16, nb)
    g_files = nb
    g_file_cap = nc

// ModEntry: alias_ni(8) + fileid_ni(8) + path(8) = 24 bytes
fn grow_mods(needed: int):
    if needed < g_mod_cap:
        return
    nc : ., mut = g_mod_cap * 2
    if nc < 16:
        nc = 16
    if nc < needed:
        nc = needed + 16
    nb := alloc(nc * 24)
    cell_copy(g_mods, g_mod_cap * 24, nb)
    g_mods = nb
    g_mod_cap = nc

// g_mod_func_fileids/names/tis: 3 parallel int arrays, 8 bytes per element each
fn grow_mod_funcs(needed: int):
    if needed < g_mod_func_cap:
        return
    nc : ., mut = g_mod_func_cap * 2
    if nc < 64:
        nc = 64
    if nc < needed:
        nc = needed + 64
    sz := nc * 8
    n1 := alloc(sz)
    cell_copy(g_mod_func_fileids, g_mod_func_cap * 8, n1)
    g_mod_func_fileids = n1
    n2 := alloc(sz)
    cell_copy(g_mod_func_names, g_mod_func_cap * 8, n2)
    g_mod_func_names = n2
    n3 := alloc(sz)
    cell_copy(g_mod_func_tis, g_mod_func_cap * 8, n3)
    g_mod_func_tis = n3
    g_mod_func_cap = nc

// g_mod_path_names: int array, 8 bytes per element
fn grow_mod_paths(needed: int):
    if needed < g_mod_path_cap:
        return
    nc : ., mut = g_mod_path_cap * 2
    if nc < 32:
        nc = 32
    if nc < needed:
        nc = needed + 32
    nb := alloc(nc * 8)
    cell_copy(g_mod_path_names, g_mod_path_cap * 8, nb)
    g_mod_path_names = nb
    g_mod_path_cap = nc

// impl-for: pairs of (interface_ni, type_ni), 16 bytes per pair
fn grow_impl_for(needed: int):
    if needed < g_impl_for_cap:
        return
    nc : ., mut = g_impl_for_cap * 2
    if nc < 8:
        nc = 8
    if nc < needed:
        nc = needed + 8
    nb := alloc(nc * 16)
    cell_copy(g_impl_for, g_impl_for_cap * 16, nb)
    g_impl_for = nb
    g_impl_for_cap = nc

// Generic param name storage (for <T> syntax parsing)
fn grow_gen_params(needed: int):
    if needed < g_gen_param_cap:
        return
    nc : ., mut = g_gen_param_cap * 2
    if nc < 16:
        nc = 16
    if nc < needed:
        nc = needed + 16
    nb := alloc(nc * 8)
    cell_copy(g_gen_params, g_gen_param_cap * 8, nb)
    g_gen_params = nb
    g_gen_param_cap = nc

// Generic constraints: for each (func_idx * MAX_GENERICS + param_idx), stores iface_ni or -1
fn grow_gen_constr(needed: int):
    if needed < g_generic_constr_cap:
        return
    nc : ., mut = g_generic_constr_cap * 2
    if nc < 16:
        nc = 16
    if nc < needed:
        nc = needed + 16
    nb := alloc(nc * 8)
    cell_copy(g_generic_constr, g_generic_constr_cap * 8, nb)
    g_generic_constr = nb
    g_generic_constr_cap = nc

// Struct and enum generic constraint side tables. Key = row * MAX_GENERICS + gi,
// a separate index space from function constraints. Growth matches grow_gen_constr.
fn grow_sgen_constr(needed: int):
    if needed < g_sgen_constr_cap:
        return
    nc : ., mut = g_sgen_constr_cap * 2
    if nc < 16:
        nc = 16
    if nc < needed:
        nc = needed + 16
    nb := alloc(nc * 8)
    cell_copy(g_sgen_constr, g_sgen_constr_cap * 8, nb)
    g_sgen_constr = nb
    g_sgen_constr_cap = nc

fn grow_egen_constr(needed: int):
    if needed < g_egen_constr_cap:
        return
    nc : ., mut = g_egen_constr_cap * 2
    if nc < 16:
        nc = 16
    if nc < needed:
        nc = needed + 16
    nb := alloc(nc * 8)
    cell_copy(g_egen_constr, g_egen_constr_cap * 8, nb)
    g_egen_constr = nb
    g_egen_constr_cap = nc

// Call-site binding table growth: i64 values appended in order, with no holes, unlike the sparse constraint tables.
fn grow_gen_binds(needed: int):
    if needed < g_gen_binds_cap:
        return
    nc : ., mut = g_gen_binds_cap * 2
    if nc < 64:
        nc = 64
    if nc < needed:
        nc = needed + 64
    nb := alloc(nc * 8)
    cell_copy(g_gen_binds, g_gen_binds_cap * 8, nb)
    g_gen_binds = nb
    g_gen_binds_cap = nc

// Constraint name of the gi-th generic parameter for a struct or enum, or -1 when
// absent or out of range. The read guard checks gi against MAX_GENERICS and the row
// index against the table count.
fn si_gen_constr(n: int, gi: int) -> int:
    if n < 0 || gi < 0 || gi >= MAX_GENERICS:
        return -1
    idx := n * MAX_GENERICS + gi
    if idx >= g_sgen_constr_count:
        return -1
    return cell_load(g_sgen_constr, idx * 8)

fn ei_gen_constr(n: int, gi: int) -> int:
    if n < 0 || gi < 0 || gi >= MAX_GENERICS:
        return -1
    idx := n * MAX_GENERICS + gi
    if idx >= g_egen_constr_count:
        return -1
    return cell_load(g_egen_constr, idx * 8)

fn grow_sg(n: int):
    if n < g_sg_cap:
        return
    nc := g_sg_cap
    if nc == 0:
        nc = 16
    loop:
        if nc > n:
            break
        nc = nc * 2
    nb := alloc(nc * ESZ_SG)
    if g_sg_cap > 0:
        cell_copy(g_sgs, g_sg_cap * ESZ_SG, nb)
    g_sgs = nb
    g_sg_cap = nc

fn grow_pts(n: int):
    if n < g_pts_cap:
        return
    nc := g_pts_cap
    if nc == 0:
        nc = 16
    loop:
        if nc > n:
            break
        nc = nc * 2
    nb := alloc(nc * 8)
    if g_pts_cap > 0:
        cell_copy(g_pts, g_pts_cap * 8, nb)
    g_pts = nb
    g_pts_cap = nc

fn grow_offsets(n: int):
    if n < g_offsets_cap:
        return
    nc := g_offsets_cap
    if nc == 0:
        nc = 16
    loop:
        if nc > n:
            break
        nc = nc * 2
    nb := alloc(nc * 8)
    if g_offsets_cap > 0:
        cell_copy(g_offsets, g_offsets_cap * 8, nb)
    g_offsets = nb
    g_offsets_cap = nc
