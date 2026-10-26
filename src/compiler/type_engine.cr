// === type_engine.cr ===
// Type-term judgment engine: semantic inclusion over set-valued type terms.
// Three-state result: 1 = holds, 0 = does not hold, -1 = budget exhausted or
// uncovered. Never treat -1 as 0.
//
// Pipeline:
//   normalize (tt_norm: NNF + DNF) -> product coverage -> literal implication
//   (including atomic-class disjointness axioms) -> mu expansion with a
//   hypothesis-judgment memo (coinductive: an in-progress pair is assumed true)
//   -> one budget step per operation; exhaustion sets g_ty_exhausted and returns
//   -1.
//
// Uncovered faces set g_ty_uncovered = 1, never 0:
//   1. Parameter variance for AK_SEQUENCE, AK_PTR, and AK_REF is handled by
//      ty_variance_of and tt_list_variance. Covariant slots use ty_sub; invariant
//      slots compare identity tokens by node identity and type terms by ty_equiv.
//   2. AK_NAMED is judged by its identity sequence (same sequence 1, different sequence 0,
//      out of domain -1). It is not structurally expanded.
//   3. Empty mu recursion (mu X.X) is treated as inhabited.
//
// Atomic class ids are decoupled from g_types rows: primitive classes map 1:1,
// and structural or named atoms carry a g_types row (ti = -1 means class level).

// Atomic class ids (AK_*).
AK_INT : int = 0
AK_DEX : int = 1
AK_STRING : int = 2
AK_BOOL : int = 3
AK_UNIT : int = 4
AK_NEVER : int = 5
AK_CHAR : int = 6
AK_DYN : int = 7
AK_PRODUCT : int = 8
AK_SUM : int = 9
AK_SEQUENCE : int = 10
AK_REF : int = 11
AK_PTR : int = 12
AK_FN : int = 13
AK_NAMED : int = 14
// AK_NULL is the primitive class for null, the None value type.
// T? = T union null. It is disjoint from every other class except AK_DYN,
// including AK_UNIT, AK_NEVER, and AK_NAMED. It is inhabited (the single value
// None) and has no type parameters. It is not in the iface registry, so
// iface_kind_of returns -1 for a row carrying it.
AK_NULL : int = 15

// Literal collection buffer for a product.
fn grow_ty_lits(needed: int):
    if needed < g_ty_lits_cap:
        return
    nc : ., mut = g_ty_lits_cap * 2
    if nc < 64:
        nc = 64
    if nc < needed:
        nc = needed + 64
    nb := alloc(nc * 8)
    cell_copy(g_ty_lits, g_ty_lits_cap * 8, nb)
    g_ty_lits = nb
    g_ty_lits_cap = nc

fn ty_lits_reset():
    g_ty_lits_count = 0

fn ty_lits_push(t: int):
    if g_ty_lits_count + 1 > g_ty_lits_cap:
        grow_ty_lits(g_ty_lits_count + 1)
    cell_store(g_ty_lits, g_ty_lits_count * 8, t)
    g_ty_lits_count = g_ty_lits_count + 1

fn ty_lit_at(k: int) -> int:
    return cell_load(g_ty_lits, k * 8)

// Collect the literals of a product (an intersection sequence) or a single literal
// into g_ty_lits.
fn lit_collect(i: int):
    if tt_tag(i) == TT_INTER:
        lit_collect(tt_a(i))
        lit_collect(tt_b(i))
        return
    ty_lits_push(i)

// Atomic-class disjointness. Different classes do not intersect; AK_DYN is the
// top class and is compatible with everything.
fn ak_disjoint(x: int, y: int) -> int:
    if x == y:
        return 0
    if x == AK_DYN || y == AK_DYN:
        return 0
    // null is its own single-value class and is disjoint from every other class.
    // This check comes before AK_NEVER and AK_NAMED. It intersects NEVER (both
    // have no values), and it is independent of the NAMED rule: a named type may
    // be any structural type, but null is not structural and no user-declared type
    // contains None, so asserting disjointness is sound.
    if x == AK_NULL || y == AK_NULL:
        return 1
    if x == AK_NEVER || y == AK_NEVER:
        return 1
    // A concrete AK_NAMED row is not expanded, so disjointness cannot be asserted.
    if x == AK_NAMED || y == AK_NAMED:
        return 0
    return 1

// Atomic class of a literal. Bottom, top, and variables have no class and return -1.
fn ty_ak_of(i: int) -> int:
    t := tt_tag(i)
    if t == TT_ATOM:
        return tt_a(i)
    if t == TT_NOT && tt_tag(tt_a(i)) == TT_ATOM:
        return tt_a(tt_a(i))
    if t == TT_TOP_K:
        return tt_a(i)
    return -1

