// src/kernel/check.cr —— 双向类型检查（spec §3，Algorithmic/Typing/Definitions.v）
// 对应 McTT 源码：theories/Algorithmic/Typing/Definitions.v
//   alg_type_check 1 条（L10-14）、alg_type_infer 9 条（L16-51）
// 依赖：nbe.cr（kern_nbe_ty）、subtype.cr（subtyping）、subst.cr、mctt.cr（ctx）
// 接口：type_check(a, m) -> int（1=接受 0/负=拒绝；(类型, 项)——CLI 已交换）
//       type_infer(m) -> int（返回推断类型 nf 节点；-1=拒绝）
// 总化（protocol §5）：任何前提失败 → -1（reject）；推断结果一律 nf（spec §3 要点）

fn ctx_pop():
    if g_ctx_len > 0:
        g_ctx_len = g_ctx_len - 1

// Γ ⊢a M ⟸ A：唯一检查规则 atc_ati——推断 + 子类型（AlgTyp/Definitions.v:11-14）
fn type_check(a: int, m: int) -> int:
    ta := type_infer(m)
    if ta < 0:
        return 0
    return subtyping(ta, a)

// Γ ⊢a M ⟹ A：9 条推断规则（AlgTyp/Definitions.v:17-51）
fn type_infer(m: int) -> int:
    k := kern_kind(m)
    if k == K_TYP:
        return mk_typ(kern_get(m, 1) + 1)
    // ati_typ：Type@i ⟹ Type@(S i)
    if k == K_NAT:
        return mk_typ(0)
    // ati_nat：ℕ ⟹ Type@0
    if k == K_ZERO:
        return mk_nat()
    // ati_zero：zero ⟹ ℕ
    if k == K_SUCC:
        // ati_succ：Γ ⊢a M ⟸ ℕ
        if type_check(mk_nat(), kern_get(m, 1)) <= 0:
            return -1
        return mk_nat()
    if k == K_VAR:
        // ati_vlookup：#x : A ∈ Γ；nbe_ty Γ (A[Wk^(x+1)])——提取 lookup 每层
        // 递归包一次 Wk（TypeCheck.ml lookup），索引 x 弱化 x+1 次；
        // 差分对拍 2026-08-28 实测确认（探针：1 次 Wk → var 1，2 次 → var 2）
        x := kern_get(m, 1)
        a := ctx_get(x)
        if a < 0:
            return -1
        // 越界（自由变量）→ reject
        return kern_nbe_ty(mk_sub(a, subst_wk_n(x + 1)))
    if k == K_PI:
        // ati_pi：Γ ⊢ A ⟹ Type@i；Γ,A ⊢ B ⟹ Type@j → Type@(max i j)
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
        // ati_fn：Γ ⊢ A ⟹ Type@i；Γ,A ⊢ M ⟹ B；nbe_ty Γ A C → Π C B
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
        c := kern_nbe_ty(a)                                             // nbe_ty Γ A（原始 ctx）
        if c < 0:
            return -1
        return mk_pi(c, tb)
    if k == K_APP:
        // ati_app：Γ ⊢ M ⟹ Π A B；Γ ⊢ N ⟸ A；nbe_ty Γ B[Id,,N] C
        mm := kern_get(m, 1)
        nn := kern_get(m, 2)
        tm := type_infer(mm)
        if tm < 0 || kern_kind(tm) != K_PI:
            return -1
        a := kern_get(tm, 1)
        b := kern_get(tm, 2)
        if type_check(a, nn) <= 0:
            return -1
        c := kern_nbe_ty(mk_sub(b, subst_id_of(nn)))                    // B[Id,,N]
        if c < 0:
            return -1
        return c
    if k == K_NATREC:
        // ati_natrec：Γ,ℕ ⊢ A ⟹ Type@i；Γ ⊢ MZ ⟸ A[Id,,zero]；
        //            Γ,ℕ,A ⊢ MS ⟸ A[Wk∘Wk,,succ #1]；Γ ⊢ M ⟸ ℕ；
        //            nbe_ty Γ A[Id,,M] B（AlgTyp/Definitions.v:26-32）
        a := kern_get(m, 1)
        mz := kern_get(m, 2)
        ms := kern_get(m, 3)
        mm := kern_get(m, 4)
        ctx_extend(mk_nat())                                            // Γ,ℕ
        ta := type_infer(a)
        if ta < 0 || kern_kind(ta) != K_TYP:
            ctx_pop()
            return -1
        ctx_pop()                                                       // 回 Γ
        if type_check(mk_sub(a, subst_id_zero()), mz) <= 0:
            return -1
        // MZ ⟸ A[Id,,zero]（Γ 下）
        ctx_extend(mk_nat())                                            // Γ,ℕ
        ctx_extend(a)                                                   // Γ,ℕ,A
        if type_check(mk_sub(a, subst_wk_wk_succ1()), ms) <= 0:
            ctx_pop()
            ctx_pop()
            return -1
        ctx_pop()                                                       // 回 Γ,ℕ
        ctx_pop()                                                       // 回 Γ
        if type_check(mk_nat(), mm) <= 0:
            return -1
        // M ⟸ ℕ（Γ 下）
        b := kern_nbe_ty(mk_sub(a, subst_id_of(mm)))                    // nbe_ty Γ A[Id,,M]
        if b < 0:
            return -1
        return b
    return -1                                                           // 其他形态（含顶层 sub）→ reject
