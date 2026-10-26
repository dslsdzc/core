// === hash.cr ===
// Public checksum, cryptographic hash, MAC and KDF surface.
//
// Widths, seeds, polynomials, iteration counts and output lengths are explicit
// parameters. All bit work rides on internal/word.cr (no new IR opcodes), and
// byte access goes through internal/bytes.cr so the raw load8/store8 names stay
// out of user symbol tables.
import internal::word
import internal::bytes

// CRC-32/ISO-HDLC: reflected polynomial, init/xorout all-ones.
CRC32_POLY_ISO_HDLC : int, pub = 3988292384
CRC32_INIT_ISO_HDLC : int, pub = 4294967295
CRC32_XOROUT_ISO_HDLC : int, pub = 4294967295

fn hashConcat2(a: string, b: string) -> string:
    la := str_len(a)
    lb := str_len(b)
    out := alloc(la + lb + 1)
    byteCopy(a, 0, out, 0, la)
    byteCopy(b, 0, out, la, lb)
    byteStore(out, la + lb, 0)
    return out

fn hashConcat3(a: string, b: string, c: string) -> string:
    ab := hashConcat2(a, b)
    return hashConcat2(ab, c)

fn hashU8(value: int) -> string:
    out := alloc(2)
    byteStore(out, 0, value % 256)
    byteStore(out, 1, 0)
    return out

fn hashU32BE(value: int) -> string:
    out := alloc(5)
    byteStoreU32BE(out, 0, value)
    byteStore(out, 4, 0)
    return out

fn hashHex(bytes: string) -> string:
    n := str_len(bytes)
    out := alloc(n * 2 + 1)
    i : ., mut = 0
    loop:
        if i >= n:
            break
        b := byteLoad(bytes, i)
        hi := b / 16
        lo := b % 16
        if hi < 10:
            byteStore(out, i * 2, 48 + hi)
        else:
            byteStore(out, i * 2, 87 + hi)
        if lo < 10:
            byteStore(out, i * 2 + 1, 48 + lo)
        else:
            byteStore(out, i * 2 + 1, 87 + lo)
        i = i + 1
    byteStore(out, n * 2, 0)
    return out

// ── CRC-32 ──────────────────────────────────────────────────────────────────

fn crc32Byte(state: int, b: int, poly: int) -> int:
    c : ., mut = wordXor(state, b, 32)
    i : ., mut = 0
    loop:
        if i >= 8:
            break
        if wordAnd(c, 1, 32) != 0:
            c = wordXor(wordShr(c, 1, 32), poly, 32)
        else:
            c = wordShr(c, 1, 32)
        i = i + 1
    return c

fn crc32Init(seed: int) -> int, pub:
    return seed

fn crc32Update(state: int, data: string, poly: int) -> int, pub:
    c : ., mut = state
    i : ., mut = 0
    loop:
        if i >= str_len(data):
            break
        c = crc32Byte(c, byteLoad(data, i), poly)
        i = i + 1
    return c

fn crc32Final(state: int) -> int, pub:
    return wordXor(state, CRC32_XOROUT_ISO_HDLC, 32)

fn crc32(data: string) -> int, pub:
    return crc32With(data, CRC32_INIT_ISO_HDLC, CRC32_POLY_ISO_HDLC)

fn crc32With(data: string, init: int, poly: int) -> int, pub:
    return crc32Final(crc32Update(crc32Init(init), data, poly))

fn crc32Hex(data: string) -> string, pub:
    return hashHex(hashU32BE(crc32(data)))

// ── SHA-256 ─────────────────────────────────────────────────────────────────

