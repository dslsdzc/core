// === type_engine.cr ===
// R2 P0：类型项判定引擎（语义包含 = 集合语义的值包含判定，spec §1/§3）。
// 三态约定（spec §3.3）：1 = 成立；0 = 不成立；**-1 = 预算耗尽/未覆盖**（禁止当 0 用）。
//
// 判定路线（P0 落地形态）：
//   规范化（tt_norm：NNF + DNF）→ 逐 product 覆盖 → 字面蕴含（含原子类互斥公理）
//   → μ 展开用「假设-判定」memo（余归纳：进行中的 (a,b) 记为真，标准递归子类型做法）
//   → 每步计预算，超限置 g_ty_exhausted 并返回 -1（不静默、不猜）。
//
// 未覆盖面（P0 显式登记，命中即 g_ty_uncovered = 1，不当作「不成立」）：
//   ① 参数化原子的**参数只在同形时判等**（变型规则 = P3 条目化后落地）；
//   ② AK_NAMED 的具体行不展开（命名类型的结构定义在 P2 接入 checker 后可用）；
//   ③ μ 的**空递归**（如 μX.X）保守判为可空。
//
// 原子类 id 与 g_types 行解耦（spec §1）：natives 1:1 映射，结构/命名原子挂 g_types 行
// （ti = -1 = 类级）。

// ─── 原子类 id（AK_*）───
AK_INT : int = 0;      AK_DEX : int = 1;     AK_STRING : int = 2;   AK_BOOL : int = 3;
AK_UNIT : int = 4;     AK_NEVER : int = 5;   AK_CHAR : int = 6;     AK_DYN : int = 7;
AK_PRODUCT : int = 8;  AK_SUM : int = 9;     AK_SEQUENCE : int = 10;
AK_REF : int = 11;     AK_PTR : int = 12;    AK_FN : int = 13;      AK_NAMED : int = 14;

// ─── 字面收集侧缓冲（product 的字面集）───
fn grow_ty_lits(needed: int) {
    if needed < g_ty_lits_cap { return; }
    nc : ., mut = g_ty_lits_cap * 2;
    if nc < 64 { nc = 64; }
    if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 8);
    _dyncpy(g_ty_lits, g_ty_lits_cap * 8, nb);
    g_ty_lits = nb;
    g_ty_lits_cap = nc;
}

fn ty_lits_reset() { g_ty_lits_count = 0; }

fn ty_lits_push(t: int) {
    if g_ty_lits_count + 1 > g_ty_lits_cap { grow_ty_lits(g_ty_lits_count + 1); }
    w64(g_ty_lits, g_ty_lits_count * 8, t);
    g_ty_lits_count = g_ty_lits_count + 1;
}

fn ty_lit_at(k: int) -> int { return r64(g_ty_lits, k * 8); }

// product（∩-链）或单字面 → 字面集（写 g_ty_lits）
fn lit_collect(i: int) {
    if tt_tag(i) == TT_INTER { lit_collect(tt_a(i)); lit_collect(tt_b(i)); return; }
    ty_lits_push(i);
}

// ─── 原子类互斥公理（P0 表：不同原子类两两不相交；AK_DYN = ⊤ 与一切相容）───
fn ak_disjoint(x: int, y: int) -> int {
    if x == y { return 0; }
    if x == AK_DYN || y == AK_DYN { return 0; }
    if x == AK_NEVER || y == AK_NEVER { return 1; }
    return 1;
}

// 字面的原子类（⊥/⊤/VAR 无类 → -1）
fn ty_ak_of(i: int) -> int {
    t := tt_tag(i);
    if t == TT_ATOM { return tt_a(i); }
    if t == TT_NOT && tt_tag(tt_a(i)) == TT_ATOM { return tt_a(tt_a(i)); }
    if t == TT_TOP_K { return tt_a(i); }
    return -1;
}

