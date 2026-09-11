// === ty_shadow.cr ===
// R2 P1：影子对拍——① 桥接层：把 checker 的类型表行号（ti）翻译成 P0 引擎的类型项
// （term，Task 1）；② 判定挂点：把引擎判定与旧判定逐点对账分类
// （Task 2，sh_compare/sh_site_begin/sh_report）。
// R2 P2a Task 3：判定权已移交引擎（`type_equal` = 快路径 + 桥接 + `ty_equiv`），影子挂点
// 仍在 `type_equal` 包装层，**对照物切到 `type_equal_legacy`**（旧结构判等，P5 删）：
// sh_compare 的 `old_ok` 现在喂的是 legacy 结论 → 分类语义 = 「引擎 vs 旧结构判等」，
// 即替换门对拍（差异须归零）。⚠ 影子对 **N 面已失明**（legacy 自身 Task 2 起 N-free）：
// old_stricter/old_looser 在数组长度面上恒 0（同义反复）——N 面验收走行为探针
// （array_len_constraint_ok 判定点 + 异长/同长/嵌套位），不得以对拍归零充当 N 面证据
// （Task 2 评审 Important）。
// Task 3 Step 0（Task 2 评审硬性要求）：unknown 桶拆因——bridge（翻译失败 = 桥接缺口，
// kind=3）vs engine（引擎三态负值，kind=0），后者再按引擎成因位细分（未覆盖面 / 预算耗尽）；
// Task 3 扩面：站点直方图（站点覆盖面实证——环缓冲只装得下「有差异/未知」的条目）。
// 语义映射 = 计划 Task 1 表；命名/泛型/未知 kind → AK_NAMED（引擎不展开 → 判定
// UNKNOWN，这正是 P1 要暴露的「未覆盖面」，与「收紧面」分开统计）。
//
// ⚠️ **`AK_*` 与 `TI_*` 下标不 1:1（Task 1 评审 M4）——必须按语义分派，禁止数值直传**：
//   checker 表前 8 行 = TI_INT=0 TI_DEX=1 TI_BOOL=2 TI_STR=3 TI_UNIT=4 TI_NEVER=5
//                     TI_CHAR=6 TI_DYN=7
//   引擎原子类     = AK_INT=0 AK_DEX=1 AK_STRING=2 AK_BOOL=3 AK_UNIT=4 AK_NEVER=5
//                     AK_CHAR=6 AK_DYN=7
// 即**下标 2/3 互换**（AK_STRING=2 而 TI_STR=3；AK_BOOL=3 而 TI_BOOL=2）。照数值直传
// 会把 bool↔string 静默错标，且两侧同错自洽 → 差异清单全成假信号。故本层用两张显式
// 分支表按语义逐项分派（sh_native_ak / sh_base_ak）；守门用例 = bridge.str_ak /
// bridge.bool_ak（type_selftest.cr）。
// **R2 P2b Task 2：分派单源化**——同一映射此前有两份实现（本层 + 注册表 iface_registry.cr 的
// iface_by_ty_code/iface_kind_of），不合一 = P2b 亲手制造「同一映射两份」（本批要治的病）。
// 现本层两个入口**委托** `iface_by_ty_code`（唯一实现）；改动前的实现作为**字面拷贝**保留为
// `sh_base_ak_legacy`/`sh_native_ak_legacy`（对照物，供 type_selftest.cr **全表对拍**；P5 删——
// 登记入 TODO #24 的 P5 继承项）。影子证据链可比性依赖调用点签名不变（两入口签名原样）。
// M1（Task 1 评审）：native 分派读**类型表本体**（kind == TYP_BASE 且 data == TY_* 码），
// 不再依赖「init_types 行号序恰与 TI_* 码序一致」这一隐式等价（当前真、不保证）。
//
// 影子只**观察**：本层只读 checker 侧（g_types / g_gen_apply_data，见 sh_term_of_ti 的
// 递归翻译）与引擎构造/判定 API，不写任何 checker 判定状态、不改判定结果、不写产物。
// 引擎预算/memo 在每次影子判定前后各 ty_budget_reset → 影子运行不污染后续。
//
// ⚠ **R2 P2a Task 3 起「关态连读都不发生」不再成立（评审 Critical 修复时更正）**：
// 判定路径已改经引擎 → `type_equal_engine` **无条件**调用 `sh_term_of_ti`（Task 3 前仅
// `--type-shadow` 下才译项）⇒ 本层的桥接缓存与 `g_shadow_hits/entries` 在**影子关**时也读写。
// 因此：① 桥接缓存**必须随类型表重置失效**（`sh_map_reset`，经 `init_types()` 调用——
// 否则长驻进程复用行号命中陈旧 ti→term = 两个不同类型被判等，见该函数注记）；
// ② 本层「只观察」的准确含义是「不写 checker 判定状态、不改判定结果、不写产物」，
// **不是**「零写入」；③ 仅剩的影子专属读数 = `g_shadow_on` 早退的
// `sh_compare`/`sh_site_begin`/`sh_report`/`sh_dump_write`。
// 关/开两态基线产物逐字节不变（判据实测见 r2p2-task-3-report §8.1）与上述无冲突。
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

