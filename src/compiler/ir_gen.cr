// === ir_gen.core ===
// Flat AST to platform-independent IR instruction generation
// (shared IR globals declared in globals.cr)

// (IR globals declared in globals.cr)

// Subgraph-level arena tracking for compile-time size estimation
g_sg_alloc_total : string, mut;    // per-sg: cumulative alloc size
g_sg_alloc_cap   : int, mut;
g_sg_arena_var   : string, mut;    // per-sg: IR var for arena ID
g_sg_arena_var_cap : int, mut;
g_ir_source_hash : int, mut;
g_ir_source_hash_ready : int, mut;

// 切片编译期长度侧表（var → 字面量长度；-1 = 未知/无记录）。
// IR_SLICE 的字面量界（high−low）在此登记，供解引用处的越界检查
// （pass_before_array_access 的 arr_len_lit）使用——见 F11。
g_ir_slice_lens : string, mut;     // [var, len] pairs
g_ir_slice_len_count : int, mut;
g_ir_slice_len_cap : int, mut;

fn grow_ir_slice_lens(needed: int) {
    if needed < g_ir_slice_len_cap { return; }
    nc := g_ir_slice_len_cap * 2; if nc < 8 { nc = 8; } if nc < needed { nc = needed + 8; }
    nb := alloc(nc * 16); _dyncpy(g_ir_slice_lens, g_ir_slice_len_cap * 16, nb);
    g_ir_slice_lens = nb; g_ir_slice_len_cap = nc;
}

fn slice_len_get(var_idx: int) -> int {
    si : ., mut = 0;
    loop { if si >= g_ir_slice_len_count { break; }
        if r64(g_ir_slice_lens, si * 16) == var_idx { return r64(g_ir_slice_lens, si * 16 + 8); }
        si = si + 1; }
    return -1;
}

fn slice_len_set(var_idx: int, len: int) {
    si : ., mut = 0;
    loop { if si >= g_ir_slice_len_count { break; }
        if r64(g_ir_slice_lens, si * 16) == var_idx {
            w64(g_ir_slice_lens, si * 16 + 8, len);
            return;
        }
        si = si + 1; }
    if len < 0 { return; }
    grow_ir_slice_lens(g_ir_slice_len_count + 1);
    w64(g_ir_slice_lens, g_ir_slice_len_count * 16, var_idx);
    w64(g_ir_slice_lens, g_ir_slice_len_count * 16 + 8, len);
    g_ir_slice_len_count = g_ir_slice_len_count + 1;
}

// F11（运行时界切片，2026-09-05 扩展）：len 字段编码——
// >= 0 = 字面量长度；<= -2 = 长度 IR 变量（-2-len_var，避开 -1 清除码）；-1 = 已清除/无记录。
fn slice_len_raw_set(var_idx: int, len_code: int) {
    si : ., mut = 0;
    loop { if si >= g_ir_slice_len_count { break; }
        if r64(g_ir_slice_lens, si * 16) == var_idx {
            w64(g_ir_slice_lens, si * 16 + 8, len_code);
            return;
        }
        si = si + 1; }
    if len_code == -1 { return; }  // 清除无条目 = no-op；负编码（长度变量）允许新增
    grow_ir_slice_lens(g_ir_slice_len_count + 1);
    w64(g_ir_slice_lens, g_ir_slice_len_count * 16, var_idx);
    w64(g_ir_slice_lens, g_ir_slice_len_count * 16 + 8, len_code);
    g_ir_slice_len_count = g_ir_slice_len_count + 1;
}

// 登记运行时界切片的长度变量；查询返回 len_var（无 → -1）。
fn slice_len_var_set(var_idx: int, len_var: int) {
    if var_idx < 0 || len_var < 0 { return; }
    slice_len_raw_set(var_idx, -2 - len_var);
}

fn slice_len_var_get(var_idx: int) -> int {
    si : ., mut = 0;
    loop { if si >= g_ir_slice_len_count { break; }
        if r64(g_ir_slice_lens, si * 16) == var_idx {
            v := r64(g_ir_slice_lens, si * 16 + 8);
            if v <= -2 { return -2 - v; }
            return -1;
        }
        si = si + 1; }
    return -1;
}

// 切片长度沿赋值/LET 传播：无条件同步 src 记录到 dst——src 无记录
// 时清除 dst（防非切片赋值后陈旧长度残留导致误守卫）。
fn slice_len_copy_to(dst_var: int, src_var: int) {
    si : ., mut = 0;
    loop { if si >= g_ir_slice_len_count { break; }
        if r64(g_ir_slice_lens, si * 16) == src_var {
            slice_len_raw_set(dst_var, r64(g_ir_slice_lens, si * 16 + 8));
            return;
        }
        si = si + 1; }
    slice_len_raw_set(dst_var, -1);
}

// 切片解引用守卫（运行时界长度）：s1 = idx 变量/字面量，上限 = 长度变量
// （IR_BOUNDS_CHECK ti=1 动态上限——与 emit_string_bounds 同机制）。
fn emit_slice_bounds(arr_var: int, idx_var: int) {
    if arr_var < 0 || idx_var < 0 { return; }
    lv := slice_len_var_get(arr_var);
    if lv >= 0 { emit(IR_BOUNDS_CHECK, -1, idx_var, lv, 0, 1); }
}

fn emit_slice_lit_bounds(arr_var: int, idx_lit: int) {
    if arr_var < 0 { return; }
    lv := slice_len_var_get(arr_var);
    if lv >= 0 {
        t := new_ir_var("_slice_idx", TI_INT);
        emit(IR_CONST, t, idx_lit, 0, 0, TI_INT);
        emit(IR_BOUNDS_CHECK, -1, t, lv, 0, 1);
    }
}

// 数组/切片的编译期长度：TYP_ARRAY 的 extra=size；切片查侧表（字面量界）。
// 未知 → -1（ext_safety 不发射 IR_BOUNDS_CHECK）。
fn arr_len_lit_of(arr_var: int) -> int {
    if arr_var < 0 { return -1; }
    ti := irv_type(arr_var);
    if ti >= 0 && ti < g_type_count && get_type_kind(ti) == TYP_ARRAY {
        return get_type_extra(ti);
    }
    if ti == TI_STR {
        prod := r64(g_df_var_producer, arr_var * 8);
        if prod >= 0 && r64(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_OPCODE) == IR_CONST &&
           r64(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_TK) == TI_STR {
            return istr_len(r64(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_S1));
        }
    }
    return slice_len_get(arr_var);
}

fn emit_string_bounds(arr_var: int, idx_var: int) {
    if arr_var < 0 || idx_var < 0 || irv_type(arr_var) != TI_STR { return; }
    len_var := new_ir_var("str_len", TI_INT);
    emit(IR_CALL, len_var, arr_var, 1, str_intern("str_len"), TI_INT);
    emit(IR_BOUNDS_CHECK, -1, idx_var, len_var, 0, 1);
}

// 字面量下标 + 字符串 → 运行时边界守卫（M-2 遗留：emit_string_bounds
// 只覆盖变量下标路径，常量下标路径与 arr_len_lit 两头落空——静默越界）。
fn emit_string_lit_bounds(arr_var: int, idx_lit: int) {
    if arr_var < 0 || irv_type(arr_var) != TI_STR { return; }
    idx_var := new_ir_var("_idx_lit", TI_INT);
    emit(IR_CONST, idx_var, idx_lit, 0, 0, TI_INT);
    emit_string_bounds(arr_var, idx_var);
}

fn grow_sg_alloc(needed: int) {
    if needed < g_sg_alloc_cap { return; }
    nc := g_sg_alloc_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 8); _dyncpy(g_sg_alloc_total, g_sg_alloc_cap * 8, nb); g_sg_alloc_total = nb; g_sg_alloc_cap = nc; }

fn grow_sg_arena_var(needed: int) {
    if needed < g_sg_arena_var_cap { return; }
    nc := g_sg_arena_var_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 8); _dyncpy(g_sg_arena_var, g_sg_arena_var_cap * 8, nb); g_sg_arena_var = nb; g_sg_arena_var_cap = nc; }

fn sg_alloc_push(kind: int) {
    grow_sg_alloc(g_sg_count + 1);
    grow_sg_arena_var(g_sg_count + 1);
    w64(g_sg_alloc_total, g_sg_count * 8, 0);
    sg_push(kind);
}

fn sg_alloc_pop() {
    total := r64(g_sg_alloc_total, (g_sg_count - 1) * 8);
    arena_var := r64(g_sg_arena_var, (g_sg_count - 1) * 8);
    sg_pop();
    emit(IR_ARENA_RESET, -1, arena_var, 0, 0, 0);
}

fn track_alloc_size(size: int) {
    if g_sg_count > 0 && str_len(g_sg_alloc_total) > 0 {
        prev := r64(g_sg_alloc_total, (g_sg_count - 1) * 8);
        w64(g_sg_alloc_total, (g_sg_count - 1) * 8, prev + size);
    }
}

fn new_ir_var(name: string, type_idx: int) -> int {
    idx := g_ir_var_count;
    grow_ir_vars(idx + 1);
    irv_set_name(idx, str_intern(name));
    irv_set_id(idx, idx);
    irv_set_type(idx, type_idx);
    g_ir_var_count = idx + 1;
    return idx;
}

fn emit(opcode: int, dest: int, src1: int, src2: int, src3: int, type_kind: int) {
    // Build linear IR (.ccr) — consumed by x86-64 backend
    idx := g_ir_instr_count;
    grow_ir_instrs(idx + 1);
    iri_set_op(idx, opcode);
    iri_set_dest(idx, dest);
    iri_set_s1(idx, src1);
    iri_set_s2(idx, src2);
    iri_set_s3(idx, src3);
    iri_set_tk(idx, type_kind);
    g_ir_instr_count = idx + 1;
    // Build dataflow graph (.cir) in parallel
    df_create_node(opcode, dest, src1, src2, src3, type_kind);
}

fn new_label() -> int {
    lbl := g_next_label;
    g_next_label = g_next_label + 1;
    return lbl;
}

fn bind_local(name_idx: int, var_idx: int) {
    grow_ir_locals(g_ir_local_count + 1);
    w64(g_ir_locals, g_ir_local_count  * 16, name_idx);
    w64(g_ir_locals, g_ir_local_count  * 16 + 8, var_idx);
    g_ir_local_count = g_ir_local_count + 1;
}

fn find_local(name_idx: int) -> int {
    i : ., mut = g_ir_local_count - 1;
    loop {
        if i < 0 { return -1; }
        if r64(g_ir_locals, i * 16) == name_idx { return r64(g_ir_locals, i * 16 + 8); }
        i = i - 1;
    }
    return -1;
}

fn find_global(name_idx: int) -> int {
    i : ., mut = g_ir_global_count - 1;
    loop {
        if i < 0 { return -1; }
        if r64(g_ir_globals, i * 24) == name_idx { return r64(g_ir_globals, i * 24 + 8); }
        i = i - 1;
    }
    return -1;
}

// Return the literal initializer AST node for an immutable module-level
// constant.  The ELF backend has no data initializers, so leaving these as
// BSS globals turns values such as T_FN and ESZ_TOKEN into zero at runtime.
fn find_global_const_node(name_idx: int) -> int {
    i : ., mut = g_global_let_count - 1;
    loop {
        if i < 0 { break; }
        node := r64(g_global_lets, i * 8);
        if ast_a(node) == name_idx && ast_data(node) == 0 {
            value_node := ast_c(node);
            if value_node >= 0 {
                value_kind := ast_kind(value_node);
                if value_kind == EXPR_INT || value_kind == EXPR_BOOL ||
                   value_kind == EXPR_DEX {
                    return value_node;
                }
            }
        }
        i = i - 1;
    }

    return -1;
}

fn push_ir_scope() {
    grow_ir_local_scopes(g_ir_local_depth + 1);
    w64(g_ir_local_scopes, g_ir_local_depth * 8, g_ir_local_count);
    g_ir_local_depth = g_ir_local_depth + 1;
}

fn pop_ir_scope() {
    g_ir_local_depth = g_ir_local_depth - 1;
    g_ir_local_count = r64(g_ir_local_scopes, g_ir_local_depth * 8);
}

fn is_ptr_var(var_idx: int) -> int {
    if var_idx < 0 { return 0; }
    ti := irv_type(var_idx);
    if ti == TI_DEX_S { return 0; }  // 哨兵类型：不查类型表（终审 M1：8 为占位表项，用户类型从 9 起）
    if ti >= 0 {
        tk := get_type_kind(ti);
        if tk == TYP_PTR || tk == TYP_REF { return 1; }
    }
    prod := r64(g_df_var_producer, var_idx * 8);
    if prod < 0 { return 0; }
    prod_op := r64(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_OPCODE);
    if prod_op == IR_ALLOC {
        ti := irv_type(var_idx);
        if ti == TI_INT || ti == TI_DEX || ti == TI_BOOL || ti == TI_CHAR {
            return 0;
        }
        return 1;
    }
    if prod_op == IR_ADDR_INDEX || prod_op == IR_REF ||
       prod_op == IR_ALLOC_STRUCT || prod_op == IR_ALLOC_ARRAY {
        return 1;
    }
    return 0;
}

fn is_byte_buf_var(var_idx: int) -> int {
    // Raw byte buffers produced by alloc() (TI_UNIT internal sentinel,
    // Core `string`) are byte-addressed: `buf + n` must NOT scale n by
    // the 8-byte element size.
    if var_idx < 0 { return 0; }
    if irv_type(var_idx) != TI_UNIT { return 0; }
    prod := r64(g_df_var_producer, var_idx * 8);
    if prod < 0 { return 0; }
    prod_op := r64(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_OPCODE);
    if prod_op == IR_ALLOC { return 1; }
    if prod_op == IR_CALL {
        func_ni := r64(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_S3);
        if func_ni >= 0 && istr_get(func_ni) == "alloc" { return 1; }
    }
    return 0;
}

fn ir_call_return_type(func_ni: int) -> int {
    if func_ni < 0 { return TI_UNIT; }
    // alloc() produces a raw byte buffer. Keep the existing internal pointer
    // sentinel until Core has a distinct raw-buffer type.
    if istr_get(func_ni) == "alloc" { return TI_UNIT; }
    bi : ., mut = 0;
    loop {
        if bi >= g_rt_builtin_count { break; }
        if r64(g_rt_builtin_names, bi * 8) == func_ni {
            return r64(g_rt_builtin_ret_types, bi * 8);
        }
        bi = bi + 1;
    }
    fi := find_func(func_ni);
    if fi >= 0 {
        rt := fi_return_type(fi);
        if rt == TY_INT { return TI_INT; }
        if rt == TY_DEX {
            // dex 边界规则（数值迁移 Task 4）：Core 函数返回精确形式（缩放整数）；
            // extern 函数保留 TI_DEX（binary64 位模式——C ABI / apx 授权 FFI）
            if fi_ast_node(fi) >= 0 && ast_kind(fi_ast_node(fi)) == EXPR_EXTERN {
                return TI_DEX;
            }
            return TI_DEX_S;
        }
        if rt == TY_BOOL { return TI_BOOL; }
        if rt == TY_STRING { return TI_STR; }
        if rt == TY_UNIT { return TI_UNIT; }
        if rt == TY_CHAR { return TI_CHAR; }
    }
    si := find_gsym(func_ni);
    if si < 0 { return TI_UNIT; }
    if sym_kind(si) == SYM_FN { return sym_type(si); }
    if sym_kind(si) == SYM_SO_FN {
        type_enc := sym_node(si);
        ret_code := type_enc - (type_enc / 100) * 100;
        if ret_code == 0 { return TI_INT; }
        if ret_code == 1 { return TI_STR; }
        if ret_code == 2 { return TI_UNIT; }
        if ret_code == 3 { return TI_DEX; }
        if ret_code == 4 { return TI_BOOL; }
    }
    return TI_UNIT;
}

