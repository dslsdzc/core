// === big_lit.cr ===
// Big integer literal normalization for the frontend.
// The compiler itself uses machine-word ints; this module only keeps the exact
// decimal text of a literal that does not fit those ints.

// The frontend's alloc() header stores the requested byte count; str_len()
// subtracts one for the terminator.  The decimal builder therefore carries an
// explicit length instead of calling str_len on a freshly allocated work buffer.
g_big_dec_len : int, mut

// Multiply a little-endian decimal string by base, then add digit.
// dec_len is the exact digit count.  The new digit count is stored in
// g_big_dec_len.  Returns a new little-endian decimal buffer.
fn dec_mul_add(dec: string, dec_len: int, base: int, digit: int) -> string:
    n := dec_len
    out := alloc(n + 2)
    carry : ., mut = digit
    i : ., mut = 0
    loop:
        if i >= n:
            break
        v := (cell_load_byte(dec, i) - 48) * base + carry
        cell_store_byte(out, i, v % 10 + 48)
        carry = v / 10
        i = i + 1
    pos : ., mut = n
    loop:
        if carry == 0:
            break
        cell_store_byte(out, pos, carry % 10 + 48)
        carry = carry / 10
        pos = pos + 1
    cell_store_byte(out, pos, 0)
    g_big_dec_len = pos
    return out

// Convert an integer literal (decimal or 0x/0o/0b) to canonical decimal text.
fn big_lit_decimal(s: string) -> string:
    sl := str_len(s)
    base : ., mut = 10
    start : ., mut = 0
    if sl >= 2 && cell_load_byte(s, 0) == 48:
        pfx := cell_load_byte(s, 1)
        if pfx == 120 || pfx == 88:
            base = 16
            start = 2
        else if pfx == 111 || pfx == 79:
            base = 8
            start = 2
        else if pfx == 98 || pfx == 66:
            base = 2
            start = 2
    dec : ., mut = alloc(2)
    cell_store_byte(dec, 0, 48)
    dec_len : ., mut = 1
    i : ., mut = start
    loop:
        if i >= sl:
            break
        c := cell_load_byte(s, i)
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
        dec = dec_mul_add(dec, dec_len, base, d)
        dec_len = g_big_dec_len
        i = i + 1

    n := dec_len
    last : ., mut = n - 1
    loop:
        if last <= 0:
            break
        if cell_load_byte(dec, last) != 48:
            break
        last = last - 1
    if last == 0 && cell_load_byte(dec, 0) == 48:
        z := alloc(2)
        cell_store_byte(z, 0, 48)
        return z
    out := alloc(last + 2)
    j : ., mut = 0
    loop:
        if last < 0:
            break
        cell_store_byte(out, j, cell_load_byte(dec, last))
        last = last - 1
        j = j + 1
    cell_store_byte(out, j, 0)
    return out
