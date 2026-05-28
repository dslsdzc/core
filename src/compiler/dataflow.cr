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
    fi : ., mut = 0;
    loop {
        if fi >= MAX_FUNCS { break; }
        g_df_func_node_start[fi] = -1;
        g_df_func_node_count[fi] = 0;
        fi = fi + 1;
    }
    vi : ., mut = 0;
    loop {
        if vi >= MAX_IREXPRS { break; }
        g_df_var_producer[vi] = -1;
        vi = vi + 1;
    }
}

// --- Node creation ---

fn df_create_node(opcode: int, dest: int, src1: int, src2: int, src3: int, type_kind: int) -> int {
    nid := g_df_node_count;
    if nid >= MAX_DF_NODES { return -1; }
    g_df_nodes[nid] = DFNode {
        opcode = opcode,
        dest_var = dest,
        src1 = src1,
        src2 = src2,
        src3 = src3,
        type_kind = type_kind,
        first_edge = -1,
        edge_count = 0,
    };
    g_df_node_count = nid + 1;

    // Record that this node produces `dest`
    if dest >= 0 && dest < MAX_IREXPRS {
        g_df_var_producer[dest] = nid;
    }

    // Add edges for src fields that are IR variables (based on opcode)
    df_connect_srcs(nid, opcode, src1, src2, src3);

    return nid;
}

// --- Edge creation ---

fn df_add_edge(from_id: int, to_id: int) {
    if from_id < 0 || to_id < 0 { return; }
    eid := g_df_edge_count;
    if eid >= MAX_DF_EDGES { return; }
    g_df_edges[eid] = DFEdge {
        from_node = from_id,
        to_node = to_id,
        next_out = g_df_nodes[from_id].first_edge,
    };
    g_df_nodes[from_id].first_edge = eid;
    g_df_nodes[from_id].edge_count = g_df_nodes[from_id].edge_count + 1;
    g_df_edge_count = eid + 1;
}

fn df_use_var(consumer_node: int, var_idx: int) {
    if var_idx < 0 || var_idx >= MAX_IREXPRS { return; }
    producer := g_df_var_producer[var_idx];
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
    if opcode == IR_CALL {
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
        nd := g_df_nodes[ni];
        idx := g_ir_instr_count;
        if idx < MAX_IRINSTRUCTIONS {
            g_ir_instrs[idx] = IRInstr {
                opcode = nd.opcode,
                dest = nd.dest_var,
                src1 = nd.src1,
                src2 = nd.src2,
                src3 = nd.src3,
                type_kind = nd.type_kind,
            };
            g_ir_instr_count = idx + 1;
        }
        ni = ni + 1;
    }
}

// --- Mark function boundary in graph ---

fn df_begin_func(func_idx: int) {
    if func_idx >= 0 && func_idx < MAX_FUNCS {
        g_df_func_node_start[func_idx] = g_df_node_count;
    }
}

fn df_end_func(func_idx: int) {
    if func_idx >= 0 && func_idx < MAX_FUNCS {
        g_df_func_node_count[func_idx] = g_df_node_count - g_df_func_node_start[func_idx];
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
        nd := g_df_nodes[ni];
        label : ., mut = df_opcode_name(nd.opcode);
        if nd.dest_var >= 0 {
            vname := get_ir_var_name(nd.dest_var);
            if __builtin_str_len(vname) > 0 {
                label = vname + ":" + label;
            }
        }
        dot = dot + "    n" + __builtin_int_to_str(ni) + " [label=\"" + label + "\", shape=box];\n";
        ni = ni + 1;
    }

    // Edges
    ei : ., mut = 0;
    loop {
        if ei >= g_df_edge_count { break; }
        e := g_df_edges[ei];
        dot = dot + "    n" + __builtin_int_to_str(e.from_node) + " -> n" + __builtin_int_to_str(e.to_node) + ";\n";
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
    return "?";
}
