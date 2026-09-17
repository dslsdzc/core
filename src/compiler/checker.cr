// === checker.core ===
// Two-pass name resolver + type checker for flat AST
// First pass: collect all function/struct/global declarations
// Second pass: type-check function bodies

// --- Type table ---
// Entries are 3 ints: kind, data, extra（24B/条——布局常量 ESZ_TYPE_ROW/OFF_TR_*
// 在 globals.cr 单源，R2 P4 Task 2 起与 TYPE 段序列化/dump 同源）

fn alloc_type(kind: int, data: int, extra: int) -> int {
    idx := g_type_count;
    grow_types(idx + 1);
    w64(g_types, idx * ESZ_TYPE_ROW + OFF_TR_KIND, kind);
    w64(g_types, idx * ESZ_TYPE_ROW + OFF_TR_DATA, data);
    w64(g_types, idx * ESZ_TYPE_ROW + OFF_TR_EXTRA, extra);
    g_type_count = idx + 1;
    return idx;
}

// ─── R2 P2a Task 1（F1）：同名 TYP_NAMED 建表去重 ───
// 背景（P1 影子对拍 9/9 差异的根因）：同一类型名在**每个出现点**都建一行——struct 字面量
// （:2206）、泛型应用的基型（:2191）等——于是同名多行。桥接层按行建原子（AK_NAMED 的 b 槽
// = 行号）→ 引擎把两行当互异命名类型 → 判不了（unknown）。裁决（用户）：根治 = 建表去重，
// 唯一分配点收敛到本函数（alloc_type 仍是裸分配器，语义不变）。
// 实读核对：全仓 TYP_NAMED 分配点恰 8 处（:406/:554/:598/:613/:622/:920/:2191/:2206），
// 实参恒 (TYP_NAMED, name_idx, 0) → 键 = name_idx（extra 恒 0，不入键）。读取点全部经
// get_type_data(ti) 取**名字**（:496 是解引用到名字的唯一入口），故按名字归一行不改读法。
// **比行号的面（去重的收益面）**：泛型应用的**基型行**（TYP_GENERIC_APPLY 的 data = base_ti）
// 与桥接项 AK_NAMED 的 b 槽（`sh_apply_identity_term` 的规范形 = 基型行）都按行比——去重把
// 「同名字不同出现点 ⇒ 不等」改成「同名 ⇒ 同 base 行，继续比实参」，这正是本条修复的目的
// （P1 差异的对偶面）。R2 P5 Task 4 后回落的 legacy 结构判等已删 ⇒ 该行号面**只剩**桥接项
// 的 b 槽（规范形，T3 起身份链按**名字令牌**比较，b 槽为标注）。
//
// 侧表 g_named_dedup（16B/条 {name_idx, ti}，开放寻址线性探测，与 ty_shadow.cr 的
// g_term_map（P5 T5 前名 g_shadow_map）同式同因）。P0/P1 血泪三件套缺一即可能挂死，逐条落：
//   ① 装填因子守卫（**探测前**）：(count + 1) * 2 >= cap → 重建扩容。表满且键不存在时
//      开放寻址永不落空 = 死循环；count 只增不减、恒等于占用槽数（兼作守卫判据）。
//   ② 重建 + **重放既有条目**：count 随重放重算（守卫读的就是它，不得沿用旧值）；重放
//      借道 named_dedup_probe（**不**经守卫）——否则重放自身可能再触发扩容 = 递归。
//   ③ 回写前重探：探测与回写之间若有插入/扩容，先前槽位即失效。本路径当前**不可达**
//      （alloc_type 不回入本函数、grow_types 不碰本表），保留 = 固化契约 + 与先例同形。
NAMED_DEDUP_INIT_CAP : int = 1024;

fn named_dedup_init() {
    if g_named_dedup_cap <= 0 {
        nc : ., mut = NAMED_DEDUP_INIT_CAP;
        nb := alloc(nc * 16);
        i : ., mut = 0;
        loop { if i >= nc { break; } w64(nb, i * 16, -1); i = i + 1; }
        g_named_dedup = nb;
        g_named_dedup_cap = nc;
        g_named_dedup_count = 0;
    }
}

// 类型表重置（行号空间作废）时侧表随之作废：cap=0 → 下次用惰性重建（空槽全 -1）。
// **可达且必需**（Task 1 评审纠错——原注「不可达防御」是错的）：`reset_frontend_state()`
// （globals.cr:332）清 `g_type_count` 却**不碰本侧表**，而 LSP 的 `lsp_check_file`
// （src/lsp/lsp.cr:168→172→187）**每请求**都走 `reset_frontend_state() → check_all()`
// 而 `check_all()` 首行即 `init_types()`（= 本重置）；且 `reset_frontend_state` 不清
// 字符串表（`g_str_count`/`g_str_hash` 零触及）→ 长驻进程内 `str_intern` 名字下标跨请求
// 稳定 ⇒ 陈旧 name→ti **必然命中**，返回的是**上一请求**的行号（此刻新表仅重建到基类型）
// → 越界/错行静默错型。删本重置 = 静默错型，不是可选防御。
fn named_dedup_reset() {
    g_named_dedup_cap = 0;
    g_named_dedup_count = 0;
}

// 无守卫探测（**只可在扩容守卫之后调用**；重建重放借道这里，不经守卫 = 防递归）：
// 命中 → 该键所在槽；未命中 → 空槽（**不插入**）。形态 = sh_map_find_nogrow（槽位变量
// `slot` + break + 尾 return；函数体不以无 break 的 loop 收尾——自托管 checker 对该形态
// 有 TF01 误报面）。
fn named_dedup_probe(name_idx: int) -> int {
    cap := g_named_dedup_cap;
    p : ., mut = tt_mod(name_idx, cap);
    slot : ., mut = -1;
    loop {
        k := r64(g_named_dedup, p * 16);
        if k < 0 { slot = p; break; }
        if k == name_idx { slot = p; break; }
        p = p + 1; if p >= cap { p = 0; }
    }
    return slot;
}

// 扩容 = 重建 + 重放既有条目（sh_map_rehash / 引擎 grow_tt_index 同式）；计数随重放重算。
fn named_dedup_rehash() {
    old := g_named_dedup;
    old_cap := g_named_dedup_cap;
    nc : ., mut = old_cap * 2;
    if nc < NAMED_DEDUP_INIT_CAP { nc = NAMED_DEDUP_INIT_CAP; }
    nb := alloc(nc * 16);
    i : ., mut = 0;
    loop { if i >= nc { break; } w64(nb, i * 16, -1); i = i + 1; }
    g_named_dedup = nb;
    g_named_dedup_cap = nc;
    g_named_dedup_count = 0;
    j : ., mut = 0;
    loop {
        if j >= old_cap { break; }
        k := r64(old, j * 16);
        if k >= 0 {
            s := named_dedup_probe(k);
            w64(g_named_dedup, s * 16, k);
            w64(g_named_dedup, s * 16 + 8, r64(old, j * 16 + 8));
            g_named_dedup_count = g_named_dedup_count + 1;
        }
        j = j + 1;
    }
}

// 槽位（含装填因子守卫 + 重建重放）：命中 → 该键所在槽；未命中 → 空槽（不插入）。
fn named_dedup_slot(name_idx: int) -> int {
    named_dedup_init();
    if (g_named_dedup_count + 1) * 2 >= g_named_dedup_cap { named_dedup_rehash(); }
    return named_dedup_probe(name_idx);
}

// 同名 TYP_NAMED 归一行（唯一分配点，8 处调用点见文件头注）：命中返回既有行，未命中
// 分配 + 登记。键域契约：name_idx >= 0（-1 = 空槽哨兵）——负键不进侧表（退化为裸分配），
// 否则「负键」与「空槽」同形会把空槽读成命中并返回**未初始化 value 槽**的任意 ti
// （`alloc` 是 bump 分配且不置零 → 不是特指某个固定值，而是任意值——静默错型）。
// 8 处实参均为名字下标（str_intern / si_name / ei_name / 类型节点的 ast_int_val）≥ 0，
// 该分支当前不可达 = 防御。
fn alloc_named_type(name_idx: int) -> int {
    if name_idx < 0 { return alloc_type(TYP_NAMED, name_idx, 0); }
    slot := named_dedup_slot(name_idx);
    if r64(g_named_dedup, slot * 16) == name_idx { return r64(g_named_dedup, slot * 16 + 8); }
    ti := alloc_type(TYP_NAMED, name_idx, 0);
    // 回写前重探（见文件头注③）
    slot2 := named_dedup_slot(name_idx);
    if r64(g_named_dedup, slot2 * 16) == name_idx {
        // 防御（当前不可达）：既有登记优先 → 本次刚分配的行成孤儿行（不写侧表、不计数）。
        // 反例写法（无条件写 slot2）会覆盖活跃条目 = 丢登记。
        return r64(g_named_dedup, slot2 * 16 + 8);
    }
    w64(g_named_dedup, slot2 * 16, name_idx);
    w64(g_named_dedup, slot2 * 16 + 8, ti);
    g_named_dedup_count = g_named_dedup_count + 1;
    return ti;
}

// 自测用（type_selftest.cr）：该名字当前在类型表里占的行数（恒 0/1；0 = 尚未分配）。
fn named_dedup_rows(name_idx: int) -> int {
    n : ., mut = 0;
    i : ., mut = 0;
    loop {
        if i >= g_type_count { break; }
        if get_type_kind(i) == TYP_NAMED && get_type_data(i) == name_idx { n = n + 1; }
        i = i + 1;
    }
    return n;
}

// ─── R2 P2a Task 3（C-4）：侧表 ↔ res_type_node **管线内断言**（`--verify-named-dedup`）───
// 背景（Task 1 交接必测项，评审裁决）：`f1.*` 用例是**人造夹具**（自测通道不经 check_all，
// 手工 alloc + 单名查行数）——它证明不了「8 个生产分配点全走侧表」：任一生产点若退回裸
// `alloc_type(TYP_NAMED, name, 0)`，自测照样全绿，而真实编译中该名字会**占两行**（读名字
// 的点仍对，比**行号**的点错——现存比行号面 = 泛型应用基型行 / 桥接项 AK_NAMED 的 b 槽）。
// 本函数把该性质升为**行为级证据**：跑在真实编译流水线（check_all 之后）上，三组断言
// 全部基于本编译期的真实类型表 / 符号表 / AST，不构造任何夹具：
//   ① 类型表 → 侧表：每个 TYP_NAMED 行按名查侧表必须**命中且回指本行**（唯一分配点 ⇒
//      每个 named 行都该有登记；回指不等 = 有生产点绕过侧表另建了同名行）；
//   ② 侧表 → 类型表 + 唯一性：每条登记必须指回 kind=TYP_NAMED 且名字相符的**合法行**，
//      且该名字在类型表里**恰 1 行**（去重不变量，全表而非抽样）；
//   ③ 读取面（替换弱断言 f1.row_count 的那条）：AST 中每个解析为**已注册命名类型**的
//      EXPR_IDENT 节点，`res_type_node(node)` 的返回值必须等于侧表命中 ti——覆盖
//      res_type_node 的两条出口（SYM_TYPE 注册行 / 惰性 alloc_named_type）。
// 只计不改：不动类型表/侧表/符号表，只读 + 计数。返回 = 不一致条数（0 = 全过）。
// 摘要行恒打印（本函数仅在 --verify-named-dedup 下被调用；默认路径零调用）。
// 性能注：③ 的 find_gsym 是符号表倒序线性扫描 → 语料越大越慢，仅调试通道（默认关）。
fn named_dedup_verify() -> int {
    bad : ., mut = 0;            // 不一致条数（返回）
    named_rows : ., mut = 0;     // 断言①覆盖的 TYP_NAMED 行数
    ident_checked : ., mut = 0;  // 断言③覆盖的类型名引用节点数
    // ① 类型表 → 侧表
    ti : ., mut = 0;
    loop {
        if ti >= g_type_count { break; }
        if get_type_kind(ti) == TYP_NAMED {
            named_rows = named_rows + 1;
            ni := get_type_data(ti);
            slot := named_dedup_slot(ni);
            if r64(g_named_dedup, slot * 16) != ni { bad = bad + 1; }
            else if r64(g_named_dedup, slot * 16 + 8) != ti { bad = bad + 1; }
        }
        ti = ti + 1;
    }
    // ② 侧表 → 类型表 + 唯一性
    e : ., mut = 0;
    loop {
        if e >= g_named_dedup_cap { break; }
        ni2 := r64(g_named_dedup, e * 16);
        if ni2 >= 0 {
            ti2 := r64(g_named_dedup, e * 16 + 8);
            if get_type_kind(ti2) != TYP_NAMED { bad = bad + 1; }
            else if get_type_data(ti2) != ni2 { bad = bad + 1; }
            if named_dedup_rows(ni2) != 1 { bad = bad + 1; }
        }
        e = e + 1;
    }
    // ③ 读取面：EXPR_IDENT（类型名引用）→ res_type_node 必须落回侧表同一行
    ai : ., mut = 0;
    loop {
        if ai >= g_ast_count { break; }
        if ast_kind(ai) == EXPR_IDENT {
            ni3 := ast_int_val(ai);
            si := find_gsym(ni3);
            if si >= 0 && sym_kind(si) == SYM_TYPE {
                sti := sym_type(si);
                // 泛型形参也 def_sym 为 SYM_TYPE，但其行 kind = TYP_GENERIC_PARAM（不经侧表）
                if get_type_kind(sti) == TYP_NAMED {
                    ident_checked = ident_checked + 1;
                    slot3 := named_dedup_slot(ni3);
                    if r64(g_named_dedup, slot3 * 16) != ni3 { bad = bad + 1; }
                    else if r64(g_named_dedup, slot3 * 16 + 8) != res_type_node(ai) { bad = bad + 1; }
                }
            }
        }
        ai = ai + 1;
    }
    print("[named-dedup] named_rows=");
    print(int_str(named_rows));
    print(" ident_checks=");
    print(int_str(ident_checked));
    print(" mismatches=");
    println(int_str(bad));
    return bad;
}

fn init_types() {
    g_type_count = 0;
    named_dedup_reset();   // 类型表重置 → 侧表随之作废（陈旧 name→ti 不得跨重置复用）
    // R2 P3 Task 5：约束诊断去重侧表同理作废（键含 AST 节点下标：跨编译期复用会漏报/误报）
    gen_constr_seen_reset();
    // R2 P2a Task 3 评审 Critical：桥接缓存（ti→term）**同理必须作废**——本批起判定路径无条件
    // 调 sh_term_of_ti，长驻进程（corelsp 每请求 init_types）复用行号时会命中陈旧 ti→term
    // ⇒ 两个不同类型被判等（静默漏报；评审实证见 ty_shadow.cr:sh_map_reset 注记）。
    sh_map_reset();
    // R2 P3 Task 0：展开层缓存（ti→展开项）**同理必须作废**（同因：行号空间复用 ⇒ 陈旧
    // ti→展开项命中 = 把上一请求的类型结构安到当前行上；同 sh_map_reset 的评审 Critical）。
    sh_unf_map_reset();
    // R2 P5 Task 4：判定回落计数（g_replace_*）随 legacy 一并删除——未知面改走 P-A 硬错
    // （ICE04，无跨请求累积语义：诊断在产生它的那次编译里即出）。
    // R2 P5 Task 2（D23）：单槽化建项失败位同生命周期（类型行号空间作废 ⇒ 该位只对本
    // 编译期有意义；LSP 每请求 init_types ⇒ 不跨请求累积）。
    g_tk_face_fail = 0;
    alloc_type(TYP_BASE, TY_INT, 0);     // TI_INT = 0
    alloc_type(TYP_BASE, TY_DEX, 0);   // TI_DEX = 1
    alloc_type(TYP_BASE, TY_BOOL, 0);    // TI_BOOL = 2
    alloc_type(TYP_BASE, TY_STRING, 0);  // TI_STR = 3
    alloc_type(TYP_BASE, TY_UNIT, 0);    // TI_UNIT = 4
    alloc_type(TYP_BASE, TY_NEVER, 0);   // TI_NEVER = 5
    alloc_type(TYP_BASE, TY_CHAR, 0);    // TI_CHAR = 6
    alloc_type(TYP_DYN, 0, 0);           // TI_DYN = 7
    // TI_DEX_S = 8 占位表项（终审 M1 修复）：TI_DEX_S 是 dex 定点精确形式（缩放整数）
    // 的 IR 变量类型哨兵，值恰为 8——曾与"首个动态分配类型下标"碰撞，@sizeOf/@alignOf/
    // is_ptr_var 的哨兵守卫对首个真实类型误触发。占住下标 8 后用户类型从 9 起，
    // 守卫永不再命中真实类型（TI_DEX_S 本身仍不查类型表，见 ir_gen.cr 注释）。
    alloc_type(TYP_BASE, TY_DEX_S, 0);   // TI_DEX_S = 8 占位
    // R2 P2b Task 1：本质条目表（iface_registry.cr）——静态数据（AK_*/TI_* 常量 + -1/0 +
    // R2 P4 Task 3 起的注册名 ni），不 alloc 类型行、不缓存本函数刚分配的行号 ⇒ 重复调用
    // 无副作用（长驻进程每请求一次）。
    // 位置 = 9 行原生 alloc 之后（表内容不依赖类型表，此处仅为「随类型表生命周期初始化」）。
    iface_registry_init();
    // R2 P4 Task 3（裁决 1 + D17）：六形状**名字生产注册面**（sequence/sequence_ro/
    // sequence_rw/indexable/iterable/product → sh_shape_*() 构造点）。无条件调用（幂等：
    // iface_shape_register 同名覆盖；reset_frontend_state 清 count 后由本行重建）——
    // 段内容 = 表本体（生产编译下恰 6 条）。详细边界见 iface_shape_builtin_init 注。
    iface_shape_builtin_init();
}

// ── Runtime builtin declarations (no .cr body, implemented in rt.s) ──
g_rt_builtin_count : int, mut;
g_rt_builtin_names : string, mut;
g_rt_builtin_ret_types : string, mut;

fn init_builtins() {
    g_rt_builtin_count = 0; g_rt_builtin_names = alloc(8 * 8); g_rt_builtin_ret_types = alloc(8 * 8);

    bi_add("load8", TI_INT);
    bi_add("store8", TI_INT);
    bi_add("load64", TI_INT);
    bi_add("r64", TI_INT);
    bi_add("alloc", TI_STR);
    bi_add("get_arg", TI_STR);
    bi_add("w32", TI_UNIT);
    bi_add("w64", TI_UNIT);
    bi_add("_dyncpy", TI_UNIT);
    bi_add("load_str_ptr", TI_STR);
    bi_add("store_str_ptr", TI_INT);
    bi_add("sched_call_0", TI_INT);
    bi_add("sched_call_1", TI_INT);
    bi_add("sched_call_2", TI_INT);
    bi_add("sched_call_3", TI_INT);
    bi_add("sched_call_4", TI_INT);
    bi_add("fiber_switch", TI_INT);
    bi_add("fiber_init", TI_INT);
    bi_add("sched_go", TI_INT);
    bi_add("m_start_workers", TI_UNIT);
    bi_add("g_set_curg", TI_UNIT);
    bi_add("g_get_curg", TI_INT);
}

fn bi_add(name: string, ret_ti: int) {
    ni := str_intern(name);
    if g_rt_builtin_count * 8 + 8 > str_len(g_rt_builtin_names) {
        nc := g_rt_builtin_count * 2 + 16;
        nb := alloc(nc * 8); _dyncpy(g_rt_builtin_names, g_rt_builtin_count * 8, nb);
        g_rt_builtin_names = nb;
    }
    if g_rt_builtin_count * 8 + 8 > str_len(g_rt_builtin_ret_types) {
        nc := g_rt_builtin_count * 2 + 16;
        nb := alloc(nc * 8); _dyncpy(g_rt_builtin_ret_types, g_rt_builtin_count * 8, nb);
        g_rt_builtin_ret_types = nb;
    }
    w64(g_rt_builtin_names, g_rt_builtin_count * 8, ni);
    w64(g_rt_builtin_ret_types, g_rt_builtin_count * 8, ret_ti);
    g_rt_builtin_count = g_rt_builtin_count + 1;
}

fn get_type_kind(ti: int) -> int {
    if ti >= 0 && ti < g_type_count { return r64(g_types, ti * 24); }
    return -1;
}

fn get_type_data(ti: int) -> int {
    if ti >= 0 && ti < g_type_count { return r64(g_types, ti * 24 + 8); }
    return 0;
}

fn get_type_extra(ti: int) -> int {
    if ti >= 0 && ti < g_type_count { return r64(g_types, ti * 24 + 16); }
    return 0;
}

// ─── R2 P2a Task 2（F2）：常量档数组长度约束 ───
// 背景（P1 findings §6.F2）：身份判等（当时的 type_equal 结构判等，R2 P5 Task 4 已删）曾把 N
// 与元素判等绑在一起 = N 属**类型身份**；而桥接按 R1 裁决 **N 不入身份**（AK_SEQUENCE 参数链
// 只含元素项）→ 判定替换（Task 3：引擎 ty_equiv）后 `[int;4]` → `[int;3]` 会**静默通过**
// （现状是编译错误 error[TF01]）。用户裁决：落「常量档长度约束」——保持现状拒绝语义，不留
// 静默缺口。本函数即该约束：N 从身份中**迁出**，成为具名、可独立调用/独立测试的检查
// （身份分支不再比 N）。
//
// 语义（本批 = 常量档：N 皆字面量 → 编译期定 恒真/恒假）：
//   沿两类型的**结构对应位置**下钻（下钻位置 = 结构判等（已删）的**递归位**：数组元素 /
//   指针元素 / 引用元素 / 切片元素 / 元组字段 / 泛型应用实参），在**数组位置**比较 N（extra）
//   ——N 必须相等；不等即 0（违反）。其余情形（异 kind / 异元数 / 非数组构造子）长度面无约束
//   → 1（满足）。**1 = 满足；0 = 违反**。
//   ⚠「同形」仅指**递归位覆盖**（下钻走得到的位），**不**指比较项相同——各构造子另有非长度
//   面，且**一律归身份判定（引擎）**，本约束有意不重复（只认 N = TYP_ARRAY 的 extra 一个维度）：
//     · REF —— 身份含 `extra`（mut 标记；桥接链 [mut 标记项, 元素项]，见 ty_shadow.cr
//       `sh_ref_mut_marker`），本函数不重复；
//     · TUPLE / GENERIC_APPLY —— 身份另比元数、APPLY 另比基型行号（规范形），同上；
//     · 反向不对称 —— PTR 的 `extra`（地址空间位 asp，`infer_expr` 的指针升格分配点）身份
//       **亦不比**（现状如此，非本任务面），本函数同样不引入该比较。
//   故切勿据「同形」推断两者判等项一致（评审 M1 收口）。
// 为何必须下钻：N 迁出身份后，嵌在非数组构造子内部的位置（`[[int;3];2]` 的数组元素位 /
//   `G<[int;3]>` 的泛型实参位 / `*[int;3]` 的指针元素位 / `(int, [int;3])` 的元组字段位）
//   不再有任何判等负责——不下钻即静默放宽（收紧面的反面）。覆盖面由 type_selftest.cr 的
//   f2.* 用例逐位钉住（同结构同长 → 1 / 同结构异长 → 0 双断）。
// 边界（如实登记）：**符号档未实现**（VC 义务 = 验证管线消费，本计划显式不做）；**动态档 =
//   运行期检查**（F11 侧表 + IR_BOUNDS_CHECK，R1 已落）⇒ 编译期**不放行**视图→固定（长度
//   不可证，见下「方向规则」）；异形不下钻（该面由身份判定的 kind/参数结构比较负责，本函数
//   不越权给 0 = 不误拒）。
// 无环：TYP_NAMED / TYP_GENERIC_PARAM / TYP_BASE / TYP_DYN 不下钻 → 深度 = 类型嵌套深度。
//
// ─── R2 P3 Task 1：方向规则（定长退役收口）───
// 语义（spec §5.1）：`[T;N] <: [T]`（更强长度约束 = 子类型）；`[T] ⊄ [T;N]`（除非证 len==N）。
// **参序约定 =（源/实参 a，目标/形参 b）**：a 的长度约束须不弱于 b 的。规则：
//   · 源 = TYP_SLICE（视图）且 目标 = TYP_ARRAY（固定）⇒ **0**（切片运行期长度不可证；
//     动态档交给运行期检查 ⇒ 编译期拒绝——**不给 -1 当 0**，「无法证」= 不放行）；
//   · 源 = TYP_ARRAY 且 目标 = TYP_SLICE ⇒ 1（拓宽，pB/pAsgnSlice 语义保持）；
//   · 其余跨 kind ⇒ 1（长度面无约束——身份判定负责，现状不变；负控 f2.nonarray_no_constraint）。
// ⚠ 参序敏感 ⇒ 10 个判定点的实参序在本批**归一为（源，目标）**（P2a 落点时各站参序随原
//   `type_equal` 调用继承、未归一：站点 5 本即（值, 声明），站点 6/8/9/10 与 unify 三处为
//   （目标, 源）⇒ 换序）。**换序对既有语义零影响**的证明面：身份面 type_equal 与长度面
//   同 kind 的 N 比较**两面皆对称**（ty_equiv 双向 / extra 相等），逐站复验见 p3-task1 报告；
//   hotpatch 站（1，两侧皆声明、无源/目标）改用 `type_compat_sym`（对称核 = 现状语义）。
// **方向只在「宽度不匹配」的固定性维上生效**——同 kind 面（含两个数组比 N）逐位保持 P2a 语义。
fn array_len_walk(ti_a: int, ti_b: int, dir: int) -> int {
    ka := get_type_kind(ti_a);
    kb := get_type_kind(ti_b);
    if ka != kb {
        if dir == 1 { if ka == TYP_SLICE && kb == TYP_ARRAY { return 0; } }   // 视图→固定：不给放行
        return 1;
    }
    if ka == TYP_ARRAY {
        if get_type_extra(ti_a) != get_type_extra(ti_b) { return 0; }
        return array_len_walk(get_type_data(ti_a), get_type_data(ti_b), dir);
    }
    if ka == TYP_PTR || ka == TYP_REF || ka == TYP_SLICE {
        return array_len_walk(get_type_data(ti_a), get_type_data(ti_b), dir);
    }
    if ka == TYP_TUPLE {
        fc := get_type_data(ti_a);
        if fc != get_type_data(ti_b) { return 1; }      // 字段数不同：身份判定负责
        fs1 := get_type_extra(ti_a);
        fs2 := get_type_extra(ti_b);
        fi : ., mut = 0;
        loop {
            if fi >= fc { break; }
            if array_len_walk(r64(g_gen_apply_data, (fs1 + fi) * 8), r64(g_gen_apply_data, (fs2 + fi) * 8), dir) == 0 { return 0; }
            fi = fi + 1;
        }
        return 1;
    }
    if ka == TYP_GENERIC_APPLY {
        if get_type_data(ti_a) != get_type_data(ti_b) { return 1; }   // 基型不同：身份判定负责
        as1 := get_type_extra(ti_a);
        as2 := get_type_extra(ti_b);
        ac1 := r64(g_gen_apply_data, as1 * 8);
        ac2 := r64(g_gen_apply_data, as2 * 8);
        if ac1 != ac2 { return 1; }                     // 实参数不同：身份判定负责
        ai : ., mut = 0;
        loop {
            if ai >= ac1 { break; }
            if array_len_walk(r64(g_gen_apply_data, (as1 + 1 + ai) * 8), r64(g_gen_apply_data, (as2 + 1 + ai) * 8), dir) == 0 { return 0; }
            ai = ai + 1;
        }
        return 1;
    }
    return 1;
}

// 方向面（有源/目标语义的站点）：见上「参序约定」注记。
fn array_len_constraint_ok(ti_a: int, ti_b: int) -> int {
    return array_len_walk(ti_a, ti_b, 1);
}

// 对称核（无方向的站点：hotpatch 一致性——两侧皆声明）：= R2 P2a Task 2 原语义逐字
// （跨 kind 一律无约束）。保留为独立入口的理由 = 「无源/目标」不是「源/目标之一」的退化，
// 用方向版会退化成**任一路由参序决定的任意判**（同一声明对换个声明序即改判）。
fn array_len_constraint_sym(ti_a: int, ti_b: int) -> int {
    return array_len_walk(ti_a, ti_b, 0);
}

