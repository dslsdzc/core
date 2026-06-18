// Core standard library: I/O, formatting, and string utilities.
// All functions here are safe for user code (wrap __builtin_* internally).

// --- String conversion ---
fn int_to_str(n: int) -> string {
    return __builtin_int_to_str(n);
}

// --- String concatenation ---
fn concat(a: string, b: string) -> string {
    return __builtin_str_push(a, b);
}

// --- Print / Println ---
fn print(s: string) {
    __builtin_print(s);
}

fn print(s: string, s2: string) {
    __builtin_print(s); __builtin_print(s2);
}

fn println(s: string) {
    __builtin_println(s);
}

fn println(s: string, s2: string) {
    __builtin_print(s); __builtin_println(s2);
}

fn print_int(n: int) {
    __builtin_print(__builtin_int_to_str(n));
}

fn println_int(n: int) {
    __builtin_println(__builtin_int_to_str(n));
}
