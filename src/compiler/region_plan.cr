// === region_plan.cr ===
// V2.0 split plan. Phase A generates v1 IR and runs PointerAnalysis/RegionCheck;
// this pass marks SG_IFs whose direct allocations cannot leave the IF. Phase B
// regenerates the IR and emits a child arena for each marked IF.
//
// The plan is a compile-time table keyed by SG index. It is not serialized and
// is not part of the .ccr contract.

g_plan_split : string, mut
g_plan_split_count : int, mut
g_plan_split_cap : int, mut
g_plan_clear_label : string, mut
g_plan_clear_sg : string, mut
g_plan_clear_count : int, mut
g_plan_clear_cap : int, mut
g_plan_merge : string, mut
g_plan_merge_kind : string, mut
g_plan_merge_name : string, mut
g_plan_merge_str1 : string, mut
g_plan_merge_str2 : string, mut
g_plan_merge_count : int, mut
g_plan_merge_cap : int, mut
g_plan_share : string, mut
g_plan_share_exit : string, mut
g_plan_share_mode : string, mut
g_plan_share_own_event : string, mut
g_plan_share_own_point : string, mut
g_plan_share_reset_mode : string, mut
g_plan_share_reset_label : string, mut
g_plan_share_reset_event : string, mut
g_plan_share_after : string, mut
g_plan_share_cow : string, mut
g_plan_share_dest : string, mut
g_plan_share_len : string, mut
g_plan_share_elem : string, mut
g_plan_share_count : int, mut
g_plan_share_cap : int, mut
g_plan_share_reset_emitted : int, mut
g_rp_share_consumer : int, mut
g_rp_share_exit : int, mut
g_rp_share_mode : int, mut
g_rp_share_reset_node : int, mut
g_rp_share_cow : int, mut
g_rp_share_dest : int, mut
g_rp_share_len : int, mut
g_rp_share_elem : int, mut
// Kind/name of the last eligible merge: 0=array, 1=struct, 2=tuple.
g_rp_merge_kind : int, mut
g_rp_merge_name : int, mut
g_rp_merge_str1 : int, mut
g_rp_merge_str2 : int, mut
g_rp_merge_len : int, mut
// Per-function transitive call-graph hazard bits:
// 1 = unsafe region, 2 = g_current_arena read/write, 4 = arena/spawn/yield/
// unknown call, 8 = heap/array/field/pointer store.
g_share_bad : string, mut
g_plan_active : int, mut
// Post-dominator sets for the current function (bitset rows, 63 lanes).
g_rp_pdom : string, mut
g_rp_common : string, mut
g_rp_pdom_words : int, mut
g_rp_pdom_nstart : int, mut
g_rp_pdom_ncount : int, mut
g_rp_pdom_ok : int, mut
// Control-flow lazy plan: AST call node ids that may be deferred to their
// unique force point. Keyed by AST node (stable across Phase B).
g_lazy_plan_nodes : string, mut
g_lazy_plan_count : int, mut
g_lazy_plan_cap : int, mut
// IR call instruction index -> AST call node id, filled during ir_gen.
g_lazy_call_ast : string, mut
g_lazy_call_ast_cap : int, mut
// Phase B deferred calls: var -> callee/return type/emitted.
g_lazy_def_var : string, mut
g_lazy_def_func : string, mut
g_lazy_def_ti : string, mut
g_lazy_def_args : string, mut
g_lazy_def_argc : string, mut
g_lazy_def_done : string, mut
g_lazy_def_kind : string, mut
g_lazy_def_memo : string, mut
g_lazy_def_count : int, mut
g_lazy_def_cap : int, mut
// Loop-invariant memo plan: call AST -> loop SG/function/return type/args.
g_lazy_memo_ast : string, mut
g_lazy_memo_sg : string, mut
g_lazy_memo_func : string, mut
g_lazy_memo_ti : string, mut
g_lazy_memo_arg0 : string, mut
g_lazy_memo_argc : string, mut
// 0 = loop-invariant hoist (preheader init), 1 = site memo (init at call).
g_lazy_memo_kind : string, mut
g_lazy_memo_count : int, mut
g_lazy_memo_cap : int, mut
// Phase B runtime vars for memo entries (indexed by memo entry).
g_lazy_memo_var : string, mut
g_lazy_memo_flag : string, mut

fn lazy_memo_grow(n: int):
    if n <= g_lazy_memo_cap:
        return
    nc : ., mut = g_lazy_memo_cap * 2
    if nc < 32:
        nc = 32
    loop:
        if nc >= n:
            break
        nc = nc * 2
    na := alloc(nc * 8)
    ns := alloc(nc * 8)
    nf := alloc(nc * 8)
    nt := alloc(nc * 8)
    n0 := alloc(nc * 8)
    nc2 := alloc(nc * 8)
    nv := alloc(nc * 8)
    nfl := alloc(nc * 8)
    nk := alloc(nc * 8)
    if g_lazy_memo_cap > 0:
        cell_copy(g_lazy_memo_ast, g_lazy_memo_cap * 8, na)
        cell_copy(g_lazy_memo_sg, g_lazy_memo_cap * 8, ns)
        cell_copy(g_lazy_memo_func, g_lazy_memo_cap * 8, nf)
        cell_copy(g_lazy_memo_ti, g_lazy_memo_cap * 8, nt)
        cell_copy(g_lazy_memo_arg0, g_lazy_memo_cap * 8, n0)
        cell_copy(g_lazy_memo_argc, g_lazy_memo_cap * 8, nc2)
        cell_copy(g_lazy_memo_var, g_lazy_memo_cap * 8, nv)
        cell_copy(g_lazy_memo_flag, g_lazy_memo_cap * 8, nfl)
        cell_copy(g_lazy_memo_kind, g_lazy_memo_cap * 8, nk)
    g_lazy_memo_ast = na
    g_lazy_memo_sg = ns
    g_lazy_memo_func = nf
    g_lazy_memo_ti = nt
    g_lazy_memo_arg0 = n0
    g_lazy_memo_argc = nc2
    g_lazy_memo_var = nv
    g_lazy_memo_flag = nfl
    g_lazy_memo_kind = nk
    g_lazy_memo_cap = nc

fn lazy_memo_add(ast: int, sg: int, func_ni: int, ti: int, arg0: int, argc: int, kind: int):
    lazy_memo_grow(g_lazy_memo_count + 1)
    cell_store(g_lazy_memo_ast, g_lazy_memo_count * 8, ast)
    cell_store(g_lazy_memo_sg, g_lazy_memo_count * 8, sg)
    cell_store(g_lazy_memo_func, g_lazy_memo_count * 8, func_ni)
    cell_store(g_lazy_memo_ti, g_lazy_memo_count * 8, ti)
    cell_store(g_lazy_memo_arg0, g_lazy_memo_count * 8, arg0)
    cell_store(g_lazy_memo_argc, g_lazy_memo_count * 8, argc)
    cell_store(g_lazy_memo_kind, g_lazy_memo_count * 8, kind)
    cell_store(g_lazy_memo_var, g_lazy_memo_count * 8, -1)
    cell_store(g_lazy_memo_flag, g_lazy_memo_count * 8, -1)
    g_lazy_memo_count = g_lazy_memo_count + 1

fn lazy_memo_index_of_ast(ast: int) -> int:
    if ast < 0:
        return -1
    mi : ., mut = 0
    loop:
        if mi >= g_lazy_memo_count:
            return -1
        if cell_load(g_lazy_memo_ast, mi * 8) == ast:
            return mi
        mi = mi + 1
    return -1

fn lazy_plan_grow(n: int):
    if n <= g_lazy_plan_cap:
        return
    nc : ., mut = g_lazy_plan_cap * 2
    if nc < 32:
        nc = 32
    loop:
        if nc >= n:
            break
        nc = nc * 2
    nb := alloc(nc * 8)
    li : ., mut = 0
    loop:
        if li >= nc:
            break
        cell_store(nb, li * 8, 0)
        li = li + 1
    if g_lazy_plan_cap > 0:
        cell_copy(g_lazy_plan_nodes, g_lazy_plan_cap * 8, nb)
    g_lazy_plan_nodes = nb
    g_lazy_plan_cap = nc

fn lazy_plan_add(ast_node: int):
    if ast_node < 0:
        return
    lazy_plan_grow(g_lazy_plan_count + 1)
    cell_store(g_lazy_plan_nodes, g_lazy_plan_count * 8, ast_node)
    g_lazy_plan_count = g_lazy_plan_count + 1

fn lazy_plan_has(ast_node: int) -> int:
    if ast_node < 0:
        return 0
    li : ., mut = 0
    loop:
        if li >= g_lazy_plan_count:
            return 0
        if cell_load(g_lazy_plan_nodes, li * 8) == ast_node:
            return 1
        li = li + 1
    return 0

fn lazy_ast_grow(n: int):
    if n <= g_lazy_call_ast_cap:
        return
    nc : ., mut = g_lazy_call_ast_cap * 2
    if nc < 256:
        nc = 256
    loop:
        if nc >= n:
            break
        nc = nc * 2
    nb := alloc(nc * 8)
    if g_lazy_call_ast_cap > 0:
        cell_copy(g_lazy_call_ast, g_lazy_call_ast_cap * 8, nb)
    g_lazy_call_ast = nb
    g_lazy_call_ast_cap = nc

fn lazy_ast_set(instr_idx: int, ast_node: int):
    if instr_idx < 0:
        return
    lazy_ast_grow(instr_idx + 1)
    cell_store(g_lazy_call_ast, instr_idx * 8, ast_node)

fn lazy_ast_get(instr_idx: int) -> int:
    if instr_idx < 0 || instr_idx >= g_lazy_call_ast_cap:
        return -1
    return cell_load(g_lazy_call_ast, instr_idx * 8)

fn lazy_def_grow(n: int):
    if n <= g_lazy_def_cap:
        return
    nc : ., mut = g_lazy_def_cap * 2
    if nc < 32:
        nc = 32
    loop:
        if nc >= n:
            break
        nc = nc * 2
    nv := alloc(nc * 8)
    nf := alloc(nc * 8)
    nt := alloc(nc * 8)
    na := alloc(nc * 8)
    nac := alloc(nc * 8)
    nd := alloc(nc * 8)
    nk := alloc(nc * 8)
    nm := alloc(nc * 8)
    if g_lazy_def_cap > 0:
        cell_copy(g_lazy_def_var, g_lazy_def_cap * 8, nv)
        cell_copy(g_lazy_def_func, g_lazy_def_cap * 8, nf)
        cell_copy(g_lazy_def_ti, g_lazy_def_cap * 8, nt)
        cell_copy(g_lazy_def_args, g_lazy_def_cap * 8, na)
        cell_copy(g_lazy_def_argc, g_lazy_def_cap * 8, nac)
        cell_copy(g_lazy_def_done, g_lazy_def_cap * 8, nd)
        cell_copy(g_lazy_def_kind, g_lazy_def_cap * 8, nk)
        cell_copy(g_lazy_def_memo, g_lazy_def_cap * 8, nm)
    g_lazy_def_var = nv
    g_lazy_def_func = nf
    g_lazy_def_ti = nt
    g_lazy_def_args = na
    g_lazy_def_argc = nac
    g_lazy_def_done = nd
    g_lazy_def_kind = nk
    g_lazy_def_memo = nm
    g_lazy_def_cap = nc

fn lazy_def_add(var: int, func_ni: int, ti: int, args: int, argc: int):
    lazy_def_grow(g_lazy_def_count + 1)
    cell_store(g_lazy_def_var, g_lazy_def_count * 8, var)
    cell_store(g_lazy_def_func, g_lazy_def_count * 8, func_ni)
    cell_store(g_lazy_def_ti, g_lazy_def_count * 8, ti)
    cell_store(g_lazy_def_args, g_lazy_def_count * 8, args)
    cell_store(g_lazy_def_argc, g_lazy_def_count * 8, argc)
    cell_store(g_lazy_def_done, g_lazy_def_count * 8, 0)
    cell_store(g_lazy_def_kind, g_lazy_def_count * 8, 0)
    cell_store(g_lazy_def_memo, g_lazy_def_count * 8, -1)
    g_lazy_def_count = g_lazy_def_count + 1

// Turn `target := <deferred pure call>` into a deferred target definition.
// The call is emitted at target's first force point instead of the LET.
fn lazy_defer_store(src: int, target: int) -> int:
    if src < 0 || target < 0 || rc_is_global_var(target) != 0:
        return -1
    di : ., mut = 0
    loop:
        if di >= g_lazy_def_count:
            return -1
        if cell_load(g_lazy_def_var, di * 8) == src:
            // Memo defs (kind 1) describe a guard, not a call with explicit
            // func/args fields. Copying one as a plain def would emit an empty
            // call for an ordinary assignment like `v = hd`.
            if cell_load(g_lazy_def_kind, di * 8) != 0:
                di = di + 1
                continue
            if cell_load(g_lazy_def_done, di * 8) != 0:
                return -1
            cell_store(g_lazy_def_done, di * 8, 1)
            fn_ni := cell_load(g_lazy_def_func, di * 8)
            ti := cell_load(g_lazy_def_ti, di * 8)
            args := cell_load(g_lazy_def_args, di * 8)
            argc := cell_load(g_lazy_def_argc, di * 8)
            lazy_def_add(target, fn_ni, ti, args, argc)
            irv_set_type(target, ti)
            return ti
        di = di + 1
    return -1

fn lazy_memo_def_add(var: int, memo_idx: int):
    lazy_def_grow(g_lazy_def_count + 1)
    cell_store(g_lazy_def_var, g_lazy_def_count * 8, var)
    cell_store(g_lazy_def_func, g_lazy_def_count * 8, -1)
    cell_store(g_lazy_def_ti, g_lazy_def_count * 8, -1)
    cell_store(g_lazy_def_args, g_lazy_def_count * 8, -1)
    cell_store(g_lazy_def_argc, g_lazy_def_count * 8, 0)
    cell_store(g_lazy_def_done, g_lazy_def_count * 8, 0)
    cell_store(g_lazy_def_kind, g_lazy_def_count * 8, 1)
    cell_store(g_lazy_def_memo, g_lazy_def_count * 8, memo_idx)
    g_lazy_def_count = g_lazy_def_count + 1

fn lazy_memo_index_of_var(var: int) -> int:
    if var < 0:
        return -1
    mi : ., mut = 0
    loop:
        if mi >= g_lazy_memo_count:
            return -1
        if cell_load(g_lazy_memo_var, mi * 8) == var:
            return mi
        mi = mi + 1
    return -1

fn lazy_memo_defer_store(src: int, target: int) -> int:
    if src < 0 || target < 0 || rc_is_global_var(target) != 0:
        return 0
    mi := lazy_memo_index_of_var(src)
    if mi < 0:
        return 0
    lazy_memo_def_add(target, mi)
    return 1

fn lazy_memo_ensure_vars(mi: int) -> int:
    if mi < 0 || mi >= g_lazy_memo_count:
        return 0
    if cell_load(g_lazy_memo_var, mi * 8) >= 0:
        return 1
    memo := new_ir_var("_lazy_memo", cell_load(g_lazy_memo_ti, mi * 8))
    flag := new_ir_var("_lazy_flag", TI_INT)
    cell_store(g_lazy_memo_var, mi * 8, memo)
    cell_store(g_lazy_memo_flag, mi * 8, flag)
    return 1

// Site memo: the flag is reset where the source call stood, so every dynamic
// pass through the call site gets at most one evaluation. Arguments are packed
// there as well, preserving the call's original inputs.
fn lazy_memo_site_begin(mi: int, first_arg: int, ac: int) -> int:
    if lazy_memo_ensure_vars(mi) == 0:
        return 0
    if cell_load(g_lazy_memo_kind, mi * 8) != 1:
        return 0
    arg0 := lazy_pack_args(first_arg, ac)
    cell_store(g_lazy_memo_arg0, mi * 8, arg0)
    flag := cell_load(g_lazy_memo_flag, mi * 8)
    z := new_ir_var("_memo_init", TI_INT)
    emit(IR_CONST, z, 0, 0, 0, TI_INT)
    emit(IR_STORE, -1, flag, z, 0, 0)
    return 1

fn lazy_memo_guard(mi: int, target: int) -> int:
    if mi < 0 || mi >= g_lazy_memo_count:
        return 0
    memo := cell_load(g_lazy_memo_var, mi * 8)
    flag := cell_load(g_lazy_memo_flag, mi * 8)
    if memo < 0 || flag < 0:
        return 0
    z := new_ir_var("_memo_zero", TI_INT)
    emit(IR_CONST, z, 0, 0, 0, TI_INT)
    cond := new_ir_var("_memo_cond", TI_BOOL)
    emit(IR_BINARY, cond, flag, z, OP_EQ, 0)
    body := new_label()
    done := new_label()
    emit_cond_match(cond, done, body)
    emit(IR_LABEL, -1, body, 0, 0, 0)
    emit(IR_CALL, memo,
         cell_load(g_lazy_memo_arg0, mi * 8),
         cell_load(g_lazy_memo_argc, mi * 8),
         cell_load(g_lazy_memo_func, mi * 8),
         cell_load(g_lazy_memo_ti, mi * 8))
    one := new_ir_var("_memo_one", TI_INT)
    emit(IR_CONST, one, 1, 0, 0, TI_INT)
    emit(IR_STORE, -1, flag, one, 0, 0)
    emit(IR_LABEL, -1, done, 0, 0, 0)
    if target >= 0:
        emit(IR_STORE, -1, target, memo, 0, 0)
    return 1

fn lazy_memo_emit_for_sg(sg: int):
    mi : ., mut = 0
    loop:
        if mi >= g_lazy_memo_count:
            return
        if cell_load(g_lazy_memo_sg, mi * 8) == sg:
            if cell_load(g_lazy_memo_kind, mi * 8) == 0:
                if lazy_memo_ensure_vars(mi) != 0:
                    flag := cell_load(g_lazy_memo_flag, mi * 8)
                    z := new_ir_var("_memo_init", TI_INT)
                    emit(IR_CONST, z, 0, 0, 0, TI_INT)
                    emit(IR_STORE, -1, flag, z, 0, 0)
        mi = mi + 1

fn lazy_def_emit(var: int) -> int:
    if var < 0:
        return 0
    di : ., mut = 0
    loop:
        if di >= g_lazy_def_count:
            return 0
        if cell_load(g_lazy_def_var, di * 8) == var:
            if cell_load(g_lazy_def_kind, di * 8) == 1:
                // Memo target: guard at every force site; the runtime flag
                // prevents duplicate calls.
                lazy_memo_guard(cell_load(g_lazy_def_memo, di * 8), var)
                return 1
            if cell_load(g_lazy_def_done, di * 8) == 0:
                cell_store(g_lazy_def_done, di * 8, 1)
                emit(IR_CALL, var,
                     cell_load(g_lazy_def_args, di * 8),
                     cell_load(g_lazy_def_argc, di * 8),
                     cell_load(g_lazy_def_func, di * 8),
                     cell_load(g_lazy_def_ti, di * 8))
                return 1
            return 0
        di = di + 1
    return 0

