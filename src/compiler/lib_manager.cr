// === lib_manager.cr ===
// Library identity, ownership, dependency direction, and export tables.
//
// SourceManager owns files. LibManager owns the library each file belongs to:
//   @core  src/compiler
//   @std   src/stdlib
//   user   the project root (catch-all)
//
// Each library owns its own dependency and export arrays, so adding one library
// never interleaves ranges with another. Visibility builds on this table: a
// symbol is visible across libraries only when its owner explicitly exported it.

LIB_KIND_UNKNOWN : int = 0
LIB_KIND_CORE : int = 1
LIB_KIND_STD : int = 2
LIB_KIND_USER : int = 3

// Library record: name ni, root path, kind, deps (ptr/count/cap),
// exports (ptr/count/cap).
LIB_REC : int = 72
OFF_LIB_NAME : int = 0
OFF_LIB_ROOT : int = 8
OFF_LIB_KIND : int = 16
OFF_LIB_DEPS : int = 24
OFF_LIB_DEP_COUNT : int = 32
OFF_LIB_DEP_CAP : int = 40
OFF_LIB_EXPORTS : int = 48
OFF_LIB_EXP_COUNT : int = 56
OFF_LIB_EXP_CAP : int = 64

// Export record: name ni, symbol kind, declaration node.
LIB_EXPORT_REC : int = 24
OFF_LIB_EXP_NAME : int = 0
OFF_LIB_EXP_KIND : int = 8
OFF_LIB_EXP_NODE : int = 16

g_libs : string, mut
g_lib_count : int, mut
g_lib_cap : int, mut
g_lib_inited : int, mut
g_lib_on : int, mut

fn lib_reset():
    g_lib_count = 0
    g_lib_cap = 0
    g_lib_inited = 0
    g_lib_on = 0

fn grow_libs(needed: int):
    if needed <= g_lib_cap:
        return
    nc : ., mut = g_lib_cap * 2
    if nc < 8:
        nc = 8
    if nc < needed:
        nc = needed + 8
    nb := alloc(nc * LIB_REC)
    if g_lib_cap > 0:
        cell_copy(g_libs, g_lib_cap * LIB_REC, nb)
    g_libs = nb
    g_lib_cap = nc

fn lib_add(name: string, root: string, kind: int) -> int:
    lid := g_lib_count
    grow_libs(lid + 1)
    off := lid * LIB_REC
    cell_store_str(g_libs, off + OFF_LIB_NAME, name)
    cell_store_str(g_libs, off + OFF_LIB_ROOT, root)
    cell_store(g_libs, off + OFF_LIB_KIND, kind)
    cell_store_str(g_libs, off + OFF_LIB_DEPS, "")
    cell_store(g_libs, off + OFF_LIB_DEP_COUNT, 0)
    cell_store(g_libs, off + OFF_LIB_DEP_CAP, 0)
    cell_store_str(g_libs, off + OFF_LIB_EXPORTS, "")
    cell_store(g_libs, off + OFF_LIB_EXP_COUNT, 0)
    cell_store(g_libs, off + OFF_LIB_EXP_CAP, 0)
    g_lib_count = lid + 1
    return lid

fn lib_name(lid: int) -> string:
    if lid < 0 || lid >= g_lib_count:
        return ""
    return cell_load_str(g_libs, lid * LIB_REC + OFF_LIB_NAME)

fn lib_root(lid: int) -> string:
    if lid < 0 || lid >= g_lib_count:
        return ""
    return cell_load_str(g_libs, lid * LIB_REC + OFF_LIB_ROOT)

fn lib_kind(lid: int) -> int:
    if lid < 0 || lid >= g_lib_count:
        return LIB_KIND_UNKNOWN
    return cell_load(g_libs, lid * LIB_REC + OFF_LIB_KIND)

fn lib_find(name: string) -> int:
    i : ., mut = 0
    loop:
        if i >= g_lib_count:
            return -1
        if str_eq(lib_name(i), name) != 0:
            return i
        i = i + 1
    return -1

fn lib_dep_count(lid: int) -> int:
    if lid < 0 || lid >= g_lib_count:
        return 0
    return cell_load(g_libs, lid * LIB_REC + OFF_LIB_DEP_COUNT)

