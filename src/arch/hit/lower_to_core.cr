// === src/arch/hit/lower_to_core.cr ===
// 合成层（HIT M1 Task 3）：IR 直线子集 → 4 核事件流 + 常量池。
// 设计：docs/superpowers/plans/2026-09-05-hit-minimal-core-m1.md Task 3。
// 管线（表模式下 corearch 内部）：IR →（本文件降低）→ 事件流 →（表投影）→ 字节。
//
// 事件流记录（g_hit_ev_stream，每条 20B = 5 × i32）：
//   [ev_id i32, dst i32, src1 i32, src2 i32, flags i32]
//   ev_id    最小核事件号（sub=1 nand=2 load=3 store=4——语义锚，表加载侧校验存在）
//   dst     结果变量（store = 0 未用）；src1/src2 = 变量或常量池槽（flags 区分）
//   flags    bit0 = src1 为常量池槽（否则变量），bit1 = src2 为常量池槽
// 未用操作数字段恒存 0（勿存 -1：hit_w32 字节拆取仅定义非负值——自持 x86 截断
// 除法与 Python 解释地板除读回分裂（255 vs 0xFFFFFFFF），M2-2a 改存 0）。
// 降低规则（M1 直线子集：const/store/load/add/sub）：
//   IR_CONST n        → load 事件（addr = 池槽；池值发射时写 ELF rodata）
//   IR_BINARY OP_SUB  → sub 事件直通
//   IR_BINARY OP_ADD  → sub 反减 sub(a, sub(0, b))：事件 E1 sub(d, 池0, b)、
//                       E2 sub(d, a, d)——中间值驻 d（编码器先读后写，读先于写）；
//                       dest-fresh 前提 d != a（违反 → 0 事件落旧路径，M2-2c 防御）
//   IR_LOAD/IR_STORE  → load/store 事件直通（槽寻址；全局/形态不符由编码器预检落旧路径）
//   超子集 IR_BINARY 子操作 → 报错「needs more events」（exit 1）
// 未映射指令（RET/ALLOC/ARENA_*/…）→ 无事件 → 旧路径（M1 混合模式）。
//
// 常量池（g_hit_pool，每槽 8B，按值去重）：值于发射尾随字符串区写入 .rodata；
// 事件对池槽的引用由编码器记 g_hit_pool_patch（instr.cr 记、elf.cr 发射后回填 rip 位移）。
//
// 本文件仅进 corearch 构建清单（build_selfhost_native.py corearch concat，
// 位于 hit.cr 之后、instr.cr 之前）。import 行仅为独立 `corec check` 解析
// （concat 构建剥离 import 行；io/ast/globals/dyn_arr/hit 均在 corearch 闭包内；
// dyn_arr 的 iri_* 等访问器与 w32/r32/r64 即编译器 IR 访问面）。

import io
import fmt
import ast
import globals
import dyn_arr
import hit

// ════════════════════════════════════════════════════════════════
// 事件流 / 常量池 布局与状态
// ════════════════════════════════════════════════════════════════

// 最小核事件号契约（core-x86.toml 的 id 同此——表加载侧按 id 匹配，缺则旧路径）
HIT_EV_SUB   : int = 1;
HIT_EV_NAND  : int = 2;
HIT_EV_LOAD  : int = 3;
HIT_EV_STORE : int = 4;

HIT_ES_REC    : int = 20;  // 5 × i32
HIT_ES_OFF_ID    : int = 0;
HIT_ES_OFF_DST   : int = 4;
HIT_ES_OFF_S1    : int = 8;
HIT_ES_OFF_S2    : int = 12;
HIT_ES_OFF_FLAGS : int = 16;
HIT_ES_S1_POOL : int = 1;   // src1 = 常量池槽（否则 = 变量号）
HIT_ES_S2_POOL : int = 2;   // src2 = 常量池槽（否则 = 变量号）

g_hit_ev_stream : string, mut;  g_hit_ev_count : int, mut;  g_hit_ev_cap : int, mut;
g_hit_ev_map : string, mut;     g_hit_ev_map_size : int, mut;  // 每 IR 指令 8B {start u32, count u32}
g_hit_pool : string, mut;       g_hit_pool_count : int, mut;   g_hit_pool_cap : int, mut;
g_hit_pool_patch : string, mut; g_hit_pool_patch_count : int, mut;  g_hit_pool_patch_cap : int, mut;  // 16B/条 {pos i64, k i64}