fn lazy_gen_reset():
    g_lazy_def_count = 0
    mi : ., mut = 0
    loop:
        if mi >= g_lazy_memo_count:
            break
        cell_store(g_lazy_memo_var, mi * 8, -1)
        cell_store(g_lazy_memo_flag, mi * 8, -1)
        mi = mi + 1
    g_lazy_call_ast_cap = 0
    g_lazy_call_ast = ""

fn region_plan_grow(n: int):
    if n < g_plan_split_cap:
        return
    nc : ., mut = g_plan_split_cap * 2
    if nc < 16:
        nc = 16
    loop:
        if nc > n:
            break
        nc = nc * 2
    nb := alloc(nc * 8)
    i : ., mut = 0
    loop:
        if i >= nc:
            break
        cell_store(nb, i * 8, 0)
        i = i + 1
    if g_plan_split_cap > 0:
        cell_copy(g_plan_split, g_plan_split_cap * 8, nb)
    g_plan_split = nb
    g_plan_split_cap = nc

fn region_plan_reset():
    g_plan_active = 0
    g_rp_pdom_ok = 0
    g_lazy_plan_count = 0
    if g_lazy_plan_cap > 0:
        li : ., mut = 0
        loop:
            if li >= g_lazy_plan_cap:
                break
            cell_store(g_lazy_plan_nodes, li * 8, 0)
            li = li + 1
    g_lazy_def_count = 0
    g_lazy_memo_count = 0
    g_plan_share_reset_emitted = 0
    g_rp_share_consumer = -1
    g_rp_share_exit = -1
    g_rp_share_mode = -1
    g_rp_share_reset_node = -1
    g_rp_share_cow = 0
    g_rp_share_dest = -1
    g_rp_share_len = 0
    g_rp_share_elem = -1
    g_rp_merge_kind = -1
    g_rp_merge_name = -1
    g_rp_merge_str1 = -1
    g_rp_merge_str2 = -1
    g_rp_merge_len = -1
    g_share_bad = ""
    // A string global starts null; cap is the allocated-size witness. Each
    // table is cleared independently: merge/share can be allocated without a
    // split table in the same process.
    if g_plan_split_cap > 0:
        i : ., mut = 0
        loop:
            if i >= g_plan_split_cap:
                break
            cell_store(g_plan_split, i * 8, 0)
            i = i + 1
    g_plan_split_count = 0
    g_plan_clear_count = 0
    if g_plan_merge_cap > 0:
        i : ., mut = 0
        loop:
            if i >= g_plan_merge_cap:
                break
            cell_store(g_plan_merge, i * 8, 0)
            cell_store(g_plan_merge_kind, i * 8, -1)
            cell_store(g_plan_merge_name, i * 8, -1)
            cell_store(g_plan_merge_str1, i * 8, -1)
            cell_store(g_plan_merge_str2, i * 8, -1)
            i = i + 1
    g_plan_merge_count = 0
    if g_plan_share_cap > 0:
        i : ., mut = 0
        loop:
            if i >= g_plan_share_cap:
                break
            cell_store(g_plan_share, i * 8, 0)
            cell_store(g_plan_share_exit, i * 8, -1)
            cell_store(g_plan_share_mode, i * 8, -1)
            cell_store(g_plan_share_own_event, i * 8, -1)
            cell_store(g_plan_share_own_point, i * 8, -1)
            cell_store(g_plan_share_reset_mode, i * 8, -1)
            cell_store(g_plan_share_reset_label, i * 8, -1)
            cell_store(g_plan_share_reset_event, i * 8, -1)
            cell_store(g_plan_share_after, i * 8, 0)
            cell_store(g_plan_share_cow, i * 8, 0)
            cell_store(g_plan_share_dest, i * 8, -1)
            cell_store(g_plan_share_len, i * 8, 0)
            cell_store(g_plan_share_elem, i * 8, -1)
            i = i + 1
    g_plan_share_count = 0

fn region_plan_mark_split(sg: int):
    if sg < 0:
        return
    region_plan_grow(sg + 1)
    if cell_load(g_plan_split, sg * 8) == 0:
        cell_store(g_plan_split, sg * 8, 1)
        g_plan_split_count = g_plan_split_count + 1

fn region_plan_grow_merge(n: int):
    if n <= g_plan_merge_cap:
        return
    nc : ., mut = g_plan_merge_cap * 2
    if nc < g_sg_count + 16:
        nc = g_sg_count + 16
    loop:
        if nc >= n:
            break
        nc = nc * 2
    nb := alloc(nc * 8)
    nk := alloc(nc * 8)
    nn := alloc(nc * 8)
    ns1 := alloc(nc * 8)
    ns2 := alloc(nc * 8)
    i : ., mut = 0
    loop:
        if i >= nc:
            break
        cell_store(nb, i * 8, 0)
        cell_store(nk, i * 8, -1)
        cell_store(nn, i * 8, -1)
        cell_store(ns1, i * 8, -1)
        cell_store(ns2, i * 8, -1)
        i = i + 1
    if g_plan_merge_cap > 0:
        cell_copy(g_plan_merge, g_plan_merge_cap * 8, nb)
        cell_copy(g_plan_merge_kind, g_plan_merge_cap * 8, nk)
        cell_copy(g_plan_merge_name, g_plan_merge_cap * 8, nn)
        cell_copy(g_plan_merge_str1, g_plan_merge_cap * 8, ns1)
        cell_copy(g_plan_merge_str2, g_plan_merge_cap * 8, ns2)
    g_plan_merge = nb
    g_plan_merge_kind = nk
    g_plan_merge_name = nn
    g_plan_merge_str1 = ns1
    g_plan_merge_str2 = ns2
    g_plan_merge_cap = nc

fn region_plan_mark_merge(sg: int, kind: int, elem_count: int, name: int,
                          str1: int, str2: int):
    if sg < 0 || elem_count < 0 || kind < 0:
        return
    region_plan_grow_merge(sg + 1)
    if cell_load(g_plan_merge, sg * 8) == 0:
        // Store count+1 so a zero-length array is distinguishable from an
        // unplanned slot.
        cell_store(g_plan_merge, sg * 8, elem_count + 1)
        cell_store(g_plan_merge_kind, sg * 8, kind)
        cell_store(g_plan_merge_name, sg * 8, name)
        cell_store(g_plan_merge_str1, sg * 8, str1)
        cell_store(g_plan_merge_str2, sg * 8, str2)
        g_plan_merge_count = g_plan_merge_count + 1

fn region_plan_is_merge(sg: int) -> int:
    if sg < 0 || g_plan_merge_count <= 0 || sg >= g_plan_merge_cap:
        return 0
    return cell_load(g_plan_merge, sg * 8)

// Element/field count of the parent copy for a merge IF.
fn region_plan_merge_len(sg: int) -> int:
    v := region_plan_is_merge(sg)
    if v <= 0:
        return 0
    return v - 1

fn region_plan_merge_kind_of(sg: int) -> int:
    if region_plan_is_merge(sg) == 0 || sg >= g_plan_merge_cap:
        return -1
    return cell_load(g_plan_merge_kind, sg * 8)

fn region_plan_merge_name_of(sg: int) -> int:
    if region_plan_is_merge(sg) == 0 || sg >= g_plan_merge_cap:
        return -1
    return cell_load(g_plan_merge_name, sg * 8)

fn region_plan_merge_str1_of(sg: int) -> int:
    if region_plan_is_merge(sg) == 0 || sg >= g_plan_merge_cap:
        return -1
    return cell_load(g_plan_merge_str1, sg * 8)

fn region_plan_merge_str2_of(sg: int) -> int:
    if region_plan_is_merge(sg) == 0 || sg >= g_plan_merge_cap:
        return -1
    return cell_load(g_plan_merge_str2, sg * 8)

fn region_plan_grow_share(n: int):
    if n <= g_plan_share_cap:
        return
    nc : ., mut = g_plan_share_cap * 2
    if nc < g_sg_count + 16:
        nc = g_sg_count + 16
    loop:
        if nc >= n:
            break
        nc = nc * 2
    nb := alloc(nc * 8)
    ne := alloc(nc * 8)
    nm := alloc(nc * 8)
    noe := alloc(nc * 8)
    nop := alloc(nc * 8)
    nrm := alloc(nc * 8)
    nrl := alloc(nc * 8)
    nre := alloc(nc * 8)
    na := alloc(nc * 8)
    ncw := alloc(nc * 8)
    nd := alloc(nc * 8)
    nl := alloc(nc * 8)
    nel := alloc(nc * 8)
    i : ., mut = 0
    loop:
        if i >= nc:
            break
        cell_store(nb, i * 8, 0)
        cell_store(ne, i * 8, -1)
        cell_store(nm, i * 8, -1)
        cell_store(noe, i * 8, -1)
        cell_store(nop, i * 8, -1)
        cell_store(nrm, i * 8, -1)
        cell_store(nrl, i * 8, -1)
        cell_store(nre, i * 8, -1)
        cell_store(na, i * 8, 0)
        cell_store(ncw, i * 8, 0)
        cell_store(nd, i * 8, -1)
        cell_store(nl, i * 8, 0)
        cell_store(nel, i * 8, -1)
        i = i + 1
    if g_plan_share_cap > 0:
        cell_copy(g_plan_share, g_plan_share_cap * 8, nb)
        cell_copy(g_plan_share_exit, g_plan_share_cap * 8, ne)
        cell_copy(g_plan_share_mode, g_plan_share_cap * 8, nm)
        cell_copy(g_plan_share_own_event, g_plan_share_cap * 8, noe)
        cell_copy(g_plan_share_own_point, g_plan_share_cap * 8, nop)
        cell_copy(g_plan_share_reset_mode, g_plan_share_cap * 8, nrm)
        cell_copy(g_plan_share_reset_label, g_plan_share_cap * 8, nrl)
        cell_copy(g_plan_share_reset_event, g_plan_share_cap * 8, nre)
        cell_copy(g_plan_share_after, g_plan_share_cap * 8, na)
        cell_copy(g_plan_share_cow, g_plan_share_cap * 8, ncw)
        cell_copy(g_plan_share_dest, g_plan_share_cap * 8, nd)
        cell_copy(g_plan_share_len, g_plan_share_cap * 8, nl)
        cell_copy(g_plan_share_elem, g_plan_share_cap * 8, nel)
    g_plan_share = nb
    g_plan_share_exit = ne
    g_plan_share_mode = nm
    g_plan_share_own_event = noe
    g_plan_share_own_point = nop
    g_plan_share_reset_mode = nrm
    g_plan_share_reset_label = nrl
    g_plan_share_reset_event = nre
    g_plan_share_after = na
    g_plan_share_cow = ncw
    g_plan_share_dest = nd
    g_plan_share_len = nl
    g_plan_share_elem = nel
    g_plan_share_cap = nc

fn region_plan_unmark_merge(sg: int):
    if sg < 0 || g_plan_merge_count <= 0 || sg >= g_plan_merge_cap:
        return
    if cell_load(g_plan_merge, sg * 8) != 0:
        cell_store(g_plan_merge, sg * 8, 0)
        g_plan_merge_count = g_plan_merge_count - 1

fn region_plan_mark_share(sg: int, exit_label: int, mode: int, event: int, own_point: int):
    if sg < 0 || exit_label < 0 || own_point < 0:
        return
    n : ., mut = sg + 1
    if event + 1 > n:
        n = event + 1
    region_plan_grow_share(n)
    if event >= g_plan_share_cap:
        return
    if cell_load(g_plan_share, sg * 8) == 0:
        cell_store(g_plan_share, sg * 8, 1)
        cell_store(g_plan_share_exit, sg * 8, exit_label)
        cell_store(g_plan_share_mode, sg * 8, mode)
        cell_store(g_plan_share_own_event, sg * 8, event)
        cell_store(g_plan_share_own_point, sg * 8, own_point)
        cell_store(g_plan_share_reset_mode, sg * 8, mode)
        cell_store(g_plan_share_reset_label, sg * 8, exit_label)
        cell_store(g_plan_share_reset_event, sg * 8, event)
        cell_store(g_plan_share_cow, sg * 8, g_rp_share_cow)
        cell_store(g_plan_share_dest, sg * 8, g_rp_share_dest)
        cell_store(g_plan_share_len, sg * 8, g_rp_share_len)
        cell_store(g_plan_share_elem, sg * 8, g_rp_share_elem)
        g_plan_share_count = g_plan_share_count + 1

fn region_plan_is_share(sg: int) -> int:
    if sg < 0 || g_plan_share_count <= 0 || sg >= g_plan_share_cap:
        return 0
    return cell_load(g_plan_share, sg * 8)

// Lifetime exit for a share slot: the last consumer's exit label id.
fn region_plan_share_exit(sg: int) -> int:
    if region_plan_is_share(sg) == 0:
        return -1
    return cell_load(g_plan_share_exit, sg * 8)

fn region_plan_share_mode_of(sg: int) -> int:
    if region_plan_is_share(sg) == 0:
        return -1
    return cell_load(g_plan_share_mode, sg * 8)

// Mode-1 share whose reset is emitted at this label (or -1).
fn region_plan_share_for_label(lbl: int) -> int:
    if lbl < 0 || g_plan_share_count <= 0:
        return -1
    s : ., mut = 0
    loop:
        if s >= g_plan_share_cap:
            return -1
        if region_plan_is_share(s) != 0:
            if cell_load(g_plan_share_mode, s * 8) == 1 && cell_load(g_plan_share_exit, s * 8) == lbl:
                return s
        s = s + 1
    return -1

// Consumer SG -> share owner SG (or -1). The owner's reset is emitted after
// the consumer's own arena reset.
fn region_plan_share_cow(sg: int) -> int:
    if region_plan_is_share(sg) == 0 || sg >= g_plan_share_cap:
        return 0
    return cell_load(g_plan_share_cow, sg * 8)

fn region_plan_share_dest(sg: int) -> int:
    if region_plan_is_share(sg) == 0 || sg >= g_plan_share_cap:
        return -1
    return cell_load(g_plan_share_dest, sg * 8)

fn region_plan_share_len(sg: int) -> int:
    if region_plan_is_share(sg) == 0 || sg >= g_plan_share_cap:
        return 0
    return cell_load(g_plan_share_len, sg * 8)

fn region_plan_share_elem(sg: int) -> int:
    if region_plan_is_share(sg) == 0 || sg >= g_plan_share_cap:
        return -1
    return cell_load(g_plan_share_elem, sg * 8)

fn region_plan_share_after(cg: int) -> int:
    if cg < 0 || g_plan_share_count <= 0 || cg >= g_plan_share_cap:
        return -1
    v := cell_load(g_plan_share_after, cg * 8)
    if v <= 0:
        return -1
    return v - 1

fn region_plan_is_split(sg: int) -> int:
    if sg < 0:
        return 0
    if g_plan_split_count <= 0:
        return 0
    if sg >= g_plan_split_cap:
        return 0
    return cell_load(g_plan_split, sg * 8)

fn region_plan_has_split() -> int:
    if g_plan_split_count > 0:
        return 1
    return 0

fn region_plan_grow_clear(n: int):
    if n < g_plan_clear_cap:
        return
    nc : ., mut = g_plan_clear_cap * 2
    if nc < 16:
        nc = 16
    loop:
        if nc > n:
            break
        nc = nc * 2
    nb := alloc(nc * 8)
    nb2 := alloc(nc * 8)
    i : ., mut = 0
    loop:
        if i >= nc:
            break
        cell_store(nb, i * 8, 0)
        cell_store(nb2, i * 8, 0)
        i = i + 1
    if g_plan_clear_cap > 0:
        cell_copy(g_plan_clear_label, g_plan_clear_cap * 8, nb)
        cell_copy(g_plan_clear_sg, g_plan_clear_cap * 8, nb2)
    g_plan_clear_label = nb
    g_plan_clear_sg = nb2
    g_plan_clear_cap = nc

fn region_plan_mark_clear(label_id: int, sg: int):
    if label_id < 0 || sg < 0:
        return
    i : ., mut = 0
    loop:
        if i >= g_plan_clear_count:
            break
        if cell_load(g_plan_clear_label, i * 8) == label_id && cell_load(g_plan_clear_sg, i * 8) == sg:
            return
        i = i + 1
    region_plan_grow_clear(g_plan_clear_count + 1)
    cell_store(g_plan_clear_label, g_plan_clear_count * 8, label_id)
    cell_store(g_plan_clear_sg, g_plan_clear_count * 8, sg)
    g_plan_clear_count = g_plan_clear_count + 1

fn region_plan_has_clear() -> int:
    if g_plan_clear_count > 0:
        return 1
    return 0

fn region_plan_has_plan() -> int:
    if g_lazy_plan_count > 0 || g_lazy_memo_count > 0:
        return 1
    if g_plan_split_count > 0 || g_plan_clear_count > 0 || g_plan_merge_count > 0 || g_plan_share_count > 0:
        return 1
    return 0

// Called from df_create_node for every IR_LABEL during Phase B. Emits the
// planned early clears after the label. The clear node itself is not a label,
// so this cannot recurse.
fn region_plan_emit_clears(label_id: int):
    if g_plan_clear_count <= 0:
        return
    i : ., mut = 0
    loop:
        if i >= g_plan_clear_count:
            return
        if cell_load(g_plan_clear_label, i * 8) == label_id:
            sg := cell_load(g_plan_clear_sg, i * 8)
            if sg >= 0 && sg < g_sg_arena_var_cap && sg < g_sg_count:
                k := cell_load(g_sgs, sg * ESZ_SG + OFF_SG_KIND)
                if k == SG_FUNC || k == SG_LOOP || k == SG_FOR || k == SG_UNSAFE:
                    slot := cell_load(g_sg_arena_var, sg * 8)
                    if slot >= 0:
                        emit(IR_ARENA_CLEAR, -1, slot, 0, 0, 0)
        i = i + 1

fn rp_var_is_pointer(var: int) -> int:
    if var < 0:
        return 0
    ti := irv_type(var)
    if ti < 0 || ti >= g_type_count:
        return 0
    k := get_type_kind(ti)
    if k == TYP_PTR || k == TYP_REF:
        return 1
    return 0

// A stack slot can carry a points-to set even when its IR type row is TI_UNIT
// (the slot's declared type lives on the variable, not the alloc node). Any
// non-empty pts set is therefore a pointer carrier for escape/liveness scans.
fn rp_var_may_point(var: int) -> int:
    if var < 0:
        return 0
    if pa_pts_empty(var) == 0:
        return 1
    return rp_var_is_pointer(var)

fn rp_slot_inside(slot: int, sg: int) -> int:
    if slot < 0 || rc_is_global_var(slot) != 0:
        return 0
    prod := cell_load(g_df_var_producer, slot * 8)
    if prod < 0:
        return 0
    return rc_sg_is_ancestor(sg, subgraph_containing(prod))

// A local slot whose address is taken can be read after the IF through an
// alias; storing a split pointer into it is an escape even when the slot itself
// is declared inside the IF.
fn rp_slot_addr_taken(slot: int, nstart: int, ncount: int) -> int:
    if slot < 0:
        return 0
    ni : ., mut = nstart
    loop:
        if ni >= nstart + ncount:
            return 0
        op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
        s1 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)
        if op == IR_REF && s1 == slot:
            return 1
        ni = ni + 1

