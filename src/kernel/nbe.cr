// src/kernel/nbe.cr: normalization by evaluation, covering evaluation,
// readback, and normalization.
// Corresponds to Semantic/Domain.v, Semantic/Evaluation/Definitions.v,
// Semantic/Readback/Definitions.v, and Semantic/NbE.v in the reference source.
// Depends on mctt.cr (K_* constructors and context), subst.cr, and term_io.cr
// (arena).
// Structure: semantic domains D_*, environments, evaluation, readback, and the
// nbe and nbe_ty entry points.
// Absolute names (d_var) are not de Bruijn indexes. The initial environment maps
// them, and read_ne converts them back to #(s-x-1).

// Semantic domains. D_* starts at 10 and does not overlap K_* (0 through 9).
D_NAT : int = 10   // semantic value of Nat
D_PI : int = 11    // Pi a rho B; B is not evaluated, and the closure stores rho
D_UNIV : int = 12  // universe at level i
D_ZERO : int = 13  // zero value
D_SUCC : int = 14  // successor value
D_FN : int = 15    // lambda rho M; the argument type is not evaluated
D_NEUT : int = 16  // neutral value with type annotation a and neutral m
D_VAR : int = 17   // absolute name x
D_APP : int = 18   // neutral application
D_NATREC : int = 19 // recursor: m under rho, return P, zero case mz, successor case MS
D_NATREC2 : int = 20 // second allocation group for D_NATREC; MS is in slot 6 and is never dispatched
D_DOM : int = 21   // type and value pair for readback
// Environment nodes. This is a functional representation: extend and drop are
// O(1) nodes and lookup follows parent references. A count-based environment
// shifted indexes when a closure snapshot was extended later.
D_ENV_BASE : int = 22  // empty base environment
D_ENV_EXT : int = 23   // {D_ENV_EXT, parent, d, 0, 0}: x=0 maps to d, otherwise parent(x-1)
D_ENV_DROP : int = 24  // {D_ENV_DROP, parent, 0, 0, 0}: x maps to parent(x+1)

fn mk_d_nat() -> int:
    return kern_new(D_NAT)
fn mk_d_univ(i: int) -> int:
    n := kern_new(D_UNIV)
    kern_set(n, 1, i)
    return n
fn mk_d_zero() -> int:
    return kern_new(D_ZERO)
fn mk_d_succ(m: int) -> int:
    n := kern_new(D_SUCC)
    kern_set(n, 1, m)
    return n
fn mk_d_pi(a: int, rho: int, b: int) -> int:
    n := kern_new(D_PI)
    kern_set(n, 1, a)
    kern_set(n, 2, rho)
    kern_set(n, 3, b)
    return n
fn mk_d_fn(rho: int, m: int) -> int:
    n := kern_new(D_FN)
    kern_set(n, 1, rho)
    kern_set(n, 2, m)
    return n
fn mk_d_neut(a: int, ne: int) -> int:
    n := kern_new(D_NEUT)
    kern_set(n, 1, a)
    kern_set(n, 2, ne)
    return n
fn mk_d_var(x: int) -> int:
    n := kern_new(D_VAR)
    kern_set(n, 1, x)
    return n
fn mk_d_app(ne: int, nf: int) -> int:
    n := kern_new(D_APP)
    kern_set(n, 1, ne)
    kern_set(n, 2, nf)
    return n
// D_NATREC has five components: m, rho, P, mz, and MS. MS lives in slot 1 of the
// next allocation group, which is slot 6 of the record.
fn mk_d_natrec(m: int, rho: int, p: int, mz: int, ms: int) -> int:
    n := kern_new(D_NATREC)
    if n < 0:
        return -1
    kern_set(n, 1, m)
    kern_set(n, 2, rho)
    kern_set(n, 3, p)
    kern_set(n, 4, mz)
    n2 := kern_new(D_NATREC2)
    if n2 < 0:
        return -1
    // If the second allocation fails, abandon the whole record. The arena only appends, so no rollback is needed.
    kern_set(n, 6, ms)
    return n
fn d_natrec_ms(n: int) -> int:
    return kern_get(n, 6)
fn mk_d_dom(a: int, m: int) -> int:
    n := kern_new(D_DOM)
    kern_set(n, 1, a)
    kern_set(n, 2, m)
    return n

// Environments.
// env_get(rho, x) resolves de Bruijn variable x, where 0 is the newest. EXT maps
// x=0 to d and otherwise parent(x-1). DROP maps x to parent(x+1). BASE returns
// d_zero, matching the total environment function; an invalid node returns -1.
fn mk_env_base() -> int:
    return kern_new(D_ENV_BASE)

fn env_extend(rho: int, d: int) -> int:
    n := kern_new(D_ENV_EXT)
    if n < 0:
        return -1
    kern_set(n, 1, rho)
    kern_set(n, 2, d)
    return n

fn env_drop(rho: int) -> int:
    n := kern_new(D_ENV_DROP)
    if n < 0:
        return -1
    kern_set(n, 1, rho)
    return n

