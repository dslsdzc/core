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
HIT_EV_JUMP  : int = 5;    // M2a：jump（rel32 事件流位置回填——发射 = instr.cr Task 2）
HIT_EV_BRANCH: int = 6;    // M2a：branch/call/ret/extern 模板已声明——发射 = Task 3 起
HIT_EV_CALL  : int = 7;
HIT_EV_RET   : int = 8;
HIT_EV_EXTERN: int = 9;

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

// ── M2a Task 2：rel 回填表 + 事件发射位置表 + 注入通道激活态 ──
// g_hit_rel：三张回填表合一（kind 0 = 事件流位置、1 = 函数起点、2 = 外部符号序），
// 24B/条 {kind i64, pos i64, target i64}（pos = rel 字段位置）。登记 = instr.cr
// 发射器（hit_rel_add）；回填 = elf.cr 发射后循环（本任务 kind 0 = 事件序目标）。
// g_hit_ev_pos：事件序 → 发射字节位置（8B/序；发射器边发边记——jump 回填消费）。
// g_hit_inject_active：--hit-events-file 注入通道激活（测试专用——预检拒绝升级为
// 大声错误 + 事件计数不符 = exit 1，防静默落旧路径掩盖注入文件错误）。
g_hit_rel : string, mut;         g_hit_rel_count : int, mut;  g_hit_rel_cap : int, mut;
g_hit_ev_pos : string, mut;      g_hit_ev_pos_count : int, mut;  g_hit_ev_pos_cap : int, mut;
g_hit_inject_active : int, mut;

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

fn hit_grow_rel(needed: int) {
    if needed < g_hit_rel_cap { return; }
    nc : ., mut = g_hit_rel_cap * 2;
    if nc < 8 { nc = 8; }
    if nc < needed { nc = needed + 4; }
    nb := alloc(nc * 24);
    hit_copy_bytes(g_hit_rel, g_hit_rel_cap * 24, nb);
    g_hit_rel = nb;
    g_hit_rel_cap = nc; }

fn hit_grow_ev_pos(needed: int) {
    if needed < g_hit_ev_pos_cap { return; }
    nc : ., mut = g_hit_ev_pos_cap * 2;
    if nc < 8 { nc = 8; }
    if nc < needed { nc = needed + 4; }
    nb := alloc(nc * 8);
    hit_copy_bytes(g_hit_ev_pos, g_hit_ev_pos_cap * 8, nb);
    g_hit_ev_pos = nb;
    g_hit_ev_pos_cap = nc; }

// rel 回填登记（M2a Task 2 接口——instr.cr 发射器调用；elf.cr 发射后回填）。
// kind: 0 = 事件流位置（jump/branch——事件序目标，本任务落地）、
//       1 = 函数起点、2 = 外部符号序（Task 4/5 消费——登记接口先行，回填拒接）。
fn hit_rel_add(kind: int, pos: int, target: int) {
    hit_grow_rel(g_hit_rel_count + 1);
    slot : ., mut = g_hit_rel_count;
    g_hit_rel_count = slot + 1;
    w64(g_hit_rel, slot * 24, kind);
    w64(g_hit_rel, slot * 24 + 8, pos);
    w64(g_hit_rel, slot * 24 + 16, target); }

// 事件序 → 发射位置记录（8B；发射器在事件字节落位前写入——位置 = 绝对 buf 偏移）
fn hit_ev_pos_set(ord: int, pos: int) {
    hit_grow_ev_pos(ord + 1);
    w64(g_hit_ev_pos, ord * 8, pos);
    if ord + 1 > g_hit_ev_pos_count { g_hit_ev_pos_count = ord + 1; } }

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
    g_hit_pool_patch_count = 0;
    // M2a Task 2：rel 回填表 + 事件位置表逐次发射清零
    g_hit_rel_count = 0;
    g_hit_ev_pos_count = 0; }

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

