// === cir_cache.cr ===
// Incremental compilation cache: per-function .cir snapshot save and load.
//
// A snapshot stores one function's dataflow graph, IR instructions, variables,
// string constants, nested subgraph records, and the string-interning journal for
// the generation window. On a hit, load_cir_cache restores this state into the
// compiler's global arrays.
//
// File layout:
//   header: magic, version, compiler identity, func fingerprint, signature
//           fingerprint, name length, name
//   vars: count, then {name, id, type} per record
//   nodes: count, then 64-byte records
//          {opcode, dest, s1, s2, s3, derived code, first_edge, edge_count}
//   nested subgraphs: count, then 48-byte records
//          {kind, enter_rel, exit_rel, parent_rel, nstart_rel, ncount}
//   edges: count, then 24-byte records {rel_from, rel_to, kind}
//   instructions: count, then 48-byte records {op, dest, s1, s2, s3, tk}
//   match cases: match count, then per IR_MATCH in instruction order:
//          {case_count, then case_count x 24-byte records
//           value i64, kind u32, str i32, target_label i32, flags u32}
//          This is the semantic model, not the derived wire: target_label is
//          the IR body label number, or -1 when the target is unresolved.
//          The MATCH s2/s3 stored in nodes/instructions are model start/count;
//          the loader rewrites s2 to the reader's model start and ccr_lower
//          derives the wire CASE table afterwards.
//   string constants: count, then {length, bytes}
//   intern journal: base count, record count, then {length, bytes}
//   trailer: var_start, node_start
//
// Validation before restore:
//   The loader scans the whole snapshot and validates all ranges, the compiler
//   identity, both fingerprints, the var baseline, edge endpoints, per-node edge
//   counts, and the trailer before writing any global. A truncated or inconsistent
//   snapshot is a cache miss, never a partial restore.
//
// Derived type codes:
//   The type-term table is process-local. The snapshot stores only the derived
//   code produced by sh_dfn_code_of_slots. On load, sh_tk_split_load rederives
//   both the term reference and the auxiliary code at the same point in the node
//   sequence as the cold path, so cold and warm runs get the same term indexes.
//
// Edges:
//   Only this function's edges are stored, with endpoints relative to node_start.
//   The next pointers are not stored; df_add_edge_kind rebuilds them in the same
//   insertion order as the cold path. Relative endpoints remain valid when a
//   partial rebuild shifts the node baseline.
//
// Intern journal:
//   Absolute intern ids depend on which functions were generated or loaded in the
//   current process. The journal stores the contents of new strings, not their
//   ids, and the loader replays them in order before restoring any id. The base
//   count must match the reader's g_str_count; otherwise the snapshot is rejected.
//
// Version policy:
//   Bump CIR_CACHE_VER when stored content is no longer equivalent to current
//   semantics. A cache miss is a harmless rebuild. The compiler identity also
//   invalidates all entries when the running binary changes, so source edits do
//   not need a manual bump for body changes.
//   The v10 `.ccr` wire migration (removing SYM opt_meta and adding semantic
//   NOD type ids) does not change this snapshot layout or its derived-code
//   contract. The stored records, journal, and trailer are unchanged, so no
//   version bump is required for that migration; only `.ccr` bytes changed.
//   v24 adds the per-function MATCH CASE section after the instruction range.
//   v25 changes that section from derived wire rows (target NOD id) to the
//   semantic model (target body label), so v24 entries are invalid.
//
// Magic value:
//   The magic is a negative 64-bit constant written as signed decimal. The
//   bootstrap backend currently stores negative file-level constants as 0; both
//   writer and reader use the same constant, so the cache remains self-consistent.
//   The limitation is recorded in the project backlog.
CIR_CACHE_MAGIC : int = -4485090715960753727
CIR_CACHE_VER   : int = 25

g_cir_write_buf : string, mut
g_cir_write_pos : int, mut
g_cir_write_cap : int, mut

// === Compiler identity ===
// The cache key contains the source path, function name, and AST fingerprints.
// Fingerprints cover the target source only. If the compiler binary changes, its
// string interning order and snapshot indexes can change while the key and
// fingerprints stay the same. The old entry would then be reused with invalid
// indexes.
//
// The header therefore stores a content hash of the running compiler ELF
// (/proc/self/exe). The loader requires it to match. A mismatch is a cache miss
// and a rebuild. Any rebuild that changes frontend semantics changes the binary
// and therefore the hash.
//
// A build-time source hash is not enough: the binary also depends on the source
// file list and order, the bootstrap Python toolchain, rt.s, and as/ld. Hashing
// the running binary covers all of them without adding generated files to the
// build.
//
// If the hash is unavailable (no procfs, read failure, empty file), the identity
// is 0. Save refuses to write and load refuses to hit, so both endpoints disable
// the cache. This avoids two identity-less compilers accepting each other's
// entries.
//
// CIR_CACHE_VER is the manual coarse-grained gate for format or semantic
// generation changes. The identity is the automatic fine-grained gate for compiler
// content changes. Both must match.
g_cir_compiler_id       : int, mut = 0
g_cir_compiler_id_ready : int, mut = 0

// Content hash of the running compiler ELF, memoized. 0 means the identity is
// unavailable (no procfs, read failure, or empty file); callers disable the cache.
fn cir_compiler_identity() -> int:
    if g_cir_compiler_id_ready != 0:
        return g_cir_compiler_id
    g_cir_compiler_id_ready = 1
    g_cir_compiler_id = cir_hash_running_binary()
    return g_cir_compiler_id

