// === internal/bytes.cr ===
// Library-internal byte access. This is the only stdlib internal layer that
// names the target raw memory ABI; public modules use these helpers instead of
// load8/store8 so the raw names stay out of user symbol tables.

fn byteLoad(buf: string, off: int) -> int:
    return load8(buf, off)

fn byteStore(buf: string, off: int, value: int):
    store8(buf, off, value % 256)

fn byteLoadU32BE(buf: string, off: int) -> int:
    b0 := load8(buf, off)
    b1 := load8(buf, off + 1)
    b2 := load8(buf, off + 2)
    b3 := load8(buf, off + 3)
    return b0 * 16777216 + b1 * 65536 + b2 * 256 + b3

fn byteLoadU32LE(buf: string, off: int) -> int:
    b0 := load8(buf, off)
    b1 := load8(buf, off + 1)
    b2 := load8(buf, off + 2)
    b3 := load8(buf, off + 3)
    return b3 * 16777216 + b2 * 65536 + b1 * 256 + b0

fn byteStoreU32BE(buf: string, off: int, value: int):
    x := value % 4294967296
    if x < 0:
        x = x + 4294967296
    store8(buf, off, x / 16777216 % 256)
    store8(buf, off + 1, x / 65536 % 256)
    store8(buf, off + 2, x / 256 % 256)
    store8(buf, off + 3, x % 256)

fn byteStoreU32LE(buf: string, off: int, value: int):
    x := value % 4294967296
    if x < 0:
        x = x + 4294967296
    store8(buf, off, x % 256)
    store8(buf, off + 1, x / 256 % 256)
    store8(buf, off + 2, x / 65536 % 256)
    store8(buf, off + 3, x / 16777216 % 256)

fn byteLoadU64BE(buf: string, off: int) -> int:
    return byteLoadU32BE(buf, off) * 4294967296 + byteLoadU32BE(buf, off + 4)

fn byteLoadU64LE(buf: string, off: int) -> int:
    return byteLoadU32LE(buf, off + 4) * 4294967296 + byteLoadU32LE(buf, off)

fn byteStoreU64BE(buf: string, off: int, value: int):
    x := value % 18446744073709551616
    if x < 0:
        x = x + 18446744073709551616
    byteStoreU32BE(buf, off, x / 4294967296)
    byteStoreU32BE(buf, off + 4, x % 4294967296)

fn byteStoreU64LE(buf: string, off: int, value: int):
    x := value % 18446744073709551616
    if x < 0:
        x = x + 18446744073709551616
    byteStoreU32LE(buf, off, x % 4294967296)
    byteStoreU32LE(buf, off + 4, x / 4294967296)

fn byteCopy(src: string, src_off: int, dst: string, dst_off: int, n: int):
    i : ., mut = 0
    loop:
        if i >= n:
            break
        store8(dst, dst_off + i, load8(src, src_off + i))
        i = i + 1
