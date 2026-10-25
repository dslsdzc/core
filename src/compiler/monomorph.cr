// === monomorph.cr ===
// Generic monomorphization: instance cache + AST specialization.
// Each concrete instantiation of a generic function produces
// a specialized copy registered in g_funcs.

// ── Instance cache ──
// Each entry: 24 bytes = [original_func_ni, type_args_str_ni, specialized_fi]
g_gen_instances : string, mut
g_gen_instance_count : int, mut
g_gen_instance_cap : int, mut

// ── Temporary substitution mapping (during clone) ──
// Parallel arrays mapping a generic parameter name index to a concrete type name index.
g_gen_subst_old : string, mut
g_gen_subst_new : string, mut
g_gen_subst_count : int, mut
g_gen_subst_cap : int, mut

// Type-row substitution table. It is parallel to the name table above:
// g_gen_subst_old maps a name index to an argument type row. The source is the
// call-site binding block from checker. On a hit, inst_type_node_of_ti builds a
// complete type node, which can represent named, composite, and generic types.
// A missing row falls back to the name path.
g_gen_subst_tis : string, mut
g_gen_subst_tis_count : int, mut
g_gen_subst_tis_cap : int, mut

// Temporary dedup map from an old AST node to its new clone.
g_gen_dedup_old : string, mut
g_gen_dedup_new : string, mut
g_gen_dedup_count : int, mut
g_gen_dedup_cap : int, mut

// Defensive struct-pattern validation for instances. The checker resolves field
// types on each wrapper (wrapper.data = ti+1); if one still contains an
// unresolved generic parameter after substitution, the clone fails closed.
g_gen_structpat_bad : int, mut
g_gen_structpat_bad_line : int, mut
g_gen_structpat_bad_col : int, mut

// ============================================================
// Grow helpers
// ============================================================
fn grow_gen_instances(needed: int):
    if needed < g_gen_instance_cap:
        return
    nc : ., mut = g_gen_instance_cap * 2
    if nc < 64:
        nc = 64
    if nc < needed:
        nc = needed + 64
    nb := alloc(nc * 24)
    cell_copy(g_gen_instances, g_gen_instance_cap * 24, nb)
    g_gen_instances = nb
    g_gen_instance_cap = nc

// Instance-to-source mapping for purity. It is declared in globals.cr because
// checker's compute_all_purity reads it, and bootstrap name resolution follows
// declaration order.
fn grow_purity_inst(needed: int):
    if needed < g_purity_inst_cap:
        return
    nc : ., mut = g_purity_inst_cap * 2
    if nc < 64:
        nc = 64
    if nc < needed:
        nc = needed + 64
    nb := alloc(nc * 24)
    cell_copy(g_purity_inst, g_purity_inst_cap * 24, nb)
    g_purity_inst = nb
    g_purity_inst_cap = nc

fn grow_gen_subst(needed: int):
    if needed < g_gen_subst_cap:
        return
    nc : ., mut = g_gen_subst_cap * 2
    if nc < 16:
        nc = 16
    if nc < needed:
        nc = needed + 16
    sz := nc * 8
    n1 := alloc(sz)
    cell_copy(g_gen_subst_old, g_gen_subst_cap * 8, n1)
    g_gen_subst_old = n1
    n2 := alloc(sz)
    cell_copy(g_gen_subst_new, g_gen_subst_cap * 8, n2)
    g_gen_subst_new = n2
    g_gen_subst_cap = nc

fn grow_gen_dedup(needed: int):
    if needed < g_gen_dedup_cap:
        return
    nc : ., mut = g_gen_dedup_cap * 2
    if nc < 64:
        nc = 64
    if nc < needed:
        nc = needed + 64
    sz := nc * 8
    n1 := alloc(sz)
    cell_copy(g_gen_dedup_old, g_gen_dedup_cap * 8, n1)
    g_gen_dedup_old = n1
    n2 := alloc(sz)
    cell_copy(g_gen_dedup_new, g_gen_dedup_cap * 8, n2)
    g_gen_dedup_new = n2
    g_gen_dedup_cap = nc

// Grow the type-row substitution table. It has the same length as g_gen_subst_old.
fn grow_gen_subst_tis(needed: int):
    if needed < g_gen_subst_tis_cap:
        return
    nc : ., mut = g_gen_subst_tis_cap * 2
    if nc < 16:
        nc = 16
    if nc < needed:
        nc = needed + 16
    nb := alloc(nc * 8)
    cell_copy(g_gen_subst_tis, g_gen_subst_tis_cap * 8, nb)
    g_gen_subst_tis = nb
    g_gen_subst_tis_cap = nc

// ============================================================
// Substitution mapping
// ============================================================

// Parse comma-separated type_args and build substitution mapping
// from generic param names (from FuncInfo) to concrete type name indices.
fn gen_build_subst(func_ni: int, type_args: string):
    g_gen_subst_count = 0
    g_gen_subst_cap = 0
    gc := fi_generic_count(func_ni)
    if gc <= 0:
        return
    pos : ., mut = 0
    gi : ., mut = 0
    loop:
        if gi >= gc:
            break
        if cell_load_byte(type_args, pos) == 0:
            break
        start := pos
        loop:
            c := cell_load_byte(type_args, pos)
            if c == 0 || c == 44:
                break
            // null or comma
            pos = pos + 1
        type_name := str_sub(type_args, start, pos - start)
        if cell_load_byte(type_args, pos) == 44:
            pos = pos + 1
        gen_param_ni := fi_generic_name(func_ni, gi)
        concrete_ni := str_intern(type_name)
        grow_gen_subst(g_gen_subst_count + 1)
        cell_store(g_gen_subst_old, g_gen_subst_count * 8, gen_param_ni)
        cell_store(g_gen_subst_new, g_gen_subst_count * 8, concrete_ni)
        g_gen_subst_count = g_gen_subst_count + 1
        gi = gi + 1

// Load a call-site binding block into the type-row substitution table. The block
// is [count, ti...], with the i-th entry for the i-th generic parameter, in the
// same order as the name table. Returns the number loaded, or 0 when the block is
// absent or invalid; the caller then falls back to the name path.
fn gen_build_subst_tis(func_ni: int, bstart: int) -> int:
    g_gen_subst_tis_count = 0
    g_gen_subst_tis_cap = 0
    if bstart < 0:
        return 0
    gc := fi_generic_count(func_ni)
    if gc <= 0:
        return 0
    if bstart >= g_gen_binds_count:
        return 0
    cnt := cell_load(g_gen_binds, bstart * 8)
    if cnt != gc:
        return 0
    // The block length must equal the parameter count; otherwise reject it.
    if bstart + 1 + cnt > g_gen_binds_count:
        return 0
    grow_gen_subst_tis(gc)
    i : ., mut = 0
    loop:
        if i >= gc:
            break
        t := cell_load(g_gen_binds, (bstart + 1 + i) * 8)
        if t < 0:
            return 0
        // An unbound entry discards the whole block; no partial substitution.
        if inst_ti_concrete(t) == 0:
            return 0
        // A remaining generic-parameter row also discards the whole block.
        cell_store(g_gen_subst_tis, i * 8, t)
        g_gen_subst_tis_count = i + 1
        i = i + 1
    return g_gen_subst_tis_count

