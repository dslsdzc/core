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
//   ops 列     = **Task 4 逐格填写**（Task 1 落空集）——每格 = 现状 checker.cr 的判定，
//     逐格注现状行号（见 iface_registry_init 内的组位集）：算术门 ADD..MOD **只含 int/dex**
//     （现状「两层结构」：早退规则（串拼接/指针算术/指针差）留代码 = 结果规则，本列只记门）。
//     消费点 = checker.cr 的三个门（ANY 算术 :1959 / ALL 逻辑 :1969 / ONE 条件 :2274+:2385 ——
//     **行号一律为接线前实测**；接线后同处 +4，按内容定址）。
//     **Task 5 消费点（单点接线，逐格台账见实施报告 §5 / 事实表 §8）**：`IP_INDEX` → checker.cr 索引面
//     兜底拒绝（接线前 :2659；接线后门体即原 TK01 调用）——见 iface_registry_init 的
//     AK_STRING/AK_SEQUENCE 条目注。**其余容器位本批不接线**（各有实测理由，不接不代表位错）：
//     `IP_INDEX_RANGE`（range 分支的非数组落空**无诊断** ⇒ 门是恒真门 = 空转）、`IP_FIELD`
//     （EXPR_FIELD 全形 rc=0、无任何诊断路径 ⇒ 同上）、`IP_METHOD`（dyn 消费点的谓词是**逐具体
//     行的方法表成员判定**（`type_has_method` 名拼接），非「原子类是否有方法面」——类级门会
//     **抑制** int/string 行今日的 EC_N_METHOD（实测 D1/D4）⇒ 接线 = 放宽）、`IP_AS`
//     （EXPR_AS 除 PTR 结果规则外恒等透传、无诊断）。四项均为 P3 收紧旋钮（登记，未接线）。

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

