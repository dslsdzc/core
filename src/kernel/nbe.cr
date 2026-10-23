// src/kernel/nbe.cr —— NbE：求值 + 读出 + 规范化（spec §5，Semantic/）
// 对应 McTT 源码：Semantic/Domain.v、Semantic/Evaluation/Definitions.v、
// Semantic/Readback/Definitions.v、Semantic/NbE.v。
// 依赖：mctt.cr（K_* 构造子 + 上下文）、subst.cr、term_io.cr（arena）。
// 结构：① 语义域 D_*（§5.1）② 环境 ③ 求值 eval（§5.2，19 条规则）
//       ④ 读出 read（§5.3，12 条规则）⑤ 规范化 nbe/nbe_ty（§5.5）。
// 关键约定：绝对名（d_var）≠ de Bruijn 索引——初始环境绑定（§5.4），
// read_ne_var 换算回 #(s-x-1)（§5.3）。

// ── ① 语义域（§5.1 Domain.v）──
// 与 K_*（0-9）不冲突：D_* = 10+
D_NAT : int = 10   // ℕ 的语义值
D_PI : int = 11    // Π a ρ B（B 不求值，闭包存 ρ）
D_UNIV : int = 12  // 𝕌@i
D_ZERO : int = 13
D_SUCC : int = 14
D_FN : int = 15    // λ ρ M（A 不参与求值）
D_NEUT : int = 16  // ⇑ a m（类型标注 a + neutral m）
D_VAR : int = 17   // !x —— 绝对名
D_APP : int = 18   // m n（neutral 应用）
D_NATREC : int = 19// rec m under ρ return P | zero -> mz | succ -> MS end
D_NATREC2 : int = 20// D_NATREC 的载荷组标记（MS 存槽 6，永不分发）
D_DOM : int = 21   // ⇓ a m（类型+值配对，domain_nf）
// 环境节点（§5.1 env 的函数式表示——与提取的 extend_env/drop_env 同构；
// 差分对拍 2026-08-28 发现 count 式 env 在闭包快照被后续追加穿插时索引错位，
// 改链式节点：extend/drop 都是 O(1) 节点，查找沿链走）
D_ENV_BASE : int = 22  // 空基环境（extend 链的底）
D_ENV_EXT : int = 23   // {D_ENV_EXT, parent, d, 0, 0}：x=0 → d，否则 parent(x-1)
D_ENV_DROP : int = 24  // {D_ENV_DROP, parent, 0, 0, 0}：x → parent(x+1)

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
// D_NATREC 有 5 个成分（m ρ P mz MS），五槽装不下——MS 存下一组的槽 1（= 槽 6）
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
    // 载荷组分配失败：整组放弃（arena 追加式，无回滚必要）
    kern_set(n, 6, ms)
    return n
fn d_natrec_ms(n: int) -> int:
    return kern_get(n, 6)
fn mk_d_dom(a: int, m: int) -> int:
    n := kern_new(D_DOM)
    kern_set(n, 1, a)
    kern_set(n, 2, m)
    return n

// ── ② 环境（§5.1 env/empty_env/extend_env/drop_env）──
// env = arena 节点链（函数式，同提取的 extend_env/drop_env）：
//   env_get(ρ, x) = de Bruijn x（0 = 最新）；EXT: x=0 → d，否则 parent(x-1)；
//   DROP: parent(x+1)；BASE: 越界 → -1
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
    // 空基：d_zero——env 全函数（提取 empty_env _ = d_zero，
                                                  // Domain.ml；越界求值 = d_zero，差分对拍 2026-08-28 实测）
    return -1

// ── ③ 求值（§5.2 Eval/Definitions.v，19 条规则）──

// eval_exp（10 条）：exp + env → domain
fn kern_eval(e: int, rho: int) -> int:
    k := kern_kind(e)
    if k == K_TYP:
        return mk_d_univ(kern_get(e, 1))
    // ⟦Type@i⟧ = 𝕌@i
    if k == K_NAT:
        return mk_d_nat()
    // ⟦ℕ⟧ = ℕ
    if k == K_ZERO:
        return mk_d_zero()
    // ⟦zero⟧ = zero
    if k == K_SUCC:
        return mk_d_succ(kern_eval(kern_get(e, 1), rho))
    // ⟦succ M⟧
    if k == K_VAR:
        return env_get(rho, kern_get(e, 1))
    // ⟦#x⟧ρ = ρ x
    if k == K_PI:
        return mk_d_pi(kern_eval(kern_get(e, 1), rho), rho, kern_get(e, 2))
    // B 不求值
    if k == K_FN:
        return mk_d_fn(rho, kern_get(e, 2))
    // A 不参与求值
    if k == K_APP:
        return kern_eval_app(kern_eval(kern_get(e, 1), rho), kern_eval(kern_get(e, 2), rho))
    if k == K_NATREC:
        return kern_eval_natrec(kern_eval(kern_get(e, 4), rho), kern_get(e, 1), kern_get(e, 2), kern_get(e, 3), rho)
    if k == K_SUB:
        return kern_eval(kern_get(e, 1), kern_eval_sub(kern_get(e, 2), rho))
    // 替换→环境→求值
    return -1

