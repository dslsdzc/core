// === type_selftest.cr ===
// R2 P0：类型项引擎判定用例表 + 自测驱动（`corec selftest-types`）。
// 判据：每例一行 PASS/FAIL，末行 "N/M type-engine cases passed"，rc=0 = 全过。
// 说明：本文件只依赖 type_terms.cr / type_engine.cr 的公开 API。
// 用例面分期：Task 1 = P0 最小 5 例（建层）；Task 3/4 扩到 spec §8 全类
// （子类型/等价/不相交/可空/反例/穷尽性/递归/参数化/预算）；**P0 终审补 8 例**
// （否定在超类型侧 / memo 扩容不挂 / 预算不吞 -1 / n 元析取 / 命名原子未知 /
// ¬μ 不下推 / 未覆盖面未知）。tests/selfhost/test_type_engine.py 的 MIN_CASES = 32。

fn ts_check(name: string, got: int, want: int) -> int {
    if got == want {
        print("PASS "); println(name);
        return 0;
    }
    print("FAIL "); print(name);
    print(": got "); print(int_str(got));
    print(" want "); println(int_str(want));
    return 1;
}

// Task 4 端到端用例的诊断探针：check_error 只追加 g_diags（不打印），故「门是否报错」可由
// 增量计数 + 首条新诊断码直接读——这是「接线后门真的在判」的行为证据（表侧用例只能证明表对）。
fn ts_diag_code_at(idx: int) -> int {
    if idx < 0 { return -1; }
    if idx >= g_diag_count { return -1; }
    return r64(g_diags, idx * DIAG_REC_SIZE);
}

// 诊断消息探针（R2 P5 Task 4）：读第 idx 条诊断的消息指针（check_error 存的就是该指针）。
fn ts_diag_msg_at(idx: int) -> string {
    if idx < 0 { return ""; }
    if idx >= g_diag_count { return ""; }
    return load_str_ptr(g_diags, idx * DIAG_REC_SIZE + 8);
}

// ─── R2 P5 Task 4：AK 映射的**冻结期望表**（替代已删的 legacy 副本对照物）───
// 与 iface_registry.cr 的 `iface_by_ty_code`（唯一生产实现）逐格对照用：本表 = 数据形态的期望，
// 不再是生产文件里的第二份实现（单源化的判据由此从「两份实现互比」变「实现 vs 冻结期望」）。
// 依据 = P2b Task 2 已裁决的映射（含两条灰格：TY_DEX_S → AK_DEX（同值域不同表示）、
// TY_GENERIC_PARAM → AK_NAMED（泛型参数哨兵 → 命名类，不展开））；未映射码 ⇒ -1。
fn ts_t4_ak_expected(ty: int) -> int {
    if ty == TY_INT { return AK_INT; }
    if ty == TY_DEX { return AK_DEX; }
    if ty == TY_DEX_S { return AK_DEX; }
    if ty == TY_BOOL { return AK_BOOL; }
    if ty == TY_STRING { return AK_STRING; }
    if ty == TY_UNIT { return AK_UNIT; }
    if ty == TY_NEVER { return AK_NEVER; }
    if ty == TY_CHAR { return AK_CHAR; }
    if ty == TY_GENERIC_PARAM { return AK_NAMED; }
    return -1;
}

// 行号面期望：**门**（kind 非 TYP_BASE ⇒ -1，含 TYP_DYN/结构/命名行与负 ti）+ 表内分派。
fn ts_t4_native_ak_expected(ti: int) -> int {
    if ti < 0 { return -1; }
    if get_type_kind(ti) != TYP_BASE { return -1; }
    return ts_t4_ak_expected(get_type_data(ti));
}

// 宽联合探针（预算守卫用）：N 层左深 union —— sub_cover 逐支递归，每支 1 步，
// N > 预算即耗尽（深 μ 链不行：参数位置的字面蕴含不递归展开，会在参数比较处短路）。
fn tt_probe_wide_union(depth: int) -> int {
    acc : ., mut = tt_atom(AK_INT, TI_INT, -1);
    d : ., mut = 0;
    loop {
        if d >= depth { break; }
        acc = tt_union(acc, tt_atom(AK_STRING, TI_STR, -1));
        d = d + 1;
    }
    return acc;
}

// R2 P3 Task 0 夹具：声明单 `int` 字段 struct（a: int），返回其命名行。本通道不经
// parser/check_all ⇒ struct 声明表照 parser.cr:1539-1560 的写槽序人工落（字段名 /
// 裸码槽 / 类型节点 / 字段数），类型节点照 parse_type 的产物形态构造。
fn ts_unf_mk_int_struct(name: string) -> int {
    sa := add_struct(name);
    si_set_field_name(sa, 0, str_intern("a"));
    si_set_field_type(sa, 0, TY_INT);
    si_set_field_type_node(sa, 0, alloc_node(0, 0, 0, 0, 0, TY_INT, 0, 0, 0));
    w64(g_structs, sa * ESZ_STRUCTINFO + OFF_SI_FIELD_COUNT, 1);
    return alloc_named_type(str_intern(name));
}

// 域项的析取支计数（「变体数」判据用）：只按引擎项形态走 union 树，**不与实现共享计数逻辑**
// （独立重算——否则同源同错自洽假绿）。⊥/单支 → 1。
fn ts_unf_union_leaves(t: int) -> int {
    if tt_tag(t) == TT_UNION { return ts_unf_union_leaves(tt_a(t)) + ts_unf_union_leaves(tt_b(t)); }
    return 1;
}

// ─── R2 P3 Task 5 夹具（生产函数入口，见 t5.* 段注）───

// g_gen_map 按名字查绑定（-1 = 未绑定）——t5.f4 用（独立读取，不复用 checker 内部循环）
fn ts_gen_map_ti(name_ni: int) -> int {
    i : ., mut = 0;
    loop {
        if i >= g_gen_map_count { return -1; }
        if r64(g_gen_map_names, i * 8) == name_ni { return r64(g_gen_map_types, i * 8); }
        i = i + 1;
    }
    return -1;
}

// 单泛型形参 + 单约束名的 struct 声明行夹具（约束经 **parser 的生产登记函数**
// save_struct_gen_constrs 落侧表——测真实路径，不手写侧表）
fn ts_t5_mk_constr_struct(name: string, cname: string) -> int {
    sa := add_struct(name);
    w64(g_structs, sa * ESZ_STRUCTINFO + OFF_SI_GENERIC_COUNT, 1);
    w64(g_structs, sa * ESZ_STRUCTINFO + OFF_SI_GENERIC_NAMES, str_intern("T5_CS_T"));
    cb := alloc(8);
    w64(cb, 0, str_intern(cname));
    save_struct_gen_constrs(sa, cb, 1);
    return sa;
}

fn ts_t5_mk_constr_enum(name: string, cname: string) -> int {
    ea := add_enum(name);
    w64(g_enums, ea * ESZ_ENUMINFO + OFF_EI_GENERIC_COUNT, 1);
    w64(g_enums, ea * ESZ_ENUMINFO + OFF_EI_GENERIC_NAMES, str_intern("T5_CE_T"));
    cb := alloc(8);
    w64(cb, 0, str_intern(cname));
    save_enum_gen_constrs(ea, cb, 1);
    return ea;
}

// 接口表行夹具（零方法）：t5.constr_iface_is_unknown_p3b 用（谓词 = find_iface 命中 ⇒
// gen_constr_satisfied 必须回 -1——P3b 交接边界）
fn ts_t5_mk_iface(name: string) -> int {
    grow_ifaces(g_iface_count + 1);
    base := g_iface_count * ESZ_IFACEINFO;
    zi : ., mut = 0;
    loop { if zi >= ESZ_IFACEINFO { break; } w8(g_ifaces, base + zi, 0); zi = zi + 1; }
    w64(g_ifaces, base + OFF_IF_NAME, str_intern(name));
    w64(g_ifaces, base + OFF_IF_GENERIC_COUNT, 0);
    g_iface_count = g_iface_count + 1;
    return g_iface_count - 1;
}

// ─── R2 P3 Task 5 用例体（独立函数：**不得**内联进 type_selftest_run ——
/// 该函数已是巨型函数，本段 40+ 局部变量的加入会使其在 Python bootstrap 的
/// 栈式代码生成下越界（实测：内联版 SIGSEGV rc=139；拆出后正常）。返回 = 失败数。
/// 用例数 = 9（调用方 `total = total + 9` 须同步——增删用例两处一起改）。
fn ts_t5_run() -> int {
    fails : ., mut = 0;
    // ═══ R2 P3 Task 5：泛型约束（保留 / 实例化判定 / 反例 / 实例键类型项化）═══
    // 判据面 = ① F4 形参链导航（形参节点**不连续**布局下的正/负控——旧 `pn+1` 导航的牙）；
    // ② 约束名解析 + 本质轴三态判定（1/0/-1）；③ 用户接口约束 = **-1 不判**（P3b 交接边界：
    // 「不判」≠「不满足」）；④ 反例文本（失败有值 / 通过无值）；⑤ 实例化点检查的**诊断去重**
    // （同节点同形参只报一次）+ 正负控；⑥ 结构/枚举约束经 parser 登记函数落到侧表后可读；
    // ⑦ 实例键结构忠实（异型异键 = 反折叠）+ ti 型替换在**克隆体**上的落点（形参类型节点）。
    // 夹具说明：本组不经 parser/check_all（照 t3/t4 口径人工落表），但**走生产函数**——
    // save_struct_gen_constrs / gen_inst_constr_check / infer_gen_call / gen_find_or_create_bind。
    init_types();
    ty_budget_reset(200000);
    // ① F4：夹具 = 「文件首类型节点恰是另一泛型形参的 ident」+ 形参 (n: int, a: T)（类型节点
    //   插在形参节点之前 ⇒ 形参在节点表不连续）。旧导航把 param1 的 pattern 读成节点 0 ⇒
    //   凭空绑定 U（phanton）且 T 永不绑定；修复后 param1 的 pattern = 声明类型 gparam(T)。
    init_types();   // 夹具前再清一次（上面 alloc 的行使节点下标可预期：本组不依赖具体下标）
    t5_u_ni := str_intern("T5_U");
    t5_u_row := alloc_type(TYP_GENERIC_PARAM, t5_u_ni, 0);
    def_sym(t5_u_ni, SYM_TYPE, t5_u_row, -1);
    alloc_node(EXPR_IDENT, 0, 0, 0, t5_u_ni, 0, 0, 0, 0);            // 「文件首类型节点」
    t5_int_n := alloc_node(0, 0, 0, 0, 0, TY_INT, 0, 0, 0);
    t5_p0 := alloc_node(EXPR_PARAM, str_intern("n"), 0, 0, 0, TY_INT, t5_int_n, 0, 0);
    t5_t_ni := str_intern("T5_T");
    t5_t_row := alloc_type(TYP_GENERIC_PARAM, t5_t_ni, 0);
    def_sym(t5_t_ni, SYM_TYPE, t5_t_row, -1);
    t5_t_n1 := alloc_node(EXPR_IDENT, 0, 0, 0, t5_t_ni, 0, 0, 0, 0);
    t5_p1 := alloc_node(EXPR_PARAM, str_intern("a"), 0, 0, 0, 0, t5_t_n1, 0, 0);
    t5_rt := alloc_node(EXPR_IDENT, 0, 0, 0, t5_t_ni, 0, 0, 0, 0);
    t5_fn := alloc_node(EXPR_FN, str_intern("t5_f4_take"), t5_p0, 2, 0, t5_rt, -1, 0, 0);
    t5_fi := add_func("t5_f4_take", 2, 0, t5_fn);   // add_func 收**字符串**（parser 同款：tok_lx 结果），不是 ni
    fi_set_generic_count(t5_fi, 1);
    println("M5b");
    fi_set_generic_name(t5_fi, 0, t5_t_ni);
    println("M5c");
    def_sym(str_intern("t5_f4_take"), SYM_FN, TI_UNIT, -1);
    t5_arg2 := alloc_node(EXPR_ARG, alloc_node(EXPR_STRING, 0, 0, 0, str_intern("s"), 0, 0, 0, 0), 0, 0, 0, 0, 0, 0, 0);
    // EXPR_ARG: a = expr, b = next（末项 b = 0 即终止符——链遍历按 `an < 0` 停，见 infer_gen_call）
    ast_set_b(t5_arg2, -1);
    t5_arg1 := alloc_node(EXPR_ARG, alloc_node(EXPR_INT, 0, 0, 0, 1, 0, 0, 0, 0), t5_arg2, 0, 0, 0, 0, 0, 0);
    t5_calln := alloc_node(EXPR_CALL, 0, t5_arg1, 2, 0, 0, 0, 0, 0);
    infer_gen_call(t5_fi, t5_calln, t5_arg1, 2);
    t5_ti_bound := ts_gen_map_ti(t5_t_ni);
    fails = fails + ts_check("t5.f4_later_param_declared_type",
        (t5_ti_bound == TI_STR && ts_gen_map_ti(t5_u_ni) == -1), 1);
    fails = fails + ts_check("t5.f4_bind_seg_recorded",
        (g_gen_binds_count == 2 && r64(g_gen_binds, 0 * 8) == 1 &&
         r64(g_gen_binds, 1 * 8) == TI_STR && ast_int_val(t5_calln) == 1), 1);
    // ② 约束名解析 + 本质轴三态
    t5_ni_int := str_intern("int");
    t5_ni_str := str_intern("string");
    t5_ni_nope := str_intern("T5_NoSuchTypeName");
    fails = fails + ts_check("t5.constr_name_resolve",
        (gen_constr_type_ti(t5_ni_int) == TI_INT && gen_constr_type_ti(t5_ni_str) == TI_STR &&
         gen_constr_type_ti(str_intern("never")) == TI_NEVER && gen_constr_type_ti(t5_ni_nope) == -1 &&
         gen_constr_type_ti(-1) == -1), 1);
    fails = fails + ts_check("t5.constr_essence_three_state",
        (gen_constr_satisfied(t5_ni_int, TI_INT) == 1 &&
         // `never` **不**满足原生约束（引擎现状：AK_NEVER 是与 AK_INT 互斥的**原子**，不是 ⊥
         // ——P0 既有语义「never 行在引擎侧不是真 ⊥」（T4 报告 §7-⑨），本批如实钉住、不动）
         gen_constr_satisfied(t5_ni_int, TI_NEVER) == 0 &&
         gen_constr_satisfied(t5_ni_int, TI_STR) == 0 &&
         gen_constr_satisfied(t5_ni_str, TI_INT) == 0 &&
         gen_constr_satisfied(t5_ni_nope, TI_INT) == -1), 1);
    // ③ 用户接口约束 + **非命名实参** ⇒ -1（P3b Task 0 后仍 -1：域限定——接口方法表只对命名行
    //    可查，故 `int` 实参不判；**不是**「未交付」。命名实参的判定面见 isat.* 段与
    //    tests/selfhost/test_iface_satisfies.py）
    t5_if_ii := ts_t5_mk_iface("T5_Show");
    fails = fails + ts_check("t5.constr_iface_non_named_unjudged",
        (find_iface(str_intern("T5_Show")) == t5_if_ii &&
         gen_constr_satisfied(str_intern("T5_Show"), TI_INT) == -1), 1);
    // ④ 反例文本：失败非空、通过为空（**不谎报**）
    fails = fails + ts_check("t5.constr_witness_text",
        (str_len(gen_constr_witness_str(TI_STR, t5_ni_int)) > 0 &&
         str_len(gen_constr_witness_str(TI_INT, t5_ni_int)) == 0 &&
         str_len(gen_constr_witness_str(TI_INT, t5_ni_nope)) == 0), 1);
    // ⑤⑥ 实例化点检查：结构/枚举约束经 parser 登记函数落侧表 + 判定 + 去重 + 正负控 + 接口面零动作
    t5_si := ts_t5_mk_constr_struct("T5BoxInt", "int");
    t5_ei := ts_t5_mk_constr_enum("T5EBoxInt", "int");
    t5_si2 := ts_t5_mk_constr_struct("T5BoxShow", "T5_Show");
    fails = fails + ts_check("t5.constr_side_table_readback",
        (si_generic_count(t5_si) == 1 && si_gen_constr(t5_si, 0) == t5_ni_int &&
         si_gen_constr(t5_si, 1) == -1 && si_gen_constr(-1, 0) == -1 &&
         ei_generic_count(t5_ei) == 1 && ei_gen_constr(t5_ei, 0) == t5_ni_int &&
         ei_gen_constr(t5_ei, 4) == -1), 1);
    t5_args := alloc(8);
    w64(t5_args, 0 * 8, TI_STR);
    t5_gnode := alloc_node(EXPR_GENERIC_APPLY, str_intern("T5BoxInt"), -1, 1, 0, 0, 0, 41, 3);
    t5_d0 := g_diag_count;
    gen_inst_constr_check(t5_gnode, t5_si, -1, t5_args, 1);
    t5_d1 := g_diag_count;
    gen_inst_constr_check(t5_gnode, t5_si, -1, t5_args, 1);      // 同节点同形参 → 去重
    t5_d2 := g_diag_count;
    t5_gnode2 := alloc_node(EXPR_GENERIC_APPLY, str_intern("T5BoxInt"), -1, 1, 0, 0, 0, 42, 3);
    gen_inst_constr_check(t5_gnode2, t5_si, -1, t5_args, 1);     // 新节点 → 再报（去重不跨节点）
    t5_d3 := g_diag_count;
    w64(t5_args, 0 * 8, TI_INT);
    t5_gnode3 := alloc_node(EXPR_GENERIC_APPLY, str_intern("T5BoxInt"), -1, 1, 0, 0, 0, 43, 3);
    gen_inst_constr_check(t5_gnode3, t5_si, -1, t5_args, 1);     // 正控：满足 → 零诊断
    gen_inst_constr_check(t5_gnode3, t5_ei, -1, t5_args, 1);     // 枚举侧同（满足）
    t5_d4 := g_diag_count;
    w64(t5_args, 0 * 8, TI_STR);
    t5_gnode4 := alloc_node(EXPR_GENERIC_APPLY, str_intern("T5EBoxInt"), -1, 1, 0, 0, 0, 44, 3);
    gen_inst_constr_check(t5_gnode4, -1, t5_ei, t5_args, 1);     // 枚举侧违反 → 诊断
    t5_d5 := g_diag_count;
    t5_gnode5 := alloc_node(EXPR_GENERIC_APPLY, str_intern("T5BoxShow"), -1, 1, 0, 0, 0, 45, 3);
    gen_inst_constr_check(t5_gnode5, t5_si2, -1, t5_args, 1);    // 接口约束 = 不判 → 零诊断
    t5_d6 := g_diag_count;
    fails = fails + ts_check("t5.inst_check_dedup_and_controls",
        (t5_d1 - t5_d0 == 1 && t5_d2 - t5_d1 == 0 && t5_d3 - t5_d2 == 1 &&
         t5_d4 - t5_d3 == 0 && t5_d5 - t5_d4 == 1 && t5_d6 - t5_d5 == 0 &&
         ts_diag_code_at(t5_d0) == EC_TG_BOUND &&
         // 末条记录下标 = **调用后计数 - 1**（d5 是调用后的 g_diag_count）
         ts_diag_code_at(t5_d5 - 1) == EC_TG_BOUND), 1);
    // ⑦ 实例键：异型异键（反折叠）+ 同名义同行同键 + 结构忠实（复合键含结构）
    t5_a_ti := alloc_named_type(str_intern("T5_A"));
    t5_b_ti := alloc_named_type(str_intern("T5_B"));
    t5_a2_ti := alloc_type(TYP_NAMED, str_intern("T5_A"), 0);
    t5_arr_ti := alloc_type(TYP_ARRAY, TI_INT, 3);
    t5_ptr_ti := alloc_type(TYP_PTR, t5_a_ti, 0);
    t5_slice_ti := alloc_type(TYP_SLICE, TI_INT, 0);
    fails = fails + ts_check("t5.inst_key_structural_faithful",
        (str_eq(inst_key_of_ti(t5_a_ti), inst_key_of_ti(t5_b_ti)) == 0 &&
         str_eq(inst_key_of_ti(t5_a_ti), inst_key_of_ti(t5_a2_ti)) != 0 &&
         str_eq(inst_key_of_ti(TI_INT), "int") != 0 &&
         str_eq(inst_key_of_ti(t5_arr_ti), "[int; 3]") != 0 &&
         str_eq(inst_key_of_ti(t5_ptr_ti), "*T5_A") != 0), 1);
    // ⑧ ti 型替换端到端：克隆体内**泛型形参位**换成实参类型节点；异键异实例、同键缓存命中。
    // 夹具形参实参 = **切片** `[int]`（键 "[int]"）：ti 路径产出 EXPR_ARRAY 类型节点，名字路径
    // 只会产出 EXPR_IDENT("[int]")（非法声明名）⇒ 本判据对「ti 路径是否生效」有牙。
    // ⚠ **范围登记**：替换只覆盖**函数体内**节点——EXPR_FN 分支不克隆形参（形参类型由
    // fi_param_type 的裸码承担），故克隆体形参仍指向源节点（与实例化的既有语义一致）。
    t5_m_ni := str_intern("T5_M");
    t5_m_tynode := alloc_node(EXPR_IDENT, 0, 0, 0, t5_m_ni, 0, 0, 0, 0);
    t5_m_body := alloc_node(EXPR_RETURN, t5_m_tynode, 0, 0, 0, 0, 0, 0, 0);   // 体内形参位
    t5_m_p := alloc_node(EXPR_PARAM, str_intern("x"), 0, 0, 0, 0, t5_m_tynode, 0, 0);
    t5_m_rt := alloc_node(EXPR_IDENT, 0, 0, 0, t5_m_ni, 0, 0, 0, 0);
    t5_m_fn := alloc_node(EXPR_FN, t5_m_ni, t5_m_p, 1, 0, t5_m_rt, t5_m_body, 0, 0);
    t5_m_fi := add_func("T5_M", 1, 0, t5_m_fn);
    fi_set_generic_count(t5_m_fi, 1);
    fi_set_generic_name(t5_m_fi, 0, t5_m_ni);
    // 绑定段（人工按 checker 写入形态落：块 = [count, ti…]，节点 int_val = 起始 + 1）
    grow_gen_binds(g_gen_binds_count + 2);
    t5_bstart := g_gen_binds_count;
    w64(g_gen_binds, t5_bstart * 8, 1);
    w64(g_gen_binds, (t5_bstart + 1) * 8, t5_slice_ti);
    g_gen_binds_count = t5_bstart + 2;
    t5_key_s := inst_key_of_ti(t5_slice_ti);
    t5_f1 := gen_find_or_create_bind(t5_m_fi, t5_key_s, t5_bstart);
    t5_f2 := gen_find_or_create_bind(t5_m_fi, t5_key_s, t5_bstart);   // 同键 → 缓存命中
    t5_f3 := gen_find_or_create_bind(t5_m_fi, inst_key_of_ti(t5_b_ti), t5_bstart);  // 异键 → 新实例
    t5_cp_ok : ., mut = 0;
    if t5_f1 >= 0 {
        t5_cb := ast_data(fi_ast_node(t5_f1));      // 克隆体（EXPR_FN）的 body
        if t5_cb >= 0 && ast_kind(t5_cb) == EXPR_RETURN {
            t5_cn := ast_a(t5_cb);                  // 体内形参位（源 = EXPR_IDENT(T5_M)）
            if t5_cn >= 0 && ast_kind(t5_cn) == EXPR_ARRAY {
                t5_cn_e := ast_a(t5_cn);            // 切片元素位（源实参 = int）
                if t5_cn_e >= 0 && ast_kind(t5_cn_e) == 0 && ast_type_val(t5_cn_e) == TY_INT { t5_cp_ok = 1; }
            }
        }
    }
    fails = fails + ts_check("t5.inst_ti_subst_in_clone",
        (t5_f1 >= 0 && t5_f2 == t5_f1 && t5_f3 >= 0 && t5_f3 != t5_f1 && t5_cp_ok == 1), 1);

    return fails;
}

// ═══════════════ R2 P3b Task 0：`iface_satisfies` 契约用例（isat.*）═══════════════
// 面（详见 type_engine.cr 的契约头注）：轴分派 A 形状 → C 用户接口 → B 本质轴；三态纪律
// （-1 不得当 0/1）；轴 C 谓词 = check_iface 同源（方法名在位 + 参数计数 + 返回码）；域限定 =
// 命名行。**本段主判据 = ① 三态直传（不是「查不到就 0」）② 与 check_iface 逐例对拍
// ③ 判定路径零 str_intern（.ccr STR 段守卫）④ 形状表注册/覆盖/复位语义。**

// 接口方法条目追加（照 parser 的 interface 分支写点：mbase + name/param_count/ret_ti）
fn ts_isat_add_method(ii: int, mname: string, pc: int, rt: int) -> int {
    n := r64(g_ifaces, ii * ESZ_IFACEINFO + OFF_IF_METHOD_COUNT);
    mbase := ii * ESZ_IFACEINFO + OFF_IF_METHODS + n * ESZ_IFMETHOD;
    w64(g_ifaces, mbase + OFF_IFM_NAME, str_intern(mname));
    w64(g_ifaces, mbase + OFF_IFM_PARAM_COUNT, pc);
    w64(g_ifaces, mbase + OFF_IFM_RET_TI, rt);
    // R2 P3b Task 6（Step 1 签名类型项化）：**类型节点**槽（与生产 parser 同形：基类型节点 =
    // kind 0 + type_val = TY_* 码）+ 接收者模式（0 = 无接收者，本组夹具形态）。
    w64(g_ifaces, mbase + OFF_IFM_RET_NODE, ts_ifc_base_node(rt));
    w64(g_ifaces, mbase + OFF_IFM_SELF_MODE, 0);
    pj : ., mut = 0;
    loop {
        if pj >= pc || pj >= MAX_IFACE_METHOD_PARAMS { break; }
        w64(g_ifaces, mbase + OFF_IFM_PARAM_TYPES + pj * 8, TY_INT);
        w64(g_ifaces, mbase + OFF_IFM_PARAM_NODES + pj * 8, ts_ifc_base_node(TY_INT));
        pj = pj + 1;
    }
    w64(g_ifaces, ii * ESZ_IFACEINFO + OFF_IF_METHOD_COUNT, n + 1);
    return mbase;
}

// 基类型节点（= parser `parse_type` 的基类型产物同形：kind 0、type_val = TY_* 码；
// 签名面消费点（`sh_sig_term_of_node` → `res_type_node`）按同一分派表解析）。
fn ts_ifc_base_node(ty: int) -> int {
    return alloc_node(0, 0, 0, 0, 0, ty, 0, 0, 0);
}

// impl 方法登记（**照 parser 的 impl 分支写点**：mangled 函数名 + g_methods 三元组
// {type_ni, method_ni, mangled_ni}）——夹具须与生产写点同形，否则对拍在两种登记面上空转。
// R2 P3b Task 6：函数行带**真 EXPR_FN 节点**（形参链 + 类型节点；形参节点**不连续**——类型
// 节点插在其后，照 parse_body 的分配布局）——签名面（`sh_func_sig_term`）从 AST 读参数/返回型。
fn ts_isat_add_impl_method(tname_ni: int, mname: string, pc: int, rt: int) -> int {
    mn := istr_get(tname_ni) + "." + mname;
    mangled_ni := str_intern(mn);
    pf : ., mut = -1;
    pj : ., mut = 0;
    loop {
        if pj >= pc { break; }
        tn := ts_ifc_base_node(TY_INT);
        if pf < 0 { pf = g_ast_count; }
        alloc_node(EXPR_PARAM, str_intern("p"), 0, 0, 0, TY_INT, tn, 0, 0);
        pj = pj + 1;
    }
    rtn := ts_ifc_base_node(rt);
    fn_node := alloc_node(EXPR_FN, mangled_ni, pf, pc, rt, rtn, -1, 0, 0);
    fi := add_func(mn, pc, rt, fn_node);
    grow_methods(g_method_count + 1);
    w64(g_methods, g_method_count * 24, tname_ni);
    w64(g_methods, g_method_count * 24 + 8, str_intern(mname));
    w64(g_methods, g_method_count * 24 + 16, mangled_ni);
    g_method_count = g_method_count + 1;
    return fi;
}

fn ts_isat_b2i(b: bool) -> int { if b { return 1; } return 0; }

// 用例数 = 16（调用方 `total = total + 16` 须同步——增删用例两处一起改）。
fn ts_isat_run() -> int {
    fails : ., mut = 0;
    // ── 夹具：接口 `T0bShow { fn show(pc=1, rt=0) }`；命名行 T0bS（有 show）/ T0bT（无方法）──
    // rt 码语义 = 映射层编码（0 = TY_INT，见 type_engine.cr 轴 C 注）。
    isat_ii := ts_t5_mk_iface("T0bShow");
    ts_isat_add_method(isat_ii, "show", 1, 0);
    isat_show_ni := str_intern("show");
    isat_s_ti := alloc_named_type(str_intern("T0bS"));
    isat_t_ti := alloc_named_type(str_intern("T0bT"));
    ts_isat_add_impl_method(str_intern("T0bS"), "show", 1, 0);
    // ① 轴 C 正例：方法在位 + 计数/返回码相符 ⇒ 1（命名行的空洞满足另见 ⑫）
    fails = fails + ts_check("isat.axis_c_satisfied",
        iface_satisfies(isat_s_ti, str_intern("T0bShow")), 1);
    // ② 轴 C 反例：方法名不在位 ⇒ **0**（可证违反——名字面忠实；不是 -1）
    fails = fails + ts_check("isat.axis_c_missing_method",
        iface_satisfies(isat_t_ti, str_intern("T0bShow")), 0);
    // ③ 轴 C 反例：参数计数不符 ⇒ 0
    isat_c_ti := alloc_named_type(str_intern("T0bC"));
    ts_isat_add_impl_method(str_intern("T0bC"), "show", 2, 0);
    fails = fails + ts_check("isat.axis_c_param_count",
        iface_satisfies(isat_c_ti, str_intern("T0bShow")), 0);
    // ④ 轴 C 反例：返回码不符（3 = TY_STRING）⇒ 0
    isat_r_ti := alloc_named_type(str_intern("T0bR"));
    ts_isat_add_impl_method(str_intern("T0bR"), "show", 1, 3);
    fails = fails + ts_check("isat.axis_c_ret_code",
        iface_satisfies(isat_r_ti, str_intern("T0bShow")), 0);
    // ⑤ 域限定：非命名行（原生 / dyn / 泛型形参）⇒ **不判**（无方法表身份；绝不因「查不到」报 0）
    isat_dyn_ti := alloc_type(TYP_DYN, 0, 0);
    isat_gp_ti := alloc_type(TYP_GENERIC_PARAM, str_intern("T0bU"), 0);
    fails = fails + ts_check("isat.axis_c_non_named_unjudged",
        ts_isat_b2i(iface_satisfies(TI_INT, str_intern("T0bShow")) == -1 &&
         iface_satisfies(isat_dyn_ti, str_intern("T0bShow")) == -1 &&
         iface_satisfies(isat_gp_ti, str_intern("T0bShow")) == -1), 1);
    // ⑥ 轴 B（本质轴）：= gen_constr_satisfied 引擎面（迁移到统一入口后逐例同结论）
    fails = fails + ts_check("isat.axis_b_essence",
        ts_isat_b2i(iface_satisfies(TI_INT, str_intern("int")) == 1 &&
         iface_satisfies(TI_INT, str_intern("string")) == 0 &&
         iface_satisfies(TI_INT, str_intern("T0bNoSuchName")) == -1), 1);
    // ⑦ 轴 A（横切形状）：注册 ⊤_SEQUENCE 名 ⇒ 切片行 1 / 原生行 0；**复位后同键 ⇒ -1**
    //    （复位断言防「条目泄漏成全局态」；lookup 负键守卫）
    //    R2 P4 Task 3 重定：形状表在 init_types 尾部已有**生产注册面**（6 条 D17 名）
    //    ——本行 = 第 7 条（slot 6），计数基数由 0 改 6；注册/查询/判定语义零变化。
    isat_seq_ti := alloc_type(TYP_SLICE, TI_INT, 0);
    isat_shape_name := str_intern("T0bShapeSeq");
    isat_n_pre := iface_shape_count();
    isat_slot := iface_shape_register(isat_shape_name, tt_top_k(AK_SEQUENCE));
    fails = fails + ts_check("isat.axis_a_shape",
        ts_isat_b2i(isat_slot == isat_n_pre && iface_shape_count() == isat_n_pre + 1 &&
         iface_shape_lookup(isat_shape_name) >= 0 &&
         iface_satisfies(isat_seq_ti, isat_shape_name) == 1 &&
         iface_satisfies(TI_INT, isat_shape_name) == 0), 1);
    // ⑧ 轴优先级：同名既是形状又是接口 ⇒ **形状优先**（TI_INT 在形状面可判 0，在用户轴恒 -1
    //    ⇒ 结果 0 即证明走了轴 A；零方法接口在用户轴本会走 1 的路径也一并在 ⑫ 覆盖）
    isat_dup_ii := ts_t5_mk_iface("T0bDup");
    fails = fails + ts_check("isat.axis_order_shape_first",
        ts_isat_b2i(find_iface(str_intern("T0bDup")) == isat_dup_ii &&
         iface_shape_register(str_intern("T0bDup"), tt_top_k(AK_SEQUENCE)) >= 0 &&
         iface_satisfies(TI_INT, str_intern("T0bDup")) == 0), 1);
    // ⑨ 轴优先级：同名既是接口又是原生类型名 ⇒ **接口优先**（= 现状 gen_constr_satisfied 的
    //    find_iface 先行；非命名实参 ⇒ -1，**不做**本质轴判定）——P3a 零行为变化面
    ts_t5_mk_iface("int");
    fails = fails + ts_check("isat.axis_order_iface_over_essence",
        ts_isat_b2i(iface_satisfies(TI_INT, str_intern("int")) == -1), 1);
    // ⑩ 与 check_iface **逐例对拍**（谓词同源的最强守门：三形态 = 满足/计数不符/返回码
    //    不符；缺方法形态在 ② 与 ⑪ 分别钉住 0 与零驻留表增长）
    isat_eq := -1;
    if ts_isat_b2i(check_iface(str_intern("T0bS"), isat_ii)) == iface_satisfies(isat_s_ti, str_intern("T0bShow")) {
        if ts_isat_b2i(check_iface(str_intern("T0bC"), isat_ii)) == iface_satisfies(isat_c_ti, str_intern("T0bShow")) {
            if ts_isat_b2i(check_iface(str_intern("T0bR"), isat_ii)) == iface_satisfies(isat_r_ti, str_intern("T0bShow")) {
                isat_eq = 1;
            }
        }
    }
    fails = fails + ts_check("isat.predicate_same_as_check_iface", isat_eq, 1);
    // ⑪ 判定路径**零 str_intern**（.ccr STR 段守卫）：缺失方法名（= 判定 0 的路径）不得把
    //    新串追加进驻留表——`type_has_method` 的 `str_intern("T.m")` 形态在此会增长表。
    isat_zz_ti := alloc_named_type(str_intern("T0bZz"));
    isat_before := g_str_count;
    iface_satisfies(isat_zz_ti, str_intern("T0bShow"));
    fails = fails + ts_check("isat.no_str_intern_on_missing",
        ts_isat_b2i(g_str_count == isat_before), 1);
    // ⑫ 空洞满足：零方法接口 + 命名行 ⇒ 1；非命名行 ⇒ -1（域限定先于空循环）
    isat_empty_ii := ts_t5_mk_iface("T0bEmpty");
    fails = fails + ts_check("isat.empty_iface_vacuous",
        ts_isat_b2i(find_iface(str_intern("T0bEmpty")) == isat_empty_ii &&
         iface_satisfies(isat_t_ti, str_intern("T0bEmpty")) == 1 &&
         iface_satisfies(TI_INT, str_intern("T0bEmpty")) == -1), 1);
    // ⑬ 泛型应用行：查方法走**基名**（decl_name_of_ti 的 TYP_GENERIC_APPLY 分支）
    grow_gen_apply_data(g_gen_apply_data_count + 2);
    isat_ga_s := g_gen_apply_data_count;
    w64(g_gen_apply_data, isat_ga_s * 8, 1);
    w64(g_gen_apply_data, (isat_ga_s + 1) * 8, TI_INT);
    g_gen_apply_data_count = isat_ga_s + 2;
    isat_ga_ti := alloc_type(TYP_GENERIC_APPLY, isat_s_ti, isat_ga_s);
    fails = fails + ts_check("isat.generic_apply_base_name",
        iface_satisfies(isat_ga_ti, str_intern("T0bShow")), 1);
    // ⑭ 三态 + 预算隔离：不可译行（越界 ti）/负键 ⇒ -1（**不得**当 0/1）；且**成功判定后**
    //    预算窗口必须干净（g_ty_steps 归零 + 上限 = 本层窗口常量；memo 不复用跨查询历史——
    //    P0 终审 Critical 3 的口径，同 type_equal_engine/gen_constr_satisfied）
    ty_budget_reset(200000);
    isat_bad_ti := g_type_count + 7;
    // 两条引擎路径：**节点同一快路径**（0 步）+ **非同一比较**（sub_cover 计步 ⇒ 出口复位可观测：
    // 缺出口复位时 g_ty_steps > 0 即红——MUT4 实证过「只用快路径 = 该断言空转」）
    isat_ok := iface_satisfies(TI_STR, str_intern("string"));   // 轴 B 快路径（勿用 int——⑨ 已声明同名接口）
    isat_no := iface_satisfies(TI_INT, str_intern("string"));   // 轴 B 非同一 ⇒ 计步
    fails = fails + ts_check("isat.three_state_budget_isolated",
        ts_isat_b2i(isat_ok == 1 && isat_no == 0 && g_ty_steps == 0 && g_ty_budget_max == IFACE_SAT_BUDGET &&
         iface_satisfies(isat_bad_ti, str_intern("int")) == -1 &&
         iface_satisfies(TI_INT, isat_bad_ti) == -1 &&
         iface_satisfies(-1, 0) == -1 && iface_satisfies(TI_INT, -1) == -1 &&
         iface_satisfies_term(-1, tt_top()) == -1 && iface_satisfies_term(TI_INT, -1) == -1 &&
         g_ty_exhausted == 0), 1);
    // ⑮ 形状表语义：覆盖（同名重注册不增长）+ 负键守卫 + 复位（count=0 ⇒ 同键未命中）
    isat_n := iface_shape_count();
    fails = fails + ts_check("isat.shape_registry_semantics",
        ts_isat_b2i(iface_shape_register(isat_shape_name, tt_top_k(AK_SEQUENCE)) == isat_slot &&
         iface_shape_count() == isat_n &&
         iface_shape_register(-1, tt_top()) == -1 &&
         iface_shape_register(isat_shape_name, -1) == -1 &&
         iface_shape_lookup(-1) == -1 &&
         iface_shape_lookup(str_intern("T0bNoShape")) == -1), 1);
    iface_shape_reset();
    fails = fails + ts_check("isat.shape_registry_reset",
        ts_isat_b2i(iface_shape_count() == 0 && iface_shape_lookup(isat_shape_name) == -1 &&
         iface_satisfies(isat_seq_ti, isat_shape_name) == -1), 1);
    return fails;
}

