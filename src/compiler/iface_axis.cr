// === iface_axis.cr ===
// Interface satisfaction and iface_kind_of.
//
// This file is linked into corec and corelsp only; corearch does not include it.
// It uses checker declarations (find_iface, find_func, decl_name_of_ti,
// gen_constr_type_ti), the type bridge and shape constructors in ty_shadow.cr,
// the interface tables in iface_registry.cr, and type_engine primitives.
//
// iface_satisfies(t, iface) returns one of three results: 1 holds, 0 does not
// hold, -1 cannot decide. It tries these routes in order:
//   A. cross-cutting shape name: ty_sub(term, shape).
//   B. intrinsic type name: iface_satisfies_ti.
//   C. user interface: iface_user_satisfies.
// A shape name wins over a user interface, and a user interface wins over an
// intrinsic type name. A name that matches two routes never falls through after
// the first match.
//
// Every engine call resets the budget before and after the query. A memo hit from
// an earlier query must not change the result.

// Unified satisfaction entry for intrinsic types, cross-cutting shapes, and user
// interfaces.
// The result is 1 (holds), 0 (does not hold), or -1 (cannot decide). Callers must
// not treat -1 as 0 or 1.
// Dispatch order is shape, interface, intrinsic type. Each route returns on its
// first match; a name that matches a shape or an interface does not fall through.
//
// Budget isolation follows type_equal_engine: reset the budget before entering
// the engine and reset it again before returning. The value matches
// gen_constr_satisfied because both perform one bridge lookup and one inclusion
// query.
IFACE_SAT_BUDGET : int = 200000

fn iface_satisfies(t_ti: int, iface_ni: int) -> int:
    if t_ti < 0:
        return -1
    if iface_ni < 0:
        return -1
    // Route A: cross-cutting shape name. No match falls through.
    st := iface_shape_lookup(iface_ni)
    if st >= 0:
        return iface_satisfies_term(t_ti, st)
    // Route C: user interface. A match here does not fall through to route B.
    if find_iface(iface_ni) >= 0:
        // The interface shape is a product of function terms. Satisfaction is
        // checked member by member: iface_user_satisfies looks up each method in
        // the impl method table and compares its function term.
        // Do not pass the whole shape to iface_satisfies_term:
        //   1. named actual types are not structurally expanded, so ty_sub against
        //      the product shape returns -1;
        //   2. product comparison checks invariant slots for structural equality,
        //      not subset inclusion, so an impl with extra methods would be
        //      rejected.
        // The member-wise path avoids both problems.
        return iface_user_satisfies(t_ti, iface_ni)
    // Route B: intrinsic type name. A non-type name returns -1; no diagnostic is invented.
    cti := gen_constr_type_ti(iface_ni)
    if cti < 0:
        return -1
    return iface_satisfies_ti(t_ti, cti)

// Compare an actual type row with a shape term. A bridge failure returns -1;
// otherwise the ty_sub result is returned unchanged.
fn iface_satisfies_term(t_ti: int, shape: int) -> int:
    if t_ti < 0:
        return -1
    if shape < 0:
        return -1
    a := sh_term_of_ti(t_ti)
    if a < 0:
        return -1
    ty_budget_reset(IFACE_SAT_BUDGET)
    s := ty_sub(a, shape)
    ty_budget_reset(IFACE_SAT_BUDGET)
    return s

// Compare an actual type row with a constraint row (intrinsic route). This is the
// engine side of gen_constr_satisfied.
fn iface_satisfies_ti(t_ti: int, cti: int) -> int:
    if t_ti < 0:
        return -1
    if cti < 0:
        return -1
    a := sh_term_of_ti(t_ti)
    b := sh_term_of_ti(cti)
    if a < 0 || b < 0:
        return -1
    ty_budget_reset(IFACE_SAT_BUDGET)
    s := ty_sub(a, b)
    ty_budget_reset(IFACE_SAT_BUDGET)
    return s

// Look up (type name, method name) in the impl method table and return the
// mangled function name, or -1 when absent.
// The table is g_methods: 24B records {type_ni, method_ni, mangled_ni}, written
// by the parser impl branch. This checks the same condition as type_has_method:
// the impl block declared Type.method.
// This function never calls str_intern. A missing method must not append a new
// string to g_strs. type_has_method is safe only for existing names; it would
// grow the intern table for a missing one, so this path avoids it.
fn iface_find_method(type_ni: int, method_ni: int) -> int:
    if type_ni < 0:
        return -1
    if method_ni < 0:
        return -1
    i : ., mut = 0
    loop:
        if i >= g_method_count:
            return -1
        if r64(g_methods, i * 24) == type_ni:
            if r64(g_methods, i * 24 + 8) == method_ni:
                return r64(g_methods, i * 24 + 16)
        i = i + 1
    return -1

