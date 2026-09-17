// === dataflow.cr ===
// Dataflow graph (.cir) construction and lowering to linear CFG (.ccr)
//
// The dataflow graph is built during IR generation. Each emit() call creates
// a DFNode with def-use edges tracked via g_df_var_producer[].
// After all IR is generated, lower_to_ccr() linearizes the graph into g_ir_instrs
// for consumption by the x86-64 backend.

// --- Initialization ---

fn init_df() {
    g_df_node_count = 0;
    g_df_edge_count = 0;
    g_df_cap = 0;
    g_df_node_cap = 0;
    g_df_edge_cap = 0;
    g_df_node_region_cap = 0;   // node region array rebuilt on grow
    g_cur_sg = -1;              // no region open yet
    g_last_state_node = -1;     // state chain starts empty per compile
    fi : ., mut = 0;
    loop {
        if fi >= g_func_count { break; }
        grow_df_arrays(fi + 1);
        w64(g_df_func_node_start, fi * 8, -1);
        w64(g_df_func_node_count, fi * 8, 0);
        fi = fi + 1;
    }
    vi : ., mut = 0;
    loop {
        if vi >= g_ir_var_count { break; }
        grow_df_arrays(vi + 1);
        w64(g_df_var_producer, vi * 8, -1);
        vi = vi + 1;
    }
}

// --- Subgraph management (bare pointer model) ---

fn sg_push(kind: int) {
    grow_sg(g_sg_count + 1);
    idx := g_sg_count;
    w64(g_sgs, idx * ESZ_SG + OFF_SG_KIND, kind);
    w64(g_sgs, idx * ESZ_SG + OFF_SG_ENTER, g_df_node_count);
    w64(g_sgs, idx * ESZ_SG + OFF_SG_EXIT, -1);
    w64(g_sgs, idx * ESZ_SG + OFF_SG_NSTART, g_df_node_count);
    w64(g_sgs, idx * ESZ_SG + OFF_SG_NCOUNT, 0);
    // Parent: find innermost currently open subgraph
    parent := -1;
    pi := idx - 1;
    loop { if pi < 0 { break; }
        if r64(g_sgs, pi * ESZ_SG + OFF_SG_EXIT) < 0 {  // still open
            parent = pi;
            break;
        }
        pi = pi - 1;
    }
    w64(g_sgs, idx * ESZ_SG + OFF_SG_PARENT, parent);
    g_cur_sg = idx;  // new innermost open region
    g_sg_count = idx + 1;
}

// sg_pop: close the last OPEN (EXIT<0) region, not g_sg_count-1.
// With the old code the count is never decremented, so df_end_func's pop
// would land on the same entry the ir_gen pop just closed, overwriting the
// innermost region's EXIT with the whole-function node count. Search back
// from the top for the entry whose EXIT is still -1, close exactly that one,
// and restore g_cur_sg to its parent.
fn sg_pop() {
    if g_sg_count <= 0 { return; }
    idx : ., mut = -1;
    pi := g_sg_count - 1;
    loop {
        if pi < 0 { break; }
        if r64(g_sgs, pi * ESZ_SG + OFF_SG_EXIT) < 0 { idx = pi; break; }
        pi = pi - 1;
    }
    if idx < 0 { return; }
    w64(g_sgs, idx * ESZ_SG + OFF_SG_EXIT, g_df_node_count);
    w64(g_sgs, idx * ESZ_SG + OFF_SG_NCOUNT,
        g_df_node_count - r64(g_sgs, idx * ESZ_SG + OFF_SG_NSTART));
    // Loop termination dependency: the region exit node (last node created in
    // the region, i.e. the exit label) must happen after the region's last
    // side effect — a VSDG state edge enforcing loop-exit ordering.
    // 循环终止依赖（kind=1）与链头推进**不在本处连接**——state 链统一在
    // 全部 IR 生成结束后重建（df_replay_state_chain；时点理由见该函数头注）：
    // 被调函数真纯度只有拿到全程序 IR 体才能算，链不能再边生成边连。
    g_cur_sg = r64(g_sgs, idx * ESZ_SG + OFF_SG_PARENT);
}

