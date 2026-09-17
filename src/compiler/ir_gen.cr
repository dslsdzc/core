// === ir_gen.core ===
// Flat AST to platform-independent IR instruction generation
// (shared IR globals declared in globals.cr)

// (IR globals declared in globals.cr)

// Subgraph-level arena tracking for compile-time size estimation
g_sg_alloc_total : string, mut;    // per-sg: cumulative alloc size
g_sg_alloc_cap   : int, mut;
g_sg_arena_var   : string, mut;    // per-sg: IR var for arena ID
g_sg_arena_var_cap : int, mut;
g_ir_source_hash : int, mut;
g_ir_source_hash_ready : int, mut;

// 切片编译期长度侧表（var → 字面量长度；-1 = 未知/无记录）。
// IR_SLICE 的字面量界（high−low）在此登记，供解引用处的越界检查
// （pass_before_array_access 的 arr_len_lit）使用——见 F11。
g_ir_slice_lens : string, mut;     // [var, len] pairs
g_ir_slice_len_count : int, mut;
g_ir_slice_len_cap : int, mut;

fn grow_ir_slice_lens(needed: int) {
    if needed < g_ir_slice_len_cap { return; }
    nc := g_ir_slice_len_cap * 2; if nc < 8 { nc = 8; } if nc < needed { nc = needed + 8; }
    nb := alloc(nc * 16); _dyncpy(g_ir_slice_lens, g_ir_slice_len_cap * 16, nb);
    g_ir_slice_lens = nb; g_ir_slice_len_cap = nc;
}

fn slice_len_get(var_idx: int) -> int {
    si : ., mut = 0;
    loop { if si >= g_ir_slice_len_count { break; }
        if r64(g_ir_slice_lens, si * 16) == var_idx { return r64(g_ir_slice_lens, si * 16 + 8); }
        si = si + 1; }
    return -1;
}

fn slice_len_set(var_idx: int, len: int) {
    si : ., mut = 0;
    loop { if si >= g_ir_slice_len_count { break; }
        if r64(g_ir_slice_lens, si * 16) == var_idx {
            w64(g_ir_slice_lens, si * 16 + 8, len);
            return;
        }
        si = si + 1; }
    if len < 0 { return; }
    grow_ir_slice_lens(g_ir_slice_len_count + 1);
    w64(g_ir_slice_lens, g_ir_slice_len_count * 16, var_idx);
    w64(g_ir_slice_lens, g_ir_slice_len_count * 16 + 8, len);
    g_ir_slice_len_count = g_ir_slice_len_count + 1;
}

// F11（运行时界切片，2026-09-05 扩展）：len 字段编码——
// >= 0 = 字面量长度；<= -2 = 长度 IR 变量（-2-len_var，避开 -1 清除码）；-1 = 已清除/无记录。
fn slice_len_raw_set(var_idx: int, len_code: int) {
    si : ., mut = 0;
    loop { if si >= g_ir_slice_len_count { break; }
        if r64(g_ir_slice_lens, si * 16) == var_idx {
            w64(g_ir_slice_lens, si * 16 + 8, len_code);
            return;
        }
        si = si + 1; }
    if len_code == -1 { return; }  // 清除无条目 = no-op；负编码（长度变量）允许新增
    grow_ir_slice_lens(g_ir_slice_len_count + 1);
    w64(g_ir_slice_lens, g_ir_slice_len_count * 16, var_idx);
    w64(g_ir_slice_lens, g_ir_slice_len_count * 16 + 8, len_code);
    g_ir_slice_len_count = g_ir_slice_len_count + 1;
}

// 登记运行时界切片的长度变量；查询返回 len_var（无 → -1）。
fn slice_len_var_set(var_idx: int, len_var: int) {
    if var_idx < 0 || len_var < 0 { return; }
    slice_len_raw_set(var_idx, -2 - len_var);
}

fn slice_len_var_get(var_idx: int) -> int {
    si : ., mut = 0;
    loop { if si >= g_ir_slice_len_count { break; }
        if r64(g_ir_slice_lens, si * 16) == var_idx {
            v := r64(g_ir_slice_lens, si * 16 + 8);
            if v <= -2 { return -2 - v; }
            return -1;
        }
        si = si + 1; }
    return -1;
}

// 切片长度沿赋值/LET 传播：无条件同步 src 记录到 dst——src 无记录
// 时清除 dst（防非切片赋值后陈旧长度残留导致误守卫）。
fn slice_len_copy_to(dst_var: int, src_var: int) {
    si : ., mut = 0;
    loop { if si >= g_ir_slice_len_count { break; }
        if r64(g_ir_slice_lens, si * 16) == src_var {
            slice_len_raw_set(dst_var, r64(g_ir_slice_lens, si * 16 + 8));
            return;
        }
        si = si + 1; }
    slice_len_raw_set(dst_var, -1);
}

// 切片解引用守卫（运行时界长度）：s1 = idx 变量/字面量，上限 = 长度变量
// （IR_BOUNDS_CHECK ti=1 动态上限——与 emit_string_bounds 同机制）。
fn emit_slice_bounds(arr_var: int, idx_var: int) {
    if arr_var < 0 || idx_var < 0 { return; }
    lv := slice_len_var_get(arr_var);
    if lv >= 0 { emit(IR_BOUNDS_CHECK, -1, idx_var, lv, 0, 1); }
}

fn emit_slice_lit_bounds(arr_var: int, idx_lit: int) {
    if arr_var < 0 { return; }
    lv := slice_len_var_get(arr_var);
    if lv >= 0 {
        t := new_ir_var("_slice_idx", TI_INT);
        emit(IR_CONST, t, idx_lit, 0, 0, TI_INT);
        emit(IR_BOUNDS_CHECK, -1, t, lv, 0, 1);
    }
}

// 数组/切片的编译期长度：TYP_ARRAY 的 extra=size；切片查侧表（字面量界）。
// 未知 → -1（ext_safety 不发射 IR_BOUNDS_CHECK）。
fn arr_len_lit_of(arr_var: int) -> int {
    if arr_var < 0 { return -1; }
    ti := irv_type(arr_var);
    if ti >= 0 && ti < g_type_count && get_type_kind(ti) == TYP_ARRAY {
        return get_type_extra(ti);
    }
    if ti == TI_STR {
        prod := r64(g_df_var_producer, arr_var * 8);
        // R2 P5 Task 2（D19）：读 **派生码**（不是 40 槽——单槽化后 40 槽 = 类型项引用）；
        // 常量节点的行是原子基行 ⇒ 派生码逐字节 ≡ 单槽化前该槽的混用码。
        if prod >= 0 && r64(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_OPCODE) == IR_CONST &&
           sh_dfn_code_of_slots(r64(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_TK),
                                r64(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_AUX)) == TI_STR {
            return istr_len(r64(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_S1));
        }
    }
    return slice_len_get(arr_var);
}

fn emit_string_bounds(arr_var: int, idx_var: int) {
    if arr_var < 0 || idx_var < 0 || irv_type(arr_var) != TI_STR { return; }
    len_var := new_ir_var("str_len", TI_INT);
    emit(IR_CALL, len_var, arr_var, 1, str_intern("str_len"), TI_INT);
    emit(IR_BOUNDS_CHECK, -1, idx_var, len_var, 0, 1);
}

// 字面量下标 + 字符串 → 运行时边界守卫（M-2 遗留：emit_string_bounds
// 只覆盖变量下标路径，常量下标路径与 arr_len_lit 两头落空——静默越界）。
fn emit_string_lit_bounds(arr_var: int, idx_lit: int) {
    if arr_var < 0 || irv_type(arr_var) != TI_STR { return; }
    idx_var := new_ir_var("_idx_lit", TI_INT);
    emit(IR_CONST, idx_var, idx_lit, 0, 0, TI_INT);
    emit_string_bounds(arr_var, idx_var);
}

fn grow_sg_alloc(needed: int) {
    if needed < g_sg_alloc_cap { return; }
    nc := g_sg_alloc_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 8); _dyncpy(g_sg_alloc_total, g_sg_alloc_cap * 8, nb); g_sg_alloc_total = nb; g_sg_alloc_cap = nc; }

fn grow_sg_arena_var(needed: int) {
    if needed < g_sg_arena_var_cap { return; }
    nc := g_sg_arena_var_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 8); _dyncpy(g_sg_arena_var, g_sg_arena_var_cap * 8, nb); g_sg_arena_var = nb; g_sg_arena_var_cap = nc; }

fn sg_alloc_push(kind: int) {
    grow_sg_alloc(g_sg_count + 1);
    grow_sg_arena_var(g_sg_count + 1);
    w64(g_sg_alloc_total, g_sg_count * 8, 0);
    sg_push(kind);
}

fn sg_alloc_pop() {
    total := r64(g_sg_alloc_total, (g_sg_count - 1) * 8);
    arena_var := r64(g_sg_arena_var, (g_sg_count - 1) * 8);
    sg_pop();
    emit(IR_ARENA_RESET, -1, arena_var, 0, 0, 0);
}

fn track_alloc_size(size: int) {
    if g_sg_count > 0 && str_len(g_sg_alloc_total) > 0 {
        prev := r64(g_sg_alloc_total, (g_sg_count - 1) * 8);
        w64(g_sg_alloc_total, (g_sg_count - 1) * 8, prev + size);
    }
}

fn new_ir_var(name: string, type_idx: int) -> int {
    idx := g_ir_var_count;
    grow_ir_vars(idx + 1);
    irv_set_name(idx, str_intern(name));
    irv_set_id(idx, idx);
    irv_set_type(idx, type_idx);
    g_ir_var_count = idx + 1;
    return idx;
}

// ── 可选运行期表示面（R2 P4 Task 5；裁决 5「解包侧判表示」；附录 B.7）──
// 事实：`Some(1)`/`None` 走 IR_MAKE_ENUM 对象（[tag][payload…]），而 `T?` 槽里的
// **裸值**仍是裸值 ⇒ 同一 `T?` 值两种表示；`Some` 臂的载荷解包（IR_LOAD_FIELD fi+1）
// 把裸值当对象解引用 ⇒ 双路径 SIGSEGV（check/build rc=0 零诊断）。
// 机制（**纯 IR**：无新 opcode、无 ABI/帧布局改动 ⇒ ELF 后端与解释器天然同源）：
// 每个可选槽（局部/形参/调用结果）配一个**表示位 IR 变量**（普通 int 局部，运行期值：
// 0 = 裸值、1 = 装箱）。写点置位（静态已知 → 常量；源已配表示位 → 拷贝），**解包点
// 分派**（`match` 的 Some/None 臂、`?`）：
//   · 裸值（0）→ 槽值**即**载荷（Some 臂直取、不读 tag；None 臂不命中）
//   · 装箱（≠0）→ 既有 tag 分派 + 字段 fi+1 取载荷（逐字不变）
// 跨函数面（返回/形参）用隐藏全局信道（纯 IR：返回点写/调用点读、调用点写/被调序言读）。
// 未覆盖面（结构体字段/数组元素/全局槽/match 结果/惰性 thunk）：不配表示位 ⇒ 解包走
// **既有**装箱假定（P3 前语义）——响亮失败或既有正确值，不新增静默错值（逐形态实测入报告）。
// g_optrep_on 关（AST 无 EXPR_OPTIONAL 且无 `Some`/`None`）⇒ 本面**零足迹**（发射面逐字节不变）。

// 表示码常量 OE_BARE/OE_BOXED 声明在 **globals.cr**（负值文件级常量放本文件会静默读 0
// ——见该处注记与 iface_registry.cr:23 先例；实测踩过）。

fn grow_ir_var_rep(needed: int) {
    if needed < g_ir_var_rep_cap { return; }
    nc := g_ir_var_rep_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 8); _dyncpy(g_ir_var_rep, g_ir_var_rep_cap * 8, nb);
    // 新槽填 **-1（哨兵 = 无表示位）**——alloc 零初始化，不填则「未写槽」被读成
    // 表示位 var 0（每个值都被判成「有表示位」= 静默错值；实测踩过：`None` 初值
    // 的表示位被读成 var0 的当前值 0 = 裸值）。照 tag2l.cr 的 tag 区初始化先例。
    z : ., mut = g_ir_var_rep_cap;
    loop { if z >= nc { break; } w64(nb, z * 8, -1); z = z + 1; }
    g_ir_var_rep = nb; g_ir_var_rep_cap = nc;
}

// 槽的表示位变量索引（-1 = 无表示位 = 非可选槽 / 未覆盖面 / 本编译单元未启用）。
// 守卫走 **cap（int 全局，默认 0）而非 str_len(base)**——base 未分配时是空串/空指针，
// 未初始化的 str_len 即 SIGSEGV（实测：文件路径（main.cr 逐函数 + .cir 缓存）不经过
// 批量入口的复位面 ⇒ 本函数必须自守卫）。
fn irv_rep(var_idx: int) -> int {
    if var_idx < 0 { return -1; }
    if g_ir_var_rep_cap <= 0 { return -1; }
    if var_idx >= g_ir_var_rep_cap { return -1; }
    return r64(g_ir_var_rep, var_idx * 8);
}

fn irv_set_rep(var_idx: int, rep_var: int) {
    if var_idx < 0 { return; }
    grow_ir_var_rep(var_idx + 1);
    w64(g_ir_var_rep, var_idx * 8, rep_var);
}

// 置表示位：enc >= 0 → 从该表示位槽拷贝；OE_BARE/OE_BOXED → 直接常量写。
fn emit_rep_set(rep_var: int, enc: int) {
    if rep_var < 0 { return; }
    if enc == oe_bare() { emit(IR_CONST, rep_var, 0, 0, 0, TI_INT); return; }
    if enc == oe_boxed() { emit(IR_CONST, rep_var, 1, 0, 0, TI_INT); return; }
    if enc >= 0 { emit(IR_STORE, -1, rep_var, enc, 0, 0); }
}

// 给可选槽配表示位变量（初始值 = 1 装箱 = 既有语义）；非可选/未启用 → -1。
fn opt_rep_slot(ti: int, name: string) -> int {
    if g_optrep_on == 0 { return -1; }
    if ti < 0 || ti >= g_type_count { return -1; }
    if get_type_kind(ti) != TYP_OPTIONAL { return -1; }
    rv := new_ir_var(name + "_rep", TI_INT);
    emit(IR_CONST, rv, 1, 0, 0, TI_INT);
    return rv;
}

// 全局槽的声明类型是否可选（globals 无表示位 ⇒ 视作未覆盖面；照声明区分裸/装箱假定）。
fn global_decl_optional(name_ni: int) -> int {
    gi : ., mut = 0;
    loop {
        if gi >= g_global_let_count { break; }
        lnode := r64(g_global_lets, gi * 8);
        if ast_a(lnode) == name_ni {
            tn := ast_b(lnode);
            if tn >= 0 && res_type_node(tn) >= 0 {
                if get_type_kind(res_type_node(tn)) == TYP_OPTIONAL { return 1; }
            }
            return 0;
        }
        gi = gi + 1;
    }
    return 0;
}

// 被调方返回类型是否可选。判据走**返回类型节点**（`EXPR_FN.type_val`）而非
// `fi_return_type`：后者是 parser 存的**裸类型码**，而 `T?` 的类型节点 `type_val` = 0
// ⇒ 被读成 int 行、判据恒假（实测踩过：裸值返回不写返回信道 + 调用点不读信道，
// 回落装箱假定 ⇒ `fn g() -> int? { return 5; }` 的调用点解包仍崩）。
fn callee_ret_optional(func_ni: int) -> int {
    if func_ni < 0 { return 0; }
    cfi := find_func(func_ni);
    if cfi < 0 { return 0; }
    cfn := fi_ast_node(cfi);
    if cfn < 0 || ast_kind(cfn) != EXPR_FN { return 0; }
    rtn := ast_type_val(cfn);
    if rtn < 0 { return 0; }
    rti := res_type_node(rtn);
    if rti < 0 || rti >= g_type_count { return 0; }
    if get_type_kind(rti) == TYP_OPTIONAL { return 1; }
    return 0;
}

// ── 容量批 T2（裁-CAP-1 (a)）：可选**聚合槽**的存储边界规范化（写点装箱）──
// 法则：可选聚合槽（结构体字段 / 数组·切片元素 / 元组元素 / 枚举载荷 / 全局槽）任何时刻恒持
// **装箱值（Some 对象）**或 None；**裸 T 值在写点装箱**。读侧零改动（既有装箱假定）。
// 局部/形参/返回/调用结果**不走本律**（R2 P4 Task 5 表示位机制不变，可持裸值）。
// 零足迹：目标槽类型不可选 ⇒ 本组函数恒不发射任何 IR（非可选程序逐字节不变）。
// 未覆盖面（登记）：指针写 `IR_STORE_PTR`——同一站点同时服务局部与聚合槽，装箱会与局部
// 表示位冲突（实测 c1 今日正确 / 装箱后静默错值）；元组·数组字面量的非 ident/调用元素。

// 槽声明类型侧表（var → 声明类型索引；-1 = 无注解/未知）。仅进程内状态，零布局变更。
// 内容（IR var 索引 → 类型索引）由声明面写入（LET 注解 / 形参类型节点），读点 = 元素写。
fn grow_ir_var_decl(needed: int) {
    if needed < g_ir_var_decl_cap { return; }
    nc := g_ir_var_decl_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 8); _dyncpy(g_ir_var_decl_ti, g_ir_var_decl_cap * 8, nb);
    z : ., mut = g_ir_var_decl_cap;
    loop { if z >= nc { break; } w64(nb, z * 8, -1); z = z + 1; }
    g_ir_var_decl_ti = nb; g_ir_var_decl_cap = nc;
}
fn irv_decl_ti(v: int) -> int {
    if v < 0 { return -1; }
    if g_ir_var_decl_cap <= 0 { return -1; }
    if v >= g_ir_var_decl_cap { return -1; }
    return r64(g_ir_var_decl_ti, v * 8);
}
fn irv_set_decl_ti(v: int, ti: int) {
    if v < 0 || ti < 0 { return; }
    grow_ir_var_decl(v + 1);
    w64(g_ir_var_decl_ti, v * 8, ti);
}

// 目标槽类型是否可选（未知/越界 ⇒ 0 = 不装箱）
fn ti_is_optional(ti: int) -> int {
    if ti < 0 { return 0; }
    if ti >= g_type_count { return 0; }
    if get_type_kind(ti) == TYP_OPTIONAL { return 1; }
    return 0;
}

// 槽（IR var）**声明**类型：声明侧表优先，否则运行期类型
fn slot_decl_ti(v: int) -> int {
    d := irv_decl_ti(v);
    if d >= 0 { return d; }
    return irv_type(v);
}

// 声明类型 → 数组/切片元素类型（-1 = 非数组/切片）
fn elem_ti_of_decl(ti: int) -> int {
    if ti < 0 { return -1; }
    if ti >= g_type_count { return -1; }
    k := get_type_kind(ti);
    if k == TYP_ARRAY || k == TYP_SLICE { return get_type_data(ti); }
    return -1;
}

// 数组/切片元素类型（-1 = 非数组/切片或未知）
fn elem_ti_of(arr_var: int) -> int {
    return elem_ti_of_decl(slot_decl_ti(arr_var));
}

// 结构体字段声明类型（field_node = EXPR_FIELD 目标节点；checker 写入 ast_c = 结构体名 ni；
// 数字元组下标形（ast_type_val > 0）不是结构体字段 ⇒ 不判）
fn field_ti_of_node(field_node: int, fi: int) -> int {
    if field_node < 0 || fi < 0 { return -1; }
    if ast_type_val(field_node) > 0 { return -1; }
    si := find_struct(ast_c(field_node));
    if si < 0 { return -1; }
    return res_type_node(si_field_type_node(si, fi));
}

// 结构体行字段声明类型（结构体字面量写点用；si = 行，来自 find_struct_by_name）
fn struct_row_field_ti(si: int, fi: int) -> int {
    if si < 0 || fi < 0 { return -1; }
    return res_type_node(si_field_type_node(si, fi));
}

// 全局槽声明类型（-1 = 非全局/无类型节点）
fn global_decl_ti(name_ni: int) -> int {
    gi : ., mut = 0;
    loop {
        if gi >= g_global_let_count { break; }
        lnode := r64(g_global_lets, gi * 8);
        if ast_a(lnode) == name_ni {
            tn := ast_b(lnode);
            if tn >= 0 { return res_type_node(tn); }
            return -1;
        }
        gi = gi + 1;
    }
    return -1;
}

// 枚举变体载荷声明类型（-1 = 非用户枚举构造器/未知）
fn enum_payload_ti(name_ni: int, pos: int) -> int {
    si := find_gsym(name_ni);
    if si < 0 { return -1; }
    ei := find_enum_row_of(sym_type(si));
    if ei < 0 { return -1; }
    vi : ., mut = 0;
    loop {
        if vi >= ei_variant_count(ei) { return -1; }
        if ei_variant_name(ei, vi) == name_ni {
            return res_type_node(ei_variant_type_node(ei, vi, pos));
        }
        vi = vi + 1;
    }
    return -1;
}

// ── 聚合读**结果槽的声明面形式**（TODO #2026-09-16-16 批 2 T3 · 裁-AGG-1 ①）──────────────────────
// 聚合槽的规范存储形式**恒为精确（scaled）**（apx 批不变量「聚合面不存在 apx 形式」；写点漏斗
// `dex_slot_norm:1059` 与 :2725/:2688/:2774/:2902 各写点均按此规范化）⇒ 只要**声明面**是 dex
// （类型节点 `TY_DEX`），读槽就应当定型 `TI_DEX_S`；其余形态**一律保持 `TI_INT`**（零足迹：
// 非 dex 程序逐字节不变）。
// **零 alloc（GC12′）**：只做**节点判**（`ast_kind(tn)==0 && ast_type_val(tn)==TY_DEX`）与
// **纯表读**（`elem_ti_of_decl`/`get_type_kind`/`get_type_data`）——**不调** `res_type_node`/
// `alloc_type`（那会新增可能 alloc 的站点，破坏暖缓存不变式）。
// **覆盖面（本批）** = 结构体字段读 / 数组·切片元素读（元素 ti 可由数组型取得）/ match 臂载荷绑定。
// **未覆盖面（登记，见计划 §10）** = 元组数字下标（裁-AGG-3：元组无声明面）· match 结果槽
// （裁-AGG-2：多臂可异型）· 泛型字段/元素（裁-AGG-4：声明型 = 类型参数）· `IR_SLICE` 产物的
// 元素读（切片 var 的 IR 型恒 `TI_INT`，元素形式无处寄存）。
fn agg_read_form_is_dex(tn: int) -> int {
    if tn < 0 { return 0; }
    if ast_kind(tn) != 0 { return 0; }
    if ast_type_val(tn) == TY_DEX { return 1; }
    return 0;
}

// 结构体字段读（`EXPR_FIELD`；数字元组下标形态 `ast_type_val > 0` 无声明面 ⇒ 不判）
fn agg_field_read_form(field_node: int, fi: int) -> int {
    if field_node < 0 || fi < 0 { return TI_INT; }
    if ast_type_val(field_node) > 0 { return TI_INT; }
    si := find_struct(ast_c(field_node));
    if si < 0 { return TI_INT; }
    if agg_read_form_is_dex(si_field_type_node(si, fi)) != 0 { return TI_DEX_S; }
    return TI_INT;
}

// 数组/切片元素读：元素 ti 由**数组 var 的型**取得（纯表读）；`TI_DEX`（apx 声明形态的
// 元素 ti）与 `TI_DEX_S` 都归一到**精确**读槽（聚合存储 = scaled）。
fn agg_elem_read_form(arr_var: int) -> int {
    et := elem_ti_of_decl(slot_decl_ti(arr_var));
    if et == TI_DEX || et == TI_DEX_S { return TI_DEX_S; }
    return TI_INT;
}

// match 臂载荷绑定读（`EXPR_ENUMPAT`：a=变体名 ni、b=首子模式、c=子模式数）
fn agg_payload_read_form(pat_node: int, pos: int) -> int {
    if pat_node < 0 || pos < 0 { return TI_INT; }
    name_ni := ast_a(pat_node);
    si := find_gsym(name_ni);
    if si < 0 { return TI_INT; }
    ei := find_enum_row_of(sym_type(si));
    if ei < 0 { return TI_INT; }
    vi : ., mut = 0;
    loop {
        if vi >= ei_variant_count(ei) { return TI_INT; }
        if ei_variant_name(ei, vi) == name_ni {
            if agg_read_form_is_dex(ei_variant_type_node(ei, vi, pos)) != 0 { return TI_DEX_S; }
            return TI_INT;
        }
        vi = vi + 1;
    }
    return TI_INT;
}

