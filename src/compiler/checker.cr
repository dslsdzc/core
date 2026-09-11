// === checker.core ===
// Two-pass name resolver + type checker for flat AST
// First pass: collect all function/struct/global declarations
// Second pass: type-check function bodies

// --- Type table ---
// Entries are 3 ints: kind, data, extra

fn alloc_type(kind: int, data: int, extra: int) -> int {
    idx := g_type_count;
    grow_types(idx + 1);
    w64(g_types, idx * 24, kind);
    w64(g_types, idx * 24 + 8, data);
    w64(g_types, idx * 24 + 16, extra);
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
// **例外（如实登记）**：type_equal_legacy 的 TYP_GENERIC_APPLY 分支（符号锚点：该分支的
// `get_type_data(t1) != get_type_data(t2)` 基型比较）比的是 get_type_data = base_ti（基型
// **行号**）——去重把「同名字不同出现点 ⇒ 不等」改成「同名 ⇒ 同 base 行，继续比实参」，
// 这正是本条修复的目的（P1 差异的对偶面）；其放宽面由 Task 3 对拍复跑量化，非本任务裁决面。
// Task 3 复核：判定替换后该分支**仅在引擎未知时**参与（TYP_GENERIC_APPLY 桥接为 AK_NAMED
// 不展开 → 引擎恒 -1 → 回落 legacy）；宽松方向的量化见对拍三档（old_looser）。
//
// 侧表 g_named_dedup（16B/条 {name_idx, ti}，开放寻址线性探测，与 ty_shadow.cr 的
// g_shadow_map 同式同因）。P0/P1 血泪三件套缺一即可能挂死，逐条落：
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
// 的点仍对，比行号的点错——`type_equal_legacy` 的 TYP_GENERIC_APPLY 基型比较即比行号）。
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
    // R2 P2a Task 3 评审 Critical：桥接缓存（ti→term）**同理必须作废**——本批起判定路径无条件
    // 调 sh_term_of_ti，长驻进程（corelsp 每请求 init_types）复用行号时会命中陈旧 ti→term
    // ⇒ 两个不同类型被判等（静默漏报；评审实证见 ty_shadow.cr:sh_map_reset 注记）。
    sh_map_reset();
    // R2 P2a Task 3：判定回落计数随之归零（类型行号空间作废 → 计数只对本编译期有意义；
    // LSP 每请求走 check_all → 本行 → 计数不跨请求累积）
    g_replace_unknown = 0; g_replace_bridge = 0;
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
    // R2 P2b Task 1：本质条目表（iface_registry.cr）——静态数据（AK_*/TI_* 常量 + -1/0），
    // 不 alloc 类型行、不缓存本函数刚分配的行号 ⇒ 重复调用无副作用（长驻进程每请求一次）。
    // 位置 = 9 行原生 alloc 之后（表内容不依赖类型表，此处仅为「随类型表生命周期初始化」）。
    iface_registry_init();
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
// 背景（P1 findings §6.F2）：身份判等（type_equal_legacy 的 TYP_ARRAY 分支）曾把 N 与元素判等
// 绑在一起 = N 属**类型身份**；而桥接按 R1 裁决 **N 不入身份**（AK_SEQUENCE 参数链只含元素项）
// → 判定替换（Task 3：引擎 ty_equiv）后 `[int;4]` → `[int;3]` 会**静默通过**（现状是编译错误
// error[TF01]）。用户裁决：落「常量档长度约束」——保持现状拒绝语义，不留静默缺口。本函数即
// 该约束：N 从身份中**迁出**，成为具名、可独立调用/独立测试的检查（身份分支不再比 N）。
//
// 语义（本批 = 常量档：N 皆字面量 → 编译期定 恒真/恒假）：
//   沿两类型的**结构对应位置**下钻（下钻位置覆盖 type_equal_legacy 的**递归位**：数组元素 /
//   指针元素 / 引用元素 / 切片元素 / 元组字段 / 泛型应用实参），在**数组位置**比较 N（extra）
//   ——N 必须相等；不等即 0（违反）。其余情形（异 kind / 异元数 / 非数组构造子）长度面无约束
//   → 1（满足）。**1 = 满足；0 = 违反**。
//   ⚠「同形」仅指**递归位覆盖**（下钻走得到的位），**不**指比较项相同——各构造子另有非长度
//   面，且**一律归身份判定**，本约束有意不重复（只认 N = TYP_ARRAY 的 extra 一个维度）：
//     · REF —— `type_equal_legacy` 的 TYP_REF 分支另比 `extra`（mut 标记），本函数不重复；
//     · TUPLE / GENERIC_APPLY —— 身份另比元数、APPLY 另比基型行号，同上；
//     · 反向不对称 —— PTR 的 `extra`（地址空间位 asp，`infer_expr` 的指针升格分配点）身份
//       **亦不比**（现状如此，非本任务面），本函数同样不引入该比较。
//   故切勿据「同形」推断两者判等项一致（评审 M1 收口）。
// 为何必须下钻：N 迁出身份后，嵌在非数组构造子内部的位置（`[[int;3];2]` 的数组元素位 /
//   `G<[int;3]>` 的泛型实参位 / `*[int;3]` 的指针元素位 / `(int, [int;3])` 的元组字段位）
//   不再有任何判等负责——不下钻即静默放宽（收紧面的反面）。覆盖面由 type_selftest.cr 的
//   f2.* 用例逐位钉住（同结构同长 → 1 / 同结构异长 → 0 双断）。
// 边界（如实登记）：**符号档 / 动态档未实现**（P3 面）；本批按字面量比较 extras，异 kind/异形
//   不下钻（该面由身份判定的 kind/参数结构比较负责，本函数不越权给 0 = 不误拒）。
// 无环：TYP_NAMED / TYP_GENERIC_PARAM / TYP_BASE / TYP_DYN 不下钻 → 深度 = 类型嵌套深度。
fn array_len_constraint_ok(ti_a: int, ti_b: int) -> int {
    ka := get_type_kind(ti_a);
    kb := get_type_kind(ti_b);
    if ka != kb { return 1; }
    if ka == TYP_ARRAY {
        if get_type_extra(ti_a) != get_type_extra(ti_b) { return 0; }
        return array_len_constraint_ok(get_type_data(ti_a), get_type_data(ti_b));
    }
    if ka == TYP_PTR || ka == TYP_REF || ka == TYP_SLICE {
        return array_len_constraint_ok(get_type_data(ti_a), get_type_data(ti_b));
    }
    if ka == TYP_TUPLE {
        fc := get_type_data(ti_a);
        if fc != get_type_data(ti_b) { return 1; }      // 字段数不同：身份判定负责
        fs1 := get_type_extra(ti_a);
        fs2 := get_type_extra(ti_b);
        fi : ., mut = 0;
        loop {
            if fi >= fc { break; }
            if array_len_constraint_ok(r64(g_gen_apply_data, (fs1 + fi) * 8), r64(g_gen_apply_data, (fs2 + fi) * 8)) == 0 { return 0; }
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
            if array_len_constraint_ok(r64(g_gen_apply_data, (as1 + 1 + ai) * 8), r64(g_gen_apply_data, (as2 + 1 + ai) * 8)) == 0 { return 0; }
            ai = ai + 1;
        }
        return 1;
    }
    return 1;
}

// F2 判定点组合（**站点**用）：身份判等 ∧ 常量档长度约束。
// N 不入身份（R1 裁决）⇒ 判定点必须在 type_equal 之外显式补检——否则 Task 3 替换身份实现后
// N 不匹配静默通过。返回：1 = 兼容；0 = 身份不匹配（原诊断措辞）；-1 = 长度约束违反（专属
// 措辞；**码不变**——TF01/TA01/TC02 的「门」= 拒绝集合不变，仅成因分列）。
// **总是调用 type_equal**：影子通道（ty_shadow.cr）在 type_equal 内按站点采样，站点调用次数
// 与位置必须保持不变（P1 站点覆盖 / 差异计数可比；关态仅多一次全局读，见 P1 登记）。
fn type_compat_strict(ti_a: int, ti_b: int) -> int {
    if !type_equal(ti_a, ti_b) { return 0; }
    if array_len_constraint_ok(ti_a, ti_b) == 0 { return -1; }
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

// R2 P1：本函数曾是**唯一**结构判等实现（原名 type_equal）。
// R2 P2a Task 3：改名 `type_equal_legacy`——判定权已移交引擎（见下方 `type_equal` 双函数），
// 本函数降级为两用：
//   ① 影子通道的**对拍对照物**（替换门：引擎判定 vs 旧结构判等逐点对账，见 sh_compare）；
//   ② 引擎三态返回 -1（未知）或桥接失败时的**回落实现**（unknown 政策：不得静默当 0/1）。
//   **P5 删**（引擎覆盖面补齐、unknown 清零后）。
// 内部 6 处递归调用点（数组/元组/引用/指针/切片/泛型应用）指向本名，**不**经包装 → 影子只在
// 外部决策点（#29 前 8、现 10——增站点 9/10）取样一次/次调用（递归展开不重复计数）。
// F2（Task 2）后数组分支已 **N-free**（N 迁出类型身份）——与引擎侧一致；长度面走
// array_len_constraint_ok（判定点显式补检），本函数**不得**再引回 N 比较（Task 2/3 评审裁决）。
fn type_equal_legacy(t1: int, t2: int) -> bool {
    if t1 == t2 { return true; }
    // Compare structure for non-base types
    if t1 >= 0 && t2 >= 0 && t1 < g_type_count && t2 < g_type_count {
        k1 := get_type_kind(t1);
        k2 := get_type_kind(t2);
        if k1 == TYP_NAMED && k2 == TYP_NAMED {
            return get_type_data(t1) == get_type_data(t2);
        }

        // F2（R2 P2a Task 2）：本分支**不比 N**——N 已迁出类型身份（与引擎侧一致：桥接的
        // AK_SEQUENCE 参数链不含 N）。长度拒绝语义由 array_len_constraint_ok 在**判定点**
        // 显式补检（type_compat_strict）；身份面只判结构（元素）。
        if k1 == TYP_ARRAY && k2 == TYP_ARRAY {
            return type_equal_legacy(get_type_data(t1), get_type_data(t2));
        }
        if k1 == TYP_TUPLE && k2 == TYP_TUPLE {
            if get_type_data(t1) != get_type_data(t2) { return false; }
            start1 := get_type_extra(t1);
            start2 := get_type_extra(t2);
            cnt := get_type_data(t1);
            i : ., mut = 0;
            loop {
                if i >= cnt { break; }
                if !type_equal_legacy(r64(g_gen_apply_data, (start1 + i) * 8), r64(g_gen_apply_data, (start2 + i) * 8)) { return false; }
                i = i + 1;
            }
            return true;
        }
        if k1 == TYP_REF && k2 == TYP_REF {
            return get_type_extra(t1) == get_type_extra(t2) && type_equal_legacy(get_type_data(t1), get_type_data(t2));
        }
        if k1 == TYP_PTR && k2 == TYP_PTR {
            return type_equal_legacy(get_type_data(t1), get_type_data(t2));
        }
        if k1 == TYP_SLICE && k2 == TYP_SLICE {
            return type_equal_legacy(get_type_data(t1), get_type_data(t2));
        }
        if k1 == TYP_GENERIC_APPLY && k2 == TYP_GENERIC_APPLY {
            if get_type_data(t1) != get_type_data(t2) { return false; }
            start1 := get_type_extra(t1);
            start2 := get_type_extra(t2);
            count1 := r64(g_gen_apply_data, start1 * 8);
            count2 := r64(g_gen_apply_data, start2 * 8);
            if count1 != count2 { return false; }
            ai : ., mut = 0;
            loop {
                if ai >= count1 { break; }
                if !type_equal_legacy(r64(g_gen_apply_data, (start1 + 1 + ai) * 8), r64(g_gen_apply_data, (start2 + 1 + ai) * 8)) { return false; }
                ai = ai + 1;
            }
            return true;
        }
        if k1 == TYP_GENERIC_PARAM && k2 == TYP_GENERIC_PARAM {
            return get_type_data(t1) == get_type_data(t2);
        }
    }
    return false;
}

// ─── R2 P2a Task 3：判定替换（引擎 ty_equiv 成为判定权威）───
// 判定主体（P1 的包装层拆两半：本函数 = 引擎判定，`type_equal` = 入口 + 影子对拍包装）。
//   ① 同一行快路径：t1 == t2 → true（与 legacy 首行**逐字同义**——legacy 首行也是
//      `if t1 == t2 { return true; }`，含负 ti 情形；故快路径不改任何判定结果，只省一次
//      桥接 + 引擎查询）；
//   ② 桥接（sh_term_of_ti）：任一侧译不成类型项（-1）→ 回落 legacy 并计数 g_replace_bridge；
//   ③ 引擎三态：1 → true；**0 → false（引擎结论即权威）**；-1（未知：预算耗尽/未覆盖面）→
//      **不静默当 0/1**，回落 legacy 并计数 g_replace_unknown（unknown 政策，P1 交接硬性）；
//   ④ 预算隔离：判定前后各 ty_budget_reset(200000)——引擎 memo 跨查询命中会让结果依赖预算
//      历史而非输入项（P0 终审 Critical 3 实证）；判定路径不得受前次查询影响。
// N 面（Task 2/3 评审裁决「N 不得回身份」）：本函数路径**不含** N 比较——桥接的 AK_SEQUENCE
// 参数链只含元素项，legacy 数组分支亦已 N-free；长度拒绝一律由 array_len_constraint_ok 在
// 判定点（type_compat_strict）承担。本函数**不得**引入任何 N（get_type_extra 的数组位）比较。
fn type_equal_engine(t1: int, t2: int) -> bool {
    if t1 == t2 { return true; }                       // 快路径：同一行
    a := sh_term_of_ti(t1);
    b := sh_term_of_ti(t2);
    if a < 0 || b < 0 {
        g_replace_bridge = g_replace_bridge + 1;       // 桥接缺口（登记，不静默）
        return type_equal_legacy(t1, t2);
    }
    ty_budget_reset(200000);
    e := ty_equiv(a, b);
    ty_budget_reset(200000);                           // 判定后即复位（不污染后续查询）
    if e == 1 { return true; }
    if e == 0 { return false; }
    // e == -1（未知）：不静默——回落 legacy 并计数（unknown 政策，报告单列）
    g_replace_unknown = g_replace_unknown + 1;
    return type_equal_legacy(t1, t2);
}

// R2 P1 影子对拍包装 / R2 P2a Task 3 判定入口：判定照常返回（**影子不改判定**）；影子只观察
// （--type-shadow 开时）。**对照物 = type_equal_legacy**（替换门：引擎 vs 旧结构判等逐点
// 对账——`sh_compare` 内部另算引擎判定与 `ok` 比较，故 ok 必须喂 legacy 的结论）。
// 未开 = 单次全局读 + 直接返回 → 两态产物逐字节判据据此成立。
// 本语言无三元运算符 → ok 用显式分支（`r ? 1 : 0` 不合法）。
fn type_equal(t1: int, t2: int) -> bool {
    r := type_equal_engine(t1, t2);
    if g_shadow_on != 0 {
        ok : ., mut = 0;
        if type_equal_legacy(t1, t2) { ok = 1; }
        sh_compare(t1, t2, ok);
    }
    return r;
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
        if i < 0 { return -1; }
        if sym_name(i) == name_idx && sym_kind(i) >= SYM_FN && sym_kind(i) <= SYM_SO_FN { return i; }
        i = i - 1;
    }
    return -1;
}

fn find_so_fn(name_idx: int) -> int {
    i : ., mut = 0;  // forward scan — SYM_SO_FN entries are before SYM_FN
    loop {
        if i >= g_sym_count { return -1; }
        if sym_name(i) == name_idx && sym_kind(i) == SYM_SO_FN {
            return i;
        }
        i = i + 1;
    }
    return -1;
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
        tv := ast_type_val(node);
        if tv == TY_INT { return TI_INT; }
        if tv == TY_DEX { return TI_DEX; }
        if tv == TY_BOOL { return TI_BOOL; }
        if tv == TY_STRING { return TI_STR; }
        if tv == TY_UNIT { return TI_UNIT; }
        if tv == TY_NEVER { return TI_NEVER; }
        if tv == TY_CHAR { return TI_CHAR; }
        if tv == TI_DYN { return TI_DYN; }
        return TI_UNIT;
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
        // 两趟（照 #25 元组第二根因同款）：实参类型解析**自身也会向
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

fn type_has_method(type_ni: int, method_ni: int) -> bool {
    tname := istr_get(type_ni);
    mname := istr_get(method_ni);
    mangled := tname + "." + mname;
    mangled_ni := str_intern(mangled);
    return find_func(mangled_ni) >= 0;
}

fn check_iface(type_ni: int, iface_ii: int) -> bool {
    method_count := r64(g_ifaces, iface_ii * ESZ_IFACEINFO + OFF_IF_METHOD_COUNT);
    mi : ., mut = 0;
    loop {
        if mi >= method_count { return true; }
        mbase2 := iface_ii * ESZ_IFACEINFO + OFF_IF_METHODS + mi * ESZ_IFMETHOD;
        method_ni := r64(g_ifaces, mbase2 + OFF_IFM_NAME);
        if !type_has_method(type_ni, method_ni) { return false; }
        // Also verify param count and return type match
        tname2 := istr_get(type_ni);
        mname2 := istr_get(method_ni);
        mangled2 := tname2 + "." + mname2;
        mangled_ni2 := str_intern(mangled2);
        fi2 := find_func(mangled_ni2);
        if fi2 >= 0 {
            iface_pc := r64(g_ifaces, mbase2 + OFF_IFM_PARAM_COUNT);
            if fi_param_count(fi2) != iface_pc { return false; }
            iface_rt := r64(g_ifaces, mbase2 + OFF_IFM_RET_TI);
            if fi_return_type(fi2) != iface_rt { return false; }
        }
        mi = mi + 1;
    }
    return true;
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
    // Register built-in Option type (for T? desugaring)
    option_found : ., mut = 0;
    i = 0;
    loop {
        if i >= g_enum_count { break; }
        if ei_name(i) == str_intern("Option") { option_found = 1; }
        i = i + 1;
    }
    if option_found == 0 {
        // Auto-register Option as a generic built-in type
        option_name_idx := str_intern("Option");
        option_ti := alloc_named_type(option_name_idx);
        def_sym(option_name_idx, SYM_TYPE, option_ti, -1);
    }

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
            } else if rt == TY_INT { rt_ti = TI_INT; }
            else if rt == TY_DEX { rt_ti = TI_DEX; }
            else if rt == TY_BOOL { rt_ti = TI_BOOL; }
            else if rt == TY_STRING { rt_ti = TI_STR; }
            else if rt == TY_UNIT { rt_ti = TI_UNIT; }
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
                    } else if first_rt == TY_INT { first_rt_ti = TI_INT; }
                    else if first_rt == TY_DEX { first_rt_ti = TI_DEX; }
                    else if first_rt == TY_BOOL { first_rt_ti = TI_BOOL; }
                    else if first_rt == TY_STRING { first_rt_ti = TI_STR; }
                    else if first_rt == TY_UNIT { first_rt_ti = TI_UNIT; }

                    sh_site_begin(1);   // 站点 1 = hotpatch 返回类型一致（ty_shadow.cr 头注有全表）
                    compat := type_compat_strict(rt_ti, first_rt_ti);
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
            rt_ti : ., mut = TI_UNIT;
            if ret_type == TY_INT { rt_ti = TI_INT; }
            else if ret_type == TY_DEX { rt_ti = TI_DEX; }
            else if ret_type == TY_BOOL { rt_ti = TI_BOOL; }
            else if ret_type == TY_STRING { rt_ti = TI_STR; }
            else if ret_type == TY_UNIT { rt_ti = TI_UNIT; }
            else if ret_type == TY_CHAR { rt_ti = TI_CHAR; }

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

// ─── TODO #29 ①②：struct 字面量的名字绑定 / 类型比对 辅助 ───

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
    if k == EXPR_ARRAY || k == EXPR_REFTYPE || k == EXPR_PTRTYPE {
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
    // 泛型应用**先于** get_type_name 捷径处理（#29 评审 Minor #2）：后者对
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
        tv := ast_type_val(node);
        if tv == TY_INT { return TI_INT; }
        if tv == TY_DEX { return TI_DEX; }
        if tv == TY_BOOL { return TI_BOOL; }
        if tv == TY_STRING { return TI_STR; }
        if tv == TY_UNIT { return TI_UNIT; }
        if tv == TY_CHAR { return TI_CHAR; }
        if tv == TI_DYN { return TI_DYN; }
        return TI_UNIT;
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
                sh_site_begin(2);   // 站点 2 = unify_types 泛型实参已绑定路径
                return type_compat_strict(r64(g_gen_map_types, mi * 8), concrete) == 1;
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
        sh_site_begin(3);   // 站点 3 = unify_types 泛型应用基型比较
        if type_compat_strict(get_type_data(pattern), get_type_data(concrete)) != 1 { return false; }
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
    sh_site_begin(4);   // 站点 4 = unify_types 兜底结构等价
    return type_compat_strict(pattern, concrete) == 1;
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
        pn = pn + 1;
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
            gci = gci + 1;
        }
    }

    // Store concrete type name on call node for backend monomorphization
    if g_gen_map_count > 0 {
        conc_type_ni := r64(g_gen_map_types, 0 * 8);
        conc_name_ni := get_type_name(conc_type_ni);
        if conc_name_ni >= 0 {
            ast_set_int_val(call_node, conc_name_ni);
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
                ptype := ast_type_val(pn);
                if ptype == TY_INT { ti = TI_INT; }
                else if ptype == TY_DEX { ti = TI_DEX; }
                else if ptype == TY_BOOL { ti = TI_BOOL; }
                else if ptype == TY_STRING { ti = TI_STR; }
                else if ptype == TY_CHAR { ti = TI_CHAR; }
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
        } else if return_type == TY_INT { ret_ti = TI_INT; }
        else if return_type == TY_DEX { ret_ti = TI_DEX; }
        else if return_type == TY_BOOL { ret_ti = TI_BOOL; }
        else if return_type == TY_STRING { ret_ti = TI_STR; }
        else if return_type == TY_UNIT { ret_ti = TI_UNIT; }
        else if return_type == TY_CHAR { ret_ti = TI_CHAR; }
        else if return_type == TY_NEVER { ret_ti = TI_NEVER; }
        sh_site_begin(5);   // 站点 5 = 函数体返回类型
        compat := type_compat_strict(body_ti, ret_ti);
        if compat != 1 && body_ti != TI_NEVER {
            // Skip check if return type is generic param (can't verify at declaration)
            // Skip check for flow functions (yield instead of return)
            is_flow_fn : ., mut = 0;
            if body >= 0 && scan_for_yield(body) != 0 { is_flow_fn = 1; }
            if !is_flow_fn && get_type_kind(ret_ti) != TYP_GENERIC_PARAM {
                diag_type_incompatible(compat, EC_TF_RETURN, "Function return type mismatch", ast_line(fn_node), ast_col(fn_node));
            }
        }
    }
    pop_scope();
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
            method_rt := r64(g_ifaces, mbase + OFF_IFM_RET_TI);

            // Check if the implementing type has this method
            type_name := istr_get(type_ni);
            method_name := istr_get(method_ni);
            mangled := type_name + "." + method_name;
            mangled_ni := str_intern(mangled);

            fi := find_func(mangled_ni);
            if fi < 0 {
                check_error(EC_TF_METHOD_NOT_FOUND, "Impl missing method '" + method_name + "' for interface '" + istr_get(iface_ni) + "'", 0, 0);
                mi = mi + 1;
                continue;
            }
            // Check param count
            actual_pc := fi_param_count(fi);
            if actual_pc != method_pc {
                check_error(EC_TF_METHOD_ARG_CNT, "Param count mismatch for method '" + method_name + "': expected " + int_str(method_pc) + " got " + int_str(actual_pc), 0, 0);
            }
            // Check each param type
            pti : ., mut = 0;
            loop {
                if pti >= method_pc || pti >= 8 { break; }
                expected_pt := r64(g_ifaces, mbase + OFF_IFM_PARAM_TYPES + pti * 8);
                actual_pt := fi_param_type(fi, pti);
                if expected_pt != actual_pt {
                    pnum_str := int_str(pti + 1);
                    check_error(EC_TF_METHOD_ARG_TYP, "Param " + pnum_str + " type mismatch for method '" + method_name + "' in interface '" + istr_get(iface_ni) + "'", 0, 0);
                }
                pti = pti + 1;
            }
            // Check return type
            actual_rt := fi_return_type(fi);
            if actual_rt != method_rt {
                check_error(EC_TF_RETURN, "Return type mismatch for method '" + method_name + "' in interface '" + istr_get(iface_ni) + "'", 0, 0);
            }
            mi = mi + 1;
        }
        pi = pi + 1;
    }
}

