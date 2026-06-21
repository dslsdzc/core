// ═══════════════════════════════════════════════
// scheduler.cr — 运行时调度器
// 64 位无上限，通过 *256 + b 逐字节组装。
// ═══════════════════════════════════════════════

fn sched_create(n: int) -> string {
    return alloc(n * 8);
}

fn sched_set(entries: string, idx: int, val: int) {
    p := idx * 8;
    v : ., mut = val;
    i : ., mut = 0;
    loop {
        if i >= 8 { break; }
        store8(entries, p + i, v % 256);
        v = v / 256;
        i = i + 1;
    }
}

fn sched_get(entries: string, idx: int) -> int {
    p := idx * 8;
    r : ., mut = 0;
    i : ., mut = 7;
    loop {
        if i < 0 { break; }
        b := load8(entries, p + i);
        if b < 0 { b = b + 256; }
        r = r * 256 + b;
        i = i - 1;
    }
    return r;
}
