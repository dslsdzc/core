// === ir_gen.core ===
// Flat AST to platform-independent IR instruction generation
// (shared IR globals declared in globals.cr)

// (IR globals declared in globals.cr)

// Subgraph-level arena tracking for compile-time size estimation
g_no_auto_arena : int, mut = 0    // 1 while generating arena infrastructure
g_program_has_arena : int, mut = 0 // 1 when the program imports the arena library
g_sg_alloc_total : string, mut    // per-sg: cumulative alloc size
g_sg_alloc_unknown : string, mut  // per-sg: 1 when a size is unknown
g_sg_alloc_cap   : int, mut
g_sg_arena_var   : string, mut    // per-sg: IR var for arena ID
g_sg_arena_var_cap : int, mut
g_ir_source_hash : int, mut
g_ir_source_hash_ready : int, mut

// 切片编译期长度侧表（var -> 字面量长度；-1 = 未知/无记录）。
// IR_SLICE 的字面量界（high−low）在此登记，供解引用处的越界检查
// （pass_before_array_access 的 arr_len_lit）使用，见 F11。
g_ir_slice_lens : string, mut     // [var, len] pairs
g_ir_slice_len_count : int, mut
g_ir_slice_len_cap : int, mut

fn grow_ir_slice_lens(needed: int):
    if needed < g_ir_slice_len_cap:
        return
    nc : ., mut = g_ir_slice_len_cap * 2
    if nc < 8:
        nc = 8
    if nc < needed:
        nc = needed + 8
    nb := alloc(nc * 16)
    cell_copy(g_ir_slice_lens, g_ir_slice_len_cap * 16, nb)
    g_ir_slice_lens = nb
    g_ir_slice_len_cap = nc

fn slice_len_get(var_idx: int) -> int:
    si : ., mut = 0
    loop:
        if si >= g_ir_slice_len_count:
            break
        if cell_load(g_ir_slice_lens, si * 16) == var_idx:
            return cell_load(g_ir_slice_lens, si * 16 + 8)
        si = si + 1
    return -1

fn slice_len_set(var_idx: int, len: int):
    si : ., mut = 0
    loop:
        if si >= g_ir_slice_len_count:
            break
        if cell_load(g_ir_slice_lens, si * 16) == var_idx:
            cell_store(g_ir_slice_lens, si * 16 + 8, len)
            return
        si = si + 1
    if len < 0:
        return
    grow_ir_slice_lens(g_ir_slice_len_count + 1)
    cell_store(g_ir_slice_lens, g_ir_slice_len_count * 16, var_idx)
    cell_store(g_ir_slice_lens, g_ir_slice_len_count * 16 + 8, len)
    g_ir_slice_len_count = g_ir_slice_len_count + 1

// F11 运行时界切片：len 字段编码，
// >= 0 = 字面量长度；<= -2 = 长度 IR 变量（-2-len_var，避开 -1 清除码）；-1 = 已清除/无记录。
fn slice_len_raw_set(var_idx: int, len_code: int):
    si : ., mut = 0
    loop:
        if si >= g_ir_slice_len_count:
            break
        if cell_load(g_ir_slice_lens, si * 16) == var_idx:
            cell_store(g_ir_slice_lens, si * 16 + 8, len_code)
            return
        si = si + 1
    if len_code == -1:
        return
    // 清除无条目 = no-op；负编码（长度变量）允许新增
    grow_ir_slice_lens(g_ir_slice_len_count + 1)
    cell_store(g_ir_slice_lens, g_ir_slice_len_count * 16, var_idx)
    cell_store(g_ir_slice_lens, g_ir_slice_len_count * 16 + 8, len_code)
    g_ir_slice_len_count = g_ir_slice_len_count + 1

// 登记运行时界切片的长度变量；查询返回 len_var（无 -> -1）。
fn slice_len_var_set(var_idx: int, len_var: int):
    if var_idx < 0 || len_var < 0:
        return
    slice_len_raw_set(var_idx, -2 - len_var)

fn slice_len_var_get(var_idx: int) -> int:
    si : ., mut = 0
    loop:
        if si >= g_ir_slice_len_count:
            break
        if cell_load(g_ir_slice_lens, si * 16) == var_idx:
            v := cell_load(g_ir_slice_lens, si * 16 + 8)
            if v <= -2:
                return -2 - v
            return -1
        si = si + 1
    return -1

// 切片长度沿赋值/LET 传播：无条件同步 src 记录到 dst，src 无记录
// 时清除 dst（防非切片赋值后陈旧长度残留导致误检查）。
fn slice_len_copy_to(dst_var: int, src_var: int):
    si : ., mut = 0
    loop:
        if si >= g_ir_slice_len_count:
            break
        if cell_load(g_ir_slice_lens, si * 16) == src_var:
            slice_len_raw_set(dst_var, cell_load(g_ir_slice_lens, si * 16 + 8))
            return
        si = si + 1
    slice_len_raw_set(dst_var, -1)

// 切片解引用检查（运行时界长度）：s1 = idx 变量/字面量，上限 = 长度变量
// （IR_BOUNDS_CHECK ti=1 动态上限，与 emit_string_bounds 同机制）。
// Slice header access. V4 slices carry a two-word header {data_ptr, len}; the
// IR variable holds the header pointer. Functions receive that pointer, so the
// length crosses call boundaries without an ABI change to the value itself.
fn is_slice_hdr(v: int) -> int:
    if v < 0:
        return 0
    return get_type_kind(irv_type(v)) == TYP_SLICE

fn slice_hdr_data(v: int) -> int:
    if is_slice_hdr(v) != 0:
        d := new_ir_var("slice_data", TI_INT)
        emit(IR_LOAD_INDEX, d, v, 0, 0, 0)
        return d
    return v

fn slice_hdr_len(v: int) -> int:
    if is_slice_hdr(v) != 0:
        l := new_ir_var("slice_len", TI_INT)
        emit(IR_LOAD_INDEX, l, v, 0, 1, 0)
        return l
    sl := slice_len_get(v)
    if sl >= 0:
        l := new_ir_var("slice_len", TI_INT)
        emit(IR_CONST, l, sl, 0, 0, TI_INT)
        return l
    return slice_len_var_get(v)

// Convert an array/side-table slice argument into a header slice when the
// callee declares a slice parameter. A header slice passes through unchanged.
fn make_slice_header(data_var: int, len_code: int, len_var: int) -> int:
    elem : ., mut = elem_ti_of(data_var)
    if elem < 0:
        elem = TI_INT
    hdr := new_ir_var("slice_arg", alloc_type(TYP_SLICE, elem, 0))
    track_alloc_array(2)
    emit(IR_ALLOC_ARRAY, hdr, 2, 0, 0, 0)
    emit(IR_STORE_INDEX, -1, hdr, data_var, 0, 0)
    if len_var >= 0:
        emit(IR_STORE_INDEX, -1, hdr, len_var, 1, 0)
        slice_len_var_set(hdr, len_var)
    else if len_code >= 0:
        lc := new_ir_var("slice_len", TI_INT)
        emit(IR_CONST, lc, len_code, 0, 0, TI_INT)
        emit(IR_STORE_INDEX, -1, hdr, lc, 1, 0)
        slice_len_set(hdr, len_code)
    return hdr

fn coerce_slice_arg(v: int) -> int:
    if v < 0:
        return v
    if is_slice_hdr(v) != 0:
        return v
    ti := irv_type(v)
    if get_type_kind(ti) == TYP_ARRAY:
        return make_slice_header(v, get_type_extra(ti), -1)
    sl := slice_len_get(v)
    if sl >= 0:
        return make_slice_header(v, sl, -1)
    slv := slice_len_var_get(v)
    if slv >= 0:
        return make_slice_header(v, -1, slv)
    return v

fn coerce_slice_args(fi: int, ac: int, arg_vars: string):
    fn_node := fi_ast_node(fi)
    if fn_node < 0:
        return
    pc := ast_c(fn_node)
    pn : ., mut = ast_b(fn_node)
    ai : ., mut = 0
    loop:
        if ai >= pc || ai >= ac:
            break
        if pn < 0 || pn >= g_ast_count:
            break
        if ast_kind(pn) == EXPR_PARAM:
            ptn := ast_data(pn)
            if ptn >= 0:
                pti := res_type_node(ptn)
                if get_type_kind(pti) == TYP_SLICE:
                    av := cell_load(arg_vars, ai * 8)
                    if av >= 0:
                        cell_store(arg_vars, ai * 8, coerce_slice_arg(av))
            ai = ai + 1
        pn = pn + 1
        loop:
            if pn >= g_ast_count:
                break
            if ast_kind(pn) == EXPR_PARAM:
                break
            pn = pn + 1

fn emit_slice_bounds(arr_var: int, idx_var: int):
    if arr_var < 0 || idx_var < 0:
        return
    if is_slice_hdr(arr_var) != 0:
        lv := slice_hdr_len(arr_var)
        if lv >= 0:
            emit(IR_BOUNDS_CHECK, -1, idx_var, lv, 0, 1)
        return
    lv := slice_len_var_get(arr_var)
    if lv >= 0:
        emit(IR_BOUNDS_CHECK, -1, idx_var, lv, 0, 1)

fn emit_slice_lit_bounds(arr_var: int, idx_lit: int):
    if arr_var < 0:
        return
    if is_slice_hdr(arr_var) != 0:
        lv := slice_hdr_len(arr_var)
        if lv >= 0:
            t := new_ir_var("_slice_idx", TI_INT)
            emit(IR_CONST, t, idx_lit, 0, 0, TI_INT)
            emit(IR_BOUNDS_CHECK, -1, t, lv, 0, 1)
        return
    lv := slice_len_var_get(arr_var)
    if lv >= 0:
        t := new_ir_var("_slice_idx", TI_INT)
        emit(IR_CONST, t, idx_lit, 0, 0, TI_INT)
        emit(IR_BOUNDS_CHECK, -1, t, lv, 0, 1)

// 数组/切片的编译期长度：TYP_ARRAY 的 extra=size；切片查侧表（字面量界）。
// 未知 -> -1（ext_safety 不发射 IR_BOUNDS_CHECK）。
fn arr_len_lit_of(arr_var: int) -> int:
    if arr_var < 0:
        return -1
    ti := irv_type(arr_var)
    if ti >= 0 && ti < g_type_count && get_type_kind(ti) == TYP_ARRAY:
        return get_type_extra(ti)
    if ti == TI_STR:
        prod := cell_load(g_df_var_producer, arr_var * 8)
        // 读 派生码（不是 40 槽，单槽化后 40 槽 = 类型项引用）；
        // 常量节点的行是原子基行 -> 派生码逐字节 ≡ 单槽化前该槽的混用码。
        if prod >= 0 && cell_load(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_OPCODE) == IR_CONST && sh_dfn_code_of_slots(cell_load(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_TK),
            cell_load(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_AUX)) == TI_STR:
            return istr_len(cell_load(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_S1))
    return slice_len_get(arr_var)

fn emit_string_bounds(arr_var: int, idx_var: int):
    if arr_var < 0 || idx_var < 0 || irv_type(arr_var) != TI_STR:
        return
    len_var := new_ir_var("str_len", TI_INT)
    emit(IR_CALL, len_var, arr_var, 1, str_intern("str_len"), TI_INT)
    emit(IR_BOUNDS_CHECK, -1, idx_var, len_var, 0, 1)

// 字面量下标 + 字符串 -> 运行时边界检查（常量下标路径与 arr_len_lit 两头落空，emit_string_bounds
// 只覆盖变量下标路径，常量下标路径与 arr_len_lit 两头落空，越界且不报错）。
fn emit_string_lit_bounds(arr_var: int, idx_lit: int):
    if arr_var < 0 || irv_type(arr_var) != TI_STR:
        return
    idx_var := new_ir_var("_idx_lit", TI_INT)
    emit(IR_CONST, idx_var, idx_lit, 0, 0, TI_INT)
    emit_string_bounds(arr_var, idx_var)

fn grow_sg_alloc(needed: int):
    if needed < g_sg_alloc_cap:
        return
    nc : ., mut = g_sg_alloc_cap * 2
    if nc < 64:
        nc = 64
    if nc < needed:
        nc = needed + 64
    nb := alloc(nc * 8)
    cell_copy(g_sg_alloc_total, g_sg_alloc_cap * 8, nb)
    g_sg_alloc_total = nb
    nb2 := alloc(nc * 8)
    cell_copy(g_sg_alloc_unknown, g_sg_alloc_cap * 8, nb2)
    g_sg_alloc_unknown = nb2
    g_sg_alloc_cap = nc

fn grow_sg_arena_var(needed: int):
    if needed < g_sg_arena_var_cap:
        return
    nc : ., mut = g_sg_arena_var_cap * 2
    if nc < 64:
        nc = 64
    if nc < needed:
        nc = needed + 64
    nb := alloc(nc * 8)
    cell_copy(g_sg_arena_var, g_sg_arena_var_cap * 8, nb)
    g_sg_arena_var = nb
    g_sg_arena_var_cap = nc

fn sg_alloc_push(kind: int):
    grow_sg_alloc(g_sg_count + 1)
    grow_sg_arena_var(g_sg_count + 1)
    cell_store(g_sg_alloc_total, g_sg_count * 8, 0)
    cell_store(g_sg_alloc_unknown, g_sg_count * 8, 0)
    sg_push(kind)

// Close a split child without adding its bytes to the parent's arena peak.
// The child arena was created by sg_alloc_push; its reset is emitted after the
// SG closes, so uses after the IF merge are outside the region exit.
fn sg_alloc_pop_split():
    if g_sg_count <= 0:
        return
    top := g_sg_count - 1
    arena_var := cell_load(g_sg_arena_var, top * 8)
    sg_pop()
    emit(IR_ARENA_RESET, -1, arena_var, 0, 0, 0)
    region_plan_emit_share_after(top)

// Close a share IF without resetting its slot. The slot stays live and current
// until the consumer SG's reset hook emits IR_ARENA_RESET for it.
fn sg_alloc_pop_share():
    if g_sg_count <= 0:
        return
    sg_pop()

fn sg_alloc_pop():
    top := g_sg_count - 1
    total := cell_load(g_sg_alloc_total, top * 8)
    unk := cell_load(g_sg_alloc_unknown, top * 8)
    arena_var := cell_load(g_sg_arena_var, top * 8)
    // The parent is the SG's recorded parent, not `top - 1`: siblings may have
    // been popped in between, so the high-water neighbor can be a closed slot.
    pi := cell_load(g_sgs, top * ESZ_SG + OFF_SG_PARENT)
    if pi >= 0:
        ptotal := cell_load(g_sg_alloc_total, pi * 8)
        cell_store(g_sg_alloc_total, pi * 8, ptotal + total)
        punk := cell_load(g_sg_alloc_unknown, pi * 8)
        if unk != 0:
            cell_store(g_sg_alloc_unknown, pi * 8, 1)
    sg_pop()
    emit(IR_ARENA_RESET, -1, arena_var, 0, 0, 0)
    region_plan_emit_share_after(top)

fn track_alloc_size(size: int):
    if g_cur_sg >= 0 && str_len(g_sg_alloc_total) > 0:
        prev := cell_load(g_sg_alloc_total, g_cur_sg * 8)
        cell_store(g_sg_alloc_total, g_cur_sg * 8, prev + size)

fn track_alloc_unknown():
    if g_cur_sg >= 0 && str_len(g_sg_alloc_unknown) > 0:
        cell_store(g_sg_alloc_unknown, g_cur_sg * 8, 1)

fn track_alloc_array(count: int):
    if count > 0 && count < 100000:
        track_alloc_size(count * 8 + 8)
    else:
        track_alloc_unknown()

fn track_alloc_struct(name_ni: int):
    si := find_struct_by_name(name_ni)
    if si >= 0:
        track_alloc_size(si_field_count(si) * 8 + 8)
    else:
        track_alloc_unknown()

fn sg_alloc_cur_total() -> int:
    if g_cur_sg < 0:
        return 0
    return cell_load(g_sg_alloc_total, g_cur_sg * 8)

fn sg_alloc_cur_unknown() -> int:
    if g_cur_sg < 0:
        return 0
    return cell_load(g_sg_alloc_unknown, g_cur_sg * 8)

fn sg_alloc_set(total: int, unknown: int):
    if g_cur_sg >= 0:
        cell_store(g_sg_alloc_total, g_cur_sg * 8, total)
        cell_store(g_sg_alloc_unknown, g_cur_sg * 8, unknown)

fn sg_peak_of_current() -> int:
    if g_cur_sg < 0:
        return 0
    if cell_load(g_sg_alloc_unknown, g_cur_sg * 8) != 0:
        return -1
    total := cell_load(g_sg_alloc_total, g_cur_sg * 8)
    if total <= 0:
        return 0
    return total

fn new_ir_var(name: string, type_idx: int) -> int:
    idx := g_ir_var_count
    grow_ir_vars(idx + 1)
    irv_set_name(idx, str_intern(name))
    irv_set_id(idx, idx)
    irv_set_type(idx, type_idx)
    g_ir_var_count = idx + 1
    return idx

// ── 可选运行期表示──
// 事实：`Some(1)`/`None` 走 IR_MAKE_ENUM 对象（[tag][payload…]），而 `T?` 槽里的
// 裸值仍是裸值 -> 同一 `T?` 值两种表示；`Some` 臂的携带值解包（IR_LOAD_FIELD fi+1）
// 把裸值当对象解引用 -> 双路径 SIGSEGV（check/build rc=0 零诊断）。
// 机制（纯 IR：无新 opcode、无 ABI/帧布局改动 -> ELF 后端与解释器天然同源）：
// 每个可选槽（局部/形参/调用结果）配一个表示位 IR 变量（普通 int 局部，运行期值：
// 0 = 裸值、1 = 装箱）。写点置位（静态已知 -> 常量；源已配表示位 -> 拷贝），解包点
// 分派（`match` 的 Some/None 臂、`?`）：
//   · 裸值（0）-> 槽值即携带值（Some 臂直取、不读 tag；None 臂不命中）
//   · 装箱（≠0）-> 既有 tag 分派 + 字段 fi+1 取携带值（逐字不变）
// 跨函数（返回/形参）用隐藏全局信道（纯 IR：返回点写/调用点读、调用点写/被调序言读）。
// 未覆盖情形（结构体字段/数组元素/全局槽/match 结果/惰性 thunk）：不配表示位 -> 解包走
// 既有装箱假定，响亮失败或既有正确值，不新增错误值且不报错(each shape is handled conservatively)。
// g_optrep_on 关（AST 无 EXPR_OPTIONAL 且无 `Some`/`None`）-> 本范围零足迹（发射路径逐字节不变）。

// 表示码常量 OE_BARE/OE_BOXED 声明在 globals.cr。负值文件级常量放在本文件
// 会读成 0 且不报错; see the note there.

fn grow_ir_var_rep(needed: int):
    if needed < g_ir_var_rep_cap:
        return
    nc : ., mut = g_ir_var_rep_cap * 2
    if nc < 64:
        nc = 64
    if nc < needed:
        nc = needed + 64
    nb := alloc(nc * 8)
    cell_copy(g_ir_var_rep, g_ir_var_rep_cap * 8, nb)
    // 新槽填 -1（哨兵 = 无表示位），alloc 零初始化，不填则未写槽被读成
    // 表示位 var 0（每个值都被判成有表示位，产生错误值且不报错；for example, the `None` initial value
    // 的表示位被读成 var0 的当前值 0 = 裸值）。
    z : ., mut = g_ir_var_rep_cap
    loop:
        if z >= nc:
            break
        cell_store(nb, z * 8, -1)
        z = z + 1
    g_ir_var_rep = nb
    g_ir_var_rep_cap = nc

// 槽的表示位变量索引（-1 = 无表示位 = 非可选槽 / 未覆盖情形 / 本编译单元未启用）。
// 检查走 cap（int 全局，默认 0）而非 str_len(base)，base 未分配时是空串/空指针，
// 未初始化的 str_len 即 SIGSEGV（file paths, including per-function main.cr and the .cir cache, do not go through
// 批量入口的复位 -> 本函数必须自检查）。
fn irv_rep(var_idx: int) -> int:
    if var_idx < 0:
        return -1
    if g_ir_var_rep_cap <= 0:
        return -1
    if var_idx >= g_ir_var_rep_cap:
        return -1
    return cell_load(g_ir_var_rep, var_idx * 8)

fn irv_set_rep(var_idx: int, rep_var: int):
    if var_idx < 0:
        return
    grow_ir_var_rep(var_idx + 1)
    cell_store(g_ir_var_rep, var_idx * 8, rep_var)

// 置表示位：enc >= 0 -> 从该表示位槽拷贝；OE_BARE/OE_BOXED -> 直接常量写。
fn emit_rep_set(rep_var: int, enc: int):
    if rep_var < 0:
        return
    if enc == oe_bare():
        emit(IR_CONST, rep_var, 0, 0, 0, TI_INT)
        return
    if enc == oe_boxed():
        emit(IR_CONST, rep_var, 1, 0, 0, TI_INT)
        return
    if enc >= 0:
        emit(IR_STORE, -1, rep_var, enc, 0, 0)

// 给可选槽配表示位变量（初始值 = 1 装箱 = 既有语义）；非可选/未启用 -> -1。
fn opt_rep_slot(ti: int, name: string) -> int:
    if g_optrep_on == 0:
        return -1
    if ti < 0 || ti >= g_type_count:
        return -1
    if get_type_kind(ti) != TYP_OPTIONAL:
        return -1
    rv := new_ir_var(name + "_rep", TI_INT)
    emit(IR_CONST, rv, 1, 0, 0, TI_INT)
    return rv

// 全局槽的声明类型是否可选（globals 无表示位 -> 视作为未覆盖情形；照声明区分裸/装箱假定）。
fn global_decl_optional(name_ni: int) -> int:
    gi : ., mut = 0
    loop:
        if gi >= g_global_let_count:
            break
        lnode := cell_load(g_global_lets, gi * 8)
        if ast_a(lnode) == name_ni && global_decl_in_ctx(lnode):
            tn := ast_b(lnode)
            if tn >= 0 && res_type_node(tn) >= 0:
                if get_type_kind(res_type_node(tn)) == TYP_OPTIONAL:
                    return 1
            return 0
        gi = gi + 1
    if g_cur_lib >= 0:
        gi = 0
        loop:
            if gi >= g_global_let_count:
                break
            lnode2 := cell_load(g_global_lets, gi * 8)
            if ast_a(lnode2) == name_ni:
                tn2 := ast_b(lnode2)
                if tn2 >= 0 && res_type_node(tn2) >= 0:
                    if get_type_kind(res_type_node(tn2)) == TYP_OPTIONAL:
                        return 1
                return 0
            gi = gi + 1
    return 0

// 被调方返回类型是否可选。判断依据是返回类型节点（`EXPR_FN.type_val`），不是
// `fi_return_type`：后者是 parser 存的裸类型码，而 `T?` 的类型节点 `type_val` = 0
// -> is read as an int row and the test is always false. A bare return that does not write the return channel, plus a call site that does not read it,
// 回落装箱假定 -> `fn g() -> int? { return 5; }` 的调用点解包仍崩）。
fn callee_ret_optional(func_ni: int) -> int:
    if func_ni < 0:
        return 0
    cfi := find_func(func_ni)
    if cfi < 0:
        return 0
    cfn := fi_ast_node(cfi)
    if cfn < 0 || ast_kind(cfn) != EXPR_FN:
        return 0
    rtn := ast_type_val(cfn)
    if rtn < 0:
        return 0
    rti := res_type_node(rtn)
    if rti < 0 || rti >= g_type_count:
        return 0
    if get_type_kind(rti) == TYP_OPTIONAL:
        return 1
    return 0

// Declared `dex?` return row for a call result. The payload can be bare
// (scaled) or boxed; the declaration row is what later match/inner reads use
// to recover the payload form. -1 = not a dex-optional return.
fn callee_ret_dex_opt_decl(func_ni: int) -> int:
    if func_ni < 0:
        return -1
    cfi := find_func(func_ni)
    if cfi < 0:
        return -1
    cfn := fi_ast_node(cfi)
    if cfn < 0 || ast_kind(cfn) != EXPR_FN:
        return -1
    rtn := ast_type_val(cfn)
    if rtn < 0 || dex_opt_type_node(rtn) == 0:
        return -1
    return res_type_node(rtn)

// ── 容量阶段 T2：可选聚合槽的存储边界规范化（写点装箱）──
// 法则：可选聚合槽（结构体字段 / 数组·切片元素 / 元组元素 / 枚举携带值 / 全局槽）任何时刻恒持
// 装箱值（Some 对象）或 None；裸 T 值在写点装箱。读侧零改动（既有装箱假定）。
// 局部/形参/返回/调用结果不走本规则。
// 零足迹：目标槽类型不可选 -> 本组函数恒不发射任何 IR（非可选程序逐字节不变）。
// 未覆盖情形（登记）：指针写 `IR_STORE_PTR`，同一站点同时服务局部与聚合槽，装箱会与局部
// 表示位冲突(boxing produces a wrong value without a diagnostic)；元组·数组字面量的非 ident/调用元素。

// 槽声明类型侧表（var -> 声明类型索引；-1 = 无注解/未知）。仅进程内状态，零布局变更。
// 内容（IR var 索引 -> 类型索引）由声明信息写入（LET 注解 / 形参类型节点），读点 = 元素写。
fn grow_ir_var_decl(needed: int):
    if needed < g_ir_var_decl_cap:
        return
    nc : ., mut = g_ir_var_decl_cap * 2
    if nc < 64:
        nc = 64
    if nc < needed:
        nc = needed + 64
    nb := alloc(nc * 8)
    cell_copy(g_ir_var_decl_ti, g_ir_var_decl_cap * 8, nb)
    z : ., mut = g_ir_var_decl_cap
    loop:
        if z >= nc:
            break
        cell_store(nb, z * 8, -1)
        z = z + 1
    g_ir_var_decl_ti = nb
    g_ir_var_decl_cap = nc
fn irv_decl_ti(v: int) -> int:
    if v < 0:
        return -1
    if g_ir_var_decl_cap <= 0:
        return -1
    if v >= g_ir_var_decl_cap:
        return -1
    return cell_load(g_ir_var_decl_ti, v * 8)
fn irv_set_decl_ti(v: int, ti: int):
    if v < 0 || ti < 0:
        return
    grow_ir_var_decl(v + 1)
    cell_store(g_ir_var_decl_ti, v * 8, ti)

// 目标槽类型是否可选（未知/越界 -> 0 = 不装箱）
fn ti_is_optional(ti: int) -> int:
    if ti < 0:
        return 0
    if ti >= g_type_count:
        return 0
    if get_type_kind(ti) == TYP_OPTIONAL:
        return 1
    return 0

// 槽（IR var）声明类型：声明侧表优先，否则运行期类型
fn slot_decl_ti(v: int) -> int:
    d := irv_decl_ti(v)
    if d >= 0:
        return d
    return irv_type(v)

// 声明类型 -> 数组/切片元素类型（-1 = 非数组/切片）
fn elem_ti_of_decl(ti: int) -> int:
    if ti < 0:
        return -1
    if ti >= g_type_count:
        return -1
    k := get_type_kind(ti)
    if k == TYP_ARRAY || k == TYP_SLICE:
        return get_type_data(ti)
    return -1

// 数组/切片元素类型（-1 = 非数组/切片或未知）
fn elem_ti_of(arr_var: int) -> int:
    return elem_ti_of_decl(slot_decl_ti(arr_var))

// 结构体字段声明类型（field_node = EXPR_FIELD 目标节点；checker 写入 ast_c = 结构体名 ni；
// 数字元组下标形（ast_type_val > 0）不是结构体字段 -> 不判）
fn field_ti_of_node(field_node: int, fi: int) -> int:
    if field_node < 0 || fi < 0:
        return -1
    if ast_type_val(field_node) > 0:
        return -1
    si := find_struct(ast_c(field_node))
    if si < 0:
        return -1
    return res_type_node(si_field_type_node(si, fi))

// 结构体行字段声明类型（结构体字面量写点用；si = 行，来自 find_struct_by_name）
fn struct_row_field_ti(si: int, fi: int) -> int:
    if si < 0 || fi < 0:
        return -1
    return res_type_node(si_field_type_node(si, fi))

// 全局槽声明类型（-1 = 非全局/无类型节点）
// Does this global declaration belong to the library currently being
// generated? g_cur_lib < 0 keeps the legacy name-only behaviour.
fn global_decl_in_ctx(lnode: int) -> bool:
    if g_cur_lib < 0:
        return true
    return lib_of_node(lnode) == g_cur_lib

fn global_decl_owner(name_ni: int) -> int:
    gi : ., mut = 0
    loop:
        if gi >= g_global_let_count:
            return -1
        lnode := cell_load(g_global_lets, gi * 8)
        if ast_a(lnode) == name_ni:
            return lib_of_node(lnode)
        gi = gi + 1
    return -1

fn global_decl_ti(name_ni: int) -> int:
    gi : ., mut = 0
    loop:
        if gi >= g_global_let_count:
            break
        lnode := cell_load(g_global_lets, gi * 8)
        if ast_a(lnode) == name_ni && global_decl_in_ctx(lnode):
            tn := ast_b(lnode)
            if tn >= 0:
                return res_type_node(tn)
            return -1
        gi = gi + 1
    if g_cur_lib >= 0:
        gi = 0
        loop:
            if gi >= g_global_let_count:
                break
            lnode2 := cell_load(g_global_lets, gi * 8)
            if ast_a(lnode2) == name_ni:
                tn2 := ast_b(lnode2)
                if tn2 >= 0:
                    return res_type_node(tn2)
                return -1
            gi = gi + 1
    return -1

// 枚举变体携带值声明类型（-1 = 非用户枚举构造器/未知）
fn enum_payload_ti(name_ni: int, pos: int) -> int:
    si := find_gsym(name_ni)
    if si < 0:
        return -1
    ei := find_enum_row_of(sym_type(si))
    if ei < 0:
        return -1
    vi : ., mut = 0
    loop:
        if vi >= ei_variant_count(ei):
            return -1
        if ei_variant_name(ei, vi) == name_ni:
            return res_type_node(ei_variant_type_node(ei, vi, pos))
        vi = vi + 1
    return -1

// ── 聚合读结果槽的声明信息形式──────────────────────
// 聚合槽的规范存储形式恒为精确（scaled）（apx 阶段不变量聚合类型不存在 apx 形式；写点汇聚点
// `dex_slot_norm:1059` 与 :2725/:2688/:2774/:2902 各写点均按此规范化）-> 只要声明信息是 dex
// （类型节点 `TY_DEX`），读槽就应当定型 `TI_DEX_S`；其余形态一律保持 `TI_INT`（零足迹：
// 非 dex 程序逐字节不变）。
// 零 alloc（GC12′）：只做节点判（`ast_kind(tn)==0 && ast_type_val(tn)==TY_DEX`）与
// 纯表读（`elem_ti_of_decl`/`get_type_kind`/`get_type_data`），不调 `res_type_node`/
// `alloc_type`（那会新增可能 alloc 的站点，违反暖缓存不变式）。
// 覆盖范围(current coverage) = 结构体字段读 / 数组·切片元素读（元素 ti 可由数组型取得）/ match 臂携带值绑定。
// 未覆盖情形（登记，见计划 10） = 元组数字下标· match 结果槽
// · 泛型字段/元素· `IR_SLICE` 产物的
// 元素读（切片 var 的 IR 型恒 `TI_INT`，元素形式无处寄存）。
fn agg_read_form_is_dex(tn: int) -> int:
    if tn < 0:
        return 0
    if ast_kind(tn) != 0:
        return 0
    if ast_type_val(tn) == TY_DEX:
        return 1
    return 0

// char 槽存的是 intern index（无 tag）。读点必须保持 TI_CHAR，不能被
// 标成 TI_INT：tagged-int 路径会把无 tag 的值右移一位。
fn agg_read_form_is_char(tn: int) -> int:
    if tn < 0:
        return 0
    if ast_kind(tn) != 0:
        return 0
    if ast_type_val(tn) == TY_CHAR:
        return 1
    return 0

// 结构体字段读（`EXPR_FIELD`）。数字元组下标的元素类型行由 checker 写入
// ast_c：元组槽恒为精确形式，dex 元素必须按 TI_DEX_S 读取，否则 tagged-int
// 路径会把无 tag 的缩放整数右移一位（7_000_000 -> 3_500_000）。
fn agg_field_read_form(field_node: int, fi: int) -> int:
    if field_node < 0 || fi < 0:
        return TI_INT
    if ast_type_val(field_node) > 0:
        et := ast_c(field_node)
        if et == TI_DEX || et == TI_DEX_S:
            return TI_DEX_S
        if et == TI_CHAR:
            return TI_CHAR
        return TI_INT
    si := find_struct(ast_c(field_node))
    if si < 0:
        return TI_INT
    ftn := si_field_type_node(si, fi)
    if agg_read_form_is_dex(ftn) != 0:
        return TI_DEX_S
    if dex_opt_type_node(ftn) != 0:
        return TI_DEX_S
    if agg_read_form_is_char(ftn) != 0:
        return TI_CHAR
    return TI_INT

// 数组/切片元素读：元素 ti 由数组 var 的型取得（纯表读）；`TI_DEX`（apx 声明形态的
// 元素 ti）与 `TI_DEX_S` 都归一到精确读槽（聚合存储 = scaled）。
fn agg_elem_read_form(arr_var: int) -> int:
    et := elem_ti_of_decl(slot_decl_ti(arr_var))
    if et == TI_DEX || et == TI_DEX_S:
        return TI_DEX_S
    if et == TI_CHAR:
        return TI_CHAR
    return TI_INT

// match 臂携带值绑定读（`EXPR_ENUMPAT`：a=变体名 ni、b=首子模式、c=子模式数）
fn agg_payload_read_form(pat_node: int, pos: int) -> int:
    if pat_node < 0 || pos < 0:
        return TI_INT
    name_ni := ast_a(pat_node)
    si := find_gsym(name_ni)
    if si < 0:
        return TI_INT
    ei := find_enum_row_of(sym_type(si))
    if ei < 0:
        return TI_INT
    vi : ., mut = 0
    loop:
        if vi >= ei_variant_count(ei):
            return TI_INT
        if ei_variant_name(ei, vi) == name_ni:
            tn := ei_variant_type_node(ei, vi, pos)
            if agg_read_form_is_dex(tn) != 0:
                return TI_DEX_S
            if agg_read_form_is_char(tn) != 0:
                return TI_CHAR
            return TI_INT
        vi = vi + 1
    return TI_INT

// 枚举携带值的声明行（仅 `T?` 且内层 dex；-1 = 不登记）。用于外层 match 的
// 载荷变量：内层再 match 时，`dex_opt_slot_ti(irv_decl_ti(...))` 才能识别它。
fn agg_payload_decl_ti(pat_node: int, pos: int) -> int:
    if pat_node < 0 || pos < 0:
        return -1
    name_ni := ast_a(pat_node)
    si := find_gsym(name_ni)
    if si < 0:
        return -1
    ei : ., mut = find_enum_row_of(sym_type(si))
    if ei < 0:
        return -1
    vi : ., mut = 0
    loop:
        if vi >= ei_variant_count(ei):
            return -1
        if ei_variant_name(ei, vi) == name_ni:
            tn := ei_variant_type_node(ei, vi, pos)
            if dex_opt_type_node(tn) != 0:
                return res_type_node(tn)
            return -1
        vi = vi + 1
    return -1

// 元素表达式（元组/数组字面量的元素槽无声明信息）的可选性：保守 = 不可选 -> 不装箱
// 覆盖范围 = ident（声明侧表）/ 调用（被调返回类型可选）；其余形态登记为未覆盖情形。
fn elem_node_optional(node: int) -> int:
    if node < 0:
        return 0
    k := ast_kind(node)
    if k == EXPR_IDENT:
        lv := find_local(ast_int_val(node))
        if lv >= 0:
            return ti_is_optional(slot_decl_ti(lv))
        return 0
    if k == EXPR_CALL:
        ni := ast_a(node)
        fi2 : ., mut = find_func(ni)
        if fi2 >= 0:
            return callee_ret_optional(ni)
        return 0
    return 0

// (A) T3：元素表达式的可选感知元素类型（-1 = 不可选/未知情形）。
// 字面量/切片两站点的声明信息登记用。调用点必须已判 `g_optrep_on`，Some/None/调用
// 三支会 `alloc_type`（零足迹教训：新增类型查询前先核是否 alloc）。
//   `Some(x)` / `None`（关键字形）-> `T?`（内层此处不可得 -> TI_UNIT 占位；`ti_is_optional`
//   只看 kind -> 写点装箱判定成立）；`ident`（声明信息可选）-> 其声明类型；`call`（返回可选）
//   -> `T?` 占位；其余 -> -1（不可选类型）。
fn elem_ti_of_node(node: int) -> int:
    if node < 0:
        return -1
    k := ast_kind(node)
    if k == EXPR_ENUM_CONSTRUCTOR:
        nm := istr_get(ast_a(node))
        if str_eq(nm, "Some") != 0 || str_eq(nm, "None") != 0:
            return alloc_type(TYP_OPTIONAL, TI_UNIT, 0)
        return -1
    if k == EXPR_IDENT:
        lv := find_local(ast_int_val(node))
        if lv >= 0:
            dti := slot_decl_ti(lv)
            if ti_is_optional(dti) != 0:
                return dti
        return -1
    if k == EXPR_CALL:
        ni := ast_a(node)
        if find_func(ni) >= 0 && callee_ret_optional(ni) != 0:
            return alloc_type(TYP_OPTIONAL, TI_UNIT, 0)
        return -1
    return -1

// 装箱体（静态）：obj = Some(v)（无新 opcode；形态照既有 EXPR_ENUM_CONSTRUCTOR 发射：
// IR_MAKE_ENUM 的 s1 = 变体名索引、携带值经 IR_STORE_FIELD 存 fi+1；tag 值 = 名索引）
fn emit_box_some(val_var: int) -> int:
    obj := new_ir_var("box", TI_INT)
    emit(IR_MAKE_ENUM, obj, str_intern("Some"), 1, 0, 0)
    emit(IR_STORE_FIELD, -1, obj, val_var, 1, 0)
    return obj

// 写点规范化（按可选性标志）：不可选 -> 原样（零 IR）；已装箱 -> 原样；
// 静态裸值 -> 直接装箱；源槽带表示位 -> 运行期条件装箱（裸则装、装箱则原样）。
fn box_for_slot_flag(val_node: int, val_var: int, is_opt: int) -> int:
    if val_var < 0:
        return val_var
    if is_opt == 0:
        return val_var
    enc := rep_enc_of_expr(val_node, val_var)
    if enc == oe_boxed():
        return val_var
    if enc == oe_bare():
        return emit_box_some(val_var)
    dest := new_ir_var("boxed", TI_INT)
    bare_lbl := new_label()
    keep_lbl := new_label()
    end_lbl := new_label()
    zb := new_ir_var("_bz", TI_INT)
    emit(IR_CONST, zb, 0, 0, 0, TI_INT)
    isb := new_ir_var("box_isbare", TI_INT)
    emit(IR_BINARY, isb, enc, zb, OP_EQ, 0)
    emit_cond_match(isb, keep_lbl, bare_lbl)
    emit(IR_LABEL, -1, bare_lbl, 0, 0, 0)
    boxv := emit_box_some(val_var)
    emit(IR_STORE, -1, dest, boxv, 0, 0)
    emit(IR_JUMP, -1, end_lbl, 0, 0, 0)
    emit(IR_LABEL, -1, keep_lbl, 0, 0, 0)
    emit(IR_STORE, -1, dest, val_var, 0, 0)
    emit(IR_LABEL, -1, end_lbl, 0, 0, 0)
    return dest

// 写点规范化（按目标槽类型）
fn box_for_optional_slot(val_node: int, val_var: int, slot_ti: int) -> int:
    return box_for_slot_flag(val_node, val_var, ti_is_optional(slot_ti))

// 值表达式的静态表示判定（解包侧判表示的另一半：写点置位的入参）。
// 返回：>= 0 = 从该表位槽拷贝（源值自身已配表示位：可选局部/形参/调用结果）；
//   OE_BARE = 静态裸值（T 值注入 `T?`：字面量/算术/解包结果/非可选槽/聚合字面量…）；
//   OE_BOXED = 静态装箱（`Some`/`None`）或未覆盖情形回落（字段/下标/match 结果/
//   惰性 thunk/未识别形态），回落取装箱 = 之前的既有语义，绝不新造产生错误值且不报错。
fn rep_enc_of_expr(node: int, val_var: int) -> int:
    if val_var >= 0:
        rv := irv_rep(val_var)
        if rv >= 0:
            return rv
    if node < 0:
        return oe_boxed()
    k := ast_kind(node)
    if k == EXPR_BLOCK:
        // An if branch is a block; its representation is the last value's, not
        // the default boxed encoding.
        stmt_start := ast_a(node)
        stmt_count := ast_b(node)
        if stmt_count > 0:
            last : ., mut = cell_load(g_block_stmts, (stmt_start + stmt_count - 1) * 8)
            return rep_enc_of_expr(last, val_var)
        return oe_boxed()
    if k == EXPR_ENUM_CONSTRUCTOR:
        nm := istr_get(ast_a(node))
        if str_eq(nm, "Some") != 0 || str_eq(nm, "None") != 0:
            return oe_boxed()
        return oe_bare()  // 用户枚举变体 = T 值（对象指针即携带值）
    if k == EXPR_INT || k == EXPR_BOOL || k == EXPR_DEX || k == EXPR_STRING:
        return oe_bare()
    if k == EXPR_CHAR:
        return oe_bare()
    if k == EXPR_BINARY || k == EXPR_UNARY || k == EXPR_AS:
        return oe_bare()
    if k == EXPR_TRY:
        return oe_bare()
    // `?` 解包结果 = T 值
    if k == EXPR_STRUCT || k == EXPR_ARRAY || k == EXPR_TUPLE:
        return oe_bare()
    if k == EXPR_IDENT:
        ni := ast_int_val(node)
        if find_local(ni) >= 0:
            return oe_bare()
        // 无表示位（上方已排除可选槽）= 非可选槽
        gv := find_global_ctx(ni, node)
        if gv >= 0:
            if global_optional_ctx(ni, node) != 0:
                return oe_boxed()
            return oe_bare()
        return oe_bare()  // 枚举裸变体等 T 值
    return oe_boxed()

// 操作数是否确定可选，保守触发范围，纯节点/表读、零 alloc_type
// (same pattern as `rep_enc_of_expr` / `elem_ti_of_node`）：
//   1 var 带表示位（可选槽/形参/调用结果）；2 `Some`/`None` 构造子；3 可选声明信息（局部槽型 / 全局）。
// 非可选一律 0 -> 比较走原路径（产物零变化 = 条目 2 的第 5 条判断）。
fn opt_cmp_optish(node: int, var: int) -> int:
    if var >= 0 && irv_rep(var) >= 0:
        return 1
    if node < 0:
        return 0
    k := ast_kind(node)
    if k == EXPR_ENUM_CONSTRUCTOR:
        nm := istr_get(ast_a(node))
        if str_eq(nm, "Some") != 0 || str_eq(nm, "None") != 0:
            return 1
        return 0
    if k == EXPR_IDENT:
        ni := ast_int_val(node)
        lv := find_local(ni)
        if lv >= 0:
            if ti_is_optional(slot_decl_ti(lv)) != 0:
                return 1
            return 0
        gv := find_global(ni)
        if gv >= 0 && global_decl_optional(ni) != 0:
            return 1
        return 0
    // 解引用可选指针：解引用结果不配表示位（`ir_gen.cr` UOP_DEREF 只发 IR_DEREF），
    // 但 INV-1 保证取址的可选槽恒装箱-> 所指即装箱对象（`match *p` 走同一假定）。
    if k == EXPR_UNARY && ast_c(node) == UOP_DEREF:
        if var >= 0 && ti_is_optional(irv_type(var)) != 0:
            return 1
        return 0
    return 0

// 比较点的有效表示 = `rep_enc_of_expr` + 一条解引用规则，
// 解引用可选指针的槽 -> 装箱对象（INV-1；`rep_enc_of_expr` 对 EXPR_UNARY 按 OE_BARE
// 回落会把装箱对象当裸值 -> 必须在此覆盖）。
fn opt_cmp_enc(node: int, var: int) -> int:
    if node >= 0 && ast_kind(node) == EXPR_UNARY && ast_c(node) == UOP_DEREF:
        if var >= 0 && ti_is_optional(irv_type(var)) != 0:
            return oe_boxed()
    return rep_enc_of_expr(node, var)

// 装箱对象的 (absent, payload) 提取，tag == "None" -> (1, 0)；
// 否则 (0, 字段1)。字段读只在非 None 分支发射（None 对象无携带值字段 -> 避免越界读）。
fn opt_cmp_extract_boxed(var: int, out_absent: int, out_val: int, zero: int):
    tag := new_ir_var("otag", TI_INT)
    emit(IR_LOAD_ENUM_TAG, tag, var, 0, 0, 0)
    nv := new_ir_var("onone", TI_INT)
    emit(IR_CONST, nv, str_intern("None"), 0, 0, TI_INT)
    isnone := new_ir_var("isnone", TI_INT)
    emit(IR_BINARY, isnone, tag, nv, OP_EQ, 0)
    none_lbl := new_label()
    some_lbl := new_label()
    xend_lbl := new_label()
    emit_cond_match(isnone, some_lbl, none_lbl)
    emit(IR_LABEL, -1, none_lbl, 0, 0, 0)
    one := new_ir_var("_o1", TI_INT)
    emit(IR_CONST, one, 1, 0, 0, TI_INT)
    emit(IR_STORE, -1, out_absent, one, 0, 0)
    emit(IR_STORE, -1, out_val, zero, 0, 0)
    emit(IR_JUMP, -1, xend_lbl, 0, 0, 0)
    emit(IR_LABEL, -1, some_lbl, 0, 0, 0)
    emit(IR_STORE, -1, out_absent, zero, 0, 0)
    pti : ., mut = TI_INT
    if var >= 0:
        pti = irv_type(var)
    fv := new_ir_var("opay", pti)
    emit(IR_LOAD_FIELD, fv, var, 0, 1, 0)
    emit(IR_STORE, -1, out_val, fv, 0, 0)
    emit(IR_LABEL, -1, xend_lbl, 0, 0, 0)

// 归一为 (absent, payload) 二元组（写进调用点预建的 out 槽），
//   裸（OE_BARE）   -> (0, 槽值)；装箱（OE_BOXED）-> 见 `opt_cmp_extract_boxed`；
//   运行期表示位（≥0）-> 分支判裸/装箱（裸 -> (0, 槽值)）。
fn opt_cmp_norm(node: int, var: int, out_absent: int, out_val: int):
    enc := opt_cmp_enc(node, var)
    zero := new_ir_var("_oz", TI_INT)
    emit(IR_CONST, zero, 0, 0, 0, TI_INT)
    if enc == oe_bare():
        emit(IR_STORE, -1, out_absent, zero, 0, 0)
        if var >= 0:
            emit(IR_STORE, -1, out_val, var, 0, 0)
        return
    if enc >= 0:
        bare_lbl := new_label()
        boxed_lbl := new_label()
        nend_lbl := new_label()
        isb := new_ir_var("rep_isbare", TI_INT)
        emit(IR_BINARY, isb, enc, zero, OP_EQ, 0)
        emit_cond_match(isb, boxed_lbl, bare_lbl)
        emit(IR_LABEL, -1, bare_lbl, 0, 0, 0)
        emit(IR_STORE, -1, out_absent, zero, 0, 0)
        if var >= 0:
            emit(IR_STORE, -1, out_val, var, 0, 0)
        emit(IR_JUMP, -1, nend_lbl, 0, 0, 0)
        emit(IR_LABEL, -1, boxed_lbl, 0, 0, 0)
        opt_cmp_extract_boxed(var, out_absent, out_val, zero)
        emit(IR_LABEL, -1, nend_lbl, 0, 0, 0)
        return
    opt_cmp_extract_boxed(var, out_absent, out_val, zero)

fn emit(opcode: int, dest: int, src1: int, src2: int, src3: int, type_kind: int):
    // Build linear IR (.ccr) — consumed by x86-64 backend
    idx := g_ir_instr_count
    grow_ir_instrs(idx + 1)
    iri_set_op(idx, opcode)
    iri_set_dest(idx, dest)
    iri_set_s1(idx, src1)
    iri_set_s2(idx, src2)
    iri_set_s3(idx, src3)
    // 类型信息单源 = DFNode 的（项, 辅码）两槽。
    // 本处是唯一拆分点：同一次 sh_tk_split 同时喂 DFNode 两槽与 iri_tk 的派生码
    // （sh_dfn_code_of_slots），既无第二真源，也不可能两处漂移。
    sh_tk_split(opcode, type_kind)
    iri_set_tk(idx, sh_dfn_code_of_slots(g_sh_slot_term, g_sh_slot_aux))
    g_ir_instr_count = idx + 1
    // Build dataflow graph (.cir) in parallel
    // 拆分时点 = emit 期（不得后移到 save 前：快照在 IR 生成期逐函数写 -> 后填
    // 必然冷/暖分歧）。代价 = 每 emit 一次分类查询（非类型 op = 几次整数比较即
    // 返回；类型信息 op = sh_term_of_ti 的原生快路径/桥接缓存)。
    df_create_node(opcode, dest, src1, src2, src3, g_sh_slot_term, g_sh_slot_aux)

fn new_label() -> int:
    lbl := g_next_label
    g_next_label = g_next_label + 1
    return lbl

// ── v10 semantic CASE model helpers ──────────────────────────────────────
// The model is a flat 24B-row buffer with the same layout as the wire CASE
// table, except `target` is the IR body label number (not a NOD id). A match
// reserves its rows before emitting arm bodies so nested matches append after
// the outer range; each target label is recorded once its body label exists.
// ccr_lower resolves labels to NOD ids and builds the wire table; ir_gen never
// writes g_ccr_case.
fn grow_lat_case(needed: int):
    if needed < g_lat_case_cap:
        return
    nc : ., mut = g_lat_case_cap * 2
    if nc < 16:
        nc = 16
    if nc < needed:
        nc = needed + 16
    nb := alloc(nc * CCR_V10_CASE_DISK)
    cell_copy(g_lat_case, g_lat_case_cap * CCR_V10_CASE_DISK, nb)
    g_lat_case = nb
    g_lat_case_cap = nc

fn lat_case_append(value: int, kind: int, str_index: int, target_label: int, flags: int) -> int:
    idx := g_lat_case_count
    grow_lat_case(idx + 1)
    base := idx * CCR_V10_CASE_DISK
    cell_store(g_lat_case, base + CCR_CASE_VALUE, value)
    cell_store32(g_lat_case, base + CCR_CASE_KIND, kind)
    cell_store32(g_lat_case, base + CCR_CASE_STR, str_index)
    cell_store32(g_lat_case, base + CCR_CASE_TARGET, target_label)
    cell_store32(g_lat_case, base + CCR_CASE_FLAGS, flags)
    g_lat_case_count = idx + 1
    return idx

fn lat_case_set_target(idx: int, label: int):
    if idx < 0 || idx >= g_lat_case_count:
        return
    cell_store32(g_lat_case, idx * CCR_V10_CASE_DISK + CCR_CASE_TARGET, label)

// One nonzero-test decision node: false is CASE 0, true is DEFAULT. If the true
// target is next, the backend emits test/je to false and falls through to true;
// if the false target is next, it emits test/jne to true and falls through to
// false. Either way there is no explicit unconditional jump.
fn emit_cond_match(cond_var: int, false_lbl: int, true_lbl: int):
    case_base : ., mut = g_lat_case_count
    lat_case_append(0, CCR_CASE_KIND_VALUE, -1, false_lbl, 0)
    lat_case_append(0, CCR_CASE_KIND_DEFAULT, -1, true_lbl, 0)
    emit(IR_MATCH, -1, cond_var, case_base, 2, 0)
    g_cir_has_match = 1

fn bind_local(name_idx: int, var_idx: int):
    grow_ir_locals(g_ir_local_count + 1)
    cell_store(g_ir_locals, g_ir_local_count  * 16, name_idx)
    cell_store(g_ir_locals, g_ir_local_count  * 16 + 8, var_idx)
    g_ir_local_count = g_ir_local_count + 1

fn find_local(name_idx: int) -> int:
    i : ., mut = g_ir_local_count - 1
    loop:
        if i < 0:
            return -1
        if cell_load(g_ir_locals, i * 16) == name_idx:
            return cell_load(g_ir_locals, i * 16 + 8)
        i = i - 1
    return -1

// Run a lookup under the library that owns the referenced AST node. The graph
// is generated with g_cur_lib unset, so collisions must be resolved at the
// specific identifier/pattern site instead of for the whole function.
fn ir_ctx_lib(node: int) -> int:
    if node < 0:
        return -1
    return lib_of_node(node)

fn find_global_ctx(name_idx: int, node: int) -> int:
    saved := g_cur_lib
    g_cur_lib = ir_ctx_lib(node)
    r := find_global(name_idx)
    g_cur_lib = saved
    return r

fn find_global_const_ctx(name_idx: int, node: int) -> int:
    saved := g_cur_lib
    g_cur_lib = ir_ctx_lib(node)
    r := find_global_const_node(name_idx)
    g_cur_lib = saved
    return r

fn global_optional_ctx(name_idx: int, node: int) -> int:
    saved := g_cur_lib
    g_cur_lib = ir_ctx_lib(node)
    r := global_decl_optional(name_idx)
    g_cur_lib = saved
    return r

fn find_global(name_idx: int) -> int:
    i : ., mut = g_ir_global_count - 1
    loop:
        if i < 0:
            break
        if cell_load(g_ir_globals, i * 24) == name_idx && cell_load(g_ir_global_lib, i * 8) == g_cur_lib:
            return cell_load(g_ir_globals, i * 24 + 8)
        i = i - 1
    i = g_ir_global_count - 1
    loop:
        if i < 0:
            return -1
        if cell_load(g_ir_globals, i * 24) == name_idx:
            return cell_load(g_ir_globals, i * 24 + 8)
        i = i - 1
    return -1

// Field load form for struct-pattern tests/bindings. Aggregate reads lose the
// declared type; string patterns must keep TI_STR so str_eq compares contents,
// bool/char keep their declared form so literal comparisons use the same
// representation as the existing bool/char arms, and other fields use the exact
// integer slot form (TI_INT).
// Field load form for struct-pattern tests/bindings. `ft` is the checker-resolved
// field type stored on the wrapper (+1). String patterns must keep TI_STR so
// str_eq compares contents, bool/char keep their declared form so literal
// comparisons use the same representation as the existing arms, and other fields
// use the exact integer slot form (TI_INT). Optional fields are raw slots.
fn structpat_field_load_ti_from(ft: int) -> int:
    if ft == TI_STR:
        return TI_STR
    if ft == TI_DEX:
        return TI_DEX_S
    if ft == TI_BOOL:
        return TI_BOOL
    if ft == TI_CHAR:
        return TI_CHAR
    return TI_INT

// ─── Struct match pattern lowering（Task 5b1）───
// Emit the comparison for one field subpattern. `fall` is taken when the
// comparison fails. Returns 1 when a test was emitted, 0 for ident/wildcard
// (no test), and -1 for an unsupported nested subpattern (caller must fail
// closed instead of jumping to the body).
// Declared payload type-node -> IR read form. Aggregates are pointers/tags
// (TI_INT); dex and char payloads need their exact slot form.
fn payload_tn_read_form(tn: int) -> int:
    if tn < 0:
        return TI_INT
    if agg_read_form_is_dex(tn) != 0:
        return TI_DEX_S
    if agg_read_form_is_char(tn) != 0:
        return TI_CHAR
    return TI_INT

fn gen_pattern_test(sub: int, fv: int, fall: int, ti: int) -> int:
    if sub < 0:
        return 0
    k := ast_kind(sub)
    if k == EXPR_STRUCTPAT:
        return gen_nested_struct_test(sub, fv, fall)
    if k == EXPR_TUPLEPAT:
        return gen_nested_tuple_test(sub, fv, fall)
    if k == EXPR_ENUMPAT:
        return gen_enum_pattern_test(sub, fv, fall, ti)
    return gen_structpat_field_test(sub, fv, fall)

// Test every refutable payload sub-pattern against one payload value whose
// declared type is val_ti (used for optional `Some(...)` payloads, which have a
// single inner type instead of a variant row).
fn gen_payload_tests(pat: int, val: int, fall: int, val_ti: int) -> int:
    c := ast_c(pat)
    if c <= 0:
        return 1
    i : ., mut = 0
    loop:
        if i >= c:
            return 1
        sub := sh_match_payload_root(pat, i)
        if sub < 0:
            return -1
        k := ast_kind(sub)
        if k == EXPR_IDENT || k == EXPR_WILDCARD:
            i = i + 1
            continue
        if val_ti < 0:
            return -1
        if gen_pattern_test(sub, val, fall, val_ti) < 0:
            return -1
        i = i + 1
    return 1

// Resolve the enum row of a variant pattern. IR lowering has no inferred
// scrutinee type, so fall back to the constructor symbol for the bare variant
// name (qualified `Enum.Variant` is reduced by get_variant_name_idx).
fn enum_row_of_pat(val_ti: int, pat: int) -> int:
    if val_ti >= 0:
        ea := find_enum_row_of(val_ti)
        if ea >= 0:
            return ea
    vni := get_variant_name_idx(ast_a(pat))
    if vni < 0:
        return -1
    si := find_gsym(vni)
    if si < 0:
        return -1
    return find_enum_row_of(sym_type(si))

// Declared type of payload position `pos` for an enum/optional match pattern.
fn enum_payload_decl_ti(match_ti: int, pat: int, pos: int) -> int:
    ea := enum_row_of_pat(match_ti, pat)
    if ea >= 0:
        vi := sh_enum_variant_index(ea, get_variant_name_idx(ast_a(pat)))
        if vi >= 0:
            tn := ei_variant_type_node(ea, vi, pos)
            if tn >= 0:
                return res_type_node(tn)
        return -1
    if match_ti >= 0 && get_type_kind(match_ti) == TYP_OPTIONAL:
        if sh_match_opt_pat(match_ti, pat) == 0:
            return get_type_data(match_ti)
    return -1

// Bind the ident sub-patterns inside a validated enum payload. Composite
// sub-patterns recurse; literals/wildcards bind nothing.
fn gen_enum_binds(pat: int, val: int, val_ti: int):
    if pat < 0 || val < 0:
        return
    ea := enum_row_of_pat(val_ti, pat)
    if ea < 0:
        return
    vi := sh_enum_variant_index(ea, get_variant_name_idx(ast_a(pat)))
    if vi < 0:
        return
    c := ast_c(pat)
    i : ., mut = 0
    loop:
        if i >= c:
            return
        sub := sh_match_payload_root(pat, i)
        if sub < 0:
            return
        k := ast_kind(sub)
        if k == EXPR_WILDCARD:
            i = i + 1
            continue
        if k == EXPR_IDENT || k == EXPR_STRUCTPAT || k == EXPR_TUPLEPAT || k == EXPR_ENUMPAT:
            tn := ei_variant_type_node(ea, vi, i)
            if tn < 0:
                return
            ft := res_type_node(tn)
            if ft < 0 || ti_has_generic_param(ft) != 0:
                return
            fv := new_ir_var("fld", TI_INT)
            irv_set_type(fv, payload_tn_read_form(tn))
            if g_optrep_on != 0 && get_type_kind(ft) == TYP_OPTIONAL:
                irv_set_decl_ti(fv, ft)
            emit(IR_LOAD_FIELD, fv, val, 0, i + 1, 0)
            if k == EXPR_IDENT:
                nn := ast_int_val(sub)
                if str_eq(istr_get(nn), "_") == 0:
                    bind_local(nn, fv)
            else if k == EXPR_STRUCTPAT:
                gen_structpat_binds(sub, fv)
            else if k == EXPR_TUPLEPAT:
                gen_tuplepat_binds(sub, fv)
            else:
                gen_enum_binds(sub, fv, ft)
        i = i + 1

// Nested enum pattern: compare the tag, then recursively test every payload
// sub-pattern. The payload root is recovered from the AST allocation order
// (parser stores only the first sub-pattern in ast_b).
fn gen_enum_pattern_test(pat: int, val: int, fall: int, val_ti: int) -> int:
    ea := enum_row_of_pat(val_ti, pat)
    if ea < 0:
        return -1
    vni := get_variant_name_idx(ast_a(pat))
    if vni < 0:
        return -1
    vi : ., mut = sh_enum_variant_index(ea, vni)
    if vi < 0:
        return -1
    tag := new_ir_var("tag", TI_INT)
    emit(IR_LOAD_ENUM_TAG, tag, val, 0, 0, 0)
    vtag := new_ir_var("vtag", TI_INT)
    emit(IR_CONST, vtag, vni, 0, 0, TI_INT)
    cmp := new_ir_var("cmp", TI_INT)
    emit(IR_BINARY, cmp, tag, vtag, OP_EQ, 0)
    ok := new_label()
    emit_cond_match(cmp, fall, ok)
    emit(IR_LABEL, -1, ok, 0, 0, 0)
    c := ast_c(pat)
    i : ., mut = 0
    loop:
        if i >= c:
            return 1
        sub := sh_match_payload_root(pat, i)
        if sub < 0:
            return -1
        k := ast_kind(sub)
        if k == EXPR_IDENT || k == EXPR_WILDCARD:
            i = i + 1
            continue
        tn := ei_variant_type_node(ea, vi, i)
        if tn < 0:
            return -1
        ft := res_type_node(tn)
        if ft < 0 || ti_has_generic_param(ft) != 0:
            return -1
        fv := new_ir_var("fld", TI_INT)
        irv_set_type(fv, payload_tn_read_form(tn))
        emit(IR_LOAD_FIELD, fv, val, 0, i + 1, 0)
        if gen_pattern_test(sub, fv, fall, ft) < 0:
            return -1
        i = i + 1
    return 1

fn gen_nested_struct_test(pat: int, val: int, fall: int) -> int:
    si := find_struct_by_name(ast_a(pat))
    c := ast_c(pat)
    w0 := ast_b(pat)
    if si < 0 || c < 0 || (c > 0 && w0 < 0):
        return -1
    i : ., mut = 0
    loop:
        if i >= c:
            break
        w := w0 + i
        sub := ast_a(w)
        jdi := struct_field_index_by_name(si, ast_b(w))
        if jdi < 0:
            return -1
        if sub >= 0:
            k := ast_kind(sub)
            if k != EXPR_IDENT && k != EXPR_WILDCARD:
                fd := ast_data(w)
                ft : ., mut = struct_row_field_ti(si, jdi)
                if fd > 0:
                    ft = fd - 1
                if ft < 0 || ti_has_generic_param(ft) != 0:
                    return -1
                fv := new_ir_var("fld", TI_INT)
                irv_set_type(fv, structpat_field_load_ti_from(ft))
                emit(IR_LOAD_FIELD, fv, val, 0, jdi, 0)
                if gen_pattern_test(sub, fv, fall, ft) < 0:
                    return -1
        i = i + 1
    return 1

fn gen_nested_tuple_test(pat: int, val: int, fall: int) -> int:
    c := ast_b(pat)
    w0 := ast_a(pat)
    if c <= 0 || w0 < 0:
        return -1
    i : ., mut = 0
    loop:
        if i >= c:
            break
        w := w0 + i
        sub := ast_a(w)
        idx := ast_b(w)
        fd := ast_data(w)
        if sub < 0 || idx != i || fd <= 0:
            return -1
        k := ast_kind(sub)
        if k != EXPR_IDENT && k != EXPR_WILDCARD:
            ft : ., mut = fd - 1
            if ti_has_generic_param(ft) != 0:
                return -1
            fv := new_ir_var("fld", TI_INT)
            irv_set_type(fv, structpat_field_load_ti_from(ft))
            emit(IR_LOAD_FIELD, fv, val, 0, idx, 0)
            if gen_pattern_test(sub, fv, fall, ft) < 0:
                return -1
        i = i + 1
    return 1

fn gen_structpat_field_test(sub: int, fv: int, fall: int) -> int:
    if sub < 0:
        return 0
    k := ast_kind(sub)
    if k == EXPR_IDENT || k == EXPR_WILDCARD:
        return 0
    if k == EXPR_STRUCTPAT || k == EXPR_TUPLEPAT:
        return gen_pattern_test(sub, fv, fall, -1)
    ok_lbl := new_label()
    cmp_var : ., mut = -1
    if k == EXPR_INT:
        pat_val := new_ir_var("pval", TI_INT)
        emit(IR_CONST, pat_val, ast_int_val(sub), 0, 0, TI_INT)
        cmp_var = new_ir_var("cmp", TI_INT)
        emit(IR_BINARY, cmp_var, fv, pat_val, OP_EQ, 0)
    else if k == EXPR_BOOL:
        pat_val := new_ir_var("pval", TI_BOOL)
        pat_bool : ., mut = 0
        if ast_int_val(sub) != 0:
            pat_bool = 1
        emit(IR_CONST, pat_val, pat_bool, 0, 0, TI_BOOL)
        cmp_var = new_ir_var("cmp", TI_INT)
        emit(IR_BINARY, cmp_var, fv, pat_val, OP_EQ, 0)
    else if k == EXPR_CHAR:
        // char runtime value = interned string index; the pattern stores the same
        // index in ast_int_val (same contract as the existing char arm).
        pat_val := new_ir_var("pval", TI_CHAR)
        track_str(ast_int_val(sub))
        emit(IR_CONST, pat_val, ast_int_val(sub), 0, 0, TI_CHAR)
        cmp_var = new_ir_var("cmp", TI_INT)
        emit(IR_BINARY, cmp_var, fv, pat_val, OP_EQ, 0)
    else if k == EXPR_STRING:
        pat_val := new_ir_var("spat", TI_STR)
        track_str(ast_int_val(sub))
        emit(IR_CONST, pat_val, ast_int_val(sub), 0, 0, TI_STR)
        eq0 := new_ir_var("_seq0", TI_STR)
        eq1 := new_ir_var("_seq1", TI_STR)
        emit(IR_STORE, -1, eq0, fv, 0, 0)
        emit(IR_STORE, -1, eq1, pat_val, 0, 0)
        cmp_var = new_ir_var("cmp", TI_BOOL)
        emit(IR_CALL, cmp_var, eq0, 2, str_intern("str_eq"), TI_BOOL)
    else:
        return -1
    emit_cond_match(cmp_var, fall, ok_lbl)
    emit(IR_LABEL, -1, ok_lbl, 0, 0, 0)
    return 1

// Bind ident subpatterns for a struct pattern in the arm scope. Each binding
// reads its field again and gets the checker-resolved field type stored on the
// wrapper. Literal and `_` subpatterns bind nothing.
fn gen_structpat_binds(pat: int, match_val: int):
    if pat < 0 || match_val < 0:
        return
    si := find_struct_by_name(ast_a(pat))
    c := ast_c(pat)
    w0 := ast_b(pat)
    if si < 0 || w0 < 0:
        return
    i : ., mut = 0
    loop:
        if i >= c:
            break
        w := w0 + i
        if w >= 0:
            sub := ast_a(w)
            if sub >= 0:
                k := ast_kind(sub)
                is_wild : ., mut = 0
                if k == EXPR_WILDCARD:
                    is_wild = 1
                if k == EXPR_IDENT && str_eq(istr_get(ast_int_val(sub)), "_") != 0:
                    is_wild = 1
                if is_wild == 0:
                    jdi : ., mut = struct_field_index_by_name(si, ast_b(w))
                    if jdi >= 0:
                        fd := ast_data(w)
                        ft : ., mut = struct_row_field_ti(si, jdi)
                        if fd > 0:
                            ft = fd - 1
                        // A still-generic field cannot be bound soundly; the
                        // pattern was fail-closed before the body.
                        if ti_has_generic_param(ft) == 0:
                            if k == EXPR_IDENT:
                                nn := ast_int_val(sub)
                                fv := new_ir_var("fld", TI_INT)
                                irv_set_type(fv, structpat_field_load_ti_from(ft))
                                if get_type_kind(ft) == TYP_OPTIONAL && g_optrep_on != 0:
                                    irv_set_decl_ti(fv, ft)
                                emit(IR_LOAD_FIELD, fv, match_val, 0, jdi, 0)
                                bind_local(nn, fv)
                            else if k == EXPR_STRUCTPAT || k == EXPR_TUPLEPAT || k == EXPR_ENUMPAT:
                                fv := new_ir_var("fld", TI_INT)
                                irv_set_type(fv, structpat_field_load_ti_from(ft))
                                emit(IR_LOAD_FIELD, fv, match_val, 0, jdi, 0)
                                if k == EXPR_STRUCTPAT:
                                    gen_structpat_binds(sub, fv)
                                else if k == EXPR_TUPLEPAT:
                                    gen_tuplepat_binds(sub, fv)
                                else:
                                    gen_enum_binds(sub, fv, ft)
        i = i + 1

// Bind ident subpatterns for a tuple pattern in the arm scope. Each binding reads
// its element again and gets the checker-resolved element type stored on the
// wrapper. Literal and `_` subpatterns bind nothing.
fn gen_tuplepat_binds(pat: int, match_val: int):
    if pat < 0 || match_val < 0:
        return
    c := ast_b(pat)
    w0 := ast_a(pat)
    if w0 < 0:
        return
    i : ., mut = 0
    loop:
        if i >= c:
            break
        w := w0 + i
        if w >= 0:
            sub := ast_a(w)
            if sub >= 0:
                k := ast_kind(sub)
                is_wild : ., mut = 0
                if k == EXPR_WILDCARD:
                    is_wild = 1
                if k == EXPR_IDENT && str_eq(istr_get(ast_int_val(sub)), "_") != 0:
                    is_wild = 1
                if is_wild == 0:
                    fd := ast_data(w)
                    ft : ., mut = TI_INT
                    if fd > 0:
                        ft = fd - 1
                    fv := new_ir_var("fld", TI_INT)
                    irv_set_type(fv, structpat_field_load_ti_from(ft))
                    if get_type_kind(ft) == TYP_OPTIONAL && g_optrep_on != 0:
                        irv_set_decl_ti(fv, ft)
                    emit(IR_LOAD_FIELD, fv, match_val, 0, ast_b(w), 0)
                    if k == EXPR_IDENT:
                        bind_local(ast_int_val(sub), fv)
                    else if k == EXPR_STRUCTPAT:
                        gen_structpat_binds(sub, fv)
                    else if k == EXPR_TUPLEPAT:
                        gen_tuplepat_binds(sub, fv)
                    else if k == EXPR_ENUMPAT:
                        gen_enum_binds(sub, fv, ft)
        i = i + 1

// Return the literal initializer AST node for an immutable module-level
// constant.  The ELF backend has no data initializers, so leaving these as
// BSS globals turns values such as T_FN and ESZ_TOKEN into zero at runtime.
fn find_global_const_node(name_idx: int) -> int:
    i : ., mut = g_global_let_count - 1
    loop:
        if i < 0:
            break
        node := cell_load(g_global_lets, i * 8)
        if ast_a(node) == name_idx && ast_data(node) == 0 && global_decl_in_ctx(node):
            value_node := ast_c(node)
            if value_node >= 0:
                value_kind := ast_kind(value_node)
                if value_kind == EXPR_INT || value_kind == EXPR_BOOL || value_kind == EXPR_DEX:
                    return value_node
        i = i - 1
    if g_cur_lib >= 0:
        i = g_global_let_count - 1
        loop:
            if i < 0:
                break
            node2 := cell_load(g_global_lets, i * 8)
            if ast_a(node2) == name_idx && ast_data(node2) == 0:
                value_node2 := ast_c(node2)
                if value_node2 >= 0:
                    vk2 := ast_kind(value_node2)
                    if vk2 == EXPR_INT || vk2 == EXPR_BOOL || vk2 == EXPR_DEX:
                        return value_node2
            i = i - 1

    return -1

fn push_ir_scope():
    grow_ir_local_scopes(g_ir_local_depth + 1)
    cell_store(g_ir_local_scopes, g_ir_local_depth * 8, g_ir_local_count)
    g_ir_local_depth = g_ir_local_depth + 1

fn pop_ir_scope():
    g_ir_local_depth = g_ir_local_depth - 1
    g_ir_local_count = cell_load(g_ir_local_scopes, g_ir_local_depth * 8)

fn is_ptr_var(var_idx: int) -> int:
    if var_idx < 0:
        return 0
    ti := irv_type(var_idx)
    if ti == TI_DEX_S:
        return 0
    // TI_DEX_S is a sentinel and is not in the type table. Row 8 is a
    // placeholder; user types start at 9.
    if ti >= 0:
        tk := get_type_kind(ti)
        if tk == TYP_PTR || tk == TYP_REF:
            return 1
    prod := cell_load(g_df_var_producer, var_idx * 8)
    if prod < 0:
        return 0
    prod_op := cell_load(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_OPCODE)
    if prod_op == IR_ALLOC:
        ti := irv_type(var_idx)
        if ti == TI_INT || ti == TI_DEX || ti == TI_BOOL || ti == TI_CHAR:
            return 0
        return 1
    if prod_op == IR_ADDR_INDEX || prod_op == IR_REF || prod_op == IR_ALLOC_STRUCT || prod_op == IR_ALLOC_ARRAY:
        return 1
    return 0

fn is_byte_buf_var(var_idx: int) -> int:
    // Raw byte buffers produced by alloc() (TI_UNIT internal sentinel,
    // Core `string`) are byte-addressed: `buf + n` must NOT scale n by
    // the 8-byte element size. A byte-arithmetic result stays a byte pointer,
    // so chains like `buf + size - 8` stay unscaled.
    if var_idx < 0:
        return 0
    prod := cell_load(g_df_var_producer, var_idx * 8)
    if prod >= 0:
        prod_op := cell_load(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_OPCODE)
        if prod_op == IR_BINARY:
            bop := cell_load(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_S3)
            if bop == OP_BYTE_ADD || bop == OP_BYTE_SUB:
                return 1
    if irv_type(var_idx) != TI_UNIT:
        return 0
    if prod < 0:
        return 0
    prod_op2 := cell_load(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_OPCODE)
    // A TI_UNIT slot backed by IR_ALLOC is an alloc()/byte-buffer local (typed
    // scalars were narrowed above, so uninitialized `x : int` no longer lands
    // here).
    if prod_op2 == IR_ALLOC:
        return 1
    if prod_op2 == IR_CALL:
        func_ni : ., mut = cell_load(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_S3)
        if runtime_frontend_builtin_is_alloc(func_ni) != 0:
            return 1
    return 0

// Value of a compile-time integer producer, or -1 when the variable is not an
// IR_CONST integer. Used by declarative placement (alloc_at) and align().
fn ir_const_int_of_var(var: int) -> int:
    if var < 0:
        return -1
    prod := cell_load(g_df_var_producer, var * 8)
    if prod < 0:
        return -1
    op := cell_load(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_OPCODE)
    if op != IR_CONST:
        return -1
    return cell_load(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_S1)

fn ir_call_return_type(func_ni: int) -> int:
    if func_ni < 0:
        return TI_UNIT
    // alloc() produces a raw byte buffer. Keep the existing internal pointer
    // sentinel until Core has a distinct raw-buffer type.
    if runtime_frontend_builtin_is_alloc(func_ni) != 0:
        return TI_UNIT
    // OS-axis builtins with no Core body (syscall3/syscall4) are not in the
    // target table but do declare a return type; without this the call result
    // is TI_UNIT and tagged comparisons treat it as a raw word.
    pr := prelude_builtin_return_ti(func_ni)
    if pr >= 0:
        return pr
    bi : ., mut = 0
    loop:
        if bi >= g_rt_builtin_count:
            break
        if cell_load(g_rt_builtin_names, bi * 8) == func_ni:
            return cell_load(g_rt_builtin_ret_types, bi * 8)
        bi = bi + 1
    fi : ., mut = find_func(func_ni)
    if fi >= 0:
        rt := fi_return_type(fi)
        if rt == TY_INT:
            return TI_INT
        if rt == TY_DEX:
            // dex 边界规则：Core 函数返回精确形式（缩放整数）；
            // extern 函数保留 TI_DEX（binary64 位模式，C ABI / apx 授权 FFI）
            if fi_ast_node(fi) >= 0 && ast_kind(fi_ast_node(fi)) == EXPR_EXTERN:
                return TI_DEX
            return TI_DEX_S
        if rt == TY_BOOL:
            return TI_BOOL
        if rt == TY_STRING:
            return TI_STR
        if rt == TY_UNIT:
            return TI_UNIT
        if rt == TY_CHAR:
            return TI_CHAR
    si := find_gsym(func_ni)
    if si < 0:
        return TI_UNIT
    if sym_kind(si) == SYM_FN:
        return sym_type(si)
    if sym_kind(si) == SYM_SO_FN:
        type_enc := sym_node(si)
        ret_code := type_enc - (type_enc / 100) * 100
        if ret_code == 0:
            return TI_INT
        if ret_code == 1:
            return TI_STR
        if ret_code == 2:
            return TI_UNIT
        if ret_code == 3:
            return TI_DEX
        if ret_code == 4:
            return TI_BOOL
    return TI_UNIT

// --- Track string constants ---
fn track_str(str_idx: int):
    i : ., mut = 0
    loop:
        if i >= g_ir_str_const_count:
            break
        if cell_load(g_ir_str_consts, i * 8) == str_idx:
            return
        i = i + 1
    grow_ir_str_consts(g_ir_str_const_count + 1)
    cell_store(g_ir_str_consts, g_ir_str_const_count * 8, str_idx)
    g_ir_str_const_count = g_ir_str_const_count + 1

// --- Loop label stack ---
fn push_loop_labels(header: int, exit: int):
    grow_ir_loop_stacks(g_ir_loop_depth + 1)
    cell_store(g_ir_loop_header, g_ir_loop_depth * 8, header)
    cell_store(g_ir_loop_exit, g_ir_loop_depth * 8, exit)
    g_ir_loop_depth = g_ir_loop_depth + 1

fn pop_loop_labels():
    g_ir_loop_depth = g_ir_loop_depth - 1

// 枚举变体名查找（F15）：name_idx 是否为任一枚举的变体名（裸引用 `c := Red`）。
// 匹配返回 name_idx 本身；非变体名返回 -1。checker 的 collect_decls 把每个
// 变体名注册为 SYM_FN（指向枚举类型），裸变体经类型检查后到达 ir_gen。
fn find_enum_variant(name_idx: int) -> int:
    ei : ., mut = 0
    loop:
        if ei >= g_enum_count:
            break
        vi : ., mut = 0
        loop:
            if vi >= ei_variant_count(ei):
                break
            if ei_variant_name(ei, vi) == name_idx:
                return name_idx
            vi = vi + 1
        ei = ei + 1
    return -1

fn get_variant_name_idx(qualified_ni: int) -> int:
    s := istr_get(qualified_ni)
    slen := str_len(s)
    dot_pos : ., mut = -1
    i : ., mut = 0
    loop:
        if i >= slen:
            break
        c := get_char(s, i)
        if str_eq(c, ".") != 0:
            dot_pos = i
        i = i + 1
    if dot_pos >= 0:
        variant_name := str_sub(s, dot_pos + 1, slen - dot_pos - 1)
        return str_intern(variant_name)
    return qualified_ni

// --- Type metadata helpers for @ builtins ---

// Resolve a type expression node to a TI_* type index.
// Handles type nodes (ast_kind==0 from parse_type) and EXPR_IDENT
// (basic type names not in the symbol table).
// Find an existing sequence type row, or allocate one. Used at parameter
// binding for `[T; N]`/`[T]` nodes: the declaration must not collapse to int,
// otherwise a `for x in xs` loop cannot recover its length.
fn find_or_alloc_seq_type(kind: int, elem: int, size: int) -> int:
    i : ., mut = 0
    loop:
        if i >= g_type_count:
            break
        if get_type_kind(i) == kind && get_type_data(i) == elem && get_type_extra(i) == size:
            return i
        i = i + 1
    return alloc_type(kind, elem, size)

fn seq_type_of_node(node: int) -> int:
    if node < 0 || ast_kind(node) != EXPR_ARRAY:
        return -1
    elem := ti_from_type_expr(ast_a(node))
    sz := ast_int_val(node)
    if sz > 0:
        return find_or_alloc_seq_type(TYP_ARRAY, elem, sz)
    return find_or_alloc_seq_type(TYP_SLICE, elem, 0)

fn ti_from_type_expr(node: int) -> int:
    if node < 0:
        return TI_UNIT
    // Type node from parse_type: ast_kind == 0, type_val = TY_*
    if ast_kind(node) == 0:
        tv := ast_type_val(node)
        if tv == TY_INT:
            return TI_INT
        if tv == TY_DEX:
            return TI_DEX
        if tv == TY_BOOL:
            return TI_BOOL
        if tv == TY_STRING:
            return TI_STR
        if tv == TY_CHAR:
            return TI_CHAR
        if tv == TY_UNIT:
            return TI_UNIT
        return TI_UNIT
    // EXPR_IDENT from parse_expr: int_val = name string index
    if ast_kind(node) == EXPR_IDENT:
        ni := ast_int_val(node)
        name := istr_get(ni)
        if str_eq(name, "int") != 0:
            return TI_INT
        if str_eq(name, "dex") != 0:
            return TI_DEX
        if str_eq(name, "bool") != 0:
            return TI_BOOL
        if str_eq(name, "string") != 0:
            return TI_STR
        if str_eq(name, "char") != 0:
            return TI_CHAR
        if str_eq(name, "unit") != 0:
            return TI_UNIT
        // Named types (structs, enums): look up in symbol table
        si : ., mut = find_gsym(ni)
        if si >= 0 && sym_kind(si) == SYM_TYPE:
            return sym_type(si)
    // Complex type expressions: delegate to checker's resolver
    return res_type_node(node)

// The frontend carries the pointee *type*, never a byte width. corearch
// reconstructs the access width for IR_DEREF/IR_STORE_PTR from this type and
// the active target layout.

fn ptr_pointee_type(var_idx: int) -> int:
    if var_idx < 0:
        return TI_INT
    ti := irv_type(var_idx)
    if ti >= 0:
        k := get_type_kind(ti)
        if k == TYP_PTR || k == TYP_REF:
            return get_type_data(ti)
    return TI_INT

// Resolve a type index to a struct info index.
// Returns -1 if the type is not a struct type.
fn ti_resolve_struct(ti: int) -> int:
    if ti < 0 || ti >= g_type_count:
        return -1
    k := get_type_kind(ti)
    if k != TYP_NAMED:
        return -1
    name_ni := get_type_data(ti)
    if name_ni < 0:
        return -1
    name := istr_get(name_ni)
    si : ., mut = 0
    loop:
        if si >= g_struct_count:
            break
        sn_ni := si_name(si)
        sn := istr_get(sn_ni)
        if str_eq(sn, name) != 0:
            return si
        si = si + 1
    return -1

// Check if a struct type has a field by name
fn ti_has_field(ti: int, name: string) -> int:
    si := ti_resolve_struct(ti)
    if si < 0:
        return 0
    fc := si_field_count(si)
    fi : ., mut = 0
    loop:
        if fi >= fc:
            break
        fn_ni := si_field_name(si, fi)
        fname := istr_get(fn_ni)
        if str_eq(fname, name) != 0:
            return 1
        fi = fi + 1
    return 0

// Get the field index of `name` in type `ti`. -1 = no such field.
// @field byte offsets are a target introspection query and are resolved by the
// target descriptor at the call site; this helper stays semantic.
fn ti_field_index(ti: int, name: string) -> int:
    si := ti_resolve_struct(ti)
    if si < 0:
        return -1
    fc := si_field_count(si)
    fi : ., mut = 0
    loop:
        if fi >= fc:
            break
        fn_ni := si_field_name(si, fi)
        fname := istr_get(fn_ni)
        if str_eq(fname, name) != 0:
            return fi
        fi = fi + 1
    return -1

// Check if a function name refers to a hotpatch function (has @hotpatch versions)
fn is_hotpatch_func(name_idx: int) -> int:
    count : ., mut = 0
    i : ., mut = 0
    loop:
        if i >= g_func_count:
            break
        if fi_name(i) == name_idx:
            fn_node := fi_ast_node(i)
            if fn_node >= 0:
                hotpatch_ver := (ast_int_val(fn_node) % 65536) / 256
                if hotpatch_ver > 0:
                    count = count + 1
        i = i + 1
    if count > 0:
        return 1
    return 0

// Helper: if a variable's producer is IR_LAZY_THUNK, emit IR_LAZY_FORCE
// to extract the real value and return the forced variable.
fn force_if_thunk(var_idx: int) -> int:
    if var_idx < 0:
        return var_idx
    // A deferred pure call is materialized at its first (and planned only)
    // force point. Subsequent forces see the call producer.
    if lazy_def_emit(var_idx) != 0:
        return var_idx
    prod := cell_load(g_df_var_producer, var_idx * 8)
    if prod >= 0:
        prod_op := cell_load(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_OPCODE)
        if prod_op == IR_LAZY_THUNK:
            forced := new_ir_var("_forced", irv_type(var_idx))
            emit(IR_LAZY_FORCE, forced, var_idx, 0, 0, 0)
            return forced
    return var_idx

// --- dex 定点精确运算辅助---
// dex 值有两种 IR 形式：
//   TI_DEX_S = 定点缩放整数（精确形式，S = 10^6，默认世界，跨函数边界统一此形式）
//   TI_DEX   = binary64 位模式（apx 形式，apx 变量及其运算的快路径表示）
// 转换规则（文档化）：运算按操作数形式分流（有 TI_DEX 操作数 -> binary64 快路径，
// 否则 -> 定点整数指令序列）；存储/边界处按槽位形式转换（apx 结果在边界按定点
// 6 位截断/舍入，精确，或经授权的近似契约的兑现）。

// bits（TI_DEX）-> 缩放整数（TI_DEX_S）：round(bits × S)，6 位定点舍入（四舍五入
// 半进，dex 定点：apx 打印/边界行为 = 6 位定点舍入，非截断、非全精度
// binary64）。实现：F2I 本身向零截断，正数先 +0.5、负数先 −0.5（分支按 m < 0 分流，
// 与字面量 str_to_scaled 的半进一致；半进 = 绝对值半上，-0.5 -> -1）。此舍入同时合并
// str_to_f64_bits 字面量转换的 ~2ulp 截断误差（打印/边界 6 位精度下不可见）。
fn dex_bits_to_scaled(var: int) -> int:
    if irv_type(var) != TI_DEX:
        return var
    c := new_ir_var("_dxs", TI_DEX)
    emit(IR_CONST, c, 4696837146684686336, 0, 0, TI_DEX)  // 1e6 的 binary64 位模式
    m := new_ir_var("_dxm", TI_DEX)
    emit(IR_BINARY, m, var, c, OP_MUL, TI_DEX)
    zero := new_ir_var("_dx0", TI_DEX)
    emit(IR_CONST, zero, 0, 0, 0, TI_DEX)
    negc := new_ir_var("_dxc", TI_INT)
    emit(IR_BINARY, negc, m, zero, OP_LT, TI_DEX)  // m < 0 -> int 0/1（comisd 路径）
    half := new_ir_var("_dxh", TI_DEX)
    emit(IR_CONST, half, 4602678819172646912, 0, 0, TI_DEX)  // 0.5 的 binary64 位模式（0x3FE0000000000000）
    pos_lbl := new_label()
    neg_lbl := new_label()
    merge_lbl := new_label()
    mrg := new_ir_var("_dxmrg", TI_DEX)
    emit_cond_match(negc, pos_lbl, neg_lbl)
    emit(IR_LABEL, -1, pos_lbl, 0, 0, 0)
    rp := new_ir_var("_dxrp", TI_DEX)
    emit(IR_BINARY, rp, m, half, OP_ADD, TI_DEX)  // m ≥ 0：+0.5
    emit(IR_STORE, -1, mrg, rp, 0, 0)
    emit(IR_JUMP, -1, merge_lbl, 0, 0, 0)
    emit(IR_LABEL, -1, neg_lbl, 0, 0, 0)
    rn := new_ir_var("_dxrn", TI_DEX)
    emit(IR_BINARY, rn, m, half, OP_SUB, TI_DEX)  // m < 0：−0.5
    emit(IR_STORE, -1, mrg, rn, 0, 0)
    emit(IR_LABEL, -1, merge_lbl, 0, 0, 0)
    r : ., mut = new_ir_var("_dxsc", TI_DEX_S)
    emit(IR_F2I, r, mrg, 0, 0, TI_DEX)
    return r

// 缩放整数（TI_DEX_S）-> bits（TI_DEX）：I2F(scaled) / S
// 字面量节点（EXPR_DEX）直接重发射为 bits 常量（与 lexer 位模式一致，免转换序列）
fn dex_scaled_to_bits(var: int, node: int) -> int:
    if irv_type(var) != TI_DEX_S:
        return var
    if node >= 0 && ast_kind(node) == EXPR_DEX:
        v := new_ir_var("dex", TI_DEX)
        emit(IR_CONST, v, ast_a(node), 0, 0, TI_DEX)
        return v
    f := new_ir_var("_dxf", TI_DEX)
    emit(IR_I2F, f, var, 0, 0, TI_DEX)
    c := new_ir_var("_dxsc", TI_DEX)
    emit(IR_CONST, c, 4696837146684686336, 0, 0, TI_DEX)  // 1e6 bits
    d := new_ir_var("_dxdiv", TI_DEX)
    emit(IR_BINARY, d, f, c, OP_DIV, TI_DEX)
    return d

// int 操作数 -> 定点缩放（×S）：精确路径的 int 隐式缩放（与 apx 路径的 I2F 处于同一位置）
fn dex_scale_int(var: int) -> int:
    if irv_type(var) != TI_INT:
        return var
    // Big-int mode stores ints tagged (2v). Multiply through the big-int path
    // (tagged rep of S = 2S), then strip the tag with a raw divide by 2 so the
    // exact-path operand is a raw scaled word.
    c := new_ir_var("_dsc", TI_INT)
    emit(IR_CONST, c, 1000000, 0, 0, TI_INT)
    p := new_ir_var("_dst", TI_INT)
    emit(IR_BINARY, p, var, c, OP_MUL, TI_INT)
    two := new_ir_var("_ds2", TI_DEX_S)
    emit(IR_CONST, two, 2, 0, 0, TI_DEX_S)
    t := new_ir_var("_dxt", TI_DEX_S)
    emit(IR_BINARY, t, p, two, OP_DIV, TI_INT)
    return t

// 存储到 dex 槽位前按槽位形式转换：
//   TI_DEX 槽（apx 变量）← 缩放值：scaled -> bits（字面量重发射，计算值 I2F/S）
//   TI_DEX_S 槽（精确变量）← bits 值：bits -> scaled（apx 结果按定点 6 位舍入入精确世界）
fn dex_store_adjust(target: int, val: int, val_node: int) -> int:
    tt := irv_type(target)
    vt : ., mut = irv_type(val)
    if tt == TI_DEX && vt == TI_DEX_S:
        return dex_scaled_to_bits(val, val_node)
    if tt == TI_DEX_S && vt == TI_DEX:
        return dex_bits_to_scaled(val)
    return val

// 聚合/指针槽写点规范化（apx 阶段 T3）：聚合类型不存在 apx 形式，`apx` 是 LET 专属
// 标签（parser.cr:819），字段 / 数组·切片元素 / 元组元素 / 枚举携带值 / 指针 pointee
// 的规范存储形式恒为精确（scaled） -> 任何 TI_DEX（bits）值入这类槽前一律转
// scaled；非 apx 值原样返回（零 IR -> 非 apx 程序逐字节不变）。
// 规则（Global Constraint 12）：本判定不含任何类型表查询（不调 res_type_node/
// alloc_type），ir_gen 路径新增 alloc_type 站点会违反暖缓存不可写条目不变式。
fn dex_slot_norm(val: int) -> int:
    if val < 0:
        return val
    if irv_type(val) != TI_DEX:
        return val
    return dex_bits_to_scaled(val)

// Whether a declaration type node is `dex?` (optional dex). This is a node-level
// check with zero allocation, using the same pattern as agg_read_form_is_dex and
// reg_one_global. A `dex?` type node is EXPR_OPTIONAL with an inner base `dex`
// node (kind 0 and type_val TY_DEX). Write points and slot typing use the declared
// form (G1: scaled) rather than inferring from the value type.
fn dex_opt_type_node(tn: int) -> int:
    if tn < 0:
        return 0
    if ast_kind(tn) != EXPR_OPTIONAL:
        return 0
    inner := ast_a(tn)
    if inner < 0 || ast_kind(inner) != 0:
        return 0
    if ast_type_val(inner) == TY_DEX:
        return 1
    return 0

// Whether a type row is `dex?` (TYP_OPTIONAL with data == TI_DEX). This is a pure
// table read with zero allocation, using the same pattern as ti_is_optional and
// elem_ti_of_decl. Optional payload read slots take the declared form.
// agg_payload_read_form recognizes only enum rows, and the built-in Some type has
// no row, so it stays TI_INT; a dex payload used as an int would be multiplied by
// S again. G2 constraint: do not call res_type_node or alloc_type.
fn dex_opt_slot_ti(ti: int) -> int:
    if ti < 0 || ti >= g_type_count:
        return 0
    if get_type_kind(ti) != TYP_OPTIONAL:
        return 0
    if get_type_data(ti) == TI_DEX:
        return 1
    return 0

// Align dex arguments to the callee parameter list; reusable after generic
// instantiation. This extraction has no effect yet because the instance parameter
// list is not substituted: monomorph's EXPR_FN clone copies only the body, so the
// condition is always false. It produces no behavior change. Do not delete it as
// dead code: generic instance parameter erasure depends on it, including
// parameterized cfi, idempotence, and the second pass after redirection.
// 锁步契约：`arg_vars`/`arg_nodes` 与参数列表同索引取用，直调（无接收者）1:1；方法调用接收者占
// `arg_vars[0]`，而 `self` 在方法参数列表中亦占第 0 位（parser 物化 EXPR_PARAM，parser.cr `self` 分支）
// -> 同样处理。幂等：转换只对 `irv_type(av) == TI_DEX` 生效 -> 已转换（TI_DEX_S）者不会被二次转换
// （这是重定向前后各跑一遍安全的前提）。本函数不得重分配 arg_vars（只写元素；句柄按值传入）。
fn dex_align_call_args(cfi: int, ac: int, arg_vars: string, arg_nodes: string, arg_nodes_cap: int):
    cfn := fi_ast_node(cfi)
    cfn_ext : ., mut = 0
    if cfn >= 0 && ast_kind(cfn) == EXPR_EXTERN:
        cfn_ext = 1
    if cfn < 0:
        return
    if cfn_ext == 0 && ast_kind(cfn) != EXPR_FN:
        return
    cpi : ., mut = 0
    cpn : ., mut = ast_b(cfn)
    // 实参节点与实参 var 同表锁步取（`arg_nodes[cpi]` 与 `arg_vars[cpi]` 同索引写入，
    // 接收者亦在内）。方法调用下 EXPR_ARG 列表不含接收者，若按列表另走游标会滞后一位。
    loop:
        if cpi >= ac:
            break
        if cpn < 0:
            break
        dd := ast_data(cpn)
        // dex? parameters are included. The test accepts a TI_DEX node or a
        // dex-optional declaration node. The extern side is not extended because
        // C ABI has no optional representation; that face is uncovered.
        // 泛型声明的 `T?`（inner = 泛型参数）条件为假 -> 调用点在重定向后
        // 用实例参数列表（inner = 具体 dex）再跑一遍本环。
        if ast_type_val(cpn) == TI_DEX || (cfn_ext == 0 && dex_opt_type_node(ast_data(cpn)) != 0):
            av : ., mut = cell_load(arg_vars, cpi * 8)
            if av >= 0:
                if cfn_ext != 0:
                    // extern：scaled -> bits（字面量直接重发射位模式常量）
                    if irv_type(av) == TI_DEX_S:
                        arg_node : ., mut = -1
                        if cpi < arg_nodes_cap:
                            arg_node = cell_load(arg_nodes, cpi * 8)
                        av = dex_scaled_to_bits(av, arg_node)
                        cell_store(arg_vars, cpi * 8, av)
                else if irv_type(av) == TI_DEX:
                    // Core 函数：apx bits -> scaled
                    av = dex_bits_to_scaled(av)
                    cell_store(arg_vars, cpi * 8, av)
        cpi = cpi + 1
        cpn = cpn + 1
        loop:
            if cpn >= g_ast_count:
                break
            if ast_kind(cpn) == EXPR_PARAM:
                break
            cpn = cpn + 1

// 聚合读的声明信息 dex-ness（apx 阶段 T3 · 比较/相等点专用）：
//  未修 -> 聚合读的结果槽 IR 型恒 TI_INT、声明型被抹 -> 下游按值型触发的
// 形式分流看不到 dex。本函数在节点级把声明信息取回来(zero alloc_type; same pattern as
// agg_elem_count_of:3004），供比较点判断操作数的规范槽形式：
//   EXPR_FIELD -> 结构体字段的声明类型节点（数字元组下标 ast_type_val>0 不判，元组无声明信息）
//   EXPR_INDEX -> 全局定长数组/切片的元素声明类型节点（局部数组无节点级声明信息 -> 不判）
// 返回 1 = 声明为 dex（-> 槽内规范形式 = 精确/scaled，guaranteed by the write points）· 0 = 非 dex / 不可得。
fn dex_decl_form_of_expr(node: int) -> int:
    if node < 0:
        return 0
    k := ast_kind(node)
    if k == EXPR_FIELD:
        if ast_type_val(node) > 0:
            return 0
        si := find_struct(ast_c(node))
        if si < 0:
            return 0
        fi : ., mut = ast_data(node)
        if fi < 0:
            return 0
        tn := si_field_type_node(si, fi)
        if tn >= 0 && ast_kind(tn) == 0 && ast_type_val(tn) == TY_DEX:
            return 1
        return 0
    if k == EXPR_INDEX:
        an : ., mut = ast_a(node)
        if an < 0 || ast_kind(an) != EXPR_IDENT:
            return 0
        ni := ast_int_val(an)
        gi : ., mut = 0
        loop:
            if gi >= g_global_let_count:
                break
            lnode := cell_load(g_global_lets, gi * 8)
            if ast_a(lnode) == ni:
                tn := ast_b(lnode)
                if tn >= 0 && ast_kind(tn) == EXPR_ARRAY:
                    etn := ast_a(tn)
                    if etn >= 0 && ast_kind(etn) == 0 && ast_type_val(etn) == TY_DEX:
                        return 1
                break
            gi = gi + 1
        return 0
    return 0

// --- IR generation for expressions ---
// Returns the IR variable index holding the result

// ─── Maranget decision-tree lowering ───────────────────────────────
// Algorithm: Maranget, "Compiling Pattern Matching to Good Decision Trees"
// (ML 2008), matrix specialization. The column selector is the FCR (fewer
// child rules) heuristic from "When Do Match-Compilation Heuristics Matter?";
// representation-specific field/tag accessors follow the Knit&Frog approach
// (Baudon et al., 2022) rather than assuming one universal constructor layout.
//
// Everything below is local: the pattern matrix, occurrence columns and
// constructor lists are alloc'd per compile call and passed down the
// recursion. The recursion stack *is* the decision tree; leaves jump to
// pre-allocated arm labels. No global node/edge tables.

fn dt_pat_wild(p: int) -> int:
    if p < 0:
        return 1
    k := ast_kind(p)
    if k == EXPR_WILDCARD:
        return 1
    if k == EXPR_IDENT:
        if str_eq(istr_get(ast_int_val(p)), "_") != 0:
            return 1
    return 0

fn dt_ctor_kind(p: int) -> int:
    if p < 0:
        return 0
    k := ast_kind(p)
    if k == EXPR_ENUMPAT:
        return 1
    if k == EXPR_STRUCTPAT:
        return 2
    if k == EXPR_TUPLEPAT:
        return 3
    if k == EXPR_INT:
        return 4
    if k == EXPR_BOOL:
        return 5
    if k == EXPR_CHAR:
        return 6
    if k == EXPR_STRING:
        return 7
    return 0

fn dt_ctor_id(p: int) -> int:
    k := dt_ctor_kind(p)
    if k == 1:
        return get_variant_name_idx(ast_a(p))
    if k == 2:
        return ast_a(p)
    if k == 3:
        return ast_b(p)
    if k == 4 || k == 5 || k == 6 || k == 7:
        return ast_int_val(p)
    return -1

fn dt_enum_vi(p: int, ti: int) -> int:
    ea := enum_row_of_pat(ti, p)
    if ea < 0:
        return -1
    return sh_enum_variant_index(ea, get_variant_name_idx(ast_a(p)))

fn dt_ctor_arity(p: int, ti: int) -> int:
    k := dt_ctor_kind(p)
    if k == 1:
        ea := enum_row_of_pat(ti, p)
        vi := dt_enum_vi(p, ti)
        if ea < 0 || vi < 0:
            return -1
        return ei_variant_type_count(ea, vi)
    if k == 2:
        si := find_struct_by_name(ast_a(p))
        if si < 0:
            return -1
        return si_field_count(si)
    if k == 3:
        return ast_b(p)
    return 0

// Sub-pattern at slot i of a constructor pattern (-1 = implicit wildcard).
fn dt_subpat(p: int, i: int) -> int:
    if p < 0 || i < 0:
        return -1
    k := dt_ctor_kind(p)
    if k == 1:
        if i < ast_c(p):
            return sh_match_payload_root(p, i)
        return -1
    if k == 2:
        si := find_struct_by_name(ast_a(p))
        if si < 0:
            return -1
        c := ast_c(p)
        w0 := ast_b(p)
        j : ., mut = 0
        loop:
            if j >= c:
                return -1
            w := w0 + j
            if w >= 0:
                if struct_field_index_by_name(si, ast_b(w)) == i:
                    return ast_a(w)
            j = j + 1
        return -1
    if k == 3:
        if i < ast_b(p):
            w := ast_a(p) + i
            if w >= 0:
                return ast_a(w)
        return -1
    return -1

// Declared type of slot i. Struct fields reuse the checker-cached wrapper type
// when present, else the row declaration; unresolved generics fail closed.
fn dt_subpat_ti(p: int, i: int, ti: int) -> int:
    if p < 0 || i < 0:
        return -1
    k := dt_ctor_kind(p)
    if k == 1:
        ea := enum_row_of_pat(ti, p)
        vi := dt_enum_vi(p, ti)
        if ea < 0 || vi < 0:
            return -1
        if i >= ei_variant_type_count(ea, vi):
            return -1
        tn := ei_variant_type_node(ea, vi, i)
        if tn < 0:
            return -1
        return res_type_node(tn)
    if k == 2:
        si := find_struct_by_name(ast_a(p))
        if si < 0:
            return -1
        c : ., mut = ast_c(p)
        w0 := ast_b(p)
        j : ., mut = 0
        loop:
            if j >= c:
                return struct_row_field_ti(si, i)
            w := w0 + j
            if w >= 0:
                if struct_field_index_by_name(si, ast_b(w)) == i:
                    fd := ast_data(w)
                    if fd > 0:
                        return fd - 1
                    return struct_row_field_ti(si, i)
            j = j + 1
        return -1
    if k == 3:
        if ti < 0 || get_type_kind(ti) != TYP_TUPLE:
            return -1
        ac : ., mut = get_type_data(ti)
        if i >= ac:
            return -1
        return cell_load(g_gen_apply_data, (get_type_extra(ti) + i) * 8)
    return -1

fn dt_pat_supported(p: int, ti: int) -> int:
    if p < 0 || dt_pat_wild(p) != 0:
        return 1
    k : ., mut = dt_ctor_kind(p)
    if k == 0:
        return 0
    arity := dt_ctor_arity(p, ti)
    if arity < 0:
        return 0
    i : ., mut = 0
    loop:
        if i >= arity:
            return 1
        sub := dt_subpat(p, i)
        if sub >= 0:
            ft := dt_subpat_ti(p, i, ti)
            if ft < 0:
                return 0
            if ti_has_generic_param(ft) != 0:
                return 0
            if dt_pat_supported(sub, ft) == 0:
                return 0
        i = i + 1
    return 1

// How many distinct non-wild head constructors a column has. -1 = mixed kinds.
fn dt_col_distinct(rows: string, pats: string, row_count: int, col_count: int, col: int) -> int:
    seen_k := alloc((row_count + 1) * 8)
    seen_id := alloc((row_count + 1) * 8)
    n : ., mut = 0
    r : ., mut = 0
    loop:
        if r >= row_count:
            return n
        p := cell_load(pats, (r * col_count + col) * 8)
        if dt_pat_wild(p) == 0:
            ck := dt_ctor_kind(p)
            if ck == 0:
                return -1
            if n > 0 && cell_load(seen_k, 0) != ck:
                return -1
            cid := dt_ctor_id(p)
            dup : ., mut = 0
            j : ., mut = 0
            loop:
                if j >= n:
                    break
                if cell_load(seen_k, j * 8) == ck:
                    if cell_load(seen_id, j * 8) == cid:
                        dup = 1
                        break
                j = j + 1
            if dup == 0:
                cell_store(seen_k, n * 8, ck)
                cell_store(seen_id, n * 8, cid)
                n = n + 1
        r = r + 1
    return n

fn dt_find_ctor_pat(pats: string, row_count: int, col_count: int, cid: int) -> int:
    r : ., mut = 0
    loop:
        if r >= row_count:
            return -1
        p := cell_load(pats, r * col_count * 8)
        if dt_pat_wild(p) == 0:
            if dt_ctor_id(p) == cid:
                return p
        r = r + 1
    return -1

fn dt_col_first_pat(rows: string, pats: string, row_count: int, col_count: int, col: int) -> int:
    r : ., mut = 0
    loop:
        if r >= row_count:
            return -1
        p := cell_load(pats, (r * col_count + col) * 8)
        if dt_pat_wild(p) == 0:
            return p
        r = r + 1
    return -1

    // Keep only rows whose head is a wildcard; drop the head column.
fn dt_default_rows(rows: string, pats: string, row_count: int, col_count: int,
                   out_rows: string, out_pats: string) -> int:
    n : ., mut = 0
    r : ., mut = 0
    loop:
        if r >= row_count:
            return n
        p := cell_load(pats, r * col_count * 8)
        if dt_pat_wild(p) != 0:
            cell_store(out_rows, n * 8, cell_load(rows, r * 8))
            c : ., mut = 1
            loop:
                if c >= col_count:
                    break
                cell_store(out_pats, (n * (col_count - 1) + c - 1) * 8,
                    cell_load(pats, (r * col_count + c) * 8))
                c = c + 1
            n = n + 1
        r = r + 1
    return n

    // Expand one constructor case into (other columns ++ constructor sub-columns).
    // Returns the new row count. `out_*` capacity = row_count and
    // row_count * (col_count - 1 + arity) respectively.
fn dt_specialize(rows: string, pats: string, cols: string, tis: string,
                 row_count: int, col_count: int, ck: int, cid: int, arity: int,
                 ctor_pat: int,
                 out_rows: string, out_pats: string, out_cols: string, out_tis: string) -> int:
    new_cols := col_count - 1 + arity
    val := cell_load(cols, 0)
    val_ti := cell_load(tis, 0)
    sub_cols := alloc((arity + 1) * 8)
    sub_tis := alloc((arity + 1) * 8)
    i : ., mut = 0
    loop:
        if i >= arity:
            break
        fv := new_ir_var("dt_fld", TI_INT)
        ft : ., mut = -1
        if ctor_pat >= 0:
            ft = dt_subpat_ti(ctor_pat, i, val_ti)
        if ft >= 0:
            irv_set_type(fv, structpat_field_load_ti_from(ft))
        offset : ., mut = i
        if ck == 1:
            offset = i + 1
        emit(IR_LOAD_FIELD, fv, val, 0, offset, 0)
        cell_store(sub_cols, i * 8, fv)
        cell_store(sub_tis, i * 8, ft)
        i = i + 1
    n : ., mut = 0
    r : ., mut = 0
    loop:
        if r >= row_count:
            return n
        p := cell_load(pats, r * col_count * 8)
        take : ., mut = 0
        if dt_pat_wild(p) != 0:
            take = 1
        else if dt_ctor_kind(p) == ck:
            if dt_ctor_id(p) == cid:
                take = 1
        if take != 0:
            cell_store(out_rows, n * 8, cell_load(rows, r * 8))
            c : ., mut = 1
            loop:
                if c >= col_count:
                    break
                cell_store(out_pats, (n * new_cols + c - 1) * 8,
                    cell_load(pats, (r * col_count + c) * 8))
                cell_store(out_cols, (c - 1) * 8, cell_load(cols, c * 8))
                cell_store(out_tis, (c - 1) * 8, cell_load(tis, c * 8))
                c = c + 1
            i = 0
            loop:
                if i >= arity:
                    break
                sub : ., mut = -1
                if dt_pat_wild(p) == 0:
                    sub = dt_subpat(p, i)
                cell_store(out_pats, (n * new_cols + col_count - 1 + i) * 8, sub)
                cell_store(out_cols, (col_count - 1 + i) * 8, cell_load(sub_cols, i * 8))
                cell_store(out_tis, (col_count - 1 + i) * 8, cell_load(sub_tis, i * 8))
                i = i + 1
            n = n + 1
        r = r + 1
    return n

// Reorder `best` to column 0. Column order is the only thing that changes.
fn dt_move_col(rows: string, pats: string, cols: string, tis: string,
               row_count: int, col_count: int, best: int,
               out_pats: string, out_cols: string, out_tis: string):
    r : ., mut = 0
    c : ., mut = 0
    loop:
        if r >= row_count:
            break
        c = 0
        loop:
            if c >= col_count:
                break
            src : ., mut = c
            if c == 0:
                src = best
            else if c == best:
                src = 0
            cell_store(out_pats, (r * col_count + c) * 8,
                cell_load(pats, (r * col_count + src) * 8))
            c = c + 1
        r = r + 1
    c = 0
    loop:
        if c >= col_count:
            break
        src : ., mut = c
        if c == 0:
            src = best
        else if c == best:
            src = 0
        cell_store(out_cols, c * 8, cell_load(cols, src * 8))
        cell_store(out_tis, c * 8, cell_load(tis, src * 8))
        c = c + 1

// One string literal equality test. Success jumps to the arm label; failure
// jumps to the next test in the same bucket or to the default edge.
fn dt_emit_str_eq(val: int, ni: int, ok: int, miss: int):
    lit := new_ir_var("dt_slit", TI_STR)
    track_str(ni)
    emit(IR_CONST, lit, ni, 0, 0, TI_STR)
    e0 := new_ir_var("dt_eq0", TI_STR)
    e1 := new_ir_var("dt_eq1", TI_STR)
    emit(IR_STORE, -1, e0, val, 0, 0)
    emit(IR_STORE, -1, e1, lit, 0, 0)
    cmp := new_ir_var("dt_seq", TI_BOOL)
    emit(IR_CALL, cmp, e0, 2, str_intern("str_eq"), TI_BOOL)
    emit_cond_match(cmp, miss, ok)

// Index tree for a string column: str_len once, then one test per distinct
// length; within a length bucket one load8 and one test per distinct first
// byte; within a first-byte bucket one str_eq per literal. A length bucket
// with a single literal needs no first-byte test (length already identifies it).
fn dt_emit_string_switch(val: int, cids: string, cn: int,
                         case_lbls: string, default_lbl: int):
    if cn <= 0:
        emit(IR_JUMP, -1, default_lbl, 0, 0, 0)
        return
    // Distinct lengths in first-appearance order.
    lens := alloc((cn + 1) * 8)
    ln : ., mut = 0
    j : ., mut = 0
    k : ., mut = 0
    loop:
        if j >= cn:
            break
        L := istr_len(cell_load(cids, j * 8))
        dup : ., mut = 0
        k = 0
        loop:
            if k >= ln:
                break
            if cell_load(lens, k * 8) == L:
                dup = 1
                break
            k = k + 1
        if dup == 0:
            cell_store(lens, ln * 8, L)
            ln = ln + 1
        j = j + 1
    len_var := new_ir_var("dt_slen", TI_INT)
    emit(IR_CALL, len_var, val, 1, str_intern("str_len"), TI_INT)
    len_lbls := alloc((ln + 1) * 8)
    i : ., mut = 0
    loop:
        if i >= ln:
            break
        L := cell_load(lens, i * 8)
        lbl := new_label()
        cell_store(len_lbls, i * 8, lbl)
        pv := new_ir_var("dt_lv", TI_INT)
        emit(IR_CONST, pv, L, 0, 0, TI_INT)
        cmp := new_ir_var("dt_lc", TI_INT)
        emit(IR_BINARY, cmp, len_var, pv, OP_EQ, 0)
        miss : ., mut = default_lbl
        if i + 1 < ln:
            miss = new_label()
        emit_cond_match(cmp, miss, lbl)
        if i + 1 < ln:
            emit(IR_LABEL, -1, miss, 0, 0, 0)
        i = i + 1
    // Length buckets in the same order.
    i = 0
    loop:
        if i >= ln:
            break
        L := cell_load(lens, i * 8)
        emit(IR_LABEL, -1, cell_load(len_lbls, i * 8), 0, 0, 0)
        cnt : ., mut = 0
        j = 0
        loop:
            if j >= cn:
                break
            if istr_len(cell_load(cids, j * 8)) == L:
                cnt = cnt + 1
            j = j + 1
        if cnt <= 1:
            // Length identifies the literal; compare it directly.
            j = 0
            loop:
                if j >= cn:
                    break
                if istr_len(cell_load(cids, j * 8)) == L:
                    dt_emit_str_eq(val, cell_load(cids, j * 8),
                        cell_load(case_lbls, j * 8), default_lbl)
                    break
                j = j + 1
        else:
            // Distinct first bytes in this length bucket.
            fbytes := alloc((cnt + 1) * 8)
            fbcount : ., mut = 0
            j = 0
            loop:
                if j >= cn:
                    break
                ni := cell_load(cids, j * 8)
                if istr_len(ni) == L:
                    B : ., mut = 0
                    if L > 0:
                        B = str_load8(ni, 0)
                    dup : ., mut = 0
                    k : ., mut = 0
                    loop:
                        if k >= fbcount:
                            break
                        if cell_load(fbytes, k * 8) == B:
                            dup = 1
                            break
                        k = k + 1
                    if dup == 0:
                        cell_store(fbytes, fbcount * 8, B)
                        fbcount = fbcount + 1
                j = j + 1
            first_var : ., mut = -1
            if L > 0:
                fb0 := new_ir_var("_dt_fb0", TI_STR)
                fb1 := new_ir_var("_dt_fb1", TI_INT)
                fbz := new_ir_var("_dt_fbz", TI_INT)
                emit(IR_CONST, fbz, 0, 0, 0, TI_INT)
                emit(IR_STORE, -1, fb0, val, 0, 0)
                emit(IR_STORE, -1, fb1, fbz, 0, 0)
                first_var = new_ir_var("dt_sfb", TI_INT)
                emit(IR_CALL, first_var, fb0, 2, str_intern("load8"), TI_INT)
            fbls := alloc((fbcount + 1) * 8)
            k = 0
            loop:
                if k >= fbcount:
                    break
                B := cell_load(fbytes, k * 8)
                lbl := new_label()
                cell_store(fbls, k * 8, lbl)
                cmp := new_ir_var("dt_fc", TI_INT)
                if L > 0:
                    pv := new_ir_var("dt_fv", TI_INT)
                    emit(IR_CONST, pv, B, 0, 0, TI_INT)
                    emit(IR_BINARY, cmp, first_var, pv, OP_EQ, 0)
                else:
                    emit(IR_CONST, cmp, 1, 0, 0, TI_INT)
                miss : ., mut = default_lbl
                if k + 1 < fbcount:
                    miss = new_label()
                emit_cond_match(cmp, miss, lbl)
                if k + 1 < fbcount:
                    emit(IR_LABEL, -1, miss, 0, 0, 0)
                k = k + 1
            // First-byte buckets.
            k = 0
            loop:
                if k >= fbcount:
                    break
                emit(IR_LABEL, -1, cell_load(fbls, k * 8), 0, 0, 0)
                B := cell_load(fbytes, k * 8)
                gidx := alloc((cnt + 1) * 8)
                gn : ., mut = 0
                j = 0
                loop:
                    if j >= cn:
                        break
                    ni := cell_load(cids, j * 8)
                    if istr_len(ni) == L:
                        B2 : ., mut = 0
                        if L > 0:
                            B2 = str_load8(ni, 0)
                        if B2 == B:
                            cell_store(gidx, gn * 8, j)
                            gn = gn + 1
                    j = j + 1
                g : ., mut = 0
                loop:
                    if g >= gn:
                        break
                    idx : ., mut = cell_load(gidx, g * 8)
                    miss : ., mut = default_lbl
                    if g + 1 < gn:
                        miss = new_label()
                    dt_emit_str_eq(val, cell_load(cids, idx * 8),
                        cell_load(case_lbls, idx * 8), miss)
                    if g + 1 < gn:
                        emit(IR_LABEL, -1, miss, 0, 0, 0)
                    g = g + 1
                k = k + 1
        i = i + 1

// Emit one decision node. Returns 0 on success, -1 on an unsupported shape
// (already emitted a fall edge; callers must not try to rewind IR).
fn dt_compile(rows: string, pats: string, cols: string, tis: string,
              row_count: int, col_count: int, fall: int, arm_lbls: string) -> int:
    if row_count <= 0:
        emit(IR_JUMP, -1, fall, 0, 0, 0)
        return 0
    // Leaf: the first row is irrefutable for every remaining column.
    allw : ., mut = 1
    i : ., mut = 0
    loop:
        if i >= col_count:
            break
        p := cell_load(pats, i * 8)
        if dt_pat_wild(p) == 0:
            allw = 0
            break
        i = i + 1
    if allw != 0:
        ai : ., mut = cell_load(rows, 0)
        emit(IR_JUMP, -1, cell_load(arm_lbls, ai * 8), 0, 0, 0)
        return 0
    // FCR column selection.
    best : ., mut = -1
    best_score : ., mut = 1000000
    c : ., mut = 0
    loop:
        if c >= col_count:
            break
        n := dt_col_distinct(rows, pats, row_count, col_count, c)
        if n > 0 && n < best_score:
            best_score = n
            best = c
        c = c + 1
    if best < 0:
        emit(IR_JUMP, -1, fall, 0, 0, 0)
        return -1
    mpats := alloc(row_count * col_count * 8)
    mcols := alloc(col_count * 8)
    mtis := alloc(col_count * 8)
    dt_move_col(rows, pats, cols, tis, row_count, col_count, best, mpats, mcols, mtis)
    p0 := dt_col_first_pat(rows, mpats, row_count, col_count, 0)
    if p0 < 0:
        emit(IR_JUMP, -1, fall, 0, 0, 0)
        return -1
    ck := dt_ctor_kind(p0)
    cid := dt_ctor_id(p0)
    arity := dt_ctor_arity(p0, cell_load(mtis, 0))
    if arity < 0:
        emit(IR_JUMP, -1, fall, 0, 0, 0)
        return -1
    // struct/tuple: one constructor, expand without a runtime test. A mixed
    // constructor set here means the checker let an impossible shape through;
    // fail closed rather than dropping rows.
    if ck == 2 || ck == 3:
        if dt_col_distinct(rows, mpats, row_count, col_count, 0) != 1:
            emit(IR_JUMP, -1, fall, 0, 0, 0)
            return -1
        new_cols := col_count - 1 + arity
        orows := alloc((row_count + 1) * 8)
        opats := alloc((row_count + 1) * (new_cols + 1) * 8)
        ocols := alloc((new_cols + 1) * 8)
        otis := alloc((new_cols + 1) * 8)
        n := dt_specialize(rows, mpats, mcols, mtis, row_count, col_count,
            ck, cid, arity, p0, orows, opats, ocols, otis)
        return dt_compile(orows, opats, ocols, otis, n, new_cols, fall, arm_lbls)
    // Collect distinct constructors for the switched column.
    ckinds := alloc((row_count + 1) * 8)
    cids := alloc((row_count + 1) * 8)
    cn : ., mut = 0
    r : ., mut = 0
    loop:
        if r >= row_count:
            break
        p := cell_load(mpats, r * col_count * 8)
        if dt_pat_wild(p) == 0:
            k2 := dt_ctor_kind(p)
            id2 := dt_ctor_id(p)
            dup : ., mut = 0
            j : ., mut = 0
            loop:
                if j >= cn:
                    break
                if cell_load(ckinds, j * 8) == k2:
                    if cell_load(cids, j * 8) == id2:
                        dup = 1
                        break
                j = j + 1
            if dup == 0:
                cell_store(ckinds, cn * 8, k2)
                cell_store(cids, cn * 8, id2)
                cn = cn + 1
        r = r + 1
    // Default matrix = wildcard rows with the head column removed.
    drows := alloc((row_count + 1) * 8)
    dpats := alloc((row_count + 1) * (col_count - 1 + 1) * 8)
    dcols := alloc(col_count * 8)
    dtis := alloc(col_count * 8)
    dn := dt_default_rows(rows, mpats, row_count, col_count, drows, dpats)
    c = 1
    loop:
        if c >= col_count:
            break
        cell_store(dcols, (c - 1) * 8, cell_load(mcols, c * 8))
        cell_store(dtis, (c - 1) * 8, cell_load(mtis, c * 8))
        c = c + 1
    // Completeness: every variant of an enum, or both booleans. Ints/chars/
    // strings are infinite and always need the default edge.
    complete : ., mut = 0
    if ck == 1:
        ea := enum_row_of_pat(cell_load(mtis, 0), p0)
        if ea >= 0 && cn == ei_variant_count(ea):
            complete = 1
    else if ck == 5:
        if cn == 2:
            complete = 1
    case_lbls := alloc((cn + 1) * 8)
    j : ., mut = 0
    loop:
        if j >= cn:
            break
        cell_store(case_lbls, j * 8, new_label())
        j = j + 1
    default_lbl := new_label()
    // Emit tests. For enums read the tag once; scalar/string columns compare
    // the value directly. Every miss goes to the default edge, which either
    // continues the wildcard matrix or falls through to the merge label.
    tag : ., mut = -1
    if ck == 1:
        tag = new_ir_var("dt_tag", TI_INT)
        emit(IR_LOAD_ENUM_TAG, tag, cell_load(mcols, 0), 0, 0, 0)
    if ck == 7:
        dt_emit_string_switch(cell_load(mcols, 0), cids, cn, case_lbls, default_lbl)
    else:
        j : ., mut = 0
        loop:
            if j >= cn:
                break
            cl := cell_load(case_lbls, j * 8)
            k2 := cell_load(ckinds, j * 8)
            id2 := cell_load(cids, j * 8)
            miss_lbl : ., mut = default_lbl
            if j + 1 < cn:
                miss_lbl = new_label()
            cmp := new_ir_var("dt_cmp", TI_INT)
            if k2 == 1:
                vtag := new_ir_var("dt_vtag", TI_INT)
                emit(IR_CONST, vtag, id2, 0, 0, TI_INT)
                emit(IR_BINARY, cmp, tag, vtag, OP_EQ, 0)
                emit_cond_match(cmp, miss_lbl, cl)
            else if k2 == 5:
                bv : ., mut = 0
                if id2 != 0:
                    bv = 1
                pv := new_ir_var("dt_pv", TI_BOOL)
                emit(IR_CONST, pv, bv, 0, 0, TI_BOOL)
                emit(IR_BINARY, cmp, cell_load(mcols, 0), pv, OP_EQ, 0)
                emit_cond_match(cmp, miss_lbl, cl)
            else if k2 == 4:
                pv := new_ir_var("dt_pv", TI_INT)
                emit(IR_CONST, pv, id2, 0, 0, TI_INT)
                emit(IR_BINARY, cmp, cell_load(mcols, 0), pv, OP_EQ, 0)
                emit_cond_match(cmp, miss_lbl, cl)
            else if k2 == 6:
                // Char slots are untagged intern indexes; compare as TI_CHAR.
                pv := new_ir_var("dt_pv", TI_CHAR)
                track_str(id2)
                emit(IR_CONST, pv, id2, 0, 0, TI_CHAR)
                emit(IR_BINARY, cmp, cell_load(mcols, 0), pv, OP_EQ, 0)
                emit_cond_match(cmp, miss_lbl, cl)
            else if k2 == 7:
                pv := new_ir_var("dt_pv", TI_STR)
                track_str(id2)
                emit(IR_CONST, pv, id2, 0, 0, TI_STR)
                e0 := new_ir_var("dt_e0", TI_STR)
                e1 := new_ir_var("dt_e1", TI_STR)
                emit(IR_STORE, -1, e0, cell_load(mcols, 0), 0, 0)
                emit(IR_STORE, -1, e1, pv, 0, 0)
                emit(IR_CALL, cmp, e0, 2, str_intern("str_eq"), TI_BOOL)
                emit_cond_match(cmp, miss_lbl, cl)
            else:
                emit(IR_JUMP, -1, fall, 0, 0, 0)
            if j + 1 < cn:
                emit(IR_LABEL, -1, miss_lbl, 0, 0, 0)
            j = j + 1
    // Default edge: wildcard rows for non-exhaustive constructor sets. For a
    // complete enum/bool switch it is unreachable (wild rows already appear in
    // every case branch), so keep the fall edge.
    emit(IR_LABEL, -1, default_lbl, 0, 0, 0)
    if complete == 0 && dn > 0:
        dt_compile(drows, dpats, dcols, dtis, dn, col_count - 1, fall, arm_lbls)
    else:
        emit(IR_JUMP, -1, fall, 0, 0, 0)
    j = 0
    loop:
        if j >= cn:
            break
        emit(IR_LABEL, -1, cell_load(case_lbls, j * 8), 0, 0, 0)
        k2 := cell_load(ckinds, j * 8)
        id2 := cell_load(cids, j * 8)
        a2 : ., mut = 0
        if k2 == 1:
            ea := enum_row_of_pat(cell_load(mtis, 0), p0)
            vi := sh_enum_variant_index(ea, id2)
            if ea >= 0 && vi >= 0:
                a2 = ei_variant_type_count(ea, vi)
        new_cols := col_count - 1 + a2
        orows := alloc((row_count + 1) * 8)
        opats := alloc((row_count + 1) * (new_cols + 1) * 8)
        ocols := alloc((new_cols + 1) * 8)
        otis := alloc((new_cols + 1) * 8)
        ctor_pat := dt_find_ctor_pat(mpats, row_count, col_count, id2)
        n := dt_specialize(rows, mpats, mcols, mtis, row_count, col_count,
            k2, id2, a2, ctor_pat, orows, opats, ocols, otis)
        dt_compile(orows, opats, ocols, otis, n, new_cols, fall, arm_lbls)
        j = j + 1
    return 0


fn gen_expr(node: int) -> int:
    if node < 0:
        return -1

    if ast_kind(node) == EXPR_NONE:
        // Wrapper node: forward to inner expression (used in struct literals)
        if ast_a(node) >= 0 && ast_a(node) != node:
            return gen_expr(ast_a(node))
        return -1

    // Literals
    if ast_kind(node) == EXPR_INT:
        v := new_ir_var("int", TI_INT)
        emit(IR_CONST, v, ast_int_val(node), 0, 0, TI_INT)
        return v
    if ast_kind(node) == EXPR_BIGINT:
        v := new_ir_var("bigint", TI_INT)
        emit(IR_CONST_BIG, v, ast_a(node), 0, 0, TI_INT)
        return v
    if ast_kind(node) == EXPR_DEX:
        // 精确字面量：定点缩放整数常量（TI_DEX_S）。
        // apx 场景（变量级 apx 标签的运算）在运算点按 node.a 的 binary64 位模式重发射。
        v := new_ir_var("dex", TI_DEX_S)
        emit(IR_CONST, v, ast_int_val(node), 0, 0, TI_DEX_S)
        return v
    if ast_kind(node) == EXPR_BOOL:
        v := new_ir_var("bool", TI_BOOL)
        emit(IR_CONST, v, ast_int_val(node), 0, 0, TI_BOOL)
        return v
    if ast_kind(node) == EXPR_STRING:
        v := new_ir_var("str", TI_STR)
        str_idx := ast_int_val(node)
        track_str(str_idx)
        emit(IR_CONST, v, str_idx, 0, 0, TI_STR)
        return v
    // 插值洞的后备路径：洞应在 checker 就被就地改写（见 checker.cr EXPR_INTERP_HOLE
    // 分支：string 恒等 / int->int_str / bool->bool_str，其它 P028）。若仍有洞走到发射路径，说明
    // checker 漏走了某条路径（extern 早退 / 实例体 / 未来新路径）-> 响亮拒绝，
    // 绝不当作空值且不报错或身份，that is the class of wrong values this code prevents。
    if ast_kind(node) == EXPR_INTERP_HOLE:
        check_error(EC_P_INTERP_HOLE_LEAK, "internal: string interpolation hole reached codegen (checker rewrite missing)", ast_line(node), ast_col(node))
        v := new_ir_var("interp_leak", TI_STR)
        emit(IR_CONST, v, str_intern(""), 0, 0, TI_STR)
        return v

    if ast_kind(node) == EXPR_CHAR:
        v := new_ir_var("char", TI_CHAR)
        str_idx := ast_int_val(node)
        track_str(str_idx)
        emit(IR_CONST, v, str_idx, 0, 0, TI_CHAR)
        return v

    // Identifier: local or global variable
    if ast_kind(node) == EXPR_IDENT:
        name_idx := ast_int_val(node)
        lv := find_local(name_idx)
        if lv >= 0:
            return lv
        const_node : ., mut = find_global_const_ctx(name_idx, node)
        // 容量阶段 T2：可选全局槽不得常量折叠，字面量初值（`g : int? = 5`）的读点若被
        // 折成裸常量 5，则 match 的 tag 读会解引用该裸值(both paths fail at run time)。
        // 折叠只对非可选全局生效（零足迹）；可选全局由运行期初始化写入装箱对象。
        if const_node >= 0 && g_optrep_on != 0 && global_optional_ctx(name_idx, node) != 0:
            const_node = -1
        if const_node >= 0:
            const_type : ., mut = TI_INT
            if ast_kind(const_node) == EXPR_BOOL:
                const_type = TI_BOOL
            if ast_kind(const_node) == EXPR_DEX:
                const_type = TI_DEX_S
            // 定点缩放常量
            cv := new_ir_var("const", const_type)
            emit(IR_CONST, cv, ast_int_val(const_node), 0, 0, const_type)
            return cv
        gv := find_global_ctx(name_idx, node)
        if gv >= 0:
            return gv
        // A bare enum variant (c := Red, no parentheses) emits MAKE_ENUM with no
        // payload: s1 = variant name intern index, s2 = 0. This is the same
        // mechanism as the Red() constructor form. The tag is the variant name
        // intern index, and match compares by name.
        if find_enum_variant(name_idx) >= 0:
            s := new_ir_var("enum", TI_UNIT)
            emit(IR_MAKE_ENUM, s, name_idx, 0, 0, 0)
            return s
        // Could be a function name being used as a value - return dummy
        v := new_ir_var("unresolved", TI_UNIT)
        return v

    // Binary operation
    if ast_kind(node) == EXPR_BINARY:
        left := ast_a(node)
        right := ast_b(node)
        op : ., mut = ast_c(node)

        // `EXPR_BINARY + OP_ASSIGN` 赋值分支已删，不可达
        // （parser 不产该组合：`tok2op` 零 OP_ASSIGN；`T_EQ` -> EXPR_ASSIGN；`+=` 族构造
        // `EXPR_ASSIGN` 包裹的 EXPR_BINARY 且 op ∈ {ADD,SUB,MUL,DIV}；语料站点直方图 0 命中）。
        // 赋值发射路径在下方 `EXPR_ASSIGN` 分支（gen_expr 的另一 arm），逐字未动。

        // Regular binary
        left_var : ., mut = gen_expr(left)
        left_var = force_if_thunk(left_var)
        // Logical operators must short-circuit.  Eagerly generating the
        // right side breaks guard expressions such as
        // `fi >= 0 && fi_generic_count(fi) > 0`.
        if op == OP_AND || op == OP_OR:
            right_lbl := new_label()
            short_lbl := new_label()
            merge_lbl := new_label()
            logic_result := new_ir_var("logic", TI_BOOL)
            if op == OP_AND:
                emit_cond_match(left_var, short_lbl, right_lbl)
            else:
                emit_cond_match(left_var, right_lbl, short_lbl)

            emit(IR_LABEL, -1, short_lbl, 0, 0, 0)
            short_value := new_ir_var("logic_short", TI_BOOL)
            if op == OP_AND:
                emit(IR_CONST, short_value, 0, 0, 0, TI_BOOL)
            else:
                emit(IR_CONST, short_value, 1, 0, 0, TI_BOOL)
            emit(IR_STORE, -1, logic_result, short_value, 0, 0)
            emit(IR_JUMP, -1, merge_lbl, 0, 0, 0)

            emit(IR_LABEL, -1, right_lbl, 0, 0, 0)
            right_value : ., mut = gen_expr(right)
            right_value = force_if_thunk(right_value)
            emit(IR_STORE, -1, logic_result, right_value, 0, 0)
            emit(IR_JUMP, -1, merge_lbl, 0, 0, 0)

            emit(IR_LABEL, -1, merge_lbl, 0, 0, 0)
            return logic_result
        right_var : ., mut = gen_expr(right)
        right_var = force_if_thunk(right_var)
        lt : ., mut = irv_type(left_var)
        rt : ., mut = irv_type(right_var)

        // Unwrap dyn operands: extract the underlying value for binary ops
        if lt == TI_DYN:
            uv := new_ir_var("_dynval", TI_UNIT)
            emit(IR_DYN_VAL, uv, left_var, 0, 0, 0)
            left_var = uv
            lt = irv_type(left_var)
        if rt == TI_DYN:
            uv := new_ir_var("_dynval", TI_UNIT)
            emit(IR_DYN_VAL, uv, right_var, 0, 0, 0)
            right_var = uv
            rt = irv_type(right_var)

        // Optional == and != compare by value, independent of representation.
        // Both sides are normalized to (absent, payload). Different absence means
        // not equal; both absent means equal; both present compares payloads. The
        // trigger is conservative (representation bit, Some/None constructor, or
        // optional declaration), so non-optional comparisons are unchanged.
        if (op == OP_EQ || op == OP_NE) && g_optrep_on != 0:
            lo := opt_cmp_optish(left, left_var)
            ro := opt_cmp_optish(right, right_var)
            if lo != 0 || ro != 0:
                lt2 : ., mut = TI_INT
                if left_var >= 0:
                    lt2 = irv_type(left_var)
                rt2 : ., mut = TI_INT
                if right_var >= 0:
                    rt2 = irv_type(right_var)
                abs_l := new_ir_var("absl", TI_INT)
                val_l := new_ir_var("vall", lt2)
                abs_r := new_ir_var("absr", TI_INT)
                val_r := new_ir_var("valr", rt2)
                opt_cmp_norm(left, left_var, abs_l, val_l)
                opt_cmp_norm(right, right_var, abs_r, val_r)
                zb := new_ir_var("_cz", TI_INT)
                emit(IR_CONST, zb, 0, 0, 0, TI_INT)
                // peq = 携带值相等（两侧皆缺省时其值无意义，由 both_abs 覆盖）
                peq : ., mut = -1
                if lt2 == TI_STR || rt2 == TI_STR:
                    eq0 := new_ir_var("_eq0", lt2)
                    eq1 := new_ir_var("_eq1", rt2)
                    emit(IR_STORE, -1, eq0, val_l, 0, 0)
                    emit(IR_STORE, -1, eq1, val_r, 0, 0)
                    peq = new_ir_var("str_eq", TI_BOOL)
                    emit(IR_CALL, peq, eq0, 2, str_intern("str_eq"), TI_BOOL)
                else:
                    peq = new_ir_var("peq", TI_INT)
                    emit(IR_BINARY, peq, val_l, val_r, OP_EQ, 0)
                both_abs := new_ir_var("bothz", TI_INT)
                emit(IR_BINARY, both_abs, abs_l, abs_r, OP_AND, 0)
                eqv := new_ir_var("eqv", TI_INT)
                emit(IR_BINARY, eqv, both_abs, peq, OP_OR, 0)
                abs_eq := new_ir_var("abeq", TI_INT)
                emit(IR_BINARY, abs_eq, abs_l, abs_r, OP_EQ, 0)
                eqi := new_ir_var("eqi", TI_INT)
                emit(IR_BINARY, eqi, abs_eq, eqv, OP_AND, 0)
                if op == OP_EQ:
                    res := new_ir_var("optcmp", TI_BOOL)
                    emit(IR_BINARY, res, eqi, zb, OP_NE, TI_BOOL)
                    return res
                res := new_ir_var("optcmp", TI_BOOL)
                emit(IR_BINARY, res, eqi, zb, OP_EQ, TI_BOOL)
                return res

        // String equality compares contents, not pointer values.
        if (op == OP_EQ || op == OP_NE) && (lt == TI_STR || rt == TI_STR):
            eq_ni := str_intern("str_eq")
            eq_arg0 := new_ir_var("_eq0", lt)
            eq_arg1 := new_ir_var("_eq1", rt)
            emit(IR_STORE, -1, eq_arg0, left_var, 0, 0)
            emit(IR_STORE, -1, eq_arg1, right_var, 0, 0)
            eq_value := new_ir_var("str_eq", TI_BOOL)
            emit(IR_CALL, eq_value, eq_arg0, 2, eq_ni, TI_BOOL)
            if op == OP_EQ:
                return eq_value
            zero_value := new_ir_var("zero", TI_INT)
            emit(IR_CONST, zero_value, 0, 0, 0, TI_INT)
            ne_value := new_ir_var("str_ne", TI_BOOL)
            emit(IR_BINARY, ne_value, eq_value, zero_value, OP_EQ, TI_BOOL)
            return ne_value
        // String concatenation — call concat() instead of IR_BINARY
        if op == OP_ADD:
            if lt == TI_STR || rt == TI_STR:
                concat_ni := str_intern("concat")
                // Pack both args into consecutive vars so ELF backend finds them
                packed0 := new_ir_var("_cat0", lt)
                packed1 := new_ir_var("_cat1", rt)
                emit(IR_STORE, -1, packed0, left_var, 0, 0)
                emit(IR_STORE, -1, packed1, right_var, 0, 0)
                v := new_ir_var("str", TI_STR)
                emit(IR_CALL, v, packed0, 2, concat_ni, TI_STR)
                return v
        // apx 阶段 T3（L10 · 比较/运算点的声明信息查表）：聚合读的结果槽 IR 型恒 TI_INT
        // （读点定型丢失声明型）-> 当操作数节点是聚合读且声明信息为 dex 时，槽内
        // The canonical form is exact (scaled), guaranteed by the write points. It
        // participates as TI_DEX_S; otherwise it falls into the TI_INT I2F branch
        // and a scaled integer is converted to double as if it were an int.
        // 作用域：只覆盖本分流点；不改读点定型（那是  的爆炸半径，/ 另阶段）。
        if lt == TI_INT && dex_decl_form_of_expr(left) != 0:
            lt = TI_DEX_S
        if rt == TI_INT && dex_decl_form_of_expr(right) != 0:
            rt = TI_DEX_S
        fti : int, mut = TI_INT
        // Pointer arithmetic: use PTR_ADD/PTR_SUB/PTR_DIFF instead of standard opcodes.
        // Raw byte buffers from alloc() are byte-addressed — separate byte ops
        // keep the raw pointer and untag the integer offset without the ×8 scale.
        buf_left := is_byte_buf_var(left_var)
        buf_right := is_byte_buf_var(right_var)
        if (buf_left != 0 || buf_right != 0) && (op == OP_ADD || op == OP_SUB):
            if buf_left == 0:
                // int + buffer: normalize to buffer + int.
                if op == OP_ADD:
                    tmp_buf := left_var
                    left_var = right_var
                    right_var = tmp_buf
                    op = OP_BYTE_ADD
            else:
                if op == OP_ADD:
                    op = OP_BYTE_ADD
                else:
                    op = OP_BYTE_SUB
        else if is_ptr_var(left_var) != 0 || is_ptr_var(right_var) != 0:
            if op == OP_ADD:
                op = OP_PTR_ADD
            else if op == OP_SUB:
                if is_ptr_var(left_var) != 0 && is_ptr_var(right_var) != 0:
                    op = OP_PTR_DIFF
                else:
                    op = OP_PTR_SUB
        if op == OP_PTR_ADD || op == OP_PTR_SUB:
            if is_ptr_var(left_var) != 0:
                fti = irv_type(left_var)
            else if is_ptr_var(right_var) != 0:
                fti = irv_type(right_var)
        // dex 运算分流：
        //   有 TI_DEX（apx 形式）操作数 -> binary64 快路径（SSE2，IEEE 754，apx 标准答案）
        //   有 TI_DEX_S（定点形式）操作数 -> 精确路径（缩放整数指令序列）
        if lt == TI_DEX || rt == TI_DEX:
            fti = TI_DEX
            // apx 路径操作数处理：字面量 -> 重发射 bits 常量；定点（TI_DEX_S）->
            // I2F/S 转 bits（按精确值参与，apx 授权的近似）；int -> I2F（隐式转换）
            if lt == TI_DEX_S:
                left_var = dex_scaled_to_bits(left_var, left)
            else if lt == TI_INT:
                t1 := new_ir_var("_f0", TI_DEX)
                emit(IR_I2F, t1, left_var, 0, 0, TI_DEX)
                left_var = t1
            if rt == TI_DEX_S:
                right_var = dex_scaled_to_bits(right_var, right)
            else if rt == TI_INT:
                t2 := new_ir_var("_f1", TI_DEX)
                emit(IR_I2F, t2, right_var, 0, 0, TI_DEX)
                right_var = t2
            v := new_ir_var("bin", fti)
            emit(IR_BINARY, v, left_var, right_var, op, fti)
            return v
        if lt == TI_DEX_S || rt == TI_DEX_S:
            fti = TI_DEX_S
            // 精确路径操作数处理：int -> ×S（隐式缩放）；定点（TI_DEX_S）直接参与
            if lt == TI_INT:
                left_var = dex_scale_int(left_var)
            if rt == TI_INT:
                right_var = dex_scale_int(right_var)
            if op == OP_MUL:
                // (a×b)/S：先乘后缩回（中间值 a·b ≤ 9.2e18 -> |值| ≤ 3.03e3 级，文档化）
                p := new_ir_var("_dxm", TI_DEX_S)
                emit(IR_BINARY, p, left_var, right_var, OP_MUL, TI_INT)
                // S is a raw scaled word. Emitting it as TI_INT would tag it in
                // big-int mode (2_000_000), and the raw exact-path divide would
                // use the tagged value (7.0*2.0 became 7.0).
                c := new_ir_var("_dxs", TI_DEX_S)
                emit(IR_CONST, c, 1000000, 0, 0, TI_DEX_S)
                v := new_ir_var("bin", TI_DEX_S)
                emit(IR_BINARY, v, p, c, OP_DIV, TI_INT)
                return v
            if op == OP_DIV:
                // (a×S)/b：先放大再除（中间值 a·S ≤ 9.2e18 -> |a| ≤ 9.2e6，向零截断）
                // S is a raw scaled word. Emitting it as TI_INT would tag it in
                // big-int mode (2_000_000), and the raw exact-path divide would
                // use the tagged value (7.0*2.0 became 7.0).
                c := new_ir_var("_dxs", TI_DEX_S)
                emit(IR_CONST, c, 1000000, 0, 0, TI_DEX_S)
                t := new_ir_var("_dxn", TI_DEX_S)
                emit(IR_BINARY, t, left_var, c, OP_MUL, TI_INT)
                v := new_ir_var("bin", TI_DEX_S)
                emit(IR_BINARY, v, t, right_var, OP_DIV, TI_INT)
                return v
            if op == OP_MOD:
                // a mod b = a - trunc(a/b)·b（截断除法恒等式，缩放形式）
                // S is a raw scaled word. Emitting it as TI_INT would tag it in
                // big-int mode (2_000_000), and the raw exact-path divide would
                // use the tagged value (7.0*2.0 became 7.0).
                c := new_ir_var("_dxs", TI_DEX_S)
                emit(IR_CONST, c, 1000000, 0, 0, TI_DEX_S)
                t1 := new_ir_var("_dxn", TI_DEX_S)
                emit(IR_BINARY, t1, left_var, c, OP_MUL, TI_INT)
                t2 := new_ir_var("_dxq", TI_DEX_S)
                emit(IR_BINARY, t2, t1, right_var, OP_DIV, TI_INT)
                t3 := new_ir_var("_dxi", TI_DEX_S)
                emit(IR_BINARY, t3, t2, c, OP_DIV, TI_INT)   // trunc(a/b)（纯整数）
                t4 := new_ir_var("_dxr", TI_DEX_S)
                emit(IR_BINARY, t4, t3, right_var, OP_MUL, TI_INT)
                v := new_ir_var("bin", TI_DEX_S)
                emit(IR_BINARY, v, left_var, t4, OP_SUB, TI_INT)
                return v
            if op == OP_EQ || op == OP_NE || op == OP_LT || op == OP_GT || op == OP_LE || op == OP_GE:
                // 比较：缩放整数比较，结果 0/1（int，非 dex 值）
                v := new_ir_var("cmp", TI_INT)
                emit(IR_BINARY, v, left_var, right_var, op, TI_INT)
                return v
            // ADD/SUB 及余下：缩放整数直接运算
            v := new_ir_var("bin", TI_DEX_S)
            emit(IR_BINARY, v, left_var, right_var, op, TI_INT)
            return v
        v := new_ir_var("bin", fti)
        emit(IR_BINARY, v, left_var, right_var, op, fti)
        return v

    // Assignment
    if ast_kind(node) == EXPR_ASSIGN:
        target : ., mut = ast_a(node)
        // Unwrap EXPR_NONE wrapper (added by checker/optimizer to
        // mark rewritten nodes). Without unwrapping, the target
        // checks below would miss wrapped UOP_DEREF or INDEX nodes.
        if ast_kind(target) == EXPR_NONE && ast_a(target) >= 0:
            target = ast_a(target)
        val_node := ast_b(node)
        val_var : ., mut = gen_expr(val_node)
        val_var = force_if_thunk(val_var)
        if ast_kind(target) == EXPR_IDENT:
            name_idx := ast_int_val(target)
            lv := find_local(name_idx)
            if lv >= 0:
                deferred_ti := lazy_defer_store(val_var, lv)
                if deferred_ti >= 0:
                    return lv
                if irv_type(lv) == TI_DYN:
                    // Dyn variable assignment: pack value with type tag
                    tag : ., mut = irv_type(val_var)
                    if tag < 0:
                        tag = TI_INT
                    emit(IR_DYN_PACK, lv, val_var, tag, 0, 0)
                else:
                    val_var = dex_store_adjust(lv, val_var, val_node)
                     // F11：切片长度沿赋值传播（字面量/运行时界长度变量同步；源无记录则清除）
                    slice_len_copy_to(lv, val_var)
                    // (A) 阶段（INV-1）：取址槽恒装箱（同 LET 写点；名字索引判定）
                    rpv0 := irv_rep(lv)
                    forced2 := g_optrep_on != 0 && rpv0 >= 0 && addr_taken_of(name_idx) != 0
                    if forced2 != 0:
                        val_var = box_for_slot_flag(val_node, val_var, 1)
                    emit(IR_STORE, -1, lv, val_var, 0, 0)
                    // 可选表示：赋值写点置位（同 LET，解包点据此分派）
                    if rpv0 >= 0:
                        if forced2 != 0:
                            emit_rep_set(rpv0, oe_boxed())
                        else:
                            emit_rep_set(rpv0, rep_enc_of_expr(val_node, val_var))
            else:
                gv := find_global(name_idx)
                if gv >= 0:
                    val_var = dex_store_adjust(gv, val_var, val_node)
                    // 容量阶段 T2：可选全局槽写点规范化（裸值装箱；目标不可选 -> 零 IR）
                    if g_optrep_on != 0:
                        val_var = box_for_optional_slot(val_node, val_var, global_decl_ti(name_idx))
                    emit(IR_STORE, -1, gv, val_var, 0, 0)
            return val_var
        if ast_kind(target) == EXPR_FIELD:
            obj_var : ., mut = gen_expr(ast_a(target))
            obj_var = force_if_thunk(obj_var)
            fi : ., mut = ast_data(target)
            // 容量阶段 T2：可选字段写点规范化（字段声明类型取自 checker 记的 ast_c 结构体名）
            val_var = dex_slot_norm(val_var)   // apx 阶段 T3：聚合类型恒精确（0 推论）；先归形式后装箱
            if g_optrep_on != 0:
                val_var = box_for_optional_slot(val_node, val_var, field_ti_of_node(target, fi))
            emit(IR_STORE_FIELD, -1, obj_var, val_var, fi, 0)
            return val_var
        if ast_kind(target) == EXPR_INDEX:
            arr_var : ., mut = gen_expr(ast_a(target))
            arr_var = force_if_thunk(arr_var)
            arr_data_store : ., mut = arr_var
            if is_slice_hdr(arr_var) != 0:
                arr_data_store = slice_hdr_data(arr_var)
            idx_node := ast_b(target)
            // 容量阶段 T2：可选元素写点规范化（元素类型 = 数组/切片声明类型的内层；
            // 全局数组的声明信息在 g_global_lets -> ident 形目标回退查全局声明）
            et : ., mut = elem_ti_of(arr_var)
            if et < 0:
                anode := ast_a(target)
                if anode >= 0 && ast_kind(anode) == EXPR_IDENT:
                    et = elem_ti_of_decl(global_decl_ti(ast_int_val(anode)))
            val_var = dex_slot_norm(val_var)   // apx 阶段 T3：元素槽恒精确
            if g_optrep_on != 0:
                val_var = box_for_optional_slot(val_node, val_var, et)
            // Write-path bounds check hook.
            arr_len_lit : ., mut = arr_len_lit_of(arr_var)
            if ast_kind(idx_node) == EXPR_INT:
                emit_string_lit_bounds(arr_var, ast_int_val(idx_node))
                emit_slice_lit_bounds(arr_var, ast_int_val(idx_node))
                if pass_before_array_access(arr_var, -1, ast_int_val(idx_node), arr_len_lit) == 0:
                    emit(IR_STORE_INDEX, -1, arr_data_store, val_var, ast_int_val(idx_node), 0)
            else:
                idx_var : ., mut = gen_expr(idx_node)
                idx_var = force_if_thunk(idx_var)
                emit_slice_bounds(arr_var, idx_var)
                if pass_before_array_access(arr_var, idx_var, -1, arr_len_lit) == 0:
                    emit(IR_STORE_INDEX_VAR, val_var, arr_data_store, idx_var, 0, 0)
            return val_var
        if ast_kind(target) == EXPR_UNARY && ast_c(target) == UOP_DEREF:
            ptr_var : ., mut = gen_expr(ast_a(target))
            ptr_var = force_if_thunk(ptr_var)
            // (A) 阶段（INV-2）：指针写且 pointee 可选 -> 装箱，一致性由 INV-1（取址槽恒装箱）
            // 与 E-2（聚合恒装箱）保证；越界 = REP-2（指针算术）/ extern（登记）
            // 先归形式、后可选装箱，装箱携带值须为规范形式；
            // 反序时 `dex_slot_norm` 落在箱对象（TI_INT）上 = 无效果（可选 dex 携带值留 bits）。
            val_var = dex_slot_norm(val_var)   // apx: pointee slots are always exact; *p = d must not be approximated.
            if g_optrep_on != 0 && ti_is_optional(ptr_pointee_type(ptr_var)) != 0:
                val_var = box_for_slot_flag(val_node, val_var, 1)
            emit(IR_STORE_PTR, -1, ptr_var, val_var, 0, 0)
            return val_var
        return val_var

    // Unary operation
    if ast_kind(node) == EXPR_UNARY:
        op := ast_c(node)
        if op == UOP_REF:
            inner := ast_a(node)
            // &arr[i]: compute address directly, don't load then take addr
            if ast_kind(inner) == EXPR_INDEX:
                arr_var : ., mut = gen_expr(ast_a(inner))
                arr_var = force_if_thunk(arr_var)
                idx_var : ., mut = gen_expr(ast_b(inner))
                idx_var = force_if_thunk(idx_var)
                elem_ti : ., mut = TI_INT
                // (A) 阶段：元素类型声明优先（T2 的 elem_ti_of：decl 表优先，退回运行期类型）
                de := elem_ti_of(arr_var)
                if de >= 0:
                    elem_ti = de
                else:
                    arr_ti := irv_type(arr_var)
                    if arr_ti >= 0:
                        arr_kind := get_type_kind(arr_ti)
                        if arr_kind == TYP_ARRAY || arr_kind == TYP_SLICE:
                            elem_ti = get_type_data(arr_ti)
                // S3 同阶段：`&arr[i]` 与 `&x` 是同一种语法现象（取址） -> 同判
                // `TYP_REF`。两套模型并存（`&x`=REF 而 `&arr[i]`=PTR）= a mismatch between declaration and runtime fact.
                // checker 侧已被 S1 覆盖（`UOP_REF` 对非 `EXPR_IDENT` 操作数走 `else` 分支后同样
                // `return alloc_type(TYP_REF, inner, is_mut)`）-> 本处是 ir_gen 侧唯一剩下的点。
                // `extra` 同 `&x`：取 `is_mut`（`&mut arr[i]` 与 `&arr[i]` 须同 `&x`/`&mut x` 一样可分）。
                arr_data_addr : ., mut = arr_var
                if is_slice_hdr(arr_var) != 0:
                    arr_data_addr = slice_hdr_data(arr_var)
                v := new_ir_var("addr", alloc_type(TYP_REF, elem_ti, ast_int_val(node)))
                emit(IR_ADDR_INDEX, v, arr_data_addr, idx_var, 3, 0)
                return v
            op_var : ., mut = gen_expr(ast_a(node))
            op_var = force_if_thunk(op_var)
            // (A) 阶段：pointee 类型声明优先（字面量推出的 IR 类型对可选槽退化为对象占位），
            // 且取址槽（INV-1 恒装箱）-> pointee 记为 TYP_OPTIONAL（装载侧 W5 据此装箱；
            // 非可选取址槽不受影响）
            // 取址目标的源名索引取自操作数（EXPR_UNARY 的 int_val 是 is_mut 位，不是名索引）
            ni_src : ., mut = -1
            if ast_kind(ast_a(node)) == EXPR_IDENT:
                ni_src = ast_int_val(ast_a(node))
            pti : ., mut = slot_decl_ti(op_var)
            if pti < 0:
                pti = irv_type(op_var)
            if ni_src >= 0:
                // 全局槽：声明信息在 g_global_lets（E-2 的 global_decl_ti），局部表未登记全局。
                // 只升级不降级：全局声明可选 -> 记可选；否则保留上面已得的类型
                // （全局 IR var 本身可能已是可选类型，直接取声明信息会把它覆盖成非可选 -> W5 不装箱）。
                gti := global_decl_ti(ni_src)
                if ti_is_optional(gti) != 0:
                    pti = gti
            if g_optrep_on != 0 && ni_src >= 0 && addr_taken_of(ni_src) != 0:
                // 取址目标具备可选能力（有表示位 / 声明为可选）-> pointee 记 TYP_OPTIONAL：
                // 装载侧 IR_STORE_PTR（W5）据 pointee 是否可选决定装箱。非可选槽 rep<0
                // 且声明非可选 -> 两种形态都不触发（零足迹）。
                if irv_rep(op_var) >= 0 || ti_is_optional(pti) != 0:
                    if ti_is_optional(pti) == 0:
                        inner3 : ., mut = pti
                        if inner3 < 0:
                            inner3 = TI_INT
                        pti = alloc_type(TYP_OPTIONAL, inner3, 0)
            // S1 同阶段：IR 变量型也必须一起改，`checker` 侧只决定语义视图，
            // 而 `region_check` / `provenance_verify` / `ptr_analysis` 读的是 `irv_type()`
            // （这一行源码）。只改 `checker.cr:2966` -> 三道安全检查看到的仍是 `TYP_PTR` ->
            // S6 的 (a) 扩法会对着一个永远不出现的 kind 生效（无效果且不报错）。
            // `extra` 同 checker：取 `is_mut`（即下面 emit 的 s2 实参，同一个值）。
            v := new_ir_var("ref", alloc_type(TYP_REF, pti, ast_int_val(node)))
            emit(IR_REF, v, op_var, ast_int_val(node), 0, 0)
            return v
        if op == UOP_DEREF:
            inner_var : ., mut = gen_expr(ast_a(node))
            inner_var = force_if_thunk(inner_var)
            dv := new_ir_var("deref", ptr_pointee_type(inner_var))
            emit(IR_DEREF, dv, inner_var, -1, 0, 0)
            return dv
        op_var : ., mut = gen_expr(ast_a(node))
        op_var = force_if_thunk(op_var)
        vt : ., mut = TI_INT
        if op == UOP_NOT:
            // Logical not yields a bool, independent of the operand type.
            vt = TI_BOOL
        else if op == UOP_NEG:
            // 一元负保持数值操作数类型：dex 精确（TI_DEX_S）-> 缩放整数取负 通过；
            // dex apx（TI_DEX）-> 整型取负（binary64 符号位翻转未实现，既有 apx
            // 限制，dex 定点文档；apx 负值请用 0 - x 表达）
            ot := irv_type(op_var)
            if ot == TI_DEX_S || ot == TI_DEX || ot == TI_INT:
                vt = ot
        v := new_ir_var("un", vt)
        emit(IR_UNARY, v, op_var, 0, op, 0)
        return v

    // Function call
    if ast_kind(node) == EXPR_GO:
        body := ast_b(node)
        range_node := ast_data(node)  // 0 = single, EXPR_RANGE node = range go
        if range_node <= 0:
            // Single go: emit call to sched_go(@addr(f), arg)
            // sched_go creates a goroutine via g_new + sched_enqueue and returns a channel
            if ast_kind(body) == EXPR_CALL:
                func_node := ast_a(body)
                first_arg := ast_b(body)
                func_ni : ., mut = -1
                if ast_kind(func_node) == EXPR_IDENT:
                    func_ni = ast_int_val(func_node)
                else if ast_kind(func_node) == EXPR_FIELD:
                    func_ni = ast_data(body)
                // Evaluate the first argument (if any)
                arg_var : ., mut = -1
                if first_arg >= 0:
                    arg_var = gen_expr(ast_a(first_arg))
                    arg_var = force_if_thunk(arg_var)
                // Function address via IR_FNADDR — the movabs placeholder is
                // patched to the function's absolute VA at ELF link time
                // (elf.cr Phase 3). goroutine_entry_wrapper reads it back
                // from G+56 (saved_fn) and calls saved_fn(saved_arg).
                fnaddr_var := new_ir_var("_go_fnaddr", TI_INT)
                emit(IR_FNADDR, fnaddr_var, func_ni, 0, 0, 0)
                // Create contiguous argument variables for the sched_go call:
                // arg0 = fn address, arg1 = arg value (0 when no arg)
                packed0 := new_ir_var("_go_fna", TI_INT)
                emit(IR_STORE, -1, packed0, fnaddr_var, 0, 0)
                packed1 := new_ir_var("_go_arg", TI_INT)
                if arg_var >= 0:
                    emit(IR_STORE, -1, packed1, arg_var, 0, 0)
                else:
                    emit(IR_CONST, packed1, 0, 0, 0, TI_INT)
                dest := new_ir_var("_go_ch", TI_INT)
                sched_go_ni := str_intern("sched_go")
                emit(IR_CALL, dest, packed0, 2, sched_go_ni, TI_INT)
                return dest
            return gen_expr(body)
        // Range go: go var start..end expr -> collect results into array
        iter_ni := ast_c(node)  // loop variable name
        range_count := ast_b(range_node) - ast_a(range_node)
        if range_count <= 0:
            return -1
        // Allocate results array
        arr_var := new_ir_var("go_arr", TI_UNIT)
        track_alloc_array(range_count)
        emit(IR_ALLOC_ARRAY, arr_var, range_count, 0, 0, 0)
        // Spawn each iteration
        if ast_kind(body) == EXPR_CALL:
            func_node := ast_a(body)
            func_ni : ., mut = -1
            if ast_kind(func_node) == EXPR_IDENT:
                func_ni = ast_int_val(func_node)
            // Extract the call arg that uses the iter variable
            fi : ., mut = 0
            loop:
                if fi >= range_count:
                    break
                // For each i, spawn with i as the iter var's value
                val_var := new_ir_var("go_val", TI_UNIT)
                emit(IR_CONST, val_var, ast_a(range_node) + fi, 0, 0, TI_INT)
                dest2 := new_ir_var("go_fut", TI_UNIT)
                emit(IR_SPAWN, dest2, val_var, 1, func_ni, -1)
                emit(IR_STORE_INDEX, -1, arr_var, dest2, fi, 0)
                fi = fi + 1
        return arr_var

    if ast_kind(node) == EXPR_CALL:
        func_node := ast_a(node)
        first_arg := ast_b(node)
        arg_count := ast_c(node)
        call_flags := ast_type_val(node)
        is_module_call := call_flags == CALL_FLAG_MODULE || call_flags == CALL_FLAG_MODULE + CALL_FLAG_INLINE
        is_inline_call := call_flags == CALL_FLAG_INLINE || call_flags == CALL_FLAG_MODULE + CALL_FLAG_INLINE
        arg_vars : string, mut
        arg_vars_cap : int, mut
        // 实参节点并记录表（表示方式写信道按实参位判表示需要节点，
        // 值 var 的类型不足以区分裸 T 与装箱 T?；方法调用时 arg 0 = 接收者节点）
        arg_nodes : string, mut
        arg_nodes_cap : int, mut
        ac : ., mut = 0
        arg_vars = alloc(64 * 8)
        arg_vars_cap = 64
        arg_nodes = alloc(64 * 8)
        arg_nodes_cap = 64
        func_ni : ., mut = -1

        // @builtin(args) — parser wraps @foo(args) as EXPR_CALL(func=EXPR_AT, ...)
        // so we detect EXPR_AT here and handle it before the normal call dispatch.
        if ast_kind(func_node) == EXPR_AT:
            name_ni := ast_a(func_node)
            name := istr_get(name_ni)

            // @sizeOf(T): emit IR_CONST with the target's size for T. Source-level
            // layout introspection is a program request, so the target descriptor
            // answers it; no IR width or stride depends on this value.
            if str_eq(name, "sizeOf") != 0:
                ti := ti_from_type_expr(ast_a(first_arg))
                sz := target_introspect_size(ti)
                v := new_ir_var("_sizeof", TI_INT)
                emit(IR_CONST, v, sz, 0, 0, TI_INT)
                return v

            // @alignOf(T): emit IR_CONST with the target's alignment for T.
            if str_eq(name, "alignOf") != 0:
                ti := ti_from_type_expr(ast_a(first_arg))
                al := target_introspect_align(ti)
                v := new_ir_var("_alignof", TI_INT)
                emit(IR_CONST, v, al, 0, 0, TI_INT)
                return v

            // @fields(T): emit string array of field names
            if str_eq(name, "fields") != 0:
                ti := ti_from_type_expr(ast_a(first_arg))
                si := ti_resolve_struct(ti)
                v := new_ir_var("_fields", TI_STR)
                if si >= 0:
                    fc := si_field_count(si)
                    // Build a string constant: comma-separated field names
                    fields_str : ., mut = ""
                    fi : ., mut = 0
                    loop:
                        if fi >= fc:
                            break
                        fname := istr_get(si_field_name(si, fi))
                        if fi > 0:
                            fields_str = fields_str + ","
                        fields_str = fields_str + fname
                        fi = fi + 1
                    ni := str_intern(fields_str)
                    track_str(ni)
                    emit(IR_CONST, v, ni, 0, 0, TI_STR)
                else:
                    emit(IR_CONST, v, 0, 0, 0, TI_STR)
                return v

            // @hasField(T, name): check field existence
            if str_eq(name, "hasField") != 0:
                ti := ti_from_type_expr(ast_a(first_arg))
                name_arg := ast_b(first_arg)
                name_expr := ast_a(name_arg)
                fn_name := istr_get(ast_int_val(name_expr))
                exists := ti_has_field(ti, fn_name)
                v := new_ir_var("_hasf", TI_BOOL)
                emit(IR_CONST, v, exists, 0, 0, TI_BOOL)
                return v

            // @field(T, name): target byte offset of a field. The field index is
            // semantic; the target descriptor maps it to the target layout.
            if str_eq(name, "field") != 0:
                ti := ti_from_type_expr(ast_a(first_arg))
                name_arg := ast_b(first_arg)
                name_expr := ast_a(name_arg)
                fn_name := istr_get(ast_int_val(name_expr))
                fi := ti_field_index(ti, fn_name)
                off : ., mut = -1
                if fi >= 0:
                    off = target_introspect_field_offset(fi)
                v := new_ir_var("_fldoff", TI_INT)
                emit(IR_CONST, v, off, 0, 0, TI_INT)
                return v

            // @typeInfo(T): emit type description string
            if str_eq(name, "typeInfo") != 0:
                ti := ti_from_type_expr(ast_a(first_arg))
                type_str : ., mut = ""
                k := get_type_kind(ti)
                if k == TYP_NAMED:
                    name_ni := get_type_data(ti)
                    type_str = istr_get(name_ni)
                else if ti == TI_INT:
                    type_str = "int"
                else if ti == TI_BOOL:
                    type_str = "bool"
                else if ti == TI_DEX || ti == TI_DEX_S:
                    type_str = "dex"
                else if ti == TI_STR:
                    type_str = "string"
                else if ti == TI_CHAR:
                    type_str = "char"
                else if ti == TI_UNIT:
                    type_str = "unit"
                else:
                    type_str = "unknown"
                ni := str_intern(type_str)
                track_str(ni)
                v := new_ir_var("_tinfo", TI_STR)
                emit(IR_CONST, v, ni, 0, 0, TI_STR)
                return v

            // @raw_int(expr): 显式转换，dex 表达式 -> 其定点缩放整数原值（int）。
            // dex 定点：dex.cr 的打印等辅助以此访问缩放表示的原始整数；
            // apx 值（TI_DEX bits）先按边界规则转 scaled（F2I(bits×S)）。
            // 结果必须复制为 TI_INT 定型变量，直接返回内层变量会携带其 dex 类型
            // （TI_DEX_S），后续 int 运算被误分派到 dex 精确路径。
            if str_eq(name, "raw_int") != 0:
                inner_var : ., mut = gen_expr(ast_a(first_arg))
                inner_var = force_if_thunk(inner_var)
                if irv_type(inner_var) == TI_DEX:
                    inner_var = dex_bits_to_scaled(inner_var)
                rv := new_ir_var("_raw", TI_INT)
                emit(IR_STORE, -1, rv, inner_var, 0, 0)
                return rv

            // @comptime(expr): force compile-time evaluation
            if str_eq(name, "comptime") != 0:
                inner_expr := ast_a(first_arg)
                // Generate IR for the inner expression
                inner_var : ., mut = gen_expr(inner_expr)
                inner_var = force_if_thunk(inner_var)
                // If the inner expression is a constant, it's already folded.
                // For runtime-dependent exprs, we'd need the interpreter.
                // For now: gen IR and return — the existing constant folding
                // (inline IR_CONST from @sizeOf etc.) handles pure compile-time exprs.
                // Future: invoke ir_interpret_expr for true forced evaluation.
                return inner_var

            // @inline(fn): emit IR_INLINE hint
            if str_eq(name, "inline") != 0:
                fn_var : ., mut = gen_expr(ast_a(first_arg))
                fn_var = force_if_thunk(fn_var)
                emit(IR_INLINE, -1, fn_var, 0, 0, 0)
                return fn_var

            // @NoBoundsCheck: emit annotation (no args)
            if str_eq(name, "NoBoundsCheck") != 0:
                emit(IR_NO_BOUNDS_CHECK, -1, 0, 0, 0, 0)
                return -1

            // @fast: emit annotation (no args)
            if str_eq(name, "fast") != 0:
                emit(IR_FAST, -1, 0, 0, 0, 0)
                return -1

            // @unroll(n): emit loop unroll hint
            if str_eq(name, "unroll") != 0:
                unroll_count := ast_int_val(ast_a(first_arg))
                emit(IR_UNROLL, -1, unroll_count, 0, 0, 0)
                return -1

            // @section(name): emit code section hint
            if str_eq(name, "section") != 0:
                name_expr := ast_a(ast_a(first_arg))
                name_ni := ast_int_val(name_expr)
                track_str(name_ni)
                emit(IR_SECTION, -1, name_ni, 0, 0, 0)
                return -1

            // @addr(fn): get function address (patched at ELF link time)
            if str_eq(name, "addr") != 0:
                fn_expr := ast_a(first_arg)
                if ast_kind(fn_expr) == EXPR_IDENT:
                    fn_ni : ., mut = ast_int_val(fn_expr)
                    ffi := find_func(fn_ni)
                    if ffi >= 0:
                        fn_ni = func_link(ffi)
                    v := new_ir_var("_fnaddr", TI_INT)
                    emit(IR_FNADDR, v, fn_ni, 0, 0, 0)
                    return v
                return -1

            // ── 2(a) 视图内建：真直通（零指令、零新变量），同一个 64 位字，只换看法 ──
            //    为什么不沿用本项目 `@raw_int` 的新建变量 + IR_STORE写法：
            //      `@raw_int` 换来换去的是 dex↔int（XMM/精确路径 vs GP 两条真正不同的机器路径），
            //      所以必须把值搬进一个定型 int的变量，否则下游按 dex 分派。
            //      而 `int ↔ string` 在两条运行期路径上都是同一个 GP 字（原生：string = 指针；
            //      解释器：string = intern 索引），搬运不改变任何东西，只会多出一条 IR_STORE，
            //      从而违反视图可完全擦除这条规则（见 test_view_builtins.py 2：往返写法与
            //      直写产物的 ELF 必须逐字节一致.
            //    类型在哪换：checker 侧（`@str_of` 返回 TI_STR / `@ptr_of` 返回 TI_INT），
            //      即表达式的类型而不是变量的类型；调用边界按被调函数形参类型编组，
            //      int/string 同属 GP 字 -> 两侧一致。
            // SYSTEM raw pointer add: untag both int operands and return the raw
            // word. No unsafe/arena: safe to call from the scheduler hot path.
            if str_eq(name, "ptr_add") != 0:
                a1 : ., mut = gen_expr(ast_a(first_arg))
                a1 = force_if_thunk(a1)
                a2n := ast_b(first_arg)
                a2v : ., mut = -1
                if a2n >= 0:
                    a2v = gen_expr(ast_a(a2n))
                    a2v = force_if_thunk(a2v)
                rv := new_ir_var("_ptr_add", TI_INT)
                emit(IR_BINARY, rv, a1, a2v, OP_RAW_ADD, TI_INT)
                return rv

            if str_eq(name, "str_of") != 0 || str_eq(name, "ptr_of") != 0:
                inner : ., mut = gen_expr(ast_a(first_arg))
                inner = force_if_thunk(inner)
                if str_eq(name, "ptr_of") != 0:
                    rv := new_ir_var("_ptr_of", TI_INT)
                    emit(IR_PTR_OF, rv, inner, 0, 0, TI_INT)
                    return rv
                else:
                    rv := new_ir_var("_str_of", TI_STR)
                    emit(IR_STR_OF, rv, inner, 0, 0, TI_STR)
                    return rv

            return -1

        // Module or method call: obj.method(args)
        if ast_kind(func_node) == EXPR_FIELD:
            func_ni = ast_data(node) // function name (set by checker for module calls)
            // An associated function (no `self` parameter) is called through the
            // same `Type.fn(...)` syntax but takes no receiver. Passing one would
            // shift every argument by a slot and drop the last.
            takes_self : ., mut = 0
            if !is_module_call:
                takes_self = 1
                cfi0 := find_func(func_ni)
                if cfi0 >= 0:
                    fn_node0 := fi_ast_node(cfi0)
                    fp0 := ast_b(fn_node0)
                    if fp0 < 0:
                        takes_self = 0
                    else if ast_int_val(fp0) == 0:
                        takes_self = 0
                else:
                    // Not a declared function: a dyn dispatch carries the method
                    // name, and the receiver is still the first argument.
                    takes_self = 1
            if takes_self != 0:
                // Method call: self is first arg
                obj_node := ast_a(func_node)
                self_var : ., mut = gen_expr(obj_node)
                self_var = force_if_thunk(self_var)
                if ac >= arg_vars_cap:
                    nc := arg_vars_cap * 2
                    nb := alloc(nc * 8)
                    cell_copy(arg_vars, arg_vars_cap * 8, nb)
                    arg_vars = nb
                    arg_vars_cap = nc
                cell_store(arg_vars, ac * 8, self_var)
                if ac >= arg_nodes_cap:
                    nc := arg_nodes_cap * 2
                    nb := alloc(nc * 8)
                    cell_copy(arg_nodes, arg_nodes_cap * 8, nb)
                    arg_nodes = nb
                    arg_nodes_cap = nc
                cell_store(arg_nodes, ac * 8, obj_node)
                ac = ac + 1
        else if ast_kind(func_node) == EXPR_IDENT:
            func_ni = ast_int_val(func_node)
            link_ni := ast_data(node)
            if link_ni >= 0:
                func_ni = link_ni

        // Generate remaining args (walk EXPR_ARG chain)
        an : ., mut = first_arg
        loop:
            if an < 0:
                break
            arg_var : ., mut = gen_expr(ast_a(an))
            arg_var = force_if_thunk(arg_var)
            if ac >= arg_vars_cap:
                nc := arg_vars_cap * 2
                nb := alloc(nc * 8)
                cell_copy(arg_vars, arg_vars_cap * 8, nb)
                arg_vars = nb
                arg_vars_cap = nc
            cell_store(arg_vars, ac * 8, arg_var)
            if ac >= arg_nodes_cap:
                nc := arg_nodes_cap * 2
                nb := alloc(nc * 8)
                cell_copy(arg_nodes, arg_nodes_cap * 8, nb)
                arg_nodes = nb
                arg_nodes_cap = nc
            cell_store(arg_nodes, ac * 8, ast_a(an))
            ac = ac + 1
            an = ast_b(an)
        // Raw current-arena access. These names are compiler builtins: a normal
        // function call would create its own function arena first and read the
        // wrong current. Lower directly to cell_load/cell_store plus the
        // g_current_arena global so scheduler context switches see the real
        // allocator state.
        if func_ni >= 0:
            bname := istr_get(func_ni)
            if str_eq(bname, "arena_current_unchecked") != 0 && ac == 0:
                dest := new_ir_var("arena_current", TI_INT)
                sv := global_var_of(str_intern("g_arena_scalars"))
                if sv >= 0:
                    z := new_ir_var("_arena_zero", TI_INT)
                    emit(IR_CONST, z, 0, 0, 0, TI_INT)
                    a0 := new_ir_var("_arena_arg", TI_STR)
                    emit(IR_STORE, -1, a0, sv, 0, 0)
                    a1 := new_ir_var("_arena_arg", TI_INT)
                    emit(IR_STORE, -1, a1, z, 0, 0)
                    emit(IR_CALL, dest, a0, 2, str_intern("cell_load"), TI_INT)
                else:
                    gv := global_var_of(str_intern("g_current_arena"))
                    if gv >= 0:
                        emit(IR_LOAD, dest, gv, 0, 0, TI_INT)
                    else:
                        emit(IR_CONST, dest, 0, 0, 0, TI_INT)
                return dest
            if str_eq(bname, "arena_set_current_unchecked") != 0 && ac == 1:
                av := cell_load(arg_vars, 0)
                sv := global_var_of(str_intern("g_arena_scalars"))
                if sv >= 0:
                    z := new_ir_var("_arena_zero", TI_INT)
                    emit(IR_CONST, z, 0, 0, 0, TI_INT)
                    a0 := new_ir_var("_arena_arg", TI_STR)
                    emit(IR_STORE, -1, a0, sv, 0, 0)
                    a1 := new_ir_var("_arena_arg", TI_INT)
                    emit(IR_STORE, -1, a1, z, 0, 0)
                    a2 := new_ir_var("_arena_arg", TI_INT)
                    emit(IR_STORE, -1, a2, av, 0, 0)
                    emit(IR_CALL, -1, a0, 3, str_intern("cell_store"), TI_INT)
                gv := global_var_of(str_intern("g_current_arena"))
                if gv >= 0:
                    emit(IR_STORE, -1, gv, av, 0, 0)
                return -1

        // dex 边界规则：dex 参数在调用点按被调方形式处理，
        //   Core 函数：一律精确形式（scaled），apx 位模式参数转 scaled（F2I(bits×S)）；
        //   extern 函数：C ABI 契约（module.cr：dex 编码 3 = binary64 跨 C 边界），
        //     精确形式（scaled）实参转 binary64 bits（I2F/S，字面量重发射位模式常量）
        // 覆盖范围（apx 阶段 T3；维护者硬条件 1逐形态收窄）：环从仅直调放宽到
        // 可解析到 Core/extern 函数的调用形态，直调（EXPR_IDENT）/ 方法调用
        // （EXPR_FIELD 且非模块调用）/ 模块限定调用（EXPR_FIELD 且 is_module_call）。
        //   · 三者共用同一环：实参表与参数列表天然对应（方法调用的接收者占
        //     arg_vars[0]，而 `self` 在方法参数列表中亦占第 0 位，parser.cr:1378-1405
        //     把 self 物化为 EXPR_PARAM）；`arg_nodes` 游标同步走 EXPR_ARG 列表。
        //   · 不是凡调用都进环：EXPR_AT 内建在 `:1600` 已提前返回（独立路径）；
        //     `find_func` 落空（func_ni < 0 / 名字非函数）-> 无声明信息 -> 环不进（零变化）。
        //   · Evidence:方法调用 b1/b1b 红 49/15，模块限定调用 m1b 红（ELF=4，期望 7），
        //     二者同因（原检查中的 EXPR_IDENT 硬限制）。
        // 环已抽为 `dex_align_call_args`（可复用，重定向后按实例签名再跑一遍）
        if func_ni >= 0:
            cfi := find_func(func_ni)
            if cfi >= 0:
                dex_align_call_args(cfi, ac, arg_vars, arg_nodes, arg_nodes_cap)
        // Generic function: redirect to monomorphized (specialized) version.
        // Method calls are included: a method on a generic struct inherits the
        // struct's parameters, so without specialization the template has no
        // emitted body and the call would target a missing symbol.
        if func_ni >= 0 && (ast_kind(func_node) == EXPR_IDENT || ast_kind(func_node) == EXPR_FIELD || is_module_call != 0):
            gen_fi := find_func(func_ni)
            if gen_fi >= 0 && fi_generic_count(gen_fi) > 0:
                // ─── 实例键类型项化 ───
                // Preferred path: the checker's call-site binding segment (g_gen_binds;
                // node int_val = segment start + 1, 0 = none). Record ti in the callee's
                // generic parameter declaration order, build the key with
                // inst_key_of_ti, and replace through the ti path (monomorph.cr). The
                // segment length must match the parameter count and all entries must be
                // bound and concrete.
                // Fallback: build the key from argument IR variable types (non-primitive
                // becomes "int"), and replace through the name path with
                // gen_create_instance(func, args, -1).
                gc_g := fi_generic_count(gen_fi)
                biv := ast_int_val(node)
                type_args : ., mut = ""
                bstart : ., mut = -1
                if biv > 0:
                    bs := biv - 1
                    if bs < g_gen_binds_count:
                        bcnt := cell_load(g_gen_binds, bs * 8)
                        if bcnt == gc_g && bs + 1 + bcnt <= g_gen_binds_count:
                            ok_b : ., mut = 1
                            gi_b : ., mut = 0
                            loop:
                                if gi_b >= bcnt:
                                    break
                                bt := cell_load(g_gen_binds, (bs + 1 + gi_b) * 8)
                                if bt < 0:
                                    ok_b = 0
                                    break
                                if inst_ti_concrete(bt) == 0:
                                    ok_b = 0
                                    break
                                if inst_type_node_of_ti(bt) < 0:
                                    ok_b = 0
                                    break
                                if gi_b > 0:
                                    type_args = type_args + ","
                                type_args = type_args + inst_key_of_ti(bt)
                                gi_b = gi_b + 1
                            if ok_b != 0:
                                bstart = bs
                if bstart < 0:
                    // Fallback: build the key from argument type names when the checker
                    // provided no bindings.
                    type_args = ""
                    ai : ., mut = 0
                    loop:
                        if ai >= ac:
                            break
                        av := cell_load(arg_vars, ai * 8)
                        ti : ., mut = TI_INT
                        if av >= 0:
                            ti = irv_type(av)
                        if ai > 0:
                            type_args = type_args + ","
                        if ti == TI_INT:
                            type_args = type_args + "int"
                        else if ti == TI_STR:
                            type_args = type_args + "string"
                        else if ti == TI_BOOL:
                            type_args = type_args + "bool"
                        else if ti == TI_CHAR:
                            type_args = type_args + "char"
                        else if ti == TI_DEX || ti == TI_DEX_S:
                            type_args = type_args + "dex"
                        else if ti == TI_UNIT:
                            type_args = type_args + "unit"
                        else:
                            type_args = type_args + "int"
                        ai = ai + 1
                // Find or create specialized function instance
                spec_ni : ., mut = -1
                if bstart >= 0:
                    spec_ni = gen_find_or_create_bind(gen_fi, type_args, bstart)
                else:
                    spec_ni = gen_find_or_create(gen_fi, type_args)
                if spec_ni >= 0:
                    func_ni = func_link(spec_ni)
                    // 泛型声明的形参是 `T?`（inner = 泛型参数 -> 条件为假）-> 上面的环
                    // 对泛型实参无效果；重定向后用实例参数列表（inner = 具体 dex -> 条件为真）再跑一遍。
                    // 幂等性见 `dex_align_call_args` 头注（已转换者 IR 型 = TI_DEX_S -> 不重转）。
                    cfi_i := find_func(func_ni)
                    if cfi_i >= 0:
                        dex_align_call_args(cfi_i, ac, arg_vars, arg_nodes, arg_nodes_cap)
                    // Fall through to normal IR_CALL emission
        if func_ni >= 0:
            cfi_args := find_func(func_ni)
            if cfi_args >= 0:
                coerce_slice_args(cfi_args, ac, arg_vars)
        if is_inline_call && func_ni >= 0:
            emit(IR_INLINE, -1, func_ni, 0, 0, 0)
        // Check SO function dispatch (variadic expansion, auto_str, etc.)
        handled := dispatch_call(func_ni, ac, arg_vars)
        if handled >= 0:
            return handled

        // `align(n)` is a declaration-time identity: allocation placement only
        // needs the numeric value, never a runtime call.
        if func_ni >= 0 && ac >= 1 && str_eq(istr_get(func_ni), "align") != 0:
            return cell_load(arg_vars, 0)

        // Declarative placement: the address, size and alignment are physical
        // facts and must be compile-time integers. The node gets provenance like
        // any other allocation, then the ordinary passes track it.
        if func_ni >= 0 && ac >= 3 && str_eq(istr_get(func_ni), "alloc_at") != 0:
            av0 := cell_load(arg_vars, 0 * 8)
            av1 := cell_load(arg_vars, 1 * 8)
            av2 := cell_load(arg_vars, 2 * 8)
            addr := ir_const_int_of_var(av0)
            size := ir_const_int_of_var(av1)
            al := ir_const_int_of_var(av2)
            if addr < 0 || size < 0 || al < 0:
                check_error(EC_TK_SIZE_TYPE,
                    "alloc_at requires compile-time integer address, size and align",
                    0, 0)
                return new_ir_var("alloc_at", alloc_at_ptr_ti())
            if size <= 0 || size % 8 != 0:
                check_error(EC_TK_SIZE_TYPE,
                    "alloc_at size must be a positive multiple of 8 bytes",
                    0, 0)
                return new_ir_var("alloc_at", alloc_at_ptr_ti())
            dest := new_ir_var("alloc_at", alloc_at_ptr_ti())
            emit(IR_ALLOC_AT, dest, addr, size, al, TI_INT)
            return dest

        // For method calls (EXPR_FIELD), func_ni was set by checker
        // Use it directly
        call_ti := ir_call_return_type(func_ni)
        dest := new_ir_var("call", call_ti)
        first_arg_var : ., mut = -1
        need_pack : ., mut = 0
        if ac > 0:
            prev : ., mut = cell_load(arg_vars, 0 * 8)
            first_arg_var = prev
            ai : ., mut = 1
            loop:
                if ai >= ac:
                    break
                cur := cell_load(arg_vars, ai * 8)
                if cur != prev + 1:
                    need_pack = 1
                    break
                prev = cur
                ai = ai + 1
        if need_pack != 0:
            ai : ., mut = 0
            loop:
                if ai >= ac:
                    break
                av := cell_load(arg_vars, ai * 8)
                at : ., mut = TI_INT
                if av >= 0:
                    at = irv_type(av)
                packed := new_ir_var("_arg", at)
                if ai == 0:
                    first_arg_var = packed
                emit(IR_STORE, -1, packed, av, 0, 0)
                ai = ai + 1
        // Dyn method dispatch: receiver is a dyn value, emit dynamic dispatch
        if ast_kind(func_node) == EXPR_FIELD && ac > 0 && func_ni >= 0:
            dyn_receiver := first_arg_var
            if dyn_receiver >= 0 && irv_type(dyn_receiver) == TI_DYN:
                dyn_dest := new_ir_var("_dyncall", TI_UNIT)
                emit(IR_DYN_DISPATCH, dyn_dest, dyn_receiver, func_ni, 0, 0)
                return dyn_dest

        // Hotpatch function call: emit IR_HOTPATCH_ROUTE instead of IR_CALL.
        // The sixth argument must be explicit. emit has six parameters; this call
        // site passes 0 because op39 has no type face. Previously the bootstrap
        // generated only the present arguments and left r9 as a stale value, which
        // made the same input produce 0 or 4 depending on program shape. Undefined
        // values must not be baked into the classification table; every cell needs
        // evidence.
        if func_ni >= 0 && is_hotpatch_func(func_ni) != 0:
            emit(IR_HOTPATCH_ROUTE, dest, func_ni, first_arg_var, ac, 0)
            return dest
        // Extern function call: emit IR_CALL_EXTERN for FFI dispatch
        if func_ni >= 0:
            fi : ., mut = find_func(func_ni)
            if fi >= 0:
                fn_node := fi_ast_node(fi)
                if fn_node >= 0 && ast_kind(fn_node) == EXPR_EXTERN:
                    emit(IR_CALL_EXTERN, dest, func_ni, first_arg_var, ac, 0)
                    return dest
        // 可选表示：实参表示写信道，逐实参位写（被调序言最早处读；
        // 写点 = 全部实参求值之后、IR_CALL 紧邻之前 -> 嵌套调用不覆写信道）。
        if g_optrep_on != 0 && g_optrep_arg_count > 0:
            ai3 : ., mut = 0
            loop:
                if ai3 >= ac:
                    break
                if ai3 >= g_optrep_arg_count:
                    break
                av3 := cell_load(arg_vars, ai3 * 8)
                an3 : ., mut = -1
                if ai3 < arg_nodes_cap:
                    an3 = cell_load(arg_nodes, ai3 * 8)
                emit_rep_set(g_optrep_arg_cell0 + ai3, rep_enc_of_expr(an3, av3))
                ai3 = ai3 + 1
        if func_ni >= 0 && runtime_frontend_builtin_is_alloc(func_ni) != 0:
            if ac >= 1:
                an := cell_load(arg_nodes, 0)
                if an >= 0 && ast_kind(an) == EXPR_INT:
                    track_alloc_size(((ast_int_val(an) + 15) / 8) * 8)
                else:
                    track_alloc_unknown()
            else:
                track_alloc_unknown()
        lazy_ast_set(g_ir_instr_count, node)
        if g_plan_active != 0 && ac == 0 && lazy_plan_has(node) != 0:
            // Compile-time lazy sink: define the result at its unique force
            // point instead of evaluating the pure call here.
            lazy_def_add(dest, func_ni, call_ti)
            return dest
        emit(IR_CALL, dest, first_arg_var, ac, func_ni, call_ti)
        // `dex?` returns carry a declared optional row, not just TI_INT. Keeping
        // the row on the call result lets a later match recover the payload form
        // (bare scaled vs boxed Some) without guessing from the IR value width.
        if g_optrep_on != 0:
            cdd := callee_ret_dex_opt_decl(func_ni)
            if cdd >= 0:
                irv_set_decl_ti(dest, cdd)
        // 可选表示：被调返回可选 -> 1) 读返回信道（读点必须紧跟真实
        // 调用：调用点与返回点同进程同栈、其间无写入）；2) 禁惰性 thunk，thunk 把
        // 调用推迟到 force 点，读点即悬空(for example: `v := g()` 的 g 判纯 -> thunk -> 表示位
        // 回落装箱 -> 裸值返回解包崩）。代价 = 仅返回可选的被调不做 thunk 延迟。
        ret_opt : ., mut = 0
        if g_optrep_on != 0 && g_optrep_ret_cell >= 0:
            ret_opt = callee_ret_optional(func_ni)
        // Lazy thunk: if calling a pure function with single use, wrap as thunk
        if func_ni >= 0 && ret_opt == 0:
            call_fi := find_func(func_ni)
            if call_fi >= 0 && fi_ispure(call_fi) != 0:
                grow_var_use_count(dest + 1)
                use_count := cell_load(g_var_use_count, dest * 8)
                if use_count <= 1:
                    thunk_var := new_ir_var("_lazy", irv_type(dest))
                    emit(IR_LAZY_THUNK, thunk_var, dest, 0, 0, 0)
                    return thunk_var
        if ret_opt != 0:
            rvr := new_ir_var("call_rep", TI_INT)
            emit(IR_LOAD, rvr, g_optrep_ret_cell, 0, 0, TI_INT)
            irv_set_rep(dest, rvr)
        return dest

    // Block
    if ast_kind(node) == EXPR_BLOCK:
        stmt_start := ast_a(node)
        stmt_count := ast_b(node)
        last : ., mut = -1
        push_ir_scope()
        i : ., mut = 0
        loop:
            if i >= stmt_count:
                break
            sn := cell_load(g_block_stmts, (stmt_start + i) * 8)
            last = gen_expr(sn)
            i = i + 1
        pop_ir_scope()
        return last

    // If expression
    if ast_kind(node) == EXPR_IF:
        // V2.0: a planned IF owns a child arena. The plan is filled in Phase A
        // after PointerAnalysis/RegionCheck and read only during Phase B.
        sg_idx := g_sg_count
        split := region_plan_is_split(sg_idx)
        merge := region_plan_is_merge(sg_idx)
        share := region_plan_is_share(sg_idx)
        if merge != 0 && share != 0:
            check_error(EC_B_LIFETIME, "IF cannot be both merge and share", 0, 0)
        child : ., mut = split
        if merge != 0 || share != 0:
            child = 1
        merge_copy_var : ., mut = -1
        merge_copy_instr : ., mut = -1
        merge_str1_var : ., mut = -1
        merge_str2_var : ., mut = -1
        merge_parent_var : ., mut = -1
        merge_emitted : ., mut = 0
        if merge != 0:
            // Allocate the surviving copy in the parent arena before the child
            // arena is created. The element count is already known from the
            // plan, so the parent arena peak includes the copy. The element
            // type row is patched at the assigning branch exit.
            merge_cnt := region_plan_merge_len(sg_idx)
            merge_kind := region_plan_merge_kind_of(sg_idx)
            // Capture the parent arena before the child is created. Array and
            // struct copies may contain string leaves that need a parent-side
            // str_sub allocation.
            gv := global_var_of(str_intern("g_current_arena"))
            if gv >= 0:
                merge_parent_var = new_ir_var("_merge_parent", TI_INT)
                emit(IR_LOAD, merge_parent_var, gv, 0, 0, TI_INT)
            if merge_kind == 3:
                ms1 := region_plan_merge_str1_of(sg_idx)
                ms2 := region_plan_merge_str2_of(sg_idx)
                if ms1 < 0:
                    if merge_parent_var < 0:
                        check_error(EC_B_LIFETIME, "string merge requires g_current_arena", 0, 0)
                else:
                    merge_str1_var = rp_emit_parent_str_copy(ms1)
                    if merge_str1_var < 0:
                        check_error(EC_B_LIFETIME, "string merge copy failed", 0, 0)
                    if ms2 >= 0 && ms2 != ms1:
                        merge_str2_var = rp_emit_parent_str_copy(ms2)
                    else:
                        merge_str2_var = merge_str1_var
            else:
                merge_copy_var = new_ir_var("_merge_copy", TI_UNIT)
                if merge_kind == 1:
                    merge_name := region_plan_merge_name_of(sg_idx)
                    track_alloc_struct(merge_name)
                    emit(IR_ALLOC_STRUCT, merge_copy_var, 0, 0, merge_name, 0)
                else:
                    track_alloc_array(merge_cnt)
                    emit(IR_ALLOC_ARRAY, merge_copy_var, merge_cnt, 0, 0, 0)
                merge_copy_instr = g_ir_instr_count - 1
        arena_instr : ., mut = -1
        if child != 0:
            sg_alloc_push(SG_IF)
            arena_var := new_ir_var("_arena", TI_INT)
            cell_store(g_sg_arena_var, (g_sg_count - 1) * 8, arena_var)
            emit(IR_ARENA_NEW, arena_var, 0, 0, 0, 0)
            arena_instr = g_ir_instr_count - 1
        else:
            sg_push(SG_IF)  // conditional region: covers [condition, merge)
        cond := ast_a(node)
        then_node := ast_b(node)
        else_node := ast_c(node)
        cond_var : ., mut = gen_expr(cond)
        cond_var = force_if_thunk(cond_var)
        then_lbl := new_label()
        else_lbl := new_label()
        merge_lbl := new_label()
        // v10 unified decision node: false is CASE 0, true falls through to
        // then. This keeps the then-first block layout and avoids an extra jump
        // in the backend's two-way-zero path.
        false_lbl : ., mut = merge_lbl
        if else_node >= 0:
            false_lbl = else_lbl
        emit_cond_match(cond_var, false_lbl, then_lbl)
        result_var : ., mut = -1
        result_rep : ., mut = -1
        emit(IR_LABEL, -1, then_lbl, 0, 0, 0)
        then_body_start := g_ir_instr_count
        base_t := sg_alloc_cur_total()
        base_u := sg_alloc_cur_unknown()
        then_val : ., mut = gen_expr(then_node)
        then_val = force_if_thunk(then_val)
        then_t := sg_alloc_cur_total()
        then_u := sg_alloc_cur_unknown()
        sg_alloc_set(base_t, base_u)
        if else_node >= 0 && then_val >= 0:
            result_var = new_ir_var("if_res", irv_type(then_val))
            emit(IR_ALLOC, result_var, 0, 0, 0, irv_type(then_val))
            if g_optrep_on != 0:
                result_rep = new_ir_var("if_res_rep", TI_INT)
                emit(IR_CONST, result_rep, 1, 0, 0, TI_INT)
                irv_set_rep(result_var, result_rep)
            emit(IR_STORE, -1, result_var, then_val, 0, 0)
            if result_rep >= 0:
                emit_rep_set(result_rep, rep_enc_of_expr(then_node, then_val))
        if merge != 0:
            // The copy runs at the end of the assigning branch: the false path
            // never sees the child pointer, so no merge phi is needed.
            if region_plan_emit_merge(sg_idx, merge_copy_var, merge_copy_instr, merge_str1_var, merge_str2_var, merge_parent_var, then_body_start, g_ir_instr_count) != 0:
                merge_emitted = 1
        emit(IR_JUMP, -1, merge_lbl, 0, 0, 0)
        if else_node >= 0:
            emit(IR_LABEL, -1, else_lbl, 0, 0, 0)
            else_body_start := g_ir_instr_count
            else_val : ., mut = gen_expr(else_node)
            else_val = force_if_thunk(else_val)
            if result_var < 0 && else_val >= 0:
                result_var = new_ir_var("if_res", irv_type(else_val))
                emit(IR_ALLOC, result_var, 0, 0, 0, irv_type(else_val))
                if g_optrep_on != 0:
                    result_rep = new_ir_var("if_res_rep", TI_INT)
                    emit(IR_CONST, result_rep, 1, 0, 0, TI_INT)
                    irv_set_rep(result_var, result_rep)
            if result_var >= 0 && else_val >= 0:
                emit(IR_STORE, -1, result_var, else_val, 0, 0)
                if result_rep >= 0:
                    emit_rep_set(result_rep, rep_enc_of_expr(else_node, else_val))
            if merge != 0:
                if region_plan_emit_merge(sg_idx, merge_copy_var, merge_copy_instr, merge_str1_var, merge_str2_var, merge_parent_var, else_body_start, g_ir_instr_count) != 0:
                    merge_emitted = 1
            emit(IR_JUMP, -1, merge_lbl, 0, 0, 0)
        other_t := sg_alloc_cur_total()
        other_u := sg_alloc_cur_unknown()
        td := then_t - base_t
        ed := other_t - base_t
        pk : ., mut = td
        if ed > pk:
            pk = ed
        sg_alloc_set(base_t + pk, base_u)
        if then_u != 0 || other_u != 0:
            sg_alloc_set(base_t + pk, 1)
        emit(IR_LABEL, -1, merge_lbl, 0, 0, 0)
        if child != 0:
            if merge != 0 && merge_emitted == 0:
                check_error(EC_B_LIFETIME,
                    "merge copy plan could not be materialized",
                    0, 0)
            peak := sg_alloc_cur_total()
            if g_no_auto_arena == 0 && peak != 0:
                iri_set_s1(arena_instr, peak)
            if share != 0:
                sg_alloc_pop_share()
            else:
                sg_alloc_pop_split()
        else:
            sg_pop()
        return result_var

    // Loop
    if ast_kind(node) == EXPR_LOOP:
        header_lbl := new_label()
        body_lbl := new_label()
        exit_lbl := new_label()
        emit(IR_JUMP, -1, header_lbl, 0, 0, 0)
        // SG_LOOP region covers [header, exit) — the back-edge jump to the
        // header lands on the region enter (region iteration in interp.cr).
        sg_alloc_push(SG_LOOP)
        arena_var := new_ir_var("_arena", TI_INT)
        cell_store(g_sg_arena_var, (g_sg_count - 1) * 8, arena_var)
        emit(IR_LABEL, -1, header_lbl, 0, 0, 0)
        emit(IR_JUMP, -1, body_lbl, 0, 0, 0)
        emit(IR_LABEL, -1, body_lbl, 0, 0, 0)
        emit(IR_ARENA_NEW, arena_var, 0, 0, 0, 0)
        arena_instr := g_ir_instr_count - 1
        push_ir_scope()
        // `continue` must jump to the post label (not the header) so the
        // arena reset runs on the continue path too — symmetric with `for`.
        post_lbl := new_label()
        push_loop_labels(post_lbl, exit_lbl)
        gen_expr(ast_a(node))
        pop_loop_labels()
        pop_ir_scope()
        peak := sg_peak_of_current()
        if g_no_auto_arena == 0 && peak != 0:
            iri_set_s1(arena_instr, peak)
        emit(IR_LABEL, -1, post_lbl, 0, 0, 0)
        emit(IR_ARENA_RESET, -1, arena_var, 0, 0, 0)  // arena reused per iteration
        emit(IR_JUMP, -1, header_lbl, 0, 0, 0)
        emit(IR_LABEL, -1, exit_lbl, 0, 0, 0)
        sg_pop()  // close loop region (arena already reset above)
        region_plan_emit_share_after(g_sg_count - 1)
        return -1

    // While loop
    if ast_kind(node) == EXPR_WHILE:
        cond := ast_a(node)
        body := ast_b(node)
        header_lbl := new_label()
        body_lbl := new_label()
        exit_lbl := new_label()
        // Keep while loops on the same SG_LOOP protocol as loop/for: the
        // region owns the condition, body, back-edge, and exit label so sg_pop
        // can add the termination dependency and advance the state chain.
        sg_alloc_push(SG_LOOP)
        arena_var := new_ir_var("_arena", TI_INT)
        cell_store(g_sg_arena_var, (g_sg_count - 1) * 8, arena_var)
        emit(IR_LABEL, -1, header_lbl, 0, 0, 0)
        cond_var : ., mut = gen_expr(cond)
        cond_var = force_if_thunk(cond_var)
        emit_cond_match(cond_var, exit_lbl, body_lbl)
        emit(IR_LABEL, -1, body_lbl, 0, 0, 0)
        emit(IR_ARENA_NEW, arena_var, 0, 0, 0, 0)
        arena_instr := g_ir_instr_count - 1
        push_ir_scope()
        // Continue must pass through the reset point before rechecking cond.
        post_lbl := new_label()
        push_loop_labels(post_lbl, exit_lbl)
        gen_expr(body)
        pop_loop_labels()
        pop_ir_scope()
        peak := sg_peak_of_current()
        if g_no_auto_arena == 0 && peak != 0:
            iri_set_s1(arena_instr, peak)
        emit(IR_LABEL, -1, post_lbl, 0, 0, 0)
        emit(IR_ARENA_RESET, -1, arena_var, 0, 0, 0)
        emit(IR_JUMP, -1, header_lbl, 0, 0, 0)
        emit(IR_LABEL, -1, exit_lbl, 0, 0, 0)
        sg_pop()  // close loop region (arena already reset above)
        region_plan_emit_share_after(g_sg_count - 1)
        return -1

    // For loop: for var in start..end { body }
    if ast_kind(node) == EXPR_FOR:
        var_ni := ast_a(node)
        iter := ast_b(node)
        body := ast_c(node)
        start_var : ., mut = -1
        end_var : ., mut = -1
        is_seq : ., mut = 0
        seq_elem_ti : ., mut = TI_INT
        seq_elem_tk : ., mut = 0
        seq_iter_var : ., mut = -1
        if ast_kind(iter) == EXPR_RANGE:
            start_var = gen_expr(ast_a(iter))
            start_var = force_if_thunk(start_var)
            end_var = gen_expr(ast_b(iter))
            end_var = force_if_thunk(end_var)
        else:
            iv : ., mut = gen_expr(iter)
            iv = force_if_thunk(iv)
            iti := irv_type(iv)
            ik := get_type_kind(iti)
            // Slice values keep TI_INT as their IR type (the slice header is a
            // pointer); their length lives in the side table. Use that record
            // when deciding whether this is a sequence loop.
            sl0 := slice_len_get(iv)
            slv0 : ., mut = -1
            if sl0 < 0:
                slv0 = slice_len_var_get(iv)
            if ik == TYP_ARRAY || ik == TYP_SLICE || iti == TI_STR:
                // Sequence iteration: index 0..len, bind the loop name to the
                // loaded element. The old fallback used the sequence value as
                // the integer upper bound, which is an infinite loop.
                is_seq = 1
                if iti == TI_STR:
                    seq_iter_var = iv
                    seq_elem_ti = TI_CHAR
                    seq_elem_tk = TI_CHAR
                    end_var = new_ir_var("for_len", TI_INT)
                    emit(IR_CALL, end_var, iv, 1, str_intern("str_len"), TI_INT)
                else:
                    seq_elem_ti = get_type_data(iti)
                    seq_elem_tk = agg_elem_read_form(iv)
                    if ik == TYP_ARRAY:
                        seq_iter_var = iv
                        end_var = new_ir_var("for_len", TI_INT)
                        emit(IR_CONST, end_var, get_type_extra(iti), 0, 0, TI_INT)
                    else:
                        // Slice header: iterate over the data pointer with the
                        // header's runtime length.
                        seq_iter_var = slice_hdr_data(iv)
                        end_var = slice_hdr_len(iv)
                        if end_var < 0:
                            check_error(EC_TK_FOR_ITER,
                                "cannot determine slice length for iteration",
                                ast_line(iter), ast_col(iter))
                            return -1
                s := new_ir_var("start", TI_INT)
                emit(IR_CONST, s, 0, 0, 0, TI_INT)
                start_var = s
            else if sl0 >= 0 || slv0 >= 0:
                // Slice value with a recorded length but an elided IR type.
                is_seq = 1
                seq_iter_var = iv
                et := elem_ti_of(iv)
                if et >= 0:
                    seq_elem_ti = et
                seq_elem_tk = agg_elem_read_form(iv)
                if sl0 >= 0:
                    end_var = new_ir_var("for_len", TI_INT)
                    emit(IR_CONST, end_var, sl0, 0, 0, TI_INT)
                else:
                    end_var = slv0
                s := new_ir_var("start", TI_INT)
                emit(IR_CONST, s, 0, 0, 0, TI_INT)
                start_var = s
            else:
                // Non-range integer iterable: evaluate and use 0..iter
                s := new_ir_var("start", TI_INT)
                emit(IR_CONST, s, 0, 0, 0, TI_INT)
                start_var = s
                end_var = iv
        // Create loop variable, init to start. The source name is bound inside
        // the body: an integer loop binds the index, a sequence loop binds the
        // loaded element.
        ivar := new_ir_var("for_i", TI_INT)
        emit(IR_ALLOC, ivar, 0, 0, 0, TI_INT)
        emit(IR_STORE, -1, ivar, start_var, 0, 0)
        header_lbl := new_label()
        body_lbl : ., mut = new_label()
        exit_lbl := new_label()
        // The SG_FOR region covers [header, exit): the back-edge jump to the
        // header is then a jump to the region enter, so the interpreter can
        // drive loop iteration from region boundaries (region iteration).
        sg_alloc_push(SG_FOR)
        arena_var := new_ir_var("_arena", TI_INT)
        cell_store(g_sg_arena_var, (g_sg_count - 1) * 8, arena_var)
        // Header: check ivar < end, branch to exit if false
        emit(IR_LABEL, -1, header_lbl, 0, 0, 0)
        cond_var := new_ir_var("for_cond", TI_INT)
        emit(IR_BINARY, cond_var, ivar, end_var, OP_LT, 0)
        emit_cond_match(cond_var, exit_lbl, body_lbl)
        // Body
        emit(IR_LABEL, -1, body_lbl, 0, 0, 0)
        emit(IR_ARENA_NEW, arena_var, 0, 0, 0, 0)
        arena_instr := g_ir_instr_count - 1
        push_ir_scope()
        // `continue` must jump to the post (increment) label, not the header —
        // otherwise the loop variable never advances and the loop spins.
        post_lbl := new_label()
        push_loop_labels(post_lbl, exit_lbl)
        if is_seq != 0:
            elem_var_ti : ., mut = seq_elem_ti
            if seq_elem_tk == TI_DEX_S || seq_elem_tk == TI_CHAR:
                elem_var_ti = seq_elem_tk
            elem_var := new_ir_var("for_elem", elem_var_ti)
            emit(IR_LOAD_INDEX_VAR, elem_var, seq_iter_var, ivar, 0, seq_elem_tk)
            bind_local(var_ni, elem_var)
        else:
            bind_local(var_ni, ivar)
        gen_expr(body)
        pop_loop_labels()
        pop_ir_scope()
        peak := sg_peak_of_current()
        if g_no_auto_arena == 0 && peak != 0:
            iri_set_s1(arena_instr, peak)
        // Increment ivar and jump to header (arena reset runs on every path,
        // including the continue path, so per-iteration memory is reused)
        emit(IR_LABEL, -1, post_lbl, 0, 0, 0)
        emit(IR_ARENA_RESET, -1, arena_var, 0, 0, 0)
        one_var := new_ir_var("one", TI_INT)
        emit(IR_CONST, one_var, 1, 0, 0, TI_INT)
        inc_var := new_ir_var("inc", TI_INT)
        emit(IR_BINARY, inc_var, ivar, one_var, OP_ADD, 0)
        emit(IR_STORE, -1, ivar, inc_var, 0, 0)
        emit(IR_JUMP, -1, header_lbl, 0, 0, 0)
        // Exit
        emit(IR_LABEL, -1, exit_lbl, 0, 0, 0)
        sg_pop()  // close loop region (arena already reset above)
        region_plan_emit_share_after(g_sg_count - 1)
        return -1

    // Match expression
    if ast_kind(node) == EXPR_MATCH:
        match_expr := ast_a(node)
        first_arm := ast_b(node)
        // Checker-cached scrutinee type (needed to resolve payload declarations
        // when variant names are shared by several enums).
        match_ti : ., mut = -1
        md := ast_data(node)
        if md > 0:
            match_ti = md - 1
        match_val : ., mut = gen_expr(match_expr)
        match_val = force_if_thunk(match_val)
        // Allocate a result variable for the match expression value
        result_var := new_ir_var("match_res", TI_INT)
        emit(IR_ALLOC, result_var, 0, 0, 0, TI_INT)
        // The result slot gets a representation bit, defaulting to 1 (boxed).
        // Each arm sets it at its write point, so consumers (LET, return, unpack)
        // inherit the correct representation. Without the bit, an arm writing a
        // bare value would make the consumer assume oe_boxed().
        mrep_var : ., mut = -1
        if g_optrep_on != 0:
            mrep_var = new_ir_var("match_res_rep", TI_INT)
            emit(IR_CONST, mrep_var, 1, 0, 0, TI_INT)
            irv_set_rep(result_var, mrep_var)
        merge_lbl := new_label()
        // ── Supported-pattern pre-scan ───────────────────────────────────
        // One IR_MATCH requires every arm to be encodable in the CASE table:
        // int/bool literals, enum variants without sub-patterns, and one last
        // wildcard. Anything else keeps the sequential lowering unchanged.
        arm_total : ., mut = 0
        an0 : ., mut = first_arm
        loop:
            if an0 < 0:
                break
            arm_total = arm_total + 1
            an0 = ast_c(an0)
        match_mode : ., mut = 1
        if first_arm < 0:
            match_mode = 0
        // 可选表示位分派（Some/None 的裸/装箱两态）保留既有逐臂路径。
        if g_optrep_on != 0 && match_val >= 0:
            if irv_rep(match_val) >= 0:
                match_mode = 0
        // Pass A: classify support without resolving enum variant names. This
        // keeps an unsupported match's string-interning order byte-identical to
        // the old sequential lowering.
        wild_total : ., mut = 0
        saw_int : ., mut = 0
        saw_bool : ., mut = 0
        saw_enum : ., mut = 0
        saw_string : ., mut = 0
        saw_nonempty_string : ., mut = 0
        an0 = first_arm
        loop:
            if an0 < 0:
                break
            ap0 := ast_a(an0)
            k0 : ., mut = -1
            if ap0 >= 0:
                k0 = ast_kind(ap0)
            if k0 == EXPR_INT:
                saw_int = 1
                iv0 := ast_int_val(ap0)
                // The backend tags small integers as value<<1. Values outside
                // the 62-bit immediate window need the big-int path, which this
                // task does not encode in CASE.
                if iv0 > 4611686018427387903 || iv0 < -4611686018427387903:
                    match_mode = 0
            else if k0 == EXPR_BOOL:
                saw_bool = 1
            else if k0 == EXPR_ENUMPAT:
                saw_enum = 1
                if ast_c(ap0) != 0:
                    // Payload binding/guard patterns are Task 4/5.
                    match_mode = 0
            else if k0 == EXPR_STRING:
                saw_string = 1
                if istr_len(ast_int_val(ap0)) > 0:
                    saw_nonempty_string = 1
                match_mode = 0
            else if k0 == EXPR_IDENT && str_eq(istr_get(ast_int_val(ap0)), "_") != 0:
                // The lexer classifies a bare `_` as an identifier because `_`
                // is a valid identifier character; the parser's EXPR_WILDCARD
                // branch is therefore unreachable for the common form.
                wild_total = wild_total + 1
                if ast_c(an0) >= 0:
                    // A wildcard shadows every later arm; keep the old path so
                    // the CASE order cannot change which body wins.
                    match_mode = 0
            else if k0 == EXPR_WILDCARD:
                wild_total = wild_total + 1
                if ast_c(an0) >= 0:
                    match_mode = 0
            else:
                match_mode = 0
            an0 = ast_c(an0)
        if match_val < 0:
            match_mode = 0
        if saw_int != 0 && irv_type(match_val) != TI_INT:
            // The backend compares tagged int slots; a different scrutinee form
            // (dex, char, struct) needs its own lowering.
            match_mode = 0
        if saw_bool != 0 && irv_type(match_val) != TI_BOOL:
            match_mode = 0
        if saw_enum != 0 && (saw_int != 0 || saw_bool != 0):
            // The backend picks one scrutinee form per MATCH range (enum tag vs
            // value slot). Mixed rows would dispatch differently in the
            // interpreter, so keep the sequential path instead.
            match_mode = 0
        if wild_total > 1:
            match_mode = 0

        // ── Decision-tree eligibility ────────────────────────────────────
        // The local matrix compiler handles nested enum/struct/tuple, scalar
        // and string columns. Optional representation dispatch keeps the
        // sequential path; unsupported shapes fall back before any IR is
        // emitted.
        dt_mode : ., mut = 0
        if match_mode == 0 && match_ti >= 0 && match_val >= 0:
            if get_type_kind(match_ti) != TYP_OPTIONAL:
                if irv_rep(match_val) < 0:
                    dt_mode = 1
                    ck0 : ., mut = -1
                    an0 = first_arm
                    loop:
                        if an0 < 0:
                            break
                        ap0 := ast_a(an0)
                        if ap0 < 0:
                            dt_mode = 0
                            break
                        if dt_pat_supported(ap0, match_ti) == 0:
                            dt_mode = 0
                            break
                        // One decision column cannot mix enum variants with
                        // scalars; the sequential path owns that shape.
                        k0 := dt_ctor_kind(ap0)
                        if k0 != 0:
                            if ck0 < 0:
                                ck0 = k0
                            else if ck0 != k0:
                                dt_mode = 0
                                break
                        an0 = ast_c(an0)

        // Pass B: only for supported matches. Resolve enum tags and dedupe by
        // (kind, value), keeping the first arm.
        vals := alloc((arm_total + 1) * 16)   // unique cases: kind@0, value@8
        cis := alloc((arm_total + 1) * 8)     // arm -> unique-case index, -1 = duplicate
        unique_n : ., mut = 0
        arm_scan : ., mut = 0
        if match_mode != 0:
            an0 = first_arm
            loop:
                if an0 < 0:
                    break
                ap0 := ast_a(an0)
                k0 := ast_kind(ap0)
                kind0 : ., mut = -1
                value0 : ., mut = 0
                if k0 == EXPR_INT:
                    kind0 = CCR_CASE_KIND_VALUE
                    value0 = ast_int_val(ap0)
                else if k0 == EXPR_BOOL:
                    bv0 : ., mut = 0
                    if ast_int_val(ap0) != 0:
                        bv0 = 1
                    kind0 = CCR_CASE_KIND_VALUE
                    value0 = bv0
                else if k0 == EXPR_ENUMPAT:
                    kind0 = CCR_CASE_KIND_ENUM
                    value0 = get_variant_name_idx(ast_a(ap0))
                    if value0 < 0:
                        match_mode = 0
                else:
                    kind0 = CCR_CASE_KIND_DEFAULT
                    value0 = 0
                ci0 : ., mut = -1
                if match_mode != 0:
                    j0 : ., mut = 0
                    dup0 : ., mut = 0
                    loop:
                        if j0 >= unique_n:
                            break
                        if cell_load(vals, j0 * 16) == kind0:
                            if cell_load(vals, j0 * 16 + 8) == value0:
                                dup0 = 1
                                break
                        j0 = j0 + 1
                    if dup0 == 0:
                        cell_store(vals, unique_n * 16, kind0)
                        cell_store(vals, unique_n * 16 + 8, value0)
                        ci0 = unique_n
                        unique_n = unique_n + 1
                cell_store(cis, arm_scan * 8, ci0)
                arm_scan = arm_scan + 1
                an0 = ast_c(an0)
        case_base : ., mut = -1
        if match_mode != 0:
            case_base = g_lat_case_count
            // type_kind 0: MATCH is not a type-face op. The NOD semantic
            // type_id is filled by ccr_nod_type_domain from the scrutinee var,
            // so the wire records the scrutinee domain instead of an invented
            // result domain.
            emit(IR_MATCH, -1, match_val, case_base, unique_n, 0)
            g_cir_has_match = 1
            // Reserve the whole model range before emitting bodies: nested
            // matches in an arm must append after this range, not splice into it.
            cj0 : ., mut = 0
            loop:
                if cj0 >= unique_n:
                    break
                lat_case_append(cell_load(vals, cj0 * 16 + 8), cell_load(vals, cj0 * 16), -1, -1, 0)
                cj0 = cj0 + 1
        // Emit the decision tree before the arm bodies: leaves jump to the
        // pre-allocated body labels, which are emitted by the arm loop below.
        arm_lbls : string, mut = alloc(0)
        if dt_mode != 0:
            arm_lbls = alloc((arm_total + 1) * 8)
            an0 = first_arm
            ai0 : ., mut = 0
            loop:
                if an0 < 0:
                    break
                cell_store(arm_lbls, ai0 * 8, new_label())
                ai0 = ai0 + 1
                an0 = ast_c(an0)
            dt_rows := alloc((arm_total + 1) * 8)
            dt_pats := alloc((arm_total + 1) * 8)
            dt_cols := alloc(8)
            dt_tis := alloc(8)
            cell_store(dt_cols, 0, match_val)
            cell_store(dt_tis, 0, match_ti)
            ai0 = 0
            an0 = first_arm
            loop:
                if an0 < 0:
                    break
                cell_store(dt_rows, ai0 * 8, ai0)
                cell_store(dt_pats, ai0 * 8, ast_a(an0))
                ai0 = ai0 + 1
                an0 = ast_c(an0)
            dt_compile(dt_rows, dt_pats, dt_cols, dt_tis, arm_total, 1, merge_lbl, arm_lbls)

        // String length bucketing: compute the scrutinee length once so arms
        // with a different literal length skip the str_eq call entirely.
        match_len_var : ., mut = -1
        if saw_string != 0 && match_mode == 0 && dt_mode == 0 && irv_type(match_val) == TI_STR:
            match_len_var = new_ir_var("m_len", TI_INT)
            emit(IR_CALL, match_len_var, match_val, 1, str_intern("str_len"), TI_INT)
        match_first_var : ., mut = -1
        if saw_nonempty_string != 0 && match_mode == 0 && dt_mode == 0 && match_len_var >= 0:
            fb0 := new_ir_var("_fb0", TI_STR)
            fb1 := new_ir_var("_fb1", TI_INT)
            fbz := new_ir_var("_fbz", TI_INT)
            emit(IR_CONST, fbz, 0, 0, 0, TI_INT)
            emit(IR_STORE, -1, fb0, match_val, 0, 0)
            emit(IR_STORE, -1, fb1, fbz, 0, 0)
            match_first_var = new_ir_var("m_first", TI_INT)
            emit(IR_CALL, match_first_var, fb0, 2, str_intern("load8"), TI_INT)
        m_base_t := sg_alloc_cur_total()
        m_base_u := sg_alloc_cur_unknown()
        m_peak : ., mut = 0
        m_unk : ., mut = 0
        an : ., mut = first_arm
        arm_idx : ., mut = 0
        loop:
            if an < 0:
                break
            sg_alloc_set(m_base_t, m_base_u)
            arm_pat := ast_a(an)
            arm_body := ast_b(an)
            pat_kind : ., mut = -1
            if arm_pat >= 0:
                pat_kind = ast_kind(arm_pat)
            is_wildcard : ., mut = 0
            if pat_kind == EXPR_WILDCARD:
                is_wildcard = 1
            // A binding ident is irrefutable: `x` (or `_` if the lexer ever routes
            // it here) matches every value and binds the scrutinee. `_` is a
            // wildcard; every other name is a binding arm.
            is_ident_bind : ., mut = 0
            ident_ni : ., mut = -1
            if pat_kind == EXPR_IDENT:
                ident_ni = ast_int_val(arm_pat)
                if str_eq(istr_get(ident_ni), "_") != 0:
                    is_wildcard = 1
                else:
                    is_ident_bind = 1
            if match_mode != 0:
                // MATCH owns the dispatch: suppress the sequential compare chain
                // and the payload-binding reads (sub-patterns already forced the
                // fallback path).
                pat_kind = -2
                is_wildcard = 0
                is_ident_bind = 0
            // 可选表示位：臂条件与臂体绑定共用（声明在臂作用域）
            rep_v : ., mut = -1
            body_lbl : ., mut = -1
            if dt_mode != 0:
                body_lbl = cell_load(arm_lbls, arm_idx * 8)
                // The tree already dispatched this arm. Keep pat_kind intact
                // for body binding, but suppress the sequential test chain.
                is_wildcard = 1
            else:
                body_lbl = new_label()
            fall_lbl : ., mut = merge_lbl
            has_next : ., mut = 0
            if ast_c(an) >= 0:
                has_next = 1
            if is_wildcard == 1 || is_ident_bind == 1:
                emit(IR_JUMP, -1, body_lbl, 0, 0, 0)
            else if pat_kind == EXPR_ENUMPAT:
                variant_ni := get_variant_name_idx(ast_a(arm_pat))
                // 解包侧判表示，scrutinee 配表示位（可选槽）时按位分派：
                //   裸值（0）-> 值即携带值：Some 模式命中臂体（不读 tag，裸值非对象，
                //   读 tag 即 SIGSEGV = 原红态）；None 模式不命中（裸值非 null）。
                //   装箱（≠0）-> 既有 tag 分派（逐字不变）。
                // 无表示位（非可选槽 / 未覆盖情形）-> 既有路径逐字不变（装箱假定）。
                if g_optrep_on != 0 && match_val >= 0:
                    rep_v = irv_rep(match_val)
                is_opt_pat : ., mut = 0
                if str_eq(istr_get(variant_ni), "Some") != 0 || str_eq(istr_get(variant_ni), "None") != 0:
                    is_opt_pat = 1
                opt_ti : ., mut = -1
                if match_ti >= 0 && get_type_kind(match_ti) == TYP_OPTIONAL:
                    is_opt_pat = 1
                    opt_ti = match_ti
                else if match_val >= 0:
                    dti := irv_decl_ti(match_val)
                    if dti >= 0 && get_type_kind(dti) == TYP_OPTIONAL:
                        is_opt_pat = 1
                        opt_ti = dti
                if rep_v < 0 && is_opt_pat == 0:
                    if has_next == 1:
                        fall_lbl = new_label()
                    if gen_enum_pattern_test(arm_pat, match_val, fall_lbl, match_ti) < 0:
                        emit(IR_JUMP, -1, fall_lbl, 0, 0, 0)
                    else:
                        emit(IR_JUMP, -1, body_lbl, 0, 0, 0)
                else:
                    is_some_pat : ., mut = 0
                    if str_eq(istr_get(variant_ni), "Some") != 0:
                        is_some_pat = 1
                    tag_lbl := new_label()
                    if has_next == 1:
                        fall_lbl = new_label()
                    inner_ti : ., mut = -1
                    if opt_ti >= 0:
                        inner_ti = get_type_data(opt_ti)
                    if rep_v >= 0:
                        zb := new_ir_var("_rz", TI_INT)
                        emit(IR_CONST, zb, 0, 0, 0, TI_INT)
                        isb := new_ir_var("rep_isbare", TI_INT)
                        if is_some_pat != 0:
                            emit(IR_BINARY, isb, rep_v, zb, OP_EQ, 0)
                        else:
                            emit(IR_BINARY, isb, rep_v, zb, OP_NE, 0)
                        // Some：裸 -> 直接对值做载荷测试；装箱 -> 落 tag 比对。
                        // None：裸 -> 不命中（落 fall）；装箱 -> 落 tag 比对。
                        if is_some_pat != 0:
                            bare_ok := new_label()
                            emit_cond_match(isb, tag_lbl, bare_ok)
                            emit(IR_LABEL, -1, bare_ok, 0, 0, 0)
                            if gen_payload_tests(arm_pat, match_val, fall_lbl, inner_ti) < 0:
                                emit(IR_JUMP, -1, fall_lbl, 0, 0, 0)
                            else:
                                emit(IR_JUMP, -1, body_lbl, 0, 0, 0)
                        else:
                            emit_cond_match(isb, fall_lbl, tag_lbl)
                    // 无表示位（字段/全局未覆盖面）-> 既有装箱假定：直接 tag 分派。
                    emit(IR_LABEL, -1, tag_lbl, 0, 0, 0)
                    tag_var := new_ir_var("tag", TI_INT)
                    emit(IR_LOAD_ENUM_TAG, tag_var, match_val, 0, 0, 0)
                    vtag := new_ir_var("vtag", TI_INT)
                    emit(IR_CONST, vtag, variant_ni, 0, 0, TI_INT)
                    cmp_var := new_ir_var("cmp", TI_INT)
                    emit(IR_BINARY, cmp_var, tag_var, vtag, OP_EQ, 0)
                    if ast_c(arm_pat) > 0:
                        payload_ok := new_label()
                        emit_cond_match(cmp_var, fall_lbl, payload_ok)
                        emit(IR_LABEL, -1, payload_ok, 0, 0, 0)
                        fv := new_ir_var("fld", TI_INT)
                        emit(IR_LOAD_FIELD, fv, match_val, 0, 1, 0)
                        if gen_payload_tests(arm_pat, fv, fall_lbl, inner_ti) < 0:
                            emit(IR_JUMP, -1, fall_lbl, 0, 0, 0)
                        else:
                            emit(IR_JUMP, -1, body_lbl, 0, 0, 0)
                    else:
                        emit_cond_match(cmp_var, fall_lbl, body_lbl)
            else if pat_kind == EXPR_STRUCTPAT:
                // Struct pattern: sequential field tests. The lowerer never
                // classifies struct patterns as MATCH, so this is the only path.
                // A missing struct/field or an unsupported nested subpattern
                // fails closed: jump to the fall edge, never to the body.
                si := find_struct_by_name(ast_a(arm_pat))
                sc := ast_c(arm_pat)
                w0 := ast_b(arm_pat)
                can_match : ., mut = 1
                if si < 0 || w0 < 0:
                    can_match = 0
                if has_next == 1:
                    fall_lbl = new_label()
                si_i : ., mut = 0
                loop:
                    if si_i >= sc:
                        break
                    w := w0 + si_i
                    sub : ., mut = -1
                    fni : ., mut = -1
                    if w >= 0:
                        sub = ast_a(w)
                        fni = ast_b(w)
                    jdi : ., mut = -1
                    if si >= 0:
                        jdi = struct_field_index_by_name(si, fni)
                    if jdi < 0:
                        can_match = 0
                        break
                    if sub >= 0:
                        sk : ., mut = ast_kind(sub)
                        if sk != EXPR_IDENT && sk != EXPR_WILDCARD:
                            fd := ast_data(w)
                            ft : ., mut = struct_row_field_ti(si, jdi)
                            if fd > 0:
                                ft = fd - 1
                            if ti_has_generic_param(ft) != 0:
                                // The checker should have rejected this before
                                // codegen. Never emit a field load with an
                                // unresolved type: fail closed.
                                check_error(EC_TS_FIELD_TYPE,
                                    "Struct pattern field has an unresolved generic type",
                                    ast_line(sub), ast_col(sub))
                                can_match = 0
                                break
                            fv := new_ir_var("fld", TI_INT)
                            irv_set_type(fv, structpat_field_load_ti_from(ft))
                            emit(IR_LOAD_FIELD, fv, match_val, 0, jdi, 0)
                            if gen_pattern_test(sub, fv, fall_lbl, ft) < 0:
                                can_match = 0
                                break
                    si_i = si_i + 1
                if can_match != 0:
                    emit(IR_JUMP, -1, body_lbl, 0, 0, 0)
                else:
                    emit(IR_JUMP, -1, fall_lbl, 0, 0, 0)
            else if pat_kind == EXPR_TUPLEPAT:
                // Tuple pattern: sequential element tests. The checker has already
                // validated the scrutinee arity and cached each element type on the
                // wrapper. A missing wrapper/type or an unsupported subpattern fails
                // closed: jump to the fall edge, never to the body.
                tc := ast_b(arm_pat)
                tw0 := ast_a(arm_pat)
                can_match : ., mut = 1
                if tw0 < 0 || tc <= 0:
                    can_match = 0
                if has_next == 1:
                    fall_lbl = new_label()
                ti_i : ., mut = 0
                loop:
                    if ti_i >= tc:
                        break
                    w := tw0 + ti_i
                    sub : ., mut = -1
                    idx : ., mut = -1
                    fd : ., mut = 0
                    if w >= 0:
                        sub = ast_a(w)
                        idx = ast_b(w)
                        fd = ast_data(w)
                    if w < 0 || idx != ti_i || fd <= 0:
                        can_match = 0
                        break
                    sk : ., mut = -1
                    if sub >= 0:
                        sk = ast_kind(sub)
                    if sk == EXPR_IDENT || sk == EXPR_WILDCARD:
                        ti_i = ti_i + 1
                        continue
                    ft := fd - 1
                    if ti_has_generic_param(ft) != 0:
                        can_match = 0
                        break
                    fv := new_ir_var("fld", TI_INT)
                    irv_set_type(fv, structpat_field_load_ti_from(ft))
                    emit(IR_LOAD_FIELD, fv, match_val, 0, idx, 0)
                    if gen_pattern_test(sub, fv, fall_lbl, ft) < 0:
                        can_match = 0
                        break
                    ti_i = ti_i + 1
                if can_match != 0:
                    emit(IR_JUMP, -1, body_lbl, 0, 0, 0)
                else:
                    emit(IR_JUMP, -1, fall_lbl, 0, 0, 0)
            else if pat_kind == EXPR_INT:
                pat_val := new_ir_var("pval", TI_INT)
                emit(IR_CONST, pat_val, ast_int_val(arm_pat), 0, 0, TI_INT)
                cmp_var := new_ir_var("cmp", TI_INT)
                emit(IR_BINARY, cmp_var, match_val, pat_val, OP_EQ, 0)
                if has_next == 1:
                    fall_lbl = new_label()
                emit_cond_match(cmp_var, fall_lbl, body_lbl)
            else if pat_kind == EXPR_BOOL:
                pat_val := new_ir_var("pval", TI_INT)
                pat_bool : ., mut = 0
                if ast_int_val(arm_pat) != 0:
                    pat_bool = 1
                emit(IR_CONST, pat_val, pat_bool, 0, 0, TI_INT)
                cmp_var := new_ir_var("cmp", TI_INT)
                emit(IR_BINARY, cmp_var, match_val, pat_val, OP_EQ, 0)
                if has_next == 1:
                    fall_lbl = new_label()
                emit_cond_match(cmp_var, fall_lbl, body_lbl)
            else if pat_kind == EXPR_CHAR:
                // char 运行期值 = 字符驻留串索引；模式存同一索引（ast_int_val）。
                // 直接比较当前值，不改 char 语义（不是 Unicode 码点）。
                pat_val := new_ir_var("pval", TI_CHAR)
                track_str(ast_int_val(arm_pat))
                emit(IR_CONST, pat_val, ast_int_val(arm_pat), 0, 0, TI_CHAR)
                cmp_var := new_ir_var("cmp", TI_INT)
                emit(IR_BINARY, cmp_var, match_val, pat_val, OP_EQ, 0)
                if has_next == 1:
                    fall_lbl = new_label()
                emit_cond_match(cmp_var, fall_lbl, body_lbl)
            else if pat_kind == EXPR_STRING:
                // String patterns do not enter CASE: compare through str_eq and
                // branch on the boolean result (the sequential path). Length is
                // bucketed first so a different-length arm never calls str_eq.
                if has_next == 1:
                    fall_lbl = new_label()
                pat_val := new_ir_var("spat", TI_STR)
                track_str(ast_int_val(arm_pat))
                emit(IR_CONST, pat_val, ast_int_val(arm_pat), 0, 0, TI_STR)
                if match_len_var >= 0:
                    plen := new_ir_var("plen", TI_INT)
                    emit(IR_CONST, plen, istr_len(ast_int_val(arm_pat)), 0, 0, TI_INT)
                    lcmp := new_ir_var("lcmp", TI_INT)
                    emit(IR_BINARY, lcmp, match_len_var, plen, OP_EQ, 0)
                    len_ok := new_label()
                    emit_cond_match(lcmp, fall_lbl, len_ok)
                    emit(IR_LABEL, -1, len_ok, 0, 0, 0)
                if match_first_var >= 0 && istr_len(ast_int_val(arm_pat)) > 0:
                    pfirst := new_ir_var("pfirst", TI_INT)
                    emit(IR_CONST, pfirst, str_load8(ast_int_val(arm_pat), 0), 0, 0, TI_INT)
                    fcmp := new_ir_var("fcmp", TI_INT)
                    emit(IR_BINARY, fcmp, match_first_var, pfirst, OP_EQ, 0)
                    first_ok := new_label()
                    emit_cond_match(fcmp, fall_lbl, first_ok)
                    emit(IR_LABEL, -1, first_ok, 0, 0, 0)
                eq0 := new_ir_var("_seq0", TI_STR)
                eq1 := new_ir_var("_seq1", TI_STR)
                emit(IR_STORE, -1, eq0, match_val, 0, 0)
                emit(IR_STORE, -1, eq1, pat_val, 0, 0)
                cmp_var := new_ir_var("cmp", TI_BOOL)
                emit(IR_CALL, cmp_var, eq0, 2, str_intern("str_eq"), TI_BOOL)
                emit_cond_match(cmp_var, fall_lbl, body_lbl)
            else:
                // Unsupported pattern kind (struct/tuple/interpolated string/bigint).
                // Preserve refutability: never fall through to the body.
                if match_mode == 0:
                    if has_next == 1:
                        fall_lbl = new_label()
                    emit(IR_JUMP, -1, fall_lbl, 0, 0, 0)
            emit(IR_LABEL, -1, body_lbl, 0, 0, 0)
            if match_mode != 0:
                ci_arm := cell_load(cis, arm_idx * 8)
                if ci_arm >= 0:
                    // The semantic model stores the body label number. ccr_lower
                    // resolves it to the NOD id when it derives the wire table.
                    lat_case_set_target(case_base + ci_arm, body_lbl)
            push_ir_scope()
            if pat_kind == EXPR_STRUCTPAT:
                gen_structpat_binds(arm_pat, match_val)
            if pat_kind == EXPR_TUPLEPAT:
                gen_tuplepat_binds(arm_pat, match_val)
            if pat_kind == EXPR_ENUMPAT:
                sub_count := ast_c(arm_pat)
                fi : ., mut = 0
                loop:
                    if fi >= sub_count:
                        break
                    fv := new_ir_var("fld", TI_INT)
                    //  携带值读定类型取声明信息形式（dex 携带值 -> TI_DEX_S）
                    // optional 声明的携带值（内建 `Some` 类型无枚举行 ->
                    // `agg_payload_read_form` 恒 TI_INT）改由 scrutinee 的声明行补判，
                    // `irv_decl_ti(match_val)` 是 LET 期登记的 `TYP_OPTIONAL` 行（`:2573`），
                    // `dex_opt_slot_ti` 纯表读(zero alloc_type, a G2 constraint)。否则 `dex?`
                    // 携带值入 dex 运算会被当 int 再 ×S（`dex_scale_int`）。
                    fv_ti : ., mut = agg_payload_read_form(arm_pat, fi)
                    if fv_ti == TI_INT && match_val >= 0:
                        if irv_type(match_val) == TI_DEX_S:
                            fv_ti = TI_DEX_S
                        else if dex_opt_slot_ti(irv_decl_ti(match_val)) != 0:
                            fv_ti = TI_DEX_S
                        else if dex_opt_slot_ti(irv_type(match_val)) != 0:
                            fv_ti = TI_DEX_S
                    if g_optrep_on != 0 && match_val >= 0:
                        pdt := agg_payload_decl_ti(arm_pat, fi)
                        if pdt >= 0:
                            irv_set_decl_ti(fv, pdt)
                    irv_set_type(fv, fv_ti)
                    if rep_v < 0:
                        emit(IR_LOAD_FIELD, fv, match_val, 0, fi + 1, 0)  // +1 for tag offset
                    else:
                        // 解包侧判表示：裸值（0）-> 槽值即携带值（直取，不解引用）；
                        // 装箱（≠0）-> 字段 fi+1（既有语义）。裸分支须跳过装
                        // 箱分支的字段读（end_lbl），否则裸值仍被解引用（原红态）。
                        bare_lbl := new_label()
                        boxed_lbl := new_label()
                        end_lbl := new_label()
                        zb2 := new_ir_var("_rz", TI_INT)
                        emit(IR_CONST, zb2, 0, 0, 0, TI_INT)
                        ib2 := new_ir_var("rep_isbare", TI_INT)
                        emit(IR_BINARY, ib2, rep_v, zb2, OP_EQ, 0)
                        emit_cond_match(ib2, boxed_lbl, bare_lbl)
                        emit(IR_LABEL, -1, bare_lbl, 0, 0, 0)
                        emit(IR_STORE, -1, fv, match_val, 0, 0)
                        emit(IR_JUMP, -1, end_lbl, 0, 0, 0)
                        emit(IR_LABEL, -1, boxed_lbl, 0, 0, 0)
                        emit(IR_LOAD_FIELD, fv, match_val, 0, fi + 1, 0)
                        emit(IR_LABEL, -1, end_lbl, 0, 0, 0)
                    spn := sh_match_payload_root(arm_pat, fi)
                    if spn >= 0:
                        sk := ast_kind(spn)
                        if sk == EXPR_IDENT:
                            nn := ast_int_val(spn)
                            if str_eq(istr_get(nn), "_") == 0:
                                bind_local(nn, fv)
                        else if sk == EXPR_STRUCTPAT:
                            gen_structpat_binds(spn, fv)
                        else if sk == EXPR_TUPLEPAT:
                            gen_tuplepat_binds(spn, fv)
                        else if sk == EXPR_ENUMPAT:
                            pft := enum_payload_decl_ti(match_ti, arm_pat, fi)
                            if pft >= 0:
                                gen_enum_binds(spn, fv, pft)
                    fi = fi + 1
            if is_ident_bind == 1:
                // Irrefutable binding arm: the name is the scrutinee itself.
                bind_local(ident_ni, match_val)
            body_val : ., mut = gen_expr(arm_body)
            body_val = force_if_thunk(body_val)
            ad := sg_alloc_cur_total() - m_base_t
            if ad > m_peak:
                m_peak = ad
            if sg_alloc_cur_unknown() != 0:
                m_unk = 1
            sg_alloc_set(m_base_t, m_base_u)
            if body_val >= 0:
                emit(IR_STORE, -1, result_var, body_val, 0, 0)
                // 容量阶段 T2：结果槽表示位置位（同 LET/赋值的写入规则，解包点据此分派）
                if mrep_var >= 0:
                    emit_rep_set(mrep_var, rep_enc_of_expr(arm_body, body_val))
            pop_ir_scope()
            emit(IR_JUMP, -1, merge_lbl, 0, 0, 0)
            if match_mode == 0 && is_wildcard == 0 && is_ident_bind == 0 && has_next == 1:
                emit(IR_LABEL, -1, fall_lbl, 0, 0, 0)
            an = ast_c(an)
            arm_idx = arm_idx + 1
        sg_alloc_set(m_base_t + m_peak, m_base_u)
        if m_unk != 0:
            sg_alloc_set(m_base_t + m_peak, 1)
        emit(IR_LABEL, -1, merge_lbl, 0, 0, 0)
        return result_var

    // Let binding
    if ast_kind(node) == EXPR_LET:
        var_ni := ast_a(node)
        type_node := ast_b(node)
        val_node := ast_c(node)
        is_apx := ast_int_val(node)  // apx 标签位（parser 存入 iv 字段）
        // Detect dyn variable (type annotation is `dyn`)
        is_dyn_var : ., mut = 0
        if type_node >= 0 && ast_kind(type_node) == 0 && ast_type_val(type_node) == TI_DYN:
            is_dyn_var = 1
        var := new_ir_var(istr_get(var_ni), TI_UNIT)
        declared_ti : ., mut = TI_UNIT
        if type_node >= 0:
            declared_ti = res_type_node(type_node)
        // 容量阶段 T2：登记声明类型（元素写点判定目标元素类型用，声明的 `[T?;N]` 才是
        // 权威；字面量推出的元素类型对可选元素退化为对象占位 TI_UNIT）
        if g_optrep_on != 0 && type_node >= 0:
            irv_set_decl_ti(var, declared_ti)
        // 可选表示：显式 `T?` 标注的槽配表示位（默认 1 = 装箱）。
        // 推断槽（无标注）在初值求值后按初值表示补配（`v := g()` / `x := Some(1)`）。
        rep_var : ., mut = opt_rep_slot(declared_ti, istr_get(var_ni))
        if rep_var >= 0:
            irv_set_rep(var, rep_var)
        // `dex` is the source-level type; its IR slot has two forms. Only an
        // explicitly tagged `apx` declaration uses binary64 bits.
        target_ti : ., mut = declared_ti
        // `dex?` 声明的规范槽形式 = scaled（G1 决定：装箱对象是聚合类
        // 表示方式、无形式位可挂；rep 位 1 比特承载不了 2 位信息）-> 槽型由声明给定。
        // The declared type determines the slot form. A dex? declaration uses the
        // scaled form so the slot type does not fall back to the value type.
        dex_opt : ., mut = 0
        if type_node >= 0:
            dex_opt = dex_opt_type_node(type_node)
        if declared_ti == TI_DEX:
            if is_apx != 0:
                target_ti = TI_DEX
            else:
                target_ti = TI_DEX_S
            irv_set_type(var, target_ti)
        else if dex_opt != 0:
            target_ti = TI_DEX_S
            irv_set_type(var, TI_DEX_S)
        is_arr : ., mut = 0
        if type_node >= 0 && val_node < 0:
            if ast_kind(type_node) == 19:
                sz := ast_int_val(type_node)
                if sz > 0:
                    // Array stride is a target fact; corearch reconstructs it from
                    // the allocation count. src2/src3 stay zero on the wire.
                    track_alloc_array(sz)
                    emit(IR_ALLOC_ARRAY, var, sz, 0, 0, 0)
                    is_arr = 1
                    // F1：记录数组类型（TYP_ARRAY extra=size），直接索引越界
                    // 检查（arr_len_lit_of）依赖该长度信息。
                    irv_set_type(var, res_type_node(type_node))
        // For dyn vars with initializer: skip allocation (value is packed below)
        if is_dyn_var == 0 || val_node < 0:
            if is_arr == 0:
                    emit(IR_ALLOC, var, 0, 0, 0, TI_UNIT)
        // Declared scalar/pointer locals keep their declared IR row even without
        // an initializer. Leaving them TI_UNIT made uninitialized `x : int` look
        // like an alloc byte buffer / pointer to later passes.
        if is_arr == 0 && declared_ti != TI_UNIT && declared_ti != TI_DEX && dex_opt == 0:
            irv_set_type(var, declared_ti)
        if val_node >= 0:
            val_var : ., mut = gen_expr(val_node)
            deferred_ti := lazy_defer_store(val_var, var)
            if deferred_ti >= 0:
                bind_local(var_ni, var)
                if is_apx != 0:
                    emit(IR_APPROX, -1, 0, 0, 0, 0)
                return var
            val_var = force_if_thunk(val_var)
            // 可选表示：推断槽按初值表示补配表示位（有表示位可拷贝 / Some/None 构造 /
            // 未覆盖情形回落值，回落配位无害：默认 1 = 装箱 = 既有语义）
            if rep_var < 0 && g_optrep_on != 0 && rep_enc_of_expr(val_node, val_var) != oe_bare():
                rep_var = new_ir_var(istr_get(var_ni) + "_rep", TI_INT)
                irv_set_rep(var, rep_var)
            // An `apx` dex local stores binary64 bits, unlike the default
            // scaled-integer dex form. The annotation alone is not enough:
            // switch the slot type and convert the initializer before later
            // binary operations inspect its type.
            if declared_ti == TI_DEX:
                val_var = dex_store_adjust(var, val_var, val_node)
            else if dex_opt != 0:
                // `dex?` 初值入箱/入槽前先归规范形式（bits -> scaled）。
                // 后续所有写点（赋值 / 指针写 / 聚合 / 装箱）都是目标槽型驱动-> 槽型定为
                // TI_DEX_S 后既有的 dex_store_adjust 路径自动生效（无需逐点补接线）。
                val_var = dex_slot_norm(val_var)
            else if declared_ti == TI_UNIT:
                target_ti = irv_type(val_var)
                irv_set_type(var, target_ti)
            if is_dyn_var != 0:
                // Dyn variable: pack value with its type tag
                dyn_var := new_ir_var("_dyn", TI_DYN)
                tag : ., mut = irv_type(val_var)
                if tag < 0:
                    tag = TI_INT
                emit(IR_DYN_PACK, dyn_var, val_var, tag, 0, 0)
                bind_local(var_ni, dyn_var)
                if is_apx != 0:
                    emit(IR_APPROX, -1, 0, 0, 0, 0)
                return dyn_var
             // Preserve the initializer type so later operations can select
             // type-specific lowering (notably string + -> concat()).
             // `dex?` 槽不采纳值型（槽型由声明给定 TI_DEX_S），
             // 否则 `x : dex? = Some(...)`（值 = 箱对象 TI_INT）会把槽型改回 TI_INT，
             // 令裸携带值 = scaled这一规范在下游再次丢失。
            if declared_ti != TI_DEX && dex_opt == 0:
                // An explicit T? declaration keeps its optional type: the
                // initializer's enum/Some type must not replace the slot type,
                // or `?` would treat the boxed payload as an enum pointer.
                if get_type_kind(declared_ti) != TYP_OPTIONAL:
                    irv_set_type(var, irv_type(val_var))
            // F11：切片长度沿 LET 初始化传播（s := arr[0..2] -> s 带长度 2；
            // 运行时界 slice 同步长度变量，slice_len_copy_to）
            slice_len_copy_to(var, val_var)
            // (A) T3：推断声明（无注解）但值已判可选聚合 -> 声明信息继承到
            // 绑定 var（字面量/切片站点登记在值 var 上；元素写点的目标是绑定 var）
            if g_optrep_on != 0 && type_node < 0:
                vd := irv_decl_ti(val_var)
                if vd >= 0:
                    irv_set_decl_ti(var, vd)
            // (A) INV-1：取址槽恒装箱，该槽地址被取过 -> 写点装箱 + 表示位固定为 1
            //（指针写/直接写两路的表示必须一致；解包侧恒走装箱分支）
            forced := g_optrep_on != 0 && rep_var >= 0 && addr_taken_of(var_ni) != 0
            if forced != 0:
                val_var = box_for_slot_flag(val_node, val_var, 1)
            emit(IR_STORE, -1, var, val_var, 0, 0)
            // 可选表示：写点置位（静态已知常量 / 源表示位拷贝），解包点据此分派
            if rep_var >= 0:
                if forced != 0:
                    emit_rep_set(rep_var, oe_boxed())
                else:
                    emit_rep_set(rep_var, rep_enc_of_expr(val_node, val_var))
        bind_local(var_ni, var)
        if is_apx != 0:
            emit(IR_APPROX, -1, 0, 0, 0, 0)
        return var

    // Return
    if ast_kind(node) == EXPR_YIELD:
        val_node := ast_a(node)
        val_var : ., mut = -1
        if val_node >= 0:
            val_var = gen_expr(val_node)
            val_var = force_if_thunk(val_var)
        emit(IR_YIELD, -1, val_var, 0, 0, 0)
        return -1  // yield suspends — no return value for caller

    if ast_kind(node) == EXPR_AWAIT:
        val_node := ast_a(node)
        val_var : ., mut = gen_expr(val_node)
        val_var = force_if_thunk(val_var)
        dest := new_ir_var("await", TI_UNIT)
        emit(IR_AWAIT, dest, val_var, 0, 0, 0)
        return dest

    if ast_kind(node) == EXPR_RETURN:
        if ast_a(node) >= 0:
            val_node := ast_a(node)
            val_var : ., mut = gen_expr(val_node)
            val_var = force_if_thunk(val_var)
            // char/bool are raw words; an int-declared return needs the tagged
            // form at the ABI boundary (`return s[0]` used to crash at exit).
            if g_cur_ret_ti == TI_INT && (irv_type(val_var) == TI_CHAR || irv_type(val_var) == TI_BOOL):
                boxed := new_ir_var("_ret_int", TI_INT)
                emit(IR_STORE, -1, boxed, val_var, 0, 0)
                val_var = boxed
            // dex 边界规则：函数返回一律精确形式（缩放整数），
            // apx 位模式在返回点转 scaled（F2I(bits×S)，按定点 6 位舍入）
            // `-> dex?` 的 `g_cur_ret_ti` 亦为 0（`unpack_type` 塌陷）
            // -> 追加返回类型节点条件（`g_cur_ret_dex_opt`，由 ir_gen_func 设置），
            // 否则 apx 源经 `-> dex?` 返回时不转换(both ELF and interpreter paths fail)。
            if (g_cur_ret_ti == TI_DEX || g_cur_ret_dex_opt != 0) && irv_type(val_var) == TI_DEX:
                val_var = dex_bits_to_scaled(val_var)
            // 可选表示：返回点写返回信道，值求值完成后、IR_RETURN
            // 紧邻处（其间无调用 -> 嵌套调用不覆写信道；调用点紧跟 IR_CALL 读）。
            if g_cur_ret_opt != 0:
                emit_rep_set(g_optrep_ret_cell, rep_enc_of_expr(val_node, val_var))
            emit(IR_RETURN, -1, val_var, 0, 0, 0)
        else:
            emit(IR_RETURN, -1, -1, 0, 0, 0)
        return -1

    // Field access
    if ast_kind(node) == EXPR_FIELD:
        // V4 `.len` builtin (checker marks it with c = -1, data = -1).
        if ast_c(node) == -1 && ast_data(node) == -1:
            len_obj : ., mut = gen_expr(ast_a(node))
            len_obj = force_if_thunk(len_obj)
            oti := irv_type(len_obj)
            if oti == TI_STR:
                v := new_ir_var("len", TI_INT)
                emit(IR_CALL, v, len_obj, 1, str_intern("str_len"), TI_INT)
                return v
            if get_type_kind(oti) == TYP_ARRAY:
                v := new_ir_var("len", TI_INT)
                emit(IR_CONST, v, get_type_extra(oti), 0, 0, TI_INT)
                return v
            if is_slice_hdr(len_obj) != 0:
                return slice_hdr_len(len_obj)
            sl := slice_len_get(len_obj)
            if sl >= 0:
                v := new_ir_var("len", TI_INT)
                emit(IR_CONST, v, sl, 0, 0, TI_INT)
                return v
            slv := slice_len_var_get(len_obj)
            if slv >= 0:
                return slv
            check_error(EC_TK_FOR_ITER,
                "cannot determine slice length for property '.len'",
                ast_line(node), ast_col(node))
            return new_ir_var("len", TI_INT)
        obj_var : ., mut = gen_expr(ast_a(node))
        obj_var = force_if_thunk(obj_var)
        // Mirror the checker's automatic REF dereference. For a TYP_REF object,
        // the checker unwraps the reference before struct field lookup and accepts
        // p.v. This branch must emit the dereference; otherwise IR_LOAD_FIELD reads
        // the address as an aggregate and produces a wrong value.
        //
        // 只对 `TYP_REF`：`PTR` 不解，与 checker 一致(`p as *S` followed by `p.v` is rejected)。
        // `&mut x` 同为 `TYP_REF`（仅 `extra` = mut 标记不同）-> 本判定按 kind、不看 extra -> 一并覆盖。
        //
        // 发射序逐字镜像 UOP_DEREF 分支（IR_DEREF + ptr_pointee_type）。
        // 该序已被 (*p).v(value 42)证明正确，不另创新序。宽度由 corearch 从
        // pointee 语义类型重建，前端不再携带。
        if get_type_kind(irv_type(obj_var)) == TYP_REF:
            dv := new_ir_var("autoderef", ptr_pointee_type(obj_var))
            emit(IR_DEREF, dv, obj_var, -1, 0, 0)
            obj_var = dv
        v : ., mut = new_ir_var("field", TI_INT)
        fi : ., mut = ast_type_val(node)
        if fi > 0:
            fi = fi - 1  // numeric tuple index (parser stored +1)
        else:
            fi = ast_data(node)   // struct field index (from checker)
        //  读点定类型取声明信息形式（dex 声明 -> TI_DEX_S），零 alloc 节点判，
        // 非 dex 形态恒 TI_INT -> 零足迹。必须在 fi 解出之后（字段位序）。
        irv_set_type(v, agg_field_read_form(node, fi))
        if g_optrep_on != 0:
            ft := field_ti_of_node(node, fi)
            if ft >= 0 && dex_opt_slot_ti(ft) != 0:
                irv_set_decl_ti(v, ft)
        emit(IR_LOAD_FIELD, v, obj_var, 0, fi, 0)
        return v

    // Index
    if ast_kind(node) == EXPR_INDEX:
        arr_var : ., mut = gen_expr(ast_a(node))
        arr_var = force_if_thunk(arr_var)
        idx_node := ast_b(node)
        idx_kind := ast_kind(idx_node)
        arr_len_lit : ., mut = arr_len_lit_of(arr_var)
        arr_data : ., mut = arr_var
        if is_slice_hdr(arr_var) != 0:
            arr_data = slice_hdr_data(arr_var)
        // Range index: arr[low..high] -> slice (pointer to arr[low])
        if idx_kind == EXPR_RANGE:
            low_node := ast_a(idx_node)
            high_node := ast_b(idx_node)
            low_var : ., mut = gen_expr(low_node)
            low_var = force_if_thunk(low_var)
            high_var : ., mut = gen_expr(high_node)
            high_var = force_if_thunk(high_var)
            // Creation checks: high <= arr_len and low <= arr_len. The low <= high
            // run-time check needs the slice's run-time length, a known design gap;
            // literal bounds are rejected by the checker.
            if arr_len_lit > 0:
                if ast_kind(low_node) == EXPR_INT:
                    if ast_int_val(low_node) < 0 || ast_int_val(low_node) > arr_len_lit:
                        emit(IR_BOUNDS_CHECK, -1, low_var, arr_len_lit + 1, 0, 0)
                else:
                    emit(IR_BOUNDS_CHECK, -1, low_var, arr_len_lit + 1, 0, 0)
                if ast_kind(high_node) == EXPR_INT:
                    if ast_int_val(high_node) < 0 || ast_int_val(high_node) > arr_len_lit:
                        emit(IR_BOUNDS_CHECK, -1, high_var, arr_len_lit + 1, 0, 0)
                else:
                    emit(IR_BOUNDS_CHECK, -1, high_var, arr_len_lit + 1, 0, 0)
            is_str_slice : ., mut = 0
            if irv_type(arr_var) == TI_STR:
                is_str_slice = 1
            v : ., mut = -1
            if is_str_slice != 0:
                v = new_ir_var("slice", TI_STR)
                emit(IR_SLICE, v, arr_var, low_var, high_var, 0)
            else:
                // V4 slice header: {data_ptr, length}. The header pointer is the
                // slice value, so length survives function calls and stores.
                base_var : ., mut = arr_var
                if is_slice_hdr(arr_var) != 0:
                    base_var = slice_hdr_data(arr_var)
                data_var := new_ir_var("slice_data", TI_INT)
                emit(IR_SLICE, data_var, base_var, low_var, high_var, 0)
                elem_ti_s : ., mut = TI_INT
                ati := irv_type(arr_var)
                ka := get_type_kind(ati)
                if ka == TYP_ARRAY || ka == TYP_SLICE:
                    elem_ti_s = get_type_data(ati)
                v = new_ir_var("slice", alloc_type(TYP_SLICE, elem_ti_s, 0))
                track_alloc_array(2)
                emit(IR_ALLOC_ARRAY, v, 2, 0, 0, 0)
                emit(IR_STORE_INDEX, -1, v, data_var, 0, 0)
            // (A) T3：源数组元素可选 -> 切片登记声明信息（切片元素写点据此装箱；
            // 非可选不登记 -> 零足迹。切片 var 的 IR 类型信息不动，避免影响 dtype/宽度等消费者）
            if g_optrep_on != 0:
                sti := elem_ti_of(arr_var)
                if ti_is_optional(sti) != 0:
                    irv_set_decl_ti(v, alloc_type(TYP_SLICE, sti, 0))
            // F11：字面量界 -> 登记切片编译期长度（解引用处 arr_len_lit 用）；
            // 运行时界 -> 计算 len = high − low 并登记长度变量（解引用处发射
            // 动态边界检查，见 emit_slice_*_bounds）。Header slices also store
            // the length in word 1.
            if ast_kind(low_node) == EXPR_INT && ast_kind(high_node) == EXPR_INT:
                sl := ast_int_val(high_node) - ast_int_val(low_node)
                if sl >= 0:
                    slice_len_set(v, sl)
                    if is_str_slice == 0:
                        lc := new_ir_var("slice_len", TI_INT)
                        emit(IR_CONST, lc, sl, 0, 0, TI_INT)
                        emit(IR_STORE_INDEX, -1, v, lc, 1, 0)
            else:
                len_var := new_ir_var("slice_len", TI_INT)
                emit(IR_BINARY, len_var, high_var, low_var, OP_SUB, TI_INT)
                slice_len_var_set(v, len_var)
                if is_str_slice == 0:
                    emit(IR_STORE_INDEX, -1, v, len_var, 1, 0)
            return v
        v := new_ir_var("elem", TI_INT)
        //  元素读定类型取声明信息形式（元素 ti 为 dex -> TI_DEX_S；纯表读）
        elem_tk : ., mut = 0
        if irv_type(arr_var) == TI_STR:
            irv_set_type(v, TI_CHAR)
            elem_tk = TI_CHAR
        else:
            irv_set_type(v, agg_elem_read_form(arr_var))
        if idx_kind == EXPR_INT:
            emit_string_lit_bounds(arr_var, ast_int_val(idx_node))
            emit_slice_lit_bounds(arr_var, ast_int_val(idx_node))
            if pass_before_array_access(arr_var, -1, ast_int_val(idx_node), arr_len_lit) == 0:
                emit(IR_LOAD_INDEX, v, arr_data, 0, ast_int_val(idx_node), elem_tk)
        else:
            idx_var : ., mut = gen_expr(idx_node)
            idx_var = force_if_thunk(idx_var)
            emit_string_bounds(arr_var, idx_var)
            emit_slice_bounds(arr_var, idx_var)
            if pass_before_array_access(arr_var, idx_var, -1, arr_len_lit) == 0:
                emit(IR_LOAD_INDEX_VAR, v, arr_data, idx_var, 0, elem_tk)
        return v

    // Enum constructor
    if ast_kind(node) == EXPR_ENUM_CONSTRUCTOR:
        name_idx := ast_a(node)
        s := new_ir_var("enum", TI_UNIT)
        emit(IR_MAKE_ENUM, s, name_idx, ast_c(node), 0, 0)
        ai : ., mut = 0
        an : ., mut = ast_b(node)  // EXPR_ARG chain
        loop:
            if an < 0:
                break
            val_var : ., mut = gen_expr(ast_a(an))
            val_var = force_if_thunk(val_var)
            // 容量阶段 T2：可选携带值写点规范化（携带值类型 = 变体声明信息；`Some`/`None` 关键字
            // 形不带变体行 -> enum_payload_ti 返回 -1 -> 原样，不装箱）
            // 先归形式、后装箱（同上，反序 = 汇聚点无效果）
            val_var = dex_slot_norm(val_var)   // apx 阶段 T3：携带值槽恒精确
            if g_optrep_on != 0:
                val_var = box_for_optional_slot(ast_a(an), val_var, enum_payload_ti(name_idx, ai))
            emit(IR_STORE_FIELD, -1, s, val_var, ai + 1, 0)  // +1 for tag offset
            an = ast_b(an)
            ai = ai + 1
        return s

    // Struct literal
    if ast_kind(node) == EXPR_STRUCT:
        // F5 契约（见 parser.cr struct 分支）：a=name idx、b=首 wrapper（连续）、c=字段数；
        // wrapper.a=字段值节点（gen_expr 对 EXPR_NONE 前向）。逐 wrapper 解引用，不得按偏移
        // 直取相邻节点当字段值，复合字段值子树占多槽会错位（错误值且不报错）。
        //  1（名字绑定）：wrapper.b=字段名 idx（parser 写入；-1 = 无名字信息 -> 位序
        // 回落）。存字段位按名字解出（与 Python bootstrap 的 gen_struct_lit 同语义），
        // Field values bind by name, not by declaration order. Evaluation order
        // stays source order, the same as the bootstrap.
        name_ni : ., mut = ast_a(node)
        si : ., mut = ast_data(node)
        if si < 0:
            si = find_struct_by_name(name_ni)
        if si >= 0:
            name_ni = si_name(si)
        s := new_ir_var("struct", TI_UNIT)
        track_alloc_struct(name_ni)
        emit(IR_ALLOC_STRUCT, s, 0, 0, name_ni, 0)
        fi : ., mut = 0
        fn2 : ., mut = ast_b(node)
        loop:
            if fi >= ast_c(node):
                break
            if fn2 >= 0:
                // fn2 = wrapper node (kind=EXPR_NONE, a=value expr, b=field name idx)
                val_var : ., mut = gen_expr(fn2)
                val_var = force_if_thunk(val_var)
                field_idx : ., mut = fi
                nn := ast_b(fn2)
                if si >= 0 && nn >= 0:
                    jdi := struct_field_index_by_name(si, nn)
                    if jdi >= 0:
                        field_idx = jdi
                // 容量阶段 T2：可选字段写点规范化（字面量形；元素值节点 = wrapper.a）
                // 先归形式、后装箱（同上）
                val_var = dex_slot_norm(val_var)   // apx 阶段 T3：字段槽恒精确
                if g_optrep_on != 0:
                    val_var = box_for_optional_slot(ast_a(fn2), val_var, struct_row_field_ti(si, field_idx))
                emit(IR_STORE_FIELD, -1, s, val_var, field_idx, 0)
                fn2 = fn2 + 1
            fi = fi + 1
        return s

    // Array literal
    if ast_kind(node) == EXPR_ARRAY:
        // F5 契约（见 parser.cr 下标分支）：a=首 wrapper（连续）、b=元素个数；wrapper.a=元素值
        // 节点（gen_expr 对 EXPR_NONE 前向）。逐 wrapper 解引用，不得按偏移直取相邻节点。
        v : ., mut = new_ir_var("arr", TI_UNIT)
        track_alloc_unknown()
        emit(IR_ALLOC_ARRAY, v, ast_b(node), 0, 0, 0)
        elem_ti : ., mut = TI_INT
        // (A) T3：数组级元素可选性预扫，元素序在后的 Some/None 也必须影响
        // 在前的裸元素（`[2, Some(1)]`）-> 装箱判定不能只按逐元素形态。
        elem_opt_ti : ., mut = -1
        if g_optrep_on != 0:
            pn : ., mut = ast_a(node)
            pi : ., mut = 0
            loop:
                if pi >= ast_b(node):
                    break
                if pn >= 0:
                    pet := elem_ti_of_node(ast_a(pn))
                    if pet >= 0:
                        elem_opt_ti = pet
                pn = pn + 1   // wrapper 连续（F5 契约）
                pi = pi + 1
        ei : ., mut = 0
        en : ., mut = ast_a(node)
        loop:
            if ei >= ast_b(node):
                break
            if en >= 0:
                e_var : ., mut = gen_expr(en)
                e_var = force_if_thunk(e_var)
                if ei == 0:
                    elem_ti = irv_type(e_var)
                // 先取原元素类型（装箱前）
                // 容量阶段 T2：可选元素写点规范化（字面量形；元素槽无声明信息 -> 按元素
                // 表达式可选性保守判定，ident/调用覆盖范围，其余形态登记）。
                // 注意：数组字面量的 en 是 wrapper 节点（值在 ast_a），须解引用后判定。
                // (A) T3：数组级可选（预扫得）-> 逐元素判定亦须为真（裸元素装箱）。
                // 先归形式、后装箱（同上）
                e_var = dex_slot_norm(e_var)   // apx 阶段 T3：元素槽恒精确
                if g_optrep_on != 0:
                    eo : ., mut = elem_node_optional(ast_a(en))
                    if elem_opt_ti >= 0:
                        eo = 1
                    e_var = box_for_slot_flag(ast_a(en), e_var, eo)
                emit(IR_STORE_INDEX, -1, v, e_var, ei, 0)
                en = en + 1
            ei = ei + 1
        irv_set_type(v, alloc_type(TYP_ARRAY, elem_ti, ast_b(node)))
        // (A) T3：可选元素数组 -> 登记声明信息（元素写点 `elem_ti_of` 据此装箱；
        // 非可选不登记 -> 与既有语料/非可选程序零足迹）。IR 类型信息不动（只登记声明信息）。
        if g_optrep_on != 0 && elem_opt_ti >= 0:
            irv_set_decl_ti(v, alloc_type(TYP_ARRAY, elem_opt_ti, ast_b(node)))
        return v

    // Range expression (evaluates both ends, returns end)
    if ast_kind(node) == EXPR_RANGE:
        start_var : ., mut = gen_expr(ast_a(node))
        start_var = force_if_thunk(start_var)
        end_var : ., mut = gen_expr(ast_b(node))
        end_var = force_if_thunk(end_var)
        return end_var

    // Break / Continue
    if ast_kind(node) == EXPR_BREAK:
        if g_ir_loop_depth > 0:
            emit(IR_JUMP, -1, cell_load(g_ir_loop_exit, (g_ir_loop_depth - 1) * 8), 0, 0, 0)
        return -1
    if ast_kind(node) == EXPR_CONTINUE:
        if g_ir_loop_depth > 0:
            emit(IR_JUMP, -1, cell_load(g_ir_loop_header, (g_ir_loop_depth - 1) * 8), 0, 0, 0)
        return -1

    if ast_kind(node) == EXPR_WILDCARD:
        return -1
    if ast_kind(node) == EXPR_ENUMPAT:
        return -1
    if ast_kind(node) == EXPR_UNSAFE:
        sg_alloc_push(SG_UNSAFE)
        arena_var := new_ir_var("_arena", TI_INT)
        cell_store(g_sg_arena_var, (g_sg_count - 1) * 8, arena_var)
        emit(IR_ARENA_NEW, arena_var, 0, 0, 0, 0)
        arena_instr := g_ir_instr_count - 1
        ret := gen_expr(ast_a(node))
        peak := sg_peak_of_current()
        if g_no_auto_arena == 0 && peak != 0:
            iri_set_s1(arena_instr, peak)
        sg_alloc_pop()
        return ret
    if ast_kind(node) == EXPR_AS:
        inner_var : ., mut = gen_expr(ast_a(node))
        inner_var = force_if_thunk(inner_var)
        target_ti : ., mut = ti_from_type_expr(ast_b(node))
        source_ti := irv_type(inner_var)
        if get_type_kind(target_ti) == TYP_PTR:
            source_kind := get_type_kind(source_ti)
            asp : ., mut = 1
            if source_kind == TYP_PTR:
                asp = get_type_extra(source_ti)
            else if source_kind == TYP_REF || is_byte_buf_var(inner_var) != 0:
                asp = 0
            target_ti = alloc_type(TYP_PTR, get_type_data(target_ti), asp)
        // int -> dex lands in the exact form (scaled by 10^6). A store into an
        // `apx` slot converts it through dex_store_adjust like any other dex
        // value.
        if source_ti == TI_INT && target_ti == TI_DEX:
            return dex_scale_int(inner_var)
        if target_ti == TI_DEX && source_ti == TI_DEX_S:
            return inner_var
        // dex -> int: bring the value to the exact (scaled) form, copy it into
        // an int word, then divide out 10^6. Integer division truncates toward
        // zero, so -1.5 becomes -1. The copy is the same operation @raw_int
        // performs, and it is what makes the following DIV a plain int DIV
        // instead of the exact-dex operand path.
        if target_ti == TI_INT && (source_ti == TI_DEX_S || source_ti == TI_DEX):
            scaled : ., mut = inner_var
            if source_ti == TI_DEX:
                scaled = dex_bits_to_scaled(inner_var)
            raw := new_ir_var("_raw", TI_INT)
            emit(IR_STORE, -1, raw, scaled, 0, 0)
            c := new_ir_var("_dxs", TI_INT)
            emit(IR_CONST, c, 1000000, 0, 0, TI_INT)
            out := new_ir_var("_cast", TI_INT)
            emit(IR_BINARY, out, raw, c, OP_DIV, TI_INT)
            return out
        // The rest of the whitelist (identity, char, pointer) moves no bits.
        cast_var := new_ir_var("_cast", target_ti)
        emit(IR_LOAD, cast_var, inner_var, 0, 0, target_ti)
        return cast_var
    if ast_kind(node) == EXPR_TRY:
        // `?` 解包 = 解包点之一 -> 同规则判表示：裸值（0）-> 槽值即携带值
        // （直取）；装箱（≠0）-> 字段 1（tag 之后）。无表示位（未覆盖情形/非可选）-> 既有
        // 行为逐字不变（原样返回内层表达式值）。
        inner := gen_expr(ast_a(node))
        if g_optrep_on != 0 && inner >= 0:
            rv := irv_rep(inner)
            if rv >= 0:
                iti := irv_type(inner)
                pti : ., mut = iti
                if iti >= 0 && get_type_kind(iti) == TYP_OPTIONAL:
                    pti = get_type_data(iti)
                dest := new_ir_var("tryv", pti)
                bl := new_label()
                xl := new_label()
                xend := new_label()
                zb := new_ir_var("_rz", TI_INT)
                emit(IR_CONST, zb, 0, 0, 0, TI_INT)
                ib := new_ir_var("rep_isbare", TI_INT)
                emit(IR_BINARY, ib, rv, zb, OP_EQ, 0)
                emit_cond_match(ib, xl, bl)
                emit(IR_LABEL, -1, bl, 0, 0, 0)
                emit(IR_STORE, -1, dest, inner, 0, 0)
                emit(IR_JUMP, -1, xend, 0, 0, 0)
                emit(IR_LABEL, -1, xl, 0, 0, 0)
                emit(IR_LOAD_FIELD, dest, inner, 0, 1, 0)
                emit(IR_LABEL, -1, xend, 0, 0, 0)
                return dest
        return inner
    if ast_kind(node) == EXPR_STRUCTPAT:
        return -1
    if ast_kind(node) == EXPR_TUPLEPAT:
        return -1
    if ast_kind(node) == EXPR_STMT:
        gen_expr(ast_a(node))
        return -1
    if ast_kind(node) == EXPR_TUPLE:
        // Tuple: allocate array for N elements, store each
        // F5 契约：a=首 wrapper（g_ast 中连续）、b=元素个数；wrapper.a = 元素值节点
        // （复合元素值节点不连续，须经 wrapper 解引用，见 checker.cr EXPR_TUPLE 注）。
        elem_idx := ast_a(node)
        ec : ., mut = ast_b(node)
        tv := new_ir_var("tuple", TI_INT)
        // Element stride is a target fact; corearch reconstructs it.
        track_alloc_array(ec)
        emit(IR_ALLOC_ARRAY, tv, ec, 0, 0, 0)
        // Store each element at its offset
        e : ., mut = 0
        loop:
            if e >= ec:
                break
            en : ., mut = -1
            if elem_idx >= 0:
                en = ast_a(elem_idx + e)
            elem_var : ., mut = gen_expr(en)
            elem_var = force_if_thunk(elem_var)
            // 容量阶段 T2：可选元素写点规范化（元组元素槽无声明信息 -> 按元素表达式可选性
            // 保守判定；ident/调用覆盖范围，其余形态登记）
            if g_optrep_on != 0:
                elem_var = box_for_slot_flag(en, elem_var, elem_node_optional(en))
            elem_var = dex_slot_norm(elem_var)   // apx 阶段 T3：元组元素槽恒精确
            emit(IR_STORE_FIELD, -1, tv, elem_var, e, 0)
            e = e + 1
        return tv

    return -1

// --- Generate IR for one function ---

fn is_arena_infra_name(name_idx: int) -> int:
    n := istr_get(name_idx)
    if str_eq(n, "arena_init") != 0:
        return 1
    if str_eq(n, "arena_new") != 0:
        return 1
    if str_eq(n, "arena_new_sized") != 0:
        return 1
    if str_eq(n, "arena_reset") != 0:
        return 1
    if str_eq(n, "arena_grow_pool") != 0:
        return 1
    if str_eq(n, "_grow_arena_meta") != 0:
        return 1
    if str_eq(n, "_arena_copy_cells") != 0:
        return 1
    if str_eq(n, "arena_avail") != 0:
        return 1
    if str_eq(n, "arena_alloc") != 0:
        return 1
    return 0

fn ir_gen_func(fi: int):
    // Skip generic functions — they will be monomorphized at call sites
    if fi_generic_count(fi) > 0:
        return
    g_cir_has_match = 0
    fn_node := fi_ast_node(fi)
    name_idx := ast_a(fn_node)
    g_no_auto_arena = is_arena_infra_name(name_idx)
    // main's automatic arena would be created before the user's arena_init
    // call and would share ids with the explicit arena. Arena programs use the
    // explicit arena instead.
    if g_program_has_arena != 0 && str_eq(istr_get(name_idx), "main") != 0:
        g_no_auto_arena = 1
    first_param := ast_b(fn_node)
    param_count := ast_c(fn_node)
    // 返回类型：从 FuncInfo 取原始 TY_* 常量（ast_type_val(fn_node) 是返回类型
    // 节点下标而非类型常量，错读会使 g_cur_ret_ti 不等于 TI_DEX，apx 返回点
    // bits->scaled 转换失效，仅在 dex 类型节点下标恰为 1 时碰巧生效）
    ret_ti := fi_return_type(fi)
    body := ast_data(fn_node)

    // Record function metadata
    func_idx := g_ir_func_count
    grow_ir_func_meta(func_idx + 1)
    cell_store(g_ir_func_name_idx, func_idx * 8, func_link(fi))
    cell_store(g_ir_func_ret_type, func_idx * 8, ret_ti)
    cell_store(g_ir_func_instr_start, func_idx * 8, g_ir_instr_count)
    cell_store(g_ir_func_var_start, func_idx * 8, g_ir_var_count)
    cell_store(g_ir_func_param_count, func_idx * 8, param_count)

    // Create IR vars for params
    pi : ., mut = 0
    pn : ., mut = first_param
    loop:
        if pi >= param_count:
            break
        if pn < 0:
            break
        pname_idx := ast_a(pn)
        pname := istr_get(pname_idx)
        param_type : ., mut = ast_type_val(pn)
        if param_type < 0:
            param_type = TI_INT
        // dex 边界规则：参数一律精确形式（缩放整数，整数寄存器传递）
        if param_type == TI_DEX:
            param_type = TI_DEX_S
        // A dex? parameter slot uses TI_DEX_S, determined by the declaration node.
        // Using int would make the call site pass binary64 in XMM while the callee
        // reads GP, an ABI mismatch. TI_DEX_S is the GP class and matches the
        // converted argument.
        else if dex_opt_type_node(ast_data(pn)) != 0:
            param_type = TI_DEX_S
        // ── S4 形参半：`&T` 形参槽型按声明信息节点定(same form as `dex?` above)──
        // 背景（预存缺陷）：`ast_type_val(pn)` 对 `&T` = 0（`EXPR_REFTYPE` 节点未填写类型索引；
        //   上面 `if param_type < 0` 护栏拦不住 0）-> 槽型退化成 `TI_INT` -> REF 身份在 IR 形参定型处丢失
        //   -> `r.f` 在 `EXPR_FIELD` 看不到 REF -> 产生错误值且不报错(`fn f(r: &S){r.v}` returns 8 instead of 42; 
        //   pre/post 两代同值 -> 存在早于裁定二）。
        // 只查不建：`checker` 解析签名时已为该 `&T` 建过 REF 行(the type table contains `kind 3`)
        //   -> 线性查找即可 -> 零新增类型行。 `alloc_type` 是裸分配器、不去重（`checker.cr:10` 注）
        //   -> 若在此另分配一行，会写进 TYPE 段 -> 动产物字节 -> 那正是本笔要避免的。
        else if ast_kind(ast_data(pn)) == EXPR_REFTYPE:
            rinner := ti_from_type_expr(ast_a(ast_data(pn)))
            rmf := ast_int_val(ast_data(pn))
            ri : ., mut = 0
            loop:
                if ri >= g_type_count:
                    break
                if get_type_kind(ri) == TYP_REF && get_type_data(ri) == rinner && get_type_extra(ri) == rmf:
                    param_type = ri
                    break
                ri = ri + 1
        // Array/slice parameters carry a sequence type. Without this, the
        // declaration value collapses to 0 (int), and sequence consumers such
        // as `for x in xs` lose the length and element type.
        ptn_seq := ast_data(pn)
        seq_ti := seq_type_of_node(ptn_seq)
        if seq_ti >= 0:
            param_type = seq_ti
        pvar := new_ir_var(pname, param_type)
        // Bind param name
        bind_local(pname_idx, pvar)
        // (乙) A1 判断通道（`--dump-params`，隐藏）：槽型直读 = 参数判断的观测手段
        // （现 CLI 无 IR 变量槽型直读：`cir` 文本 dump 只有逐指令、`--dump-tk-terms` 是
        // DFNode.TK 派生信息、`alloc d : unit` 那行是 decl 信息）。纯表读
        // （`irv_type`/`ast_type_val`/`istr_get` + `int_str`）-> 零 alloc 副作用、
        // rc 中性 + 零产物（用不用该 flag 产物逐字节不变）。
        // `decl` = 声明信息节点 `type_val`：泛型形参 = 0 -> 与 `slot` 并排即擦除的直接证据。
        if g_dump_params_on != 0:
            print("PARAM ")
            print(istr_get(name_idx))
            print(" p")
            print(int_str(pi))
            print(" ")
            print(pname)
            print(" slot=")
            print(int_str(irv_type(pvar)))
            print(" decl=")
            print(int_str(ast_type_val(pn)))
            print("\n")
        // 可选表示：形参表示位，序言最早处从实参信道读（先于任何
        // 可能改写信道的调用；调用点在 IR_CALL 前写）。形参类型节点 = EXPR_PARAM.data。
        ptn := ast_data(pn)
        // 容量阶段 T2：形参声明类型登记（元素写点判定用；与表示位互不干扰）
        if g_optrep_on != 0 && ptn >= 0:
            irv_set_decl_ti(pvar, res_type_node(ptn))
        if g_optrep_on != 0 && g_optrep_arg_count > 0 && ptn >= 0 && pi < g_optrep_arg_count:
            pti := res_type_node(ptn)
            if pti >= 0 && get_type_kind(pti) == TYP_OPTIONAL:
                prv := new_ir_var(pname + "_prep", TI_INT)
                emit(IR_LOAD, prv, g_optrep_arg_cell0 + pi, 0, 0, TI_INT)
                irv_set_rep(pvar, prv)
                // (A) 阶段（INV-1）：取址形参恒装箱，序言内条件装箱（信道 rep = 0 裸值 -> 装箱）
                // 并把表示位固定为 1（后续含指针写在内的一切写点都由 W3/W2 保持该不变量）
                if addr_taken_of(pname_idx) != 0:
                    zb := new_ir_var("_rz", TI_INT)
                    emit(IR_CONST, zb, 0, 0, 0, TI_INT)
                    isb := new_ir_var("prep_isbare", TI_INT)
                    emit(IR_BINARY, isb, prv, zb, OP_EQ, 0)
                    bare_lbl := new_label()
                    end_lbl := new_label()
                    emit_cond_match(isb, end_lbl, bare_lbl)
                    emit(IR_LABEL, -1, bare_lbl, 0, 0, 0)
                    boxed := emit_box_some(pvar)
                    emit(IR_STORE, -1, pvar, boxed, 0, 0)
                    one := new_ir_var("prep_one", TI_INT)
                    emit(IR_CONST, one, 1, 0, 0, TI_INT)
                    emit(IR_STORE, -1, prv, one, 0, 0)
                    emit(IR_LABEL, -1, end_lbl, 0, 0, 0)
        pi = pi + 1
        // Scan past type nodes to next EXPR_PARAM
        pn = pn + 1
        loop:
            if pn >= g_ast_count:
                break
            if ast_kind(pn) == EXPR_PARAM:
                break
            pn = pn + 1

    // Function-level arena (df_begin_func already pushed SG_FUNC)
    grow_sg_alloc(g_sg_count + 1)
    grow_sg_arena_var(g_sg_count + 1)
    cell_store(g_sg_alloc_total, (g_sg_count - 1) * 8, 0)
    arena_var := new_ir_var("_arena", TI_INT)
    cell_store(g_sg_arena_var, (g_sg_count - 1) * 8, arena_var)
    emit(IR_ARENA_NEW, arena_var, 0, 0, 0, 0)
    arena_instr := g_ir_instr_count - 1

    // 程序启动期全局初始化：只在 main 序言注入，run 与 build
    // 两路径都从 main 进入（interp.cr 按名查找 main；ELF _start call main），因此
    // 无需新 IR 函数/新 .ccr 段/新 _start 指令 = 无序列化与字节布局扰动。
    // 无需运行期初始化的程序不发射任何指令（零变化）。
    if str_eq(istr_get(name_idx), "main") != 0:
        inject_global_inits()

    // Generate body（记录返回 TI，EXPR_RETURN 的 dex 边界转换用）
    g_cur_ret_ti = ret_ti
    // 返回类型节点是否 `dex?`（节点级零 alloc）。`-> dex?` 的
    // `ret_ti`（= `fi_return_type` 裸码）与 `type_val` 均为 0（`unpack_type(EXPR_OPTIONAL)`）
    // -> 返回点 dex 转换检查 `g_cur_ret_ti == TI_DEX` 恒假 -> 需本标志补位。
    g_cur_ret_dex_opt = 0
    rtn_d := ast_type_val(fn_node)
    if rtn_d >= 0 && dex_opt_type_node(rtn_d) != 0:
        g_cur_ret_dex_opt = 1
    // 可选表示：本函数返回可选时，返回点写返回信道（见 EXPR_RETURN）。
    // 判断依据是返回类型节点（ast_type_val(fn_node) = 返回类型节点下标，见上方 ret_ti
    // 注释）而非 fi_return_type 裸码（`T?` 的类型节点 type_val = 0 -> 恒判否）。
    g_cur_ret_opt = 0
    if g_optrep_on != 0 && g_optrep_ret_cell >= 0:
        rtn := ast_type_val(fn_node)
        if rtn >= 0:
            rti := res_type_node(rtn)
            if rti >= 0 && rti < g_type_count && get_type_kind(rti) == TYP_OPTIONAL:
                g_cur_ret_opt = 1
    if body >= 0:
        gen_expr(body)
    g_cur_ret_ti = -1
    g_cur_ret_opt = 0
    g_cur_ret_dex_opt = 0

    // Patch arena size and reset before return. Arena infrastructure functions
    // must not create automatic arenas: their epilogue reset would re-enter
    // arena_reset and recurse.
    peak := sg_peak_of_current()
    if g_no_auto_arena == 0 && peak != 0:
        iri_set_s1(arena_instr, peak)
    emit(IR_ARENA_RESET, -1, arena_var, 0, 0, 0)

    // Add return at end if not already terminated（可达 = 后备 return；不可达 = 死码，
    // 两后端同语义不执行）。可选返回点写装箱默认值（与 ABI 返回寄存器的未定义值同档）。
    if g_cur_ret_opt != 0:
        emit_rep_set(g_optrep_ret_cell, oe_boxed())
    emit(IR_RETURN, -1, -1, 0, 0, 0)
    g_no_auto_arena = 0

    cell_store(g_ir_func_instr_count, func_idx * 8, g_ir_instr_count - cell_load(g_ir_func_instr_start, func_idx * 8))
    cell_store(g_ir_func_var_count, func_idx * 8, g_ir_var_count - cell_load(g_ir_func_var_start, func_idx * 8))
    g_ir_func_count = func_idx + 1

// --- Initialize global IR vars from global lets ---

// Extract the compile-time constant initializer of a file-scope let
// (0 = none/not constant — BSS is zero-initialized anyway).
// NB: applies to mutable AND immutable lets (mut/const init values both
// need to be written at startup — unlike find_global_const_node which
// only folds immutable constants at compile time).
fn global_init_val(name_idx: int) -> int:
    if g_arena_pool_limit_cfg > 0 && str_eq(istr_get(name_idx), "g_arena_pool_limit") != 0:
        return g_arena_pool_limit_cfg
    i : ., mut = g_global_let_count - 1
    loop:
        if i < 0:
            break
        node := cell_load(g_global_lets, i * 8)
        if ast_a(node) == name_idx && global_decl_in_ctx(node):
            value_node := ast_c(node)
            if value_node >= 0:
                vk := ast_kind(value_node)
                if vk == EXPR_INT || vk == EXPR_BOOL:
                    return ast_int_val(value_node)
                if vk == EXPR_DEX:
                    // dex 全局常量：定点缩放整数（精确形式初始值；apx 位模式由
                    // reg_one_global 从节点 a 取，见该函数）
                    return ast_int_val(value_node)
                if vk == EXPR_UNARY && ast_c(value_node) == UOP_NEG:
                    inner := ast_a(value_node)
                    if ast_kind(inner) == EXPR_INT || ast_kind(inner) == EXPR_BOOL:
                        return 0 - ast_int_val(inner)
                    if ast_kind(inner) == EXPR_DEX:
                        return 0 - ast_int_val(inner)
        i = i - 1
    if g_cur_lib >= 0:
        i = g_global_let_count - 1
        loop:
            if i < 0:
                break
            node2 := cell_load(g_global_lets, i * 8)
            if ast_a(node2) == name_idx:
                value_node2 := ast_c(node2)
                if value_node2 >= 0:
                    vk2 := ast_kind(value_node2)
                    if vk2 == EXPR_INT || vk2 == EXPR_BOOL || vk2 == EXPR_DEX:
                        return ast_int_val(value_node2)
                    if vk2 == EXPR_UNARY && ast_c(value_node2) == UOP_NEG:
                        inner2 := ast_a(value_node2)
                        if ast_kind(inner2) == EXPR_INT || ast_kind(inner2) == EXPR_BOOL || ast_kind(inner2) == EXPR_DEX:
                            return 0 - ast_int_val(inner2)
            i = i - 1
    return 0

// 类型节点 -> `[T; N]` 的元素数 N（`[T]` 切片 = 0）；非聚合 = -1。
// 类型别名解析一层：`type Arr = [int;2]; g : Arr;` 的声明类型节点是 EXPR_IDENT
// （parser.cr parse_type 的用户类型分支），须经 g_type_aliases（{name_idx, type_node}
// 16B/条）回到底层 EXPR_ARRAY，否则同一定长数组全局类仍留 SIGSEGV。
fn agg_elem_count_of(tn: int) -> int:
    if tn < 0:
        return -1
    if ast_kind(tn) == EXPR_ARRAY:
        return ast_int_val(tn)
    if ast_kind(tn) == EXPR_IDENT:
        ni : ., mut = ast_int_val(tn)
        ai : ., mut = 0
        loop:
            if ai >= g_type_alias_count:
                break
            an := cell_load(g_type_aliases, ai * ESZ_TYPE_ALIAS + OFF_TA_NAME)
            if decl_src_for_unique(an) == ni && (g_cur_lib < 0 || decl_owner_for_unique(an) == g_cur_lib || decl_owner_for_unique(an) < 0):
                rt := cell_load(g_type_aliases, ai * ESZ_TYPE_ALIAS + OFF_TA_TYPE)
                if rt >= 0 && ast_kind(rt) == EXPR_ARRAY:
                    return ast_int_val(rt)
                break
            ai = ai + 1
    return -1

// 文件级 let 是否需要运行期初始化。
// 判断依据（与 global_init_val 互补，它只认编译期标量常量，其余归 0 且不报错）：
//   1 声明类型是聚合（`[T; N]`/`[T]`，含类型别名一层解析）-> 必须运行期分配存储；
//   2 初值存在且不是 int/bool/dex 字面量（含负号字面量）-> 必须运行期求值。
fn global_needs_runtime_init(name_idx: int) -> int:
    i : ., mut = g_global_let_count - 1
    loop:
        if i < 0:
            break
        node := cell_load(g_global_lets, i * 8)
        if ast_a(node) == name_idx && global_decl_in_ctx(node):
            // 容量阶段 T2：可选全局槽必须走运行期初始化，静态度量（.quad 裸值）写进槽后
            // 读侧按装箱解引用 -> 双路径 139(run-time failure)。装箱在 inject_global_inits
            // 内完成；非可选全局不受影响（零足迹）。
            if g_optrep_on != 0 && ti_is_optional(global_decl_ti(name_idx)) != 0:
                return 1
            if agg_elem_count_of(ast_b(node)) >= 0:
                return 1
            vn := ast_c(node)
            if vn < 0:
                return 0
            vk := ast_kind(vn)
            if vk == EXPR_INT:
                iv0 := ast_int_val(vn)
                if iv0 < -4611686018427387904 || iv0 > 4611686018427387903:
                    return 1
                return 0
            if vk == EXPR_BOOL || vk == EXPR_DEX:
                return 0
            if vk == EXPR_UNARY && ast_c(vn) == UOP_NEG:
                inner := ast_a(vn)
                ik := ast_kind(inner)
                if ik == EXPR_INT:
                    iv0 := 0 - ast_int_val(inner)
                    if iv0 < -4611686018427387904 || iv0 > 4611686018427387903:
                        return 1
                    return 0
                if ik == EXPR_BOOL || ik == EXPR_DEX:
                    return 0
            return 1
        i = i - 1
    return 0

// 按 name_idx 查已注册的全局 IR var（未注册 = -1）。
fn global_var_of(name_idx: int) -> int:
    gi : ., mut = 0
    loop:
        if gi >= g_ir_global_count:
            break
        if cell_load(g_ir_globals, gi * 24) == name_idx && cell_load(g_ir_global_lib, gi * 8) == g_cur_lib:
            return cell_load(g_ir_globals, gi * 24 + 8)
        gi = gi + 1
    gi = 0
    loop:
        if gi >= g_ir_global_count:
            return -1
        if cell_load(g_ir_globals, gi * 24) == name_idx:
            return cell_load(g_ir_globals, gi * 24 + 8)
        gi = gi + 1
    return -1

fn global_seg_index(node: int) -> int:
    line := ast_line(node)
    if line <= 0 || line > g_line_count:
        return 0
    lo := ast_lo(node)
    if lo <= 0:
        return 0
    // Import order replaces the retired byte segments: the main file is 0,
    // imported files follow in load order. global_seg_index feeds the reverse
    // module order in inject_global_inits.
    sm := sm_span_file(lo - 1)
    if sm < 0:
        return 0
    si : ., mut = 1
    while si < g_import_count:
        if cell_load(g_import_sm, si * 8) == sm:
            return si
        si = si + 1
    return 0

// 把需要运行期初始化的文件级 let 降级为 IR 序列（写进当前函数 = main 序言）。
// 顺序 = 模块依赖拓扑序的近似：导入文件按 load 顺序追加在 main 之后，因此
// 反段序（深层导入 -> 直接导入 -> main）让被依赖文件的全局先初始化；同文件内
// 保持源序。
fn inject_global_inits():
    saved_lib := g_cur_lib
    n := g_global_let_count
    order := alloc((n + 1) * 8)
    i : ., mut = 0
    loop:
        if i >= n:
            break
        cell_store(order, i * 8, i)
        i = i + 1
    i = 1
    loop:
        if i >= n:
            break
        key := cell_load(order, i * 8)
        kseg := global_seg_index(cell_load(g_global_lets, key * 8))
        j : ., mut = i - 1
        loop:
            if j < 0:
                break
            prev := cell_load(order, j * 8)
            if global_seg_index(cell_load(g_global_lets, prev * 8)) >= kseg:
                break
            cell_store(order, (j + 1) * 8, prev)
            j = j - 1
        cell_store(order, (j + 1) * 8, key)
        i = i + 1
    i = 0
    loop:
        if i >= n:
            break
        lnode := cell_load(g_global_lets, cell_load(order, i * 8) * 8)
        name_idx := ast_a(lnode)
        g_cur_lib = lib_of_node(lnode)
        if global_needs_runtime_init(name_idx) != 0:
            gv := global_var_of(name_idx)
            if gv >= 0:
                vn := ast_c(lnode)
                v : ., mut = -1
                if vn >= 0:
                    v = gen_expr(vn)
                    v = force_if_thunk(v)
                else:
                    // 无初值聚合：整流分配（零初始化由 alloc 语义保证，rt.s 的 rep stosb；
                    // 解释器 IR_ALLOC_ARRAY 显式清零）。仅 `[T; N]`（N ≥ 1）注入；`[T]`
                    // （切片无长度，N = 0）不注入，保持 BSS 零 = 空切片/哑指针，
                    // 空切片解引用属独立 null 陷阱类.
                    cnt := agg_elem_count_of(ast_b(lnode))
                    if cnt > 0:
                        v = new_ir_var("ginit", TI_UNIT)
                        track_alloc_array(cnt)
                        emit(IR_ALLOC_ARRAY, v, cnt, 0, 0, 0)
                        irv_set_type(v, alloc_type(TYP_ARRAY, TI_INT, cnt))
                if v >= 0:
                    // 容量阶段 T2：可选全局槽初值写点规范化（与赋值点 :1155 是两处独立
                    // 代码点，初值走 inject_global_inits，赋值走 EXPR_ASSIGN）
                    // 先归形式、后装箱（同上，反序 = 汇聚点无效果）
                    v = dex_store_adjust(gv, v, vn)   // apx 阶段 T3：全局初值按槽声明型（含 apx 全局）
                    if g_optrep_on != 0:
                        v = box_for_optional_slot(vn, v, global_decl_ti(name_idx))
                    emit(IR_STORE, -1, gv, v, 0, 0)
        i = i + 1
    if g_cfg_arena_zero_on_reset != 0:
        gz := global_var_of(str_intern("g_arena_zero_on_reset"))
        if gz >= 0:
            zv := new_ir_var("arena_zero_cfg", TI_INT)
            emit(IR_CONST, zv, 1, 0, 0, TI_INT)
            emit(IR_STORE, -1, gz, zv, 0, 0)
    g_cur_lib = saved_lib

// Register one IR global, deduplicated by name_idx.
fn reg_one_global(name_idx: int):
    saved_lib := g_cur_lib
    decl_owner := global_decl_owner(name_idx)
    if decl_owner >= 0:
        g_cur_lib = decl_owner
    found : ., mut = 0
    gi : ., mut = 0
    loop:
        if gi >= g_ir_global_count:
            break
        if cell_load(g_ir_globals, gi * 24) == name_idx && cell_load(g_ir_global_lib, gi * 8) == g_cur_lib:
            found = 1
            break
        gi = gi + 1
    if found == 0:
        name := istr_get(name_idx)
        // dex 全局变量：精确（TI_DEX_S，缩放整数初始值）或
        // apx（TI_DEX，binary64 位模式初始值），按声明 LET 的类型节点与 apx 位
        gtype : ., mut = TI_INT
        is_dex_global : ., mut = 0
        gli : ., mut = 0
        loop:
            if gli >= g_global_let_count:
                break
            lnode := cell_load(g_global_lets, gli * 8)
            if ast_a(lnode) == name_idx && global_decl_in_ctx(lnode):
                ltn := ast_b(lnode)
                if ltn >= 0 && ast_kind(ltn) == 0 && ast_type_val(ltn) == TY_DEX:
                    if ast_int_val(lnode) != 0:
                        gtype = TI_DEX
                    else:
                        gtype = TI_DEX_S
                    is_dex_global = 1
                else if ltn >= 0 && dex_opt_type_node(ltn) != 0:
                    // A dex? global slot uses the scaled form. is_dex_global stays 0
                    // because its only consumer handles apx bit-pattern globals.
                    gtype = TI_DEX_S
                break
            gli = gli + 1
        gvar := new_ir_var(name, gtype)
        grow_ir_globals(g_ir_global_count + 1)
        cell_store(g_ir_globals, g_ir_global_count * 24, name_idx)
        cell_store(g_ir_globals, g_ir_global_count * 24 + 8, gvar)
        // Const initializer — emitted by the ELF backend's _init_globals.
        iv : int, mut = global_init_val(name_idx)
        if is_dex_global != 0 && gtype == TI_DEX:
            // apx 全局：初始值为 binary64 位模式（缩放值 -> bits 从节点 a 取）
            i2 : ., mut = 0
            loop:
                if i2 >= g_global_let_count:
                    break
                lnode2 := cell_load(g_global_lets, i2 * 8)
                if ast_a(lnode2) == name_idx && global_decl_in_ctx(lnode2):
                    vn := ast_c(lnode2)
                    if vn >= 0 && ast_kind(vn) == EXPR_DEX:
                        iv = ast_a(vn)
                    break
                i2 = i2 + 1
        cell_store(g_ir_globals, g_ir_global_count * 24 + 16, iv)
        cell_store(g_ir_global_lib, g_ir_global_count * 8, g_cur_lib)
        g_ir_global_count = g_ir_global_count + 1
    g_cur_lib = saved_lib

fn ir_gen_globals():
    ccr_set_raw_mode_from_source()
    saved_lib := g_cur_lib
    // The parser records only file-scope declarations in g_global_lets.
    // Do not scan every EXPR_LET here: that also includes function locals.
    i : ., mut = 0
    loop:
        if i >= g_global_let_count:
            break
        node := cell_load(g_global_lets, i * 8)
        g_cur_lib = lib_of_node(node)
        reg_one_global(ast_a(node))
        i = i + 1

    g_cur_lib = lib_find("@core")
    // Manually register ir_gen.cr's own globals — the parser's auto-detection
    // of file-scope declarations is known to miss some (see CLAUDE.md Known Issues).
    reg_one_global(str_intern("g_sg_alloc_total"))
    reg_one_global(str_intern("g_sg_alloc_cap"))
    reg_one_global(str_intern("g_sg_arena_var"))
    reg_one_global(str_intern("g_sg_arena_var_cap"))
    reg_one_global(str_intern("g_ir_source_hash"))
    reg_one_global(str_intern("g_ir_source_hash_ready"))
    reg_one_global(str_intern("g_cir_write_buf"))
    reg_one_global(str_intern("g_cir_write_pos"))
    reg_one_global(str_intern("g_cir_write_cap"))
    // v21 生成期 intern 日志（cir_cache.cr/dyn_arr.cr/globals.cr 共用；新增编译器侧全局
    // 必须在此登记，parser 的 file-scope 自动发现已知会漏，漏登记 -> 赋值丢弃或落错槽且不报错）。
    reg_one_global(str_intern("g_cir_rec_on"))
    reg_one_global(str_intern("g_cir_rec_ids"))
    reg_one_global(str_intern("g_cir_rec_count"))
    reg_one_global(str_intern("g_cir_rec_cap"))
    reg_one_global(str_intern("g_cir_rec_base"))
    reg_one_global(str_intern("g_cir_skip_journal"))
    // Runtime globals needed by emit_alloc_body and emit_start.
    // These MUST exist in BSS for every program, even without rt.cr included.
    reg_one_global(str_intern("g_heap_ptr"))
    reg_one_global(str_intern("g_heap_end"))
    reg_one_global(str_intern("g_current_arena"))
    // Both allocator bodies write this failure witness before trapping.
    // Register it for every program so the legacy body's witness does not
    // fall back to an unpatched RIP-relative store.
    reg_one_global(str_intern("g_alloc_fail_request"))
    reg_one_global(str_intern("g_alloc_fail_class"))
    reg_one_global(str_intern("g_alloc_fail_cursor"))
    reg_one_global(str_intern("g_alloc_fail_limit"))
    reg_one_global(str_intern("g_arena_cursors"))
    reg_one_global(str_intern("g_arena_sizes"))
    reg_one_global(str_intern("g_arena_parents"))
    reg_one_global(str_intern("g_arena_max_size"))
    reg_one_global(str_intern("g_arena_count"))
    reg_one_global(str_intern("g_arena_cap"))
    reg_one_global(str_intern("g_arena_pool_data"))
    reg_one_global(str_intern("g_arena_free_list"))
    g_cur_lib = saved_lib
    reg_optrep_globals()

// 表示方式初始化（两条 IR 生成入口都必须先调：ir_gen_all 批量路径 + main.cr 文件路径
// （逐函数 + .cir 缓存），后者不经过本文件的批量入口，漏调即侧表未分配）。位置：
// 先于 ir_gen_globals（隐藏信道的 var 记录顺序 = 全局记录顺序依赖）。
fn optrep_begin():
    g_ir_var_rep = ""
    g_ir_var_rep_cap = 0
    g_ir_var_decl_ti = ""
    g_ir_var_decl_cap = 0
    g_optrep_ret_cell = -1
    g_optrep_arg_cell0 = -1
    g_optrep_arg_count = 0
    g_cur_ret_opt = 0
    optrep_prescan()
    optrep_addr_prescan()

// Address-taken prescan, one pass over the AST, collecting the name indexes of all
// address-taken identifiers. A criterion is `&ident`, where UOP_REF's operand is
// EXPR_IDENT. Other address forms follow design section 2.3: `&arr[i]` is an
// already boxed aggregate, other expressions are temporaries, function addresses
// are not slots, pointer arithmetic is a REP-2 boundary, and externs are
// recorded.
fn grow_addr_taken(needed: int):
    if needed <= g_addr_taken_cap:
        return
    nc : ., mut = g_addr_taken_cap * 2
    if nc < 32:
        nc = 32
    if nc < needed:
        nc = needed + 32
    nb := alloc(nc * 8)
    cell_copy(g_addr_taken_names, g_addr_taken_cap * 8, nb)
    g_addr_taken_names = nb
    g_addr_taken_cap = nc
fn addr_taken_add(ni: int):
    if ni < 0:
        return
    if addr_taken_of(ni) != 0:
        return
    // 去重（线性扫；量级 = 源码里 &ident 的条数）
    grow_addr_taken(g_addr_taken_count + 1)
    cell_store(g_addr_taken_names, g_addr_taken_count * 8, ni)
    g_addr_taken_count = g_addr_taken_count + 1
fn addr_taken_of(ni: int) -> int:
    if ni < 0:
        return 0
    i : ., mut = 0
    loop:
        if i >= g_addr_taken_count:
            return 0
        if cell_load(g_addr_taken_names, i * 8) == ni:
            return 1
        i = i + 1
    return 0
fn optrep_addr_prescan():
    g_addr_taken_count = 0
    i : ., mut = 0
    loop:
        if i >= g_ast_count:
            break
        if ast_kind(i) == EXPR_UNARY && ast_c(i) == UOP_REF:
            opn := ast_a(i)
            if opn >= 0 && ast_kind(opn) == EXPR_IDENT:
                addr_taken_add(ast_int_val(opn))
        i = i + 1

// 表示方式启用扫描（零足迹检查）：AST 含任一 `T?` 类型节点（EXPR_OPTIONAL）或任一
// `Some`/`None` 构造（关键字名分派，与 checker 同规约：用户变体同名时上方 SYM_FN 优先，
// 但扫描宽于实际使用只会多启用一层空机器、不会漏启用，条件为启用 -> 表示方式完整）。
fn optrep_prescan():
    g_optrep_on = 0
    i : ., mut = 0
    loop:
        if i >= g_ast_count:
            break
        k := ast_kind(i)
        if k == EXPR_OPTIONAL:
            g_optrep_on = 1
            break
        if k == EXPR_ENUM_CONSTRUCTOR:
            nm := istr_get(ast_a(i))
            if str_eq(nm, "Some") != 0 || str_eq(nm, "None") != 0:
                g_optrep_on = 1
                break
        i = i + 1

// 隐藏全局注册（照 reg_one_global 形态但不查 g_global_lets，编译器内部名，零初值）。
// var_idx == 记录顺序（save_ccr 的全局记录顺序检查）由本函数只在 ir_gen_globals 尾部调用、
// 此后不再注册全局保证。
fn reg_hidden_global(name_ni: int) -> int:
    gvar := new_ir_var(istr_get(name_ni), TI_INT)
    grow_ir_globals(g_ir_global_count + 1)
    cell_store(g_ir_globals, g_ir_global_count * 24, name_ni)
    cell_store(g_ir_globals, g_ir_global_count * 24 + 8, gvar)
    cell_store(g_ir_globals, g_ir_global_count * 24 + 16, 0)
    cell_store(g_ir_global_lib, g_ir_global_count * 8, g_cur_lib)
    g_ir_global_count = g_ir_global_count + 1
    return gvar

// 可选表示的跨函数信道注册（仅在 g_optrep_on 时）：返回信道单元 + 每形参位一个实参
// 信道单元（连续 var 索引；被调按形参位读、调用点按实参位写）。
fn reg_optrep_globals():
    g_optrep_ret_cell = -1
    g_optrep_arg_cell0 = -1
    g_optrep_arg_count = 0
    if g_optrep_on == 0:
        return
    maxp : ., mut = 0
    fi2 : ., mut = 0
    loop:
        if fi2 >= g_func_count:
            break
        pc := fi_param_count(fi2)
        if pc > maxp:
            maxp = pc
        fi2 = fi2 + 1
    if maxp > 64:
        maxp = 64
    g_optrep_ret_cell = reg_hidden_global(str_intern("__optrep_ret"))
    j : ., mut = 0
    loop:
        if j >= maxp:
            break
        cv := reg_hidden_global(str_intern("__optrep_arg" + int_str(j)))
        if j == 0:
            g_optrep_arg_cell0 = cv
        j = j + 1
    g_optrep_arg_count = maxp

// --- AST walk: patch method call names for monomorphization ---

fn ast_patch_node(node: int, subst_from: string, subst_to: string):
    if node < 0:
        return
    k := ast_kind(node)
    if k == EXPR_CALL:
        func_node := ast_a(node)
        if ast_kind(func_node) == EXPR_FIELD:
            data_ni := ast_data(node)
            if data_ni >= 0:
                data_str := istr_get(data_ni)
                dlen := str_len(data_str)
                flen := str_len(subst_from)
                if dlen >= flen:
                    matches : ., mut = 1
                    dci : ., mut = 0
                    loop:
                        if dci >= flen:
                            break
                        if cell_load_byte(data_str, dci) != cell_load_byte(subst_from, dci):
                            matches = 0
                            break
                        dci = dci + 1
                    if matches != 0 && (dlen == flen || cell_load_byte(data_str, flen) == 46):
                        rest := str_sub(data_str, flen, dlen - flen)
                        new_name := subst_to + rest
                        ast_set_data(node, str_intern(new_name))
    // Recurse into children based on node kind
    if k == EXPR_BLOCK:
        ss := ast_a(node)
        sc := ast_b(node)
        i2 : ., mut = 0
        loop:
            if i2 >= sc:
                break
            sn2 := cell_load(g_block_stmts, (ss + i2) * 8)
            ast_patch_node(sn2, subst_from, subst_to)
            i2 = i2 + 1
    else if k == EXPR_IF || k == EXPR_LOOP || k == EXPR_WHILE || k == EXPR_UNSAFE:
        if ast_a(node) >= 0:
            ast_patch_node(ast_a(node), subst_from, subst_to)
        if k == EXPR_IF:
            if ast_b(node) >= 0:
                ast_patch_node(ast_b(node), subst_from, subst_to)
            if ast_c(node) >= 0:
                ast_patch_node(ast_c(node), subst_from, subst_to)
    else if k == EXPR_BINARY || k == EXPR_ASSIGN || k == EXPR_RANGE || k == EXPR_AS:
        if ast_a(node) >= 0:
            ast_patch_node(ast_a(node), subst_from, subst_to)
        if ast_b(node) >= 0:
            ast_patch_node(ast_b(node), subst_from, subst_to)
    else if k == EXPR_CALL || k == EXPR_ENUM_CONSTRUCTOR:
        if ast_a(node) >= 0:
            ast_patch_node(ast_a(node), subst_from, subst_to)
        an3 : ., mut = ast_b(node)
        ac3 := ast_c(node)
        ai3 : ., mut = 0
        loop:
            if ai3 >= ac3:
                break
            if an3 >= 0:
                ast_patch_node(an3, subst_from, subst_to)
                an3 = an3 + 1
            ai3 = ai3 + 1
    else if k == EXPR_MATCH:
        if ast_a(node) >= 0:
            ast_patch_node(ast_a(node), subst_from, subst_to)
        an4 : ., mut = ast_b(node)
        loop:
            if an4 < 0:
                break
            if ast_a(an4) >= 0:
                ast_patch_node(ast_a(an4), subst_from, subst_to)
            if ast_b(an4) >= 0:
                ast_patch_node(ast_b(an4), subst_from, subst_to)
            an4 = ast_c(an4)
    else if k == EXPR_FOR:
        if ast_b(node) >= 0:
            ast_patch_node(ast_b(node), subst_from, subst_to)
        if ast_c(node) >= 0:
            ast_patch_node(ast_c(node), subst_from, subst_to)
    else if k == EXPR_LET:
        if ast_c(node) >= 0:
            ast_patch_node(ast_c(node), subst_from, subst_to)
    else if k == EXPR_STMT:
        if ast_a(node) >= 0:
            ast_patch_node(ast_a(node), subst_from, subst_to)
    else if k == EXPR_STRUCT:
        // a = type name index, b = first wrapper (contiguous), c = field count,
        // wrapper.a = field value node. Dereference the wrapper and recurse.
        // Passing the EXPR_NONE wrapper itself to ast_patch_node would do nothing,
        // so method names in struct literal fields inside generic instances would
        // not be replaced.
        an5 : ., mut = ast_b(node)
        ac5 := ast_c(node)
        ai5 : ., mut = 0
        loop:
            if ai5 >= ac5:
                break
            if an5 >= 0:
                vn5 : ., mut = -1
                if ast_kind(an5) == EXPR_NONE:
                    vn5 = ast_a(an5)
                if vn5 >= 0:
                    ast_patch_node(vn5, subst_from, subst_to)
                an5 = an5 + 1
            ai5 = ai5 + 1
    else if k == EXPR_ARRAY:
        // a=first wrapper（连续）, b=elem_count；wrapper.a=元素值节点（F5 契约，见 parser.cr 下标分支）
        an6 : ., mut = ast_a(node)
        ac6 := ast_b(node)
        ai6 : ., mut = 0
        loop:
            if ai6 >= ac6:
                break
            if an6 >= 0:
                vn6 : ., mut = -1
                if ast_kind(an6) == EXPR_NONE:
                    vn6 = ast_a(an6)
                if vn6 >= 0:
                    ast_patch_node(vn6, subst_from, subst_to)
                an6 = an6 + 1
            ai6 = ai6 + 1
    else if k == EXPR_TUPLE:
        // a=first wrapper（连续）, b=elem_count；wrapper.a=元素值节点（F5 契约）
        an6 : ., mut = ast_a(node)
        ac6 := ast_b(node)
        ai6 : ., mut = 0
        loop:
            if ai6 >= ac6:
                break
            if an6 >= 0:
                vn6 : ., mut = -1
                if ast_kind(an6) == EXPR_NONE:
                    vn6 = ast_a(an6)
                if vn6 >= 0:
                    ast_patch_node(vn6, subst_from, subst_to)
                an6 = an6 + 1
            ai6 = ai6 + 1
    else if k == EXPR_FIELD || k == EXPR_INDEX || k == EXPR_UNARY || k == EXPR_RETURN || k == EXPR_TRY:
        if ast_a(node) >= 0:
            ast_patch_node(ast_a(node), subst_from, subst_to)

fn find_or_create_mono_func(fi: int, call_node: int) -> int:
    // Create a monomorphized version of generic function fi for the given call site.
    // Only creates the FuncInfo entry — IR generation happens in pass 2 of ir_gen_all.

    fn_node := fi_ast_node(fi)
    body := ast_data(fn_node)
    first_param := ast_b(fn_node)
    param_count := ast_c(fn_node)
    orig_ret_type := ast_int_val(fn_node)
    orig_ret_node := ast_type_val(fn_node)

    gen_name_ni := fi_generic_name(fi, 0)
    gen_name := istr_get(gen_name_ni)

    // Get concrete type name from call node (stored by checker)
    concrete_type_ni : ., mut = ast_int_val(call_node)
    concrete_type_name : ., mut = istr_get(concrete_type_ni)

    // Create mangled name: "funcname$genericname.concretetype"
    orig_fn_name := istr_get(fi_name(fi))
    mangled_name : ., mut = orig_fn_name + "$"
    mangled_name = mangled_name + gen_name + "." + concrete_type_name
    mangled_ni := str_intern(mangled_name)

    // Check if already exists
    existing := find_func(mangled_ni)
    if existing >= 0:
        return existing

    // Create new EXPR_PARAM nodes with concrete param types
    new_first_param : ., mut = -1
    ppi : ., mut = 0
    ppn : ., mut = first_param
    loop:
        if ppi >= param_count:
            break
        if ppn < 0:
            break
        pname_ni := ast_a(ppn)
        self_mode := ast_int_val(ppn)
        orig_type_val := ast_type_val(ppn)
        orig_type_node := ast_data(ppn)

        // Replace type node if it references the generic param
        new_type_node : ., mut = orig_type_node
        if orig_type_node >= 0 && ast_kind(orig_type_node) == EXPR_IDENT && ast_int_val(orig_type_node) == gen_name_ni:
            // Create new type node referencing concrete type name
            new_type_node = alloc_node(EXPR_IDENT, 0, 0, 0, concrete_type_ni, 0, 0, 0, 0)

        np := alloc_node(EXPR_PARAM, pname_ni, 0, 0, self_mode, orig_type_val, new_type_node, 0, 0)
        if ppi == 0:
            new_first_param = np
        ppi = ppi + 1
        ppn = ppn + 1
        loop:
            if ppn >= g_ast_count:
                break
            if ast_kind(ppn) == EXPR_PARAM:
                break
            ppn = ppn + 1

    // Create new EXPR_FN node
    new_fn_node := alloc_node(EXPR_FN, mangled_ni, new_first_param, param_count, orig_ret_type, orig_ret_node, body, 0, 0)

    // Patch body: replace "gen_name.method" -> "concrete_type_name.method"
    if body >= 0:
        ast_patch_node(body, gen_name, concrete_type_name)

    // Register new function
    new_fi := add_func(mangled_name, param_count, orig_ret_type, new_fn_node)
    if new_fi >= 0:
        // Copy generic constraint info (non-generic now, but keep for reference)
        fi_set_generic_count(new_fi, 0)

    return new_fi

// --- Main entry ---

fn text_has_marker(text: string, marker: string) -> int:
    sl := str_len(text)
    ml := str_len(marker)
    if ml <= 0 || sl < ml:
        return 0
    i : ., mut = 0
    loop:
        if i + ml > sl:
            break
        j : ., mut = 0
        loop:
            if j >= ml:
                break
            if cell_load_byte(text, i + j) != cell_load_byte(marker, j):
                break
            j = j + 1
        if j >= ml:
            return 1
        i = i + 1
    return 0

fn ccr_source_has_marker(marker: string) -> int:
    // Scan every file in the import graph, not just the main file. A marker in
    // an imported compiler file still selects the compiler-specific lowering.
    if g_prelude_sm >= 0 && text_has_marker(sm_file_text(g_prelude_sm), marker) != 0:
        return 1
    i : ., mut = 0
    loop:
        if i >= g_import_count:
            break
        sm := cell_load(g_import_sm, i * 8)
        if text_has_marker(sm_file_text(sm), marker) != 0:
            return 1
        i = i + 1
    return text_has_marker(g_source, marker)

fn ccr_source_dir_is_compiler() -> int:
    d := g_source_dir
    n := str_len(d)
    if str_eq(d, "src/compiler") != 0:
        return 1
    if n >= 12 && str_eq(str_sub(d, n - 12, 12), "src/compiler") != 0:
        return 1
    if n >= 13 && cell_load_byte(d, n - 1) == 47:
        if str_eq(str_sub(d, n - 13, 12), "src/compiler") != 0:
            return 1
    return 0

fn ccr_set_raw_mode_from_source():
    // Compiler and backend sources keep raw machine integers. User programs use
    // the tagged BigInt semantics by default. The .ccr header carries this flag
    // to corearch so both sides agree before code generation.
    g_ccr_emit_raw_int = 0
    g_program_has_arena = ccr_source_has_marker("fn arena_init")
    if ccr_source_has_marker("fn parse_expr") != 0:
        g_ccr_emit_raw_int = 1
    if ccr_source_has_marker("fn corearch_main") != 0:
        g_ccr_emit_raw_int = 1
    if ccr_source_has_marker("import cli") != 0:
        // The CLI word-table layer intentionally stores raw string pointers via
        // cell_store/cell_load and views them back through @str_of. Legacy raw
        // semantics are required for that table; user CLI programs are not
        // arithmetic kernels.
        g_ccr_emit_raw_int = 1
    if ccr_source_dir_is_compiler() != 0:
        g_ccr_emit_raw_int = 1

fn ir_gen_all():
    ccr_set_raw_mode_from_source()
    saved_lib := g_cur_lib
    if g_plan_active == 0:
        region_plan_reset()
    lazy_gen_reset()
    g_sg_count = 0
    g_cur_sg = -1
    rc_ctl_invalidate()
    // Second IR runs inherit whole-program facts from Phase A. Reset the
    // generation-time optimistic purity and usage counts so Phase B matches a
    // cold v1 generation (lazy thunks depend on both).
    gs : ., mut = 0
    loop:
        if gs >= g_func_count:
            break
        fi_set_ispure(gs, 1)
        gs = gs + 1
    g_purity_inst_count = 0
    g_var_use_count = ""
    g_var_use_count_cap = 0
    g_df_state_finalized = 0
    g_ir_var_count = 0
    g_ir_instr_count = 0
    g_ir_func_count = 0
    g_ir_local_count = 0
    g_ir_local_depth = 0
    g_ir_global_count = 0
    g_next_label = 1
    g_ir_loop_depth = 0
    g_ir_str_const_count = 0
    g_lat_case = ""
    g_lat_case_count = 0
    g_lat_case_cap = 0
    // The wire table is derived by ccr_lower; reset it too so a second IR run
    // in one process cannot inherit stale rows.
    g_ccr_case = ""
    g_ccr_case_count = 0
    g_ccr_case_cap = 0
    g_cir_has_match = 0
    // 可选表示方式：侧表复位 + 启用扫描（先于全局注册，隐藏信道的 var 记录顺序依赖）
    optrep_begin()

    // Initialize dataflow graph
    init_df()

    // Initialize globals
    ir_gen_globals()

    i : ., mut = 0
    loop:
        if i >= g_func_count:
            break
        if fi_generic_count(i) > 0:
            i = i + 1
            continue
        ir_func_idx := g_ir_func_count
        df_begin_func(ir_func_idx)
        ir_gen_func(i)
        df_end_func(ir_func_idx)
        i = i + 1

    if g_plan_active != 0 && g_plan_share_count > 0 && g_plan_share_reset_emitted != g_plan_share_count:
        check_error(EC_B_LIFETIME, "share resets were not emitted for every planned slot", 0, 0)

    // 纯度 + 状态依赖边序列最终化（全部 IR 体就绪后；理由见 checker.cr compute_all_purity
    // 与 dataflow.cr df_replay_state_chain 头注）。文件路径的同点调用在 main.cr。
    df_state_finalize()
    g_cur_lib = saved_lib

// Compute function body fingerprint: hash of the function body source text.
// Used for cache hit detection. If the body hasn't changed, the output IR
// is identical and can be restored from cache.
fn func_fingerprint(func_node: int) -> int:
    // func_node = EXPR_FUNC node
    // Body starts at ast_data(func_node)
    body := ast_data(func_node)
    if body < 0:
        return 0
    // For fingerprinting, hash the function's AST line/col range in source
    // This is simpler than extracting the exact body bytes:
    // hash AST node kind chain from the body
    if g_ir_source_hash_ready == 0:
        source_hash : ., mut = 2166136261
        // Hash every graph file in parse order. Hashing only the main file
        // would let an edit in an imported file reuse a stale cache entry.
        if g_prelude_sm >= 0:
            ptxt := sm_file_text(g_prelude_sm)
            pp : ., mut = 0
            plen := str_len(ptxt)
            loop:
                if pp >= plen:
                    break
                source_hash = source_hash * 16777619 + cell_load_byte(ptxt, pp)
                pp = pp + 1
            source_hash = source_hash * 16777619 + 10
        gi : ., mut = 0
        loop:
            if gi >= g_import_count:
                break
            gsm := cell_load(g_import_sm, gi * 8)
            gtxt := sm_file_text(gsm)
            source_pos : ., mut = 0
            source_len := str_len(gtxt)
            loop:
                if source_pos >= source_len:
                    break
                source_hash = source_hash * 16777619 + cell_load_byte(gtxt, source_pos)
                source_pos = source_pos + 1
            source_hash = source_hash * 16777619 + 10
            gi = gi + 1
        if g_import_count == 0:
            source_pos : ., mut = 0
            source_len := str_len(g_source)
            loop:
                if source_pos >= source_len:
                    break
                source_hash = source_hash * 16777619 + cell_load_byte(g_source, source_pos)
                source_pos = source_pos + 1
        g_ir_source_hash = source_hash
        g_ir_source_hash_ready = 1
    h : ., mut = g_ir_source_hash
    // Walk the body AST and hash node kinds + values
    // For a simple first pass: hash the function's token stream range
    start_line := ast_line(func_node)
    start_col := ast_col(func_node)
    // Use g_line/position info to hash source bytes for this function
    // For now: simple hash of function name + param count + body node
    h = h * 16777619 + (ast_kind(func_node) % 256)
    h = h * 16777619 + (ast_a(func_node) % 256)   // name_ni
    h = h * 16777619 + (ast_c(func_node) % 256)   // param count
    if body >= 0:
        h = h * 16777619 + (ast_kind(body) % 256)
    return h

// Compute function signature fingerprint: hash of name + param types + return type.
// Used to detect when callers need recompilation.
fn sig_fingerprint(func_node: int) -> int:
    h : ., mut = 2166136261
    // Name
    name_ni := ast_a(func_node)
    name := istr_get(name_ni)
    ni : ., mut = 0
    loop:
        if ni >= str_len(name):
            break
        h = h * 16777619 + (cell_load_byte(name, ni) % 256)
        ni = ni + 1
    // Param types
    param : ., mut = ast_b(func_node)
    param_count := ast_c(func_node)
    pi : ., mut = 0
    loop:
        if pi >= param_count:
            break
        pt := ast_type_val(param)
        h = h * 16777619 + (pt % 256)
        pi = pi + 1
        param = param + 1
    // Return type
    ret_type := ast_type_val(func_node)
    h = h * 16777619 + (ret_type % 256)
    return h
