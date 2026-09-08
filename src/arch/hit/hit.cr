// === src/arch/hit/hit.cr ===
// 硬件接口表（HIT）：core-x86.toml → 内存表 加载器（M1 Task 1 + M2a Task 1 schema v2）。
// 设计：docs/superpowers/specs/2026-09-05-hardware-interface-table.md
// 格式：docs/superpowers/plans/2026-09-05-hit-minimal-core-m1.md「表文件格式」节
//      + docs/superpowers/specs/2026-09-07-hit-m2-design.md §3（schema v2）
// 表 = corearch 运行的唯一平台依赖：load_hit_table 把 toml 表文件读成
// 事件/投影/步 三块紧凑 buffer 表 + 运行时条目，表驱动编码器直读。
//
// schema v2（M2a Task 1）：步模板从 M1 的 5 字段扩展为完整形态描述
// prefix/rex/opcode/modrm{role|digit}/SIB/disp/imm/rel/cond；每事件可多 proj
// 条目（多形态）；[[event.proj.step]] 步小节表达多步序列；[runtime.x86] 小节
// 表达运行时条目。M1 表形态（字段直置 proj 层、单 proj、无 runtime）
// = v2 子集，加载不变。字段值域/关联规则校验错误全部拒绝加载。
//
// 本文件仅进 corearch 构建清单（build_selfhost_native.py corearch concat），
// corec 不需要。import 行仅为独立 `corec check src/arch/hit/hit.cr` 解析
// （flat concat 构建会剥离 import 行；io/toml/fmt 均在 corearch 闭包内）。
import io
import toml
import fmt

// ════════════════════════════════════════════════════════════════
// 内存表布局（直读；LE 存取用 hit_w32/hit_r32）
// ════════════════════════════════════════════════════════════════

// g_hit_events：每事件 40B = 10 × i32
HIT_EVENT_REC : int = 40;
HIT_EV_OFF_ID         : int = 0;   // 最小核事件号（1-4 数据 + 5-9 控制/调用/系统）
HIT_EV_OFF_NAME       : int = 4;   // 名字串下标（g_hit_names 表）
HIT_EV_OFF_INPUTS     : int = 8;   // 事件签名（无宽度/寄存器/寻址——最小核抽象）
HIT_EV_OFF_OUTPUTS    : int = 12;
HIT_EV_OFF_SIDE       : int = 16;  // 0 = pure，1 = effect
// 20/24/28 = proj0（M1 兼容视区）：M1 消费方（emit_instr_tabled → hit_ev_step_of
// → hit_proj_step(es, 0, st)）只读首投影视图，故把 proj0 的 isa/步数/首步偏移
// 镜像于此，多 proj 事件的其余形态走 32/36 字段。旧路径消费面布局不变。
HIT_EV_OFF_ISA        : int = 20;  // proj0 ISA 码（1 = x86-64）
HIT_EV_OFF_STEP_COUNT : int = 24;  // proj0 步数
HIT_EV_OFF_STEP_OFF   : int = 28;  // proj0 首步在 g_hit_steps 的字节偏移
HIT_EV_OFF_PROJ_OFF   : int = 32;  // 首投影记录下标（g_hit_projs，12B/条）
HIT_EV_OFF_PROJ_COUNT : int = 36;  // 投影形态数（M1 恒 1）

// g_hit_projs：每投影 12B = 3 × i32（事件 32/36 字段索引本表）
HIT_PROJ_REC : int = 12;
HIT_PJ_OFF_ISA        : int = 0;   // 投影 ISA 码
HIT_PJ_OFF_STEP_COUNT : int = 4;   // 该形态步数
HIT_PJ_OFF_STEP_OFF   : int = 8;   // 该形态首步在 g_hit_steps 的字节偏移

// g_hit_steps：每步 108B。前 20B = M1 布局视区（OP0/OP1/REG_ROLE/RM_ROLE/
// RM_MODE——偏移与旧布局一致，旧消费方原样可读）；20B 起 = v2 规范字段。
// 模板字节 = prefix → REX → opcode 三段固定拼接序（不含 ModRM/SIB/disp/imm/
// rel——那些由槽位/角色回填，非模板字节）。
HIT_STEP_REC : int = 108;
HIT_ST_OFF_OP0      : int = 0;    // 字节流首字节（prefix/REX/opcode 拼接序）
HIT_ST_OFF_OP1      : int = 4;    // 字节流第二字节（0 = 无）
HIT_ST_OFF_REG_ROLE : int = 8;    // modrm.reg 侧角色码（角色 1-6 / 寄存器字面量 16+regno；0 = 无/digit 形）
HIT_ST_OFF_RM_ROLE  : int = 12;   // modrm.rm 角色码（同上；0 = 无）
HIT_ST_OFF_RM_MODE  : int = 16;   // 0 = rm 为寄存器；1 = rm 为 base+disp（缺省 base = rbp）；2 = SIB
// ── v2 规范字段（20 起；未用恒 0）──
HIT_ST_OFF_PFX0        : int = 20;  // 前缀字节 0（66/0F…）
HIT_ST_OFF_PFX1        : int = 24;  // 前缀字节 1
HIT_ST_OFF_REX         : int = 28;  // REX 字节（0x40|w<<3|r<<2|x<<1|b；无 REX = 0）
HIT_ST_OFF_OPB0        : int = 32;  // opcode 字节 0
HIT_ST_OFF_OPB1        : int = 36;  // opcode 字节 1
HIT_ST_OFF_OPB2        : int = 40;  // opcode 字节 2
HIT_ST_OFF_OPN         : int = 44;  // opcode 字节数（1..3）
HIT_ST_OFF_REG_IS_DIGIT : int = 48; // reg 侧为 /digit（1）而非角色
HIT_ST_OFF_REG_DIGIT   : int = 52;  // digit 值（0..7）
HIT_ST_OFF_BASE_ROLE   : int = 56;  // base 角色码（rm_mode 1 = modrm base，缺省 rbp→0；
                                    // rm_mode 2 = SIB base；rip = 32 池/rodata/全局形）
HIT_ST_OFF_SIB_SCALE   : int = 60;  // SIB scale（0..3；非 rm_mode 2 = 0）
HIT_ST_OFF_SIB_INDEX   : int = 64;  // SIB index 角色码
HIT_ST_OFF_DISP_SIZE   : int = 68;  // disp 宽度：0 = auto（槽回填按幅度选 1|4）；1/4 字面
HIT_ST_OFF_DISP_SRC    : int = 72;  // disp 源角色码（0 = 无/槽隐含）
HIT_ST_OFF_IMM_SIZE    : int = 76;  // imm 宽度（1/2/4/8；0 = 无）
HIT_ST_OFF_IMM_ROLE    : int = 80;  // imm 操作数角色码（字面量 lit = 100）
HIT_ST_OFF_IMM_KIND    : int = 84;  // imm 回填 kind（0 = 无；1 = fnaddr）
HIT_ST_OFF_IMM_LIT     : int = 88;  // imm 字面量值（imm_role = lit 时）
HIT_ST_OFF_REL_ROLE    : int = 92;  // rel 回填操作数角色码（0 = 无）
HIT_ST_OFF_REL_KIND    : int = 96;  // rel 回填表：1 = 事件流位置；2 = 函数；3 = 外部符号
HIT_ST_OFF_REL_SIZE    : int = 100; // rel 宽度（8/32）
HIT_ST_OFF_COND_ROLE   : int = 104; // branch 条件源槽角色码（cmp/test 序列操作数）

// 角色/效应/ISA 码
HIT_ROLE_DST  : int = 1;
HIT_ROLE_SRC1 : int = 2;
HIT_ROLE_SRC2 : int = 3;
HIT_ROLE_ADDR : int = 4;
HIT_ROLE_VAL  : int = 5;
HIT_ROLE_COND : int = 6;          // branch 条件源（v2）
HIT_SIDE_PURE : int = 0;
HIT_SIDE_EFFECT : int = 1;
HIT_ISA_X86 : int = 1;
// 操作数码空间补充（与角色码不相交）
HIT_REG_BASE : int = 16;          // 寄存器字面量 = 16 + regno（rax=0..r15=15）
HIT_CODE_RIP : int = 32;          // rip 基（仅 base 键合法）
HIT_CODE_LIT : int = 100;         // imm 字面量（imm_role = "lit"）
// rel kind 码
HIT_REL_EVENT : int = 1;
HIT_REL_FUNC  : int = 2;
HIT_REL_EXTERN : int = 3;
// imm kind 码
HIT_IMM_FNADDR : int = 1;
// [runtime.x86] 条目槽（每槽 4B；见 hit_parse_runtime_chunk）
HIT_RT_CALL_MECHANISM  : int = 0;
HIT_RT_CALL_RET_ADDR   : int = 1;
HIT_RT_CALL_STACK_GROW : int = 2;
HIT_RT_PARAM_MODE      : int = 3;
HIT_RT_PARAM_MASK      : int = 4;
HIT_RT_SAVE_MASK       : int = 5;
HIT_RT_EXTERN_ENTRY    : int = 6;
HIT_RT_EXTERN_RESOLVE  : int = 7;

