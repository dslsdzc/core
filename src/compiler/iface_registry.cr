// === iface_registry.cr ===
// R2 P2b Task 1：本质条目表（native interface entries）+ `iface_*` 查询 API（spec §2/§2.5）。
//
// 定位：spec §2「一张注册表、检查器统一查表」的**第一段地面**——本文件只**建层**：
//   · 13 条本质条目（8 原生 + product/sequence/ref/ptr/named）= **静态数据**（表内容 = 常量，
//     不缓存任何类型表行号——P1 M1 教训：init_types 的行号序不是可依赖的契约）；
//   · 操作许可位集（`ops`）+ 字面量定型码（`lit_code`）+ 查询 API（`iface_*`）。
// **零消费者、零行为变化**（Task 1 硬口径）：checker/ir_gen/后端一律未接线；表**不 alloc
// `g_types` 行**（先例 `init_builtins` 的 `g_rt_builtin_*` 旁表，checker.cr:261-303）⇒ `.ccr`
// 类型段/行号零扰动。接线在 Task 3（字面量定型）/4（操作许可）/5（容器面）；`ops` 位集本 Task
// 落**空集**（全 0），由 Task 4/5 逐格填——**空集期间不得有消费者**（本 Task 即如此）。
//
// ⚠️ **AK↔TI 下标不 1:1（P1 血泪，硬性）**：`AK_STRING=2` 而 `TI_STR=3`、`AK_BOOL=3` 而
//    `TI_BOOL=2`（ty_shadow.cr:18-26）。本表 `ak`/`ti_row` 两列**逐项按语义写死**，禁止任何
//    数值直传/下标互换；`iface_by_ty_code` 即改动前 `sh_base_ak`（ty_shadow.cr）的语义，逐项分派。
//    守门 = type_selftest.cr 的 `iface.*_ti` 逐条目用例（bool/string 两行互换即红）。
//
// ⚠️ **声明序（本仓库 globals 可见性）**：本文件位于 `checker.cr` **之后**（清单序 =
//    ast→globals→…→checker→type_terms→type_engine→**iface_registry**→ty_shadow→…）⇒
//    **函数**可被 checker.cr 前向引用（既有事实），**变量/常量不可**（globals.cr:290-292 的
//    g_purity_inst 先例）。故本文件的 ESZ_/OFF_ 常量只可在本文件与**其后**的文件
//    （ty_shadow.cr / type_selftest.cr）使用；Task 4/5 若要在 `checker.cr` 里直接写 `IP_*`
//    位下标常量，须把 `IP_*` 声明在 `globals.cr`（否则解析期 Undefined name）。
//
// 现状依据（逐格转录；Task 3/4/5 接线时按此对拍，格注 = 计划 Global Constraints 第 4 条）：
//   lit_code 列 = infer_expr 头部的 5 条内联 if（计划时点 checker.cr:1892-1897；接线时点
//     实测 :1896-1901，偏移 +4）：EXPR_INT→TI_INT /
//     EXPR_DEX→TI_DEX / EXPR_STRING→TI_STR / EXPR_BOOL→TI_BOOL / EXPR_CHAR→TI_CHAR。
//   ti_row 列  = ast.cr:286-293 的 TI_* 常量（**常量，非位置推演**）。
//   ak/kind 列 = checker 侧原子宇宙 13 类（侦查 §4.1）：TYP_BASE→8 原生（经 TY_* 码）、
//     TYP_NAMED/TYP_GENERIC_PARAM/TYP_GENERIC_APPLY→AK_NAMED、TYP_ARRAY/TYP_SLICE→AK_SEQUENCE、
//     TYP_REF→AK_REF、TYP_PTR→AK_PTR、TYP_TUPLE→AK_PRODUCT、TYP_DYN→AK_DYN。
//     **无 AK_SUM/AK_FN 条目**：checker 侧无对应原子（enum 类型行 = TYP_NAMED，checker.cr:982；
//     无函数类型行）。
//   ops 列     = 空集（Task 4/5 按计划逐格填；本 Task 零消费者）。