// ─── R2 P3b Task 2 用例体（独立函数：**不得**内联进 type_selftest_run——同 ts_t5_run 的
// 栈式代码生成上限理由；用例数 = **15**，调用方 `total = total + 15` 须同步）。
// 判据面 = ① 六条横切形状项（序列/只读/可写/可索引/可迭代/product）的**满足判定**；
// ② 两个**消费点换位的等价前提**（索引兜底门 ↔ IP_INDEX 许可集；range 固定性 ↔ TYP_ARRAY）
// 的**全类型行枚举**。
// **两路纪律**（Task 0 M4 教训：只走节点同一快路径的断言 = 空转）：每例除「判定值」外加一条
// 「非同一比较」断言（实参项 != 形状项 ⇒ 结果不可能由 ty_sub 的 `a == b` 快路径给出）；
// 两条枚举例的枚举规模单独断言（防零行遍历/真空通过）。
fn ts_x2_b(b: bool) -> int { if b { return 1; } return 0; }

fn ts_x2_run() -> int {
    fails : ., mut = 0;
    // ── 夹具（行面）──
    x2_arr := alloc_type(TYP_ARRAY, TI_INT, 3);        // 固定长序列（固定性位 = N = 3）
    x2_slice := alloc_type(TYP_SLICE, TI_INT, 0);      // 视图（固定性位 = -1）
    x2_ro_view := alloc_type(TYP_REF, x2_slice, 0);    // &[int]（只读视图）
    x2_rw_view := alloc_type(TYP_REF, x2_slice, 1);    // &mut [int]（可写视图）
    grow_gen_apply_data(g_gen_apply_data_count + 1);   // 元组行：字段列（product 面的行）
    x2_tup_start := g_gen_apply_data_count;
    w64(g_gen_apply_data, x2_tup_start * 8, TI_INT);
    g_gen_apply_data_count = x2_tup_start + 1;
    x2_tup := alloc_type(TYP_TUPLE, 1, x2_tup_start);
    x2_named := alloc_named_type(str_intern("X2ShapeN"));

    // ① 序列接口：数组 + 切片（皆 AK_SEQUENCE）满足；原生/只读视图/命名行不满足；**非同一**断言
    fails = fails + ts_check("x2.seq_accepts_body",
        ts_x2_b(iface_satisfies_term(x2_arr, sh_shape_seq()) == 1 &&
         iface_satisfies_term(x2_slice, sh_shape_seq()) == 1 &&
         sh_term_of_ti(x2_arr) != sh_shape_seq() && sh_term_of_ti(x2_slice) != sh_shape_seq()), 1);
    fails = fails + ts_check("x2.seq_rejects_non_body",
        ts_x2_b(iface_satisfies_term(TI_INT, sh_shape_seq()) == 0 &&
         iface_satisfies_term(x2_ro_view, sh_shape_seq()) == 0 &&
         iface_satisfies_term(x2_named, sh_shape_seq()) == 0), 1);
    // ② 只读序列：本体（数组/切片）+ 只读视图满足（视图面由 AK_REF **协变槽**判定 = 元素非 ⊤
    //    也成立，即「只读 = 协变」的兑现）；可写视图**不**满足（mut 标记等式语义 = Task 1 裁决）
    fails = fails + ts_check("x2.ro_accepts_body_and_ro_view",
        ts_x2_b(iface_satisfies_term(x2_arr, sh_shape_seq_ro()) == 1 &&
         iface_satisfies_term(x2_slice, sh_shape_seq_ro()) == 1 &&
         iface_satisfies_term(x2_ro_view, sh_shape_seq_ro()) == 1 &&
         iface_satisfies_term(x2_rw_view, sh_shape_seq_ro()) == 0 &&
         sh_term_of_ti(x2_ro_view) != sh_shape_seq_ro()), 1);
    // ③ 可写序列：本体满足（切片可写 = T1 探针 pSliceW `s[0] = 9` rc=0 实证）；**拒绝只读视图**
    fails = fails + ts_check("x2.rw_accepts_body_rejects_ro_view",
        ts_x2_b(iface_satisfies_term(x2_arr, sh_shape_seq_rw()) == 1 &&
         iface_satisfies_term(x2_slice, sh_shape_seq_rw()) == 1 &&
         iface_satisfies_term(x2_ro_view, sh_shape_seq_rw()) == 0 &&
         iface_satisfies_term(TI_INT, sh_shape_seq_rw()) == 0), 1);
    // ④ 可写**视图**形状不可表达（登记面，三态纪律）：ref(mut=1, ⊤ₖ(SEQ)) ⇒ **-1**（不变槽遇 ⊤ =
    //    未覆盖面），**不得**当 0/1（改成 0/1 的突变即红）。uncovered 位须**直调引擎**读
    //    （`iface_satisfies_term` 出口做预算复位 = 清该位——本层读不到，非「未置位」）。
    ty_budget_reset(200000);
    x2_rw_shape := tt_atom(AK_REF, -1, tt_cons(sh_ref_mut_marker(1), tt_cons(tt_top_k(AK_SEQUENCE), tt_nil())));
    x2_rw_s := iface_satisfies_term(x2_rw_view, x2_rw_shape);
    ty_budget_reset(200000);
    x2_rw_direct := ty_sub(sh_term_of_ti(x2_rw_view), x2_rw_shape);
    x2_rw_unc := ty_uncovered();
    fails = fails + ts_check("x2.rw_view_unexpressible",
        ts_x2_b(x2_rw_s == -1 && x2_rw_direct == -1 && x2_rw_unc == 1), 1);
    ty_budget_reset(200000);
    // ⑤ 可索引：字符串正控（checker 既有串下标结果分支）+ 序列；原生负控
    fails = fails + ts_check("x2.indexable_str_and_seq",
        ts_x2_b(iface_satisfies_term(TI_STR, sh_shape_indexable()) == 1 &&
         iface_satisfies_term(x2_arr, sh_shape_indexable()) == 1 &&
         iface_satisfies_term(x2_slice, sh_shape_indexable()) == 1 &&
         iface_satisfies_term(TI_INT, sh_shape_indexable()) == 0), 1);
    // ⑥ 可迭代（首版）+ product：序列满足迭代；元组行满足 product；原生/命名行皆否
    fails = fails + ts_check("x2.iterable_and_product",
        ts_x2_b(iface_satisfies_term(x2_arr, sh_shape_iterable()) == 1 &&
         iface_satisfies_term(x2_slice, sh_shape_iterable()) == 1 &&
         iface_satisfies_term(TI_INT, sh_shape_iterable()) == 0 &&
         iface_satisfies_term(x2_tup, sh_shape_product()) == 1 &&
         iface_satisfies_term(TI_INT, sh_shape_product()) == 0 &&
         iface_satisfies_term(x2_named, sh_shape_product()) == 0), 1);
    // ⑦ **消费点换位等价（索引门）**：可索引形状满足集 == IP_INDEX 许可集——全类型行枚举。
    //    checker 索引兜底门换位后行为保持的判据；枚举规模单独断言（反真空：行数/许可行数下界）
    x2_n_rows : ., mut = 0;
    x2_bad : ., mut = 0;
    x2_n_perm : ., mut = 0;
    x2_n_undec : ., mut = 0;
    x2_i : ., mut = 0;
    loop {
        if x2_i >= g_type_count { break; }
        x2_n_rows = x2_n_rows + 1;
        x2_s := iface_satisfies_term(x2_i, sh_shape_indexable());
        x2_o := iface_permits(iface_kind_of(x2_i), IP_INDEX);
        if x2_s == -1 {
            x2_n_undec = x2_n_undec + 1;
        } else {
            if x2_s == 1 { x2_n_perm = x2_n_perm + 1; }
            if (x2_s == 1) != (x2_o == 1) { x2_bad = x2_bad + 1; }
        }
        x2_i = x2_i + 1;
    }
    fails = fails + ts_check("x2.indexable_matches_ops",
        ts_x2_b(x2_n_rows == g_type_count && x2_n_rows >= 15 && x2_bad == 0 &&
         x2_n_perm >= 3 && x2_n_undec == 0 && get_type_kind(TI_STR) == TYP_BASE), 1);
    // ⑧ **消费点换位等价（range 分支）**：`形状满足 ∧ 固定性位 ≥ 0` == `kind == TYP_ARRAY`——
    //    全类型行枚举（固定长行与视图行**两类皆须出现**，否则枚举面真空）
    x2_bad2 : ., mut = 0;
    x2_n_fixed : ., mut = 0;
    x2_n_view : ., mut = 0;
    x2_j : ., mut = 0;
    loop {
        if x2_j >= g_type_count { break; }
        x2_s2 := iface_satisfies_term(x2_j, sh_shape_seq());
        if x2_s2 != -1 {
            x2_fixed : ., mut = 0;
            if x2_s2 == 1 {
                if sh_seq_fixed_len_of_ti(x2_j) >= 0 { x2_fixed = 1; }
            }
            x2_k : ., mut = 0;
            if get_type_kind(x2_j) == TYP_ARRAY { x2_k = 1; }
            if x2_fixed != x2_k { x2_bad2 = x2_bad2 + 1; }
            if x2_s2 == 1 {
                if x2_fixed == 1 { x2_n_fixed = x2_n_fixed + 1; } else { x2_n_view = x2_n_view + 1; }
            }
        }
        x2_j = x2_j + 1;
    }
    fails = fails + ts_check("x2.range_fixedness_matches_kind",
        ts_x2_b(x2_bad2 == 0 && x2_n_fixed >= 1 && x2_n_view >= 1), 1);
    // ⑨ 形状项的**名字面**（轴 A 生产入口）：六条规范项经注册表可按名判定（= Step 1「条目」的
    //    注册面兑现）；复位后同键 ⇒ -1（无泄漏）。
    //    R2 P4 Task 3 重钉（裁决 1 + D17）：**生产注册面**同例断言——`iface_shape_builtin_init()`
    //    显式重跑（幂等）后，六个 D17 名可按名查询且与 sh_shape_*() 构造点**同项**；
    //    随后照旧注册六个自测名（同名覆盖语义不受影响，计数 = 6 + 6）。
    iface_shape_builtin_init();
    x2_p1 := iface_shape_lookup(str_intern("sequence"));
    x2_p2 := iface_shape_lookup(str_intern("sequence_ro"));
    x2_p3 := iface_shape_lookup(str_intern("sequence_rw"));
    x2_p4 := iface_shape_lookup(str_intern("indexable"));
    x2_p5 := iface_shape_lookup(str_intern("iterable"));
    x2_p6 := iface_shape_lookup(str_intern("product"));
    fails = fails + ts_check("x2.shape_builtin_names", ts_x2_b(
        iface_shape_count() == 6 && x2_p1 == sh_shape_seq() && x2_p2 == sh_shape_seq_ro() &&
        x2_p3 == sh_shape_seq_rw() && x2_p4 == sh_shape_indexable() &&
        x2_p5 == sh_shape_iterable() && x2_p6 == sh_shape_product() &&
        iface_satisfies(x2_arr, str_intern("sequence")) == 1 &&
        iface_satisfies(TI_INT, str_intern("sequence")) == 0), 1);
    x2_n0 := iface_shape_count();
    x2_r1 := iface_shape_register(str_intern("X2NameSeq"), sh_shape_seq());
    x2_r2 := iface_shape_register(str_intern("X2NameIdx"), sh_shape_indexable());
    x2_r3 := iface_shape_register(str_intern("X2NameRo"), sh_shape_seq_ro());
    x2_r4 := iface_shape_register(str_intern("X2NameRw"), sh_shape_seq_rw());
    x2_r5 := iface_shape_register(str_intern("X2NameItr"), sh_shape_iterable());
    x2_r6 := iface_shape_register(str_intern("X2NameProd"), sh_shape_product());
    fails = fails + ts_check("x2.axis_a_registered",
        ts_x2_b(x2_r1 >= 0 && x2_r2 >= 0 && x2_r3 >= 0 && x2_r4 >= 0 && x2_r5 >= 0 && x2_r6 >= 0 &&
         iface_shape_count() == x2_n0 + 6 &&
         iface_satisfies(x2_arr, str_intern("X2NameSeq")) == 1 &&
         iface_satisfies(x2_arr, str_intern("X2NameIdx")) == 1 &&
         iface_satisfies(x2_ro_view, str_intern("X2NameRo")) == 1 &&
         iface_satisfies(x2_ro_view, str_intern("X2NameRw")) == 0 &&
         iface_satisfies(x2_tup, str_intern("X2NameProd")) == 1 &&
         iface_satisfies(TI_INT, str_intern("X2NameSeq")) == 0), 1);
    iface_shape_reset();
    // R2 P4 Task 3 重钉：复位守门口径不变（count = 0 + 旧键 -1）；**新增**生产注册面的
    // 「复位后可重建」断言（生产重置点 = reset_frontend_state 清 count，随 init_types 尾部
    // 的 iface_shape_builtin_init 重建 ⇒ 长驻进程每请求一致）。
    x2_restored : ., mut = 0;
    if iface_shape_count() == 0 && iface_satisfies(x2_arr, str_intern("X2NameSeq")) == -1 {
        iface_shape_builtin_init();
        if iface_shape_count() == 6 && iface_shape_lookup(str_intern("sequence")) == sh_shape_seq() {
            x2_restored = 1;
        }
    }
    fails = fails + ts_check("x2.shape_no_leak_after_reset",
        ts_x2_b(x2_restored == 1), 1);
    // ⑩ 零 str_intern（.ccr STR 段守卫）——R2 P4 Task 3 重定（裁决 1）：
    //    (a) **判定/查询路径零新增驻留**：形状项构造（六构造点）+ 按名查询 + 注册幂等重跑
    //        （iface_shape_builtin_init 重复调用）皆不得增长 g_strs；
    //    (b) **初始化/注册面的固定增量**：增量 = 逐名注册的 6 个 D17 名（在 init_types 首次
    //        调用时一次性支付——裁决 1 明示接受 STR 段增长），此后幂等 ⇒ 本处以「(a) 零增长 +
    //        六名可查（= 名字已驻留且 ni 解析正确）」两式联立钉住。
    //    注：T1..T2 期的绝对口径「构造路径恒零驻留」在初始化面已不成立（原文保留于
    //    iface_registry.cr 头注），本重定即该翻转的落地面。
    x2_strs := g_str_count;
    x2_t1 := sh_shape_seq();
    x2_t2 := sh_shape_seq_ro();
    x2_t3 := sh_shape_seq_rw();
    x2_t4 := sh_shape_indexable();
    x2_t5 := sh_shape_iterable();
    x2_t6 := sh_shape_product();
    x2_p1b := iface_shape_lookup(str_intern("sequence"));
    x2_p2b := iface_shape_lookup(str_intern("sequence_ro"));
    x2_p3b := iface_shape_lookup(str_intern("sequence_rw"));
    x2_p4b := iface_shape_lookup(str_intern("indexable"));
    x2_p5b := iface_shape_lookup(str_intern("iterable"));
    x2_p6b := iface_shape_lookup(str_intern("product"));
    iface_shape_builtin_init();   // 幂等重跑（不得再增长驻留表）
    fails = fails + ts_check("x2.no_str_intern",
        ts_x2_b(g_str_count == x2_strs && x2_t1 >= 0 && x2_t2 >= 0 && x2_t3 >= 0 &&
         x2_t4 >= 0 && x2_t5 >= 0 && x2_t6 >= 0 &&
         x2_p1b == x2_t1 && x2_p2b == x2_t2 && x2_p3b == x2_t3 &&
         x2_p4b == x2_t4 && x2_p5b == x2_t5 && x2_p6b == x2_t6), 1);
    // ⑪ 三态纪律（形状面）：越界行/负键/不可译行 ⇒ **-1**（不得当 0/1）；成功判定后预算窗口干净
    ty_budget_reset(200000);
    x2_ok := iface_satisfies_term(x2_arr, sh_shape_seq());     // 非同一 ⇒ 计步（非快路径）
    fails = fails + ts_check("x2.uncovered_not_folded",
        ts_x2_b(x2_ok == 1 && g_ty_steps == 0 && g_ty_budget_max == IFACE_SAT_BUDGET &&
         iface_satisfies_term(-1, sh_shape_seq()) == -1 &&
         iface_satisfies_term(g_type_count + 7, sh_shape_seq()) == -1 &&
         iface_satisfies_term(TI_INT, -1) == -1 &&
         iface_satisfies(x2_arr, -1) == -1 && iface_satisfies(-1, 0) == -1 &&
         g_ty_exhausted == 0), 1);
    // ⑫ 用户接口形状项（R2 P3b Task 6 Step 1 起**可建**）：零方法接口 ⇒ **空 product**（≥0，
    //    空洞满足的载体）；未声明的接口名 ⇒ -1（不得当 0/1）。判断面：命名行 + 零方法 = 满足 1
    //    （空洞）；原生行 = 域限定 -1。
    x2_ii := ts_t5_mk_iface("X2ShapeIface");
    fails = fails + ts_check("x2.iface_shape_term_built",
        ts_x2_b(find_iface(str_intern("X2ShapeIface")) == x2_ii &&
         sh_iface_shape_term(str_intern("X2ShapeIface")) >= 0 &&
         sh_iface_shape_term(str_intern("X2NoSuchIface")) == -1 &&
         iface_satisfies(x2_named, str_intern("X2ShapeIface")) == 1 &&
         iface_satisfies(TI_INT, str_intern("X2ShapeIface")) == -1), 1);
    // ⑬ 形状项与**行**的桥接关系（形状判定 = 行桥接 + 引擎包含，两层都不可少）：切片的项
    //    除固定性位外与数组项同形 ⇒ 两者同判（固定性**不**入形状判定——语义判定不看 N）
    x2_same : ., mut = 0;
    x2_ta := sh_term_of_ti(x2_arr);
    x2_ts := sh_term_of_ti(x2_slice);
    if x2_ta >= 0 && x2_ts >= 0 && x2_ta != x2_ts {
        if ty_sub(x2_ta, x2_ts) == 1 && ty_sub(x2_ts, x2_ta) == 1 { x2_same = 1; }
    }
    fails = fails + ts_check("x2.fixedness_not_in_shape_judgment",
        ts_x2_b(x2_same == 1 && sh_seq_fixed_len_of_ti(x2_arr) == 3 &&
         sh_seq_fixed_len_of_ti(x2_slice) == -1 && sh_seq_fixed_len_of_ti(TI_INT) == -1), 1);
    return fails;
}

// ═══════════════ R2 P3b Task 6：impl 契约用例（ifc.*）═══════════════
// 面（详见 ty_shadow.cr 的 sh_sig_term_of_ti / sh_iface_shape_term 注 + type_engine.cr 的
// iface_user_satisfies 注）：① **签名类型项化**——接口方法条目的类型**节点**槽是签名的忠实
// 来源，判定按**类型**（命名/泛型应用/接收者模式/元数）而非裸码；② **接口形状项** = 方法集
// （product of fn，b 槽 = 方法名）建项与不可建面；③ **mangling 退役**——方法解析走 g_methods
// 表、判定路径零 str_intern；④ 三态纪律（不可判 ⇒ -1，绝不当 0/1）。
// 夹具须与生产写点同形（parser 的 interface/impl 分支）：接口方法条目 = 节点槽 + 接收者模式；
// impl 函数行 = 真 EXPR_FN（形参链 + 类型节点，形参节点**不连续**）。
// 用例数 = 14（调用方 `total = total + 14` 须同步——增删用例两处一起改）。

// 命名类型夹具（结构声明 + SYM_TYPE 登记 + 命名行——供 res_type_node 的 EXPR_IDENT /
// EXPR_GENERIC_APPLY 两分支解析）。
fn ts_ifc_mk_named(name: string) -> int {
    ni := str_intern(name);
    add_struct(name);
    ti := alloc_named_type(ni);
    def_sym(ni, SYM_TYPE, ti, -1);
    return ti;
}

// 签名类型**节点**夹具：命名型（EXPR_IDENT，int_val = 名字 ni）
fn ts_ifc_named_node(name: string) -> int {
    return alloc_node(EXPR_IDENT, 0, 0, 0, str_intern(name), 0, 0, 0, 0);
}

// 签名类型节点：序列（EXPR_ARRAY；n = 长度，0 = 视图）——实参根单槽契约照 parser 产物
fn ts_ifc_seq_node(elem_node: int, n: int) -> int {
    return alloc_node(EXPR_ARRAY, elem_node, 0, 0, n, 0, 0, 0, 0);
}

// 签名类型节点：泛型应用（EXPR_GENERIC_APPLY；a = 基名 ni、b = 首实参节点（**连续**）、c = 个数）
fn ts_ifc_apply_node(base_name: string, arg_node: int) -> int {
    return alloc_node(EXPR_GENERIC_APPLY, str_intern(base_name), arg_node, 1, 0, 0, 0, 0, 0);
}

// 接口方法条目（节点面可控：pnodes = 参数节点缓冲（可 -1 = 全无节点）；rnode = 返回型节点；
// smode = 接收者模式（0 = 无接收者，1/2/3 = self/&self/&mut self））
fn ts_ifc_add_method_n(ii: int, mname: string, pc: int, smode: int, n0: int, n1: int, n2: int, n3: int, rnode: int) -> int {
    n := r64(g_ifaces, ii * ESZ_IFACEINFO + OFF_IF_METHOD_COUNT);
    mbase := ii * ESZ_IFACEINFO + OFF_IF_METHODS + n * ESZ_IFMETHOD;
    w64(g_ifaces, mbase + OFF_IFM_NAME, str_intern(mname));
    w64(g_ifaces, mbase + OFF_IFM_PARAM_COUNT, pc);
    w64(g_ifaces, mbase + OFF_IFM_RET_TI, 0);
    w64(g_ifaces, mbase + OFF_IFM_RET_NODE, rnode);
    w64(g_ifaces, mbase + OFF_IFM_SELF_MODE, smode);
    pj : ., mut = 0;
    loop {
        if pj >= pc || pj >= MAX_IFACE_METHOD_PARAMS { break; }
        pn : ., mut = -1;
        if pj == 0 { pn = n0; }
        if pj == 1 { pn = n1; }
        if pj == 2 { pn = n2; }
        if pj == 3 { pn = n3; }
        w64(g_ifaces, mbase + OFF_IFM_PARAM_TYPES + pj * 8, TY_INT);
        w64(g_ifaces, mbase + OFF_IFM_PARAM_NODES + pj * 8, pn);
        pj = pj + 1;
    }
    w64(g_ifaces, ii * ESZ_IFACEINFO + OFF_IF_METHOD_COUNT, n + 1);
    return mbase;
}

// impl 侧函数行（节点面可控；mode0 = 首参接收者模式（≠0 时该参无节点——接收者槽约定））。
// 返回 = 函数行号。
fn ts_ifc_add_impl(tname_ni: int, mname: string, pc: int, mode0: int, n0: int, n1: int, rnode: int) -> int {
    mn := istr_get(tname_ni) + "." + mname;
    mangled_ni := str_intern(mn);
    pf : ., mut = -1;
    pj : ., mut = 0;
    loop {
        if pj >= pc { break; }
        pn2 : ., mut = -1;
        m : ., mut = 0;
        if pj == 0 { m = mode0; }
        if m == 0 {
            if pj == 0 { pn2 = n0; }
            if pj == 1 { pn2 = n1; }
        }
        if pf < 0 { pf = g_ast_count; }
        alloc_node(EXPR_PARAM, str_intern("p"), 0, 0, m, TY_INT, pn2, 0, 0);
        pj = pj + 1;
    }
    fn_node := alloc_node(EXPR_FN, mangled_ni, pf, pc, 0, rnode, -1, 0, 0);
    fi := add_func(mn, pc, 0, fn_node);
    grow_methods(g_method_count + 1);
    w64(g_methods, g_method_count * 24, tname_ni);
    w64(g_methods, g_method_count * 24 + 8, str_intern(mname));
    w64(g_methods, g_method_count * 24 + 16, mangled_ni);
    g_method_count = g_method_count + 1;
    return fi;
}

fn ts_ifc_run() -> int {
    fails : ., mut = 0;
    // ── 夹具：4 个命名类型（A/B 同构异名——名义 vs 结构面）+ 3 个 impl 宿主 ──
    ifc_a_ti := ts_ifc_mk_named("IfcA");
    ts_ifc_mk_named("IfcB");
    ts_ifc_mk_named("IfcBox");
    ifc_a_n := ts_ifc_named_node("IfcA");
    ifc_b_n := ts_ifc_named_node("IfcB");
    ifc_int_n := ts_ifc_base_node(TY_INT);
    // 泛型应用节点：`IfcBox[IfcA]` / `IfcBox[IfcB]`（实参根单槽连续）
    ifc_ap_a := ts_ifc_apply_node("IfcBox", ifc_a_n);
    ifc_ap_b := ts_ifc_apply_node("IfcBox", ifc_b_n);
    // 序列节点：`[int; 3]` / `[int; 4]`
    ifc_seq3 := ts_ifc_seq_node(ifc_int_n, 3);
    ifc_seq4 := ts_ifc_seq_node(ifc_int_n, 4);
    // 接口：IfcI0 { m(x: IfcA) -> IfcB }（无接收者；参数/返回皆命名型）
    ifc_ii0 := ts_t5_mk_iface("IfcI0");
    ts_ifc_add_method_n(ifc_ii0, "m", 1, 0, ifc_a_n, -1, -1, -1, ifc_b_n);
    // 命中：同签名
    ifc_h_ti := ts_ifc_mk_named("IfcH");
    ts_ifc_add_impl(str_intern("IfcH"), "m", 1, 0, ifc_a_n, -1, ifc_b_n);
    // 参数类型不符（IfcB ← IfcA）
    ifc_p_ti := ts_ifc_mk_named("IfcP");
    ts_ifc_add_impl(str_intern("IfcP"), "m", 1, 0, ifc_b_n, -1, ifc_b_n);
    // 返回类型不符（int ← IfcB）
    ifc_r_ti := ts_ifc_mk_named("IfcR");
    ts_ifc_add_impl(str_intern("IfcR"), "m", 1, 0, ifc_a_n, -1, ifc_int_n);

    // ① 签名类型项化（参数面）：命名参数型按**类型**判定——同型 1 / 异型 0（旧态两侧皆码 0 ⇒ 恒等）
    fails = fails + ts_check("ifc.sig_named_param_bound",
        ts_isat_b2i(iface_satisfies(ifc_h_ti, str_intern("IfcI0")) == 1 &&
         iface_satisfies(ifc_p_ti, str_intern("IfcI0")) == 0), 1);
    // ② 签名类型项化（返回面）：命名返回型 vs 原生返回型 ⇒ 0；同命名型 ⇒ 1（编码面闭合的直接判据）
    fails = fails + ts_check("ifc.sig_named_ret_bound",
        ts_isat_b2i(iface_satisfies(ifc_r_ti, str_intern("IfcI0")) == 0 &&
         iface_satisfies(ifc_h_ti, str_intern("IfcI0")) == 1), 1);
    // ③ 泛型应用实参面：`IfcBox[IfcA]` vs `IfcBox[IfcB]` ⇒ 0；同实参 ⇒ 1
    //    （旧态：应用行裸码塌缩为 0 ⇒ 静默判等；规范形展开基名 + 实参链 ⇒ 异实参异节点）
    ifc_ii1 := ts_t5_mk_iface("IfcI1");
    ts_ifc_add_method_n(ifc_ii1, "m", 1, 0, ifc_ap_a, -1, -1, -1, ifc_int_n);
    ifc_g_ti := ts_ifc_mk_named("IfcG");
    ts_ifc_add_impl(str_intern("IfcG"), "m", 1, 0, ifc_ap_a, -1, ifc_int_n);
    ifc_g2_ti := ts_ifc_mk_named("IfcG2");
    ts_ifc_add_impl(str_intern("IfcG2"), "m", 1, 0, ifc_ap_b, -1, ifc_int_n);
    fails = fails + ts_check("ifc.sig_apply_arg_bound",
        ts_isat_b2i(iface_satisfies(ifc_g_ti, str_intern("IfcI1")) == 1 &&
         iface_satisfies(ifc_g2_ti, str_intern("IfcI1")) == 0), 1);
    // ④ 接收者模式是判定维度：iface `&self`（2）vs impl `self`（1）/`&mut self`（3）⇒ 0；同模式 ⇒ 1
    ifc_ii2 := ts_t5_mk_iface("IfcI2");
    ts_ifc_add_method_n(ifc_ii2, "m", 1, 2, -1, -1, -1, -1, ifc_int_n);
    ifc_m1_ti := ts_ifc_mk_named("IfcM1");
    ts_ifc_add_impl(str_intern("IfcM1"), "m", 1, 1, -1, -1, ifc_int_n);
    ifc_m2_ti := ts_ifc_mk_named("IfcM2");
    ts_ifc_add_impl(str_intern("IfcM2"), "m", 1, 2, -1, -1, ifc_int_n);
    ifc_m3_ti := ts_ifc_mk_named("IfcM3");
    ts_ifc_add_impl(str_intern("IfcM3"), "m", 1, 3, -1, -1, ifc_int_n);
    fails = fails + ts_check("ifc.sig_receiver_mode",
        ts_isat_b2i(iface_satisfies(ifc_m2_ti, str_intern("IfcI2")) == 1 &&
         iface_satisfies(ifc_m1_ti, str_intern("IfcI2")) == 0 &&
         iface_satisfies(ifc_m3_ti, str_intern("IfcI2")) == 0), 1);
    // ⑤ 元数（链长）：iface 1 参 vs impl 2 参 ⇒ 0（链形不同）；impl 0 参 ⇒ 0
    ifc_w_ti := ts_ifc_mk_named("IfcW");
    ts_ifc_add_impl(str_intern("IfcW"), "m", 2, 0, ifc_a_n, ifc_int_n, ifc_b_n);
    ifc_w0_ti := ts_ifc_mk_named("IfcW0");
    ts_ifc_add_impl(str_intern("IfcW0"), "m", 0, 0, -1, -1, ifc_b_n);
    fails = fails + ts_check("ifc.sig_arity_chain",
        ts_isat_b2i(iface_satisfies(ifc_w_ti, str_intern("IfcI0")) == 0 &&
         iface_satisfies(ifc_w0_ti, str_intern("IfcI0")) == 0), 1);
    // ⑥ N **不入**签名身份（P3a 不变量）：`[int;3]` vs `[int;4]` ⇒ 1（长度面由常量档承担）
    ifc_ii3 := ts_t5_mk_iface("IfcI3");
    ts_ifc_add_method_n(ifc_ii3, "m", 1, 0, ifc_seq3, -1, -1, -1, ifc_int_n);
    ifc_n_ti := ts_ifc_mk_named("IfcN");
    ts_ifc_add_impl(str_intern("IfcN"), "m", 1, 0, ifc_seq4, -1, ifc_int_n);
    fails = fails + ts_check("ifc.sig_len_not_in_identity",
        ts_isat_b2i(iface_satisfies(ifc_n_ti, str_intern("IfcI3")) == 1), 1);
    // ⑦ 命名行**名义**（不展开）：IfcA 与 IfcB 结构同构（皆零字段）但不可互换 ⇒ 0
    //    （判定不落引擎的 AK_NAMED 展开面——签名身份按**行**（同名字同行））
    fails = fails + ts_check("ifc.sig_named_nominal_not_structural",
        ts_isat_b2i(iface_satisfies(ifc_p_ti, str_intern("IfcI1")) == 0 &&
         iface_satisfies(ifc_g_ti, str_intern("IfcI1")) == 1), 1);
    // ⑧ 接口形状项 = 方法集（product of fn）：成员数 = 方法数、成员 b 槽 = 方法名、
    //    链长 = 1 + 参数数；越界成员 ⇒ -1
    ifc_ii4 := ts_t5_mk_iface("IfcI4");
    ts_ifc_add_method_n(ifc_ii4, "m", 1, 0, ifc_a_n, -1, -1, -1, ifc_b_n);
    ts_ifc_add_method_n(ifc_ii4, "n", 2, 0, ifc_a_n, ifc_int_n, -1, -1, ifc_int_n);
    ifc_shp := sh_iface_shape_term(str_intern("IfcI4"));
    ifc_m0 := sh_shape_member_at(ifc_shp, 0);
    ifc_m1 := sh_shape_member_at(ifc_shp, 1);
    ifc_chain_ok : ., mut = 0;
    if ifc_m0 >= 0 && ifc_m1 >= 0 {
        c0 := tt_c(ifc_m0);
        c1 := tt_c(ifc_m1);
        // 链长（1 + pc）：cons(ret, cons(p…)) ⇒ 2 元链（pc=1）/ 3 元链（pc=2）
        if tt_tag(c0) == TT_CONS && tt_tag(tt_b(c0)) == TT_CONS && tt_tag(tt_b(tt_b(c0))) == TT_NIL {
            if tt_tag(c1) == TT_CONS && tt_tag(tt_b(c1)) == TT_CONS {
                if tt_tag(tt_b(tt_b(c1))) == TT_CONS && tt_tag(tt_b(tt_b(tt_b(c1)))) == TT_NIL { ifc_chain_ok = 1; }
            }
        }
    }
    fails = fails + ts_check("ifc.shape_product_of_fn",
        ts_isat_b2i(ifc_shp >= 0 && tt_tag(ifc_shp) == TT_ATOM && tt_a(ifc_shp) == AK_PRODUCT &&
         ifc_m0 >= 0 && tt_tag(ifc_m0) == TT_ATOM && tt_a(ifc_m0) == AK_FN &&
         tt_b(ifc_m0) == str_intern("m") && tt_b(ifc_m1) == str_intern("n") &&
         ifc_chain_ok == 1 && sh_shape_member_at(ifc_shp, 2) == -1 &&
         sh_shape_member_at(ifc_shp, -1) == -1), 1);
    // ⑨ 形状项不可建面：参数数越界（9 > MAX_IFACE_METHOD_PARAMS）⇒ -1（未覆盖面，不得当 0/1）；
    //    未声明接口名 ⇒ -1
    ifc_ii5 := ts_t5_mk_iface("IfcI5");
    ts_ifc_add_method_n(ifc_ii5, "m", 9, 0, -1, -1, -1, -1, ifc_int_n);
    fails = fails + ts_check("ifc.shape_build_unjudged",
        ts_isat_b2i(sh_iface_shape_term(str_intern("IfcI5")) == -1 &&
         sh_iface_shape_term(str_intern("IfcNope")) == -1 &&
         iface_satisfies(ifc_h_ti, str_intern("IfcI5")) == -1), 1);
    // ⑩ mangling 退役：判定/查表路径**零 str_intern**（缺失方法 = 判定 0 的路径也不得驻留新串
    //    ——旧 `type_has_method` 的 `str_intern("T.m")` 形态在此会增长表）
    ifc_zz_ti := ts_ifc_mk_named("IfcZz");
    ifc_strs := g_str_count;
    ifc_p1 := iface_satisfies(ifc_zz_ti, str_intern("IfcI0"));
    ifc_p2 := type_has_method(str_intern("IfcZz"), str_intern("m"));
    fails = fails + ts_check("ifc.mangling_zero_str_intern",
        ts_isat_b2i(ifc_p1 == 0 && ifc_p2 == false && g_str_count == ifc_strs), 1);
    // ⑪ 方法解析 = 表查询（`type_has_method` ⇔ `iface_find_method >= 0`）：在位 true / 缺失 false
    fails = fails + ts_check("ifc.type_has_method_table",
        ts_isat_b2i(type_has_method(str_intern("IfcH"), str_intern("m")) == true &&
         type_has_method(str_intern("IfcZz"), str_intern("m")) == false &&
         iface_find_method(str_intern("IfcH"), str_intern("m")) >= 0 &&
         iface_find_method(str_intern("IfcZz"), str_intern("m")) < 0), 1);
    // ⑫ 同源对拍（check_iface bool 面 ⇔ iface_satisfies 三态面 的 1 侧）：三形态逐例相等
    ifc_eq : ., mut = 0;
    if ts_isat_b2i(check_iface(str_intern("IfcH"), ifc_ii0)) == iface_satisfies(ifc_h_ti, str_intern("IfcI0")) {
        if ts_isat_b2i(check_iface(str_intern("IfcP"), ifc_ii0)) == iface_satisfies(ifc_p_ti, str_intern("IfcI0")) {
            if ts_isat_b2i(check_iface(str_intern("IfcR"), ifc_ii0)) == iface_satisfies(ifc_r_ti, str_intern("IfcI0")) {
                ifc_eq = 1;
            }
        }
    }
    fails = fails + ts_check("ifc.check_iface_same_source", ifc_eq, 1);
    // ⑬ 三态（域限定与不可判）：非命名行（原生/泛型形参/dyn）⇒ -1；零方法接口 + 命名行 ⇒ 1
    //    （空洞满足）；未知接口名 ⇒ -1
    ifc_gp_ti := alloc_type(TYP_GENERIC_PARAM, str_intern("IfcU"), 0);
    ifc_dyn_ti := alloc_type(TYP_DYN, 0, 0);
    ifc_ii6 := ts_t5_mk_iface("IfcI6");
    fails = fails + ts_check("ifc.three_state_unjudged",
        ts_isat_b2i(iface_satisfies(TI_INT, str_intern("IfcI0")) == -1 &&
         iface_satisfies(ifc_gp_ti, str_intern("IfcI0")) == -1 &&
         iface_satisfies(ifc_dyn_ti, str_intern("IfcI0")) == -1 &&
         iface_satisfies(ifc_h_ti, str_intern("IfcI6")) == 1 &&
         iface_satisfies(ifc_h_ti, str_intern("IfcNope")) == -1 &&
         iface_satisfies(-1, str_intern("IfcI0")) == -1), 1);
    // ⑭ 空 product 的形状面：零方法接口的形状项链为空（tt_nil）——成员/链形判据
    ifc_shp6 := sh_iface_shape_term(str_intern("IfcI6"));
    fails = fails + ts_check("ifc.shape_empty_product",
        ts_isat_b2i(ifc_shp6 >= 0 && tt_tag(ifc_shp6) == TT_ATOM && tt_a(ifc_shp6) == AK_PRODUCT &&
         tt_c(ifc_shp6) >= 0 && tt_tag(tt_c(ifc_shp6)) == TT_NIL &&
         sh_shape_member_at(ifc_shp6, 0) == -1 && ifc_a_ti >= 0), 1);
    return fails;
}

