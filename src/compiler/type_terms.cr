// === type_terms.cr ===
// R2 P0：类型项表（集合语义的类型项 DAG）
// 语义见 spec §1：τ ::= ⊥ | ⊤ | ⊤ₖ | τ₁∪τ₂ | τ₁∩τ₂ | ¬τ | μX.τ | X | k(τ₁…τₙ)
// 条目 48B {tag, a, b, c, d, hash}；同构项共享（DAG），索引 = 开放寻址哈希表 g_tt_index。
// 本文件只做「表示 + 构造去重」；判定在 type_engine.cr，规范化（NNF/DNF）在 Task 2。
//
// 哈希面注记（与计划代码的偏差逐条见 Task 1 报告）：
//   ① 本语言无位异或算子（lexer 无 caret/CARET token，ast.cr OP_* 无 BXOR），
//      FNV-1a 的 `h ^ byte` 改用本仓库既有 FNV-1 加法折叠（dyn_arr.cr hash_bytes 同族：
//      h = h * prime + byte）——确定性、与插入顺序无关，正是 DAG 去重所需的键性质。
//   ② 槽位一律经 tt_mod 取非负（计划同日同款修正；负数取模 = 负下标 → 探针越界 →
//      扩容后去重静默失效，原生压力测试实证）。
//   ③ 键 = 五字段全比，哈希不入键（只定位槽位）——见 tt_term 内注记。

// ─── 标签常量（TT_*；与 ast.cr 的 TI_* 类型 kind 无关——本层是类型项语言）───
TT_BOT : int = 0;   TT_TOP : int = 1;   TT_TOP_K : int = 2;
TT_UNION : int = 3; TT_INTER : int = 4; TT_NOT : int = 5;
TT_MU : int = 6;    TT_ATOM : int = 7;  TT_VAR : int = 8;
TT_NIL : int = 9;   TT_CONS : int = 10;

// 条目 = 48B，六字段各 8B（与 g_ir_entries 同风格：字节缓冲 + 偏移常量）
ESZ_TYPE_TERM : int = 48;
OFF_TT_TAG : int = 0;  OFF_TT_A : int = 8;   OFF_TT_B : int = 16;
OFF_TT_C : int = 24;   OFF_TT_D : int = 32;  OFF_TT_HASH : int = 40;

// ─── 访问器（i = 类型项行号；调用方保证 0 ≤ i < tt_count()）───
fn tt_tag(i: int) -> int { return r64(g_type_terms, i * ESZ_TYPE_TERM + OFF_TT_TAG); }
fn tt_a(i: int) -> int { return r64(g_type_terms, i * ESZ_TYPE_TERM + OFF_TT_A); }
fn tt_b(i: int) -> int { return r64(g_type_terms, i * ESZ_TYPE_TERM + OFF_TT_B); }
fn tt_c(i: int) -> int { return r64(g_type_terms, i * ESZ_TYPE_TERM + OFF_TT_C); }
fn tt_d(i: int) -> int { return r64(g_type_terms, i * ESZ_TYPE_TERM + OFF_TT_D); }
fn tt_count() -> int { return g_type_term_count; }

// ─── 结构哈希（DAG 去重的键：五字段 fold，与插入顺序无关）───
fn tt_hash5(tag: int, a: int, b: int, c: int, d: int) -> int {
    h : ., mut = 1469598103934665603;
    slot : ., mut = 0;
    loop {
        if slot >= 5 { break; }
        v : ., mut = tag;
        if slot == 1 { v = a; } else if slot == 2 { v = b; }
        else if slot == 3 { v = c; } else if slot == 4 { v = d; }
        k : ., mut = 0;
        loop {
            if k >= 8 { break; }
            byte : ., mut = v % 256;
            if byte < 0 { byte = -byte; }
            h = h * 1099511628211 + byte;
            v = v / 256;
            k = k + 1;
        }
        slot = slot + 1;
    }
    return h;
}