// --- Node creation ---

// R2 P5 Task 2（D19 单槽化）：`tk_term` = 类型项引用（g_type_terms 行号；-1 = 无项）、
// `tk_aux` = 辅码（旗标/宽度/计数/不可入项的原始行码；0 = 无），由**调用方**
// （唯一调用点 = ir_gen.cr 的 emit）经 `sh_tk_split` 派生后传入。本函数仍属 corec
// 侧（build_selfhost_native.py 的 corec_files），但**不引用任何前端/桥接符号**
// ——按「共享文件零前端依赖」纪律留余量（dataflow.cr 若某日并入 corearch 清单，
// 本函数零改动即可链接）。参数语义 = 「存储」：本函数只落槽，不解释、不校验、
// 不派生（派生规则单源 = ty_shadow.cr 的 sh_tk_split；码由 sh_dfn_code_of_slots 派生）。
fn df_create_node(opcode: int, dest: int, src1: int, src2: int, src3: int, tk_term: int, tk_aux: int) -> int {
    nid := g_df_node_count;
    grow_df_nodes(nid + 1);
    grow_df_node_region(nid + 1);
    w64(g_df_node_region, nid * 8, g_cur_sg);  // owning region (-1 = none)
    w64(g_df_nodes, nid * ESZ_DFNODE + OFF_DF_OPCODE, opcode);
    w64(g_df_nodes, nid * ESZ_DFNODE + OFF_DF_DEST, dest);
    w64(g_df_nodes, nid * ESZ_DFNODE + OFF_DF_S1, src1);
    w64(g_df_nodes, nid * ESZ_DFNODE + OFF_DF_S2, src2);
    w64(g_df_nodes, nid * ESZ_DFNODE + OFF_DF_S3, src3);
    w64(g_df_nodes, nid * ESZ_DFNODE + OFF_DF_TK, tk_term);   // R2 P5 Task 2：类型项引用
    w64(g_df_nodes, nid * ESZ_DFNODE + OFF_DF_AUX, tk_aux);   // R2 P5 Task 2：辅码
    w64(g_df_nodes, nid * ESZ_DFNODE + OFF_DF_FIRST_EDGE, -1);
    w64(g_df_nodes, nid * ESZ_DFNODE + OFF_DF_EDGE_COUNT, 0);
    g_df_node_count = nid + 1;

    // Record that this node produces `dest`
    if dest >= 0 {
        grow_df_arrays(dest + 1);
        w64(g_df_var_producer, dest * 8, nid);
    }

    // Add edges for src fields that are IR variables (based on opcode)
    // 第 6 参 = 辅码（IR_BOUNDS_CHECK 的 `!= 0` = 动态上限旗标——单槽化后旗标在
    // 辅码槽；见 df_connect_srcs 的 IR_BOUNDS_CHECK 分支）。
    df_connect_srcs(nid, opcode, src1, src2, src3, tk_aux);
    // VSDG state chain（kind=1）不在此连接——见 df_replay_state_chain 头注
    // （时点：真纯度需要全程序 IR 体 ⇒ 链统一在 IR 生成结束后重建）。
    return nid;
}

// --- Edge creation ---

fn df_add_edge_kind(from_id: int, to_id: int, kind: int) {
    if from_id < 0 || to_id < 0 { return; }
    eid := g_df_edge_count;
    grow_df_edges(eid + 1);
    w64(g_df_edges, eid * ESZ_DFEDGE + OFF_DFE_FROM, from_id);
    w64(g_df_edges, eid * ESZ_DFEDGE + OFF_DFE_TO, to_id);
    w64(g_df_edges, eid * ESZ_DFEDGE + OFF_DFE_KIND, kind);
    old_first := r64(g_df_nodes, from_id * ESZ_DFNODE + OFF_DF_FIRST_EDGE);
    w64(g_df_edges, eid * ESZ_DFEDGE + OFF_DFE_NEXT, old_first);
    w64(g_df_nodes, from_id * ESZ_DFNODE + OFF_DF_FIRST_EDGE, eid);
    old_cnt := r64(g_df_nodes, from_id * ESZ_DFNODE + OFF_DF_EDGE_COUNT);
    w64(g_df_nodes, from_id * ESZ_DFNODE + OFF_DF_EDGE_COUNT, old_cnt + 1);
    g_df_edge_count = eid + 1;
}