// ═══════════ R2 P5 Task 3：命名面判定化（身份链 + 可判定面加强）用例段 ═══════════
// 判据面（行为/结构断言，**不依赖 legacy 存活**——影子层下线后本段仍是回归网组件；
// 源级探针面见 tests/selfhost/test_named_face.py）：
//   ① 链形态（**双构造点逐位同构**：NAMED/PARAM = [名字令牌]；APPLY = [基名令牌, 实参项…]）；
//   ② 同链 ⇒ 1 / 链异 ⇒ 0（同名/异名命名；同/异实参泛型应用；嵌套应用）；
//   ③ 混类（命名 × 原生）⇒ 0（= legacy 跨 kind 同结论 = false）；
//   ④ 域外 ⇒ -1（空链 / 令牌位错位 / 实参位 μ 变元 / NEVER·DYN 混类）——三态纪律
//      （不得近似成 0/1）；
//   ⑤ 清零判据（二进制内）：命名面经 type_equal = 引擎自决 + **零 ICE04 诊断**（T4：回落
//      计数随 legacy 删除，断言形态由「计数零增量」升级为「未知诊断缺席」）；
//   ⑥ **残留面**（计划停条件②）= 参数链**不变槽**的元素非同形（`[NA;2]` vs `[NB;2]`）：
//      T3 时未动（可判定但属 `tt_list_variance_at` 不变槽，须单独裁决）⇒ **T3b 已关闭**
//      （`te_elem_cmp` 三态；断言迁往 `ts_t3b_run` 段——本段只剩同元素对照）。
// 夹具 = 人造行（alloc_named_type/alloc_type），不进生产侧表语义面，只服务本段断言。
fn ts_t3n_run() -> int {
    fails : ., mut = 0;
    ty_budget_reset(200000);
    n_a := alloc_named_type(str_intern("T3NA"));
    n_b := alloc_named_type(str_intern("T3NB"));
    na_ni := get_type_data(n_a);
    ta := sh_term_of_ti(n_a);
    tb := sh_term_of_ti(n_b);
    // ① 链形态：b 槽 = 行号（标注；D21 的 atom_of 消费者），c = [令牌(name_ni)]
    fails = fails + ts_check("t3n.chain_shape",
        (ta >= 0 && tt_a(ta) == AK_NAMED && tt_b(ta) == n_a &&
         tt_c(ta) >= 0 && tt_tag(tt_c(ta)) == TT_CONS &&
         tt_a(tt_c(ta)) == sh_name_token(na_ni) &&
         tt_b(tt_c(ta)) >= 0 && tt_tag(tt_b(tt_c(ta))) == TT_NIL), 1);
    // ① D21 契约不回退：atom_of 仍读 b（命名行 = 本行；应用行 = 基型行，规范形）
    // ② 同名 ⇒ 同行（named_dedup）⇒ 同节点 ⇒ 等价 1；异名 ⇒ 0（双向）
    n_a2 := alloc_named_type(str_intern("T3NA"));
    fails = fails + ts_check("t3n.same_name_same_row",
        (n_a2 == n_a && sh_term_of_ti(n_a2) == ta && ty_equiv(ta, sh_term_of_ti(n_a2)) == 1), 1);
    fails = fails + ts_check("t3n.diff_name_diff",
        (ty_sub(ta, tb) == 0 && ty_sub(tb, ta) == 0 && ty_equiv(ta, tb) == 0), 1);
    // ③ 混类：命名 × 原生 ⇒ 0（名义型与异类原子不交）
    fails = fails + ts_check("t3n.named_vs_base_zero",
        (ty_equiv(ta, sh_term_of_ti(TI_INT)) == 0 && ty_equiv(ta, sh_term_of_ti(TI_STR)) == 0 &&
         ty_equiv(sh_term_of_ti(TI_STR), ta) == 0), 1);
    // ④ 域外：NEVER/DYN 混类 ⇒ -1 + 未覆盖面位置位（⊥/⊤ 语义未建模，登记）
    ty_budget_reset(200000);
    dn := ty_equiv(ta, sh_term_of_ti(TI_NEVER));
    unc1 := ty_uncovered();
    ty_budget_reset(200000);
    dd := ty_equiv(ta, sh_term_of_ti(TI_DYN));
    unc2 := ty_uncovered();
    fails = fails + ts_check("t3n.never_dyn_out_of_domain",
        (dn == -1 && dd == -1 && unc1 == 1 && unc2 == 1), 1);
    // ④ 域外：空链（无身份 = 未覆盖面②原形态）⇒ -1
    ty_budget_reset(200000);
    dnc := ty_equiv(tt_atom(AK_NAMED, -1, -1), ta);
    fails = fails + ts_check("t3n.no_chain_out_of_domain", (dnc == -1 && ty_uncovered() == 1), 1);
    // ④ 域外：令牌位放类型项 ⇒ -1（位置错位不猜）
    ty_budget_reset(200000);
    mis1 := ty_equiv(tt_atom(AK_NAMED, -1, tt_cons(tt_atom(AK_INT, TI_INT, -1), tt_nil())), ta);
    fails = fails + ts_check("t3n.token_pos_mismatch_out", (mis1 == -1 && ty_uncovered() == 1), 1);
    // ④ 域外：实参位 μ 变元 ⇒ -1（实参位只收类型项；令牌位同节点 ⇒ 比较推进到实参位）
    bad_arg := tt_atom(AK_NAMED, n_a, tt_cons(sh_name_token(na_ni), tt_cons(tt_var(0), tt_nil())));
    good_arg := tt_atom(AK_NAMED, n_a, tt_cons(sh_name_token(na_ni), tt_cons(sh_term_of_ti(TI_INT), tt_nil())));
    ty_budget_reset(200000);
    mis2 := ty_equiv(bad_arg, good_arg);
    fails = fails + ts_check("t3n.arg_var_out_of_domain", (mis2 == -1 && ty_uncovered() == 1), 1);
    // ⑤ 清零判据（二进制内）：命名面经 type_equal = **引擎自决**——R2 P5 Task 4 后回落计数
    //    本体已删（legacy 一并删除）⇒ 断言升级为「自决 + **零 ICE04 诊断**」：诊断缺席 = 引擎
    //    真判（0/1），而不是「未知被静默当 false」（P-A 的牙齿 = t4.ice04_* 三例）。
    t3n_d0 := g_diag_count;
    eqf : ., mut = 0;
    if !type_equal(n_a, n_b) {
        if g_diag_count == t3n_d0 { eqf = 1; }
    }
    fails = fails + ts_check("t3n.decided_no_indeterminate", (eqf == 1 && ty_sub(ta, tb) == 0), 1);
    // ② 泛型应用：规范形 b = 基型行 + 链 [基名令牌, 实参项…]
    grow_gen_apply_data(g_gen_apply_data_count + 2);
    gs1 := g_gen_apply_data_count;
    w64(g_gen_apply_data, gs1 * 8, 1);
    w64(g_gen_apply_data, (gs1 + 1) * 8, TI_INT);
    g_gen_apply_data_count = gs1 + 2;
    ga1 := alloc_type(TYP_GENERIC_APPLY, n_a, gs1);
    ga2 := alloc_type(TYP_GENERIC_APPLY, n_a, gs1);      // **另一行**，同基型同实参
    grow_gen_apply_data(g_gen_apply_data_count + 2);
    gs2 := g_gen_apply_data_count;
    w64(g_gen_apply_data, gs2 * 8, 1);
    w64(g_gen_apply_data, (gs2 + 1) * 8, TI_STR);
    g_gen_apply_data_count = gs2 + 2;
    ga3 := alloc_type(TYP_GENERIC_APPLY, n_a, gs2);      // 同基型**异实参**
    t_ga1 := sh_term_of_ti(ga1);
    t_ga2 := sh_term_of_ti(ga2);
    t_ga3 := sh_term_of_ti(ga3);
    fails = fails + ts_check("t3n.apply_canonical_b",
        (t_ga1 >= 0 && tt_a(t_ga1) == AK_NAMED && tt_b(t_ga1) == n_a &&
         tt_atom_of_term(t_ga1) == n_a &&
         tt_c(t_ga1) >= 0 && tt_tag(tt_c(t_ga1)) == TT_CONS &&
         tt_a(tt_c(t_ga1)) == sh_name_token(na_ni) &&
         tt_a(tt_b(tt_c(t_ga1))) == sh_term_of_ti(TI_INT)), 1);
    fails = fails + ts_check("t3n.apply_two_rows_same_args",
        (ga1 != ga2 && t_ga1 == t_ga2 && ty_equiv(t_ga1, t_ga2) == 1), 1);
    fails = fails + ts_check("t3n.apply_diff_args_zero",
        (ty_sub(t_ga1, t_ga3) == 0 && ty_sub(t_ga3, t_ga1) == 0), 1);
    fails = fails + ts_check("t3n.apply_vs_bare_diff",
        (ty_sub(t_ga1, ta) == 0 && ty_sub(ta, t_ga1) == 0), 1);
    // ② 双构造点逐位同构（计划停条件③守门）：同型两构造 ⇒ **同节点**
    fails = fails + ts_check("t3n.two_points_isomorphic",
        (sh_sig_term_of_ti(n_a) == ta && sh_sig_term_of_ti(ga1) == t_ga1), 1);
    // ② 嵌套应用：Box[Box[int]] 两处（外层实参分别指向同实参的**不同行**）⇒ 同节点
    grow_gen_apply_data(g_gen_apply_data_count + 2);
    gs3 := g_gen_apply_data_count;
    w64(g_gen_apply_data, gs3 * 8, 1);
    w64(g_gen_apply_data, (gs3 + 1) * 8, ga1);
    g_gen_apply_data_count = gs3 + 2;
    ga4 := alloc_type(TYP_GENERIC_APPLY, n_a, gs3);
    grow_gen_apply_data(g_gen_apply_data_count + 2);
    gs4 := g_gen_apply_data_count;
    w64(g_gen_apply_data, gs4 * 8, 1);
    w64(g_gen_apply_data, (gs4 + 1) * 8, ga2);
    g_gen_apply_data_count = gs4 + 2;
    ga5 := alloc_type(TYP_GENERIC_APPLY, n_a, gs4);
    fails = fails + ts_check("t3n.nested_apply_same",
        (ga4 != ga5 && sh_term_of_ti(ga4) == sh_term_of_ti(ga5)), 1);
    // ② 可选面（union）：NA ⊂ NA?（注入面）⇒ 1；NA? vs NB?（内层异名）⇒ 0
    opt_a := tt_union(ta, sh_null_term());
    opt_b := tt_union(tb, sh_null_term());
    fails = fails + ts_check("t3n.optional_named",
        (ty_sub(ta, opt_a) == 1 && ty_sub(opt_a, opt_b) == 0), 1);
    // ④ 域外：union 面含**无链**命名原子（未覆盖面②原形态）⇒ 仍 -1（加强不得把
    // 未范化/域外并集面误判成 0——计划 Step 1 的 union 负控）
    ty_budget_reset(200000);
    u_out := ty_equiv(tt_union(tt_atom(AK_NAMED, -1, -1), sh_null_term()),
                      tt_union(tt_atom(AK_NAMED, -2, -1), sh_null_term()));
    fails = fails + ts_check("t3n.union_out_of_domain", (u_out == -1 && ty_uncovered() == 1), 1);
    // ⑥ 残留面**已关闭**（R2 P5 Task 3b：不变槽元素三态 te_elem_cmp）——断言迁移到
    // `t3b.inv_slot_seq_named_diff_zero`（本段不再钉「-1」；翻转向量见 p5-task3b 报告）
    // ⑥ 对照：同元素（不同行）⇒ 1（N 不入身份 + 同链 ⇒ 快路径）
    arr_a := sh_seq_term(n_a, 2);
    arr_a2 := sh_seq_term(n_a, 2);
    fails = fails + ts_check("t3n.same_elem_seq_equiv", ty_equiv(arr_a, arr_a2), 1);
    return fails;
}

// ═══════════ R2 P5 Task 3b：不变槽元素三态（te_elem_cmp）用例段 ═══════════
// 关闭 P5 Task 3 §6 登记的残留面（交接条目即本段 RED 面）。判据六面：
//   ① 主形态：序列/指针/元组/嵌套的**不变槽**元素 = 异名命名原子 ⇒ 引擎自决 **0**
//      （双向）+ **零未覆盖面**（= 红态计数面：改前 unknown_engine=1 replace_unknown=1）；
//   ② 不误伤等价面：同元素（另一行）/ N 面（`[T;2]` vs `[T;3]`）/ 同令牌 ⇒ **1**；
//   ③ 令牌位（AK_SUM 链槽 0/1 = 枚举名/变体名令牌）按**节点同一性**：异名 ⇒ 0、同名 ⇒ 1；
//   ④ 域外守卫：链元素**既非令牌也非类型项**（μ 变元）⇒ 仍 **-1 + 未覆盖面**（不近似成 0）；
//   ⑤ 负控（报告 §6.1 点名的两例）：(a) 同名令牌 ⇒ **同一节点**（DAG 去重 ⇒ 结构上不存在
//      「同名不同节点」，节点同一性比较不可能把同名令牌判不同）；(b) 令牌 × 原生 unit 项
//      **同形**（AK_UNIT ∧ b ≥ 0）——`ty_equiv` 判**等**（令牌碰撞类的实证），`te_elem_cmp`
//      令牌先判 ⇒ 0（绝不产生假等；失效方向选择见 type_engine.cr 该函数头注）；
//   ⑥ 二进制面清零判据：数组行经 `type_equal` = **引擎自决 + 零 ICE04 诊断**（T4 重钉：
//      回落计数随 legacy 删除，断言形态改为「未知诊断缺席」）。
// 夹具 = 人造行（alloc_named_type/alloc_type，同名 ⇒ 同名去重行）；不进生产侧表语义面。
fn ts_t3b_run() -> int {
    fails : ., mut = 0;
    ty_budget_reset(200000);
    n_a := alloc_named_type(str_intern("T3NA"));
    n_b := alloc_named_type(str_intern("T3NB"));
    t_a := sh_term_of_ti(n_a);
    t_b := sh_term_of_ti(n_b);
    t_int := sh_term_of_ti(TI_INT);
    // ① 序列元素（AK_SEQUENCE 链槽 0）：异名 ⇒ 0 双向 + 零未覆盖面
    arr_a := alloc_type(TYP_ARRAY, n_a, 2);
    arr_b := alloc_type(TYP_ARRAY, n_b, 2);
    ty_budget_reset(200000);
    ab := ty_sub(sh_term_of_ti(arr_a), sh_term_of_ti(arr_b));
    ba := ty_sub(sh_term_of_ti(arr_b), sh_term_of_ti(arr_a));
    fails = fails + ts_check("t3b.inv_slot_seq_named_diff_zero",
        ts_isat_b2i(ab == 0 && ba == 0 && ty_uncovered() == 0), 1);
    // ① 指针元素（AK_PTR 链槽 0）⇒ 0
    ty_budget_reset(200000);
    pb := ty_sub(tt_atom(AK_PTR, -1, tt_cons(t_a, tt_nil())),
                 tt_atom(AK_PTR, -1, tt_cons(t_b, tt_nil())));
    fails = fails + ts_check("t3b.inv_slot_ptr_named_diff_zero",
        ts_isat_b2i(pb == 0 && ty_uncovered() == 0), 1);
    // ① 元组字段位（AK_PRODUCT 链；第 2 字段同项 = 对照组）⇒ 0
    ty_budget_reset(200000);
    pr := ty_sub(tt_atom(AK_PRODUCT, -1, tt_cons(t_a, tt_cons(t_int, tt_nil()))),
                 tt_atom(AK_PRODUCT, -1, tt_cons(t_b, tt_cons(t_int, tt_nil()))));
    fails = fails + ts_check("t3b.inv_slot_prod_named_diff_zero",
        ts_isat_b2i(pr == 0 && ty_uncovered() == 0), 1);
    // ① 嵌套（元素 = 序列项 ⇒ 经 te_elem_cmp 的类型项面递归）：[[NA;2];2] vs [[NB;2];2] ⇒ 0
    nest_a := alloc_type(TYP_ARRAY, alloc_type(TYP_ARRAY, n_a, 2), 2);
    nest_b := alloc_type(TYP_ARRAY, alloc_type(TYP_ARRAY, n_b, 2), 2);
    ty_budget_reset(200000);
    ns := ty_sub(sh_term_of_ti(nest_a), sh_term_of_ti(nest_b));
    fails = fails + ts_check("t3b.inv_slot_nested_seq_diff_zero",
        ts_isat_b2i(ns == 0 && ty_uncovered() == 0), 1);
    // ② 等价面不被压成 0：N 面（[NA;2] vs [NA;3] ⇒ 1）+ 同元素**另一行** ⇒ 1
    ty_budget_reset(200000);
    n_eq := ty_equiv(sh_term_of_ti(arr_a), sh_term_of_ti(alloc_type(TYP_ARRAY, n_a, 3)));
    r_eq := ty_equiv(sh_term_of_ti(arr_a), sh_term_of_ti(alloc_type(TYP_ARRAY, n_a, 2)));
    fails = fails + ts_check("t3b.equiv_face_not_crushed",
        ts_isat_b2i(n_eq == 1 && r_eq == 1 && ty_uncovered() == 0), 1);
    // ③ 令牌位：AK_SUM 链 = [枚举名令牌, 变体名令牌]（皆不变槽）——异变体名 ⇒ 0
    e1 := str_intern("T3bE1");
    v1 := str_intern("T3bV1");
    v2 := str_intern("T3bV2");
    sum_v1 := tt_atom(AK_SUM, -1, tt_cons(sh_name_token(e1), tt_cons(sh_name_token(v1), tt_nil())));
    sum_v2 := tt_atom(AK_SUM, -1, tt_cons(sh_name_token(e1), tt_cons(sh_name_token(v2), tt_nil())));
    ty_budget_reset(200000);
    sv := ty_sub(sum_v1, sum_v2);
    fails = fails + ts_check("t3b.token_slot_variant_diff_zero",
        ts_isat_b2i(sv == 0 && ty_uncovered() == 0), 1);
    // ③ 同令牌 ⇒ 同节点 ⇒ 1（同枚举同变体两处构造）
    sum_v1x := tt_atom(AK_SUM, -1, tt_cons(sh_name_token(e1), tt_cons(sh_name_token(v1), tt_nil())));
    fails = fails + ts_check("t3b.token_slot_same_one",
        ts_isat_b2i(sum_v1 == sum_v1x && ty_equiv(sum_v1, sum_v1x) == 1), 1);
    // ⑤(a) 负控：同名令牌 ⇒ 同一节点（DAG 去重）——「同名不同节点」结构上不可达；
    // mut 标记同式（同值同节点、异值异节点）
    fails = fails + ts_check("t3b.token_same_name_same_node",
        ts_isat_b2i(sh_name_token(e1) == sh_name_token(e1) &&
                    sh_name_token(e1) != sh_name_token(v1) &&
                    sh_ref_mut_marker(0) == sh_ref_mut_marker(0) &&
                    sh_ref_mut_marker(0) != sh_ref_mut_marker(1)), 1);
    // ⑤(b) 负控：令牌 × 原生 unit 项同形 ⇒ ty_equiv 判**等**（碰撞实证）；
    // te_elem_cmp 令牌先判 ⇒ 0（无假等）；unit × unit ⇒ 同节点 ⇒ 1
    u_item := sh_term_of_ti(TI_UNIT);
    tok_e1 := sh_name_token(e1);
    ty_budget_reset(200000);
    coll := ty_equiv(u_item, tok_e1);
    fails = fails + ts_check("t3b.unit_token_shape_collision_guard",
        ts_isat_b2i(coll == 1 && te_elem_cmp(u_item, tok_e1) == 0 &&
                    te_elem_cmp(u_item, u_item) == 1), 1);
    // ⑤(b) 补：unit 项在**非令牌型**元素位上按类型项比较 ⇒ [unit] vs [int] = 0；
    // [unit] vs [unit]（N 不同）⇒ 1
    ty_budget_reset(200000);
    u_i := ty_sub(sh_seq_term(TI_UNIT, 2), sh_seq_term(TI_INT, 2));
    u_u := ty_equiv(sh_seq_term(TI_UNIT, 2), sh_seq_term(TI_UNIT, 3));
    fails = fails + ts_check("t3b.unit_elem_type_item_face",
        ts_isat_b2i(u_i == 0 && u_u == 1 && ty_uncovered() == 0), 1);
    // ④ 域外守卫的牙：链元素既非令牌也非类型项（μ 变元）⇒ -1 + 未覆盖面
    ty_budget_reset(200000);
    dom := ty_sub(tt_atom(AK_SEQUENCE, -1, tt_cons(tt_var(0), tt_nil())),
                  tt_atom(AK_SEQUENCE, -1, tt_cons(t_int, tt_nil())));
    fails = fails + ts_check("t3b.elem_out_of_domain_stays_minus1",
        ts_isat_b2i(dom == -1 && ty_uncovered() == 1), 1);
    // ② 只读 ref 元素（协变槽）+ mut 标记槽回归钉：&NA vs &NB ⇒ 0；& 与 &mut ⇒ 0
    ref_a := tt_atom(AK_REF, -1, tt_cons(sh_ref_mut_marker(0), tt_cons(t_a, tt_nil())));
    ref_b := tt_atom(AK_REF, -1, tt_cons(sh_ref_mut_marker(0), tt_cons(t_b, tt_nil())));
    ref_m := tt_atom(AK_REF, -1, tt_cons(sh_ref_mut_marker(1), tt_cons(t_a, tt_nil())));
    ty_budget_reset(200000);
    rb := ty_sub(ref_a, ref_b);
    rm := ty_sub(ref_a, ref_m);
    fails = fails + ts_check("t3b.ref_elem_and_marker",
        ts_isat_b2i(rb == 0 && rm == 0 && ty_uncovered() == 0), 1);
    // ⑥ 清零判据（二进制内）：数组行经 type_equal = 引擎自决 + 零 ICE04 诊断（T4 重钉：
    //    回落计数已随 legacy 删除 ⇒ 断言形态 = 「未知诊断缺席」）
    t3b_d0 := g_diag_count;
    dec : ., mut = 0;
    if !type_equal(arr_a, arr_b) {
        if g_diag_count == t3b_d0 { dec = 1; }
    }
    fails = fails + ts_check("t3b.decided_no_indeterminate_arr", dec, 1);
    return fails;
}

// ═══════════ R2 P5 Task 4：残留 -1 政策 P-A（ICE04 硬错）用例段 ═══════════
// 判据面（**不依赖 legacy 存活**——它就是 legacy 删除后的替身证据；影子层下线后照常）：
//   ① 桥接缺口（行号越界 ⇒ 该行译不成类型项）⇒ **判 false + ICE04 恰 1 条**（旧行为 = 回落
//      legacy + g_replace_bridge 计数；两件旧物均已删除）；
//   ② 引擎 -1（未覆盖面：命名原子身份链 × NEVER 原子 ⇒ 域外，`te_named_pair` 的 NEVER/DYN
//      守卫）⇒ **判 false + ICE04**，且措辞 ≠ 桥接缺口措辞（成因可读 = 归因不混）；
//   ③ 决定面**零误报**：引擎自决（0/1）与同一行快路径一律不产 ICE04——三态纪律的牙齿 =
//      「未知 ⇒ 诊断」而「确定 ⇒ 无诊断」（P-A 若被改回「静默 false」= ①②转红；若被改成
//      「全报」= ③转红）。
// 诊断是**故意**触发的：本段结束时复位 g_diag_count（不留进后续用例的增量基线）。
fn ts_t4_run() -> int {
    fails : ., mut = 0;
    // ① 桥接缺口（ti 越界 = 无项）
    t4_d0 := g_diag_count;
    t4_b1 : ., mut = 0;
    if !type_equal(g_type_count + 100, TI_INT) { t4_b1 = 1; }
    t4_d1 := g_diag_count;
    t4_m_bridge := ts_diag_msg_at(t4_d0);
    fails = fails + ts_check("t4.ice04_bridge_gap_hard_error",
        (t4_b1 == 1 && t4_d1 == t4_d0 + 1 && ts_diag_code_at(t4_d0) == EC_ICE_TY_INDET &&
         str_len(t4_m_bridge) > 0), 1);
    // ② 引擎 -1（未覆盖面）：命名原子（T3 身份链）× NEVER 原子 = **域外**（`te_named_pair`
    //    的 NEVER/DYN 守卫 ⇒ -1 + g_ty_uncovered，见 t3n.never_dyn_out_of_domain）——这是
    //    桥接**能译**（两条目皆 ≥ 0）但引擎判不了的形态：与 ① 的桥接缺口是**两个不同出口**。
    //    （反例形态记：AK_NEVER × AK_DYN 是**已判**面（⊥ ⊆ ⊤ 不反向 ⇒ 0），不产 -1。）
    t4_na := alloc_named_type(str_intern("T4IndetNamed"));
    t4_d2 := g_diag_count;
    t4_b2 : ., mut = 0;
    if !type_equal(t4_na, TI_NEVER) { t4_b2 = 1; }
    t4_d3 := g_diag_count;
    t4_m_engine := ts_diag_msg_at(t4_d2);
    fails = fails + ts_check("t4.ice04_engine_uncovered_hard_error",
        (t4_b2 == 1 && t4_d3 == t4_d2 + 1 && ts_diag_code_at(t4_d2) == EC_ICE_TY_INDET &&
         str_len(t4_m_engine) > 0 && str_eq(t4_m_bridge, t4_m_engine) == 0), 1);
    // ③ 决定面零误报（引擎自决 0 与同一行快路径各自零诊断）
    t4_d4 := g_diag_count;
    t4_ok : ., mut = 0;
    if !type_equal(TI_INT, TI_STR) {                    // 引擎自决 0
        if type_equal(TI_INT, TI_INT) {                 // 同一行快路径（自反）
            if g_diag_count == t4_d4 { t4_ok = 1; }
        }
    }
    fails = fails + ts_check("t4.ice04_decided_no_false_positive", t4_ok, 1);
    g_diag_count = t4_d4;    // 复位（本段的 ICE04 是故意触发的）
    return fails;
}

// ═══════════ R2 P4 Task 2：TYPE 段内容面（装填 / 序列化 / dedup / 确定性）═══════════
// 用例面：① 段体缓冲 ↔ 内存表逐字段 roundtrip（行表 24B/条 + 项表 40B/条 + 长度公式）；
// ② dedup 重建（同构项 = 同节点；b 标注区分固定长度；DAG 无同 (tag,a..d) 重行）；
// ③ **确定性**（D13 的牙）：判定历史扰动（ty_sub/ty_equiv 触发规范化向项表追加新项）
// 后重装填 ⇒ 段体逐字节同（「直接序列化活表」的旧实现必在此变——见 ccr_types.cr 头注）；
// ④ 不可译行 ⇒ 装填拒绝（save 侧拒落盘，三态纪律）。
// 夹具说明：本组自建干净类型表（init_types 9 原生行 + 4 行可选/定长数组），不经
// parser/check_all；**必须最后运行**（populate 复位项层/引擎/桥接三面缓存）。
fn ts_ccr_roundtrip_ok() -> int {
    rc := g_type_count;
    tc := tt_count();
    if g_ccr_type_seg_len != 4 + rc * ESZ_TYPE_ROW + 4 + tc * ESZ_TYPE_TERM_DISK { return 0; }
    if buf_read_u32(g_ccr_type_seg, 0) != rc { return 0; }
    pos : ., mut = 4;
    i : ., mut = 0;
    loop {
        if i >= rc { break; }
        if buf_read_i64(g_ccr_type_seg, pos) != r64(g_types, i * ESZ_TYPE_ROW + OFF_TR_KIND) { return 0; }
        if buf_read_i64(g_ccr_type_seg, pos + 8) != r64(g_types, i * ESZ_TYPE_ROW + OFF_TR_DATA) { return 0; }
        if buf_read_i64(g_ccr_type_seg, pos + 16) != r64(g_types, i * ESZ_TYPE_ROW + OFF_TR_EXTRA) { return 0; }
        pos = pos + ESZ_TYPE_ROW;
        i = i + 1;
    }
    if buf_read_u32(g_ccr_type_seg, pos) != tc { return 0; }
    pos = pos + 4;
    j : ., mut = 0;
    loop {
        if j >= tc { break; }
        if buf_read_i64(g_ccr_type_seg, pos) != tt_tag(j) { return 0; }
        if buf_read_i64(g_ccr_type_seg, pos + 8) != tt_a(j) { return 0; }
        if buf_read_i64(g_ccr_type_seg, pos + 16) != tt_b(j) { return 0; }
        if buf_read_i64(g_ccr_type_seg, pos + 24) != tt_c(j) { return 0; }
        if buf_read_i64(g_ccr_type_seg, pos + 32) != tt_d(j) { return 0; }
        pos = pos + ESZ_TYPE_TERM_DISK;
        j = j + 1;
    }
    if pos != g_ccr_type_seg_len { return 0; }
    return 1;
}

fn ts_ccr_dedup_ok(opt_a: int, opt_b: int, arr3: int, arr4: int) -> int {
    // 同构 ⇒ 同节点（两个 `int?` 行 → 同一 union 项）；b 标注（固定长度）区分 ⇒ 异节点
    if sh_term_of_ti(opt_a) != sh_term_of_ti(opt_b) { return 0; }
    if sh_term_of_ti(arr3) == sh_term_of_ti(arr4) { return 0; }
    // DAG 不变量：表内无两个同 (tag,a..d) 的行（tt_term 去重——重建路径的牙）
    n := tt_count();
    i : ., mut = 0;
    loop {
        if i >= n { break; }
        j : ., mut = i + 1;
        loop {
            if j >= n { break; }
            if tt_tag(i) == tt_tag(j) && tt_a(i) == tt_a(j) && tt_b(i) == tt_b(j) &&
               tt_c(i) == tt_c(j) && tt_d(i) == tt_d(j) { return 0; }
            j = j + 1;
        }
        i = i + 1;
    }
    return 1;
}

fn ts_ccr_purity_ok() -> int {
    n0 := g_ccr_type_seg_len;
    cp := alloc(n0 + 8);
    _dyncpy(g_ccr_type_seg, n0, cp);
    // R2 P4 Task 3：IFACE 段同批纳入（D13 的承诺面 = **两段**皆类型表/接口表的纯函数）
    i0 := g_ccr_iface_seg_len;
    ip := alloc(i0 + 8);
    _dyncpy(g_ccr_iface_seg, i0, ip);
    // 判定历史扰动：跨项判定 + 规范化（向项表追加新项——旧「直接序列化活表」必在此变）
    pa := tt_atom(AK_INT, TI_INT, -1);
    pb := tt_atom(AK_STRING, TI_STR, -1);
    if ty_sub(tt_union(pa, pb), pa) != 0 { println("ct.seg_determinism: perturbation ty_sub != 0"); return 0; }
    if ty_disjoint(pa, pb) != 1 { println("ct.seg_determinism: perturbation ty_disjoint != 1"); return 0; }
    if ty_equiv(tt_union(pa, tt_union(pb, pa)), tt_union(pa, pb)) != 1 {
        println("ct.seg_determinism: perturbation ty_equiv != 1"); return 0;
    }
    // 唯一标注项（**保证**向项表追加新项——判定扰动可能与既有项同构而零新增，
    // 突变控制实证：仅判定扰动的版本对「跳过装填」突变不转红，本项补上该牙）
    uq := tt_atom(AK_DEX, 900001, tt_cons(pa, tt_nil()));
    if tt_tag(uq) != TT_ATOM || tt_b(uq) != 900001 {
        println("ct.seg_determinism: unique-term fixture failed"); return 0;
    }
    // 重装填（项层/引擎/桥接复位 → 行序重建）⇒ 段体逐字节同
    if ccr_seg_prepare_save() != 0 { println("ct.seg_determinism: rebuild prepare failed"); return 0; }
    if g_ccr_type_seg_len != n0 {
        print("ct.seg_determinism: buffer length changed "); print(int_str(n0));
        print(" -> "); println(int_str(g_ccr_type_seg_len));
        return 0;
    }
    k : ., mut = 0;
    loop {
        if k >= n0 { break; }
        if load8(g_ccr_type_seg, k) != load8(cp, k) {
            print("ct.seg_determinism: buffer byte mismatch at "); println(int_str(k));
            return 0;
        }
        k = k + 1;
    }
    // IFACE 段同判（R2 P4 Task 3）：重装填后逐字节同（形状重注册/签名装填皆纯函数）
    if g_ccr_iface_seg_len != i0 {
        print("ct.seg_determinism: iface buffer length changed "); print(int_str(i0));
        print(" -> "); println(int_str(g_ccr_iface_seg_len));
        return 0;
    }
    k2 : ., mut = 0;
    loop {
        if k2 >= i0 { break; }
        if load8(g_ccr_iface_seg, k2) != load8(ip, k2) {
            print("ct.seg_determinism: iface buffer byte mismatch at "); println(int_str(k2));
            return 0;
        }
        k2 = k2 + 1;
    }
    return 1;
}

fn ts_ccr_run() -> int {
    fails : ., mut = 0;
    init_types();   // 干净表（9 原生行——不受前段夹具影响）
    // R2 P4 Task 3：接口表同批清零（段体含 IFACE 五小节 ⇒ 上游 ifc/isat 夹具的**死节点**
    // （EXPR_IDENT 指向已被 init_types 作废的命名行 ⇒ res_type_node 落 dyn 行）会令签名项
    // 不可建 ⇒ 装填拒绝。本组语义 = 「干净类型表 + 干净接口表」的段体往返夹具。
    g_iface_count = 0;
    g_impl_for_count = 0;
    g_method_count = 0;
    iface_shape_reset();
    iface_shape_builtin_init();
    opt_a := alloc_type(TYP_OPTIONAL, TI_INT, 0);
    opt_b := alloc_type(TYP_OPTIONAL, TI_INT, 0);
    arr3 := alloc_type(TYP_ARRAY, TI_INT, 3);
    arr4 := alloc_type(TYP_ARRAY, TI_INT, 4);
    prep := ccr_seg_prepare_save();
    fails = fails + ts_check("ct.seg_prepare", prep, 0);
    if prep == 0 {
        fails = fails + ts_check("ct.seg_roundtrip", ts_ccr_roundtrip_ok(), 1);
        fails = fails + ts_check("ct.seg_dedup_identity", ts_ccr_dedup_ok(opt_a, opt_b, arr3, arr4), 1);
        fails = fails + ts_check("ct.seg_determinism", ts_ccr_purity_ok(), 1);
    } else {
        fails = fails + 3;   // 后续三例无法运行 ⇒ 计失败（不得静默少算）
    }
    // ④ 不可译行（子行越界）⇒ 装填拒绝（save 拒落盘）——**最后**（污染类型表）
    bad_row := alloc_type(TYP_ARRAY, 999999, 0);
    rej := ccr_type_populate();
    if bad_row < 0 { rej = 1; }   // 夹具未建成 ⇒ 不算通过（防假绿）
    fails = fails + ts_check("ct.seg_reject_untranslatable", rej, -1);
    return fails;
}

// ═══════════ R2 P4 Task 3：IFACE 段内容面（扩列 / 命名化 / 签名项化 / 段体往返）═══════════
// 用例面（7 例）：① 段体五小节与内存表逐字段一致 + 行走完 == 缓冲长度（无尾随）；
// ② 签名项槽（ret_term/param_terms）== 活算值（装填与签名来源零漂移；未用槽 = -1）；
// ③ 形状名生产注册面（六名可按名查询且与 sh_shape_*() 构造点**同项**）；④ 条目表扩列
// （16 行 + 三新行 ops = 0 + 逐名可读）；⑤ 判定面零变化（全类型行枚举无新映射 +
// TYP_NULL/TYP_OPTIONAL 行仍 -1）；⑥ 不可建签名（dyn 位图行入签名）⇒ 装填拒绝
// （save 拒落盘）——**最后**（污染接口表）。
// 夹具/边界：本组自建**干净接口表**（g_iface_count/g_impl_for_count/g_method_count 清零 +
// 形状表 reset + 生产注册面重跑）——上游 ts_ifc_run 的夹具含 9 形参接口（不可建面），
// 不清零会令装填拒绝（设计如此：populate 不静默跳过）。**必须最后运行**（populate 复位三面缓存）。
fn ts_ccr2_row_ok(b: string, p: int, i: int) -> int {
    eo := i * ESZ_IFACE_ENTRY;
    if buf_read_i32(b, p) != r64(g_iface_entries, eo + OFF_IE_AK) { return 0; }
    if buf_read_i32(b, p + 4) != r64(g_iface_entries, eo + OFF_IE_TI) { return 0; }
    if buf_read_i32(b, p + 8) != r64(g_iface_entries, eo + OFF_IE_NAME) { return 0; }
    if buf_read_i32(b, p + 12) != r64(g_iface_entries, eo + OFF_IE_LIT) { return 0; }
    if buf_read_i64(b, p + 16) != r64(g_iface_entries, eo + OFF_IE_OPS) { return 0; }
    return 1;
}

