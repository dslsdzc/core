// === ty_shadow.cr ===
// R2 P1：影子对拍——① 桥接层：把 checker 的类型表行号（ti）翻译成 P0 引擎的类型项
// （term，Task 1）；② 判定挂点：把引擎判定与旧判定逐点对账分类
// （Task 2，sh_compare/sh_site_begin/sh_report）。
// R2 P3 Task 0：**引擎展开层**（文件末段）——named/struct/enum/generic-apply → 结构项，
// 只服务「满足判定」与「穷尽性域/模式项」两条路径；等价判定保持原子名义（边界与理由见
// 该段头注——裁错即判定全面漂移）。
// R2 P3 Task 1：**序列项 / ref mut 标记**（`sh_seq_term` / `sh_ref_mut_marker`，见下方
// 构造点注记）：序列项的 b 槽 = 固定性位（N 或 -1；**不入等价身份**），AK_REF 链 = [mut 标记,
// 元素]（mut 成为判定维度——旧约定「不入链」下引擎把 `&T` 与 `&mut T` 判等价 = 静默放宽，
// legacy 比 extra ⇒ 替换后 mut 面失守；本批关闭）。变型规则（引擎侧表）在 type_engine.cr。
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
// （如 ty_memo_slot_no_grow）：后者曾是自托管 checker 的误报面——函数体以无 break 的 loop
// 收尾时它按「落空 = 返回 unit」判 → TF01 "Function return type mismatch"。**该误报已修**
// （TF01 收口：checker.cr 的 `stmt_cannot_fall_through`/`loop_body_has_break` 落空分析 +
// type_engine.cr 的 `lits_copy` 返回型改 string），此处形态保留仅为 typed 探测的旧写法，
// 不再有「不许这么写」的合规约束（不过改写无益，故不动）。
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
// ─── R2 P3 Task 1：序列项 / ref mut 标记（桥接的两个新构造点）───
// 序列项（TYP_ARRAY 与 TYP_SLICE 的**唯一**构造点）：tt_atom(AK_SEQUENCE, fixed_len, [元素项])。
//   b 槽 = **固定性位**：数组 = N（长度字面量），切片/视图 = -1。
//   ⚠ 引擎比较只看 a（原子类）与 c（参数链）两槽（`lit_implies` 的**双方皆正原子**分支；
//   b 槽是**标注**——AK_NAMED 的 b = 行号即此约定）⇒ **N 不入等价/包含身份**（R1 裁决 +
//   P2a 长度约束不变量的延续）：`[int;3]` 与 `[int;4]` 的项除 b 外逐位相同 ⇒ `ty_equiv == 1`、
//   `ty_sub == 1`，拒绝一律由 checker 的常量档约束承担。固定性位的消费者 = checker.cr
//   `array_len_constraint_ok` 的**方向规则**（视图→固定拒绝）与后续横切形状（P3 Task 2）。
//   -1 = 元素项译不成（调用方回 -1，不缓存）。
fn sh_seq_term(elem_ti: int, fixed_len: int) -> int {
    el := sh_term_of_ti(elem_ti);
    if el < 0 { return -1; }
    return tt_atom(AK_SEQUENCE, fixed_len, tt_cons(el, tt_nil()));
}

// AK_REF 链槽 0 = mut 标记（R2 P3 Task 1 起 mut **成为判定维度**，替代旧约定的「不入链」——
// 旧约定下 `&T` 与 `&mut T` 的项逐位相同 ⇒ 引擎判等价，而 legacy 比 extra(mut) 判不等 ⇒
// 判定替换后 mut 面静默放宽；本标记即该缺口的关闭）。
// 标记项 = tt_atom(AK_UNIT, mut, -1)：**语法令牌**（b 槽 = 标记值，照 AK_NAMED 的 b = 行号
// 同约定），非类型集——引擎侧按**节点同一性**比较（type_engine.cr 的 tt_list_variance_at
// 槽 0 分支；不同标记 = 确定不匹配 ⇒ 0，不回 -1）。
fn sh_ref_mut_marker(mutv: int) -> int {
    return tt_atom(AK_UNIT, mutv, -1);
}

// 名字令牌（P3 Task 1 起：变体身份链的 name **索引入链**升级为**令牌原子上链**）。
// 旧约定（Task 0）= `tt_cons(ei_name(ea), tt_cons(name_ni, tt_nil()))` 直接把 **name 索引**
// 当链元素——索引是**别名**：任何把链元素当术语解释的比较（如按结构/等价比较）会把
// `str_intern` 得到的小整数当**术语下标**读取（`tt_tag(ni)` = 第 ni 个项的 tag）⇒ 名字
// 碰撞即静默判等。本任务实证两类：① 不变槽改用 ty_equiv 比较时
// `unf.enum_variant_identity_scoped` 红（异枚举同名变体被判等）；② 固定性守卫
// （tt_type_elem_same）会读链元素的 class。⇒ 令牌改为**原子节点**
// `tt_atom(AK_UNIT, ni, -1)`（与 mut 标记同式；b = 值），只按**节点同一性**比较，
// 结构比较再也不可能把它当术语解释。语义等价（不同名字 → 不同节点；同名字 → 同节点）。
fn sh_name_token(ni: int) -> int {
    return tt_atom(AK_UNIT, ni, -1);
}

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

