// === assert.cr ===
// 运行时检查系统 — 参考 Rust 的 assert!/debug_assert!/unreachable!/todo!
//
// 依赖: import panic
// 用法:
//   assert(cond, "msg")            — 条件不满足时 panic
//   assert_eq(a, b, "msg")         — a != b 时 panic
//   assert_ne(a, b, "msg")         — a == b 时 panic
//   debug_assert(cond, "msg")      — 调试模式才检查（未来扩展：编译选项控制）
//   unreachable("msg")             — 不可达代码
//   unreachable_mut(msg) -> int    — 不可达代码（有返回值版本）
//   todo("msg")                    — 未完成功能
//   unimplemented("msg")           — 未实现功能

// --- 断言基元（无条件 panic + 信息）---

// 条件为假时 panic
// 等价于 Rust 的 assert!(cond, "msg")
fn assert(cond: int, msg: string) {
    if cond == 0 {
        panic_at(msg, "", 0, 0);
    }
}

// 条件为真时 panic（用于反向断言）
fn assert_not(cond: int, msg: string) {
    if cond != 0 {
        panic_at(msg, "", 0, 0);
    }
}

// --- 值断言 ---

// a == b 不等时 panic
// 等价于 Rust 的 assert_eq!(a, b)
fn assert_eq(a: int, b: int, msg: string) {
    if a != b {
        panic_at(msg, "", 0, 0);
    }
}

// a != b 相等时 panic
// 等价于 Rust 的 assert_ne!(a, b)
fn assert_ne(a: int, b: int, msg: string) {
    if a == b {
        panic_at(msg, "", 0, 0);
    }
}

// 指针/引用值为空时 panic
fn assert_not_null(ptr: string, msg: string) {
    if str_len(ptr) == 0 {
        panic_at(msg, "", 0, 0);
    }
}

// --- 调试断言（debug_assert）---
// 未来：由编译选项控制是否启用
// 目前等同 assert（始终检查）

fn debug_assert(cond: int, msg: string) {
    if cond == 0 {
        panic_at(msg, "", 0, 0);
    }
}

fn debug_assert_eq(a: int, b: int, msg: string) {
    if a != b {
        panic_at(msg, "", 0, 0);
    }
}

// --- 标记宏（markers）---

// 标记不可达代码
// 等价于 Rust 的 unreachable!()
fn unreachable(msg: string) {
    panic_at("internal error: entered unreachable code", "", 0, 0);
}

// 不可达代码（有返回值—用于函数必须有返回值的场景）
fn unreachable_mut(msg: string) -> int {
    panic_at("internal error: entered unreachable code", "", 0, 0);
    return -1;
}

// 标记未完成的功能
// 等价于 Rust 的 todo!()
fn todo(msg: string) {
    panic_at("not yet implemented: ", "", 0, 0);
}

fn todo_mut(msg: string) -> int {
    panic_at("not yet implemented: ", "", 0, 0);
    return -1;
}

// 标记未实现的功能（与 todo 类似但语义不同）
// 等价于 Rust 的 unimplemented!()
fn unimplemented(msg: string) {
    panic_at("not implemented: ", "", 0, 0);
}

fn unimplemented_mut(msg: string) -> int {
    panic_at("not implemented: ", "", 0, 0);
    return -1;
}

// --- 边界检查 ---
// 数组访问的运行时边界检查

// 检查 index 是否在 [0, len) 范围内
// 超出范围时 panic
fn check_bounds(index: int, len: int, msg: string) {
    if index < 0 || index >= len {
        panic_at(msg, "", 0, 0);
    }
}

// 范围检查（start..end 是否在 [0, len) 内）
fn check_range(start: int, end: int, len: int, msg: string) {
    if start < 0 || start > end || end > len {
        panic_at(msg, "", 0, 0);
    }
}
