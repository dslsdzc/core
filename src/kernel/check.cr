// src/kernel/check.cr: bidirectional type checking.
// Corresponds to theories/Algorithmic/Typing/Definitions.v.
// alg_type_check has one rule; alg_type_infer has nine.
// Depends on nbe.cr (kern_nbe_ty), subtype.cr, subst.cr, and mctt.cr (context).
// Interface: type_check(a, m) returns 1 for accept and 0 or negative for reject;
// type_infer(m) returns an inferred nf node, or -1 for reject.
// Every failed premise returns -1, and inferred results are normalized.

fn ctx_pop():
    if g_ctx_len > 0:
        g_ctx_len = g_ctx_len - 1

// Check M against A: infer M then check subtyping.
fn type_check(a: int, m: int) -> int:
    ta := type_infer(m)
    if ta < 0:
        return 0
    return subtyping(ta, a)

// Infer the type of M. There are nine rules.
fn type_infer(m: int) -> int:
    k := kern_kind(m)
    if k == K_TYP:
        return mk_typ(kern_get(m, 1) + 1)
    // ati_typ: Type@i has type Type@(i+1).
    if k == K_NAT:
        return mk_typ(0)
    // ati_nat: Nat has type Type@0.
    if k == K_ZERO:
        return mk_nat()
    // ati_zero: zero has type Nat.
    if k == K_SUCC:
        // ati_succ: check the operand against Nat.
        if type_check(mk_nat(), kern_get(m, 1)) <= 0:
            return -1
        return mk_nat()
    if k == K_VAR:
        // ati_vlookup: look up #x in the context and normalize A weakened by
        // x+1. Each context level adds one Wk, so index x is weakened x+1 times.
        x := kern_get(m, 1)
        a := ctx_get(x)
        if a < 0:
            return -1
        // An out-of-range index is a free variable and is rejected.
        return kern_nbe_ty(mk_sub(a, subst_wk_n(x + 1)))
    if k == K_PI:
        // ati_pi: infer A and B as universes and return the larger level.
        a := kern_get(m, 1)
        b := kern_get(m, 2)
        ta := type_infer(a)
        if ta < 0 || kern_kind(ta) != K_TYP:
            return -1
        i := kern_get(ta, 1)
        ctx_extend(a)
        tb := type_infer(b)
        ctx_pop()
        if tb < 0 || kern_kind(tb) != K_TYP:
            return -1
        j := kern_get(tb, 1)
        if j > i:
            return mk_typ(j)
        return mk_typ(i)
    if k == K_FN:
        // ati_fn: infer A as a universe, infer the body under A, and return Pi.
        a := kern_get(m, 1)
        mm := kern_get(m, 2)
        ta := type_infer(a)
        if ta < 0 || kern_kind(ta) != K_TYP:
            return -1
        ctx_extend(a)
        tb := type_infer(mm)
        ctx_pop()
        if tb < 0:
            return -1
        c := kern_nbe_ty(a)                                             // normalize A in the original context
        if c < 0:
            return -1
        return mk_pi(c, tb)
    if k == K_APP:
        // ati_app: infer the function as Pi, check the argument, and substitute it into the result type.
        mm := kern_get(m, 1)
        nn := kern_get(m, 2)
        tm := type_infer(mm)
        if tm < 0 || kern_kind(tm) != K_PI:
            return -1
        a := kern_get(tm, 1)
        b := kern_get(tm, 2)
        if type_check(a, nn) <= 0:
            return -1
        c := kern_nbe_ty(mk_sub(b, subst_id_of(nn)))                    // substitute N into B
        if c < 0:
            return -1
        return c
    if k == K_NATREC:
        // ati_natrec: infer A under Gamma,Nat; check MZ against A[zero];
        // check MS under Gamma,Nat,A against A[succ #1]; check M against Nat;
        // then normalize A[M].
        a := kern_get(m, 1)
        mz := kern_get(m, 2)
        ms := kern_get(m, 3)
        mm := kern_get(m, 4)
        ctx_extend(mk_nat())                                            // extend with Nat
        ta := type_infer(a)
        if ta < 0 || kern_kind(ta) != K_TYP:
            ctx_pop()
            return -1
        ctx_pop()                                                       // return to Gamma
        if type_check(mk_sub(a, subst_id_zero()), mz) <= 0:
            return -1
        // Check MZ against A[zero] under Gamma.
        ctx_extend(mk_nat())                                            // extend with Nat
        ctx_extend(a)                                                   // extend with A
        if type_check(mk_sub(a, subst_wk_wk_succ1()), ms) <= 0:
            ctx_pop()
            ctx_pop()
            return -1
        ctx_pop()                                                       // return to Gamma,Nat
        ctx_pop()                                                       // return to Gamma
        if type_check(mk_nat(), mm) <= 0:
            return -1
        // Check M against Nat under Gamma.
        b := kern_nbe_ty(mk_sub(a, subst_id_of(mm)))                    // normalize A[M]
        if b < 0:
            return -1
        return b
    return -1                                                           // other forms, including a top-level substitution, are rejected