fn env_get(rho: int, x: int) -> int:
    if rho < 0:
        return -1
    k := kern_kind(rho)
    if k == D_ENV_EXT:
        if x == 0:
            return kern_get(rho, 2)
        return env_get(kern_get(rho, 1), x - 1)
    if k == D_ENV_DROP:
        return env_get(kern_get(rho, 1), x + 1)
    if k == D_ENV_BASE:
        return mk_d_zero()
    // BASE returns d_zero, matching the total environment function.
    return -1

// Evaluation.

// eval_exp: expression and environment to domain.
fn kern_eval(e: int, rho: int) -> int:
    k := kern_kind(e)
    if k == K_TYP:
        return mk_d_univ(kern_get(e, 1))
    // eval(Type@i) = Univ@i.
    if k == K_NAT:
        return mk_d_nat()
    // eval(Nat) = Nat.
    if k == K_ZERO:
        return mk_d_zero()
    // eval(zero) = zero.
    if k == K_SUCC:
        return mk_d_succ(kern_eval(kern_get(e, 1), rho))
    // eval(succ M).
    if k == K_VAR:
        return env_get(rho, kern_get(e, 1))
    // eval(#x) under rho is rho(x).
    if k == K_PI:
        return mk_d_pi(kern_eval(kern_get(e, 1), rho), rho, kern_get(e, 2))
    // B is not evaluated.
    if k == K_FN:
        return mk_d_fn(rho, kern_get(e, 2))
    // A is not evaluated.
    if k == K_APP:
        return kern_eval_app(kern_eval(kern_get(e, 1), rho), kern_eval(kern_get(e, 2), rho))
    if k == K_NATREC:
        return kern_eval_natrec(kern_eval(kern_get(e, 4), rho), kern_get(e, 1), kern_get(e, 2), kern_get(e, 3), rho)
    if k == K_SUB:
        return kern_eval(kern_get(e, 1), kern_eval_sub(kern_get(e, 2), rho))
    // Substitution, then environment, then evaluation.
    return -1

// eval_natrec: recursion over a domain.
fn kern_eval_natrec(m: int, a: int, mz: int, ms: int, rho: int) -> int:
    k := kern_kind(m)
    if k == D_ZERO:
        return kern_eval(mz, rho)
    // rec zero evaluates MZ under rho.
    if k == D_SUCC:
        b := kern_get(m, 1)
        r := kern_eval_natrec(b, a, mz, ms, rho)                                // recursive result
        return kern_eval(ms, env_extend(env_extend(rho, b), r))                 // evaluate MS under rho extended with b and r
    if k == D_NEUT:
        ne := kern_get(m, 2)
        a2 := kern_eval(a, env_extend(rho, m))                                  // evaluate A under rho extended with the neutral value
        return mk_d_neut(a2, mk_d_natrec(ne, rho, a, kern_eval(mz, rho), ms))   // keep the neutral value
    return -1

// eval_app: apply a domain to an argument.
fn kern_eval_app(m: int, n: int) -> int:
    k := kern_kind(m)
    if k == D_FN:
        return kern_eval(kern_get(m, 2), env_extend(kern_get(m, 1), n))
    // Expand the closure.
    if k == D_NEUT:
        a := kern_get(m, 1)
        if kern_kind(a) == D_PI:
            ap := kern_get(a, 1)
            rp := kern_get(a, 2)
            bp := kern_get(a, 3)
            b := kern_eval(bp, env_extend(rp, n))                               // evaluate B under rho extended with n
            return mk_d_neut(b, mk_d_app(kern_get(m, 2), mk_d_dom(ap, n)))      // neutral application
    return -1

// eval_sub: apply a substitution to an environment.
fn kern_eval_sub(s: int, rho: int) -> int:
    k := kern_kind(s)
    if k == K_SUB:
        sk := kern_get(s, 4)
        if sk == S_ID:
            return rho
        // eval(Id) under rho is rho.
        if sk == S_WEAKEN:
            return env_drop(rho)
        // eval(Wk) under rho drops the newest binding.
        if sk == S_EXTEND:
            rs := kern_eval_sub(kern_get(s, 1), rho)                            // apply the first substitution
            return env_extend(rs, kern_eval(kern_get(s, 2), rho))               // extend with the evaluated term
        if sk == S_COMPOSE:
            rt := kern_eval_sub(kern_get(s, 2), rho)                            // apply tau first
            return kern_eval_sub(kern_get(s, 1), rt)                            // then apply sigma
    return -1

// Readback: domain and depth to nf or ne expression nodes. Absolute names
// convert to de Bruijn indexes with #(s-x-1).

