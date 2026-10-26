// === bits.cr ===
// Fixed-width raw-word operations. Core ints are mathematical values; the
// @bit* builtins cross the tagged/raw boundary explicitly, so this module can
// present unsigned 32/64-bit arithmetic without leaking representation details.
//
// The @raw* builtins are the untagged layer used by the interpreter/runtime.
// User code should use Bits32/Bits64.

BITS32_MASK : int = 4294967295
BITS32_SIZE : int = 4294967296
BITS32_BITS : int = 32

fn bits32Norm(x: int) -> int:
    r := x % BITS32_SIZE
    if r < 0:
        r = r + BITS32_SIZE
    return r

fn bits32(value: int) -> Bits32:
    return Bits32 { value = bits32Norm(value) }

fn bits32Zero() -> Bits32:
    return Bits32 { value = 0 }

fn bits32One() -> Bits32:
    return Bits32 { value = 1 }

fn bits32Max() -> Bits32:
    return Bits32 { value = BITS32_MASK }

struct Bits32:
    value: int

impl Bits32:
    fn toInt(&self) -> int:
        return self.value

    fn and(&self, other: Bits32) -> Bits32:
        return Bits32 { value = @bitAnd(self.value, other.value) }

    fn or(&self, other: Bits32) -> Bits32:
        return Bits32 { value = @bitOr(self.value, other.value) }

    fn xor(&self, other: Bits32) -> Bits32:
        return Bits32 { value = @bitXor(self.value, other.value) }

    fn not(&self) -> Bits32:
        return Bits32 { value = @bitXor(self.value, BITS32_MASK) }

    fn shl(&self, n: int) -> Bits32:
        return Bits32 { value = bits32Norm(@bitShl(self.value, n % BITS32_BITS)) }

    fn shr(&self, n: int) -> Bits32:
        return Bits32 { value = @bitShr(self.value, n % BITS32_BITS) }

    fn rotl(&self, n: int) -> Bits32:
        k := n % BITS32_BITS
        if k == 0:
            return Bits32 { value = self.value }
        left := bits32Norm(@bitShl(self.value, k))
        right := @bitShr(self.value, BITS32_BITS - k)
        return Bits32 { value = @bitOr(left, right) }

    fn rotr(&self, n: int) -> Bits32:
        k := n % BITS32_BITS
        if k == 0:
            return Bits32 { value = self.value }
        right := @bitShr(self.value, k)
        left := bits32Norm(@bitShl(self.value, BITS32_BITS - k))
        return Bits32 { value = @bitOr(left, right) }

    fn add(&self, other: Bits32) -> Bits32:
        return Bits32 { value = bits32Norm(self.value + other.value) }

    fn sub(&self, other: Bits32) -> Bits32:
        return Bits32 { value = bits32Norm(self.value - other.value) }

    fn mul(&self, other: Bits32) -> Bits32:
        return Bits32 { value = bits32Norm(self.value * other.value) }

    fn eq(&self, other: Bits32) -> bool:
        return self.value == other.value

    fn lt(&self, other: Bits32) -> bool:
        return self.value < other.value

    fn isZero(&self) -> bool:
        return self.value == 0

fn bits32LoadBE(buf: string, off: int) -> Bits32:
    b0 := load8(buf, off)
    b1 := load8(buf, off + 1)
    b2 := load8(buf, off + 2)
    b3 := load8(buf, off + 3)
    return Bits32 { value = b0 * 16777216 + b1 * 65536 + b2 * 256 + b3 }

fn bits32LoadLE(buf: string, off: int) -> Bits32:
    b0 := load8(buf, off)
    b1 := load8(buf, off + 1)
    b2 := load8(buf, off + 2)
    b3 := load8(buf, off + 3)
    return Bits32 { value = b3 * 16777216 + b2 * 65536 + b1 * 256 + b0 }

fn bits32StoreBE(buf: string, off: int, v: Bits32):
    x := v.value
    store8(buf, off, x / 16777216 % 256)
    store8(buf, off + 1, x / 65536 % 256)
    store8(buf, off + 2, x / 256 % 256)
    store8(buf, off + 3, x % 256)

fn bits32StoreLE(buf: string, off: int, v: Bits32):
    x := v.value
    store8(buf, off, x % 256)
    store8(buf, off + 1, x / 256 % 256)
    store8(buf, off + 2, x / 65536 % 256)
    store8(buf, off + 3, x / 16777216 % 256)
