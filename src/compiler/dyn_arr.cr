// === dyn_arr.cr ===
// Byte helpers + ESZ/OFF constants + grow functions + string pool.

// ============================================================
// Byte helpers
// ============================================================
fn w8(buf: string, pos: int, val: int) { store8(buf, pos, val % 256); }
fn bu8(buf: string, pos: int) -> int { return load8(buf, pos) % 256; }
fn w32(buf: string, pos: int, val: int) {
    uv : ., mut = val; if uv < 0 { uv = uv + 4294967296; }
    w8(buf,pos,uv%256); w8(buf,pos+1,(uv/256)%256);
    w8(buf,pos+2,(uv/65536)%256); w8(buf,pos+3,(uv/16777216)%256); }
fn r32(buf: string, pos: int) -> int {
    v := bu8(buf,pos)+bu8(buf,pos+1)*256+bu8(buf,pos+2)*65536+bu8(buf,pos+3)*16777216;
    if v >= 2147483648 { v = v - 4294967296; } return v; }
fn w64(buf: string, pos: int, val: int) {
    lo : ., mut = val % 4294967296; hi : ., mut = val / 4294967296;
    if val < 0 { lo = val; hi = -1; }
    w32(buf,pos,lo); w32(buf,pos+4,hi); }
fn r64(buf: string, pos: int) -> int {
    lo := r32(buf,pos); hi := r32(buf,pos+4);
    if hi < 0 { hi = hi + 4294967296; }
    return lo + hi * 4294967296; }

// ============================================================
// Element sizes (bytes per element)
// ============================================================
ESZ_TOKEN    : int = 40;     // kind,lexeme,int_val,line,col = 5×8
ESZ_ASTNODE  : int = 72;    // kind,a,b,c,int_val,type_val,data,line,col = 9×8
ESZ_SYMENTRY : int = 32;    // name_idx,kind,type_idx,node_idx = 4×8
ESZ_IRVAR    : int = 24;    // name_idx,id,type_kind = 3×8
ESZ_IRINSTR  : int = 48;    // opcode,dest,src1,src2,src3,type_kind = 6×8
ESZ_FUNCINFO : int = 200;
ESZ_STRUCTINFO : int = 440;
ESZ_ENUMINFO : int = 2360;  // name+variants[16]+variant_count+generic_names[4]+generic_count

// Token field offsets
OFF_TK_KIND : int = 0; OFF_TK_LEXEME : int = 8;
OFF_TK_INTVAL : int = 16; OFF_TK_LINE : int = 24; OFF_TK_COL : int = 32;

// ASTNode field offsets
OFF_AS_KIND : int = 0; OFF_AS_A : int = 8; OFF_AS_B : int = 16; OFF_AS_C : int = 24;
OFF_AS_INTVAL : int = 32; OFF_AS_TYPEVAL : int = 40;
OFF_AS_DATA : int = 48; OFF_AS_LINE : int = 56; OFF_AS_COL : int = 64;

// SymEntry field offsets
OFF_SY_NAME : int = 0; OFF_SY_KIND : int = 8;
OFF_SY_TYPE : int = 16; OFF_SY_NODE : int = 24;

// IRVar field offsets
OFF_IRV_NAME : int = 0; OFF_IRV_ID : int = 8; OFF_IRV_TYPE : int = 16;

// IRInstr field offsets
OFF_IRI_OP : int = 0; OFF_IRI_DEST : int = 8;
OFF_IRI_S1 : int = 16; OFF_IRI_S2 : int = 24;
OFF_IRI_S3 : int = 32; OFF_IRI_TK : int = 40;

// FuncInfo offsets
OFF_FI_NAME : int = 0; OFF_FI_PARAM_COUNT : int = 8;
OFF_FI_PARAM_TYPES : int = 16;
OFF_FI_RETURN_TYPE : int = 144; OFF_FI_AST_NODE : int = 152;
OFF_FI_GENERIC_NAMES : int = 160; OFF_FI_GENERIC_COUNT : int = 192;

// StructInfo offsets
OFF_SI_NAME : int = 0; OFF_SI_FIELD_NAMES : int = 8;
OFF_SI_FIELD_TYPES : int = 136; OFF_SI_FIELD_TYPE_NODES : int = 264;
OFF_SI_FIELD_COUNT : int = 392;
OFF_SI_GENERIC_NAMES : int = 400; OFF_SI_GENERIC_COUNT : int = 432;

// DFNode sizes and offsets
ESZ_DFNODE : int = 64;   // opcode,dest_var,src1,src2,src3,type_kind,first_edge,edge_count = 8x8
OFF_DF_OPCODE : int = 0;     OFF_DF_DEST : int = 8;
OFF_DF_S1 : int = 16;        OFF_DF_S2 : int = 24;
OFF_DF_S3 : int = 32;        OFF_DF_TK : int = 40;
OFF_DF_FIRST_EDGE : int = 48; OFF_DF_EDGE_COUNT : int = 56;

// DFEdge sizes and offsets
ESZ_DFEDGE : int = 24;   // from_node,to_node,next_out = 3x8
OFF_DFE_FROM : int = 0;  OFF_DFE_TO : int = 8;  OFF_DFE_NEXT : int = 16;

// InterfaceInfo: fixed-size entry per interface
// Header(24) + methods[16] * method_entry(88) = 1432 total
ESZ_IFACEINFO : int = 1432;
OFF_IF_NAME : int = 0; OFF_IF_METHOD_COUNT : int = 8; OFF_IF_GENERIC_COUNT : int = 16;
OFF_IF_METHODS : int = 24;  // first method entry
// Each method entry: name_idx(8) + param_count(8) + ret_ti(8) + param_types[8](64) = 88 bytes
ESZ_IFMETHOD : int = 88;
OFF_IFM_NAME : int = 0; OFF_IFM_PARAM_COUNT : int = 8; OFF_IFM_RET_TI : int = 16;
OFF_IFM_PARAM_TYPES : int = 24;  // first of up to 8 param types (each 8 bytes)
MAX_IFACE_METHOD_PARAMS : int = 8;

