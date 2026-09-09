// === ccr_io.cr ===
// .ccr binary serialization — the interface between corec (frontend)
// and corearch (backend).
//
// v7 format（serialization v4；v7-only——load 校验 version==7，无 v6 兼容/转换；
// v6 读路径退役：旧 v6 文件由 version 拒收，无转换工具）
// 字节真相 = docs/superpowers/specs/2026-09-09-lattice-ir-v7-format.md（设计定稿
// ——在 v6 段表架构上扩展：NOD 36B 邻接 + EDG 段必落 + ENT 实记录（Task 2：
// corec 产时重建——直调内核 compute_live_ranges（ent_kernel.cr 单源化，见 save_ccr））
// + coreir-schema.md 家风格（Task 6 并入 schema）。本文件头注释 = 实现权威
// （v6 目标形状落地：SYM 归并 spec §3.2——vars 表并入函数记录声明区/globals；
// REG 坐标化 spec §3.5——kind/parent/enter/exit/first_ent/last_ent，nstart/
// ncount 由 enter/exit 派生）。与 spec 表格的编码层差异（实现决策，Task 6
// schema 同步按本注释落笔）：
//   (a) 局部变量 name/type 不丢：ENT 28B 定长记录只携带 var_id（NOD 同命名
//       space = 内存行序），无法容纳声明元数据——「存在即声明」落为：变量的
//       名称/类型 = 函数记录内嵌声明区（位置数组，行序即创建序、前 param_count
//       个 = 参数；非符号命名空间——SYM 无 vars 小节）；全局 type 占 v5 全局
//       记录 var_idx 槽（var_idx 恒 == 行序，冗余）——记录仍 16B。
//   (b) SYM 子节序 = globals → funcs → str_consts → structs → enums →
//       opt_meta（globals 前置 = loader 单遍流式重建 var 行序 [全局行][函数块]）。
//   (c) func 记录的 instr/var 范围不再落盘——instr 范围由 root_region（REG 行
//       id）span 派生（根 region = SG_FUNC，span = 函数节点范围，与 v5 func_meta
//       instr_start/count 恒等）；var_start = 声明区行序游标（globals 行 + 前缀
//       函数块）。
//   (d) REG 由「可缺」升为必备（load 拒绝无 REG 的文件——函数指令边界唯一
//       真源）；ENT 仍可缺（v5 精神：旧段缺失 = 空）。
// 全整数 LE；offset 相对文件头：
//   [header 16B]: magic u32 = "CCR1" | version u32 = 7 | seg_count u32 = 6 |
//                 reserved u32 = 0
//   [seg table 6×12B]: {tag u32, offset u32, size u32}——规范序（tag = 行号 1..6，
//                 offset = 上一段尾，段体紧随段表连续排列）
//   [seg bodies]（按段表寻址）:
//     STR(1) 字符串表：  [str_count u32] [× {len u32, data}]（同 v5）
//     SYM(2) 符号面（spec §3.2 归并形状——每小节自带计数）:
//       [global_count][global_count×16B {name u32, type u32, init_val i64}]
//                    （v5 var_idx 槽 → type：var 行序 = 全局记录序 0..G-1，
//                    行名/型随本记录携带——var_idx 恒等行序故删除）
//       [func_count][func_count×{name u32, param_count u32, ret_type u32,
//                    root_region i32（本函数 SG_FUNC 的 REG 行 id）,
//                    first_ent i32, last_ent i32（本函数条目文件范围；
//                    -1 = 无条目）}                                   = 24B
//                    + param_ents[param_count]×i32（参数变量的「入参」条目 =
//                    该参数 def_nod=-1 条目 id；函数内被重定值/从未引用 → -1）
//                    + var_count u32
//                    + var_decls[var_count]×{name u32, type u32}]（v5 vars 表
//                    并入——行序 = 创建序，前 param_count 个 = 参数；变量命名
//                    space = globals 行 + 函数块行序相接，ENT/NOD var_id 指此）
//       [str_const_count][str_const_count×4B]
//       [struct_count][struct_count×{name u32, field_count u32,
//                      fields[field_count]×{name u32, type u32}}]
//       [enum_count][enum_count×{name u32, variant_count u32,
//                     variants[variant_count]×{name u32, type_count u32,
//                     types[type_count]×u32}}]
//       [opt_count][opt_count×{key u32, len u32, data lenB}]
//     NOD(3) 节点表：    [nod_count u32] [×36B {op i32, dest i32, src1 i64,
//                        src2 i32, src3 i32, tk i32, first_edge u32,
//                        edge_count u32}]——28B v5 语义字段不变 + 邻接索引
//                        （v7 spec §3.3；NOD id = 文件序索引 0..nod_count-1
//                        = 图坐标 D1；ENT 区间/def 即指此坐标）
//     EDG(6) 边表（v7 必落）：[edg_count u32] [×8B {to_nod u32, kind u32}]
//                        ——节点 i 出边连续段 [first_edge, first_edge+edge_count)，
//                        first_edge = 前缀累计（节点 i+1 first_edge = 前节点
//                        first_edge+edge_count）；每边 to_nod > 所属节点（v7
//                        spec §4 拓扑不变量 1——数据/state 边前向）；kind 0=数据
//                        (def-use)、1=state（副作用序）。落盘源 = g_df_edges
//                        （内存 = 头插链表，dataflow.cr）——save 前按节点序
//                        单遍收集（见 ccr_collect_edges）；v7 校验规则
//                        edg_count == Σ edge_count（规则 3）。
//     ENT(4) 条目表：    [ent_count u32] [×28B {var_id i32, version u32,
//                        def_nod i32, live_start u32, live_end u32（半开：
//                        最后使用点+1）, home i32, flags u32}]
//                        v7 Task 2 起实记录（corec 产时重建 = 直调内核
//                        compute_live_ranges/compute_entries（ent_kernel.cr——
//                        内核抽取 Task 2 写侧单源化，镜像消除；文件 ENT = 校验面
//                        + 语义消费通道数据源）；内存表 24B/条（闭区间、无
//                        version，内核与写侧共用）→ 落盘：
//                        version = 同 var 组内定值升序序数（1-based），
//                        live_end_disk = live_end_mem + 1；盘上 7 字段 = 28B。
//                        home 恒 -1（实例注记——分配决策不写回格式，字节
//                        spec §3.5）；flags 恒 0（无配方/参数/全局/驱逐位
//                        零实例——位语义保留）
//     REG(5) region 表： [sg_count u32] [×24B {kind u32, parent i32,
//                        enter_nod u32, exit_nod u32（v5 enter/exit 指令号 =
//                        NOD 坐标，语义不变）, first_ent i32, last_ent i32}]
//                        v5 的 nstart/ncount 不再落盘——nstart ≡ enter、
//                        ncount = exit − enter（sg_push/sg_pop 不变式），
//                        load 内存态重建与 v5 记录逐字节一致。
//                        first_ent/last_ent（区内条目范围）语义：条目按其
//                        def_nod ∈ [enter_nod, exit_nod) 归属 region（定值点
//                        升序 → 文件条目序连续一段）；根 region（kind=SG_FUNC）
//                        = 整个函数条目块（含 def=-1 参数条目）；无条目 = -1。
// 载荷约定（corec → corearch）：NOD 段 = v5 instrs 坐标化（字段同布局）——
// corearch 消费路径不变（硬约束）；ENT 由 corearch 加载校验，发射不依赖。
// 内存态重建（load 后 = 本文件字节的投影，ELF 发射语义零变化）：g_ir_vars 行
// {name,id,type}（id = 行序）、g_ir_globals {name,var_idx,init_val}（var_idx =
// 行序）、g_ir_func_* 七数组（instr/var 范围派生，见 (c)）、g_sgs（nstart/
// ncount 派生）、g_ir_entries 24B 表 + func 条目块（块界按 SYM func first/last
// 校验）。
// 与 v5 差异：固定 36B 头 + 定序段 → Header + 段表；entries 段新增；
//   v5 参考：magic/version=5/7 计数在固定偏移，本文件旧注释已废弃。

// --- Byte buffer helpers ---
// No bitwise ops in Core — use arithmetic instead.

CCR_MAGIC : int = 827474755;  // "CCR1" (0x31524343)
CCR_VERSION : int = 7;        // v7-only（load 校验 ==7；v6 读路径退役——拒 version≠7）
CCR_SEG_COUNT : int = 6;      // STR SYM NOD ENT REG EDG（规范序 tag 1..6；预留 7+ 不占空间）

// On-disk NOD record size: 7 × i32 + 邻接 2 × u32 = 36 bytes — v7 spec §3.3
// {op, dest, s1(i64), src2, src3, tk, first_edge, edge_count}（v5 28B 语义字段
// 不变，first_edge/edge_count = 节点出边在 EDG 段的连续段索引）。
ESZ_NOD_DISK : int = 36;

// On-disk EDG record size: 2 × u32 = 8 bytes — v7 spec §3.4
// {to_nod u32, kind u32}（from = 所属节点，邻接隐含——文件序节点 i 的出边
// 在 [first_edge, first_edge+edge_count) 连续段内）
ESZ_EDGE_DISK : int = 8;

// On-disk REG record size: 6 × i32 = 24 bytes — v6 坐标化字段序
// {kind, parent, enter_nod, exit_nod, first_ent, last_ent}（v5 的 nstart/ncount
// 不落盘——load 由 enter/exit 派生：nstart = enter, ncount = exit − enter）。
// NOTE: the in-memory SG entry is ESZ_SG (48 bytes, u64 fields) — that is NOT
// the wire format. Always use ESZ_SG_DISK for .ccr size math, never ESZ_SG.
ESZ_SG_DISK : int = 24;

// SYM 落盘记录尺寸：
//   全局记录 16B {name u32, type u32, init_val i64}（v5 var_idx 槽 → type）
//   函数记录 = 24B 定长头 {name, param_count, ret_type, root_region,
//                first_ent, last_ent} + param_ents[i32 × param_count]
//              + {var_count u32} + var_decls[8B × var_count]
ESZ_GLOBAL_DISK : int = 16;
ESZ_FUNC_HEAD_DISK : int = 24;
ESZ_VARDECL_DISK : int = 8;