// Literal contradiction test: a first-order criterion for an empty product.
// Atomic class of a literal in positive or negated position. Returns -1 when the
// literal has no class (variable, composite, bottom, or top).
fn lit_class_of(i: int) -> int:
    t := tt_tag(i)
    if t == TT_ATOM || t == TT_TOP_K:
        return tt_a(i)
    if t == TT_NOT:
        it := tt_tag(tt_a(i))
        if it == TT_ATOM || it == TT_TOP_K:
            return tt_a(tt_a(i))
    return -1

fn lit_is_neg(i: int) -> int:
    if tt_tag(i) == TT_NOT:
        return 1
    return 0

// Whether one pair of literals is disjoint (the intersection is empty). The rule is
// intentionally narrow:
//   positive x positive, different classes: empty;
//   positive x negative, different classes: not empty (int ∩ ¬string = int);
//   positive x ¬top-k, same class: empty;
//   negative x negative: never empty.
fn lit_empty_pair(p: int, q: int) -> int:
    if tt_tag(p) == TT_BOT || tt_tag(q) == TT_BOT:
        return 1
    if tt_not(q) == p:
        return 1
    // X and not X
    pc := lit_class_of(p)
    qc := lit_class_of(q)
    if pc < 0 || qc < 0:
        return 0
    pneg := lit_is_neg(p)
    qneg := lit_is_neg(q)
    if pneg == 0 && qneg == 0:
        return ak_disjoint(pc, qc)
    // Positive x negative.
    if pneg == 0 && qneg != 0:
        if tt_tag(q) == TT_NOT && tt_tag(tt_a(q)) == TT_TOP_K && pc == qc:
            return 1
        return 0
    if pneg != 0 && qneg == 0:
        if tt_tag(p) == TT_NOT && tt_tag(tt_a(p)) == TT_TOP_K && pc == qc:
            return 1
        return 0
    return 0   // negative x negative

// Buffer-based version. sub_cover needs the literal sets of both p and q at the
// same time, so the side buffer must not be reused.
fn lits_contradictory_buf(buf: string, n: int) -> int:
    i : ., mut = 0
    loop:
        if i >= n:
            break
        p : ., mut = cell_load(buf, i * 8)
        j : ., mut = i + 1
        loop:
            if j >= n:
                break
            q := cell_load(buf, j * 8)
            if lit_empty_pair(p, q) == 1:
                return 1
            j = j + 1
        i = i + 1
    return 0

// Collect product literals into a separate buffer and return the buffer. The
// return type is string because alloc's type in the checker is () -> string and
// the value flow uses byte buffers throughout.
fn lits_copy(p: int) -> string:
    ty_lits_reset()
    lit_collect(p)
    n := g_ty_lits_count
    buf := alloc((n + 1) * 8)
    i : ., mut = 0
    loop:
        if i >= n:
            break
        cell_store(buf, i * 8, ty_lit_at(i))
        i = i + 1
    return buf

fn lits_contradictory() -> int:
    return lits_contradictory_buf(g_ty_lits, g_ty_lits_count)

// Named types are judged by an identity sequence.
// Identity is the sequence built by ty_shadow.cr (sh_named_identity_term and
// sh_apply_identity_term): [name token] or [base token, arg terms...]. It is not
// a structural expansion; expanding would make structurally equal but differently
// named structs compare equal.
//
// Rules:
//   1. Sequences equal element-wise -> 1.
//   2. Sequences differ and both sides are in the domain -> 0.
//   3. Out of domain -> -1: empty sequence, position mismatch (a token where a term is
//      expected or vice versa), or an AK_NEVER/AK_DYN mix. Never approximate.
// Token positions use node identity. Type-argument positions use ty_equiv.
fn te_is_name_token(e: int) -> int:
    if e < 0 || e >= tt_count():
        return 0
    if tt_tag(e) != TT_ATOM:
        return 0
    if tt_a(e) != AK_UNIT:
        return 0
    if tt_b(e) < 0:
        return 0
    return 1

// Terms allowed in argument positions: type terms (atom, union, intersection,
// cons, nil). Mu variables, negations, and raw values are out of domain.
// Primitive unit atoms are in the domain. They have the same shape as tokens
// (b >= 0), so the position decides the comparison: argument positions use
// ty_equiv, and token positions use te_token_cmp.
fn te_is_arg_term(e: int) -> int:
    if e < 0 || e >= tt_count():
        return 0
    t := tt_tag(e)
    if t == TT_ATOM || t == TT_UNION || t == TT_INTER || t == TT_CONS || t == TT_NIL:
        return 1
    return 0

