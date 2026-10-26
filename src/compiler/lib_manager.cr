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
    nc := g_lib_cap * 2
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

fn lib_dep_add(from_lid: int, to_lid: int):
    if from_lid < 0 || from_lid >= g_lib_count || to_lid < 0 || to_lid >= g_lib_count:
        return
    off := from_lid * LIB_REC
    arr := cell_load_str(g_libs, off + OFF_LIB_DEPS)
    cnt := cell_load(g_libs, off + OFF_LIB_DEP_COUNT)
    cap := cell_load(g_libs, off + OFF_LIB_DEP_CAP)
    i : ., mut = 0
    loop:
        if i >= cnt:
            break
        if cell_load(arr, i * 8) == to_lid:
            return
        i = i + 1
    if cnt >= cap:
        nc := cap * 2
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
    arr := cell_load_str(g_libs, off + OFF_LIB_EXPORTS)
    cnt := cell_load(g_libs, off + OFF_LIB_EXP_COUNT)
    cap := cell_load(g_libs, off + OFF_LIB_EXP_CAP)
    if cnt >= cap:
        nc := cap * 2
        if nc < 16:
            nc = 16
        nb := alloc(nc * LIB_EXPORT_REC)
        if cap > 0:
            cell_copy(arr, cap * LIB_EXPORT_REC, nb)
        arr = nb
        cap = nc
        cell_store_str(g_libs, off + OFF_LIB_EXPORTS, arr)
        cell_store(g_libs, off + OFF_LIB_EXP_CAP, cap)
    eoff := cnt * LIB_EXPORT_REC
    cell_store(arr, eoff + OFF_LIB_EXP_NAME, name_ni)
    cell_store(arr, eoff + OFF_LIB_EXP_KIND, sym_kind)
    cell_store(arr, eoff + OFF_LIB_EXP_NODE, node)
    cell_store(g_libs, off + OFF_LIB_EXP_COUNT, cnt + 1)

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
    if str_eq(str_sub(path, 0, plen), prefix) != 0:
        return 1
    return 0

fn lib_lookup_path(path: string) -> int:
    lib_init_defaults_once()
    if g_lib_inited == 0:
        return -1
    best : ., mut = -1
    best_len : ., mut = -1
    i : ., mut = 0
    loop:
        if i >= g_lib_count:
            break
        root := lib_root(i)
        rlen := str_len(root)
        if rlen > 0 && lib_path_has_prefix(path, root) != 0:
            if rlen > best_len:
                best = i
                best_len = rlen
        i = i + 1
    if best >= 0:
        return best
    if lib_path_is_core_impl(path) != 0:
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
    needle := "/" + prefix
    nlen := str_len(needle)
    slen := str_len(path)
    i : ., mut = 0
    loop:
        if i + nlen > slen:
            return 0
        if str_eq(str_sub(path, i, nlen), needle) != 0:
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
    if g_lib_on == 0:
        return -1
    return lib_lookup_path(path)

fn file_path_by_fni(fni: int) -> string:
    i : ., mut = 0
    loop:
        if i >= g_file_count:
            return ""
        if cell_load(g_files, i * 16) == fni:
            if cell_load(g_files, i * 16 + 8) == 0:
                return ""
            return cell_load_str(g_files, i * 16 + 8)
        i = i + 1
    return ""

fn lib_of_node(node: int) -> int:
    if node < 0 || node >= g_ast_count:
        return -1
    line := ast_line(node)
    if line <= 0 || line > g_line_count:
        return -1
    fni := cell_load(g_line_fileid, (line - 1) * 8)
    p := file_path_by_fni(fni)
    return lib_lookup_path(p)

fn lib_enable_if_user_line(line: int):
    if g_lib_on != 0:
        return
    if line <= 0 || line > g_line_count:
        return
    fni := cell_load(g_line_fileid, (line - 1) * 8)
    path := file_path_by_fni(fni)
    // Do not enable the library layer for declarations inside the compiler or
    // the standard library itself. Only user declarations opt in.
    if lib_path_has_dir_prefix(path, "src/compiler/") != 0:
        return
    if lib_path_has_prefix(path, "src/stdlib/") != 0:
        return
    g_lib_on = 1
    lib_register_defaults()

fn lib_owner_unfiltered(node: int) -> int:
    if node < 0 || node >= g_ast_count:
        return -1
    line := ast_line(node)
    if line <= 0 || line > g_line_count:
        return -1
    fni := cell_load(g_line_fileid, (line - 1) * 8)
    return lib_lookup_path(file_path_by_fni(fni))

// Enable the library layer only when a user declaration is exported. Standard
// library pub tags do not opt the whole compilation into filtering.
fn lib_prepare_from_pub():
    if g_saw_pub == 0 || g_lib_on != 0:
        return
    if g_lib_inited == 0:
        lib_register_defaults()
    i : ., mut = 0
    loop:
        if i >= g_func_count:
            return
        node := fi_ast_node(i)
        if fn_node_is_pub(node) != 0:
            owner := lib_owner_unfiltered(node)
            if owner >= 0 && lib_kind(owner) == LIB_KIND_USER:
                g_lib_on = 1
                return
        i = i + 1

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
        println("lib: 14/14 ok")
    else:
        print("lib: FAIL ")
        println(int_str(fails))
    return fails
