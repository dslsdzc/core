// Linux output file modes.
//
// These are Linux OS facts, not target architecture or ELF header facts:
// 0755 executable ELF, 0644 non-executable data/shared object.
fn linux_mode_exec() -> int:
    return 493
fn linux_mode_rw() -> int:
    return 420
