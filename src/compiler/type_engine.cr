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
//   ① 参数化原子的参数位**变型规则** = R2 P3 Task 1 **已落地**（`ty_variance_of` +
//      `tt_list_variance`：AK_SEQUENCE/AK_PTR/AK_REF 三构造子）。**协变槽**已判（只读 ref
//      元素 = ty_sub 三态）；**不变槽的非同形参数** = R2 P5 Task 3b **已收口**（`te_elem_cmp`
//      三态：令牌按节点同一性 / 类型项按 ty_equiv ⇒ 确定不同回 0、仅域外回 -1——「链元素皆
//      类型项或身份令牌」的排序分派即 P0 登记时缺的那个不变量，见 tt_list_variance_at 注记）；
//   ② AK_NAMED 的具体行不展开（命名类型的结构定义在 P2 接入 checker 后可用）——
//      R2 P5 Task 3 **部分收口**：命名面按**身份链**判定（同链 1 / 链异 0 / 域外 -1，见
//      `te_named_pair` 头注）；**结构展开**仍不进判定面（P3a 反证：同形不同名 struct 判等）。
//      残留域外面 = 空链/位置错位/AK_NEVER·AK_DYN 混类（登记于 P5 Task 3 报告）；
//   ③ μ 的**空递归**（如 μX.X）保守判为可空。
//
// 原子类 id 与 g_types 行解耦（spec §1）：natives 1:1 映射，结构/命名原子挂 g_types 行
// （ti = -1 = 类级）。