fn sha256Compress(state: [int; 8], block: string, off: int):
    // Local, not a global constant: dynamic subscript on a global array
    // currently reads 0 in the backend (separate defect). Keep K here until
    // that path is fixed and pinned by a test.
    k : [int; 64], mut = [1116352408, 1899447441, 3049323471, 3921009573, 961987163, 1508970993, 2453635748, 2870763221, 3624381080, 310598401, 607225278, 1426881987, 1925078388, 2162078206, 2614888103, 3248222580, 3835390401, 4022224774, 264347078, 604807628, 770255983, 1249150122, 1555081692, 1996064986, 2554220882, 2821834349, 2952996808, 3210313671, 3336571891, 3584528711, 113926993, 338241895, 666307205, 773529912, 1294757372, 1396182291, 1695183700, 1986661051, 2177026350, 2456956037, 2730485921, 2820302411, 3259730800, 3345764771, 3516065817, 3600352804, 4094571909, 275423344, 430227734, 506948616, 659060556, 883997877, 958139571, 1322822218, 1537002063, 1747873779, 1955562222, 2024104815, 2227730452, 2361852424, 2428436474, 2756734187, 3204031479, 3329325298]
    w : [int; 64] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
    i : ., mut = 0
    loop:
        if i >= 16:
            break
        w[i] = byteLoadU32BE(block, off + i * 4)
        i = i + 1
    loop:
        if i >= 64:
            break
        s0 := wordXor(wordXor(wordRotr(w[i - 15], 7, 32), wordRotr(w[i - 15], 18, 32), 32), wordShr(w[i - 15], 3, 32), 32)
        s1 := wordXor(wordXor(wordRotr(w[i - 2], 17, 32), wordRotr(w[i - 2], 19, 32), 32), wordShr(w[i - 2], 10, 32), 32)
        w[i] = wordAdd(wordAdd(w[i - 16], s0, 32), wordAdd(w[i - 7], s1, 32), 32)
        i = i + 1
    a : ., mut = state[0]
    b : ., mut = state[1]
    c : ., mut = state[2]
    d : ., mut = state[3]
    e : ., mut = state[4]
    f : ., mut = state[5]
    g : ., mut = state[6]
    h : ., mut = state[7]
    i = 0
    loop:
        if i >= 64:
            break
        s1 := wordXor(wordXor(wordRotr(e, 6, 32), wordRotr(e, 11, 32), 32), wordRotr(e, 25, 32), 32)
        ch := wordXor(wordAnd(e, f, 32), wordAnd(wordNot(e, 32), g, 32), 32)
        t1 := wordAdd(wordAdd(wordAdd(h, s1, 32), ch, 32), wordAdd(k[i], w[i], 32), 32)
        s0 := wordXor(wordXor(wordRotr(a, 2, 32), wordRotr(a, 13, 32), 32), wordRotr(a, 22, 32), 32)
        maj := wordXor(wordXor(wordAnd(a, b, 32), wordAnd(a, c, 32), 32), wordAnd(b, c, 32), 32)
        t2 := wordAdd(s0, maj, 32)
        h = g
        g = f
        f = e
        e = wordAdd(d, t1, 32)
        d = c
        c = b
        b = a
        a = wordAdd(t1, t2, 32)
        i = i + 1
    state[0] = wordAdd(state[0], a, 32)
    state[1] = wordAdd(state[1], b, 32)
    state[2] = wordAdd(state[2], c, 32)
    state[3] = wordAdd(state[3], d, 32)
    state[4] = wordAdd(state[4], e, 32)
    state[5] = wordAdd(state[5], f, 32)
    state[6] = wordAdd(state[6], g, 32)
    state[7] = wordAdd(state[7], h, 32)

fn sha256(data: string) -> string, pub:
    state : [int; 8] = [1779033703, 3144134277, 1013904242, 2773480762, 1359893119, 2600822924, 528734635, 1541459225]
    slen := str_len(data)
    full := slen / 64
    i : ., mut = 0
    loop:
        if i >= full:
            break
        sha256Compress(state, data, i * 64)
        i = i + 1
    rem := slen - full * 64
    tail_len : ., mut = 64
    if rem + 9 > 64:
        tail_len = 128
    tail := alloc(tail_len + 1)
    j : ., mut = 0
    loop:
        if j >= tail_len:
            break
        byteStore(tail, j, 0)
        j = j + 1
    byteCopy(data, full * 64, tail, 0, rem)
    byteStore(tail, rem, 128)
    byteStoreU64BE(tail, tail_len - 8, slen * 8)
    sha256Compress(state, tail, 0)
    if tail_len == 128:
        sha256Compress(state, tail, 64)
    out := alloc(33)
    k : ., mut = 0
    loop:
        if k >= 8:
            break
        byteStoreU32BE(out, k * 4, state[k])
        k = k + 1
    byteStore(out, 32, 0)
    return out