// --- Track string constants ---
fn track_str(str_idx: int) {
    i : ., mut = 0;
    loop {
        if i >= g_ir_str_const_count { break; }
        if r64(g_ir_str_consts, i * 8) == str_idx { return; }
        i = i + 1;
    }
    grow_ir_str_consts(g_ir_str_const_count + 1);
    w64(g_ir_str_consts, g_ir_str_const_count * 8, str_idx);
    g_ir_str_const_count = g_ir_str_const_count + 1;
}

// --- Loop label stack ---
fn push_loop_labels(header: int, exit: int) {
    grow_ir_loop_stacks(g_ir_loop_depth + 1);
    w64(g_ir_loop_header, g_ir_loop_depth * 8, header);
    w64(g_ir_loop_exit, g_ir_loop_depth * 8, exit);
    g_ir_loop_depth = g_ir_loop_depth + 1;
}

fn pop_loop_labels() {
    g_ir_loop_depth = g_ir_loop_depth - 1;
}

// 枚举变体名查找（F15）：name_idx 是否为任一枚举的变体名（裸引用 `c := Red`）。
// 匹配返回 name_idx 本身；非变体名返回 -1。checker 的 collect_decls 把每个
// 变体名注册为 SYM_FN（指向枚举类型）——裸变体经类型检查后到达 ir_gen。
fn find_enum_variant(name_idx: int) -> int {
    ei : ., mut = 0;
    loop {
        if ei >= g_enum_count { break; }
        vi : ., mut = 0;
        loop {
            if vi >= ei_variant_count(ei) { break; }
            if ei_variant_name(ei, vi) == name_idx { return name_idx; }
            vi = vi + 1;
        }
        ei = ei + 1;
    }
    return -1;
}

fn get_variant_name_idx(qualified_ni: int) -> int {
    s := istr_get(qualified_ni);
    slen := str_len(s);
    dot_pos : ., mut = -1;
    i : ., mut = 0;
    loop {
        if i >= slen { break; }
        c := get_char(s, i);
        if str_eq(c, ".") != 0 { dot_pos = i; }
        i = i + 1;
    }
    if dot_pos >= 0 {
        variant_name := str_sub(s, dot_pos + 1, slen - dot_pos - 1);
        return str_intern(variant_name);
    }
    return qualified_ni;
}

// --- Type metadata helpers for @ builtins ---

// Resolve a type expression node to a TI_* type index.
// Handles type nodes (ast_kind==0 from parse_type) and EXPR_IDENT
// (basic type names not in the symbol table).
fn ti_from_type_expr(node: int) -> int {
    if node < 0 { return TI_UNIT; }
    // Type node from parse_type: ast_kind == 0, type_val = TY_*
    if ast_kind(node) == 0 {
        tv := ast_type_val(node);
        if tv == TY_INT { return TI_INT; }
        if tv == TY_DEX { return TI_DEX; }
        if tv == TY_BOOL { return TI_BOOL; }
        if tv == TY_STRING { return TI_STR; }
        if tv == TY_CHAR { return TI_CHAR; }
        if tv == TY_UNIT { return TI_UNIT; }
        return TI_UNIT;
    }
    // EXPR_IDENT from parse_expr: int_val = name string index
    if ast_kind(node) == EXPR_IDENT {
        ni := ast_int_val(node);
        name := istr_get(ni);
        if str_eq(name, "int") != 0 { return TI_INT; }
        if str_eq(name, "dex") != 0 { return TI_DEX; }
        if str_eq(name, "bool") != 0 { return TI_BOOL; }
        if str_eq(name, "string") != 0 { return TI_STR; }
        if str_eq(name, "char") != 0 { return TI_CHAR; }
        if str_eq(name, "unit") != 0 { return TI_UNIT; }
        // Named types (structs, enums): look up in symbol table
        si := find_gsym(ni);
        if si >= 0 && sym_kind(si) == SYM_TYPE { return sym_type(si); }
    }
    // Complex type expressions: delegate to checker's resolver
    return res_type_node(node);
}

// Type size in bytes
fn type_size(ti: int) -> int {
    if ti == TI_DEX_S { return 8; }  // 哨兵类型：8 字节槽（不查类型表；终审 M1：8 为占位表项，用户类型从 9 起）
    if ti == TI_CHAR { return 4; }  // not in type table
    if ti < 0 || ti >= g_type_count { return 8; }
    k := get_type_kind(ti);
    if k == TYP_BASE {
        d := get_type_data(ti);
        if d == TY_INT { return 8; }
        if d == TY_DEX { return 8; }
        if d == TY_BOOL { return 1; }
        if d == TY_STRING { return 8; }
        if d == TY_UNIT { return 0; }
        if d == TY_CHAR { return 4; }
        return 8;
    }
    if k == TYP_ARRAY {
        elem := get_type_data(ti);
        cnt := get_type_extra(ti);
        return type_size(elem) * cnt;
    }
    if k == TYP_PTR || k == TYP_REF { return 8; }
    if k == TYP_SLICE { return 16; }
    if k == TYP_NAMED {
        name_ni := get_type_data(ti);
        si : ., mut = 0;
        loop {
            if si >= g_struct_count { break; }
            if si_name(si) == name_ni { return si_field_count(si) * 8; }
            si = si + 1;
        }
        return 8;
    }
    return 8;
}

fn ptr_pointee_type(var_idx: int) -> int {
    if var_idx < 0 { return TI_INT; }
    ti := irv_type(var_idx);
    if ti >= 0 {
        k := get_type_kind(ti);
        if k == TYP_PTR || k == TYP_REF { return get_type_data(ti); }
    }
    return TI_INT;
}

fn ptr_access_width(var_idx: int) -> int {
    width := type_size(ptr_pointee_type(var_idx));
    if width <= 0 { return 8; }
    return width;
}

// Type alignment in bytes
fn type_align(ti: int) -> int {
    if ti == TI_DEX_S { return 8; }  // 哨兵类型：8 字节对齐（不查类型表；终审 M1：8 为占位表项）
    if ti == TI_CHAR { return 4; }
    if ti < 0 || ti >= g_type_count { return 8; }
    k := get_type_kind(ti);
    if k == TYP_BASE {
        d := get_type_data(ti);
        if d == TY_INT { return 8; }
        if d == TY_DEX { return 8; }
        if d == TY_BOOL { return 1; }
        if d == TY_STRING { return 8; }
        if d == TY_CHAR { return 4; }
        return 8;
    }
    if k == TYP_ARRAY { return type_align(get_type_data(ti)); }
    if k == TYP_PTR || k == TYP_REF { return 8; }
    if k == TYP_SLICE { return 8; }
    if k == TYP_NAMED { return 8; }
    return 8;
}

// Resolve a type index to a struct info index.
// Returns -1 if the type is not a struct type.
fn ti_resolve_struct(ti: int) -> int {
    if ti < 0 || ti >= g_type_count { return -1; }
    k := get_type_kind(ti);
    if k != TYP_NAMED { return -1; }
    name_ni := get_type_data(ti);
    if name_ni < 0 { return -1; }
    name := istr_get(name_ni);
    si : ., mut = 0;
    loop {
        if si >= g_struct_count { break; }
        sn_ni := si_name(si);
        sn := istr_get(sn_ni);
        if str_eq(sn, name) != 0 { return si; }
        si = si + 1;
    }
    return -1;
}

// Check if a struct type has a field by name
fn ti_has_field(ti: int, name: string) -> int {
    si := ti_resolve_struct(ti);
    if si < 0 { return 0; }
    fc := si_field_count(si);
    fi : ., mut = 0;
    loop {
        if fi >= fc { break; }
        fn_ni := si_field_name(si, fi);
        fname := istr_get(fn_ni);
        if str_eq(fname, name) != 0 { return 1; }
        fi = fi + 1;
    }
    return 0;
}

// Get field byte offset (each field is 8 bytes)
fn ti_field_offset(ti: int, name: string) -> int {
    si := ti_resolve_struct(ti);
    if si < 0 { return -1; }
    fc := si_field_count(si);
    fi : ., mut = 0;
    loop {
        if fi >= fc { break; }
        fn_ni := si_field_name(si, fi);
        fname := istr_get(fn_ni);
        if str_eq(fname, name) != 0 { return fi * 8; }
        fi = fi + 1;
    }
    return -1;
}

// Check if a function name refers to a hotpatch function (has @hotpatch versions)
fn is_hotpatch_func(name_idx: int) -> int {
    count : ., mut = 0;
    i : ., mut = 0;
    loop {
        if i >= g_func_count { break; }
        if fi_name(i) == name_idx {
            fn_node := fi_ast_node(i);
            if fn_node >= 0 {
                hotpatch_ver := ast_int_val(fn_node) / 256;
                if hotpatch_ver > 0 { count = count + 1; }
            }
        }
        i = i + 1;
    }
    if count > 0 { return 1; }
    return 0;
}

// Helper: if a variable's producer is IR_LAZY_THUNK, emit IR_LAZY_FORCE
// to extract the real value and return the forced variable.
fn force_if_thunk(var_idx: int) -> int {
    if var_idx < 0 { return var_idx; }
    prod := r64(g_df_var_producer, var_idx * 8);
    if prod >= 0 {
        prod_op := r64(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_OPCODE);
        if prod_op == IR_LAZY_THUNK {
            forced := new_ir_var("_forced", irv_type(var_idx));
            emit(IR_LAZY_FORCE, forced, var_idx, 0, 0, 0);
            return forced;
        }
    }
    return var_idx;
}

// --- dex 定点精确运算辅助（数值迁移 Task 4）---
// dex 值有两种 IR 形式：
//   TI_DEX_S = 定点缩放整数（精确形式，S = 10^6，默认世界——跨函数边界统一此形式）
//   TI_DEX   = binary64 位模式（apx 形式——apx 变量及其运算的快路径表示）
// 转换规则（文档化）：运算按操作数形式分流（有 TI_DEX 操作数 → binary64 快路径，
// 否则 → 定点整数指令序列）；存储/边界处按槽位形式转换（apx 结果在边界按定点
// 6 位截断/舍入——「精确，或经授权的近似」契约的兑现）。

// bits（TI_DEX）→ 缩放整数（TI_DEX_S）：round(bits × S)——6 位定点舍入（四舍五入
// 半进，数值迁移 Task 6 定稿：apx 打印/边界行为 = 6 位定点舍入，非截断、非全精度
// binary64）。实现：F2I 本身向零截断——正数先 +0.5、负数先 −0.5（分支按 m < 0 分流，
// 与字面量 str_to_scaled 的半进一致；半进 = 绝对值半上，-0.5 → -1）。此舍入同时吸收
// str_to_f64_bits 字面量转换的 ~2ulp 截断误差（打印/边界 6 位精度下不可见）。
fn dex_bits_to_scaled(var: int) -> int {
    if irv_type(var) != TI_DEX { return var; }
    c := new_ir_var("_dxs", TI_DEX);
    emit(IR_CONST, c, 4696837146684686336, 0, 0, TI_DEX);  // 1e6 的 binary64 位模式
    m := new_ir_var("_dxm", TI_DEX);
    emit(IR_BINARY, m, var, c, OP_MUL, TI_DEX);
    zero := new_ir_var("_dx0", TI_DEX);
    emit(IR_CONST, zero, 0, 0, 0, TI_DEX);
    negc := new_ir_var("_dxc", TI_INT);
    emit(IR_BINARY, negc, m, zero, OP_LT, TI_DEX);  // m < 0 → int 0/1（comisd 路径）
    half := new_ir_var("_dxh", TI_DEX);
    emit(IR_CONST, half, 4602678819172646912, 0, 0, TI_DEX);  // 0.5 的 binary64 位模式（0x3FE0000000000000）
    pos_lbl := new_label();
    neg_lbl := new_label();
    merge_lbl := new_label();
    mrg := new_ir_var("_dxmrg", TI_DEX);
    emit(IR_BRANCH, -1, negc, neg_lbl, pos_lbl, 0);
    emit(IR_LABEL, -1, pos_lbl, 0, 0, 0);
    rp := new_ir_var("_dxrp", TI_DEX);
    emit(IR_BINARY, rp, m, half, OP_ADD, TI_DEX);  // m ≥ 0：+0.5
    emit(IR_STORE, -1, mrg, rp, 0, 0);
    emit(IR_JUMP, -1, merge_lbl, 0, 0, 0);
    emit(IR_LABEL, -1, neg_lbl, 0, 0, 0);
    rn := new_ir_var("_dxrn", TI_DEX);
    emit(IR_BINARY, rn, m, half, OP_SUB, TI_DEX);  // m < 0：−0.5
    emit(IR_STORE, -1, mrg, rn, 0, 0);
    emit(IR_LABEL, -1, merge_lbl, 0, 0, 0);
    r := new_ir_var("_dxsc", TI_DEX_S);
    emit(IR_F2I, r, mrg, 0, 0, TI_DEX);
    return r;
}

// 缩放整数（TI_DEX_S）→ bits（TI_DEX）：I2F(scaled) / S
// 字面量节点（EXPR_DEX）直接重发射为 bits 常量（与 lexer 位模式一致，免转换序列）
fn dex_scaled_to_bits(var: int, node: int) -> int {
    if irv_type(var) != TI_DEX_S { return var; }
    if node >= 0 && ast_kind(node) == EXPR_DEX {
        v := new_ir_var("dex", TI_DEX);
        emit(IR_CONST, v, ast_a(node), 0, 0, TI_DEX);
        return v;
    }
    f := new_ir_var("_dxf", TI_DEX);
    emit(IR_I2F, f, var, 0, 0, TI_DEX);
    c := new_ir_var("_dxsc", TI_DEX);
    emit(IR_CONST, c, 4696837146684686336, 0, 0, TI_DEX);  // 1e6 bits
    d := new_ir_var("_dxdiv", TI_DEX);
    emit(IR_BINARY, d, f, c, OP_DIV, TI_DEX);
    return d;
}

