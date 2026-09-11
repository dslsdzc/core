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
    w64(g_structs, sa * ESZ_STRUCTINFO + OFF_SI_FIELD_NAMES, str_intern("a"));
    w64(g_structs, sa * ESZ_STRUCTINFO + OFF_SI_FIELD_TYPES, TY_INT);
    w64(g_structs, sa * ESZ_STRUCTINFO + OFF_SI_FIELD_TYPE_NODES, alloc_node(0, 0, 0, 0, 0, TY_INT, 0, 0, 0));
    w64(g_structs, sa * ESZ_STRUCTINFO + OFF_SI_FIELD_COUNT, 1);
    return alloc_named_type(str_intern(name));
}

// 域项的析取支计数（「变体数」判据用）：只按引擎项形态走 union 树，**不与实现共享计数逻辑**
// （独立重算——否则同源同错自洽假绿）。⊥/单支 → 1。
fn ts_unf_union_leaves(t: int) -> int {
    if tt_tag(t) == TT_UNION { return ts_unf_union_leaves(tt_a(t)) + ts_unf_union_leaves(tt_b(t)); }
    return 1;
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
    // P0 不判变型（读视图协变 = P3）→ 同类不同参数 = **未知**（-1），不给确定 0
    // （P0 终审 Important B：确定 0 会与 spec §2.2 的 sequence<⊤> 正向判定冲突）
    total = total + 1; fails = fails + ts_check("param.unknown_p0", ty_sub(seq_i, seq_s), -1);
    // 未覆盖面位断言前**显式重置**（全局粘滞位，前面案例碰过 ¬μ 会误过——修复复审 N5）
    ty_budget_reset(200000);
    d_dummy := ty_sub(seq_i, seq_s);   // 重置后重新触发一次未覆盖面
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
    t_ref := sh_term_of_ti(alloc_type(TYP_REF, TI_STR, 0));
    total = total + 1; fails = fails + ts_check("bridge.ref_inner",
        (tt_a(t_ref) == AK_REF && tt_c(t_ref) == tt_cons(tt_atom(AK_STRING, TI_STR, -1), tt_nil())), 1);
    t_slice := sh_term_of_ti(alloc_type(TYP_SLICE, TI_STR, 0));
    total = total + 1; fails = fails + ts_check("bridge.slice_seq",
        (tt_a(t_slice) == AK_SEQUENCE && tt_c(t_slice) == tt_cons(tt_atom(AK_STRING, TI_STR, -1), tt_nil())), 1);
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
    // 缓存语义：新 ti 恰入表 1 条（其元素 = 原生快路径，不入表）；同 ti 二次调用恰命中 1 次
    e_before := sh_map_entries();
    arr_ti2 := alloc_type(TYP_ARRAY, TI_STR, 9);
    t_arr2 := sh_term_of_ti(arr_ti2);
    total = total + 1; fails = fails + ts_check("bridge.entries_delta", (sh_map_entries() - e_before), 1);
    h_before := sh_map_hits();
    t_arr2b := sh_term_of_ti(arr_ti2);
    total = total + 1; fails = fails + ts_check("bridge.hit_delta",
        ((sh_map_hits() - h_before) == 1 && t_arr2b == t_arr2), 1);
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
    total = total + 1; fails = fails + ts_check("bridge.grow_cap_doubled", (g_shadow_map_cap >= 2048), 1);
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
        (sh_map_entries() == g2_before + 1100 && g_shadow_map_cap >= 4096 && sh_term_of_ti(arr_ti2) == t_arr2), 1);

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
    // ② unknown 政策：两个**互异命名型**行 → 桥接 AK_NAMED 不展开 → 引擎 -1（未知）→
    //    **不得静默当 0/1**：回落 legacy（此处判 false）+ g_replace_unknown 恰 +1。
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
    t3_unknown_before := g_replace_unknown;
    t3_ub : ., mut = 0;
    if !type_equal(t3_na, t3_nb) {
        if (g_replace_unknown - t3_unknown_before) == 1 { t3_ub = 1; }
    }
    total = total + 1; fails = fails + ts_check("t3.unknown_fallback_legacy", t3_ub, 1);
    // 桥接缺口（sh_term_of_ti 译不成项：行号越界）→ 同样回落 legacy（判 false）+ 计数 g_replace_bridge
    t3_bridge_before := g_replace_bridge;
    t3_bf : ., mut = 0;
    if !type_equal(g_type_count + 100, TI_INT) {
        if (g_replace_bridge - t3_bridge_before) == 1 { t3_bf = 1; }
    }
    total = total + 1; fails = fails + ts_check("t3.bridge_fallback_legacy", t3_bf, 1);
    ty_budget_reset(200000);

    // --- R2 P2a Task 3 评审 Critical：桥接缓存**随类型表重置失效**（sh_map_reset）---
    // 机制：本批起判定路径**无条件**调 sh_term_of_ti（Task 3 前仅 --type-shadow 下）→ 桥接缓存
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
        (t3c_entries_mid >= 1 && t3c_entries_after == 0 && g_shadow_map_cap == 0), 1);
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
    // 覆盖面口径：13 条目 × 两向（ak→ti 行 / 行→ak 类）+ 11 个 API 逐签名；8 原生逐条目不抽样。
    init_types();
    total = total + 1; fails = fails + ts_check("iface.count", iface_count(), 13);
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
    // 判据 = **全表对拍**（非抽样）：生产入口（委托版）与 legacy 版（改动前实现的字面拷贝，
    // 仅存于此对拍面；ty_shadow.cr 注明 P5 删）逐格相同。只比「两版相等」会漏两类错——
    // 入口被换成第三个实现、两版一起错 ⇒ 另加③~⑥的**显式**断言（反真空/灰格/门/下标不 1:1）。
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
        if iface_by_ty_code(t2_code) != sh_base_ak_legacy(t2_code) { t2_ty_bad = t2_ty_bad + 1; }
        t2_i = t2_i + 1;
    }
    total = total + 1; fails = fails + ts_check("iface.by_ty_code_all_codes", t2_ty_bad, 0);
    // ② 行号面全表：逐 ti ∈ [0, g_type_count)（含 TI_DYN 行、TI_DEX_S 占位行与上方结构/命名行）
    t2_ti_bad : ., mut = 0;
    t2_j : ., mut = 0;
    loop {
        if t2_j >= g_type_count { break; }
        if sh_native_ak(t2_j) != sh_native_ak_legacy(t2_j) { t2_ti_bad = t2_ti_bad + 1; }
        t2_j = t2_j + 1;
    }
    total = total + 1; fails = fails + ts_check("iface.native_ak_all_rows", t2_ti_bad, 0);
    // ③ **反真空哨兵**（两处 loop 是本 Task 的判据本体，不得空转假绿）：
    //    ⓐ 扫描计数：码面 10 个键全扫过（且解码真读回写入值）；行面恰为 g_type_count 行且 ≥ 9；
    //    ⓑ 比较是活的：对**已知不等**的一对（未映射码 -1 vs TY_INT → AK_INT）必须报不等。
    total = total + 1; fails = fails + ts_check("iface.scan_coverage",
        (t2_i == 10 && r64(t2_codes, 56) == TY_GENERIC_PARAM && r64(t2_codes, 64) == TY_DEX_S &&
         t2_j == g_type_count && t2_j >= 9), 1);
    total = total + 1; fails = fails + ts_check("iface.compare_is_live",
        (iface_by_ty_code(999) == sh_base_ak_legacy(TY_INT)), 0);
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
    // ⑥ 条目面一致性（逐条目：`iface_ops(ak)` 必须回读该行的 ops 列；防「列未填/查错行」）
    o4_row_bad : ., mut = 0;
    o4_r : ., mut = 0;
    loop {
        if o4_r >= g_iface_entry_count { break; }
        o4_akr := r64(g_iface_entries, o4_r * ESZ_IFACE_ENTRY + OFF_IE_AK);
        if iface_ops(o4_akr) != r64(g_iface_entries, o4_r * ESZ_IFACE_ENTRY + OFF_IE_OPS) { o4_row_bad = o4_row_bad + 1; }
        if iface_ops(o4_akr) == 0 { o4_row_bad = o4_row_bad + 1; }   // 全 0 行 = 空集残留（Task 1 口径）
        o4_r = o4_r + 1;
    }
    total = total + 1; fails = fails + ts_check("ops.entry_row_consistent", o4_row_bad, 0);
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
    w64(g_structs, unf_box_sa * ESZ_STRUCTINFO + OFF_SI_FIELD_NAMES, str_intern("val"));
    w64(g_structs, unf_box_sa * ESZ_STRUCTINFO + OFF_SI_FIELD_TYPES, 0);   // 裸码槽 = parser 对非基型的塌缩值（0 = TY_INT；本层不读）
    w64(g_structs, unf_box_sa * ESZ_STRUCTINFO + OFF_SI_FIELD_TYPE_NODES,
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
    w64(g_structs, unf_p1_sa * ESZ_STRUCTINFO + OFF_SI_FIELD_NAMES, str_intern("a"));
    w64(g_structs, unf_p1_sa * ESZ_STRUCTINFO + OFF_SI_FIELD_TYPES, TY_INT);
    w64(g_structs, unf_p1_sa * ESZ_STRUCTINFO + OFF_SI_FIELD_TYPE_NODES, alloc_node(0, 0, 0, 0, 0, TY_INT, 0, 0, 0));
    w64(g_structs, unf_p1_sa * ESZ_STRUCTINFO + OFF_SI_FIELD_NAMES + 8, str_intern("b"));
    w64(g_structs, unf_p1_sa * ESZ_STRUCTINFO + OFF_SI_FIELD_TYPES + 8, TY_STRING);
    w64(g_structs, unf_p1_sa * ESZ_STRUCTINFO + OFF_SI_FIELD_TYPE_NODES + 8, alloc_node(0, 0, 0, 0, 0, TY_STRING, 0, 0, 0));
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
    w64(g_structs, unf_p2_sa * ESZ_STRUCTINFO + OFF_SI_FIELD_NAMES, str_intern("x"));
    w64(g_structs, unf_p2_sa * ESZ_STRUCTINFO + OFF_SI_FIELD_TYPES, 0);
    w64(g_structs, unf_p2_sa * ESZ_STRUCTINFO + OFF_SI_FIELD_TYPE_NODES, unf_arrn);
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
    total = total + 1; fails = fails + ts_check("unf.nominal_equiv_atomic_unknown",
        ty_equiv(sh_term_of_ti(unf_s1_ti), sh_term_of_ti(unf_s2_ti)), -1);
    unf_ru0 := g_replace_unknown;
    unf_eqf : ., mut = 0;
    if !type_equal(unf_s1_ti, unf_s2_ti) {
        if (g_replace_unknown - unf_ru0) == 1 { unf_eqf = 1; }
    }
    total = total + 1; fails = fails + ts_check("unf.nominal_type_equal_false", unf_eqf, 1);

    // 夹具 ⑤：enum UnfColorU { UnfRedU, UnfGreenU, UnfBlueU }（tag-only，3 变体）
    unf_col_ei := add_enum("UnfColorU");
    w64(g_enums, unf_col_ei * ESZ_ENUMINFO + OFF_EI_VARIANTS + 0 * OFF_EV_SIZE + OFF_EV_NAME, str_intern("UnfRedU"));
    w64(g_enums, unf_col_ei * ESZ_ENUMINFO + OFF_EI_VARIANTS + 1 * OFF_EV_SIZE + OFF_EV_NAME, str_intern("UnfGreenU"));
    w64(g_enums, unf_col_ei * ESZ_ENUMINFO + OFF_EI_VARIANTS + 2 * OFF_EV_SIZE + OFF_EV_NAME, str_intern("UnfBlueU"));
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
    w64(g_enums, unf_dup_ei * ESZ_ENUMINFO + OFF_EI_VARIANTS + OFF_EV_NAME, str_intern("UnfRedU"));
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
    w64(g_enums, unf_opt_ei * ESZ_ENUMINFO + OFF_EI_VARIANTS + 0 * OFF_EV_SIZE + OFF_EV_NAME, str_intern("UnfNoneU"));
    w64(g_enums, unf_opt_ei * ESZ_ENUMINFO + OFF_EI_VARIANTS + 1 * OFF_EV_SIZE + OFF_EV_NAME, str_intern("UnfSomeU"));
    w64(g_enums, unf_opt_ei * ESZ_ENUMINFO + OFF_EI_VARIANTS + 1 * OFF_EV_SIZE + OFF_EV_TYPE_COUNT, 1);
    w64(g_enums, unf_opt_ei * ESZ_ENUMINFO + OFF_EI_VARIANTS + 1 * OFF_EV_SIZE + OFF_EV_TYPES, TY_INT);   // 裸码槽（parser 事实；本层不读）
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

    // 接口面占位（P2b 未交付条目/满足关系、签名类型项化归 Task 6）：形状项与满足判定一律
    // 三态 -1——**不得**被消费方当 0/1 用。负键/越界键同律（断言在 Task 2/6 落地后仍成立）。
    total = total + 1; fails = fails + ts_check("unf.iface_stub_three_state",
        (sh_iface_shape_term(-1) == -1 && iface_satisfies(-1, 0) == -1 && iface_satisfies(TI_INT, 9999) == -1), 1);

    print(int_str(total - fails)); print("/"); print(int_str(total)); println(" type-engine cases passed");
    if fails != 0 { return 1; }
    return 0;
}