// EnumInfo offsets
OFF_EI_NAME : int = 0; OFF_EI_VARIANTS : int = 8;
OFF_EI_VARIANT_COUNT : int = 2312;
OFF_EI_GENERIC_NAMES : int = 2320; OFF_EI_GENERIC_COUNT : int = 2352;
// EnumVariant within variants[N]: name(8) + types[16](128) + type_count(8)
OFF_EV_NAME : int = 0; OFF_EV_TYPES : int = 8; OFF_EV_TYPE_COUNT : int = 136;
OFF_EV_SIZE : int = 144;

// ============================================================
// Copy helper
// ============================================================
fn _dyncpy(src: string, nbytes: int, dst: string) {
    ci : ., mut = 0;
    loop { if ci >= nbytes { break; } w8(dst, ci, bu8(src, ci)); ci = ci + 1; } }

// ============================================================
// Grow helpers for ALL arrays
// ============================================================
fn _grow(buf_name: string, cap_name: int, esz: int, min_init: int) {
    // Helper: cap_name is by value; we return new cap. Caller must assign.
    // Inline expansion needed per array since Core can't do generic.
}
// Each array gets its own grow function with doubling pattern.

fn dyn_grow_tokens(needed: int) {
    if needed < g_tok_cap { return; }
    nc : ., mut = g_tok_cap * 2; if nc < 128 { nc = 128; } if nc < needed { nc = needed + 128; }
    nb := alloc(nc * ESZ_TOKEN); _dyncpy(g_tokens, g_tok_cap * ESZ_TOKEN, nb);
    g_tokens = nb; g_tok_cap = nc; }

fn dyn_grow_ast(needed: int) {
    if needed < g_ast_cap { return; }
    nc : ., mut = g_ast_cap * 2; if nc < 128 { nc = 128; } if nc < needed { nc = needed + 128; }
    nb := alloc(nc * ESZ_ASTNODE); _dyncpy(g_ast, g_ast_cap * ESZ_ASTNODE, nb);
    g_ast = nb; g_ast_cap = nc; }

fn dyn_grow_syms(needed: int) {
    if needed < g_sym_cap { return; }
    nc : ., mut = g_sym_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * ESZ_SYMENTRY); _dyncpy(g_syms, g_sym_cap * ESZ_SYMENTRY, nb);
    g_syms = nb; g_sym_cap = nc; }

fn dyn_grow_types(needed: int) {
    if needed < g_type_cap { return; }
    nc : ., mut = g_type_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 24); _dyncpy(g_types, g_type_cap * 24, nb);
    g_types = nb; g_type_cap = nc; }

fn dyn_grow_funcs(needed: int) {
    if needed < g_func_cap { return; }
    nc : ., mut = g_func_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * ESZ_FUNCINFO); _dyncpy(g_funcs, g_func_cap * ESZ_FUNCINFO, nb);
    g_funcs = nb; g_func_cap = nc; }

fn dyn_grow_structs(needed: int) {
    if needed < g_struct_cap { return; }
    nc : ., mut = g_struct_cap * 2; if nc < 32 { nc = 32; } if nc < needed { nc = needed + 32; }
    nb := alloc(nc * ESZ_STRUCTINFO); _dyncpy(g_structs, g_struct_cap * ESZ_STRUCTINFO, nb);
    g_structs = nb; g_struct_cap = nc; }

fn dyn_grow_enums(needed: int) {
    if needed < g_enum_cap { return; }
    nc : ., mut = g_enum_cap * 2; if nc < 16 { nc = 16; } if nc < needed { nc = needed + 16; }
    nb := alloc(nc * ESZ_ENUMINFO); _dyncpy(g_enums, g_enum_cap * ESZ_ENUMINFO, nb);
    g_enums = nb; g_enum_cap = nc; }

fn dyn_grow_ifaces(needed: int) {
    if needed < g_iface_cap { return; }
    nc : ., mut = g_iface_cap * 2; if nc < 4 { nc = 4; } if nc < needed { nc = needed + 4; }
    nb := alloc(nc * ESZ_IFACEINFO); _dyncpy(g_ifaces, g_iface_cap * ESZ_IFACEINFO, nb);
    g_ifaces = nb; g_iface_cap = nc; }

fn dyn_grow_ir_vars(needed: int) {
    if needed < g_ir_var_cap { return; }
    nc : ., mut = g_ir_var_cap * 2; if nc < 128 { nc = 128; } if nc < needed { nc = needed + 128; }
    nb := alloc(nc * ESZ_IRVAR); _dyncpy(g_ir_vars, g_ir_var_cap * ESZ_IRVAR, nb);
    g_ir_vars = nb; g_ir_var_cap = nc; }

fn dyn_grow_ir_instrs(needed: int) {
    if needed < g_ir_instr_cap { return; }
    nc : ., mut = g_ir_instr_cap * 2; if nc < 128 { nc = 128; } if nc < needed { nc = needed + 128; }
    nb := alloc(nc * ESZ_IRINSTR); _dyncpy(g_ir_instrs, g_ir_instr_cap * ESZ_IRINSTR, nb);
    g_ir_instrs = nb; g_ir_instr_cap = nc; }

fn dyn_grow_ir_locals(needed: int) {
    if needed < g_ir_local_cap { return; }
    nc : ., mut = g_ir_local_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 16); _dyncpy(g_ir_locals, g_ir_local_cap * 16, nb);
    g_ir_locals = nb; g_ir_local_cap = nc; }

