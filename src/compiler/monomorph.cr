// === monomorph.cr ===
// Generic monomorphization: instance cache + AST specialization.
// Each concrete instantiation of a generic function produces
// a specialized copy registered in g_funcs.

// ── Instance cache ──
// Each entry: 24 bytes = [original_func_ni, type_args_str_ni, specialized_fi]
g_gen_instances : string, mut;
g_gen_instance_count : int, mut;
g_gen_instance_cap : int, mut;

// ── Temporary substitution mapping (during clone) ──
// Parallel arrays: generic param name index → concrete type name index
g_gen_subst_old : string, mut;
g_gen_subst_new : string, mut;
g_gen_subst_count : int, mut;
g_gen_subst_cap : int, mut;

// ── Temporary dedup map (old AST node → new AST node during clone) ──
g_gen_dedup_old : string, mut;
g_gen_dedup_new : string, mut;
g_gen_dedup_count : int, mut;
g_gen_dedup_cap : int, mut;

// ============================================================
// Grow helpers
// ============================================================
fn grow_gen_instances(needed: int) {
    if needed < g_gen_instance_cap { return; }
    nc : ., mut = g_gen_instance_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 24); _dyncpy(g_gen_instances, g_gen_instance_cap * 24, nb);
    g_gen_instances = nb; g_gen_instance_cap = nc; }

// 效应/纯度修正 Task 1：实例 → 源映射侧表（声明在 globals.cr——checker.cr 的
// compute_all_purity 要读它，bootstrap 名字解析按声明序）。
fn grow_purity_inst(needed: int) {
    if needed < g_purity_inst_cap { return; }
    nc : ., mut = g_purity_inst_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 24); _dyncpy(g_purity_inst, g_purity_inst_cap * 24, nb);
    g_purity_inst = nb; g_purity_inst_cap = nc; }

fn grow_gen_subst(needed: int) {
    if needed < g_gen_subst_cap { return; }
    nc : ., mut = g_gen_subst_cap * 2; if nc < 16 { nc = 16; } if nc < needed { nc = needed + 16; }
    sz := nc * 8;
    n1 := alloc(sz); _dyncpy(g_gen_subst_old, g_gen_subst_cap * 8, n1); g_gen_subst_old = n1;
    n2 := alloc(sz); _dyncpy(g_gen_subst_new, g_gen_subst_cap * 8, n2); g_gen_subst_new = n2;
    g_gen_subst_cap = nc; }

fn grow_gen_dedup(needed: int) {
    if needed < g_gen_dedup_cap { return; }
    nc : ., mut = g_gen_dedup_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    sz := nc * 8;
    n1 := alloc(sz); _dyncpy(g_gen_dedup_old, g_gen_dedup_cap * 8, n1); g_gen_dedup_old = n1;
    n2 := alloc(sz); _dyncpy(g_gen_dedup_new, g_gen_dedup_cap * 8, n2); g_gen_dedup_new = n2;
    g_gen_dedup_cap = nc; }

// ============================================================
// Substitution mapping
// ============================================================

// Parse comma-separated type_args and build substitution mapping
// from generic param names (from FuncInfo) to concrete type name indices.
fn gen_build_subst(func_ni: int, type_args: string) {
    g_gen_subst_count = 0; g_gen_subst_cap = 0;
    gc := fi_generic_count(func_ni);
    if gc <= 0 { return; }
    pos : ., mut = 0;
    gi : ., mut = 0;
    loop {
        if gi >= gc { break; }
        if load8(type_args, pos) == 0 { break; }
        start := pos;
        loop {
            c := load8(type_args, pos);
            if c == 0 || c == 44 { break; }  // null or comma
            pos = pos + 1;
        }
        type_name := str_sub(type_args, start, pos - start);
        if load8(type_args, pos) == 44 { pos = pos + 1; }
        gen_param_ni := fi_generic_name(func_ni, gi);
        concrete_ni := str_intern(type_name);
        grow_gen_subst(g_gen_subst_count + 1);
        w64(g_gen_subst_old, g_gen_subst_count * 8, gen_param_ni);
        w64(g_gen_subst_new, g_gen_subst_count * 8, concrete_ni);
        g_gen_subst_count = g_gen_subst_count + 1;
        gi = gi + 1;
    }
}

// Look up substitution for a generic param name.
// Returns concrete type name index, or -1 if not a generic param.
fn gen_lookup_subst(name_ni: int) -> int {
    mi : ., mut = 0;
    loop {
        if mi >= g_gen_subst_count { break; }
        if r64(g_gen_subst_old, mi * 8) == name_ni {
            return r64(g_gen_subst_new, mi * 8);
        }
        mi = mi + 1;
    }
    return -1;
}