// Is the storage reached by `ptr_var` declared inside `sg`? Used for stores of
// split allocation pointers into outer slots.
fn rp_target_inside(ptr_var: int, at_node: int, sg: int, nstart: int, ncount: int, depth: int) -> int:
    if ptr_var < 0 || depth > RC_MAX_DEPTH:
        return 0
    if rc_is_global_var(ptr_var) != 0:
        return 0
    if pa_pts_empty(ptr_var) == 0:
        saw : ., mut = 0
        ai : ., mut = 0
        loop:
            if ai >= g_pa_alloc_count:
                return saw
            if pa_pts_has(ptr_var, ai) != 0:
                saw = 1
                an := cell_load(g_pa_alloc_nodes, ai * 8)
                if rc_sg_is_ancestor(sg, subgraph_containing(an)) == 0:
                    return 0
            ai = ai + 1
        return saw
    prod := cell_load(g_df_var_producer, ptr_var * 8)
    if prod < 0:
        return 0
    op := cell_load(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_OPCODE)
    s1 := cell_load(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_S1)
    s2 := cell_load(g_df_nodes, prod * ESZ_DFNODE + OFF_DF_S2)
    if op == IR_REF:
        if rp_slot_inside(s1, sg) == 0:
            return 0
        if rp_slot_addr_taken(s1, nstart, ncount) != 0:
            return 0
        return 1
    if op == IR_PHI:
        if s1 < 0 || rp_target_inside(s1, prod, sg, nstart, ncount, depth + 1) == 0:
            return 0
        if s2 < 0 || rp_target_inside(s2, prod, sg, nstart, ncount, depth + 1) == 0:
            return 0
        return 1
    if op == IR_LAZY_THUNK || op == IR_LAZY_FORCE:
        if s1 >= 0:
            return rp_target_inside(s1, prod, sg, nstart, ncount, depth + 1)
    return 0

fn rp_if_has_unsafe(sg_start: int, sg_count: int) -> int:
    ni : ., mut = sg_start
    loop:
        if ni >= sg_start + sg_count:
            return 0
        if is_in_unsafe(ni) != 0:
            return 1
        ni = ni + 1

fn rp_label_inside(target: int, sg_start: int, sg_count: int) -> int:
    if target < 0:
        return 0
    if target >= sg_start && target < sg_start + sg_count:
        return 1
    return 0

// Non-local exit or an opaque effect: return, calls, spawn/await, address
// observation, or a jump/match target outside the IF. Conservative on purpose.
fn rp_if_has_exit_or_effect(sg_start: int, sg_count: int) -> int:
    ni : ., mut = sg_start
    loop:
        if ni >= sg_start + sg_count:
            return 0
        op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
        s1 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)
        if op == IR_RETURN || op == IR_CALL || op == IR_CALL_EXTERN || op == IR_SPAWN || op == IR_YIELD || op == IR_AWAIT || op == IR_PTR_OF || op == IR_STR_OF:
            return 1
        if op == IR_JUMP:
            t := rc_ctl_label_node(s1)
            if rp_label_inside(t, sg_start, sg_count) == 0:
                return 1
        ni = ni + 1

fn rp_alloc_escapes(alloc_id: int, sg: int, nstart: int, ncount: int,
                    sg_start: int, sg_count: int) -> int:
    an := cell_load(g_pa_alloc_nodes, alloc_id * 8)
    ni : ., mut = nstart
    loop:
        if ni >= nstart + ncount:
            return 0
        op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
        d  := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_DEST)
        s1 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)
        s2 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S2)
        s3 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S3)
        uses_alloc : ., mut = 0
        if s1 >= 0 && rp_var_may_point(s1) != 0 && pa_pts_has(s1, alloc_id) != 0:
            uses_alloc = 1
        if s2 >= 0 && rp_var_may_point(s2) != 0 && pa_pts_has(s2, alloc_id) != 0:
            uses_alloc = 1
        if s3 >= 0 && rp_var_may_point(s3) != 0 && pa_pts_has(s3, alloc_id) != 0:
            uses_alloc = 1
        if d >= 0 && rp_var_may_point(d) != 0 && op == IR_STORE_INDEX_VAR && pa_pts_has(d, alloc_id) != 0:
            uses_alloc = 1
        if uses_alloc != 0 && ni != an:
            nsg := subgraph_containing(ni)
            if rc_sg_is_ancestor(sg, nsg) == 0:
                return 1
            if op == IR_STORE_PTR && s2 >= 0 && pa_pts_has(s2, alloc_id) != 0:
                if rp_target_inside(s1, ni, sg, nstart, ncount, 0) == 0:
                    return 1
            if op == IR_STORE && s2 >= 0 && pa_pts_has(s2, alloc_id) != 0:
                if rp_slot_inside(s1, sg) == 0:
                    return 1
                if rp_slot_addr_taken(s1, nstart, ncount) != 0:
                    return 1
            if op == IR_STORE_INDEX && s2 >= 0 && pa_pts_has(s2, alloc_id) != 0:
                if rp_target_inside(s1, ni, sg, nstart, ncount, 0) == 0:
                    return 1
            if op == IR_STORE_FIELD && s2 >= 0 && pa_pts_has(s2, alloc_id) != 0:
                if rp_target_inside(s1, ni, sg, nstart, ncount, 0) == 0:
                    return 1
            if op == IR_STORE_INDEX_VAR && d >= 0 && pa_pts_has(d, alloc_id) != 0:
                if rp_target_inside(s1, ni, sg, nstart, ncount, 0) == 0:
                    return 1
        ni = ni + 1

// True when the allocation is owned by a nested releasing region (loop, for,
// unsafe, or an already planned split/merge IF). Such an allocation never lands
// in the current IF's arena and its lifetime is handled by that region.
fn rp_alloc_has_nested_release(an: int, sg: int) -> int:
    csg : ., mut = subgraph_containing(an)
    loop:
        if csg < 0 || csg == sg:
            return 0
        if rc_sg_releases(csg) != 0:
            return 1
        csg = cell_load(g_sgs, csg * ESZ_SG + OFF_SG_PARENT)
    return 0

// Returns 1 when the IF has at least one direct allocation and every allocation
// that lands in its arena stays inside.
fn rp_if_eligible(sg: int, sg_start: int, sg_count: int,
                  nstart: int, ncount: int) -> int:
    found : ., mut = 0
    ai : ., mut = 0
    loop:
        if ai >= g_pa_alloc_count:
            return found
        an := cell_load(g_pa_alloc_nodes, ai * 8)
        aop := cell_load(g_df_nodes, an * ESZ_DFNODE + OFF_DF_OPCODE)
        if aop == IR_ALLOC_ARRAY || aop == IR_ALLOC_STRUCT:
            csg := subgraph_containing(an)
            if csg == sg:
                found = 1
            // Nested non-releasing allocations land in this IF's arena too, so
            // they must not escape this IF. A nested release owns its bytes.
            if csg == sg || rc_sg_is_ancestor(sg, csg) != 0:
                if rp_alloc_has_nested_release(an, sg) == 0:
                    if rp_alloc_escapes(ai, sg, nstart, ncount, sg_start, sg_count) != 0:
                        return 0
        ai = ai + 1
    return found

fn rp_global_var_named(name: string) -> int:
    gi : ., mut = 0
    loop:
        if gi >= g_ir_global_count:
            return -1
        if str_eq(istr_get(cell_load(g_ir_globals, gi * 24)), name) != 0:
            return cell_load(g_ir_globals, gi * 24 + 8)
        gi = gi + 1
    return -1

fn rp_if_reads_var(sg_start: int, sg_count: int, var: int) -> int:
    if var < 0:
        return 0
    ni : ., mut = sg_start
    loop:
        if ni >= sg_start + sg_count:
            return 0
        op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
        s1 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)
        s2 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S2)
        s3 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S3)
        d := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_DEST)
        // Literal-only fields (values, labels, type tags) must not be treated
        // as variable slots: CASE bases in particular can collide with var ids.
        literal_only : ., mut = 0
        if op == IR_CONST || op == IR_CONST_BIG || op == IR_LABEL || op == IR_JUMP || op == IR_ALLOC || op == IR_ALLOC_ARRAY || op == IR_ALLOC_STRUCT || op == IR_ALLOC_AT || op == IR_BOUNDS_CHECK:
            literal_only = 1
        if literal_only == 0:
            if op == IR_MATCH:
                if s1 == var:
                    return 1
            else if op == IR_BINARY:
                if s1 == var || s2 == var:
                    return 1
            else if op == IR_UNARY:
                if s1 == var:
                    return 1
            else if op == IR_LOAD_INDEX:
                if s1 == var:
                    return 1
            else if op == IR_LOAD_INDEX_VAR:
                if s1 == var || s2 == var:
                    return 1
            else if op == IR_STORE_INDEX:
                if s1 == var || s2 == var:
                    return 1
            else if op == IR_STORE_INDEX_VAR:
                if d == var || s1 == var || s2 == var:
                    return 1
            else if op == IR_STORE:
                if s1 == var || s2 == var:
                    return 1
            else:
                if s1 == var || s2 == var || s3 == var:
                    return 1
        ni = ni + 1

// Slot owner for an allocation. `rc_releasing_region` returns -1 for
// function-level allocations because a function exit is not a RegionCheck
// release point; early clear still needs the owning SG_FUNC.
fn rp_alloc_slot(an: int) -> int:
    s := rc_releasing_region(an)
    if s >= 0:
        return s
    sg : ., mut = subgraph_containing(an)
    loop:
        if sg < 0:
            return -1
        if cell_load(g_sgs, sg * ESZ_SG + OFF_SG_KIND) == SG_FUNC:
            return sg
        sg = cell_load(g_sgs, sg * ESZ_SG + OFF_SG_PARENT)
    return -1

RP_FULL : int = 9223372036854775807

fn rp_bit_set(buf: string, base: int, bit: int):
    if bit < 0:
        return
    w := bit / 63
    m := pa_bit_mask(bit % 63)
    idx := (base + w) * 8
    cur := cell_load(buf, idx)
    if (cur / m) % 2 == 0:
        cell_store(buf, idx, cur + m)

fn rp_bit_has(buf: string, base: int, bit: int) -> int:
    if bit < 0:
        return 0
    w := bit / 63
    m := pa_bit_mask(bit % 63)
    return (cell_load(buf, (base + w) * 8) / m) % 2

fn rp_bits_clear(buf: string, base: int, words: int):
    w : ., mut = 0
    loop:
        if w >= words:
            return
        cell_store(buf, (base + w) * 8, 0)
        w = w + 1

fn rp_bits_fill(buf: string, base: int, words: int):
    w : ., mut = 0
    loop:
        if w >= words:
            return
        cell_store(buf, (base + w) * 8, RP_FULL)
        w = w + 1

fn rp_bits_and(dst: string, dbase: int, src: string, sbase: int, words: int) -> int:
    changed : ., mut = 0
    w : ., mut = 0
    loop:
        if w >= words:
            return changed
        a := cell_load(dst, (dbase + w) * 8)
        b := cell_load(src, (sbase + w) * 8)
        out : ., mut = 0
        mask : ., mut = 1
        k : ., mut = 0
        loop:
            if k >= 63:
                break
            if (a / mask) % 2 == 1 && (b / mask) % 2 == 1:
                out = out + mask
            mask = mask * 2
            k = k + 1
        if out != a:
            cell_store(dst, (dbase + w) * 8, out)
            changed = 1
        w = w + 1
    return changed

fn rp_bits_copy(dst: string, dbase: int, src: string, sbase: int, words: int):
    w : ., mut = 0
    loop:
        if w >= words:
            return
        cell_store(dst, (dbase + w) * 8, cell_load(src, (sbase + w) * 8))
        w = w + 1

fn rp_bits_same(a: string, abase: int, b: string, bbase: int, words: int) -> int:
    w : ., mut = 0
    loop:
        if w >= words:
            return 1
        if cell_load(a, (abase + w) * 8) != cell_load(b, (bbase + w) * 8):
            return 0
        w = w + 1

// Post-dominators over the HDFG-derived control adjacency. Exits are nodes with
// no successors; pdom[exit] = {exit}. The worklist starts with every node and
// re-enqueues predecessors when a row shrinks. A size/iteration cap keeps the
// pass bounded; exceeding it disables early clear for this function (v1).
fn rp_pdom_prepare(nstart: int, ncount: int):
    if g_rp_pdom_ok != 0 && g_rp_pdom_nstart == nstart && g_rp_pdom_ncount == ncount:
        return
    g_rp_pdom_nstart = nstart
    g_rp_pdom_ncount = ncount
    g_rp_pdom_ok = 0
    if ncount <= 0 || ncount > 8000:
        return
    words : ., mut = (ncount + 62) / 63
    if words < 1:
        words = 1
    g_rp_pdom_words = words
    g_rp_pdom = alloc(ncount * words * 8)
    i : ., mut = 0
    loop:
        if i >= ncount:
            break
        rp_bits_fill(g_rp_pdom, i * words, words)
        i = i + 1
    // Exit rows contain only the exit itself.
    i = 0
    loop:
        if i >= ncount:
            break
        if rc_ctl_succ_count(nstart + i) == 0:
            rp_bits_clear(g_rp_pdom, i * words, words)
            rp_bit_set(g_rp_pdom, i * words, i)
        i = i + 1
    // Predecessor lists.
    edge_total : ., mut = 0
    i = 0
    loop:
        if i >= ncount:
            break
        edge_total = edge_total + rc_ctl_succ_count(nstart + i)
        i = i + 1
    pred_head := alloc(ncount * 8)
    pred_from := alloc((edge_total + 1) * 8)
    pred_next := alloc((edge_total + 1) * 8)
    i = 0
    loop:
        if i >= ncount:
            break
        cell_store(pred_head, i * 8, -1)
        i = i + 1
    e : ., mut = 0
    i = 0
    loop:
        if i >= ncount:
            break
        sc := rc_ctl_succ_count(nstart + i)
        k : ., mut = 0
        loop:
            if k >= sc:
                break
            v := rc_ctl_succ_at(nstart + i, k)
            if v >= nstart && v < nstart + ncount:
                vi := v - nstart
                cell_store(pred_from, e * 8, i)
                cell_store(pred_next, e * 8, cell_load(pred_head, vi * 8))
                cell_store(pred_head, vi * 8, e)
                e = e + 1
            k = k + 1
        i = i + 1
    work := alloc(ncount * 8)
    queued := alloc(ncount * 8)
    i = 0
    loop:
        if i >= ncount:
            break
        cell_store(work, i * 8, i)
        cell_store(queued, i * 8, 1)
        i = i + 1
    top : ., mut = ncount
    temp := alloc(words * 8)
    guard : ., mut = 0
    loop:
        if top <= 0:
            break
        top = top - 1
        u := cell_load(work, top * 8)
        cell_store(queued, u * 8, 0)
        sc := rc_ctl_succ_count(nstart + u)
        if sc <= 0:
            rp_bits_clear(temp, 0, words)
        else:
            rp_bits_fill(temp, 0, words)
            k : ., mut = 0
            loop:
                if k >= sc:
                    break
                v := rc_ctl_succ_at(nstart + u, k)
                if v >= nstart && v < nstart + ncount:
                    rp_bits_and(temp, 0, g_rp_pdom, (v - nstart) * words, words)
                k = k + 1
        rp_bit_set(temp, 0, u - nstart)
        if rp_bits_same(temp, 0, g_rp_pdom, u * words, words) == 0:
            rp_bits_copy(g_rp_pdom, u * words, temp, 0, words)
            pe : ., mut = cell_load(pred_head, u * 8)
            loop:
                if pe < 0:
                    break
                pv := cell_load(pred_from, pe * 8)
                if cell_load(queued, pv * 8) == 0:
                    cell_store(work, top * 8, pv)
                    top = top + 1
                    cell_store(queued, pv * 8, 1)
                pe = cell_load(pred_next, pe * 8)
        guard = guard + 1
        if guard > ncount * 8 + 2000:
            return
    // common[alloc] = intersection of pdom[use] over every use of that alloc.
    if g_pa_alloc_count > 0:
        g_rp_common = alloc(g_pa_alloc_count * words * 8)
        ai : ., mut = 0
        loop:
            if ai >= g_pa_alloc_count:
                break
            rp_bits_fill(g_rp_common, ai * words, words)
            ai = ai + 1
        ni : ., mut = nstart
        loop:
            if ni >= nstart + ncount:
                break
            op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
            s1 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)
            s2 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S2)
            s3 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S3)
            if s1 >= 0 && rp_var_may_point(s1) != 0:
                ai2 : ., mut = 0
                loop:
                    if ai2 >= g_pa_alloc_count:
                        break
                    if pa_pts_has(s1, ai2) != 0 && ni != cell_load(g_pa_alloc_nodes, ai2 * 8):
                        rp_bits_and(g_rp_common, ai2 * words, g_rp_pdom, (ni - nstart) * words, words)
                    ai2 = ai2 + 1
            if s2 >= 0 && rp_var_may_point(s2) != 0:
                ai3 : ., mut = 0
                loop:
                    if ai3 >= g_pa_alloc_count:
                        break
                    if pa_pts_has(s2, ai3) != 0 && ni != cell_load(g_pa_alloc_nodes, ai3 * 8):
                        rp_bits_and(g_rp_common, ai3 * words, g_rp_pdom, (ni - nstart) * words, words)
                    ai3 = ai3 + 1
            if s3 >= 0 && rp_var_may_point(s3) != 0:
                ai4 : ., mut = 0
                loop:
                    if ai4 >= g_pa_alloc_count:
                        break
                    if pa_pts_has(s3, ai4) != 0 && ni != cell_load(g_pa_alloc_nodes, ai4 * 8):
                        rp_bits_and(g_rp_common, ai4 * words, g_rp_pdom, (ni - nstart) * words, words)
                    ai4 = ai4 + 1
            ni = ni + 1
    g_rp_pdom_ok = 1

// No later jump/match may reach a node at or before the clear point. A backedge
// to a use after the clear would make the clear unsound.
fn rp_clear_suffix_safe(qn: int, sg_end: int) -> int:
    ni : ., mut = qn + 1
    loop:
        if ni >= sg_end:
            return 1
        op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
        s1 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)
        s2 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S2)
        s3 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S3)
        if op == IR_JUMP:
            t := rc_ctl_label_node(s1)
            if t >= 0 && t <= qn:
                return 0
        if op == IR_MATCH:
            base := s2
            cnt := s3
            k : ., mut = 0
            loop:
                if k >= cnt:
                    break
                if base >= 0 && base + k < g_lat_case_count:
                    lbl := cell_load_i32(g_lat_case, (base + k) * CCR_V10_CASE_DISK + CCR_CASE_TARGET)
                    t := rc_ctl_label_node(lbl)
                    if t >= 0 && t <= qn:
                        return 0
                k = k + 1
        ni = ni + 1
    return 1

