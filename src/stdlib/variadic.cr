// ═══════════════════════════════════════════
// variadic.cr — 运行时变参工具
//
// 被 .so 插件调用，在运行时处理变参展开。
// 编译器不参与，纯粹是标准库。
//
// 用法（在 .so 中）：
//   count := va_count(args_pack);
//   for i := 0; i < count; i++ {
//       arg := va_arg(args_pack, i);
//       dispatch_call(fn_ni, arg);
//   }
// ═══════════════════════════════════════════

// 变参包计数：返回参数数量
fn va_count(pack: string) -> int {
    if str_len(pack) < 8 { return 0; }
    return r64(pack, 0);
}

// 变参包取值：返回第 n 个参数的 IR 变量
fn va_arg(pack: string, n: int) -> int {
    if str_len(pack) < (n + 1) * 8 + 8 { return -1; }
    return r64(pack, (n + 1) * 8);
}

// 检测函数名是否含 "ln"（println → print + "\n"）
fn va_fn_has_ln(fn_name: string) -> bool {
    fnl := str_len(fn_name);
    if fnl >= 4 {
        if load8(fn_name, fnl-2) == 108 && load8(fn_name, fnl-1) == 110 { return true; }
    }
    return false;
}
