// === dyn_arr.cr ===
// Byte helpers + ESZ/OFF constants + grow functions + string pool.

// ============================================================
// Byte helpers
// ============================================================
fn w8(buf: string, pos: int, val: int) { store8(buf, pos, val % 256); }
fn bu8(buf: string, pos: int) -> int { return load8(buf, pos) % 256; }
fn w32(buf: string, pos: int, val: int) {
    b0 : ., mut = val % 256; t1 : ., mut = val / 256;
    b1 : ., mut = t1 % 256; t2 : ., mut = t1 / 256;
    b2 : ., mut = t2 % 256; t3 : ., mut = t2 / 256;
    b3 : ., mut = t3 % 256;
    // Borrow chain for two's complement of negative val (no 4294967296 constant)
    if b0 < 0 { b0 = b0 + 256; b1 = b1 - 1; }
    if b1 < 0 { b1 = b1 + 256; b2 = b2 - 1; }
    if b2 < 0 { b2 = b2 + 256; b3 = b3 - 1; }
    if b3 < 0 { b3 = b3 + 256; }
    store8(buf,pos,b0); store8(buf,pos+1,b1);
    store8(buf,pos+2,b2); store8(buf,pos+3,b3); }
fn r32(buf: string, pos: int) -> int {
    b0 := bu8(buf,pos); b1 := bu8(buf,pos+1);
    b2 := bu8(buf,pos+2); b3 := bu8(buf,pos+3);
    v := b0 + b1*256 + b2*65536;
    if b3 >= 128 { v = v + (b3 - 256) * 16777216; }
    else { v = v + b3 * 16777216; }
    return v; }
fn w64(buf: string, pos: int, val: int) {
    cur : ., mut = val;
    i : ., mut = 0;
    loop {
        if i >= 8 { break; }
        byte : ., mut = cur % 256;
        if byte < 0 { byte = byte + 256; }
        store8(buf, pos + i, byte);
        cur = (cur - byte) / 256;
        i = i + 1;
    }
}
fn r64(buf: string, pos: int) -> int {
    // The low dword is unsigned. Reading it through r32 double-subtracts
    // 2^32 for negative values, e.g. -1 becomes -1 + (-1 * 2^32).
    lo := bu8(buf,pos) + bu8(buf,pos+1)*256 + bu8(buf,pos+2)*65536 + bu8(buf,pos+3)*16777216;
    hi := r32(buf,pos+4);
    hi_part := hi * 65536; hi_part = hi_part * 65536;
    return lo + hi_part; }

// ============================================================
// Element sizes (bytes per element)
// ============================================================
ESZ_TOKEN    : int = 40;     // kind,lexeme,int_val,line,col = 5×8
ESZ_ASTNODE  : int = 72;    // kind,a,b,c,int_val,type_val,data,line,col = 9×8
ESZ_SYMENTRY : int = 32;    // name_idx,kind,type_idx,node_idx = 4×8
ESZ_IRVAR    : int = 24;    // name_idx,id,type_kind = 3×8
ESZ_IRINSTR  : int = 48;    // opcode,dest,src1,src2,src3,type_kind = 6×8
ESZ_FUNCINFO : int = 688;
ESZ_STRUCTINFO : int = 440;
ESZ_ENUMINFO : int = 4408;  // name+variants[16]（含载荷类型节点槽，P3 Task 4）+variant_count+generic_names[4]+generic_count

// Token field offsets
OFF_TK_KIND : int = 0; OFF_TK_LEXEME : int = 8;
OFF_TK_INTVAL : int = 16; OFF_TK_LINE : int = 24; OFF_TK_COL : int = 32;

// ASTNode field offsets
OFF_AS_KIND : int = 0; OFF_AS_A : int = 8; OFF_AS_B : int = 16; OFF_AS_C : int = 24;
OFF_AS_INTVAL : int = 32; OFF_AS_TYPEVAL : int = 40;
OFF_AS_DATA : int = 48; OFF_AS_LINE : int = 56; OFF_AS_COL : int = 64;

// SymEntry field offsets
OFF_SY_NAME : int = 0; OFF_SY_KIND : int = 8;
OFF_SY_TYPE : int = 16; OFF_SY_NODE : int = 24;

// IRVar field offsets
OFF_IRV_NAME : int = 0; OFF_IRV_ID : int = 8; OFF_IRV_TYPE : int = 16;

// IRInstr field offsets
OFF_IRI_OP : int = 0; OFF_IRI_DEST : int = 8;
OFF_IRI_S1 : int = 16; OFF_IRI_S2 : int = 24;
OFF_IRI_S3 : int = 32; OFF_IRI_TK : int = 40;

// FuncInfo offsets
// 形参槽上限：param_types 是**定长内嵌槽区**（跟在 param_count 之后、return_type
// 之前），槽数即硬上限。修复前槽数 = 16 且写入无界 → 第 17 个形参起改写
// return_type/ast_node（TY_INT=0 恰把 ast_node 写成 0 = 节点表首项）→
// 「TF01 误归 + .ccr name_idx/param_count=0 + rc=0 产物崩」静默误编译
// （TODO #2026-09-10-4，2026-09-11）。64 = 与 ast.cr FuncInfo 镜像 `[int; 64]` 对齐，
// 并覆盖 ≥22（16 栈参 + 6 寄存器参，SysV）的栈清理形。越界 = parser 硬错
// P020（rc=1）+ 下方访问器护栏双保险——**任何情况下不得静默越界写**。
MAX_FN_PARAMS : int = 64;
OFF_FI_NAME : int = 0; OFF_FI_PARAM_COUNT : int = 8;
OFF_FI_PARAM_TYPES : int = 16;                        // 64 槽 × 8B = 512 → 至 527
OFF_FI_RETURN_TYPE : int = 528; OFF_FI_AST_NODE : int = 536;
OFF_FI_GENERIC_NAMES : int = 544; OFF_FI_GENERIC_COUNT : int = 672;
OFF_FI_ISPURE : int = 680;  // 1 = pure (no side effects), 0 = impure

// StructInfo offsets
// 容量批 T3（裁-CAP-2 (a)）：字段槽区**迁侧表**——本槽（原 field_names 首槽）改义为
// `field_base`（侧表起始行）；`OFF_SI_FIELD_TYPES`/`OFF_SI_FIELD_TYPE_NODES` 保留为
// **未用填充**（记录尺寸不变 ⇒ 盘面与外部算术零改动）。
OFF_SI_NAME : int = 0; OFF_SI_FIELD_BASE : int = 8;
OFF_SI_FIELD_TYPES : int = 136; OFF_SI_FIELD_TYPE_NODES : int = 264;   // 保留未用
OFF_SI_FIELD_COUNT : int = 392;
OFF_SI_GENERIC_NAMES : int = 400; OFF_SI_GENERIC_COUNT : int = 432;

// DFNode sizes and offsets
// R2 P5 Task 2（D19 单槽化 α = 槽语义对调 + 辅码显式分离）：类型面**单源**。
//   OFF_DF_TK  (40) = **类型项引用**（g_type_terms 行号；-1 = 无项）= 类型面唯一真源；
//   OFF_DF_AUX (64) = **辅码**（旗标/宽度/计数 + 不可入项的原始类型行码；0 = 无）。
// 契约（四条，缺一即静默类）：
//   ① **字节零变化**：ESZ_DFNODE 保持 72B，两槽只是**语义对调**（原 40 = 混用码、
//      原 64 = 项引用）⇒ `.ccr`（NOD 36B）与 `.cir` 快照（节点 64B）布局零改动，
//      `CCR_VERSION=8` 不 bump；`CIR_CACHE_VER` 当时为 17（**此后由 TODO #2026-09-16-16 批 2 升级到 18**——聚合读结果槽型改声明面形式；**再于 2026-09-17 由批 5（opt-dex）升到 19**——`dex?` 载荷形式规范化；两次同因：旧快照与新语义不等价）。
//   ② **互斥**（D22-②）：辅码 ≠ 0 ⇒ 项 = -1；项 ≥ 0 ⇒ 辅码 = 0（由拆分器构造保证）。
//   ③ **码 = 派生量**（D22-①/D23）：`iri_tk` / `.ccr` NOD / `.cir` 快照里的类型码
//      一律由 `sh_dfn_code_of_slots(项, 辅码)` 派生，**不得**当独立真源存储或读回
//      （派生码逐节点 ≡ 单槽化前的混用码；`.ccr`/`.cir` 面因此逐字节不变）。
//   ④ 写点 = df_create_node（dataflow.cr，本文件不引用桥接符号）+ `.cir` 快照装载
//      侧的**重派生**（cir_cache.cr——盘面只承载派生码，不入项/辅码槽：进程内项
//      引用不得跨进程，D20）。
// 拆分器（(opcode, tk) → (项, 辅码)）单源 = ty_shadow.cr 的 sh_tk_split；既有消费者
// （instr.cr/regalloc/lower_to_core/dump/ccr_io）读的是**派生码**，零改动。
ESZ_DFNODE : int = 72;   // opcode,dest_var,src1,src2,src3,tk_term,first_edge,edge_count,tk_aux = 9x8
OFF_DF_OPCODE : int = 0;     OFF_DF_DEST : int = 8;
OFF_DF_S1 : int = 16;        OFF_DF_S2 : int = 24;
OFF_DF_S3 : int = 32;        OFF_DF_TK : int = 40;   // ★语义（P5 T2）：类型项引用（-1 = 无项）
OFF_DF_FIRST_EDGE : int = 48; OFF_DF_EDGE_COUNT : int = 56;
OFF_DF_AUX : int = 64;   // P5 T2（D19，原 OFF_DF_TK_TERM 槽位）：辅码（0 = 无）

// DFEdge sizes and offsets
ESZ_DFEDGE : int = 32;   // from_node,to_node,next_out,kind = 4x8
OFF_DFE_FROM : int = 0;  OFF_DFE_TO : int = 8;  OFF_DFE_NEXT : int = 16;
OFF_DFE_KIND : int = 24; // 0=data (def-use), 1=state (ordering/termination)

// Entry record (v6 条目版本段：变量 × 定值点切分版本条目，compute_entries 填充)。
// 内存布局 = .ccr v6 落盘格式逐字节一致（24B/条，六字段各 4B，w32/r32 LE 存取）：
// var_idx u32, def_instr i32, live_start i32, live_end i32, home i32, flags u32。
ESZ_ENTRY   : int = 24;
OFF_ENTRY_VAR   : int = 0;    // 全局 IR 变量索引
OFF_ENTRY_DEF   : int = 4;    // 定值指令全局索引（-1 = 无定值）
OFF_ENTRY_LS    : int = 8;    // 版本存在区间起点（全局指令序）
OFF_ENTRY_LE    : int = 12;   // 版本存在区间终点（全局指令序）
OFF_ENTRY_HOME  : int = 16;   // 分配槽位（-1 = 未分配）
OFF_ENTRY_FLAGS : int = 20;   // 位 0 预留：无配方（条款 4b）