// ════════════════════════════════════════════════════════════════
// ════════════════════════════════════════════════════════════════
// 事件流注入测试通道（M2a Task 2）——hit_lower_program 的注入替身
// ════════════════════════════════════════════════════════════════
// corearch 隐藏 flag --hit-events-file <path>（测试专用；真实构建路径不启用）：
// 文本事件流文件（--dump-events 输出的逆格式）→ 构造 g_hit_ev_stream/g_hit_pool
// + 每指令事件映射，跳过降低直接 emit——模板对照与降低器解耦（Task 3/6 的
// 对照与 dump 断言全部经此通道，无需降低器先支持）。
//
// 文件格式（'#' 注释行可夹；行序 = 事件流序 = 指令序）：
//   ev <name> [dst=N] [s1=[pool]N] [s2=[pool]N]   每事件一行（name = 表内事件名）
//   pool <v0> <v1> ...                            池值行（按序入槽——可多行）
// 事件操作数域缺省 = 取所附着 IR 指令的同名操作数（dst→iri_dest、s1→iri_s1、
// s2→iri_s2；指令域为负 → 0）——测试作者无需知道 .ccr 全局变量号；需要改写
// 的域显式给（jump 的 s1 = 目标事件序；池引用写 s1=poolN）。
//
// 附着规则（= M1 降低的指令↔事件对应；未列事件指令 = 0 事件 → 旧路径——
// 逐字节对照面因此可含 const/分支等任意旧路径指令）：
//   事件 1 sub  ← IR_BINARY(OP_SUB)          事件 4 store ← IR_STORE
//   事件 3 load ← IR_LOAD（var 操作数）/ IR_CONST（非串、pool 操作数——池载入）
//   事件 5 jump ← IR_JUMP（s1 须显式 = 目标事件序）
//   事件 11 cst ← IR_CONST（非串、imm 直载 const 事件——cst 夹具表测试载体，
//        imm 值 = 事件 s1 原值；核心表未声明 id 11 时行解析即拒 'unknown event'）
//   其余事件（6-9 等）→ 无指令期望 → 行无法附着 → 拒绝（'no instruction
//   expects'——branch/call/ret/extern Task 3 前保持拒绝的大声面）。
// 解析/附着错误全部 return 1（corearch exit 1）。本文件与注入表均测试专用。
//
// 注入事件行暂存（解析期不知目标指令——两遍：先解析行，后走指令附着）：
// 每行 20B = {id i32, flags i32, dst i32, s1 i32, s2 i32}（flags 位见下）
g_hit_inj : string, mut;   g_hit_inj_count : int, mut;  g_hit_inj_cap : int, mut;

HIT_INJ_HAS_DST : int = 1;   // dst 域显式（否则 = 指令 dest）
HIT_INJ_HAS_S1  : int = 2;   // s1 域显式
HIT_INJ_HAS_S2  : int = 4;   // s2 域显式
HIT_INJ_S1_POOL : int = 8;   // s1 = 池槽引用
HIT_INJ_S2_POOL : int = 16;  // s2 = 池槽引用

fn hit_grow_inj(needed: int) {
    if needed < g_hit_inj_cap { return; }
    nc : ., mut = g_hit_inj_cap * 2;
    if nc < 8 { nc = 8; }
    if nc < needed { nc = needed + 4; }
    nb := alloc(nc * 20);
    hit_copy_bytes(g_hit_inj, g_hit_inj_cap * 20, nb);
    g_hit_inj = nb;
    g_hit_inj_cap = nc; }

fn hit_inj_line_id(i: int) -> int { return hit_r32(g_hit_inj, i * 20 + 0); }
fn hit_inj_line_flags(i: int) -> int { return hit_r32(g_hit_inj, i * 20 + 4); }
fn hit_inj_line_dst(i: int) -> int { return hit_r32(g_hit_inj, i * 20 + 8); }
fn hit_inj_line_s1(i: int) -> int { return hit_r32(g_hit_inj, i * 20 + 12); }
fn hit_inj_line_s2(i: int) -> int { return hit_r32(g_hit_inj, i * 20 + 16); }

// 事件名 → 事件槽（反向查名——dump 打印名、注入文件写名；未知 → -1）
fn hit_inj_event_by_name(name: string) -> int {
    ei : ., mut = 0;
    loop {
        if ei >= g_hit_event_count { break; }
        if str_eq(hit_event_name(ei), name) != 0 { return ei; }
        ei = ei + 1; }
    return -1; }