fn lib_dep_at(lid: int, i: int) -> int:
    if lid < 0 || lid >= g_lib_count:
        return -1
    if i < 0 || i >= lib_dep_count(lid):
        return -1
    arr := cell_load_str(g_libs, lid * LIB_REC + OFF_LIB_DEPS)
    return cell_load(arr, i * 8)

fn lib_reaches(from_lid: int, to_lid: int, depth: int) -> int:
    if from_lid < 0 || to_lid < 0 || depth > 32:
        return 0
    if from_lid == to_lid:
        return 1
    n := lib_dep_count(from_lid)
    i : ., mut = 0
    loop:
        if i >= n:
            return 0
        if lib_reaches(lib_dep_at(from_lid, i), to_lid, depth + 1) != 0:
            return 1
        i = i + 1
    return 0

fn lib_dep_add(from_lid: int, to_lid: int):
    if from_lid < 0 || from_lid >= g_lib_count || to_lid < 0 || to_lid >= g_lib_count:
        return
    // Reject self-edges and cycles: the library graph is a DAG.
    if lib_reaches(to_lid, from_lid, 0) != 0:
        return
    off := from_lid * LIB_REC
    arr : ., mut = cell_load_str(g_libs, off + OFF_LIB_DEPS)
    cnt := cell_load(g_libs, off + OFF_LIB_DEP_COUNT)
    cap : ., mut = cell_load(g_libs, off + OFF_LIB_DEP_CAP)
    i : ., mut = 0
    loop:
        if i >= cnt:
            break
        if cell_load(arr, i * 8) == to_lid:
            return
        i = i + 1
    if cnt >= cap:
        nc : ., mut = cap * 2
        if nc < 8:
            nc = 8
        nb := alloc(nc * 8)
        if cap > 0:
            cell_copy(arr, cap * 8, nb)
        arr = nb
        cap = nc
        cell_store_str(g_libs, off + OFF_LIB_DEPS, arr)
        cell_store(g_libs, off + OFF_LIB_DEP_CAP, cap)
    cell_store(arr, cnt * 8, to_lid)
    cell_store(g_libs, off + OFF_LIB_DEP_COUNT, cnt + 1)

fn lib_has_dep(from_lid: int, to_lid: int) -> int:
    if from_lid == to_lid:
        return 1
    if from_lid < 0 || from_lid >= g_lib_count:
        return 0
    off := from_lid * LIB_REC
    arr := cell_load_str(g_libs, off + OFF_LIB_DEPS)
    cnt := cell_load(g_libs, off + OFF_LIB_DEP_COUNT)
    i : ., mut = 0
    loop:
        if i >= cnt:
            return 0
        if cell_load(arr, i * 8) == to_lid:
            return 1
        i = i + 1
    return 0

// Dependency direction is explicit: @core may consume @std, @std is a leaf,
// and user code may consume @std/user. No one may consume @core internals.
fn lib_can_import(from_lid: int, to_lid: int) -> int:
    if from_lid == to_lid:
        return 1
    if to_lid < 0 || from_lid < 0:
        return 0
    if lib_kind(to_lid) == LIB_KIND_CORE && lib_kind(from_lid) != LIB_KIND_CORE:
        return 0
    return lib_has_dep(from_lid, to_lid)

