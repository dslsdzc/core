// === ty_shadow.cr ===
// R2 P1：影子对拍桥接层——把 checker 的类型表行号（ti）翻译成 P0 引擎的类型项（term）。
// 语义映射 = 计划 Task 1 表；命名/泛型/未知 kind → AK_NAMED（引擎不展开 → 判定
// UNKNOWN，这正是 P1 要暴露的「未覆盖面」，与「收紧面」分开统计）。
// 本层只**读** checker 侧（g_types / g_gen_apply_data）与引擎侧构造 API，不写任何判定
// 状态、无挂点（挂点 = Task 2 的 type_equal 包装）→ P0 基线产物逐字节不变。
//
// 缓存 g_shadow_map（16B/条 {ti, term}）：开放寻址线性探测（与引擎 g_tt_index 同式），
// 键 = ti 本体（term 不入键）。计划骨架的两处缺口在本实现补齐（偏差逐条见 Task 1 报告）：
//   ① 骨架无扩容、无装填因子守卫 → 表满（或 ti 探测链满）时 sh_map_find 的探测
//      **永不落空 = 死循环**。P1 Task 3 的语料是编译器自身（ti 数可上数千 > 初始容量
//      1024），P0 引擎同族缺陷（memo 装填因子）已有实证，故此处按同款守卫落：
//      探测前 (g_shadow_entries + 1) * 2 >= cap → 扩容重建 + 重放（sh_map_rehash）。
//      计数即 g_shadow_entries（只增不减，恒等于占用槽数——无需第五个全局）。
//   ② 骨架「先探槽位 → 递归翻译子项 → 回写该槽位」：递归中的插入可触发扩容（表指针与
//      容量变更）→ 回写的槽位索引失效 = 静默错写/丢条目（P0「扩容后去重静默失效」同族）。
//      本实现：翻译完成后**重探**再写；重探必落空槽（ti 图无环——子项 ti 恒小于父项，
//      父项此刻未入表），命中分支仅为防未来改动的兜底。

SHADOW_MAP_INIT_CAP : int = 1024;

// ─── 原生清单 → AK_*（**按语义逐项对应，不得按下标直通**）───
// checker 表前 8 行由 init_types 按 TI_* 常量序分配，而引擎 AK_* 的**编号序与之不同**：
//   checker: TI_INT=0 TI_DEX=1 TI_BOOL=2 TI_STR=3 TI_UNIT=4 TI_NEVER=5 TI_CHAR=6 TI_DYN=7
//   引擎   : AK_INT=0 AK_DEX=1 AK_STRING=2 AK_BOOL=3 AK_UNIT=4 AK_NEVER=5 AK_CHAR=6 AK_DYN=7
// 即下标 2/3 **互换**（AK_STRING=2 而 TI_STR=3；AK_BOOL=3 而 TI_BOOL=2）。计划注释
// 「AK_* 与 TI_* 前 7 项 1:1」与 spec §11 的原生清单实测**不一致**，照抄骨架的
// `tt_atom(ti, ti, -1)` 会把 bool↔string 静默错标（两侧同错且自洽 → 影子差异清单
// 全是假信号）。守门用例 = bridge.str_ak / bridge.bool_ak。
fn sh_native_ak(ti: int) -> int {
    if ti == TI_INT { return AK_INT; }
    if ti == TI_DEX { return AK_DEX; }
    if ti == TI_BOOL { return AK_BOOL; }
    if ti == TI_STR { return AK_STRING; }
    if ti == TI_UNIT { return AK_UNIT; }
    if ti == TI_NEVER { return AK_NEVER; }
    if ti == TI_CHAR { return AK_CHAR; }
    if ti == TI_DYN { return AK_DYN; }
    return -1;
}

// TYP_BASE 的 data（TY_*）→ AK_*：同款语义对应（TY 序与 TI 序一致，故与 AK 下标同样
// 不可混用）。-1 = 无对应（调用方回退 AK_NAMED）。
fn sh_base_ak(ty: int) -> int {
    if ty == TY_INT { return AK_INT; }
    if ty == TY_DEX { return AK_DEX; }
    // TY_DEX_S（dex 定点形式）的计划表未列项：其值域仍是 dex（缩放整数表示），
    // 故归 AK_DEX（引擎无「同值域不同表示」的区分——表示层差异不进类型身份）。
    if ty == TY_DEX_S { return AK_DEX; }
    if ty == TY_BOOL { return AK_BOOL; }
    if ty == TY_STRING { return AK_STRING; }
    if ty == TY_UNIT { return AK_UNIT; }
    if ty == TY_NEVER { return AK_NEVER; }
    if ty == TY_CHAR { return AK_CHAR; }
    if ty == TY_GENERIC_PARAM { return AK_NAMED; }   // 泛型参数哨兵 → 命名类（不展开）
    return -1;
}

