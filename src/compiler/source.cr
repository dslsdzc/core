// === source.cr ===
// SourceManager: file identity, spans, line tables, and virtual files.
//
// This is the first rewrite slice. It is standalone: no existing path uses it
// yet. A later slice makes tokenize() take (SourceManager, FileId) and gives
// every token a Span.
//
// File record (40 bytes):
//   path_ni, text, length, line_base, line_count
// Line starts are flattened across files. A file's line table is the range
// [line_base, line_base + line_count). Offsets are file-local, never the
// concatenated source offset.

OFF_SMF_PATH : int = 0
OFF_SMF_TEXT : int = 8
OFF_SMF_LEN : int = 16
OFF_SMF_LINE_BASE : int = 24
OFF_SMF_LINE_COUNT : int = 32
ESZ_SM_FILE : int = 40

g_sm_file_count : int, mut
g_sm_file_cap : int, mut
g_sm_files : string, mut

g_sm_line_count : int, mut
g_sm_line_cap : int, mut
g_sm_line_starts : string, mut

// Parallel to file records: owner library id (see lib_manager.cr).
g_sm_file_libs : string, mut
g_sm_file_lib_count : int, mut
g_sm_file_lib_cap : int, mut

struct Span:
    file: int
    lo: int
    hi: int

fn sm_reset():
    g_sm_file_count = 0
    g_sm_line_count = 0
    g_sm_file_lib_count = 0

fn grow_sm_files(needed: int):
    if needed <= g_sm_file_cap:
        return
    nc : ., mut = g_sm_file_cap * 2
    if nc < 8:
        nc = 8
    if nc < needed:
        nc = needed + 8
    nb := alloc(nc * ESZ_SM_FILE)
    if g_sm_file_cap > 0:
        cell_copy(g_sm_files, g_sm_file_cap * ESZ_SM_FILE, nb)
    g_sm_files = nb
    g_sm_file_cap = nc
    nl := alloc(nc * 8)
    if g_sm_file_lib_cap > 0:
        cell_copy(g_sm_file_libs, g_sm_file_lib_cap * 8, nl)
    g_sm_file_libs = nl
    g_sm_file_lib_cap = nc

fn grow_sm_lines(needed: int):
    if needed < g_sm_line_cap:
        return
    nc : ., mut = g_sm_line_cap * 2
    if nc < 8:
        nc = 8
    if nc < needed:
        nc = needed + 8
    nb := alloc(nc * 8)
    if g_sm_line_cap > 0:
        cell_copy(g_sm_line_starts, g_sm_line_cap * 8, nb)
    g_sm_line_starts = nb
    g_sm_line_cap = nc

// Register a file. The caller owns the text; SourceManager does not copy it.
fn sm_add_file(path: string, text: string) -> int:
    id := g_sm_file_count
    grow_sm_files(id + 1)
    path_ni := str_intern(path)
    base := g_sm_line_count
    grow_sm_lines(base + 1)
    cell_store(g_sm_line_starts, base * 8, 0)
    g_sm_line_count = base + 1

    tlen := str_len(text)
    i : ., mut = 0
    loop:
        if i >= tlen:
            break
        if cell_load_byte(text, i) == 10:
            grow_sm_lines(g_sm_line_count + 1)
            cell_store(g_sm_line_starts, g_sm_line_count * 8, i + 1)
            g_sm_line_count = g_sm_line_count + 1
        i = i + 1

    off := id * ESZ_SM_FILE
    cell_store(g_sm_files, off + OFF_SMF_PATH, path_ni)
    cell_store_str(g_sm_files, off + OFF_SMF_TEXT, text)
    cell_store(g_sm_files, off + OFF_SMF_LEN, tlen)
    cell_store(g_sm_files, off + OFF_SMF_LINE_BASE, base)
    cell_store(g_sm_files, off + OFF_SMF_LINE_COUNT, g_sm_line_count - base)
    cell_store(g_sm_file_libs, id * 8, lib_for_path(path))
    g_sm_file_lib_count = id + 1
    g_sm_file_count = id + 1
    return id

fn sm_add_virtual(name: string, text: string) -> int:
    return sm_add_file(name, text)

fn sm_file_count() -> int:
    return g_sm_file_count

fn sm_file_text(id: int) -> string:
    if id < 0 || id >= g_sm_file_count:
        return ""
    return cell_load_str(g_sm_files, id * ESZ_SM_FILE + OFF_SMF_TEXT)

fn sm_file_lib(id: int) -> int:
    if id < 0 || id >= g_sm_file_lib_count:
        return -1
    return cell_load(g_sm_file_libs, id * 8)

