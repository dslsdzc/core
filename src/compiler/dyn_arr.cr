// === dyn_arr.cr ===
// Byte helpers + ESZ/OFF constants + grow functions + string pool.

// ============================================================
// Byte helpers
// ============================================================
fn w8(buf: string, pos: int, val: int) { __builtin_store8(buf, pos, val % 256); }
fn bu8(buf: string, pos: int) -> int { return __builtin_load8(buf, pos) % 256; }
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
    nb := __builtin_alloc(nc * ESZ_TOKEN); _dyncpy(g_tokens, g_tok_cap * ESZ_TOKEN, nb);
    g_tokens = nb; g_tok_cap = nc; }

fn dyn_grow_ast(needed: int) {
    if needed < g_ast_cap { return; }
    nc : ., mut = g_ast_cap * 2; if nc < 128 { nc = 128; } if nc < needed { nc = needed + 128; }
    nb := __builtin_alloc(nc * ESZ_ASTNODE); _dyncpy(g_ast, g_ast_cap * ESZ_ASTNODE, nb);
    g_ast = nb; g_ast_cap = nc; }

fn dyn_grow_syms(needed: int) {
    if needed < g_sym_cap { return; }
    nc : ., mut = g_sym_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := __builtin_alloc(nc * ESZ_SYMENTRY); _dyncpy(g_syms, g_sym_cap * ESZ_SYMENTRY, nb);
    g_syms = nb; g_sym_cap = nc; }

fn dyn_grow_types(needed: int) {
    if needed < g_type_cap { return; }
    nc : ., mut = g_type_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := __builtin_alloc(nc * 24); _dyncpy(g_types, g_type_cap * 24, nb);
    g_types = nb; g_type_cap = nc; }

fn dyn_grow_funcs(needed: int) {
    if needed < g_func_cap { return; }
    nc : ., mut = g_func_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := __builtin_alloc(nc * ESZ_FUNCINFO); _dyncpy(g_funcs, g_func_cap * ESZ_FUNCINFO, nb);
    g_funcs = nb; g_func_cap = nc; }

fn dyn_grow_structs(needed: int) {
    if needed < g_struct_cap { return; }
    nc : ., mut = g_struct_cap * 2; if nc < 32 { nc = 32; } if nc < needed { nc = needed + 32; }
    nb := __builtin_alloc(nc * ESZ_STRUCTINFO); _dyncpy(g_structs, g_struct_cap * ESZ_STRUCTINFO, nb);
    g_structs = nb; g_struct_cap = nc; }

fn dyn_grow_enums(needed: int) {
    if needed < g_enum_cap { return; }
    nc : ., mut = g_enum_cap * 2; if nc < 16 { nc = 16; } if nc < needed { nc = needed + 16; }
    nb := __builtin_alloc(nc * ESZ_ENUMINFO); _dyncpy(g_enums, g_enum_cap * ESZ_ENUMINFO, nb);
    g_enums = nb; g_enum_cap = nc; }

fn dyn_grow_ir_vars(needed: int) {
    if needed < g_ir_var_cap { return; }
    nc : ., mut = g_ir_var_cap * 2; if nc < 128 { nc = 128; } if nc < needed { nc = needed + 128; }
    nb := __builtin_alloc(nc * ESZ_IRVAR); _dyncpy(g_ir_vars, g_ir_var_cap * ESZ_IRVAR, nb);
    g_ir_vars = nb; g_ir_var_cap = nc; }

fn dyn_grow_ir_instrs(needed: int) {
    if needed < g_ir_instr_cap { return; }
    nc : ., mut = g_ir_instr_cap * 2; if nc < 128 { nc = 128; } if nc < needed { nc = needed + 128; }
    nb := __builtin_alloc(nc * ESZ_IRINSTR); _dyncpy(g_ir_instrs, g_ir_instr_cap * ESZ_IRINSTR, nb);
    g_ir_instrs = nb; g_ir_instr_cap = nc; }

fn dyn_grow_ir_locals(needed: int) {
    if needed < g_ir_local_cap { return; }
    nc : ., mut = g_ir_local_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := __builtin_alloc(nc * 16); _dyncpy(g_ir_locals, g_ir_local_cap * 16, nb);
    g_ir_locals = nb; g_ir_local_cap = nc; }

fn dyn_grow_ir_globals(needed: int) {
    if needed < g_ir_global_cap { return; }
    nc : ., mut = g_ir_global_cap * 2; if nc < 16 { nc = 16; } if nc < needed { nc = needed + 16; }
    nb := __builtin_alloc(nc * 16); _dyncpy(g_ir_globals, g_ir_global_cap * 16, nb);
    g_ir_globals = nb; g_ir_global_cap = nc; }

fn dyn_grow_ir_str_consts(needed: int) {
    if needed < g_ir_str_const_cap { return; }
    nc : ., mut = g_ir_str_const_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := __builtin_alloc(nc * 8); _dyncpy(g_ir_str_consts, g_ir_str_const_cap * 8, nb);
    g_ir_str_consts = nb; g_ir_str_const_cap = nc; }

fn dyn_grow_errors(needed: int) {
    if needed < g_err_cap { return; }
    nc : ., mut = g_err_cap * 2; if nc < 16 { nc = 16; } if nc < needed { nc = needed + 16; }
    nb := __builtin_alloc(nc * 8); _dyncpy(g_errors, g_err_cap * 8, nb);
    g_errors = nb; g_err_cap = nc; }

