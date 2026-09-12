// === monomorph.cr ===
// Generic monomorphization: instance cache + AST specialization.
// Each concrete instantiation of a generic function produces
// a specialized copy registered in g_funcs.

// ── Instance cache ──
// Each entry: 24 bytes = [original_func_ni, type_args_str_ni, specialized_fi]
g_gen_instances : string, mut;
g_gen_instance_count : int, mut;
g_gen_instance_cap : int, mut;

// ── Temporary substitution mapping (during clone) ──
// Parallel arrays: generic param name index → concrete type name index
g_gen_subst_old : string, mut;
g_gen_subst_new : string, mut;
g_gen_subst_count : int, mut;
g_gen_subst_cap : int, mut;

// ── R2 P3 Task 5（Step 4）：ti 型替换表（与上面的名字表**并行同键**：g_gen_subst_old 的
//    名字 ni → 实参**类型行 ti**）。来源 = checker 的调用点绑定段（g_gen_binds，globals.cr
//    表注）；命中时替换产物 = `inst_type_node_of_ti` 造的**完整类型节点**（命名/复合/泛型
//    应用皆可表达），取代旧「拼名字串再 str_intern 查名字」的塌缩（非原生实参一律 "int"）。
//    -1/缺位 → 回落名字路径（旧行为逐字保持）。──
g_gen_subst_tis : string, mut;
g_gen_subst_tis_count : int, mut;
g_gen_subst_tis_cap : int, mut;

// ── Temporary dedup map (old AST node → new AST node during clone) ──
g_gen_dedup_old : string, mut;
g_gen_dedup_new : string, mut;
g_gen_dedup_count : int, mut;
g_gen_dedup_cap : int, mut;

// ============================================================
// Grow helpers
// ============================================================
fn grow_gen_instances(needed: int) {
    if needed < g_gen_instance_cap { return; }
    nc : ., mut = g_gen_instance_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 24); _dyncpy(g_gen_instances, g_gen_instance_cap * 24, nb);
    g_gen_instances = nb; g_gen_instance_cap = nc; }

// 效应/纯度修正 Task 1：实例 → 源映射侧表（声明在 globals.cr——checker.cr 的
// compute_all_purity 要读它，bootstrap 名字解析按声明序）。
fn grow_purity_inst(needed: int) {
    if needed < g_purity_inst_cap { return; }
    nc : ., mut = g_purity_inst_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 24); _dyncpy(g_purity_inst, g_purity_inst_cap * 24, nb);
    g_purity_inst = nb; g_purity_inst_cap = nc; }

fn grow_gen_subst(needed: int) {
    if needed < g_gen_subst_cap { return; }
    nc : ., mut = g_gen_subst_cap * 2; if nc < 16 { nc = 16; } if nc < needed { nc = needed + 16; }
    sz := nc * 8;
    n1 := alloc(sz); _dyncpy(g_gen_subst_old, g_gen_subst_cap * 8, n1); g_gen_subst_old = n1;
    n2 := alloc(sz); _dyncpy(g_gen_subst_new, g_gen_subst_cap * 8, n2); g_gen_subst_new = n2;
    g_gen_subst_cap = nc; }

fn grow_gen_dedup(needed: int) {
    if needed < g_gen_dedup_cap { return; }
    nc : ., mut = g_gen_dedup_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    sz := nc * 8;
    n1 := alloc(sz); _dyncpy(g_gen_dedup_old, g_gen_dedup_cap * 8, n1); g_gen_dedup_old = n1;
    n2 := alloc(sz); _dyncpy(g_gen_dedup_new, g_gen_dedup_cap * 8, n2); g_gen_dedup_new = n2;
    g_gen_dedup_cap = nc; }

// R2 P3 Task 5（Step 4）：ti 型替换表增长（与 g_gen_subst_old 同长——同一次实例化建立）
fn grow_gen_subst_tis(needed: int) {
    if needed < g_gen_subst_tis_cap { return; }
    nc : ., mut = g_gen_subst_tis_cap * 2; if nc < 16 { nc = 16; } if nc < needed { nc = needed + 16; }
    nb := alloc(nc * 8); _dyncpy(g_gen_subst_tis, g_gen_subst_tis_cap * 8, nb);
    g_gen_subst_tis = nb; g_gen_subst_tis_cap = nc; }

// ============================================================
// Substitution mapping
// ============================================================

// Parse comma-separated type_args and build substitution mapping
// from generic param names (from FuncInfo) to concrete type name indices.
fn gen_build_subst(func_ni: int, type_args: string) {
    g_gen_subst_count = 0; g_gen_subst_cap = 0;
    gc := fi_generic_count(func_ni);
    if gc <= 0 { return; }
    pos : ., mut = 0;
    gi : ., mut = 0;
    loop {
        if gi >= gc { break; }
        if load8(type_args, pos) == 0 { break; }
        start := pos;
        loop {
            c := load8(type_args, pos);
            if c == 0 || c == 44 { break; }  // null or comma
            pos = pos + 1;
        }
        type_name := str_sub(type_args, start, pos - start);
        if load8(type_args, pos) == 44 { pos = pos + 1; }
        gen_param_ni := fi_generic_name(func_ni, gi);
        concrete_ni := str_intern(type_name);
        grow_gen_subst(g_gen_subst_count + 1);
        w64(g_gen_subst_old, g_gen_subst_count * 8, gen_param_ni);
        w64(g_gen_subst_new, g_gen_subst_count * 8, concrete_ni);
        g_gen_subst_count = g_gen_subst_count + 1;
        gi = gi + 1;
    }
}