fn rp_same_block_alloc_after(qn: int, sg: int, sg_end: int) -> int:
    ni : ., mut = qn + 1
    loop:
        if ni >= sg_end:
            return 0
        op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
        if op == IR_LABEL || op == IR_JUMP || op == IR_MATCH || op == IR_RETURN:
            return 0
        if op == IR_ALLOC_ARRAY || op == IR_ALLOC_STRUCT:
            if rp_alloc_slot(ni) == sg:
                return 1
        ni = ni + 1

fn rp_prior_uses_pdom(qn: int, sg: int, nstart: int) -> int:
    if g_rp_pdom_ok == 0:
        return 0
    words := g_rp_pdom_words
    ai : ., mut = 0
    loop:
        if ai >= g_pa_alloc_count:
            return 1
        an := cell_load(g_pa_alloc_nodes, ai * 8)
        if an < qn && rp_alloc_slot(an) == sg:
            if rp_bit_has(g_rp_common, ai * words, qn - nstart) == 0:
                return 0
        ai = ai + 1

fn rp_clear_candidate(sg: int, nstart: int, ncount: int, sg_start: int, sg_end: int) -> int:
    qn : ., mut = sg_start
    loop:
        if qn >= sg_end:
            return -1
        op := cell_load(g_df_nodes, qn * ESZ_DFNODE + OFF_DF_OPCODE)
        if op == IR_LABEL:
            before : ., mut = 0
            ai : ., mut = 0
            loop:
                if ai >= g_pa_alloc_count:
                    break
                an := cell_load(g_pa_alloc_nodes, ai * 8)
                aop := cell_load(g_df_nodes, an * ESZ_DFNODE + OFF_DF_OPCODE)
                if rp_alloc_slot(an) == sg && (aop == IR_ALLOC_ARRAY || aop == IR_ALLOC_STRUCT):
                    if an < qn:
                        before = 1
                ai = ai + 1
            if before != 0 && rp_prior_uses_pdom(qn, sg, nstart) != 0:
                if rp_same_block_alloc_after(qn, sg, sg_end) != 0:
                    if rp_clear_suffix_safe(qn, sg_end) != 0:
                        return cell_load(g_df_nodes, qn * ESZ_DFNODE + OFF_DF_S1)
        qn = qn + 1
    return -1

// IR_CALL/IR_SPAWN carry contiguous argument vars starting at s1.
fn rp_call_arg_uses_alloc(s1: int, s2: int, ai_sel: int) -> int:
    if s1 < 0 || s2 <= 0:
        return 0
    ac : ., mut = 0
    loop:
        if ac >= s2:
            return 0
        av := s1 + ac
        if av >= 0 && rp_var_may_point(av) != 0 && pa_pts_has(av, ai_sel) != 0:
            return 1
        ac = ac + 1
    return 0

fn rp_scalar_elem(ti: int) -> int:
    if ti < 0 || ti >= g_type_count:
        return 0
    if get_type_kind(ti) != TYP_BASE:
        return 0
    d := get_type_data(ti)
    if d == TY_INT || d == TY_BOOL || d == TY_CHAR || d == TY_DEX || d == TY_DEX_S:
        return 1
    return 0

// A leaf that can be copied by value: scalar or an owned string. Strings are
// deep-copied with str_sub; arrays/structs would need nested allocation and are
// handled separately.
fn rp_copyable_leaf(ti: int) -> int:
    if rp_scalar_elem(ti) != 0:
        return 1
    if ti >= 0 && ti < g_type_count:
        if get_type_kind(ti) == TYP_BASE && get_type_data(ti) == TY_STRING:
            return 1
    return 0

fn rp_string_ti(ti: int) -> int:
    if ti >= 0 && ti < g_type_count:
        if get_type_kind(ti) == TYP_BASE && get_type_data(ti) == TY_STRING:
            return 1
    return 0

fn rp_if_merge_ancestors_ok(sg: int) -> int:
    p : ., mut = cell_load(g_sgs, sg * ESZ_SG + OFF_SG_PARENT)
    loop:
        if p < 0:
            return 1
        k := cell_load(g_sgs, p * ESZ_SG + OFF_SG_KIND)
        if k == SG_FUNC:
            return 1
        // Identity inside unsafe is observable; no merge there.
        if k == SG_UNSAFE:
            return 0
        p = cell_load(g_sgs, p * ESZ_SG + OFF_SG_PARENT)

// The copy is allocated in the nearest releasing ancestor's arena (loop/for/
// unsafe/planned IF). It may be merged only when the rebound outer slot has no
// use at or after that ancestor's exit, and is not aliased into another
// variable that could outlive the arena.
fn rp_merge_lifetime_ok(sg: int, dest: int, nstart: int, ncount: int) -> int:
    s_end := cell_load(g_sgs, sg * ESZ_SG + OFF_SG_NSTART) + cell_load(g_sgs, sg * ESZ_SG + OFF_SG_NCOUNT)
    p : ., mut = cell_load(g_sgs, sg * ESZ_SG + OFF_SG_PARENT)
    loop:
        if p < 0:
            return 1
        k := cell_load(g_sgs, p * ESZ_SG + OFF_SG_KIND)
        if k == SG_FUNC:
            return 1
        if rc_sg_releases(p) != 0:
            pe := cell_load(g_sgs, p * ESZ_SG + OFF_SG_EXIT)
            ni : ., mut = s_end
            loop:
                if ni >= nstart + ncount:
                    break
                if ni >= pe:
                    if rp_if_reads_var(ni, 1, dest) != 0:
                        return 0
                ni = ni + 1
            // Any alias of the slot could be used after the arena dies.
            ni = s_end
            loop:
                if ni >= nstart + ncount:
                    return 1
                op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
                d := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_DEST)
                s1 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)
                s2 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S2)
                if op == IR_STORE && s2 == dest && s1 != dest:
                    return 0
                if (op == IR_STORE_INDEX || op == IR_STORE_INDEX_VAR || op == IR_STORE_FIELD || op == IR_STORE_PTR) && s2 == dest:
                    return 0
                if op == IR_STORE_INDEX_VAR && d == dest:
                    return 0
                ni = ni + 1
        p = cell_load(g_sgs, p * ESZ_SG + OFF_SG_PARENT)

// True when `var` may point to either selected allocation.
fn rp_sel_pts(var: int, ai1: int, ai2: int) -> int:
    if var < 0 || rp_var_may_point(var) == 0:
        return 0
    if ai1 >= 0 && pa_pts_has(var, ai1) != 0:
        return 1
    if ai2 >= 0 && pa_pts_has(var, ai2) != 0:
        return 1
    return 0

fn rp_call_arg_uses_sel(s1: int, s2: int, ai1: int, ai2: int) -> int:
    if ai1 >= 0 && rp_call_arg_uses_alloc(s1, s2, ai1) != 0:
        return 1
    if ai2 >= 0 && rp_call_arg_uses_alloc(s1, s2, ai2) != 0:
        return 1
    return 0

// 0=array, 1=struct, 2=tuple; -1 when the allocation is not a candidate.
fn rp_merge_alloc_kind(an: int) -> int:
    if an < 0:
        return -1
    op := cell_load(g_df_nodes, an * ESZ_DFNODE + OFF_DF_OPCODE)
    if op == IR_ALLOC_STRUCT:
        return 1
    if op != IR_ALLOC_ARRAY:
        return -1
    ad := cell_load(g_df_nodes, an * ESZ_DFNODE + OFF_DF_DEST)
    ti := irv_type(ad)
    if ti >= 0 && ti < g_type_count && get_type_kind(ti) == TYP_ARRAY:
        return 0
    return 2

// A tuple is POD when every element slot receives a scalar value. The tuple
// type row is not carried by IR_ALLOC_ARRAY, so the stored value types are the
// proof; any array/string/struct/tuple/pointer field rejects the copy.
fn rp_tuple_pod(an: int, cnt: int, sg_start: int, sg_count: int) -> int:
    if an < 0 || cnt <= 0 || cnt > 64:
        return 0
    ad := cell_load(g_df_nodes, an * ESZ_DFNODE + OFF_DF_DEST)
    i : ., mut = 0
    loop:
        if i >= cnt:
            return 1
        found : ., mut = 0
        ni : ., mut = sg_start
        loop:
            if ni >= sg_start + sg_count:
                break
            op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
            s1 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)
            s2 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S2)
            s3 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S3)
            if op == IR_STORE_FIELD && s1 == ad && s3 == i:
                found = 1
                if rp_copyable_leaf(irv_type(s2)) == 0:
                    return 0
            ni = ni + 1
        if found == 0:
            return 0
        i = i + 1
    return 0

// Narrow string merge: the IF has no direct allocations and assigns a string
// value into one outer local slot, once per assigning branch. The copy is made
// at the branch exit by switching to the parent arena and calling str_sub, so
// the result lives in the parent slot even when the source string was built in
// the child arena. Plan name carries the outer destination variable.
fn rp_if_string_merge_eligible(sg: int, sg_start: int, sg_count: int,
                               nstart: int, ncount: int) -> int:
    ai : ., mut = 0
    loop:
        if ai >= g_pa_alloc_count:
            break
        an := cell_load(g_pa_alloc_nodes, ai * 8)
        if subgraph_containing(an) == sg:
            return 0
        ai = ai + 1
    dest : ., mut = -1
    count : ., mut = 0
    st1 : ., mut = -1
    st2 : ., mut = -1
    src1 : ., mut = -1
    src2 : ., mut = -1
    lit1 : ., mut = -1
    lit2 : ., mut = -1
    ni : ., mut = sg_start
    loop:
        if ni >= sg_start + sg_count:
            break
        op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
        if op == IR_STORE:
            s1 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)
            s2 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S2)
            if s1 >= 0 && irv_type(s2) == TI_STR:
                if subgraph_containing(ni) != sg:
                    return 0
                if dest < 0:
                    dest = s1
                else if dest != s1:
                    return 0
                // A literal source can be precomputed in the parent arena
                // before the child exists. Any other string value is copied at
                // the branch exit through the runtime arena switch.
                lit : ., mut = -1
                pv := cell_load(g_df_var_producer, s2 * 8)
                if pv >= 0:
                    if cell_load(g_df_nodes, pv * ESZ_DFNODE + OFF_DF_OPCODE) == IR_CONST:
                        lv := cell_load(g_df_nodes, pv * ESZ_DFNODE + OFF_DF_S1)
                        if lv >= 0:
                            lit = lv
                count = count + 1
                if count == 1:
                    st1 = ni
                    src1 = s2
                    lit1 = lit
                else if count == 2:
                    st2 = ni
                    src2 = s2
                    lit2 = lit
                else:
                    return 0
        ni = ni + 1
    if count < 1 || dest < 0 || rc_is_global_var(dest) != 0:
        return 0
    if irv_type(dest) != TI_STR:
        return 0
    prod := cell_load(g_df_var_producer, dest * 8)
    if prod < 0:
        return 0
    if rc_sg_is_ancestor(sg, subgraph_containing(prod)) != 0:
        return 0
    // No other write to the outer slot inside the IF.
    ni = sg_start
    loop:
        if ni >= sg_start + sg_count:
            break
        op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
        s1 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)
        s2 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S2)
        if op == IR_STORE && s1 == dest:
            if irv_type(s2) != TI_STR:
                return 0
        ni = ni + 1
    if count == 2:
        mnode := sg_start + sg_count - 1
        if cell_load(g_df_nodes, mnode * ESZ_DFNODE + OFF_DF_OPCODE) != IR_LABEL:
            return 0
        j1 : ., mut = -1
        j2 : ., mut = -1
        jc : ., mut = 0
        ni = sg_start
        loop:
            if ni >= sg_start + sg_count:
                break
            if cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE) == IR_JUMP:
                if rc_ctl_label_node(cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)) == mnode:
                    jc = jc + 1
                    if jc == 1:
                        j1 = ni
                    else if jc == 2:
                        j2 = ni
                    else:
                        return 0
            ni = ni + 1
        if jc != 2 || st1 >= j1 || st2 <= j1 || st2 >= j2:
            return 0
    if lit1 < 0 || (count == 2 && lit2 < 0):
        lit1 = -1
        lit2 = -1
    g_rp_merge_kind = 3
    g_rp_merge_name = dest
    g_rp_merge_str1 = lit1
    g_rp_merge_str2 = lit2
    g_rp_merge_len = 1
    return 1

// Only calls to the pure string builders in fmt are allowed inside a string
// merge IF. The owner check prevents a user-defined function with the same
// name from being mistaken for the library routine.
fn rp_fmt_owner() -> int:
    fi := rc_func_by_name(str_intern("str_len"))
    if fi < 0:
        return -1
    return func_owner(fi)

fn rp_string_call_name_ok(ni: int) -> int:
    if ni < 0:
        return 0
    n := istr_get(ni)
    if str_eq(n, "str_len") != 0:
        return 1
    if str_eq(n, "chr") != 0:
        return 1
    if str_eq(n, "get_char") != 0:
        return 1
    if str_eq(n, "str_sub") != 0:
        return 1
    if str_eq(n, "str_eq") != 0:
        return 1
    if str_eq(n, "str_cmp") != 0:
        return 1
    if str_eq(n, "concat") != 0:
        return 1
    if str_eq(n, "int_str") != 0:
        return 1
    if str_eq(n, "str_int") != 0:
        return 1
    if str_eq(n, "to_str") != 0:
        return 1
    if str_eq(n, "bool_str") != 0:
        return 1
    if str_eq(n, "format") != 0:
        return 1
    if str_eq(n, "format2") != 0:
        return 1
    if str_eq(n, "format_int") != 0:
        return 1
    if str_eq(n, "float_str_bits") != 0:
        return 1
    return 0

fn rp_string_calls_ok(sg_start: int, sg_count: int) -> int:
    owner := rp_fmt_owner()
    if owner < 0:
        return 0
    ni : ., mut = sg_start
    loop:
        if ni >= sg_start + sg_count:
            return 1
        op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
        s1 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)
        s3 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S3)
        if op == IR_CALL:
            if rp_string_call_name_ok(s3) == 0:
                return 0
            cfi := rc_func_by_name(s3)
            if cfi < 0 || func_owner(cfi) != owner:
                return 0
        else if op == IR_CALL_EXTERN || op == IR_SPAWN || op == IR_YIELD || op == IR_AWAIT || op == IR_RETURN:
            return 0
        else if op == IR_JUMP:
            if rp_label_inside(rc_ctl_label_node(s1), sg_start, sg_count) == 0:
                return 0
        ni = ni + 1
    return 1