// Data edges (def-use) — the common case
fn df_add_edge(from_id: int, to_id: int) {
    df_add_edge_kind(from_id, to_id, 0);
}

// VSDG state chain: keep the ordering of side-effecting operations in program
// order. 只有改内存或调不纯函数的节点入链（各自与前一节点以 kind=1 状态边相连）。
// 时点（效应/纯度修正 Task 1）：**不再逐节点即时连接**——改由 df_replay_state_chain
// 在全部 IR 生成结束后对成品图重放调用；入链判据未变，仍是本函数。
fn df_connect_state(node_id: int, opcode: int, s3: int) {
    is_side_effect : ., mut = 0;
    // opcode 级效应清单的**唯一真源** = purity_op_effect（checker.cr；D7「效应清单
    // 收敛为一份」——链分类与纯度判定同表，两条判据才不会各自漂移）。历史两处
    // 缺失即由此收敛：① IR_CALL_EXTERN 两侧皆缺（extern 调用既被乐观标纯、又不在
    // 本表）；② IR_STORE_PTR/IR_AWAIT 只进了纯度侧（裸指针写、spawn 同步）。
    if purity_op_effect(opcode) != 0 { is_side_effect = 1; }
    if opcode == IR_CALL {
        // s3 = func name idx; resolve to func index for purity. Unknown/external
        // functions are conservatively treated as side-effecting.
        cfi := find_func(s3);
        if cfi < 0 { is_side_effect = 1; }
        else if fi_ispure(cfi) == 0 { is_side_effect = 1; }
    }
    if is_side_effect != 0 {
        if g_last_state_node >= 0 { df_add_edge_kind(g_last_state_node, node_id, 1); }
        g_last_state_node = node_id;
    }
}

// ─── state 链重建（效应/纯度修正 Task 1）──────────────────────────────
// 出处：链原在 df_create_node 内逐节点即时连接。改为「全部 IR 生成结束后重放」的
// 唯一理由 = **纯度时点**：入链判据含「调不纯函数」（df_connect_state 的 IR_CALL
// 分支），而「被调者是否纯」只能由全程序 IR 体算出（compute_all_purity——IR 体
// 逐函数生成，调用者先于被调者生成是常态，且递归/前向引用无解）⇒ 生成期恒无
// 全程序事实。链与发射面无关（NOD 序 = 节点创建序，与边无关；corearch 三轴不读
// EDG）⇒ 时点后移零发射影响。
// 重放保真：节点创建序 = 程序序；每函数链头重置（与 df_begin_func 同语义）；
// 循环终止规则按「区关闭位 = 该区 OFF_SG_EXIT」逐句复刻原 sg_pop 语义。
fn df_state_close_regions_at(head: string, next: string, pos: int) {
    sg := r64(head, pos * 8);
    loop {
        if sg < 0 { break; }
        // 原 sg_pop 的链语义（spec region-cfg §4.2）逐句复刻：关闭位 = 该区最后一个
        // 节点 + 1（当时 g_df_node_count）⇒ last_node = pos - 1。
        last_node := pos - 1;
        nstart := r64(g_sgs, sg * ESZ_SG + OFF_SG_NSTART);
        if last_node >= nstart {
            // 终止边源必须在区内（循环体无副作用时链头是区前的 store——连过去等于
            // 宣称循环退出依赖于该区不含的副作用）。
            if g_last_state_node >= nstart {
                df_add_edge_kind(g_last_state_node, last_node, 1);  // termination dependency
            }
            // 链头推进到区退出节点：循环之后的副作用必须依赖循环终止
            // （spec §4.2：不终止的循环必须终止整图）。
            g_last_state_node = last_node;
        }
        sg = r64(next, sg * 8);
    }
}