// 元素表达式（元组/数组字面量的元素槽无声明面）的可选性：**保守 = 不可选 ⇒ 不装箱**
// 覆盖面 = ident（声明侧表）/ 调用（被调返回类型可选）；其余形态登记为未覆盖面。
fn elem_node_optional(node: int) -> int {
    if node < 0 { return 0; }
    k := ast_kind(node);
    if k == EXPR_IDENT {
        lv := find_local(ast_int_val(node));
        if lv >= 0 { return ti_is_optional(slot_decl_ti(lv)); }
        return 0;
    }
    if k == EXPR_CALL {
        ni := ast_a(node);
        fi2 := find_func(ni);
        if fi2 >= 0 { return callee_ret_optional(ni); }
        return 0;
    }
    return 0;
}

// (A) T3（裁-T3-1）：元素表达式的**可选感知元素类型**（-1 = 不可选/未知面）。
// 字面量/切片两站点的声明面登记用。**调用点必须已判 `g_optrep_on`**——Some/None/调用
// 三支会 `alloc_type`（零足迹教训：新增类型面查询前先核是否 alloc）。
//   `Some(x)` / `None`（关键字形）⇒ `T?`（内层此处不可得 ⇒ TI_UNIT 占位；`ti_is_optional`
//   只看 kind ⇒ 写点装箱判定成立）；`ident`（声明面可选）⇒ 其声明类型；`call`（返回可选）
//   ⇒ `T?` 占位；其余 ⇒ -1（不可选面）。
fn elem_ti_of_node(node: int) -> int {
    if node < 0 { return -1; }
    k := ast_kind(node);
    if k == EXPR_ENUM_CONSTRUCTOR {
        nm := istr_get(ast_a(node));
        if str_eq(nm, "Some") != 0 || str_eq(nm, "None") != 0 {
            return alloc_type(TYP_OPTIONAL, TI_UNIT, 0);
        }
        return -1;
    }
    if k == EXPR_IDENT {
        lv := find_local(ast_int_val(node));
        if lv >= 0 {
            dti := slot_decl_ti(lv);
            if ti_is_optional(dti) != 0 { return dti; }
        }
        return -1;
    }
    if k == EXPR_CALL {
        ni := ast_a(node);
        if find_func(ni) >= 0 && callee_ret_optional(ni) != 0 {
            return alloc_type(TYP_OPTIONAL, TI_UNIT, 0);
        }
        return -1;
    }
    return -1;
}

// 装箱体（静态）：obj = Some(v)（无新 opcode；形态照既有 EXPR_ENUM_CONSTRUCTOR 发射：
// IR_MAKE_ENUM 的 s1 = 变体名索引、载荷经 IR_STORE_FIELD 存 fi+1；tag 值 = 名索引）
fn emit_box_some(val_var: int) -> int {
    obj := new_ir_var("box", TI_INT);
    emit(IR_MAKE_ENUM, obj, str_intern("Some"), 1, 0, 0);
    emit(IR_STORE_FIELD, -1, obj, val_var, 1, 0);
    return obj;
}

// 写点规范化（按**可选性标志**）：不可选 ⇒ 原样（零 IR）；已装箱 ⇒ 原样；
// 静态裸值 ⇒ 直接装箱；源槽带表示位 ⇒ **运行期条件装箱**（裸则装、装箱则原样）。
fn box_for_slot_flag(val_node: int, val_var: int, is_opt: int) -> int {
    if val_var < 0 { return val_var; }
    if is_opt == 0 { return val_var; }
    enc := rep_enc_of_expr(val_node, val_var);
    if enc == oe_boxed() { return val_var; }
    if enc == oe_bare() { return emit_box_some(val_var); }
    dest := new_ir_var("boxed", TI_INT);
    bare_lbl := new_label();
    keep_lbl := new_label();
    end_lbl := new_label();
    zb := new_ir_var("_bz", TI_INT);
    emit(IR_CONST, zb, 0, 0, 0, TI_INT);
    isb := new_ir_var("box_isbare", TI_INT);
    emit(IR_BINARY, isb, enc, zb, OP_EQ, 0);
    emit(IR_BRANCH, -1, isb, bare_lbl, keep_lbl, 0);
    emit(IR_LABEL, -1, bare_lbl, 0, 0, 0);
    boxv := emit_box_some(val_var);
    emit(IR_STORE, -1, dest, boxv, 0, 0);
    emit(IR_JUMP, -1, end_lbl, 0, 0, 0);
    emit(IR_LABEL, -1, keep_lbl, 0, 0, 0);
    emit(IR_STORE, -1, dest, val_var, 0, 0);
    emit(IR_LABEL, -1, end_lbl, 0, 0, 0);
    return dest;
}

// 写点规范化（按**目标槽类型**）
fn box_for_optional_slot(val_node: int, val_var: int, slot_ti: int) -> int {
    return box_for_slot_flag(val_node, val_var, ti_is_optional(slot_ti));
}

// 值表达式的**静态表示判定**（解包侧判表示的另一半：写点置位的入参）。
// 返回：>= 0 = 从该表位槽拷贝（源值自身已配表示位：可选局部/形参/调用结果）；
//   OE_BARE = 静态裸值（T 值注入 `T?`：字面量/算术/解包结果/非可选槽/聚合字面量…）；
//   OE_BOXED = 静态装箱（`Some`/`None`）**或**未覆盖面回落（字段/下标/match 结果/
//   惰性 thunk/未识别形态）——回落取装箱 = P3 前既有语义，绝不新造静默错值。
fn rep_enc_of_expr(node: int, val_var: int) -> int {
    if val_var >= 0 {
        rv := irv_rep(val_var);
        if rv >= 0 { return rv; }
    }
    if node < 0 { return oe_boxed(); }
    k := ast_kind(node);
    if k == EXPR_ENUM_CONSTRUCTOR {
        nm := istr_get(ast_a(node));
        if str_eq(nm, "Some") != 0 || str_eq(nm, "None") != 0 { return oe_boxed(); }
        return oe_bare();  // 用户枚举变体 = T 值（对象指针即载荷）
    }
    if k == EXPR_INT || k == EXPR_BOOL || k == EXPR_DEX || k == EXPR_STRING { return oe_bare(); }
    if k == EXPR_CHAR { return oe_bare(); }
    if k == EXPR_BINARY || k == EXPR_UNARY || k == EXPR_AS { return oe_bare(); }
    if k == EXPR_TRY { return oe_bare(); }  // `?` 解包结果 = T 值
    if k == EXPR_STRUCT || k == EXPR_ARRAY || k == EXPR_TUPLE { return oe_bare(); }
    if k == EXPR_IDENT {
        ni := ast_int_val(node);
        if find_local(ni) >= 0 { return oe_bare(); }  // 无表示位（上方已排除可选槽）= 非可选槽
        gv := find_global(ni);
        if gv >= 0 {
            if global_decl_optional(ni) != 0 { return oe_boxed(); }
            return oe_bare();
        }
        return oe_bare();  // 枚举裸变体等 T 值
    }
    return oe_boxed();
}

fn emit(opcode: int, dest: int, src1: int, src2: int, src3: int, type_kind: int) {
    // Build linear IR (.ccr) — consumed by x86-64 backend
    idx := g_ir_instr_count;
    grow_ir_instrs(idx + 1);
    iri_set_op(idx, opcode);
    iri_set_dest(idx, dest);
    iri_set_s1(idx, src1);
    iri_set_s2(idx, src2);
    iri_set_s3(idx, src3);
    // R2 P5 Task 2（D19 单槽化）：类型面**单源** = DFNode 的（项, 辅码）两槽。
    // 本处是**唯一**拆分点：同一次 sh_tk_split 同时喂 DFNode 两槽与 iri_tk 的派生码
    // （sh_dfn_code_of_slots）——既无第二真源，也不可能两处漂移。
    sh_tk_split(opcode, type_kind);
    iri_set_tk(idx, sh_dfn_code_of_slots(g_sh_slot_term, g_sh_slot_aux));
    g_ir_instr_count = idx + 1;
    // Build dataflow graph (.cir) in parallel
    // 拆分时点 = **emit 期**（不得后移到 save 前：快照在 IR 生成期逐函数写 ⇒ 后填
    // 必然冷/暖分歧）。代价 = 每 emit 一次分类查询（非类型面 op = 几次整数比较即
    // 返回；类型面 op = sh_term_of_ti 的原生快路径/桥接缓存，实测耗时见报告 §6）。
    df_create_node(opcode, dest, src1, src2, src3, g_sh_slot_term, g_sh_slot_aux);
}

fn new_label() -> int {
    lbl := g_next_label;
    g_next_label = g_next_label + 1;
    return lbl;
}

fn bind_local(name_idx: int, var_idx: int) {
    grow_ir_locals(g_ir_local_count + 1);
    w64(g_ir_locals, g_ir_local_count  * 16, name_idx);
    w64(g_ir_locals, g_ir_local_count  * 16 + 8, var_idx);
    g_ir_local_count = g_ir_local_count + 1;
}

fn find_local(name_idx: int) -> int {
    i : ., mut = g_ir_local_count - 1;
    loop {
        if i < 0 { return -1; }
        if r64(g_ir_locals, i * 16) == name_idx { return r64(g_ir_locals, i * 16 + 8); }
        i = i - 1;
    }
    return -1;
}

fn find_global(name_idx: int) -> int {
    i : ., mut = g_ir_global_count - 1;
    loop {
        if i < 0 { return -1; }
        if r64(g_ir_globals, i * 24) == name_idx { return r64(g_ir_globals, i * 24 + 8); }
        i = i - 1;
    }
    return -1;
}

// Return the literal initializer AST node for an immutable module-level
// constant.  The ELF backend has no data initializers, so leaving these as
// BSS globals turns values such as T_FN and ESZ_TOKEN into zero at runtime.
fn find_global_const_node(name_idx: int) -> int {
    i : ., mut = g_global_let_count - 1;
    loop {
        if i < 0 { break; }
        node := r64(g_global_lets, i * 8);
        if ast_a(node) == name_idx && ast_data(node) == 0 {
            value_node := ast_c(node);
            if value_node >= 0 {
                value_kind := ast_kind(value_node);
                if value_kind == EXPR_INT || value_kind == EXPR_BOOL ||
                   value_kind == EXPR_DEX {
                    return value_node;
                }
            }
        }
        i = i - 1;
    }

    return -1;
}

fn push_ir_scope() {
    grow_ir_local_scopes(g_ir_local_depth + 1);
    w64(g_ir_local_scopes, g_ir_local_depth * 8, g_ir_local_count);
    g_ir_local_depth = g_ir_local_depth + 1;
}

fn pop_ir_scope() {
    g_ir_local_depth = g_ir_local_depth - 1;
    g_ir_local_count = r64(g_ir_local_scopes, g_ir_local_depth * 8);
}

fn is_ptr_var(var_idx: int) -> int {
    if var_idx < 0 { return 0; }
    ti := irv_type(var_idx);
    if ti == TI_DEX_S { return 0; }  // 哨兵类型：不查类型表（终审 M1：8 为占位表项，用户类型从 9 起）
    if ti >= 0 {
        tk := get_type_kind(ti);
        if tk == TYP_PTR || tk == TYP_REF { return 1; }
    }
    prod := r64(g_df_var_producer, var_idx * 8);
    if prod < 0 { return 0; }
    prod_op := r64(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_OPCODE);
    if prod_op == IR_ALLOC {
        ti := irv_type(var_idx);
        if ti == TI_INT || ti == TI_DEX || ti == TI_BOOL || ti == TI_CHAR {
            return 0;
        }
        return 1;
    }
    if prod_op == IR_ADDR_INDEX || prod_op == IR_REF ||
       prod_op == IR_ALLOC_STRUCT || prod_op == IR_ALLOC_ARRAY {
        return 1;
    }
    return 0;
}

fn is_byte_buf_var(var_idx: int) -> int {
    // Raw byte buffers produced by alloc() (TI_UNIT internal sentinel,
    // Core `string`) are byte-addressed: `buf + n` must NOT scale n by
    // the 8-byte element size.
    if var_idx < 0 { return 0; }
    if irv_type(var_idx) != TI_UNIT { return 0; }
    prod := r64(g_df_var_producer, var_idx * 8);
    if prod < 0 { return 0; }
    prod_op := r64(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_OPCODE);
    if prod_op == IR_ALLOC { return 1; }
    if prod_op == IR_CALL {
        func_ni := r64(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_S3);
        if func_ni >= 0 && istr_get(func_ni) == "alloc" { return 1; }
    }
    return 0;
}

fn ir_call_return_type(func_ni: int) -> int {
    if func_ni < 0 { return TI_UNIT; }
    // alloc() produces a raw byte buffer. Keep the existing internal pointer
    // sentinel until Core has a distinct raw-buffer type.
    if istr_get(func_ni) == "alloc" { return TI_UNIT; }
    bi : ., mut = 0;
    loop {
        if bi >= g_rt_builtin_count { break; }
        if r64(g_rt_builtin_names, bi * 8) == func_ni {
            return r64(g_rt_builtin_ret_types, bi * 8);
        }
        bi = bi + 1;
    }
    fi := find_func(func_ni);
    if fi >= 0 {
        rt := fi_return_type(fi);
        if rt == TY_INT { return TI_INT; }
        if rt == TY_DEX {
            // dex 边界规则（数值迁移 Task 4）：Core 函数返回精确形式（缩放整数）；
            // extern 函数保留 TI_DEX（binary64 位模式——C ABI / apx 授权 FFI）
            if fi_ast_node(fi) >= 0 && ast_kind(fi_ast_node(fi)) == EXPR_EXTERN {
                return TI_DEX;
            }
            return TI_DEX_S;
        }
        if rt == TY_BOOL { return TI_BOOL; }
        if rt == TY_STRING { return TI_STR; }
        if rt == TY_UNIT { return TI_UNIT; }
        if rt == TY_CHAR { return TI_CHAR; }
    }
    si := find_gsym(func_ni);
    if si < 0 { return TI_UNIT; }
    if sym_kind(si) == SYM_FN { return sym_type(si); }
    if sym_kind(si) == SYM_SO_FN {
        type_enc := sym_node(si);
        ret_code := type_enc - (type_enc / 100) * 100;
        if ret_code == 0 { return TI_INT; }
        if ret_code == 1 { return TI_STR; }
        if ret_code == 2 { return TI_UNIT; }
        if ret_code == 3 { return TI_DEX; }
        if ret_code == 4 { return TI_BOOL; }
    }
    return TI_UNIT;
}

// --- Track string constants ---
fn track_str(str_idx: int) {
    i : ., mut = 0;
    loop {
        if i >= g_ir_str_const_count { break; }
        if r64(g_ir_str_consts, i * 8) == str_idx { return; }
        i = i + 1;
    }
    grow_ir_str_consts(g_ir_str_const_count + 1);
    w64(g_ir_str_consts, g_ir_str_const_count * 8, str_idx);
    g_ir_str_const_count = g_ir_str_const_count + 1;
}

// --- Loop label stack ---
fn push_loop_labels(header: int, exit: int) {
    grow_ir_loop_stacks(g_ir_loop_depth + 1);
    w64(g_ir_loop_header, g_ir_loop_depth * 8, header);
    w64(g_ir_loop_exit, g_ir_loop_depth * 8, exit);
    g_ir_loop_depth = g_ir_loop_depth + 1;
}

fn pop_loop_labels() {
    g_ir_loop_depth = g_ir_loop_depth - 1;
}

// 枚举变体名查找（F15）：name_idx 是否为任一枚举的变体名（裸引用 `c := Red`）。
// 匹配返回 name_idx 本身；非变体名返回 -1。checker 的 collect_decls 把每个
// 变体名注册为 SYM_FN（指向枚举类型）——裸变体经类型检查后到达 ir_gen。
fn find_enum_variant(name_idx: int) -> int {
    ei : ., mut = 0;
    loop {
        if ei >= g_enum_count { break; }
        vi : ., mut = 0;
        loop {
            if vi >= ei_variant_count(ei) { break; }
            if ei_variant_name(ei, vi) == name_idx { return name_idx; }
            vi = vi + 1;
        }
        ei = ei + 1;
    }
    return -1;
}

fn get_variant_name_idx(qualified_ni: int) -> int {
    s := istr_get(qualified_ni);
    slen := str_len(s);
    dot_pos : ., mut = -1;
    i : ., mut = 0;
    loop {
        if i >= slen { break; }
        c := get_char(s, i);
        if str_eq(c, ".") != 0 { dot_pos = i; }
        i = i + 1;
    }
    if dot_pos >= 0 {
        variant_name := str_sub(s, dot_pos + 1, slen - dot_pos - 1);
        return str_intern(variant_name);
    }
    return qualified_ni;
}

// --- Type metadata helpers for @ builtins ---

// Resolve a type expression node to a TI_* type index.
// Handles type nodes (ast_kind==0 from parse_type) and EXPR_IDENT
// (basic type names not in the symbol table).
fn ti_from_type_expr(node: int) -> int {
    if node < 0 { return TI_UNIT; }
    // Type node from parse_type: ast_kind == 0, type_val = TY_*
    if ast_kind(node) == 0 {
        tv := ast_type_val(node);
        if tv == TY_INT { return TI_INT; }
        if tv == TY_DEX { return TI_DEX; }
        if tv == TY_BOOL { return TI_BOOL; }
        if tv == TY_STRING { return TI_STR; }
        if tv == TY_CHAR { return TI_CHAR; }
        if tv == TY_UNIT { return TI_UNIT; }
        return TI_UNIT;
    }
    // EXPR_IDENT from parse_expr: int_val = name string index
    if ast_kind(node) == EXPR_IDENT {
        ni := ast_int_val(node);
        name := istr_get(ni);
        if str_eq(name, "int") != 0 { return TI_INT; }
        if str_eq(name, "dex") != 0 { return TI_DEX; }
        if str_eq(name, "bool") != 0 { return TI_BOOL; }
        if str_eq(name, "string") != 0 { return TI_STR; }
        if str_eq(name, "char") != 0 { return TI_CHAR; }
        if str_eq(name, "unit") != 0 { return TI_UNIT; }
        // Named types (structs, enums): look up in symbol table
        si := find_gsym(ni);
        if si >= 0 && sym_kind(si) == SYM_TYPE { return sym_type(si); }
    }
    // Complex type expressions: delegate to checker's resolver
    return res_type_node(node);
}

// Type size in bytes
fn type_size(ti: int) -> int {
    if ti == TI_DEX_S { return 8; }  // 哨兵类型：8 字节槽（不查类型表；终审 M1：8 为占位表项，用户类型从 9 起）
    if ti == TI_CHAR { return 4; }  // not in type table
    if ti < 0 || ti >= g_type_count { return 8; }
    k := get_type_kind(ti);
    if k == TYP_BASE {
        d := get_type_data(ti);
        if d == TY_INT { return 8; }
        if d == TY_DEX { return 8; }
        if d == TY_BOOL { return 1; }
        if d == TY_STRING { return 8; }
        if d == TY_UNIT { return 0; }
        if d == TY_CHAR { return 4; }
        return 8;
    }
    if k == TYP_ARRAY {
        elem := get_type_data(ti);
        cnt := get_type_extra(ti);
        return type_size(elem) * cnt;
    }
    if k == TYP_PTR || k == TYP_REF { return 8; }
    if k == TYP_SLICE { return 16; }
    if k == TYP_NAMED {
        name_ni := get_type_data(ti);
        si : ., mut = 0;
        loop {
            if si >= g_struct_count { break; }
            if si_name(si) == name_ni { return si_field_count(si) * 8; }
            si = si + 1;
        }
        return 8;
    }
    return 8;
}

fn ptr_pointee_type(var_idx: int) -> int {
    if var_idx < 0 { return TI_INT; }
    ti := irv_type(var_idx);
    if ti >= 0 {
        k := get_type_kind(ti);
        if k == TYP_PTR || k == TYP_REF { return get_type_data(ti); }
    }
    return TI_INT;
}

fn ptr_access_width(var_idx: int) -> int {
    width := type_size(ptr_pointee_type(var_idx));
    if width <= 0 { return 8; }
    return width;
}

// Type alignment in bytes
fn type_align(ti: int) -> int {
    if ti == TI_DEX_S { return 8; }  // 哨兵类型：8 字节对齐（不查类型表；终审 M1：8 为占位表项）
    if ti == TI_CHAR { return 4; }
    if ti < 0 || ti >= g_type_count { return 8; }
    k := get_type_kind(ti);
    if k == TYP_BASE {
        d := get_type_data(ti);
        if d == TY_INT { return 8; }
        if d == TY_DEX { return 8; }
        if d == TY_BOOL { return 1; }
        if d == TY_STRING { return 8; }
        if d == TY_CHAR { return 4; }
        return 8;
    }
    if k == TYP_ARRAY { return type_align(get_type_data(ti)); }
    if k == TYP_PTR || k == TYP_REF { return 8; }
    if k == TYP_SLICE { return 8; }
    if k == TYP_NAMED { return 8; }
    return 8;
}

// Resolve a type index to a struct info index.
// Returns -1 if the type is not a struct type.
fn ti_resolve_struct(ti: int) -> int {
    if ti < 0 || ti >= g_type_count { return -1; }
    k := get_type_kind(ti);
    if k != TYP_NAMED { return -1; }
    name_ni := get_type_data(ti);
    if name_ni < 0 { return -1; }
    name := istr_get(name_ni);
    si : ., mut = 0;
    loop {
        if si >= g_struct_count { break; }
        sn_ni := si_name(si);
        sn := istr_get(sn_ni);
        if str_eq(sn, name) != 0 { return si; }
        si = si + 1;
    }
    return -1;
}

// Check if a struct type has a field by name
fn ti_has_field(ti: int, name: string) -> int {
    si := ti_resolve_struct(ti);
    if si < 0 { return 0; }
    fc := si_field_count(si);
    fi : ., mut = 0;
    loop {
        if fi >= fc { break; }
        fn_ni := si_field_name(si, fi);
        fname := istr_get(fn_ni);
        if str_eq(fname, name) != 0 { return 1; }
        fi = fi + 1;
    }
    return 0;
}

// Get field byte offset (each field is 8 bytes)
fn ti_field_offset(ti: int, name: string) -> int {
    si := ti_resolve_struct(ti);
    if si < 0 { return -1; }
    fc := si_field_count(si);
    fi : ., mut = 0;
    loop {
        if fi >= fc { break; }
        fn_ni := si_field_name(si, fi);
        fname := istr_get(fn_ni);
        if str_eq(fname, name) != 0 { return fi * 8; }
        fi = fi + 1;
    }
    return -1;
}

// Check if a function name refers to a hotpatch function (has @hotpatch versions)
fn is_hotpatch_func(name_idx: int) -> int {
    count : ., mut = 0;
    i : ., mut = 0;
    loop {
        if i >= g_func_count { break; }
        if fi_name(i) == name_idx {
            fn_node := fi_ast_node(i);
            if fn_node >= 0 {
                hotpatch_ver := ast_int_val(fn_node) / 256;
                if hotpatch_ver > 0 { count = count + 1; }
            }
        }
        i = i + 1;
    }
    if count > 0 { return 1; }
    return 0;
}

// Helper: if a variable's producer is IR_LAZY_THUNK, emit IR_LAZY_FORCE
// to extract the real value and return the forced variable.
fn force_if_thunk(var_idx: int) -> int {
    if var_idx < 0 { return var_idx; }
    prod := r64(g_df_var_producer, var_idx * 8);
    if prod >= 0 {
        prod_op := r64(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_OPCODE);
        if prod_op == IR_LAZY_THUNK {
            forced := new_ir_var("_forced", irv_type(var_idx));
            emit(IR_LAZY_FORCE, forced, var_idx, 0, 0, 0);
            return forced;
        }
    }
    return var_idx;
}

// --- dex 定点精确运算辅助（数值迁移 Task 4）---
// dex 值有两种 IR 形式：
//   TI_DEX_S = 定点缩放整数（精确形式，S = 10^6，默认世界——跨函数边界统一此形式）
//   TI_DEX   = binary64 位模式（apx 形式——apx 变量及其运算的快路径表示）
// 转换规则（文档化）：运算按操作数形式分流（有 TI_DEX 操作数 → binary64 快路径，
// 否则 → 定点整数指令序列）；存储/边界处按槽位形式转换（apx 结果在边界按定点
// 6 位截断/舍入——「精确，或经授权的近似」契约的兑现）。