// V2.2 merge: one direct constant-size scalar array is stored directly into an
// outer local slot. An if/else may allocate one array per branch when both
// arrays have the same element type and length; one parent copy is filled at
// each assigning branch exit, and the outer slot is rebound there. Element
// reads/writes may reach a child through aliases inside the IF; outside the IF
// they must go through the outer slot.
fn rp_if_merge_eligible(sg: int, sg_start: int, sg_count: int,
                        nstart: int, ncount: int, allow_calls: int) -> int:
    // Flow-insensitive points-to cannot order uses across a loop backedge, so a
    // merge IF inside a loop stays v1. Unsafe blocks are also identity-observable.
    g_rp_merge_len = -1
    if rp_if_merge_ancestors_ok(sg) == 0:
        return 0
    if rp_if_string_merge_eligible(sg, sg_start, sg_count, nstart, ncount) != 0:
        return 1
    alloc_count : ., mut = 0
    kind : ., mut = -1
    name1 : ., mut = -1
    an1 : ., mut = -1
    an2 : ., mut = -1
    ai1 : ., mut = -1
    ai2 : ., mut = -1
    ai : ., mut = 0
    loop:
        if ai >= g_pa_alloc_count:
            break
        an := cell_load(g_pa_alloc_nodes, ai * 8)
        if subgraph_containing(an) == sg:
            k := rp_merge_alloc_kind(an)
            if k < 0:
                return 0
            if alloc_count == 0:
                kind = k
                name1 = cell_load(g_df_nodes, an * ESZ_DFNODE + OFF_DF_S3)
                an1 = an
                ai1 = ai
            else if alloc_count == 1:
                if k != kind:
                    return 0
                if kind == 1:
                    if cell_load(g_df_nodes, an * ESZ_DFNODE + OFF_DF_S3) != name1:
                        return 0
                an2 = an
                ai2 = ai
            else:
                return 0
            alloc_count = alloc_count + 1
        ai = ai + 1
    if alloc_count < 1:
        return 0
    if alloc_count == 2 && an2 < an1:
        tn := an1
        ti := ai1
        an1 = an2
        ai1 = ai2
        an2 = tn
        ai2 = ti
    // Every other allocation that lands in this IF's arena must stay inside;
    // only the selected arrays are copied out to the parent slot.
    ai = 0
    loop:
        if ai >= g_pa_alloc_count:
            break
        if ai != ai1 && ai != ai2:
            an := cell_load(g_pa_alloc_nodes, ai * 8)
            aop2 := cell_load(g_df_nodes, an * ESZ_DFNODE + OFF_DF_OPCODE)
            if aop2 == IR_ALLOC_ARRAY || aop2 == IR_ALLOC_STRUCT:
                csg2 := subgraph_containing(an)
                if csg2 == sg || rc_sg_is_ancestor(sg, csg2) != 0:
                    if rp_alloc_has_nested_release(an, sg) == 0:
                        if rp_alloc_escapes(ai, sg, nstart, ncount, sg_start, sg_count) != 0:
                            return 0
        ai = ai + 1
    ad1 := cell_load(g_df_nodes, an1 * ESZ_DFNODE + OFF_DF_DEST)
    cnt : ., mut = 0
    elem : ., mut = -1
    if kind == 0:
        at := irv_type(ad1)
        if at < 0 || at >= g_type_count || get_type_kind(at) != TYP_ARRAY:
            return 0
        cnt = cell_load(g_df_nodes, an1 * ESZ_DFNODE + OFF_DF_S1)
        if cnt < 0:
            return 0
        elem = get_type_data(at)
        if rp_copyable_leaf(elem) == 0:
            return 0
    else if kind == 1:
        si := find_struct_by_name(name1)
        if si < 0:
            return 0
        cnt = si_field_count(si)
        if cnt <= 0 || cnt > 64:
            return 0
        fi : ., mut = 0
        loop:
            if fi >= cnt:
                break
            if rp_copyable_leaf(struct_row_field_ti(si, fi)) == 0:
                return 0
            fi = fi + 1
    else:
        cnt = cell_load(g_df_nodes, an1 * ESZ_DFNODE + OFF_DF_S1)
        if rp_tuple_pod(an1, cnt, sg_start, sg_count) == 0:
            return 0
    ad2 : ., mut = -1
    mid : ., mut = -1
    ni : ., mut = sg_start
    if alloc_count == 2:
        ad2 = cell_load(g_df_nodes, an2 * ESZ_DFNODE + OFF_DF_DEST)
        if kind == 0:
            at2 := irv_type(ad2)
            if at2 < 0 || at2 >= g_type_count || get_type_kind(at2) != TYP_ARRAY:
                return 0
            if cell_load(g_df_nodes, an2 * ESZ_DFNODE + OFF_DF_S1) != cnt:
                return 0
            if get_type_data(at2) != elem:
                return 0
        else if kind == 1:
            if cell_load(g_df_nodes, an2 * ESZ_DFNODE + OFF_DF_S3) != name1:
                return 0
        else:
            if cell_load(g_df_nodes, an2 * ESZ_DFNODE + OFF_DF_S1) != cnt:
                return 0
            if rp_tuple_pod(an2, cnt, sg_start, sg_count) == 0:
                return 0
        // The two arrays must occupy different branches: the then branch ends
        // at the first jump to the IF merge label, the else branch at the
        // second. Splitting here keeps one copy emission per branch range.
        mnode := sg_start + sg_count - 1
        if cell_load(g_df_nodes, mnode * ESZ_DFNODE + OFF_DF_OPCODE) != IR_LABEL:
            return 0
        mlbl := cell_load(g_df_nodes, mnode * ESZ_DFNODE + OFF_DF_S1)
        j1 : ., mut = -1
        j2 : ., mut = -1
        jc : ., mut = 0
        ni = sg_start
        loop:
            if ni >= sg_start + sg_count:
                break
            if cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE) == IR_JUMP:
                if rc_ctl_label_node(cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)) == mnode:
                    jc = jc + 1
                    if jc == 1:
                        j1 = ni
                    else if jc == 2:
                        j2 = ni
                    else:
                        return 0
            ni = ni + 1
        if jc != 2 || an1 >= j1 || an2 <= j1 || an2 >= j2:
            return 0
        mid = j1
    // Each selected array must be bound to the same outer local slot exactly
    // once, in its own branch.
    dest : ., mut = -1
    stores1 : ., mut = 0
    stores2 : ., mut = 0
    ni = sg_start
    loop:
        if ni >= sg_start + sg_count:
            break
        op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
        s1 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)
        s2 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S2)
        if op == IR_STORE && s2 == ad1:
            if subgraph_containing(ni) != sg:
                return 0
            if alloc_count == 2 && ni >= mid:
                return 0
            if dest < 0:
                dest = s1
            else if dest != s1:
                return 0
            stores1 = stores1 + 1
        else if op == IR_STORE && alloc_count == 2 && s2 == ad2:
            if subgraph_containing(ni) != sg:
                return 0
            if ni <= mid:
                return 0
            if dest < 0:
                dest = s1
            else if dest != s1:
                return 0
            stores2 = stores2 + 1
        ni = ni + 1
    if stores1 != 1 || dest < 0 || rc_is_global_var(dest) != 0:
        return 0
    if alloc_count == 2 && stores2 != 1:
        return 0
    if rp_merge_lifetime_ok(sg, dest, nstart, ncount) == 0:
        return 0
    prod := cell_load(g_df_var_producer, dest * 8)
    if prod < 0:
        return 0
    if rc_sg_is_ancestor(sg, subgraph_containing(prod)) != 0:
        return 0
    // The outer slot must not be overwritten by anything except the selected
    // child arrays inside the IF.
    ni = sg_start
    loop:
        if ni >= sg_start + sg_count:
            break
        op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
        s1 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)
        s2 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S2)
        if op == IR_STORE && s1 == dest:
            if s2 != ad1 && (alloc_count < 2 || s2 != ad2):
                return 0
        ni = ni + 1
    // Precise use scan. For load/store-index the base is a use-through of a
    // child array; the stored value is an escape if it names a child. Every
    // other opcode that mentions a child is an observation and blocks.
    ni = nstart
    loop:
        if ni >= nstart + ncount:
            g_rp_merge_kind = kind
            g_rp_merge_name = name1
            g_rp_merge_len = cnt
            return 1
        op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
        dv := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_DEST)
        s1 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)
        s2 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S2)
        s3 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S3)
        if ni > an1:
            base : ., mut = -1
            value : ., mut = -1
            extra : ., mut = 0
            known : ., mut = 0
            if kind == 0:
                if op == IR_LOAD_INDEX || op == IR_LOAD_INDEX_VAR:
                    base = s1
                    known = 1
                    if op == IR_LOAD_INDEX_VAR && rp_sel_pts(s2, ai1, ai2) != 0:
                        extra = 1
                else if op == IR_STORE_INDEX:
                    base = s1
                    value = s2
                    known = 1
                else if op == IR_STORE_INDEX_VAR:
                    base = s1
                    value = dv
                    known = 1
                    if rp_sel_pts(s2, ai1, ai2) != 0:
                        extra = 1
            else:
                if op == IR_LOAD_FIELD:
                    base = s1
                    known = 1
                else if op == IR_STORE_FIELD:
                    base = s1
                    value = s2
                    known = 1
            if known == 0:
                if op == IR_STORE && s1 == dest && subgraph_containing(ni) == sg:
                    if s2 == ad1 || (alloc_count == 2 && s2 == ad2):
                        // A bind of a child array into the outer slot.
                        ni = ni + 1
                        continue
                // Literal-only opcodes: their source fields are values, label
                // ids, or type tags, not variable slots.
                literal_only : ., mut = 0
                if op == IR_CONST || op == IR_CONST_BIG || op == IR_LABEL || op == IR_JUMP || op == IR_ALLOC || op == IR_ALLOC_ARRAY || op == IR_ALLOC_STRUCT || op == IR_BOUNDS_CHECK:
                    // Bounds checks carry only integer indices and lengths; the
                    // array pointer is not an operand.
                    literal_only = 1
                if literal_only == 0:
                    // IR_BINARY/IR_UNARY/IR_MATCH keep an operator or label
                    // range in the high fields; check only the value slots.
                    if op == IR_CALL || op == IR_SPAWN:
                        if allow_calls == 0 && rp_call_arg_uses_sel(s1, s2, ai1, ai2) != 0:
                            return 0
                    else if op == IR_MATCH:
                        if rp_sel_pts(s1, ai1, ai2) != 0:
                            return 0
                    else if op == IR_BINARY:
                        if rp_sel_pts(s1, ai1, ai2) != 0:
                            return 0
                        if rp_sel_pts(s2, ai1, ai2) != 0:
                            return 0
                    else if op == IR_UNARY:
                        if rp_sel_pts(s1, ai1, ai2) != 0:
                            return 0
                    else:
                        if rp_sel_pts(s1, ai1, ai2) != 0:
                            return 0
                        if rp_sel_pts(s2, ai1, ai2) != 0:
                            return 0
                        if rp_sel_pts(s3, ai1, ai2) != 0:
                            return 0
                        if rp_sel_pts(dv, ai1, ai2) != 0:
                            return 0
            else:
                if extra != 0:
                    return 0
                if rp_sel_pts(value, ai1, ai2) != 0:
                    return 0
                if rp_sel_pts(base, ai1, ai2) != 0:
                    if rc_sg_is_ancestor(sg, subgraph_containing(ni)) == 0 && base != dest:
                        return 0
        ni = ni + 1
    g_rp_merge_kind = kind
    g_rp_merge_name = name1
    g_rp_merge_len = cnt
    return 1

// V2.3 narrow share: a top-level IF allocates one scalar array into its child
// slot and every use after the IF is a read through the rebound outer slot.
// The child slot stays live, is not reused, and is reset after the last
// consumer loop's own reset (the LCPD of the readers).
// Node of the SG's own IR_ARENA_NEW (the arena is not current before it).
fn rp_sg_arena_new_node(sg: int) -> int:
    av := cell_load(g_sg_arena_var, sg * 8)
    if av < 0:
        return -1
    ns := cell_load(g_sgs, sg * ESZ_SG + OFF_SG_NSTART)
    ne := cell_load(g_sgs, sg * ESZ_SG + OFF_SG_EXIT)
    ni : ., mut = ns
    loop:
        if ni >= ne:
            return -1
        op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
        d := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_DEST)
        if op == IR_ARENA_NEW && d == av:
            return ni
        ni = ni + 1
    return -1

// Reset event for a label: a loop/for/split-IF exit label uses the after-SG
// reset (mode 0); a function-level or plain-IF label uses a label reset
// (mode 1). A label inside any active releasing arena, an unsafe, or a merge IF
// is not a valid current-S point.
fn rp_share_bad_set(fi: int, bits: int):
    if fi < 0 || fi >= g_ir_func_count:
        return
    cur := cell_load(g_share_bad, fi * 8)
    nv := cur + bits
    // OR the four independent bits without a bitwise opcode.
    out : ., mut = 0
    b : ., mut = 1
    loop:
        if b > 8:
            break
        if (cur / b) % 2 == 1 || (bits / b) % 2 == 1:
            out = out + b
        b = b * 2
    cell_store(g_share_bad, fi * 8, out)

fn rp_share_bad_prepare():
    g_share_bad = alloc(g_ir_func_count * 8)
    fi : ., mut = 0
    loop:
        if fi >= g_ir_func_count:
            break
        cell_store(g_share_bad, fi * 8, 0)
        fi = fi + 1
    cav := rp_global_var_named("g_current_arena")
    fi = 0
    loop:
        if fi >= g_ir_func_count:
            break
        cs := cell_load(g_df_func_node_start, fi * 8)
        cc := cell_load(g_df_func_node_count, fi * 8)
        if cs >= 0 && cc > 0:
            if cav >= 0:
                if rp_if_reads_var(cs, cc, cav) != 0:
                    rp_share_bad_set(fi, 2)
            ni : ., mut = cs
            loop:
                if ni >= cs + cc:
                    break
                op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
                d := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_DEST)
                s1 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)
                s2 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S2)
                s3 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S3)
                if op == IR_STORE && s1 == cav:
                    rp_share_bad_set(fi, 2)
                if op == IR_STORE_INDEX || op == IR_STORE_INDEX_VAR || op == IR_STORE_FIELD || op == IR_STORE_PTR || op == IR_ADDR_INDEX || op == IR_REF || op == IR_SLICE || op == IR_PTR_OF || op == IR_STR_OF:
                    rp_share_bad_set(fi, 8)
                // A callee allocation can land in the caller's current share
                // slot and die at the share reset. Reject it unless a later
                // lifetime proof is added for returned values.
                if op == IR_ALLOC_ARRAY || op == IR_ALLOC_STRUCT || op == IR_ALLOC_AT:
                    rp_share_bad_set(fi, 4)
                if op == IR_RETURN:
                    rt := irv_type(s1)
                    if rt >= 0 && rt < g_type_count:
                        rk := get_type_kind(rt)
                        if rk == TYP_ARRAY || rk == TYP_PTR || rk == TYP_REF || rk == TYP_SLICE || rk == TYP_TUPLE || rk == TYP_OPTIONAL:
                            rp_share_bad_set(fi, 4)
                        else if rk == TYP_BASE && get_type_data(rt) == TY_STRING:
                            rp_share_bad_set(fi, 4)
                if op == IR_SPAWN || op == IR_YIELD || op == IR_AWAIT:
                    rp_share_bad_set(fi, 4)
                if op == IR_CALL_EXTERN || op == IR_HOTPATCH_ROUTE || op == IR_DYN_DISPATCH:
                    rp_share_bad_set(fi, 4)
                if op == IR_CALL || op == IR_SPAWN:
                    if is_arena_infra_name(s3) != 0:
                        rp_share_bad_set(fi, 4)
                    else if rc_func_by_name(s3) < 0:
                        rp_share_bad_set(fi, 15)
                ni = ni + 1
            sg : ., mut = 0
            loop:
                if sg >= g_sg_count:
                    break
                ss := cell_load(g_sgs, sg * ESZ_SG + OFF_SG_NSTART)
                if ss >= cs && ss < cs + cc:
                    if cell_load(g_sgs, sg * ESZ_SG + OFF_SG_KIND) == SG_UNSAFE:
                        rp_share_bad_set(fi, 1)
                sg = sg + 1
        fi = fi + 1
    // Propagate callee hazards to callers until stable.
    changed : ., mut = 1
    guard : ., mut = 0
    loop:
        if changed == 0:
            return
        guard = guard + 1
        if guard > g_ir_func_count + 4:
            return
        changed = 0
        fi = 0
        loop:
            if fi >= g_ir_func_count:
                break
            cs := cell_load(g_df_func_node_start, fi * 8)
            cc := cell_load(g_df_func_node_count, fi * 8)
            if cs >= 0 && cc > 0:
                ni : ., mut = cs
                loop:
                    if ni >= cs + cc:
                        break
                    op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
                    s3 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S3)
                    if op == IR_CALL || op == IR_SPAWN:
                        cfi := rc_func_by_name(s3)
                        if cfi >= 0 && cfi < g_ir_func_count:
                            cb := cell_load(g_share_bad, cfi * 8)
                            ob := cell_load(g_share_bad, fi * 8)
                            if cb != 0 && (ob + cb) != ob:
                                rp_share_bad_set(fi, cb)
                                changed = 1
                    ni = ni + 1
            fi = fi + 1

fn rp_share_event_for_label(q: int, p: int) -> int:
    g_rp_share_mode = -1
    g_rp_share_consumer = -1
    g_rp_share_reset_node = -1
    event : ., mut = -1
    mode : ., mut = -1
    rn : ., mut = q
    cur : ., mut = subgraph_containing(q)
    loop:
        if cur < 0:
            return 0
        if cur == p:
            break
        k := cell_load(g_sgs, cur * ESZ_SG + OFF_SG_KIND)
        if k == SG_UNSAFE:
            return 0
        if k == SG_LOOP || k == SG_FOR:
            ex := cell_load(g_sgs, cur * ESZ_SG + OFF_SG_EXIT)
            if q == ex - 1:
                if event >= 0:
                    return 0
                event = cur
                mode = 0
                rn = ex
            else:
                return 0
        else if k == SG_IF:
            if region_plan_is_share(cur) != 0:
                return 0
            if region_plan_is_merge(cur) != 0:
                return 0
            if region_plan_is_split(cur) != 0:
                ex := cell_load(g_sgs, cur * ESZ_SG + OFF_SG_EXIT)
                if q == ex - 1:
                    if event >= 0:
                        return 0
                    event = cur
                    mode = 0
                    rn = ex
                else:
                    return 0
        cur = cell_load(g_sgs, cur * ESZ_SG + OFF_SG_PARENT)
    if event < 0:
        mode = 1
        rn = q
    else:
        // A structured region exit is a reset point only when the region is a
        // top-level statement after the share IF. Inside a plain IF it can be
        // skipped; the enclosing join label is the safe point instead.
        ep := cell_load(g_sgs, event * ESZ_SG + OFF_SG_PARENT)
        if ep != p:
            return 0
    g_rp_share_mode = mode
    g_rp_share_consumer = event
    g_rp_share_reset_node = rn
    return 1

// Cross-function read-only proof for a call in a share window. Only leaf
// callees are accepted: no calls/spawn, no unsafe, no direct g_current_arena
// read/write, and the BP/RegionCheck summaries must show that every parameter
// receiving the shared array is neither written nor escaped nor returned nor
// passed to FFI.
// The cross-function proof is read-only: a callee receiving the shared array
// must not perform any heap/array/field/pointer store. A leaf callee may still
// store scalars into its own stack slots; those do not reach the shared bytes.
fn rp_share_callee_heap_readonly(cfi: int) -> int:
    cs := cell_load(g_df_func_node_start, cfi * 8)
    cc := cell_load(g_df_func_node_count, cfi * 8)
    if cs < 0 || cc <= 0:
        return 0
    ni : ., mut = cs
    loop:
        if ni >= cs + cc:
            return 1
        op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
        if op == IR_STORE_INDEX || op == IR_STORE_INDEX_VAR || op == IR_STORE_FIELD || op == IR_STORE_PTR:
            return 0
        ni = ni + 1
    return 0

fn rp_share_call_args_ok(cfi: int, s1: int, s2: int, ai_sel: int) -> int:
    pc := cell_load(g_ir_func_param_count, cfi * 8)
    saw_array : ., mut = 0
    ac : ., mut = 0
    loop:
        if ac >= s2:
            if saw_array != 0:
                hb := cell_load(g_share_bad, cfi * 8)
                if (hb / 8) % 2 == 1:
                    return 0
            return 1
        av := s1 + ac
        if av >= 0 && rp_var_may_point(av) != 0 && pa_pts_has(av, ai_sel) != 0:
            saw_array = 1
            if ac >= pc:
                return 0
            if rc_mask_has(g_bp_param_write, cfi * 2, ac) != 0:
                return 0
            if rc_mask_has(g_rc_param_escape, cfi * 2, ac) != 0:
                return 0
            if rc_mask_has(g_rc_ret_alias, cfi * 2, ac) != 0:
                return 0
            if rc_mask_has(g_rc_param_ffi, cfi * 2, ac) != 0:
                return 0
        ac = ac + 1
    return 0

fn rp_share_callee_clean(cfi: int) -> int:
    if cfi < 0 || cfi >= g_ir_func_count || str_len(g_share_bad) == 0:
        return 0
    bits := cell_load(g_share_bad, cfi * 8)
    if (bits / 1) % 2 == 1 || (bits / 2) % 2 == 1 || (bits / 4) % 2 == 1:
        return 0
    return 1

fn rp_share_call_ok(s1: int, s2: int, s3: int, ai_sel: int) -> int:
    if is_arena_infra_name(s3) != 0:
        return 0
    cfi := rc_func_by_name(s3)
    if cfi < 0:
        return 0
    if rp_share_callee_clean(cfi) == 0:
        return 0
    return rp_share_call_args_ok(cfi, s1, s2, ai_sel)

// The window from the IF exit to the reset point must not observe the arena
// switch, allocate through the shared slot, leave a nested arena current, or
// contain a write/escape of the shared array. Calls are rejected in this slice.
fn rp_share_window_ok(s_end: int, rn: int, mode: int, ai_sel: int, nstart: int, ncount: int) -> int:
    ni : ., mut = s_end
    loop:
        if ni >= rn:
            break
        op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
        s1 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)
        s2 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S2)
        s3 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S3)
        if op == IR_SPAWN || op == IR_YIELD || op == IR_AWAIT:
            return 0
        if op == IR_CALL_EXTERN || op == IR_HOTPATCH_ROUTE || op == IR_DYN_DISPATCH:
            return 0
        if op == IR_CALL:
            if rp_share_call_ok(s1, s2, s3, ai_sel) == 0:
                return 0
        if op == IR_RETURN:
            return 0
        if op == IR_JUMP:
            t := rc_ctl_label_node(cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1))
            if t < s_end:
                return 0
            if mode == 1:
                if t > rn:
                    return 0
            else:
                if t >= rn:
                    return 0
            d : ., mut = 0
            loop:
                if d >= g_sg_count:
                    break
                ds := cell_load(g_sgs, d * ESZ_SG + OFF_SG_NSTART)
                if ds >= s_end && ds < rn:
                    dk := cell_load(g_sgs, d * ESZ_SG + OFF_SG_KIND)
                    if dk == SG_LOOP || dk == SG_FOR:
                        de := cell_load(g_sgs, d * ESZ_SG + OFF_SG_EXIT)
                        if t == de - 1:
                            return 0
                d = d + 1
        ni = ni + 1
    d : ., mut = 0
    loop:
        if d >= g_sg_count:
            break
        ds := cell_load(g_sgs, d * ESZ_SG + OFF_SG_NSTART)
        if ds >= s_end && ds < rn:
            dk := cell_load(g_sgs, d * ESZ_SG + OFF_SG_KIND)
            if dk == SG_UNSAFE:
                return 0
            if dk == SG_IF && region_plan_is_merge(d) != 0:
                return 0
        d = d + 1
    cav := rp_global_var_named("g_current_arena")
    if cav >= 0 && rp_if_reads_var(s_end, rn - s_end, cav) != 0:
        return 0
    ai : ., mut = 0
    loop:
        if ai >= g_pa_alloc_count:
            break
        an2 := cell_load(g_pa_alloc_nodes, ai * 8)
        if an2 > s_end && an2 < rn:
            cur2 : ., mut = subgraph_containing(an2)
            owned : ., mut = 0
            loop:
                if cur2 < 0:
                    break
                if rc_sg_releases(cur2) != 0:
                    an_new : ., mut = rp_sg_arena_new_node(cur2)
                    if an_new < 0:
                        // A split/merge IF has no arena node in Phase A; its
                        // child arena is created at the IF entry in Phase B.
                        ck := cell_load(g_sgs, cur2 * ESZ_SG + OFF_SG_KIND)
                        if ck == SG_IF && (region_plan_is_split(cur2) != 0 || region_plan_is_merge(cur2) != 0 || region_plan_is_share(cur2) != 0):
                            an_new = cell_load(g_sgs, cur2 * ESZ_SG + OFF_SG_NSTART)
                    if an_new >= 0 && an2 > an_new:
                        owned = 1
                        break
                cur2 = cell_load(g_sgs, cur2 * ESZ_SG + OFF_SG_PARENT)
            if owned == 0:
                return 0
        ai = ai + 1
    return 1