fn df_replay_state_chain() {
    if g_ir_func_count <= 0 { return; }
    // 位置 → 关闭区（只收 SG_LOOP/SG_FOR——链规则只对这两族生效）：head[pos] 与
    // next[sg] 两条 i64 链，按区号升序头插 ⇒ 同位置读出为区号降序 = sg_pop 的关闭序。
    // alloc 不保证清零（rt.s bump 分配器）⇒ head 逐项显式置 -1。
    head := alloc((g_df_node_count + 1) * 8);
    next := alloc((g_sg_count + 1) * 8);
    i : ., mut = 0;
    loop {
        if i > g_df_node_count { break; }
        w64(head, i * 8, -1);
        i = i + 1;
    }
    si : ., mut = 0;
    loop {
        if si >= g_sg_count { break; }
        k := r64(g_sgs, si * ESZ_SG + OFF_SG_KIND);
        if k == SG_LOOP || k == SG_FOR {
            ex := r64(g_sgs, si * ESZ_SG + OFF_SG_EXIT);
            if ex >= 0 && ex <= g_df_node_count {
                w64(next, si * 8, r64(head, ex * 8));
                w64(head, ex * 8, si);
            }
        }
        si = si + 1;
    }
    irf : ., mut = 0;
    loop {
        if irf >= g_ir_func_count { break; }
        start := r64(g_df_func_node_start, irf * 8);
        cnt := r64(g_df_func_node_count, irf * 8);
        g_last_state_node = -1;   // 每函数独立链（与 df_begin_func 同语义）
        n : ., mut = 0;
        loop {
            if n >= cnt { break; }
            if n > 0 { df_state_close_regions_at(head, next, start + n); }
            pos := start + n;
            df_connect_state(pos, r64(g_df_nodes, pos * ESZ_DFNODE + OFF_DF_OPCODE),
                r64(g_df_nodes, pos * ESZ_DFNODE + OFF_DF_S3));
            n = n + 1;
        }
        // 函数末端关闭位（SG_FUNC 恒在此；循环落在函数末句时该环也在此）——只在此
        // 处理：下一函数走 n=0 时跳过 start ⇒ 每个关闭位恰好处理一次。函数 0 的
        // start（位 0）无人处理，但那里 last_node = -1 < nstart ≥ 0 ⇒ 规则恒 no-op。
        df_state_close_regions_at(head, next, start + cnt);
        irf = irf + 1;
    }
}

// 链最终化（唯一入口）：真纯度 + 链重建。两个调用点均在「IR 生成结束、任何链
// 消费者之前」——run 路径 = ir_gen_all 尾；文件路径 = main.cr IR 循环之后
// （cir 转储 / 区域检查 / lower_to_ccr / 保存 .ccr 之前）。
fn df_state_finalize() {
    // 幂等护栏（Task 4 终审 Minor #5）：重复调用会**二次连链**（同一图再加一遍
    // kind=1 边 + 重算纯度）。当前两调用点互斥故不触发，属潜在坑；旗标随
    // reset_frontend_state 复位（长驻进程每编译一次重建）。
    if g_df_state_finalized != 0 { return; }
    g_df_state_finalized = 1;
    compute_all_purity();
    df_replay_state_chain();
}

fn df_use_var(consumer_node: int, var_idx: int) {
    if var_idx < 0 { return; }
    // Ensure the DF arrays are large enough for this variable index.
    // df_create_node only grows arrays for 'dest', but src fields (passed as
    // var_idx here) may have higher indices (e.g. arena_var from IR_ARENA_RESET
    // where dest=-1 but src1 is a high arena ID variable).
    if var_idx >= g_df_cap { grow_df_arrays(var_idx + 1); }
    producer := r64(g_df_var_producer, var_idx * 8);
    if producer >= 0 {
        df_add_edge(producer, consumer_node);
    }
}