// ─── 桥接缓存（ti → term）───
fn sh_map_cap_init() {
    if g_shadow_map_cap <= 0 {
        nc : ., mut = SHADOW_MAP_INIT_CAP;
        nb := alloc(nc * 16);
        i : ., mut = 0;
        loop { if i >= nc { break; } w64(nb, i * 16, -1); i = i + 1; }
        g_shadow_map = nb;
        g_shadow_map_cap = nc;
    }
}

// 无守卫探测（**只可在扩容守卫之后调用**；sh_map_rehash 重放时借道这里）：
// 命中返回槽位，未命中返回空槽位（不插入）。
// 形态 = tt_term 的探测循环（ret + break + 尾 return），**不**用「循环体内裸 return 收尾」
// （如 ty_memo_slot_no_grow）：后者是自托管 checker 的已知误报面——函数体以无 break 的
// loop 收尾时它按「落空 = 返回 unit」判 → TF01 "Function return type mismatch"（实跑
// `check src/compiler/main.cr` 对 lits_copy / ty_memo_slot_no_grow 各报一条）。本函数
// 是 typed 探测，尾 return 语义等价且不给 P1 Task 3 的语料日志添新误报行。
fn sh_map_find_nogrow(ti: int) -> int {
    cap := g_shadow_map_cap;
    // 非负槽位（负数取模 = 负下标 → 探针越界；与引擎 tt_mod 同式同因——直接复用引擎
    // 该函数，避免本仓库第三份取模式各自漂移）
    p : ., mut = tt_mod(ti, cap);
    ret : ., mut = -1;
    loop {
        k := r64(g_shadow_map, p * 16);
        if k < 0 { ret = p; break; }
        if k == ti { ret = p; break; }
        p = p + 1; if p >= cap { p = 0; }
    }
    return ret;
}

fn sh_map_find(ti: int) -> int {
    sh_map_cap_init();
    // 装填因子守卫（**必须在探测前**）：表满且键不存在时开放寻址永不退出（死循环）
    if (g_shadow_entries + 1) * 2 >= g_shadow_map_cap { sh_map_rehash(); }
    return sh_map_find_nogrow(ti);
}

// 扩容 = 重建 + **重放既有条目**（引擎 grow_tt_index/tt_reindex 同式）；计数随重放重算
// （装填因子守卫读的就是它，不得沿用旧值）。
fn sh_map_rehash() {
    old := g_shadow_map;
    old_cap := g_shadow_map_cap;
    nc : ., mut = old_cap * 2;
    if nc < SHADOW_MAP_INIT_CAP { nc = SHADOW_MAP_INIT_CAP; }
    nb := alloc(nc * 16);
    i : ., mut = 0;
    loop { if i >= nc { break; } w64(nb, i * 16, -1); i = i + 1; }
    g_shadow_map = nb;
    g_shadow_map_cap = nc;
    g_shadow_entries = 0;
    j : ., mut = 0;
    loop {
        if j >= old_cap { break; }
        k := r64(old, j * 16);
        if k >= 0 {
            s := sh_map_find_nogrow(k);
            w64(g_shadow_map, s * 16, k);
            w64(g_shadow_map, s * 16 + 8, r64(old, j * 16 + 8));
            g_shadow_entries = g_shadow_entries + 1;
        }
        j = j + 1;
    }
}