// 表加载全局（hit.cr 仅进 corearch 构建 → 不污染 corec/corelsp）
g_hit_events : string, mut;   g_hit_event_count : int, mut;  g_hit_event_cap : int, mut;
g_hit_steps  : string, mut;   g_hit_step_count : int, mut;   g_hit_step_cap : int, mut;
g_hit_projs  : string, mut;   g_hit_proj_count : int, mut;   g_hit_proj_cap : int, mut;
g_hit_names  : string, mut;   g_hit_name_count : int, mut;   g_hit_name_cap : int, mut;
g_hit_runtime : string, mut;  g_hit_runtime_present : int, mut;

// ════════════════════════════════════════════════════════════════
// buffer 表小工具（自持：仅用运行时内建 load8/store8/alloc）
// ════════════════════════════════════════════════════════════════

fn hit_copy_bytes(src: string, n: int, dst: string) {
    i : int, mut = 0;
    loop {
        if i >= n { break; }
        store8(dst, i, load8(src, i));
        i = i + 1; }
}

// 4B 小端写/读（仅存非负值——id/字节/码 均非负；字节拆取仿 w32 的 % 256
// 惯例——按位 & 不进 HIT 表值域：本文件仅 hit_bit 用倍增）
fn hit_w32(buf: string, pos: int, v: int) {
    store8(buf, pos + 0, v % 256);
    store8(buf, pos + 1, (v / 256) % 256);
    store8(buf, pos + 2, (v / 65536) % 256);
    store8(buf, pos + 3, (v / 16777216) % 256); }

fn hit_r32(buf: string, pos: int) -> int {
    return load8(buf, pos) + load8(buf, pos + 1) * 256 +
           load8(buf, pos + 2) * 65536 + load8(buf, pos + 3) * 16777216; }

fn hit_zero_bytes(buf: string, from: int, n: int) {
    i : int, mut = 0;
    loop {
        if i >= n { break; }
        store8(buf, from + i, 0);
        i = i + 1; }
}

fn hit_grow_events(needed: int) {
    if needed < g_hit_event_cap { return; }
    nc : int, mut = g_hit_event_cap * 2;
    if nc < 16 { nc = 16; }
    if nc < needed { nc = needed + 4; }
    nb := alloc(nc * HIT_EVENT_REC);
    hit_copy_bytes(g_hit_events, g_hit_event_cap * HIT_EVENT_REC, nb);
    g_hit_events = nb;
    g_hit_event_cap = nc; }

fn hit_grow_steps(needed: int) {
    if needed < g_hit_step_cap { return; }
    nc : int, mut = g_hit_step_cap * 2;
    if nc < 16 { nc = 16; }
    if nc < needed { nc = needed + 4; }
    nb := alloc(nc * HIT_STEP_REC);
    hit_copy_bytes(g_hit_steps, g_hit_step_cap * HIT_STEP_REC, nb);
    g_hit_steps = nb;
    g_hit_step_cap = nc; }

fn hit_grow_projs(needed: int) {
    if needed < g_hit_proj_cap { return; }
    nc : int, mut = g_hit_proj_cap * 2;
    if nc < 16 { nc = 16; }
    if nc < needed { nc = needed + 4; }
    nb := alloc(nc * HIT_PROJ_REC);
    hit_copy_bytes(g_hit_projs, g_hit_proj_cap * HIT_PROJ_REC, nb);
    g_hit_projs = nb;
    g_hit_proj_cap = nc; }

fn hit_grow_names(needed: int) {
    if needed < g_hit_name_cap { return; }
    nc : int, mut = g_hit_name_cap * 2;
    if nc < 16 { nc = 16; }
    if nc < needed { nc = needed + 4; }
    nb := alloc(nc * 8);
    hit_copy_bytes(g_hit_names, g_hit_name_cap * 8, nb);
    g_hit_names = nb;
    g_hit_name_cap = nc; }

// ════════════════════════════════════════════════════════════════
// toml 文本扫描（表文件结构层；标量值解析复用 stdlib toml.cr）
// ════════════════════════════════════════════════════════════════

// 从 pos 起逐行扫描，返回第一个 tag 匹配的行首偏移；无 → -1。
// 匹配规则：行首（允许前导空白）字节与 tag 完全相等，且 tag 之后只允许
// 行尾 / 空白 / '\r'（CRLF）/ '#'（行尾注释）——容忍手写表的
// "[[event.proj]]   # 注释" 形式；同时避免 "[[event]]" 前缀误配
// "[[event.proj]]"（tag 后必须紧跟界定符）。
fn hit_find_tag(content: string, pos: int, tag: string) -> int {
    slen := str_len(content);
    tlen := str_len(tag);
    p : int, mut = pos;
    loop {
        if p >= slen { break; }
        s : int, mut = p;
        loop {
            if s >= slen { break; }
            c := load8(content, s);
            if c == 32 || c == 9 { s = s + 1; } else { break; }
        }
        e : int, mut = s;
        loop {
            if e >= slen { break; }
            if load8(content, e) == 10 { break; }
            e = e + 1; }
        if s + tlen <= e {
            m : int, mut = 0;
            ok : int, mut = 1;
            loop {
                if m >= tlen { break; }
                if load8(content, s + m) != load8(tag, m) { ok = 0; break; }
                m = m + 1; }
            if ok == 1 {
                if s + tlen == e { return s; }   // tag 到行尾（\n 或 EOF）
                c2 := load8(content, s + tlen);
                if c2 == 13 || c2 == 32 || c2 == 9 || c2 == 35 { return s; }
            }
        }
        p = e + 1; }
    return -1; }

// pos 所在行的行尾后偏移（下一行首；EOF = 文长）
fn hit_line_after(content: string, pos: int) -> int {
    slen := str_len(content);
    i : int, mut = pos;
    loop {
        if i >= slen { break; }
        if load8(content, i) == 10 { return i + 1; }
        i = i + 1; }
    return slen; }

// 行首 token（键名）判定：text 中是否存在以 key 为整 token 的行
// （token 终止符 = 空白 / '=' / 行尾；'#' 注释行跳过）。
fn hit_has_key(text: string, key: string) -> int {
    slen := str_len(text);
    klen := str_len(key);
    p : int, mut = 0;
    loop {
        if p >= slen { break; }
        s : int, mut = p;
        loop {
            if s >= slen { break; }
            c := load8(text, s);
            if c == 32 || c == 9 { s = s + 1; } else { break; } }
        e : int, mut = s;
        loop {
            if e >= slen { break; }
            if load8(text, e) == 10 { break; }
            e = e + 1; }
        if s < e && load8(text, s) == 35 { p = e + 1; continue; }   // '#' 注释行
        t : int, mut = s;
        loop {
            if t >= e { break; }
            c := load8(text, t);
            if c == 32 || c == 9 || c == 61 { break; }
            t = t + 1; }
        if t - s == klen {
            m : int, mut = 0;
            ok : int, mut = 1;
            loop {
                if m >= klen { break; }
                if load8(text, s + m) != load8(key, m) { ok = 0; break; }
                m = m + 1; }
            if ok == 1 { return 1; }
        }
        p = e + 1; }
    return 0; }

