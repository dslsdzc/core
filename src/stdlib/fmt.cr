// fmt — String formatting and conversion utilities.
// All functions are pure (no side effects).

fn to_string(n: int) -> string {
    return __builtin_int_to_str(n);
}

fn to_string(s: string) -> string {
    return s;
}

fn concat(a: string, b: string) -> string {
    return __builtin_str_push(a, b);
}