// 位构造（乘 2 循环，照既有 dyn_set_type 惯例——本语言无移位运算符）。下标语义见 globals.cr
// 的 IP_* 块；n ≥ 63 时 i64 负号翻转（= 全位命中）由 `iface_permits` 的越界闸拒绝，本函数只
// 供表内**已知常量**使用，不做校验（表内容 = 常量，n 恒 < 32）。
fn iface_bit(n: int) -> int {
    b : ., mut = 1;
    k : ., mut = n;
    loop { if k <= 0 { break; } b = b * 2; k = k - 1; }
    return b;
}

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
    // ─── ops 列组位集（Task 4 逐格填写；每格注现状 checker.cr 行号 = 逐格转录依据）───
    // 算术门（唯一消费者 = checker.cr:1959 的 ANY 门）：**只含 int/dex**——这不是省事，而是与
    // :1959 一字等价所要求的最小集。现状「算术许可」是**两层**：早退规则（串拼接 :1946 /
    // 指针算术 :1948+:1951 / 指针差 :1955）命中即 return、不会走到门；门只管「两侧皆非数值才
    // 报错」。故把 PTR/STRING 填进本组 = **放宽**（ANY 语义下 permits(PTR,ADD)=1 足以放行
    // `*T + *T`、`"a" - "b"`——两条现状均为 error[TB01]，有负控钉红）。
    o_arith := iface_bit(OP_ADD) + iface_bit(OP_SUB) + iface_bit(OP_MUL) + iface_bit(OP_DIV) + iface_bit(OP_MOD);
    // 逻辑族（消费者 = checker.cr:1969 的 ALL 门）：现状每侧须 `bool|int`（:1969 逐字：
    // `(lt != BOOL && lt != INT) || (rt != BOOL && rt != INT)`）⇒ 本组**恰 {int, bool}**。
    // ⚠ 计划 Task 4 许可格表把本组写在「AK_INT/AK_DEX」行（括注「允许 bool|int」自相矛盾）——
    //   **实测裁决**：dex 在现状被拒（`1.5 && true` → error[TC01]，探针实测）⇒ DEX 格必为 0，
    //   否则 = 放宽。取「与 :1969 一字等价」为准（计划 Step 2 的替换代码即此要求）。
    o_logic := iface_bit(OP_AND) + iface_bit(OP_OR);
    // 比较族（:1965-1967 六个比较 op 恒返 bool、**不校验操作数**）+ 一元族（:1979 NEG/NOT 透传、
    // :1982 REF 对任意操作数产 TYP_PTR、:2003-2014 DEREF 兜底透传）+ 转换（:2892-2908 除 PTR 的
    // asp 外恒等透传）⇒ **对全部 13 类置 1**（现状宽松面的集中体现；P3 收紧旋钮，本批只登记）。
    // 口径：这四项在现状**没有拒绝路径**，故本批不接线（无门可换）——表登记为 P3 的可审计位。
    o_cmp := iface_bit(OP_EQ) + iface_bit(OP_NE) + iface_bit(OP_LT) + iface_bit(OP_GT) + iface_bit(OP_LE) + iface_bit(OP_GE);
    o_un := iface_bit(IP_UOP_BIAS + UOP_NEG) + iface_bit(IP_UOP_BIAS + UOP_NOT) +
            iface_bit(IP_UOP_BIAS + UOP_REF) + iface_bit(IP_UOP_BIAS + UOP_DEREF);
    o_base := o_cmp + o_un + iface_bit(IP_AS);          // 13 类共有面（比较/一元/转换全许可）
    o_cond := iface_bit(IP_COND);                       // `if`（:2274 收 bool|int）
    o_cond_b := iface_bit(IP_COND_BOOL);                // `while`（:2385 **只收 bool**——不得与上合并）
    // 8 原生（ti_row 取 TI_* 常量；AK↔TI 逐项分派——bool/string 两行按语义错位书写）
    //   AK_INT ：门 + 逻辑 + 条件（:2274 收 int）——**无 IP_COND_BOOL**（:2385 拒 int，探针 N9 实测）
    iface_put(0, AK_INT, TI_INT, -1, EXPR_INT, o_base + o_arith + o_logic + o_cond);
    //   AK_DEX ：仅门——逻辑/条件均**不含 dex**（:1969/:2274 只认 bool|int；探针 N7/N8 实测拒）
    iface_put(1, AK_DEX, TI_DEX, -1, EXPR_DEX, o_base + o_arith);
    //   AK_STRING：无算术/逻辑/条件（串拼接走 :1946 早退，不进本表）；索引面 = :2619（串下标→int）
    //     ——Task 5：IP_INDEX 已接线（兜底门；串的**结果**分支 :2644 原地保留）
    iface_put(2, AK_STRING, TI_STR, -1, EXPR_STRING, o_base + iface_bit(IP_INDEX));
    //   AK_BOOL ：逻辑 + 两条条件位（:2274 收 bool、:2385 收 bool）
    iface_put(3, AK_BOOL, TI_BOOL, -1, EXPR_BOOL, o_base + o_logic + o_cond + o_cond_b);
    iface_put(4, AK_UNIT, TI_UNIT, -1, -1, o_base);
    iface_put(5, AK_NEVER, TI_NEVER, -1, -1, o_base);
    iface_put(6, AK_CHAR, TI_CHAR, -1, EXPR_CHAR, o_base);
    //   AK_DYN ：+ 方法面（:2066 dyn 方法校验路径）——Task 5：**未接线**（该路径的拒绝谓词 =
    //     `type_has_method(具体行名, 方法名)`（名拼接方法表判定），非本类级位；实测 int/string
    //     行今日也发 EC_N_METHOD（探针 D1/D4）⇒ 类级门会抑制 = 放宽）
    iface_put(7, AK_DYN, TI_DYN, -1, -1, o_base + iface_bit(IP_METHOD));
    // 结构/命名（ti_row = -1 = 类级，无「规范行」）
    //   AK_PRODUCT ：+ 字段面（:2566-2577 元组 `.N`）——Task 5：IP_FIELD **未接线**（落空
    //     `return TI_UNIT` 无诊断；其前的 kind 分支是结果规则）
    iface_put(8, AK_PRODUCT, -1, -1, -1, o_base + iface_bit(IP_FIELD));
    //   AK_SEQUENCE：+ 索引面（:2605-2618 数组/切片元素 + F2 越界；:2586 range→slice）
    //     ——Task 5：IP_INDEX 已接线（兜底门；ARRAY/SLICE 的**结果**分支原地保留）；
    //     IP_INDEX_RANGE **未接线**（range 分支 :2612-2627 的非数组落空 `return TI_UNIT` 无诊断
    //     ⇒ 门恒真 = 空转；登记为 P3 旋钮）
    iface_put(9, AK_SEQUENCE, -1, -1, -1, o_base + iface_bit(IP_INDEX) + iface_bit(IP_INDEX_RANGE));
    //   AK_REF/AK_PTR：门全 0——**指针算术由 :1948-1955 早退承担**（结果规则留代码），非本表
    iface_put(10, AK_REF, -1, -1, -1, o_base);
    iface_put(11, AK_PTR, -1, -1, -1, o_base);
    //   AK_NAMED ：+ 字段面（:2522-2563 struct 字段表）+ 方法面（:2088 方法表）——Task 5：
    //     两位均**未接线**（EXPR_FIELD 全形 rc=0、零诊断路径；方法面 = 逐方法表名判定，
    //     同 AK_DYN 注的理由）；登记为 P3 旋钮
    iface_put(12, AK_NAMED, -1, -1, -1, o_base + iface_bit(IP_FIELD) + iface_bit(IP_METHOD));
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