// Subgraph entry (48 bytes each)
ESZ_SG   : int = 48;
OFF_SG_KIND   : int = 0;   // 0=func, 1=loop, 2=for, 3=flow, 4=unsafe
OFF_SG_ENTER  : int = 8;   // enter seq number (instruction index)
OFF_SG_EXIT   : int = 16;  // exit seq number
OFF_SG_PARENT : int = 24;  // parent subgraph index
OFF_SG_NSTART : int = 32;  // first DFNode index
OFF_SG_NCOUNT : int = 40;  // node count

SG_FUNC   : int = 0;
SG_LOOP   : int = 1;
SG_FOR    : int = 2;
SG_FLOW   : int = 3;
SG_UNSAFE : int = 4;
SG_IF     : int = 5;  // conditional region: covers [condition, merge)

// InterfaceInfo: fixed-size entry per interface
// Header(24) + methods[16] * method_entry(240) = 3864 total（R2 P4 Task 3：168 → 240，
//   + 类型项槽 72B——见下 OFF_IFM_PARAM_TERMS/OFF_IFM_RET_TERM 注）
ESZ_IFACEINFO : int = 3864;
OFF_IF_NAME : int = 0; OFF_IF_METHOD_COUNT : int = 8; OFF_IF_GENERIC_COUNT : int = 16;
OFF_IF_METHODS : int = 24;  // first method entry
// Each method entry: name_idx(8) + param_count(8) + ret_ti(8) + param_types[8](64)
//   + param_nodes[8](64) + ret_node(8) + self_mode(8) + param_terms[8](64) + ret_term(8) = 240 bytes
// R2 P3b Task 6（Step 1 签名类型项化）：**裸码槽保留**（`param_types` / `ret_ti`）——
//   S6 站点（checker 的泛型方法调用返回型映射）的值域 = 映射层编码（TY_*），P2b Task 6 已把
//   该域**显式化钉住**（t6_S6_* 行为用例）⇒ 不得改；新增**类型节点**槽 = 签名的忠实来源
//   （裸码把非原生类型一律塌缩为 0 = TY_INT，与 int 不可区分）——供 Step 3 的签名项比较
//   （满足判定 / impl 声明面）与 `sh_iface_shape_term` 建项。-1 = 无节点（哨兵；不用 0——
//   节点 0 是合法下标，用 0 会与「首个分配节点」混同）。接收者槽两侧皆无节点（parser 的
//   self 约定，见 self_mode）。
ESZ_IFMETHOD : int = 240;
OFF_IFM_NAME : int = 0; OFF_IFM_PARAM_COUNT : int = 8; OFF_IFM_RET_TI : int = 16;
OFF_IFM_PARAM_TYPES : int = 24;   // first of up to 8 param types (each 8 bytes)   → 24..87
OFF_IFM_PARAM_NODES : int = 88;   // first of up to 8 param type nodes (8B each)  → 88..151
OFF_IFM_RET_NODE : int = 152;     // return type node（-1 = 无，= unit）
OFF_IFM_SELF_MODE : int = 160;    // 接收者模式：0 = 无接收者（首参为普通形参）/ 1 = self /
                                  //   2 = &self / 3 = &mut self（照 EXPR_PARAM 的 int_val 约定）
// R2 P4 Task 3（IFACE 段签名项化）——**类型项槽**（-1 = 不可建/无）：
//   param_terms[8] = 各形参的签名类型项（`sh_iface_sig_param_term`；接收者槽 = unit 占位项）
//   ret_term       = 返回签名类型项（`sh_iface_sig_ret_term`）
// 与 param_nodes/ret_node 的关系：节点槽 = **corec 侧**的签名来源（AST 节点，判定路径消费）；
// 项槽 = **载体面**（IFACE(8) 段落盘 + corearch 读回）——corearch 侧无 AST ⇒ 节点槽恒 -1，
// 项槽是签名在载入侧的唯一忠实表示（二者不同域，不得互相复用）。写侧 = ccr_types.cr 的
// ccr_iface_populate 填充（与段体同一读点）；读侧 = load_ccr 由段填充。**不入 .cir 快照**
// （快照字段清单不含 g_ifaces——见 Task 3 报告 §布局影响面）。
OFF_IFM_PARAM_TERMS : int = 168;  // first of up to 8 param terms (8B each)       → 168..231
OFF_IFM_RET_TERM : int = 232;     // return signature term (-1 = 不可建)
MAX_IFACE_METHOD_PARAMS : int = 8;
// R2 P3b Task 6（Step 1）：方法上限单源化（旧态 = parser 内联字面量 16，与 ESZ_IFACEINFO
// 的槽数隐式绑定）。**本任务显式登记保留**（不解除）：解除需把方法表迁到侧表（全部读点换位），
// 按 B.4-7 的 MAX_* 统一口径「先加护栏、再评估解除」；护栏现状 = 超限**硬错 rc=1**（非静默
// 截断——实测），本任务加钉子用例（test_impl_iface.py 的 limit 组）。
MAX_IFACE_METHODS : int = 16;

// ─── 本质条目表布局（R2 P4 Task 3：自 iface_registry.cr **迁入**）───
// 迁入理由 = IFACE(8) 段的 loader（corearch 侧，ccr_io.cr）要重建 `g_iface_entries`
// 并校验 `native_count == IFACE_ENTRY_COUNT`，而 iface_registry.cr **不入 corearch
// 清单**（corec-only：内含 checker 耦合的 iface_kind_of 之邻）⇒ 布局常量必须在双
// concat 共享面（本文件 = 共享层；与 ESZ_IFACEINFO/ESZ_IFMETHOD 同居一处的先例）。
// 迁入只放宽声明序（dyn_arr.cr < checker.cr < iface_registry.cr），零语义变化。
//   {ak, ti_row, name_ni, lit_code, ops}：ak = 原子类（AK_*）；ti_row = 规范 checker
//   类型行（8 原生 = TI_* 常量；结构/命名 = -1）；name_ni = 名字 ni（显示/查询用，
//   R2 P4 Task 3 起在注册面 str_intern 填充——裁决 1 接受 STR 段增长）；lit_code =
//   字面量定型（AST kind；-1 = 无）；ops = 操作许可位集。
ESZ_IFACE_ENTRY : int = 40;
OFF_IE_AK : int = 0;  OFF_IE_TI : int = 8;  OFF_IE_NAME : int = 16;
OFF_IE_LIT : int = 24; OFF_IE_OPS : int = 32;
// R2 P4 Task 3（裁决 3+7）：13 → 16（+AK_NULL 原生第九员 + AK_SUM + AK_FN——纯信息面，
// ops = 0 = 无操作许可；判定面零变化由全类型行枚举守门）。
IFACE_ENTRY_COUNT : int = 16;

// 形状条目表 grow（R2 P4 Task 3：自 iface_registry.cr **迁入**——同 IFACE 段 loader
// 读回面：corearch 侧重建 g_iface_shape_* 需表增长；本文件 = grow 助手统一宿主，
// 零依赖（alloc/_dyncpy 皆共享层））。语义/布局零变化（逐字搬迁）。
fn iface_shape_grow(needed: int) {
    if needed <= g_iface_shape_cap { return; }
    nc : ., mut = g_iface_shape_cap * 2;
    if nc < 8 { nc = 8; }
    if nc < needed { nc = needed + 8; }
    nb := alloc(nc * 8);
    _dyncpy(g_iface_shape_names, g_iface_shape_cap * 8, nb);
    g_iface_shape_names = nb;
    nt := alloc(nc * 8);
    _dyncpy(g_iface_shape_terms, g_iface_shape_cap * 8, nt);
    g_iface_shape_terms = nt;
    g_iface_shape_cap = nc;
}

// EnumInfo offsets
// R2 P3 Task 4（T0 交接 ①）：变体载荷**类型节点**槽（照 struct 先例 OFF_SI_FIELD_TYPE_NODES）
// ——裸码槽 OFF_EV_TYPES 的非基型载荷一律塌缩为 0 = TY_INT（parser 的 unpack_type），
// 「载荷是 int」与「载荷是 string/命名类型/泛型形参」不可区分 ⇒ 载荷面（泛型代入/满足判定）
// 在裸码表上不可能忠实。nodes 槽 = parse_type 的产物节点（-1/0 = 无信息）。
// 布局：EnumVariant = name(8) + types[16](128) + type_count(8) + type_nodes[16](128) = 272
// 容量批 T3（裁-CAP-2 (a)）：变体槽区**迁侧表**——`OFF_EI_VARIANTS` 槽改义为 `variant_base`
// （侧表起始行）；`OFF_EV_*` 与 272B 槽区保留为**未用填充**（记录尺寸不变 ⇒ 外部算术零改动）。
OFF_EI_NAME : int = 0; OFF_EI_VARIANTS : int = 8;    // = variant_base
OFF_EI_VARIANT_COUNT : int = 4360;
OFF_EI_GENERIC_NAMES : int = 4368; OFF_EI_GENERIC_COUNT : int = 4400;
OFF_EV_NAME : int = 0; OFF_EV_TYPES : int = 8; OFF_EV_TYPE_COUNT : int = 136;
OFF_EV_TYPE_NODES : int = 144;
OFF_EV_SIZE : int = 272;

// ============================================================
// Copy helper
// ============================================================
fn _dyncpy(src: string, nbytes: int, dst: string) {
    ci : ., mut = 0;
    loop { if ci >= nbytes { break; } w8(dst, ci, bu8(src, ci)); ci = ci + 1; } }

// ============================================================
// Grow helpers for ALL arrays
// ============================================================
fn _grow(buf_name: string, cap_name: int, esz: int, min_init: int) {
    // Helper: cap_name is by value; we return new cap. Caller must assign.
    // Inline expansion needed per array since Core can't do generic.
}
// Each array gets its own grow function with doubling pattern.

fn grow_tokens(needed: int) {
    if needed < g_tok_cap { return; }
    nc : ., mut = g_tok_cap * 2; if nc < 128 { nc = 128; } if nc < needed { nc = needed + 128; }
    nb := alloc(nc * ESZ_TOKEN); _dyncpy(g_tokens, g_tok_cap * ESZ_TOKEN, nb);
    g_tokens = nb; g_tok_cap = nc; }

fn grow_ast(needed: int) {
    if needed < g_ast_cap { return; }
    nc : ., mut = g_ast_cap * 2; if nc < 128 { nc = 128; } if nc < needed { nc = needed + 128; }
    nb := alloc(nc * ESZ_ASTNODE); _dyncpy(g_ast, g_ast_cap * ESZ_ASTNODE, nb);
    g_ast = nb; g_ast_cap = nc; }

fn grow_syms(needed: int) {
    if needed < g_sym_cap { return; }
    nc : ., mut = g_sym_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * ESZ_SYMENTRY); _dyncpy(g_syms, g_sym_cap * ESZ_SYMENTRY, nb);
    g_syms = nb; g_sym_cap = nc; }

fn grow_types(needed: int) {
    if needed < g_type_cap { return; }
    nc : ., mut = g_type_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    // R2 P4 Task 2：行尺寸经 ESZ_TYPE_ROW 单源（globals.cr——与 alloc_type/
    // TYPE 段序列化同源；原为字面量 24）。
    nb := alloc(nc * ESZ_TYPE_ROW); _dyncpy(g_types, g_type_cap * ESZ_TYPE_ROW, nb);
    g_types = nb; g_type_cap = nc; }