fn ts_ccr2_seg_walk_ok() -> int {
    b := g_ccr_iface_seg;
    n := g_ccr_iface_seg_len;
    if n <= 0 { return 0; }
    // ① 原生条目（计数 == 常量 == 表计数；逐行 5 字段 == g_iface_entries）
    if buf_read_u32(b, 0) != IFACE_ENTRY_COUNT { return 0; }
    if buf_read_u32(b, 0) != g_iface_entry_count { return 0; }
    p : ., mut = 4;
    ei : ., mut = 0;
    loop {
        if ei >= IFACE_ENTRY_COUNT { break; }
        if ts_ccr2_row_ok(b, p, ei) != 1 { return 0; }
        p = p + 24;
        ei = ei + 1;
    }
    // ② 横切形状
    if buf_read_u32(b, p) != g_iface_shape_count { return 0; }
    p = p + 4;
    si : ., mut = 0;
    loop {
        if si >= g_iface_shape_count { break; }
        if buf_read_i32(b, p) != r64(g_iface_shape_names, si * 8) { return 0; }
        if buf_read_i32(b, p + 4) != r64(g_iface_shape_terms, si * 8) { return 0; }
        p = p + 8;
        si = si + 1;
    }
    // ③ 用户接口（头 16B + 方法 80B：项槽先于裸码槽——实施取声明行序，见 ccr_types.cr 头注）
    if buf_read_u32(b, p) != g_iface_count { return 0; }
    p = p + 4;
    fi : ., mut = 0;
    loop {
        if fi >= g_iface_count { break; }
        fo := fi * ESZ_IFACEINFO;
        mc := r64(g_ifaces, fo + OFF_IF_METHOD_COUNT);
        if buf_read_i32(b, p) != r64(g_ifaces, fo + OFF_IF_NAME) { return 0; }
        if buf_read_i32(b, p + 4) != mc { return 0; }
        if buf_read_i32(b, p + 8) != r64(g_ifaces, fo + OFF_IF_GENERIC_COUNT) { return 0; }
        p = p + 16;
        mj : ., mut = 0;
        loop {
            if mj >= mc { break; }
            mo := fo + OFF_IF_METHODS + mj * ESZ_IFMETHOD;
            if buf_read_i32(b, p) != r64(g_ifaces, mo + OFF_IFM_NAME) { return 0; }
            if buf_read_i32(b, p + 4) != r64(g_ifaces, mo + OFF_IFM_PARAM_COUNT) { return 0; }
            if buf_read_i32(b, p + 8) != r64(g_ifaces, mo + OFF_IFM_SELF_MODE) { return 0; }
            if buf_read_i32(b, p + 12) != r64(g_ifaces, mo + OFF_IFM_RET_TERM) { return 0; }
            p = p + 16;
            kq : ., mut = 0;
            loop {
                if kq >= MAX_IFACE_METHOD_PARAMS { break; }
                if buf_read_i32(b, p) != r64(g_ifaces, mo + OFF_IFM_PARAM_TERMS + kq * 8) { return 0; }
                p = p + 4;
                kq = kq + 1;
            }
            qq : ., mut = 0;
            loop {
                if qq >= MAX_IFACE_METHOD_PARAMS { break; }
                if buf_read_i32(b, p) != r64(g_ifaces, mo + OFF_IFM_PARAM_TYPES + qq * 8) { return 0; }
                p = p + 4;
                qq = qq + 1;
            }
            mj = mj + 1;
        }
        fi = fi + 1;
    }
    // ④ impl 边
    if buf_read_u32(b, p) != g_impl_for_count { return 0; }
    p = p + 4;
    gi : ., mut = 0;
    loop {
        if gi >= g_impl_for_count { break; }
        if buf_read_i32(b, p) != r64(g_impl_for, gi * 16) { return 0; }
        if buf_read_i32(b, p + 4) != r64(g_impl_for, gi * 16 + 8) { return 0; }
        p = p + 8;
        gi = gi + 1;
    }
    // ⑤ 方法表
    if buf_read_u32(b, p) != g_method_count { return 0; }
    p = p + 4;
    mi : ., mut = 0;
    loop {
        if mi >= g_method_count { break; }
        if buf_read_i32(b, p) != r64(g_methods, mi * 24) { return 0; }
        if buf_read_i32(b, p + 4) != r64(g_methods, mi * 24 + 8) { return 0; }
        if buf_read_i32(b, p + 8) != r64(g_methods, mi * 24 + 16) { return 0; }
        p = p + 12;
        mi = mi + 1;
    }
    if p != n { return 0; }        // 行走完 == 缓冲长度（五小节自洽 + 无尾随字节）
    return 1;
}

fn ts_ccr2_sig_slots_ok() -> int {
    ii : ., mut = 0;
    loop {
        if ii >= g_iface_count { break; }
        mc := r64(g_ifaces, ii * ESZ_IFACEINFO + OFF_IF_METHOD_COUNT);
        mi : ., mut = 0;
        loop {
            if mi >= mc { break; }
            mo := ii * ESZ_IFACEINFO + OFF_IF_METHODS + mi * ESZ_IFMETHOD;
            // 返回槽 == 活算（签名的唯一来源 = sh_iface_sig_ret_term）
            if r64(g_ifaces, mo + OFF_IFM_RET_TERM) != sh_iface_sig_ret_term(ii, mi) { return 0; }
            pc := r64(g_ifaces, mo + OFF_IFM_PARAM_COUNT);
            pj : ., mut = 0;
            loop {
                if pj >= MAX_IFACE_METHOD_PARAMS { break; }
                if pj < pc {
                    if r64(g_ifaces, mo + OFF_IFM_PARAM_TERMS + pj * 8) != sh_iface_sig_param_term(ii, mi, pj) { return 0; }
                } else {
                    if r64(g_ifaces, mo + OFF_IFM_PARAM_TERMS + pj * 8) != -1 { return 0; }   // 未用槽 = -1
                }
                pj = pj + 1;
            }
            mi = mi + 1;
        }
        ii = ii + 1;
    }
    return 1;
}

fn ts_ccr2_shape_names_ok() -> int {
    // 六生产名可查 + 与构造点**同项**（节点同一——形状项 = 唯一数据面）
    if iface_shape_count() < 6 { return 0; }
    if iface_shape_lookup(str_intern("sequence")) != sh_shape_seq() { return 0; }
    if iface_shape_lookup(str_intern("sequence_ro")) != sh_shape_seq_ro() { return 0; }
    if iface_shape_lookup(str_intern("sequence_rw")) != sh_shape_seq_rw() { return 0; }
    if iface_shape_lookup(str_intern("indexable")) != sh_shape_indexable() { return 0; }
    if iface_shape_lookup(str_intern("iterable")) != sh_shape_iterable() { return 0; }
    if iface_shape_lookup(str_intern("product")) != sh_shape_product() { return 0; }
    return 1;
}

fn ts_ccr2_entries_ok() -> int {
    // 扩列 13 → 16：三新行可查 + ops = 0（纯信息面）+ 16 行逐名（注册面固定增量）
    if iface_count() != 16 { return 0; }
    if iface_entry(AK_NULL) < 0 { return 0; }
    if iface_entry(AK_SUM) < 0 { return 0; }
    if iface_entry(AK_FN) < 0 { return 0; }
    if iface_ops(AK_NULL) != 0 { return 0; }
    if iface_ops(AK_SUM) != 0 { return 0; }
    if iface_ops(AK_FN) != 0 { return 0; }
    if iface_ti_of(AK_NULL) != -1 { return 0; }   // 无规范行（类级）
    if iface_ti_of(AK_SUM) != -1 { return 0; }
    if iface_ti_of(AK_FN) != -1 { return 0; }
    // 逐名（16 行：8 原生 + 5 结构/命名 + 3 新行）
    if iface_name_of(AK_INT) != str_intern("int") { return 0; }
    if iface_name_of(AK_DEX) != str_intern("dex") { return 0; }
    if iface_name_of(AK_STRING) != str_intern("string") { return 0; }
    if iface_name_of(AK_BOOL) != str_intern("bool") { return 0; }
    if iface_name_of(AK_UNIT) != str_intern("unit") { return 0; }
    if iface_name_of(AK_NEVER) != str_intern("never") { return 0; }
    if iface_name_of(AK_CHAR) != str_intern("char") { return 0; }
    if iface_name_of(AK_DYN) != str_intern("dyn") { return 0; }
    if iface_name_of(AK_PRODUCT) != str_intern("product") { return 0; }
    if iface_name_of(AK_SEQUENCE) != str_intern("sequence") { return 0; }
    if iface_name_of(AK_REF) != str_intern("ref") { return 0; }
    if iface_name_of(AK_PTR) != str_intern("ptr") { return 0; }
    if iface_name_of(AK_NAMED) != str_intern("named") { return 0; }
    if iface_name_of(AK_NULL) != str_intern("null") { return 0; }
    if iface_name_of(AK_SUM) != str_intern("sum") { return 0; }
    if iface_name_of(AK_FN) != str_intern("fn") { return 0; }
    if iface_name_of(-1) != -1 { return 0; }      // 负键守卫（不得与行 0 混同）
    if iface_name_of(9999) != -1 { return 0; }
    return 1;
}

fn ts_ccr2_kind_domain_ok() -> int {
    // 判定面零变化（扩列只加「可查询性」）：全类型行枚举——三新原子不得被任何行命中
    // （若未来给某行新映射到 AK_NULL/AK_SUM/AK_FN，本用例转红 = 有意的闸）
    i : ., mut = 0;
    loop {
        if i >= g_type_count { break; }
        k := iface_kind_of(i);
        if k == AK_NULL || k == AK_SUM || k == AK_FN { return 0; }
        i = i + 1;
    }
    return 1;
}

fn ts_ccr2_run() -> int {
    fails : ., mut = 0;
    // 生产重置路径的接线钉（先于夹具）：`reset_frontend_state` 清形状表 count +
    // `check_all` 首行的 init_types ⇒ 六名重建——**不经**显式 iface_shape_builtin_init
    // （本断言 = 「init_types 尾部调用」的牙；若该调用缺失/被挪走 ⇒ 本条转红）。
    iface_shape_reset();
    init_types();                 // 干净类型表（9 原生行）+ 生产形状注册面
    fails = fails + ts_check("ct2.shape_face_from_init_types",
        (iface_shape_count() == 6 &&
         iface_shape_lookup(str_intern("sequence")) == sh_shape_seq() &&
         iface_shape_lookup(str_intern("product")) == sh_shape_product()), 1);
    g_iface_count = 0;            // 干净接口表（上游 ts_ifc_run 夹具含不可建面——不清零即拒装填）
    g_impl_for_count = 0;
    g_method_count = 0;
    iface_shape_reset();
    iface_shape_builtin_init();   // 生产注册面（6 名）——populate 会重跑（幂等）
    // 夹具：命名行 + null/可选行（判定面显式钉）+ 1 接口（self 接收者 + 命名型形参）
    //       + impl 边 + 方法表（生产写点同形：parser 的 interface/impl 分支）
    ts_ifc_mk_named("Ct2Named");
    ct2_null := alloc_type(TYP_NULL, 0, 0);
    ct2_opt := alloc_type(TYP_OPTIONAL, TI_INT, 0);
    ct2_n := ts_ifc_named_node("Ct2Named");
    ct2_int_n := ts_ifc_base_node(TY_INT);
    ct2_ii := ts_t5_mk_iface("Ct2Iface");
    ts_ifc_add_method_n(ct2_ii, "a", 1, 1, -1, -1, -1, -1, ct2_int_n);      // fn a(self) -> int
    ts_ifc_add_method_n(ct2_ii, "b", 1, 0, ct2_n, -1, -1, -1, ct2_int_n);   // fn b(x: Ct2Named) -> int
    grow_impl_for(1);
    w64(g_impl_for, 0, str_intern("Ct2Iface"));
    w64(g_impl_for, 8, str_intern("Ct2Named"));
    g_impl_for_count = 1;
    grow_methods(1);
    w64(g_methods, 0, str_intern("Ct2Named"));
    w64(g_methods, 8, str_intern("b"));
    w64(g_methods, 16, str_intern("Ct2Named.b"));
    g_method_count = 1;
    prep := ccr_seg_prepare_save();
    fails = fails + ts_check("ct2.seg_prepare", prep, 0);
    if prep == 0 {
        fails = fails + ts_check("ct2.iface_seg_walk", ts_ccr2_seg_walk_ok(), 1);
        fails = fails + ts_check("ct2.iface_sig_slots", ts_ccr2_sig_slots_ok(), 1);
        fails = fails + ts_check("ct2.shape_names_production", ts_ccr2_shape_names_ok(), 1);
    } else {
        fails = fails + 3;   // 后续三例无法运行 ⇒ 计失败（不得静默少算）
    }
    fails = fails + ts_check("ct2.entry_table_16_named", ts_ccr2_entries_ok(), 1);
    fails = fails + ts_check("ct2.kind_of_no_new_mapping",
        (ts_ccr2_kind_domain_ok() == 1 && iface_kind_of(ct2_null) == -1 && iface_kind_of(ct2_opt) == -1), 1);
    // ⑥ 不可建签名（dyn 位图行入签名：sh_sig_term_of_ti 对 TYP_DYN 回 -1）⇒ 装填拒绝
    //    （save 拒落盘——三态纪律：不得把缺项签名静默写成 -1 落盘）——**最后**（污染接口表）
    ct2_dyn_n := ts_ifc_base_node(TI_DYN);   // parser 对 `dyn` 正产 type_val = TI_DYN
    ts_ifc_add_method_n(ct2_ii, "c", 0, 0, -1, -1, -1, -1, ct2_dyn_n);
    rej2 := ccr_iface_populate();
    fails = fails + ts_check("ct2.reject_unbuildable_sig", rej2, -1);
    return fails;
}

// ═══════════ R2 P6 Task 2（E-10）：¬ 面同类原子身份判据的邻域覆盖（9 例）═══════════
// 牙齿分工（计划 Task 2 Step 4 的四向 + 本批补钉）：
//   ① 同身份 ⇒ **仍相交**（防「一律判不交」的过度加强）；
//   ② μ 变元作**字面** ⇒ **仍 -1 + 未覆盖面**（走 lit_implies 既有域外路径，三态不得稀释）；
//   ③④ `⊤ₖ` 两方向 ⇒ **不变（0）**〔**语义钉子**：防将来扩域/重排把 `⊤ₖ` 误当身份原子
//      （`tt_top_k` 的 c 槽 = 0 非 -1，仅靠空链守卫拦不住）；既有 `neg.supertype*` 走的是
//      **¬×¬** 分支，不覆盖本面 ⇒ 补此两钉〕；
//   ⑤ 跨枚举**同名**变体 ⇒ 1（复刻 P3 Task 1 令牌碰撞类；身份含枚举名）；
//   ⑥ AK_UNIT 类**令牌字面**（非 AK_SUM）⇒ 维持 0（钉类域检查）；
//   ⑦ `AK_NAMED` ⇒ 维持 **-1 + 未覆盖面**（P0 终审 Important B 在册政策，本批不翻转）；
//   ⑧ 空链 / 链元素域外（手造畸形项）⇒ **P1-a：0**（裁定口径：域外逐位不变）；
//   ⑨ 参数化构造子面（D4）⇒ 维持 0：`[int]` vs ¬`[int ∪ string]` 双向 —— 类域守卫的**稳定牙齿**
//      （无守卫时元素项不同 ⇒ te_chain_cmp 回 0 ⇒ 误判 1 = **假不交**）。
// 夹具 = 纯合成（`str_intern` + `sh_name_token` + `tt_atom/tt_cons/tt_nil/tt_union`）⇒ 不依赖
//   g_types / `sh_term_of_ti` / `init_types()`（与调用序列中其它段解耦）。
// 用例数 = **11**（调用方 `total = total + 11` 须同步——增删用例两处一起改）。
fn ts_t2_neg_run() -> int {
    fails : ., mut = 0;
    e1 := str_intern("T2NegE1");
    v1 := str_intern("T2NegV1");
    v2 := str_intern("T2NegV2");
    e2 := str_intern("T2NegE2");
    sum_11 := tt_atom(AK_SUM, -1, tt_cons(sh_name_token(e1), tt_cons(sh_name_token(v1), tt_nil())));
    sum_21 := tt_atom(AK_SUM, -1, tt_cons(sh_name_token(e2), tt_cons(sh_name_token(v1), tt_nil())));
    i_atom := tt_atom(AK_INT, TI_INT, -1);
    s_atom := tt_atom(AK_STRING, TI_STR, -1);
    // ① 同身份（同枚举同变体，两处构造 ⇒ DAG 去重同节点）⇒ lp ⊆ ¬x 不成立 ⇒ 0
    ty_budget_reset(200000);
    fails = fails + ts_check("t2.neg_same_identity_not_disjoint",
        ts_isat_b2i(ty_sub(sum_11, tt_not(sum_11)) == 0 && ty_uncovered() == 0), 1);
    // ② μ 变元作字面（无原子类）⇒ -1 + 未覆盖面（既有域外路径，不受本批改动影响）
    ty_budget_reset(200000);
    fails = fails + ts_check("t2.neg_var_literal_stays_minus1",
        ts_isat_b2i(ty_sub(tt_var(0), tt_not(sum_11)) == -1 && ty_uncovered() == 1), 1);
    // ③ ⊤ₖ 在左：类顶 ⊆ ¬原子 ⇒ 假（类顶含该类全部值）⇒ 0
    ty_budget_reset(200000);
    fails = fails + ts_check("t2.neg_topk_left_unchanged",
        ts_isat_b2i(ty_sub(tt_top_k(AK_SUM), tt_not(sum_11)) == 0 && ty_uncovered() == 0), 1);
    // ④ ⊤ₖ 在右：原子 ⊆ ¬类顶 ⇒ 假 ⇒ 0
    ty_budget_reset(200000);
    fails = fails + ts_check("t2.neg_topk_right_unchanged",
        ts_isat_b2i(ty_sub(sum_11, tt_not(tt_top_k(AK_SUM))) == 0 && ty_uncovered() == 0), 1);
    // ⑤ 跨枚举同名变体：链首令牌（枚举名）不同 ⇒ 异身份 ⇒ 1；同项 ⇒ 0（不得混同）
    ty_budget_reset(200000);
    fails = fails + ts_check("t2.neg_cross_enum_same_name",
        ts_isat_b2i(ty_sub(sum_21, tt_not(sum_11)) == 1 && ty_sub(sum_11, tt_not(sum_21)) == 1 &&
                    ty_sub(sum_11, tt_not(sum_11)) == 0 && ty_uncovered() == 0), 1);
    // ⑩ **同枚举异变体**（本批暴露首版实现缺陷的那条）：AK_SUM 槽 1 = **变体令牌**，而
    //    `te_chain_cmp` 的槽 ≥1 走**实参位规则**（`te_arg_cmp → ty_equiv`）⇒ 两个不同令牌
    //    结构判等（b 槽只是标注）⇒ 误判「同链」。本判据走**逐元素令牌同一性** ⇒ 1。
    //    （三例 `t3.*_over_claim` 与该例同族：同枚举 T3Color 的 T3Blue vs T3Red。）
    sum_12b := tt_atom(AK_SUM, -1, tt_cons(sh_name_token(e1), tt_cons(sh_name_token(v2), tt_nil())));
    ty_budget_reset(200000);
    fails = fails + ts_check("t2.neg_same_enum_diff_variant",
        ts_isat_b2i(ty_sub(sum_12b, tt_not(sum_11)) == 1 && ty_sub(sum_11, tt_not(sum_12b)) == 1 &&
                    ty_sub(sum_11, tt_not(sum_11)) == 0 && ty_uncovered() == 0), 1);
    // ⑥ AK_UNIT 类令牌字面（非 AK_SUM）⇒ 类域外 ⇒ 维持 0
    ty_budget_reset(200000);
    fails = fails + ts_check("t2.neg_token_literal_not_identity_face",
        ts_isat_b2i(ty_sub(sh_name_token(v1), tt_not(sh_name_token(v2))) == 0 && ty_uncovered() == 0), 1);
    // ⑦ AK_NAMED ⇒ 维持 -1 + 未覆盖面（P0 Important B / named.not_disjoint 在册；本批不动）
    ty_budget_reset(200000);
    named_nc := tt_atom(AK_NAMED, 7, -1);
    fails = fails + ts_check("t2.neg_named_stays_minus1",
        ts_isat_b2i(ty_sub(named_nc, tt_not(sum_11)) == -1 && ty_uncovered() == 1), 1);
    // ⑧ 身份链不可判的手造畸形项 ⇒ 维持 0（P1-a 钉；两条断言分别钉两个守卫：
    //    空链（无身份）与链元素域外（非令牌）——无守卫时都会落成 d == 0 ⇒ 误判「异身份」⇒ 1）
    ty_budget_reset(200000);
    mu_chain := tt_atom(AK_SUM, -1, tt_cons(sh_name_token(e1), tt_cons(tt_var(0), tt_nil())));
    empty_chain := tt_atom(AK_SUM, -1, -1);
    fails = fails + ts_check("t2.neg_chain_elem_out_of_domain_pin",
        ts_isat_b2i(ty_sub(empty_chain, tt_not(sum_11)) == 0 &&
                    ty_sub(mu_chain, tt_not(sum_11)) == 0 && ty_uncovered() == 0), 1);
    // ⑪ AK_REF 的 **mut 标记位是令牌**（`sh_ref_mut_marker`）⇒ 链形与 AK_SUM 同族（元素皆令牌）
    //    ⇒ **类域守卫的稳定牙齿**：无守卫时 `&int` vs `&mut int` 在槽 0 令牌异节点 ⇒ 误判
    //    「异身份」⇒ 1 = **假不交**（D4 的 REF 面；语义上两者值集关系未建模，保守回 0）。
    ref_r := tt_atom(AK_REF, -1, tt_cons(sh_ref_mut_marker(0), tt_cons(i_atom, tt_nil())));
    ref_m := tt_atom(AK_REF, -1, tt_cons(sh_ref_mut_marker(1), tt_cons(i_atom, tt_nil())));
    ty_budget_reset(200000);
    fails = fails + ts_check("t2.neg_ref_mut_marker_face_stays_zero",
        ts_isat_b2i(ty_sub(ref_r, tt_not(ref_m)) == 0 && ty_sub(ref_m, tt_not(ref_r)) == 0 &&
                    ty_uncovered() == 0), 1);
    // ⑨ 参数化构造子（D4）：`[int]` vs ¬`[int ∪ string]` 双向 ⇒ 0 —— 类域守卫的稳定牙齿
    //    （无守卫时元素项不同 ⇒ te_chain_cmp 回 0 ⇒ 误判 1 = 假不交；语义上 `[int] ⊆ [int∪string]`）
    seq_i := tt_atom(AK_SEQUENCE, -1, tt_cons(i_atom, tt_nil()));
    seq_u := tt_atom(AK_SEQUENCE, -1, tt_cons(tt_union(i_atom, s_atom), tt_nil()));
    ty_budget_reset(200000);
    fails = fails + ts_check("t2.neg_param_face_stays_zero",
        ts_isat_b2i(ty_sub(seq_i, tt_not(seq_u)) == 0 && ty_sub(seq_u, tt_not(seq_i)) == 0 &&
                    ty_uncovered() == 0), 1);
    return fails;
}