// 非负槽位（**不要写 h - (h/cap)*cap**：i64 除法向零截断，h 为负时该式得负下标 →
// 探针越界 → 去重静默失效；2026-09-10 P0 Task 1 原生压力测试实证扩容后 dedup 全灭，
// 计划同日同款修正 = 本函数）。
// 先取余再取绝对值：|h % cap| < cap ≤ 2^63，取负不溢出（cap 恒为 2 的幂，见
// grow_tt_index）；本仓库先例 = str_intern 的 `pos := h % cap; if pos < 0 { pos = -pos; }`。
fn tt_mod(h: int, cap: int) -> int {
    m : ., mut = h % cap;
    if m < 0 { m = 0 - m; }
    return m;
}

// ─── 扩容（本文件自持，**不置 dyn_arr.cr**）───
// 计划 Step 4 把两函数放在 dyn_arr.cr（照 grow_types 先例），实测该位置破坏
// corearch 单元：dyn_arr.cr 属双 concat 共享面（build_selfhost_native.py 的
// common_files），而 type_terms.cr 只入 corec 清单——共享文件里引用引擎符号 =
// corearch 解析期 `Undefined name: ESZ_TYPE_TERM / tt_reindex` 硬失败（实测）。
// 引擎自持扩容 + 常量，共享面零改动，corearch/corelsp 不受影响。
fn grow_type_terms(needed: int) {
    if needed < g_type_term_cap { return; }
    nc : ., mut = g_type_term_cap * 2;
    if nc < 256 { nc = 256; }
    if nc < needed { nc = needed + 64; }
    nb := alloc(nc * ESZ_TYPE_TERM);
    _dyncpy(g_type_terms, g_type_term_cap * ESZ_TYPE_TERM, nb);
    g_type_terms = nb;
    g_type_term_cap = nc;
}

fn grow_tt_index(needed: int) {
    // 开放寻址索引：容量取 2 的幂、**≥ 2×现有项数**（重建式扩容，见 tt_reindex）。
    // 「≥ 2×项数」不是可选项：tt_reindex 的重放插入**没有**装填因子守卫，若新表按
    // needed 定得过小（如调用方传 2、而现有项已 >512），重放时探测永不落空 = 死循环
    // （P0 自测守门用例实证：`g_tt_index_cap = 0; grow_tt_index(2)` 直接挂死）。
    if needed < g_tt_index_cap { return; }
    nc : ., mut = 1024;
    need2 : ., mut = needed;
    if (g_type_term_count + 1) * 2 > need2 { need2 = (g_type_term_count + 1) * 2; }
    loop { if nc >= need2 { break; } nc = nc * 2; }
    nb := alloc(nc * 8);
    i : ., mut = 0;
    loop { if i >= nc { break; } w64(nb, i * 8, -1); i = i + 1; }
    g_tt_index = nb;
    g_tt_index_cap = nc;
    g_tt_index_count = 0;
    tt_reindex();
}

// ─── 索引重建（grow_tt_index 扩容后调用：清表 + 重放全部项的开放寻址插入）───
fn tt_reindex() {
    i : ., mut = 0;
    loop {
        if i >= g_type_term_count { break; }
        h := r64(g_type_terms, i * ESZ_TYPE_TERM + OFF_TT_HASH);
        cap := g_tt_index_cap;
        p : ., mut = tt_mod(h, cap);
        loop {
            if r64(g_tt_index, p * 8) < 0 { break; }
            p = p + 1; if p >= cap { p = 0; }
        }
        w64(g_tt_index, p * 8, i);
        g_tt_index_count = g_tt_index_count + 1;
        i = i + 1;
    }
}

// 同构比较（五字段全比——DAG 键；哈希相同与否不参与，见 tt_term 内注记）
fn tt_same(i: int, j: int) -> int {
    if tt_tag(i) != tt_tag(j) { return 0; }
    if tt_a(i) != tt_a(j) { return 0; }
    if tt_b(i) != tt_b(j) { return 0; }
    if tt_c(i) != tt_c(j) { return 0; }
    if tt_d(i) != tt_d(j) { return 0; }
    return 1;
}