// F2 判定点组合（**站点**用）：身份判等 ∧ 常量档长度约束 ∧（Task 1）方向规则。
// N 不入身份（R1 裁决）⇒ 判定点必须在 type_equal 之外显式补检——否则 Task 3 替换身份实现后
// N/固定性不匹配静默通过。返回：1 = 兼容；0 = 身份不匹配（原诊断措辞）；-1 = 长度/方向约束
// 违反（专属措辞；**码不变**——TF01/TA01/TC02 的「门」= 拒绝集合不变，仅成因分列）。
// **总是调用 type_equal**（判定入口单点）：判定点**一律**经此组合函数，不得就地内联等价比较
// ——否则判定面旁路（历史依据：影子对拍期站点调用次数/位置必须可比，P1 登记；影子通道已随
// P5 Task 5 下线，本条 = 判定面单点纪律的继承）。
// 参序 =（源，目标）——见 array_len_walk 上方的归一说明。
fn type_compat_strict(ti_a: int, ti_b: int) -> int {
    if !type_equal(ti_a, ti_b) {
        // ─── R2 P3 Task 4：**可选目标的子类型注入**（`T ⊆ T?`、`null ⊆ T?`）───
        // 语义（spec §5.4）：`T?` = `T ∪ null` ⇒ 裸 T 值与 None 值**本来就该**流进 T? 的槽
        // （返回位/赋值位/实参位/字段位…同一组合函数）。而行面判定是**身份**口径
        // （type_equal = 等价），等价不含 `int ⊆ int ∪ null` ⇒ 不注入则 `fn g() -> int? { return 5; }`
        // 被拒（实测 TF01），「联合类型」在行为面等于没落地。
        // 收窄面（为何不是「站点改子类型」）：注入**只在目标行 kind == TYP_OPTIONAL 时**触发
        // —— 该 kind 只由 `T?` 产生，语料零命中（全仓无 `T?`），故既有接受/拒绝集合**逐点不变**；
        // 站点面（type_equal 采样、长度档、措辞分派）与 P2a/P2b 判据**零改动**。反方向
        // （`T?` 值进 `T` 槽）不注入：引擎 ty_sub(union, T) = 0 ⇒ 照旧拒绝（soundness 面）。
        // 三态纪律：引擎 0/-1（不含/未知）一律**不放行**（未知不得当放宽）。
        if get_type_kind(ti_b) == TYP_OPTIONAL {
            if ti_subsumes(ti_a, ti_b) == 1 { return 1; }
        }
        return 0;
    }
    if array_len_constraint_ok(ti_a, ti_b) == 0 { return -1; }
    return 1;
}

// R2 P3 Task 4：ti 级包含判定（源 ⊆ 目标）——桥接 + 引擎 `ty_sub` 三态，**仅 1 放行**
// （0 = 确定不含、-1 = 未知 ⇒ 都回 0：本入口只服务「放松注入」，未知绝不当放宽 = 三态纪律）。
// 预算前后隔离照 type_equal_engine 的窗口纪律（引擎 memo 跨查询命中会让结果依赖预算历史）；
// 不触碰 `g_replace_*` 计数（那两个计数是 type_equal 替换面的台账，本入口不属该面）。
fn ti_subsumes(src_ti: int, tgt_ti: int) -> int {
    a := sh_term_of_ti(src_ti);
    b := sh_term_of_ti(tgt_ti);
    if a < 0 || b < 0 { return 0; }
    ty_budget_reset(200000);
    s := ty_sub(a, b);
    ty_budget_reset(200000);
    if s == 1 { return 1; }
    return 0;
}

// 无方向站点的组合（与 type_compat_strict 同构，仅长度面走对称核）：hotpatch 站（1）用。
fn type_compat_sym(ti_a: int, ti_b: int) -> int {
    if !type_equal(ti_a, ti_b) { return 0; }
    if array_len_constraint_sym(ti_a, ti_b) == 0 { return -1; }
    return 1;
}

// F2 判定点诊断：verdict ≠ 1 时发码——-1（长度约束违反）用专属措辞，0 用原措辞。
fn diag_type_incompatible(verdict: int, code: int, what: string, line: int, col: int) {
    if verdict == -1 {
        check_error(code, "Array length constraint not satisfied", line, col);
    } else {
        check_error(code, what, line, col);
    }
}

// ─── R2 P5 Task 6（TODO #2026-09-11-14）：声明位点的值/注解兼容判定 ───
// 背景：`EXPR_LET` 站点自 P3 Task 1 实测起为**无任何兼容检查**的洞（`checker.cr` 该分支
// 只登记符号，ti = 注解行 ⇒ 后端按注解行发射 = 静默错产物）。实测（旧/新二进制同值）：
// `x : int = "s"` / `x : [int;3] = s`（切片）/ `x : [int;4] = [1,2,3]`（异长常量档）/
// `x : int? = 5; y : int = x`（可选流进窄槽）全部 check rc=0 零诊断。
// 判定 = `type_compat_strict`（身份 + 长度档 + 可选目标注入），照赋值位点（EXPR_ASSIGN）
// 与返回位点（TF01）同款组合函数；参序归一（P3 T1 §3.1）=（源 = 初始化值, 目标 = 注解行）。
// 两个调用点共用本函数：① `infer_expr` 的 `EXPR_LET` 分支（局部）；② `check_global_let`
// （全局初始化器——同形缺口，一并在 #2026-09-11-14 划界内收口）。
// 豁免（逐条对齐邻站，各附理由；无豁免即无判定）：
//   ① 无注解 / `: .` / `: auto`（type_node < 0）或无初值（val_node < 0）⇒ 无契约可核；
//   ② 注解 = `dyn` ⇒ 不判（dyn 槽按值追踪；照赋值位点 `tt == TI_DYN` 分支与本站下行
//      `dyn_set_type` 语义——注解 dyn 时值的类型**就是**该槽的合法类型集）；
//   ③ 值 = `never`（TI_NEVER）⇒ 不判——两义：**底部**（发散值，照返回位点
//      `body_ti != TI_NEVER` 豁免同路）+ 表达式层 TI_NEVER 的**错误标记**义（未定义名/
//      未定义函数等错误路径的返回值，见 EXPR_IDENT/EXPR_CALL 的 `return TI_NEVER`）——
//      后者是**诊断级联抑制**（实测 r1/r3 探针：只发一条 N01/N06，无二次 TA02）。
//      实测登记：`-> never` 函数的**调用**被推断为 unit（非 never）⇒ `x : int = boom()`
//      新增 TA02——与邻站现状一致（`return boom()` 今天即报 TF01，探针 q15），非本检查
//      新引入的类；全语料零 `-> never`（src/tests/examples 皆无）⇒ 零命中。
//   ④ 注解 kind == `TYP_GENERIC_PARAM` ⇒ 不判（声明期不可验证；照返回位点
//      `get_type_kind(ret_ti) != TYP_GENERIC_PARAM` 豁免）。
// 三态纪律：本函数只消费 `type_compat_strict` 的 {1,0,-1}；不可判（引擎 -1 / 桥接缺口）由
//   `type_equal` 内部按 P-A 发 ICE04（硬错），**不**在本函数内回落或近似。
fn check_let_annot_compat(node: int, val_node: int, val_ti: int, ti: int) {
    type_node := ast_b(node);                          // EXPR_LET: b = 注解类型节点（-1 = 无）
    if type_node < 0 || val_node < 0 { return; }
    if ti == TI_DYN { return; }
    if val_ti == TI_NEVER { return; }
    if get_type_kind(ti) == TYP_GENERIC_PARAM { return; }
    compat := type_compat_strict(val_ti, ti);
    if compat != 1 {
        diag_type_incompatible(compat, EC_TA_DECL, "Variable declared as " + type_display(ti) + ", got " + type_display(val_ti), ast_line(node), ast_col(node));
    }
}

// R2 P1：本文件曾同时有**结构判等实现**（原名 type_equal）与引擎判定两套。
// R2 P2a Task 3：结构判等降级为 `type_equal_legacy`（影子对拍对照物 + 引擎 -1 的回落实现）。
// **R2 P5 Task 4 删除**（本处）：断言前提 = 清零判据成立（全语料 72 档 `decisions=agree=32988`、
//   `replace_bridge=replace_unknown=0`；残留 -1 面由 Task 3 命名面判定化 + Task 3b 不变槽元素
//   三态收口，探针 `unknown_engine=0`）——D24 顺序：清零 → 删 legacy → 影子层下线（T5 已完成，
//   影子通道整体删除；判定面回归网 = 冻结基线同源对拍 + 行为探针 + 突变控制，见 TODO 与
//   src/ci/run.sh 的自述）。
// 删除件与替代证据（D26）见 p5-task4-report §判据；P-A 政策见 `type_equal_engine` 头注。

// P-A（Task 4 Step 1 推荐案，落纸）：判定不可判 = **硬错 ICE04**（三态纪律：未知不得当 0/1，
// 也**不得**回落/近似）。两个出口：
//   ① 桥接缺口（sh_term_of_ti 返回 -1 = 该行译不成类型项——行越界/桥接未覆盖）；
//   ② 引擎三态 -1（预算耗尽 / 未覆盖面：μ/¬/⊤ₖ 等，见 Task 0 表 D 清点）。
// 诊断面：新码 ICE04（main.cr 硬名单 ⇒ build 亦拒绝）+ 反例（两侧类型项文本，D23 先例）。
// 判定点（type_equal 无 AST 位置）⇒ line/col = 0；定位由调用点自身的诊断（TA01/TF01…）承担。
// 全语料零命中（report-only 先行，由 Task 3 的 0 计数支撑）⇒ 零行为变化。
fn ty_indeterminate_report(kind: int, t1: int, t2: int, a: int, b: int, unc: int, exh: int) {
    msg : ., mut = "";
    if kind == 0 {
        msg = "type judgment indeterminate: no type term for type row " + int_str(t1) + " / " + int_str(t2) + " (bridge gap)";
    } else {
        cause : ., mut = "uncovered face";
        if unc == 0 && exh != 0 { cause = "budget exhausted"; }
        msg = "type judgment indeterminate: " + tt_display(a) + " vs " + tt_display(b) + " (" + cause + ")";
    }
    check_error(EC_ICE_TY_INDET, msg, 0, 0);
}

// ─── R2 P2a Task 3 / R2 P5 Task 4：判定 = 引擎唯一权威 ───
// 判定主体（P1 的包装层拆两半：本函数 = 引擎判定，`type_equal` = 入口转发）。
//   ① 同一行快路径：t1 == t2 → true（含负 ti 情形；快路径不改任何判定结果，只省一次桥接
//      + 引擎查询）；
//   ② 桥接（sh_term_of_ti）：任一侧译不成类型项（-1）⇒ **P-A 硬错**（ICE04 + 桥接缺口措辞）
//      —— 判定不可进行 = 未知；旧行为（Task 4 前）= 回落 legacy + g_replace_bridge（已删）；
//   ③ 引擎三态：1 → true；**0 → false（引擎结论即权威）**；-1（未知：预算耗尽/未覆盖面）⇒
//      **P-A 硬错**（ICE04 + 成因 + 反例）——旧行为 = 回落 legacy + g_replace_unknown（已删）；
//   ④ 预算隔离：判定前后各 ty_budget_reset(200000)——引擎 memo 跨查询命中会让结果依赖预算
//      历史而非输入项（P0 终审 Critical 3 实证）；判定路径不得受前次查询影响。
// 返回 false 是「未知」在 bool 面上唯一的保守出口（fail-closed：不因未知放宽），
//   **不等价于**「确定不等价」——后者由 ICE04 与实际 0 区分（诊断只在未知时发）。
// N 面（Task 2/3 评审裁决「N 不得回身份」）：本函数路径**不含** N 比较——桥接的 AK_SEQUENCE
// 参数链只含元素项；长度拒绝一律由 array_len_constraint_ok 在判定点（type_compat_strict）
// 承担。本函数**不得**引入任何 N（get_type_extra 的数组位）比较。
fn type_equal_engine(t1: int, t2: int) -> bool {
    if t1 == t2 { return true; }                       // 快路径：同一行
    a := sh_term_of_ti(t1);
    b := sh_term_of_ti(t2);
    if a < 0 || b < 0 {
        ty_indeterminate_report(0, t1, t2, a, b, 0, 0);
        return false;
    }
    ty_budget_reset(200000);
    e := ty_equiv(a, b);
    // 成因位须在**第二次 reset 之前**读（ty_budget_reset 清 g_ty_uncovered/g_ty_exhausted）
    unc := ty_uncovered();
    exh := ty_exhausted();
    ty_budget_reset(200000);                           // 判定后即复位（不污染后续查询）
    if e == 1 { return true; }
    if e == 0 { return false; }
    // e == -1（未知）：P-A —— 不静默、不回落：硬错 + 反例
    ty_indeterminate_report(1, t1, t2, a, b, unc, exh);
    return false;
}

// R2 P1 影子对拍包装 / R2 P2a Task 3 判定入口 → R2 P5 Task 4 纯转发（对照物删除）。
// **R2 P5 Task 5**：影子通道整体下线（`sh_compare` 及其调用点、ring/摘要/站点直方图/CLI 通道、
// `g_shadow_*` 全部删除）。保留本名与转发形态 = 判定入口单点（调用面零改动；站点/计数面无残留）。
fn type_equal(t1: int, t2: int) -> bool {
    return type_equal_engine(t1, t2);
}

fn scan_for_yield(node: int) -> int {
    if node < 0 { return 0; }
    k := ast_kind(node);
    if k == EXPR_YIELD { return 1; }
    if k == EXPR_BLOCK {
        ss := ast_a(node); sc := ast_b(node);
        i : ., mut = 0;
        loop { if i >= sc { break; }
            sn := r64(g_block_stmts, (ss + i) * 8);
            if scan_for_yield(sn) != 0 { return 1; }
            i = i + 1; }
        return 0; }
    if k == EXPR_LOOP || k == EXPR_WHILE {
        return scan_for_yield(ast_a(node)); }
    if k == EXPR_IF {
        if scan_for_yield(ast_a(node)) != 0 { return 1; }
        if scan_for_yield(ast_b(node)) != 0 { return 1; }
        if ast_c(node) >= 0 && scan_for_yield(ast_c(node)) != 0 { return 1; }
        return 0; }
    if k == EXPR_FOR { return scan_for_yield(ast_c(node)); }
    return 0;
}

// ─── 落空（fall through）分析 —— TF01 收口 ───
// 背景：函数体返回检查（站点 5）以「块类型 = 末语句类型」判返回；以**无 break 的 loop**
// 收尾的体运行时永不走到函数尾（只能从体内 return 出），其「unit」不是缺返回值的证据
// ⇒ 历史误报一例 `ty_memo_slot_no_grow`（ty_shadow.cr 记载面）。判定**保守**：只认确定
// 不能落空的形态，其余一律回 0（= 可落空 = 照旧判 TF01）——真落空体绝不能溜过
// （那是静默接受洞，比误报危险得多）。

// 循环体内是否存在**直属于本循环**的 break（嵌套 loop/while/for 内的 break 归内层 ⇒
// 在循环节点处截断、不下钻）。返回 1 亦覆盖「形态未知」（默认兜底）——未知按「可能有
// break」处理 = fail-closed：宁可照旧报 TF01，也不误判「无 break ⇒ 永不落空」。
fn loop_body_has_break(node: int) -> int {
    if node < 0 { return 0; }
    k := ast_kind(node);
    if k == EXPR_BREAK { return 1; }
    if k == EXPR_LOOP || k == EXPR_WHILE || k == EXPR_FOR { return 0; }
    if k == EXPR_BLOCK {
        ss := ast_a(node); sc := ast_b(node);
        i : ., mut = 0;
        loop { if i >= sc { break; }
            if loop_body_has_break(r64(g_block_stmts, (ss + i) * 8)) != 0 { return 1; }
            i = i + 1; }
        return 0;
    }
    if k == EXPR_IF {
        if loop_body_has_break(ast_a(node)) != 0 { return 1; }
        if loop_body_has_break(ast_b(node)) != 0 { return 1; }
        return loop_body_has_break(ast_c(node));
    }
    if k == EXPR_MATCH {
        // 臂 = EXPR_ARM 链（parser 以 arm.c 串联，尾 -1）——**非连续槽**，勿按段扫
        if loop_body_has_break(ast_a(node)) != 0 { return 1; }
        an : ., mut = ast_b(node);
        loop { if an < 0 { break; }
            if loop_body_has_break(ast_b(an)) != 0 { return 1; }
            an = ast_c(an); }
        return 0;
    }
    if k == EXPR_ARM || k == EXPR_BINARY || k == EXPR_ASSIGN || k == EXPR_INDEX ||
       k == EXPR_RANGE || k == EXPR_AS || k == EXPR_ARG || k == EXPR_CALL {
        if loop_body_has_break(ast_a(node)) != 0 { return 1; }
        return loop_body_has_break(ast_b(node));
    }
    if k == EXPR_ENUM_CONSTRUCTOR || k == EXPR_AT {
        // a = 名 ni（**不是节点**）：只下钻实参链（b）
        return loop_body_has_break(ast_b(node));
    }
    if k == EXPR_GO {
        // a 恒 -1、体在 b（range 形态另有 c/data）；a/b 双下钻 = 保守（go 体内 break 不漏判）
        if loop_body_has_break(ast_a(node)) != 0 { return 1; }
        return loop_body_has_break(ast_b(node));
    }
    if k == EXPR_LET {
        // a = 名 ni（**不是节点**）：只下钻类型（b）与值（c）
        if loop_body_has_break(ast_b(node)) != 0 { return 1; }
        return loop_body_has_break(ast_c(node));
    }
    if k == EXPR_STRUCT || k == EXPR_STRUCTPAT || k == EXPR_ENUMPAT || k == EXPR_GENERIC_APPLY {
        // 连续子节点段：首 b、个数 c（wrapper.a = 值/子模式，经 EXPR_NONE 分支承接）
        return seg_has_break(ast_b(node), ast_c(node));
    }
    if k == EXPR_ARRAY || k == EXPR_TUPLE {
        return seg_has_break(ast_a(node), ast_b(node));
    }
    if k == EXPR_NONE {
        // wrapper（a = 值节点）或基类型节点（a = 0）：照 monomorph 的判据
        if ast_a(node) >= 0 && ast_a(node) != node { return loop_body_has_break(ast_a(node)); }
        return 0;
    }
    if k == EXPR_STMT || k == EXPR_UNSAFE || k == EXPR_RETURN || k == EXPR_YIELD ||
       k == EXPR_AWAIT || k == EXPR_MOVE || k == EXPR_TRY || k == EXPR_UNARY ||
       k == EXPR_FIELD || k == EXPR_OPTIONAL || k == EXPR_REFTYPE || k == EXPR_PTRTYPE {
        return loop_body_has_break(ast_a(node));
    }
    if k == EXPR_INT || k == EXPR_DEX || k == EXPR_BOOL || k == EXPR_STRING ||
       k == EXPR_IDENT || k == EXPR_CHAR || k == EXPR_WILDCARD || k == EXPR_CONTINUE {
        return 0;
    }
    // 兜底（含 EXPR_FN/PARAM/FLOW/EXTERN 等未枚举形态）：按「可能有 break」保守处理
    return 1;
}

fn seg_has_break(first: int, count: int) -> int {
    if first < 0 { return 0; }
    i : ., mut = 0;
    loop { if i >= count { break; }
        n := first + i;
        if n >= 0 && n < g_ast_count {
            if loop_body_has_break(n) != 0 { return 1; }
        }
        i = i + 1; }
    return 0;
}

// 语句是否**不能落空**（走到本语句之后的代码）：1 = 确定不能，0 = 可能落空（保守默认）。
// 注意 `return` 在此**不判 divergence**：它虽然「不能走完」，但**带返回值**——本分析只服务
// 「块末语句类型是否代表函数返回值」这一问，而 return 的值类型恰是该问的被检对象（豁免它
// = 洗白真错面，lits_copy 型）。故只认**不产出值**的不可落空形态：无直系 break 的 loop、
// 双分支皆不可落空且无 else 的 if、包裹层（STMT/UNSAFE/嵌套 block）。
// **登记面**：非落空体内的 return 值类型本分析**不核对**（checker 现模型无逐 return 核对；
// 该面 = 既有面——本条只把「以无 break 的 loop 收尾」从 TF01 误报中解放，不新增核对）。
fn stmt_cannot_fall_through(node: int) -> int {
    if node < 0 { return 0; }
    k := ast_kind(node);
    if k == EXPR_BLOCK {
        ss := ast_a(node); sc := ast_b(node);
        i : ., mut = 0;
        loop { if i >= sc { break; }
            if stmt_cannot_fall_through(r64(g_block_stmts, (ss + i) * 8)) != 0 { return 1; }
            i = i + 1; }
        return 0;
    }
    if k == EXPR_LOOP {
        // 无直系 break ⇒ 只可能从体内 return 出（loop_body_has_break 的未知 = 1 保证
        // 此处判 1 只在**确定**无 break 时成立）
        if loop_body_has_break(ast_a(node)) == 0 { return 1; }
        return 0;
    }
    if k == EXPR_IF {
        if ast_c(node) < 0 { return 0; }   // 无 else：条件不成立即落空
        if stmt_cannot_fall_through(ast_b(node)) == 0 { return 0; }
        return stmt_cannot_fall_through(ast_c(node));
    }
    if k == EXPR_STMT || k == EXPR_UNSAFE { return stmt_cannot_fall_through(ast_a(node)); }
    return 0;
}

// 语句是否**确定发散**（本层不产出值、不落到后继）——**含 `return`**。
// **仅服务 TC02 的「else 支类型是幻影」判定**（消费点 = infer_expr 的 EXPR_IF 合并点守卫）；
// **不得**用于 TF01——那里豁免 return 体会洗白真错面（lits_copy 型），见上一条的头注。
// 保守默认 0（不确定即 0）：只认 return 族 + 包裹层（STMT/UNSAFE）+ 块内任一句确定发散。
// 未覆盖面（登记，本批不判）：`break`/`continue` 收尾的分支（需循环上下文）。
fn stmt_diverges(node: int) -> int {
    if node < 0 { return 0; }
    k := ast_kind(node);
    if k == EXPR_RETURN { return 1; }
    if k == EXPR_STMT || k == EXPR_UNSAFE { return stmt_diverges(ast_a(node)); }
    if k == EXPR_BLOCK {
        ss := ast_a(node); sc := ast_b(node);
        i : ., mut = 0;
        loop { if i >= sc { break; }
            if stmt_diverges(r64(g_block_stmts, (ss + i) * 8)) != 0 { return 1; }
            i = i + 1; }
        return 0;
    }
    return 0;
}

// --- Symbol table ---
struct SymEntry {
    name_idx: int,
    kind: int,
    type_idx: int,
    node_idx: int,
}

fn push_scope() {
    grow_scope_bounds(g_scope_depth + 1);
    w64(g_scope_bounds, g_scope_depth * 8, g_sym_count);
    g_scope_depth = g_scope_depth + 1;
}

fn pop_scope() {
    if g_scope_depth > 0 {
        g_scope_depth = g_scope_depth - 1;
        g_sym_count = r64(g_scope_bounds, g_scope_depth * 8);
    }
}

fn def_sym(name_idx: int, kind: int, type_idx: int, node_idx: int) {
    grow_syms(g_sym_count + 1);
    sym_set_name(g_sym_count, name_idx);
    sym_set_kind(g_sym_count, kind);
    sym_set_type(g_sym_count, type_idx);
    sym_set_node(g_sym_count, node_idx);
    g_sym_count = g_sym_count + 1;
}

fn find_sym(name_idx: int) -> int {
    i : ., mut = g_sym_count - 1;
    loop {
        if i < 0 { return -1; }
        if sym_name(i) == name_idx { return i; }
        i = i - 1;
    }
    return -1;
}

fn find_gsym(name_idx: int) -> int {
    i : ., mut = g_sym_count - 1;
    loop {
        if i < 0 { break; }   // 主表未命中 ⇒ 落到下方侧表回退
        if sym_name(i) == name_idx && sym_kind(i) >= SYM_FN && sym_kind(i) <= SYM_SO_FN { return i; }
        i = i - 1;
    }
    // 侧表回退（第 4 批 #82/#83）：索引元数据只在名字**被引用**（走到这里）且主表**没有**
    // 同名条目时才物化 ⇒ 未引用条目零产物足迹；且同名 `.cr` 声明优先（裁-HR-2：
    // 宿主家目录里的文件**不得**悄悄改写用户源码声明的含义）。
    // **查不到时做了什么**：主表无 + 侧表无 ⇒ 返回 -1，由调用点报 Undefined（响亮）。
    // **绝不**在此放行——那是「响亮失败 → 静默错值」的退化（本批红线）。
    ssi := find_so_side(name_idx);
    if ssi < 0 { return -1; }
    return so_materialize(ssi);
}

fn find_so_fn(name_idx: int) -> int {
    i : ., mut = 0;
    loop {
        if i >= g_sym_count { break; }
        if sym_name(i) == name_idx {
            if sym_kind(i) == SYM_SO_FN { return i; }
            // 同名 `.cr` 声明优先（裁-HR-2）⇒ 不物化 SO_FN（`print`/`println` 走声明面）。
            // 注：原先此处注释称「SO_FN 在 SYM_FN 之前」——那是**改造前**的现状描述
            // （导入期注册 + check_all 复位后追加）；改造后物化发生在**首次查找**，
            // 物化条目追加在表尾，且「有声明则不物化」⇒ 该顺序假设已不存在。
            return -1;
        }
        i = i + 1;
    }
    ssi := find_so_side(name_idx);
    if ssi < 0 { return -1; }
    return so_materialize(ssi);
}


// --- Error tracking ---
// Uses g_diags, g_diag_count from globals.cr (and ast.cr)
// Old g_check_errors is replaced by structured g_diags.

fn check_error(code: int, msg: string, line: int, col: int) {
    grow_diags(g_diag_count + 1);
    w64(g_diags, g_diag_count * DIAG_REC_SIZE, code);
    store_str_ptr(g_diags, g_diag_count * DIAG_REC_SIZE + 8, msg);
    w64(g_diags, g_diag_count * DIAG_REC_SIZE + 16, line);
    w64(g_diags, g_diag_count * DIAG_REC_SIZE + 24, col);
    w64(g_diags, g_diag_count * DIAG_REC_SIZE + 32, diag_fileid_for_line(line));
    g_diag_count = g_diag_count + 1;
}

// --- Borrow checking ---


fn find_borrow_entry(var_ni: int) -> int {
    i : ., mut = 0;
    loop {
        if i >= g_borrow_count { return -1; }
        if r64(g_borrow_vars, i * 8) == var_ni { return i; }
        i = i + 1;
    }
    return -1;
}

fn check_borrow(var_ni: int, is_mut: int) -> bool {
    bi := find_borrow_entry(var_ni);
    if bi >= 0 {
        if is_mut != 0 {
            // &mut x: fail if any borrow exists
            if r64(g_borrow_refs, bi * 8) > 0 || r64(g_borrow_muts, bi * 8) != 0 { return false; }
            w64(g_borrow_muts, bi * 8, 1);
            return true;
        } else {
            // &x: fail if mutable borrow exists
            if r64(g_borrow_muts, bi * 8) != 0 { return false; }
            w64(g_borrow_refs, bi * 8, r64(g_borrow_refs, bi * 8) + 1);
            return true;
        }
    }
    // First borrow of this variable
    grow_borrow_vars(g_borrow_count + 1);
    w64(g_borrow_vars, g_borrow_count * 8, var_ni);
    w64(g_borrow_refs, g_borrow_count * 8, 0);
    w64(g_borrow_muts, g_borrow_count * 8, 0);
    if is_mut != 0 { w64(g_borrow_muts, g_borrow_count * 8, 1); }
    else { w64(g_borrow_refs, g_borrow_count * 8, 1); }
    g_borrow_count = g_borrow_count + 1;
    return true;
}

fn check_use(var_ni: int) -> bool {
    bi := find_borrow_entry(var_ni);
    if bi >= 0 {
        if r64(g_borrow_refs, bi * 8) > 0 || r64(g_borrow_muts, bi * 8) != 0 { return false; }
    }
    return true;
}