// int 操作数 → 定点缩放（×S）：精确路径的 int 隐式对齐（与 apx 路径的 I2F 同位）
fn dex_scale_int(var: int) -> int {
    if irv_type(var) != TI_INT { return var; }
    c := new_ir_var("_dsc", TI_INT);
    emit(IR_CONST, c, 1000000, 0, 0, TI_INT);
    t := new_ir_var("_dxt", TI_DEX_S);
    emit(IR_BINARY, t, var, c, OP_MUL, TI_INT);
    return t;
}

// 存储到 dex 槽位前按槽位形式转换（数值迁移 Task 4）：
//   TI_DEX 槽（apx 变量）← 缩放值：scaled → bits（字面量重发射，计算值 I2F/S）
//   TI_DEX_S 槽（精确变量）← bits 值：bits → scaled（apx 结果按定点 6 位舍入入精确世界）
fn dex_store_adjust(target: int, val: int, val_node: int) -> int {
    tt := irv_type(target);
    vt := irv_type(val);
    if tt == TI_DEX && vt == TI_DEX_S { return dex_scaled_to_bits(val, val_node); }
    if tt == TI_DEX_S && vt == TI_DEX { return dex_bits_to_scaled(val); }
    return val;
}

// --- IR generation for expressions ---
// Returns the IR variable index holding the result