// Look up substitution for a generic param name.
// Returns concrete type name index, or -1 if not a generic param.
fn gen_lookup_subst(name_ni: int) -> int:
    mi : ., mut = 0
    loop:
        if mi >= g_gen_subst_count:
            break
        if cell_load(g_gen_subst_old, mi * 8) == name_ni:
            return cell_load(g_gen_subst_new, mi * 8)
        mi = mi + 1
    return -1

// Check if a name is a base type. Returns the TY_* constant, or -1.
fn gen_base_type_tv(name_ni: int) -> int:
    s := istr_get(name_ni)
    if s == "int":
        return TY_INT
    if s == "dex":
        return TY_DEX
    if s == "bool":
        return TY_BOOL
    if s == "string":
        return TY_STRING
    if s == "char":
        return TY_CHAR
    if s == "unit":
        return TY_UNIT
    if s == "never":
        return TY_NEVER
    return -1

// Type-row helpers: key, syntax node, and substitution.
// The old instance key was built from argument IR variable types as a name string.
// Non-native types (struct, tuple, slice, ref) all collapsed to "int", so two
// different struct arguments produced the same instance. Type substitution also
// replaced names as text, which could substitute a wrong name into a generic
// parameter position. These helpers fix both problems:
//   1. inst_key_of_ti: type row to a canonical structural key. Different types get
//      different keys.
//   2. inst_type_node_of_ti: type row to a type syntax node for substitution.
//   3. gen_subst_ti: replace generic parameter rows in nested call-site bindings
//      using the current instance.
// Key separators: "|" inside a type, "; " for array lengths, and "," only between
// parameters, because gen_build_subst splits on commas. A canonical key must not
// contain a comma.
// Syntax node synthesis only handles types whose root occupies one slot: native,
// named, and generic-parameter types. EXPR_GENERIC_APPLY reads arguments at
// first_arg + i, so argument roots must be consecutive; a composite argument's
// subtree would be interleaved. Composite arguments return -1 and fall back to the
// name path.

fn inst_key_of_ti(ti: int) -> string:
    k := get_type_kind(ti)
    if k < 0:
        return "?"
    if k == TYP_BASE:
        d := get_type_data(ti)
        if d == TY_INT:
            return "int"
        if d == TY_DEX:
            return "dex"
        if d == TY_BOOL:
            return "bool"
        if d == TY_STRING:
            return "string"
        if d == TY_CHAR:
            return "char"
        if d == TY_UNIT:
            return "unit"
        if d == TY_NEVER:
            return "never"
        return "#" + int_str(d)
    if k == TYP_NAMED || k == TYP_GENERIC_PARAM:
        return istr_get(get_type_data(ti))
    if k == TYP_GENERIC_APPLY:
        base := get_type_data(ti)
        s : ., mut = "?"
        if get_type_kind(base) == TYP_NAMED:
            s = istr_get(get_type_data(base))
        s = s + "["
        start := get_type_extra(ti)
        cnt := cell_load(g_gen_apply_data, start * 8)
        i : ., mut = 0
        loop:
            if i >= cnt:
                break
            if i > 0:
                s = s + "|"
            s = s + inst_key_of_ti(cell_load(g_gen_apply_data, (start + 1 + i) * 8))
            i = i + 1
        return s + "]"
    if k == TYP_ARRAY:
        return "[" + inst_key_of_ti(get_type_data(ti)) + "; " + int_str(get_type_extra(ti)) + "]"
    if k == TYP_SLICE:
        return "[" + inst_key_of_ti(get_type_data(ti)) + "]"
    if k == TYP_REF:
        if get_type_extra(ti) != 0:
            return "&mut " + inst_key_of_ti(get_type_data(ti))
        return "&" + inst_key_of_ti(get_type_data(ti))
    if k == TYP_PTR:
        return "*" + inst_key_of_ti(get_type_data(ti))
    if k == TYP_OPTIONAL:
        return inst_key_of_ti(get_type_data(ti)) + "?"
    if k == TYP_NULL:
        return "null"
    if k == TYP_DYN:
        return "dyn"
    if k == TYP_TUPLE:
        s : ., mut = "("
        cnt2 := get_type_data(ti)
        start2 := get_type_extra(ti)
        i2 : ., mut = 0
        loop:
            if i2 >= cnt2:
                break
            if i2 > 0:
                s = s + "|"
            s = s + inst_key_of_ti(cell_load(g_gen_apply_data, (start2 + i2) * 8))
            i2 = i2 + 1
        return s + ")"
    return "#" + int_str(ti)   // unknown kind: fall back to the row number

// Type row to a type syntax node (single-slot root rule above). -1 means no syntax form; the caller falls back to the name path.
fn inst_type_node_of_ti(ti: int) -> int:
    k := get_type_kind(ti)
    if k < 0:
        return -1
    if k == TYP_BASE:
        return alloc_node(0, 0, 0, 0, 0, get_type_data(ti), 0, 0, 0)
    if k == TYP_NAMED || k == TYP_GENERIC_PARAM:
        return alloc_node(EXPR_IDENT, 0, 0, 0, get_type_data(ti), 0, 0, 0, 0)
    if k == TYP_ARRAY:
        inner := inst_type_node_of_ti(get_type_data(ti))
        if inner < 0:
            return -1
        return alloc_node(EXPR_ARRAY, inner, 0, 0, get_type_extra(ti), 0, 0, 0, 0)
    if k == TYP_SLICE:
        inner := inst_type_node_of_ti(get_type_data(ti))
        if inner < 0:
            return -1
        return alloc_node(EXPR_ARRAY, inner, 0, 0, 0, 0, 0, 0, 0)
    if k == TYP_REF:
        inner := inst_type_node_of_ti(get_type_data(ti))
        if inner < 0:
            return -1
        return alloc_node(EXPR_REFTYPE, inner, 0, 0, get_type_extra(ti), 0, 0, 0, 0)
    if k == TYP_PTR:
        inner := inst_type_node_of_ti(get_type_data(ti))
        if inner < 0:
            return -1
        return alloc_node(EXPR_PTRTYPE, inner, 0, 0, 0, 0, 0, 0, 0)
    if k == TYP_OPTIONAL:
        inner := inst_type_node_of_ti(get_type_data(ti))
        if inner < 0:
            return -1
        return alloc_node(EXPR_OPTIONAL, inner, 0, 0, 0, 0, 0, 0, 0)
    if k == TYP_GENERIC_APPLY:
        base := get_type_data(ti)
        if get_type_kind(base) != TYP_NAMED:
            return -1
        start := get_type_extra(ti)
        cnt := cell_load(g_gen_apply_data, start * 8)
        if cnt <= 0:
            return -1
        first_an : ., mut = -1
        i : ., mut = 0
        loop:
            if i >= cnt:
                break
            at := cell_load(g_gen_apply_data, (start + 1 + i) * 8)
            ak := get_type_kind(at)
            // Argument roots must be consecutive: accept only native, named, and generic-parameter rows.
            if ak != TYP_BASE && ak != TYP_NAMED && ak != TYP_GENERIC_PARAM:
                return -1
            an := inst_type_node_of_ti(at)
            if an < 0:
                return -1
            if i == 0:
                first_an = an
            i = i + 1
        return alloc_node(EXPR_GENERIC_APPLY, get_type_data(base), first_an, cnt, 0, 0, 0, 0, 0)
    return -1   // tuple, null, dyn, and unknown kinds have no syntax form here