// User-interface satisfaction. The interface shape is a product of function
// terms. For each interface method m:
//   1. the type's method table contains m;
//   2. the receiver mode matches;
//   3. the function term matches the impl function term.
// Results:
//   1: all methods are present and signatures match, including an interface with
//      no methods.
//   0: a method is missing, the receiver mode differs, the parameter count
//      differs, or the signature differs.
//   -1: the type is not a named row, the function row is missing, or a term
//      cannot be built. A failed lookup alone never produces 0.
// Signatures containing generic parameter rows match only within the same
// declaration. dyn bitmap rows are not part of the normalized form, so a
// signature containing dyn returns -1.
fn iface_user_satisfies(t_ti: int, iface_ni: int) -> int:
    ii := find_iface(iface_ni)
    if ii < 0:
        return -1
    // Only named rows have a method-table identity. Other kinds return -1.
    // Use decl_name_of_ti instead of get_type_name: get_type_name calls str_intern
    // for base rows, and this layer must not grow the intern table.
    tname_ni := decl_name_of_ti(t_ti)
    if tname_ni < 0:
        return -1
    return iface_user_satisfies_ii(tname_ni, ii)

// Name-level core shared by iface_user_satisfies and checker check_iface. Both call
// this function, so their behavior is identical by construction.
fn iface_user_satisfies_ii(tname_ni: int, ii: int) -> int:
    if tname_ni < 0 || ii < 0:
        return -1
    mc := r64(g_ifaces, ii * ESZ_IFACEINFO + OFF_IF_METHOD_COUNT)
    if mc < 0 || mc > MAX_IFACE_METHODS:
        return -1
    shp := sh_iface_shape_term(r64(g_ifaces, ii * ESZ_IFACEINFO + OFF_IF_NAME))
    if shp < 0:
        return -1
    mi : ., mut = 0
    loop:
        if mi >= mc:
            return 1
        mbase := ii * ESZ_IFACEINFO + OFF_IF_METHODS + mi * ESZ_IFMETHOD
        m_ni := r64(g_ifaces, mbase + OFF_IFM_NAME)
        f_ni := iface_find_method(tname_ni, m_ni)
        if f_ni < 0:
            return 0
        // A missing method is a definite violation.
        fi := find_func(f_ni)
        if fi < 0:
            return -1
        // Table inconsistency: return -1, do not invent a violation.
        if sh_iface_self_mode(ii, mi) != sh_func_self_mode(fi):
            return 0
        // Receiver mode.

        ifm := sh_shape_member_at(shp, mi)
        if ifm < 0:
            return -1
        // Shape and method table are out of sync: return -1.
        implf := sh_func_sig_term(fi)
        if implf < 0:
            return -1
        // The impl signature term cannot be built: return -1.
        // Signature equality uses tt_list_same, not ty_sub. ty_sub returns -1
        // for definitely different invariant slots, which would turn a signature
        // mismatch into cannot-decide. The terms are normalized, so equal types
        // share a node and different types have different nodes. Compare the
        // function term parameter lists. The b slot of the fn atom is the method
        // name and is metadata, not part of the signature.
        if tt_list_same(tt_c(implf), tt_c(ifm)) != 1:
            return 0
        mi = mi + 1
    return 1

// Checker type row to AK_* atom class. Returns -1 for an invalid row.
// The mapping follows iface_registry's atom classes.
// This function is not sh_native_ak. sh_native_ak accepts only TYP_BASE rows;
// this function maps TYP_DYN to AK_DYN and structural rows to their classes. Both
// use the same TY_* table through iface_by_ty_code, but they keep different
// gates.
fn iface_kind_of(ti: int) -> int:
    k := get_type_kind(ti)
    if k < 0:
        return -1
    // 负值/越界行（get_type_kind 已做范围闸）
    if k == TYP_BASE:
        return iface_by_ty_code(get_type_data(ti))
    if k == TYP_DYN:
        return AK_DYN
    if k == TYP_NAMED:
        return AK_NAMED
    if k == TYP_GENERIC_PARAM:
        return AK_NAMED
    if k == TYP_GENERIC_APPLY:
        return AK_NAMED
    if k == TYP_ARRAY:
        return AK_SEQUENCE
    if k == TYP_SLICE:
        return AK_SEQUENCE
    if k == TYP_REF:
        return AK_REF
    if k == TYP_PTR:
        return AK_PTR
    if k == TYP_TUPLE:
        return AK_PRODUCT
    return -1                                     // 未知 kind（当前类型表无此情形）
