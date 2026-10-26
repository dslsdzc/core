// === dataflow.cr ===
// HDFG construction and state finalization.
//
// IR generation calls emit(), which creates a DFNode. Data edges are tracked
// through g_df_var_producer[]. After IR generation, ccr_lower.cr::lower_to_ccr()
// builds g_ir_instrs for the backend, and df_state_finalize() computes purity and
// replays the state chain.

// --- Initialization ---

fn init_df():
    g_df_node_count = 0
    g_df_edge_count = 0
    g_df_cap = 0
    g_df_node_cap = 0
    g_df_edge_cap = 0
    g_df_node_region_cap = 0   // node region array rebuilt on grow
    g_cur_sg = -1              // no region open yet
    g_last_state_node = -1     // state chain starts empty per compile
    fi : ., mut = 0
    loop:
        if fi >= g_func_count:
            break
        grow_df_arrays(fi + 1)
        cell_store(g_df_func_node_start, fi * 8, -1)
        cell_store(g_df_func_node_count, fi * 8, 0)
        fi = fi + 1
    vi : ., mut = 0
    loop:
        if vi >= g_ir_var_count:
            break
        grow_df_arrays(vi + 1)
        cell_store(g_df_var_producer, vi * 8, -1)
        vi = vi + 1

// --- Subgraph management (bare pointer model) ---

fn sg_push(kind: int):
    grow_sg(g_sg_count + 1)
    idx : ., mut = g_sg_count
    cell_store(g_sgs, idx * ESZ_SG + OFF_SG_KIND, kind)
    cell_store(g_sgs, idx * ESZ_SG + OFF_SG_ENTER, g_df_node_count)
    cell_store(g_sgs, idx * ESZ_SG + OFF_SG_EXIT, -1)
    cell_store(g_sgs, idx * ESZ_SG + OFF_SG_NSTART, g_df_node_count)
    cell_store(g_sgs, idx * ESZ_SG + OFF_SG_NCOUNT, 0)
    // Parent: find innermost currently open subgraph
    parent : ., mut = -1
    pi : ., mut = idx - 1
    loop:
        if pi < 0:
            break
        if cell_load(g_sgs, pi * ESZ_SG + OFF_SG_EXIT) < 0:
            // still open
            parent = pi
            break
        pi = pi - 1
    cell_store(g_sgs, idx * ESZ_SG + OFF_SG_PARENT, parent)
    g_cur_sg = idx  // new innermost open region
    g_sg_count = idx + 1

// Close the innermost open region. A region is open while OFF_SG_EXIT is -1.
// g_sg_count is a high-water mark and is never decremented, so the function
// searches backward for the first open entry. This keeps df_end_func from
// closing the same region twice and overwriting its EXIT with the function
// node count.
fn sg_pop():
    if g_sg_count <= 0:
        return
    idx : ., mut = -1
    pi : ., mut = g_sg_count - 1
    loop:
        if pi < 0:
            break
        if cell_load(g_sgs, pi * ESZ_SG + OFF_SG_EXIT) < 0:
            idx = pi
            break
        pi = pi - 1
    if idx < 0:
        return
    cell_store(g_sgs, idx * ESZ_SG + OFF_SG_EXIT, g_df_node_count)
    cell_store(g_sgs, idx * ESZ_SG + OFF_SG_NCOUNT,
        g_df_node_count - cell_load(g_sgs, idx * ESZ_SG + OFF_SG_NSTART))
    // Loop termination dependency: the region exit node (last node created in
    // the region, i.e. the exit label) must happen after the region's last
    // side effect — a VSDG state edge enforcing loop-exit ordering.
    // 循环终止依赖（kind=1）与序列头推进不在本处连接，状态依赖边序列统一在
    // 全部 IR 生成结束后重建（df_replay_state_chain；时点理由见该函数头注）：
    // 被调函数真纯度只有拿到全程序 IR 体才能算，状态依赖关系不能边生成边连接。
    g_cur_sg = cell_load(g_sgs, idx * ESZ_SG + OFF_SG_PARENT)

// --- Node creation ---