fn sm_file_path(id: int) -> string:
    if id < 0 || id >= g_sm_file_count:
        return ""
    return istr_get(cell_load(g_sm_files, id * ESZ_SM_FILE + OFF_SMF_PATH))

fn sm_file_len(id: int) -> int:
    if id < 0 || id >= g_sm_file_count:
        return 0
    return cell_load(g_sm_files, id * ESZ_SM_FILE + OFF_SMF_LEN)

fn sm_file_line_count(id: int) -> int:
    if id < 0 || id >= g_sm_file_count:
        return 0
    return cell_load(g_sm_files, id * ESZ_SM_FILE + OFF_SMF_LINE_COUNT)

fn sm_line_start(id: int, line: int) -> int:
    if id < 0 || id >= g_sm_file_count:
        return 0
    base := cell_load(g_sm_files, id * ESZ_SM_FILE + OFF_SMF_LINE_BASE)
    cnt := cell_load(g_sm_files, id * ESZ_SM_FILE + OFF_SMF_LINE_COUNT)
    if cnt <= 0:
        return 0
    ln : ., mut = line
    if ln < 1:
        ln = 1
    if ln > cnt:
        ln = cnt
    return cell_load(g_sm_line_starts, (base + ln - 1) * 8)

fn sm_line_index(id: int, off: int) -> int:
    if id < 0 || id >= g_sm_file_count:
        return 0
    base := cell_load(g_sm_files, id * ESZ_SM_FILE + OFF_SMF_LINE_BASE)
    cnt := cell_load(g_sm_files, id * ESZ_SM_FILE + OFF_SMF_LINE_COUNT)
    if cnt <= 0:
        return 0
    lo : ., mut = 0
    hi : ., mut = cnt - 1
    ans : ., mut = 0
    loop:
        if lo > hi:
            break
        mid := (lo + hi) / 2
        st := cell_load(g_sm_line_starts, (base + mid) * 8)
        if st <= off:
            ans = mid
            lo = mid + 1
        else:
            hi = mid - 1
    return ans

fn sm_location_line(id: int, off: int) -> int:
    return sm_line_index(id, off) + 1

fn sm_location_col(id: int, off: int) -> int:
    st := sm_line_start(id, sm_location_line(id, off))
    if off < st:
        return 1
    return off - st + 1

fn sm_line_text(id: int, line: int) -> string:
    if id < 0 || id >= g_sm_file_count:
        return ""
    cnt := cell_load(g_sm_files, id * ESZ_SM_FILE + OFF_SMF_LINE_COUNT)
    if line < 1 || line > cnt:
        return ""
    text := cell_load_str(g_sm_files, id * ESZ_SM_FILE + OFF_SMF_TEXT)
    start := sm_line_start(id, line)
    end : ., mut = cell_load(g_sm_files, id * ESZ_SM_FILE + OFF_SMF_LEN)
    if line < cnt:
        end = sm_line_start(id, line + 1) - 1
    if end > start:
        if cell_load_byte(text, end - 1) == 13:
            end = end - 1
    if end < start:
        end = start
    return str_sub(text, start, end - start)

fn sm_span(file: int, lo: int, hi: int) -> Span:
    return Span { file = file, lo = lo, hi = hi }

fn sm_selftest() -> int:
    sm_reset()
    fails : ., mut = 0

    a := sm_add_file("a.cr", "a\nbb\n")
    if g_sm_file_count != 1:
        fails = fails + 1
    if str_eq(sm_file_path(a), "a.cr") == 0:
        fails = fails + 1
    if str_eq(sm_file_text(a), "a\nbb\n") == 0:
        fails = fails + 1
    if sm_file_len(a) != 5:
        fails = fails + 1
    if sm_file_line_count(a) != 3:
        fails = fails + 1
    if sm_location_line(a, 0) != 1:
        fails = fails + 1
    if sm_location_col(a, 0) != 1:
        fails = fails + 1
    if sm_location_line(a, 2) != 2:
        fails = fails + 1
    if sm_location_col(a, 3) != 2:
        fails = fails + 1
    if sm_location_line(a, 5) != 3:
        fails = fails + 1
    if str_eq(sm_line_text(a, 1), "a") == 0:
        fails = fails + 1
    if str_eq(sm_line_text(a, 2), "bb") == 0:
        fails = fails + 1

    b := sm_add_virtual("<stdin>", "x")
    if b != 1:
        fails = fails + 1
    if str_eq(sm_file_path(b), "<stdin>") == 0:
        fails = fails + 1
    if sm_location_line(b, 0) != 1:
        fails = fails + 1
    if str_eq(sm_line_text(b, 1), "x") == 0:
        fails = fails + 1

    if fails == 0:
        println("source: 16/16 ok")
    else:
        print("source: FAIL ")
        println(int_str(fails))
    return fails
