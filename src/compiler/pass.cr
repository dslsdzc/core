// === pass.cr ===
// 编译器扩展钩子调度器 — 编译核心 ↔ 插件之间的桥梁
//
// 编译器核心在关键节点调 pass_*()。
// 每个 pass_*() 通过 ext_mgr 的 ext_dispatch_*() 分发到已注册插件。
//
// 不需要修改此文件来添加新插件——只需在 ext_plugins.cr 中注册新 handler。
// 不需要修改编译器核心——只需在核心中加 pass_*() 调用点。

// 数组访问前 — 由 ir_gen 在每次 IR_LOAD/STORE_INDEX 前调用
// 返回: 0=正常, 1=跳过此次访问
fn pass_before_array_access(arr_var: int, idx_var: int, idx_lit: int, arr_len_lit: int) -> int {
    return ext_dispatch_array_access(arr_var, idx_var, idx_lit, arr_len_lit);
}

// 二元运算后 — 用于溢出检查
fn pass_after_binary(op: int, lv: int, rv: int, result_var: int) -> int {
    return ext_dispatch_binary_op(op, lv, rv, result_var);
}

// 内置函数展开 — 由 .so/stdlib 插件注册
fn dispatch_call(fn_ni: int, ac: int, arg_vars: string) -> int {
    return -1;
}