fn type_selftest_run() -> int {
    fails : ., mut = 0;
    total : ., mut = 0;

    // --- P0 最小用例 ---
    a_int := tt_atom(AK_INT, TI_INT, -1);
    a_str := tt_atom(AK_STRING, TI_STR, -1);
    a_bool := tt_atom(AK_BOOL, TI_BOOL, -1);

    total = total + 1; fails = fails + ts_check("unit.bot_sub_int", ty_sub(tt_bot(), a_int), 1);
    total = total + 1; fails = fails + ts_check("unit.int_sub_str",  ty_sub(a_int, a_str), 0);
    total = total + 1; fails = fails + ts_check("unit.int_sub_int",  ty_sub(a_int, a_int), 1);
    total = total + 1; fails = fails + ts_check("unit.dedup",       (tt_union(a_int, a_str) == tt_union(a_int, a_str)), 1);
    total = total + 1; fails = fails + ts_check("unit.notnot",      (tt_not(tt_not(a_int)) == a_int), 1);

    // --- 规范化（Task 2）：De Morgan / 否定下推 / 分配律 / 幂等 ---
    // 探针：(int ∪ string) ∩ bool —— 分配律必须把它展成 union（两层分配）
    probe := tt_inter(tt_union(a_int, a_str), a_bool);
    total = total + 1; fails = fails + ts_check("norm.demorgan",
        (tt_norm(tt_not(tt_union(a_int, a_str))) == tt_norm(tt_inter(tt_not(a_int), tt_not(a_str)))), 1);
    total = total + 1; fails = fails + ts_check("norm.nnf_neg_push",
        tt_tag(tt_norm(tt_not(tt_union(a_int, a_str)))), TT_INTER);
    total = total + 1; fails = fails + ts_check("norm.dnf_shape", tt_is_dnf(tt_norm(probe)), 1);
    total = total + 1; fails = fails + ts_check("norm.distributed", tt_tag(tt_norm(probe)), TT_UNION);
    total = total + 1; fails = fails + ts_check("norm.idempotent",
        (tt_norm(tt_norm(probe)) == tt_norm(probe)), 1);

    // --- 判定（Task 3）：子类型 / 等价 / 不相交 / 可空 / ⊤ₖ / 预算三态 ---
    u_is := tt_union(a_int, a_str);
    total = total + 1; fails = fails + ts_check("sub.union_right", ty_sub(a_int, u_is), 1);
    total = total + 1; fails = fails + ts_check("sub.union_left_neg", ty_sub(u_is, a_int), 0);
    total = total + 1; fails = fails + ts_check("sub.inter", ty_sub(tt_inter(a_int, a_str), a_int), 1);
    // 非平凡吸收：int ∪ (str ∪ int) ≡ int ∪ str（需引擎判定，非构造律）
    total = total + 1; fails = fails + ts_check("equiv.absorb",
        ty_equiv(tt_union(a_int, tt_union(a_str, a_int)), tt_union(a_int, a_str)), 1);
    total = total + 1; fails = fails + ts_check("disjoint.atoms", ty_disjoint(a_int, a_str), 1);
    total = total + 1; fails = fails + ts_check("disjoint.same", ty_disjoint(a_int, a_int), 0);
    total = total + 1; fails = fails + ts_check("inh.atom", ty_inhabited(a_int), 1);
    total = total + 1; fails = fails + ts_check("inh.contra", ty_inhabited(tt_inter(a_int, tt_not(a_int))), 0);
    total = total + 1; fails = fails + ts_check("inh.mixed_atoms",
        ty_inhabited(tt_inter(a_int, tt_atom(AK_SEQUENCE, -1, -1))), 0);
    total = total + 1; fails = fails + ts_check("topk.sub", ty_sub(a_int, tt_top_k(AK_INT)), 1);
    total = total + 1; fails = fails + ts_check("topk.neg", ty_sub(a_str, tt_top_k(AK_INT)), 0);
    // 预算守卫：深递归项 + 极小预算 → 三态 -1（禁止与「不成立」混淆）
    ty_budget_reset(64);
    total = total + 1; fails = fails + ts_check("budget.unknown", ty_sub(tt_probe_wide_union(300), a_int), -1);
    total = total + 1; fails = fails + ts_check("budget.flag", ty_exhausted(), 1);
    ty_budget_reset(200000);

    // --- 反例（witness）+ 穷尽性（Task 4）---
    w := tt_witness(a_int, a_str);
    total = total + 1; fails = fails + ts_check("witness.nonempty", (w >= 0), 1);
    total = total + 1; fails = fails + ts_check("witness.sub_of_a", ty_sub(w, a_int), 1);
    total = total + 1; fails = fails + ts_check("witness.not_sub_of_b", ty_sub(w, a_str), 0);
    total = total + 1; fails = fails + ts_check("witness.empty", tt_witness(a_int, a_int), -1);

    dom := tt_union(tt_union(a_int, a_str), a_bool);
    pats := tt_cons(a_int, tt_cons(a_str, tt_nil()));
    total = total + 1; fails = fails + ts_check("exhaust.incomplete", ty_exhaustive(dom, pats), 0);
    miss := ty_exhaust_witness(dom, pats);
    total = total + 1; fails = fails + ts_check("exhaust.witness_bool", ty_equiv(miss, a_bool), 1);
    total = total + 1; fails = fails + ts_check("exhaust.complete",
        ty_exhaustive(dom, tt_cons(a_int, tt_cons(a_str, tt_cons(a_bool, tt_nil())))), 1);

    // --- 递归 + 参数化（Task 4）---
    rec_abs := tt_mu(0, tt_union(a_int, tt_var(0)));
    total = total + 1; fails = fails + ts_check("rec.absorb", ty_equiv(rec_abs, a_int), 1);
    rec_list := tt_mu(0, tt_union(a_int, tt_atom(AK_PRODUCT, -1, tt_cons(tt_var(0), tt_nil()))));
    total = total + 1; fails = fails + ts_check("rec.inh", ty_inhabited(rec_list), 1);
    total = total + 1; fails = fails + ts_check("rec.sub_self", ty_sub(rec_list, rec_list), 1);
    seq_i := tt_atom(AK_SEQUENCE, -1, tt_cons(a_int, tt_nil()));
    seq_s := tt_atom(AK_SEQUENCE, -1, tt_cons(a_str, tt_nil()));
    total = total + 1; fails = fails + ts_check("param.same", ty_sub(seq_i, seq_i), 1);
    // **R2 P5 Task 3b 翻转钉**（原 `param.unknown_p0`，期望 -1）：不变槽元素三态落地后
    // 同类异参（`[int]` vs `[str]`，元素 = 异原生类）由「未知 -1」变「确定不同 **0**」。
    // 语义正确性：不变元素槽下 `[int] ⊄ [str]`（元素类不同 ⇒ 确定）；与 spec §2.2 的
    // `sequence<⊤>` 正向面**无冲突**——后者由 `tt_top_k(AK_SEQUENCE)` 的 TOP_K 分支判
    // （`[T] <: sequence<⊤>` 恒 1，与元素比较无关；守门例见 x2.shape_* 段）。
    // 对齐面：legacy `type_equal([int],[str]) = false` = 0（替换门同结论，影子 old_* = 0）。
    total = total + 1; fails = fails + ts_check("param.elem_class_diff_zero", ty_sub(seq_i, seq_s), 0);
    // 未覆盖面位断言前**显式重置**（全局粘滞位，前面案例碰过 ¬μ 会误过——修复复审 N5）；
    // T3b 后本触发器改用**仍属域外**的面（μ 变元作序列元素 ⇒ te_elem_cmp 域外守卫）
    ty_budget_reset(200000);
    seq_mu := tt_atom(AK_SEQUENCE, -1, tt_cons(tt_var(0), tt_nil()));
    d_dummy := ty_sub(seq_i, seq_mu);  // 重置后重新触发一次未覆盖面（域外元素）
    total = total + 1; fails = fails + ts_check("param.uncovered_flag", ty_uncovered(), 1);

    // --- P0 终审补例（三个 Critical + 两条 Important 各配一例回归）---
    // C1：否定在超类型侧 —— ¬A ⊆ ¬B ⟺ B ⊆ A（方向反会让两侧同时成立）
    total = total + 1; fails = fails + ts_check("neg.supertype",
        ty_sub(tt_not(seq_i), tt_not(tt_top_k(AK_SEQUENCE))), 0);
    total = total + 1; fails = fails + ts_check("neg.supertype_rev",
        ty_sub(tt_not(tt_top_k(AK_SEQUENCE)), tt_not(seq_i)), 1);
    // C3：预算耗尽不得被吞成 0（三态必须上抛）——**预算窗口扫描**守「exhausted ⇒ -1」
    // 不变量（单点预算 1 会被规范化预算满足，守不住 lit_implies 吞并面——修复复审 N2）
    ok_sw : ., mut = 1;
    bi : ., mut = 1;
    loop {
        if bi > 12 { break; }
        ty_budget_reset(bi);
        r_sw := ty_sub(tt_not(seq_i), tt_not(tt_top_k(AK_SEQUENCE)));
        if ty_exhausted() == 1 && r_sw != -1 { ok_sw = 0; }
        bi = bi + 1;
    }
    ty_budget_reset(200000);
    total = total + 1; fails = fails + ts_check("budget.no_swallow_sweep", ok_sw, 1);
    // witness 的三态：-1 = 不可满足 / -2 = 未知（预算耗尽），ty_exhaustive 对 -2 → -1
    // （dom/pats 在此处重新构造：本块位于「反例+穷尽性」节之前）
    dom_u := tt_union(tt_union(a_int, a_str), a_bool);
    pats_u := tt_cons(a_int, tt_cons(a_str, tt_nil()));
    ty_budget_reset(1);
    total = total + 1; fails = fails + ts_check("witness.unknown_budget", tt_witness(a_int, a_str), -2);
    total = total + 1; fails = fails + ts_check("exhaust.unknown_budget", ty_exhaustive(dom_u, pats_u), -1);
    ty_budget_reset(200000);
    // C2：memo 表扩容不挂（1200 互异对逼出装填因子守卫 + 重建重放；到得了下一行 = 未死循环）
    d2 : ., mut = 0;
    last := 0;
    loop {
        if d2 >= 1200 { break; }
        last = ty_sub(tt_mu(d2, a_int), a_int);
        d2 = d2 + 1;
    }
    total = total + 1; fails = fails + ts_check("memo.overflow_survived", last, 1);
    // A：n 元析取（≥3）是合法 DNF（左深嵌套 union）
    total = total + 1; fails = fails + ts_check("dnf.n_ary",
        tt_is_dnf(tt_norm(tt_inter(tt_union(a_int, a_str), tt_union(a_bool, a_int)))), 1);
    // B：命名原子不展开 → 未知；且不得断言与它互斥
    named_t := tt_atom(AK_NAMED, 7, -1);
    a_prod := tt_atom(AK_PRODUCT, -1, -1);
    total = total + 1; fails = fails + ts_check("named.unknown", ty_sub(named_t, a_prod), -1);
    total = total + 1; fails = fails + ts_check("named.not_disjoint", ty_disjoint(named_t, a_prod), 0);
    // D：¬μ 不静默改写为 μ¬（保留为字面 + 未覆盖面）
    total = total + 1; fails = fails + ts_check("neg.mu_kept",
        tt_tag(tt_norm(tt_not(tt_mu(0, a_int)))), TT_NOT);

    // --- 索引扩容守门（Task 1 遗留：判据规模 << 初始容量 → 扩容/重建路径无常规覆盖）---
    ref := tt_atom(AK_SEQUENCE, -1, tt_cons(a_int, tt_nil()));
    before := tt_count();
    g_tt_index_cap = 0;      // 直接逼出 grow_tt_index → 重建索引（tt_reindex）+ 重放插入
    grow_tt_index(2);
    after := tt_atom(AK_SEQUENCE, -1, tt_cons(a_int, tt_nil()));
    total = total + 1; fails = fails + ts_check("grow.index_rebuilt", (after == ref), 1);
    d : ., mut = 0;
    loop {
        if d >= 40 { break; }
        item := tt_atom(AK_PRODUCT, -1, tt_cons(tt_mu(d, a_int), tt_nil()));
        d = d + 1;
    }
    // 40 个互异项建两遍：第二遍必须**全部命中**已有项（DAG 去重幂等）——精确断言
    // （早期版本用 `>= before+40`，既弱又不精确；P0 终审 Minor 指出）
    c_after_first := tt_count();
    d4 : ., mut = 0;
    loop {
        if d4 >= 40 { break; }
        item2 := tt_atom(AK_PRODUCT, -1, tt_cons(tt_mu(d4, a_int), tt_nil()));
        d4 = d4 + 1;
    }
    total = total + 1; fails = fails + ts_check("grow.dedup_40_idempotent", (tt_count() - c_after_first), 0);
    total = total + 1; fails = fails + ts_check("grow.dedup_after_rebuild",
        (tt_atom(AK_PRODUCT, -1, tt_cons(tt_mu(0, a_int), tt_nil())) ==
         tt_atom(AK_PRODUCT, -1, tt_cons(tt_mu(0, a_int), tt_nil()))), 1);

    // --- P1 桥接（checker ti → 引擎项，R2 P1 Task 1；映射表 = 计划 Task 1 表）---
    // 前置：本通道不经 check_all()，g_types 未初始化 → 显式 init_types()（原生 9 项
    // 占下标 0..8，用户类型自 9 起——桥接用例的 alloc_type 依赖该布局）。
    // 预算：前段用例累积 g_ty_steps（仅显式 ty_budget_reset 归零），重置到干净窗口
    // （P0 修复复审 N5 同款卫生）。
    init_types();
    ty_budget_reset(200000);
    t_int := sh_term_of_ti(TI_INT);
    total = total + 1; fails = fails + ts_check("bridge.int_atom", tt_tag(t_int), TT_ATOM);
    total = total + 1; fails = fails + ts_check("bridge.int_ak", tt_a(t_int), AK_INT);
    t_arr := sh_term_of_ti(alloc_type(TYP_ARRAY, TI_INT, 3));
    total = total + 1; fails = fails + ts_check("bridge.arr_seq", tt_a(t_arr), AK_SEQUENCE);
    t_arr3 := sh_term_of_ti(alloc_type(TYP_ARRAY, TI_INT, 4));
    total = total + 1; fails = fails + ts_check("bridge.len_not_identity",
        ty_equiv(t_arr, t_arr3), 1);            // N 不入身份（R1 裁决）——3 与 4 等价
    total = total + 1; fails = fails + ts_check("bridge.cache_hit", (sh_term_of_ti(TI_INT) == t_int), 1);
    // 原生序守门：checker 下标序 ≠ 引擎 AK 序——TI_BOOL=2/TI_STR=3 vs AK_STRING=2/AK_BOOL=3
    // （计划注释「AK_* 与 TI_* 前 7 项 1:1」**不成立**，按下标直通会 bool↔string 静默错标）
    total = total + 1; fails = fails + ts_check("bridge.str_ak", tt_a(sh_term_of_ti(TI_STR)), AK_STRING);
    total = total + 1; fails = fails + ts_check("bridge.bool_ak", tt_a(sh_term_of_ti(TI_BOOL)), AK_BOOL);
    total = total + 1; fails = fails + ts_check("bridge.dyn_ak", tt_a(sh_term_of_ti(TI_DYN)), AK_DYN);
    // M3（Task 1 评审）：native 分派 = 读表本体（kind == TYP_BASE 且 data == TY_*）——**全表覆盖**
    // （M1 后它成为主路径，此前只有 row 8 可达且无用例）。行 0..7 逐行对照，不抽样：
    // 任一行错位（含 bool↔str 互换回归）即红。
    // ⚠️ **row 7 陷阱**：TI_DYN 行 kind = TYP_DYN 而 **data = 0（== TY_INT！）**——若实现先比
    // data 再判 kind，dyn 会静默译成 AK_INT。故 ① 断言 sh_native_ak(TI_DYN) == -1（dyn 必走
    // kind 分支，绝不进 native 路径），② 项本身仍 = AK_DYN。两断言合起来把「先 data 后 kind」
    // 的写法钉死在红。
    acc_nat : ., mut = 1;
    ri : ., mut = 0;
    loop {
        if ri >= 8 { break; }
        want_ak : ., mut = -1;
        if ri == TI_INT { want_ak = AK_INT; }
        else if ri == TI_DEX { want_ak = AK_DEX; }
        else if ri == TI_BOOL { want_ak = AK_BOOL; }
        else if ri == TI_STR { want_ak = AK_STRING; }
        else if ri == TI_UNIT { want_ak = AK_UNIT; }
        else if ri == TI_NEVER { want_ak = AK_NEVER; }
        else if ri == TI_CHAR { want_ak = AK_CHAR; }
        got_ak := sh_native_ak(ri);
        if ri == TI_DYN {
            if got_ak != -1 { acc_nat = 0; }     // dyn：kind 分支，native 必 -1
        } else if got_ak != want_ak { acc_nat = 0; }
        ri = ri + 1;
    }
    total = total + 1; fails = fails + ts_check("bridge.native_row_table", acc_nat, 1);
    total = total + 1; fails = fails + ts_check("bridge.native_dyn_kind_branch",
        (sh_native_ak(TI_DYN) == -1 && tt_a(sh_term_of_ti(TI_DYN)) == AK_DYN), 1);
    // TY_DEX_S 占位行（row 8）：M1 后走 native 路径（旧实现走通用路径），两侧同 = AK_DEX
    total = total + 1; fails = fails + ts_check("bridge.native_dex_s",
        (sh_native_ak(TI_DEX_S) == AK_DEX && tt_a(sh_term_of_ti(TI_DEX_S)) == AK_DEX), 1);
    // 参数链（内层项）+ 两份同类分支不得互串（PTR/REF 是两条独立分支）
    t_ptr := sh_term_of_ti(alloc_type(TYP_PTR, TI_INT, 0));
    // M2（Task 1 评审）：class 断言与参数链**并列**——原用例只断参数链，整支误译成
    // SEQUENCE/REF 也会绿（对照 ref_inner 已断 class）
    total = total + 1; fails = fails + ts_check("bridge.ptr_ak", tt_a(t_ptr), AK_PTR);
    total = total + 1; fails = fails + ts_check("bridge.ptr_inner",
        tt_c(t_ptr), tt_cons(tt_atom(AK_INT, TI_INT, -1), tt_nil()));
    // P3 Task 1（断言更新，用例数不变）：AK_REF 链 = [mut 标记项, 元素项]（mut 入链 = 判定
    // 维度）⇒ 本用例守的「REF 链含元素项」改断链**第二项**（标记项由 t1.var_mut_* 单列）。
    // 旧断言（链首即元素）随 mut 入链的布局裁决更新——原因见 ty_shadow.cr 的 sh_ref_mut_marker。
    t_ref := sh_term_of_ti(alloc_type(TYP_REF, TI_STR, 0));
    total = total + 1; fails = fails + ts_check("bridge.ref_inner",
        (tt_a(t_ref) == AK_REF && tt_b(tt_c(t_ref)) == tt_cons(tt_atom(AK_STRING, TI_STR, -1), tt_nil())), 1);
    t_slice := sh_term_of_ti(alloc_type(TYP_SLICE, TI_STR, 0));
    total = total + 1; fails = fails + ts_check("bridge.slice_seq",
        (tt_a(t_slice) == AK_SEQUENCE && tt_c(t_slice) == tt_cons(tt_atom(AK_STRING, TI_STR, -1), tt_nil())), 1);

    // --- R2 P5 Task 2（D19/D21/D22/D23）：DFNode 类型面**单槽化** ---
    // 形态 = 两槽（OFF_DF_TK 项引用 + OFF_DF_AUX 辅码）+ 派生码（sh_dfn_code_of_slots）；
    // P4 的 `t4.tk_*` 用例保留（语义未变者原地；清单扩大/复合行走辅码者重钉）。
    // 负控的牙齿 = 每个「本该 -1」的用例都同时断言**直译路径非 -1**（证明拒绝出自
    // 分类门而非「该行不可译」——否则门形同虚设也能绿）。
    total = total + 1; fails = fails + ts_check("t4.tk_const_int",
        (sh_tk_term_of_code(IR_CONST, TI_INT) == sh_term_of_ti(TI_INT) &&
         tt_a(sh_tk_term_of_code(IR_CONST, TI_INT)) == AK_INT), 1);
    total = total + 1; fails = fails + ts_check("t4.tk_binary_dex",
        (sh_tk_term_of_code(IR_BINARY, TI_DEX) == sh_term_of_ti(TI_DEX) &&
         tt_a(sh_tk_term_of_code(IR_BINARY, TI_DEX)) == AK_DEX), 1);
    total = total + 1; fails = fails + ts_check("t4.tk_const_dex_s_row8",
        (sh_tk_term_of_code(IR_CONST, TI_DEX_S) == sh_term_of_ti(TI_DEX_S) &&
         tt_a(sh_tk_term_of_code(IR_CONST, TI_DEX_S)) == AK_DEX), 1);
    // 负控 ①：IR_BOUNDS_CHECK 的 tk 是旗标（1 = 动态上限），而 1 数值上 = TI_DEX 行
    // ——直译有值 ⇒ 只能靠分类门挡住（凭空安 dex 项 = 本用例钉死的形态）。
    total = total + 1; fails = fails + ts_check("t4.tk_bounds_flag1_rejected",
        (sh_tk_term_of_code(IR_BOUNDS_CHECK, 1) == -1 && sh_term_of_ti(1) >= 0), 1);
    // 负控 ②：IR_DEREF 的 tk 是访问宽度（8B），8 数值上 = TI_DEX_S 行（同款陷阱）。
    total = total + 1; fails = fails + ts_check("t4.tk_deref_width8_rejected",
        (sh_tk_term_of_code(IR_DEREF, 8) == -1 && sh_term_of_ti(TI_DEX_S) >= 0), 1);
    // 负控 ③（重钉：P5 T2 起 IR_CALL/IR_ALLOC 入类型行面 ⇒ 换成「面外」op）：
    // 「行合法（0 = TI_INT）但 op 不在任何类型/辅码面」——面外 op 不得因 tk 恰好合法而放行。
    total = total + 1; fails = fails + ts_check("t4.tk_unlisted_op_valid_row_rejected",
        (sh_tk_term_of_code(IR_STORE, TI_INT) == -1 &&
         sh_tk_term_of_code(IR_RETURN, TI_INT) == -1 &&
         sh_tk_term_of_code(IR_MAKE_ENUM, TI_INT) == -1 &&
         sh_term_of_ti(TI_INT) >= 0), 1);
    // 负控 ④：行号越界 / 负值 ⇒ -1（不得当 0/1 用；不得读越界项表）。
    total = total + 1; fails = fails + ts_check("t4.tk_row_range_rejected",
        (sh_tk_term_of_code(IR_CONST, g_type_count) == -1 &&
         sh_tk_term_of_code(IR_BINARY, g_type_count + 7) == -1 &&
         sh_tk_term_of_code(IR_CONST, -1) == -1), 1);
    // 查询纯度（P5 T2 引入 / **P5 T5 重钉**：原断言 = 「本函数不扰动影子对账的 hits 计数」，
    // 影子通道下线后该计数已不存在 ⇒ 改钉**查询纯度**这一同源性质）：`sh_tk_term_of_code`
    // 是**纯查询**——不写槽出参、不置 D23 失败位（诊断调用不得污染落盘闸；有副作用的生产
    // 路径一律走 sh_tk_split）；且对同一行返回**同一项**（缓存语义）。
    // 牙齿：必须取**非原生行**（原生行走 sh_native_ak 快路径，本就不进缓存 ⇒ 拿 TI_INT 测
    // 等于恒真断言）。TYP_DYN 行首次直译建项入缓存、二次直译命中同项。
    t4_dyn_row := alloc_type(TYP_DYN, 0, 0);
    t4_dyn_term := sh_term_of_ti(t4_dyn_row);          // 预热：首次（miss）入桥接缓存
    t4_fail_0 := g_tk_face_fail;
    sh_tk_split(IR_CONST, g_type_count);               // 槽出参置哨兵（越界行 ⇒ term=-1/aux=越界行号）
    t4_sent_t := g_sh_slot_term;
    t4_sent_a := g_sh_slot_aux;
    t4_fail_before := g_tk_face_fail;
    sk4 := sh_tk_term_of_code(IR_CONST, t4_dyn_row);   // 查询路径（缓存命中）
    total = total + 1; fails = fails + ts_check("t4.tk_query_purity_and_cache_hit",
        ((t4_dyn_term >= 0 && sk4 == t4_dyn_term &&
          g_sh_slot_term == t4_sent_t && g_sh_slot_aux == t4_sent_a &&
          g_tk_face_fail == t4_fail_before)), 1);
    g_tk_face_fail = t4_fail_0;                        // 复位（哨兵行的 D23 位 = 本用例产物，不留给后续）

    // ── R2 P5 Task 2 新例 ①：原子行契约（D21）──
    // TT_ATOM ∧ b ≥ 0 ⇒ b；union / cons / nil / 负 / 越界 ⇒ **-1**（显式，不得近似）。
    t5s_ptr_row := alloc_type(TYP_PTR, TI_INT, 0);
    t5s_ptr_term := sh_term_of_ti(t5s_ptr_row);
    total = total + 1; fails = fails + ts_check("p5t2.atom_of_contract",
        (tt_atom_of_term(sh_term_of_ti(TI_INT)) == TI_INT &&
         tt_atom_of_term(t5s_ptr_term) == -1 &&            // 复合项：AK_PTR 的 b = -1
         tt_atom_of_term(tt_nil()) == -1 &&
         tt_atom_of_term(tt_cons(tt_atom(AK_INT, TI_INT, -1), tt_nil())) == -1 &&
         tt_atom_of_term(-1) == -1 &&
         tt_atom_of_term(tt_count() + 9) == -1), 1);

    // ── 新例 ②：类型行面 —— 改走 split，断言**两槽**（项 + 空辅码）+ 互斥 ──
    sh_tk_split(IR_BINARY, TI_STR);
    t5s_bin_str_term := g_sh_slot_term;
    t5s_bin_str_aux := g_sh_slot_aux;
    total = total + 1; fails = fails + ts_check("p5t2.slot_type_face_atomic",
        (t5s_bin_str_term == sh_term_of_ti(TI_STR) && t5s_bin_str_aux == 0 &&
         sh_dfn_code_of_slots(t5s_bin_str_term, t5s_bin_str_aux) == TI_STR), 1);

    // ── 新例 ③：类型行面扩面（Task 0 再裁的 5 个 op 正控）──
    sh_tk_split(IR_ALLOC, TI_UNIT); t5s_a1 := g_sh_slot_term; t5s_a1x := g_sh_slot_aux;
    sh_tk_split(IR_CALL, TI_INT); t5s_a2 := g_sh_slot_term; t5s_a2x := g_sh_slot_aux;
    sh_tk_split(IR_LOAD, TI_INT); t5s_a3 := g_sh_slot_term; t5s_a3x := g_sh_slot_aux;
    sh_tk_split(IR_I2F, TI_DEX); t5s_a4 := g_sh_slot_term; t5s_a4x := g_sh_slot_aux;
    sh_tk_split(IR_F2I, TI_DEX); t5s_a5 := g_sh_slot_term; t5s_a5x := g_sh_slot_aux;
    total = total + 1; fails = fails + ts_check("p5t2.slot_type_face_extended",
        (t5s_a1 == sh_term_of_ti(TI_UNIT) && t5s_a1x == 0 && tt_a(t5s_a1) == AK_UNIT &&
         t5s_a2 == sh_term_of_ti(TI_INT) && t5s_a2x == 0 &&
         t5s_a3 == sh_term_of_ti(TI_INT) && t5s_a3x == 0 &&
         t5s_a4 == sh_term_of_ti(TI_DEX) && t5s_a4x == 0 && tt_a(t5s_a4) == AK_DEX &&
         t5s_a5 == sh_term_of_ti(TI_DEX) && t5s_a5x == 0 && tt_a(t5s_a5) == AK_DEX), 1);

    // ── 新例 ④：复合行 ⇒ 走辅码（F2 裁决；码保真，派生码 ≡ 旧混用码）──
    // 牙齿：先证该行**可译**（sh_term_of_ti ≥ 0）——否则「term = -1」可能出自不可译，
    // 门形同虚设也能绿。
    sh_tk_split(IR_BINARY, t5s_ptr_row);
    total = total + 1; fails = fails + ts_check("p5t2.slot_composite_row_to_aux",
        (t5s_ptr_term >= 0 && g_sh_slot_term == -1 && g_sh_slot_aux == t5s_ptr_row &&
         sh_dfn_code_of_slots(g_sh_slot_term, g_sh_slot_aux) == t5s_ptr_row), 1);
    // 同款：数组行（AK_SEQUENCE 的 b = 长度或 -1 ⇒ 复合）。
    t5s_arr_row := alloc_type(TYP_ARRAY, TI_INT, 3);
    sh_tk_split(IR_CONST, t5s_arr_row);
    total = total + 1; fails = fails + ts_check("p5t2.slot_array_row_to_aux",
        (sh_term_of_ti(t5s_arr_row) >= 0 && g_sh_slot_term == -1 &&
         g_sh_slot_aux == t5s_arr_row &&
         sh_dfn_code_of_slots(g_sh_slot_term, g_sh_slot_aux) == t5s_arr_row), 1);

    // ── 新例 ⑤：辅码面 —— 旗标 / 宽度 / 计数（含负码）原码保真 ──
    sh_tk_split(IR_BOUNDS_CHECK, 1); t5s_f1t := g_sh_slot_term; t5s_f1a := g_sh_slot_aux;
    sh_tk_split(IR_BOUNDS_CHECK, 0); t5s_f0t := g_sh_slot_term; t5s_f0a := g_sh_slot_aux;
    sh_tk_split(IR_DEREF, 8); t5s_d8t := g_sh_slot_term; t5s_d8a := g_sh_slot_aux;
    sh_tk_split(IR_STORE_PTR, 4); t5s_d4t := g_sh_slot_term; t5s_d4a := g_sh_slot_aux;
    sh_tk_split(IR_SPAWN, -1); t5s_spt := g_sh_slot_term; t5s_spa := g_sh_slot_aux;
    total = total + 1; fails = fails + ts_check("p5t2.slot_aux_face_codes",
        (t5s_f1t == -1 && t5s_f1a == 1 && sh_dfn_code_of_slots(t5s_f1t, t5s_f1a) == 1 &&
         t5s_f0t == -1 && t5s_f0a == 0 && sh_dfn_code_of_slots(t5s_f0t, t5s_f0a) == 0 &&
         t5s_d8t == -1 && t5s_d8a == 8 && sh_dfn_code_of_slots(t5s_d8t, t5s_d8a) == 8 &&
         t5s_d4t == -1 && t5s_d4a == 4 &&
         t5s_spt == -1 && t5s_spa == -1 && sh_dfn_code_of_slots(t5s_spt, t5s_spa) == -1), 1);
    // 数值陷阱复证：辅码 1 / 8 直译确有其项（TI_DEX / TI_DEX_S 行）——分类门才是拦阻者。
    total = total + 1; fails = fails + ts_check("p5t2.aux_trap_rows_translatable",
        (sh_term_of_ti(1) >= 0 && tt_a(sh_term_of_ti(1)) == AK_DEX &&
         sh_term_of_ti(TI_DEX_S) >= 0 && tt_a(sh_term_of_ti(TI_DEX_S)) == AK_DEX &&
         sh_tk_term_of_code(IR_STORE_PTR, TI_DEX_S) == -1), 1);

    // ── 新例 ⑥：面外 op ⇒ 两槽皆空、派生码 0（含 LOAD_ENUM_TAG = Task 0 再裁「无」）──
    sh_tk_split(IR_STORE, 0); t5s_n1t := g_sh_slot_term; t5s_n1a := g_sh_slot_aux;
    sh_tk_split(IR_LOAD_ENUM_TAG, 0); t5s_n2t := g_sh_slot_term; t5s_n2a := g_sh_slot_aux;
    sh_tk_split(IR_LABEL, 0); t5s_n3t := g_sh_slot_term; t5s_n3a := g_sh_slot_aux;
    total = total + 1; fails = fails + ts_check("p5t2.slot_none_face_empty",
        (t5s_n1t == -1 && t5s_n1a == 0 && sh_dfn_code_of_slots(t5s_n1t, t5s_n1a) == 0 &&
         t5s_n2t == -1 && t5s_n2a == 0 && t5s_n3t == -1 && t5s_n3a == 0), 1);

    // ── 新例 ⑦：派生码契约（辅码优先 / 无项⇒0 / 不可逆⇒-1 显式）──
    total = total + 1; fails = fails + ts_check("p5t2.code_derivation_contract",
        (sh_dfn_code_of_slots(sh_term_of_ti(TI_STR), 0) == TI_STR &&
         sh_dfn_code_of_slots(-1, 0) == 0 &&
         sh_dfn_code_of_slots(-1, 7) == 7 &&
         sh_dfn_code_of_slots(t5s_ptr_term, 0) == -1 &&      // 复合项入项槽 = 无法派生（显式响亮）
         sh_dfn_code_of_slots(sh_term_of_ti(TI_INT), 9) == 9), 1);   // 辅码优先（互斥由拆分器保证）

    // ── 新例 ⑧：互斥不变量（D22-②）逐 op 复核（面 0 / 面 1 / 面 2 各取代表）──
    sh_tk_split(IR_CONST, TI_STR); t5s_m1 := (g_sh_slot_term >= 0 && g_sh_slot_aux == 0);
    sh_tk_split(IR_DEREF, 8); t5s_m2 := (g_sh_slot_term == -1 && g_sh_slot_aux != 0);
    sh_tk_split(IR_STORE, 0); t5s_m3 := (g_sh_slot_term == -1 && g_sh_slot_aux == 0);
    t5s_m_ok := 1;
    if t5s_m1 == 0 || t5s_m2 == 0 || t5s_m3 == 0 { t5s_m_ok = 0; }
    total = total + 1; fails = fails + ts_check("p5t2.slot_mutual_exclusion", t5s_m_ok, 1);

    // ── 新例 ⑨：F1 修正（IR_HOTPATCH_ROUTE 的类型面 = 无；显式 0 实参 ⇒ 两槽皆空）──
    sh_tk_split(IR_HOTPATCH_ROUTE, 0);
    total = total + 1; fails = fails + ts_check("p5t2.hotpatch_route_no_face",
        (g_sh_slot_term == -1 && g_sh_slot_aux == 0 &&
         sh_dfn_code_of_slots(g_sh_slot_term, g_sh_slot_aux) == 0), 1);

    // ── 新例 ⑩：D23 建项失败位（越界类型面行 ⇒ 计数 +1；复合行**不**置位）──
    t5s_fail_before := g_tk_face_fail;
    sh_tk_split(IR_CONST, g_type_count);
    t5s_fail_after := g_tk_face_fail;
    t5s_out_t := g_sh_slot_term;               // 出参须**即时**取（下一次 split 会覆写）
    t5s_out_a := g_sh_slot_aux;
    sh_tk_split(IR_BINARY, t5s_ptr_row);      // 复合行 = 域内可译 ⇒ 不得置位
    t5s_fail_final := g_tk_face_fail;
    g_tk_face_fail = 0;                        // 复位（不污染后续落盘闸用例）
    total = total + 1; fails = fails + ts_check("p5t2.d23_build_fail_bit",
        (t5s_fail_after == t5s_fail_before + 1 && t5s_fail_final == t5s_fail_after &&
         t5s_out_t == -1 && t5s_out_a == g_type_count), 1);
    // TYP_NAMED：AK_NAMED + 行号存 b 槽（引擎不展开 → 判定 UNKNOWN = P1 预期未覆盖面）
    // ⚠️ 本行**刻意走裸分配**（P2a Task 1 后 8 个生产分配点已收敛到 alloc_named_type）：
    // 它构造的是人造 TYP_NAMED 行（键 1201 不对应任何真名），登记进生产侧表会用假键污染
    // name→ti 映射（自测将来若被并入编译路径即静默错型）。裸分配 = 不登记 = 不污染。
    named_ti := alloc_type(TYP_NAMED, 1201, 0);
    t_named := sh_term_of_ti(named_ti);
    total = total + 1; fails = fails + ts_check("bridge.named_ak_b",
        (tt_a(t_named) == AK_NAMED && tt_b(t_named) == named_ti), 1);
    // TYP_TUPLE 实读布局（checker.cr:118 type_equal 分支 + :2041+ 字段访问 t.N）：
    //   data = 字段数，extra = 字段 ti 在 g_gen_apply_data 的起始下标（8B/元素）
    grow_gen_apply_data(g_gen_apply_data_count + 2);
    tup_start := g_gen_apply_data_count;
    w64(g_gen_apply_data, tup_start * 8, TI_INT);
    w64(g_gen_apply_data, (tup_start + 1) * 8, TI_STR);
    g_gen_apply_data_count = g_gen_apply_data_count + 2;
    t_tup := sh_term_of_ti(alloc_type(TYP_TUPLE, 2, tup_start));
    total = total + 1; fails = fails + ts_check("bridge.tuple_product", tt_a(t_tup), AK_PRODUCT);
    total = total + 1; fails = fails + ts_check("bridge.tuple_fields",
        tt_c(t_tup), tt_cons(tt_atom(AK_INT, TI_INT, -1), tt_cons(tt_atom(AK_STRING, TI_STR, -1), tt_nil())));
    // 缓存语义：新 ti 恰入表 1 条（其元素 = 原生快路径，不入表）；同 ti 二次调用 = 命中
    // （**P5 T5 重钉**：原断言 = hits 计数恰 +1；影子 hits 通道已随影子层下线 ⇒ 改钉
    // 「命中 ⇒ 同项 + 不新增条目」——同一语义的占用面证据，不再依赖计数器）。
    e_before := sh_map_entries();
    arr_ti2 := alloc_type(TYP_ARRAY, TI_STR, 9);
    t_arr2 := sh_term_of_ti(arr_ti2);
    total = total + 1; fails = fails + ts_check("bridge.entries_delta", (sh_map_entries() - e_before), 1);
    e_hit_before := sh_map_entries();
    t_arr2b := sh_term_of_ti(arr_ti2);
    total = total + 1; fails = fails + ts_check("bridge.cache_hit_same_term_no_new_entry",
        (t_arr2b == t_arr2 && sh_map_entries() == e_hit_before), 1);
    // 缓存扩容/重建守门（P0「扩容路径判据不可达」教训同款）：上面仅 8 条 << 初始容量
    // 1024 → 装填因子守卫/重建路径**不可达**。用 600 个互异 ti（extra=N 各不同 = 互异
    // 类型表行，正是「N 不入身份」下 600 行同项的典型规模）逼出一次扩容重建（守卫
    // (entries+1)*2 >= cap 在 entries=511 时触发）；再验两件事：①重放守恒（条目数恰
    // +600，不多不少）②重建**前**已入表的条目仍命中（重放把旧表条目全搬过去了）。
    g_before := sh_map_entries();
    gi : ., mut = 0;
    loop {
        if gi >= 600 { break; }
        sh_term_of_ti(alloc_type(TYP_ARRAY, TI_INT, 1000 + gi));
        gi = gi + 1;
    }
    total = total + 1; fails = fails + ts_check("bridge.grow_rehash",
        (sh_map_entries() == g_before + 600 && sh_term_of_ti(arr_ti2) == t_arr2), 1);
    total = total + 1; fails = fails + ts_check("bridge.grow_cap_doubled", (g_term_map_cap >= 2048), 1);
    // 第二次重建守门（Step 4b ②，Task 1 评审挂账：「>1024 条目第二次重建无实测」）：
    // 上一例只推过第一条守卫线（entries=511 → cap 1024→2048）；本例再入 1100 条互异 ti
    // 把条目推过第二条守卫线（entries=1023 → cap 2048→4096）——断三件事：①重放守恒（恰
    // +1100，不多不少）②cap ≥ 4096（**证明**第二次重建真的发生，不是「读码判安全」）
    // ③首批（第一次重建前入表）条目仍命中（两次重放都把它搬过去了）。
    g2_before := sh_map_entries();
    gj : ., mut = 0;
    loop {
        if gj >= 1100 { break; }
        sh_term_of_ti(alloc_type(TYP_ARRAY, TI_INT, 5000 + gj));
        gj = gj + 1;
    }
    total = total + 1; fails = fails + ts_check("bridge.grow_rehash2",
        (sh_map_entries() == g2_before + 1100 && g_term_map_cap >= 4096 && sh_term_of_ti(arr_ti2) == t_arr2), 1);

    // --- F1（R2 P2a Task 1）：同名 TYP_NAMED 归一行 —— P1 影子对拍 9/9 差异根因消除 ---
    // 根因：同一类型名（struct 字面量 / 泛型应用基型在不同**出现点**）各建一行 → 桥接按行
    // 建原子（AK_NAMED 的 b 槽 = 行号）→ 引擎视两行为互异命名类型 → 判不了（9 条 unknown）。
    // 修法（用户裁决 = 根治）：建表去重，唯一分配点收敛到 alloc_named_type。
    n1 := alloc_named_type(str_intern("DedupProbe"));
    n2 := alloc_named_type(str_intern("DedupProbe"));
    total = total + 1; fails = fails + ts_check("f1.same_name_one_row", (n1 == n2), 1);
    total = total + 1; fails = fails + ts_check("f1.row_count", named_dedup_rows(str_intern("DedupProbe")), 1);
    n3 := alloc_named_type(str_intern("DedupProbe2"));
    total = total + 1; fails = fails + ts_check("f1.diff_name_diff_row", (n3 != n1), 1);
    // 引擎侧：同名两行归一后，桥接的同一性成立（P1 的 9 unknown 根因消除）
    total = total + 1; fails = fails + ts_check("f1.bridge_same_term",
        (sh_term_of_ti(n1) == sh_term_of_ti(n2)), 1);
    // 扩容/重建覆盖（P0/P1 血泪教训：装填守卫/重建重放路径判据不可达 = 挂死风险只靠读码）：
    // 入 1700 个互异**真名**（键域 = str_intern 分配的名字下标，与生产同域）推过**两道**
    // 守卫线——count=511 → cap 1024→2048，count=1023 → 2048→4096。断四件事：①两次重建都
    // 真的发生（cap≥4096，非「读码判安全」）②重放守恒（条目计数恰 +1700，不多不少——
    // 重放漏条目/重复计数即红）③首条（重建前入表）仍归**原行**（重放把旧条目全搬过去了）
    // ④该名字行数仍为 1（重建不产生重复行 = 去重不因扩容失效）。
    c_before := g_named_dedup_count;
    f1i : ., mut = 0;
    loop {
        if f1i >= 1700 { break; }
        alloc_named_type(str_intern("DedupGrow" + int_str(f1i)));
        f1i = f1i + 1;
    }
    total = total + 1; fails = fails + ts_check("f1.dedup_rehash_survived",
        (g_named_dedup_cap >= 4096 && g_named_dedup_count == c_before + 1700 && alloc_named_type(str_intern("DedupProbe")) == n1 && named_dedup_rows(str_intern("DedupProbe")) == 1), 1);

    // --- F2（R2 P2a Task 2）：数组长度 N 迁为「常量档长度约束」 ---
    // 背景（P1 findings §6.F2）：身份判等曾把 N 与元素判等绑在一起（N 属身份）；引擎侧按
    // R1 裁决 **N 不入身份** → 直接替换判定会让 `[int;4]` → `[int;3]` **静默通过**。
    // 修法（用户裁决 = 落常量档长度约束）：N 迁出身份 → 具名约束 array_len_constraint_ok
    // （判定点显式补检）；拒绝语义保持（异长仍拒、同长仍过）。本组即该约束的守门用例。
    // 默认预算窗口（ty_equiv 用例计数）——本组之前的用例只碰过裸分配/侧表，未跑判定。
    ty_budget_reset(200000);
    f2_arr3 := alloc_type(TYP_ARRAY, TI_INT, 3);
    f2_arr3b := alloc_type(TYP_ARRAY, TI_INT, 3);   // **另一行**同长：约束不可是 ti 同一性
    f2_arr4 := alloc_type(TYP_ARRAY, TI_INT, 4);
    total = total + 1; fails = fails + ts_check("f2.same_len_ok",
        array_len_constraint_ok(f2_arr3, f2_arr3b), 1);
    total = total + 1; fails = fails + ts_check("f2.diff_len_reject",
        array_len_constraint_ok(f2_arr4, f2_arr3), 0);
    // 引擎侧：N 不入身份（spec §5.1；与 bridge.len_not_identity 同义，此处另立一行）
    total = total + 1; fails = fails + ts_check("f2.engine_len_agnostic",
        ty_equiv(sh_term_of_ti(f2_arr4), sh_term_of_ti(f2_arr3)), 1);
    // 结构下钻（N 不在顶层数组位也要拦住——否则身份去 N 后这些位置静默放宽）：
    // ① 数组元素位 `[[int;3];2]`；② 泛型应用实参位 `G<[int;3]>`；③ 指针元素位 `*[int;3]`；
    // ④ 元组字段位 `(int, [int;3])`。每例双断：同结构同长 → 1 / 同结构异长 → 0（防误拒）。
    f2_outer3 := alloc_type(TYP_ARRAY, f2_arr3, 2);
    f2_outer4 := alloc_type(TYP_ARRAY, f2_arr4, 2);
    total = total + 1; fails = fails + ts_check("f2.nested_elem_reject",
        (array_len_constraint_ok(f2_outer3, f2_outer3) == 1 && array_len_constraint_ok(f2_outer4, f2_outer3) == 0), 1);
    grow_gen_apply_data(g_gen_apply_data_count + 4);
    f2_ga_s1 := g_gen_apply_data_count;
    w64(g_gen_apply_data, f2_ga_s1 * 8, 1);
    w64(g_gen_apply_data, (f2_ga_s1 + 1) * 8, f2_arr3);
    f2_ga_s2 := f2_ga_s1 + 2;
    w64(g_gen_apply_data, f2_ga_s2 * 8, 1);
    w64(g_gen_apply_data, (f2_ga_s2 + 1) * 8, f2_arr4);
    g_gen_apply_data_count = f2_ga_s2 + 2;
    // base 走**裸分配**（人造行不入侧表——P1 桥接夹具同款约定，防假键污染 name→ti）
    f2_base := alloc_type(TYP_NAMED, 1202, 0);
    f2_ga3 := alloc_type(TYP_GENERIC_APPLY, f2_base, f2_ga_s1);
    f2_ga4 := alloc_type(TYP_GENERIC_APPLY, f2_base, f2_ga_s2);
    total = total + 1; fails = fails + ts_check("f2.genapply_arg_reject",
        (array_len_constraint_ok(f2_ga3, f2_ga3) == 1 && array_len_constraint_ok(f2_ga4, f2_ga3) == 0), 1);
    f2_pt3 := alloc_type(TYP_PTR, f2_arr3, 0);
    f2_pt4 := alloc_type(TYP_PTR, f2_arr4, 0);
    total = total + 1; fails = fails + ts_check("f2.ptr_elem_reject",
        (array_len_constraint_ok(f2_pt3, f2_pt3) == 1 && array_len_constraint_ok(f2_pt4, f2_pt3) == 0), 1);
    grow_gen_apply_data(g_gen_apply_data_count + 4);
    f2_tp_s1 := g_gen_apply_data_count;
    w64(g_gen_apply_data, f2_tp_s1 * 8, TI_INT);
    w64(g_gen_apply_data, (f2_tp_s1 + 1) * 8, f2_arr3);
    f2_tp_s2 := f2_tp_s1 + 2;
    w64(g_gen_apply_data, f2_tp_s2 * 8, TI_INT);
    w64(g_gen_apply_data, (f2_tp_s2 + 1) * 8, f2_arr4);
    g_gen_apply_data_count = f2_tp_s2 + 2;
    f2_tup3 := alloc_type(TYP_TUPLE, 2, f2_tp_s1);
    f2_tup4 := alloc_type(TYP_TUPLE, 2, f2_tp_s2);
    total = total + 1; fails = fails + ts_check("f2.tuple_field_reject",
        (array_len_constraint_ok(f2_tup3, f2_tup3) == 1 && array_len_constraint_ok(f2_tup4, f2_tup3) == 0), 1);
    // 负控：非数组对（含单侧数组）长度面无约束 → 恒满足（防「一律拒绝」的退化实现）
    total = total + 1; fails = fails + ts_check("f2.nonarray_no_constraint",
        (array_len_constraint_ok(f2_arr3, TI_INT) == 1 && array_len_constraint_ok(TI_INT, f2_arr3) == 1), 1);
    // Task 4 Step 5c（Task 2 评审 M2 收口）：① 补齐约束的 REF / SLICE 两个递归位（此前已钉
    // 数组元素 / 泛型实参 / 指针元素 / 元组字段四位，下钻面 6 位里缺这两位）；② 把**站点接线**
    // 纳入自测面——站点的措辞由 type_compat_strict 的**三态**分派（1 = 兼容 / 0 = 身份不匹配
    // → 原措辞 / -1 = 身份通过但长度约束违反 → 专属措辞），故 0 与 -1 的**区分**本身就是判据
    // （把两路并成一路 = 措辞面回归，且会把「长度不满足」误报成普通类型不匹配）。
    // REF 位注：约束只看 data（元素），**不**比 extra（mut）——mut 归身份判定（头注「同形」限定）。
    f2_rf3 := alloc_type(TYP_REF, f2_arr3, 0);
    f2_rf4 := alloc_type(TYP_REF, f2_arr4, 0);
    total = total + 1; fails = fails + ts_check("f2.ref_elem_reject",
        (array_len_constraint_ok(f2_rf3, f2_rf3) == 1 && array_len_constraint_ok(f2_rf4, f2_rf3) == 0), 1);
    f2_sl3 := alloc_type(TYP_SLICE, f2_arr3, 0);
    f2_sl4 := alloc_type(TYP_SLICE, f2_arr4, 0);
    total = total + 1; fails = fails + ts_check("f2.slice_elem_reject",
        (array_len_constraint_ok(f2_sl3, f2_sl3) == 1 && array_len_constraint_ok(f2_sl4, f2_sl3) == 0), 1);
    // 站点三态（type_compat_strict 恒「先 type_equal 再约束」，站点调用面不变）：
    // ① 同结构同长 → 1；② 异结构（数组 vs 基类型）→ 0（身份面否决，原措辞）；③ 同结构异长
    // → -1（**只有**这一路走长度措辞；且它证明 type_equal 已放行 = 引擎身份确实 N-free）。
    total = total + 1; fails = fails + ts_check("t3.strict_dispatch_ok",
        type_compat_strict(f2_arr3, f2_arr3b), 1);
    total = total + 1; fails = fails + ts_check("t3.strict_dispatch_identity",
        type_compat_strict(f2_arr3, TI_INT), 0);
    total = total + 1; fails = fails + ts_check("t3.strict_dispatch_len",
        type_compat_strict(f2_arr4, f2_arr3), -1);

    // --- R2 P2a Task 3：判定替换（引擎为判定权威 + unknown 政策 + N 不回身份）---
    // ① N 面（Task 2/3 评审裁决「N 不得回身份」）：`type_equal`（引擎判定）对**同结构异长**
    //    判 true——N 不在身份内；拒绝语义由 array_len_constraint_ok 独立承担（第二断）。
    //    两断合起来 = 该不变量的双钉：引擎不放宽成身份 → 但拒绝不丢。
    // ② unknown 政策（R2 P5 Task 3 重钉 → T4 终态）：两个**互异命名型**行 → 桥接身份链 ⇒
    //    引擎**自决 0**（不再未知 ⇒ 零回落）；T4 后回落本体已删 ⇒ 断言 = 「自决 + 零未知
    //    诊断（ICE04 缺席）」。**不得静默当 0/1** 的牙齿在 t4.ice04_* 三例（真未知面）。
    // ③ 同一行快路径：不触发引擎/回落（同型自反恒 true）。
    ty_budget_reset(200000);
    t3_arr3 := alloc_type(TYP_ARRAY, TI_INT, 3);
    t3_arr4 := alloc_type(TYP_ARRAY, TI_INT, 4);
    t3_ok : ., mut = 0;
    if type_equal(t3_arr3, t3_arr4) {
        if array_len_constraint_ok(t3_arr4, t3_arr3) == 0 { t3_ok = 1; }
    }
    total = total + 1; fails = fails + ts_check("t3.engine_len_not_identity", t3_ok, 1);
    // 行 1203/1204 = 人造行（不进生产侧表语义面；alloc_named_type 仅为取得互异 named 行）
    t3_na := alloc_named_type(str_intern("T3NamedA"));
    t3_nb := alloc_named_type(str_intern("T3NamedB"));
    // **R2 P5 Task 3 重钉 / T4 终态**：命名面接引擎（身份链）后本形态 = 引擎**自决 0**
    // （= legacy 同值），不再回落——T4 后回落计数本体亦删 ⇒ 断言形态 = 「行为（false）+
    // 引擎直判 0 + **零未知诊断**（ICE04 缺席 = 引擎真判而非未知被静默当 false）」。
    t3_d0 := g_diag_count;
    t3_ub : ., mut = 0;
    if !type_equal(t3_na, t3_nb) {
        if g_diag_count == t3_d0 { t3_ub = 1; }
    }
    total = total + 1; fails = fails + ts_check("t3.named_face_decided_no_indeterminate",
        (t3_ub == 1 && ty_equiv(sh_term_of_ti(t3_na), sh_term_of_ti(t3_nb)) == 0), 1);
    // 桥接缺口（sh_term_of_ti 译不成项：行号越界）→ **P-A 硬错**（T4 重钉：旧行为 = 回落
    // legacy + g_replace_bridge 计数；现行为 = 判 false + ICE04 诊断恰 1 条）。措辞/成因面
    // 由 t4.ice04_* 段复核（本例只钉「行为 + 码」）。
    t3_bf_d0 := g_diag_count;
    t3_bf : ., mut = 0;
    if !type_equal(g_type_count + 100, TI_INT) {
        if g_diag_count == t3_bf_d0 + 1 {
            if ts_diag_code_at(t3_bf_d0) == EC_ICE_TY_INDET { t3_bf = 1; }
        }
    }
    total = total + 1; fails = fails + ts_check("t3.bridge_gap_ice04_hard_error", t3_bf, 1);
    g_diag_count = t3_bf_d0;    // 本诊断是**故意**触发的（复位：不留进后续用例的增量基线）
    ty_budget_reset(200000);

    // --- R2 P2a Task 3 评审 Critical：桥接缓存**随类型表重置失效**（sh_map_reset）---
    // 机制：判定路径**无条件**调 sh_term_of_ti（R2 P2a Task 3 起；此前仅 --type-shadow 下译项，
    // 该旗标随 P5 T5 影子层下线删除）→ 桥接缓存
    // key = ti 本体，而 init_types() 清空重建类型表（**行号空间复用**）→ 陈旧的 ti→term 命中
    // 即返回 = 两个不同类型被判等（长驻进程静默漏报；评审复现：corelsp 同 URI 两次 didOpen）。
    // 用例 ① 重置后缓存确实清空（entries 0 + cap 0 = 惰性重建）；② 行号复用场景下**不得**返回
    // 陈旧项——返回的必须是新类型的项（元素 AK 由 int 变 bool）。② 是 ① 的行为级对偶：
    // 只查计数不查返回值的断言在「清了计数但表还活着」的错法下会假绿。
    init_types();                                    // 干净起点（同时建立缓存基线）
    t3c_tiA := alloc_type(TYP_ARRAY, TI_INT, 2);     // 行号 T
    t3c_termA := sh_term_of_ti(t3c_tiA);             // 缓存 {T → seq(int)}
    t3c_entries_mid := sh_map_entries();
    init_types();                                    // 类型表 + 桥接缓存一并失效
    t3c_entries_after := sh_map_entries();
    total = total + 1; fails = fails + ts_check("t3c.map_reset_clears_bridge",
        (t3c_entries_mid >= 1 && t3c_entries_after == 0 && g_term_map_cap == 0), 1);
    t3c_tiB := alloc_type(TYP_ARRAY, TI_BOOL, 2);    // 同一行号 T（复用）
    t3c_termB := sh_term_of_ti(t3c_tiB);
    t3c_ok : ., mut = 0;
    if t3c_tiB == t3c_tiA {                          // 场景成立：行号确实复用
        if t3c_termB != t3c_termA {                  // 未返回陈旧项
            if tt_a(tt_a(tt_c(t3c_termA))) == AK_INT {
                if tt_a(tt_a(tt_c(t3c_termB))) == AK_BOOL { t3c_ok = 1; }
            }
        }
    }
    total = total + 1; fails = fails + ts_check("t3c.no_stale_term_after_reset", t3c_ok, 1);

    // --- R2 P2b Task 1：本质条目表 + `iface_*` 查询 API（零消费者建层；表 = 静态数据）---
    // 前置：表由 init_types() 尾部建立（本通道不经 check_all → 与 P1 桥接段同款显式调用）；
    // 显式重建 = 干净起点（类型表行号空间复位，结构行自 9 起）。
    // 覆盖面口径：**16 条目**（R2 P4 Task 3 扩列：13 → +AK_NULL +AK_SUM +AK_FN）× 两向
    // （ak→ti 行 / 行→ak 类）+ 12 个 API 逐签名；8 原生逐条目不抽样。扩列 = 纯信息面
    // （三新行 ops = 0、ti_row = -1）——判定面零变化由 `ct2.kind_of_no_new_mapping`（全类型
    // 行枚举）承担，本行只钉「可查询性」面。
    init_types();
    total = total + 1; fails = fails + ts_check("iface.count", iface_count(), 16);
    // 逐原生条目：ak → 规范行 + **AK↔TI 下标不 1:1** 的显式守卫（bool/string 互换即红）
    total = total + 1; fails = fails + ts_check("iface.int_ti", iface_ti_of(AK_INT), TI_INT);
    total = total + 1; fails = fails + ts_check("iface.dex_ti", iface_ti_of(AK_DEX), TI_DEX);
    total = total + 1; fails = fails + ts_check("iface.str_ti", iface_ti_of(AK_STRING), TI_STR);
    total = total + 1; fails = fails + ts_check("iface.bool_ti", iface_ti_of(AK_BOOL), TI_BOOL);
    total = total + 1; fails = fails + ts_check("iface.unit_ti", iface_ti_of(AK_UNIT), TI_UNIT);
    total = total + 1; fails = fails + ts_check("iface.never_ti", iface_ti_of(AK_NEVER), TI_NEVER);
    total = total + 1; fails = fails + ts_check("iface.char_ti", iface_ti_of(AK_CHAR), TI_CHAR);
    total = total + 1; fails = fails + ts_check("iface.dyn_ti", iface_ti_of(AK_DYN), TI_DYN);
    // 反向：结构/命名条目无「规范行」（类级）→ 恒 -1（若哪天被填成某行 = 类级/行级混同）
    total = total + 1; fails = fails + ts_check("iface.struct_ti_none",
        (iface_ti_of(AK_PRODUCT) == -1 && iface_ti_of(AK_SEQUENCE) == -1 && iface_ti_of(AK_REF) == -1 &&
         iface_ti_of(AK_PTR) == -1 && iface_ti_of(AK_NAMED) == -1), 1);
    // 行号 → 原子类：8 原生经**类型表本体**（kind == TYP_BASE && data == TY_*）判，不按行号猜
    total = total + 1; fails = fails + ts_check("iface.kind_int", iface_kind_of(TI_INT), AK_INT);
    total = total + 1; fails = fails + ts_check("iface.kind_dex", iface_kind_of(TI_DEX), AK_DEX);
    total = total + 1; fails = fails + ts_check("iface.kind_str", iface_kind_of(TI_STR), AK_STRING);
    total = total + 1; fails = fails + ts_check("iface.kind_bool", iface_kind_of(TI_BOOL), AK_BOOL);
    total = total + 1; fails = fails + ts_check("iface.kind_unit", iface_kind_of(TI_UNIT), AK_UNIT);
    total = total + 1; fails = fails + ts_check("iface.kind_never", iface_kind_of(TI_NEVER), AK_NEVER);
    total = total + 1; fails = fails + ts_check("iface.kind_char", iface_kind_of(TI_CHAR), AK_CHAR);
    total = total + 1; fails = fails + ts_check("iface.kind_dyn", iface_kind_of(TI_DYN), AK_DYN);
    total = total + 1; fails = fails + ts_check("iface.kind_oob", iface_kind_of(g_type_count + 7), -1);
    total = total + 1; fails = fails + ts_check("iface.kind_neg", iface_kind_of(-1), -1);
    // 结构/命名行 → 类（逐 kind 一条构造子；配对着写以钉死「非同类混判」）
    ifc_ptr := alloc_type(TYP_PTR, TI_INT, 0);
    ifc_ref := alloc_type(TYP_REF, TI_STR, 0);
    total = total + 1; fails = fails + ts_check("iface.kind_ptr_ref",
        (iface_kind_of(ifc_ptr) == AK_PTR && iface_kind_of(ifc_ref) == AK_REF), 1);
    ifc_arr := alloc_type(TYP_ARRAY, TI_INT, 3);
    ifc_slice := alloc_type(TYP_SLICE, TI_INT, 0);
    total = total + 1; fails = fails + ts_check("iface.kind_seq",
        (iface_kind_of(ifc_arr) == AK_SEQUENCE && iface_kind_of(ifc_slice) == AK_SEQUENCE), 1);
    ifc_tup := alloc_type(TYP_TUPLE, 0, 0);
    total = total + 1; fails = fails + ts_check("iface.kind_product", iface_kind_of(ifc_tup), AK_PRODUCT);
    ifc_named := alloc_named_type(str_intern("IfaceNamedProbe"));
    ifc_gp := alloc_type(TYP_GENERIC_PARAM, str_intern("IfaceGP"), 0);
    ifc_ga := alloc_type(TYP_GENERIC_APPLY, ifc_named, 0);
    total = total + 1; fails = fails + ts_check("iface.kind_named",
        (iface_kind_of(ifc_named) == AK_NAMED && iface_kind_of(ifc_gp) == AK_NAMED &&
         iface_kind_of(ifc_ga) == AK_NAMED), 1);
    // 条目定位（含越界/负键：不得把「无此原子」与行 0 混同）
    total = total + 1; fails = fails + ts_check("iface.entry_lookup",
        (iface_entry(AK_INT) >= 0 && iface_entry(AK_INT) < iface_count() && iface_entry(AK_NAMED) >= 0 &&
         iface_entry(-1) == -1 && iface_entry(9999) == -1), 1);
    // TY_* 码 → 原子类（逐项语义分派；含两条已裁决灰格：DEX_S 同值域不同表示、GENERIC_PARAM 哨兵）
    total = total + 1; fails = fails + ts_check("iface.ty_code_natives",
        (iface_by_ty_code(TY_INT) == AK_INT && iface_by_ty_code(TY_DEX) == AK_DEX &&
         iface_by_ty_code(TY_BOOL) == AK_BOOL && iface_by_ty_code(TY_STRING) == AK_STRING &&
         iface_by_ty_code(TY_UNIT) == AK_UNIT && iface_by_ty_code(TY_NEVER) == AK_NEVER &&
         iface_by_ty_code(TY_CHAR) == AK_CHAR), 1);
    total = total + 1; fails = fails + ts_check("iface.ty_code_gray",
        (iface_by_ty_code(TY_DEX_S) == AK_DEX && iface_by_ty_code(TY_GENERIC_PARAM) == AK_NAMED), 1);
    total = total + 1; fails = fails + ts_check("iface.ty_code_unknown", iface_by_ty_code(999), -1);
    // 字面量定型（查表入口 = 条目 lit_code 列；接线后 = infer_expr 的 5 处唯一真源，
    // 端到端对拍见本文件末段 `lit.infer_*`）
    total = total + 1; fails = fails + ts_check("iface.lit_int", iface_lit_ti(EXPR_INT), TI_INT);
    total = total + 1; fails = fails + ts_check("iface.lit_dex", iface_lit_ti(EXPR_DEX), TI_DEX);
    total = total + 1; fails = fails + ts_check("iface.lit_str", iface_lit_ti(EXPR_STRING), TI_STR);
    total = total + 1; fails = fails + ts_check("iface.lit_bool", iface_lit_ti(EXPR_BOOL), TI_BOOL);
    total = total + 1; fails = fails + ts_check("iface.lit_char", iface_lit_ti(EXPR_CHAR), TI_CHAR);
    total = total + 1; fails = fails + ts_check("iface.lit_none", iface_lit_ti(EXPR_IDENT), -1);
    total = total + 1; fails = fails + ts_check("iface.lit_ak",
        (iface_lit_ak(EXPR_INT) == AK_INT && iface_lit_ak(EXPR_DEX) == AK_DEX &&
         iface_lit_ak(EXPR_STRING) == AK_STRING && iface_lit_ak(EXPR_BOOL) == AK_BOOL &&
         iface_lit_ak(EXPR_CHAR) == AK_CHAR), 1);
    // 负键 = 条目的「无字面量」哨兵 ⇒ 必须先行拒绝（否则 -1 命中无字面量条目）
    total = total + 1; fails = fails + ts_check("iface.lit_neg", iface_lit_ak(-1), -1);
    // 类型项 → 原子类（单一原子 / ⊤ₖ；复合与越界 → -1）
    ifc_term_atom := tt_atom(AK_INT, TI_INT, -1);
    total = total + 1; fails = fails + ts_check("iface.of_term_atom", iface_of_term(ifc_term_atom), AK_INT);
    total = total + 1; fails = fails + ts_check("iface.of_term_topk", iface_of_term(tt_top_k(AK_SEQUENCE)), AK_SEQUENCE);
    total = total + 1; fails = fails + ts_check("iface.of_term_compound", iface_of_term(tt_union(a_int, a_str)), -1);
    total = total + 1; fails = fails + ts_check("iface.of_term_oob",
        (iface_of_term(-1) == -1 && iface_of_term(tt_count() + 9) == -1), 1);
    // 未知原子 → 空许可集（不得给「看起来有许可」的位）；位下标越界 → 0（不得回绕成全位命中）
    total = total + 1; fails = fails + ts_check("iface.ops_unknown", iface_ops(-1), 0);
    total = total + 1; fails = fails + ts_check("iface.ops_unknown_ak", iface_ops(9999), 0);
    total = total + 1; fails = fails + ts_check("iface.permits_bad_op",
        (iface_permits(AK_INT, -1) == 0 && iface_permits(AK_INT, 63) == 0 && iface_permits(9999, OP_ADD) == 0), 1);

    // --- R2 P2b Task 2：`iface_kind_of` 单源化——桥接分派（sh_native_ak/sh_base_ak）与注册表合一 ---
    // 判据 = **全表逐格**（非抽样）：生产入口对**冻结期望表**逐格相同。**R2 P5 Task 4 重定**：
    // 改动前实现的字面拷贝（sh_base_ak_legacy/sh_native_ak_legacy）已随 legacy 面删除 ⇒ 对照物
    // 改为 `ts_t4_ak_expected`/`ts_t4_native_ak_expected`（**本文件的冻结期望**，不再是生产文件里
    // 的第二份实现——单源化的收益自此由数据钉住）。只比「两版相等」会漏两类错——入口被换成
    // 第三个实现、两版一起错 ⇒ 另加③~⑥的**显式**断言（反真空/灰格/门/下标不 1:1）。
    // ① TY 码面：全部 9 个 TY_* 码（含 TY_DEX_S / TY_GENERIC_PARAM 两条已裁决灰格）+ 未映射码
    t2_codes := alloc(10 * 8);
    w64(t2_codes, 0, TY_INT);            w64(t2_codes, 8, TY_DEX);
    w64(t2_codes, 16, TY_BOOL);          w64(t2_codes, 24, TY_STRING);
    w64(t2_codes, 32, TY_UNIT);          w64(t2_codes, 40, TY_NEVER);
    w64(t2_codes, 48, TY_CHAR);          w64(t2_codes, 56, TY_GENERIC_PARAM);
    w64(t2_codes, 64, TY_DEX_S);         w64(t2_codes, 72, 999);
    t2_ty_bad : ., mut = 0;
    t2_i : ., mut = 0;
    loop {
        if t2_i >= 10 { break; }
        t2_code := r64(t2_codes, t2_i * 8);
        if iface_by_ty_code(t2_code) != ts_t4_ak_expected(t2_code) { t2_ty_bad = t2_ty_bad + 1; }
        t2_i = t2_i + 1;
    }
    total = total + 1; fails = fails + ts_check("iface.by_ty_code_all_codes", t2_ty_bad, 0);
    // ② 行号面全表：逐 ti ∈ [0, g_type_count)（含 TI_DYN 行、TI_DEX_S 占位行与上方结构/命名行）
    t2_ti_bad : ., mut = 0;
    t2_j : ., mut = 0;
    loop {
        if t2_j >= g_type_count { break; }
        if sh_native_ak(t2_j) != ts_t4_native_ak_expected(t2_j) { t2_ti_bad = t2_ti_bad + 1; }
        t2_j = t2_j + 1;
    }
    total = total + 1; fails = fails + ts_check("iface.native_ak_all_rows", t2_ti_bad, 0);
    // ③ **反真空哨兵**（两处 loop 是本 Task 的判据本体，不得空转假绿）：
    //    ⓐ 扫描计数：码面 10 个键全扫过（且解码真读回写入值）；行面恰为 g_type_count 行且 ≥ 9；
    //    ⓑ 比较是活的：两个**已知互补**的格必须给出**不同**结果（未映射码 → -1 而 TY_INT → AK_INT）。
    total = total + 1; fails = fails + ts_check("iface.scan_coverage",
        (t2_i == 10 && r64(t2_codes, 56) == TY_GENERIC_PARAM && r64(t2_codes, 64) == TY_DEX_S &&
         t2_j == g_type_count && t2_j >= 9), 1);
    total = total + 1; fails = fails + ts_check("iface.compare_is_live",
        (iface_by_ty_code(999) == ts_t4_ak_expected(TY_INT)), 0);
    // ④ 生产入口**确实在委托**（逐项钉死；含两条灰格与未映射码）
    total = total + 1; fails = fails + ts_check("iface.bridge_delegates",
        (sh_base_ak(TY_INT) == AK_INT && sh_base_ak(TY_STRING) == AK_STRING && sh_base_ak(TY_BOOL) == AK_BOOL &&
         sh_base_ak(TY_DEX_S) == AK_DEX && sh_base_ak(TY_GENERIC_PARAM) == AK_NAMED && sh_base_ak(999) == -1 &&
         sh_native_ak(TI_INT) == AK_INT && sh_native_ak(TI_STR) == AK_STRING), 1);
    // ⑤ **原门保留**（委托不得把 sh_native_ak 变成 iface_kind_of）：DYN 行/结构行/负号 → -1，
    // 而同时注册表侧对 DYN 行回 AK_DYN——两函数契约不同，各自钉一条。
    total = total + 1; fails = fails + ts_check("iface.bridge_gate_kept",
        (sh_native_ak(TI_DYN) == -1 && sh_native_ak(ifc_arr) == -1 && sh_native_ak(ifc_named) == -1 &&
         sh_native_ak(-1) == -1 && iface_kind_of(TI_DYN) == AK_DYN), 1);
    // ⑥ 语义分派守卫（P1 血泪：AK/TI 下标不 1:1）——若哪天有人「按下标直传」，本行必红
    total = total + 1; fails = fails + ts_check("iface.dispatch_no_index_shortcut",
        (iface_ti_of(AK_STRING) != AK_STRING && iface_ti_of(AK_BOOL) != AK_BOOL && TI_STR != TI_BOOL), 1);

    // --- R2 P2b Task 3：字面量定型查表接线（infer_expr 的 5 个字面量分支 → iface_lit_ti）---
    // 判据 = **接线端到端**：用与 parser 同族的 `alloc_node` 构造 5 个字面量 AST 节点，逐 kind 比
    // `infer_expr(节点)` 与改动前的字面常量（= 内联 if 链 `checker.cr:1896-1901` 的逐格转录）。
    // 为什么不能只看表侧（`iface.lit_*`）：表对而**线错**（接线点写错键，如 EXPR_INT 行调
    // `iface_lit_ti(EXPR_DEX)`）在表侧用例下**全绿**——只有经 infer_expr 真跑才暴露。
    // 本段为**本 Task 的判据本体**，其非真空性由实施报告记录的**突变控制**（翻转表格 ⇒ 本段
    // `lit.infer_int` 必红 ⇒ 复位）实证，非仅「跑过一遍」。
    li_int := alloc_node(EXPR_INT, -1, -1, -1, 42, TY_INT, -1, 0, 0);
    li_dex := alloc_node(EXPR_DEX, -1, -1, -1, 314, TY_DEX, -1, 0, 0);
    li_str := alloc_node(EXPR_STRING, -1, -1, -1, str_intern("iface_lit_probe"), TY_STRING, -1, 0, 0);
    li_bool := alloc_node(EXPR_BOOL, -1, -1, -1, 1, TY_BOOL, -1, 0, 0);
    li_char := alloc_node(EXPR_CHAR, -1, -1, -1, 65, TY_CHAR, -1, 0, 0);
    // 反真空哨兵：构造出的节点确实带预期 kind（防 alloc_node 参数错位 ⇒ 「拿错节点比错值」假绿）
    total = total + 1; fails = fails + ts_check("lit.node_kinds",
        (ast_kind(li_int) == EXPR_INT && ast_kind(li_dex) == EXPR_DEX && ast_kind(li_str) == EXPR_STRING &&
         ast_kind(li_bool) == EXPR_BOOL && ast_kind(li_char) == EXPR_CHAR), 1);
    total = total + 1; fails = fails + ts_check("lit.infer_int", infer_expr(li_int), TI_INT);
    total = total + 1; fails = fails + ts_check("lit.infer_dex", infer_expr(li_dex), TI_DEX);
    total = total + 1; fails = fails + ts_check("lit.infer_str", infer_expr(li_str), TI_STR);
    total = total + 1; fails = fails + ts_check("lit.infer_bool", infer_expr(li_bool), TI_BOOL);
    total = total + 1; fails = fails + ts_check("lit.infer_char", infer_expr(li_char), TI_CHAR);
    // 端到端 ↔ 表 对拍：接线后 infer_expr 的结果必须**逐 kind 等于表查表结果**（表 = 唯一真源；
    // 若哪天有人把某行改回硬编码常量，本行仍绿但 `lit.infer_*` 亦绿——真正的守门是实施报告的
    // 突变控制：改表格 ⇒ infer_* 红 ⇒ 该行确在读表）
    total = total + 1; fails = fails + ts_check("lit.infer_is_table",
        (infer_expr(li_int) == iface_lit_ti(EXPR_INT) && infer_expr(li_dex) == iface_lit_ti(EXPR_DEX) &&
         infer_expr(li_str) == iface_lit_ti(EXPR_STRING) && infer_expr(li_bool) == iface_lit_ti(EXPR_BOOL) &&
         infer_expr(li_char) == iface_lit_ti(EXPR_CHAR)), 1);
    // 短路顺序（接线硬口径：**逐字保持**）——EXPR_NONE 转发行夹在 EXPR_INT 与 EXPR_DEX 之间：
    // ① 带内层值的 wrapper：在 EXPR_INT 行不命中（kind=0）⇒ 走转发行 → 内层类型；
    // ② 空 wrapper（a = -1）：转发行不命中 ⇒ 落函数中部的 EXPR_NONE 分支 → TI_UNIT。
    li_wrap := alloc_node(EXPR_NONE, li_int, -1, -1, 0, 0, -1, 0, 0);
    li_wrap_empty := alloc_node(EXPR_NONE, -1, -1, -1, 0, 0, -1, 0, 0);
    total = total + 1; fails = fails + ts_check("lit.none_forwards", infer_expr(li_wrap), TI_INT);
    total = total + 1; fails = fails + ts_check("lit.none_empty_unit", infer_expr(li_wrap_empty), TI_UNIT);
    // 负节点先行拒绝（infer_expr 头行；接线不得把它挤掉）
    total = total + 1; fails = fails + ts_check("lit.neg_node_unit", infer_expr(-1), TI_UNIT);

    // --- R2 P2b Task 4：操作许可位集接线（ops 列逐格；消费者 = checker.cr 的三个门）---
    // 判据口径 = **与改动前的判定一字等价**（逐格全表对拍，非抽样）：把「改动前的谓词」内联进
    // 本段，逐 ak × 逐 op 与 `iface_permits` 对拍。三组关键等价（改动前原文 = checker.cr 算术门
    // :1959 / 逻辑门 :1969 / 条件门 :2274 + :2385）：
    //   ① ADD..MOD 许可 ⟺ ak ∈ {AK_INT, AK_DEX}（门**只含 int/dex**；PTR/STRING 不在内 ⇒
    //      `*T + *T`/`"a" - "b"` 仍 error[TB01]）
    //   ② OP_AND/OP_OR 许可 ⟺ ak ∈ {AK_INT, AK_BOOL}（dex 拒——`1.5 && true` 现状 TC01）
    //   ③ IP_COND ⟺ ak ∈ {AK_INT, AK_BOOL}；IP_COND_BOOL ⟺ ak == AK_BOOL（`while 1` 现状 TC04）
    // 反真空：另立「许可为 1 的格数」哨兵（全 0 表 ⇒ 计数 0 必红）+ 条目面一致性 + 端到端段。
    o4_aks := alloc(13 * 8);   // 13 类枚举（顺序 = 条目表声明序）
    w64(o4_aks, 0, AK_INT);      w64(o4_aks, 8, AK_DEX);      w64(o4_aks, 16, AK_STRING);
    w64(o4_aks, 24, AK_BOOL);    w64(o4_aks, 32, AK_UNIT);    w64(o4_aks, 40, AK_NEVER);
    w64(o4_aks, 48, AK_CHAR);    w64(o4_aks, 56, AK_DYN);     w64(o4_aks, 64, AK_PRODUCT);
    w64(o4_aks, 72, AK_SEQUENCE); w64(o4_aks, 80, AK_REF);    w64(o4_aks, 88, AK_PTR);
    w64(o4_aks, 96, AK_NAMED);
    o4_ops := alloc(5 * 8);    // 算术族 5 op（门消费面：OP_ADD..OP_MOD）
    w64(o4_ops, 0, OP_ADD);      w64(o4_ops, 8, OP_SUB);      w64(o4_ops, 16, OP_MUL);
    w64(o4_ops, 24, OP_DIV);     w64(o4_ops, 32, OP_MOD);
    // ① 算术门：逐 ak × 逐 op 对拍「许可 ⟺ int|dex」
    o4_arith_bad : ., mut = 0;
    o4_arith_yes : ., mut = 0;
    o4_i : ., mut = 0;
    loop {
        if o4_i >= 13 { break; }
        o4_ak := r64(o4_aks, o4_i * 8);
        o4_j : ., mut = 0;
        loop {
            if o4_j >= 5 { break; }
            o4_op := r64(o4_ops, o4_j * 8);
            o4_want : ., mut = 0;
            if o4_ak == AK_INT || o4_ak == AK_DEX { o4_want = 1; }
            if iface_permits(o4_ak, o4_op) != o4_want { o4_arith_bad = o4_arith_bad + 1; }
            if iface_permits(o4_ak, o4_op) == 1 { o4_arith_yes = o4_arith_yes + 1; }
            o4_j = o4_j + 1;
        }
        o4_i = o4_i + 1;
    }
    total = total + 1; fails = fails + ts_check("ops.arith_gate_eq_legacy", o4_arith_bad, 0);
    total = total + 1; fails = fails + ts_check("ops.arith_permit_count", o4_arith_yes, 10);  // = 2 ak × 5 op
    // ② 逻辑族：逐 ak × 逐 op（OP_AND/OP_OR）对拍「许可 ⟺ int|bool」——谓词取 OP_AND（不另设 IP_LOGIC）
    o4_logic_bad : ., mut = 0;
    o4_logic_yes : ., mut = 0;
    o4_k : ., mut = 0;
    loop {
        if o4_k >= 13 { break; }
        o4_ak2 := r64(o4_aks, o4_k * 8);
        o4_want2 : ., mut = 0;
        if o4_ak2 == AK_INT || o4_ak2 == AK_BOOL { o4_want2 = 1; }
        if iface_permits(o4_ak2, OP_AND) != o4_want2 { o4_logic_bad = o4_logic_bad + 1; }
        if iface_permits(o4_ak2, OP_OR) != o4_want2 { o4_logic_bad = o4_logic_bad + 1; }
        if iface_permits(o4_ak2, OP_AND) == 1 { o4_logic_yes = o4_logic_yes + 1; }
        o4_k = o4_k + 1;
    }
    total = total + 1; fails = fails + ts_check("ops.logic_gate_eq_legacy", o4_logic_bad, 0);
    total = total + 1; fails = fails + ts_check("ops.logic_permit_count", o4_logic_yes, 2);  // int + bool
    // ③ 条件族：IP_COND = {int, bool}；IP_COND_BOOL = {bool}（**两条规则现状不同，不得合并**）
    o4_cond_bad : ., mut = 0;
    o4_cond_yes : ., mut = 0;
    o4_condb_yes : ., mut = 0;
    o4_m : ., mut = 0;
    loop {
        if o4_m >= 13 { break; }
        o4_ak3 := r64(o4_aks, o4_m * 8);
        o4_want3 : ., mut = 0;
        if o4_ak3 == AK_INT || o4_ak3 == AK_BOOL { o4_want3 = 1; }
        o4_want4 : ., mut = 0;
        if o4_ak3 == AK_BOOL { o4_want4 = 1; }
        if iface_permits(o4_ak3, IP_COND) != o4_want3 { o4_cond_bad = o4_cond_bad + 1; }
        if iface_permits(o4_ak3, IP_COND_BOOL) != o4_want4 { o4_cond_bad = o4_cond_bad + 1; }
        if iface_permits(o4_ak3, IP_COND) == 1 { o4_cond_yes = o4_cond_yes + 1; }
        if iface_permits(o4_ak3, IP_COND_BOOL) == 1 { o4_condb_yes = o4_condb_yes + 1; }
        o4_m = o4_m + 1;
    }
    total = total + 1; fails = fails + ts_check("ops.cond_gate_eq_legacy", o4_cond_bad, 0);
    total = total + 1; fails = fails + ts_check("ops.cond_permit_count", o4_cond_yes * 10 + o4_condb_yes, 21);  // 2 与 1
    // ④ 全许可面（现状**无拒绝路径** ⇒ 本批不接线、只登记为 P3 旋钮）：比较 6 op / 一元 4 op / AS
    //    对全部 13 类置 1——逐格对拍（计数 = 13 × 11 = 143）
    o4_all_bad : ., mut = 0;
    o4_all_yes : ., mut = 0;
    o4_n : ., mut = 0;
    loop {
        if o4_n >= 13 { break; }
        o4_ak4 := r64(o4_aks, o4_n * 8);
        o4_n2 : ., mut = 0;
        loop {
            if o4_n2 >= 6 { break; }
            o4_cop := OP_EQ + o4_n2;                     // OP_EQ..OP_GE 连续取值（6..11）
            if iface_permits(o4_ak4, o4_cop) != 1 { o4_all_bad = o4_all_bad + 1; }
            if iface_permits(o4_ak4, o4_cop) == 1 { o4_all_yes = o4_all_yes + 1; }
            o4_n2 = o4_n2 + 1;
        }
        o4_n3 : ., mut = 0;
        loop {
            if o4_n3 >= 4 { break; }
            o4_uop := IP_UOP_BIAS + 1 + o4_n3;           // UOP_NEG..UOP_DEREF → 21..24
            if iface_permits(o4_ak4, o4_uop) != 1 { o4_all_bad = o4_all_bad + 1; }
            if iface_permits(o4_ak4, o4_uop) == 1 { o4_all_yes = o4_all_yes + 1; }
            o4_n3 = o4_n3 + 1;
        }
        if iface_permits(o4_ak4, IP_AS) != 1 { o4_all_bad = o4_all_bad + 1; }
        if iface_permits(o4_ak4, IP_AS) == 1 { o4_all_yes = o4_all_yes + 1; }
        o4_n = o4_n + 1;
    }
    total = total + 1; fails = fails + ts_check("ops.all_permit_eq_legacy", o4_all_bad, 0);
    total = total + 1; fails = fails + ts_check("ops.all_permit_count", o4_all_yes, 143);  // 13 × 11
    // ⑤ 容器/方法面（Task 5 的消费格；本批登记）：索引/字段/方法各恰两类
    total = total + 1; fails = fails + ts_check("ops.index_permit_set",
        (iface_permits(AK_SEQUENCE, IP_INDEX) == 1 && iface_permits(AK_STRING, IP_INDEX) == 1 &&
         iface_permits(AK_INT, IP_INDEX) == 0 && iface_permits(AK_REF, IP_INDEX) == 0 &&
         iface_permits(AK_SEQUENCE, IP_INDEX_RANGE) == 1 && iface_permits(AK_STRING, IP_INDEX_RANGE) == 0), 1);
    total = total + 1; fails = fails + ts_check("ops.field_permit_set",
        (iface_permits(AK_NAMED, IP_FIELD) == 1 && iface_permits(AK_PRODUCT, IP_FIELD) == 1 &&
         iface_permits(AK_INT, IP_FIELD) == 0 && iface_permits(AK_SEQUENCE, IP_FIELD) == 0), 1);
    total = total + 1; fails = fails + ts_check("ops.method_permit_set",
        (iface_permits(AK_DYN, IP_METHOD) == 1 && iface_permits(AK_NAMED, IP_METHOD) == 1 &&
         iface_permits(AK_INT, IP_METHOD) == 0 && iface_permits(AK_PTR, IP_METHOD) == 0), 1);
    // ⑥ 条目面一致性（逐条目：`iface_ops(ak)` 必须回读该行的 ops 列；防「列未填/查错行」）。
    // R2 P4 Task 3 重定：扩列三行（AK_NULL/AK_SUM/AK_FN）= **纯信息面**（ops = 0 是设计值，
    // 非「空集残留」）⇒ 零 ops 行 = **恰三行且逐名可指**（允许集显式列举，其余行仍须非 0
    // ——T1..T2 口径保持）。
    o4_row_bad : ., mut = 0;
    o4_zero : ., mut = 0;
    o4_r : ., mut = 0;
    loop {
        if o4_r >= g_iface_entry_count { break; }
        o4_akr := r64(g_iface_entries, o4_r * ESZ_IFACE_ENTRY + OFF_IE_AK);
        if iface_ops(o4_akr) != r64(g_iface_entries, o4_r * ESZ_IFACE_ENTRY + OFF_IE_OPS) { o4_row_bad = o4_row_bad + 1; }
        if iface_ops(o4_akr) == 0 {
            if o4_akr == AK_NULL || o4_akr == AK_SUM || o4_akr == AK_FN { o4_zero = o4_zero + 1; }
            else { o4_row_bad = o4_row_bad + 1; }
        }
        o4_r = o4_r + 1;
    }
    total = total + 1; fails = fails + ts_check("ops.entry_row_consistent",
        (o4_row_bad == 0 && o4_zero == 3), 1);
    // ⑦ 端到端（经真 infer_expr 走三个门；**行为证据**——表侧用例证明不了「线对」）：
    //    ptr 操作数 = `&int 字面量` 的构造节点（EXPR_UNARY/UOP_REF，非 ident 分支 ⇒ 不触借用检查）
    o4_ref := alloc_node(EXPR_UNARY, li_int, -1, UOP_REF, 0, 0, -1, 0, 0);
    o4_ref2 := alloc_node(EXPR_UNARY, li_int, -1, UOP_REF, 0, 0, -1, 0, 0);
    o4_b_add_int := alloc_node(EXPR_BINARY, li_int, li_int, OP_ADD, 0, 0, -1, 0, 0);
    o4_b_sub_str := alloc_node(EXPR_BINARY, li_str, li_str, OP_SUB, 0, 0, -1, 0, 0);
    o4_b_add_str := alloc_node(EXPR_BINARY, li_str, li_str, OP_ADD, 0, 0, -1, 0, 0);
    o4_b_ptrptr := alloc_node(EXPR_BINARY, o4_ref, o4_ref2, OP_ADD, 0, 0, -1, 0, 0);
    o4_b_ptrdiff := alloc_node(EXPR_BINARY, o4_ref, o4_ref2, OP_SUB, 0, 0, -1, 0, 0);
    o4_b_ptradd := alloc_node(EXPR_BINARY, o4_ref, li_int, OP_ADD, 0, 0, -1, 0, 0);
    o4_b_dex := alloc_node(EXPR_BINARY, li_dex, li_int, OP_ADD, 0, 0, -1, 0, 0);
    o4_b_logic := alloc_node(EXPR_BINARY, li_bool, li_int, OP_AND, 0, 0, -1, 0, 0);
    o4_b_logic_bad := alloc_node(EXPR_BINARY, li_dex, li_bool, OP_AND, 0, 0, -1, 0, 0);
    o4_b_eq := alloc_node(EXPR_BINARY, li_str, li_int, OP_EQ, 0, 0, -1, 0, 0);
    // 反真空哨兵：构造节点确实带预期 kind/op（防 alloc_node 参数错位 ⇒ 假绿）
    total = total + 1; fails = fails + ts_check("ops.node_kinds",
        (ast_kind(o4_b_add_int) == EXPR_BINARY && ast_c(o4_b_add_int) == OP_ADD &&
         ast_kind(o4_ref) == EXPR_UNARY && ast_c(o4_ref) == UOP_REF), 1);
    // 正控：int 算术 / 串拼接（早退规则）/ 指针算术 + int / dex 支配 / 逻辑 int 侧 / 比较不校验
    o4_m0 := g_diag_count;
    o4_r_add := infer_expr(o4_b_add_int);
    total = total + 1; fails = fails + ts_check("ops.infer_add_int",
        o4_r_add * 100 + (g_diag_count - o4_m0), TI_INT * 100);
    o4_m1 := g_diag_count;
    o4_r_cat := infer_expr(o4_b_add_str);
    total = total + 1; fails = fails + ts_check("ops.infer_add_str_concat",
        o4_r_cat * 100 + (g_diag_count - o4_m1), TI_STR * 100);
    o4_m2 := g_diag_count;
    o4_r_pa := infer_expr(o4_b_ptradd);
    // 结果 = `*T` 行本身（T = int）：**不**与另一次 `infer_expr(o4_ref)` 的行号比——alloc_type
    // 是裸分配器（不去重，每次调用追加新行）⇒ 两次推断的行号必然不同（比行号 = 永久红）。
    o4_pa_ok : ., mut = 0;
    if get_type_kind(o4_r_pa) == TYP_PTR && get_type_data(o4_r_pa) == TI_INT {
        if g_diag_count - o4_m2 == 0 { o4_pa_ok = 1; }
    }
    total = total + 1; fails = fails + ts_check("ops.infer_ptr_add_int", o4_pa_ok, 1);
    o4_m3 := g_diag_count;
    o4_r_dx := infer_expr(o4_b_dex);
    total = total + 1; fails = fails + ts_check("ops.infer_dex_add",
        o4_r_dx * 100 + (g_diag_count - o4_m3), TI_DEX * 100);
    o4_m4 := g_diag_count;
    o4_r_lg := infer_expr(o4_b_logic);
    total = total + 1; fails = fails + ts_check("ops.infer_logic_int_ok",
        o4_r_lg * 100 + (g_diag_count - o4_m4), TI_BOOL * 100);
    o4_m5 := g_diag_count;
    o4_r_eq := infer_expr(o4_b_eq);
    total = total + 1; fails = fails + ts_check("ops.infer_cmp_unchecked",
        o4_r_eq * 100 + (g_diag_count - o4_m5), TI_BOOL * 100);   // 现状宽松面：比较不校验（登记）
    // 负控（**本批最易放宽的三条**）：string 算术 / ptr+ptr / dex 逻辑 → 必须仍报错（码不变）
    o4_m6 := g_diag_count;
    o4_r_bad1 := infer_expr(o4_b_sub_str);
    total = total + 1; fails = fails + ts_check("ops.infer_sub_str_diag", g_diag_count - o4_m6, 1);
    total = total + 1; fails = fails + ts_check("ops.infer_sub_str_code", ts_diag_code_at(o4_m6), EC_TB_ADD);
    total = total + 1; fails = fails + ts_check("ops.infer_sub_str_result", o4_r_bad1, TI_INT);
    o4_m7 := g_diag_count;
    o4_r_bad2 := infer_expr(o4_b_ptrptr);
    total = total + 1; fails = fails + ts_check("ops.infer_ptr_add_ptr_diag", g_diag_count - o4_m7, 1);
    total = total + 1; fails = fails + ts_check("ops.infer_ptr_add_ptr_code", ts_diag_code_at(o4_m7), EC_TB_ADD);
    total = total + 1; fails = fails + ts_check("ops.infer_ptr_add_ptr_result", o4_r_bad2, TI_INT);
    o4_m8 := g_diag_count;
    o4_r_bad3 := infer_expr(o4_b_logic_bad);
    total = total + 1; fails = fails + ts_check("ops.infer_logic_dex_diag", g_diag_count - o4_m8, 1);
    total = total + 1; fails = fails + ts_check("ops.infer_logic_dex_code", ts_diag_code_at(o4_m8), EC_TC_IF_COND);
    // 早退规则保留（结果规则）：指针差 = `*T - *T` → int（不经门、不报错）
    o4_m9 := g_diag_count;
    o4_r_pd := infer_expr(o4_b_ptrdiff);
    total = total + 1; fails = fails + ts_check("ops.infer_ptr_diff",
        o4_r_pd * 100 + (g_diag_count - o4_m9), TI_INT * 100);

    // --- R2 P2b Task 5：容器面接线（**唯一接线点** = 索引兜底拒绝 → IP_INDEX 查表）---
    // 三层判据：
    //   ① **集等价**（保语义硬口径，全类型行枚举非抽样）：门的可达集 =「kind ∉ {ARRAY, SLICE} ∧
    //      ti ≠ TI_STR」= 结果分支后的落空集；表的拒绝集与之**逐行相等**（`permits == 1 ⟺ 可达
    //      集外`，双向都数）⇒ 接线不改变任何一行的判定。**这是本 Task 接线等价性的本体证据**；
    //      非真空性由实施报告的突变控制承担（给 AK_INT 加 IP_INDEX ⇒ 本例必红）。
    //   ② **端到端经真 infer_expr**（三个结果分支保留 + 兜底门在判）：诊断增量 + 码 + 结果类型。
    //   ③ 反真空哨兵：枚举覆盖行类直方图非退化 + 构造节点 kind/op 正确。
    // 覆盖行类自备（不依赖前序段落的残余行）：PTR/REF/TUPLE 各一行，供 ③ 的直方图计数
    ix_row_ptr := alloc_type(TYP_PTR, TI_INT, 0);
    ix_row_ref := alloc_type(TYP_REF, TI_INT, 0);
    ix_row_tup := alloc_type(TYP_TUPLE, 0, 0);
    ix_li0 := alloc_node(EXPR_INT, -1, -1, -1, 0, TY_INT, -1, 0, 0);   // 索引值 0（串下标须在界内，避免 F 面诊断）
    ix_arr3 := alloc_node(EXPR_ARRAY, -1, 3, -1, 0, 0, -1, 0, 0);   // 数组字面量 len=3（无元素）
    ix_arr0 := alloc_node(EXPR_ARRAY, -1, 0, -1, 0, 0, -1, 0, 0);   // 空数组字面量 len=0
    ix_idx_arr := alloc_node(EXPR_INDEX, ix_arr0, li_int, -1, 0, 0, -1, 0, 0);
    ix_idx_str := alloc_node(EXPR_INDEX, li_str, ix_li0, -1, 0, 0, -1, 0, 0);
    ix_idx_int := alloc_node(EXPR_INDEX, li_int, li_int, -1, 0, 0, -1, 0, 0);
    ix_idx_bool := alloc_node(EXPR_INDEX, li_bool, li_int, -1, 0, 0, -1, 0, 0);
    ix_ref := alloc_node(EXPR_UNARY, li_int, -1, UOP_REF, 0, 0, -1, 0, 0);
    ix_idx_ptr := alloc_node(EXPR_INDEX, ix_ref, li_int, -1, 0, 0, -1, 0, 0);
    ix_range := alloc_node(EXPR_RANGE, li_int, li_int, -1, 0, 0, -1, 0, 0);
    ix_idx_arr_range := alloc_node(EXPR_INDEX, ix_arr0, ix_range, -1, 0, 0, -1, 0, 0);
    ix_idx_str_range := alloc_node(EXPR_INDEX, li_str, ix_range, -1, 0, 0, -1, 0, 0);
    ix_idx_arr_oob := alloc_node(EXPR_INDEX, ix_arr3, li_int, -1, 0, 0, -1, 0, 0);
    ix_idx_range_oob := alloc_node(EXPR_INDEX, ix_arr3, ix_range, -1, 0, 0, -1, 0, 0);
    total = total + 1; fails = fails + ts_check("idx.node_kinds",
        (ast_kind(ix_idx_arr) == EXPR_INDEX && ast_kind(ix_arr3) == EXPR_ARRAY && ast_b(ix_idx_arr) == li_int &&
         ast_kind(ix_range) == EXPR_RANGE && ast_kind(ix_idx_ptr) == EXPR_INDEX && ast_c(ix_ref) == UOP_REF), 1);
    // ① 集等价（逐行）：perm == 1 ⟺ 该行**不**属于「结果分支已处理集」{kind ARRAY, kind SLICE, ti == TI_STR}
    ix_bad : ., mut = 0;
    ix_n_rows : ., mut = 0;
    ix_n_seq : ., mut = 0;
    ix_n_str : ., mut = 0;
    ix_n_named : ., mut = 0;
    ix_n_prod : ., mut = 0;
    ix_n_ref : ., mut = 0;
    ix_n_ptr : ., mut = 0;
    ix_n_dyn : ., mut = 0;
    ix_i : ., mut = 0;
    loop {
        if ix_i >= g_type_count { break; }
        ix_k := get_type_kind(ix_i);
        ix_ak := iface_kind_of(ix_i);
        ix_reach : ., mut = 1;   // 1 = 到达兜底门（结果分支都不命中）
        if ix_k == TYP_ARRAY || ix_k == TYP_SLICE || ix_i == TI_STR { ix_reach = 0; }
        ix_perm := iface_permits(ix_ak, IP_INDEX);
        ix_want : ., mut = 1;
        if ix_reach == 1 { ix_want = 0; }
        if ix_perm != ix_want { ix_bad = ix_bad + 1; }
        if ix_k == TYP_ARRAY || ix_k == TYP_SLICE { ix_n_seq = ix_n_seq + 1; }
        if ix_i == TI_STR { ix_n_str = ix_n_str + 1; }
        if ix_ak == AK_NAMED { ix_n_named = ix_n_named + 1; }
        if ix_ak == AK_PRODUCT { ix_n_prod = ix_n_prod + 1; }
        if ix_ak == AK_REF { ix_n_ref = ix_n_ref + 1; }
        if ix_ak == AK_PTR { ix_n_ptr = ix_n_ptr + 1; }
        if ix_ak == AK_DYN { ix_n_dyn = ix_n_dyn + 1; }
        ix_n_rows = ix_n_rows + 1;
        ix_i = ix_i + 1;
    }
    total = total + 1; fails = fails + ts_check("idx.gate_deny_covers_fallback", ix_bad, 0);
    // ③ 反真空：扫满全表 + 每类至少一行 + **STR 行恰 1 行**（`ti == TI_STR` ⇔ AK_STRING 的等价性
    //    依赖「TYP_BASE 行唯一分配点 = init_types」——该行数若变，本例先红）
    total = total + 1; fails = fails + ts_check("idx.scan_coverage",
        (ix_n_rows == g_type_count && ix_n_rows >= 15 && ix_n_seq >= 2 && ix_n_str == 1 &&
         ix_n_named >= 1 && ix_n_prod >= 1 && ix_n_ref >= 1 && ix_n_ptr >= 1 && ix_n_dyn >= 1 &&
         get_type_kind(ix_row_ptr) == TYP_PTR && get_type_kind(ix_row_ref) == TYP_REF &&
         get_type_kind(ix_row_tup) == TYP_TUPLE), 1);
    // ② 端到端：结果分支保留（数组 → int、串 → int；含 OOB/F11 两个既有诊断仍发）
    ix_m0 := g_diag_count;
    ix_r_arr := infer_expr(ix_idx_arr);
    total = total + 1; fails = fails + ts_check("idx.infer_arr_ok", ix_r_arr * 100 + (g_diag_count - ix_m0), TI_INT * 100);
    ix_m1 := g_diag_count;
    ix_r_str := infer_expr(ix_idx_str);
    total = total + 1; fails = fails + ts_check("idx.infer_str_ok", ix_r_str * 100 + (g_diag_count - ix_m1), TI_INT * 100);
    ix_m2 := g_diag_count;
    ix_r_asc := infer_expr(ix_idx_arr_range);
    ix_asc_ok : ., mut = 0;
    if get_type_kind(ix_r_asc) == TYP_SLICE && get_type_data(ix_r_asc) == TI_INT {
        if g_diag_count - ix_m2 == 0 { ix_asc_ok = 1; }
    }
    total = total + 1; fails = fails + ts_check("idx.infer_range_slice", ix_asc_ok, 1);
    // 兜底门在判：非容器行 → TK01（码/结果逐字不变）
    ix_m3 := g_diag_count;
    ix_r_int := infer_expr(ix_idx_int);
    total = total + 1; fails = fails + ts_check("idx.infer_int_denied_diag", g_diag_count - ix_m3, 1);
    total = total + 1; fails = fails + ts_check("idx.infer_int_denied_code", ts_diag_code_at(ix_m3), EC_TK_INDEX);
    total = total + 1; fails = fails + ts_check("idx.infer_int_denied_result", ix_r_int, TI_INT);
    ix_m4 := g_diag_count;
    infer_expr(ix_idx_bool);
    total = total + 1; fails = fails + ts_check("idx.infer_bool_denied_diag", g_diag_count - ix_m4, 1);
    total = total + 1; fails = fails + ts_check("idx.infer_bool_denied_code", ts_diag_code_at(ix_m4), EC_TK_INDEX);
    ix_m5 := g_diag_count;
    infer_expr(ix_idx_ptr);
    total = total + 1; fails = fails + ts_check("idx.infer_ptr_denied_diag", g_diag_count - ix_m5, 1);
    total = total + 1; fails = fails + ts_check("idx.infer_ptr_denied_code", ts_diag_code_at(ix_m5), EC_TK_INDEX);
    // 登记面（现状宽松，本 Task 断言「不动」）：串 range 索引静默 → unit（range 分支的非数组落空）
    ix_m6 := g_diag_count;
    ix_r_sr := infer_expr(ix_idx_str_range);
    total = total + 1; fails = fails + ts_check("idx.infer_str_range_unit", ix_r_sr * 100 + (g_diag_count - ix_m6), TI_UNIT * 100);
    // 结果规则原地保留的**正证据**（防「接线把分支合并掉」）：F2 越界 + F11 切片界仍发
    ix_m7 := g_diag_count;
    infer_expr(ix_idx_arr_oob);
    total = total + 1; fails = fails + ts_check("idx.infer_arr_oob_diag", g_diag_count - ix_m7, 1);
    total = total + 1; fails = fails + ts_check("idx.infer_arr_oob_code", ts_diag_code_at(ix_m7), EC_R_OOB);
    ix_m8 := g_diag_count;
    infer_expr(ix_idx_range_oob);
    total = total + 1; fails = fails + ts_check("idx.infer_range_oob_diag", g_diag_count - ix_m8, 1);
    total = total + 1; fails = fails + ts_check("idx.infer_range_oob_code", ts_diag_code_at(ix_m8), EC_TK_SLICE_BOUNDS);

    // --- R2 P2b Task 6：`res_type_node`/`res_call_type` 双份 TY→TI 映射合一（单表 ty_code_to_ti）---
    // 三层判据：
    //   ① 表侧逐码（含**表内不兜底**：TY_DEX_S/未知/负码 → -1）；
    //   ② 两处基型分支**端到端**（`alloc_node(0,…,tv)` 构造基型节点 → 经真 res_type_node/res_call_type
    //      比返回，= 改动前 inline 链的逐格转录）；
    //   ③ 反真空哨兵（构造节点 kind/tv 回读正确；负节点先行拒绝）＋ **两表唯一差异格** NEVER 的双向断言
    //      （A → TI_NEVER、B → TI_UNIT——探针实测该格在调用位点**可达**，差异显式保留不静默合一）。
    // 非真空性（表变 ⇒ ②段必变）由实施报告的突变控制承担：表侧用例只能证明表对，证明不了线对。
    total = total + 1; fails = fails + ts_check("t6.ty_code_head",
        (ty_code_to_ti(TY_INT) == TI_INT && ty_code_to_ti(TY_DEX) == TI_DEX &&
         ty_code_to_ti(TY_BOOL) == TI_BOOL && ty_code_to_ti(TY_STRING) == TI_STR &&
         ty_code_to_ti(TY_UNIT) == TI_UNIT), 1);
    total = total + 1; fails = fails + ts_check("t6.ty_code_tail",
        (ty_code_to_ti(TY_NEVER) == TI_NEVER && ty_code_to_ti(TY_CHAR) == TI_CHAR), 1);
    // 码 7 = TY_GENERIC_PARAM 与 TI_DYN 的数值撞车格（spec §2.4 现场）：现状两表原文原样保留
    total = total + 1; fails = fails + ts_check("t6.ty_code_dyn7",
        (ty_code_to_ti(TI_DYN) == TI_DYN && ty_code_to_ti(TY_GENERIC_PARAM) == TI_DYN), 1);
    // **表内不兜底**：TY_DEX_S(8) 不入表（计划注「不属两表并集」）+ 未知/负码 → -1
    total = total + 1; fails = fails + ts_check("t6.ty_code_domain",
        (ty_code_to_ti(TY_DEX_S) == -1 && ty_code_to_ti(-1) == -1 && ty_code_to_ti(999) == -1), 1);
    // ② 端到端：基型节点逐码（含 7 = dyn 码位——parser.cr:98 对 `dyn` 类型名正产此码）
    t6_int := alloc_node(0, 0, 0, 0, 0, TY_INT, 0, 0, 0);
    t6_dex := alloc_node(0, 0, 0, 0, 0, TY_DEX, 0, 0, 0);
    t6_bool := alloc_node(0, 0, 0, 0, 0, TY_BOOL, 0, 0, 0);
    t6_str := alloc_node(0, 0, 0, 0, 0, TY_STRING, 0, 0, 0);
    t6_unit := alloc_node(0, 0, 0, 0, 0, TY_UNIT, 0, 0, 0);
    t6_never := alloc_node(0, 0, 0, 0, 0, TY_NEVER, 0, 0, 0);
    t6_char := alloc_node(0, 0, 0, 0, 0, TY_CHAR, 0, 0, 0);
    t6_dyn := alloc_node(0, 0, 0, 0, 0, TI_DYN, 0, 0, 0);
    t6_dex_s := alloc_node(0, 0, 0, 0, 0, TY_DEX_S, 0, 0, 0);
    t6_oob := alloc_node(0, 0, 0, 0, 0, 999, 0, 0, 0);
    total = total + 1; fails = fails + ts_check("t6.node_kinds",
        (ast_kind(t6_never) == 0 && ast_type_val(t6_never) == TY_NEVER &&
         ast_type_val(t6_dyn) == TI_DYN && ast_type_val(t6_dex_s) == TY_DEX_S), 1);
    total = total + 1; fails = fails + ts_check("t6.R_codes",
        (res_type_node(t6_int) == TI_INT && res_type_node(t6_dex) == TI_DEX &&
         res_type_node(t6_bool) == TI_BOOL && res_type_node(t6_str) == TI_STR &&
         res_type_node(t6_unit) == TI_UNIT && res_type_node(t6_never) == TI_NEVER &&
         res_type_node(t6_char) == TI_CHAR), 1);
    total = total + 1; fails = fails + ts_check("t6.C_codes",
        (res_call_type(t6_int, -1) == TI_INT && res_call_type(t6_dex, -1) == TI_DEX &&
         res_call_type(t6_bool, -1) == TI_BOOL && res_call_type(t6_str, -1) == TI_STR &&
         res_call_type(t6_unit, -1) == TI_UNIT && res_call_type(t6_char, -1) == TI_CHAR), 1);
    // **两表唯一语义差**：NEVER 格（A 有 / B 无 ⇒ B 落 TI_UNIT）——差异不得被合一抹平
    total = total + 1; fails = fails + ts_check("t6.never_cell_diff",
        (res_type_node(t6_never) == TI_NEVER && res_call_type(t6_never, -1) == TI_UNIT), 1);
    // 两表**共有**的 7 码格（dyn）：均 → TI_DYN（B2 探针：`x : dyn = 5; x.nosuch()` 的 N08 依赖本格）
    total = total + 1; fails = fails + ts_check("t6.dyn_cell_both",
        (res_type_node(t6_dyn) == TI_DYN && res_call_type(t6_dyn, -1) == TI_DYN), 1);
    // 域外码（TY_DEX_S/未知）两表均落 TI_UNIT（= 改动前的尾回落；表内无兜底）
    total = total + 1; fails = fails + ts_check("t6.dex_s_oob_unit",
        (res_type_node(t6_dex_s) == TI_UNIT && res_call_type(t6_dex_s, -1) == TI_UNIT &&
         res_type_node(t6_oob) == TI_UNIT && res_call_type(t6_oob, -1) == TI_UNIT), 1);
    total = total + 1; fails = fails + ts_check("t6.neg_node_unit",
        (res_type_node(-1) == TI_UNIT && res_call_type(-1, -1) == TI_UNIT), 1);

    // ═══ R2 P3 Task 0：引擎展开层（named/struct/enum/generic-apply → 结构项）═══
    // 判据面 = ① 正向形态：字段**声明序** / 变体数 / 泛型实参代入；② **名义不变量双钉**
    // （等价面零漂移：展开项结构相等 ∧ 桥接项 ty_equiv 仍 -1 ∧ type_equal 仍 false）；
    // ③ 缺口上抛（不可展开 → -1，**不得**静默判否）；④ 展开缓存语义（命中计数 / 失败不入表）；
    // ⑤ 域/模式项在引擎穷尽性上的**端到端**前哨（Task 3 判据的种子）。
    // 夹具全部人造行（本通道不经 parser/check_all）：声明表照 parser 的写槽序落，类型节点照
    // parse_type 的产物形态构造（基型节点 kind=0 + type_val=TY_*；EXPR_IDENT = 泛型形参/
    // 命名类型；EXPR_ARRAY = `[T;N]`）。
    init_types();                    // 干净起点（类型行号空间复位；原生 9 行在前）
    ty_budget_reset(200000);

    // 夹具 ①：struct UnfBoxU[T] { val: T }（泛型字段 = 形参 ⇒ 实参代入判据）+ 两个应用行
    // 形参照 collect_decls（checker.cr:941-950）登记为符号——**生产路径 struct 泛型形参必在
    // 符号表**（res_type_node 经 find_gsym 解析形参名），本通道照此登记 = 走真实解析路径。
    unf_gp := str_intern("UnfTGparamU");
    def_sym(unf_gp, SYM_TYPE, alloc_type(TYP_GENERIC_PARAM, unf_gp, 0), -1);
    unf_box_sa := add_struct("UnfBoxU");
    w64(g_structs, unf_box_sa * ESZ_STRUCTINFO + OFF_SI_GENERIC_COUNT, 1);
    w64(g_structs, unf_box_sa * ESZ_STRUCTINFO + OFF_SI_GENERIC_NAMES, unf_gp);
    si_set_field_name(unf_box_sa, 0, str_intern("val"));
    si_set_field_type(unf_box_sa, 0, 0);   // 裸码槽 = parser 对非基型的塌缩值（0 = TY_INT；本层不读）
    si_set_field_type_node(unf_box_sa, 0,
        alloc_node(EXPR_IDENT, -1, -1, -1, unf_gp, 0, -1, 0, 0));
    w64(g_structs, unf_box_sa * ESZ_STRUCTINFO + OFF_SI_FIELD_COUNT, 1);
    unf_box_ti := alloc_named_type(str_intern("UnfBoxU"));
    // 应用行 `UnfBoxU[int]` / `UnfBoxU[string]`（g_gen_apply_data: [count, arg]）
    grow_gen_apply_data(g_gen_apply_data_count + 2);
    unf_gas1 := g_gen_apply_data_count;
    w64(g_gen_apply_data, unf_gas1 * 8, 1);
    w64(g_gen_apply_data, (unf_gas1 + 1) * 8, TI_INT);
    g_gen_apply_data_count = unf_gas1 + 2;
    unf_ga_int := alloc_type(TYP_GENERIC_APPLY, unf_box_ti, unf_gas1);
    grow_gen_apply_data(g_gen_apply_data_count + 2);
    unf_gas2 := g_gen_apply_data_count;
    w64(g_gen_apply_data, unf_gas2 * 8, 1);
    w64(g_gen_apply_data, (unf_gas2 + 1) * 8, TI_STR);
    g_gen_apply_data_count = unf_gas2 + 2;
    unf_ga_str := alloc_type(TYP_GENERIC_APPLY, unf_box_ti, unf_gas2);
    unf_ta := sh_struct_term(unf_ga_int);
    unf_tb := sh_struct_term(unf_ga_str);
    total = total + 1; fails = fails + ts_check("unf.ga_arg_subst",
        (tt_a(unf_ta) == AK_PRODUCT && tt_c(unf_ta) == tt_cons(tt_atom(AK_INT, TI_INT, -1), tt_nil()) &&
         tt_c(unf_tb) == tt_cons(tt_atom(AK_STRING, TI_STR, -1), tt_nil()) && unf_ta != unf_tb), 1);
    // 未应用形态：泛型形参保持**名义**（res_type_node 取形参行 ⇒ AK_NAMED）——不得凭空代入 int
    unf_tbare := sh_struct_term(unf_box_ti);
    total = total + 1; fails = fails + ts_check("unf.ga_unapplied_nominal",
        (unf_tbare >= 0 && tt_a(unf_tbare) == AK_PRODUCT && tt_a(tt_a(tt_c(unf_tbare))) != AK_INT), 1);

    // 夹具 ②：struct UnfP1U { a: int, b: string }（字段**声明序**；含基型两种）
    unf_p1_sa := add_struct("UnfP1U");
    si_set_field_name(unf_p1_sa, 0, str_intern("a"));
    si_set_field_type(unf_p1_sa, 0, TY_INT);
    si_set_field_type_node(unf_p1_sa, 0, alloc_node(0, 0, 0, 0, 0, TY_INT, 0, 0, 0));
    si_set_field_name(unf_p1_sa, 1, str_intern("b"));
    si_set_field_type(unf_p1_sa, 1, TY_STRING);
    si_set_field_type_node(unf_p1_sa, 1, alloc_node(0, 0, 0, 0, 0, TY_STRING, 0, 0, 0));
    w64(g_structs, unf_p1_sa * ESZ_STRUCTINFO + OFF_SI_FIELD_COUNT, 2);
    unf_p1_ti := alloc_named_type(str_intern("UnfP1U"));
    unf_tp1 := sh_struct_term(unf_p1_ti);
    total = total + 1; fails = fails + ts_check("unf.struct_field_order",
        (tt_a(unf_tp1) == AK_PRODUCT &&
         tt_c(unf_tp1) == tt_cons(tt_atom(AK_INT, TI_INT, -1), tt_cons(tt_atom(AK_STRING, TI_STR, -1), tt_nil()))), 1);
    // 夹具 ③：struct UnfP2U { x: [int;2] }——字段**裸码槽 = 0（= TY_INT）而类型节点 = 数组**：
    // 「只读裸码槽」的实现会把该字段静默误判为 int（本用例即其守门；裸码塌缩 = parser 事实）
    unf_p2_sa := add_struct("UnfP2U");
    unf_arrn := alloc_node(EXPR_ARRAY, alloc_node(0, 0, 0, 0, 0, TY_INT, 0, 0, 0), -1, -1, 2, 0, -1, 0, 0);
    si_set_field_name(unf_p2_sa, 0, str_intern("x"));
    si_set_field_type(unf_p2_sa, 0, 0);
    si_set_field_type_node(unf_p2_sa, 0, unf_arrn);
    w64(g_structs, unf_p2_sa * ESZ_STRUCTINFO + OFF_SI_FIELD_COUNT, 1);
    unf_p2_ti := alloc_named_type(str_intern("UnfP2U"));
    unf_tp2 := sh_struct_term(unf_p2_ti);
    total = total + 1; fails = fails + ts_check("unf.struct_field_node_not_code",
        (tt_a(unf_tp2) == AK_PRODUCT && tt_a(tt_a(tt_c(unf_tp2))) == AK_SEQUENCE), 1);

    // 夹具 ④：两个**同形不同名** struct（UnfS1U{a:int} / UnfS2U{a:int}）——本 Task 的风险边界，
    // 三断 = 双钉：① 展开项（满足面）**结构相等**（同形 ⇒ 同项 = 满足判定的设计意图）；
    // ② 桥接项（等价面）仍 -1（AK_NAMED 原子不展开，**不得**当 0/1）；③ type_equal 仍 false
    // 且回落 legacy 恰 +1（不静默）。
    unf_s1_ti := ts_unf_mk_int_struct("UnfS1U");
    unf_s2_ti := ts_unf_mk_int_struct("UnfS2U");
    unf_e1 := sh_struct_term(unf_s1_ti);
    unf_e2 := sh_struct_term(unf_s2_ti);
    total = total + 1; fails = fails + ts_check("unf.nominal_structural_equal",
        (unf_e1 >= 0 && unf_e2 >= 0 && ty_equiv(unf_e1, unf_e2) == 1), 1);
    // **R2 P5 Task 3 重钉**（翻转向量表：`unf.nominal_equiv_atomic_unknown` →
    // `unf.nominal_equiv_atomic_decided`）：命名面接引擎身份链后，**异名同形**两个命名型的
    // 桥接项判 **0 = 确定不同**（旧断 -1 = 未覆盖面；legacy 同结论 = false ⇒ 行为同值，
    // 差异 = 引擎自决而非回落）。展开项（满足面）结构相等断（上一例）逐字未动——「等价面
    // 不展开」的边界仍由该例把住（同形不同名 ⇒ 桥接项 0，展开项 1）。
    total = total + 1; fails = fails + ts_check("unf.nominal_equiv_atomic_decided",
        ty_equiv(sh_term_of_ti(unf_s1_ti), sh_term_of_ti(unf_s2_ti)), 0);
    // T3 重钉（零回落）→ **T4 终态**：回落计数已随 legacy 删除 ⇒ 断言 = 「判 false + 零
    // 未知诊断（ICE04 缺席 = 引擎真判 0，而非未知被静默当 false）」。
    unf_d0 := g_diag_count;
    unf_eqf : ., mut = 0;
    if !type_equal(unf_s1_ti, unf_s2_ti) {
        if g_diag_count == unf_d0 { unf_eqf = 1; }
    }
    total = total + 1; fails = fails + ts_check("unf.nominal_type_equal_false", unf_eqf, 1);

    // 夹具 ⑤：enum UnfColorU { UnfRedU, UnfGreenU, UnfBlueU }（tag-only，3 变体）
    unf_col_ei := add_enum("UnfColorU");
    ei_set_variant_name(unf_col_ei, 0, str_intern("UnfRedU"));
    ei_set_variant_name(unf_col_ei, 1, str_intern("UnfGreenU"));
    ei_set_variant_name(unf_col_ei, 2, str_intern("UnfBlueU"));
    w64(g_enums, unf_col_ei * ESZ_ENUMINFO + OFF_EI_VARIANT_COUNT, 3);
    unf_col_ti := alloc_named_type(str_intern("UnfColorU"));
    unf_dom := sh_enum_domain_term(unf_col_ti);
    total = total + 1; fails = fails + ts_check("unf.enum_domain_count",
        (unf_dom >= 0 && ts_unf_union_leaves(unf_dom) == 3), 1);
    unf_vr := sh_variant_term(unf_col_ti, str_intern("UnfRedU"));
    unf_vg := sh_variant_term(unf_col_ti, str_intern("UnfGreenU"));
    unf_vb := sh_variant_term(unf_col_ti, str_intern("UnfBlueU"));
    total = total + 1; fails = fails + ts_check("unf.enum_variant_in_domain",
        (ty_sub(unf_vr, unf_dom) == 1 && ty_sub(unf_vg, unf_dom) == 1 && ty_sub(unf_vb, unf_dom) == 1 &&
         sh_variant_term(unf_col_ti, str_intern("UnfNoSuchVariantU")) == -1), 1);
    // 变体身份**含枚举名**（引擎只比 a/c 两槽 ⇒ 身份必须入参数链）：异枚举**同名变体**不得被判等价
    unf_dup_ei := add_enum("UnfDupU");
    ei_set_variant_name(unf_dup_ei, 0, str_intern("UnfRedU"));
    w64(g_enums, unf_dup_ei * ESZ_ENUMINFO + OFF_EI_VARIANT_COUNT, 1);
    unf_dup_ti := alloc_named_type(str_intern("UnfDupU"));
    unf_vdup := sh_variant_term(unf_dup_ti, str_intern("UnfRedU"));
    total = total + 1; fails = fails + ts_check("unf.enum_variant_identity_scoped",
        (unf_vdup >= 0 && ty_sub(unf_vdup, unf_vr) != 1 && ty_sub(unf_vr, unf_vdup) != 1), 1);
    // 空枚举：域 = ⊥（无值可取——**登记语义**：空域在补集语义下恒穷尽，Task 3 须显式裁决）
    unf_emp_ei := add_enum("UnfEmptyU");
    w64(g_enums, unf_emp_ei * ESZ_ENUMINFO + OFF_EI_VARIANT_COUNT, 0);
    unf_emp_ti := alloc_named_type(str_intern("UnfEmptyU"));
    total = total + 1; fails = fails + ts_check("unf.enum_empty_domain_bot", tt_tag(sh_enum_domain_term(unf_emp_ti)), TT_BOT);

    // 夹具 ⑥：enum UnfOptU[T] { UnfNoneU, UnfSomeU(T) }（tag + payload 混合）——域/模式项在
    // 引擎穷尽性上的**端到端**前哨（Task 3 判据的种子）。payload 槽照 parser 落裸码（非基型
    // 塌缩为 0 ⇒ 本层**不读**它：payload 不入变体项，见 ty_shadow.cr 展开段未覆盖面注记）。
    unf_opt_ei := add_enum("UnfOptU");
    w64(g_enums, unf_opt_ei * ESZ_ENUMINFO + OFF_EI_GENERIC_COUNT, 1);
    w64(g_enums, unf_opt_ei * ESZ_ENUMINFO + OFF_EI_GENERIC_NAMES, str_intern("UnfTOptU"));
    ei_set_variant_name(unf_opt_ei, 0, str_intern("UnfNoneU"));
    ei_set_variant_name(unf_opt_ei, 1, str_intern("UnfSomeU"));
    ei_set_variant_type_count(unf_opt_ei, 1, 1);
    ei_set_variant_type(unf_opt_ei, 1, 0, TY_INT);   // 裸码槽（parser 事实；本层不读）
    w64(g_enums, unf_opt_ei * ESZ_ENUMINFO + OFF_EI_VARIANT_COUNT, 2);
    unf_opt_ti := alloc_named_type(str_intern("UnfOptU"));
    unf_odom := sh_enum_domain_term(unf_opt_ti);
    unf_onone := sh_variant_term(unf_opt_ti, str_intern("UnfNoneU"));
    unf_osome := sh_variant_term(unf_opt_ti, str_intern("UnfSomeU"));
    total = total + 1; fails = fails + ts_check("unf.exhaust_cover_all",
        ty_exhaustive(unf_odom, tt_cons(unf_onone, tt_cons(unf_osome, tt_nil()))), 1);
    total = total + 1; fails = fails + ts_check("unf.exhaust_missing_one",
        ty_exhaustive(unf_odom, tt_cons(unf_onone, tt_nil())), 0);
    // 缺变体 witness：不可空且 ⊆ 缺失变体。**登记**：原始 witness = 各析取支之并（**含空析取支**
    // ——norm 不做空支净化）⇒ Task 3 若当「具体反例值」用，须先取有住户的支（或引擎加净化）。
    unf_w2 := ty_exhaust_witness(unf_odom, tt_cons(unf_onone, tt_nil()));
    total = total + 1; fails = fails + ts_check("unf.exhaust_witness_subset",
        (unf_w2 >= 0 && ty_inhabited(unf_w2) == 1 && ty_sub(unf_w2, unf_osome) == 1), 1);

    // 展开缓存：新 ti 恰入表 1 条；二次调用恰命中 1 次且返回**同项**；**失败不缓存**（-1 不入表）
    unf_fresh := ts_unf_mk_int_struct("UnfCacheU");
    unf_ce0 := sh_unf_entries();
    unf_ch0 := sh_unf_hits();
    unf_ct1 := sh_struct_term(unf_fresh);
    unf_ce1 := sh_unf_entries();
    unf_ct2 := sh_struct_term(unf_fresh);
    unf_fail_e0 := sh_unf_entries();
    sh_struct_term(g_type_count + 7);
    total = total + 1; fails = fails + ts_check("unf.cache_hit_and_no_neg_cache",
        ((unf_ce1 - unf_ce0) == 1 && (sh_unf_hits() - unf_ch0) == 1 && unf_ct2 == unf_ct1 &&
         (sh_unf_entries() - unf_fail_e0) == 0), 1);

    // 缺口上抛（**不得静默判否**）：行号越界 / 未声明的名字行 / 裸泛型形参行 / 非枚举变体名 → -1
    unf_plain_ti := alloc_named_type(str_intern("UnfNoDeclU"));
    unf_loose_gp := alloc_type(TYP_GENERIC_PARAM, str_intern("UnfLooseTU"), 0);
    total = total + 1; fails = fails + ts_check("unf.neg_paths",
        (sh_struct_term(g_type_count + 7) == -1 && sh_enum_domain_term(g_type_count + 7) == -1 &&
         sh_struct_term(-1) == -1 && sh_variant_term(-1, 0) == -1 && sh_variant_term(unf_col_ti, -1) == -1 &&
         sh_struct_term(unf_plain_ti) == -1 && sh_enum_domain_term(unf_plain_ti) == -1 &&
         sh_struct_term(unf_loose_gp) == -1), 1);

    // 接口面负键守门（P3b Task 0 后：`iface_satisfies` 已交付，本用例 = **域外输入守卫**——
    // 形状项构造仍为 Task 6 占位（-1），负键/未知名键一律三态 -1，**不得**被消费方当 0/1 用）
    total = total + 1; fails = fails + ts_check("unf.iface_stub_three_state",
        (sh_iface_shape_term(-1) == -1 && iface_satisfies(-1, 0) == -1 && iface_satisfies(TI_INT, 9999) == -1), 1);

    // ═══ R2 P3 Task 1：定长退役收口（array/slice 方向 + 变型表 + N 读取面守门）═══
    // 判据面 = ① 方向：`[T;N] <: [T]`（固定 → 视图 = 拓宽，放行）/ `[T] ⊄ [T;N]`（视图 → 固定，
    // 无法证 len==N ⇒ 拒；**确定 0 而非 -1**）；② 变型：只读协变通过 / 可写不变拒绝（AK_REF
    // 槽语义）+ mut 标记成为判定维度（`&T` ≢ `&mut T` 双向）；③ **N 读取面守门**：身份路径与
    // 子类型路径零 N（`[int;3]` 与 `[int;4]` 的项除 b 槽外逐位相同），拒绝**唯一**来源 =
    // 常量档约束；④ 嵌套位（指针元素 / 元组字段 / 泛型实参 / 数组元素）逐位同律；⑤ 动态档登记
    // （视图运行期长度不可证 ⇒ 决定 0，不得以 -1 冒充决定）。
    // 层归属（计划编排列「方向 4」于引擎步内）：固定性存于序列项 **b 槽（标注，不入引擎比较）**
    // ⇒ 方向**不在**引擎 ty_sub 面，而在 checker 的 array_len_constraint_ok（参序 =（源，目标））
    // ——与 P2a「N 迁出身份、拒绝由常量档承担」同一构造；故本组的方向断言直接打该函数与站点
    // 三态包装 type_compat_strict（引擎侧只保留「N 不入身份/子类型」的守门）。
    ty_budget_reset(200000);
    t1_arr3 := alloc_type(TYP_ARRAY, TI_INT, 3);
    t1_arr4 := alloc_type(TYP_ARRAY, TI_INT, 4);
    t1_sl := alloc_type(TYP_SLICE, TI_INT, 0);
    t1_sl2 := alloc_type(TYP_SLICE, TI_INT, 0);      // 另一行同形切片：方向面不得靠 ti 同一性
    // ① 方向（顶层）：固定→视图 放行；视图→固定 拒（0 = 决定，非 -1）；视图→视图 同元素放行
    total = total + 1; fails = fails + ts_check("t1.dir_arr_to_slice_ok",
        array_len_constraint_ok(t1_arr3, t1_sl), 1);
    total = total + 1; fails = fails + ts_check("t1.dir_slice_to_arr_reject",
        array_len_constraint_ok(t1_sl, t1_arr3), 0);
    total = total + 1; fails = fails + ts_check("t1.dir_slice_slice_ok",
        array_len_constraint_ok(t1_sl, t1_sl2), 1);
    // ② N 不入身份（同固定性异 N）：引擎等价 1 ∧ 常量档拒 0（双钉 = 「N 迁移」不变量）
    total = total + 1; fails = fails + ts_check("t1.dir_fixed_two_lengths_identity",
        (ty_equiv(sh_term_of_ti(t1_arr3), sh_term_of_ti(t1_arr4)) == 1 &&
         array_len_constraint_ok(t1_arr4, t1_arr3) == 0), 1);
    // ③ 嵌套位逐位同律（负控：反向拓宽必须仍放行——防「一律拒绝」的退化实现）
    t1_pt_sl := alloc_type(TYP_PTR, t1_sl, 0);
    t1_pt_arr := alloc_type(TYP_PTR, t1_arr3, 0);
    total = total + 1; fails = fails + ts_check("t1.dir_nested_ptr",
        (array_len_constraint_ok(t1_pt_sl, t1_pt_arr) == 0 && array_len_constraint_ok(t1_pt_arr, t1_pt_sl) == 1), 1);
    t1_out_sl := alloc_type(TYP_ARRAY, t1_sl, 2);       // [[int];2]
    t1_out_arr := alloc_type(TYP_ARRAY, t1_arr3, 2);    // [[int;3];2]
    total = total + 1; fails = fails + ts_check("t1.dir_nested_elem",
        (array_len_constraint_ok(t1_out_sl, t1_out_arr) == 0 && array_len_constraint_ok(t1_out_arr, t1_out_sl) == 1), 1);
    grow_gen_apply_data(g_gen_apply_data_count + 4);
    t1_tp_s1 := g_gen_apply_data_count;
    w64(g_gen_apply_data, t1_tp_s1 * 8, TI_INT);
    w64(g_gen_apply_data, (t1_tp_s1 + 1) * 8, t1_sl);
    t1_tp_s2 := t1_tp_s1 + 2;
    w64(g_gen_apply_data, t1_tp_s2 * 8, TI_INT);
    w64(g_gen_apply_data, (t1_tp_s2 + 1) * 8, t1_arr3);
    g_gen_apply_data_count = t1_tp_s2 + 2;
    t1_tup_sl := alloc_type(TYP_TUPLE, 2, t1_tp_s1);     // (int, [int])
    t1_tup_arr := alloc_type(TYP_TUPLE, 2, t1_tp_s2);    // (int, [int;3])
    total = total + 1; fails = fails + ts_check("t1.dir_nested_tuple",
        (array_len_constraint_ok(t1_tup_sl, t1_tup_arr) == 0 && array_len_constraint_ok(t1_tup_arr, t1_tup_sl) == 1), 1);
    grow_gen_apply_data(g_gen_apply_data_count + 4);
    t1_ga_s1 := g_gen_apply_data_count;
    w64(g_gen_apply_data, t1_ga_s1 * 8, 1);
    w64(g_gen_apply_data, (t1_ga_s1 + 1) * 8, t1_sl);
    t1_ga_s2 := t1_ga_s1 + 2;
    w64(g_gen_apply_data, t1_ga_s2 * 8, 1);
    w64(g_gen_apply_data, (t1_ga_s2 + 1) * 8, t1_arr3);
    g_gen_apply_data_count = t1_ga_s2 + 2;
    t1_base := alloc_type(TYP_NAMED, 1203, 0);           // 人造基型行（裸分配，防假键污染）
    t1_ga_sl := alloc_type(TYP_GENERIC_APPLY, t1_base, t1_ga_s1);
    t1_ga_arr := alloc_type(TYP_GENERIC_APPLY, t1_base, t1_ga_s2);
    total = total + 1; fails = fails + ts_check("t1.dir_nested_genapply",
        (array_len_constraint_ok(t1_ga_sl, t1_ga_arr) == 0 && array_len_constraint_ok(t1_ga_arr, t1_ga_sl) == 1), 1);
    // ④ 站点三态（专属措辞 = -1 路）：拓宽 1；视图→固定 -1（身份放行、方向拒）；对称核 = 现状
    total = total + 1; fails = fails + ts_check("t1.strict_widen_ok",
        type_compat_strict(t1_arr3, t1_sl), 1);
    total = total + 1; fails = fails + ts_check("t1.strict_view_to_fixed",
        type_compat_strict(t1_sl, t1_arr3), -1);
    total = total + 1; fails = fails + ts_check("t1.strict_sym_no_direction",
        (type_compat_sym(t1_sl, t1_arr3) == 1 && type_compat_sym(t1_arr3, t1_sl) == 1), 1);
    // ⑤ 变型：只读协变通过 / 可写不变拒绝（AK_REF 槽 1 条件变型）；表外构造子默认不变
    t1_u := tt_union(tt_atom(AK_INT, TI_INT, -1), tt_atom(AK_STRING, TI_STR, -1));   // int ∪ string
    t1_rv_ro := tt_atom(AK_REF, -1, tt_cons(sh_ref_mut_marker(0), tt_cons(tt_atom(AK_INT, TI_INT, -1), tt_nil())));
    t1_rv_ro_w := tt_atom(AK_REF, -1, tt_cons(sh_ref_mut_marker(0), tt_cons(t1_u, tt_nil())));
    t1_rv_mut := tt_atom(AK_REF, -1, tt_cons(sh_ref_mut_marker(1), tt_cons(tt_atom(AK_INT, TI_INT, -1), tt_nil())));
    t1_rv_mut_w := tt_atom(AK_REF, -1, tt_cons(sh_ref_mut_marker(1), tt_cons(t1_u, tt_nil())));
    total = total + 1; fails = fails + ts_check("t1.var_readonly_covariant",
        (ty_sub(t1_rv_ro, t1_rv_ro_w) == 1 && ty_sub(t1_rv_ro_w, t1_rv_ro) == 0), 1);
    // 不变槽非同形的判定**语义** = 「不是子类型」；引擎回 **-1**（未覆盖面登记——不变槽的
    // 「确定不等价 ⇒ 0」加强需先有「链元素皆类型项」不变量，见 type_engine.cr 注记）⇒ 断
    // 「两向皆不得判 1」= 不变性的可执行内容；生产面（checker type_equal）在此回落 legacy
    // 得 false = 实拒（pE 探针实测 rc=1）。
    total = total + 1; fails = fails + ts_check("t1.var_mut_invariant_reject",
        (ty_sub(t1_rv_mut, t1_rv_mut_w) != 1 && ty_sub(t1_rv_mut_w, t1_rv_mut) != 1), 1);
    total = total + 1; fails = fails + ts_check("t1.var_seq_elem_invariant",
        ty_sub(tt_atom(AK_SEQUENCE, -1, tt_cons(tt_atom(AK_INT, TI_INT, -1), tt_nil())),
               tt_atom(AK_SEQUENCE, -1, tt_cons(t1_u, tt_nil()))) != 1, 1);
    // ⑥ mut 标记入链 = 判定维度（走真实桥接）：`&T` ≢ `&mut T` 双向；同 mut 同元素仍等价
    t1_ref_ro := alloc_type(TYP_REF, TI_INT, 0);
    t1_ref_ro2 := alloc_type(TYP_REF, TI_INT, 0);
    t1_ref_mut := alloc_type(TYP_REF, TI_INT, 1);
    total = total + 1; fails = fails + ts_check("t1.var_mut_marker_dimension",
        (ty_equiv(sh_term_of_ti(t1_ref_ro), sh_term_of_ti(t1_ref_mut)) == 0 &&
         ty_equiv(sh_term_of_ti(t1_ref_mut), sh_term_of_ti(t1_ref_ro)) == 0 &&
         ty_equiv(sh_term_of_ti(t1_ref_ro), sh_term_of_ti(t1_ref_ro2)) == 1 &&
         tt_b(tt_a(tt_c(sh_term_of_ti(t1_ref_mut)))) == 1), 1);
    // ⑦ N 读取面守门：身份路径（ty_equiv）+ **子类型路径（ty_sub）**零 N；唯一拒绝来源 = 常量档
    total = total + 1; fails = fails + ts_check("t1.n_face_gate",
        (type_equal(t1_arr3, t1_arr4) &&
         ty_sub(sh_term_of_ti(t1_arr3), sh_term_of_ti(t1_arr4)) == 1 &&
         array_len_constraint_ok(t1_arr4, t1_arr3) == 0), 1);
    // ⑧ 动态档登记：切片运行期长度不可证 ⇒ 视图→固定是**决定**（0），不得回 -1 冒充未知；
    //    异长固定档同理（常量档拒绝也在决定面）。
    total = total + 1; fails = fails + ts_check("t1.dyn_tier_decided",
        (array_len_constraint_ok(t1_sl, t1_arr3) == 0 && array_len_constraint_ok(t1_sl2, t1_arr4) == 0 &&
         array_len_constraint_ok(t1_arr3, t1_arr4) == 0), 1);
    // ⑨ **嵌套位**的身份不变量 + 站点三态（本批实测发现的回归面：序列项的固定性位 b 会经
    //    嵌套元素位的**节点同一性**泄进身份 ⇒ 必须由引擎的「忽略 b 的序列项相等」挡住——
    //    type_engine.cr 的 tt_type_elem_same/tt_seq_same）。断三件事：
    //    ① 嵌套 N：`type_equal([[int;3];2], [[int;4];2])` 仍 true **且不触发 unknown 回落**
    //    （引擎自决 = 身份路径零 N 的强式；旧实现靠 legacy 回落兜底，措辞随之退化）；
    //    ② 嵌套固定性同样**不入身份**（`ty_equiv` 两向 1）；
    //    ③ 站点层：嵌套 视图→固定 = -1（专属措辞路）、嵌套 固定→视图 = 1（拓宽保持）。
    t1_out_arr4 := alloc_type(TYP_ARRAY, t1_arr4, 2);   // [[int;4];2]
    // T4 终态：断言从「零回落计数」改为「零未知诊断」（ICE04 缺席 = 引擎真判身份路径）
    t1_d0 := g_diag_count;
    t1_nest_ok : ., mut = 0;
    if type_equal(t1_out_arr, t1_out_arr4) { if g_diag_count == t1_d0 { t1_nest_ok = 1; } }
    total = total + 1; fails = fails + ts_check("t1.n_face_gate_nested",
        (t1_nest_ok == 1 && array_len_constraint_ok(t1_out_arr4, t1_out_arr) == 0), 1);
    total = total + 1; fails = fails + ts_check("t1.fixedness_not_identity_nested",
        ty_equiv(sh_term_of_ti(t1_out_sl), sh_term_of_ti(t1_out_arr)), 1);
    total = total + 1; fails = fails + ts_check("t1.dir_nested_strict",
        (type_compat_strict(t1_out_sl, t1_out_arr) == -1 && type_compat_strict(t1_out_arr, t1_out_sl) == 1), 1);

    // ═══ R2 P3 Task 3：match 穷尽性真判定（补集空性 + 具体变体反例）═══
    // 判据面 = ① 引擎三态：全覆盖 / 缺一 / 无臂 / 通配吸收 / 单变体；② **反例的具体值** =
    // 缺失**变体名**（逐变体覆盖位命名——引擎 witness 原始形态含空析取支，与缺失变体按
    // ty_equiv 不等，本组第 3 例把该事实与消费点命名一并钉死）；③ 域守卫与不可映射守卫
    // （-1 = 不判，不得当 0/1）；④ 空枚举域 = 空洞穷尽（登记语义，与计划原文「= 0」的偏差
    // 见任务报告）；⑤ payload 变体混合 / 限定名解析 / 重复臂 / 泛型应用行。
    // 夹具照 Task 0 先例人工落行（写槽序 = parser 的；payload 裸码槽照 parser 事实落）。
    init_types();
    ty_budget_reset(200000);
    t3_col_ei := add_enum("T3Color");
    ei_set_variant_name(t3_col_ei, 0, str_intern("T3Red"));
    ei_set_variant_name(t3_col_ei, 1, str_intern("T3Green"));
    ei_set_variant_name(t3_col_ei, 2, str_intern("T3Blue"));
    w64(g_enums, t3_col_ei * ESZ_ENUMINFO + OFF_EI_VARIANT_COUNT, 3);
    t3_col_ti := alloc_named_type(str_intern("T3Color"));
    t3_r := sh_match_variant_term(t3_col_ti, 0);
    t3_g := sh_match_variant_term(t3_col_ti, 1);
    t3_b := sh_match_variant_term(t3_col_ti, 2);
    // ① 全覆盖 = 1（模式项与域项同一构造 ⇒ 补集空）
    total = total + 1; fails = fails + ts_check("t3.cover_all",
        sh_match_exhaustive(t3_col_ti, tt_cons(t3_r, tt_cons(t3_g, tt_cons(t3_b, tt_nil()))), 0), 1);
    // ② 缺一变体 = 0；反例 = **缺失变体名**（引擎判据 + 覆盖位命名两路并用）
    t3_ab := tt_cons(t3_r, tt_cons(t3_g, tt_nil()));
    total = total + 1; fails = fails + ts_check("t3.missing_one_verdict",
        sh_match_exhaustive(t3_col_ti, t3_ab, 0), 0);
    t3_w := ty_exhaust_witness(sh_enum_domain_term(t3_col_ti), t3_ab);
    t3_cx := sh_match_first_missing(sh_match_bit(0) + sh_match_bit(1), ei_variant_count(t3_col_ei));
    t3_cx_named : ., mut = 0;
    if t3_cx == 2 {
        if str_eq(istr_get(ei_variant_name(t3_col_ei, t3_cx)), "T3Blue") != 0 { t3_cx_named = 1; }
    }
    // 引擎 witness 原始形态 = 含空析取支的并（Task 0 §5-②）：本批**实测**（三态）=
    // ty_sub(w, 缺失变体) = 1（w ⊆ b）∧ ty_sub(反方向) = **-1**（未覆盖面——空析取支让反向
    // 结构比较落空）∧ ty_equiv = **-1**（**不是 0**：Task 0 报告记「不等」为 `== 0`，实测为
    // -1 = 未覆盖面，此处按实测钉死；-1 不得当 0 用的三态纪律在此具体化）∧ 可空 = 1。
    // 故「反例给具体值」由**覆盖位命名**承担（引擎 witness 项在其上不可作显示名）。
    total = total + 1; fails = fails + ts_check("t3.counterexample_named_variant",
        (t3_w >= 0 && ty_inhabited(t3_w) == 1 && ty_sub(t3_w, t3_b) == 1 && t3_cx_named), 1);
    // ─── R2 P5 Task 3b 翻转钉（原合取式 `... && ty_equiv(t3_w, t3_b) == -1` 的拆解）───
    // 变体项 = AK_SUM 链 [枚举名令牌, 变体名令牌]（两枚**身份令牌**）⇒ 不变槽三态落地后，
    // 令牌按节点同一性判**确定不同 0**（改前 = -1 + 未覆盖面）。t3_w = 含两枚**空析取支**
    // 的并：q1 = R∩¬R∩¬G、q2 = G∩¬R∩¬G（皆 ∅）、q3 = B∩¬R∩¬G（= B）。翻转链（实测）：
    //   `ty_sub(B, q1)` 改前 -1（lit_implies(B,R) 走令牌不变槽 ⇒ 未知）→ 改后 0；
    //   ⇒ 外层并分支 `x := sub_cover(B, q1∪q2)` 改前 -1、改后 0；
    //   ⇒ 整式 `ty_sub(B, t3_w)` 改前 **-1**（x = -1 上抛）改后 **0**（x = 0 ∧ y = 0）。
    // ⚠ **登记面（T3b 揭开、R2 P6 Task 2 已收口）**：`ty_sub(B, q3) = 0` —— `sub_cover` 的
    // product 规则（须逐字面覆盖）撞上 ¬ 面「同类原子 ⇒ 不判交」规则（`lit_implies(B, ¬R)`：
    // lp/¬x 同类 AK_SUM ⇒ 原 `ak_disjoint` 回 0 ⇒ 判「不含」）——语义上 `B ⊆ ¬R` **成立**
    // （异变体值集不交）。T3b 只是撤掉了原先掩盖它的 -1（把该过判暴露为可观测）；**Task 2
    // 在 `lit_implies` 的 ¬ 面加「同类 ⇒ 身份判据」**（`atom_same_class_disjoint`，域 = AK_SUM
    // 变体项）⇒ `B ⊆ ¬R`/`B ⊆ ¬G` 转 1 ⇒ 下两例 + 单点最小复现**转 1 并重钉**（本批唯一的
    // 行为方向变化；域外面与 `AK_NAMED` 维持原语义，见 type_engine.cr 该函数头注）。
    total = total + 1; fails = fails + ts_check("t3.witness_reverse_over_claim", ty_sub(t3_b, t3_w), 1);
    total = total + 1; fails = fails + ts_check("t3.witness_equiv_over_claim", ty_equiv(t3_w, t3_b), 1);
    // 同一收口面的**最小复现**（单点断言：`B ⊆ B ∩ ¬R` ⟺ `B ⊆ ¬R`）
    total = total + 1; fails = fails + ts_check("t3.product_neg_over_claim",
        ty_sub(t3_b, tt_inter(t3_b, tt_not(t3_r))), 1);
    // ③ 通配/绑定 = ⊤：吸收一切（引擎侧 ⊤ 语义；checker 侧映射见 EXPR_MATCH）
    total = total + 1; fails = fails + ts_check("t3.wildcard_absorbs",
        sh_match_exhaustive(t3_col_ti, tt_cons(tt_top(), tt_nil()), 0), 1);
    // ④ 单变体枚举：有臂 = 1 / 无臂 = 0（空链 ⇒ 补集 = 全域）
    t3_only_ei := add_enum("T3Only");
    ei_set_variant_name(t3_only_ei, 0, str_intern("T3One"));
    w64(g_enums, t3_only_ei * ESZ_ENUMINFO + OFF_EI_VARIANT_COUNT, 1);
    t3_only_ti := alloc_named_type(str_intern("T3Only"));
    t3_one := sh_match_variant_term(t3_only_ti, 0);
    total = total + 1; fails = fails + ts_check("t3.single_variant_covered",
        sh_match_exhaustive(t3_only_ti, tt_cons(t3_one, tt_nil()), 0), 1);
    total = total + 1; fails = fails + ts_check("t3.no_arms_not_exhaustive",
        (sh_match_exhaustive(t3_only_ti, tt_nil(), 0) == 0 && sh_match_first_missing(0, 1) == 0), 1);
    // ⑤ 域守卫与不可映射守卫：非枚举 scrutinee / 不可映射模式 ⇒ -1（**不判**，不得当 0/1）
    t3_s_ti := ts_unf_mk_int_struct("T3StrU");
    total = total + 1; fails = fails + ts_check("t3.domain_guard_unknown",
        (sh_match_exhaustive(TI_INT, tt_nil(), 0) == -1 && sh_match_exhaustive(t3_s_ti, tt_nil(), 0) == -1 &&
         sh_match_exhaustive(-1, tt_nil(), 0) == -1 && sh_enum_domain_term(t3_s_ti) == -1), 1);
    total = total + 1; fails = fails + ts_check("t3.unmappable_guard_unknown",
        sh_match_exhaustive(t3_col_ti, tt_cons(t3_r, tt_cons(t3_g, tt_cons(t3_b, tt_nil()))), 1), -1);
    // ⑥ 空枚举域 = ⊥：补集语义下**空洞穷尽**（无值可漏 ⇒ 无反例；计划原文「= 0」的偏差登记）
    t3_emp_ei := add_enum("T3Empty");
    w64(g_enums, t3_emp_ei * ESZ_ENUMINFO + OFF_EI_VARIANT_COUNT, 0);
    t3_emp_ti := alloc_named_type(str_intern("T3Empty"));
    total = total + 1; fails = fails + ts_check("t3.empty_domain_vacuous",
        (sh_match_exhaustive(t3_emp_ti, tt_nil(), 0) == 1 && sh_match_first_missing(0, 0) == -1), 1);
    // ⑦ payload 变体与 tag 变体混合（payload 不入项 = 变体身份粒度；覆盖语义不受影响）
    t3_mix_ei := add_enum("T3Mix");
    ei_set_variant_name(t3_mix_ei, 0, str_intern("T3None"));
    ei_set_variant_name(t3_mix_ei, 1, str_intern("T3Some"));
    ei_set_variant_type_count(t3_mix_ei, 1, 1);
    ei_set_variant_type(t3_mix_ei, 1, 0, TY_INT);
    w64(g_enums, t3_mix_ei * ESZ_ENUMINFO + OFF_EI_VARIANT_COUNT, 2);
    t3_mix_ti := alloc_named_type(str_intern("T3Mix"));
    t3_none := sh_match_variant_term(t3_mix_ti, 0);
    t3_some := sh_match_variant_term(t3_mix_ti, 1);
    total = total + 1; fails = fails + ts_check("t3.payload_mixed_cover",
        (t3_none >= 0 && t3_some >= 0 && t3_none != t3_some &&
         sh_match_exhaustive(t3_mix_ti, tt_cons(t3_some, tt_cons(t3_none, tt_nil())), 0) == 1 &&
         sh_match_exhaustive(t3_mix_ti, tt_cons(t3_none, tt_nil()), 0) == 0 &&
         sh_match_first_missing(sh_match_bit(0), 2) == 1), 1);
    // ⑧ 模式名字解析：限定名 `Enum.Variant` 与裸名同判；异枚举前缀 / 未声明名 ⇒ -1（不可映射）；
    //    类别分类：通配/绑定 = ⊤、枚举模式 = 变体、字面量/负节点 = 不可映射
    t3_pat_q := alloc_node(EXPR_ENUMPAT, str_intern("T3Color.T3Blue"), 0, 0, 0, 0, 0, 0, 0);
    t3_pat_b := alloc_node(EXPR_ENUMPAT, str_intern("T3Blue"), 0, 0, 0, 0, 0, 0, 0);
    t3_pat_f := alloc_node(EXPR_ENUMPAT, str_intern("T3Mix.T3Blue"), 0, 0, 0, 0, 0, 0, 0);
    t3_pat_n := alloc_node(EXPR_ENUMPAT, str_intern("T3Nope"), 0, 0, 0, 0, 0, 0, 0);
    t3_pat_w := alloc_node(EXPR_WILDCARD, 0, 0, 0, 0, 0, 0, 0, 0);
    t3_pat_l := alloc_node(EXPR_INT, 0, 0, 0, 5, TY_INT, 0, 0, 0);
    t3_pat_i := alloc_node(EXPR_IDENT, 0, 0, 0, str_intern("t3bind"), 0, 0, 0, 0);
    total = total + 1; fails = fails + ts_check("t3.pat_name_resolution",
        (sh_match_pat_variant(t3_col_ti, t3_pat_q) == 2 && sh_match_pat_variant(t3_col_ti, t3_pat_b) == 2 &&
         sh_match_pat_variant(t3_col_ti, t3_pat_f) == -1 && sh_match_pat_variant(t3_col_ti, t3_pat_n) == -1 &&
         sh_match_pat_variant(t3_col_ti, t3_pat_w) == -1 && sh_match_pat_variant(t3_s_ti, t3_pat_b) == -1), 1);
    total = total + 1; fails = fails + ts_check("t3.pat_kind_classification",
        (sh_match_pat_kind(t3_pat_w) == 1 && sh_match_pat_kind(t3_pat_i) == 1 &&
         sh_match_pat_kind(t3_pat_q) == 2 && sh_match_pat_kind(t3_pat_l) == 0 &&
         sh_match_pat_kind(-1) == 0), 1);
    // ⑨ 重复臂：覆盖面无贡献（补集仍空 = 穷尽；覆盖位去重在 checker 侧收集时做——
    // 「位已置 ⇒ 该臂冗余」由行为集钉死）
    total = total + 1; fails = fails + ts_check("t3.dup_arm_complement",
        (sh_match_exhaustive(t3_only_ti, tt_cons(t3_one, tt_cons(t3_one, tt_nil())), 0) == 1 &&
         sh_match_first_missing(sh_match_bit(0), 3) == 1), 1);
    // ⑩ 泛型应用行（`T3GOpt[int]`）：域可展开 + 全覆盖 = 1（变体身份与实参无关）
    t3_go_ei := add_enum("T3GOpt");
    w64(g_enums, t3_go_ei * ESZ_ENUMINFO + OFF_EI_GENERIC_COUNT, 1);
    w64(g_enums, t3_go_ei * ESZ_ENUMINFO + OFF_EI_GENERIC_NAMES, str_intern("T3GT"));
    ei_set_variant_name(t3_go_ei, 0, str_intern("T3GN"));
    ei_set_variant_name(t3_go_ei, 1, str_intern("T3GS"));
    ei_set_variant_type_count(t3_go_ei, 1, 1);
    ei_set_variant_type(t3_go_ei, 1, 0, 0);
    w64(g_enums, t3_go_ei * ESZ_ENUMINFO + OFF_EI_VARIANT_COUNT, 2);
    t3_go_ti := alloc_named_type(str_intern("T3GOpt"));
    grow_gen_apply_data(g_gen_apply_data_count + 2);
    t3_gas := g_gen_apply_data_count;
    w64(g_gen_apply_data, t3_gas * 8, 1);
    w64(g_gen_apply_data, (t3_gas + 1) * 8, TI_INT);
    g_gen_apply_data_count = t3_gas + 2;
    t3_go_ga := alloc_type(TYP_GENERIC_APPLY, t3_go_ti, t3_gas);
    t3_gn := sh_match_variant_term(t3_go_ga, 0);
    t3_gs := sh_match_variant_term(t3_go_ga, 1);
    total = total + 1; fails = fails + ts_check("t3.generic_apply_domain",
        (t3_gn >= 0 && t3_gs >= 0 &&
         sh_match_exhaustive(t3_go_ga, tt_cons(t3_gn, tt_cons(t3_gs, tt_nil())), 0) == 1 &&
         sh_match_exhaustive(t3_go_ga, tt_cons(t3_gn, tt_nil()), 0) == 0), 1);

    // ═══ R2 P3 Task 4：联合/可选（`T?` = `T ∪ null`；退役内建 Option 注册）═══
    // 判据面 = ① 项层：`T?` 行译作 union(内层项, null 原子项)——与**独立构造**的并项等价；
    // ② 子类型/不相交/可空：None ⊆ T?、Some(1) ⊆ int?、null ⊥ int（与 unit/never 亦不相交）、
    //    null 有值（单点域）；③ null 行规范化（同一项，两行不分裂）；④ 判定点注入的**方向性**
    //    （T ⊆ T? 放行 / T? ⊄ T 拒绝——soundness 面）；⑤ match 域面（两分支：有值 + None）与
    //    反例命名、通配吸收、不可映射守卫、非可选域零变化；⑥ 枚举载荷**类型节点列**（T0 交接 ①：
    //    裸码塌缩为 0 = TY_INT，节点列才是载荷真值——本组以「码说是 int、节点说是 string」的
    //    反向夹具把节点列的读取钉死）；⑦ 退役面（Option 无命名行、AK_NULL 无注册表条目）。
    // 夹具：行 = alloc_type/alloc_named_type；枚举表照 parser 写槽序人工落（两列都写）。
    init_types();
    ty_budget_reset(200000);
    t4_null := alloc_type(TYP_NULL, 0, 0);            // None 的类型行（每出现点一行）
    t4_null2 := alloc_type(TYP_NULL, 0, 0);           // 第二个出现点（规范化判据用）
    t4_int_opt := alloc_type(TYP_OPTIONAL, TI_INT, 0);
    t4_str_opt := alloc_type(TYP_OPTIONAL, TI_STR, 0);
    t4_intt := sh_term_of_ti(TI_INT);
    t4_nullt := sh_null_term();
    t4_optt := sh_term_of_ti(t4_int_opt);
    // ① 项层：`int?` 项 = int ∪ null（与独立构造的并项等价），且 **不等于** 裸 int
    total = total + 1; fails = fails + ts_check("t4.opt_term_is_union",
        (ty_equiv(t4_optt, tt_union(t4_intt, t4_nullt)) == 1 &&
         ty_equiv(t4_optt, t4_intt) == 0 && ty_sub(t4_intt, t4_optt) == 1), 1);
    // ② 子类型/不相交/可空
    total = total + 1; fails = fails + ts_check("t4.none_sub_optional",
        (ty_sub(t4_nullt, t4_optt) == 1 && ty_sub(t4_nullt, sh_term_of_ti(t4_str_opt)) == 1 &&
         ty_sub(t4_optt, t4_nullt) == 0 && ty_sub(t4_optt, t4_intt) == 0), 1);
    total = total + 1; fails = fails + ts_check("t4.some_sub_optional",
        (ty_equiv(sh_term_of_ti(alloc_type(TYP_OPTIONAL, TI_INT, 0)), t4_optt) == 1), 1);
    total = total + 1; fails = fails + ts_check("t4.null_disjoint_and_inhabited",
        (ty_disjoint(t4_nullt, t4_intt) == 1 && ty_disjoint(t4_nullt, sh_term_of_ti(TI_UNIT)) == 1 &&
         ty_disjoint(t4_nullt, sh_term_of_ti(TI_NEVER)) == 1 && ty_disjoint(t4_nullt, t4_nullt) == 0 &&
         ty_inhabited(t4_nullt) == 1), 1);
    // ③ null 行规范化：两个出现点译成**同一项**（节点同一），且互判包含
    total = total + 1; fails = fails + ts_check("t4.null_row_canonical",
        (sh_term_of_ti(t4_null) == sh_term_of_ti(t4_null2) &&
         ty_sub(sh_term_of_ti(t4_null), sh_term_of_ti(t4_null2)) == 1), 1);
    // ④ 判定点注入（type_compat_strict）：T ⊆ T? 放行、反向拒绝、异型拒绝；同型走身份路径
    total = total + 1; fails = fails + ts_check("t4.sub_injection_asymmetry",
        (type_compat_strict(TI_INT, t4_int_opt) == 1 && type_compat_strict(t4_int_opt, TI_INT) == 0 &&
         type_compat_strict(TI_STR, t4_int_opt) == 0 && type_compat_strict(t4_null, t4_int_opt) == 1 &&
         type_compat_strict(t4_int_opt, t4_int_opt) == 1 && type_compat_strict(TI_INT, t4_str_opt) == 0), 1);
    // ⑤ 注册表/许可：null 与可选行都**不是**单一原子类 ⇒ -1（门全拒）。
    //    R2 P4 Task 3 重定（原判据「AK_NULL 无条目」随扩列翻转）：AK_NULL **有条目**
    //    （第 14 行，可查询性面）但 ops = 0 ⇒ 操作门仍全拒——保守面由「无条目」换位到
    //    「条目 + 零许可位」（同一行为、更可查询）；条目数 13 → 16（扩列硬值）。
    total = total + 1; fails = fails + ts_check("t4.null_no_ops_no_entry",
        (iface_kind_of(t4_null) == -1 && iface_kind_of(t4_int_opt) == -1 &&
         iface_permits(-1, OP_ADD) == 0 && iface_entry(AK_NULL) >= 0 &&
         iface_ops(AK_NULL) == 0 && iface_permits(AK_NULL, OP_ADD) == 0 && iface_count() == 16), 1);
    // ⑥ AK_NULL 互斥公理全表（13 类逐类）：除 AK_DYN（⊤ 相容规则）与自身外皆不相交
    t4_dj : ., mut = 0;
    t4_k : ., mut = 0;
    t4_aks := alloc(13 * 8);
    w64(t4_aks, 0 * 8, AK_INT); w64(t4_aks, 1 * 8, AK_DEX); w64(t4_aks, 2 * 8, AK_STRING);
    w64(t4_aks, 3 * 8, AK_BOOL); w64(t4_aks, 4 * 8, AK_UNIT); w64(t4_aks, 5 * 8, AK_NEVER);
    w64(t4_aks, 6 * 8, AK_CHAR); w64(t4_aks, 7 * 8, AK_DYN); w64(t4_aks, 8 * 8, AK_PRODUCT);
    w64(t4_aks, 9 * 8, AK_SUM); w64(t4_aks, 10 * 8, AK_SEQUENCE); w64(t4_aks, 11 * 8, AK_REF);
    w64(t4_aks, 12 * 8, AK_PTR);
    loop {
        if t4_k >= 13 { break; }
        ka := r64(t4_aks, t4_k * 8);
        want : ., mut = 1;
        if ka == AK_DYN { want = 0; }          // AK_DYN = ⊤：与一切相容（含 null）——登记
        if ak_disjoint(AK_NULL, ka) != want { t4_dj = t4_dj + 1; }
        t4_k = t4_k + 1;
    }
    total = total + 1; fails = fails + ts_check("t4.ak_null_disjoint_table",
        (t4_dj == 0 && ak_disjoint(AK_NULL, AK_NULL) == 0 && ak_disjoint(AK_NULL, AK_NAMED) == 1), 1);
    // ⑦ match 域面：可选域 = 两分支（有值 = Some 模式 / null = None 模式）
    t4_some_pat := alloc_node(EXPR_ENUMPAT, str_intern("Some"), 0, 0, 0, 0, 0, 0, 0);
    t4_none_pat := alloc_node(EXPR_ENUMPAT, str_intern("None"), 0, 0, 0, 0, 0, 0, 0);
    t4_other_pat := alloc_node(EXPR_ENUMPAT, str_intern("Red"), 0, 0, 0, 0, 0, 0, 0);
    t4_qual_pat := alloc_node(EXPR_ENUMPAT, str_intern("Option.Some"), 0, 0, 0, 0, 0, 0, 0);
    t4_some_t := sh_match_opt_term(t4_int_opt, sh_match_opt_pat(t4_int_opt, t4_some_pat));
    t4_none_t := sh_match_opt_term(t4_int_opt, sh_match_opt_pat(t4_int_opt, t4_none_pat));
    t4_full := tt_cons(t4_some_t, tt_cons(t4_none_t, tt_nil()));
    total = total + 1; fails = fails + ts_check("t4.match_opt_two_branch_cover",
        (t4_some_t == t4_intt && t4_none_t == t4_nullt &&
         sh_match_exhaustive(t4_int_opt, t4_full, 0) == 1 &&
         sh_match_exhaustive(t4_int_opt, tt_cons(t4_some_t, tt_nil()), 0) == 0 &&
         sh_match_exhaustive(t4_int_opt, tt_cons(t4_none_t, tt_nil()), 0) == 0), 1);
    total = total + 1; fails = fails + ts_check("t4.match_opt_counterexample_naming",
        (sh_match_first_missing(sh_match_bit(0), 2) == 1 &&
         sh_match_first_missing(sh_match_bit(1), 2) == 0 &&
         sh_match_first_missing(0, 2) == 0), 1);
    total = total + 1; fails = fails + ts_check("t4.match_opt_wildcard_and_guards",
        (sh_match_exhaustive(t4_int_opt, tt_cons(tt_top(), tt_nil()), 0) == 1 &&
         sh_match_exhaustive(t4_int_opt, t4_full, 1) == -1 &&
         sh_match_exhaustive(TI_INT, t4_full, 0) == -1 &&
         sh_match_domain_term(TI_INT) == -1 && sh_match_domain_term(t4_str_opt) >= 0), 1);
    total = total + 1; fails = fails + ts_check("t4.opt_pat_mapping",
        (sh_match_opt_pat(t4_int_opt, t4_some_pat) == 0 && sh_match_opt_pat(t4_int_opt, t4_none_pat) == 1 &&
         sh_match_opt_pat(t4_int_opt, t4_other_pat) == -1 && sh_match_opt_pat(t4_int_opt, t4_qual_pat) == -1 &&
         sh_match_opt_pat(TI_INT, t4_none_pat) == -1), 1);
    total = total + 1; fails = fails + ts_check("t4.opt_domain_leaf_count",
        (ts_unf_union_leaves(sh_match_domain_term(t4_int_opt)) == 2 &&
         ts_unf_union_leaves(sh_match_domain_term(t4_str_opt)) == 2), 1);
    // ⑧ 枚举载荷类型节点列（T0 交接 ① 的消费面：sh_variant_payload_term）
    t4_p_ei := add_enum("T4Payload");
    ei_set_variant_name(t4_p_ei, 0, str_intern("T4Tag"));
    // 变体 1：**裸码槽 = 0（= TY_INT，旧布局的全部信息）而节点列 = string** —— 节点列才是真值
    ei_set_variant_name(t4_p_ei, 1, str_intern("T4Str"));
    ei_set_variant_type_count(t4_p_ei, 1, 1);
    ei_set_variant_type(t4_p_ei, 1, 0, TY_INT);
    ei_set_variant_type_node(t4_p_ei, 1, 0, alloc_node(0, 0, 0, 0, 0, TY_STRING, 0, 0, 0));
    w64(g_enums, t4_p_ei * ESZ_ENUMINFO + OFF_EI_VARIANT_COUNT, 2);
    t4_p_ti := alloc_named_type(str_intern("T4Payload"));
    total = total + 1; fails = fails + ts_check("t4.payload_node_beats_bare_code",
        (sh_variant_payload_term(t4_p_ti, str_intern("T4Str")) == sh_term_of_ti(TI_STR) &&
         ty_disjoint(sh_variant_payload_term(t4_p_ti, str_intern("T4Str")), t4_intt) == 1 &&
         sh_variant_payload_term(t4_p_ti, str_intern("T4Tag")) == -1 &&
         sh_variant_payload_term(t4_p_ti, str_intern("T4Nope")) == -1), 1);
    // ⑨ 载荷泛型代入：`enum T4GP[T] { T4S(T) }` 的 apply 行取实参项；两实例不同
    t4_g_ei := add_enum("T4GP");
    w64(g_enums, t4_g_ei * ESZ_ENUMINFO + OFF_EI_GENERIC_COUNT, 1);
    w64(g_enums, t4_g_ei * ESZ_ENUMINFO + OFF_EI_GENERIC_NAMES, str_intern("T4GT"));
    ei_set_variant_name(t4_g_ei, 0, str_intern("T4GS"));
    ei_set_variant_type_count(t4_g_ei, 0, 1);
    ei_set_variant_type(t4_g_ei, 0, 0, TY_INT);
    ei_set_variant_type_node(t4_g_ei, 0, 0, alloc_node(EXPR_IDENT, 0, 0, 0, str_intern("T4GT"), 0, 0, 0, 0));
    w64(g_enums, t4_g_ei * ESZ_ENUMINFO + OFF_EI_VARIANT_COUNT, 1);
    t4_g_ti := alloc_named_type(str_intern("T4GP"));
    grow_gen_apply_data(g_gen_apply_data_count + 2);
    t4_gs := g_gen_apply_data_count;
    w64(g_gen_apply_data, t4_gs * 8, 1);
    w64(g_gen_apply_data, (t4_gs + 1) * 8, TI_INT);
    g_gen_apply_data_count = t4_gs + 2;
    t4_g_ga := alloc_type(TYP_GENERIC_APPLY, t4_g_ti, t4_gs);
    grow_gen_apply_data(g_gen_apply_data_count + 2);
    t4_gs2 := g_gen_apply_data_count;
    w64(g_gen_apply_data, t4_gs2 * 8, 1);
    w64(g_gen_apply_data, (t4_gs2 + 1) * 8, TI_STR);
    g_gen_apply_data_count = t4_gs2 + 2;
    t4_g_ga2 := alloc_type(TYP_GENERIC_APPLY, t4_g_ti, t4_gs2);
    total = total + 1; fails = fails + ts_check("t4.payload_generic_subst",
        (sh_variant_payload_term(t4_g_ga, str_intern("T4GS")) == sh_term_of_ti(TI_INT) &&
         sh_variant_payload_term(t4_g_ga2, str_intern("T4GS")) == sh_term_of_ti(TI_STR) &&
         sh_variant_payload_term(t4_g_ga, str_intern("T4GS")) != sh_variant_payload_term(t4_g_ga2, str_intern("T4GS"))), 1);
    // ⑩ 退役面：`Option` 名在类型表**零行**（内建注册已退役；用户声明才建行）
    total = total + 1; fails = fails + ts_check("t4.option_not_registered",
        (named_dedup_rows(str_intern("Option")) == 0 && find_gsym(str_intern("Option")) < 0), 1);

    // R2 P3 Task 5 段（用例体在 ts_t5_run——见该函数头注「不得内联」）
    total = total + 9; fails = fails + ts_t5_run();

    // R2 P3b Task 0 段（用例体在 ts_isat_run——同上，不得内联）
    total = total + 16; fails = fails + ts_isat_run();

    // R2 P3b Task 2 段（用例体在 ts_x2_run——同上，不得内联；16 例 = 原 15 + R2 P4
    // Task 3 新增 x2.shape_builtin_names）
    total = total + 16; fails = fails + ts_x2_run();
    // R2 P3b Task 6：impl 契约（签名类型项化 / 形状项 / mangling 退役 / 三态）——见 ts_ifc_run
    total = total + 14; fails = fails + ts_ifc_run();

    // R2 P5 Task 3：命名面判定化（身份链 + 可判定面加强 + 域外守卫）——见 ts_t3n_run
    // （残留面 1 例已迁至 t3b 段 ⇒ 本段 19 → 18）
    total = total + 18; fails = fails + ts_t3n_run();

    // R2 P5 Task 3b：不变槽元素三态（te_elem_cmp）——见 ts_t3b_run（13 例）
    total = total + 13; fails = fails + ts_t3b_run();

    // R2 P5 Task 4：残留 -1 政策 P-A（ICE04 硬错；桥接缺口 / 引擎未覆盖面 / 决定面零误报）
    // ——见 ts_t4_run（3 例）
    total = total + 3; fails = fails + ts_t4_run();

    // R2 P6 Task 2（E-10）：¬ 面同类原子身份判据邻域覆盖——见 ts_t2_neg_run（9 例）
    total = total + 11; fails = fails + ts_t2_neg_run();

    // R2 P4 Task 2：TYPE 段内容面（装填/roundtrip/dedup/确定性/拒绝面）——见 ts_ccr_run
    // R2 P4 Task 3：IFACE 段内容面（五小节往返/签名项槽/形状名注册面/条目扩列/判定面
    // 零变化/不可建签名拒绝）——见 ts_ccr2_run（**必须最后**：populate 复位项层/引擎/
    // 桥接三面缓存；两段共用同一装填入口）
    // （R2 P4 Task 4 的 7 例已在前段 bridge 节内联——见 t4.tk_* 注释。）
    total = total + 5; fails = fails + ts_ccr_run();
    total = total + 8; fails = fails + ts_ccr2_run();

    print(int_str(total - fails)); print("/"); print(int_str(total)); println(" type-engine cases passed");
    if fails != 0 { return 1; }
    return 0;
}
