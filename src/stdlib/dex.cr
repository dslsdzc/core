// dex.cr: fixed-point helpers for dex arithmetic.
//
// Representation: dex is a scaled int64 with scale S = 10^6. A value x is stored
// as x*S, so 3.14 is 3140000. Arithmetic is exact in this representation:
// 0.1 + 0.2 == 0.3 and 3.14 + 2.86 == 6.0.
//
// Operations compile to scaled integer sequences:
// - add and subtract use the scaled integers directly;
// - multiply uses (a*S * b*S) / S;
// - divide uses (a*S * S) / (b*S), truncated toward zero;
// - modulo uses a - trunc(a/b)*b;
// - comparisons use the scaled integers directly.
//
// Overflow wraps modulo 2^64 with no trap, like int overflow. Add and subtract
// are safe while the result is within 9.2e12. Multiply is safe while
// |a|*|b| <= 9.2e6. Divide is safe while |a| <= 9.2e6 and b != 0.
// Division and modulo truncate toward zero. Literals round half up at the seventh
// decimal digit. Printing removes trailing zeros.
//
// Variables marked apx use the binary64 fast path and do not use these exact
// helpers. Across a function boundary dex is always the exact scaled integer
// form; an apx result is rounded to six decimal places.
//
// apx printing through dex_str rounds to six decimal places, so 0.1 prints as
// "0.1". This also hides the roughly 2 ulp truncation error from literal
// conversion. Full-precision Ryu-style printing is not implemented.
//
// The interpreter has no binary64 semantics. I2F and F2I report errors for apx
// code, so apx programs must run natively.
//
// @raw_int(v) exposes the scaled integer for printing with ordinary integer
// operations.

// Convert a scaled integer to decimal text and remove trailing zeros.
fn dex_str(v: dex) -> string, pub:
    n : ., mut = @raw_int(v)    // scaled integer value
    neg : int, mut = 0
    if n < 0:
        neg = 1
        n = 0 - n
    ip := n / 1000000           // integer part
    fp := n % 1000000           // fractional part, scaled
    s : ., mut = ""
    if neg != 0:
        s = "-"
    s = s + int_str(ip)
    if fp != 0:
        s = s + "."
        fs : ., mut = ""
        d : ., mut = fp
        k : ., mut = 100000
        loop:
            if k <= 0:
                break
            dg := d / k
            d = d - dg * k
            fs = fs + int_str(dg)
            k = k / 10
        // Remove trailing zeros.
        li : ., mut = str_len(fs) - 1
        loop:
            if li < 0:
                break
            if load8(fs, li) != 48:
                break
            fs = str_sub(fs, 0, li)
            li = li - 1
        s = s + fs
    return s