fn gen_lookup_subst_ti(name_ni: int) -> int:
    mi : ., mut = 0
    loop:
        if mi >= g_gen_subst_tis_count:
            break
        if cell_load(g_gen_subst_old, mi * 8) == name_ni:
            return cell_load(g_gen_subst_tis, mi * 8)
        mi = mi + 1
    return -1

// Raw TY_* code for FuncInfo.return_type. Composite rows have no raw code; the
// inferred-return path currently covers base types (identity/array-element
// returns). Composite returns fall back to unit and are handled by later slices.
fn ret_code_of_ti(ti: int) -> int:
    if ti == TI_INT:
        return TY_INT
    if ti == TI_STR:
        return TY_STRING
    if ti == TI_BOOL:
        return TY_BOOL
    if ti == TI_CHAR:
        return TY_CHAR
    if ti == TI_DEX || ti == TI_DEX_S:
        return TY_DEX
    if ti == TI_UNIT:
        return TY_UNIT
    if ti == TI_NEVER:
        return TY_NEVER
    k := get_type_kind(ti)
    if k == TYP_OPTIONAL:
        return ret_code_of_ti(get_type_data(ti))
    return TY_UNIT

// Type row after replacing generic-parameter rows for the current instance. Invalid rows stay unchanged; composite rows are rebuilt structurally.
fn gen_subst_ti(ti: int) -> int:
    k := get_type_kind(ti)
    if k < 0:
        return ti
    if k == TYP_GENERIC_PARAM:
        s := gen_lookup_subst_ti(get_type_data(ti))
        if s >= 0:
            return s
        return ti
    if k == TYP_ARRAY:
        return alloc_type(TYP_ARRAY, gen_subst_ti(get_type_data(ti)), get_type_extra(ti))
    if k == TYP_SLICE:
        return alloc_type(TYP_SLICE, gen_subst_ti(get_type_data(ti)), 0)
    if k == TYP_REF:
        return alloc_type(TYP_REF, gen_subst_ti(get_type_data(ti)), get_type_extra(ti))
    if k == TYP_PTR:
        return alloc_type(TYP_PTR, gen_subst_ti(get_type_data(ti)), get_type_extra(ti))
    if k == TYP_OPTIONAL:
        return alloc_type(TYP_OPTIONAL, gen_subst_ti(get_type_data(ti)), 0)
    if k == TYP_GENERIC_APPLY:
        start := get_type_extra(ti)
        cnt := cell_load(g_gen_apply_data, start * 8)
        // Two passes: substituting a child can append to g_gen_apply_data.
        subs : string, mut
        if cnt > 0:
            subs = alloc(cnt * 8)
            i : ., mut = 0
            loop:
                if i >= cnt:
                    break
                cell_store(subs, i * 8, gen_subst_ti(cell_load(g_gen_apply_data, (start + 1 + i) * 8)))
                i = i + 1
        ns := g_gen_apply_data_count
        grow_gen_apply_data(ns + 1 + cnt)
        cell_store(g_gen_apply_data, ns * 8, cnt)
        i2 : ., mut = 0
        loop:
            if i2 >= cnt:
                break
            cell_store(g_gen_apply_data, (ns + 1 + i2) * 8, cell_load(subs, i2 * 8))
            i2 = i2 + 1
        g_gen_apply_data_count = ns + 1 + cnt
        return alloc_type(TYP_GENERIC_APPLY, get_type_data(ti), ns)
    return ti

// Whether a substituted row is fully concrete, with no remaining generic-parameter
// rows. This is required before remapping nested call-site bindings. If a row
// remains, the binding has no solution in this instance and the whole block is
// discarded instead of creating a partial instance.
fn inst_ti_concrete(ti: int) -> int:
    k := get_type_kind(ti)
    if k < 0:
        return 1
    // An out-of-range row is not a parameter, so treat it as concrete; the judgment path rejects it later.
    if k == TYP_GENERIC_PARAM:
        return 0
    if k == TYP_ARRAY || k == TYP_SLICE || k == TYP_REF || k == TYP_PTR || k == TYP_OPTIONAL:
        return inst_ti_concrete(get_type_data(ti))
    if k == TYP_GENERIC_APPLY:
        start := get_type_extra(ti)
        cnt := cell_load(g_gen_apply_data, start * 8)
        i : ., mut = 0
        loop:
            if i >= cnt:
                return 1
            if inst_ti_concrete(cell_load(g_gen_apply_data, (start + 1 + i) * 8)) == 0:
                return 0
            i = i + 1
        return 1
    if k == TYP_TUPLE:
        start2 := get_type_extra(ti)
        cnt2 := get_type_data(ti)
        i2 : ., mut = 0
        loop:
            if i2 >= cnt2:
                return 1
            if inst_ti_concrete(cell_load(g_gen_apply_data, (start2 + i2) * 8)) == 0:
                return 0
            i2 = i2 + 1
        return 1
    return 1