// Compare position 0, the identity token. The caller guarantees e1 != e2. A
// difference is determinate: a name token's identity is its node.
fn te_token_cmp(e1: int, e2: int) -> int:
    if te_is_name_token(e1) != 0 && te_is_name_token(e2) != 0:
        return 0
    return -1      // position mismatch (not a token): out of domain

// Compare positions >= 1 (generic argument type terms) by engine equivalence,
// passing the three-state result through.
fn te_arg_cmp(e1: int, e2: int) -> int:
    if te_is_arg_term(e1) == 0 || te_is_arg_term(e2) == 0:
        return -1
    return ty_equiv(e1, e2)

// Identity sequence comparison, three-state. slot is the current position (0 = token).
// Different sequence shapes are structurally different: nil vs cons returns 0; a
// non-list side is out of domain and returns -1.
fn te_chain_cmp(slot: int, p: int, q: int) -> int:
    if p == q:
        return 1
    if p < 0 || q < 0:
        return 0
    // Empty sequence against non-empty sequence.
    tp := tt_tag(p)
    tq := tt_tag(q)
    if tp != TT_CONS || tq != TT_CONS:
        if tp == TT_NIL || tq == TT_NIL:
            return 0
        return -1
    e1 := tt_a(p)
    e2 := tt_a(q)
    d : ., mut = 1
    if e1 != e2:
        if slot == 0:
            d = te_token_cmp(e1, e2)
        else:
            d = te_arg_cmp(e1, e2)
    if d == -1:
        return -1
    if d == 0:
        return 0
    return te_chain_cmp(slot + 1, tt_b(p), tt_b(q))

// Compare elements in invariant slots. Returns 1 (equal), 0 (definitely
// different), or -1 (out of domain).
//   1. Both sides are identity tokens (AK_UNIT with b >= 0): same node means
//      equal; different nodes mean different. Do not use ty_equiv, which would
//      equate structurally equal tokens with different names.
//   2. Both sides are type terms: use ty_equiv three-state.
//   3. Otherwise set g_ty_uncovered and return -1.
// AK_UNIT tokens and primitive unit terms have the same shape. Tokens are checked
// first so the worst case is 0, never a false equality.
fn te_elem_cmp(p: int, q: int) -> int:
    if p == q:
        return 1
    if te_is_name_token(p) != 0 && te_is_name_token(q) != 0:
        return 0
    if te_is_arg_term(p) != 0 && te_is_arg_term(q) != 0:
        return ty_equiv(p, q)
    g_ty_uncovered = 1
    return -1

// Pairwise named-type judgment, three-state. p and q are TT_ATOM and at least one
// side is AK_NAMED; the caller guarantees this.
fn te_named_pair(pk: int, p: int, qk: int, q: int) -> int:
    if pk == qk:
        // Both sides are AK_NAMED (same class, at least one is named).
        cp := tt_c(p)
        cq := tt_c(q)
        if cp < 0 || cq < 0:
            return -1
        // Empty sequence means no identity, so it is out of domain.
        return te_chain_cmp(0, cp, cq)
    // Named type against a different atom class: determinate different. The named
    // side must carry an identity sequence. The other side must not be AK_NEVER or
    // AK_DYN, whose bottom/top semantics are not modeled here; those stay -1.
    if pk == AK_NAMED:
        if tt_c(p) < 0:
            return -1
        if qk == AK_NEVER || qk == AK_DYN:
            return -1
        return 0
    if tt_c(q) < 0:
        return -1
    if pk == AK_NEVER || pk == AK_DYN:
        return -1
    return 0

// Determinate disjointness for same-class atoms, used by the negation face of
// lit_implies: lp ⊆ ¬x iff lp ∩ x = ∅. ak_disjoint gives no information for the
// same class, so this function supplements it with identity sequences.
//
// Domain:
//   1. AK_SUM variant term: sequence [enum token, variant token]. Different sequences
//      mean different (enum, variant) and disjoint value sets -> 1. The same sequence
//      means the same node -> intersecting -> 0.
//   2. Class top ⊤k(k): contains all values of the class, so it intersects
//      same-class atoms -> 0.
//   3. Parameterized constructors and primitive classes: different sequences do not
//      imply disjointness (for example [int] and [int ∪ string]). Return 0.
//   4. Empty sequence: no identity, return 0.
//   5. Non-token elements in an AK_SUM sequence: malformed, return 0.
// This function returns only 0 or 1 and does not set g_ty_uncovered; out-of-domain
// cases are handled by the caller's guards.
fn atom_same_class_disjoint(p: int, q: int) -> int:
    if tt_tag(p) == TT_TOP_K || tt_tag(q) == TT_TOP_K:
        return 0
    // Class top intersects any same-class atom.
    if tt_a(p) != AK_SUM:
        return 0
    // Non-identity atoms, including primitive and parameterized classes.
    cp := tt_c(p)
    cq := tt_c(q)
    if cp < 0 || cq < 0:
        return 0
    // Empty sequence means no identity.
    d := sum_chain_same(cp, cq)
    if d == 1:
        return 0
    // Same identity means intersecting.
    if d == 0:
        return 1
    // Different identity means disjoint.
    return 0                                                          // not decidable

