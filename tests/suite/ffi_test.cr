import io

// Test extern function declarations at top level
extern fn getchar() -> int
extern fn putchar(c: int) -> int

// M2 终审：extern dex 参数声明面——dex 跨 C 边界 = binary64 bits（module.cr ABI 契约）。
// 仅声明（不调用）：调用点转换由 tests/selfhost/test_dex_arith.py 的
// test_extern_dex_arg_cir 以 IR 层断言覆盖（运行时 FFI 被 corearch --link
// 静态路径既有崩溃阻塞，见 numeric-task-7-report Fix F）。
extern fn dex_floor(d: dex) -> dex

fn main() -> int:
    // Verify that extern fn declarations compiled successfully
    // by testing that we can call main correctly
    println("ALL PASS")
    return 0