// Remap a source call-site binding block (iv = block start + 1) for the current
// instance. Returns the new iv, or 0 when the block cannot be remapped and the
// clone should fall back to the name path.
// A cloned call node carries bindings from the source function context, such as
// T := gparam(U). Reusing them would build an instance key from the source context
// and select the wrong instance; clearing them would lose information.
fn gen_remap_binds(iv: int) -> int:
    if iv <= 0:
        return 0
    start := iv - 1
    if start >= g_gen_binds_count:
        return 0
    cnt := cell_load(g_gen_binds, start * 8)
    if cnt <= 0:
        return 0
    if start + 1 + cnt > g_gen_binds_count:
        return 0
    // Every entry must be fully concrete after substitution; otherwise discard the
    // whole block. Results go to a temporary buffer first because gen_subst_ti can
    // append type rows and payloads, and to avoid reading while writing.
    subs : string, mut = alloc(cnt * 8)
    i : ., mut = 0
    loop:
        if i >= cnt:
            break
        t := gen_subst_ti(cell_load(g_gen_binds, (start + 1 + i) * 8))
        if inst_ti_concrete(t) == 0:
            return 0
        cell_store(subs, i * 8, t)
        i = i + 1
    ns := g_gen_binds_count
    grow_gen_binds(ns + 1 + cnt)
    cell_store(g_gen_binds, ns * 8, cnt)
    i2 : ., mut = 0
    loop:
        if i2 >= cnt:
            break
        cell_store(g_gen_binds, (ns + 1 + i2) * 8, cell_load(subs, i2 * 8))
        i2 = i2 + 1
    g_gen_binds_count = ns + 1 + cnt
    return ns + 1

// ============================================================
// Dedup mapping for tree clone
// ============================================================

fn gen_dedup_find(old_node: int) -> int:
    mi : ., mut = 0
    loop:
        if mi >= g_gen_dedup_count:
            break
        if cell_load(g_gen_dedup_old, mi * 8) == old_node:
            return cell_load(g_gen_dedup_new, mi * 8)
        mi = mi + 1
    return -1

fn gen_dedup_add(old_node: int, new_node: int):
    grow_gen_dedup(g_gen_dedup_count + 1)
    cell_store(g_gen_dedup_old, g_gen_dedup_count * 8, old_node)
    cell_store(g_gen_dedup_new, g_gen_dedup_count * 8, new_node)
    g_gen_dedup_count = g_gen_dedup_count + 1

// ============================================================
// Deep AST clone with generic param substitution
// ============================================================

// Clone a sequence of g_block_stmts entries, substituting each one.
fn gen_clone_block(start: int, count: int) -> int:
    if count <= 0:
        return -1
    new_start := g_block_stmt_count
    grow_block_stmts(new_start + count)
    // Reserve the outer block range before cloning children. Nested blocks
    // append after this range instead of reusing and overwriting new_start.
    g_block_stmt_count = new_start + count
    i : ., mut = 0
    loop:
        if i >= count:
            break
        old_stmt := cell_load(g_block_stmts, (start + i) * 8)
        new_stmt := gen_clone_tree(old_stmt)
        cell_store(g_block_stmts, (new_start + i) * 8, new_stmt)
        i = i + 1
    return new_start

// Clone consecutive AST nodes (for struct fields, array elements, etc.)
fn gen_clone_consecutive(start: int, count: int) -> int:
    if count <= 0 || start < 0:
        return -1
    // Each cloned node is appended to g_ast by gen_clone_tree, so they end up consecutive.
    first_new := g_ast_count
    i : ., mut = 0
    loop:
        if i >= count:
            break
        gen_clone_tree(start + i)
        i = i + 1
    return first_new

