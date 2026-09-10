// === checker.core ===
// Two-pass name resolver + type checker for flat AST
// First pass: collect all function/struct/global declarations
// Second pass: type-check function bodies

// --- Type table ---
// Entries are 3 ints: kind, data, extra

fn alloc_type(kind: int, data: int, extra: int) -> int {
    idx := g_type_count;
    grow_types(idx + 1);
    w64(g_types, idx * 24, kind);
    w64(g_types, idx * 24 + 8, data);
    w64(g_types, idx * 24 + 16, extra);
    g_type_count = idx + 1;
    return idx;
}

fn init_types() {
    g_type_count = 0;
    alloc_type(TYP_BASE, TY_INT, 0);     // TI_INT = 0
    alloc_type(TYP_BASE, TY_DEX, 0);   // TI_DEX = 1
    alloc_type(TYP_BASE, TY_BOOL, 0);    // TI_BOOL = 2
    alloc_type(TYP_BASE, TY_STRING, 0);  // TI_STR = 3
    alloc_type(TYP_BASE, TY_UNIT, 0);    // TI_UNIT = 4
    alloc_type(TYP_BASE, TY_NEVER, 0);   // TI_NEVER = 5
    alloc_type(TYP_BASE, TY_CHAR, 0);    // TI_CHAR = 6
    alloc_type(TYP_DYN, 0, 0);           // TI_DYN = 7
    // TI_DEX_S = 8 占位表项（终审 M1 修复）：TI_DEX_S 是 dex 定点精确形式（缩放整数）
    // 的 IR 变量类型哨兵，值恰为 8——曾与"首个动态分配类型下标"碰撞，@sizeOf/@alignOf/
    // is_ptr_var 的哨兵守卫对首个真实类型误触发。占住下标 8 后用户类型从 9 起，
    // 守卫永不再命中真实类型（TI_DEX_S 本身仍不查类型表，见 ir_gen.cr 注释）。
    alloc_type(TYP_BASE, TY_DEX_S, 0);   // TI_DEX_S = 8 占位
}

// ── Runtime builtin declarations (no .cr body, implemented in rt.s) ──
g_rt_builtin_count : int, mut;
g_rt_builtin_names : string, mut;
g_rt_builtin_ret_types : string, mut;

fn init_builtins() {
    g_rt_builtin_count = 0; g_rt_builtin_names = alloc(8 * 8); g_rt_builtin_ret_types = alloc(8 * 8);

    bi_add("load8", TI_INT);
    bi_add("store8", TI_INT);
    bi_add("load64", TI_INT);
    bi_add("r64", TI_INT);
    bi_add("alloc", TI_STR);
    bi_add("get_arg", TI_STR);
    bi_add("w32", TI_UNIT);
    bi_add("w64", TI_UNIT);
    bi_add("_dyncpy", TI_UNIT);
    bi_add("load_str_ptr", TI_STR);
    bi_add("store_str_ptr", TI_INT);
    bi_add("sched_call_0", TI_INT);
    bi_add("sched_call_1", TI_INT);
    bi_add("sched_call_2", TI_INT);
    bi_add("sched_call_3", TI_INT);
    bi_add("sched_call_4", TI_INT);
    bi_add("fiber_switch", TI_INT);
    bi_add("fiber_init", TI_INT);
    bi_add("sched_go", TI_INT);
    bi_add("m_start_workers", TI_UNIT);
    bi_add("g_set_curg", TI_UNIT);
    bi_add("g_get_curg", TI_INT);
}

fn bi_add(name: string, ret_ti: int) {
    ni := str_intern(name);
    if g_rt_builtin_count * 8 + 8 > str_len(g_rt_builtin_names) {
        nc := g_rt_builtin_count * 2 + 16;
        nb := alloc(nc * 8); _dyncpy(g_rt_builtin_names, g_rt_builtin_count * 8, nb);
        g_rt_builtin_names = nb;
    }
    if g_rt_builtin_count * 8 + 8 > str_len(g_rt_builtin_ret_types) {
        nc := g_rt_builtin_count * 2 + 16;
        nb := alloc(nc * 8); _dyncpy(g_rt_builtin_ret_types, g_rt_builtin_count * 8, nb);
        g_rt_builtin_ret_types = nb;
    }
    w64(g_rt_builtin_names, g_rt_builtin_count * 8, ni);
    w64(g_rt_builtin_ret_types, g_rt_builtin_count * 8, ret_ti);
    g_rt_builtin_count = g_rt_builtin_count + 1;
}

fn get_type_kind(ti: int) -> int {
    if ti >= 0 && ti < g_type_count { return r64(g_types, ti * 24); }
    return -1;
}

fn get_type_data(ti: int) -> int {
    if ti >= 0 && ti < g_type_count { return r64(g_types, ti * 24 + 8); }
    return 0;
}

fn get_type_extra(ti: int) -> int {
    if ti >= 0 && ti < g_type_count { return r64(g_types, ti * 24 + 16); }
    return 0;
}

fn type_equal(t1: int, t2: int) -> bool {
    if t1 == t2 { return true; }
    // Compare structure for non-base types
    if t1 >= 0 && t2 >= 0 && t1 < g_type_count && t2 < g_type_count {
        k1 := get_type_kind(t1);
        k2 := get_type_kind(t2);
        if k1 == TYP_NAMED && k2 == TYP_NAMED {
            return get_type_data(t1) == get_type_data(t2);
        }

        if k1 == TYP_ARRAY && k2 == TYP_ARRAY {
            if type_equal(get_type_data(t1), get_type_data(t2)) {
                if get_type_extra(t1) == get_type_extra(t2) {
                    return true;
                }
            }
            return false;
        }
        if k1 == TYP_TUPLE && k2 == TYP_TUPLE {
            if get_type_data(t1) != get_type_data(t2) { return false; }
            start1 := get_type_extra(t1);
            start2 := get_type_extra(t2);
            cnt := get_type_data(t1);
            i : ., mut = 0;
            loop {
                if i >= cnt { break; }
                if !type_equal(r64(g_gen_apply_data, (start1 + i) * 8), r64(g_gen_apply_data, (start2 + i) * 8)) { return false; }
                i = i + 1;
            }
            return true;
        }
        if k1 == TYP_REF && k2 == TYP_REF {
            return get_type_extra(t1) == get_type_extra(t2) && type_equal(get_type_data(t1), get_type_data(t2));
        }
        if k1 == TYP_PTR && k2 == TYP_PTR {
            return type_equal(get_type_data(t1), get_type_data(t2));
        }
        if k1 == TYP_SLICE && k2 == TYP_SLICE {
            return type_equal(get_type_data(t1), get_type_data(t2));
        }
        if k1 == TYP_GENERIC_APPLY && k2 == TYP_GENERIC_APPLY {
            if get_type_data(t1) != get_type_data(t2) { return false; }
            start1 := get_type_extra(t1);
            start2 := get_type_extra(t2);
            count1 := r64(g_gen_apply_data, start1 * 8);
            count2 := r64(g_gen_apply_data, start2 * 8);
            if count1 != count2 { return false; }
            ai : ., mut = 0;
            loop {
                if ai >= count1 { break; }
                if !type_equal(r64(g_gen_apply_data, (start1 + 1 + ai) * 8), r64(g_gen_apply_data, (start2 + 1 + ai) * 8)) { return false; }
                ai = ai + 1;
            }
            return true;
        }
        if k1 == TYP_GENERIC_PARAM && k2 == TYP_GENERIC_PARAM {
            return get_type_data(t1) == get_type_data(t2);
        }
    }
    return false;
}

fn scan_for_yield(node: int) -> int {
    if node < 0 { return 0; }
    k := ast_kind(node);
    if k == EXPR_YIELD { return 1; }
    if k == EXPR_BLOCK {
        ss := ast_a(node); sc := ast_b(node);
        i : ., mut = 0;
        loop { if i >= sc { break; }
            sn := r64(g_block_stmts, (ss + i) * 8);
            if scan_for_yield(sn) != 0 { return 1; }
            i = i + 1; }
        return 0; }
    if k == EXPR_LOOP || k == EXPR_WHILE {
        return scan_for_yield(ast_a(node)); }
    if k == EXPR_IF {
        if scan_for_yield(ast_a(node)) != 0 { return 1; }
        if scan_for_yield(ast_b(node)) != 0 { return 1; }
        if ast_c(node) >= 0 && scan_for_yield(ast_c(node)) != 0 { return 1; }
        return 0; }
    if k == EXPR_FOR { return scan_for_yield(ast_c(node)); }
    return 0;
}

// --- Symbol table ---
struct SymEntry {
    name_idx: int,
    kind: int,
    type_idx: int,
    node_idx: int,
}

fn push_scope() {
    grow_scope_bounds(g_scope_depth + 1);
    w64(g_scope_bounds, g_scope_depth * 8, g_sym_count);
    g_scope_depth = g_scope_depth + 1;
}

fn pop_scope() {
    if g_scope_depth > 0 {
        g_scope_depth = g_scope_depth - 1;
        g_sym_count = r64(g_scope_bounds, g_scope_depth * 8);
    }
}

fn def_sym(name_idx: int, kind: int, type_idx: int, node_idx: int) {
    grow_syms(g_sym_count + 1);
    sym_set_name(g_sym_count, name_idx);
    sym_set_kind(g_sym_count, kind);
    sym_set_type(g_sym_count, type_idx);
    sym_set_node(g_sym_count, node_idx);
    g_sym_count = g_sym_count + 1;
}

fn find_sym(name_idx: int) -> int {
    i : ., mut = g_sym_count - 1;
    loop {
        if i < 0 { return -1; }
        if sym_name(i) == name_idx { return i; }
        i = i - 1;
    }
    return -1;
}

fn find_gsym(name_idx: int) -> int {
    i : ., mut = g_sym_count - 1;
    loop {
        if i < 0 { return -1; }
        if sym_name(i) == name_idx && sym_kind(i) >= SYM_FN && sym_kind(i) <= SYM_SO_FN { return i; }
        i = i - 1;
    }
    return -1;
}

fn find_so_fn(name_idx: int) -> int {
    i : ., mut = 0;  // forward scan — SYM_SO_FN entries are before SYM_FN
    loop {
        if i >= g_sym_count { return -1; }
        if sym_name(i) == name_idx && sym_kind(i) == SYM_SO_FN {
            return i;
        }
        i = i + 1;
    }
    return -1;
}


// --- Error tracking ---
// Uses g_diags, g_diag_count from globals.cr (and ast.cr)
// Old g_check_errors is replaced by structured g_diags.

fn check_error(code: int, msg: string, line: int, col: int) {
    grow_diags(g_diag_count + 1);
    w64(g_diags, g_diag_count * DIAG_REC_SIZE, code);
    store_str_ptr(g_diags, g_diag_count * DIAG_REC_SIZE + 8, msg);
    w64(g_diags, g_diag_count * DIAG_REC_SIZE + 16, line);
    w64(g_diags, g_diag_count * DIAG_REC_SIZE + 24, col);
    w64(g_diags, g_diag_count * DIAG_REC_SIZE + 32, diag_fileid_for_line(line));
    g_diag_count = g_diag_count + 1;
}

// --- Borrow checking ---


fn find_borrow_entry(var_ni: int) -> int {
    i : ., mut = 0;
    loop {
        if i >= g_borrow_count { return -1; }
        if r64(g_borrow_vars, i * 8) == var_ni { return i; }
        i = i + 1;
    }
    return -1;
}

fn check_borrow(var_ni: int, is_mut: int) -> bool {
    bi := find_borrow_entry(var_ni);
    if bi >= 0 {
        if is_mut != 0 {
            // &mut x: fail if any borrow exists
            if r64(g_borrow_refs, bi * 8) > 0 || r64(g_borrow_muts, bi * 8) != 0 { return false; }
            w64(g_borrow_muts, bi * 8, 1);
            return true;
        } else {
            // &x: fail if mutable borrow exists
            if r64(g_borrow_muts, bi * 8) != 0 { return false; }
            w64(g_borrow_refs, bi * 8, r64(g_borrow_refs, bi * 8) + 1);
            return true;
        }
    }
    // First borrow of this variable
    grow_borrow_vars(g_borrow_count + 1);
    w64(g_borrow_vars, g_borrow_count * 8, var_ni);
    w64(g_borrow_refs, g_borrow_count * 8, 0);
    w64(g_borrow_muts, g_borrow_count * 8, 0);
    if is_mut != 0 { w64(g_borrow_muts, g_borrow_count * 8, 1); }
    else { w64(g_borrow_refs, g_borrow_count * 8, 1); }
    g_borrow_count = g_borrow_count + 1;
    return true;
}

fn check_use(var_ni: int) -> bool {
    bi := find_borrow_entry(var_ni);
    if bi >= 0 {
        if r64(g_borrow_refs, bi * 8) > 0 || r64(g_borrow_muts, bi * 8) != 0 { return false; }
    }
    return true;
}

