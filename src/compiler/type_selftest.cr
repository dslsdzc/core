// === type_selftest.cr ===
// Type-term engine case table and self-test driver (corec selftest-types).
// Each case prints PASS or FAIL. The last line is
// "N/M type-engine cases passed"; rc=0 means all passed.
// This file depends only on the public APIs of type_terms.cr and type_engine.cr.
// The suite covers subtyping, equivalence, disjointness, inhabitation,
// counterexamples, exhaustiveness, recursion, parameterization, and budget.
// tests/selfhost/test_type_engine.py requires MIN_CASES = 32.
//
// 类型判定有三种结果：
//   1：成立
//   0：不成立
//   -1：无法判定，原因是预算耗尽或规则未实现。不得把 -1 当作 0 或 1。

fn ts_check(name: string, got: int, want: int) -> int:
    if got == want:
        print("PASS ")
        println(name)
        return 0
    print("FAIL ")
    print(name)
    print(": got ")
    print(int_str(got))
    print(" want ")
    println(int_str(want))
    return 1

// Boolean variant of ts_check. The semantics are identical, but got and want are
// bool, so call sites do not need an implicit bool-to-int conversion. The FAIL
// branch prints bool_str instead of int_str.
fn ts_check_b(name: string, got: bool, want: bool) -> int:
    if got == want:
        print("PASS ")
        println(name)
        return 0
    print("FAIL ")
    print(name)
    print(": got ")
    print(bool_str(got))
    print(" want ")
    println(bool_str(want))
    return 1

// Diagnostic probe for end-to-end cases. check_error only appends to g_diags and
// does not print, so the incremental count and the first new diagnostic code show
// that the gate actually fired. Table-only cases cannot prove that.
fn ts_diag_code_at(idx: int) -> int:
    if idx < 0:
        return -1
    if idx >= g_diag_count:
        return -1
    return cell_load(g_diags, idx * DIAG_REC_SIZE)

// Read the message pointer of diagnostic idx. check_error stores that pointer.
fn ts_diag_msg_at(idx: int) -> string:
    if idx < 0:
        return ""
    if idx >= g_diag_count:
        return ""
    return cell_load_str(g_diags, idx * DIAG_REC_SIZE + 8)

// Frozen expected AK mapping, compared cell by cell with iface_by_ty_code.
// This table is expected data, not a second production implementation.
// TY_DEX_S maps to AK_DEX (same value domain, different representation).
// TY_GENERIC_PARAM maps to AK_NAMED (generic parameter sentinel, not expanded).
// Unmapped codes return -1.
fn ts_t4_ak_expected(ty: int) -> int:
    if ty == TY_INT:
        return AK_INT
    if ty == TY_DEX:
        return AK_DEX
    if ty == TY_DEX_S:
        return AK_DEX
    if ty == TY_BOOL:
        return AK_BOOL
    if ty == TY_STRING:
        return AK_STRING
    if ty == TY_UNIT:
        return AK_UNIT
    if ty == TY_NEVER:
        return AK_NEVER
    if ty == TY_CHAR:
        return AK_CHAR
    if ty == TY_GENERIC_PARAM:
        return AK_NAMED
    return -1

// 记录编号期望：先检查 kind 是否为 TYP_BASE，非基类型返回 -1，包括 TYP_DYN、结构和命名记录以及负编号；基类型再查表。
fn ts_t4_native_ak_expected(ti: int) -> int:
    if ti < 0:
        return -1
    if get_type_kind(ti) != TYP_BASE:
        return -1
    return ts_t4_ak_expected(get_type_data(ti))

// Build an N-level left-deep union for the budget guard. sub_cover recurses on
// each branch and spends one step per branch, so N above the budget exhausts it.
// A deep mu chain does not work because literal implication at argument positions
// does not expand and short-circuits there.
fn tt_probe_wide_union(depth: int) -> int:
    acc : ., mut = tt_atom(AK_INT, TI_INT, -1)
    d : ., mut = 0
    loop:
        if d >= depth:
            break
        acc = tt_union(acc, tt_atom(AK_STRING, TI_STR, -1))
        d = d + 1
    return acc

// Build a struct fixture with one int field (a: int) and return its named row.
// This path does not run parser or check_all. The struct declaration is written
// manually using the same slot order as parser.cr: field name, raw code slot,
// type node, and field count. The type node matches parse_type's output shape.
fn ts_unf_mk_int_struct(name: string) -> int:
    sa := add_struct(name)
    si_set_field_name(sa, 0, str_intern("a"))
    si_set_field_type(sa, 0, TY_INT)
    si_set_field_type_node(sa, 0, alloc_node(0, 0, 0, 0, 0, TY_INT, 0, 0, 0))
    cell_store(g_structs, sa * ESZ_STRUCTINFO + OFF_SI_FIELD_COUNT, 1)
    return alloc_named_type(str_intern(name))

// Count union leaves in a domain term. This walks the union tree by term shape
// and does not share counting logic with the implementation, so a shared bug
// cannot make the test pass spuriously. Bottom or a single branch returns 1.
fn ts_unf_union_leaves(t: int) -> int:
    if tt_tag(t) == TT_UNION:
        return ts_unf_union_leaves(tt_a(t)) + ts_unf_union_leaves(tt_b(t))
    return 1

// t5.* 用例的夹具入口。

// g_gen_map 按名字查绑定，返回 -1 表示未绑定。t5.f4 使用，独立读取，不复用 checker 内部循环。
fn ts_gen_map_ti(name_ni: int) -> int:
    i : ., mut = 0
    loop:
        if i >= g_gen_map_count:
            return -1
        if cell_load(g_gen_map_names, i * 8) == name_ni:
            return cell_load(g_gen_map_types, i * 8)
        i = i + 1
    return -1

// 单泛型形参和单约束名的 struct 声明记录夹具。约束经 parser 的生产登记
// 函数 save_struct_gen_constrs 写入侧表，测试真实路径，不手写侧表。
fn ts_t5_mk_constr_struct(name: string, cname: string) -> int:
    sa := add_struct(name)
    cell_store(g_structs, sa * ESZ_STRUCTINFO + OFF_SI_GENERIC_COUNT, 1)
    cell_store(g_structs, sa * ESZ_STRUCTINFO + OFF_SI_GENERIC_NAMES, str_intern("T5_CS_T"))
    cb := alloc(8)
    cell_store(cb, 0, str_intern(cname))
    save_struct_gen_constrs(sa, cb, 1)
    return sa

fn ts_t5_mk_constr_enum(name: string, cname: string) -> int:
    ea := add_enum(name)
    cell_store(g_enums, ea * ESZ_ENUMINFO + OFF_EI_GENERIC_COUNT, 1)
    cell_store(g_enums, ea * ESZ_ENUMINFO + OFF_EI_GENERIC_NAMES, str_intern("T5_CE_T"))
    cb := alloc(8)
    cell_store(cb, 0, str_intern(cname))
    save_enum_gen_constrs(ea, cb, 1)
    return ea

// 零方法接口表记录，ts_t5_run 的 constr_iface_is_unknown_p3b 使用。
// 条件：find_iface 命中时，gen_constr_satisfied 返回 -1。
fn ts_t5_mk_iface(name: string) -> int:
    grow_ifaces(g_iface_count + 1)
    base := g_iface_count * ESZ_IFACEINFO
    zi : ., mut = 0
    loop:
        if zi >= ESZ_IFACEINFO:
            break
        cell_store8(g_ifaces, base + zi, 0)
        zi = zi + 1
    cell_store(g_ifaces, base + OFF_IF_NAME, str_intern(name))
    cell_store(g_ifaces, base + OFF_IF_GENERIC_COUNT, 0)
    g_iface_count = g_iface_count + 1
    return g_iface_count - 1

// Do not inline this into type_selftest_run. That function is already large, and
// adding these local variables can overflow the Python bootstrap's stack-based
// code generation. This function returns the failure count.
// 用例数 = 9，调用方的 total = total + 9 必须同步修改。
fn ts_t5_run() -> int:
    fails : ., mut = 0
    // === 泛型约束：保留、实例化判定、反例、实例键类型项化 ===
    // 检查：
    // 1. 参数列表导航。形参节点不连续时的正向和负向控制；旧 pn+1 导航曾在
    //    这里出错。
    // 2. 约束名解析和本质轴判定（1/0/-1）。
    // 3. 用户接口约束返回 -1 表示不判，不等于不满足。
    // 4. 反例文本：失败有值，通过无值。
    // 5. 实例化点检查的诊断去重，同节点同形参只报一次，加正负控制。
    // 6. 结构和枚举约束经 parser 登记函数写入侧表后可读。
    // 7. 实例键结构忠实，异型异键；ti 类型替换落在克隆体的形参类型节点。
    // 夹具不经过 parser 或 check_all，按 t3 和 t4 的做法人工写表，但调用
    // 生产函数：save_struct_gen_constrs、gen_inst_constr_check、
    // infer_gen_call、gen_find_or_create_bind。
    init_types()
    ty_budget_reset(200000)
    // 1. F4：夹具的文件首类型节点是另一个泛型形参的 ident，形参是
    // (n: int, a: T)。类型节点插在形参节点之前，所以形参在节点表里不连续。
    // 旧导航把 param1 的 pattern 读成节点 0，凭空绑定 U，T 永远不绑定。
    // 当前实现把 param1 的 pattern 解析为声明类型 gparam(T)。
    init_types()   // 夹具前再清一次，让节点下标可预期。本组不依赖具体下标。
    t5_u_ni := str_intern("T5_U")
    t5_u_row := alloc_type(TYP_GENERIC_PARAM, t5_u_ni, 0)
    def_sym(t5_u_ni, SYM_TYPE, t5_u_row, -1)
    alloc_node(EXPR_IDENT, 0, 0, 0, t5_u_ni, 0, 0, 0, 0)            // 文件首类型节点
    t5_int_n := alloc_node(0, 0, 0, 0, 0, TY_INT, 0, 0, 0)
    t5_p0 := alloc_node(EXPR_PARAM, str_intern("n"), 0, 0, 0, TY_INT, t5_int_n, 0, 0)
    t5_t_ni := str_intern("T5_T")
    t5_t_row := alloc_type(TYP_GENERIC_PARAM, t5_t_ni, 0)
    def_sym(t5_t_ni, SYM_TYPE, t5_t_row, -1)
    t5_t_n1 := alloc_node(EXPR_IDENT, 0, 0, 0, t5_t_ni, 0, 0, 0, 0)
    t5_p1 := alloc_node(EXPR_PARAM, str_intern("a"), 0, 0, 0, 0, t5_t_n1, 0, 0)
    t5_rt := alloc_node(EXPR_IDENT, 0, 0, 0, t5_t_ni, 0, 0, 0, 0)
    t5_fn := alloc_node(EXPR_FN, str_intern("t5_f4_take"), t5_p0, 2, 0, t5_rt, -1, 0, 0)
    t5_fi := add_func("t5_f4_take", 2, 0, t5_fn)   // add_func 收字符串（parser 同款：tok_lx 结果），不是 ni
    fi_set_generic_count(t5_fi, 1)
    println("M5b")
    fi_set_generic_name(t5_fi, 0, t5_t_ni)
    println("M5c")
    def_sym(str_intern("t5_f4_take"), SYM_FN, TI_UNIT, -1)
    t5_arg2 := alloc_node(EXPR_ARG, alloc_node(EXPR_STRING, 0, 0, 0, str_intern("s"), 0, 0, 0, 0), 0, 0, 0, 0, 0, 0, 0)
    // EXPR_ARG: a = expr, b = next。末项 b = 0 是终止符，列表遍历在 an < 0 时停止，见 infer_gen_call。
    ast_set_b(t5_arg2, -1)
    t5_arg1 := alloc_node(EXPR_ARG, alloc_node(EXPR_INT, 0, 0, 0, 1, 0, 0, 0, 0), t5_arg2, 0, 0, 0, 0, 0, 0)
    t5_calln := alloc_node(EXPR_CALL, 0, t5_arg1, 2, 0, 0, 0, 0, 0)
    infer_gen_call(t5_fi, t5_calln, t5_arg1, 2)
    t5_ti_bound := ts_gen_map_ti(t5_t_ni)
    fails = fails + ts_check_b("t5.f4_later_param_declared_type",
        (t5_ti_bound == TI_STR && ts_gen_map_ti(t5_u_ni) == -1), true)
    fails = fails + ts_check_b("t5.f4_bind_seg_recorded",
        (g_gen_binds_count == 2 && cell_load(g_gen_binds, 0 * 8) == 1 &&
            cell_load(g_gen_binds, 1 * 8) == TI_STR && ast_int_val(t5_calln) == 1), true)
    // 2. 约束名解析和本质轴判定结果。
    t5_ni_int := str_intern("int")
    t5_ni_str := str_intern("string")
    t5_ni_nope := str_intern("T5_NoSuchTypeName")
    fails = fails + ts_check_b("t5.constr_name_resolve",
        (gen_constr_type_ti(t5_ni_int) == TI_INT && gen_constr_type_ti(t5_ni_str) == TI_STR &&
            gen_constr_type_ti(str_intern("never")) == TI_NEVER && gen_constr_type_ti(t5_ni_nope) == -1 &&
            gen_constr_type_ti(-1) == -1), true)
    fails = fails + ts_check_b("t5.constr_essence_three_state",
        (gen_constr_satisfied(t5_ni_int, TI_INT) == 1 &&
         // never 不满足原生约束。引擎当前把 AK_NEVER 当作与 AK_INT 互斥的
         // 原子，不是底部。这是已有语义，本用例如实固定。
            gen_constr_satisfied(t5_ni_int, TI_NEVER) == 0 &&
            gen_constr_satisfied(t5_ni_int, TI_STR) == 0 &&
            gen_constr_satisfied(t5_ni_str, TI_INT) == 0 &&
            gen_constr_satisfied(t5_ni_nope, TI_INT) == -1), true)
    // 3. 用户接口约束和非命名实参返回 -1。接口方法表只能查命名记录，
    // 所以 int 实参不判；这不是未实现。命名实参的判定见 isat.* 和
    // tests/selfhost/test_iface_satisfies.py。
    t5_if_ii := ts_t5_mk_iface("T5_Show")
    fails = fails + ts_check_b("t5.constr_iface_non_named_unjudged",
        (find_iface(str_intern("T5_Show")) == t5_if_ii &&
            gen_constr_satisfied(str_intern("T5_Show"), TI_INT) == -1), true)
    // 4. 反例文本：失败时非空，通过时为空。
    fails = fails + ts_check_b("t5.constr_witness_text",
        (str_len(gen_constr_witness_str(TI_STR, t5_ni_int)) > 0 &&
            str_len(gen_constr_witness_str(TI_INT, t5_ni_int)) == 0 &&
            str_len(gen_constr_witness_str(TI_INT, t5_ni_nope)) == 0), true)
    // 5 和 6. 实例化点检查：结构和枚举约束经 parser 登记函数写入侧表，检查判定、去重、正负控制和接口数据零动作。
    t5_si := ts_t5_mk_constr_struct("T5BoxInt", "int")
    t5_ei := ts_t5_mk_constr_enum("T5EBoxInt", "int")
    t5_si2 := ts_t5_mk_constr_struct("T5BoxShow", "T5_Show")
    fails = fails + ts_check_b("t5.constr_side_table_readback",
        (si_generic_count(t5_si) == 1 && si_gen_constr(t5_si, 0) == t5_ni_int &&
            si_gen_constr(t5_si, 1) == -1 && si_gen_constr(-1, 0) == -1 &&
            ei_generic_count(t5_ei) == 1 && ei_gen_constr(t5_ei, 0) == t5_ni_int &&
            ei_gen_constr(t5_ei, 4) == -1), true)
    t5_args := alloc(8)
    cell_store(t5_args, 0 * 8, TI_STR)
    t5_gnode := alloc_node(EXPR_GENERIC_APPLY, str_intern("T5BoxInt"), -1, 1, 0, 0, 0, 41, 3)
    t5_d0 := g_diag_count
    gen_inst_constr_check(t5_gnode, t5_si, -1, t5_args, 1)
    t5_d1 := g_diag_count
    gen_inst_constr_check(t5_gnode, t5_si, -1, t5_args, 1)      // 同节点同形参 -> 去重
    t5_d2 := g_diag_count
    t5_gnode2 := alloc_node(EXPR_GENERIC_APPLY, str_intern("T5BoxInt"), -1, 1, 0, 0, 0, 42, 3)
    gen_inst_constr_check(t5_gnode2, t5_si, -1, t5_args, 1)     // 新节点 -> 再报（去重不跨节点）
    t5_d3 := g_diag_count
    cell_store(t5_args, 0 * 8, TI_INT)
    t5_gnode3 := alloc_node(EXPR_GENERIC_APPLY, str_intern("T5BoxInt"), -1, 1, 0, 0, 0, 43, 3)
    gen_inst_constr_check(t5_gnode3, t5_si, -1, t5_args, 1)     // 正控：满足 -> 零诊断
    gen_inst_constr_check(t5_gnode3, t5_ei, -1, t5_args, 1)     // 枚举侧同（满足）
    t5_d4 := g_diag_count
    cell_store(t5_args, 0 * 8, TI_STR)
    t5_gnode4 := alloc_node(EXPR_GENERIC_APPLY, str_intern("T5EBoxInt"), -1, 1, 0, 0, 0, 44, 3)
    gen_inst_constr_check(t5_gnode4, -1, t5_ei, t5_args, 1)     // 枚举侧违反 -> 诊断
    t5_d5 := g_diag_count
    t5_gnode5 := alloc_node(EXPR_GENERIC_APPLY, str_intern("T5BoxShow"), -1, 1, 0, 0, 0, 45, 3)
    gen_inst_constr_check(t5_gnode5, t5_si2, -1, t5_args, 1)    // 接口约束 = 不判 -> 零诊断
    t5_d6 := g_diag_count
    fails = fails + ts_check_b("t5.inst_check_dedup_and_controls",
        (t5_d1 - t5_d0 == 1 && t5_d2 - t5_d1 == 0 && t5_d3 - t5_d2 == 1 &&
            t5_d4 - t5_d3 == 0 && t5_d5 - t5_d4 == 1 && t5_d6 - t5_d5 == 0 &&
            ts_diag_code_at(t5_d0) == EC_TG_BOUND &&
         // 末条记录下标 = 调用后计数 - 1（d5 是调用后的 g_diag_count）
            ts_diag_code_at(t5_d5 - 1) == EC_TG_BOUND), true)
    // 7. 实例键：异型异键，同名同记录同键，复合键包含结构。
    t5_a_ti := alloc_named_type(str_intern("T5_A"))
    t5_b_ti := alloc_named_type(str_intern("T5_B"))
    t5_a2_ti := alloc_type(TYP_NAMED, str_intern("T5_A"), 0)
    t5_arr_ti := alloc_type(TYP_ARRAY, TI_INT, 3)
    t5_ptr_ti := alloc_type(TYP_PTR, t5_a_ti, 0)
    t5_slice_ti := alloc_type(TYP_SLICE, TI_INT, 0)
    fails = fails + ts_check_b("t5.inst_key_structural_faithful",
        (str_eq(inst_key_of_ti(t5_a_ti), inst_key_of_ti(t5_b_ti)) == 0 &&
            str_eq(inst_key_of_ti(t5_a_ti), inst_key_of_ti(t5_a2_ti)) != 0 &&
            str_eq(inst_key_of_ti(TI_INT), "int") != 0 &&
            str_eq(inst_key_of_ti(t5_arr_ti), "[int; 3]") != 0 &&
            str_eq(inst_key_of_ti(t5_ptr_ti), "*T5_A") != 0), true)
    // 8. ti 类型替换端到端：克隆体内的泛型形参位替换成实参类型节点；
    // 异键异实例，同键缓存命中。夹具形参实参是切片 [int]，键 "[int]"。
    // ti 路径产生 EXPR_ARRAY 类型节点；名字路径只会产生 EXPR_IDENT("[int]")，
    // 这是非法声明名。因此本条判断能区分 ti 路径是否生效。
    // 替换只覆盖函数体节点。EXPR_FN 分支不克隆形参，形参类型由 fi_param_type
    // 的裸码承担，所以克隆体形参仍指向源节点，与实例化的既有语义一致。
    t5_m_ni := str_intern("T5_M")
    t5_m_tynode := alloc_node(EXPR_IDENT, 0, 0, 0, t5_m_ni, 0, 0, 0, 0)
    t5_m_body := alloc_node(EXPR_RETURN, t5_m_tynode, 0, 0, 0, 0, 0, 0, 0)   // 体内形参位
    t5_m_p := alloc_node(EXPR_PARAM, str_intern("x"), 0, 0, 0, 0, t5_m_tynode, 0, 0)
    t5_m_rt := alloc_node(EXPR_IDENT, 0, 0, 0, t5_m_ni, 0, 0, 0, 0)
    t5_m_fn := alloc_node(EXPR_FN, t5_m_ni, t5_m_p, 1, 0, t5_m_rt, t5_m_body, 0, 0)
    t5_m_fi := add_func("T5_M", 1, 0, t5_m_fn)
    fi_set_generic_count(t5_m_fi, 1)
    fi_set_generic_name(t5_m_fi, 0, t5_m_ni)
    // 绑定段按 checker 的写入形态人工构造：块 = [count, ti...]，节点 int_val = 起始 + 1。
    grow_gen_binds(g_gen_binds_count + 2)
    t5_bstart := g_gen_binds_count
    cell_store(g_gen_binds, t5_bstart * 8, 1)
    cell_store(g_gen_binds, (t5_bstart + 1) * 8, t5_slice_ti)
    g_gen_binds_count = t5_bstart + 2
    t5_key_s := inst_key_of_ti(t5_slice_ti)
    t5_f1 := gen_find_or_create_bind(t5_m_fi, t5_key_s, t5_bstart)
    t5_f2 := gen_find_or_create_bind(t5_m_fi, t5_key_s, t5_bstart)   // 同键 -> 缓存命中
    t5_f3 := gen_find_or_create_bind(t5_m_fi, inst_key_of_ti(t5_b_ti), t5_bstart)  // 异键 -> 新实例
    t5_cp_ok : ., mut = 0
    if t5_f1 >= 0:
        t5_cb := ast_data(fi_ast_node(t5_f1))      // 克隆体（EXPR_FN）的 body
        if t5_cb >= 0 && ast_kind(t5_cb) == EXPR_RETURN:
            t5_cn := ast_a(t5_cb)                  // 体内形参位（源 = EXPR_IDENT(T5_M)）
            if t5_cn >= 0 && ast_kind(t5_cn) == EXPR_ARRAY:
                t5_cn_e := ast_a(t5_cn)            // 切片元素位（源实参 = int）
                if t5_cn_e >= 0 && ast_kind(t5_cn_e) == 0 && ast_type_val(t5_cn_e) == TY_INT:
                    t5_cp_ok = 1
    fails = fails + ts_check_b("t5.inst_ti_subst_in_clone",
        (t5_f1 >= 0 && t5_f2 == t5_f1 && t5_f3 >= 0 && t5_f3 != t5_f1 && t5_cp_ok == 1), true)

    return fails

// === iface_satisfies 契约用例（isat.*）===
// 判定顺序：A 形状，C 用户接口，B 本质类型。结果 -1 表示无法判定，
// 不得当成 0 或 1。轴 C 的条件与 check_iface 相同：方法名存在、参数计数
// 和返回类型匹配。域限定为命名记录。
// 主要判断依据：1. 1/0/-1 原样返回，不是查不到就返回 0；2. 与 check_iface 逐例
// 比较；3. 判定路径不调用 str_intern；4. 形状表的注册、覆盖和复位。

// 追加接口方法，写入位置与 parser 的 interface 分支相同：mbase + name、param_count、ret_ti。
fn ts_isat_add_method(ii: int, mname: string, pc: int, rt: int) -> int:
    n := cell_load(g_ifaces, ii * ESZ_IFACEINFO + OFF_IF_METHOD_COUNT)
    mbase := ii * ESZ_IFACEINFO + OFF_IF_METHODS + n * ESZ_IFMETHOD
    cell_store(g_ifaces, mbase + OFF_IFM_NAME, str_intern(mname))
    cell_store(g_ifaces, mbase + OFF_IFM_PARAM_COUNT, pc)
    cell_store(g_ifaces, mbase + OFF_IFM_RET_TI, rt)
    // 返回类型节点槽与 parser 相同：基类型节点是 kind 0，type_val = TY_*。
    // 接收者模式 0 表示无接收者，本组夹具使用这种形态。
    cell_store(g_ifaces, mbase + OFF_IFM_RET_NODE, ts_ifc_base_node(rt))
    cell_store(g_ifaces, mbase + OFF_IFM_SELF_MODE, 0)
    pj : ., mut = 0
    loop:
        if pj >= pc || pj >= MAX_IFACE_METHOD_PARAMS:
            break
        cell_store(g_ifaces, mbase + OFF_IFM_PARAM_TYPES + pj * 8, TY_INT)
        cell_store(g_ifaces, mbase + OFF_IFM_PARAM_NODES + pj * 8, ts_ifc_base_node(TY_INT))
        pj = pj + 1
    cell_store(g_ifaces, ii * ESZ_IFACEINFO + OFF_IF_METHOD_COUNT, n + 1)
    return mbase

// 基类型节点，与 parser 的 parse_type 产物同形：kind 0，type_val = TY_*。
// 签名数据消费点 sh_sig_term_of_node 经 res_type_node 使用同一分派表。
fn ts_ifc_base_node(ty: int) -> int:
    return alloc_node(0, 0, 0, 0, 0, ty, 0, 0, 0)

// 登记 impl 方法，写入位置与 parser 的 impl 分支相同：mangled 函数名和
// g_methods 三元组 {type_ni, method_ni, mangled_ni}。夹具必须与生产写点
// 同形，否则对拍没有意义。
// 函数记录带真正的 EXPR_FN 节点：参数列表和类型节点；形参节点不连续，
// 类型节点插在后面，按 parse_body 的分配布局。签名数据 sh_func_sig_term
// 从 AST 读取参数和返回类型。
fn ts_isat_add_impl_method(tname_ni: int, mname: string, pc: int, rt: int) -> int:
    mn := istr_get(tname_ni) + "." + mname
    mangled_ni := str_intern(mn)
    pf : ., mut = -1
    pj : ., mut = 0
    loop:
        if pj >= pc:
            break
        tn := ts_ifc_base_node(TY_INT)
        if pf < 0:
            pf = g_ast_count
        alloc_node(EXPR_PARAM, str_intern("p"), 0, 0, 0, TY_INT, tn, 0, 0)
        pj = pj + 1
    rtn := ts_ifc_base_node(rt)
    fn_node := alloc_node(EXPR_FN, mangled_ni, pf, pc, rt, rtn, -1, 0, 0)
    fi := add_func(mn, pc, rt, fn_node)
    grow_methods(g_method_count + 1)
    cell_store(g_methods, g_method_count * 24, tname_ni)
    cell_store(g_methods, g_method_count * 24 + 8, str_intern(mname))
    cell_store(g_methods, g_method_count * 24 + 16, mangled_ni)
    g_method_count = g_method_count + 1
    return fi

fn ts_isat_b2i(b: bool) -> int:
    if b:
        return 1
    return 0

// 用例数 = 16，调用方的 total = total + 16 必须同步修改。
fn ts_isat_run() -> int:
    fails : ., mut = 0
    // 夹具：接口 T0bShow { fn show(pc=1, rt=0) }；命名记录 T0bS 有 show，
    // T0bT 没有方法。
    // rt 码是映射层编码：0 = TY_INT，见 type_engine.cr 轴 C 的说明。
    isat_ii := ts_t5_mk_iface("T0bShow")
    ts_isat_add_method(isat_ii, "show", 1, 0)
    isat_show_ni := str_intern("show")
    isat_s_ti := alloc_named_type(str_intern("T0bS"))
    isat_t_ti := alloc_named_type(str_intern("T0bT"))
    ts_isat_add_impl_method(str_intern("T0bS"), "show", 1, 0)
    // 1. 轴 C 正例：方法存在，参数计数和返回类型匹配，返回 1。命名记录的空方法集见第 12 例。
    fails = fails + ts_check("isat.axis_c_satisfied",
        iface_satisfies(isat_s_ti, str_intern("T0bShow")), 1)
    // 2. 轴 C 反例：方法不存在，返回 0，这是确定的违反，不是 -1。
    fails = fails + ts_check("isat.axis_c_missing_method",
        iface_satisfies(isat_t_ti, str_intern("T0bShow")), 0)
    // 3. 轴 C 反例：参数计数不符，返回 0。
    isat_c_ti := alloc_named_type(str_intern("T0bC"))
    ts_isat_add_impl_method(str_intern("T0bC"), "show", 2, 0)
    fails = fails + ts_check("isat.axis_c_param_count",
        iface_satisfies(isat_c_ti, str_intern("T0bShow")), 0)
    // 4. 轴 C 反例：返回类型码不符（3 = TY_STRING），返回 0。
    isat_r_ti := alloc_named_type(str_intern("T0bR"))
    ts_isat_add_impl_method(str_intern("T0bR"), "show", 1, 3)
    fails = fails + ts_check("isat.axis_c_ret_code",
        iface_satisfies(isat_r_ti, str_intern("T0bShow")), 0)
    // 5. 域限定：非命名记录（原生、dyn、泛型形参）返回 -1，不判。没有方法表身份时，不得因为查不到就返回 0。
    isat_dyn_ti := alloc_type(TYP_DYN, 0, 0)
    isat_gp_ti := alloc_type(TYP_GENERIC_PARAM, str_intern("T0bU"), 0)
    fails = fails + ts_check("isat.axis_c_non_named_unjudged",
        ts_isat_b2i(iface_satisfies(TI_INT, str_intern("T0bShow")) == -1 &&
            iface_satisfies(isat_dyn_ti, str_intern("T0bShow")) == -1 &&
            iface_satisfies(isat_gp_ti, str_intern("T0bShow")) == -1), 1)
    // 6. 轴 B：本质类型，调用 gen_constr_satisfied。
    fails = fails + ts_check("isat.axis_b_essence",
        ts_isat_b2i(iface_satisfies(TI_INT, str_intern("int")) == 1 &&
            iface_satisfies(TI_INT, str_intern("string")) == 0 &&
            iface_satisfies(TI_INT, str_intern("T0bNoSuchName")) == -1), 1)
    // 7. 轴 A：横切形状。注册 top_k(AK_SEQUENCE) 后，切片记录返回 1，
    // 原生记录返回 0；复位后同名查询返回 -1。
    // 形状表在 init_types 尾部已有 6 条生产注册表项；本条是第 7 条（槽 6）。
    // 计数基数从 0 改为 6，注册、查询和判定语义不变。
    isat_seq_ti := alloc_type(TYP_SLICE, TI_INT, 0)
    isat_shape_name := str_intern("T0bShapeSeq")
    isat_n_pre := iface_shape_count()
    isat_slot := iface_shape_register(isat_shape_name, tt_top_k(AK_SEQUENCE))
    fails = fails + ts_check("isat.axis_a_shape",
        ts_isat_b2i(isat_slot == isat_n_pre && iface_shape_count() == isat_n_pre + 1 &&
            iface_shape_lookup(isat_shape_name) >= 0 &&
            iface_satisfies(isat_seq_ti, isat_shape_name) == 1 &&
            iface_satisfies(TI_INT, isat_shape_name) == 0), 1)
    // 8. 轴优先级：同名既是形状又是接口，形状优先。TI_INT 在形状数据上
    // 判 0，在用户轴恒为 -1；结果 0 证明走了轴 A。零方法接口在用户轴的
    // 路径由第 12 例覆盖。
    isat_dup_ii := ts_t5_mk_iface("T0bDup")
    fails = fails + ts_check("isat.axis_order_shape_first",
        ts_isat_b2i(find_iface(str_intern("T0bDup")) == isat_dup_ii &&
            iface_shape_register(str_intern("T0bDup"), tt_top_k(AK_SEQUENCE)) >= 0 &&
            iface_satisfies(TI_INT, str_intern("T0bDup")) == 0), 1)
    // 9. 轴优先级：同名既是接口又是原生类型名，接口优先，与
    // gen_constr_satisfied 的 find_iface 先行相同。非命名实参返回 -1，
    // 不进入本质轴。
    ts_t5_mk_iface("int")
    fails = fails + ts_check("isat.axis_order_iface_over_essence",
        ts_isat_b2i(iface_satisfies(TI_INT, str_intern("int")) == -1), 1)
    // 10. 与 check_iface 逐例比较：满足、参数计数不符、返回类型码不符
    // 三种形态。缺方法形态在第 2 和第 11 例分别检查 0 和零驻留表增长。
    isat_eq : ., mut = -1
    if ts_isat_b2i(check_iface(str_intern("T0bS"), isat_ii)) == iface_satisfies(isat_s_ti, str_intern("T0bShow")):
        if ts_isat_b2i(check_iface(str_intern("T0bC"), isat_ii)) == iface_satisfies(isat_c_ti, str_intern("T0bShow")):
            if ts_isat_b2i(check_iface(str_intern("T0bR"), isat_ii)) == iface_satisfies(isat_r_ti, str_intern("T0bShow")):
                isat_eq = 1
    fails = fails + ts_check("isat.predicate_same_as_check_iface", isat_eq, 1)
    // 11. 判定路径不调用 str_intern：缺失方法名时返回 0，不得把新字符串
    // 加入驻留表。type_has_method 的 str_intern("T.m") 写法会在这里增长表。
    isat_zz_ti := alloc_named_type(str_intern("T0bZz"))
    isat_before := g_str_count
    iface_satisfies(isat_zz_ti, str_intern("T0bShow"))
    fails = fails + ts_check("isat.no_str_intern_on_missing",
        ts_isat_b2i(g_str_count == isat_before), 1)
    // 12. 空方法集满足：零方法接口加命名记录返回 1；非命名记录返回 -1，域检查先于空循环。
    isat_empty_ii := ts_t5_mk_iface("T0bEmpty")
    fails = fails + ts_check("isat.empty_iface_vacuous",
        ts_isat_b2i(find_iface(str_intern("T0bEmpty")) == isat_empty_ii &&
            iface_satisfies(isat_t_ti, str_intern("T0bEmpty")) == 1 &&
            iface_satisfies(TI_INT, str_intern("T0bEmpty")) == -1), 1)
    // 13. 泛型应用记录：查方法使用基名，走 decl_name_of_ti 的 TYP_GENERIC_APPLY 分支。
    grow_gen_apply_data(g_gen_apply_data_count + 2)
    isat_ga_s := g_gen_apply_data_count
    cell_store(g_gen_apply_data, isat_ga_s * 8, 1)
    cell_store(g_gen_apply_data, (isat_ga_s + 1) * 8, TI_INT)
    g_gen_apply_data_count = isat_ga_s + 2
    isat_ga_ti := alloc_type(TYP_GENERIC_APPLY, isat_s_ti, isat_ga_s)
    fails = fails + ts_check("isat.generic_apply_base_name",
        iface_satisfies(isat_ga_ti, str_intern("T0bShow")), 1)
    // 14. 判定结果和预算隔离：不可译记录（越界 ti）和负键返回 -1；
    // 成功判定后预算窗口必须干净。
    ty_budget_reset(200000)
    isat_bad_ti := g_type_count + 7
    // 两条引擎路径：节点同一快路径 0 步；非同一比较会累计步数，退出时必须
    // 复位。如果缺少出口复位，g_ty_steps > 0 会让本用例失败。
    isat_ok := iface_satisfies(TI_STR, str_intern("string"))   // 轴 B 快路径（勿用 int，9 已声明同名接口）
    isat_no := iface_satisfies(TI_INT, str_intern("string"))   // 轴 B 非同一 -> 计步
    fails = fails + ts_check("isat.three_state_budget_isolated",
        ts_isat_b2i(isat_ok == 1 && isat_no == 0 && g_ty_steps == 0 && g_ty_budget_max == IFACE_SAT_BUDGET &&
            iface_satisfies(isat_bad_ti, str_intern("int")) == -1 &&
            iface_satisfies(TI_INT, isat_bad_ti) == -1 &&
            iface_satisfies(-1, 0) == -1 && iface_satisfies(TI_INT, -1) == -1 &&
            iface_satisfies_term(-1, tt_top()) == -1 && iface_satisfies_term(TI_INT, -1) == -1 &&
            g_ty_exhausted == 0), 1)
    // 15. 形状表语义：同名重注册不增长，负键拒绝，复位后同名查询未命中。
    isat_n := iface_shape_count()
    fails = fails + ts_check("isat.shape_registry_semantics",
        ts_isat_b2i(iface_shape_register(isat_shape_name, tt_top_k(AK_SEQUENCE)) == isat_slot &&
            iface_shape_count() == isat_n &&
            iface_shape_register(-1, tt_top()) == -1 &&
            iface_shape_register(isat_shape_name, -1) == -1 &&
            iface_shape_lookup(-1) == -1 &&
            iface_shape_lookup(str_intern("T0bNoShape")) == -1), 1)
    iface_shape_reset()
    fails = fails + ts_check("isat.shape_registry_reset",
        ts_isat_b2i(iface_shape_count() == 0 && iface_shape_lookup(isat_shape_name) == -1 &&
            iface_satisfies(isat_seq_ti, isat_shape_name) == -1), 1)
    return fails