// allowed（空格分隔键名表）中是否含 key（整 token 匹配）
fn hit_key_allowed(allowed: string, key: string) -> int {
    alen := str_len(allowed);
    klen := str_len(key);
    p : int, mut = 0;
    loop {
        if p >= alen { break; }
        loop {
            if p >= alen { break; }
            if load8(allowed, p) == 32 { p = p + 1; } else { break; } }
        if p >= alen { break; }
        e : int, mut = p;
        loop {
            if e >= alen { break; }
            if load8(allowed, e) == 32 { break; }
            e = e + 1; }
        if e - p == klen {
            m : int, mut = 0;
            ok : int, mut = 1;
            loop {
                if m >= klen { break; }
                if load8(allowed, p + m) != load8(key, m) { ok = 0; break; }
                m = m + 1; }
            if ok == 1 { return 1; }
        }
        p = e; }
    return 0; }

// 本层键名白名单扫描：任一非 '#' 行以不在 allowed 中的键开头 → 报错
// "unknown key"。Returns 0 = 干净；1 = 已报未知键。
fn hit_scan_keys_ok(text: string, allowed: string) -> int {
    slen := str_len(text);
    p : int, mut = 0;
    loop {
        if p >= slen { break; }
        s : int, mut = p;
        loop {
            if s >= slen { break; }
            c := load8(text, s);
            if c == 32 || c == 9 { s = s + 1; } else { break; } }
        e : int, mut = s;
        loop {
            if e >= slen { break; }
            if load8(text, e) == 10 { break; }
            e = e + 1; }
        if s < e && load8(text, s) != 35 {   // 非注释行
            t : int, mut = s;
            loop {
                if t >= e { break; }
                c := load8(text, t);
                if c == 32 || c == 9 || c == 61 { break; }
                t = t + 1; }
            if t > s {
                tok := str_sub(text, s, t - s);
                if hit_key_allowed(allowed, tok) == 0 {
                    print("error: HIT table: unknown key '"); print(tok); println("'");
                    return 1; }
            }
        }
        p = e + 1; }
    return 0; }

// 原始值串（key = 之后到行尾注释前，去首尾空白；返回原样含引号）
fn hit_raw_str(text: string, key: string) -> string {
    slen := str_len(text);
    klen := str_len(key);
    p : int, mut = 0;
    loop {
        if p >= slen { return ""; }
        s : int, mut = p;
        loop {
            if s >= slen { break; }
            c := load8(text, s);
            if c == 32 || c == 9 { s = s + 1; } else { break; } }
        e : int, mut = s;
        loop {
            if e >= slen { break; }
            if load8(text, e) == 10 { break; }
            e = e + 1; }
        if s < e && load8(text, s) != 35 && s + klen <= e {
            m : int, mut = 0;
            ok : int, mut = 1;
            loop {
                if m >= klen { break; }
                if load8(text, s + m) != load8(key, m) { ok = 0; break; }
                m = m + 1; }
            if ok == 1 {
                q : int, mut = s + klen;
                loop {
                    if q >= e { break; }
                    if load8(text, q) == 32 || load8(text, q) == 9 { q = q + 1; } else { break; } }
                if q < e && load8(text, q) == 61 {
                    v0 : int, mut = q + 1;
                    loop {
                        if v0 >= e { break; }
                        if load8(text, v0) == 32 || load8(text, v0) == 9 { v0 = v0 + 1; } else { break; } }
                    v1 : int, mut = v0;
                    loop {
                        if v1 >= e { break; }
                        if load8(text, v1) == 35 { break; }   // '#' 行尾注释
                        v1 = v1 + 1; }
                    loop {
                        if v1 <= v0 { break; }
                        c := load8(text, v1 - 1);
                        if c == 32 || c == 9 || c == 13 { v1 = v1 - 1; } else { break; } }
                    return str_sub(text, v0, v1 - v0);
                }
            }
        }
        p = e + 1; }
    return ""; }

// 事件名 → 角色码（1..6；0 = 未知/缺失）
fn hit_role_code(name: string) -> int {
    if str_eq(name, "dst") != 0 { return HIT_ROLE_DST; }
    if str_eq(name, "src1") != 0 { return HIT_ROLE_SRC1; }
    if str_eq(name, "src2") != 0 { return HIT_ROLE_SRC2; }
    if str_eq(name, "addr") != 0 { return HIT_ROLE_ADDR; }
    if str_eq(name, "val") != 0 { return HIT_ROLE_VAL; }
    if str_eq(name, "cond") != 0 { return HIT_ROLE_COND; }
    return 0; }

// 寄存器名 → regno（0..15）；非寄存器名 → -1
fn hit_reg_code(name: string) -> int {
    if str_eq(name, "rax") != 0 { return 0; }
    if str_eq(name, "rcx") != 0 { return 1; }
    if str_eq(name, "rdx") != 0 { return 2; }
    if str_eq(name, "rbx") != 0 { return 3; }
    if str_eq(name, "rsp") != 0 { return 4; }
    if str_eq(name, "rbp") != 0 { return 5; }
    if str_eq(name, "rsi") != 0 { return 6; }
    if str_eq(name, "rdi") != 0 { return 7; }
    if str_eq(name, "r8") != 0 { return 8; }
    if str_eq(name, "r9") != 0 { return 9; }
    if str_eq(name, "r10") != 0 { return 10; }
    if str_eq(name, "r11") != 0 { return 11; }
    if str_eq(name, "r12") != 0 { return 12; }
    if str_eq(name, "r13") != 0 { return 13; }
    if str_eq(name, "r14") != 0 { return 14; }
    if str_eq(name, "r15") != 0 { return 15; }
    return -1; }

// 操作数码：角色 1..6 或寄存器字面量 16+regno；0 = 未知
fn hit_operand_code(name: string) -> int {
    rc := hit_role_code(name);
    if rc != 0 { return rc; }
    rn := hit_reg_code(name);
    if rn >= 0 { return HIT_REG_BASE + rn; }
    return 0; }

// base 键码：操作数码或 rip（32）；0 = 未知
fn hit_base_code(name: string) -> int {
    oc := hit_operand_code(name);
    if oc != 0 { return oc; }
    if str_eq(name, "rip") != 0 { return HIT_CODE_RIP; }
    return 0; }

// 2^n（按位或不存在，倍增）
fn hit_bit(n: int) -> int {
    b : int, mut = 1;
    i : int, mut = 0;
    loop {
        if i >= n { break; }
        b = b * 2;
        i = i + 1; }
    return b; }

fn hit_err_ev(ev_id: int) {
    print("error: HIT table: event "); print_i(ev_id); print(": "); }

fn hit_err_step(ev_id: int, step_no: int) {
    print("error: HIT table: event "); print_i(ev_id); print(" step "); print_i(step_no); print(": "); }