// ─── R2 P3 Task 4：null 项（`T? = T ∪ null` 的右支；`None` 类型的项）───
// 规范形态 = tt_atom(AK_NULL, -1, -1)：**行号不入项**（b 槽是标注；此处刻意连标注都空）。
// 理由：`None` 每出现一次就分配一行（TYP_NULL 不做行去重）⇒ 若把行号写进 b 槽，同一类型
// 会有 N 个「不同节点」——虽然引擎比较只看 a/c 两槽（b 是标注）⇒ 语义不受影响，但节点同一
// 性快路径（ty_sub 的 `a == b`、tt_norm 的哈希去重）会失去同项合并，读数与缓存都变差。
// 单点语义 ⇒ 项恒定，构造去重（tt_term 的哈希合表）保证全仓只有**一个** null 节点。
fn sh_null_term() -> int {
    return tt_atom(AK_NULL, -1, -1);
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
        // TYP_ARRAY 的 extra = N（长度），**不入身份**（R1 裁决）→ 参数链只含元素项，
        // N 落 b 槽 = 固定性位（P3 Task 1；构造点单源化到 sh_seq_term）
        fl : ., mut = -1;
        if k1 == TYP_ARRAY { fl = get_type_extra(ti); }
        term = sh_seq_term(d1, fl);
    } else if k1 == TYP_PTR {
        // 同 PTR：元素入链（AK_PTR 槽 0 变型 = 不变，见 type_engine.cr 变型表）；
        // extra（asp 地址空间位）不入链——与 legacy 的 PTR 分支（只比 data）同语义
        in1 := sh_term_of_ti(d1);
        if in1 >= 0 { term = tt_atom(AK_PTR, -1, tt_cons(in1, tt_nil())); }
    } else if k1 == TYP_REF {
        // extra = mut 标记：**入链**（P3 Task 1）——链 = [mut 标记项, 元素项]，标记与元素
        // 各占一槽（槽 0 不变 / 槽 1 只读协变、可写不变，见 type_engine.cr 变型表）
        in2 := sh_term_of_ti(d1);
        if in2 >= 0 { term = tt_atom(AK_REF, -1, tt_cons(sh_ref_mut_marker(get_type_extra(ti)), tt_cons(in2, tt_nil()))); }
    } else if k1 == TYP_OPTIONAL {
        // R2 P3 Task 4：`T?` = `T ∪ null`（spec §5.4）。这是桥接层**唯一**译作非原子项的行
        // （其余行 → 单原子）；依据 = 定义式本身（不是名义展开——T? 无名字可展开）。语义落点：
        // 引擎对 union 的一切判定（包含/等价/不相交/穷尽性）零新规则。
        in3 := sh_term_of_ti(d1);
        if in3 >= 0 { term = tt_union(in3, sh_null_term()); }
    } else if k1 == TYP_NULL {
        // null 单点类型（`None` 值的类型）：规范项 = null 原子（无参数、无 b 槽行号——同一
        // 类型的不同出现点（每处 `None` 各一行）必须译成**同一**项，否则 `ty_sub(null, null)`
        // 会走结构比较而非节点同一/规范化快路径（语义仍对，但多绕一圈且不可读）。
        term = sh_null_term();
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

// ─── R2 P5 Task 2（D19/D21/D22/D23）：DFNode 类型面单槽化 = 唯一分类表 + 拆分器 ───
// 单槽化（α，内存面）：`OFF_DF_TK` = **类型项引用**（类型面唯一真源），
// `OFF_DF_AUX` = **辅码**（原混用槽里的非类型部分：旗标/宽度/计数/不可入项的原始行码）。
// `.ccr` NOD 与 `.cir` 快照**只承载派生码**（`sh_dfn_code_of_slots`）⇒ 盘面与版本位
// 零改动（布局零变化，见 dyn_arr.cr 的四条契约）。
//
// 分类表（Task 0 表 A 的代码化；逐 op 依据 = p5-task0-report §2 的 51 行表 + 后端
// `ti` 消费者机器审计）：
//   · **类型行面**（face 0，tk 语义 = 类型行 ⇒ 建项）：IR_CONST / IR_BINARY / IR_ALLOC /
//     IR_CALL / IR_LOAD / IR_I2F / IR_F2I —— P4 的 {CONST,BINARY} 允许清单 + Task 0
//     对 P4 六排除项的再裁（前五者「调用点显式传 TI_*/类型行变量」⇒ 语义即类型行；
//     IR_LOAD_ENUM_TAG 两调用点传字面量 0 ⇒ 保留「无面」）。
//   · **辅码面**（face 1，tk 语义 = 非类型码 ⇒ 原码进辅码槽）：IR_BOUNDS_CHECK（0/1
//     动态上限旗标，instr.cr:1340 `ti != 0`）/ IR_DEREF / IR_STORE_PTR（访问宽度码
//     8/4/2/1，instr.cr 的 e2_ptr_bounds_check）/ IR_SPAWN（spawn_count；-1 = 动态）/
//     IR_HOTPATCH_ROUTE（F1 修正后的显式 0）。
//   · **无面**（face 2，tk 语义 = 无）：其余全部 op。
// 数值陷阱（P4 §2 实测）：旗标 `1` 数值上 = TI_DEX 行、宽度 `8` = TI_DEX_S 行 ⇒
// 分类**必须逐 op**，按行号猜即凭空给「指针解引用」安 dex 项。
//
// **原子行 vs 复合行**（F2 裁决 = Task 0 候选 (iii)+(ii)）：类型面**只接受项可逆的行**
// （`atom_of(项) == 行号`，当且仅当项是 TT_ATOM 且 b 槽即行号）。指针/引用/数组/切片/
// 可选/null/元组行的项是结构性项（如 AK_PTR 的 b = -1）⇒ **不建项**（D21：非原子 ⇒ -1，
// 不近似），原码按辅码槽**保真**⇒ 派生码逐字节 ≡ 旧混用码（D22-① 在全语料成立，含
// 复合行）。反例（实测）：`tests/suite/ptr_ref_first.cr` 的 IR_BINARY tk=10 = 指针行。
//
// 三态纪律（D23）：类型面 op 的行**越出类型表**或**在域内但译不出项**（桥接缺口）
// ⇒ **建项失败**（`g_tk_face_fail` 置位）⇒ save 侧拒绝落盘（rc=1 + 诊断），绝不静默
// 留空项。`tk < 0` = 「无类型」（IR_LOAD/CALL 的未定型路径）不是行码，不算失败。
fn sh_tk_is_type_face(opcode: int) -> int {
    if opcode == IR_CONST || opcode == IR_BINARY || opcode == IR_ALLOC ||
       opcode == IR_CALL || opcode == IR_LOAD || opcode == IR_I2F || opcode == IR_F2I {
        return 1;
    }
    return 0;
}

// 行三态（D23 判据面）：-1 = 非行码（tk < 0 = 无类型，合法）；0 = **不可译**（越界 /
// 桥接缺口 ⇒ 建项失败）；1 = 可译（原子行 ⇒ 项；复合行 ⇒ 辅码保真）。
fn sh_tk_row_state(tk: int) -> int {
    if tk < 0 { return -1; }
    if tk >= g_type_count { return 0; }
    if sh_term_of_ti(tk) < 0 { return 0; }
    return 1;
}

// D21 契约：`TT_ATOM ∧ b ≥ 0 ⇒ b`（b 槽即该原子的类型行）；其余（union/product/μ/
// 空链/负）⇒ **-1 = 非单一原子**（不得近似、不得回 0）。
fn sh_atom_of_term(term: int) -> int {
    if term < 0 || term >= tt_count() { return -1; }
    if tt_tag(term) != TT_ATOM { return -1; }
    if tt_b(term) < 0 { return -1; }
    return tt_b(term);
}

// 分类（纯函数）：0 = 类型行面（**项可逆**才归此面）/ 1 = 辅码面 / 2 = 无面。
fn sh_tk_face_of_code(opcode: int, tk: int) -> int {
    if sh_tk_is_type_face(opcode) != 0 {
        if sh_tk_row_state(tk) == 1 {
            if sh_atom_of_term(sh_term_of_ti(tk)) == tk { return 0; }
        }
        return 1;   // 复合行 / 越界 / 桥接缺口 / 负值 —— 一律辅码（码保真）
    }
    if opcode == IR_BOUNDS_CHECK || opcode == IR_DEREF || opcode == IR_STORE_PTR ||
       opcode == IR_SPAWN || opcode == IR_HOTPATCH_ROUTE {
        return 1;
    }
    return 2;
}

// 拆分器（**单源**；emit 与 `.cir` 装载侧共用）：(opcode, tk) → (项槽, 辅码槽)。
// 出参经两个全局返回（Core 无多返回值）——**读前必先调用**（函数入口先置默认值，
// 无残留状态）。规则：
//   face 0 ⇒ 项 = `sh_term_of_ti(tk)`（此时构造已证可逆）、辅码 = 0；
//   其余   ⇒ 项 = -1、辅码 = tk（**码保真**：旗标/宽度/复合行/无面 op 的非零码
//            一律原样承载，派生码因此逐字节 ≡ 旧混用码）。
// 该调用**不进**影子对账计数（hits/entries 只统计判定站点；本函数是载体面派生，
// 冷/暖两态与判定历史无关）——故 sh_term_of_ti 的命中计数先存后复原。
// entries（装填因子输入 = 真实占用槽数）**不复原**——复原即欺骗扩容守卫。
fn sh_tk_split(opcode: int, tk: int) {
    sh_tk_split_impl(opcode, tk, 1);
}

// 装载侧变体（`.cir` 快照重派生）：**不置 D23 失败位**。理由 = 判据面不同：
//   · emit 路径（count_fail=1）：类型面行的可译性是**真不变量**——行刚由前端/IR 生成
//     产出，越界/译不出 = 编译器 bug（或桥接缺口）⇒ 拒绝落盘。
//   · 装载路径（count_fail=0）：盘上的码是**不透明历史值**，而暖进程的类型表可能**更小**
//     ——缓存命中跳过该函数的 IR 生成，而 ir_gen 自身会 `alloc_type` 新行
//     （ir_gen.cr:1277/:1283/:2434/:2491/:2792 的 addr/ref/cast/数组行）⇒ 冷路径存在的行
//     在暖进程可能不存在。这是**预存的缓存面局限**（登记：报告 §5-④；β 盘面项索引
//     承接面 = P6），不是本进程的编译器 bug。代码由辅码槽保真 ⇒ 派生码仍逐字节正确，
//     只有该项在本进程不可重建（term = -1）。缓存命中**绝不**因此让编译失败。
fn sh_tk_split_load(opcode: int, tk: int) {
    sh_tk_split_impl(opcode, tk, 0);
}

fn sh_tk_split_impl(opcode: int, tk: int, count_fail: int) {
    // hits 复原**包住整个函数**（不止 sh_term_of_ti 那一处）：分类查询自己也走
    // sh_term_of_ti（row_state 的可译判定 + 原子性检查），那同样是载体面派生。
    hits_before := g_shadow_hits;
    fac := sh_tk_face_of_code(opcode, tk);
    g_sh_slot_term = -1;
    g_sh_slot_aux = 0;
    if fac == 0 {
        g_sh_slot_term = sh_term_of_ti(tk);
    } else {
        // 码保真：旗标/宽度/计数/复合行码/无面 op 的非零码一律原样承载（含负码——
        // IR_SPAWN 的 tk = -1 = 「动态 spawn 计数」，是合法辅码，**不得**钳成 0）。
        // 辅码哨兵：0 = 无；非零（含负）= 该码本身。
        g_sh_slot_aux = tk;
        // D23：类型面 op 的行**不可译**（越界/桥接缺口）⇒ 建项失败——复合行是
        // 域内可译 ⇒ 正常路径，不置位。
        if count_fail != 0 {
            if sh_tk_is_type_face(opcode) != 0 && sh_tk_row_state(tk) == 0 { g_tk_face_fail = g_tk_face_fail + 1; }
        }
    }
    g_shadow_hits = hits_before;
}

// 槽 → 派生码（**唯一**派生点；dataflow.cr 的 lower_to_ccr / ir_gen.cr 的 emit /
// cir_cache.cr 的装载侧共用）：辅码 ≠ 0 ⇒ 辅码；无项 ⇒ 0；否则 `atom_of(项)`
// （不可逆 ⇒ -1：显式、响亮，绝不近似成 0/1）。
fn sh_dfn_code_of_slots(tk_term: int, tk_aux: int) -> int {
    if tk_aux != 0 { return tk_aux; }
    if tk_term < 0 { return 0; }
    return sh_atom_of_term(tk_term);
}

// 兼容入口（自测/诊断面）：单槽化前 `sh_tk_term_of_code(opcode, tk)` 的语义 =
// 「类型面派生出的项；其余 -1」——即拆分器的**项槽**输出，但**纯查询**：不写槽出参、
// 不计 D23 失败位（诊断调用不得污染落盘闸；有副作用的生产路径一律走 sh_tk_split）。
// 与 split 共用同一个分类函数 sh_tk_face_of_code ⇒ 规则单源，无第二份判定。
fn sh_tk_term_of_code(opcode: int, tk: int) -> int {
    // hits 复原包住分类查询（它自己也走 sh_term_of_ti——同 split 的计数纪律）。
    hits_before := g_shadow_hits;
    t : ., mut = -1;
    if sh_tk_face_of_code(opcode, tk) == 0 { t = sh_term_of_ti(tk); }
    g_shadow_hits = hits_before;
    return t;
}

// ─── 桥接统计（自测断言/影子摘要用）───
fn sh_map_hits() -> int { return g_shadow_hits; }
fn sh_map_entries() -> int { return g_shadow_entries; }

// ─── R2 P3 Task 5：类型项文本化（诊断反例用）───
// 用途 = `tt_witness` 的反例项 → 人可读文本（P3 计划 Task 5 Step 3「诊断含反例值」）。
// **只读、零 str_intern**：`.ccr` 的 STR 段 = 编译期 g_strs 全量（P2b 附录 A.3-②）⇒ 渲染
// 不得驻留新串（诊断文本一律用 dyn 串拼接；istr_get 读既有串）。
// 形态 = 结构化 JSON 风格（`int`/`string`/`sequence<int>`/`{int, string}`/`A ∪ B`/`¬A`…）；
// 未识别 tag → "?"（**不谎报**形态）。深度上限 = 避免病态项上的栈爆（超限 → "…"）。
fn tt_display_at(t: int, depth: int) -> string {
    if t < 0 { return "?"; }
    if depth > 24 { return "…"; }
    if t >= tt_count() { return "?"; }
    tg := tt_tag(t);
    if tg == TT_BOT { return "⊥"; }
    if tg == TT_TOP { return "⊤"; }
    if tg == TT_TOP_K { return "⊤" + int_str(tt_a(t)); }
    if tg == TT_UNION { return tt_display_at(tt_a(t), depth + 1) + " ∪ " + tt_display_at(tt_b(t), depth + 1); }
    if tg == TT_INTER { return tt_display_at(tt_a(t), depth + 1) + " ∩ " + tt_display_at(tt_b(t), depth + 1); }
    if tg == TT_NOT { return "¬" + tt_display_at(tt_a(t), depth + 1); }
    if tg == TT_MU { return "μ" + int_str(tt_a(t)) + "." + tt_display_at(tt_b(t), depth + 1); }
    if tg == TT_VAR { return "X" + int_str(tt_a(t)); }
    if tg == TT_NIL { return "nil"; }
    if tg == TT_CONS { return "cons(" + tt_display_at(tt_a(t), depth + 1) + ", " + tt_display_at(tt_b(t), depth + 1) + ")"; }
    if tg == TT_ATOM {
        ak := tt_a(t);
        // AK_NAMED 单列提前返回（**不是**风格偏好）：若并入下方 if-else 链，链内既有赋值分支
        // 又有 return 分支 ⇒ 自托管 checker 报 `error[TC02]: If branches have different types`
        // （本文件属 `check src/compiler` 语料 ⇒ 会给 CI 的 check 作业加一条**新**诊断——
        // 实测 build10 前版本命中：`tt_display_at` 的 AK_FN/AK_NAMED 分支）。
        if ak == AK_NAMED {
            nb := tt_b(t);
            if nb >= 0 { return "named#" + int_str(nb); }
            return "named";
        }
        head : ., mut = "";
        if ak == AK_INT { head = "int"; }
        else if ak == AK_DEX { head = "dex"; }
        else if ak == AK_STRING { head = "string"; }
        else if ak == AK_BOOL { head = "bool"; }
        else if ak == AK_UNIT { head = "unit"; }
        else if ak == AK_NEVER { head = "never"; }
        else if ak == AK_CHAR { head = "char"; }
        else if ak == AK_DYN { head = "dyn"; }
        else if ak == AK_NULL { head = "null"; }
        else if ak == AK_PRODUCT { head = "product"; }
        else if ak == AK_SUM { head = "sum"; }
        else if ak == AK_SEQUENCE { head = "sequence"; }
        else if ak == AK_REF { head = "ref"; }
        else if ak == AK_PTR { head = "ptr"; }
        else if ak == AK_FN { head = "fn"; }
        else { head = "atom#" + int_str(ak); }
        // 参数链（AK_REF 的槽 0 是 mut 标记：语义为 &/&mut，照桥接约定还原）
        if ak == AK_REF && tt_c(t) >= 0 && tt_tag(tt_c(t)) == TT_CONS {
            m := tt_a(tt_c(t));
            mut_s : ., mut = "&";
            if tt_tag(m) == TT_ATOM && tt_a(m) == AK_UNIT && tt_b(m) == 1 { mut_s = "&mut "; }
            rest := tt_b(tt_c(t));
            if rest >= 0 && tt_tag(rest) == TT_CONS { return mut_s + tt_display_at(tt_a(rest), depth + 1); }
            return mut_s;
        }
        p := tt_c(t);
        if p < 0 || tt_tag(p) != TT_CONS { return head; }
        s : ., mut = head + "<";
        k : ., mut = 0;
        loop {
            if p < 0 { break; }
            if tt_tag(p) != TT_CONS { break; }
            if k > 0 { s = s + ", "; }
            s = s + tt_display_at(tt_a(p), depth + 1);
            p = tt_b(p);
            k = k + 1;
        }
        return s + ">";
    }
    return "?";
}

fn tt_display(t: int) -> string { return tt_display_at(t, 0); }

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

// ═══════════════ R2 P3 Task 0：引擎展开层（named/struct/enum/generic-apply → 结构项）═══════════════
// **语义边界（裁错即判定全面漂移——本层第一性约束）**：展开**只服务**两条路径
//   ① 满足判定 `T <: 形状`（P3 Task 2 横切形状 / Task 6 用户接口；本批 = type_engine.cr 的
//      `iface_satisfies` 占位）
//   ② 穷尽性域/模式项（`sh_enum_domain_term` / `sh_variant_term`，P3 Task 3）
// **等价/包含判定（`type_equal` → `type_equal_engine` → `sh_term_of_ti` → `ty_equiv`）一律
// 不经本层**：命名类型在等价面的身份 = **原子名义**（AK_NAMED + 行号；`sh_term_of_ti` 的
// NAMED/GENERIC_* 分支本批**一行未动**）。把展开项接进等价判定 = 两个**同形不同名**的
// struct 被判等价（语义漂移），并推翻 P2a 对拍归零基线（`old_stricter=0 / old_looser=0`
// ——那条基线同时是 P5 删 `type_equal_legacy` 的前提）。守门用例 = `unf.nominal_*` 三例
// （双钉：展开项**结构相等** ∧ 桥接项 `ty_equiv` 仍 -1 ∧ `type_equal` 仍 false 且回落计数 +1）。
// 深度 = **一层**：字段/变体子项一律走既有 `sh_term_of_ti`（其命名/泛型分支**不展开**）
// ⇒ 递归结构（`struct Node { next: *Node }`）在第二层即终止；一层不足 → 按引擎既有约定
// **-1 上抛**（-1 = 不可展开/未覆盖面，消费方按三态处理——**不得**静默判否）。
// **非纯只读（诚实登记）**：字段类型节点经 checker 的 `res_type_node` 解析（**唯一实现**——
// 本层不复制其语义），故对非基型字段可追加类型行（alloc_type/alloc_named_type）、并可能报
// EC_N_GENERIC_TYPE。与 checker.cr EXPR_FIELD（:2583-2606）的字段解析**同源同径**。本批零
// 生产消费者；接入判定路径（Task 2/6）前须评估「判定中途分配类型行」的时序影响。
// 预算：展开步进计入引擎预算（`tt_step`）——耗尽 → -1（不得当 0/1）。范式与
// `ty_budget_reset` 的窗口隔离兼容（消费方在查询前 reset ⇒ 展开步数计入该窗口）。

// ─── 展开项布局（Task 3/4/6 消费约定；按**引擎比较面**设计）───
// ⚠ 引擎的原子比较只看 `a`（原子类）与 `c`（参数链）两槽（lit_implies:175-182；`b` 槽是
// **标注**、不参与比较——AK_NAMED 的 b 槽 = 行号即此约定）⇒ **语义身份必须入参数链**，
// 否则两类不同声明会静默合并（例：两个枚举的同名变体、两个不同枚举的域）。
//   struct → tt_atom(AK_PRODUCT, ti, 字段项链)          // 链序 = 声明序；**结构项**（同形同项）
//   enum   → 各变体项之**并**（左深 union）= 域         // 空枚举 → ⊥（无值可取，见下）
//   变体项 → tt_atom(AK_SUM, ti, [枚举名令牌, 变体名令牌]) // 身份 = (枚举, 变体) 两名**入链**
//     （P3 Task 1：两名以 **sh_name_token 原子**上链，不再用裸 name 索引——见该函数注记）
// 变体项**不含 payload**：枚举表只存 payload 的**裸 TY 码**（parser.cr:1601 的 unpack_type；
// 非基型塌缩为 0 = TY_INT，与「payload 是 int」**不可区分**）⇒ 含入即静默谎报；故 payload
// 不入项（**未覆盖面登记**：payload 面的满足判定归 Task 4——若需要，须先扩枚举表存 payload
// 类型节点，照 struct 的 OFF_SI_FIELD_TYPE_NODES 先例）。穷尽性按变体身份判定不受影响
// （现状模式面亦不按 payload 分解——EXPR_ENUMPAT 的子模式是另一条路径）。

UNF_MAP_INIT_CAP : int = 256;

// 展开缓存随类型表作废（同 sh_map_reset 同因同式：init_types 行号空间复用 ⇒ 陈旧 ti→展开项
// 命中 = 把上一个请求的类型结构安到当前行上；长驻 corelsp 每请求一次 init_types）。
fn sh_unf_map_reset() {
    g_unf_map_cap = 0;
    g_unf_entries = 0;
    g_unf_hits = 0;
}

fn sh_unf_cap_init() {
    if g_unf_map_cap <= 0 {
        nc : ., mut = UNF_MAP_INIT_CAP;
        nb := alloc(nc * 16);
        i : ., mut = 0;
        loop { if i >= nc { break; } w64(nb, i * 16, -1); i = i + 1; }
        g_unf_map = nb;
        g_unf_map_cap = nc;
    }
}

// 无守卫探测（**只可在扩容守卫之后调用**；重建重放借道）——形态照 sh_map_find_nogrow
// （typed 探测用 ret + break + 尾 return；函数体不以无 break 的 loop 收尾——自托管 checker
// 对该形态有 TF01 误报面，见该函数注记）。
fn sh_unf_find_nogrow(ti: int) -> int {
    cap := g_unf_map_cap;
    p : ., mut = tt_mod(ti, cap);
    ret : ., mut = -1;
    loop {
        k := r64(g_unf_map, p * 16);
        if k < 0 { ret = p; break; }
        if k == ti { ret = p; break; }
        p = p + 1; if p >= cap { p = 0; }
    }
    return ret;
}

fn sh_unf_find(ti: int) -> int {
    sh_unf_cap_init();
    // 装填因子守卫（**必须在探测前**）：表满且键不存在时开放寻址永不退出（死循环）
    if (g_unf_entries + 1) * 2 >= g_unf_map_cap { sh_unf_rehash(); }
    return sh_unf_find_nogrow(ti);
}

// 扩容 = 重建 + **重放既有条目**（引擎 grow_tt_index / 桥接 sh_map_rehash 同式）；计数随重放重算
fn sh_unf_rehash() {
    old := g_unf_map;
    old_cap := g_unf_map_cap;
    nc : ., mut = old_cap * 2;
    if nc < UNF_MAP_INIT_CAP { nc = UNF_MAP_INIT_CAP; }
    nb := alloc(nc * 16);
    i : ., mut = 0;
    loop { if i >= nc { break; } w64(nb, i * 16, -1); i = i + 1; }
    g_unf_map = nb;
    g_unf_map_cap = nc;
    g_unf_entries = 0;
    j : ., mut = 0;
    loop {
        if j >= old_cap { break; }
        k := r64(old, j * 16);
        if k >= 0 {
            s := sh_unf_find_nogrow(k);
            w64(g_unf_map, s * 16, k);
            w64(g_unf_map, s * 16 + 8, r64(old, j * 16 + 8));
            g_unf_entries = g_unf_entries + 1;
        }
        j = j + 1;
    }
}

fn sh_unf_hits() -> int { return g_unf_hits; }
fn sh_unf_entries() -> int { return g_unf_entries; }

// 枚举变体名 → 变体下标（-1 = 该枚举无此变体名）。线性扫（≤ MAX_ENUM_VARIANTS=16）。
fn sh_enum_variant_index(ea: int, name_ni: int) -> int {
    i : ., mut = 0;
    ret : ., mut = -1;
    loop {
        if i >= ei_variant_count(ea) { break; }
        if ei_variant_name(ea, i) == name_ni { ret = i; break; }
        i = i + 1;
    }
    return ret;
}

// struct 第 fi 字段 → 项（-1 = 不可展开）。泛型形参代入照 checker.cr EXPR_FIELD 的路径
// （那里返回 ti、消费方是 checker；此处返回项）：字段节点为 EXPR_IDENT 且名字 ∈ 该 struct 的
// 泛型形参名表 ⇒ 从**泛型应用实参**（ga，g_gen_apply_data: [count, arg1, …]）取对应实参项；
// 其余（非形参 / 非应用形态 / 实参缺位）→ 经 res_type_node 解析字段类型节点。
// 注：非应用形态下泛型形参保持**名义**（res_type_node 取该形参的类型行 ⇒ AK_NAMED 原子）——
// 不假装知道实参是什么（EXPR_FIELD 的落空路径同款）。嵌套代入（`Box[Box[T]]`）现状不可达：
// 形参只做**一层**代入（与 checker 现状一致；F4 同族缺陷，TODO #21 / Task 5 收口）。
fn sh_struct_field_term(sa: int, fi: int, ga: int) -> int {
    fnode := si_field_type_node(sa, fi);
    if fnode < 0 { return -1; }
    if ast_kind(fnode) == EXPR_IDENT {
        fni := ast_int_val(fnode);
        if is_struct_generic(sa, fni) {
            if ga >= 0 && get_type_kind(ga) == TYP_GENERIC_APPLY {
                gstart := get_type_extra(ga);
                gcnt := r64(g_gen_apply_data, gstart * 8);
                gpi : ., mut = 0;
                loop {
                    if gpi >= si_generic_count(sa) { break; }
                    if si_generic_name(sa, gpi) == fni {
                        if gpi < gcnt { return sh_term_of_ti(r64(g_gen_apply_data, (gstart + 1 + gpi) * 8)); }
                        break;   // 实参缺位 → 落空到名义项（下方 res_type_node），不得取越界槽
                    }
                    gpi = gpi + 1;
                }
            }
        }
    }
    fti := res_type_node(fnode);
    if fti < 0 { return -1; }
    return sh_term_of_ti(fti);
}

// struct 命名行 / 泛型应用行 → AK_PRODUCT（参数链 = 逐字段项，**声明序**）。
// -1 = 不可展开（既非命名行也非泛型应用行 / 名字未声明为 struct / 任一字段不可展开 / 预算耗尽）。
fn sh_struct_term(ti: int) -> int {
    if ti < 0 { return -1; }
    if get_type_kind(ti) < 0 { return -1; }          // 行号越界（ti ≥ g_type_count）
    sa := find_struct_row_of(ti);
    if sa < 0 { return -1; }
    slot := sh_unf_find(ti);
    if r64(g_unf_map, slot * 16) == ti {
        g_unf_hits = g_unf_hits + 1;
        return r64(g_unf_map, slot * 16 + 8);
    }
    ga : ., mut = -1;
    if get_type_kind(ti) == TYP_GENERIC_APPLY { ga = ti; }
    // CONS 链**逆序构造**（i 自末尾向前）：DAG 项不可变，正向追加需改写已建项；逆序构造的
    // 结果顺序仍 = 声明序（照 sh_tuple_to_product 同款同因）。
    tail : ., mut = tt_nil();
    i : ., mut = si_field_count(sa) - 1;
    loop {
        if i < 0 { break; }
        if tt_step() == -1 { return -1; }             // 预算耗尽 → 上抛（不得当「空 product」）
        ft := sh_struct_field_term(sa, i, ga);
        if ft < 0 { return -1; }                      // 任一字段不可展开 ⇒ 整项不可展开（不缓存）
        tail = tt_cons(ft, tail);
        i = i - 1;
    }
    term := tt_atom(AK_PRODUCT, ti, tail);
    // 写回前**重探**（字段解析期间可能已扩容——照 sh_term_of_ti 注记②同款）
    slot2 := sh_unf_find(ti);
    if r64(g_unf_map, slot2 * 16) == ti {
        g_unf_hits = g_unf_hits + 1;
        return r64(g_unf_map, slot2 * 16 + 8);
    }
    w64(g_unf_map, slot2 * 16, ti);
    w64(g_unf_map, slot2 * 16 + 8, term);
    g_unf_entries = g_unf_entries + 1;
    return term;
}

// 变体名 → 变体项（穷尽性**模式项**用；与域中的对应变体项**同一构造**——两者必须逐位相同，
// 否则补集判定失真）。name_ni 必须是该枚举**声明过的**变体名（否则 -1：不得为未声明变体臆造项）。
// ti 接受命名行与泛型应用行（变体身份与实参无关——payload 不入项时 Option[int]/Option[str]
// 的变体集相同，正是穷尽性所需）。
fn sh_variant_term(ti: int, name_ni: int) -> int {
    ea := find_enum_row_of(ti);
    if ea < 0 { return -1; }
    if sh_enum_variant_index(ea, name_ni) < 0 { return -1; }
    // P3 Task 1：身份两名经 **sh_name_token** 上链（旧约定 = 裸 name 索引入链——索引用作
    // 链元素时会被结构比较当术语下标解释，见 sh_name_token 注记）；两构造点（域/模式项）
    // 仍逐位同一 ✓
    return tt_atom(AK_SUM, ti, tt_cons(sh_name_token(ei_name(ea)), tt_cons(sh_name_token(name_ni), tt_nil())));
}

// enum 命名行 / 泛型应用行 → **域** = 各变体项之并（左深 union）。
// -1 = 不可展开（非枚举行 / 预算耗尽）。空枚举（0 变体）→ ⊥ = 无值可取（**唯一**的
// 「展开成功但域为空」形态；Task 3 判穷尽时对该形态须显式裁决——空域在补集语义下恒穷尽）。
fn sh_enum_domain_term(ti: int) -> int {
    if ti < 0 { return -1; }
    if get_type_kind(ti) < 0 { return -1; }
    ea := find_enum_row_of(ti);
    if ea < 0 { return -1; }
    slot := sh_unf_find(ti);
    if r64(g_unf_map, slot * 16) == ti {
        g_unf_hits = g_unf_hits + 1;
        return r64(g_unf_map, slot * 16 + 8);
    }
    acc : ., mut = tt_bot();
    i : ., mut = 0;
    loop {
        if i >= ei_variant_count(ea) { break; }
        if tt_step() == -1 { return -1; }
        v := sh_variant_term(ti, ei_variant_name(ea, i));
        if v < 0 { return -1; }
        acc = tt_union(acc, v);
        i = i + 1;
    }
    slot2 := sh_unf_find(ti);
    if r64(g_unf_map, slot2 * 16) == ti {
        g_unf_hits = g_unf_hits + 1;
        return r64(g_unf_map, slot2 * 16 + 8);
    }
    w64(g_unf_map, slot2 * 16, ti);
    w64(g_unf_map, slot2 * 16 + 8, acc);
    g_unf_entries = g_unf_entries + 1;
    return acc;
}

// 接口 → 形状项（方法集 = product of fn）——**仍为占位，恒 -1**（阻塞精确定位见下）：
// 现状接口方法签名存**裸 TY_***（parser.cr:1671/1685 的 `unpack_type` ⇒ 非原生类型节点一律
// ═══════════════ R2 P3b Task 6（Step 1/3）：签名规范项 + 接口形状项 ═══════════════
// 语义（spec §2.3「interface I → 形状类型项：方法集 = product of fn 原子（方法签名各自为
// fn(τ₁…τₙ)->τ 项）」）：本段是**签名项化**的唯一构造点。Step 1 交付了类型节点槽
// （`OFF_IFM_PARAM_NODES` / `OFF_IFM_RET_NODE`）⇒ 签名首次可用**类型**而非映射层码表达。
//
// ⚠ 为何需要**规范形**（而不是直接复用 `sh_term_of_ti` 的项）：判定走引擎 `ty_sub`，而
// 引擎在「不变槽」上按**节点同一性**比较链元素（`tt_list_same`），且对 AK_NAMED **不展开**
// （P0 未覆盖面②）。直接桥接的项有两个身份缺陷：
//   ① `TYP_GENERIC_APPLY` 行经 `alloc_type` **裸分配**（不去重）⇒ 同型的两次出现是**不同**
//      节点 ⇒ 同签名被判不同（假违反）；
//   ② 序列项的 b 槽（N / 固定性）在节点同一性下**入身份** ⇒ `[int;3]` 与 `[int;4]` 判不同
//      ——与「N 不入身份」不变量（R1 裁决 / P3a Task 1）相悖（N 面由常量档承担）。
// 规范形把**身份维度**入项、其余归一：泛型应用 = 基名行（named_dedup 已按名规范） + 实参链；
// 序列 = N 归 -1；指针 = asp 不入项（照桥接）；命名行 = 行（按名规范）；引用 = mut 标记入项
// （身份维度，照桥接）。⇒ **同型恒同节点、异型恒异节点**，引擎的 `ty_sub`（顶原子 AK_FN 的
// 不变槽链比较）即给出签名相等判定（1/0；-1 面只剩建项失败）。
// dyn（位图行不参与规范形）与未知 kind ⇒ -1（未覆盖面，**不得**当 0/1）。
// 零 str_intern：全部走既有 ni/行（.ccr STR 段守）。
fn sh_sig_term_of_ti(ti: int) -> int {
    if ti < 0 { return -1; }
    k := get_type_kind(ti);
    if k < 0 { return -1; }
    if k == TYP_BASE {
        d := get_type_data(ti);
        ak := sh_base_ak(d);
        if ak < 0 { return -1; }
        return tt_atom(ak, ti, -1);
    }
    if k == TYP_NAMED || k == TYP_GENERIC_PARAM {
        // 命名行：named_dedup 按名规范（同名恒同行）；泛型形参行 = 声明点行（跨声明不同行 =
        // 已登记面：签名内含泛型形参的匹配只在同一声明内成立）
        return tt_atom(AK_NAMED, ti, -1);
    }
    if k == TYP_NULL { return sh_null_term(); }
    if k == TYP_ARRAY || k == TYP_SLICE {
        el := sh_sig_term_of_ti(get_type_data(ti));
        if el < 0 { return -1; }
        return tt_atom(AK_SEQUENCE, -1, tt_cons(el, tt_nil()));
    }
    if k == TYP_PTR {
        el2 := sh_sig_term_of_ti(get_type_data(ti));
        if el2 < 0 { return -1; }
        return tt_atom(AK_PTR, -1, tt_cons(el2, tt_nil()));
    }
    if k == TYP_REF {
        el3 := sh_sig_term_of_ti(get_type_data(ti));
        if el3 < 0 { return -1; }
        return tt_atom(AK_REF, -1, tt_cons(sh_ref_mut_marker(get_type_extra(ti)), tt_cons(el3, tt_nil())));
    }
    if k == TYP_OPTIONAL {
        el4 := sh_sig_term_of_ti(get_type_data(ti));
        if el4 < 0 { return -1; }
        return tt_union(el4, sh_null_term());
    }
    if k == TYP_TUPLE {
        cnt := get_type_data(ti);
        start := get_type_extra(ti);
        tail : ., mut = tt_nil();
        i : ., mut = cnt - 1;
        loop {
            if i < 0 { break; }
            et := sh_sig_term_of_ti(r64(g_gen_apply_data, (start + i) * 8));
            if et < 0 { return -1; }
            tail = tt_cons(et, tail);
            i = i - 1;
        }
        return tt_atom(AK_PRODUCT, -1, tail);
    }
    if k == TYP_GENERIC_APPLY {
        base := get_type_data(ti);
        if get_type_kind(base) != TYP_NAMED { return -1; }
        start2 := get_type_extra(ti);
        cnt2 := r64(g_gen_apply_data, start2 * 8);
        if cnt2 < 0 { return -1; }
        tail2 : ., mut = tt_nil();
        j : ., mut = cnt2 - 1;
        loop {
            if j < 0 { break; }
            at := sh_sig_term_of_ti(r64(g_gen_apply_data, (start2 + 1 + j) * 8));
            if at < 0 { return -1; }
            tail2 = tt_cons(at, tail2);
            j = j - 1;
        }
        return tt_atom(AK_NAMED, base, tail2);
    }
    return -1;   // TYP_DYN（位图行）/ 未知 kind：未覆盖面
}

// 类型**节点** → 签名项（节点契约：<0 = 无节点 ⇒ unit；照 checker 的 `type_node > 0` 约定，
// 但用 -1 哨兵以免与「节点 0」混同）。res_type_node 的解析面 = 与其它消费点同一入口。
fn sh_sig_term_of_node(node: int) -> int {
    if node < 0 { return sh_sig_term_of_ti(TI_UNIT); }
    ti := res_type_node(node);
    return sh_sig_term_of_ti(ti);
}

// 接口方法签名的**参数项**（idx 自 0 起）。接收者槽（self_mode ≠ 0 且 idx == 0）= unit
// **占位**——接收者模式（self/&self/&mut self）是调用约定而非类型集维度，由消费方**显式比较**
//（`sh_iface_self_mode` / `sh_func_self_mode`）；不为它造令牌原子的理由：令牌的 b 槽在引擎
// 的类级比较（只看 a/c 两槽）下不可见 ⇒ 模式 1/2/3 会互相判等（静默）。
fn sh_iface_sig_param_term(ii: int, mi: int, idx: int) -> int {
    if ii < 0 || mi < 0 || idx < 0 { return -1; }
    if idx >= MAX_IFACE_METHOD_PARAMS { return -1; }
    mbase := ii * ESZ_IFACEINFO + OFF_IF_METHODS + mi * ESZ_IFMETHOD;
    if r64(g_ifaces, mbase + OFF_IFM_PARAM_COUNT) <= idx { return -1; }
    smode := r64(g_ifaces, mbase + OFF_IFM_SELF_MODE);
    if idx == 0 && smode != 0 { return sh_sig_term_of_ti(TI_UNIT); }
    return sh_sig_term_of_node(r64(g_ifaces, mbase + OFF_IFM_PARAM_NODES + idx * 8));
}

fn sh_iface_sig_ret_term(ii: int, mi: int) -> int {
    if ii < 0 || mi < 0 { return -1; }
    mbase := ii * ESZ_IFACEINFO + OFF_IF_METHODS + mi * ESZ_IFMETHOD;
    return sh_sig_term_of_node(r64(g_ifaces, mbase + OFF_IFM_RET_NODE));
}

fn sh_iface_self_mode(ii: int, mi: int) -> int {
    if ii < 0 || mi < 0 { return -1; }
    return r64(g_ifaces, ii * ESZ_IFACEINFO + OFF_IF_METHODS + mi * ESZ_IFMETHOD + OFF_IFM_SELF_MODE);
}

// impl 侧（函数行）签名的**参数项**（idx 自 0 起；从 AST 形参链前扫解析——形参节点不连续，
// 每参的类型节点插在其后，照 ir_gen/checker 同款扫描约定）。接收者槽同占位约定。
fn sh_func_sig_param_term(fi: int, idx: int) -> int {
    if fi < 0 || idx < 0 { return -1; }
    fn_node := fi_ast_node(fi);
    if fn_node < 0 { return -1; }
    if ast_kind(fn_node) != EXPR_FN { return -1; }
    if idx >= fi_param_count(fi) { return -1; }
    pn := ast_b(fn_node);   // EXPR_FN: b = first param node（a = 函数名 ni——不是形参入口）
    pi : ., mut = 0;
    loop {
        if pn < 0 { return -1; }
        if pn >= g_ast_count { return -1; }
        if ast_kind(pn) == EXPR_PARAM {
            if pi == idx {
                mode := ast_int_val(pn);
                if mode == -1 { return -1; }      // 变参：签名项不可表达（登记）
                if mode != 0 { return sh_sig_term_of_ti(TI_UNIT); }
                return sh_sig_term_of_node(ast_data(pn));
            }
            pi = pi + 1;
        }
        pn = pn + 1;
    }
    return -1;
}

fn sh_func_self_mode(fi: int) -> int {
    if fi < 0 { return -1; }
    fn_node := fi_ast_node(fi);
    if fn_node < 0 { return -1; }
    if ast_kind(fn_node) != EXPR_FN { return -1; }
    if fi_param_count(fi) <= 0 { return 0; }
    pn := ast_b(fn_node);   // EXPR_FN: b = first param node
    loop {
        if pn < 0 { return -1; }
        if pn >= g_ast_count { return -1; }
        if ast_kind(pn) == EXPR_PARAM {
            m := ast_int_val(pn);
            if m == -1 { return -1; }
            return m;
        }
        pn = pn + 1;
    }
    return -1;
}

// impl 侧函数行的返回项（解析规则 = check_func 的返回位逐字同款：非基型节点走
// res_type_node；基型/无节点走码表（域含 NEVER、缺 7 ⇒ unit 兜底））。
fn sh_func_sig_ret_term(fi: int) -> int {
    if fi < 0 { return -1; }
    fn_node := fi_ast_node(fi);
    if fn_node < 0 { return -1; }
    if ast_kind(fn_node) != EXPR_FN { return -1; }
    rnode := ast_type_val(fn_node);
    ret_ti : ., mut = TI_UNIT;
    if rnode > 0 && ast_kind(rnode) != 0 {
        ret_ti = res_type_node(rnode);
    } else {
        rm := ty_code_to_ti(fi_return_type(fi));
        if rm >= 0 && rm != TI_DYN { ret_ti = rm; }
    }
    return sh_sig_term_of_ti(ret_ti);
}

// 函数行 → **fn 项**：`tt_atom(AK_FN, -1, [返回项, 参数项…])`（链序 = 返回在首，参数按声明序；
// 逆序构造，照 sh_tuple_to_product 同因）。b 槽留空（引擎比较只看 a/c ⇒ 方法名不参与判定）。
fn sh_func_sig_term(fi: int) -> int {
    if fi < 0 { return -1; }
    pc := fi_param_count(fi);
    if pc < 0 || pc > MAX_FN_PARAMS { return -1; }
    rt := sh_func_sig_ret_term(fi);
    if rt < 0 { return -1; }
    tail : ., mut = tt_cons(rt, tt_nil());
    i : ., mut = pc - 1;
    loop {
        if i < 0 { break; }
        pt := sh_func_sig_param_term(fi, i);
        if pt < 0 { return -1; }
        tail = tt_cons(pt, tail);
        i = i - 1;
    }
    return tt_atom(AK_FN, -1, tail);
}

// 接口 → 形状类型项（spec §2.3）：`tt_atom(AK_PRODUCT, -1, [fn 项…])`，链序 = 方法声明序
// （与 `g_ifaces` 方法表同序——消费方按表索引取成员，见 type_engine 的轴 C）。成员 fn 项的
// **b 槽 = 方法名 ni**（消费方的查表键；引擎不比较 b，本层显式读取）。
// -1 = 不可建（接口名未声明 / 方法数越界（>16）/ 任一签名项不可建 / 参数数越界（>8））。
// 零方法接口 ⇒ 空 product（`tt_nil()` 链）——空洞满足的载体（判定面见轴 C）。
// 三态纪律：-1 = 未覆盖面，**不得**被消费方当 0（不满足）或 1（满足）用。
fn sh_iface_shape_term(iface_ni: int) -> int {
    if iface_ni < 0 { return -1; }
    ii := find_iface(iface_ni);
    if ii < 0 { return -1; }
    mc := r64(g_ifaces, ii * ESZ_IFACEINFO + OFF_IF_METHOD_COUNT);
    if mc < 0 { return -1; }
    if mc > MAX_IFACE_METHODS { return -1; }
    tail : ., mut = tt_nil();
    i : ., mut = mc - 1;
    loop {
        if i < 0 { break; }
        mbase := ii * ESZ_IFACEINFO + OFF_IF_METHODS + i * ESZ_IFMETHOD;
        m_ni := r64(g_ifaces, mbase + OFF_IFM_NAME);
        pc := r64(g_ifaces, mbase + OFF_IFM_PARAM_COUNT);
        if pc < 0 || pc > MAX_IFACE_METHOD_PARAMS { return -1; }
        rt2 := sh_iface_sig_ret_term(ii, i);
        if rt2 < 0 { return -1; }
        ptail : ., mut = tt_cons(rt2, tt_nil());
        pj : ., mut = pc - 1;
        loop {
            if pj < 0 { break; }
            pterm := sh_iface_sig_param_term(ii, i, pj);
            if pterm < 0 { return -1; }
            ptail = tt_cons(pterm, ptail);
            pj = pj - 1;
        }
        tail = tt_cons(tt_atom(AK_FN, m_ni, ptail), tail);
        i = i - 1;
    }
    return tt_atom(AK_PRODUCT, -1, tail);
}

// 形状项的第 idx 个成员（fn 项；-1 = 越界/非形状项）。消费方（轴 C）按方法表索引取用。
fn sh_shape_member_at(shp: int, idx: int) -> int {
    if shp < 0 || idx < 0 { return -1; }
    if tt_tag(shp) != TT_ATOM { return -1; }
    if tt_a(shp) != AK_PRODUCT { return -1; }
    c := tt_c(shp);
    i : ., mut = 0;
    loop {
        if i > idx { return -1; }
        if c < 0 { return -1; }
        if tt_tag(c) != TT_CONS { return -1; }
        if i == idx { return tt_a(c); }
        c = tt_b(c);
        i = i + 1;
    }
    return -1;
}

// ─── R2 P3b Task 2：序列行的**固定性**读取（range 消费点的表示层维度）───
// 返回：固定长序列的 N（数组，≥0）/ -1（视图（切片）/ 非序列行 / 不可译行）。
// 依据 = 序列项的 **b 槽**（`sh_seq_term`：数组 = N、切片/视图 = -1）——**表示提示层**，
// 语义判定不看 N（spec §5.1「N 是表示提示，语义判定不看」；T1 裁定「固定性位不入身份/比较」，
// 消费者逐条登记 = 常量档检查 + 表示层 + 本 Task 的横切形状面）。
// 用途 = checker 的 range 索引分支（`arr[lo..hi]`）：固定长 ⇒ 产视图（`[T]`）；视图 ⇒ 现状
// `TI_UNIT`（IP_INDEX_RANGE 未接线，登记面）。**不得**把它读作身份/子类型维度（那是常量档的
// 职责；本站只决定「range 在本行上产不产视图」的结果形态，行为与改动前逐行相同）。
fn sh_seq_fixed_len_of_ti(ti: int) -> int {
    t := sh_term_of_ti(ti);
    if t < 0 { return -1; }
    if tt_tag(t) != TT_ATOM { return -1; }
    if tt_a(t) != AK_SEQUENCE { return -1; }
    return tt_b(t);
}

// ═══════════════ R2 P3 Task 3：match 穷尽性消费点（补集空性 + 具体变体反例）═══════════════
// 判据本体 = 引擎的**补集空性**（`ty_exhaustive`：domain \ ⋃patterns 的可满足性；P0 已落）。
// **引擎不在本 Task 文件面内**（协调者裁决）⇒ 引擎侧的两处缺口一律在**消费点**消化：
//   ① **域守卫**（域限定，计划显式登记）：仅**枚举 scrutinee** 判穷尽（域 = 变体集）；
//      scrutinee 非枚举/域不可展开（struct/原生/int/string/bool…）⇒ **不判**（-1）。非枚举域
//      **不得**假装穷尽、**不得**假装不穷尽——故本层零诊断、零硬错误。
//   ② **模式面守卫**：任一臂模式**不可忠实映射** ⇒ **不判**（-1）。不可映射 = 字面量模式
//      （int/string/char/bool）/ struct 模式 / 非本枚举的变体名。**不得**把它们当 ∅（凭空判
//      「不穷尽」）或当 ⊤（凭空判「穷尽」）——三态纪律：未知一律 -1，由消费方零动作。
//   ③ **反例的具体值**：引擎 witness 的原始形态 = 各析取支之**并**（`tt_norm` 不做空支净化：
//      缺失 B 时 = (A∩¬A)∪(B∩¬A)，按 `ty_equiv` 与「缺失变体」**不等**——Task 0 §5-② 实测）
//      ⇒ 反例**不**取 witness 项，而按**变体逐项覆盖位**命名（`sh_match_first_missing`）：
//      与引擎判据同源（同一变体项构造）但独立计算 ⇒ 两路一致性由自测用例钉死。
// 模式项约定（与展开层/引擎对齐）：通配 `_` 与绑定 ident = `tt_top()`（引擎侧 ⊤ 吸收 = 覆盖
// 一切；值域不绑）；变体模式 = `sh_variant_term(scrut_ti, vni)`——**与域内对应变体同一构造**
// （两个构造点不同 ⇒ 补集判定失真）。

// 臂模式 → 类别：1 = ⊤（通配 `_` / 绑定 ident）/ 2 = 枚举变体模式（须再判归属）/ 0 = 不可映射。
fn sh_match_pat_kind(pat_node: int) -> int {
    if pat_node < 0 { return 0; }
    k := ast_kind(pat_node);
    if k == EXPR_WILDCARD { return 1; }
    if k == EXPR_IDENT { return 1; }        // 绑定 = 通配（值域不绑；与 ir_gen 的按值比较臂不同层）
    if k == EXPR_ENUMPAT { return 2; }
    return 0;                               // 字面量 / struct 模式 / EXPR_NONE ⇒ 不可映射（登记）
}

// 变体模式 → **本枚举**变体下标（-1 = 不属本枚举 / 名字不可解析 / scrutinee 不可展开）。
// 名字两形态（parser.cr parse_pattern 的产物）：裸变体名（`Red`）/ 限定名（`Color.Red`
// ——parser 的 name + "." + variant 拼接）。限定名取**末点后段**为变体名（口径与 ir_gen.cr
// get_variant_name_idx 一致；此处**不调 str_intern**——`.ccr` STR 段 = g_strs 全量，
// 见 P2b 附录 A.3-② 的硬判据约束）。前缀不是本枚举名 ⇒ -1（该模式对本域无覆盖，但按②取
// **不可判**而非 ∅）。变体名比较用 str_eq 逐项（不驻留新串）。
fn sh_match_pat_variant(scrut_ti: int, pat_node: int) -> int {
    ea := find_enum_row_of(scrut_ti);
    if ea < 0 { return -1; }
    if pat_node < 0 { return -1; }
    // 名字槽 = **a**（parser.cr parse_pattern：`alloc_node(EXPR_ENUMPAT, ni, …)`；ir_gen 的
    // 消费点同用 ast_a 取之。**不是** int_val——EXPR_IDENT 才把名字放 int_val）。
    pname := istr_get(ast_a(pat_node));
    slen := str_len(pname);
    dot : ., mut = -1;
    i : ., mut = 0;
    loop {
        if i >= slen { break; }
        c := get_char(pname, i);
        if str_eq(c, ".") != 0 { dot = i; }
        i = i + 1;
    }
    vname : ., mut = pname;
    if dot >= 0 {
        head := str_sub(pname, 0, dot);
        if str_eq(head, istr_get(ei_name(ea))) == 0 { return -1; }
        vname = str_sub(pname, dot + 1, slen - dot - 1);
    }
    vi : ., mut = 0;
    loop {
        if vi >= ei_variant_count(ea) { return -1; }
        if str_eq(istr_get(ei_variant_name(ea, vi)), vname) != 0 { return vi; }
        vi = vi + 1;
    }
    return -1;
}

// 变体下标 → 变体项（-1 = 越界/scrutinee 不可展开）；与 sh_variant_term 的唯一入口关系
fn sh_match_variant_term(scrut_ti: int, vi: int) -> int {
    ea := find_enum_row_of(scrut_ti);
    if ea < 0 { return -1; }
    if vi < 0 || vi >= ei_variant_count(ea) { return -1; }
    return sh_variant_term(scrut_ti, ei_variant_name(ea, vi));
}

// 覆盖位：bit(vi) = 2^vi（本语言无移位 ⇒ 循环乘 2，同 iface_bit；vi < 63 由
// MAX_ENUM_VARIANTS = 16 保证不溢出——**该前提自 R2 P4 Task 6 起由写入侧护栏强制**：
// >16 变体 = `error[P022]` 硬拒（parse 阶段诊断闸，编译不进入判定面）；此前只是假设）
fn sh_match_bit(vi: int) -> int {
    if vi < 0 { return 0; }
    b : ., mut = 1;
    k : ., mut = vi;
    loop { if k <= 0 { break; } b = b * 2; k = k - 1; }
    return b;
}

// 首个**未覆盖**变体下标（-1 = 全覆盖 = 反例面为空）。反例命名 = 本函数（头注③）；位测试照
// iface_permits 的 (bits / bit) % 2 惯例（**无按位与运算符**；bits ≥ 0、bit > 0 ⇒ 取模非负）。
fn sh_match_first_missing(cover_bits: int, count: int) -> int {
    i : ., mut = 0;
    loop {
        if i >= count { return -1; }
        b := sh_match_bit(i);            // i ≥ 0 ⇒ b ≥ 1（除零不可达）
        if (cover_bits / b) % 2 == 0 { return i; }
        i = i + 1;
    }
    return -1;
}

// 穷尽性三态：1 = 穷尽（补集空）/ 0 = 不穷尽（有反例变体）/ -1 = **不判**（域不可展开 /
// 模式不可映射 / 引擎未知=预算耗尽）。消费方：0 → 诊断 + 反例命名；1/-1 → 零动作。
// R2 P3 Task 4：域面扩一条 —— `T?`（TYP_OPTIONAL）的域 = `T ∪ null`（sh_match_domain_term）。
fn sh_match_exhaustive(scrut_ti: int, pat_terms: int, unmappable: int) -> int {
    if unmappable != 0 { return -1; }
    dom := sh_match_domain_term(scrut_ti);
    if dom < 0 { return -1; }               // 非枚举/非可选域 ⇒ 不判（域限定的显式登记）
    return ty_exhaustive(dom, pat_terms);
}

// ═══════════════ R2 P3 Task 4：联合/可选（`T?` = `T ∪ null`）的 match 域面 ═══════════════
// 域：枚举行 → 变体集之并（Task 0/3 的 sh_enum_domain_term）；**TYP_OPTIONAL 行 → T ∪ null**。
// 分支（两分，与 spec §5.4 的「T? 两分支：有值 + None」一致）：
//   0 = 有值部分（`Some(…)` 模式；项 = 内层项本身——`T?` 的值域含裸 T 值，见 checker 的行语义）
//   1 = null 部分（`None` 模式；项 = sh_null_term()）
// 三态纪律：非可选 scrutinee ⇒ -1（不判）；可选 scrutinee 上的**异域模式**（别的变体名/字面量）
// ⇒ -1（不可映射，同 Task 3 的②：不得当 ∅ 或 ⊤）。
// 名字形态：仅裸名 `Some`/`None`（**限定名不接受**——可选无类型名可作前缀；用户声明
// `enum Option` 时那走枚举域那条路，与本路互不干扰）。
fn sh_match_domain_term(ti: int) -> int {
    if ti < 0 { return -1; }
    if get_type_kind(ti) == TYP_OPTIONAL {
        in5 := sh_term_of_ti(get_type_data(ti));
        if in5 < 0 { return -1; }           // 内层不可译 ⇒ 域不可展开（不判）
        return tt_union(in5, sh_null_term());
    }
    return sh_enum_domain_term(ti);
}

// 可选模式 → 分支下标（0 = 有值 / 1 = null；-1 = 不可映射或非可选 scrutinee）。
// 名字槽 = ast_a（EXPR_ENUMPAT 契约，Task 3 §6-②）；`Some`/`None` 是关键字名。
fn sh_match_opt_pat(scrut_ti: int, pat_node: int) -> int {
    if scrut_ti < 0 { return -1; }
    if get_type_kind(scrut_ti) != TYP_OPTIONAL { return -1; }
    if pat_node < 0 { return -1; }
    pname := istr_get(ast_a(pat_node));
    if str_eq(pname, "Some") != 0 { return 0; }   // `Some(…)` 与裸 `Some` 同判（载荷绑定不参与）
    if str_eq(pname, "None") != 0 { return 1; }
    return -1;
}

// 分支下标 → 覆盖项（与 sh_match_domain_term 的析取支**同一构造**——两个构造点不同 ⇒ 补集失真）。
fn sh_match_opt_term(scrut_ti: int, part: int) -> int {
    if part == 0 { return sh_term_of_ti(get_type_data(scrut_ti)); }
    return sh_null_term();
}

// ─── R2 P3 Task 4：枚举变体**载荷项**（T0 交接 ① 的消费面；载荷类型节点列的唯一读取点）───
// 背景（Task 0 §5-①）：枚举表旧布局只存载荷**裸 TY 码**（OFF_EV_TYPES），非基型一律塌缩为
// 0 = TY_INT ⇒ 「载荷是 int」与「载荷是 string/命名类型/泛型形参」**不可区分**。本任务按
// struct 先例补 **OFF_EV_TYPE_NODES 列**（parser 随裸码同写类型节点；见 parser.cr 枚举分支），
// 本函数即该列的忠实读取点：泛型形参按泛型应用行的实参**代入**（照 sh_struct_field_term 的
// 路径——一层代入，嵌套代入属 F4 同族缺陷/TODO #21）。
// 返回：单载荷 = 该载荷项；多载荷 = AK_PRODUCT 链（**声明序**，逆序构造）；**0 载荷（tag 变体）→ -1**
// （语义域外登记：载荷为空 ≠ 载荷 unit——不发明「tag 变体 = 单点」的项，Task 5/6 若需要另裁）。
// -1 = 不可展开（非枚举行 / 无此变体名 / 无载荷 / 载荷节点缺失 / 任一载荷不可译 / 预算耗尽）。
fn sh_variant_payload_at(ea: int, vi: int, i: int, ga: int) -> int {
    pn := ei_variant_type_node(ea, vi, i);
    if pn < 0 { return -1; }
    if ast_kind(pn) == EXPR_IDENT {
        pni := ast_int_val(pn);
        gi2 : ., mut = 0;
        loop {
            if gi2 >= ei_generic_count(ea) { break; }
            if ei_generic_name(ea, gi2) == pni {
                // 泛型形参：泛型应用行的对应实参（缺位 → 落空到名义，照 sh_struct_field_term）
                if ga >= 0 && get_type_kind(ga) == TYP_GENERIC_APPLY {
                    gstart2 := get_type_extra(ga);
                    gcnt2 := r64(g_gen_apply_data, gstart2 * 8);
                    if gi2 < gcnt2 { return sh_term_of_ti(r64(g_gen_apply_data, (gstart2 + 1 + gi2) * 8)); }
                }
                break;
            }
            gi2 = gi2 + 1;
        }
    }
    pti := res_type_node(pn);
    if pti < 0 { return -1; }
    return sh_term_of_ti(pti);
}

fn sh_variant_payload_term(ti: int, name_ni: int) -> int {
    ea := find_enum_row_of(ti);
    if ea < 0 { return -1; }
    vi := sh_enum_variant_index(ea, name_ni);
    if vi < 0 { return -1; }
    tc := ei_variant_type_count(ea, vi);
    if tc <= 0 { return -1; }
    ga : ., mut = -1;
    if get_type_kind(ti) == TYP_GENERIC_APPLY { ga = ti; }
    tail : ., mut = tt_nil();
    i : ., mut = tc - 1;
    loop {
        if i < 0 { break; }
        if tt_step() == -1 { return -1; }
        pt := sh_variant_payload_at(ea, vi, i, ga);
        if pt < 0 { return -1; }
        tail = tt_cons(pt, tail);
        i = i - 1;
    }
    if tc == 1 { return tt_a(tail); }        // 单载荷：链首即载荷项（不套空实义 product）
    return tt_atom(AK_PRODUCT, ti, tail);
}

// ─── R2 P3 Task 4：枚举载荷列入库断言（调试通道 `--verify-evp-nodes`，默认关）───
// 报文 = `[enum-payload-verify] enums=E variants=V slots=S collapses=C bad=B`，返回 bad
// （>0 ⇒ 调用方 rc=1）。断言：**每个载荷槽都有类型节点**（< 0 = parser 未写 = 本任务的前置
// 缺口复发）。`collapses` = 裸码列说 int（TY_INT=0）而**节点列不是 int 基型节点**的槽数——
// 即「裸码丢失了真实载荷类型」的可数证据（T0 §5-① 的仓库级量化）；它是**信息量**（≥ 0 正常），
// 不是失败（bad 才算失败）。只读、只计数、不写任何表。
fn sh_evp_verify() -> int {
    bad : ., mut = 0;
    slots : ., mut = 0;
    collapsed : ., mut = 0;
    variants : ., mut = 0;
    ei : ., mut = 0;
    loop {
        if ei >= g_enum_count { break; }
        vi : ., mut = 0;
        loop {
            if vi >= ei_variant_count(ei) { break; }
            variants = variants + 1;
            tc2 := ei_variant_type_count(ei, vi);
            ti2 : ., mut = 0;
            loop {
                if ti2 >= tc2 { break; }
                slots = slots + 1;
                code := ei_variant_type(ei, vi, ti2);
                pn2 := ei_variant_type_node(ei, vi, ti2);
                if pn2 < 0 {
                    bad = bad + 1;
                } else if code == TY_INT {
                    if ast_kind(pn2) != 0 || ast_type_val(pn2) != TY_INT { collapsed = collapsed + 1; }
                }
                ti2 = ti2 + 1;
            }
            vi = vi + 1;
        }
        ei = ei + 1;
    }
    print("[enum-payload-verify] enums=");
    print(int_str(g_enum_count));
    print(" variants=");
    print(int_str(variants));
    print(" slots=");
    print(int_str(slots));
    print(" collapses=");
    print(int_str(collapsed));
    print(" bad=");
    println(int_str(bad));
    return bad;
}