// ─── 条目布局（40B/条 × 5 字段；与 g_types(24B/条)/ESZ_TYPE_TERM(48B/条) 同族：扁平 i64 缓冲）───
//   {ak, ti_row, name_ni, lit_code, ops}
//   ak       = 原子类（AK_*；type_engine.cr:19-22）
//   ti_row   = 该原子的**规范 checker 类型行**（8 原生 = TI_INT..TI_DYN 常量；结构/命名 = -1）
//   name_ni  = 名字 ni（显示用）——**本 Task 落 -1**，见 iface_registry_init 注记
//   lit_code = **字面量定型**：AST 字面量 kind（EXPR_INT/EXPR_DEX/EXPR_STRING/EXPR_BOOL/
//              EXPR_CHAR）→ 本条目（`iface_lit_ti`/`iface_lit_ak` 的查表键）；-1 = 无字面量
//   ops      = 操作许可位集（bit(OP_*)/bit(UOP_*+20)/bit(IP_*)；见 Task 4 的位下标约定）
ESZ_IFACE_ENTRY : int = 40;
OFF_IE_AK : int = 0;  OFF_IE_TI : int = 8;  OFF_IE_NAME : int = 16;
OFF_IE_LIT : int = 24; OFF_IE_OPS : int = 32;

IFACE_ENTRY_COUNT : int = 13;   // 8 原生 + product/sequence/ref/ptr/named

// ─── 建表（由 init_types() 尾部调用；幂等）───
// 表内容 = 常量（AK_*/TI_*/-1/0）⇒ 不读类型表、不缓存行号、不因 init_types 的重复调用而失效
// （行号空间复用不影响本表——这正是「不缓存行号」的目的；长驻进程 corelsp 每请求 init_types）。
//
// **name_ni = -1（本 Task 的落地口径；与计划文「name_ni = str_intern 显示名」有一处受判据
// 约束的偏差，实测依据如下）**：`.ccr` 的 STR 段 = 编译期 `g_strs` **全量**（ccr_io.cr:537 起
// 逐串落盘；实测 ptr_arith 的 .ccr 含 159 串，其中 load64/fpow2i/g_cir_write_buf 等编译器
// 内部串与源文件无关）⇒ 在本函数里 `str_intern("product")` 之类会把 13 个新串**追加**进
// g_strs ⇒ `.ccr` 逐字节变（Global Constraints 硬判据：「预期逐字节不变；若变 → 停下上报」）。
// 零消费者阶段无一格需要显示名 ⇒ 本 Task 不 interning（name 列留 -1），待**首个消费者**
// （P3 诊断/显示）落地时再一并裁决「是否接受 .ccr STR 段增长」。**不得**为了让本列「看起来
// 完整」而在初始化路径上 str_intern（那是拿硬判据换美观）。
fn iface_registry_init() {
    if g_iface_registry_ok != 0 { return; }   // 幂等（内容恒定，无需重建）
    g_iface_entries = alloc(IFACE_ENTRY_COUNT * ESZ_IFACE_ENTRY);
    g_iface_entry_count = IFACE_ENTRY_COUNT;
    // 8 原生（ti_row 取 TI_* 常量；AK↔TI 逐项分派——bool/string 两行按语义错位书写）
    iface_put(0, AK_INT, TI_INT, -1, EXPR_INT, 0);
    iface_put(1, AK_DEX, TI_DEX, -1, EXPR_DEX, 0);
    iface_put(2, AK_STRING, TI_STR, -1, EXPR_STRING, 0);
    iface_put(3, AK_BOOL, TI_BOOL, -1, EXPR_BOOL, 0);
    iface_put(4, AK_UNIT, TI_UNIT, -1, -1, 0);
    iface_put(5, AK_NEVER, TI_NEVER, -1, -1, 0);
    iface_put(6, AK_CHAR, TI_CHAR, -1, EXPR_CHAR, 0);
    iface_put(7, AK_DYN, TI_DYN, -1, -1, 0);
    // 结构/命名（ti_row = -1 = 类级，无「规范行」）
    iface_put(8, AK_PRODUCT, -1, -1, -1, 0);
    iface_put(9, AK_SEQUENCE, -1, -1, -1, 0);
    iface_put(10, AK_REF, -1, -1, -1, 0);
    iface_put(11, AK_PTR, -1, -1, -1, 0);
    iface_put(12, AK_NAMED, -1, -1, -1, 0);
    g_iface_registry_ok = 1;
}