// R2 P3 Task 5（Step 4）：把调用点绑定段（块 = [count, ti…]，见 checker.cr 写入点）装进
// ti 型替换表——**名表与 ti 表同序同键**（第 i 项同为第 i 个泛型形参）。返回装填条数；
// 0 = 无绑定段/段非法（调用方回落名字路径）。
fn gen_build_subst_tis(func_ni: int, bstart: int) -> int {
    g_gen_subst_tis_count = 0; g_gen_subst_tis_cap = 0;
    if bstart < 0 { return 0; }
    gc := fi_generic_count(func_ni);
    if gc <= 0 { return 0; }
    if bstart >= g_gen_binds_count { return 0; }
    cnt := r64(g_gen_binds, bstart * 8);
    if cnt != gc { return 0; }                     // 段长必须与形参数一致（不同 ⇒ 不信任）
    if bstart + 1 + cnt > g_gen_binds_count { return 0; }
    grow_gen_subst_tis(gc);
    i : ., mut = 0;
    loop {
        if i >= gc { break; }
        t := r64(g_gen_binds, (bstart + 1 + i) * 8);
        if t < 0 { return 0; }                     // 未绑定 ⇒ 全段放弃（不半解）
        if inst_ti_concrete(t) == 0 { return 0; }  // 含泛型形参行 ⇒ 全段放弃（同上）
        w64(g_gen_subst_tis, i * 8, t);
        g_gen_subst_tis_count = i + 1;
        i = i + 1;
    }
    return g_gen_subst_tis_count;
}

// Look up substitution for a generic param name.
// Returns concrete type name index, or -1 if not a generic param.
fn gen_lookup_subst(name_ni: int) -> int {
    mi : ., mut = 0;
    loop {
        if mi >= g_gen_subst_count { break; }
        if r64(g_gen_subst_old, mi * 8) == name_ni {
            return r64(g_gen_subst_new, mi * 8);
        }
        mi = mi + 1;
    }
    return -1;
}

// Check if a name is a base type. Returns the TY_* constant, or -1.
fn gen_base_type_tv(name_ni: int) -> int {
    s := istr_get(name_ni);
    if s == "int" { return TY_INT; }
    if s == "dex" { return TY_DEX; }
    if s == "bool" { return TY_BOOL; }
    if s == "string" { return TY_STRING; }
    if s == "char" { return TY_CHAR; }
    if s == "unit" { return TY_UNIT; }
    if s == "never" { return TY_NEVER; }
    return -1;
}

// ═══════════════ R2 P3 Task 5（Step 4）：ti ⇄ 节点/键 三件套 ═══════════════
// 背景（旧态，逐条实测）：实例键由 ir_gen 从**实参 IR 变量的类型**拼名字串得到，非原生
// （struct/tuple/slice/ref…）一律兜底 "int"（ir_gen.cr 的 else 分支）⇒ ① 两个不同 struct
// 实参折叠成同一实例（实测 .ccr：`f[unit]` 一份）；② 替换 = 名字文本替换（gen_build_subst）
// ⇒ 泛型形参被替换成**错的名字**（`fn f[T](a: int, b: T)` 以 `f(1, "s")` 调用 → T := int，
// 而形参 b 的声明类型是 T ⇒ 实例体按 int 落地）。本套即治此二病：
//   ① `inst_key_of_ti`：类型行 → 规范结构名（键的构成单元；结构忠实 ⇒ 异型不再折叠）；
//   ② `inst_type_node_of_ti`：类型行 → 类型语法节点（替换产物；命名/应用/序列/引用/指针/
//      可选皆可表达）；
//   ③ `gen_subst_ti`：克隆期把嵌套调用点绑定里的泛型形参行按**当前实例**替换。
// 分隔符约定（**键必须能被 gen_build_subst 按逗号切分**）：项内分隔用 "|"、长度用 "; "、
// 形参间才用 ","（实例键的 join 分隔符）⇒ 规范名内**不得出现逗号**。
// 语法节点合成契约：**仅**合成「根节点占单槽」的类型（原生/命名/泛型形参）——EXPR_GENERIC_APPLY
// 的实参读取按 `first_arg + i`（res_type_node）⇒ 实参根节点必须**连续**，而合成复合实参时
// 子树节点会插在中间（parser 侧靠「子树的根恒为该子树最后分配的节点」自然成立）⇒ 复合实参
// 一律回 -1（调用方回落名字路径；登记为未覆盖面）。

fn inst_key_of_ti(ti: int) -> string {
    k := get_type_kind(ti);
    if k < 0 { return "?"; }
    if k == TYP_BASE {
        d := get_type_data(ti);
        if d == TY_INT { return "int"; }
        if d == TY_DEX { return "dex"; }
        if d == TY_BOOL { return "bool"; }
        if d == TY_STRING { return "string"; }
        if d == TY_CHAR { return "char"; }
        if d == TY_UNIT { return "unit"; }
        if d == TY_NEVER { return "never"; }
        return "#" + int_str(d);
    }
    if k == TYP_NAMED || k == TYP_GENERIC_PARAM { return istr_get(get_type_data(ti)); }
    if k == TYP_GENERIC_APPLY {
        base := get_type_data(ti);
        s : ., mut = "?";
        if get_type_kind(base) == TYP_NAMED { s = istr_get(get_type_data(base)); }
        s = s + "[";
        start := get_type_extra(ti);
        cnt := r64(g_gen_apply_data, start * 8);
        i : ., mut = 0;
        loop {
            if i >= cnt { break; }
            if i > 0 { s = s + "|"; }
            s = s + inst_key_of_ti(r64(g_gen_apply_data, (start + 1 + i) * 8));
            i = i + 1;
        }
        return s + "]";
    }
    if k == TYP_ARRAY { return "[" + inst_key_of_ti(get_type_data(ti)) + "; " + int_str(get_type_extra(ti)) + "]"; }
    if k == TYP_SLICE { return "[" + inst_key_of_ti(get_type_data(ti)) + "]"; }
    if k == TYP_REF {
        if get_type_extra(ti) != 0 { return "&mut " + inst_key_of_ti(get_type_data(ti)); }
        return "&" + inst_key_of_ti(get_type_data(ti));
    }
    if k == TYP_PTR { return "*" + inst_key_of_ti(get_type_data(ti)); }
    if k == TYP_OPTIONAL { return inst_key_of_ti(get_type_data(ti)) + "?"; }
    if k == TYP_NULL { return "null"; }
    if k == TYP_DYN { return "dyn"; }
    if k == TYP_TUPLE {
        s : ., mut = "(";
        cnt2 := get_type_data(ti);
        start2 := get_type_extra(ti);
        i2 : ., mut = 0;
        loop {
            if i2 >= cnt2 { break; }
            if i2 > 0 { s = s + "|"; }
            s = s + inst_key_of_ti(r64(g_gen_apply_data, (start2 + i2) * 8));
            i2 = i2 + 1;
        }
        return s + ")";
    }
    return "#" + int_str(ti);   // 未知 kind：行号兜底（同编译期内确定；跨行同型不去重，登记）
}