// Check if a name is a base type. Returns the TY_* constant, or -1.
fn gen_base_type_tv(name_ni: int) -> int {
    s := istr_get(name_ni);
    if s == "int" { return TY_INT; }
    if s == "dex" { return TY_DEX; }
    if s == "bool" { return TY_BOOL; }
    if s == "string" { return TY_STRING; }
    if s == "char" { return TY_CHAR; }
    if s == "unit" { return TY_UNIT; }
    if s == "never" { return TY_NEVER; }
    return -1;
}

// ============================================================
// Dedup mapping for tree clone
// ============================================================

fn gen_dedup_find(old_node: int) -> int {
    mi : ., mut = 0;
    loop {
        if mi >= g_gen_dedup_count { break; }
        if r64(g_gen_dedup_old, mi * 8) == old_node {
            return r64(g_gen_dedup_new, mi * 8);
        }
        mi = mi + 1;
    }
    return -1;
}

fn gen_dedup_add(old_node: int, new_node: int) {
    grow_gen_dedup(g_gen_dedup_count + 1);
    w64(g_gen_dedup_old, g_gen_dedup_count * 8, old_node);
    w64(g_gen_dedup_new, g_gen_dedup_count * 8, new_node);
    g_gen_dedup_count = g_gen_dedup_count + 1;
}

// ============================================================
// Deep AST clone with generic param substitution
// ============================================================

// Clone a sequence of g_block_stmts entries, substituting each one.
fn gen_clone_block(start: int, count: int) -> int {
    if count <= 0 { return -1; }
    new_start := g_block_stmt_count;
    grow_block_stmts(new_start + count);
    // Reserve the outer block range before cloning children. Nested blocks
    // append after this range instead of reusing and overwriting new_start.
    g_block_stmt_count = new_start + count;
    i : ., mut = 0;
    loop {
        if i >= count { break; }
        old_stmt := r64(g_block_stmts, (start + i) * 8);
        new_stmt := gen_clone_tree(old_stmt);
        w64(g_block_stmts, (new_start + i) * 8, new_stmt);
        i = i + 1;
    }
    return new_start;
}

// Clone consecutive AST nodes (for struct fields, array elements, etc.)
fn gen_clone_consecutive(start: int, count: int) -> int {
    if count <= 0 || start < 0 { return -1; }
    // Each cloned node is appended to g_ast by gen_clone_tree, so they end up consecutive.
    first_new := g_ast_count;
    i : ., mut = 0;
    loop {
        if i >= count { break; }
        gen_clone_tree(start + i);
        i = i + 1;
    }
    return first_new;
}