// `tk_term` is a type-term reference (g_type_terms row, -1 = none).
// `tk_aux` is the auxiliary code (flags, width, count, or an unrepresentable
// row). The caller splits the type face with sh_tk_split. This function only
// stores the slots; it does not interpret, validate, or derive them. The
// derived code is produced by sh_dfn_code_of_slots.
fn df_create_node(opcode: int, dest: int, src1: int, src2: int, src3: int, tk_term: int, tk_aux: int) -> int:
    nid := g_df_node_count
    grow_df_nodes(nid + 1)
    grow_df_node_region(nid + 1)
    cell_store(g_df_node_region, nid * 8, g_cur_sg)  // owning region (-1 = none)
    cell_store(g_df_nodes, nid * ESZ_DFNODE + OFF_DF_OPCODE, opcode)
    cell_store(g_df_nodes, nid * ESZ_DFNODE + OFF_DF_DEST, dest)
    cell_store(g_df_nodes, nid * ESZ_DFNODE + OFF_DF_S1, src1)
    cell_store(g_df_nodes, nid * ESZ_DFNODE + OFF_DF_S2, src2)
    cell_store(g_df_nodes, nid * ESZ_DFNODE + OFF_DF_S3, src3)
    cell_store(g_df_nodes, nid * ESZ_DFNODE + OFF_DF_TK, tk_term)   // type-term reference
    cell_store(g_df_nodes, nid * ESZ_DFNODE + OFF_DF_AUX, tk_aux)   // auxiliary code
    cell_store(g_df_nodes, nid * ESZ_DFNODE + OFF_DF_FIRST_EDGE, -1)
    cell_store(g_df_nodes, nid * ESZ_DFNODE + OFF_DF_EDGE_COUNT, 0)
    g_df_node_count = nid + 1

    // Record that this node produces `dest`
    if dest >= 0:
        grow_df_arrays(dest + 1)
        cell_store(g_df_var_producer, dest * 8, nid)

    // Add edges for src fields that are IR variables (based on opcode)
    // 第 6 参 = 辅码（IR_BOUNDS_CHECK 的 `!= 0` = 动态上限旗标，单槽化后旗标在
    // 辅码槽；见 df_connect_srcs 的 IR_BOUNDS_CHECK 分支）。
    df_connect_srcs(nid, opcode, src1, src2, src3, tk_aux)
    // VSDG state chain（kind=1）不在此连接，见 df_replay_state_chain 头注
    // （时点：真纯度需要全程序 IR 体 -> 状态依赖关系统一在 IR 生成结束后重建）。
    return nid

// --- Edge creation ---

fn df_add_edge_kind(from_id: int, to_id: int, kind: int):
    if from_id < 0 || to_id < 0:
        return
    eid := g_df_edge_count
    grow_df_edges(eid + 1)
    cell_store(g_df_edges, eid * ESZ_DFEDGE + OFF_DFE_FROM, from_id)
    cell_store(g_df_edges, eid * ESZ_DFEDGE + OFF_DFE_TO, to_id)
    cell_store(g_df_edges, eid * ESZ_DFEDGE + OFF_DFE_KIND, kind)
    old_first := cell_load(g_df_nodes, from_id * ESZ_DFNODE + OFF_DF_FIRST_EDGE)
    cell_store(g_df_edges, eid * ESZ_DFEDGE + OFF_DFE_NEXT, old_first)
    cell_store(g_df_nodes, from_id * ESZ_DFNODE + OFF_DF_FIRST_EDGE, eid)
    old_cnt := cell_load(g_df_nodes, from_id * ESZ_DFNODE + OFF_DF_EDGE_COUNT)
    cell_store(g_df_nodes, from_id * ESZ_DFNODE + OFF_DF_EDGE_COUNT, old_cnt + 1)
    g_df_edge_count = eid + 1

// Data edge (def-use). This is the common case.
fn df_add_edge(from_id: int, to_id: int):
    df_add_edge_kind(from_id, to_id, 0)

