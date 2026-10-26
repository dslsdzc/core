// === bits.cr ===
// Fixed-width 32-bit operations implemented with Core arithmetic only.
// No new IR opcodes: bitwise work is expressed with %, /, * and conditionals,
// Byte-order helpers live in rawbuf.cr; this file has no target builtins.

BITS32_MASK : int = 4294967295
BITS32_SIZE : int = 4294967296
BITS32_BITS : int = 32

fn bits32Norm(x: int) -> int:
    r := x % BITS32_SIZE
    if r < 0:
        r = r + BITS32_SIZE
    return r

fn bits32And(a: int, b: int) -> int:
    x := bits32Norm(a)
    y := bits32Norm(b)
    r : ., mut = 0
    p : ., mut = 1
    i : ., mut = 0
    loop:
        if i >= BITS32_BITS:
            break
        if x % 2 == 1 && y % 2 == 1:
            r = r + p
        x = x / 2
        y = y / 2
        p = p * 2
        i = i + 1
    return r

fn bits32Or(a: int, b: int) -> int:
    x := bits32Norm(a)
    y := bits32Norm(b)
    r : ., mut = 0
    p : ., mut = 1
    i : ., mut = 0
    loop:
        if i >= BITS32_BITS:
            break
        if x % 2 == 1 || y % 2 == 1:
            r = r + p
        x = x / 2
        y = y / 2
        p = p * 2
        i = i + 1
    return r

fn bits32Xor(a: int, b: int) -> int:
    x := bits32Norm(a)
    y := bits32Norm(b)
    r : ., mut = 0
    p : ., mut = 1
    i : ., mut = 0
    loop:
        if i >= BITS32_BITS:
            break
        if x % 2 != y % 2:
            r = r + p
        x = x / 2
        y = y / 2
        p = p * 2
        i = i + 1
    return r

fn bits32Not(a: int) -> int:
    return BITS32_MASK - bits32Norm(a)

fn bits32Shl(a: int, n: int) -> int:
    k := n % BITS32_BITS
    r := bits32Norm(a)
    i : ., mut = 0
    loop:
        if i >= k:
            break
        r = bits32Norm(r * 2)
        i = i + 1
    return r

fn bits32Shr(a: int, n: int) -> int:
    k := n % BITS32_BITS
    r := bits32Norm(a)
    i : ., mut = 0
    loop:
        if i >= k:
            break
        r = r / 2
        i = i + 1
    return r

fn bits32Rotl(a: int, n: int) -> int:
    k := n % BITS32_BITS
    if k == 0:
        return bits32Norm(a)
    return bits32Or(bits32Shl(a, k), bits32Shr(a, BITS32_BITS - k))

fn bits32Rotr(a: int, n: int) -> int:
    k := n % BITS32_BITS
    if k == 0:
        return bits32Norm(a)
    return bits32Or(bits32Shr(a, k), bits32Shl(a, BITS32_BITS - k))

fn bits32Add(a: int, b: int) -> int:
    return bits32Norm(bits32Norm(a) + bits32Norm(b))

fn bits32Sub(a: int, b: int) -> int:
    return bits32Norm(bits32Norm(a) - bits32Norm(b))

fn bits32Mul(a: int, b: int) -> int:
    return bits32Norm(bits32Norm(a) * bits32Norm(b))

struct Bits32:
    value: int

fn bits32(value: int) -> Bits32:
    return Bits32 { value = bits32Norm(value) }

fn bits32Zero() -> Bits32:
    return Bits32 { value = 0 }

fn bits32One() -> Bits32:
    return Bits32 { value = 1 }

fn bits32Max() -> Bits32:
    return Bits32 { value = BITS32_MASK }

impl Bits32:
    fn toInt(&self) -> int:
        return self.value

    fn and(&self, other: Bits32) -> Bits32:
        return Bits32 { value = bits32And(self.value, other.value) }

    fn or(&self, other: Bits32) -> Bits32:
        return Bits32 { value = bits32Or(self.value, other.value) }

    fn xor(&self, other: Bits32) -> Bits32:
        return Bits32 { value = bits32Xor(self.value, other.value) }

    fn not(&self) -> Bits32:
        return Bits32 { value = bits32Not(self.value) }

    fn shl(&self, n: int) -> Bits32:
        return Bits32 { value = bits32Shl(self.value, n) }

    fn shr(&self, n: int) -> Bits32:
        return Bits32 { value = bits32Shr(self.value, n) }

    fn rotl(&self, n: int) -> Bits32:
        return Bits32 { value = bits32Rotl(self.value, n) }

    fn rotr(&self, n: int) -> Bits32:
        return Bits32 { value = bits32Rotr(self.value, n) }

    fn add(&self, other: Bits32) -> Bits32:
        return Bits32 { value = bits32Add(self.value, other.value) }

    fn sub(&self, other: Bits32) -> Bits32:
        return Bits32 { value = bits32Sub(self.value, other.value) }

    fn mul(&self, other: Bits32) -> Bits32:
        return Bits32 { value = bits32Mul(self.value, other.value) }

    fn eq(&self, other: Bits32) -> bool:
        return self.value == other.value

    fn lt(&self, other: Bits32) -> bool:
        return self.value < other.value

    fn isZero(&self) -> bool:
        return self.value == 0