fn push_borrow_scope() {
    grow_borrow_markers(g_borrow_scope_depth + 1);
    w64(g_borrow_scope_markers, g_borrow_scope_depth * 8, g_holder_count);
    g_borrow_scope_depth = g_borrow_scope_depth + 1;
}

fn pop_borrow_scope() {
    if g_borrow_scope_depth > 0 {
        g_borrow_scope_depth = g_borrow_scope_depth - 1;
        marker := r64(g_borrow_scope_markers, g_borrow_scope_depth * 8);
        // Release all borrows held from marker to end
        loop {
            if g_holder_count <= marker { break; }
            g_holder_count = g_holder_count - 1;
            borrowed_ni := r64(g_holder_borrowed, g_holder_count * 8);
            is_mut := r64(g_holder_is_mut, g_holder_count * 8);
            bi := find_borrow_entry(borrowed_ni);
            if bi >= 0 {
                if is_mut != 0 { w64(g_borrow_muts, bi * 8, 0); }
                else {
                    if r64(g_borrow_refs, bi * 8) > 0 { w64(g_borrow_refs, bi * 8, r64(g_borrow_refs, bi * 8) - 1); }
                }
                // Clean up entry if no more borrows
                if r64(g_borrow_refs, bi * 8) == 0 && r64(g_borrow_muts, bi * 8) == 0 {
                    si : ., mut = bi;
                    loop {
                        if si + 1 >= g_borrow_count { break; }
                        w64(g_borrow_vars, si * 8, r64(g_borrow_vars, (si + 1) * 8));
                        w64(g_borrow_refs, si * 8, r64(g_borrow_refs, (si + 1) * 8));
                        w64(g_borrow_muts, si * 8, r64(g_borrow_muts, (si + 1) * 8));
                        si = si + 1;
                    }
                    g_borrow_count = g_borrow_count - 1;
                }
            }
        }
    }
}

fn push_unsafe_scope() { g_unsafe_depth = g_unsafe_depth + 1; }
fn pop_unsafe_scope()  { if g_unsafe_depth > 0 { g_unsafe_depth = g_unsafe_depth - 1; } }

fn record_borrow_holder(borrower_ni: int, borrowed_ni: int, is_mut: int) {
    grow_holder(g_holder_count + 1);
    w64(g_holder_borrowers, g_holder_count * 8, borrower_ni);
    w64(g_holder_borrowed, g_holder_count * 8, borrowed_ni);
    w64(g_holder_is_mut, g_holder_count * 8, is_mut);
    g_holder_count = g_holder_count + 1;
}

fn borrow_var_name(node: int) -> int {
    if node < 0 { return -1; }
    if ast_kind(node) == EXPR_IDENT { return ast_int_val(node); }
    return -1;
}

// --- Type resolution utilities ---

fn res_type_node(node: int) -> int {
    if node < 0 { return TI_UNIT; }
    if ast_kind(node) == 0 {
        // Base type node: type_val = TY_*
        tv := ast_type_val(node);
        if tv == TY_INT { return TI_INT; }
        if tv == TY_DEX { return TI_DEX; }
        if tv == TY_BOOL { return TI_BOOL; }
        if tv == TY_STRING { return TI_STR; }
        if tv == TY_UNIT { return TI_UNIT; }
        if tv == TY_NEVER { return TI_NEVER; }
        if tv == TY_CHAR { return TI_CHAR; }
        if tv == TI_DYN { return TI_DYN; }
        return TI_UNIT;
    }
    if ast_kind(node) == EXPR_IDENT {
        // Named type: int_val = name string index
        name_idx := ast_int_val(node);
        si := find_gsym(name_idx);
        if si >= 0 && sym_kind(si) == SYM_TYPE {
            return sym_type(si);
        }
        // Create named type entry
        return alloc_type(TYP_NAMED, name_idx, 0);
    }
    if ast_kind(node) == EXPR_ARRAY {
        // 表示层概念（2026-09-10 语言面收窄裁决 §1）：`[T; N]` 的类型构造器身份已退役——
        // 语义归处 = product（N 元聚合）/ 序列接口 + 长度 where（N 长序列）/ F11 图（长度事实，
        // 可表达依赖长度）。本语法保留为「内联容量存储」表示提示（映射参数层，与 hw-map 同层；
        // 随实例选择生效或退化，非经典范式映射可忽略）。见
        // docs/superpowers/specs/2026-09-10-language-surface-narrowing-design.md §1
        // Array type [T; N] or slice type [T] (size 0)
        elem := res_type_node(ast_a(node));
        sz := ast_int_val(node);
        if sz == 0 {
            return alloc_type(TYP_SLICE, elem, 0);
        }
        return alloc_type(TYP_ARRAY, elem, sz);
    }
    if ast_kind(node) == EXPR_REFTYPE {
        // Reference type &T or &mut T
        inner := res_type_node(ast_a(node));
        mut_flag := ast_int_val(node);
        return alloc_type(TYP_REF, inner, mut_flag);
    }
    if ast_kind(node) == EXPR_PTRTYPE {
        // Pointer type *T
        inner := res_type_node(ast_a(node));
        return alloc_type(TYP_PTR, inner, 0);
    }
    if ast_kind(node) == EXPR_GENERIC_APPLY {
        // Generic application: Box[int]
        name_idx := ast_a(node);
        first_arg_node := ast_b(node);
        arg_count := ast_c(node);
        si := find_gsym(name_idx);
        if si < 0 || sym_kind(si) != SYM_TYPE {
            check_error(EC_N_GENERIC_TYPE, "Undefined type in generic application", ast_line(node), ast_col(node));
            return TI_UNIT;
        }
        base_ti := sym_type(si);
        // Store args in g_gen_apply_data: [count, arg1, arg2, ...]
        data_start := g_gen_apply_data_count;
        grow_gen_apply_data(data_start + 1 + arg_count);
        w64(g_gen_apply_data, data_start * 8, arg_count);
        g_gen_apply_data_count = data_start + 1;
        ai : ., mut = 0;
        an : ., mut = first_arg_node;
        loop {
            if ai >= arg_count { break; }
            arg_ti := res_type_node(an);
            w64(g_gen_apply_data, (data_start + 1 + ai) * 8, arg_ti);
            ai = ai + 1;
            an = an + 1;
        }
        g_gen_apply_data_count = data_start + 1 + arg_count;
        return alloc_type(TYP_GENERIC_APPLY, base_ti, data_start);
    }
    return TI_UNIT;
}

fn find_struct(name_idx: int) -> int {
    i : ., mut = 0;
    loop {
        if i >= g_struct_count { return -1; }
        if si_name(i) == name_idx { return i; }
        i = i + 1;
    }
    return -1;
}

fn find_enum(name_idx: int) -> int {
    i : ., mut = 0;
    loop {
        if i >= g_enum_count { return -1; }
        if ei_name(i) == name_idx { return i; }
        i = i + 1;
    }
    return -1;
}

fn find_iface(name_ni: int) -> int {
    i : ., mut = 0;
    loop {
        if i >= g_iface_count { return -1; }
        if r64(g_ifaces, i * ESZ_IFACEINFO + OFF_IF_NAME) == name_ni { return i; }
        i = i + 1;
    }
    return -1;
}

fn get_type_name(ti: int) -> int {
    k := get_type_kind(ti);
    if k == TYP_NAMED { return get_type_data(ti); }
    if k == TYP_BASE {
        d := get_type_data(ti);
        if d == TY_INT { return str_intern("int"); }
        if d == TY_DEX { return str_intern("dex"); }
        if d == TY_BOOL { return str_intern("bool"); }
        if d == TY_STRING { return str_intern("string"); }
        if d == TY_UNIT { return str_intern("unit"); }
        if d == TY_CHAR { return str_intern("char"); }
    }
    if k == TYP_GENERIC_APPLY {
        base := get_type_data(ti);
        if get_type_kind(base) == TYP_NAMED { return get_type_data(base); }
    }
    return -1;
}

fn type_has_method(type_ni: int, method_ni: int) -> bool {
    tname := istr_get(type_ni);
    mname := istr_get(method_ni);
    mangled := tname + "." + mname;
    mangled_ni := str_intern(mangled);
    return find_func(mangled_ni) >= 0;
}

fn check_iface(type_ni: int, iface_ii: int) -> bool {
    method_count := r64(g_ifaces, iface_ii * ESZ_IFACEINFO + OFF_IF_METHOD_COUNT);
    mi : ., mut = 0;
    loop {
        if mi >= method_count { return true; }
        mbase2 := iface_ii * ESZ_IFACEINFO + OFF_IF_METHODS + mi * ESZ_IFMETHOD;
        method_ni := r64(g_ifaces, mbase2 + OFF_IFM_NAME);
        if !type_has_method(type_ni, method_ni) { return false; }
        // Also verify param count and return type match
        tname2 := istr_get(type_ni);
        mname2 := istr_get(method_ni);
        mangled2 := tname2 + "." + mname2;
        mangled_ni2 := str_intern(mangled2);
        fi2 := find_func(mangled_ni2);
        if fi2 >= 0 {
            iface_pc := r64(g_ifaces, mbase2 + OFF_IFM_PARAM_COUNT);
            if fi_param_count(fi2) != iface_pc { return false; }
            iface_rt := r64(g_ifaces, mbase2 + OFF_IFM_RET_TI);
            if fi_return_type(fi2) != iface_rt { return false; }
        }
        mi = mi + 1;
    }
    return true;
}

// --- First pass: collect all declarations ---

