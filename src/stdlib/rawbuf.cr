// === rawbuf.cr ===
// Standard-library boundary for raw byte buffers. This is the only stdlib file
// that calls the target's load8/store8 builtins; higher layers use these helpers.

fn rawRead8(buf: string, off: int) -> int:
    return load8(buf, off)

fn rawWrite8(buf: string, off: int, value: int):
    store8(buf, off, value % 256)

fn rawReadU32BE(buf: string, off: int) -> int:
    b0 := load8(buf, off)
    b1 := load8(buf, off + 1)
    b2 := load8(buf, off + 2)
    b3 := load8(buf, off + 3)
    return b0 * 16777216 + b1 * 65536 + b2 * 256 + b3

fn rawReadU32LE(buf: string, off: int) -> int:
    b0 := load8(buf, off)
    b1 := load8(buf, off + 1)
    b2 := load8(buf, off + 2)
    b3 := load8(buf, off + 3)
    return b3 * 16777216 + b2 * 65536 + b1 * 256 + b0

fn rawWriteU32BE(buf: string, off: int, value: int):
    x := value % 4294967296
    if x < 0:
        x = x + 4294967296
    store8(buf, off, x / 16777216 % 256)
    store8(buf, off + 1, x / 65536 % 256)
    store8(buf, off + 2, x / 256 % 256)
    store8(buf, off + 3, x % 256)

fn rawWriteU32LE(buf: string, off: int, value: int):
    x := value % 4294967296
    if x < 0:
        x = x + 4294967296
    store8(buf, off, x % 256)
    store8(buf, off + 1, x / 256 % 256)
    store8(buf, off + 2, x / 65536 % 256)
    store8(buf, off + 3, x / 16777216 % 256)