fn grow_funcs(needed: int) {
    if needed < g_func_cap { return; }
    nc : ., mut = g_func_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * ESZ_FUNCINFO); _dyncpy(g_funcs, g_func_cap * ESZ_FUNCINFO, nb);
    g_funcs = nb; g_func_cap = nc; }

fn grow_structs(needed: int) {
    if needed < g_struct_cap { return; }
    nc : ., mut = g_struct_cap * 2; if nc < 32 { nc = 32; } if nc < needed { nc = needed + 32; }
    nb := alloc(nc * ESZ_STRUCTINFO); _dyncpy(g_structs, g_struct_cap * ESZ_STRUCTINFO, nb);
    g_structs = nb; g_struct_cap = nc; }

fn grow_enums(needed: int) {
    if needed < g_enum_cap { return; }
    nc : ., mut = g_enum_cap * 2; if nc < 16 { nc = 16; } if nc < needed { nc = needed + 16; }
    nb := alloc(nc * ESZ_ENUMINFO); _dyncpy(g_enums, g_enum_cap * ESZ_ENUMINFO, nb);
    g_enums = nb; g_enum_cap = nc; }

fn grow_ifaces(needed: int) {
    if needed < g_iface_cap { return; }
    nc : ., mut = g_iface_cap * 2; if nc < 4 { nc = 4; } if nc < needed { nc = needed + 4; }
    nb := alloc(nc * ESZ_IFACEINFO); _dyncpy(g_ifaces, g_iface_cap * ESZ_IFACEINFO, nb);
    g_ifaces = nb; g_iface_cap = nc; }

fn grow_ir_vars(needed: int) {
    if needed < g_ir_var_cap { return; }
    nc : ., mut = g_ir_var_cap * 2; if nc < 128 { nc = 128; } if nc < needed { nc = needed + 128; }
    nb := alloc(nc * ESZ_IRVAR); _dyncpy(g_ir_vars, g_ir_var_cap * ESZ_IRVAR, nb);
    g_ir_vars = nb; g_ir_var_cap = nc; }

fn grow_ir_instrs(needed: int) {
    if needed < g_ir_instr_cap { return; }
    nc : ., mut = g_ir_instr_cap * 2; if nc < 128 { nc = 128; } if nc < needed { nc = needed + 128; }
    nb := alloc(nc * ESZ_IRINSTR); _dyncpy(g_ir_instrs, g_ir_instr_cap * ESZ_IRINSTR, nb);
    g_ir_instrs = nb; g_ir_instr_cap = nc; }

fn grow_ir_locals(needed: int) {
    if needed < g_ir_local_cap { return; }
    nc : ., mut = g_ir_local_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 16); _dyncpy(g_ir_locals, g_ir_local_cap * 16, nb);
    g_ir_locals = nb; g_ir_local_cap = nc; }

fn grow_ir_globals(needed: int) {
    if needed < g_ir_global_cap { return; }
    nc : ., mut = g_ir_global_cap * 2; if nc < 16 { nc = 16; } if nc < needed { nc = needed + 16; }
    nb := alloc(nc * 24); _dyncpy(g_ir_globals, g_ir_global_cap * 24, nb);
    g_ir_globals = nb; g_ir_global_cap = nc; }

fn grow_ir_str_consts(needed: int) {
    if needed < g_ir_str_const_cap { return; }
    nc : ., mut = g_ir_str_const_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 8); _dyncpy(g_ir_str_consts, g_ir_str_const_cap * 8, nb);
    g_ir_str_consts = nb; g_ir_str_const_cap = nc; }

fn grow_errors(needed: int) {
    if needed < g_err_cap { return; }
    nc : ., mut = g_err_cap * 2; if nc < 16 { nc = 16; } if nc < needed { nc = needed + 16; }
    nb := alloc(nc * 8); _dyncpy(g_errors, g_err_cap * 8, nb);
    g_errors = nb; g_err_cap = nc; }

fn grow_block_stmts(needed: int) {
    if needed < g_block_stmt_cap { return; }
    nc : ., mut = g_block_stmt_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 8); _dyncpy(g_block_stmts, g_block_stmt_cap * 8, nb);
    g_block_stmts = nb; g_block_stmt_cap = nc; }

fn grow_ir_func_meta(needed: int) { if needed < g_ir_func_name_idx_cap { return; }
    if needed < g_ir_func_name_idx_cap { return; }
    nc : ., mut = g_ir_func_name_idx_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    sz := nc * 8;
    n1 := alloc(sz); _dyncpy(g_ir_func_name_idx, g_ir_func_name_idx_cap*8, n1); g_ir_func_name_idx = n1; 
    n2 := alloc(sz); _dyncpy(g_ir_func_ret_type, g_ir_func_ret_type_cap*8, n2); g_ir_func_ret_type = n2;
    n3 := alloc(sz); _dyncpy(g_ir_func_instr_start, g_ir_func_instr_start_cap*8, n3); g_ir_func_instr_start = n3;
    n4 := alloc(sz); _dyncpy(g_ir_func_instr_count, g_ir_func_instr_count_cap*8, n4); g_ir_func_instr_count = n4;
    n5 := alloc(sz); _dyncpy(g_ir_func_var_start, g_ir_func_var_start_cap*8, n5); g_ir_func_var_start = n5;
    n6 := alloc(sz); _dyncpy(g_ir_func_var_count, g_ir_func_var_count_cap*8, n6); g_ir_func_var_count = n6;
    n7 := alloc(sz); _dyncpy(g_ir_func_param_count, g_ir_func_param_count_cap*8, n7); g_ir_func_param_count = n7;
    g_ir_func_name_idx_cap=nc; g_ir_func_ret_type_cap=nc; g_ir_func_instr_start_cap=nc;
    g_ir_func_instr_count_cap=nc; g_ir_func_var_start_cap=nc; g_ir_func_var_count_cap=nc; g_ir_func_param_count_cap=nc; }

// ============================================================
// Accessor helpers for AST node fields
// ============================================================
fn ast_kind(n: int) -> int { return r64(g_ast, n * ESZ_ASTNODE + OFF_AS_KIND); }
fn ast_a(n: int) -> int { return r64(g_ast, n * ESZ_ASTNODE + OFF_AS_A); }
fn ast_b(n: int) -> int { return r64(g_ast, n * ESZ_ASTNODE + OFF_AS_B); }
fn ast_c(n: int) -> int { return r64(g_ast, n * ESZ_ASTNODE + OFF_AS_C); }
fn ast_int_val(n: int) -> int { return r64(g_ast, n * ESZ_ASTNODE + OFF_AS_INTVAL); }
fn ast_type_val(n: int) -> int { return r64(g_ast, n * ESZ_ASTNODE + OFF_AS_TYPEVAL); }
fn ast_data(n: int) -> int { return r64(g_ast, n * ESZ_ASTNODE + OFF_AS_DATA); }
fn ast_line(n: int) -> int { return r64(g_ast, n * ESZ_ASTNODE + OFF_AS_LINE); }
fn ast_col(n: int) -> int { return r64(g_ast, n * ESZ_ASTNODE + OFF_AS_COL); }

fn ast_set_kind(n: int, v: int) { w64(g_ast, n * ESZ_ASTNODE + OFF_AS_KIND, v); }
fn ast_set_a(n: int, v: int) { w64(g_ast, n * ESZ_ASTNODE + OFF_AS_A, v); }
fn ast_set_b(n: int, v: int) { w64(g_ast, n * ESZ_ASTNODE + OFF_AS_B, v); }
fn ast_set_c(n: int, v: int) { w64(g_ast, n * ESZ_ASTNODE + OFF_AS_C, v); }
fn ast_set_int_val(n: int, v: int) { w64(g_ast, n * ESZ_ASTNODE + OFF_AS_INTVAL, v); }
fn ast_set_type_val(n: int, v: int) { w64(g_ast, n * ESZ_ASTNODE + OFF_AS_TYPEVAL, v); }
fn ast_set_data(n: int, v: int) { w64(g_ast, n * ESZ_ASTNODE + OFF_AS_DATA, v); }
fn ast_set_line(n: int, v: int) { w64(g_ast, n * ESZ_ASTNODE + OFF_AS_LINE, v); }
fn ast_set_col(n: int, v: int) { w64(g_ast, n * ESZ_ASTNODE + OFF_AS_COL, v); }

fn ast_alloc(kind: int, a: int, b: int, c: int, iv: int, tv: int, d: int, line: int, col: int) -> int {
    idx := g_ast_count;
    grow_ast(idx + 1);
    w64(g_ast, idx * ESZ_ASTNODE + OFF_AS_KIND, kind);
    w64(g_ast, idx * ESZ_ASTNODE + OFF_AS_A, a);
    w64(g_ast, idx * ESZ_ASTNODE + OFF_AS_B, b);
    w64(g_ast, idx * ESZ_ASTNODE + OFF_AS_C, c);
    w64(g_ast, idx * ESZ_ASTNODE + OFF_AS_INTVAL, iv);
    w64(g_ast, idx * ESZ_ASTNODE + OFF_AS_TYPEVAL, tv);
    w64(g_ast, idx * ESZ_ASTNODE + OFF_AS_DATA, d);
    w64(g_ast, idx * ESZ_ASTNODE + OFF_AS_LINE, line);
    w64(g_ast, idx * ESZ_ASTNODE + OFF_AS_COL, col);
    g_ast_count = idx + 1;
    return idx; }

// Accessor helpers for SymEntry
// ─── R2 P3 Task 4：读取面护栏（n ∉ [0, g_sym_count) ⇒ -1，不触内存）───
// 触发链（本任务实测）：① 本任务退役了内建 Option 注册（collect_decls 早期的一次 def_sym）
// ⇒ 「无类型声明的源文件」在函数注册循环处 g_syms 仍为 **NULL**（首个 def_sym 尚未发生，
// 这是合法状态）；② `collect_decls` 的重复函数检查写的是 `existing_si >= 0 && sym_kind(existing_si)`
// （checker.cr:1202），而 **bootstrap 构建的编译器二进制不求值短路**（T0 §5-③ 实测：`&&`
// 两侧无条件求值）⇒ `sym_kind(-1)` 被求值 → `r64(NULL, 负偏移)` → SIGSEGV（实测 d0 类
// 「只有 fn、无类型声明」的源 rc=139）。修法 = 访问器自身带范围闸（与类型表访问器
// get_type_kind/get_type_data 同款）；合法读零变化，越界/未分配返回 -1（哨兵语义与
// find_gsym 的 -1 一致）。根因（bootstrap 不短路）仍归 T0 §5-③ 登记，不在本任务面内。
fn sym_name(n: int) -> int { if n < 0 || n >= g_sym_count { return -1; } return r64(g_syms, n * ESZ_SYMENTRY + OFF_SY_NAME); }
fn sym_kind(n: int) -> int { if n < 0 || n >= g_sym_count { return -1; } return r64(g_syms, n * ESZ_SYMENTRY + OFF_SY_KIND); }
fn sym_type(n: int) -> int { if n < 0 || n >= g_sym_count { return -1; } return r64(g_syms, n * ESZ_SYMENTRY + OFF_SY_TYPE); }
fn sym_node(n: int) -> int { if n < 0 || n >= g_sym_count { return -1; } return r64(g_syms, n * ESZ_SYMENTRY + OFF_SY_NODE); }
fn sym_set_name(n: int, v: int) { w64(g_syms, n * ESZ_SYMENTRY + OFF_SY_NAME, v); }
fn sym_set_kind(n: int, v: int) { w64(g_syms, n * ESZ_SYMENTRY + OFF_SY_KIND, v); }
fn sym_set_type(n: int, v: int) { w64(g_syms, n * ESZ_SYMENTRY + OFF_SY_TYPE, v); }
fn sym_set_node(n: int, v: int) { w64(g_syms, n * ESZ_SYMENTRY + OFF_SY_NODE, v); }