// Compare AK_SUM variant sequences by node identity. Returns 1 for the same sequence,
// 0 for definitely different, and -1 for not decidable. The only production
// constructor is sh_variant_term, which always builds two tokens. Do not use
// te_sequence_cmp: its slot layout is for named types (slot 0 token, slots >= 1 type
// args), so a variant token in slot 1 would go through ty_equiv and two different
// tokens could compare equal because their b annotation is ignored.
fn sum_chain_same(p: int, q: int) -> int:
    if p == q:
        return 1
    if p < 0 || q < 0:
        return -1
    if tt_tag(p) != TT_CONS || tt_tag(q) != TT_CONS:
        return -1
    e1 := tt_a(p)
    e2 := tt_a(q)
    if e1 != e2:
        if te_is_name_token(e1) == 0 || te_is_name_token(e2) == 0:
            return -1
        return 0                                                   // both tokens, different nodes -> different sequence
    return sum_chain_same(tt_b(p), tt_b(q))

// Literal implication: lp implies lq.
fn lit_implies(lp: int, lq: int) -> int:
    if lp == lq:
        return 1
    if tt_tag(lq) == TT_TOP:
        return 1
    if tt_tag(lp) == TT_BOT:
        return 1
    if tt_tag(lp) == TT_TOP:
        return tt_tag(lq) == TT_TOP
    // lq is a class top.
    if tt_tag(lq) == TT_TOP_K:
        k := tt_a(lq)
        if tt_tag(lp) == TT_TOP_K:
            return tt_a(lp) == k
        if tt_tag(lp) == TT_ATOM:
            return tt_a(lp) == k
        return 0
    // lq is ¬x: lp ⊆ ¬x exactly when lp ∩ x is empty.
    if tt_tag(lq) == TT_NOT:
        x := tt_a(lq)
        // ¬P ⊆ ¬X exactly when X ⊆ P. The argument order matters; reversing it
        // would make ¬A ⊆ ¬B and A ⊊ B both true.
        if tt_tag(lp) == TT_NOT:
            return ty_sub(x, tt_a(lp))
        // A classless literal such as ¬(μ...): unknown, mark uncovered.
        if lit_class_of(lp) < 0 || lit_class_of(x) < 0:
            if tt_tag(x) == TT_BOT:
                return 1
            if tt_tag(lp) == TT_BOT:
                return 1
            g_ty_uncovered = 1
            return -1
        pk := lit_class_of(lp)
        xk := lit_class_of(x)
        if pk == AK_NAMED || xk == AK_NAMED:
            g_ty_uncovered = 1
            return -1
        // Do not expand; identity decides intersection. Different identity means
        // disjoint, so lp ⊆ ¬x holds. Different classes use ak_disjoint. Identity is
        // only in terms, while ak_disjoint sees class ids, so this strengthening
        // stays here; moving it there would make every same-class pair disjoint.
        if pk == xk:
            return atom_same_class_disjoint(lp, x)
        if ak_disjoint(pk, xk) == 1:
            return 1
        return 0
    // Both sides are positive atoms. Same class uses variance comparison.
    if tt_tag(lp) == TT_ATOM && tt_tag(lq) == TT_ATOM:
        pk := tt_a(lp)
        qk := tt_a(lq)
        // Named types use the identity sequence; see te_named_pair for the three-state
        // domain rules.
        if pk == AK_NAMED || qk == AK_NAMED:
            d := te_named_pair(pk, lp, qk, lq)
            if d == -1:
                g_ty_uncovered = 1
                return -1
            return d
        if pk != qk:
            return 0
        lv := tt_list_variance(pk, tt_c(lp), tt_c(lq))
        if lv == 1:
            return 1
        if lv == -1:
            return -1
        // The invariant-slot comparison returned 0: definitely not included.
        return 0
    return 0