fn dyn_grow_ir_globals(needed: int) {
    if needed < g_ir_global_cap { return; }
    nc : ., mut = g_ir_global_cap * 2; if nc < 16 { nc = 16; } if nc < needed { nc = needed + 16; }
    nb := alloc(nc * 16); _dyncpy(g_ir_globals, g_ir_global_cap * 16, nb);
    g_ir_globals = nb; g_ir_global_cap = nc; }

fn dyn_grow_ir_str_consts(needed: int) {
    if needed < g_ir_str_const_cap { return; }
    nc : ., mut = g_ir_str_const_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 8); _dyncpy(g_ir_str_consts, g_ir_str_const_cap * 8, nb);
    g_ir_str_consts = nb; g_ir_str_const_cap = nc; }

fn dyn_grow_errors(needed: int) {
    if needed < g_err_cap { return; }
    nc : ., mut = g_err_cap * 2; if nc < 16 { nc = 16; } if nc < needed { nc = needed + 16; }
    nb := alloc(nc * 8); _dyncpy(g_errors, g_err_cap * 8, nb);
    g_errors = nb; g_err_cap = nc; }

fn dyn_grow_block_stmts(needed: int) {
    if needed < g_block_stmt_cap { return; }
    nc : ., mut = g_block_stmt_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 8); _dyncpy(g_block_stmts, g_block_stmt_cap * 8, nb);
    g_block_stmts = nb; g_block_stmt_cap = nc; }

fn dyn_grow_ir_func_meta(needed: int) { if needed < g_ir_func_name_idx_cap { return; }
    if needed < g_ir_func_name_idx_cap { return; }
    nc : ., mut = g_ir_func_name_idx_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    sz := nc * 8;
    n1 := alloc(sz); _dyncpy(g_ir_func_name_idx, g_ir_func_name_idx_cap*8, n1); g_ir_func_name_idx = n1; 
    n2 := alloc(sz); _dyncpy(g_ir_func_ret_type, g_ir_func_ret_type_cap*8, n2); g_ir_func_ret_type = n2;
    n3 := alloc(sz); _dyncpy(g_ir_func_instr_start, g_ir_func_instr_start_cap*8, n3); g_ir_func_instr_start = n3;
    n4 := alloc(sz); _dyncpy(g_ir_func_instr_count, g_ir_func_instr_count_cap*8, n4); g_ir_func_instr_count = n4;
    n5 := alloc(sz); _dyncpy(g_ir_func_var_start, g_ir_func_var_start_cap*8, n5); g_ir_func_var_start = n5;
    n6 := alloc(sz); _dyncpy(g_ir_func_var_count, g_ir_func_var_count_cap*8, n6); g_ir_func_var_count = n6;
    n7 := alloc(sz); _dyncpy(g_ir_func_param_count, g_ir_func_param_count_cap*8, n7); g_ir_func_param_count = n7;
    g_ir_func_name_idx_cap=nc; g_ir_func_ret_type_cap=nc; g_ir_func_instr_start_cap=nc;
    g_ir_func_instr_count_cap=nc; g_ir_func_var_start_cap=nc; g_ir_func_var_count_cap=nc; g_ir_func_param_count_cap=nc; }

// ============================================================
// Accessor helpers for AST node fields
// ============================================================
fn ast_kind(n: int) -> int { return r64(g_ast, n * ESZ_ASTNODE + OFF_AS_KIND); }
fn ast_a(n: int) -> int { return r64(g_ast, n * ESZ_ASTNODE + OFF_AS_A); }
fn ast_b(n: int) -> int { return r64(g_ast, n * ESZ_ASTNODE + OFF_AS_B); }
fn ast_c(n: int) -> int { return r64(g_ast, n * ESZ_ASTNODE + OFF_AS_C); }
fn ast_int_val(n: int) -> int { return r64(g_ast, n * ESZ_ASTNODE + OFF_AS_INTVAL); }
fn ast_type_val(n: int) -> int { return r64(g_ast, n * ESZ_ASTNODE + OFF_AS_TYPEVAL); }
fn ast_data(n: int) -> int { return r64(g_ast, n * ESZ_ASTNODE + OFF_AS_DATA); }
fn ast_line(n: int) -> int { return r64(g_ast, n * ESZ_ASTNODE + OFF_AS_LINE); }
fn ast_col(n: int) -> int { return r64(g_ast, n * ESZ_ASTNODE + OFF_AS_COL); }

fn ast_set_kind(n: int, v: int) { w64(g_ast, n * ESZ_ASTNODE + OFF_AS_KIND, v); }
fn ast_set_a(n: int, v: int) { w64(g_ast, n * ESZ_ASTNODE + OFF_AS_A, v); }
fn ast_set_b(n: int, v: int) { w64(g_ast, n * ESZ_ASTNODE + OFF_AS_B, v); }
fn ast_set_c(n: int, v: int) { w64(g_ast, n * ESZ_ASTNODE + OFF_AS_C, v); }
fn ast_set_int_val(n: int, v: int) { w64(g_ast, n * ESZ_ASTNODE + OFF_AS_INTVAL, v); }
fn ast_set_type_val(n: int, v: int) { w64(g_ast, n * ESZ_ASTNODE + OFF_AS_TYPEVAL, v); }
fn ast_set_data(n: int, v: int) { w64(g_ast, n * ESZ_ASTNODE + OFF_AS_DATA, v); }
fn ast_set_line(n: int, v: int) { w64(g_ast, n * ESZ_ASTNODE + OFF_AS_LINE, v); }
fn ast_set_col(n: int, v: int) { w64(g_ast, n * ESZ_ASTNODE + OFF_AS_COL, v); }

