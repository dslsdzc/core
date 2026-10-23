// src/kernel/subtype.cr: algorithmic subtyping.
// Corresponds to theories/Algorithmic/Subtyping/Definitions.v: not_univ_pi,
// three alg_subtyping_nf rules, and one alg_subtyping rule.
// Depends on nbe.cr (kern_nbe_ty) and kernel_main.cr (nf_eq).
// subtyping(a, b) returns 1 for yes and 0 or negative for no. The context is read
// from mctt.cr globals.
// Total: if either side is not a type, normalization fails and the result is no.

// Normal-form subtyping. There are three rules.
fn kern_sub_nf(a: int, b: int) -> int:
    ka := kern_get(a, 0)
    kb := kern_get(b, 0)
    if ka == K_TYP && kb == K_TYP:
        // asnf_univ: universe levels compare by i <= j.
        return kern_get(a, 1) <= kern_get(b, 1)
    if ka == K_PI && kb == K_PI:
        // asnf_pi: domains must be syntactically equal and codomains are
        // covariant. McTT has no contravariant Pi subtyping; do not add it.
        if nf_eq(kern_get(a, 1), kern_get(b, 1)) == 0:
            return 0
        return kern_sub_nf(kern_get(a, 2), kern_get(b, 2))
    // asnf_refl: when A is not a universe or Pi, compare by equality.
    if ka == K_TYP || ka == K_PI:
        return 0
    // The not_univ_pi premise is satisfied here.
    return nf_eq(a, b)

// Normalize both sides to nf, then compare them.
fn subtyping(a: int, b: int) -> int:
    a1 := kern_nbe_ty(a)
    b1 := kern_nbe_ty(b)
    if a1 < 0 || b1 < 0:
        return 0
    // Non-type forms normalize to a failure and return no.
    return kern_sub_nf(a1, b1)