fn push_borrow_scope() {
    grow_borrow_markers(g_borrow_scope_depth + 1);
    w64(g_borrow_scope_markers, g_borrow_scope_depth * 8, g_holder_count);
    g_borrow_scope_depth = g_borrow_scope_depth + 1;
}

fn pop_borrow_scope() {
    if g_borrow_scope_depth > 0 {
        g_borrow_scope_depth = g_borrow_scope_depth - 1;
        marker := r64(g_borrow_scope_markers, g_borrow_scope_depth * 8);
        // Release all borrows held from marker to end
        loop {
            if g_holder_count <= marker { break; }
            g_holder_count = g_holder_count - 1;
            borrowed_ni := r64(g_holder_borrowed, g_holder_count * 8);
            is_mut := r64(g_holder_is_mut, g_holder_count * 8);
            bi := find_borrow_entry(borrowed_ni);
            if bi >= 0 {
                if is_mut != 0 { w64(g_borrow_muts, bi * 8, 0); }
                else {
                    if r64(g_borrow_refs, bi * 8) > 0 { w64(g_borrow_refs, bi * 8, r64(g_borrow_refs, bi * 8) - 1); }
                }
                // Clean up entry if no more borrows
                if r64(g_borrow_refs, bi * 8) == 0 && r64(g_borrow_muts, bi * 8) == 0 {
                    si : ., mut = bi;
                    loop {
                        if si + 1 >= g_borrow_count { break; }
                        w64(g_borrow_vars, si * 8, r64(g_borrow_vars, (si + 1) * 8));
                        w64(g_borrow_refs, si * 8, r64(g_borrow_refs, (si + 1) * 8));
                        w64(g_borrow_muts, si * 8, r64(g_borrow_muts, (si + 1) * 8));
                        si = si + 1;
                    }
                    g_borrow_count = g_borrow_count - 1;
                }
            }
        }
    }
}

fn push_unsafe_scope() { g_unsafe_depth = g_unsafe_depth + 1; }
fn pop_unsafe_scope()  { if g_unsafe_depth > 0 { g_unsafe_depth = g_unsafe_depth - 1; } }

fn record_borrow_holder(borrower_ni: int, borrowed_ni: int, is_mut: int) {
    grow_holder(g_holder_count + 1);
    w64(g_holder_borrowers, g_holder_count * 8, borrower_ni);
    w64(g_holder_borrowed, g_holder_count * 8, borrowed_ni);
    w64(g_holder_is_mut, g_holder_count * 8, is_mut);
    g_holder_count = g_holder_count + 1;
}

fn borrow_var_name(node: int) -> int {
    if node < 0 { return -1; }
    if ast_kind(node) == EXPR_IDENT { return ast_int_val(node); }
    return -1;
}

// --- Type resolution utilities ---

fn res_type_node(node: int) -> int {
    if node < 0 { return TI_UNIT; }
    if ast_kind(node) == 0 {
        // Base type node: type_val = TY_*
        // P2b Task 6：8 行内联链 → 单表 `ty_code_to_ti`（尾部回落显式写出，不藏表里）；
        //   本站点域 = {INT,DEX,BOOL,STRING,UNIT,NEVER,CHAR} ∪ {7 = dyn 码}——**与 res_call_type 的
        //   唯一语义差 = NEVER 格**（该函数无此格，见其注）。域外（如 TY_DEX_S=8/未知码）落 TI_UNIT。
        tv := ast_type_val(node);
        mapped : ., mut = ty_code_to_ti(tv);
        if mapped < 0 { mapped = TI_UNIT; }
        return mapped;
    }
    if ast_kind(node) == EXPR_IDENT {
        // Named type: int_val = name string index
        name_idx := ast_int_val(node);
        si := find_gsym(name_idx);
        if si >= 0 && sym_kind(si) == SYM_TYPE {
            return sym_type(si);
        }
        // Create named type entry
        return alloc_named_type(name_idx);
    }
    if ast_kind(node) == EXPR_ARRAY {
        // 表示层概念（2026-09-10 语言面收窄裁决 §1）：`[T; N]` 的类型构造器身份已退役——
        // 语义归处 = product（N 元聚合）/ 序列接口 + 长度 where（N 长序列）/ F11 图（长度事实，
        // 可表达依赖长度）。本语法保留为「内联容量存储」表示提示（映射参数层，与 hw-map 同层；
        // 随实例选择生效或退化，非经典范式映射可忽略）。见
        // docs/superpowers/specs/2026-09-10-language-surface-narrowing-design.md §1
        // Array type [T; N] or slice type [T] (size 0)
        elem := res_type_node(ast_a(node));
        sz := ast_int_val(node);
        if sz == 0 {
            return alloc_type(TYP_SLICE, elem, 0);
        }
        return alloc_type(TYP_ARRAY, elem, sz);
    }
    if ast_kind(node) == EXPR_REFTYPE {
        // Reference type &T or &mut T
        inner := res_type_node(ast_a(node));
        mut_flag := ast_int_val(node);
        return alloc_type(TYP_REF, inner, mut_flag);
    }
    if ast_kind(node) == EXPR_PTRTYPE {
        // Pointer type *T
        inner := res_type_node(ast_a(node));
        return alloc_type(TYP_PTR, inner, 0);
    }
    if ast_kind(node) == EXPR_OPTIONAL {
        // R2 P3 Task 4：`T?` = `T ∪ null`（spec §5.4）——行 = TYP_OPTIONAL(data = 内层行)。
        // 语义在三层落：① 桥接把本行译作 union(内层项, null 原子项)（ty_shadow.cr）；
        // ② 引擎按普通联合项判定（包含/等价/不相交/穷尽性，全走既有 DNF 路径，零新规则）；
        // ③ 判定点（type_compat_strict 等）不变——`int ⊆ int ∪ null`、`int ∪ null ⊄ int`。
        // 一条**不**去侧表的理由：本行无名字（旧形态 Option[T] 的「名字身份」正是本任务退役的
        // 东西），故不进 named_dedup；同内容的两个行在引擎侧译成同一个项（DAG 去重）⇒ 判定等价。
        inner := res_type_node(ast_a(node));
        return alloc_type(TYP_OPTIONAL, inner, 0);
    }
    if ast_kind(node) == EXPR_GENERIC_APPLY {
        // Generic application: Box[int]
        name_idx := ast_a(node);
        first_arg_node := ast_b(node);
        arg_count := ast_c(node);
        si := find_gsym(name_idx);
        if si < 0 || sym_kind(si) != SYM_TYPE {
            check_error(EC_N_GENERIC_TYPE, "Undefined type in generic application", ast_line(node), ast_col(node));
            return TI_UNIT;
        }
        base_ti := sym_type(si);
        // 两趟（照 #2026-09-16-2 元组第二根因同款）：实参类型解析**自身也会向
        // g_gen_apply_data 追加**（嵌套应用如 Box[Box[int]] 的内层载荷）——
        // 先解析进暂存，后一次性认领连续块。修复前「先认领块再逐参解析」会让
        // 内层 append 冲掉外层的 count 槽与后续载荷槽（终点 count 截断），
        // `Box[Box[int]]` 的字段/返回位因此被误判（假拒）。
        args : string, mut;
        if arg_count > 0 {
            args = alloc(arg_count * 8);
            ai : ., mut = 0;
            an : ., mut = first_arg_node;
            loop {
                if ai >= arg_count { break; }
                w64(args, ai * 8, res_type_node(an));
                ai = ai + 1;
                an = an + 1;
            }
        }
        // R2 P3 Task 5（Step 3）：**实例化点**的结构/枚举泛型约束检查（`Box[T: I]` 的 `Box[P]`）。
        // 判定 = ty_sub（本质轴）+ 反例诊断；用户接口约束 = -1 零动作（P3b 阻塞面）。
        gen_inst_constr_check(node, find_struct(name_idx), find_enum(name_idx), args, arg_count);
        // Store args in g_gen_apply_data: [count, arg1, arg2, ...]
        data_start := g_gen_apply_data_count;
        grow_gen_apply_data(data_start + 1 + arg_count);
        w64(g_gen_apply_data, data_start * 8, arg_count);
        ai2 : ., mut = 0;
        loop {
            if ai2 >= arg_count { break; }
            w64(g_gen_apply_data, (data_start + 1 + ai2) * 8, r64(args, ai2 * 8));
            ai2 = ai2 + 1;
        }
        g_gen_apply_data_count = data_start + 1 + arg_count;
        return alloc_type(TYP_GENERIC_APPLY, base_ti, data_start);
    }
    return TI_UNIT;
}

fn find_struct(name_idx: int) -> int {
    i : ., mut = 0;
    loop {
        if i >= g_struct_count { return -1; }
        if si_name(i) == name_idx { return i; }
        i = i + 1;
    }
    return -1;
}

fn find_enum(name_idx: int) -> int {
    i : ., mut = 0;
    loop {
        if i >= g_enum_count { return -1; }
        if ei_name(i) == name_idx { return i; }
        i = i + 1;
    }
    return -1;
}

fn find_iface(name_ni: int) -> int {
    i : ., mut = 0;
    loop {
        if i >= g_iface_count { return -1; }
        if r64(g_ifaces, i * ESZ_IFACEINFO + OFF_IF_NAME) == name_ni { return i; }
        i = i + 1;
    }
    return -1;
}

// ─── R2 P3 Task 0：展开层的「行 → 声明」入口（名字解析归 checker；展开层只读声明表）───
// ti 接受两种形态（与桥接 sh_term_of_ti 的 TYP_NAMED / TYP_GENERIC_APPLY 两分支同域）：
//   TYP_NAMED（data = 名字 ni）/ TYP_GENERIC_APPLY（data = 基型行；基型须为 TYP_NAMED）。
// -1 = 既非命名行也非泛型应用行 / 基型非命名行。**只读**（不改类型表、不报诊断、不分配）。
fn decl_name_of_ti(ti: int) -> int {
    if ti < 0 { return -1; }
    k := get_type_kind(ti);
    if k == TYP_NAMED { return get_type_data(ti); }
    if k == TYP_GENERIC_APPLY {
        base := get_type_data(ti);
        if get_type_kind(base) == TYP_NAMED { return get_type_data(base); }
    }
    return -1;
}

// 命名/泛型应用行 → struct 声明行（-1 = 非此二形态 / 该名字未声明为 struct）
fn find_struct_row_of(ti: int) -> int {
    ni := decl_name_of_ti(ti);
    if ni < 0 { return -1; }
    return find_struct(ni);
}

// 同上 → enum 声明行
fn find_enum_row_of(ti: int) -> int {
    ni := decl_name_of_ti(ti);
    if ni < 0 { return -1; }
    return find_enum(ni);
}

fn get_type_name(ti: int) -> int {
    k := get_type_kind(ti);
    if k == TYP_NAMED { return get_type_data(ti); }
    if k == TYP_BASE {
        d := get_type_data(ti);
        if d == TY_INT { return str_intern("int"); }
        if d == TY_DEX { return str_intern("dex"); }
        if d == TY_BOOL { return str_intern("bool"); }
        if d == TY_STRING { return str_intern("string"); }
        if d == TY_UNIT { return str_intern("unit"); }
        if d == TY_CHAR { return str_intern("char"); }
    }
    if k == TYP_GENERIC_APPLY {
        base := get_type_data(ti);
        if get_type_kind(base) == TYP_NAMED { return get_type_data(base); }
    }
    return -1;
}

// R2 P3b Task 6（Step 3，mangling 退役）：方法解析从「`Type.method` 字符串拼接 + `find_func`」
// 改为**表查询**（`g_methods` 三元组 {type_ni, method_ni, func_name_ni}，parser 的 impl 分支
// 唯一写点；引擎侧同一入口 `iface_find_method`）。域等价（同一 impl 声明面），且**零 str_intern**
// ——旧形态对缺失方法名会往驻留表追加新串（`.ccr` STR 段增长面，见 A.3-②）。
fn type_has_method(type_ni: int, method_ni: int) -> bool {
    if iface_find_method(type_ni, method_ni) < 0 { return false; }
    return true;
}

// 接口满足判定（bool 面；语义 = 引擎轴 C 用户谓词的**同一实现** `iface_user_satisfies_ii`，
// 见 type_engine.cr：方法名表查询 + 接收者模式 + 签名项引擎判定）。保持 bool 返回值的理由 =
// 调用点（泛型约束的函数调用位点）的既有语义「不能判定为满足 ⇒ 报 TG02」逐字不变（措辞/去重/
// rc 不在本任务面内）；三态面由 `iface_satisfies` / `iface_user_satisfies` 承担。
fn check_iface(type_ni: int, iface_ii: int) -> bool {
    if iface_user_satisfies_ii(type_ni, iface_ii) == 1 { return true; }
    return false;
}

// ═══════════════ R2 P3 Task 5：泛型约束（保留 / 实例化判定 / 反例）═══════════════
// 语义（spec §5.2）：`fn f[T]`（约束 = ⊤）/ `fn f[T: I]`（约束 = 类型项 I）；**结构/枚举泛型
// 补上约束**（旧态：parser 写进 dummy 缓冲后丢弃，见 parser.cr 的 save_*_gen_constrs）；
// 实例化检查 = `ty_sub(实参, 约束)`；失败给**非空反例**（`tt_witness`）。
// **本批 = P3a 半边**（P3 计划 Task 5 与「与 P2b 的交接面」表第 4 行）：
//   · 本质轴（约束项 = 原生/已声明类型名）：`gen_constr_satisfied` 走引擎判定 —— 本批落地；
//   · 用户轴（`I` 是 `interface` 名）：满足判定 = `iface_satisfies`（**P3b Task 0 已交付**，
//     type_engine.cr 的轴 C）。两站点口径分家（**有意**）：函数调用点 `gen_constr_satisfied`
//     只取 1（0/-1 回落既有 `check_iface` 名拼接路径——措辞/去重/rc 逐字保持，切换归 Task 6
//     Step 3）；结构/枚举实例化点 `gen_inst_constr_satisfied` 直取真值（0 ⇒ TG02）。
//     ⇒ 不得据「函数调用点措辞未变」推断判定面未落地。
// 三态纪律（P0/P1/P2a 继承）：-1 一律**不判**——不得当 0（拒绝）或 1（放行）。
// 预算隔离照 `ti_subsumes`（引擎 memo 跨查询命中会让结果依赖预算历史）。

// 约束名 → 类型行（-1 = 不是类型名）。原生名按 parse_type 的字典逐名判（parser.cr 的
// 8 个基类型名分支：int/dex/bool/string/char/never/unit/dyn——**原生名不经符号表**，
// init_types 只建类型行不 def_sym）；其余查符号表 SYM_TYPE（struct/enum/别名/泛型形参）。
fn gen_constr_type_ti(c_ni: int) -> int {
    if c_ni < 0 { return -1; }
    s := istr_get(c_ni);
    if str_eq(s, "int") != 0 { return TI_INT; }
    if str_eq(s, "dex") != 0 { return TI_DEX; }
    if str_eq(s, "bool") != 0 { return TI_BOOL; }
    if str_eq(s, "string") != 0 { return TI_STR; }
    if str_eq(s, "char") != 0 { return TI_CHAR; }
    if str_eq(s, "unit") != 0 { return TI_UNIT; }
    if str_eq(s, "never") != 0 { return TI_NEVER; }
    if str_eq(s, "dyn") != 0 { return TI_DYN; }
    si := find_gsym(c_ni);
    if si >= 0 && sym_kind(si) == SYM_TYPE { return sym_type(si); }
    return -1;
}

// 约束满足三态：1 = 满足 / 0 = 违反 / -1 = **不判**（名字非类型/非接口 / 桥接失败）。三态
// 直传（**不**把 -1 折成 0/1）。
// R2 P3b Task 0：本函数 = `iface_satisfies` 统一入口的**函数调用点消费者**（P2b 交接契约①）。
fn gen_constr_satisfied(c_ni: int, arg_ti: int) -> int {
    if c_ni < 0 || arg_ti < 0 { return -1; }
    if find_iface(c_ni) >= 0 {
        // 用户轴（接口名）：`iface_satisfies` 已交付（P3b Task 0）——**1 提前返回**（与回落
        // 路径结论一致，省一次名拼接/查表）；**0 与 -1 一律落下方既有 `check_iface` 名拼接
        // 路径**（本层口径 = P3a「函数调用点逐字不动」：措辞/去重/rc 全保持）。0 → 诊断的
        // 切换（= 走 gen_constr_raise 的新措辞）归 Task 6 Step 3——两处谓词同源（
        // iface_user_satisfies 与 check_iface 判同一面），故此处**不存在**判定分歧。
        s := iface_satisfies(arg_ti, c_ni);
        if s == 1 { return 1; }
        return -1;
    }
    cti := gen_constr_type_ti(c_ni);
    if cti < 0 { return -1; }                      // 非类型名（未定义名等）：不判、不发明诊断
    a := sh_term_of_ti(arg_ti);
    b := sh_term_of_ti(cti);
    if a < 0 || b < 0 { return -1; }               // 桥接缺口 ⇒ 不判
    ty_budget_reset(200000);
    s := ty_sub(a, b);
    ty_budget_reset(200000);
    return s;                                      // 1/0/-1 直传
}

// 实例化点（结构/枚举 `Box[T: I]` 的 `Box[P]`）专用满足判定：**用户轴直取 iface_satisfies
// 的真值**（不回落）——回落面是函数调用点的消息/去重口径（见 gen_constr_satisfied 注），
// 与实例化点无关。purpose：本批（P3b Task 0）起 `T: I` 在实例化点**真判定**（此前 = 恒 -1
// 不判、零诊断——P3a 登记面）。三态直传：-1 = 不判 ⇒ 调用方零动作。
fn gen_inst_constr_satisfied(c_ni: int, arg_ti: int) -> int {
    if c_ni < 0 || arg_ti < 0 { return -1; }
    if find_iface(c_ni) >= 0 { return iface_satisfies(arg_ti, c_ni); }
    return gen_constr_satisfied(c_ni, arg_ti);
}

// 反例文本（诊断用）：`实参 \ 约束` 的具体值。三态 -1 / 反例不可得 → ""（**不谎报反例**）。
fn gen_constr_witness_str(arg_ti: int, c_ni: int) -> string {
    cti := gen_constr_type_ti(c_ni);
    if cti < 0 { return ""; }
    a := sh_term_of_ti(arg_ti);
    b := sh_term_of_ti(cti);
    if a < 0 || b < 0 { return ""; }
    ty_budget_reset(200000);
    w := tt_witness(a, b);
    ty_budget_reset(200000);
    if w < 0 { return ""; }
    return tt_display(w);
}

// 诊断发射（措辞分派：既有接口路径的措辞/码不动；本路径 = 约束 + 反例）。码沿用
// EC_TG_BOUND（TG02，软诊断：check rc=1 / build rc=0 —— 与既有约束检查同门，**不新增硬门**）。
fn gen_constr_raise(arg_ti: int, c_ni: int, line: int, col: int) {
    // 措辞分派：接口名约束 ⇒ **与既有 check_iface 路径同措辞**（"does not satisfy interface
    // 'X'"——两站点一致性；接口非类型行 ⇒ 反例项不可得 = 不附反例，不谎报）；类型名约束 ⇒
    // 既有措辞 + 反例（措辞与反例面 P3a 已交付，逐字未动）。
    if find_iface(c_ni) >= 0 {
        msg_i := "Type '" + type_display(arg_ti) + "' does not satisfy interface '" + istr_get(c_ni) + "'";
        check_error(EC_TG_BOUND, msg_i, line, col);
        return;
    }
    msg := "Type '" + type_display(arg_ti) + "' does not satisfy constraint '" + istr_get(c_ni) + "'";
    w := gen_constr_witness_str(arg_ti, c_ni);
    if str_len(w) > 0 { msg = msg + " (counterexample: " + w + ")"; }
    check_error(EC_TG_BOUND, msg, line, col);
}

// ─── 诊断去重侧表（开放寻址，16B/条 {key, 1}；key = node * MAX_GENERICS + gi）───
// 为何需要：实例化点的判定函数（res_type_node / res_call_type）按**语法出现点**调用，同一
// AST 节点可被多次解析（字段访问、多次引用同一注解…），且 `check_error` 无去重 ⇒ 不去重即
// 同一条约束违反被打印多次。键 = (节点, 形参下标)——同节点不同形参各报一条（信息不丢）。
// 生命周期同 named_dedup（init_types 置 cap=0 → 惰性重建）；键含 AST 节点下标 ⇒ 随编译期作废。
fn gen_constr_seen_init() {
    if g_constr_seen_cap > 0 { return; }
    nc := 1024;
    nb := alloc(nc * 16);
    i : ., mut = 0;
    loop { if i >= nc { break; } w64(nb, i * 16, -1); i = i + 1; }
    g_constr_seen = nb;
    g_constr_seen_cap = nc;
    g_constr_seen_count = 0;
}

fn gen_constr_seen_reset() {
    g_constr_seen_cap = 0;
    g_constr_seen_count = 0;
}

fn gen_constr_seen_probe(k: int) -> int {
    cap := g_constr_seen_cap;
    p : ., mut = tt_mod(k, cap);
    ret : ., mut = -1;
    loop {
        kk := r64(g_constr_seen, p * 16);
        if kk < 0 { ret = p; break; }
        if kk == k { ret = p; break; }
        p = p + 1; if p >= cap { p = 0; }
    }
    return ret;
}

fn gen_constr_seen_rehash() {
    old := g_constr_seen;
    old_cap := g_constr_seen_cap;
    nc := old_cap * 2;
    nb := alloc(nc * 16);
    i : ., mut = 0;
    loop { if i >= nc { break; } w64(nb, i * 16, -1); i = i + 1; }
    g_constr_seen = nb;
    g_constr_seen_cap = nc;
    g_constr_seen_count = 0;
    j : ., mut = 0;
    loop {
        if j >= old_cap { break; }
        kk := r64(old, j * 16);
        if kk >= 0 {
            s := gen_constr_seen_probe(kk);
            w64(g_constr_seen, s * 16, kk);
            w64(g_constr_seen, s * 16 + 8, 1);
            g_constr_seen_count = g_constr_seen_count + 1;
        }
        j = j + 1;
    }
}

// 1 = 首次（调用方报诊断），0 = 已报过（丢弃）。装填因子守卫在探测**前**（表满 + 键不存在
// ⇒ 开放寻址永不退出，照 named_dedup / sh_map 同款同因）。
fn gen_constr_seen_add(k: int) -> int {
    gen_constr_seen_init();
    if (g_constr_seen_count + 1) * 2 >= g_constr_seen_cap { gen_constr_seen_rehash(); }
    s := gen_constr_seen_probe(k);
    if r64(g_constr_seen, s * 16) == k { return 0; }
    w64(g_constr_seen, s * 16, k);
    w64(g_constr_seen, s * 16 + 8, 1);
    g_constr_seen_count = g_constr_seen_count + 1;
    return 1;
}

// ─── 实例化点检查（结构/枚举泛型：`Box[T: I]` 的 `Box[P]`）───
// 消费点 = res_type_node / res_call_type 的 EXPR_GENERIC_APPLY 分支（实参已解析成 ti 处）。
// sa/ea = struct/enum 声明行（-1 = 该名字不是 struct/enum —— 接口泛型/未知名，零动作）。
// **实参缺位不判**（不越界读）；**arg_ti < 0 不判**（未解析）；用户接口约束经
// gen_constr_satisfied 回 -1 ⇒ 零动作（P3b 阻塞面，见该函数注）。
fn gen_inst_constr_check(app_node: int, sa: int, ea: int, args: string, arg_count: int) {
    gc : ., mut = 0;
    if sa >= 0 { gc = si_generic_count(sa); }
    else if ea >= 0 { gc = ei_generic_count(ea); }
    else { return; }
    i : ., mut = 0;
    loop {
        if i >= gc { break; }
        if i >= arg_count { break; }
        c_ni : ., mut = -1;
        if sa >= 0 { c_ni = si_gen_constr(sa, i); } else { c_ni = ei_gen_constr(ea, i); }
        if c_ni >= 0 {
            arg_ti := r64(args, i * 8);
            if arg_ti >= 0 {
                if gen_inst_constr_satisfied(c_ni, arg_ti) == 0 {
                    if gen_constr_seen_add(app_node * MAX_GENERICS + i) != 0 {
                        gen_constr_raise(arg_ti, c_ni, ast_line(app_node), ast_col(app_node));
                    }
                }
            }
        }
        i = i + 1;
    }
}

// --- First pass: collect all declarations ---