// ════════════════════════════════════════════════════════════════
// schema v2 步字段解析（模板语言核心）
// ════════════════════════════════════════════════════════════════
// text = 一个 [[event.proj.step]] 小节全文（或 v1 平铺投影的 proj 层文本——
// isa_ok = 1 时允许 isa 键混于其中）。解析成功 → 追加一条 108B 步记录。
// Returns 0 = 成功；1 = 失败（错误已打印）。
fn hit_parse_step(text: string, ev_id: int, step_no: int, isa_ok: int) -> int {
    if isa_ok == 1 {
        if hit_scan_keys_ok(text, "isa prefix opcode rex_w rex_r rex_x rex_b modrm_reg_role modrm_reg_digit modrm_rm_role rm_mode modrm_base_role sib_scale sib_index_role sib_base_role disp_size disp_src imm_size imm_role imm_lit imm_kind rel_role rel_kind rel_size cond_role") != 0 { return 1; }
    } else {
        if hit_scan_keys_ok(text, "prefix opcode rex_w rex_r rex_x rex_b modrm_reg_role modrm_reg_digit modrm_rm_role rm_mode modrm_base_role sib_scale sib_index_role sib_base_role disp_size disp_src imm_size imm_role imm_lit imm_kind rel_role rel_kind rel_size cond_role") != 0 { return 1; }
    }
    // ── 输出记录字段（函数顶给默认值；各组按需覆盖）──
    op0 : int, mut = 0;   op1 : int, mut = 0;
    reg_code : int, mut = 0;  is_digit : int, mut = 0;  digit_val : int, mut = 0;
    rm_code : int, mut = 0;   rm_mode : int, mut = 0;
    base_code : int, mut = 0; scl_val : int, mut = 0;  idx_code : int, mut = 0;
    dsz_code : int, mut = 0;  dsrc_code : int, mut = 0;
    isz_val : int, mut = 0;   iro_code : int, mut = 0; ik_val : int, mut = 0;  ilit_val : int, mut = 0;
    rro_code : int, mut = 0;  rk_val : int, mut = 0;   rs_val : int, mut = 0;
    cond_code : int, mut = 0;
    rex_byte : int, mut = 0;  npf : int, mut = 0;
    pfx0 : int, mut = 0;  pfx1 : int, mut = 0;
    // ── rex 位（出现则须 0/1；任一出现且值 1 才产生 REX 字节）──
    rwp := hit_has_key(text, "rex_w");
    rrp := hit_has_key(text, "rex_r");
    rxp := hit_has_key(text, "rex_x");
    rbp := hit_has_key(text, "rex_b");
    rw : int, mut = 0;  rr : int, mut = 0;  rx : int, mut = 0;  rb : int, mut = 0;
    if rwp == 1 { rw = toml_get_int(text, "rex_w"); }
    if rrp == 1 { rr = toml_get_int(text, "rex_r"); }
    if rxp == 1 { rx = toml_get_int(text, "rex_x"); }
    if rbp == 1 { rb = toml_get_int(text, "rex_b"); }
    if rwp == 1 && (rw < 0 || rw > 1) { hit_err_step(ev_id, step_no); println("bad rex bit"); return 1; }
    if rrp == 1 && (rr < 0 || rr > 1) { hit_err_step(ev_id, step_no); println("bad rex bit"); return 1; }
    if rxp == 1 && (rx < 0 || rx > 1) { hit_err_step(ev_id, step_no); println("bad rex bit"); return 1; }
    if rbp == 1 && (rb < 0 || rb > 1) { hit_err_step(ev_id, step_no); println("bad rex bit"); return 1; }
    if (rwp == 1 && rw == 1) || (rrp == 1 && rr == 1) ||
       (rxp == 1 && rx == 1) || (rbp == 1 && rb == 1) {
        rex_byte = 0x40;
        if rwp == 1 && rw == 1 { rex_byte = rex_byte + 8; }
        if rrp == 1 && rr == 1 { rex_byte = rex_byte + 4; }
        if rxp == 1 && rx == 1 { rex_byte = rex_byte + 2; }
        if rbp == 1 && rb == 1 { rex_byte = rex_byte + 1; }
    }
    // ── prefix（≤2 字节；每字节 ≤255）──
    if hit_has_key(text, "prefix") == 1 {
        pfb := alloc(16);
        npf = toml_get_int_list(text, "prefix", pfb, 3);
        if npf < 0 {
            hit_err_step(ev_id, step_no); println("prefix missing/malformed");
            return 1; }
        if npf > 2 {
            hit_err_step(ev_id, step_no); println("prefix >2 bytes");
            return 1; }
        j : int, mut = 0;
        loop {
            if j >= npf { break; }
            if hit_r32(pfb, j * 4) > 255 {
                hit_err_step(ev_id, step_no); println("prefix byte >255 (not a byte)");
                return 1; }
            j = j + 1; }
        if npf >= 1 { pfx0 = hit_r32(pfb, 0); }
        if npf >= 2 { pfx1 = hit_r32(pfb, 4); }
    }
    // ── opcode（必选，1..3 字节；每字节 ≤255）──
    opc_p := hit_has_key(text, "opcode");
    opb := alloc(16);
    nop := toml_get_int_list(text, "opcode", opb, 4);
    if opc_p == 0 || nop < 1 {
        hit_err_step(ev_id, step_no); println("opcode missing/malformed");
        return 1; }
    if nop > 3 {
        hit_err_step(ev_id, step_no); println("opcode >3 bytes");
        return 1; }
    j : int, mut = 0;
    loop {
        if j >= nop { break; }
        if hit_r32(opb, j * 4) > 255 {
            hit_err_step(ev_id, step_no); println("opcode byte >255 (not a byte)");
            return 1; }
        j = j + 1; }
    // ── modrm 族关联校验（键出现才算族；各组字段按需自校验）──
    h_role  := hit_has_key(text, "modrm_reg_role");
    h_digit := hit_has_key(text, "modrm_reg_digit");
    h_rm    := hit_has_key(text, "modrm_rm_role");
    h_mode  := hit_has_key(text, "rm_mode");
    h_base  := hit_has_key(text, "modrm_base_role");
    h_scl   := hit_has_key(text, "sib_scale");
    h_sidx  := hit_has_key(text, "sib_index_role");
    h_sbas  := hit_has_key(text, "sib_base_role");
    h_dsz   := hit_has_key(text, "disp_size");
    h_dsrc  := hit_has_key(text, "disp_src");
    grp := h_role + h_digit + h_rm + h_mode + h_base + h_scl + h_sidx + h_sbas + h_dsz + h_dsrc;
    if grp > 0 {
        if h_role == 1 && h_digit == 1 {
            hit_err_step(ev_id, step_no); println("modrm reg role and digit both present");
            return 1; }
        if h_role == 0 && h_digit == 0 {
            hit_err_step(ev_id, step_no); println("modrm reg role/digit missing");
            return 1; }
        if h_role == 1 {
            reg_code = hit_operand_code(toml_get_str(text, "modrm_reg_role"));
            if reg_code == 0 {
                hit_err_step(ev_id, step_no); println("unknown modrm role");
                return 1; }
        } else {
            digit_val = toml_get_int(text, "modrm_reg_digit");
            if digit_val < 0 || digit_val > 7 {
                hit_err_step(ev_id, step_no); println("bad reg digit");
                return 1; }
            is_digit = 1;
        }
        if h_rm == 0 {
            hit_err_step(ev_id, step_no); println("modrm rm role missing");
            return 1; }
        rm_code = hit_operand_code(toml_get_str(text, "modrm_rm_role"));
        if rm_code == 0 {
            hit_err_step(ev_id, step_no); println("unknown modrm role");
            return 1; }
        if h_mode == 1 {
            rm_mode = toml_get_int(text, "rm_mode");
            if rm_mode < 0 || rm_mode > 2 {
                hit_err_step(ev_id, step_no); println("bad rm_mode");
                return 1; }
        }
        if h_scl + h_sidx + h_sbas > 0 && rm_mode != 2 {
            hit_err_step(ev_id, step_no); println("sib fields need rm_mode 2");
            return 1; }
        if rm_mode == 2 && (h_scl == 0 || h_sbas == 0) {
            hit_err_step(ev_id, step_no); println("rm_mode 2 needs sib_scale and sib_base_role");
            return 1; }
        if h_base == 1 && rm_mode == 0 {
            hit_err_step(ev_id, step_no); println("modrm_base_role needs rm_mode 1/2");
            return 1; }
        if h_base == 1 && rm_mode == 1 {
            base_code = hit_base_code(toml_get_str(text, "modrm_base_role"));
            if base_code == 0 {
                hit_err_step(ev_id, step_no); println("bad modrm_base_role");
                return 1; }
        }
        if (h_dsz + h_dsrc > 0) && rm_mode == 0 {
            hit_err_step(ev_id, step_no); println("disp needs rm_mode 1/2");
            return 1; }
        if rm_mode == 2 {
            scl_val = toml_get_int(text, "sib_scale");
            if scl_val < 0 || scl_val > 3 {
                hit_err_step(ev_id, step_no); println("bad sib_scale");
                return 1; }
            if h_sidx == 1 {
                idx_code = hit_operand_code(toml_get_str(text, "sib_index_role"));
                if idx_code == 0 {
                    hit_err_step(ev_id, step_no); println("bad sib_index_role");
                    return 1; }
            }
            base_code = hit_base_code(toml_get_str(text, "sib_base_role"));
            if base_code == 0 {
                hit_err_step(ev_id, step_no); println("bad sib_base_role");
                return 1; }
        }
        if h_dsz == 1 {
            dv := hit_raw_str(text, "disp_size");
            if str_len(dv) >= 2 && load8(dv, 0) == 34 && load8(dv, str_len(dv) - 1) == 34 {
                dv = str_sub(dv, 1, str_len(dv) - 2); }
            dv_ok : int, mut = 0;
            if str_eq(dv, "auto") != 0 { dsz_code = 0; dv_ok = 1; }
            if str_eq(dv, "1") != 0 { dsz_code = 1; dv_ok = 1; }
            if str_eq(dv, "4") != 0 { dsz_code = 4; dv_ok = 1; }
            if dv_ok == 0 {
                hit_err_step(ev_id, step_no); println("bad disp_size");
                return 1; }
        }
        if h_dsrc == 1 {
            dsrc_code = hit_operand_code(toml_get_str(text, "disp_src"));
            if dsrc_code == 0 {
                hit_err_step(ev_id, step_no); println("bad disp_src");
                return 1; }
        }
    }
    // ── imm 族（与 modrm 族无关：字面量/回填载体）──
    h_isz  := hit_has_key(text, "imm_size");
    h_iro  := hit_has_key(text, "imm_role");
    h_ik   := hit_has_key(text, "imm_kind");
    h_ilit := hit_has_key(text, "imm_lit");
    if h_isz == 1 {
        isz_val = toml_get_int(text, "imm_size");
        if isz_val != 1 && isz_val != 2 && isz_val != 4 && isz_val != 8 {
            hit_err_step(ev_id, step_no); println("bad imm_size");
            return 1; }
        if h_iro == 0 && h_ik == 0 {
            hit_err_step(ev_id, step_no); println("imm_size without imm_role/imm_kind");
            return 1; }
    }
    if h_iro == 1 {
        inm := toml_get_str(text, "imm_role");
        if str_eq(inm, "lit") != 0 { iro_code = HIT_CODE_LIT; }
        else {
            iro_code = hit_operand_code(inm);
            if iro_code == 0 {
                hit_err_step(ev_id, step_no); println("bad imm_role");
                return 1; }
        }
    }
    if h_ik == 1 {
        if str_eq(toml_get_str(text, "imm_kind"), "fnaddr") == 0 {
            hit_err_step(ev_id, step_no); println("bad imm_kind");
            return 1; }
        if h_isz == 0 || isz_val != 8 {
            hit_err_step(ev_id, step_no); println("imm_kind fnaddr needs imm_size 8");
            return 1; }
        ik_val = HIT_IMM_FNADDR;
    }
    if h_ilit == 1 {
        ilit_val = toml_get_int(text, "imm_lit");
        if ilit_val < 0 {
            hit_err_step(ev_id, step_no); println("bad imm_lit (negative unsupported)");
            return 1; }
    }
    // ── rel 族（三字段同现；kind = event/func/extern；size = 8/32）──
    h_rro := hit_has_key(text, "rel_role");
    h_rk  := hit_has_key(text, "rel_kind");
    h_rs  := hit_has_key(text, "rel_size");
    if h_rro + h_rk + h_rs > 0 {
        if h_rro == 0 || h_rk == 0 || h_rs == 0 {
            hit_err_step(ev_id, step_no); println("rel fields incomplete (role/kind/size)");
            return 1; }
        rkn := toml_get_str(text, "rel_kind");
        if str_eq(rkn, "event") == 0 && str_eq(rkn, "func") == 0 && str_eq(rkn, "extern") == 0 {
            hit_err_step(ev_id, step_no); println("bad rel kind");
            return 1; }
        if str_eq(rkn, "event") != 0 { rk_val = HIT_REL_EVENT; }
        if str_eq(rkn, "func") != 0 { rk_val = HIT_REL_FUNC; }
        if str_eq(rkn, "extern") != 0 { rk_val = HIT_REL_EXTERN; }
        rs_val = toml_get_int(text, "rel_size");
        if rs_val != 8 && rs_val != 32 {
            hit_err_step(ev_id, step_no); println("bad rel size");
            return 1; }
        rro_code = hit_operand_code(toml_get_str(text, "rel_role"));
        if rro_code == 0 {
            hit_err_step(ev_id, step_no); println("bad rel role");
            return 1; }
    }
    // ── cond 键（branch 条件源槽）──
    if hit_has_key(text, "cond_role") == 1 {
        cond_code = hit_operand_code(toml_get_str(text, "cond_role"));
        if cond_code == 0 {
            hit_err_step(ev_id, step_no); println("bad cond_role");
            return 1; }
    }
    // ── 字节流组装（prefix → REX → opcode）+ 追加 108B 步记录 ──
    stb := alloc(8);
    nst : int, mut = 0;
    if npf >= 1 { store8(stb, nst, pfx0); nst = nst + 1; }
    if npf >= 2 { store8(stb, nst, pfx1); nst = nst + 1; }
    if rex_byte != 0 { store8(stb, nst, rex_byte); nst = nst + 1; }
    j = 0;
    loop {
        if j >= nop { break; }
        store8(stb, nst, hit_r32(opb, j * 4));
        nst = nst + 1;
        j = j + 1; }
    if nst > 0 { op0 = load8(stb, 0); }
    if nst > 1 { op1 = load8(stb, 1); }
    hit_grow_steps(g_hit_step_count + 1);
    sb := g_hit_step_count * HIT_STEP_REC;
    g_hit_step_count = g_hit_step_count + 1;
    hit_zero_bytes(g_hit_steps, sb, HIT_STEP_REC);
    hit_w32(g_hit_steps, sb + HIT_ST_OFF_OP0, op0);
    hit_w32(g_hit_steps, sb + HIT_ST_OFF_OP1, op1);
    hit_w32(g_hit_steps, sb + HIT_ST_OFF_REG_ROLE, reg_code);
    hit_w32(g_hit_steps, sb + HIT_ST_OFF_RM_ROLE, rm_code);
    hit_w32(g_hit_steps, sb + HIT_ST_OFF_RM_MODE, rm_mode);
    hit_w32(g_hit_steps, sb + HIT_ST_OFF_PFX0, pfx0);
    hit_w32(g_hit_steps, sb + HIT_ST_OFF_PFX1, pfx1);
    hit_w32(g_hit_steps, sb + HIT_ST_OFF_REX, rex_byte);
    hit_w32(g_hit_steps, sb + HIT_ST_OFF_OPB0, hit_r32(opb, 0));
    hit_w32(g_hit_steps, sb + HIT_ST_OFF_OPB1, hit_r32(opb, 4));
    hit_w32(g_hit_steps, sb + HIT_ST_OFF_OPB2, hit_r32(opb, 8));
    hit_w32(g_hit_steps, sb + HIT_ST_OFF_OPN, nop);
    hit_w32(g_hit_steps, sb + HIT_ST_OFF_REG_IS_DIGIT, is_digit);
    hit_w32(g_hit_steps, sb + HIT_ST_OFF_REG_DIGIT, digit_val);
    hit_w32(g_hit_steps, sb + HIT_ST_OFF_BASE_ROLE, base_code);
    hit_w32(g_hit_steps, sb + HIT_ST_OFF_SIB_SCALE, scl_val);
    hit_w32(g_hit_steps, sb + HIT_ST_OFF_SIB_INDEX, idx_code);
    hit_w32(g_hit_steps, sb + HIT_ST_OFF_DISP_SIZE, dsz_code);
    hit_w32(g_hit_steps, sb + HIT_ST_OFF_DISP_SRC, dsrc_code);
    hit_w32(g_hit_steps, sb + HIT_ST_OFF_IMM_SIZE, isz_val);
    hit_w32(g_hit_steps, sb + HIT_ST_OFF_IMM_ROLE, iro_code);
    hit_w32(g_hit_steps, sb + HIT_ST_OFF_IMM_KIND, ik_val);
    hit_w32(g_hit_steps, sb + HIT_ST_OFF_IMM_LIT, ilit_val);
    hit_w32(g_hit_steps, sb + HIT_ST_OFF_REL_ROLE, rro_code);
    hit_w32(g_hit_steps, sb + HIT_ST_OFF_REL_KIND, rk_val);
    hit_w32(g_hit_steps, sb + HIT_ST_OFF_REL_SIZE, rs_val);
    hit_w32(g_hit_steps, sb + HIT_ST_OFF_COND_ROLE, cond_code);
    return 0; }