// 注入行附着期望：指令 (op, subop, ti) 是否期望事件行 (l_id, l_pool)。
// 未列事件（6-9 等）= 无期望 → 行不得附着（拒绝面）。
fn hit_inj_line_expected(op: int, subop: int, ti: int, l_id: int, l_pool: int) -> int {
    if l_id == HIT_EV_JUMP { if op == IR_JUMP && l_pool == 0 { return 1; } return 0; }
    if l_id == HIT_EV_SUB {
        if op == IR_BINARY && subop == OP_SUB { return 1; }
        return 0; }
    if l_id == HIT_EV_STORE { if op == IR_STORE { return 1; } return 0; }
    if l_id == HIT_EV_LOAD {
        if op == IR_LOAD && l_pool == 0 { return 1; }
        if op == IR_CONST && ti != TI_STR && l_pool == 1 { return 1; }
        return 0; }
    if l_id == 11 {   // cst 夹具事件（imm 直载 const）——注入测试载体，见上注
        if op == IR_CONST && ti != TI_STR && l_pool == 0 { return 1; }
        return 0; }
    return 0; }

// 行分派：pool 值行 / ev 事件行 / 坏行。0 = 行已处理；1 = 错误（已打印）。
fn hit_inj_parse_line(line: string) -> int {
    llen := str_len(line);
    if llen >= 4 && load8(line, 0) == 112 && load8(line, 1) == 111 &&
       load8(line, 2) == 111 && load8(line, 3) == 108 &&
       (llen == 4 || load8(line, 4) == 32) {
        return hit_inj_parse_pool_line(line); }
    if llen >= 2 && load8(line, 0) == 101 && load8(line, 1) == 118 &&
       (llen == 2 || load8(line, 2) == 32) {
        return hit_inj_parse_ev_line(line); }
    print("error: HIT events: bad event line: "); println(line);
    return 1; }

// pool 行：空格分隔值按序入池槽（可多行）。0 = 成功；1 = 错误（已打印）。
fn hit_inj_parse_pool_line(line: string) -> int {
    llen := str_len(line);
    vp : ., mut = 4;
    loop {
        loop {
            if vp >= llen { break; }
            if load8(line, vp) == 32 { vp = vp + 1; } else { break; } }
        if vp >= llen { break; }
        vv := hit_inj_parse_int(line, vp);
        if vv < 0 {
            print("error: HIT events: bad pool value at line: ");
            println(line);
            return 1; }
        hit_grow_pool(g_hit_pool_count + 1);
        hit_pool_w64(g_hit_pool, g_hit_pool_count * 8, vv);
        g_hit_pool_count = g_hit_pool_count + 1;
        loop {   // 越过该值全部数字（'-' 含首字符——已在 parse 校验）
            if vp >= llen { break; }
            c := load8(line, vp);
            if c >= 48 && c <= 57 || c == 45 { vp = vp + 1; } else { break; } } }
    return 0; }