fn sha256Hex(data: string) -> string, pub:
    return hashHex(sha256(data))

// ── HMAC-SHA-256 ────────────────────────────────────────────────────────────

fn hmacSha256(key: string, msg: string) -> string, pub:
    block : ., mut = 64
    k : ., mut = alloc(block + 1)
    i : ., mut = 0
    loop:
        if i >= block:
            break
        byteStore(k, i, 0)
        i = i + 1
    klen := str_len(key)
    if klen > block:
        hk := sha256(key)
        byteCopy(hk, 0, k, 0, str_len(hk))
    else:
        byteCopy(key, 0, k, 0, klen)
    ipad := alloc(block + 1)
    opad := alloc(block + 1)
    i = 0
    loop:
        if i >= block:
            break
        kb := byteLoad(k, i)
        byteStore(ipad, i, wordXor(kb, 54, 8))
        byteStore(opad, i, wordXor(kb, 92, 8))
        i = i + 1
    inner := sha256(hashConcat2(ipad, msg))
    return sha256(hashConcat2(opad, inner))

fn hmacSha256Hex(key: string, msg: string) -> string, pub:
    return hashHex(hmacSha256(key, msg))

// ── HKDF-SHA-256 (RFC 5869) ─────────────────────────────────────────────────

fn hkdfSha256Extract(ikm: string, salt: string) -> string, pub:
    return hmacSha256(salt, ikm)

fn hkdfSha256Expand(prk: string, info: string, length: int) -> string, pub:
    out := alloc(length + 1)
    t : ., mut = ""
    pos : ., mut = 0
    counter : ., mut = 1
    loop:
        if pos >= length:
            break
        t = hmacSha256(prk, hashConcat3(t, info, hashU8(counter)))
        n : ., mut = str_len(t)
        if n > length - pos:
            n = length - pos
        byteCopy(t, 0, out, pos, n)
        pos = pos + n
        counter = counter + 1
    byteStore(out, length, 0)
    return out

fn hkdfSha256(ikm: string, salt: string, info: string, length: int) -> string, pub:
    return hkdfSha256Expand(hkdfSha256Extract(ikm, salt), info, length)

fn hkdfSha256Hex(ikm: string, salt: string, info: string, length: int) -> string, pub:
    return hashHex(hkdfSha256(ikm, salt, info, length))

// ── PBKDF2-HMAC-SHA-256 (RFC 8018) ──────────────────────────────────────────

fn pbkdf2Sha256(password: string, salt: string, iterations: int, length: int) -> string, pub:
    out := alloc(length + 1)
    blocks := (length + 31) / 32
    bi : ., mut = 1
    pos : ., mut = 0
    loop:
        if bi > blocks:
            break
        u : ., mut = hmacSha256(password, hashConcat2(salt, hashU32BE(bi)))
        t := alloc(33)
        byteCopy(u, 0, t, 0, 32)
        byteStore(t, 32, 0)
        j : ., mut = 2
        loop:
            if j > iterations:
                break
            u = hmacSha256(password, u)
            k : ., mut = 0
            loop:
                if k >= 32:
                    break
                byteStore(t, k, wordXor(byteLoad(t, k), byteLoad(u, k), 8))
                k = k + 1
            j = j + 1
        n : ., mut = 32
        if n > length - pos:
            n = length - pos
        byteCopy(t, 0, out, pos, n)
        pos = pos + n
        bi = bi + 1
    byteStore(out, length, 0)
    return out

fn pbkdf2Sha256Hex(password: string, salt: string, iterations: int, length: int) -> string, pub:
    return hashHex(pbkdf2Sha256(password, salt, iterations, length))
