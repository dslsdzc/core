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
    // 字面量定型（查表入口 = 条目 lit_code 列；**当前实现 = infer_expr:1892-1897 的内联 if 链**）
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

    print(int_str(total - fails)); print("/"); print(int_str(total)); println(" type-engine cases passed");
    if fails != 0 { return 1; }
    return 0;
}
