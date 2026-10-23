import io

extern fn dex_ffi_bits_check(d: dex) -> int

fn main() -> int:
    return dex_ffi_bits_check(3.14)