// IRVar helpers
fn irv_name(n: int) -> int { return r64(g_ir_vars, n * ESZ_IRVAR + OFF_IRV_NAME); }
fn irv_id(n: int) -> int { return r64(g_ir_vars, n * ESZ_IRVAR + OFF_IRV_ID); }
fn irv_type(n: int) -> int { return r64(g_ir_vars, n * ESZ_IRVAR + OFF_IRV_TYPE); }
fn irv_set_name(n: int, v: int) { w64(g_ir_vars, n * ESZ_IRVAR + OFF_IRV_NAME, v); }
fn irv_set_id(n: int, v: int) { w64(g_ir_vars, n * ESZ_IRVAR + OFF_IRV_ID, v); }
fn irv_set_type(n: int, v: int) { w64(g_ir_vars, n * ESZ_IRVAR + OFF_IRV_TYPE, v); }

// IRInstr helpers
fn iri_op(n: int) -> int { return r64(g_ir_instrs, n * ESZ_IRINSTR + OFF_IRI_OP); }
fn iri_dest(n: int) -> int { return r64(g_ir_instrs, n * ESZ_IRINSTR + OFF_IRI_DEST); }
fn iri_s1(n: int) -> int { return r64(g_ir_instrs, n * ESZ_IRINSTR + OFF_IRI_S1); }
fn iri_s2(n: int) -> int { return r64(g_ir_instrs, n * ESZ_IRINSTR + OFF_IRI_S2); }
fn iri_s3(n: int) -> int { return r64(g_ir_instrs, n * ESZ_IRINSTR + OFF_IRI_S3); }
fn iri_tk(n: int) -> int { return r64(g_ir_instrs, n * ESZ_IRINSTR + OFF_IRI_TK); }
fn iri_set_op(n: int, v: int) { w64(g_ir_instrs, n * ESZ_IRINSTR + OFF_IRI_OP, v); }
fn iri_set_dest(n: int, v: int) { w64(g_ir_instrs, n * ESZ_IRINSTR + OFF_IRI_DEST, v); }
fn iri_set_s1(n: int, v: int) { w64(g_ir_instrs, n * ESZ_IRINSTR + OFF_IRI_S1, v); }
fn iri_set_s2(n: int, v: int) { w64(g_ir_instrs, n * ESZ_IRINSTR + OFF_IRI_S2, v); }
fn iri_set_s3(n: int, v: int) { w64(g_ir_instrs, n * ESZ_IRINSTR + OFF_IRI_S3, v); }
fn iri_set_tk(n: int, v: int) { w64(g_ir_instrs, n * ESZ_IRINSTR + OFF_IRI_TK, v); }

// 变量名查询（原定义于 ir_gen.cr——2026-09-07 regalloc 移后端随迁本文件：
// corearch 闭包不含 ir_gen.cr，regalloc.cr 判定/注入打印消费本函数；双侧共享）
fn get_ir_var_name(var_idx: int) -> string {
    if var_idx >= 0 && var_idx < g_ir_var_count {
        ni := irv_name(var_idx);
        return istr_get(ni);
    }
    return "";
}

// FuncInfo helpers
fn fi_name(n: int) -> int { return r64(g_funcs, n * ESZ_FUNCINFO + OFF_FI_NAME); }
fn fi_param_count(n: int) -> int { return r64(g_funcs, n * ESZ_FUNCINFO + OFF_FI_PARAM_COUNT); }
fn fi_return_type(n: int) -> int { return r64(g_funcs, n * ESZ_FUNCINFO + OFF_FI_RETURN_TYPE); }
fn fi_ast_node(n: int) -> int { return r64(g_funcs, n * ESZ_FUNCINFO + OFF_FI_AST_NODE); }
fn fi_generic_count(n: int) -> int { return r64(g_funcs, n * ESZ_FUNCINFO + OFF_FI_GENERIC_COUNT); }
fn fi_param_type(n: int, pi: int) -> int {
    if pi < 0 || pi >= MAX_FN_PARAMS { return 0; }  // 越界 = 槽区外（读护栏；写侧同护栏 + parser 硬错）
    return r64(g_funcs, n * ESZ_FUNCINFO + OFF_FI_PARAM_TYPES + pi * 8); }
fn fi_generic_name(n: int, gi: int) -> int { return r64(g_funcs, n * ESZ_FUNCINFO + OFF_FI_GENERIC_NAMES + gi * 8); }
fn fi_set_name(n: int, v: int) { w64(g_funcs, n * ESZ_FUNCINFO + OFF_FI_NAME, v); }
fn fi_set_param_count(n: int, v: int) { w64(g_funcs, n * ESZ_FUNCINFO + OFF_FI_PARAM_COUNT, v); }
fn fi_set_param_type(n: int, pi: int, v: int) {
    if pi < 0 || pi >= MAX_FN_PARAMS { return; }  // 槽区护栏：越界写会踩 return_type/ast_node/generic_*/ispure（TODO #2026-09-10-4 根源）
    w64(g_funcs, n * ESZ_FUNCINFO + OFF_FI_PARAM_TYPES + pi*8, v); }
fn fi_set_return_type(n: int, v: int) { w64(g_funcs, n * ESZ_FUNCINFO + OFF_FI_RETURN_TYPE, v); }
fn fi_set_ast_node(n: int, v: int) { w64(g_funcs, n * ESZ_FUNCINFO + OFF_FI_AST_NODE, v); }
fn fi_set_generic_name(n: int, gi: int, v: int) { w64(g_funcs, n * ESZ_FUNCINFO + OFF_FI_GENERIC_NAMES + gi*8, v); }
fn fi_set_generic_count(n: int, v: int) { w64(g_funcs, n * ESZ_FUNCINFO + OFF_FI_GENERIC_COUNT, v); }

fn fi_ispure(n: int) -> int { return r64(g_funcs, n * ESZ_FUNCINFO + OFF_FI_ISPURE); }
fn fi_set_ispure(n: int, v: int) { w64(g_funcs, n * ESZ_FUNCINFO + OFF_FI_ISPURE, v); }

// StructInfo helpers
fn si_name(n: int) -> int { return r64(g_structs, n * ESZ_STRUCTINFO + OFF_SI_NAME); }
fn si_field_count(n: int) -> int { return r64(g_structs, n * ESZ_STRUCTINFO + OFF_SI_FIELD_COUNT); }
fn si_generic_count(n: int) -> int { return r64(g_structs, n * ESZ_STRUCTINFO + OFF_SI_GENERIC_COUNT); }
// ─── 容量批 T3（裁-CAP-2 (a)）：结构体字段**侧表**（无硬上限）───
// 布局：记录内 `OFF_SI_FIELD_BASE` = 本记录字段在侧表的起始行；`OFF_SI_FIELD_COUNT` = 计数
// （真值）。三条扁平表按「记录基数 + 字段下标」寻址；高水位 `g_si_f_used` 由
// `si_commit_fields` 提交（记录字段区一次性占用，不重叠）。
fn grow_si_fields(needed: int) {
    if needed <= g_si_f_cap { return; }
    nc := g_si_f_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 8); _dyncpy(g_si_f_names, g_si_f_cap * 8, nb); g_si_f_names = nb;
    tb := alloc(nc * 8); _dyncpy(g_si_f_types, g_si_f_cap * 8, tb); g_si_f_types = tb;
    ob := alloc(nc * 8); _dyncpy(g_si_f_nodes, g_si_f_cap * 8, ob); g_si_f_nodes = ob;
    g_si_f_cap = nc;
}
fn si_field_base(n: int) -> int { return r64(g_structs, n * ESZ_STRUCTINFO + OFF_SI_FIELD_BASE); }
fn si_set_field_base(n: int, v: int) { w64(g_structs, n * ESZ_STRUCTINFO + OFF_SI_FIELD_BASE, v); }
// 提交字段区（base + 计数 ⇒ 高水位）；parser 与 ccr_io 装载共用
fn si_commit_fields(n: int, fc: int) {
    b := si_field_base(n);
    if b < 0 { return; }
    if fc < 0 { return; }
    if b + fc > g_si_f_used { g_si_f_used = b + fc; }
}
// 读护栏（R2 P4 Task 6 / TODO #2026-09-12-2 的**计数为界**版本）：fi 越界（< 0 或 ≥ count）⇒ 回哨兵
// -1（不越读）；在界读 = 侧表取值。
fn si_field_row(n: int, fi: int) -> int {
    if fi < 0 { return -1; }
    if fi >= si_field_count(n) { return -1; }
    b := si_field_base(n);
    if b < 0 { return -1; }
    return b + fi;
}
fn si_field_name(n: int, fi: int) -> int {
    r := si_field_row(n, fi);
    if r < 0 { return -1; }
    return r64(g_si_f_names, r * 8); }
fn si_field_type(n: int, fi: int) -> int {
    r := si_field_row(n, fi);
    if r < 0 { return -1; }
    return r64(g_si_f_types, r * 8); }
fn si_field_type_node(n: int, fi: int) -> int {
    r := si_field_row(n, fi);
    if r < 0 { return -1; }
    return r64(g_si_f_nodes, r * 8); }
fn si_generic_name(n: int, gi: int) -> int { return r64(g_structs, n*ESZ_STRUCTINFO + OFF_SI_GENERIC_NAMES + gi*8); }