fn ast_alloc(kind: int, a: int, b: int, c: int, iv: int, tv: int, d: int, line: int, col: int) -> int {
    idx := g_ast_count;
    dyn_grow_ast(idx + 1);
    w64(g_ast, idx * ESZ_ASTNODE + OFF_AS_KIND, kind);
    w64(g_ast, idx * ESZ_ASTNODE + OFF_AS_A, a);
    w64(g_ast, idx * ESZ_ASTNODE + OFF_AS_B, b);
    w64(g_ast, idx * ESZ_ASTNODE + OFF_AS_C, c);
    w64(g_ast, idx * ESZ_ASTNODE + OFF_AS_INTVAL, iv);
    w64(g_ast, idx * ESZ_ASTNODE + OFF_AS_TYPEVAL, tv);
    w64(g_ast, idx * ESZ_ASTNODE + OFF_AS_DATA, d);
    w64(g_ast, idx * ESZ_ASTNODE + OFF_AS_LINE, line);
    w64(g_ast, idx * ESZ_ASTNODE + OFF_AS_COL, col);
    g_ast_count = idx + 1;
    return idx; }

// Accessor helpers for SymEntry
fn sym_name(n: int) -> int { return r64(g_syms, n * ESZ_SYMENTRY + OFF_SY_NAME); }
fn sym_kind(n: int) -> int { return r64(g_syms, n * ESZ_SYMENTRY + OFF_SY_KIND); }
fn sym_type(n: int) -> int { return r64(g_syms, n * ESZ_SYMENTRY + OFF_SY_TYPE); }
fn sym_node(n: int) -> int { return r64(g_syms, n * ESZ_SYMENTRY + OFF_SY_NODE); }
fn sym_set_name(n: int, v: int) { w64(g_syms, n * ESZ_SYMENTRY + OFF_SY_NAME, v); }
fn sym_set_kind(n: int, v: int) { w64(g_syms, n * ESZ_SYMENTRY + OFF_SY_KIND, v); }
fn sym_set_type(n: int, v: int) { w64(g_syms, n * ESZ_SYMENTRY + OFF_SY_TYPE, v); }
fn sym_set_node(n: int, v: int) { w64(g_syms, n * ESZ_SYMENTRY + OFF_SY_NODE, v); }

// IRVar helpers
fn irv_name(n: int) -> int { return r64(g_ir_vars, n * ESZ_IRVAR + OFF_IRV_NAME); }
fn irv_id(n: int) -> int { return r64(g_ir_vars, n * ESZ_IRVAR + OFF_IRV_ID); }
fn irv_type(n: int) -> int { return r64(g_ir_vars, n * ESZ_IRVAR + OFF_IRV_TYPE); }
fn irv_set_name(n: int, v: int) { w64(g_ir_vars, n * ESZ_IRVAR + OFF_IRV_NAME, v); }
fn irv_set_id(n: int, v: int) { w64(g_ir_vars, n * ESZ_IRVAR + OFF_IRV_ID, v); }
fn irv_set_type(n: int, v: int) { w64(g_ir_vars, n * ESZ_IRVAR + OFF_IRV_TYPE, v); }

// IRInstr helpers
fn iri_op(n: int) -> int { return r64(g_ir_instrs, n * ESZ_IRINSTR + OFF_IRI_OP); }
fn iri_dest(n: int) -> int { return r64(g_ir_instrs, n * ESZ_IRINSTR + OFF_IRI_DEST); }
fn iri_s1(n: int) -> int { return r64(g_ir_instrs, n * ESZ_IRINSTR + OFF_IRI_S1); }
fn iri_s2(n: int) -> int { return r64(g_ir_instrs, n * ESZ_IRINSTR + OFF_IRI_S2); }
fn iri_s3(n: int) -> int { return r64(g_ir_instrs, n * ESZ_IRINSTR + OFF_IRI_S3); }
fn iri_tk(n: int) -> int { return r64(g_ir_instrs, n * ESZ_IRINSTR + OFF_IRI_TK); }
fn iri_set_op(n: int, v: int) { w64(g_ir_instrs, n * ESZ_IRINSTR + OFF_IRI_OP, v); }
fn iri_set_dest(n: int, v: int) { w64(g_ir_instrs, n * ESZ_IRINSTR + OFF_IRI_DEST, v); }
fn iri_set_s1(n: int, v: int) { w64(g_ir_instrs, n * ESZ_IRINSTR + OFF_IRI_S1, v); }
fn iri_set_s2(n: int, v: int) { w64(g_ir_instrs, n * ESZ_IRINSTR + OFF_IRI_S2, v); }
fn iri_set_s3(n: int, v: int) { w64(g_ir_instrs, n * ESZ_IRINSTR + OFF_IRI_S3, v); }
fn iri_set_tk(n: int, v: int) { w64(g_ir_instrs, n * ESZ_IRINSTR + OFF_IRI_TK, v); }

// FuncInfo helpers
fn fi_name(n: int) -> int { return r64(g_funcs, n * ESZ_FUNCINFO + OFF_FI_NAME); }
fn fi_param_count(n: int) -> int { return r64(g_funcs, n * ESZ_FUNCINFO + OFF_FI_PARAM_COUNT); }
fn fi_return_type(n: int) -> int { return r64(g_funcs, n * ESZ_FUNCINFO + OFF_FI_RETURN_TYPE); }
fn fi_ast_node(n: int) -> int { return r64(g_funcs, n * ESZ_FUNCINFO + OFF_FI_AST_NODE); }
fn fi_generic_count(n: int) -> int { return r64(g_funcs, n * ESZ_FUNCINFO + OFF_FI_GENERIC_COUNT); }
fn fi_param_type(n: int, pi: int) -> int { return r64(g_funcs, n * ESZ_FUNCINFO + OFF_FI_PARAM_TYPES + pi * 8); }
fn fi_generic_name(n: int, gi: int) -> int { return r64(g_funcs, n * ESZ_FUNCINFO + OFF_FI_GENERIC_NAMES + gi * 8); }
fn fi_set_name(n: int, v: int) { w64(g_funcs, n * ESZ_FUNCINFO + OFF_FI_NAME, v); }
fn fi_set_param_count(n: int, v: int) { w64(g_funcs, n * ESZ_FUNCINFO + OFF_FI_PARAM_COUNT, v); }
fn fi_set_param_type(n: int, pi: int, v: int) { w64(g_funcs, n * ESZ_FUNCINFO + OFF_FI_PARAM_TYPES + pi*8, v); }
fn fi_set_return_type(n: int, v: int) { w64(g_funcs, n * ESZ_FUNCINFO + OFF_FI_RETURN_TYPE, v); }
fn fi_set_ast_node(n: int, v: int) { w64(g_funcs, n * ESZ_FUNCINFO + OFF_FI_AST_NODE, v); }
fn fi_set_generic_name(n: int, gi: int, v: int) { w64(g_funcs, n * ESZ_FUNCINFO + OFF_FI_GENERIC_NAMES + gi*8, v); }
fn fi_set_generic_count(n: int, v: int) { w64(g_funcs, n * ESZ_FUNCINFO + OFF_FI_GENERIC_COUNT, v); }