// ════════════════════════════════════════════════════════════════
// [[event.proj]] 投影小节解析（chunk 内 ph 处起；多步/平铺两形）
// ════════════════════════════════════════════════════════════════
// Returns 0 = 成功；1 = 失败（错误已打印）。
fn hit_parse_proj_section(chunk: string, ph: int, ev_id: int) -> int {
    pl := hit_line_after(chunk, ph);
    // 本投影文本终点：平铺 = 下一 [[event.proj]]（或块尾）；步小节形 = 首步头
    //（步头位于下一 proj 头之前才算本投影的步小节——防跨 proj 误配）
    nxt_pr := hit_find_tag(chunk, pl, "[[event.proj]]");
    st_hdr := hit_find_tag(chunk, pl, "[[event.proj.step]]");
    sectioned : int, mut = 0;
    pend : int, mut = str_len(chunk);
    if st_hdr >= 0 && (nxt_pr < 0 || st_hdr < nxt_pr) {
        sectioned = 1;
        pend = st_hdr; }
    else if nxt_pr >= 0 {
        pend = nxt_pr; }
    pfields := str_sub(chunk, pl, pend - pl);
    // isa 必选且须为 x86-64（层级无关：平铺时 isa 混于步字段）
    if str_eq(toml_get_str(pfields, "isa"), "x86-64") == 0 {
        hit_err_ev(ev_id); println("unknown isa");
        return 1; }
    first_step := g_hit_step_count;
    scnt : int, mut = 0;
    if sectioned == 0 {
        // 平铺单步（v1 子集：isa 之外的字段 = 单步字段；白名单扫 = 步层全表）
        if hit_parse_step(pfields, ev_id, 0, 1) != 0 { return 1; }
        scnt = 1; }
    else {
        if hit_scan_keys_ok(pfields, "isa") != 0 { return 1; }
        // 步小节逐个解析（步文本终点 = 下一 step 头 / 下一 proj 头 / 块尾）
        sp : int, mut = st_hdr;
        loop {
            if sp < 0 { break; }
            sl := hit_line_after(chunk, sp);
            ns := hit_find_tag(chunk, sl, "[[event.proj.step]]");
            np2 := hit_find_tag(chunk, sl, "[[event.proj]]");
            send : int, mut = str_len(chunk);
            if ns >= 0 && ns < send { send = ns; }
            if np2 >= 0 && np2 < send { send = np2; }
            stext := str_sub(chunk, sl, send - sl);
            if hit_parse_step(stext, ev_id, scnt, 0) != 0 { return 1; }
            scnt = scnt + 1;
            // 续行边界（Task 1 评审 fix）：ns 在下一 proj 头之后 = 属于后续
            // [[event.proj]] 的步小节——不得续入本投影（np2 只截步文本、不
            // 终止循环；旧缺陷 = 静默吸收后续投影步：本投影步数膨胀 + 步
            // 记录重复入库，多 proj 步小节事件加载成功但表已错）
            if ns >= 0 && (np2 < 0 || ns < np2) { sp = ns; }
            else { sp = -1; } }
        if scnt == 0 {
            hit_err_ev(ev_id); println("projection has no steps");
            return 1; }
    }
    // 追加投影记录（isa/步数/首步字节偏移）
    hit_grow_projs(g_hit_proj_count + 1);
    ps := g_hit_proj_count;
    g_hit_proj_count = ps + 1;
    hit_w32(g_hit_projs, ps * HIT_PROJ_REC + HIT_PJ_OFF_ISA, HIT_ISA_X86);
    hit_w32(g_hit_projs, ps * HIT_PROJ_REC + HIT_PJ_OFF_STEP_COUNT, scnt);
    hit_w32(g_hit_projs, ps * HIT_PROJ_REC + HIT_PJ_OFF_STEP_OFF, first_step * HIT_STEP_REC);
    return 0; }