fn hit_grow_ev(needed: int) {
    if needed < g_hit_ev_cap { return; }
    nc : ., mut = g_hit_ev_cap * 2;
    if nc < 64 { nc = 64; }
    if nc < needed { nc = needed + 8; }
    nb := alloc(nc * HIT_ES_REC);
    hit_copy_bytes(g_hit_ev_stream, g_hit_ev_cap * HIT_ES_REC, nb);
    g_hit_ev_stream = nb;
    g_hit_ev_cap = nc; }

fn hit_grow_pool(needed: int) {
    if needed < g_hit_pool_cap { return; }
    nc : ., mut = g_hit_pool_cap * 2;
    if nc < 8 { nc = 8; }
    if nc < needed { nc = needed + 4; }
    nb := alloc(nc * 8);
    hit_copy_bytes(g_hit_pool, g_hit_pool_cap * 8, nb);
    g_hit_pool = nb;
    g_hit_pool_cap = nc; }

fn hit_grow_pool_patch(needed: int) {
    if needed < g_hit_pool_patch_cap { return; }
    nc : ., mut = g_hit_pool_patch_cap * 2;
    if nc < 8 { nc = 8; }
    if nc < needed { nc = needed + 4; }
    nb := alloc(nc * 16);
    hit_copy_bytes(g_hit_pool_patch, g_hit_pool_patch_cap * 16, nb);
    g_hit_pool_patch = nb;
    g_hit_pool_patch_cap = nc; }

// 8B 补码小端写（借位链，两补正确——负值池槽可表达；仿 dyn_arr w32 链扩至 8 字节）
fn hit_pool_w64(buf: string, pos: int, v: int) {
    b0 : ., mut = v % 256;          t1 : ., mut = v / 256;
    b1 : ., mut = t1 % 256;         t2 : ., mut = t1 / 256;
    b2 : ., mut = t2 % 256;         t3 : ., mut = t2 / 256;
    b3 : ., mut = t3 % 256;         t4 : ., mut = t3 / 256;
    b4 : ., mut = t4 % 256;         t5 : ., mut = t4 / 256;
    b5 : ., mut = t5 % 256;         t6 : ., mut = t5 / 256;
    b6 : ., mut = t6 % 256;         t7 : ., mut = t6 / 256;
    b7 : ., mut = t7 % 256;
    if b0 < 0 { b0 = b0 + 256; b1 = b1 - 1; }
    if b1 < 0 { b1 = b1 + 256; b2 = b2 - 1; }
    if b2 < 0 { b2 = b2 + 256; b3 = b3 - 1; }
    if b3 < 0 { b3 = b3 + 256; b4 = b4 - 1; }
    if b4 < 0 { b4 = b4 + 256; b5 = b5 - 1; }
    if b5 < 0 { b5 = b5 + 256; b6 = b6 - 1; }
    if b6 < 0 { b6 = b6 + 256; b7 = b7 - 1; }
    if b7 < 0 { b7 = b7 + 256; }
    store8(buf, pos + 0, b0); store8(buf, pos + 1, b1);
    store8(buf, pos + 2, b2); store8(buf, pos + 3, b3);
    store8(buf, pos + 4, b4); store8(buf, pos + 5, b5);
    store8(buf, pos + 6, b6); store8(buf, pos + 7, b7); }

fn hit_lower_reset() {
    g_hit_ev_count = 0;
    g_hit_pool_count = 0;
    g_hit_pool_patch_count = 0; }

fn hit_ev_map_init(n: int) {
    g_hit_ev_map_size = n;
    g_hit_ev_map = alloc(n * 8 + 8); }

fn hit_ev_map_set(i: int, start: int, cnt: int) {
    w32(g_hit_ev_map, i * 8, start);
    w32(g_hit_ev_map, i * 8 + 4, cnt); }

fn hit_ev_map_cnt(i: int) -> int {
    if i < 0 || i >= g_hit_ev_map_size { return 0; }
    return r32(g_hit_ev_map, i * 8 + 4); }

