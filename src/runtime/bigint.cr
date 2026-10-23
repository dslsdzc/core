// === bigint.cr ===
// Arbitrary precision integers for the Core runtime.
//
// Representation:
//   tagged value low bit 0: mathematical value times 2
//   tagged value low bit 1: pointer to a BigInt object plus 1
//
// BigInt object:
//   offset 0: sign (-1, 0, 1)
//   offset 8: digit count
//   offset 16: base 2^30 digits, little endian
//
// The 30-bit digit base keeps a digit product below 2^60. Adding a carry and
// an accumulator stays below 2^62, so the runtime's own limb arithmetic does
// not fall back into the BigInt path.
//
// Algorithms follow the imath integer algorithms (MIT), with normalization,
// schoolbook multiplication, and binary long division. GMP is used only as an
// optimization reference; no GMP source is copied.

BI_SIGN : int = 0
BI_LEN : int = 8
BI_DIGITS : int = 16
BI_BASE : int = 1073741824          // 2^30
BI_BASE2 : int = 1152921504606846976 // 2^60
BI_IMM_MAX : int = 4611686018427387903
BI_IMM_MIN : int = -4611686018427387904

g_bi_error : int, mut
g_bi_rem : int, mut

fn bi_runtime_error(message: string):
    // One shared runtime-error path for divide-by-zero and machine-word range
    // failures.  Keep the text here so the ELF and interpreter can converge on
    // the same contract later.
    syscall3(1, 2, message, str_len(message))
    syscall3(60, 1, 0, 0)

fn bi_is_big(v: int) -> int:
    if v % 2 != 0:
        return 1
    return 0

fn bi_imm(v: int) -> int:
    return v / 2

fn bi_tag(v: int) -> int:
    return v * 2

fn bi_big_ptr(v: int) -> string:
    p : ., mut = ""
    unsafe:
        p = @str_of(v - 1)
    return p

fn bi_tag_ptr(p: string) -> int:
    q : ., mut = 0
    unsafe:
        q = @ptr_of(p)
    return q + 1

fn bi_new(n: int) -> string:
    return alloc(BI_DIGITS + n * 8)

fn bi_sign_of(p: string) -> int:
    return r64(p, BI_SIGN)

fn bi_len_of(p: string) -> int:
    return r64(p, BI_LEN)

fn bi_digit(p: string, i: int) -> int:
    return r64(p, BI_DIGITS + i * 8)

fn bi_set_sign(p: string, s: int):
    w64(p, BI_SIGN, s)

fn bi_set_len(p: string, n: int):
    w64(p, BI_LEN, n)

fn bi_set_digit(p: string, i: int, d: int):
    w64(p, BI_DIGITS + i * 8, d)

fn bi_normalize(p: string) -> string:
    n := bi_len_of(p)
    loop:
        if n <= 0:
            break
        if bi_digit(p, n - 1) != 0:
            break
        n = n - 1
    bi_set_len(p, n)
    if n == 0:
        bi_set_sign(p, 0)
    return p

fn bi_from_imm(x: int) -> string:
    if x == -9223372036854775808:
        // -2^63 = -8 * 2^60.  Negating INT64_MIN in a raw machine int
        // would overflow back to itself.
        p := bi_new(3)
        bi_set_digit(p, 2, 8)
        bi_set_sign(p, -1)
        bi_set_len(p, 3)
        return p
    p := bi_new(3)
    if x == 0:
        return p
    v : ., mut = x
    s : ., mut = 1
    if v < 0:
        s = -1
        v = -v
    i : ., mut = 0
    loop:
        if v == 0:
            break
        bi_set_digit(p, i, v % BI_BASE)
        v = v / BI_BASE
        i = i + 1
    bi_set_sign(p, s)
    bi_set_len(p, i)
    return p

fn bi_as_big(v: int) -> string:
    if bi_is_big(v) != 0:
        return bi_big_ptr(v)
    return bi_from_imm(bi_imm(v))

fn bi_result(p: string) -> int:
    bi_normalize(p)
    n := bi_len_of(p)
    if n == 0:
        return 0
    if n > 3:
        return bi_tag_ptr(p)
    d0 := bi_digit(p, 0)
    d1 : ., mut = 0
    d2 : ., mut = 0
    if n > 1:
        d1 = bi_digit(p, 1)
    if n > 2:
        d2 = bi_digit(p, 2)
    if d2 > 3:
        return bi_tag_ptr(p)
    x := d0 + d1 * BI_BASE + d2 * BI_BASE2
    if bi_sign_of(p) < 0:
        x = -x
    if x < BI_IMM_MIN || x > BI_IMM_MAX:
        return bi_tag_ptr(p)
    return bi_tag(x)