// ─── 原生清单 → AK_*（**按语义逐项对应，不得按下标直通**；下标互换事实见文件头注）───
// 计划注释「AK_* 与 TI_* 前 7 项 1:1」与 spec §11 实测**不一致**：照抄骨架的
// `tt_atom(ti, ti, -1)` 会把 bool↔string 静默错标（两侧同错且自洽 → 差异清单全假信号）。
// M1（Task 1 评审）：**读表本体**判定，不按行号猜。判据 = 该行 kind 恰为 TYP_BASE 且
// data（TY_* 码）有语义对应 → 该行的类型身份即此原生类。行号序与 TY_*/TI_* 码序的
// 「巧合一致」不再是正确性前提（表布局一变即静默错标的隐式依赖已消除）。
// 注：TYP_DYN 行（TI_DYN=7）kind ≠ TYP_BASE → 不在此路，走 sh_term_of_ti 的 TYP_DYN 分支；
// TY_DEX_S 占位行（TI_DEX_S=8）经 sh_base_ak 归 AK_DEX（同值域不同表示）
// ——旧实现按行号白名单把它留给通用路径，两条路产出的项完全一致（仅缓存占用差异）。
fn sh_native_ak(ti: int) -> int {
    if ti < 0 { return -1; }
    // **原门保留**（P2b Task 2 的关键点）：本快路径只认「类型表本体 = TYP_BASE」的行；
    // TYP_DYN 行与全部结构/命名行一律 -1（TI_DYN 走 sh_term_of_ti 的 TYP_DYN 分支，见文件头注）。
    // ⚠ **不得**把本函数直接换成 iface_kind_of：后者对 TYP_DYN 行回 AK_DYN、对结构行回
    // AK_SEQUENCE/…（= 注册表的分派面），与本层的「原生快路径」契约不同——两函数只用
    // 同一个 TY_* 逐项分派表（iface_by_ty_code），门各自保留。
    if get_type_kind(ti) != TYP_BASE { return -1; }
    return iface_by_ty_code(get_type_data(ti));
}

// TYP_BASE 的 data（TY_*）→ AK_*：同款语义对应（TY 序与 TI 序一致，故与 AK 下标同样
// 不可混用）。-1 = 无对应（调用方回退 AK_NAMED）。
// R2 P2b Task 2：实现已**单源化**到 iface_registry.cr 的 `iface_by_ty_code`（唯一实现；
// 逐项语义分派，含 TY_DEX_S→AK_DEX / TY_GENERIC_PARAM→AK_NAMED 两条已裁决灰格）。
fn sh_base_ak(ty: int) -> int {
    return iface_by_ty_code(ty);
}

// ─── 对照物（R2 P2b Task 2：改动前实现的**字面拷贝**；仅 type_selftest.cr 全表对拍用，P5 删）───
// 用途 = `iface.by_ty_code_all_codes` / `iface.native_ak_all_rows`（逐 TY 码 × 逐 ti 行，非抽样）
// 的旧版对照——**生产路径不调用**（影子/判定链路只经上面的委托版）。P5 删（TODO #24 继承项）。
fn sh_native_ak_legacy(ti: int) -> int {
    if ti < 0 { return -1; }
    if get_type_kind(ti) != TYP_BASE { return -1; }
    return sh_base_ak_legacy(get_type_data(ti));
}