// ─── 字面矛盾判定（product 是否为空集的一阶判据）───
// 字面所属原子类（ATOM/⊤ₖ 正位置，及其否定）——-1 = 无类（VAR/复合/⊥/⊤）
fn lit_class_of(i: int) -> int {
    t := tt_tag(i);
    if t == TT_ATOM || t == TT_TOP_K { return tt_a(i); }
    if t == TT_NOT {
        it := tt_tag(tt_a(i));
        if it == TT_ATOM || it == TT_TOP_K { return tt_a(tt_a(i)); }
    }
    return -1;
}

fn lit_is_neg(i: int) -> int { if tt_tag(i) == TT_NOT { return 1; } return 0; }

// 单对字面是否互斥（⟦p⟧ ∩ ⟦q⟧ = ∅）——**规则要窄**：
//   正×正 异类 → ∅ ✓；正×负 **异类不空**（int ∩ ¬string = int ≠ ∅——P0 Task 4 自测实证
//   早期版本把这条写错，导致 witness 恒 -1）；正×¬⊤ₖ 同类 → ∅；负×负 永不空。
fn lit_empty_pair(p: int, q: int) -> int {
    if tt_tag(p) == TT_BOT || tt_tag(q) == TT_BOT { return 1; }
    if tt_not(q) == p { return 1; }                     // X ∧ ¬X
    pc := lit_class_of(p);
    qc := lit_class_of(q);
    if pc < 0 || qc < 0 { return 0; }
    pneg := lit_is_neg(p);
    qneg := lit_is_neg(q);
    if pneg == 0 && qneg == 0 { return ak_disjoint(pc, qc); }   // 正 × 正
    if pneg == 0 && qneg != 0 {
        if tt_tag(q) == TT_NOT && tt_tag(tt_a(q)) == TT_TOP_K && pc == qc { return 1; }
        return 0;
    }
    if pneg != 0 && qneg == 0 {
        if tt_tag(p) == TT_NOT && tt_tag(tt_a(p)) == TT_TOP_K && pc == qc { return 1; }
        return 0;
    }
    return 0;   // 负 × 负
}

// 独立缓冲版（避免侧缓冲互踩：sub_cover 需同时持有 p/q 两侧字面集）
fn lits_contradictory_buf(buf: int, n: int) -> int {
    i : ., mut = 0;
    loop {
        if i >= n { break; }
        p := r64(buf, i * 8);
        j : ., mut = i + 1;
        loop {
            if j >= n { break; }
            q := r64(buf, j * 8);
            if lit_empty_pair(p, q) == 1 { return 1; }
            j = j + 1;
        }
        i = i + 1;
    }
    return 0;
}

// 收集 product 的字面到独立缓冲，返回缓冲指针（元素数 = g_ty_lits_count）
fn lits_copy(p: int) -> int {
    ty_lits_reset();
    lit_collect(p);
    n := g_ty_lits_count;
    buf := alloc((n + 1) * 8);
    i : ., mut = 0;
    loop { if i >= n { break; } w64(buf, i * 8, ty_lit_at(i)); i = i + 1; }
    return buf;
}

fn lits_contradictory() -> int {
    return lits_contradictory_buf(g_ty_lits, g_ty_lits_count);
}

// ─── 字面蕴含（⟦lp⟧ ⊆ ⟦lq⟧）───
fn lit_implies(lp: int, lq: int) -> int {
    if lp == lq { return 1; }
    if tt_tag(lq) == TT_TOP { return 1; }
    if tt_tag(lp) == TT_BOT { return 1; }
    if tt_tag(lp) == TT_TOP { return tt_tag(lq) == TT_TOP; }
    // lq = ⊤ₖ
    if tt_tag(lq) == TT_TOP_K {
        k := tt_a(lq);
        if tt_tag(lp) == TT_TOP_K { return tt_a(lp) == k; }
        if tt_tag(lp) == TT_ATOM { return tt_a(lp) == k; }
        return 0;
    }
    // lq = ¬x：lp ⊆ ¬x ⟺ lp ∩ x = ∅
    if tt_tag(lq) == TT_NOT {
        x := tt_a(lq);
        if tt_tag(lp) == TT_NOT { return ty_sub(tt_a(lp), x); }   // ¬p ⊆ ¬x ⟺ x ⊆ p
        pk := ty_ak_of(lp);
        xk := ty_ak_of(x);
        if pk >= 0 && xk >= 0 && ak_disjoint(pk, xk) == 1 { return 1; }
        if tt_tag(x) == TT_BOT { return 1; }
        return 0;
    }
    // 双方皆正原子：同类 + 参数同形（P0：参数不变，见未覆盖面①）
    if tt_tag(lp) == TT_ATOM && tt_tag(lq) == TT_ATOM {
        if tt_a(lp) != tt_a(lq) { return 0; }
        if tt_b(lp) != tt_b(lq) { return 0; }
        return tt_list_same(tt_c(lp), tt_c(lq));
    }
    return 0;
}