// Structural equality for parameter sequences. This is the default slot comparison
// for invariant slots.
fn tt_list_same(p: int, q: int) -> int:
    if p == q:
        return 1
    if p < 0 || q < 0:
        return 0
    if tt_tag(p) != TT_CONS || tt_tag(q) != TT_CONS:
        return 0
    if tt_list_same(tt_a(p), tt_a(q)) == 0:
        return 0
    return tt_list_same(tt_b(p), tt_b(q))

// Equality for invariant-slot type terms, ignoring the sequence b slot.
// The b slot of a sequence term is a representation hint (N / fixedness). It can
// leak into node identity for nested elements: [[int;3];2] and [[int];2] have
// element terms that differ only in b and are different nodes, so tt_list_same
// reports not structurally equal and the engine returns -1 as unknown.
// Ignore b when both sides are AK_SEQUENCE atoms, recursively. Other constructors
// use node identity (tt_list_same). AK_NAMED's b is a row id and is identity;
// token atoms (AK_SUM name token, AK_REF mut marker) also use b as identity.
fn tt_type_elem_same(p: int, q: int) -> int:
    if p == q:
        return 1
    if p < 0 || q < 0:
        return 0
    if tt_tag(p) == TT_ATOM && tt_a(p) == AK_SEQUENCE && tt_tag(q) == TT_ATOM && tt_a(q) == AK_SEQUENCE:
        return tt_seq_same(p, q)
    return tt_list_same(p, q)

// Sequence term equality, ignoring b: same class and element-wise recursive
// parameter sequences. Element positions go through tt_type_elem_same.
fn tt_seq_same(p: int, q: int) -> int:
    if p == q:
        return 1
    cp := tt_c(p)
    cq := tt_c(q)
    if cp == cq:
        return 1
    if cp < 0 || cq < 0:
        return 0
    if tt_tag(cp) != TT_CONS || tt_tag(cq) != TT_CONS:
        return 0
    if tt_type_elem_same(tt_a(cp), tt_a(cq)) != 1:
        return 0
    return tt_type_elem_same(tt_b(cp), tt_b(cq))

// Variance table and parameter-sequence comparison.
// Read-only views are covariant; writable views are invariant.
// 0 = invariant, 1 = covariant. Other constructors default to invariant.
//   AK_SEQUENCE slot 0: invariant because arrays and slices are writable.
//   AK_PTR slot 0: invariant because bare pointers are writable.
//   AK_REF slot 0: mut marker, invariant and decidable (a syntax token, not a type
//   set).
//   AK_REF slot 1: covariant for read-only, invariant for writable. The writable
//   case is lowered to 0 by tt_list_variance_at after reading the marker.
fn ty_variance_of(ak: int, slot: int) -> int:
    if ak == AK_REF:
        if slot == 0:
            return 0
        if slot == 1:
            return 1
        return 0
    if ak == AK_SEQUENCE:
        return 0
    if ak == AK_PTR:
        return 0
    return 0   // other constructors (primitives, named classes) are invariant

// Compare parameter sequences by variance. Returns 1 (holds), 0 (does not hold), or
// -1 (unknown).
//   covariant slot -> ty_sub(a, b), three-state.
//   AK_REF slot 0 (mut marker) -> node identity; a different marker is 0, not -1.
//   other invariant slots -> tt_type_elem_same, otherwise te_elem_cmp three-state
//   (tokens by node identity, type terms by engine equivalence).
// p == q is a fast path. Different sequence shapes return 0.
fn tt_list_variance_at(ak: int, slot: int, mutv: int, p: int, q: int) -> int:
    if p == q:
        return 1
    if p < 0 || q < 0:
        return 0
    if tt_tag(p) != TT_CONS || tt_tag(q) != TT_CONS:
        return 0
    ha := tt_a(p)
    hb := tt_a(q)
    if ak == AK_REF && slot == 0:
        if tt_list_same(ha, hb) != 1:
            return 0
        // Mut marker slot: decidable by node identity.
    else:
        v : ., mut = ty_variance_of(ak, slot)
        if ak == AK_REF && slot == 1 && mutv == 1:
            v = 0
        // Writable ref: the element slot is invariant.
        if v == 1:
            s := ty_sub(ha, hb)
            if s != 1:
                return s
        else:
            if tt_type_elem_same(ha, hb) != 1:
                // Not structurally equal: use the three-state comparison.
                // Determinate different returns 0; out-of-domain or unknown returns
                // -1. te_elem_cmp sets the uncovered bit; this layer does not
                // swallow it or change the state.
                d := te_elem_cmp(ha, hb)
                if d == -1:
                    return -1
                if d == 0:
                    return 0
    return tt_list_variance_at(ak, slot + 1, mutv, tt_b(p), tt_b(q))