// ─── 构造/复用（DAG 去重的唯一入口）───
fn tt_term(tag: int, a: int, b: int, c: int, d: int) -> int {
    if g_tt_index_cap <= 0 { grow_tt_index(2); }
    h := tt_hash5(tag, a, b, c, d);
    ret : ., mut = -1;
    loop {
        // 装填因子守卫：探测前扩容（扩容 = 重建索引，故探测位置不会中途失配）；
        // 扩容后重试同一轮（loop 而非递归——避免深递归与重复增长）。
        if (g_type_term_count + 1) * 2 >= g_tt_index_cap { grow_tt_index((g_type_term_count + 1) * 2); }
        cap := g_tt_index_cap;
        p : ., mut = tt_mod(h, cap);
        loop {
            idx := r64(g_tt_index, p * 8);
            if idx < 0 { break; }
            // 键比较 = 五字段全比（DAG 键）；**不**把「存储哈希 == 重算哈希」并入键：
            // 该等式只在 i64 回绕语义下恒真（x86-64 后端成立），而 bootstrap 解释器
            // 为任意精度整数（interpreter.py 二元运算无回绕）——重算 h 不回绕、落盘
            // 哈希经 w64/r64 截断到 i64，等式恒假 → 去重静默退化为「只插不查」。
            // 哈希在本层的唯一职责 = 槽位定位（插入与 tt_reindex 重放同用），
            // 故键只认五字段；碰撞（含上述截断差）仅令探测链变长，不改变结果。
            if tt_tag(idx) == tag && tt_a(idx) == a && tt_b(idx) == b &&
               tt_c(idx) == c && tt_d(idx) == d { ret = idx; break; }
            p = p + 1; if p >= cap { p = 0; }
        }
        if ret >= 0 { break; }
        // 未命中：追加新项，写入本轮探测到的空槽（轮内索引未被改动）
        grow_type_terms(g_type_term_count + 1);
        i := g_type_term_count;
        w64(g_type_terms, i * ESZ_TYPE_TERM + OFF_TT_TAG, tag);
        w64(g_type_terms, i * ESZ_TYPE_TERM + OFF_TT_A, a);
        w64(g_type_terms, i * ESZ_TYPE_TERM + OFF_TT_B, b);
        w64(g_type_terms, i * ESZ_TYPE_TERM + OFF_TT_C, c);
        w64(g_type_terms, i * ESZ_TYPE_TERM + OFF_TT_D, d);
        w64(g_type_terms, i * ESZ_TYPE_TERM + OFF_TT_HASH, h);
        g_type_term_count = i + 1;
        w64(g_tt_index, p * 8, i);
        g_tt_index_count = g_tt_index_count + 1;
        ret = i;
        break;
    }
    return ret;
}

// ─── 构造 API ───
// 惰性 memo：0 = 未建 + ready 位（零初值惯例——全局 `= -1` 初值在 bootstrap
// 后端会被降级为 0，见 globals.cr 声明段注记）
fn tt_bot() -> int { return tt_term(TT_BOT, 0, 0, 0, 0); }

fn tt_top() -> int {
    if g_tt_top_ok == 0 { g_tt_top = tt_term(TT_TOP, 0, 0, 0, 0); g_tt_top_ok = 1; }
    return g_tt_top;
}

fn tt_top_k(k: int) -> int { return tt_term(TT_TOP_K, k, 0, 0, 0); }

fn tt_union(a: int, b: int) -> int {
    if a == b { return a; }
    if tt_tag(a) == TT_BOT { return b; }
    if tt_tag(b) == TT_BOT { return a; }
    if tt_tag(a) == TT_TOP || tt_tag(b) == TT_TOP { return tt_top(); }
    return tt_term(TT_UNION, a, b, 0, 0);
}

fn tt_inter(a: int, b: int) -> int {
    if a == b { return a; }
    if tt_tag(a) == TT_TOP { return b; }
    if tt_tag(b) == TT_TOP { return a; }
    if tt_tag(a) == TT_BOT || tt_tag(b) == TT_BOT { return tt_bot(); }
    return tt_term(TT_INTER, a, b, 0, 0);
}

fn tt_not(a: int) -> int {
    if tt_tag(a) == TT_BOT { return tt_top(); }
    if tt_tag(a) == TT_TOP { return tt_bot(); }
    if tt_tag(a) == TT_NOT { return tt_a(a); }   // 双重否定免费（构造面代数律）
    return tt_term(TT_NOT, a, 0, 0, 0);
}

fn tt_mu(v: int, body: int) -> int { return tt_term(TT_MU, v, body, 0, 0); }
fn tt_var(v: int) -> int { return tt_term(TT_VAR, v, 0, 0, 0); }