// TY_DEX_S（dex 定点形式）的计划表未列项：其值域仍是 dex（缩放整数表示），故归 AK_DEX
// （引擎无「同值域不同表示」的区分——表示层差异不进类型身份）。
fn sh_base_ak_legacy(ty: int) -> int {
    if ty == TY_INT { return AK_INT; }
    if ty == TY_DEX { return AK_DEX; }
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
// **重置 = 随类型表作废**（R2 P2a Task 3 评审 Critical 修复；与 named_dedup_reset 同式）：
// 键 = ti 本体，而 `init_types()` 会把类型表清空重建（行号空间复用）→ 陈旧 ti→term 若不清，
// 长驻进程（corelsp 每请求 `reset_frontend_state → check_all → init_types`）里**命中即返回**
// 上一请求的类型项 ⇒ 两个不同类型被判等（静默漏报）。评审实证：同 URI 两次 didOpen 只把
// 数组元素型 int→bool，第二次 diagnostics=0（应 1 条 Assignment type mismatch）。
// cap = 0 → 下次 sh_map_find 惰性重建（空槽全 -1）；entries/hits 归零（否则装填因子守卫
// 按陈旧计数提前扩容，且 hits 跨请求累积失去诊断意义）。
fn sh_map_reset() {
    g_shadow_map_cap = 0;
    g_shadow_entries = 0;
    g_shadow_hits = 0;
}

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

// ═══════════════ R2 P1 Task 2：影子判定挂点 + 分类计数 + 摘要/转储 ═══════════════
// 站点 id ↔ 语义（checker.cr **10 个外部决策点**（#29 前为 8），id 按行号升序赋值；挂点 = 调用前
// sh_site_begin(id)，见 checker.cr 对应行的行内注记）：
//   1 = checker.cr:728（计划期 :711）hotpatch 返回类型一致（collect_decls，rt_ti vs first_rt_ti）
//   2 = checker.cr:965（计划期 :947）unify_types 泛型实参已绑定路径（g_gen_map 命中 → 实参 vs 具体型）
//   3 = checker.cr:978（计划期 :959）unify_types 泛型应用基型比较（TYP_GENERIC_APPLY 头部）
//   4 = checker.cr:993（计划期 :973）unify_types 兜底结构等价（非泛型 / 未匹配路径）
//   5 = checker.cr:1233（计划期 :1212）函数体返回类型（check_func）
//   6 = checker.cr:1427（计划期 :1405）赋值兼容（infer_expr 的 EXPR_BINARY + OP_ASSIGN；**当前 parser 已无生产点 = 遗留路径，无样本**）
//   7 = checker.cr:1819（计划期 :1796）if 分支类型合并（infer_expr 的 EXPR_IF）
//   8 = checker.cr:2152（计划期 :2127）赋值兼容（infer_expr 的 EXPR_ASSIGN 节点）
//   9 = checker.cr EXPR_STRUCT（TODO #29 ②；行号随 #29 落位漂移，按分支名锚定）struct 字面量字段类型 vs 声明
//  10 = checker.cr EXPR_ARRAY（TODO #29 ③）数组字面量元素同质性（首元素类型 vs 后续元素）
// 行号双列：落地后（Task 2 增 16 行）+ 计划期（与 plan/brief 对读用），两列同源同点；9/10 为
// #29 增站点（+2 → 全表 10 个外部决策点），行号不再回填（锚点 = 分支名）。
// **实读勘误**（计划骨架的站位标签）：骨架写「3 match 模式 / 8 索引」——实读不符：
// match 模式路径不经 type_equal（8 个外部点无一是 match_*），:2127 落在 EXPR_ASSIGN 分支
// 而非索引分支。上表为实读结论。

SHADOW_RING_CAP : int = 256;

fn sh_count_agree() -> int { return g_shadow_agree; }
fn sh_count_old_stricter() -> int { return g_shadow_old_stricter; }
fn sh_count_old_looser() -> int { return g_shadow_old_looser; }
fn sh_count_unknown() -> int { return g_shadow_unknown; }

// 站点标注（在 10 个外部决策点调用 type_equal 前紧邻落；#29 增站点 9/10）。**各站点无条件调用本函数**
// （挂点在决策点上，不在 type_equal 包装内——包装只挡 sh_compare）→ 关态若不守卫，每次
// 判定都多一次调用 + 一次性 64B alloc（直方图缓冲）+ 计数 RMW。故首行按 g_shadow_on 早退
// （M3，Task 3 评审实证：原注释「影子关时 wrapper 不调本函数」**不成立**）；早退后关态
// 残留开销 = 一次全局读 + 返回，与 type_equal 包装同量级。
// Task 3 扩面：顺带累计站点直方图（每个决策点「跑到过几次」——0 差异语料下这是站点
// 覆盖面的唯一实证；site 出界即忽略，不越界写）。
fn sh_site_begin(site: int) {
    if g_shadow_on == 0 { return; }
    g_shadow_site = site;
    if site < 1 || site > 10 { return; }
    if g_shadow_site_cap <= 0 {
        g_shadow_site_counts = alloc(10 * 8);
        g_shadow_site_cap = 10;
    }
    off : ., mut = (site - 1) * 8;
    w64(g_shadow_site_counts, off, r64(g_shadow_site_counts, off) + 1);
}

// 差异/未知环形缓冲（**前 256 条**；满则只计数不覆盖——P1 要的是「首批样本」而非滚动窗口）。
// kind：0 = unknown_engine（引擎三态负值：预算耗尽 / 未覆盖面）/ 1 = old_stricter（旧拒新受）
// / 2 = old_looser（旧受新拒 = 收紧面）/ 3 = unknown_bridge（任一侧翻译失败 = 桥接缺口）；
// 比骨架的 0/1 二值多存方向，便于 Task 3 归档。0 与 3 的拆分是 Task 3 Step 0（Task 2 评审
// 硬性要求：混记则归因不可恢复）；engine 桶的进一步归因走摘要（ring 只有 256 条）。
fn sh_record(kind: int, t1: int, t2: int, old_ok: int) {
    if g_shadow_ring_cap <= 0 {
        g_shadow_ring = alloc(SHADOW_RING_CAP * 40);
        g_shadow_ring_cap = SHADOW_RING_CAP;
    }
    if g_shadow_ring_count >= SHADOW_RING_CAP { return; }
    off : ., mut = g_shadow_ring_count * 40;
    w64(g_shadow_ring, off, g_shadow_site);
    w64(g_shadow_ring, off + 8, t1);
    w64(g_shadow_ring, off + 16, t2);
    w64(g_shadow_ring, off + 24, old_ok);
    w64(g_shadow_ring, off + 32, kind);
    g_shadow_ring_count = g_shadow_ring_count + 1;
}

// 影子判定：翻译两侧 → 引擎三态 → 与旧判定（old_ok，0/1）分类对账。
// **只观察**：不返回值、不写 checker 状态；预算/memo 前后各重置（影子运行不污染后续——
// 引擎 memo 跨查询命中会让结果依赖预算历史，P0 终审 Critical 3 实证）。
fn sh_compare(t1: int, t2: int, old_ok: int) {
    g_shadow_total = g_shadow_total + 1;
    a := sh_term_of_ti(t1);
    b := sh_term_of_ti(t2);
    // 因①：任一侧翻译失败（桥接缺口，kind=3）——与因②分开记，否则 Task 3 归因不可恢复
    if a < 0 || b < 0 {
        g_shadow_unknown = g_shadow_unknown + 1;
        g_shadow_unknown_bridge = g_shadow_unknown_bridge + 1;
        sh_record(3, t1, t2, old_ok);
        return;
    }
    ty_budget_reset(200000);
    e := ty_equiv(a, b);
    // 成因位必须在**第二次 reset 之前**读（ty_budget_reset 会清 g_ty_exhausted/g_ty_uncovered）
    unc := ty_uncovered();
    exh := ty_exhausted();
    ty_budget_reset(200000);                 // 影子运行不污染后续
    // 三态：任何负值都是「未判定」（-1 预算耗尽 / 未覆盖面）——不得降级为 0/1
    if e < 0 {
        // 因②：引擎三态负值（kind=0）；摘要再按引擎自报成因位细分（uncovered 优先——它是
        // 「未覆盖面」的显式登记，与「预算不够」是两类完全不同的后续动作）
        g_shadow_unknown = g_shadow_unknown + 1;
        g_shadow_unknown_engine = g_shadow_unknown_engine + 1;
        if unc != 0 { g_shadow_unknown_uncovered = g_shadow_unknown_uncovered + 1; }
        if unc == 0 && exh != 0 { g_shadow_unknown_budget = g_shadow_unknown_budget + 1; }
        sh_record(0, t1, t2, old_ok);
        return;
    }
    // 注意语义：旧 true ⇔ 引擎 1
    if e == old_ok { g_shadow_agree = g_shadow_agree + 1; return; }
    if old_ok == 0 && e == 1 { g_shadow_old_stricter = g_shadow_old_stricter + 1; sh_record(1, t1, t2, old_ok); return; }
    g_shadow_old_looser = g_shadow_old_looser + 1;   // 旧受新拒 = 收紧面
    sh_record(2, t1, t2, old_ok);
}

fn sh_site_name(s: int) -> string {
    if s == 1 { return "hotpatch-ret"; }
    if s == 2 { return "generic-arg"; }
    if s == 3 { return "generic-apply-base"; }
    if s == 4 { return "unify-fallback"; }
    if s == 5 { return "fn-body-ret"; }
    if s == 6 { return "assign-binary"; }
    if s == 7 { return "if-branch"; }
    if s == 8 { return "assign-node"; }
    if s == 9 { return "struct-field-type"; }
    if s == 10 { return "array-elem-type"; }
    return "?";
}

fn sh_kind_name(k: int) -> string {
    if k == 0 { return "unknown_engine"; }
    if k == 1 { return "old_stricter"; }
    if k == 2 { return "old_looser"; }
    if k == 3 { return "unknown_bridge"; }
    return "?";
}

// 摘要行（仅影子开时打印；关 = 零输出 → 两态 stdout 也零变化）。
// 前 5 组 key=value = Task 2 契约（**前缀不变**，既有 grep 读取方不受影响；Task 3 评审
// M2 逐字比对 `28fed09` 的 sh_report：Task 2 原文正是 5 组）；后 4 组 = Task 3 Step 0
// 拆因（unknown 两因 + engine 桶成因位），因 ring 只有 256 条、摘要才是无损计数通道。
// R2 P2a Task 3 追加 2 组 = **判定替换的回落计数**（checker.cr 的 type_equal；与影子
// unknown 桶不同：那是影子自己的引擎判定，这两组数**判定路径**的回落次数）。
// 注意：计数器只在影子开时**打印**，但累加与开关无关——type_equal_engine 里的自增在
// `if g_shadow_on != 0` 之前且不以它为条件（码级），故关态计数与开态同值、关态 stdout
// 逐字节不变（两态零变化判据）。**可复核的独立交叉证据**：影子侧的 unknown_engine（影子
// 自查的引擎负值次数）与 replace_unknown（判定路径回落次数）在 71 个语料文件上**逐文件
// 相等**（同一批调用、两个独立计数器）——见 Task 3 报告 §unknown 处置。
fn sh_report() -> int {
    if g_shadow_on == 0 { return 0; }
    print("[type-shadow] decisions=");
    print(int_str(g_shadow_total));
    print(" agree=");
    print(int_str(g_shadow_agree));
    print(" old_stricter=");
    print(int_str(g_shadow_old_stricter));
    print(" old_looser=");
    print(int_str(g_shadow_old_looser));
    print(" unknown=");
    print(int_str(g_shadow_unknown));
    print(" unknown_bridge=");
    print(int_str(g_shadow_unknown_bridge));
    print(" unknown_engine=");
    print(int_str(g_shadow_unknown_engine));
    print(" unknown_engine_uncovered=");
    print(int_str(g_shadow_unknown_uncovered));
    print(" unknown_engine_budget=");
    print(int_str(g_shadow_unknown_budget));
    print(" replace_bridge=");
    print(int_str(g_replace_bridge));
    print(" replace_unknown=");
    println(int_str(g_replace_unknown));
    // 站点直方图（Task 3 扩面）：与主行同开同关；恒有 sum(site_i) == decisions（每个
    // sh_compare 之前必有一次 sh_site_begin）——两行互为校验。
    print("[type-shadow-sites]");
    si : ., mut = 0;
    loop {
        if si >= 10 { break; }
        print(" ");
        print(sh_site_name(si + 1));
        print("=");
        n : ., mut = 0;
        if g_shadow_site_cap > 0 { n = r64(g_shadow_site_counts, si * 8); }
        print(int_str(n));
        si = si + 1;
    }
    println("");
    return 0;
}

// 差异条目转储（每行：site名<TAB>site<TAB>t1<TAB>t2<TAB>old_ok<TAB>kind名）。
// -1 = 未启用（影子关 / 路径空 / 无条目 / 写失败）。
fn sh_dump_write(path: string) -> int {
    if g_shadow_on == 0 { return -1; }
    if str_len(path) == 0 { return -1; }
    if g_shadow_ring_count <= 0 { return -1; }
    body : ., mut = "# R2 P1 type-shadow diff dump (first 256 entries; overflow = counts only)\n# site\tsite_id\tt1\tt2\told_ok\tkind\tkind_id\n";
    i : ., mut = 0;
    loop {
        if i >= g_shadow_ring_count { break; }
        off : ., mut = i * 40;
        sit := r64(g_shadow_ring, off);
        kd := r64(g_shadow_ring, off + 32);
        body = body + sh_site_name(sit) + "\t" + int_str(sit) + "\t"
                    + int_str(r64(g_shadow_ring, off + 8)) + "\t"
                    + int_str(r64(g_shadow_ring, off + 16)) + "\t"
                    + int_str(r64(g_shadow_ring, off + 24)) + "\t"
                    + sh_kind_name(kd) + "\t" + int_str(kd) + "\n";
        i = i + 1;
    }
    w := write_file(path, body);
    if w < 0 { return -1; }
    print("type-shadow dump: ");
    print(int_str(g_shadow_ring_count));
    print(" entries -> ");
    println(path);
    return 0;
}