// 单行写入（照 init_builtins 的 bi_add 先例：表驱动的写入收敛到一处）
fn iface_put(e: int, ak: int, ti: int, name_ni: int, lit_code: int, ops: int) {
    w64(g_iface_entries, e * ESZ_IFACE_ENTRY + OFF_IE_AK, ak);
    w64(g_iface_entries, e * ESZ_IFACE_ENTRY + OFF_IE_TI, ti);
    w64(g_iface_entries, e * ESZ_IFACE_ENTRY + OFF_IE_NAME, name_ni);
    w64(g_iface_entries, e * ESZ_IFACE_ENTRY + OFF_IE_LIT, lit_code);
    w64(g_iface_entries, e * ESZ_IFACE_ENTRY + OFF_IE_OPS, ops);
}

// 未建表守卫（init_types 会建；此处兜「查询早于 init_types」——自测通道/未来调用点不得读空表：
// 空表指针 + 线性扫 = 立即越界读）。照 ty_memo_slot 的 ok 位惰性建表先例（type_engine.cr:256）。
fn iface_ensure() {
    if g_iface_registry_ok == 0 { iface_registry_init(); }
}

// ─── 查询 API（spec §2.5）───
fn iface_count() -> int { return IFACE_ENTRY_COUNT; }

// 原子类 → 条目行号（-1 = 无此原子）
fn iface_entry(ak: int) -> int {
    iface_ensure();
    i : ., mut = 0;
    loop {
        if i >= g_iface_entry_count { break; }
        if r64(g_iface_entries, i * ESZ_IFACE_ENTRY + OFF_IE_AK) == ak { return i; }
        i = i + 1;
    }
    return -1;
}

// 操作许可位集（**spec §2.5 的签名**）；-1/未知原子 → 全 0 = 无许可
fn iface_ops(ak: int) -> int {
    e := iface_entry(ak);
    if e < 0 { return 0; }
    return r64(g_iface_entries, e * ESZ_IFACE_ENTRY + OFF_IE_OPS);
}

// 位测试（1/0；op 已含 UOP/IP 偏置——偏置表见 Task 4 的位下标约定）。
// 位下标越界 → 0（**不得**回绕：位构造是「乘 2」循环，op ≥ 63 会把 i64 位集推成负值 = 全位命中）。
fn iface_permits(ak: int, op: int) -> int {
    if op < 0 { return 0; }
    if op > 62 { return 0; }
    ops := iface_ops(ak);
    if ops == 0 { return 0; }
    bit : ., mut = 1;
    k : ., mut = op;
    loop { if k <= 0 { break; } bit = bit * 2; k = k - 1; }
    if (ops / bit) % 2 != 0 { return 1; }
    return 0;
}

// 字面量 AST kind → 条目行号（-1 = 非字面量 kind）。查表键 = 条目的 lit_code 列
// （13 条线性扫；AST kind 面只有 5 个命中项）。lit_kind < 0 = 条目的「无字面量」哨兵，
// 必须先行拒绝（否则 -1 会把无字面量的条目当成命中）。
fn iface_lit_entry(lit_kind: int) -> int {
    if lit_kind < 0 { return -1; }
    iface_ensure();
    i : ., mut = 0;
    loop {
        if i >= g_iface_entry_count { break; }
        if r64(g_iface_entries, i * ESZ_IFACE_ENTRY + OFF_IE_LIT) == lit_kind { return i; }
        i = i + 1;
    }
    return -1;
}

// 字面量 AST kind → TI_*（-1 = 非字面量 kind）——Task 3 已接线：infer_expr（现址 :1896-1901）的
// 5 个字面量分支逐条改调本函数（表 = 唯一真源；`iface.lit_*` 用例 + `lit.infer_*` 端到端用例对拍）
fn iface_lit_ti(lit_kind: int) -> int {
    e := iface_lit_entry(lit_kind);
    if e < 0 { return -1; }
    return r64(g_iface_entries, e * ESZ_IFACE_ENTRY + OFF_IE_TI);
}

// 字面量 AST kind → AK_*（同上；交叉断言/引擎侧用）
fn iface_lit_ak(lit_kind: int) -> int {
    e := iface_lit_entry(lit_kind);
    if e < 0 { return -1; }
    return r64(g_iface_entries, e * ESZ_IFACE_ENTRY + OFF_IE_AK);
}

