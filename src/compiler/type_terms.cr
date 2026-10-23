// === type_terms.cr ===
// Type-term table: a DAG with set semantics.
// τ ::= ⊥ | ⊤ | ⊤k | τ1 ∪ τ2 | τ1 ∩ τ2 | ¬τ | μX.τ | X | k(τ1...τn)
// Entry is 48B {tag, a, b, c, d, hash}. Structurally equal terms share a node
// (DAG). The index is open addressing in g_tt_index.
// This file provides representation and construction dedup. Semantic judgment is
// in type_engine.cr; NNF and DNF normalization are here.
// Hashing uses the FNV-1 addition fold because Core has no xor operator. Slots are
// normalized non-negative with tt_mod. The key compares all five fields; the hash
// only locates a slot.

// ─── 标签常量（TT_*；与 ast.cr 的 TI_* 类型 kind 无关，本层是类型项语言）───
TT_BOT : int = 0
TT_TOP : int = 1
TT_TOP_K : int = 2
TT_UNION : int = 3
TT_INTER : int = 4
TT_NOT : int = 5
TT_MU : int = 6
TT_ATOM : int = 7
TT_VAR : int = 8
TT_NIL : int = 9
TT_CONS : int = 10

// 条目布局常量（ESZ_TYPE_TERM、OFF_TT_*）在 ccr_schema.cr。条目为六字段各 8B
// （与 g_ir_entries 同风格：字节缓冲 + 偏移常量）。

// Disk term record in TYPE(7): 5 * i64 = 40B {tag, a, b, c, d}. The in-memory
// hash slot is omitted because it is a pure function of the five fields; the
// loader recomputes it with tt_hash5. Field width is 8B, matching memory.

// ─── 访问器（i = 类型项行号；调用方保证 0 ≤ i < tt_count()）───
fn tt_tag(i: int) -> int:
    return r64(g_type_terms, i * ESZ_TYPE_TERM + OFF_TT_TAG)
fn tt_a(i: int) -> int:
    return r64(g_type_terms, i * ESZ_TYPE_TERM + OFF_TT_A)
fn tt_b(i: int) -> int:
    return r64(g_type_terms, i * ESZ_TYPE_TERM + OFF_TT_B)
fn tt_c(i: int) -> int:
    return r64(g_type_terms, i * ESZ_TYPE_TERM + OFF_TT_C)
fn tt_d(i: int) -> int:
    return r64(g_type_terms, i * ESZ_TYPE_TERM + OFF_TT_D)
fn tt_count() -> int:
    return g_type_term_count

// TT_ATOM with b >= 0 returns b, the type row of the atom. Everything else
// (union, product, mu, empty chain, negative b) returns -1, meaning not a single
// atom. Never approximate and never return 0.
fn tt_atom_of_term(term: int) -> int:
    if term < 0 || term >= tt_count():
        return -1
    if tt_tag(term) != TT_ATOM:
        return -1
    if tt_b(term) < 0:
        return -1
    return tt_b(term)

// ─── 结构哈希（DAG 去重的键：五字段 fold，与插入顺序无关）───
fn tt_hash5(tag: int, a: int, b: int, c: int, d: int) -> int:
    h : ., mut = 1469598103934665603
    slot : ., mut = 0
    loop:
        if slot >= 5:
            break
        v : ., mut = tag
        if slot == 1:
            v = a
        else if slot == 2:
            v = b
        else if slot == 3:
            v = c
        else if slot == 4:
            v = d
        k : ., mut = 0
        loop:
            if k >= 8:
                break
            byte : ., mut = v % 256
            if byte < 0:
                byte = -byte
            h = h * 1099511628211 + byte
            v = v / 256
            k = k + 1
        slot = slot + 1
    return h

// Non-negative slot. Do not use h - (h/cap)*cap: i64 division truncates toward
// zero, so a negative h produces a negative index and the probe walks out of
// bounds. Take the remainder first, then absolute value. The capacity is always a
// power of two (see grow_tt_index), so |h % cap| < cap <= 2^63 and negation does
// not overflow.
fn tt_mod(h: int, cap: int) -> int:
    m : ., mut = h % cap
    if m < 0:
        m = 0 - m
    return m