// ev 行：`ev <name> [dst=N] [s1=[pool]N] [s2=[pool]N]`——操作数域缺省 = 附着时
// 取指令同名操作数（附着规则见 hit_inj_line_expected）。行暂存 20B 待遍 2 附着。
// 0 = 成功；1 = 错误（已打印）。
fn hit_inj_parse_ev_line(line: string) -> int {
    llen := str_len(line);
    np : ., mut = 2;
    loop {
        if np >= llen { break; }
        if load8(line, np) == 32 { np = np + 1; } else { break; } }
    ne : ., mut = np;
    loop {
        if ne >= llen { break; }
        if load8(line, ne) == 32 { break; }
        ne = ne + 1; }
    if ne <= np {
        print("error: HIT events: bad event line: "); println(line);
        return 1; }
    es := hit_inj_event_by_name(str_sub(line, np, ne - np));
    if es < 0 {
        print("error: HIT events: unknown event '");
        print(str_sub(line, np, ne - np)); println("'");
        return 1; }
    ev_id := hit_r32(g_hit_events, es * HIT_EVENT_REC + HIT_EV_OFF_ID);
    fl : ., mut = 0;
    dv : ., mut = 0;
    s1v : ., mut = 0;
    s2v : ., mut = 0;
    dpos := hit_inj_field_of(line, ne, "dst", 0);
    if dpos == -2 {
        print("error: HIT events: bad dst at line: "); println(line);
        return 1; }
    if dpos >= 0 {
        dv = hit_inj_parse_int(line, dpos);
        if dv < 0 {
            print("error: HIT events: bad dst at line: "); println(line);
            return 1; }
        fl = fl + HIT_INJ_HAS_DST; }
    s1pos := hit_inj_field_of(line, ne, "s1", 1);
    if s1pos == -2 {
        print("error: HIT events: bad s1 at line: "); println(line);
        return 1; }
    if s1pos >= 0 {
        if load8(line, s1pos) == 112 {   // poolN
            s1v = str_int(str_sub(line, s1pos + 4, str_len(line) - s1pos - 4));
            fl = fl + HIT_INJ_HAS_S1 + HIT_INJ_S1_POOL; }
        else {
            s1v = hit_inj_parse_int(line, s1pos);
            if s1v < 0 {
                print("error: HIT events: bad s1 at line: "); println(line);
                return 1; }
            fl = fl + HIT_INJ_HAS_S1; } }
    s2pos := hit_inj_field_of(line, ne, "s2", 1);
    if s2pos == -2 {
        print("error: HIT events: bad s2 at line: "); println(line);
        return 1; }
    if s2pos >= 0 {
        if load8(line, s2pos) == 112 {
            s2v = str_int(str_sub(line, s2pos + 4, str_len(line) - s2pos - 4));
            fl = fl + HIT_INJ_HAS_S2 + HIT_INJ_S2_POOL; }
        else {
            s2v = hit_inj_parse_int(line, s2pos);
            if s2v < 0 {
                print("error: HIT events: bad s2 at line: "); println(line);
                return 1; }
            fl = fl + HIT_INJ_HAS_S2; } }
    hit_grow_inj(g_hit_inj_count + 1);
    hit_w32(g_hit_inj, g_hit_inj_count * 20 + 0, ev_id);
    hit_w32(g_hit_inj, g_hit_inj_count * 20 + 4, fl);
    hit_w32(g_hit_inj, g_hit_inj_count * 20 + 8, dv);
    hit_w32(g_hit_inj, g_hit_inj_count * 20 + 12, s1v);
    hit_w32(g_hit_inj, g_hit_inj_count * 20 + 16, s2v);
    g_hit_inj_count = g_hit_inj_count + 1;
    return 0; }

