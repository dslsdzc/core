// fmt — String formatting and conversion utilities.
// All functions are pure (no side effects).

fn str_len(s: string) -> int {
    hdr := load64(s, -8);  // total bytes allocated (includes null)
    if hdr <= 0 { return 0; }
    return hdr - 1;        // exclude null terminator
}

fn chr(c: int) -> string {
    res := alloc(2);
    store8(res, 0, c);
    store8(res, 1, 0);
    return res;
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
    la := str_len(a); lb := str_len(b);
    if la != lb { return 0; }
    i : ., mut = 0;
    loop {
        if i >= la { return 1; }
        if load8(a, i) != load8(b, i) { return 0; }
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

fn to_str(n: int) -> string {
    return int_str(n);
}
// 字符串插值用（批 8 插值展开）：`bool` 洞的转换。**不经 int**——遵维护者「bool 不隐式转 int」裁定，
// 故不写 `int_str(b)`，而按真值给出 `"true"`/`"false"`。
// ⚠ 为何必须是「函数」而非合成 `if` 表达式（实测）：`"v=" + if b { "true" } else { "false" }`
// **rc=139**（手写同形亦崩 = 预存缺陷，另立条目）⇒ 转换只能走调用面，本函数即该调用面。
// ⚠ 代价（实测、已上报）：本函数进 `fmt.cr` ⇒ **所有 `import fmt` 程序的产物变大**
// （pa ELF 28822→28854 = +32B、`.ccr` +725B）⇒ canary 载体面变化，按 §6 纪律停下上报 + 同批重锁。
fn bool_str(b: bool) -> string {
    if b { return "true"; }
    return "false";
}


// Format string: replace {} with args sequentially.
// Example: format("x = {} and y = {}", int_str(x), int_str(y))
// Simple string interpolation: replaces "{0}" with first arg, "{1}" with second, etc.
// Usage: format("Hello {0}, you are {1} years old", name, age_str)
fn format(fmt_str: string, a0: string) -> string {
    fl := str_len(fmt_str);
    a0l := str_len(a0);
    // Fast path: no interpolation needed
    out_buf := alloc(fl + a0l + 16);
    ri := 0;  // write position
    fi := 0;  // read position
    loop {
        if fi >= fl { break; }
        c := load8(fmt_str, fi);
        if c == 123 && fi + 2 < fl && load8(fmt_str, fi+1) == 48 && load8(fmt_str, fi+2) == 125 {
            // "{0}" → replace with a0
            ai : ., mut = 0;
            loop { if ai >= a0l { break; } store8(out_buf, ri, load8(a0, ai)); ri = ri + 1; ai = ai + 1; }
            fi = fi + 3;
        } else {
            store8(out_buf, ri, c);
            ri = ri + 1; fi = fi + 1;
        }
    }
    store8(out_buf, ri, 0);
    return out_buf;
}

fn format2(fmt_str: string, a0: string, a1: string) -> string {
    return format(fmt_str, a0);  // fallback: format handles {0} only for now
}

// Integer to string → format helper
fn format_int(fmt_str: string, val: int) -> string {
    return format(fmt_str, int_str(val));
}

// ── float 打印（IEEE 754 double → 十进制字符串，定点最多 6 位小数）──
// 纯整数实现：提取符号/指数/尾数 → 规范化 → 整数部分 + 小数长除

fn fpow2i(k: int) -> int {
    v : int = 1; i : ., mut = 0;
    loop { if i >= k { break; } v = v * 2; i = i + 1; }
    return v;
}

fn float_str_bits(bits: int) -> string {
    // 符号（bit63）
    neg : int = 0; u : int = bits;
    if u < 0 {
        neg = 1;
        // Avoid spelling INT64_MIN: the lexer cannot represent its positive
        // magnitude as an integer token before applying unary minus.
        u = u - (-9223372036854775807) + 1;
    }
    // 提取字段（除以 2^52 代替移位）
    exp := (u / 4503599627370496) % 2048;
    mant := u % 4503599627370496;
    // 特殊值（IEEE 754 标准）
    if exp == 0 && mant == 0 {
        if neg != 0 { return "-0"; }
        return "0";
    }
    if exp == 2047 {
        if mant == 0 { if neg != 0 { return "-inf"; } return "inf"; }
        return "nan";
    }
    // 归一化：m = 1.mant（正规）或 0.mant（次正规），e = exp - 1023
    m : int = mant; e : int = exp - 1023;
    if exp != 0 { m = mant + 4503599627370496; }
    else { e = e + 1; }
    // value = m × 2^(e-52)（m 是 2^52 缩放的尾数）
    ip : int = 0;
    den : int = 1;   // 小数分母（小数部分 = r/den）
    r : int = 0;
    if e >= 52 {
        if e - 52 <= 10 { ip = m * fpow2i(e - 52); }
        else { ip = m * 1024; }   // 大数近似（超出 int 范围）
    } else {
        if 52 - e <= 53 {
            den = fpow2i(52 - e);
            ip = m / den;
            r = m % den;
        } else {
            ip = 0; den = fpow2i(53); r = m;  // 极小值
        }
    }
    // 长除：r × 10 / den，提取 7 位（第 7 位用于舍入）
    frac_str : ., mut = "";
    r2 : ., mut = r;
    di : ., mut = 0;
    loop { if di >= 7 { break; }
        r2 = r2 * 10;
        dg2 := r2 / den;
        if dg2 > 9 { dg2 = 9; }
        r2 = r2 - dg2 * den;
        if di < 6 { frac_str = frac_str + int_str(dg2); }
        else if dg2 >= 5 {
            // 第 7 位 ≥ 5：从第 6 位向前传播进位。
            fl2 := str_len(frac_str);
            carry : ., mut = 1;
            ri : ., mut = fl2 - 1;
            loop {
                if ri < 0 || carry == 0 { break; }
                digit := load8(frac_str, ri) - 48;
                if digit < 9 {
                    store8(frac_str, ri, digit + 49);
                    carry = 0;
                } else {
                    store8(frac_str, ri, 48);
                    ri = ri - 1;
                }
            }
            if carry != 0 { ip = ip + 1; }
        }
        di = di + 1; }
    // 去尾零
    fl := str_len(frac_str);
    loop { if fl <= 0 { break; } if load8(frac_str, fl - 1) != 48 { break; } fl = fl - 1; }
    if fl > 0 { frac_str = str_sub(frac_str, 0, fl); }
    // 组装
    out : ., mut = "";
    if neg != 0 { out = out + "-"; }
    out = out + int_str(ip);
    if fl > 0 { out = out + "." + frac_str; }
    return out;
}