// Deep-clone an AST subtree, substituting generic param references
// with concrete type name references.
fn gen_clone_tree(node: int) -> int:
    if node < 0:
        return -1

    // Dedup: if this node was already cloned, return the existing clone.
    dup := gen_dedup_find(node)
    if dup >= 0:
        return dup

    k := ast_kind(node)
    a := ast_a(node)
    b := ast_b(node)
    c := ast_c(node)
    iv := ast_int_val(node)
    tv := ast_type_val(node)
    d := ast_data(node)
    ln := ast_line(node)
    cl := ast_col(node)

    // ── EXPR_IDENT: might be a generic param reference ──
    if k == EXPR_IDENT:
        ni := iv
        // Try the type-row path first: it can build a complete type node for named,
        // applied, sequence, reference, pointer, and optional types. If synthesis
        // fails for a type with no syntax form, fall back to the name path.
        sti := gen_lookup_subst_ti(ni)
        if sti >= 0:
            sn := inst_type_node_of_ti(sti)
            if sn >= 0:
                gen_dedup_add(node, sn)
                return sn
        sub := gen_lookup_subst(ni)
        if sub >= 0:
            // Substitute generic param with concrete type
            base_tv := gen_base_type_tv(sub)
            if base_tv >= 0:
                // Base type reference: kind 0 with type_val.
                n := ast_alloc(0, 0, 0, 0, 0, base_tv, 0, ln, cl)
                gen_dedup_add(node, n)
                return n
            // Named type: EXPR_IDENT with the concrete name.
            n := ast_alloc(k, a, b, c, sub, tv, d, ln, cl)
            gen_dedup_add(node, n)
            return n
        // Not a generic parameter; clone unchanged.
        n := ast_alloc(k, a, b, c, ni, tv, d, ln, cl)
        gen_dedup_add(node, n)
        return n

    // ── EXPR_NONE (kind=0): base type node OR struct field wrapper ──
    if k == EXPR_NONE:
        if a >= 0 && a != node:
            // Struct literal field or pattern wrapper: a = value expression
            a2 := gen_clone_tree(a)
            n := ast_alloc(k, a2, b, c, iv, tv, d, ln, cl)
            gen_dedup_add(node, n)
            return n
        // Base type node or empty: no AST children
        n := ast_alloc(k, a, b, c, iv, tv, d, ln, cl)
        gen_dedup_add(node, n)
        return n

    // ── Leaf nodes (no AST children) ──
    if k == EXPR_INT:
        n := ast_alloc(k, a, b, c, iv, tv, d, ln, cl)
        gen_dedup_add(node, n)
        return n
    if k == EXPR_DEX:
        n := ast_alloc(k, a, b, c, iv, tv, d, ln, cl)
        gen_dedup_add(node, n)
        return n
    if k == EXPR_BOOL:
        n := ast_alloc(k, a, b, c, iv, tv, d, ln, cl)
        gen_dedup_add(node, n)
        return n
    if k == EXPR_STRING:
        n := ast_alloc(k, a, b, c, iv, tv, d, ln, cl)
        gen_dedup_add(node, n)
        return n
    if k == EXPR_CHAR:
        n := ast_alloc(k, a, b, c, iv, tv, d, ln, cl)
        gen_dedup_add(node, n)
        return n
    if k == EXPR_WILDCARD:
        n := ast_alloc(k, a, b, c, iv, tv, d, ln, cl)
        gen_dedup_add(node, n)
        return n
    if k == EXPR_BREAK:
        n := ast_alloc(k, a, b, c, iv, tv, d, ln, cl)
        gen_dedup_add(node, n)
        return n
    if k == EXPR_CONTINUE:
        n := ast_alloc(k, a, b, c, iv, tv, d, ln, cl)
        gen_dedup_add(node, n)
        return n

    // ── Single child in `a` ──
    if k == EXPR_RETURN:
        a2 := gen_clone_tree(a)
        n := ast_alloc(k, a2, b, c, iv, tv, d, ln, cl)
        gen_dedup_add(node, n)
        return n
    if k == EXPR_YIELD:
        a2 := gen_clone_tree(a)
        n := ast_alloc(k, a2, b, c, iv, tv, d, ln, cl)
        gen_dedup_add(node, n)
        return n
    if k == EXPR_AWAIT:
        a2 := gen_clone_tree(a)
        n := ast_alloc(k, a2, b, c, iv, tv, d, ln, cl)
        gen_dedup_add(node, n)
        return n
    if k == EXPR_UNSAFE:
        a2 := gen_clone_tree(a)
        n := ast_alloc(k, a2, b, c, iv, tv, d, ln, cl)
        gen_dedup_add(node, n)
        return n
    if k == EXPR_TRY:
        a2 := gen_clone_tree(a)
        n := ast_alloc(k, a2, b, c, iv, tv, d, ln, cl)
        gen_dedup_add(node, n)
        return n
    if k == EXPR_UNARY:
        a2 := gen_clone_tree(a)
        n := ast_alloc(k, a2, b, c, iv, tv, d, ln, cl)
        gen_dedup_add(node, n)
        return n
    if k == EXPR_FIELD:
        a2 := gen_clone_tree(a)
        n := ast_alloc(k, a2, b, c, iv, tv, d, ln, cl)
        gen_dedup_add(node, n)
        return n
    if k == EXPR_STMT:
        a2 := gen_clone_tree(a)
        n := ast_alloc(k, a2, b, c, iv, tv, d, ln, cl)
        gen_dedup_add(node, n)
        return n
    if k == EXPR_GO:
        a2 := gen_clone_tree(a)
        n := ast_alloc(k, a2, b, c, iv, tv, d, ln, cl)
        gen_dedup_add(node, n)
        return n
    // T? has the inner type node in a. Its generic parameters are substituted by the
    // EXPR_IDENT branch, so clone only a here. This explicit branch avoids the
    // fallback treating d (=0) as a child node.
    if k == EXPR_OPTIONAL:
        a2 := gen_clone_tree(a)
        n := ast_alloc(k, a2, b, c, iv, tv, d, ln, cl)
        gen_dedup_add(node, n)
        return n
    // An interpolation hole should not reach cloning, because the checker rewrites
    // it to a conversion call earlier. It still needs an explicit branch: the
    // fallback would treat d as a child or drop the subtree. Clone only a and keep
    // data (the hole text).
    if k == EXPR_INTERP_HOLE:
        a2 := gen_clone_tree(a)
        n := ast_alloc(k, a2, b, c, 0, tv, d, ln, cl)
        gen_dedup_add(node, n)
        return n

    // ── Two children: `a` and `b` ──
    if k == EXPR_BINARY:
        a2 := gen_clone_tree(a)
        b2 := gen_clone_tree(b)
        n := ast_alloc(k, a2, b2, c, iv, tv, d, ln, cl)
        gen_dedup_add(node, n)
        return n
    if k == EXPR_ASSIGN:
        a2 := gen_clone_tree(a)
        b2 := gen_clone_tree(b)
        n := ast_alloc(k, a2, b2, c, iv, tv, d, ln, cl)
        gen_dedup_add(node, n)
        return n
    if k == EXPR_INDEX:
        a2 := gen_clone_tree(a)
        b2 := gen_clone_tree(b)
        n := ast_alloc(k, a2, b2, c, iv, tv, d, ln, cl)
        gen_dedup_add(node, n)
        return n
    if k == EXPR_WHILE:
        a2 := gen_clone_tree(a)
        b2 := gen_clone_tree(b)
        n := ast_alloc(k, a2, b2, c, iv, tv, d, ln, cl)
        gen_dedup_add(node, n)
        return n
    if k == EXPR_LOOP:
        a2 := gen_clone_tree(a)
        n := ast_alloc(k, a2, b, c, iv, tv, d, ln, cl)
        gen_dedup_add(node, n)
        return n
    if k == EXPR_RANGE:
        a2 := gen_clone_tree(a)
        b2 := gen_clone_tree(b)
        n := ast_alloc(k, a2, b2, c, iv, tv, d, ln, cl)
        gen_dedup_add(node, n)
        return n
    if k == EXPR_AS:
        a2 := gen_clone_tree(a)
        b2 := gen_clone_tree(b)
        n := ast_alloc(k, a2, b2, c, iv, tv, d, ln, cl)
        gen_dedup_add(node, n)
        return n

    // ── EXPR_CALL: a=func_node(YES), b=first_ARG(YES), c=arg_count(NOT) ──
    if k == EXPR_CALL:
        a2 := gen_clone_tree(a)
        b2 := gen_clone_tree(b)
        // Remap call-site bindings for this instance. The cloned node carries the
        // source function context's bindings; gen_remap_binds substitutes them for
        // the current instance. A block that is not fully concrete becomes 0 and
        // falls back to the name path. The iv must be rewritten explicitly because
        // ast_alloc copies it.
        n := ast_alloc(k, a2, b2, c, iv, tv, d, ln, cl)
        ast_set_int_val(n, gen_remap_binds(iv))
        // Resolve an interface method call whose receiver is a generic parameter.
        // The source node has data = the generic parameter name and
        // type_val = CALL_FLAG_IFACE_METHOD. Use the current instance's concrete
        // type to look up the real function name in g_methods.
        // If resolution fails because the parameter is unbound, the type has no such
        // method, or the parameter is nested, leave the node unchanged.
        if tv == CALL_FLAG_IFACE_METHOD:
            cni := gen_lookup_subst(d)
            if cni >= 0 && a2 >= 0:
                m_ni := ast_int_val(a2)
                f_ni := iface_find_method(cni, m_ni)
                if f_ni >= 0:
                    ast_set_data(n, f_ni)
                    ast_set_type_val(n, 0)
        gen_dedup_add(node, n)
        return n

    // ── EXPR_ARG: a=expr(YES), b=next_arg(YES or -1) ──
    if k == EXPR_ARG:
        a2 := gen_clone_tree(a)
        b2 := gen_clone_tree(b)
        n := ast_alloc(k, a2, b2, c, iv, tv, d, ln, cl)
        gen_dedup_add(node, n)
        return n

    // ── EXPR_IF: a=cond(YES), b=then(YES), c=else(YES or -1) ──
    if k == EXPR_IF:
        a2 := gen_clone_tree(a)
        b2 := gen_clone_tree(b)
        c2 := gen_clone_tree(c)
        n := ast_alloc(k, a2, b2, c2, iv, tv, d, ln, cl)
        gen_dedup_add(node, n)
        return n

    // ── EXPR_FN: a=name_ni(NOT), b=first_param(YES), c=param_count(NOT), d=body(YES) ──
    if k == EXPR_FN:
        d2 := gen_clone_tree(d)
        n := ast_alloc(k, a, b, c, iv, tv, d2, ln, cl)
        gen_dedup_add(node, n)
        return n

    // ── EXPR_PARAM: a=name_ni(NOT), d=type_node(YES) ──
    if k == EXPR_PARAM:
        d2 := gen_clone_tree(d)
        n := ast_alloc(k, a, b, c, iv, tv, d2, ln, cl)
        gen_dedup_add(node, n)
        return n

    // ── EXPR_BLOCK: children in g_block_stmts ──
    if k == EXPR_BLOCK:
        new_start := gen_clone_block(a, b)
        n := ast_alloc(k, new_start, b, c, iv, tv, d, ln, cl)
        gen_dedup_add(node, n)
        return n

    // ── EXPR_FOR: a=var_name_ni(NOT), b=iter(YES), c=body(YES) ──
    if k == EXPR_FOR:
        b2 := gen_clone_tree(b)
        c2 := gen_clone_tree(c)
        n := ast_alloc(k, a, b2, c2, iv, tv, d, ln, cl)
        gen_dedup_add(node, n)
        return n

    // ── EXPR_LET: a=name_ni(NOT), b=type(YES or -1), c=value(YES or -1), d=is_mut(NOT) ──
    if k == EXPR_LET:
        b2 := gen_clone_tree(b)
        c2 := gen_clone_tree(c)
        n := ast_alloc(k, a, b2, c2, iv, tv, d, ln, cl)
        gen_dedup_add(node, n)
        return n

    // EXPR_STRUCT: a = type name, b = first wrapper (consecutive), c = field count.
    // wrapper.a = field value node, wrapper.b = field name index or -1.
    if k == EXPR_STRUCT:
        if b >= 0 && c > 0:
            // Clone field values first, then build consecutive wrappers. Interleaving
            // value cloning with wrapper creation would make wrappers non-consecutive.
            // Keep field names: instance bodies bind fields by name, and losing the
            // name would fall back to positional binding when source order differs
            // from declaration order.
            nvs : string, mut = alloc(c * 8)
            nms : string, mut = alloc(c * 8)
            i : ., mut = 0
            loop:
                if i >= c:
                    break
                vn : ., mut = -1
                if b + i >= 0:
                    vn = ast_a(b + i)
                cell_store(nvs, i * 8, gen_clone_tree(vn))
                cell_store(nms, i * 8, ast_b(b + i))
                i = i + 1
            new_first := g_ast_count
            i = 0
            loop:
                if i >= c:
                    break
                ast_alloc(EXPR_NONE, cell_load(nvs, i * 8), cell_load(nms, i * 8), 0, 0, 0, 0, ln, cl)
                i = i + 1
            n := ast_alloc(k, a, new_first, c, iv, tv, d, ln, cl)
            gen_dedup_add(node, n)
            return n
        n := ast_alloc(k, a, b, c, iv, tv, d, ln, cl)
        gen_dedup_add(node, n)
        return n

    // EXPR_ARRAY: a = first wrapper (consecutive), b = element count.
    // wrapper.a = element value node.
    if k == EXPR_ARRAY:
        if a >= 0 && b > 0:
            // Clone element values first, then build consecutive wrappers.
            nvs : string, mut = alloc(b * 8)
            i : ., mut = 0
            loop:
                if i >= b:
                    break
                vn : ., mut = -1
                if a + i >= 0:
                    vn = ast_a(a + i)
                cell_store(nvs, i * 8, gen_clone_tree(vn))
                i = i + 1
            new_first := g_ast_count
            i = 0
            loop:
                if i >= b:
                    break
                ast_alloc(EXPR_NONE, cell_load(nvs, i * 8), 0, 0, 0, 0, 0, ln, cl)
                i = i + 1
            n := ast_alloc(k, new_first, b, c, iv, tv, d, ln, cl)
            gen_dedup_add(node, n)
            return n
        n := ast_alloc(k, a, b, c, iv, tv, d, ln, cl)
        gen_dedup_add(node, n)
        return n

    // EXPR_TUPLE: a = first wrapper (consecutive), b = element count.
    // wrapper.a = element value node.
    if k == EXPR_TUPLE:
        if a >= 0 && b > 0:
            // Clone element values first, then build consecutive wrappers.
            nvs : string, mut = alloc(b * 8)
            i : ., mut = 0
            loop:
                if i >= b:
                    break
                vn : ., mut = -1
                if a + i >= 0:
                    vn = ast_a(a + i)
                cell_store(nvs, i * 8, gen_clone_tree(vn))
                i = i + 1
            new_first := g_ast_count
            i = 0
            loop:
                if i >= b:
                    break
                ast_alloc(EXPR_NONE, cell_load(nvs, i * 8), 0, 0, 0, 0, 0, ln, cl)
                i = i + 1
            n := ast_alloc(k, new_first, b, c, iv, tv, d, ln, cl)
            gen_dedup_add(node, n)
            return n
        n := ast_alloc(k, a, b, c, iv, tv, d, ln, cl)
        gen_dedup_add(node, n)
        return n

    // ── EXPR_GENERIC_APPLY: a=base_name_ni(NOT), b=first_arg(YES, consecutive), c=arg_count(NOT) ──
    if k == EXPR_GENERIC_APPLY:
        if b >= 0 && c > 0:
            new_first := gen_clone_consecutive(b, c)
            n := ast_alloc(k, a, new_first, c, iv, tv, d, ln, cl)
            gen_dedup_add(node, n)
            return n
        n := ast_alloc(k, a, b, c, iv, tv, d, ln, cl)
        gen_dedup_add(node, n)
        return n

    // ── EXPR_MATCH: a=expr(YES), b=first_arm(YES), c=arm_count(NOT) ──
    if k == EXPR_MATCH:
        a2 := gen_clone_tree(a)
        b2 := gen_clone_tree(b)
        n := ast_alloc(k, a2, b2, c, iv, tv, d, ln, cl)
        gen_dedup_add(node, n)
        return n

    // ── EXPR_ARM: a=pattern(YES), b=body(YES) ──
    if k == EXPR_ARM:
        a2 := gen_clone_tree(a)
        b2 := gen_clone_tree(b)
        n := ast_alloc(k, a2, b2, c, iv, tv, d, ln, cl)
        gen_dedup_add(node, n)
        return n

    // ── EXPR_ENUM_CONSTRUCTOR: a=name_ni(NOT), b=first_arg(YES), c=arg_count(NOT) ──
    if k == EXPR_ENUM_CONSTRUCTOR:
        b2 := gen_clone_tree(b)
        n := ast_alloc(k, a, b2, c, iv, tv, d, ln, cl)
        gen_dedup_add(node, n)
        return n

    // ── EXPR_ENUMPAT: a=name_ni(NOT), b=first_subpat(YES, consecutive), c=subpat_count(NOT) ──
    if k == EXPR_ENUMPAT:
        b2 := gen_clone_consecutive(b, c)
        n := ast_alloc(k, a, b2, c, iv, tv, d, ln, cl)
        gen_dedup_add(node, n)
        return n

    // EXPR_STRUCTPAT: a = name, b = first wrapper (consecutive), c = field count.
    // wrapper.a = subpattern node, wrapper.b = field name index (same contract as
    // struct literal wrappers). Preserve the name so a clone still binds by name.
    if k == EXPR_STRUCTPAT:
        pbad : ., mut = 0
        if b >= 0 && c > 0:
            nvs : string, mut = alloc(c * 8)
            nns : string, mut = alloc(c * 8)
            nds : string, mut = alloc(c * 8)
            i : ., mut = 0
            loop:
                if i >= c:
                    break
                vn : ., mut = -1
                nn : ., mut = -1
                nd : ., mut = 0
                if b + i >= 0:
                    vn = ast_a(b + i)
                    nn = ast_b(b + i)
                    nd = ast_data(b + i)   // checker-resolved field type + 1
                if nd > 0:
                    ft := nd - 1
                    sk : ., mut = -1
                    if vn >= 0:
                        sk = ast_kind(vn)
                    // `_` neither compares nor binds, so a still-generic field is
                    // safe there. ident/literal subpatterns would load/bind it.
                    if ti_has_generic_param(ft) != 0 && sk != EXPR_WILDCARD:
                        pbad = 1
                        if g_gen_structpat_bad == 0:
                            g_gen_structpat_bad = 1
                            g_gen_structpat_bad_line = ln
                            g_gen_structpat_bad_col = cl
                cell_store(nvs, i * 8, gen_clone_tree(vn))
                cell_store(nns, i * 8, nn)
                cell_store(nds, i * 8, nd)
                i = i + 1
            new_first := g_ast_count
            i = 0
            loop:
                if i >= c:
                    break
                ast_alloc(EXPR_NONE, cell_load(nvs, i * 8), cell_load(nns, i * 8), 0, 0, 0, cell_load(nds, i * 8), ln, cl)
                i = i + 1
            if pbad != 0:
                // Fail closed: b = -1 makes ir_gen reject the pattern without
                // emitting any field load.
                n := ast_alloc(k, a, -1, c, iv, tv, d, ln, cl)
                gen_dedup_add(node, n)
                return n
            n := ast_alloc(k, a, new_first, c, iv, tv, d, ln, cl)
            gen_dedup_add(node, n)
            return n
        n := ast_alloc(k, a, b, c, iv, tv, d, ln, cl)
        gen_dedup_add(node, n)
        return n

    // EXPR_TUPLEPAT: a = first wrapper (consecutive), b = element count.
    // wrapper.a = subpattern node, wrapper.b = element index, wrapper.d =
    // checker-resolved element type + 1. Preserve both halves of the wrapper so a
    // clone still compares/binds the same positions with the same type.
    if k == EXPR_TUPLEPAT:
        if a >= 0 && b > 0:
            nvs : string, mut = alloc(b * 8)
            nns : string, mut = alloc(b * 8)
            nds : string, mut = alloc(b * 8)
            i : ., mut = 0
            loop:
                if i >= b:
                    break
                vn : ., mut = -1
                nn : ., mut = -1
                nd : ., mut = 0
                if a + i >= 0:
                    vn = ast_a(a + i)
                    nn = ast_b(a + i)
                    nd = ast_data(a + i)
                cell_store(nvs, i * 8, gen_clone_tree(vn))
                cell_store(nns, i * 8, nn)
                cell_store(nds, i * 8, nd)
                i = i + 1
            new_first := g_ast_count
            i = 0
            loop:
                if i >= b:
                    break
                ast_alloc(EXPR_NONE, cell_load(nvs, i * 8), cell_load(nns, i * 8), 0, 0, 0, cell_load(nds, i * 8), ln, cl)
                i = i + 1
            n := ast_alloc(k, new_first, b, c, iv, tv, d, ln, cl)
            gen_dedup_add(node, n)
            return n
        n := ast_alloc(k, a, b, c, iv, tv, d, ln, cl)
        gen_dedup_add(node, n)
        return n

    // ── EXPR_AT: a=name_ni(NOT), b=args_node(YES or -1) ──
    if k == EXPR_AT:
        b2 := gen_clone_tree(b)
        n := ast_alloc(k, a, b2, c, iv, tv, d, ln, cl)
        gen_dedup_add(node, n)
        return n

    // ── EXPR_FLOW: a=name_ni(NOT), b=param_count(NOT), c=first_param(YES), d=body(YES) ──
    if k == EXPR_FLOW:
        c2 := gen_clone_tree(c)
        d2 := gen_clone_tree(d)
        n := ast_alloc(k, a, b, c2, iv, tv, d2, ln, cl)
        gen_dedup_add(node, n)
        return n

    // Fallback for node kinds without an explicit branch. Clone all pointer-sized
    // fields as children.
    a2 := gen_clone_tree(a)
    b2 := gen_clone_tree(b)
    c2 := gen_clone_tree(c)
    d2 := gen_clone_tree(d)
    n := ast_alloc(k, a2, b2, c2, iv, tv, d2, ln, cl)
    gen_dedup_add(node, n)
    return n

