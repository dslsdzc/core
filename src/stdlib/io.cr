// Core standard library: I/O output.
// All I/O functions take pre-formatted strings (use fmt for conversions).

fn print(s: string) {
    __builtin_print(s);
}

fn println(s: string) {
    __builtin_println(s);
}

fn print_int(n: int) {
    __builtin_print(__builtin_int_to_str(n));
}

fn println_int(n: int) {
    __builtin_println(__builtin_int_to_str(n));
}
