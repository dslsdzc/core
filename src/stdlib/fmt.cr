// fmt — String formatting and conversion utilities.
// All functions are pure (no side effects).

fn str_len(s: string) -> int {
    i : ., mut = 0;
    loop {
        c := load8(s, i);
        if c == 0 { return i; }
        i = i + 1;
    }
    return 0;
}

fn get_char(s: string, idx: int) -> string {
    sl := str_len(s);
    if idx < 0 || idx >= sl { return ""; }
    c := load8(s, idx);
    res := alloc(2);
    store8(res, 0, c);
    store8(res, 1, 0);
    return res;
}

fn str_sub(s: string, start: int, len: int) -> string {
    slen := str_len(s);
    if start < 0 || start >= slen { return ""; }
    actual_len : ., mut = len;
    if start + actual_len > slen { actual_len = slen - start; }
    if actual_len <= 0 { return ""; }
    res := alloc(actual_len + 1);
    i : ., mut = 0;
    loop {
        if i >= actual_len { break; }
        c := load8(s, start + i);
        store8(res, i, c);
        i = i + 1;
    }
    store8(res, actual_len, 0);
    return res;
}

fn str_eq(a: string, b: string) -> int {
    i : ., mut = 0;
    loop {
        ca := load8(a, i);
        cb := load8(b, i);
        if ca != cb { return 0; }
        if ca == 0 { return 1; }
        i = i + 1;
    }
    return 0;
}

fn str_cmp(a: string, b: string) -> int {
    i : ., mut = 0;
    loop {
        ca := load8(a, i);
        cb := load8(b, i);
        if ca == 0 && cb == 0 { return 0; }
        if ca == 0 { return -1; }
        if cb == 0 { return 1; }
        if ca < cb { return -1; }
        if ca > cb { return 1; }
        i = i + 1;
    }
    return 0;
}

fn concat(a: string, b: string) -> string {
    aa := a;
    bb := b;
    lena := str_len(aa);
    lenb := str_len(bb);
    res := alloc(lena + lenb + 1);
    i : ., mut = 0;
    loop {
        if i >= lena { break; }
        c := load8(aa, i);
        store8(res, i, c);
        i = i + 1;
    }
    j : ., mut = 0;
    loop {
        if j >= lenb { break; }
        c := load8(bb, j);
        store8(res, lena + j, c);
        j = j + 1;
    }
    store8(res, lena + lenb, 0);
    return res;
}

fn int_str(n: int) -> string {
    if n == 0 { return "0"; }
    val : ., mut = n;
    neg : ., mut = 0;
    if val < 0 { neg = 1; val = -val; }
    tmp : ., mut = val;
    ndigits : ., mut = 0;
    loop {
        ndigits = ndigits + 1;
        tmp = tmp / 10;
        if tmp == 0 { break; }
    }
    extra : ., mut = neg;
    buf := alloc(ndigits + extra + 1);
    end : ., mut = ndigits;
    pos : ., mut = ndigits - 1;
    loop {
        rem := val % 10;
        store8(buf, pos, rem + 48);
        val = val / 10;
        if pos == 0 { break; }
        pos = pos - 1;
    }
    if neg == 1 {
        k : ., mut = ndigits;
        loop {
            if k == 0 { break; }
            ci := load8(buf, k - 1);
            store8(buf, k, ci);
            k = k - 1;
        }
        store8(buf, 0, 45);
        end = end + 1;
    }
    store8(buf, end, 0);
    return buf;
}

fn str_int(s: string) -> int {
    slen := str_len(s);
    if slen == 0 { return 0; }
    i : ., mut = 0;
    neg : ., mut = 0;
    c0 := load8(s, 0);
    if c0 == 45 { neg = 1; i = 1; }
    res : ., mut = 0;
    loop {
        if i >= slen { break; }
        c := load8(s, i);
        if c < 48 || c > 57 { break; }
        res = res * 10 + (c - 48);
        i = i + 1;
    }
    if neg == 1 { return -res; }
    return res;
}

fn to_string(n: int) -> string {
    return int_str(n);
}

// Format string: replace {} with args sequentially.
// Example: format("x = {} and y = {}", int_str(x), int_str(y))
// Rust-style: used with print( format(...) ) or println( format(...) )
// Note: variadic iteration requires interpreter or IR-gen expansion.
fn format(fmt_str: string, ...args: string) -> string {
    return fmt_str;
}