fn gen_expr(node: int) -> int {
    if node < 0 { return -1; }

    if ast_kind(node) == EXPR_NONE {
        // Wrapper node: forward to inner expression (used in struct literals)
        if ast_a(node) >= 0 && ast_a(node) != node { return gen_expr(ast_a(node)); }
        return -1;
    }

    // Literals
    if ast_kind(node) == EXPR_INT {
        v := new_ir_var("int", TI_INT);
        emit(IR_CONST, v, ast_int_val(node), 0, 0, TI_INT);
        return v;
    }
    if ast_kind(node) == EXPR_DEX {
        // 精确字面量（数值迁移 Task 4）：定点缩放整数常量（TI_DEX_S）。
        // apx 场景（变量级 apx 标签的运算）在运算点按 node.a 的 binary64 位模式重发射。
        v := new_ir_var("dex", TI_DEX_S);
        emit(IR_CONST, v, ast_int_val(node), 0, 0, TI_DEX_S);
        return v;
    }
    if ast_kind(node) == EXPR_BOOL {
        v := new_ir_var("bool", TI_BOOL);
        emit(IR_CONST, v, ast_int_val(node), 0, 0, TI_BOOL);
        return v;
    }
    if ast_kind(node) == EXPR_STRING {
        v := new_ir_var("str", TI_STR);
        str_idx := ast_int_val(node);
        track_str(str_idx);
        emit(IR_CONST, v, str_idx, 0, 0, TI_STR);
        return v;
    }
    if ast_kind(node) == EXPR_CHAR {
        v := new_ir_var("char", TI_CHAR);
        str_idx := ast_int_val(node);
        track_str(str_idx);
        emit(IR_CONST, v, str_idx, 0, 0, TI_CHAR);
        return v;
    }

    // Identifier: local or global variable
    if ast_kind(node) == EXPR_IDENT {
        name_idx := ast_int_val(node);
        lv := find_local(name_idx);
        if lv >= 0 { return lv; }
        const_node := find_global_const_node(name_idx);
        if const_node >= 0 {
            const_type : ., mut = TI_INT;
            if ast_kind(const_node) == EXPR_BOOL { const_type = TI_BOOL; }
            if ast_kind(const_node) == EXPR_DEX { const_type = TI_DEX_S; }  // 定点缩放常量
            cv := new_ir_var("const", const_type);
            emit(IR_CONST, cv, ast_int_val(const_node), 0, 0, const_type);
            return cv;
        }
        gv := find_global(name_idx);
        if gv >= 0 { return gv; }
        // F15：枚举裸变体（c := Red，不带括号）——发射无 payload 的 MAKE_ENUM
        // （s1=变体名 ni、s2=0），与 EXPR_ENUM_CONSTRUCTOR 的 `Red()` 调用形式
        // 同机制（tag = 变体名驻留索引，match 按名字比较）。修复前落为下方
        // "unresolved" 哑变量 → 后续 LOAD_ENUM_TAG 解引用垃圾值 → SIGSEGV（139）。
        if find_enum_variant(name_idx) >= 0 {
            s := new_ir_var("enum", TI_UNIT);
            emit(IR_MAKE_ENUM, s, name_idx, 0, 0, 0);
            return s;
        }
        // Could be a function name being used as a value - return dummy
        v := new_ir_var("unresolved", TI_UNIT);
        return v;
    }

    // Binary operation
    if ast_kind(node) == EXPR_BINARY {
        left := ast_a(node);
        right := ast_b(node);
        op := ast_c(node);

        // Assignment
        if op == OP_ASSIGN {
            val_var := gen_expr(right);
            val_var = force_if_thunk(val_var);
            // Determine lhs kind
            if ast_kind(left) == EXPR_IDENT {
                name_idx := ast_int_val(left);
                target := find_local(name_idx);
                if target >= 0 {
                    if irv_type(target) == TI_DYN {
                        // Dyn variable assignment: pack value with type tag
                        tag := irv_type(val_var);
                        if tag < 0 { tag = TI_INT; }
                        emit(IR_DYN_PACK, target, val_var, tag, 0, 0);
                    } else {
                        // dex 槽位形式转换（数值迁移 Task 4：apx 槽存 bits，精确槽存缩放）
                        val_var = dex_store_adjust(target, val_var, right);
                         // F11：切片长度沿赋值传播（字面量/运行时界长度变量同步；源无记录则清除）
                         slice_len_copy_to(target, val_var);
emit(IR_STORE, -1, target, val_var, 0, 0);
                    }
                } else {
                    gtarget := find_global(name_idx);
                    if gtarget >= 0 {
                        val_var = dex_store_adjust(gtarget, val_var, right);
                        emit(IR_STORE, -1, gtarget, val_var, 0, 0);
                    }
                }
                return val_var;
            }
            if ast_kind(left) == EXPR_FIELD {
                obj_var := gen_expr(ast_a(left));
                obj_var = force_if_thunk(obj_var);
                field_ni := ast_int_val(left);
                fi := ast_data(left);  // field index stored by checker
                emit(IR_STORE_FIELD, -1, obj_var, val_var, fi, 0);
                return val_var;
            }
            if ast_kind(left) == EXPR_INDEX {
                arr_var := gen_expr(ast_a(left));
                arr_var = force_if_thunk(arr_var);
                idx_node := ast_b(left);
                idx_kind := ast_kind(idx_node);
                // F1：写路径越界守卫钩子（EXPR_BINARY OP_ASSIGN 遗留路径，同步修复）
                arr_len_lit : ., mut = arr_len_lit_of(arr_var);
                if idx_kind == EXPR_INT {
                    emit_string_lit_bounds(arr_var, ast_int_val(idx_node));
                    emit_slice_lit_bounds(arr_var, ast_int_val(idx_node));
                    if pass_before_array_access(arr_var, -1, ast_int_val(idx_node), arr_len_lit) == 0 {
                        emit(IR_STORE_INDEX, -1, arr_var, val_var, ast_int_val(idx_node), 0);
                    }
        } else {
            idx_var := gen_expr(idx_node);
            idx_var = force_if_thunk(idx_var);
            emit_string_bounds(arr_var, idx_var);
            emit_slice_bounds(arr_var, idx_var);
            if pass_before_array_access(arr_var, idx_var, -1, arr_len_lit) == 0 {
                emit(IR_STORE_INDEX_VAR, val_var, arr_var, idx_var, 0, 0);
            }
                }
                return val_var;
            }
            return val_var;
        }

        // Regular binary
        left_var := gen_expr(left);
        left_var = force_if_thunk(left_var);
        // Logical operators must short-circuit.  Eagerly generating the
        // right side breaks guard expressions such as
        // `fi >= 0 && fi_generic_count(fi) > 0`.
        if op == OP_AND || op == OP_OR {
            right_lbl := new_label();
            short_lbl := new_label();
            merge_lbl := new_label();
            logic_result := new_ir_var("logic", TI_BOOL);
            if op == OP_AND {
                emit(IR_BRANCH, -1, left_var, right_lbl, short_lbl, 0);
            } else {
                emit(IR_BRANCH, -1, left_var, short_lbl, right_lbl, 0);
            }

            emit(IR_LABEL, -1, short_lbl, 0, 0, 0);
            short_value := new_ir_var("logic_short", TI_BOOL);
            if op == OP_AND { emit(IR_CONST, short_value, 0, 0, 0, TI_BOOL); }
            else { emit(IR_CONST, short_value, 1, 0, 0, TI_BOOL); }
            emit(IR_STORE, -1, logic_result, short_value, 0, 0);
            emit(IR_JUMP, -1, merge_lbl, 0, 0, 0);

            emit(IR_LABEL, -1, right_lbl, 0, 0, 0);
            right_value := gen_expr(right);
            right_value = force_if_thunk(right_value);
            emit(IR_STORE, -1, logic_result, right_value, 0, 0);
            emit(IR_JUMP, -1, merge_lbl, 0, 0, 0);

            emit(IR_LABEL, -1, merge_lbl, 0, 0, 0);
            return logic_result;
        }
        right_var := gen_expr(right);
        right_var = force_if_thunk(right_var);
        lt := irv_type(left_var);
        rt := irv_type(right_var);

        // Unwrap dyn operands: extract the underlying value for binary ops
        if lt == TI_DYN {
            uv := new_ir_var("_dynval", TI_UNIT);
            emit(IR_DYN_VAL, uv, left_var, 0, 0, 0);
            left_var = uv;
            lt = irv_type(left_var);
        }
        if rt == TI_DYN {
            uv := new_ir_var("_dynval", TI_UNIT);
            emit(IR_DYN_VAL, uv, right_var, 0, 0, 0);
            right_var = uv;
            rt = irv_type(right_var);
        }

        // String equality compares contents, not pointer values.
        if (op == OP_EQ || op == OP_NE) && (lt == TI_STR || rt == TI_STR) {
            eq_ni := str_intern("str_eq");
            eq_arg0 := new_ir_var("_eq0", lt);
            eq_arg1 := new_ir_var("_eq1", rt);
            emit(IR_STORE, -1, eq_arg0, left_var, 0, 0);
            emit(IR_STORE, -1, eq_arg1, right_var, 0, 0);
            eq_value := new_ir_var("str_eq", TI_BOOL);
            emit(IR_CALL, eq_value, eq_arg0, 2, eq_ni, TI_BOOL);
            if op == OP_EQ { return eq_value; }
            zero_value := new_ir_var("zero", TI_INT);
            emit(IR_CONST, zero_value, 0, 0, 0, TI_INT);
            ne_value := new_ir_var("str_ne", TI_BOOL);
            emit(IR_BINARY, ne_value, eq_value, zero_value, OP_EQ, TI_BOOL);
            return ne_value;
        }
        // String concatenation — call concat() instead of IR_BINARY
        if op == OP_ADD {
            if lt == TI_STR || rt == TI_STR {
                concat_ni := str_intern("concat");
                // Pack both args into consecutive vars so ELF backend finds them
                packed0 := new_ir_var("_cat0", lt);
                packed1 := new_ir_var("_cat1", rt);
                emit(IR_STORE, -1, packed0, left_var, 0, 0);
                emit(IR_STORE, -1, packed1, right_var, 0, 0);
                v := new_ir_var("str", TI_STR);
                emit(IR_CALL, v, packed0, 2, concat_ni, TI_STR);
                return v;
            }
        }
        fti : int = TI_INT;
        // Pointer arithmetic: use PTR_ADD/PTR_SUB/PTR_DIFF instead of standard opcodes.
        // Raw byte buffers from alloc() are byte-addressed — plain ADD/SUB, no scaling.
        if is_ptr_var(left_var) != 0 || is_ptr_var(right_var) != 0 {
            buf_left := is_byte_buf_var(left_var);
            buf_right := is_byte_buf_var(right_var);
            if buf_left == 0 && buf_right == 0 {
                if op == OP_ADD { op = OP_PTR_ADD; }
                else if op == OP_SUB {
                    if is_ptr_var(left_var) != 0 && is_ptr_var(right_var) != 0 {
                        op = OP_PTR_DIFF;
                    } else {
                        op = OP_PTR_SUB;
                    }
                }
            }
        }
        if op == OP_PTR_ADD || op == OP_PTR_SUB {
            if is_ptr_var(left_var) != 0 { fti = irv_type(left_var); }
            else if is_ptr_var(right_var) != 0 { fti = irv_type(right_var); }
        }
        // dex 运算分流（数值迁移 Task 4）：
        //   有 TI_DEX（apx 形式）操作数 → binary64 快路径（SSE2，IEEE 754——apx 标准答案）
        //   有 TI_DEX_S（定点形式）操作数 → 精确路径（缩放整数指令序列）
        if lt == TI_DEX || rt == TI_DEX {
            fti = TI_DEX;
            // apx 路径操作数对齐：字面量 → 重发射 bits 常量；定点（TI_DEX_S）→
            // I2F/S 转 bits（按精确值参与——apx 授权的近似）；int → I2F（隐式转换）
            if lt == TI_DEX_S { left_var = dex_scaled_to_bits(left_var, left); }
            else if lt == TI_INT {
                t1 := new_ir_var("_f0", TI_DEX);
                emit(IR_I2F, t1, left_var, 0, 0, TI_DEX);
                left_var = t1;
            }
            if rt == TI_DEX_S { right_var = dex_scaled_to_bits(right_var, right); }
            else if rt == TI_INT {
                t2 := new_ir_var("_f1", TI_DEX);
                emit(IR_I2F, t2, right_var, 0, 0, TI_DEX);
                right_var = t2;
            }
            v := new_ir_var("bin", fti);
            emit(IR_BINARY, v, left_var, right_var, op, fti);
            return v;
        }
        if lt == TI_DEX_S || rt == TI_DEX_S {
            fti = TI_DEX_S;
            // 精确路径操作数对齐：int → ×S（隐式缩放）；定点（TI_DEX_S）直接参与
            if lt == TI_INT { left_var = dex_scale_int(left_var); }
            if rt == TI_INT { right_var = dex_scale_int(right_var); }
            if op == OP_MUL {
                // (a×b)/S：先乘后缩回（中间值 a·b ≤ 9.2e18 → |值| ≤ 3.03e3 级，文档化）
                p := new_ir_var("_dxm", TI_DEX_S);
                emit(IR_BINARY, p, left_var, right_var, OP_MUL, TI_INT);
                c := new_ir_var("_dxs", TI_INT);
                emit(IR_CONST, c, 1000000, 0, 0, TI_INT);
                v := new_ir_var("bin", TI_DEX_S);
                emit(IR_BINARY, v, p, c, OP_DIV, TI_INT);
                return v;
            }
            if op == OP_DIV {
                // (a×S)/b：先放大再除（中间值 a·S ≤ 9.2e18 → |a| ≤ 9.2e6，向零截断）
                c := new_ir_var("_dxs", TI_INT);
                emit(IR_CONST, c, 1000000, 0, 0, TI_INT);
                t := new_ir_var("_dxn", TI_DEX_S);
                emit(IR_BINARY, t, left_var, c, OP_MUL, TI_INT);
                v := new_ir_var("bin", TI_DEX_S);
                emit(IR_BINARY, v, t, right_var, OP_DIV, TI_INT);
                return v;
            }
            if op == OP_MOD {
                // a mod b = a - trunc(a/b)·b（截断除法恒等式，缩放形式）
                c := new_ir_var("_dxs", TI_INT);
                emit(IR_CONST, c, 1000000, 0, 0, TI_INT);
                t1 := new_ir_var("_dxn", TI_DEX_S);
                emit(IR_BINARY, t1, left_var, c, OP_MUL, TI_INT);
                t2 := new_ir_var("_dxq", TI_DEX_S);
                emit(IR_BINARY, t2, t1, right_var, OP_DIV, TI_INT);
                t3 := new_ir_var("_dxi", TI_DEX_S);
                emit(IR_BINARY, t3, t2, c, OP_DIV, TI_INT);   // trunc(a/b)（纯整数）
                t4 := new_ir_var("_dxr", TI_DEX_S);
                emit(IR_BINARY, t4, t3, right_var, OP_MUL, TI_INT);
                v := new_ir_var("bin", TI_DEX_S);
                emit(IR_BINARY, v, left_var, t4, OP_SUB, TI_INT);
                return v;
            }
            if op == OP_EQ || op == OP_NE || op == OP_LT || op == OP_GT ||
               op == OP_LE || op == OP_GE {
                // 比较：缩放整数比较，结果 0/1（int——非 dex 值）
                v := new_ir_var("cmp", TI_INT);
                emit(IR_BINARY, v, left_var, right_var, op, TI_INT);
                return v;
            }
            // ADD/SUB 及余下：缩放整数直接运算
            v := new_ir_var("bin", TI_DEX_S);
            emit(IR_BINARY, v, left_var, right_var, op, TI_INT);
            return v;
        }
        v := new_ir_var("bin", fti);
        emit(IR_BINARY, v, left_var, right_var, op, fti);
        return v;
    }

    // Assignment
    if ast_kind(node) == EXPR_ASSIGN {
        target := ast_a(node);
        // Unwrap EXPR_NONE wrapper (added by checker/optimizer to
        // mark rewritten nodes). Without unwrapping, the target
        // checks below would miss wrapped UOP_DEREF or INDEX nodes.
        if ast_kind(target) == EXPR_NONE && ast_a(target) >= 0 {
            target = ast_a(target);
        }
        val_node := ast_b(node);
        val_var := gen_expr(val_node);
        val_var = force_if_thunk(val_var);
        if ast_kind(target) == EXPR_IDENT {
            name_idx := ast_int_val(target);
            lv := find_local(name_idx);
            if lv >= 0 {
                if irv_type(lv) == TI_DYN {
                    // Dyn variable assignment: pack value with type tag
                    tag := irv_type(val_var);
                    if tag < 0 { tag = TI_INT; }
                    emit(IR_DYN_PACK, lv, val_var, tag, 0, 0);
                } else {
                    val_var = dex_store_adjust(lv, val_var, val_node);
                     // F11：切片长度沿赋值传播（字面量/运行时界长度变量同步；源无记录则清除）
                     slice_len_copy_to(lv, val_var);
emit(IR_STORE, -1, lv, val_var, 0, 0);
                }
            } else {
                gv := find_global(name_idx);
                if gv >= 0 {
                    val_var = dex_store_adjust(gv, val_var, val_node);
                    emit(IR_STORE, -1, gv, val_var, 0, 0);
                }
            }
            return val_var;
        }
        if ast_kind(target) == EXPR_FIELD {
            obj_var := gen_expr(ast_a(target));
            obj_var = force_if_thunk(obj_var);
            fi := ast_data(target);
            emit(IR_STORE_FIELD, -1, obj_var, val_var, fi, 0);
            return val_var;
        }
        if ast_kind(target) == EXPR_INDEX {
            arr_var := gen_expr(ast_a(target));
            arr_var = force_if_thunk(arr_var);
            idx_node := ast_b(target);
            // F1：写路径越界守卫钩子（修复前完全没有——见 compcert-round4 F1）
            arr_len_lit : ., mut = arr_len_lit_of(arr_var);
            if ast_kind(idx_node) == EXPR_INT {
                emit_string_lit_bounds(arr_var, ast_int_val(idx_node));
                emit_slice_lit_bounds(arr_var, ast_int_val(idx_node));
                if pass_before_array_access(arr_var, -1, ast_int_val(idx_node), arr_len_lit) == 0 {
                    emit(IR_STORE_INDEX, -1, arr_var, val_var, ast_int_val(idx_node), 0);
                }
            } else {
                idx_var := gen_expr(idx_node);
                idx_var = force_if_thunk(idx_var);
                emit_slice_bounds(arr_var, idx_var);
                if pass_before_array_access(arr_var, idx_var, -1, arr_len_lit) == 0 {
                    emit(IR_STORE_INDEX_VAR, val_var, arr_var, idx_var, 0, 0);
                }
            }
            return val_var;
        }
        if ast_kind(target) == EXPR_UNARY && ast_c(target) == UOP_DEREF {
            ptr_var := gen_expr(ast_a(target));
            ptr_var = force_if_thunk(ptr_var);
            emit(IR_STORE_PTR, -1, ptr_var, val_var, 0, ptr_access_width(ptr_var));
            return val_var;
        }
        return val_var;
    }

    // Unary operation
    if ast_kind(node) == EXPR_UNARY {
        op := ast_c(node);
        if op == UOP_REF {
            inner := ast_a(node);
            // &arr[i]: compute address directly, don't load then take addr
            if ast_kind(inner) == EXPR_INDEX {
                arr_var := gen_expr(ast_a(inner));
                arr_var = force_if_thunk(arr_var);
                idx_var := gen_expr(ast_b(inner));
                idx_var = force_if_thunk(idx_var);
                elem_ti : ., mut = TI_INT;
                arr_ti := irv_type(arr_var);
                if arr_ti >= 0 {
                    arr_kind := get_type_kind(arr_ti);
                    if arr_kind == TYP_ARRAY || arr_kind == TYP_SLICE {
                        elem_ti = get_type_data(arr_ti);
                    }
                }
                v := new_ir_var("addr", alloc_type(TYP_PTR, elem_ti, 0));
                emit(IR_ADDR_INDEX, v, arr_var, idx_var, 3, 0);
                return v;
            }
            op_var := gen_expr(ast_a(node));
            op_var = force_if_thunk(op_var);
            v := new_ir_var("ref", alloc_type(TYP_PTR, irv_type(op_var), 0));
            emit(IR_REF, v, op_var, ast_int_val(node), 0, 0);
            return v;
        }
        if op == UOP_DEREF {
            inner_var := gen_expr(ast_a(node));
            inner_var = force_if_thunk(inner_var);
            dv := new_ir_var("deref", ptr_pointee_type(inner_var));
            emit(IR_DEREF, dv, inner_var, -1, 0, ptr_access_width(inner_var));
            return dv;
        }
        op_var := gen_expr(ast_a(node));
        op_var = force_if_thunk(op_var);
        vt : ., mut = TI_INT;
        if op == UOP_NEG {
            // 一元负保持数值操作数类型：dex 精确（TI_DEX_S）→ 缩放整数取负 ✓；
            // dex apx（TI_DEX）→ 整型取负（binary64 符号位翻转未实现——既有 apx
            // 限制，数值迁移 Task 4 文档化；apx 负值请用 0 - x 表达）
            ot := irv_type(op_var);
            if ot == TI_DEX_S || ot == TI_DEX || ot == TI_INT { vt = ot; }
        }
        v := new_ir_var("un", vt);
        emit(IR_UNARY, v, op_var, 0, op, 0);
        return v;
    }

    // Function call
    if ast_kind(node) == EXPR_GO {
        body := ast_b(node);
        range_node := ast_data(node);  // 0 = single, EXPR_RANGE node = range go
        if range_node <= 0 {
            // Single go: emit call to sched_go(@addr(f), arg)
            // sched_go creates a goroutine via g_new + sched_enqueue and returns a channel
            if ast_kind(body) == EXPR_CALL {
                func_node := ast_a(body);
                first_arg := ast_b(body);
                func_ni : ., mut = -1;
                if ast_kind(func_node) == EXPR_IDENT {
                    func_ni = ast_int_val(func_node);
                } else if ast_kind(func_node) == EXPR_FIELD {
                    func_ni = ast_data(body);
                }
                // Evaluate the first argument (if any)
                arg_var : ., mut = -1;
                if first_arg >= 0 {
                    arg_var = gen_expr(ast_a(first_arg));
                    arg_var = force_if_thunk(arg_var);
                }
                // Function address via IR_FNADDR — the movabs placeholder is
                // patched to the function's absolute VA at ELF link time
                // (elf.cr Phase 3). goroutine_entry_wrapper reads it back
                // from G+56 (saved_fn) and calls saved_fn(saved_arg).
                fnaddr_var := new_ir_var("_go_fnaddr", TI_INT);
                emit(IR_FNADDR, fnaddr_var, func_ni, 0, 0, 0);
                // Create contiguous argument variables for the sched_go call:
                // arg0 = fn address, arg1 = arg value (0 when no arg)
                packed0 := new_ir_var("_go_fna", TI_INT);
                emit(IR_STORE, -1, packed0, fnaddr_var, 0, 0);
                packed1 := new_ir_var("_go_arg", TI_INT);
                if arg_var >= 0 {
                    emit(IR_STORE, -1, packed1, arg_var, 0, 0);
                } else {
                    emit(IR_CONST, packed1, 0, 0, 0, TI_INT);
                }
                dest := new_ir_var("_go_ch", TI_INT);
                sched_go_ni := str_intern("sched_go");
                emit(IR_CALL, dest, packed0, 2, sched_go_ni, TI_INT);
                return dest;
            }
            return gen_expr(body);
        }
        // Range go: go var start..end expr → collect results into array
        iter_ni := ast_c(node);  // loop variable name
        range_count := ast_b(range_node) - ast_a(range_node);
        if range_count <= 0 { return -1; }
        // Allocate results array
        arr_var := new_ir_var("go_arr", TI_UNIT);
        emit(IR_ALLOC_ARRAY, arr_var, range_count, 0, 0, 0);
        // Spawn each iteration
        if ast_kind(body) == EXPR_CALL {
            func_node := ast_a(body);
            func_ni : ., mut = -1;
            if ast_kind(func_node) == EXPR_IDENT { func_ni = ast_int_val(func_node); }
            // Extract the call arg that uses the iter variable
            fi : ., mut = 0;
            loop { if fi >= range_count { break; }
                // For each i, spawn with i as the iter var's value
                val_var := new_ir_var("go_val", TI_UNIT);
                emit(IR_CONST, val_var, ast_a(range_node) + fi, 0, 0, TI_INT);
                dest2 := new_ir_var("go_fut", TI_UNIT);
                emit(IR_SPAWN, dest2, val_var, 1, func_ni, -1);
                emit(IR_STORE_INDEX, -1, arr_var, dest2, fi, 0);
            fi = fi + 1; }
        }
        return arr_var;
    }

    if ast_kind(node) == EXPR_CALL {
        func_node := ast_a(node);
        first_arg := ast_b(node);
        arg_count := ast_c(node);
        call_flags := ast_type_val(node);
        is_module_call := call_flags == CALL_FLAG_MODULE || call_flags == CALL_FLAG_MODULE + CALL_FLAG_INLINE;
        is_inline_call := call_flags == CALL_FLAG_INLINE || call_flags == CALL_FLAG_MODULE + CALL_FLAG_INLINE;
        arg_vars : string, mut;    arg_vars_cap : int, mut;
        ac : ., mut = 0;
    arg_vars = alloc(64 * 8); arg_vars_cap = 64;
        func_ni : ., mut = -1;

        // @builtin(args) — parser wraps @foo(args) as EXPR_CALL(func=EXPR_AT, ...)
        // so we detect EXPR_AT here and handle it before the normal call dispatch.
        if ast_kind(func_node) == EXPR_AT {
            name_ni := ast_a(func_node);
            name := istr_get(name_ni);

            // @sizeOf(T): emit IR_CONST with type size
            if str_eq(name, "sizeOf") != 0 {
                ti := ti_from_type_expr(ast_a(first_arg));
                sz := type_size(ti);
                v := new_ir_var("_sizeof", TI_INT);
                emit(IR_CONST, v, sz, 0, 0, TI_INT);
                return v;
            }

            // @alignOf(T): emit IR_CONST with type alignment
            if str_eq(name, "alignOf") != 0 {
                ti := ti_from_type_expr(ast_a(first_arg));
                al := type_align(ti);
                v := new_ir_var("_alignof", TI_INT);
                emit(IR_CONST, v, al, 0, 0, TI_INT);
                return v;
            }

            // @fields(T): emit string array of field names
            if str_eq(name, "fields") != 0 {
                ti := ti_from_type_expr(ast_a(first_arg));
                si := ti_resolve_struct(ti);
                v := new_ir_var("_fields", TI_STR);
                if si >= 0 {
                    fc := si_field_count(si);
                    // Build a string constant: comma-separated field names
                    fields_str : ., mut = "";
                    fi : ., mut = 0;
                    loop {
                        if fi >= fc { break; }
                        fname := istr_get(si_field_name(si, fi));
                        if fi > 0 { fields_str = fields_str + ","; }
                        fields_str = fields_str + fname;
                        fi = fi + 1;
                    }
                    ni := str_intern(fields_str);
                    track_str(ni);
                    emit(IR_CONST, v, ni, 0, 0, TI_STR);
                } else {
                    emit(IR_CONST, v, 0, 0, 0, TI_STR);
                }
                return v;
            }

            // @hasField(T, name): check field existence
            if str_eq(name, "hasField") != 0 {
                ti := ti_from_type_expr(ast_a(first_arg));
                name_arg := ast_b(first_arg);
                name_expr := ast_a(name_arg);
                fn_name := istr_get(ast_int_val(name_expr));
                exists := ti_has_field(ti, fn_name);
                v := new_ir_var("_hasf", TI_BOOL);
                emit(IR_CONST, v, exists, 0, 0, TI_BOOL);
                return v;
            }

            // @field(T, name): get field offset
            if str_eq(name, "field") != 0 {
                ti := ti_from_type_expr(ast_a(first_arg));
                name_arg := ast_b(first_arg);
                name_expr := ast_a(name_arg);
                fn_name := istr_get(ast_int_val(name_expr));
                off := ti_field_offset(ti, fn_name);
                v := new_ir_var("_fldoff", TI_INT);
                emit(IR_CONST, v, off, 0, 0, TI_INT);
                return v;
            }

            // @typeInfo(T): emit type description string
            if str_eq(name, "typeInfo") != 0 {
                ti := ti_from_type_expr(ast_a(first_arg));
                type_str : ., mut = "";
                k := get_type_kind(ti);
                if k == TYP_NAMED {
                    name_ni := get_type_data(ti);
                    type_str = istr_get(name_ni);
                } else if ti == TI_INT { type_str = "int"; }
                else if ti == TI_BOOL { type_str = "bool"; }
                else if ti == TI_DEX || ti == TI_DEX_S { type_str = "dex"; }
                else if ti == TI_STR { type_str = "string"; }
                else if ti == TI_CHAR { type_str = "char"; }
                else if ti == TI_UNIT { type_str = "unit"; }
                else { type_str = "unknown"; }
                ni := str_intern(type_str);
                track_str(ni);
                v := new_ir_var("_tinfo", TI_STR);
                emit(IR_CONST, v, ni, 0, 0, TI_STR);
                return v;
            }

            // @raw_int(expr): 显式转换——dex 表达式 → 其定点缩放整数原值（int）。
            // 数值迁移 Task 4：dex.cr 的打印等辅助以此访问缩放表示的原始整数；
            // apx 值（TI_DEX bits）先按边界规则转 scaled（F2I(bits×S)）。
            // 结果必须复制为 TI_INT 定型变量——直接返回内层变量会携带其 dex 类型
            // （TI_DEX_S），后续 int 运算被误分派到 dex 精确路径。
            if str_eq(name, "raw_int") != 0 {
                inner_var := gen_expr(ast_a(first_arg));
                inner_var = force_if_thunk(inner_var);
                if irv_type(inner_var) == TI_DEX {
                    inner_var = dex_bits_to_scaled(inner_var);
                }
                rv := new_ir_var("_raw", TI_INT);
                emit(IR_STORE, -1, rv, inner_var, 0, 0);
                return rv;
            }

            // @comptime(expr): force compile-time evaluation
            if str_eq(name, "comptime") != 0 {
                inner_expr := ast_a(first_arg);
                // Generate IR for the inner expression
                inner_var := gen_expr(inner_expr);
                inner_var = force_if_thunk(inner_var);
                // If the inner expression is a constant, it's already folded.
                // For runtime-dependent exprs, we'd need the interpreter.
                // For now: gen IR and return — the existing constant folding
                // (inline IR_CONST from @sizeOf etc.) handles pure compile-time exprs.
                // Future: invoke ir_interpret_expr for true forced evaluation.
                return inner_var;
            }

            // @inline(fn): emit IR_INLINE hint
            if str_eq(name, "inline") != 0 {
                fn_var := gen_expr(ast_a(first_arg));
                fn_var = force_if_thunk(fn_var);
                emit(IR_INLINE, -1, fn_var, 0, 0, 0);
                return fn_var;
            }

            // @no_bounds_check: emit annotation (no args)
            if str_eq(name, "no_bounds_check") != 0 {
                emit(IR_NO_BOUNDS_CHECK, -1, 0, 0, 0, 0);
                return -1;
            }

            // @fast: emit annotation (no args)
            if str_eq(name, "fast") != 0 {
                emit(IR_FAST, -1, 0, 0, 0, 0);
                return -1;
            }

            // @unroll(n): emit loop unroll hint
            if str_eq(name, "unroll") != 0 {
                unroll_count := ast_int_val(ast_a(first_arg));
                emit(IR_UNROLL, -1, unroll_count, 0, 0, 0);
                return -1;
            }

            // @section(name): emit code section hint
            if str_eq(name, "section") != 0 {
                name_expr := ast_a(ast_a(first_arg));
                name_ni := ast_int_val(name_expr);
                track_str(name_ni);
                emit(IR_SECTION, -1, name_ni, 0, 0, 0);
                return -1;
            }

            // @addr(fn): get function address (patched at ELF link time)
            if str_eq(name, "addr") != 0 {
                fn_expr := ast_a(first_arg);
                if ast_kind(fn_expr) == EXPR_IDENT {
                    fn_ni := ast_int_val(fn_expr);
                    v := new_ir_var("_fnaddr", TI_INT);
                    emit(IR_FNADDR, v, fn_ni, 0, 0, 0);
                    return v;
                }
                return -1;
            }

            return -1;
        }

        // Module or method call: obj.method(args)
        if ast_kind(func_node) == EXPR_FIELD {
            func_ni = ast_data(node); // function name (set by checker for module calls)
            if !is_module_call {
                // Method call: self is first arg
                obj_node := ast_a(func_node);
                self_var := gen_expr(obj_node);
                self_var = force_if_thunk(self_var);
                if ac >= arg_vars_cap { nc := arg_vars_cap * 2; nb := alloc(nc * 8); _dyncpy(arg_vars, arg_vars_cap * 8, nb); arg_vars = nb; arg_vars_cap = nc; } w64(arg_vars, ac * 8, self_var);
                ac = ac + 1;
            }
        } else if ast_kind(func_node) == EXPR_IDENT {
            func_ni = ast_int_val(func_node);
        }

        // Generate remaining args (walk EXPR_ARG chain)
        an : ., mut = first_arg;
        loop {
            if an < 0 { break; }
            arg_var := gen_expr(ast_a(an));
            arg_var = force_if_thunk(arg_var);
            if ac >= arg_vars_cap { nc := arg_vars_cap * 2; nb := alloc(nc * 8); _dyncpy(arg_vars, arg_vars_cap * 8, nb); arg_vars = nb; arg_vars_cap = nc; } w64(arg_vars, ac * 8, arg_var);
            ac = ac + 1;
            an = ast_b(an);
        }
        // dex 边界规则（数值迁移 Task 4 + 终审 M2）：dex 参数在调用点按被调方形式对齐——
        //   Core 函数：一律精确形式（scaled），apx 位模式参数转 scaled（F2I(bits×S)）；
        //   extern 函数：C ABI 契约（module.cr：dex 编码 3 = binary64 跨 C 边界），
        //     精确形式（scaled）实参转 binary64 bits（I2F/S——字面量重发射位模式常量）
        if func_ni >= 0 && ast_kind(func_node) == EXPR_IDENT {
            cfi := find_func(func_ni);
            if cfi >= 0 {
                cfn := fi_ast_node(cfi);
                cfn_ext : ., mut = 0;
                if cfn >= 0 && ast_kind(cfn) == EXPR_EXTERN { cfn_ext = 1; }
                if cfn >= 0 && (cfn_ext != 0 || ast_kind(cfn) == EXPR_FN) {
                    cpi : ., mut = 0;
                    cpn : ., mut = ast_b(cfn);
                    an2 : ., mut = first_arg;  // 并行走 EXPR_ARG 链取实参节点（字面量重发射）
                    loop {
                        if cpi >= ac { break; }
                        if cpn < 0 { break; }
                        if ast_type_val(cpn) == TI_DEX {
                            av := r64(arg_vars, cpi * 8);
                            if av >= 0 {
                                if cfn_ext != 0 {
                                    // extern：scaled → bits（字面量直接重发射位模式常量）
                                    if irv_type(av) == TI_DEX_S {
                                        arg_node : ., mut = -1;
                                        if an2 >= 0 { arg_node = ast_a(an2); }
                                        av = dex_scaled_to_bits(av, arg_node);
                                        w64(arg_vars, cpi * 8, av);
                                    }
                                } else if irv_type(av) == TI_DEX {
                                    // Core 函数：apx bits → scaled
                                    av = dex_bits_to_scaled(av);
                                    w64(arg_vars, cpi * 8, av);
                                }
                            }
                        }
                        cpi = cpi + 1;
                        if an2 >= 0 { an2 = ast_b(an2); }
                        cpn = cpn + 1;
                        loop {
                            if cpn >= g_ast_count { break; }
                            if ast_kind(cpn) == EXPR_PARAM { break; }
                            cpn = cpn + 1;
                        }
                    }
                }
            }
        }
        // Generic function: redirect to monomorphized (specialized) version
        if func_ni >= 0 && (ast_kind(func_node) == EXPR_IDENT) {
            gen_fi := find_func(func_ni);
            if gen_fi >= 0 && fi_generic_count(gen_fi) > 0 {
                // Build type args string from call argument types
                type_args : ., mut = "";
                ai : ., mut = 0;
                loop {
                    if ai >= ac { break; }
                    av := r64(arg_vars, ai * 8);
                    ti := TI_INT;
                    if av >= 0 { ti = irv_type(av); }
                    if ai > 0 { type_args = type_args + ","; }
                    if ti == TI_INT { type_args = type_args + "int"; }
                    else if ti == TI_STR { type_args = type_args + "string"; }
                    else if ti == TI_BOOL { type_args = type_args + "bool"; }
                    else if ti == TI_CHAR { type_args = type_args + "char"; }
                    else if ti == TI_DEX || ti == TI_DEX_S { type_args = type_args + "dex"; }
                    else if ti == TI_UNIT { type_args = type_args + "unit"; }
                    else { type_args = type_args + "int"; }
                    ai = ai + 1;
                }
                // Find or create specialized function instance
                spec_ni := gen_find_or_create(gen_fi, type_args);
                if spec_ni >= 0 {
                    func_ni = fi_name(spec_ni);
                    // Fall through to normal IR_CALL emission
                }
            }
        }
        if is_inline_call && func_ni >= 0 {
            emit(IR_INLINE, -1, func_ni, 0, 0, 0);
        }
        // Check SO function dispatch (variadic expansion, auto_str, etc.)
        handled := dispatch_call(func_ni, ac, arg_vars);
        if handled >= 0 { return handled; }

        // For method calls (EXPR_FIELD), func_ni was set by checker
        // Use it directly
        call_ti := ir_call_return_type(func_ni);
        dest := new_ir_var("call", call_ti);
        first_arg_var := -1;
        need_pack : ., mut = 0;
        if ac > 0 {
            prev := r64(arg_vars, 0 * 8);
            first_arg_var = prev;
            ai : ., mut = 1;
            loop {
                if ai >= ac { break; }
                cur := r64(arg_vars, ai * 8);
                if cur != prev + 1 { need_pack = 1; break; }
                prev = cur;
                ai = ai + 1;
            }
        }
        if need_pack != 0 {
            ai : ., mut = 0;
            loop {
                if ai >= ac { break; }
                av := r64(arg_vars, ai * 8);
                at := TI_INT;
                if av >= 0 { at = irv_type(av); }
                packed := new_ir_var("_arg", at);
                if ai == 0 { first_arg_var = packed; }
                emit(IR_STORE, -1, packed, av, 0, 0);
                ai = ai + 1;
            }
        }
        // Dyn method dispatch: receiver is a dyn value, emit dynamic dispatch
        if ast_kind(func_node) == EXPR_FIELD && ac > 0 && func_ni >= 0 {
            dyn_receiver := first_arg_var;
            if dyn_receiver >= 0 && irv_type(dyn_receiver) == TI_DYN {
                dyn_dest := new_ir_var("_dyncall", TI_UNIT);
                emit(IR_DYN_DISPATCH, dyn_dest, dyn_receiver, func_ni, 0, 0);
                return dyn_dest;
            }
        }

        // Hotpatch function call: emit IR_HOTPATCH_ROUTE instead of IR_CALL
        if func_ni >= 0 && is_hotpatch_func(func_ni) != 0 {
            emit(IR_HOTPATCH_ROUTE, dest, func_ni, first_arg_var, ac);
            return dest;
        }
        // Extern function call: emit IR_CALL_EXTERN for FFI dispatch
        if func_ni >= 0 {
            fi := find_func(func_ni);
            if fi >= 0 {
                fn_node := fi_ast_node(fi);
                if fn_node >= 0 && ast_kind(fn_node) == EXPR_EXTERN {
                    emit(IR_CALL_EXTERN, dest, func_ni, first_arg_var, ac, 0);
                    return dest;
                }
            }
        }
        emit(IR_CALL, dest, first_arg_var, ac, func_ni, call_ti);
        // Lazy thunk: if calling a pure function with single use, wrap as thunk
        if func_ni >= 0 {
            call_fi := find_func(func_ni);
            if call_fi >= 0 && fi_ispure(call_fi) != 0 {
                grow_var_use_count(dest + 1);
                use_count := r64(g_var_use_count, dest * 8);
                if use_count <= 1 {
                    thunk_var := new_ir_var("_lazy", irv_type(dest));
                    emit(IR_LAZY_THUNK, thunk_var, dest, 0, 0, 0);
                    return thunk_var;
                }
            }
        }
        return dest;
    }

    // Block
    if ast_kind(node) == EXPR_BLOCK {
        stmt_start := ast_a(node);
        stmt_count := ast_b(node);
        last : ., mut = -1;
        push_ir_scope();
        i : ., mut = 0;
        loop {
            if i >= stmt_count { break; }
            sn := r64(g_block_stmts, (stmt_start + i) * 8);
            last = gen_expr(sn);
            i = i + 1;
        }
        pop_ir_scope();
        return last;
    }

    // If expression
    if ast_kind(node) == EXPR_IF {
        sg_push(SG_IF);  // conditional region: covers [condition, merge)
        cond := ast_a(node);
        then_node := ast_b(node);
        else_node := ast_c(node);
        cond_var := gen_expr(cond);
        cond_var = force_if_thunk(cond_var);
        then_lbl := new_label();
        else_lbl := new_label();
        merge_lbl := new_label();
        if else_node >= 0 {
            emit(IR_BRANCH, -1, cond_var, then_lbl, else_lbl, 0);
        } else {
            emit(IR_BRANCH, -1, cond_var, then_lbl, merge_lbl, 0);
        }
        emit(IR_LABEL, -1, then_lbl, 0, 0, 0);
        gen_expr(then_node);
        emit(IR_JUMP, -1, merge_lbl, 0, 0, 0);
        if else_node >= 0 {
            emit(IR_LABEL, -1, else_lbl, 0, 0, 0);
            gen_expr(else_node);
            emit(IR_JUMP, -1, merge_lbl, 0, 0, 0);
        }
        emit(IR_LABEL, -1, merge_lbl, 0, 0, 0);
        sg_pop();
        return -1;
    }

    // Loop
    if ast_kind(node) == EXPR_LOOP {
        header_lbl := new_label();
        body_lbl := new_label();
        exit_lbl := new_label();
        emit(IR_JUMP, -1, header_lbl, 0, 0, 0);
        // SG_LOOP region covers [header, exit) — the back-edge jump to the
        // header lands on the region enter (region iteration in interp.cr).
        sg_alloc_push(SG_LOOP);
        arena_var := new_ir_var("_arena", TI_INT);
        w64(g_sg_arena_var, (g_sg_count - 1) * 8, arena_var);
        emit(IR_LABEL, -1, header_lbl, 0, 0, 0);
        emit(IR_JUMP, -1, body_lbl, 0, 0, 0);
        emit(IR_LABEL, -1, body_lbl, 0, 0, 0);
        emit(IR_ARENA_NEW, arena_var, 0, 0, 0, 0);
        arena_instr := g_ir_instr_count - 1;
        push_ir_scope();
        // `continue` must jump to the post label (not the header) so the
        // arena reset runs on the continue path too — symmetric with `for`.
        post_lbl := new_label();
        push_loop_labels(post_lbl, exit_lbl);
        gen_expr(ast_a(node));
        pop_loop_labels();
        pop_ir_scope();
        total := r64(g_sg_alloc_total, g_sg_count - 1);
        if total > 0 { iri_set_s1(arena_instr, total); }
        emit(IR_LABEL, -1, post_lbl, 0, 0, 0);
        emit(IR_ARENA_RESET, -1, arena_var, 0, 0, 0);  // arena reused per iteration
        emit(IR_JUMP, -1, header_lbl, 0, 0, 0);
        emit(IR_LABEL, -1, exit_lbl, 0, 0, 0);
        sg_pop();  // close loop region (arena already reset above)
        return -1;
    }

    // While loop
    if ast_kind(node) == EXPR_WHILE {
        cond := ast_a(node);
        body := ast_b(node);
        header_lbl := new_label();
        body_lbl := new_label();
        exit_lbl := new_label();
        // Keep while loops on the same SG_LOOP protocol as loop/for: the
        // region owns the condition, body, back-edge, and exit label so sg_pop
        // can add the termination dependency and advance the state chain.
        sg_push(SG_LOOP);
        arena_var := new_ir_var("_arena", TI_INT);
        w64(g_sg_arena_var, (g_sg_count - 1) * 8, arena_var);
        emit(IR_LABEL, -1, header_lbl, 0, 0, 0);
        cond_var := gen_expr(cond);
        cond_var = force_if_thunk(cond_var);
        emit(IR_BRANCH, -1, cond_var, body_lbl, exit_lbl, 0);
        emit(IR_LABEL, -1, body_lbl, 0, 0, 0);
        emit(IR_ARENA_NEW, arena_var, 0, 0, 0, 0);
        arena_instr := g_ir_instr_count - 1;
        push_ir_scope();
        // Continue must pass through the reset point before rechecking cond.
        post_lbl := new_label();
        push_loop_labels(post_lbl, exit_lbl);
        gen_expr(body);
        pop_loop_labels();
        pop_ir_scope();
        total := r64(g_sg_alloc_total, g_sg_count - 1);
        if total > 0 { iri_set_s1(arena_instr, total); }
        emit(IR_LABEL, -1, post_lbl, 0, 0, 0);
        emit(IR_ARENA_RESET, -1, arena_var, 0, 0, 0);
        emit(IR_JUMP, -1, header_lbl, 0, 0, 0);
        emit(IR_LABEL, -1, exit_lbl, 0, 0, 0);
        sg_pop();  // close loop region (arena already reset above)
        return -1;
    }

    // For loop: for var in start..end { body }
    if ast_kind(node) == EXPR_FOR {
        var_ni := ast_a(node);
        iter := ast_b(node);
        body := ast_c(node);
        start_var := -1;
        end_var := -1;
        if ast_kind(iter) == EXPR_RANGE {
            start_var = gen_expr(ast_a(iter));
            start_var = force_if_thunk(start_var);
            end_var = gen_expr(ast_b(iter));
            end_var = force_if_thunk(end_var);
        } else {
            // Non-range iterable: evaluate and use 0..iter
            s := new_ir_var("start", TI_INT);
            emit(IR_CONST, s, 0, 0, 0, TI_INT);
            start_var = s;
            end_var = gen_expr(iter);
            end_var = force_if_thunk(end_var);
        }
        // Create loop variable, init to start
        ivar := new_ir_var("for_i", TI_INT);
        emit(IR_ALLOC, ivar, 0, 0, 0, TI_INT);
        emit(IR_STORE, -1, ivar, start_var, 0, 0);
        bind_local(var_ni, ivar);
        header_lbl := new_label();
        body_lbl := new_label();
        exit_lbl := new_label();
        // The SG_FOR region covers [header, exit): the back-edge jump to the
        // header is then a jump to the region enter, so the interpreter can
        // drive loop iteration from region boundaries (region iteration).
        sg_alloc_push(SG_FOR);
        arena_var := new_ir_var("_arena", TI_INT);
        w64(g_sg_arena_var, (g_sg_count - 1) * 8, arena_var);
        // Header: check ivar < end, branch to exit if false
        emit(IR_LABEL, -1, header_lbl, 0, 0, 0);
        cond_var := new_ir_var("for_cond", TI_INT);
        emit(IR_BINARY, cond_var, ivar, end_var, OP_LT, 0);
        emit(IR_BRANCH, -1, cond_var, body_lbl, exit_lbl, 0);
        // Body
        emit(IR_LABEL, -1, body_lbl, 0, 0, 0);
        emit(IR_ARENA_NEW, arena_var, 0, 0, 0, 0);
        arena_instr := g_ir_instr_count - 1;
        push_ir_scope();
        // `continue` must jump to the post (increment) label, not the header —
        // otherwise the loop variable never advances and the loop spins.
        post_lbl := new_label();
        push_loop_labels(post_lbl, exit_lbl);
        gen_expr(body);
        pop_loop_labels();
        pop_ir_scope();
        total := r64(g_sg_alloc_total, g_sg_count - 1);
        if total > 0 { iri_set_s1(arena_instr, total); }
        // Increment ivar and jump to header (arena reset runs on every path,
        // including the continue path, so per-iteration memory is reused)
        emit(IR_LABEL, -1, post_lbl, 0, 0, 0);
        emit(IR_ARENA_RESET, -1, arena_var, 0, 0, 0);
        one_var := new_ir_var("one", TI_INT);
        emit(IR_CONST, one_var, 1, 0, 0, TI_INT);
        inc_var := new_ir_var("inc", TI_INT);
        emit(IR_BINARY, inc_var, ivar, one_var, OP_ADD, 0);
        emit(IR_STORE, -1, ivar, inc_var, 0, 0);
        emit(IR_JUMP, -1, header_lbl, 0, 0, 0);
        // Exit
        emit(IR_LABEL, -1, exit_lbl, 0, 0, 0);
        sg_pop();  // close loop region (arena already reset above)
        return -1;
    }

    // Match expression
    if ast_kind(node) == EXPR_MATCH {
        match_expr := ast_a(node);
        first_arm := ast_b(node);
        match_val := gen_expr(match_expr);
        match_val = force_if_thunk(match_val);
        // Allocate a result variable for the match expression value
        result_var := new_ir_var("match_res", TI_INT);
        emit(IR_ALLOC, result_var, 0, 0, 0, TI_INT);
        merge_lbl := new_label();
        an : ., mut = first_arm;
        loop {
            if an < 0 { break; }
            arm_pat := ast_a(an);
            arm_body := ast_b(an);
            pat_kind := -1;
            if arm_pat >= 0 { pat_kind = ast_kind(arm_pat); }
            is_wildcard := 0;
            if pat_kind == EXPR_WILDCARD { is_wildcard = 1; }
            body_lbl := new_label();
            fall_lbl : ., mut = merge_lbl;
            has_next := 0;
            if ast_c(an) >= 0 { has_next = 1; }
            if is_wildcard == 1 {
                emit(IR_JUMP, -1, body_lbl, 0, 0, 0);
            } else if pat_kind == EXPR_ENUMPAT {
                variant_ni := get_variant_name_idx(ast_a(arm_pat));
                tag_var := new_ir_var("tag", TI_INT);
                emit(IR_LOAD_ENUM_TAG, tag_var, match_val, 0, 0, 0);
                vtag := new_ir_var("vtag", TI_INT);
                emit(IR_CONST, vtag, variant_ni, 0, 0, TI_INT);
                cmp_var := new_ir_var("cmp", TI_INT);
                emit(IR_BINARY, cmp_var, tag_var, vtag, OP_EQ, 0);
                if has_next == 1 { fall_lbl = new_label(); }
                emit(IR_BRANCH, -1, cmp_var, body_lbl, fall_lbl, 0);
            } else if pat_kind == EXPR_INT {
                pat_val := new_ir_var("pval", TI_INT);
                emit(IR_CONST, pat_val, ast_int_val(arm_pat), 0, 0, TI_INT);
                cmp_var := new_ir_var("cmp", TI_INT);
                emit(IR_BINARY, cmp_var, match_val, pat_val, OP_EQ, 0);
                if has_next == 1 { fall_lbl = new_label(); }
                emit(IR_BRANCH, -1, cmp_var, body_lbl, fall_lbl, 0);
            } else if pat_kind == EXPR_BOOL {
                pat_val := new_ir_var("pval", TI_INT);
                pat_bool : ., mut = 0;
                if ast_int_val(arm_pat) != 0 { pat_bool = 1; }
                emit(IR_CONST, pat_val, pat_bool, 0, 0, TI_INT);
                cmp_var := new_ir_var("cmp", TI_INT);
                emit(IR_BINARY, cmp_var, match_val, pat_val, OP_EQ, 0);
                if has_next == 1 { fall_lbl = new_label(); }
                emit(IR_BRANCH, -1, cmp_var, body_lbl, fall_lbl, 0);
            }
            emit(IR_LABEL, -1, body_lbl, 0, 0, 0);
            push_ir_scope();
            if pat_kind == EXPR_ENUMPAT {
                sub_count := ast_c(arm_pat);
                fi : ., mut = 0;
                loop {
                    if fi >= sub_count { break; }
                    fv := new_ir_var("fld", TI_INT);
                    emit(IR_LOAD_FIELD, fv, match_val, 0, fi + 1, 0);  // +1 for tag offset
                    spn := ast_b(arm_pat) + fi;
                    if spn >= 0 && ast_kind(spn) == EXPR_IDENT {
                        bind_local(ast_int_val(spn), fv);
                    }
                    fi = fi + 1;
                }
            }
            body_val := gen_expr(arm_body);
            body_val = force_if_thunk(body_val);
            if body_val >= 0 {
                emit(IR_STORE, -1, result_var, body_val, 0, 0);
            }
            pop_ir_scope();
            emit(IR_JUMP, -1, merge_lbl, 0, 0, 0);
            if is_wildcard == 0 {
                if has_next == 1 {
                    emit(IR_LABEL, -1, fall_lbl, 0, 0, 0);
                }
            }
            an = ast_c(an);
        }
        emit(IR_LABEL, -1, merge_lbl, 0, 0, 0);
        return result_var;
    }

    // Let binding
    if ast_kind(node) == EXPR_LET {
        var_ni := ast_a(node);
        type_node := ast_b(node);
        val_node := ast_c(node);
        is_apx := ast_int_val(node);  // apx 标签位（parser 存入 iv 字段）
        // Detect dyn variable (type annotation is `dyn`)
        is_dyn_var : ., mut = 0;
        if type_node >= 0 && ast_kind(type_node) == 0 && ast_type_val(type_node) == TI_DYN {
            is_dyn_var = 1;
        }
        var := new_ir_var(istr_get(var_ni), TI_UNIT);
        declared_ti : ., mut = TI_UNIT;
        if type_node >= 0 { declared_ti = res_type_node(type_node); }
        // `dex` is the source-level type; its IR slot has two forms. Only an
        // explicitly tagged `apx` declaration uses binary64 bits.
        target_ti : ., mut = declared_ti;
        if declared_ti == TI_DEX {
            if is_apx != 0 { target_ti = TI_DEX; }
            else { target_ti = TI_DEX_S; }
            irv_set_type(var, target_ti);
        }
        is_arr : ., mut = 0;
        if type_node >= 0 && val_node < 0 {
            if ast_kind(type_node) == 19 {
                sz := ast_int_val(type_node);
                if sz > 0 {
                    emit(IR_ALLOC_ARRAY, var, sz, 8, 0, 0); is_arr = 1;
                    // F1：记录数组类型（TYP_ARRAY extra=size）——直接索引越界
                    // 检查（arr_len_lit_of）依赖该长度信息。
                    irv_set_type(var, res_type_node(type_node));
                }
            }
        }
        // For dyn vars with initializer: skip allocation (value is packed below)
        if is_dyn_var == 0 || val_node < 0 {
            if is_arr == 0 { emit(IR_ALLOC, var, 0, 0, 0, TI_UNIT); }
        }
        if val_node >= 0 {
            val_var := gen_expr(val_node);
            val_var = force_if_thunk(val_var);
            // An `apx` dex local stores binary64 bits, unlike the default
            // scaled-integer dex form. The annotation alone is not enough:
            // switch the slot type and convert the initializer before later
            // binary operations inspect its type.
            if declared_ti == TI_DEX {
                val_var = dex_store_adjust(var, val_var, val_node);
            } else if declared_ti == TI_UNIT {
                target_ti = irv_type(val_var);
                irv_set_type(var, target_ti);
            }
            if is_dyn_var != 0 {
                // Dyn variable: pack value with its type tag
                dyn_var := new_ir_var("_dyn", TI_DYN);
                tag := irv_type(val_var);
                if tag < 0 { tag = TI_INT; }
                emit(IR_DYN_PACK, dyn_var, val_var, tag, 0, 0);
                bind_local(var_ni, dyn_var);
                if is_apx != 0 { emit(IR_APPROX, -1, 0, 0, 0, 0); }
                return dyn_var;
            }
             // Preserve the initializer type so later operations can select
             // type-specific lowering (notably string + -> concat()).
              if declared_ti != TI_DEX {
                  irv_set_type(var, irv_type(val_var));
              }
            // F11：切片长度沿 LET 初始化传播（s := arr[0..2] → s 带长度 2；
            // 运行时界 slice 同步长度变量——slice_len_copy_to）
            slice_len_copy_to(var, val_var);
            emit(IR_STORE, -1, var, val_var, 0, 0);
        }
        bind_local(var_ni, var);
        if is_apx != 0 { emit(IR_APPROX, -1, 0, 0, 0, 0); }
        return var;
    }

    // Return
    if ast_kind(node) == EXPR_YIELD {
        val_node := ast_a(node);
        val_var : ., mut = -1;
        if val_node >= 0 { val_var = gen_expr(val_node); val_var = force_if_thunk(val_var); }
        emit(IR_YIELD, -1, val_var, 0, 0, 0);
        return -1;  // yield suspends — no return value for caller
    }

    if ast_kind(node) == EXPR_AWAIT {
        val_node := ast_a(node);
        val_var := gen_expr(val_node);
        val_var = force_if_thunk(val_var);
        dest := new_ir_var("await", TI_UNIT);
        emit(IR_AWAIT, dest, val_var, 0, 0, 0);
        return dest;
    }

    if ast_kind(node) == EXPR_RETURN {
        if ast_a(node) >= 0 {
            val_var := gen_expr(ast_a(node));
            val_var = force_if_thunk(val_var);
            // dex 边界规则（数值迁移 Task 4）：函数返回一律精确形式（缩放整数）——
            // apx 位模式在返回点转 scaled（F2I(bits×S)，按定点 6 位舍入）
            if g_cur_ret_ti == TI_DEX && irv_type(val_var) == TI_DEX {
                val_var = dex_bits_to_scaled(val_var);
            }
            emit(IR_RETURN, -1, val_var, 0, 0, 0);
        } else {
            emit(IR_RETURN, -1, -1, 0, 0, 0);
        }
        return -1;
    }

    // Field access
    if ast_kind(node) == EXPR_FIELD {
        obj_var := gen_expr(ast_a(node));
        obj_var = force_if_thunk(obj_var);
        v := new_ir_var("field", TI_INT);
        fi : ., mut = ast_type_val(node);
        if fi > 0 {
            fi = fi - 1;  // numeric tuple index (parser stored +1)
        } else {
            fi = ast_data(node);   // struct field index (from checker)
        }
        emit(IR_LOAD_FIELD, v, obj_var, 0, fi, 0);
        return v;
    }

    // Index
    if ast_kind(node) == EXPR_INDEX {
        arr_var := gen_expr(ast_a(node));
        arr_var = force_if_thunk(arr_var);
        idx_node := ast_b(node);
        idx_kind := ast_kind(idx_node);
        arr_len_lit : ., mut = arr_len_lit_of(arr_var);
        // Range index: arr[low..high] → slice (pointer to arr[low])
        if idx_kind == EXPR_RANGE {
            low_node := ast_a(idx_node);
            high_node := ast_b(idx_node);
            low_var := gen_expr(low_node);
            low_var = force_if_thunk(low_var);
            high_var := gen_expr(high_node);
            high_var = force_if_thunk(high_var);
            // F11：创建期守卫——high ≤ arr_len、low ≤ arr_len（low ≤ high 的
            // 运行时检查需切片运行时长度，见报告设计缺口；字面量界由 checker 拦截）。
            if arr_len_lit > 0 {
                if ast_kind(low_node) == EXPR_INT {
                    if ast_int_val(low_node) < 0 || ast_int_val(low_node) > arr_len_lit {
                        emit(IR_BOUNDS_CHECK, -1, low_var, arr_len_lit + 1, 0, 0);
                    }
                } else {
                    emit(IR_BOUNDS_CHECK, -1, low_var, arr_len_lit + 1, 0, 0);
                }
                if ast_kind(high_node) == EXPR_INT {
                    if ast_int_val(high_node) < 0 || ast_int_val(high_node) > arr_len_lit {
                        emit(IR_BOUNDS_CHECK, -1, high_var, arr_len_lit + 1, 0, 0);
                    }
                } else {
                    emit(IR_BOUNDS_CHECK, -1, high_var, arr_len_lit + 1, 0, 0);
                }
            }
            v := new_ir_var("slice", TI_INT);
            emit(IR_SLICE, v, arr_var, low_var, high_var, 0);
            // F11：字面量界 → 登记切片编译期长度（解引用处 arr_len_lit 用）；
            // 运行时界 → 计算 len = high − low 并登记长度变量（解引用处发射
            // 动态边界检查——见 emit_slice_*_bounds）。
            if ast_kind(low_node) == EXPR_INT && ast_kind(high_node) == EXPR_INT {
                sl := ast_int_val(high_node) - ast_int_val(low_node);
                if sl >= 0 { slice_len_set(v, sl); }
            } else {
                len_var := new_ir_var("slice_len", TI_INT);
                emit(IR_BINARY, len_var, high_var, low_var, OP_SUB, TI_INT);
                slice_len_var_set(v, len_var);
            }
            return v;
        }
        v := new_ir_var("elem", TI_INT);
        if idx_kind == EXPR_INT {
            emit_string_lit_bounds(arr_var, ast_int_val(idx_node));
            emit_slice_lit_bounds(arr_var, ast_int_val(idx_node));
            if pass_before_array_access(arr_var, -1, ast_int_val(idx_node), arr_len_lit) == 0 {
                emit(IR_LOAD_INDEX, v, arr_var, 0, ast_int_val(idx_node), 0);
            }
        } else {
            idx_var := gen_expr(idx_node);
            idx_var = force_if_thunk(idx_var);
            emit_string_bounds(arr_var, idx_var);
            emit_slice_bounds(arr_var, idx_var);
            if pass_before_array_access(arr_var, idx_var, -1, arr_len_lit) == 0 {
                emit(IR_LOAD_INDEX_VAR, v, arr_var, idx_var, 0, 0);
            }
        }
        return v;
    }

    // Enum constructor
    if ast_kind(node) == EXPR_ENUM_CONSTRUCTOR {
        name_idx := ast_a(node);
        s := new_ir_var("enum", TI_UNIT);
        emit(IR_MAKE_ENUM, s, name_idx, ast_c(node), 0, 0);
        ai : ., mut = 0;
        an : ., mut = ast_b(node);  // EXPR_ARG chain
        loop {
            if an < 0 { break; }
            val_var := gen_expr(ast_a(an));
            val_var = force_if_thunk(val_var);
            emit(IR_STORE_FIELD, -1, s, val_var, ai + 1, 0);  // +1 for tag offset
            an = ast_b(an);
            ai = ai + 1;
        }
        return s;
    }

    // Struct literal
    if ast_kind(node) == EXPR_STRUCT {
        name_ni := ast_a(node);
        s := new_ir_var("struct", TI_UNIT);
        emit(IR_ALLOC_STRUCT, s, 0, 0, name_ni, 0);
        fi : ., mut = 0;
        fn2 : ., mut = ast_b(node);
        loop {
            if fi >= ast_c(node) { break; }
            if fn2 >= 0 {
                // fn2 = wrapper node (kind=0, a=value expr)
                val_var := gen_expr(fn2);
                val_var = force_if_thunk(val_var);
                field_idx := fi;
                emit(IR_STORE_FIELD, -1, s, val_var, field_idx, 0);
                fn2 = fn2 + 1;
            }
            fi = fi + 1;
        }
        return s;
    }

    // Array literal
    if ast_kind(node) == EXPR_ARRAY {
        v := new_ir_var("arr", TI_UNIT);
        emit(IR_ALLOC_ARRAY, v, ast_b(node), 0, 0, 0);
        elem_ti : ., mut = TI_INT;
        ei : ., mut = 0;
        en : ., mut = ast_a(node);
        loop {
            if ei >= ast_b(node) { break; }
            if en >= 0 {
                e_var := gen_expr(en);
                e_var = force_if_thunk(e_var);
                if ei == 0 { elem_ti = irv_type(e_var); }
                emit(IR_STORE_INDEX, -1, v, e_var, ei, 0);
                en = en + 1;
            }
            ei = ei + 1;
        }
        irv_set_type(v, alloc_type(TYP_ARRAY, elem_ti, ast_b(node)));
        return v;
    }

    // Range expression (evaluates both ends, returns end)
    if ast_kind(node) == EXPR_RANGE {
        start_var := gen_expr(ast_a(node));
        start_var = force_if_thunk(start_var);
        end_var := gen_expr(ast_b(node));
        end_var = force_if_thunk(end_var);
        return end_var;
    }

    // Break / Continue
    if ast_kind(node) == EXPR_BREAK {
        if g_ir_loop_depth > 0 {
            emit(IR_JUMP, -1, r64(g_ir_loop_exit, (g_ir_loop_depth - 1) * 8), 0, 0, 0);
        }
        return -1;
    }
    if ast_kind(node) == EXPR_CONTINUE {
        if g_ir_loop_depth > 0 {
            emit(IR_JUMP, -1, r64(g_ir_loop_header, (g_ir_loop_depth - 1) * 8), 0, 0, 0);
        }
        return -1;
    }

    if ast_kind(node) == EXPR_WILDCARD { return -1; }
    if ast_kind(node) == EXPR_ENUMPAT { return -1; }
    if ast_kind(node) == EXPR_MOVE {
        return gen_expr(ast_a(node));
    }
    if ast_kind(node) == EXPR_UNSAFE {
        sg_alloc_push(SG_UNSAFE);
        arena_var := new_ir_var("_arena", TI_INT);
        w64(g_sg_arena_var, (g_sg_count - 1) * 8, arena_var);
        emit(IR_ARENA_NEW, arena_var, 0, 0, 0, 0);
        arena_instr := g_ir_instr_count - 1;
        ret := gen_expr(ast_a(node));
        total := r64(g_sg_alloc_total, g_sg_count - 1);
        if total > 0 { iri_set_s1(arena_instr, total); }
        sg_alloc_pop();
        return ret;
    }
    if ast_kind(node) == EXPR_AS {
        inner_var := gen_expr(ast_a(node));
        inner_var = force_if_thunk(inner_var);
        target_ti := ti_from_type_expr(ast_b(node));
        if get_type_kind(target_ti) == TYP_PTR {
            source_ti := irv_type(inner_var);
            source_kind := get_type_kind(source_ti);
            asp : ., mut = 1;
            if source_kind == TYP_PTR {
                asp = get_type_extra(source_ti);
            } else if source_kind == TYP_REF || is_byte_buf_var(inner_var) != 0 {
                asp = 0;
            }
            target_ti = alloc_type(TYP_PTR, get_type_data(target_ti), asp);
        }
        cast_var := new_ir_var("_cast", target_ti);
        emit(IR_LOAD, cast_var, inner_var, 0, 0, target_ti);
        return cast_var;
    }
    if ast_kind(node) == EXPR_TRY {
        // Try: unwrap Result/Option, just emit the inner expr for now
        return gen_expr(ast_a(node));
    }
    if ast_kind(node) == EXPR_STRUCTPAT {
        return -1;
    }
    if ast_kind(node) == EXPR_STMT {
        gen_expr(ast_a(node));
        return -1;
    }
    if ast_kind(node) == EXPR_TUPLE {
        // Tuple: allocate array for N elements, store each
        elem_idx := ast_a(node);
        ec : ., mut = ast_b(node);
        tv := new_ir_var("tuple", TI_INT);
        emit(IR_ALLOC_ARRAY, tv, ec, 0, 8, 0);  // alloc N * 8 bytes
        // Store each element at its offset
        e : ., mut = 0;
        loop {
            if e >= ec { break; }
            elem_var := gen_expr(elem_idx + e);
            elem_var = force_if_thunk(elem_var);
            emit(IR_STORE_FIELD, -1, tv, elem_var, e, 0);
            e = e + 1;
        }
        return tv;
    }

    return -1;
}