// Single-pass multiplicative hash (FNV-1 64-bit constants; the language has no
// XOR operator, so this uses the same shape as func_fingerprint in ir_gen.cr).
// It processes eight-byte words, then the remaining bytes, then mixes in the total
// length so different lengths cannot collide by construction. The target is
// little-endian x86-64, and only determinism matters, not byte order.
//
// The hash is memoized by the caller, so the cost is paid once per process that
// actually reaches the cache. It is not cryptographic: it distinguishes builds of
// the same compiler, and an attacker who can write cache files can already write
// arbitrary payloads.
fn cir_hash_running_binary() -> int:
    fd := syscall3(2, "/proc/self/exe", 0, 0)  // open(O_RDONLY)
    if fd < 0:
        return 0
    buf := alloc(65536)
    h : ., mut = -3750763034362895579  // FNV-1 64 offset basis（signed i64）
    total : ., mut = 0
    loop:
        n := syscall3(0, fd, buf, 65536)  // read(fd, buf, 65536)
        if n <= 0:
            break
        i : ., mut = 0
        loop:
            if i + 8 > n:
                break
            h = h * 1099511628211 + cell_load64(buf, i)
            i = i + 8
        loop:
            if i >= n:
                break
            h = h * 1099511628211 + cell_load_byte(buf, i)
            i = i + 1
        total = total + n
    r1 := syscall3(3, fd, 0, 0)  // close(fd)
    if total == 0:
        return 0
    h = h * 1099511628211 + total
    return h

// Count non-function regions belonging to one function. The function SG is
// recreated by df_begin_func on a cache hit, so only nested records are stored.
fn cir_cache_sg_count(node_start: int, node_count: int) -> int:
    count : ., mut = 0
    si : ., mut = 0
    loop:
        if si >= g_sg_count:
            break
        kind := cell_load(g_sgs, si * ESZ_SG + OFF_SG_KIND)
        nstart := cell_load(g_sgs, si * ESZ_SG + OFF_SG_NSTART)
        if kind != SG_FUNC && nstart >= node_start && nstart < node_start + node_count:
            count = count + 1
        si = si + 1
    return count

// Encode a region parent as an index within the serialized nested-region
// list. -1 denotes the function SG recreated by df_begin_func.
fn cir_cache_sg_parent(sg_idx: int, node_start: int, node_count: int) -> int:
    parent := cell_load(g_sgs, sg_idx * ESZ_SG + OFF_SG_PARENT)
    if parent < 0:
        return -1
    parent_kind := cell_load(g_sgs, parent * ESZ_SG + OFF_SG_KIND)
    parent_start := cell_load(g_sgs, parent * ESZ_SG + OFF_SG_NSTART)
    if parent_kind == SG_FUNC && parent_start == node_start:
        return -1

    local : ., mut = 0
    si : ., mut = 0
    loop:
        if si >= sg_idx:
            break
        kind := cell_load(g_sgs, si * ESZ_SG + OFF_SG_KIND)
        nstart := cell_load(g_sgs, si * ESZ_SG + OFF_SG_NSTART)
        if kind != SG_FUNC && nstart >= node_start && nstart < node_start + node_count:
            if si == parent:
                return local
            local = local + 1
        si = si + 1
    return -1

