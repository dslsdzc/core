// src/kernel/subtype.cr —— 算法子类型（spec §4，Algorithmic/Subtyping/Definitions.v）
// 对应 McTT 源码：theories/Algorithmic/Subtyping/Definitions.v
//   not_univ_pi（L9-13）、alg_subtyping_nf 3 条（L15-27）、alg_subtyping 1 条（L29-35）
// 依赖：nbe.cr（kern_nbe_ty）、kernel_main.cr（nf_eq）
// 接口：subtyping(a, b) -> int（1=是 0/负=否；ctx 从 mctt.cr 全局读）
// 总化（protocol §5）：两侧非类型形态 → no（kern_nbe_ty 失败 → -1 → 0）

// ⊢anf A ⊆ A'：正规形子类型（AlgSub/Definitions.v:15-27，3 条）
fn kern_sub_nf(a: int, b: int) -> int:
    ka := kern_get(a, 0)
    kb := kern_get(b, 0)
    if ka == K_TYP && kb == K_TYP:
        // asnf_univ：i <= j（AlgSub/Definitions.v:20-22）
        return kern_get(a, 1) <= kern_get(b, 1)
    if ka == K_PI && kb == K_PI:
        // asnf_pi：域语法相等 + 余域协变（AlgSub/Definitions.v:23-26）
        // 注意：无逆变前提（McTT 没有 Π 逆变子类型——移植时不得添加）
        if nf_eq(kern_get(a, 1), kern_get(b, 1)) == 0:
            return 0
        return kern_sub_nf(kern_get(a, 2), kern_get(b, 2))
    // asnf_refl：not_univ_pi A ∧ A = A'（AlgSub/Definitions.v:16-19）
    if ka == K_TYP || ka == K_PI:
        return 0
    // not_univ_pi 前置
    return nf_eq(a, b)

// Γ ⊢a A ⊆ B：先规范化两侧到 nf，再在 nf 上比较（AlgSub/Definitions.v:29-35）
fn subtyping(a: int, b: int) -> int:
    a1 := kern_nbe_ty(a)
    b1 := kern_nbe_ty(b)
    if a1 < 0 || b1 < 0:
        return 0
    // 非类型形态 → no（总化）
    return kern_sub_nf(a1, b1)