// bits（TI_DEX）→ 缩放整数（TI_DEX_S）：round(bits × S)——6 位定点舍入（四舍五入
// 半进，数值迁移 Task 6 定稿：apx 打印/边界行为 = 6 位定点舍入，非截断、非全精度
// binary64）。实现：F2I 本身向零截断——正数先 +0.5、负数先 −0.5（分支按 m < 0 分流，
// 与字面量 str_to_scaled 的半进一致；半进 = 绝对值半上，-0.5 → -1）。此舍入同时吸收
// str_to_f64_bits 字面量转换的 ~2ulp 截断误差（打印/边界 6 位精度下不可见）。
fn dex_bits_to_scaled(var: int) -> int {
    if irv_type(var) != TI_DEX { return var; }
    c := new_ir_var("_dxs", TI_DEX);
    emit(IR_CONST, c, 4696837146684686336, 0, 0, TI_DEX);  // 1e6 的 binary64 位模式
    m := new_ir_var("_dxm", TI_DEX);
    emit(IR_BINARY, m, var, c, OP_MUL, TI_DEX);
    zero := new_ir_var("_dx0", TI_DEX);
    emit(IR_CONST, zero, 0, 0, 0, TI_DEX);
    negc := new_ir_var("_dxc", TI_INT);
    emit(IR_BINARY, negc, m, zero, OP_LT, TI_DEX);  // m < 0 → int 0/1（comisd 路径）
    half := new_ir_var("_dxh", TI_DEX);
    emit(IR_CONST, half, 4602678819172646912, 0, 0, TI_DEX);  // 0.5 的 binary64 位模式（0x3FE0000000000000）
    pos_lbl := new_label();
    neg_lbl := new_label();
    merge_lbl := new_label();
    mrg := new_ir_var("_dxmrg", TI_DEX);
    emit(IR_BRANCH, -1, negc, neg_lbl, pos_lbl, 0);
    emit(IR_LABEL, -1, pos_lbl, 0, 0, 0);
    rp := new_ir_var("_dxrp", TI_DEX);
    emit(IR_BINARY, rp, m, half, OP_ADD, TI_DEX);  // m ≥ 0：+0.5
    emit(IR_STORE, -1, mrg, rp, 0, 0);
    emit(IR_JUMP, -1, merge_lbl, 0, 0, 0);
    emit(IR_LABEL, -1, neg_lbl, 0, 0, 0);
    rn := new_ir_var("_dxrn", TI_DEX);
    emit(IR_BINARY, rn, m, half, OP_SUB, TI_DEX);  // m < 0：−0.5
    emit(IR_STORE, -1, mrg, rn, 0, 0);
    emit(IR_LABEL, -1, merge_lbl, 0, 0, 0);
    r := new_ir_var("_dxsc", TI_DEX_S);
    emit(IR_F2I, r, mrg, 0, 0, TI_DEX);
    return r;
}

// 缩放整数（TI_DEX_S）→ bits（TI_DEX）：I2F(scaled) / S
// 字面量节点（EXPR_DEX）直接重发射为 bits 常量（与 lexer 位模式一致，免转换序列）
fn dex_scaled_to_bits(var: int, node: int) -> int {
    if irv_type(var) != TI_DEX_S { return var; }
    if node >= 0 && ast_kind(node) == EXPR_DEX {
        v := new_ir_var("dex", TI_DEX);
        emit(IR_CONST, v, ast_a(node), 0, 0, TI_DEX);
        return v;
    }
    f := new_ir_var("_dxf", TI_DEX);
    emit(IR_I2F, f, var, 0, 0, TI_DEX);
    c := new_ir_var("_dxsc", TI_DEX);
    emit(IR_CONST, c, 4696837146684686336, 0, 0, TI_DEX);  // 1e6 bits
    d := new_ir_var("_dxdiv", TI_DEX);
    emit(IR_BINARY, d, f, c, OP_DIV, TI_DEX);
    return d;
}

// int 操作数 → 定点缩放（×S）：精确路径的 int 隐式对齐（与 apx 路径的 I2F 同位）
fn dex_scale_int(var: int) -> int {
    if irv_type(var) != TI_INT { return var; }
    c := new_ir_var("_dsc", TI_INT);
    emit(IR_CONST, c, 1000000, 0, 0, TI_INT);
    t := new_ir_var("_dxt", TI_DEX_S);
    emit(IR_BINARY, t, var, c, OP_MUL, TI_INT);
    return t;
}

// 存储到 dex 槽位前按槽位形式转换（数值迁移 Task 4）：
//   TI_DEX 槽（apx 变量）← 缩放值：scaled → bits（字面量重发射，计算值 I2F/S）
//   TI_DEX_S 槽（精确变量）← bits 值：bits → scaled（apx 结果按定点 6 位舍入入精确世界）
fn dex_store_adjust(target: int, val: int, val_node: int) -> int {
    tt := irv_type(target);
    vt := irv_type(val);
    if tt == TI_DEX && vt == TI_DEX_S { return dex_scaled_to_bits(val, val_node); }
    if tt == TI_DEX_S && vt == TI_DEX { return dex_bits_to_scaled(val); }
    return val;
}

// 聚合/指针槽写点规范化（apx 批 T3）：**聚合面不存在 apx 形式**——`apx` 是 LET 专属
// 标签（parser.cr:819），字段 / 数组·切片元素 / 元组元素 / 枚举载荷 / 指针 pointee
// 的规范存储形式**恒为精确（scaled）** ⇒ 任何 TI_DEX（bits）值入这类槽前一律转
// scaled；非 apx 值原样返回（**零 IR** ⇒ 非 apx 程序逐字节不变）。
// 纪律（Global Constraint 12）：本判定**不含任何类型表查询**（不调 res_type_node/
// alloc_type）——ir_gen 路径新增 alloc_type 站点会破坏暖缓存「不可写条目」不变式。
fn dex_slot_norm(val: int) -> int {
    if val < 0 { return val; }
    if irv_type(val) != TI_DEX { return val; }
    return dex_bits_to_scaled(val);
}

// 声明类型**节点**是否 `dex?`（可选 dex）——**节点级零 alloc**（先例 `agg_read_form_is_dex:417` /
// `reg_one_global` 的 `ast_kind(ltn)==0 && ast_type_val(ltn)==TY_DEX`）。`dex?` 的类型节点 =
// `EXPR_OPTIONAL`，其内层是基类型节点 `dex`（`ast_kind==0 && ast_type_val==TY_DEX`）。
// 用途（批 5 · R1）：写点/槽型按**声明**定形式（G1 裁决 = scaled），而非按值型反推。
fn dex_opt_type_node(tn: int) -> int {
    if tn < 0 { return 0; }
    if ast_kind(tn) != EXPR_OPTIONAL { return 0; }
    inner := ast_a(tn);
    if inner < 0 || ast_kind(inner) != 0 { return 0; }
    if ast_type_val(inner) == TY_DEX { return 1; }
    return 0;
}

// 类型**行**是否 `dex?`（`TYP_OPTIONAL` ∧ `data == TI_DEX`）——**纯表读零 alloc**（先例
// `ti_is_optional:328` / `elem_ti_of_decl:343`）。用途（批 5 · G2 读点定型）：optional 声明的
// 载荷读槽取**声明面**形式——`agg_payload_read_form` 只认枚举行，内建 `Some` 面无行 ⇒ 恒 TI_INT
// （`dex?` 载荷按值参与 dex 运算会被当 int 再 ×S）。G2 红线：**不得**调 `res_type_node`/`alloc_type`。
fn dex_opt_slot_ti(ti: int) -> int {
    if ti < 0 || ti >= g_type_count { return 0; }
    if get_type_kind(ti) != TYP_OPTIONAL { return 0; }
    if get_type_data(ti) == TI_DEX { return 1; }
    return 0;
}

// 聚合读的**声明面** dex-ness（apx 批 T3 · 比较/相等点专用）：
// #2026-09-16-16 未修 ⇒ 聚合读的结果槽 IR 型恒 TI_INT、**声明型被抹** ⇒ 下游「按值型触发」的
// 形式分流看不到 dex。本函数在**节点级**把声明面取回来（**零 alloc_type**；先例
// agg_elem_count_of:3004），供比较点判断操作数的**规范槽形式**：
//   EXPR_FIELD ⇒ 结构体字段的声明类型节点（数字元组下标 ast_type_val>0 不判——元组无声明面）
//   EXPR_INDEX ⇒ **全局**定长数组/切片的元素声明类型节点（局部数组无节点级声明面 ⇒ 不判）
// 返回 1 = 声明为 dex（⇒ 槽内规范形式 = **精确/scaled**，由本批写点保证）· 0 = 非 dex / 不可得。
fn dex_decl_form_of_expr(node: int) -> int {
    if node < 0 { return 0; }
    k := ast_kind(node);
    if k == EXPR_FIELD {
        if ast_type_val(node) > 0 { return 0; }
        si := find_struct(ast_c(node));
        if si < 0 { return 0; }
        fi : ., mut = ast_data(node);
        if fi < 0 { return 0; }
        tn := si_field_type_node(si, fi);
        if tn >= 0 && ast_kind(tn) == 0 && ast_type_val(tn) == TY_DEX { return 1; }
        return 0;
    }
    if k == EXPR_INDEX {
        an := ast_a(node);
        if an < 0 || ast_kind(an) != EXPR_IDENT { return 0; }
        ni := ast_int_val(an);
        gi : ., mut = 0;
        loop {
            if gi >= g_global_let_count { break; }
            lnode := r64(g_global_lets, gi * 8);
            if ast_a(lnode) == ni {
                tn := ast_b(lnode);
                if tn >= 0 && ast_kind(tn) == EXPR_ARRAY {
                    etn := ast_a(tn);
                    if etn >= 0 && ast_kind(etn) == 0 && ast_type_val(etn) == TY_DEX { return 1; }
                }
                break;
            }
            gi = gi + 1;
        }
        return 0;
    }
    return 0;
}

// --- IR generation for expressions ---
// Returns the IR variable index holding the result

