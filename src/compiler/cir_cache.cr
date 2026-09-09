// === cir_cache.cr ===
// Incremental compilation cache: per-function .cir snapshot save/load.
// Saves the dataflow graph state (DF nodes, edges, IR instrs, vars, strings)
// for one function. On cache hit, restores the state directly into the
// compiler's global arrays.

// Magic header for .cir cache files
// v12: invalidate older call flags, generic cloning/indexing, and yield ASTs.
// v13: persist nested SG region metadata in per-function cache files.
// v14: 幽灵边播种修复（v7 Task 0 注 A 裁决）——快照内未产出 var 的 producer
//      槽语义随 grow_df_arrays 播种变更为恒 -1；旧快照（含 0 槽幽灵边 + 恢复
//      路径不重播种）必须失效——cache miss = 无害重建。
// 注意：magic 位模式 = C1C1…（bytes）；以 signed 十进制书写——hex 字面量
// 0xC1C1C1C1C1C1C1C1 超 i64 上界，会被词法溢出守卫拒绝（见 lexer P2 修复）。
CIR_CACHE_MAGIC : int = -4485090715960753727;
CIR_CACHE_VER   : int = 14;

g_cir_write_buf : string, mut;
g_cir_write_pos : int, mut;
g_cir_write_cap : int, mut;

// Count non-function regions belonging to one function. The function SG is
// recreated by df_begin_func on a cache hit, so only nested records are stored.
fn cir_cache_sg_count(node_start: int, node_count: int) -> int {
    count : ., mut = 0;
    si : ., mut = 0;
    loop {
        if si >= g_sg_count { break; }
        kind := r64(g_sgs, si * ESZ_SG + OFF_SG_KIND);
        nstart := r64(g_sgs, si * ESZ_SG + OFF_SG_NSTART);
        if kind != SG_FUNC && nstart >= node_start && nstart < node_start + node_count {
            count = count + 1;
        }
        si = si + 1;
    }
    return count;
}

// Encode a region parent as an index within the serialized nested-region
// list. -1 denotes the function SG recreated by df_begin_func.
fn cir_cache_sg_parent(sg_idx: int, node_start: int, node_count: int) -> int {
    parent := r64(g_sgs, sg_idx * ESZ_SG + OFF_SG_PARENT);
    if parent < 0 { return -1; }
    parent_kind := r64(g_sgs, parent * ESZ_SG + OFF_SG_KIND);
    parent_start := r64(g_sgs, parent * ESZ_SG + OFF_SG_NSTART);
    if parent_kind == SG_FUNC && parent_start == node_start { return -1; }

    local : ., mut = 0;
    si : ., mut = 0;
    loop {
        if si >= sg_idx { break; }
        kind := r64(g_sgs, si * ESZ_SG + OFF_SG_KIND);
        nstart := r64(g_sgs, si * ESZ_SG + OFF_SG_NSTART);
        if kind != SG_FUNC && nstart >= node_start && nstart < node_start + node_count {
            if si == parent { return local; }
            local = local + 1;
        }
        si = si + 1;
    }
    return -1;
}