// Connect source operands based on opcode semantics.
// Only fields that carry IR variable indices create dataflow edges.
fn df_connect_srcs(node_id: int, opcode: int, s1: int, s2: int, s3: int, tk_aux: int) {
    if opcode == IR_CONST { return; }  // all srcs are scalar values/labels

    if opcode == IR_BINARY {
        df_use_var(node_id, s1);
        df_use_var(node_id, s2);
        return;
    }
    if opcode == IR_UNARY {
        df_use_var(node_id, s1);
        return;
    }
    if opcode == IR_CALL || opcode == IR_SPAWN {
        // s1 = first argument var index, s2 = arg count (int), s3 = func name idx (int)
        // All args are contiguous vars starting at s1
        ac : ., mut = 0;
        loop {
            if ac >= s2 { break; }
            df_use_var(node_id, s1 + ac);
            ac = ac + 1;
        }
        return;
    }
    if opcode == IR_CALL_EXTERN {
        // s1 = func_name_ni (int), s2 = first_arg_var, s3 = arg_count
        df_use_var(node_id, s2);
        return;
    }
    if opcode == IR_RETURN {
        if s1 >= 0 { df_use_var(node_id, s1); }
        return;
    }
    if opcode == IR_STORE {
        df_use_var(node_id, s1);  // target var
        df_use_var(node_id, s2);  // value var
        return;
    }
    if opcode == IR_LOAD {
        df_use_var(node_id, s1);  // address var
        return;
    }
    if opcode == IR_LOAD_FIELD {
        df_use_var(node_id, s1);  // struct var
        return;
    }
    if opcode == IR_STORE_FIELD {
        df_use_var(node_id, s1);  // struct var
        df_use_var(node_id, s2);  // value var
        return;
    }
    if opcode == IR_LOAD_INDEX {
        df_use_var(node_id, s1);  // array var
        return;
    }
    if opcode == IR_STORE_INDEX {
        df_use_var(node_id, s1);  // array var
        df_use_var(node_id, s2);  // value var
        return;
    }
    if opcode == IR_LOAD_INDEX_VAR {
        df_use_var(node_id, s1);  // array var
        df_use_var(node_id, s2);  // index var
        return;
    }
    if opcode == IR_STORE_INDEX_VAR {
        df_use_var(node_id, s1);  // value var
        df_use_var(node_id, s2);  // array var
        df_use_var(node_id, s3);  // index var
        return;
    }
    if opcode == IR_BRANCH {
        df_use_var(node_id, s1);  // condition var (labels s2, s3 are not vars)
        return;
    }
    if opcode == IR_BOUNDS_CHECK {
        df_use_var(node_id, s1);
        // 单槽化（P5 T2）：旗标已从混用 tk 槽移入**辅码**槽 ⇒ 读 tk_aux（值域不变：
        // 1 = 动态上限 ⇒ 上限变量 s2 也是数据依赖；0 = 字面量上限 ⇒ 不连）。
        if tk_aux != 0 { df_use_var(node_id, s2); }
        return;
    }
    if opcode == IR_REF {
        df_use_var(node_id, s1);  // referenced var
        return;
    }
    if opcode == IR_DEREF {
        df_use_var(node_id, s1);  // ref var
        return;
    }
    if opcode == IR_MAKE_ENUM {
        // s1 = variant name idx (int), fields are stored separately via STORE_FIELD
        return;
    }
    if opcode == IR_SLICE {
        df_use_var(node_id, s1);  // array var
        df_use_var(node_id, s2);  // low var
        df_use_var(node_id, s3);  // high var
        return;
    }
    if opcode == IR_STORE_PTR {
        df_use_var(node_id, s1);  // ptr var
        df_use_var(node_id, s2);  // value var
        return;
    }
    if opcode == IR_LOAD_ENUM_TAG {
        df_use_var(node_id, s1);  // enum var
        return;
    }
    if opcode == IR_ARENA_NEW { df_use_var(node_id, s1); return; }
    if opcode == IR_ARENA_RESET { df_use_var(node_id, s1); return; }
    if opcode == IR_INLINE { df_use_var(node_id, s1); return; }
    if opcode == IR_HOTPATCH_ROUTE {
        df_use_var(node_id, s2);  // first_arg is a variable
        return;
    }
    if opcode == IR_DYN_TAG { df_use_var(node_id, s1); return; }
    if opcode == IR_DYN_VAL { df_use_var(node_id, s1); return; }
    if opcode == IR_DYN_PACK { df_use_var(node_id, s1); return; }
    if opcode == IR_DYN_DISPATCH { df_use_var(node_id, s1); return; }
    if opcode == IR_LAZY_THUNK { df_use_var(node_id, s1); return; }
    if opcode == IR_LAZY_FORCE { df_use_var(node_id, s1); return; }
    // Other opcodes (LABEL, JUMP, ALLOC, ALLOC_STRUCT, ALLOC_ARRAY, PHI):
    // no variable inputs to track
}