fn collect_decls() {
    i : ., mut = 0;
    // First: register all struct types
    loop {
        if i >= g_struct_count { break; }
        name_idx := si_name(i);
        type_idx := alloc_named_type(name_idx);
        def_sym(name_idx, SYM_TYPE, type_idx, -1);
        i = i + 1;
    }
    // Resolve struct field types now that all struct names are registered
    i = 0;
    loop {
        if i >= g_struct_count { break; }
        j : ., mut = 0;
        loop {
            if j >= si_field_count(i) { break; }
            // Field types were stored by parser as unpack_type() results (TY_* or 0)
            // We need to resolve them — but they're stored as ints, not nodes.
            // For now, leave as-is; fields are resolved during type inference.
            j = j + 1;
        }
        i = i + 1;
    }
    // Register struct generic params for type resolution
    i = 0;
    loop {
        if i >= g_struct_count { break; }
        gc := si_generic_count(i);
        if gc > 0 {
            gj : ., mut = 0;
            loop {
                if gj >= gc { break; }
                gname_ni := si_generic_name(i, gj);
                g_ti := alloc_type(TYP_GENERIC_PARAM, gname_ni, 0);
                grow_gen_params(g_gen_param_count + 2);
                w64(g_gen_params, g_gen_param_count * 8, gname_ni);
                w64(g_gen_params, (g_gen_param_count + 1) * 8, g_ti);
                g_gen_param_count = g_gen_param_count + 2;
                def_sym(gname_ni, SYM_TYPE, g_ti, -1);
                gj = gj + 1;
            }
        }
        i = i + 1;
    }
    // Register all interface types
    i = 0;
    loop {
        if i >= g_iface_count { break; }
        name_idx := r64(g_ifaces, i * ESZ_IFACEINFO + OFF_IF_NAME);
        type_idx := alloc_named_type(name_idx);
        def_sym(name_idx, SYM_TYPE, type_idx, -1);
        i = i + 1;
    }
    // ─── R2 P3 Task 4：**退役**内建 Option 注册（spec §5.4）───
    // 旧行为：无用户 `enum Option` 时自动注册一个名为 "Option" 的**命名类型**行并 def_sym
    // （`T?` 经 parser 降级为 `Option[T]` 泛型应用，靠这个名字解析）。
    // 退役依据：① `T?` 的目标形态 = EXPR_OPTIONAL → TYP_OPTIONAL（`T ∪ null` 可直接表达）；
    // ② 名字路径把「可选」绑死在一个用户可重名的标识符上（用户声明 `enum Option` 时 `T?`
    // 的含义静默改变——Task 3 §6-⑥ 登记的交互面）；③ `.ccr` STR 段与行号序随该注册漂移。
    // 退役后 `Option` **不再是**语言内建名（无行、无符号）：用户自声明 `enum Option` 则按
    // 普通枚举解析；一行不注册 = `test_optional.py` 的行数对照用例（selftest `t4.option_not_registered`）。
    // ⚠ 连带面（须登记）：`Some`/`None` 不再靠该行解析——内建构造器路径见 EXPR_ENUM_CONSTRUCTOR
    // （按关键字名给 TYP_OPTIONAL/TYP_NULL 行）；`EXPR_TRY` 的 `base_name == "Option"/"Result"`
    // 名字串判断同期退役（改按类型项结构解包）。

    // Register all enum types and their variant constructors
    i = 0;
    loop {
        if i >= g_enum_count { break; }
        name_idx := ei_name(i);
        type_idx := alloc_named_type(name_idx);
        def_sym(name_idx, SYM_TYPE, type_idx, -1);
        // Register each variant as a function returning the enum type
        vi : ., mut = 0;
        loop {
            if vi >= ei_variant_count(i) { break; }
            vname_idx := ei_variant_name(i, vi);
            def_sym(vname_idx, SYM_FN, type_idx, -1);
            vi = vi + 1;
        }
        i = i + 1;
    }

    // Register enum generic params for type resolution
    i = 0;
    loop {
        if i >= g_enum_count { break; }
        gc := ei_generic_count(i);
        if gc > 0 {
            gj : ., mut = 0;
            loop {
                if gj >= gc { break; }
                gname_ni := ei_generic_name(i, gj);
                g_ti := alloc_type(TYP_GENERIC_PARAM, gname_ni, 0);
                grow_gen_params(g_gen_param_count + 2);
                w64(g_gen_params, g_gen_param_count * 8, gname_ni);
                w64(g_gen_params, (g_gen_param_count + 1) * 8, g_ti);
                g_gen_param_count = g_gen_param_count + 2;
                def_sym(gname_ni, SYM_TYPE, g_ti, -1);
                gj = gj + 1;
            }
        }
        i = i + 1;
    }

    // Register type aliases
    i = 0;
    loop {
        if i >= g_type_alias_count { break; }
        name_idx := r64(g_type_aliases, i * 16);
        type_node := r64(g_type_aliases, i * 16 + 8);
        ti := res_type_node(type_node);
        def_sym(name_idx, SYM_TYPE, ti, -1);
        i = i + 1;
    }

    // Register all functions
    i = 0;
    loop {
        if i >= g_func_count { break; }
        name_idx := fi_name(i);
        fn_node := fi_ast_node(i);
        hotpatch_ver := ast_int_val(fn_node) / 256;
        rt := fi_return_type(i);
        rt_ti := TI_UNIT;
        // For generic functions, skip return type resolution (depends on call site)
        if fi_generic_count(i) > 0 {
            rt_ti = TI_UNIT;
            // Register function generic params for type resolution
            gj : ., mut = 0;
            loop {
                if gj >= fi_generic_count(i) { break; }
                gname_ni := fi_generic_name(i, gj);
                g_ti := alloc_type(TYP_GENERIC_PARAM, gname_ni, 0);
                grow_gen_params(g_gen_param_count + 2);
                w64(g_gen_params, g_gen_param_count * 8, gname_ni);
                w64(g_gen_params, (g_gen_param_count + 1) * 8, g_ti);
                g_gen_param_count = g_gen_param_count + 2;
                def_sym(gname_ni, SYM_TYPE, g_ti, -1);
                gj = gj + 1;
            }
        } else {
            type_node := ast_type_val(fn_node);
            if type_node > 0 && ast_kind(type_node) != 0 {
                rt_ti = res_type_node(type_node);
            } else {
                // P2b Task 6：值经单表 `ty_code_to_ti`；**本站点域 = 现状链 {INT,DEX,BOOL,STRING,UNIT}**
                //   （无 CHAR/NEVER/7 ⇒ 三者与域外码一律保留 `rt_ti` 初值 TI_UNIT——域差异**逐站保留**，
                //   不得按「表 + 尾回落」一刀切：站点域差异是**载荷**的，探针 F1/F2/F4 实证，
                //   `fn f() -> char` 的非泛型符号类型现状 = unit、extern 站点同形 = char）。
                rt_mapped := ty_code_to_ti(rt);
                if rt_mapped >= 0 && rt_mapped != TI_CHAR && rt_mapped != TI_NEVER && rt_mapped != TI_DYN {
                    rt_ti = rt_mapped;
                }
            }
        }
        if hotpatch_ver > 0 {
            // @hotpatch function: register with mangled name fn_name.vN
            fn_name_str := istr_get(name_idx);
            mangled_name := fn_name_str + ".v" + int_str(hotpatch_ver);
            mangled_ni := str_intern(mangled_name);
            def_sym(mangled_ni, SYM_FN, rt_ti, fn_node);

            // Verify signature matches the first version
            fj : ., mut = 0;
            loop {
                if fj >= i { break; }
                if fi_name(fj) == name_idx {
                    first_fn := fi_ast_node(fj);
                    first_rt := fi_return_type(fj);
                    first_rt_ti := TI_UNIT;
                    type_node2 := ast_type_val(first_fn);
                    if type_node2 > 0 && ast_kind(type_node2) != 0 {
                        first_rt_ti = res_type_node(type_node2);
                    } else {
                        // P2b Task 6：同上一处（本站点 = **hotpatch 首版**返回，域与上一处逐字相同）
                        first_mapped := ty_code_to_ti(first_rt);
                        if first_mapped >= 0 && first_mapped != TI_CHAR && first_mapped != TI_NEVER && first_mapped != TI_DYN {
                            first_rt_ti = first_mapped;
                        }
                    }

                    // P3 Task 1：本站两侧**皆声明**（无源/目标之分）⇒ 长度面走对称核（= 现状语义）
                    compat := type_compat_sym(rt_ti, first_rt_ti);
                    if compat != 1 {
                        diag_type_incompatible(compat, EC_TF_RETURN, "Hotpatch return type mismatch for '" + fn_name_str + "'", ast_line(fn_node), ast_col(fn_node));
                    }
                    first_pc := fi_param_count(fj);
                    cur_pc := fi_param_count(i);
                    if first_pc != cur_pc {
                        check_error(EC_N_DUPLICATE, "Hotpatch parameter count mismatch for '" + fn_name_str + "'", ast_line(fn_node), ast_col(fn_node));
                    }
                    break;
                }
                fj = fj + 1;
            }

            // Also register original name for call resolution (latest version wins)
            def_sym(name_idx, SYM_FN, rt_ti, fn_node);
        } else {
            // Normal function: check for duplicates (allow if existing is @hotpatch)
            existing_si := find_gsym(name_idx);
            if existing_si >= 0 && sym_kind(existing_si) == SYM_FN {
                existing_node := sym_node(existing_si);
                existing_is_hotpatch : ., mut = 0;
                if existing_node >= 0 && ast_kind(existing_node) == EXPR_FN {
                    existing_is_hotpatch = ast_int_val(existing_node) / 256;
                }
                if existing_is_hotpatch == 0 {
                    fn_name_str := istr_get(name_idx);
                    check_error(EC_N_DUPLICATE, "Duplicate function definition '" + fn_name_str + "'", ast_line(fn_node), ast_col(fn_node));
                }
            }
            def_sym(name_idx, SYM_FN, rt_ti, fn_node);
        }
        fi_set_ispure(i, 1);  // optimistic: all functions are pure
        i = i + 1;
    }
    // Register extern function declarations (EXPR_EXTERN nodes not yet in g_funcs)
    ei : ., mut = 0;
    loop {
        if ei >= g_ast_count { break; }
        if ast_kind(ei) == EXPR_EXTERN {
            name_ni := ast_a(ei);
            first_param := ast_b(ei);
            param_count := ast_c(ei);
            ret_type := ast_type_val(ei);

            // Resolve return type to type index
            // P2b Task 6：值经单表 `ty_code_to_ti`；**本站点域 = {INT,DEX,BOOL,STRING,UNIT,CHAR}**
            //   （含 CHAR、缺 NEVER/7——与上方 hotpatch 注册站点的域**不同且载荷**：探针 F4 实测
            //   `extern fn f() -> char` 的符号类型 = char，而 F1 同形非 extern = unit）
            rt_ti : ., mut = TI_UNIT;
            ext_mapped := ty_code_to_ti(ret_type);
            if ext_mapped >= 0 && ext_mapped != TI_NEVER && ext_mapped != TI_DYN {
                rt_ti = ext_mapped;
            }

            // Register in symbol table (skip if duplicate)
            if find_gsym(name_ni) < 0 {
                def_sym(name_ni, SYM_FN, rt_ti, ei);
            }

            // Register in g_funcs for backend codegen and linking
            func_idx := g_func_count;
            grow_funcs(func_idx + 1);
            fi_set_name(func_idx, name_ni);
            fi_set_param_count(func_idx, param_count);
            fi_set_return_type(func_idx, ret_type);
            fi_set_ast_node(func_idx, ei);
            fi_set_generic_count(func_idx, 0);
            fi_set_ispure(func_idx, 1);  // optimistic: extern functions are pure
            g_func_count = func_idx + 1;
        }
        ei = ei + 1;
    }
    // Register all global variables
    i = 0;
    loop {
        if i >= g_global_let_count { break; }
        node := r64(g_global_lets, i * 8);
        name_idx := ast_a(node);  // EXPR_LET: a = name idx
        type_node := ast_b(node);  // EXPR_LET: b = type node (-1 if none)
        ti := TI_UNIT;
        if type_node >= 0 { ti = res_type_node(type_node); }
        def_sym(name_idx, SYM_GLOBAL, ti, node);
        i = i + 1;
    }
    // Register module aliases (from imports)
    mi : ., mut = 0;
    loop {
        if mi >= g_mod_count { break; }
        alias_ni := r64(g_mods, mi * 24);
        fileid_ni := r64(g_mods, mi * 24 + 8);
        def_sym(alias_ni, SYM_MODULE, fileid_ni, -1);
        mi = mi + 1;
    }
    // Register mod path declarations (mod foo::bar;)
    pi : ., mut = 0;
    loop {
        if pi >= g_mod_path_count { break; }
        mpn := r64(g_mod_path_names, pi * 8);
        def_sym(mpn, SYM_MODULE, mpn, -1);
        pi = pi + 1;
    }
    // Build module function lookup table for qualified access (e.g., mymath.add)
    main_fni : ., mut = 0;
    if g_file_count > 0 { main_fni = r64(g_files, 0); }
    g_mod_func_count = 0; g_mod_func_cap = 0;
    fi : ., mut = 0;
    loop {
        if fi >= g_func_count { break; }
        fn_node := fi_ast_node(fi);
        fn_line := ast_line(fn_node);
        if fn_line > 0 && fn_line <= g_line_count {
            fileid_ni := r64(g_line_fileid, (fn_line - 1) * 8);
            if fileid_ni != main_fni && fileid_ni != 0 && g_line_count > 0 {
                grow_mod_funcs(g_mod_func_count + 1);
                w64(g_mod_func_fileids, g_mod_func_count * 8, fileid_ni);
                w64(g_mod_func_names, g_mod_func_count * 8, fi_name(fi));
                fn_si := find_sym(fi_name(fi));
                if fn_si >= 0 {
                    w64(g_mod_func_tis, g_mod_func_count * 8, sym_type(fn_si));
                }
                g_mod_func_count = g_mod_func_count + 1;
            }
        }
        fi = fi + 1;
    }
}

// --- Generic type inference helpers ---

fn is_func_generic(fi: int, name_idx: int) -> bool {
    if fi < 0 || fi >= g_func_count { return false; }
    gi : ., mut = 0;
    loop {
        if gi >= fi_generic_count(fi) { return false; }
        if r64(g_funcs, fi * ESZ_FUNCINFO + OFF_FI_GENERIC_NAMES + gi * 8) == name_idx { return true; }
        gi = gi + 1;
    }
    return false;
}

fn find_func(name_idx: int) -> int {
    i : ., mut = 0;
    loop {
        if i >= g_func_count { return -1; }
        if fi_name(i) == name_idx { return i; }
        i = i + 1;
    }
    return -1;
}

// ─── TODO #2026-09-11-11 ①②：struct 字面量的名字绑定 / 类型比对 辅助 ───

// 字段名 idx → 声明下标（-1 = 该名字不在声明中）。名字 idx 来自 parser 写入的 wrapper.b
// （EXPR_STRUCT 契约，见 ast.cr / parser.cr struct 字面量分支）。
fn struct_field_index_by_name(si: int, name_ni: int) -> int {
    if si < 0 || name_ni < 0 { return -1; }
    j : ., mut = 0;
    loop {
        if j >= si_field_count(si) { return -1; }
        if si_field_name(si, j) == name_ni { return j; }
        j = j + 1;
    }
    return -1;
}

// 类型里是否**仍含未实例化的泛型参数**（TYP_GENERIC_PARAM，可嵌套在数组 / 指针 / 引用 /
// 切片 / 元组 / 泛型应用内）。字面量的「字段类型 vs 声明」「元素同质性」判定在**任一侧**
// 含未实例化参数时**跳过**——参数未实例化时比较不成立，强行比较 = 假拒（实测泛型函数体
// `fn f[T](x: T) { p := P{a: 1, b: x}; }`：x 的类型是 T，与声明的 int 比较必假）。参数实例化
// 由 monomorph 负责，此判定不越权。
fn ti_has_generic_param(ti: int) -> int {
    k := get_type_kind(ti);
    if k < 0 { return 0; }
    if k == TYP_GENERIC_PARAM { return 1; }
    if k == TYP_ARRAY || k == TYP_PTR || k == TYP_REF || k == TYP_SLICE {
        return ti_has_generic_param(get_type_data(ti));
    }
    if k == TYP_TUPLE {
        cnt := get_type_data(ti);
        st := get_type_extra(ti);
        i : ., mut = 0;
        loop {
            if i >= cnt { break; }
            if ti_has_generic_param(r64(g_gen_apply_data, (st + i) * 8)) != 0 { return 1; }
            i = i + 1;
        }
        return 0;
    }
    if k == TYP_GENERIC_APPLY {
        st := get_type_extra(ti);
        cnt := r64(g_gen_apply_data, st * 8);
        i : ., mut = 0;
        loop {
            if i >= cnt { break; }
            if ti_has_generic_param(r64(g_gen_apply_data, (st + 1 + i) * 8)) != 0 { return 1; }
            i = i + 1;
        }
        return 0;
    }
    return 0;
}

// 字段**声明类型节点**是否提及本结构体的泛型参数（`T` / `[T; 3]` / `Box[T]` …）。提及 =
// 该字段的声明类型在字面量处**无法静态解析**：结构体泛型参数在字面量作用域不在名字表里，
// res_type_node 会把 `T` 误解析成名为 "T" 的具名类型 → 与实参比较必假（假拒）。故这些字段
// 的类型比对跳过；参数本身走绑定路径（is_struct_generic 判定，见 EXPR_STRUCT 分支）。
fn type_node_mentions_struct_param(si: int, tn: int) -> int {
    if tn < 0 || si < 0 { return 0; }
    k := ast_kind(tn);
    if k == EXPR_IDENT {
        if is_struct_generic(si, ast_int_val(tn)) { return 1; }
        return 0;
    }
    if k == EXPR_ARRAY || k == EXPR_REFTYPE || k == EXPR_PTRTYPE || k == EXPR_OPTIONAL {
        // EXPR_OPTIONAL（P3 Task 4）：内层提及形参（`T?` 字段）⇒ 同上跳过字面量处的静态比对。
        return type_node_mentions_struct_param(si, ast_a(tn));
    }
    if k == EXPR_GENERIC_APPLY {
        if is_struct_generic(si, ast_a(tn)) { return 1; }
        cnt := ast_c(tn);
        an : ., mut = ast_b(tn);
        i : ., mut = 0;
        loop {
            if i >= cnt { break; }
            if an >= 0 {
                if type_node_mentions_struct_param(si, an) != 0 { return 1; }
            }
            an = an + 1;
            i = i + 1;
        }
        return 0;
    }
    return 0;
}

// 类型展示名（诊断措辞用）：具名/基型/泛型应用基名走 get_type_name，其余构造子递归拼装。
// 未识别 → "?"（不伪造名字）。
fn type_display(ti: int) -> string {
    k := get_type_kind(ti);
    // 泛型应用**先于** get_type_name 捷径处理（#2026-09-11-11 评审 Minor #2）：后者对
    // TYP_GENERIC_APPLY 只返回基名 ⇒ 实参全丢（「expected Box, got Box」——
    // 真正不匹配的那个类型实参恰是读者最需要的），且使本函数下方的实参分支
    // 成死码。此处展开成 `Box[int]` / `Pair[Box[int], string]` 形式。
    if k == TYP_GENERIC_APPLY {
        base := get_type_data(ti);
        s : string, mut;
        s = type_display(base);
        s = s + "[";
        start := get_type_extra(ti);
        cnt := r64(g_gen_apply_data, start * 8);
        i : ., mut = 0;
        loop {
            if i >= cnt { break; }
            if i > 0 { s = s + ", "; }
            s = s + type_display(r64(g_gen_apply_data, (start + 1 + i) * 8));
            i = i + 1;
        }
        s = s + "]";
        return s;
    }
    ni := get_type_name(ti);
    if ni >= 0 { return istr_get(ni); }
    if k == TYP_ARRAY { return "[" + type_display(get_type_data(ti)) + "; " + int_str(get_type_extra(ti)) + "]"; }
    if k == TYP_SLICE { return "[" + type_display(get_type_data(ti)) + "]"; }
    if k == TYP_PTR { return "*" + type_display(get_type_data(ti)); }
    if k == TYP_REF { return "&" + type_display(get_type_data(ti)); }
    if k == TYP_GENERIC_PARAM { return istr_get(get_type_data(ti)); }
    if k == TYP_DYN { return "dyn"; }
    // R2 P3 Task 4：`T?` 显示为 `T?`、null 单点类型显示为 "null"（诊断措辞面；未识别仍 "?"）
    if k == TYP_OPTIONAL { return type_display(get_type_data(ti)) + "?"; }
    if k == TYP_NULL { return "null"; }
    return "?";
}

fn is_struct_generic(si: int, name_idx: int) -> bool {
    if si < 0 || si >= g_struct_count { return false; }
    gi : ., mut = 0;
    loop {
        if gi >= si_generic_count(si) { return false; }
        if si_generic_name(si, gi) == name_idx { return true; }
        gi = gi + 1;
    }
    return false;
}

fn find_struct_by_name(name_idx: int) -> int {
    i : ., mut = 0;
    loop {
        if i >= g_struct_count { return -1; }
        if si_name(i) == name_idx { return i; }
        i = i + 1;
    }
    return -1;
}

fn res_call_type(node: int, func_fi: int) -> int {
    // Resolve a type node for call inference, treating generic params as TYP_GENERIC_PARAM
    if node < 0 { return TI_UNIT; }
    if ast_kind(node) == 0 {
        // P2b Task 6：7 行内联链 → 单表 `ty_code_to_ti`；**本站点与 res_type_node 的唯一语义差
        //   = NEVER 格**（现状链无 TY_NEVER 分支 ⇒ 落尾 TI_UNIT）——探针实测**可达**
        //   （`fn g[T](a: T) -> never {...}` 的调用位点；插桩 build 实测 PROBE6_CALL_NEVER 命中 1 次，
        //   见报告 §探针）⇒ 差异**显式保留**，不静默合一；「never 在调用位点被当 unit」登记为 P3 待裁决项。
        tv := ast_type_val(node);
        mapped : ., mut = ty_code_to_ti(tv);
        if mapped < 0 || tv == TY_NEVER { mapped = TI_UNIT; }
        return mapped;
    }
    if ast_kind(node) == EXPR_IDENT {
        name_idx := ast_int_val(node);
        if is_func_generic(func_fi, name_idx) {
            return alloc_type(TYP_GENERIC_PARAM, name_idx, 0);
        }
        // Regular named type
        si := find_gsym(name_idx);
        if si >= 0 && sym_kind(si) == SYM_TYPE { return sym_type(si); }
        return alloc_named_type(name_idx);
    }
    if ast_kind(node) == EXPR_GENERIC_APPLY {
        name_idx := ast_a(node);
        first_an := ast_b(node);
        ac := ast_c(node);
        si := find_gsym(name_idx);
        if si < 0 || sym_kind(si) != SYM_TYPE { return TI_UNIT; }
        base_ti := sym_type(si);
        // 两趟（同 res_type_node 的泛型应用分支：实参解析会追加嵌套应用载荷）
        args : string, mut;
        if ac > 0 {
            args = alloc(ac * 8);
            ai : ., mut = 0;
            an : ., mut = first_an;
            loop {
                if ai >= ac { break; }
                w64(args, ai * 8, res_call_type(an, func_fi));
                ai = ai + 1;
                an = an + 1;
            }
        }
        // R2 P3 Task 5（Step 3）：调用位点的实例化检查（与 res_type_node 同源；本节的存在理由
        // = 调用位点的类型语法（形参/返回/字段）两侧都要覆盖——见 res_call_type 头注的域差）。
        gen_inst_constr_check(node, find_struct(name_idx), find_enum(name_idx), args, ac);
        ds := g_gen_apply_data_count;
        grow_gen_apply_data(ds + 1 + ac);
        w64(g_gen_apply_data, ds * 8, ac);
        ai2 : ., mut = 0;
        loop {
            if ai2 >= ac { break; }
            w64(g_gen_apply_data, (ds + 1 + ai2) * 8, r64(args, ai2 * 8));
            ai2 = ai2 + 1;
        }
        g_gen_apply_data_count = ds + 1 + ac;
        return alloc_type(TYP_GENERIC_APPLY, base_ti, ds);
    }
    if ast_kind(node) == EXPR_REFTYPE {
        inner := res_call_type(ast_a(node), func_fi);
        mf := ast_int_val(node);
        return alloc_type(TYP_REF, inner, mf);
    }
    if ast_kind(node) == EXPR_OPTIONAL {
        // R2 P3 Task 4：`T?` 在调用位点的解析（与 res_type_node 同语义；本函数只多一条
        // 泛型形参分支的差异，见函数头注——optional 分支两侧一致）。
        inner := res_call_type(ast_a(node), func_fi);
        return alloc_type(TYP_OPTIONAL, inner, 0);
    }
    return TI_UNIT;
}

fn unify_types(pattern: int, concrete: int) -> bool {
    if pattern == concrete { return true; }
    pk := get_type_kind(pattern);
    ck := get_type_kind(concrete);
    if pk < 0 || ck < 0 { return false; }
    if pk == TYP_GENERIC_PARAM {
        name_idx := get_type_data(pattern);
        mi : ., mut = 0;
        loop {
            if mi >= g_gen_map_count { break; }
            if r64(g_gen_map_names, mi * 8) == name_idx {
                // P3 Task 1 参序归一：源 = concrete（实参），目标 = 已绑定项
                return type_compat_strict(concrete, r64(g_gen_map_types, mi * 8)) == 1;
            }
            mi = mi + 1;
        }
        grow_gen_map(g_gen_map_count + 1);
        w64(g_gen_map_names, g_gen_map_count * 8, name_idx);
        w64(g_gen_map_types, g_gen_map_count * 8, concrete);
        g_gen_map_count = g_gen_map_count + 1;
        return true;
        return false;
    }
    if pk == TYP_GENERIC_APPLY && ck == TYP_GENERIC_APPLY {
        // P3 Task 1 参序归一：源 = concrete 基型，目标 = pattern 基型（两侧恒 TYP_NAMED ⇒ 方向面不可达）
        if type_compat_strict(get_type_data(concrete), get_type_data(pattern)) != 1 { return false; }
        ps := get_type_extra(pattern);
        cs := get_type_extra(concrete);
        pc := r64(g_gen_apply_data, ps * 8);
        cc := r64(g_gen_apply_data, cs * 8);
        if pc != cc { return false; }
        ai : ., mut = 0;
        loop {
            if ai >= pc { break; }
            if !unify_types(r64(g_gen_apply_data, (ps + 1 + ai) * 8), r64(g_gen_apply_data, (cs + 1 + ai) * 8)) { return false; }
            ai = ai + 1;
        }
        return true;
    }
    // P3 Task 1 参序归一：源 = concrete（实参），目标 = pattern（声明）
    return type_compat_strict(concrete, pattern) == 1;
}

fn substitute_return_type(ti: int) -> int {
    // Substitute generic params using g_gen_map
    if g_gen_map_count == 0 { return ti; }
    k := get_type_kind(ti);
    if k == TYP_GENERIC_PARAM {
        name_idx := get_type_data(ti);
        mi : ., mut = 0;
        loop {
            if mi >= g_gen_map_count { break; }
            if r64(g_gen_map_names, mi * 8) == name_idx { return r64(g_gen_map_types, mi * 8); }
            mi = mi + 1;
        }
        return ti;
    }
    if k == TYP_GENERIC_APPLY {
        base := get_type_data(ti);
        start := get_type_extra(ti);
        count := r64(g_gen_apply_data, start * 8);
        // 两趟（同 res_type_node：递归代换会追加嵌套应用载荷 ⇒ 先算进暂存再认领块）
        subs : string, mut;
        if count > 0 {
            subs = alloc(count * 8);
            ai : ., mut = 0;
            loop {
                if ai >= count { break; }
                w64(subs, ai * 8, substitute_return_type(r64(g_gen_apply_data, (start + 1 + ai) * 8)));
                ai = ai + 1;
            }
        }
        new_start := g_gen_apply_data_count;
        grow_gen_apply_data(new_start + 1 + count);
        w64(g_gen_apply_data, new_start * 8, count);
        ai2 : ., mut = 0;
        loop {
            if ai2 >= count { break; }
            w64(g_gen_apply_data, (new_start + 1 + ai2) * 8, r64(subs, ai2 * 8));
            ai2 = ai2 + 1;
        }
        g_gen_apply_data_count = new_start + 1 + count;
        return alloc_type(TYP_GENERIC_APPLY, base, new_start);
    }
    return ti;
}