// StructInfo helpers
fn si_name(n: int) -> int { return r64(g_structs, n * ESZ_STRUCTINFO + OFF_SI_NAME); }
fn si_field_count(n: int) -> int { return r64(g_structs, n * ESZ_STRUCTINFO + OFF_SI_FIELD_COUNT); }
fn si_generic_count(n: int) -> int { return r64(g_structs, n * ESZ_STRUCTINFO + OFF_SI_GENERIC_COUNT); }
fn si_field_name(n: int, fi: int) -> int { return r64(g_structs, n*ESZ_STRUCTINFO + OFF_SI_FIELD_NAMES + fi*8); }
fn si_field_type(n: int, fi: int) -> int { return r64(g_structs, n*ESZ_STRUCTINFO + OFF_SI_FIELD_TYPES + fi*8); }
fn si_field_type_node(n: int, fi: int) -> int { return r64(g_structs, n*ESZ_STRUCTINFO + OFF_SI_FIELD_TYPE_NODES + fi*8); }
fn si_generic_name(n: int, gi: int) -> int { return r64(g_structs, n*ESZ_STRUCTINFO + OFF_SI_GENERIC_NAMES + gi*8); }

// EnumInfo helpers
fn ei_name(n: int) -> int { return r64(g_enums, n * ESZ_ENUMINFO + OFF_EI_NAME); }
fn ei_variant_count(n: int) -> int { return r64(g_enums, n * ESZ_ENUMINFO + OFF_EI_VARIANT_COUNT); }
fn ei_generic_count(n: int) -> int { return r64(g_enums, n * ESZ_ENUMINFO + OFF_EI_GENERIC_COUNT); }
fn ei_variant_name(n: int, vi: int) -> int { return r64(g_enums, n*ESZ_ENUMINFO + OFF_EI_VARIANTS + vi*OFF_EV_SIZE + OFF_EV_NAME); }
fn ei_variant_type(n: int, vi: int, ti: int) -> int { return r64(g_enums, n*ESZ_ENUMINFO + OFF_EI_VARIANTS + vi*OFF_EV_SIZE + OFF_EV_TYPES + ti*8); }
fn ei_variant_type_count(n: int, vi: int) -> int { return r64(g_enums, n*ESZ_ENUMINFO + OFF_EI_VARIANTS + vi*OFF_EV_SIZE + OFF_EV_TYPE_COUNT); }

// ============================================================
// String table helpers (dynamic byte buffer)
// ============================================================
fn dyn_grow_g_strs(needed: int) {
    if needed < g_str_cap { return; }
    nc : ., mut = g_str_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 8); _dyncpy(g_strs, g_str_cap * 8, nb);
    g_strs = nb; g_str_cap = nc; }

fn str_intern(s: string) -> int {
    i : ., mut = 0;
    loop {
        if i >= g_str_count { break; }
        if str_eq(load_str_ptr(g_strs, i * 8), s) != 0 { return i; }
        i = i + 1; }
    dyn_grow_g_strs(g_str_count + 1);
    store_str_ptr(g_strs, g_str_count * 8, s);
    g_str_count = g_str_count + 1;
    return g_str_count - 1; }

fn istr_get(idx: int) -> string {
    if idx < 0 || idx >= g_str_count { return ""; }
    return load_str_ptr(g_strs, idx * 8); }

fn istr_len(idx: int) -> int {
    if idx < 0 || idx >= g_str_count { return 0; }
    return str_len(istr_get(idx)); }

fn str_load8(idx: int, ci: int) -> int {
    if idx < 0 || idx >= g_str_count { return 0; }
    return load8(istr_get(idx), ci); }

fn dyn_grow_line_fileid(needed: int) {
    if needed < g_line_cap { return; }
    nc : ., mut = g_line_cap * 2; if nc < 128 { nc = 128; } if nc < needed { nc = needed + 128; }
    nb := alloc(nc * 8); _dyncpy(g_line_fileid, g_line_cap * 8, nb);
    g_line_fileid = nb; g_line_cap = nc; }
fn dyn_grow_segs(needed: int) {
    if needed < g_seg_cap { return; }
    nc : ., mut = g_seg_cap * 2; if nc < 16 { nc = 16; } if nc < needed { nc = needed + 16; }
    sz := nc * 8;
    n1 := alloc(sz); _dyncpy(g_seg_starts, g_seg_cap * 8, n1); g_seg_starts = n1;
    n2 := alloc(sz); _dyncpy(g_seg_fileids, g_seg_cap * 8, n2); g_seg_fileids = n2;
    g_seg_cap = nc; }
fn dyn_grow_gen_apply_data(needed: int) {
    if needed < g_gen_apply_data_cap { return; }
    nc : ., mut = g_gen_apply_data_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 8); _dyncpy(g_gen_apply_data, g_gen_apply_data_cap * 8, nb);
    g_gen_apply_data = nb; g_gen_apply_data_cap = nc; }