// TY_*（基类型码）→ TI_*（类型表行常量）；**-1 = 无对应**（调用方自行回落，本表不兜底）。
// P2b Task 6：`res_type_node`/`res_call_type` 的**双份基型分支** + 同族 6 处内联链
// （checker.cr 的 hotpatch 注册 / extern 注册 / 形参 / 返回 / iface 返回）合一的**唯一映射表**。
//   · 逐项按语义写死（**禁止按值直传**——P1 血泪：AK/TI 下标不 1:1，见本文件头注）；
//   · 码 7 一格 = **现状两表原文原样保留**（`if tv == TI_DYN { return TI_DYN; }`）：TY_GENERIC_PARAM=7
//     与 TI_DYN=7 的纯数字撞车（spec §2.4），而 parser.cr:98 对 `dyn` 类型名**正产** `type_val=TI_DYN`
//     ⇒ 本格**可达**（探针 B2：`x : dyn = 5; x.nosuch()` → N08，即 res_type_node 走本格）。
//   · **TY_DEX_S(8) 不入表**（计划 Interfaces 注「占位行，仅 init_types 面用；不属两表并集」）：
//     两处调用点现状对码 8 均落 `TI_UNIT`（尾部回落）⇒ 入表 = 若该码可达即行为变化（selftest
//     `t6.R_dex_s_unit`/`t6.C_dex_s_unit` 把「码 8 → TI_UNIT」钉红）。全 src 实测：TY_DEX_S 只出现在
//     init_types 的位置公理（checker.cr:253）与注释；无任何 parser/铸点写 `type_val = 8`（parser
//     只产 int/dex/bool/string/char/never/dyn 七码 + 复合节点）。**域外码一律 -1**（含负值）。
fn ty_code_to_ti(ty: int) -> int {
    if ty == TY_INT { return TI_INT; }
    if ty == TY_DEX { return TI_DEX; }
    if ty == TY_BOOL { return TI_BOOL; }
    if ty == TY_STRING { return TI_STR; }
    if ty == TY_UNIT { return TI_UNIT; }
    if ty == TY_NEVER { return TI_NEVER; }
    if ty == TY_CHAR { return TI_CHAR; }
    if ty == TI_DYN { return TI_DYN; }   // ← 现状原样：7 = TY_GENERIC_PARAM 的数值撞车格（见头注）
    return -1;
}

// iface_kind_of 已移至 iface_axis.cr（R2 P4 Task 0，链接面纯化）

// 原子类 → 规范行（8 原生 = TI_*；结构/命名条目 ti_row = -1 ⇒ 恒 -1）
fn iface_ti_of(ak: int) -> int {
    e := iface_entry(ak);
    if e < 0 { return -1; }
    return r64(g_iface_entries, e * ESZ_IFACE_ENTRY + OFF_IE_TI);
}