// 不得内联进 type_selftest_run，原因同 ts_t5_run：栈式代码生成上限。
// 用例数 = 15，调用方的 total = total + 15 必须同步修改。
// 检查：1. 六种横切形状项（序列、只读、可写、可索引、可迭代、product）的
// 满足判定。2. 两个消费点换位后的等价前提：索引后备检查与 IP_INDEX 许可集；
// range 固定性与 TYP_ARRAY。枚举全部类型表记录。
// 每例除判定值外再加一条非同一比较断言：实参项 != 形状项，所以结果不可能
// 来自 ty_sub 的 a == b 快路径。两条枚举例单独断言枚举规模，防止零行遍历。
fn ts_x2_b(b: bool) -> int:
    if b:
        return 1
    return 0

fn ts_x2_run() -> int:
    fails : ., mut = 0
    // 夹具：类型表记录。
    x2_arr := alloc_type(TYP_ARRAY, TI_INT, 3)        // 固定长序列（固定性位 = N = 3）
    x2_slice := alloc_type(TYP_SLICE, TI_INT, 0)      // 视图（固定性位 = -1）
    x2_ro_view := alloc_type(TYP_REF, x2_slice, 0)    // &[int]（只读视图）
    x2_rw_view := alloc_type(TYP_REF, x2_slice, 1)    // &mut [int]（可写视图）
    grow_gen_apply_data(g_gen_apply_data_count + 1)   // 元组行：字段列（product 类型表记录）
    x2_tup_start := g_gen_apply_data_count
    cell_store(g_gen_apply_data, x2_tup_start * 8, TI_INT)
    g_gen_apply_data_count = x2_tup_start + 1
    x2_tup := alloc_type(TYP_TUPLE, 1, x2_tup_start)
    x2_named := alloc_named_type(str_intern("X2ShapeN"))

    // 1. 序列形状：数组和切片满足；原生类型、只读视图、命名记录不满足。非同一断言：实参项不等于形状项。
    fails = fails + ts_check("x2.seq_accepts_body",
        ts_x2_b(iface_satisfies_term(x2_arr, sh_shape_seq()) == 1 &&
            iface_satisfies_term(x2_slice, sh_shape_seq()) == 1 &&
            sh_term_of_ti(x2_arr) != sh_shape_seq() && sh_term_of_ti(x2_slice) != sh_shape_seq()), 1)
    fails = fails + ts_check("x2.seq_rejects_non_body",
        ts_x2_b(iface_satisfies_term(TI_INT, sh_shape_seq()) == 0 &&
            iface_satisfies_term(x2_ro_view, sh_shape_seq()) == 0 &&
            iface_satisfies_term(x2_named, sh_shape_seq()) == 0), 1)
    // 2. 只读序列：数组、切片和只读视图满足；可写视图不满足。
    // 只读视图由 AK_REF 的协变槽判定，元素不是 top 时也成立。
    fails = fails + ts_check("x2.ro_accepts_body_and_ro_view",
        ts_x2_b(iface_satisfies_term(x2_arr, sh_shape_seq_ro()) == 1 &&
            iface_satisfies_term(x2_slice, sh_shape_seq_ro()) == 1 &&
            iface_satisfies_term(x2_ro_view, sh_shape_seq_ro()) == 1 &&
            iface_satisfies_term(x2_rw_view, sh_shape_seq_ro()) == 0 &&
            sh_term_of_ti(x2_ro_view) != sh_shape_seq_ro()), 1)
    // 3. 可写序列：数组和切片满足，只读视图拒绝。
    fails = fails + ts_check("x2.rw_accepts_body_rejects_ro_view",
        ts_x2_b(iface_satisfies_term(x2_arr, sh_shape_seq_rw()) == 1 &&
            iface_satisfies_term(x2_slice, sh_shape_seq_rw()) == 1 &&
            iface_satisfies_term(x2_ro_view, sh_shape_seq_rw()) == 0 &&
            iface_satisfies_term(TI_INT, sh_shape_seq_rw()) == 0), 1)
    // 4. 可写视图形状无法表达，这是已登记行为。ref(mut=1, top_k(SEQ)) 的
    // 不变槽遇到 top，返回 -1，不得当成 0 或 1。
    // 直接调用引擎读取 uncovered 位：iface_satisfies_term 出口会复位预算并
    // 清除该位，本层读不到。
    ty_budget_reset(200000)
    x2_rw_shape := tt_atom(AK_REF, -1, tt_cons(sh_ref_mut_marker(1), tt_cons(tt_top_k(AK_SEQUENCE), tt_nil())))
    x2_rw_s := iface_satisfies_term(x2_rw_view, x2_rw_shape)
    ty_budget_reset(200000)
    x2_rw_direct := ty_sub(sh_term_of_ti(x2_rw_view), x2_rw_shape)
    x2_rw_unc := ty_uncovered()
    fails = fails + ts_check("x2.rw_view_unexpressible",
        ts_x2_b(x2_rw_s == -1 && x2_rw_direct == -1 && x2_rw_unc == 1), 1)
    ty_budget_reset(200000)
    // 5. 可索引：字符串和序列满足；原生类型不满足。
    fails = fails + ts_check("x2.indexable_str_and_seq",
        ts_x2_b(iface_satisfies_term(TI_STR, sh_shape_indexable()) == 1 &&
            iface_satisfies_term(x2_arr, sh_shape_indexable()) == 1 &&
            iface_satisfies_term(x2_slice, sh_shape_indexable()) == 1 &&
            iface_satisfies_term(TI_INT, sh_shape_indexable()) == 0), 1)
    // 6. 可迭代和 product：序列满足可迭代；元组满足 product；原生类型和命名记录都不满足。
    fails = fails + ts_check("x2.iterable_and_product",
        ts_x2_b(iface_satisfies_term(x2_arr, sh_shape_iterable()) == 1 &&
            iface_satisfies_term(x2_slice, sh_shape_iterable()) == 1 &&
            iface_satisfies_term(TI_INT, sh_shape_iterable()) == 0 &&
            iface_satisfies_term(x2_tup, sh_shape_product()) == 1 &&
            iface_satisfies_term(TI_INT, sh_shape_product()) == 0 &&
            iface_satisfies_term(x2_named, sh_shape_product()) == 0), 1)
    // 7. 索引检查换位等价：可索引形状的满足集等于 IP_INDEX 许可集，
    // 枚举全部类型表记录。单独断言枚举规模：记录数和许可记录数下界。
    x2_n_rows : ., mut = 0
    x2_bad : ., mut = 0
    x2_n_perm : ., mut = 0
    x2_n_undec : ., mut = 0
    x2_i : ., mut = 0
    loop:
        if x2_i >= g_type_count:
            break
        x2_n_rows = x2_n_rows + 1
        x2_s := iface_satisfies_term(x2_i, sh_shape_indexable())
        x2_o := iface_permits(iface_kind_of(x2_i), IP_INDEX)
        if x2_s == -1:
            x2_n_undec = x2_n_undec + 1
        else:
            if x2_s == 1:
                x2_n_perm = x2_n_perm + 1
            if (x2_s == 1) != (x2_o == 1):
                x2_bad = x2_bad + 1
        x2_i = x2_i + 1
    fails = fails + ts_check("x2.indexable_matches_ops",
        ts_x2_b(x2_n_rows == g_type_count && x2_n_rows >= 15 && x2_bad == 0 &&
            x2_n_perm >= 3 && x2_n_undec == 0 && get_type_kind(TI_STR) == TYP_BASE), 1)
    // 8. range 分支换位等价：形状满足且固定性位 >= 0 等价于
    // kind == TYP_ARRAY，枚举全部类型表记录。固定长度记录和视图记录都必须
    // 出现，否则枚举集为空。
    x2_bad2 : ., mut = 0
    x2_n_fixed : ., mut = 0
    x2_n_view : ., mut = 0
    x2_j : ., mut = 0
    loop:
        if x2_j >= g_type_count:
            break
        x2_s2 := iface_satisfies_term(x2_j, sh_shape_seq())
        if x2_s2 != -1:
            x2_fixed : ., mut = 0
            if x2_s2 == 1:
                if sh_seq_fixed_len_of_ti(x2_j) >= 0:
                    x2_fixed = 1
            x2_k : ., mut = 0
            if get_type_kind(x2_j) == TYP_ARRAY:
                x2_k = 1
            if x2_fixed != x2_k:
                x2_bad2 = x2_bad2 + 1
            if x2_s2 == 1:
                if x2_fixed == 1:
                    x2_n_fixed = x2_n_fixed + 1
                else:
                    x2_n_view = x2_n_view + 1
        x2_j = x2_j + 1
    fails = fails + ts_check("x2.range_fixedness_matches_kind",
        ts_x2_b(x2_bad2 == 0 && x2_n_fixed >= 1 && x2_n_view >= 1), 1)
    // 9. 形状名注册：六个规范项可按名查询，判定结果与 sh_shape_* 构造项
    // 相同。复位后同名返回 -1。
    // iface_shape_builtin_init 显式重跑是幂等的；随后注册六个自测名，
    // 计数为 6 + 6。
    iface_shape_builtin_init()
    x2_p1 := iface_shape_lookup(str_intern("sequence"))
    x2_p2 := iface_shape_lookup(str_intern("sequence_ro"))
    x2_p3 := iface_shape_lookup(str_intern("sequence_rw"))
    x2_p4 := iface_shape_lookup(str_intern("indexable"))
    x2_p5 := iface_shape_lookup(str_intern("iterable"))
    x2_p6 := iface_shape_lookup(str_intern("product"))
    fails = fails + ts_check("x2.shape_builtin_names", ts_x2_b(
            iface_shape_count() == 6 && x2_p1 == sh_shape_seq() && x2_p2 == sh_shape_seq_ro() &&
            x2_p3 == sh_shape_seq_rw() && x2_p4 == sh_shape_indexable() &&
            x2_p5 == sh_shape_iterable() && x2_p6 == sh_shape_product() &&
            iface_satisfies(x2_arr, str_intern("sequence")) == 1 &&
            iface_satisfies(TI_INT, str_intern("sequence")) == 0), 1)
    x2_n0 := iface_shape_count()
    x2_r1 := iface_shape_register(str_intern("X2NameSeq"), sh_shape_seq())
    x2_r2 := iface_shape_register(str_intern("X2NameIdx"), sh_shape_indexable())
    x2_r3 := iface_shape_register(str_intern("X2NameRo"), sh_shape_seq_ro())
    x2_r4 := iface_shape_register(str_intern("X2NameRw"), sh_shape_seq_rw())
    x2_r5 := iface_shape_register(str_intern("X2NameItr"), sh_shape_iterable())
    x2_r6 := iface_shape_register(str_intern("X2NameProd"), sh_shape_product())
    fails = fails + ts_check("x2.axis_a_registered",
        ts_x2_b(x2_r1 >= 0 && x2_r2 >= 0 && x2_r3 >= 0 && x2_r4 >= 0 && x2_r5 >= 0 && x2_r6 >= 0 &&
            iface_shape_count() == x2_n0 + 6 &&
            iface_satisfies(x2_arr, str_intern("X2NameSeq")) == 1 &&
            iface_satisfies(x2_arr, str_intern("X2NameIdx")) == 1 &&
            iface_satisfies(x2_ro_view, str_intern("X2NameRo")) == 1 &&
            iface_satisfies(x2_ro_view, str_intern("X2NameRw")) == 0 &&
            iface_satisfies(x2_tup, str_intern("X2NameProd")) == 1 &&
            iface_satisfies(TI_INT, str_intern("X2NameSeq")) == 0), 1)
    iface_shape_reset()
    // 复位检查规则不变（count = 0 + 旧键 -1）；新增生产注册表的
    // 复位后可重建断言（生产重置点 = reset_frontend_state 清 count，随 init_types 尾部
    // 的 iface_shape_builtin_init 重建 -> 长驻进程每请求一致）。
    x2_restored : ., mut = 0
    if iface_shape_count() == 0 && iface_satisfies(x2_arr, str_intern("X2NameSeq")) == -1:
        iface_shape_builtin_init()
        if iface_shape_count() == 6 && iface_shape_lookup(str_intern("sequence")) == sh_shape_seq():
            x2_restored = 1
    fails = fails + ts_check("x2.shape_no_leak_after_reset",
        ts_x2_b(x2_restored == 1), 1)
    // 10. 判定和查询路径不调用 str_intern：形状项构造、按名查询和注册
    // 幂等重跑都不得增长 g_strs。
    // 初始化时一次性注册 6 个名字。这里同时检查零增长和六名可查。
    x2_strs := g_str_count
    x2_t1 := sh_shape_seq()
    x2_t2 := sh_shape_seq_ro()
    x2_t3 := sh_shape_seq_rw()
    x2_t4 := sh_shape_indexable()
    x2_t5 := sh_shape_iterable()
    x2_t6 := sh_shape_product()
    x2_p1b := iface_shape_lookup(str_intern("sequence"))
    x2_p2b := iface_shape_lookup(str_intern("sequence_ro"))
    x2_p3b := iface_shape_lookup(str_intern("sequence_rw"))
    x2_p4b := iface_shape_lookup(str_intern("indexable"))
    x2_p5b := iface_shape_lookup(str_intern("iterable"))
    x2_p6b := iface_shape_lookup(str_intern("product"))
    iface_shape_builtin_init()   // 幂等重跑（不得再增长驻留表）
    fails = fails + ts_check("x2.no_str_intern",
        ts_x2_b(g_str_count == x2_strs && x2_t1 >= 0 && x2_t2 >= 0 && x2_t3 >= 0 &&
            x2_t4 >= 0 && x2_t5 >= 0 && x2_t6 >= 0 &&
            x2_p1b == x2_t1 && x2_p2b == x2_t2 && x2_p3b == x2_t3 &&
            x2_p4b == x2_t4 && x2_p5b == x2_t5 && x2_p6b == x2_t6), 1)
    // 11. 形状数据的判定约定：越界记录、负键、不可译记录返回 -1；成功判定后预算窗口干净。
    ty_budget_reset(200000)
    x2_ok := iface_satisfies_term(x2_arr, sh_shape_seq())     // 非同一 -> 计步（非快路径）
    fails = fails + ts_check("x2.uncovered_not_folded",
        ts_x2_b(x2_ok == 1 && g_ty_steps == 0 && g_ty_budget_max == IFACE_SAT_BUDGET &&
            iface_satisfies_term(-1, sh_shape_seq()) == -1 &&
            iface_satisfies_term(g_type_count + 7, sh_shape_seq()) == -1 &&
            iface_satisfies_term(TI_INT, -1) == -1 &&
            iface_satisfies(x2_arr, -1) == -1 && iface_satisfies(-1, 0) == -1 &&
            g_ty_exhausted == 0), 1)
    // 12. 用户接口形状项：零方法接口产生空 product，可满足；未声明接口名
    // 返回 -1。命名记录加零方法返回 1；原生记录受域限定返回 -1。
    x2_ii := ts_t5_mk_iface("X2ShapeIface")
    fails = fails + ts_check("x2.iface_shape_term_built",
        ts_x2_b(find_iface(str_intern("X2ShapeIface")) == x2_ii &&
            sh_iface_shape_term(str_intern("X2ShapeIface")) >= 0 &&
            sh_iface_shape_term(str_intern("X2NoSuchIface")) == -1 &&
            iface_satisfies(x2_named, str_intern("X2ShapeIface")) == 1 &&
            iface_satisfies(TI_INT, str_intern("X2ShapeIface")) == -1), 1)
    // 13. 形状项和类型表记录的桥接：切片的项除固定性位外与数组项同形，
    // 两者同判。固定性不进入形状判定。
    x2_same : ., mut = 0
    x2_ta := sh_term_of_ti(x2_arr)
    x2_ts := sh_term_of_ti(x2_slice)
    if x2_ta >= 0 && x2_ts >= 0 && x2_ta != x2_ts:
        if ty_sub(x2_ta, x2_ts) == 1 && ty_sub(x2_ts, x2_ta) == 1:
            x2_same = 1
    fails = fails + ts_check("x2.fixedness_not_in_shape_judgment",
        ts_x2_b(x2_same == 1 && sh_seq_fixed_len_of_ti(x2_arr) == 3 &&
            sh_seq_fixed_len_of_ti(x2_slice) == -1 && sh_seq_fixed_len_of_ti(TI_INT) == -1), 1)
    return fails

// === impl 契约用例（ifc.*）===
// 签名和形状：
// 1. 签名类型项化：接口方法条目的类型节点槽是签名的来源，判定按类型而不是
//    裸码，包括命名、泛型应用、接收者模式和元数。
// 2. 接口形状项是方法集的 product，b 槽是方法名；检查可建项和不可建项。
// 3. 方法解析走 g_methods，判定路径不调用 str_intern。
// 4. 不可判返回 -1，不得当成 0 或 1。
// 夹具须与 parser 的 interface 和 impl 分支同形：接口方法条目包含节点槽和
// 接收者模式；impl 函数记录包含真正的 EXPR_FN，参数列表和类型节点，形参
// 节点不连续。
// 用例数 = 14，调用方的 total = total + 14 必须同步修改。

// 命名类型夹具（结构声明 + SYM_TYPE 登记 + 命名记录，供 res_type_node 的 EXPR_IDENT /
// EXPR_GENERIC_APPLY 两分支解析）。
fn ts_ifc_mk_named(name: string) -> int:
    ni := str_intern(name)
    add_struct(name)
    ti := alloc_named_type(ni)
    def_sym(ni, SYM_TYPE, ti, -1)
    return ti

// 签名类型节点夹具：命名型（EXPR_IDENT，int_val = 名字 ni）
fn ts_ifc_named_node(name: string) -> int:
    return alloc_node(EXPR_IDENT, 0, 0, 0, str_intern(name), 0, 0, 0, 0)

// 签名类型节点：序列（EXPR_ARRAY；n = 长度，0 = 视图），实参根单槽契约照 parser 产物
fn ts_ifc_seq_node(elem_node: int, n: int) -> int:
    return alloc_node(EXPR_ARRAY, elem_node, 0, 0, n, 0, 0, 0, 0)

// 签名类型节点：泛型应用（EXPR_GENERIC_APPLY；a = 基名 ni、b = 首实参节点（连续）、c = 个数）
fn ts_ifc_apply_node(base_name: string, arg_node: int) -> int:
    return alloc_node(EXPR_GENERIC_APPLY, str_intern(base_name), arg_node, 1, 0, 0, 0, 0, 0)

// 接口方法条目（节点数据可控：pnodes = 参数节点缓冲（可 -1 = 全无节点）；rnode = 返回型节点；
// smode = 接收者模式（0 = 无接收者，1/2/3 = self/&self/&mut self））
fn ts_ifc_add_method_n(ii: int, mname: string, pc: int, smode: int, n0: int, n1: int, n2: int, n3: int, rnode: int) -> int:
    n := cell_load(g_ifaces, ii * ESZ_IFACEINFO + OFF_IF_METHOD_COUNT)
    mbase := ii * ESZ_IFACEINFO + OFF_IF_METHODS + n * ESZ_IFMETHOD
    cell_store(g_ifaces, mbase + OFF_IFM_NAME, str_intern(mname))
    cell_store(g_ifaces, mbase + OFF_IFM_PARAM_COUNT, pc)
    cell_store(g_ifaces, mbase + OFF_IFM_RET_TI, 0)
    cell_store(g_ifaces, mbase + OFF_IFM_RET_NODE, rnode)
    cell_store(g_ifaces, mbase + OFF_IFM_SELF_MODE, smode)
    pj : ., mut = 0
    loop:
        if pj >= pc || pj >= MAX_IFACE_METHOD_PARAMS:
            break
        pn : ., mut = -1
        if pj == 0:
            pn = n0
        if pj == 1:
            pn = n1
        if pj == 2:
            pn = n2
        if pj == 3:
            pn = n3
        cell_store(g_ifaces, mbase + OFF_IFM_PARAM_TYPES + pj * 8, TY_INT)
        cell_store(g_ifaces, mbase + OFF_IFM_PARAM_NODES + pj * 8, pn)
        pj = pj + 1
    cell_store(g_ifaces, ii * ESZ_IFACEINFO + OFF_IF_METHOD_COUNT, n + 1)
    return mbase

// impl 侧函数行（节点数据可控；mode0 = 首参接收者模式（≠0 时该参无节点，接收者槽约定））。
// 返回 = 函数行号。
fn ts_ifc_add_impl(tname_ni: int, mname: string, pc: int, mode0: int, n0: int, n1: int, rnode: int) -> int:
    mn := istr_get(tname_ni) + "." + mname
    mangled_ni := str_intern(mn)
    pf : ., mut = -1
    pj : ., mut = 0
    loop:
        if pj >= pc:
            break
        pn2 : ., mut = -1
        m : ., mut = 0
        if pj == 0:
            m = mode0
        if m == 0:
            if pj == 0:
                pn2 = n0
            if pj == 1:
                pn2 = n1
        if pf < 0:
            pf = g_ast_count
        alloc_node(EXPR_PARAM, str_intern("p"), 0, 0, m, TY_INT, pn2, 0, 0)
        pj = pj + 1
    fn_node := alloc_node(EXPR_FN, mangled_ni, pf, pc, 0, rnode, -1, 0, 0)
    fi : ., mut = add_func(mn, pc, 0, fn_node)
    grow_methods(g_method_count + 1)
    cell_store(g_methods, g_method_count * 24, tname_ni)
    cell_store(g_methods, g_method_count * 24 + 8, str_intern(mname))
    cell_store(g_methods, g_method_count * 24 + 16, mangled_ni)
    g_method_count = g_method_count + 1
    return fi

fn ts_ifc_run() -> int:
    fails : ., mut = 0
    // ── 夹具：4 个命名类型（A/B 同构异名，名义 vs 结构）+ 3 个 impl 实现类型 ──
    ifc_a_ti := ts_ifc_mk_named("IfcA")
    ts_ifc_mk_named("IfcB")
    ts_ifc_mk_named("IfcBox")
    ifc_a_n := ts_ifc_named_node("IfcA")
    ifc_b_n := ts_ifc_named_node("IfcB")
    ifc_int_n := ts_ifc_base_node(TY_INT)
    // 泛型应用节点：`IfcBox[IfcA]` / `IfcBox[IfcB]`（实参根单槽连续）
    ifc_ap_a := ts_ifc_apply_node("IfcBox", ifc_a_n)
    ifc_ap_b := ts_ifc_apply_node("IfcBox", ifc_b_n)
    // 序列节点：`[int; 3]` / `[int; 4]`
    ifc_seq3 := ts_ifc_seq_node(ifc_int_n, 3)
    ifc_seq4 := ts_ifc_seq_node(ifc_int_n, 4)
    // 接口：IfcI0 { m(x: IfcA) -> IfcB }（无接收者；参数/返回皆命名型）
    ifc_ii0 := ts_t5_mk_iface("IfcI0")
    ts_ifc_add_method_n(ifc_ii0, "m", 1, 0, ifc_a_n, -1, -1, -1, ifc_b_n)
    // 命中：同签名
    ifc_h_ti := ts_ifc_mk_named("IfcH")
    ts_ifc_add_impl(str_intern("IfcH"), "m", 1, 0, ifc_a_n, -1, ifc_b_n)
    // 参数类型不符（IfcB ← IfcA）
    ifc_p_ti := ts_ifc_mk_named("IfcP")
    ts_ifc_add_impl(str_intern("IfcP"), "m", 1, 0, ifc_b_n, -1, ifc_b_n)
    // 返回类型不符（int ← IfcB）
    ifc_r_ti := ts_ifc_mk_named("IfcR")
    ts_ifc_add_impl(str_intern("IfcR"), "m", 1, 0, ifc_a_n, -1, ifc_int_n)

    // 1 签名类型项化（参数）：命名参数型按类型判定，同型 1 / 异型 0
    fails = fails + ts_check("ifc.sig_named_param_bound",
        ts_isat_b2i(iface_satisfies(ifc_h_ti, str_intern("IfcI0")) == 1 &&
            iface_satisfies(ifc_p_ti, str_intern("IfcI0")) == 0), 1)
    // 2 签名类型项化（返回值）：命名返回型 vs 原生返回型 -> 0；同命名型 -> 1（编码闭合的直接判断）
    fails = fails + ts_check("ifc.sig_named_ret_bound",
        ts_isat_b2i(iface_satisfies(ifc_r_ti, str_intern("IfcI0")) == 0 &&
            iface_satisfies(ifc_h_ti, str_intern("IfcI0")) == 1), 1)
    // 3 泛型应用实参：`IfcBox[IfcA]` vs `IfcBox[IfcB]` -> 0；同实参 -> 1
    //  （应用记录裸码塌缩为 0 -> 不报错地判等；规范形展开基名 + 实参列表 -> 异实参异节点）
    ifc_ii1 := ts_t5_mk_iface("IfcI1")
    ts_ifc_add_method_n(ifc_ii1, "m", 1, 0, ifc_ap_a, -1, -1, -1, ifc_int_n)
    ifc_g_ti := ts_ifc_mk_named("IfcG")
    ts_ifc_add_impl(str_intern("IfcG"), "m", 1, 0, ifc_ap_a, -1, ifc_int_n)
    ifc_g2_ti := ts_ifc_mk_named("IfcG2")
    ts_ifc_add_impl(str_intern("IfcG2"), "m", 1, 0, ifc_ap_b, -1, ifc_int_n)
    fails = fails + ts_check("ifc.sig_apply_arg_bound",
        ts_isat_b2i(iface_satisfies(ifc_g_ti, str_intern("IfcI1")) == 1 &&
            iface_satisfies(ifc_g2_ti, str_intern("IfcI1")) == 0), 1)
    // 4 接收者模式是判定维度：iface `&self`（2）vs impl `self`（1）/`&mut self`（3）-> 0；同模式 -> 1
    ifc_ii2 := ts_t5_mk_iface("IfcI2")
    ts_ifc_add_method_n(ifc_ii2, "m", 1, 2, -1, -1, -1, -1, ifc_int_n)
    ifc_m1_ti := ts_ifc_mk_named("IfcM1")
    ts_ifc_add_impl(str_intern("IfcM1"), "m", 1, 1, -1, -1, ifc_int_n)
    ifc_m2_ti := ts_ifc_mk_named("IfcM2")
    ts_ifc_add_impl(str_intern("IfcM2"), "m", 1, 2, -1, -1, ifc_int_n)
    ifc_m3_ti := ts_ifc_mk_named("IfcM3")
    ts_ifc_add_impl(str_intern("IfcM3"), "m", 1, 3, -1, -1, ifc_int_n)
    fails = fails + ts_check("ifc.sig_receiver_mode",
        ts_isat_b2i(iface_satisfies(ifc_m2_ti, str_intern("IfcI2")) == 1 &&
            iface_satisfies(ifc_m1_ti, str_intern("IfcI2")) == 0 &&
            iface_satisfies(ifc_m3_ti, str_intern("IfcI2")) == 0), 1)
    // 5 元数（列表长度）：iface 1 参 vs impl 2 参 -> 0（序列结构不同）；impl 0 参 -> 0
    ifc_w_ti := ts_ifc_mk_named("IfcW")
    ts_ifc_add_impl(str_intern("IfcW"), "m", 2, 0, ifc_a_n, ifc_int_n, ifc_b_n)
    ifc_w0_ti := ts_ifc_mk_named("IfcW0")
    ts_ifc_add_impl(str_intern("IfcW0"), "m", 0, 0, -1, -1, ifc_b_n)
    fails = fails + ts_check("ifc.sig_arity_chain",
        ts_isat_b2i(iface_satisfies(ifc_w_ti, str_intern("IfcI0")) == 0 &&
            iface_satisfies(ifc_w0_ti, str_intern("IfcI0")) == 0), 1)
    // 6 N 不入签名身份：`[int;3]` vs `[int;4]` -> 1（长度约束由常量档承担）
    ifc_ii3 := ts_t5_mk_iface("IfcI3")
    ts_ifc_add_method_n(ifc_ii3, "m", 1, 0, ifc_seq3, -1, -1, -1, ifc_int_n)
    ifc_n_ti := ts_ifc_mk_named("IfcN")
    ts_ifc_add_impl(str_intern("IfcN"), "m", 1, 0, ifc_seq4, -1, ifc_int_n)
    fails = fails + ts_check("ifc.sig_len_not_in_identity",
        ts_isat_b2i(iface_satisfies(ifc_n_ti, str_intern("IfcI3")) == 1), 1)
    // 7 命名记录名义（不展开）：IfcA 与 IfcB 结构同构（皆零字段）但不可互换 -> 0
    //  （判定不落引擎的 AK_NAMED 展开，签名身份按行（同名字同行））
    fails = fails + ts_check("ifc.sig_named_nominal_not_structural",
        ts_isat_b2i(iface_satisfies(ifc_p_ti, str_intern("IfcI1")) == 0 &&
            iface_satisfies(ifc_g_ti, str_intern("IfcI1")) == 1), 1)
    // 8 接口形状项 = 方法集（product of fn）：成员数 = 方法数、成员 b 槽 = 方法名、
    //  列表长度 = 1 + 参数数；越界成员 -> -1
    ifc_ii4 := ts_t5_mk_iface("IfcI4")
    ts_ifc_add_method_n(ifc_ii4, "m", 1, 0, ifc_a_n, -1, -1, -1, ifc_b_n)
    ts_ifc_add_method_n(ifc_ii4, "n", 2, 0, ifc_a_n, ifc_int_n, -1, -1, ifc_int_n)
    ifc_shp := sh_iface_shape_term(str_intern("IfcI4"))
    ifc_m0 := sh_shape_member_at(ifc_shp, 0)
    ifc_m1 := sh_shape_member_at(ifc_shp, 1)
    ifc_chain_ok : ., mut = 0
    if ifc_m0 >= 0 && ifc_m1 >= 0:
        c0 := tt_c(ifc_m0)
        c1 := tt_c(ifc_m1)
        // 列表长度（1 + pc）：cons(ret, cons(p…)) -> 2 元列表（pc=1）/ 3 元列表（pc=2）
        if tt_tag(c0) == TT_CONS && tt_tag(tt_b(c0)) == TT_CONS && tt_tag(tt_b(tt_b(c0))) == TT_NIL:
            if tt_tag(c1) == TT_CONS && tt_tag(tt_b(c1)) == TT_CONS:
                if tt_tag(tt_b(tt_b(c1))) == TT_CONS && tt_tag(tt_b(tt_b(tt_b(c1)))) == TT_NIL:
                    ifc_chain_ok = 1
    fails = fails + ts_check("ifc.shape_product_of_fn",
        ts_isat_b2i(ifc_shp >= 0 && tt_tag(ifc_shp) == TT_ATOM && tt_a(ifc_shp) == AK_PRODUCT &&
            ifc_m0 >= 0 && tt_tag(ifc_m0) == TT_ATOM && tt_a(ifc_m0) == AK_FN &&
            tt_b(ifc_m0) == str_intern("m") && tt_b(ifc_m1) == str_intern("n") &&
            ifc_chain_ok == 1 && sh_shape_member_at(ifc_shp, 2) == -1 &&
            sh_shape_member_at(ifc_shp, -1) == -1), 1)
    // 9. 形状项不可建：参数数 9 超过 MAX_IFACE_METHOD_PARAMS，返回 -1；
    // 未声明接口名也返回 -1。
    ifc_ii5 := ts_t5_mk_iface("IfcI5")
    ts_ifc_add_method_n(ifc_ii5, "m", 9, 0, -1, -1, -1, -1, ifc_int_n)
    fails = fails + ts_check("ifc.shape_build_unjudged",
        ts_isat_b2i(sh_iface_shape_term(str_intern("IfcI5")) == -1 &&
            sh_iface_shape_term(str_intern("IfcNope")) == -1 &&
            iface_satisfies(ifc_h_ti, str_intern("IfcI5")) == -1), 1)
    // 10. 方法查找路径不调用 str_intern：缺失方法返回 0，旧
    // type_has_method 的 str_intern("T.m") 写法会增长表。
    ifc_zz_ti := ts_ifc_mk_named("IfcZz")
    ifc_strs := g_str_count
    ifc_p1 := iface_satisfies(ifc_zz_ti, str_intern("IfcI0"))
    ifc_p2 := type_has_method(str_intern("IfcZz"), str_intern("m"))
    fails = fails + ts_check("ifc.mangling_zero_str_intern",
        ts_isat_b2i(ifc_p1 == 0 && ifc_p2 == false && g_str_count == ifc_strs), 1)
    // 11. 方法解析是表查询：type_has_method 为真当且仅当 iface_find_method >= 0。
    fails = fails + ts_check("ifc.type_has_method_table",
        ts_isat_b2i(type_has_method(str_intern("IfcH"), str_intern("m")) == true &&
            type_has_method(str_intern("IfcZz"), str_intern("m")) == false &&
            iface_find_method(str_intern("IfcH"), str_intern("m")) >= 0 &&
            iface_find_method(str_intern("IfcZz"), str_intern("m")) < 0), 1)
    // 12. 与 check_iface 同源：三种形态逐例相等。
    ifc_eq : ., mut = 0
    if ts_isat_b2i(check_iface(str_intern("IfcH"), ifc_ii0)) == iface_satisfies(ifc_h_ti, str_intern("IfcI0")):
        if ts_isat_b2i(check_iface(str_intern("IfcP"), ifc_ii0)) == iface_satisfies(ifc_p_ti, str_intern("IfcI0")):
            if ts_isat_b2i(check_iface(str_intern("IfcR"), ifc_ii0)) == iface_satisfies(ifc_r_ti, str_intern("IfcI0")):
                ifc_eq = 1
    fails = fails + ts_check("ifc.check_iface_same_source", ifc_eq, 1)
    // 13. 域限定和不可判：非命名记录（原生、泛型形参、dyn）返回 -1；
    // 零方法接口加命名记录返回 1；未知接口名返回 -1。
    ifc_gp_ti := alloc_type(TYP_GENERIC_PARAM, str_intern("IfcU"), 0)
    ifc_dyn_ti := alloc_type(TYP_DYN, 0, 0)
    ifc_ii6 := ts_t5_mk_iface("IfcI6")
    fails = fails + ts_check("ifc.three_state_unjudged",
        ts_isat_b2i(iface_satisfies(TI_INT, str_intern("IfcI0")) == -1 &&
            iface_satisfies(ifc_gp_ti, str_intern("IfcI0")) == -1 &&
            iface_satisfies(ifc_dyn_ti, str_intern("IfcI0")) == -1 &&
            iface_satisfies(ifc_h_ti, str_intern("IfcI6")) == 1 &&
            iface_satisfies(ifc_h_ti, str_intern("IfcNope")) == -1 &&
            iface_satisfies(-1, str_intern("IfcI0")) == -1), 1)
    // 14. 空 product 的形状数据：零方法接口的形状项列表为空，成员查询
    // 返回 -1。
    ifc_shp6 := sh_iface_shape_term(str_intern("IfcI6"))
    fails = fails + ts_check("ifc.shape_empty_product",
        ts_isat_b2i(ifc_shp6 >= 0 && tt_tag(ifc_shp6) == TT_ATOM && tt_a(ifc_shp6) == AK_PRODUCT &&
            tt_c(ifc_shp6) >= 0 && tt_tag(tt_c(ifc_shp6)) == TT_NIL &&
            sh_shape_member_at(ifc_shp6, 0) == -1 && ifc_a_ti >= 0), 1)
    return fails