// EnumInfo helpers
fn ei_name(n: int) -> int { return r64(g_enums, n * ESZ_ENUMINFO + OFF_EI_NAME); }
fn ei_variant_count(n: int) -> int { return r64(g_enums, n * ESZ_ENUMINFO + OFF_EI_VARIANT_COUNT); }
fn ei_generic_count(n: int) -> int { return r64(g_enums, n * ESZ_ENUMINFO + OFF_EI_GENERIC_COUNT); }
fn ei_generic_name(n: int, gi: int) -> int { return r64(g_enums, n*ESZ_ENUMINFO + OFF_EI_GENERIC_NAMES + gi*8); }
// 读护栏（R2 P4 Task 6 / TODO #2026-09-12-2）：越界 = 槽区外（读会取到 variant_count/generic 槽或邻
// 记录）⇒ 回哨兵（名字/类型码/类型节点 = -1；计数 = 0）。在界调用点（count ≤ 16）行为不变。
// ─── 容量批 T3：枚举变体**侧表**（无硬上限；同 struct 字段形态）───
fn grow_ei_variants(needed: int) {
    if needed <= g_ei_v_cap { return; }
    nc := g_ei_v_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    a := alloc(nc * 8); _dyncpy(g_ei_v_names, g_ei_v_cap * 8, a); g_ei_v_names = a;
    b := alloc(nc * 8); _dyncpy(g_ei_v_tbase, g_ei_v_cap * 8, b); g_ei_v_tbase = b;
    c := alloc(nc * 8); _dyncpy(g_ei_v_tcount, g_ei_v_cap * 8, c); g_ei_v_tcount = c;
    z : ., mut = g_ei_v_cap;
    loop { if z >= nc { break; } w64(b, z * 8, -1); z = z + 1; }   // tbase 新槽 = -1 哨兵
    g_ei_v_cap = nc;
}
fn grow_ei_vtypes(needed: int) {
    if needed <= g_ei_vt_cap { return; }
    nc := g_ei_vt_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    a := alloc(nc * 8); _dyncpy(g_ei_vt_types, g_ei_vt_cap * 8, a); g_ei_vt_types = a;
    b := alloc(nc * 8); _dyncpy(g_ei_vt_nodes, g_ei_vt_cap * 8, b); g_ei_vt_nodes = b;
    g_ei_vt_cap = nc;
}
fn ei_variant_base(n: int) -> int { return r64(g_enums, n * ESZ_ENUMINFO + OFF_EI_VARIANTS); }
fn ei_set_variant_base(n: int, v: int) { w64(g_enums, n * ESZ_ENUMINFO + OFF_EI_VARIANTS, v); }
fn ei_commit_variants(n: int, vc: int) {
    b := ei_variant_base(n);
    if b < 0 { return; }
    if vc < 0 { return; }
    if b + vc > g_ei_v_used { g_ei_v_used = b + vc; }
}
fn ei_variant_row(n: int, vi: int) -> int {
    if vi < 0 { return -1; }
    if vi >= ei_variant_count(n) { return -1; }
    b := ei_variant_base(n);
    if b < 0 { return -1; }
    return b + vi;
}
fn ei_variant_name(n: int, vi: int) -> int {
    r := ei_variant_row(n, vi);
    if r < 0 { return -1; }
    return r64(g_ei_v_names, r * 8); }
fn ei_variant_type_count(n: int, vi: int) -> int {
    r := ei_variant_row(n, vi);
    if r < 0 { return 0; }
    return r64(g_ei_v_tcount, r * 8); }
fn ei_variant_type(n: int, vi: int, ti: int) -> int {
    r := ei_variant_row(n, vi);
    if r < 0 { return -1; }
    if ti < 0 || ti >= r64(g_ei_v_tcount, r * 8) { return -1; }
    tb := r64(g_ei_v_tbase, r * 8);
    if tb < 0 { return -1; }
    return r64(g_ei_vt_types, (tb + ti) * 8); }
// R2 P3 Task 4（T0 交接 ①）：载荷第 ti 个的**类型节点**（-1/0 = 无信息——.ccr 不落本列，
// 序列化读回侧该列恒 0；消费者须以 type_count 为界，不得据 0 反推「节点 0」）。
fn ei_variant_type_node(n: int, vi: int, ti: int) -> int {
    r := ei_variant_row(n, vi);
    if r < 0 { return -1; }
    if ti < 0 || ti >= r64(g_ei_v_tcount, r * 8) { return -1; }
    tb := r64(g_ei_v_tbase, r * 8);
    if tb < 0 { return -1; }
    return r64(g_ei_vt_nodes, (tb + ti) * 8); }

// ─── 枚举/结构体记录**受护访问器**（R2 P4 Task 6；TODO #2026-09-12-2 收口，#2026-09-10-4 同族形态）───
// 背景（TODO #2026-09-12-2 代码级定位；**容量批 T3 起该定长槽区已退役**——字段/变体迁侧表）：EnumVariant 槽区（旧 `MAX_ENUM_VARIANTS` 槽 × `OFF_EV_SIZE`）与
// StructInfo 字段槽区（旧 `MAX_STRUCT_FIELDS` 槽）曾是**定长内嵌槽区**——其后紧跟记录自身的
// count/generic 槽，再往后是**下一条记录**（同一 buffer）⇒ 无界写入既踩自身记录尾也踩邻记录
// （实测：第 17 变体槽起点 = `OFF_EI_VARIANT_COUNT` 自身、槽尾越过 `ESZ_ENUMINFO` 224B）。
// 修复形态**照 TODO #2026-09-10-4 收口**（`fi_param_type`/`fi_set_param_type`）：
//   ① **唯一受护写点** = 本组 setter（parser 全改走它们 ⇒ 未来新调用点亦不可能越界写）；
//   ② 读护栏 = 越界回哨兵（名字/类型节点 = -1 = 无效下标；计数 = 0），**不越读**；
//   ③ 面向用户的拒绝由 parser 的 P022/P023 硬错承担（本层只做内存安全兜底，不代替诊断）。
// count 槽（`ei_variant_count`/`si_field_count` 的写）**不设护栏**——真值是诊断依据，照
// P020 的 `add_func(pc)` 先例（计数保持真实值，超限由硬错拒绝；越界读由②兜底）。
fn ei_set_variant_name(n: int, vi: int, v: int) {
    if vi < 0 { return; }
    b := ei_variant_base(n);
    if b < 0 { return; }
    grow_ei_variants(b + vi + 1);
    if b + vi + 1 > g_ei_v_used { g_ei_v_used = b + vi + 1; }
    w64(g_ei_v_names, (b + vi) * 8, v); }
// 载荷基址**惰性分配**（首个载荷写入时占用高水位；后续增量推进）

fn ei_variant_tbase_ensure(n: int, vi: int) -> int {
    b := ei_variant_base(n);
    if b < 0 { return -1; }
    grow_ei_variants(b + vi + 1);
    r := b + vi;
    tb := r64(g_ei_v_tbase, r * 8);
    if tb < 0 {
        tb = g_ei_vt_used;
        w64(g_ei_v_tbase, r * 8, tb);
    }
    return tb;
}
fn ei_set_variant_type(n: int, vi: int, ti: int, v: int) {
    if vi < 0 || ti < 0 { return; }
    tb := ei_variant_tbase_ensure(n, vi);
    if tb < 0 { return; }
    grow_ei_vtypes(tb + ti + 1);
    w64(g_ei_vt_types, (tb + ti) * 8, v);
    if tb + ti + 1 > g_ei_vt_used { g_ei_vt_used = tb + ti + 1; } }
fn ei_set_variant_type_count(n: int, vi: int, v: int) {
    if vi < 0 { return; }
    b := ei_variant_base(n);
    if b < 0 { return; }
    grow_ei_variants(b + vi + 1);
    w64(g_ei_v_tcount, (b + vi) * 8, v);
    if v > 0 {
        tb := ei_variant_tbase_ensure(n, vi);   // 申报区间整体占位（未写槽亦不与他人重叠）
        if tb >= 0 && tb + v > g_ei_vt_used { g_ei_vt_used = tb + v; }
    } }
fn ei_set_variant_type_node(n: int, vi: int, ti: int, v: int) {
    if vi < 0 || ti < 0 { return; }
    tb := ei_variant_tbase_ensure(n, vi);
    if tb < 0 { return; }
    grow_ei_vtypes(tb + ti + 1);
    w64(g_ei_vt_nodes, (tb + ti) * 8, v);
    if tb + ti + 1 > g_ei_vt_used { g_ei_vt_used = tb + ti + 1; } }
fn si_set_field_name(n: int, fi: int, v: int) {
    if fi < 0 { return; }
    b := si_field_base(n);
    if b < 0 { return; }
    grow_si_fields(b + fi + 1);
    if b + fi + 1 > g_si_f_used { g_si_f_used = b + fi + 1; }
    w64(g_si_f_names, (b + fi) * 8, v); }
fn si_set_field_type(n: int, fi: int, v: int) {
    if fi < 0 { return; }
    b := si_field_base(n);
    if b < 0 { return; }
    grow_si_fields(b + fi + 1);
    if b + fi + 1 > g_si_f_used { g_si_f_used = b + fi + 1; }
    w64(g_si_f_types, (b + fi) * 8, v); }
fn si_set_field_type_node(n: int, fi: int, v: int) {
    if fi < 0 { return; }
    b := si_field_base(n);
    if b < 0 { return; }
    grow_si_fields(b + fi + 1);
    if b + fi + 1 > g_si_f_used { g_si_f_used = b + fi + 1; }
    w64(g_si_f_nodes, (b + fi) * 8, v); }

// ============================================================
// String table helpers (dynamic byte buffer)
// ============================================================
fn grow_g_strs(needed: int) {
    if needed < g_str_cap { return; }
    nc : ., mut = g_str_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 8); _dyncpy(g_strs, g_str_cap * 8, nb);
    g_strs = nb; g_str_cap = nc; }

fn str_hash(s: string) -> int {
    h : ., mut = 5381;
    i : ., mut = 0;
    loop {
        c := load8(s, i);
        if c == 0 { break; }
        h = h * 33 + c;
        i = i + 1; }
    return h; }

// Hash arbitrary bytes (for function body content fingerprinting).
// Uses a multiplicative hash similar to str_hash but with FNV-inspired
// constants for better distribution over byte ranges.
fn hash_bytes(data: string, len: int) -> int {
    h : ., mut = 2166136261;  // FNV offset basis
    i : ., mut = 0;
    loop {
        if i >= len { break; }
        h = h * 16777619;  // FNV prime
        h = h + (load8(data, i) % 256);
        i = i + 1;
    }
    return h;
}

fn _grow_str_hash(ncap: int) {
    // Allocate new table filled with -1, rehash all existing strings
    nb := alloc(ncap * 8);
    i : ., mut = 0;
    loop { if i >= ncap { break; } w64(nb, i * 8, -1); i = i + 1; }

    // Rehash all strings already in g_strs into new table
    si : ., mut = 0;
    loop {
        if si >= g_str_count { break; }
        s := load_str_ptr(g_strs, si * 8);
        h := str_hash(s);
        pos := h % ncap;
        if pos < 0 { pos = -pos; }
        loop {
            if r64(nb, pos * 8) < 0 { w64(nb, pos * 8, si); break; }
            pos = (pos + 1) % ncap; }
        si = si + 1; }
    g_str_hash = nb;
    g_str_hash_cap = ncap; }

