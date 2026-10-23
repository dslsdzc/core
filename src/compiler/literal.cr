// === literal.cr ===
// Numeric literal conversion. The lexer stores the source text; the parser
// converts it to the representation used by the AST.

// 2^k（纯整数，k >= 0）
fn pow2i(k: int) -> int:
    v : int = 1
    i : ., mut = 0
    loop:
        if i >= k:
            break
        v = v * 2
        i = i + 1
    return v

// Convert a decimal string to IEEE 754 binary64 bits using integer arithmetic
// (at most 18 significant digits). The value is ip + fp/den: find the integer
// bit width, long-divide the fraction to 64 bits, then take a 53-bit significand.
// The result truncates rather than rounds, within about 2 ulp for 18 digits.
fn str_to_f64_bits(s: string) -> int:
    sl := str_len(s)
    i : ., mut = 0
    neg : int = 0
    if i < sl && load8(s, i) == 45:
        neg = 1
        i = i + 1
    ip : int = 0
    fp : int = 0
    den : int = 1
    sd : int = 0
    ip_digits : ., mut = 0
    fp_digits : ., mut = 0
    too_wide : ., mut = 0
    loop:
        if i >= sl:
            break
        c := load8(s, i)
        if c == 46:
            sd = 1
            i = i + 1
            continue
        if c < 48 || c > 57:
            break
        if sd != 0:
            fp_digits = fp_digits + 1
            if fp_digits <= 18:
                fp = fp * 10 + (c - 48)
                den = den * 10
        else:
            ip_digits = ip_digits + 1
            if ip_digits <= 19:
                digit_ip := c - 48
                if ip > 922337203685477580 || (ip == 922337203685477580 && digit_ip > 7 + neg):
                    too_wide = 1
                else:
                    ip = ip * 10 + digit_ip
            else:
                too_wide = 1
        i = i + 1
    if too_wide != 0:
        add_error("decimal literal integer part is too wide")
        return 0
    if ip == 0 && fp == 0:
        if neg != 0:
            return (-9223372036854775807 - 1)
        return 0
    // 小数 64 位（长除：r=fp，每轮 r×2 vs den）
    frac64 : int = 0
    r : ., mut = fp
    bits : ., mut = 0
    loop:
        if bits >= 64:
            break
        if r >= 4611686018427387904:
            r = r / 2
            den = den / 2
        r = r * 2
        frac64 = frac64 * 2
        if r >= den:
            r = r - den
            frac64 = frac64 + 1
        bits = bits + 1
    // 整数部分位宽
    bi : ., mut = 0
    t2 : ., mut = ip
    loop:
        if t2 == 0:
            break
        t2 = t2 / 2
        bi = bi + 1
    mant : int = 0
    exp : int = 0
    if bi > 0:
        sh := 53 - bi
        if sh >= 0:
            mant = (ip * pow2i(sh)) + (frac64 / pow2i(64 - sh))
        else:
            // Avoid pow2i of a negative value for integer parts wider than
            // the binary64 significand.
            mant = ip / pow2i(0 - sh)
        exp = 1023 + (bi - 1)
    else:
        // 纯小数：frac64 的最高位
        bf : ., mut = 0
        t2 = frac64
        loop:
            if t2 == 0:
                break
            t2 = t2 / 2
            bf = bf + 1
        if bf == 0:
            if neg != 0:
                return (-9223372036854775807 - 1)
            return 0
        sh := 53 - bf
        if sh >= 0:
            mant = frac64 * pow2i(sh)
        else:
            mant = frac64 / pow2i(-sh)
        exp = 1023 + (bf - 65)
    // Assemble; mant is truncated to 52 bits without rounding.
    bits64 : int = 0
    if exp > 0 && exp < 2047:
        bits64 = (mant % 4503599627370496) + exp * 4503599627370496
    if neg != 0:
        bits64 = bits64 + (-9223372036854775807 - 1)
    return bits64