// Save one function's DFG state to a .cir cache file.
// path: full file path (including .core/cache/cir/ prefix)
// source_fi: source FuncInfo index used for AST fingerprints
// ir_fi: compact IR function index used for IR/DFG ranges
// Returns 0 on success, -1 on failure.
fn save_cir_cache(path: string, source_fi: int, ir_fi: int) -> int:
    // If the compiler identity is unavailable, do not write a snapshot. An entry
    // with identity 0 could be accepted by another compiler that also lacks an
    // identity. Disabling the cache is a full rebuild, which is correct.
    cid := cir_compiler_identity()
    if cid == 0:
        return -1

    // Compute fingerprint
    fn_node := fi_ast_node(source_fi)
    fp := func_fingerprint(fn_node)
    sig := sig_fingerprint(fn_node)
    name_ni := cell_load(g_ir_func_name_idx, ir_fi * 8)
    name := istr_get(name_ni)
    name_len := str_len(name)

    var_start := cell_load(g_ir_func_var_start, ir_fi * 8)
    var_count := cell_load(g_ir_func_var_count, ir_fi * 8)
    node_start := cell_load(g_df_func_node_start, ir_fi * 8)
    node_count := cell_load(g_df_func_node_count, ir_fi * 8)
    instr_start := cell_load(g_ir_func_instr_start, ir_fi * 8)
    instr_count := cell_load(g_ir_func_instr_count, ir_fi * 8)

    // Validate and size the MATCH CASE section before touching the file. Every
    // IR_MATCH owns a contiguous range of semantic model rows (g_lat_case);
    // nested matches append after their enclosing range, which is also
    // instruction order. A mismatch would produce a snapshot the loader must
    // reject, so refuse to write it.
    match_count : ., mut = 0
    match_size : ., mut = 8
    expected_case : ., mut = -1
    ms_i : ., mut = 0
    loop:
        if ms_i >= instr_count:
            break
        ms_inst := instr_start + ms_i
        if iri_op(ms_inst) == IR_MATCH:
            ms_start := iri_s2(ms_inst)
            ms_n := iri_s3(ms_inst)
            if ms_start < 0 || ms_n < 0:
                return -1
            if ms_start + ms_n > g_lat_case_count:
                return -1
            if expected_case >= 0 && ms_start != expected_case:
                return -1
            expected_case = ms_start + ms_n
            match_count = match_count + 1
            match_size = match_size + 8 + ms_n * 24
        ms_i = ms_i + 1

    // Serialize in memory and issue one write. The previous per-field writes
    // made a full self-host build perform millions of syscalls on its cache.
    total_size : ., mut = 48 + name_len  // v17 头部 = magic/ver/identity/fp/sig/name_len
    total_size = total_size + 8 + var_count * 24
    // Node records are 8 fields of 8 bytes: {opcode, dest, s1, s2, s3, derived
    // code, first_edge, edge_count}. The term-reference and auxiliary slots are
    // not stored; the loader rederives both from the derived code.
    total_size = total_size + 8 + node_count * 64
    // Only this function's edges are stored: [edge_start, g_df_edge_count).
    // Each record is 24 bytes: {rel_from, rel_to, kind}, with signed offsets
    // relative to node_start. The next pointers are not stored; the loader
    // rebuilds them through df_add_edge_kind in the cold-path insertion order.
    edge_start := cell_load(g_df_func_edge_start, ir_fi * 8)
    own_edge_count : ., mut = g_df_edge_count - edge_start
    if own_edge_count < 0:
        own_edge_count = 0
    total_size = total_size + 8 + own_edge_count * 24
    total_size = total_size + 8 + instr_count * 48
    // Per-function MATCH CASE model section. Always present, even when empty,
    // so the reader can parse every v25 snapshot with one layout.
    total_size = total_size + match_size
    total_size = total_size + 8
    size_si : ., mut = 0
    loop:
        if size_si >= g_ir_str_const_count:
            break
        size_ni := cell_load(g_ir_str_consts, size_si * 8)
        total_size = total_size + 8 + str_len(istr_get(size_ni))
        size_si = size_si + 1
    // v13: nested SG records (kind/enter/exit/parent/nstart/ncount).
    sg_count := cir_cache_sg_count(node_start, node_count)
    total_size = total_size + 8 + sg_count * 48
    // Intern journal: {base count, record count, then {length, bytes}}.
    total_size = total_size + 16
    size_ri : ., mut = 0
    loop:
        if size_ri >= g_cir_rec_count:
            break
        total_size = total_size + 8 + str_len(istr_get(cell_load(g_cir_rec_ids, size_ri * 8)))
        size_ri = size_ri + 1
    // Trailer: {var_start, node_start}. Both are validated before restore.
    total_size = total_size + 16
    if total_size > g_cir_write_cap:
        new_cap : ., mut = g_cir_write_cap * 2
        if new_cap < 4096:
            new_cap = 4096
        if new_cap < total_size:
            new_cap = total_size
        g_cir_write_buf = alloc(new_cap)
        g_cir_write_cap = new_cap
    g_cir_write_pos = 0

    fd := syscall3(2, path, 577, 420)  // O_WRONLY|O_CREAT|O_TRUNC, 0644
    if fd < 0:
        return -1

    // Write header
    cir_store_cell(fd, CIR_CACHE_MAGIC)
    cir_store_cell(fd, CIR_CACHE_VER)
    cir_store_cell(fd, cid)  // v17: 编译器身份（重建即失效）
    cir_store_cell(fd, fp)
    cir_store_cell(fd, sig)
    cir_store_cell(fd, name_len)
    write_fd(fd, name, name_len)

    // Determine var range for this function
    cir_store_cell(fd, var_count)
    vi : ., mut = 0
    loop:
        if vi >= var_count:
            break
        v_idx := var_start + vi
        cir_store_cell(fd, irv_name(v_idx))
        cir_store_cell(fd, irv_id(v_idx))
        cir_store_cell(fd, irv_type(v_idx))
        vi = vi + 1

    // Write function's node range
    cir_store_cell(fd, node_count)
    ni2 : ., mut = 0
    loop:
        if ni2 >= node_count:
            break
        n := node_start + ni2
        cir_store_cell(fd, cell_load(g_df_nodes, n * ESZ_DFNODE + OFF_DF_OPCODE))
        cir_store_cell(fd, cell_load(g_df_nodes, n * ESZ_DFNODE + OFF_DF_DEST))
        cir_store_cell(fd, cell_load(g_df_nodes, n * ESZ_DFNODE + OFF_DF_S1))
        cir_store_cell(fd, cell_load(g_df_nodes, n * ESZ_DFNODE + OFF_DF_S2))
        cir_store_cell(fd, cell_load(g_df_nodes, n * ESZ_DFNODE + OFF_DF_S3))
        // Store the derived code only. The term-reference slot is a process-local
        // type-term index and cannot cross processes or resets. The auxiliary code
        // is derived from the same pair and is not stored either.
        cir_store_cell(fd, sh_dfn_code_of_slots(cell_load(g_df_nodes, n * ESZ_DFNODE + OFF_DF_TK),
                cell_load(g_df_nodes, n * ESZ_DFNODE + OFF_DF_AUX)))
        cir_store_cell(fd, cell_load(g_df_nodes, n * ESZ_DFNODE + OFF_DF_FIRST_EDGE))
        cir_store_cell(fd, cell_load(g_df_nodes, n * ESZ_DFNODE + OFF_DF_EDGE_COUNT))
        // The term and auxiliary slots are pure functions of the opcode and derived
        // code. The loader rederives them at the same point in the node sequence as
        // the cold path, keeping term indexes aligned.
        ni2 = ni2 + 1

    // Persist nested SG metadata with offsets relative to this function's
    // node range. Parent indices are local to this serialized section.
    cir_store_cell(fd, sg_count)
    sg_i : ., mut = 0
    loop:
        if sg_i >= g_sg_count:
            break
        kind := cell_load(g_sgs, sg_i * ESZ_SG + OFF_SG_KIND)
        nstart := cell_load(g_sgs, sg_i * ESZ_SG + OFF_SG_NSTART)
        if kind != SG_FUNC && nstart >= node_start && nstart < node_start + node_count:
            cir_store_cell(fd, kind)
            cir_store_cell(fd, cell_load(g_sgs, sg_i * ESZ_SG + OFF_SG_ENTER) - node_start)
            cir_store_cell(fd, cell_load(g_sgs, sg_i * ESZ_SG + OFF_SG_EXIT) - node_start)
            cir_store_cell(fd, cir_cache_sg_parent(sg_i, node_start, node_count))
            cir_store_cell(fd, nstart - node_start)
            cir_store_cell(fd, cell_load(g_sgs, sg_i * ESZ_SG + OFF_SG_NCOUNT))
        sg_i = sg_i + 1

    // Write only this function's edges. Endpoints are signed offsets relative to
    // node_start; the next pointers are rebuilt during load.
    cir_store_cell(fd, own_edge_count)
    ei : ., mut = 0
    loop:
        if ei >= own_edge_count:
            break
        e := edge_start + ei
        cir_store_cell(fd, cell_load(g_df_edges, e * ESZ_DFEDGE + OFF_DFE_FROM) - node_start)
        cir_store_cell(fd, cell_load(g_df_edges, e * ESZ_DFEDGE + OFF_DFE_TO) - node_start)
        cir_store_cell(fd, cell_load(g_df_edges, e * ESZ_DFEDGE + OFF_DFE_KIND))
        ei = ei + 1

    // Write function's instruction range
    cir_store_cell(fd, instr_count)
    ii : ., mut = 0
    loop:
        if ii >= instr_count:
            break
        inst := instr_start + ii
        cir_store_cell(fd, iri_op(inst))
        cir_store_cell(fd, iri_dest(inst))
        cir_store_cell(fd, iri_s1(inst))
        cir_store_cell(fd, iri_s2(inst))
        cir_store_cell(fd, iri_s3(inst))
        cir_store_cell(fd, iri_tk(inst))
        ii = ii + 1

    // Write the MATCH CASE section. Matches are stored in instruction order so
    // the loader can pair each group with its IR_MATCH without storing an index.
    cir_store_cell(fd, match_count)
    cs_i : ., mut = 0
    loop:
        if cs_i >= instr_count:
            break
        cs_inst := instr_start + cs_i
        if iri_op(cs_inst) == IR_MATCH:
            cs_start := iri_s2(cs_inst)
            cs_n := iri_s3(cs_inst)
            cir_store_cell(fd, cs_n)
            cj : ., mut = 0
            loop:
                if cj >= cs_n:
                    break
                cbase := (cs_start + cj) * 24
                cir_store_cell(fd, cell_load(g_lat_case, cbase + CCR_CASE_VALUE))
                cir_store_cell32(fd, cell_load32(g_lat_case, cbase + CCR_CASE_KIND))
                cir_store_cell32(fd, cell_load_i32(g_lat_case, cbase + CCR_CASE_STR))
                // Persist the semantic target label, not a node-relative wire
                // target. Labels are restored verbatim, so no baseline rebase
                // is needed on load.
                cir_store_cell32(fd, cell_load_i32(g_lat_case, cbase + CCR_CASE_TARGET))
                cir_store_cell32(fd, cell_load32(g_lat_case, cbase + CCR_CASE_FLAGS))
                cj = cj + 1
        cs_i = cs_i + 1

    // Write string constants used by this function
    cir_store_cell(fd, g_ir_str_const_count)
    si : ., mut = 0
    loop:
        if si >= g_ir_str_const_count:
            break
        ni3 := cell_load(g_ir_str_consts, si * 8)
        s := istr_get(ni3)
        sl := str_len(s)
        cir_store_cell(fd, sl)
        vi = 0
        loop:
            if vi >= sl:
                break
            cir_store_byte(fd, cell_load_byte(s, vi))
            vi = vi + 1
        si = si + 1

    // The intern journal stores contents, not ids. The loader replays the records
    // in order to bring the reader's string table to the same state as the writer's.
    // The first field is the writer's g_str_count at the start of the generation
    // window. The reader requires the same count before replay; a mismatch means
    // the two sides diverged earlier, so the snapshot is rejected.
    cir_store_cell(fd, g_cir_rec_base)
    cir_store_cell(fd, g_cir_rec_count)
    ri : ., mut = 0
    loop:
        if ri >= g_cir_rec_count:
            break
        rs := istr_get(cell_load(g_cir_rec_ids, ri * 8))
        rl := str_len(rs)
        cir_store_cell(fd, rl)
        rj : ., mut = 0
        loop:
            if rj >= rl:
                break
            cir_store_byte(fd, cell_load_byte(rs, rj))
            rj = rj + 1
        ri = ri + 1

    // Trailer: {var_start, node_start}. The var baseline is always validated. The
    // node baseline is required only when the snapshot contains an out-of-range
    // relative endpoint.
    cir_store_cell(fd, var_start)
    cir_store_cell(fd, node_start)

    written := syscall3(1, fd, g_cir_write_buf, g_cir_write_pos)
    syscall3(3, fd, 0, 0)
    if written != g_cir_write_pos:
        return -1
    return 0