// 类型行 → 类型语法节点（**单槽根**约束见上注）；-1 = 无对应形态（调用方回落名字路径）
fn inst_type_node_of_ti(ti: int) -> int {
    k := get_type_kind(ti);
    if k < 0 { return -1; }
    if k == TYP_BASE { return alloc_node(0, 0, 0, 0, 0, get_type_data(ti), 0, 0, 0); }
    if k == TYP_NAMED || k == TYP_GENERIC_PARAM {
        return alloc_node(EXPR_IDENT, 0, 0, 0, get_type_data(ti), 0, 0, 0, 0);
    }
    if k == TYP_ARRAY {
        inner := inst_type_node_of_ti(get_type_data(ti));
        if inner < 0 { return -1; }
        return alloc_node(EXPR_ARRAY, inner, 0, 0, get_type_extra(ti), 0, 0, 0, 0);
    }
    if k == TYP_SLICE {
        inner := inst_type_node_of_ti(get_type_data(ti));
        if inner < 0 { return -1; }
        return alloc_node(EXPR_ARRAY, inner, 0, 0, 0, 0, 0, 0, 0);
    }
    if k == TYP_REF {
        inner := inst_type_node_of_ti(get_type_data(ti));
        if inner < 0 { return -1; }
        return alloc_node(EXPR_REFTYPE, inner, 0, 0, get_type_extra(ti), 0, 0, 0, 0);
    }
    if k == TYP_PTR {
        inner := inst_type_node_of_ti(get_type_data(ti));
        if inner < 0 { return -1; }
        return alloc_node(EXPR_PTRTYPE, inner, 0, 0, 0, 0, 0, 0, 0);
    }
    if k == TYP_OPTIONAL {
        inner := inst_type_node_of_ti(get_type_data(ti));
        if inner < 0 { return -1; }
        return alloc_node(EXPR_OPTIONAL, inner, 0, 0, 0, 0, 0, 0, 0);
    }
    if k == TYP_GENERIC_APPLY {
        base := get_type_data(ti);
        if get_type_kind(base) != TYP_NAMED { return -1; }
        start := get_type_extra(ti);
        cnt := r64(g_gen_apply_data, start * 8);
        if cnt <= 0 { return -1; }
        first_an : ., mut = -1;
        i : ., mut = 0;
        loop {
            if i >= cnt { break; }
            at := r64(g_gen_apply_data, (start + 1 + i) * 8);
            ak := get_type_kind(at);
            // 实参根节点连续契约：仅接受单槽根（原生/命名/形参）——复合实参见上注（登记）
            if ak != TYP_BASE && ak != TYP_NAMED && ak != TYP_GENERIC_PARAM { return -1; }
            an := inst_type_node_of_ti(at);
            if an < 0 { return -1; }
            if i == 0 { first_an = an; }
            i = i + 1;
        }
        return alloc_node(EXPR_GENERIC_APPLY, get_type_data(base), first_an, cnt, 0, 0, 0, 0, 0);
    }
    return -1;   // TUPLE / NULL / DYN / 未知 kind：无语法形态（DYN 另见 res_type_node 的码 7 格）
}

fn gen_lookup_subst_ti(name_ni: int) -> int {
    mi : ., mut = 0;
    loop {
        if mi >= g_gen_subst_tis_count { break; }
        if r64(g_gen_subst_old, mi * 8) == name_ni { return r64(g_gen_subst_tis, mi * 8); }
        mi = mi + 1;
    }
    return -1;
}

// 类型行 → 按当前实例替换泛型形参行后的类型行（-1 保持原行；复合行结构性重建）
fn gen_subst_ti(ti: int) -> int {
    k := get_type_kind(ti);
    if k < 0 { return ti; }
    if k == TYP_GENERIC_PARAM {
        s := gen_lookup_subst_ti(get_type_data(ti));
        if s >= 0 { return s; }
        return ti;
    }
    if k == TYP_ARRAY { return alloc_type(TYP_ARRAY, gen_subst_ti(get_type_data(ti)), get_type_extra(ti)); }
    if k == TYP_SLICE { return alloc_type(TYP_SLICE, gen_subst_ti(get_type_data(ti)), 0); }
    if k == TYP_REF { return alloc_type(TYP_REF, gen_subst_ti(get_type_data(ti)), get_type_extra(ti)); }
    if k == TYP_PTR { return alloc_type(TYP_PTR, gen_subst_ti(get_type_data(ti)), get_type_extra(ti)); }
    if k == TYP_OPTIONAL { return alloc_type(TYP_OPTIONAL, gen_subst_ti(get_type_data(ti)), 0); }
    if k == TYP_GENERIC_APPLY {
        start := get_type_extra(ti);
        cnt := r64(g_gen_apply_data, start * 8);
        // 两趟（照 res_type_node 同款：子项替换自身会追加 gen_apply 载荷）
        subs : string, mut;
        if cnt > 0 {
            subs = alloc(cnt * 8);
            i : ., mut = 0;
            loop {
                if i >= cnt { break; }
                w64(subs, i * 8, gen_subst_ti(r64(g_gen_apply_data, (start + 1 + i) * 8)));
                i = i + 1;
            }
        }
        ns := g_gen_apply_data_count;
        grow_gen_apply_data(ns + 1 + cnt);
        w64(g_gen_apply_data, ns * 8, cnt);
        i2 : ., mut = 0;
        loop {
            if i2 >= cnt { break; }
            w64(g_gen_apply_data, (ns + 1 + i2) * 8, r64(subs, i2 * 8));
            i2 = i2 + 1;
        }
        g_gen_apply_data_count = ns + 1 + cnt;
        return alloc_type(TYP_GENERIC_APPLY, get_type_data(ti), ns);
    }
    return ti;
}