// --- Generate IR for one function ---

fn ir_gen_func(fi: int) {
    // Skip generic functions — they will be monomorphized at call sites
    if fi_generic_count(fi) > 0 { return; }
    fn_node := fi_ast_node(fi);
    name_idx := ast_a(fn_node);
    first_param := ast_b(fn_node);
    param_count := ast_c(fn_node);
    // 返回类型：从 FuncInfo 取原始 TY_* 常量（ast_type_val(fn_node) 是返回类型
    // 节点下标而非类型常量——错读会使 g_cur_ret_ti 不等于 TI_DEX，apx 返回点
    // bits→scaled 转换失效，仅在 dex 类型节点下标恰为 1 时碰巧生效）
    ret_ti := fi_return_type(fi);
    body := ast_data(fn_node);

    // Record function metadata
    func_idx := g_ir_func_count;
    grow_ir_func_meta(func_idx + 1);
    w64(g_ir_func_name_idx, func_idx * 8, name_idx);
    w64(g_ir_func_ret_type, func_idx * 8, ret_ti);
    w64(g_ir_func_instr_start, func_idx * 8, g_ir_instr_count);
    w64(g_ir_func_var_start, func_idx * 8, g_ir_var_count);
    w64(g_ir_func_param_count, func_idx * 8, param_count);

    // Create IR vars for params
    pi : ., mut = 0;
    pn : ., mut = first_param;
    loop {
        if pi >= param_count { break; }
        if pn < 0 { break; }
        pname_idx := ast_a(pn);
        pname := istr_get(pname_idx);
        param_type : ., mut = ast_type_val(pn);
        if param_type < 0 { param_type = TI_INT; }
        // dex 边界规则（数值迁移 Task 4）：参数一律精确形式（缩放整数，整数寄存器传递）
        if param_type == TI_DEX { param_type = TI_DEX_S; }
        pvar := new_ir_var(pname, param_type);
        // Bind param name
        bind_local(pname_idx, pvar);
        pi = pi + 1;
        // Scan past type nodes to next EXPR_PARAM
        pn = pn + 1;
        loop {
            if pn >= g_ast_count { break; }
            if ast_kind(pn) == EXPR_PARAM { break; }
            pn = pn + 1;
        }
    }

    // Function-level arena (df_begin_func already pushed SG_FUNC)
    grow_sg_alloc(g_sg_count + 1);
    grow_sg_arena_var(g_sg_count + 1);
    w64(g_sg_alloc_total, (g_sg_count - 1) * 8, 0);
    arena_var := new_ir_var("_arena", TI_INT);
    w64(g_sg_arena_var, (g_sg_count - 1) * 8, arena_var);
    emit(IR_ARENA_NEW, arena_var, 0, 0, 0, 0);
    arena_instr := g_ir_instr_count - 1;

    // Generate body（记录返回 TI——EXPR_RETURN 的 dex 边界转换用）
    g_cur_ret_ti = ret_ti;
    if body >= 0 {
        gen_expr(body);
    }
    g_cur_ret_ti = -1;

    // Patch arena size and reset before return
    total := r64(g_sg_alloc_total, (g_sg_count - 1) * 8);
    if total > 0 { iri_set_s1(arena_instr, total); }
    emit(IR_ARENA_RESET, -1, arena_var, 0, 0, 0);

    // Add return at end if not already terminated
    emit(IR_RETURN, -1, -1, 0, 0, 0);

    w64(g_ir_func_instr_count, func_idx * 8, g_ir_instr_count - r64(g_ir_func_instr_start, func_idx * 8));
    w64(g_ir_func_var_count, func_idx * 8, g_ir_var_count - r64(g_ir_func_var_start, func_idx * 8));
    g_ir_func_count = func_idx + 1;
}