fn lib_export_add(lid: int, name_ni: int, sym_kind: int, node: int):
    if lid < 0 || lid >= g_lib_count || name_ni < 0:
        return
    off := lid * LIB_REC
    arr : ., mut = cell_load_str(g_libs, off + OFF_LIB_EXPORTS)
    cnt := cell_load(g_libs, off + OFF_LIB_EXP_COUNT)
    cap : ., mut = cell_load(g_libs, off + OFF_LIB_EXP_CAP)
    if cnt >= cap:
        nc : ., mut = cap * 2
        if nc < 16:
            nc = 16
        nb := alloc(nc * LIB_EXPORT_REC)
        if cap > 0:
            cell_copy(arr, cap * LIB_EXPORT_REC, nb)
        arr = nb
        cap = nc
        cell_store_str(g_libs, off + OFF_LIB_EXPORTS, arr)
        cell_store(g_libs, off + OFF_LIB_EXP_CAP, cap)
    // Keep the export set ordered by (name, kind) so cross-library visibility
    // is a binary search, not a linear scan per symbol lookup.
    pos : ., mut = 0
    loop:
        if pos >= cnt:
            break
        en := cell_load(arr, pos * LIB_EXPORT_REC + OFF_LIB_EXP_NAME)
        ek := cell_load(arr, pos * LIB_EXPORT_REC + OFF_LIB_EXP_KIND)
        if en > name_ni || (en == name_ni && ek >= sym_kind):
            break
        pos = pos + 1
    if pos < cnt:
        en2 := cell_load(arr, pos * LIB_EXPORT_REC + OFF_LIB_EXP_NAME)
        ek2 := cell_load(arr, pos * LIB_EXPORT_REC + OFF_LIB_EXP_KIND)
        if en2 == name_ni && ek2 == sym_kind:
            cell_store(arr, pos * LIB_EXPORT_REC + OFF_LIB_EXP_NODE, node)
            return
    j : ., mut = cnt
    loop:
        if j <= pos:
            break
        src := (j - 1) * LIB_EXPORT_REC
        dst := j * LIB_EXPORT_REC
        cell_store(arr, dst + OFF_LIB_EXP_NAME, cell_load(arr, src + OFF_LIB_EXP_NAME))
        cell_store(arr, dst + OFF_LIB_EXP_KIND, cell_load(arr, src + OFF_LIB_EXP_KIND))
        cell_store(arr, dst + OFF_LIB_EXP_NODE, cell_load(arr, src + OFF_LIB_EXP_NODE))
        j = j - 1
    eoff := pos * LIB_EXPORT_REC
    cell_store(arr, eoff + OFF_LIB_EXP_NAME, name_ni)
    cell_store(arr, eoff + OFF_LIB_EXP_KIND, sym_kind)
    cell_store(arr, eoff + OFF_LIB_EXP_NODE, node)
    cell_store(g_libs, off + OFF_LIB_EXP_COUNT, cnt + 1)

fn lib_export_find_kind(lid: int, name_ni: int, kind: int) -> int:
    c := lib_export_count(lid)
    lo : ., mut = 0
    hi : ., mut = c
    loop:
        if lo >= hi:
            return -1
        mid := (lo + hi) / 2
        en := lib_export_name(lid, mid)
        ek := lib_export_kind(lid, mid)
        if en < name_ni || (en == name_ni && ek < kind):
            lo = mid + 1
        else if en > name_ni || (en == name_ni && ek > kind):
            hi = mid
        else:
            return mid
    return -1

fn lib_export_count(lid: int) -> int:
    if lid < 0 || lid >= g_lib_count:
        return 0
    return cell_load(g_libs, lid * LIB_REC + OFF_LIB_EXP_COUNT)

fn lib_export_arr(lid: int) -> string:
    if lid < 0 || lid >= g_lib_count:
        return ""
    return cell_load_str(g_libs, lid * LIB_REC + OFF_LIB_EXPORTS)

fn lib_export_name(lid: int, i: int) -> int:
    if i < 0 || i >= lib_export_count(lid):
        return -1
    return cell_load(lib_export_arr(lid), i * LIB_EXPORT_REC + OFF_LIB_EXP_NAME)

fn lib_export_kind(lid: int, i: int) -> int:
    if i < 0 || i >= lib_export_count(lid):
        return -1
    return cell_load(lib_export_arr(lid), i * LIB_EXPORT_REC + OFF_LIB_EXP_KIND)

fn lib_export_node(lid: int, i: int) -> int:
    if i < 0 || i >= lib_export_count(lid):
        return -1
    return cell_load(lib_export_arr(lid), i * LIB_EXPORT_REC + OFF_LIB_EXP_NODE)

fn lib_export_find(lid: int, name_ni: int) -> int:
    c := lib_export_count(lid)
    i : ., mut = 0
    loop:
        if i >= c:
            return -1
        if lib_export_name(lid, i) == name_ni:
            return i
        i = i + 1
    return -1

fn lib_set_user_root(root: string):
    uid := lib_find("@user")
    if uid < 0:
        return
    cell_store_str(g_libs, uid * LIB_REC + OFF_LIB_ROOT, root)

fn lib_register_defaults():
    c := lib_add("@core", "src/compiler/", LIB_KIND_CORE)
    s := lib_add("@std", "src/stdlib/", LIB_KIND_STD)
    u := lib_add("@user", "", LIB_KIND_USER)
    lib_dep_add(c, s)
    lib_dep_add(u, s)
    g_lib_inited = 1
    lib_set_user_root("")

fn lib_enable():
    g_lib_on = 1
    lib_init_defaults_once()