// 替换后是否**全具体**（无残留泛型形参行）：克隆期嵌套调用点绑定重映射的前置条件
// （残留 = 该绑定在本实例上下文无解 ⇒ 整段放弃、回落旧名字路径，不发明半解实例）
fn inst_ti_concrete(ti: int) -> int {
    k := get_type_kind(ti);
    if k < 0 { return 1; }                       // 越界行：非形参，按具体处理（判定面自会拒绝）
    if k == TYP_GENERIC_PARAM { return 0; }
    if k == TYP_ARRAY || k == TYP_SLICE || k == TYP_REF || k == TYP_PTR || k == TYP_OPTIONAL {
        return inst_ti_concrete(get_type_data(ti));
    }
    if k == TYP_GENERIC_APPLY {
        start := get_type_extra(ti);
        cnt := r64(g_gen_apply_data, start * 8);
        i : ., mut = 0;
        loop {
            if i >= cnt { return 1; }
            if inst_ti_concrete(r64(g_gen_apply_data, (start + 1 + i) * 8)) == 0 { return 0; }
            i = i + 1;
        }
        return 1;
    }
    if k == TYP_TUPLE {
        start2 := get_type_extra(ti);
        cnt2 := get_type_data(ti);
        i2 : ., mut = 0;
        loop {
            if i2 >= cnt2 { return 1; }
            if inst_ti_concrete(r64(g_gen_apply_data, (start2 + i2) * 8)) == 0 { return 0; }
            i2 = i2 + 1;
        }
        return 1;
    }
    return 1;
}

// 克隆期：源调用点绑定段（iv = 段起始 + 1，见 checker.cr 写入点）→ 按当前实例重登记的段
// （返回新的 **iv**；0 = 无/不可重映射 ⇒ 克隆体回落旧名字路径）。
// 为何必须重映射：克隆体内的调用节点携带**源函数上下文**的绑定（如 T := gparam(U)）——
// 直接沿用 = 用源上下文的形参行给实例建键（错实例）；置 0 = 丢信息（旧行为）。
fn gen_remap_binds(iv: int) -> int {
    if iv <= 0 { return 0; }
    start := iv - 1;
    if start >= g_gen_binds_count { return 0; }
    cnt := r64(g_gen_binds, start * 8);
    if cnt <= 0 { return 0; }
    if start + 1 + cnt > g_gen_binds_count { return 0; }
    // 前置：全部条目替换后须**全具体**（否则整段放弃——不发明半解实例）。替换结果先落暂存
    // （gen_subst_ti 对复合行会追加类型行/载荷 ⇒ 逐条重算 = 双倍分配；且避免边写边读）。
    subs : string, mut = alloc(cnt * 8);
    i : ., mut = 0;
    loop {
        if i >= cnt { break; }
        t := gen_subst_ti(r64(g_gen_binds, (start + 1 + i) * 8));
        if inst_ti_concrete(t) == 0 { return 0; }
        w64(subs, i * 8, t);
        i = i + 1;
    }
    ns := g_gen_binds_count;
    grow_gen_binds(ns + 1 + cnt);
    w64(g_gen_binds, ns * 8, cnt);
    i2 : ., mut = 0;
    loop {
        if i2 >= cnt { break; }
        w64(g_gen_binds, (ns + 1 + i2) * 8, r64(subs, i2 * 8));
        i2 = i2 + 1;
    }
    g_gen_binds_count = ns + 1 + cnt;
    return ns + 1;
}

// ============================================================
// Dedup mapping for tree clone
// ============================================================

fn gen_dedup_find(old_node: int) -> int {
    mi : ., mut = 0;
    loop {
        if mi >= g_gen_dedup_count { break; }
        if r64(g_gen_dedup_old, mi * 8) == old_node {
            return r64(g_gen_dedup_new, mi * 8);
        }
        mi = mi + 1;
    }
    return -1;
}

fn gen_dedup_add(old_node: int, new_node: int) {
    grow_gen_dedup(g_gen_dedup_count + 1);
    w64(g_gen_dedup_old, g_gen_dedup_count * 8, old_node);
    w64(g_gen_dedup_new, g_gen_dedup_count * 8, new_node);
    g_gen_dedup_count = g_gen_dedup_count + 1;
}

// ============================================================
// Deep AST clone with generic param substitution
// ============================================================

// Clone a sequence of g_block_stmts entries, substituting each one.
fn gen_clone_block(start: int, count: int) -> int {
    if count <= 0 { return -1; }
    new_start := g_block_stmt_count;
    grow_block_stmts(new_start + count);
    // Reserve the outer block range before cloning children. Nested blocks
    // append after this range instead of reusing and overwriting new_start.
    g_block_stmt_count = new_start + count;
    i : ., mut = 0;
    loop {
        if i >= count { break; }
        old_stmt := r64(g_block_stmts, (start + i) * 8);
        new_stmt := gen_clone_tree(old_stmt);
        w64(g_block_stmts, (new_start + i) * 8, new_stmt);
        i = i + 1;
    }
    return new_start;
}

// Clone consecutive AST nodes (for struct fields, array elements, etc.)
fn gen_clone_consecutive(start: int, count: int) -> int {
    if count <= 0 || start < 0 { return -1; }
    // Each cloned node is appended to g_ast by gen_clone_tree, so they end up consecutive.
    first_new := g_ast_count;
    i : ., mut = 0;
    loop {
        if i >= count { break; }
        gen_clone_tree(start + i);
        i = i + 1;
    }
    return first_new;
}