// ============================================================
// Cache API: find or create specialized instance
// ============================================================

// Find a specialized instance in the cache.
// func_ni: the original generic FuncInfo index
// type_args: comma-separated concrete type names (e.g. "int,string")
// Returns the specialized function index, or -1 if not found.
fn gen_find_cached(func_ni: int, type_args: string) -> int:
    i : ., mut = 0
    loop:
        if i >= g_gen_instance_count:
            break
        if cell_load(g_gen_instances, i * 24) == func_ni:
            cached_args_ni := cell_load(g_gen_instances, i * 24 + 8)
            if istr_eq(cached_args_ni, type_args) != 0:
                return cell_load(g_gen_instances, i * 24 + 16)
        i = i + 1
    return -1

// Find or create a specialized instance of a generic function.
// func_ni: the original generic FuncInfo index
// type_args: comma-separated concrete type names (e.g. "int,string")
// Returns the specialized function index.
fn gen_find_or_create(func_ni: int, type_args: string) -> int:
    cached := gen_find_cached(func_ni, type_args)
    if cached >= 0:
        return cached
    return gen_create_instance(func_ni, type_args, -1)

// Find or create an instance with a call-site binding block. ir_gen supplies the
// canonical key and the block start. The key is the joined structural type string,
// so different instances get different keys.
fn gen_find_or_create_bind(func_ni: int, type_args: string, bstart: int) -> int:
    cached := gen_find_cached(func_ni, type_args)
    if cached >= 0:
        return cached
    return gen_create_instance(func_ni, type_args, bstart)