// TYP_TUPLE → AK_PRODUCT（参数链 = 逐字段项，顺序 = 声明顺序）。
// **实读布局**（checker.cr:118-131 type_equal 的 TUPLE 分支 + :2041-2050 字段访问 t.N）：
//   data  = 字段数；extra = 字段 ti 在 g_gen_apply_data 的起始下标（8B/元素）——
//   第 i 个字段 ti = r64(g_gen_apply_data, (extra + i) * 8)。
// 计划文中的「字段在 g_tuple_*」在本仓库**不存在**（全仓 grep 零命中），以实读为准。
// CONS 链**逆序构造**（i 自末尾向前 cons）：DAG 项不可变，正向追加需改写已建项——
// 不可行；逆序构造的结果顺序仍 = 声明顺序。
fn sh_tuple_to_product(ti: int) -> int {
    cnt := get_type_data(ti);
    start := get_type_extra(ti);
    tail : ., mut = tt_nil();
    i : ., mut = cnt - 1;
    loop {
        if i < 0 { break; }
        et := sh_term_of_ti(r64(g_gen_apply_data, (start + i) * 8));
        if et < 0 { return -1; }        // 任一字段无法翻译 → 整项无法翻译（不缓存）
        tail = tt_cons(et, tail);
        i = i - 1;
    }
    return tt_atom(AK_PRODUCT, -1, tail);
}

// ti → 类型项（带 per-ti 缓存；-1 = 无法翻译）
fn sh_term_of_ti(ti: int) -> int {
    if ti < 0 { return -1; }
    // 原生快路径：无表读、不占缓存条目
    nak := sh_native_ak(ti);
    if nak >= 0 { return tt_atom(nak, ti, -1); }
    slot := sh_map_find(ti);
    if r64(g_shadow_map, slot * 16) == ti {
        g_shadow_hits = g_shadow_hits + 1;
        return r64(g_shadow_map, slot * 16 + 8);
    }
    // 未命中：按 kind 翻译（递归子项）
    term : ., mut = -1;
    k1 := get_type_kind(ti);
    d1 := get_type_data(ti);
    if k1 < 0 { return -1; }            // 行号越界（ti >= g_type_count）= 无法翻译
    if k1 == TYP_BASE {
        bak := sh_base_ak(d1);
        if bak >= 0 { term = tt_atom(bak, ti, -1); }
    } else if k1 == TYP_DYN {
        // data = 类型集位图（0 = 单一已知类型）——计划表定 TYP_DYN → AK_DYN。位图是
        // dyn 的**收窄**，AK_DYN 在引擎侧 = ⊤（与一切相容）→ 该项过宽（可致 Task 3
        // 里同源 dyn 集被判「等价」的假信号）；P1 不改引擎，先按表落 + 报告注记。
        term = tt_atom(AK_DYN, ti, -1);
    } else if k1 == TYP_ARRAY || k1 == TYP_SLICE {
        // TYP_ARRAY 的 extra = N（长度），**不入身份**（R1 裁决）→ 参数链只含元素项
        el := sh_term_of_ti(d1);
        if el >= 0 { term = tt_atom(AK_SEQUENCE, -1, tt_cons(el, tt_nil())); }
    } else if k1 == TYP_PTR {
        in1 := sh_term_of_ti(d1);
        if in1 >= 0 { term = tt_atom(AK_PTR, -1, tt_cons(in1, tt_nil())); }
    } else if k1 == TYP_REF {
        // extra = mut 标记：同 PTR，不入参数链（引擎无只读/可写区分 = P3 条目化面）
        in2 := sh_term_of_ti(d1);
        if in2 >= 0 { term = tt_atom(AK_REF, -1, tt_cons(in2, tt_nil())); }
    } else if k1 == TYP_TUPLE {
        term = sh_tuple_to_product(ti);
    } else if k1 == TYP_NAMED || k1 == TYP_GENERIC_PARAM || k1 == TYP_GENERIC_APPLY {
        term = tt_atom(AK_NAMED, ti, -1);   // 不展开 → UNKNOWN（P1 预期）
    } else {
        term = tt_atom(AK_NAMED, ti, -1);   // 未知 kind 保守归入命名类
    }
    if term < 0 { return -1; }
    // 写回前**重探**（递归翻译期间可能已扩容——见文件头注记②）
    slot2 := sh_map_find(ti);
    if r64(g_shadow_map, slot2 * 16) == ti {
        g_shadow_hits = g_shadow_hits + 1;  // 兜底：递归期间同 ti 已入表
        return r64(g_shadow_map, slot2 * 16 + 8);
    }
    w64(g_shadow_map, slot2 * 16, ti);
    w64(g_shadow_map, slot2 * 16 + 8, term);
    g_shadow_entries = g_shadow_entries + 1;
    return term;
}

// ─── 桥接统计（自测断言/影子摘要用）───
fn sh_map_hits() -> int { return g_shadow_hits; }
fn sh_map_entries() -> int { return g_shadow_entries; }