fn gen_expr(node: int) -> int {
    if node < 0 { return -1; }

    if ast_kind(node) == EXPR_NONE {
        // Wrapper node: forward to inner expression (used in struct literals)
        if ast_a(node) >= 0 && ast_a(node) != node { return gen_expr(ast_a(node)); }
        return -1;
    }

    // Literals
    if ast_kind(node) == EXPR_INT {
        v := new_ir_var("int", TI_INT);
        emit(IR_CONST, v, ast_int_val(node), 0, 0, TI_INT);
        return v;
    }
    if ast_kind(node) == EXPR_DEX {
        // 精确字面量（数值迁移 Task 4）：定点缩放整数常量（TI_DEX_S）。
        // apx 场景（变量级 apx 标签的运算）在运算点按 node.a 的 binary64 位模式重发射。
        v := new_ir_var("dex", TI_DEX_S);
        emit(IR_CONST, v, ast_int_val(node), 0, 0, TI_DEX_S);
        return v;
    }
    if ast_kind(node) == EXPR_BOOL {
        v := new_ir_var("bool", TI_BOOL);
        emit(IR_CONST, v, ast_int_val(node), 0, 0, TI_BOOL);
        return v;
    }
    if ast_kind(node) == EXPR_STRING {
        v := new_ir_var("str", TI_STR);
        str_idx := ast_int_val(node);
        track_str(str_idx);
        emit(IR_CONST, v, str_idx, 0, 0, TI_STR);
        return v;
    }
    if ast_kind(node) == EXPR_CHAR {
        v := new_ir_var("char", TI_CHAR);
        str_idx := ast_int_val(node);
        track_str(str_idx);
        emit(IR_CONST, v, str_idx, 0, 0, TI_CHAR);
        return v;
    }

    // Identifier: local or global variable
    if ast_kind(node) == EXPR_IDENT {
        name_idx := ast_int_val(node);
        lv := find_local(name_idx);
        if lv >= 0 { return lv; }
        const_node := find_global_const_node(name_idx);
        // 容量批 T2：**可选全局槽不得常量折叠**——字面量初值（`g : int? = 5`）的读点若被
        // 折成裸常量 5，则 match 的 tag 读会解引用该裸值（双路径 139，实测 e2_global_bare）。
        // 折叠面只对非可选全局生效（零足迹）；可选全局由运行期初始化写入装箱对象。
        if const_node >= 0 && g_optrep_on != 0 && global_decl_optional(name_idx) != 0 { const_node = -1; }
        if const_node >= 0 {
            const_type : ., mut = TI_INT;
            if ast_kind(const_node) == EXPR_BOOL { const_type = TI_BOOL; }
            if ast_kind(const_node) == EXPR_DEX { const_type = TI_DEX_S; }  // 定点缩放常量
            cv := new_ir_var("const", const_type);
            emit(IR_CONST, cv, ast_int_val(const_node), 0, 0, const_type);
            return cv;
        }
        gv := find_global(name_idx);
        if gv >= 0 { return gv; }
        // F15：枚举裸变体（c := Red，不带括号）——发射无 payload 的 MAKE_ENUM
        // （s1=变体名 ni、s2=0），与 EXPR_ENUM_CONSTRUCTOR 的 `Red()` 调用形式
        // 同机制（tag = 变体名驻留索引，match 按名字比较）。修复前落为下方
        // "unresolved" 哑变量 → 后续 LOAD_ENUM_TAG 解引用垃圾值 → SIGSEGV（139）。
        if find_enum_variant(name_idx) >= 0 {
            s := new_ir_var("enum", TI_UNIT);
            emit(IR_MAKE_ENUM, s, name_idx, 0, 0, 0);
            return s;
        }
        // Could be a function name being used as a value - return dummy
        v := new_ir_var("unresolved", TI_UNIT);
        return v;
    }

    // Binary operation
    if ast_kind(node) == EXPR_BINARY {
        left := ast_a(node);
        right := ast_b(node);
        op := ast_c(node);

        // R2 P5 Task 4（D25）：`EXPR_BINARY + OP_ASSIGN` 赋值分支**已删**——不可达
        // （parser 不产该组合：`tok2op` 零 OP_ASSIGN；`T_EQ` → EXPR_ASSIGN；`+=` 族构造
        // `EXPR_ASSIGN` 包裹的 EXPR_BINARY 且 op ∈ {ADD,SUB,MUL,DIV}；语料站点直方图 0 命中）。
        // 赋值发射面在下方 `EXPR_ASSIGN` 分支（gen_expr 的另一 arm），逐字未动。

        // Regular binary
        left_var := gen_expr(left);
        left_var = force_if_thunk(left_var);
        // Logical operators must short-circuit.  Eagerly generating the
        // right side breaks guard expressions such as
        // `fi >= 0 && fi_generic_count(fi) > 0`.
        if op == OP_AND || op == OP_OR {
            right_lbl := new_label();
            short_lbl := new_label();
            merge_lbl := new_label();
            logic_result := new_ir_var("logic", TI_BOOL);
            if op == OP_AND {
                emit(IR_BRANCH, -1, left_var, right_lbl, short_lbl, 0);
            } else {
                emit(IR_BRANCH, -1, left_var, short_lbl, right_lbl, 0);
            }

            emit(IR_LABEL, -1, short_lbl, 0, 0, 0);
            short_value := new_ir_var("logic_short", TI_BOOL);
            if op == OP_AND { emit(IR_CONST, short_value, 0, 0, 0, TI_BOOL); }
            else { emit(IR_CONST, short_value, 1, 0, 0, TI_BOOL); }
            emit(IR_STORE, -1, logic_result, short_value, 0, 0);
            emit(IR_JUMP, -1, merge_lbl, 0, 0, 0);

            emit(IR_LABEL, -1, right_lbl, 0, 0, 0);
            right_value := gen_expr(right);
            right_value = force_if_thunk(right_value);
            emit(IR_STORE, -1, logic_result, right_value, 0, 0);
            emit(IR_JUMP, -1, merge_lbl, 0, 0, 0);

            emit(IR_LABEL, -1, merge_lbl, 0, 0, 0);
            return logic_result;
        }
        right_var := gen_expr(right);
        right_var = force_if_thunk(right_var);
        lt := irv_type(left_var);
        rt := irv_type(right_var);

        // Unwrap dyn operands: extract the underlying value for binary ops
        if lt == TI_DYN {
            uv := new_ir_var("_dynval", TI_UNIT);
            emit(IR_DYN_VAL, uv, left_var, 0, 0, 0);
            left_var = uv;
            lt = irv_type(left_var);
        }
        if rt == TI_DYN {
            uv := new_ir_var("_dynval", TI_UNIT);
            emit(IR_DYN_VAL, uv, right_var, 0, 0, 0);
            right_var = uv;
            rt = irv_type(right_var);
        }

        // String equality compares contents, not pointer values.
        if (op == OP_EQ || op == OP_NE) && (lt == TI_STR || rt == TI_STR) {
            eq_ni := str_intern("str_eq");
            eq_arg0 := new_ir_var("_eq0", lt);
            eq_arg1 := new_ir_var("_eq1", rt);
            emit(IR_STORE, -1, eq_arg0, left_var, 0, 0);
            emit(IR_STORE, -1, eq_arg1, right_var, 0, 0);
            eq_value := new_ir_var("str_eq", TI_BOOL);
            emit(IR_CALL, eq_value, eq_arg0, 2, eq_ni, TI_BOOL);
            if op == OP_EQ { return eq_value; }
            zero_value := new_ir_var("zero", TI_INT);
            emit(IR_CONST, zero_value, 0, 0, 0, TI_INT);
            ne_value := new_ir_var("str_ne", TI_BOOL);
            emit(IR_BINARY, ne_value, eq_value, zero_value, OP_EQ, TI_BOOL);
            return ne_value;
        }
        // String concatenation — call concat() instead of IR_BINARY
        if op == OP_ADD {
            if lt == TI_STR || rt == TI_STR {
                concat_ni := str_intern("concat");
                // Pack both args into consecutive vars so ELF backend finds them
                packed0 := new_ir_var("_cat0", lt);
                packed1 := new_ir_var("_cat1", rt);
                emit(IR_STORE, -1, packed0, left_var, 0, 0);
                emit(IR_STORE, -1, packed1, right_var, 0, 0);
                v := new_ir_var("str", TI_STR);
                emit(IR_CALL, v, packed0, 2, concat_ni, TI_STR);
                return v;
            }
        }
        // apx 批 T3（L10 · 比较/运算点的**声明面**查表）：聚合读的结果槽 IR 型恒 TI_INT
        // （#2026-09-16-16：读点定型丢失声明型）⇒ 当操作数节点是聚合读**且声明面为 dex** 时，槽内
        // 规范形式 = **精确（scaled）**（由本批写点保证）⇒ 按 TI_DEX_S 参与分流——否则
        // 会落「TI_INT 操作数 I2F」支，把 scaled 整数当整数升 double（实测 b8 红 0）。
        // **作用域**：只覆盖本分流点；**不改读点定型**（那是 #2026-09-16-16 的爆炸半径，#2026-09-16-29/#2026-09-16-16 另批）。
        if lt == TI_INT && dex_decl_form_of_expr(left) != 0 { lt = TI_DEX_S; }
        if rt == TI_INT && dex_decl_form_of_expr(right) != 0 { rt = TI_DEX_S; }
        fti : int = TI_INT;
        // Pointer arithmetic: use PTR_ADD/PTR_SUB/PTR_DIFF instead of standard opcodes.
        // Raw byte buffers from alloc() are byte-addressed — plain ADD/SUB, no scaling.
        if is_ptr_var(left_var) != 0 || is_ptr_var(right_var) != 0 {
            buf_left := is_byte_buf_var(left_var);
            buf_right := is_byte_buf_var(right_var);
            if buf_left == 0 && buf_right == 0 {
                if op == OP_ADD { op = OP_PTR_ADD; }
                else if op == OP_SUB {
                    if is_ptr_var(left_var) != 0 && is_ptr_var(right_var) != 0 {
                        op = OP_PTR_DIFF;
                    } else {
                        op = OP_PTR_SUB;
                    }
                }
            }
        }
        if op == OP_PTR_ADD || op == OP_PTR_SUB {
            if is_ptr_var(left_var) != 0 { fti = irv_type(left_var); }
            else if is_ptr_var(right_var) != 0 { fti = irv_type(right_var); }
        }
        // dex 运算分流（数值迁移 Task 4）：
        //   有 TI_DEX（apx 形式）操作数 → binary64 快路径（SSE2，IEEE 754——apx 标准答案）
        //   有 TI_DEX_S（定点形式）操作数 → 精确路径（缩放整数指令序列）
        if lt == TI_DEX || rt == TI_DEX {
            fti = TI_DEX;
            // apx 路径操作数对齐：字面量 → 重发射 bits 常量；定点（TI_DEX_S）→
            // I2F/S 转 bits（按精确值参与——apx 授权的近似）；int → I2F（隐式转换）
            if lt == TI_DEX_S { left_var = dex_scaled_to_bits(left_var, left); }
            else if lt == TI_INT {
                t1 := new_ir_var("_f0", TI_DEX);
                emit(IR_I2F, t1, left_var, 0, 0, TI_DEX);
                left_var = t1;
            }
            if rt == TI_DEX_S { right_var = dex_scaled_to_bits(right_var, right); }
            else if rt == TI_INT {
                t2 := new_ir_var("_f1", TI_DEX);
                emit(IR_I2F, t2, right_var, 0, 0, TI_DEX);
                right_var = t2;
            }
            v := new_ir_var("bin", fti);
            emit(IR_BINARY, v, left_var, right_var, op, fti);
            return v;
        }
        if lt == TI_DEX_S || rt == TI_DEX_S {
            fti = TI_DEX_S;
            // 精确路径操作数对齐：int → ×S（隐式缩放）；定点（TI_DEX_S）直接参与
            if lt == TI_INT { left_var = dex_scale_int(left_var); }
            if rt == TI_INT { right_var = dex_scale_int(right_var); }
            if op == OP_MUL {
                // (a×b)/S：先乘后缩回（中间值 a·b ≤ 9.2e18 → |值| ≤ 3.03e3 级，文档化）
                p := new_ir_var("_dxm", TI_DEX_S);
                emit(IR_BINARY, p, left_var, right_var, OP_MUL, TI_INT);
                c := new_ir_var("_dxs", TI_INT);
                emit(IR_CONST, c, 1000000, 0, 0, TI_INT);
                v := new_ir_var("bin", TI_DEX_S);
                emit(IR_BINARY, v, p, c, OP_DIV, TI_INT);
                return v;
            }
            if op == OP_DIV {
                // (a×S)/b：先放大再除（中间值 a·S ≤ 9.2e18 → |a| ≤ 9.2e6，向零截断）
                c := new_ir_var("_dxs", TI_INT);
                emit(IR_CONST, c, 1000000, 0, 0, TI_INT);
                t := new_ir_var("_dxn", TI_DEX_S);
                emit(IR_BINARY, t, left_var, c, OP_MUL, TI_INT);
                v := new_ir_var("bin", TI_DEX_S);
                emit(IR_BINARY, v, t, right_var, OP_DIV, TI_INT);
                return v;
            }
            if op == OP_MOD {
                // a mod b = a - trunc(a/b)·b（截断除法恒等式，缩放形式）
                c := new_ir_var("_dxs", TI_INT);
                emit(IR_CONST, c, 1000000, 0, 0, TI_INT);
                t1 := new_ir_var("_dxn", TI_DEX_S);
                emit(IR_BINARY, t1, left_var, c, OP_MUL, TI_INT);
                t2 := new_ir_var("_dxq", TI_DEX_S);
                emit(IR_BINARY, t2, t1, right_var, OP_DIV, TI_INT);
                t3 := new_ir_var("_dxi", TI_DEX_S);
                emit(IR_BINARY, t3, t2, c, OP_DIV, TI_INT);   // trunc(a/b)（纯整数）
                t4 := new_ir_var("_dxr", TI_DEX_S);
                emit(IR_BINARY, t4, t3, right_var, OP_MUL, TI_INT);
                v := new_ir_var("bin", TI_DEX_S);
                emit(IR_BINARY, v, left_var, t4, OP_SUB, TI_INT);
                return v;
            }
            if op == OP_EQ || op == OP_NE || op == OP_LT || op == OP_GT ||
               op == OP_LE || op == OP_GE {
                // 比较：缩放整数比较，结果 0/1（int——非 dex 值）
                v := new_ir_var("cmp", TI_INT);
                emit(IR_BINARY, v, left_var, right_var, op, TI_INT);
                return v;
            }
            // ADD/SUB 及余下：缩放整数直接运算
            v := new_ir_var("bin", TI_DEX_S);
            emit(IR_BINARY, v, left_var, right_var, op, TI_INT);
            return v;
        }
        v := new_ir_var("bin", fti);
        emit(IR_BINARY, v, left_var, right_var, op, fti);
        return v;
    }

    // Assignment
    if ast_kind(node) == EXPR_ASSIGN {
        target := ast_a(node);
        // Unwrap EXPR_NONE wrapper (added by checker/optimizer to
        // mark rewritten nodes). Without unwrapping, the target
        // checks below would miss wrapped UOP_DEREF or INDEX nodes.
        if ast_kind(target) == EXPR_NONE && ast_a(target) >= 0 {
            target = ast_a(target);
        }
        val_node := ast_b(node);
        val_var := gen_expr(val_node);
        val_var = force_if_thunk(val_var);
        if ast_kind(target) == EXPR_IDENT {
            name_idx := ast_int_val(target);
            lv := find_local(name_idx);
            if lv >= 0 {
                if irv_type(lv) == TI_DYN {
                    // Dyn variable assignment: pack value with type tag
                    tag := irv_type(val_var);
                    if tag < 0 { tag = TI_INT; }
                    emit(IR_DYN_PACK, lv, val_var, tag, 0, 0);
                } else {
                    val_var = dex_store_adjust(lv, val_var, val_node);
                     // F11：切片长度沿赋值传播（字面量/运行时界长度变量同步；源无记录则清除）
                     slice_len_copy_to(lv, val_var);
                    // (A) 批（INV-1）：取址槽恒装箱（同 LET 写点；名字索引判定）
                    rpv0 := irv_rep(lv);
                    forced2 := g_optrep_on != 0 && rpv0 >= 0 && addr_taken_of(name_idx) != 0;
                    if forced2 != 0 { val_var = box_for_slot_flag(val_node, val_var, 1); }
emit(IR_STORE, -1, lv, val_var, 0, 0);
                    // 可选表示（R2 P4 Task 5）：赋值写点置位（同 LET——解包点据此分派）
                    if rpv0 >= 0 {
                        if forced2 != 0 { emit_rep_set(rpv0, oe_boxed()); }
                        else { emit_rep_set(rpv0, rep_enc_of_expr(val_node, val_var)); }
                    }
                }
            } else {
                gv := find_global(name_idx);
                if gv >= 0 {
                    val_var = dex_store_adjust(gv, val_var, val_node);
                    // 容量批 T2：可选全局槽写点规范化（裸值装箱；目标不可选 ⇒ 零 IR）
                    if g_optrep_on != 0 { val_var = box_for_optional_slot(val_node, val_var, global_decl_ti(name_idx)); }
                    emit(IR_STORE, -1, gv, val_var, 0, 0);
                }
            }
            return val_var;
        }
        if ast_kind(target) == EXPR_FIELD {
            obj_var := gen_expr(ast_a(target));
            obj_var = force_if_thunk(obj_var);
            fi := ast_data(target);
            // 容量批 T2：可选字段写点规范化（字段声明类型取自 checker 记的 ast_c 结构体名）
            val_var = dex_slot_norm(val_var);   // apx 批 T3：聚合面恒精确（§0 推论）；先归形式后装箱
            if g_optrep_on != 0 { val_var = box_for_optional_slot(val_node, val_var, field_ti_of_node(target, fi)); }
            emit(IR_STORE_FIELD, -1, obj_var, val_var, fi, 0);
            return val_var;
        }
        if ast_kind(target) == EXPR_INDEX {
            arr_var := gen_expr(ast_a(target));
            arr_var = force_if_thunk(arr_var);
            idx_node := ast_b(target);
            // 容量批 T2：可选元素写点规范化（元素类型 = 数组/切片声明类型的内层；
            // 全局数组的声明面在 g_global_lets ⇒ ident 形目标回退查全局声明）
            et := elem_ti_of(arr_var);
            if et < 0 {
                anode := ast_a(target);
                if anode >= 0 && ast_kind(anode) == EXPR_IDENT {
                    et = elem_ti_of_decl(global_decl_ti(ast_int_val(anode)));
                }
            }
            val_var = dex_slot_norm(val_var);   // apx 批 T3：元素槽恒精确
            if g_optrep_on != 0 { val_var = box_for_optional_slot(val_node, val_var, et); }
            // F1：写路径越界守卫钩子（修复前完全没有——见 compcert-round4 F1）
            arr_len_lit : ., mut = arr_len_lit_of(arr_var);
            if ast_kind(idx_node) == EXPR_INT {
                emit_string_lit_bounds(arr_var, ast_int_val(idx_node));
                emit_slice_lit_bounds(arr_var, ast_int_val(idx_node));
                if pass_before_array_access(arr_var, -1, ast_int_val(idx_node), arr_len_lit) == 0 {
                    emit(IR_STORE_INDEX, -1, arr_var, val_var, ast_int_val(idx_node), 0);
                }
            } else {
                idx_var := gen_expr(idx_node);
                idx_var = force_if_thunk(idx_var);
                emit_slice_bounds(arr_var, idx_var);
                if pass_before_array_access(arr_var, idx_var, -1, arr_len_lit) == 0 {
                    emit(IR_STORE_INDEX_VAR, val_var, arr_var, idx_var, 0, 0);
                }
            }
            return val_var;
        }
        if ast_kind(target) == EXPR_UNARY && ast_c(target) == UOP_DEREF {
            ptr_var := gen_expr(ast_a(target));
            ptr_var = force_if_thunk(ptr_var);
            // (A) 批（INV-2）：**指针写且 pointee 可选 ⇒ 装箱**——一致性由 INV-1（取址槽恒装箱）
            // 与 E-2（聚合恒装箱）保证；越界面 = REP-2（指针算术）/ extern（登记）
            // 批 5（opt-dex · R2 序修正）：**先归形式、后可选装箱**——装箱载荷须为规范形式；
            // 反序时 `dex_slot_norm` 落在箱对象（TI_INT）上 = 空转（可选 dex 载荷留 bits）。
            val_var = dex_slot_norm(val_var);   // apx 批 T3：pointee 槽恒精确（`*p = d` 实测 RED）
            if g_optrep_on != 0 && ti_is_optional(ptr_pointee_type(ptr_var)) != 0 {
                val_var = box_for_slot_flag(val_node, val_var, 1);
            }
            emit(IR_STORE_PTR, -1, ptr_var, val_var, 0, ptr_access_width(ptr_var));
            return val_var;
        }
        return val_var;
    }

    // Unary operation
    if ast_kind(node) == EXPR_UNARY {
        op := ast_c(node);
        if op == UOP_REF {
            inner := ast_a(node);
            // &arr[i]: compute address directly, don't load then take addr
            if ast_kind(inner) == EXPR_INDEX {
                arr_var := gen_expr(ast_a(inner));
                arr_var = force_if_thunk(arr_var);
                idx_var := gen_expr(ast_b(inner));
                idx_var = force_if_thunk(idx_var);
                elem_ti : ., mut = TI_INT;
                // (A) 批：元素类型**声见面优先**（T2 的 elem_ti_of：decl 表优先，退回运行期类型）
                de := elem_ti_of(arr_var);
                if de >= 0 { elem_ti = de; }
                else {
                    arr_ti := irv_type(arr_var);
                    if arr_ti >= 0 {
                        arr_kind := get_type_kind(arr_ti);
                        if arr_kind == TYP_ARRAY || arr_kind == TYP_SLICE {
                            elem_ti = get_type_data(arr_ti);
                        }
                    }
                }
                v := new_ir_var("addr", alloc_type(TYP_PTR, elem_ti, 0));
                emit(IR_ADDR_INDEX, v, arr_var, idx_var, 3, 0);
                return v;
            }
            op_var := gen_expr(ast_a(node));
            op_var = force_if_thunk(op_var);
            // (A) 批：pointee 类型**声见面优先**（字面量推出的 IR 类型对可选槽退化为对象占位），
            // 且**取址槽（INV-1 恒装箱）⇒ pointee 记为 TYP_OPTIONAL**（装载侧 W5 据此装箱；
            // 非可选取址槽不受影响）
            // 取址目标的**源名索引**取自操作数（EXPR_UNARY 的 int_val 是 is_mut 位，不是名索引）
            ni_src : ., mut = -1;
            if ast_kind(ast_a(node)) == EXPR_IDENT { ni_src = ast_int_val(ast_a(node)); }
            pti := slot_decl_ti(op_var);
            if pti < 0 { pti = irv_type(op_var); }
            if ni_src >= 0 {
                // 全局槽：声明面在 g_global_lets（E-2 的 global_decl_ti）——局部表未登记全局。
                // **只升级不降级**：全局声明可选 ⇒ 记可选；否则保留上面已得的类型
                // （全局 IR var 本身可能已是可选类型，直接取声明面会把它覆盖成非可选 ⇒ W5 不装箱）。
                gti := global_decl_ti(ni_src);
                if ti_is_optional(gti) != 0 { pti = gti; }
            }
            if g_optrep_on != 0 && ni_src >= 0 && addr_taken_of(ni_src) != 0 {
                // 取址目标具备可选能力（有表示位 / 声明为可选）⇒ pointee 记 TYP_OPTIONAL：
                // 装载侧 IR_STORE_PTR（W5）据 pointee 是否可选决定装箱。非可选槽 rep<0
                // 且声明非可选 ⇒ 两种形态都不触发（零足迹）。
                if irv_rep(op_var) >= 0 || ti_is_optional(pti) != 0 {
                    if ti_is_optional(pti) == 0 {
                        inner3 := pti; if inner3 < 0 { inner3 = TI_INT; }
                        pti = alloc_type(TYP_OPTIONAL, inner3, 0);
                    }
                }
            }
            v := new_ir_var("ref", alloc_type(TYP_PTR, pti, 0));
            emit(IR_REF, v, op_var, ast_int_val(node), 0, 0);
            return v;
        }
        if op == UOP_DEREF {
            inner_var := gen_expr(ast_a(node));
            inner_var = force_if_thunk(inner_var);
            dv := new_ir_var("deref", ptr_pointee_type(inner_var));
            emit(IR_DEREF, dv, inner_var, -1, 0, ptr_access_width(inner_var));
            return dv;
        }
        op_var := gen_expr(ast_a(node));
        op_var = force_if_thunk(op_var);
        vt : ., mut = TI_INT;
        if op == UOP_NEG {
            // 一元负保持数值操作数类型：dex 精确（TI_DEX_S）→ 缩放整数取负 ✓；
            // dex apx（TI_DEX）→ 整型取负（binary64 符号位翻转未实现——既有 apx
            // 限制，数值迁移 Task 4 文档化；apx 负值请用 0 - x 表达）
            ot := irv_type(op_var);
            if ot == TI_DEX_S || ot == TI_DEX || ot == TI_INT { vt = ot; }
        }
        v := new_ir_var("un", vt);
        emit(IR_UNARY, v, op_var, 0, op, 0);
        return v;
    }

    // Function call
    if ast_kind(node) == EXPR_GO {
        body := ast_b(node);
        range_node := ast_data(node);  // 0 = single, EXPR_RANGE node = range go
        if range_node <= 0 {
            // Single go: emit call to sched_go(@addr(f), arg)
            // sched_go creates a goroutine via g_new + sched_enqueue and returns a channel
            if ast_kind(body) == EXPR_CALL {
                func_node := ast_a(body);
                first_arg := ast_b(body);
                func_ni : ., mut = -1;
                if ast_kind(func_node) == EXPR_IDENT {
                    func_ni = ast_int_val(func_node);
                } else if ast_kind(func_node) == EXPR_FIELD {
                    func_ni = ast_data(body);
                }
                // Evaluate the first argument (if any)
                arg_var : ., mut = -1;
                if first_arg >= 0 {
                    arg_var = gen_expr(ast_a(first_arg));
                    arg_var = force_if_thunk(arg_var);
                }
                // Function address via IR_FNADDR — the movabs placeholder is
                // patched to the function's absolute VA at ELF link time
                // (elf.cr Phase 3). goroutine_entry_wrapper reads it back
                // from G+56 (saved_fn) and calls saved_fn(saved_arg).
                fnaddr_var := new_ir_var("_go_fnaddr", TI_INT);
                emit(IR_FNADDR, fnaddr_var, func_ni, 0, 0, 0);
                // Create contiguous argument variables for the sched_go call:
                // arg0 = fn address, arg1 = arg value (0 when no arg)
                packed0 := new_ir_var("_go_fna", TI_INT);
                emit(IR_STORE, -1, packed0, fnaddr_var, 0, 0);
                packed1 := new_ir_var("_go_arg", TI_INT);
                if arg_var >= 0 {
                    emit(IR_STORE, -1, packed1, arg_var, 0, 0);
                } else {
                    emit(IR_CONST, packed1, 0, 0, 0, TI_INT);
                }
                dest := new_ir_var("_go_ch", TI_INT);
                sched_go_ni := str_intern("sched_go");
                emit(IR_CALL, dest, packed0, 2, sched_go_ni, TI_INT);
                return dest;
            }
            return gen_expr(body);
        }
        // Range go: go var start..end expr → collect results into array
        iter_ni := ast_c(node);  // loop variable name
        range_count := ast_b(range_node) - ast_a(range_node);
        if range_count <= 0 { return -1; }
        // Allocate results array
        arr_var := new_ir_var("go_arr", TI_UNIT);
        emit(IR_ALLOC_ARRAY, arr_var, range_count, 0, 0, 0);
        // Spawn each iteration
        if ast_kind(body) == EXPR_CALL {
            func_node := ast_a(body);
            func_ni : ., mut = -1;
            if ast_kind(func_node) == EXPR_IDENT { func_ni = ast_int_val(func_node); }
            // Extract the call arg that uses the iter variable
            fi : ., mut = 0;
            loop { if fi >= range_count { break; }
                // For each i, spawn with i as the iter var's value
                val_var := new_ir_var("go_val", TI_UNIT);
                emit(IR_CONST, val_var, ast_a(range_node) + fi, 0, 0, TI_INT);
                dest2 := new_ir_var("go_fut", TI_UNIT);
                emit(IR_SPAWN, dest2, val_var, 1, func_ni, -1);
                emit(IR_STORE_INDEX, -1, arr_var, dest2, fi, 0);
            fi = fi + 1; }
        }
        return arr_var;
    }

    if ast_kind(node) == EXPR_CALL {
        func_node := ast_a(node);
        first_arg := ast_b(node);
        arg_count := ast_c(node);
        call_flags := ast_type_val(node);
        is_module_call := call_flags == CALL_FLAG_MODULE || call_flags == CALL_FLAG_MODULE + CALL_FLAG_INLINE;
        is_inline_call := call_flags == CALL_FLAG_INLINE || call_flags == CALL_FLAG_MODULE + CALL_FLAG_INLINE;
        arg_vars : string, mut;    arg_vars_cap : int, mut;
        // R2 P4 Task 5：实参**节点**并行表（表示面写信道按实参位判表示需要节点——
        // 值 var 的类型不足以区分裸 T 与装箱 T?；方法调用时 arg 0 = 接收者节点）
        arg_nodes : string, mut;   arg_nodes_cap : int, mut;
        ac : ., mut = 0;
    arg_vars = alloc(64 * 8); arg_vars_cap = 64;
    arg_nodes = alloc(64 * 8); arg_nodes_cap = 64;
        func_ni : ., mut = -1;

        // @builtin(args) — parser wraps @foo(args) as EXPR_CALL(func=EXPR_AT, ...)
        // so we detect EXPR_AT here and handle it before the normal call dispatch.
        if ast_kind(func_node) == EXPR_AT {
            name_ni := ast_a(func_node);
            name := istr_get(name_ni);

            // @sizeOf(T): emit IR_CONST with type size
            if str_eq(name, "sizeOf") != 0 {
                ti := ti_from_type_expr(ast_a(first_arg));
                sz := type_size(ti);
                v := new_ir_var("_sizeof", TI_INT);
                emit(IR_CONST, v, sz, 0, 0, TI_INT);
                return v;
            }

            // @alignOf(T): emit IR_CONST with type alignment
            if str_eq(name, "alignOf") != 0 {
                ti := ti_from_type_expr(ast_a(first_arg));
                al := type_align(ti);
                v := new_ir_var("_alignof", TI_INT);
                emit(IR_CONST, v, al, 0, 0, TI_INT);
                return v;
            }

            // @fields(T): emit string array of field names
            if str_eq(name, "fields") != 0 {
                ti := ti_from_type_expr(ast_a(first_arg));
                si := ti_resolve_struct(ti);
                v := new_ir_var("_fields", TI_STR);
                if si >= 0 {
                    fc := si_field_count(si);
                    // Build a string constant: comma-separated field names
                    fields_str : ., mut = "";
                    fi : ., mut = 0;
                    loop {
                        if fi >= fc { break; }
                        fname := istr_get(si_field_name(si, fi));
                        if fi > 0 { fields_str = fields_str + ","; }
                        fields_str = fields_str + fname;
                        fi = fi + 1;
                    }
                    ni := str_intern(fields_str);
                    track_str(ni);
                    emit(IR_CONST, v, ni, 0, 0, TI_STR);
                } else {
                    emit(IR_CONST, v, 0, 0, 0, TI_STR);
                }
                return v;
            }

            // @hasField(T, name): check field existence
            if str_eq(name, "hasField") != 0 {
                ti := ti_from_type_expr(ast_a(first_arg));
                name_arg := ast_b(first_arg);
                name_expr := ast_a(name_arg);
                fn_name := istr_get(ast_int_val(name_expr));
                exists := ti_has_field(ti, fn_name);
                v := new_ir_var("_hasf", TI_BOOL);
                emit(IR_CONST, v, exists, 0, 0, TI_BOOL);
                return v;
            }

            // @field(T, name): get field offset
            if str_eq(name, "field") != 0 {
                ti := ti_from_type_expr(ast_a(first_arg));
                name_arg := ast_b(first_arg);
                name_expr := ast_a(name_arg);
                fn_name := istr_get(ast_int_val(name_expr));
                off := ti_field_offset(ti, fn_name);
                v := new_ir_var("_fldoff", TI_INT);
                emit(IR_CONST, v, off, 0, 0, TI_INT);
                return v;
            }

            // @typeInfo(T): emit type description string
            if str_eq(name, "typeInfo") != 0 {
                ti := ti_from_type_expr(ast_a(first_arg));
                type_str : ., mut = "";
                k := get_type_kind(ti);
                if k == TYP_NAMED {
                    name_ni := get_type_data(ti);
                    type_str = istr_get(name_ni);
                } else if ti == TI_INT { type_str = "int"; }
                else if ti == TI_BOOL { type_str = "bool"; }
                else if ti == TI_DEX || ti == TI_DEX_S { type_str = "dex"; }
                else if ti == TI_STR { type_str = "string"; }
                else if ti == TI_CHAR { type_str = "char"; }
                else if ti == TI_UNIT { type_str = "unit"; }
                else { type_str = "unknown"; }
                ni := str_intern(type_str);
                track_str(ni);
                v := new_ir_var("_tinfo", TI_STR);
                emit(IR_CONST, v, ni, 0, 0, TI_STR);
                return v;
            }

            // @raw_int(expr): 显式转换——dex 表达式 → 其定点缩放整数原值（int）。
            // 数值迁移 Task 4：dex.cr 的打印等辅助以此访问缩放表示的原始整数；
            // apx 值（TI_DEX bits）先按边界规则转 scaled（F2I(bits×S)）。
            // 结果必须复制为 TI_INT 定型变量——直接返回内层变量会携带其 dex 类型
            // （TI_DEX_S），后续 int 运算被误分派到 dex 精确路径。
            if str_eq(name, "raw_int") != 0 {
                inner_var := gen_expr(ast_a(first_arg));
                inner_var = force_if_thunk(inner_var);
                if irv_type(inner_var) == TI_DEX {
                    inner_var = dex_bits_to_scaled(inner_var);
                }
                rv := new_ir_var("_raw", TI_INT);
                emit(IR_STORE, -1, rv, inner_var, 0, 0);
                return rv;
            }

            // @comptime(expr): force compile-time evaluation
            if str_eq(name, "comptime") != 0 {
                inner_expr := ast_a(first_arg);
                // Generate IR for the inner expression
                inner_var := gen_expr(inner_expr);
                inner_var = force_if_thunk(inner_var);
                // If the inner expression is a constant, it's already folded.
                // For runtime-dependent exprs, we'd need the interpreter.
                // For now: gen IR and return — the existing constant folding
                // (inline IR_CONST from @sizeOf etc.) handles pure compile-time exprs.
                // Future: invoke ir_interpret_expr for true forced evaluation.
                return inner_var;
            }

            // @inline(fn): emit IR_INLINE hint
            if str_eq(name, "inline") != 0 {
                fn_var := gen_expr(ast_a(first_arg));
                fn_var = force_if_thunk(fn_var);
                emit(IR_INLINE, -1, fn_var, 0, 0, 0);
                return fn_var;
            }

            // @NoBoundsCheck: emit annotation (no args)
            if str_eq(name, "NoBoundsCheck") != 0 {
                emit(IR_NO_BOUNDS_CHECK, -1, 0, 0, 0, 0);
                return -1;
            }

            // @fast: emit annotation (no args)
            if str_eq(name, "fast") != 0 {
                emit(IR_FAST, -1, 0, 0, 0, 0);
                return -1;
            }

            // @unroll(n): emit loop unroll hint
            if str_eq(name, "unroll") != 0 {
                unroll_count := ast_int_val(ast_a(first_arg));
                emit(IR_UNROLL, -1, unroll_count, 0, 0, 0);
                return -1;
            }

            // @section(name): emit code section hint
            if str_eq(name, "section") != 0 {
                name_expr := ast_a(ast_a(first_arg));
                name_ni := ast_int_val(name_expr);
                track_str(name_ni);
                emit(IR_SECTION, -1, name_ni, 0, 0, 0);
                return -1;
            }

            // @addr(fn): get function address (patched at ELF link time)
            if str_eq(name, "addr") != 0 {
                fn_expr := ast_a(first_arg);
                if ast_kind(fn_expr) == EXPR_IDENT {
                    fn_ni := ast_int_val(fn_expr);
                    v := new_ir_var("_fnaddr", TI_INT);
                    emit(IR_FNADDR, v, fn_ni, 0, 0, 0);
                    return v;
                }
                return -1;
            }

            return -1;
        }

        // Module or method call: obj.method(args)
        if ast_kind(func_node) == EXPR_FIELD {
            func_ni = ast_data(node); // function name (set by checker for module calls)
            if !is_module_call {
                // Method call: self is first arg
                obj_node := ast_a(func_node);
                self_var := gen_expr(obj_node);
                self_var = force_if_thunk(self_var);
                if ac >= arg_vars_cap { nc := arg_vars_cap * 2; nb := alloc(nc * 8); _dyncpy(arg_vars, arg_vars_cap * 8, nb); arg_vars = nb; arg_vars_cap = nc; } w64(arg_vars, ac * 8, self_var);
                if ac >= arg_nodes_cap { nc := arg_nodes_cap * 2; nb := alloc(nc * 8); _dyncpy(arg_nodes, arg_nodes_cap * 8, nb); arg_nodes = nb; arg_nodes_cap = nc; } w64(arg_nodes, ac * 8, obj_node);
                ac = ac + 1;
            }
        } else if ast_kind(func_node) == EXPR_IDENT {
            func_ni = ast_int_val(func_node);
        }

        // Generate remaining args (walk EXPR_ARG chain)
        an : ., mut = first_arg;
        loop {
            if an < 0 { break; }
            arg_var := gen_expr(ast_a(an));
            arg_var = force_if_thunk(arg_var);
            if ac >= arg_vars_cap { nc := arg_vars_cap * 2; nb := alloc(nc * 8); _dyncpy(arg_vars, arg_vars_cap * 8, nb); arg_vars = nb; arg_vars_cap = nc; } w64(arg_vars, ac * 8, arg_var);
            if ac >= arg_nodes_cap { nc := arg_nodes_cap * 2; nb := alloc(nc * 8); _dyncpy(arg_nodes, arg_nodes_cap * 8, nb); arg_nodes = nb; arg_nodes_cap = nc; } w64(arg_nodes, ac * 8, ast_a(an));
            ac = ac + 1;
            an = ast_b(an);
        }
        // dex 边界规则（数值迁移 Task 4 + 终审 M2）：dex 参数在调用点按被调方形式对齐——
        //   Core 函数：一律精确形式（scaled），apx 位模式参数转 scaled（F2I(bits×S)）；
        //   extern 函数：C ABI 契约（module.cr：dex 编码 3 = binary64 跨 C 边界），
        //     精确形式（scaled）实参转 binary64 bits（I2F/S——字面量重发射位模式常量）
        // 覆盖面（apx 批 T3；维护者硬条件 1「逐形态收窄」）：环从「仅直调」放宽到
        // **可解析到 Core/extern 函数的调用形态**——直调（EXPR_IDENT）/ 方法调用
        // （EXPR_FIELD 且非模块调用）/ 模块限定调用（EXPR_FIELD 且 is_module_call）。
        //   · 三者共用同一环：实参表与形参链**天然对齐**（方法调用的接收者占
        //     arg_vars[0]，而 `self` 在方法形参链中亦占第 0 位——parser.cr:1378-1405
        //     把 self 物化为 EXPR_PARAM）；`arg_nodes` 游标同步走 EXPR_ARG 链。
        //   · **不是「凡调用都进环」**：EXPR_AT 内建在 `:1600` 已提前返回（独立路径）；
        //     `find_func` 落空（func_ni < 0 / 名字非函数）⇒ 无声明面 ⇒ 环不进（零变化）。
        //   · 实测依据：方法调用 b1/b1b 红 49/15 · 模块限定调用 m1b 红（ELF=4，期望 7）
        //     —— 二者同因（旧门的 `EXPR_IDENT` 硬限制）。
        if func_ni >= 0 {
            cfi := find_func(func_ni);
            if cfi >= 0 {
                cfn := fi_ast_node(cfi);
                cfn_ext : ., mut = 0;
                if cfn >= 0 && ast_kind(cfn) == EXPR_EXTERN { cfn_ext = 1; }
                if cfn >= 0 && (cfn_ext != 0 || ast_kind(cfn) == EXPR_FN) {
                    cpi : ., mut = 0;
                    cpn : ., mut = ast_b(cfn);
                    // 实参节点与实参 var **同表锁步**取（`arg_nodes[cpi]` 与 `arg_vars[cpi]`
                    // 同索引写入，接收者亦在内）——方法调用下 EXPR_ARG 链**不含接收者**，
                    // 若按链另走游标会滞后一位（本批实测：node 仅服务于 extern 字面量
                    // 重发射，Core 分支不用；仍按锁步改正以免埋雷）。
                    loop {
                        if cpi >= ac { break; }
                        if cpn < 0 { break; }
                        // 批 5（opt-dex · R3）：`dex?` 形参也进环——修复前门只认基类型节点
                        // （`type_val == TI_DEX`），`dex?` 的 `type_val` = 0 ⇒ apx 实参不转换
                        // ⇒ 与 callee 槽型（本批已改 TI_DEX_S）口径一致；extern 侧不扩
                        // （C ABI 无可选表示，`.so` 面登记未覆盖面）。
                        if ast_type_val(cpn) == TI_DEX ||
                           (cfn_ext == 0 && dex_opt_type_node(ast_data(cpn)) != 0) {
                            av := r64(arg_vars, cpi * 8);
                            if av >= 0 {
                                if cfn_ext != 0 {
                                    // extern：scaled → bits（字面量直接重发射位模式常量）
                                    if irv_type(av) == TI_DEX_S {
                                        arg_node : ., mut = -1;
                                        if cpi < arg_nodes_cap { arg_node = r64(arg_nodes, cpi * 8); }
                                        av = dex_scaled_to_bits(av, arg_node);
                                        w64(arg_vars, cpi * 8, av);
                                    }
                                } else if irv_type(av) == TI_DEX {
                                    // Core 函数：apx bits → scaled
                                    av = dex_bits_to_scaled(av);
                                    w64(arg_vars, cpi * 8, av);
                                }
                            }
                        }
                        cpi = cpi + 1;
                        cpn = cpn + 1;
                        loop {
                            if cpn >= g_ast_count { break; }
                            if ast_kind(cpn) == EXPR_PARAM { break; }
                            cpn = cpn + 1;
                        }
                    }
                }
            }
        }
        // Generic function: redirect to monomorphized (specialized) version
        if func_ni >= 0 && (ast_kind(func_node) == EXPR_IDENT) {
            gen_fi := find_func(func_ni);
            if gen_fi >= 0 && fi_generic_count(gen_fi) > 0 {
                // ─── R2 P3 Task 5（Step 4）：实例键类型项化 ───
                // 优先：checker 登记的**调用点绑定段**（g_gen_binds；节点 int_val = 段起始+1，
                // 0 = 无）——按被调方泛型形参**声明序**给 ti，键 = `inst_key_of_ti` 规范结构名
                // （含命名/应用实参真身份），替换走 ti 路径（monomorph.cr）。前置 = 段长与形参
                // 数一致 + 全绑定 + 全具体（否则回落旧路径；半解实例比旧路径更坏）。
                // 回落（旧路径，**逐字保留**）：键由**实参 IR 变量类型**拼名串（非原生 → "int"
                // 兜底），替换走名字路径——`gen_create_instance(func, args, -1)`。
                gc_g := fi_generic_count(gen_fi);
                biv := ast_int_val(node);
                type_args : ., mut = "";
                bstart : ., mut = -1;
                if biv > 0 {
                    bs := biv - 1;
                    if bs < g_gen_binds_count {
                        bcnt := r64(g_gen_binds, bs * 8);
                        if bcnt == gc_g && bs + 1 + bcnt <= g_gen_binds_count {
                            ok_b : ., mut = 1;
                            gi_b : ., mut = 0;
                            loop {
                                if gi_b >= bcnt { break; }
                                bt := r64(g_gen_binds, (bs + 1 + gi_b) * 8);
                                if bt < 0 { ok_b = 0; break; }
                                if inst_ti_concrete(bt) == 0 { ok_b = 0; break; }
                                if inst_type_node_of_ti(bt) < 0 { ok_b = 0; break; }
                                if gi_b > 0 { type_args = type_args + ","; }
                                type_args = type_args + inst_key_of_ti(bt);
                                gi_b = gi_b + 1;
                            }
                            if ok_b != 0 { bstart = bs; }
                        }
                    }
                }
                if bstart < 0 {
                    // 旧路径：逐实参类型名串（**不得**改动——checker 未给绑定时的唯一退路）
                    type_args = "";
                    ai : ., mut = 0;
                    loop {
                        if ai >= ac { break; }
                        av := r64(arg_vars, ai * 8);
                        ti := TI_INT;
                        if av >= 0 { ti = irv_type(av); }
                        if ai > 0 { type_args = type_args + ","; }
                        if ti == TI_INT { type_args = type_args + "int"; }
                        else if ti == TI_STR { type_args = type_args + "string"; }
                        else if ti == TI_BOOL { type_args = type_args + "bool"; }
                        else if ti == TI_CHAR { type_args = type_args + "char"; }
                        else if ti == TI_DEX || ti == TI_DEX_S { type_args = type_args + "dex"; }
                        else if ti == TI_UNIT { type_args = type_args + "unit"; }
                        else { type_args = type_args + "int"; }
                        ai = ai + 1;
                    }
                }
                // Find or create specialized function instance
                spec_ni : ., mut = -1;
                if bstart >= 0 { spec_ni = gen_find_or_create_bind(gen_fi, type_args, bstart); }
                else { spec_ni = gen_find_or_create(gen_fi, type_args); }
                if spec_ni >= 0 {
                    func_ni = fi_name(spec_ni);
                    // Fall through to normal IR_CALL emission
                }
            }
        }
        if is_inline_call && func_ni >= 0 {
            emit(IR_INLINE, -1, func_ni, 0, 0, 0);
        }
        // Check SO function dispatch (variadic expansion, auto_str, etc.)
        handled := dispatch_call(func_ni, ac, arg_vars);
        if handled >= 0 { return handled; }

        // For method calls (EXPR_FIELD), func_ni was set by checker
        // Use it directly
        call_ti := ir_call_return_type(func_ni);
        dest := new_ir_var("call", call_ti);
        first_arg_var := -1;
        need_pack : ., mut = 0;
        if ac > 0 {
            prev := r64(arg_vars, 0 * 8);
            first_arg_var = prev;
            ai : ., mut = 1;
            loop {
                if ai >= ac { break; }
                cur := r64(arg_vars, ai * 8);
                if cur != prev + 1 { need_pack = 1; break; }
                prev = cur;
                ai = ai + 1;
            }
        }
        if need_pack != 0 {
            ai : ., mut = 0;
            loop {
                if ai >= ac { break; }
                av := r64(arg_vars, ai * 8);
                at := TI_INT;
                if av >= 0 { at = irv_type(av); }
                packed := new_ir_var("_arg", at);
                if ai == 0 { first_arg_var = packed; }
                emit(IR_STORE, -1, packed, av, 0, 0);
                ai = ai + 1;
            }
        }
        // Dyn method dispatch: receiver is a dyn value, emit dynamic dispatch
        if ast_kind(func_node) == EXPR_FIELD && ac > 0 && func_ni >= 0 {
            dyn_receiver := first_arg_var;
            if dyn_receiver >= 0 && irv_type(dyn_receiver) == TI_DYN {
                dyn_dest := new_ir_var("_dyncall", TI_UNIT);
                emit(IR_DYN_DISPATCH, dyn_dest, dyn_receiver, func_ni, 0, 0);
                return dyn_dest;
            }
        }

        // Hotpatch function call: emit IR_HOTPATCH_ROUTE instead of IR_CALL
        // R2 P5 Task 2（F1 裁决）：第 6 实参**必须显式给**。修复前本调用点只传 5 参，
        // 而 `emit` 形参 6 个 ⇒ 第 6 参 = **残留寄存器值**（corec 由 Python bootstrap
        // 生成：bootstrap/corec/backend/x86_64_stack_asm.py:222-226 只为实际存在的
        // 实参写寄存器，r9 保持前序计算的残留 ⇒ 实测同一语料两种程序形状得 0 / 4 两值；
        // 自托管语义下缺省实参 = 0）。op39 的类型面 = 「无」（Task 0 表 A），故显式 0。
        // 已裁决偏差登记：含 hotpatch 的语料该节点码 4→0（该值本是垃圾、零消费者；
        // canary 语料 ptr_arith 不含 hotpatch ⇒ 不受影响）。把未定义行为烘进分类表
        // 不可接受——分类表要求「每格有依据」。
        if func_ni >= 0 && is_hotpatch_func(func_ni) != 0 {
            emit(IR_HOTPATCH_ROUTE, dest, func_ni, first_arg_var, ac, 0);
            return dest;
        }
        // Extern function call: emit IR_CALL_EXTERN for FFI dispatch
        if func_ni >= 0 {
            fi := find_func(func_ni);
            if fi >= 0 {
                fn_node := fi_ast_node(fi);
                if fn_node >= 0 && ast_kind(fn_node) == EXPR_EXTERN {
                    emit(IR_CALL_EXTERN, dest, func_ni, first_arg_var, ac, 0);
                    return dest;
                }
            }
        }
        // 可选表示（R2 P4 Task 5）：实参表示写信道——逐实参位写（被调序言最早处读；
        // 写点 = 全部实参求值之后、IR_CALL 紧邻之前 ⇒ 嵌套调用不覆写信道）。
        if g_optrep_on != 0 && g_optrep_arg_count > 0 {
            ai3 : ., mut = 0;
            loop {
                if ai3 >= ac { break; }
                if ai3 >= g_optrep_arg_count { break; }
                av3 := r64(arg_vars, ai3 * 8);
                an3 : ., mut = -1;
                if ai3 < arg_nodes_cap { an3 = r64(arg_nodes, ai3 * 8); }
                emit_rep_set(g_optrep_arg_cell0 + ai3, rep_enc_of_expr(an3, av3));
                ai3 = ai3 + 1;
            }
        }
        emit(IR_CALL, dest, first_arg_var, ac, func_ni, call_ti);
        // 可选表示（R2 P4 Task 5）：被调返回可选 ⇒ 1) 读返回信道（读点必须**紧跟真实
        // 调用**：调用点与返回点同进程同栈、其间无写入）；2) **禁惰性 thunk**——thunk 把
        // 调用推迟到 force 点，读点即悬空（实测踩过：`v := g()` 的 g 判纯 ⇒ thunk ⇒ 表示位
        // 回落装箱 ⇒ 裸值返回解包崩）。代价 = 仅「返回可选」的被调不做 thunk 延迟。
        ret_opt : ., mut = 0;
        if g_optrep_on != 0 && g_optrep_ret_cell >= 0 { ret_opt = callee_ret_optional(func_ni); }
        // Lazy thunk: if calling a pure function with single use, wrap as thunk
        if func_ni >= 0 && ret_opt == 0 {
            call_fi := find_func(func_ni);
            if call_fi >= 0 && fi_ispure(call_fi) != 0 {
                grow_var_use_count(dest + 1);
                use_count := r64(g_var_use_count, dest * 8);
                if use_count <= 1 {
                    thunk_var := new_ir_var("_lazy", irv_type(dest));
                    emit(IR_LAZY_THUNK, thunk_var, dest, 0, 0, 0);
                    return thunk_var;
                }
            }
        }
        if ret_opt != 0 {
            rvr := new_ir_var("call_rep", TI_INT);
            emit(IR_LOAD, rvr, g_optrep_ret_cell, 0, 0, TI_INT);
            irv_set_rep(dest, rvr);
        }
        return dest;
    }

    // Block
    if ast_kind(node) == EXPR_BLOCK {
        stmt_start := ast_a(node);
        stmt_count := ast_b(node);
        last : ., mut = -1;
        push_ir_scope();
        i : ., mut = 0;
        loop {
            if i >= stmt_count { break; }
            sn := r64(g_block_stmts, (stmt_start + i) * 8);
            last = gen_expr(sn);
            i = i + 1;
        }
        pop_ir_scope();
        return last;
    }

    // If expression
    if ast_kind(node) == EXPR_IF {
        sg_push(SG_IF);  // conditional region: covers [condition, merge)
        cond := ast_a(node);
        then_node := ast_b(node);
        else_node := ast_c(node);
        cond_var := gen_expr(cond);
        cond_var = force_if_thunk(cond_var);
        then_lbl := new_label();
        else_lbl := new_label();
        merge_lbl := new_label();
        if else_node >= 0 {
            emit(IR_BRANCH, -1, cond_var, then_lbl, else_lbl, 0);
        } else {
            emit(IR_BRANCH, -1, cond_var, then_lbl, merge_lbl, 0);
        }
        emit(IR_LABEL, -1, then_lbl, 0, 0, 0);
        gen_expr(then_node);
        emit(IR_JUMP, -1, merge_lbl, 0, 0, 0);
        if else_node >= 0 {
            emit(IR_LABEL, -1, else_lbl, 0, 0, 0);
            gen_expr(else_node);
            emit(IR_JUMP, -1, merge_lbl, 0, 0, 0);
        }
        emit(IR_LABEL, -1, merge_lbl, 0, 0, 0);
        sg_pop();
        return -1;
    }

    // Loop
    if ast_kind(node) == EXPR_LOOP {
        header_lbl := new_label();
        body_lbl := new_label();
        exit_lbl := new_label();
        emit(IR_JUMP, -1, header_lbl, 0, 0, 0);
        // SG_LOOP region covers [header, exit) — the back-edge jump to the
        // header lands on the region enter (region iteration in interp.cr).
        sg_alloc_push(SG_LOOP);
        arena_var := new_ir_var("_arena", TI_INT);
        w64(g_sg_arena_var, (g_sg_count - 1) * 8, arena_var);
        emit(IR_LABEL, -1, header_lbl, 0, 0, 0);
        emit(IR_JUMP, -1, body_lbl, 0, 0, 0);
        emit(IR_LABEL, -1, body_lbl, 0, 0, 0);
        emit(IR_ARENA_NEW, arena_var, 0, 0, 0, 0);
        arena_instr := g_ir_instr_count - 1;
        push_ir_scope();
        // `continue` must jump to the post label (not the header) so the
        // arena reset runs on the continue path too — symmetric with `for`.
        post_lbl := new_label();
        push_loop_labels(post_lbl, exit_lbl);
        gen_expr(ast_a(node));
        pop_loop_labels();
        pop_ir_scope();
        total := r64(g_sg_alloc_total, g_sg_count - 1);
        if total > 0 { iri_set_s1(arena_instr, total); }
        emit(IR_LABEL, -1, post_lbl, 0, 0, 0);
        emit(IR_ARENA_RESET, -1, arena_var, 0, 0, 0);  // arena reused per iteration
        emit(IR_JUMP, -1, header_lbl, 0, 0, 0);
        emit(IR_LABEL, -1, exit_lbl, 0, 0, 0);
        sg_pop();  // close loop region (arena already reset above)
        return -1;
    }

    // While loop
    if ast_kind(node) == EXPR_WHILE {
        cond := ast_a(node);
        body := ast_b(node);
        header_lbl := new_label();
        body_lbl := new_label();
        exit_lbl := new_label();
        // Keep while loops on the same SG_LOOP protocol as loop/for: the
        // region owns the condition, body, back-edge, and exit label so sg_pop
        // can add the termination dependency and advance the state chain.
        sg_push(SG_LOOP);
        arena_var := new_ir_var("_arena", TI_INT);
        w64(g_sg_arena_var, (g_sg_count - 1) * 8, arena_var);
        emit(IR_LABEL, -1, header_lbl, 0, 0, 0);
        cond_var := gen_expr(cond);
        cond_var = force_if_thunk(cond_var);
        emit(IR_BRANCH, -1, cond_var, body_lbl, exit_lbl, 0);
        emit(IR_LABEL, -1, body_lbl, 0, 0, 0);
        emit(IR_ARENA_NEW, arena_var, 0, 0, 0, 0);
        arena_instr := g_ir_instr_count - 1;
        push_ir_scope();
        // Continue must pass through the reset point before rechecking cond.
        post_lbl := new_label();
        push_loop_labels(post_lbl, exit_lbl);
        gen_expr(body);
        pop_loop_labels();
        pop_ir_scope();
        total := r64(g_sg_alloc_total, g_sg_count - 1);
        if total > 0 { iri_set_s1(arena_instr, total); }
        emit(IR_LABEL, -1, post_lbl, 0, 0, 0);
        emit(IR_ARENA_RESET, -1, arena_var, 0, 0, 0);
        emit(IR_JUMP, -1, header_lbl, 0, 0, 0);
        emit(IR_LABEL, -1, exit_lbl, 0, 0, 0);
        sg_pop();  // close loop region (arena already reset above)
        return -1;
    }

    // For loop: for var in start..end { body }
    if ast_kind(node) == EXPR_FOR {
        var_ni := ast_a(node);
        iter := ast_b(node);
        body := ast_c(node);
        start_var := -1;
        end_var := -1;
        if ast_kind(iter) == EXPR_RANGE {
            start_var = gen_expr(ast_a(iter));
            start_var = force_if_thunk(start_var);
            end_var = gen_expr(ast_b(iter));
            end_var = force_if_thunk(end_var);
        } else {
            // Non-range iterable: evaluate and use 0..iter
            s := new_ir_var("start", TI_INT);
            emit(IR_CONST, s, 0, 0, 0, TI_INT);
            start_var = s;
            end_var = gen_expr(iter);
            end_var = force_if_thunk(end_var);
        }
        // Create loop variable, init to start
        ivar := new_ir_var("for_i", TI_INT);
        emit(IR_ALLOC, ivar, 0, 0, 0, TI_INT);
        emit(IR_STORE, -1, ivar, start_var, 0, 0);
        bind_local(var_ni, ivar);
        header_lbl := new_label();
        body_lbl := new_label();
        exit_lbl := new_label();
        // The SG_FOR region covers [header, exit): the back-edge jump to the
        // header is then a jump to the region enter, so the interpreter can
        // drive loop iteration from region boundaries (region iteration).
        sg_alloc_push(SG_FOR);
        arena_var := new_ir_var("_arena", TI_INT);
        w64(g_sg_arena_var, (g_sg_count - 1) * 8, arena_var);
        // Header: check ivar < end, branch to exit if false
        emit(IR_LABEL, -1, header_lbl, 0, 0, 0);
        cond_var := new_ir_var("for_cond", TI_INT);
        emit(IR_BINARY, cond_var, ivar, end_var, OP_LT, 0);
        emit(IR_BRANCH, -1, cond_var, body_lbl, exit_lbl, 0);
        // Body
        emit(IR_LABEL, -1, body_lbl, 0, 0, 0);
        emit(IR_ARENA_NEW, arena_var, 0, 0, 0, 0);
        arena_instr := g_ir_instr_count - 1;
        push_ir_scope();
        // `continue` must jump to the post (increment) label, not the header —
        // otherwise the loop variable never advances and the loop spins.
        post_lbl := new_label();
        push_loop_labels(post_lbl, exit_lbl);
        gen_expr(body);
        pop_loop_labels();
        pop_ir_scope();
        total := r64(g_sg_alloc_total, g_sg_count - 1);
        if total > 0 { iri_set_s1(arena_instr, total); }
        // Increment ivar and jump to header (arena reset runs on every path,
        // including the continue path, so per-iteration memory is reused)
        emit(IR_LABEL, -1, post_lbl, 0, 0, 0);
        emit(IR_ARENA_RESET, -1, arena_var, 0, 0, 0);
        one_var := new_ir_var("one", TI_INT);
        emit(IR_CONST, one_var, 1, 0, 0, TI_INT);
        inc_var := new_ir_var("inc", TI_INT);
        emit(IR_BINARY, inc_var, ivar, one_var, OP_ADD, 0);
        emit(IR_STORE, -1, ivar, inc_var, 0, 0);
        emit(IR_JUMP, -1, header_lbl, 0, 0, 0);
        // Exit
        emit(IR_LABEL, -1, exit_lbl, 0, 0, 0);
        sg_pop();  // close loop region (arena already reset above)
        return -1;
    }

    // Match expression
    if ast_kind(node) == EXPR_MATCH {
        match_expr := ast_a(node);
        first_arm := ast_b(node);
        match_val := gen_expr(match_expr);
        match_val = force_if_thunk(match_val);
        // Allocate a result variable for the match expression value
        result_var := new_ir_var("match_res", TI_INT);
        emit(IR_ALLOC, result_var, 0, 0, 0, TI_INT);
        // 容量批 T2（裁-CAP-1 (a) 的 match 面 = 裁决 (i) 表示位案）：结果槽配**表示位**
        // （与既有局部机制同源；默认 1 = 装箱），各臂写点置位 ⇒ 消费点（LET/返回/解包）
        // 自动继承正确表示。修复前：臂写裸值时无表示 ⇒ 消费侧落 `oe_boxed()` 装箱假定
        // ⇒ 双路径 139（T1 实测 e2_matchres_bare）。
        mrep_var : ., mut = -1;
        if g_optrep_on != 0 {
            mrep_var = new_ir_var("match_res_rep", TI_INT);
            emit(IR_CONST, mrep_var, 1, 0, 0, TI_INT);
            irv_set_rep(result_var, mrep_var);
        }
        merge_lbl := new_label();
        an : ., mut = first_arm;
        loop {
            if an < 0 { break; }
            arm_pat := ast_a(an);
            arm_body := ast_b(an);
            pat_kind := -1;
            if arm_pat >= 0 { pat_kind = ast_kind(arm_pat); }
            is_wildcard := 0;
            if pat_kind == EXPR_WILDCARD { is_wildcard = 1; }
            // 可选表示位（R2 P4 Task 5）：臂条件与臂体绑定共用（声明在臂作用域）
            rep_v : ., mut = -1;
            body_lbl := new_label();
            fall_lbl : ., mut = merge_lbl;
            has_next := 0;
            if ast_c(an) >= 0 { has_next = 1; }
            if is_wildcard == 1 {
                emit(IR_JUMP, -1, body_lbl, 0, 0, 0);
            } else if pat_kind == EXPR_ENUMPAT {
                variant_ni := get_variant_name_idx(ast_a(arm_pat));
                // R2 P4 Task 5：**解包侧判表示**——scrutinee 配表示位（可选槽）时按位分派：
                //   裸值（0）→ 值即载荷：Some 模式命中臂体（**不读 tag**——裸值非对象，
                //   读 tag 即 SIGSEGV = 原红态）；None 模式不命中（裸值非 null）。
                //   装箱（≠0）→ 既有 tag 分派（逐字不变）。
                // 无表示位（非可选槽 / 未覆盖面）→ 既有路径逐字不变（装箱假定）。
                if g_optrep_on != 0 && match_val >= 0 { rep_v = irv_rep(match_val); }
                if rep_v < 0 {
                    tag_var := new_ir_var("tag", TI_INT);
                    emit(IR_LOAD_ENUM_TAG, tag_var, match_val, 0, 0, 0);
                    vtag := new_ir_var("vtag", TI_INT);
                    emit(IR_CONST, vtag, variant_ni, 0, 0, TI_INT);
                    cmp_var := new_ir_var("cmp", TI_INT);
                    emit(IR_BINARY, cmp_var, tag_var, vtag, OP_EQ, 0);
                    if has_next == 1 { fall_lbl = new_label(); }
                    emit(IR_BRANCH, -1, cmp_var, body_lbl, fall_lbl, 0);
                } else {
                    is_some_pat : ., mut = 0;
                    if str_eq(istr_get(variant_ni), "Some") != 0 { is_some_pat = 1; }
                    tag_lbl := new_label();
                    if has_next == 1 { fall_lbl = new_label(); }
                    zb := new_ir_var("_rz", TI_INT);
                    emit(IR_CONST, zb, 0, 0, 0, TI_INT);
                    isb := new_ir_var("rep_isbare", TI_INT);
                    if is_some_pat != 0 { emit(IR_BINARY, isb, rep_v, zb, OP_EQ, 0); }
                    else { emit(IR_BINARY, isb, rep_v, zb, OP_NE, 0); }
                    // Some：裸 → 直接命中；装箱 → 落 tag 比对。None：裸 → 不命中（落 fall）；
                    // 装箱 → 落 tag 比对。
                    if is_some_pat != 0 { emit(IR_BRANCH, -1, isb, body_lbl, tag_lbl, 0); }
                    else { emit(IR_BRANCH, -1, isb, tag_lbl, fall_lbl, 0); }
                    emit(IR_LABEL, -1, tag_lbl, 0, 0, 0);
                    tag_var := new_ir_var("tag", TI_INT);
                    emit(IR_LOAD_ENUM_TAG, tag_var, match_val, 0, 0, 0);
                    vtag := new_ir_var("vtag", TI_INT);
                    emit(IR_CONST, vtag, variant_ni, 0, 0, TI_INT);
                    cmp_var := new_ir_var("cmp", TI_INT);
                    emit(IR_BINARY, cmp_var, tag_var, vtag, OP_EQ, 0);
                    emit(IR_BRANCH, -1, cmp_var, body_lbl, fall_lbl, 0);
                }
            } else if pat_kind == EXPR_INT {
                pat_val := new_ir_var("pval", TI_INT);
                emit(IR_CONST, pat_val, ast_int_val(arm_pat), 0, 0, TI_INT);
                cmp_var := new_ir_var("cmp", TI_INT);
                emit(IR_BINARY, cmp_var, match_val, pat_val, OP_EQ, 0);
                if has_next == 1 { fall_lbl = new_label(); }
                emit(IR_BRANCH, -1, cmp_var, body_lbl, fall_lbl, 0);
            } else if pat_kind == EXPR_BOOL {
                pat_val := new_ir_var("pval", TI_INT);
                pat_bool : ., mut = 0;
                if ast_int_val(arm_pat) != 0 { pat_bool = 1; }
                emit(IR_CONST, pat_val, pat_bool, 0, 0, TI_INT);
                cmp_var := new_ir_var("cmp", TI_INT);
                emit(IR_BINARY, cmp_var, match_val, pat_val, OP_EQ, 0);
                if has_next == 1 { fall_lbl = new_label(); }
                emit(IR_BRANCH, -1, cmp_var, body_lbl, fall_lbl, 0);
            }
            emit(IR_LABEL, -1, body_lbl, 0, 0, 0);
            push_ir_scope();
            if pat_kind == EXPR_ENUMPAT {
                sub_count := ast_c(arm_pat);
                fi : ., mut = 0;
                loop {
                    if fi >= sub_count { break; }
                    fv := new_ir_var("fld", TI_INT);
                    // TODO #2026-09-16-16 批 2：载荷读定型取**声明面形式**（dex 载荷 ⇒ TI_DEX_S）
                    // 批 5（opt-dex · G2）：optional 声明的载荷（内建 `Some` 面无枚举行 ⇒
                    // `agg_payload_read_form` 恒 TI_INT）改由 **scrutinee 的声明行**补判——
                    // `irv_decl_ti(match_val)` 是 LET 期登记的 `TYP_OPTIONAL` 行（`:2573`），
                    // `dex_opt_slot_ti` 纯表读（**零 alloc_type** = G2 红线）。否则 `dex?`
                    // 载荷入 dex 运算会被当 int 再 ×S（`dex_scale_int`）。
                    fv_ti : ., mut = agg_payload_read_form(arm_pat, fi);
                    if fv_ti == TI_INT && match_val >= 0 {
                        if dex_opt_slot_ti(irv_decl_ti(match_val)) != 0 { fv_ti = TI_DEX_S; }
                    }
                    irv_set_type(fv, fv_ti);
                    if rep_v < 0 {
                        emit(IR_LOAD_FIELD, fv, match_val, 0, fi + 1, 0);  // +1 for tag offset
                    } else {
                        // 解包侧判表示：裸值（0）→ 槽值**即**载荷（直取，不解引用）；
                        // 装箱（≠0）→ 字段 fi+1（既有语义）。裸分支须**跳过**装
                        // 箱分支的字段读（end_lbl）——否则裸值仍被解引用（原红态）。
                        bare_lbl := new_label();
                        boxed_lbl := new_label();
                        end_lbl := new_label();
                        zb2 := new_ir_var("_rz", TI_INT);
                        emit(IR_CONST, zb2, 0, 0, 0, TI_INT);
                        ib2 := new_ir_var("rep_isbare", TI_INT);
                        emit(IR_BINARY, ib2, rep_v, zb2, OP_EQ, 0);
                        emit(IR_BRANCH, -1, ib2, bare_lbl, boxed_lbl, 0);
                        emit(IR_LABEL, -1, bare_lbl, 0, 0, 0);
                        emit(IR_STORE, -1, fv, match_val, 0, 0);
                        emit(IR_JUMP, -1, end_lbl, 0, 0, 0);
                        emit(IR_LABEL, -1, boxed_lbl, 0, 0, 0);
                        emit(IR_LOAD_FIELD, fv, match_val, 0, fi + 1, 0);
                        emit(IR_LABEL, -1, end_lbl, 0, 0, 0);
                    }
                    spn := ast_b(arm_pat) + fi;
                    if spn >= 0 && ast_kind(spn) == EXPR_IDENT {
                        bind_local(ast_int_val(spn), fv);
                    }
                    fi = fi + 1;
                }
            }
            body_val := gen_expr(arm_body);
            body_val = force_if_thunk(body_val);
            if body_val >= 0 {
                emit(IR_STORE, -1, result_var, body_val, 0, 0);
                // 容量批 T2：结果槽表示位置位（同 LET/赋值的写点口径——解包点据此分派）
                if mrep_var >= 0 { emit_rep_set(mrep_var, rep_enc_of_expr(arm_body, body_val)); }
            }
            pop_ir_scope();
            emit(IR_JUMP, -1, merge_lbl, 0, 0, 0);
            if is_wildcard == 0 {
                if has_next == 1 {
                    emit(IR_LABEL, -1, fall_lbl, 0, 0, 0);
                }
            }
            an = ast_c(an);
        }
        emit(IR_LABEL, -1, merge_lbl, 0, 0, 0);
        return result_var;
    }

    // Let binding
    if ast_kind(node) == EXPR_LET {
        var_ni := ast_a(node);
        type_node := ast_b(node);
        val_node := ast_c(node);
        is_apx := ast_int_val(node);  // apx 标签位（parser 存入 iv 字段）
        // Detect dyn variable (type annotation is `dyn`)
        is_dyn_var : ., mut = 0;
        if type_node >= 0 && ast_kind(type_node) == 0 && ast_type_val(type_node) == TI_DYN {
            is_dyn_var = 1;
        }
        var := new_ir_var(istr_get(var_ni), TI_UNIT);
        declared_ti : ., mut = TI_UNIT;
        if type_node >= 0 { declared_ti = res_type_node(type_node); }
        // 容量批 T2：登记声明类型（元素写点判定目标元素类型用——声明的 `[T?;N]` 才是
        // 权威；字面量推出的元素类型对可选元素退化为对象占位 TI_UNIT）
        if g_optrep_on != 0 && type_node >= 0 { irv_set_decl_ti(var, declared_ti); }
        // 可选表示（R2 P4 Task 5）：显式 `T?` 标注的槽配表示位（默认 1 = 装箱）。
        // 推断槽（无标注）在初值求值后按初值表示面补配（`v := g()` / `x := Some(1)`）。
        rep_var : ., mut = opt_rep_slot(declared_ti, istr_get(var_ni));
        if rep_var >= 0 { irv_set_rep(var, rep_var); }
        // `dex` is the source-level type; its IR slot has two forms. Only an
        // explicitly tagged `apx` declaration uses binary64 bits.
        target_ti : ., mut = declared_ti;
        // 批 5（opt-dex · R1）：`dex?` 声明的**规范槽形式 = scaled**（G1 裁决：装箱对象是聚合类
        // 载体、无形式位可挂；rep 位 1 比特承载不了 2 位信息）⇒ 槽型由**声明**给定。
        // 修复前：门 `declared_ti == TI_DEX` 对 `dex?`（TYP_OPTIONAL 行）不触发，槽型退化为
        // 「随值」（:2577-2579 的值型采纳）⇒ apx 源直接把 bits 存进槽（实测 ELF/interp 15）。
        dex_opt : ., mut = 0;
        if type_node >= 0 { dex_opt = dex_opt_type_node(type_node); }
        if declared_ti == TI_DEX {
            if is_apx != 0 { target_ti = TI_DEX; }
            else { target_ti = TI_DEX_S; }
            irv_set_type(var, target_ti);
        } else if dex_opt != 0 {
            target_ti = TI_DEX_S;
            irv_set_type(var, TI_DEX_S);
        }
        is_arr : ., mut = 0;
        if type_node >= 0 && val_node < 0 {
            if ast_kind(type_node) == 19 {
                sz := ast_int_val(type_node);
                if sz > 0 {
                    emit(IR_ALLOC_ARRAY, var, sz, 8, 0, 0); is_arr = 1;
                    // F1：记录数组类型（TYP_ARRAY extra=size）——直接索引越界
                    // 检查（arr_len_lit_of）依赖该长度信息。
                    irv_set_type(var, res_type_node(type_node));
                }
            }
        }
        // For dyn vars with initializer: skip allocation (value is packed below)
        if is_dyn_var == 0 || val_node < 0 {
            if is_arr == 0 { emit(IR_ALLOC, var, 0, 0, 0, TI_UNIT); }
        }
        if val_node >= 0 {
            val_var := gen_expr(val_node);
            val_var = force_if_thunk(val_var);
            // 可选表示：推断槽按初值表示面补配表示位（有表示位可拷贝 / Some/None 构造 /
            // 未覆盖面回落值——回落配位无害：默认 1 = 装箱 = 既有语义）
            if rep_var < 0 && g_optrep_on != 0 && rep_enc_of_expr(val_node, val_var) != oe_bare() {
                rep_var = new_ir_var(istr_get(var_ni) + "_rep", TI_INT);
                irv_set_rep(var, rep_var);
            }
            // An `apx` dex local stores binary64 bits, unlike the default
            // scaled-integer dex form. The annotation alone is not enough:
            // switch the slot type and convert the initializer before later
            // binary operations inspect its type.
            if declared_ti == TI_DEX {
                val_var = dex_store_adjust(var, val_var, val_node);
            } else if dex_opt != 0 {
                // 批 5（opt-dex · R1）：`dex?` 初值入箱/入槽前先归规范形式（bits → scaled）。
                // 后续所有写点（赋值 / 指针写 / 聚合 / 装箱）都是「目标槽型驱动」⇒ 槽型定为
                // TI_DEX_S 后既有的 dex_store_adjust 路径自动生效（无需逐点补接线）。
                val_var = dex_slot_norm(val_var);
            } else if declared_ti == TI_UNIT {
                target_ti = irv_type(val_var);
                irv_set_type(var, target_ti);
            }
            if is_dyn_var != 0 {
                // Dyn variable: pack value with its type tag
                dyn_var := new_ir_var("_dyn", TI_DYN);
                tag := irv_type(val_var);
                if tag < 0 { tag = TI_INT; }
                emit(IR_DYN_PACK, dyn_var, val_var, tag, 0, 0);
                bind_local(var_ni, dyn_var);
                if is_apx != 0 { emit(IR_APPROX, -1, 0, 0, 0, 0); }
                return dyn_var;
            }
             // Preserve the initializer type so later operations can select
             // type-specific lowering (notably string + -> concat()).
             // 批 5（opt-dex · R1）：`dex?` 槽**不**采纳值型（槽型由声明给定 TI_DEX_S）——
             // 否则 `x : dex? = Some(...)`（值 = 箱对象 TI_INT）会把槽型改回 TI_INT，
             // 令「裸载荷 = scaled」这一规范面在下游再次丢失。
              if declared_ti != TI_DEX && dex_opt == 0 {
                  irv_set_type(var, irv_type(val_var));
              }
            // F11：切片长度沿 LET 初始化传播（s := arr[0..2] → s 带长度 2；
            // 运行时界 slice 同步长度变量——slice_len_copy_to）
            slice_len_copy_to(var, val_var);
            // (A) T3（裁-T3-1）：**推断**声明（无注解）但值面已判可选聚合 ⇒ 声明面继承到
            // **绑定 var**（字面量/切片站点登记在**值 var** 上；元素写点的目标是绑定 var）
            if g_optrep_on != 0 && type_node < 0 {
                vd := irv_decl_ti(val_var);
                if vd >= 0 { irv_set_decl_ti(var, vd); }
            }
            // (A) 批（INV-1）：**取址槽恒装箱**——该槽地址被取过 ⇒ 写点装箱 + 表示位钉 1
            //（指针写/直接写两路的表示必须一致；解包侧恒走装箱分支）
            forced := g_optrep_on != 0 && rep_var >= 0 && addr_taken_of(var_ni) != 0;
            if forced != 0 { val_var = box_for_slot_flag(val_node, val_var, 1); }
            emit(IR_STORE, -1, var, val_var, 0, 0);
            // 可选表示：写点置位（静态已知常量 / 源表示位拷贝）——解包点据此分派
            if rep_var >= 0 {
                if forced != 0 { emit_rep_set(rep_var, oe_boxed()); }
                else { emit_rep_set(rep_var, rep_enc_of_expr(val_node, val_var)); }
            }
        }
        bind_local(var_ni, var);
        if is_apx != 0 { emit(IR_APPROX, -1, 0, 0, 0, 0); }
        return var;
    }

    // Return
    if ast_kind(node) == EXPR_YIELD {
        val_node := ast_a(node);
        val_var : ., mut = -1;
        if val_node >= 0 { val_var = gen_expr(val_node); val_var = force_if_thunk(val_var); }
        emit(IR_YIELD, -1, val_var, 0, 0, 0);
        return -1;  // yield suspends — no return value for caller
    }

    if ast_kind(node) == EXPR_AWAIT {
        val_node := ast_a(node);
        val_var := gen_expr(val_node);
        val_var = force_if_thunk(val_var);
        dest := new_ir_var("await", TI_UNIT);
        emit(IR_AWAIT, dest, val_var, 0, 0, 0);
        return dest;
    }

    if ast_kind(node) == EXPR_RETURN {
        if ast_a(node) >= 0 {
            val_node := ast_a(node);
            val_var := gen_expr(val_node);
            val_var = force_if_thunk(val_var);
            // dex 边界规则（数值迁移 Task 4）：函数返回一律精确形式（缩放整数）——
            // apx 位模式在返回点转 scaled（F2I(bits×S)，按定点 6 位舍入）
            // 批 5（opt-dex · R3）：`-> dex?` 的 `g_cur_ret_ti` 亦为 0（`unpack_type` 塌陷）
            // ⇒ 追加**返回类型节点**判据（`g_cur_ret_dex_opt`，由 ir_gen_func 设置）——
            // 否则 apx 源经 `-> dex?` 返回时不转换（实测 ELF/interp 双路径 15）。
            if (g_cur_ret_ti == TI_DEX || g_cur_ret_dex_opt != 0) && irv_type(val_var) == TI_DEX {
                val_var = dex_bits_to_scaled(val_var);
            }
            // 可选表示（R2 P4 Task 5）：返回点写返回信道——值求值**完成后**、IR_RETURN
            // 紧邻处（其间无调用 ⇒ 嵌套调用不覆写信道；调用点紧跟 IR_CALL 读）。
            if g_cur_ret_opt != 0 {
                emit_rep_set(g_optrep_ret_cell, rep_enc_of_expr(val_node, val_var));
            }
            emit(IR_RETURN, -1, val_var, 0, 0, 0);
        } else {
            emit(IR_RETURN, -1, -1, 0, 0, 0);
        }
        return -1;
    }

    // Field access
    if ast_kind(node) == EXPR_FIELD {
        obj_var := gen_expr(ast_a(node));
        obj_var = force_if_thunk(obj_var);
        v := new_ir_var("field", TI_INT);
        fi : ., mut = ast_type_val(node);
        if fi > 0 {
            fi = fi - 1;  // numeric tuple index (parser stored +1)
        } else {
            fi = ast_data(node);   // struct field index (from checker)
        }
        // TODO #2026-09-16-16 批 2：读点定型取**声明面形式**（dex 声明 ⇒ TI_DEX_S）——零 alloc 节点判，
        // 非 dex 形态恒 TI_INT ⇒ 零足迹。**必须在 fi 解出之后**（字段位序）。
        irv_set_type(v, agg_field_read_form(node, fi));
        emit(IR_LOAD_FIELD, v, obj_var, 0, fi, 0);
        return v;
    }

    // Index
    if ast_kind(node) == EXPR_INDEX {
        arr_var := gen_expr(ast_a(node));
        arr_var = force_if_thunk(arr_var);
        idx_node := ast_b(node);
        idx_kind := ast_kind(idx_node);
        arr_len_lit : ., mut = arr_len_lit_of(arr_var);
        // Range index: arr[low..high] → slice (pointer to arr[low])
        if idx_kind == EXPR_RANGE {
            low_node := ast_a(idx_node);
            high_node := ast_b(idx_node);
            low_var := gen_expr(low_node);
            low_var = force_if_thunk(low_var);
            high_var := gen_expr(high_node);
            high_var = force_if_thunk(high_var);
            // F11：创建期守卫——high ≤ arr_len、low ≤ arr_len（low ≤ high 的
            // 运行时检查需切片运行时长度，见报告设计缺口；字面量界由 checker 拦截）。
            if arr_len_lit > 0 {
                if ast_kind(low_node) == EXPR_INT {
                    if ast_int_val(low_node) < 0 || ast_int_val(low_node) > arr_len_lit {
                        emit(IR_BOUNDS_CHECK, -1, low_var, arr_len_lit + 1, 0, 0);
                    }
                } else {
                    emit(IR_BOUNDS_CHECK, -1, low_var, arr_len_lit + 1, 0, 0);
                }
                if ast_kind(high_node) == EXPR_INT {
                    if ast_int_val(high_node) < 0 || ast_int_val(high_node) > arr_len_lit {
                        emit(IR_BOUNDS_CHECK, -1, high_var, arr_len_lit + 1, 0, 0);
                    }
                } else {
                    emit(IR_BOUNDS_CHECK, -1, high_var, arr_len_lit + 1, 0, 0);
                }
            }
            v := new_ir_var("slice", TI_INT);
            emit(IR_SLICE, v, arr_var, low_var, high_var, 0);
            // (A) T3（裁-T3-1）：源数组元素**可选** ⇒ 切片登记声明面（切片元素写点据此装箱；
            // 非可选不登记 ⇒ 零足迹。切片 var 的 IR 型面不动——避免影响 dtype/宽度等消费者）
            if g_optrep_on != 0 {
                sti := elem_ti_of(arr_var);
                if ti_is_optional(sti) != 0 { irv_set_decl_ti(v, alloc_type(TYP_SLICE, sti, 0)); }
            }
            // F11：字面量界 → 登记切片编译期长度（解引用处 arr_len_lit 用）；
            // 运行时界 → 计算 len = high − low 并登记长度变量（解引用处发射
            // 动态边界检查——见 emit_slice_*_bounds）。
            if ast_kind(low_node) == EXPR_INT && ast_kind(high_node) == EXPR_INT {
                sl := ast_int_val(high_node) - ast_int_val(low_node);
                if sl >= 0 { slice_len_set(v, sl); }
            } else {
                len_var := new_ir_var("slice_len", TI_INT);
                emit(IR_BINARY, len_var, high_var, low_var, OP_SUB, TI_INT);
                slice_len_var_set(v, len_var);
            }
            return v;
        }
        v := new_ir_var("elem", TI_INT);
        // TODO #2026-09-16-16 批 2：元素读定型取**声明面形式**（元素 ti 为 dex ⇒ TI_DEX_S；纯表读）
        irv_set_type(v, agg_elem_read_form(arr_var));
        if idx_kind == EXPR_INT {
            emit_string_lit_bounds(arr_var, ast_int_val(idx_node));
            emit_slice_lit_bounds(arr_var, ast_int_val(idx_node));
            if pass_before_array_access(arr_var, -1, ast_int_val(idx_node), arr_len_lit) == 0 {
                emit(IR_LOAD_INDEX, v, arr_var, 0, ast_int_val(idx_node), 0);
            }
        } else {
            idx_var := gen_expr(idx_node);
            idx_var = force_if_thunk(idx_var);
            emit_string_bounds(arr_var, idx_var);
            emit_slice_bounds(arr_var, idx_var);
            if pass_before_array_access(arr_var, idx_var, -1, arr_len_lit) == 0 {
                emit(IR_LOAD_INDEX_VAR, v, arr_var, idx_var, 0, 0);
            }
        }
        return v;
    }

    // Enum constructor
    if ast_kind(node) == EXPR_ENUM_CONSTRUCTOR {
        name_idx := ast_a(node);
        s := new_ir_var("enum", TI_UNIT);
        emit(IR_MAKE_ENUM, s, name_idx, ast_c(node), 0, 0);
        ai : ., mut = 0;
        an : ., mut = ast_b(node);  // EXPR_ARG chain
        loop {
            if an < 0 { break; }
            val_var := gen_expr(ast_a(an));
            val_var = force_if_thunk(val_var);
            // 容量批 T2：可选载荷写点规范化（载荷类型 = 变体声明面；`Some`/`None` 关键字
            // 形不带变体行 ⇒ enum_payload_ti 返回 -1 ⇒ 原样，不装箱）
            // 批 5（opt-dex · R2 序修正）：先归形式、后装箱（同上——反序 = 漏斗空转）
            val_var = dex_slot_norm(val_var);   // apx 批 T3：载荷槽恒精确
            if g_optrep_on != 0 { val_var = box_for_optional_slot(ast_a(an), val_var, enum_payload_ti(name_idx, ai)); }
            emit(IR_STORE_FIELD, -1, s, val_var, ai + 1, 0);  // +1 for tag offset
            an = ast_b(an);
            ai = ai + 1;
        }
        return s;
    }

    // Struct literal
    if ast_kind(node) == EXPR_STRUCT {
        // F5 契约（见 parser.cr struct 分支）：a=name idx、b=首 wrapper（连续）、c=字段数；
        // wrapper.a=字段值节点（gen_expr 对 EXPR_NONE 前向）。逐 wrapper 解引用，不得按偏移
        // 直取相邻节点当字段值——复合字段值子树占多槽会错位（静默错误值）。
        // TODO #2026-09-11-11 ①（名字绑定）：wrapper.b=字段名 idx（parser 写入；-1 = 无名字信息 → 位序
        // 回落）。**存字段位按名字解出**（与 Python bootstrap 的 gen_struct_lit 同语义）——
        // 修复前按 wrapper 序直取 fi = 声明位序绑定 ⇒ P{b:11, a:22} 静默得 a=11。发出顺序
        // 仍是**源序**（求值顺序 = 源码书写顺序，与 bootstrap 一致）。
        name_ni := ast_a(node);
        s := new_ir_var("struct", TI_UNIT);
        emit(IR_ALLOC_STRUCT, s, 0, 0, name_ni, 0);
        si := find_struct_by_name(name_ni);
        fi : ., mut = 0;
        fn2 : ., mut = ast_b(node);
        loop {
            if fi >= ast_c(node) { break; }
            if fn2 >= 0 {
                // fn2 = wrapper node (kind=EXPR_NONE, a=value expr, b=field name idx)
                val_var := gen_expr(fn2);
                val_var = force_if_thunk(val_var);
                field_idx : ., mut = fi;
                nn := ast_b(fn2);
                if si >= 0 && nn >= 0 {
                    jdi := struct_field_index_by_name(si, nn);
                    if jdi >= 0 { field_idx = jdi; }
                }
                // 容量批 T2：可选字段写点规范化（字面量形；元素值节点 = wrapper.a）
                // 批 5（opt-dex · R2 序修正）：先归形式、后装箱（同上）
                val_var = dex_slot_norm(val_var);   // apx 批 T3：字段槽恒精确
                if g_optrep_on != 0 { val_var = box_for_optional_slot(ast_a(fn2), val_var, struct_row_field_ti(si, field_idx)); }
                emit(IR_STORE_FIELD, -1, s, val_var, field_idx, 0);
                fn2 = fn2 + 1;
            }
            fi = fi + 1;
        }
        return s;
    }

    // Array literal
    if ast_kind(node) == EXPR_ARRAY {
        // F5 契约（见 parser.cr 下标分支）：a=首 wrapper（连续）、b=元素个数；wrapper.a=元素值
        // 节点（gen_expr 对 EXPR_NONE 前向）。逐 wrapper 解引用，不得按偏移直取相邻节点。
        v := new_ir_var("arr", TI_UNIT);
        emit(IR_ALLOC_ARRAY, v, ast_b(node), 0, 0, 0);
        elem_ti : ., mut = TI_INT;
        // (A) T3（裁-T3-1）：**数组级元素可选性预扫**——元素序在后的 Some/None 也必须影响
        // 在前的裸元素（`[2, Some(1)]`）⇒ 装箱判定不能只按逐元素形态。
        elem_opt_ti : ., mut = -1;
        if g_optrep_on != 0 {
            pn : ., mut = ast_a(node);
            pi : ., mut = 0;
            loop {
                if pi >= ast_b(node) { break; }
                if pn >= 0 {
                    pet := elem_ti_of_node(ast_a(pn));
                    if pet >= 0 { elem_opt_ti = pet; }
                }
                pn = pn + 1;   // wrapper 连续（F5 契约）
                pi = pi + 1;
            }
        }
        ei : ., mut = 0;
        en : ., mut = ast_a(node);
        loop {
            if ei >= ast_b(node) { break; }
            if en >= 0 {
                e_var := gen_expr(en);
                e_var = force_if_thunk(e_var);
                if ei == 0 { elem_ti = irv_type(e_var); }   // 先取原元素类型（装箱前）
                // 容量批 T2：可选元素写点规范化（字面量形；元素槽无声明面 ⇒ 按元素
                // 表达式可选性保守判定——ident/调用覆盖面，其余形态登记）。
                // 注意：数组字面量的 en 是 **wrapper** 节点（值在 ast_a）——须解引用后判定。
                // (A) T3：数组级可选（预扫得）⇒ 逐元素判定亦须为真（裸元素装箱）。
                // 批 5（opt-dex · R2 序修正）：先归形式、后装箱（同上）
                e_var = dex_slot_norm(e_var);   // apx 批 T3：元素槽恒精确
                if g_optrep_on != 0 {
                    eo := elem_node_optional(ast_a(en));
                    if elem_opt_ti >= 0 { eo = 1; }
                    e_var = box_for_slot_flag(ast_a(en), e_var, eo);
                }
                emit(IR_STORE_INDEX, -1, v, e_var, ei, 0);
                en = en + 1;
            }
            ei = ei + 1;
        }
        irv_set_type(v, alloc_type(TYP_ARRAY, elem_ti, ast_b(node)));
        // (A) T3（裁-T3-1）：**可选元素数组 ⇒ 登记声明面**（元素写点 `elem_ti_of` 据此装箱；
        // 非可选不登记 ⇒ 与既有语料/非可选程序零足迹）。IR 型面不动（只登记声明面）。
        if g_optrep_on != 0 && elem_opt_ti >= 0 {
            irv_set_decl_ti(v, alloc_type(TYP_ARRAY, elem_opt_ti, ast_b(node)));
        }
        return v;
    }

    // Range expression (evaluates both ends, returns end)
    if ast_kind(node) == EXPR_RANGE {
        start_var := gen_expr(ast_a(node));
        start_var = force_if_thunk(start_var);
        end_var := gen_expr(ast_b(node));
        end_var = force_if_thunk(end_var);
        return end_var;
    }

    // Break / Continue
    if ast_kind(node) == EXPR_BREAK {
        if g_ir_loop_depth > 0 {
            emit(IR_JUMP, -1, r64(g_ir_loop_exit, (g_ir_loop_depth - 1) * 8), 0, 0, 0);
        }
        return -1;
    }
    if ast_kind(node) == EXPR_CONTINUE {
        if g_ir_loop_depth > 0 {
            emit(IR_JUMP, -1, r64(g_ir_loop_header, (g_ir_loop_depth - 1) * 8), 0, 0, 0);
        }
        return -1;
    }

    if ast_kind(node) == EXPR_WILDCARD { return -1; }
    if ast_kind(node) == EXPR_ENUMPAT { return -1; }
    if ast_kind(node) == EXPR_MOVE {
        return gen_expr(ast_a(node));
    }
    if ast_kind(node) == EXPR_UNSAFE {
        sg_alloc_push(SG_UNSAFE);
        arena_var := new_ir_var("_arena", TI_INT);
        w64(g_sg_arena_var, (g_sg_count - 1) * 8, arena_var);
        emit(IR_ARENA_NEW, arena_var, 0, 0, 0, 0);
        arena_instr := g_ir_instr_count - 1;
        ret := gen_expr(ast_a(node));
        total := r64(g_sg_alloc_total, g_sg_count - 1);
        if total > 0 { iri_set_s1(arena_instr, total); }
        sg_alloc_pop();
        return ret;
    }
    if ast_kind(node) == EXPR_AS {
        inner_var := gen_expr(ast_a(node));
        inner_var = force_if_thunk(inner_var);
        target_ti := ti_from_type_expr(ast_b(node));
        if get_type_kind(target_ti) == TYP_PTR {
            source_ti := irv_type(inner_var);
            source_kind := get_type_kind(source_ti);
            asp : ., mut = 1;
            if source_kind == TYP_PTR {
                asp = get_type_extra(source_ti);
            } else if source_kind == TYP_REF || is_byte_buf_var(inner_var) != 0 {
                asp = 0;
            }
            target_ti = alloc_type(TYP_PTR, get_type_data(target_ti), asp);
        }
        cast_var := new_ir_var("_cast", target_ti);
        emit(IR_LOAD, cast_var, inner_var, 0, 0, target_ti);
        return cast_var;
    }
    if ast_kind(node) == EXPR_TRY {
        // R2 P4 Task 5：`?` 解包 = 解包点之一 ⇒ 同规则判表示：裸值（0）→ 槽值即载荷
        // （直取）；装箱（≠0）→ 字段 1（tag 之后）。无表示位（未覆盖面/非可选）→ 既有
        // 行为**逐字不变**（原样返回内层表达式值）。
        inner := gen_expr(ast_a(node));
        if g_optrep_on != 0 && inner >= 0 {
            rv := irv_rep(inner);
            if rv >= 0 {
                dest := new_ir_var("tryv", irv_type(inner));
                bl := new_label();
                xl := new_label();
                xend := new_label();
                zb := new_ir_var("_rz", TI_INT);
                emit(IR_CONST, zb, 0, 0, 0, TI_INT);
                ib := new_ir_var("rep_isbare", TI_INT);
                emit(IR_BINARY, ib, rv, zb, OP_EQ, 0);
                emit(IR_BRANCH, -1, ib, bl, xl, 0);
                emit(IR_LABEL, -1, bl, 0, 0, 0);
                emit(IR_STORE, -1, dest, inner, 0, 0);
                emit(IR_JUMP, -1, xend, 0, 0, 0);
                emit(IR_LABEL, -1, xl, 0, 0, 0);
                emit(IR_LOAD_FIELD, dest, inner, 0, 1, 0);
                emit(IR_LABEL, -1, xend, 0, 0, 0);
                return dest;
            }
        }
        return inner;
    }
    if ast_kind(node) == EXPR_STRUCTPAT {
        return -1;
    }
    if ast_kind(node) == EXPR_STMT {
        gen_expr(ast_a(node));
        return -1;
    }
    if ast_kind(node) == EXPR_TUPLE {
        // Tuple: allocate array for N elements, store each
        // F5 契约：a=首 wrapper（g_ast 中连续）、b=元素个数；wrapper.a = 元素值节点
        // （复合元素值节点不连续，须经 wrapper 解引用——见 checker.cr EXPR_TUPLE 注）。
        elem_idx := ast_a(node);
        ec : ., mut = ast_b(node);
        tv := new_ir_var("tuple", TI_INT);
        emit(IR_ALLOC_ARRAY, tv, ec, 0, 8, 0);  // alloc N * 8 bytes
        // Store each element at its offset
        e : ., mut = 0;
        loop {
            if e >= ec { break; }
            en : ., mut = -1;
            if elem_idx >= 0 { en = ast_a(elem_idx + e); }
            elem_var := gen_expr(en);
            elem_var = force_if_thunk(elem_var);
            // 容量批 T2：可选元素写点规范化（元组元素槽无声明面 ⇒ 按元素表达式可选性
            // 保守判定；ident/调用覆盖面，其余形态登记）
            if g_optrep_on != 0 { elem_var = box_for_slot_flag(en, elem_var, elem_node_optional(en)); }
            elem_var = dex_slot_norm(elem_var);   // apx 批 T3：元组元素槽恒精确
            emit(IR_STORE_FIELD, -1, tv, elem_var, e, 0);
            e = e + 1;
        }
        return tv;
    }

    return -1;
}