fn collect_decls() {
    i : ., mut = 0;
    // First: register all struct types
    loop {
        if i >= g_struct_count { break; }
        name_idx := si_name(i);
        type_idx := alloc_type(TYP_NAMED, name_idx, 0);
        def_sym(name_idx, SYM_TYPE, type_idx, -1);
        i = i + 1;
    }
    // Resolve struct field types now that all struct names are registered
    i = 0;
    loop {
        if i >= g_struct_count { break; }
        j : ., mut = 0;
        loop {
            if j >= si_field_count(i) { break; }
            // Field types were stored by parser as unpack_type() results (TY_* or 0)
            // We need to resolve them — but they're stored as ints, not nodes.
            // For now, leave as-is; fields are resolved during type inference.
            j = j + 1;
        }
        i = i + 1;
    }
    // Register struct generic params for type resolution
    i = 0;
    loop {
        if i >= g_struct_count { break; }
        gc := si_generic_count(i);
        if gc > 0 {
            gj : ., mut = 0;
            loop {
                if gj >= gc { break; }
                gname_ni := si_generic_name(i, gj);
                g_ti := alloc_type(TYP_GENERIC_PARAM, gname_ni, 0);
                grow_gen_params(g_gen_param_count + 2);
                w64(g_gen_params, g_gen_param_count * 8, gname_ni);
                w64(g_gen_params, (g_gen_param_count + 1) * 8, g_ti);
                g_gen_param_count = g_gen_param_count + 2;
                def_sym(gname_ni, SYM_TYPE, g_ti, -1);
                gj = gj + 1;
            }
        }
        i = i + 1;
    }
    // Register all interface types
    i = 0;
    loop {
        if i >= g_iface_count { break; }
        name_idx := r64(g_ifaces, i * ESZ_IFACEINFO + OFF_IF_NAME);
        type_idx := alloc_type(TYP_NAMED, name_idx, 0);
        def_sym(name_idx, SYM_TYPE, type_idx, -1);
        i = i + 1;
    }
    // Register built-in Option type (for T? desugaring)
    option_found : ., mut = 0;
    i = 0;
    loop {
        if i >= g_enum_count { break; }
        if ei_name(i) == str_intern("Option") { option_found = 1; }
        i = i + 1;
    }
    if option_found == 0 {
        // Auto-register Option as a generic built-in type
        option_name_idx := str_intern("Option");
        option_ti := alloc_type(TYP_NAMED, option_name_idx, 0);
        def_sym(option_name_idx, SYM_TYPE, option_ti, -1);
    }

    // Register all enum types and their variant constructors
    i = 0;
    loop {
        if i >= g_enum_count { break; }
        name_idx := ei_name(i);
        type_idx := alloc_type(TYP_NAMED, name_idx, 0);
        def_sym(name_idx, SYM_TYPE, type_idx, -1);
        // Register each variant as a function returning the enum type
        vi : ., mut = 0;
        loop {
            if vi >= ei_variant_count(i) { break; }
            vname_idx := ei_variant_name(i, vi);
            def_sym(vname_idx, SYM_FN, type_idx, -1);
            vi = vi + 1;
        }
        i = i + 1;
    }

    // Register enum generic params for type resolution
    i = 0;
    loop {
        if i >= g_enum_count { break; }
        gc := ei_generic_count(i);
        if gc > 0 {
            gj : ., mut = 0;
            loop {
                if gj >= gc { break; }
                gname_ni := ei_generic_name(i, gj);
                g_ti := alloc_type(TYP_GENERIC_PARAM, gname_ni, 0);
                grow_gen_params(g_gen_param_count + 2);
                w64(g_gen_params, g_gen_param_count * 8, gname_ni);
                w64(g_gen_params, (g_gen_param_count + 1) * 8, g_ti);
                g_gen_param_count = g_gen_param_count + 2;
                def_sym(gname_ni, SYM_TYPE, g_ti, -1);
                gj = gj + 1;
            }
        }
        i = i + 1;
    }

    // Register type aliases
    i = 0;
    loop {
        if i >= g_type_alias_count { break; }
        name_idx := r64(g_type_aliases, i * 16);
        type_node := r64(g_type_aliases, i * 16 + 8);
        ti := res_type_node(type_node);
        def_sym(name_idx, SYM_TYPE, ti, -1);
        i = i + 1;
    }

    // Register all functions
    i = 0;
    loop {
        if i >= g_func_count { break; }
        name_idx := fi_name(i);
        fn_node := fi_ast_node(i);
        hotpatch_ver := ast_int_val(fn_node) / 256;
        rt := fi_return_type(i);
        rt_ti := TI_UNIT;
        // For generic functions, skip return type resolution (depends on call site)
        if fi_generic_count(i) > 0 {
            rt_ti = TI_UNIT;
            // Register function generic params for type resolution
            gj : ., mut = 0;
            loop {
                if gj >= fi_generic_count(i) { break; }
                gname_ni := fi_generic_name(i, gj);
                g_ti := alloc_type(TYP_GENERIC_PARAM, gname_ni, 0);
                grow_gen_params(g_gen_param_count + 2);
                w64(g_gen_params, g_gen_param_count * 8, gname_ni);
                w64(g_gen_params, (g_gen_param_count + 1) * 8, g_ti);
                g_gen_param_count = g_gen_param_count + 2;
                def_sym(gname_ni, SYM_TYPE, g_ti, -1);
                gj = gj + 1;
            }
        } else {
            type_node := ast_type_val(fn_node);
            if type_node > 0 && ast_kind(type_node) != 0 {
                rt_ti = res_type_node(type_node);
            } else if rt == TY_INT { rt_ti = TI_INT; }
            else if rt == TY_DEX { rt_ti = TI_DEX; }
            else if rt == TY_BOOL { rt_ti = TI_BOOL; }
            else if rt == TY_STRING { rt_ti = TI_STR; }
            else if rt == TY_UNIT { rt_ti = TI_UNIT; }
        }
        if hotpatch_ver > 0 {
            // @hotpatch function: register with mangled name fn_name.vN
            fn_name_str := istr_get(name_idx);
            mangled_name := fn_name_str + ".v" + int_str(hotpatch_ver);
            mangled_ni := str_intern(mangled_name);
            def_sym(mangled_ni, SYM_FN, rt_ti, fn_node);

            // Verify signature matches the first version
            fj : ., mut = 0;
            loop {
                if fj >= i { break; }
                if fi_name(fj) == name_idx {
                    first_fn := fi_ast_node(fj);
                    first_rt := fi_return_type(fj);
                    first_rt_ti := TI_UNIT;
                    type_node2 := ast_type_val(first_fn);
                    if type_node2 > 0 && ast_kind(type_node2) != 0 {
                        first_rt_ti = res_type_node(type_node2);
                    } else if first_rt == TY_INT { first_rt_ti = TI_INT; }
                    else if first_rt == TY_DEX { first_rt_ti = TI_DEX; }
                    else if first_rt == TY_BOOL { first_rt_ti = TI_BOOL; }
                    else if first_rt == TY_STRING { first_rt_ti = TI_STR; }
                    else if first_rt == TY_UNIT { first_rt_ti = TI_UNIT; }

                    if !type_equal(rt_ti, first_rt_ti) {
                        check_error(EC_TF_RETURN, "Hotpatch return type mismatch for '" + fn_name_str + "'", ast_line(fn_node), ast_col(fn_node));
                    }
                    first_pc := fi_param_count(fj);
                    cur_pc := fi_param_count(i);
                    if first_pc != cur_pc {
                        check_error(EC_N_DUPLICATE, "Hotpatch parameter count mismatch for '" + fn_name_str + "'", ast_line(fn_node), ast_col(fn_node));
                    }
                    break;
                }
                fj = fj + 1;
            }

            // Also register original name for call resolution (latest version wins)
            def_sym(name_idx, SYM_FN, rt_ti, fn_node);
        } else {
            // Normal function: check for duplicates (allow if existing is @hotpatch)
            existing_si := find_gsym(name_idx);
            if existing_si >= 0 && sym_kind(existing_si) == SYM_FN {
                existing_node := sym_node(existing_si);
                existing_is_hotpatch : ., mut = 0;
                if existing_node >= 0 && ast_kind(existing_node) == EXPR_FN {
                    existing_is_hotpatch = ast_int_val(existing_node) / 256;
                }
                if existing_is_hotpatch == 0 {
                    fn_name_str := istr_get(name_idx);
                    check_error(EC_N_DUPLICATE, "Duplicate function definition '" + fn_name_str + "'", ast_line(fn_node), ast_col(fn_node));
                }
            }
            def_sym(name_idx, SYM_FN, rt_ti, fn_node);
        }
        fi_set_ispure(i, 1);  // optimistic: all functions are pure
        i = i + 1;
    }
    // Register extern function declarations (EXPR_EXTERN nodes not yet in g_funcs)
    ei : ., mut = 0;
    loop {
        if ei >= g_ast_count { break; }
        if ast_kind(ei) == EXPR_EXTERN {
            name_ni := ast_a(ei);
            first_param := ast_b(ei);
            param_count := ast_c(ei);
            ret_type := ast_type_val(ei);

            // Resolve return type to type index
            rt_ti : ., mut = TI_UNIT;
            if ret_type == TY_INT { rt_ti = TI_INT; }
            else if ret_type == TY_DEX { rt_ti = TI_DEX; }
            else if ret_type == TY_BOOL { rt_ti = TI_BOOL; }
            else if ret_type == TY_STRING { rt_ti = TI_STR; }
            else if ret_type == TY_UNIT { rt_ti = TI_UNIT; }
            else if ret_type == TY_CHAR { rt_ti = TI_CHAR; }

            // Register in symbol table (skip if duplicate)
            if find_gsym(name_ni) < 0 {
                def_sym(name_ni, SYM_FN, rt_ti, ei);
            }

            // Register in g_funcs for backend codegen and linking
            func_idx := g_func_count;
            grow_funcs(func_idx + 1);
            fi_set_name(func_idx, name_ni);
            fi_set_param_count(func_idx, param_count);
            fi_set_return_type(func_idx, ret_type);
            fi_set_ast_node(func_idx, ei);
            fi_set_generic_count(func_idx, 0);
            fi_set_ispure(func_idx, 1);  // optimistic: extern functions are pure
            g_func_count = func_idx + 1;
        }
        ei = ei + 1;
    }
    // Register all global variables
    i = 0;
    loop {
        if i >= g_global_let_count { break; }
        node := r64(g_global_lets, i * 8);
        name_idx := ast_a(node);  // EXPR_LET: a = name idx
        type_node := ast_b(node);  // EXPR_LET: b = type node (-1 if none)
        ti := TI_UNIT;
        if type_node >= 0 { ti = res_type_node(type_node); }
        def_sym(name_idx, SYM_GLOBAL, ti, node);
        i = i + 1;
    }
    // Register module aliases (from imports)
    mi : ., mut = 0;
    loop {
        if mi >= g_mod_count { break; }
        alias_ni := r64(g_mods, mi * 24);
        fileid_ni := r64(g_mods, mi * 24 + 8);
        def_sym(alias_ni, SYM_MODULE, fileid_ni, -1);
        mi = mi + 1;
    }
    // Register mod path declarations (mod foo::bar;)
    pi : ., mut = 0;
    loop {
        if pi >= g_mod_path_count { break; }
        mpn := r64(g_mod_path_names, pi * 8);
        def_sym(mpn, SYM_MODULE, mpn, -1);
        pi = pi + 1;
    }
    // Build module function lookup table for qualified access (e.g., mymath.add)
    main_fni : ., mut = 0;
    if g_file_count > 0 { main_fni = r64(g_files, 0); }
    g_mod_func_count = 0; g_mod_func_cap = 0;
    fi : ., mut = 0;
    loop {
        if fi >= g_func_count { break; }
        fn_node := fi_ast_node(fi);
        fn_line := ast_line(fn_node);
        if fn_line > 0 && fn_line <= g_line_count {
            fileid_ni := r64(g_line_fileid, (fn_line - 1) * 8);
            if fileid_ni != main_fni && fileid_ni != 0 && g_line_count > 0 {
                grow_mod_funcs(g_mod_func_count + 1);
                w64(g_mod_func_fileids, g_mod_func_count * 8, fileid_ni);
                w64(g_mod_func_names, g_mod_func_count * 8, fi_name(fi));
                fn_si := find_sym(fi_name(fi));
                if fn_si >= 0 {
                    w64(g_mod_func_tis, g_mod_func_count * 8, sym_type(fn_si));
                }
                g_mod_func_count = g_mod_func_count + 1;
            }
        }
        fi = fi + 1;
    }
}

// --- Generic type inference helpers ---

fn is_func_generic(fi: int, name_idx: int) -> bool {
    if fi < 0 || fi >= g_func_count { return false; }
    gi : ., mut = 0;
    loop {
        if gi >= fi_generic_count(fi) { return false; }
        if r64(g_funcs, fi * ESZ_FUNCINFO + OFF_FI_GENERIC_NAMES + gi * 8) == name_idx { return true; }
        gi = gi + 1;
    }
    return false;
}

fn find_func(name_idx: int) -> int {
    i : ., mut = 0;
    loop {
        if i >= g_func_count { return -1; }
        if fi_name(i) == name_idx { return i; }
        i = i + 1;
    }
    return -1;
}

fn is_struct_generic(si: int, name_idx: int) -> bool {
    if si < 0 || si >= g_struct_count { return false; }
    gi : ., mut = 0;
    loop {
        if gi >= si_generic_count(si) { return false; }
        if si_generic_name(si, gi) == name_idx { return true; }
        gi = gi + 1;
    }
    return false;
}

fn find_struct_by_name(name_idx: int) -> int {
    i : ., mut = 0;
    loop {
        if i >= g_struct_count { return -1; }
        if si_name(i) == name_idx { return i; }
        i = i + 1;
    }
    return -1;
}

fn res_call_type(node: int, func_fi: int) -> int {
    // Resolve a type node for call inference, treating generic params as TYP_GENERIC_PARAM
    if node < 0 { return TI_UNIT; }
    if ast_kind(node) == 0 {
        tv := ast_type_val(node);
        if tv == TY_INT { return TI_INT; }
        if tv == TY_DEX { return TI_DEX; }
        if tv == TY_BOOL { return TI_BOOL; }
        if tv == TY_STRING { return TI_STR; }
        if tv == TY_UNIT { return TI_UNIT; }
        if tv == TY_CHAR { return TI_CHAR; }
        if tv == TI_DYN { return TI_DYN; }
        return TI_UNIT;
    }
    if ast_kind(node) == EXPR_IDENT {
        name_idx := ast_int_val(node);
        if is_func_generic(func_fi, name_idx) {
            return alloc_type(TYP_GENERIC_PARAM, name_idx, 0);
        }
        // Regular named type
        si := find_gsym(name_idx);
        if si >= 0 && sym_kind(si) == SYM_TYPE { return sym_type(si); }
        return alloc_type(TYP_NAMED, name_idx, 0);
    }
    if ast_kind(node) == EXPR_GENERIC_APPLY {
        name_idx := ast_a(node);
        first_an := ast_b(node);
        ac := ast_c(node);
        si := find_gsym(name_idx);
        if si < 0 || sym_kind(si) != SYM_TYPE { return TI_UNIT; }
        base_ti := sym_type(si);
        ds := g_gen_apply_data_count;
        grow_gen_apply_data(ds + 1 + ac);
        w64(g_gen_apply_data, ds * 8, ac);
        g_gen_apply_data_count = ds + 1;
        ai : ., mut = 0;
        an : ., mut = first_an;
        loop {
            if ai >= ac { break; }
            at := res_call_type(an, func_fi);
            w64(g_gen_apply_data, (ds + 1 + ai) * 8, at);
            ai = ai + 1;
            an = an + 1;
        }
        g_gen_apply_data_count = ds + 1 + ac;
        return alloc_type(TYP_GENERIC_APPLY, base_ti, ds);
    }
    if ast_kind(node) == EXPR_REFTYPE {
        inner := res_call_type(ast_a(node), func_fi);
        mf := ast_int_val(node);
        return alloc_type(TYP_REF, inner, mf);
    }
    return TI_UNIT;
}