fn hit_ev_map_start(i: int) -> int {
    if i < 0 || i >= g_hit_ev_map_size { return 0; }
    return r32(g_hit_ev_map, i * 8); }

// 追加一条事件（20B）；未用操作数 = 0（勿存 -1：hit_w32 非负约定——M2-2a）
fn hit_ev_append(ev_id: int, d: int, s1: int, s2: int, flags: int) {
    hit_grow_ev(g_hit_ev_count + 1);
    slot : ., mut = g_hit_ev_count;
    g_hit_ev_count = slot + 1;
    hit_w32(g_hit_ev_stream, slot * HIT_ES_REC + HIT_ES_OFF_ID, ev_id);
    hit_w32(g_hit_ev_stream, slot * HIT_ES_REC + HIT_ES_OFF_DST, d);
    hit_w32(g_hit_ev_stream, slot * HIT_ES_REC + HIT_ES_OFF_S1, s1);
    hit_w32(g_hit_ev_stream, slot * HIT_ES_REC + HIT_ES_OFF_S2, s2);
    hit_w32(g_hit_ev_stream, slot * HIT_ES_REC + HIT_ES_OFF_FLAGS, flags); }

// 事件流访问器（dump/编码器消费；i 为流内下标）
fn hit_ev_id(i: int) -> int { return hit_r32(g_hit_ev_stream, i * HIT_ES_REC + HIT_ES_OFF_ID); }
fn hit_ev_dst(i: int) -> int { return hit_r32(g_hit_ev_stream, i * HIT_ES_REC + HIT_ES_OFF_DST); }
fn hit_ev_s1(i: int) -> int { return hit_r32(g_hit_ev_stream, i * HIT_ES_REC + HIT_ES_OFF_S1); }
fn hit_ev_s2(i: int) -> int { return hit_r32(g_hit_ev_stream, i * HIT_ES_REC + HIT_ES_OFF_S2); }
fn hit_ev_flags(i: int) -> int { return hit_r32(g_hit_ev_stream, i * HIT_ES_REC + HIT_ES_OFF_FLAGS); }
fn hit_ev_total() -> int { return g_hit_ev_count; }

// 常量池：按值去重 intern；返回槽号
fn hit_pool_intern(v: int) -> int {
    k : ., mut = 0;
    loop {
        if k >= g_hit_pool_count { break; }
        if r64(g_hit_pool, k * 8) == v { return k; }
        k = k + 1; }
    hit_grow_pool(g_hit_pool_count + 1);
    pk : ., mut = g_hit_pool_count;
    g_hit_pool_count = pk + 1;
    hit_pool_w64(g_hit_pool, pk * 8, v);
    return pk; }

fn hit_pool_total() -> int { return g_hit_pool_count; }
fn hit_pool_val(k: int) -> int { return r64(g_hit_pool, k * 8); }

// 池引用 patch 记录（编码器在发射池值 mov 时调用；elf.cr 于 rodata 定稿后回填）
fn hit_pool_patch_add(pos: int, k: int) {
    hit_grow_pool_patch(g_hit_pool_patch_count + 1);
    slot : ., mut = g_hit_pool_patch_count;
    g_hit_pool_patch_count = slot + 1;
    w64(g_hit_pool_patch, slot * 16, pos);
    w64(g_hit_pool_patch, slot * 16 + 8, k); }

// ════════════════════════════════════════════════════════════════
// 降低规则（IR 直线子集 → 事件流）
// ════════════════════════════════════════════════════════════════

