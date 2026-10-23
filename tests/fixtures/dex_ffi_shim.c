#include <stdint.h>
#include <string.h>

/* ABI probe: accept the lexer-compatible 3.14 binary64 bit pattern. */
int64_t dex_ffi_bits_check(double value) {
    int64_t bits = 0;
    memcpy(&bits, &value, sizeof(bits));
    return bits == 4614253070214989086LL ||
           bits == 4614253070214989087LL ? 0 : 1;
}

double dex_floor(double value) {
    return value;
}
