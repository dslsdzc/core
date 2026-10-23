// === big_lit.cr ===
// Big integer literal normalization for the frontend.
// The compiler itself uses machine-word ints; this module only keeps the exact
// decimal text of a literal that does not fit those ints.

// Multiply a little-endian decimal string by base, then add digit.
// Returns a new little-endian decimal string.
fn dec_mul_add(dec: string, base: int, digit: int) -> string:
    n := str_len(dec)
    out := alloc(n + 2)
    carry : ., mut = digit
    i : ., mut = 0
    loop:
        if i >= n:
            break
        v := (load8(dec, i) - 48) * base + carry
        store8(out, i, v % 10 + 48)
        carry = v / 10
        i = i + 1
    pos : ., mut = n
    loop:
        if carry == 0:
            break
        store8(out, pos, carry % 10 + 48)
        carry = carry / 10
        pos = pos + 1
    store8(out, pos, 0)
    return out

// Convert an integer literal (decimal or 0x/0o/0b) to canonical decimal text.
fn big_lit_decimal(s: string) -> string:
    sl := str_len(s)
    base : ., mut = 10
    start : ., mut = 0
    if sl >= 2 && load8(s, 0) == 48:
        pfx := load8(s, 1)
        if pfx == 120 || pfx == 88:
            base = 16
            start = 2
        else if pfx == 111 || pfx == 79:
            base = 8
            start = 2
        else if pfx == 98 || pfx == 66:
            base = 2
            start = 2
    dec := alloc(2)
    store8(dec, 0, 48)
    i : ., mut = start
    loop:
        if i >= sl:
            break
        c := load8(s, i)
        if c == 95:
            i = i + 1
            continue
        d : ., mut = 0
        if c >= 48 && c <= 57:
            d = c - 48
        else if c >= 65 && c <= 70:
            d = c - 55
        else:
            d = c - 87
        dec = dec_mul_add(dec, base, d)
        i = i + 1

    n := str_len(dec)
    last : ., mut = n - 1
    loop:
        if last <= 0:
            break
        if load8(dec, last) != 48:
            break
        last = last - 1
    if last == 0 && load8(dec, 0) == 48:
        z := alloc(2)
        store8(z, 0, 48)
        return z
    out := alloc(last + 2)
    j : ., mut = 0
    loop:
        if last < 0:
            break
        store8(out, j, load8(dec, last))
        last = last - 1
        j = j + 1
    store8(out, j, 0)
    return out