// 参数链同形（P0：结构相等；变型 = P3）
fn tt_list_same(p: int, q: int) -> int {
    if p == q { return 1; }
    if p < 0 || q < 0 { return 0; }
    if tt_tag(p) != TT_CONS || tt_tag(q) != TT_CONS { return 0; }
    if tt_list_same(tt_a(p), tt_a(q)) == 0 { return 0; }
    return tt_list_same(tt_b(p), tt_b(q));
}

// ─── memo（假设-判定；0 = 假 / 1 = 真 / 2 = 进行中即假设真）───
fn grow_ty_memo(needed: int) {
    if needed < g_ty_memo_cap { return; }
    nc : ., mut = 1024;
    loop { if nc >= needed { break; } nc = nc * 2; }
    nb := alloc(nc * 16);
    i : ., mut = 0;
    loop { if i >= nc { break; } w64(nb, i * 16, -1); i = i + 1; }
    nv := alloc(nc * 8);
    i2 : ., mut = 0;
    loop { if i2 >= nc { break; } w64(nv, i2 * 8, 0); i2 = i2 + 1; }
    g_ty_memo_keys = nb;
    g_ty_memo_vals = nv;
    g_ty_memo_cap = nc;
    g_ty_memo_count = 0;
}

fn ty_memo_slot(a: int, b: int) -> int {
    if g_ty_memo_ok == 0 { grow_ty_memo(1024); g_ty_memo_ok = 1; }
    h : ., mut = (a * 31 + b) % g_ty_memo_cap;
    if h < 0 { h = 0 - h; }
    p : ., mut = h;
    loop {
        k := r64(g_ty_memo_keys, p * 16);
        if k < 0 { return p; }
        if k == a && r64(g_ty_memo_keys, p * 16 + 8) == b { return p; }
        p = p + 1; if p >= g_ty_memo_cap { p = 0; }
    }
}

fn ty_memo_state(slot: int) -> int {
    if r64(g_ty_memo_keys, slot * 16) < 0 { return -2; }   // 空槽（未占用）
    return r64(g_ty_memo_vals, slot * 8);
}

fn ty_memo_set(slot: int, a: int, b: int, v: int) {
    if r64(g_ty_memo_keys, slot * 16) < 0 {
        w64(g_ty_memo_keys, slot * 16, a);
        w64(g_ty_memo_keys, slot * 16 + 8, b);
        g_ty_memo_count = g_ty_memo_count + 1;
    }
    w64(g_ty_memo_vals, slot * 8, v);
}

// ─── μ 展开（代入）───
fn tt_subst_list(p: int, v: int, r: int) -> int {
    if p < 0 { return -1; }
    if tt_tag(p) != TT_CONS { return tt_subst(p, v, r); }
    return tt_cons(tt_subst(tt_a(p), v, r), tt_subst_list(tt_b(p), v, r));
}