// --- Initialize global IR vars from global lets ---

// Extract the compile-time constant initializer of a file-scope let
// (0 = none/not constant — BSS is zero-initialized anyway).
// NB: applies to mutable AND immutable lets (mut/const init values both
// need to be written at startup — unlike find_global_const_node which
// only folds immutable constants at compile time).
fn global_init_val(name_idx: int) -> int {
    i : ., mut = g_global_let_count - 1;
    loop {
        if i < 0 { break; }
        node := r64(g_global_lets, i * 8);
        if ast_a(node) == name_idx {
            value_node := ast_c(node);
            if value_node >= 0 {
                vk := ast_kind(value_node);
                if vk == EXPR_INT || vk == EXPR_BOOL {
                    return ast_int_val(value_node);
                }
                if vk == EXPR_DEX {
                    // dex 全局常量：定点缩放整数（精确形式初始值；apx 位模式由
                    // reg_one_global 从节点 a 取——见该函数）
                    return ast_int_val(value_node);
                }
                if vk == EXPR_UNARY && ast_c(value_node) == UOP_NEG {
                    inner := ast_a(value_node);
                    if ast_kind(inner) == EXPR_INT || ast_kind(inner) == EXPR_BOOL {
                        return 0 - ast_int_val(inner);
                    }
                    if ast_kind(inner) == EXPR_DEX {
                        return 0 - ast_int_val(inner);
                    }
                }
            }
        }
        i = i - 1;
    }
    return 0;
}

