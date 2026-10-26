// === rawbuf.cr ===
// Public raw byte buffer wrappers. The load8/store8 ABI lives in
// internal/bytes.cr; this file only keeps the historical public names.
import internal::bytes

fn rawRead8(buf: string, off: int) -> int, pub:
    return byteLoad(buf, off)

fn rawWrite8(buf: string, off: int, value: int), pub:
    byteStore(buf, off, value)

fn rawReadU32BE(buf: string, off: int) -> int, pub:
    return byteLoadU32BE(buf, off)

fn rawReadU32LE(buf: string, off: int) -> int, pub:
    return byteLoadU32LE(buf, off)

fn rawWriteU32BE(buf: string, off: int, value: int), pub:
    byteStoreU32BE(buf, off, value)

fn rawWriteU32LE(buf: string, off: int, value: int), pub:
    byteStoreU32LE(buf, off, value)