fn lib_init_defaults_once():
    if g_lib_inited != 0:
        return
    // Ownership is a cheap side table. It is initialized for every
    // compilation because the raw ABI visibility check needs the owner of the
    // current function even when the pub/library layer itself is off.
    lib_register_defaults()

fn lib_path_has_prefix(path: string, prefix: string) -> int:
    plen := str_len(prefix)
    if plen == 0:
        return 1
    if str_len(path) < plen:
        return 0
    i : ., mut = 0
    loop:
        if i >= plen:
            return 1
        if cell_load_byte(path, i) != cell_load_byte(prefix, i):
            return 0
        i = i + 1
    return 0

fn lib_relative_path(path: string) -> string:
    // Compute roots per call. Caching them in globals is unsafe across arena
    // resets (the self-test and LSP run several frontend passes in one process).
    cw := get_cwd()
    if str_len(cw) > 0:
        pre := cw + "/"
        if lib_path_has_prefix(path, pre) != 0:
            return str_sub(path, str_len(pre), str_len(path) - str_len(pre))
    exe := get_exe_path()
    if str_len(exe) > 0:
        root := parent_dir(parent_dir(exe))
        if str_len(root) > 0:
            pre2 := root + "/"
            if lib_path_has_prefix(path, pre2) != 0:
                return str_sub(path, str_len(pre2), str_len(path) - str_len(pre2))
    return path

fn lib_lookup_path(path: string) -> int:
    lib_init_defaults_once()
    if g_lib_inited == 0:
        return -1
    p := lib_relative_path(path)
    best : ., mut = -1
    best_len : ., mut = -1
    i : ., mut = 0
    loop:
        if i >= g_lib_count:
            break
        root := lib_root(i)
        rlen := str_len(root)
        if rlen > 0 && lib_path_has_prefix(p, root) != 0:
            if rlen > best_len:
                best = i
                best_len = rlen
        i = i + 1
    if best >= 0:
        return best
    if lib_path_is_core_impl(p) != 0:
        return lib_find("@core")
    return lib_find("@user")

// Fast, allocation-free guard: only paths rooted at the repository's `src/`
// tree can belong to the compiler implementation. User program paths and
// virtual names skip the per-directory scan below, which otherwise allocates
// a substring per byte per prefix and can exhaust the selftest heap.
fn lib_path_has_src_root(path: string) -> int:
    if lib_path_has_prefix(path, "src/") != 0:
        return 1
    slen := str_len(path)
    i : ., mut = 0
    loop:
        if i + 5 > slen:
            return 0
        if cell_load_byte(path, i) == 47 && cell_load_byte(path, i + 1) == 115 && cell_load_byte(path, i + 2) == 114 && cell_load_byte(path, i + 3) == 99 && cell_load_byte(path, i + 4) == 47:
            return 1
        i = i + 1
    return 0

// Match a directory prefix in either repository-relative form
// ("src/arch/x.cr") or absolute form ("<repo>/src/arch/x.cr").
fn lib_path_has_dir_prefix(path: string, prefix: string) -> int:
    if lib_path_has_prefix(path, prefix) != 0:
        return 1
    // A directory operand such as `src/compiler` (no trailing slash) is the
    // same library root as `src/compiler/`.
    plen := str_len(prefix)
    if plen > 0 && str_len(path) == plen - 1 && lib_path_has_prefix(prefix, path) != 0:
        return 1
    slen := str_len(path)
    i : ., mut = 0
    loop:
        if i + plen + 1 > slen:
            return 0
        if cell_load_byte(path, i) == 47:
            j : ., mut = 0
            found : ., mut = 1
            loop:
                if j >= plen:
                    break
                if cell_load_byte(path, i + 1 + j) != cell_load_byte(prefix, j):
                    found = 0
                    break
                j = j + 1
            if found != 0:
                return 1
        i = i + 1
    return 0