// Register one IR global, deduplicated by name_idx.
fn reg_one_global(name_idx: int) {
    found : ., mut = 0;
    gi : ., mut = 0;
    loop { if gi >= g_ir_global_count { break; }
        if r64(g_ir_globals, gi * 24) == name_idx { found = 1; break; }
    gi = gi + 1; }
    if found == 0 {
        name := istr_get(name_idx);
        // dex 全局变量（数值迁移 Task 4）：精确（TI_DEX_S，缩放整数初始值）或
        // apx（TI_DEX，binary64 位模式初始值）——按声明 LET 的类型节点与 apx 位
        gtype : ., mut = TI_INT;
        is_dex_global : ., mut = 0;
        gli : ., mut = 0;
        loop {
            if gli >= g_global_let_count { break; }
            lnode := r64(g_global_lets, gli * 8);
            if ast_a(lnode) == name_idx {
                ltn := ast_b(lnode);
                if ltn >= 0 && ast_kind(ltn) == 0 && ast_type_val(ltn) == TY_DEX {
                    if ast_int_val(lnode) != 0 { gtype = TI_DEX; } else { gtype = TI_DEX_S; }
                    is_dex_global = 1;
                }
                break;
            }
            gli = gli + 1;
        }
        gvar := new_ir_var(name, gtype);
        grow_ir_globals(g_ir_global_count + 1);
        w64(g_ir_globals, g_ir_global_count * 24, name_idx);
        w64(g_ir_globals, g_ir_global_count * 24 + 8, gvar);
        // Const initializer — emitted by the ELF backend's _init_globals.
        iv : int = global_init_val(name_idx);
        if is_dex_global != 0 && gtype == TI_DEX {
            // apx 全局：初始值为 binary64 位模式（缩放值 → bits 从节点 a 取）
            i2 : ., mut = 0;
            loop {
                if i2 >= g_global_let_count { break; }
                lnode2 := r64(g_global_lets, i2 * 8);
                if ast_a(lnode2) == name_idx {
                    vn := ast_c(lnode2);
                    if vn >= 0 && ast_kind(vn) == EXPR_DEX { iv = ast_a(vn); }
                    break;
                }
                i2 = i2 + 1;
            }
        }
        w64(g_ir_globals, g_ir_global_count * 24 + 16, iv);
        g_ir_global_count = g_ir_global_count + 1;
    }
}