// --- Usage count analysis ---

fn grow_var_use_count(needed: int) {
    if needed < g_var_use_count_cap { return; }
    nc : ., mut = g_var_use_count_cap * 2;
    if nc < 128 { nc = 128; }
    if nc < needed { nc = needed + 128; }
    nb := alloc(nc * 8);
    _dyncpy(g_var_use_count, g_var_use_count_cap * 8, nb);
    g_var_use_count = nb;
    g_var_use_count_cap = nc;
}

fn compute_usage_counts() {
    // For each edge from_id→to_id, increment the usage count of
    // from_id's dest variable (the IR variable it produces).
    ei : ., mut = 0;
    loop {
        if ei >= g_df_edge_count { break; }
        // State edges are not data consumers — skip them for usage counts
        if r64(g_df_edges, ei * ESZ_DFEDGE + OFF_DFE_KIND) != 0 { ei = ei + 1; continue; }
        from_id := r64(g_df_edges, ei * ESZ_DFEDGE + OFF_DFE_FROM);
        dest := r64(g_df_nodes, from_id * ESZ_DFNODE + OFF_DF_DEST);
        if dest >= 0 {
            grow_var_use_count(dest + 1);
            prev := r64(g_var_use_count, dest * 8);
            w64(g_var_use_count, dest * 8, prev + 1);
        }
        ei = ei + 1;
    }
}

// --- Lowering: dataflow graph → linear CFG IR (.ccr) ---

fn lower_to_ccr() {
    // The graph was built in parallel with linear IR during emit().
    // For now: clear and rebuild g_ir_instrs from graph nodes.
    // Since nodes are in creation order (AST walk order), sequential
    // walk is already a valid topological schedule.
    g_ir_instr_count = 0;

    ni : ., mut = 0;
    loop {
        if ni >= g_df_node_count { break; }
        idx := g_ir_instr_count;
        grow_ir_instrs(idx + 1);
        iri_set_op(idx, r64(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE));
        iri_set_dest(idx, r64(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_DEST));
        iri_set_s1(idx, r64(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S1));
        iri_set_s2(idx, r64(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S2));
        iri_set_s3(idx, r64(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S3));
        // R2 P5 Task 2（D19）：iri_tk = **派生码**（不是槽值）——单槽化后 40 槽存的是
        // 类型项引用，码一律经 sh_dfn_code_of_slots 派生（派生码逐节点 ≡ 单槽化前的
        // 混用码 ⇒ .ccr 字节不变）。本文件对桥接符号的依赖仅此一处（df_create_node
        // 本身保持零前端依赖；lower_to_ccr 本就引 checker 侧 purity_op_effect）。
        iri_set_tk(idx, sh_dfn_code_of_slots(
            r64(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_TK),
            r64(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_AUX)));
        g_ir_instr_count = idx + 1;
        ni = ni + 1;
    }

    // Rebuilt g_ir_instrs means g_ir_func_instr_start/count are stale.
    // Node i → instruction i, so df boundaries = ir boundaries.
    fi : ., mut = 0;
    loop {
        if fi >= g_ir_func_count { break; }
        w64(g_ir_func_instr_start, fi * 8,
            r64(g_df_func_node_start, fi * 8));
        w64(g_ir_func_instr_count, fi * 8,
            r64(g_df_func_node_count, fi * 8));
        fi = fi + 1;
    }

    // After lowering, compute per-variable usage counts for optimization passes
    compute_usage_counts();

    // regalloc 移后端（2026-09-07，D-1=Y）：数据面（区间/条目）随分配归位
    // corearch——.ccr ENT 恒空，不再在此无条件计算；corearch load 后自算自检
    // （regalloc.cr compute_live_ranges/compute_entries，载入 NOD 流坐标同源）。
}

