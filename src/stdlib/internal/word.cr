// === internal/word.cr ===
// Library-internal fixed-width word arithmetic.
//
// Width is an *algorithm parameter*, not a type: every helper takes `bits` and
// wraps modulo 2^bits. No new IR opcodes are involved; the operations are
// expressed with /, %, * and conditionals so they run on the existing HIT core.

fn wordTwoPow(bits: int) -> int:
    r : ., mut = 1
    i : ., mut = 0
    loop:
        if i >= bits:
            break
        r = r * 2
        i = i + 1
    return r

fn wordNorm(value: int, bits: int) -> int:
    if bits <= 0:
        return 0
    modulus := wordTwoPow(bits)
    r := value % modulus
    if r < 0:
        r = r + modulus
    return r

fn wordMask(bits: int) -> int:
    if bits <= 0:
        return 0
    return wordTwoPow(bits) - 1

fn wordBit(value: int, bit: int, bits: int) -> int:
    if bit < 0 || bit >= bits:
        return 0
    return wordNorm(value / wordTwoPow(bit), bits) % 2

fn wordNot(a: int, bits: int) -> int:
    return wordMask(bits) - wordNorm(a, bits)

fn wordAnd(a: int, b: int, bits: int) -> int:
    x := wordNorm(a, bits)
    y := wordNorm(b, bits)
    r : ., mut = 0
    p : ., mut = 1
    i : ., mut = 0
    loop:
        if i >= bits:
            break
        if x % 2 == 1 && y % 2 == 1:
            r = r + p
        x = x / 2
        y = y / 2
        p = p * 2
        i = i + 1
    return r

fn wordOr(a: int, b: int, bits: int) -> int:
    x := wordNorm(a, bits)
    y := wordNorm(b, bits)
    r : ., mut = 0
    p : ., mut = 1
    i : ., mut = 0
    loop:
        if i >= bits:
            break
        if x % 2 == 1 || y % 2 == 1:
            r = r + p
        x = x / 2
        y = y / 2
        p = p * 2
        i = i + 1
    return r

fn wordXor(a: int, b: int, bits: int) -> int:
    x := wordNorm(a, bits)
    y := wordNorm(b, bits)
    r : ., mut = 0
    p : ., mut = 1
    i : ., mut = 0
    loop:
        if i >= bits:
            break
        if x % 2 != y % 2:
            r = r + p
        x = x / 2
        y = y / 2
        p = p * 2
        i = i + 1
    return r

fn wordShl(a: int, n: int, bits: int) -> int:
    if bits <= 0:
        return 0
    k := n % bits
    r := wordNorm(a, bits)
    i : ., mut = 0
    loop:
        if i >= k:
            break
        r = wordNorm(r * 2, bits)
        i = i + 1
    return r

fn wordShr(a: int, n: int, bits: int) -> int:
    if bits <= 0:
        return 0
    k := n % bits
    r := wordNorm(a, bits)
    i : ., mut = 0
    loop:
        if i >= k:
            break
        r = r / 2
        i = i + 1
    return r

fn wordRotl(a: int, n: int, bits: int) -> int:
    if bits <= 0:
        return 0
    k := n % bits
    if k == 0:
        return wordNorm(a, bits)
    return wordOr(wordShl(a, k, bits), wordShr(a, bits - k, bits), bits)

fn wordRotr(a: int, n: int, bits: int) -> int:
    if bits <= 0:
        return 0
    k := n % bits
    if k == 0:
        return wordNorm(a, bits)
    return wordOr(wordShr(a, k, bits), wordShl(a, bits - k, bits), bits)

fn wordAdd(a: int, b: int, bits: int) -> int:
    return wordNorm(wordNorm(a, bits) + wordNorm(b, bits), bits)

fn wordSub(a: int, b: int, bits: int) -> int:
    return wordNorm(wordNorm(a, bits) - wordNorm(b, bits), bits)

fn wordMul(a: int, b: int, bits: int) -> int:
    return wordNorm(wordNorm(a, bits) * wordNorm(b, bits), bits)