// --- Generate IR for one function ---

fn ir_gen_func(fi: int) {
    // Skip generic functions — they will be monomorphized at call sites
    if fi_generic_count(fi) > 0 { return; }
    fn_node := fi_ast_node(fi);
    name_idx := ast_a(fn_node);
    first_param := ast_b(fn_node);
    param_count := ast_c(fn_node);
    // 返回类型：从 FuncInfo 取原始 TY_* 常量（ast_type_val(fn_node) 是返回类型
    // 节点下标而非类型常量——错读会使 g_cur_ret_ti 不等于 TI_DEX，apx 返回点
    // bits→scaled 转换失效，仅在 dex 类型节点下标恰为 1 时碰巧生效）
    ret_ti := fi_return_type(fi);
    body := ast_data(fn_node);

    // Record function metadata
    func_idx := g_ir_func_count;
    grow_ir_func_meta(func_idx + 1);
    w64(g_ir_func_name_idx, func_idx * 8, name_idx);
    w64(g_ir_func_ret_type, func_idx * 8, ret_ti);
    w64(g_ir_func_instr_start, func_idx * 8, g_ir_instr_count);
    w64(g_ir_func_var_start, func_idx * 8, g_ir_var_count);
    w64(g_ir_func_param_count, func_idx * 8, param_count);

    // Create IR vars for params
    pi : ., mut = 0;
    pn : ., mut = first_param;
    loop {
        if pi >= param_count { break; }
        if pn < 0 { break; }
        pname_idx := ast_a(pn);
        pname := istr_get(pname_idx);
        param_type : ., mut = ast_type_val(pn);
        if param_type < 0 { param_type = TI_INT; }
        // dex 边界规则（数值迁移 Task 4）：参数一律精确形式（缩放整数，整数寄存器传递）
        if param_type == TI_DEX { param_type = TI_DEX_S; }
        // 批 5（opt-dex · R3）：`dex?` 形参槽型 —— 修复前 `unpack_type(EXPR_OPTIONAL)` 返 0
        // （parser.cr:150-153）⇒ `EXPR_PARAM.type_val` = 0 = `TI_INT` ⇒ 槽型按 int 建、
        // 而调用点按实参 var 的 `TI_DEX` 分类为 binary64（XMM）⇒ **ABI 失配**（按 XMM 传、
        // 按 GP 读 = 垃圾值 + 双路径分歧）。槽型按**声明面节点**定 = `TI_DEX_S`（GP 类，
        // 与调用点转换后的实参一致）。
        else if dex_opt_type_node(ast_data(pn)) != 0 { param_type = TI_DEX_S; }
        pvar := new_ir_var(pname, param_type);
        // Bind param name
        bind_local(pname_idx, pvar);
        // 可选表示（R2 P4 Task 5）：形参表示位——**序言最早处**从实参信道读（先于任何
        // 可能改写信道的调用；调用点在 IR_CALL 前写）。形参类型节点 = EXPR_PARAM.data。
        ptn := ast_data(pn);
        // 容量批 T2：形参声明类型登记（元素写点判定用；与表示位面互不干扰）
        if g_optrep_on != 0 && ptn >= 0 { irv_set_decl_ti(pvar, res_type_node(ptn)); }
        if g_optrep_on != 0 && g_optrep_arg_count > 0 && ptn >= 0 && pi < g_optrep_arg_count {
            pti := res_type_node(ptn);
            if pti >= 0 && get_type_kind(pti) == TYP_OPTIONAL {
                prv := new_ir_var(pname + "_prep", TI_INT);
                emit(IR_LOAD, prv, g_optrep_arg_cell0 + pi, 0, 0, TI_INT);
                irv_set_rep(pvar, prv);
                // (A) 批（INV-1）：**取址形参**恒装箱——序言内条件装箱（信道 rep = 0 裸值 ⇒ 装箱）
                // 并把表示位钉 1（后续含指针写在内的一切写点都由 W3/W2 保持该不变量）
                if addr_taken_of(pname_idx) != 0 {
                    zb := new_ir_var("_rz", TI_INT);
                    emit(IR_CONST, zb, 0, 0, 0, TI_INT);
                    isb := new_ir_var("prep_isbare", TI_INT);
                    emit(IR_BINARY, isb, prv, zb, OP_EQ, 0);
                    bare_lbl := new_label();
                    end_lbl := new_label();
                    emit(IR_BRANCH, -1, isb, bare_lbl, end_lbl, 0);
                    emit(IR_LABEL, -1, bare_lbl, 0, 0, 0);
                    boxed := emit_box_some(pvar);
                    emit(IR_STORE, -1, pvar, boxed, 0, 0);
                    one := new_ir_var("prep_one", TI_INT);
                    emit(IR_CONST, one, 1, 0, 0, TI_INT);
                    emit(IR_STORE, -1, prv, one, 0, 0);
                    emit(IR_LABEL, -1, end_lbl, 0, 0, 0);
                }
            }
        }
        pi = pi + 1;
        // Scan past type nodes to next EXPR_PARAM
        pn = pn + 1;
        loop {
            if pn >= g_ast_count { break; }
            if ast_kind(pn) == EXPR_PARAM { break; }
            pn = pn + 1;
        }
    }

    // Function-level arena (df_begin_func already pushed SG_FUNC)
    grow_sg_alloc(g_sg_count + 1);
    grow_sg_arena_var(g_sg_count + 1);
    w64(g_sg_alloc_total, (g_sg_count - 1) * 8, 0);
    arena_var := new_ir_var("_arena", TI_INT);
    w64(g_sg_arena_var, (g_sg_count - 1) * 8, arena_var);
    emit(IR_ARENA_NEW, arena_var, 0, 0, 0, 0);
    arena_instr := g_ir_instr_count - 1;

    // 程序启动期全局初始化（2026-09-10 R1 ②）：只在 main 序言注入——run 与 build
    // 两路径都从 main 进入（interp.cr 按名查找 main；ELF _start call main），因此
    // 无需新 IR 函数/新 .ccr 段/新 _start 指令 = 无序列化与字节布局扰动。
    // 无需运行期初始化的程序不发射任何指令（零变化）。
    if str_eq(istr_get(name_idx), "main") != 0 { inject_global_inits(); }

    // Generate body（记录返回 TI——EXPR_RETURN 的 dex 边界转换用）
    g_cur_ret_ti = ret_ti;
    // 批 5（opt-dex · R3）：返回类型节点是否 `dex?`（节点级零 alloc）。`-> dex?` 的
    // `ret_ti`（= `fi_return_type` 裸码）与 `type_val` 均为 0（`unpack_type(EXPR_OPTIONAL)`）
    // ⇒ 返回点 dex 转换门 `g_cur_ret_ti == TI_DEX` 恒假 ⇒ 需本标志补位。
    g_cur_ret_dex_opt = 0;
    rtn_d := ast_type_val(fn_node);
    if rtn_d >= 0 && dex_opt_type_node(rtn_d) != 0 { g_cur_ret_dex_opt = 1; }
    // 可选表示（R2 P4 Task 5）：本函数返回可选时，返回点写返回信道（见 EXPR_RETURN）。
    // 判据走**返回类型节点**（ast_type_val(fn_node) = 返回类型节点下标——见上方 ret_ti
    // 注释）而非 fi_return_type 裸码（`T?` 的类型节点 type_val = 0 ⇒ 恒判否）。
    g_cur_ret_opt = 0;
    if g_optrep_on != 0 && g_optrep_ret_cell >= 0 {
        rtn := ast_type_val(fn_node);
        if rtn >= 0 {
            rti := res_type_node(rtn);
            if rti >= 0 && rti < g_type_count && get_type_kind(rti) == TYP_OPTIONAL { g_cur_ret_opt = 1; }
        }
    }
    if body >= 0 {
        gen_expr(body);
    }
    g_cur_ret_ti = -1;
    g_cur_ret_opt = 0;
    g_cur_ret_dex_opt = 0;

    // Patch arena size and reset before return
    total := r64(g_sg_alloc_total, (g_sg_count - 1) * 8);
    if total > 0 { iri_set_s1(arena_instr, total); }
    emit(IR_ARENA_RESET, -1, arena_var, 0, 0, 0);

    // Add return at end if not already terminated（可达 = 兜底 return；不可达 = 死码，
    // 两后端同语义不执行）。可选返回点写装箱默认值（与 ABI 返回寄存器的未定义值同档）。
    if g_cur_ret_opt != 0 { emit_rep_set(g_optrep_ret_cell, oe_boxed()); }
    emit(IR_RETURN, -1, -1, 0, 0, 0);

    w64(g_ir_func_instr_count, func_idx * 8, g_ir_instr_count - r64(g_ir_func_instr_start, func_idx * 8));
    w64(g_ir_func_var_count, func_idx * 8, g_ir_var_count - r64(g_ir_func_var_start, func_idx * 8));
    g_ir_func_count = func_idx + 1;
}