// State chain: keep side-effecting operations in program order. A node enters
// the chain when purity_op_effect reports an effect, or when IR_CALL targets an
// impure or unresolved function. The chain is replayed after IR generation by
// df_replay_state_chain; the admission rule stays in this function.
fn df_connect_state(node_id: int, opcode: int, s3: int):
    is_side_effect : ., mut = 0
    // The opcode-level effect list has one source: purity_op_effect. Chain
    // classification and purity judgment share this table, so the two cannot
    // drift apart.
    if purity_op_effect(opcode) != 0:
        is_side_effect = 1
    if opcode == IR_CALL:
        // s3 = func name idx; resolve to func index for purity. Unknown/external
        // functions are conservatively treated as side-effecting.
        cfi := find_func(s3)
        if cfi < 0:
            is_side_effect = 1
        else if fi_ispure(cfi) == 0:
            is_side_effect = 1
    if is_side_effect != 0:
        if g_last_state_node >= 0:
            df_add_edge_kind(g_last_state_node, node_id, 1)
        g_last_state_node = node_id

// State-chain replay.
//
// The chain cannot be connected during node creation because the IR_CALL rule
// needs to know whether the callee is pure, and purity is a whole-program fact
// computed by compute_all_purity after all IR bodies exist. Replaying after IR
// generation has no effect on emission: NOD order is creation order, and the
// backend does not read EDG.
//
// The replay keeps node creation order as program order, resets the chain head
// per function, and closes loop and for regions at OFF_SG_EXIT.
fn df_state_close_regions_at(head: string, next: string, pos: int):
    sg : ., mut = cell_load(head, pos * 8)
    loop:
        if sg < 0:
            break
        // A region closes at the node after its last node. last_node is the
        // node immediately before the close position.
        last_node := pos - 1
        nstart := cell_load(g_sgs, sg * ESZ_SG + OFF_SG_NSTART)
        if last_node >= nstart:
            // 终止边源必须在区内（循环体无副作用时序列头是区前的 store，连过去等于
            // 宣称循环退出依赖于该区不含的副作用）。
            if g_last_state_node >= nstart:
                df_add_edge_kind(g_last_state_node, last_node, 1)  // termination dependency
            // 序列头推进到区退出节点：循环之后的副作用必须依赖循环终止
            // （spec 4.2：不终止的循环必须终止整图）。
            g_last_state_node = last_node
        sg = cell_load(next, sg * 8)

fn df_replay_state_chain():
    if g_ir_func_count <= 0:
        return
    // 位置 -> 关闭区（只收 SG_LOOP/SG_FOR，状态依赖规则只对这两族生效）：head[pos] 与
    // next[sg] 两个 i64 数组，按区号升序头插 -> 同位置读出为区号降序 = sg_pop 的关闭序。
    // alloc 不保证清零（rt.s bump 分配器）-> head 逐项显式置 -1。
    head := alloc((g_df_node_count + 1) * 8)
    next := alloc((g_sg_count + 1) * 8)
    i : ., mut = 0
    loop:
        if i > g_df_node_count:
            break
        cell_store(head, i * 8, -1)
        i = i + 1
    si : ., mut = 0
    loop:
        if si >= g_sg_count:
            break
        k := cell_load(g_sgs, si * ESZ_SG + OFF_SG_KIND)
        if k == SG_LOOP || k == SG_FOR:
            ex := cell_load(g_sgs, si * ESZ_SG + OFF_SG_EXIT)
            if ex >= 0 && ex <= g_df_node_count:
                cell_store(next, si * 8, cell_load(head, ex * 8))
                cell_store(head, ex * 8, si)
        si = si + 1
    irf : ., mut = 0
    loop:
        if irf >= g_ir_func_count:
            break
        start := cell_load(g_df_func_node_start, irf * 8)
        cnt := cell_load(g_df_func_node_count, irf * 8)
        g_last_state_node = -1   // 每函数独立的状态依赖序列（与 df_begin_func 同语义）
        n : ., mut = 0
        loop:
            if n >= cnt:
                break
            if n > 0:
                df_state_close_regions_at(head, next, start + n)
            pos := start + n
            df_connect_state(pos, cell_load(g_df_nodes, pos * ESZ_DFNODE + OFF_DF_OPCODE),
                cell_load(g_df_nodes, pos * ESZ_DFNODE + OFF_DF_S3))
            n = n + 1
        // 函数末端关闭位（SG_FUNC 恒在此；循环落在函数末句时该环也在此），只在此
        // 处理：下一函数走 n=0 时跳过 start -> 每个关闭位恰好处理一次。函数 0 的
        // start（位 0）无人处理，但那里 last_node = -1 < nstart ≥ 0 -> 规则恒 no-op。
        df_state_close_regions_at(head, next, start + cnt)
        irf = irf + 1