// Growth lives here, not in dyn_arr.cr. dyn_arr.cr is shared with corearch, and
// an engine symbol there would fail corearch resolution. type_terms.cr is linked
// into corec, corearch, and corelsp, so the engine can own these grow functions
// and constants without changing the shared surface.
fn grow_type_terms(needed: int):
    if needed < g_type_term_cap:
        return
    nc : ., mut = g_type_term_cap * 2
    if nc < 256:
        nc = 256
    if nc < needed:
        nc = needed + 64
    nb := alloc(nc * ESZ_TYPE_TERM)
    _dyncpy(g_type_terms, g_type_term_cap * ESZ_TYPE_TERM, nb)
    g_type_terms = nb
    g_type_term_cap = nc

fn grow_tt_index(needed: int):
    // Open addressing index. Capacity is a power of two and at least twice the
    // current term count. The 2x rule is required because tt_reindex replays
    // inserts without a load-factor guard; a table sized only by needed could loop
    // forever when replaying a table that is already too full.
    if needed < g_tt_index_cap:
        return
    nc : ., mut = 1024
    need2 : ., mut = needed
    if (g_type_term_count + 1) * 2 > need2:
        need2 = (g_type_term_count + 1) * 2
    loop:
        if nc >= need2:
            break
        nc = nc * 2
    nb := alloc(nc * 8)
    i : ., mut = 0
    loop:
        if i >= nc:
            break
        w64(nb, i * 8, -1)
        i = i + 1
    g_tt_index = nb
    g_tt_index_cap = nc
    g_tt_index_count = 0
    tt_reindex()

// ─── 索引重建（grow_tt_index 扩容后调用：清表 + 重放全部项的开放寻址插入）───
fn tt_reindex():
    i : ., mut = 0
    loop:
        if i >= g_type_term_count:
            break
        h := r64(g_type_terms, i * ESZ_TYPE_TERM + OFF_TT_HASH)
        cap := g_tt_index_cap
        p : ., mut = tt_mod(h, cap)
        loop:
            if r64(g_tt_index, p * 8) < 0:
                break
            p = p + 1
            if p >= cap:
                p = 0
        w64(g_tt_index, p * 8, i)
        g_tt_index_count = g_tt_index_count + 1
        i = i + 1

// Reset the term layer. Clear counts, the index, and lazy memos. Setting
// g_tt_index_cap = 0 makes the next tt_term call grow_tt_index(2), which rebuilds
// an empty index. g_tt_top_ok and g_tt_nil_ok = 0 re-fetch the lazy top and nil
// terms; if the rebuilt table already has them, dedup finds the same nodes.
// Buffers are not freed; capacity is reused on rebuild or load.
// Engine state is reset here too (budget, memo, literals), because it belongs to
// the same term-row namespace. type_engine.cr is not in the corearch manifest, so
// this function writes the globals directly.
// Callers (ccr_types.cr fill or ccr_io.cr load) must also reset the bridge caches
// sh_map_reset and sh_unf_map_reset on the corec side; stale ti-to-term caches
// hold old row semantics.
fn tt_layer_reset():
    g_type_term_count = 0
    g_tt_index_cap = 0
    g_tt_index_count = 0
    g_tt_top_ok = 0
    g_tt_nil_ok = 0
    tt_budget_state_reset()
    g_ty_memo_ok = 0
    g_ty_memo_cap = 0
    g_ty_lits_count = 0

// 预算/未覆盖位复位（不动项表）：--dump-types 的 probe 在表已载入后跑项层
// 原语（tt_norm，规范化计步），两侧（写侧进程/读侧进程）须从同一计数起点出发
// 才能对拍消耗与结果。
fn tt_budget_state_reset():
    g_ty_steps = 0
    g_ty_budget_max = 200000
    g_ty_exhausted = 0
    g_ty_uncovered = 0

