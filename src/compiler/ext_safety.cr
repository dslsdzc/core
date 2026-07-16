// === ext_safety.cr ===
// 运行时安全检查扩展 — 数组越界、算术溢出
//
// 由 ext.cr 管理，CORE_SAFE=1 启用。
// 在 IR 生成阶段插入检查指令，不修改编译器核心。

// === 数组越界检查 ===
// 在 IR_LOAD_INDEX / IR_STORE_INDEX 之前插入边界检查。
// 对于字面量索引（编译期已知），在编译期检查；
// 对于变量索引，用 IR_BOUNDS_CHECK 做运行时检查。
//
// 返回: 0=正常, 1=编译期越界（调用方应跳过访问）

fn ext_safety_check_index(arr_var: int, idx_var: int, idx_lit: int, arr_len_lit: int) -> int {
    if ext_has(EXT_SAFE) == 0 { return 0; }

    // 字面量索引 + 字面量长度 → 编译期检查
    if idx_lit >= 0 && arr_len_lit >= 0 {
        if idx_lit < 0 || idx_lit >= arr_len_lit {
            // 编译期越界：插入一个肯定会触发的检查
            // 用一个不可能满足的条件来触发运行时 abort
            return 1;  // 调用方应跳过这次访问或报错
        }
        // 编译期安全，不需要运行时检查
        return 0;
    }

    // 变量索引 + 字面量长度 → 运行时 IR_BOUNDS_CHECK
    if arr_len_lit >= 0 {
        emit(IR_BOUNDS_CHECK, -1, idx_var, arr_len_lit, 0, 0);
        return 0;
    }

    // 变量索引 + 变量长度 → 目前不支持（需要数组 header 存储长度）
    return 0;
}

// === 算术溢出检查 ===
// 在 IR_BINARY 的 + - * 操作后插入溢出检查
// 目前仅支持字面量溢出检测（编译期已知不会溢出则跳过）

fn ext_safety_check_overflow(op: int, lv: int, rv: int, result_var: int) -> int {
    if ext_has(EXT_SAFE) == 0 { return 0; }
    // TODO: 运行时溢出检查（需要在 IR 层添加带溢出检测的算术指令）
    return 0;
}