// On-disk ENT record: 7 × 4B = 28 bytes (var_id/version/def_nod/live_start/
// live_end/home/flags; version + 半开 live_end 由内存 24B 表转换，见文件头注释).
// The in-memory entry table is ESZ_ENTRY (24 bytes, no version field — the
// per-var ordinal is derivable from group order); disk record ≠ memory record.
ESZ_ENTRY_DISK : int = 28;

fn bw_byte(val: int, shift: int) -> int {
    if shift == 0 { return val % 256; }
    if shift >= 24 { return (val / 16777216) % 256; }
    if shift >= 16 { return (val / 65536) % 256; }
    if shift >= 8 { return (val / 256) % 256; }
    return 0;
}

fn buf_write_u32(buf: string, pos: int, val: int) {
    w32(buf, pos, val);
}

fn buf_write_i32(buf: string, pos: int, val: int) {
    w32(buf, pos, val);
}

fn buf_write_i64(buf: string, pos: int, val: int) {
    w64(buf, pos, val);
}

fn buf_read_u32(buf: string, pos: int) -> int {
    b0 := load8(buf, pos);
    b1 := load8(buf, pos + 1);
    b2 := load8(buf, pos + 2);
    b3 := load8(buf, pos + 3);
    return b0 + b1 * 256 + b2 * 65536 + b3 * 16777216;
}

fn buf_read_i32(buf: string, pos: int) -> int {
    b0 := load8(buf, pos);
    b1 := load8(buf, pos + 1);
    b2 := load8(buf, pos + 2);
    b3 := load8(buf, pos + 3);
    val := b0 + b1 * 256 + b2 * 65536;
    if b3 >= 128 { return val + (b3 - 256) * 16777216; }
    return val + b3 * 16777216;
}

fn buf_read_i64(buf: string, pos: int) -> int {
    // Little-endian signed 64-bit. The low dword must be read UNSIGNED:
    // reading it signed (buf_read_i32) would double-subtract for negatives
    // (e.g. -7 = lo -7 + hi -1 → -7 + -2^32, not -7).
    b0 := load8(buf, pos);
    b1 := load8(buf, pos + 1);
    b2 := load8(buf, pos + 2);
    b3 := load8(buf, pos + 3);
    lo := b0 + b1 * 256 + b2 * 65536 + b3 * 16777216;
    h0 := load8(buf, pos + 4);
    h1 := load8(buf, pos + 5);
    h2 := load8(buf, pos + 6);
    h3 := load8(buf, pos + 7);
    hi : ., mut = h0 + h1 * 256 + h2 * 65536;
    if h3 >= 128 { hi = hi + (h3 - 256) * 16777216; }
    else { hi = hi + h3 * 16777216; }   // 修复 15：h3 < 128 时漏加 h3×2^24 → bit 56-62 丢失
    // Keep the factor within the parser's supported integer-literal range.
    hi_part := hi * 65536;
    hi_part = hi_part * 65536;
    return lo + hi_part;
}

// Check a byte range without forming an overflowing end position. CCR counts
// come from the file, so every variable-length section must use this helper
// before reading or growing an array from its count.
fn ccr_has_bytes(pos: int, need: int, fsize: int) -> int {
    if pos < 0 || need < 0 || pos > fsize { return 0; }
    if need > fsize - pos { return 0; }
    return 1;
}

fn ccr_i32_fits(val: int) -> int {
    if val < -2147483648 || val > 2147483647 { return 0; }
    return 1;
}

fn ccr_validate_i32_fields() -> int {
    ii : ., mut = 0;
    loop {
        if ii >= g_ir_instr_count { break; }
        if ccr_i32_fits(iri_dest(ii)) == 0 ||
           ccr_i32_fits(iri_s2(ii)) == 0 ||
           ccr_i32_fits(iri_s3(ii)) == 0 { return 0; }
        ii = ii + 1;
    }
    // REG 落盘字段 = kind/parent/enter/exit（nstart/ncount 由 enter/exit 派生，
    // 不再落盘——v5 校验过的内存 nstart/ncount 字段随之免除）
    si : ., mut = 0;
    loop {
        if si >= g_sg_count { break; }
        f := si * ESZ_SG;
        if ccr_i32_fits(r64(g_sgs, f + OFF_SG_KIND)) == 0 ||
           ccr_i32_fits(r64(g_sgs, f + OFF_SG_ENTER)) == 0 ||
           ccr_i32_fits(r64(g_sgs, f + OFF_SG_EXIT)) == 0 ||
           ccr_i32_fits(r64(g_sgs, f + OFF_SG_PARENT)) == 0 { return 0; }
        si = si + 1;
    }
    return 1;
}

// 函数 fi 的根 region = REG 行序第 fi 个 SG_FUNC 行（压栈序：每个已编译函数
// df_begin_func 推 SG_FUNC，嵌套行紧随其根行——根行按函数序 1:1）。
// 返回行 id；-1 = 越界/结构不一致。
fn ccr_func_root_sg(func_i: int) -> int {
    if func_i < 0 { return -1; }
    k : ., mut = 0;
    si : ., mut = 0;
    loop {
        if si >= g_sg_count { break; }
        if r64(g_sgs, si * ESZ_SG + OFF_SG_KIND) == SG_FUNC {
            if k == func_i { return si; }
            k = k + 1;
        }
        si = si + 1;
    }
    return -1;
}

// --- Segment size calculation（段体大小；Header+段表 = 16 + 12×6 = 88）---
// 每段自带计数 u32；写侧与 calc 侧逐字节一致（v7 测试 walk 校验 end==fsize）。

fn ccr_str_seg_size() -> int {
    sz : ., mut = 4;  // str_count
    si : ., mut = 0;
    loop {
        if si >= g_str_count { break; }
        sz = sz + 4 + istr_len(si);
        si = si + 1;
    }
    return sz;
}

fn ccr_sym_seg_size() -> int {
    // 布局 = ccr_sym_seg_size/save_ccr/load_ccr 三方逐字节一致（见头注释）：
    //   globals(16B) → funcs(24B 头 + param_ents + var_count + var_decls 8B)
    //   → str_consts → structs → enums → opt_meta
    sz : ., mut = 4 + g_ir_global_count * ESZ_GLOBAL_DISK;   // global_count + globals
    sz = sz + 4;  // func_count
    fi : ., mut = 0;
    loop {
        if fi >= g_ir_func_count { break; }
        pc := r64(g_ir_func_param_count, fi * 8);
        vc := r64(g_ir_func_var_count, fi * 8);
        sz = sz + ESZ_FUNC_HEAD_DISK + pc * 4 + 4 + vc * ESZ_VARDECL_DISK;
        fi = fi + 1;
    }
    sz = sz + 4 + g_ir_str_const_count * 4;     // str_const_count + str_consts
    // structs: struct_count + {name, field_count, fields×8B}
    sz = sz + 4;
    sti : ., mut = 0;
    loop {
        if sti >= g_struct_count { break; }
        sz = sz + 8 + si_field_count(sti) * 8;
        sti = sti + 1;
    }
    // enums: enum_count + {name, variant_count, variants×{name, tc, types×4B}}
    sz = sz + 4;
    ei : ., mut = 0;
    loop {
        if ei >= g_enum_count { break; }
        vc := ei_variant_count(ei);
        sz = sz + 8;  // name + variant_count
        vi : ., mut = 0;
        loop {
            if vi >= vc { break; }
            tc := ei_variant_type_count(ei, vi);
            sz = sz + 8 + tc * 4;  // variant name + tc + types
            vi = vi + 1;
        }
        ei = ei + 1;
    }
    // opt_meta: opt_count + {key, len, data}
    sz = sz + 4;
    mi : ., mut = 0;
    loop {
        if mi >= g_opt_meta_count { break; }
        sz = sz + 8 + r32(g_opt_meta, mi * OPT_META_STRIDE + 4);
        mi = mi + 1;
    }
    return sz;
}

fn ccr_nod_seg_size() -> int {
    return 4 + g_ir_instr_count * ESZ_NOD_DISK;
}

fn ccr_edg_seg_size(edge_total: int) -> int {
    return 4 + edge_total * ESZ_EDGE_DISK;
}

fn ccr_ent_seg_size() -> int {
    return 4 + g_entry_count * ESZ_ENTRY_DISK;
}

fn ccr_reg_seg_size() -> int {
    return 4 + g_sg_count * ESZ_SG_DISK;
}

// --- Size calculation（v7：16B header + 6×12B seg table + 各段体）---
// edge_total = EDG 记录总数（save_ccr 先行收集，见 ccr_collect_edges）。

fn calc_ccr_size(edge_total: int) -> int {
    sz : ., mut = 16 + CCR_SEG_COUNT * 12;
    sz = sz + ccr_str_seg_size();
    sz = sz + ccr_sym_seg_size();
    sz = sz + ccr_nod_seg_size();
    sz = sz + ccr_ent_seg_size();
    sz = sz + ccr_reg_seg_size();
    sz = sz + ccr_edg_seg_size(edge_total);
    return sz;
}

// --- EDG 内容收集（写侧；v7 spec §3.4/§4）---
// g_df_edges = 每节点头插出边链表（dataflow.cr df_add_edge_kind，OFF_DFE_NEXT
// 链）。落盘前按节点序单遍走查 → 每节点出边连续段（first_edge = 前缀累计）
// + 扁平 {to, kind} 值缓冲（8B/边，to + kind×2^32 打包）。写侧守卫与 loader
// 同域（v7 守卫面强度保持）：链表归属错乱/后向边（to_nod ≤ 所属节点，自环
// 含）/kind > 1 → 拒绝落盘（内存图 = 文件 EDG 的唯一源，loader 永不拒绝
// 自己 writer 的产物）。
fn ccr_collect_edges(edge_counts: string, edge_offs: string) -> int {
    total : ., mut = 0;
    ni : ., mut = 0;
    loop {
        if ni >= g_ir_instr_count { break; }
        w64(edge_offs, ni * 8, total);
        cnt : ., mut = 0;
        eid : ., mut = r64(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_FIRST_EDGE);
        loop {
            if eid < 0 { break; }
            if eid >= g_df_edge_count { return -1; }   // 链表越界（缓存恢复错乱防御）
            if r64(g_df_edges, eid * ESZ_DFEDGE + OFF_DFE_FROM) != ni { return -1; }
            eto := r64(g_df_edges, eid * ESZ_DFEDGE + OFF_DFE_TO);
            if eto <= ni { return -1; }                // v7 §4 规则 1：to_nod > 所属节点
            if r64(g_df_edges, eid * ESZ_DFEDGE + OFF_DFE_KIND) > 1 { return -1; }
            cnt = cnt + 1;
            eid = r64(g_df_edges, eid * ESZ_DFEDGE + OFF_DFE_NEXT);
        }
        w64(edge_counts, ni * 8, cnt);
        total = total + cnt;
        ni = ni + 1;
    }
    return total;
}