// Write helpers for the in-memory cache serializer.
fn cir_store_cell(fd: int, val: int):
    cell_store(g_cir_write_buf, g_cir_write_pos, val)
    g_cir_write_pos = g_cir_write_pos + 8

// CASE records pack 32-bit fields after the 64-bit value. Keep them at their
// wire widths; widening them to 8 bytes would break the shared 24B row.
fn cir_store_cell32(fd: int, val: int):
    cell_store32(g_cir_write_buf, g_cir_write_pos, val)
    g_cir_write_pos = g_cir_write_pos + 4

fn cir_store_byte(fd: int, val: int):
    cell_store_byte(g_cir_write_buf, g_cir_write_pos, val)
    g_cir_write_pos = g_cir_write_pos + 1

fn write_fd(fd: int, data: string, len: int):
    write_pos : ., mut = 0
    loop:
        if write_pos >= len:
            break
        cell_store_byte(g_cir_write_buf, g_cir_write_pos, cell_load_byte(data, write_pos))
        g_cir_write_pos = g_cir_write_pos + 1
        write_pos = write_pos + 1

// === Snapshot read buffer ===
// The snapshot contents are transient: after load, no pointer into the buffer is
// kept. Variable names and strings are interned, and node and instruction fields
// are copied into global arrays. The old reader allocated a new buffer per
// function. The bump allocator never frees, so the buffers accumulated and could
// exhaust the heap; when allocation returned 0, the reader passed it to str_len
// and crashed.
//
// A single reusable buffer grows to the largest snapshot, not the sum of all
// snapshots. It has the same string layout as read_file: an 8-byte length header
// at buf-8, rewritten to fsize+1 after each read, so str_len(buf) == fsize and
// existing r64/str_sub consumers work unchanged.
g_cir_read_buf : string, mut
g_cir_read_cap : int, mut   // 数据区容量（不含 -8 处的 8B 长度头）