fn dyn_grow_df_nodes(needed: int) {
    if needed < g_df_node_cap { return; }
    nc : ., mut = g_df_node_cap * 2; if nc < 128 { nc = 128; } if nc < needed { nc = needed + 128; }
    nb := alloc(nc * ESZ_DFNODE); _dyncpy(g_df_nodes, g_df_node_cap * ESZ_DFNODE, nb);
    g_df_nodes = nb; g_df_node_cap = nc; }
fn dyn_grow_df_edges(needed: int) {
    if needed < g_df_edge_cap { return; }
    nc : ., mut = g_df_edge_cap * 2; if nc < 128 { nc = 128; } if nc < needed { nc = needed + 128; }
    nb := alloc(nc * ESZ_DFEDGE); _dyncpy(g_df_edges, g_df_edge_cap * ESZ_DFEDGE, nb);
    g_df_edges = nb; g_df_edge_cap = nc; }
fn dyn_grow_df_arrays(needed: int) {
    if needed < g_df_cap { return; }
    nc : ., mut = g_df_cap * 2; if nc < 128 { nc = 128; } if nc < needed { nc = needed + 128; }
    sz := nc * 8;
    n1 := alloc(sz); _dyncpy(g_df_var_producer, g_df_cap * 8, n1); g_df_var_producer = n1;
    n2 := alloc(sz); _dyncpy(g_df_func_node_start, g_df_cap * 8, n2); g_df_func_node_start = n2;
    n3 := alloc(sz); _dyncpy(g_df_func_node_count, g_df_cap * 8, n3); g_df_func_node_count = n3;
    g_df_cap = nc; }

fn dyn_grow_gen_map(needed: int) {
    if needed < g_gen_map_cap { return; }
    nc : ., mut = g_gen_map_cap * 2; if nc < 8 { nc = 8; } if nc < needed { nc = needed + 8; }
    sz := nc * 8;
    n1 := alloc(sz); _dyncpy(g_gen_map_names, g_gen_map_cap*8, n1); g_gen_map_names = n1;
    n2 := alloc(sz); _dyncpy(g_gen_map_types, g_gen_map_cap*8, n2); g_gen_map_types = n2;
    g_gen_map_cap = nc; }
fn dyn_grow_borrow_vars(needed: int) {
    if needed < g_borrow_cap { return; }
    nc : ., mut = g_borrow_cap * 2; if nc < 16 { nc = 16; } if nc < needed { nc = needed + 16; }
    sz := nc * 8;
    n1 := alloc(sz); _dyncpy(g_borrow_vars, g_borrow_cap*8, n1); g_borrow_vars = n1;
    n2 := alloc(sz); _dyncpy(g_borrow_refs, g_borrow_cap*8, n2); g_borrow_refs = n2;
    n3 := alloc(sz); _dyncpy(g_borrow_muts, g_borrow_cap*8, n3); g_borrow_muts = n3;
    g_borrow_cap = nc; }
fn dyn_grow_holder(needed: int) {
    if needed < g_holder_cap { return; }
    nc : ., mut = g_holder_cap * 2; if nc < 16 { nc = 16; } if nc < needed { nc = needed + 16; }
    sz := nc * 8;
    n1 := alloc(sz); _dyncpy(g_holder_borrowers, g_holder_cap*8, n1); g_holder_borrowers = n1;
    n2 := alloc(sz); _dyncpy(g_holder_borrowed, g_holder_cap*8, n2); g_holder_borrowed = n2;
    n3 := alloc(sz); _dyncpy(g_holder_is_mut, g_holder_cap*8, n3); g_holder_is_mut = n3;
    g_holder_cap = nc; }

fn dyn_grow_global_lets(needed: int) {
    if needed < g_global_lets_cap { return; }
    nc : ., mut = g_global_lets_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 8); _dyncpy(g_global_lets, g_global_lets_cap * 8, nb);
    g_global_lets = nb; g_global_lets_cap = nc; }
fn dyn_grow_loop_stack(needed: int) {
    if needed < g_loop_stack_cap { return; }
    nc : ., mut = g_loop_stack_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 24); _dyncpy(g_loop_stack, g_loop_stack_cap * 24, nb);
    g_loop_stack = nb; g_loop_stack_cap = nc; }
fn dyn_grow_type_aliases(needed: int) {
    if needed < g_type_alias_cap { return; }
    nc : ., mut = g_type_alias_cap * 2; if nc < 32 { nc = 32; } if nc < needed { nc = needed + 32; }
    nb := alloc(nc * 16); _dyncpy(g_type_aliases, g_type_alias_cap * 16, nb);
    g_type_aliases = nb; g_type_alias_cap = nc; }
fn dyn_grow_scope_bounds(needed: int) {
    if needed < g_scope_bounds_cap { return; }
    nc : ., mut = g_scope_bounds_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 8); _dyncpy(g_scope_bounds, g_scope_bounds_cap * 8, nb);
    g_scope_bounds = nb; g_scope_bounds_cap = nc; }
fn dyn_grow_methods(needed: int) {
    if needed < g_method_cap { return; }
    nc : ., mut = g_method_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 24); _dyncpy(g_methods, g_method_cap * 24, nb);
    g_methods = nb; g_method_cap = nc; }
fn dyn_grow_borrow_scope_markers(needed: int) {
    if needed < g_borrow_scope_markers_cap { return; }
    nc : ., mut = g_borrow_scope_markers_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 8); _dyncpy(g_borrow_scope_markers, g_borrow_scope_markers_cap * 8, nb);
    g_borrow_scope_markers = nb; g_borrow_scope_markers_cap = nc; }

fn istr_eq(idx: int, lit: string) -> int {
    if idx < 0 || idx >= g_str_count { return 0; }
    if str_eq(istr_get(idx), lit) != 0 { return 1; }
    return 0; }