// === 命名类型处理：身份令牌序列和可判定部分 ===
// Behavioral and structural checks; source-level checks are in
// tests/selfhost/test_named_face.py.
// 1. 序列结构：两个构造点逐位同构。NAMED 和 PARAM 是 [名字令牌]；
//    APPLY 是 [基名令牌, 实参项...]。
// 2. 序列相同返回 1，序列不同返回 0；覆盖同名和异名命名、同实参和异实参
//    泛型应用、嵌套应用。
// 3. 命名类型和原生类型混类返回 0。
// 4. 域外输入返回 -1：空序列、令牌位错位、实参位 μ 变元、NEVER 和 DYN
//    混类。不得近似成 0 或 1。
// 5. 命名类型经 type_equal 由引擎直接判定，不产生 ICE04。
// 6. 残留情形：参数列表不变槽的元素类型不同（[NA;2] vs [NB;2]），由
//    te_elem_cmp 处理，断言在 ts_t3b_run。
// 夹具是人造记录，不登记到生产名字表，只服务本段断言。
fn ts_t3n_run() -> int:
    fails : ., mut = 0
    ty_budget_reset(200000)
    n_a := alloc_named_type(str_intern("T3NA"))
    n_b := alloc_named_type(str_intern("T3NB"))
    na_ni := get_type_data(n_a)
    ta := sh_term_of_ti(n_a)
    tb := sh_term_of_ti(n_b)
    // 1. 序列结构：b 槽是记录编号，供 atom_of 使用；c = [令牌(name_ni)]。
    fails = fails + ts_check_b("t3n.chain_shape",
        (ta >= 0 && tt_a(ta) == AK_NAMED && tt_b(ta) == n_a &&
            tt_c(ta) >= 0 && tt_tag(tt_c(ta)) == TT_CONS &&
            tt_a(tt_c(ta)) == sh_name_token(na_ni) &&
            tt_b(tt_c(ta)) >= 0 && tt_tag(tt_b(tt_c(ta))) == TT_NIL), true)
    // atom_of 仍读 b：命名记录返回本条记录，应用记录返回基型记录。
    // 2 同名 -> 同行（named_dedup）-> 同节点 -> 等价 1；异名 -> 0（双向）
    n_a2 := alloc_named_type(str_intern("T3NA"))
    fails = fails + ts_check_b("t3n.same_name_same_row",
        (n_a2 == n_a && sh_term_of_ti(n_a2) == ta && ty_equiv(ta, sh_term_of_ti(n_a2)) == 1), true)
    fails = fails + ts_check_b("t3n.diff_name_diff",
        (ty_sub(ta, tb) == 0 && ty_sub(tb, ta) == 0 && ty_equiv(ta, tb) == 0), true)
    // 3 混类：命名 × 原生 -> 0（名义型与异类原子不交）
    fails = fails + ts_check_b("t3n.named_vs_base_zero",
        (ty_equiv(ta, sh_term_of_ti(TI_INT)) == 0 && ty_equiv(ta, sh_term_of_ti(TI_STR)) == 0 &&
            ty_equiv(sh_term_of_ti(TI_STR), ta) == 0), true)
    // 4 域外：NEVER/DYN 混类 -> -1 + 未覆盖情形位置位（⊥/⊤ 语义未建模，登记）
    ty_budget_reset(200000)
    dn := ty_equiv(ta, sh_term_of_ti(TI_NEVER))
    unc1 := ty_uncovered()
    ty_budget_reset(200000)
    dd := ty_equiv(ta, sh_term_of_ti(TI_DYN))
    unc2 := ty_uncovered()
    fails = fails + ts_check_b("t3n.never_dyn_out_of_domain",
        (dn == -1 && dd == -1 && unc1 == 1 && unc2 == 1), true)
    // 4 域外：空序列（无身份 = 未覆盖情形2原形态）-> -1
    ty_budget_reset(200000)
    dnc := ty_equiv(tt_atom(AK_NAMED, -1, -1), ta)
    fails = fails + ts_check_b("t3n.no_chain_out_of_domain", (dnc == -1 && ty_uncovered() == 1), true)
    // 4 域外：令牌位放类型项 -> -1（位置错位不猜）
    ty_budget_reset(200000)
    mis1 := ty_equiv(tt_atom(AK_NAMED, -1, tt_cons(tt_atom(AK_INT, TI_INT, -1), tt_nil())), ta)
    fails = fails + ts_check_b("t3n.token_pos_mismatch_out", (mis1 == -1 && ty_uncovered() == 1), true)
    // 4 域外：实参位 μ 变元 -> -1（实参位只收类型项；令牌位同节点 -> 比较推进到实参位）
    bad_arg := tt_atom(AK_NAMED, n_a, tt_cons(sh_name_token(na_ni), tt_cons(tt_var(0), tt_nil())))
    good_arg := tt_atom(AK_NAMED, n_a, tt_cons(sh_name_token(na_ni), tt_cons(sh_term_of_ti(TI_INT), tt_nil())))
    ty_budget_reset(200000)
    mis2 := ty_equiv(bad_arg, good_arg)
    fails = fails + ts_check_b("t3n.arg_var_out_of_domain", (mis2 == -1 && ty_uncovered() == 1), true)
    // 5. 命名类型经 type_equal 由引擎直接判定，不产生 ICE04。
    t3n_d0 := g_diag_count
    eqf : ., mut = 0
    if !type_equal(n_a, n_b):
        if g_diag_count == t3n_d0:
            eqf = 1
    fails = fails + ts_check_b("t3n.decided_no_indeterminate", (eqf == 1 && ty_sub(ta, tb) == 0), true)
    // 2 泛型应用：规范形 b = 基型记录 + 序列 [基名令牌, 实参项…]
    grow_gen_apply_data(g_gen_apply_data_count + 2)
    gs1 := g_gen_apply_data_count
    cell_store(g_gen_apply_data, gs1 * 8, 1)
    cell_store(g_gen_apply_data, (gs1 + 1) * 8, TI_INT)
    g_gen_apply_data_count = gs1 + 2
    ga1 := alloc_type(TYP_GENERIC_APPLY, n_a, gs1)
    ga2 := alloc_type(TYP_GENERIC_APPLY, n_a, gs1)      // 另一行，同基型同实参
    grow_gen_apply_data(g_gen_apply_data_count + 2)
    gs2 := g_gen_apply_data_count
    cell_store(g_gen_apply_data, gs2 * 8, 1)
    cell_store(g_gen_apply_data, (gs2 + 1) * 8, TI_STR)
    g_gen_apply_data_count = gs2 + 2
    ga3 := alloc_type(TYP_GENERIC_APPLY, n_a, gs2)      // 同基型异实参
    t_ga1 := sh_term_of_ti(ga1)
    t_ga2 := sh_term_of_ti(ga2)
    t_ga3 := sh_term_of_ti(ga3)
    fails = fails + ts_check_b("t3n.apply_canonical_b",
        (t_ga1 >= 0 && tt_a(t_ga1) == AK_NAMED && tt_b(t_ga1) == n_a &&
            tt_atom_of_term(t_ga1) == n_a &&
            tt_c(t_ga1) >= 0 && tt_tag(tt_c(t_ga1)) == TT_CONS &&
            tt_a(tt_c(t_ga1)) == sh_name_token(na_ni) &&
            tt_a(tt_b(tt_c(t_ga1))) == sh_term_of_ti(TI_INT)), true)
    fails = fails + ts_check_b("t3n.apply_two_rows_same_args",
        (ga1 != ga2 && t_ga1 == t_ga2 && ty_equiv(t_ga1, t_ga2) == 1), true)
    fails = fails + ts_check_b("t3n.apply_diff_args_zero",
        (ty_sub(t_ga1, t_ga3) == 0 && ty_sub(t_ga3, t_ga1) == 0), true)
    fails = fails + ts_check_b("t3n.apply_vs_bare_diff",
        (ty_sub(t_ga1, ta) == 0 && ty_sub(ta, t_ga1) == 0), true)
    // Both construction points are structurally identical: the same type in two
    // constructions yields the same node.
    fails = fails + ts_check_b("t3n.two_points_isomorphic",
        (sh_sig_term_of_ti(n_a) == ta && sh_sig_term_of_ti(ga1) == t_ga1), true)
    // 2 嵌套应用：Box[Box[int]] 两处（外层实参分别指向同实参的不同行）-> 同节点
    grow_gen_apply_data(g_gen_apply_data_count + 2)
    gs3 := g_gen_apply_data_count
    cell_store(g_gen_apply_data, gs3 * 8, 1)
    cell_store(g_gen_apply_data, (gs3 + 1) * 8, ga1)
    g_gen_apply_data_count = gs3 + 2
    ga4 := alloc_type(TYP_GENERIC_APPLY, n_a, gs3)
    grow_gen_apply_data(g_gen_apply_data_count + 2)
    gs4 := g_gen_apply_data_count
    cell_store(g_gen_apply_data, gs4 * 8, 1)
    cell_store(g_gen_apply_data, (gs4 + 1) * 8, ga2)
    g_gen_apply_data_count = gs4 + 2
    ga5 := alloc_type(TYP_GENERIC_APPLY, n_a, gs4)
    fails = fails + ts_check_b("t3n.nested_apply_same",
        (ga4 != ga5 && sh_term_of_ti(ga4) == sh_term_of_ti(ga5)), true)
    // 2 可选类型（union）：NA ⊂ NA?（注入）-> 1；NA? vs NB?（内层异名）-> 0
    opt_a := tt_union(ta, sh_null_term())
    opt_b := tt_union(tb, sh_null_term())
    fails = fails + ts_check_b("t3n.optional_named",
        (ty_sub(ta, opt_a) == 1 && ty_sub(opt_a, opt_b) == 0), true)
    // 域外：union 含无身份序列的命名原子，仍返回 -1。加强判定不得把
    // 未规范化或域外的并集误判成 0。
    ty_budget_reset(200000)
    u_out := ty_equiv(tt_union(tt_atom(AK_NAMED, -1, -1), sh_null_term()),
        tt_union(tt_atom(AK_NAMED, -2, -1), sh_null_term()))
    fails = fails + ts_check_b("t3n.union_out_of_domain", (u_out == -1 && ty_uncovered() == 1), true)
    // 不变槽元素由 te_elem_cmp 判定，断言见
    // t3b.inv_slot_seq_named_diff_zero。本段不再断言 -1。
    // 对照：同元素但不同记录返回 1。N 不属于身份，序列比较走快路径。
    arr_a := sh_seq_term(n_a, 2)
    arr_a2 := sh_seq_term(n_a, 2)
    fails = fails + ts_check("t3n.same_elem_seq_equiv", ty_equiv(arr_a, arr_a2), 1)
    return fails

// === 不变槽元素判定（te_elem_cmp）用例 ===
// 检查：
// 1. 主形态：序列、指针、元组和嵌套结构的不变槽元素是不同命名原子，
//    引擎双向直接判 0，不置未实现位。
// 2. 不误伤等价判定：同元素但不同记录、N 长度约束（[T;2] vs [T;3]）、
//    同令牌都返回 1。
// 3. 令牌位：AK_SUM 序列槽 0 和 1 是枚举名和变体名令牌，按节点同一性
//    比较；异名返回 0，同名返回 1。
// 4. 域外检查：序列元素既不是令牌也不是类型项（μ 变元），返回 -1 并
//    置未实现位，不得近似成 0。
// 5. 反例：同名令牌是同一节点，DAG 去重保证不存在同名不同节点；令牌
//    与原生 unit 项同形时，ty_equiv 判等，但 te_elem_cmp 先判令牌，
//    返回 0，不会产生错误等价。
// 6. 数组记录经 type_equal 由引擎直接判定，不产生 ICE04。
// 夹具是人造记录（alloc_named_type/alloc_type），同名记录去重，不登记到
// 生产名字表。
fn ts_t3b_run() -> int:
    fails : ., mut = 0
    ty_budget_reset(200000)
    n_a := alloc_named_type(str_intern("T3NA"))
    n_b := alloc_named_type(str_intern("T3NB"))
    t_a := sh_term_of_ti(n_a)
    t_b := sh_term_of_ti(n_b)
    t_int := sh_term_of_ti(TI_INT)
    // 1 序列元素（AK_SEQUENCE 序列槽位 0）：异名 -> 0 双向 + 零未覆盖情形
    arr_a := alloc_type(TYP_ARRAY, n_a, 2)
    arr_b := alloc_type(TYP_ARRAY, n_b, 2)
    ty_budget_reset(200000)
    ab := ty_sub(sh_term_of_ti(arr_a), sh_term_of_ti(arr_b))
    ba := ty_sub(sh_term_of_ti(arr_b), sh_term_of_ti(arr_a))
    fails = fails + ts_check("t3b.inv_slot_seq_named_diff_zero",
        ts_isat_b2i(ab == 0 && ba == 0 && ty_uncovered() == 0), 1)
    // 1 指针元素（AK_PTR 序列槽位 0）-> 0
    ty_budget_reset(200000)
    pb := ty_sub(tt_atom(AK_PTR, -1, tt_cons(t_a, tt_nil())),
        tt_atom(AK_PTR, -1, tt_cons(t_b, tt_nil())))
    fails = fails + ts_check("t3b.inv_slot_ptr_named_diff_zero",
        ts_isat_b2i(pb == 0 && ty_uncovered() == 0), 1)
    // 1 元组字段位（AK_PRODUCT 序列；第 2 字段同项 = 对照组）-> 0
    ty_budget_reset(200000)
    pr := ty_sub(tt_atom(AK_PRODUCT, -1, tt_cons(t_a, tt_cons(t_int, tt_nil()))),
        tt_atom(AK_PRODUCT, -1, tt_cons(t_b, tt_cons(t_int, tt_nil()))))
    fails = fails + ts_check("t3b.inv_slot_prod_named_diff_zero",
        ts_isat_b2i(pr == 0 && ty_uncovered() == 0), 1)
    // 1 嵌套（元素 = 序列项 -> 经 te_elem_cmp 的类型项递归）：[[NA;2];2] vs [[NB;2];2] -> 0
    nest_a := alloc_type(TYP_ARRAY, alloc_type(TYP_ARRAY, n_a, 2), 2)
    nest_b := alloc_type(TYP_ARRAY, alloc_type(TYP_ARRAY, n_b, 2), 2)
    ty_budget_reset(200000)
    ns := ty_sub(sh_term_of_ti(nest_a), sh_term_of_ti(nest_b))
    fails = fails + ts_check("t3b.inv_slot_nested_seq_diff_zero",
        ts_isat_b2i(ns == 0 && ty_uncovered() == 0), 1)
    // 2 等价判定不被压成 0：N 长度约束（[NA;2] vs [NA;3] -> 1）+ 同元素另一行 -> 1
    ty_budget_reset(200000)
    n_eq := ty_equiv(sh_term_of_ti(arr_a), sh_term_of_ti(alloc_type(TYP_ARRAY, n_a, 3)))
    r_eq := ty_equiv(sh_term_of_ti(arr_a), sh_term_of_ti(alloc_type(TYP_ARRAY, n_a, 2)))
    fails = fails + ts_check("t3b.equiv_face_not_crushed",
        ts_isat_b2i(n_eq == 1 && r_eq == 1 && ty_uncovered() == 0), 1)
    // 3 令牌位：AK_SUM 序列 = [枚举名令牌, 变体名令牌]（皆不变槽），异变体名 -> 0
    e1 := str_intern("T3bE1")
    v1 := str_intern("T3bV1")
    v2 := str_intern("T3bV2")
    sum_v1 := tt_atom(AK_SUM, -1, tt_cons(sh_name_token(e1), tt_cons(sh_name_token(v1), tt_nil())))
    sum_v2 := tt_atom(AK_SUM, -1, tt_cons(sh_name_token(e1), tt_cons(sh_name_token(v2), tt_nil())))
    ty_budget_reset(200000)
    sv := ty_sub(sum_v1, sum_v2)
    fails = fails + ts_check("t3b.token_slot_variant_diff_zero",
        ts_isat_b2i(sv == 0 && ty_uncovered() == 0), 1)
    // 3 同令牌 -> 同节点 -> 1（同枚举同变体两处构造）
    sum_v1x := tt_atom(AK_SUM, -1, tt_cons(sh_name_token(e1), tt_cons(sh_name_token(v1), tt_nil())))
    fails = fails + ts_check("t3b.token_slot_same_one",
        ts_isat_b2i(sum_v1 == sum_v1x && ty_equiv(sum_v1, sum_v1x) == 1), 1)
    // 5(a) 负控：同名令牌 -> 同一节点（DAG 去重），同名不同节点结构上不可达；
    // mut 标记同式（同值同节点、异值异节点）
    fails = fails + ts_check("t3b.token_same_name_same_node",
        ts_isat_b2i(sh_name_token(e1) == sh_name_token(e1) &&
            sh_name_token(e1) != sh_name_token(v1) &&
            sh_ref_mut_marker(0) == sh_ref_mut_marker(0) &&
            sh_ref_mut_marker(0) != sh_ref_mut_marker(1)), 1)
    // 5(b) 负控：令牌 × 原生 unit 项同形 -> ty_equiv 判等（碰撞实证）；
    // te_elem_cmp 令牌先判 -> 0（无假等）；unit × unit -> 同节点 -> 1
    u_item := sh_term_of_ti(TI_UNIT)
    tok_e1 := sh_name_token(e1)
    ty_budget_reset(200000)
    coll := ty_equiv(u_item, tok_e1)
    fails = fails + ts_check("t3b.unit_token_shape_collision_guard",
        ts_isat_b2i(coll == 1 && te_elem_cmp(u_item, tok_e1) == 0 &&
            te_elem_cmp(u_item, u_item) == 1), 1)
    // 5b. unit 项在非令牌元素位置按类型项比较：[unit] vs [int] 返回 0；
    // [unit] vs [unit] 长度不同返回 1。
    ty_budget_reset(200000)
    u_i := ty_sub(sh_seq_term(TI_UNIT, 2), sh_seq_term(TI_INT, 2))
    u_u := ty_equiv(sh_seq_term(TI_UNIT, 2), sh_seq_term(TI_UNIT, 3))
    fails = fails + ts_check("t3b.unit_elem_type_item_face",
        ts_isat_b2i(u_i == 0 && u_u == 1 && ty_uncovered() == 0), 1)
    // 4. 域外检查：序列元素既不是令牌也不是类型项（μ 变元），返回 -1 并置未实现位。
    ty_budget_reset(200000)
    dom := ty_sub(tt_atom(AK_SEQUENCE, -1, tt_cons(tt_var(0), tt_nil())),
        tt_atom(AK_SEQUENCE, -1, tt_cons(t_int, tt_nil())))
    fails = fails + ts_check("t3b.elem_out_of_domain_stays_minus1",
        ts_isat_b2i(dom == -1 && ty_uncovered() == 1), 1)
    // 2. 只读 ref 的协变槽和 mut 标记槽：&NA vs &NB 返回 0；& 和 &mut 返回 0。
    ref_a := tt_atom(AK_REF, -1, tt_cons(sh_ref_mut_marker(0), tt_cons(t_a, tt_nil())))
    ref_b := tt_atom(AK_REF, -1, tt_cons(sh_ref_mut_marker(0), tt_cons(t_b, tt_nil())))
    ref_m := tt_atom(AK_REF, -1, tt_cons(sh_ref_mut_marker(1), tt_cons(t_a, tt_nil())))
    ty_budget_reset(200000)
    rb := ty_sub(ref_a, ref_b)
    rm := ty_sub(ref_a, ref_m)
    fails = fails + ts_check("t3b.ref_elem_and_marker",
        ts_isat_b2i(rb == 0 && rm == 0 && ty_uncovered() == 0), 1)
    // 6. 数组记录经 type_equal 由引擎直接判定，不产生 ICE04。
    t3b_d0 := g_diag_count
    dec : ., mut = 0
    if !type_equal(arr_a, arr_b):
        if g_diag_count == t3b_d0:
            dec = 1
    fails = fails + ts_check("t3b.decided_no_indeterminate_arr", dec, 1)
    return fails

// === 残留 -1 处理：ICE04 编译失败 ===
// 检查：
// 1. 桥接缺口：记录编号越界，无法翻译成类型项。type_equal 返回 false，
//    并产生恰好一条 ICE04。
// 2. 引擎返回 -1：未实现情形，例如命名原子身份令牌序列与 NEVER 原子混类。
//    返回 false 并产生 ICE04；措辞必须与桥接缺口不同。
// 3. 零误报：引擎直接判定的 0/1 和同一记录快路径都不产生 ICE04。
// 诊断是故意触发的，本段结束时复位 g_diag_count。
fn ts_t4_run() -> int:
    fails : ., mut = 0
    // 1. 桥接缺口：ti 越界，没有类型项。
    t4_d0 := g_diag_count
    t4_b1 : ., mut = 0
    if !type_equal(g_type_count + 100, TI_INT):
        t4_b1 = 1
    t4_d1 := g_diag_count
    t4_m_bridge := ts_diag_msg_at(t4_d0)
    fails = fails + ts_check_b("t4.ice04_bridge_gap_hard_error",
        (t4_b1 == 1 && t4_d1 == t4_d0 + 1 && ts_diag_code_at(t4_d0) == EC_ICE_TY_INDET &&
            str_len(t4_m_bridge) > 0), true)
    // 2. 引擎返回 -1：命名原子和 NEVER 原子混类，te_named_pair 的
    // NEVER/DYN 检查返回 -1 并置未实现位。桥接能翻译两条记录，但引擎
    // 判不了，这是与桥接缺口不同的出口。
    // 反例：AK_NEVER × AK_DYN 是已判情形，返回 0，不产生 -1。
    t4_na := alloc_named_type(str_intern("T4IndetNamed"))
    t4_d2 := g_diag_count
    t4_b2 : ., mut = 0
    if !type_equal(t4_na, TI_NEVER):
        t4_b2 = 1
    t4_d3 := g_diag_count
    t4_m_engine := ts_diag_msg_at(t4_d2)
    fails = fails + ts_check_b("t4.ice04_engine_uncovered_hard_error",
        (t4_b2 == 1 && t4_d3 == t4_d2 + 1 && ts_diag_code_at(t4_d2) == EC_ICE_TY_INDET &&
            str_len(t4_m_engine) > 0 && str_eq(t4_m_bridge, t4_m_engine) == 0), true)
    // 3. 零误报：引擎直接判 0 和同一记录快路径都不产生诊断。
    t4_d4 := g_diag_count
    t4_ok : ., mut = 0
    if !type_equal(TI_INT, TI_STR):
        // 引擎自决 0
        if type_equal(TI_INT, TI_INT):
            // 同一行快路径（自反）
            if g_diag_count == t4_d4:
                t4_ok = 1
    fails = fails + ts_check("t4.ice04_decided_no_false_positive", t4_ok, 1)
    g_diag_count = t4_d4    // 复位本段故意触发的诊断计数。
    return fails

// === TYPE 段：装填、序列化、去重、确定性 ===
// 用例：
// 1. 段缓冲和内存表逐字段往返：记录表每条 24 字节，项表每条 40 字节，
//    长度公式一致。
// 2. 去重重建：同构项得到同一节点；b 标注区分固定长度；DAG 不产生相同
//    (tag,a..d) 的重复项。
// 3. 确定性：判定历史会向项表追加规范化项；重新装填后段体逐字节相同。
// 4. 不可译记录：装填拒绝，保存侧不写入文件。
// 夹具自建干净类型表：init_types 的 9 个原生记录，加 4 条可选和定长数组
// 记录。不经过 parser 或 check_all。必须最后运行，因为 populate 会复位项层、
// 引擎和桥接缓存。
fn ts_ccr_roundtrip_ok() -> int:
    rc := g_type_count
    tc := tt_count()
    if g_ccr_type_seg_len != 4 + rc * ESZ_TYPE_ROW + 4 + tc * ESZ_TYPE_TERM_DISK:
        return 0
    if buf_read_u32(g_ccr_type_seg, 0) != rc:
        return 0
    pos : ., mut = 4
    i : ., mut = 0
    loop:
        if i >= rc:
            break
        if buf_read_i64(g_ccr_type_seg, pos) != cell_load(g_types, i * ESZ_TYPE_ROW + OFF_TR_KIND):
            return 0
        if buf_read_i64(g_ccr_type_seg, pos + 8) != cell_load(g_types, i * ESZ_TYPE_ROW + OFF_TR_DATA):
            return 0
        if buf_read_i64(g_ccr_type_seg, pos + 16) != cell_load(g_types, i * ESZ_TYPE_ROW + OFF_TR_EXTRA):
            return 0
        pos = pos + ESZ_TYPE_ROW
        i = i + 1
    if buf_read_u32(g_ccr_type_seg, pos) != tc:
        return 0
    pos = pos + 4
    j : ., mut = 0
    loop:
        if j >= tc:
            break
        if buf_read_i64(g_ccr_type_seg, pos) != tt_tag(j):
            return 0
        if buf_read_i64(g_ccr_type_seg, pos + 8) != tt_a(j):
            return 0
        if buf_read_i64(g_ccr_type_seg, pos + 16) != tt_b(j):
            return 0
        if buf_read_i64(g_ccr_type_seg, pos + 24) != tt_c(j):
            return 0
        if buf_read_i64(g_ccr_type_seg, pos + 32) != tt_d(j):
            return 0
        pos = pos + ESZ_TYPE_TERM_DISK
        j = j + 1
    if pos != g_ccr_type_seg_len:
        return 0
    return 1

fn ts_ccr_dedup_ok(opt_a: int, opt_b: int, arr3: int, arr4: int) -> int:
    // 同构 -> 同节点（两个 `int?` 行 -> 同一 union 项）；b 标注（固定长度）区分 -> 异节点
    if sh_term_of_ti(opt_a) != sh_term_of_ti(opt_b):
        return 0
    if sh_term_of_ti(arr3) == sh_term_of_ti(arr4):
        return 0
    // DAG 不变量：项表中不存在两个 tag 和 a..d 都相同的项。tt_term 负责去重，这段直接检查重建结果。
    n := tt_count()
    i : ., mut = 0
    loop:
        if i >= n:
            break
        j : ., mut = i + 1
        loop:
            if j >= n:
                break
            if tt_tag(i) == tt_tag(j) && tt_a(i) == tt_a(j) && tt_b(i) == tt_b(j) && tt_c(i) == tt_c(j) && tt_d(i) == tt_d(j):
                return 0
            j = j + 1
        i = i + 1
    return 1

fn ts_ccr_purity_ok() -> int:
    n0 := g_ccr_type_seg_len
    cp := alloc(n0 + 8)
    cell_copy(g_ccr_type_seg, n0, cp)
    // IFACE 段也纳入。类型表和接口表的装填都是纯函数。
    i0 := g_ccr_iface_seg_len
    ip := alloc(i0 + 8)
    cell_copy(g_ccr_iface_seg, i0, ip)
    // 判定历史扰动：跨项判定 + 规范化（向项表追加新项，旧直接序列化活表必在此变）
    pa := tt_atom(AK_INT, TI_INT, -1)
    pb := tt_atom(AK_STRING, TI_STR, -1)
    if ty_sub(tt_union(pa, pb), pa) != 0:
        println("ct.seg_determinism: perturbation ty_sub != 0")
        return 0
    if ty_disjoint(pa, pb) != 1:
        println("ct.seg_determinism: perturbation ty_disjoint != 1")
        return 0
    if ty_equiv(tt_union(pa, tt_union(pb, pa)), tt_union(pa, pb)) != 1:
        println("ct.seg_determinism: perturbation ty_equiv != 1")
        return 0
    // 构造唯一的标注项，确保判定扰动会向项表追加新项。若扰动与已有项
    // 同构，新增数为零，测试会失去效果。
    uq := tt_atom(AK_DEX, 900001, tt_cons(pa, tt_nil()))
    if tt_tag(uq) != TT_ATOM || tt_b(uq) != 900001:
        println("ct.seg_determinism: unique-term fixture failed")
        return 0
    // 重装填（项层/引擎/桥接复位 -> 记录顺序重建）-> 段体逐字节同
    if ccr_seg_prepare_save() != 0:
        println("ct.seg_determinism: rebuild prepare failed")
        return 0
    if g_ccr_type_seg_len != n0:
        print("ct.seg_determinism: buffer length changed ")
        print(int_str(n0))
        print(" -> ")
        println(int_str(g_ccr_type_seg_len))
        return 0
    k : ., mut = 0
    loop:
        if k >= n0:
            break
        if cell_load_byte(g_ccr_type_seg, k) != cell_load_byte(cp, k):
            print("ct.seg_determinism: buffer byte mismatch at ")
            println(int_str(k))
            return 0
        k = k + 1
    // IFACE 段同判（重装填后逐字节同（形状重注册/签名装填皆纯函数）
    if g_ccr_iface_seg_len != i0:
        print("ct.seg_determinism: iface buffer length changed ")
        print(int_str(i0))
        print(" -> ")
        println(int_str(g_ccr_iface_seg_len))
        return 0
    k2 : ., mut = 0
    loop:
        if k2 >= i0:
            break
        if cell_load_byte(g_ccr_iface_seg, k2) != cell_load_byte(ip, k2):
            print("ct.seg_determinism: iface buffer byte mismatch at ")
            println(int_str(k2))
            return 0
        k2 = k2 + 1
    return 1

fn ts_ccr_run() -> int:
    fails : ., mut = 0
    init_types()   // 干净表（9 原生行，不受前段夹具影响）
    // 接口表同阶段清零（段体含 IFACE 五小节 -> 上游 ifc/isat 夹具的死节点
    // （EXPR_IDENT 指向已被 init_types 作废的命名记录 -> res_type_node 落 dyn 行）会令签名项
    // 不可建 -> 装填拒绝。本组语义 = 干净类型表 + 干净接口表的段体往返夹具。
    g_iface_count = 0
    g_impl_for_count = 0
    g_method_count = 0
    iface_shape_reset()
    iface_shape_builtin_init()
    opt_a := alloc_type(TYP_OPTIONAL, TI_INT, 0)
    opt_b := alloc_type(TYP_OPTIONAL, TI_INT, 0)
    arr3 := alloc_type(TYP_ARRAY, TI_INT, 3)
    arr4 := alloc_type(TYP_ARRAY, TI_INT, 4)
    prep := ccr_seg_prepare_save()
    fails = fails + ts_check("ct.seg_prepare", prep, 0)
    if prep == 0:
        fails = fails + ts_check("ct.seg_roundtrip", ts_ccr_roundtrip_ok(), 1)
        fails = fails + ts_check("ct.seg_dedup_identity", ts_ccr_dedup_ok(opt_a, opt_b, arr3, arr4), 1)
        fails = fails + ts_check("ct.seg_determinism", ts_ccr_purity_ok(), 1)
    else:
        fails = fails + 3   // 后续三例无法运行 -> 计失败（不得漏算且不报错）
    // 4 不可译行（子行越界）-> 装填拒绝（save 拒落盘），最后（使类型表失效）
    bad_row := alloc_type(TYP_ARRAY, 999999, 0)
    rej : ., mut = ccr_type_populate()
    if bad_row < 0:
        rej = 1
    // 夹具未建成 -> 不算通过（防假通过）
    fails = fails + ts_check("ct.seg_reject_untranslatable", rej, -1)
    return fails

// === IFACE 段：扩列、命名化、签名项、段体往返 ===
// 用例：
// 1. 段体五个小节与内存表逐字段一致，行走结束位置等于缓冲长度，没有尾随数据。
// 2. 签名项槽 ret_term 和 param_terms 等于实时计算值，装填和签名来源不漂移；
//    未使用槽为 -1。
// 3. 形状名生产注册表：六个名字可按名查询，且与 sh_shape_* 构造项相同。
// 4. 条目表扩列：16 条记录，加 3 条新记录 ops = 0，并且逐名可读。
// 5. 判定逻辑零变化：枚举全部类型表记录，没有新映射；TYP_NULL 和
//    TYP_OPTIONAL 记录仍返回 -1。
// 6. 不可建签名（dyn 位图记录进入签名）导致装填拒绝，保存侧不写入文件。
// 夹具：本组自建干净接口表，清零 g_iface_count、g_impl_for_count 和
// g_method_count，复位形状表并重跑生产注册表。上游 ts_ifc_run 的夹具包含
// 9 形参接口，不可建项；不清零会导致装填拒绝。必须最后运行，populate 会
// 复位三部分缓存。
fn ts_ccr2_row_ok(b: string, p: int, i: int) -> int:
    eo := i * ESZ_IFACE_ENTRY
    if buf_read_i32(b, p) != cell_load(g_iface_entries, eo + OFF_IE_AK):
        return 0
    if buf_read_i32(b, p + 4) != cell_load(g_iface_entries, eo + OFF_IE_TI):
        return 0
    if buf_read_i32(b, p + 8) != cell_load(g_iface_entries, eo + OFF_IE_NAME):
        return 0
    if buf_read_i32(b, p + 12) != cell_load(g_iface_entries, eo + OFF_IE_LIT):
        return 0
    if buf_read_i64(b, p + 16) != cell_load(g_iface_entries, eo + OFF_IE_OPS):
        return 0
    return 1