fn str_intern(s: string) -> int {
    // Lazy init hash table
    if g_str_hash_cap == 0 { _grow_str_hash(64); }

    // Hash lookup
    h := str_hash(s);
    cap := g_str_hash_cap;
    pos := h % cap;
    if pos < 0 { pos = -pos; }
    loop {
        si := r64(g_str_hash, pos * 8);
        if si < 0 { break; }  // empty slot → not found
        if str_eq(load_str_ptr(g_strs, si * 8), s) != 0 { return si; }
        pos = (pos + 1) % cap; }

    // Not found: insert
    grow_g_strs(g_str_count + 1);
    store_str_ptr(g_strs, g_str_count * 8, s);
    g_str_count = g_str_count + 1;

    // Insert into hash table (pos is the empty slot we found)
    w64(g_str_hash, pos * 8, g_str_count - 1);

    // Auto-rehash if load > 70%
    if g_str_count * 10 > g_str_hash_cap * 7 {
        _grow_str_hash(g_str_hash_cap * 2); }
    return g_str_count - 1; }

fn istr_get(idx: int) -> string {
    if idx < 0 || idx >= g_str_count { return ""; }
    return load_str_ptr(g_strs, idx * 8); }

fn istr_len(idx: int) -> int {
    if idx < 0 || idx >= g_str_count { return 0; }
    return str_len(istr_get(idx)); }

fn str_load8(idx: int, ci: int) -> int {
    if idx < 0 || idx >= g_str_count { return 0; }
    return load8(istr_get(idx), ci); }

fn grow_line_file(needed: int) {
    if needed < g_line_cap { return; }
    nc : ., mut = g_line_cap * 2; if nc < 128 { nc = 128; } if nc < needed { nc = needed + 128; }
    nb := alloc(nc * 8); _dyncpy(g_line_fileid, g_line_cap * 8, nb);
    g_line_fileid = nb; g_line_cap = nc; }
fn grow_segs(needed: int) {
    if needed < g_seg_cap { return; }
    nc : ., mut = g_seg_cap * 2; if nc < 16 { nc = 16; } if nc < needed { nc = needed + 16; }
    sz := nc * 8;
    n1 := alloc(sz); _dyncpy(g_seg_starts, g_seg_cap * 8, n1); g_seg_starts = n1;
    n2 := alloc(sz); _dyncpy(g_seg_fileids, g_seg_cap * 8, n2); g_seg_fileids = n2;
    g_seg_cap = nc; }
fn grow_gen_apply_data(needed: int) {
    if needed < g_gen_apply_data_cap { return; }
    nc : ., mut = g_gen_apply_data_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 8); _dyncpy(g_gen_apply_data, g_gen_apply_data_cap * 8, nb);
    g_gen_apply_data = nb; g_gen_apply_data_cap = nc; }
fn grow_df_nodes(needed: int) {
    if needed < g_df_node_cap { return; }
    nc : ., mut = g_df_node_cap * 2; if nc < 128 { nc = 128; } if nc < needed { nc = needed + 128; }
    nb := alloc(nc * ESZ_DFNODE); _dyncpy(g_df_nodes, g_df_node_cap * ESZ_DFNODE, nb);
    g_df_nodes = nb; g_df_node_cap = nc; }
fn grow_df_node_region(needed: int) {
    if needed < g_df_node_region_cap { return; }
    nc : ., mut = g_df_node_region_cap * 2; if nc < 128 { nc = 128; } if nc < needed { nc = needed + 128; }
    nb := alloc(nc * 8); _dyncpy(g_df_node_region, g_df_node_region_cap * 8, nb);
    g_df_node_region = nb; g_df_node_region_cap = nc; }
fn grow_df_edges(needed: int) {
    if needed < g_df_edge_cap { return; }
    nc : ., mut = g_df_edge_cap * 2; if nc < 128 { nc = 128; } if nc < needed { nc = needed + 128; }
    nb := alloc(nc * ESZ_DFEDGE); _dyncpy(g_df_edges, g_df_edge_cap * ESZ_DFEDGE, nb);
    g_df_edges = nb; g_df_edge_cap = nc; }
fn grow_df_arrays(needed: int) {
    if needed < g_df_cap { return; }
    nc : ., mut = g_df_cap * 2; if nc < 128 { nc = 128; } if nc < needed { nc = needed + 128; }
    sz := nc * 8;
    n1 := alloc(sz); _dyncpy(g_df_var_producer, g_df_cap * 8, n1);
    // 幽灵边修复（v7 Task 0 注 A 裁决 = 播种修复，dataflow.cr/cir_cache.cr 同款）：
    // producer 槽必须对全部 var 下标恒 -1——alloc 新段（零页/复用页）不可依赖，
    // 未定值 var（全局/参数/0 字面量槽）若留 0 =「节点 0」→ df_use_var 产幽灵边
    // 0→X + 自环 (0,0)。增长区显式播种 -1；既有区由 _dyncpy 保留（定值由
    // df_create_node 覆写、缓存放回路径同走本函数 → 未产出 var 保持 -1）。
    zi : ., mut = g_df_cap;
    loop {
        if zi >= nc { break; }
        w64(n1, zi * 8, -1);
        zi = zi + 1;
    }
    g_df_var_producer = n1;
    n2 := alloc(sz); _dyncpy(g_df_func_node_start, g_df_cap * 8, n2); g_df_func_node_start = n2;
    n3 := alloc(sz); _dyncpy(g_df_func_node_count, g_df_cap * 8, n3); g_df_func_node_count = n3;
    g_df_cap = nc; }

fn grow_gen_map(needed: int) {
    if needed < g_gen_map_cap { return; }
    nc : ., mut = g_gen_map_cap * 2; if nc < 8 { nc = 8; } if nc < needed { nc = needed + 8; }
    sz := nc * 8;
    n1 := alloc(sz); _dyncpy(g_gen_map_names, g_gen_map_cap*8, n1); g_gen_map_names = n1;
    n2 := alloc(sz); _dyncpy(g_gen_map_types, g_gen_map_cap*8, n2); g_gen_map_types = n2;
    g_gen_map_cap = nc; }
fn grow_borrow_vars(needed: int) {
    if needed < g_borrow_cap { return; }
    nc : ., mut = g_borrow_cap * 2; if nc < 16 { nc = 16; } if nc < needed { nc = needed + 16; }
    sz := nc * 8;
    n1 := alloc(sz); _dyncpy(g_borrow_vars, g_borrow_cap*8, n1); g_borrow_vars = n1;
    n2 := alloc(sz); _dyncpy(g_borrow_refs, g_borrow_cap*8, n2); g_borrow_refs = n2;
    n3 := alloc(sz); _dyncpy(g_borrow_muts, g_borrow_cap*8, n3); g_borrow_muts = n3;
    g_borrow_cap = nc; }
fn grow_holder(needed: int) {
    if needed < g_holder_cap { return; }
    nc : ., mut = g_holder_cap * 2; if nc < 16 { nc = 16; } if nc < needed { nc = needed + 16; }
    sz := nc * 8;
    n1 := alloc(sz); _dyncpy(g_holder_borrowers, g_holder_cap*8, n1); g_holder_borrowers = n1;
    n2 := alloc(sz); _dyncpy(g_holder_borrowed, g_holder_cap*8, n2); g_holder_borrowed = n2;
    n3 := alloc(sz); _dyncpy(g_holder_is_mut, g_holder_cap*8, n3); g_holder_is_mut = n3;
    g_holder_cap = nc; }

fn grow_global_lets(needed: int) {
    if needed < g_global_lets_cap { return; }
    nc : ., mut = g_global_lets_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 8); _dyncpy(g_global_lets, g_global_lets_cap * 8, nb);
    g_global_lets = nb; g_global_lets_cap = nc; }
fn grow_loop_stack(needed: int) {
    if needed < g_loop_stack_cap { return; }
    nc : ., mut = g_loop_stack_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 24); _dyncpy(g_loop_stack, g_loop_stack_cap * 24, nb);
    g_loop_stack = nb; g_loop_stack_cap = nc; }
fn grow_type_aliases(needed: int) {
    if needed < g_type_alias_cap { return; }
    nc : ., mut = g_type_alias_cap * 2; if nc < 32 { nc = 32; } if nc < needed { nc = needed + 32; }
    nb := alloc(nc * 16); _dyncpy(g_type_aliases, g_type_alias_cap * 16, nb);
    g_type_aliases = nb; g_type_alias_cap = nc; }
fn grow_scope_bounds(needed: int) {
    if needed < g_scope_bounds_cap { return; }
    nc : ., mut = g_scope_bounds_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 8); _dyncpy(g_scope_bounds, g_scope_bounds_cap * 8, nb);
    g_scope_bounds = nb; g_scope_bounds_cap = nc; }
fn grow_methods(needed: int) {
    if needed < g_method_cap { return; }
    nc : ., mut = g_method_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 24); _dyncpy(g_methods, g_method_cap * 24, nb);
    g_methods = nb; g_method_cap = nc; }
fn grow_borrow_markers(needed: int) {
    if needed < g_borrow_scope_markers_cap { return; }
    nc : ., mut = g_borrow_scope_markers_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 8); _dyncpy(g_borrow_scope_markers, g_borrow_scope_markers_cap * 8, nb);
    g_borrow_scope_markers = nb; g_borrow_scope_markers_cap = nc; }

fn istr_eq(idx: int, lit: string) -> int {
    if idx < 0 || idx >= g_str_count { return 0; }
    if str_eq(istr_get(idx), lit) != 0 { return 1; }
    return 0; }

// ============================================================
// Grow functions for x86 backend arrays
// ============================================================

fn grow_x86_vars(needed: int) {
    if needed < g_x86_var_cap { return; }
    nc : ., mut = g_x86_var_cap * 2; if nc < 128 { nc = 128; } if nc < needed { nc = needed + 128; }
    nb := alloc(nc * 8); _dyncpy(g_x86_vars, g_x86_var_cap * 8, nb);
    g_x86_vars = nb; g_x86_var_cap = nc; }

fn grow_is_enum(needed: int) {
    if needed < g_x86_is_enum_cap { return; }
    nc : ., mut = g_x86_is_enum_cap * 2; if nc < 128 { nc = 128; } if nc < needed { nc = needed + 128; }
    nb := alloc(nc * 8); _dyncpy(g_x86_is_enum, g_x86_is_enum_cap * 8, nb);
    g_x86_is_enum = nb; g_x86_is_enum_cap = nc; }

fn grow_is_global(needed: int) {
    if needed < g_x86_global_cap { return; }
    nc : ., mut = g_x86_global_cap * 2; if nc < 128 { nc = 128; } if nc < needed { nc = needed + 128; }
    nb := alloc(nc * 8); _dyncpy(g_x86_is_global, g_x86_global_cap * 8, nb);
    g_x86_is_global = nb; g_x86_global_cap = nc; }

fn grow_global_off(needed: int) {
    if needed < g_x86_global_off_cap { return; }
    nc : ., mut = g_x86_global_off_cap * 2; if nc < 128 { nc = 128; } if nc < needed { nc = needed + 128; }
    nb := alloc(nc * 8); _dyncpy(g_x86_global_off, g_x86_global_off_cap * 8, nb);
    g_x86_global_off = nb; g_x86_global_off_cap = nc; }

fn grow_str_offs(needed: int) {
    if needed < g_x86_str_cap { return; }
    nc : ., mut = g_x86_str_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 8); _dyncpy(g_x86_str_offs, g_x86_str_cap * 8, nb);
    g_x86_str_offs = nb; g_x86_str_cap = nc; }