// V2.3 share: a top-level IF allocates one scalar array into its child slot;
// after the IF the array is only read. The slot stays live and is reset at the
// earliest label that post-dominates the IF merge, has no intervening call/
// allocation/arena switch, and is a valid current-S point (a function/plain-IF
// label or a loop/for/split-IF exit). No copy is made.
fn rp_if_share_eligible(sg: int, sg_start: int, sg_count: int,
                        nstart: int, ncount: int) -> int:
    g_rp_share_consumer = -1
    g_rp_share_exit = -1
    g_rp_share_mode = -1
    g_rp_share_reset_node = -1
    g_rp_share_cow = 0
    g_rp_share_dest = -1
    g_rp_share_len = 0
    g_rp_share_elem = -1
    // Same hard gates as the split/merge candidate scan.
    if rp_if_has_unsafe(sg_start, sg_count) != 0:
        return 0
    if rp_if_has_exit_or_effect(sg_start, sg_count) != 0:
        return 0
    cav0 := rp_global_var_named("g_current_arena")
    if rp_if_reads_var(sg_start, sg_count, cav0) != 0:
        return 0
    p := cell_load(g_sgs, sg * ESZ_SG + OFF_SG_PARENT)
    if p < 0 || cell_load(g_sgs, p * ESZ_SG + OFF_SG_KIND) != SG_FUNC:
        return 0
    cnt := rp_if_merge_eligible(sg, sg_start, sg_count, nstart, ncount, 1)
    if cnt <= 0:
        return 0
    ai_sel : ., mut = -1
    alloc_count : ., mut = 0
    ai : ., mut = 0
    loop:
        if ai >= g_pa_alloc_count:
            break
        an := cell_load(g_pa_alloc_nodes, ai * 8)
        if subgraph_containing(an) == sg:
            ai_sel = ai
            alloc_count = alloc_count + 1
        ai = ai + 1
    if ai_sel < 0 || alloc_count != 1:
        return 0
    an := cell_load(g_pa_alloc_nodes, ai_sel * 8)
    alloc_dest := cell_load(g_df_nodes, an * ESZ_DFNODE + OFF_DF_DEST)
    dest : ., mut = -1
    ni : ., mut = sg_start
    loop:
        if ni >= sg_start + sg_count:
            break
        op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
        s1 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)
        s2 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S2)
        if op == IR_STORE && s2 == alloc_dest:
            dest = s1
        ni = ni + 1
    if dest < 0:
        return 0
    at := irv_type(alloc_dest)
    if at < 0 || at >= g_type_count || get_type_kind(at) != TYP_ARRAY:
        return 0
    g_rp_share_dest = dest
    g_rp_share_len = cell_load(g_df_nodes, an * ESZ_DFNODE + OFF_DF_S1)
    g_rp_share_elem = get_type_data(at)
    s_end := sg_start + sg_count
    func_end := nstart + ncount
    umax : ., mut = -1
    wrote : ., mut = 0
    ni = s_end
    loop:
        if ni >= func_end:
            break
        op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
        dv := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_DEST)
        s1 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)
        s2 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S2)
        s3 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S3)
        base : ., mut = -1
        value : ., mut = -1
        known : ., mut = 0
        if op == IR_LOAD_INDEX || op == IR_LOAD_INDEX_VAR:
            base = s1
            known = 1
        else if op == IR_STORE_INDEX:
            base = s1
            value = s2
            known = 1
        else if op == IR_STORE_INDEX_VAR:
            base = s1
            value = dv
            known = 1
        if known != 0:
            if value >= 0 && rp_var_may_point(value) != 0 && pa_pts_has(value, ai_sel) != 0:
                return 0
            if base >= 0 && rp_var_may_point(base) != 0 && pa_pts_has(base, ai_sel) != 0:
                if base != dest:
                    return 0
                if op == IR_STORE_INDEX || op == IR_STORE_INDEX_VAR:
                    wrote = 1
                umax = ni
        else:
            literal_only : ., mut = 0
            if op == IR_CONST || op == IR_CONST_BIG || op == IR_LABEL || op == IR_JUMP || op == IR_ALLOC || op == IR_ALLOC_ARRAY || op == IR_ALLOC_STRUCT || op == IR_BOUNDS_CHECK:
                literal_only = 1
            if literal_only == 0:
                if op == IR_CALL || op == IR_SPAWN:
                    if rp_call_arg_uses_alloc(s1, s2, ai_sel) != 0:
                        umax = ni
                else if op == IR_MATCH:
                    if s1 >= 0 && rp_var_may_point(s1) != 0 && pa_pts_has(s1, ai_sel) != 0:
                        return 0
                else if op == IR_BINARY:
                    if s1 >= 0 && rp_var_may_point(s1) != 0 && pa_pts_has(s1, ai_sel) != 0:
                        return 0
                    if s2 >= 0 && rp_var_may_point(s2) != 0 && pa_pts_has(s2, ai_sel) != 0:
                        return 0
                else if op == IR_UNARY:
                    if s1 >= 0 && rp_var_may_point(s1) != 0 && pa_pts_has(s1, ai_sel) != 0:
                        return 0
                else:
                    if s1 >= 0 && rp_var_may_point(s1) != 0 && pa_pts_has(s1, ai_sel) != 0:
                        return 0
                    if s2 >= 0 && rp_var_may_point(s2) != 0 && pa_pts_has(s2, ai_sel) != 0:
                        return 0
                    if s3 >= 0 && rp_var_may_point(s3) != 0 && pa_pts_has(s3, ai_sel) != 0:
                        return 0
                    if dv >= 0 && rp_var_may_point(dv) != 0 && pa_pts_has(dv, ai_sel) != 0:
                        return 0
        ni = ni + 1
    if umax < 0:
        return 0
    if wrote != 0:
        g_rp_share_cow = 1
    rp_pdom_prepare(nstart, ncount)
    if g_rp_pdom_ok == 0:
        return 0
    merge_node := s_end - 1
    if cell_load(g_df_nodes, merge_node * ESZ_DFNODE + OFF_DF_OPCODE) != IR_LABEL:
        return 0
    words := g_rp_pdom_words
    q : ., mut = umax + 1
    loop:
        if q >= func_end:
            return 0
        op := cell_load(g_df_nodes, q * ESZ_DFNODE + OFF_DF_OPCODE)
        if op == IR_LABEL:
            ev := rp_share_event_for_label(q, p)
            if ev != 0:
                // Mode-1 labels need post-dominance. A top-level structured
                // region exit (mode 0) is unconditional after the share IF;
                // loops may not appear in post-dominance because of the
                // non-terminating path, which is harmless here.
                ok : ., mut = 1
                if g_rp_share_mode == 1:
                    ok = rp_bit_has(g_rp_pdom, (merge_node - nstart) * words, q - nstart)
                if ok != 0:
                    win := rp_share_window_ok(s_end, g_rp_share_reset_node, g_rp_share_mode, ai_sel, nstart, ncount)
                    if win != 0:
                        g_rp_share_exit = cell_load(g_df_nodes, q * ESZ_DFNODE + OFF_DF_S1)
                        return cnt
        q = q + 1
    return 0

// Materialize the V2.2 merge copy at the end of the assigning branch. The copy
// allocation was emitted before the child arena, so it lives in the parent slot.
// The child array is copied element by element and the outer slot is rebound
// before the branch jumps to the merge label; the other path keeps the old value.
fn rp_emit_merge_arg(av: int, ti: int) -> int:
    pv := new_ir_var("_merge_arg", ti)
    emit(IR_STORE, -1, pv, av, 0, 0)
    return pv

// Materialize a literal string copy in the parent arena before the IF child
// arena is created. str_sub allocates in the current arena and returns a value
// that survives the child reset.
fn rp_emit_parent_str_copy(lit: int) -> int:
    if lit < 0:
        return -1
    litv := new_ir_var("_merge_lit", TI_STR)
    emit(IR_CONST, litv, lit, 0, 0, TI_STR)
    zv := new_ir_var("_merge_zero", TI_INT)
    emit(IR_CONST, zv, 0, 0, 0, TI_INT)
    lv := new_ir_var("_merge_len", TI_INT)
    emit(IR_CONST, lv, istr_len(lit), 0, 0, TI_INT)
    a0 := rp_emit_merge_arg(litv, TI_STR)
    a1 := rp_emit_merge_arg(zv, TI_INT)
    a2 := rp_emit_merge_arg(lv, TI_INT)
    // str_sub allocates len+1 bytes; charge the parent slot before the call so
    // a static arena peak includes the surviving copy.
    track_alloc_size(((istr_len(lit) + 1 + 15) / 8) * 8)
    cp := new_ir_var("_merge_str", TI_STR)
    emit(IR_CALL, cp, a0, 3, str_intern("str_sub"), TI_STR)
    return cp

// Dynamic string copy: temporarily point the allocator and the interpreter's
// current-arena global at the parent, let str_sub allocate/copy there, then
// restore the child. The scalar cell is the allocator's authoritative current
// arena; the global keeps the interpreter and future region code in sync.
fn rp_emit_str_sub_value(src: int) -> int:
    if src < 0:
        return -1
    lenv := new_ir_var("_merge_str_len", TI_INT)
    emit(IR_CALL, lenv, src, 1, str_intern("str_len"), TI_INT)
    zv := new_ir_var("_merge_zero", TI_INT)
    emit(IR_CONST, zv, 0, 0, 0, TI_INT)
    c0 := rp_emit_merge_arg(src, TI_STR)
    c1 := rp_emit_merge_arg(zv, TI_INT)
    c2 := rp_emit_merge_arg(lenv, TI_INT)
    cp := new_ir_var("_merge_str", TI_STR)
    emit(IR_CALL, cp, c0, 3, str_intern("str_sub"), TI_STR)
    return cp

// Switch the allocator's current arena to the parent. Returns the saved child
// id, or -1 when the program has no arena runtime (global heap path). On an
// invalid setup returns -2.
fn rp_emit_parent_enter(parent: int, child: int) -> int:
    if parent < 0:
        return -1
    scalars := rp_global_var_named("g_arena_scalars")
    cav := rp_global_var_named("g_current_arena")
    if scalars < 0:
        return -1
    if child < 0 || cav < 0:
        return -2
    zv := new_ir_var("_merge_zero", TI_INT)
    emit(IR_CONST, zv, 0, 0, 0, TI_INT)
    a0 := rp_emit_merge_arg(scalars, TI_STR)
    a1 := rp_emit_merge_arg(zv, TI_INT)
    saved := new_ir_var("_merge_saved", TI_INT)
    emit(IR_CALL, saved, a0, 2, str_intern("cell_load"), TI_INT)
    b0 := rp_emit_merge_arg(scalars, TI_STR)
    b1 := rp_emit_merge_arg(zv, TI_INT)
    b2 := rp_emit_merge_arg(parent, TI_INT)
    emit(IR_CALL, -1, b0, 3, str_intern("cell_store"), TI_INT)
    emit(IR_STORE, -1, cav, parent, 0, 0)
    return saved

fn rp_emit_parent_leave(saved: int) -> int:
    if saved < 0:
        return 1
    scalars := rp_global_var_named("g_arena_scalars")
    cav := rp_global_var_named("g_current_arena")
    if scalars < 0 || cav < 0:
        return 0
    zv := new_ir_var("_merge_zero", TI_INT)
    emit(IR_CONST, zv, 0, 0, 0, TI_INT)
    d0 := rp_emit_merge_arg(scalars, TI_STR)
    d1 := rp_emit_merge_arg(zv, TI_INT)
    d2 := rp_emit_merge_arg(saved, TI_INT)
    emit(IR_CALL, -1, d0, 3, str_intern("cell_store"), TI_INT)
    emit(IR_STORE, -1, cav, saved, 0, 0)
    return 1

// Copy one string value into the parent arena and return the new variable.
fn rp_emit_string_value_copy(src: int, parent: int, child: int) -> int:
    if src < 0:
        return -1
    saved := rp_emit_parent_enter(parent, child)
    if saved == -2:
        return -1
    cp := rp_emit_str_sub_value(src)
    if rp_emit_parent_leave(saved) == 0:
        return -1
    return cp

fn rp_emit_string_switch_copy(dest: int, src: int, parent: int, child: int) -> int:
    if dest < 0:
        return 0
    cp := rp_emit_string_value_copy(src, parent, child)
    if cp < 0:
        return 0
    emit(IR_STORE, -1, dest, cp, 0, 0)
    return 1

// Literal string copies were materialized in the parent arena at the IF entry.
// Each assigning branch only rebinds the outer slot to its precomputed copy.
fn rp_emit_string_merge(sg: int, copy1: int, copy2: int, parent_var: int,
                        range_start: int, range_end: int) -> int:
    dest := region_plan_merge_name_of(sg)
    if dest < 0:
        return 0
    src : ., mut = -1
    lit : ., mut = -1
    ni : ., mut = range_start
    loop:
        if ni >= range_end:
            break
        op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
        s1 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)
        s2 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S2)
        if op == IR_STORE && s1 == dest && irv_type(s2) == TI_STR:
            src = s2
            lit = -1
            pv := cell_load(g_df_var_producer, s2 * 8)
            if pv >= 0 && cell_load(g_df_nodes, pv * ESZ_DFNODE + OFF_DF_OPCODE) == IR_CONST:
                lit = cell_load(g_df_nodes, pv * ESZ_DFNODE + OFF_DF_S1)
        ni = ni + 1
    if src < 0:
        return 0
    if region_plan_merge_str1_of(sg) < 0:
        child := cell_load(g_sg_arena_var, sg * 8)
        return rp_emit_string_switch_copy(dest, src, parent_var, child)
    if lit < 0:
        return 0
    cp : ., mut = -1
    if lit == region_plan_merge_str1_of(sg):
        cp = copy1
    else if lit == region_plan_merge_str2_of(sg):
        cp = copy2
    if cp < 0:
        return 0
    emit(IR_STORE, -1, dest, cp, 0, 0)
    return 1

fn region_plan_emit_merge(sg: int, copy_var: int, copy_instr: int,
                          str1_var: int, str2_var: int, parent_var: int,
                          range_start: int, range_end: int) -> int:
    kind := region_plan_merge_kind_of(sg)
    if kind < 0:
        return 0
    if kind == 3:
        return rp_emit_string_merge(sg, str1_var, str2_var, parent_var, range_start, range_end)
    if copy_var < 0 || copy_instr < 0:
        return 0
    an : ., mut = -1
    ni : ., mut = range_start
    loop:
        if ni >= range_end:
            break
        op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
        if subgraph_containing(ni) == sg:
            if kind == 1:
                if op == IR_ALLOC_STRUCT:
                    an = ni
                    break
            else:
                if op == IR_ALLOC_ARRAY:
                    an = ni
                    break
        ni = ni + 1
    if an < 0:
        return 0
    alloc_dest := cell_load(g_df_nodes, an * ESZ_DFNODE + OFF_DF_DEST)
    dest : ., mut = -1
    ni = range_start
    loop:
        if ni >= range_end:
            break
        op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
        s1 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)
        s2 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S2)
        if op == IR_STORE && s2 == alloc_dest && s1 >= 0:
            dest = s1
            break
        ni = ni + 1
    if dest < 0:
        return 0
    cnt : ., mut = 0
    if kind == 0:
        at := irv_type(alloc_dest)
        if at < 0 || at >= g_type_count || get_type_kind(at) != TYP_ARRAY:
            return 0
        cnt = cell_load(g_df_nodes, an * ESZ_DFNODE + OFF_DF_S1)
        elem := get_type_data(at)
        if cnt < 0 || rp_scalar_elem(elem) == 0:
            return 0
        // The copy allocation was emitted with the planned element count and
        // its size already charged to the parent arena; only the type row is
        // patched.
        irv_set_type(copy_var, alloc_type(TYP_ARRAY, elem, cnt))
        child_av := cell_load(g_sg_arena_var, sg * 8)
        elem_str := rp_string_ti(elem)
        if cnt <= 8:
            i : ., mut = 0
            loop:
                if i >= cnt:
                    break
                ev := new_ir_var("_merge_elem", elem)
                emit(IR_LOAD_INDEX, ev, alloc_dest, 0, i, elem)
                if elem_str != 0:
                    cp := rp_emit_string_value_copy(ev, parent_var, child_av)
                    if cp < 0:
                        return 0
                    emit(IR_STORE_INDEX, -1, copy_var, cp, i, 0)
                else:
                    emit(IR_STORE_INDEX, -1, copy_var, ev, i, 0)
                i = i + 1
        else:
            // Constant long arrays copy through a small runtime loop instead
            // of unrolling thousands of instructions. The loop lives inside
            // the assigning branch and only touches the two parent/child
            // buffers.
            iv := new_ir_var("_merge_i", TI_INT)
            zv := new_ir_var("_merge_zero", TI_INT)
            emit(IR_CONST, zv, 0, 0, 0, TI_INT)
            emit(IR_STORE, -1, iv, zv, 0, 0)
            cv := new_ir_var("_merge_cnt", TI_INT)
            emit(IR_CONST, cv, cnt, 0, 0, TI_INT)
            one := new_ir_var("_merge_one", TI_INT)
            emit(IR_CONST, one, 1, 0, 0, TI_INT)
            head := new_label()
            body := new_label()
            done := new_label()
            emit(IR_JUMP, -1, head, 0, 0, 0)
            emit(IR_LABEL, -1, head, 0, 0, 0)
            cond := new_ir_var("_merge_cond", TI_BOOL)
            emit(IR_BINARY, cond, iv, cv, OP_LT, 0)
            emit_cond_match(cond, done, body)
            emit(IR_LABEL, -1, body, 0, 0, 0)
            ev := new_ir_var("_merge_elem", elem)
            emit(IR_LOAD_INDEX_VAR, ev, alloc_dest, iv, 0, elem)
            if elem_str != 0:
                cp := rp_emit_string_value_copy(ev, parent_var, child_av)
                if cp < 0:
                    return 0
                emit(IR_STORE_INDEX_VAR, cp, copy_var, iv, 0, 0)
            else:
                emit(IR_STORE_INDEX_VAR, ev, copy_var, iv, 0, 0)
            nv := new_ir_var("_merge_next", TI_INT)
            emit(IR_BINARY, nv, iv, one, OP_ADD, 0)
            emit(IR_STORE, -1, iv, nv, 0, 0)
            emit(IR_JUMP, -1, head, 0, 0, 0)
            emit(IR_LABEL, -1, done, 0, 0, 0)
    else if kind == 1:
        name := region_plan_merge_name_of(sg)
        si := find_struct_by_name(name)
        if si < 0:
            return 0
        cnt = si_field_count(si)
        if cnt <= 0 || cnt > 64:
            return 0
        child_av := cell_load(g_sg_arena_var, sg * 8)
        i : ., mut = 0
        loop:
            if i >= cnt:
                break
            ft := struct_row_field_ti(si, i)
            ev := new_ir_var("_merge_field", ft)
            emit(IR_LOAD_FIELD, ev, alloc_dest, 0, i, 0)
            if rp_string_ti(ft) != 0:
                cp := rp_emit_string_value_copy(ev, parent_var, child_av)
                if cp < 0:
                    return 0
                emit(IR_STORE_FIELD, -1, copy_var, cp, i, 0)
            else:
                emit(IR_STORE_FIELD, -1, copy_var, ev, i, 0)
            i = i + 1
    else:
        cnt = cell_load(g_df_nodes, an * ESZ_DFNODE + OFF_DF_S1)
        if cnt <= 0 || cnt > 64:
            return 0
        irv_set_type(copy_var, irv_type(alloc_dest))
        i : ., mut = 0
        loop:
            if i >= cnt:
                break
            ft : ., mut = TI_INT
            fi : ., mut = range_start
            loop:
                if fi >= range_end:
                    break
                op := cell_load(g_df_nodes, fi * ESZ_DFNODE + OFF_DF_OPCODE)
                s1 := cell_load(g_df_nodes, fi * ESZ_DFNODE + OFF_DF_S1)
                s2 := cell_load(g_df_nodes, fi * ESZ_DFNODE + OFF_DF_S2)
                s3 := cell_load(g_df_nodes, fi * ESZ_DFNODE + OFF_DF_S3)
                if op == IR_STORE_FIELD && s1 == alloc_dest && s3 == i:
                    ft = irv_type(s2)
                fi = fi + 1
            ev := new_ir_var("_merge_field", ft)
            emit(IR_LOAD_FIELD, ev, alloc_dest, 0, i, 0)
            if rp_string_ti(ft) != 0:
                child_av2 := cell_load(g_sg_arena_var, sg * 8)
                cp := rp_emit_string_value_copy(ev, parent_var, child_av2)
                if cp < 0:
                    return 0
                emit(IR_STORE_FIELD, -1, copy_var, cp, i, 0)
            else:
                emit(IR_STORE_FIELD, -1, copy_var, ev, i, 0)
            i = i + 1
    emit(IR_STORE, -1, dest, copy_var, 0, 0)
    return 1