// 状态依赖关系最终化（唯一入口）：真纯度 + 依赖边重建。两个调用点均在IR 生成结束、任何状态依赖关系
// 消费者之前，run 路径 = ir_gen_all 尾；文件路径 = main.cr IR 循环之后
// （cir 转储 / 区域检查 / lower_to_ccr / 保存 .ccr 之前）。
fn df_state_finalize():
    // Idempotence guard. A second call would add the state edges twice and
    // recompute purity. The flag is reset by reset_frontend_state so a
    // long-running process rebuilds the chain for each compilation.
    if g_df_state_finalized != 0:
        return
    g_df_state_finalized = 1
    compute_all_purity()
    df_replay_state_chain()

fn df_use_var(consumer_node: int, var_idx: int):
    if var_idx < 0:
        return
    // Ensure the DF arrays are large enough for this variable index.
    // df_create_node only grows arrays for 'dest', but src fields (passed as
    // var_idx here) may have higher indices (e.g. arena_var from IR_ARENA_RESET
    // where dest=-1 but src1 is a high arena ID variable).
    if var_idx >= g_df_cap:
        grow_df_arrays(var_idx + 1)
    producer := cell_load(g_df_var_producer, var_idx * 8)
    if producer >= 0:
        df_add_edge(producer, consumer_node)