// --- Initialize global IR vars from global lets ---

// Extract the compile-time constant initializer of a file-scope let
// (0 = none/not constant — BSS is zero-initialized anyway).
// NB: applies to mutable AND immutable lets (mut/const init values both
// need to be written at startup — unlike find_global_const_node which
// only folds immutable constants at compile time).
fn global_init_val(name_idx: int) -> int {
    i : ., mut = g_global_let_count - 1;
    loop {
        if i < 0 { break; }
        node := r64(g_global_lets, i * 8);
        if ast_a(node) == name_idx {
            value_node := ast_c(node);
            if value_node >= 0 {
                vk := ast_kind(value_node);
                if vk == EXPR_INT || vk == EXPR_BOOL {
                    return ast_int_val(value_node);
                }
                if vk == EXPR_DEX {
                    // dex 全局常量：定点缩放整数（精确形式初始值；apx 位模式由
                    // reg_one_global 从节点 a 取——见该函数）
                    return ast_int_val(value_node);
                }
                if vk == EXPR_UNARY && ast_c(value_node) == UOP_NEG {
                    inner := ast_a(value_node);
                    if ast_kind(inner) == EXPR_INT || ast_kind(inner) == EXPR_BOOL {
                        return 0 - ast_int_val(inner);
                    }
                    if ast_kind(inner) == EXPR_DEX {
                        return 0 - ast_int_val(inner);
                    }
                }
            }
        }
        i = i - 1;
    }
    return 0;
}

