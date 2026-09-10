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

    print(int_str(total - fails)); print("/"); print(int_str(total)); println(" type-engine cases passed");
    if fails != 0 { return 1; }
    return 0;
}