// Connect source operands based on opcode semantics.
// Only fields that carry IR variable indices create dataflow edges.
fn df_connect_srcs(node_id: int, opcode: int, s1: int, s2: int, s3: int, tk_aux: int):
    if opcode == IR_CONST:
        return
    if opcode == IR_CONST_BIG:
        return
    // all srcs are scalar values/labels

    if opcode == IR_BINARY:
        df_use_var(node_id, s1)
        df_use_var(node_id, s2)
        return
    if opcode == IR_UNARY:
        df_use_var(node_id, s1)
        return
    if opcode == IR_CALL || opcode == IR_SPAWN:
        // s1 = first argument var index, s2 = arg count (int), s3 = func name idx (int)
        // All args are contiguous vars starting at s1
        ac : ., mut = 0
        loop:
            if ac >= s2:
                break
            df_use_var(node_id, s1 + ac)
            ac = ac + 1
        return
    if opcode == IR_CALL_EXTERN:
        // s1 = func_name_ni (int), s2 = first_arg_var, s3 = arg_count
        df_use_var(node_id, s2)
        return
    if opcode == IR_RETURN:
        if s1 >= 0:
            df_use_var(node_id, s1)
        return
    if opcode == IR_STORE:
        df_use_var(node_id, s1)  // target var
        df_use_var(node_id, s2)  // value var
        return
    if opcode == IR_LOAD:
        df_use_var(node_id, s1)  // address var
        return
    if opcode == IR_LOAD_FIELD:
        df_use_var(node_id, s1)  // struct var
        return
    if opcode == IR_STORE_FIELD:
        df_use_var(node_id, s1)  // struct var
        df_use_var(node_id, s2)  // value var
        return
    if opcode == IR_LOAD_INDEX:
        df_use_var(node_id, s1)  // array var
        return
    if opcode == IR_STORE_INDEX:
        df_use_var(node_id, s1)  // array var
        df_use_var(node_id, s2)  // value var
        return
    if opcode == IR_LOAD_INDEX_VAR:
        df_use_var(node_id, s1)  // array var
        df_use_var(node_id, s2)  // index var
        return
    if opcode == IR_STORE_INDEX_VAR:
        df_use_var(node_id, s1)  // value var
        df_use_var(node_id, s2)  // array var
        df_use_var(node_id, s3)  // index var
        return
    if opcode == IR_MATCH:
        // The scrutinee is the only variable read; case targets are labels in
        // the CASE table, not node operands.
        df_use_var(node_id, s1)
        return
    if opcode == IR_BOUNDS_CHECK:
        df_use_var(node_id, s1)
        // 单槽化：旗标已从混用 tk 槽移入辅码槽 -> 读 tk_aux（值域不变：
        // 1 = 动态上限 -> 上限变量 s2 也是数据依赖；0 = 字面量上限 -> 不连）。
        if tk_aux != 0:
            df_use_var(node_id, s2)
        return
    if opcode == IR_REF:
        df_use_var(node_id, s1)  // referenced var
        return
    if opcode == IR_DEREF:
        df_use_var(node_id, s1)  // ref var
        return
    if opcode == IR_MAKE_ENUM:
        // s1 = variant name idx (int), fields are stored separately via STORE_FIELD
        return
    if opcode == IR_SLICE:
        df_use_var(node_id, s1)  // array var
        df_use_var(node_id, s2)  // low var
        df_use_var(node_id, s3)  // high var
        return
    if opcode == IR_STORE_PTR:
        df_use_var(node_id, s1)  // ptr var
        df_use_var(node_id, s2)  // value var
        return
    if opcode == IR_LOAD_ENUM_TAG:
        df_use_var(node_id, s1)  // enum var
        return
    if opcode == IR_ARENA_NEW:
        df_use_var(node_id, s1)
        return
    if opcode == IR_ARENA_RESET:
        df_use_var(node_id, s1)
        return
    if opcode == IR_INLINE:
        df_use_var(node_id, s1)
        return
    if opcode == IR_HOTPATCH_ROUTE:
        df_use_var(node_id, s2)  // first_arg is a variable
        return
    if opcode == IR_DYN_TAG:
        df_use_var(node_id, s1)
        return
    if opcode == IR_DYN_VAL:
        df_use_var(node_id, s1)
        return
    if opcode == IR_DYN_PACK:
        df_use_var(node_id, s1)
        return
    if opcode == IR_DYN_DISPATCH:
        df_use_var(node_id, s1)
        return
    if opcode == IR_LAZY_THUNK:
        df_use_var(node_id, s1)
        return
    if opcode == IR_LAZY_FORCE:
        df_use_var(node_id, s1)
        return
    // Other opcodes (LABEL, JUMP, ALLOC, ALLOC_STRUCT, ALLOC_ARRAY, PHI):
    // no variable inputs to track

// --- Usage count analysis ---

fn grow_var_use_count(needed: int):
    if needed < g_var_use_count_cap:
        return
    nc : ., mut = g_var_use_count_cap * 2
    if nc < 128:
        nc = 128
    if nc < needed:
        nc = needed + 128
    nb := alloc(nc * 8)
    cell_copy(g_var_use_count, g_var_use_count_cap * 8, nb)
    g_var_use_count = nb
    g_var_use_count_cap = nc

fn compute_usage_counts():
    // For each edge from_id->to_id, increment the usage count of
    // from_id's dest variable (the IR variable it produces).
    ei : ., mut = 0
    loop:
        if ei >= g_df_edge_count:
            break
        // State edges are not data consumers — skip them for usage counts
        if cell_load(g_df_edges, ei * ESZ_DFEDGE + OFF_DFE_KIND) != 0:
            ei = ei + 1
            continue
        from_id := cell_load(g_df_edges, ei * ESZ_DFEDGE + OFF_DFE_FROM)
        dest := cell_load(g_df_nodes, from_id * ESZ_DFNODE + OFF_DF_DEST)
        if dest >= 0:
            grow_var_use_count(dest + 1)
            prev := cell_load(g_var_use_count, dest * 8)
            cell_store(g_var_use_count, dest * 8, prev + 1)
        ei = ei + 1