// 第二遍：按节点序把出边写入扁平缓冲（slot = edge_offs[i] 起连续）
fn ccr_fill_edge_buf(buf: string, edge_offs: string) {
    ni : ., mut = 0;
    loop {
        if ni >= g_ir_instr_count { break; }
        slot : ., mut = r64(edge_offs, ni * 8);
        eid : ., mut = r64(g_df_nodes, ni * ESZ_DFNODE + OFF_DF_FIRST_EDGE);
        loop {
            if eid < 0 { break; }
            eto := r64(g_df_edges, eid * ESZ_DFEDGE + OFF_DFE_TO);
            ekind := r64(g_df_edges, eid * ESZ_DFEDGE + OFF_DFE_KIND);
            w64(buf, slot * 8, eto + ekind * 4294967296);
            slot = slot + 1;
            eid = r64(g_df_edges, eid * ESZ_DFEDGE + OFF_DFE_NEXT);
        }
        ni = ni + 1;
    }
}

// --- v7 读侧载入缓冲（EDG 校验后保留——图边语义对象：内核完备 Task 1 起经
// 对象面 v7_edge_to/v7_edge_kind 消费（ent_kernel.cr——节点出边遍历 = 配方
// 输入集）；g_df_edges 在 corearch 编译物中存在但 dataflow.cr 不在其内——
// 独立缓冲）---
g_v7_edges : string, mut;         // EDG 扁平记录（8B/条，文件序 = 节点运行序）
g_v7_edge_count : int, mut;

// --- Entry-table accessors（内存 24B 表读——写侧/loader 本地别名；内核
// ent_* 等价访问器在 ent_kernel.cr（双 concat 共享，2026-09-10 Task 2 起），
// 本组保留不收敛（按实际引用删原则）。buf_read_i32 带符号扩展同内核。）---
fn ccr_ent_var(e: int) -> int { return buf_read_i32(g_ir_entries, e * ESZ_ENTRY + OFF_ENTRY_VAR); }
fn ccr_ent_def(e: int) -> int { return buf_read_i32(g_ir_entries, e * ESZ_ENTRY + OFF_ENTRY_DEF); }
fn ccr_ent_ls(e: int) -> int { return buf_read_i32(g_ir_entries, e * ESZ_ENTRY + OFF_ENTRY_LS); }
fn ccr_ent_le(e: int) -> int { return buf_read_i32(g_ir_entries, e * ESZ_ENTRY + OFF_ENTRY_LE); }
fn ccr_ent_home(e: int) -> int { return buf_read_i32(g_ir_entries, e * ESZ_ENTRY + OFF_ENTRY_HOME); }
fn ccr_ent_flags(e: int) -> int { return buf_read_i32(g_ir_entries, e * ESZ_ENTRY + OFF_ENTRY_FLAGS); }

// --- Entry 表载体 grow 注记（内核抽取 Task 2：写侧单源化）---
// compute_entries_v7/ccr_grow_* 镜像已删——corec 写侧直调内核
// compute_live_ranges()（尾部逐函数内调 compute_entries；grow = 内核
// grow_entries/grow_func_entry_meta，ent_kernel.cr 双 concat 共享单实例）。
// loader（corearch 进程）ENT 载入同样直调内核 grow（函数体 = 原本地副本
// 逐字节同源——语义零变化）。

// 函数条目块 [es, es+ec) 内 var 的 def=-1 条目 id（SYM func param_ents 回填
// 用——参数「入参」条目 = 该参数 def=-1 条目；被重定值/从未引用 → 无 = -1；
// def=-1 补丁每 var 至多一条）。写侧守卫：返回 id 恒 ≥ es 且在块内。
fn ccr_param_entry_id(var_id: int, es: int, ec: int) -> int {
    e : ., mut = 0;
    loop {
        if e >= ec { break; }
        ei := es + e;
        if ccr_ent_var(ei) == var_id && ccr_ent_def(ei) < 0 { return ei; }
        e = e + 1;
    }
    return -1;
}

// --- Save（写侧与 calc 侧一致；段表规范序、段体连续）---