fn tt_list_variance(ak: int, p: int, q: int) -> int:
    mutv : ., mut = 0
    if ak == AK_REF:
        // Slot 0 is compared before this point. Take the mut marker from the sequence
        // head. A non-marker shape is conservatively treated as read-only (0).
        if p >= 0 && tt_tag(p) == TT_CONS:
            m := tt_a(p)
            if tt_tag(m) == TT_ATOM && tt_a(m) == AK_UNIT:
                mutv = tt_b(m)
    return tt_list_variance_at(ak, 0, mutv, p, q)

// Memo for hypothesis judgment: 0 = false, 1 = true, 2 = in progress (assume true).
fn grow_ty_memo(needed: int):
    if needed < g_ty_memo_cap:
        return
    nc : ., mut = 1024
    loop:
        if nc >= needed:
            break
        nc = nc * 2
    nb := alloc(nc * 16)
    i : ., mut = 0
    loop:
        if i >= nc:
            break
        cell_store(nb, i * 16, -1)
        i = i + 1
    nv := alloc(nc * 8)
    i2 : ., mut = 0
    loop:
        if i2 >= nc:
            break
        cell_store(nv, i2 * 8, 0)
        i2 = i2 + 1
    g_ty_memo_keys = nb
    g_ty_memo_vals = nv
    g_ty_memo_cap = nc
    g_ty_memo_count = 0

// Rehash rebuilds and replays existing entries. In-progress states are preserved:
// clearing them would drop coinductive hypotheses and could fail to terminate.
fn ty_memo_rehash():
    old_keys := g_ty_memo_keys
    old_vals := g_ty_memo_vals
    old_cap := g_ty_memo_cap
    nc : ., mut = old_cap * 2
    if nc < 1024:
        nc = 1024
    nb := alloc(nc * 16)
    nv := alloc(nc * 8)
    i : ., mut = 0
    loop:
        if i >= nc:
            break
        cell_store(nb, i * 16, -1)
        cell_store(nv, i * 8, 0)
        i = i + 1
    g_ty_memo_keys = nb
    g_ty_memo_vals = nv
    g_ty_memo_cap = nc
    g_ty_memo_count = 0
    j : ., mut = 0
    loop:
        if j >= old_cap:
            break
        k := cell_load(old_keys, j * 16)
        if k >= 0:
            b2 := cell_load(old_keys, j * 16 + 8)
            s := ty_memo_slot_no_grow(k, b2)
            cell_store(g_ty_memo_keys, s * 16, k)
            cell_store(g_ty_memo_keys, s * 16 + 8, b2)
            cell_store(g_ty_memo_vals, s * 8, cell_load(old_vals, j * 8))
            g_ty_memo_count = g_ty_memo_count + 1
        j = j + 1

fn ty_memo_slot_no_grow(a: int, b: int) -> int:
    h : ., mut = (a * 31 + b) % g_ty_memo_cap
    if h < 0:
        h = 0 - h
    p : ., mut = h
    loop:
        k := cell_load(g_ty_memo_keys, p * 16)
        if k < 0:
            return p
        if k == a && cell_load(g_ty_memo_keys, p * 16 + 8) == b:
            return p
        p = p + 1
        if p >= g_ty_memo_cap:
            p = 0

fn ty_memo_slot(a: int, b: int) -> int:
    if g_ty_memo_ok == 0:
        grow_ty_memo(1024)
        g_ty_memo_ok = 1
    // Load-factor guard before probing. A full table with a missing key would loop
    // forever in open addressing, so rehash first.
    if (g_ty_memo_count + 1) * 2 >= g_ty_memo_cap:
        ty_memo_rehash()
    // Memo lookup counts against the budget. Exhaustion returns -1 to the caller.
    if tt_step() == -1:
        return -1
    return ty_memo_slot_no_grow(a, b)

fn ty_memo_state(slot: int) -> int:
    if cell_load(g_ty_memo_keys, slot * 16) < 0:
        return -2
    // Empty slot (unused).
    return cell_load(g_ty_memo_vals, slot * 8)

fn ty_memo_set(slot: int, a: int, b: int, v: int):
    if cell_load(g_ty_memo_keys, slot * 16) < 0:
        cell_store(g_ty_memo_keys, slot * 16, a)
        cell_store(g_ty_memo_keys, slot * 16 + 8, b)
        g_ty_memo_count = g_ty_memo_count + 1
    cell_store(g_ty_memo_vals, slot * 8, v)