// ═══════════════ R2 P3b Task 0：横切轴形状条目表（`iface_satisfies` 的轴 A）═══════════════
// 语义（spec §2.2）：每条横切接口 = **一个形状类型项**（如 `sequence` ⇒ `⊤_SEQUENCE`、
// `可索引`/`可迭代`/`product` 各一条），满足判定 = `ty_sub(实参项, 形状项)`——与用户轴/本质轴
// 共用同一套引擎判定，不另建规则体系。本表 = 形状条目的**唯一数据面**（名字 ni → 类型项）。
//
// ⚠ 空表口径（本批 = P3b Task 0 backfill）：**零条目注册** ⇒ 轴 A 恒未命中 ⇒ `iface_satisfies`
//   落轴 C/B（本批 P3b 的判定面 = 用户接口 + 本质轴）。条目细化（`sequence`/只读/可写/可索引/
//   可迭代/product 四~六条 + 各自形状项）归 **Task 2 Step 1**（该步的「形状条目细化」原文）；
//   到位后 `iface_satisfies(t, <形状名 ni>)` 即按包含判定给 1/0/-1，消费点（索引/切片/迭代）
//   的换位归 Task 2 Step 3。
//
// ⚠ 注册名须为**已驻留**的名字 ni：本层**不做任何 `str_intern`**（初始化/查询路径 str_intern
//   会把新串追加进 g_strs ⇒ .ccr STR 段变——A.3-② 硬约束；源码标识符由 lexer 驻留，调用方
//   直接传 ni）。表本身不 alloc `g_types` 行、不进 .ccr 序列化 ⇒ 类型段/行号零扰动。
//
// 生命周期：count 随 `reset_frontend_state` 清零、cap 保留（缓冲复用）——照 g_sgen_constr 先例。
// 同名**覆盖**（最后一次注册生效；幂等重注册不增长表）。
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

// 注册（返回行号；-1 = 参数非法）。name_ni < 0 / term < 0 一律拒绝——**不得**把负值当
// 「未注册」哨兵写进表（那会让 lookup 把 -1 名字与空槽混淆）。
fn iface_shape_register(name_ni: int, term: int) -> int {
    if name_ni < 0 { return -1; }
    if term < 0 { return -1; }
    i : ., mut = 0;
    loop {
        if i >= g_iface_shape_count { break; }
        if r64(g_iface_shape_names, i * 8) == name_ni {
            w64(g_iface_shape_terms, i * 8, term);   // 覆盖（幂等重注册）
            return i;
        }
        i = i + 1;
    }
    iface_shape_grow(g_iface_shape_count + 1);
    w64(g_iface_shape_names, g_iface_shape_count * 8, name_ni);
    w64(g_iface_shape_terms, g_iface_shape_count * 8, term);
    g_iface_shape_count = g_iface_shape_count + 1;
    return g_iface_shape_count - 1;
}

// 查询：名字 ni → 形状项（-1 = 未注册/参数非法）
fn iface_shape_lookup(name_ni: int) -> int {
    if name_ni < 0 { return -1; }
    i : ., mut = 0;
    loop {
        if i >= g_iface_shape_count { return -1; }
        if r64(g_iface_shape_names, i * 8) == name_ni { return r64(g_iface_shape_terms, i * 8); }
        i = i + 1;
    }
    return -1;
}

fn iface_shape_count() -> int { return g_iface_shape_count; }

// 清空（**仅自测**：形状注册是进程级全局态，自测用例注册后复位，防条目泄漏进后续用例/
// 编译——LSP 长驻进程内多编译共用本表，生产路径的复位点是 reset_frontend_state）。
fn iface_shape_reset() { g_iface_shape_count = 0; }

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

// ═══════════════ R2 P3b Task 2：横切轴形状项（Step 1「条目细化」的类型项数据面）══════════════
// spec §2.2：每条横切接口 = **一个形状类型项**，满足判定 = 一条包含判定 `T <: 形状`（与本质轴
// /用户轴共用同一套引擎判定，不另建规则体系）。本段 = 六条形状项的**唯一构造点**；名字面注册
// 走上方的 `iface_shape_register`（`iface_satisfies` 轴 A 的查表键）。
//
// ⚠ **不得**写成 `sequence<⊤>` 参数链（P3b Task 0 §1.3 勘误，实测）：AK_SEQUENCE 的槽 0 是
//   **不变**槽（Task 1 变型表：本语言数组/切片**可写**，元素协变不健全）⇒ 不变槽遇 ⊤ 会落
//   **-1**（未覆盖面）而非 1 ⇒ 序列面形状一律取**类别形** `⊤ₖ(AK_SEQUENCE)`。
// ⚠ 每个构造点**零 str_intern**（.ccr STR 段硬约束 = A.3-②）：形状项只进类型项 DAG
//   （append-only ⇒ 跨编译/跨 init_types 稳定），不驻留新串——守门 = selftest `x2.no_str_intern`。
// ⚠ **名字面：生产路径本批不注册**（Step 1 的「条目」= 数据面；注册裁决归后批）。理由 =
//   形状名是**驻留 ni**，而编译器源码里的新标识符/串只在生产编译执行到那行时才驻留 ⇒ 在任何
//   初始化路径（init_types / iface_registry_init）注册 = 把新串追加进 g_strs ⇒ `.ccr` STR 段
//   逐字节变（A.3-② 硬判据）。本批消费者（索引/切片）是**无名字消费点**，直接 `iface_satisfies_term`
//   （P3b Task 0 §1.3 已备此路）；命名消费（`T: 可索引` 一类语法）待命名面裁决后接。