// --- Mark function boundary in graph ---

fn df_begin_func(func_idx: int):
    if func_idx >= 0:
        grow_df_arrays(func_idx + 1)
        cell_store(g_df_func_node_start, func_idx * 8, g_df_node_count)
        // Record the edge start for this function. Edges created after this
        // point belong to the function; df_begin_func and df_end_func do not
        // create edges, and the state chain is replayed later.
        cell_store(g_df_func_edge_start, func_idx * 8, g_df_edge_count)
        sg_push(SG_FUNC)
    g_last_state_node = -1  // fresh state chain per function

fn df_end_func(func_idx: int):
    if func_idx >= 0:
        start := cell_load(g_df_func_node_start, func_idx * 8)
        cell_store(g_df_func_node_count, func_idx * 8, g_df_node_count - start)
        sg_pop()

// --- DOT output ---

fn df_graph_to_dot() -> string:
    // Build the graph in a growable buffer.  Repeated string concatenation
    // allocates and copies the whole prefix for every fragment, exhausting
    // the native bump heap on medium/large graphs before the dump is written.
    dump_buf_reset()
    dump_buf_append("digraph G {\n")
    dump_buf_append("    rankdir=TB;\n")

    // Region clusters: group each subgraph's nodes into a DOT cluster
    si : ., mut = 0
    loop:
        if si >= g_sg_count:
            break
        skind := cell_load(g_sgs, si * ESZ_SG + OFF_SG_KIND)
        sname : ., mut = "region"
        if skind == SG_IF:
            sname = "if"
        if skind == SG_LOOP:
            sname = "loop"
        if skind == SG_FOR:
            sname = "for"
        if skind == SG_FLOW:
            sname = "flow"
        if skind == SG_UNSAFE:
            sname = "unsafe"
        dump_buf_append("  subgraph cluster_")
        dump_buf_append(sname)
        dump_buf_append(int_str(si))
        dump_buf_append(" { label=\"")
        dump_buf_append(sname)
        dump_buf_append("\";\n")
        // Nodes in this region:
        n0 := cell_load(g_sgs, si * ESZ_SG + OFF_SG_NSTART)
        n1 := cell_load(g_sgs, si * ESZ_SG + OFF_SG_EXIT)
        if n1 >= 0:
            // skip unclosed (EXIT<0) entries
            ni : ., mut = n0
            loop:
                if ni >= n1:
                    break
                dump_buf_append("    n")
                dump_buf_append(int_str(ni))
                dump_buf_append(";\n")
                ni = ni + 1
        dump_buf_append("  }\n")
        si = si + 1

    // Node definitions
    ni : ., mut = 0
    loop:
        if ni >= g_df_node_count:
            break
        n_op := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE)
        n_dest := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_DEST)
        n_s3 := cell_load(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_S3)
        label : ., mut = df_opcode_name(n_op, n_s3)
        if n_dest >= 0:
            vname := get_ir_var_name(n_dest)
            if str_len(vname) > 0:
                label = vname + ":" + label
        dump_buf_append("    n")
        dump_buf_append(int_str(ni))
        dump_buf_append(" [label=\"")
        dump_buf_append(label)
        dump_buf_append("\", shape=box];\n")
        ni = ni + 1

    // Edges (state edges dashed/red so ordering constraints stand out)
    ei : ., mut = 0
    loop:
        if ei >= g_df_edge_count:
            break
        e_from := cell_load(g_df_edges, ei * ESZ_DFEDGE + OFF_DFE_FROM)
        e_to := cell_load(g_df_edges, ei * ESZ_DFEDGE + OFF_DFE_TO)
        if cell_load(g_df_edges, ei * ESZ_DFEDGE + OFF_DFE_KIND) != 0:
            dump_buf_append("    n")
            dump_buf_append(int_str(e_from))
            dump_buf_append(" -> n")
            dump_buf_append(int_str(e_to))
            dump_buf_append(" [style=dashed,color=red];\n")
        else:
            dump_buf_append("    n")
            dump_buf_append(int_str(e_from))
            dump_buf_append(" -> n")
            dump_buf_append(int_str(e_to))
            dump_buf_append(";\n")
        ei = ei + 1

    dump_buf_append("}\n")
    return dump_buf_finish()