// --- Mark function boundary in graph ---

fn df_begin_func(func_idx: int) {
    if func_idx >= 0 {
        grow_df_arrays(func_idx + 1);
        w64(g_df_func_node_start, func_idx * 8, g_df_node_count);
        // 缓存收窄批（CIR_CACHE_VER 20）：记边起点——本函数的边 = [edge_start, g_df_edge_count)。
        // 时点与 df_end_func 的节点计数同构：**df_begin_func 之后产生的边皆属本函数**
        // （节点亦然；df_begin/df_end 自身不建边，state 链在全部 save 之后才重放）。
        w64(g_df_func_edge_start, func_idx * 8, g_df_edge_count);
        sg_push(SG_FUNC);
    }
    g_last_state_node = -1;  // fresh state chain per function
}

fn df_end_func(func_idx: int) {
    if func_idx >= 0 {
        start := r64(g_df_func_node_start, func_idx * 8);
        w64(g_df_func_node_count, func_idx * 8, g_df_node_count - start);
        sg_pop();
    }
}

// --- DOT output ---

fn df_graph_to_dot() -> string {
    // Build the graph in a growable buffer.  Repeated string concatenation
    // allocates and copies the whole prefix for every fragment, exhausting
    // the native bump heap on medium/large graphs before the dump is written.
    dump_buf_reset();
    dump_buf_append("digraph G {\n");
    dump_buf_append("    rankdir=TB;\n");

    // Region clusters: group each subgraph's nodes into a DOT cluster
    si : ., mut = 0;
    loop {
        if si >= g_sg_count { break; }
        skind := r64(g_sgs, si * ESZ_SG + OFF_SG_KIND);
        sname : ., mut = "region";
        if skind == SG_IF     { sname = "if"; }
        if skind == SG_LOOP   { sname = "loop"; }
        if skind == SG_FOR    { sname = "for"; }
        if skind == SG_FLOW   { sname = "flow"; }
        if skind == SG_UNSAFE { sname = "unsafe"; }
        dump_buf_append("  subgraph cluster_"); dump_buf_append(sname);
        dump_buf_append(int_str(si)); dump_buf_append(" { label=\"");
        dump_buf_append(sname); dump_buf_append("\";\n");
        // Nodes in this region:
        n0 := r64(g_sgs, si * ESZ_SG + OFF_SG_NSTART);
        n1 := r64(g_sgs, si * ESZ_SG + OFF_SG_EXIT);
        if n1 >= 0 {  // skip unclosed (EXIT<0) entries
            ni : ., mut = n0;
            loop { if ni >= n1 { break; }
                dump_buf_append("    n"); dump_buf_append(int_str(ni)); dump_buf_append(";\n");
                ni = ni + 1; }
        }
        dump_buf_append("  }\n");
        si = si + 1;
    }

    // Node definitions
    ni : ., mut = 0;
    loop {
        if ni >= g_df_node_count { break; }
        n_op := r64(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE);
        n_dest := r64(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_DEST);
        n_s3 := r64(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S3);
        label : ., mut = df_opcode_name(n_op, n_s3);
        if n_dest >= 0 {
            vname := get_ir_var_name(n_dest);
            if str_len(vname) > 0 {
                label = vname + ":" + label;
            }
        }
        dump_buf_append("    n"); dump_buf_append(int_str(ni));
        dump_buf_append(" [label=\""); dump_buf_append(label);
        dump_buf_append("\", shape=box];\n");
        ni = ni + 1;
    }

    // Edges (state edges dashed/red so ordering constraints stand out)
    ei : ., mut = 0;
    loop {
        if ei >= g_df_edge_count { break; }
        e_from := r64(g_df_edges, ei * ESZ_DFEDGE + OFF_DFE_FROM);
        e_to := r64(g_df_edges, ei * ESZ_DFEDGE + OFF_DFE_TO);
        if r64(g_df_edges, ei * ESZ_DFEDGE + OFF_DFE_KIND) != 0 {
            dump_buf_append("    n"); dump_buf_append(int_str(e_from)); dump_buf_append(" -> n");
            dump_buf_append(int_str(e_to)); dump_buf_append(" [style=dashed,color=red];\n");
        } else {
            dump_buf_append("    n"); dump_buf_append(int_str(e_from)); dump_buf_append(" -> n");
            dump_buf_append(int_str(e_to)); dump_buf_append(";\n");
        }
        ei = ei + 1;
    }

    dump_buf_append("}\n");
    return dump_buf_finish();
}