// Read a snapshot into the reusable buffer. Returns the file length, or -1 when
// the snapshot is unusable: open failure, empty file, short read, or allocation
// failure. The caller treats -1 as a cache miss and never as an empty table.
// A snapshot is a regular file written by one save_cir_cache write, so size <= 0
// is invalid and there is no pseudo-file read loop.
fn cir_read_snapshot(path: string) -> int:
    fd := syscall3(2, path, 0, 0)  // open(O_RDONLY)
    if fd < 0:
        return -1
    fsize := syscall3(8, fd, 0, 2)  // lseek(fd, 0, SEEK_END)
    if fsize <= 0:
        r0 := syscall3(3, fd, 0, 0)  // close
        return -1
    if fsize + 1 > g_cir_read_cap:
        new_cap : ., mut = g_cir_read_cap
        if new_cap < 4096:
            new_cap = 4096
        loop:
            if new_cap >= fsize + 1:
                break
            new_cap = new_cap * 2
        g_cir_read_buf = alloc(new_cap + 8)
        g_cir_read_cap = new_cap
    r2 := syscall3(8, fd, 0, 0)  // lseek(fd, 0, SEEK_SET)
    nread := syscall3(0, fd, g_cir_read_buf, fsize)  // read(fd, buf, fsize)
    r3 := syscall3(3, fd, 0, 0)  // close(fd)
    // A missing buffer (allocation exhausted, so g_cir_read_buf is 0 and read
    // returns EFAULT) or a short read is unusable: return a miss instead of parsing
    // half a snapshot. Do not add a `buf == 0` check: the bootstrap backend compiles
    // a string/int comparison through str_eq and str_len(0), which dereferences
    // NULL-8. The read EFAULT result is the safer guard.
    if nread != fsize:
        return -1
    cell_store(g_cir_read_buf, -8, fsize + 1)  // 长度头 = fsize（str_len 计算方式与 read_file 相同）
    return fsize

