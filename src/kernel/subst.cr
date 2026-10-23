fn subst_q(s : int) -> int:
    return mk_extend(mk_compose(s , mk_weaken()) , mk_var(0))

fn subst_id_zero() -> int:
    return mk_extend(mk_id() , mk_zero())

fn subst_wk_wk_succ1() -> int:
    return mk_extend(mk_compose(mk_weaken() , mk_weaken()) , mk_succ(mk_var(1)))

fn subst_id_of(e : int) -> int:
    return mk_extend(mk_id() , e)

// Wk composed n times. Context lookup adds one Wk per level, so index x is
// weakened x+1 times.
fn subst_wk_n(n : int) -> int:
    s : ., mut = mk_weaken()
    i : ., mut = 1
    loop:
        if i >= n:
            break
        s = mk_compose(s , mk_weaken())
        i = i + 1
    return s