fn ts_ccr2_seg_walk_ok() -> int:
    b := g_ccr_iface_seg
    n := g_ccr_iface_seg_len
    if n <= 0:
        return 0
    // 1 原生条目（计数 == 常量 == 表计数；逐条记录 5 字段 == g_iface_entries）
    if buf_read_u32(b, 0) != IFACE_ENTRY_COUNT:
        return 0
    if buf_read_u32(b, 0) != g_iface_entry_count:
        return 0
    p : ., mut = 4
    ei : ., mut = 0
    loop:
        if ei >= IFACE_ENTRY_COUNT:
            break
        if ts_ccr2_row_ok(b, p, ei) != 1:
            return 0
        p = p + 24
        ei = ei + 1
    // 2 横切形状
    if buf_read_u32(b, p) != g_iface_shape_count:
        return 0
    p = p + 4
    si : ., mut = 0
    loop:
        if si >= g_iface_shape_count:
            break
        if buf_read_i32(b, p) != cell_load(g_iface_shape_names, si * 8):
            return 0
        if buf_read_i32(b, p + 4) != cell_load(g_iface_shape_terms, si * 8):
            return 0
        p = p + 8
        si = si + 1
    // 3 用户接口（头 16B + 方法 80B：项槽先于裸码槽，实施取声明记录顺序，见 ccr_types.cr 头注）
    if buf_read_u32(b, p) != g_iface_count:
        return 0
    p = p + 4
    fi : ., mut = 0
    loop:
        if fi >= g_iface_count:
            break
        fo := fi * ESZ_IFACEINFO
        mc := cell_load(g_ifaces, fo + OFF_IF_METHOD_COUNT)
        if buf_read_i32(b, p) != cell_load(g_ifaces, fo + OFF_IF_NAME):
            return 0
        if buf_read_i32(b, p + 4) != mc:
            return 0
        if buf_read_i32(b, p + 8) != cell_load(g_ifaces, fo + OFF_IF_GENERIC_COUNT):
            return 0
        p = p + 16
        mj : ., mut = 0
        loop:
            if mj >= mc:
                break
            mo := fo + OFF_IF_METHODS + mj * ESZ_IFMETHOD
            if buf_read_i32(b, p) != cell_load(g_ifaces, mo + OFF_IFM_NAME):
                return 0
            if buf_read_i32(b, p + 4) != cell_load(g_ifaces, mo + OFF_IFM_PARAM_COUNT):
                return 0
            if buf_read_i32(b, p + 8) != cell_load(g_ifaces, mo + OFF_IFM_SELF_MODE):
                return 0
            if buf_read_i32(b, p + 12) != cell_load(g_ifaces, mo + OFF_IFM_RET_TERM):
                return 0
            p = p + 16
            kq : ., mut = 0
            loop:
                if kq >= MAX_IFACE_METHOD_PARAMS:
                    break
                if buf_read_i32(b, p) != cell_load(g_ifaces, mo + OFF_IFM_PARAM_TERMS + kq * 8):
                    return 0
                p = p + 4
                kq = kq + 1
            qq : ., mut = 0
            loop:
                if qq >= MAX_IFACE_METHOD_PARAMS:
                    break
                if buf_read_i32(b, p) != cell_load(g_ifaces, mo + OFF_IFM_PARAM_TYPES + qq * 8):
                    return 0
                p = p + 4
                qq = qq + 1
            mj = mj + 1
        fi = fi + 1
    // 4 impl 边
    if buf_read_u32(b, p) != g_impl_for_count:
        return 0
    p = p + 4
    gi : ., mut = 0
    loop:
        if gi >= g_impl_for_count:
            break
        if buf_read_i32(b, p) != cell_load(g_impl_for, gi * 16):
            return 0
        if buf_read_i32(b, p + 4) != cell_load(g_impl_for, gi * 16 + 8):
            return 0
        p = p + 8
        gi = gi + 1
    // 5 方法表
    if buf_read_u32(b, p) != g_method_count:
        return 0
    p = p + 4
    mi : ., mut = 0
    loop:
        if mi >= g_method_count:
            break
        if buf_read_i32(b, p) != cell_load(g_methods, mi * 24):
            return 0
        if buf_read_i32(b, p + 4) != cell_load(g_methods, mi * 24 + 8):
            return 0
        if buf_read_i32(b, p + 8) != cell_load(g_methods, mi * 24 + 16):
            return 0
        p = p + 12
        mi = mi + 1
    if p != n:
        return 0
    // 行走完 == 缓冲长度（五小节自洽 + 无尾随字节）
    return 1

fn ts_ccr2_sig_slots_ok() -> int:
    ii : ., mut = 0
    loop:
        if ii >= g_iface_count:
            break
        mc := cell_load(g_ifaces, ii * ESZ_IFACEINFO + OFF_IF_METHOD_COUNT)
        mi : ., mut = 0
        loop:
            if mi >= mc:
                break
            mo := ii * ESZ_IFACEINFO + OFF_IF_METHODS + mi * ESZ_IFMETHOD
            // 返回槽 == 活算（签名的唯一来源 = sh_iface_sig_ret_term）
            if cell_load(g_ifaces, mo + OFF_IFM_RET_TERM) != sh_iface_sig_ret_term(ii, mi):
                return 0
            pc := cell_load(g_ifaces, mo + OFF_IFM_PARAM_COUNT)
            pj : ., mut = 0
            loop:
                if pj >= MAX_IFACE_METHOD_PARAMS:
                    break
                if pj < pc:
                    if cell_load(g_ifaces, mo + OFF_IFM_PARAM_TERMS + pj * 8) != sh_iface_sig_param_term(ii, mi, pj):
                        return 0
                else:
                    if cell_load(g_ifaces, mo + OFF_IFM_PARAM_TERMS + pj * 8) != -1:
                        return 0
                    // 未用槽 = -1
                pj = pj + 1
            mi = mi + 1
        ii = ii + 1
    return 1

fn ts_ccr2_shape_names_ok() -> int:
    // 六生产名可查 + 与构造点同项（节点同一，形状项 = 唯一数据源）
    if iface_shape_count() < 6:
        return 0
    if iface_shape_lookup(str_intern("sequence")) != sh_shape_seq():
        return 0
    if iface_shape_lookup(str_intern("sequence_ro")) != sh_shape_seq_ro():
        return 0
    if iface_shape_lookup(str_intern("sequence_rw")) != sh_shape_seq_rw():
        return 0
    if iface_shape_lookup(str_intern("indexable")) != sh_shape_indexable():
        return 0
    if iface_shape_lookup(str_intern("iterable")) != sh_shape_iterable():
        return 0
    if iface_shape_lookup(str_intern("product")) != sh_shape_product():
        return 0
    return 1

fn ts_ccr2_entries_ok() -> int:
    // 扩列 13 -> 16：三新行可查 + ops = 0（纯信息）+ 16 行逐名（注册表固定增量）
    if iface_count() != 16:
        return 0
    if iface_entry(AK_NULL) < 0:
        return 0
    if iface_entry(AK_SUM) < 0:
        return 0
    if iface_entry(AK_FN) < 0:
        return 0
    if iface_ops(AK_NULL) != 0:
        return 0
    if iface_ops(AK_SUM) != 0:
        return 0
    if iface_ops(AK_FN) != 0:
        return 0
    if iface_ti_of(AK_NULL) != -1:
        return 0
    // 无规范行（类级）
    if iface_ti_of(AK_SUM) != -1:
        return 0
    if iface_ti_of(AK_FN) != -1:
        return 0
    // 逐名（16 行：8 原生 + 5 结构/命名 + 3 新行）
    if iface_name_of(AK_INT) != str_intern("int"):
        return 0
    if iface_name_of(AK_DEX) != str_intern("dex"):
        return 0
    if iface_name_of(AK_STRING) != str_intern("string"):
        return 0
    if iface_name_of(AK_BOOL) != str_intern("bool"):
        return 0
    if iface_name_of(AK_UNIT) != str_intern("unit"):
        return 0
    if iface_name_of(AK_NEVER) != str_intern("never"):
        return 0
    if iface_name_of(AK_CHAR) != str_intern("char"):
        return 0
    if iface_name_of(AK_DYN) != str_intern("dyn"):
        return 0
    if iface_name_of(AK_PRODUCT) != str_intern("product"):
        return 0
    if iface_name_of(AK_SEQUENCE) != str_intern("sequence"):
        return 0
    if iface_name_of(AK_REF) != str_intern("ref"):
        return 0
    if iface_name_of(AK_PTR) != str_intern("ptr"):
        return 0
    if iface_name_of(AK_NAMED) != str_intern("named"):
        return 0
    if iface_name_of(AK_NULL) != str_intern("null"):
        return 0
    if iface_name_of(AK_SUM) != str_intern("sum"):
        return 0
    if iface_name_of(AK_FN) != str_intern("fn"):
        return 0
    if iface_name_of(-1) != -1:
        return 0
    // 负键检查（不得与行 0 混同）
    if iface_name_of(9999) != -1:
        return 0
    return 1

fn ts_ccr2_kind_domain_ok() -> int:
    // 判定逻辑零变化（扩列只加可查询性）：全部类型表记录枚举，三新原子不得被任何行命中
    // （若未来给某行新映射到 AK_NULL/AK_SUM/AK_FN，本用例转红 = 有意的检查）
    i : ., mut = 0
    loop:
        if i >= g_type_count:
            break
        k := iface_kind_of(i)
        if k == AK_NULL || k == AK_SUM || k == AK_FN:
            return 0
        i = i + 1
    return 1

fn ts_ccr2_run() -> int:
    fails : ., mut = 0
    // 生产重置路径检查：reset_frontend_state 清形状表计数，check_all 首行的
    // init_types 重建六个名字，不显式调用 iface_shape_builtin_init。若
    // init_types 尾部调用缺失或被移走，本条失败。
    iface_shape_reset()
    init_types()                 // 干净类型表（9 个原生记录）和生产形状注册表。
    fails = fails + ts_check_b("ct2.shape_face_from_init_types",
        (iface_shape_count() == 6 &&
            iface_shape_lookup(str_intern("sequence")) == sh_shape_seq() &&
            iface_shape_lookup(str_intern("product")) == sh_shape_product()), true)
    g_iface_count = 0            // 干净接口表。上游 ts_ifc_run 夹具包含不可建项，不清零会被拒绝装填。
    g_impl_for_count = 0
    g_method_count = 0
    iface_shape_reset()
    iface_shape_builtin_init()   // 生产注册表（6 名），populate 会重跑（幂等）
    // 夹具：命名记录 + null/可选行（判定逻辑显式断言）+ 1 接口（self 接收者 + 命名型形参）
    //   + impl 边 + 方法表（生产写点同形：parser 的 interface/impl 分支）
    ts_ifc_mk_named("Ct2Named")
    ct2_null := alloc_type(TYP_NULL, 0, 0)
    ct2_opt := alloc_type(TYP_OPTIONAL, TI_INT, 0)
    ct2_n := ts_ifc_named_node("Ct2Named")
    ct2_int_n := ts_ifc_base_node(TY_INT)
    ct2_ii := ts_t5_mk_iface("Ct2Iface")
    ts_ifc_add_method_n(ct2_ii, "a", 1, 1, -1, -1, -1, -1, ct2_int_n)      // fn a(self) -> int
    ts_ifc_add_method_n(ct2_ii, "b", 1, 0, ct2_n, -1, -1, -1, ct2_int_n)   // fn b(x: Ct2Named) -> int
    grow_impl_for(1)
    cell_store(g_impl_for, 0, str_intern("Ct2Iface"))
    cell_store(g_impl_for, 8, str_intern("Ct2Named"))
    g_impl_for_count = 1
    grow_methods(1)
    cell_store(g_methods, 0, str_intern("Ct2Named"))
    cell_store(g_methods, 8, str_intern("b"))
    cell_store(g_methods, 16, str_intern("Ct2Named.b"))
    g_method_count = 1
    prep := ccr_seg_prepare_save()
    fails = fails + ts_check("ct2.seg_prepare", prep, 0)
    if prep == 0:
        fails = fails + ts_check("ct2.iface_seg_walk", ts_ccr2_seg_walk_ok(), 1)
        fails = fails + ts_check("ct2.iface_sig_slots", ts_ccr2_sig_slots_ok(), 1)
        fails = fails + ts_check("ct2.shape_names_production", ts_ccr2_shape_names_ok(), 1)
    else:
        fails = fails + 3   // 后续三例无法运行 -> 计失败（不得漏算且不报错）
    fails = fails + ts_check("ct2.entry_table_16_named", ts_ccr2_entries_ok(), 1)
    fails = fails + ts_check_b("ct2.kind_of_no_new_mapping",
        (ts_ccr2_kind_domain_ok() == 1 && iface_kind_of(ct2_null) == -1 && iface_kind_of(ct2_opt) == -1), true)
    // 6 不可建签名（dyn 位图行入签名：sh_sig_term_of_ti 对 TYP_DYN 回 -1）-> 装填拒绝
    //  （save 拒落盘，判定约定：不得把缺项签名写成 -1 且不报错 落盘），最后（使接口表失效）
    ct2_dyn_n := ts_ifc_base_node(TI_DYN)   // parser 对 `dyn` 正产 type_val = TI_DYN
    ts_ifc_add_method_n(ct2_ii, "c", 0, 0, -1, -1, -1, -1, ct2_dyn_n)
    rej2 := ccr_iface_populate()
    fails = fails + ts_check("ct2.reject_unbuildable_sig", rej2, -1)
    return fails

// === 否定分支同类原子身份判断的邻域覆盖（11 例）===
// 覆盖：
// 1. 同身份仍相交，防止过度加强成一律判不交。
// 2. μ 变元作字面返回 -1 并置未实现位，走 lit_implies 的域外路径，结果不得被稀释。
// 3 和 4. top_k 两个方向不变，返回 0，防止将来扩域或重排把 top_k 当成身份
//    原子。现有 neg.supertype 用例走 neg 与 neg 分支，不覆盖这里。
// 5. 跨枚举同名变体返回 1，身份包含枚举名。
// 6. AK_UNIT 类令牌字面（不是 AK_SUM）维持 0，检查类域。
// 7. AK_NAMED 维持 -1 并置未实现位。
// 8. 空序列或序列元素域外返回 0，域外逐位不变。
// 9. 参数化构造子维持 0：[int] vs ¬[int ∪ string] 双向，类域检查的
//    稳定点。没有检查时元素项不同，te_chain_cmp 返回 0，会误判为 1，
//    即假不交。
// 夹具是纯合成，只使用 str_intern、sh_name_token 和项构造器，不依赖
// g_types、sh_term_of_ti 或 init_types。
// 用例数 = 11，调用方的 total = total + 11 必须同步修改。
fn ts_t2_neg_run() -> int:
    fails : ., mut = 0
    e1 := str_intern("T2NegE1")
    v1 := str_intern("T2NegV1")
    v2 := str_intern("T2NegV2")
    e2 := str_intern("T2NegE2")
    sum_11 := tt_atom(AK_SUM, -1, tt_cons(sh_name_token(e1), tt_cons(sh_name_token(v1), tt_nil())))
    sum_21 := tt_atom(AK_SUM, -1, tt_cons(sh_name_token(e2), tt_cons(sh_name_token(v1), tt_nil())))
    i_atom := tt_atom(AK_INT, TI_INT, -1)
    s_atom := tt_atom(AK_STRING, TI_STR, -1)
    // 1 同身份（同枚举同变体，两处构造 -> DAG 去重同节点）-> lp ⊆ ¬x 不成立 -> 0
    ty_budget_reset(200000)
    fails = fails + ts_check("t2.neg_same_identity_not_disjoint",
        ts_isat_b2i(ty_sub(sum_11, tt_not(sum_11)) == 0 && ty_uncovered() == 0), 1)
    // 2. μ 变元作字面没有原子类，返回 -1 并置未实现位。
    ty_budget_reset(200000)
    fails = fails + ts_check("t2.neg_var_literal_stays_minus1",
        ts_isat_b2i(ty_sub(tt_var(0), tt_not(sum_11)) == -1 && ty_uncovered() == 1), 1)
    // 3 ⊤ₖ 在左：类顶 ⊆ ¬原子 -> 假（类顶含该类全部值）-> 0
    ty_budget_reset(200000)
    fails = fails + ts_check("t2.neg_topk_left_unchanged",
        ts_isat_b2i(ty_sub(tt_top_k(AK_SUM), tt_not(sum_11)) == 0 && ty_uncovered() == 0), 1)
    // 4 ⊤ₖ 在右：原子 ⊆ ¬类顶 -> 假 -> 0
    ty_budget_reset(200000)
    fails = fails + ts_check("t2.neg_topk_right_unchanged",
        ts_isat_b2i(ty_sub(sum_11, tt_not(tt_top_k(AK_SUM))) == 0 && ty_uncovered() == 0), 1)
    // 5 跨枚举同名变体：序列首项令牌（枚举名）不同 -> 异身份 -> 1；同项 -> 0（不得混同）
    ty_budget_reset(200000)
    fails = fails + ts_check("t2.neg_cross_enum_same_name",
        ts_isat_b2i(ty_sub(sum_21, tt_not(sum_11)) == 1 && ty_sub(sum_11, tt_not(sum_21)) == 1 &&
            ty_sub(sum_11, tt_not(sum_11)) == 0 && ty_uncovered() == 0), 1)
    // 10. 同枚举不同变体：AK_SUM 槽 1 是变体令牌，而 te_chain_cmp 对槽 >= 1
    // 走实参位规则（te_arg_cmp -> ty_equiv），两个不同令牌会结构判等，b 槽
    // 只是标注，于是误判序列相同。逐元素令牌同一性判断返回 1。
    // t3.*_over_claim 三个用例属于同一族：同枚举 T3Color 的 T3Blue 和 T3Red。
    sum_12b := tt_atom(AK_SUM, -1, tt_cons(sh_name_token(e1), tt_cons(sh_name_token(v2), tt_nil())))
    ty_budget_reset(200000)
    fails = fails + ts_check("t2.neg_same_enum_diff_variant",
        ts_isat_b2i(ty_sub(sum_12b, tt_not(sum_11)) == 1 && ty_sub(sum_11, tt_not(sum_12b)) == 1 &&
            ty_sub(sum_11, tt_not(sum_11)) == 0 && ty_uncovered() == 0), 1)
    // 6. AK_UNIT 类令牌字面（不是 AK_SUM）属于类域外，维持 0。
    ty_budget_reset(200000)
    fails = fails + ts_check("t2.neg_token_literal_not_identity_face",
        ts_isat_b2i(ty_sub(sh_name_token(v1), tt_not(sh_name_token(v2))) == 0 && ty_uncovered() == 0), 1)
    // 7 AK_NAMED -> 维持 -1 + 未覆盖情形（named.not_disjoint 在册；不动）
    ty_budget_reset(200000)
    named_nc := tt_atom(AK_NAMED, 7, -1)
    fails = fails + ts_check("t2.neg_named_stays_minus1",
        ts_isat_b2i(ty_sub(named_nc, tt_not(sum_11)) == -1 && ty_uncovered() == 1), 1)
    // 8 身份令牌序列不可判的手造畸形项 -> 维持 0（P1-a 断言；两条断言分别断言两个检查：
    //  空序列（无身份）与序列元素域外（非令牌），无检查时都会落成 d == 0 -> 误判异身份-> 1）
    ty_budget_reset(200000)
    mu_chain := tt_atom(AK_SUM, -1, tt_cons(sh_name_token(e1), tt_cons(tt_var(0), tt_nil())))
    empty_chain := tt_atom(AK_SUM, -1, -1)
    fails = fails + ts_check("t2.neg_chain_elem_out_of_domain_pin",
        ts_isat_b2i(ty_sub(empty_chain, tt_not(sum_11)) == 0 &&
            ty_sub(mu_chain, tt_not(sum_11)) == 0 && ty_uncovered() == 0), 1)
    // ⑪ AK_REF 的 mut 标记位是令牌（`sh_ref_mut_marker`）-> 序列结构与 AK_SUM 同族（元素皆令牌）
    //  -> 类域检查的稳定检查点：无检查时 `&int` vs `&mut int` 在槽 0 令牌异节点 -> 误判
    //  异身份-> 1 = 假不交（D4 的 REF 类型；语义上两者值集关系未建模，保守回 0）。
    ref_r := tt_atom(AK_REF, -1, tt_cons(sh_ref_mut_marker(0), tt_cons(i_atom, tt_nil())))
    ref_m := tt_atom(AK_REF, -1, tt_cons(sh_ref_mut_marker(1), tt_cons(i_atom, tt_nil())))
    ty_budget_reset(200000)
    fails = fails + ts_check("t2.neg_ref_mut_marker_face_stays_zero",
        ts_isat_b2i(ty_sub(ref_r, tt_not(ref_m)) == 0 && ty_sub(ref_m, tt_not(ref_r)) == 0 &&
            ty_uncovered() == 0), 1)
    // 9 参数化构造子（D4）：`[int]` vs ¬`[int ∪ string]` 双向 -> 0，类域检查的稳定检查点
    //  （无检查时元素项不同 -> te_chain_cmp 回 0 -> 误判 1 = 假不交；语义上 `[int] ⊆ [int∪string]`）
    seq_i := tt_atom(AK_SEQUENCE, -1, tt_cons(i_atom, tt_nil()))
    seq_u := tt_atom(AK_SEQUENCE, -1, tt_cons(tt_union(i_atom, s_atom), tt_nil()))
    ty_budget_reset(200000)
    fails = fails + ts_check("t2.neg_param_face_stays_zero",
        ts_isat_b2i(ty_sub(seq_i, tt_not(seq_u)) == 0 && ty_sub(seq_u, tt_not(seq_i)) == 0 &&
            ty_uncovered() == 0), 1)
    return fails

