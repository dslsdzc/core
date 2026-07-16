// === trace.cr ===
// 运行时诊断工具 — 参考 Rust 的 RUST_BACKTRACE / dbg! 设计
//
// 通用部分（任何代码可用）:
//   trace_assert(cond, msg)    — 条件不满足时输出警告
//   trace_dbg(name, val)       — 打印变量名和值
//
// 编译器专用部分（需要编译器全局变量）在 src/compiler/trace_ext.cr

fn trace_assert(cond: int, msg: string) {
    if cond != 0 { return; }
    println(msg);
}

fn trace_dbg(name: string, val: int) -> int {
    print_i(val);
    return val;
}

fn trace_dbg_str(name: string, val: string) -> string {
    print(val);
    return val;
}