fn unify_types(pattern: int, concrete: int) -> bool {
    if pattern == concrete { return true; }
    pk := get_type_kind(pattern);
    ck := get_type_kind(concrete);
    if pk < 0 || ck < 0 { return false; }
    if pk == TYP_GENERIC_PARAM {
        name_idx := get_type_data(pattern);
        mi : ., mut = 0;
        loop {
            if mi >= g_gen_map_count { break; }
            if r64(g_gen_map_names, mi * 8) == name_idx {
                return type_equal(r64(g_gen_map_types, mi * 8), concrete);
            }
            mi = mi + 1;
        }
        grow_gen_map(g_gen_map_count + 1);
        w64(g_gen_map_names, g_gen_map_count * 8, name_idx);
        w64(g_gen_map_types, g_gen_map_count * 8, concrete);
        g_gen_map_count = g_gen_map_count + 1;
        return true;
        return false;
    }
    if pk == TYP_GENERIC_APPLY && ck == TYP_GENERIC_APPLY {
        if !type_equal(get_type_data(pattern), get_type_data(concrete)) { return false; }
        ps := get_type_extra(pattern);
        cs := get_type_extra(concrete);
        pc := r64(g_gen_apply_data, ps * 8);
        cc := r64(g_gen_apply_data, cs * 8);
        if pc != cc { return false; }
        ai : ., mut = 0;
        loop {
            if ai >= pc { break; }
            if !unify_types(r64(g_gen_apply_data, (ps + 1 + ai) * 8), r64(g_gen_apply_data, (cs + 1 + ai) * 8)) { return false; }
            ai = ai + 1;
        }
        return true;
    }
    return type_equal(pattern, concrete);
}

fn substitute_return_type(ti: int) -> int {
    // Substitute generic params using g_gen_map
    if g_gen_map_count == 0 { return ti; }
    k := get_type_kind(ti);
    if k == TYP_GENERIC_PARAM {
        name_idx := get_type_data(ti);
        mi : ., mut = 0;
        loop {
            if mi >= g_gen_map_count { break; }
            if r64(g_gen_map_names, mi * 8) == name_idx { return r64(g_gen_map_types, mi * 8); }
            mi = mi + 1;
        }
        return ti;
    }
    if k == TYP_GENERIC_APPLY {
        base := get_type_data(ti);
        start := get_type_extra(ti);
        count := r64(g_gen_apply_data, start * 8);
        new_start := g_gen_apply_data_count;
        grow_gen_apply_data(new_start + 1 + count);
        w64(g_gen_apply_data, new_start * 8, count);
        g_gen_apply_data_count = new_start + 1;
        ai : ., mut = 0;
        loop {
            if ai >= count { break; }
            sub := substitute_return_type(r64(g_gen_apply_data, (start + 1 + ai) * 8));
            w64(g_gen_apply_data, (new_start + 1 + ai) * 8, sub);
            ai = ai + 1;
        }
        g_gen_apply_data_count = new_start + 1 + count;
        return alloc_type(TYP_GENERIC_APPLY, base, new_start);
    }
    return ti;
}

fn infer_gen_call(fi: int, call_node: int, first_arg: int, arg_count: int) -> int {
    // Infer concrete types for a generic function call
    fn_node := fi_ast_node(fi);
    first_param := ast_b(fn_node);
    param_count := ast_c(fn_node);
    ret_type_node := ast_type_val(fn_node);

    g_gen_map_count = 0; g_gen_map_cap = 0;

    // First pass: infer arg types and build mapping
    pi : ., mut = 0;
    pn : ., mut = first_param;
    an : ., mut = first_arg;
    loop {
        if pi >= param_count || pi >= arg_count { break; }
        if pn < 0 || an < 0 { break; }

        orig_type_node := ast_data(pn);  // original param type node

        if orig_type_node >= 0 {
            pattern_ti := res_call_type(orig_type_node, fi);
            concrete_ti := infer_expr(ast_a(an));
            unify_types(pattern_ti, concrete_ti);
        } else {
            infer_expr(ast_a(an));
        }

        pi = pi + 1;
        pn = pn + 1;
        an = ast_b(an);  // next EXPR_ARG
    }

    // Check generic constraints (if any)
    gc := fi_generic_count(fi);
    if gc > 0 {
        gci : ., mut = 0;
        loop {
            if gci >= gc { break; }
            constr_idx := fi * MAX_GENERICS + gci;
            if constr_idx < g_generic_constr_count {
                iface_ni := r64(g_generic_constr, constr_idx * 8);
                if iface_ni >= 0 {
                    pname_ni := fi_generic_name(fi, gci);
                    concrete_ti : ., mut = -1;
                    hmi : ., mut = 0;
                    loop {
                        if hmi >= g_gen_map_count { break; }
                        if r64(g_gen_map_names, hmi * 8) == pname_ni {
                            concrete_ti = r64(g_gen_map_types, hmi * 8);
                            break;
                        }
                        hmi = hmi + 1;
                    }
                    if concrete_ti >= 0 {
                        type_ni := get_type_name(concrete_ti);
                        if type_ni >= 0 {
                            ii := find_iface(iface_ni);
                            if ii >= 0 {
                                if !check_iface(type_ni, ii) {
                                    check_error(EC_TG_BOUND, "Type '" + istr_get(type_ni) + "' does not satisfy interface '" + istr_get(iface_ni) + "'", ast_line(call_node), ast_col(call_node));
                                }
                            }
                        }
                    }
                }
            }
            gci = gci + 1;
        }
    }

    // Store concrete type name on call node for backend monomorphization
    if g_gen_map_count > 0 {
        conc_type_ni := r64(g_gen_map_types, 0 * 8);
        conc_name_ni := get_type_name(conc_type_ni);
        if conc_name_ni >= 0 {
            ast_set_int_val(call_node, conc_name_ni);
        }
    }

    // Substitute return type
    if g_gen_map_count > 0 && ret_type_node >= 0 {
        resolved_ret := res_call_type(ret_type_node, fi);
        return substitute_return_type(resolved_ret);
    }

    // Fallback: look up from symbol table
    func_ni : ., mut = ast_a(fn_node);
    si := find_gsym(func_ni);
    if si >= 0 && sym_kind(si) == SYM_FN {
        return sym_type(si);
    }
    return TI_UNIT;
}

// --- check_func with generic param scope ---

fn check_func(fi: int) {
    g_checker_current_fi = fi;
    // Reset per-function borrow state
    g_borrow_count = 0; g_borrow_cap = 0;
    g_holder_count = 0; g_holder_cap = 0;
    g_borrow_scope_depth = 0; g_borrow_scope_markers_cap = 0;
    fn_node := fi_ast_node(fi);
    // Extern functions have no body to check — skip
    if ast_kind(fn_node) == EXPR_EXTERN { return; }
    name_idx := ast_a(fn_node);  // EXPR_FN: a = name idx
    first_param := ast_b(fn_node);  // EXPR_FN: b = first param node
    param_count := ast_c(fn_node);  // EXPR_FN: c = param count
    return_type := fi_return_type(fi);  // EXPR_FN: raw return TY_*, safe from hotpatch encoding
    body := ast_data(fn_node);  // EXPR_FN: data = body node

    push_scope();
    // Register generic params if any
    if fi_generic_count(fi) > 0 {
        gi : ., mut = 0;
        loop {
            if gi >= fi_generic_count(fi) { break; }
            gname_idx := r64(g_funcs, fi * ESZ_FUNCINFO + OFF_FI_GENERIC_NAMES + gi * 8);
            g_ti := alloc_type(TYP_GENERIC_PARAM, gname_idx, 0);
            def_sym(gname_idx, SYM_TYPE, g_ti, -1);
            gi = gi + 1;
        }
    }
    // Add params to scope
    pi : ., mut = 0;
    pn : ., mut = first_param;
    loop {
        if pi >= param_count { break; }
        if pn < 0 { break; }
        pname_idx := ast_a(pn);  // EXPR_PARAM: a = name idx
        self_mode := ast_int_val(pn);  // EXPR_PARAM: int_val = self mode (0=normal, 1=self, 2=&self, 3=&mut self, -1=variadic)
        if self_mode == -1 { pi = pi + 1; pn = pn + 1; continue; }
        ti : ., mut = TI_UNIT;
        if self_mode == 0 {
            // Regular param: resolve using original type node if it's non-base (named/generic)
            orig_type_node := ast_data(pn);
            if orig_type_node >= 0 && ast_kind(orig_type_node) != 0 {
                ti = res_type_node(orig_type_node);
            } else {
                // Base type: switch on type_val (TY_*)
                ptype := ast_type_val(pn);
                if ptype == TY_INT { ti = TI_INT; }
                else if ptype == TY_DEX { ti = TI_DEX; }
                else if ptype == TY_BOOL { ti = TI_BOOL; }
                else if ptype == TY_STRING { ti = TI_STR; }
                else if ptype == TY_CHAR { ti = TI_CHAR; }
            }
        } else {
            // Self param: derive struct type from mangled function name "Struct.method"
            fn_name := istr_get(fi_name(fi));
            fn_len := str_len(fn_name);
            dot_pos : ., mut = -1;
            di : ., mut = 0;
            loop {
                if di >= fn_len { break; }
                if load8(fn_name, di) == 46 { dot_pos = di; break; }  // '.' = 46
                di = di + 1;
            }
            if dot_pos > 0 {
                struct_name := str_sub(fn_name, 0, dot_pos);
                struct_ni := str_intern(struct_name);
                si := find_gsym(struct_ni);
                if si >= 0 && sym_kind(si) == SYM_TYPE {
                    struct_ti := sym_type(si);
                    if self_mode == 1 {
                        // self by value
                        ti = struct_ti;
                    } else {
                        // &self (mode 2) or &mut self (mode 3)
                        mut_flag := 0;
                        if self_mode == 3 { mut_flag = 1; }
                        ti = alloc_type(TYP_REF, struct_ti, mut_flag);
                    }
                }
            }
        }
        def_sym(pname_idx, SYM_PARAM, ti, -1);
        pi = pi + 1;
        // Params are not contiguous — type nodes are allocated between them
        pn = pn + 1;
        loop {
            if pn >= g_ast_count { break; }
            if ast_kind(pn) == EXPR_PARAM { break; }
            pn = pn + 1;
        }
    }
    // Check body
    if body >= 0 {
        body_ti := infer_expr(body);
        ret_ti : ., mut = TI_UNIT;
        // First check for named type via the stored type node (kind != 0)
        type_node := ast_type_val(fn_node);
        if type_node > 0 && ast_kind(type_node) != 0 {
            ret_ti = res_type_node(type_node);
        } else if return_type == TY_INT { ret_ti = TI_INT; }
        else if return_type == TY_DEX { ret_ti = TI_DEX; }
        else if return_type == TY_BOOL { ret_ti = TI_BOOL; }
        else if return_type == TY_STRING { ret_ti = TI_STR; }
        else if return_type == TY_UNIT { ret_ti = TI_UNIT; }
        else if return_type == TY_CHAR { ret_ti = TI_CHAR; }
        else if return_type == TY_NEVER { ret_ti = TI_NEVER; }
        if !type_equal(body_ti, ret_ti) && body_ti != TI_NEVER {
            // Skip check if return type is generic param (can't verify at declaration)
            // Skip check for flow functions (yield instead of return)
            is_flow_fn : ., mut = 0;
            if body >= 0 && scan_for_yield(body) != 0 { is_flow_fn = 1; }
            if !is_flow_fn && get_type_kind(ret_ti) != TYP_GENERIC_PARAM {
                check_error(EC_TF_RETURN, "Function return type mismatch", ast_line(fn_node), ast_col(fn_node));
            }
        }
    }
    pop_scope();
}