fn tt_subst(i: int, v: int, r: int) -> int {
    t := tt_tag(i);
    if t == TT_VAR { if tt_a(i) == v { return r; } return i; }
    if t == TT_UNION { return tt_union(tt_subst(tt_a(i), v, r), tt_subst(tt_b(i), v, r)); }
    if t == TT_INTER { return tt_inter(tt_subst(tt_a(i), v, r), tt_subst(tt_b(i), v, r)); }
    if t == TT_NOT { return tt_not(tt_subst(tt_a(i), v, r)); }
    if t == TT_MU {
        if tt_a(i) == v { return i; }   // 内层同名 μ 遮蔽（避免捕获）
        return tt_mu(tt_a(i), tt_subst(tt_b(i), v, r));
    }
    if t == TT_ATOM { return tt_atom(tt_a(i), tt_b(i), tt_subst_list(tt_c(i), v, r)); }
    return i;
}

// ─── 预算守卫 ───
fn ty_budget_reset(limit: int) {
    g_ty_steps = 0;
    g_ty_budget_max = limit;
    g_ty_exhausted = 0;
    g_ty_uncovered = 0;
}

fn ty_exhausted() -> int { return g_ty_exhausted; }
fn ty_uncovered() -> int { return g_ty_uncovered; }

// ─── 覆盖判定：⟦p⟧ ⊆ ⟦q⟧（p/q 已规范化；q 可为 union）───
fn sub_cover(p: int, q: int) -> int {
    g_ty_steps = g_ty_steps + 1;
    if g_ty_steps > g_ty_budget_max { g_ty_exhausted = 1; return -1; }
    // μ 展开（左右各自）——**必须走 ty_sub_core（memo 入口）**：展开后的项对会重复出现，
    // 靠「进行中 = 假设成立」的余归纳终止（直接递归 sub_cover 会不收敛——Task 4 自测
    // rec.absorb 实证：μX.(int ∪ X) ≤ int 需要假设-判定才成立）。
    if tt_tag(p) == TT_MU { return ty_sub_core(tt_subst(tt_b(p), tt_a(p), p), q); }
    if tt_tag(q) == TT_MU { return ty_sub_core(p, tt_subst(tt_b(q), tt_a(q), q)); }
    if tt_tag(p) == TT_UNION {
        x := sub_cover(tt_a(p), q);
        if x != 1 { return x; }
        return sub_cover(tt_b(p), q);
    }
    if tt_tag(q) == TT_UNION {
        // p 被某个析取支覆盖即可；三态：任一为 1 → 1；全 0 → 0；含 -1 → -1
        x := sub_cover(p, tt_a(q));
        if x == 1 { return 1; }
        y := sub_cover(p, tt_b(q));
        if y == 1 { return 1; }
        if x == -1 || y == -1 { return -1; }
        return 0;
    }
    if tt_tag(q) == TT_TOP { return 1; }
    if tt_tag(p) == TT_BOT { return 1; }
    // p、q 皆 product（∩-链）或单字面：p 的字面集须覆盖 q 的每个字面
    bufp := lits_copy(p);
    pn := g_ty_lits_count;
    if lits_contradictory_buf(bufp, pn) == 1 { return 1; }   // p = ∅ ⊆ 一切
    bufq := lits_copy(q);
    qn := g_ty_lits_count;
    qi : ., mut = 0;
    loop {
        if qi >= qn { break; }
        lq := r64(bufq, qi * 8);
        covered : ., mut = 0;
        pi : ., mut = 0;
        loop {
            if pi >= pn { break; }
            lp := r64(bufp, pi * 8);
            if lit_implies(lp, lq) == 1 { covered = 1; break; }
            pi = pi + 1;
        }
        if covered == 0 { return 0; }
        qi = qi + 1;
    }
    return 1;
}

// ─── 顶层：包含（假设-判定 + memo + 预算）───
fn ty_sub_core(a: int, b: int) -> int {
    slot := ty_memo_slot(a, b);
    st := ty_memo_state(slot);
    if st == 2 { return 1; }            // 进行中 = 假设成立（余归纳）
    if st == 1 { return 1; }
    if st == 0 { return 0; }
    ty_memo_set(slot, a, b, 2);
    r := sub_cover(a, b);
    if r == -1 {
        // 预算耗尽的结果**不可缓存**（否则后续更大预算的调用会读到假 -1）——清槽
        w64(g_ty_memo_keys, slot * 16, -1);
        w64(g_ty_memo_vals, slot * 8, 0);
    } else {
        ty_memo_set(slot, a, b, r);
    }
    return r;
}