// ============================================================
// Grow functions for x86 backend arrays
// ============================================================

fn dyn_grow_x86_vars(needed: int) {
    if needed < g_x86_var_cap { return; }
    nc : ., mut = g_x86_var_cap * 2; if nc < 128 { nc = 128; } if nc < needed { nc = needed + 128; }
    nb := alloc(nc * 8); _dyncpy(g_x86_vars, g_x86_var_cap * 8, nb);
    g_x86_vars = nb; g_x86_var_cap = nc; }

fn dyn_grow_x86_is_enum(needed: int) {
    if needed < g_x86_is_enum_cap { return; }
    nc : ., mut = g_x86_is_enum_cap * 2; if nc < 128 { nc = 128; } if nc < needed { nc = needed + 128; }
    nb := alloc(nc * 8); _dyncpy(g_x86_is_enum, g_x86_is_enum_cap * 8, nb);
    g_x86_is_enum = nb; g_x86_is_enum_cap = nc; }

fn dyn_grow_x86_is_global(needed: int) {
    if needed < g_x86_global_cap { return; }
    nc : ., mut = g_x86_global_cap * 2; if nc < 128 { nc = 128; } if nc < needed { nc = needed + 128; }
    nb := alloc(nc * 8); _dyncpy(g_x86_is_global, g_x86_global_cap * 8, nb);
    g_x86_is_global = nb; g_x86_global_cap = nc; }

fn dyn_grow_x86_global_off(needed: int) {
    if needed < g_x86_global_off_cap { return; }
    nc : ., mut = g_x86_global_off_cap * 2; if nc < 128 { nc = 128; } if nc < needed { nc = needed + 128; }
    nb := alloc(nc * 8); _dyncpy(g_x86_global_off, g_x86_global_off_cap * 8, nb);
    g_x86_global_off = nb; g_x86_global_off_cap = nc; }

fn dyn_grow_x86_str_offs(needed: int) {
    if needed < g_x86_str_cap { return; }
    nc : ., mut = g_x86_str_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 8); _dyncpy(g_x86_str_offs, g_x86_str_cap * 8, nb);
    g_x86_str_offs = nb; g_x86_str_cap = nc; }

fn dyn_grow_x86_rip_patch(needed: int) {
    if needed < g_x86_rip_patch_cap { return; }
    nc : ., mut = g_x86_rip_patch_cap * 2; if nc < 128 { nc = 128; } if nc < needed { nc = needed + 128; }
    nb1 := alloc(nc * 8); _dyncpy(g_x86_rip_patch_pos, g_x86_rip_patch_cap * 8, nb1); g_x86_rip_patch_pos = nb1;
    nb2 := alloc(nc * 8); _dyncpy(g_x86_rip_patch_globals, g_x86_rip_patch_cap * 8, nb2); g_x86_rip_patch_globals = nb2;
    g_x86_rip_patch_cap = nc; }

fn dyn_grow_x86_ext_rel(needed: int) {
    if needed < g_x86_ext_rel_cap { return; }
    nc : ., mut = g_x86_ext_rel_cap * 2; if nc < 32 { nc = 32; } if nc < needed { nc = needed + 32; }
    sz := nc * 8;
    n1 := alloc(sz); _dyncpy(g_x86_ext_rel_pos, g_x86_ext_rel_cap*8, n1); g_x86_ext_rel_pos = n1;
    n2 := alloc(sz); _dyncpy(g_x86_ext_rel_name, g_x86_ext_rel_cap*8, n2); g_x86_ext_rel_name = n2;
    g_x86_ext_rel_cap = nc; }

fn dyn_grow_x86_func_offsets(needed: int) {
    if needed < g_x86_func_offsets_cap { return; }
    nc : ., mut = g_x86_func_offsets_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 8); _dyncpy(g_x86_func_offsets, g_x86_func_offsets_cap * 8, nb);
    g_x86_func_offsets = nb; g_x86_func_offsets_cap = nc; }

fn dyn_grow_x86_emit_vars(needed: int) {
    if needed < g_x86_emit_vars_cap { return; }
    nc : ., mut = g_x86_emit_vars_cap * 2; if nc < 128 { nc = 128; } if nc < needed { nc = needed + 128; }
    nb := alloc(nc * 8); _dyncpy(g_x86_emit_vars, g_x86_emit_vars_cap * 8, nb);
    g_x86_emit_vars = nb; g_x86_emit_vars_cap = nc; }

fn dyn_grow_x86_ret_patch(needed: int) {
    if needed < g_x86_ret_patch_cap { return; }
    nc : ., mut = g_x86_ret_patch_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 8); _dyncpy(g_x86_ret_patch_pos, g_x86_ret_patch_cap * 8, nb);
    g_x86_ret_patch_pos = nb; g_x86_ret_patch_cap = nc; }
fn dyn_grow_x86_call_patch(needed: int) {
    if needed < g_x86_call_patch_cap { return; }
    nc : ., mut = g_x86_call_patch_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    n1 := alloc(nc * 8); _dyncpy(g_x86_call_patch_pos, g_x86_call_patch_cap * 8, n1); g_x86_call_patch_pos = n1;
    n2 := alloc(nc * 8); _dyncpy(g_x86_call_patch_name, g_x86_call_patch_cap * 8, n2); g_x86_call_patch_name = n2;
    g_x86_call_patch_cap = nc; }

fn dyn_grow_x86_func_cp(needed: int) {
    if needed < g_x86_func_cp_cap { return; }
    nc : ., mut = g_x86_func_cp_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 8); _dyncpy(g_x86_func_cp, g_x86_func_cp_cap * 8, nb);
    g_x86_func_cp = nb; g_x86_func_cp_cap = nc; }