fn tt_nil() -> int {
    if g_tt_nil_ok == 0 { g_tt_nil = tt_term(TT_NIL, 0, 0, 0, 0); g_tt_nil_ok = 1; }
    return g_tt_nil;
}

fn tt_cons(head: int, tail: int) -> int { return tt_term(TT_CONS, head, tail, 0, 0); }
fn tt_atom(ak: int, ti: int, params: int) -> int { return tt_term(TT_ATOM, ak, ti, params, 0); }

// ─── NNF（否定下推）与 DNF 规范化（R2 P0 Task 2）───
// 语义（spec §1.3）：规范化输出 = DNF（union of products；product = 字面集合）。
// 本层只做「形态规整」——语义判定（覆盖/等价/可空/反例）在 type_engine.cr。

// 参数链逐元素 NNF（ATOM 的 params = CONS 链；-1 = 无参）
fn tt_nnf_list(p: int) -> int {
    if p < 0 { return -1; }
    if tt_tag(p) != TT_CONS { return tt_nnf(p); }
    return tt_cons(tt_nnf(tt_a(p)), tt_nnf_list(tt_b(p)));
}

// 正位置 NNF：结构不变，否定下推（¬(∪) → ∩(¬)、¬(∩) → ∪(¬)、¬¬ 消，均在负位置函数里）
fn tt_nnf(i: int) -> int {
    t := tt_tag(i);
    if t == TT_NOT { return tt_nnf_neg(tt_a(i)); }
    if t == TT_UNION { return tt_union(tt_nnf(tt_a(i)), tt_nnf(tt_b(i))); }
    if t == TT_INTER { return tt_inter(tt_nnf(tt_a(i)), tt_nnf(tt_b(i))); }
    if t == TT_MU { return tt_mu(tt_a(i), tt_nnf(tt_b(i))); }
    if t == TT_ATOM { return tt_atom(tt_a(i), tt_b(i), tt_nnf_list(tt_c(i))); }
    if t == TT_CONS { return tt_nnf_list(i); }
    return i;   // ⊥ / ⊤ / ⊤ₖ / VAR / NIL：字面，原样
}

// 负位置 NNF：计算 ¬i 的 NNF
fn tt_nnf_neg(i: int) -> int {
    t := tt_tag(i);
    if t == TT_BOT { return tt_top(); }
    if t == TT_TOP { return tt_bot(); }
    if t == TT_NOT { return tt_nnf(tt_a(i)); }          // ¬¬i = i
    if t == TT_UNION { return tt_inter(tt_nnf_neg(tt_a(i)), tt_nnf_neg(tt_b(i))); }
    if t == TT_INTER { return tt_union(tt_nnf_neg(tt_a(i)), tt_nnf_neg(tt_b(i))); }
    if t == TT_MU {
        // ¬μX.F ≠ μX.¬F（后者需要 ν 绑定）——**不静默做非等价改写**（P0 终审 Important D）：
        // 保留 ¬(μ…) 为字面（tt_is_literal 接受）+ 登记未覆盖面；判定侧走保守路径（不覆盖）
        g_ty_uncovered = 1;
        return tt_not(i);
    }
    return tt_not(i);   // 字面取反：¬ATOM / ¬VAR / ¬⊤ₖ
}

// 参数链逐元素 DNF（参数内的分配律同样要做）
fn tt_dnf_list(p: int) -> int {
    if p < 0 { return -1; }
    if tt_tag(p) != TT_CONS { return tt_dnf(p); }
    return tt_cons(tt_dnf(tt_a(p)), tt_dnf_list(tt_b(p)));
}