fn bi_copy(p: string) -> string:
    n := bi_len_of(p)
    q := bi_new(n)
    bi_set_sign(q, bi_sign_of(p))
    bi_set_len(q, n)
    i : ., mut = 0
    loop:
        if i >= n:
            break
        bi_set_digit(q, i, bi_digit(p, i))
        i = i + 1
    return q

fn bi_cmp_abs(a: string, b: string) -> int:
    la := bi_len_of(a)
    lb := bi_len_of(b)
    if la < lb:
        return -1
    if la > lb:
        return 1
    i : ., mut = la
    loop:
        if i <= 0:
            break
        i = i - 1
        da := bi_digit(a, i)
        db := bi_digit(b, i)
        if da < db:
            return -1
        if da > db:
            return 1
    return 0

fn bi_cmp(a: int, b: int) -> int:
    pa := bi_as_big(a)
    pb := bi_as_big(b)
    sa := bi_sign_of(pa)
    sb := bi_sign_of(pb)
    if sa < sb:
        return -1
    if sa > sb:
        return 1
    if sa == 0:
        return 0
    c := bi_cmp_abs(pa, pb)
    if sa < 0:
        return bi_tag(-c)
    return bi_tag(c)

fn bi_add_abs(a: string, b: string) -> string:
    la := bi_len_of(a)
    lb := bi_len_of(b)
    n : ., mut = la
    if lb > n:
        n = lb
    r := bi_new(n + 1)
    carry : ., mut = 0
    i : ., mut = 0
    loop:
        if i >= n:
            break
        da : ., mut = 0
        db : ., mut = 0
        if i < la:
            da = bi_digit(a, i)
        if i < lb:
            db = bi_digit(b, i)
        s := da + db + carry
        bi_set_digit(r, i, s % BI_BASE)
        carry = s / BI_BASE
        i = i + 1
    if carry != 0:
        bi_set_digit(r, n, carry)
        n = n + 1
    bi_set_len(r, n)
    bi_set_sign(r, 1)
    return bi_normalize(r)

fn bi_sub_abs(a: string, b: string) -> string:
    la := bi_len_of(a)
    lb := bi_len_of(b)
    r := bi_new(la)
    borrow : ., mut = 0
    i : ., mut = 0
    loop:
        if i >= la:
            break
        da := bi_digit(a, i)
        db : ., mut = 0
        if i < lb:
            db = bi_digit(b, i)
        d := da - db - borrow
        if d < 0:
            d = d + BI_BASE
            borrow = 1
        else:
            borrow = 0
        bi_set_digit(r, i, d)
        i = i + 1
    bi_set_len(r, la)
    bi_set_sign(r, 1)
    return bi_normalize(r)

fn bi_add(a: int, b: int) -> int:
    if a == 0:
        return b
    if b == 0:
        return a
    pa := bi_as_big(a)
    pb := bi_as_big(b)
    sa := bi_sign_of(pa)
    sb := bi_sign_of(pb)
    if sa == sb:
        r := bi_add_abs(pa, pb)
        bi_set_sign(r, sa)
        return bi_result(r)
    c := bi_cmp_abs(pa, pb)
    if c == 0:
        return 0
    if c > 0:
        r := bi_sub_abs(pa, pb)
        bi_set_sign(r, sa)
        return bi_result(r)
    r := bi_sub_abs(pb, pa)
    bi_set_sign(r, sb)
    return bi_result(r)

fn bi_neg(a: int) -> int:
    if a == 0:
        return 0
    if bi_is_big(a) == 0:
        return bi_tag(-bi_imm(a))
    p := bi_big_ptr(a)
    q := bi_copy(p)
    bi_set_sign(q, -bi_sign_of(p))
    return bi_result(q)

fn bi_sub(a: int, b: int) -> int:
    return bi_add(a, bi_neg(b))