fn ir_gen_globals() {
    // The parser records only file-scope declarations in g_global_lets.
    // Do not scan every EXPR_LET here: that also includes function locals.
    i : ., mut = 0;
    loop {
        if i >= g_global_let_count { break; }
        node := r64(g_global_lets, i * 8);
        reg_one_global(ast_a(node));
        i = i + 1;
    }

    // Manually register ir_gen.cr's own globals — the parser's auto-detection
    // of file-scope declarations is known to miss some (see CLAUDE.md Known Issues).
    reg_one_global(str_intern("g_sg_alloc_total"));
    reg_one_global(str_intern("g_sg_alloc_cap"));
    reg_one_global(str_intern("g_sg_arena_var"));
    reg_one_global(str_intern("g_sg_arena_var_cap"));
    reg_one_global(str_intern("g_ir_source_hash"));
    reg_one_global(str_intern("g_ir_source_hash_ready"));
    reg_one_global(str_intern("g_cir_write_buf"));
    reg_one_global(str_intern("g_cir_write_pos"));
    reg_one_global(str_intern("g_cir_write_cap"));
    // Runtime globals needed by emit_alloc_body and emit_start.
    // These MUST exist in BSS for every program, even without rt.cr included.
    reg_one_global(str_intern("g_heap_ptr"));
    reg_one_global(str_intern("g_heap_end"));
    reg_one_global(str_intern("g_current_arena"));
    reg_one_global(str_intern("g_arena_cursors"));
    reg_one_global(str_intern("g_arena_sizes"));
    reg_one_global(str_intern("g_arena_parents"));
    reg_one_global(str_intern("g_arena_max_size"));
    reg_one_global(str_intern("g_arena_count"));
    reg_one_global(str_intern("g_arena_cap"));
    reg_one_global(str_intern("g_arena_pool_data"));
    reg_one_global(str_intern("g_arena_free_list"));
}

// --- AST walk: patch method call names for monomorphization ---

fn ast_patch_node(node: int, subst_from: string, subst_to: string) {
    if node < 0 { return; }
    k := ast_kind(node);
    if k == EXPR_CALL {
        func_node := ast_a(node);
        if ast_kind(func_node) == EXPR_FIELD {
            data_ni := ast_data(node);
            if data_ni >= 0 {
                data_str := istr_get(data_ni);
                dlen := str_len(data_str);
                flen := str_len(subst_from);
                if dlen >= flen {
                    matches : ., mut = 1;
                    dci : ., mut = 0;
                    loop {
                        if dci >= flen { break; }
                        if load8(data_str, dci) != load8(subst_from, dci) { matches = 0; break; }
                        dci = dci + 1;
                    }
                    if matches != 0 && (dlen == flen || load8(data_str, flen) == 46) {
                        rest := str_sub(data_str, flen, dlen - flen);
                        new_name := subst_to + rest;
                        ast_set_data(node, str_intern(new_name));
                    }
                }
            }
        }
    }
    // Recurse into children based on node kind
    if k == EXPR_BLOCK {
        ss := ast_a(node); sc := ast_b(node);
        i2 : ., mut = 0;
        loop { if i2 >= sc { break; }
            sn2 := r64(g_block_stmts, (ss + i2) * 8);
            ast_patch_node(sn2, subst_from, subst_to);
            i2 = i2 + 1; }
    } else if k == EXPR_IF || k == EXPR_LOOP || k == EXPR_WHILE || k == EXPR_UNSAFE {
        if ast_a(node) >= 0 { ast_patch_node(ast_a(node), subst_from, subst_to); }
        if k == EXPR_IF {
            if ast_b(node) >= 0 { ast_patch_node(ast_b(node), subst_from, subst_to); }
            if ast_c(node) >= 0 { ast_patch_node(ast_c(node), subst_from, subst_to); }
        }
    } else if k == EXPR_BINARY || k == EXPR_ASSIGN || k == EXPR_RANGE || k == EXPR_AS {
        if ast_a(node) >= 0 { ast_patch_node(ast_a(node), subst_from, subst_to); }
        if ast_b(node) >= 0 { ast_patch_node(ast_b(node), subst_from, subst_to); }
    } else if k == EXPR_CALL || k == EXPR_ENUM_CONSTRUCTOR {
        if ast_a(node) >= 0 { ast_patch_node(ast_a(node), subst_from, subst_to); }
        an3 := ast_b(node); ac3 := ast_c(node);
        ai3 : ., mut = 0;
        loop { if ai3 >= ac3 { break; } if an3 >= 0 { ast_patch_node(an3, subst_from, subst_to); an3 = an3 + 1; } ai3 = ai3 + 1; }
    } else if k == EXPR_MATCH {
        if ast_a(node) >= 0 { ast_patch_node(ast_a(node), subst_from, subst_to); }
        an4 := ast_b(node);
        loop { if an4 < 0 { break; }
            if ast_a(an4) >= 0 { ast_patch_node(ast_a(an4), subst_from, subst_to); }
            if ast_b(an4) >= 0 { ast_patch_node(ast_b(an4), subst_from, subst_to); }
            an4 = ast_c(an4); }
    } else if k == EXPR_FOR {
        if ast_b(node) >= 0 { ast_patch_node(ast_b(node), subst_from, subst_to); }
        if ast_c(node) >= 0 { ast_patch_node(ast_c(node), subst_from, subst_to); }
    } else if k == EXPR_LET {
        if ast_c(node) >= 0 { ast_patch_node(ast_c(node), subst_from, subst_to); }
    } else if k == EXPR_STMT {
        if ast_a(node) >= 0 { ast_patch_node(ast_a(node), subst_from, subst_to); }
    } else if k == EXPR_STRUCT {
        an5 := ast_b(node); ac5 := ast_c(node);
        ai5 : ., mut = 0;
        loop { if ai5 >= ac5 { break; } if an5 >= 0 { ast_patch_node(an5, subst_from, subst_to); an5 = an5 + 1; } ai5 = ai5 + 1; }
    } else if k == EXPR_ARRAY || k == EXPR_TUPLE {
        an6 := ast_b(node); ac6 := ast_c(node);
        ai6 : ., mut = 0;
        loop { if ai6 >= ac6 { break; } if an6 >= 0 { ast_patch_node(an6, subst_from, subst_to); an6 = an6 + 1; } ai6 = ai6 + 1; }
    } else if k == EXPR_FIELD || k == EXPR_INDEX || k == EXPR_UNARY || k == EXPR_RETURN || k == EXPR_TRY || k == EXPR_MOVE {
        if ast_a(node) >= 0 { ast_patch_node(ast_a(node), subst_from, subst_to); }
    }
}

fn find_or_create_mono_func(fi: int, call_node: int) -> int {
    // Create a monomorphized version of generic function fi for the given call site.
    // Only creates the FuncInfo entry — IR generation happens in pass 2 of ir_gen_all.

    fn_node := fi_ast_node(fi);
    body := ast_data(fn_node);
    first_param := ast_b(fn_node);
    param_count := ast_c(fn_node);
    orig_ret_type := ast_int_val(fn_node);
    orig_ret_node := ast_type_val(fn_node);

    gen_name_ni := fi_generic_name(fi, 0);
    gen_name := istr_get(gen_name_ni);

    // Get concrete type name from call node (stored by checker)
    concrete_type_ni : ., mut = ast_int_val(call_node);
    concrete_type_name : ., mut = istr_get(concrete_type_ni);

    // Create mangled name: "funcname$genericname.concretetype"
    orig_fn_name := istr_get(fi_name(fi));
    mangled_name : ., mut = orig_fn_name + "$";
    mangled_name = mangled_name + gen_name + "." + concrete_type_name;
    mangled_ni := str_intern(mangled_name);

    // Check if already exists
    existing := find_func(mangled_ni);
    if existing >= 0 { return existing; }

    // Create new EXPR_PARAM nodes with concrete param types
    new_first_param : ., mut = -1;
    ppi : ., mut = 0;
    ppn : ., mut = first_param;
    loop {
        if ppi >= param_count { break; }
        if ppn < 0 { break; }
        pname_ni := ast_a(ppn);
        self_mode := ast_int_val(ppn);
        orig_type_val := ast_type_val(ppn);
        orig_type_node := ast_data(ppn);

        // Replace type node if it references the generic param
        new_type_node : ., mut = orig_type_node;
        if orig_type_node >= 0 && ast_kind(orig_type_node) == EXPR_IDENT && ast_int_val(orig_type_node) == gen_name_ni {
            // Create new type node referencing concrete type name
            new_type_node = alloc_node(EXPR_IDENT, 0, 0, 0, concrete_type_ni, 0, 0, 0, 0);
        }

        np := alloc_node(EXPR_PARAM, pname_ni, 0, 0, self_mode, orig_type_val, new_type_node, 0, 0);
        if ppi == 0 { new_first_param = np; }
        ppi = ppi + 1;
        ppn = ppn + 1;
        loop { if ppn >= g_ast_count { break; } if ast_kind(ppn) == EXPR_PARAM { break; } ppn = ppn + 1; }
    }

    // Create new EXPR_FN node
    new_fn_node := alloc_node(EXPR_FN, mangled_ni, new_first_param, param_count, orig_ret_type, orig_ret_node, body, 0, 0);

    // Patch body: replace "gen_name.method" → "concrete_type_name.method"
    if body >= 0 {
        ast_patch_node(body, gen_name, concrete_type_name);
    }

    // Register new function
    new_fi := add_func(mangled_name, param_count, orig_ret_type, new_fn_node);
    if new_fi >= 0 {
        // Copy generic constraint info (non-generic now, but keep for reference)
        fi_set_generic_count(new_fi, 0);
    }

    return new_fi;
}

// --- Main entry ---

fn ir_gen_all() {
    g_ir_var_count = 0;
    g_ir_instr_count = 0;
    g_ir_func_count = 0;
    g_ir_local_count = 0;
    g_ir_local_depth = 0;
    g_ir_global_count = 0;
    g_next_label = 1;
    g_ir_loop_depth = 0;
    g_ir_str_const_count = 0;

    // Initialize dataflow graph
    init_df();

    // Initialize globals
    ir_gen_globals();

    i : ., mut = 0;
    loop {
        if i >= g_func_count { break; }
        if fi_generic_count(i) > 0 { i = i + 1; continue; }
        ir_func_idx := g_ir_func_count;
        df_begin_func(ir_func_idx);
        ir_gen_func(i);
        df_end_func(ir_func_idx);
        i = i + 1;
    }
}

// Compute function body fingerprint: hash of the function body source text.
// Used for cache hit detection. If the body hasn't changed, the output IR
// is identical and can be restored from cache.
fn func_fingerprint(func_node: int) -> int {
    // func_node = EXPR_FUNC node
    // Body starts at ast_data(func_node)
    body := ast_data(func_node);
    if body < 0 { return 0; }
    // For fingerprinting, hash the function's AST line/col range in source
    // This is simpler than extracting the exact body bytes:
    // hash AST node kind chain from the body
    if g_ir_source_hash_ready == 0 {
        source_hash : ., mut = 2166136261;
        source_pos : ., mut = 0;
        source_len := str_len(g_source);
        loop {
            if source_pos >= source_len { break; }
            source_hash = source_hash * 16777619 + load8(g_source, source_pos);
            source_pos = source_pos + 1;
        }
        g_ir_source_hash = source_hash;
        g_ir_source_hash_ready = 1;
    }
    h : ., mut = g_ir_source_hash;
    // Walk the body AST and hash node kinds + values
    // For a simple first pass: hash the function's token stream range
    start_line := ast_line(func_node);
    start_col := ast_col(func_node);
    // Use g_line/position info to hash source bytes for this function
    // For now: simple hash of function name + param count + body node
    h = h * 16777619 + (ast_kind(func_node) % 256);
    h = h * 16777619 + (ast_a(func_node) % 256);   // name_ni
    h = h * 16777619 + (ast_c(func_node) % 256);   // param count
    if body >= 0 { h = h * 16777619 + (ast_kind(body) % 256); }
    return h;
}

// Compute function signature fingerprint: hash of name + param types + return type.
// Used to detect when callers need recompilation.
fn sig_fingerprint(func_node: int) -> int {
    h : ., mut = 2166136261;
    // Name
    name_ni := ast_a(func_node);
    name := istr_get(name_ni);
    ni : ., mut = 0;
    loop { if ni >= str_len(name) { break; }
        h = h * 16777619 + (load8(name, ni) % 256);
    ni = ni + 1; }
    // Param types
    param := ast_b(func_node);
    param_count := ast_c(func_node);
    pi : ., mut = 0;
    loop { if pi >= param_count { break; }
        pt := ast_type_val(param);
        h = h * 16777619 + (pt % 256);
        pi = pi + 1;
        param = param + 1;
    }
    // Return type
    ret_type := ast_type_val(func_node);
    h = h * 16777619 + (ret_type % 256);
    return h;
}
