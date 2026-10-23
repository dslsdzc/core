// === ext_safety.cr ===
// 运行时安全检查插件 — 通过 ext_mgr 注册到编译器钩子
//
// 在 ext_mgr_init() 中调用 ext_safety_init() 注册自己。
// 钩子触发时 ext_mgr 调用本插件的 handler 函数。

// 插件初始化：注册到钩子
fn ext_safety_init():
    if ext_has(0) == 0:
        return
    // 等 ext_mgr 初始化
    ext_reg(EXT_HOOK_ARRAY_ACCESS, 1)  // 监听数组访问
    ext_reg(EXT_HOOK_BINARY_OP, 1)     // 监听二元运算

// === 数组越界检查 handler ===
// 在 IR_LOAD_INDEX / IR_STORE_INDEX 之前被 ext_mgr 调用。
// idx_lit/arr_len_lit >=0 表示编译期已知的值。
// 返回: 0=继续（编译期越界时发射必陷检查——不可静默跳过，见 F1/F2）
fn ext_safety_on_array_access(arr_var: int, idx_var: int, idx_lit: int, arr_len_lit: int) -> int:
    // 字面量索引（idx_var < 0 表示传了字面量）+ 字面量长度 → 编译期检查。
    // 注意：idx_lit 可为负（arr[-1] 解析为负字面量时）——同样必须拦截。
    if arr_len_lit >= 0 && idx_var < 0:
        if idx_lit < 0 || idx_lit >= arr_len_lit:
            // 编译期越界：发射恒陷检查（IR_CONST + BOUNDS_CHECK）——
            // 修复前 return 1 静默跳过访问 → 目标变量未初始化 → 静默错值。
            tmp := new_ir_var("_oob_idx", TI_INT)
            emit(IR_CONST, tmp, idx_lit, 0, 0, TI_INT)
            emit(IR_BOUNDS_CHECK, -1, tmp, arr_len_lit, 0, 0)
        return 0
    // 变量索引 + 字面量长度 → 插入 IR_BOUNDS_CHECK
    if arr_len_lit >= 0 && idx_var >= 0:
        emit(IR_BOUNDS_CHECK, -1, idx_var, arr_len_lit, 0, 0)
        return 0
    return 0

// === 算术溢出检查 handler（预留） ===
fn ext_safety_on_binary_op(op: int, lv: int, rv: int, result_var: int) -> int:
    return 0