fn infer_gen_call(fi: int, call_node: int, first_arg: int, arg_count: int) -> int {
    // Infer concrete types for a generic function call
    fn_node := fi_ast_node(fi);
    first_param := ast_b(fn_node);
    param_count := ast_c(fn_node);
    ret_type_node := ast_type_val(fn_node);

    g_gen_map_count = 0; g_gen_map_cap = 0;

    // First pass: infer arg types and build mapping
    pi : ., mut = 0;
    pn : ., mut = first_param;
    an : ., mut = first_arg;
    loop {
        if pi >= param_count || pi >= arg_count { break; }
        if pn < 0 || an < 0 { break; }

        orig_type_node := ast_data(pn);  // original param type node

        if orig_type_node >= 0 {
            pattern_ti := res_call_type(orig_type_node, fi);
            concrete_ti := infer_expr(ast_a(an));
            unify_types(pattern_ti, concrete_ti);
        } else {
            infer_expr(ast_a(an));
        }

        pi = pi + 1;
        // ─── R2 P3 Task 5（Step 1）：F4 形参链导航修复（TODO #2026-09-11-4）───
        // 旧态 `pn = pn + 1` 假设 EXPR_PARAM 在节点表里**连续**——不成立：每个形参的类型
        // 节点由 parse_type 在**该形参节点之前**分配（parser.cr 的 `pty := parse_type()` →
        // `alloc_node(EXPR_PARAM, …, pty, …)`），且**每个**类型（含基类型）都占一节点
        // （parse_type 尾部 `alloc_node(0,…,ty,0,…)`）⇒ 第 i+1 个形参不是 pn+1。
        // 实测症状（TODO #2026-09-11-4 原始探针的机制，本批实读）：`fn take[T](a: T, n: int)` 的
        // param1 落到 `int` 的类型节点上——`ast_data(基类型节点) = 0` ⇒ res_call_type(0) 读
        // **AST 节点 0**（= 本文件首个类型节点；若它恰是 `EXPR_IDENT(T)` 则回 gparam(T)）：
        // 非泛型形参的**声明类型约束**在调用推断中被绕过，且 gparam(T) 分支会给**未绑定**的
        // 形参凭空绑定 T（`fn take[T](n: int, a: T)` 场景）。
        // 修法 = 前扫到下一个 EXPR_PARAM（与 ir_gen.cr 的三处同款同因：:1481-1487 的 dex 参数
        // 对齐 / :2279-2285 的参数建 var / :2715 的 mono 克隆），扫到表尾置 -1（外循环 break）。
        pn = pn + 1;
        loop { if pn >= g_ast_count { pn = -1; break; } if ast_kind(pn) == EXPR_PARAM { break; } pn = pn + 1; }
        an = ast_b(an);  // next EXPR_ARG
    }

    // Check generic constraints (if any)
    gc := fi_generic_count(fi);
    if gc > 0 {
        gci : ., mut = 0;
        loop {
            if gci >= gc { break; }
            constr_idx := fi * MAX_GENERICS + gci;
            if constr_idx < g_generic_constr_count {
                iface_ni := r64(g_generic_constr, constr_idx * 8);
                if iface_ni >= 0 {
                    pname_ni := fi_generic_name(fi, gci);
                    concrete_ti : ., mut = -1;
                    hmi : ., mut = 0;
                    loop {
                        if hmi >= g_gen_map_count { break; }
                        if r64(g_gen_map_names, hmi * 8) == pname_ni {
                            concrete_ti = r64(g_gen_map_types, hmi * 8);
                            break;
                        }
                        hmi = hmi + 1;
                    }
                    if concrete_ti >= 0 {
                        // R2 P3 Task 5（Step 3）：先走**本质轴**引擎判定（约束名 = 原生/已声明
                        // 类型名时 `ty_sub(实参项, 约束项)` + 反例）；用户接口名 ⇒ 0 不在此直取
                        // （1 走提前返回；0/-1 落下方既有 check_iface 路径——**措辞/去重/rc 逐字
                        // 未动**，0 → 新措辞的诊断切换归 Task 6 Step 3；见 gen_constr_satisfied 注）。
                        if gen_constr_satisfied(iface_ni, concrete_ti) == 0 {
                            if gen_constr_seen_add(call_node * MAX_GENERICS + gci) != 0 {
                                gen_constr_raise(concrete_ti, iface_ni, ast_line(call_node), ast_col(call_node));
                            }
                        } else {
                        type_ni := get_type_name(concrete_ti);
                        if type_ni >= 0 {
                            ii := find_iface(iface_ni);
                            if ii >= 0 {
                                if !check_iface(type_ni, ii) {
                                    check_error(EC_TG_BOUND, "Type '" + istr_get(type_ni) + "' does not satisfy interface '" + istr_get(iface_ni) + "'", ast_line(call_node), ast_col(call_node));
                                }
                            }
                        }
                        }
                    }
                }
            }
            gci = gci + 1;
        }
    }

    // ─── R2 P3 Task 5（Step 4）：调用点**泛型绑定**登记（monomorph 实例键类型项化）───
    // 旧态 = 把「首个绑定的类型名」写进调用节点 int_val（唯一读者 `ir_gen.cr` 的
    // find_or_create_mono_func 是**死码**——零调用者；ir_gen 的实际实例键来自**实参 IR 变量
    // 的类型**，对命名/复合实参一律塌缩 "int" ⇒ 异型实例折叠 + 错替换）。新态 = 按**被调方
    // 泛型形参声明序**登记 ti 段（块 = [count, ti…]），节点 int_val = 块起始 + 1（**0 = 无**
    // ——parser 建 EXPR_CALL 时 iv 初值即 0，见 parser.cr 的 alloc_node(EXPR_CALL, …, 0, …)）。
    // ir_gen 据此生成规范实例键（inst_key_of_ti）并以 ti 型替换（monomorph.cr）；
    // 绑定全缺（g_gen_map_count == 0，如 T 只出现在返回型）⇒ 不写（0 = 回落旧名字路径）。
    if g_gen_map_count > 0 {
        gc_b := fi_generic_count(fi);
        if gc_b > 0 {
            bstart := g_gen_binds_count;
            grow_gen_binds(bstart + 1 + gc_b);
            w64(g_gen_binds, bstart * 8, gc_b);
            gi_b : ., mut = 0;
            loop {
                if gi_b >= gc_b { break; }
                pname_b := fi_generic_name(fi, gi_b);
                tv_b : ., mut = -1;
                hmi_b : ., mut = 0;
                loop {
                    if hmi_b >= g_gen_map_count { break; }
                    if r64(g_gen_map_names, hmi_b * 8) == pname_b {
                        tv_b = r64(g_gen_map_types, hmi_b * 8);
                        break;
                    }
                    hmi_b = hmi_b + 1;
                }
                w64(g_gen_binds, (bstart + 1 + gi_b) * 8, tv_b);
                gi_b = gi_b + 1;
            }
            g_gen_binds_count = bstart + 1 + gc_b;
            ast_set_int_val(call_node, bstart + 1);
        }
    }

    // Substitute return type
    if g_gen_map_count > 0 && ret_type_node >= 0 {
        resolved_ret := res_call_type(ret_type_node, fi);
        return substitute_return_type(resolved_ret);
    }

    // Fallback: look up from symbol table
    func_ni : ., mut = ast_a(fn_node);
    si := find_gsym(func_ni);
    if si >= 0 && sym_kind(si) == SYM_FN {
        return sym_type(si);
    }
    return TI_UNIT;
}

// --- check_func with generic param scope ---

fn check_func(fi: int) {
    g_checker_current_fi = fi;
    // Reset per-function borrow state
    g_borrow_count = 0; g_borrow_cap = 0;
    g_holder_count = 0; g_holder_cap = 0;
    g_borrow_scope_depth = 0; g_borrow_scope_markers_cap = 0;
    fn_node := fi_ast_node(fi);
    // Extern functions have no body to check — skip
    if ast_kind(fn_node) == EXPR_EXTERN { return; }
    name_idx := ast_a(fn_node);  // EXPR_FN: a = name idx
    first_param := ast_b(fn_node);  // EXPR_FN: b = first param node
    param_count := ast_c(fn_node);  // EXPR_FN: c = param count
    return_type := fi_return_type(fi);  // EXPR_FN: raw return TY_*, safe from hotpatch encoding
    body := ast_data(fn_node);  // EXPR_FN: data = body node

    push_scope();
    // Register generic params if any
    if fi_generic_count(fi) > 0 {
        gi : ., mut = 0;
        loop {
            if gi >= fi_generic_count(fi) { break; }
            gname_idx := r64(g_funcs, fi * ESZ_FUNCINFO + OFF_FI_GENERIC_NAMES + gi * 8);
            g_ti := alloc_type(TYP_GENERIC_PARAM, gname_idx, 0);
            def_sym(gname_idx, SYM_TYPE, g_ti, -1);
            gi = gi + 1;
        }
    }
    // Add params to scope
    pi : ., mut = 0;
    pn : ., mut = first_param;
    loop {
        if pi >= param_count { break; }
        if pn < 0 { break; }
        pname_idx := ast_a(pn);  // EXPR_PARAM: a = name idx
        self_mode := ast_int_val(pn);  // EXPR_PARAM: int_val = self mode (0=normal, 1=self, 2=&self, 3=&mut self, -1=variadic)
        if self_mode == -1 { pi = pi + 1; pn = pn + 1; continue; }
        ti : ., mut = TI_UNIT;
        if self_mode == 0 {
            // Regular param: resolve using original type node if it's non-base (named/generic)
            orig_type_node := ast_data(pn);
            if orig_type_node >= 0 && ast_kind(orig_type_node) != 0 {
                ti = res_type_node(orig_type_node);
            } else {
                // Base type: switch on type_val (TY_*)
                // P2b Task 6：值经单表 `ty_code_to_ti`；**本站点域 = {INT,DEX,BOOL,STRING,CHAR}**
                //   （缺 UNIT/NEVER/7——UNIT 缺不等于行为差：映射值 = 初值 TI_UNIT；NEVER 差异载荷，
                //   探针 F7 实测：`fn f(b: never)` 的形参符号类型 = unit（@raw_int 报 TF07））
                ptype := ast_type_val(pn);
                ptype_mapped := ty_code_to_ti(ptype);
                if ptype_mapped >= 0 && ptype_mapped != TI_NEVER && ptype_mapped != TI_DYN {
                    ti = ptype_mapped;
                }
            }
        } else {
            // Self param: derive struct type from mangled function name "Struct.method"
            fn_name := istr_get(fi_name(fi));
            fn_len := str_len(fn_name);
            dot_pos : ., mut = -1;
            di : ., mut = 0;
            loop {
                if di >= fn_len { break; }
                if load8(fn_name, di) == 46 { dot_pos = di; break; }  // '.' = 46
                di = di + 1;
            }
            if dot_pos > 0 {
                struct_name := str_sub(fn_name, 0, dot_pos);
                struct_ni := str_intern(struct_name);
                si := find_gsym(struct_ni);
                if si >= 0 && sym_kind(si) == SYM_TYPE {
                    struct_ti := sym_type(si);
                    if self_mode == 1 {
                        // self by value
                        ti = struct_ti;
                    } else {
                        // &self (mode 2) or &mut self (mode 3)
                        mut_flag := 0;
                        if self_mode == 3 { mut_flag = 1; }
                        ti = alloc_type(TYP_REF, struct_ti, mut_flag);
                    }
                }
            }
        }
        def_sym(pname_idx, SYM_PARAM, ti, -1);
        pi = pi + 1;
        // Params are not contiguous — type nodes are allocated between them
        pn = pn + 1;
        loop {
            if pn >= g_ast_count { break; }
            if ast_kind(pn) == EXPR_PARAM { break; }
            pn = pn + 1;
        }
    }
    // Check body
    if body >= 0 {
        body_ti := infer_expr(body);
        ret_ti : ., mut = TI_UNIT;
        // First check for named type via the stored type node (kind != 0)
        type_node := ast_type_val(fn_node);
        if type_node > 0 && ast_kind(type_node) != 0 {
            ret_ti = res_type_node(type_node);
        } else {
            // P2b Task 6：值经单表 `ty_code_to_ti`；**本站点域 = {INT..CHAR}**（含 NEVER；缺 7——
            //   探针 F11：`fn f() -> dyn` 的体检查用 unit 兜底，与 F10 的 never 格互不干扰）
            ret_ti_mapped := ty_code_to_ti(return_type);
            if ret_ti_mapped >= 0 && ret_ti_mapped != TI_DYN { ret_ti = ret_ti_mapped; }
        }
        compat := type_compat_strict(body_ti, ret_ti);
        // 落空分析（TF01 收口，见 stmt_cannot_fall_through 头注）：体确定不能落空（如以
        // 无 break 的 loop 收尾）⇒ 「块类型 = 末语句类型」推出的 unit 不是缺返回值的证据，
        // 等价于 never 格（与下行既有 TI_NEVER 豁免同路）。
        if compat != 1 && body_ti != TI_NEVER && stmt_cannot_fall_through(body) == 0 {
            // Skip check if return type is generic param (can't verify at declaration)
            // Skip check for flow functions (yield instead of return)
            is_flow_fn : ., mut = 0;
            if body >= 0 && scan_for_yield(body) != 0 { is_flow_fn = 1; }
            if !is_flow_fn && get_type_kind(ret_ti) != TYP_GENERIC_PARAM {
                diag_type_incompatible(compat, EC_TF_RETURN, "Function return type mismatch", ast_line(fn_node), ast_col(fn_node));
            }
        }
    }
    // 批 6（T3）：规约标注面——**在 pop_scope 之前**（形参仍在作用域内，`#check(a > 0)` 才能定型）
    spec_check_func(fn_node, return_type);
    pop_scope();
}

// 批 6（T3）：**每函数标注检查** —— bool 型 + `#ensure` 的 `result` 域 + C1 子集（禁调用）。
// 时点 = `check_func` 尾部（形参已入作用域）；`result` 用**嵌套作用域**绑定 ⇒ 不泄进函数体。
// 三态纪律：`infer_expr` 给不出 bool（含未覆盖面）⇒ 一律 **V05 硬错**（**不得**「未知当通过」）。
// 域检查的第二重来源 = `infer_expr` 对未定义名的既有诊断（N06/N01，build 面非豁免 ⇒ 阻断）。
fn spec_check_func(fn_node: int, return_type: int) {
    if g_spec_count == 0 { return; }
    hit : ., mut = 0;
    i : ., mut = 0;
    loop {
        if i >= g_spec_count { break; }
        if spec_fnode(i) == fn_node { hit = 1; break; }
        i = i + 1;
    }
    if hit == 0 { return; }
    push_scope();
    // `#ensure` 的 `result` 绑定（裁-S8）：与既有作用域名冲突 ⇒ **硬错**（不静默择一、不静默遮蔽）
    // ⚠ **零足迹纪律**：`str_intern("result")` **只能在确需绑定时调用**——无条件调用会让
    // STR 段凭空 +10B（T3 首轮被 Δ 判据当场抓住：d0 用例期望 Δ=0、实测 10；根因即此）。
    ri : ., mut = -1;
    j : ., mut = 0;
    loop {
        if j >= g_spec_count { break; }
        if spec_fnode(j) == fn_node && spec_kind(j) == 1 { ri = j; break; }
        j = j + 1;
    }
    if ri >= 0 {
        res_ni := str_intern("result");
        if find_sym(res_ni) >= 0 {
            spec_set_status(ri, SPEC_ST_RED);
            check_error(EC_V_RESULT_SHADOW,
                "'result' is already bound in this scope (#ensure binding would shadow it)",
                spec_line(ri), spec_col(ri));
        } else {
            def_sym(res_ni, SYM_LOCAL, ty_code_to_ti(return_type), -1);
        }
    }
    // 逐条：① 禁调用（裁-V5 的 C1 子集；避开纯度时序坑——本批**未**解决该时序，只绕开）
    //       ② 表达式必须恰为 bool
    k : ., mut = 0;
    loop {
        if k >= g_spec_count { break; }
        if spec_fnode(k) == fn_node {
            if spec_has_call(spec_expr(k)) != 0 {
                spec_set_status(k, SPEC_ST_RED);
                check_error(EC_V_CALL_BANNED,
                    "annotation expression must not contain calls (C1 subset)",
                    spec_line(k), spec_col(k));
            } else {
                t := infer_expr(spec_expr(k));
                if t != TI_BOOL {
                    spec_set_status(k, SPEC_ST_RED);
                    check_error(EC_V_NOT_BOOL, "annotation expression must be bool",
                        spec_line(k), spec_col(k));
                }
            }
        }
        k = k + 1;
    }
    pop_scope();
}

// 标注表达式的**调用扫描**（C1 子集：禁调用）。只走 C1 允许的节点形（字面量/标识符/一元/二元），
// 遇到调用即返回 1；未知节点形 = 不判定（返回 0，由 bool 型那一关兜住）。
fn spec_has_call(e: int) -> int {
    if e < 0 { return 0; }
    k := ast_kind(e);
    if k == EXPR_CALL { return 1; }
    if k == EXPR_BINARY {
        if spec_has_call(ast_a(e)) != 0 { return 1; }
        return spec_has_call(ast_b(e));
    }
    if k == EXPR_UNARY { return spec_has_call(ast_a(e)); }
    return 0;
}

fn check_impl_for() {
    pi : ., mut = 0;
    loop {
        if pi >= g_impl_for_count { break; }
        iface_ni := r64(g_impl_for, pi * 16);
        type_ni := r64(g_impl_for, pi * 16 + 8);
        // Find interface by name
        ii := find_iface(iface_ni);
        if ii < 0 {
            iface_name := istr_get(iface_ni);
            check_error(EC_N_UNDEFINED, "Undefined interface '" + iface_name + "'", 0, 0);
            pi = pi + 1;
            continue;
        }
        method_count := r64(g_ifaces, ii * ESZ_IFACEINFO + OFF_IF_METHOD_COUNT);
        mi : ., mut = 0;
        loop {
            if mi >= method_count { break; }
            mbase := ii * ESZ_IFACEINFO + OFF_IF_METHODS + mi * ESZ_IFMETHOD;
            method_ni := r64(g_ifaces, mbase + OFF_IFM_NAME);
            method_pc := r64(g_ifaces, mbase + OFF_IFM_PARAM_COUNT);
            method_name := istr_get(method_ni);
            iface_name2 := istr_get(iface_ni);

            // R2 P3b Task 6（Step 3，mangling 退役）：方法解析 = **表查询**
            // （`g_methods` 三元组 → 函数名 ni → 函数行），不再拼 "Type.method" 串。
            func_ni := iface_find_method(type_ni, method_ni);
            fi : ., mut = -1;
            if func_ni >= 0 { fi = find_func(func_ni); }
            if fi < 0 {
                check_error(EC_TF_METHOD_NOT_FOUND, "Impl missing method '" + method_name + "' for interface '" + iface_name2 + "'", 0, 0);
                mi = mi + 1;
                continue;
            }
            // 接收者模式（调用约定维度；旧态两侧皆码 0 ⇒ 不可比 ⇒ 本任务起显式比较）
            if sh_iface_self_mode(ii, mi) != sh_func_self_mode(fi) {
                check_error(EC_TF_METHOD_ARG_TYP, "Param 1 type mismatch for method '" + method_name + "' in interface '" + iface_name2 + "'", 0, 0);
            }
            // 参数计数
            actual_pc := fi_param_count(fi);
            if actual_pc != method_pc {
                check_error(EC_TF_METHOD_ARG_CNT, "Param count mismatch for method '" + method_name + "': expected " + int_str(method_pc) + " got " + int_str(actual_pc), 0, 0);
            }
            // 逐参类型（**签名项**比较：N 不入项 / 泛型应用展开 / 命名行按名 —— 取代旧裸码相等）
            pti : ., mut = 0;
            loop {
                if pti >= method_pc || pti >= MAX_IFACE_METHOD_PARAMS { break; }
                apt := sh_func_sig_param_term(fi, pti);
                ept := sh_iface_sig_param_term(ii, mi, pti);
                if apt >= 0 && ept >= 0 {
                    // 判定 = 引擎的不变槽结构比较原语（0/1 全域；理由见 type_engine.cr 的
                    // iface_user_satisfies_ii 注——ty_sub 会把「确定不同」上抛为 -1 = 未覆盖面）
                    if tt_list_same(apt, ept) != 1 {
                        pnum_str := int_str(pti + 1);
                        check_error(EC_TF_METHOD_ARG_TYP, "Param " + pnum_str + " type mismatch for method '" + method_name + "' in interface '" + iface_name2 + "'", 0, 0);
                    }
                }
                pti = pti + 1;
            }
            // 返回类型（签名项比较；同上）
            art := sh_func_sig_ret_term(fi);
            ert := sh_iface_sig_ret_term(ii, mi);
            if art >= 0 && ert >= 0 {
                if tt_list_same(art, ert) != 1 {
                    check_error(EC_TF_RETURN, "Return type mismatch for method '" + method_name + "' in interface '" + iface_name2 + "'", 0, 0);
                }
            }
            mi = mi + 1;
        }
        pi = pi + 1;
    }
}

fn check_global_let(node: int) {
    val_node := ast_c(node);  // EXPR_LET: c = value
    type_node := ast_b(node); // EXPR_LET: b = 注解类型节点（-1 = 无）
    val_ti := TI_UNIT;
    if val_node >= 0 {
        val_ti = infer_expr(val_node);
    }
    // R2 P5 Task 6（TODO #2026-09-11-14）：全局初始化器的值/注解兼容检查（局部站点同款；
    // 全局符号类型在注册趟（check_global_lets）即取注解行 ⇒ 不查同样静默错产物）。
    ti := val_ti;
    if type_node >= 0 { ti = res_type_node(type_node); }
    check_let_annot_compat(node, val_node, val_ti, ti);
}

// --- Dynamic type set tracking ---

fn grow_dyn_type_sets(needed: int) {
    if needed < g_dyn_type_set_cap { return; }
    nc : ., mut = g_dyn_type_set_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 8); _dyncpy(g_dyn_type_sets, g_dyn_type_set_cap * 8, nb);
    g_dyn_type_sets = nb; g_dyn_type_set_cap = nc;
}

fn dyn_set_type(var_idx: int, ti: int) {
    grow_dyn_type_sets(var_idx + 1);
    old_bits := r64(g_dyn_type_sets, var_idx * 8);
    bit : ., mut = 1;
    if ti >= 0 && ti < 64 {
        bit = 1; shl := ti; loop { if shl <= 0 { break; } bit = bit * 2; shl = shl - 1; }
    }
    w64(g_dyn_type_sets, var_idx * 8, old_bits + bit);
    if var_idx >= g_dyn_type_set_count { g_dyn_type_set_count = var_idx + 1; }
}

fn dyn_has_type(var_idx: int, ti: int) -> int {
    if var_idx < 0 || var_idx >= g_dyn_type_set_count { return 0; }
    set := r64(g_dyn_type_sets, var_idx * 8);
    bit : ., mut = 1;
    if ti >= 0 && ti < 64 {
        bit = 1; shl := ti; loop { if shl <= 0 { break; } bit = bit * 2; shl = shl - 1; }
    }
    if (set / bit) % 2 != 0 { return 1; }
    return 0;
}

fn union_bitmaps(a: int, b: int) -> int {
    r : ., mut = 0;
    pos : ., mut = 0;
    loop {
        if pos >= 64 { break; }
        bit : ., mut = 1;
        shl := pos;
        loop { if shl <= 0 { break; } bit = bit * 2; shl = shl - 1; }
        if (a / bit) % 2 != 0 || (b / bit) % 2 != 0 { r = r + bit; }
        pos = pos + 1;
    }
    return r;
}

fn validate_dyn_method(si: int, method_ni: int, line: int, col: int) {
    if si < 0 || si >= g_dyn_type_set_count { return; }
    set := r64(g_dyn_type_sets, si * 8);
    if set == 0 { return; }
    ti : ., mut = 0;
    loop {
        if ti >= g_type_count { break; }
        if ti >= 64 { break; }
        bit : ., mut = 1;
        shl := ti;
        loop { if shl <= 0 { break; } bit = bit * 2; shl = shl - 1; }
        if (set / bit) % 2 != 0 {
            type_ni := get_type_name(ti);
            if type_ni >= 0 {
                if !type_has_method(type_ni, method_ni) {
                    tname := istr_get(type_ni);
                    mname := istr_get(method_ni);
                    check_error(EC_N_METHOD, "dyn: method '" + mname + "' not found on type '" + tname + "'", line, col);
                }
            }
        }
        ti = ti + 1;
    }
}

// --- Type inference ---

// 推实参（TODO #2026-09-16-31「已解析直调的实参推断缺失」修复）：EXPR_CALL 的**所有**「已解析」
// 路径在 return 之前**必须**调用本函数——否则实参表达式**完全不被类型检查**，后果两重：
//   ① 实参位的内层调用若是 `EXPR_FIELD` 被调（方法/模块限定），其 `ast_data`（被调名索引）
//      只能由 `infer_expr` 的模块/方法分支回填 ⇒ 从没回填 ⇒ 保持 parser 初值 0 ⇒ ir_gen 读
//      `istr_get(0)` = 文件首个 interned 串（有 `import` 时恰为 "import"）⇒ 后端查不到 ⇒ **SIGSEGV 139**；
//   ② 实参里的未定义函数/变量、常量越界**静默通过**（零诊断）。
// 调用点（4 处，完备性枚举见计划 §3ter）：`:2811`（never 返回型）· `:2817`（已注册 Core fn，
// 主病灶）· `:2824`（runtime builtin）· `:2831`（EC_N_FUNC 未定义函数）；函数尾的
// `func_ni < 0` 路径本就用同一循环（已改为调用本函数，单一真源）。
// 注：泛型直调（`:2791` → `infer_gen_call`）内部**已推**（`:2020`/`:2023`），无需在此重复。
fn infer_call_args(first_arg: int) {
    an : ., mut = first_arg;
    loop {
        if an < 0 { break; }
        anode := ast_a(an);
        infer_expr(anode);
        // (b) fail-closed 护栏（维护者裁-ARG-2；TODO #2026-09-16-31）：实参位的调用若是 `EXPR_FIELD`
        // 被调而 `ast_data` 仍为 0 ⇒ **被调名从未被回填**（模块/方法分支没跑到）⇒ ir_gen 会读出
        // 伪函数名（`istr_get(0)` = 文件首个 interned 串，有 `import` 时恰为 "import"）⇒ 后端
        // 按名解析失败 ⇒ 外部位重定向 ⇒ **SIGSEGV 139**。
        // 此处**响亮拒绝**（硬错 ⇒ 走既有 fail-closed 闸门 ← `main.cr:146-175` 位于 check_all
        // 之后、ir_gen 之前 ⇒ 在 checker 侧报错才被该闸门覆盖），**绝不静默产坏产物**。
        // **正常路径下恒不触发**（(a) 已让所有已解析路径推实参；dyn 方法调用的名字由 dyn 分支
        // 回填，实测 `dyn_dispatch` 正常 ⇒ 不误伤）——其价值 = **防未来同类回归**。
        if anode >= 0 {
            if ast_kind(anode) == EXPR_CALL {
                fnode := ast_a(anode);
                if fnode >= 0 {
                    if ast_kind(fnode) == EXPR_FIELD {
                        if ast_data(anode) <= 0 {
                            check_error(EC_N_FUNC, "Unresolved module/method call in argument position", ast_line(anode), ast_col(anode));
                        }
                    }
                }
            }
        }
        an = ast_b(an);
    }
}