fn dyn_grow_block_stmts(needed: int) {
    if needed < g_block_stmt_cap { return; }
    nc : ., mut = g_block_stmt_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := __builtin_alloc(nc * 8); _dyncpy(g_block_stmts, g_block_stmt_cap * 8, nb);
    g_block_stmts = nb; g_block_stmt_cap = nc; }

fn dyn_grow_ir_func_meta(needed: int) {
    if needed < g_ir_func_name_idx_cap { return; }
    nc : ., mut = g_ir_func_name_idx_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    sz := nc * 8;
    n1 := __builtin_alloc(sz); _dyncpy(g_ir_func_name_idx, g_ir_func_name_idx_cap*8, n1); g_ir_func_name_idx = n1;
    n2 := __builtin_alloc(sz); _dyncpy(g_ir_func_ret_type, g_ir_func_ret_type_cap*8, n2); g_ir_func_ret_type = n2;
    n3 := __builtin_alloc(sz); _dyncpy(g_ir_func_instr_start, g_ir_func_instr_start_cap*8, n3); g_ir_func_instr_start = n3;
    n4 := __builtin_alloc(sz); _dyncpy(g_ir_func_instr_count, g_ir_func_instr_count_cap*8, n4); g_ir_func_instr_count = n4;
    n5 := __builtin_alloc(sz); _dyncpy(g_ir_func_var_start, g_ir_func_var_start_cap*8, n5); g_ir_func_var_start = n5;
    n6 := __builtin_alloc(sz); _dyncpy(g_ir_func_var_count, g_ir_func_var_count_cap*8, n6); g_ir_func_var_count = n6;
    n7 := __builtin_alloc(sz); _dyncpy(g_ir_func_param_count, g_ir_func_param_count_cap*8, n7); g_ir_func_param_count = n7;
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
// String pool helpers
// ============================================================
fn _grow_str_pool(needed: int) {
    if needed < g_str_pool_cap { return; }
    nc : ., mut = g_str_pool_cap * 2; if nc < 256 { nc = 256; } if nc < needed { nc = needed + 128; }
    nb := __builtin_alloc(nc); _dyncpy(g_str_pool, g_str_pool_cap, nb);
    g_str_pool = nb; g_str_pool_cap = nc;
    noc := g_str_offsets_cap * 2; if noc < 64 { noc = 64; }
    nob := __builtin_alloc(noc); _dyncpy(g_str_offsets, g_str_offsets_cap, nob);
    g_str_offsets = nob; g_str_offsets_cap = noc; }

fn str_intern(s: string) -> int {
    sl := __builtin_str_len(s);
    i : ., mut = 0; pos : ., mut = 0;
    loop {
        if i >= g_str_count { break; }
        pl : ., mut = 0;
        loop { bc := bu8(g_str_pool, pos + pl); if bc == 0 { break; } pl = pl + 1; }
        if pl == sl {
            eq : ., mut = 1; j : ., mut = 0;
            loop {
                if j >= sl { break; }
                if bu8(g_str_pool, pos + j) != __builtin_load8(s, j) { eq = 0; break; }
                j = j + 1; }
            if eq != 0 { return i; } }
        pos = pos + pl + 1;
        i = i + 1; }
    need := g_str_pool_len + sl + 1;
    _grow_str_pool(need);
    if g_str_count * 8 + 8 > g_str_offsets_cap {
        noc2 := g_str_offsets_cap * 2; if noc2 < 64 { noc2 = 64; }
        nob2 := __builtin_alloc(noc2); _dyncpy(g_str_offsets, g_str_offsets_cap, nob2);
        g_str_offsets = nob2; g_str_offsets_cap = noc2; }
    w64(g_str_offsets, g_str_count * 8, g_str_pool_len);
    j : ., mut = 0;
    loop { if j >= sl { break; } w8(g_str_pool, g_str_pool_len + j, __builtin_load8(s, j)); j = j + 1; }
    w8(g_str_pool, g_str_pool_len + sl, 0);
    g_str_pool_len = need;
    g_str_count = g_str_count + 1;
    return g_str_count - 1; }

fn str_get(idx: int) -> string {
    if idx < 0 || idx >= g_str_count { return ""; }
    off := r64(g_str_offsets, idx * 8);
    ln : ., mut = 0;
    loop { if bu8(g_str_pool, off + ln) == 0 { break; } ln = ln + 1; }
    return __builtin_str_sub(g_str_pool, off, ln); }

fn str_len(idx: int) -> int {
    if idx < 0 || idx >= g_str_count { return 0; }
    off := r64(g_str_offsets, idx * 8);
    ln : ., mut = 0;
    loop { if bu8(g_str_pool, off + ln) == 0 { break; } ln = ln + 1; }
    return ln; }

fn str_load8(idx: int, ci: int) -> int {
    if idx < 0 || idx >= g_str_count { return 0; }
    off := r64(g_str_offsets, idx * 8);
    return bu8(g_str_pool, off + ci); }

fn str_eq(idx: int, lit: string) -> int {
    if idx < 0 || idx >= g_str_count { return 0; }
    off := r64(g_str_offsets, idx * 8);
    sl := __builtin_str_len(lit);
    j : ., mut = 0;
    loop {
        pc := bu8(g_str_pool, off + j);
        if pc == 0 { if j == sl { return 1; } return 0; }
        if j >= sl { return 0; }
        if pc != __builtin_load8(lit, j) { return 0; }
        j = j + 1; }
    return 0; }