fn type_selftest_run() -> int:
    saved_lib := g_cur_lib
    g_cur_lib = -1
    fails : ., mut = 0
    total : ., mut = 0

    // ---  最小用例 ---
    a_int := tt_atom(AK_INT, TI_INT, -1)
    a_str := tt_atom(AK_STRING, TI_STR, -1)
    a_bool := tt_atom(AK_BOOL, TI_BOOL, -1)

    total = total + 1
    fails = fails + ts_check("unit.bot_sub_int", ty_sub(tt_bot(), a_int), 1)
    total = total + 1
    fails = fails + ts_check("unit.int_sub_str",  ty_sub(a_int, a_str), 0)
    total = total + 1
    fails = fails + ts_check("unit.int_sub_int",  ty_sub(a_int, a_int), 1)
    total = total + 1
    fails = fails + ts_check_b("unit.dedup",       (tt_union(a_int, a_str) == tt_union(a_int, a_str)), true)
    total = total + 1
    fails = fails + ts_check_b("unit.notnot",      (tt_not(tt_not(a_int)) == a_int), true)

    // --- 规范化：De Morgan / 否定下推 / 分配规则 / 幂等 ---
    // 检查：(int ∪ string) ∩ bool，分配规则必须把它展成 union（两层分配）
    probe := tt_inter(tt_union(a_int, a_str), a_bool)
    total = total + 1
    fails = fails + ts_check_b("norm.demorgan",
        (tt_norm(tt_not(tt_union(a_int, a_str))) == tt_norm(tt_inter(tt_not(a_int), tt_not(a_str)))), true)
    total = total + 1
    fails = fails + ts_check("norm.nnf_neg_push",
        tt_tag(tt_norm(tt_not(tt_union(a_int, a_str)))), TT_INTER)
    total = total + 1
    fails = fails + ts_check("norm.dnf_shape", tt_is_dnf(tt_norm(probe)), 1)
    total = total + 1
    fails = fails + ts_check("norm.distributed", tt_tag(tt_norm(probe)), TT_UNION)
    total = total + 1
    fails = fails + ts_check_b("norm.idempotent",
        (tt_norm(tt_norm(probe)) == tt_norm(probe)), true)

    // --- 判定：子类型 / 等价 / 不相交 / 可空 / ⊤ₖ / 预算判定结果 ---
    u_is := tt_union(a_int, a_str)
    total = total + 1
    fails = fails + ts_check("sub.union_right", ty_sub(a_int, u_is), 1)
    total = total + 1
    fails = fails + ts_check("sub.union_left_neg", ty_sub(u_is, a_int), 0)
    total = total + 1
    fails = fails + ts_check("sub.inter", ty_sub(tt_inter(a_int, a_str), a_int), 1)
    // 非平凡合并：int ∪ (str ∪ int) ≡ int ∪ str（需引擎判定，非构造规则）
    total = total + 1
    fails = fails + ts_check("equiv.absorb",
        ty_equiv(tt_union(a_int, tt_union(a_str, a_int)), tt_union(a_int, a_str)), 1)
    total = total + 1
    fails = fails + ts_check("disjoint.atoms", ty_disjoint(a_int, a_str), 1)
    total = total + 1
    fails = fails + ts_check("disjoint.same", ty_disjoint(a_int, a_int), 0)
    total = total + 1
    fails = fails + ts_check("inh.atom", ty_inhabited(a_int), 1)
    total = total + 1
    fails = fails + ts_check("inh.contra", ty_inhabited(tt_inter(a_int, tt_not(a_int))), 0)
    total = total + 1
    fails = fails + ts_check("inh.mixed_atoms",
        ty_inhabited(tt_inter(a_int, tt_atom(AK_SEQUENCE, -1, -1))), 0)
    total = total + 1
    fails = fails + ts_check("topk.sub", ty_sub(a_int, tt_top_k(AK_INT)), 1)
    total = total + 1
    fails = fails + ts_check("topk.neg", ty_sub(a_str, tt_top_k(AK_INT)), 0)
    // 预算检查：深递归项 + 极小预算 -> 判定结果 -1（禁止与不成立混淆）
    ty_budget_reset(64)
    total = total + 1
    fails = fails + ts_check("budget.unknown", ty_sub(tt_probe_wide_union(300), a_int), -1)
    total = total + 1
    fails = fails + ts_check("budget.flag", ty_exhausted(), 1)
    ty_budget_reset(200000)

    // --- 反例（witness）+ 穷尽性---
    w := tt_witness(a_int, a_str)
    total = total + 1
    fails = fails + ts_check_b("witness.nonempty", (w >= 0), true)
    total = total + 1
    fails = fails + ts_check("witness.sub_of_a", ty_sub(w, a_int), 1)
    total = total + 1
    fails = fails + ts_check("witness.not_sub_of_b", ty_sub(w, a_str), 0)
    total = total + 1
    fails = fails + ts_check("witness.empty", tt_witness(a_int, a_int), -1)

    dom := tt_union(tt_union(a_int, a_str), a_bool)
    pats := tt_cons(a_int, tt_cons(a_str, tt_nil()))
    total = total + 1
    fails = fails + ts_check("exhaust.incomplete", ty_exhaustive(dom, pats), 0)
    miss := ty_exhaust_witness(dom, pats)
    total = total + 1
    fails = fails + ts_check("exhaust.witness_bool", ty_equiv(miss, a_bool), 1)
    total = total + 1
    fails = fails + ts_check("exhaust.complete",
        ty_exhaustive(dom, tt_cons(a_int, tt_cons(a_str, tt_cons(a_bool, tt_nil())))), 1)

    // --- 递归与参数化 ---
    rec_abs := tt_mu(0, tt_union(a_int, tt_var(0)))
    total = total + 1
    fails = fails + ts_check("rec.absorb", ty_equiv(rec_abs, a_int), 1)
    rec_list := tt_mu(0, tt_union(a_int, tt_atom(AK_PRODUCT, -1, tt_cons(tt_var(0), tt_nil()))))
    total = total + 1
    fails = fails + ts_check("rec.inh", ty_inhabited(rec_list), 1)
    total = total + 1
    fails = fails + ts_check("rec.sub_self", ty_sub(rec_list, rec_list), 1)
    seq_i := tt_atom(AK_SEQUENCE, -1, tt_cons(a_int, tt_nil()))
    seq_s := tt_atom(AK_SEQUENCE, -1, tt_cons(a_str, tt_nil()))
    total = total + 1
    fails = fails + ts_check("param.same", ty_sub(seq_i, seq_i), 1)
    // 不变元素槽：`[int]` 与 `[str]` 的元素原子类不同，所以 ty_sub 返回 0，
    // 不是 -1。元素为 top 的序列仍接受任意元素类型，见 TOP_K 分支和
    // x2.shape_* 用例。
    total = total + 1
    fails = fails + ts_check("param.elem_class_diff_zero", ty_sub(seq_i, seq_s), 0)
    // ty_uncovered 是全局粘滞位。断言前先复位，避免之前的用例让本用例误过。
    // 触发器是 μ 变元作序列元素，te_elem_cmp 会把它判为域外。
    ty_budget_reset(200000)
    seq_mu := tt_atom(AK_SEQUENCE, -1, tt_cons(tt_var(0), tt_nil()))
    d_dummy := ty_sub(seq_i, seq_mu)  // 重置后重新触发一次未覆盖情形（域外元素）
    total = total + 1
    fails = fails + ts_check("param.uncovered_flag", ty_uncovered(), 1)

    // Regression cases for earlier review findings.
    // 否定在超类型侧：¬A ⊆ ¬B 当且仅当 B ⊆ A。方向反了会让两侧同时成立。
    total = total + 1
    fails = fails + ts_check("neg.supertype",
        ty_sub(tt_not(seq_i), tt_not(tt_top_k(AK_SEQUENCE))), 0)
    total = total + 1
    fails = fails + ts_check("neg.supertype_rev",
        ty_sub(tt_not(tt_top_k(AK_SEQUENCE)), tt_not(seq_i)), 1)
    // 预算耗尽不得被当成 0。用小预算逐个查询，要求每次耗尽都返回 -1。
    // 只测预算 1 不够，因为规范化可能先消耗掉预算，比较还没开始。
    ok_sw : ., mut = 1
    bi : ., mut = 1
    loop:
        if bi > 12:
            break
        ty_budget_reset(bi)
        r_sw := ty_sub(tt_not(seq_i), tt_not(tt_top_k(AK_SEQUENCE)))
        if ty_exhausted() == 1 && r_sw != -1:
            ok_sw = 0
        bi = bi + 1
    ty_budget_reset(200000)
    total = total + 1
    fails = fails + ts_check("budget.no_swallow_sweep", ok_sw, 1)
    // tt_witness 返回 -1 表示不可满足，返回 -2 表示预算耗尽。
    // ty_exhaustive 把 -2 映射为 -1。
    dom_u := tt_union(tt_union(a_int, a_str), a_bool)
    pats_u := tt_cons(a_int, tt_cons(a_str, tt_nil()))
    ty_budget_reset(1)
    total = total + 1
    fails = fails + ts_check("witness.unknown_budget", tt_witness(a_int, a_str), -2)
    total = total + 1
    fails = fails + ts_check("exhaust.unknown_budget", ty_exhaustive(dom_u, pats_u), -1)
    ty_budget_reset(200000)
        // memo 表扩容：1200 个互异对触发装填因子检查和重建。
    // 能执行到下一行，说明重建没有死循环。
    d2 : ., mut = 0
    last : ., mut = 0
    loop:
        if d2 >= 1200:
            break
        last = ty_sub(tt_mu(d2, a_int), a_int)
        d2 = d2 + 1
    total = total + 1
    fails = fails + ts_check("memo.overflow_survived", last, 1)
    // 三元及以上的析取是合法 DNF，表示为左深嵌套的 union。
    total = total + 1
    fails = fails + ts_check("dnf.n_ary",
        tt_is_dnf(tt_norm(tt_inter(tt_union(a_int, a_str), tt_union(a_bool, a_int)))), 1)
    // 命名原子不展开，结果是未知；也不得断言它与产品类型互斥。
    named_t := tt_atom(AK_NAMED, 7, -1)
    a_prod := tt_atom(AK_PRODUCT, -1, -1)
    total = total + 1
    fails = fails + ts_check("named.unknown", ty_sub(named_t, a_prod), -1)
    total = total + 1
    fails = fails + ts_check("named.not_disjoint", ty_disjoint(named_t, a_prod), 0)
    // ¬μ 不会被不报错地改写为 μ¬。它保留为字面否定，并报告为未实现情形。
    total = total + 1
    fails = fails + ts_check("neg.mu_kept",
        tt_tag(tt_norm(tt_not(tt_mu(0, a_int)))), TT_NOT)

        // --- 索引扩容 ---
    // 正常用例数量远小于初始容量，不会触发扩容和重建。这里强制走这两条路径。
    ref := tt_atom(AK_SEQUENCE, -1, tt_cons(a_int, tt_nil()))
    before := tt_count()
    g_tt_index_cap = 0      // 直接逼出 grow_tt_index -> 重建索引（tt_reindex）+ 重放插入
    grow_tt_index(2)
    after := tt_atom(AK_SEQUENCE, -1, tt_cons(a_int, tt_nil()))
    total = total + 1
    fails = fails + ts_check_b("grow.index_rebuilt", (after == ref), true)
    d : ., mut = 0
    loop:
        if d >= 40:
            break
        item := tt_atom(AK_PRODUCT, -1, tt_cons(tt_mu(d, a_int), tt_nil()))
        d = d + 1
    // 构造 40 个互异项两遍。第二遍必须命中已有项，项数量不变。
    c_after_first := tt_count()
    d4 : ., mut = 0
    loop:
        if d4 >= 40:
            break
        item2 := tt_atom(AK_PRODUCT, -1, tt_cons(tt_mu(d4, a_int), tt_nil()))
        d4 = d4 + 1
    total = total + 1
    fails = fails + ts_check("grow.dedup_40_idempotent", (tt_count() - c_after_first), 0)
    total = total + 1
    fails = fails + ts_check_b("grow.dedup_after_rebuild",
        (tt_atom(AK_PRODUCT, -1, tt_cons(tt_mu(0, a_int), tt_nil())) ==
            tt_atom(AK_PRODUCT, -1, tt_cons(tt_mu(0, a_int), tt_nil()))), true)

    // --- checker 类型表记录到引擎类型项的桥接 ---
    // 本路径不经过 check_all()，所以显式调用 init_types()。九个原生类型占
    // 记录 0..8，用户类型从 9 开始，alloc_type 依赖这个布局。
    // 之前的用例会累积 g_ty_steps，这里复位预算。
    init_types()
    ty_budget_reset(200000)
    t_int := sh_term_of_ti(TI_INT)
    total = total + 1
    fails = fails + ts_check("bridge.int_atom", tt_tag(t_int), TT_ATOM)
    total = total + 1
    fails = fails + ts_check("bridge.int_ak", tt_a(t_int), AK_INT)
    t_arr := sh_term_of_ti(alloc_type(TYP_ARRAY, TI_INT, 3))
    total = total + 1
    fails = fails + ts_check("bridge.arr_seq", tt_a(t_arr), AK_SEQUENCE)
    t_arr3 := sh_term_of_ti(alloc_type(TYP_ARRAY, TI_INT, 4))
    total = total + 1
    fails = fails + ts_check("bridge.len_not_identity",
        ty_equiv(t_arr, t_arr3), 1)            // 长度不是身份的一部分，3 与 4 等价
    total = total + 1
    fails = fails + ts_check_b("bridge.cache_hit", (sh_term_of_ti(TI_INT) == t_int), true)
    // AK_* 与 TI_* 序号不一一对应：TI_BOOL=2/TI_STR=3，而
    // AK_STRING=2/AK_BOOL=3。按序号直通会把 bool 和 string 混淆，而且不会报错。
    total = total + 1
    fails = fails + ts_check("bridge.str_ak", tt_a(sh_term_of_ti(TI_STR)), AK_STRING)
    total = total + 1
    fails = fails + ts_check("bridge.bool_ak", tt_a(sh_term_of_ti(TI_BOOL)), AK_BOOL)
    total = total + 1
    fails = fails + ts_check("bridge.dyn_ak", tt_a(sh_term_of_ti(TI_DYN)), AK_DYN)
    // native 路径读取类型表记录本身：kind == TYP_BASE 且 data == TY_*。
    // 对记录 0..7 逐条检查，不抽样；任一条错位都会失败。
    // 记录 7：TI_DYN 的 kind = TYP_DYN，但 data = 0，数值等于 TY_INT。
    // 实现必须先看 kind。否则 dyn 会被译成 AK_INT。这里同时断言
    // sh_native_ak(TI_DYN) == -1，而 sh_term_of_ti(TI_DYN) 仍返回 AK_DYN。
    acc_nat : ., mut = 1
    ri : ., mut = 0
    loop:
        if ri >= 8:
            break
        want_ak : ., mut = -1
        if ri == TI_INT:
            want_ak = AK_INT
        else if ri == TI_DEX:
            want_ak = AK_DEX
        else if ri == TI_BOOL:
            want_ak = AK_BOOL
        else if ri == TI_STR:
            want_ak = AK_STRING
        else if ri == TI_UNIT:
            want_ak = AK_UNIT
        else if ri == TI_NEVER:
            want_ak = AK_NEVER
        else if ri == TI_CHAR:
            want_ak = AK_CHAR
        got_ak := sh_native_ak(ri)
        if ri == TI_DYN:
            if got_ak != -1:
                acc_nat = 0
            // dyn 行走 kind 分支，native 必须返回 -1。
        else if got_ak != want_ak:
            acc_nat = 0
        ri = ri + 1
    total = total + 1
    fails = fails + ts_check("bridge.native_row_table", acc_nat, 1)
    total = total + 1
    fails = fails + ts_check_b("bridge.native_dyn_kind_branch",
        (sh_native_ak(TI_DYN) == -1 && tt_a(sh_term_of_ti(TI_DYN)) == AK_DYN), true)
    // TY_DEX_S 占位记录 8：native 路径和通用路径都返回 AK_DEX。
    total = total + 1
    fails = fails + ts_check_b("bridge.native_dex_s",
        (sh_native_ak(TI_DEX_S) == AK_DEX && tt_a(sh_term_of_ti(TI_DEX_S)) == AK_DEX), true)
    // 检查内层参数列表；PTR 和 REF 是两条独立分支，不得互相串用。
    t_ptr := sh_term_of_ti(alloc_type(TYP_PTR, TI_INT, 0))
    // 同时检查 class 和参数列表。只检查参数列表时，整支误译成
    // SEQUENCE 或 REF 的用例仍会通过。
    total = total + 1
    fails = fails + ts_check("bridge.ptr_ak", tt_a(t_ptr), AK_PTR)
    total = total + 1
    fails = fails + ts_check("bridge.ptr_inner",
        tt_c(t_ptr), tt_cons(tt_atom(AK_INT, TI_INT, -1), tt_nil()))
    // REF 序列是 [mut 标记项, 元素项]。本用例检查第二项是元素项；
    // mut 标记项由 t1.var_mut_* 单独检查。布局见 ty_shadow.cr 的
    // sh_ref_mut_marker。
    t_ref := sh_term_of_ti(alloc_type(TYP_REF, TI_STR, 0))
    total = total + 1
    fails = fails + ts_check_b("bridge.ref_inner",
        (tt_a(t_ref) == AK_REF && tt_b(tt_c(t_ref)) == tt_cons(tt_atom(AK_STRING, TI_STR, -1), tt_nil())), true)
    t_slice := sh_term_of_ti(alloc_type(TYP_SLICE, TI_STR, 0))
    total = total + 1
    fails = fails + ts_check_b("bridge.slice_seq",
        (tt_a(t_slice) == AK_SEQUENCE && tt_c(t_slice) == tt_cons(tt_atom(AK_STRING, TI_STR, -1), tt_nil())), true)

    // --- DFNode 类型信息单槽化 ---
    // 每个 DFNode 使用两个槽：OFF_DF_TK 存类型项引用，OFF_DF_AUX 存辅码。
    // sh_dfn_code_of_slots 从这两个槽派生原码。
    // 每个应返回 -1 的用例同时断言直译路径不是 -1，证明拒绝来自分类检查，
    // 而不是这条记录本身不可译。
    total = total + 1
    fails = fails + ts_check_b("t4.tk_const_int",
        (sh_tk_term_of_code(IR_CONST, TI_INT) == sh_term_of_ti(TI_INT) &&
            tt_a(sh_tk_term_of_code(IR_CONST, TI_INT)) == AK_INT), true)
    total = total + 1
    fails = fails + ts_check_b("t4.tk_binary_dex",
        (sh_tk_term_of_code(IR_BINARY, TI_DEX) == sh_term_of_ti(TI_DEX) &&
            tt_a(sh_tk_term_of_code(IR_BINARY, TI_DEX)) == AK_DEX), true)
    total = total + 1
    fails = fails + ts_check_b("t4.tk_const_dex_s_row8",
        (sh_tk_term_of_code(IR_CONST, TI_DEX_S) == sh_term_of_ti(TI_DEX_S) &&
            tt_a(sh_tk_term_of_code(IR_CONST, TI_DEX_S)) == AK_DEX), true)
    // 反例 1：IR_BOUNDS_CHECK 的 tk 是旗标（1 表示动态上限），数值 1
    // 同时是 TI_DEX 记录。直译会得到有效项，必须由分类检查拒绝。
    total = total + 1
    fails = fails + ts_check_b("t4.tk_bounds_flag1_rejected",
        (sh_tk_term_of_code(IR_BOUNDS_CHECK, 1) == -1 && sh_term_of_ti(1) >= 0), true)
    // 反例 2：IR_DEREF / IR_STORE_PTR 的旧辅码是访问宽度（8 字节），数值 8
    // 同时是 TI_DEX_S 记录。前端 v10 Task 5 起不再发射该宽度；此处保留分类器
    // 固定用例：旧宽度码若被重引入，仍必须落辅码面（term = -1），不得当成类型行。
    total = total + 1
    fails = fails + ts_check_b("t4.tk_deref_width8_rejected",
        (sh_tk_term_of_code(IR_DEREF, 8) == -1 && sh_term_of_ti(TI_DEX_S) >= 0), true)
    total = total + 1
    fails = fails + ts_check_b("t4.tk_store_ptr_width8_rejected",
        (sh_tk_term_of_code(IR_STORE_PTR, 8) == -1 && sh_term_of_ti(TI_DEX_S) >= 0), true)
    // 反例 3：记录合法（0 = TI_INT），但 op 不属于任何类型或辅码类别。
    // 不能因为 tk 恰好合法就放行。
    total = total + 1
    fails = fails + ts_check_b("t4.tk_unlisted_op_valid_row_rejected",
        (sh_tk_term_of_code(IR_STORE, TI_INT) == -1 &&
            sh_tk_term_of_code(IR_RETURN, TI_INT) == -1 &&
            sh_tk_term_of_code(IR_MAKE_ENUM, TI_INT) == -1 &&
            sh_term_of_ti(TI_INT) >= 0), true)
    // 反例 4：记录编号越界或为负，返回 -1，不得读越界项表。
    total = total + 1
    fails = fails + ts_check_b("t4.tk_row_range_rejected",
        (sh_tk_term_of_code(IR_CONST, g_type_count) == -1 &&
            sh_tk_term_of_code(IR_BINARY, g_type_count + 7) == -1 &&
            sh_tk_term_of_code(IR_CONST, -1) == -1), true)
    // sh_tk_term_of_code 是纯查询：不写槽出参，不置建项失败位，
    // 也不影响写入文件检查。所有有副作用的路径都走 sh_tk_split。对同一记录
    // 再次查询返回同一项。
    // 检查点必须取非原生记录。原生记录走 sh_native_ak 快路径，不进缓存，
    // 用 TI_INT 测试等于恒真。TYP_DYN 记录首次直译时建项并写入缓存，
    // 第二次直译命中同一项。
    t4_dyn_row := alloc_type(TYP_DYN, 0, 0)
    t4_dyn_term := sh_term_of_ti(t4_dyn_row)          // 预热：首次（miss）入桥接缓存
    t4_fail_0 := g_tk_face_fail
    sh_tk_split(IR_CONST, g_type_count)               // 槽出参置哨兵（越界行 -> term=-1/aux=越界行号）
    t4_sent_t := g_sh_slot_term
    t4_sent_a := g_sh_slot_aux
    t4_fail_before := g_tk_face_fail
    sk4 := sh_tk_term_of_code(IR_CONST, t4_dyn_row)   // 查询路径（缓存命中）
    total = total + 1
    fails = fails + ts_check_b("t4.tk_query_purity_and_cache_hit",
        ((t4_dyn_term >= 0 && sk4 == t4_dyn_term &&
                g_sh_slot_term == t4_sent_t && g_sh_slot_aux == t4_sent_a &&
                g_tk_face_fail == t4_fail_before)), true)
    g_tk_face_fail = t4_fail_0                        // 复位本用例设置的建项失败位。

    // 原子记录约定：TT_ATOM 且 b >= 0 时返回 b；union、cons、nil、
    // 负值和越界返回 -1。
    t5s_ptr_row := alloc_type(TYP_PTR, TI_INT, 0)
    t5s_ptr_term := sh_term_of_ti(t5s_ptr_row)
    total = total + 1
    fails = fails + ts_check_b("p5t2.atom_of_contract",
        (tt_atom_of_term(sh_term_of_ti(TI_INT)) == TI_INT &&
            tt_atom_of_term(t5s_ptr_term) == -1 &&            // 复合项：AK_PTR 的 b = -1
            tt_atom_of_term(tt_nil()) == -1 &&
            tt_atom_of_term(tt_cons(tt_atom(AK_INT, TI_INT, -1), tt_nil())) == -1 &&
            tt_atom_of_term(-1) == -1 &&
            tt_atom_of_term(tt_count() + 9) == -1), true)

    // 类型表记录数据：走 split，检查类型项槽和空辅码槽。
    sh_tk_split(IR_BINARY, TI_STR)
    t5s_bin_str_term := g_sh_slot_term
    t5s_bin_str_aux := g_sh_slot_aux
    total = total + 1
    fails = fails + ts_check_b("p5t2.slot_type_face_atomic",
        (t5s_bin_str_term == sh_term_of_ti(TI_STR) && t5s_bin_str_aux == 0 &&
            sh_dfn_code_of_slots(t5s_bin_str_term, t5s_bin_str_aux) == TI_STR), true)

    // 类型表记录数据扩展：五个 op 的正向用例。
    sh_tk_split(IR_ALLOC, TI_UNIT)
    t5s_a1 := g_sh_slot_term
    t5s_a1x := g_sh_slot_aux
    sh_tk_split(IR_CALL, TI_INT)
    t5s_a2 := g_sh_slot_term
    t5s_a2x := g_sh_slot_aux
    sh_tk_split(IR_LOAD, TI_INT)
    t5s_a3 := g_sh_slot_term
    t5s_a3x := g_sh_slot_aux
    sh_tk_split(IR_I2F, TI_DEX)
    t5s_a4 := g_sh_slot_term
    t5s_a4x := g_sh_slot_aux
    sh_tk_split(IR_F2I, TI_DEX)
    t5s_a5 := g_sh_slot_term
    t5s_a5x := g_sh_slot_aux
    total = total + 1
    fails = fails + ts_check_b("p5t2.slot_type_face_extended",
        (t5s_a1 == sh_term_of_ti(TI_UNIT) && t5s_a1x == 0 && tt_a(t5s_a1) == AK_UNIT &&
            t5s_a2 == sh_term_of_ti(TI_INT) && t5s_a2x == 0 &&
            t5s_a3 == sh_term_of_ti(TI_INT) && t5s_a3x == 0 &&
            t5s_a4 == sh_term_of_ti(TI_DEX) && t5s_a4x == 0 && tt_a(t5s_a4) == AK_DEX &&
            t5s_a5 == sh_term_of_ti(TI_DEX) && t5s_a5x == 0 && tt_a(t5s_a5) == AK_DEX), true)

    // 复合记录：类型项槽为空，记录编号写入辅码槽。
    // 先确认这条记录可译（sh_term_of_ti >= 0）。否则 term = -1 也可能
    // 来自不可译，测试会失去意义。
    sh_tk_split(IR_BINARY, t5s_ptr_row)
    total = total + 1
    fails = fails + ts_check_b("p5t2.slot_composite_row_to_aux",
        (t5s_ptr_term >= 0 && g_sh_slot_term == -1 && g_sh_slot_aux == t5s_ptr_row &&
            sh_dfn_code_of_slots(g_sh_slot_term, g_sh_slot_aux) == t5s_ptr_row), true)
    // 数组记录也是复合记录：AK_SEQUENCE 的 b 槽是长度或 -1。
    t5s_arr_row := alloc_type(TYP_ARRAY, TI_INT, 3)
    sh_tk_split(IR_CONST, t5s_arr_row)
    total = total + 1
    fails = fails + ts_check_b("p5t2.slot_array_row_to_aux",
        (sh_term_of_ti(t5s_arr_row) >= 0 && g_sh_slot_term == -1 &&
            g_sh_slot_aux == t5s_arr_row &&
            sh_dfn_code_of_slots(g_sh_slot_term, g_sh_slot_aux) == t5s_arr_row), true)

    // 辅码：旗标、宽度和计数保持原码，包括负码。
    sh_tk_split(IR_BOUNDS_CHECK, 1)
    t5s_f1t := g_sh_slot_term
    t5s_f1a := g_sh_slot_aux
    sh_tk_split(IR_BOUNDS_CHECK, 0)
    t5s_f0t := g_sh_slot_term
    t5s_f0a := g_sh_slot_aux
    sh_tk_split(IR_DEREF, 8)
    t5s_d8t := g_sh_slot_term
    t5s_d8a := g_sh_slot_aux
    sh_tk_split(IR_STORE_PTR, 4)
    t5s_d4t := g_sh_slot_term
    t5s_d4a := g_sh_slot_aux
    sh_tk_split(IR_SPAWN, -1)
    t5s_spt := g_sh_slot_term
    t5s_spa := g_sh_slot_aux
    total = total + 1
    fails = fails + ts_check_b("p5t2.slot_aux_face_codes",
        (t5s_f1t == -1 && t5s_f1a == 1 && sh_dfn_code_of_slots(t5s_f1t, t5s_f1a) == 1 &&
            t5s_f0t == -1 && t5s_f0a == 0 && sh_dfn_code_of_slots(t5s_f0t, t5s_f0a) == 0 &&
            t5s_d8t == -1 && t5s_d8a == 8 && sh_dfn_code_of_slots(t5s_d8t, t5s_d8a) == 8 &&
            t5s_d4t == -1 && t5s_d4a == 4 &&
            t5s_spt == -1 && t5s_spa == -1 && sh_dfn_code_of_slots(t5s_spt, t5s_spa) == -1), true)
    // 辅码 1 和 8 直译时确实有对应项（TI_DEX 和 TI_DEX_S 记录），必须由分类检查拦截。
    total = total + 1
    fails = fails + ts_check_b("p5t2.aux_trap_rows_translatable",
        (sh_term_of_ti(1) >= 0 && tt_a(sh_term_of_ti(1)) == AK_DEX &&
            sh_term_of_ti(TI_DEX_S) >= 0 && tt_a(sh_term_of_ti(TI_DEX_S)) == AK_DEX &&
            sh_tk_term_of_code(IR_STORE_PTR, TI_DEX_S) == -1), true)

    // 范围外 op：两个槽都为空，派生码为 0。
    sh_tk_split(IR_STORE, 0)
    t5s_n1t := g_sh_slot_term
    t5s_n1a := g_sh_slot_aux
    sh_tk_split(IR_LOAD_ENUM_TAG, 0)
    t5s_n2t := g_sh_slot_term
    t5s_n2a := g_sh_slot_aux
    sh_tk_split(IR_LABEL, 0)
    t5s_n3t := g_sh_slot_term
    t5s_n3a := g_sh_slot_aux
    total = total + 1
    fails = fails + ts_check_b("p5t2.slot_none_face_empty",
        (t5s_n1t == -1 && t5s_n1a == 0 && sh_dfn_code_of_slots(t5s_n1t, t5s_n1a) == 0 &&
            t5s_n2t == -1 && t5s_n2a == 0 && t5s_n3t == -1 && t5s_n3a == 0), true)

    // 派生码规则：辅码优先；没有类型项时返回 0；复合项无法派生时返回 -1。
    total = total + 1
    fails = fails + ts_check_b("p5t2.code_derivation_contract",
        (sh_dfn_code_of_slots(sh_term_of_ti(TI_STR), 0) == TI_STR &&
            sh_dfn_code_of_slots(-1, 0) == 0 &&
            sh_dfn_code_of_slots(-1, 7) == 7 &&
            sh_dfn_code_of_slots(t5s_ptr_term, 0) == -1 &&      // 复合项放在类型项槽时无法派生，返回 -1。
            sh_dfn_code_of_slots(sh_term_of_ti(TI_INT), 9) == 9), true)   // 辅码优先；拆分器保证两个槽互斥。

    // 槽互斥：逐 op 检查三种形态：类型项、辅码、都为空。
    sh_tk_split(IR_CONST, TI_STR)
    t5s_m1 := (g_sh_slot_term >= 0 && g_sh_slot_aux == 0)
    sh_tk_split(IR_DEREF, 8)
    t5s_m2 := (g_sh_slot_term == -1 && g_sh_slot_aux != 0)
    sh_tk_split(IR_STORE, 0)
    t5s_m3 := (g_sh_slot_term == -1 && g_sh_slot_aux == 0)
    t5s_m_ok : ., mut = 1
    if t5s_m1 == 0 || t5s_m2 == 0 || t5s_m3 == 0:
        t5s_m_ok = 0
    total = total + 1
    fails = fails + ts_check("p5t2.slot_mutual_exclusion", t5s_m_ok, 1)

    // IR_HOTPATCH_ROUTE 没有类型信息，两个槽都为空。
    sh_tk_split(IR_HOTPATCH_ROUTE, 0)
    total = total + 1
    fails = fails + ts_check_b("p5t2.hotpatch_route_no_face",
        (g_sh_slot_term == -1 && g_sh_slot_aux == 0 &&
            sh_dfn_code_of_slots(g_sh_slot_term, g_sh_slot_aux) == 0), true)

    // 建项失败位：越界记录使计数加一，复合记录不置位。
    t5s_fail_before := g_tk_face_fail
    sh_tk_split(IR_CONST, g_type_count)
    t5s_fail_after := g_tk_face_fail
    t5s_out_t := g_sh_slot_term               // 出参须即时取（下一次 split 会覆写）
    t5s_out_a := g_sh_slot_aux
    sh_tk_split(IR_BINARY, t5s_ptr_row)      // 复合行 = 域内可译 -> 不得置位
    t5s_fail_final := g_tk_face_fail
    g_tk_face_fail = 0                        // 复位（不影响后续落盘检查用例）
    total = total + 1
    fails = fails + ts_check_b("p5t2.d23_build_fail_bit",
        (t5s_fail_after == t5s_fail_before + 1 && t5s_fail_final == t5s_fail_after &&
            t5s_out_t == -1 && t5s_out_a == g_type_count), true)
    // TYP_NAMED：AK_NAMED，记录编号存 b 槽。引擎不展开，判定结果为未知。
    // 这里刻意裸分配。alloc_named_type 会登记名字并去重。本用例的人造记录
    // 使用的名字键 1201 不对应任何真实名字，登记会破坏 name->ti 映射。
    // 裸分配不登记，不会破坏映射。
    named_ti := alloc_type(TYP_NAMED, 1201, 0)
    t_named := sh_term_of_ti(named_ti)
    total = total + 1
    fails = fails + ts_check_b("bridge.named_ak_b",
        (tt_a(t_named) == AK_NAMED && tt_b(t_named) == named_ti), true)
    // TYP_TUPLE 布局：data = 字段数，extra = 字段记录编号在
    // g_gen_apply_data 的起始下标，每项 8 字节。
    grow_gen_apply_data(g_gen_apply_data_count + 2)
    tup_start := g_gen_apply_data_count
    cell_store(g_gen_apply_data, tup_start * 8, TI_INT)
    cell_store(g_gen_apply_data, (tup_start + 1) * 8, TI_STR)
    g_gen_apply_data_count = g_gen_apply_data_count + 2
    t_tup := sh_term_of_ti(alloc_type(TYP_TUPLE, 2, tup_start))
    total = total + 1
    fails = fails + ts_check("bridge.tuple_product", tt_a(t_tup), AK_PRODUCT)
    total = total + 1
    fails = fails + ts_check("bridge.tuple_fields",
        tt_c(t_tup), tt_cons(tt_atom(AK_INT, TI_INT, -1), tt_cons(tt_atom(AK_STRING, TI_STR, -1), tt_nil())))
    // 新记录恰好向缓存加入一项。元素是原生类型，走快路径，不进缓存。
    // 同一记录第二次查询命中同一项，不新增条目。
    e_before := sh_map_entries()
    arr_ti2 := alloc_type(TYP_ARRAY, TI_STR, 9)
    t_arr2 := sh_term_of_ti(arr_ti2)
    total = total + 1
    fails = fails + ts_check("bridge.entries_delta", (sh_map_entries() - e_before), 1)
    e_hit_before := sh_map_entries()
    t_arr2b := sh_term_of_ti(arr_ti2)
    total = total + 1
    fails = fails + ts_check_b("bridge.cache_hit_same_term_no_new_entry",
        (t_arr2b == t_arr2 && sh_map_entries() == e_hit_before), true)
    // 上面只有 8 条记录，远小于初始容量 1024，扩容和重建路径不可达。
    // 用 600 条互异记录触发一次扩容重建。检查两件事：条目数恰好增加 600；
    // 重建前已入表的条目仍命中。
    g_before := sh_map_entries()
    gi : ., mut = 0
    loop:
        if gi >= 600:
            break
        sh_term_of_ti(alloc_type(TYP_ARRAY, TI_INT, 1000 + gi))
        gi = gi + 1
    total = total + 1
    fails = fails + ts_check_b("bridge.grow_rehash",
        (sh_map_entries() == g_before + 600 && sh_term_of_ti(arr_ti2) == t_arr2), true)
    total = total + 1
    fails = fails + ts_check_b("bridge.grow_cap_doubled", (g_term_map_cap >= 2048), true)
    // 再增加 1100 条互异记录，触发第二次扩容。检查条目数恰好增加 1100，
    // 容量至少 4096，首阶段记录仍命中。
    g2_before := sh_map_entries()
    gj : ., mut = 0
    loop:
        if gj >= 1100:
            break
        sh_term_of_ti(alloc_type(TYP_ARRAY, TI_INT, 5000 + gj))
        gj = gj + 1
    total = total + 1
    fails = fails + ts_check_b("bridge.grow_rehash2",
        (sh_map_entries() == g2_before + 1100 && g_term_map_cap >= 4096 && sh_term_of_ti(arr_ti2) == t_arr2), true)

    // --- 同名 TYP_NAMED 记录去重 ---
    // 同一个类型名在不同出现点各建一条记录，桥接按记录编号建原子，
    // 引擎就会把两条记录当成不同命名类型，导致 9 条 unknown。
    // 修法是建表时去重，唯一分配点收敛到 alloc_named_type。
    n1 := alloc_named_type(str_intern("DedupProbe"))
    n2 := alloc_named_type(str_intern("DedupProbe"))
    total = total + 1
    fails = fails + ts_check_b("f1.same_name_one_row", (n1 == n2), true)
    total = total + 1
    fails = fails + ts_check("f1.row_count", named_dedup_rows(str_intern("DedupProbe")), 1)
    n3 := alloc_named_type(str_intern("DedupProbe2"))
    total = total + 1
    fails = fails + ts_check_b("f1.diff_name_diff_row", (n3 != n1), true)
    // 同名记录归并后，桥接对两个名字得到同一项。
    total = total + 1
    fails = fails + ts_check_b("f1.bridge_same_term",
        (sh_term_of_ti(n1) == sh_term_of_ti(n2)), true)
    // 加入 1700 个互异真实名字，触发两次扩容。检查容量至少 4096；
    // 条目数恰好增加 1700；首条记录仍映射到原记录；名字记录数仍为 1。
    c_before := g_named_dedup_count
    f1i : ., mut = 0
    loop:
        if f1i >= 1700:
            break
        alloc_named_type(str_intern("DedupGrow" + int_str(f1i)))
        f1i = f1i + 1
    total = total + 1
    fails = fails + ts_check_b("f1.dedup_rehash_survived",
        (g_named_dedup_cap >= 4096 && g_named_dedup_count == c_before + 1700 && alloc_named_type(str_intern("DedupProbe")) == n1 && named_dedup_rows(str_intern("DedupProbe")) == 1), true)

    // --- 数组长度 N 改为常量档长度约束 ---
    // 身份判等曾把 N 和元素判等绑在一起。引擎侧现在规定 N 不属于身份，
    // 所以直接替换判定会让 [int;4] 通过 [int;3]。
    // 修法是把 N 移到具名约束 array_len_constraint_ok，由判定点显式补检。
    // 异长仍拒绝，同长仍通过。本组检查这个约束。
    // 本组之前的用例只做裸分配和侧表操作，没有运行判定，这里复位预算。
    ty_budget_reset(200000)
    f2_arr3 := alloc_type(TYP_ARRAY, TI_INT, 3)
    f2_arr3b := alloc_type(TYP_ARRAY, TI_INT, 3)   // 另一条同长记录：约束不能依赖记录编号相同。
    f2_arr4 := alloc_type(TYP_ARRAY, TI_INT, 4)
    total = total + 1
    fails = fails + ts_check("f2.same_len_ok",
        array_len_constraint_ok(f2_arr3, f2_arr3b), 1)
    total = total + 1
    fails = fails + ts_check("f2.diff_len_reject",
        array_len_constraint_ok(f2_arr4, f2_arr3), 0)
    // 引擎侧：N 不属于身份。
    total = total + 1
    fails = fails + ts_check("f2.engine_len_agnostic",
        ty_equiv(sh_term_of_ti(f2_arr4), sh_term_of_ti(f2_arr3)), 1)
    // N 不只在顶层数组位置。下面四种位置也要检查：数组元素、泛型应用实参、
    // 指针元素和元组字段。每例同时检查同长通过和异长拒绝。
    f2_outer3 := alloc_type(TYP_ARRAY, f2_arr3, 2)
    f2_outer4 := alloc_type(TYP_ARRAY, f2_arr4, 2)
    total = total + 1
    fails = fails + ts_check_b("f2.nested_elem_reject",
        (array_len_constraint_ok(f2_outer3, f2_outer3) == 1 && array_len_constraint_ok(f2_outer4, f2_outer3) == 0), true)
    grow_gen_apply_data(g_gen_apply_data_count + 4)
    f2_ga_s1 := g_gen_apply_data_count
    cell_store(g_gen_apply_data, f2_ga_s1 * 8, 1)
    cell_store(g_gen_apply_data, (f2_ga_s1 + 1) * 8, f2_arr3)
    f2_ga_s2 := f2_ga_s1 + 2
    cell_store(g_gen_apply_data, f2_ga_s2 * 8, 1)
    cell_store(g_gen_apply_data, (f2_ga_s2 + 1) * 8, f2_arr4)
    g_gen_apply_data_count = f2_ga_s2 + 2
    // 基类型记录裸分配：人造记录不登记到名字表，避免假键破坏 name->ti 映射。
    f2_base := alloc_type(TYP_NAMED, 1202, 0)
    f2_ga3 := alloc_type(TYP_GENERIC_APPLY, f2_base, f2_ga_s1)
    f2_ga4 := alloc_type(TYP_GENERIC_APPLY, f2_base, f2_ga_s2)
    total = total + 1
    fails = fails + ts_check_b("f2.genapply_arg_reject",
        (array_len_constraint_ok(f2_ga3, f2_ga3) == 1 && array_len_constraint_ok(f2_ga4, f2_ga3) == 0), true)
    f2_pt3 := alloc_type(TYP_PTR, f2_arr3, 0)
    f2_pt4 := alloc_type(TYP_PTR, f2_arr4, 0)
    total = total + 1
    fails = fails + ts_check_b("f2.ptr_elem_reject",
        (array_len_constraint_ok(f2_pt3, f2_pt3) == 1 && array_len_constraint_ok(f2_pt4, f2_pt3) == 0), true)
    grow_gen_apply_data(g_gen_apply_data_count + 4)
    f2_tp_s1 := g_gen_apply_data_count
    cell_store(g_gen_apply_data, f2_tp_s1 * 8, TI_INT)
    cell_store(g_gen_apply_data, (f2_tp_s1 + 1) * 8, f2_arr3)
    f2_tp_s2 := f2_tp_s1 + 2
    cell_store(g_gen_apply_data, f2_tp_s2 * 8, TI_INT)
    cell_store(g_gen_apply_data, (f2_tp_s2 + 1) * 8, f2_arr4)
    g_gen_apply_data_count = f2_tp_s2 + 2
    f2_tup3 := alloc_type(TYP_TUPLE, 2, f2_tp_s1)
    f2_tup4 := alloc_type(TYP_TUPLE, 2, f2_tp_s2)
    total = total + 1
    fails = fails + ts_check_b("f2.tuple_field_reject",
        (array_len_constraint_ok(f2_tup3, f2_tup3) == 1 && array_len_constraint_ok(f2_tup4, f2_tup3) == 0), true)
    // 非数组对（包括只有一侧是数组）没有长度约束，结果恒为满足。这防止约束实现退化成一律拒绝。
    total = total + 1
    fails = fails + ts_check_b("f2.nonarray_no_constraint",
        (array_len_constraint_ok(f2_arr3, TI_INT) == 1 && array_len_constraint_ok(TI_INT, f2_arr3) == 1), true)
    // 补齐 REF 和 SLICE 两个递归位置。已有数组元素、泛型实参、指针元素和
    // 元组字段四个位置，下钻六个位置中还缺这两个。
    // 站点措辞由 type_compat_strict 的结果决定：1 兼容；0 身份不匹配；
    // -1 身份通过但长度约束失败。0 和 -1 必须分开，否则长度错误会被报成
    // 普通类型不匹配。
    // REF 只检查 data（元素），不比较 extra（mut）。mut 属于身份判定。
    f2_rf3 := alloc_type(TYP_REF, f2_arr3, 0)
    f2_rf4 := alloc_type(TYP_REF, f2_arr4, 0)
    total = total + 1
    fails = fails + ts_check_b("f2.ref_elem_reject",
        (array_len_constraint_ok(f2_rf3, f2_rf3) == 1 && array_len_constraint_ok(f2_rf4, f2_rf3) == 0), true)
    f2_sl3 := alloc_type(TYP_SLICE, f2_arr3, 0)
    f2_sl4 := alloc_type(TYP_SLICE, f2_arr4, 0)
    total = total + 1
    fails = fails + ts_check_b("f2.slice_elem_reject",
        (array_len_constraint_ok(f2_sl3, f2_sl3) == 1 && array_len_constraint_ok(f2_sl4, f2_sl3) == 0), true)
    // 站点分派：同结构同长返回 1；数组对基类型返回 0；同结构异长返回 -1。
    // 只有第三种走长度措辞，它同时证明 type_equal 已放行，引擎身份确实不含 N。
    total = total + 1
    fails = fails + ts_check("t3.strict_dispatch_ok",
        type_compat_strict(f2_arr3, f2_arr3b), 1)
    total = total + 1
    fails = fails + ts_check("t3.strict_dispatch_identity",
        type_compat_strict(f2_arr3, TI_INT), 0)
    total = total + 1
    fails = fails + ts_check("t3.strict_dispatch_len",
        type_compat_strict(f2_arr4, f2_arr3), -1)

    // --- 判定替换：引擎负责判定，未知结果按 ICE04 处理，N 不回到身份 ---
    // 1. N 长度约束：type_equal 对同结构异长返回 true，说明 N 不在身份内。
    //    拒绝由 array_len_constraint_ok 单独承担。两条断言合起来检查这个不变量。
    // 2. 两个不同命名类型记录经桥接得到不同身份令牌序列，引擎返回 0，不返回未知。
    //    回落路径删除后，断言改为引擎直接判定且不产生 ICE04。
    // 3. 同一记录走快路径，不进入引擎，结果恒为 true。
    ty_budget_reset(200000)
    t3_arr3 := alloc_type(TYP_ARRAY, TI_INT, 3)
    t3_arr4 := alloc_type(TYP_ARRAY, TI_INT, 4)
    t3_ok : ., mut = 0
    if type_equal(t3_arr3, t3_arr4):
        if array_len_constraint_ok(t3_arr4, t3_arr3) == 0:
            t3_ok = 1
    total = total + 1
    fails = fails + ts_check("t3.engine_len_not_identity", t3_ok, 1)
    // 人造记录，不登记到生产名字表。alloc_named_type 只用于取得互异的命名记录。
    t3_na := alloc_named_type(str_intern("T3NamedA"))
    t3_nb := alloc_named_type(str_intern("T3NamedB"))
    // 命名类型接入引擎后，两个不同名字由引擎直接判 0，不回落，
    // 也不产生未知诊断。
    t3_d0 := g_diag_count
    t3_ub : ., mut = 0
    if !type_equal(t3_na, t3_nb):
        if g_diag_count == t3_d0:
            t3_ub = 1
    total = total + 1
    fails = fails + ts_check_b("t3.named_face_decided_no_indeterminate",
        (t3_ub == 1 && ty_equiv(sh_term_of_ti(t3_na), sh_term_of_ti(t3_nb)) == 0), true)
    // 桥接缺口：sh_term_of_ti 无法翻译记录编号越界的记录。
    // type_equal 判 false 并产生一条 ICE04。本例只检查行为和诊断码，
    // 措辞由 t4.ice04_* 检查。
    t3_bf_d0 := g_diag_count
    t3_bf : ., mut = 0
    if !type_equal(g_type_count + 100, TI_INT):
        if g_diag_count == t3_bf_d0 + 1:
            if ts_diag_code_at(t3_bf_d0) == EC_ICE_TY_INDET:
                t3_bf = 1
    total = total + 1
    fails = fails + ts_check("t3.bridge_gap_ice04_hard_error", t3_bf, 1)
    g_diag_count = t3_bf_d0    // 这条诊断是故意触发的，复位计数，避免影响后续用例。
    ty_budget_reset(200000)

    // --- 桥接缓存随类型表重置失效 ---
    // 桥接缓存以记录编号为键。init_types() 清空并重建类型表后，记录编号会复用。
    // 旧缓存项必须清除，否则两个不同类型会读到同一个类型项。
    // 用例 1：重置后条目数和容量都归零，缓存按需重建。
    // 用例 2：记录编号复用时不得返回旧项；新记录的元素原子类必须从 int 变成 bool。
    // 只检查计数、不检查返回值的测试，在计数清零但表仍存活的错误实现下会通过。
    init_types()                                    // 干净起点（同时建立缓存基线）
    t3c_tiA := alloc_type(TYP_ARRAY, TI_INT, 2)     // 行号 T
    t3c_termA := sh_term_of_ti(t3c_tiA)             // 缓存 {T -> seq(int)}
    t3c_entries_mid := sh_map_entries()
    init_types()                                    // 类型表 + 桥接缓存一并失效
    t3c_entries_after := sh_map_entries()
    total = total + 1
    fails = fails + ts_check_b("t3c.map_reset_clears_bridge",
        (t3c_entries_mid >= 1 && t3c_entries_after == 0 && g_term_map_cap == 0), true)
    t3c_tiB := alloc_type(TYP_ARRAY, TI_BOOL, 2)    // 同一行号 T（复用）
    t3c_termB := sh_term_of_ti(t3c_tiB)
    t3c_ok : ., mut = 0
    if t3c_tiB == t3c_tiA:
        // 场景成立：行号确实复用
        if t3c_termB != t3c_termA:
            // 未返回陈旧项
            if tt_a(tt_a(tt_c(t3c_termA))) == AK_INT:
                if tt_a(tt_a(tt_c(t3c_termB))) == AK_BOOL:
                    t3c_ok = 1
    total = total + 1
    fails = fails + ts_check("t3c.no_stale_term_after_reset", t3c_ok, 1)

    // --- 本质条目表和 iface_* 查询 API ---
    // 本路径不经过 check_all，所以显式调用 init_types()。重建后类型表记录编号
    // 范围复位，结构记录从 9 开始。
    // 16 个条目：13 个原有条目，加 AK_NULL、AK_SUM、AK_FN；两个方向：ak->ti
    // 和记录->ak 类；12 个 API 逐个检查签名。8 个原生类型逐条检查，不抽样。
    // 新增三个条目只有信息，ops = 0，ti_row = -1；判定逻辑没有新增映射由
    // ct2.kind_of_no_new_mapping 检查，本用例只检查可查询性。
    init_types()
    total = total + 1
    fails = fails + ts_check("iface.count", iface_count(), 16)
    // 逐原生条目：ak -> 规范行 + AK↔TI 下标不 1:1 的显式检查（bool/string 互换即红）
    total = total + 1
    fails = fails + ts_check("iface.int_ti", iface_ti_of(AK_INT), TI_INT)
    total = total + 1
    fails = fails + ts_check("iface.dex_ti", iface_ti_of(AK_DEX), TI_DEX)
    total = total + 1
    fails = fails + ts_check("iface.str_ti", iface_ti_of(AK_STRING), TI_STR)
    total = total + 1
    fails = fails + ts_check("iface.bool_ti", iface_ti_of(AK_BOOL), TI_BOOL)
    total = total + 1
    fails = fails + ts_check("iface.unit_ti", iface_ti_of(AK_UNIT), TI_UNIT)
    total = total + 1
    fails = fails + ts_check("iface.never_ti", iface_ti_of(AK_NEVER), TI_NEVER)
    total = total + 1
    fails = fails + ts_check("iface.char_ti", iface_ti_of(AK_CHAR), TI_CHAR)
    total = total + 1
    fails = fails + ts_check("iface.dyn_ti", iface_ti_of(AK_DYN), TI_DYN)
    // 结构类和命名类条目没有规范记录，返回 -1。若被填成某条记录，就是类级和记录级混同。
    total = total + 1
    fails = fails + ts_check_b("iface.struct_ti_none",
        (iface_ti_of(AK_PRODUCT) == -1 && iface_ti_of(AK_SEQUENCE) == -1 && iface_ti_of(AK_REF) == -1 &&
            iface_ti_of(AK_PTR) == -1 && iface_ti_of(AK_NAMED) == -1), true)
    // 记录到原子类：8 个原生类型读取类型表记录本身（kind == TYP_BASE 且 data == TY_*），不按记录编号猜。
    total = total + 1
    fails = fails + ts_check("iface.kind_int", iface_kind_of(TI_INT), AK_INT)
    total = total + 1
    fails = fails + ts_check("iface.kind_dex", iface_kind_of(TI_DEX), AK_DEX)
    total = total + 1
    fails = fails + ts_check("iface.kind_str", iface_kind_of(TI_STR), AK_STRING)
    total = total + 1
    fails = fails + ts_check("iface.kind_bool", iface_kind_of(TI_BOOL), AK_BOOL)
    total = total + 1
    fails = fails + ts_check("iface.kind_unit", iface_kind_of(TI_UNIT), AK_UNIT)
    total = total + 1
    fails = fails + ts_check("iface.kind_never", iface_kind_of(TI_NEVER), AK_NEVER)
    total = total + 1
    fails = fails + ts_check("iface.kind_char", iface_kind_of(TI_CHAR), AK_CHAR)
    total = total + 1
    fails = fails + ts_check("iface.kind_dyn", iface_kind_of(TI_DYN), AK_DYN)
    total = total + 1
    fails = fails + ts_check("iface.kind_oob", iface_kind_of(g_type_count + 7), -1)
    total = total + 1
    fails = fails + ts_check("iface.kind_neg", iface_kind_of(-1), -1)
    // 结构类和命名类记录按 kind 返回对应类；成对检查，防止不同类互相误判。
    ifc_ptr := alloc_type(TYP_PTR, TI_INT, 0)
    ifc_ref := alloc_type(TYP_REF, TI_STR, 0)
    total = total + 1
    fails = fails + ts_check_b("iface.kind_ptr_ref",
        (iface_kind_of(ifc_ptr) == AK_PTR && iface_kind_of(ifc_ref) == AK_REF), true)
    ifc_arr := alloc_type(TYP_ARRAY, TI_INT, 3)
    ifc_slice := alloc_type(TYP_SLICE, TI_INT, 0)
    total = total + 1
    fails = fails + ts_check_b("iface.kind_seq",
        (iface_kind_of(ifc_arr) == AK_SEQUENCE && iface_kind_of(ifc_slice) == AK_SEQUENCE), true)
    ifc_tup := alloc_type(TYP_TUPLE, 0, 0)
    total = total + 1
    fails = fails + ts_check("iface.kind_product", iface_kind_of(ifc_tup), AK_PRODUCT)
    ifc_named := alloc_named_type(str_intern("IfaceNamedProbe"))
    ifc_gp := alloc_type(TYP_GENERIC_PARAM, str_intern("IfaceGP"), 0)
    ifc_ga := alloc_type(TYP_GENERIC_APPLY, ifc_named, 0)
    total = total + 1
    fails = fails + ts_check_b("iface.kind_named",
        (iface_kind_of(ifc_named) == AK_NAMED && iface_kind_of(ifc_gp) == AK_NAMED &&
            iface_kind_of(ifc_ga) == AK_NAMED), true)
    // 条目定位（含越界/负键：不得把无此原子与行 0 混同）
    total = total + 1
    fails = fails + ts_check_b("iface.entry_lookup",
        (iface_entry(AK_INT) >= 0 && iface_entry(AK_INT) < iface_count() && iface_entry(AK_NAMED) >= 0 &&
            iface_entry(-1) == -1 && iface_entry(9999) == -1), true)
    // TY_* 码 -> 原子类
    total = total + 1
    fails = fails + ts_check_b("iface.ty_code_natives",
        (iface_by_ty_code(TY_INT) == AK_INT && iface_by_ty_code(TY_DEX) == AK_DEX &&
            iface_by_ty_code(TY_BOOL) == AK_BOOL && iface_by_ty_code(TY_STRING) == AK_STRING &&
            iface_by_ty_code(TY_UNIT) == AK_UNIT && iface_by_ty_code(TY_NEVER) == AK_NEVER &&
            iface_by_ty_code(TY_CHAR) == AK_CHAR), true)
    total = total + 1
    fails = fails + ts_check_b("iface.ty_code_gray",
        (iface_by_ty_code(TY_DEX_S) == AK_DEX && iface_by_ty_code(TY_GENERIC_PARAM) == AK_NAMED), true)
    total = total + 1
    fails = fails + ts_check("iface.ty_code_unknown", iface_by_ty_code(999), -1)
    // 字面量定型：查表入口是条目的 lit_code 列。infer_expr 的五个字面量
    // 分支使用同一张表，端到端检查见文件末段 lit.infer_*。
    total = total + 1
    fails = fails + ts_check("iface.lit_int", iface_lit_ti(EXPR_INT), TI_INT)
    total = total + 1
    fails = fails + ts_check("iface.lit_dex", iface_lit_ti(EXPR_DEX), TI_DEX)
    total = total + 1
    fails = fails + ts_check("iface.lit_str", iface_lit_ti(EXPR_STRING), TI_STR)
    total = total + 1
    fails = fails + ts_check("iface.lit_bool", iface_lit_ti(EXPR_BOOL), TI_BOOL)
    total = total + 1
    fails = fails + ts_check("iface.lit_char", iface_lit_ti(EXPR_CHAR), TI_CHAR)
    total = total + 1
    fails = fails + ts_check("iface.lit_none", iface_lit_ti(EXPR_IDENT), -1)
    total = total + 1
    fails = fails + ts_check_b("iface.lit_ak",
        (iface_lit_ak(EXPR_INT) == AK_INT && iface_lit_ak(EXPR_DEX) == AK_DEX &&
            iface_lit_ak(EXPR_STRING) == AK_STRING && iface_lit_ak(EXPR_BOOL) == AK_BOOL &&
            iface_lit_ak(EXPR_CHAR) == AK_CHAR), true)
    // 负键表示没有字面量，必须先行拒绝，否则 -1 会命中无字面量条目。
    total = total + 1
    fails = fails + ts_check("iface.lit_neg", iface_lit_ak(-1), -1)
    // 类型项到原子类：单个原子或 top_k 返回类；复合项和越界返回 -1。
    ifc_term_atom := tt_atom(AK_INT, TI_INT, -1)
    total = total + 1
    fails = fails + ts_check("iface.of_term_atom", iface_of_term(ifc_term_atom), AK_INT)
    total = total + 1
    fails = fails + ts_check("iface.of_term_topk", iface_of_term(tt_top_k(AK_SEQUENCE)), AK_SEQUENCE)
    total = total + 1
    fails = fails + ts_check("iface.of_term_compound", iface_of_term(tt_union(a_int, a_str)), -1)
    total = total + 1
    fails = fails + ts_check_b("iface.of_term_oob",
        (iface_of_term(-1) == -1 && iface_of_term(tt_count() + 9) == -1), true)
    // 未知原子返回空许可集；位下标越界返回 0，不得回绕成全部许可。
    total = total + 1
    fails = fails + ts_check("iface.ops_unknown", iface_ops(-1), 0)
    total = total + 1
    fails = fails + ts_check("iface.ops_unknown_ak", iface_ops(9999), 0)
    total = total + 1
    fails = fails + ts_check_b("iface.permits_bad_op",
        (iface_permits(AK_INT, -1) == 0 && iface_permits(AK_INT, 63) == 0 && iface_permits(9999, OP_ADD) == 0), true)

    // --- iface_kind_of 与桥接分派共用同一张表 ---
    // 判断方式是全表逐格比较，不抽样：生产入口的每个格子必须等于冻结期望表。
    // 字面拷贝对照物已删除，改用 ts_t4_ak_expected 和
    // ts_t4_native_ak_expected。它们只保存期望数据，不是第二份生产实现。
    // 只比较两个版本是否相等，会漏掉入口被换成第三个实现、或两个版本一起错
    // 的情况，所以下面另加显式断言。
    // 1. TY 码表：9 个 TY_* 码和 1 个未映射码。
    t2_codes := alloc(10 * 8)
    cell_store(t2_codes, 0, TY_INT)
    cell_store(t2_codes, 8, TY_DEX)
    cell_store(t2_codes, 16, TY_BOOL)
    cell_store(t2_codes, 24, TY_STRING)
    cell_store(t2_codes, 32, TY_UNIT)
    cell_store(t2_codes, 40, TY_NEVER)
    cell_store(t2_codes, 48, TY_CHAR)
    cell_store(t2_codes, 56, TY_GENERIC_PARAM)
    cell_store(t2_codes, 64, TY_DEX_S)
    cell_store(t2_codes, 72, 999)
    t2_ty_bad : ., mut = 0
    t2_i : ., mut = 0
    loop:
        if t2_i >= 10:
            break
        t2_code := cell_load(t2_codes, t2_i * 8)
        if iface_by_ty_code(t2_code) != ts_t4_ak_expected(t2_code):
            t2_ty_bad = t2_ty_bad + 1
        t2_i = t2_i + 1
    total = total + 1
    fails = fails + ts_check("iface.by_ty_code_all_codes", t2_ty_bad, 0)
    // 2. 类型表记录：逐条检查 [0, g_type_count)，包括 TI_DYN、TI_DEX_S 和结构/命名记录。
    t2_ti_bad : ., mut = 0
    t2_j : ., mut = 0
    loop:
        if t2_j >= g_type_count:
            break
        if sh_native_ak(t2_j) != ts_t4_native_ak_expected(t2_j):
            t2_ti_bad = t2_ti_bad + 1
        t2_j = t2_j + 1
    total = total + 1
    fails = fails + ts_check("iface.native_ak_all_rows", t2_ti_bad, 0)
    // 3. 防止空跑：扫描计数必须是 10；记录数必须等于 g_type_count 且至少 9；
    // 比较必须能区分两个已知不同的格子。
    total = total + 1
    fails = fails + ts_check_b("iface.scan_coverage",
        (t2_i == 10 && cell_load(t2_codes, 56) == TY_GENERIC_PARAM && cell_load(t2_codes, 64) == TY_DEX_S &&
            t2_j == g_type_count && t2_j >= 9), true)
    total = total + 1
    fails = fails + ts_check_b("iface.compare_is_live",
        (iface_by_ty_code(999) == ts_t4_ak_expected(TY_INT)), false)
    // 4. 生产入口确实委托给同一张表：逐项检查，包括两个特殊映射和未映射码。
    total = total + 1
    fails = fails + ts_check_b("iface.bridge_delegates",
        (sh_base_ak(TY_INT) == AK_INT && sh_base_ak(TY_STRING) == AK_STRING && sh_base_ak(TY_BOOL) == AK_BOOL &&
            sh_base_ak(TY_DEX_S) == AK_DEX && sh_base_ak(TY_GENERIC_PARAM) == AK_NAMED && sh_base_ak(999) == -1 &&
            sh_native_ak(TI_INT) == AK_INT && sh_native_ak(TI_STR) == AK_STRING), true)
    // 5. sh_native_ak 保留自己的入口条件，不能退化成 iface_kind_of：
    // DYN 记录、结构记录和负值返回 -1；iface_kind_of 对 DYN 返回 AK_DYN。
    // 两个函数分别断言。
    total = total + 1
    fails = fails + ts_check_b("iface.bridge_gate_kept",
        (sh_native_ak(TI_DYN) == -1 && sh_native_ak(ifc_arr) == -1 && sh_native_ak(ifc_named) == -1 &&
            sh_native_ak(-1) == -1 && iface_kind_of(TI_DYN) == AK_DYN), true)
    // 6. AK 和 TI 序号不一一对应。如果有人按下标直传，本条失败。
    total = total + 1
    fails = fails + ts_check_b("iface.dispatch_no_index_shortcut",
        (iface_ti_of(AK_STRING) != AK_STRING && iface_ti_of(AK_BOOL) != AK_BOOL && TI_STR != TI_BOOL), true)

    // --- infer_expr 的五个字面量分支改用 iface_lit_ti ---
    // 用 alloc_node 构造五个字面量节点，逐个比较 infer_expr(节点) 和
    // iface_lit_ti 的结果。只检查表侧不够：表对但接线点写错键时，表侧用例
    // 仍会通过，只有经 infer_expr 真正执行才会暴露。
    li_int := alloc_node(EXPR_INT, -1, -1, -1, 42, TY_INT, -1, 0, 0)
    li_dex := alloc_node(EXPR_DEX, -1, -1, -1, 314, TY_DEX, -1, 0, 0)
    li_str := alloc_node(EXPR_STRING, -1, -1, -1, str_intern("iface_lit_probe"), TY_STRING, -1, 0, 0)
    li_bool := alloc_node(EXPR_BOOL, -1, -1, -1, 1, TY_BOOL, -1, 0, 0)
    li_char := alloc_node(EXPR_CHAR, -1, -1, -1, 65, TY_CHAR, -1, 0, 0)
    // 构造出的节点必须带预期 kind，防止 alloc_node 参数错位。
    total = total + 1
    fails = fails + ts_check_b("lit.node_kinds",
        (ast_kind(li_int) == EXPR_INT && ast_kind(li_dex) == EXPR_DEX && ast_kind(li_str) == EXPR_STRING &&
            ast_kind(li_bool) == EXPR_BOOL && ast_kind(li_char) == EXPR_CHAR), true)
    total = total + 1
    fails = fails + ts_check("lit.infer_int", infer_expr(li_int), TI_INT)
    total = total + 1
    fails = fails + ts_check("lit.infer_dex", infer_expr(li_dex), TI_DEX)
    total = total + 1
    fails = fails + ts_check("lit.infer_str", infer_expr(li_str), TI_STR)
    total = total + 1
    fails = fails + ts_check("lit.infer_bool", infer_expr(li_bool), TI_BOOL)
    total = total + 1
    fails = fails + ts_check("lit.infer_char", infer_expr(li_char), TI_CHAR)
    // 端到端结果必须等于查表结果。
    total = total + 1
    fails = fails + ts_check_b("lit.infer_is_table",
        (infer_expr(li_int) == iface_lit_ti(EXPR_INT) && infer_expr(li_dex) == iface_lit_ti(EXPR_DEX) &&
            infer_expr(li_str) == iface_lit_ti(EXPR_STRING) && infer_expr(li_bool) == iface_lit_ti(EXPR_BOOL) &&
            infer_expr(li_char) == iface_lit_ti(EXPR_CHAR)), true)
    // 短路顺序保持不变。EXPR_NONE 的转发行位于 EXPR_INT 和 EXPR_DEX 之间：
    // 带内层值的 wrapper 走转发行，返回内层类型；空 wrapper 转到 EXPR_NONE
    // 分支，返回 TI_UNIT。
    li_wrap := alloc_node(EXPR_NONE, li_int, -1, -1, 0, 0, -1, 0, 0)
    li_wrap_empty := alloc_node(EXPR_NONE, -1, -1, -1, 0, 0, -1, 0, 0)
    total = total + 1
    fails = fails + ts_check("lit.none_forwards", infer_expr(li_wrap), TI_INT)
    total = total + 1
    fails = fails + ts_check("lit.none_empty_unit", infer_expr(li_wrap_empty), TI_UNIT)
    // 负节点在 infer_expr 开头被拒绝，接线不能挤掉这个分支。
    total = total + 1
    fails = fails + ts_check("lit.neg_node_unit", infer_expr(-1), TI_UNIT)

    // --- 操作许可位集：ops 列逐格检查，消费者是 checker.cr 的三个检查 ---
    // 与改动前的判定逐格等价，不抽样：每个 ak 和每个 op 都比较
    // iface_permits 和改动前的判断条件。三个关键等价关系：
    // 1. ADD..MOD 许可当且仅当 ak 是 int 或 dex。PTR 和 STRING 不在内，
    //    所以 *T + *T 和 "a" - "b" 仍报 error[TB01]。
    // 2. OP_AND/OP_OR 许可当且仅当 ak 是 int 或 bool。dex 被拒绝，
    //    1.5 && true 仍报 TC01。
    // 3. IP_COND 只允许 bool；if 与 while 共用同一条规则。
    //    while 1 仍报 TC04。
    // 另设许可为 1 的格数哨兵，全 0 表会失败；再加条目数据一致性和端到端段。
    o4_aks := alloc(13 * 8)   // 13 类枚举（顺序 = 条目表声明序）
    cell_store(o4_aks, 0, AK_INT)
    cell_store(o4_aks, 8, AK_DEX)
    cell_store(o4_aks, 16, AK_STRING)
    cell_store(o4_aks, 24, AK_BOOL)
    cell_store(o4_aks, 32, AK_UNIT)
    cell_store(o4_aks, 40, AK_NEVER)
    cell_store(o4_aks, 48, AK_CHAR)
    cell_store(o4_aks, 56, AK_DYN)
    cell_store(o4_aks, 64, AK_PRODUCT)
    cell_store(o4_aks, 72, AK_SEQUENCE)
    cell_store(o4_aks, 80, AK_REF)
    cell_store(o4_aks, 88, AK_PTR)
    cell_store(o4_aks, 96, AK_NAMED)
    o4_ops := alloc(5 * 8)    // 算术族 5 op（检查消费点：OP_ADD..OP_MOD）
    cell_store(o4_ops, 0, OP_ADD)
    cell_store(o4_ops, 8, OP_SUB)
    cell_store(o4_ops, 16, OP_MUL)
    cell_store(o4_ops, 24, OP_DIV)
    cell_store(o4_ops, 32, OP_MOD)
    // 1 算术检查：逐 ak × 逐 op 对拍许可 ⟺ int|dex
    o4_arith_bad : ., mut = 0
    o4_arith_yes : ., mut = 0
    o4_i : ., mut = 0
    loop:
        if o4_i >= 13:
            break
        o4_ak := cell_load(o4_aks, o4_i * 8)
        o4_j : ., mut = 0
        loop:
            if o4_j >= 5:
                break
            o4_op := cell_load(o4_ops, o4_j * 8)
            o4_want : ., mut = 0
            if o4_ak == AK_INT || o4_ak == AK_DEX:
                o4_want = 1
            if iface_permits(o4_ak, o4_op) != o4_want:
                o4_arith_bad = o4_arith_bad + 1
            if iface_permits(o4_ak, o4_op) == 1:
                o4_arith_yes = o4_arith_yes + 1
            o4_j = o4_j + 1
        o4_i = o4_i + 1
    total = total + 1
    fails = fails + ts_check("ops.arith_gate_eq_legacy", o4_arith_bad, 0)
    total = total + 1
    fails = fails + ts_check("ops.arith_permit_count", o4_arith_yes, 10)  // = 2 ak × 5 op
    // 2 逻辑族：逐 ak × 逐 op（OP_AND/OP_OR）对拍许可 ⟺ int|bool，判断条件取 OP_AND（不另设 IP_LOGIC）
    o4_logic_bad : ., mut = 0
    o4_logic_yes : ., mut = 0
    o4_k : ., mut = 0
    loop:
        if o4_k >= 13:
            break
        o4_ak2 := cell_load(o4_aks, o4_k * 8)
        o4_want2 : ., mut = 0
        if o4_ak2 == AK_INT || o4_ak2 == AK_BOOL:
            o4_want2 = 1
        if iface_permits(o4_ak2, OP_AND) != o4_want2:
            o4_logic_bad = o4_logic_bad + 1
        if iface_permits(o4_ak2, OP_OR) != o4_want2:
            o4_logic_bad = o4_logic_bad + 1
        if iface_permits(o4_ak2, OP_AND) == 1:
            o4_logic_yes = o4_logic_yes + 1
        o4_k = o4_k + 1
    total = total + 1
    fails = fails + ts_check("ops.logic_gate_eq_legacy", o4_logic_bad, 0)
    total = total + 1
    fails = fails + ts_check("ops.logic_permit_count", o4_logic_yes, 2)  // int + bool
    // 3 条件族：IP_COND = {bool}；if 与 while 共用同一条规则。
    o4_cond_bad : ., mut = 0
    o4_cond_yes : ., mut = 0
    o4_m : ., mut = 0
    loop:
        if o4_m >= 13:
            break
        o4_ak3 := cell_load(o4_aks, o4_m * 8)
        o4_want3 : ., mut = 0
        if o4_ak3 == AK_BOOL:
            o4_want3 = 1
        if iface_permits(o4_ak3, IP_COND) != o4_want3:
            o4_cond_bad = o4_cond_bad + 1
        if iface_permits(o4_ak3, IP_COND) == 1:
            o4_cond_yes = o4_cond_yes + 1
        o4_m = o4_m + 1
    total = total + 1
    fails = fails + ts_check("ops.cond_gate_eq_legacy", o4_cond_bad, 0)
    total = total + 1
    fails = fails + ts_check("ops.cond_permit_count", o4_cond_yes, 1)
    // 4. 比较、一元和 AS 操作目前全部许可，没有拒绝路径。这里只登记为
    // 待接线项，逐格检查 13 类 × 11 op = 143 格。
    o4_all_bad : ., mut = 0
    o4_all_yes : ., mut = 0
    o4_n : ., mut = 0
    loop:
        if o4_n >= 13:
            break
        o4_ak4 := cell_load(o4_aks, o4_n * 8)
        o4_n2 : ., mut = 0
        loop:
            if o4_n2 >= 6:
                break
            o4_cop := OP_EQ + o4_n2                     // OP_EQ..OP_GE 连续取值（6..11）
            if iface_permits(o4_ak4, o4_cop) != 1:
                o4_all_bad = o4_all_bad + 1
            if iface_permits(o4_ak4, o4_cop) == 1:
                o4_all_yes = o4_all_yes + 1
            o4_n2 = o4_n2 + 1
        o4_n3 : ., mut = 0
        loop:
            if o4_n3 >= 4:
                break
            o4_uop := IP_UOP_BIAS + 1 + o4_n3           // UOP_NEG..UOP_DEREF -> 21..24
            if iface_permits(o4_ak4, o4_uop) != 1:
                o4_all_bad = o4_all_bad + 1
            if iface_permits(o4_ak4, o4_uop) == 1:
                o4_all_yes = o4_all_yes + 1
            o4_n3 = o4_n3 + 1
        if iface_permits(o4_ak4, IP_AS) != 1:
            o4_all_bad = o4_all_bad + 1
        if iface_permits(o4_ak4, IP_AS) == 1:
            o4_all_yes = o4_all_yes + 1
        o4_n = o4_n + 1
    total = total + 1
    fails = fails + ts_check("ops.all_permit_eq_legacy", o4_all_bad, 0)
    total = total + 1
    fails = fails + ts_check("ops.all_permit_count", o4_all_yes, 143)  // 13 × 11
    // 5. 容器和方法许可：索引、字段、方法各检查两类允许和两类拒绝。
    total = total + 1
    fails = fails + ts_check_b("ops.index_permit_set",
        (iface_permits(AK_SEQUENCE, IP_INDEX) == 1 && iface_permits(AK_STRING, IP_INDEX) == 1 &&
            iface_permits(AK_INT, IP_INDEX) == 0 && iface_permits(AK_REF, IP_INDEX) == 0 &&
            iface_permits(AK_SEQUENCE, IP_INDEX_RANGE) == 1 && iface_permits(AK_STRING, IP_INDEX_RANGE) == 0), true)
    total = total + 1
    fails = fails + ts_check_b("ops.field_permit_set",
        (iface_permits(AK_NAMED, IP_FIELD) == 1 && iface_permits(AK_PRODUCT, IP_FIELD) == 1 &&
            iface_permits(AK_INT, IP_FIELD) == 0 && iface_permits(AK_SEQUENCE, IP_FIELD) == 0), true)
    total = total + 1
    fails = fails + ts_check_b("ops.method_permit_set",
        (iface_permits(AK_DYN, IP_METHOD) == 1 && iface_permits(AK_NAMED, IP_METHOD) == 1 &&
            iface_permits(AK_INT, IP_METHOD) == 0 && iface_permits(AK_PTR, IP_METHOD) == 0), true)
    // 6. 条目数据一致性：iface_ops(ak) 必须回读该条记录的 ops 字段，
    // 防止列未填或查错记录。新增的 AK_NULL、AK_SUM、AK_FN 三个条目只有信息，
    // ops = 0 是设计值。零 ops 行恰好三行，并且可以逐名指出；其余行的 ops 必须非 0。
    o4_row_bad : ., mut = 0
    o4_zero : ., mut = 0
    o4_r : ., mut = 0
    loop:
        if o4_r >= g_iface_entry_count:
            break
        o4_akr := cell_load(g_iface_entries, o4_r * ESZ_IFACE_ENTRY + OFF_IE_AK)
        if iface_ops(o4_akr) != cell_load(g_iface_entries, o4_r * ESZ_IFACE_ENTRY + OFF_IE_OPS):
            o4_row_bad = o4_row_bad + 1
        if iface_ops(o4_akr) == 0:
            if o4_akr == AK_NULL || o4_akr == AK_SUM || o4_akr == AK_FN:
                o4_zero = o4_zero + 1
            else:
                o4_row_bad = o4_row_bad + 1
        o4_r = o4_r + 1
    total = total + 1
    fails = fails + ts_check_b("ops.entry_row_consistent",
        (o4_row_bad == 0 && o4_zero == 3), true)
    // 7. 端到端：经真正的 infer_expr 走三个检查。表侧用例不能证明接线正确。
    // ptr 操作数是 &int 字面量构造的节点（EXPR_UNARY/UOP_REF），不走 ident
    // 分支，不触发借用检查。
    o4_ref := alloc_node(EXPR_UNARY, li_int, -1, UOP_REF, 0, 0, -1, 0, 0)
    o4_ref2 := alloc_node(EXPR_UNARY, li_int, -1, UOP_REF, 0, 0, -1, 0, 0)
    o4_b_add_int := alloc_node(EXPR_BINARY, li_int, li_int, OP_ADD, 0, 0, -1, 0, 0)
    o4_b_sub_str := alloc_node(EXPR_BINARY, li_str, li_str, OP_SUB, 0, 0, -1, 0, 0)
    o4_b_add_str := alloc_node(EXPR_BINARY, li_str, li_str, OP_ADD, 0, 0, -1, 0, 0)
    o4_b_ptrptr := alloc_node(EXPR_BINARY, o4_ref, o4_ref2, OP_ADD, 0, 0, -1, 0, 0)
    o4_b_ptrdiff := alloc_node(EXPR_BINARY, o4_ref, o4_ref2, OP_SUB, 0, 0, -1, 0, 0)
    o4_b_ptradd := alloc_node(EXPR_BINARY, o4_ref, li_int, OP_ADD, 0, 0, -1, 0, 0)
    o4_b_dex := alloc_node(EXPR_BINARY, li_dex, li_int, OP_ADD, 0, 0, -1, 0, 0)
    o4_b_logic := alloc_node(EXPR_BINARY, li_bool, li_int, OP_AND, 0, 0, -1, 0, 0)
    o4_b_logic_bad := alloc_node(EXPR_BINARY, li_dex, li_bool, OP_AND, 0, 0, -1, 0, 0)
    o4_b_eq := alloc_node(EXPR_BINARY, li_str, li_int, OP_EQ, 0, 0, -1, 0, 0)
    // 构造的节点必须带预期 kind 和 op，防止 alloc_node 参数错位。
    total = total + 1
    fails = fails + ts_check_b("ops.node_kinds",
        (ast_kind(o4_b_add_int) == EXPR_BINARY && ast_c(o4_b_add_int) == OP_ADD &&
            ast_kind(o4_ref) == EXPR_UNARY && ast_c(o4_ref) == UOP_REF), true)
    // 正向用例：int 算术、字符串拼接、地址型加 int、dex 算术、int 逻辑、比较不校验。
    o4_m0 := g_diag_count
    o4_r_add := infer_expr(o4_b_add_int)
    total = total + 1
    fails = fails + ts_check("ops.infer_add_int",
        o4_r_add * 100 + (g_diag_count - o4_m0), TI_INT * 100)
    o4_m1 := g_diag_count
    o4_r_cat := infer_expr(o4_b_add_str)
    total = total + 1
    fails = fails + ts_check("ops.infer_add_str_concat",
        o4_r_cat * 100 + (g_diag_count - o4_m1), TI_STR * 100)
    o4_m2 := g_diag_count
    o4_r_pa := infer_expr(o4_b_ptradd)
    // 结果保持操作数的 kind。o4_ref 是 REF，所以结果是 TYP_REF。
    // alloc_type 不去重，每次调用追加新记录，不能拿两次推断的记录编号比较。
    // 本条同时证明检查接受 REF：如果算术检查被整条关掉，诊断计数会变化。
    o4_pa_ok : ., mut = 0
    if get_type_kind(o4_r_pa) == TYP_REF && get_type_data(o4_r_pa) == TI_INT:
        if g_diag_count - o4_m2 == 0:
            o4_pa_ok = 1
    total = total + 1
    fails = fails + ts_check("ops.infer_ptr_add_int", o4_pa_ok, 1)
    // 另一个方向：int + 地址型，覆盖检查的第二个条件（左操作数是 int，
    // 右操作数是地址型）。上一例只覆盖地址型在左。本例如检查被关掉，
    // 诊断计数会变化。
    o4_b_intaddr := alloc_node(EXPR_BINARY, li_int, o4_ref2, OP_ADD, 0, 0, -1, 0, 0)
    o4_m2b := g_diag_count
    o4_r_ia := infer_expr(o4_b_intaddr)
    o4_ia_ok : ., mut = 0
    if get_type_kind(o4_r_ia) == TYP_REF && get_type_data(o4_r_ia) == TI_INT:
        if g_diag_count - o4_m2b == 0:
            o4_ia_ok = 1
    total = total + 1
    fails = fails + ts_check("ops.infer_int_add_addr", o4_ia_ok, 1)
    o4_m3 := g_diag_count
    o4_r_dx := infer_expr(o4_b_dex)
    total = total + 1
    fails = fails + ts_check("ops.infer_dex_add",
        o4_r_dx * 100 + (g_diag_count - o4_m3), TI_DEX * 100)
    o4_m4 := g_diag_count
    o4_r_lg := infer_expr(o4_b_logic)
    total = total + 1
    fails = fails + ts_check("ops.infer_logic_int_ok",
        o4_r_lg * 100 + (g_diag_count - o4_m4), TI_BOOL * 100)
    o4_m5 := g_diag_count
    o4_r_eq := infer_expr(o4_b_eq)
    total = total + 1
    fails = fails + ts_check("ops.infer_cmp_unchecked",
        o4_r_eq * 100 + (g_diag_count - o4_m5), TI_BOOL * 100)   // 现状宽松范围：比较不校验（登记）
    // 反例：字符串算术、ptr + ptr、dex 逻辑必须仍报错，诊断码不变。
    o4_m6 := g_diag_count
    o4_r_bad1 := infer_expr(o4_b_sub_str)
    total = total + 1
    fails = fails + ts_check("ops.infer_sub_str_diag", g_diag_count - o4_m6, 1)
    total = total + 1
    fails = fails + ts_check("ops.infer_sub_str_code", ts_diag_code_at(o4_m6), EC_TB_ADD)
    total = total + 1
    fails = fails + ts_check("ops.infer_sub_str_result", o4_r_bad1, TI_INT)
    o4_m7 := g_diag_count
    o4_r_bad2 := infer_expr(o4_b_ptrptr)
    total = total + 1
    fails = fails + ts_check("ops.infer_ptr_add_ptr_diag", g_diag_count - o4_m7, 1)
    total = total + 1
    fails = fails + ts_check("ops.infer_ptr_add_ptr_code", ts_diag_code_at(o4_m7), EC_TB_ADD)
    total = total + 1
    fails = fails + ts_check("ops.infer_ptr_add_ptr_result", o4_r_bad2, TI_INT)
    o4_m8 := g_diag_count
    o4_r_bad3 := infer_expr(o4_b_logic_bad)
    total = total + 1
    fails = fails + ts_check("ops.infer_logic_dex_diag", g_diag_count - o4_m8, 1)
    total = total + 1
    fails = fails + ts_check("ops.infer_logic_dex_code", ts_diag_code_at(o4_m8), EC_TC_IF_COND)
    // 地址型减地址型早退为 int，不经过检查，不报错。
    o4_m9 := g_diag_count
    o4_r_pd := infer_expr(o4_b_ptrdiff)
    total = total + 1
    fails = fails + ts_check("ops.infer_ptr_diff",
        o4_r_pd * 100 + (g_diag_count - o4_m9), TI_INT * 100)

    // --- 容器接线：索引的后备拒绝改用 IP_INDEX 查表 ---
    // 三层检查：
    // 1. 集等价：枚举全部类型表记录，比较检查可达集和表的拒绝集，双向计数。
    // 2. 端到端：经 infer_expr 检查三个结果分支和后备检查，比较诊断增量、
    //    诊断码和结果类型。
    // 3. 防退化：枚举覆盖行类直方图，并检查构造节点的 kind 和 op。
    // 本段自备覆盖行：PTR、REF、TUPLE 各一条，供直方图计数。
    ix_row_ptr := alloc_type(TYP_PTR, TI_INT, 0)
    ix_row_ref := alloc_type(TYP_REF, TI_INT, 0)
    ix_row_tup := alloc_type(TYP_TUPLE, 0, 0)
    ix_li0 := alloc_node(EXPR_INT, -1, -1, -1, 0, TY_INT, -1, 0, 0)   // 索引值 0，字符串下标必须在界内，避免触发界检查诊断。
    ix_arr3 := alloc_node(EXPR_ARRAY, -1, 3, -1, 0, 0, -1, 0, 0)   // 数组字面量 len=3（无元素）
    ix_arr0 := alloc_node(EXPR_ARRAY, -1, 0, -1, 0, 0, -1, 0, 0)   // 空数组字面量 len=0
    ix_idx_arr := alloc_node(EXPR_INDEX, ix_arr0, li_int, -1, 0, 0, -1, 0, 0)
    ix_idx_str := alloc_node(EXPR_INDEX, li_str, ix_li0, -1, 0, 0, -1, 0, 0)
    ix_idx_int := alloc_node(EXPR_INDEX, li_int, li_int, -1, 0, 0, -1, 0, 0)
    ix_idx_bool := alloc_node(EXPR_INDEX, li_bool, li_int, -1, 0, 0, -1, 0, 0)
    ix_ref := alloc_node(EXPR_UNARY, li_int, -1, UOP_REF, 0, 0, -1, 0, 0)
    ix_idx_ptr := alloc_node(EXPR_INDEX, ix_ref, li_int, -1, 0, 0, -1, 0, 0)
    ix_range := alloc_node(EXPR_RANGE, li_int, li_int, -1, 0, 0, -1, 0, 0)
    ix_idx_arr_range := alloc_node(EXPR_INDEX, ix_arr0, ix_range, -1, 0, 0, -1, 0, 0)
    ix_idx_str_range := alloc_node(EXPR_INDEX, li_str, ix_range, -1, 0, 0, -1, 0, 0)
    ix_idx_arr_oob := alloc_node(EXPR_INDEX, ix_arr3, li_int, -1, 0, 0, -1, 0, 0)
    ix_idx_range_oob := alloc_node(EXPR_INDEX, ix_arr3, ix_range, -1, 0, 0, -1, 0, 0)
    total = total + 1
    fails = fails + ts_check_b("idx.node_kinds",
        (ast_kind(ix_idx_arr) == EXPR_INDEX && ast_kind(ix_arr3) == EXPR_ARRAY && ast_b(ix_idx_arr) == li_int &&
            ast_kind(ix_range) == EXPR_RANGE && ast_kind(ix_idx_ptr) == EXPR_INDEX && ast_c(ix_ref) == UOP_REF), true)
    // 1. 集等价：逐条记录检查 perm == 1 当且仅当该记录不属于结果分支已处理集 {ARRAY, SLICE, TI_STR}。
    ix_bad : ., mut = 0
    ix_n_rows : ., mut = 0
    ix_n_seq : ., mut = 0
    ix_n_str : ., mut = 0
    ix_n_named : ., mut = 0
    ix_n_prod : ., mut = 0
    ix_n_ref : ., mut = 0
    ix_n_ptr : ., mut = 0
    ix_n_dyn : ., mut = 0
    ix_i : ., mut = 0
    loop:
        if ix_i >= g_type_count:
            break
        ix_k := get_type_kind(ix_i)
        ix_ak := iface_kind_of(ix_i)
        ix_reach : ., mut = 1   // 1 = 到达后备检查（结果分支都不命中）
        if ix_k == TYP_ARRAY || ix_k == TYP_SLICE || ix_i == TI_STR:
            ix_reach = 0
        ix_perm := iface_permits(ix_ak, IP_INDEX)
        ix_want : ., mut = 1
        if ix_reach == 1:
            ix_want = 0
        if ix_perm != ix_want:
            ix_bad = ix_bad + 1
        if ix_k == TYP_ARRAY || ix_k == TYP_SLICE:
            ix_n_seq = ix_n_seq + 1
        if ix_i == TI_STR:
            ix_n_str = ix_n_str + 1
        if ix_ak == AK_NAMED:
            ix_n_named = ix_n_named + 1
        if ix_ak == AK_PRODUCT:
            ix_n_prod = ix_n_prod + 1
        if ix_ak == AK_REF:
            ix_n_ref = ix_n_ref + 1
        if ix_ak == AK_PTR:
            ix_n_ptr = ix_n_ptr + 1
        if ix_ak == AK_DYN:
            ix_n_dyn = ix_n_dyn + 1
        ix_n_rows = ix_n_rows + 1
        ix_i = ix_i + 1
    total = total + 1
    fails = fails + ts_check("idx.gate_deny_covers_fallback", ix_bad, 0)
    // 3. 防退化：扫描全表；每类至少一条记录；STR 记录恰好一条。
    // TI_STR 与 AK_STRING 的等价依赖 TYP_BASE 记录只在 init_types 分配一次。
    total = total + 1
    fails = fails + ts_check_b("idx.scan_coverage",
        (ix_n_rows == g_type_count && ix_n_rows >= 15 && ix_n_seq >= 2 && ix_n_str == 1 &&
            ix_n_named >= 1 && ix_n_prod >= 1 && ix_n_ref >= 1 && ix_n_ptr >= 1 && ix_n_dyn >= 1 &&
            get_type_kind(ix_row_ptr) == TYP_PTR && get_type_kind(ix_row_ref) == TYP_REF &&
            get_type_kind(ix_row_tup) == TYP_TUPLE), true)
    // 2. 端到端：数组和字符串索引返回 int；越界和切片界诊断仍发出。
    ix_m0 := g_diag_count
    ix_r_arr := infer_expr(ix_idx_arr)
    total = total + 1
    fails = fails + ts_check("idx.infer_arr_ok", ix_r_arr * 100 + (g_diag_count - ix_m0), TI_INT * 100)
    ix_m1 := g_diag_count
    ix_r_str := infer_expr(ix_idx_str)
    total = total + 1
    fails = fails + ts_check("idx.infer_str_ok", ix_r_str * 100 + (g_diag_count - ix_m1), TI_INT * 100)
    ix_m2 := g_diag_count
    ix_r_asc := infer_expr(ix_idx_arr_range)
    ix_asc_ok : ., mut = 0
    if get_type_kind(ix_r_asc) == TYP_SLICE && get_type_data(ix_r_asc) == TI_INT:
        if g_diag_count - ix_m2 == 0:
            ix_asc_ok = 1
    total = total + 1
    fails = fails + ts_check("idx.infer_range_slice", ix_asc_ok, 1)
    // 后备检查生效：非容器记录报 TK01，诊断码和结果类型不变。
    ix_m3 := g_diag_count
    ix_r_int := infer_expr(ix_idx_int)
    total = total + 1
    fails = fails + ts_check("idx.infer_int_denied_diag", g_diag_count - ix_m3, 1)
    total = total + 1
    fails = fails + ts_check("idx.infer_int_denied_code", ts_diag_code_at(ix_m3), EC_TK_INDEX)
    total = total + 1
    fails = fails + ts_check("idx.infer_int_denied_result", ix_r_int, TI_INT)
    ix_m4 := g_diag_count
    infer_expr(ix_idx_bool)
    total = total + 1
    fails = fails + ts_check("idx.infer_bool_denied_diag", g_diag_count - ix_m4, 1)
    total = total + 1
    fails = fails + ts_check("idx.infer_bool_denied_code", ts_diag_code_at(ix_m4), EC_TK_INDEX)
    ix_m5 := g_diag_count
    infer_expr(ix_idx_ptr)
    total = total + 1
    fails = fails + ts_check("idx.infer_ptr_denied_diag", g_diag_count - ix_m5, 1)
    total = total + 1
    fails = fails + ts_check("idx.infer_ptr_denied_code", ts_diag_code_at(ix_m5), EC_TK_INDEX)
    // 已登记行为：字符串 range 索引不报错，结果为 unit。这是 range 分支
    // 对非数组的落空行为。
    ix_m6 := g_diag_count
    ix_r_sr := infer_expr(ix_idx_str_range)
    total = total + 1
    fails = fails + ts_check("idx.infer_str_range_unit", ix_r_sr * 100 + (g_diag_count - ix_m6), TI_UNIT * 100)
    // 结果分支保持原样：越界和切片界诊断仍发出，接线没有合并分支。
    ix_m7 := g_diag_count
    infer_expr(ix_idx_arr_oob)
    total = total + 1
    fails = fails + ts_check("idx.infer_arr_oob_diag", g_diag_count - ix_m7, 1)
    total = total + 1
    fails = fails + ts_check("idx.infer_arr_oob_code", ts_diag_code_at(ix_m7), EC_R_OOB)
    ix_m8 := g_diag_count
    infer_expr(ix_idx_range_oob)
    total = total + 1
    fails = fails + ts_check("idx.infer_range_oob_diag", g_diag_count - ix_m8, 1)
    total = total + 1
    fails = fails + ts_check("idx.infer_range_oob_code", ts_diag_code_at(ix_m8), EC_TK_SLICE_BOUNDS)

    // --- res_type_node 和 res_call_type 共用 ty_code_to_ti 映射 ---
    // 三层检查：
    // 1. 表侧逐码，包括表内不后备：TY_DEX_S、未知码和负码返回 -1。
    // 2. 端到端：构造基型节点，经 res_type_node 和 res_call_type 比较返回。
    // 3. 防止空跑：节点 kind 和 tv 回读正确；负节点先行拒绝；两表唯一
    //    差异格 NEVER 双向断言。
    total = total + 1
    fails = fails + ts_check_b("t6.ty_code_head",
        (ty_code_to_ti(TY_INT) == TI_INT && ty_code_to_ti(TY_DEX) == TI_DEX &&
            ty_code_to_ti(TY_BOOL) == TI_BOOL && ty_code_to_ti(TY_STRING) == TI_STR &&
            ty_code_to_ti(TY_UNIT) == TI_UNIT), true)
    total = total + 1
    fails = fails + ts_check_b("t6.ty_code_tail",
        (ty_code_to_ti(TY_NEVER) == TI_NEVER && ty_code_to_ti(TY_CHAR) == TI_CHAR), true)
    // 码 7 同时是 TY_GENERIC_PARAM 和 TI_DYN，数值冲突。两表保持原样。
    total = total + 1
    fails = fails + ts_check_b("t6.ty_code_dyn7",
        (ty_code_to_ti(TI_DYN) == TI_DYN && ty_code_to_ti(TY_GENERIC_PARAM) == TI_DYN), true)
    // 表内不后备：TY_DEX_S(8) 不在两表并集里；未知码和负码返回 -1。
    total = total + 1
    fails = fails + ts_check_b("t6.ty_code_domain",
        (ty_code_to_ti(TY_DEX_S) == -1 && ty_code_to_ti(-1) == -1 && ty_code_to_ti(999) == -1), true)
    // 2. 端到端：基型节点逐码检查，包括码 7（dyn）；parser 对 dyn 类型名产生这个码。
    t6_int := alloc_node(0, 0, 0, 0, 0, TY_INT, 0, 0, 0)
    t6_dex := alloc_node(0, 0, 0, 0, 0, TY_DEX, 0, 0, 0)
    t6_bool := alloc_node(0, 0, 0, 0, 0, TY_BOOL, 0, 0, 0)
    t6_str := alloc_node(0, 0, 0, 0, 0, TY_STRING, 0, 0, 0)
    t6_unit := alloc_node(0, 0, 0, 0, 0, TY_UNIT, 0, 0, 0)
    t6_never := alloc_node(0, 0, 0, 0, 0, TY_NEVER, 0, 0, 0)
    t6_char := alloc_node(0, 0, 0, 0, 0, TY_CHAR, 0, 0, 0)
    t6_dyn := alloc_node(0, 0, 0, 0, 0, TI_DYN, 0, 0, 0)
    t6_dex_s := alloc_node(0, 0, 0, 0, 0, TY_DEX_S, 0, 0, 0)
    t6_oob := alloc_node(0, 0, 0, 0, 0, 999, 0, 0, 0)
    total = total + 1
    fails = fails + ts_check_b("t6.node_kinds",
        (ast_kind(t6_never) == 0 && ast_type_val(t6_never) == TY_NEVER &&
            ast_type_val(t6_dyn) == TI_DYN && ast_type_val(t6_dex_s) == TY_DEX_S), true)
    total = total + 1
    fails = fails + ts_check_b("t6.R_codes",
        (res_type_node(t6_int) == TI_INT && res_type_node(t6_dex) == TI_DEX &&
            res_type_node(t6_bool) == TI_BOOL && res_type_node(t6_str) == TI_STR &&
            res_type_node(t6_unit) == TI_UNIT && res_type_node(t6_never) == TI_NEVER &&
            res_type_node(t6_char) == TI_CHAR), true)
    total = total + 1
    fails = fails + ts_check_b("t6.C_codes",
        (res_call_type(t6_int, -1) == TI_INT && res_call_type(t6_dex, -1) == TI_DEX &&
            res_call_type(t6_bool, -1) == TI_BOOL && res_call_type(t6_str, -1) == TI_STR &&
            res_call_type(t6_unit, -1) == TI_UNIT && res_call_type(t6_char, -1) == TI_CHAR), true)
    // 两表唯一的语义差异在 NEVER：res_type_node 返回 TI_NEVER，res_call_type 落到 TI_UNIT。合表不得抹平这个差异。
    total = total + 1
    fails = fails + ts_check_b("t6.never_cell_diff",
        (res_type_node(t6_never) == TI_NEVER && res_call_type(t6_never, -1) == TI_UNIT), true)
    // 两表共有的码 7（dyn）都返回 TI_DYN。
    total = total + 1
    fails = fails + ts_check_b("t6.dyn_cell_both",
        (res_type_node(t6_dyn) == TI_DYN && res_call_type(t6_dyn, -1) == TI_DYN), true)
    // 域外码（TY_DEX_S 和未知码）在两表都落到 TI_UNIT，与改动前的尾回落相同。
    total = total + 1
    fails = fails + ts_check_b("t6.dex_s_oob_unit",
        (res_type_node(t6_dex_s) == TI_UNIT && res_call_type(t6_dex_s, -1) == TI_UNIT &&
            res_type_node(t6_oob) == TI_UNIT && res_call_type(t6_oob, -1) == TI_UNIT), true)
    total = total + 1
    fails = fails + ts_check_b("t6.neg_node_unit",
        (res_type_node(-1) == TI_UNIT && res_call_type(-1, -1) == TI_UNIT), true)

    // === 引擎展开层：named、struct、enum 和 generic-apply 到结构项 ===
    // 检查：
    // 1. 正向形态：字段声明顺序、变体数、泛型实参替换。
    // 2. 名义不变量：展开项结构相等，桥接项 ty_equiv 返回 -1，type_equal 返回 false。
    // 3. 缺口上抛：不可展开返回 -1，不得判否且不报错。
    // 4. 展开缓存：命中计数和失败不缓存。
    // 5. 域和模式项在穷尽性检查上的端到端行为。
    // 夹具全部是人造记录，本路径不经过 parser/check_all。声明表按 parser 的
    // 写槽顺序填写，类型节点按 parse_type 的产物形态构造。
    init_types()                    // 干净起点：类型表记录编号复位，九个原生记录在前。
    ty_budget_reset(200000)

    // 夹具 1：struct UnfBoxU[T] { val: T }。泛型字段是形参，用于检查实参替换；
    // 再构造两个应用记录。形参按 collect_decls 的方式登记为符号。生产路径的
    // struct 泛型形参必须在符号表里，res_type_node 通过 find_gsym 解析形参名。
    unf_gp := str_intern("UnfTGparamU")
    def_sym(unf_gp, SYM_TYPE, alloc_type(TYP_GENERIC_PARAM, unf_gp, 0), -1)
    unf_box_sa := add_struct("UnfBoxU")
    cell_store(g_structs, unf_box_sa * ESZ_STRUCTINFO + OFF_SI_GENERIC_COUNT, 1)
    cell_store(g_structs, unf_box_sa * ESZ_STRUCTINFO + OFF_SI_GENERIC_NAMES, unf_gp)
    si_set_field_name(unf_box_sa, 0, str_intern("val"))
    si_set_field_type(unf_box_sa, 0, 0)   // 裸码槽是 parser 对非基型的塌缩值（0 = TY_INT）；本层不读这个槽。
    si_set_field_type_node(unf_box_sa, 0,
        alloc_node(EXPR_IDENT, -1, -1, -1, unf_gp, 0, -1, 0, 0))
    cell_store(g_structs, unf_box_sa * ESZ_STRUCTINFO + OFF_SI_FIELD_COUNT, 1)
    unf_box_ti := alloc_named_type(str_intern("UnfBoxU"))
    // 应用记录 `UnfBoxU[int]` / `UnfBoxU[string]`（g_gen_apply_data: [count, arg]）
    grow_gen_apply_data(g_gen_apply_data_count + 2)
    unf_gas1 := g_gen_apply_data_count
    cell_store(g_gen_apply_data, unf_gas1 * 8, 1)
    cell_store(g_gen_apply_data, (unf_gas1 + 1) * 8, TI_INT)
    g_gen_apply_data_count = unf_gas1 + 2
    unf_ga_int := alloc_type(TYP_GENERIC_APPLY, unf_box_ti, unf_gas1)
    grow_gen_apply_data(g_gen_apply_data_count + 2)
    unf_gas2 := g_gen_apply_data_count
    cell_store(g_gen_apply_data, unf_gas2 * 8, 1)
    cell_store(g_gen_apply_data, (unf_gas2 + 1) * 8, TI_STR)
    g_gen_apply_data_count = unf_gas2 + 2
    unf_ga_str := alloc_type(TYP_GENERIC_APPLY, unf_box_ti, unf_gas2)
    unf_ta := sh_struct_term(unf_ga_int)
    unf_tb := sh_struct_term(unf_ga_str)
    total = total + 1
    fails = fails + ts_check_b("unf.ga_arg_subst",
        (tt_a(unf_ta) == AK_PRODUCT && tt_c(unf_ta) == tt_cons(tt_atom(AK_INT, TI_INT, -1), tt_nil()) &&
            tt_c(unf_tb) == tt_cons(tt_atom(AK_STRING, TI_STR, -1), tt_nil()) && unf_ta != unf_tb), true)
    // 未应用形态：泛型形参保持名义，res_type_node 取形参记录并返回 AK_NAMED，不得替换成 int。
    unf_tbare := sh_struct_term(unf_box_ti)
    total = total + 1
    fails = fails + ts_check_b("unf.ga_unapplied_nominal",
        (unf_tbare >= 0 && tt_a(unf_tbare) == AK_PRODUCT && tt_a(tt_a(tt_c(unf_tbare))) != AK_INT), true)

    // 夹具 2：struct UnfP1U { a: int, b: string }，检查字段声明顺序和两种基型。
    unf_p1_sa := add_struct("UnfP1U")
    si_set_field_name(unf_p1_sa, 0, str_intern("a"))
    si_set_field_type(unf_p1_sa, 0, TY_INT)
    si_set_field_type_node(unf_p1_sa, 0, alloc_node(0, 0, 0, 0, 0, TY_INT, 0, 0, 0))
    si_set_field_name(unf_p1_sa, 1, str_intern("b"))
    si_set_field_type(unf_p1_sa, 1, TY_STRING)
    si_set_field_type_node(unf_p1_sa, 1, alloc_node(0, 0, 0, 0, 0, TY_STRING, 0, 0, 0))
    cell_store(g_structs, unf_p1_sa * ESZ_STRUCTINFO + OFF_SI_FIELD_COUNT, 2)
    unf_p1_ti := alloc_named_type(str_intern("UnfP1U"))
    unf_tp1 := sh_struct_term(unf_p1_ti)
    total = total + 1
    fails = fails + ts_check_b("unf.struct_field_order",
        (tt_a(unf_tp1) == AK_PRODUCT &&
            tt_c(unf_tp1) == tt_cons(tt_atom(AK_INT, TI_INT, -1), tt_cons(tt_atom(AK_STRING, TI_STR, -1), tt_nil()))), true)
    // 夹具 3：struct UnfP2U { x: [int;2] }。字段裸码槽是 0（TY_INT），类型节点
    // 是数组。只读裸码槽的实现会把字段误判成 int；本用例检查这一点。
    unf_p2_sa := add_struct("UnfP2U")
    unf_arrn := alloc_node(EXPR_ARRAY, alloc_node(0, 0, 0, 0, 0, TY_INT, 0, 0, 0), -1, -1, 2, 0, -1, 0, 0)
    si_set_field_name(unf_p2_sa, 0, str_intern("x"))
    si_set_field_type(unf_p2_sa, 0, 0)
    si_set_field_type_node(unf_p2_sa, 0, unf_arrn)
    cell_store(g_structs, unf_p2_sa * ESZ_STRUCTINFO + OFF_SI_FIELD_COUNT, 1)
    unf_p2_ti := alloc_named_type(str_intern("UnfP2U"))
    unf_tp2 := sh_struct_term(unf_p2_ti)
    total = total + 1
    fails = fails + ts_check_b("unf.struct_field_node_not_code",
        (tt_a(unf_tp2) == AK_PRODUCT && tt_a(tt_a(tt_c(unf_tp2))) == AK_SEQUENCE), true)

    // 夹具 4：两个同形不同名的 struct（UnfS1U{a:int} 和 UnfS2U{a:int}）。
    // 三条断言：1. 展开项结构相等，这是满足判定的设计意图。2. 桥接项仍为 -1，
    // AK_NAMED 原子不展开，不得当成 0 或 1。3. type_equal 返回 false。
    unf_s1_ti := ts_unf_mk_int_struct("UnfS1U")
    unf_s2_ti := ts_unf_mk_int_struct("UnfS2U")
    unf_e1 := sh_struct_term(unf_s1_ti)
    unf_e2 := sh_struct_term(unf_s2_ti)
    total = total + 1
    fails = fails + ts_check_b("unf.nominal_structural_equal",
        (unf_e1 >= 0 && unf_e2 >= 0 && ty_equiv(unf_e1, unf_e2) == 1), true)
    // 命名类型接入引擎后，异名同形的两个命名类型由桥接项直接判 0，
    // 即确定不同，而不是未知。展开项结构相等仍由上一例检查。
    total = total + 1
    fails = fails + ts_check("unf.nominal_equiv_atomic_decided",
        ty_equiv(sh_term_of_ti(unf_s1_ti), sh_term_of_ti(unf_s2_ti)), 0)
    // type_equal 判 false，且不产生未知诊断。
    unf_d0 := g_diag_count
    unf_eqf : ., mut = 0
    if !type_equal(unf_s1_ti, unf_s2_ti):
        if g_diag_count == unf_d0:
            unf_eqf = 1
    total = total + 1
    fails = fails + ts_check("unf.nominal_type_equal_false", unf_eqf, 1)

    // 夹具 5：enum UnfColorU { UnfRedU, UnfGreenU, UnfBlueU }，三个只有标签的变体。
    unf_col_ei := add_enum("UnfColorU")
    ei_set_variant_name(unf_col_ei, 0, str_intern("UnfRedU"))
    ei_set_variant_name(unf_col_ei, 1, str_intern("UnfGreenU"))
    ei_set_variant_name(unf_col_ei, 2, str_intern("UnfBlueU"))
    cell_store(g_enums, unf_col_ei * ESZ_ENUMINFO + OFF_EI_VARIANT_COUNT, 3)
    unf_col_ti := alloc_named_type(str_intern("UnfColorU"))
    unf_dom := sh_enum_domain_term(unf_col_ti)
    total = total + 1
    fails = fails + ts_check_b("unf.enum_domain_count",
        (unf_dom >= 0 && ts_unf_union_leaves(unf_dom) == 3), true)
    unf_vr := sh_variant_term(unf_col_ti, str_intern("UnfRedU"))
    unf_vg := sh_variant_term(unf_col_ti, str_intern("UnfGreenU"))
    unf_vb := sh_variant_term(unf_col_ti, str_intern("UnfBlueU"))
    total = total + 1
    fails = fails + ts_check_b("unf.enum_variant_in_domain",
        (ty_sub(unf_vr, unf_dom) == 1 && ty_sub(unf_vg, unf_dom) == 1 && ty_sub(unf_vb, unf_dom) == 1 &&
            sh_variant_term(unf_col_ti, str_intern("UnfNoSuchVariantU")) == -1), true)
    // 变体身份包含枚举名。引擎只比较 a 和 c 两个槽，所以身份必须放进参数列表；不同枚举的同名变体不得判等价。
    unf_dup_ei := add_enum("UnfDupU")
    ei_set_variant_name(unf_dup_ei, 0, str_intern("UnfRedU"))
    cell_store(g_enums, unf_dup_ei * ESZ_ENUMINFO + OFF_EI_VARIANT_COUNT, 1)
    unf_dup_ti := alloc_named_type(str_intern("UnfDupU"))
    unf_vdup := sh_variant_term(unf_dup_ti, str_intern("UnfRedU"))
    total = total + 1
    fails = fails + ts_check_b("unf.enum_variant_identity_scoped",
        (unf_vdup >= 0 && ty_sub(unf_vdup, unf_vr) != 1 && ty_sub(unf_vr, unf_vdup) != 1), true)
    // 空枚举的域是底部。
    unf_emp_ei := add_enum("UnfEmptyU")
    cell_store(g_enums, unf_emp_ei * ESZ_ENUMINFO + OFF_EI_VARIANT_COUNT, 0)
    unf_emp_ti := alloc_named_type(str_intern("UnfEmptyU"))
    total = total + 1
    fails = fails + ts_check("unf.enum_empty_domain_bot", tt_tag(sh_enum_domain_term(unf_emp_ti)), TT_BOT)

    // 夹具 6：enum UnfOptU[T] { UnfNoneU, UnfSomeU(T) }，标签和携带值混合。
    // 用于检查域和模式项在穷尽性上的端到端行为。携带值槽按 parser 写裸码，
    // 非基型塌缩为 0，本层不读它；携带值不进入变体项，见 ty_shadow.cr
    // 展开段的说明。
    unf_opt_ei := add_enum("UnfOptU")
    cell_store(g_enums, unf_opt_ei * ESZ_ENUMINFO + OFF_EI_GENERIC_COUNT, 1)
    cell_store(g_enums, unf_opt_ei * ESZ_ENUMINFO + OFF_EI_GENERIC_NAMES, str_intern("UnfTOptU"))
    ei_set_variant_name(unf_opt_ei, 0, str_intern("UnfNoneU"))
    ei_set_variant_name(unf_opt_ei, 1, str_intern("UnfSomeU"))
    ei_set_variant_type_count(unf_opt_ei, 1, 1)
    ei_set_variant_type(unf_opt_ei, 1, 0, TY_INT)   // 裸码槽（parser 事实；本层不读）
    cell_store(g_enums, unf_opt_ei * ESZ_ENUMINFO + OFF_EI_VARIANT_COUNT, 2)
    unf_opt_ti := alloc_named_type(str_intern("UnfOptU"))
    unf_odom := sh_enum_domain_term(unf_opt_ti)
    unf_onone := sh_variant_term(unf_opt_ti, str_intern("UnfNoneU"))
    unf_osome := sh_variant_term(unf_opt_ti, str_intern("UnfSomeU"))
    total = total + 1
    fails = fails + ts_check("unf.exhaust_cover_all",
        ty_exhaustive(unf_odom, tt_cons(unf_onone, tt_cons(unf_osome, tt_nil()))), 1)
    total = total + 1
    fails = fails + ts_check("unf.exhaust_missing_one",
        ty_exhaustive(unf_odom, tt_cons(unf_onone, tt_nil())), 0)
    // 缺失变体的 witness 不可为空，且必须是缺失变体的子类型。原始 witness
    // 是各析取支的并，包含空析取支，norm 不清理空支。若把它当具体反例值
    // 使用，必须先取有值的支。
    unf_w2 := ty_exhaust_witness(unf_odom, tt_cons(unf_onone, tt_nil()))
    total = total + 1
    fails = fails + ts_check_b("unf.exhaust_witness_subset",
        (unf_w2 >= 0 && ty_inhabited(unf_w2) == 1 && ty_sub(unf_w2, unf_osome) == 1), true)

    // 展开缓存：新记录恰好加入一项；第二次调用命中一次并返回同一项；失败不缓存，-1 不加入表。
    unf_fresh := ts_unf_mk_int_struct("UnfCacheU")
    unf_ce0 := sh_unf_entries()
    unf_ch0 := sh_unf_hits()
    unf_ct1 := sh_struct_term(unf_fresh)
    unf_ce1 := sh_unf_entries()
    unf_ct2 := sh_struct_term(unf_fresh)
    unf_fail_e0 := sh_unf_entries()
    sh_struct_term(g_type_count + 7)
    total = total + 1
    fails = fails + ts_check_b("unf.cache_hit_and_no_neg_cache",
        ((unf_ce1 - unf_ce0) == 1 && (sh_unf_hits() - unf_ch0) == 1 && unf_ct2 == unf_ct1 &&
            (sh_unf_entries() - unf_fail_e0) == 0), true)

    // 缺口上抛：记录编号越界、未声明名字、裸泛型形参、非枚举变体名都返回 -1。
    unf_plain_ti := alloc_named_type(str_intern("UnfNoDeclU"))
    unf_loose_gp := alloc_type(TYP_GENERIC_PARAM, str_intern("UnfLooseTU"), 0)
    total = total + 1
    fails = fails + ts_check_b("unf.neg_paths",
        (sh_struct_term(g_type_count + 7) == -1 && sh_enum_domain_term(g_type_count + 7) == -1 &&
            sh_struct_term(-1) == -1 && sh_variant_term(-1, 0) == -1 && sh_variant_term(unf_col_ti, -1) == -1 &&
            sh_struct_term(unf_plain_ti) == -1 && sh_enum_domain_term(unf_plain_ti) == -1 &&
            sh_struct_term(unf_loose_gp) == -1), true)

    // 接口数据的负键检查：形状项构造仍返回占位 -1。负键和未知名键都返回
    // -1，消费方不得把它当 0 或 1。
    total = total + 1
    fails = fails + ts_check_b("unf.iface_stub_three_state",
        (sh_iface_shape_term(-1) == -1 && iface_satisfies(-1, 0) == -1 && iface_satisfies(TI_INT, 9999) == -1), true)

    // === 定长数组和切片的方向规则、变型表、N 读取路径 ===
    // 检查：
    // 1. 方向：[T;N] <: [T] 放行；[T] ⊄ [T;N] 拒绝，结果为 0 而不是 -1。
    // 2. 变型：只读协变通过，可写不变拒绝；mut 标记是判定维度，&T 和 &mut T
    //    双向不等价。
    // 3. N 读取：身份路径和子类型路径都不含 N；[int;3] 与 [int;4] 的项除 b 槽外
    //    逐位相同，拒绝只来自常量档约束。
    // 4. 嵌套位置：指针元素、元组字段、泛型实参、数组元素逐位同规则。
    // 5. 动态档：视图运行期长度不可证，结果为 0，不得用 -1 代替决定。
    // 固定性存在序列项的 b 槽，b 是标注，不进入引擎比较。方向不在引擎 ty_sub
    // 中判定，而在 checker 的 array_len_constraint_ok 中判定，参数顺序是
    // （源，目标）。本组方向断言直接调用该函数和 type_compat_strict。
    ty_budget_reset(200000)
    t1_arr3 := alloc_type(TYP_ARRAY, TI_INT, 3)
    t1_arr4 := alloc_type(TYP_ARRAY, TI_INT, 4)
    t1_sl := alloc_type(TYP_SLICE, TI_INT, 0)
    t1_sl2 := alloc_type(TYP_SLICE, TI_INT, 0)      // 另一条同形切片记录：方向规则不能依赖记录编号相同。
    // 1. 顶层方向：固定到视图放行；视图到固定拒绝，结果为 0；视图到视图且元素相同放行。
    total = total + 1
    fails = fails + ts_check("t1.dir_arr_to_slice_ok",
        array_len_constraint_ok(t1_arr3, t1_sl), 1)
    total = total + 1
    fails = fails + ts_check("t1.dir_slice_to_arr_reject",
        array_len_constraint_ok(t1_sl, t1_arr3), 0)
    total = total + 1
    fails = fails + ts_check("t1.dir_slice_slice_ok",
        array_len_constraint_ok(t1_sl, t1_sl2), 1)
    // 2. N 不属于身份：同固定性异长度时，引擎等价返回 1，常量档拒绝返回 0。
    total = total + 1
    fails = fails + ts_check_b("t1.dir_fixed_two_lengths_identity",
        (ty_equiv(sh_term_of_ti(t1_arr3), sh_term_of_ti(t1_arr4)) == 1 &&
            array_len_constraint_ok(t1_arr4, t1_arr3) == 0), true)
    // 3. 嵌套位置逐位同规则。反向拓宽必须仍放行，防止规则退化成一律拒绝。
    t1_pt_sl := alloc_type(TYP_PTR, t1_sl, 0)
    t1_pt_arr := alloc_type(TYP_PTR, t1_arr3, 0)
    total = total + 1
    fails = fails + ts_check_b("t1.dir_nested_ptr",
        (array_len_constraint_ok(t1_pt_sl, t1_pt_arr) == 0 && array_len_constraint_ok(t1_pt_arr, t1_pt_sl) == 1), true)
    t1_out_sl := alloc_type(TYP_ARRAY, t1_sl, 2)       // [[int];2]
    t1_out_arr := alloc_type(TYP_ARRAY, t1_arr3, 2)    // [[int;3];2]
    total = total + 1
    fails = fails + ts_check_b("t1.dir_nested_elem",
        (array_len_constraint_ok(t1_out_sl, t1_out_arr) == 0 && array_len_constraint_ok(t1_out_arr, t1_out_sl) == 1), true)
    grow_gen_apply_data(g_gen_apply_data_count + 4)
    t1_tp_s1 := g_gen_apply_data_count
    cell_store(g_gen_apply_data, t1_tp_s1 * 8, TI_INT)
    cell_store(g_gen_apply_data, (t1_tp_s1 + 1) * 8, t1_sl)
    t1_tp_s2 := t1_tp_s1 + 2
    cell_store(g_gen_apply_data, t1_tp_s2 * 8, TI_INT)
    cell_store(g_gen_apply_data, (t1_tp_s2 + 1) * 8, t1_arr3)
    g_gen_apply_data_count = t1_tp_s2 + 2
    t1_tup_sl := alloc_type(TYP_TUPLE, 2, t1_tp_s1)     // (int, [int])
    t1_tup_arr := alloc_type(TYP_TUPLE, 2, t1_tp_s2)    // (int, [int;3])
    total = total + 1
    fails = fails + ts_check_b("t1.dir_nested_tuple",
        (array_len_constraint_ok(t1_tup_sl, t1_tup_arr) == 0 && array_len_constraint_ok(t1_tup_arr, t1_tup_sl) == 1), true)
    grow_gen_apply_data(g_gen_apply_data_count + 4)
    t1_ga_s1 := g_gen_apply_data_count
    cell_store(g_gen_apply_data, t1_ga_s1 * 8, 1)
    cell_store(g_gen_apply_data, (t1_ga_s1 + 1) * 8, t1_sl)
    t1_ga_s2 := t1_ga_s1 + 2
    cell_store(g_gen_apply_data, t1_ga_s2 * 8, 1)
    cell_store(g_gen_apply_data, (t1_ga_s2 + 1) * 8, t1_arr3)
    g_gen_apply_data_count = t1_ga_s2 + 2
    t1_base := alloc_type(TYP_NAMED, 1203, 0)           // 人造基类型记录，裸分配，避免假键破坏 name->ti 映射。
    t1_ga_sl := alloc_type(TYP_GENERIC_APPLY, t1_base, t1_ga_s1)
    t1_ga_arr := alloc_type(TYP_GENERIC_APPLY, t1_base, t1_ga_s2)
    total = total + 1
    fails = fails + ts_check_b("t1.dir_nested_genapply",
        (array_len_constraint_ok(t1_ga_sl, t1_ga_arr) == 0 && array_len_constraint_ok(t1_ga_arr, t1_ga_sl) == 1), true)
    // 4. 站点判定：拓宽返回 1；视图到固定返回 -1；对称检查两层都返回 1。
    total = total + 1
    fails = fails + ts_check("t1.strict_widen_ok",
        type_compat_strict(t1_arr3, t1_sl), 1)
    total = total + 1
    fails = fails + ts_check("t1.strict_view_to_fixed",
        type_compat_strict(t1_sl, t1_arr3), -1)
    total = total + 1
    fails = fails + ts_check_b("t1.strict_sym_no_direction",
        (type_compat_sym(t1_sl, t1_arr3) == 1 && type_compat_sym(t1_arr3, t1_sl) == 1), true)
    // 5. 变型：只读协变通过，可写不变拒绝。AK_REF 槽 1 是条件变型；表外构造子默认不变。
    t1_u := tt_union(tt_atom(AK_INT, TI_INT, -1), tt_atom(AK_STRING, TI_STR, -1))   // int ∪ string
    t1_rv_ro := tt_atom(AK_REF, -1, tt_cons(sh_ref_mut_marker(0), tt_cons(tt_atom(AK_INT, TI_INT, -1), tt_nil())))
    t1_rv_ro_w := tt_atom(AK_REF, -1, tt_cons(sh_ref_mut_marker(0), tt_cons(t1_u, tt_nil())))
    t1_rv_mut := tt_atom(AK_REF, -1, tt_cons(sh_ref_mut_marker(1), tt_cons(tt_atom(AK_INT, TI_INT, -1), tt_nil())))
    t1_rv_mut_w := tt_atom(AK_REF, -1, tt_cons(sh_ref_mut_marker(1), tt_cons(t1_u, tt_nil())))
    total = total + 1
    fails = fails + ts_check_b("t1.var_readonly_covariant",
        (ty_sub(t1_rv_ro, t1_rv_ro_w) == 1 && ty_sub(t1_rv_ro_w, t1_rv_ro) == 0), true)
    // 不变槽的判定语义是“不是子类型”。引擎返回 -1，表示未实现，而不是
    // 确定不等价。两向都不得判 1；生产路径的 type_equal 在此返回 false，
    // 实际拒绝。
    total = total + 1
    fails = fails + ts_check_b("t1.var_mut_invariant_reject",
        (ty_sub(t1_rv_mut, t1_rv_mut_w) != 1 && ty_sub(t1_rv_mut_w, t1_rv_mut) != 1), true)
    total = total + 1
    fails = fails + ts_check_b("t1.var_seq_elem_invariant",
        (ty_sub(tt_atom(AK_SEQUENCE, -1, tt_cons(tt_atom(AK_INT, TI_INT, -1), tt_nil())),
                tt_atom(AK_SEQUENCE, -1, tt_cons(t1_u, tt_nil()))) != 1), true)
    // 6. mut 标记进入序列后成为判定维度，走真实桥接：&T 和 &mut T 双向不等价；同 mut 同元素仍等价。
    t1_ref_ro := alloc_type(TYP_REF, TI_INT, 0)
    t1_ref_ro2 := alloc_type(TYP_REF, TI_INT, 0)
    t1_ref_mut := alloc_type(TYP_REF, TI_INT, 1)
    total = total + 1
    fails = fails + ts_check_b("t1.var_mut_marker_dimension",
        (ty_equiv(sh_term_of_ti(t1_ref_ro), sh_term_of_ti(t1_ref_mut)) == 0 &&
            ty_equiv(sh_term_of_ti(t1_ref_mut), sh_term_of_ti(t1_ref_ro)) == 0 &&
            ty_equiv(sh_term_of_ti(t1_ref_ro), sh_term_of_ti(t1_ref_ro2)) == 1 &&
            tt_b(tt_a(tt_c(sh_term_of_ti(t1_ref_mut)))) == 1), true)
    // 7. N 读取路径：身份路径 ty_equiv 和子类型路径 ty_sub 都不含 N；唯一拒绝来源是常量档。
    total = total + 1
    fails = fails + ts_check_b("t1.n_face_gate",
        (type_equal(t1_arr3, t1_arr4) &&
            ty_sub(sh_term_of_ti(t1_arr3), sh_term_of_ti(t1_arr4)) == 1 &&
            array_len_constraint_ok(t1_arr4, t1_arr3) == 0), true)
    // 8. 动态档：切片运行期长度不可证，视图到固定是确定拒绝 0，不得返回 -1；
    // 异长固定档同理。
    total = total + 1
    fails = fails + ts_check_b("t1.dyn_tier_decided",
        (array_len_constraint_ok(t1_sl, t1_arr3) == 0 && array_len_constraint_ok(t1_sl2, t1_arr4) == 0 &&
            array_len_constraint_ok(t1_arr3, t1_arr4) == 0), true)
    // 9. 嵌套位置的身份不变量和站点判定。序列项的固定性位 b 不能通过
    // 嵌套元素进入身份；引擎比较序列项时忽略 b。三条断言：
    // 1. 嵌套 N 仍等价，且不触发未知。
    // 2. 嵌套固定性不进入身份，ty_equiv 两向返回 1。
    // 3. 站点层：嵌套视图到固定返回 -1，嵌套固定到视图返回 1。
    t1_out_arr4 := alloc_type(TYP_ARRAY, t1_arr4, 2)   // [[int;4];2]
    // 不产生未知诊断。
    t1_d0 := g_diag_count
    t1_nest_ok : ., mut = 0
    if type_equal(t1_out_arr, t1_out_arr4):
        if g_diag_count == t1_d0:
            t1_nest_ok = 1
    total = total + 1
    fails = fails + ts_check_b("t1.n_face_gate_nested",
        (t1_nest_ok == 1 && array_len_constraint_ok(t1_out_arr4, t1_out_arr) == 0), true)
    total = total + 1
    fails = fails + ts_check("t1.fixedness_not_identity_nested",
        ty_equiv(sh_term_of_ti(t1_out_sl), sh_term_of_ti(t1_out_arr)), 1)
    total = total + 1
    fails = fails + ts_check_b("t1.dir_nested_strict",
        (type_compat_strict(t1_out_sl, t1_out_arr) == -1 && type_compat_strict(t1_out_arr, t1_out_sl) == 1), true)

    // === match 穷尽性判定：补集为空和具体变体反例 ===
    // 检查：
    // 1. 引擎判定：全覆盖、缺一、无臂、通配覆盖、单变体。
    // 2. 反例的具体值是缺失变体名。引擎的原始 witness 包含空析取支，
    //    和缺失变体按 ty_equiv 不等；本组第 3 例固定这个事实和消费点的命名。
    // 3. 域检查和不可映射检查：-1 表示不判，不得当成 0 或 1。
    // 4. 空枚举域按补集语义是空洞穷尽。
    // 5. 携带值变体混合、限定名解析、重复臂、泛型应用记录。
    // The fixture writes records by hand in the parser's slot order. Raw payload
    // code slots follow parser facts.
    init_types()
    ty_budget_reset(200000)
    t3_col_ei := add_enum("T3Color")
    ei_set_variant_name(t3_col_ei, 0, str_intern("T3Red"))
    ei_set_variant_name(t3_col_ei, 1, str_intern("T3Green"))
    ei_set_variant_name(t3_col_ei, 2, str_intern("T3Blue"))
    cell_store(g_enums, t3_col_ei * ESZ_ENUMINFO + OFF_EI_VARIANT_COUNT, 3)
    t3_col_ti := alloc_named_type(str_intern("T3Color"))
    t3_r := sh_match_variant_term(t3_col_ti, 0)
    t3_g := sh_match_variant_term(t3_col_ti, 1)
    t3_b := sh_match_variant_term(t3_col_ti, 2)
    // 1. 全覆盖返回 1：模式项和域项由同一构造生成，补集为空。
    total = total + 1
    fails = fails + ts_check("t3.cover_all",
        sh_match_exhaustive(t3_col_ti, tt_cons(t3_r, tt_cons(t3_g, tt_cons(t3_b, tt_nil()))), 0), 1)
    // 2. 缺一个变体返回 0；反例是缺失变体名，同时检查引擎判定和覆盖位命名。
    t3_ab := tt_cons(t3_r, tt_cons(t3_g, tt_nil()))
    total = total + 1
    fails = fails + ts_check("t3.missing_one_verdict",
        sh_match_exhaustive(t3_col_ti, t3_ab, 0), 0)
    t3_w := ty_exhaust_witness(sh_enum_domain_term(t3_col_ti), t3_ab)
    t3_cx := sh_match_first_missing(sh_match_bit(0) + sh_match_bit(1), ei_variant_count(t3_col_ei))
    t3_cx_named : ., mut = 0
    if t3_cx == 2:
        if str_eq(istr_get(ei_variant_name(t3_col_ei, t3_cx)), "T3Blue") != 0:
            t3_cx_named = 1
    // 引擎的原始 witness 是包含空析取支的并集。它与缺失变体的关系是：
    // ty_sub(w, b) = 1；反向 ty_sub(b, w) = -1，因为空析取支使反向结构比较
    // 落空；ty_equiv 也返回 -1，不是 0。按判定约定，-1 不得当成 0。可空为 1。
    // 因此具体反例值由覆盖位命名提供，引擎 witness 项不作为显示名。
    total = total + 1
    fails = fails + ts_check_b("t3.counterexample_named_variant",
        (t3_w >= 0 && ty_inhabited(t3_w) == 1 && ty_sub(t3_w, t3_b) == 1 && t3_cx_named), true)
    // 变体项是 AK_SUM 序列 [枚举名令牌, 变体名令牌]。两个令牌按节点
    // 同一性判为确定不同 0。t3_w 是包含两个空析取支的并：
    // q1 = R∩¬R∩¬G，q2 = G∩¬R∩¬G，二者都为空；q3 = B∩¬R∩¬G = B。
    // B 与 q1 的 lit_implies 在令牌不变槽上曾经返回未知，同类令牌判断
    // 加入后返回 0，外层并分支也返回 0，所以 B ⊆ t3_w 成立。
    // 下面的三个断言固定这个行为。
    total = total + 1
    fails = fails + ts_check("t3.witness_reverse_over_claim", ty_sub(t3_b, t3_w), 1)
    total = total + 1
    fails = fails + ts_check("t3.witness_equiv_over_claim", ty_equiv(t3_w, t3_b), 1)
    // 同一范围的最小复现（单点断言：`B ⊆ B ∩ ¬R` ⟺ `B ⊆ ¬R`）
    total = total + 1
    fails = fails + ts_check("t3.product_neg_over_claim",
        ty_sub(t3_b, tt_inter(t3_b, tt_not(t3_r))), 1)
    // 3. 通配和绑定等于 top，覆盖一切。
    total = total + 1
    fails = fails + ts_check("t3.wildcard_absorbs",
        sh_match_exhaustive(t3_col_ti, tt_cons(tt_top(), tt_nil()), 0), 1)
    // 4. 单变体枚举：有臂返回 1，无臂返回 0，空序列的补集是全域。
    t3_only_ei := add_enum("T3Only")
    ei_set_variant_name(t3_only_ei, 0, str_intern("T3One"))
    cell_store(g_enums, t3_only_ei * ESZ_ENUMINFO + OFF_EI_VARIANT_COUNT, 1)
    t3_only_ti := alloc_named_type(str_intern("T3Only"))
    t3_one := sh_match_variant_term(t3_only_ti, 0)
    total = total + 1
    fails = fails + ts_check("t3.single_variant_covered",
        sh_match_exhaustive(t3_only_ti, tt_cons(t3_one, tt_nil()), 0), 1)
    total = total + 1
    fails = fails + ts_check_b("t3.no_arms_not_exhaustive",
        (sh_match_exhaustive(t3_only_ti, tt_nil(), 0) == 0 && sh_match_first_missing(0, 1) == 0), true)
    // 5. 域检查和不可映射检查：非枚举 scrutinee 或不可映射模式返回 -1，不得当成 0 或 1。
    t3_s_ti := ts_unf_mk_int_struct("T3StrU")
    total = total + 1
    fails = fails + ts_check_b("t3.domain_guard_unknown",
        (sh_match_exhaustive(TI_INT, tt_nil(), 0) == -1 && sh_match_exhaustive(t3_s_ti, tt_nil(), 0) == -1 &&
            sh_match_exhaustive(-1, tt_nil(), 0) == -1 && sh_enum_domain_term(t3_s_ti) == -1), true)
    total = total + 1
    fails = fails + ts_check("t3.unmappable_guard_unknown",
        sh_match_exhaustive(t3_col_ti, tt_cons(t3_r, tt_cons(t3_g, tt_cons(t3_b, tt_nil()))), 1), -1)
    // 6. 空枚举的域是底部，补集语义下空洞穷尽：没有值可漏，也没有反例。
    t3_emp_ei := add_enum("T3Empty")
    cell_store(g_enums, t3_emp_ei * ESZ_ENUMINFO + OFF_EI_VARIANT_COUNT, 0)
    t3_emp_ti := alloc_named_type(str_intern("T3Empty"))
    total = total + 1
    fails = fails + ts_check_b("t3.empty_domain_vacuous",
        (sh_match_exhaustive(t3_emp_ti, tt_nil(), 0) == 1 && sh_match_first_missing(0, 0) == -1), true)
    // 7. 携带值变体和标签变体混合。携带值不进入项，变体身份按标签粒度；覆盖语义不受影响。
    t3_mix_ei := add_enum("T3Mix")
    ei_set_variant_name(t3_mix_ei, 0, str_intern("T3None"))
    ei_set_variant_name(t3_mix_ei, 1, str_intern("T3Some"))
    ei_set_variant_type_count(t3_mix_ei, 1, 1)
    ei_set_variant_type(t3_mix_ei, 1, 0, TY_INT)
    cell_store(g_enums, t3_mix_ei * ESZ_ENUMINFO + OFF_EI_VARIANT_COUNT, 2)
    t3_mix_ti := alloc_named_type(str_intern("T3Mix"))
    t3_none := sh_match_variant_term(t3_mix_ti, 0)
    t3_some := sh_match_variant_term(t3_mix_ti, 1)
    total = total + 1
    fails = fails + ts_check_b("t3.payload_mixed_cover",
        (t3_none >= 0 && t3_some >= 0 && t3_none != t3_some &&
            sh_match_exhaustive(t3_mix_ti, tt_cons(t3_some, tt_cons(t3_none, tt_nil())), 0) == 1 &&
            sh_match_exhaustive(t3_mix_ti, tt_cons(t3_none, tt_nil()), 0) == 0 &&
            sh_match_first_missing(sh_match_bit(0), 2) == 1), true)
    // 8. 模式名解析：限定名 Enum.Variant 和裸名结果相同；异枚举前缀或
    // 未声明名返回 -1。类别分类：通配和绑定是 top，枚举模式是变体，
    // 字面量和负节点不可映射。
    t3_pat_q := alloc_node(EXPR_ENUMPAT, str_intern("T3Color.T3Blue"), 0, 0, 0, 0, 0, 0, 0)
    t3_pat_b := alloc_node(EXPR_ENUMPAT, str_intern("T3Blue"), 0, 0, 0, 0, 0, 0, 0)
    t3_pat_f := alloc_node(EXPR_ENUMPAT, str_intern("T3Mix.T3Blue"), 0, 0, 0, 0, 0, 0, 0)
    t3_pat_n := alloc_node(EXPR_ENUMPAT, str_intern("T3Nope"), 0, 0, 0, 0, 0, 0, 0)
    t3_pat_w := alloc_node(EXPR_WILDCARD, 0, 0, 0, 0, 0, 0, 0, 0)
    t3_pat_l := alloc_node(EXPR_INT, 0, 0, 0, 5, TY_INT, 0, 0, 0)
    t3_pat_i := alloc_node(EXPR_IDENT, 0, 0, 0, str_intern("t3bind"), 0, 0, 0, 0)
    total = total + 1
    fails = fails + ts_check_b("t3.pat_name_resolution",
        (sh_match_pat_variant(t3_col_ti, t3_pat_q) == 2 && sh_match_pat_variant(t3_col_ti, t3_pat_b) == 2 &&
            sh_match_pat_variant(t3_col_ti, t3_pat_f) == -1 && sh_match_pat_variant(t3_col_ti, t3_pat_n) == -1 &&
            sh_match_pat_variant(t3_col_ti, t3_pat_w) == -1 && sh_match_pat_variant(t3_s_ti, t3_pat_b) == -1), true)
    total = total + 1
    fails = fails + ts_check_b("t3.pat_kind_classification",
        (sh_match_pat_kind(t3_pat_w) == 1 && sh_match_pat_kind(t3_pat_i) == 1 &&
            sh_match_pat_kind(t3_pat_q) == 2 && sh_match_pat_kind(t3_pat_l) == 0 &&
            sh_match_pat_kind(-1) == 0), true)
    // 9. 重复臂不增加覆盖范围：补集仍为空；覆盖位去重在 checker 收集时完成。
    // 该臂的冗余由行为集固定。
    total = total + 1
    fails = fails + ts_check_b("t3.dup_arm_complement",
        (sh_match_exhaustive(t3_only_ti, tt_cons(t3_one, tt_cons(t3_one, tt_nil())), 0) == 1 &&
            sh_match_first_missing(sh_match_bit(0), 3) == 1), true)
    // 10. 泛型应用记录 T3GOpt[int]：域可展开，全覆盖返回 1，变体身份与实参无关。
    t3_go_ei := add_enum("T3GOpt")
    cell_store(g_enums, t3_go_ei * ESZ_ENUMINFO + OFF_EI_GENERIC_COUNT, 1)
    cell_store(g_enums, t3_go_ei * ESZ_ENUMINFO + OFF_EI_GENERIC_NAMES, str_intern("T3GT"))
    ei_set_variant_name(t3_go_ei, 0, str_intern("T3GN"))
    ei_set_variant_name(t3_go_ei, 1, str_intern("T3GS"))
    ei_set_variant_type_count(t3_go_ei, 1, 1)
    ei_set_variant_type(t3_go_ei, 1, 0, 0)
    cell_store(g_enums, t3_go_ei * ESZ_ENUMINFO + OFF_EI_VARIANT_COUNT, 2)
    t3_go_ti := alloc_named_type(str_intern("T3GOpt"))
    grow_gen_apply_data(g_gen_apply_data_count + 2)
    t3_gas := g_gen_apply_data_count
    cell_store(g_gen_apply_data, t3_gas * 8, 1)
    cell_store(g_gen_apply_data, (t3_gas + 1) * 8, TI_INT)
    g_gen_apply_data_count = t3_gas + 2
    t3_go_ga := alloc_type(TYP_GENERIC_APPLY, t3_go_ti, t3_gas)
    t3_gn := sh_match_variant_term(t3_go_ga, 0)
    t3_gs := sh_match_variant_term(t3_go_ga, 1)
    total = total + 1
    fails = fails + ts_check_b("t3.generic_apply_domain",
        (t3_gn >= 0 && t3_gs >= 0 &&
            sh_match_exhaustive(t3_go_ga, tt_cons(t3_gn, tt_cons(t3_gs, tt_nil())), 0) == 1 &&
            sh_match_exhaustive(t3_go_ga, tt_cons(t3_gn, tt_nil()), 0) == 0), true)

    // === 联合和可选：T? = T ∪ null；内建 Option 不再注册 ===
    // 检查：
    // 1. 项层：T? 记录译成 union(内层项, null 原子项)，与独立构造的并项等价。
    // 2. 子类型、不相交、可空：None ⊆ T?，Some(1) ⊆ int?，null 与 int 不相交，
    //    也与 unit 和 never 不相交；null 有值。
    // 3. null 记录规范化：两个出现点译成同一项，不分裂。
    // 4. 判定点方向：T ⊆ T? 放行，T? ⊄ T 拒绝。
    // 5. match 域：两个分支，有值和 None；检查反例命名、通配覆盖、
    //    不可映射和非可选域。
    // 6. 枚举携带值类型节点列：裸码塌缩为 0（TY_INT），节点列才是携带值的
    //    真实类型；本组用码说是 int、节点说是 string 的反向夹具固定节点列读取。
    // 7. Option 不再注册：没有命名记录，AK_NULL 没有注册表条目。
    // 夹具：记录用 alloc_type 和 alloc_named_type 构造；枚举表按 parser 写槽
    // 顺序人工填写，两列都写。
    init_types()
    ty_budget_reset(200000)
    t4_null := alloc_type(TYP_NULL, 0, 0)            // None 的类型表记录，每个出现点一条。
    t4_null2 := alloc_type(TYP_NULL, 0, 0)           // 第二个出现点（规范化判断用）
    t4_int_opt := alloc_type(TYP_OPTIONAL, TI_INT, 0)
    t4_str_opt := alloc_type(TYP_OPTIONAL, TI_STR, 0)
    t4_intt := sh_term_of_ti(TI_INT)
    t4_nullt := sh_null_term()
    t4_optt := sh_term_of_ti(t4_int_opt)
    // 1. 项层：int? 的项等于 int ∪ null，且不等于裸 int。
    total = total + 1
    fails = fails + ts_check_b("t4.opt_term_is_union",
        (ty_equiv(t4_optt, tt_union(t4_intt, t4_nullt)) == 1 &&
            ty_equiv(t4_optt, t4_intt) == 0 && ty_sub(t4_intt, t4_optt) == 1), true)
    // 2. 子类型、不相交、可空。
    total = total + 1
    fails = fails + ts_check_b("t4.none_sub_optional",
        (ty_sub(t4_nullt, t4_optt) == 1 && ty_sub(t4_nullt, sh_term_of_ti(t4_str_opt)) == 1 &&
            ty_sub(t4_optt, t4_nullt) == 0 && ty_sub(t4_optt, t4_intt) == 0), true)
    total = total + 1
    fails = fails + ts_check_b("t4.some_sub_optional",
        (ty_equiv(sh_term_of_ti(alloc_type(TYP_OPTIONAL, TI_INT, 0)), t4_optt) == 1), true)
    total = total + 1
    fails = fails + ts_check_b("t4.null_disjoint_and_inhabited",
        (ty_disjoint(t4_nullt, t4_intt) == 1 && ty_disjoint(t4_nullt, sh_term_of_ti(TI_UNIT)) == 1 &&
            ty_disjoint(t4_nullt, sh_term_of_ti(TI_NEVER)) == 1 && ty_disjoint(t4_nullt, t4_nullt) == 0 &&
            ty_inhabited(t4_nullt) == 1), true)
    // 3. null 记录规范化：两个出现点译成同一项，节点相同，互相包含。
    total = total + 1
    fails = fails + ts_check_b("t4.null_row_canonical",
        (sh_term_of_ti(t4_null) == sh_term_of_ti(t4_null2) &&
            ty_sub(sh_term_of_ti(t4_null), sh_term_of_ti(t4_null2)) == 1), true)
    // 4. 判定点方向：T ⊆ T? 放行，反向拒绝，异型拒绝；同型走身份路径。
    total = total + 1
    fails = fails + ts_check_b("t4.sub_injection_asymmetry",
        (type_compat_strict(TI_INT, t4_int_opt) == 1 && type_compat_strict(t4_int_opt, TI_INT) == 0 &&
            type_compat_strict(TI_STR, t4_int_opt) == 0 && type_compat_strict(t4_null, t4_int_opt) == 1 &&
            type_compat_strict(t4_int_opt, t4_int_opt) == 1 && type_compat_strict(TI_INT, t4_str_opt) == 0), true)
    // 5. 注册表和许可：null 和可选记录都不是单一原子类，iface_kind_of
    // 返回 -1。AK_NULL 有第 14 条条目，但 ops = 0，操作检查全部拒绝。
    // 条目数从 13 增加到 16。
    total = total + 1
    fails = fails + ts_check_b("t4.null_no_ops_no_entry",
        (iface_kind_of(t4_null) == -1 && iface_kind_of(t4_int_opt) == -1 &&
            iface_permits(-1, OP_ADD) == 0 && iface_entry(AK_NULL) >= 0 &&
            iface_ops(AK_NULL) == 0 && iface_permits(AK_NULL, OP_ADD) == 0 && iface_count() == 16), true)
    // 6. AK_NULL 的互斥规则：对 13 个类逐类检查。除 AK_DYN（top，相容）和自身外都不相交。
    t4_dj : ., mut = 0
    t4_k : ., mut = 0
    t4_aks := alloc(13 * 8)
    cell_store(t4_aks, 0 * 8, AK_INT)
    cell_store(t4_aks, 1 * 8, AK_DEX)
    cell_store(t4_aks, 2 * 8, AK_STRING)
    cell_store(t4_aks, 3 * 8, AK_BOOL)
    cell_store(t4_aks, 4 * 8, AK_UNIT)
    cell_store(t4_aks, 5 * 8, AK_NEVER)
    cell_store(t4_aks, 6 * 8, AK_CHAR)
    cell_store(t4_aks, 7 * 8, AK_DYN)
    cell_store(t4_aks, 8 * 8, AK_PRODUCT)
    cell_store(t4_aks, 9 * 8, AK_SUM)
    cell_store(t4_aks, 10 * 8, AK_SEQUENCE)
    cell_store(t4_aks, 11 * 8, AK_REF)
    cell_store(t4_aks, 12 * 8, AK_PTR)
    loop:
        if t4_k >= 13:
            break
        ka := cell_load(t4_aks, t4_k * 8)
        want : ., mut = 1
        if ka == AK_DYN:
            want = 0
        // AK_DYN 是 top，与一切相容，包括 null。
        if ak_disjoint(AK_NULL, ka) != want:
            t4_dj = t4_dj + 1
        t4_k = t4_k + 1
    total = total + 1
    fails = fails + ts_check_b("t4.ak_null_disjoint_table",
        (t4_dj == 0 && ak_disjoint(AK_NULL, AK_NULL) == 0 && ak_disjoint(AK_NULL, AK_NAMED) == 1), true)
    // 7. Optional match domain: two branches, Some (has a value) and None (null).
    t4_some_pat := alloc_node(EXPR_ENUMPAT, str_intern("Some"), 0, 0, 0, 0, 0, 0, 0)
    t4_none_pat := alloc_node(EXPR_ENUMPAT, str_intern("None"), 0, 0, 0, 0, 0, 0, 0)
    t4_other_pat := alloc_node(EXPR_ENUMPAT, str_intern("Red"), 0, 0, 0, 0, 0, 0, 0)
    t4_qual_pat := alloc_node(EXPR_ENUMPAT, str_intern("Option.Some"), 0, 0, 0, 0, 0, 0, 0)
    t4_some_t := sh_match_opt_term(t4_int_opt, sh_match_opt_pat(t4_int_opt, t4_some_pat))
    t4_none_t := sh_match_opt_term(t4_int_opt, sh_match_opt_pat(t4_int_opt, t4_none_pat))
    t4_full := tt_cons(t4_some_t, tt_cons(t4_none_t, tt_nil()))
    total = total + 1
    fails = fails + ts_check_b("t4.match_opt_two_branch_cover",
        (t4_some_t == t4_intt && t4_none_t == t4_nullt &&
            sh_match_exhaustive(t4_int_opt, t4_full, 0) == 1 &&
            sh_match_exhaustive(t4_int_opt, tt_cons(t4_some_t, tt_nil()), 0) == 0 &&
            sh_match_exhaustive(t4_int_opt, tt_cons(t4_none_t, tt_nil()), 0) == 0), true)
    total = total + 1
    fails = fails + ts_check_b("t4.match_opt_counterexample_naming",
        (sh_match_first_missing(sh_match_bit(0), 2) == 1 &&
            sh_match_first_missing(sh_match_bit(1), 2) == 0 &&
            sh_match_first_missing(0, 2) == 0), true)
    total = total + 1
    fails = fails + ts_check_b("t4.match_opt_wildcard_and_guards",
        (sh_match_exhaustive(t4_int_opt, tt_cons(tt_top(), tt_nil()), 0) == 1 &&
            sh_match_exhaustive(t4_int_opt, t4_full, 1) == -1 &&
            sh_match_exhaustive(TI_INT, t4_full, 0) == -1 &&
            sh_match_domain_term(TI_INT) == -1 && sh_match_domain_term(t4_str_opt) >= 0), true)
    total = total + 1
    fails = fails + ts_check_b("t4.opt_pat_mapping",
        (sh_match_opt_pat(t4_int_opt, t4_some_pat) == 0 && sh_match_opt_pat(t4_int_opt, t4_none_pat) == 1 &&
            sh_match_opt_pat(t4_int_opt, t4_other_pat) == -1 && sh_match_opt_pat(t4_int_opt, t4_qual_pat) == -1 &&
            sh_match_opt_pat(TI_INT, t4_none_pat) == -1), true)
    total = total + 1
    fails = fails + ts_check_b("t4.opt_domain_leaf_count",
        (ts_unf_union_leaves(sh_match_domain_term(t4_int_opt)) == 2 &&
            ts_unf_union_leaves(sh_match_domain_term(t4_str_opt)) == 2), true)
    // 8. Enum payload type-node column: sh_variant_payload_term reads this column.
    t4_p_ei := add_enum("T4Payload")
    ei_set_variant_name(t4_p_ei, 0, str_intern("T4Tag"))
    // Variant 1: the bare code slot is 0 (TY_INT, the only information in the old
    // layout), while the type-node column says string. The node column is the real
    // type.
    ei_set_variant_name(t4_p_ei, 1, str_intern("T4Str"))
    ei_set_variant_type_count(t4_p_ei, 1, 1)
    ei_set_variant_type(t4_p_ei, 1, 0, TY_INT)
    ei_set_variant_type_node(t4_p_ei, 1, 0, alloc_node(0, 0, 0, 0, 0, TY_STRING, 0, 0, 0))
    cell_store(g_enums, t4_p_ei * ESZ_ENUMINFO + OFF_EI_VARIANT_COUNT, 2)
    t4_p_ti := alloc_named_type(str_intern("T4Payload"))
    total = total + 1
    fails = fails + ts_check_b("t4.payload_node_beats_bare_code",
        (sh_variant_payload_term(t4_p_ti, str_intern("T4Str")) == sh_term_of_ti(TI_STR) &&
            ty_disjoint(sh_variant_payload_term(t4_p_ti, str_intern("T4Str")), t4_intt) == 1 &&
            sh_variant_payload_term(t4_p_ti, str_intern("T4Tag")) == -1 &&
            sh_variant_payload_term(t4_p_ti, str_intern("T4Nope")) == -1), true)
    // 9. Generic payload substitution: enum T4GP[T] { T4S(T) }. A generic
    // application takes the payload term from its argument. The int and string
    // instances must produce different terms.
    t4_g_ei := add_enum("T4GP")
    cell_store(g_enums, t4_g_ei * ESZ_ENUMINFO + OFF_EI_GENERIC_COUNT, 1)
    cell_store(g_enums, t4_g_ei * ESZ_ENUMINFO + OFF_EI_GENERIC_NAMES, str_intern("T4GT"))
    ei_set_variant_name(t4_g_ei, 0, str_intern("T4GS"))
    ei_set_variant_type_count(t4_g_ei, 0, 1)
    ei_set_variant_type(t4_g_ei, 0, 0, TY_INT)
    ei_set_variant_type_node(t4_g_ei, 0, 0, alloc_node(EXPR_IDENT, 0, 0, 0, str_intern("T4GT"), 0, 0, 0, 0))
    cell_store(g_enums, t4_g_ei * ESZ_ENUMINFO + OFF_EI_VARIANT_COUNT, 1)
    t4_g_ti := alloc_named_type(str_intern("T4GP"))
    grow_gen_apply_data(g_gen_apply_data_count + 2)
    t4_gs := g_gen_apply_data_count
    cell_store(g_gen_apply_data, t4_gs * 8, 1)
    cell_store(g_gen_apply_data, (t4_gs + 1) * 8, TI_INT)
    g_gen_apply_data_count = t4_gs + 2
    t4_g_ga := alloc_type(TYP_GENERIC_APPLY, t4_g_ti, t4_gs)
    grow_gen_apply_data(g_gen_apply_data_count + 2)
    t4_gs2 := g_gen_apply_data_count
    cell_store(g_gen_apply_data, t4_gs2 * 8, 1)
    cell_store(g_gen_apply_data, (t4_gs2 + 1) * 8, TI_STR)
    g_gen_apply_data_count = t4_gs2 + 2
    t4_g_ga2 := alloc_type(TYP_GENERIC_APPLY, t4_g_ti, t4_gs2)
    total = total + 1
    fails = fails + ts_check_b("t4.payload_generic_subst",
        (sh_variant_payload_term(t4_g_ga, str_intern("T4GS")) == sh_term_of_ti(TI_INT) &&
            sh_variant_payload_term(t4_g_ga2, str_intern("T4GS")) == sh_term_of_ti(TI_STR) &&
            sh_variant_payload_term(t4_g_ga, str_intern("T4GS")) != sh_variant_payload_term(t4_g_ga2, str_intern("T4GS"))), true)
    // 10. Option is not a built-in type. It has no type row and no symbol unless
    // the user declares it.
    total = total + 1
    fails = fails + ts_check_b("t4.option_not_registered",
        (named_dedup_rows(str_intern("Option")) == 0 && find_gsym(str_intern("Option")) < 0), true)

    // t5 constraint tests. Cases are in ts_t5_run; they are not inlined here.
    total = total + 9
    fails = fails + ts_t5_run()

    // isat interface satisfaction tests (16 cases), in ts_isat_run.
    total = total + 16
    fails = fails + ts_isat_run()

    // x2 shape tests (16 cases, including x2.shape_builtin_names), in ts_x2_run.
    total = total + 16
    fails = fails + ts_x2_run()

    // impl contract tests (14 cases): signature terms, shape terms, method lookup
    // without name mangling, and judgment results. In ts_ifc_run.
    total = total + 14
    fails = fails + ts_ifc_run()

    // Named-type identity tests (18 cases): identity token sequence, decidable
    // cases, and out-of-domain guards. In ts_t3n_run. One residual case moved to
    // the t3b section.
    total = total + 18
    fails = fails + ts_t3n_run()

    // Invariant-slot element comparison (13 cases), in ts_t3b_run.
    total = total + 13
    fails = fails + ts_t3b_run()

    // ICE04 behavior (3 cases): bridge gaps, uncovered rules, and no false
    // diagnostics. In ts_t4_run.
    total = total + 3
    fails = fails + ts_t4_run()

    // Negation branch: same-class atom identity (11 cases), in ts_t2_neg_run.
    total = total + 11
    fails = fails + ts_t2_neg_run()

    // TYPE segment tests (5 cases): fill, roundtrip, dedup, determinism, and
    // rejection paths. In ts_ccr_run.
    // IFACE segment tests (8 cases): five sections, signature term slots, shape
    // name registry, entry expansion, unchanged judgment logic, and rejection of
    // unbuildable signatures. In ts_ccr2_run. It must run last because populate
    // resets the term layer, engine, and bridge caches. Both segments share the
    // same fill entry.
    // Seven bridge cases are inlined in the earlier bridge section; see t4.tk_*.
    total = total + 5
    fails = fails + ts_ccr_run()
    total = total + 8
    fails = fails + ts_ccr2_run()

    g_cur_lib = saved_lib
    print(int_str(total - fails))
    print("/")
    print(int_str(total))
    println(" type-engine cases passed")
    if fails != 0:
        return 1
    return 0