fn dyn_grow_x86_rodataref(needed: int) {
    if needed < g_x86_rodataref_cap { return; }
    nc : ., mut = g_x86_rodataref_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    n1 := alloc(nc * 8); _dyncpy(g_x86_rodataref_pos, g_x86_rodataref_cap * 8, n1); g_x86_rodataref_pos = n1;
    n2 := alloc(nc * 8); _dyncpy(g_x86_rodataref_ro, g_x86_rodataref_cap * 8, n2); g_x86_rodataref_ro = n2;
    g_x86_rodataref_cap = nc; }

fn dyn_grow_x86_alloc_patch(needed: int) {
    if needed < g_x86_alloc_patch_cap { return; }
    nc : ., mut = g_x86_alloc_patch_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 8); _dyncpy(g_x86_alloc_patch_pos, g_x86_alloc_patch_cap * 8, nb);
    g_x86_alloc_patch_pos = nb; g_x86_alloc_patch_cap = nc; }

fn dyn_grow_ir_local_scopes(needed: int) {
    if needed < g_ir_local_scopes_cap { return; }
    nc : ., mut = g_ir_local_scopes_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 8); _dyncpy(g_ir_local_scopes, g_ir_local_scopes_cap * 8, nb);
    g_ir_local_scopes = nb; g_ir_local_scopes_cap = nc; }

fn dyn_grow_ir_loop_stacks(needed: int) {
    if needed < g_ir_loop_stacks_cap { return; }
    nc : ., mut = g_ir_loop_stacks_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    n1 := alloc(nc * 8); _dyncpy(g_ir_loop_header, g_ir_loop_stacks_cap * 8, n1); g_ir_loop_header = n1;
    n2 := alloc(nc * 8); _dyncpy(g_ir_loop_exit, g_ir_loop_stacks_cap * 8, n2); g_ir_loop_exit = n2;
    g_ir_loop_stacks_cap = nc; }

fn dyn_grow_label_poses(needed: int) {
    if needed < g_label_cap { return; }
    nc : ., mut = g_label_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 8); _dyncpy(g_label_poses, g_label_cap * 8, nb);
    g_label_poses = nb; g_label_cap = nc; }

// ============================================================
// Grow functions for newly-converted arrays
// ============================================================

// Diag struct: code(8) + msg(8) + line(8) + col(8) = 32 bytes
fn dyn_grow_diags(needed: int) {
    if needed < g_diag_cap { return; }
    nc : ., mut = g_diag_cap * 2; if nc < 16 { nc = 16; } if nc < needed { nc = needed + 16; }
    nb := alloc(nc * 32); _dyncpy(g_diags, g_diag_cap * 32, nb);
    g_diags = nb; g_diag_cap = nc; }

// FileEntry: fileid_ni(8) + path(8) = 16 bytes
fn dyn_grow_files(needed: int) {
    if needed < g_file_cap { return; }
    nc : ., mut = g_file_cap * 2; if nc < 16 { nc = 16; } if nc < needed { nc = needed + 16; }
    nb := alloc(nc * 16); _dyncpy(g_files, g_file_cap * 16, nb);
    g_files = nb; g_file_cap = nc; }

// ModEntry: alias_ni(8) + fileid_ni(8) + path(8) = 24 bytes
fn dyn_grow_mods(needed: int) {
    if needed < g_mod_cap { return; }
    nc : ., mut = g_mod_cap * 2; if nc < 16 { nc = 16; } if nc < needed { nc = needed + 16; }
    nb := alloc(nc * 24); _dyncpy(g_mods, g_mod_cap * 24, nb);
    g_mods = nb; g_mod_cap = nc; }

// g_mod_func_fileids/names/tis: 3 parallel int arrays, 8 bytes per element each
fn dyn_grow_mod_funcs(needed: int) {
    if needed < g_mod_func_cap { return; }
    nc : ., mut = g_mod_func_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    sz := nc * 8;
    n1 := alloc(sz); _dyncpy(g_mod_func_fileids, g_mod_func_cap * 8, n1); g_mod_func_fileids = n1;
    n2 := alloc(sz); _dyncpy(g_mod_func_names, g_mod_func_cap * 8, n2); g_mod_func_names = n2;
    n3 := alloc(sz); _dyncpy(g_mod_func_tis, g_mod_func_cap * 8, n3); g_mod_func_tis = n3;
    g_mod_func_cap = nc; }

// g_mod_path_names: int array, 8 bytes per element
fn dyn_grow_mod_paths(needed: int) {
    if needed < g_mod_path_cap { return; }
    nc : ., mut = g_mod_path_cap * 2; if nc < 32 { nc = 32; } if nc < needed { nc = needed + 32; }
    nb := alloc(nc * 8); _dyncpy(g_mod_path_names, g_mod_path_cap * 8, nb);
    g_mod_path_names = nb; g_mod_path_cap = nc; }

// impl-for: pairs of (interface_ni, type_ni), 16 bytes per pair
fn dyn_grow_impl_for(needed: int) {
    if needed < g_impl_for_cap { return; }
    nc : ., mut = g_impl_for_cap * 2; if nc < 8 { nc = 8; } if nc < needed { nc = needed + 8; }
    nb := alloc(nc * 16); _dyncpy(g_impl_for, g_impl_for_cap * 16, nb);
    g_impl_for = nb; g_impl_for_cap = nc; }

// Generic constraints: for each (func_idx * MAX_GENERICS + param_idx), stores iface_ni or -1
fn dyn_grow_generic_constr(needed: int) {
    if needed < g_generic_constr_cap { return; }
    nc : ., mut = g_generic_constr_cap * 2; if nc < 16 { nc = 16; } if nc < needed { nc = needed + 16; }
    nb := alloc(nc * 8); _dyncpy(g_generic_constr, g_generic_constr_cap * 8, nb);
    g_generic_constr = nb; g_generic_constr_cap = nc; }