fn check_impl_for() {
    pi : ., mut = 0;
    loop {
        if pi >= g_impl_for_count { break; }
        iface_ni := r64(g_impl_for, pi * 16);
        type_ni := r64(g_impl_for, pi * 16 + 8);
        // Find interface by name
        ii := find_iface(iface_ni);
        if ii < 0 {
            iface_name := istr_get(iface_ni);
            check_error(EC_N_UNDEFINED, "Undefined interface '" + iface_name + "'", 0, 0);
            pi = pi + 1;
            continue;
        }
        method_count := r64(g_ifaces, ii * ESZ_IFACEINFO + OFF_IF_METHOD_COUNT);
        mi : ., mut = 0;
        loop {
            if mi >= method_count { break; }
            mbase := ii * ESZ_IFACEINFO + OFF_IF_METHODS + mi * ESZ_IFMETHOD;
            method_ni := r64(g_ifaces, mbase + OFF_IFM_NAME);
            method_pc := r64(g_ifaces, mbase + OFF_IFM_PARAM_COUNT);
            method_rt := r64(g_ifaces, mbase + OFF_IFM_RET_TI);

            // Check if the implementing type has this method
            type_name := istr_get(type_ni);
            method_name := istr_get(method_ni);
            mangled := type_name + "." + method_name;
            mangled_ni := str_intern(mangled);

            fi := find_func(mangled_ni);
            if fi < 0 {
                check_error(EC_TF_METHOD_NOT_FOUND, "Impl missing method '" + method_name + "' for interface '" + istr_get(iface_ni) + "'", 0, 0);
                mi = mi + 1;
                continue;
            }
            // Check param count
            actual_pc := fi_param_count(fi);
            if actual_pc != method_pc {
                check_error(EC_TF_METHOD_ARG_CNT, "Param count mismatch for method '" + method_name + "': expected " + int_str(method_pc) + " got " + int_str(actual_pc), 0, 0);
            }
            // Check each param type
            pti : ., mut = 0;
            loop {
                if pti >= method_pc || pti >= 8 { break; }
                expected_pt := r64(g_ifaces, mbase + OFF_IFM_PARAM_TYPES + pti * 8);
                actual_pt := fi_param_type(fi, pti);
                if expected_pt != actual_pt {
                    pnum_str := int_str(pti + 1);
                    check_error(EC_TF_METHOD_ARG_TYP, "Param " + pnum_str + " type mismatch for method '" + method_name + "' in interface '" + istr_get(iface_ni) + "'", 0, 0);
                }
                pti = pti + 1;
            }
            // Check return type
            actual_rt := fi_return_type(fi);
            if actual_rt != method_rt {
                check_error(EC_TF_RETURN, "Return type mismatch for method '" + method_name + "' in interface '" + istr_get(iface_ni) + "'", 0, 0);
            }
            mi = mi + 1;
        }
        pi = pi + 1;
    }
}

fn check_global_let(node: int) {
    val_node := ast_c(node);  // EXPR_LET: c = value
    if val_node >= 0 {
        infer_expr(val_node);
    }
}

// --- Dynamic type set tracking ---

fn grow_dyn_type_sets(needed: int) {
    if needed < g_dyn_type_set_cap { return; }
    nc : ., mut = g_dyn_type_set_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 8); _dyncpy(g_dyn_type_sets, g_dyn_type_set_cap * 8, nb);
    g_dyn_type_sets = nb; g_dyn_type_set_cap = nc;
}

fn dyn_set_type(var_idx: int, ti: int) {
    grow_dyn_type_sets(var_idx + 1);
    old_bits := r64(g_dyn_type_sets, var_idx * 8);
    bit : ., mut = 1;
    if ti >= 0 && ti < 64 {
        bit = 1; shl := ti; loop { if shl <= 0 { break; } bit = bit * 2; shl = shl - 1; }
    }
    w64(g_dyn_type_sets, var_idx * 8, old_bits + bit);
    if var_idx >= g_dyn_type_set_count { g_dyn_type_set_count = var_idx + 1; }
}

fn dyn_has_type(var_idx: int, ti: int) -> int {
    if var_idx < 0 || var_idx >= g_dyn_type_set_count { return 0; }
    set := r64(g_dyn_type_sets, var_idx * 8);
    bit : ., mut = 1;
    if ti >= 0 && ti < 64 {
        bit = 1; shl := ti; loop { if shl <= 0 { break; } bit = bit * 2; shl = shl - 1; }
    }
    if (set / bit) % 2 != 0 { return 1; }
    return 0;
}

fn union_bitmaps(a: int, b: int) -> int {
    r : ., mut = 0;
    pos : ., mut = 0;
    loop {
        if pos >= 64 { break; }
        bit : ., mut = 1;
        shl := pos;
        loop { if shl <= 0 { break; } bit = bit * 2; shl = shl - 1; }
        if (a / bit) % 2 != 0 || (b / bit) % 2 != 0 { r = r + bit; }
        pos = pos + 1;
    }
    return r;
}

fn validate_dyn_method(si: int, method_ni: int, line: int, col: int) {
    if si < 0 || si >= g_dyn_type_set_count { return; }
    set := r64(g_dyn_type_sets, si * 8);
    if set == 0 { return; }
    ti : ., mut = 0;
    loop {
        if ti >= g_type_count { break; }
        if ti >= 64 { break; }
        bit : ., mut = 1;
        shl := ti;
        loop { if shl <= 0 { break; } bit = bit * 2; shl = shl - 1; }
        if (set / bit) % 2 != 0 {
            type_ni := get_type_name(ti);
            if type_ni >= 0 {
                if !type_has_method(type_ni, method_ni) {
                    tname := istr_get(type_ni);
                    mname := istr_get(method_ni);
                    check_error(EC_N_METHOD, "dyn: method '" + mname + "' not found on type '" + tname + "'", line, col);
                }
            }
        }
        ti = ti + 1;
    }
}

// --- Type inference ---