fn df_opcode_name(opcode: int, s3: int) -> string:
    if opcode == IR_CONST:
        return "const"
    if opcode == IR_CONST_BIG:
        return "const_big"
    if opcode == IR_PTR_OF:
        return "ptr_of"
    if opcode == IR_STR_OF:
        return "str_of"
    if opcode == IR_BINARY:
        if s3 == OP_PTR_ADD:
            return "ptr_add"
        if s3 == OP_PTR_SUB:
            return "ptr_sub"
        if s3 == OP_PTR_DIFF:
            return "ptr_diff"
        return "binary"
    if opcode == IR_UNARY:
        return "unary"
    if opcode == IR_CALL:
        return "call"
    if opcode == IR_RETURN:
        return "return"
    if opcode == IR_ALLOC:
        return "alloc"
    if opcode == IR_ALLOC_STRUCT:
        return "alloc_struct"
    if opcode == IR_ALLOC_ARRAY:
        return "alloc_array"
    if opcode == IR_STORE:
        return "store"
    if opcode == IR_LOAD:
        return "load"
    if opcode == IR_LOAD_FIELD:
        return "load_field"
    if opcode == IR_STORE_FIELD:
        return "store_field"
    if opcode == IR_LOAD_INDEX:
        return "load_index"
    if opcode == IR_STORE_INDEX:
        return "store_index"
    if opcode == IR_LOAD_INDEX_VAR:
        return "load_index_var"
    if opcode == IR_STORE_INDEX_VAR:
        return "store_index_var"
    if opcode == IR_MAKE_ENUM:
        return "make_enum"
    if opcode == IR_REF:
        return "ref"
    if opcode == IR_MATCH:
        return "match"
    if opcode == IR_JUMP:
        return "jump"
    if opcode == IR_LABEL:
        return "label"
    if opcode == IR_PHI:
        return "phi"
    if opcode == IR_LOAD_ENUM_TAG:
        return "load_enum_tag"
    if opcode == IR_SLICE:
        return "slice"
    if opcode == IR_DEREF:
        return "deref"
    if opcode == IR_STORE_PTR:
        return "store_ptr"
    if opcode == IR_SPAWN:
        return "spawn"
    if opcode == IR_YIELD:
        return "yield"
    if opcode == IR_FNADDR:
        return "fnaddr"
    if opcode == IR_ARENA_NEW:
        return "arena_new"
    if opcode == IR_ARENA_RESET:
        return "arena_reset"
    if opcode == IR_INLINE:
        return "inline"
    if opcode == IR_NO_BOUNDS_CHECK:
        return "NoBoundsCheck"
    if opcode == IR_FAST:
        return "fast"
    if opcode == IR_UNROLL:
        return "unroll"
    if opcode == IR_APPROX:
        return "approx"
    if opcode == IR_SECTION:
        return "section"
    if opcode == IR_HOTPATCH_ROUTE:
        return "hotpatch_route"
    if opcode == IR_DYN_TAG:
        return "dyn_tag"
    if opcode == IR_DYN_VAL:
        return "dyn_val"
    if opcode == IR_DYN_PACK:
        return "dyn_pack"
    if opcode == IR_DYN_DISPATCH:
        return "dyn_dispatch"
    if opcode == IR_CALL_EXTERN:
        return "call_extern"
    if opcode == IR_LAZY_THUNK:
        return "lazy_thunk"
    if opcode == IR_LAZY_FORCE:
        return "lazy_force"
    if opcode == IR_AWAIT:
        return "await"
    if opcode == IR_BOUNDS_CHECK:
        return "bounds_check"
    if opcode == IR_ADDR_INDEX:
        return "addr_index"
    if opcode == IR_I2F:
        return "i2f"
    if opcode == IR_F2I:
        return "f2i"
    if opcode == IR_NOP:
        return "nop"
    return "?"
