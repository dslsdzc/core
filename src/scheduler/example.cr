// ═══════════════════════════════════════════════
// scheduler 使用示例
//
// 演示：创建一个调度表，注册两个函数，通过表间接调用。
// ═══════════════════════════════════════════════

import io

fn hello(name: string) {
    print("hello ");
    println(name);
}

fn add(a: int, b: int) -> int {
    return a + b;
}

fn main() -> int {
    // 创建调度表（2 个条目）
    table := sched_create(2);

    // 注册函数（把函数指针写入表）
    // 注意：Core 没有函数指针类型，需要用 load_str_ptr + store_str_ptr
    // 在汇编层面处理。这里先简化——直接用 sched_set 存整数地址。
    // 实际的函数地址需由链接器提供。
    //
    // 示例（伪代码）：
    //   sched_set(table, 0, &hello);
    //   sched_set(table, 1, &add);
    //
    // 然后通过表间接调用：
    //   sched_call_1(table.entries, 0, "world");
    //   result := sched_call_2(table.entries, 1, 3, 5);

    println("scheduler example");

    // 目前只演示表操作，不实际调用
    //（函数指针在 Core 层面不可达，待编译器支持）

    return 0;
}