fn infer_expr(node: int) -> int {
    if node < 0 { return TI_UNIT; }


    // R2 P2b Task 3：字面量定型 → 本质条目表查表（唯一真源 = iface_registry.cr 的 lit_code 列）。
    // 改动前 = 本处 5 条内联 if（`return TI_INT/TI_DEX/TI_STR/TI_BOOL/TI_CHAR`，计划时点
    // checker.cr:1892-1897 → 现址 :1896-1901，偏移 +4）**逐格转录**进表；5 个 kind 的判断
    // 顺序与短路行为**逐字保持**——EXPR_NONE 转发行仍夹在 EXPR_INT 与 EXPR_DEX 之间，
    // **不得**重排、**不得**合并成「先取 kind 再查」的循环（那会改短路面）。
    if ast_kind(node) == EXPR_INT { return iface_lit_ti(EXPR_INT); }
    if ast_kind(node) == EXPR_NONE && ast_a(node) >= 0 && ast_a(node) != node { return infer_expr(ast_a(node)); }
    if ast_kind(node) == EXPR_DEX { return iface_lit_ti(EXPR_DEX); }
    if ast_kind(node) == EXPR_STRING { return iface_lit_ti(EXPR_STRING); }
    if ast_kind(node) == EXPR_BOOL { return iface_lit_ti(EXPR_BOOL); }
    if ast_kind(node) == EXPR_CHAR { return iface_lit_ti(EXPR_CHAR); }

    if ast_kind(node) == EXPR_IDENT {
        name_idx := ast_int_val(node);
        // Borrow check: can't use variable while it's borrowed
        if !check_use(name_idx) {
            name := istr_get(name_idx);
            check_error(EC_B_USE_WHILE_BORROWED, "Cannot use '" + name + "' while it is borrowed", ast_line(node), ast_col(node));
        }
        si := find_sym(name_idx);
        if si >= 0 { return sym_type(si); }
        name := istr_get(name_idx);
        check_error(EC_N_UNDEFINED, "Undefined name '" + name + "'", ast_line(node), ast_col(node));
        return TI_NEVER;
    }
    if ast_kind(node) == EXPR_NONE {
        // Wrapper node in struct literal: forward to inner expression
        if ast_a(node) >= 0 && ast_a(node) != node { return infer_expr(ast_a(node)); }
        return TI_UNIT;
    }

    if ast_kind(node) == EXPR_BINARY {
        left := ast_a(node);
        right := ast_b(node);
        op := ast_c(node);
        // R2 P5 Task 4（D25）：`EXPR_BINARY + OP_ASSIGN` 分支**已删**（站点 6 随之退役——
        // 其挂点在本分支内）。不可达三面证明：① `tok2op`（parser.cr）不产 OP_ASSIGN；
        // ② `T_EQ` → `EXPR_ASSIGN`（parser.cr）；③ `+=` 族显式构造 `EXPR_ASSIGN` 包裹的
        // `EXPR_BINARY` 且 op ∈ {ADD,SUB,MUL,DIV} ⇒ 全仓无生产者（含 opt/pass 面）。
        // 实证：全语料 shadow 站点直方图 `assign-binary=0`（32988 次判定）。**赋值判定点
        // = 站点 8（EXPR_ASSIGN，见 infer_expr 的 EXPR_ASSIGN 分支）**，逐字保留。
        lt := infer_expr(left);
        rt := infer_expr(right);
        if op == OP_ADD || op == OP_SUB || op == OP_MUL || op == OP_DIV || op == OP_MOD {
            // String concatenation for OP_ADD
            if op == OP_ADD && (lt == TI_STR || rt == TI_STR) { return TI_STR; }
            // Pointer arithmetic: *T + n or n + *T → *T
            if (op == OP_ADD || op == OP_SUB) && (get_type_kind(lt) == TYP_PTR && rt == TI_INT) {
                return lt;  // return the pointer type unchanged
            }
            if (op == OP_ADD || op == OP_SUB) && (lt == TI_INT && get_type_kind(rt) == TYP_PTR) {
                return rt;
            }
            // Pointer difference: *T - *T → int
            if op == OP_SUB && get_type_kind(lt) == TYP_PTR && get_type_kind(rt) == TYP_PTR {
                return TI_INT;
            }
            // Check: arithmetic ops require int or dex —— R2 P2b Task 4：查表（门形状 = ANY：
            // 「至少一侧许可即通过」，与改动前的 `&&` 形状一字等价）。转录依据 = 本处改动前的
            // `lt != TI_INT && lt != TI_DEX && rt != TI_INT && rt != TI_DEX`；表的 ADD..MOD 格
            // **只含 int/dex**（PTR/STRING 不在内——早退规则 :1946/:1948/:1951/:1955（接线前实测
            // 行号；接线后本块 +4）仍在原处 = 结果规则，不进本门）。负控（须仍报 error[TB01]）：
            // `*T + *T`、`"a" - "b"`。
            if iface_permits(iface_kind_of(lt), op) == 0 && iface_permits(iface_kind_of(rt), op) == 0 {
                check_error(EC_TB_ADD, "Arithmetic operation requires int or dex", ast_line(node), ast_col(node));
            }
            if lt == TI_DEX || rt == TI_DEX { return TI_DEX; }
            return TI_INT;
        }
        if op == OP_EQ || op == OP_NE || op == OP_LT || op == OP_GT || op == OP_LE || op == OP_GE {
            return TI_BOOL;
        }
        if op == OP_AND || op == OP_OR {
            // R2 P2b Task 4：查表（门形状 = ALL「每侧都须许可」）。转录依据 = 本处改动前的
            // `lt != TI_BOOL && lt != TI_INT || rt != TI_BOOL && rt != TI_INT`（= 某侧「非 bool 且
            // 非 int」即报错）；谓词写 OP_AND（**不另设** IP_LOGIC——OP_AND/OP_OR 在表中同步置位，
            // 且现状 :1969 对两个 op 一字不分）。表的 AND/OR 格恰 {int, bool}——**dex 不在内**
            // （`1.5 && true` 现状 error[TC01]，探针 N7 实测）。
            if iface_permits(iface_kind_of(lt), OP_AND) == 0 || iface_permits(iface_kind_of(rt), OP_AND) == 0 {
                check_error(EC_TC_IF_COND, "Logical operator requires bool or int operands", ast_line(node), ast_col(node));
            }
            return TI_BOOL;
        }
        return TI_INT;
    }

    if ast_kind(node) == EXPR_UNARY {
        op := ast_c(node);
        if op == UOP_NEG || op == UOP_NOT {
            return infer_expr(ast_a(node));
        }
        if op == UOP_REF {
            operand := ast_a(node);
            is_mut := ast_int_val(node);
            inner : ., mut = TI_UNIT;
            if ast_kind(operand) == EXPR_IDENT {
                vi := ast_int_val(operand);
                if !check_borrow(vi, is_mut) {
                    name := istr_get(vi);
                    if is_mut != 0 {
                        check_error(EC_B_BORROW_MUT, "Cannot borrow '" + name + "' as mutable, already borrowed", ast_line(node), ast_col(node));
                    } else {
                        check_error(EC_B_BORROW_IMMUT, "Cannot borrow '" + name + "' as immutable, already mutably borrowed", ast_line(node), ast_col(node));
                    }
                }
                si := find_sym(vi);
                if si >= 0 { inner = sym_type(si); }
            } else {
                inner = infer_expr(operand);
            }
            return alloc_type(TYP_PTR, inner, 0);
        }
        if op == UOP_DEREF {
            inner := infer_expr(ast_a(node));
            if get_type_kind(inner) == TYP_REF {
                return get_type_data(inner);
            }
            if get_type_kind(inner) == TYP_PTR {
                return get_type_data(inner);
            }
            if get_type_kind(inner) == TYP_GENERIC_PARAM {
                return inner;
            }
            return inner;
        }
        return infer_expr(ast_a(node));
    }

    if ast_kind(node) == EXPR_CALL {
        func_node := ast_a(node);
        first_arg := ast_b(node);
        arg_count := ast_c(node);
        func_ni : ., mut = -1;

        // Method call: obj.method(args)  or  module.func(args)
        if ast_kind(func_node) == EXPR_FIELD {
            obj := ast_a(func_node);
            method_ni := ast_int_val(func_node);

            // Module-qualified call: module.func(args)
            mod_call_done : ., mut = 0;
            mod_found_mfi : ., mut = -1;
            if ast_kind(obj) == EXPR_IDENT {
                mod_name_ni := ast_int_val(obj);
                si := find_sym(mod_name_ni);
                if si >= 0 && sym_kind(si) == SYM_MODULE {
                    fileid_ni := sym_type(si);
                    // Look up (fileid, method) in module function table
                    mfi : ., mut = 0;
                    loop {
                        if mfi >= g_mod_func_count { break; }
                        if r64(g_mod_func_fileids, mfi * 8) == fileid_ni && r64(g_mod_func_names, mfi * 8) == method_ni {
                            func_ni = r64(g_mod_func_names, mfi * 8);
                            ast_set_data(node, func_ni);
                            call_flags := ast_type_val(node);
                            if call_flags == CALL_FLAG_INLINE {
                                ast_set_type_val(node, CALL_FLAG_MODULE + CALL_FLAG_INLINE);
                            } else {
                                ast_set_type_val(node, CALL_FLAG_MODULE);
                            }
                            mod_call_done = 1;
                            mod_found_mfi = mfi;
                            break;
                        }
                        mfi = mfi + 1;
                    }
                }
            }
            if mod_call_done == 1 {
                // Infer arg types
                an : ., mut = first_arg;
                loop {
                    if an < 0 { break; }
                    infer_expr(ast_a(an));
                    an = ast_b(an);
                }
                if mod_found_mfi >= 0 {
                    return r64(g_mod_func_tis, mod_found_mfi * 8);
                }
                return TI_UNIT;
            }

            obj_ti := infer_expr(obj);
            // --- Dyn method validation ---
            if obj_ti == TI_DYN {
                if ast_kind(obj) == EXPR_IDENT {
                    obj_ni := ast_int_val(obj);
                    obj_si := find_sym(obj_ni);
                    if obj_si >= 0 {
                        validate_dyn_method(obj_si, method_ni, ast_line(node), ast_col(node));
                    }
                }
                // Infer arg types (for side effects)
                an_dyn : ., mut = first_arg;
                loop {
                    if an_dyn < 0 { break; }
                    infer_expr(ast_a(an_dyn));
                    an_dyn = ast_b(an_dyn);
                }
                return TI_UNIT;
            }
            lookup_ti : ., mut = obj_ti;
            // Unwrap generic apply to base type
            if lookup_ti >= 0 && lookup_ti < g_type_count && get_type_kind(lookup_ti) == TYP_GENERIC_APPLY {
                lookup_ti = get_type_data(lookup_ti);
            }
            if lookup_ti >= 0 && lookup_ti < g_type_count && get_type_kind(lookup_ti) == TYP_NAMED {
                struct_ni := get_type_data(lookup_ti);
                // Look up method in method table
                mi : ., mut = 0;
                loop {
                    if mi >= g_method_count { break; }
                    if r64(g_methods, mi * 24) == struct_ni && r64(g_methods, mi * 24 + 8) == method_ni {
                        func_ni = r64(g_methods, mi * 24 + 16);
                        ast_set_data(node, func_ni);
                        break;
                    }
                    mi = mi + 1;
                }
            }
            // Generic param method call resolution
            if func_ni < 0 && get_type_kind(lookup_ti) == TYP_GENERIC_PARAM {
                gen_ni := get_type_data(lookup_ti);
                gc2 := fi_generic_count(g_checker_current_fi);
                gci2 : ., mut = 0;
                loop {
                    if gci2 >= gc2 { break; }
                    gname_idx2 := r64(g_funcs, g_checker_current_fi * ESZ_FUNCINFO + OFF_FI_GENERIC_NAMES + gci2 * 8);
                    if gname_idx2 == gen_ni {
                        constr_idx2 := g_checker_current_fi * MAX_GENERICS + gci2;
                        if constr_idx2 < g_generic_constr_count {
                            iface_ni2 := r64(g_generic_constr, constr_idx2 * 8);
                            if iface_ni2 >= 0 {
                                ii2 := find_iface(iface_ni2);
                                if ii2 >= 0 {
                                    imc2 := r64(g_ifaces, ii2 * ESZ_IFACEINFO + OFF_IF_METHOD_COUNT);
                                    imi2 : ., mut = 0;
                                    loop {
                                        if imi2 >= imc2 { break; }
                                        imbase2 := ii2 * ESZ_IFACEINFO + OFF_IF_METHODS + imi2 * ESZ_IFMETHOD;
                                        if r64(g_ifaces, imbase2 + OFF_IFM_NAME) == method_ni {
                                            // R2 P3b Task 6（Step 3，mangling 退役）：不再合成 "T.m"
                                            //   串——调用点记（**泛型形参名 ni**，标记位），实例化
                                            //   时由 monomorph 按具体类型查方法表解析为真实函数名
                                            //   （对照 gen_clone_tree 的 EXPR_CALL 分支与 ast.cr 的
                                            //   CALL_FLAG_IFACE_METHOD 注）。旧态 = 名字拼接 + 克隆
                                            //   期文本替换 ⇒ 实例体内调用目标悬空（实测产物运行
                                            //   rc=139）；本任务起表查询（同 iface_find_method）。
                                            ast_set_data(node, gen_ni);
                                            ast_set_type_val(node, CALL_FLAG_IFACE_METHOD);
                                            iface_ret2 := r64(g_ifaces, imbase2 + OFF_IFM_RET_TI);
                                            // P2b Task 6：值经单表 `ty_code_to_ti`；本站点值域 = parser 写入的
                                            //   `unpack_type(返回型节点)`（parser.cr:1701，即 TY_* 码）；**域 = {INT..CHAR}**
                                            //   （缺 NEVER/7 ⇒ 落尾 TI_UNIT）。**显式化**：现状 6 行用的是 `iface_ret2 == TY_*`
                                            //   而值域是 TI_*，靠「TY_INT==TI_INT==0 … TY_CHAR==TI_CHAR==6」的数值撞车成立，
                                            //   合一后改按语义查表（探针 F13：`-> never` 的 iface 方法在调用点 = unit；
                                            //   F14：`-> char` = char）。
                                            iface_ret_ti := ty_code_to_ti(iface_ret2);
                                            if iface_ret_ti >= 0 && iface_ret_ti != TI_NEVER && iface_ret_ti != TI_DYN {
                                                func_ni = gen_ni;
                                                return iface_ret_ti;
                                            }
                                            func_ni = gen_ni; return TI_UNIT;
                                        }
                                        imi2 = imi2 + 1;
                                    }
                                }
                            }
                        }
                        break;
                    }
                    gci2 = gci2 + 1;
                }
            }
            // Infer arg types (walk EXPR_ARG chain)
            an : ., mut = first_arg;
            loop {
                if an < 0 { break; }
                infer_expr(ast_a(an));
                an = ast_b(an);
            }
            if func_ni >= 0 {
                si := find_gsym(func_ni);
                if si >= 0 && sym_kind(si) == SYM_FN {
                    // R2 P6 Task 4a（E-11，姊妹站点）：与直调站点守卫同形——
                    //   `func_ni` = parser impl 分支写入的 mangled ni（"S.m"，
                    //   parser.cr:1887-1894）⇒ 与直调面同一张 g_funcs/符号表，
                    //   `fi_return_type`/`sym_type` 语义逐位同。差异一处（显式对齐）：
                    //   本尾无泛型早退（直调面走 `infer_gen_call`）⇒ 补
                    //   `fi_generic_count == 0` 守卫，使泛型面两站点一致**不动**
                    //   （参数化方法的返回型依实例化）。本面恒无 extern（impl 分支
                    //   只认 `fn`，parser.cr:1864-1899）⇒ 不需 EXPR_FN 限定
                    //   （行为等价，非逐字镜像）。嵌套 if 同直调站点（`&&` 不短路 +
                    //   表读无护栏）。
                    fi_m := find_func(func_ni);
                    if fi_m >= 0 {
                        if fi_generic_count(fi_m) == 0 {
                            if sym_type(si) == TI_UNIT {
                                if fi_return_type(fi_m) == TY_NEVER {
                                    return TI_NEVER;
                                }
                            }
                        }
                    }
                    return sym_type(si);
                }
            }
            return TI_UNIT;
        }

        // Determine function name and return type
        if ast_kind(func_node) == EXPR_IDENT {
            func_ni = ast_int_val(func_node);
        }
        // @builtin(args) — transfer args from EXPR_CALL to EXPR_AT, then delegate
        if ast_kind(func_node) == EXPR_AT {
            ast_set_b(func_node, first_arg);
            return infer_expr(func_node);
        }
        // Check builtins (syscall3/syscall4 — OS communication, no .cr body)
        if func_ni >= 0 {
            s := istr_get(func_ni);
            if s == "syscall3" { return TI_INT; }
            if s == "syscall4" { return TI_INT; }
        }
        // Check for SYM_SO_FN (.so extension registered)
        so_fn_fi : ., mut = -1;
        if func_ni >= 0 {
            si := find_gsym(func_ni);
            if si >= 0 && sym_kind(si) == SYM_SO_FN {
                so_fn_fi = si;
                tag_flags2 := sym_type(si);  // stores tag_flags
                type_enc2 := sym_node(si);   // stores type encoding

                // Infer arg types (walk EXPR_ARG chain)
                an : ., mut = first_arg;
                loop {
                    if an < 0 { break; }
                    infer_expr(ast_a(an));
                    an = ast_b(an);
                }

                // Decode return type (type_enc2 % 100)
                ret_code2 : ., mut = type_enc2 - (type_enc2 / 100) * 100;
                // Map back to TI_*
                if ret_code2 == 0 { return TI_INT; }
                if ret_code2 == 1 { return TI_STR; }
                if ret_code2 == 2 { return TI_UNIT; }
                if ret_code2 == 3 { return TI_DEX; }
                if ret_code2 == 4 { return TI_BOOL; }
                return TI_UNIT;
            }
        }
        // Look up function
        if func_ni >= 0 && so_fn_fi < 0 {
            si := find_gsym(func_ni);
            if si >= 0 && sym_kind(si) == SYM_FN {
                // Check if generic function
                fi := find_func(func_ni);
                if fi >= 0 && fi_generic_count(fi) > 0 {
                    return infer_gen_call(fi, node, first_arg, arg_count);
                }
                // R2 P6 Task 4a（E-11）：被调**非泛型 `fn` 声明**的返回行 = `never`
                //   ⇒ 调用推断 `never`。声明注册趟把 NEVER 钳成 unit（collect_decls 的
                //   域守卫 :1491：`rt_mapped != TI_NEVER`）⇒ 此处按裸码 `fi_return_type`
                //   复读一次；两处下游闸随之生效：声明位 `check_let_annot_compat` 豁免③
                //   （:526）/ 返回位（:2234）。**只改推断结果**：`sym_type(si)` 值不动
                //   ⇒ 发射面零耦合（ir_gen 的调用结果型经 sym_type，见 ir_gen.cr:1662）。
                //   守卫四条：① 泛型已由上方早退排除；② 仍是被钳的 unit 格；③ 裸码 =
                //   TY_NEVER；④ = `fn` 声明（**extern 面按裁④ 不动**）。
                //   **嵌套 if**：bootstrap 构建的 corec 对 `&&` 两侧无条件求值
                //   （bootstrap/corec/frontend/ir_gen.py:226-235），且 `fi_return_type`
                //   （dyn_arr.cr:459）与 `ast_kind`（dyn_arr.cr:370）均无护栏 ⇒ 不得写
                //   `guard && 表读`。
                if fi >= 0 {
                    if sym_type(si) == TI_UNIT {
                        if fi_return_type(fi) == TY_NEVER {
                            fnd := fi_ast_node(fi);
                            if fnd >= 0 {
                                if ast_kind(fnd) == EXPR_FN {
            infer_call_args(first_arg);   // TODO #2026-09-16-31：实参必须被推断（本 return 路径原先跳过）
                                    return TI_NEVER;
                                }
                            }
                        }
                    }
                }
            infer_call_args(first_arg);   // TODO #2026-09-16-31：实参必须被推断（本 return 路径原先跳过）
                return sym_type(si);  // return type
            }
            // Check runtime builtins (no .cr body, implemented in rt.s)
            bi : ., mut = 0;
            loop {
                if bi >= g_rt_builtin_count { break; }
                if r64(g_rt_builtin_names, bi * 8) == func_ni {
            infer_call_args(first_arg);   // TODO #2026-09-16-31：实参必须被推断（本 return 路径原先跳过）
                    return r64(g_rt_builtin_ret_types, bi * 8);
                }
                bi = bi + 1;
            }
            // Not found in symbol table or builtins — report error
            name := istr_get(func_ni);
            check_error(EC_N_FUNC, "Undefined function '" + name + "'", ast_line(node), ast_col(node));
            infer_call_args(first_arg);   // TODO #2026-09-16-31：实参必须被推断（本 return 路径原先跳过）
            return TI_NEVER;
        }
        infer_call_args(first_arg);   // 单一真源（与上述 4 处同一函数）
        return TI_INT;  // external/unknown functions
    }

    if ast_kind(node) == EXPR_BLOCK {
        stmt_start := ast_a(node);
        stmt_count := ast_b(node);
        res : ., mut = TI_UNIT;
        push_borrow_scope();
        i : ., mut = 0;
        loop {
            if i >= stmt_count { break; }
            sn := r64(g_block_stmts, (stmt_start + i) * 8);
            res = infer_expr(sn);
            i = i + 1;
        }
        // Track the last-statement type for debugging
        // (no operation needed — res is already the last type)
        pop_borrow_scope();
        return res;
    }

    if ast_kind(node) == EXPR_IF {
        cond := ast_a(node);
        then_node := ast_b(node);
        else_node := ast_c(node);
        cond_ti := infer_expr(cond);
        // Accept int as truthy/falsy in conditions (not just strict bool)
        // R2 P2b Task 4：查表（门形状 = ONE 单操作数）。转录依据 = 本处改动前的
        // `cond_ti != TI_BOOL && cond_ti != TI_INT`；IP_COND 格恰 {int, bool}——**dex 拒**
        // （`if 1.5` 现状 error[TC01]，探针 N8 实测）。**不得**与 `while` 的 IP_COND_BOOL 合并
        // （那条只收 bool——合并 = 收紧 `if` 或放宽 `while`）。
        if iface_permits(iface_kind_of(cond_ti), IP_COND) == 0 {
            check_error(EC_TC_IF_COND, "If condition must be bool or int", ast_line(node), ast_col(node));
        }
        // --- Dyn type set merge: save pre-if state ---
        pre_dyn_count : ., mut = g_dyn_type_set_count;
        pre_dyn_save : string, mut = "";
        if pre_dyn_count > 0 {
            pre_dyn_save = alloc(pre_dyn_count * 8);
            _dyncpy(g_dyn_type_sets, pre_dyn_count * 8, pre_dyn_save);
        }
        // --- Process then branch ---
        push_borrow_scope();
        then_ti := infer_expr(then_node);
        pop_borrow_scope();
        // --- Save then-branch dyn state ---
        then_dyn_count : ., mut = g_dyn_type_set_count;
        then_dyn_save : string, mut = "";
        if then_dyn_count > 0 {
            then_dyn_save = alloc(then_dyn_count * 8);
            _dyncpy(g_dyn_type_sets, then_dyn_count * 8, then_dyn_save);
        }
        // --- Restore pre-if state (zero stale entries beyond pre_dyn_count) ---
        g_dyn_type_set_count = pre_dyn_count;
        if pre_dyn_count > 0 {
            _dyncpy(pre_dyn_save, pre_dyn_count * 8, g_dyn_type_sets);
        }
        iz : ., mut = pre_dyn_count;
        loop {
            if iz >= then_dyn_count { break; }
            w64(g_dyn_type_sets, iz * 8, 0);
            iz = iz + 1;
        }
        // --- Process else branch (if any) ---
        if else_node >= 0 {
            push_borrow_scope();
            else_ti := infer_expr(else_node);
            pop_borrow_scope();
            // --- Merge dyn type sets from both branches ---
            merge_count : ., mut = then_dyn_count;
            if g_dyn_type_set_count > merge_count { merge_count = g_dyn_type_set_count; }
            grow_dyn_type_sets(merge_count);
            g_dyn_type_set_count = merge_count;
            mi : ., mut = 0;
            loop {
                if mi >= merge_count { break; }
                then_bits : ., mut = 0;
                if mi < then_dyn_count { then_bits = r64(then_dyn_save, mi * 8); }
                else_bits : ., mut = 0;
                if mi < g_dyn_type_set_count { else_bits = r64(g_dyn_type_sets, mi * 8); }
                merged := union_bitmaps(then_bits, else_bits);
                w64(g_dyn_type_sets, mi * 8, merged);
                mi = mi + 1;
            }
            g_dyn_type_set_count = merge_count;
            // P3 Task 1 参序归一：合并**结果类型 = then_ti**（下方 return then_ti）⇒ 源 = else 侧，
            // 目标 = then 侧（长度约束更弱者放前面会被这里拦住 = 与结果类型一致；反之亦然）
            compat := type_compat_strict(else_ti, then_ti);
            // TC02 收口（P3）：if 的**值类型定义为 then_ti**（下方 return then_ti）⇒ 当 **else 支
            // 确定发散**（`return` 族收尾、不产出值）时，else 侧的「类型」是幻影（EXPR_RETURN 推断
            // = 所返回值类型）⇒ 相容判定无对象 ⇒ 不报。
            // **不对称是有意的**：then 支发散时 then_ti 本身即幻影（模型面，另案）⇒ 该形态继续报
            // TC02（保留真信号）。谓词 = stmt_diverges（头注：只服务本判定点）。
            if compat != 1 && then_ti != TI_NEVER && else_ti != TI_NEVER {
                if stmt_diverges(else_node) == 0 {
                    diag_type_incompatible(compat, EC_TC_IF_BRANCH, "If branches have different types", ast_line(node), ast_col(node));
                }
            }
            return then_ti;
        }
        return TI_UNIT;
    }

    if ast_kind(node) == EXPR_GO {
        // a=-1, b=body;  c=iter_ni (>=0 for range mode)
        body := ast_b(node);
        // **range-go 迭代变量绑定**（2026-09-16 #2026-09-16-31 批 T4；维护者裁 (i)）：`go i a..b body` 的
        // 语义**就是绑定 `i`**（ir_gen 侧按 `EXPR_GO.c` 使用该名），而本分支此前**不绑** ⇒
        // checker 与语言语义不一致（checker 缺口，非误报豁免问题）。
        // **修前不可见**：body 常为 `f(i)` 形（已解析直调的实参）⇒ 实参从不被推断（TODO #2026-09-16-31）
        // ⇒ `i` 从未被查、无诊断；#2026-09-16-31 修好后**暴露为 N01 误报**（命中载体 = 29 探针之一的
        // `tests/probes/p_spawn.cr` + 已挂 CI 的 `tests/selfhost/test_interp_parity.py`）。
        // 绑定语义与 `for` **同源**（先例 `checker.cr:3039-3051`）：**int 局部**（与 ir_gen 的
        // `iter_var_ni` 用法一致）+ **作用域严格限 body**（进前绑、出后恢复）；
        // `ast_c(node) <= 0`（单发形 `go f(x)`）**不绑、完全不受影响**（硬条件 1）。
        iter_ni := ast_c(node);
        scoped : ., mut = 0;
        push_borrow_scope();
        if iter_ni > 0 {
            push_scope();
            def_sym(iter_ni, SYM_LOCAL, TI_INT, -1);
            scoped = 1;
        }
        body_ti := infer_expr(body);
        if scoped != 0 { pop_scope(); }
        pop_borrow_scope();
        rn := ast_data(node);
        if rn <= 0 {
            return body_ti;  // single go: future of body type
        }
        // Range go: returns array of body type (size from data=range_node)
        range_node := ast_data(node);
        rng_count := ast_b(range_node) - ast_a(range_node);
        // 表示层概念（2026-09-10 语言面收窄裁决 §1）：`[T; N]` 退役为「内联容量存储」表示提示（语义归处 = product / 序列+长度约束 / F11）——完整注记见本文件 res_type_node 的 EXPR_ARRAY 分支处，spec 见 docs/superpowers/specs/2026-09-10-language-surface-narrowing-design.md §1
        return alloc_type(TYP_ARRAY, body_ti, rng_count);
    }

    if ast_kind(node) == EXPR_YIELD {
        val := ast_a(node);
        val_ti : ., mut = TI_UNIT;
        if val >= 0 { val_ti = infer_expr(val); }
        // In a flow, the yield type is the flow's result type; return the value type
        return val_ti;  // yield's type is the yielded value's type
    }

    if ast_kind(node) == EXPR_AWAIT {
        val := ast_a(node);
        val_ti := infer_expr(val);
        // If awaiting an array of T, return array element type T
        // If awaiting a single future, return the type directly
        if get_type_kind(val_ti) == TYP_ARRAY {
            return get_type_data(val_ti);  // await [Future<T>] → T
        }
        return val_ti;
    }

    if ast_kind(node) == EXPR_LOOP {
        push_borrow_scope();
        infer_expr(ast_a(node));
        pop_borrow_scope();
        return TI_UNIT;
    }

    if ast_kind(node) == EXPR_WHILE {
        cond := ast_a(node);
        body := ast_b(node);
        cond_ti := infer_expr(cond);
        // R2 P2b Task 4：查表（门形状 = ONE）。转录依据 = 本处改动前的 `cond_ti != TI_BOOL`；
        // IP_COND_BOOL 格**只含 bool**（`while 1` 现状 error[TC04]，探针 N9 实测）。
        if iface_permits(iface_kind_of(cond_ti), IP_COND_BOOL) == 0 {
            check_error(EC_TC_WHILE_COND, "While condition must be bool", ast_line(node), ast_col(node));
        }
        push_borrow_scope();
        infer_expr(body);
        pop_borrow_scope();
        return TI_UNIT;
    }

    if ast_kind(node) == EXPR_FOR {
        var_ni := ast_a(node);
        iter := ast_b(node);
        body := ast_c(node);
        infer_expr(iter);
        push_scope();
        push_borrow_scope();
        def_sym(var_ni, SYM_LOCAL, TI_INT, -1);
        infer_expr(body);
        pop_borrow_scope();
        pop_scope();
        return TI_UNIT;
    }

    if ast_kind(node) == EXPR_RANGE {
        st := infer_expr(ast_a(node));
        et := infer_expr(ast_b(node));
        if st != TI_INT { check_error(EC_TB_ADD, "Range start must be int", ast_line(node), ast_col(node)); }
        if et != TI_INT { check_error(EC_TB_ADD, "Range end must be int", ast_line(node), ast_col(node)); }
        return TI_INT;
    }

    if ast_kind(node) == EXPR_MATCH {
        match_expr := ast_a(node);
        first_arm := ast_b(node);
        match_ti := infer_expr(match_expr);
        res : ., mut = TI_UNIT;
        ai : ., mut = 0;
        an : ., mut = first_arm;
        // R2 P3 Task 3：穷尽性判定面（补集空性 + 具体变体反例）。收集与臂体推断同趟：
        // 模式类别/归属 → 模式项 CONS 链（m_pats）+ 覆盖位（m_cover）+ 不可映射标记
        // （m_unmappable）；臂体推断后统一判（判据本体与消费点封装见 ty_shadow.cr 末段）。
        m_pats : ., mut = tt_nil();
        mc_save := mc_begin();     // 容量批 T3：覆盖位图入栈（无界；旧态 = 单 int 2^vi）
        m_unmappable : ., mut = 0;
        m_wild : ., mut = 0;      // 通配/绑定已见（冗余臂判据用；非穷尽性判据本体）
        m_dup : ., mut = -1;      // 首个冗余臂模式节点（-1 = 无）
        loop {
            if an < 0 { break; }
            arm_pat := ast_a(an);  // EXPR_ARM: a = pattern
            arm_body := ast_b(an);  // EXPR_ARM: b = body
            if arm_pat >= 0 {
                pk := sh_match_pat_kind(arm_pat);
                if pk == 1 {
                    if m_wild != 0 { if m_dup < 0 { m_dup = arm_pat; } }
                    m_wild = 1;
                    m_pats = tt_cons(tt_top(), m_pats);
                } else if pk == 2 {
                    vi := sh_match_pat_variant(match_ti, arm_pat);
                    vt : ., mut = -1;
                    if vi >= 0 { vt = sh_match_variant_term(match_ti, vi); }
                    // R2 P3 Task 4：可选域（`T?`）——枚举归属不成立时试 `Some`/`None` 两分支
                    // （sh_match_opt_pat 对非可选 scrutinee 恒 -1 ⇒ 既有枚举/非枚举面零变化）。
                    oi : ., mut = -1;
                    if vi < 0 {
                        oi = sh_match_opt_pat(match_ti, arm_pat);
                        if oi >= 0 { vt = sh_match_opt_term(match_ti, oi); }
                    }
                    if vt < 0 {
                        m_unmappable = 1;      // 非本枚举/非本域/未声明变体名 ⇒ 不判（不得当 ∅/⊤）
                    } else {
                        ci : ., mut = vi;
                        if vi < 0 { ci = oi; }   // 可选域：覆盖位 0 = 有值 / 1 = null
                        if m_wild != 0 { if m_dup < 0 { m_dup = arm_pat; } }
                        if mc_has(ci) != 0 { if m_dup < 0 { m_dup = arm_pat; } }
                        mc_add(ci);
                        m_pats = tt_cons(vt, m_pats);
                    }
                } else {
                    m_unmappable = 1;          // 字面量/struct 模式 ⇒ 不判（登记）
                }
            }
            // Bind pattern variables in new scope
            push_scope();
            if arm_pat >= 0 {
                if ast_kind(arm_pat) == EXPR_ENUMPAT {
                    // Bind sub-patterns
                    sub_pat := ast_b(arm_pat);
                    sub_count := ast_c(arm_pat);
                    spi : ., mut = 0;
                    spn : ., mut = sub_pat;
                    loop {
                        if spi >= sub_count { break; }
                        if spn >= 0 {
                            if ast_kind(spn) == EXPR_IDENT {
                                def_sym(ast_int_val(spn), SYM_LOCAL, TI_INT, -1);
                            }
                            spn = spn + 1;
                        }
                        spi = spi + 1;
                    }
                }
                if ast_kind(arm_pat) == EXPR_IDENT {
                    def_sym(ast_int_val(arm_pat), SYM_LOCAL, TI_INT, -1);
                }
            }
            push_borrow_scope();
            arm_ti := infer_expr(arm_body);
            pop_borrow_scope();
            if ai == 0 { res = arm_ti; }
            pop_scope();
            an = ast_c(an);  // next arm via linked list
            ai = ai + 1;
        }
        // 穷尽性判定：引擎补集空性（预算前后隔离照 type_equal_engine 的窗口纪律）。
        // 三态：0 = 不穷尽（诊断 + 具体反例变体名）；1 = 穷尽；-1 = 不判（非枚举域/不可映射
        // 模式/引擎未知）——**零诊断**（三态纪律：未知不得当「不穷尽」，也不得当「穷尽」）。
        ty_budget_reset(200000);
        m_verdict := sh_match_exhaustive(match_ti, m_pats, m_unmappable);
        ty_budget_reset(200000);
        if m_verdict == 0 {
            mi : ., mut = -1;
            msg := "Non-exhaustive match";
            if get_type_kind(match_ti) == TYP_OPTIONAL {
                // `T?` 两分支反例命名（R2 P3 Task 4）：0 = 有值（Some）/ 1 = null（None）
                mi = mc_first_missing(2);
                if mi == 0 { msg = msg + ": missing variant 'Some'"; }
                if mi == 1 { msg = msg + ": missing variant 'None'"; }
            } else {
                ea := find_enum_row_of(match_ti);
                if ea >= 0 { mi = mc_first_missing(ei_variant_count(ea)); }
                if mi >= 0 { msg = msg + ": missing variant '" + istr_get(ei_variant_name(ea, mi)) + "'"; }
            }
            check_error(EC_TM_EXHAUST, msg, ast_line(node), ast_col(node));
        }
        if m_dup >= 0 {
            check_error(EC_TM_REDUNDANT, "Redundant match arm", ast_line(m_dup), ast_col(m_dup));
        }
        mc_end(mc_save);   // 容量批 T3：覆盖位图出栈（清零本层位 + 回退长度）
        return res;
    }

    if ast_kind(node) == EXPR_LET {
        var_ni := ast_a(node);
        type_node := ast_b(node);
        val_node := ast_c(node);
        val_ti := TI_UNIT;
        if val_node >= 0 {
            val_ti = infer_expr(val_node);
            // Check if value is a borrow (&x or &mut x), record the holder
            if ast_kind(val_node) == EXPR_UNARY && ast_c(val_node) == UOP_REF {
                borrowed_ni := borrow_var_name(ast_a(val_node));
                if borrowed_ni >= 0 {
                    mut_flag := ast_int_val(val_node);
                    record_borrow_holder(var_ni, borrowed_ni, mut_flag);
                }
            }
        }
        ti := val_ti;
        if type_node >= 0 { ti = res_type_node(type_node); }
        // R2 P5 Task 6（TODO #2026-09-11-14）：值/注解兼容检查（豁免面见 check_let_annot_compat 头注）
        check_let_annot_compat(node, val_node, val_ti, ti);
        if istr_get(var_ni) != "_" {
            def_sym(var_ni, SYM_LOCAL, ti, -1);
            if ti == TI_DYN && val_node >= 0 {
                grow_dyn_type_sets(g_sym_count);
                w64(g_dyn_type_sets, (g_sym_count - 1) * 8, 0);
                dyn_set_type(g_sym_count - 1, val_ti);
            }
        }
        return TI_UNIT;
    }

    if ast_kind(node) == EXPR_RETURN {
        if ast_a(node) >= 0 {
            return infer_expr(ast_a(node));
        }
        return TI_UNIT;
    }

    if ast_kind(node) == EXPR_ENUM_CONSTRUCTOR {
        name_idx := ast_a(node);
        first_arg := ast_b(node);
        arg_count := ast_c(node);
        si := find_gsym(name_idx);
        if si >= 0 && sym_kind(si) == SYM_FN {
            // Infer arg types (walk EXPR_ARG chain)
            an : ., mut = first_arg;
            loop {
                if an < 0 { break; }
                infer_expr(ast_a(an));
                an = ast_b(an);
            }
            return sym_type(si); // enum type
        }
        name := istr_get(name_idx);
        // ─── R2 P3 Task 4：内建可选构造器（退役内建 Option 注册后的解析路径）───
        // `Some`/`None` 是**关键字**（lexer.cr 的 T_SOME/T_NONE 仅由这两个词产出）⇒ 本分派是
        // 关键字名分派，不是「类型名分派」：用户声明同名**变体**时上面的 SYM_FN 命中优先
        // （p20 语义保持：用户 `enum Option[T] { None, Some(T) }` 时 Some/None 仍是它的变体）。
        // 类型面：`None` = TYP_NULL（null 单点类型，`T ∪ null` 里的 null）；`Some(x)` =
        // TYP_OPTIONAL(载荷行) ⇒ `Some(1)` 的类型 = `int?`（计划用例「Some(1) 满足 int?」）。
        // 表示面（如实登记）：运行时形态沿用既有 EXPR_ENUM_CONSTRUCTOR 代码路径（ir_gen 的
        // IR_MAKE_ENUM + 字段存；EXPR_TRY 的 IR = 内层表达式）——本任务落**类型层**的联合/
        // 可选语义，运行期表示统一（Some 值 vs 裸值）不在本任务 Files 面内（计划未列 ir_gen/
        // 后端），登记为未覆盖面。
        if str_eq(name, "Some") != 0 {
            at : ., mut = TI_UNIT;
            if arg_count == 1 && first_arg >= 0 {
                at = infer_expr(ast_a(first_arg));
            } else if arg_count > 1 {
                // 多载荷（`Some(a, b)`）：载荷行 = TYP_TUPLE（两趟落盘，照 EXPR_TUPLE 契约——
                // 元素推断自身可向 g_gen_apply_data 追加数据，不得边推边写；见该分支注记）。
                tis : string, mut = alloc(arg_count * 8);
                ai : ., mut = 0;
                an2 : ., mut = first_arg;
                loop {
                    if ai >= arg_count { break; }
                    ev : ., mut = TI_UNIT;
                    if an2 >= 0 {
                        ev = infer_expr(ast_a(an2));
                        an2 = ast_b(an2);
                    }
                    w64(tis, ai * 8, ev);
                    ai = ai + 1;
                }
                ds := g_gen_apply_data_count;
                grow_gen_apply_data(ds + arg_count);
                ai = 0;
                loop {
                    if ai >= arg_count { break; }
                    w64(g_gen_apply_data, (ds + ai) * 8, r64(tis, ai * 8));
                    ai = ai + 1;
                }
                g_gen_apply_data_count = ds + arg_count;
                at = alloc_type(TYP_TUPLE, arg_count, ds);
            }
            return alloc_type(TYP_OPTIONAL, at, 0);
        }
        if str_eq(name, "None") != 0 {
            return alloc_type(TYP_NULL, 0, 0);
        }
        check_error(EC_N_UNDEFINED, "Undefined enum constructor '" + name + "'", ast_line(node), ast_col(node));
        return TI_UNIT;
    }

    if ast_kind(node) == EXPR_FIELD {
        obj := ast_a(node);
        field_ni := ast_int_val(node);
        obj_ti := infer_expr(obj);
        // Auto-deref: if obj is a reference type, unwrap to inner type
        actual_ti : ., mut = obj_ti;
        if actual_ti >= 0 && actual_ti < g_type_count && get_type_kind(actual_ti) == TYP_REF {
            actual_ti = get_type_data(actual_ti);
        }
        // Handle generic apply: unwrap to base named type for struct lookup
        if actual_ti >= 0 && actual_ti < g_type_count && get_type_kind(actual_ti) == TYP_GENERIC_APPLY {
            actual_ti = get_type_data(actual_ti);
        }
        if actual_ti >= 0 && actual_ti < g_type_count && get_type_kind(actual_ti) == TYP_NAMED {
            struct_ni := get_type_data(actual_ti);
            si := find_struct(struct_ni);
            if si >= 0 {
                fi : ., mut = 0;
                loop {
                    if fi >= si_field_count(si) { break; }
                    if si_field_name(si, fi) == field_ni {
                        ast_set_data(node, fi);  // store field index for ir_gen
                        ast_set_c(node, struct_ni);  // store struct name for ELF backend
                        // Resolve field type, substituting generic params if needed
                        ft_node := si_field_type_node(si, fi);
                        if ft_node >= 0 {
                            if ast_kind(ft_node) == EXPR_IDENT {
                                ft_name_idx := ast_int_val(ft_node);
                                // Check if this field type is a generic param (substitute if we have a generic apply)
                                if is_struct_generic(si, ft_name_idx) && get_type_kind(obj_ti) == TYP_GENERIC_APPLY {
                                        base_ti := get_type_data(obj_ti);
                                        ga_start := get_type_extra(obj_ti);
                                        ga_count := r64(g_gen_apply_data, ga_start * 8);
                                        // Find which generic param index
                                        gpi : ., mut = 0;
                                        loop {
                                            if gpi >= si_generic_count(si) { break; }
                                            if si_generic_name(si, gpi) == ft_name_idx {
                                                // Use the corresponding arg from the generic apply
                                                if gpi < ga_count {
                                                    return r64(g_gen_apply_data, (ga_start + 1 + gpi) * 8);
                                                }
                                                break;
                                            }
                                            gpi = gpi + 1;
                                        }
                                }
                            }
                            return res_type_node(ft_node);
                        }
                        return si_field_type(si, fi);
                    }
                    fi = fi + 1;
                }
            }
        }
        // Tuple field access: t.0, t.1
        if actual_ti >= 0 && actual_ti < g_type_count && get_type_kind(actual_ti) == TYP_TUPLE {
            field_name := istr_get(field_ni);
            idx := str_int(field_name);
            tc := get_type_data(actual_ti);
            if idx >= 0 && idx < tc {
                data_start := get_type_extra(actual_ti);
                if ast_data(node) != idx {
                    ast_set_data(node, idx);
                }
                return r64(g_gen_apply_data, (data_start + idx) * 8);
            }
        }
        return TI_UNIT;
    }

    if ast_kind(node) == EXPR_INDEX {
        arr_ti := infer_expr(ast_a(node));
        idx_ti := infer_expr(ast_b(node));
        arr_kind := get_type_kind(arr_ti);
        // Range index: arr[low..high] → slice type
        if ast_kind(ast_b(node)) == EXPR_RANGE {
            // R2 P3b Task 2：类别判定换位到**序列形状**（数组/切片同属 AK_SEQUENCE；
            // sh_shape_seq = ⊤ₖ(AK_SEQUENCE)，见 iface_registry.cr 的横切形状段）。
            // 固定性维度（N vs 视图）取自序列项的 b 槽（sh_seq_fixed_len_of_ti——表示层提示，
            // 语义判定不看 N：spec §5.1 + T1 的固定性位登记）。行为保持：仅**固定长序列**
            // （数组）在 range 下产视图；切片/非序列现状 = TI_UNIT（IP_INDEX_RANGE 未接线，
            // 登记面 A.2 #15）。三态纪律：形状 -1（不可译行）**不**折算，回落旧 kind 直比
            // （该行改动前由 `arr_kind == TYP_ARRAY` 独判 ⇒ 回落即逐行同结论）。
            seq_ok := iface_satisfies_term(arr_ti, sh_shape_seq());
            if seq_ok == -1 && arr_kind == TYP_ARRAY { seq_ok = 1; }
            if seq_ok == 1 && sh_seq_fixed_len_of_ti(arr_ti) >= 0 {
                // F11：字面量切片界编译期验证（TK05/06 既有错误码）
                arr_len : ., mut = get_type_extra(arr_ti);
                rn := ast_b(node);
                if arr_len > 0 && ast_kind(ast_a(rn)) == EXPR_INT && ast_kind(ast_b(rn)) == EXPR_INT {
                    lo := ast_int_val(ast_a(rn));
                    hi := ast_int_val(ast_b(rn));
                    if lo < 0 || hi > arr_len {
                        check_error(EC_TK_SLICE_BOUNDS, "slice out of bounds: [" + int_str(lo) + ".." + int_str(hi) + "] (array length " + int_str(arr_len) + ")", ast_line(node), ast_col(node));
                    } else if lo > hi {
                        check_error(EC_TK_SLICE_LEN, "slice length negative: [" + int_str(lo) + ".." + int_str(hi) + "]", ast_line(node), ast_col(node));
                    }
                }
                return alloc_type(TYP_SLICE, get_type_data(arr_ti), 0);
            }
            return TI_UNIT;
        }
        // Regular index: arr[i] or slice[i] → element type
        if arr_kind == TYP_ARRAY {
            // F2：字面量索引编译期越界检查（数组长度编译期可知时）
            if ast_kind(ast_b(node)) == EXPR_INT {
                idx_val := ast_int_val(ast_b(node));
                arr_len : ., mut = get_type_extra(arr_ti);
                if arr_len > 0 && (idx_val < 0 || idx_val >= arr_len) {
                    check_error(EC_R_OOB, "index out of bounds: " + int_str(idx_val) + " (array length " + int_str(arr_len) + ")", ast_line(node), ast_col(node));
                }
            }
            return get_type_data(arr_ti);
        }
        if arr_kind == TYP_SLICE {
            return get_type_data(arr_ti);  // slice[i] → element type
        }
        if arr_ti == TI_STR {
            // A string is a byte sequence. Reject a statically known invalid
            // index instead of allowing a silent read past its terminator.
            if ast_kind(ast_a(node)) == EXPR_STRING && ast_kind(ast_b(node)) == EXPR_INT {
                string_len := istr_len(ast_int_val(ast_a(node)));
                string_idx := ast_int_val(ast_b(node));
                if string_idx < 0 || string_idx >= string_len {
                    check_error(EC_R_OOB,
                        "string index out of bounds: " + int_str(string_idx) +
                        " (length " + int_str(string_len) + ")",
                        ast_line(node), ast_col(node));
                }
            }
            return TI_INT;  // string[i] → byte value
        }
        // R2 P3b Task 2：兜底门从「许可位集直查」换位到**横切形状满足判定**（可索引形状 =
        // ⊤ₖ(SEQUENCE) ∪ ⊤ₖ(STRING)，见 iface_registry.cr 的横切形状段）。与 P2b Task 5 的
        // 表查同一口径：本门的**可达集** = 上方三个结果分支（arr→elem+F2 / slice→elem /
        // str→int——同时决定结果类型，A.2 #16-18 明令原地保留）之后的落空集；形状的**拒绝集**
        // 与之逐行相等（全类型行枚举守门 = selftest `x2.indexable_matches_ops` + 既有
        // `idx.gate_deny_covers_fallback`）。三态纪律：形状 -1（不可判：不可译行等）**不**折算成
        // 0/1，而是**回落**既有许可表——改动前同类行本就走该表，故回落 = 逐行同结论。
        idx_ok := iface_satisfies_term(arr_ti, sh_shape_indexable());
        if idx_ok == -1 { idx_ok = iface_permits(iface_kind_of(arr_ti), IP_INDEX); }
        if idx_ok != 1 {
            check_error(EC_TK_INDEX, "Cannot index non-array type", ast_line(node), ast_col(node));
        }
        return TI_INT;
    }

    if ast_kind(node) == EXPR_ASSIGN {
        target := ast_a(node);
        val := ast_b(node);
        tt := infer_expr(target);
        vt := infer_expr(val);
        if tt == TI_DYN {
            // dyn assignment: track the RHS type, skip strict type check
            if ast_kind(target) == EXPR_IDENT {
                target_ni := ast_int_val(target);
                target_si := find_sym(target_ni);
                if target_si >= 0 {
                    dyn_set_type(target_si, vt);
                }
            }
        } else {
            // P3 Task 1 参序归一：赋值 = 目标(tt) ← 值(vt) ⇒ 源 = vt，目标 = tt
            compat := type_compat_strict(vt, tt);
            if compat != 1 {
                diag_type_incompatible(compat, EC_TA_ASSIGN, "Assignment type mismatch", ast_line(node), ast_col(node));
            }
        }
        return vt;
    }

    if ast_kind(node) == EXPR_STRUCT {
        // Struct literal: a = name idx, b = first field wrapper, c = field count。
        // F5 契约（见 parser.cr struct 分支）：wrapper 在 g_ast 中连续、wrapper.a=字段值节点；
        // 逐 wrapper 解引用（infer_expr 对 EXPR_NONE 前向）——直接按偏移取「下一个节点」当字段值
        // 只在字段值单槽时成立，复合字段值（调用/字面量）会整体错位（静默错误值）。
        // TODO #2026-09-11-11 ①②（名字绑定 + 类型比对）：wrapper.b = 字段名 idx（parser 写入；-1 = 无名字
        // 信息 → 不校验、按既有位序语义回落）。新增 = 未知字段（TS02）/ 重复字段（TS04）/
        // 缺字段（TS01）三校验 + 字段类型 vs 声明比对（TS03，走 type_compat_strict 引擎判定）。
        // **值按名字绑定**（与 Python bootstrap 的 gen_struct_lit 同语义；名字 → 声明下标，
        // 消费者 ir_gen 同步按名字取字段位）：修复前值按**声明位序**绑定 ⇒ P{b:11, a:22} 静默
        // 得 a=11（静默错值级，rc=0）。
        name_ni := ast_a(node);
        si := find_struct_by_name(name_ni);
        c := ast_c(node);
        w0 := ast_b(node);
        // 名字信息齐备？（parser 恒写；克隆体丢名字 → 回落位序、不做名字类校验）
        named : ., mut = 0;
        if w0 >= 0 && c > 0 {
            named = 1;
            ni2 : ., mut = 0;
            loop {
                if ni2 >= c { break; }
                if ast_b(w0 + ni2) < 0 { named = 0; break; }
                ni2 = ni2 + 1;
            }
        }
        // didx[i] = 字面量第 i 个字段 → 声明字段下标（默认位序 = 无名字信息时的既有语义）
        didx : string, mut = alloc((c + 1) * 8);
        i : ., mut = 0;
        loop {
            if i >= c { break; }
            w64(didx, i * 8, i);
            i = i + 1;
        }
        if si >= 0 && (named != 0 || c == 0) {
            // ── 名字 → 声明下标：未知字段 / 重复字段 / 缺字段 ──
            fc := si_field_count(si);
            used : string, mut = alloc((fc + 1) * 8);
            j : ., mut = 0;
            loop {
                if j >= fc { break; }
                w64(used, j * 8, 0);
                j = j + 1;
            }
            if named != 0 {
                i = 0;
                loop {
                    if i >= c { break; }
                    nn := ast_b(w0 + i);
                    jdi := struct_field_index_by_name(si, nn);
                    if jdi < 0 {
                        check_error(EC_TS_UNKNOWN_FIELD, "Unknown field '" + istr_get(nn) + "' in struct literal " + istr_get(name_ni), ast_line(w0 + i), ast_col(w0 + i));
                    } else {
                        if r64(used, jdi * 8) != 0 {
                            check_error(EC_TS_FIELD_DUP, "Field '" + istr_get(nn) + "' initialized more than once", ast_line(w0 + i), ast_col(w0 + i));
                        }
                        w64(used, jdi * 8, 1);
                        w64(didx, i * 8, jdi);
                    }
                    i = i + 1;
                }
            }
            j = 0;
            loop {
                if j >= fc { break; }
                if r64(used, j * 8) == 0 {
                    // 只报第一个缺字段（同一程序员错误不刷屏）
                    check_error(EC_TS_MISSING_FIELD, "Missing field '" + istr_get(si_field_name(si, j)) + "' in struct literal " + istr_get(name_ni), ast_line(node), ast_col(node));
                    break;
                }
                j = j + 1;
            }
        }
        // ── 值类型逐个推断（一次/字段：infer_expr 有副作用，勿重复推断；结构体名未找到时
        //    也要推断——嵌套诊断/dyn 记录等副作用在此，旧行为不可丢）──
        vts : string, mut = alloc((c + 1) * 8);
        i = 0;
        loop {
            if i >= c { break; }
            if w0 >= 0 { w64(vts, i * 8, infer_expr(w0 + i)); }
            i = i + 1;
        }
        if si >= 0 {
            gc := si_generic_count(si);
            if gc > 0 {
                // ── 泛型结构体：字段类型 = 泛型参数 → 绑定（重复绑定走 unify 已绑定路径比对）──
                g_gen_map_count = 0; g_gen_map_cap = 0;
                i = 0;
                loop {
                    if i >= c { break; }
                    jdi := r64(didx, i * 8);
                    if jdi >= 0 && jdi < si_field_count(si) {
                        dtn := si_field_type_node(si, jdi);
                        if dtn >= 0 && ast_kind(dtn) == EXPR_IDENT && is_struct_generic(si, ast_int_val(dtn)) {
                            pt := alloc_type(TYP_GENERIC_PARAM, ast_int_val(dtn), 0);
                            if !unify_types(pt, r64(vts, i * 8)) {
                                check_error(EC_TS_FIELD_TYPE, "Field '" + istr_get(si_field_name(si, jdi)) + "': expected " + istr_get(ast_int_val(dtn)) + ", got " + type_display(r64(vts, i * 8)), ast_line(w0 + i), ast_col(w0 + i));
                            }
                        }
                    }
                    i = i + 1;
                }
            }
            // ── 非参数声明类型：值类型 vs 声明类型比对（两侧任一含未实例化泛型参数 → 跳过）──
            i = 0;
            loop {
                if i >= c { break; }
                jdi := r64(didx, i * 8);
                if jdi >= 0 && jdi < si_field_count(si) {
                    dtn := si_field_type_node(si, jdi);
                    is_param : ., mut = 0;
                    if dtn >= 0 && ast_kind(dtn) == EXPR_IDENT && is_struct_generic(si, ast_int_val(dtn)) { is_param = 1; }
                    if is_param == 0 && type_node_mentions_struct_param(si, dtn) == 0 {
                        vt := r64(vts, i * 8);
                        if ti_has_generic_param(vt) == 0 {
                            dt := res_type_node(dtn);
                            if ti_has_generic_param(dt) == 0 {
                                // P3 Task 1 参序归一：源 = 值类型(vt)，目标 = 声明类型(dt)
                                verdict := type_compat_strict(vt, dt);
                                if verdict != 1 {
                                    diag_type_incompatible(verdict, EC_TS_FIELD_TYPE, "Field '" + istr_get(si_field_name(si, jdi)) + "': expected " + type_display(dt) + ", got " + type_display(vt), ast_line(w0 + i), ast_col(w0 + i));
                                }
                            }
                        }
                    }
                }
                i = i + 1;
            }
            if gc > 0 {
                // ── 结果类型 TYP_GENERIC_APPLY：实参按**参数声明序**取映射 ──
                // （旧代码按字面量字段序写映射 + 直取映射序 = 参数序 ≠ 字段序时实参错位）
                base_ti := alloc_named_type(name_ni);
                ds := g_gen_apply_data_count;
                grow_gen_apply_data(ds + 1 + gc);
                g_gen_apply_data_count = ds + 1;
                found : ., mut = 0;
                g : ., mut = 0;
                loop {
                    if g >= gc { break; }
                    pni := si_generic_name(si, g);
                    bind : ., mut = -1;
                    mi : ., mut = 0;
                    loop {
                        if mi >= g_gen_map_count { break; }
                        if r64(g_gen_map_names, mi * 8) == pni { bind = r64(g_gen_map_types, mi * 8); break; }
                        mi = mi + 1;
                    }
                    if bind >= 0 {
                        w64(g_gen_apply_data, (ds + 1 + found) * 8, bind);
                        found = found + 1;
                    }
                    g = g + 1;
                }
                w64(g_gen_apply_data, ds * 8, found);
                g_gen_apply_data_count = ds + 1 + found;
                return alloc_type(TYP_GENERIC_APPLY, base_ti, ds);
            }
            return alloc_named_type(name_ni);
        }
        // 结构体名未找到：既有行为（不在此报错，返回具名类型）
        return alloc_named_type(name_ni);
    }

    if ast_kind(node) == EXPR_ARRAY {
        // Array literal（F5 契约，见 parser.cr 下标分支）：a = first wrapper（连续）,
        // b = elem count；wrapper.a=元素值节点（infer_expr 对 EXPR_NONE 前向）——不得按偏移
        // 直取相邻节点当元素，复合元素子树占多槽会整体错位（静默错型/错值）。
        // TODO #2026-09-11-11 ③：元素**同质性**检查——旧代码逐个覆盖 elem_ti（最终 = **最后一个**元素的
        // 类型），异质字面量 [1, "x", 3] 静默通过且类型随末元素漂移。现取首元素类型为元素类型
        // （与 Python bootstrap 的 ArrayLit 同语义），后续元素逐个与首元素比对（TK02）。
        elem_ti := TI_INT;   // 空字面量 []：沿用旧默认
        ei : ., mut = 0;
        en : ., mut = ast_a(node);
        loop {
            if ei >= ast_b(node) { break; }
            if en >= 0 {
                eti := infer_expr(en);
                if ei == 0 {
                    elem_ti = eti;
                } else {
                    // 两侧任一含未实例化泛型参数 → 跳过（不假拒，见 ti_has_generic_param）
                    if ti_has_generic_param(elem_ti) == 0 && ti_has_generic_param(eti) == 0 {
                        // P3 Task 1 参序归一：源 = 本元素(eti)，目标 = 首元素定下的元素类型(elem_ti)
                        verdict := type_compat_strict(eti, elem_ti);
                        if verdict != 1 {
                            diag_type_incompatible(verdict, EC_TK_ELEM_TYPE, "Expected array element type " + type_display(elem_ti) + ", got " + type_display(eti), ast_line(en), ast_col(en));
                        }
                    }
                }
                en = en + 1;
            }
            ei = ei + 1;
        }
        // 表示层概念（2026-09-10 语言面收窄裁决 §1）：`[T; N]` 退役为「内联容量存储」表示提示（语义归处 = product / 序列+长度约束 / F11）——完整注记见本文件 res_type_node 的 EXPR_ARRAY 分支处，spec 见 docs/superpowers/specs/2026-09-10-language-surface-narrowing-design.md §1
        return alloc_type(TYP_ARRAY, elem_ti, ast_b(node));
    }

    if ast_kind(node) == EXPR_BREAK { return TI_UNIT; }
    if ast_kind(node) == EXPR_CONTINUE { return TI_UNIT; }
    if ast_kind(node) == EXPR_WILDCARD { return TI_UNIT; }
    if ast_kind(node) == EXPR_MOVE {
        return infer_expr(ast_a(node));
    }
    if ast_kind(node) == EXPR_UNSAFE {
        push_unsafe_scope();
        ret := infer_expr(ast_a(node));
        pop_unsafe_scope();
        return ret;
    }
    if ast_kind(node) == EXPR_TRY {
        // R2 P3 Task 4：`?` 解包改按**类型项结构**（spec §5.4），废掉基名字符串判断
        // （旧实现按 `base_name == "Option" || base_name == "Result"` 取第一个类型实参——
        // 与「可选不再依赖内建 Option 枚举名」相悖，且对用户自定义枚举按名字猜测语义）。
        // 语义：`T?` = `T ∪ null` ⇒ 解包 = 取**非 null 析取支**。行面只有两种承载：
        //   · TYP_OPTIONAL（data = 内层行）→ 返回内层（= T）；
        //   · TYP_NULL（null 单点类型，无值可取）→ **不做解包**（返回原行）——「解包 null」
        //     的结果是空类型，而本层的 `never`/`⊥` 行在引擎侧不是真 ⊥（AK_NEVER 仍按原子类
        //     判包含，见 type_engine.cr 的 lit_implies）⇒ 判 never 会引入**新的**拒绝面；
        //     故保守不动（如实登记：`None?` 的类型 = null 自身）。
        // 其余（命名行/泛型应用行/原生行）**一律不解包**（旧行为：名字命中 Option/Result 才解包；
        // 用户枚举不再按名字猜——语义面登记见任务报告「收紧清单/语义保持」双表）。
        inner_ti := infer_expr(ast_a(node));
        if get_type_kind(inner_ti) == TYP_OPTIONAL {
            return get_type_data(inner_ti);
        }
        return inner_ti;
    }
    if ast_kind(node) == EXPR_STRUCTPAT {
        return TI_UNIT;
    }
    if ast_kind(node) == EXPR_AS {
        // expr as Type — type cast
        inner_ti := infer_expr(ast_a(node));
        type_node := ast_b(node);
        target_ti := res_type_node(type_node);
        if get_type_kind(target_ti) == TYP_PTR {
            inner_kind := get_type_kind(inner_ti);
            asp : ., mut = 1;
            if inner_kind == TYP_PTR {
                asp = get_type_extra(inner_ti);
            } else if inner_kind == TYP_REF {
                asp = 0;
            }
            return alloc_type(TYP_PTR, get_type_data(target_ti), asp);
        }
        return target_ti;
    }
    if ast_kind(node) == EXPR_STMT {
        infer_expr(ast_a(node));
        return TI_UNIT;
    }
    if ast_kind(node) == EXPR_TUPLE {
        // Tuple: create a TYP_TUPLE type with element types
        // F5 契约：a=首 wrapper（g_ast 中连续）、b=元素个数；wrapper.a = 元素值节点。
        // 复合元素（如 [1,2,3]）的值节点自身不连续，必须经 wrapper 解引用——
        // 直读 `elem_idx + e` 会把元素子节点当元素（类型错录 → 假拒 + soundness 漏放）。
        elem_idx := ast_a(node);
        ec : ., mut = ast_b(node);
        // 元素类型**两趟**记录（F5 第二根因）：先逐个推断（元素的推断自身可能向
        // g_gen_apply_data 追加数据——嵌套元组 / 泛型应用 / 泛型结构字面量的
        // g_gen_map 段），再一次性连续落盘。若照旧在循环前取 data_start 边推边写，
        // 前面元素追加的数据会把后续元素的位置顶开，extra 与实际落点错位（实测：
        // ((2,3),1) 的元素表被读成内层元组的字段 [int,int] → 嵌套元组异型互赋静默通过）。
        tis : string, mut = alloc(ec * 8);
        e : ., mut = 0;
        loop {
            if e >= ec { break; }
            wn : ., mut = -1;
            if elem_idx >= 0 { wn = ast_a(elem_idx + e); }
            w64(tis, e * 8, infer_expr(wn));
            e = e + 1;
        }
        data_start := g_gen_apply_data_count;
        grow_gen_apply_data(data_start + ec);
        e = 0;
        loop {
            if e >= ec { break; }
            w64(g_gen_apply_data, (data_start + e) * 8, r64(tis, e * 8));
            e = e + 1;
        }
        g_gen_apply_data_count = data_start + ec;
        return alloc_type(TYP_TUPLE, ec, data_start);
    }

    if ast_kind(node) == EXPR_AT {
        name_ni := ast_a(node);
        name := istr_get(name_ni);
        args := ast_b(node);

        // @sizeOf(T) — 1 type argument
        if str_eq(name, "sizeOf") != 0 {
            if args < 0 { check_error(EC_N_UNDEFINED, "@sizeOf requires a type argument", ast_line(node), ast_col(node)); return TI_NEVER; }
            ti := res_type_node(args);
            if ti < 0 { check_error(EC_N_UNDEFINED, "@sizeOf: unknown type", ast_line(node), ast_col(node)); return TI_NEVER; }
            return TI_INT;
        }

        // @addr(fn) — function address, type int
        if str_eq(name, "addr") != 0 {
            ast_set_type_val(node, TI_INT);  // function address is an int
            return TI_INT;
        }

        // @alignOf(T) — 1 type argument
        if str_eq(name, "alignOf") != 0 {
            if args < 0 { check_error(EC_N_UNDEFINED, "@alignOf requires a type argument", ast_line(node), ast_col(node)); return TI_NEVER; }
            ti := res_type_node(args);
            if ti < 0 { check_error(EC_N_UNDEFINED, "@alignOf: unknown type", ast_line(node), ast_col(node)); return TI_NEVER; }
            return TI_INT;
        }

        // @fields(T) — 1 type argument, returns []string
        if str_eq(name, "fields") != 0 {
            if args < 0 { check_error(EC_N_UNDEFINED, "@fields requires a type argument", ast_line(node), ast_col(node)); return TI_NEVER; }
            ti := res_type_node(args);
            return TI_STR;
        }

        // @hasField(T, name) — type + string
        if str_eq(name, "hasField") != 0 {
            if args < 0 || ast_b(args) < 0 { check_error(EC_N_UNDEFINED, "@hasField requires 2 args", ast_line(node), ast_col(node)); return TI_NEVER; }
            ti := res_type_node(ast_a(args));
            return TI_BOOL;
        }

        // @field(T, name) — type + string, returns FieldInfo
        if str_eq(name, "field") != 0 {
            if args < 0 || ast_b(args) < 0 { check_error(EC_N_UNDEFINED, "@field requires 2 args", ast_line(node), ast_col(node)); return TI_NEVER; }
            ti := res_type_node(ast_a(args));
            return TI_INT;
        }

        // @typeInfo(T) — returns TypeInfo
        if str_eq(name, "typeInfo") != 0 {
            if args < 0 { check_error(EC_N_UNDEFINED, "@typeInfo requires a type argument", ast_line(node), ast_col(node)); return TI_NEVER; }
            ti := res_type_node(args);
            return TI_INT;  // placeholder — returns handle
        }

        // @raw_int(expr) — dex 表达式 → 缩放整数原值（显式转换，数值迁移 Task 4）
        if str_eq(name, "raw_int") != 0 {
            if args < 0 { check_error(EC_N_UNDEFINED, "@raw_int requires an expression", ast_line(node), ast_col(node)); return TI_NEVER; }
            av := infer_expr(ast_a(args));
            // 参数校验：dex（或 int——int 原值即其缩放值）才可取其原值；其余类型报错
            if av != TI_DEX && av != TI_INT && av != TI_NEVER {
                check_error(EC_TF_ARG_TYPE, "@raw_int requires a dex (or int) expression", ast_line(node), ast_col(node));
                return TI_NEVER;
            }
            return TI_INT;
        }

        // @comptime(expr) — force compile-time eval
        if str_eq(name, "comptime") != 0 {
            if args < 0 { check_error(EC_N_UNDEFINED, "@comptime requires an expression", ast_line(node), ast_col(node)); return TI_NEVER; }
            v := infer_expr(ast_a(args));
            ast_set_type_val(node, v);
            return v;
        }

        // @inline(fn) — inline hint
        if str_eq(name, "inline") != 0 {
            if args < 0 { check_error(EC_N_UNDEFINED, "@inline requires a function argument", ast_line(node), ast_col(node)); return TI_NEVER; }
            v := infer_expr(ast_a(args));
            ast_set_type_val(node, v);
            return v;
        }

        // @NoBoundsCheck — no args, unit
        if str_eq(name, "NoBoundsCheck") != 0 {
            return TI_UNIT;
        }

        // @fast — no args, unit
        if str_eq(name, "fast") != 0 {
            return TI_UNIT;
        }

        // @unroll(n) — requires integer argument
        if str_eq(name, "unroll") != 0 {
            if args < 0 { check_error(EC_N_UNDEFINED, "@unroll requires an integer argument", ast_line(node), ast_col(node)); return TI_UNIT; }
            return TI_UNIT;
        }

        // @section(name) — requires string argument
        if str_eq(name, "section") != 0 {
            if args < 0 { check_error(EC_N_UNDEFINED, "@section requires a string argument", ast_line(node), ast_col(node)); return TI_UNIT; }
            return TI_UNIT;
        }

        // @hotpatch — function annotation, not an expression
        if str_eq(name, "hotpatch") != 0 {
            return TI_UNIT;
        }

        check_error(EC_N_UNDEFINED, "unknown @ builtin: " + name, ast_line(node), ast_col(node));
        return TI_UNIT;
    }

    return TI_UNIT;
}

