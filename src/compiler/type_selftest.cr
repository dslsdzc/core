// === type_selftest.cr ===
// R2 P0：类型项引擎判定用例表 + 自测驱动（`corec selftest-types`）。
// 判据：每例一行 PASS/FAIL，末行 "N/M type-engine cases passed"，rc=0 = 全过。
// 说明：本文件只依赖 type_terms.cr / type_engine.cr 的公开 API。
// 用例面分期：Task 1 = P0 最小 5 例（建层：表/DAG 去重/构造面代数律 + 桩判定）；
// Task 3/4 扩充为 spec §8 全类（子类型/等价/不相交/可空/反例/穷尽性/递归/参数化/预算），
// 同步抬 tests/selfhost/test_type_engine.py 的 MIN_CASES 到 20。

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
    total = total + 1; fails = fails + ts_check("equiv.absorb", ty_equiv(tt_union(a_int, a_int), a_int), 1);
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
    total = total + 1; fails = fails + ts_check("param.invariant_p0", ty_sub(seq_i, seq_s), 0);

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
    total = total + 1; fails = fails + ts_check("grow.count_40", (tt_count() >= before + 40), 1);
    total = total + 1; fails = fails + ts_check("grow.dedup_after_rebuild",
        (tt_atom(AK_PRODUCT, -1, tt_cons(tt_mu(0, a_int), tt_nil())) ==
         tt_atom(AK_PRODUCT, -1, tt_cons(tt_mu(0, a_int), tt_nil()))), 1);

    print(int_str(total - fails)); print("/"); print(int_str(total)); println(" type-engine cases passed");
    if fails != 0 { return 1; }
    return 0;
}
