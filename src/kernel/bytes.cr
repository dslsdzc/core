// src/kernel/bytes.cr: byte helpers. The kernel is self-contained so its trust
// base can be audited independently.
// The byte layer (w8, bu8, w32, r32, cell_store/cell_load, and _dyncpy) is
// shared by the compiler and the target/runtime axes. It is not language
// semantics; semantic passes use typed operations instead.

fn w8(buf: string, pos: int, val: int):
    store8(buf, pos, val % 256)
fn bu8(buf: string, pos: int) -> int:
    return load8(buf, pos) % 256
fn w32(buf: string, pos: int, val: int):
    b0 : ., mut = val % 256
    t1 : ., mut = val / 256
    b1 : ., mut = t1 % 256
    t2 : ., mut = t1 / 256
    b2 : ., mut = t2 % 256
    t3 : ., mut = t2 / 256
    b3 : ., mut = t3 % 256
    // Borrow chain for two's complement of negative val (no 4294967296 constant)
    if b0 < 0:
        b0 = b0 + 256
        b1 = b1 - 1
    if b1 < 0:
        b1 = b1 + 256
        b2 = b2 - 1
    if b2 < 0:
        b2 = b2 + 256
        b3 = b3 - 1
    if b3 < 0:
        b3 = b3 + 256
    store8(buf,pos,b0)
    store8(buf,pos+1,b1)
    store8(buf,pos+2,b2)
    store8(buf,pos+3,b3)
fn r32(buf: string, pos: int) -> int:
    b0 := bu8(buf,pos)
    b1 := bu8(buf,pos+1)
    b2 := bu8(buf,pos+2)
    b3 := bu8(buf,pos+3)
    v := b0 + b1*256 + b2*65536
    if b3 >= 128:
        v = v + (b3 - 256) * 16777216
    else:
        v = v + b3 * 16777216
    return v
fn cell_store(buf: string, pos: int, val: int):
    cur : ., mut = val
    i : ., mut = 0
    loop:
        if i >= 8:
            break
        byte : ., mut = cur % 256
        if byte < 0:
            byte = byte + 256
        store8(buf, pos + i, byte)
        cur = (cur - byte) / 256
        i = i + 1
fn cell_load(buf: string, pos: int) -> int:
    // The low dword is unsigned. Reading it through r32 double-subtracts
    // 2^32 for negative values, e.g. -1 becomes -1 + (-1 * 2^32).
    lo := bu8(buf,pos) + bu8(buf,pos+1)*256 + bu8(buf,pos+2)*65536 + bu8(buf,pos+3)*16777216
    hi := r32(buf,pos+4)
    hi_part := hi * 65536
    hi_part = hi_part * 65536
    return lo + hi_part

fn _dyncpy(src: string, nbytes: int, dst: string):
    ci : ., mut = 0
    loop:
        if ci >= nbytes:
            break
        w8(dst, ci, bu8(src, ci))
        ci = ci + 1

// ── Compiler cell API ──
// The frontend uses these names for compiler-owned table slots. The cell width
// and raw byte access stay in this low-level module; semantic passes do not
// issue fixed-width memory operations.

fn cell_store32(buf: string, pos: int, val: int):
    w32(buf, pos, val)

fn cell_load32(buf: string, pos: int) -> int:
    return r32(buf, pos)

fn cell_store8(buf: string, pos: int, val: int):
    w8(buf, pos, val)

fn cell_load8(buf: string, pos: int) -> int:
    return bu8(buf, pos)

fn cell_store_byte(buf: string, pos: int, val: int):
    store8(buf, pos, val)

fn cell_load_byte(buf: string, pos: int) -> int:
    return load8(buf, pos)

fn cell_load64(buf: string, pos: int) -> int:
    return load64(buf, pos)

fn cell_copy(src: string, nbytes: int, dst: string):
    _dyncpy(src, nbytes, dst)

fn cell_load_str(buf: string, pos: int) -> string:
    return load_str_ptr(buf, pos)

fn cell_store_str(buf: string, pos: int, val: string) -> int:
    return store_str_ptr(buf, pos, val)