fn grow_rip_patch(needed: int) {
    if needed < g_x86_rip_patch_cap { return; }
    nc : ., mut = g_x86_rip_patch_cap * 2; if nc < 128 { nc = 128; } if nc < needed { nc = needed + 128; }
    nb1 := alloc(nc * 8); _dyncpy(g_x86_rip_patch_pos, g_x86_rip_patch_cap * 8, nb1); g_x86_rip_patch_pos = nb1;
    nb2 := alloc(nc * 8); _dyncpy(g_x86_rip_patch_globals, g_x86_rip_patch_cap * 8, nb2); g_x86_rip_patch_globals = nb2;
    g_x86_rip_patch_cap = nc; }

// `.so` 扩展索引侧表（第 4 批 #82/#83）：**动态增长**（本仓约定：All arrays are dynamic
// byte buffers, no MAX_* limits——这正是 TODO #2026-09-17-1「容量硬编码 128 + 写入无界」要消灭的形态）。
fn grow_so_side(needed: int) {
    if needed < g_so_side_cap { return; }
    nc : ., mut = g_so_side_cap * 2; if nc < 32 { nc = 32; } if nc < needed { nc = needed + 32; }
    sz := nc * 8;
    n1 := alloc(sz); _dyncpy(g_so_side_name, g_so_side_cap*8, n1); g_so_side_name = n1;
    n2 := alloc(sz); _dyncpy(g_so_side_tags, g_so_side_cap*8, n2); g_so_side_tags = n2;
    n3 := alloc(sz); _dyncpy(g_so_side_type, g_so_side_cap*8, n3); g_so_side_type = n3;
    g_so_side_cap = nc; }

// ─── 批 6 T2：规约标注侧表（动态增长；照本仓「no MAX_* limits」约定）────────────────
fn grow_spec_side(needed: int) {
    if needed < g_spec_cap { return; }
    nc : ., mut = g_spec_cap * 2; if nc < 16 { nc = 16; } if nc < needed { nc = needed + 16; }
    sz := nc * 8;
    n1 := alloc(sz); _dyncpy(g_spec_fn, g_spec_cap*8, n1); g_spec_fn = n1;
    n6 := alloc(sz); _dyncpy(g_spec_fnode, g_spec_cap*8, n6); g_spec_fnode = n6;
    n2 := alloc(sz); _dyncpy(g_spec_kind, g_spec_cap*8, n2); g_spec_kind = n2;
    n3 := alloc(sz); _dyncpy(g_spec_expr, g_spec_cap*8, n3); g_spec_expr = n3;
    n4 := alloc(sz); _dyncpy(g_spec_line, g_spec_cap*8, n4); g_spec_line = n4;
    n5 := alloc(sz); _dyncpy(g_spec_col, g_spec_cap*8, n5); g_spec_col = n5;
    g_spec_cap = nc; }

// 追加一条标注记录（**唯一写点**；源序 ⇒ 索引即源序）。
fn spec_add(fn_ni: int, kind: int, expr: int, line: int, col: int) {
    grow_spec_side(g_spec_count + 1);
    i := g_spec_count;
    w64(g_spec_fn, i * 8, fn_ni);
    w64(g_spec_fnode, i * 8, -1);   // 由 parser 在 EXPR_FN 分配后回填（spec_set_fnode）
    w64(g_spec_kind, i * 8, kind);
    w64(g_spec_expr, i * 8, expr);
    w64(g_spec_line, i * 8, line);
    w64(g_spec_col, i * 8, col);
    g_spec_count = i + 1;
}

// 读访问器（**受护**：越界回哨兵，绝不读邻记录——照 fi_param_type 的护栏体例）。
fn spec_fn(i: int) -> int { if i < 0 || i >= g_spec_count { return -1; } return r64(g_spec_fn, i * 8); }
fn spec_fnode(i: int) -> int { if i < 0 || i >= g_spec_count { return -1; } return r64(g_spec_fnode, i * 8); }
fn spec_set_fnode(i: int, v: int) { if i < 0 || i >= g_spec_count { return; } w64(g_spec_fnode, i * 8, v); }
fn spec_kind(i: int) -> int { if i < 0 || i >= g_spec_count { return -1; } return r64(g_spec_kind, i * 8); }
fn spec_expr(i: int) -> int { if i < 0 || i >= g_spec_count { return -1; } return r64(g_spec_expr, i * 8); }
fn spec_line(i: int) -> int { if i < 0 || i >= g_spec_count { return -1; } return r64(g_spec_line, i * 8); }
fn spec_col(i: int) -> int { if i < 0 || i >= g_spec_count { return -1; } return r64(g_spec_col, i * 8); }

fn grow_ext_rel(needed: int) {
    if needed < g_x86_ext_rel_cap { return; }
    nc : ., mut = g_x86_ext_rel_cap * 2; if nc < 32 { nc = 32; } if nc < needed { nc = needed + 32; }
    sz := nc * 8;
    n1 := alloc(sz); _dyncpy(g_x86_ext_rel_pos, g_x86_ext_rel_cap*8, n1); g_x86_ext_rel_pos = n1;
    n2 := alloc(sz); _dyncpy(g_x86_ext_rel_name, g_x86_ext_rel_cap*8, n2); g_x86_ext_rel_name = n2;
    g_x86_ext_rel_cap = nc; }

fn grow_func_offsets(needed: int) {
    if needed < g_x86_func_offsets_cap { return; }
    nc : ., mut = g_x86_func_offsets_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 16); _dyncpy(g_x86_func_offsets, g_x86_func_offsets_cap * 16, nb);
    g_x86_func_offsets = nb; g_x86_func_offsets_cap = nc; }

fn grow_emit_vars(needed: int) {
    if needed < g_x86_emit_vars_cap { return; }
    nc : ., mut = g_x86_emit_vars_cap * 2; if nc < 128 { nc = 128; } if nc < needed { nc = needed + 128; }
    nb := alloc(nc * 8); _dyncpy(g_x86_emit_vars, g_x86_emit_vars_cap * 8, nb);
    g_x86_emit_vars = nb; g_x86_emit_vars_cap = nc; }

fn grow_pending(needed: int) {
    if needed < g_pending_cap { return; }
    nc : ., mut = g_pending_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 8); _dyncpy(g_pending_pos, g_pending_cap * 8, nb);
    g_pending_pos = nb;
    nb2 := alloc(nc * 8); _dyncpy(g_pending_label, g_pending_cap * 8, nb2);
    g_pending_label = nb2; g_pending_cap = nc; }
fn grow_ret_patch(needed: int) {
    if needed < g_x86_ret_patch_cap { return; }
    nc : ., mut = g_x86_ret_patch_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 8); _dyncpy(g_x86_ret_patch_pos, g_x86_ret_patch_cap * 8, nb);
    g_x86_ret_patch_pos = nb; g_x86_ret_patch_cap = nc; }
fn grow_call_patch(needed: int) {
    if needed < g_x86_call_patch_cap { return; }
    nc : ., mut = g_x86_call_patch_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    n1 := alloc(nc * 8); _dyncpy(g_x86_call_patch_pos, g_x86_call_patch_cap * 8, n1); g_x86_call_patch_pos = n1;
    n2 := alloc(nc * 8); _dyncpy(g_x86_call_patch_name, g_x86_call_patch_cap * 8, n2); g_x86_call_patch_name = n2;
    g_x86_call_patch_cap = nc; }
fn grow_fnaddr_patch(needed: int) {
    if needed < g_x86_fnaddr_patch_cap { return; }
    nc : ., mut = g_x86_fnaddr_patch_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    n1 := alloc(nc * 8); _dyncpy(g_x86_fnaddr_patch_pos, g_x86_fnaddr_patch_cap * 8, n1); g_x86_fnaddr_patch_pos = n1;
    n2 := alloc(nc * 8); _dyncpy(g_x86_fnaddr_patch_name, g_x86_fnaddr_patch_cap * 8, n2); g_x86_fnaddr_patch_name = n2;
    g_x86_fnaddr_patch_cap = nc; }

fn grow_func_cp(needed: int) {
    if needed < g_x86_func_cp_cap { return; }
    nc : ., mut = g_x86_func_cp_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 8); _dyncpy(g_x86_func_cp, g_x86_func_cp_cap * 8, nb);
    g_x86_func_cp = nb; g_x86_func_cp_cap = nc; }

fn grow_mw_tag_off(needed: int) {
    if needed < g_x86_mw_tag_off_cap { return; }
    nc : ., mut = g_x86_mw_tag_off_cap * 2; if nc < 128 { nc = 128; } if nc < needed { nc = needed + 128; }
    nb := alloc(nc * 8); _dyncpy(g_x86_mw_tag_off, g_x86_mw_tag_off_cap * 8, nb);
    g_x86_mw_tag_off = nb; g_x86_mw_tag_off_cap = nc; }

fn grow_mw_jo_patch(needed: int) {
    if needed < g_x86_mw_jo_cap { return; }
    nc : ., mut = g_x86_mw_jo_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 8); _dyncpy(g_x86_mw_jo_pos, g_x86_mw_jo_cap * 8, nb);
    g_x86_mw_jo_pos = nb;
    nb2 := alloc(nc * 8); _dyncpy(g_x86_mw_jo_dest, g_x86_mw_jo_cap * 8, nb2);
    g_x86_mw_jo_dest = nb2;
    nb3 := alloc(nc * 8); _dyncpy(g_x86_mw_jo_is_sub, g_x86_mw_jo_cap * 8, nb3);
    g_x86_mw_jo_is_sub = nb3;
    nb4 := alloc(nc * 8); _dyncpy(g_x86_mw_jo_resume, g_x86_mw_jo_cap * 8, nb4);
    g_x86_mw_jo_resume = nb4;
    g_x86_mw_jo_cap = nc; }

fn grow_mw_oc_patch(needed: int) {
    if needed < g_x86_mw_oc_cap { return; }
    nc : ., mut = g_x86_mw_oc_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 8); _dyncpy(g_x86_mw_oc_pos1, g_x86_mw_oc_cap * 8, nb);
    g_x86_mw_oc_pos1 = nb;
    nb2 := alloc(nc * 8); _dyncpy(g_x86_mw_oc_pos2, g_x86_mw_oc_cap * 8, nb2);
    g_x86_mw_oc_pos2 = nb2;
    nb3 := alloc(nc * 8); _dyncpy(g_x86_mw_oc_s1, g_x86_mw_oc_cap * 8, nb3);
    g_x86_mw_oc_s1 = nb3;
    nb4 := alloc(nc * 8); _dyncpy(g_x86_mw_oc_s2, g_x86_mw_oc_cap * 8, nb4);
    g_x86_mw_oc_s2 = nb4;
    nb5 := alloc(nc * 8); _dyncpy(g_x86_mw_oc_dest, g_x86_mw_oc_cap * 8, nb5);
    g_x86_mw_oc_dest = nb5;
    nb6 := alloc(nc * 8); _dyncpy(g_x86_mw_oc_op, g_x86_mw_oc_cap * 8, nb6);
    g_x86_mw_oc_op = nb6;
    nb7 := alloc(nc * 8); _dyncpy(g_x86_mw_oc_resume, g_x86_mw_oc_cap * 8, nb7);
    g_x86_mw_oc_resume = nb7;
    g_x86_mw_oc_cap = nc; }