// ════════════════════════════════════════════════════════════════
// [[event]] 事件小节解析（含其全部投影小节）
// ════════════════════════════════════════════════════════════════
// chunk = 自 "[[event]]" 行起、到下个节头前的文本（不含下一节）。
// Returns 0 = 成功；1 = 失败（错误已打印）。
fn hit_parse_event_chunk(chunk: string) -> int {
    // 事件字段区 = 头行后、首个 proj/step 小节前（step 在 proj 前 = 结构错）
    fe := hit_line_after(chunk, 0);
    p_off := hit_find_tag(chunk, fe, "[[event.proj]]");
    s_off := hit_find_tag(chunk, fe, "[[event.proj.step]]");
    if s_off >= 0 && (p_off < 0 || s_off < p_off) {
        println("error: HIT table: stray [[event.proj.step]] before [[event.proj]]");
        return 1; }
    fend : int, mut = str_len(chunk);
    if p_off >= 0 && p_off < fend { fend = p_off; }
    if s_off >= 0 && s_off < fend { fend = s_off; }
    ev_text := str_sub(chunk, fe, fend - fe);
    if hit_scan_keys_ok(ev_text, "id name arith inputs outputs side_effect") != 0 { return 1; }
    id := toml_get_int(ev_text, "id");
    if id <= 0 {
        println("error: HIT table: event missing or invalid id");
        return 1; }
    // 重复 id 检测
    k : int, mut = 0;
    loop {
        if k >= g_hit_event_count { break; }
        if hit_r32(g_hit_events, k * HIT_EVENT_REC + HIT_EV_OFF_ID) == id {
            print("error: HIT table: duplicate event id "); print_i(id); println("");
            return 1; }
        k = k + 1; }
    name := toml_get_str(ev_text, "name");
    if str_len(name) == 0 {
        hit_err_ev(id); println("missing name");
        return 1; }
    inputs := toml_get_int(ev_text, "inputs");
    outputs := toml_get_int(ev_text, "outputs");
    se := toml_get_str(ev_text, "side_effect");
    side : int, mut = -1;
    if str_eq(se, "pure") != 0 { side = HIT_SIDE_PURE; }
    if str_eq(se, "effect") != 0 { side = HIT_SIDE_EFFECT; }
    if side < 0 {
        hit_err_ev(id); println("bad side_effect");
        return 1; }
    // 名字入名字表（8B/项存串指针；str_sub 副本 arena 存活）
    hit_grow_names(g_hit_name_count + 1);
    name_ni : int, mut = g_hit_name_count;
    g_hit_name_count = name_ni + 1;
    store_str_ptr(g_hit_names, name_ni * 8, name);
    // 事件行追加（proj 范围字段在投影解析后回填）
    hit_grow_events(g_hit_event_count + 1);
    slot := g_hit_event_count;
    g_hit_event_count = slot + 1;
    hit_zero_bytes(g_hit_events, slot * HIT_EVENT_REC, HIT_EVENT_REC);
    hit_w32(g_hit_events, slot * HIT_EVENT_REC + HIT_EV_OFF_ID, id);
    hit_w32(g_hit_events, slot * HIT_EVENT_REC + HIT_EV_OFF_NAME, name_ni);
    hit_w32(g_hit_events, slot * HIT_EVENT_REC + HIT_EV_OFF_INPUTS, inputs);
    hit_w32(g_hit_events, slot * HIT_EVENT_REC + HIT_EV_OFF_OUTPUTS, outputs);
    hit_w32(g_hit_events, slot * HIT_EVENT_REC + HIT_EV_OFF_SIDE, side);
    // 投影小节（多 proj：事件 32/36 记范围；20/24/28 = proj0 镜像）
    first_proj : int, mut = g_hit_proj_count;
    pcount : int, mut = 0;
    hpos : int, mut = fend;
    loop {
        ph := hit_find_tag(chunk, hpos, "[[event.proj]]");
        if ph < 0 { break; }
        pcount = pcount + 1;
        if hit_parse_proj_section(chunk, ph, id) != 0 { return 1; }
        hpos = ph + 1; }
    if pcount == 0 {
        hit_err_ev(id); println("missing [[event.proj]]");
        return 1; }
    hit_w32(g_hit_events, slot * HIT_EVENT_REC + HIT_EV_OFF_PROJ_OFF, first_proj);
    hit_w32(g_hit_events, slot * HIT_EVENT_REC + HIT_EV_OFF_PROJ_COUNT, pcount);
    // proj0 镜像（M1 消费方视区：isa/步数/首步字节偏移）
    p0 := first_proj * HIT_PROJ_REC;
    hit_w32(g_hit_events, slot * HIT_EVENT_REC + HIT_EV_OFF_ISA,
           hit_r32(g_hit_projs, p0 + HIT_PJ_OFF_ISA));
    hit_w32(g_hit_events, slot * HIT_EVENT_REC + HIT_EV_OFF_STEP_COUNT,
           hit_r32(g_hit_projs, p0 + HIT_PJ_OFF_STEP_COUNT));
    hit_w32(g_hit_events, slot * HIT_EVENT_REC + HIT_EV_OFF_STEP_OFF,
           hit_r32(g_hit_projs, p0 + HIT_PJ_OFF_STEP_OFF));
    return 0; }

