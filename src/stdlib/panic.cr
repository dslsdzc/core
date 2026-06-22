// === panic.cr ===
// Rust-style panic handler for debugging.
// NOT recommended for production use — dev-only tool.
//
// Ported from Rust's library/std/src/panicking.rs
// Format: "panicked at FILE:LINE:COL:\nMESSAGE\n"
//
// Usage:
//   import panic
//   panic::panic("something went wrong");
//   panic::panic_at("index out of bounds", "src/main.cr", 42, 5);

// Write raw bytes to stderr (fd 2)
fn _panic_write(s: string) {
    sl := str_len(s);
    if sl > 0 { r1 := syscall3(1, 2, s, sl); }
}

fn _panic_writeln(s: string) {
    _panic_write(s);
    r1 := syscall3(1, 2, "\n", 1);
}

// Core panic entry point — prints message + location to stderr, then aborts.
// Mirrors Rust's default_hook output format:
//   panicked at FILE:LINE:COL:\nMESSAGE
fn panic_at(msg: string, file: string, line: int, col: int) {
    // Build: "panicked at FILE:LINE:COL:\nMESSAGE\n"
    _panic_write("panicked at ");
    _panic_write(file);
    _panic_write(":");
    _panic_write(int_str(line));
    _panic_write(":");
    _panic_write(int_str(col));
    _panic_writeln(":");
    _panic_writeln(msg);

    // Abort via exit(1)
    r1 := syscall3(60, 1, 0, 0);
}

// Convenience — panic without location info
// Prints: "panicked at:\nMESSAGE\n"
fn panic(msg: string) {
    _panic_writeln("panicked at:");
    _panic_writeln(msg);
    r1 := syscall3(60, 1, 0, 0);
}