fn save_ccr(path: string) -> int {
    // The v7 wire format stores these fields as signed i32 — 编码层文件格式
    // 限制（字段形状 = 文件布局域，hw-map/经典投影实例；与 int 语义无涉，
    // int-unbounded-semantics 定稿 §三）。Refuse to emit a lossy file instead
    // of letting w32 silently keep only the low bits.
    if ccr_validate_i32_fields() == 0 { return -1; }

    // v7 Task 2（ENT 主干化）+ 内核抽取 Task 2（写侧单源化）：ENT 数据面先行
    // ——corec 写侧直调内核 compute_live_ranges()（尾部逐函数内调 compute_entries，
    // 填 g_ir_entries 内存 24B 闭区间表 / g_entry_count + 函数块界
    // g_ir_func_entry_start/count）。镜像 compute_entries_v7 已消除——双转录
    // R5 收敛；corearch 判定/分配自算 = 同一内核（双进程同源）。文件 ENT = 校验
    // 面 + 语义消费通道数据源，行为零变化（半开转换 live_end+1 仍在下方写点）。
    compute_live_ranges();

    // v7：EDG 内容先收集（NOD 邻接域 + 段尺寸先决）——g_df_edges 内存 =
    // 头插链表，按节点序走查 → 每节点出边连续段（first_edge = 前缀累计）
    edge_counts := alloc((g_ir_instr_count + 8) * 8);
    edge_offs := alloc((g_ir_instr_count + 8) * 8);
    edge_total := ccr_collect_edges(edge_counts, edge_offs);
    if edge_total < 0 { return -1; }
    edge_buf : string, mut = "";
    if edge_total > 0 {
        edge_buf = alloc(edge_total * 8);
        ccr_fill_edge_buf(edge_buf, edge_offs);
    }

    tsz := calc_ccr_size(edge_total);
    buf := alloc(tsz);
    pos : ., mut = 0;

    // Header（16B）
    buf_write_u32(buf, pos, CCR_MAGIC); pos = pos + 4;
    buf_write_u32(buf, pos, CCR_VERSION); pos = pos + 4;
    buf_write_u32(buf, pos, CCR_SEG_COUNT); pos = pos + 4;
    buf_write_u32(buf, pos, 0); pos = pos + 4;  // reserved

    // 段体大小（与 calc_ccr_size 同一来源逐段一致）
    s1 := ccr_str_seg_size();
    s2 := ccr_sym_seg_size();
    s3 := ccr_nod_seg_size();
    s4 := ccr_ent_seg_size();
    s5 := ccr_reg_seg_size();
    s6 := ccr_edg_seg_size(edge_total);

    // Seg table（6 × 12B；offset = 前段尾，从段表后起；规范序 tag 1..6）
    o1 : ., mut = 16 + CCR_SEG_COUNT * 12;
    o2 : ., mut = o1 + s1;
    o3 : ., mut = o2 + s2;
    o4 : ., mut = o3 + s3;
    o5 : ., mut = o4 + s4;
    o6 : ., mut = o5 + s5;

    buf_write_u32(buf, pos, 1); buf_write_u32(buf, pos + 4, o1); buf_write_u32(buf, pos + 8, s1); pos = pos + 12;
    buf_write_u32(buf, pos, 2); buf_write_u32(buf, pos + 4, o2); buf_write_u32(buf, pos + 8, s2); pos = pos + 12;
    buf_write_u32(buf, pos, 3); buf_write_u32(buf, pos + 4, o3); buf_write_u32(buf, pos + 8, s3); pos = pos + 12;
    buf_write_u32(buf, pos, 4); buf_write_u32(buf, pos + 4, o4); buf_write_u32(buf, pos + 8, s4); pos = pos + 12;
    buf_write_u32(buf, pos, 5); buf_write_u32(buf, pos + 4, o5); buf_write_u32(buf, pos + 8, s5); pos = pos + 12;
    buf_write_u32(buf, pos, 6); buf_write_u32(buf, pos + 4, o6); buf_write_u32(buf, pos + 8, s6); pos = pos + 12;

    // === STR: strings ===
    buf_write_u32(buf, pos, g_str_count); pos = pos + 4;
    si : ., mut = 0;
    loop {
        if si >= g_str_count { break; }
        sl := istr_len(si);
        buf_write_u32(buf, pos, sl); pos = pos + 4;
        ci : ., mut = 0;
        loop {
            if ci >= sl { break; }
            store8(buf, pos, str_load8(si, ci));
            pos = pos + 1;
            ci = ci + 1;
        }
        si = si + 1;
    }

    // === SYM: globals（16B each: name u32, type u32, init_val i64）===
    // v5 var_idx 槽 → type（var_idx 恒 == 行序——ir_gen reg_one_global 每全局
    // 一 var 行、行序与记录序锁步；下方校验强制，失配拒绝 = 防止未来布局漂移
    // 时静默生成行序错位的文件）。全局行 = var 命名空间前缀 0..G-1。
    buf_write_u32(buf, pos, g_ir_global_count); pos = pos + 4;
    gi : ., mut = 0;
    loop {
        if gi >= g_ir_global_count { break; }
        if r64(g_ir_globals, gi * 24 + 8) != gi { return -1; }
        buf_write_u32(buf, pos, r64(g_ir_globals, gi * 24)); pos = pos + 4;     // name
        buf_write_u32(buf, pos, irv_type(gi)); pos = pos + 4;                   // type
        buf_write_i64(buf, pos, r64(g_ir_globals, gi * 24 + 16)); pos = pos + 8; // init_val
        gi = gi + 1;
    }

    // === SYM: funcs（24B 头 + param_ents + var 声明区——v5 func_meta 的
    // instr_start/count 由 root_region span 取代、var_start/count 由声明区
    // 行序游标取代；v5 vars 表并入声明区：行序 = 创建序、前 param_count 个
    // = 参数。var 行序守卫：每函数声明区起点 == 前缀累计（globals 行 + 前
    // 函数 var 数），块序相接铺满 g_ir_vars）===
    // GC-4（SYM 评审 M2）：位置级守卫——计数级（Σ == var_count + var_idx == gi）
    // 总量守恒时察觉不到块错位（声明区左移/右移一格、总量不变 → 文件行序
    // 静默漂移，ENT var_id 命名空间错位）。失配 = 函数非序发射 → 拒绝；与
    // loader REG root span 校验（load 侧同域闭环）同风格。
    vcursor : ., mut = g_ir_global_count;
    buf_write_u32(buf, pos, g_ir_func_count); pos = pos + 4;
    fi : ., mut = 0;
    loop {
        if fi >= g_ir_func_count { break; }
        froot := ccr_func_root_sg(fi);
        if froot < 0 { return -1; }
        vc := r64(g_ir_func_var_count, fi * 8);
        vs := r64(g_ir_func_var_start, fi * 8);
        if vs != vcursor { return -1; }  // 声明区起点 ≠ 前缀累计 → 行序错位
        vcursor = vcursor + vc;
        pc := r64(g_ir_func_param_count, fi * 8);
        if pc > vc { return -1; }
        // v7 Task 2：条目块界实回填（内核 compute_live_ranges 已先行）——函数条目
        // 块 = ENT 文件序连续段 [es, es+ec)（SYM func 与 REG 根行同源双写；
        // loader 块对照消费：pcnt==0 ↔ -1、ffe == 块首、fle == 块末）
        es := r64(g_ir_func_entry_start, fi * 8);
        ec := r64(g_ir_func_entry_count, fi * 8);
        fe2 : ., mut = -1;
        le2 : ., mut = -1;
        if ec > 0 { fe2 = es; le2 = es + ec - 1; }
        buf_write_u32(buf, pos, r64(g_ir_func_name_idx, fi * 8)); pos = pos + 4;
        buf_write_u32(buf, pos, pc); pos = pos + 4;
        buf_write_u32(buf, pos, r64(g_ir_func_ret_type, fi * 8)); pos = pos + 4;
        buf_write_i32(buf, pos, froot); pos = pos + 4;
        buf_write_i32(buf, pos, fe2); pos = pos + 4;
        buf_write_i32(buf, pos, le2); pos = pos + 4;
        // param_ents 实回填：参数「入参」条目 = 该参数 var 的 def=-1 条目 id
        // （函数内被重定值/从未引用 → -1；头注释 §3.2 语义）。loader 只做
        // 界拒绝（pid < -1）——与 ENT 的一致性由 Python 侧/测试网对照。
        pp : ., mut = 0;
        loop {
            if pp >= pc { break; }
            buf_write_i32(buf, pos, ccr_param_entry_id(vs + pp, es, ec));
            pos = pos + 4;
            pp = pp + 1;
        }
        // var 声明区（行序声明——name/type；ENT「存在即声明」的名称/类型投影）
        buf_write_u32(buf, pos, vc); pos = pos + 4;
        vv : ., mut = 0;
        loop {
            if vv >= vc { break; }
            row := vs + vv;
            if row < 0 || row >= g_ir_var_count { return -1; }
            buf_write_u32(buf, pos, irv_name(row)); pos = pos + 4;
            buf_write_u32(buf, pos, irv_type(row)); pos = pos + 4;
            vv = vv + 1;
        }
        fi = fi + 1;
    }
    if vcursor != g_ir_var_count { return -1; }  // 末块未铺满命名空间 → 洞

    // === SYM: string constants ===
    buf_write_u32(buf, pos, g_ir_str_const_count); pos = pos + 4;
    sci : ., mut = 0;
    loop {
        if sci >= g_ir_str_const_count { break; }
        buf_write_u32(buf, pos, r64(g_ir_str_consts, sci * 8)); pos = pos + 4;
        sci = sci + 1;
    }

    // === SYM: structs ===
    buf_write_u32(buf, pos, g_struct_count); pos = pos + 4;
    sti : ., mut = 0;
    loop {
        if sti >= g_struct_count { break; }
        fc := si_field_count(sti);
        buf_write_u32(buf, pos, si_name(sti)); pos = pos + 4;
        buf_write_u32(buf, pos, fc); pos = pos + 4;
        fii : ., mut = 0;
        loop {
            if fii >= fc { break; }
            buf_write_u32(buf, pos, si_field_name(sti, fii)); pos = pos + 4;
            buf_write_u32(buf, pos, si_field_type(sti, fii)); pos = pos + 4;
            fii = fii + 1;
        }
        sti = sti + 1;
    }

    // === SYM: enums ===
    buf_write_u32(buf, pos, g_enum_count); pos = pos + 4;
    ei2 : ., mut = 0;
    loop {
        if ei2 >= g_enum_count { break; }
        vc := ei_variant_count(ei2);
        buf_write_u32(buf, pos, ei_name(ei2)); pos = pos + 4;
        buf_write_u32(buf, pos, vc); pos = pos + 4;
        vi2 : ., mut = 0;
        loop {
            if vi2 >= vc { break; }
            tcnt := ei_variant_type_count(ei2, vi2);
            buf_write_u32(buf, pos, ei_variant_name(ei2, vi2)); pos = pos + 4;
            buf_write_u32(buf, pos, tcnt); pos = pos + 4;
            tf : ., mut = 0;
            loop {
                if tf >= tcnt { break; }
                buf_write_u32(buf, pos, ei_variant_type(ei2, vi2, tf)); pos = pos + 4;
                tf = tf + 1;
            }
            vi2 = vi2 + 1;
        }
        ei2 = ei2 + 1;
    }

    // === SYM: opt_meta ===
    buf_write_u32(buf, pos, g_opt_meta_count); pos = pos + 4;
    mi : ., mut = 0;
    loop {
        if mi >= g_opt_meta_count { break; }
        mo := mi * OPT_META_STRIDE;
        mk := r32(g_opt_meta, mo);       // key (u8 padded to u64)
        md_len := r32(g_opt_meta, mo + 4); // data length
        buf_write_u32(buf, pos, mk); pos = pos + 4;
        buf_write_u32(buf, pos, md_len); pos = pos + 4;
        di : ., mut = 0;
        loop { if di >= md_len { break; }
            store8(buf, pos, load8(g_opt_meta, mo + 8 + di));
            pos = pos + 1;
            di = di + 1;
        }
        mi = mi + 1;
    }

    // === NOD: instructions（36B each；NOD id = 文件序 = 全局指令序；28B
    // 语义字段与 v6 逐字段一致 + first_edge/edge_count 邻接索引——EDG 段
    // 由 edge_buf 在段体末尾落盘）===
    buf_write_u32(buf, pos, g_ir_instr_count); pos = pos + 4;
    ii : ., mut = 0;
    loop {
        if ii >= g_ir_instr_count { break; }
        buf_write_u32(buf, pos, iri_op(ii)); pos = pos + 4;
        buf_write_i32(buf, pos, iri_dest(ii)); pos = pos + 4;
        // 修复 14：s1 改 64 位——IR_CONST 的大 int 常量 / float 位模式
        // 之前被截断成 32 位（float 常量静默损坏）
        buf_write_i64(buf, pos, iri_s1(ii)); pos = pos + 8;
        buf_write_i32(buf, pos, iri_s2(ii)); pos = pos + 4;
        buf_write_i32(buf, pos, iri_s3(ii)); pos = pos + 4;
        buf_write_u32(buf, pos, iri_tk(ii)); pos = pos + 4;
        buf_write_u32(buf, pos, r64(edge_offs, ii * 8)); pos = pos + 4;   // first_edge
        buf_write_u32(buf, pos, r64(edge_counts, ii * 8)); pos = pos + 4; // edge_count
        ii = ii + 1;
    }

    // === ENT: entries（28B each；内存闭区间 → 盘上：version 组内序数、live_end+1 半开）===
    // 版本序数：每 var 一张计数槽（var 全局槽 id 唯一属一个函数——组内序 = 全局序）
    buf_write_u32(buf, pos, g_entry_count); pos = pos + 4;
    vcnt : string, mut = alloc((g_ir_var_count + 8) * 8);
    vz : ., mut = 0;
    loop {
        if vz >= g_ir_var_count + 8 { break; }
        w64(vcnt, vz * 8, 0);
        vz = vz + 1;
    }
    ej : ., mut = 0;
    loop {
        if ej >= g_entry_count { break; }
        ev := ccr_ent_var(ej);
        ed := ccr_ent_def(ej);
        els := ccr_ent_ls(ej);
        ele := ccr_ent_le(ej);
        eho := ccr_ent_home(ej);
        efl := ccr_ent_flags(ej);
        ord := r64(vcnt, ev * 8) + 1;
        w64(vcnt, ev * 8, ord);
        buf_write_i32(buf, pos, ev); pos = pos + 4;      // var_id
        buf_write_u32(buf, pos, ord); pos = pos + 4;     // version（1-based）
        buf_write_i32(buf, pos, ed); pos = pos + 4;      // def_nod（-1 = 无定值）
        buf_write_u32(buf, pos, els); pos = pos + 4;     // live_start（含定值）
        buf_write_u32(buf, pos, ele + 1); pos = pos + 4; // live_end（半开 = 内存闭区间 +1）
        buf_write_i32(buf, pos, eho); pos = pos + 4;     // home（-1 = 未分配）
        buf_write_u32(buf, pos, efl); pos = pos + 4;     // flags
        ej = ej + 1;
    }

    // === REG: region（24B each——spec §3.5 字段序 {kind, parent, enter_nod,
    // exit_nod, first_ent, last_ent}；v5 nstart/ncount 不落盘 = enter/exit 派生，
    // 未闭合（exit < enter）region 无法表示 → 拒绝）===
    // first/last 语义：区内条目 = 定值点 def_nod ∈ [enter, exit)（定值点升序 →
    // 文件条目序连续段）；根 region（kind=SG_FUNC，函数 k = 行序第 k 个根）=
    // 整个函数条目块（含 def=-1 参数条目）；无条目 = -1。
    buf_write_u32(buf, pos, g_sg_count); pos = pos + 4;
    rfunc : ., mut = -1;  // 当前根 region 的函数号（行序 = 压栈序）
    si2 : ., mut = 0;
    loop {
        if si2 >= g_sg_count { break; }
        f := si2 * ESZ_SG;
        sk2 := r64(g_sgs, f + OFF_SG_KIND);
        sen := r64(g_sgs, f + OFF_SG_ENTER);
        sex := r64(g_sgs, f + OFF_SG_EXIT);
        spa := r64(g_sgs, f + OFF_SG_PARENT);
        if sex < sen { return -1; }  // 未闭合 → ncount 不可派生
        if sk2 == SG_FUNC { rfunc = rfunc + 1; }
        if rfunc < 0 || rfunc >= g_ir_func_count { return -1; }  // 行序结构失配
        // v7 Task 2：条目范围实回填（内核 compute_live_ranges 已先行）——根 region
        // （SG_FUNC）= 整个函数条目块（含 def=-1 参数条目；与 SYM func
        // first/last 同源双写——loader 逐根行对照）；嵌套 region = 定值点
        // def_nod ∈ [enter, exit) 的条目段（块内定值点升序 → 文件条目序连续
        // 一段；无 = -1）。头注释 §3.5 语义：区间 = def_nod 归属，非全块。
        fe2 : ., mut = -1;
        le2 : ., mut = -1;
        bes := r64(g_ir_func_entry_start, rfunc * 8);
        bec := r64(g_ir_func_entry_count, rfunc * 8);
        if sk2 == SG_FUNC {
            if bec > 0 { fe2 = bes; le2 = bes + bec - 1; }
        } else {
            kk : ., mut = 0;
            loop {
                if kk >= bec { break; }
                eid2 := bes + kk;
                ed2 := ccr_ent_def(eid2);
                if ed2 >= sen && ed2 < sex {
                    if fe2 < 0 { fe2 = eid2; }
                    le2 = eid2;
                }
                kk = kk + 1;
            }
        }
        if sk2 == SG_FUNC {
            // 根 region span = 函数指令范围（REG = 文件里函数边界的唯一真源，
            // 与 func 表一致性校验——失配 = 内部状态漂移）
            is2 := r64(g_ir_func_instr_start, rfunc * 8);
            ic2 := r64(g_ir_func_instr_count, rfunc * 8);
            if sen != is2 || sex != is2 + ic2 { return -1; }
        }
        buf_write_i32(buf, pos, sk2); pos = pos + 4;
        buf_write_i32(buf, pos, spa); pos = pos + 4;
        buf_write_i32(buf, pos, sen); pos = pos + 4;
        buf_write_i32(buf, pos, sex); pos = pos + 4;
        buf_write_i32(buf, pos, fe2); pos = pos + 4;
        buf_write_i32(buf, pos, le2); pos = pos + 4;
        si2 = si2 + 1;
    }

    // === EDG: edges（v7 必落；8B each {to_nod u32, kind u32}——所属节点 =
    // 邻接隐含：节点 i 出边连续段 [first_edge, first_edge+edge_count)，
    // edge_buf = 收集遍的扁平记录（打包 to + kind×2^32，此处解包写 u32 对）===
    buf_write_u32(buf, pos, edge_total); pos = pos + 4;
    ei3 : ., mut = 0;
    loop {
        if ei3 >= edge_total { break; }
        ev := r64(edge_buf, ei3 * 8);
        buf_write_u32(buf, pos, ev % 4294967296); pos = pos + 4;   // to_nod
        buf_write_u32(buf, pos, ev / 4294967296); pos = pos + 4;   // kind
        ei3 = ei3 + 1;
    }

    // Use syscall directly (write_file uses str_len which stops at null)
    fd := syscall3(2, path, 577, 420);  // open(O_WRONLY|O_CREAT|O_TRUNC, 0644)
    if fd < 0 { return -1; }
    written : ., mut = 0;
    written = syscall3(1, fd, buf, tsz);  // write(fd, buf, tsz)
    r2 := syscall3(3, fd, 0, 0);  // close(fd)
    if written != tsz { return -1; }
    return 0;
}