// 同构比较（五字段全比，DAG 键；哈希相同与否不参与，见 tt_term 内注记）
fn tt_same(i: int, j: int) -> int:
    if tt_tag(i) != tt_tag(j):
        return 0
    if tt_a(i) != tt_a(j):
        return 0
    if tt_b(i) != tt_b(j):
        return 0
    if tt_c(i) != tt_c(j):
        return 0
    if tt_d(i) != tt_d(j):
        return 0
    return 1

// ─── 构造/复用（DAG 去重的唯一入口）───
fn tt_term(tag: int, a: int, b: int, c: int, d: int) -> int:
    if g_tt_index_cap <= 0:
        grow_tt_index(2)
    h := tt_hash5(tag, a, b, c, d)
    ret : ., mut = -1
    loop:
        // 装填因子检查：探测前扩容（扩容 = 重建索引，故探测位置不会中途失配）；
        // 扩容后重试同一轮（loop 而非递归，避免深递归与重复增长）。
        if (g_type_term_count + 1) * 2 >= g_tt_index_cap:
            grow_tt_index((g_type_term_count + 1) * 2)
        cap := g_tt_index_cap
        p : ., mut = tt_mod(h, cap)
        loop:
            idx := r64(g_tt_index, p * 8)
            if idx < 0:
                break
            // Key comparison uses all five fields. The stored hash is not part of
            // the key: it only locates the slot. Hash collisions only lengthen the
            // probe chain and do not change the result.
            if tt_tag(idx) == tag && tt_a(idx) == a && tt_b(idx) == b && tt_c(idx) == c && tt_d(idx) == d:
                ret = idx
                break
            p = p + 1
            if p >= cap:
                p = 0
        if ret >= 0:
            break
        // 未命中：追加新项，写入本轮探测到的空槽（轮内索引未被改动）
        grow_type_terms(g_type_term_count + 1)
        i := g_type_term_count
        w64(g_type_terms, i * ESZ_TYPE_TERM + OFF_TT_TAG, tag)
        w64(g_type_terms, i * ESZ_TYPE_TERM + OFF_TT_A, a)
        w64(g_type_terms, i * ESZ_TYPE_TERM + OFF_TT_B, b)
        w64(g_type_terms, i * ESZ_TYPE_TERM + OFF_TT_C, c)
        w64(g_type_terms, i * ESZ_TYPE_TERM + OFF_TT_D, d)
        w64(g_type_terms, i * ESZ_TYPE_TERM + OFF_TT_HASH, h)
        g_type_term_count = i + 1
        w64(g_tt_index, p * 8, i)
        g_tt_index_count = g_tt_index_count + 1
        ret = i
        break
    return ret

// ─── 构造 API ───
// 惰性 memo：0 = 未建 + ready 位（零初值惯例，全局 `= -1` 初值在 bootstrap
// 后端会被降级为 0，见 globals.cr 声明段注记）
fn tt_bot() -> int:
    return tt_term(TT_BOT, 0, 0, 0, 0)

fn tt_top() -> int:
    if g_tt_top_ok == 0:
        g_tt_top = tt_term(TT_TOP, 0, 0, 0, 0)
        g_tt_top_ok = 1
    return g_tt_top

fn tt_top_k(k: int) -> int:
    return tt_term(TT_TOP_K, k, 0, 0, 0)

fn tt_union(a: int, b: int) -> int:
    if a == b:
        return a
    if tt_tag(a) == TT_BOT:
        return b
    if tt_tag(b) == TT_BOT:
        return a
    if tt_tag(a) == TT_TOP || tt_tag(b) == TT_TOP:
        return tt_top()
    return tt_term(TT_UNION, a, b, 0, 0)

fn tt_inter(a: int, b: int) -> int:
    if a == b:
        return a
    if tt_tag(a) == TT_TOP:
        return b
    if tt_tag(b) == TT_TOP:
        return a
    if tt_tag(a) == TT_BOT || tt_tag(b) == TT_BOT:
        return tt_bot()
    return tt_term(TT_INTER, a, b, 0, 0)