// TY_*（基类型码）→ AK_*：逐项语义分派（**唯一实现在此**）；-1 = 无对应。
// P2b Task 2 单源化：桥接层 `sh_base_ak` 已改为**薄委托**本函数（改动前的字面拷贝保留为
// ty_shadow.cr 的 `sh_base_ak_legacy`，仅 type_selftest.cr 全表对拍用，P5 删）。
//   TY_DEX_S → AK_DEX（同值域不同表示——表示层差异不进类型身份，ty_shadow.cr:78-80 已裁决）
//   TY_GENERIC_PARAM → AK_NAMED（泛型参数哨兵 → 命名类，不展开；ty_shadow.cr:86 已裁决）
fn iface_by_ty_code(ty: int) -> int {
    if ty == TY_INT { return AK_INT; }
    if ty == TY_DEX { return AK_DEX; }
    if ty == TY_DEX_S { return AK_DEX; }
    if ty == TY_BOOL { return AK_BOOL; }
    if ty == TY_STRING { return AK_STRING; }
    if ty == TY_UNIT { return AK_UNIT; }
    if ty == TY_NEVER { return AK_NEVER; }
    if ty == TY_CHAR { return AK_CHAR; }
    if ty == TY_GENERIC_PARAM { return AK_NAMED; }
    return -1;
}

// checker 类型行号 → AK_*（-1 = 越界/负）。
// 分派表 = 侦查 §4.1 的 checker 侧原子宇宙 13 类，与条目表的 ak 列同源。
// ⚠ P2b Task 2 边界（**勿混**）：桥接层 `sh_native_ak` **不**调本函数——它保留自己的
// `get_type_kind != TYP_BASE → -1` 门（原生快路径契约：TI_DYN 行经 sh_term_of_ti 的 TYP_DYN
// 分支，结构/命名行走通用路径），只共用上面的 `iface_by_ty_code` 一张 TY 码表。故本函数对
// TYP_DYN 行回 AK_DYN、对结构/命名行回其类，而 sh_native_ak 对同样这些行回 -1——「单源化」
// = 两入口共用**逐项分派表**，不是把两个入口合并成同一语义（type_selftest.cr 的
// `iface.bridge_gate_kept` 把该差异钉在红）。
fn iface_kind_of(ti: int) -> int {
    k := get_type_kind(ti);
    if k < 0 { return -1; }                       // 负值/越界行（get_type_kind 已做范围闸）
    if k == TYP_BASE { return iface_by_ty_code(get_type_data(ti)); }
    if k == TYP_DYN { return AK_DYN; }
    if k == TYP_NAMED { return AK_NAMED; }
    if k == TYP_GENERIC_PARAM { return AK_NAMED; }
    if k == TYP_GENERIC_APPLY { return AK_NAMED; }
    if k == TYP_ARRAY { return AK_SEQUENCE; }
    if k == TYP_SLICE { return AK_SEQUENCE; }
    if k == TYP_REF { return AK_REF; }
    if k == TYP_PTR { return AK_PTR; }
    if k == TYP_TUPLE { return AK_PRODUCT; }
    return -1;                                     // 未知 kind（当前类型表无此情形）
}

// 原子类 → 规范行（8 原生 = TI_*；结构/命名条目 ti_row = -1 ⇒ 恒 -1）
fn iface_ti_of(ak: int) -> int {
    e := iface_entry(ak);
    if e < 0 { return -1; }
    return r64(g_iface_entries, e * ESZ_IFACE_ENTRY + OFF_IE_TI);
}

// 类型项 → AK_*（单一原子；非单一 → -1；⊤ₖ → 其 k）。
// 越界/负项先行拒绝：tt_* 访问器**无范围闸**（约定「调用方保证 0 ≤ i < tt_count()」），
// 直接喂 -1 会读到表前偏移。
fn iface_of_term(t: int) -> int {
    if t < 0 { return -1; }
    if t >= tt_count() { return -1; }
    tg := tt_tag(t);
    if tg == TT_ATOM { return tt_a(t); }
    if tg == TT_TOP_K { return tt_a(t); }
    return -1;                                     // union/inter/not/bot/top/mu/var/nil/cons
}