// 序列接口（spec §2.2 的 `序列接口 ⟺ sequence<⊤>`，按上方勘误兑现为 ⊤ₖ 类别形）。
// 数组行与切片行同属 AK_SEQUENCE ⇒ 皆满足；`&[T]`/`&mut [T]`（AK_REF 行）**不**满足（见只读形状）。
fn sh_shape_seq() -> int { return tt_top_k(AK_SEQUENCE); }

// 只读序列 = 序列本体（数组/切片）+ **只读视图**（`&[T]`）。
// 「只读 = **协变**」（计划 Step 1）：视图部分的元素落在 AK_REF 的**协变槽**（Task 1 变型表：
// 只读 ref 的元素槽协变、可写 ref 降为不变）⇒ `&[int] <: 只读序列` 由协变槽判定（元素不是 ⊤
// 也成立）——T1 §6-④ 登记的「只读序列形状」在**视图面**由此闭合。
// **等式语义**（Task 1 裁决：mut 标记是判定维度，非 Rust 式单向放宽）：`&mut [T]` 的标记不同
// ⇒ **不**满足只读形状（判 0，可判定）；`&mut [T]` 也不满足可写形状（见下：视图面不可表达）。
fn sh_shape_seq_ro() -> int {
    view := tt_atom(AK_REF, -1, tt_cons(sh_ref_mut_marker(0), tt_cons(tt_top_k(AK_SEQUENCE), tt_nil())));
    return tt_union(tt_top_k(AK_SEQUENCE), view);
}

// 可写序列 = **序列本体**（数组/切片——本语言切片可写，T1 探针 pSliceW `s[0] = 9` rc=0 实证）
// ⇒ 与序列接口同项；**拒绝只读视图**（`&[T]` 是 AK_REF 行，非序列类 ⇒ 0）。
// 可写**视图**（`&mut [T]`）的形状**不可表达**：AK_REF 可写侧槽 1 = 不变（变型表）⇒ 槽内 ⊤ 落
// -1（未覆盖面）而非 1 ⇒ 本形状只覆盖本体面；该边界由 selftest `x2.rw_view_unexpressible`
// 钉红（**-1 不得当 0/1 用**）。
fn sh_shape_seq_rw() -> int { return tt_top_k(AK_SEQUENCE); }

// 可索引 = 序列 ∪ 字符串（串下标 → 字节值，checker 既有结果分支）。
// **与 IP_INDEX 许可集逐行同集**（{AK_SEQUENCE, AK_STRING}）——这是索引兜底门换位后行为保持的
// 等价前提（全类型行枚举守门 = selftest `x2.indexable_matches_ops`）。
fn sh_shape_indexable() -> int { return tt_union(tt_top_k(AK_SEQUENCE), tt_top_k(AK_STRING)); }

// 可迭代（首版）= 序列（数组/切片）。
// 字符串**不**入本形状：迭代面现状**无任何类型检查**（checker 的 EXPR_FOR 只推迭代源类型、
// ir_gen 把它当数值界用）⇒ 无「串可迭代」的代码面证据，不宣称。
fn sh_shape_iterable() -> int { return tt_top_k(AK_SEQUENCE); }

// product = 元组行（AK_PRODUCT）。struct 行 = AK_NAMED（结构项经展开层 / 用户轴面）⇒ 不在首版。
fn sh_shape_product() -> int { return tt_top_k(AK_PRODUCT); }