// Mu expansion by substitution.
fn tt_subst_list(p: int, v: int, r: int) -> int:
    if p < 0:
        return -1
    if tt_tag(p) != TT_CONS:
        return tt_subst(p, v, r)
    return tt_cons(tt_subst(tt_a(p), v, r), tt_subst_list(tt_b(p), v, r))

fn tt_subst(i: int, v: int, r: int) -> int:
    t := tt_tag(i)
    if t == TT_VAR:
        if tt_a(i) == v:
            return r
        return i
    if t == TT_UNION:
        return tt_union(tt_subst(tt_a(i), v, r), tt_subst(tt_b(i), v, r))
    if t == TT_INTER:
        return tt_inter(tt_subst(tt_a(i), v, r), tt_subst(tt_b(i), v, r))
    if t == TT_NOT:
        return tt_not(tt_subst(tt_a(i), v, r))
    if t == TT_MU:
        if tt_a(i) == v:
            return i
        // An inner binder with the same variable shadows it (capture avoidance).
        return tt_mu(tt_a(i), tt_subst(tt_b(i), v, r))
    if t == TT_ATOM:
        return tt_atom(tt_a(i), tt_b(i), tt_subst_list(tt_c(i), v, r))
    return i

// Budget guard.
fn ty_budget_reset(limit: int):
    g_ty_steps = 0
    g_ty_budget_max = limit
    g_ty_exhausted = 0
    g_ty_uncovered = 0
    // Clear the memo (rebuilt on the next ty_memo_slot call). Each top-level query
    // is independent; otherwise a cached hit would make the result depend on
    // budget history rather than the input terms.
    // Also clear cap: grow_ty_memo returns early when needed < cap, so clearing only
    // the ok bit would reuse an old table after a rehash.
    g_ty_memo_ok = 0
    g_ty_memo_cap = 0

fn ty_exhausted() -> int:
    return g_ty_exhausted
fn ty_uncovered() -> int:
    return g_ty_uncovered

// Coverage: p is a subset of q. p and q are normalized; q may be a union.
fn sub_cover(p: int, q: int) -> int:
    g_ty_steps = g_ty_steps + 1
    if g_ty_steps > g_ty_budget_max:
        g_ty_exhausted = 1
        return -1
    // Mu expansion on either side must go through ty_sub_core, the memo entry.
    // Expanded pairs repeat, and termination relies on the coinductive rule
    // "in progress means assumed true." Direct recursion in sub_cover would not
    // converge.
    if tt_tag(p) == TT_MU:
        return ty_sub_core(tt_subst(tt_b(p), tt_a(p), p), q)
    if tt_tag(q) == TT_MU:
        return ty_sub_core(p, tt_subst(tt_b(q), tt_a(q), q))
    if tt_tag(p) == TT_UNION:
        x := sub_cover(tt_a(p), q)
        if x != 1:
            return x
        return sub_cover(tt_b(p), q)
    if tt_tag(q) == TT_UNION:
        // p is covered if any disjunct covers it. Three-state: any 1 is 1; all 0
        // is 0; any -1 is -1.
        x := sub_cover(p, tt_a(q))
        if x == 1:
            return 1
        y := sub_cover(p, tt_b(q))
        if y == 1:
            return 1
        if x == -1 || y == -1:
            return -1
        return 0
    if tt_tag(q) == TT_TOP:
        return 1
    if tt_tag(p) == TT_BOT:
        return 1
    // p and q are products (intersection sequences) or single literals. The literal
    // set of p must cover every literal of q.
    bufp := lits_copy(p)
    pn := g_ty_lits_count
    if lits_contradictory_buf(bufp, pn) == 1:
        return 1
    // Empty p is a subset of everything.
    bufq := lits_copy(q)
    qn := g_ty_lits_count
    qi : ., mut = 0
    loop:
        if qi >= qn:
            break
        lq := cell_load(bufq, qi * 8)
        covered : ., mut = 0
        pi : ., mut = 0
        loop:
            if pi >= pn:
                break
            lp := cell_load(bufp, pi * 8)
            li := lit_implies(lp, lq)
            if li == 1:
                covered = 1
                break
            // Budget exhaustion and uncovered faces must propagate. Treating -1 as
            // covered would silently cache 0, which the three-state rule forbids.
            if li == -1:
                return -1
            pi = pi + 1
        if covered == 0:
            return 0
        qi = qi + 1
    return 1

