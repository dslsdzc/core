// ═══════════════════════════════════════════════
// sched.cr — Core 运行时调度器
//
// 提供间接调用表（dispatch table）的创建与管理。
// 表本身在 BSS/堆上分配，条目为 8 字节函数地址。
//
// 使用流程：
//   1. sched_create(n) → 创建 n 个空条目的表
//   2. sched_set(t, i, fn) → 将 fn 写入第 i 个条目
//   3. sched_call(t, i, ...) → 通过 i 间接调用
//
// sched_call 由汇编实现（sched.s），Core 代码不可见其内部。
// ═══════════════════════════════════════════════

// 调度表结构
// entries: 连续 8 字节指针数组
// count:   条目数量
struct DispatchTable {
    entries: string,   // 函数指针数组
    count: int,         // 条目数
}

// 创建 n 个条目的调度表，返回初始化后的表
fn sched_create(n: int) -> DispatchTable {
    buf := alloc(n * 8);
    return DispatchTable { entries = buf, count = n };
}

// 将函数地址写入调度表第 idx 个条目
fn sched_set(table: DispatchTable, idx: int, fn_addr: int) {
    if idx < 0 || idx >= table.count {
        print("sched_set: index out of bounds\n");
        return;
    }
    store_str_ptr(table.entries, idx * 8, fn_addr);
}

// 读取调度表第 idx 个条目的函数地址
fn sched_get(table: DispatchTable, idx: int) -> int {
    if idx < 0 || idx >= table.count {
        print("sched_get: index out of bounds\n");
        return 0;
    }
    return r64(table.entries, idx * 8);
}

// 遍历表，打印所有条目
fn sched_dump(table: DispatchTable) {
    i : ., mut = 0;
    loop {
        if i >= table.count { break; }
        addr := r64(table.entries, i * 8);
        print("  [");
        print_i(i);
        print("] = 0x");
        // 地址暂不做 hex 输出，只打整数
        print_i(addr);
        println("");
        i = i + 1;
    }
}