// Create a specialized copy of a generic function:
//   1. build generic-parameter to concrete-type substitutions;
//   2. deep-clone the AST with substitution;
//   3. register the new function in g_funcs;
//   4. cache the new function index;
//   5. return the new index.
fn gen_create_instance(func_ni: int, type_args: string, bstart: int) -> int:
    // Build substitution mappings. The name table is the fallback; under canonical
    // keys its names are not declaration names for composite types, so it is used
    // only when the type-row path fails. The type-row table is the preferred path
    // and is filled when bstart is valid.
    gen_build_subst(func_ni, type_args)
    gen_build_subst_tis(func_ni, bstart)
    // Inferred return: substitute the stored body-derived row for this instance.
    inst_ret_code : ., mut = -1
    if func_ni >= 0 && func_ni < g_func_ret_count:
        rrow := cell_load(g_func_ret_ti, func_ni * 8)
        if rrow != -2:
            inst_ret_code = ret_code_of_ti(gen_subst_ti(rrow))

    // 2. Clone the original function AST
    orig_fn_node := fi_ast_node(func_ni)
    g_gen_dedup_count = 0
    g_gen_dedup_cap = 0
    g_gen_structpat_bad = 0
    g_gen_structpat_bad_line = 0
    g_gen_structpat_bad_col = 0
    new_fn_node := gen_clone_tree(orig_fn_node)
    if g_gen_structpat_bad != 0:
        check_error(EC_TS_FIELD_TYPE,
            "Struct pattern field has an unresolved generic type",
            g_gen_structpat_bad_line, g_gen_structpat_bad_col)

    // Concretize the instance parameter chain. The EXPR_FN clone branch copies b/c
    // (first parameter and count), so the instance would share the declaration's
    // parameter nodes. The prologue would read type_val = 0 and assign TI_INT to
    // every slot, and call-site alignment would fail for generic parameters.
    // Clone each parameter node and its type subtree, substituting generic
    // parameters for the current instance. Recompute type_val from the cloned type
    // node: a base-type node contributes its type_val; a non-base type contributes
    // 0. Without this, the copied declaration value 0 would remain.
    // Keep the layout contract: each parameter's type subtree is allocated before
    // its parameter node, so the pn+1 cursor scan still works.
    pc_src := ast_c(orig_fn_node)
    if pc_src > 0:
        opn : ., mut = ast_b(orig_fn_node)
        first_np : ., mut = -1
        pi_src : ., mut = 0
        loop:
            if pi_src >= pc_src:
                break
            if opn < 0:
                break
            if ast_kind(opn) == EXPR_PARAM:
                nd := ast_data(opn)
                nd2 : ., mut = -1
                if nd >= 0:
                    nd2 = gen_clone_tree(nd)
                ntv : ., mut = 0
                if nd2 >= 0 && ast_kind(nd2) == 0:
                    ntv = ast_type_val(nd2)
                np := ast_alloc(EXPR_PARAM, ast_a(opn), ast_b(opn), ast_c(opn), ast_int_val(opn), ntv, nd2, ast_line(opn), ast_col(opn))
                gen_dedup_add(opn, np)
                if first_np < 0:
                    first_np = np
                pi_src = pi_src + 1
            opn = opn + 1
        if first_np >= 0:
            ast_set_b(new_fn_node, first_np)

    // Compute mangled name: "orig_name[type_args]" for unique identification
    orig_name := istr_get(fi_name(func_ni))
    mangled_name : ., mut = orig_name + "[" + type_args + "]"
    mangled_ni := str_intern(mangled_name)
    // Update the cloned AST node's name to the mangled name
    ast_set_a(new_fn_node, mangled_ni)

    // 3. Register new function in g_funcs
    new_fi := g_func_count
    grow_funcs(new_fi + 1)

    // Use mangled name for unique lookup
    fi_set_name(new_fi, mangled_ni)

    // Clone params: param type info from FuncInfo
    pc := fi_param_count(func_ni)
    fi_set_param_count(new_fi, pc)
    pi : ., mut = 0
    loop:
        if pi >= pc:
            break
        fi_set_param_type(new_fi, pi, fi_param_type(func_ni, pi))
        pi = pi + 1

    // Return type: inferred instances use the substituted body-derived code.
    if inst_ret_code >= 0:
        fi_set_return_type(new_fi, inst_ret_code)
    else:
        fi_set_return_type(new_fi, fi_return_type(func_ni))

    // AST node reference
    fi_set_ast_node(new_fi, new_fn_node)

    // Specialized instance has zero generic params (they've been substituted)
    fi_set_generic_count(new_fi, 0)

    g_func_count = new_fi + 1

    // Revalidate the specialized body against its concrete parameter types.
    // Template checking is deliberately lenient for generic templates; this is
    // the strict pass. Diagnostics raised here are caught by the IR-generation
    // gate in main.cr and fail the build closed.
    check_func(new_fi)

    // 4. Cache the new function
    type_args_ni := str_intern(type_args)
    grow_gen_instances(g_gen_instance_count + 1)
    cell_store(g_gen_instances, g_gen_instance_count * 24, func_ni)
    cell_store(g_gen_instances, g_gen_instance_count * 24 + 8, type_args_ni)
    cell_store(g_gen_instances, g_gen_instance_count * 24 + 16, new_fi)
    g_gen_instance_count = g_gen_instance_count + 1

    // Record the instance-to-source mapping for purity. Do not copy
    // fi_ispure(func_ni) here: at IR generation time the source function has no
    // true purity yet, and the default is optimistic. The instance's own purity is
    // computed in df_state_finalize; the source purity is the conjunction of its
    // instances, filled by compute_all_purity.
    grow_purity_inst(g_purity_inst_count + 1)
    cell_store(g_purity_inst, g_purity_inst_count * 24, func_ni)
    cell_store(g_purity_inst, g_purity_inst_count * 24 + 8, type_args_ni)
    cell_store(g_purity_inst, g_purity_inst_count * 24 + 16, new_fi)
    g_purity_inst_count = g_purity_inst_count + 1

    // 5. Return new function index
    return new_fi