fn bi_mul(a: int, b: int) -> int:
    if a == 0 || b == 0:
        return 0
    pa := bi_as_big(a)
    pb := bi_as_big(b)
    la := bi_len_of(pa)
    lb := bi_len_of(pb)
    r := bi_new(la + lb)
    i : ., mut = 0
    loop:
        if i >= la:
            break
        carry : ., mut = 0
        ai := bi_digit(pa, i)
        j : ., mut = 0
        loop:
            if j >= lb:
                break
            cur := bi_digit(r, i + j) + ai * bi_digit(pb, j) + carry
            bi_set_digit(r, i + j, cur % BI_BASE)
            carry = cur / BI_BASE
            j = j + 1
        k : ., mut = i + lb
        loop:
            if carry == 0:
                break
            cur := bi_digit(r, k) + carry
            bi_set_digit(r, k, cur % BI_BASE)
            carry = cur / BI_BASE
            k = k + 1
        i = i + 1
    bi_set_len(r, la + lb)
    s : ., mut = 1
    if bi_sign_of(pa) != bi_sign_of(pb):
        s = -1
    bi_set_sign(r, s)
    return bi_result(r)

fn bi_is_zero(a: int) -> int:
    if a == 0:
        return 1
    if bi_is_big(a) == 0:
        return 0
    p := bi_big_ptr(a)
    if bi_len_of(p) == 0:
        return 1
    return 0

fn bi_pow2(k: int) -> int:
    v : ., mut = 1
    i : ., mut = 0
    loop:
        if i >= k:
            break
        v = v * 2
        i = i + 1
    return v

fn bi_bitlen_abs(p: string) -> int:
    n := bi_len_of(p)
    if n == 0:
        return 0
    top := bi_digit(p, n - 1)
    bits : ., mut = 0
    loop:
        if top == 0:
            break
        top = top / 2
        bits = bits + 1
    return (n - 1) * 30 + bits

fn bi_bit(p: string, pos: int) -> int:
    di := pos / 30
    if di >= bi_len_of(p):
        return 0
    return (bi_digit(p, di) / bi_pow2(pos % 30)) % 2

fn bi_set_bit(p: string, pos: int):
    di := pos / 30
    if di >= bi_len_of(p):
        return
    d := bi_digit(p, di) + bi_pow2(pos % 30)
    bi_set_digit(p, di, d)

fn bi_shl1(p: string) -> string:
    n := bi_len_of(p)
    r := bi_new(n + 1)
    carry : ., mut = 0
    i : ., mut = 0
    loop:
        if i >= n:
            break
        v := bi_digit(p, i) * 2 + carry
        bi_set_digit(r, i, v % BI_BASE)
        carry = v / BI_BASE
        i = i + 1
    bi_set_len(r, n)
    if carry != 0:
        bi_set_digit(r, n, carry)
        bi_set_len(r, n + 1)
    bi_set_sign(r, 1)
    return bi_normalize(r)

fn bi_add_small(a: int, b: int) -> int:
    return bi_add(a, bi_tag(b))

fn bi_mul_small(a: int, m: int) -> int:
    if a == 0 || m == 0:
        return 0
    if bi_is_big(a) == 0:
        x := bi_imm(a)
        if m > 0 && x >= BI_IMM_MIN / m && x <= BI_IMM_MAX / m:
            return bi_tag(x * m)
        if m < 0 && x <= BI_IMM_MIN / m && x >= BI_IMM_MAX / m:
            return bi_tag(x * m)
    p := bi_as_big(a)
    n := bi_len_of(p)
    r := bi_new(n + 1)
    carry : ., mut = 0
    i : ., mut = 0
    loop:
        if i >= n:
            break
        v := bi_digit(p, i) * m + carry
        bi_set_digit(r, i, v % BI_BASE)
        carry = v / BI_BASE
        i = i + 1
    bi_set_len(r, n)
    if carry != 0:
        bi_set_digit(r, n, carry)
        bi_set_len(r, n + 1)
    bi_set_sign(r, bi_sign_of(p))
    return bi_result(r)

fn bi_div_small(a: int, d: int) -> int:
    if d == 0:
        g_bi_error = 1
        g_bi_rem = 0
        return 0
    if bi_is_big(a) == 0:
        x := bi_imm(a)
        g_bi_rem = x % d
        return bi_tag(x / d)
    p := bi_as_big(a)
    n := bi_len_of(p)
    r := bi_new(n)
    rem : ., mut = 0
    i : ., mut = n
    loop:
        if i <= 0:
            break
        i = i - 1
        cur := rem * BI_BASE + bi_digit(p, i)
        bi_set_digit(r, i, cur / d)
        rem = cur % d
    bi_set_len(r, n)
    bi_set_sign(r, bi_sign_of(p))
    g_bi_rem = rem
    return bi_result(r)