fn tt_not(a: int) -> int:
    if tt_tag(a) == TT_BOT:
        return tt_top()
    if tt_tag(a) == TT_TOP:
        return tt_bot()
    if tt_tag(a) == TT_NOT:
        return tt_a(a)
    // 双重否定免费（构造代数规则）
    return tt_term(TT_NOT, a, 0, 0, 0)

fn tt_mu(v: int, body: int) -> int:
    return tt_term(TT_MU, v, body, 0, 0)
fn tt_var(v: int) -> int:
    return tt_term(TT_VAR, v, 0, 0, 0)

fn tt_nil() -> int:
    if g_tt_nil_ok == 0:
        g_tt_nil = tt_term(TT_NIL, 0, 0, 0, 0)
        g_tt_nil_ok = 1
    return g_tt_nil

fn tt_cons(head: int, tail: int) -> int:
    return tt_term(TT_CONS, head, tail, 0, 0)
fn tt_atom(ak: int, ti: int, params: int) -> int:
    return tt_term(TT_ATOM, ak, ti, params, 0)

// NNF (push negations) and DNF normalization.
// Normal form output is DNF (union of products; product is a set of literals).
// This layer only reshapes terms. Semantic judgment (coverage, equivalence,
// emptiness, counterexamples) is in type_engine.cr.

// 参数列表逐元素 NNF（ATOM 的 params = CONS 列表；-1 = 无参）
fn tt_nnf_list(p: int) -> int:
    if p < 0:
        return -1
    if tt_tag(p) != TT_CONS:
        return tt_nnf(p)
    return tt_cons(tt_nnf(tt_a(p)), tt_nnf_list(tt_b(p)))

// 正位置 NNF：结构不变，否定下推（¬(∪) -> ∩(¬)、¬(∩) -> ∪(¬)、¬¬ 消，均在负位置函数里）
fn tt_nnf(i: int) -> int:
    t := tt_tag(i)
    if t == TT_NOT:
        return tt_nnf_neg(tt_a(i))
    if t == TT_UNION:
        return tt_union(tt_nnf(tt_a(i)), tt_nnf(tt_b(i)))
    if t == TT_INTER:
        return tt_inter(tt_nnf(tt_a(i)), tt_nnf(tt_b(i)))
    if t == TT_MU:
        return tt_mu(tt_a(i), tt_nnf(tt_b(i)))
    if t == TT_ATOM:
        return tt_atom(tt_a(i), tt_b(i), tt_nnf_list(tt_c(i)))
    if t == TT_CONS:
        return tt_nnf_list(i)
    return i   // ⊥ / ⊤ / ⊤ₖ / VAR / NIL：字面，原样

// 负位置 NNF：计算 ¬i 的 NNF
fn tt_nnf_neg(i: int) -> int:
    t := tt_tag(i)
    if t == TT_BOT:
        return tt_top()
    if t == TT_TOP:
        return tt_bot()
    if t == TT_NOT:
        return tt_nnf(tt_a(i))
    // ¬¬i = i
    if t == TT_UNION:
        return tt_inter(tt_nnf_neg(tt_a(i)), tt_nnf_neg(tt_b(i)))
    if t == TT_INTER:
        return tt_union(tt_nnf_neg(tt_a(i)), tt_nnf_neg(tt_b(i)))
    if t == TT_MU:
        // ¬μX.F is not μX.¬F; the latter needs a ν binder. Do not rewrite to a
        // non-equivalent form: keep ¬(μ...) as a literal (tt_is_literal accepts it)
        // and mark the uncovered face. Judgment takes the conservative path.
        g_ty_uncovered = 1
        return tt_not(i)
    return tt_not(i)   // 字面取反：¬ATOM / ¬VAR / ¬⊤ₖ

// 参数列表逐元素 DNF（参数内的分配规则同样要做）
fn tt_dnf_list(p: int) -> int:
    if p < 0:
        return -1
    if tt_tag(p) != TT_CONS:
        return tt_dnf(p)
    return tt_cons(tt_dnf(tt_a(p)), tt_dnf_list(tt_b(p)))