// GC-4 测试钩子（corec ccr --inject-var-shift 载体；真实构建路径永不调用）：
// func0 var 声明区起点左移 1 行（globals ≥ 1 时新块 [vs-1, vs-1+vc0) 恒留在
// 命名空间内——行首行被 globals 末行顶替、行尾少写 func0 末行）。Σ 计数级
// 守卫（Σ func var_count == g_ir_var_count，总量守恒）察觉不到；位置级守卫
// （vs == 前缀累计）必须拒绝 save——模拟未来函数非序发射的静默错位。
fn inject_var_shift() -> int {
    if g_ir_func_count < 1 { return 1; }
    vs := r64(g_ir_func_var_start, 0);
    if vs < 1 { return 1; }  // 无 globals 行可借位 → 注入前置不满足
    w64(g_ir_func_var_start, 0, vs - 1);
    return 0;
}

// --- Load（v7-only：校验 Header + 段表规范布局 + 逐段越界拒绝；version ≠ 7
// = v6 读路径退役——拒绝）---
// 内核完备 Task 1（语义对象模型）：loader 产出 = 语义对象载入 + 守卫——
// NOD→g_ir_instrs 线性重建段移出（调度重建 = 实例事务 build_linear_schedule，
// regalloc.cr；入口 = corearch.cr / arch/linux/ld/main.cr 在 load 成功后调用）。
// 解析序：STR → SYM（globals/funcs 声明区重建 var 命名空间行序）→ REG
// （nstart/ncount 派生 + func 指令边界回填）→ NOD（36B——28B 语义字段入对象
// 缓冲 g_v7_nod_sem（对象留存形态裁决 (a)，邻接域入 g_v7_nod_meta——不再写
// 线性流）→ ENT（28B → 内存 24B 表，去掉 version、live_end 半开转回闭区间
// −1；块界与 SYM func first/last 对照）→ EDG（邻接连续段校验 + 拓扑不变量
// + 入 g_v7_edges 缓冲）。守卫消费 = NOD 计数（局部 instr_cnt）+ 邻接域
// （g_v7_nod_meta）+ REG 派生边界——全程零线性流（iri_*/g_ir_instrs）依赖。
// 内存态（g_ir_vars 行 id=行序 / g_ir_globals var_idx=行序 / func 七数组 /
// g_sgs）与 v6 加载结果逐字节一致；线性流由 build_linear_schedule 从对象
// 缓冲重建，与原重建段产物逐字节一致（28B 语义字段与 v6 逐字段相同，文件
// 布局变化不影响下游——ELF 发射）。

