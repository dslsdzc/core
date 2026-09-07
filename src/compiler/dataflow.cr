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
    kind := r64(g_sgs, idx * ESZ_SG + OFF_SG_KIND);
    if kind == SG_LOOP || kind == SG_FOR {
        last_node := g_df_node_count - 1;
        if last_node >= r64(g_sgs, idx * ESZ_SG + OFF_SG_NSTART) {
            // The termination-edge source must be inside the region. When the
            // loop body is pure, g_last_state_node is a pre-loop store
            // (created before the region) — linking it would claim the loop
            // exit follows a side effect the region does not contain.
            if g_last_state_node >= r64(g_sgs, idx * ESZ_SG + OFF_SG_NSTART) {
                df_add_edge_kind(g_last_state_node, last_node, 1);  // termination dependency
            }
            // Advance the state-chain head to the region exit node: side
            // effects after the loop must depend on loop termination (spec
            // §4.2: a loop that never terminates must terminate the graph).
            g_last_state_node = last_node;
        }
    }
    g_cur_sg = r64(g_sgs, idx * ESZ_SG + OFF_SG_PARENT);
}

// --- Node creation ---

fn df_create_node(opcode: int, dest: int, src1: int, src2: int, src3: int, type_kind: int) -> int {
    nid := g_df_node_count;
    grow_df_nodes(nid + 1);
    grow_df_node_region(nid + 1);
    w64(g_df_node_region, nid * 8, g_cur_sg);  // owning region (-1 = none)
    w64(g_df_nodes, nid * ESZ_DFNODE + OFF_DF_OPCODE, opcode);
    w64(g_df_nodes, nid * ESZ_DFNODE + OFF_DF_DEST, dest);
    w64(g_df_nodes, nid * ESZ_DFNODE + OFF_DF_S1, src1);
    w64(g_df_nodes, nid * ESZ_DFNODE + OFF_DF_S2, src2);
    w64(g_df_nodes, nid * ESZ_DFNODE + OFF_DF_S3, src3);
    w64(g_df_nodes, nid * ESZ_DFNODE + OFF_DF_TK, type_kind);
    w64(g_df_nodes, nid * ESZ_DFNODE + OFF_DF_FIRST_EDGE, -1);
    w64(g_df_nodes, nid * ESZ_DFNODE + OFF_DF_EDGE_COUNT, 0);
    g_df_node_count = nid + 1;

    // Record that this node produces `dest`
    if dest >= 0 {
        grow_df_arrays(dest + 1);
        w64(g_df_var_producer, dest * 8, nid);
    }

    // Add edges for src fields that are IR variables (based on opcode)
    df_connect_srcs(nid, opcode, src1, src2, src3, type_kind);
    // VSDG state chain: side-effecting nodes are ordered by state edges
    df_connect_state(nid, opcode, src3);
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
// order. Called for every created DFNode; only nodes that mutate memory or
// call impure functions enter the chain (each links to the previous one via a
// kind=1 state edge).
fn df_connect_state(node_id: int, opcode: int, s3: int) {
    is_side_effect : ., mut = 0;
    if opcode == IR_STORE          { is_side_effect = 1; }
    if opcode == IR_STORE_FIELD    { is_side_effect = 1; }
    if opcode == IR_STORE_INDEX    { is_side_effect = 1; }
    if opcode == IR_STORE_INDEX_VAR { is_side_effect = 1; }
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
fn df_connect_srcs(node_id: int, opcode: int, s1: int, s2: int, s3: int, type_kind: int) {
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
        if type_kind != 0 { df_use_var(node_id, s2); }
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
        iri_set_tk(idx, r64(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_TK));
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
    if opcode == IR_NO_BOUNDS_CHECK { return "no_bounds_check"; }
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
