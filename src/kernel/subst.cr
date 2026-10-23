fn subst_q(s : int) -> int:
    return mk_extend(mk_compose(s , mk_weaken()) , mk_var(0))

fn subst_id_zero() -> int:
    return mk_extend(mk_id() , mk_zero())

fn subst_wk_wk_succ1() -> int:
    return mk_extend(mk_compose(mk_weaken() , mk_weaken()) , mk_succ(mk_var(1)))

fn subst_id_of(e : int) -> int:
    return mk_extend(mk_id() , e)

// Wk∘…∘Wk（n 次）——lookup 的弱化计数（TypeCheck.ml lookup 每层递归包一次 Wk，
// 索引 x 的查找结果被弱化 x+1 次；差分对拍 2026-08-28 实测确认）
fn subst_wk_n(n : int) -> int:
    s : ., mut = mk_weaken()
    i : ., mut = 1
    loop:
        if i >= n:
            break
        s = mk_compose(s , mk_weaken())
        i = i + 1
    return s