fn load_ccr(data: string, fsize: int) -> int {
    if fsize < 16 { return -1; }  // header

    pos : ., mut = 0;

    // Magic
    magic := buf_read_u32(data, pos); pos = pos + 4;
    if magic != CCR_MAGIC { return -1; }

    // Version — v6-only（无 v5 兼容/转换工具）
    ver := buf_read_u32(data, pos); pos = pos + 4;
    if ver != CCR_VERSION { return -1; }

    // Seg count + reserved
    seg_cnt := buf_read_u32(data, pos); pos = pos + 4;
    rsv := buf_read_u32(data, pos); pos = pos + 4;
    if seg_cnt > (fsize - 16) / 12 { return -1; }

    // 段表：规范布局——tag 必须 = 行号（1..），offset 必须 = 前段尾，段不越界。
    // （段表 {tag, offset, size} 结构本身允段序自由，v7 writer 只用规范序——
    // loader 按规范序校验，非规范布局一律拒绝。）
    seg_off1 : ., mut = 0; seg_off2 : ., mut = 0; seg_off3 : ., mut = 0;
    seg_off4 : ., mut = 0; seg_off5 : ., mut = 0; seg_off6 : ., mut = 0;
    seg_end1 : ., mut = 0; seg_end2 : ., mut = 0; seg_end3 : ., mut = 0;
    seg_end4 : ., mut = 0; seg_end5 : ., mut = 0; seg_end6 : ., mut = 0;
    have1 : ., mut = 0; have2 : ., mut = 0; have3 : ., mut = 0;
    have4 : ., mut = 0; have5 : ., mut = 0; have6 : ., mut = 0;
    cursor : ., mut = 16 + seg_cnt * 12;
    ri : ., mut = 0;
    loop {
        if ri >= seg_cnt { break; }
        if !ccr_has_bytes(pos, 12, fsize) { return -1; }
        tg := buf_read_u32(data, pos); pos = pos + 4;
        soff := buf_read_u32(data, pos); pos = pos + 4;
        ssz := buf_read_u32(data, pos); pos = pos + 4;
        if tg < 1 || tg > 6 { return -1; }
        if tg != ri + 1 { return -1; }              // 规范 tag 序
        if soff != cursor { return -1; }            // 段体连续
        if ssz > fsize - cursor { return -1; }      // 越界拒绝
        // 重复 tag 防御（规范序下不可能，双保险）
        if tg == 1 { if have1 != 0 { return -1; } seg_off1 = soff; seg_end1 = soff + ssz; have1 = 1; }
        if tg == 2 { if have2 != 0 { return -1; } seg_off2 = soff; seg_end2 = soff + ssz; have2 = 1; }
        if tg == 3 { if have3 != 0 { return -1; } seg_off3 = soff; seg_end3 = soff + ssz; have3 = 1; }
        if tg == 4 { if have4 != 0 { return -1; } seg_off4 = soff; seg_end4 = soff + ssz; have4 = 1; }
        if tg == 5 { if have5 != 0 { return -1; } seg_off5 = soff; seg_end5 = soff + ssz; have5 = 1; }
        if tg == 6 { if have6 != 0 { return -1; } seg_off6 = soff; seg_end6 = soff + ssz; have6 = 1; }
        cursor = soff + ssz;
        ri = ri + 1;
    }

    // STR/SYM/NOD/REG 必备（v6 坐标化后 func 指令边界 = root_region span 的
    // 唯一真源，REG 缺段无法重建函数边界）；EDG v7 必落（spec §3.4——文件
    // 语义载体 = NOD+EDG，缺边段 = 格式不一致拒绝）；ENT 可缺（v5 精神：
    // 旧段缺失 = 空表——Task 2 起 corec 恒产实记录，缺段等价空 = loader
    // 兼容语义保留）
    if have1 == 0 || have2 == 0 || have3 == 0 || have5 == 0 || have6 == 0 { return -1; }
    if have4 == 0 { seg_off4 = 0; seg_end4 = 0; }

    // 状态重置（corearch 单次加载；保持可重入）
    g_str_count = 0;
    g_ir_var_count = 0;
    g_ir_instr_count = 0;
    g_ir_func_count = 0;
    g_ir_str_const_count = 0;
    g_struct_count = 0;
    g_enum_count = 0;
    g_sg_count = 0;
    g_ir_global_count = 0;
    g_opt_meta_count = 0;
    g_entry_count = 0;
    g_v7_edge_count = 0;
    g_v7_nod_count = 0;   // 内核完备 Task 1：NOD 对象缓冲计数（NOD 段载入后置位）

    // === STR: strings ===
    pos = seg_off1;
    if !ccr_has_bytes(pos, 4, seg_end1) { return -1; }
    str_cnt := buf_read_u32(data, pos); pos = pos + 4;
    si : ., mut = 0;
    loop {
        if si >= str_cnt { break; }
        if !ccr_has_bytes(pos, 4, seg_end1) { return -1; }
        sl := buf_read_u32(data, pos); pos = pos + 4;
        if !ccr_has_bytes(pos, sl, seg_end1) { return -1; }
        // Allocate buffer for string content
        s := alloc(sl + 1);
        ci : ., mut = 0;
        loop {
            if ci >= sl { break; }
            store8(s, ci, load8(data, pos));
            pos = pos + 1;
            ci = ci + 1;
        }
        store8(s, sl, 0);
        str_intern(s);
        si = si + 1;
    }

    // === SYM: globals（16B each: name u32, type u32, init_val i64）===
    // var 命名空间重建（流式）：全局行 = 记录序 0..G-1（行名/型随本记录携带，
    // v5 的 var 行 = 同源冗余）；id = 行序。后续函数声明区行序相接。
    pos = seg_off2;
    if !ccr_has_bytes(pos, 4, seg_end2) { return -1; }
    gc := buf_read_u32(data, pos); pos = pos + 4;
    if gc > (seg_end2 - seg_off2) / ESZ_GLOBAL_DISK { return -1; }
    grow_ir_globals(gc);
    gi : ., mut = 0;
    loop {
        if gi >= gc { break; }
        if !ccr_has_bytes(pos, ESZ_GLOBAL_DISK, seg_end2) { return -1; }
        gname_ni := buf_read_u32(data, pos); pos = pos + 4;
        gtype := buf_read_u32(data, pos); pos = pos + 4;
        ginit_val := buf_read_i64(data, pos); pos = pos + 8;
        grow_ir_vars(g_ir_var_count + 1);
        gvar := g_ir_var_count;
        irv_set_name(gvar, gname_ni);
        irv_set_id(gvar, gvar);
        irv_set_type(gvar, gtype);
        g_ir_var_count = gvar + 1;
        w64(g_ir_globals, gi * 24, gname_ni);
        w64(g_ir_globals, gi * 24 + 8, gvar);
        w64(g_ir_globals, gi * 24 + 16, ginit_val);
        g_ir_global_count = gi + 1;
        gi = gi + 1;
    }

    // === SYM: funcs（24B 头 + param_ents + var 声明区）===
    // 头字段 = spec §3.2：name/param_count/ret_type/root_region（REG 行 id）/
    // first_ent/last_ent（本函数条目文件范围）。instr/var 范围不落盘：instr =
    // root_region span（REG 段解析后回填），var_start = 声明区行序游标。
    if !ccr_has_bytes(pos, 4, seg_end2) { return -1; }
    func_cnt := buf_read_u32(data, pos); pos = pos + 4;
    if func_cnt > (seg_end2 - pos) / ESZ_FUNC_HEAD_DISK { return -1; }
    grow_ir_func_meta(func_cnt);
    // func 记录临时元数据（REG 段回填/ENT 块界校验用）：{root i64, first i64, last i64}
    fn_meta := alloc((func_cnt + 8) * 24);
    fi : ., mut = 0;
    loop {
        if fi >= func_cnt { break; }
        if !ccr_has_bytes(pos, ESZ_FUNC_HEAD_DISK, seg_end2) { return -1; }
        fname := buf_read_u32(data, pos); pos = pos + 4;
        fpc := buf_read_u32(data, pos); pos = pos + 4;
        fret := buf_read_u32(data, pos); pos = pos + 4;
        froot := buf_read_i32(data, pos); pos = pos + 4;
        ffe := buf_read_i32(data, pos); pos = pos + 4;
        fle := buf_read_i32(data, pos); pos = pos + 4;
        if froot < 0 { return -1; }             // 每函数必有根 region（df_begin_func）
        if ffe < -1 || fle < -1 || (ffe == -1) != (fle == -1) { return -1; }
        w64(g_ir_func_name_idx, fi * 8, fname);
        w64(g_ir_func_param_count, fi * 8, fpc);
        w64(g_ir_func_ret_type, fi * 8, fret);
        w64(fn_meta, fi * 24, froot);
        w64(fn_meta, fi * 24 + 8, ffe);
        w64(fn_meta, fi * 24 + 16, fle);
        // param_ents（i32 each；内存无消费者——只做越界拒绝）
        pj : ., mut = 0;
        loop {
            if pj >= fpc { break; }
            if !ccr_has_bytes(pos, 4, seg_end2) { return -1; }
            pid := buf_read_i32(data, pos); pos = pos + 4;
            if pid < -1 { return -1; }
            pj = pj + 1;
        }
        // var 声明区（行序 = 创建序，前 param_count 个 = 参数）
        if !ccr_has_bytes(pos, 4, seg_end2) { return -1; }
        fvc := buf_read_u32(data, pos); pos = pos + 4;
        if fpc > fvc { return -1; }
        if fvc > (seg_end2 - pos) / ESZ_VARDECL_DISK { return -1; }
        fvs2 := g_ir_var_count;
        w64(g_ir_func_var_start, fi * 8, fvs2);
        dj : ., mut = 0;
        loop {
            if dj >= fvc { break; }
            if !ccr_has_bytes(pos, ESZ_VARDECL_DISK, seg_end2) { return -1; }
            dname := buf_read_u32(data, pos); pos = pos + 4;
            dtype := buf_read_u32(data, pos); pos = pos + 4;
            grow_ir_vars(g_ir_var_count + 1);
            drow := g_ir_var_count;
            irv_set_name(drow, dname);
            irv_set_id(drow, drow);
            irv_set_type(drow, dtype);
            g_ir_var_count = drow + 1;
            dj = dj + 1;
        }
        if g_ir_var_count - fvs2 != fvc { return -1; }
        w64(g_ir_func_var_count, fi * 8, fvc);
        g_ir_func_count = fi + 1;
        fi = fi + 1;
    }

    // === SYM: string constants（4B each）===
    if !ccr_has_bytes(pos, 4, seg_end2) { return -1; }
    str_const_cnt := buf_read_u32(data, pos); pos = pos + 4;
    if str_const_cnt > (seg_end2 - seg_off2) / 4 { return -1; }
    grow_ir_str_consts(str_const_cnt);
    sci : ., mut = 0;
    loop {
        if sci >= str_const_cnt { break; }
        if !ccr_has_bytes(pos, 4, seg_end2) { return -1; }
        scv := buf_read_u32(data, pos); pos = pos + 4; w64(g_ir_str_consts, sci * 8, scv);
        g_ir_str_const_count = sci + 1;
        sci = sci + 1;
    }

    // === SYM: structs ===
    if !ccr_has_bytes(pos, 4, seg_end2) { return -1; }
    struct_cnt := buf_read_u32(data, pos); pos = pos + 4;
    if struct_cnt > (seg_end2 - seg_off2) / 8 { return -1; }
    grow_structs(struct_cnt);
    g_struct_count = struct_cnt;
    sti : ., mut = 0;
    loop {
        if sti >= struct_cnt { break; }
        if !ccr_has_bytes(pos, 8, seg_end2) { return -1; }
        sname_ni := buf_read_u32(data, pos); pos = pos + 4;
        fc := buf_read_u32(data, pos); pos = pos + 4;
        if fc > MAX_STRUCT_FIELDS { println("error: .ccr struct field count exceeds max"); return 1; }
        if fc > (seg_end2 - pos) / 8 { return -1; }
        w64(g_structs, sti * ESZ_STRUCTINFO + OFF_SI_NAME, sname_ni);
        w64(g_structs, sti * ESZ_STRUCTINFO + OFF_SI_FIELD_COUNT, fc);
        // Zero out all field slots and type nodes
        zfi : ., mut = 0;
        loop {
            if zfi >= 16 { break; }
            w64(g_structs, sti * ESZ_STRUCTINFO + OFF_SI_FIELD_NAMES + zfi * 8, 0);
            w64(g_structs, sti * ESZ_STRUCTINFO + OFF_SI_FIELD_TYPES + zfi * 8, 0);
            w64(g_structs, sti * ESZ_STRUCTINFO + OFF_SI_FIELD_TYPE_NODES + zfi * 8, 0);
            zfi = zfi + 1;
        }
        // Zero generic slots
        w64(g_structs, sti * ESZ_STRUCTINFO + OFF_SI_GENERIC_COUNT, 0);
        zgi : ., mut = 0;
        loop { if zgi >= 4 { break; } w64(g_structs, sti * ESZ_STRUCTINFO + OFF_SI_GENERIC_NAMES + zgi * 8, 0); zgi = zgi + 1; }
        // Write field data
        fi2 : ., mut = 0;
        loop {
            if fi2 >= fc { break; }
            fn_ni := buf_read_u32(data, pos); pos = pos + 4;
            ft := buf_read_u32(data, pos); pos = pos + 4;
            w64(g_structs, sti * ESZ_STRUCTINFO + OFF_SI_FIELD_NAMES + fi2 * 8, fn_ni);
            w64(g_structs, sti * ESZ_STRUCTINFO + OFF_SI_FIELD_TYPES + fi2 * 8, ft);
            fi2 = fi2 + 1;
        }
        sti = sti + 1;
    }

    // === SYM: enums ===
    if !ccr_has_bytes(pos, 4, seg_end2) { return -1; }
    enum_cnt := buf_read_u32(data, pos); pos = pos + 4;
    if enum_cnt > (seg_end2 - seg_off2) / 8 { return -1; }
    grow_enums(enum_cnt);
    g_enum_count = enum_cnt;
    ei : ., mut = 0;
    loop {
        if ei >= enum_cnt { break; }
        if !ccr_has_bytes(pos, 8, seg_end2) { return -1; }
        ename_ni := buf_read_u32(data, pos); pos = pos + 4;
        vc := buf_read_u32(data, pos); pos = pos + 4;
        if vc > MAX_ENUM_VARIANTS { println("error: .ccr enum variant count exceeds max"); return 1; }
        if vc > (seg_end2 - pos) / 8 { return -1; }
        w64(g_enums, ei * ESZ_ENUMINFO + OFF_EI_NAME, ename_ni);
        w64(g_enums, ei * ESZ_ENUMINFO + OFF_EI_VARIANT_COUNT, vc);
        // Zero all variant slots
        zvi : ., mut = 0;
        loop {
            if zvi >= 16 { break; }
            w64(g_enums, ei * ESZ_ENUMINFO + OFF_EI_VARIANTS + zvi * OFF_EV_SIZE + OFF_EV_NAME, 0);
            w64(g_enums, ei * ESZ_ENUMINFO + OFF_EI_VARIANTS + zvi * OFF_EV_SIZE + OFF_EV_TYPE_COUNT, 0);
            ztj : ., mut = 0;
            loop { if ztj >= 16 { break; } w64(g_enums, ei * ESZ_ENUMINFO + OFF_EI_VARIANTS + zvi * OFF_EV_SIZE + OFF_EV_TYPES + ztj * 8, 0); ztj = ztj + 1; }
            zvi = zvi + 1;
        }
        w64(g_enums, ei * ESZ_ENUMINFO + OFF_EI_GENERIC_COUNT, 0);
        zgi2 : ., mut = 0;
        loop { if zgi2 >= 4 { break; } w64(g_enums, ei * ESZ_ENUMINFO + OFF_EI_GENERIC_NAMES + zgi2 * 8, 0); zgi2 = zgi2 + 1; }
        // Write variant data
        vi3 : ., mut = 0;
        loop {
            if vi3 >= vc { break; }
            vni := buf_read_u32(data, pos); pos = pos + 4;
            tc := buf_read_u32(data, pos); pos = pos + 4;
            if tc > MAX_VARIANT_TYPES { println("error: .ccr variant type count exceeds max"); return 1; }
            if tc > (seg_end2 - pos) / 4 { return -1; }
            w64(g_enums, ei * ESZ_ENUMINFO + OFF_EI_VARIANTS + vi3 * OFF_EV_SIZE + OFF_EV_NAME, vni);
            w64(g_enums, ei * ESZ_ENUMINFO + OFF_EI_VARIANTS + vi3 * OFF_EV_SIZE + OFF_EV_TYPE_COUNT, tc);
            tf : ., mut = 0;
            loop {
                if tf >= tc { break; }
                tval := buf_read_u32(data, pos); pos = pos + 4;
                w64(g_enums, ei * ESZ_ENUMINFO + OFF_EI_VARIANTS + vi3 * OFF_EV_SIZE + OFF_EV_TYPES + tf * 8, tval);
                tf = tf + 1;
            }
            vi3 = vi3 + 1;
        }
        ei = ei + 1;
    }

    // === SYM: opt_meta ===
    if !ccr_has_bytes(pos, 4, seg_end2) { return -1; }
    mc := buf_read_u32(data, pos); pos = pos + 4;
    mi : ., mut = 0;
    loop {
        if mi >= mc { break; }
        if !ccr_has_bytes(pos, 8, seg_end2) { return -1; }
        mk := buf_read_u32(data, pos); pos = pos + 4;
        md_len := buf_read_u32(data, pos); pos = pos + 4;
        if md_len > OPT_META_STRIDE - 8 || !ccr_has_bytes(pos, md_len, seg_end2) { return -1; }
        // Allocate and store entry
        grow_opt_meta(mi + 1);
        mo := mi * OPT_META_STRIDE;
        w32(g_opt_meta, mo, mk);
        w32(g_opt_meta, mo + 4, md_len);
        di : ., mut = 0;
        loop { if di >= md_len { break; }
            store8(g_opt_meta, mo + 8 + di, load8(data, pos));
            pos = pos + 1;
            di = di + 1;
        }
        g_opt_meta_count = mi + 1;
        mi = mi + 1;
    }

    // === REG: region（24B each——spec §3.5 字段序 {kind, parent, enter_nod,
    // exit_nod, first_ent, last_ent}）===
    // v5 的 nstart/ncount 不落盘——由 enter/exit 派生（不变式 nstart ≡ enter、
    // ncount = exit − enter），内存态与 v5 记录逐字节一致。未闭合（exit < enter）
    // 记录 v6 无法表示 → 拒绝。
    // first/last 校验：SG_FUNC 根行（行序第 k 个 = 函数 k）的区内条目范围必须
    // 与 SYM func 记录 first/last 一致（同信息双写，失配 = 格式不一致）。
    // 函数指令边界重建：func root_region（SYM）→ REG span = [enter, exit)。
    pos = seg_off5;
    if !ccr_has_bytes(pos, 4, seg_end5) { return -1; }
    sg_n := buf_read_u32(data, pos); pos = pos + 4;
    if sg_n > (seg_end5 - seg_off5) / ESZ_SG_DISK { return -1; }
    sg_i : ., mut = 0;
    rfcnt : ., mut = 0;  // 已见 SG_FUNC 根行数（行序 = 函数序 1:1）
    loop {
        if sg_i >= sg_n { break; }
        grow_sg(sg_i + 1);
        f := sg_i * ESZ_SG;
        rk := buf_read_i32(data, pos); pos = pos + 4;
        rp := buf_read_i32(data, pos); pos = pos + 4;
        ren := buf_read_i32(data, pos); pos = pos + 4;
        rex := buf_read_i32(data, pos); pos = pos + 4;
        rfe := buf_read_i32(data, pos); pos = pos + 4;
        rle := buf_read_i32(data, pos); pos = pos + 4;
        if rex < ren { return -1; }  // 未闭合 → ncount 不可派生
        if rfe < -1 || rle < -1 || (rfe == -1) != (rle == -1) { return -1; }
        w64(g_sgs, f + OFF_SG_KIND, rk);
        w64(g_sgs, f + OFF_SG_ENTER, ren);
        w64(g_sgs, f + OFF_SG_EXIT, rex);
        w64(g_sgs, f + OFF_SG_PARENT, rp);
        w64(g_sgs, f + OFF_SG_NSTART, ren);
        w64(g_sgs, f + OFF_SG_NCOUNT, rex - ren);
        if rk == SG_FUNC {
            if rfcnt >= func_cnt { return -1; }  // 根行多于函数记录
            if rfe != r64(fn_meta, rfcnt * 24 + 8) || rle != r64(fn_meta, rfcnt * 24 + 16) {
                return -1;  // REG 根行条目范围 ≠ SYM func 记录
            }
            rfcnt = rfcnt + 1;
        }
        sg_i = sg_i + 1;
    }
    if rfcnt != func_cnt { return -1; }  // 根行少于函数记录（每函数必有根）
    g_sg_count = sg_n;

    // 函数指令边界回填：instr_start = root_region enter, instr_count = exit − enter
    // （根 region span = 函数节点范围——与 v5 func_meta instr_start/count 恒等，
    // 内存态与 v5 逐字节一致）
    bfi : ., mut = 0;
    loop {
        if bfi >= func_cnt { break; }
        rid := r64(fn_meta, bfi * 24);
        if rid < 0 || rid >= sg_n { return -1; }
        fr := rid * ESZ_SG;
        if r64(g_sgs, fr + OFF_SG_KIND) != SG_FUNC { return -1; }
        ren := r64(g_sgs, fr + OFF_SG_ENTER);
        rex := r64(g_sgs, fr + OFF_SG_EXIT);
        if rex < ren { return -1; }
        w64(g_ir_func_instr_start, bfi * 8, ren);
        w64(g_ir_func_instr_count, bfi * 8, rex - ren);
        bfi = bfi + 1;
    }

    // === NOD: instructions（36B each）===
    // 内核完备 Task 1（语义对象模型）：loader 产出 = 对象载入 + 守卫——28B
    // 语义字段 → 内核对象缓冲 g_v7_nod_sem（内存记录 = 盘记录剥离邻接的镜像，
    // 布局 offset 同盘）+ 邻接域 first_edge/edge_count → g_v7_nod_meta
    // （EDG 段校验 + 对象面 nod_edge_first/count 消费）。NOD→g_ir_instrs
    // 线性重建段已移出本函数（调度重建 = 实例事务 build_linear_schedule，
    // regalloc.cr——load 返回后、发射/分派前由入口调用）；g_ir_instrs/
    // g_ir_instr_count 本段不再触碰（重建段原写点全清）。
    pos = seg_off3;
    if !ccr_has_bytes(pos, 4, seg_end3) { return -1; }
    instr_cnt := buf_read_u32(data, pos); pos = pos + 4;
    if instr_cnt > (seg_end3 - seg_off3) / ESZ_NOD_DISK { return -1; }
    g_v7_nod_sem = alloc((instr_cnt + 8) * ESZ_NOD_SEM);
    g_v7_nod_meta = alloc((instr_cnt + 8) * ESZ_NOD_META);
    ii : ., mut = 0;
    loop {
        if ii >= instr_cnt { break; }
        if !ccr_has_bytes(pos, ESZ_NOD_DISK, seg_end3) { return -1; }
        opcode := buf_read_u32(data, pos); pos = pos + 4;
        dest := buf_read_i32(data, pos); pos = pos + 4;
        s1 := buf_read_i64(data, pos); pos = pos + 8;   // 修复 14：s1 64 位
        s2 := buf_read_i32(data, pos); pos = pos + 4;
        s3 := buf_read_i32(data, pos); pos = pos + 4;
        tk := buf_read_u32(data, pos); pos = pos + 4;
        nfe := buf_read_u32(data, pos); pos = pos + 4;  // first_edge（邻接索引）
        nec := buf_read_u32(data, pos); pos = pos + 4;  // edge_count
        // 对象缓冲写（语义字段 = 盘字节镜像——w32/w64 低 32/64 位存储，存取
        // 经 nod_* 访问器 buf_read_* 符号扩展，数值与原重建段消费完全一致）
        w32(g_v7_nod_sem, ii * ESZ_NOD_SEM + OFF_NS_OP, opcode);
        w32(g_v7_nod_sem, ii * ESZ_NOD_SEM + OFF_NS_DEST, dest);
        w64(g_v7_nod_sem, ii * ESZ_NOD_SEM + OFF_NS_S1, s1);
        w32(g_v7_nod_sem, ii * ESZ_NOD_SEM + OFF_NS_S2, s2);
        w32(g_v7_nod_sem, ii * ESZ_NOD_SEM + OFF_NS_S3, s3);
        w32(g_v7_nod_sem, ii * ESZ_NOD_SEM + OFF_NS_TK, tk);
        w64(g_v7_nod_meta, ii * ESZ_NOD_META, nfe);
        w64(g_v7_nod_meta, ii * ESZ_NOD_META + 8, nec);
        ii = ii + 1;
    }
    g_v7_nod_count = instr_cnt;

    // GC-3（SYM 评审 M1）：REG root span 对 NOD 空间上界校验——函数指令边界
    // （root_region span）在 REG 段解析时回填，instr_cnt 直到 NOD 段才可知；
    // 彼时只查了 rex ≥ ren（未闭合），无上界 → 越界 span 通过后 ELF 发射在
    // NOD 空间外读指令（缓冲外静默/崩溃）。逐函数校验 instr_start + count
    // ≤ instr_cnt（含负值拒绝；风格与 ENT ele > instr_cnt 拒绝一致——载荷
    // 消费前的最后一次可拒绝点）。
    rfi : ., mut = 0;
    loop {
        if rfi >= func_cnt { break; }
        ris := r64(g_ir_func_instr_start, rfi * 8);
        ric := r64(g_ir_func_instr_count, rfi * 8);
        if ris < 0 || ric < 0 || ris + ric > instr_cnt { return -1; }
        rfi = rfi + 1;
    }

    // === ENT: entries（28B each → 内存 24B 表）===
    // 盘上半开 live_end → 内存闭区间 −1；version 字段不入内存（组内序可推）。
    if have4 != 0 {
        pos = seg_off4;
        if !ccr_has_bytes(pos, 4, seg_end4) { return -1; }
        ent_cnt := buf_read_u32(data, pos); pos = pos + 4;
        if ent_cnt > (seg_end4 - seg_off4) / ESZ_ENTRY_DISK { return -1; }
        grow_entries(ent_cnt);
        eii : ., mut = 0;
        loop {
            if eii >= ent_cnt { break; }
            if !ccr_has_bytes(pos, ESZ_ENTRY_DISK, seg_end4) { return -1; }
            ev := buf_read_i32(data, pos); pos = pos + 4;   // var_id
            evr := buf_read_u32(data, pos); pos = pos + 4;  // version（盘上仅校验用）
            ed := buf_read_i32(data, pos); pos = pos + 4;   // def_nod
            els := buf_read_u32(data, pos); pos = pos + 4;  // live_start（含定值）
            ele := buf_read_u32(data, pos); pos = pos + 4;  // live_end（半开）
            eho := buf_read_i32(data, pos); pos = pos + 4;  // home
            efl := buf_read_u32(data, pos); pos = pos + 4;  // flags
            // 语义校验（越界拒绝，先例 ccr 校验风格）
            if evr < 1 { return -1; }
            if ev < 0 || ev >= g_ir_var_count { return -1; }  // var 命名空间 = SYM 行重建总量
            if els >= ele || ele > instr_cnt { return -1; }
            if ed >= 0 {
                if ed >= instr_cnt { return -1; }
                if ed != els { return -1; }   // 定值条目 live_start == def
            }
            // 内存闭区间表
            mo2 := eii * ESZ_ENTRY;
            w32(g_ir_entries, mo2 + OFF_ENTRY_VAR, ev);
            w32(g_ir_entries, mo2 + OFF_ENTRY_DEF, ed);
            w32(g_ir_entries, mo2 + OFF_ENTRY_LS, els);
            w32(g_ir_entries, mo2 + OFF_ENTRY_LE, ele - 1);
            w32(g_ir_entries, mo2 + OFF_ENTRY_HOME, eho);
            w32(g_ir_entries, mo2 + OFF_ENTRY_FLAGS, efl);
            g_entry_count = eii + 1;
            eii = eii + 1;
        }
        // 函数条目段界重建：条目按函数升序成块落盘（compute_entries func_i 升序），
        // 每函数一段 [start, count)——块判定 = var 槽 ∈ 该函数 var 区间（var 槽
        // 全属唯一函数，段序与函数序一致）。重建结果与 SYM func 记录
        // first_ent/last_ent 逐函数对照（同信息双写，失配 = 格式不一致）。
        grow_func_entry_meta(func_cnt);
        pf : ., mut = 0;
        pe : ., mut = 0;
        loop {
            if pf >= func_cnt { break; }
            fvs := r64(g_ir_func_var_start, pf * 8);
            fvc := r64(g_ir_func_var_count, pf * 8);
            pstart := pe;
            w64(g_ir_func_entry_start, pf * 8, pe);
            loop {
                if pe >= g_entry_count { break; }
                pv := buf_read_i32(g_ir_entries, pe * ESZ_ENTRY + OFF_ENTRY_VAR);
                if fvc <= 0 || pv < fvs || pv >= fvs + fvc { break; }
                pe = pe + 1;
            }
            pcnt := pe - pstart;
            w64(g_ir_func_entry_count, pf * 8, pcnt);
            ffe := r64(fn_meta, pf * 24 + 8);
            fle := r64(fn_meta, pf * 24 + 16);
            if pcnt == 0 {
                if ffe != -1 || fle != -1 { return -1; }
            } else {
                if ffe != pstart || fle != pstart + pcnt - 1 { return -1; }
            }
            pf = pf + 1;
        }
        if pe != g_entry_count { return -1; }
    }

    // === EDG: edges（v7 必落；8B each {to_nod u32, kind u32}——所属节点 =
    // 邻接隐含：节点 i 出边连续段 [first_edge, first_edge+edge_count)，first_edge
    // = 前缀累计（v7 spec §3.3 邻接约定）。校验（spec §4 + 守卫面强度保持）：
    //   ① 连续段与 NOD 邻接域逐节点对照（first_edge == 前缀累计；段界不出 EDG）
    //   ② Σ edge_count == edg_count（规则 3；行走完 == 段体大小）
    //   ③ 每条边 to_nod < instr_cnt（NOD 引用界内）+ to_nod > 所属节点
    //      （规则 1 拓扑不变量——数据/state 边前向；自环/后向 = 文件损坏拒绝）
    //   ④ kind ≤ 1（0=数据、1=state；2+ 预留 = 未知边类拒绝）
    // 校验通过后边表入 g_v7_edges 缓冲（文件序连续段——图语义消费通道/调试）。
    // branch/jump 目标 = 操作数引用非边（v7 §4 边界声明）——NOD 操作数不参与
    // 本段校验。
    pos = seg_off6;
    if !ccr_has_bytes(pos, 4, seg_end6) { return -1; }
    edg_cnt := buf_read_u32(data, pos); pos = pos + 4;
    if edg_cnt > (seg_end6 - seg_off6) / ESZ_EDGE_DISK { return -1; }
    v7_buf : string, mut = "";
    if edg_cnt > 0 {
        v7_buf = alloc(edg_cnt * 8);
    }
    g_v7_edges = v7_buf;
    g_v7_edge_count = edg_cnt;
    ei4 : ., mut = 0;
    run_off : ., mut = 0;
    loop {
        if ei4 >= instr_cnt { break; }
        // 邻接域读内核对象缓冲 g_v7_nod_meta（原 nod_edge_meta loader 局部——
        // 内核完备 Task 1 对象留存形态裁决 (a)：对象 = 内核持有物，EDG 守卫
        // 与对象面 nod_edge_first/count 同源；守卫逻辑零改动）
        nfe := r64(g_v7_nod_meta, ei4 * ESZ_NOD_META);
        nec := r64(g_v7_nod_meta, ei4 * ESZ_NOD_META + 8);
        if nfe != run_off { return -1; }       // ① 前缀累计失配（段错位/伪造）
        if run_off + nec > edg_cnt { return -1; }  // ① 节点段越出 EDG 空间
        rec : ., mut = 0;
        loop {
            if rec >= nec { break; }
            if !ccr_has_bytes(pos, ESZ_EDGE_DISK, seg_end6) { return -1; }
            eto := buf_read_u32(data, pos); pos = pos + 4;
            ekind := buf_read_u32(data, pos); pos = pos + 4;
            if ekind > 1 { return -1; }              // ④ 未知边类
            if eto >= instr_cnt { return -1; }       // ③ to 出 NOD 空间
            if eto <= ei4 { return -1; }             // ③ 后向/自环（拓扑不变量）
            w64(v7_buf, (run_off + rec) * 8, eto + ekind * 4294967296);
            rec = rec + 1;
        }
        run_off = run_off + nec;
        ei4 = ei4 + 1;
    }
    if run_off != edg_cnt { return -1; }         // ② Σ edge_count == edg_count
    if pos != seg_end6 { return -1; }            // ② 行走完 == 段体大小

    return 0;
}