// Save one function's DFG state to a .cir cache file.
// path: full file path (including .core/cache/cir/ prefix)
// source_fi: source FuncInfo index used for AST fingerprints
// ir_fi: compact IR function index used for IR/DFG ranges
// Returns 0 on success, -1 on failure.
fn save_cir_cache(path: string, source_fi: int, ir_fi: int) -> int {
    fd := syscall3(2, path, 577, 420);  // O_WRONLY|O_CREAT|O_TRUNC, 0644
    if fd < 0 { return -1; }

    // Compute fingerprint
    fn_node := fi_ast_node(source_fi);
    fp := func_fingerprint(fn_node);
    sig := sig_fingerprint(fn_node);
    name_ni := r64(g_ir_func_name_idx, ir_fi * 8);
    name := istr_get(name_ni);
    name_len := str_len(name);

    var_start := r64(g_ir_func_var_start, ir_fi * 8);
    var_count := r64(g_ir_func_var_count, ir_fi * 8);
    node_start := r64(g_df_func_node_start, ir_fi * 8);
    node_count := r64(g_df_func_node_count, ir_fi * 8);
    instr_start := r64(g_ir_func_instr_start, ir_fi * 8);
    instr_count := r64(g_ir_func_instr_count, ir_fi * 8);

    // Serialize in memory and issue one write. The previous per-field writes
    // made a full self-host build perform millions of syscalls on its cache.
    total_size : ., mut = 40 + name_len;
    total_size = total_size + 8 + var_count * 24;
    total_size = total_size + 8 + node_count * 64;
    total_size = total_size + 8 + g_df_edge_count * 32;  // v5: 4 fields incl. kind
    total_size = total_size + 8 + instr_count * 48;
    total_size = total_size + 8;
    size_si : ., mut = 0;
    loop {
        if size_si >= g_ir_str_const_count { break; }
        size_ni := r64(g_ir_str_consts, size_si * 8);
        total_size = total_size + 8 + str_len(istr_get(size_ni));
        size_si = size_si + 1;
    }
    // v13: nested SG records (kind/enter/exit/parent/nstart/ncount).
    sg_count := cir_cache_sg_count(node_start, node_count);
    total_size = total_size + 8 + sg_count * 48;
    if total_size > g_cir_write_cap {
        new_cap := g_cir_write_cap * 2;
        if new_cap < 4096 { new_cap = 4096; }
        if new_cap < total_size { new_cap = total_size; }
        g_cir_write_buf = alloc(new_cap);
        g_cir_write_cap = new_cap;
    }
    g_cir_write_pos = 0;

    // Write header
    w64_cir(fd, CIR_CACHE_MAGIC);
    w64_cir(fd, CIR_CACHE_VER);
    w64_cir(fd, fp);
    w64_cir(fd, sig);
    w64_cir(fd, name_len);
    write_fd(fd, name, name_len);

    // Determine var range for this function
    w64_cir(fd, var_count);
    vi : ., mut = 0;
    loop {
        if vi >= var_count { break; }
        v_idx := var_start + vi;
        w64_cir(fd, irv_name(v_idx));
        w64_cir(fd, irv_id(v_idx));
        w64_cir(fd, irv_type(v_idx));
        vi = vi + 1;
    }

    // Write function's node range
    w64_cir(fd, node_count);
    ni2 : ., mut = 0;
    loop {
        if ni2 >= node_count { break; }
        n := node_start + ni2;
        w64_cir(fd, r64(g_df_nodes, n * ESZ_DFNODE + OFF_DF_OPCODE));
        w64_cir(fd, r64(g_df_nodes, n * ESZ_DFNODE + OFF_DF_DEST));
        w64_cir(fd, r64(g_df_nodes, n * ESZ_DFNODE + OFF_DF_S1));
        w64_cir(fd, r64(g_df_nodes, n * ESZ_DFNODE + OFF_DF_S2));
        w64_cir(fd, r64(g_df_nodes, n * ESZ_DFNODE + OFF_DF_S3));
        w64_cir(fd, r64(g_df_nodes, n * ESZ_DFNODE + OFF_DF_TK));
        w64_cir(fd, r64(g_df_nodes, n * ESZ_DFNODE + OFF_DF_FIRST_EDGE));
        w64_cir(fd, r64(g_df_nodes, n * ESZ_DFNODE + OFF_DF_EDGE_COUNT));
        ni2 = ni2 + 1;
    }

    // Persist nested SG metadata with offsets relative to this function's
    // node range. Parent indices are local to this serialized section.
    w64_cir(fd, sg_count);
    sg_i : ., mut = 0;
    loop {
        if sg_i >= g_sg_count { break; }
        kind := r64(g_sgs, sg_i * ESZ_SG + OFF_SG_KIND);
        nstart := r64(g_sgs, sg_i * ESZ_SG + OFF_SG_NSTART);
        if kind != SG_FUNC && nstart >= node_start && nstart < node_start + node_count {
            w64_cir(fd, kind);
            w64_cir(fd, r64(g_sgs, sg_i * ESZ_SG + OFF_SG_ENTER) - node_start);
            w64_cir(fd, r64(g_sgs, sg_i * ESZ_SG + OFF_SG_EXIT) - node_start);
            w64_cir(fd, cir_cache_sg_parent(sg_i, node_start, node_count));
            w64_cir(fd, nstart - node_start);
            w64_cir(fd, r64(g_sgs, sg_i * ESZ_SG + OFF_SG_NCOUNT));
        }
        sg_i = sg_i + 1;
    }

    // Write edges (all edges for this function's nodes)
    // For simplicity, write ALL edges (they're few compared to nodes)
    // v5: 4×8B per edge — from/to/next + kind (state edges survive cache hits)
    w64_cir(fd, g_df_edge_count);
    ei : ., mut = 0;
    loop {
        if ei >= g_df_edge_count { break; }
        w64_cir(fd, r64(g_df_edges, ei * ESZ_DFEDGE + OFF_DFE_FROM));
        w64_cir(fd, r64(g_df_edges, ei * ESZ_DFEDGE + OFF_DFE_TO));
        w64_cir(fd, r64(g_df_edges, ei * ESZ_DFEDGE + OFF_DFE_NEXT));
        w64_cir(fd, r64(g_df_edges, ei * ESZ_DFEDGE + OFF_DFE_KIND));
        ei = ei + 1;
    }

    // Write function's instruction range
    w64_cir(fd, instr_count);
    ii : ., mut = 0;
    loop {
        if ii >= instr_count { break; }
        inst := instr_start + ii;
        w64_cir(fd, iri_op(inst));
        w64_cir(fd, iri_dest(inst));
        w64_cir(fd, iri_s1(inst));
        w64_cir(fd, iri_s2(inst));
        w64_cir(fd, iri_s3(inst));
        w64_cir(fd, iri_tk(inst));
        ii = ii + 1;
    }

    // Write string constants used by this function
    w64_cir(fd, g_ir_str_const_count);
    si : ., mut = 0;
    loop {
        if si >= g_ir_str_const_count { break; }
        ni3 := r64(g_ir_str_consts, si * 8);
        s := istr_get(ni3);
        sl := str_len(s);
        w64_cir(fd, sl);
        vi = 0;
        loop { if vi >= sl { break; }
            w8_cir(fd, load8(s, vi));
        vi = vi + 1; }
        si = si + 1;
    }

    written := syscall3(1, fd, g_cir_write_buf, g_cir_write_pos);
    syscall3(3, fd, 0, 0);
    if written != g_cir_write_pos { return -1; }
    return 0;
}