fn infer_expr(node: int) -> int {
    if node < 0 { return TI_UNIT; }


    if ast_kind(node) == EXPR_INT { return TI_INT; }
    if ast_kind(node) == EXPR_NONE && ast_a(node) >= 0 && ast_a(node) != node { return infer_expr(ast_a(node)); }
    if ast_kind(node) == EXPR_DEX { return TI_DEX; }
    if ast_kind(node) == EXPR_STRING { return TI_STR; }
    if ast_kind(node) == EXPR_BOOL { return TI_BOOL; }
    if ast_kind(node) == EXPR_CHAR { return TI_CHAR; }

    if ast_kind(node) == EXPR_IDENT {
        name_idx := ast_int_val(node);
        // Borrow check: can't use variable while it's borrowed
        if !check_use(name_idx) {
            name := istr_get(name_idx);
            check_error(EC_B_USE_WHILE_BORROWED, "Cannot use '" + name + "' while it is borrowed", ast_line(node), ast_col(node));
        }
        si := find_sym(name_idx);
        if si >= 0 { return sym_type(si); }
        name := istr_get(name_idx);
        check_error(EC_N_UNDEFINED, "Undefined name '" + name + "'", ast_line(node), ast_col(node));
        return TI_NEVER;
    }
    if ast_kind(node) == EXPR_NONE {
        // Wrapper node in struct literal: forward to inner expression
        if ast_a(node) >= 0 && ast_a(node) != node { return infer_expr(ast_a(node)); }
        return TI_UNIT;
    }

    if ast_kind(node) == EXPR_BINARY {
        left := ast_a(node);
        right := ast_b(node);
        op := ast_c(node);
        if op == OP_ASSIGN {
            // Assignment: left = right
            lt := infer_expr(left);
            rt := infer_expr(right);
            if !type_equal(lt, rt) {
                check_error(EC_TA_ASSIGN, "Assignment type mismatch", ast_line(node), ast_col(node));
            }
            return rt;
        }
        lt := infer_expr(left);
        rt := infer_expr(right);
        if op == OP_ADD || op == OP_SUB || op == OP_MUL || op == OP_DIV || op == OP_MOD {
            // String concatenation for OP_ADD
            if op == OP_ADD && (lt == TI_STR || rt == TI_STR) { return TI_STR; }
            // Pointer arithmetic: *T + n or n + *T → *T
            if (op == OP_ADD || op == OP_SUB) && (get_type_kind(lt) == TYP_PTR && rt == TI_INT) {
                return lt;  // return the pointer type unchanged
            }
            if (op == OP_ADD || op == OP_SUB) && (lt == TI_INT && get_type_kind(rt) == TYP_PTR) {
                return rt;
            }
            // Pointer difference: *T - *T → int
            if op == OP_SUB && get_type_kind(lt) == TYP_PTR && get_type_kind(rt) == TYP_PTR {
                return TI_INT;
            }
            // Check: arithmetic ops require int or dex
            if lt != TI_INT && lt != TI_DEX && rt != TI_INT && rt != TI_DEX {
                check_error(EC_TB_ADD, "Arithmetic operation requires int or dex", ast_line(node), ast_col(node));
            }
            if lt == TI_DEX || rt == TI_DEX { return TI_DEX; }
            return TI_INT;
        }
        if op == OP_EQ || op == OP_NE || op == OP_LT || op == OP_GT || op == OP_LE || op == OP_GE {
            return TI_BOOL;
        }
        if op == OP_AND || op == OP_OR {
            if lt != TI_BOOL && lt != TI_INT || rt != TI_BOOL && rt != TI_INT {
                check_error(EC_TC_IF_COND, "Logical operator requires bool or int operands", ast_line(node), ast_col(node));
            }
            return TI_BOOL;
        }
        return TI_INT;
    }

    if ast_kind(node) == EXPR_UNARY {
        op := ast_c(node);
        if op == UOP_NEG || op == UOP_NOT {
            return infer_expr(ast_a(node));
        }
        if op == UOP_REF {
            operand := ast_a(node);
            is_mut := ast_int_val(node);
            inner : ., mut = TI_UNIT;
            if ast_kind(operand) == EXPR_IDENT {
                vi := ast_int_val(operand);
                if !check_borrow(vi, is_mut) {
                    name := istr_get(vi);
                    if is_mut != 0 {
                        check_error(EC_B_BORROW_MUT, "Cannot borrow '" + name + "' as mutable, already borrowed", ast_line(node), ast_col(node));
                    } else {
                        check_error(EC_B_BORROW_IMMUT, "Cannot borrow '" + name + "' as immutable, already mutably borrowed", ast_line(node), ast_col(node));
                    }
                }
                si := find_sym(vi);
                if si >= 0 { inner = sym_type(si); }
            } else {
                inner = infer_expr(operand);
            }
            return alloc_type(TYP_PTR, inner, 0);
        }
        if op == UOP_DEREF {
            inner := infer_expr(ast_a(node));
            if get_type_kind(inner) == TYP_REF {
                return get_type_data(inner);
            }
            if get_type_kind(inner) == TYP_PTR {
                return get_type_data(inner);
            }
            if get_type_kind(inner) == TYP_GENERIC_PARAM {
                return inner;
            }
            return inner;
        }
        return infer_expr(ast_a(node));
    }

    if ast_kind(node) == EXPR_CALL {
        func_node := ast_a(node);
        first_arg := ast_b(node);
        arg_count := ast_c(node);
        func_ni : ., mut = -1;

        // Method call: obj.method(args)  or  module.func(args)
        if ast_kind(func_node) == EXPR_FIELD {
            obj := ast_a(func_node);
            method_ni := ast_int_val(func_node);

            // Module-qualified call: module.func(args)
            mod_call_done : ., mut = 0;
            mod_found_mfi : ., mut = -1;
            if ast_kind(obj) == EXPR_IDENT {
                mod_name_ni := ast_int_val(obj);
                si := find_sym(mod_name_ni);
                if si >= 0 && sym_kind(si) == SYM_MODULE {
                    fileid_ni := sym_type(si);
                    // Look up (fileid, method) in module function table
                    mfi : ., mut = 0;
                    loop {
                        if mfi >= g_mod_func_count { break; }
                        if r64(g_mod_func_fileids, mfi * 8) == fileid_ni && r64(g_mod_func_names, mfi * 8) == method_ni {
                            func_ni = r64(g_mod_func_names, mfi * 8);
                            ast_set_data(node, func_ni);
                            call_flags := ast_type_val(node);
                            if call_flags == CALL_FLAG_INLINE {
                                ast_set_type_val(node, CALL_FLAG_MODULE + CALL_FLAG_INLINE);
                            } else {
                                ast_set_type_val(node, CALL_FLAG_MODULE);
                            }
                            mod_call_done = 1;
                            mod_found_mfi = mfi;
                            break;
                        }
                        mfi = mfi + 1;
                    }
                }
            }
            if mod_call_done == 1 {
                // Infer arg types
                an : ., mut = first_arg;
                loop {
                    if an < 0 { break; }
                    infer_expr(ast_a(an));
                    an = ast_b(an);
                }
                if mod_found_mfi >= 0 {
                    return r64(g_mod_func_tis, mod_found_mfi * 8);
                }
                return TI_UNIT;
            }

            obj_ti := infer_expr(obj);
            // --- Dyn method validation ---
            if obj_ti == TI_DYN {
                if ast_kind(obj) == EXPR_IDENT {
                    obj_ni := ast_int_val(obj);
                    obj_si := find_sym(obj_ni);
                    if obj_si >= 0 {
                        validate_dyn_method(obj_si, method_ni, ast_line(node), ast_col(node));
                    }
                }
                // Infer arg types (for side effects)
                an_dyn : ., mut = first_arg;
                loop {
                    if an_dyn < 0 { break; }
                    infer_expr(ast_a(an_dyn));
                    an_dyn = ast_b(an_dyn);
                }
                return TI_UNIT;
            }
            lookup_ti : ., mut = obj_ti;
            // Unwrap generic apply to base type
            if lookup_ti >= 0 && lookup_ti < g_type_count && get_type_kind(lookup_ti) == TYP_GENERIC_APPLY {
                lookup_ti = get_type_data(lookup_ti);
            }
            if lookup_ti >= 0 && lookup_ti < g_type_count && get_type_kind(lookup_ti) == TYP_NAMED {
                struct_ni := get_type_data(lookup_ti);
                // Look up method in method table
                mi : ., mut = 0;
                loop {
                    if mi >= g_method_count { break; }
                    if r64(g_methods, mi * 24) == struct_ni && r64(g_methods, mi * 24 + 8) == method_ni {
                        func_ni = r64(g_methods, mi * 24 + 16);
                        ast_set_data(node, func_ni);
                        break;
                    }
                    mi = mi + 1;
                }
            }
            // Generic param method call resolution
            if func_ni < 0 && get_type_kind(lookup_ti) == TYP_GENERIC_PARAM {
                gen_ni := get_type_data(lookup_ti);
                gc2 := fi_generic_count(g_checker_current_fi);
                gci2 : ., mut = 0;
                loop {
                    if gci2 >= gc2 { break; }
                    gname_idx2 := r64(g_funcs, g_checker_current_fi * ESZ_FUNCINFO + OFF_FI_GENERIC_NAMES + gci2 * 8);
                    if gname_idx2 == gen_ni {
                        constr_idx2 := g_checker_current_fi * MAX_GENERICS + gci2;
                        if constr_idx2 < g_generic_constr_count {
                            iface_ni2 := r64(g_generic_constr, constr_idx2 * 8);
                            if iface_ni2 >= 0 {
                                ii2 := find_iface(iface_ni2);
                                if ii2 >= 0 {
                                    imc2 := r64(g_ifaces, ii2 * ESZ_IFACEINFO + OFF_IF_METHOD_COUNT);
                                    imi2 : ., mut = 0;
                                    loop {
                                        if imi2 >= imc2 { break; }
                                        imbase2 := ii2 * ESZ_IFACEINFO + OFF_IF_METHODS + imi2 * ESZ_IFMETHOD;
                                        if r64(g_ifaces, imbase2 + OFF_IFM_NAME) == method_ni {
                                            tname2 := istr_get(gen_ni);
                                            mname2 := istr_get(method_ni);
                                            mangled2 := tname2 + "." + mname2;
                                            mangled_ni2 := str_intern(mangled2);
                                            ast_set_data(node, mangled_ni2);
                                            iface_ret2 := r64(g_ifaces, imbase2 + OFF_IFM_RET_TI);
                                            if iface_ret2 == TY_INT { func_ni = mangled_ni2; return TI_INT; }
                                            if iface_ret2 == TY_DEX { func_ni = mangled_ni2; return TI_DEX; }
                                            if iface_ret2 == TY_BOOL { func_ni = mangled_ni2; return TI_BOOL; }
                                            if iface_ret2 == TY_STRING { func_ni = mangled_ni2; return TI_STR; }
                                            if iface_ret2 == TY_UNIT { func_ni = mangled_ni2; return TI_UNIT; }
                                            if iface_ret2 == TY_CHAR { func_ni = mangled_ni2; return TI_CHAR; }
                                            func_ni = mangled_ni2; return TI_UNIT;
                                        }
                                        imi2 = imi2 + 1;
                                    }
                                }
                            }
                        }
                        break;
                    }
                    gci2 = gci2 + 1;
                }
            }
            // Infer arg types (walk EXPR_ARG chain)
            an : ., mut = first_arg;
            loop {
                if an < 0 { break; }
                infer_expr(ast_a(an));
                an = ast_b(an);
            }
            if func_ni >= 0 {
                si := find_gsym(func_ni);
                if si >= 0 && sym_kind(si) == SYM_FN {
                    return sym_type(si);
                }
            }
            return TI_UNIT;
        }

        // Determine function name and return type
        if ast_kind(func_node) == EXPR_IDENT {
            func_ni = ast_int_val(func_node);
        }
        // @builtin(args) — transfer args from EXPR_CALL to EXPR_AT, then delegate
        if ast_kind(func_node) == EXPR_AT {
            ast_set_b(func_node, first_arg);
            return infer_expr(func_node);
        }
        // Check builtins (syscall3/syscall4 — OS communication, no .cr body)
        if func_ni >= 0 {
            s := istr_get(func_ni);
            if s == "syscall3" { return TI_INT; }
            if s == "syscall4" { return TI_INT; }
        }
        // Check for SYM_SO_FN (.so extension registered)
        so_fn_fi : ., mut = -1;
        if func_ni >= 0 {
            si := find_gsym(func_ni);
            if si >= 0 && sym_kind(si) == SYM_SO_FN {
                so_fn_fi = si;
                tag_flags2 := sym_type(si);  // stores tag_flags
                type_enc2 := sym_node(si);   // stores type encoding

                // Infer arg types (walk EXPR_ARG chain)
                an : ., mut = first_arg;
                loop {
                    if an < 0 { break; }
                    infer_expr(ast_a(an));
                    an = ast_b(an);
                }

                // Decode return type (type_enc2 % 100)
                ret_code2 : ., mut = type_enc2 - (type_enc2 / 100) * 100;
                // Map back to TI_*
                if ret_code2 == 0 { return TI_INT; }
                if ret_code2 == 1 { return TI_STR; }
                if ret_code2 == 2 { return TI_UNIT; }
                if ret_code2 == 3 { return TI_DEX; }
                if ret_code2 == 4 { return TI_BOOL; }
                return TI_UNIT;
            }
        }
        // Look up function
        if func_ni >= 0 && so_fn_fi < 0 {
            si := find_gsym(func_ni);
            if si >= 0 && sym_kind(si) == SYM_FN {
                // Check if generic function
                fi := find_func(func_ni);
                if fi >= 0 && fi_generic_count(fi) > 0 {
                    return infer_gen_call(fi, node, first_arg, arg_count);
                }
                return sym_type(si);  // return type
            }
            // Check runtime builtins (no .cr body, implemented in rt.s)
            bi : ., mut = 0;
            loop {
                if bi >= g_rt_builtin_count { break; }
                if r64(g_rt_builtin_names, bi * 8) == func_ni {
                    return r64(g_rt_builtin_ret_types, bi * 8);
                }
                bi = bi + 1;
            }
            // Not found in symbol table or builtins — report error
            name := istr_get(func_ni);
            check_error(EC_N_FUNC, "Undefined function '" + name + "'", ast_line(node), ast_col(node));
            return TI_NEVER;
        }
        // Infer arg types (for side effects)
        an : ., mut = first_arg;
        loop {
            if an < 0 { break; }
            infer_expr(ast_a(an));
            an = ast_b(an);
        }
        return TI_INT;  // external/unknown functions
    }

    if ast_kind(node) == EXPR_BLOCK {
        stmt_start := ast_a(node);
        stmt_count := ast_b(node);
        res : ., mut = TI_UNIT;
        push_borrow_scope();
        i : ., mut = 0;
        loop {
            if i >= stmt_count { break; }
            sn := r64(g_block_stmts, (stmt_start + i) * 8);
            res = infer_expr(sn);
            i = i + 1;
        }
        // Track the last-statement type for debugging
        // (no operation needed — res is already the last type)
        pop_borrow_scope();
        return res;
    }

    if ast_kind(node) == EXPR_IF {
        cond := ast_a(node);
        then_node := ast_b(node);
        else_node := ast_c(node);
        cond_ti := infer_expr(cond);
        // Accept int as truthy/falsy in conditions (not just strict bool)
        if cond_ti != TI_BOOL && cond_ti != TI_INT {
            check_error(EC_TC_IF_COND, "If condition must be bool or int", ast_line(node), ast_col(node));
        }
        // --- Dyn type set merge: save pre-if state ---
        pre_dyn_count : ., mut = g_dyn_type_set_count;
        pre_dyn_save : string, mut = "";
        if pre_dyn_count > 0 {
            pre_dyn_save = alloc(pre_dyn_count * 8);
            _dyncpy(g_dyn_type_sets, pre_dyn_count * 8, pre_dyn_save);
        }
        // --- Process then branch ---
        push_borrow_scope();
        then_ti := infer_expr(then_node);
        pop_borrow_scope();
        // --- Save then-branch dyn state ---
        then_dyn_count : ., mut = g_dyn_type_set_count;
        then_dyn_save : string, mut = "";
        if then_dyn_count > 0 {
            then_dyn_save = alloc(then_dyn_count * 8);
            _dyncpy(g_dyn_type_sets, then_dyn_count * 8, then_dyn_save);
        }
        // --- Restore pre-if state (zero stale entries beyond pre_dyn_count) ---
        g_dyn_type_set_count = pre_dyn_count;
        if pre_dyn_count > 0 {
            _dyncpy(pre_dyn_save, pre_dyn_count * 8, g_dyn_type_sets);
        }
        iz : ., mut = pre_dyn_count;
        loop {
            if iz >= then_dyn_count { break; }
            w64(g_dyn_type_sets, iz * 8, 0);
            iz = iz + 1;
        }
        // --- Process else branch (if any) ---
        if else_node >= 0 {
            push_borrow_scope();
            else_ti := infer_expr(else_node);
            pop_borrow_scope();
            // --- Merge dyn type sets from both branches ---
            merge_count : ., mut = then_dyn_count;
            if g_dyn_type_set_count > merge_count { merge_count = g_dyn_type_set_count; }
            grow_dyn_type_sets(merge_count);
            g_dyn_type_set_count = merge_count;
            mi : ., mut = 0;
            loop {
                if mi >= merge_count { break; }
                then_bits : ., mut = 0;
                if mi < then_dyn_count { then_bits = r64(then_dyn_save, mi * 8); }
                else_bits : ., mut = 0;
                if mi < g_dyn_type_set_count { else_bits = r64(g_dyn_type_sets, mi * 8); }
                merged := union_bitmaps(then_bits, else_bits);
                w64(g_dyn_type_sets, mi * 8, merged);
                mi = mi + 1;
            }
            g_dyn_type_set_count = merge_count;
            if !type_equal(then_ti, else_ti) && then_ti != TI_NEVER && else_ti != TI_NEVER {
                check_error(EC_TC_IF_BRANCH, "If branches have different types", ast_line(node), ast_col(node));
            }
            return then_ti;
        }
        return TI_UNIT;
    }

    if ast_kind(node) == EXPR_GO {
        // a=-1, b=body;  c=iter_ni (>=0 for range mode)
        body := ast_b(node);
        push_borrow_scope();
        body_ti := infer_expr(body);
        pop_borrow_scope();
        rn := ast_data(node);
        if rn <= 0 {
            return body_ti;  // single go: future of body type
        }
        // Range go: returns array of body type (size from data=range_node)
        range_node := ast_data(node);
        rng_count := ast_b(range_node) - ast_a(range_node);
        // 表示层概念（2026-09-10 语言面收窄裁决 §1）：`[T; N]` 退役为「内联容量存储」表示提示（语义归处 = product / 序列+长度约束 / F11）——完整注记见本文件 res_type_node 的 EXPR_ARRAY 分支处，spec 见 docs/superpowers/specs/2026-09-10-language-surface-narrowing-design.md §1
        return alloc_type(TYP_ARRAY, body_ti, rng_count);
    }

    if ast_kind(node) == EXPR_YIELD {
        val := ast_a(node);
        val_ti : ., mut = TI_UNIT;
        if val >= 0 { val_ti = infer_expr(val); }
        // In a flow, the yield type is the flow's result type; return the value type
        return val_ti;  // yield's type is the yielded value's type
    }

    if ast_kind(node) == EXPR_AWAIT {
        val := ast_a(node);
        val_ti := infer_expr(val);
        // If awaiting an array of T, return array element type T
        // If awaiting a single future, return the type directly
        if get_type_kind(val_ti) == TYP_ARRAY {
            return get_type_data(val_ti);  // await [Future<T>] → T
        }
        return val_ti;
    }

    if ast_kind(node) == EXPR_LOOP {
        push_borrow_scope();
        infer_expr(ast_a(node));
        pop_borrow_scope();
        return TI_UNIT;
    }

    if ast_kind(node) == EXPR_WHILE {
        cond := ast_a(node);
        body := ast_b(node);
        cond_ti := infer_expr(cond);
        if cond_ti != TI_BOOL {
            check_error(EC_TC_WHILE_COND, "While condition must be bool", ast_line(node), ast_col(node));
        }
        push_borrow_scope();
        infer_expr(body);
        pop_borrow_scope();
        return TI_UNIT;
    }

    if ast_kind(node) == EXPR_FOR {
        var_ni := ast_a(node);
        iter := ast_b(node);
        body := ast_c(node);
        infer_expr(iter);
        push_scope();
        push_borrow_scope();
        def_sym(var_ni, SYM_LOCAL, TI_INT, -1);
        infer_expr(body);
        pop_borrow_scope();
        pop_scope();
        return TI_UNIT;
    }

    if ast_kind(node) == EXPR_RANGE {
        st := infer_expr(ast_a(node));
        et := infer_expr(ast_b(node));
        if st != TI_INT { check_error(EC_TB_ADD, "Range start must be int", ast_line(node), ast_col(node)); }
        if et != TI_INT { check_error(EC_TB_ADD, "Range end must be int", ast_line(node), ast_col(node)); }
        return TI_INT;
    }

    if ast_kind(node) == EXPR_MATCH {
        match_expr := ast_a(node);
        first_arm := ast_b(node);
        infer_expr(match_expr);
        res : ., mut = TI_UNIT;
        ai : ., mut = 0;
        an : ., mut = first_arm;
        loop {
            if an < 0 { break; }
            arm_pat := ast_a(an);  // EXPR_ARM: a = pattern
            arm_body := ast_b(an);  // EXPR_ARM: b = body
            // Bind pattern variables in new scope
            push_scope();
            if arm_pat >= 0 {
                if ast_kind(arm_pat) == EXPR_ENUMPAT {
                    // Bind sub-patterns
                    sub_pat := ast_b(arm_pat);
                    sub_count := ast_c(arm_pat);
                    spi : ., mut = 0;
                    spn : ., mut = sub_pat;
                    loop {
                        if spi >= sub_count { break; }
                        if spn >= 0 {
                            if ast_kind(spn) == EXPR_IDENT {
                                def_sym(ast_int_val(spn), SYM_LOCAL, TI_INT, -1);
                            }
                            spn = spn + 1;
                        }
                        spi = spi + 1;
                    }
                }
                if ast_kind(arm_pat) == EXPR_IDENT {
                    def_sym(ast_int_val(arm_pat), SYM_LOCAL, TI_INT, -1);
                }
            }
            push_borrow_scope();
            arm_ti := infer_expr(arm_body);
            pop_borrow_scope();
            if ai == 0 { res = arm_ti; }
            pop_scope();
            an = ast_c(an);  // next arm via linked list
            ai = ai + 1;
        }
        return res;
    }

    if ast_kind(node) == EXPR_LET {
        var_ni := ast_a(node);
        type_node := ast_b(node);
        val_node := ast_c(node);
        val_ti := TI_UNIT;
        if val_node >= 0 {
            val_ti = infer_expr(val_node);
            // Check if value is a borrow (&x or &mut x), record the holder
            if ast_kind(val_node) == EXPR_UNARY && ast_c(val_node) == UOP_REF {
                borrowed_ni := borrow_var_name(ast_a(val_node));
                if borrowed_ni >= 0 {
                    mut_flag := ast_int_val(val_node);
                    record_borrow_holder(var_ni, borrowed_ni, mut_flag);
                }
            }
        }
        ti := val_ti;
        if type_node >= 0 { ti = res_type_node(type_node); }
        if istr_get(var_ni) != "_" {
            def_sym(var_ni, SYM_LOCAL, ti, -1);
            if ti == TI_DYN && val_node >= 0 {
                grow_dyn_type_sets(g_sym_count);
                w64(g_dyn_type_sets, (g_sym_count - 1) * 8, 0);
                dyn_set_type(g_sym_count - 1, val_ti);
            }
        }
        return TI_UNIT;
    }

    if ast_kind(node) == EXPR_RETURN {
        if ast_a(node) >= 0 {
            return infer_expr(ast_a(node));
        }
        return TI_UNIT;
    }

    if ast_kind(node) == EXPR_ENUM_CONSTRUCTOR {
        name_idx := ast_a(node);
        first_arg := ast_b(node);
        arg_count := ast_c(node);
        si := find_gsym(name_idx);
        if si >= 0 && sym_kind(si) == SYM_FN {
            // Infer arg types (walk EXPR_ARG chain)
            an : ., mut = first_arg;
            loop {
                if an < 0 { break; }
                infer_expr(ast_a(an));
                an = ast_b(an);
            }
            return sym_type(si); // enum type
        }
        name := istr_get(name_idx);
        check_error(EC_N_UNDEFINED, "Undefined enum constructor '" + name + "'", ast_line(node), ast_col(node));
        return TI_UNIT;
    }

    if ast_kind(node) == EXPR_FIELD {
        obj := ast_a(node);
        field_ni := ast_int_val(node);
        obj_ti := infer_expr(obj);
        // Auto-deref: if obj is a reference type, unwrap to inner type
        actual_ti : ., mut = obj_ti;
        if actual_ti >= 0 && actual_ti < g_type_count && get_type_kind(actual_ti) == TYP_REF {
            actual_ti = get_type_data(actual_ti);
        }
        // Handle generic apply: unwrap to base named type for struct lookup
        if actual_ti >= 0 && actual_ti < g_type_count && get_type_kind(actual_ti) == TYP_GENERIC_APPLY {
            actual_ti = get_type_data(actual_ti);
        }
        if actual_ti >= 0 && actual_ti < g_type_count && get_type_kind(actual_ti) == TYP_NAMED {
            struct_ni := get_type_data(actual_ti);
            si := find_struct(struct_ni);
            if si >= 0 {
                fi : ., mut = 0;
                loop {
                    if fi >= si_field_count(si) { break; }
                    if si_field_name(si, fi) == field_ni {
                        ast_set_data(node, fi);  // store field index for ir_gen
                        ast_set_c(node, struct_ni);  // store struct name for ELF backend
                        // Resolve field type, substituting generic params if needed
                        ft_node := si_field_type_node(si, fi);
                        if ft_node >= 0 {
                            if ast_kind(ft_node) == EXPR_IDENT {
                                ft_name_idx := ast_int_val(ft_node);
                                // Check if this field type is a generic param (substitute if we have a generic apply)
                                if is_struct_generic(si, ft_name_idx) && get_type_kind(obj_ti) == TYP_GENERIC_APPLY {
                                        base_ti := get_type_data(obj_ti);
                                        ga_start := get_type_extra(obj_ti);
                                        ga_count := r64(g_gen_apply_data, ga_start * 8);
                                        // Find which generic param index
                                        gpi : ., mut = 0;
                                        loop {
                                            if gpi >= si_generic_count(si) { break; }
                                            if si_generic_name(si, gpi) == ft_name_idx {
                                                // Use the corresponding arg from the generic apply
                                                if gpi < ga_count {
                                                    return r64(g_gen_apply_data, (ga_start + 1 + gpi) * 8);
                                                }
                                                break;
                                            }
                                            gpi = gpi + 1;
                                        }
                                }
                            }
                            return res_type_node(ft_node);
                        }
                        return si_field_type(si, fi);
                    }
                    fi = fi + 1;
                }
            }
        }
        // Tuple field access: t.0, t.1
        if actual_ti >= 0 && actual_ti < g_type_count && get_type_kind(actual_ti) == TYP_TUPLE {
            field_name := istr_get(field_ni);
            idx := str_int(field_name);
            tc := get_type_data(actual_ti);
            if idx >= 0 && idx < tc {
                data_start := get_type_extra(actual_ti);
                if ast_data(node) != idx {
                    ast_set_data(node, idx);
                }
                return r64(g_gen_apply_data, (data_start + idx) * 8);
            }
        }
        return TI_UNIT;
    }

    if ast_kind(node) == EXPR_INDEX {
        arr_ti := infer_expr(ast_a(node));
        idx_ti := infer_expr(ast_b(node));
        arr_kind := get_type_kind(arr_ti);
        // Range index: arr[low..high] → slice type
        if ast_kind(ast_b(node)) == EXPR_RANGE {
            if arr_kind == TYP_ARRAY {
                // F11：字面量切片界编译期验证（TK05/06 既有错误码）
                arr_len : ., mut = get_type_extra(arr_ti);
                rn := ast_b(node);
                if arr_len > 0 && ast_kind(ast_a(rn)) == EXPR_INT && ast_kind(ast_b(rn)) == EXPR_INT {
                    lo := ast_int_val(ast_a(rn));
                    hi := ast_int_val(ast_b(rn));
                    if lo < 0 || hi > arr_len {
                        check_error(EC_TK_SLICE_BOUNDS, "slice out of bounds: [" + int_str(lo) + ".." + int_str(hi) + "] (array length " + int_str(arr_len) + ")", ast_line(node), ast_col(node));
                    } else if lo > hi {
                        check_error(EC_TK_SLICE_LEN, "slice length negative: [" + int_str(lo) + ".." + int_str(hi) + "]", ast_line(node), ast_col(node));
                    }
                }
                return alloc_type(TYP_SLICE, get_type_data(arr_ti), 0);
            }
            return TI_UNIT;
        }
        // Regular index: arr[i] or slice[i] → element type
        if arr_kind == TYP_ARRAY {
            // F2：字面量索引编译期越界检查（数组长度编译期可知时）
            if ast_kind(ast_b(node)) == EXPR_INT {
                idx_val := ast_int_val(ast_b(node));
                arr_len : ., mut = get_type_extra(arr_ti);
                if arr_len > 0 && (idx_val < 0 || idx_val >= arr_len) {
                    check_error(EC_R_OOB, "index out of bounds: " + int_str(idx_val) + " (array length " + int_str(arr_len) + ")", ast_line(node), ast_col(node));
                }
            }
            return get_type_data(arr_ti);
        }
        if arr_kind == TYP_SLICE {
            return get_type_data(arr_ti);  // slice[i] → element type
        }
        if arr_ti == TI_STR {
            // A string is a byte sequence. Reject a statically known invalid
            // index instead of allowing a silent read past its terminator.
            if ast_kind(ast_a(node)) == EXPR_STRING && ast_kind(ast_b(node)) == EXPR_INT {
                string_len := istr_len(ast_int_val(ast_a(node)));
                string_idx := ast_int_val(ast_b(node));
                if string_idx < 0 || string_idx >= string_len {
                    check_error(EC_R_OOB,
                        "string index out of bounds: " + int_str(string_idx) +
                        " (length " + int_str(string_len) + ")",
                        ast_line(node), ast_col(node));
                }
            }
            return TI_INT;  // string[i] → byte value
        }
        check_error(EC_TK_INDEX, "Cannot index non-array type", ast_line(node), ast_col(node));
        return TI_INT;
    }

    if ast_kind(node) == EXPR_ASSIGN {
        target := ast_a(node);
        val := ast_b(node);
        tt := infer_expr(target);
        vt := infer_expr(val);
        if tt == TI_DYN {
            // dyn assignment: track the RHS type, skip strict type check
            if ast_kind(target) == EXPR_IDENT {
                target_ni := ast_int_val(target);
                target_si := find_sym(target_ni);
                if target_si >= 0 {
                    dyn_set_type(target_si, vt);
                }
            }
        } else if !type_equal(tt, vt) {
            check_error(EC_TA_ASSIGN, "Assignment type mismatch", ast_line(node), ast_col(node));
        }
        return vt;
    }

    if ast_kind(node) == EXPR_STRUCT {
        // Struct literal: a = name idx, b = first field value (wrapper), c = field count
        name_ni := ast_a(node);
        // Check if struct is generic
        si := find_struct_by_name(name_ni);
        if si >= 0 && si_generic_count(si) > 0 {
            // Generic struct: infer concrete types from field values
            g_gen_map_count = 0; g_gen_map_cap = 0;
            fi : ., mut = 0;
            fn2 : ., mut = ast_b(node);
            loop {
                if fi >= ast_c(node) { break; }
                if fi < si_field_count(si) && fn2 >= 0 {
                    field_val_ti := infer_expr(fn2);
                    orig_type_node := si_field_type_node(si, fi);
                    if orig_type_node >= 0 {
                        if ast_kind(orig_type_node) == EXPR_IDENT {
                            // Check if field type is a generic param
                            field_name_idx := ast_int_val(orig_type_node);
                            if is_struct_generic(si, field_name_idx) {
                                grow_gen_map(g_gen_map_count + 1);
                                w64(g_gen_map_names, g_gen_map_count * 8, field_name_idx);
                                w64(g_gen_map_types, g_gen_map_count * 8, field_val_ti);
                                g_gen_map_count = g_gen_map_count + 1;
                            }
                        }
                    }
                    fn2 = fn2 + 1;
                }
                fi = fi + 1;
            }
            // Create TYP_GENERIC_APPLY for this struct
            base_ti := alloc_type(TYP_NAMED, name_ni, 0);
            ds := g_gen_apply_data_count;
            grow_gen_apply_data(ds + 1 + g_gen_map_count);
            w64(g_gen_apply_data, ds * 8, g_gen_map_count);
            g_gen_apply_data_count = ds + 1;
            mi : ., mut = 0;
            loop {
                if mi >= g_gen_map_count { break; }
                w64(g_gen_apply_data, (ds + 1 + mi) * 8, r64(g_gen_map_types, mi * 8));
                mi = mi + 1;
            }
            g_gen_apply_data_count = ds + 1 + g_gen_map_count;
            return alloc_type(TYP_GENERIC_APPLY, base_ti, ds);
        }
        // Non-generic struct
        ti := alloc_type(TYP_NAMED, name_ni, 0);
        fi : ., mut = 0;
        fn2 : ., mut = ast_b(node);
        loop {
            if fi >= ast_c(node) { break; }
            if fn2 >= 0 {
                infer_expr(fn2); // wrapper node — forwards to value
                fn2 = fn2 + 1;
            }
            fi = fi + 1;
        }
        return ti;
    }

    if ast_kind(node) == EXPR_ARRAY {
        // Array literal: a = first elem, b = elem count
        elem_ti := TI_INT;
        ei : ., mut = 0;
        en : ., mut = ast_a(node);
        loop {
            if ei >= ast_b(node) { break; }
            if en >= 0 {
                elem_ti = infer_expr(en);
                en = en + 1;
            }
            ei = ei + 1;
        }
        // 表示层概念（2026-09-10 语言面收窄裁决 §1）：`[T; N]` 退役为「内联容量存储」表示提示（语义归处 = product / 序列+长度约束 / F11）——完整注记见本文件 res_type_node 的 EXPR_ARRAY 分支处，spec 见 docs/superpowers/specs/2026-09-10-language-surface-narrowing-design.md §1
        return alloc_type(TYP_ARRAY, elem_ti, ast_b(node));
    }

    if ast_kind(node) == EXPR_BREAK { return TI_UNIT; }
    if ast_kind(node) == EXPR_CONTINUE { return TI_UNIT; }
    if ast_kind(node) == EXPR_WILDCARD { return TI_UNIT; }
    if ast_kind(node) == EXPR_MOVE {
        return infer_expr(ast_a(node));
    }
    if ast_kind(node) == EXPR_UNSAFE {
        push_unsafe_scope();
        ret := infer_expr(ast_a(node));
        pop_unsafe_scope();
        return ret;
    }
    if ast_kind(node) == EXPR_TRY {
        // Try operator: unwrap Option[T] → T, Result[T,E] → T
        inner_ti := infer_expr(ast_a(node));
        if get_type_kind(inner_ti) == TYP_GENERIC_APPLY {
            base_ti := get_type_data(inner_ti);
            if get_type_kind(base_ti) == TYP_NAMED {
                base_ni := get_type_data(base_ti);
                base_name := istr_get(base_ni);
                if base_name == "Option" || base_name == "Result" {
                    ga_start := get_type_extra(inner_ti);
                    if r64(g_gen_apply_data, ga_start * 8) >= 1 {
                        return r64(g_gen_apply_data, (ga_start + 1) * 8); // first type arg
                    }
                }
            }
        }
        return inner_ti;
    }
    if ast_kind(node) == EXPR_STRUCTPAT {
        return TI_UNIT;
    }
    if ast_kind(node) == EXPR_AS {
        // expr as Type — type cast
        inner_ti := infer_expr(ast_a(node));
        type_node := ast_b(node);
        target_ti := res_type_node(type_node);
        if get_type_kind(target_ti) == TYP_PTR {
            inner_kind := get_type_kind(inner_ti);
            asp : ., mut = 1;
            if inner_kind == TYP_PTR {
                asp = get_type_extra(inner_ti);
            } else if inner_kind == TYP_REF {
                asp = 0;
            }
            return alloc_type(TYP_PTR, get_type_data(target_ti), asp);
        }
        return target_ti;
    }
    if ast_kind(node) == EXPR_STMT {
        infer_expr(ast_a(node));
        return TI_UNIT;
    }
    if ast_kind(node) == EXPR_TUPLE {
        // Tuple: create a TYP_TUPLE type with element types
        elem_idx := ast_a(node);
        ec : ., mut = ast_b(node);
        data_start := g_gen_apply_data_count;
        e : ., mut = 0;
        loop {
            if e >= ec { break; }
            elem_ti := infer_expr(elem_idx + e);
            grow_gen_apply_data(g_gen_apply_data_count + 1);
            w64(g_gen_apply_data, g_gen_apply_data_count * 8, elem_ti);
            g_gen_apply_data_count = g_gen_apply_data_count + 1;
            e = e + 1;
        }
        return alloc_type(TYP_TUPLE, ec, data_start);
    }

    if ast_kind(node) == EXPR_AT {
        name_ni := ast_a(node);
        name := istr_get(name_ni);
        args := ast_b(node);

        // @sizeOf(T) — 1 type argument
        if str_eq(name, "sizeOf") != 0 {
            if args < 0 { check_error(EC_N_UNDEFINED, "@sizeOf requires a type argument", ast_line(node), ast_col(node)); return TI_NEVER; }
            ti := res_type_node(args);
            if ti < 0 { check_error(EC_N_UNDEFINED, "@sizeOf: unknown type", ast_line(node), ast_col(node)); return TI_NEVER; }
            return TI_INT;
        }

        // @addr(fn) — function address, type int
        if str_eq(name, "addr") != 0 {
            ast_set_type_val(node, TI_INT);  // function address is an int
            return TI_INT;
        }

        // @alignOf(T) — 1 type argument
        if str_eq(name, "alignOf") != 0 {
            if args < 0 { check_error(EC_N_UNDEFINED, "@alignOf requires a type argument", ast_line(node), ast_col(node)); return TI_NEVER; }
            ti := res_type_node(args);
            if ti < 0 { check_error(EC_N_UNDEFINED, "@alignOf: unknown type", ast_line(node), ast_col(node)); return TI_NEVER; }
            return TI_INT;
        }

        // @fields(T) — 1 type argument, returns []string
        if str_eq(name, "fields") != 0 {
            if args < 0 { check_error(EC_N_UNDEFINED, "@fields requires a type argument", ast_line(node), ast_col(node)); return TI_NEVER; }
            ti := res_type_node(args);
            return TI_STR;
        }

        // @hasField(T, name) — type + string
        if str_eq(name, "hasField") != 0 {
            if args < 0 || ast_b(args) < 0 { check_error(EC_N_UNDEFINED, "@hasField requires 2 args", ast_line(node), ast_col(node)); return TI_NEVER; }
            ti := res_type_node(ast_a(args));
            return TI_BOOL;
        }

        // @field(T, name) — type + string, returns FieldInfo
        if str_eq(name, "field") != 0 {
            if args < 0 || ast_b(args) < 0 { check_error(EC_N_UNDEFINED, "@field requires 2 args", ast_line(node), ast_col(node)); return TI_NEVER; }
            ti := res_type_node(ast_a(args));
            return TI_INT;
        }

        // @typeInfo(T) — returns TypeInfo
        if str_eq(name, "typeInfo") != 0 {
            if args < 0 { check_error(EC_N_UNDEFINED, "@typeInfo requires a type argument", ast_line(node), ast_col(node)); return TI_NEVER; }
            ti := res_type_node(args);
            return TI_INT;  // placeholder — returns handle
        }

        // @raw_int(expr) — dex 表达式 → 缩放整数原值（显式转换，数值迁移 Task 4）
        if str_eq(name, "raw_int") != 0 {
            if args < 0 { check_error(EC_N_UNDEFINED, "@raw_int requires an expression", ast_line(node), ast_col(node)); return TI_NEVER; }
            av := infer_expr(ast_a(args));
            // 参数校验：dex（或 int——int 原值即其缩放值）才可取其原值；其余类型报错
            if av != TI_DEX && av != TI_INT && av != TI_NEVER {
                check_error(EC_TF_ARG_TYPE, "@raw_int requires a dex (or int) expression", ast_line(node), ast_col(node));
                return TI_NEVER;
            }
            return TI_INT;
        }

        // @comptime(expr) — force compile-time eval
        if str_eq(name, "comptime") != 0 {
            if args < 0 { check_error(EC_N_UNDEFINED, "@comptime requires an expression", ast_line(node), ast_col(node)); return TI_NEVER; }
            v := infer_expr(ast_a(args));
            ast_set_type_val(node, v);
            return v;
        }

        // @inline(fn) — inline hint
        if str_eq(name, "inline") != 0 {
            if args < 0 { check_error(EC_N_UNDEFINED, "@inline requires a function argument", ast_line(node), ast_col(node)); return TI_NEVER; }
            v := infer_expr(ast_a(args));
            ast_set_type_val(node, v);
            return v;
        }

        // @no_bounds_check — no args, unit
        if str_eq(name, "no_bounds_check") != 0 {
            return TI_UNIT;
        }

        // @fast — no args, unit
        if str_eq(name, "fast") != 0 {
            return TI_UNIT;
        }

        // @unroll(n) — requires integer argument
        if str_eq(name, "unroll") != 0 {
            if args < 0 { check_error(EC_N_UNDEFINED, "@unroll requires an integer argument", ast_line(node), ast_col(node)); return TI_UNIT; }
            return TI_UNIT;
        }

        // @section(name) — requires string argument
        if str_eq(name, "section") != 0 {
            if args < 0 { check_error(EC_N_UNDEFINED, "@section requires a string argument", ast_line(node), ast_col(node)); return TI_UNIT; }
            return TI_UNIT;
        }

        // @hotpatch — function annotation, not an expression
        if str_eq(name, "hotpatch") != 0 {
            return TI_UNIT;
        }

        check_error(EC_N_UNDEFINED, "unknown @ builtin: " + name, ast_line(node), ast_col(node));
        return TI_UNIT;
    }

    return TI_UNIT;
}

