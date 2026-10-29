// Raw allocator bodies. Compiled by tools/gen_alloc_blob.py with raw-int
// semantics; the blob generator supplies cell_load/cell_store and patches the
// globals listed in EXTERNAL_GLOBALS.

g_heap_ptr : string, mut
g_heap_end : string, mut
g_alloc_fail_request : int, mut
g_alloc_fail_class : int, mut
g_alloc_fail_cursor : int, mut
g_alloc_fail_limit : int, mut

fn alloc_ptr(v: int) -> string:
    p : ., mut = ""
    unsafe:
        p = @str_of(v)
    return p

fn alloc_uword(s: string) -> int:
    v : ., mut = 0
    unsafe:
        v = @ptr_of(s)
    return v

fn alloc_simple(size: int, heap_start: string) -> string:
    if size < 0:
        return alloc_ptr(0)
    if size > 67108864:
        return alloc_ptr(0)
    aligned : ., mut = (size + 15) / 8 * 8
    hp := g_heap_ptr
    hp_raw : ., mut = alloc_uword(hp)
    he_raw : ., mut = alloc_uword(g_heap_end)
    if hp_raw == 0:
        hp = heap_start
        hp_raw = alloc_uword(hp)
        he_raw = hp_raw + 1073741824
        g_heap_ptr = hp
        g_heap_end = alloc_ptr(he_raw)
    new_raw : ., mut = hp_raw + aligned
    if new_raw > he_raw:
        heap_expand()
        hp = g_heap_ptr
        hp_raw = alloc_uword(hp)
        he_raw = alloc_uword(g_heap_end)
        new_raw = hp_raw + aligned
        if new_raw > he_raw:
            g_alloc_fail_request = size
            g_alloc_fail_class = -1
            g_alloc_fail_cursor = hp_raw
            g_alloc_fail_limit = he_raw
            syscall3(60, 132, 0, 0)
            return alloc_ptr(0)
    g_heap_ptr = alloc_ptr(new_raw)
    i : ., mut = 0
    loop:
        if i >= aligned:
            break
        store8(hp, i, 0)
        i = i + 1
    cell_store(hp, 0, size)
    return alloc_ptr(hp_raw + 8)