// ════════════════════════════════════════════════════════════════
// [runtime.x86] 运行时小节（spec §6 最小描述；可选小节，出现则 8 键齐备）
// ════════════════════════════════════════════════════════════════
// chunk = 自 "[runtime.x86]" 行起、到下个节头前的文本（不含下一节）。
// Returns 0 = 成功；1 = 失败（错误已打印）。
fn hit_parse_runtime_chunk(chunk: string) -> int {
    fe := hit_line_after(chunk, 0);
    text := str_sub(chunk, fe, str_len(chunk) - fe);
    if hit_scan_keys_ok(text, "call_mechanism call_ret_addr call_stack_grow param_mode param_regs save_regs extern_entry extern_resolve") != 0 { return 1; }
    // 8 键齐备
    if hit_has_key(text, "call_mechanism") == 0 { println("error: HIT table: runtime section missing call_mechanism"); return 1; }
    if hit_has_key(text, "call_ret_addr") == 0 { println("error: HIT table: runtime section missing call_ret_addr"); return 1; }
    if hit_has_key(text, "call_stack_grow") == 0 { println("error: HIT table: runtime section missing call_stack_grow"); return 1; }
    if hit_has_key(text, "param_mode") == 0 { println("error: HIT table: runtime section missing param_mode"); return 1; }
    if hit_has_key(text, "param_regs") == 0 { println("error: HIT table: runtime section missing param_regs"); return 1; }
    if hit_has_key(text, "save_regs") == 0 { println("error: HIT table: runtime section missing save_regs"); return 1; }
    if hit_has_key(text, "extern_entry") == 0 { println("error: HIT table: runtime section missing extern_entry"); return 1; }
    if hit_has_key(text, "extern_resolve") == 0 { println("error: HIT table: runtime section missing extern_resolve"); return 1; }
    rt := alloc(32);
    // 机制枚举值（非 stack/pushed/down/regs/call_rel32/ext_rel → 拒）
    if str_eq(toml_get_str(text, "call_mechanism"), "stack") == 0 {
        println("error: HIT table: bad call_mechanism");
        return 1; }
    hit_w32(rt, HIT_RT_CALL_MECHANISM * 4, 1);
    if str_eq(toml_get_str(text, "call_ret_addr"), "pushed") == 0 {
        println("error: HIT table: bad call_ret_addr");
        return 1; }
    hit_w32(rt, HIT_RT_CALL_RET_ADDR * 4, 1);
    if str_eq(toml_get_str(text, "call_stack_grow"), "down") == 0 {
        println("error: HIT table: bad call_stack_grow");
        return 1; }
    hit_w32(rt, HIT_RT_CALL_STACK_GROW * 4, 1);
    pm := toml_get_str(text, "param_mode");
    if str_eq(pm, "regs") == 0 && str_eq(pm, "stack") == 0 {
        println("error: HIT table: bad param_mode");
        return 1; }
    if str_eq(pm, "regs") != 0 { hit_w32(rt, HIT_RT_PARAM_MODE * 4, 1); }
    if str_eq(pm, "stack") != 0 { hit_w32(rt, HIT_RT_PARAM_MODE * 4, 2); }
    if str_eq(toml_get_str(text, "extern_entry"), "call_rel32") == 0 {
        println("error: HIT table: bad extern_entry");
        return 1; }
    hit_w32(rt, HIT_RT_EXTERN_ENTRY * 4, 1);
    if str_eq(toml_get_str(text, "extern_resolve"), "ext_rel") == 0 {
        println("error: HIT table: bad extern_resolve");
        return 1; }
    hit_w32(rt, HIT_RT_EXTERN_RESOLVE * 4, 1);
    // 寄存器掩码（空格分隔寄存器名 → regno 位集）
    if hit_parse_reg_mask(toml_get_str(text, "param_regs"), rt, HIT_RT_PARAM_MASK * 4) != 0 { return 1; }
    if hit_parse_reg_mask(toml_get_str(text, "save_regs"), rt, HIT_RT_SAVE_MASK * 4) != 0 { return 1; }
    g_hit_runtime = rt;
    g_hit_runtime_present = 1;
    return 0; }

// 寄存器掩码解析（空格分隔名列表 → 位掩码写 rt+pos）；0 = 成功；1 = 未知名（已打印）
fn hit_parse_reg_mask(raw: string, rt: string, pos: int) -> int {
    rlen := str_len(raw);
    mask : int, mut = 0;
    p : int, mut = 0;
    loop {
        if p >= rlen { break; }
        loop {
            if p >= rlen { break; }
            if load8(raw, p) == 32 { p = p + 1; } else { break; } }
        if p >= rlen { break; }
        e : int, mut = p;
        loop {
            if e >= rlen { break; }
            if load8(raw, e) == 32 { break; }
            e = e + 1; }
        rn := hit_reg_code(str_sub(raw, p, e - p));
        if rn < 0 {
            print("error: HIT table: runtime unknown register '");
            print(str_sub(raw, p, e - p)); println("'");
            return 1; }
        mask = mask + hit_bit(rn);
        p = e; }
    hit_w32(rt, pos, mask);
    return 0; }

// ════════════════════════════════════════════════════════════════
// 公共接口（M1 Task 1 契约 + M2a Task 1 扩展）
// ════════════════════════════════════════════════════════════════

// 加载 HIT 表文件并填充 g_hit_events/g_hit_projs/g_hit_steps（计数式重置——
// 重复调用覆盖旧表）。[[event]] 与 [runtime.x86] 小节按出现序任意交错解析
//（runtime 可夹在事件间，尾部追加事件亦可）。Returns 0 = 成功；1 = 失败
//（错误已打印，表不可用）。
fn load_hit_table(path: string) -> int {
    content := read_file(path);
    if str_len(content) == 0 {
        print("error: cannot open HIT table: "); println(path);
        return 1; }
    g_hit_event_count = 0;
    g_hit_step_count = 0;
    g_hit_proj_count = 0;
    g_hit_name_count = 0;
    g_hit_runtime_present = 0;
    expected := toml_get_int(content, "events");  // [table] events（缺省 0 → 尾部校验兜底）
    pos : int, mut = 0;
    loop {
        ev := hit_find_tag(content, pos, "[[event]]");
        rt := hit_find_tag(content, pos, "[runtime.x86]");
        if ev < 0 && rt < 0 { break; }
        if ev < 0 || (rt >= 0 && rt < ev) {
            // [runtime.x86] 小节：到下一 [[event]] / 再一 runtime 头 / EOF 为止
            end : int, mut = str_len(content);
            e2 := hit_find_tag(content, rt + 1, "[[event]]");
            r2 := hit_find_tag(content, rt + 1, "[runtime.x86]");
            if e2 >= 0 && e2 < end { end = e2; }
            if r2 >= 0 && r2 < end { end = r2; }
            chunk := str_sub(content, rt, end - rt);
            if hit_parse_runtime_chunk(chunk) != 0 { return 1; }
            pos = end; }
        else {
            end : int, mut = str_len(content);
            e2 := hit_find_tag(content, ev + 1, "[[event]]");
            r2 := hit_find_tag(content, ev + 1, "[runtime.x86]");
            if e2 >= 0 && e2 < end { end = e2; }
            if r2 >= 0 && r2 < end { end = r2; }
            chunk := str_sub(content, ev, end - ev);
            if hit_parse_event_chunk(chunk) != 0 { return 1; }
            pos = end; } }
    if g_hit_event_count == 0 {
        println("error: HIT table: no [[event]] sections");
        return 1; }
    // 注（M2a Task 1 评审记录）：spec §2「运行时核事件 id 1-9 每表必具」与验证项
    // 「缺事件…拒绝」的加载器强制在场检查暂缓——事件绑定 = Task 4 落地（届时
    // 消费方按 id 查找自然暴露缺失），此处仅拦零事件与 [table] events 计数不符。
    if g_hit_event_count != expected {
        print("error: HIT table: [table] events="); print_i(expected);
        print(" parsed="); print_i(g_hit_event_count); println(" mismatch");
        return 1; }
    return 0; }

// 表模式激活态：加载成功（g_hit_event_count > 0）= 发射循环启用表优先
fn hit_table_active() -> int {
    if g_hit_event_count > 0 { return 1; }
    return 0; }

