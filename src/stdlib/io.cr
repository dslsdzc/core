fn print(s: string) {
    __builtin_print(s);
}
fn print(s: string, s2: string) {
    __builtin_print(s); __builtin_print(s2);
}
fn print(s: string, s2: string, s3: string) {
    __builtin_print(s); __builtin_print(s2); __builtin_print(s3);
}
fn print(s: string, s2: string, s3: string, s4: string) {
    __builtin_print(s); __builtin_print(s2); __builtin_print(s3); __builtin_print(s4);
}

fn print(n: int) {
    __builtin_print(__builtin_int_to_str(n));
}
fn print(n: int, n2: int) {
    __builtin_print(__builtin_int_to_str(n)); __builtin_print(__builtin_int_to_str(n2));
}
fn print(n: int, n2: int, n3: int) {
    __builtin_print(__builtin_int_to_str(n)); __builtin_print(__builtin_int_to_str(n2)); __builtin_print(__builtin_int_to_str(n3));
}

fn print(s: string, n: int) {
    __builtin_print(s); __builtin_print(__builtin_int_to_str(n));
}
fn print(s: string, n: int, s2: string) {
    __builtin_print(s); __builtin_print(__builtin_int_to_str(n)); __builtin_print(s2);
}
fn print(s: string, n: int, s2: string, n2: int) {
    __builtin_print(s); __builtin_print(__builtin_int_to_str(n)); __builtin_print(s2); __builtin_print(__builtin_int_to_str(n2));
}
fn print(n: int, s: string) {
    __builtin_print(__builtin_int_to_str(n)); __builtin_print(s);
}
fn print(n: int, s: string, n2: int) {
    __builtin_print(__builtin_int_to_str(n)); __builtin_print(s); __builtin_print(__builtin_int_to_str(n2));
}

fn println(s: string) {
    __builtin_println(s);
}
fn println(s: string, s2: string) {
    __builtin_print(s); __builtin_println(s2);
}
fn println(n: int) {
    __builtin_println(__builtin_int_to_str(n));
}
fn println(s: string, n: int) {
    __builtin_print(s); __builtin_println(__builtin_int_to_str(n));
}

fn print_int(n: int) {
    __builtin_print(__builtin_int_to_str(n));
}

fn println_int(n: int) {
    __builtin_println(__builtin_int_to_str(n));
}