// 类型节点 → `[T; N]` 的元素数 N（`[T]` 切片 = 0）；非聚合 = -1。
// 类型别名解析一层：`type Arr = [int;2]; g : Arr;` 的声明类型节点是 EXPR_IDENT
// （parser.cr parse_type 的用户类型分支），须经 g_type_aliases（{name_idx, type_node}
// 16B/条）回到底层 EXPR_ARRAY——否则同一「定长数组全局」类仍留 SIGSEGV。
fn agg_elem_count_of(tn: int) -> int {
    if tn < 0 { return -1; }
    if ast_kind(tn) == EXPR_ARRAY { return ast_int_val(tn); }
    if ast_kind(tn) == EXPR_IDENT {
        ni := ast_int_val(tn);
        ai : ., mut = 0;
        loop {
            if ai >= g_type_alias_count { break; }
            if r64(g_type_aliases, ai * 16) == ni {
                rt := r64(g_type_aliases, ai * 16 + 8);
                if rt >= 0 && ast_kind(rt) == EXPR_ARRAY { return ast_int_val(rt); }
                break;
            }
            ai = ai + 1;
        }
    }
    return -1;
}

// 文件级 let 是否需要「运行期初始化」（2026-09-10 语言面收窄 §1.3 / R1 ②）。
// 判据（与 global_init_val 互补——它只认编译期标量常量，其余静默归 0）：
//   ① 声明类型是聚合（`[T; N]`/`[T]`，含类型别名一层解析）→ 必须运行期分配存储；
//   ② 初值存在且不是 int/bool/dex 字面量（含负号字面量）→ 必须运行期求值。
fn global_needs_runtime_init(name_idx: int) -> int {
    i : ., mut = g_global_let_count - 1;
    loop {
        if i < 0 { break; }
        node := r64(g_global_lets, i * 8);
        if ast_a(node) == name_idx {
            // 容量批 T2：可选全局槽**必须**走运行期初始化——静态度量（.quad 裸值）写进槽后
            // 读侧按装箱解引用 ⇒ 双路径 139（实测 e2_global_bare）。装箱在 inject_global_inits
            // 内完成；非可选全局不受影响（零足迹）。
            if g_optrep_on != 0 && ti_is_optional(global_decl_ti(name_idx)) != 0 { return 1; }
            if agg_elem_count_of(ast_b(node)) >= 0 { return 1; }
            vn := ast_c(node);
            if vn < 0 { return 0; }
            vk := ast_kind(vn);
            if vk == EXPR_INT || vk == EXPR_BOOL || vk == EXPR_DEX { return 0; }
            if vk == EXPR_UNARY && ast_c(vn) == UOP_NEG {
                inner := ast_a(vn);
                ik := ast_kind(inner);
                if ik == EXPR_INT || ik == EXPR_BOOL || ik == EXPR_DEX { return 0; }
            }
            return 1;
        }
        i = i - 1;
    }
    return 0;
}

// 按 name_idx 查已注册的全局 IR var（未注册 = -1）。
fn global_var_of(name_idx: int) -> int {
    gi : ., mut = 0;
    loop {
        if gi >= g_ir_global_count { break; }
        if r64(g_ir_globals, gi * 24) == name_idx { return r64(g_ir_globals, gi * 24 + 8); }
        gi = gi + 1;
    }
    return -1;
}