fn grow_opt_meta(needed: int) {
    if needed <= g_opt_meta_cap { return; }
    nc : ., mut = g_opt_meta_cap * 2;
    if nc < 16 { nc = 16; }
    if nc < needed { nc = needed + 16; }
    nb := alloc(nc * OPT_META_STRIDE);
    _dyncpy(g_opt_meta, g_opt_meta_count * OPT_META_STRIDE, nb);
    g_opt_meta = nb; g_opt_meta_cap = nc;
}
fn grow_func_code_sz(needed: int) {
    if needed < g_x86_func_code_sz_cap { return; }
    nc : ., mut = g_x86_func_code_sz_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 8); _dyncpy(g_x86_func_code_sz, g_x86_func_code_sz_cap * 8, nb);
    g_x86_func_code_sz = nb; g_x86_func_code_sz_cap = nc; }

fn grow_rodataref(needed: int) {
    if needed < g_x86_rodataref_cap { return; }
    nc : ., mut = g_x86_rodataref_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    n1 := alloc(nc * 8); _dyncpy(g_x86_rodataref_pos, g_x86_rodataref_cap * 8, n1); g_x86_rodataref_pos = n1;
    n2 := alloc(nc * 8); _dyncpy(g_x86_rodataref_ro, g_x86_rodataref_cap * 8, n2); g_x86_rodataref_ro = n2;
    g_x86_rodataref_cap = nc; }

fn grow_alloc_patch(needed: int) {
    if needed < g_x86_alloc_patch_cap { return; }
    nc : ., mut = g_x86_alloc_patch_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 8); _dyncpy(g_x86_alloc_patch_pos, g_x86_alloc_patch_cap * 8, nb);
    g_x86_alloc_patch_pos = nb; g_x86_alloc_patch_cap = nc; }

fn grow_ir_local_scopes(needed: int) {
    if needed < g_ir_local_scopes_cap { return; }
    nc : ., mut = g_ir_local_scopes_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 8); _dyncpy(g_ir_local_scopes, g_ir_local_scopes_cap * 8, nb);
    g_ir_local_scopes = nb; g_ir_local_scopes_cap = nc; }

fn grow_ir_loop_stacks(needed: int) {
    if needed < g_ir_loop_stacks_cap { return; }
    nc : ., mut = g_ir_loop_stacks_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    n1 := alloc(nc * 8); _dyncpy(g_ir_loop_header, g_ir_loop_stacks_cap * 8, n1); g_ir_loop_header = n1;
    n2 := alloc(nc * 8); _dyncpy(g_ir_loop_exit, g_ir_loop_stacks_cap * 8, n2); g_ir_loop_exit = n2;
    g_ir_loop_stacks_cap = nc; }

fn grow_label_poses(needed: int) {
    if needed < g_label_cap { return; }
    nc : ., mut = g_label_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 8); _dyncpy(g_label_poses, g_label_cap * 8, nb);
    g_label_poses = nb; g_label_cap = nc; }

// ============================================================
// Grow functions for newly-converted arrays
// ============================================================

// Diag struct: code(8) + msg(8) + line(8) + col(8) + file_id(8) = 40 bytes
fn grow_diags(needed: int) {
    if needed < g_diag_cap { return; }
    nc : ., mut = g_diag_cap * 2; if nc < 16 { nc = 16; } if nc < needed { nc = needed + 16; }
    nb := alloc(nc * DIAG_REC_SIZE); _dyncpy(g_diags, g_diag_cap * DIAG_REC_SIZE, nb);
    g_diags = nb; g_diag_cap = nc; }

// FileEntry: fileid_ni(8) + path(8) = 16 bytes
fn grow_files(needed: int) {
    if needed < g_file_cap { return; }
    nc : ., mut = g_file_cap * 2; if nc < 16 { nc = 16; } if nc < needed { nc = needed + 16; }
    nb := alloc(nc * 16); _dyncpy(g_files, g_file_cap * 16, nb);
    g_files = nb; g_file_cap = nc; }

// ModEntry: alias_ni(8) + fileid_ni(8) + path(8) = 24 bytes
fn grow_mods(needed: int) {
    if needed < g_mod_cap { return; }
    nc : ., mut = g_mod_cap * 2; if nc < 16 { nc = 16; } if nc < needed { nc = needed + 16; }
    nb := alloc(nc * 24); _dyncpy(g_mods, g_mod_cap * 24, nb);
    g_mods = nb; g_mod_cap = nc; }

// g_mod_func_fileids/names/tis: 3 parallel int arrays, 8 bytes per element each
fn grow_mod_funcs(needed: int) {
    if needed < g_mod_func_cap { return; }
    nc : ., mut = g_mod_func_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    sz := nc * 8;
    n1 := alloc(sz); _dyncpy(g_mod_func_fileids, g_mod_func_cap * 8, n1); g_mod_func_fileids = n1;
    n2 := alloc(sz); _dyncpy(g_mod_func_names, g_mod_func_cap * 8, n2); g_mod_func_names = n2;
    n3 := alloc(sz); _dyncpy(g_mod_func_tis, g_mod_func_cap * 8, n3); g_mod_func_tis = n3;
    g_mod_func_cap = nc; }

// g_mod_path_names: int array, 8 bytes per element
fn grow_mod_paths(needed: int) {
    if needed < g_mod_path_cap { return; }
    nc : ., mut = g_mod_path_cap * 2; if nc < 32 { nc = 32; } if nc < needed { nc = needed + 32; }
    nb := alloc(nc * 8); _dyncpy(g_mod_path_names, g_mod_path_cap * 8, nb);
    g_mod_path_names = nb; g_mod_path_cap = nc; }

// impl-for: pairs of (interface_ni, type_ni), 16 bytes per pair
fn grow_impl_for(needed: int) {
    if needed < g_impl_for_cap { return; }
    nc : ., mut = g_impl_for_cap * 2; if nc < 8 { nc = 8; } if nc < needed { nc = needed + 8; }
    nb := alloc(nc * 16); _dyncpy(g_impl_for, g_impl_for_cap * 16, nb);
    g_impl_for = nb; g_impl_for_cap = nc; }

// Generic param name storage (for <T> syntax parsing)
fn grow_gen_params(needed: int) {
    if needed < g_gen_param_cap { return; }
    nc : ., mut = g_gen_param_cap * 2; if nc < 16 { nc = 16; } if nc < needed { nc = needed + 16; }
    nb := alloc(nc * 8); _dyncpy(g_gen_params, g_gen_param_cap * 8, nb);
    g_gen_params = nb; g_gen_param_cap = nc; }

// Generic constraints: for each (func_idx * MAX_GENERICS + param_idx), stores iface_ni or -1
fn grow_gen_constr(needed: int) {
    if needed < g_generic_constr_cap { return; }
    nc : ., mut = g_generic_constr_cap * 2; if nc < 16 { nc = 16; } if nc < needed { nc = needed + 16; }
    nb := alloc(nc * 8); _dyncpy(g_generic_constr, g_generic_constr_cap * 8, nb);
    g_generic_constr = nb; g_generic_constr_cap = nc; }

// R2 P3 Task 5：结构/枚举泛型约束侧表（键 = row * MAX_GENERICS + gi；索引空间与函数侧分家，
// 见 globals.cr 表注）。增长式样逐字照 grow_gen_constr（同族第三/第四份，语义同构）。
fn grow_sgen_constr(needed: int) {
    if needed < g_sgen_constr_cap { return; }
    nc : ., mut = g_sgen_constr_cap * 2; if nc < 16 { nc = 16; } if nc < needed { nc = needed + 16; }
    nb := alloc(nc * 8); _dyncpy(g_sgen_constr, g_sgen_constr_cap * 8, nb);
    g_sgen_constr = nb; g_sgen_constr_cap = nc; }

fn grow_egen_constr(needed: int) {
    if needed < g_egen_constr_cap { return; }
    nc : ., mut = g_egen_constr_cap * 2; if nc < 16 { nc = 16; } if nc < needed { nc = needed + 16; }
    nb := alloc(nc * 8); _dyncpy(g_egen_constr, g_egen_constr_cap * 8, nb);
    g_egen_constr = nb; g_egen_constr_cap = nc; }

// R2 P3 Task 5（Step 4）：调用点绑定侧表增长（i64 顺序追加，无洞——与上面两张稀疏表不同）
fn grow_gen_binds(needed: int) {
    if needed < g_gen_binds_cap { return; }
    nc : ., mut = g_gen_binds_cap * 2; if nc < 64 { nc = 64; } if nc < needed { nc = needed + 64; }
    nb := alloc(nc * 8); _dyncpy(g_gen_binds, g_gen_binds_cap * 8, nb);
    g_gen_binds = nb; g_gen_binds_cap = nc; }

// 结构/枚举第 gi 个泛型形参的约束名 ni（-1 = 无约束/越界）。读取面护栏（照 SI 访问器惯例：
// 越界不越读——gi 上限 MAX_GENERICS、行下标上限计数）。
fn si_gen_constr(n: int, gi: int) -> int {
    if n < 0 || gi < 0 || gi >= MAX_GENERICS { return -1; }
    idx := n * MAX_GENERICS + gi;
    if idx >= g_sgen_constr_count { return -1; }
    return r64(g_sgen_constr, idx * 8); }

fn ei_gen_constr(n: int, gi: int) -> int {
    if n < 0 || gi < 0 || gi >= MAX_GENERICS { return -1; }
    idx := n * MAX_GENERICS + gi;
    if idx >= g_egen_constr_count { return -1; }
    return r64(g_egen_constr, idx * 8); }

fn grow_sg(n: int) {
    if n < g_sg_cap { return; }
    nc := g_sg_cap;
    if nc == 0 { nc = 16; }
    loop { if nc > n { break; } nc = nc * 2; }
    nb := alloc(nc * ESZ_SG);
    if g_sg_cap > 0 { _dyncpy(g_sgs, g_sg_cap * ESZ_SG, nb); }
    g_sgs = nb;
    g_sg_cap = nc; }

fn grow_pts(n: int) {
    if n < g_pts_cap { return; }
    nc := g_pts_cap;
    if nc == 0 { nc = 16; }
    loop { if nc > n { break; } nc = nc * 2; }
    nb := alloc(nc * 8);
    if g_pts_cap > 0 { _dyncpy(g_pts, g_pts_cap * 8, nb); }
    g_pts = nb; g_pts_cap = nc; }

fn grow_offsets(n: int) {
    if n < g_offsets_cap { return; }
    nc := g_offsets_cap;
    if nc == 0 { nc = 16; }
    loop { if nc > n { break; } nc = nc * 2; }
    nb := alloc(nc * 8);
    if g_offsets_cap > 0 { _dyncpy(g_offsets, g_offsets_cap * 8, nb); }
    g_offsets = nb; g_offsets_cap = nc; }
