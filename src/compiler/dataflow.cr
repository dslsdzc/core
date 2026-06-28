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

// --- Node creation ---

fn df_create_node(opcode: int, dest: int, src1: int, src2: int, src3: int, type_kind: int) -> int {
    nid := g_df_node_count;
    grow_df_nodes(nid + 1);
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
    df_connect_srcs(nid, opcode, src1, src2, src3);
    if opcode == 4 || opcode == 27 {
        print("df_create: op="); print(int_str(opcode));
        print(" nid="); print(int_str(nid));
        print(" count="); println(int_str(g_df_node_count));
    }
    return nid;
}

// --- Edge creation ---

fn df_add_edge(from_id: int, to_id: int) {
    if from_id < 0 || to_id < 0 { return; }
    eid := g_df_edge_count;
    grow_df_edges(eid + 1);
    w64(g_df_edges, eid * ESZ_DFEDGE + OFF_DFE_FROM, from_id);
    w64(g_df_edges, eid * ESZ_DFEDGE + OFF_DFE_TO, to_id);
    old_first := r64(g_df_nodes, from_id * ESZ_DFNODE + OFF_DF_FIRST_EDGE);
    w64(g_df_edges, eid * ESZ_DFEDGE + OFF_DFE_NEXT, old_first);
    w64(g_df_nodes, from_id * ESZ_DFNODE + OFF_DF_FIRST_EDGE, eid);
    old_cnt := r64(g_df_nodes, from_id * ESZ_DFNODE + OFF_DF_EDGE_COUNT);
    w64(g_df_nodes, from_id * ESZ_DFNODE + OFF_DF_EDGE_COUNT, old_cnt + 1);
    g_df_edge_count = eid + 1;
}

fn df_use_var(consumer_node: int, var_idx: int) {
    if var_idx < 0 { return; }
    producer := r64(g_df_var_producer, var_idx * 8);
    if producer >= 0 {
        df_add_edge(producer, consumer_node);
    }
}

// Connect source operands based on opcode semantics.
// Only fields that carry IR variable indices create dataflow edges.
fn df_connect_srcs(node_id: int, opcode: int, s1: int, s2: int, s3: int) {
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
    // Other opcodes (LABEL, JUMP, ALLOC, ALLOC_STRUCT, ALLOC_ARRAY, PHI):
    // no variable inputs to track
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
}

// --- Mark function boundary in graph ---

fn df_begin_func(func_idx: int) {
    if func_idx >= 0 {
        grow_df_arrays(func_idx + 1);
        w64(g_df_func_node_start, func_idx * 8, g_df_node_count);
    }
}

fn df_end_func(func_idx: int) {
    if func_idx >= 0 {
        start := r64(g_df_func_node_start, func_idx * 8);
        w64(g_df_func_node_count, func_idx * 8, g_df_node_count - start);
    }
}

// --- DOT output ---

fn df_graph_to_dot() -> string {
    dot : ., mut = "digraph G {\n";
    dot = dot + "    rankdir=TB;\n";

    // Node definitions
    ni : ., mut = 0;
    loop {
        if ni >= g_df_node_count { break; }
        n_op := r64(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_OPCODE);
        n_dest := r64(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_DEST);
        label : ., mut = df_opcode_name(n_op);
        if n_dest >= 0 {
            vname := get_ir_var_name(n_dest);
            if str_len(vname) > 0 {
                label = vname + ":" + label;
            }
        }
        dot = dot + "    n" + int_str(ni) + " [label=\"" + label + "\", shape=box];\n";
        ni = ni + 1;
    }

    // Edges
    ei : ., mut = 0;
    loop {
        if ei >= g_df_edge_count { break; }
        e_from := r64(g_df_edges, ei * ESZ_DFEDGE + OFF_DFE_FROM);
        e_to := r64(g_df_edges, ei * ESZ_DFEDGE + OFF_DFE_TO);
        dot = dot + "    n" + int_str(e_from) + " -> n" + int_str(e_to) + ";\n";
        ei = ei + 1;
    }

    dot = dot + "}\n";
    return dot;
}

fn df_opcode_name(opcode: int) -> string {
    if opcode == IR_CONST { return "const"; }
    if opcode == IR_BINARY { return "binary"; }
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
    return "?";
}
