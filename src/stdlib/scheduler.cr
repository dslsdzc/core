// ═══════════════════════════════════════════════
// scheduler.cr — 运行时调度器
//
// 创建与管理间接调用表（dispatch table）。
// 当前只支持 32 位地址（val < 2^32）。
// ═══════════════════════════════════════════════

fn sched_create(n: int) -> string {
    return alloc(n * 8);
}

fn sched_set32(entries: string, idx: int, val: int) {
    p := idx * 8;
    lo : ., mut = val;
    if lo < 0 { lo = lo + 4294967296; }
    store8(entries, p,   lo % 256);
    store8(entries, p+1, (lo / 256) % 256);
    store8(entries, p+2, (lo / 65536) % 256);
    store8(entries, p+3, (lo / 16777216) % 256);
}

fn sched_get32(entries: string, idx: int) -> int {
    p := idx * 8;
    r : ., mut = 0;
    r = r + load8(entries, p);
    r = r + load8(entries, p+1) * 256;
    r = r + load8(entries, p+2) * 65536;
    r = r + load8(entries, p+3) * 16777216;
    return r;
}
