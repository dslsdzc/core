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
    alloc_type(TYP_BASE, TY_FLOAT, 0);   // TI_FLOAT = 1
    alloc_type(TYP_BASE, TY_BOOL, 0);    // TI_BOOL = 2
    alloc_type(TYP_BASE, TY_STRING, 0);  // TI_STR = 3
    alloc_type(TYP_BASE, TY_UNIT, 0);    // TI_UNIT = 4
    alloc_type(TYP_BASE, TY_NEVER, 0);   // TI_NEVER = 5
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
    w64(g_diags, g_diag_count * 32, code);
    store_str_ptr(g_diags, g_diag_count * 32 + 8, msg);
    w64(g_diags, g_diag_count * 32 + 16, line);
    w64(g_diags, g_diag_count * 32 + 24, col);
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
        if tv == TY_FLOAT { return TI_FLOAT; }
        if tv == TY_BOOL { return TI_BOOL; }
        if tv == TY_STRING { return TI_STR; }
        if tv == TY_UNIT { return TI_UNIT; }
        if tv == TY_NEVER { return TI_NEVER; }
        if tv == TY_CHAR { return TI_CHAR; }
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
        if d == TY_FLOAT { return str_intern("float"); }
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
        rt := fi_return_type(i);
        rt_ti := TI_UNIT;
        // For generic functions, skip return type resolution (depends on call site)
        if fi_generic_count(i) > 0 {
            rt_ti = TI_UNIT;
        } else {
            type_node := ast_type_val(fn_node);
            if type_node > 0 && ast_kind(type_node) != 0 {
                rt_ti = res_type_node(type_node);
            } else if rt == TY_INT { rt_ti = TI_INT; }
            else if rt == TY_FLOAT { rt_ti = TI_FLOAT; }
            else if rt == TY_BOOL { rt_ti = TI_BOOL; }
            else if rt == TY_STRING { rt_ti = TI_STR; }
            else if rt == TY_UNIT { rt_ti = TI_UNIT; }
        }
        def_sym(name_idx, SYM_FN, rt_ti, fn_node);
        i = i + 1;
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
        if tv == TY_FLOAT { return TI_FLOAT; }
        if tv == TY_BOOL { return TI_BOOL; }
        if tv == TY_STRING { return TI_STR; }
        if tv == TY_UNIT { return TI_UNIT; }
        if tv == TY_CHAR { return TI_CHAR; }
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
    name_idx := ast_a(fn_node);  // EXPR_FN: a = name idx
    first_param := ast_b(fn_node);  // EXPR_FN: b = first param node
    param_count := ast_c(fn_node);  // EXPR_FN: c = param count
    return_type := ast_int_val(fn_node);  // EXPR_FN: int_val = return TY_*
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
                else if ptype == TY_FLOAT { ti = TI_FLOAT; }
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
        else if return_type == TY_FLOAT { ret_ti = TI_FLOAT; }
        else if return_type == TY_BOOL { ret_ti = TI_BOOL; }
        else if return_type == TY_STRING { ret_ti = TI_STR; }
        else if return_type == TY_UNIT { ret_ti = TI_UNIT; }
        else if return_type == TY_CHAR { ret_ti = TI_CHAR; }
        else if return_type == TY_NEVER { ret_ti = TI_NEVER; }
        if !type_equal(body_ti, ret_ti) && body_ti != TI_NEVER {
            // Skip check if return type is generic param (can't verify at declaration)
            if get_type_kind(ret_ti) != TYP_GENERIC_PARAM {
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

// --- Type inference ---

fn infer_expr(node: int) -> int {
    if node < 0 { return TI_UNIT; }


    if ast_kind(node) == EXPR_INT { return TI_INT; }
    if ast_kind(node) == EXPR_NONE && ast_a(node) >= 0 { return infer_expr(ast_a(node)); }
    if ast_kind(node) == EXPR_FLOAT { return TI_FLOAT; }
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
        if ast_a(node) >= 0 { return infer_expr(ast_a(node)); }
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
            // Check: arithmetic ops require int or float
            if lt != TI_INT && lt != TI_FLOAT && rt != TI_INT && rt != TI_FLOAT {
                check_error(EC_TB_ADD, "Arithmetic operation requires int or float", ast_line(node), ast_col(node));
            }
            if lt == TI_FLOAT || rt == TI_FLOAT { return TI_FLOAT; }
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
            mut_flag := ast_int_val(node);
            // Borrow check: can we borrow this variable?
            var_ni := borrow_var_name(operand);
            if var_ni >= 0 {
                if !check_borrow(var_ni, mut_flag) {
                    name := istr_get(var_ni);
                    if mut_flag != 0 {
                        check_error(EC_B_BORROW_MUT, "Cannot borrow '" + name + "' as mutable, already borrowed", ast_line(node), ast_col(node));
                    } else {
                        check_error(EC_B_BORROW_IMMUT, "Cannot borrow '" + name + "' as immutable, already mutably borrowed", ast_line(node), ast_col(node));
                    }
                }
            }
            // Get inner type without triggering check_use on the operand
            inner : ., mut = TI_UNIT;
            if ast_kind(operand) == EXPR_IDENT {
                vi := ast_int_val(operand);
                si := find_sym(vi);
                if si >= 0 { inner = sym_type(si); }
            } else {
                inner = infer_expr(operand);
            }
            return alloc_type(TYP_REF, inner, mut_flag);
        }
        if op == UOP_DEREF {
            inner := infer_expr(ast_a(node));
            if get_type_kind(inner) == TYP_REF {
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
                            ast_set_type_val(node, 1);  // mark as module call
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
                                            if iface_ret2 == TY_FLOAT { func_ni = mangled_ni2; return TI_FLOAT; }
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
        // Check builtins (only syscall3 — OS communication, no .cr body)
        if func_ni >= 0 {
            s := istr_get(func_ni);
            if s == "syscall3" { return TI_INT; }
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
                if ret_code2 == 3 { return TI_FLOAT; }
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
        push_borrow_scope();
        then_ti := infer_expr(then_node);
        pop_borrow_scope();
        if else_node >= 0 {
            push_borrow_scope();
            else_ti := infer_expr(else_node);
            pop_borrow_scope();
            if !type_equal(then_ti, else_ti) && then_ti != TI_NEVER && else_ti != TI_NEVER {
                check_error(EC_TC_IF_BRANCH, "If branches have different types", ast_line(node), ast_col(node));
            }
            return then_ti;
        }
        return TI_UNIT;
    }

    if ast_kind(node) == EXPR_GO {
        // ast_a = spawn count (-1=dynamic, N=static batch), ast_b = body
        body := ast_b(node);
        push_borrow_scope();
        infer_expr(body);
        pop_borrow_scope();
        return TI_UNIT;  // fire-and-forget: caller gets unit
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
                return alloc_type(TYP_SLICE, get_type_data(arr_ti), 0);
            }
            return TI_UNIT;
        }
        // Regular index: arr[i] or slice[i] → element type
        if arr_kind == TYP_ARRAY {
            return get_type_data(arr_ti);
        }
        if arr_kind == TYP_SLICE {
            return get_type_data(arr_ti);  // slice[i] → element type
        }
        if arr_ti == TI_STR {
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
        if !type_equal(tt, vt) {
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
        return alloc_type(TYP_ARRAY, elem_ti, ast_b(node));
    }

    if ast_kind(node) == EXPR_BREAK { return TI_UNIT; }
    if ast_kind(node) == EXPR_CONTINUE { return TI_UNIT; }
    if ast_kind(node) == EXPR_WILDCARD { return TI_UNIT; }
    if ast_kind(node) == EXPR_MOVE {
        return infer_expr(ast_a(node));
    }
    if ast_kind(node) == EXPR_UNSAFE {
        push_borrow_scope();
        ret := infer_expr(ast_a(node));
        pop_borrow_scope();
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
        return res_type_node(type_node);
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