fn check_global_let(node: int) {
    val_node := ast_c(node);  // EXPR_LET: c = value
    if val_node >= 0 {
        infer_expr(val_node);
    }
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

fn infer_expr(node: int) -> int {
    if node < 0 { return TI_UNIT; }


    if ast_kind(node) == EXPR_INT { return TI_INT; }
    if ast_kind(node) == EXPR_NONE && ast_a(node) >= 0 && ast_a(node) != node { return infer_expr(ast_a(node)); }
    if ast_kind(node) == EXPR_DEX { return TI_DEX; }
    if ast_kind(node) == EXPR_STRING { return TI_STR; }
    if ast_kind(node) == EXPR_BOOL { return TI_BOOL; }
    if ast_kind(node) == EXPR_CHAR { return TI_CHAR; }

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
        if op == OP_ASSIGN {
            // Assignment: left = right
            lt := infer_expr(left);
            rt := infer_expr(right);
            sh_site_begin(6);   // 站点 6 = 赋值兼容（EXPR_BINARY + OP_ASSIGN）
            compat := type_compat_strict(lt, rt);
            if compat != 1 {
                diag_type_incompatible(compat, EC_TA_ASSIGN, "Assignment type mismatch", ast_line(node), ast_col(node));
            }
            return rt;
        }
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
            // Check: arithmetic ops require int or dex
            if lt != TI_INT && lt != TI_DEX && rt != TI_INT && rt != TI_DEX {
                check_error(EC_TB_ADD, "Arithmetic operation requires int or dex", ast_line(node), ast_col(node));
            }
            if lt == TI_DEX || rt == TI_DEX { return TI_DEX; }
            return TI_INT;
        }
        if op == OP_EQ || op == OP_NE || op == OP_LT || op == OP_GT || op == OP_LE || op == OP_GE {
            return TI_BOOL;
        }
        if op == OP_AND || op == OP_OR {
            if lt != TI_BOOL && lt != TI_INT || rt != TI_BOOL && rt != TI_INT {
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
                                            tname2 := istr_get(gen_ni);
                                            mname2 := istr_get(method_ni);
                                            mangled2 := tname2 + "." + mname2;
                                            mangled_ni2 := str_intern(mangled2);
                                            ast_set_data(node, mangled_ni2);
                                            iface_ret2 := r64(g_ifaces, imbase2 + OFF_IFM_RET_TI);
                                            if iface_ret2 == TY_INT { func_ni = mangled_ni2; return TI_INT; }
                                            if iface_ret2 == TY_DEX { func_ni = mangled_ni2; return TI_DEX; }
                                            if iface_ret2 == TY_BOOL { func_ni = mangled_ni2; return TI_BOOL; }
                                            if iface_ret2 == TY_STRING { func_ni = mangled_ni2; return TI_STR; }
                                            if iface_ret2 == TY_UNIT { func_ni = mangled_ni2; return TI_UNIT; }
                                            if iface_ret2 == TY_CHAR { func_ni = mangled_ni2; return TI_CHAR; }
                                            func_ni = mangled_ni2; return TI_UNIT;
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
                return sym_type(si);  // return type
            }
            // Check runtime builtins (no .cr body, implemented in rt.s)
            bi : ., mut = 0;
            loop {
                if bi >= g_rt_builtin_count { break; }
                if r64(g_rt_builtin_names, bi * 8) == func_ni {
                    return r64(g_rt_builtin_ret_types, bi * 8);
                }
                bi = bi + 1;
            }
            // Not found in symbol table or builtins — report error
            name := istr_get(func_ni);
            check_error(EC_N_FUNC, "Undefined function '" + name + "'", ast_line(node), ast_col(node));
            return TI_NEVER;
        }
        // Infer arg types (for side effects)
        an : ., mut = first_arg;
        loop {
            if an < 0 { break; }
            infer_expr(ast_a(an));
            an = ast_b(an);
        }
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
        if cond_ti != TI_BOOL && cond_ti != TI_INT {
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
            sh_site_begin(7);   // 站点 7 = if 分支类型合并
            compat := type_compat_strict(then_ti, else_ti);
            if compat != 1 && then_ti != TI_NEVER && else_ti != TI_NEVER {
                diag_type_incompatible(compat, EC_TC_IF_BRANCH, "If branches have different types", ast_line(node), ast_col(node));
            }
            return then_ti;
        }
        return TI_UNIT;
    }

    if ast_kind(node) == EXPR_GO {
        // a=-1, b=body;  c=iter_ni (>=0 for range mode)
        body := ast_b(node);
        push_borrow_scope();
        body_ti := infer_expr(body);
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
        if cond_ti != TI_BOOL {
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
        infer_expr(match_expr);
        res : ., mut = TI_UNIT;
        ai : ., mut = 0;
        an : ., mut = first_arm;
        loop {
            if an < 0 { break; }
            arm_pat := ast_a(an);  // EXPR_ARM: a = pattern
            arm_body := ast_b(an);  // EXPR_ARM: b = body
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
            if arr_kind == TYP_ARRAY {
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
        check_error(EC_TK_INDEX, "Cannot index non-array type", ast_line(node), ast_col(node));
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
            sh_site_begin(8);   // 站点 8 = 赋值兼容（EXPR_ASSIGN 节点）
            compat := type_compat_strict(tt, vt);
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
        // TODO #29 ①②（名字绑定 + 类型比对）：wrapper.b = 字段名 idx（parser 写入；-1 = 无名字
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
                                sh_site_begin(9);   // 站点 9 = struct 字面量字段类型 vs 声明
                                verdict := type_compat_strict(dt, vt);
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
        // TODO #29 ③：元素**同质性**检查——旧代码逐个覆盖 elem_ti（最终 = **最后一个**元素的
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
                        sh_site_begin(10);   // 站点 10 = 数组字面量元素同质性
                        verdict := type_compat_strict(elem_ti, eti);
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
        // Try operator: unwrap Option[T] → T, Result[T,E] → T
        inner_ti := infer_expr(ast_a(node));
        if get_type_kind(inner_ti) == TYP_GENERIC_APPLY {
            base_ti := get_type_data(inner_ti);
            if get_type_kind(base_ti) == TYP_NAMED {
                base_ni := get_type_data(base_ti);
                base_name := istr_get(base_ni);
                if base_name == "Option" || base_name == "Result" {
                    ga_start := get_type_extra(inner_ti);
                    if r64(g_gen_apply_data, ga_start * 8) >= 1 {
                        return r64(g_gen_apply_data, (ga_start + 1) * 8); // first type arg
                    }
                }
            }
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

        // @no_bounds_check — no args, unit
        if str_eq(name, "no_bounds_check") != 0 {
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
    // Save SYM_SO_FN entries before g_sym_count reset destroys them
    so_count : ., mut = 0;
    so_names : string, mut = alloc(128 * 8);
    so_types : string, mut = alloc(128 * 8);
    so_nodes : string, mut = alloc(128 * 8);
    si_scan : ., mut = 0;
    loop {
        if si_scan >= g_sym_count { break; }
        if sym_kind(si_scan) == SYM_SO_FN {
            w64(so_names, so_count * 8, sym_name(si_scan));
            w64(so_types, so_count * 8, sym_type(si_scan));
            w64(so_nodes, so_count * 8, sym_node(si_scan));
            so_count = so_count + 1;
        }
        si_scan = si_scan + 1;
    }
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

    // Restore SYM_SO_FN entries lost by g_sym_count reset
    ri : ., mut = 0;
    loop {
        if ri >= so_count { break; }
        si := g_sym_count;
        grow_syms(si + 1);
        sym_set_name(si, r64(so_names, ri * 8));
        sym_set_kind(si, SYM_SO_FN);
        sym_set_type(si, r64(so_types, ri * 8));
        sym_set_node(si, r64(so_nodes, ri * 8));
        g_sym_count = si + 1;
        ri = ri + 1;
    }

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