// --- Main entry ---

fn check_all() {
    init_types();
    // 【已删除：SYM_SO_FN 保全缓冲】（第 4 批 #82/#83 T3，2026-09-17）
    // 原实现在此把 `SYM_SO_FN` 条目搬进 `alloc(128*8)` 三个临时数组、复位后再追加回去。
    // 它随「`import` 期即注册 SO_FN」而存在；本批改为**侧表 + 首次引用时物化**后：
    //   · 物化发生在 `g_sym_count` 复位**之后**（检查期首次查找）⇒ 复位前表内无 SO_FN
    //     ⇒ 存取皆为 0 ⇒ 本块成为**死码**；
    //   · 因而一并删除。**TODO #2026-09-17-1 的越界写堆随之从根上消失**（那三条 `alloc(128*8)`
    //     配合无上界的 `w64(so_names, so_count*8, …)`：索引 >128 行时越界，实测 N=2000
    //     时对合法声明 `src/stdlib/io.cr:27 read_file` 报假诊断；N=200 时**产物不变但堆已坏**）。
    //   ⚠ 该缺陷的历史不得随代码删除而消失：#98 条目保留，状态记「随本批消除」。
    g_sym_count = 0;
    g_scope_depth = 0; g_scope_bounds_cap = 0;
    g_diag_count = 0; g_diag_cap = 0;
    g_gen_map_count = 0; g_gen_map_cap = 0;
    g_gen_apply_data_count = 0;
    g_gen_apply_data_cap = 0;
    g_gen_param_count = 0; g_gen_param_cap = 0;
    g_dyn_type_set_count = 0; g_dyn_type_set_cap = 0; g_dyn_type_sets = "";

    // First pass: collect declarations
    collect_decls();
    init_builtins();

    // 【已删除：SYM_SO_FN 回填循环】（同上 T3）——与上方保全缓冲同生共死；
    // 物化改由 `find_gsym`/`find_so_fn` 的侧表回退承担（首次引用时追加，天然在复位之后）。

    // Register runtime builtins as proper SYM_FN (no .cr body, implemented in rt.s)
    // These must come after collect_decls so user-defined funcs take priority.
    ri2 : ., mut = 0;
    loop {
        if ri2 >= g_rt_builtin_count { break; }
        ni2 := r64(g_rt_builtin_names, ri2 * 8);
        ti2 := r64(g_rt_builtin_ret_types, ri2 * 8);
        if find_gsym(ni2) < 0 {  // skip if already defined by user
            si2 := g_sym_count;
            grow_syms(si2 + 1);
            sym_set_name(si2, ni2);
            sym_set_kind(si2, SYM_FN);
            sym_set_type(si2, ti2);
            sym_set_node(si2, -1);
            g_sym_count = si2 + 1;
        }
        ri2 = ri2 + 1;
    }

    // Second pass: check function bodies
    i : ., mut = 0;
    loop {
        if i >= g_func_count { break; }
        check_func(i);
        i = i + 1;
    }

    // Check global let initializers
    i = 0;
    loop {
        if i >= g_global_let_count { break; }
        check_global_let(r64(g_global_lets, i * 8));
        i = i + 1;
    }

    // Check impl-for relationships
    check_impl_for();

    // 批 6（T2/T3）：规约标注面检查（形态 + 常量折叠的唯一判定面）。见 spec_check_all 头注。
    spec_check_all();
}