// --- Main entry ---

fn check_all() {
    init_types();
    // Save SYM_SO_FN entries before g_sym_count reset destroys them
    so_count : ., mut = 0;
    so_names : string, mut = alloc(128 * 8);
    so_types : string, mut = alloc(128 * 8);
    so_nodes : string, mut = alloc(128 * 8);
    si_scan : ., mut = 0;
    loop {
        if si_scan >= g_sym_count { break; }
        if sym_kind(si_scan) == SYM_SO_FN {
            w64(so_names, so_count * 8, sym_name(si_scan));
            w64(so_types, so_count * 8, sym_type(si_scan));
            w64(so_nodes, so_count * 8, sym_node(si_scan));
            so_count = so_count + 1;
        }
        si_scan = si_scan + 1;
    }
    g_sym_count = 0;
    g_scope_depth = 0; g_scope_bounds_cap = 0;
    g_diag_count = 0; g_diag_cap = 0;
    g_gen_map_count = 0; g_gen_map_cap = 0;
    g_gen_apply_data_count = 0;
    g_gen_apply_data_cap = 0;
    g_gen_param_count = 0; g_gen_param_cap = 0;
    g_dyn_type_set_count = 0; g_dyn_type_set_cap = 0; g_dyn_type_sets = "";

    // First pass: collect declarations
    collect_decls();
    init_builtins();

    // Restore SYM_SO_FN entries lost by g_sym_count reset
    ri : ., mut = 0;
    loop {
        if ri >= so_count { break; }
        si := g_sym_count;
        grow_syms(si + 1);
        sym_set_name(si, r64(so_names, ri * 8));
        sym_set_kind(si, SYM_SO_FN);
        sym_set_type(si, r64(so_types, ri * 8));
        sym_set_node(si, r64(so_nodes, ri * 8));
        g_sym_count = si + 1;
        ri = ri + 1;
    }

    // Register runtime builtins as proper SYM_FN (no .cr body, implemented in rt.s)
    // These must come after collect_decls so user-defined funcs take priority.
    ri2 : ., mut = 0;
    loop {
        if ri2 >= g_rt_builtin_count { break; }
        ni2 := r64(g_rt_builtin_names, ri2 * 8);
        ti2 := r64(g_rt_builtin_ret_types, ri2 * 8);
        if find_gsym(ni2) < 0 {  // skip if already defined by user
            si2 := g_sym_count;
            grow_syms(si2 + 1);
            sym_set_name(si2, ni2);
            sym_set_kind(si2, SYM_FN);
            sym_set_type(si2, ti2);
            sym_set_node(si2, -1);
            g_sym_count = si2 + 1;
        }
        ri2 = ri2 + 1;
    }

    // Second pass: check function bodies
    i : ., mut = 0;
    loop {
        if i >= g_func_count { break; }
        check_func(i);
        i = i + 1;
    }

    // Check global let initializers
    i = 0;
    loop {
        if i >= g_global_let_count { break; }
        check_global_let(r64(g_global_lets, i * 8));
        i = i + 1;
    }

    // Check impl-for relationships
    check_impl_for();
}