// Deep-clone an AST subtree, substituting generic param references
// with concrete type name references.
fn gen_clone_tree(node: int) -> int {
    if node < 0 { return -1; }

    // Dedup: if this node was already cloned, return the existing clone.
    dup := gen_dedup_find(node);
    if dup >= 0 { return dup; }

    k := ast_kind(node);
    a := ast_a(node); b := ast_b(node); c := ast_c(node);
    iv := ast_int_val(node); tv := ast_type_val(node);
    d := ast_data(node); ln := ast_line(node); cl := ast_col(node);

    // ── EXPR_IDENT: might be a generic param reference ──
    if k == EXPR_IDENT {
        ni := iv;
        sub := gen_lookup_subst(ni);
        if sub >= 0 {
            // Substitute generic param with concrete type
            base_tv := gen_base_type_tv(sub);
            if base_tv >= 0 {
                // Base type reference (int, float, etc.) → kind=0 node with type_val
                n := ast_alloc(0, 0, 0, 0, 0, base_tv, 0, ln, cl);
                gen_dedup_add(node, n); return n;
            }
            // Named type (struct name, etc.) → EXPR_IDENT with concrete name
            n := ast_alloc(k, a, b, c, sub, tv, d, ln, cl);
            gen_dedup_add(node, n); return n;
        }
        // Not a generic param — clone as-is
        n := ast_alloc(k, a, b, c, ni, tv, d, ln, cl);
        gen_dedup_add(node, n); return n;
    }

    // ── EXPR_NONE (kind=0): base type node OR struct field wrapper ──
    if k == EXPR_NONE {
        if a >= 0 && a != node {
            // Struct literal field or pattern wrapper: a = value expression
            a2 := gen_clone_tree(a);
            n := ast_alloc(k, a2, b, c, iv, tv, d, ln, cl);
            gen_dedup_add(node, n); return n;
        }
        // Base type node or empty: no AST children
        n := ast_alloc(k, a, b, c, iv, tv, d, ln, cl);
        gen_dedup_add(node, n); return n;
    }

    // ── Leaf nodes (no AST children) ──
    if k == EXPR_INT { n := ast_alloc(k, a, b, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }
    if k == EXPR_DEX { n := ast_alloc(k, a, b, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }
    if k == EXPR_BOOL { n := ast_alloc(k, a, b, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }
    if k == EXPR_STRING { n := ast_alloc(k, a, b, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }
    if k == EXPR_CHAR { n := ast_alloc(k, a, b, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }
    if k == EXPR_WILDCARD { n := ast_alloc(k, a, b, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }
    if k == EXPR_BREAK { n := ast_alloc(k, a, b, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }
    if k == EXPR_CONTINUE { n := ast_alloc(k, a, b, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }

    // ── Single child in `a` ──
    if k == EXPR_RETURN { a2 := gen_clone_tree(a); n := ast_alloc(k, a2, b, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }
    if k == EXPR_YIELD { a2 := gen_clone_tree(a); n := ast_alloc(k, a2, b, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }
    if k == EXPR_AWAIT { a2 := gen_clone_tree(a); n := ast_alloc(k, a2, b, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }
    if k == EXPR_MOVE { a2 := gen_clone_tree(a); n := ast_alloc(k, a2, b, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }
    if k == EXPR_UNSAFE { a2 := gen_clone_tree(a); n := ast_alloc(k, a2, b, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }
    if k == EXPR_TRY { a2 := gen_clone_tree(a); n := ast_alloc(k, a2, b, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }
    if k == EXPR_UNARY { a2 := gen_clone_tree(a); n := ast_alloc(k, a2, b, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }
    if k == EXPR_FIELD { a2 := gen_clone_tree(a); n := ast_alloc(k, a2, b, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }
    if k == EXPR_STMT { a2 := gen_clone_tree(a); n := ast_alloc(k, a2, b, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }
    if k == EXPR_GO { a2 := gen_clone_tree(a); n := ast_alloc(k, a2, b, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }

    // ── Two children: `a` and `b` ──
    if k == EXPR_BINARY { a2 := gen_clone_tree(a); b2 := gen_clone_tree(b); n := ast_alloc(k, a2, b2, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }
    if k == EXPR_ASSIGN { a2 := gen_clone_tree(a); b2 := gen_clone_tree(b); n := ast_alloc(k, a2, b2, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }
    if k == EXPR_INDEX { a2 := gen_clone_tree(a); b2 := gen_clone_tree(b); n := ast_alloc(k, a2, b2, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }
    if k == EXPR_WHILE { a2 := gen_clone_tree(a); b2 := gen_clone_tree(b); n := ast_alloc(k, a2, b2, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }
    if k == EXPR_LOOP { a2 := gen_clone_tree(a); n := ast_alloc(k, a2, b, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }
    if k == EXPR_RANGE { a2 := gen_clone_tree(a); b2 := gen_clone_tree(b); n := ast_alloc(k, a2, b2, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }
    if k == EXPR_AS { a2 := gen_clone_tree(a); b2 := gen_clone_tree(b); n := ast_alloc(k, a2, b2, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }

    // ── EXPR_CALL: a=func_node(YES), b=first_ARG(YES), c=arg_count(NOT) ──
    if k == EXPR_CALL { a2 := gen_clone_tree(a); b2 := gen_clone_tree(b); n := ast_alloc(k, a2, b2, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }

    // ── EXPR_ARG: a=expr(YES), b=next_arg(YES or -1) ──
    if k == EXPR_ARG { a2 := gen_clone_tree(a); b2 := gen_clone_tree(b); n := ast_alloc(k, a2, b2, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }

    // ── EXPR_IF: a=cond(YES), b=then(YES), c=else(YES or -1) ──
    if k == EXPR_IF { a2 := gen_clone_tree(a); b2 := gen_clone_tree(b); c2 := gen_clone_tree(c); n := ast_alloc(k, a2, b2, c2, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }

    // ── EXPR_FN: a=name_ni(NOT), b=first_param(YES), c=param_count(NOT), d=body(YES) ──
    if k == EXPR_FN { d2 := gen_clone_tree(d); n := ast_alloc(k, a, b, c, iv, tv, d2, ln, cl); gen_dedup_add(node, n); return n; }

    // ── EXPR_PARAM: a=name_ni(NOT), d=type_node(YES) ──
    if k == EXPR_PARAM { d2 := gen_clone_tree(d); n := ast_alloc(k, a, b, c, iv, tv, d2, ln, cl); gen_dedup_add(node, n); return n; }

    // ── EXPR_BLOCK: children in g_block_stmts ──
    if k == EXPR_BLOCK { new_start := gen_clone_block(a, b); n := ast_alloc(k, new_start, b, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }

    // ── EXPR_FOR: a=var_name_ni(NOT), b=iter(YES), c=body(YES) ──
    if k == EXPR_FOR { b2 := gen_clone_tree(b); c2 := gen_clone_tree(c); n := ast_alloc(k, a, b2, c2, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }

    // ── EXPR_LET: a=name_ni(NOT), b=type(YES or -1), c=value(YES or -1), d=is_mut(NOT) ──
    if k == EXPR_LET { b2 := gen_clone_tree(b); c2 := gen_clone_tree(c); n := ast_alloc(k, a, b2, c2, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }

    // ── EXPR_STRUCT: a=type_name_ni(NOT), b=first wrapper(YES, consecutive), c=field_count(NOT)；
    //    wrapper.a = field value node（F5 契约，见 parser.cr struct 字面量分支）──
    if k == EXPR_STRUCT {
        if b >= 0 && c > 0 {
            // 字段值先逐个深克隆（各自子树自占槽位），再统建连续 wrapper——
            // 不得「克隆值后随建 wrapper」逐元素交错：wrapper 将不连续（与 parser 同契约）。
            nvs : string, mut = alloc(c * 8);
            i : ., mut = 0;
            loop {
                if i >= c { break; }
                vn : ., mut = -1;
                if b + i >= 0 { vn = ast_a(b + i); }
                w64(nvs, i * 8, gen_clone_tree(vn));
                i = i + 1;
            }
            new_first := g_ast_count;
            i = 0;
            loop {
                if i >= c { break; }
                ast_alloc(EXPR_NONE, r64(nvs, i * 8), 0, 0, 0, 0, 0, ln, cl);
                i = i + 1;
            }
            n := ast_alloc(k, a, new_first, c, iv, tv, d, ln, cl);
            gen_dedup_add(node, n); return n;
        }
        n := ast_alloc(k, a, b, c, iv, tv, d, ln, cl);
        gen_dedup_add(node, n); return n;
    }

    // ── EXPR_ARRAY: a=first wrapper(YES, consecutive), b=elem_count(NOT)；
    //    wrapper.a = element value node（F5 契约，见 parser.cr 下标分支）──
    if k == EXPR_ARRAY {
        if a >= 0 && b > 0 {
            // 元素值先逐个深克隆（各自子树自占槽位），再统建连续 wrapper（与 parser 同契约）。
            nvs : string, mut = alloc(b * 8);
            i : ., mut = 0;
            loop {
                if i >= b { break; }
                vn : ., mut = -1;
                if a + i >= 0 { vn = ast_a(a + i); }
                w64(nvs, i * 8, gen_clone_tree(vn));
                i = i + 1;
            }
            new_first := g_ast_count;
            i = 0;
            loop {
                if i >= b { break; }
                ast_alloc(EXPR_NONE, r64(nvs, i * 8), 0, 0, 0, 0, 0, ln, cl);
                i = i + 1;
            }
            n := ast_alloc(k, new_first, b, c, iv, tv, d, ln, cl);
            gen_dedup_add(node, n); return n;
        }
        n := ast_alloc(k, a, b, c, iv, tv, d, ln, cl);
        gen_dedup_add(node, n); return n;
    }

    // ── EXPR_TUPLE: a=first wrapper(YES, consecutive), b=elem_count(NOT)；
    //    wrapper.a = element value node（F5 契约，见 parser.cr 元组分支）──
    if k == EXPR_TUPLE {
        if a >= 0 && b > 0 {
            // 元素值先逐个深克隆（各自子树自占槽位），再统建连续 wrapper——
            // 不得「克隆值后随建 wrapper」逐元素交错：wrapper 将不连续（与 parser 同契约）。
            nvs : string, mut = alloc(b * 8);
            i : ., mut = 0;
            loop {
                if i >= b { break; }
                vn : ., mut = -1;
                if a + i >= 0 { vn = ast_a(a + i); }
                w64(nvs, i * 8, gen_clone_tree(vn));
                i = i + 1;
            }
            new_first := g_ast_count;
            i = 0;
            loop {
                if i >= b { break; }
                ast_alloc(EXPR_NONE, r64(nvs, i * 8), 0, 0, 0, 0, 0, ln, cl);
                i = i + 1;
            }
            n := ast_alloc(k, new_first, b, c, iv, tv, d, ln, cl);
            gen_dedup_add(node, n); return n;
        }
        n := ast_alloc(k, a, b, c, iv, tv, d, ln, cl);
        gen_dedup_add(node, n); return n;
    }

    // ── EXPR_GENERIC_APPLY: a=base_name_ni(NOT), b=first_arg(YES, consecutive), c=arg_count(NOT) ──
    if k == EXPR_GENERIC_APPLY {
        if b >= 0 && c > 0 {
            new_first := gen_clone_consecutive(b, c);
            n := ast_alloc(k, a, new_first, c, iv, tv, d, ln, cl);
            gen_dedup_add(node, n); return n;
        }
        n := ast_alloc(k, a, b, c, iv, tv, d, ln, cl);
        gen_dedup_add(node, n); return n;
    }

    // ── EXPR_MATCH: a=expr(YES), b=first_arm(YES), c=arm_count(NOT) ──
    if k == EXPR_MATCH { a2 := gen_clone_tree(a); b2 := gen_clone_tree(b); n := ast_alloc(k, a2, b2, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }

    // ── EXPR_ARM: a=pattern(YES), b=body(YES) ──
    if k == EXPR_ARM { a2 := gen_clone_tree(a); b2 := gen_clone_tree(b); n := ast_alloc(k, a2, b2, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }

    // ── EXPR_ENUM_CONSTRUCTOR: a=name_ni(NOT), b=first_arg(YES), c=arg_count(NOT) ──
    if k == EXPR_ENUM_CONSTRUCTOR { b2 := gen_clone_tree(b); n := ast_alloc(k, a, b2, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }

    // ── EXPR_ENUMPAT: a=name_ni(NOT), b=first_subpat(YES, consecutive), c=subpat_count(NOT) ──
    if k == EXPR_ENUMPAT { b2 := gen_clone_consecutive(b, c); n := ast_alloc(k, a, b2, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }

    // ── EXPR_STRUCTPAT: a=name_ni(NOT), b=first wrapper(YES, consecutive), c=field_count(NOT)；
    //    wrapper.a = 子模式节点（F5 契约，见 parser.cr struct 模式分支）──
    if k == EXPR_STRUCTPAT {
        if b >= 0 && c > 0 {
            nvs : string, mut = alloc(c * 8);
            i : ., mut = 0;
            loop {
                if i >= c { break; }
                vn : ., mut = -1;
                if b + i >= 0 { vn = ast_a(b + i); }
                w64(nvs, i * 8, gen_clone_tree(vn));
                i = i + 1;
            }
            new_first := g_ast_count;
            i = 0;
            loop {
                if i >= c { break; }
                ast_alloc(EXPR_NONE, r64(nvs, i * 8), 0, 0, 0, 0, 0, ln, cl);
                i = i + 1;
            }
            n := ast_alloc(k, a, new_first, c, iv, tv, d, ln, cl);
            gen_dedup_add(node, n); return n;
        }
        n := ast_alloc(k, a, b, c, iv, tv, d, ln, cl);
        gen_dedup_add(node, n); return n;
    }

    // ── EXPR_AT: a=name_ni(NOT), b=args_node(YES or -1) ──
    if k == EXPR_AT { b2 := gen_clone_tree(b); n := ast_alloc(k, a, b2, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }

    // ── EXPR_FLOW: a=name_ni(NOT), b=param_count(NOT), c=first_param(YES), d=body(YES) ──
    if k == EXPR_FLOW { c2 := gen_clone_tree(c); d2 := gen_clone_tree(d); n := ast_alloc(k, a, b, c2, iv, tv, d2, ln, cl); gen_dedup_add(node, n); return n; }

    // ── Fallback (shouldn't normally reach here) ──
    // Conservatively clone all pointer-sized fields as AST children.
    a2 := gen_clone_tree(a); b2 := gen_clone_tree(b); c2 := gen_clone_tree(c); d2 := gen_clone_tree(d);
    n := ast_alloc(k, a2, b2, c2, iv, tv, d2, ln, cl);
    gen_dedup_add(node, n); return n;
}

// ============================================================
// Cache API: find or create specialized instance
// ============================================================

// Find a specialized instance in the cache.
// func_ni: the original generic FuncInfo index
// type_args: comma-separated concrete type names (e.g. "int,string")
// Returns the specialized function index, or -1 if not found.
fn gen_find_cached(func_ni: int, type_args: string) -> int {
    i : ., mut = 0;
    loop {
        if i >= g_gen_instance_count { break; }
        if r64(g_gen_instances, i * 24) == func_ni {
            cached_args_ni := r64(g_gen_instances, i * 24 + 8);
            if istr_eq(cached_args_ni, type_args) != 0 {
                return r64(g_gen_instances, i * 24 + 16);
            }
        }
        i = i + 1;
    }
    return -1;
}

// Find or create a specialized instance of a generic function.
// func_ni: the original generic FuncInfo index
// type_args: comma-separated concrete type names (e.g. "int,string")
// Returns the specialized function index.
fn gen_find_or_create(func_ni: int, type_args: string) -> int {
    cached := gen_find_cached(func_ni, type_args);
    if cached >= 0 { return cached; }
    return gen_create_instance(func_ni, type_args);
}

// Create a specialized copy of a generic function.
// Steps:
//   1. Build generic param → concrete type name substitution mapping
//   2. Deep-clone the function's AST subtree with type substitution
//   3. Register the new function in g_funcs
//   4. Cache the new function index
//   5. Return the new function index
fn gen_create_instance(func_ni: int, type_args: string) -> int {
    // 1. Build substitution mapping
    gen_build_subst(func_ni, type_args);

    // 2. Clone the original function AST
    orig_fn_node := fi_ast_node(func_ni);
    g_gen_dedup_count = 0; g_gen_dedup_cap = 0;
    new_fn_node := gen_clone_tree(orig_fn_node);

    // Compute mangled name: "orig_name[type_args]" for unique identification
    orig_name := istr_get(fi_name(func_ni));
    mangled_name : ., mut = orig_name + "[" + type_args + "]";
    mangled_ni := str_intern(mangled_name);
    // Update the cloned AST node's name to the mangled name
    ast_set_a(new_fn_node, mangled_ni);

    // 3. Register new function in g_funcs
    new_fi := g_func_count;
    grow_funcs(new_fi + 1);

    // Use mangled name for unique lookup
    fi_set_name(new_fi, mangled_ni);

    // Clone params: param type info from FuncInfo
    pc := fi_param_count(func_ni);
    fi_set_param_count(new_fi, pc);
    pi : ., mut = 0;
    loop {
        if pi >= pc { break; }
        fi_set_param_type(new_fi, pi, fi_param_type(func_ni, pi));
        pi = pi + 1;
    }

    // Return type (set from original; will be re-checked)
    fi_set_return_type(new_fi, fi_return_type(func_ni));

    // AST node reference
    fi_set_ast_node(new_fi, new_fn_node);

    // Specialized instance has zero generic params (they've been substituted)
    fi_set_generic_count(new_fi, 0);

    g_func_count = new_fi + 1;

    // 4. Cache the new function
    type_args_ni := str_intern(type_args);
    grow_gen_instances(g_gen_instance_count + 1);
    w64(g_gen_instances, g_gen_instance_count * 24, func_ni);
    w64(g_gen_instances, g_gen_instance_count * 24 + 8, type_args_ni);
    w64(g_gen_instances, g_gen_instance_count * 24 + 16, new_fi);
    g_gen_instance_count = g_gen_instance_count + 1;

    // 效应/纯度修正 Task 1：登记实例 → 源（纯度回填用，见 globals.cr 表注）。
    // 注意：不在此处写 fi_set_ispure(new_fi, fi_ispure(func_ni))——本时点（IR 生成期）
    // 源函数还没有真纯度（真纯度只能由全程序 IR 体算，见 checker.cr 头注），
    // 抄过来的是乐观默认值，会把有效应泛型实例错标为纯。实例纯度由其自身体
    // 在 df_state_finalize 算出；源函数纯度 = 实例合取（compute_all_purity 回填）。
    grow_purity_inst(g_purity_inst_count + 1);
    w64(g_purity_inst, g_purity_inst_count * 24, func_ni);
    w64(g_purity_inst, g_purity_inst_count * 24 + 8, type_args_ni);
    w64(g_purity_inst, g_purity_inst_count * 24 + 16, new_fi);
    g_purity_inst_count = g_purity_inst_count + 1;

    // 5. Return new function index
    return new_fi;
}