// 事件 id → 事件槽（记录下标）；-1 = 无
fn hit_event_lookup(id: int) -> int {
    i : int, mut = 0;
    loop {
        if i >= g_hit_event_count { break; }
        if hit_r32(g_hit_events, i * HIT_EVENT_REC + HIT_EV_OFF_ID) == id { return i; }
        i = i + 1; }
    return -1; }

// 事件名（诊断用；g_hit_names 表取串）
fn hit_event_name(slot: int) -> string {
    if slot < 0 || slot >= g_hit_event_count { return ""; }
    ni := hit_r32(g_hit_events, slot * HIT_EVENT_REC + HIT_EV_OFF_NAME);
    if ni < 0 || ni >= g_hit_name_count { return ""; }
    return load_str_ptr(g_hit_names, ni * 8); }

// 事件投影形态数；-1 = 事件槽非法
fn hit_proj_count(event_slot: int) -> int {
    if event_slot < 0 || event_slot >= g_hit_event_count { return -1; }
    return hit_r32(g_hit_events, event_slot * HIT_EVENT_REC + HIT_EV_OFF_PROJ_COUNT); }

// 事件第 proj_i 投影步数；-1 = 越界
fn hit_proj_step_count(event_slot: int, proj_i: int) -> int {
    if event_slot < 0 || event_slot >= g_hit_event_count { return -1; }
    po := hit_r32(g_hit_events, event_slot * HIT_EVENT_REC + HIT_EV_OFF_PROJ_OFF);
    pc := hit_r32(g_hit_events, event_slot * HIT_EVENT_REC + HIT_EV_OFF_PROJ_COUNT);
    if proj_i < 0 || proj_i >= pc { return -1; }
    return hit_r32(g_hit_projs, (po + proj_i) * HIT_PROJ_REC + HIT_PJ_OFF_STEP_COUNT); }

// 取事件第 proj_i 投影第 step_i 步：把该步 108B v2 记录原样复制到 out
//（字段布局 = 上方 HIT_ST_OFF_* 常量序；调用方保证 ≥108B）。
// Returns 0 = 成功；-1 = 事件槽/proj/步号非法。
fn hit_proj_step_get(event_slot: int, proj_i: int, step_i: int, out: string) -> int {
    if event_slot < 0 || event_slot >= g_hit_event_count { return -1; }
    po := hit_r32(g_hit_events, event_slot * HIT_EVENT_REC + HIT_EV_OFF_PROJ_OFF);
    pc := hit_r32(g_hit_events, event_slot * HIT_EVENT_REC + HIT_EV_OFF_PROJ_COUNT);
    if proj_i < 0 || proj_i >= pc { return -1; }
    ps := (po + proj_i) * HIT_PROJ_REC;
    sc := hit_r32(g_hit_projs, ps + HIT_PJ_OFF_STEP_COUNT);
    if step_i < 0 || step_i >= sc { return -1; }
    off := hit_r32(g_hit_projs, ps + HIT_PJ_OFF_STEP_OFF);
    j : int, mut = 0;
    loop {
        if j >= HIT_STEP_REC { break; }
        store8(out, j, load8(g_hit_steps, off + step_i * HIT_STEP_REC + j));
        j = j + 1; }
    return 0; }

// 取事件投影步（M1 契约 = proj0 视图）：把该步记录原样复制到 out（调用方
// 保证 ≥HIT_STEP_REC；M1 消费方只读前 20B 视区 = 布局未变。事件 24/28 字段
// = proj0 镜像，语义与 M1 记录等价——单投影事件的 proj0 = 唯一投影）。
// Returns 0 = 成功；-1 = 事件槽/步号非法。
fn hit_proj_step(event_slot: int, step_i: int, out: string) -> int {
    if event_slot < 0 || event_slot >= g_hit_event_count { return -1; }
    sc := hit_r32(g_hit_events, event_slot * HIT_EVENT_REC + HIT_EV_OFF_STEP_COUNT);
    if step_i < 0 || step_i >= sc { return -1; }
    off := hit_r32(g_hit_events, event_slot * HIT_EVENT_REC + HIT_EV_OFF_STEP_OFF);
    j : int, mut = 0;
    loop {
        if j >= HIT_STEP_REC { break; }
        store8(out, j, load8(g_hit_steps, off + step_i * HIT_STEP_REC + j));
        j = j + 1; }
    return 0; }

// 运行时条目查询：key = 8 键名之一（call_mechanism/call_ret_addr/
// call_stack_grow/param_mode/param_regs/save_regs/extern_entry/extern_resolve）。
// 值 = 4B 码或位掩码写入 out。Returns 0 = 已写；-1 = 无 runtime 小节/未知键。
fn hit_runtime_get(key: string, out: string) -> int {
    if g_hit_runtime_present == 0 { return -1; }
    slot : int, mut = -1;
    if str_eq(key, "call_mechanism") != 0 { slot = HIT_RT_CALL_MECHANISM; }
    if str_eq(key, "call_ret_addr") != 0 { slot = HIT_RT_CALL_RET_ADDR; }
    if str_eq(key, "call_stack_grow") != 0 { slot = HIT_RT_CALL_STACK_GROW; }
    if str_eq(key, "param_mode") != 0 { slot = HIT_RT_PARAM_MODE; }
    if str_eq(key, "param_regs") != 0 { slot = HIT_RT_PARAM_MASK; }
    if str_eq(key, "save_regs") != 0 { slot = HIT_RT_SAVE_MASK; }
    if str_eq(key, "extern_entry") != 0 { slot = HIT_RT_EXTERN_ENTRY; }
    if str_eq(key, "extern_resolve") != 0 { slot = HIT_RT_EXTERN_RESOLVE; }
    if slot < 0 { return -1; }
    hit_w32(out, 0, hit_r32(g_hit_runtime, slot * 4));
    return 0; }

// ── --dump-table 读回通道（corearch 加载后调用；只读表状态，零写侧影响）──
// 评审项 1 锁（多 proj 步小节归属）与评审项 4（v2 字段区读回覆盖）共用：
// 每事件一行 proj 表记录回读（hit_proj_count/hit_proj_step_count——步数吞并
// 在此失真）；每步一行 v2 字段区探针（hit_proj_step_get 整条 108B 复制后读
// opcode 区 OPB0 = 偏移 32——写读一致的实证）；runtime 槽位掩码读回。
fn hit_dump_table_state() {
    // 事件 → 逐 proj 步数（proj0 镜像/M1 视区也随 p0 步数一起验证）
    ei : int, mut = 0;
    loop {
        if ei >= g_hit_event_count { break; }
        print("hit proj: ev=");
        print_i(hit_r32(g_hit_events, ei * HIT_EVENT_REC + HIT_EV_OFF_ID));
        pc := hit_proj_count(ei);
        print(" projs="); print_i(pc);
        pi : int, mut = 0;
        loop {
            if pi >= pc { break; }
            print(" p"); print_i(pi); print("=");
            print_i(hit_proj_step_count(ei, pi));
            pi = pi + 1; }
        println("");
        ei = ei + 1; }
    // 逐步 opcode 首字节探针（v2 字段区 = 步记录偏移 32 起）
    st := alloc(HIT_STEP_REC);
    ej : int, mut = 0;
    loop {
        if ej >= g_hit_event_count { break; }
        idj := hit_r32(g_hit_events, ej * HIT_EVENT_REC + HIT_EV_OFF_ID);
        pj : int, mut = 0;
        loop {
            if pj >= hit_proj_count(ej) { break; }
            sj : int, mut = 0;
            loop {
                if sj >= hit_proj_step_count(ej, pj) { break; }
                if hit_proj_step_get(ej, pj, sj, st) == 0 {
                    print("hit step: ev="); print_i(idj);
                    print(" p="); print_i(pj); print(" s="); print_i(sj);
                    print(" opb="); print_i(hit_r32(st, HIT_ST_OFF_OPB0));
                    println(""); }
                sj = sj + 1; }
            pj = pj + 1; }
        ej = ej + 1; }
    // runtime 槽读回（掩码十进制 = 测试期望锚：param = rdi rsi rdx rcx r8 r9；
    // save = rbx r12-15）
    if hit_runtime_get("param_regs", st) == 0 {
        print("hit rt: param_regs="); print_i(hit_r32(st, 0)); println(""); }
    if hit_runtime_get("save_regs", st) == 0 {
        print("hit rt: save_regs="); print_i(hit_r32(st, 0)); println(""); }
}