// Write helpers for the in-memory cache serializer.
fn w64_cir(fd: int, val: int) {
    w64(g_cir_write_buf, g_cir_write_pos, val);
    g_cir_write_pos = g_cir_write_pos + 8;
}

fn w8_cir(fd: int, val: int) {
    store8(g_cir_write_buf, g_cir_write_pos, val);
    g_cir_write_pos = g_cir_write_pos + 1;
}

fn write_fd(fd: int, data: string, len: int) {
    write_pos : ., mut = 0;
    loop {
        if write_pos >= len { break; }
        store8(g_cir_write_buf, g_cir_write_pos, load8(data, write_pos));
        g_cir_write_pos = g_cir_write_pos + 1;
        write_pos = write_pos + 1;
    }
}

// Load a .cir cache file and restore DFG state.
// func_idx is the function index used to verify the cached fingerprints
// against the current AST. Returns 0 on success, -1 on failure (cache miss).
fn load_cir_cache(path: string, func_idx: int) -> int {
    data := read_file(path);
    if str_len(data) < 48 { return -1; }
    pos : ., mut = 0;

    // Validate header
    magic := r64(data, pos); pos = pos + 8;
    if magic != CIR_CACHE_MAGIC { return -1; }
    ver := r64(data, pos); pos = pos + 8;
    if ver != CIR_CACHE_VER { return -1; }

    fp := r64(data, pos); pos = pos + 8;
    sig := r64(data, pos); pos = pos + 8;

    // Verify fingerprints against current AST.
    // If the function body or signature changed, the cache is stale.
    fn_node := fi_ast_node(func_idx);
    current_fp := func_fingerprint(fn_node);
    if fp != current_fp { return -1; }
    current_sig := sig_fingerprint(fn_node);
    if sig != current_sig { return -1; }

    // Verify function identity (name)
    name_len := r64(data, pos); pos = pos + 8;
    // Skip name string (we already know which function we tried to load)
    pos = pos + name_len;

    // Restore vars
    var_count := r64(data, pos); pos = pos + 8;
    vi : ., mut = 0;
    loop {
        if vi >= var_count { break; }
        name_ni := r64(data, pos); pos = pos + 8;
        v_id := r64(data, pos); pos = pos + 8;
        v_type := r64(data, pos); pos = pos + 8;
        // Ensure var array is large enough
        if v_id >= g_ir_var_count {
            grow_ir_vars(v_id + 1);
            g_ir_var_count = v_id + 1;
        }
        irv_set_name(v_id, name_ni);
        irv_set_id(v_id, v_id);
        irv_set_type(v_id, v_type);
        vi = vi + 1;
    }

    // Restore nodes
    node_count := r64(data, pos); pos = pos + 8;
    base_node := g_df_node_count;
    grow_df_nodes(g_df_node_count + node_count);
    // RegionCheck 显式映射：恢复的节点没有经过 df_create_node，须在此同步写入
    // node→region 映射，否则 subgraph_containing 在缓存命中路径读到未初始化
    // 的 g_df_node_region（null → SIGSEGV）。缓存不保存内层 region（Minor #4），
    // 以当前 open 的 func region（df_begin_func 已 sg_push）为归属——与旧的
    // 线性扫 g_sgs 在缓存命中路径得到的结果一致。
    grow_df_node_region(base_node + node_count);
    ni : ., mut = 0;
    loop {
        if ni >= node_count { break; }
        n := base_node + ni;
        w64(g_df_node_region, n * 8, g_cur_sg);
        w64(g_df_nodes, n * ESZ_DFNODE + OFF_DF_OPCODE, r64(data, pos)); pos = pos + 8;
        w64(g_df_nodes, n * ESZ_DFNODE + OFF_DF_DEST, r64(data, pos)); pos = pos + 8;
        w64(g_df_nodes, n * ESZ_DFNODE + OFF_DF_S1, r64(data, pos)); pos = pos + 8;
        w64(g_df_nodes, n * ESZ_DFNODE + OFF_DF_S2, r64(data, pos)); pos = pos + 8;
        w64(g_df_nodes, n * ESZ_DFNODE + OFF_DF_S3, r64(data, pos)); pos = pos + 8;
        w64(g_df_nodes, n * ESZ_DFNODE + OFF_DF_TK, r64(data, pos)); pos = pos + 8;
        w64(g_df_nodes, n * ESZ_DFNODE + OFF_DF_FIRST_EDGE, r64(data, pos)); pos = pos + 8;
        w64(g_df_nodes, n * ESZ_DFNODE + OFF_DF_EDGE_COUNT, r64(data, pos)); pos = pos + 8;
        // Record var producer. 幽灵边修复（v7 注 A 裁决）缓存面：grow_df_arrays
        // 对新增长区播种 -1（dyn_arr.cr 同款注释）——快照内未产出 var（参数等）
        // 的 producer 槽恒 -1（修复前零页 = 0 =「节点 0」→ 缓存命中函数保留
        // 幽灵边）；本处只覆写快照内真实定值的 var。旧快照由 CIR_CACHE_VER
        // 13→14 失效。
        dest := r64(g_df_nodes, n * ESZ_DFNODE + OFF_DF_DEST);
        if dest >= 0 {
            grow_df_arrays(dest + 1);
            w64(g_df_var_producer, dest * 8, n);
        }
        ni = ni + 1;
    }
    g_df_node_count = base_node + node_count;

    // Restore nested SG metadata (v13). The current function SG was opened by
    // df_begin_func; cached parent=-1 refers to that SG.
    sg_count := r64(data, pos); pos = pos + 8;
    sg_base := g_sg_count;
    sg_i : ., mut = 0;
    loop {
        if sg_i >= sg_count { break; }
        new_sg := g_sg_count;
        grow_sg(new_sg + 1);
        kind := r64(data, pos); pos = pos + 8;
        enter_rel := r64(data, pos); pos = pos + 8;
        exit_rel := r64(data, pos); pos = pos + 8;
        parent_rel := r64(data, pos); pos = pos + 8;
        nstart_rel := r64(data, pos); pos = pos + 8;
        ncount := r64(data, pos); pos = pos + 8;
        parent := g_cur_sg;
        if parent_rel >= 0 { parent = sg_base + parent_rel; }
        f := new_sg * ESZ_SG;
        w64(g_sgs, f + OFF_SG_KIND, kind);
        w64(g_sgs, f + OFF_SG_ENTER, base_node + enter_rel);
        w64(g_sgs, f + OFF_SG_EXIT, base_node + exit_rel);
        w64(g_sgs, f + OFF_SG_PARENT, parent);
        w64(g_sgs, f + OFF_SG_NSTART, base_node + nstart_rel);
        w64(g_sgs, f + OFF_SG_NCOUNT, ncount);
        g_sg_count = new_sg + 1;

        // Later (inner) records overwrite the enclosing region mapping.
        rn : ., mut = base_node + nstart_rel;
        rend := rn + ncount;
        loop {
            if rn >= rend { break; }
            w64(g_df_node_region, rn * 8, new_sg);
            rn = rn + 1;
        }
        sg_i = sg_i + 1;
    }

    // Restore edges (v5: 4×8B per edge — from/to/next/kind)
    edge_count := r64(data, pos); pos = pos + 8;
    grow_df_edges(edge_count);
    g_df_edge_count = edge_count;
    ei : ., mut = 0;
    loop {
        if ei >= edge_count { break; }
        e_from := r64(data, pos); pos = pos + 8;
        e_to := r64(data, pos); pos = pos + 8;
        e_next := r64(data, pos); pos = pos + 8;
        e_kind := r64(data, pos); pos = pos + 8;
        w64(g_df_edges, ei * ESZ_DFEDGE + OFF_DFE_FROM, e_from);
        w64(g_df_edges, ei * ESZ_DFEDGE + OFF_DFE_TO, e_to);
        w64(g_df_edges, ei * ESZ_DFEDGE + OFF_DFE_NEXT, e_next);
        w64(g_df_edges, ei * ESZ_DFEDGE + OFF_DFE_KIND, e_kind);
        ei = ei + 1;
    }

    // Restore instructions
    instr_count := r64(data, pos); pos = pos + 8;
    base_instr := g_ir_instr_count;
    grow_ir_instrs(g_ir_instr_count + instr_count);
    ii : ., mut = 0;
    loop {
        if ii >= instr_count { break; }
        inst := base_instr + ii;
        iri_set_op(inst, r64(data, pos)); pos = pos + 8;
        iri_set_dest(inst, r64(data, pos)); pos = pos + 8;
        iri_set_s1(inst, r64(data, pos)); pos = pos + 8;
        iri_set_s2(inst, r64(data, pos)); pos = pos + 8;
        iri_set_s3(inst, r64(data, pos)); pos = pos + 8;
        iri_set_tk(inst, r64(data, pos)); pos = pos + 8;
        ii = ii + 1;
    }
    g_ir_instr_count = base_instr + instr_count;

    // Restore string constants (used by nodes/instrs)
    str_count := r64(data, pos); pos = pos + 8;
    si : ., mut = 0;
    loop {
        if si >= str_count { break; }
        sl := r64(data, pos); pos = pos + 8;
        s := str_sub(data, pos, sl);
        pos = pos + sl;
        track_str(str_intern(s));
        si = si + 1;
    }

    return 0;
}

// Ensure cache directory exists.
fn make_cir_cache_dir() {
    // Create .core/ directory hierarchy for cache.
    // mkdir syscall = 83 on x86-64 Linux: mkdir(path, mode)
    // Ignore EEXIST errors (directory may already exist).
    syscall3(83, ".core", 448, 0);
    syscall3(83, ".core/cache", 448, 0);
    syscall3(83, ".core/cache/cir", 448, 0);
}