// eval_natrec（3 条）：domain 上的递归
fn kern_eval_natrec(m: int, a: int, mz: int, ms: int, rho: int) -> int:
    k := kern_kind(m)
    if k == D_ZERO:
        return kern_eval(mz, rho)
    // rec zero ↘ ⟦MZ⟧ρ
    if k == D_SUCC:
        b := kern_get(m, 1)
        r := kern_eval_natrec(b, a, mz, ms, rho)                                // 递归 r
        return kern_eval(ms, env_extend(env_extend(rho, b), r))                 // ⟦MS⟧ ρ↦b↦r
    if k == D_NEUT:
        ne := kern_get(m, 2)
        a2 := kern_eval(a, env_extend(rho, m))                                  // ⟦A⟧ ρ↦⇑b m
        return mk_d_neut(a2, mk_d_natrec(ne, rho, a, kern_eval(mz, rho), ms))   // 保持 neutral
    return -1

// eval_app（2 条）：$|m & n|↘ r
fn kern_eval_app(m: int, n: int) -> int:
    k := kern_kind(m)
    if k == D_FN:
        return kern_eval(kern_get(m, 2), env_extend(kern_get(m, 1), n))
    // λρM 展开
    if k == D_NEUT:
        a := kern_get(m, 1)
        if kern_kind(a) == D_PI:
            ap := kern_get(a, 1)
            rp := kern_get(a, 2)
            bp := kern_get(a, 3)
            b := kern_eval(bp, env_extend(rp, n))                               // ⟦B⟧ ρ↦n
            return mk_d_neut(b, mk_d_app(kern_get(m, 2), mk_d_dom(ap, n)))      // ⇑b (m (⇓a n))
    return -1

// eval_sub（4 条）：替换 → 环境（⟦σ⟧s ρ ↘ ρσ）
fn kern_eval_sub(s: int, rho: int) -> int:
    k := kern_kind(s)
    if k == K_SUB:
        sk := kern_get(s, 4)
        if sk == S_ID:
            return rho
        // ⟦Id⟧ ρ = ρ
        if sk == S_WEAKEN:
            return env_drop(rho)
        // ⟦Wk⟧ ρ = ρ↯
        if sk == S_EXTEND:
            rs := kern_eval_sub(kern_get(s, 1), rho)                            // ρσ
            return env_extend(rs, kern_eval(kern_get(s, 2), rho))               // ρσ ↦ m
        if sk == S_COMPOSE:
            rt := kern_eval_sub(kern_get(s, 2), rho)                            // ⟦τ⟧ ρ（τ 先作用）
            return kern_eval_sub(kern_get(s, 1), rt)                            // ⟦σ⟧ ρτ
    return -1

// ── ④ 读出（§5.3 Readback/Definitions.v，12 条规则）──
// domain + 深度 s → nf/ne（exp 节点！）；绝对名 → de Bruijn：!x → #(s-x-1)

// read_nf（6 条）
fn kern_read_nf(d: int, s: int) -> int:
    a := kern_get(d, 1)
    m := kern_get(d, 2)                                    // ⇓ a m
    ak := kern_kind(a)
    if ak == D_UNIV:
        return kern_read_typ(m, s)
    // ⇓𝕌@i a
    if ak == D_NAT:
        mk := kern_kind(m)
        if mk == D_ZERO:
            return mk_zero()
        // ⇓ℕ zero
        if mk == D_SUCC:
            return mk_succ(kern_read_nf(mk_d_dom(a, kern_get(m, 1)), s))
        if mk == D_NEUT:
            return kern_read_ne(kern_get(m, 2), s)
        // ⇓ℕ (⇑a' m)
        return -1
    if ak == D_PI:
        // η 展开（read_nf_fn）：应用到新鲜绝对名 s，深度 +1
        ap := kern_get(a, 1)
        rp := kern_get(a, 2)
        bp := kern_get(a, 3)
        a_out := kern_read_typ(ap, s)                                           // A = Rtyp a in s
        fresh := mk_d_neut(ap, mk_d_var(s))                                     // ⇑! a s
        m1 := kern_eval_app(m, fresh)                                           // $|m & ⇑!a s|
        b := kern_eval(bp, env_extend(rp, fresh))                               // ⟦B⟧ ρ↦⇑!a s
        m_out := kern_read_nf(mk_d_dom(b, m1), s + 1)                           // Rnf ⇓b m' in S s
        return mk_fn(a_out, m_out)                                              // λ A M
    if ak == D_NEUT:
        mk := kern_kind(m)
        if mk == D_NEUT:
            return kern_read_ne(kern_get(m, 2), s)
        // ⇓(⇑a b)(⇑c m)
    return -1

