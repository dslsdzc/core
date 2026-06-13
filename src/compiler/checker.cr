// === checker.core ===
// Two-pass name resolver + type checker for flat AST
// First pass: collect all function/struct/global declarations
// Second pass: type-check function bodies

// --- Type table ---
// Entries are 3 ints: kind, data, extra
g_types : [int; MAX_TYPES * 3], mut;
g_type_count : int, mut;

fn alloc_type(kind: int, data: int, extra: int) -> int {
    idx := g_type_count;
    if idx < MAX_TYPES {
        g_types[idx * 3] = kind;
        g_types[idx * 3 + 1] = data;
        g_types[idx * 3 + 2] = extra;
        g_type_count = idx + 1;
    }
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

fn get_type_kind(ti: int) -> int {
    if ti >= 0 && ti < g_type_count { return g_types[ti * 3]; }
    return -1;
}

fn get_type_data(ti: int) -> int {
    if ti >= 0 && ti < g_type_count { return g_types[ti * 3 + 1]; }
    return 0;
}

fn get_type_extra(ti: int) -> int {
    if ti >= 0 && ti < g_type_count { return g_types[ti * 3 + 2]; }
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
                if !type_equal(g_gen_apply_data[start1 + i], g_gen_apply_data[start2 + i]) { return false; }
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
            count1 := g_gen_apply_data[start1];
            count2 := g_gen_apply_data[start2];
            if count1 != count2 { return false; }
            ai : ., mut = 0;
            loop {
                if ai >= count1 { break; }
                if !type_equal(g_gen_apply_data[start1 + 1 + ai], g_gen_apply_data[start2 + 1 + ai]) { return false; }
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

g_syms : [SymEntry; MAX_SYMS], mut;
g_sym_count : int, mut;
g_scope_bounds : [int; MAX_SCOPES], mut;
g_scope_depth : int, mut;

fn push_scope() {
    if g_scope_depth < MAX_SCOPES {
        g_scope_bounds[g_scope_depth] = g_sym_count;
        g_scope_depth = g_scope_depth + 1;
    }
}

fn pop_scope() {
    if g_scope_depth > 0 {
        g_scope_depth = g_scope_depth - 1;
        g_sym_count = g_scope_bounds[g_scope_depth];
    }
}

fn define_sym(name_idx: int, kind: int, type_idx: int, node_idx: int) {
    if g_sym_count < MAX_SYMS {
        g_syms[g_sym_count] = SymEntry { name_idx = name_idx, kind = kind, type_idx = type_idx, node_idx = node_idx };
        g_sym_count = g_sym_count + 1;
    }
}

fn lookup_sym(name_idx: int) -> int {
    i : ., mut = g_sym_count - 1;
    loop {
        if i < 0 { return -1; }
        if g_syms[i].name_idx == name_idx { return i; }
        i = i - 1;
    }
    return -1;
}

fn lookup_sym_global(name_idx: int) -> int {
    i : ., mut = g_sym_count - 1;
    loop {
        if i < 0 { return -1; }
        if g_syms[i].name_idx == name_idx && g_syms[i].kind >= SYM_FN && g_syms[i].kind <= SYM_GLOBAL { return i; }
        i = i - 1;
    }
    return -1;
}

// --- Error tracking ---
// Uses g_diags, g_diag_count from globals.cr (and ast.cr)
// Old g_check_errors is replaced by structured g_diags.

fn check_error(code: int, msg: string, line: int, col: int) {
    if g_diag_count < MAX_ERRS {
        g_diags[g_diag_count] = Diag { code = code, msg = msg, line = line, col = col };
        g_diag_count = g_diag_count + 1;
    }
}

// --- Borrow checking ---
MAX_BORROWS : int = 32;
MAX_HOLDERS : int = 64;

// Borrow state: tracks which variables are currently borrowed
g_borrow_vars : [int; MAX_BORROWS], mut;
g_borrow_refs : [int; MAX_BORROWS], mut;     // immutable ref count
g_borrow_muts : [int; MAX_BORROWS], mut;     // mutable ref flag (0/1)
g_borrow_count : int, mut;

// Borrow holder tracking: who holds a borrow on which variable
g_holder_borrowers : [int; MAX_HOLDERS], mut;  // name_idx of borrower
g_holder_borrowed : [int; MAX_HOLDERS], mut;   // name_idx of borrowed
g_holder_is_mut : [int; MAX_HOLDERS], mut;     // is mutable borrow?
g_holder_count : int, mut;

// Borrow scope markers: at scope entry, records current holder count
g_borrow_scope_markers : [int; MAX_SCOPES], mut;
g_borrow_scope_depth : int, mut;

fn find_borrow_entry(var_ni: int) -> int {
    i : ., mut = 0;
    loop {
        if i >= g_borrow_count { return -1; }
        if g_borrow_vars[i] == var_ni { return i; }
        i = i + 1;
    }
    return -1;
}

fn check_borrow(var_ni: int, is_mut: int) -> bool {
    bi := find_borrow_entry(var_ni);
    if bi >= 0 {
        if is_mut != 0 {
            // &mut x: fail if any borrow exists
            if g_borrow_refs[bi] > 0 || g_borrow_muts[bi] != 0 { return false; }
            g_borrow_muts[bi] = 1;
            return true;
        } else {
            // &x: fail if mutable borrow exists
            if g_borrow_muts[bi] != 0 { return false; }
            g_borrow_refs[bi] = g_borrow_refs[bi] + 1;
            return true;
        }
    }
    // First borrow of this variable
    if g_borrow_count < MAX_BORROWS {
        g_borrow_vars[g_borrow_count] = var_ni;
        g_borrow_refs[g_borrow_count] = 0;
        g_borrow_muts[g_borrow_count] = 0;
        if is_mut != 0 { g_borrow_muts[g_borrow_count] = 1; }
        else { g_borrow_refs[g_borrow_count] = 1; }
        g_borrow_count = g_borrow_count + 1;
    }
    return true;
}

fn check_use(var_ni: int) -> bool {
    bi := find_borrow_entry(var_ni);
    if bi >= 0 {
        if g_borrow_refs[bi] > 0 || g_borrow_muts[bi] != 0 { return false; }
    }
    return true;
}

fn push_borrow_scope() {
    if g_borrow_scope_depth < MAX_SCOPES {
        g_borrow_scope_markers[g_borrow_scope_depth] = g_holder_count;
        g_borrow_scope_depth = g_borrow_scope_depth + 1;
    }
}

fn pop_borrow_scope() {
    if g_borrow_scope_depth > 0 {
        g_borrow_scope_depth = g_borrow_scope_depth - 1;
        marker := g_borrow_scope_markers[g_borrow_scope_depth];
        // Release all borrows held from marker to end
        loop {
            if g_holder_count <= marker { break; }
            g_holder_count = g_holder_count - 1;
            borrowed_ni := g_holder_borrowed[g_holder_count];
            is_mut := g_holder_is_mut[g_holder_count];
            bi := find_borrow_entry(borrowed_ni);
            if bi >= 0 {
                if is_mut != 0 { g_borrow_muts[bi] = 0; }
                else {
                    if g_borrow_refs[bi] > 0 { g_borrow_refs[bi] = g_borrow_refs[bi] - 1; }
                }
                // Clean up entry if no more borrows
                if g_borrow_refs[bi] == 0 && g_borrow_muts[bi] == 0 {
                    si : ., mut = bi;
                    loop {
                        if si + 1 >= g_borrow_count { break; }
                        g_borrow_vars[si] = g_borrow_vars[si + 1];
                        g_borrow_refs[si] = g_borrow_refs[si + 1];
                        g_borrow_muts[si] = g_borrow_muts[si + 1];
                        si = si + 1;
                    }
                    g_borrow_count = g_borrow_count - 1;
                }
            }
        }
    }
}

fn record_borrow_holder(borrower_ni: int, borrowed_ni: int, is_mut: int) {
    if g_holder_count < MAX_HOLDERS {
        g_holder_borrowers[g_holder_count] = borrower_ni;
        g_holder_borrowed[g_holder_count] = borrowed_ni;
        g_holder_is_mut[g_holder_count] = is_mut;
        g_holder_count = g_holder_count + 1;
    }
}

fn borrow_var_name(node: int) -> int {
    if node < 0 { return -1; }
    if g_ast[node].kind == EXPR_IDENT { return g_ast[node].int_val; }
    return -1;
}

// --- Type resolution utilities ---

fn resolve_type_node(node: int) -> int {
    if node < 0 { return TI_UNIT; }
    n := g_ast[node];
    if n.kind == 0 {
        // Base type node: type_val = TY_*
        tv := n.type_val;
        if tv == TY_INT { return TI_INT; }
        if tv == TY_FLOAT { return TI_FLOAT; }
        if tv == TY_BOOL { return TI_BOOL; }
        if tv == TY_STRING { return TI_STR; }
        if tv == TY_UNIT { return TI_UNIT; }
        if tv == TY_NEVER { return TI_NEVER; }
        if tv == TY_CHAR { return TI_CHAR; }
        return TI_UNIT;
    }
    if n.kind == EXPR_IDENT {
        // Named type: int_val = name string index
        name_idx := n.int_val;
        si := lookup_sym_global(name_idx);
        if si >= 0 && g_syms[si].kind == SYM_TYPE {
            return g_syms[si].type_idx;
        }
        // Create named type entry
        return alloc_type(TYP_NAMED, name_idx, 0);
    }
    if n.kind == EXPR_ARRAY {
        // Array type [T; N] or slice type [T] (size 0)
        elem := resolve_type_node(n.a);
        sz := n.int_val;
        if sz == 0 {
            return alloc_type(TYP_SLICE, elem, 0);
        }
        return alloc_type(TYP_ARRAY, elem, sz);
    }
    if n.kind == EXPR_REFTYPE {
        // Reference type &T or &mut T
        inner := resolve_type_node(n.a);
        mut_flag := n.int_val;
        return alloc_type(TYP_REF, inner, mut_flag);
    }
    if n.kind == EXPR_GENERIC_APPLY {
        // Generic application: Box[int]
        name_idx := n.a;
        first_arg_node := n.b;
        arg_count := n.c;
        si := lookup_sym_global(name_idx);
        if si < 0 || g_syms[si].kind != SYM_TYPE {
            check_error(EC_N_GENERIC_TYPE, "Undefined type in generic application", n.line, n.col);
            return TI_UNIT;
        }
        base_ti := g_syms[si].type_idx;
        // Store args in g_gen_apply_data: [count, arg1, arg2, ...]
        data_start := g_gen_apply_data_count;
        g_gen_apply_data[data_start] = arg_count;
        g_gen_apply_data_count = data_start + 1;
        ai : ., mut = 0;
        an : ., mut = first_arg_node;
        loop {
            if ai >= arg_count { break; }
            arg_ti := resolve_type_node(an);
            g_gen_apply_data[data_start + 1 + ai] = arg_ti;
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
        if str_intern(g_structs[i].name) == name_idx { return i; }
        i = i + 1;
    }
    return -1;
}

fn find_enum(name_idx: int) -> int {
    i : ., mut = 0;
    loop {
        if i >= g_enum_count { return -1; }
        if str_intern(g_enums[i].name) == name_idx { return i; }
        i = i + 1;
    }
    return -1;
}

// --- First pass: collect all declarations ---

fn collect_decls() {
    i : ., mut = 0;
    // First: register all struct types
    loop {
        if i >= g_struct_count { break; }
        name_idx := str_intern(g_structs[i].name);
        type_idx := alloc_type(TYP_NAMED, name_idx, 0);
        define_sym(name_idx, SYM_TYPE, type_idx, -1);
        i = i + 1;
    }
    // Resolve struct field types now that all struct names are registered
    i = 0;
    loop {
        if i >= g_struct_count { break; }
        j : ., mut = 0;
        loop {
            if j >= g_structs[i].field_count { break; }
            // Field types were stored by parser as unpack_type() results (TY_* or 0)
            // We need to resolve them — but they're stored as ints, not nodes.
            // For now, leave as-is; fields are resolved during type inference.
            j = j + 1;
        }
        i = i + 1;
    }
    // Register built-in Option type (for T? desugaring)
    option_found : ., mut = 0;
    i = 0;
    loop {
        if i >= g_enum_count { break; }
        if str_intern(g_enums[i].name) == str_intern("Option") { option_found = 1; }
        i = i + 1;
    }
    if option_found == 0 {
        // Auto-register Option as a generic built-in type
        option_name_idx := str_intern("Option");
        option_ti := alloc_type(TYP_NAMED, option_name_idx, 0);
        define_sym(option_name_idx, SYM_TYPE, option_ti, -1);
    }

    // Register all enum types and their variant constructors
    i = 0;
    loop {
        if i >= g_enum_count { break; }
        name_idx := str_intern(g_enums[i].name);
        type_idx := alloc_type(TYP_NAMED, name_idx, 0);
        define_sym(name_idx, SYM_TYPE, type_idx, -1);
        // Register each variant as a function returning the enum type
        vi : ., mut = 0;
        loop {
            if vi >= g_enums[i].variant_count { break; }
            vname_idx := str_intern(g_enums[i].variants[vi].name);
            define_sym(vname_idx, SYM_FN, type_idx, -1);
            vi = vi + 1;
        }
        i = i + 1;
    }

    // Register type aliases
    i = 0;
    loop {
        if i >= g_type_alias_count { break; }
        name_idx := g_type_aliases[i].name_idx;
        type_node := g_type_aliases[i].type_node;
        ti := resolve_type_node(type_node);
        define_sym(name_idx, SYM_TYPE, ti, -1);
        i = i + 1;
    }

    // Register all functions
    i = 0;
    loop {
        if i >= g_func_count { break; }
        name_idx := str_intern(g_funcs[i].name);
        fn_node := g_funcs[i].ast_node;
        rt := g_funcs[i].return_type;
        rt_ti := TI_UNIT;
        // For generic functions, skip return type resolution (depends on call site)
        if g_funcs[i].generic_count > 0 {
            rt_ti = TI_UNIT;
        } else {
            type_node := g_ast[fn_node].type_val;
            if type_node > 0 && g_ast[type_node].kind != 0 {
                rt_ti = resolve_type_node(type_node);
            } else if rt == TY_INT { rt_ti = TI_INT; }
            else if rt == TY_FLOAT { rt_ti = TI_FLOAT; }
            else if rt == TY_BOOL { rt_ti = TI_BOOL; }
            else if rt == TY_STRING { rt_ti = TI_STR; }
            else if rt == TY_UNIT { rt_ti = TI_UNIT; }
        }
        define_sym(name_idx, SYM_FN, rt_ti, fn_node);
        i = i + 1;
    }
    // Register all global variables
    i = 0;
    loop {
        if i >= g_global_let_count { break; }
        node := g_global_lets[i];
        n := g_ast[node];
        name_idx := n.a;  // EXPR_LET: a = name idx
        type_node := n.b;  // EXPR_LET: b = type node (-1 if none)
        ti := TI_UNIT;
        if type_node >= 0 { ti = resolve_type_node(type_node); }
        define_sym(name_idx, SYM_GLOBAL, ti, node);
        i = i + 1;
    }
    // Register module aliases (from imports)
    mi : ., mut = 0;
    loop {
        if mi >= g_mod_count { break; }
        define_sym(g_mods[mi].alias_ni, SYM_MODULE, g_mods[mi].fileid_ni, -1);
        mi = mi + 1;
    }
    // Register mod path declarations (mod foo::bar;)
    pi : ., mut = 0;
    loop {
        if pi >= g_mod_path_count { break; }
        define_sym(g_mod_path_names[pi], SYM_MODULE, g_mod_path_names[pi], -1);
        pi = pi + 1;
    }
    // Build module function lookup table for qualified access (e.g., mymath.add)
    main_fni : ., mut = 0;
    if g_file_count > 0 { main_fni = g_files[0].fileid_ni; }
    g_mod_func_count = 0;
    fi : ., mut = 0;
    loop {
        if fi >= g_func_count { break; }
        fn_node := g_funcs[fi].ast_node;
        fn_line := g_ast[fn_node].line;
        if fn_line > 0 && fn_line <= g_line_count {
            fileid_ni := g_line_fileid[fn_line - 1];
            if fileid_ni != main_fni && fileid_ni != 0 && g_line_count > 0 {
                if g_mod_func_count < MAX_MOD_FUNCS {
                    g_mod_func_fileids[g_mod_func_count] = fileid_ni;
                    g_mod_func_names[g_mod_func_count] = str_intern(g_funcs[fi].name);
                    fn_si := lookup_sym(str_intern(g_funcs[fi].name));
                    if fn_si >= 0 {
                        g_mod_func_tis[g_mod_func_count] = g_syms[fn_si].type_idx;
                    }
                    g_mod_func_count = g_mod_func_count + 1;
                }
            }
        }
        fi = fi + 1;
    }
}

// --- Generic type inference helpers ---
g_gen_map_names : [int; 4], mut;  // generic param name indices
g_gen_map_types : [int; 4], mut;  // corresponding concrete type indices
g_gen_map_count : int, mut;

fn is_func_generic(fi: int, name_idx: int) -> bool {
    if fi < 0 || fi >= g_func_count { return false; }
    gi : ., mut = 0;
    loop {
        if gi >= g_funcs[fi].generic_count { return false; }
        if str_intern(g_funcs[fi].generic_names[gi]) == name_idx { return true; }
        gi = gi + 1;
    }
    return false;
}

fn find_func(name_idx: int) -> int {
    s := g_strs[name_idx];
    i : ., mut = 0;
    loop {
        if i >= g_func_count { return -1; }
        if g_funcs[i].name == s { return i; }
        i = i + 1;
    }
    return -1;
}

fn is_struct_generic(si: int, name_idx: int) -> bool {
    if si < 0 || si >= g_struct_count { return false; }
    gi : ., mut = 0;
    loop {
        if gi >= g_structs[si].generic_count { return false; }
        if str_intern(g_structs[si].generic_names[gi]) == name_idx { return true; }
        gi = gi + 1;
    }
    return false;
}

fn find_struct_by_name(name_idx: int) -> int {
    i : ., mut = 0;
    loop {
        if i >= g_struct_count { return -1; }
        if str_intern(g_structs[i].name) == name_idx { return i; }
        i = i + 1;
    }
    return -1;
}

fn resolve_call_type_node(node: int, func_fi: int) -> int {
    // Resolve a type node for call inference, treating generic params as TYP_GENERIC_PARAM
    if node < 0 { return TI_UNIT; }
    n := g_ast[node];
    if n.kind == 0 {
        tv := n.type_val;
        if tv == TY_INT { return TI_INT; }
        if tv == TY_FLOAT { return TI_FLOAT; }
        if tv == TY_BOOL { return TI_BOOL; }
        if tv == TY_STRING { return TI_STR; }
        if tv == TY_UNIT { return TI_UNIT; }
        if tv == TY_CHAR { return TI_CHAR; }
        return TI_UNIT;
    }
    if n.kind == EXPR_IDENT {
        name_idx := n.int_val;
        if is_func_generic(func_fi, name_idx) {
            return alloc_type(TYP_GENERIC_PARAM, name_idx, 0);
        }
        // Regular named type
        si := lookup_sym_global(name_idx);
        if si >= 0 && g_syms[si].kind == SYM_TYPE { return g_syms[si].type_idx; }
        return alloc_type(TYP_NAMED, name_idx, 0);
    }
    if n.kind == EXPR_GENERIC_APPLY {
        name_idx := n.a;
        first_an := n.b;
        ac := n.c;
        si := lookup_sym_global(name_idx);
        if si < 0 || g_syms[si].kind != SYM_TYPE { return TI_UNIT; }
        base_ti := g_syms[si].type_idx;
        ds := g_gen_apply_data_count;
        g_gen_apply_data[ds] = ac;
        g_gen_apply_data_count = ds + 1;
        ai : ., mut = 0;
        an : ., mut = first_an;
        loop {
            if ai >= ac { break; }
            at := resolve_call_type_node(an, func_fi);
            g_gen_apply_data[ds + 1 + ai] = at;
            ai = ai + 1;
            an = an + 1;
        }
        g_gen_apply_data_count = ds + 1 + ac;
        return alloc_type(TYP_GENERIC_APPLY, base_ti, ds);
    }
    if n.kind == EXPR_REFTYPE {
        inner := resolve_call_type_node(n.a, func_fi);
        mf := n.int_val;
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
            if g_gen_map_names[mi] == name_idx {
                return type_equal(g_gen_map_types[mi], concrete);
            }
            mi = mi + 1;
        }
        if g_gen_map_count < MAX_GENERICS {
            g_gen_map_names[g_gen_map_count] = name_idx;
            g_gen_map_types[g_gen_map_count] = concrete;
            g_gen_map_count = g_gen_map_count + 1;
            return true;
        }
        return false;
    }
    if pk == TYP_GENERIC_APPLY && ck == TYP_GENERIC_APPLY {
        if !type_equal(get_type_data(pattern), get_type_data(concrete)) { return false; }
        ps := get_type_extra(pattern);
        cs := get_type_extra(concrete);
        pc := g_gen_apply_data[ps];
        cc := g_gen_apply_data[cs];
        if pc != cc { return false; }
        ai : ., mut = 0;
        loop {
            if ai >= pc { break; }
            if !unify_types(g_gen_apply_data[ps + 1 + ai], g_gen_apply_data[cs + 1 + ai]) { return false; }
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
            if g_gen_map_names[mi] == name_idx { return g_gen_map_types[mi]; }
            mi = mi + 1;
        }
        return ti;
    }
    if k == TYP_GENERIC_APPLY {
        base := get_type_data(ti);
        start := get_type_extra(ti);
        count := g_gen_apply_data[start];
        new_start := g_gen_apply_data_count;
        g_gen_apply_data[new_start] = count;
        g_gen_apply_data_count = new_start + 1;
        ai : ., mut = 0;
        loop {
            if ai >= count { break; }
            sub := substitute_return_type(g_gen_apply_data[start + 1 + ai]);
            g_gen_apply_data[new_start + 1 + ai] = sub;
            ai = ai + 1;
        }
        g_gen_apply_data_count = new_start + 1 + count;
        return alloc_type(TYP_GENERIC_APPLY, base, new_start);
    }
    return ti;
}

fn infer_generic_call(fi: int, call_node: int, first_arg: int, arg_count: int) -> int {
    // Infer concrete types for a generic function call
    fn_node := g_funcs[fi].ast_node;
    f := g_ast[fn_node];
    first_param := f.b;
    param_count := f.c;
    ret_type_node := f.type_val;

    g_gen_map_count = 0;

    // First pass: infer arg types and build mapping
    pi : ., mut = 0;
    pn : ., mut = first_param;
    an : ., mut = first_arg;
    loop {
        if pi >= param_count || pi >= arg_count { break; }
        if pn < 0 || an < 0 { break; }

        p := g_ast[pn];
        orig_type_node := p.data;  // original param type node

        if orig_type_node >= 0 {
            pattern_ti := resolve_call_type_node(orig_type_node, fi);
            concrete_ti := infer_expr(an);
            unify_types(pattern_ti, concrete_ti);
        } else {
            infer_expr(an);
        }

        pi = pi + 1;
        pn = pn + 1;
        an = an + 1;
    }

    // Substitute return type
    if g_gen_map_count > 0 && ret_type_node >= 0 {
        resolved_ret := resolve_call_type_node(ret_type_node, fi);
        return substitute_return_type(resolved_ret);
    }

    // Fallback: look up from symbol table
    func_ni : ., mut = f.a;
    si := lookup_sym_global(func_ni);
    if si >= 0 && g_syms[si].kind == SYM_FN {
        return g_syms[si].type_idx;
    }
    return TI_UNIT;
}

// --- check_func with generic param scope ---

fn check_func(fi: int) {
    // Reset per-function borrow state
    g_borrow_count = 0;
    g_holder_count = 0;
    g_borrow_scope_depth = 0;
    fn_node := g_funcs[fi].ast_node;
    f := g_ast[fn_node];
    name_idx := f.a;  // EXPR_FN: a = name idx
    first_param := f.b;  // EXPR_FN: b = first param node
    param_count := f.c;  // EXPR_FN: c = param count
    return_type := f.int_val;  // EXPR_FN: int_val = return TY_*
    body := f.data;  // EXPR_FN: data = body node

    push_scope();
    // Register generic params if any
    if g_funcs[fi].generic_count > 0 {
        gi : ., mut = 0;
        loop {
            if gi >= g_funcs[fi].generic_count { break; }
            gname_idx := str_intern(g_funcs[fi].generic_names[gi]);
            g_ti := alloc_type(TYP_GENERIC_PARAM, gname_idx, 0);
            define_sym(gname_idx, SYM_TYPE, g_ti, -1);
            gi = gi + 1;
        }
    }
    // Add params to scope
    pi : ., mut = 0;
    pn : ., mut = first_param;
    loop {
        if pi >= param_count { break; }
        if pn < 0 { break; }
        p := g_ast[pn];
        pname_idx := p.a;  // EXPR_PARAM: a = name idx
        self_mode := p.int_val;  // EXPR_PARAM: int_val = self mode (0=normal, 1=self, 2=&self, 3=&mut self)
        ti : ., mut = TI_UNIT;
        if self_mode == 0 {
            // Regular param: resolve using original type node if it's non-base (named/generic)
            orig_type_node := p.data;
            if orig_type_node >= 0 && g_ast[orig_type_node].kind != 0 {
                ti = resolve_type_node(orig_type_node);
            } else {
                // Base type: switch on type_val (TY_*)
                ptype := p.type_val;
                if ptype == TY_INT { ti = TI_INT; }
                else if ptype == TY_FLOAT { ti = TI_FLOAT; }
                else if ptype == TY_BOOL { ti = TI_BOOL; }
                else if ptype == TY_STRING { ti = TI_STR; }
                else if ptype == TY_CHAR { ti = TI_CHAR; }
            }
        } else {
            // Self param: derive struct type from mangled function name "Struct.method"
            fn_name := g_funcs[fi].name;
            fn_len := __builtin_str_len(fn_name);
            dot_pos : ., mut = -1;
            di : ., mut = 0;
            loop {
                if di >= fn_len { break; }
                if __builtin_str_get(fn_name, di) == "." { dot_pos = di; break; }
                di = di + 1;
            }
            if dot_pos > 0 {
                struct_name := __builtin_str_sub(fn_name, 0, dot_pos);
                struct_ni := str_intern(struct_name);
                si := lookup_sym_global(struct_ni);
                if si >= 0 && g_syms[si].kind == SYM_TYPE {
                    struct_ti := g_syms[si].type_idx;
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
        define_sym(pname_idx, SYM_PARAM, ti, -1);
        pi = pi + 1;
        // Params are not contiguous — type nodes are allocated between them
        pn = pn + 1;
        loop {
            if pn >= g_ast_count { break; }
            if g_ast[pn].kind == EXPR_PARAM { break; }
            pn = pn + 1;
        }
    }
    // Check body
    if body >= 0 {
        body_ti := infer_expr(body);
        ret_ti : ., mut = TI_UNIT;
        // First check for named type via the stored type node (kind != 0)
        type_node := f.type_val;
        if type_node > 0 && g_ast[type_node].kind != 0 {
            ret_ti = resolve_type_node(type_node);
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
                check_error(EC_TF_RETURN, "Function return type mismatch", f.line, f.col);
            }
        }
    }
    pop_scope();
}

fn check_global_let(node: int) {
    n := g_ast[node];
    val_node := n.c;  // EXPR_LET: c = value
    if val_node >= 0 {
        infer_expr(val_node);
    }
}

// --- Type inference ---

fn infer_expr(node: int) -> int {
    if node < 0 { return TI_UNIT; }
    n := g_ast[node];


    if n.kind == EXPR_INT { return TI_INT; }
    if n.kind == EXPR_NONE && n.a >= 0 { return infer_expr(n.a); }
    if n.kind == EXPR_FLOAT { return TI_FLOAT; }
    if n.kind == EXPR_STRING { return TI_STR; }
    if n.kind == EXPR_BOOL { return TI_BOOL; }
    if n.kind == EXPR_CHAR { return TI_CHAR; }

    if n.kind == EXPR_IDENT {
        name_idx := n.int_val;
        // Borrow check: can't use variable while it's borrowed
        if !check_use(name_idx) {
            name := g_strs[name_idx];
            check_error(EC_B_USE_WHILE_BORROWED, "Cannot use '" + name + "' while it is borrowed", n.line, n.col);
        }
        si := lookup_sym(name_idx);
        if si >= 0 { return g_syms[si].type_idx; }
        name := g_strs[name_idx];
        check_error(EC_N_UNDEFINED, "Undefined name '" + name + "'", n.line, n.col);
        return TI_NEVER;
    }
    if n.kind == EXPR_NONE {
        // Wrapper node in struct literal: forward to inner expression
        if n.a >= 0 { return infer_expr(n.a); }
        return TI_UNIT;
    }

    if n.kind == EXPR_BINARY {
        left := n.a;
        right := n.b;
        op := n.c;
        if op == OP_ASSIGN {
            // Assignment: left = right
            lt := infer_expr(left);
            rt := infer_expr(right);
            if !type_equal(lt, rt) {
                check_error(EC_TA_ASSIGN, "Assignment type mismatch", n.line, n.col);
            }
            return rt;
        }
        lt := infer_expr(left);
        rt := infer_expr(right);
        if op == OP_ADD || op == OP_SUB || op == OP_MUL || op == OP_DIV || op == OP_MOD {
            // Check: arithmetic ops require int or float
            if lt != TI_INT && lt != TI_FLOAT && rt != TI_INT && rt != TI_FLOAT {
                check_error(EC_TB_ADD, "Arithmetic operation requires int or float", n.line, n.col);
            }
            // String concatenation for OP_ADD
            if op == OP_ADD && (lt == TI_STR || rt == TI_STR) { return TI_STR; }
            if lt == TI_FLOAT || rt == TI_FLOAT { return TI_FLOAT; }
            return TI_INT;
        }
        if op == OP_EQ || op == OP_NE || op == OP_LT || op == OP_GT || op == OP_LE || op == OP_GE {
            return TI_BOOL;
        }
        if op == OP_AND || op == OP_OR {
            if lt != TI_BOOL || rt != TI_BOOL {
                check_error(EC_TC_IF_COND, "Logical operator requires bool operands", n.line, n.col);
            }
            return TI_BOOL;
        }
        return TI_INT;
    }

    if n.kind == EXPR_UNARY {
        op := n.c;
        if op == UOP_NEG || op == UOP_NOT {
            return infer_expr(n.a);
        }
        if op == UOP_REF {
            operand := n.a;
            mut_flag := n.int_val;
            // Borrow check: can we borrow this variable?
            var_ni := borrow_var_name(operand);
            if var_ni >= 0 {
                if !check_borrow(var_ni, mut_flag) {
                    name := g_strs[var_ni];
                    if mut_flag != 0 {
                        check_error(EC_B_BORROW_MUT, "Cannot borrow '" + name + "' as mutable, already borrowed", n.line, n.col);
                    } else {
                        check_error(EC_B_BORROW_IMMUT, "Cannot borrow '" + name + "' as immutable, already mutably borrowed", n.line, n.col);
                    }
                }
            }
            // Get inner type without triggering check_use on the operand
            inner : ., mut = TI_UNIT;
            if g_ast[operand].kind == EXPR_IDENT {
                vi := g_ast[operand].int_val;
                si := lookup_sym(vi);
                if si >= 0 { inner = g_syms[si].type_idx; }
            } else {
                inner = infer_expr(operand);
            }
            return alloc_type(TYP_REF, inner, mut_flag);
        }
        if op == UOP_DEREF {
            inner := infer_expr(n.a);
            if get_type_kind(inner) == TYP_REF {
                return get_type_data(inner);
            }
            if get_type_kind(inner) == TYP_GENERIC_PARAM {
                return inner;
            }
            return inner;
        }
        return infer_expr(n.a);
    }

    if n.kind == EXPR_CALL {
        func_node := n.a;
        first_arg := n.b;
        arg_count := n.c;
        func_ni : ., mut = -1;

        // Method call: obj.method(args)  or  module.func(args)
        if g_ast[func_node].kind == EXPR_FIELD {
            obj := g_ast[func_node].a;
            method_ni := g_ast[func_node].int_val;

            // Module-qualified call: module.func(args)
            mod_call_done : ., mut = 0;
            mod_found_mfi : ., mut = -1;
            if g_ast[obj].kind == EXPR_IDENT {
                mod_name_ni := g_ast[obj].int_val;
                si := lookup_sym(mod_name_ni);
                if si >= 0 && g_syms[si].kind == SYM_MODULE {
                    fileid_ni := g_syms[si].type_idx;
                    // Look up (fileid, method) in module function table
                    mfi : ., mut = 0;
                    loop {
                        if mfi >= g_mod_func_count { break; }
                        if g_mod_func_fileids[mfi] == fileid_ni && g_mod_func_names[mfi] == method_ni {
                            func_ni = g_mod_func_names[mfi];
                            g_ast[node].data = func_ni;
                            g_ast[node].type_val = 1;  // mark as module call
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
                ai : ., mut = 0;
                an : ., mut = first_arg;
                loop {
                    if ai >= arg_count { break; }
                    if an >= 0 { infer_expr(an); an = an + 1; }
                    ai = ai + 1;
                }
                if mod_found_mfi >= 0 {
                    return g_mod_func_tis[mod_found_mfi];
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
                    if g_methods[mi].struct_ni == struct_ni && g_methods[mi].method_ni == method_ni {
                        func_ni = g_methods[mi].mangled_ni;
                        g_ast[node].data = func_ni;
                        break;
                    }
                    mi = mi + 1;
                }
            }
            // Infer arg types
            ai : ., mut = 0;
            an : ., mut = first_arg;
            loop {
                if ai >= arg_count { break; }
                if an >= 0 { infer_expr(an); an = an + 1; }
                ai = ai + 1;
            }
            if func_ni >= 0 {
                si := lookup_sym_global(func_ni);
                if si >= 0 && g_syms[si].kind == SYM_FN {
                    return g_syms[si].type_idx;
                }
            }
            return TI_UNIT;
        }

        // Determine function name and return type
        if g_ast[func_node].kind == EXPR_IDENT {
            func_ni = g_ast[func_node].int_val;
        }
        // Check builtins
        if func_ni >= 0 {
            s := g_strs[func_ni];
            if s == "__builtin_str_len" { return TI_INT; }
            if s == "__builtin_str_get" { return TI_STR; }
            if s == "__builtin_str_sub" { return TI_STR; }
            if s == "__builtin_int_to_str" { return TI_STR; }
            if s == "__builtin_str_push" { return TI_STR; }
            if s == "__builtin_str_from_int" { return TI_STR; }
            if s == "__builtin_str_to_int" { return TI_INT; }
            if s == "__builtin_print" { return TI_UNIT; }
            if s == "__builtin_println" { return TI_UNIT; }
            
            if s == "__builtin_print" { return TI_UNIT; }
            if s == "__builtin_println" { return TI_UNIT; }
            if s == "__builtin_syscall3" { return TI_INT; }
            if s == "__builtin_load8" { return TI_INT; }
            if s == "__builtin_store8" { return TI_INT; }
            if s == "__builtin_alloc" { return TI_STR; }
            if s == "__builtin_read_file" { return TI_STR; }
            if s == "__builtin_write_file" { return TI_INT; }
            if s == "__builtin_str_eq" { return TI_INT; }
            if s == "__builtin_str_cmp" { return TI_INT; }
            if s == "__builtin_get_arg" { return TI_STR; }
            if s == "__builtin_int_to_str" { return TI_STR; }
            if s == "__builtin_load8" { return TI_INT; }
            if s == "__builtin_store8" { return TI_INT; }
        }
        // Look up function
        if func_ni >= 0 {
            si := lookup_sym_global(func_ni);
            if si >= 0 && g_syms[si].kind == SYM_FN {
                // Check if generic function
                fi := find_func(func_ni);
                if fi >= 0 && g_funcs[fi].generic_count > 0 {
                    return infer_generic_call(fi, node, first_arg, arg_count);
                }
                return g_syms[si].type_idx;  // return type
            }
        }
        // Infer arg types (for side effects)
        ai : ., mut = 0;
        an : ., mut = first_arg;
        loop {
            if ai >= arg_count { break; }
            if an >= 0 {
                infer_expr(an);
                an = an + 1;
            }
            ai = ai + 1;
        }
        return TI_UNIT;
    }

    if n.kind == EXPR_BLOCK {
        stmt_start := n.a;
        stmt_count := n.b;
        res : ., mut = TI_UNIT;
        push_borrow_scope();
        i : ., mut = 0;
        loop {
            if i >= stmt_count { break; }
            sn := g_block_stmts[stmt_start + i];
            res = infer_expr(sn);
            i = i + 1;
        }
        pop_borrow_scope();
        return res;
    }

    if n.kind == EXPR_IF {
        cond := n.a;
        then_node := n.b;
        else_node := n.c;
        cond_ti := infer_expr(cond);
        if cond_ti != TI_BOOL {
            check_error(EC_TC_IF_COND, "If condition must be bool", n.line, n.col);
        }
        push_borrow_scope();
        then_ti := infer_expr(then_node);
        pop_borrow_scope();
        if else_node >= 0 {
            push_borrow_scope();
            else_ti := infer_expr(else_node);
            pop_borrow_scope();
            if !type_equal(then_ti, else_ti) {
                check_error(EC_TC_IF_BRANCH, "If branches have different types", n.line, n.col);
            }
            return then_ti;
        }
        return TI_UNIT;
    }

    if n.kind == EXPR_LOOP {
        push_borrow_scope();
        infer_expr(n.a);
        pop_borrow_scope();
        return TI_UNIT;
    }

    if n.kind == EXPR_WHILE {
        cond := n.a;
        body := n.b;
        cond_ti := infer_expr(cond);
        if cond_ti != TI_BOOL {
            check_error(EC_TC_WHILE_COND, "While condition must be bool", n.line, n.col);
        }
        push_borrow_scope();
        infer_expr(body);
        pop_borrow_scope();
        return TI_UNIT;
    }

    if n.kind == EXPR_FOR {
        var_ni := n.a;
        iter := n.b;
        body := n.c;
        infer_expr(iter);
        push_scope();
        push_borrow_scope();
        define_sym(var_ni, SYM_LOCAL, TI_INT, -1);
        infer_expr(body);
        pop_borrow_scope();
        pop_scope();
        return TI_UNIT;
    }

    if n.kind == EXPR_RANGE {
        st := infer_expr(n.a);
        et := infer_expr(n.b);
        if st != TI_INT { check_error(EC_TB_ADD, "Range start must be int", n.line, n.col); }
        if et != TI_INT { check_error(EC_TB_ADD, "Range end must be int", n.line, n.col); }
        return TI_INT;
    }

    if n.kind == EXPR_MATCH {
        match_expr := n.a;
        first_arm := n.b;
        infer_expr(match_expr);
        res : ., mut = TI_UNIT;
        ai : ., mut = 0;
        an : ., mut = first_arm;
        loop {
            if an < 0 { break; }
            arm_pat := g_ast[an].a;  // EXPR_ARM: a = pattern
            arm_body := g_ast[an].b;  // EXPR_ARM: b = body
            // Bind pattern variables in new scope
            push_scope();
            if arm_pat >= 0 {
                pat := g_ast[arm_pat];
                if pat.kind == EXPR_ENUMPAT {
                    // Bind sub-patterns
                    sub_pat := pat.b;
                    sub_count := pat.c;
                    spi : ., mut = 0;
                    spn : ., mut = sub_pat;
                    loop {
                        if spi >= sub_count { break; }
                        if spn >= 0 {
                            sp := g_ast[spn];
                            if sp.kind == EXPR_IDENT {
                                define_sym(sp.int_val, SYM_LOCAL, TI_INT, -1);
                            }
                            spn = spn + 1;
                        }
                        spi = spi + 1;
                    }
                }
                if pat.kind == EXPR_IDENT {
                    define_sym(pat.int_val, SYM_LOCAL, TI_INT, -1);
                }
            }
            push_borrow_scope();
            arm_ti := infer_expr(arm_body);
            pop_borrow_scope();
            if ai == 0 { res = arm_ti; }
            pop_scope();
            an = g_ast[an].c;  // next arm via linked list
            ai = ai + 1;
        }
        return res;
    }

    if n.kind == EXPR_LET {
        var_ni := n.a;
        type_node := n.b;
        val_node := n.c;
        val_ti := TI_UNIT;
        if val_node >= 0 {
            val_ti = infer_expr(val_node);
            // Check if value is a borrow (&x or &mut x), record the holder
            if g_ast[val_node].kind == EXPR_UNARY && g_ast[val_node].c == UOP_REF {
                borrowed_ni := borrow_var_name(g_ast[val_node].a);
                if borrowed_ni >= 0 {
                    mut_flag := g_ast[val_node].int_val;
                    record_borrow_holder(var_ni, borrowed_ni, mut_flag);
                }
            }
        }
        ti := val_ti;
        if type_node >= 0 { ti = resolve_type_node(type_node); }
        if g_strs[var_ni] != "_" {
            define_sym(var_ni, SYM_LOCAL, ti, -1);
        }
        return TI_UNIT;
    }

    if n.kind == EXPR_RETURN {
        if n.a >= 0 {
            return infer_expr(n.a);
        }
        return TI_UNIT;
    }

    if n.kind == EXPR_ENUM_CONSTRUCTOR {
        name_idx := n.a;
        first_arg := n.b;
        arg_count := n.c;
        si := lookup_sym_global(name_idx);
        if si >= 0 && g_syms[si].kind == SYM_FN {
            // Infer arg types
            ai : ., mut = 0;
            an : ., mut = first_arg;
            loop {
                if ai >= arg_count { break; }
                if an >= 0 {
                    infer_expr(an);
                    an = an + 1;
                }
                ai = ai + 1;
            }
            return g_syms[si].type_idx; // enum type
        }
        name := g_strs[name_idx];
        check_error(EC_N_UNDEFINED, "Undefined enum constructor '" + name + "'", n.line, n.col);
        return TI_UNIT;
    }

    if n.kind == EXPR_FIELD {
        obj := n.a;
        field_ni := n.int_val;
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
                    if fi >= g_structs[si].field_count { break; }
                    if str_intern(g_structs[si].field_names[fi]) == field_ni {
                        g_ast[node].data = fi;  // store field index for ir_gen
                        // Resolve field type, substituting generic params if needed
                        ft_node := g_structs[si].field_type_nodes[fi];
                        if ft_node >= 0 {
                            ftn := g_ast[ft_node];
                            if ftn.kind == EXPR_IDENT {
                                ft_name_idx := ftn.int_val;
                                // Check if this field type is a generic param (substitute if we have a generic apply)
                                if is_struct_generic(si, ft_name_idx) && get_type_kind(obj_ti) == TYP_GENERIC_APPLY {
                                        base_ti := get_type_data(obj_ti);
                                        ga_start := get_type_extra(obj_ti);
                                        ga_count := g_gen_apply_data[ga_start];
                                        // Find which generic param index
                                        gpi : ., mut = 0;
                                        loop {
                                            if gpi >= g_structs[si].generic_count { break; }
                                            if str_intern(g_structs[si].generic_names[gpi]) == ft_name_idx {
                                                // Use the corresponding arg from the generic apply
                                                if gpi < ga_count {
                                                    return g_gen_apply_data[ga_start + 1 + gpi];
                                                }
                                                break;
                                            }
                                            gpi = gpi + 1;
                                        }
                                }
                            }
                            return resolve_type_node(ft_node);
                        }
                        return g_structs[si].field_types[fi];
                    }
                    fi = fi + 1;
                }
            }
        }
        // Tuple field access: t.0, t.1
        if actual_ti >= 0 && actual_ti < g_type_count && get_type_kind(actual_ti) == TYP_TUPLE {
            field_name := g_strs[field_ni];
            idx := __builtin_str_to_int(field_name);
            tc := get_type_data(actual_ti);
            if idx >= 0 && idx < tc {
                data_start := get_type_extra(actual_ti);
                if g_ast[node].data != idx {
                    g_ast[node].data = idx;
                }
                return g_gen_apply_data[data_start + idx];
            }
        }
        return TI_UNIT;
    }

    if n.kind == EXPR_INDEX {
        arr_ti := infer_expr(n.a);
        idx_ti := infer_expr(n.b);
        arr_kind := get_type_kind(arr_ti);
        // Range index: arr[low..high] → slice type
        if g_ast[n.b].kind == EXPR_RANGE {
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
        check_error(EC_TK_INDEX, "Cannot index non-array type", n.line, n.col);
        return TI_INT;
    }

    if n.kind == EXPR_ASSIGN {
        target := n.a;
        val := n.b;
        tt := infer_expr(target);
        vt := infer_expr(val);
        if !type_equal(tt, vt) {
            check_error(EC_TA_ASSIGN, "Assignment type mismatch", n.line, n.col);
        }
        return vt;
    }

    if n.kind == EXPR_STRUCT {
        // Struct literal: a = name idx, b = first field value (wrapper), c = field count
        name_ni := n.a;
        // Check if struct is generic
        si := find_struct_by_name(name_ni);
        if si >= 0 && g_structs[si].generic_count > 0 {
            // Generic struct: infer concrete types from field values
            g_gen_map_count = 0;
            fi : ., mut = 0;
            fn2 : ., mut = n.b;
            loop {
                if fi >= n.c { break; }
                if fi < g_structs[si].field_count && fn2 >= 0 {
                    field_val_ti := infer_expr(fn2);
                    orig_type_node := g_structs[si].field_type_nodes[fi];
                    if orig_type_node >= 0 {
                        pn := g_ast[orig_type_node];
                        if pn.kind == EXPR_IDENT {
                            // Check if field type is a generic param
                            field_name_idx := pn.int_val;
                            if is_struct_generic(si, field_name_idx) && g_gen_map_count < MAX_GENERICS {
                                g_gen_map_names[g_gen_map_count] = field_name_idx;
                                g_gen_map_types[g_gen_map_count] = field_val_ti;
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
            g_gen_apply_data[ds] = g_gen_map_count;
            g_gen_apply_data_count = ds + 1;
            mi : ., mut = 0;
            loop {
                if mi >= g_gen_map_count { break; }
                g_gen_apply_data[ds + 1 + mi] = g_gen_map_types[mi];
                mi = mi + 1;
            }
            g_gen_apply_data_count = ds + 1 + g_gen_map_count;
            return alloc_type(TYP_GENERIC_APPLY, base_ti, ds);
        }
        // Non-generic struct
        ti := alloc_type(TYP_NAMED, name_ni, 0);
        fi : ., mut = 0;
        fn2 : ., mut = n.b;
        loop {
            if fi >= n.c { break; }
            if fn2 >= 0 {
                infer_expr(fn2); // wrapper node — forwards to value
                fn2 = fn2 + 1;
            }
            fi = fi + 1;
        }
        return ti;
    }

    if n.kind == EXPR_ARRAY {
        // Array literal: a = first elem, b = elem count
        elem_ti := TI_INT;
        ei : ., mut = 0;
        en : ., mut = n.a;
        loop {
            if ei >= n.b { break; }
            if en >= 0 {
                elem_ti = infer_expr(en);
                en = en + 1;
            }
            ei = ei + 1;
        }
        return alloc_type(TYP_ARRAY, elem_ti, n.b);
    }

    if n.kind == EXPR_BREAK { return TI_UNIT; }
    if n.kind == EXPR_CONTINUE { return TI_UNIT; }
    if n.kind == EXPR_WILDCARD { return TI_UNIT; }
    if n.kind == EXPR_MOVE {
        return infer_expr(n.a);
    }
    if n.kind == EXPR_UNSAFE {
        push_borrow_scope();
        ret := infer_expr(n.a);
        pop_borrow_scope();
        return ret;
    }
    if n.kind == EXPR_TRY {
        // Try operator: unwrap Option[T] → T, Result[T,E] → T
        inner_ti := infer_expr(n.a);
        if get_type_kind(inner_ti) == TYP_GENERIC_APPLY {
            base_ti := get_type_data(inner_ti);
            if get_type_kind(base_ti) == TYP_NAMED {
                base_ni := get_type_data(base_ti);
                base_name := g_strs[base_ni];
                if base_name == "Option" || base_name == "Result" {
                    ga_start := get_type_extra(inner_ti);
                    if g_gen_apply_data[ga_start] >= 1 {
                        return g_gen_apply_data[ga_start + 1]; // first type arg
                    }
                }
            }
        }
        return inner_ti;
    }
    if n.kind == EXPR_STRUCTPAT {
        return TI_UNIT;
    }
    if n.kind == EXPR_AS {
        // expr as Type — type cast
        inner_ti := infer_expr(n.a);
        type_node := n.b;
        return resolve_type_node(type_node);
    }
    if n.kind == EXPR_STMT {
        infer_expr(n.a);
        return TI_UNIT;
    }
    if n.kind == EXPR_TUPLE {
        // Tuple: create a TYP_TUPLE type with element types
        elem_idx := n.a;
        ec : ., mut = n.b;
        data_start := g_gen_apply_data_count;
        e : ., mut = 0;
        loop {
            if e >= ec { break; }
            elem_ti := infer_expr(elem_idx + e);
            g_gen_apply_data[g_gen_apply_data_count] = elem_ti;
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
    g_sym_count = 0;
    g_scope_depth = 0;
    g_diag_count = 0;
    g_gen_map_count = 0;
    g_gen_apply_data_count = 0;

    // First pass: collect declarations
    collect_decls();

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
        check_global_let(g_global_lets[i]);
        i = i + 1;
    }
}
