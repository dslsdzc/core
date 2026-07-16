// === pass.cr ===
// 编译器扩展钩子调度器 — 连接编译器核心与扩展模块
//
// 编译器核心在关键节点调用 pass_*() 函数。
// 每个函数检查已注册的扩展，将控制权转给相应的扩展处理。
//
// 钩子点：
//   pass_before_array_access() — 数组访问前的安全检查
//   pass_after_binary()         — 算术操作后的溢出检查
//   dispatch_call()             — 内置函数展开（.so/stdlib 插件）

// 数组访问前调用
// arr_var: 数组变量，idx_var: 索引变量，idx_lit: 字面索引（-1=变量），arr_len_lit: 编译期已知长度（-1=未知）
fn pass_before_array_access(arr_var: int, idx_var: int, idx_lit: int, arr_len_lit: int) -> int {
    return ext_safety_check_index(arr_var, idx_var, idx_lit, arr_len_lit);
}

// 算术操作后调用（用于溢出检查）
fn pass_after_binary(op: int, lv: int, rv: int, result_var: int) -> int {
    return ext_safety_check_overflow(op, lv, rv, result_var);
}

// 内置函数展开 — 由 .so/stdlib 插件注册
// 返回: >=0 = 展开结果变量的索引, -1 = 未找到展开
fn dispatch_call(fn_ni: int, ac: int, arg_vars: string) -> int {
    return -1;  // 暂无内置展开——全部由 stdlib/.so 处理
}