// Top-level inclusion with hypothesis judgment, memo, and budget.
fn ty_sub_core(a: int, b: int) -> int:
    slot := ty_memo_slot(a, b)
    if slot < 0:
        return -1
    // Budget exhausted by the memo lookup.
    st := ty_memo_state(slot)
    if st == 2:
        return 1
    // In progress means assumed true (coinduction).
    if st == 1:
        return 1
    if st == 0:
        return 0
    ty_memo_set(slot, a, b, 2)
    r := sub_cover(a, b)
    if r == -1:
        // Do not cache -1 from budget exhaustion; a later call with a larger budget
        // would read a false -1. Clear the slot.
        cell_store(g_ty_memo_keys, slot * 16, -1)
        cell_store(g_ty_memo_vals, slot * 8, 0)
    else:
        ty_memo_set(slot, a, b, r)
    return r

fn ty_sub(a: int, b: int) -> int:
    // Default budget when the caller did not call ty_budget_reset. A zero initial
    // budget would make every judgment report exhaustion.
    if g_ty_budget_max <= 0:
        ty_budget_reset(200000)
    if a == b:
        return 1
    n1 := tt_norm(a)
    if n1 < 0:
        return -1
    // Normalization budget exhausted.
    n2 := tt_norm(b)
    if n2 < 0:
        return -1
    if n1 == n2:
        return 1
    if tt_tag(n2) == TT_TOP:
        return 1
    if tt_tag(n1) == TT_BOT:
        return 1
    return ty_sub_core(n1, n2)

fn ty_equiv(a: int, b: int) -> int:
    x := ty_sub(a, b)
    if x != 1:
        return x
    y := ty_sub(b, a)
    if y != 1:
        return y
    return 1

// Inhabitation: under DNF, at least one product is non-contradictory.
fn ty_inhabited(a: int) -> int:
    if g_ty_budget_max <= 0:
        ty_budget_reset(200000)
    n := tt_norm(a)
    if n < 0:
        return -1
    // Normalization budget exhausted.
    return inh_any_at(n, 0)

// Depth guard. Empty mu recursion such as μX.X has no termination criterion, so
// excessive depth returns -1 and marks uncovered. Empty recursion is conservatively
// treated as undecidable, never as 0 or 1.
fn inh_any(i: int) -> int:
    return inh_any_at(i, 0)

fn inh_any_at(i: int, depth: int) -> int:
    if depth > 512:
        g_ty_exhausted = 1
        return -1
    if tt_tag(i) == TT_UNION:
        x := inh_any_at(tt_a(i), depth)
        if x == 1:
            return 1
        y := inh_any_at(tt_b(i), depth)
        if y == 1:
            return 1
        if x == -1 || y == -1:
            return -1
        return 0
    if tt_tag(i) == TT_MU:
        return inh_any_at(tt_subst(tt_b(i), tt_a(i), i), depth + 1)
    if tt_tag(i) == TT_BOT:
        return 0
    ty_lits_reset()
    lit_collect(i)
    // Core has no ternary operator, so use an explicit branch.
    if lits_contradictory() == 1:
        return 0
    return 1

// Counterexample (witness) and exhaustiveness.
// The witness is the normalized type term of A \ B. Return -1 when it is
// unsatisfiable (no counterexample). Return -2 when the result is unknown (budget
// exhausted or uncovered), strictly distinct from unsatisfiable. Sharing -1 would
// treat "cannot prove" as "exhaustive".
fn tt_witness(a: int, b: int) -> int:
    r := tt_norm(tt_inter(a, tt_not(b)))
    if r < 0:
        return -2
    if tt_tag(r) == TT_BOT:
        return -1
    x := ty_inhabited(r)
    if x == -1:
        return -2
    if x != 1:
        return -1
    return r

// Exhaustiveness witness = domain \ union(patterns), where patterns is a CONS sequence.
fn ty_exhaust_witness(domain: int, patterns: int) -> int:
    acc : ., mut = tt_bot()
    p : ., mut = patterns
    loop:
        if p < 0:
            break
        if tt_tag(p) != TT_CONS:
            break
        acc = tt_union(acc, tt_a(p))
        p = tt_b(p)
    return tt_witness(domain, acc)

fn ty_exhaustive(domain: int, patterns: int) -> int:
    w := ty_exhaust_witness(domain, patterns)
    if w == -2:
        return -1
    // Unknown (budget exhausted or uncovered) is not exhaustive.
    if g_ty_exhausted != 0:
        return -1
    if w < 0:
        return 1
    // Empty complement means exhaustive.
    return 0

fn ty_disjoint(a: int, b: int) -> int:
    x := ty_inhabited(tt_inter(a, b))
    if x == -1:
        return -1
    // Three-state propagation: unknown must not be downgraded to 0.
    if x == 0:
        return 1
    return 0

// The iface cluster lives in iface_axis.cr to keep the linkage surface clean.