// ─── 批 6：规约标注面（`#check` / `#ensure`）────────────────────────────────────
// 本批边界（裁-V5/V6 + 裁-S4/S5/S9）：
//   · **判定面 = 只做常量折叠**（唯一「红」= `#check(常量假)`）；其余一律「未证」= **不报错**。
//   · **未证绝不走诊断通道**——绿/黄只进 `--dump-vcs`（T4）；否则 fail-closed 闸门
//     （main.cr:146-175，默认阻断）会把「没证明」变成 rc=1，违反裁-V6。
//   · **表达式子集 = 无调用**（裁-V5）⇒ 纯度项**空转**；纯度时序陷阱**未被解决、只被绕开**
//     （生成期 `fi_ispure` 是乐观默认值，见本文件 3968-3977 头注）——**不得**声称已处理。
//   · 折叠器为**纯函数式**（不改 AST、不建 IR、不写任何图/表）⇒ 零足迹。

// 折叠结果侧信道：`g_spec_fold_ok` = 0 表示「本次折叠不可用（含子表达式不可折叠）」。
// 显式侧信道而非哨兵值（int 全域都是合法值 ⇒ 哨兵必然歧义）。
g_spec_fold_ok : int, mut;

// 常量折叠（int/bool 域；不可折叠 ⇒ g_spec_fold_ok = 0）。
// 覆盖 = C1 子集里**字面量闭合**的形态：int/bool 字面量 · 一元 `-`/`!` · 二元 算术/比较/逻辑。
// **不做代数化简**（如 `x*0`）——只折字面量，避免把「未证」误升为「已证」。
fn spec_fold_val(e: int) -> int {
    g_spec_fold_ok = 0;
    if e < 0 { return 0; }
    k := ast_kind(e);
    if k == EXPR_INT { g_spec_fold_ok = 1; return ast_int_val(e); }
    if k == EXPR_BOOL { g_spec_fold_ok = 1; return ast_int_val(e); }
    if k == EXPR_UNARY {
        op := ast_c(e);
        v := spec_fold_val(ast_a(e));
        if g_spec_fold_ok == 0 { return 0; }
        if op == UOP_NEG { g_spec_fold_ok = 1; return 0 - v; }
        if op == UOP_NOT { g_spec_fold_ok = 1; if v == 0 { return 1; } return 0; }
        g_spec_fold_ok = 0; return 0;
    }
    if k == EXPR_BINARY {
        op := ast_c(e);
        l := spec_fold_val(ast_a(e));
        if g_spec_fold_ok == 0 { return 0; }
        r := spec_fold_val(ast_b(e));
        if g_spec_fold_ok == 0 { return 0; }
        if op == OP_ADD { g_spec_fold_ok = 1; return l + r; }
        if op == OP_SUB { g_spec_fold_ok = 1; return l - r; }
        if op == OP_MUL { g_spec_fold_ok = 1; return l * r; }
        if op == OP_DIV { if r == 0 { g_spec_fold_ok = 0; return 0; } g_spec_fold_ok = 1; return l / r; }
        if op == OP_MOD { if r == 0 { g_spec_fold_ok = 0; return 0; } g_spec_fold_ok = 1; return l % r; }
        if op == OP_EQ { g_spec_fold_ok = 1; if l == r { return 1; } return 0; }
        if op == OP_NE { g_spec_fold_ok = 1; if l != r { return 1; } return 0; }
        if op == OP_LT { g_spec_fold_ok = 1; if l < r { return 1; } return 0; }
        if op == OP_GT { g_spec_fold_ok = 1; if l > r { return 1; } return 0; }
        if op == OP_LE { g_spec_fold_ok = 1; if l <= r { return 1; } return 0; }
        if op == OP_GE { g_spec_fold_ok = 1; if l >= r { return 1; } return 0; }
        if op == OP_AND { g_spec_fold_ok = 1; if l != 0 && r != 0 { return 1; } return 0; }
        if op == OP_OR { g_spec_fold_ok = 1; if l != 0 || r != 0 { return 1; } return 0; }
        g_spec_fold_ok = 0; return 0;
    }
    return 0;   // 变量 / 调用 / 字段 / 下标 / 字面量外一切 ⇒ 未证
}

// 规约标注面检查：逐条走侧表；**唯一硬错 = `#check(常量假)`**（`EC_V_CHECK_FALSE` = V01）。
// `#ensure` 本批不做常量红判定（后置条件在编译期无输入 ⇒ 常量假同样可判，但**留 T3 收口**：
// 本条**只判 `#check`**，避免在 T2 扩大红面）。
fn spec_check_all() {
    i : ., mut = 0;
    loop {
        if i >= g_spec_count { break; }
        // T3：`#ensure` 的常量假同样可判定且必错 ⇒ 与 `#check` 同判（T2 只判了 #check）。
        ex := spec_expr(i);
        v := spec_fold_val(ex);
        if g_spec_fold_ok != 0 {
            if v == 0 {
                spec_set_status(i, SPEC_ST_RED);
                nm : ., mut = "#check(...)";
                if spec_kind(i) == 1 { nm = "#ensure(...)"; }
                check_error(EC_V_CHECK_FALSE, nm + " is statically false", spec_line(i), spec_col(i));
            } else {
                spec_set_status(i, SPEC_ST_GREEN);
            }
        }
        i = i + 1;
    }
}

// ─── 效应/纯度修正 Task 1（P0 插队批）：真纯度计算 ─────────────────────────
// 语义出处：docs/superpowers/plans/2026-08-08-region-cfg.md:484「非纯调用才进链；
// find_func 不可得（外部函数）保守进链」。
//
// 纯（1）⟺ 下列全部成立（全按 IR/DF 面判定，一律保守）：
//   ① 体无 store 族：IR_STORE / IR_STORE_FIELD / IR_STORE_INDEX /
//      IR_STORE_INDEX_VAR / IR_STORE_PTR（裸指针写同为效应）；无 unsafe 区
//      （IR 无 unsafe 专用 opcode——按 SG_UNSAFE 区的归属函数判定）。
//   ② 体无 IO/FFI/并发效应 opcode：IR_CALL_EXTERN / IR_HOTPATCH_ROUTE /
//      IR_DYN_DISPATCH / IR_SPAWN / IR_YIELD / IR_AWAIT / IR_INLINE 见 ③。
//   ③ 传递闭包内被调者全纯：IR_CALL 的 s3 = 名 ni 经 find_func 解析（不可解析 =
//      runtime builtin ⇒ 不纯）；IR_INLINE 亦按 s1 经 find_func 解析，但 s1 的
//      含义**依发射点分两形**：调用旗标形（ir_gen.cr:1523）s1 = 函数**名 ni**；
//      `@inline(expr)` 形（ir_gen.cr:1373）s1 = **变量索引** ⇒ 该形必然解析失败、
//      被保守判不纯（误差方向安全；终审 Minor #4 记录，注释原文「同为名 ni」失实）。
//   ④ 递归/SCC ⇒ 保守不纯：不动点从「全不纯」起点**升纯**——自环/互环永远等不到
//      「被调者已纯」⇒ 自动留在不纯，无需显式 SCC 检测。
// 泛型源函数（无 IR 体、永不被调用——调用点解析到实例）：纯度 = 实例的合取
// （无实例 = 0），故「实例与源同值」恒成立。
//
// 时点：**IR 生成结束之后**（唯一入口 = df_state_finalize，见 dataflow.cr）。
// IR 体是纯度的唯一权威来源，而 IR 体逐函数生成（调用者先于被调者、含递归与
// 前向引用）⇒ check_all 尾部（声明就绪但 IR 体尚未生成）与 collect_decls 期
// （调用图未闭合）都不可用；链消费者（df_connect_state）相应后移到同一时点
// （df_replay_state_chain）——否则链只能读到生成期的乐观默认值。
//
// 默认值冻结注记：checker.cr 注册函数时的 fi_set_ispure(..., 1)（乐观默认）
// **有意保留**——IR 生成期它的唯一消费者是 ir_gen.cr 的 lazy 判定，本批明令
// 冻结该判定（use_count 时序缺陷另批修）⇒ 删掉默认值会让 lazy 全部不发射、
// 发射面逐字节改变。真纯度在 IR 生成后由本函数覆盖写回。

fn purity_op_effect(op: int) -> int {
    if op == IR_STORE           { return 1; }
    if op == IR_STORE_FIELD     { return 1; }
    if op == IR_STORE_INDEX     { return 1; }
    if op == IR_STORE_INDEX_VAR { return 1; }
    if op == IR_STORE_PTR       { return 1; }
    if op == IR_CALL_EXTERN     { return 1; }
    if op == IR_HOTPATCH_ROUTE  { return 1; }
    if op == IR_DYN_DISPATCH    { return 1; }
    if op == IR_SPAWN           { return 1; }
    if op == IR_YIELD           { return 1; }
    if op == IR_AWAIT           { return 1; }
    return 0;
}

// IR 函数序号（g_ir_func_* 表下标）→ 源 FuncInfo 下标；-1 = 越界（不可达防御）。
// 依据：IR 生成循环按源序**跳过泛型函数**发 IR；monomorph 实例只追加到 g_funcs
// 末尾（唯一创建点 = ir_gen.cr 的调用点）⇒ IR 序 = 源序非泛型子序列 ++ 实例创建序，
// 与本函数「按源序跳过泛型」的重放一致。调用方另按 g_ir_func_name_idx 复核名字，
// 复核失败即保守判不纯（防映射漂移静默错标）。
fn src_func_of_ir(irf: int) -> int {
    cnt : ., mut = 0;
    i : ., mut = 0;
    loop {
        if i >= g_func_count { return -1; }
        if fi_generic_count(i) == 0 {
            if cnt == irf { return i; }
            cnt = cnt + 1;
        }
        i = i + 1;
    }
    return -1;
}

// DF 节点序号 → 所属 IR 函数序号（-1 = 无）。g_df_func_node_start 单调 ⇒ 线性
// 取下界即上界；unsafe 区稀少，不值得为它引二分。
fn df_func_of_node(pos: int) -> int {
    best : ., mut = -1;
    irf : ., mut = 0;
    loop {
        if irf >= g_ir_func_count { break; }
        if r64(g_df_func_node_start, irf * 8) <= pos { best = irf; }
        irf = irf + 1;
    }
    return best;
}

fn compute_all_purity() {
    fcount := g_func_count;
    if fcount <= 0 { return; }
    if g_ir_func_count <= 0 { return; }   // 无 IR 体（check-only 路径）⇒ 不覆盖默认值

    // 侧表（本函数自持）：local = 局部效应/硬不纯位；pure = 当前纯度工作值；
    // callee = 每条 IR 指令的可解析被调 fi（-1 = 非调用；不可解析记在 local 位）。
    // alloc 不保证清零（rt.s bump 分配器）⇒ 三表全部显式初始化。
    local := alloc(fcount * 8);
    pure := alloc(fcount * 8);
    callee := alloc(g_ir_instr_count * 8);
    z : ., mut = 0;
    loop {
        if z >= fcount { break; }
        w64(local, z * 8, 0);
        w64(pure, z * 8, 0);
        z = z + 1;
    }
    z = 0;
    loop {
        if z >= g_ir_instr_count { break; }
        w64(callee, z * 8, -1);
        z = z + 1;
    }

    // ── 1) 逐 IR 函数扫体：局部效应位 + 调用边解析 ──
    irf : ., mut = 0;
    loop {
        if irf >= g_ir_func_count { break; }
        sfi := src_func_of_ir(irf);
        map_ok : ., mut = 1;
        if sfi < 0 { map_ok = 0; }
        else if r64(g_ir_func_name_idx, irf * 8) != fi_name(sfi) { map_ok = 0; }
        else if ast_kind(fi_ast_node(sfi)) == EXPR_EXTERN { map_ok = 0; }
        if map_ok == 0 {
            // 映射漂移/extern 声明体（无可生成的体）：保守判不纯
            if sfi >= 0 { w64(local, sfi * 8, 1); }
            irf = irf + 1; continue;
        }
        istart := r64(g_ir_func_instr_start, irf * 8);
        icnt := r64(g_ir_func_instr_count, irf * 8);
        ii := istart;
        loop {
            if ii >= istart + icnt { break; }
            op := iri_op(ii);
            if purity_op_effect(op) != 0 { w64(local, sfi * 8, 1); }
            if op == IR_CALL {
                cf := find_func(iri_s3(ii));
                if cf < 0 { w64(local, sfi * 8, 1); }   // 不可解析（runtime builtin）⇒ 不纯
                else { w64(callee, ii * 8, cf); }
            }
            if op == IR_INLINE {
                cf2 := find_func(iri_s1(ii));
                if cf2 < 0 { w64(local, sfi * 8, 1); }
                else { w64(callee, ii * 8, cf2); }
            }
            ii = ii + 1;
        }
        irf = irf + 1;
    }

    // ── 2) unsafe 区 ⇒ 归属函数不纯（IR 无 unsafe opcode：效应藏在块内裸操作里；
    //      归属 = 区起始节点落在哪个函数的节点区间）──
    si : ., mut = 0;
    loop {
        if si >= g_sg_count { break; }
        if r64(g_sgs, si * ESZ_SG + OFF_SG_KIND) == SG_UNSAFE {
            uf := df_func_of_node(r64(g_sgs, si * ESZ_SG + OFF_SG_NSTART));
            if uf >= 0 {
                usf := src_func_of_ir(uf);
                if usf >= 0 { w64(local, usf * 8, 1); }
            }
        }
        si = si + 1;
    }

    // ── 3) 不动点：全不纯起点升纯（保守单调，语义见头注 ④）──
    changed : ., mut = 1;
    loop {
        if changed == 0 { break; }
        changed = 0;
        irf = 0;
        loop {
            if irf >= g_ir_func_count { break; }
            sf := src_func_of_ir(irf);
            if sf >= 0 {
                if r64(local, sf * 8) == 0 {
                    if r64(pure, sf * 8) == 0 {
                        ist2 := r64(g_ir_func_instr_start, irf * 8);
                        ic2 := r64(g_ir_func_instr_count, irf * 8);
                        allpure : ., mut = 1;
                        ii2 := ist2;
                        loop {
                            if ii2 >= ist2 + ic2 { break; }
                            c := r64(callee, ii2 * 8);
                            if c >= 0 {
                                if r64(pure, c * 8) == 0 { allpure = 0; break; }
                            }
                            ii2 = ii2 + 1;
                        }
                        if allpure != 0 {
                            w64(pure, sf * 8, 1);
                            changed = 1;
                        }
                    }
                }
            }
            irf = irf + 1;
        }
    }

    // ── 4) 泛型源（无 IR 体）回填：源纯度 = 实例合取（无实例 = 0）──
    fi : ., mut = 0;
    loop {
        if fi >= fcount { break; }
        if fi_generic_count(fi) > 0 {
            ninst : ., mut = 0;
            allp : ., mut = 1;
            gi : ., mut = 0;
            loop {
                if gi >= g_purity_inst_count { break; }
                if r64(g_purity_inst, gi * 24) == fi {
                    ninst = ninst + 1;
                    nf := r64(g_purity_inst, gi * 24 + 16);
                    if nf >= 0 && nf < fcount {
                        if r64(pure, nf * 8) == 0 { allp = 0; }
                    } else { allp = 0; }
                }
                gi = gi + 1;
            }
            if ninst > 0 && allp != 0 { w64(pure, fi * 8, 1); }
        }
        fi = fi + 1;
    }

    // ── 5) 写回 ──
    fi = 0;
    loop {
        if fi >= fcount { break; }
        fi_set_ispure(fi, r64(pure, fi * 8));
        fi = fi + 1;
    }
}

// 自测辅助：按名查纯度（-1 = 无此函数——与 0/1 区分，防「查不到」被当「不纯」）。
fn fi_ispure_of(name_ni: int) -> int {
    fi := find_func(name_ni);
    if fi < 0 { return -1; }
    return fi_ispure(fi);
}