// ─── 原子类 id（AK_*）───
AK_INT : int = 0;      AK_DEX : int = 1;     AK_STRING : int = 2;   AK_BOOL : int = 3;
AK_UNIT : int = 4;     AK_NEVER : int = 5;   AK_CHAR : int = 6;     AK_DYN : int = 7;
AK_PRODUCT : int = 8;  AK_SUM : int = 9;     AK_SEQUENCE : int = 10;
AK_REF : int = 11;     AK_PTR : int = 12;    AK_FN : int = 13;      AK_NAMED : int = 14;
// R2 P3 Task 4（联合/可选）：`null`（`None` 值的类型）——**原生第九员**，值域 = 单点。
// 语义（spec §5.4）：`T?` = `T ∪ null`（桥接侧把 TYP_OPTIONAL 行译作该原子与内层项之并）。
// 公理（ak_disjoint）：与一切异类原子**不相交**（含 AK_UNIT / AK_NEVER / AK_NAMED——null 不是
// 任何别的原子类；与 AK_DYN 保持 DYN 的相容规则）；自身相等（x == y 早退）。
// 可空：AK_NULL 是**有值**类型（唯一值 None）⇒ ty_inhabited = 1（引擎的 inh 只判字面矛盾，
// 无需特例）。无类型参数（ty_variance_of 落表外默认不变，链恒空）。
// 注册表：**不入 iface_registry 条目表**（IFACE_ENTRY_COUNT = 13 为 P2b 判据硬值；且本原子
// 无操作许可 —— 算术/逻辑/条件门对其全拒，正是期望行为）⇒ `iface_kind_of` 对承载行回 -1。
AK_NULL : int = 15;

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
    // R2 P3 Task 4：null 是**它自己的**单点原子类——与其余一切类不相交。位置在 AK_NEVER/
    // AK_NAMED 两条之前：与 NEVER 相交（两者都无公共值）；与 NAMED 的「不得断言互斥」无关
    // （NAMED 保守律针对的是「命名类型可能是任何结构类型」——null 不是结构类型，任何用户
    // 声明类型的值集里都不含 None 这个值 ⇒ 断互斥是**可断言**的，不违 P0 终审 Important B）。
    if x == AK_NULL || y == AK_NULL { return 1; }
    if x == AK_NEVER || y == AK_NEVER { return 1; }
    // AK_NAMED 的具体行不展开（未覆盖面②）→ **不得断言互斥**（P0 终审 Important B 实证：
    // named 可能是任何结构类型的别名，断言互斥即不可能断言）
    if x == AK_NAMED || y == AK_NAMED { return 0; }
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
fn lits_contradictory_buf(buf: string, n: int) -> int {
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

// 收集 product 的字面到独立缓冲，返回缓冲（元素数 = g_ty_lits_count）
// 返回型 = `string`：`alloc` 在类型模型里就是 `() -> string`（checker.cr 的 bi_add("alloc",
// TI_STR)），本值流转面也全按字节缓冲走（`r64`/`w64`/`lits_contradictory_buf` 皆收 string）
// ——旧声明 `-> int` 是真·类型洗白（TF01；check 作业 rc=1 划界之一，本批修）。
fn lits_copy(p: int) -> string {
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

// ═══════════ R2 P5 Task 3：命名面可判定域（身份链判定）═══════════
// 背景：AK_NAMED 原子原为**一律 -1**（未覆盖面②「命名行不展开」）⇒ 任何两个命名型比较都
// 回落 legacy（checker 的 g_replace_unknown）。本任务把**可判定**的命名面接进引擎：身份 =
// 桥接层构造的**身份链**（ty_shadow.cr 的 sh_named_identity_term / sh_apply_identity_term：
// `[名字令牌]` / `[基名令牌, 实参项…]`），**不是**结构性展开（P3a 实测反证：把展开项接进
// 等价面 ⇒ 同形不同名 struct 判等 + 推翻 P2a 归零基线，见 ty_shadow.cr 展开层头注）。
//
// 规则（三态；-1 = **适用域外**，调用方置 g_ty_uncovered 上抛——不得近似成 0/1）：
//   ① 链同（逐元素）⇒ 1；② 链异且两侧元素皆在可判定域内 ⇒ 0（确定不同）；
//   ③ 域外 ⇒ -1：空链（未覆盖面②的原形态：无身份的命名原子）/ 位置错位（令牌位放类型项或
//      反之）/ **AK_NEVER·AK_DYN** 的混类（⊥/⊤ 语义未在本层建模——"never ⊆ X"、"X ⊆ dyn"
//      不属本批，保持 -1；其余类 vs 命名型 ⇒ 0 = 名义型与异类原子不交，与 legacy 跨 kind
//      同结论）。
// 位置语义（链 = proper list；位置 0 = 身份令牌，位置 ≥ 1 = 泛型实参类型项）：
//   · 令牌位 → **节点同一性**（令牌不是类型集：拿 ty_equiv 比会把一切 AK_UNIT 令牌判等
//     ——P3 Task 1 实测的令牌碰撞类；见 tt_list_variance_at 注）；
//   · 实参位 → 引擎**自身的等价判定** ty_equiv（三态直传）——链元素是桥接构造的规范项
//     （同型 ⇒ 同节点），N 面（数组固定性 b 槽）经既有不变槽 b-忽略规则处理
//     （`[int;3]` 与 `[int;4]` 作实参仍判等 ✓）。
// 与 legacy 的口径对齐（等价面）：同链 ⇒ legacy 判 1；链异 ⇒ legacy 判 0。legacy 的判据 =
// kind 相同 + data 递归（命名行 data = 名字索引；named_dedup 使「同名 ⇔ 同行」⇒ 与令牌
// 同一性一致）。**已登记未编码角落**：本链不区分 kind（TYP_NAMED vs TYP_GENERIC_PARAM
// 同名 ⇒ 判等，legacy 按 kind 判否）——需同名跨类比较才可达，可达性未证实（P5 T3 报告 §）。
fn te_is_name_token(e: int) -> int {
    if e < 0 || e >= tt_count() { return 0; }
    if tt_tag(e) != TT_ATOM { return 0; }
    if tt_a(e) != AK_UNIT { return 0; }
    if tt_b(e) < 0 { return 0; }
    return 1;
}

// 实参位允许的项：类型项（原子/并/交/链/空链）。μ 变元/¬/裸值一律域外。
// 注：AK_UNIT 原子（原生 unit 类型项）**在**域内——它与令牌同形（b ≥ 0），本层不按键区分：
// 实参位比较走 ty_equiv（unit vs int ⇒ 类不同 ⇒ 0，与 legacy 同结论；令牌不会出现在实参位，
// 令牌位的比较另有 te_token_cmp）。
fn te_is_arg_term(e: int) -> int {
    if e < 0 || e >= tt_count() { return 0; }
    t := tt_tag(e);
    if t == TT_ATOM || t == TT_UNION || t == TT_INTER || t == TT_CONS || t == TT_NIL { return 1; }
    return 0;
}

// 位置 0（身份令牌）比较；调用方已保证 e1 != e2。差异 ⇒ 确定不同（名字令牌的身份 = 节点）。
fn te_token_cmp(e1: int, e2: int) -> int {
    if te_is_name_token(e1) != 0 && te_is_name_token(e2) != 0 { return 0; }
    return -1;      // 位置错位（非令牌）⇒ 域外，不猜
}

// 位置 ≥ 1（泛型实参类型项）比较：引擎等价（0/1/-1 直传）。
fn te_arg_cmp(e1: int, e2: int) -> int {
    if te_is_arg_term(e1) == 0 || te_is_arg_term(e2) == 0 { return -1; }
    return ty_equiv(e1, e2);
}

// 身份链比较（三态）：slot = 当前位置（0 = 令牌位）。链形不同 = 结构不同（proper list 前提：
// nil vs cons ⇒ 0；任一侧非链形（非 nil/cons）⇒ 域外 ⇒ -1）。
fn te_chain_cmp(slot: int, p: int, q: int) -> int {
    if p == q { return 1; }
    if p < 0 || q < 0 { return 0; }              // 空链 vs 非空链
    tp := tt_tag(p);
    tq := tt_tag(q);
    if tp != TT_CONS || tq != TT_CONS {
        if tp == TT_NIL || tq == TT_NIL { return 0; }
        return -1;
    }
    e1 := tt_a(p);
    e2 := tt_a(q);
    d : ., mut = 1;
    if e1 != e2 {
        if slot == 0 { d = te_token_cmp(e1, e2); } else { d = te_arg_cmp(e1, e2); }
    }
    if d == -1 { return -1; }
    if d == 0 { return 0; }
    return te_chain_cmp(slot + 1, tt_b(p), tt_b(q));
}

// ═══════════ R2 P5 Task 3b：不变槽元素比较（三态）═══════════
// 背景（P5 Task 3 §6 残留面，本步收口）：不变槽元素原为「结构同形（tt_type_elem_same）
// 否则 -1 + 未覆盖面」⇒ 元素是**已可判**的命名原子时（`[NA;2]` vs `[NB;2]`、`*NA` vs
// `*NB`、元组含异名元素）判不出 ⇒ 回落 legacy。本函数把「确定不同 ⇒ 0」从命名面扩到
// **全部不变槽元素**（native/struct/token）。适用域（三态；-1 = 域外 ⇒ 调用方上抛）：
//   ① 两侧皆**身份令牌**（`te_is_name_token`：AK_UNIT ∧ b ≥ 0，= sh_name_token /
//      sh_ref_mut_marker 的形态）⇒ **节点同一性**：不同节点 = 不同名字/标记 = 确定不同
//      （禁 ty_equiv：令牌不是类型集，同形不同名会被判等——P3 Task 1 实测的令牌碰撞类）；
//   ② 两侧皆**类型项**（te_is_arg_term）⇒ 引擎等价三态直传（`ty_equiv`）——命名/序列/
//      原生元素各按其自有的可判定域递归（域外在内层置位上抛，本层不吞）；
//   ③ 其余（任一侧**既非令牌也非类型项**：μ 变元 / ¬ / ⊤ₖ / 裸值…）⇒ -1 + 未覆盖面位（不猜）。
//      注：**排序错位**（名字/标记令牌 × 普通类型项，如 vs `int` 项）落 ②——令牌是 TT_ATOM，
//      按类型项面走 ty_equiv（异类原子不交 ⇒ 0，**不产生假等**）；AK_UNIT 类**内部**的混排
//      （令牌 × 原生 unit 项）落 ①（形态二义，见下）。
// 域内前提（同 (ak, slot) 上不出现排序混排——**构造点**保证，见 ty_shadow.cr 链构造段）：
//   AK_SUM（展开层变体项）链 = [枚举名令牌, 变体名令牌] ⇒ 槽 0/1 皆令牌 ⇒ ①；AK_REF 槽 0
//   （mut 标记）另有判定分支、槽 1 及其余构造子（SEQUENCE/PTR/PRODUCT/FN）链元素皆类型项
//   ⇒ ②；命名面链（AK_NAMED）先分派 te_named_pair，不经本函数。③ = **域外面**（可达：接口
//   形状面把 `⊤ₖ(序列)` 放进可写 ref 的不变槽 ⇒ 该槽无判据——守门例 `x2.rw_view_unexpressible`；
//   本步对该面**保持 -1**，未动），非「不可达防御分支」。
// ⚠ **AK_UNIT 形态二义**（登记）：原生 unit 类型项 = tt_atom(AK_UNIT, 行号, -1) 与令牌
//   同形（b ≥ 0）⇒ 两者结构不可分辨。选择「令牌先判」是**失效方向**要求：若走 ty_equiv，
//   token × unit 同类同形 ⇒ 判**等**（假等 = 令牌碰撞类）；先判令牌则最坏回 0 = 确定不同，
//   绝不产生假等。可达性：唯一原生 unit 项在 DAG 里**只有一个节点**（单行 + 去重）⇒ unit
//   × unit 恒同节点（快路径）；token × unit 需构造点在同一槽混排两排序——全构造点无此形态
//   （负控见 type_selftest.cr 的 t3b.* 段）。
fn te_elem_cmp(p: int, q: int) -> int {
    if p == q { return 1; }
    if te_is_name_token(p) != 0 && te_is_name_token(q) != 0 { return 0; }
    if te_is_arg_term(p) != 0 && te_is_arg_term(q) != 0 { return ty_equiv(p, q); }
    g_ty_uncovered = 1;
    return -1;
}

// 命名面成对判定（三态）：p/q 皆 TT_ATOM 且至少一侧 AK_NAMED（调用方保证）。
fn te_named_pair(pk: int, p: int, qk: int, q: int) -> int {
    if pk == qk {
        // 双方皆 AK_NAMED（同类 ∧ 至少一侧 NAMED）
        cp := tt_c(p);
        cq := tt_c(q);
        if cp < 0 || cq < 0 { return -1; }       // 空链 = 无身份（未覆盖面②原形态）⇒ 域外
        return te_chain_cmp(0, cp, cq);
    }
    // 名义型 × 异类原子：确定不同（legacy 跨 kind 同结论）。守卫：命名侧必须带身份链；
    // 异类侧不得是 AK_NEVER/AK_DYN（⊥/⊤ 语义未建模 ⇒ 域外，保持 -1）。
    if pk == AK_NAMED {
        if tt_c(p) < 0 { return -1; }
        if qk == AK_NEVER || qk == AK_DYN { return -1; }
        return 0;
    }
    if tt_c(q) < 0 { return -1; }
    if pk == AK_NEVER || pk == AK_DYN { return -1; }
    return 0;
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
        // ¬P ⊆ ¬X ⟺ **X ⊆ P**（逆否）——P0 终审 Critical 1：早期写成 ty_sub(P, X)（方向反），
        // 使 ¬A ⊆ ¬B 与 A ⊊ B 同时成立（自相矛盾）。
        if tt_tag(lp) == TT_NOT { return ty_sub(x, tt_a(lp)); }
        // ¬(μ…) 等无类字面：未知（登记，保守不覆盖）
        if lit_class_of(lp) < 0 || lit_class_of(x) < 0 {
            if tt_tag(x) == TT_BOT { return 1; }
            if tt_tag(lp) == TT_BOT { return 1; }
            g_ty_uncovered = 1;
            return -1;
        }
        pk := lit_class_of(lp);
        xk := lit_class_of(x);
        if pk == AK_NAMED || xk == AK_NAMED { g_ty_uncovered = 1; return -1; }   // 不展开 → 未知
        if ak_disjoint(pk, xk) == 1 { return 1; }
        return 0;
    }
    // 双方皆正原子：同类 + 参数链按**变型**比较（R2 P3 Task 1 取代 P0「仅同形判等」）
    if tt_tag(lp) == TT_ATOM && tt_tag(lq) == TT_ATOM {
        pk := tt_a(lp);
        qk := tt_a(lq);
        // R2 P5 Task 3：命名面（身份链）——取代原「AK_NAMED ⇒ 一律 -1」守卫。
        // 可判定域/域外三态见 te_named_pair 头注（P5 前此面 = unknown 清零对象）
        if pk == AK_NAMED || qk == AK_NAMED {
            d := te_named_pair(pk, lp, qk, lq);
            if d == -1 { g_ty_uncovered = 1; return -1; }
            return d;
        }
        if pk != qk { return 0; }
        lv := tt_list_variance(pk, tt_c(lp), tt_c(lq));
        if lv == 1 { return 1; }
        if lv == -1 { return -1; }     // 未知（不定槽的 ty_equiv 三态负值）：**上抛**，不得当 0
        // 确定不蕴含（不变槽查到确定不等价 / 协变槽 ty_sub 确定不成立 / 链形不同）：
        // P0 此处一律回 -1 + 未覆盖面（登记「参数仅同形判等」）——变型落地后它是**已判**面
        return 0;
    }
    return 0;
}

// 参数链同形（结构相等；R2 P3 Task 1 起为**变型表的默认槽比较**——不变槽即此恒等）
fn tt_list_same(p: int, q: int) -> int {
    if p == q { return 1; }
    if p < 0 || q < 0 { return 0; }
    if tt_tag(p) != TT_CONS || tt_tag(q) != TT_CONS { return 0; }
    if tt_list_same(tt_a(p), tt_a(q)) == 0 { return 0; }
    return tt_list_same(tt_b(p), tt_b(q));
}

// ─── R2 P3 Task 1：不变槽的「类型项相等」——序列项**固定性位（b）不入** ───
// 背景（本任务实测）：序列项的 b 槽是表示提示（N / 固定性，见 ty_shadow.cr 的 sh_seq_term），
// 但 b 会经**嵌套元素位的节点同一性**泄进判定：`[[int;3];2]` 的元素项（序列项）与
// `[[int];2]` 的元素项**除 b 外逐位相同却节点不同** ⇒ tt_list_same 判「非同形」⇒ 引擎回 -1
// （未覆盖面）⇒ 回落 legacy——① 身份路径出现 N/固定性（违 R1 不变量「N 只在常量档与表示层」）；
// ② 站点措辞从长度专属退化为普通不匹配（实测探针 pN3：`return [s, s]` 给
// 「Function return type mismatch」而非「Array length constraint not satisfied」）。
// 修法：**双方皆 AK_SEQUENCE 原子**时按「忽略 b 的结构相等」递归（元素仍可能是序列 ⇒ 继续
// 忽略）；**其余构造子一律节点同一性（tt_list_same）**——AK_NAMED 的 b = 行号是**身份**
// （[S] 与 [T] 必须不同）、令牌原子（AK_SUM 的 name 令牌 / AK_REF 的 mut 标记）的 b 也是身份。
// 守卫「皆 AK_SEQUENCE」使本函数**永不**解释令牌（令牌恒为 AK_UNIT 原子，见 sh_name_token /
// sh_ref_mut_marker）——旧约定（裸 name 索引入链）下的别名风险已随之消除。
fn tt_type_elem_same(p: int, q: int) -> int {
    if p == q { return 1; }
    if p < 0 || q < 0 { return 0; }
    if tt_tag(p) == TT_ATOM && tt_a(p) == AK_SEQUENCE &&
       tt_tag(q) == TT_ATOM && tt_a(q) == AK_SEQUENCE { return tt_seq_same(p, q); }
    return tt_list_same(p, q);
}

// 序列项相等（忽略 b）：class 相同 + 参数链逐元素递归（元素位经 tt_type_elem_same 再判定）。
fn tt_seq_same(p: int, q: int) -> int {
    if p == q { return 1; }
    cp := tt_c(p);
    cq := tt_c(q);
    if cp == cq { return 1; }
    if cp < 0 || cq < 0 { return 0; }
    if tt_tag(cp) != TT_CONS || tt_tag(cq) != TT_CONS { return 0; }
    if tt_type_elem_same(tt_a(cp), tt_a(cq)) != 1 { return 0; }
    return tt_type_elem_same(tt_b(cp), tt_b(cq));
}

// ═══════════════ R2 P3 Task 1：变型表（slot 单调性）+ 参数链按变型比较 ═══════════════
// 语义（spec §5.1）：只读视图**协变**（⟦槽a⟧ ⊆ ⟦槽b⟧ ⇒ 蕴含），可写视图**不变**（槽须等价）。
// 0 = 不变 / 1 = 协变。**其余构造子默认不变**（= P0 同形判等逐位保持）。
// 首版覆盖三构造子（计划 Task 1 Step 2 指定）：
//   · AK_SEQUENCE 槽 0（元素）= 不变：本语言数组/切片**可写**（实测探针 `s := a[0..3]; s[0] = 9;`
//     rc=0）⇒ 元素协变不健全（写坏是静默错值级）。定长退役的**方向**面（[T;N] <: [T]）不走本表：
//     N/固定性存于序列项的 **b 槽（标注，不入比较）**，方向由 checker 的 array_len_constraint_ok
//     承担（理由与参序约定见该函数注记——身份/子类型路径零 N 是 P2a 不变量）。
//   · AK_PTR 槽 0（元素）= 不变：可写裸指针（与 legacy 的 PTR 分支「只比元素」同语义）。
//   · AK_REF 槽 0 = **mut 标记**（不变，且比较**可判定**——标记是语法令牌非类型集，见
//     tt_list_variance_at）；槽 1（元素）= **只读协变 / 可写不变**：变型依赖槽 0 的值 ⇒ 静态
//     二元表表达不了该条件，故本表给只读侧（mut = 0）的默认值 1，可写侧由 tt_list_variance_at
//     依链首标记降为 0（**条件单点收敛在比较函数内**，本表不重复表达）。
fn ty_variance_of(ak: int, slot: int) -> int {
    if ak == AK_REF {
        if slot == 0 { return 0; }
        if slot == 1 { return 1; }
        return 0;
    }
    if ak == AK_SEQUENCE { return 0; }
    if ak == AK_PTR { return 0; }
    return 0;   // 表外构造子（含原生八员/命名类）：不变 = 现状结构相等
}

// 参数链按变型比较（lit_implies 的正原子同形面入口）。返回 1 / 0 / **-1 = 未知**（上抛）。
// 槽位语义（逐槽成对推进）：
//   · 协变槽 → ty_sub(槽a, 槽b)：三态直传（-1 上抛；0 = 确定不蕴含 ⇒ 0）；
//   · AK_REF 槽 0（mut 标记）→ **节点同一性且判定**：标记是**语法令牌**（不同标记 = 确定
//     不匹配 ⇒ **0**，不回 -1）——它**不是**类型集，故不适用「未知」保守性；回 -1 只会让
//     调用方回落 legacy 把同一结论重算一遍（mut 面 legacy 本就比 extra）。标记项 =
//     tt_atom(AK_UNIT, mut, -1)（b 槽 = 标记值，照 AK_NAMED 的 b = 行号同约定；见
//     ty_shadow.cr 的 sh_ref_mut_marker）。
//   · 其余不变槽 → 「同形（tt_type_elem_same）⇒ 同」，否则 **`te_elem_cmp` 三态**
//     （R2 P5 Task 3b 落地）：令牌按节点同一性 / 类型项按引擎等价 ⇒ 确定不同回 **0**（已判面）、
//     仅域外回 **-1 + 未覆盖面**（上抛）。⚠ 早期（P0~P5 T3）此处一律「非同形 ⇒ -1」的理由是
//     「链元素并非皆类型项」（展开层把身份令牌直接放链）——te_elem_cmp 的**排序分派**（先判
//     令牌、再判类型项）即该不变量，令牌不再被 ty_equiv 当术语解释（P3 Task 1 实测的令牌
//     碰撞类；M 改法红例 = 异枚举同名变体被判等），故加强面现在可安全落地。
// 同形快路径：p == q → 1（DAG 去重使「同形同项」恒为同一节点 ⇒ 主流路径零额外开销，且
// **改动前后逐位一致**）。链形不同（非 CONS / 负）→ 0（结构不同 = 现状语义）。
fn tt_list_variance_at(ak: int, slot: int, mutv: int, p: int, q: int) -> int {
    if p == q { return 1; }
    if p < 0 || q < 0 { return 0; }
    if tt_tag(p) != TT_CONS || tt_tag(q) != TT_CONS { return 0; }
    ha := tt_a(p);
    hb := tt_a(q);
    if ak == AK_REF && slot == 0 {
        if tt_list_same(ha, hb) != 1 { return 0; }     // 标记槽：可判定（见上）
    } else {
        v : ., mut = ty_variance_of(ak, slot);
        if ak == AK_REF && slot == 1 && mutv == 1 { v = 0; }   // 可写 ref：元素降为不变
        if v == 1 {
            s := ty_sub(ha, hb);
            if s != 1 { return s; }
        } else {
            if tt_type_elem_same(ha, hb) != 1 {
                // R2 P5 Task 3b：非同形 ⇒ 三态加强（确定不同 ⇒ 0；域外/内层未知 ⇒ -1 上抛，
                // 位由 te_elem_cmp / 内层置起——本层不吞、不改标）
                d := te_elem_cmp(ha, hb);
                if d == -1 { return -1; }
                if d == 0 { return 0; }
            }
        }
    }
    return tt_list_variance_at(ak, slot + 1, mutv, tt_b(p), tt_b(q));
}

fn tt_list_variance(ak: int, p: int, q: int) -> int {
    mutv : ., mut = 0;
    if ak == AK_REF {
        // 槽 0 已在调用前判定同形（p == q 快路径或由本函数逐槽比较）——此处只取标记值：
        // 链首 = 标记项（链形约定见 sh_ref_mut_marker；非标记形态保守取 0 = 只读）
        if p >= 0 && tt_tag(p) == TT_CONS {
            m := tt_a(p);
            if tt_tag(m) == TT_ATOM && tt_a(m) == AK_UNIT { mutv = tt_b(m); }
        }
    }
    return tt_list_variance_at(ak, 0, mutv, p, q);
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

// 扩容 = 重建 + **重放既有条目**（保留「进行中」状态：清表会丢余归纳假设 → 可能不终止）
fn ty_memo_rehash() {
    old_keys := g_ty_memo_keys;
    old_vals := g_ty_memo_vals;
    old_cap := g_ty_memo_cap;
    nc : ., mut = old_cap * 2;
    if nc < 1024 { nc = 1024; }
    nb := alloc(nc * 16);
    nv := alloc(nc * 8);
    i : ., mut = 0;
    loop { if i >= nc { break; } w64(nb, i * 16, -1); w64(nv, i * 8, 0); i = i + 1; }
    g_ty_memo_keys = nb;
    g_ty_memo_vals = nv;
    g_ty_memo_cap = nc;
    g_ty_memo_count = 0;
    j : ., mut = 0;
    loop {
        if j >= old_cap { break; }
        k := r64(old_keys, j * 16);
        if k >= 0 {
            b2 := r64(old_keys, j * 16 + 8);
            s := ty_memo_slot_no_grow(k, b2);
            w64(g_ty_memo_keys, s * 16, k);
            w64(g_ty_memo_keys, s * 16 + 8, b2);
            w64(g_ty_memo_vals, s * 8, r64(old_vals, j * 8));
            g_ty_memo_count = g_ty_memo_count + 1;
        }
        j = j + 1;
    }
}

fn ty_memo_slot_no_grow(a: int, b: int) -> int {
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

fn ty_memo_slot(a: int, b: int) -> int {
    if g_ty_memo_ok == 0 { grow_ty_memo(1024); g_ty_memo_ok = 1; }
    // 装填因子守卫（**必须在探测前**）：表满且键不存在时开放寻址永不退出
    // （P0 终审 Critical 2 实证：1200 互异对 → 98% CPU 空转）→ 先扩容（重建 + 重放）
    if (g_ty_memo_count + 1) * 2 >= g_ty_memo_cap { ty_memo_rehash(); }
    // memo 查找计入预算（防备忘录自身成为无界成本）；耗尽 → -1 上抛（调用方处理）
    if tt_step() == -1 { return -1; }
    return ty_memo_slot_no_grow(a, b);
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
    // memo 随之清空（下次 ty_memo_slot 重建）：**每个顶层查询独立**——否则跨查询的
    // 缓存命中会让结果依赖预算历史而非输入项（P0 终审 Critical 3 实证）
    // 注意还要清 cap：grow_ty_memo 有 `needed < cap → return` 早退，若 cap 已涨过
    // （经 rehash），只清 ok 位会复用旧表 → 隔离承诺落空（修复复审 N1）
    g_ty_memo_ok = 0;
    g_ty_memo_cap = 0;
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
            li := lit_implies(lp, lq);
            if li == 1 { covered = 1; break; }
            // 预算耗尽/未覆盖面必须**上抛**（P0 终审 Critical 3：早期 `== 1` 把 -1 当「未覆盖」
            // → 判定结果被吞成 0 并缓存，违反 spec §3.3「禁止当 0 用」）
            if li == -1 { return -1; }
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
    if slot < 0 { return -1; }        // 预算耗尽（memo 查找本身计数）
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
    if n1 < 0 { return -1; }      // 规范化预算耗尽（P0 终审 Important C）
    n2 := tt_norm(b);
    if n2 < 0 { return -1; }
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
    if n < 0 { return -1; }       // 规范化预算耗尽
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
// witness = A\B 的规范化类型项；**不可满足 → -1**（无遗漏/无反例值）；
// **-2 = 未知**（预算耗尽/未覆盖面——与「不可满足」严格区分：P0 终审 Minor 指出早期
// 二者共用 -1 会让「证明不了」被当成「确实穷尽」）
fn tt_witness(a: int, b: int) -> int {
    r := tt_norm(tt_inter(a, tt_not(b)));
    if r < 0 { return -2; }
    if tt_tag(r) == TT_BOT { return -1; }
    x := ty_inhabited(r);
    if x == -1 { return -2; }
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
    if w == -2 { return -1; }            // 未知（预算耗尽/未覆盖面）——不得当「穷尽」
    if g_ty_exhausted != 0 { return -1; }
    if w < 0 { return 1; }               // 补集空 = 穷尽
    return 0;
}

fn ty_disjoint(a: int, b: int) -> int {
    x := ty_inhabited(tt_inter(a, b));
    if x == -1 { return -1; }   // 三态传播：未知不得降级为 0
    if x == 0 { return 1; }
    return 0;
}

// iface 簇已移至 iface_axis.cr（R2 P4 Task 0，链接面纯化）