// DNF：∩ 分配到 ∪ 上（(A∪B)∩C → (A∩C)∪(B∩C)）；叶子 = product（∩-链）或字面
// 全程计预算；-1 = 预算耗尽（上抛，不得当 0/形态用）
fn tt_dnf(i: int) -> int {
    if tt_step() == -1 { return -1; }
    t := tt_tag(i);
    if t == TT_UNION {
        a1 := tt_dnf(tt_a(i));
        if a1 < 0 { return -1; }
        b1 := tt_dnf(tt_b(i));
        if b1 < 0 { return -1; }
        return tt_union(a1, b1);
    }
    if t == TT_INTER {
        l := tt_dnf(tt_a(i));
        if l < 0 { return -1; }
        r := tt_dnf(tt_b(i));
        if r < 0 { return -1; }
        // 分配律必须**两支都展开**：(A∪B)∩C → (A∩C) ∪ (B∩C)。
        // 只展开一支 = 静默丢项（P0 Task 2 自测实证：norm.distributed got INTER want UNION
        // ——计划骨架同样写错，本实现已修）。
        if tt_tag(l) == TT_UNION {
            x := tt_dnf(tt_inter(tt_a(l), r));
            if x < 0 { return -1; }
            y := tt_dnf(tt_inter(tt_b(l), r));
            if y < 0 { return -1; }
            return tt_union(x, y);
        }
        if tt_tag(r) == TT_UNION {
            x := tt_dnf(tt_inter(l, tt_a(r)));
            if x < 0 { return -1; }
            y := tt_dnf(tt_inter(l, tt_b(r)));
            if y < 0 { return -1; }
            return tt_union(x, y);
        }
        return tt_inter(l, r);
    }
    if t == TT_MU {
        b1 := tt_dnf(tt_b(i));
        if b1 < 0 { return -1; }
        return tt_mu(tt_a(i), b1);
    }
    if t == TT_ATOM { return tt_atom(tt_a(i), tt_b(i), tt_dnf_list(tt_c(i))); }
    return i;
}

// 预算步进（**规范化也计入**——P0 终审 Important C 实证：∩ 分配律在 n 元联合下
// 词项数 2^n 爆炸（n=16 → 29 万项）而 exhausted 恒 0，预算形同虚设）。
fn tt_step() -> int {
    if g_ty_budget_max <= 0 { g_ty_budget_max = 200000; }
    g_ty_steps = g_ty_steps + 1;
    if g_ty_steps > g_ty_budget_max { g_ty_exhausted = 1; return -1; }
    return 0;
}

// 规范化入口（NNF → DNF；DAG 去重使「同形同项」免费）——-1 = 预算耗尽（调用方必须上抛）
fn tt_norm(i: int) -> int {
    n := tt_nnf(i);
    if n < 0 { return -1; }
    return tt_dnf(n);
}

// ─── 形态判定（自测断言与引擎前置检查共用）───
fn tt_is_literal(i: int) -> int {
    t := tt_tag(i);
    if t == TT_ATOM || t == TT_VAR || t == TT_TOP_K || t == TT_BOT || t == TT_TOP { return 1; }
    if t == TT_NOT {
        it := tt_tag(tt_a(i));
        // NOT(MU) 亦为字面：¬μ 不下推动（见 tt_nnf_neg 的 MU 分支）
        if it == TT_ATOM || it == TT_VAR || it == TT_TOP_K || it == TT_MU { return 1; }
    }
    return 0;
}

fn tt_is_product_chain(i: int) -> int {
    if tt_tag(i) == TT_INTER {
        if tt_tag(tt_a(i)) == TT_UNION || tt_tag(tt_b(i)) == TT_UNION { return 0; }
        if tt_is_product_chain(tt_a(i)) == 0 { return 0; }
        return tt_is_product_chain(tt_b(i));
    }
    return tt_is_literal(i);
}

// DNF 成员：union 的子项 = product 或字面（不得再嵌 union）
fn tt_is_dnf_member(i: int) -> int {
    if tt_tag(i) == TT_UNION { return 0; }
    if tt_tag(i) == TT_INTER { return tt_is_product_chain(i); }
    return tt_is_literal(i);
}

fn tt_is_dnf(i: int) -> int {
    // union 是**左深嵌套**（tt_union 不扁平化）→ 必须递归接受 n 元析取：
    // 早期版本对子项调 tt_is_dnf_member（要求子项非 union）→ ≥3 析取的合法 DNF 被误判 0
    // （P0 终审 Important A 实证：(A|B)∩(C|D) 规范化为 4 析取 → 判 0）。
    if tt_tag(i) == TT_UNION {
        if tt_is_dnf(tt_a(i)) == 0 { return 0; }
        return tt_is_dnf(tt_b(i));
    }
    return tt_is_dnf_member(i);
}
