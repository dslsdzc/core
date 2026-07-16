// === ext_safety.cr ===
// 运行时安全检查插件 — 通过 ext_mgr 注册到编译器钩子
//
// 在 ext_mgr_init() 中调用 ext_safety_init() 注册自己。
// 钩子触发时 ext_mgr 调用本插件的 handler 函数。

// 插件初始化：注册到钩子
fn ext_safety_init() {
    if ext_has(0) == 0 { return; }  // 等 ext_mgr 初始化
    ext_reg(EXT_HOOK_ARRAY_ACCESS, 1);  // 监听数组访问
    ext_reg(EXT_HOOK_BINARY_OP, 1);     // 监听二元运算
}

// === 数组越界检查 handler ===
// 在 IR_LOAD_INDEX / IR_STORE_INDEX 之前被 ext_mgr 调用。
// idx_lit/arr_len_lit >=0 表示编译期已知的值。
// 返回: 0=继续, 1=跳过（编译期越界）
fn ext_safety_on_array_access(arr_var: int, idx_var: int, idx_lit: int, arr_len_lit: int) -> int {
    // 字面量索引 + 字面量长度 → 编译期检查
    if idx_lit >= 0 && arr_len_lit >= 0 {
        if idx_lit < 0 || idx_lit >= arr_len_lit {
            return 1;  // 编译期越界，跳过此次访问
        }
        return 0;  // 编译期安全
    }
    // 变量索引 + 字面量长度 → 插入 IR_BOUNDS_CHECK
    if arr_len_lit >= 0 {
        emit(IR_BOUNDS_CHECK, -1, idx_var, arr_len_lit, 0, 0);
        return 0;
    }
    return 0;
}

// === 算术溢出检查 handler（预留） ===
fn ext_safety_on_binary_op(op: int, lv: int, rv: int, result_var: int) -> int {
    return 0;
}