// read_nf
fn kern_read_nf(d: int, s: int) -> int:
    a := kern_get(d, 1)
    m := kern_get(d, 2)                                    // type and value pair
    ak := kern_kind(a)
    if ak == D_UNIV:
        return kern_read_typ(m, s)
    // Universe case.
    if ak == D_NAT:
        mk := kern_kind(m)
        if mk == D_ZERO:
            return mk_zero()
        // Nat zero.
        if mk == D_SUCC:
            return mk_succ(kern_read_nf(mk_d_dom(a, kern_get(m, 1)), s))
        if mk == D_NEUT:
            return kern_read_ne(kern_get(m, 2), s)
        // Neutral case.
        return -1
    if ak == D_PI:
        // Eta expansion: apply to the fresh absolute name s and increase the depth.
        ap := kern_get(a, 1)
        rp := kern_get(a, 2)
        bp := kern_get(a, 3)
        a_out := kern_read_typ(ap, s)                                           // read back A at depth s
        fresh := mk_d_neut(ap, mk_d_var(s))                                     // fresh neutral variable
        m1 := kern_eval_app(m, fresh)                                           // apply m to the fresh variable
        b := kern_eval(bp, env_extend(rp, fresh))                               // evaluate B under the extended environment
        m_out := kern_read_nf(mk_d_dom(b, m1), s + 1)                           // read back the body at depth s+1
        return mk_fn(a_out, m_out)                                              // lambda A M
    if ak == D_NEUT:
        mk := kern_kind(m)
        if mk == D_NEUT:
            return kern_read_ne(kern_get(m, 2), s)
        // Nested neutral pair.
    return -1

// read_ne
fn kern_read_ne(ne: int, s: int) -> int:
    k := kern_kind(ne)
    if k == D_VAR:
        return mk_var(s - kern_get(ne, 1) - 1)
    // Convert an absolute name to a de Bruijn index.
    if k == D_APP:
        return mk_app(kern_read_ne(kern_get(ne, 1), s), kern_read_nf(kern_get(ne, 2), s))
    if k == D_NATREC:
        m := kern_get(ne, 1)
        rho := kern_get(ne, 2)
        b := kern_get(ne, 3)
        mz := kern_get(ne, 4)
        ms := d_natrec_ms(ne)
        // Evaluate B with a fresh Nat variable and read the result back at depth s+1.
        b1 := kern_eval(b, env_extend(rho, mk_d_neut(mk_d_nat(), mk_d_var(s))))
        b_out := kern_read_typ(b1, s + 1)
        // Evaluate B at zero and read back the zero case at depth s.
        bz := kern_eval(b, env_extend(rho, mk_d_zero()))
        mz_out := kern_read_nf(mk_d_dom(bz, mz), s)
        // Evaluate B and MS for the successor case and read the result back at depth s+2.
        bs := kern_eval(b, env_extend(rho, mk_d_succ(mk_d_neut(mk_d_nat(), mk_d_var(s)))))
        ms1 := kern_eval(ms, env_extend(env_extend(rho, mk_d_neut(mk_d_nat(), mk_d_var(s))), mk_d_neut(b1, mk_d_var(s + 1))))
        ms_out := kern_read_nf(mk_d_dom(bs, ms1), s + 2)
        // Read back the neutral scrutinee.
        m_out := kern_read_ne(m, s)
        return mk_natrec(b_out, mz_out, ms_out, m_out)                          // rec M return B' | zero -> MZ | succ -> MS' end
    return -1

// read_typ
fn kern_read_typ(a: int, s: int) -> int:
    k := kern_kind(a)
    if k == D_UNIV:
        return mk_typ(kern_get(a, 1))
    // Universe to Type.
    if k == D_NAT:
        return mk_nat()
    // Nat to Nat.
    if k == D_PI:
        ap := kern_get(a, 1)
        rp := kern_get(a, 2)
        bp := kern_get(a, 3)
        a_out := kern_read_typ(ap, s)                                           // read back A at depth s
        fresh := mk_d_neut(ap, mk_d_var(s))                                     // fresh neutral variable
        b := kern_eval(bp, env_extend(rp, fresh))                               // evaluate B under the extended environment
        b_out := kern_read_typ(b, s + 1)                                        // read back B at depth s+1
        return mk_pi(a_out, b_out)                                              // Pi A B'
    if k == D_NEUT:
        return kern_read_ne(kern_get(a, 2), s)
    // Neutral type.
    return -1

// Normalization entry points.

// Build the initial environment from oldest to newest binding. The x-th de
// Bruijn variable maps to the absolute name len-1-x.
fn kern_initial_env() -> int:
    rho : ., mut = mk_env_base()
    name : ., mut = 0
    i : ., mut = g_ctx_len - 1
    loop:
        if i < 0:
            break
        a := ctx_get(i)
        va := kern_eval(a, rho)
        rho = env_extend(rho, mk_d_neut(va, mk_d_var(name)))
        name = name + 1
        i = i - 1
    return rho

// Normalize M of type A to nf at readback depth length(Gamma).
fn kern_nbe(m: int, a: int) -> int:
    rho := kern_initial_env()
    da := kern_eval(a, rho)
    dm := kern_eval(m, rho)
    return kern_read_nf(mk_d_dom(da, dm), g_ctx_len)

// Normalize type M to nf.
fn kern_nbe_ty(m: int) -> int:
    rho := kern_initial_env()
    dm := kern_eval(m, rho)
    return kern_read_typ(dm, g_ctx_len)