fn bi_from_dec(s: string) -> int:
    n := str_len(s)
    i : ., mut = 0
    neg : ., mut = 0
    if n > 0 && load8(s, 0) == 45:
        neg = 1
        i = 1
    r : ., mut = 0
    loop:
        if i >= n:
            break
        c := load8(s, i)
        if c < 48 || c > 57:
            break
        r = bi_mul_small(r, 10)
        r = bi_add_small(r, c - 48)
        i = i + 1
    if neg != 0:
        r = bi_neg(r)
    return r

fn bi_to_dec(a: int) -> string:
    if a == 0:
        z := alloc(2)
        store8(z, 0, 48)
        return z
    neg : ., mut = 0
    p : ., mut = bi_as_big(a)
    if bi_sign_of(p) < 0:
        neg = 1
        p = bi_as_big(bi_neg(a))
    n := bi_len_of(p)
    cap := n * 10 + 4
    tmp := alloc(cap)
    pos : ., mut = cap - 1
    store8(tmp, pos, 0)
    cur : ., mut = bi_result(p)
    loop:
        if cur == 0:
            break
        q := bi_div_small(cur, 10)
        pos = pos - 1
        store8(tmp, pos, g_bi_rem + 48)
        cur = q
    if neg != 0:
        pos = pos - 1
        store8(tmp, pos, 45)
    m := cap - 1 - pos
    out := alloc(m + 1)
    j : ., mut = 0
    loop:
        if j >= m:
            break
        store8(out, j, load8(tmp, pos + j))
        j = j + 1
    return out

fn bi_divmod(a: int, b: int) -> int:
    if b == 0:
        bi_runtime_error("division by zero\n")
        g_bi_error = 1
        return 0
    if a == 0:
        g_bi_rem = 0
        return 0
    pa := bi_as_big(a)
    pb := bi_as_big(b)
    c := bi_cmp_abs(pa, pb)
    if c < 0:
        g_bi_rem = a
        return 0
    sa := bi_sign_of(pa)
    sb := bi_sign_of(pb)
    if c == 0:
        q : ., mut = 1
        if sa != sb:
            q = -1
        g_bi_rem = 0
        return bi_tag(q)
    n := bi_len_of(pa)
    q := bi_new(n + 1)
    bi_set_len(q, n + 1)
    rem_p := bi_from_imm(0)
    bits := bi_bitlen_abs(pa)
    pos : ., mut = bits
    loop:
        if pos <= 0:
            break
        pos = pos - 1
        rem_p = bi_shl1(rem_p)
        if bi_bit(pa, pos) != 0:
            rem_p = bi_as_big(bi_add_small(bi_result(rem_p), 1))
        if bi_cmp_abs(rem_p, pb) >= 0:
            rem_p = bi_sub_abs(rem_p, pb)
            bi_set_bit(q, pos)
    bi_set_len(q, n + 1)
    bi_set_sign(q, sa * sb)
    rq := bi_result(q)
    bi_set_sign(rem_p, sa)
    g_bi_rem = bi_result(rem_p)
    return rq

fn bi_div(a: int, b: int) -> int:
    q := bi_divmod(a, b)
    return q

fn bi_mod(a: int, b: int) -> int:
    q := bi_divmod(a, b)
    return g_bi_rem

fn bi_from_word(raw: int) -> int:
    if raw >= BI_IMM_MIN && raw <= BI_IMM_MAX:
        return bi_tag(raw)
    return bi_result(bi_from_imm(raw))

fn bi_from_uword(raw: int) -> int:
    if raw >= 0 && raw <= BI_IMM_MAX:
        return bi_tag(raw)
    return bi_result(bi_from_imm(raw))

fn bi_to_word_checked(a: int) -> int:
    g_bi_error = 0
    p := bi_as_big(a)
    n := bi_len_of(p)
    if n > 3:
        bi_runtime_error("integer out of machine-word range\n")
        g_bi_error = 1
        return 0
    d0 := bi_digit(p, 0)
    d1 : ., mut = 0
    d2 : ., mut = 0
    if n > 1:
        d1 = bi_digit(p, 1)
    if n > 2:
        d2 = bi_digit(p, 2)
    if d2 > 3:
        bi_runtime_error("integer out of machine-word range\n")
        g_bi_error = 1
        return 0
    x := d0 + d1 * BI_BASE + d2 * BI_BASE2
    if bi_sign_of(p) < 0:
        x = -x
    return x

fn bi_to_uword_checked(a: int) -> int:
    x := bi_to_word_checked(a)
    if g_bi_error != 0:
        return 0
    if x < 0:
        bi_runtime_error("integer out of unsigned machine-word range\n")
        g_bi_error = 1
        return 0
    return x