// Emit the delayed reset of a share slot after consumer SG `cg` has closed its
// own arena. The share slot is current again at this point; resetting it
// returns the runtime to the parent before the next parent allocation.
fn region_plan_emit_share_after(cg: int):
    if g_plan_share_count <= 0:
        return
    // Descending SG = innermost share first (LIFO).
    s : ., mut = g_sg_count - 1
    loop:
        if s < 0:
            return
        if region_plan_is_share(s) != 0:
            if cell_load(g_plan_share_reset_mode, s * 8) == 0 && cell_load(g_plan_share_reset_event, s * 8) == cg:
                av := cell_load(g_sg_arena_var, s * 8)
                if av < 0:
                    check_error(EC_B_LIFETIME, "share reset lost its slot variable", 0, 0)
                    return
                emit(IR_ARENA_RESET, -1, av, 0, 0, 0)
                g_plan_share_reset_emitted = g_plan_share_reset_emitted + 1
        s = s - 1

fn region_plan_emit_share_resets(lbl: int):
    if g_plan_share_count <= 0:
        return
    s : ., mut = g_sg_count - 1
    loop:
        if s < 0:
            return
        if region_plan_is_share(s) != 0:
            if cell_load(g_plan_share_reset_mode, s * 8) == 1 && cell_load(g_plan_share_reset_label, s * 8) == lbl:
                av := cell_load(g_sg_arena_var, s * 8)
                if av < 0:
                    check_error(EC_B_LIFETIME, "share label lost its slot variable", 0, 0)
                    return
                emit(IR_ARENA_RESET, -1, av, 0, 0, 0)
                g_plan_share_reset_emitted = g_plan_share_reset_emitted + 1
        s = s - 1

// Overlapping share slots nest at runtime. Defer an outer share's reset to the
// latest reset point of any share created inside it, and reset all slots that
// share an event in descending SG order (innermost first).
fn rp_share_effective_prepare():
    n := g_plan_share_count
    if n <= 0:
        return
    ssg := alloc(n * 8)
    sstart := alloc(n * 8)
    seff := alloc(n * 8)
    srm := alloc(n * 8)
    srl := alloc(n * 8)
    sre := alloc(n * 8)
    i : ., mut = 0
    sg : ., mut = 0
    loop:
        if sg >= g_sg_count:
            break
        if region_plan_is_share(sg) != 0:
            if i < n:
                cell_store(ssg, i * 8, sg)
                cell_store(sstart, i * 8, cell_load(g_sgs, sg * ESZ_SG + OFF_SG_NSTART))
                cell_store(seff, i * 8, cell_load(g_plan_share_own_point, sg * 8))
                cell_store(srm, i * 8, cell_load(g_plan_share_reset_mode, sg * 8))
                cell_store(srl, i * 8, cell_load(g_plan_share_reset_label, sg * 8))
                cell_store(sre, i * 8, cell_load(g_plan_share_reset_event, sg * 8))
                i = i + 1
        sg = sg + 1
    if i != n:
        return
    changed : ., mut = 1
    guard : ., mut = 0
    loop:
        if changed == 0:
            break
        guard = guard + 1
        if guard > n * 2 + 4:
            break
        changed = 0
        j : ., mut = 0
        loop:
            if j >= n:
                break
            parent : ., mut = -1
            k : ., mut = j - 1
            loop:
                if k < 0:
                    break
                if cell_load(seff, k * 8) > cell_load(sstart, j * 8):
                    parent = k
                    break
                k = k - 1
            if parent >= 0 && cell_load(seff, parent * 8) < cell_load(seff, j * 8):
                cell_store(seff, parent * 8, cell_load(seff, j * 8))
                cell_store(srm, parent * 8, cell_load(srm, j * 8))
                cell_store(srl, parent * 8, cell_load(srl, j * 8))
                cell_store(sre, parent * 8, cell_load(sre, j * 8))
                changed = 1
            j = j + 1
    i = 0
    loop:
        if i >= n:
            return
        s := cell_load(ssg, i * 8)
        cell_store(g_plan_share_reset_mode, s * 8, cell_load(srm, i * 8))
        cell_store(g_plan_share_reset_label, s * 8, cell_load(srl, i * 8))
        cell_store(g_plan_share_reset_event, s * 8, cell_load(sre, i * 8))
        i = i + 1

fn lazy_loop_ancestor(node: int) -> int:
    sg : ., mut = subgraph_containing(node)
    loop:
        if sg < 0:
            return -1
        k := cell_load(g_sgs, sg * ESZ_SG + OFF_SG_KIND)
        if k == SG_LOOP || k == SG_FOR:
            return sg
        sg = cell_load(g_sgs, sg * ESZ_SG + OFF_SG_PARENT)
    return -1

fn lazy_pts_only_local(var: int, cs: int, cc: int) -> int:
    if var < 0 || rp_var_may_point(var) == 0:
        return 0
    found : ., mut = 0
    ai : ., mut = 0
    loop:
        if ai >= g_pa_alloc_count:
            return found
        if pa_pts_has(var, ai) != 0:
            an := cell_load(g_pa_alloc_nodes, ai * 8)
            if an < cs || an >= cs + cc:
                return 0
            found = 1
        ai = ai + 1
    return 0

// A deferred callee may allocate/write local aggregates, but must not read
// g_current_arena, write globals, call anything, use unsafe, form pointers that
// escape, or store through a parameter/external pointer. Local array/struct
// writes are allowed because the callee's own function arena owns them.
fn lazy_pointer_arg_safe(av: int) -> int:
    ti := irv_type(av)
    if ti < 0 || ti >= g_type_count:
        return 0
    k := get_type_kind(ti)
    if k == TYP_ARRAY:
        if rp_scalar_elem(get_type_data(ti)) == 0:
            return 0
    else if k != TYP_PTR && k != TYP_REF:
        return 0
    if k != TYP_ARRAY && rp_var_may_point(av) == 0:
        return 0
    found : ., mut = 0
    ai : ., mut = 0
    loop:
        if ai >= g_pa_alloc_count:
            return found
        if pa_pts_has(av, ai) != 0:
            an := cell_load(g_pa_alloc_nodes, ai * 8)
            if rc_releasing_region(an) >= 0:
                return 0
            found = 1
        ai = ai + 1
    return 0

fn lazy_memory_write(op: int) -> int:
    if op == IR_STORE_FIELD || op == IR_STORE_INDEX || op == IR_STORE_INDEX_VAR || op == IR_STORE_PTR:
        return 1
    return 0

fn lazy_op_may_mutate_memory(op: int) -> int:
    if lazy_memory_write(op) != 0:
        return 1
    if op == IR_CALL || op == IR_CALL_EXTERN || op == IR_SPAWN || op == IR_HOTPATCH_ROUTE || op == IR_DYN_DISPATCH || op == IR_YIELD || op == IR_AWAIT:
        return 1
    return 0

// Pointer arguments are captured by value, so the pointee's contents must not
// change between the original call site and the force point. Direct scalar
// stores are fine (their values are captured); aggregate/pointer stores and
// any other call could mutate the pointee.
fn lazy_range_pointee_stable(lo: int, hi: int, skip_call: int) -> int:
    ni : ., mut = lo
    loop:
        if ni >= hi:
            return 1
        if ni != skip_call:
            op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
            if lazy_op_may_mutate_memory(op) != 0:
                return 0
        ni = ni + 1
    return 1

// A loop memo may execute the call on a later iteration. The pointee must be
// stable for every dynamic pass through the loop, so no aggregate/pointer
// store and no other call may appear in the loop body.
fn lazy_loop_pointee_stable(ls: int, le: int, skip_call: int) -> int:
    ni : ., mut = ls
    loop:
        if ni >= le:
            return 1
        if ni != skip_call:
            op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
            if lazy_op_may_mutate_memory(op) != 0:
                return 0
        ni = ni + 1
    return 1

// Exact variable-read scan for a call-free callee body. Unused and literal
// fields (operators, field indices, label ids, sizes) must not be mistaken for
// variable reads; global var 0 in particular collides with every zero field.
fn lazy_node_reads_var(op: int, d: int, s1: int, s2: int, s3: int, aux: int, var: int) -> int:
    if op == IR_BINARY || op == IR_STORE_INDEX || op == IR_LOAD_INDEX_VAR || op == IR_STORE_FIELD:
        return s1 == var || s2 == var
    // Constant-index loads carry the index in the literal s3 field.
    if op == IR_LOAD_INDEX:
        return s1 == var
    if op == IR_STORE_INDEX_VAR:
        return d == var || s1 == var || s2 == var
    if op == IR_UNARY || op == IR_RETURN || op == IR_LOAD || op == IR_LOAD_FIELD || op == IR_LOAD_ENUM_TAG || op == IR_DEREF || op == IR_MATCH || op == IR_ARENA_RESET || op == IR_ARENA_CLEAR || op == IR_YIELD || op == IR_AWAIT || op == IR_DYN_TAG || op == IR_DYN_VAL || op == IR_DYN_PACK || op == IR_DYN_DISPATCH || op == IR_PTR_OF || op == IR_STR_OF || op == IR_I2F || op == IR_F2I || op == IR_LAZY_THUNK || op == IR_LAZY_FORCE:
        return s1 == var
    if op == IR_STORE:
        return s2 == var
    if op == IR_STORE_PTR:
        return s1 == var || s2 == var
    if op == IR_SLICE:
        return s1 == var || s2 == var || s3 == var
    if op == IR_BOUNDS_CHECK:
        if s1 == var:
            return 1
        if aux != 0 && s2 == var:
            return 1
        return 0
    if op == IR_ADDR_INDEX:
        return s1 == var || s2 == var
    if op == IR_REF:
        return s1 == var
    if op == IR_PHI:
        return s1 == var || s2 == var
    return 0

fn lazy_callee_reads_var(cs: int, cc: int, var: int) -> int:
    if var < 0:
        return 0
    ni : ., mut = cs
    loop:
        if ni >= cs + cc:
            return 0
        op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
        d := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_DEST)
        s1 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)
        s2 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S2)
        s3 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S3)
        aux := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_AUX)
        if lazy_node_reads_var(op, d, s1, s2, s3, aux, var) != 0:
            return 1
        ni = ni + 1
    return 0

fn lazy_callee_safe(fi: int) -> int:
    if fi < 0:
        return 0
    cs := cell_load(g_df_func_node_start, fi * 8)
    cc := cell_load(g_df_func_node_count, fi * 8)
    if cs < 0 || cc <= 0:
        return 0
    cav := rp_global_var_named("g_current_arena")
    // Any mutable global read may observe a different value at the force
    // point. The language has no immutable-global marker in the IR table, so
    // keep every global-reading callee eager; callers that need laziness pass
    // the value as an argument, which is captured at the call site.
    gi : ., mut = 0
    loop:
        if gi >= g_ir_global_count:
            break
        gv := cell_load(g_ir_globals, gi * 24 + 8)
        if gv >= 0 && lazy_callee_reads_var(cs, cc, gv) != 0:
            return 0
        gi = gi + 1
    ni : ., mut = cs
    loop:
        if ni >= cs + cc:
            break
        op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
        d := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_DEST)
        s1 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)
        s2 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S2)
        if op == IR_CALL || op == IR_CALL_EXTERN || op == IR_SPAWN || op == IR_YIELD || op == IR_AWAIT || op == IR_HOTPATCH_ROUTE || op == IR_DYN_DISPATCH:
            return 0
        if op == IR_STORE_PTR || op == IR_PTR_OF || op == IR_STR_OF || op == IR_ADDR_INDEX || op == IR_SLICE || op == IR_REF || op == IR_FNADDR:
            return 0
        if op == IR_ALLOC_AT || op == IR_ARENA_CLEAR:
            return 0
        if op == IR_STORE:
            if s1 >= 0 && rc_is_global_var(s1) != 0:
                return 0
            if s1 == cav:
                return 0
        if op == IR_STORE_INDEX || op == IR_STORE_FIELD:
            if lazy_pts_only_local(s1, cs, cc) == 0:
                return 0
        if op == IR_STORE_INDEX_VAR:
            if lazy_pts_only_local(s1, cs, cc) == 0:
                return 0
        ni = ni + 1
    d : ., mut = 0
    loop:
        if d >= g_sg_count:
            return 1
        ds := cell_load(g_sgs, d * ESZ_SG + OFF_SG_NSTART)
        if ds >= cs && ds < cs + cc:
            if cell_load(g_sgs, d * ESZ_SG + OFF_SG_KIND) == SG_UNSAFE:
                return 0
        d = d + 1
    return 1

fn lazy_callee_no_alloc(fi: int) -> int:
    if fi < 0:
        return 0
    cs := cell_load(g_df_func_node_start, fi * 8)
    cc := cell_load(g_df_func_node_count, fi * 8)
    if cs < 0 || cc <= 0:
        return 0
    ni : ., mut = cs
    loop:
        if ni >= cs + cc:
            return 1
        op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
        if op == IR_ALLOC_ARRAY || op == IR_ALLOC_STRUCT || op == IR_ALLOC_AT || op == IR_ARENA_CLEAR:
            return 0
        if op == IR_CALL || op == IR_CALL_EXTERN || op == IR_SPAWN || op == IR_YIELD || op == IR_AWAIT:
            return 0
        ni = ni + 1
    return 0

// Select zero-argument pure scalar calls whose single force point sits in a
// conditional branch/loop body within the same loop iteration. The plan is
// keyed by the AST call node id; Phase B defers the call to the force point.
fn lazy_last_label(node: int, nstart: int) -> int:
    r : ., mut = -1
    tj : ., mut = nstart
    loop:
        if tj >= node:
            return r
        if cell_load(g_df_nodes, tj * ESZ_DFNODE + OFF_DF_OPCODE) == IR_LABEL:
            r = tj
        tj = tj + 1
    return r

fn lazy_arg_invariant(av: int, ls: int, le: int, nstart: int, ncount: int) -> int:
    if av < 0:
        return 0
    // A global can be rewritten by any call in the loop; its value at the
    // first force need not equal its value at the original call site.
    if rc_is_global_var(av) != 0:
        return 0
    // If the slot's address escapes anywhere in the function, an indirect
    // store or a callee can mutate it across the hoisted region.
    ni : ., mut = nstart
    loop:
        if ni >= nstart + ncount:
            break
        op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
        s1 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)
        if (op == IR_REF || op == IR_ADDR_INDEX) && s1 == av:
            return 0
        ni = ni + 1
    // Any write to the argument slot inside the loop makes it non-invariant.
    ni = ls
    loop:
        if ni >= le:
            break
        op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
        s1 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)
        d := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_DEST)
        if op == IR_STORE && s1 == av:
            return 0
        if (op == IR_STORE_INDEX || op == IR_STORE_INDEX_VAR || op == IR_STORE_FIELD) && s1 == av:
            return 0
        if op == IR_STORE_INDEX_VAR && d == av:
            return 0
        ni = ni + 1
    pv := cell_load(g_df_var_producer, av * 8)
    if pv < ls || pv >= le:
        return 1
    op := cell_load(g_df_nodes, pv * ESZ_DFNODE + OFF_DF_OPCODE)
    if op == IR_CONST || op == IR_CONST_BIG:
        return 1
    if op == IR_STORE:
        sv := cell_load(g_df_nodes, pv * ESZ_DFNODE + OFF_DF_S2)
        pv2 := cell_load(g_df_var_producer, sv * 8)
        if pv2 >= 0:
            op2 := cell_load(g_df_nodes, pv2 * ESZ_DFNODE + OFF_DF_OPCODE)
            if op2 == IR_CONST || op2 == IR_CONST_BIG:
                return 1
    return 0