// Deep-clone an AST subtree, substituting generic param references
// with concrete type name references.
fn gen_clone_tree(node: int) -> int {
    if node < 0 { return -1; }

    // Dedup: if this node was already cloned, return the existing clone.
    dup := gen_dedup_find(node);
    if dup >= 0 { return dup; }

    k := ast_kind(node);
    a := ast_a(node); b := ast_b(node); c := ast_c(node);
    iv := ast_int_val(node); tv := ast_type_val(node);
    d := ast_data(node); ln := ast_line(node); cl := ast_col(node);

    // ── EXPR_IDENT: might be a generic param reference ──
    if k == EXPR_IDENT {
        ni := iv;
        // R2 P3 Task 5（Step 4）：**ti 路径优先**——由类型行合成完整类型节点（命名/应用/序列/
        // 引用/指针/可选皆可表达），治旧「名字文本替换」对非原生实参的塌缩。合成失败（-1：
        // 元组/复合实参等无语法形态）→ 落名字路径（旧行为逐字保持）。
        sti := gen_lookup_subst_ti(ni);
        if sti >= 0 {
            sn := inst_type_node_of_ti(sti);
            if sn >= 0 { gen_dedup_add(node, sn); return sn; }
        }
        sub := gen_lookup_subst(ni);
        if sub >= 0 {
            // Substitute generic param with concrete type
            base_tv := gen_base_type_tv(sub);
            if base_tv >= 0 {
                // Base type reference (int, float, etc.) → kind=0 node with type_val
                n := ast_alloc(0, 0, 0, 0, 0, base_tv, 0, ln, cl);
                gen_dedup_add(node, n); return n;
            }
            // Named type (struct name, etc.) → EXPR_IDENT with concrete name
            n := ast_alloc(k, a, b, c, sub, tv, d, ln, cl);
            gen_dedup_add(node, n); return n;
        }
        // Not a generic param — clone as-is
        n := ast_alloc(k, a, b, c, ni, tv, d, ln, cl);
        gen_dedup_add(node, n); return n;
    }

    // ── EXPR_NONE (kind=0): base type node OR struct field wrapper ──
    if k == EXPR_NONE {
        if a >= 0 && a != node {
            // Struct literal field or pattern wrapper: a = value expression
            a2 := gen_clone_tree(a);
            n := ast_alloc(k, a2, b, c, iv, tv, d, ln, cl);
            gen_dedup_add(node, n); return n;
        }
        // Base type node or empty: no AST children
        n := ast_alloc(k, a, b, c, iv, tv, d, ln, cl);
        gen_dedup_add(node, n); return n;
    }

    // ── Leaf nodes (no AST children) ──
    if k == EXPR_INT { n := ast_alloc(k, a, b, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }
    if k == EXPR_DEX { n := ast_alloc(k, a, b, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }
    if k == EXPR_BOOL { n := ast_alloc(k, a, b, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }
    if k == EXPR_STRING { n := ast_alloc(k, a, b, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }
    if k == EXPR_CHAR { n := ast_alloc(k, a, b, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }
    if k == EXPR_WILDCARD { n := ast_alloc(k, a, b, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }
    if k == EXPR_BREAK { n := ast_alloc(k, a, b, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }
    if k == EXPR_CONTINUE { n := ast_alloc(k, a, b, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }

    // ── Single child in `a` ──
    if k == EXPR_RETURN { a2 := gen_clone_tree(a); n := ast_alloc(k, a2, b, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }
    if k == EXPR_YIELD { a2 := gen_clone_tree(a); n := ast_alloc(k, a2, b, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }
    if k == EXPR_AWAIT { a2 := gen_clone_tree(a); n := ast_alloc(k, a2, b, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }
    if k == EXPR_MOVE { a2 := gen_clone_tree(a); n := ast_alloc(k, a2, b, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }
    if k == EXPR_UNSAFE { a2 := gen_clone_tree(a); n := ast_alloc(k, a2, b, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }
    if k == EXPR_TRY { a2 := gen_clone_tree(a); n := ast_alloc(k, a2, b, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }
    if k == EXPR_UNARY { a2 := gen_clone_tree(a); n := ast_alloc(k, a2, b, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }
    if k == EXPR_FIELD { a2 := gen_clone_tree(a); n := ast_alloc(k, a2, b, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }
    if k == EXPR_STMT { a2 := gen_clone_tree(a); n := ast_alloc(k, a2, b, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }
    if k == EXPR_GO { a2 := gen_clone_tree(a); n := ast_alloc(k, a2, b, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }
    // ── R2 P3 Task 4：`T?`（a = 内层类型节点，可能含泛型形参）——单子节点克隆，
    //    形参代入由 EXPR_IDENT 分支承担（clone 时经 gen_lookup_subst），故此处只递归 a。
    //    **必配分支**：默认兜底会把 d（=0）当 AST 子节点克隆（读进节点 0）——显式分支消除该面。
    if k == EXPR_OPTIONAL { a2 := gen_clone_tree(a); n := ast_alloc(k, a2, b, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }

    // ── Two children: `a` and `b` ──
    if k == EXPR_BINARY { a2 := gen_clone_tree(a); b2 := gen_clone_tree(b); n := ast_alloc(k, a2, b2, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }
    if k == EXPR_ASSIGN { a2 := gen_clone_tree(a); b2 := gen_clone_tree(b); n := ast_alloc(k, a2, b2, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }
    if k == EXPR_INDEX { a2 := gen_clone_tree(a); b2 := gen_clone_tree(b); n := ast_alloc(k, a2, b2, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }
    if k == EXPR_WHILE { a2 := gen_clone_tree(a); b2 := gen_clone_tree(b); n := ast_alloc(k, a2, b2, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }
    if k == EXPR_LOOP { a2 := gen_clone_tree(a); n := ast_alloc(k, a2, b, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }
    if k == EXPR_RANGE { a2 := gen_clone_tree(a); b2 := gen_clone_tree(b); n := ast_alloc(k, a2, b2, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }
    if k == EXPR_AS { a2 := gen_clone_tree(a); b2 := gen_clone_tree(b); n := ast_alloc(k, a2, b2, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }

    // ── EXPR_CALL: a=func_node(YES), b=first_ARG(YES), c=arg_count(NOT) ──
    if k == EXPR_CALL {
        a2 := gen_clone_tree(a); b2 := gen_clone_tree(b);
        // R2 P3 Task 5（Step 4）：调用点绑定的**实例化重映射**——克隆体内的调用节点携带
        // **源函数上下文**的绑定（如 T := gparam(U)）⇒ 按当前实例替换重登记（gen_remap_binds）；
        // 不可完全落地 → 0（= 无绑定，回落旧名字路径）。**必须显式改写**：iv 经 ast_alloc
        // 原样拷贝，沿用 = 用源上下文的形参行给实例建键（错实例）。
        n := ast_alloc(k, a2, b2, c, iv, tv, d, ln, cl);
        ast_set_int_val(n, gen_remap_binds(iv));
        // R2 P3b Task 6（Step 3，mangling 退役）：接口方法调用（泛型形参接收者）的**实例化解析**。
        // 源节点携带（data = 泛型形参名 ni，type_val = CALL_FLAG_IFACE_METHOD；检查见 checker 的
        // 泛型约束方法路径注）⇒ 此处按当前实例的具体类型**查方法表**取真实函数名（`g_methods`
        // 三元组 → 函数名 ni）。旧态 = 克隆期沿用合成的 "T.m" 串（文本替换只作用于 EXPR_IDENT）
        // ⇒ 实例体内调用目标悬空（实测：产物运行 rc=139）。
        // 解析失败（形参未绑定 / 具体类型无此方法 / 嵌套形参）⇒ 保持原状（登记面，不发明目标）。
        if tv == CALL_FLAG_IFACE_METHOD {
            cni := gen_lookup_subst(d);
            if cni >= 0 && a2 >= 0 {
                m_ni := ast_int_val(a2);
                f_ni := iface_find_method(cni, m_ni);
                if f_ni >= 0 {
                    ast_set_data(n, f_ni);
                    ast_set_type_val(n, 0);
                }
            }
        }
        gen_dedup_add(node, n); return n;
    }

    // ── EXPR_ARG: a=expr(YES), b=next_arg(YES or -1) ──
    if k == EXPR_ARG { a2 := gen_clone_tree(a); b2 := gen_clone_tree(b); n := ast_alloc(k, a2, b2, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }

    // ── EXPR_IF: a=cond(YES), b=then(YES), c=else(YES or -1) ──
    if k == EXPR_IF { a2 := gen_clone_tree(a); b2 := gen_clone_tree(b); c2 := gen_clone_tree(c); n := ast_alloc(k, a2, b2, c2, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }

    // ── EXPR_FN: a=name_ni(NOT), b=first_param(YES), c=param_count(NOT), d=body(YES) ──
    if k == EXPR_FN { d2 := gen_clone_tree(d); n := ast_alloc(k, a, b, c, iv, tv, d2, ln, cl); gen_dedup_add(node, n); return n; }

    // ── EXPR_PARAM: a=name_ni(NOT), d=type_node(YES) ──
    if k == EXPR_PARAM { d2 := gen_clone_tree(d); n := ast_alloc(k, a, b, c, iv, tv, d2, ln, cl); gen_dedup_add(node, n); return n; }

    // ── EXPR_BLOCK: children in g_block_stmts ──
    if k == EXPR_BLOCK { new_start := gen_clone_block(a, b); n := ast_alloc(k, new_start, b, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }

    // ── EXPR_FOR: a=var_name_ni(NOT), b=iter(YES), c=body(YES) ──
    if k == EXPR_FOR { b2 := gen_clone_tree(b); c2 := gen_clone_tree(c); n := ast_alloc(k, a, b2, c2, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }

    // ── EXPR_LET: a=name_ni(NOT), b=type(YES or -1), c=value(YES or -1), d=is_mut(NOT) ──
    if k == EXPR_LET { b2 := gen_clone_tree(b); c2 := gen_clone_tree(c); n := ast_alloc(k, a, b2, c2, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }

    // ── EXPR_STRUCT: a=type_name_ni(NOT), b=first wrapper(YES, consecutive), c=field_count(NOT)；
    //    wrapper.a = field value node、wrapper.b = 字段名 idx（TODO #29 ①；-1 = 无名字信息）
    //    （F5 契约，见 parser.cr struct 字面量分支）──
    if k == EXPR_STRUCT {
        if b >= 0 && c > 0 {
            // 字段值先逐个深克隆（各自子树自占槽位），再统建连续 wrapper——
            // 不得「克隆值后随建 wrapper」逐元素交错：wrapper 将不连续（与 parser 同契约）。
            // **名字随克隆保留**（#29 ①）：实例体里的字段绑定仍按名字（源序 ≠ 声明序时，
            // 丢名字会让 ir_gen 回落位序 ⇒ 静默错值——正是 #29 要消灭的类）。
            nvs : string, mut = alloc(c * 8);
            nms : string, mut = alloc(c * 8);
            i : ., mut = 0;
            loop {
                if i >= c { break; }
                vn : ., mut = -1;
                if b + i >= 0 { vn = ast_a(b + i); }
                w64(nvs, i * 8, gen_clone_tree(vn));
                w64(nms, i * 8, ast_b(b + i));
                i = i + 1;
            }
            new_first := g_ast_count;
            i = 0;
            loop {
                if i >= c { break; }
                ast_alloc(EXPR_NONE, r64(nvs, i * 8), r64(nms, i * 8), 0, 0, 0, 0, ln, cl);
                i = i + 1;
            }
            n := ast_alloc(k, a, new_first, c, iv, tv, d, ln, cl);
            gen_dedup_add(node, n); return n;
        }
        n := ast_alloc(k, a, b, c, iv, tv, d, ln, cl);
        gen_dedup_add(node, n); return n;
    }

    // ── EXPR_ARRAY: a=first wrapper(YES, consecutive), b=elem_count(NOT)；
    //    wrapper.a = element value node（F5 契约，见 parser.cr 下标分支）──
    if k == EXPR_ARRAY {
        if a >= 0 && b > 0 {
            // 元素值先逐个深克隆（各自子树自占槽位），再统建连续 wrapper（与 parser 同契约）。
            nvs : string, mut = alloc(b * 8);
            i : ., mut = 0;
            loop {
                if i >= b { break; }
                vn : ., mut = -1;
                if a + i >= 0 { vn = ast_a(a + i); }
                w64(nvs, i * 8, gen_clone_tree(vn));
                i = i + 1;
            }
            new_first := g_ast_count;
            i = 0;
            loop {
                if i >= b { break; }
                ast_alloc(EXPR_NONE, r64(nvs, i * 8), 0, 0, 0, 0, 0, ln, cl);
                i = i + 1;
            }
            n := ast_alloc(k, new_first, b, c, iv, tv, d, ln, cl);
            gen_dedup_add(node, n); return n;
        }
        n := ast_alloc(k, a, b, c, iv, tv, d, ln, cl);
        gen_dedup_add(node, n); return n;
    }

    // ── EXPR_TUPLE: a=first wrapper(YES, consecutive), b=elem_count(NOT)；
    //    wrapper.a = element value node（F5 契约，见 parser.cr 元组分支）──
    if k == EXPR_TUPLE {
        if a >= 0 && b > 0 {
            // 元素值先逐个深克隆（各自子树自占槽位），再统建连续 wrapper——
            // 不得「克隆值后随建 wrapper」逐元素交错：wrapper 将不连续（与 parser 同契约）。
            nvs : string, mut = alloc(b * 8);
            i : ., mut = 0;
            loop {
                if i >= b { break; }
                vn : ., mut = -1;
                if a + i >= 0 { vn = ast_a(a + i); }
                w64(nvs, i * 8, gen_clone_tree(vn));
                i = i + 1;
            }
            new_first := g_ast_count;
            i = 0;
            loop {
                if i >= b { break; }
                ast_alloc(EXPR_NONE, r64(nvs, i * 8), 0, 0, 0, 0, 0, ln, cl);
                i = i + 1;
            }
            n := ast_alloc(k, new_first, b, c, iv, tv, d, ln, cl);
            gen_dedup_add(node, n); return n;
        }
        n := ast_alloc(k, a, b, c, iv, tv, d, ln, cl);
        gen_dedup_add(node, n); return n;
    }

    // ── EXPR_GENERIC_APPLY: a=base_name_ni(NOT), b=first_arg(YES, consecutive), c=arg_count(NOT) ──
    if k == EXPR_GENERIC_APPLY {
        if b >= 0 && c > 0 {
            new_first := gen_clone_consecutive(b, c);
            n := ast_alloc(k, a, new_first, c, iv, tv, d, ln, cl);
            gen_dedup_add(node, n); return n;
        }
        n := ast_alloc(k, a, b, c, iv, tv, d, ln, cl);
        gen_dedup_add(node, n); return n;
    }

    // ── EXPR_MATCH: a=expr(YES), b=first_arm(YES), c=arm_count(NOT) ──
    if k == EXPR_MATCH { a2 := gen_clone_tree(a); b2 := gen_clone_tree(b); n := ast_alloc(k, a2, b2, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }

    // ── EXPR_ARM: a=pattern(YES), b=body(YES) ──
    if k == EXPR_ARM { a2 := gen_clone_tree(a); b2 := gen_clone_tree(b); n := ast_alloc(k, a2, b2, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }

    // ── EXPR_ENUM_CONSTRUCTOR: a=name_ni(NOT), b=first_arg(YES), c=arg_count(NOT) ──
    if k == EXPR_ENUM_CONSTRUCTOR { b2 := gen_clone_tree(b); n := ast_alloc(k, a, b2, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }

    // ── EXPR_ENUMPAT: a=name_ni(NOT), b=first_subpat(YES, consecutive), c=subpat_count(NOT) ──
    if k == EXPR_ENUMPAT { b2 := gen_clone_consecutive(b, c); n := ast_alloc(k, a, b2, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }

    // ── EXPR_STRUCTPAT: a=name_ni(NOT), b=first wrapper(YES, consecutive), c=field_count(NOT)；
    //    wrapper.a = 子模式节点（F5 契约，见 parser.cr struct 模式分支）──
    if k == EXPR_STRUCTPAT {
        if b >= 0 && c > 0 {
            nvs : string, mut = alloc(c * 8);
            i : ., mut = 0;
            loop {
                if i >= c { break; }
                vn : ., mut = -1;
                if b + i >= 0 { vn = ast_a(b + i); }
                w64(nvs, i * 8, gen_clone_tree(vn));
                i = i + 1;
            }
            new_first := g_ast_count;
            i = 0;
            loop {
                if i >= c { break; }
                ast_alloc(EXPR_NONE, r64(nvs, i * 8), 0, 0, 0, 0, 0, ln, cl);
                i = i + 1;
            }
            n := ast_alloc(k, a, new_first, c, iv, tv, d, ln, cl);
            gen_dedup_add(node, n); return n;
        }
        n := ast_alloc(k, a, b, c, iv, tv, d, ln, cl);
        gen_dedup_add(node, n); return n;
    }

    // ── EXPR_AT: a=name_ni(NOT), b=args_node(YES or -1) ──
    if k == EXPR_AT { b2 := gen_clone_tree(b); n := ast_alloc(k, a, b2, c, iv, tv, d, ln, cl); gen_dedup_add(node, n); return n; }

    // ── EXPR_FLOW: a=name_ni(NOT), b=param_count(NOT), c=first_param(YES), d=body(YES) ──
    if k == EXPR_FLOW { c2 := gen_clone_tree(c); d2 := gen_clone_tree(d); n := ast_alloc(k, a, b, c2, iv, tv, d2, ln, cl); gen_dedup_add(node, n); return n; }

    // ── Fallback (shouldn't normally reach here) ──
    // Conservatively clone all pointer-sized fields as AST children.
    a2 := gen_clone_tree(a); b2 := gen_clone_tree(b); c2 := gen_clone_tree(c); d2 := gen_clone_tree(d);
    n := ast_alloc(k, a2, b2, c2, iv, tv, d2, ln, cl);
    gen_dedup_add(node, n); return n;
}

// ============================================================
// Cache API: find or create specialized instance
// ============================================================

// Find a specialized instance in the cache.
// func_ni: the original generic FuncInfo index
// type_args: comma-separated concrete type names (e.g. "int,string")
// Returns the specialized function index, or -1 if not found.
fn gen_find_cached(func_ni: int, type_args: string) -> int {
    i : ., mut = 0;
    loop {
        if i >= g_gen_instance_count { break; }
        if r64(g_gen_instances, i * 24) == func_ni {
            cached_args_ni := r64(g_gen_instances, i * 24 + 8);
            if istr_eq(cached_args_ni, type_args) != 0 {
                return r64(g_gen_instances, i * 24 + 16);
            }
        }
        i = i + 1;
    }
    return -1;
}

// Find or create a specialized instance of a generic function.
// func_ni: the original generic FuncInfo index
// type_args: comma-separated concrete type names (e.g. "int,string")
// Returns the specialized function index.
fn gen_find_or_create(func_ni: int, type_args: string) -> int {
    cached := gen_find_cached(func_ni, type_args);
    if cached >= 0 { return cached; }
    return gen_create_instance(func_ni, type_args, -1);
}

// R2 P3 Task 5（Step 4）：带**调用点绑定段**的查/建（ir_gen 提供规范键 + 段起始）。
// 缓存键 = type_args 串（规范结构名 join，含真身份）⇒ 同实例同键、异实例异键（不再折叠）。
fn gen_find_or_create_bind(func_ni: int, type_args: string, bstart: int) -> int {
    cached := gen_find_cached(func_ni, type_args);
    if cached >= 0 { return cached; }
    return gen_create_instance(func_ni, type_args, bstart);
}

// Create a specialized copy of a generic function.
// Steps:
//   1. Build generic param → concrete type name substitution mapping
//   2. Deep-clone the function's AST subtree with type substitution
//   3. Register the new function in g_funcs
//   4. Cache the new function index
//   5. Return the new function index
fn gen_create_instance(func_ni: int, type_args: string, bstart: int) -> int {
    // 1. Build substitution mapping
    //    · 名表（g_gen_subst_old/new）：键 = 键串按逗号切分——**回落路径**；规范键下其名字对
    //      复合类型不是声明名 ⇒ 只在 ti 路径失效时才可能被用到（见 gen_clone_tree 的优先级）。
    //    · ti 表（g_gen_subst_tis）：bstart ≥ 0 且段合法时装填（**优先路径**——完整类型节点）。
    gen_build_subst(func_ni, type_args);
    gen_build_subst_tis(func_ni, bstart);

    // 2. Clone the original function AST
    orig_fn_node := fi_ast_node(func_ni);
    g_gen_dedup_count = 0; g_gen_dedup_cap = 0;
    new_fn_node := gen_clone_tree(orig_fn_node);

    // Compute mangled name: "orig_name[type_args]" for unique identification
    orig_name := istr_get(fi_name(func_ni));
    mangled_name : ., mut = orig_name + "[" + type_args + "]";
    mangled_ni := str_intern(mangled_name);
    // Update the cloned AST node's name to the mangled name
    ast_set_a(new_fn_node, mangled_ni);

    // 3. Register new function in g_funcs
    new_fi := g_func_count;
    grow_funcs(new_fi + 1);

    // Use mangled name for unique lookup
    fi_set_name(new_fi, mangled_ni);

    // Clone params: param type info from FuncInfo
    pc := fi_param_count(func_ni);
    fi_set_param_count(new_fi, pc);
    pi : ., mut = 0;
    loop {
        if pi >= pc { break; }
        fi_set_param_type(new_fi, pi, fi_param_type(func_ni, pi));
        pi = pi + 1;
    }

    // Return type (set from original; will be re-checked)
    fi_set_return_type(new_fi, fi_return_type(func_ni));

    // AST node reference
    fi_set_ast_node(new_fi, new_fn_node);

    // Specialized instance has zero generic params (they've been substituted)
    fi_set_generic_count(new_fi, 0);

    g_func_count = new_fi + 1;

    // 4. Cache the new function
    type_args_ni := str_intern(type_args);
    grow_gen_instances(g_gen_instance_count + 1);
    w64(g_gen_instances, g_gen_instance_count * 24, func_ni);
    w64(g_gen_instances, g_gen_instance_count * 24 + 8, type_args_ni);
    w64(g_gen_instances, g_gen_instance_count * 24 + 16, new_fi);
    g_gen_instance_count = g_gen_instance_count + 1;

    // 效应/纯度修正 Task 1：登记实例 → 源（纯度回填用，见 globals.cr 表注）。
    // 注意：不在此处写 fi_set_ispure(new_fi, fi_ispure(func_ni))——本时点（IR 生成期）
    // 源函数还没有真纯度（真纯度只能由全程序 IR 体算，见 checker.cr 头注），
    // 抄过来的是乐观默认值，会把有效应泛型实例错标为纯。实例纯度由其自身体
    // 在 df_state_finalize 算出；源函数纯度 = 实例合取（compute_all_purity 回填）。
    grow_purity_inst(g_purity_inst_count + 1);
    w64(g_purity_inst, g_purity_inst_count * 24, func_ni);
    w64(g_purity_inst, g_purity_inst_count * 24 + 8, type_args_ni);
    w64(g_purity_inst, g_purity_inst_count * 24 + 16, new_fi);
    g_purity_inst_count = g_purity_inst_count + 1;

    // 5. Return new function index
    return new_fi;
}