// Compiler implementation domain. The library model names the frontend
// `src/compiler/` as @core; the architecture/runtime/OS/format/LSP trees are
// part of the same implementation and must share its raw-ABI visibility.
// User projects are rooted elsewhere, so these prefixes are unambiguous.
fn lib_path_is_core_impl(path: string) -> int:
    if lib_path_has_src_root(path) == 0:
        return 0
    if lib_path_has_dir_prefix(path, "src/compiler/") != 0:
        return 1
    if lib_path_has_dir_prefix(path, "src/arch/") != 0:
        return 1
    if lib_path_has_dir_prefix(path, "src/runtime/") != 0:
        return 1
    if lib_path_has_dir_prefix(path, "src/os/") != 0:
        return 1
    if lib_path_has_dir_prefix(path, "src/format/") != 0:
        return 1
    if lib_path_has_dir_prefix(path, "src/lsp/") != 0:
        return 1
    if lib_path_has_dir_prefix(path, "src/targets/") != 0:
        return 1
    if lib_path_has_dir_prefix(path, "src/kernel/") != 0:
        return 1
    if lib_path_has_dir_prefix(path, "src/lattice/") != 0:
        return 1
    if lib_path_has_dir_prefix(path, "src/scheduler/") != 0:
        return 1
    return 0

fn lib_for_path(path: string) -> int:
    return lib_lookup_path(path)

// Drop the per-compilation export set but keep the allocated buffers. Parser
// (types/globals) and checker (functions/methods) repopulate it for the next
// compilation; this keeps long-lived LSP sessions from accumulating stale pub
// declarations.
fn lib_export_reset():
    lib_init_defaults_once()
    i : ., mut = 0
    loop:
        if i >= g_lib_count:
            return
        cell_store(g_libs, i * LIB_REC + OFF_LIB_EXP_COUNT, 0)
        i = i + 1

fn file_path_by_fni(fni: int) -> string:
    i : ., mut = 0
    loop:
        if i >= g_file_count:
            return ""
        if cell_load(g_files, i * 24) == fni:
            if cell_load(g_files, i * 24 + 8) == 0:
                return ""
            return cell_load_str(g_files, i * 24 + 8)
        i = i + 1
    return ""

fn lib_of_line(line: int) -> int:
    id := sm_for_line(line)
    if id < 0:
        return -1
    return sm_file_lib(id)

fn lib_of_node(node: int) -> int:
    // The owning file comes from the byte span. Going through the line first
    // would add a line-table search to every visibility check.
    if node < 0 || node >= g_ast_count:
        return -1
    lo := ast_lo(node)
    if lo <= 0:
        return -1
    id := sm_span_file(lo - 1)
    if id < 0:
        return -1
    return sm_file_lib(id)

fn lib_selftest() -> int:
    lib_reset()
    lib_enable()
    fails : ., mut = 0
    c := lib_find("@core")
    s := lib_find("@std")
    u := lib_find("@user")
    if c < 0 || s < 0 || u < 0:
        fails = fails + 1
    if lib_for_path("src/compiler/parser.cr") != c:
        fails = fails + 1
    if lib_for_path("src/stdlib/fmt.cr") != s:
        fails = fails + 1
    if lib_for_path("examples/main.cr") != u:
        fails = fails + 1
    if lib_for_path("src/compilerish/x.cr") != u:
        fails = fails + 1
    if lib_can_import(u, s) != 1:
        fails = fails + 1
    if lib_can_import(c, s) != 1:
        fails = fails + 1
    if lib_can_import(s, c) != 0:
        fails = fails + 1
    if lib_can_import(u, c) != 0:
        fails = fails + 1
    // The dependency graph is a DAG: adding an edge that would close a cycle
    // (including a self edge) is rejected.
    s_deps := lib_dep_count(s)
    lib_dep_add(s, c)
    if lib_dep_count(s) != s_deps:
        fails = fails + 1
    u_deps := lib_dep_count(u)
    lib_dep_add(u, u)
    if lib_dep_count(u) != u_deps:
        fails = fails + 1
    if lib_can_import(u, s) != 1:
        fails = fails + 1
    ni := str_intern("print")
    lib_export_add(s, ni, 1, 123)
    if lib_export_find(s, ni) < 0:
        fails = fails + 1
    if lib_export_node(s, 0) != 123:
        fails = fails + 1
    if lib_export_count(c) != 0:
        fails = fails + 1
    sm_reset()
    sf := sm_add_file("src/stdlib/probe.cr", "x")
    cf := sm_add_file("src/compiler/probe.cr", "x")
    if sm_file_lib(sf) != s:
        fails = fails + 1
    if sm_file_lib(cf) != c:
        fails = fails + 1
    if fails == 0:
        println("lib: 18/18 ok")
    else:
        print("lib: FAIL ")
        println(int_str(fails))
    return fails