fn lazy_uses_inside(var: int, lo: int, hi: int, nstart: int, ncount: int) -> int:
    if var < 0:
        return 0
    uses : ., mut = 0
    ni : ., mut = nstart
    loop:
        if ni >= nstart + ncount:
            return uses
        if rp_if_reads_var(ni, 1, var) != 0:
            if ni < lo || ni >= hi:
                return -1
            uses = uses + 1
        ni = ni + 1
    return uses

fn lazy_memo_analyze():
    fi : ., mut = 0
    loop:
        if fi >= g_ir_func_count:
            return
        nstart := cell_load(g_df_func_node_start, fi * 8)
        ncount := cell_load(g_df_func_node_count, fi * 8)
        if nstart < 0 || ncount <= 0:
            fi = fi + 1
            continue
        ni : ., mut = nstart
        loop:
            if ni >= nstart + ncount:
                break
            op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
            if op != IR_CALL:
                ni = ni + 1
                continue
            lsg := lazy_loop_ancestor(ni)
            if lsg < 0:
                ni = ni + 1
                continue
            ls := cell_load(g_sgs, lsg * ESZ_SG + OFF_SG_NSTART)
            le := cell_load(g_sgs, lsg * ESZ_SG + OFF_SG_EXIT)
            ac := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S2)
            s1 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)
            s3 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S3)
            dest := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_DEST)
            if dest < 0 || rp_scalar_elem(irv_type(dest)) == 0:
                ni = ni + 1
                continue
            ast := lazy_ast_get(ni)
            if ast < 0:
                ni = ni + 1
                continue
            cfi := rc_func_by_name(s3)
            if cfi < 0 || lazy_callee_safe(cfi) == 0:
                ni = ni + 1
                continue
            args_ok : ., mut = 1
            has_ptr_arg : ., mut = 0
            ai : ., mut = 0
            loop:
                if ai >= ac:
                    break
                av := s1 + ai
                if av < 0 || lazy_arg_invariant(av, ls, le, nstart, ncount) == 0:
                    args_ok = 0
                    break
                if rp_scalar_elem(irv_type(av)) == 0:
                    if lazy_pointer_arg_safe(av) == 0:
                        args_ok = 0
                        break
                    has_ptr_arg = 1
                ai = ai + 1
            if args_ok == 0:
                ni = ni + 1
                continue
            if has_ptr_arg != 0 && lazy_loop_pointee_stable(ls, le, ni) == 0:
                ni = ni + 1
                continue
            // Follow thunk/force; every use must stay inside the loop.
            res : ., mut = dest
            tj : ., mut = nstart
            loop:
                if tj >= nstart + ncount:
                    break
                if cell_load(g_df_nodes, tj * ESZ_DFNODE + OFF_DF_OPCODE) == IR_LAZY_THUNK:
                    if cell_load(g_df_nodes, tj * ESZ_DFNODE + OFF_DF_S1) == res:
                        res = cell_load(g_df_nodes, tj * ESZ_DFNODE + OFF_DF_DEST)
                        break
                tj = tj + 1
            forces : ., mut = 0
            tj = nstart
            loop:
                if tj >= nstart + ncount:
                    break
                if cell_load(g_df_nodes, tj * ESZ_DFNODE + OFF_DF_OPCODE) == IR_LAZY_FORCE:
                    if cell_load(g_df_nodes, tj * ESZ_DFNODE + OFF_DF_S1) == res:
                        forces = forces + 1
                tj = tj + 1
            if forces <= 0:
                ni = ni + 1
                continue
            // Validate each force's uses (or its local store target) stay in loop.
            ok : ., mut = 1
            tj = nstart
            loop:
                if tj >= nstart + ncount:
                    break
                if cell_load(g_df_nodes, tj * ESZ_DFNODE + OFF_DF_OPCODE) == IR_LAZY_FORCE:
                    if cell_load(g_df_nodes, tj * ESZ_DFNODE + OFF_DF_S1) == res:
                        fd := cell_load(g_df_nodes, tj * ESZ_DFNODE + OFF_DF_DEST)
                        target : ., mut = fd
                        using : ., mut = -1
                        scan : ., mut = tj + 1
                        loop:
                            if scan >= nstart + ncount:
                                break
                            if rp_if_reads_var(scan, 1, fd) != 0:
                                using = scan
                                break
                            scan = scan + 1
                        if using >= 0:
                            op2 := cell_load(g_df_nodes, using * ESZ_DFNODE + OFF_DF_OPCODE)
                            if op2 == IR_STORE:
                                t2 := cell_load(g_df_nodes, using * ESZ_DFNODE + OFF_DF_S1)
                                if t2 >= 0 && rc_is_global_var(t2) == 0:
                                    target = t2
                        u := lazy_uses_inside(target, ls, le, nstart, ncount)
                        if u <= 0:
                            ok = 0
                            break
                tj = tj + 1
            if ok == 0:
                ni = ni + 1
                continue
            lazy_memo_add(ast, lsg, s3, irv_type(dest), s1, ac, 0)
            ni = ni + 1
        fi = fi + 1

fn lazy_plan_analyze():
    fi : ., mut = 0
    loop:
        if fi >= g_ir_func_count:
            return
        nstart := cell_load(g_df_func_node_start, fi * 8)
        ncount := cell_load(g_df_func_node_count, fi * 8)
        if nstart < 0 || ncount <= 0:
            fi = fi + 1
            continue
        ni : ., mut = nstart
        loop:
            if ni >= nstart + ncount:
                break
            op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
            if op != IR_CALL:
                ni = ni + 1
                continue
            ac := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S2)
            s1 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1)
            s3 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S3)
            dest := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_DEST)
            if dest < 0:
                ni = ni + 1
                continue
            ti := irv_type(dest)
            if rp_scalar_elem(ti) == 0:
                ni = ni + 1
                continue
            ast := lazy_ast_get(ni)
            if ast < 0:
                ni = ni + 1
                continue
            cfi := rc_func_by_name(s3)
            if cfi < 0 || lazy_callee_safe(cfi) == 0:
                ni = ni + 1
                continue
            // Follow the eager lazy-thunk wrapper emitted in Phase A.
            res : ., mut = dest
            tj : ., mut = nstart
            loop:
                if tj >= nstart + ncount:
                    break
                if cell_load(g_df_nodes, tj * ESZ_DFNODE + OFF_DF_OPCODE) == IR_LAZY_THUNK:
                    if cell_load(g_df_nodes, tj * ESZ_DFNODE + OFF_DF_S1) == res:
                        res = cell_load(g_df_nodes, tj * ESZ_DFNODE + OFF_DF_DEST)
                        break
                tj = tj + 1
            fcount : ., mut = 0
            force_node : ., mut = -1
            fd : ., mut = -1
            tj = nstart
            loop:
                if tj >= nstart + ncount:
                    break
                if cell_load(g_df_nodes, tj * ESZ_DFNODE + OFF_DF_OPCODE) == IR_LAZY_FORCE:
                    if cell_load(g_df_nodes, tj * ESZ_DFNODE + OFF_DF_S1) == res:
                        fcount = fcount + 1
                        force_node = tj
                        fd = cell_load(g_df_nodes, tj * ESZ_DFNODE + OFF_DF_DEST)
                tj = tj + 1
            if fcount != 1 || fd < 0:
                ni = ni + 1
                continue
            // A forced value assigned to a local slot: defer the call to the
            // slot's unique use, so `v := pure()` is not evaluated at the LET.
            store_node : ., mut = -1
            store_target : ., mut = -1
            tj = force_node + 1
            loop:
                if tj >= nstart + ncount:
                    break
                if rp_if_reads_var(tj, 1, fd) != 0:
                    if cell_load(g_df_nodes, tj * ESZ_DFNODE + OFF_DF_OPCODE) == IR_STORE:
                        store_node = tj
                        store_target = cell_load(g_df_nodes, tj * ESZ_DFNODE + OFF_DF_S1)
                    break
                tj = tj + 1
            if store_node >= 0 && store_target >= 0 && rc_is_global_var(store_target) == 0:
                // The defining store itself counts as a use in
                // compute_usage_counts; the read-use scan below starts after
                // that store and rejects any later write to the slot.
                fd = store_target
                force_node = store_node
            use : ., mut = -1
            last_use : ., mut = -1
            uc : ., mut = 0
            reads : ., mut = 0
            writes : ., mut = 0
            block0 : ., mut = -1
            same_block : ., mut = 1
            tj = force_node + 1
            loop:
                if tj >= nstart + ncount:
                    break
                op2 := cell_load(g_df_nodes, tj * ESZ_DFNODE + OFF_DF_OPCODE)
                s1b := cell_load(g_df_nodes, tj * ESZ_DFNODE + OFF_DF_S1)
                if op2 == IR_STORE && s1b == fd:
                    writes = writes + 1
                    uc = uc + 2
                else if rp_if_reads_var(tj, 1, fd) != 0:
                    reads = reads + 1
                    uc = uc + 1
                    if use < 0:
                        use = tj
                        block0 = lazy_last_label(tj, nstart)
                    else if lazy_last_label(tj, nstart) != block0:
                        same_block = 0
                    last_use = tj
                tj = tj + 1
            if uc < 1 || use < 0:
                ni = ni + 1
                continue
            // Any later write to the bound slot would either clobber the
            // deferred result or make an earlier def win for a later
            // assignment. Keep that shape eager.
            if writes != 0:
                ni = ni + 1
                continue
            // Reads in one basic block reuse the call emitted at the first
            // force. Reads split across blocks use a runtime memo flag instead:
            // every read guards, the first one evaluates, later ones reuse.
            memo_use : ., mut = 0
            if same_block == 0:
                if writes != 0 || reads < 2:
                    ni = ni + 1
                    continue
                if lazy_memo_index_of_ast(ast) >= 0:
                    // The loop hoist memo already covers this call.
                    ni = ni + 1
                    continue
                csg0 := subgraph_containing(ni)
                la0 := lazy_loop_ancestor(ni)
                ok_uses : ., mut = 1
                tj = force_node + 1
                loop:
                    if tj >= nstart + ncount:
                        break
                    if rp_if_reads_var(tj, 1, fd) != 0:
                        if lazy_loop_ancestor(tj) != la0:
                            ok_uses = 0
                            break
                        usg := subgraph_containing(tj)
                        if usg != csg0 && rc_sg_is_ancestor(csg0, usg) == 0:
                            ok_uses = 0
                            break
                    tj = tj + 1
                if ok_uses == 0:
                    ni = ni + 1
                    continue
                memo_use = 1
            // Argument expressions are still evaluated at the original site;
            // Phase B captures scalar values into stable temporaries, so a
            // later mutation cannot change the deferred call's inputs. Pointer
            // arguments are rejected because their pointee may die before the
            // force point.
            args_ok : ., mut = 1
            has_ptr_arg : ., mut = 0
            ai : ., mut = 0
            loop:
                if ai >= ac:
                    break
                av := s1 + ai
                if av < 0:
                    args_ok = 0
                    break
                if rp_scalar_elem(irv_type(av)) == 0:
                    if lazy_pointer_arg_safe(av) == 0:
                        args_ok = 0
                        break
                    has_ptr_arg = 1
                ai = ai + 1
            if args_ok == 0:
                ni = ni + 1
                continue
            // The call is materialized at the first read, not at the local
            // store that merely binds the forced value. Scan through the last
            // read so a pointee mutation on any path to a force is caught.
            if has_ptr_arg != 0 && lazy_range_pointee_stable(ni + 1, last_use + 1, ni) == 0:
                ni = ni + 1
                continue
            if memo_use != 0:
                lazy_memo_add(ast, -1, s3, irv_type(dest), -1, ac, 1)
                ni = ni + 1
                continue
            target : ., mut = -1
            tj = nstart
            loop:
                if tj >= use:
                    break
                if cell_load(g_df_nodes, tj * ESZ_DFNODE + OFF_DF_OPCODE) == IR_LABEL:
                    target = tj
                tj = tj + 1
            if target <= ni:
                ni = ni + 1
                continue
            has_match : ., mut = 0
            tj = ni
            loop:
                if tj >= target:
                    break
                if cell_load(g_df_nodes, tj * ESZ_DFNODE + OFF_DF_OPCODE) == IR_MATCH:
                    has_match = 1
                    break
                tj = tj + 1
            if has_match == 0:
                ni = ni + 1
                continue
            if lazy_loop_ancestor(ni) != lazy_loop_ancestor(use):
                ni = ni + 1
                continue
            csg := subgraph_containing(ni)
            usg := subgraph_containing(use)
            if csg != usg && rc_sg_is_ancestor(csg, usg) == 0:
                ni = ni + 1
                continue
            lazy_plan_add(ast)
            ni = ni + 1
        fi = fi + 1

fn region_plan_analyze():
    region_plan_reset()
    // Phase B currently regenerates with ir_gen_all, which does not reproduce
    // the per-function monomorph/optional representation path. Keep those
    // programs on v1 until the shared generator is extracted.
    if g_optrep_on != 0:
        return
    // Monomorph instances are appended during Phase A; ir_gen_all does not
    // reproduce the per-function instance path exactly, so keep them on v1.
    if g_gen_instance_count > 0:
        return
    if g_cfg_region_plan_max_nodes > 0:
        total_nodes : ., mut = 0
        ti : ., mut = 0
        loop:
            if ti >= g_ir_func_count:
                break
            nc := cell_load(g_df_func_node_count, ti * 8)
            if nc > 0:
                total_nodes = total_nodes + nc
            ti = ti + 1
        if total_nodes > g_cfg_region_plan_max_nodes:
            return
    gs : ., mut = 0
    loop:
        if gs >= g_func_count:
            break
        if fi_generic_count(gs) > 0:
            return
        gs = gs + 1
    rp_share_bad_prepare()
    fi : ., mut = 0
    loop:
        if fi >= g_ir_func_count:
            break
        nstart := cell_load(g_df_func_node_start, fi * 8)
        ncount := cell_load(g_df_func_node_count, fi * 8)
        if nstart < 0 || ncount <= 0:
            fi = fi + 1
            continue
        rc_ctl_prepare(nstart, ncount)
        sg : ., mut = 0
        loop:
            if sg >= g_sg_count:
                break
            sg_start := cell_load(g_sgs, sg * ESZ_SG + OFF_SG_NSTART)
            sg_count := cell_load(g_sgs, sg * ESZ_SG + OFF_SG_NCOUNT)
            if sg_start >= nstart && sg_start < nstart + ncount:
                if cell_load(g_sgs, sg * ESZ_SG + OFF_SG_KIND) == SG_IF:
                    if rp_if_has_unsafe(sg_start, sg_count) == 0:
                        cav := rp_global_var_named("g_current_arena")
                        if rp_if_reads_var(sg_start, sg_count, cav) == 0:
                            string_planned : ., mut = 0
                            if rp_string_calls_ok(sg_start, sg_count) != 0:
                                if rp_if_string_merge_eligible(sg, sg_start, sg_count, nstart, ncount) != 0:
                                    region_plan_mark_merge(sg, g_rp_merge_kind, g_rp_merge_len, g_rp_merge_name, g_rp_merge_str1, g_rp_merge_str2)
                                    string_planned = 1
                            if string_planned == 0:
                                if rp_if_has_exit_or_effect(sg_start, sg_count) == 0:
                                    if rp_if_eligible(sg, sg_start, sg_count, nstart, ncount) != 0:
                                        region_plan_mark_split(sg)
                                    else:
                                        mc := rp_if_merge_eligible(sg, sg_start, sg_count, nstart, ncount, 0)
                                        if mc > 0:
                                            region_plan_mark_merge(sg, g_rp_merge_kind, g_rp_merge_len, g_rp_merge_name, g_rp_merge_str1, g_rp_merge_str2)
            sg = sg + 1
        fi = fi + 1

    // V2.3 share pass. Run after split/merge marks so the window can reject
    // merge copies landing in a candidate's slot. Candidates are processed in
    // SG order; a later merge candidate inside an earlier candidate's window
    // makes the earlier one ineligible, so the chosen share slots never
    // overlap. Non-overlapping sequential shares are allowed.
    fi = 0
    loop:
        if fi >= g_ir_func_count:
            break
        nstart := cell_load(g_df_func_node_start, fi * 8)
        ncount := cell_load(g_df_func_node_count, fi * 8)
        if nstart < 0 || ncount <= 0:
            fi = fi + 1
            continue
        rc_ctl_prepare(nstart, ncount)
        // Descending SG so a later (inner) share is marked before an earlier
        // candidate tests its window; later share allocations are then active
        // in the earlier window and no merge copy exists for them.
        sg : ., mut = g_sg_count - 1
        loop:
            if sg < 0:
                break
            sg_start := cell_load(g_sgs, sg * ESZ_SG + OFF_SG_NSTART)
            sg_count := cell_load(g_sgs, sg * ESZ_SG + OFF_SG_NCOUNT)
            if sg_start >= nstart && sg_start < nstart + ncount:
                if cell_load(g_sgs, sg * ESZ_SG + OFF_SG_KIND) == SG_IF:
                    if region_plan_is_split(sg) == 0:
                        if rp_if_share_eligible(sg, sg_start, sg_count, nstart, ncount) != 0:
                            if region_plan_is_merge(sg) != 0:
                                region_plan_unmark_merge(sg)
                            region_plan_mark_share(sg, g_rp_share_exit, g_rp_share_mode, g_rp_share_consumer, g_rp_share_reset_node)
            sg = sg - 1
        fi = fi + 1

    rp_share_effective_prepare()

    // Second pass: early clear for FUNC/LOOP/FOR/UNSAFE slots. Run after all
    // split marks so allocations in a split IF are not counted for the parent.
    // A parent-slot clear can coexist with share: the share slot is a separate
    // arena, and the clear pass's liveness sees every parent allocation use.
    // The clear is emitted at the label before the share reset at the same
    // point; arena_clear resets the parent metadata without switching current.
    fi = 0
    loop:
        if fi >= g_ir_func_count:
            break
        nstart := cell_load(g_df_func_node_start, fi * 8)
        ncount := cell_load(g_df_func_node_count, fi * 8)
        if nstart < 0 || ncount <= 0:
            fi = fi + 1
            continue
        rc_ctl_prepare(nstart, ncount)
        rp_pdom_prepare(nstart, ncount)
        sg : ., mut = 0
        loop:
            if sg >= g_sg_count:
                break
            sg_start := cell_load(g_sgs, sg * ESZ_SG + OFF_SG_NSTART)
            sg_count := cell_load(g_sgs, sg * ESZ_SG + OFF_SG_NCOUNT)
            if sg_start >= nstart && sg_start < nstart + ncount:
                k := cell_load(g_sgs, sg * ESZ_SG + OFF_SG_KIND)
                if k == SG_FUNC || k == SG_LOOP || k == SG_FOR || k == SG_UNSAFE:
                    lbl := rp_clear_candidate(sg, nstart, ncount, sg_start, sg_start + sg_count)
                    if lbl >= 0:
                        region_plan_mark_clear(lbl, sg)
            sg = sg + 1
        fi = fi + 1

    lazy_memo_analyze()
    lazy_plan_analyze()