// 降低单条 IR 指令并追加事件。Returns 0 = 成功（可能无事件 = 旧路径直通）；
// 1 = 超子集 op（错误已打印）——调用方中止（exit 1）。
fn hit_lower_instr(j: int) -> int {
    op := iri_op(j);
    d := iri_dest(j);
    s1 := iri_s1(j);
    s2 := iri_s2(j);
    s3 := iri_s3(j);
    ti := iri_tk(j);
    if op == IR_CONST {
        // 字符串常量走旧路径（g2_str_off/rodataref 字符串机制）；
        // 其余常量 → 池槽 load 事件（8B 槽值发射时写 rodata）
        if ti == TI_STR { return 0; }
        if d < 0 { return 0; }
        k := hit_pool_intern(s1);
        hit_ev_append(HIT_EV_LOAD, d, k, 0, HIT_ES_S1_POOL);   // load 事件：addr = 池槽（s2 = 0 未用）
        return 0; }
    if op == IR_BINARY {
        if ti == TI_DEX { return 0; }   // binary64 运算走旧 SSE 路径（M1 不移表）
        if s3 == OP_SUB {
            if d < 0 || s1 < 0 || s2 < 0 { return 0; }
            hit_ev_append(HIT_EV_SUB, d, s1, s2, 0);
            return 0; }
        if s3 == OP_ADD {
            if d < 0 || s1 < 0 || s2 < 0 { return 0; }
            // dest-fresh 前提（M2-2c 防御）：E1 先把中间值 (0−b) 写入 d 槽；
            // d == a 时 E2 读 src1(a) 读到的已是中间值 → a − (0−b) 语义崩。
            // 落 0 事件 = 旧路径（旧路径编码器逐事件先读后写，无此前提）。
            if d == s1 { return 0; }
            k0 := hit_pool_intern(0);   // 合成 0（最小核无 const 事件）
            // sub 反减 add(a,b) := sub(a, sub(0,b))——中间值驻 d：
            // E1: d ← 0 − b；E2: d ← a − d（编码器先读后写，读先于写）
            hit_ev_append(HIT_EV_SUB, d, k0, s2, HIT_ES_S1_POOL);
            hit_ev_append(HIT_EV_SUB, d, s1, d, 0);
            return 0; }
        // 其余子操作（mul/div/mod/移位/位与/或/…）= 超出 M1 直线子集
        print("error: HIT lower: instr "); print_i(j);
        print(" op="); print_i(op); print(" sub="); print_i(s3);
        println(" needs more events (M1 straight-line subset: const/load/store/add/sub)");
        return 1; }
    if op == IR_LOAD {
        if d >= 0 && s1 >= 0 {
            // 槽读 → 槽写（全局/形态不符由编码器预检 → 整条落旧路径）；
            // s2 = 0 未用（勿存 -1：hit_w32 非负约定，M2-2a）
            hit_ev_append(HIT_EV_LOAD, d, s1, 0, 0);
        }
        return 0; }
    if op == IR_STORE {
        if s1 >= 0 && s2 >= 0 {
            // 槽写：addr = s1 槽、val = s2；dst = 0 未用（M2-2a）
            hit_ev_append(HIT_EV_STORE, 0, s1, s2, 0);
        }
        return 0; }
    return 0; }

// 全程序降低（corearch 表模式下、发射前调用）。
// M1 直线子集契约 = 入口函数 main 的指令流；.ccr 随带的标准库辅助函数
// （fmt/io 闭包，src/stdlib/_import.cr 无条件引入）含比较/分支/除法等超子集
// 运算——超出 M1 语义范围，记 0 事件（发射时落旧路径，混合模式）。main 内
// 超子集 op（mod/移位/…）→ 'needs more events' 报错（exit 1）。
// map 全量清零（未降低指令 0 事件）；仅降低 main。
// Returns 0 = 成功；1 = 超子集 op（错误已打印，调用方 exit 1）。
fn hit_lower_program() -> int {
    hit_lower_reset();
    hit_ev_map_init(g_ir_instr_count);
    mi : ., mut = 0;
    loop {
        if mi >= g_ir_instr_count { break; }
        hit_ev_map_set(mi, 0, 0);
        mi = mi + 1; }
    entry : ., mut = -1;
    fi : ., mut = 0;
    loop {
        if fi >= g_ir_func_count { break; }
        if str_eq(istr_get(r64(g_ir_func_name_idx, fi * 8)), "main") != 0 { entry = fi; break; }
        fi = fi + 1; }
    if entry < 0 { return 0; }   // 无 main = M1 载体外（不降低，全旧路径）
    ist := r64(g_ir_func_instr_start, entry * 8);
    ic := r64(g_ir_func_instr_count, entry * 8);
    ii : ., mut = 0;
    loop {
        if ii >= ic { break; }
        j := ist + ii;
        base : ., mut = g_hit_ev_count;
        if hit_lower_instr(j) != 0 { return 1; }
        hit_ev_map_set(j, base, g_hit_ev_count - base);
        ii = ii + 1; }
    return 0; }