fn ty_sub(a: int, b: int) -> int {
    // 默认预算（未显式 ty_budget_reset 时可用；零初值下 g_ty_budget_max = 0 会让每次
    // 判定都「预算耗尽」→ 满屏 -1——P0 Task 3 自测实证）
    if g_ty_budget_max <= 0 { ty_budget_reset(200000); }
    if a == b { return 1; }
    n1 := tt_norm(a);
    n2 := tt_norm(b);
    if n1 == n2 { return 1; }
    if tt_tag(n2) == TT_TOP { return 1; }
    if tt_tag(n1) == TT_BOT { return 1; }
    return ty_sub_core(n1, n2);
}

fn ty_equiv(a: int, b: int) -> int {
    x := ty_sub(a, b);
    if x != 1 { return x; }
    y := ty_sub(b, a);
    if y != 1 { return y; }
    return 1;
}

// 可空性：DNF 下存在一个不矛盾 product
fn ty_inhabited(a: int) -> int {
    if g_ty_budget_max <= 0 { ty_budget_reset(200000); }
    n := tt_norm(a);
    return inh_any_at(n, 0);
}

// 深度守卫：μ 展开的**空递归**（如 μX.X）无可终止判据——超深即 -1 + 未覆盖面
// （登记：空递归保守判为不可判，不静默当 0/1）
fn inh_any(i: int) -> int { return inh_any_at(i, 0); }

fn inh_any_at(i: int, depth: int) -> int {
    if depth > 512 { g_ty_exhausted = 1; return -1; }
    if tt_tag(i) == TT_UNION {
        x := inh_any_at(tt_a(i), depth);
        if x == 1 { return 1; }
        y := inh_any_at(tt_b(i), depth);
        if y == 1 { return 1; }
        if x == -1 || y == -1 { return -1; }
        return 0;
    }
    if tt_tag(i) == TT_MU { return inh_any_at(tt_subst(tt_b(i), tt_a(i), i), depth + 1); }
    if tt_tag(i) == TT_BOT { return 0; }
    ty_lits_reset();
    lit_collect(i);
    // 本语言无三元运算符（`?:` 不合法——P0 Task 3 构建期实证）→ 显式分支
    if lits_contradictory() == 1 { return 0; }
    return 1;
}

// ─── 反例（witness）与穷尽性（Task 4）───
// witness = A\B 的规范化类型项；不可满足 → -1（= 无遗漏/无反例值）
fn tt_witness(a: int, b: int) -> int {
    r := tt_norm(tt_inter(a, tt_not(b)));
    if tt_tag(r) == TT_BOT { return -1; }
    x := ty_inhabited(r);
    if x != 1 { return -1; }
    return r;
}

// 穷尽 witness = domain \ ⋃patterns（patterns = CONS 链）
fn ty_exhaust_witness(domain: int, patterns: int) -> int {
    acc : ., mut = tt_bot();
    p : ., mut = patterns;
    loop {
        if p < 0 { break; }
        if tt_tag(p) != TT_CONS { break; }
        acc = tt_union(acc, tt_a(p));
        p = tt_b(p);
    }
    return tt_witness(domain, acc);
}

fn ty_exhaustive(domain: int, patterns: int) -> int {
    w := ty_exhaust_witness(domain, patterns);
    if g_ty_exhausted != 0 { return -1; }
    if w < 0 { return 1; }   // 补集空 = 穷尽
    return 0;
}

fn ty_disjoint(a: int, b: int) -> int {
    x := ty_inhabited(tt_inter(a, b));
    if x == -1 { return -1; }   // 三态传播：未知不得降级为 0
    if x == 0 { return 1; }
    return 0;
}