// read_ne（3 条）
fn kern_read_ne(ne: int, s: int) -> int:
    k := kern_kind(ne)
    if k == D_VAR:
        return mk_var(s - kern_get(ne, 1) - 1)
    // !x → #(s-x-1)
    if k == D_APP:
        return mk_app(kern_read_ne(kern_get(ne, 1), s), kern_read_nf(kern_get(ne, 2), s))
    if k == D_NATREC:
        m := kern_get(ne, 1)
        rho := kern_get(ne, 2)
        b := kern_get(ne, 3)
        mz := kern_get(ne, 4)
        ms := d_natrec_ms(ne)
        // ⟦B⟧ ρ↦⇑!ℕs ↘ b1；Rtyp b1 in S s ↘ B'
        b1 := kern_eval(b, env_extend(rho, mk_d_neut(mk_d_nat(), mk_d_var(s))))
        b_out := kern_read_typ(b1, s + 1)
        // ⟦B⟧ ρ↦zero ↘ bz；Rnf ⇓bz mz in s ↘ MZ
        bz := kern_eval(b, env_extend(rho, mk_d_zero()))
        mz_out := kern_read_nf(mk_d_dom(bz, mz), s)
        // ⟦B⟧ ρ↦succ(⇑!ℕs) ↘ bs；⟦MS⟧ ρ↦⇑!ℕs↦⇑!b(Ss) ↘ ms'；Rnf ⇓bs ms' in S(S s) ↘ MS'
        bs := kern_eval(b, env_extend(rho, mk_d_succ(mk_d_neut(mk_d_nat(), mk_d_var(s)))))
        ms1 := kern_eval(ms, env_extend(env_extend(rho, mk_d_neut(mk_d_nat(), mk_d_var(s))), mk_d_neut(b1, mk_d_var(s + 1))))
        ms_out := kern_read_nf(mk_d_dom(bs, ms1), s + 2)
        // Rne m in s ↘ M
        m_out := kern_read_ne(m, s)
        return mk_natrec(b_out, mz_out, ms_out, m_out)                          // rec M return B' | zero -> MZ | succ -> MS' end
    return -1

// read_typ（4 条）
fn kern_read_typ(a: int, s: int) -> int:
    k := kern_kind(a)
    if k == D_UNIV:
        return mk_typ(kern_get(a, 1))
    // 𝕌@i → Type@i
    if k == D_NAT:
        return mk_nat()
    // ℕ → ℕ
    if k == D_PI:
        ap := kern_get(a, 1)
        rp := kern_get(a, 2)
        bp := kern_get(a, 3)
        a_out := kern_read_typ(ap, s)                                           // Rtyp a in s
        fresh := mk_d_neut(ap, mk_d_var(s))                                     // ⇑! a s
        b := kern_eval(bp, env_extend(rp, fresh))                               // ⟦B⟧ ρ↦⇑!a s
        b_out := kern_read_typ(b, s + 1)                                        // Rtyp b in S s
        return mk_pi(a_out, b_out)                                              // Π A B'
    if k == D_NEUT:
        return kern_read_ne(kern_get(a, 2), s)
    // ⇑ a b → ⇑ B
    return -1

// ── ⑤ 规范化入口（§5.4 initial_env + §5.5 nbe/nbe_ty）──

// initial_env Γ ρ：从最旧到最新绑定，第 x 个 de Bruijn 变量 → 绝对名 (len-1-x)
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

// nbe Γ M A：M : A 规范化为 nf（读入深度 = length Γ）
fn kern_nbe(m: int, a: int) -> int:
    rho := kern_initial_env()
    da := kern_eval(a, rho)
    dm := kern_eval(m, rho)
    return kern_read_nf(mk_d_dom(da, dm), g_ctx_len)

// nbe_ty Γ M：类型 M 规范化为 nf
fn kern_nbe_ty(m: int) -> int:
    rho := kern_initial_env()
    dm := kern_eval(m, rho)
    return kern_read_typ(dm, g_ctx_len)