// 把需要运行期初始化的文件级 let 降级为 IR 序列（写进当前函数 = main 序言）。
// 顺序 = g_global_lets 源序（跨全局依赖如 `b : [int;2] = a;` 因此正确）。
fn inject_global_inits() {
    i : ., mut = 0;
    loop {
        if i >= g_global_let_count { break; }
        lnode := r64(g_global_lets, i * 8);
        name_idx := ast_a(lnode);
        if global_needs_runtime_init(name_idx) != 0 {
            gv := global_var_of(name_idx);
            if gv >= 0 {
                vn := ast_c(lnode);
                v : ., mut = -1;
                if vn >= 0 {
                    v = gen_expr(vn);
                    v = force_if_thunk(v);
                } else {
                    // 无初值聚合：整流分配（零初始化由 alloc 语义保证——rt.s 的 rep stosb；
                    // 解释器 IR_ALLOC_ARRAY 显式清零）。仅 `[T; N]`（N ≥ 1）注入；`[T]`
                    // （切片无长度，N = 0）不注入——保持 BSS 零 = 空切片/哑指针，
                    // 空切片解引用属独立 null 陷阱类，不在本批。
                    cnt := agg_elem_count_of(ast_b(lnode));
                    if cnt > 0 {
                        v = new_ir_var("ginit", TI_UNIT);
                        emit(IR_ALLOC_ARRAY, v, cnt, 0, 0, 0);
                        irv_set_type(v, alloc_type(TYP_ARRAY, TI_INT, cnt));
                    }
                }
                if v >= 0 {
                    // 容量批 T2：可选全局槽**初值**写点规范化（与赋值点 :1155 是两处独立
                    // 代码点——初值走 inject_global_inits，赋值走 EXPR_ASSIGN）
                    // 批 5（opt-dex · R2 序修正）：先归形式、后装箱（同上——反序 = 漏斗空转）
                    v = dex_store_adjust(gv, v, vn);   // apx 批 T3：全局初值按槽声明型（含 apx 全局）
                    if g_optrep_on != 0 { v = box_for_optional_slot(vn, v, global_decl_ti(name_idx)); }
                    emit(IR_STORE, -1, gv, v, 0, 0);
                }
            }
        }
        i = i + 1;
    }
}

// Register one IR global, deduplicated by name_idx.
fn reg_one_global(name_idx: int) {
    found : ., mut = 0;
    gi : ., mut = 0;
    loop { if gi >= g_ir_global_count { break; }
        if r64(g_ir_globals, gi * 24) == name_idx { found = 1; break; }
    gi = gi + 1; }
    if found == 0 {
        name := istr_get(name_idx);
        // dex 全局变量（数值迁移 Task 4）：精确（TI_DEX_S，缩放整数初始值）或
        // apx（TI_DEX，binary64 位模式初始值）——按声明 LET 的类型节点与 apx 位
        gtype : ., mut = TI_INT;
        is_dex_global : ., mut = 0;
        gli : ., mut = 0;
        loop {
            if gli >= g_global_let_count { break; }
            lnode := r64(g_global_lets, gli * 8);
            if ast_a(lnode) == name_idx {
                ltn := ast_b(lnode);
                if ltn >= 0 && ast_kind(ltn) == 0 && ast_type_val(ltn) == TY_DEX {
                    if ast_int_val(lnode) != 0 { gtype = TI_DEX; } else { gtype = TI_DEX_S; }
                    is_dex_global = 1;
                } else if ltn >= 0 && dex_opt_type_node(ltn) != 0 {
                    // 批 5（opt-dex · R1）：`dex?` 全局槽 = **规范形式 scaled**（G1 裁决）。
                    // 修复前本门只认基类型节点 `dex` ⇒ `dex?` 全局落 TI_INT 槽，
                    // 赋值/初值的 dex_store_adjust 因目标型不匹配而空转（实测 15）。
                    // is_dex_global 不置 1：其唯一消费者（:3320）只服务 apx 位模式全局。
                    gtype = TI_DEX_S;
                }
                break;
            }
            gli = gli + 1;
        }
        gvar := new_ir_var(name, gtype);
        grow_ir_globals(g_ir_global_count + 1);
        w64(g_ir_globals, g_ir_global_count * 24, name_idx);
        w64(g_ir_globals, g_ir_global_count * 24 + 8, gvar);
        // Const initializer — emitted by the ELF backend's _init_globals.
        iv : int = global_init_val(name_idx);
        if is_dex_global != 0 && gtype == TI_DEX {
            // apx 全局：初始值为 binary64 位模式（缩放值 → bits 从节点 a 取）
            i2 : ., mut = 0;
            loop {
                if i2 >= g_global_let_count { break; }
                lnode2 := r64(g_global_lets, i2 * 8);
                if ast_a(lnode2) == name_idx {
                    vn := ast_c(lnode2);
                    if vn >= 0 && ast_kind(vn) == EXPR_DEX { iv = ast_a(vn); }
                    break;
                }
                i2 = i2 + 1;
            }
        }
        w64(g_ir_globals, g_ir_global_count * 24 + 16, iv);
        g_ir_global_count = g_ir_global_count + 1;
    }
}

fn ir_gen_globals() {
    // The parser records only file-scope declarations in g_global_lets.
    // Do not scan every EXPR_LET here: that also includes function locals.
    i : ., mut = 0;
    loop {
        if i >= g_global_let_count { break; }
        node := r64(g_global_lets, i * 8);
        reg_one_global(ast_a(node));
        i = i + 1;
    }

    // Manually register ir_gen.cr's own globals — the parser's auto-detection
    // of file-scope declarations is known to miss some (see CLAUDE.md Known Issues).
    reg_one_global(str_intern("g_sg_alloc_total"));
    reg_one_global(str_intern("g_sg_alloc_cap"));
    reg_one_global(str_intern("g_sg_arena_var"));
    reg_one_global(str_intern("g_sg_arena_var_cap"));
    reg_one_global(str_intern("g_ir_source_hash"));
    reg_one_global(str_intern("g_ir_source_hash_ready"));
    reg_one_global(str_intern("g_cir_write_buf"));
    reg_one_global(str_intern("g_cir_write_pos"));
    reg_one_global(str_intern("g_cir_write_cap"));
    // Runtime globals needed by emit_alloc_body and emit_start.
    // These MUST exist in BSS for every program, even without rt.cr included.
    reg_one_global(str_intern("g_heap_ptr"));
    reg_one_global(str_intern("g_heap_end"));
    reg_one_global(str_intern("g_current_arena"));
    reg_one_global(str_intern("g_arena_cursors"));
    reg_one_global(str_intern("g_arena_sizes"));
    reg_one_global(str_intern("g_arena_parents"));
    reg_one_global(str_intern("g_arena_max_size"));
    reg_one_global(str_intern("g_arena_count"));
    reg_one_global(str_intern("g_arena_cap"));
    reg_one_global(str_intern("g_arena_pool_data"));
    reg_one_global(str_intern("g_arena_free_list"));
    reg_optrep_globals();
}

// 表示面初始化（**两条 IR 生成入口都必须先调**：ir_gen_all 批量路径 + main.cr 文件路径
// （逐函数 + .cir 缓存）——后者不经过本文件的批量入口，漏调即侧表未分配）。位置：
// **先于 ir_gen_globals**（隐藏信道的 var 行序 = 全局行序依赖）。
fn optrep_begin() {
    g_ir_var_rep = "";
    g_ir_var_rep_cap = 0;
    g_ir_var_decl_ti = "";
    g_ir_var_decl_cap = 0;
    g_optrep_ret_cell = -1;
    g_optrep_arg_cell0 = -1;
    g_optrep_arg_count = 0;
    g_cur_ret_opt = 0;
    optrep_prescan();
    optrep_addr_prescan();
}

// (A) 批（裁-REP-4）：**取址面预扫**——收集一切「取址 ident」的名字索引（照 optrep_prescan
// 先例；全 AST 一遍）。判据面 = `&ident`（`UOP_REF` 的 operand 为 `EXPR_IDENT`）；其余取址
// 形态见计划 §2.3 引理 1（`&arr[i]` = 聚合面已恒装箱；`&<其它表达式>` = 临时量非槽；函数地址
// 非槽；指针算术 = REP-2 边界；extern = 登记）。
fn grow_addr_taken(needed: int) {
    if needed <= g_addr_taken_cap { return; }
    nc := g_addr_taken_cap * 2; if nc < 32 { nc = 32; } if nc < needed { nc = needed + 32; }
    nb := alloc(nc * 8); _dyncpy(g_addr_taken_names, g_addr_taken_cap * 8, nb);
    g_addr_taken_names = nb; g_addr_taken_cap = nc;
}
fn addr_taken_add(ni: int) {
    if ni < 0 { return; }
    if addr_taken_of(ni) != 0 { return; }          // 去重（线性扫；量级 = 源码里 &ident 的条数）
    grow_addr_taken(g_addr_taken_count + 1);
    w64(g_addr_taken_names, g_addr_taken_count * 8, ni);
    g_addr_taken_count = g_addr_taken_count + 1;
}
fn addr_taken_of(ni: int) -> int {
    if ni < 0 { return 0; }
    i : ., mut = 0;
    loop {
        if i >= g_addr_taken_count { return 0; }
        if r64(g_addr_taken_names, i * 8) == ni { return 1; }
        i = i + 1;
    }
    return 0;
}
fn optrep_addr_prescan() {
    g_addr_taken_count = 0;
    i : ., mut = 0;
    loop {
        if i >= g_ast_count { break; }
        if ast_kind(i) == EXPR_UNARY && ast_c(i) == UOP_REF {
            opn := ast_a(i);
            if opn >= 0 && ast_kind(opn) == EXPR_IDENT {
                addr_taken_add(ast_int_val(opn));
            }
        }
        i = i + 1;
    }
}

// 表示面启用扫描（**零足迹门**）：AST 含任一 `T?` 类型节点（EXPR_OPTIONAL）或任一
// `Some`/`None` 构造（关键字名分派，与 checker 同规约：用户变体同名时上方 SYM_FN 优先，
// 但扫描**宽于**实际使用只会多启用一层空机器、不会漏启用——判据面为「启用 ⇒ 表示面完整」）。
fn optrep_prescan() {
    g_optrep_on = 0;
    i : ., mut = 0;
    loop {
        if i >= g_ast_count { break; }
        k := ast_kind(i);
        if k == EXPR_OPTIONAL { g_optrep_on = 1; break; }
        if k == EXPR_ENUM_CONSTRUCTOR {
            nm := istr_get(ast_a(i));
            if str_eq(nm, "Some") != 0 || str_eq(nm, "None") != 0 { g_optrep_on = 1; break; }
        }
        i = i + 1;
    }
}

// 隐藏全局注册（照 reg_one_global 形态但不查 g_global_lets——编译器内部名，零初值）。
// var_idx == 行序（save_ccr 的全局行序守卫）由「本函数只在 ir_gen_globals 尾部调用、
// 此后不再注册全局」保证。
fn reg_hidden_global(name_ni: int) -> int {
    gvar := new_ir_var(istr_get(name_ni), TI_INT);
    grow_ir_globals(g_ir_global_count + 1);
    w64(g_ir_globals, g_ir_global_count * 24, name_ni);
    w64(g_ir_globals, g_ir_global_count * 24 + 8, gvar);
    w64(g_ir_globals, g_ir_global_count * 24 + 16, 0);
    g_ir_global_count = g_ir_global_count + 1;
    return gvar;
}

// 可选表示的跨函数信道注册（仅在 g_optrep_on 时）：返回信道单元 + 每形参位一个实参
// 信道单元（连续 var 索引；被调按形参位读、调用点按实参位写）。
fn reg_optrep_globals() {
    g_optrep_ret_cell = -1;
    g_optrep_arg_cell0 = -1;
    g_optrep_arg_count = 0;
    if g_optrep_on == 0 { return; }
    maxp : ., mut = 0;
    fi2 : ., mut = 0;
    loop {
        if fi2 >= g_func_count { break; }
        pc := fi_param_count(fi2);
        if pc > maxp { maxp = pc; }
        fi2 = fi2 + 1;
    }
    if maxp > 64 { maxp = 64; }
    g_optrep_ret_cell = reg_hidden_global(str_intern("__optrep_ret"));
    j : ., mut = 0;
    loop {
        if j >= maxp { break; }
        cv := reg_hidden_global(str_intern("__optrep_arg" + int_str(j)));
        if j == 0 { g_optrep_arg_cell0 = cv; }
        j = j + 1;
    }
    g_optrep_arg_count = maxp;
}

// --- AST walk: patch method call names for monomorphization ---

fn ast_patch_node(node: int, subst_from: string, subst_to: string) {
    if node < 0 { return; }
    k := ast_kind(node);
    if k == EXPR_CALL {
        func_node := ast_a(node);
        if ast_kind(func_node) == EXPR_FIELD {
            data_ni := ast_data(node);
            if data_ni >= 0 {
                data_str := istr_get(data_ni);
                dlen := str_len(data_str);
                flen := str_len(subst_from);
                if dlen >= flen {
                    matches : ., mut = 1;
                    dci : ., mut = 0;
                    loop {
                        if dci >= flen { break; }
                        if load8(data_str, dci) != load8(subst_from, dci) { matches = 0; break; }
                        dci = dci + 1;
                    }
                    if matches != 0 && (dlen == flen || load8(data_str, flen) == 46) {
                        rest := str_sub(data_str, flen, dlen - flen);
                        new_name := subst_to + rest;
                        ast_set_data(node, str_intern(new_name));
                    }
                }
            }
        }
    }
    // Recurse into children based on node kind
    if k == EXPR_BLOCK {
        ss := ast_a(node); sc := ast_b(node);
        i2 : ., mut = 0;
        loop { if i2 >= sc { break; }
            sn2 := r64(g_block_stmts, (ss + i2) * 8);
            ast_patch_node(sn2, subst_from, subst_to);
            i2 = i2 + 1; }
    } else if k == EXPR_IF || k == EXPR_LOOP || k == EXPR_WHILE || k == EXPR_UNSAFE {
        if ast_a(node) >= 0 { ast_patch_node(ast_a(node), subst_from, subst_to); }
        if k == EXPR_IF {
            if ast_b(node) >= 0 { ast_patch_node(ast_b(node), subst_from, subst_to); }
            if ast_c(node) >= 0 { ast_patch_node(ast_c(node), subst_from, subst_to); }
        }
    } else if k == EXPR_BINARY || k == EXPR_ASSIGN || k == EXPR_RANGE || k == EXPR_AS {
        if ast_a(node) >= 0 { ast_patch_node(ast_a(node), subst_from, subst_to); }
        if ast_b(node) >= 0 { ast_patch_node(ast_b(node), subst_from, subst_to); }
    } else if k == EXPR_CALL || k == EXPR_ENUM_CONSTRUCTOR {
        if ast_a(node) >= 0 { ast_patch_node(ast_a(node), subst_from, subst_to); }
        an3 := ast_b(node); ac3 := ast_c(node);
        ai3 : ., mut = 0;
        loop { if ai3 >= ac3 { break; } if an3 >= 0 { ast_patch_node(an3, subst_from, subst_to); an3 = an3 + 1; } ai3 = ai3 + 1; }
    } else if k == EXPR_MATCH {
        if ast_a(node) >= 0 { ast_patch_node(ast_a(node), subst_from, subst_to); }
        an4 := ast_b(node);
        loop { if an4 < 0 { break; }
            if ast_a(an4) >= 0 { ast_patch_node(ast_a(an4), subst_from, subst_to); }
            if ast_b(an4) >= 0 { ast_patch_node(ast_b(an4), subst_from, subst_to); }
            an4 = ast_c(an4); }
    } else if k == EXPR_FOR {
        if ast_b(node) >= 0 { ast_patch_node(ast_b(node), subst_from, subst_to); }
        if ast_c(node) >= 0 { ast_patch_node(ast_c(node), subst_from, subst_to); }
    } else if k == EXPR_LET {
        if ast_c(node) >= 0 { ast_patch_node(ast_c(node), subst_from, subst_to); }
    } else if k == EXPR_STMT {
        if ast_a(node) >= 0 { ast_patch_node(ast_a(node), subst_from, subst_to); }
    } else if k == EXPR_STRUCT {
        // a=type_name_ni, b=first wrapper（连续）, c=field_count；wrapper.a=字段值节点
        // （F5 契约，见 parser.cr struct 字面量分支）——须解引用 wrapper 再递归，
        // 旧代码把 EXPR_NONE wrapper 本身交给 ast_patch_node（无该 kind 分支）= 空转，
        // 泛型实例体内 struct 字面量字段中的方法调用名得不到替换。
        an5 := ast_b(node); ac5 := ast_c(node);
        ai5 : ., mut = 0;
        loop {
            if ai5 >= ac5 { break; }
            if an5 >= 0 {
                vn5 : ., mut = -1;
                if ast_kind(an5) == EXPR_NONE { vn5 = ast_a(an5); }
                if vn5 >= 0 { ast_patch_node(vn5, subst_from, subst_to); }
                an5 = an5 + 1;
            }
            ai5 = ai5 + 1;
        }
    } else if k == EXPR_ARRAY {
        // a=first wrapper（连续）, b=elem_count；wrapper.a=元素值节点（F5 契约，见 parser.cr 下标分支）
        an6 := ast_a(node); ac6 := ast_b(node);
        ai6 : ., mut = 0;
        loop {
            if ai6 >= ac6 { break; }
            if an6 >= 0 {
                vn6 : ., mut = -1;
                if ast_kind(an6) == EXPR_NONE { vn6 = ast_a(an6); }
                if vn6 >= 0 { ast_patch_node(vn6, subst_from, subst_to); }
                an6 = an6 + 1;
            }
            ai6 = ai6 + 1;
        }
    } else if k == EXPR_TUPLE {
        // a=first wrapper（连续）, b=elem_count；wrapper.a=元素值节点（F5 契约）
        an6 := ast_a(node); ac6 := ast_b(node);
        ai6 : ., mut = 0;
        loop {
            if ai6 >= ac6 { break; }
            if an6 >= 0 {
                vn6 : ., mut = -1;
                if ast_kind(an6) == EXPR_NONE { vn6 = ast_a(an6); }
                if vn6 >= 0 { ast_patch_node(vn6, subst_from, subst_to); }
                an6 = an6 + 1;
            }
            ai6 = ai6 + 1;
        }
    } else if k == EXPR_FIELD || k == EXPR_INDEX || k == EXPR_UNARY || k == EXPR_RETURN || k == EXPR_TRY || k == EXPR_MOVE {
        if ast_a(node) >= 0 { ast_patch_node(ast_a(node), subst_from, subst_to); }
    }
}

fn find_or_create_mono_func(fi: int, call_node: int) -> int {
    // Create a monomorphized version of generic function fi for the given call site.
    // Only creates the FuncInfo entry — IR generation happens in pass 2 of ir_gen_all.

    fn_node := fi_ast_node(fi);
    body := ast_data(fn_node);
    first_param := ast_b(fn_node);
    param_count := ast_c(fn_node);
    orig_ret_type := ast_int_val(fn_node);
    orig_ret_node := ast_type_val(fn_node);

    gen_name_ni := fi_generic_name(fi, 0);
    gen_name := istr_get(gen_name_ni);

    // Get concrete type name from call node (stored by checker)
    concrete_type_ni : ., mut = ast_int_val(call_node);
    concrete_type_name : ., mut = istr_get(concrete_type_ni);

    // Create mangled name: "funcname$genericname.concretetype"
    orig_fn_name := istr_get(fi_name(fi));
    mangled_name : ., mut = orig_fn_name + "$";
    mangled_name = mangled_name + gen_name + "." + concrete_type_name;
    mangled_ni := str_intern(mangled_name);

    // Check if already exists
    existing := find_func(mangled_ni);
    if existing >= 0 { return existing; }

    // Create new EXPR_PARAM nodes with concrete param types
    new_first_param : ., mut = -1;
    ppi : ., mut = 0;
    ppn : ., mut = first_param;
    loop {
        if ppi >= param_count { break; }
        if ppn < 0 { break; }
        pname_ni := ast_a(ppn);
        self_mode := ast_int_val(ppn);
        orig_type_val := ast_type_val(ppn);
        orig_type_node := ast_data(ppn);

        // Replace type node if it references the generic param
        new_type_node : ., mut = orig_type_node;
        if orig_type_node >= 0 && ast_kind(orig_type_node) == EXPR_IDENT && ast_int_val(orig_type_node) == gen_name_ni {
            // Create new type node referencing concrete type name
            new_type_node = alloc_node(EXPR_IDENT, 0, 0, 0, concrete_type_ni, 0, 0, 0, 0);
        }

        np := alloc_node(EXPR_PARAM, pname_ni, 0, 0, self_mode, orig_type_val, new_type_node, 0, 0);
        if ppi == 0 { new_first_param = np; }
        ppi = ppi + 1;
        ppn = ppn + 1;
        loop { if ppn >= g_ast_count { break; } if ast_kind(ppn) == EXPR_PARAM { break; } ppn = ppn + 1; }
    }

    // Create new EXPR_FN node
    new_fn_node := alloc_node(EXPR_FN, mangled_ni, new_first_param, param_count, orig_ret_type, orig_ret_node, body, 0, 0);

    // Patch body: replace "gen_name.method" → "concrete_type_name.method"
    if body >= 0 {
        ast_patch_node(body, gen_name, concrete_type_name);
    }

    // Register new function
    new_fi := add_func(mangled_name, param_count, orig_ret_type, new_fn_node);
    if new_fi >= 0 {
        // Copy generic constraint info (non-generic now, but keep for reference)
        fi_set_generic_count(new_fi, 0);
    }

    return new_fi;
}

// --- Main entry ---

fn ir_gen_all() {
    g_ir_var_count = 0;
    g_ir_instr_count = 0;
    g_ir_func_count = 0;
    g_ir_local_count = 0;
    g_ir_local_depth = 0;
    g_ir_global_count = 0;
    g_next_label = 1;
    g_ir_loop_depth = 0;
    g_ir_str_const_count = 0;
    // 可选表示面：侧表复位 + 启用扫描（先于全局注册——隐藏信道的 var 行序依赖）
    optrep_begin();

    // Initialize dataflow graph
    init_df();

    // Initialize globals
    ir_gen_globals();

    i : ., mut = 0;
    loop {
        if i >= g_func_count { break; }
        if fi_generic_count(i) > 0 { i = i + 1; continue; }
        ir_func_idx := g_ir_func_count;
        df_begin_func(ir_func_idx);
        ir_gen_func(i);
        df_end_func(ir_func_idx);
        i = i + 1;
    }

    // 纯度 + state 链最终化（全部 IR 体就绪后；理由见 checker.cr compute_all_purity
    // 与 dataflow.cr df_replay_state_chain 头注）。文件路径的同点调用在 main.cr。
    df_state_finalize();
}

// Compute function body fingerprint: hash of the function body source text.
// Used for cache hit detection. If the body hasn't changed, the output IR
// is identical and can be restored from cache.
fn func_fingerprint(func_node: int) -> int {
    // func_node = EXPR_FUNC node
    // Body starts at ast_data(func_node)
    body := ast_data(func_node);
    if body < 0 { return 0; }
    // For fingerprinting, hash the function's AST line/col range in source
    // This is simpler than extracting the exact body bytes:
    // hash AST node kind chain from the body
    if g_ir_source_hash_ready == 0 {
        source_hash : ., mut = 2166136261;
        source_pos : ., mut = 0;
        source_len := str_len(g_source);
        loop {
            if source_pos >= source_len { break; }
            source_hash = source_hash * 16777619 + load8(g_source, source_pos);
            source_pos = source_pos + 1;
        }
        g_ir_source_hash = source_hash;
        g_ir_source_hash_ready = 1;
    }
    h : ., mut = g_ir_source_hash;
    // Walk the body AST and hash node kinds + values
    // For a simple first pass: hash the function's token stream range
    start_line := ast_line(func_node);
    start_col := ast_col(func_node);
    // Use g_line/position info to hash source bytes for this function
    // For now: simple hash of function name + param count + body node
    h = h * 16777619 + (ast_kind(func_node) % 256);
    h = h * 16777619 + (ast_a(func_node) % 256);   // name_ni
    h = h * 16777619 + (ast_c(func_node) % 256);   // param count
    if body >= 0 { h = h * 16777619 + (ast_kind(body) % 256); }
    return h;
}

// Compute function signature fingerprint: hash of name + param types + return type.
// Used to detect when callers need recompilation.
fn sig_fingerprint(func_node: int) -> int {
    h : ., mut = 2166136261;
    // Name
    name_ni := ast_a(func_node);
    name := istr_get(name_ni);
    ni : ., mut = 0;
    loop { if ni >= str_len(name) { break; }
        h = h * 16777619 + (load8(name, ni) % 256);
    ni = ni + 1; }
    // Param types
    param := ast_b(func_node);
    param_count := ast_c(func_node);
    pi : ., mut = 0;
    loop { if pi >= param_count { break; }
        pt := ast_type_val(param);
        h = h * 16777619 + (pt % 256);
        pi = pi + 1;
        param = param + 1;
    }
    // Return type
    ret_type := ast_type_val(func_node);
    h = h * 16777619 + (ret_type % 256);
    return h;
}