// DNF：∩ 分配到 ∪ 上（(A∪B)∩C -> (A∩C)∪(B∩C)）；叶子 = product（交集表达式）或字面
// 全程计预算；-1 = 预算耗尽（上抛，不得当 0/形态用）
fn tt_dnf(i: int) -> int:
    if tt_step() == -1:
        return -1
    t := tt_tag(i)
    if t == TT_UNION:
        a1 := tt_dnf(tt_a(i))
        if a1 < 0:
            return -1
        b1 := tt_dnf(tt_b(i))
        if b1 < 0:
            return -1
        return tt_union(a1, b1)
    if t == TT_INTER:
        l := tt_dnf(tt_a(i))
        if l < 0:
            return -1
        r := tt_dnf(tt_b(i))
        if r < 0:
            return -1
        // Distribution must expand both sides: (A ∪ B) ∩ C becomes
        // (A ∩ C) ∪ (B ∩ C). Expanding only one side drops terms.
        if tt_tag(l) == TT_UNION:
            x := tt_dnf(tt_inter(tt_a(l), r))
            if x < 0:
                return -1
            y := tt_dnf(tt_inter(tt_b(l), r))
            if y < 0:
                return -1
            return tt_union(x, y)
        if tt_tag(r) == TT_UNION:
            x := tt_dnf(tt_inter(l, tt_a(r)))
            if x < 0:
                return -1
            y := tt_dnf(tt_inter(l, tt_b(r)))
            if y < 0:
                return -1
            return tt_union(x, y)
        return tt_inter(l, r)
    if t == TT_MU:
        b1 := tt_dnf(tt_b(i))
        if b1 < 0:
            return -1
        return tt_mu(tt_a(i), b1)
    if t == TT_ATOM:
        return tt_atom(tt_a(i), tt_b(i), tt_dnf_list(tt_c(i)))
    return i

// Budget step. Normalization also counts because distribution can grow terms
// exponentially; without counting, exhausted would stay 0 and the budget would
// have no effect.
fn tt_step() -> int:
    if g_ty_budget_max <= 0:
        g_ty_budget_max = 200000
    g_ty_steps = g_ty_steps + 1
    if g_ty_steps > g_ty_budget_max:
        g_ty_exhausted = 1
        return -1
    return 0

// 规范化入口（NNF -> DNF；DAG 去重使同形同项免费），-1 = 预算耗尽（调用方必须上抛）
fn tt_norm(i: int) -> int:
    n := tt_nnf(i)
    if n < 0:
        return -1
    return tt_dnf(n)

// ─── 形态判定（自测断言与引擎前置检查共用）───
fn tt_is_literal(i: int) -> int:
    t := tt_tag(i)
    if t == TT_ATOM || t == TT_VAR || t == TT_TOP_K || t == TT_BOT || t == TT_TOP:
        return 1
    if t == TT_NOT:
        it := tt_tag(tt_a(i))
        // NOT(MU) 亦为字面：¬μ 不下推动（见 tt_nnf_neg 的 MU 分支）
        if it == TT_ATOM || it == TT_VAR || it == TT_TOP_K || it == TT_MU:
            return 1
    return 0

fn tt_is_product_chain(i: int) -> int:
    if tt_tag(i) == TT_INTER:
        if tt_tag(tt_a(i)) == TT_UNION || tt_tag(tt_b(i)) == TT_UNION:
            return 0
        if tt_is_product_chain(tt_a(i)) == 0:
            return 0
        return tt_is_product_chain(tt_b(i))
    return tt_is_literal(i)

// DNF 成员：union 的子项 = product 或字面（不得再嵌 union）
fn tt_is_dnf_member(i: int) -> int:
    if tt_tag(i) == TT_UNION:
        return 0
    if tt_tag(i) == TT_INTER:
        return tt_is_product_chain(i)
    return tt_is_literal(i)

fn tt_is_dnf(i: int) -> int:
    // union is left-deep and tt_union does not flatten, so recursion must accept
    // n-ary disjunctions.
    if tt_tag(i) == TT_UNION:
        if tt_is_dnf(tt_a(i)) == 0:
            return 0
        return tt_is_dnf(tt_b(i))
    return tt_is_dnf_member(i)