fn df_opcode_name(opcode: int, s3: int) -> string {
    if opcode == IR_CONST { return "const"; }
    if opcode == IR_BINARY {
        if s3 == OP_PTR_ADD  { return "ptr_add"; }
        if s3 == OP_PTR_SUB  { return "ptr_sub"; }
        if s3 == OP_PTR_DIFF { return "ptr_diff"; }
        return "binary";
    }
    if opcode == IR_UNARY { return "unary"; }
    if opcode == IR_CALL { return "call"; }
    if opcode == IR_RETURN { return "return"; }
    if opcode == IR_ALLOC { return "alloc"; }
    if opcode == IR_ALLOC_STRUCT { return "alloc_struct"; }
    if opcode == IR_ALLOC_ARRAY { return "alloc_array"; }
    if opcode == IR_STORE { return "store"; }
    if opcode == IR_LOAD { return "load"; }
    if opcode == IR_LOAD_FIELD { return "load_field"; }
    if opcode == IR_STORE_FIELD { return "store_field"; }
    if opcode == IR_LOAD_INDEX { return "load_index"; }
    if opcode == IR_STORE_INDEX { return "store_index"; }
    if opcode == IR_LOAD_INDEX_VAR { return "load_index_var"; }
    if opcode == IR_STORE_INDEX_VAR { return "store_index_var"; }
    if opcode == IR_MAKE_ENUM { return "make_enum"; }
    if opcode == IR_REF { return "ref"; }
    if opcode == IR_BRANCH { return "branch"; }
    if opcode == IR_JUMP { return "jump"; }
    if opcode == IR_LABEL { return "label"; }
    if opcode == IR_PHI { return "phi"; }
    if opcode == IR_LOAD_ENUM_TAG { return "load_enum_tag"; }
    if opcode == IR_SLICE { return "slice"; }
    if opcode == IR_DEREF { return "deref"; }
    if opcode == IR_STORE_PTR { return "store_ptr"; }
    if opcode == IR_SPAWN { return "spawn"; }
    if opcode == IR_YIELD { return "yield"; }
    if opcode == IR_FNADDR { return "fnaddr"; }
    if opcode == IR_ARENA_NEW { return "arena_new"; }
    if opcode == IR_ARENA_RESET { return "arena_reset"; }
    if opcode == IR_INLINE { return "inline"; }
    if opcode == IR_NO_BOUNDS_CHECK { return "NoBoundsCheck"; }
    if opcode == IR_FAST { return "fast"; }
    if opcode == IR_UNROLL { return "unroll"; }
    if opcode == IR_APPROX { return "approx"; }
    if opcode == IR_SECTION { return "section"; }
    if opcode == IR_HOTPATCH_ROUTE { return "hotpatch_route"; }
    if opcode == IR_DYN_TAG { return "dyn_tag"; }
    if opcode == IR_DYN_VAL { return "dyn_val"; }
    if opcode == IR_DYN_PACK { return "dyn_pack"; }
    if opcode == IR_DYN_DISPATCH { return "dyn_dispatch"; }
    if opcode == IR_CALL_EXTERN { return "call_extern"; }
    if opcode == IR_LAZY_THUNK { return "lazy_thunk"; }
    if opcode == IR_LAZY_FORCE { return "lazy_force"; }
    if opcode == IR_AWAIT { return "await"; }
    if opcode == IR_BOUNDS_CHECK { return "bounds_check"; }
    if opcode == IR_ADDR_INDEX { return "addr_index"; }
    if opcode == IR_I2F { return "i2f"; }
    if opcode == IR_F2I { return "f2i"; }
    if opcode == IR_NOP { return "nop"; }
    return "?";
}