// Load a .cir cache file and restore DFG state.
// func_idx is the function index used to verify the cached fingerprints
// against the current AST. Returns 0 on success, -1 on failure (cache miss).
fn load_cir_cache(path: string, func_idx: int) -> int:
    // Load through the reusable buffer; see cir_read_snapshot.
    dlen := cir_read_snapshot(path)
    if dlen < 0:
        return -1
    data := g_cir_read_buf
    // Header is 48 bytes plus the function name, then at least one 8-byte section count.
    if dlen < 56:
        return -1
    pos : ., mut = 0

    // Validate header
    magic := cell_load(data, pos)
    pos = pos + 8
    if magic != CIR_CACHE_MAGIC:
        return -1
    ver := cell_load(data, pos)
    pos = pos + 8
    if ver != CIR_CACHE_VER:
        return -1

    // Compiler identity: an entry written by another compiler binary has different
    // string interning order and indexes, while the fingerprints cover only the
    // target source. Reject it here. Identity 0 is also rejected; save does not
    // write such entries.
    cid := cir_compiler_identity()
    entry_cid := cell_load(data, pos)
    pos = pos + 8
    if cid == 0 || entry_cid != cid:
        return -1

    fp := cell_load(data, pos)
    pos = pos + 8
    sig := cell_load(data, pos)
    pos = pos + 8

    // Verify fingerprints against current AST.
    // If the function body or signature changed, the cache is stale.
    fn_node := fi_ast_node(func_idx)
    current_fp := func_fingerprint(fn_node)
    if fp != current_fp:
        return -1
    current_sig := sig_fingerprint(fn_node)
    if sig != current_sig:
        return -1

    // Verify function identity (name)
    name_len := cell_load(data, pos)
    pos = pos + 8
    // Skip name string (we already know which function we tried to load)
    pos = pos + name_len

    // Trailer baselines are validated before restore. The shortest valid entry is a
    // 48-byte header plus a 16-byte trailer; dlen < 56 was rejected above, so use
    // 64 here.
    if dlen < 64:
        return -1

    // Structural pre-scan. It only reads; no globals are written. A destructive
    // restore that fails halfway would leave global arrays partially updated, and a
    // later rebuild would add to that state. Every range check must pass before the
    // first write. Truncation or an out-of-range field is a cache miss, never a
    // crash or a partial restore.
    p : ., mut = pos
    var_p := p
    p_var_count := cell_load(data, p)
    p = p + 8 + p_var_count * 24
    if p > dlen:
        return -1
    node_p := p
    p_node_count := cell_load(data, p)
    p = p + 8 + p_node_count * 64
    if p > dlen:
        return -1
    sg_p := p
    p_sg_count := cell_load(data, p)
    p = p + 8 + p_sg_count * 48
    if p > dlen:
        return -1
    edge_p := p
    p_edge_count := cell_load(data, p)
    p = p + 8 + p_edge_count * 24
    if p > dlen:
        return -1
    instr_p := p
    p_instr_count := cell_load(data, p)
    p = p + 8 + p_instr_count * 48
    if p > dlen:
        return -1
    // emit() creates one NOD and one instruction per operation, so the local
    // index is the same in both sections. The MATCH NOD mirror is validated below
    // through this mapping; require the counts to agree before relying on it.
    if p_node_count != p_instr_count:
        return -1
    // Count IR_MATCH instructions. The CASE section stores one group per MATCH
    // in instruction order, so this count must match the section header exactly.
    p_match_count : ., mut = 0
    p_mi : ., mut = 0
    loop:
        if p_mi >= p_instr_count:
            break
        if cell_load(data, instr_p + 8 + p_mi * 48) == IR_MATCH:
            p_match_count = p_match_count + 1
        p_mi = p_mi + 1

    // MATCH CASE section: match count, then per MATCH {case_count, rows}. This
    // is the semantic model: a row stores target_label = the IR body label
    // number. Validate every target against this function's IR_LABEL nodes
    // before any global is written.
    case_p := p
    if p + 8 > dlen:
        return -1
    p_case_matches := cell_load(data, p)
    p = p + 8
    if p_case_matches != p_match_count:
        return -1
    p_ci : ., mut = 0
    p_mi = 0
    p_expected_case : ., mut = -1
    loop:
        if p_ci >= p_case_matches:
            break
        // Pair this group with the next IR_MATCH in instruction order.
        loop:
            if p_mi >= p_instr_count:
                return -1
            if cell_load(data, instr_p + 8 + p_mi * 48) == IR_MATCH:
                break
            p_mi = p_mi + 1
        p_inst := instr_p + 8 + p_mi * 48
        p_ms := cell_load(data, p_inst + 24)
        p_mn := cell_load(data, p_inst + 32)
        if p + 8 > dlen:
            return -1
        p_cn := cell_load(data, p)
        p = p + 8
        if p_cn != p_mn || p_cn < 0 || p_ms < 0:
            return -1
        // The cached MATCH NOD is lowered into the .ccr, so its s2/s3 must
        // mirror the instruction exactly. A tampered NOD would otherwise hit and
        // change the warm CASE range after lower_to_ccr rebuilds from NOD.
        p_nod := node_p + 8 + p_mi * 64
        if cell_load(data, p_nod) != IR_MATCH:
            return -1
        if cell_load(data, p_nod + 24) != p_ms:
            return -1
        if cell_load(data, p_nod + 32) != p_mn:
            return -1
        // Matches in one function own contiguous ranges in increasing order.
        if p_expected_case >= 0 && p_ms != p_expected_case:
            return -1
        p_expected_case = p_ms + p_cn
        if p_cn > (dlen - p) / 24:
            return -1
        p_rj : ., mut = 0
        loop:
            if p_rj >= p_cn:
                break
            p_kind := cell_load32(data, p + 8)
            p_flags := cell_load32(data, p + 20)
            if p_kind < CCR_CASE_KIND_VALUE || p_kind > CCR_CASE_KIND_DEFAULT:
                return -1
            if p_flags != 0:
                return -1
            p_tl := cell_load_i32(data, p + 16)
            if p_tl < -1:
                return -1
            // A non-negative model target must name an IR_LABEL node in this
            // function. -1 is preserved for an unresolved target and will be
            // rejected by ccr_lower's wire validation instead of restoring a
            // bogus label.
            if p_tl >= 0:
                p_lf : ., mut = 0
                p_ln : ., mut = 0
                loop:
                    if p_ln >= p_node_count:
                        break
                    p_loff := node_p + 8 + p_ln * 64
                    if cell_load(data, p_loff) == IR_LABEL && cell_load(data, p_loff + 16) == p_tl:
                        p_lf = 1
                        break
                    p_ln = p_ln + 1
                if p_lf == 0:
                    return -1
            p = p + 24
            p_rj = p_rj + 1
        p_mi = p_mi + 1
        p_ci = p_ci + 1
    // No unmatched IR_MATCH may remain after the stored groups.
    loop:
        if p_mi >= p_instr_count:
            break
        if cell_load(data, instr_p + 8 + p_mi * 48) == IR_MATCH:
            return -1
        p_mi = p_mi + 1

    str_p := p
    if p + 8 > dlen:
        return -1
    p_str_count := cell_load(data, p)
    p = p + 8
    p_si : ., mut = 0
    loop:
        if p_si >= p_str_count:
            break
        sl_p := cell_load(data, p)
        p = p + 8 + sl_p
        if p > dlen:
            return -1
        p_si = p_si + 1
    // Intern journal section during the read-only scan: {base count, record count, records}.
    j_p := p
    p_j_base := cell_load(data, p)
    p = p + 8
    p_j_count := cell_load(data, p)
    p = p + 8
    p_ji : ., mut = 0
    loop:
        if p_ji >= p_j_count:
            break
        jl_p := cell_load(data, p)
        p = p + 8 + jl_p
        if p > dlen:
            return -1
        p_ji = p_ji + 1
    // The trailer starts at the scan end p, not at dlen-16. Trailing bytes after the
    // entry are ignored, as they always were; test_cir_warm_path.py D5 is the
    // regression case. A truncated entry, including a missing or partial trailer,
    // returns a miss.
    if p + 16 > dlen:
        return -1
    var_start_w := cell_load(data, p)
    node_start_w := cell_load(data, p + 8)
    // The var range is the only mirror domain that cannot be remapped cheaply:
    // var indexes appear in node dest/s1..s3 and instruction s1..s3. Always
    // validate it. A mismatch means the reader and writer are in different states,
    // so return a miss.
    if g_ir_var_count != var_start_w:
        return -1

    // Validate edge endpoints. When every relative endpoint is in
    // [0, node_count), shifting the node baseline does not change the meaning of
    // the relative ids, so node_start is not checked; otherwise every edit would
    // invalidate all later functions. If an endpoint is negative, it points to an
    // earlier function or a global node, and node_start must match.
    base_node_v := g_df_node_count
    need_node_witness : ., mut = 0
    ei_v : ., mut = 0
    loop:
        if ei_v >= p_edge_count:
            break
        eo_v := edge_p + 8 + ei_v * 24
        rf_v := cell_load(data, eo_v)
        rt_v := cell_load(data, eo_v + 8)
        if rf_v >= p_node_count:
            return -1
        // An endpoint at or past node_count is invalid.
        if rt_v >= p_node_count:
            return -1
        // A negative endpoint needs the node baseline witness.
        if rf_v < 0 || rt_v < 0:
            need_node_witness = 1
            if base_node_v + rf_v < 0:
                return -1
            if base_node_v + rt_v < 0:
                return -1
        ei_v = ei_v + 1
    if need_node_witness != 0:
        if g_df_node_count != node_start_w:
            return -1

    // Per-node witness: the stored edge_count must equal the number of outgoing
    // edges for that node in the edge list. The linked list is rebuilt by replay,
    // so check the stored value against the replay count before writing anything.
    // The tally buffer is small relative to the graph.
    if p_node_count > 0:
        tally := alloc(p_node_count * 8)
        tz : ., mut = 0
        loop:
            if tz >= p_node_count:
                break
            cell_store(tally, tz * 8, 0)
            tz = tz + 1
        ei_t : ., mut = 0
        loop:
            if ei_t >= p_edge_count:
                break
            rf_t := cell_load(data, edge_p + 8 + ei_t * 24)
            if rf_t >= 0:
                cell_store(tally, rf_t * 8, cell_load(tally, rf_t * 8) + 1)
            ei_t = ei_t + 1
        nj : ., mut = 0
        loop:
            if nj >= p_node_count:
                break
            ec_disk := cell_load(data, node_p + 8 + nj * 64 + 56)
            if ec_disk != cell_load(tally, nj * 8):
                return -1
            nj = nj + 1

    // Replay the intern journal before consuming any id. All ids in the snapshot are
    // writer-side indexes; they are valid only after the reader's string table
    // reaches the writer's state. Replay order is record order, which is generation
    // order, so each str_intern reproduces the writer's index.
    // The base count must equal the reader's g_str_count at the start of the
    // window. A mismatch means the two sides diverged, so return a miss.
    // --inject-cir-skip-journal skips replay and reproduces the original defect; it
    // exists only for mutation testing.
    if g_cir_skip_journal == 0:
        if g_str_count != p_j_base:
            return -1
        jp : ., mut = j_p + 16
        ji : ., mut = 0
        loop:
            if ji >= p_j_count:
                break
            jl2 := cell_load(data, jp)
            jp = jp + 8
            js := str_sub(data, jp, jl2)
            jp = jp + jl2
            str_intern(js)
            ji = ji + 1

    // CASE str indexes are intern ids, so they are meaningful only after the
    // journal replay above. Range-check them before the destructive array restore;
    // do not call istr_get here because a malformed id must stay a cache miss.
    if p_case_matches > 0:
        csp : ., mut = case_p + 8
        csi : ., mut = 0
        loop:
            if csi >= p_case_matches:
                break
            csn := cell_load(data, csp)
            csp = csp + 8
            csr : ., mut = 0
            loop:
                if csr >= csn:
                    break
                csidx := cell_load_i32(data, csp + 12)
                cskind := cell_load32(data, csp + 8)
                if csidx < -1 || csidx >= g_str_count:
                    return -1
                if cskind == CCR_CASE_KIND_STRING && csidx < 0:
                    return -1
                csp = csp + 24
                csr = csr + 1
            csi = csi + 1

    // Restore vars
    var_count := cell_load(data, pos)
    pos = pos + 8
    vi : ., mut = 0
    loop:
        if vi >= var_count:
            break
        name_ni := cell_load(data, pos)
        pos = pos + 8
        v_id := cell_load(data, pos)
        pos = pos + 8
        v_type := cell_load(data, pos)
        pos = pos + 8
        // Ensure var array is large enough
        if v_id >= g_ir_var_count:
            grow_ir_vars(v_id + 1)
            g_ir_var_count = v_id + 1
        irv_set_name(v_id, name_ni)
        irv_set_id(v_id, v_id)
        irv_set_type(v_id, v_type)
        vi = vi + 1

    // Restore nodes
    node_count := cell_load(data, pos)
    pos = pos + 8
    base_node := g_df_node_count
    grow_df_nodes(g_df_node_count + node_count)
    // Restored nodes did not pass through df_create_node, so write their node-to-
    // region mapping here. Otherwise subgraph_containing reads an uninitialized
    // g_df_node_region entry and crashes. The snapshot does not store inner
    // regions; the current function region opened by df_begin_func owns them,
    // which matches what the old linear g_sgs scan produced.
    grow_df_node_region(base_node + node_count)
    ni : ., mut = 0
    loop:
        if ni >= node_count:
            break
        n := base_node + ni
        cell_store(g_df_node_region, n * 8, g_cur_sg)
        cell_store(g_df_nodes, n * ESZ_DFNODE + OFF_DF_OPCODE, cell_load(data, pos))
        pos = pos + 8
        cell_store(g_df_nodes, n * ESZ_DFNODE + OFF_DF_DEST, cell_load(data, pos))
        pos = pos + 8
        cell_store(g_df_nodes, n * ESZ_DFNODE + OFF_DF_S1, cell_load(data, pos))
        pos = pos + 8
        cell_store(g_df_nodes, n * ESZ_DFNODE + OFF_DF_S2, cell_load(data, pos))
        pos = pos + 8
        cell_store(g_df_nodes, n * ESZ_DFNODE + OFF_DF_S3, cell_load(data, pos))
        pos = pos + 8
        // The snapshot stores one tk field, the derived code. Both slots are
        // rederived from it at the same point in the node sequence as the cold
        // path. The splitter has one implementation, sh_tk_split, so the term table
        // grows in the same order and cold and warm runs get the same term
        // indexes. Term references are not read from disk because they are
        // process-local indexes.
        tk_disk := cell_load(data, pos)
        pos = pos + 8
        // The load variant does not set the build-failure bit. A stored code may
        // fall outside the warm process's smaller type table; a cache hit must not
        // turn that into a compile failure. See sh_tk_split_load in ty_shadow.cr.
        sh_tk_split_load(cell_load(g_df_nodes, n * ESZ_DFNODE + OFF_DF_OPCODE), tk_disk)
        cell_store(g_df_nodes, n * ESZ_DFNODE + OFF_DF_TK, g_sh_slot_term)
        cell_store(g_df_nodes, n * ESZ_DFNODE + OFF_DF_AUX, g_sh_slot_aux)
        // The stored first_edge and edge_count are not trusted because edge indexes
        // shift with the new node baseline. Zero both and let df_add_edge_kind
        // rebuild them. The stored values were already checked by the per-node
        // witness during the pre-scan.
        cell_store(g_df_nodes, n * ESZ_DFNODE + OFF_DF_FIRST_EDGE, -1)
        cell_store(g_df_nodes, n * ESZ_DFNODE + OFF_DF_EDGE_COUNT, 0)
        pos = pos + 16   // 跳过盘上两字段
        // Record the producer for variables defined by this node. grow_df_arrays
        // fills new slots with -1, so a variable with no producer in the snapshot
        // stays -1. Only overwrite variables that the snapshot actually defines.
        // The old zero-filled slots read as node 0 and kept ghost edges.
        dest := cell_load(g_df_nodes, n * ESZ_DFNODE + OFF_DF_DEST)
        if dest >= 0:
            grow_df_arrays(dest + 1)
            cell_store(g_df_var_producer, dest * 8, n)
        ni = ni + 1
    g_df_node_count = base_node + node_count

    // Restore nested SG metadata (v13). The current function SG was opened by
    // df_begin_func; cached parent=-1 refers to that SG.
    sg_count := cell_load(data, pos)
    pos = pos + 8
    sg_base := g_sg_count
    sg_i : ., mut = 0
    loop:
        if sg_i >= sg_count:
            break
        new_sg := g_sg_count
        grow_sg(new_sg + 1)
        kind := cell_load(data, pos)
        pos = pos + 8
        enter_rel := cell_load(data, pos)
        pos = pos + 8
        exit_rel := cell_load(data, pos)
        pos = pos + 8
        parent_rel := cell_load(data, pos)
        pos = pos + 8
        nstart_rel := cell_load(data, pos)
        pos = pos + 8
        ncount := cell_load(data, pos)
        pos = pos + 8
        parent : ., mut = g_cur_sg
        if parent_rel >= 0:
            parent = sg_base + parent_rel
        f := new_sg * ESZ_SG
        cell_store(g_sgs, f + OFF_SG_KIND, kind)
        cell_store(g_sgs, f + OFF_SG_ENTER, base_node + enter_rel)
        cell_store(g_sgs, f + OFF_SG_EXIT, base_node + exit_rel)
        cell_store(g_sgs, f + OFF_SG_PARENT, parent)
        cell_store(g_sgs, f + OFF_SG_NSTART, base_node + nstart_rel)
        cell_store(g_sgs, f + OFF_SG_NCOUNT, ncount)
        g_sg_count = new_sg + 1

        // Later (inner) records overwrite the enclosing region mapping.
        rn : ., mut = base_node + nstart_rel
        rend := rn + ncount
        loop:
            if rn >= rend:
                break
            cell_store(g_df_node_region, rn * 8, new_sg)
            rn = rn + 1
        sg_i = sg_i + 1

    // Restore this function's edges. Each record is {rel_from, rel_to, kind}; the
    // next pointer is not stored. Replay through df_add_edge_kind, the same function
    // and insertion order as the cold path, so each node's list and edge_count match
    // the writer. Relative endpoints remain correct when a partial rebuild shifts
    // the node baseline.
    own_edge_count := cell_load(data, pos)
    pos = pos + 8
    ei : ., mut = 0
    loop:
        if ei >= own_edge_count:
            break
        rel_from := cell_load(data, pos)
        pos = pos + 8
        rel_to := cell_load(data, pos)
        pos = pos + 8
        e_kind := cell_load(data, pos)
        pos = pos + 8
        // Signed mapping: a negative endpoint points to an earlier function or a
        // global node. Bounds and the baseline witness were checked in the pre-scan.
        df_add_edge_kind(base_node + rel_from, base_node + rel_to, e_kind)
        ei = ei + 1

    // Restore instructions
    instr_count := cell_load(data, pos)
    pos = pos + 8
    base_instr := g_ir_instr_count
    grow_ir_instrs(g_ir_instr_count + instr_count)
    ii : ., mut = 0
    loop:
        if ii >= instr_count:
            break
        inst := base_instr + ii
        iri_set_op(inst, cell_load(data, pos))
        pos = pos + 8
        iri_set_dest(inst, cell_load(data, pos))
        pos = pos + 8
        iri_set_s1(inst, cell_load(data, pos))
        pos = pos + 8
        iri_set_s2(inst, cell_load(data, pos))
        pos = pos + 8
        iri_set_s3(inst, cell_load(data, pos))
        pos = pos + 8
        iri_set_tk(inst, cell_load(data, pos))
        pos = pos + 8
        ii = ii + 1
    g_ir_instr_count = base_instr + instr_count

    // Restore this function's semantic MATCH CASE ranges. The section is in the
    // same order as the restored instruction stream, so pair each group with the
    // next IR_MATCH and append at the current global model count. Targets are
    // already body label numbers and labels are restored verbatim, so only the
    // model start is rebased. s3 (the count) is unchanged. This restores the
    // model, not the wire; ccr_lower derives g_ccr_case afterwards. The pre-scan
    // already validated counts, ordering, target labels, and row domains, so
    // this phase cannot fail halfway.
    restored_matches := cell_load(data, pos)
    pos = pos + 8
    rm_i : ., mut = 0
    rm_scan : ., mut = base_instr
    loop:
        if rm_i >= restored_matches:
            break
        loop:
            if rm_scan >= g_ir_instr_count:
                return -1
            if iri_op(rm_scan) == IR_MATCH:
                break
            rm_scan = rm_scan + 1
        rm_count := cell_load(data, pos)
        pos = pos + 8
        rm_case_start := g_lat_case_count
        iri_set_s2(rm_scan, rm_case_start)
        // lower_to_ccr rebuilds instructions from NOD, so the mirror must get the
        // same model start. Node/instr local indexes are 1:1 (checked above).
        rm_nod := base_node + (rm_scan - base_instr)
        cell_store(g_df_nodes, rm_nod * ESZ_DFNODE + OFF_DF_S2, rm_case_start)
        rm_j : ., mut = 0
        loop:
            if rm_j >= rm_count:
                break
            rm_value := cell_load(data, pos)
            rm_kind := cell_load32(data, pos + 8)
            rm_str := cell_load_i32(data, pos + 12)
            rm_label := cell_load_i32(data, pos + 16)
            rm_flags := cell_load32(data, pos + 20)
            pos = pos + 24
            lat_case_append(rm_value, rm_kind, rm_str, rm_label, rm_flags)
            rm_j = rm_j + 1
        rm_scan = rm_scan + 1
        rm_i = rm_i + 1

    // Restore string constants (used by nodes/instrs)
    str_count := cell_load(data, pos)
    pos = pos + 8
    si : ., mut = 0
    loop:
        if si >= str_count:
            break
        sl := cell_load(data, pos)
        pos = pos + 8
        s := str_sub(data, pos, sl)
        pos = pos + sl
        track_str(str_intern(s))
        si = si + 1

    return 0

// Intern journal window. main.cr calls these around ir_gen_func when the cache is
// enabled. Ordering is deterministic: across functions, main.cr uses one loop for
// generation and load; within a function, both sides use the single str_intern
// insertion path in dyn_arr.cr, so record order is insertion order. Insertions
// outside the window come from parse and check, which are identical on both sides
// and do not need to be in the journal. Replaying records in order therefore
// reproduces the writer's indexes.
fn cir_rec_begin():
    g_cir_rec_on = 1
    g_cir_rec_count = 0
    g_cir_rec_base = g_str_count

fn cir_rec_end():
    g_cir_rec_on = 0

// Ensure cache directory exists.
fn make_cir_cache_dir():
    // Create .core/ directory hierarchy for cache.
    // mkdir syscall = 83 on x86-64 Linux: mkdir(path, mode)
    // Ignore EEXIST errors (directory may already exist).
    syscall3(83, ".core", 448, 0)
    syscall3(83, ".core/cache", 448, 0)
    syscall3(83, ".core/cache/cir", 448, 0)
