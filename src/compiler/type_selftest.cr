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
    // 参数链（内层项）+ 两份同类分支不得互串（PTR/REF 是两条独立分支）
    t_ptr := sh_term_of_ti(alloc_type(TYP_PTR, TI_INT, 0));
    total = total + 1; fails = fails + ts_check("bridge.ptr_inner",
        tt_c(t_ptr), tt_cons(tt_atom(AK_INT, TI_INT, -1), tt_nil()));
    t_ref := sh_term_of_ti(alloc_type(TYP_REF, TI_STR, 0));
    total = total + 1; fails = fails + ts_check("bridge.ref_inner",
        (tt_a(t_ref) == AK_REF && tt_c(t_ref) == tt_cons(tt_atom(AK_STRING, TI_STR, -1), tt_nil())), 1);
    t_slice := sh_term_of_ti(alloc_type(TYP_SLICE, TI_STR, 0));
    total = total + 1; fails = fails + ts_check("bridge.slice_seq",
        (tt_a(t_slice) == AK_SEQUENCE && tt_c(t_slice) == tt_cons(tt_atom(AK_STRING, TI_STR, -1), tt_nil())), 1);
    // TYP_NAMED：AK_NAMED + 行号存 b 槽（引擎不展开 → 判定 UNKNOWN = P1 预期未覆盖面）
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

    print(int_str(total - fails)); print("/"); print(int_str(total)); println(" type-engine cases passed");
    if fails != 0 { return 1; }
    return 0;
}