// 注入文件解析 + 指令附着（入口函数 = main——与降低同定位）。0 = 成功；1 = 错
//（错误已打印——corearch 侧 exit 1）。
fn hit_inject_events(path: string) -> int {
    content := read_file(path);
    if str_len(content) == 0 {
        print("error: cannot open HIT events file: "); println(path);
        return 1; }
    hit_lower_reset();
    g_hit_inj_count = 0;
    // ── 遍 1：逐行解析（pool 值直入池；ev 行暂存待附着）──
    slen := str_len(content);
    ln : ., mut = 0;
    loop {
        if ln >= slen { break; }
        s : ., mut = ln;
        loop {
            if s >= slen { break; }
            c := load8(content, s);
            if c == 32 || c == 9 { s = s + 1; } else { break; } }
        e : ., mut = s;
        loop {
            if e >= slen { break; }
            if load8(content, e) == 10 { break; }
            e = e + 1; }
        if s < e && load8(content, s) != 35 {   // 非注释非空行
            line := str_sub(content, s, e - s);
            if hit_inj_parse_line(line) != 0 { return 1; }
        }
        ln = e + 1; }
    // ── 遍 2：入口函数（main）指令序附着（行序 = 指令序——未匹配行留待下条）──
    entry : ., mut = -1;
    fi : ., mut = 0;
    loop {
        if fi >= g_ir_func_count { break; }
        if str_eq(istr_get(r64(g_ir_func_name_idx, fi * 8)), "main") != 0 { entry = fi; break; }
        fi = fi + 1; }
    if entry < 0 {
        println("error: HIT events: no main function to attach events to");
        return 1; }
    hit_ev_map_init(g_ir_instr_count);
    mi : ., mut = 0;
    loop {
        if mi >= g_ir_instr_count { break; }
        hit_ev_map_set(mi, 0, 0);
        mi = mi + 1; }
    ist := r64(g_ir_func_instr_start, entry * 8);
    ic := r64(g_ir_func_instr_count, entry * 8);
    cur : ., mut = 0;   // 下一条未附着行
    ii : ., mut = 0;
    loop {
        if ii >= ic { break; }
        j := ist + ii;
        if cur < g_hit_inj_count {
            op := iri_op(j);
            ti := iri_tk(j);
            subop : ., mut = -1;
            if op == IR_BINARY { subop = iri_s3(j); }
            l_id := hit_inj_line_id(cur);
            l_fl := hit_inj_line_flags(cur);
            l_pool : ., mut = 0;
            if l_fl / 8 % 2 == 1 { l_pool = 1; }
            if hit_inj_line_expected(op, subop, ti, l_id, l_pool) == 1 {
                if l_id == HIT_EV_JUMP && l_fl / 2 % 2 == 0 {
                    println("error: HIT events: jump event needs explicit s1 (target event ordinal)");
                    return 1; }
                // 附着：事件记录 = 行值（缺省取指令同名操作数）
                d : ., mut = hit_inj_line_dst(cur);
                if l_fl % 2 == 0 { d = iri_dest(j); if d < 0 { d = 0; } }
                s1 : ., mut = hit_inj_line_s1(cur);
                if l_fl / 2 % 2 == 0 { s1 = iri_s1(j); if s1 < 0 { s1 = 0; } }
                s2 : ., mut = hit_inj_line_s2(cur);
                if l_fl / 4 % 2 == 0 { s2 = iri_s2(j); if s2 < 0 { s2 = 0; } }
                evfl : ., mut = 0;
                if l_fl / 8 % 2 == 1 { evfl = evfl + HIT_ES_S1_POOL; }
                if l_fl / 16 % 2 == 1 { evfl = evfl + HIT_ES_S2_POOL; }
                hit_ev_append(l_id, d, s1, s2, evfl);
                hit_ev_map_set(j, g_hit_ev_count - 1, 1);
                cur = cur + 1; } }
        ii = ii + 1; }
    // ── 遍 3：尾校验（未附着行 = 作者错——事件不支持/与指令序不符）──
    if cur < g_hit_inj_count {
        print("error: HIT events: no instruction expects event ");
        print(hit_event_name(hit_event_lookup(hit_inj_line_id(cur))));
        print(" (line "); print_i(cur + 1); println(")");
        return 1; }
    if g_hit_inj_count == 0 {
        println("error: HIT events: file has no ev lines");
        return 1; }
    // jump 事件目标 = 事件序——范围校验（0 ≤ 目标 < 总事件数）
    ji : ., mut = 0;
    loop {
        if ji >= g_hit_ev_count { break; }
        if hit_ev_id(ji) == HIT_EV_JUMP {
            t := hit_ev_s1(ji);
            if t < 0 || t >= g_hit_ev_count {
                print("error: HIT events: jump target event ordinal ");
                print_i(t); print(" out of range (0..");
                print_i(g_hit_ev_count - 1); println(")");
                return 1; } }
        ji = ji + 1; }
    return 0; }

// 行内数值 token 解析（val 起为值首；返回 值；-1 = 非数）
fn hit_inj_parse_int(content: string, val: int) -> int {
    slen := str_len(content);
    p : ., mut = val;
    if p < slen && load8(content, p) == 45 { p = p + 1; }   // '-'（池负值）
    if p >= slen { return -1; }
    if load8(content, p) < 48 || load8(content, p) > 57 { return -1; }
    return str_int(str_sub(content, val, str_len(content) - val)); }

// k=v 字段定位：从 fpos 起找 token "k="；命中返回 v 起偏移（v = 数或 "pool"）。
// 返回：≥0 = 值起；-1 = 键未出现；-2 = 键出现但值非数/非 pool（坏值——调用方报错）。
fn hit_inj_field_of(content: string, fpos: int, key: string, pool_ok: int) -> int {
    slen := str_len(content);
    klen := str_len(key);
    p : ., mut = fpos;
    loop {
        if p + klen >= slen { return -1; }
        if load8(content, p + klen) == 61 && (p == fpos || load8(content, p - 1) == 32) {
            m : ., mut = 0;
            ok : ., mut = 1;
            loop {
                if m >= klen { break; }
                if load8(content, p + m) != load8(key, m) { ok = 0; break; }
                m = m + 1; }
            if ok == 1 {
                v0 : ., mut = p + klen + 1;
                if v0 >= slen { return -2; }
                c := load8(content, v0);
                if pool_ok == 1 && c == 112 && v0 + 4 <= slen &&
                   load8(content, v0 + 1) == 111 && load8(content, v0 + 2) == 111 &&
                   load8(content, v0 + 3) == 108 { return v0; }
                if c >= 48 && c <= 57 || c == 45 { return v0; }
                return -2; }
        }
        p = p + 1; }
    return -1; }
