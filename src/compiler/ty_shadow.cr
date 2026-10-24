// === ty_shadow.cr ===
// Bridge from checker type rows to engine type terms, plus the expansion layer.
// The file name and the sh_ prefix are historical. No shadow comparison channel
// remains.
//
// Part 1: bridge.
//   sh_term_of_ti maps a checker type row (ti) to an engine type term.
//   Constructors cover primitives, named types, generic applications, arrays and
//   slices, references and mut markers, name tokens, tuples, and null.
//   sh_tk_* classify the type slot of a DFNode and split a type term reference
//   from an auxiliary code.
//
// Part 2: expansion.
//   struct, enum, and generic-apply rows are expanded to structural terms.
//   Expansion is used only by interface satisfaction and exhaustiveness/pattern
//   checks. Equivalence and inclusion keep named types nominal.
//
// Judgment results have three values: 1 holds, 0 does not hold, -1 cannot decide
// because the budget is exhausted or a rule is not implemented. Callers must not
// treat -1 as 0 or 1.
//
// AK_* and TI_* indices are not 1:1:
//   TI_INT=0 TI_DEX=1 TI_BOOL=2 TI_STR=3 TI_UNIT=4 TI_NEVER=5 TI_CHAR=6 TI_DYN=7
//   AK_INT=0 AK_DEX=1 AK_STRING=2 AK_BOOL=3 AK_UNIT=4 AK_NEVER=5 AK_CHAR=6 AK_DYN=7
// The mapping is by meaning, never by numeric index. sh_native_ak reads the type
// row (kind == TYP_BASE) and delegates the TY_* mapping to iface_by_ty_code.
//
// The bridge cache g_term_map maps ti to term. It is cleared whenever the type
// table is rebuilt because row numbers are reused. Open addressing has a
// load-factor check before probing. After translating a term, the bridge probes
// again before writing because recursive translation can resize the table.
//
// The bridge reads checker type tables and calls engine construction and judgment
// APIs. It does not change judgment state or output. One exception: expansion
// resolves field type nodes with res_type_node, which can append type rows.

TERM_MAP_INIT_CAP : int = 1024

// ─── 原生清单 -> AK_*（按语义逐项对应，不得按下标直通；下标互换事实见文件头注）───
// The first seven AK_* and TI_* entries are not one-to-one. Mapping by numeric
// index would mislabel bool and string, and both sides would be wrong in the same
// way. This implementation reads the type row itself instead of guessing by row
// number. The test is
// kind 恰为 TYP_BASE 且 data（TY_* 码）有语义对应，此时该记录的类型身份
// 就是此原生类。记录编号顺序与 TY_*/TI_* 码序的巧合一致不再是正确性前提。
// 注：TYP_DYN 记录（TI_DYN=7）的 kind 不是 TYP_BASE，不在此路径，走
// sh_term_of_ti 的 TYP_DYN 分支。TY_DEX_S 占位记录（TI_DEX_S=8）经
// sh_base_ak 归 AK_DEX（同值域不同表示）。当前实现按记录编号白名单把它
// 留给通用路径，两条路产出的项完全相同，只有缓存占用不同。
fn sh_native_ak(ti: int) -> int:
    if ti < 0:
        return -1
    // 本快路径只认类型表记录本身：kind 必须是 TYP_BASE；TYP_DYN 和所有
    // 结构/命名记录返回 -1。TI_DYN 走 sh_term_of_ti 的 TYP_DYN 分支，见文件头。
    //  不得把本函数直接换成 iface_kind_of：后者对 TYP_DYN 行回 AK_DYN、对结构行回
    // AK_SEQUENCE/…（= 注册表的分派逻辑），与本层的原生快路径契约不同，两函数只用
    // 同一个 TY_* 逐项分派表（iface_by_ty_code），检查各自保留。
    if get_type_kind(ti) != TYP_BASE:
        return -1
    return iface_by_ty_code(get_type_data(ti))

// TYP_BASE 的 data（TY_*）-> AK_*：同款语义对应（TY 序与 TI 序一致，故与 AK 下标同样
// 不可混用）。-1 = 无对应（调用方回退 AK_NAMED）。
// 实现已单源化到 iface_registry.cr 的 `iface_by_ty_code`（唯一实现；
// 逐项语义分派，含 TY_DEX_S->AK_DEX / TY_GENERIC_PARAM->AK_NAMED 两个已确定的特殊映射）。
fn sh_base_ak(ty: int) -> int:
    return iface_by_ty_code(ty)

// Historical comparison copies were removed; the frozen expected table lives in type_selftest.cr.
// 用途曾是 `iface.by_ty_code_all_codes` / `iface.native_ak_all_rows`（逐 TY 码 × 逐 ti 行，
// 非抽样）的旧版对照。删因：单源化的收益已由冻结期望表承担（期望值以数据形式落在
// type_selftest.cr 的 `ts_t4_ak_expected`，不再需要生产文件里的第二份实现）。
// The TY_DEX_S mapping still holds：值域仍是 dex（缩放整数表示）-> 归 AK_DEX
// （引擎无同值域不同表示的区分，表示层差异不进类型身份）。

// ─── 桥接缓存（ti -> term）───
// 重置 = 随类型表作废（
// 键 = ti 本体，而 `init_types()` 会把类型表清空重建（行号空间复用）-> 陈旧 ti->term 若不清，
// 长驻进程（corelsp 每请求 `reset_frontend_state -> check_all -> init_types`）里命中即返回
// 上一请求的类型项 -> 两个不同类型被判等（不报错漏报）。同 URI 两次 didOpen 只把
// 数组元素型 int->bool，第二次 diagnostics=0（应 1 条 Assignment type mismatch）。
// cap = 0 -> 下次 sh_map_find 惰性重建（空槽全 -1）；entries 归零（否则装填因子检查按陈旧
// 计数提前扩容）。影子期的 hits 复位已删（计数本体随影子层下线）。
fn sh_map_reset():
    g_term_map_cap = 0
    g_term_map_entries = 0

fn sh_map_cap_init():
    if g_term_map_cap <= 0:
        nc : ., mut = TERM_MAP_INIT_CAP
        nb := alloc(nc * 16)
        i : ., mut = 0
        loop:
            if i >= nc:
                break
            cell_store(nb, i * 16, -1)
            i = i + 1
        g_term_map = nb
        g_term_map_cap = nc

// Probe without inserting. Call only after the growth check; rehash also uses it.
// The loop uses ret, break, and a final return so the self-hosted checker sees a
// returning function. A body ending in a breakless loop was once misreported as
// TF01; the current fall-through analysis handles that shape.
fn sh_map_find_nogrow(ti: int) -> int:
    cap := g_term_map_cap
    // 非负槽位（负数取模 = 负下标 -> 检查越界；与引擎 tt_mod 同式同因，直接复用引擎
    // 该函数，避免本仓库第三份取模式各自漂移）
    p : ., mut = tt_mod(ti, cap)
    ret : ., mut = -1
    loop:
        k := cell_load(g_term_map, p * 16)
        if k < 0:
            ret = p
            break
        if k == ti:
            ret = p
            break
        p = p + 1
        if p >= cap:
            p = 0
    return ret

fn sh_map_find(ti: int) -> int:
    sh_map_cap_init()
    // 装填因子检查（必须在探测前）：表满且键不存在时开放寻址永不退出（死循环）
    if (g_term_map_entries + 1) * 2 >= g_term_map_cap:
        sh_map_rehash()
    return sh_map_find_nogrow(ti)

// 扩容 = 重建 + 重放既有条目（引擎 grow_tt_index/tt_reindex 同式）；计数随重放重算
// （装填因子检查读的就是它，不得沿用旧值）。
fn sh_map_rehash():
    old := g_term_map
    old_cap := g_term_map_cap
    nc : ., mut = old_cap * 2
    if nc < TERM_MAP_INIT_CAP:
        nc = TERM_MAP_INIT_CAP
    nb := alloc(nc * 16)
    i : ., mut = 0
    loop:
        if i >= nc:
            break
        cell_store(nb, i * 16, -1)
        i = i + 1
    g_term_map = nb
    g_term_map_cap = nc
    g_term_map_entries = 0
    j : ., mut = 0
    loop:
        if j >= old_cap:
            break
        k := cell_load(old, j * 16)
        if k >= 0:
            s := sh_map_find_nogrow(k)
            cell_store(g_term_map, s * 16, k)
            cell_store(g_term_map, s * 16 + 8, cell_load(old, j * 16 + 8))
            g_term_map_entries = g_term_map_entries + 1
        j = j + 1

// TYP_TUPLE -> AK_PRODUCT（参数列表 = 逐字段项，顺序 = 声明顺序）。
// The layout is read from checker's TUPLE branch and field access:
//   data = field count; extra = start index of field type rows in
//   g_gen_apply_data, 8 bytes per element. Field i is
//   cell_load(g_gen_apply_data, (extra + i) * 8). There is no g_tuple_* table.
// CONS 列表逆序构造（i 自末尾向前 cons）：DAG 项不可变，正向追加需改写已建项，
// 不可行；逆序构造的结果顺序仍 = 声明顺序。
// ─── 序列项 / ref mut 标记（桥接的两个新构造点）───
// 序列项（TYP_ARRAY 与 TYP_SLICE 的唯一构造点）：tt_atom(AK_SEQUENCE, fixed_len, [元素项])。
//   b 槽 = 固定性位：数组 = N（长度字面量），切片/视图 = -1。
//    引擎比较只看 a（原子类）与 c（参数列表）两槽（`lit_implies` 的双方皆正原子分支；
//   b 槽是标注，AK_NAMED 的 b = 行号即此约定）-> N 不入等价/包含身份（
//    长度约束不变量的延续）：`[int;3]` 与 `[int;4]` 的项除 b 外逐位相同 -> `ty_equiv == 1`、
//   `ty_sub == 1`，拒绝一律由 checker 的常量档约束承担。固定性位的消费者 = checker.cr
//   `array_len_constraint_ok` 的方向规则（视图到固定拒绝）与后续横切形状。
//   -1 = 元素项译不成（调用方回 -1，不缓存）。
fn sh_seq_term(elem_ti: int, fixed_len: int) -> int:
    el := sh_term_of_ti(elem_ti)
    if el < 0:
        return -1
    return tt_atom(AK_SEQUENCE, fixed_len, tt_cons(el, tt_nil()))

// AK_REF 序列槽位 0 = mut 标记（起 mut 成为判定维度，替代当前约定的不加入序列，
// 当前约定下 `&T` 与 `&mut T` 的项逐位相同 -> 引擎判等价，而 legacy 比 extra(mut) 判不等 ->
// 判定替换后 mut 属性不报错放宽；本标记即该缺口的关闭）。
// 标记项 = tt_atom(AK_UNIT, mut, -1)：语法令牌（b 槽 = 标记值，照 AK_NAMED 的 b = 行号
// 同约定），非类型集，引擎侧按节点同一性比较（type_engine.cr 的 tt_list_variance_at
// 槽 0 分支；不同标记 = 确定不匹配 -> 0，不回 -1）。
fn sh_ref_mut_marker(mutv: int) -> int:
    return tt_atom(AK_UNIT, mutv, -1)

// 名字令牌：变体身份序列存放令牌原子，不再直接存放 name 索引。
// 当前约定（）= `tt_cons(ei_name(ea), tt_cons(name_ni, tt_nil()))` 直接把 name 索引
// 当序列元素，索引是别名：任何把序列元素当术语解释的比较（如按结构/等价比较）会把
// `str_intern` 得到的小整数当术语下标读取（`tt_tag(ni)` = 第 ni 个项的 tag）-> 名字
// collisions silently compare equal. Two cases show the problem: invariant-slot
// comparison with ty_equiv
// `unf.enum_variant_identity_scoped` 红（异枚举同名变体被判等）；2 固定性检查
// （tt_type_elem_same）会读序列元素的 class。-> 令牌改为原子节点
// `tt_atom(AK_UNIT, ni, -1)`（与 mut 标记同式；b = 值），只按节点同一性比较，
// 结构比较再也不可能把它当术语解释。语义等价（不同名字 -> 不同节点；同名字 -> 同节点）。
fn sh_name_token(ni: int) -> int:
    return tt_atom(AK_UNIT, ni, -1)

fn sh_tuple_to_product(ti: int) -> int:
    cnt := get_type_data(ti)
    start := get_type_extra(ti)
    tail : ., mut = tt_nil()
    i : ., mut = cnt - 1
    loop:
        if i < 0:
            break
        et := sh_term_of_ti(cell_load(g_gen_apply_data, (start + i) * 8))
        if et < 0:
            return -1
        // 任一字段无法翻译 -> 整项无法翻译（不缓存）
        tail = tt_cons(et, tail)
        i = i - 1
    return tt_atom(AK_PRODUCT, -1, tail)

// ─── null 项（`T? = T ∪ null` 的右支；`None` 类型的项）───
// 规范形态 = tt_atom(AK_NULL, -1, -1)：行号不入项（b 槽是标注；此处刻意连标注都空）。
// 理由：`None` 每出现一次就分配一行（TYP_NULL 不做行去重）-> 若把行号写进 b 槽，同一类型
// 会有 N 个不同节点，虽然引擎比较只看 a/c 两槽（b 是标注）-> 语义不受影响，但节点同一
// 性快路径（ty_sub 的 `a == b`、tt_norm 的哈希去重）会失去同项合并，读数与缓存都变差。
// 单点语义 -> 项恒定，构造去重（tt_term 的哈希合表）保证全仓只有一个 null 节点。
fn sh_null_term() -> int:
    return tt_atom(AK_NULL, -1, -1)

// Named-type identity token sequence, shared by both construction points. The
// identity replaces an empty sequence plus an identity in the b slot.
//   TYP_NAMED or TYP_GENERIC_PARAM: c = [sh_name_token(name_ni)]
//   TYP_GENERIC_APPLY: c = [sh_name_token(base name), argument items...]
// b is still an annotation: this row for NAMED/PARAM, the base row for APPLY.
// Named-type comparison uses slots a and c in te_named_pair and te_chain_cmp.
// The b slot's existing consumer is tt_atom_of_term, which derives type rows for
// the DF representation.
// APPLY 的 b 槽取基型行（不取本行）是规范形要求：`Box[int]` 的两处实例化各占一行
// （alloc_type 裸分配）-> 若 b = 本行则同型两行节点不同 -> 节点同一性快路径 / 不变槽
// 结构比较 / 接口签名（iface_axis 的 tt_list_same 判等）全部失真。基型行经 named_dedup
// canonical by name, so equal types get the same node. Both construction points
// share this form; their only difference is the recursive function for argument
// items, and the signature data does not include N.
// 命名类型处理不展开，
// 序列里只有身份令牌与实参类型项，没有任何结构定义。
// -1 = 不可构造（行越界 / 基型非命名行 / 实参不可译），调用方按桥接缺口上抛。
fn sh_named_identity_term(ti: int) -> int:
    if ti < 0:
        return -1
    ni := get_type_data(ti)
    if ni < 0:
        return -1
    return tt_atom(AK_NAMED, ti, tt_cons(sh_name_token(ni), tt_nil()))

// 泛型应用实参列表（两构造点共用骨架；variant：0 = 桥接侧递归 sh_term_of_ti /
// 1 = 签名数据递归 sh_sig_term_of_ti）。
fn sh_apply_args_chain(ti: int, variant: int) -> int:
    start := get_type_extra(ti)
    cnt := cell_load(g_gen_apply_data, start * 8)
    if cnt < 0:
        return -1
    tail : ., mut = tt_nil()
    j : ., mut = cnt - 1
    loop:
        if j < 0:
            break
        ai := cell_load(g_gen_apply_data, (start + 1 + j) * 8)
        at : ., mut = -1
        if variant == 0:
            at = sh_term_of_ti(ai)
        else:
            at = sh_sig_term_of_ti(ai)
        if at < 0:
            return -1
        // 任一实参不可译 -> 整项不可译（不缓存）
        tail = tt_cons(at, tail)
        j = j - 1
    return tail

// 泛型应用行 -> 命名原子（身份 = 基名令牌 + 实参列表；b = 基型行 = 规范形）。-1 = 不可构造。
fn sh_apply_identity_term(ti: int, variant: int) -> int:
    if ti < 0:
        return -1
    base := get_type_data(ti)
    if get_type_kind(base) != TYP_NAMED:
        return -1
    bni := get_type_data(base)
    if bni < 0:
        return -1
    tail := sh_apply_args_chain(ti, variant)
    if tail < 0:
        return -1
    return tt_atom(AK_NAMED, base, tt_cons(sh_name_token(bni), tail))

// ti -> 类型项（带 per-ti 缓存；-1 = 无法翻译）
fn sh_term_of_ti(ti: int) -> int:
    if ti < 0:
        return -1
    // 原生快路径：无表读、不占缓存条目
    nak := sh_native_ak(ti)
    if nak >= 0:
        return tt_atom(nak, ti, -1)
    slot := sh_map_find(ti)
    if cell_load(g_term_map, slot * 16) == ti:
        return cell_load(g_term_map, slot * 16 + 8)
    // 未命中：按 kind 翻译（递归子项）
    term : ., mut = -1
    k1 := get_type_kind(ti)
    d1 := get_type_data(ti)
    if k1 < 0:
        return -1
    // 行号越界（ti >= g_type_count）= 无法翻译
    if k1 == TYP_BASE:
        bak := sh_base_ak(d1)
        if bak >= 0:
            term = tt_atom(bak, ti, -1)
    else if k1 == TYP_DYN:
        // data is a type-set bitmap; 0 means one known type. The table maps
        // TYP_DYN to AK_DYN. AK_DYN is top in the engine, which is wider than the
        // bitmap, so this is a documented approximation.
        term = tt_atom(AK_DYN, ti, -1)
    else if k1 == TYP_ARRAY || k1 == TYP_SLICE:
        // TYP_ARRAY 的 extra = N（长度），不入身份-> 参数列表只含元素项，
        // N 落 b 槽 = 固定性位（构造点统一在 sh_seq_term）
        fl : ., mut = -1
        if k1 == TYP_ARRAY:
            fl = get_type_extra(ti)
        term = sh_seq_term(d1, fl)
    else if k1 == TYP_PTR:
        // 同 PTR：元素加入序列（AK_PTR 槽 0 变型 = 不变，见 type_engine.cr 变型表）；
        // extra（asp 地址空间位）不加入序列，与 legacy 的 PTR 分支（只比 data）同语义
        in1 := sh_term_of_ti(d1)
        if in1 >= 0:
            term = tt_atom(AK_PTR, -1, tt_cons(in1, tt_nil()))
    else if k1 == TYP_REF:
        // extra = mut 标记：加入序列（当前约定），序列 = [mut 标记项, 元素项]，标记与元素
        // 各占一槽（槽 0 不变 / 槽 1 只读协变、可写不变，见 type_engine.cr 变型表）
        in2 := sh_term_of_ti(d1)
        if in2 >= 0:
            term = tt_atom(AK_REF, -1, tt_cons(sh_ref_mut_marker(get_type_extra(ti)), tt_cons(in2, tt_nil())))
    else if k1 == TYP_OPTIONAL:
        // `T?` = `T ∪ null`（spec 5.4）。这是桥接层唯一译作非原子项的行
        // （其余行 -> 单原子）；依据 = 定义式本身（不是名义展开，T? 无名字可展开）。语义落点：
        // 引擎对 union 的一切判定（包含/等价/不相交/穷尽性）零新规则。
        in3 := sh_term_of_ti(d1)
        if in3 >= 0:
            term = tt_union(in3, sh_null_term())
    else if k1 == TYP_NULL:
        // null 单点类型（`None` 值的类型）：规范项 = null 原子（无参数、无 b 槽行号，同一
        // 类型的不同出现点（每处 `None` 各一行）必须译成同一项，否则 `ty_sub(null, null)`
        // 会走结构比较而非节点同一/规范化快路径（语义仍对，但多绕一圈且不可读）。
        term = sh_null_term()
    else if k1 == TYP_TUPLE:
        term = sh_tuple_to_product(ti)
    else if k1 == TYP_NAMED || k1 == TYP_GENERIC_PARAM:
        // 身份令牌序列（名字令牌），取代原空序列 + b 槽当身份（见
        // sh_named_identity_term 文件头注）
        term = sh_named_identity_term(ti)
    else if k1 == TYP_GENERIC_APPLY:
        term = sh_apply_identity_term(ti, 0)
    else:
        // 未知 kind 保守归入命名类：无身份序列 -> 引擎命名类型处理域外（-1，见 te_named_pair 检查）。
        // All kinds are dispatched above; this branch is unreachable and only defensive.
        term = tt_atom(AK_NAMED, ti, -1)
    if term < 0:
        return -1
    // 写回前重探（递归翻译期间可能已扩容，见文件头注记2）
    slot2 := sh_map_find(ti)
    if cell_load(g_term_map, slot2 * 16) == ti:
        return cell_load(g_term_map, slot2 * 16 + 8)   // 后备：递归期间同 ti 已入表
    cell_store(g_term_map, slot2 * 16, ti)
    cell_store(g_term_map, slot2 * 16 + 8, term)
    g_term_map_entries = g_term_map_entries + 1
    return term

// ─── DFNode 类型信息单槽化 = 唯一分类表 + 拆分器 ───
// 单槽化（α，内存表示）：`OFF_DF_TK` = 类型项引用（类型信息唯一真源），
// `OFF_DF_AUX` = 辅码（原混用槽里的非类型部分：旗标/宽度/计数/不可入项的原始行码）。
// `.ccr` NOD 与 `.cir` 快照只承载派生码（`sh_dfn_code_of_slots`）-> 文件布局与版本位
// 零改动（布局零变化，见 dyn_arr.cr 的四条契约）。
//
// 分类表（ 表 A 的代码化；逐 op 依据 = p5-task0-report 2 的 51 行表 + 后端
// `ti` 消费者机器审计）：
//   · 类型行数据（face 0，tk 语义 = 类型行 -> 建项）：IR_CONST / IR_BINARY / IR_ALLOC /
//     IR_CALL / IR_LOAD / IR_I2F / IR_F2I ，  的 {CONST,BINARY} 允许清单 + 
//     对  六排除项的再裁（前五者调用点显式传 TI_*/类型行变量-> 语义即类型行；
//     IR_LOAD_ENUM_TAG has two call sites that pass literal 0, so it keeps no
//     type information.
//   · 辅码（face 1，tk 语义 = 非类型码 -> 原码进辅码槽）：IR_BOUNDS_CHECK（0/1
//     动态上限旗标，instr.cr:1340 `ti != 0`）/ IR_DEREF / IR_STORE_PTR（旧访问宽度
//     码 8/4/2/1；v10 Task 5 起前端不再发射，宽度由 corearch 从 pointee 语义类型
//     重建——分类规则保留：重引入的宽度码仍必须落辅码面）/ IR_SPAWN（spawn_count；
//     -1 = 动态）/ IR_HOTPATCH_ROUTE with explicit 0.
//   · 无类型信息（face 2，tk 语义 = 无）：其余全部 op。
// Numeric coincidence: flag 1 equals the TI_DEX row and the legacy width code 8
// equals the TI_DEX_S row. The frontend no longer emits that width, but the
// classifier must keep blocking the collision: classification is per opcode and
// guessing by row number would assign a dex item to a pointer dereference.
//
// 原子行 vs 复合行：类型信息只接受项可逆的行
// atom_of(term) == ti 当且仅当 term 是 TT_ATOM 且 b 槽就是 ti。指针、引用、
// 数组、切片、可选、null 和元组记录的项是结构项（例如 AK_PTR 的 b = -1），
// 不建原子项，因此 atom_of 返回 -1，不做近似。原码保存在辅码槽，派生码逐字节
// 等于原码（含复合记录）。反例：tests/suite/ptr_ref_first.cr 的 IR_BINARY
// tk=10 是指针记录。
//
// 判定规则：类型信息 op 的记录越出类型表，或在域内但译不出项（桥接缺口），
// 就置建项失败位 g_tk_face_fail，保存侧拒绝写入文件（rc=1 并给出诊断），
// 不会留空项。tk < 0 表示无类型（IR_LOAD/CALL 的未定型路径），不是记录码，
// 不算失败。
fn sh_tk_is_type_face(opcode: int) -> int:
    if opcode == IR_CONST || opcode == IR_BINARY || opcode == IR_ALLOC || opcode == IR_CALL || opcode == IR_LOAD || opcode == IR_I2F || opcode == IR_F2I:
        return 1
    return 0

// Row judgment result: -1 = not a row code (tk < 0 means no type, which is valid);
// 0 = untranslatable (out of range or a bridge gap, so item construction failed);
// 1 = translatable (an atom row becomes an item; a composite row keeps its code).
fn sh_tk_row_state(tk: int) -> int:
    if tk < 0:
        return -1
    if tk >= g_type_count:
        return 0
    if sh_term_of_ti(tk) < 0:
        return 0
    return 1

// The atom-of-term rule is implemented in type_terms.cr:tt_atom_of_term. The
// corearch import list does not include this file, while load_ccr's term-index
// consistency check and the corearch readback channel need it. Callers use that
// single entry; no second definition remains here.

// 分类（纯函数）：0 = 类型表记录（项可逆才归此类）/ 1 = 辅码 / 2 = 无类型信息。
fn sh_tk_face_of_code(opcode: int, tk: int) -> int:
    if sh_tk_is_type_face(opcode) != 0:
        if sh_tk_row_state(tk) == 1:
            if tt_atom_of_term(sh_term_of_ti(tk)) == tk:
                return 0
        return 1   // 复合行 / 越界 / 桥接缺口 / 负值 ， 一律辅码（码保真）
    if opcode == IR_BOUNDS_CHECK || opcode == IR_DEREF || opcode == IR_STORE_PTR || opcode == IR_SPAWN || opcode == IR_HOTPATCH_ROUTE:
        return 1
    return 2

// 拆分器（单源；emit 与 `.cir` 装载侧共用）：(opcode, tk) -> (项槽, 辅码槽)。
// 出参经两个全局返回（Core 无多返回值），读前必先调用（函数入口先置默认值，
// 无残留状态）。规则：
//   face 0 -> 项 = `sh_term_of_ti(tk)`（此时构造已证可逆）、辅码 = 0；
//   其余   -> 项 = -1、辅码 = tk（码保真：旗标/宽度/复合行/无类型信息 op 的非零码
//            一律原样承载，派生码因此逐字节等于原先的混合码）。
// 该调用不进影子对账计数（hits/entries 只统计判定站点；本函数是表示方式派生，
// 冷/暖两态与判定历史无关），故 sh_term_of_ti 的命中计数先存后复原。
// entries（装填因子输入 = 真实占用槽数）不复原，复原即欺骗扩容检查。
fn sh_tk_split(opcode: int, tk: int):
    sh_tk_split_impl(opcode, tk, 1)

// 装载侧变体（.cir 快照重派生）不置建项失败位，因为判据不同：
//   emit 路径（count_fail=1）：类型信息记录的可译性是真不变量。记录刚由前端和
//   IR 生成，越界或译不出就是编译器 bug 或桥接缺口，必须拒绝写入文件。
//   装载路径（count_fail=0）：文件里的码是历史值，暖进程的类型表可能更小。
//   缓存命中会跳过该函数的 IR 生成，而 ir_gen 自己会 alloc_type 新记录
//   （ir_gen.cr:1277/:1283/:2434/:2491/:2792 的 addr/ref/cast/数组记录），
//   冷路径存在的记录在暖进程可能不存在。这是已知的缓存范围限制，不是本进程的
//   编译器 bug。代码保存在辅码槽，派生码仍逐字节正确，只有该项在本进程无法
//   重建（term = -1）。缓存命中绝不因此让编译失败。
fn sh_tk_split_load(opcode: int, tk: int):
    sh_tk_split_impl(opcode, tk, 0)

fn sh_tk_split_impl(opcode: int, tk: int, count_fail: int):
    fac := sh_tk_face_of_code(opcode, tk)
    g_sh_slot_term = -1
    g_sh_slot_aux = 0
    if fac == 0:
        g_sh_slot_term = sh_term_of_ti(tk)
    else:
        // 码保真：旗标/宽度/计数/复合行码/无类型信息 op 的非零码一律原样承载（含负码，
        // IR_SPAWN 的 tk = -1 = 动态 spawn 计数，是合法辅码，不得钳成 0）。
        // 辅码哨兵：0 = 无；非零（含负）= 该码本身。
        g_sh_slot_aux = tk
        // If a type-information operation has an untranslatable row (out of range
        // or a bridge gap), item construction fails. A composite row is in range
        // and translatable, so it takes the normal path and does not fail.
        if count_fail != 0:
            if sh_tk_is_type_face(opcode) != 0 && sh_tk_row_state(tk) == 0:
                g_tk_face_fail = g_tk_face_fail + 1

// 槽 -> 派生码（唯一派生点；ccr_lower.cr 的 lower_to_ccr / ir_gen.cr 的 emit /
// cir_cache.cr 的装载侧共用）：辅码 ≠ 0 -> 辅码；无项 -> 0；否则 `atom_of(项)`
// （不可逆 -> -1：显式、响亮，绝不近似成 0/1）。
fn sh_dfn_code_of_slots(tk_term: int, tk_aux: int) -> int:
    if tk_aux != 0:
        return tk_aux
    if tk_term < 0:
        return 0
    return tt_atom_of_term(tk_term)

// 兼容入口（自测/诊断）：单槽化前 `sh_tk_term_of_code(opcode, tk)` 的语义 =
// 类型信息派生出的项；其余 -1，即拆分器的项槽输出，但纯查询：不写槽出参、
// 不计失败位（诊断调用不得破坏写入文件检查；有副作用的生产路径一律走 sh_tk_split）。
// 与 split 共用同一个分类函数 sh_tk_face_of_code -> 规则单源，无第二份判定。
fn sh_tk_term_of_code(opcode: int, tk: int) -> int:
    t : ., mut = -1
    if sh_tk_face_of_code(opcode, tk) == 0:
        t = sh_term_of_ti(tk)
    return t

// ─── 桥接统计（自测断言用；影子期的 hits 通道已删，桥接缓存现有
// 唯一可观测部分 = 占用槽数 entries（装填因子检查的输入，恒等于真实占用））───
fn sh_map_entries() -> int:
    return g_term_map_entries

// ─── 类型项文本化（诊断反例用）───
// 用途 = `tt_witness` 的反例项 -> 人可读文本（诊断包含反例值）。
// 只读、零 str_intern：`.ccr` 的 STR 段 = 编译期 g_strs 全量（ 附录 A.3-2）-> 渲染
// 不得驻留新串（诊断文本一律用 dyn 串拼接；istr_get 读既有串）。
// 形态 = 结构化 JSON 风格（`int`/`string`/`sequence<int>`/`{int, string}`/`A ∪ B`/`¬A`…）；
// 未识别 tag -> "?"（不谎报形态）。深度上限 = 避免病态项上的栈爆（超限 -> "…"）。
fn tt_display_at(t: int, depth: int) -> string:
    if t < 0:
        return "?"
    if depth > 24:
        return "…"
    if t >= tt_count():
        return "?"
    tg := tt_tag(t)
    if tg == TT_BOT:
        return "⊥"
    if tg == TT_TOP:
        return "⊤"
    if tg == TT_TOP_K:
        return "⊤" + int_str(tt_a(t))
    if tg == TT_UNION:
        return tt_display_at(tt_a(t), depth + 1) + " ∪ " + tt_display_at(tt_b(t), depth + 1)
    if tg == TT_INTER:
        return tt_display_at(tt_a(t), depth + 1) + " ∩ " + tt_display_at(tt_b(t), depth + 1)
    if tg == TT_NOT:
        return "¬" + tt_display_at(tt_a(t), depth + 1)
    if tg == TT_MU:
        return "μ" + int_str(tt_a(t)) + "." + tt_display_at(tt_b(t), depth + 1)
    if tg == TT_VAR:
        return "X" + int_str(tt_a(t))
    if tg == TT_NIL:
        return "nil"
    if tg == TT_CONS:
        return "cons(" + tt_display_at(tt_a(t), depth + 1) + ", " + tt_display_at(tt_b(t), depth + 1) + ")"
    if tg == TT_ATOM:
        ak := tt_a(t)
        // AK_NAMED returns early. Joining the if-else chain below would mix
        // assignment and return branches, and the self-hosted checker reports
        // error[TC02]: If branches have different types. This file is part of the
        // `check src/compiler` corpus, so that would add a check diagnostic.
        if ak == AK_NAMED:
            nb := tt_b(t)
            if nb >= 0:
                return "named#" + int_str(nb)
            return "named"
        head : ., mut = ""
        if ak == AK_INT:
            head = "int"
        else if ak == AK_DEX:
            head = "dex"
        else if ak == AK_STRING:
            head = "string"
        else if ak == AK_BOOL:
            head = "bool"
        else if ak == AK_UNIT:
            head = "unit"
        else if ak == AK_NEVER:
            head = "never"
        else if ak == AK_CHAR:
            head = "char"
        else if ak == AK_DYN:
            head = "dyn"
        else if ak == AK_NULL:
            head = "null"
        else if ak == AK_PRODUCT:
            head = "product"
        else if ak == AK_SUM:
            head = "sum"
        else if ak == AK_SEQUENCE:
            head = "sequence"
        else if ak == AK_REF:
            head = "ref"
        else if ak == AK_PTR:
            head = "ptr"
        else if ak == AK_FN:
            head = "fn"
        else:
            head = "atom#" + int_str(ak)
        // 参数列表（AK_REF 的槽 0 是 mut 标记：语义为 &/&mut，照桥接约定还原）
        if ak == AK_REF && tt_c(t) >= 0 && tt_tag(tt_c(t)) == TT_CONS:
            m := tt_a(tt_c(t))
            mut_s : ., mut = "&"
            if tt_tag(m) == TT_ATOM && tt_a(m) == AK_UNIT && tt_b(m) == 1:
                mut_s = "&mut "
            rest := tt_b(tt_c(t))
            if rest >= 0 && tt_tag(rest) == TT_CONS:
                return mut_s + tt_display_at(tt_a(rest), depth + 1)
            return mut_s
        p := tt_c(t)
        if p < 0 || tt_tag(p) != TT_CONS:
            return head
        s : ., mut = head + "<"
        k : ., mut = 0
        loop:
            if p < 0:
                break
            if tt_tag(p) != TT_CONS:
                break
            if k > 0:
                s = s + ", "
            s = s + tt_display_at(tt_a(p), depth + 1)
            p = tt_b(p)
            k = k + 1
        return s + ">"
    return "?"

fn tt_display(t: int) -> string:
    return tt_display_at(t, 0)

// ═══════════════ 引擎展开层（named/struct/enum/generic-apply -> 结构项）═══════════════
// 语义边界（裁错即判定全面漂移，本层首要约束）：展开只服务两条路径
//   1 满足判定 `T <: 形状`（横切形状和用户接口；当前使用 type_engine.cr 的
//      `iface_satisfies` 占位）
//   2 穷尽性域/模式项（`sh_enum_domain_term` / `sh_variant_term`）
// 等价和包含判定（type_equal -> type_equal_engine -> sh_term_of_ti -> ty_equiv）
// 不经过本层。命名类型在等价判定中的身份是原子名义（AK_NAMED 加记录编号；
// sh_term_of_ti 的 NAMED 和 GENERIC_* 分支不改动）。把展开项接进等价判定会让
// two structurally equal structs with different names would compare equal. That
// is a semantic change and is forbidden.
// 检查用例是 unf.nominal_* 三例：展开项结构相等，桥接项 ty_equiv 判确定不同 0，
// type_equal 判 false 且不产生 ICE04。
// 深度 = 一层：字段/变体子项一律走既有 `sh_term_of_ti`（其命名/泛型分支不展开）
// -> 递归结构（`struct Node { next: *Node }`）在第二层即终止；一层不足 -> 按引擎既有约定
// -1 上抛（-1 = 不可展开/未实现情形，消费方按判定结果处理，不得不报错判否）。
// 非纯只读（诚实登记）：字段类型节点经 checker 的 `res_type_node` 解析（唯一实现，
// 本层不复制其语义），故对非基型字段可追加类型行（alloc_type/alloc_named_type）、并可能报
// EC_N_GENERIC_TYPE。与 checker.cr EXPR_FIELD（:2583-2606）的字段解析同源同径。当前没有
// 生产消费者；接入判定路径（/6）前须评估判定中途分配类型行的时序影响。
// 预算：展开步进计入引擎预算（`tt_step`），耗尽 -> -1（不得当 0/1）。范式与
// `ty_budget_reset` 的窗口隔离兼容（消费方在查询前 reset -> 展开步数计入该窗口）。

// ─── 展开项布局（/4/6 消费约定；按引擎比较逻辑设计）───
//  引擎的原子比较只看 `a`（原子类）与 `c`（参数列表）两槽（lit_implies:175-182；`b` 槽是
// 标注、不参与比较，AK_NAMED 的 b 槽 = 行号即此约定）-> 语义身份必须入参数列表，
// 否则两类不同声明会不报错合并（例：两个枚举的同名变体、两个不同枚举的域）。
//   struct -> tt_atom(AK_PRODUCT, ti, 字段列表)          // 列表顺序 = 声明序；结构项（同形同项）
//   enum   -> 各变体项之并（左深 union）= 域         // 空枚举 -> ⊥（无值可取，见下）
//   变体项 -> tt_atom(AK_SUM, ti, [枚举名令牌, 变体名令牌]) // 身份 = (枚举, 变体) 两名加入序列
//     （两名以 sh_name_token 原子加入序列，不再用裸 name 索引，见该函数注记）
// 变体项不含 payload：枚举表只存 payload 的裸 TY 码（parser.cr:1601 的 unpack_type；
// 非基型塌缩为 0 = TY_INT，与payload 是 int不可区分）-> 含入即不报错谎报；故 payload
// 不入项（未实现情形登记：携带值的满足判定尚未实现；若需要，须先扩枚举表存 payload
// type nodes, following the struct OFF_SI_FIELD_TYPE_NODES pattern). Exhaustiveness
// by variant identity is unaffected
// （现状模式检查亦不按 payload 分解，EXPR_ENUMPAT 的子模式是另一条路径）。

UNF_MAP_INIT_CAP : int = 256

// 展开缓存随类型表作废（同 sh_map_reset 同因同式：init_types 行号空间复用 -> 陈旧 ti->展开项
// 命中 = 把上一个请求的类型结构安到当前行上；长驻 corelsp 每请求一次 init_types）。
fn sh_unf_map_reset():
    g_unf_map_cap = 0
    g_unf_entries = 0
    g_unf_hits = 0

fn sh_unf_cap_init():
    if g_unf_map_cap <= 0:
        nc : ., mut = UNF_MAP_INIT_CAP
        nb := alloc(nc * 16)
        i : ., mut = 0
        loop:
            if i >= nc:
                break
            cell_store(nb, i * 16, -1)
            i = i + 1
        g_unf_map = nb
        g_unf_map_cap = nc

// 无检查探测（只可在扩容检查之后调用；重建重放借道），形态照 sh_map_find_nogrow
// （typed 探测用 ret + break + 尾 return；函数体不以无 break 的 loop 收尾，自托管 checker
// 对该形态有 TF01 误报情形，见该函数注记）。
fn sh_unf_find_nogrow(ti: int) -> int:
    cap := g_unf_map_cap
    p : ., mut = tt_mod(ti, cap)
    ret : ., mut = -1
    loop:
        k := cell_load(g_unf_map, p * 16)
        if k < 0:
            ret = p
            break
        if k == ti:
            ret = p
            break
        p = p + 1
        if p >= cap:
            p = 0
    return ret

fn sh_unf_find(ti: int) -> int:
    sh_unf_cap_init()
    // 装填因子检查（必须在探测前）：表满且键不存在时开放寻址永不退出（死循环）
    if (g_unf_entries + 1) * 2 >= g_unf_map_cap:
        sh_unf_rehash()
    return sh_unf_find_nogrow(ti)

// 扩容 = 重建 + 重放既有条目（引擎 grow_tt_index / 桥接 sh_map_rehash 同式）；计数随重放重算
fn sh_unf_rehash():
    old := g_unf_map
    old_cap := g_unf_map_cap
    nc : ., mut = old_cap * 2
    if nc < UNF_MAP_INIT_CAP:
        nc = UNF_MAP_INIT_CAP
    nb := alloc(nc * 16)
    i : ., mut = 0
    loop:
        if i >= nc:
            break
        cell_store(nb, i * 16, -1)
        i = i + 1
    g_unf_map = nb
    g_unf_map_cap = nc
    g_unf_entries = 0
    j : ., mut = 0
    loop:
        if j >= old_cap:
            break
        k := cell_load(old, j * 16)
        if k >= 0:
            s := sh_unf_find_nogrow(k)
            cell_store(g_unf_map, s * 16, k)
            cell_store(g_unf_map, s * 16 + 8, cell_load(old, j * 16 + 8))
            g_unf_entries = g_unf_entries + 1
        j = j + 1

fn sh_unf_hits() -> int:
    return g_unf_hits
fn sh_unf_entries() -> int:
    return g_unf_entries

// 枚举变体名 -> 变体下标（-1 = 该枚举无此变体名）。线性扫描（变体数量没有上限）。
fn sh_enum_variant_index(ea: int, name_ni: int) -> int:
    i : ., mut = 0
    ret : ., mut = -1
    loop:
        if i >= ei_variant_count(ea):
            break
        if ei_variant_name(ea, i) == name_ni:
            ret = i
            break
        i = i + 1
    return ret

// struct 第 fi 字段 -> 项（-1 = 不可展开）。泛型形参替换照 checker.cr EXPR_FIELD 的路径
// （那里返回 ti、消费方是 checker；此处返回项）：字段节点为 EXPR_IDENT 且名字 ∈ 该 struct 的
// 泛型形参名表 -> 从泛型应用实参（ga，g_gen_apply_data: [count, arg1, …]）取对应实参项；
// 其余（非形参 / 非应用形态 / 实参缺位）-> 经 res_type_node 解析字段类型节点。
// In a non-application form a generic parameter stays nominal: res_type_node
// returns its type row as an AK_NAMED atom. The code does not invent an argument.
// Nested substitution such as Box[Box[T]] is not reachable today because
// parameters are substituted one level only, consistent with checker.
fn sh_struct_field_term(sa: int, fi: int, ga: int) -> int:
    fnode := si_field_type_node(sa, fi)
    if fnode < 0:
        return -1
    if ast_kind(fnode) == EXPR_IDENT:
        fni := ast_int_val(fnode)
        if is_struct_generic(sa, fni):
            if ga >= 0 && get_type_kind(ga) == TYP_GENERIC_APPLY:
                gstart := get_type_extra(ga)
                gcnt := cell_load(g_gen_apply_data, gstart * 8)
                gpi : ., mut = 0
                loop:
                    if gpi >= si_generic_count(sa):
                        break
                    if si_generic_name(sa, gpi) == fni:
                        if gpi < gcnt:
                            return sh_term_of_ti(cell_load(g_gen_apply_data, (gstart + 1 + gpi) * 8))
                        break   // 实参缺位 -> 落空到名义项（下方 res_type_node），不得取越界槽
                    gpi = gpi + 1
    fti := res_type_node(fnode)
    if fti < 0:
        return -1
    return sh_term_of_ti(fti)

// struct 命名行 / 泛型应用行 -> AK_PRODUCT（参数列表 = 逐字段项，声明序）。
// -1 = 不可展开（既非命名行也非泛型应用行 / 名字未声明为 struct / 任一字段不可展开 / 预算耗尽）。
fn sh_struct_term(ti: int) -> int:
    if ti < 0:
        return -1
    if get_type_kind(ti) < 0:
        return -1
    // 行号越界（ti ≥ g_type_count）
    sa := find_struct_row_of(ti)
    if sa < 0:
        return -1
    slot := sh_unf_find(ti)
    if cell_load(g_unf_map, slot * 16) == ti:
        g_unf_hits = g_unf_hits + 1
        return cell_load(g_unf_map, slot * 16 + 8)
    ga : ., mut = -1
    if get_type_kind(ti) == TYP_GENERIC_APPLY:
        ga = ti
    // CONS 列表逆序构造（i 自末尾向前）：DAG 项不可变，正向追加需改写已建项；逆序构造的
    // 结果顺序仍 = 声明序（照 sh_tuple_to_product 同款同因）。
    tail : ., mut = tt_nil()
    i : ., mut = si_field_count(sa) - 1
    loop:
        if i < 0:
            break
        if tt_step() == -1:
            return -1
        // 预算耗尽 -> 上抛（不得当空 product）
        ft := sh_struct_field_term(sa, i, ga)
        if ft < 0:
            return -1
        // 任一字段不可展开 -> 整项不可展开（不缓存）
        tail = tt_cons(ft, tail)
        i = i - 1
    term := tt_atom(AK_PRODUCT, ti, tail)
    // 写回前重探（字段解析期间可能已扩容，照 sh_term_of_ti 注记2同款）
    slot2 := sh_unf_find(ti)
    if cell_load(g_unf_map, slot2 * 16) == ti:
        g_unf_hits = g_unf_hits + 1
        return cell_load(g_unf_map, slot2 * 16 + 8)
    cell_store(g_unf_map, slot2 * 16, ti)
    cell_store(g_unf_map, slot2 * 16 + 8, term)
    g_unf_entries = g_unf_entries + 1
    return term

// 变体名 -> 变体项（穷尽性模式项用；与域中的对应变体项同一构造，两者必须逐位相同，
// 否则补集判定失真）。name_ni 必须是该枚举声明过的变体名（否则 -1：不得为未声明变体臆造项）。
// ti 接受命名行与泛型应用行（变体身份与实参无关，payload 不入项时 Option[int]/Option[str]
// 的变体集相同，正是穷尽性所需）。
fn sh_variant_term(ti: int, name_ni: int) -> int:
    ea := find_enum_row_of(ti)
    if ea < 0:
        return -1
    if sh_enum_variant_index(ea, name_ni) < 0:
        return -1
    // 身份两名经 sh_name_token 加入序列（当前约定 = 裸 name 索引加入序列，索引用作
    // 序列元素时会被结构比较当术语下标解释，见 sh_name_token 注记）；两构造点（域/模式项）
    // 仍逐位同一 ✓
    return tt_atom(AK_SUM, ti, tt_cons(sh_name_token(ei_name(ea)), tt_cons(sh_name_token(name_ni), tt_nil())))

// enum 命名行 / 泛型应用行 -> 域 = 各变体项之并（左深 union）。
// Returns -1 when the row is not an enum or the budget is exhausted. An empty
// enum (0 variants) becomes bottom, meaning no value. It is the only successful
// expansion with an empty domain; exhaustiveness must handle it explicitly, and
// an empty domain is always exhaustive under complement semantics.
fn sh_enum_domain_term(ti: int) -> int:
    if ti < 0:
        return -1
    if get_type_kind(ti) < 0:
        return -1
    ea := find_enum_row_of(ti)
    if ea < 0:
        return -1
    slot := sh_unf_find(ti)
    if cell_load(g_unf_map, slot * 16) == ti:
        g_unf_hits = g_unf_hits + 1
        return cell_load(g_unf_map, slot * 16 + 8)
    acc : ., mut = tt_bot()
    i : ., mut = 0
    loop:
        if i >= ei_variant_count(ea):
            break
        if tt_step() == -1:
            return -1
        v := sh_variant_term(ti, ei_variant_name(ea, i))
        if v < 0:
            return -1
        acc = tt_union(acc, v)
        i = i + 1
    slot2 := sh_unf_find(ti)
    if cell_load(g_unf_map, slot2 * 16) == ti:
        g_unf_hits = g_unf_hits + 1
        return cell_load(g_unf_map, slot2 * 16 + 8)
    cell_store(g_unf_map, slot2 * 16, ti)
    cell_store(g_unf_map, slot2 * 16 + 8, acc)
    g_unf_entries = g_unf_entries + 1
    return acc

// 接口 -> 形状项（方法集 = product of fn），仍为占位，恒 -1（阻塞精确定位见下）：
// 现状接口方法签名存裸 TY_*（parser.cr:1671/1685 的 `unpack_type` -> 非原生类型节点一律
// ═══════════════ 签名规范项 + 接口形状项 ═══════════════
// 语义（spec 2.3interface I -> 形状类型项：方法集 = product of fn 原子（方法签名各自为
// fn(τ₁…τₙ)->τ item): this is the only signature-item construction point. The
// signature slots OFF_IFM_PARAM_NODES and OFF_IFM_RET_NODE hold type nodes, so
// signatures use types rather than mapping-layer codes.
//
// 为什么需要规范形，而不是直接复用 sh_term_of_ti 的项：判定走引擎 ty_sub，
// 引擎在不变槽上按节点同一性比较序列元素（tt_list_same），并且不展开 AK_NAMED。
// 直接桥接的项有两个身份问题：
//   1. TYP_GENERIC_APPLY 记录经 alloc_type 裸分配，不去重，同型两次出现是不同
//      节点，同签名会被判不同，产生假违反。
//   2. 序列项的 b 槽（N 或固定性）在节点同一性下进入身份，[int;3] 和 [int;4]
//      会被判不同，与 N 不属于身份的不变量冲突。N 长度约束由常量档承担。
// 规范形把身份维度放进项，其余归一：泛型应用 = 基名记录（named_dedup 已按名
// 规范）加实参列表；序列 = N 归 -1；指针 = asp 不进入项；命名记录 = 记录编号
// （按名规范）；引用 = mut 标记进入项。这样同型恒同节点，异型恒异节点，
// 引擎的 ty_sub 就给出签名相等判定（1/0；-1 只剩建项失败）。
// dyn（位图行不参与规范形）与未知 kind -> -1（未实现情形，不得当 0/1）。
// 零 str_intern：全部走既有 ni/行（.ccr STR 段守）。
fn sh_sig_term_of_ti(ti: int) -> int:
    if ti < 0:
        return -1
    k := get_type_kind(ti)
    if k < 0:
        return -1
    if k == TYP_BASE:
        d := get_type_data(ti)
        ak := sh_base_ak(d)
        if ak < 0:
            return -1
        return tt_atom(ak, ti, -1)
    if k == TYP_NAMED || k == TYP_GENERIC_PARAM:
        // 命名行：named_dedup 按名规范（同名恒同行）；泛型形参行 = 声明点行（跨声明不同行 =
        // 已登记数据：签名内含泛型形参的匹配只在同一声明内成立）
        // 身份令牌序列与 sh_term_of_ti 的命名分支逐位同构（同一 sh_name_token
        // sequence structure). Both construction points must change together.
        return sh_named_identity_term(ti)
    if k == TYP_NULL:
        return sh_null_term()
    if k == TYP_ARRAY || k == TYP_SLICE:
        el := sh_sig_term_of_ti(get_type_data(ti))
        if el < 0:
            return -1
        return tt_atom(AK_SEQUENCE, -1, tt_cons(el, tt_nil()))
    if k == TYP_PTR:
        el2 := sh_sig_term_of_ti(get_type_data(ti))
        if el2 < 0:
            return -1
        return tt_atom(AK_PTR, -1, tt_cons(el2, tt_nil()))
    if k == TYP_REF:
        el3 := sh_sig_term_of_ti(get_type_data(ti))
        if el3 < 0:
            return -1
        return tt_atom(AK_REF, -1, tt_cons(sh_ref_mut_marker(get_type_extra(ti)), tt_cons(el3, tt_nil())))
    if k == TYP_OPTIONAL:
        el4 := sh_sig_term_of_ti(get_type_data(ti))
        if el4 < 0:
            return -1
        return tt_union(el4, sh_null_term())
    if k == TYP_TUPLE:
        cnt := get_type_data(ti)
        start := get_type_extra(ti)
        tail : ., mut = tt_nil()
        i : ., mut = cnt - 1
        loop:
            if i < 0:
                break
            et := sh_sig_term_of_ti(cell_load(g_gen_apply_data, (start + i) * 8))
            if et < 0:
                return -1
            tail = tt_cons(et, tail)
            i = i - 1
        return tt_atom(AK_PRODUCT, -1, tail)
    if k == TYP_GENERIC_APPLY:
        // 形态与 sh_term_of_ti 的 APPLY 分支同构（基型行 + [基名令牌,
        // 实参项…]），不再只挂裸实参列表（那是基型行当身份的当前形态：与桥接侧命名分支
        // 失同步 -> 两构造点对同型给出不同节点）。差别只剩实参项递归走本构造点
        // （variant=1：签名数据 N 不入项，见 sh_apply_args_chain 注）。
        return sh_apply_identity_term(ti, 1)
    return -1   // TYP_DYN（位图行）/ 未知 kind：未实现情形

// 类型节点 -> 签名项（节点契约：<0 = 无节点 -> unit；照 checker 的 `type_node > 0` 约定，
// 但用 -1 哨兵以免与节点 0混同）。res_type_node 的解析入口与其他消费点相同。
fn sh_sig_term_of_node(node: int) -> int:
    if node < 0:
        return sh_sig_term_of_ti(TI_UNIT)
    ti := res_type_node(node)
    return sh_sig_term_of_ti(ti)

// 接口方法签名的参数项（idx 自 0 起）。接收者槽（self_mode ≠ 0 且 idx == 0）= unit
// 占位，接收者模式（self/&self/&mut self）是调用约定而非类型集维度，由消费方显式比较
//（`sh_iface_self_mode` / `sh_func_self_mode`）；不为它造令牌原子的理由：令牌的 b 槽在引擎
// 的类级比较（只看 a/c 两槽）下不可见 -> 模式 1/2/3 会互相判等（不报错）。
fn sh_iface_sig_param_term(ii: int, mi: int, idx: int) -> int:
    if ii < 0 || mi < 0 || idx < 0:
        return -1
    if idx >= MAX_IFACE_METHOD_PARAMS:
        return -1
    mbase := ii * ESZ_IFACEINFO + OFF_IF_METHODS + mi * ESZ_IFMETHOD
    if cell_load(g_ifaces, mbase + OFF_IFM_PARAM_COUNT) <= idx:
        return -1
    smode := cell_load(g_ifaces, mbase + OFF_IFM_SELF_MODE)
    if idx == 0 && smode != 0:
        return sh_sig_term_of_ti(TI_UNIT)
    return sh_sig_term_of_node(cell_load(g_ifaces, mbase + OFF_IFM_PARAM_NODES + idx * 8))

fn sh_iface_sig_ret_term(ii: int, mi: int) -> int:
    if ii < 0 || mi < 0:
        return -1
    mbase := ii * ESZ_IFACEINFO + OFF_IF_METHODS + mi * ESZ_IFMETHOD
    return sh_sig_term_of_node(cell_load(g_ifaces, mbase + OFF_IFM_RET_NODE))

fn sh_iface_self_mode(ii: int, mi: int) -> int:
    if ii < 0 || mi < 0:
        return -1
    return cell_load(g_ifaces, ii * ESZ_IFACEINFO + OFF_IF_METHODS + mi * ESZ_IFMETHOD + OFF_IFM_SELF_MODE)

// impl 侧（函数行）签名的参数项（idx 自 0 起；从 AST 参数列表前扫解析，形参节点不连续，
// 每参的类型节点插在其后，照 ir_gen/checker 同款扫描约定）。接收者槽同占位约定。
fn sh_func_sig_param_term(fi: int, idx: int) -> int:
    if fi < 0 || idx < 0:
        return -1
    fn_node := fi_ast_node(fi)
    if fn_node < 0:
        return -1
    if ast_kind(fn_node) != EXPR_FN:
        return -1
    if idx >= fi_param_count(fi):
        return -1
    pn := ast_b(fn_node)   // EXPR_FN: b = first param node（a = 函数名 ni，不是形参入口）
    pi : ., mut = 0
    loop:
        if pn < 0:
            return -1
        if pn >= g_ast_count:
            return -1
        if ast_kind(pn) == EXPR_PARAM:
            if pi == idx:
                mode := ast_int_val(pn)
                if mode == -1:
                    return -1
                // 变参：签名项不可表达（登记）
                if mode != 0:
                    return sh_sig_term_of_ti(TI_UNIT)
                return sh_sig_term_of_node(ast_data(pn))
            pi = pi + 1
        pn = pn + 1
    return -1

fn sh_func_self_mode(fi: int) -> int:
    if fi < 0:
        return -1
    fn_node := fi_ast_node(fi)
    if fn_node < 0:
        return -1
    if ast_kind(fn_node) != EXPR_FN:
        return -1
    if fi_param_count(fi) <= 0:
        return 0
    pn := ast_b(fn_node)   // EXPR_FN: b = first param node
    loop:
        if pn < 0:
            return -1
        if pn >= g_ast_count:
            return -1
        if ast_kind(pn) == EXPR_PARAM:
            m := ast_int_val(pn)
            if m == -1:
                return -1
            return m
        pn = pn + 1
    return -1

// impl 侧函数行的返回项（解析规则 = check_func 的返回位逐字同款：非基型节点走
// res_type_node；基型/无节点走码表（域含 NEVER、缺 7 -> unit 后备））。
fn sh_func_sig_ret_term(fi: int) -> int:
    if fi < 0:
        return -1
    fn_node := fi_ast_node(fi)
    if fn_node < 0:
        return -1
    if ast_kind(fn_node) != EXPR_FN:
        return -1
    rnode := ast_type_val(fn_node)
    ret_ti : ., mut = TI_UNIT
    if rnode > 0 && ast_kind(rnode) != 0:
        ret_ti = res_type_node(rnode)
    else:
        rm := ty_code_to_ti(fi_return_type(fi))
        if rm >= 0 && rm != TI_DYN:
            ret_ti = rm
    return sh_sig_term_of_ti(ret_ti)

// 函数行 -> fn 项：`tt_atom(AK_FN, -1, [返回项, 参数项…])`（列表顺序 = 返回在首，参数按声明序；
// 逆序构造，照 sh_tuple_to_product 同因）。b 槽留空（引擎比较只看 a/c -> 方法名不参与判定）。
fn sh_func_sig_term(fi: int) -> int:
    if fi < 0:
        return -1
    pc := fi_param_count(fi)
    if pc < 0 || pc > MAX_FN_PARAMS:
        return -1
    rt := sh_func_sig_ret_term(fi)
    if rt < 0:
        return -1
    tail : ., mut = tt_cons(rt, tt_nil())
    i : ., mut = pc - 1
    loop:
        if i < 0:
            break
        pt := sh_func_sig_param_term(fi, i)
        if pt < 0:
            return -1
        tail = tt_cons(pt, tail)
        i = i - 1
    return tt_atom(AK_FN, -1, tail)

// 接口 -> 形状类型项（spec 2.3）：`tt_atom(AK_PRODUCT, -1, [fn 项…])`，列表顺序 = 方法声明序
// （与 `g_ifaces` 方法表同序，消费方按表索引取成员，见 type_engine 的轴 C）。成员 fn 项的
// b 槽 = 方法名 ni（消费方的查表键；引擎不比较 b，本层显式读取）。
// -1 = 不可建（接口名未声明 / 方法数越界（>16）/ 任一签名项不可建 / 参数数越界（>8））。
// 零方法接口 -> 空 product（空列表），空方法集满足的表示（判定逻辑见轴 C）。
// 判定规则：-1 = 未实现情形，不得被消费方当 0（不满足）或 1（满足）用。
fn sh_iface_shape_term(iface_ni: int) -> int:
    if iface_ni < 0:
        return -1
    ii := find_iface(iface_ni)
    if ii < 0:
        return -1
    mc := cell_load(g_ifaces, ii * ESZ_IFACEINFO + OFF_IF_METHOD_COUNT)
    if mc < 0:
        return -1
    if mc > MAX_IFACE_METHODS:
        return -1
    tail : ., mut = tt_nil()
    i : ., mut = mc - 1
    loop:
        if i < 0:
            break
        mbase := ii * ESZ_IFACEINFO + OFF_IF_METHODS + i * ESZ_IFMETHOD
        m_ni := cell_load(g_ifaces, mbase + OFF_IFM_NAME)
        pc := cell_load(g_ifaces, mbase + OFF_IFM_PARAM_COUNT)
        if pc < 0 || pc > MAX_IFACE_METHOD_PARAMS:
            return -1
        rt2 := sh_iface_sig_ret_term(ii, i)
        if rt2 < 0:
            return -1
        ptail : ., mut = tt_cons(rt2, tt_nil())
        pj : ., mut = pc - 1
        loop:
            if pj < 0:
                break
            pterm := sh_iface_sig_param_term(ii, i, pj)
            if pterm < 0:
                return -1
            ptail = tt_cons(pterm, ptail)
            pj = pj - 1
        tail = tt_cons(tt_atom(AK_FN, m_ni, ptail), tail)
        i = i - 1
    return tt_atom(AK_PRODUCT, -1, tail)

// 形状项的第 idx 个成员（fn 项；-1 = 越界/非形状项）。消费方（轴 C）按方法表索引取用。
fn sh_shape_member_at(shp: int, idx: int) -> int:
    if shp < 0 || idx < 0:
        return -1
    if tt_tag(shp) != TT_ATOM:
        return -1
    if tt_a(shp) != AK_PRODUCT:
        return -1
    c := tt_c(shp)
    i : ., mut = 0
    loop:
        if i > idx:
            return -1
        if c < 0:
            return -1
        if tt_tag(c) != TT_CONS:
            return -1
        if i == idx:
            return tt_a(c)
        c = tt_b(c)
        i = i + 1
    return -1

// ─── 序列行的固定性读取（range 消费点的表示层维度）───
// 返回：固定长序列的 N（数组，≥0）/ -1（视图（切片）/ 非序列行 / 不可译行）。
// 依据 = 序列项的 b 槽（`sh_seq_term`：数组 = N、切片/视图 = -1），表示提示层，
// Semantic judgments ignore N (spec 5.1: N is a representation hint, and the
// fixed-length bit is not part of identity or comparison). The consumers are the
// constant-range check, the representation layer, and shape data.
// 用途 = checker 的 range 索引分支（`arr[lo..hi]`）：固定长 -> 产视图（`[T]`）；视图 -> 现状
// `TI_UNIT`（IP_INDEX_RANGE 未接线，登记数据）。不得把它读作身份/子类型维度（那是常量档的
// 职责；本站只决定range 在本行上产不产视图的结果形态，行为与改动前逐行相同）。
fn sh_seq_fixed_len_of_ti(ti: int) -> int:
    t := sh_term_of_ti(ti)
    if t < 0:
        return -1
    if tt_tag(t) != TT_ATOM:
        return -1
    if tt_a(t) != AK_SEQUENCE:
        return -1
    return tt_b(t)

// ═══════════════ match 穷尽性消费点（补集空性 + 具体变体反例）═══════════════
// 判据本体 = 引擎的补集空性（`ty_exhaustive`：domain \ ⋃patterns 的可满足性； 已落）。
// 引擎不在本文件范围内-> 引擎侧的两处缺口一律在消费点消化：
//   1 域检查（域限定，计划显式登记）：仅枚举 scrutinee 判穷尽（域 = 变体集）；
//      scrutinee 非枚举/域不可展开（struct/原生/int/string/bool…）-> 不判（-1）。非枚举域
//      不得假装穷尽、不得假装不穷尽，故本层零诊断、零编译失败误。
//   2 模式检查：任一臂模式不可忠实映射 -> 不判（-1）。不可映射 = 字面量模式
//      （int/string/char/bool）/ struct 模式 / 非本枚举的变体名。不得把它们当 ∅（凭空判
//      不穷尽）或当 ⊤（凭空判穷尽），判定规则：未知一律 -1，由消费方零动作。
//   3 反例的具体值：引擎 witness 的原始形态 = 各析取支之并（`tt_norm` 不做空支净化：
//      when B is missing it can be (A∩¬A)∪(B∩¬A), which ty_equiv does not equate
//      with the missing variant)
//      -> 反例不取 witness 项，而按变体逐项覆盖位命名（`sh_match_first_missing`）：
//      与引擎判据同源（同一变体项构造）但独立计算 -> 两路一致性由自测用例固定。
// 模式项约定（与展开层/引擎对齐）：通配 `_` 与绑定 ident = `tt_top()`（引擎侧 ⊤ 覆盖 = 覆盖
// 一切；值域不绑）；变体模式 = `sh_variant_term(scrut_ti, vni)`，与域内对应变体同一构造
// （两个构造点不同 -> 补集判定失真）。

// 臂模式 -> 类别：1 = ⊤（通配 `_` / 绑定 ident）/ 2 = 枚举变体模式（须再判归属）/ 0 = 不可映射。
fn sh_match_pat_kind(pat_node: int) -> int:
    if pat_node < 0:
        return 0
    k := ast_kind(pat_node)
    if k == EXPR_WILDCARD:
        return 1
    if k == EXPR_IDENT:
        return 1
    // 绑定 = 通配（值域不绑；与 ir_gen 的按值比较臂不同层）
    if k == EXPR_ENUMPAT:
        return 2
    return 0                               // 字面量 / struct 模式 / tuple 模式 / EXPR_NONE -> 不可映射（登记）

// 字面量模式种类（int/bool/string/char），-1 = 非字面量模式。
// 这些模式在 checker 侧可逐值比较，但域是无限的（bool 除外），因此没有
// `_`/绑定臂时一律按不穷尽处理；枚举域仍走类型引擎。
fn sh_match_lit_kind(pat_node: int) -> int:
    if pat_node < 0:
        return -1
    k := ast_kind(pat_node)
    if k == EXPR_INT || k == EXPR_BOOL || k == EXPR_STRING || k == EXPR_CHAR:
        return k
    return -1

// 同一字面量（kind + value）是否已在前面的臂出现（首个匹配语义）。
fn sh_match_lit_seen(first_arm: int, cur_arm: int, kind: int, value: int) -> int:
    an := first_arm
    loop:
        if an < 0 || an == cur_arm:
            break
        p := ast_a(an)
        if p >= 0:
            if ast_kind(p) == kind && ast_int_val(p) == value:
                return 1
        an = ast_c(an)
    return 0

// 模式子树的最小节点下标。parser 先分配子模式节点、最后分配外层模式节点；
// 复合子模式（X(y)）的根下标高于自己的后代，因此 ast_b 不是子树起点，必须递归到
// 第一个子模式（parser.cr parse_pattern 的分配序：子先父后）。
fn sh_match_pat_subtree_start(p: int) -> int:
    if p < 0:
        return -1
    k := ast_kind(p)
    if k == EXPR_ENUMPAT:
        if ast_c(p) > 0:
            c := ast_b(p)
            if c >= 0 && c < p:
                s := sh_match_pat_subtree_start(c)
                if s >= 0 && s < p:
                    return s
    else if k == EXPR_STRUCTPAT:
        if ast_c(p) > 0:
            w := ast_b(p)
            if w >= 0 && w < p:
                c := ast_a(w)
                if c >= 0 && c < p:
                    s := sh_match_pat_subtree_start(c)
                    if s >= 0 && s < p:
                        return s
    else if k == EXPR_TUPLEPAT:
        // Tuple patterns use the array/tuple wrapper contract: a=first wrapper,
        // b=element count, wrapper.a=subpattern.
        if ast_b(p) > 0:
            w := ast_a(p)
            if w >= 0 && w < p:
                c := ast_a(w)
                if c >= 0 && c < p:
                    s := sh_match_pat_subtree_start(c)
                    if s >= 0 && s < p:
                        return s
    return p

// Enum payload 内的首个 refutable 节点（-1 = 全部为 ident/wildcard）。
// 扫描区间 = [首个子模式子树起点, pat_node)。parser 在分配外层节点前连续分配
// 完整 payload 子树，因此该区间覆盖所有子模式，包括“复合子模式不在首位”的
// A(x, X(y)) —— 只按 ast_b + i 会漏掉后面的复合子模式。
fn sh_match_payload_bad(pat_node: int) -> int:
    if pat_node < 0:
        return -1
    count := ast_c(pat_node)
    if count <= 0:
        return -1
    first := ast_b(pat_node)
    if first < 0 || first >= pat_node:
        return pat_node
    start := sh_match_pat_subtree_start(first)
    if start < 0 || start >= pat_node:
        return pat_node
    i := start
    loop:
        if i >= pat_node:
            return -1
        k := ast_kind(i)
        if k != EXPR_IDENT && k != EXPR_WILDCARD:
            return i
        i = i + 1
    return -1

// 变体模式 -> 本枚举变体下标（-1 = 不属本枚举 / 名字不可解析 / scrutinee 不可展开）。
// 名字有两种形态（parser.cr parse_pattern 的产物）：裸变体名 Red，或限定名
// Color.Red（parser 用 name + "." + variant 拼接）。限定名取最后一个点之后的段
// 作为变体名，规则与 ir_gen.cr 的 get_variant_name_idx 一致。此处不调用
// str_intern，.ccr STR 段是 g_strs 全量，见附录 A.3-2 的硬性约束。前缀不是
// 本枚举名时返回 -1：该模式对本域没有覆盖，但按第 2 条取不可判，而不是空集。
// 变体名用 str_eq 逐项比较，不驻留新串。
fn sh_match_pat_variant(scrut_ti: int, pat_node: int) -> int:
    ea := find_enum_row_of(scrut_ti)
    if ea < 0:
        return -1
    if pat_node < 0:
        return -1
    // 名字槽 = a（parser.cr parse_pattern：`alloc_node(EXPR_ENUMPAT, ni, …)`；ir_gen 的
    // 消费点同用 ast_a 取之。不是 int_val，EXPR_IDENT 才把名字放 int_val）。
    pname := istr_get(ast_a(pat_node))
    slen := str_len(pname)
    dot : ., mut = -1
    i : ., mut = 0
    loop:
        if i >= slen:
            break
        c := get_char(pname, i)
        if str_eq(c, ".") != 0:
            dot = i
        i = i + 1
    vname : ., mut = pname
    if dot >= 0:
        head := str_sub(pname, 0, dot)
        if str_eq(head, istr_get(ei_name(ea))) == 0:
            return -1
        vname = str_sub(pname, dot + 1, slen - dot - 1)
    vi : ., mut = 0
    loop:
        if vi >= ei_variant_count(ea):
            return -1
        if str_eq(istr_get(ei_variant_name(ea, vi)), vname) != 0:
            return vi
        vi = vi + 1
    return -1

// 变体下标 -> 变体项（-1 = 越界/scrutinee 不可展开）；与 sh_variant_term 的唯一入口关系
fn sh_match_variant_term(scrut_ti: int, vi: int) -> int:
    ea := find_enum_row_of(scrut_ti)
    if ea < 0:
        return -1
    if vi < 0 || vi >= ei_variant_count(ea):
        return -1
    return sh_variant_term(scrut_ti, ei_variant_name(ea, vi))

// Unbounded match coverage bitmap.
// After the variant limit was removed, 2^vi overflows at vi >= 63 and corrupts
// coverage decisions.
// 位图 = 字节缓冲（每字节 8 位）+ 位下标寻址（本语言无按位与 -> 除法/取模，照 iface_permits
// 惯例）；栈纪律：`mc_begin` 记长度、`mc_end` 清零回退 -> 嵌套 match 互不破坏。
fn grow_cov_bits(needed: int):
    if needed <= g_cov_cap:
        return
    nc := g_cov_cap * 2
    if nc < 64:
        nc = 64
    if nc < needed:
        nc = needed + 64
    nb := alloc(nc)
    cell_copy(g_cov_bits, g_cov_cap, nb)
    z : ., mut = g_cov_cap
    loop:
        if z >= nc:
            break
        cell_store_byte(nb, z, 0)
        z = z + 1
    g_cov_bits = nb
    g_cov_cap = nc
// 进入一次 match 覆盖收集：返回当前长度（供 mc_end 回退）
fn mc_begin() -> int:
    return g_cov_len
fn mc_add(vi: int):
    if vi < 0:
        return
    grow_cov_bits(vi / 8 + 1)
    if vi + 1 > g_cov_len:
        g_cov_len = vi + 1
    b := cell_load8(g_cov_bits, vi / 8)
    pw : ., mut = 1
    k : ., mut = vi % 8
    loop:
        if k <= 0:
            break
        pw = pw * 2
        k = k - 1
    if (b / pw) % 2 == 0:
        cell_store_byte(g_cov_bits, vi / 8, b + pw)
fn mc_has(vi: int) -> int:
    if vi < 0:
        return 0
    if vi >= g_cov_len:
        return 0
    if vi / 8 >= g_cov_cap:
        return 0
    b := cell_load8(g_cov_bits, vi / 8)
    pw : ., mut = 1
    k : ., mut = vi % 8
    loop:
        if k <= 0:
            break
        pw = pw * 2
        k = k - 1
    return (b / pw) % 2
// 首个未覆盖位（-1 = 全覆盖）；判定结果口径与 sh_match_first_missing 同
fn mc_first_missing(count: int) -> int:
    i : ., mut = 0
    loop:
        if i >= count:
            return -1
        if mc_has(i) == 0:
            return i
        i = i + 1
    return -1
// 退出：清零本层用过的位并回退长度（嵌套安全）
fn mc_end(saved: int):
    i : ., mut = saved
    loop:
        if i >= g_cov_len:
            break
        if i / 8 < g_cov_cap:
            cell_store_byte(g_cov_bits, i / 8, 0)
        i = i + 1
    g_cov_len = saved

// Coverage bit for the legacy selftest API, limited to domains of at most 62
// variants: bit(vi) = 2^vi, built by doubling because the language has no shift.
// Production paths use the unbounded mc_* bitmap. This function overflows at
// vi >= 63.
fn sh_match_bit(vi: int) -> int:
    if vi < 0:
        return 0
    b : ., mut = 1
    k : ., mut = vi
    loop:
        if k <= 0:
            break
        b = b * 2
        k = k - 1
    return b

// 首个未覆盖变体下标（-1 = 全覆盖 = 反例集为空）。反例命名 = 本函数（头注3）；位测试照
// iface_permits 的 (bits / bit) % 2 惯例（无按位与运算符；bits ≥ 0、bit > 0 -> 取模非负）。
fn sh_match_first_missing(cover_bits: int, count: int) -> int:
    i : ., mut = 0
    loop:
        if i >= count:
            return -1
        b := sh_match_bit(i)            // i ≥ 0 -> b ≥ 1（除零不可达）
        if (cover_bits / b) % 2 == 0:
            return i
        i = i + 1
    return -1

// 穷尽性判定结果：1 = 穷尽（补集空）/ 0 = 不穷尽（有反例变体）/ -1 = 不判（域不可展开 /
// 模式不可映射 / 引擎未知=预算耗尽）。消费方：0 -> 诊断 + 反例命名；1/-1 -> 零动作。
// 域扩一条 ， `T?`（TYP_OPTIONAL）的域 = `T ∪ null`（sh_match_domain_term）。
fn sh_match_exhaustive(scrut_ti: int, pat_terms: int, unmappable: int) -> int:
    if unmappable != 0:
        return -1
    dom := sh_match_domain_term(scrut_ti)
    if dom < 0:
        return -1
    // 非枚举/非可选域 -> 不判（域限定的显式登记）
    return ty_exhaustive(dom, pat_terms)

// ═══════════════ 联合/可选（`T?` = `T ∪ null`）的 match 域 ═══════════════
// 域：枚举行 -> 变体集之并（/3 的 sh_enum_domain_term）；TYP_OPTIONAL 行 -> T ∪ null。
// 分支（两分，与 spec 5.4 的T? 两分支：有值 + None一致）：
//   0 = 有值部分（`Some(…)` 模式；项 = 内层项本身，`T?` 的值域含裸 T 值，见 checker 的行语义）
//   1 = null 部分（`None` 模式；项 = sh_null_term()）
// 判定规则：非可选 scrutinee -> -1（不判）；可选 scrutinee 上的异域模式（别的变体名/字面量）
// -> -1（不可映射，同  的2：不得当 ∅ 或 ⊤）。
// 名字形态：仅裸名 `Some`/`None`（限定名不接受，可选无类型名可作前缀；用户声明
// `enum Option` 时那走枚举域那条路，与本路互不干扰）。
fn sh_match_domain_term(ti: int) -> int:
    if ti < 0:
        return -1
    if get_type_kind(ti) == TYP_OPTIONAL:
        in5 := sh_term_of_ti(get_type_data(ti))
        if in5 < 0:
            return -1
        // 内层不可译 -> 域不可展开（不判）
        return tt_union(in5, sh_null_term())
    return sh_enum_domain_term(ti)

// 可选模式 -> 分支下标（0 = 有值 / 1 = null；-1 = 不可映射或非可选 scrutinee）。
// 名字槽 = ast_a（EXPR_ENUMPAT 契约， 6-2）；`Some`/`None` 是关键字名。
fn sh_match_opt_pat(scrut_ti: int, pat_node: int) -> int:
    if scrut_ti < 0:
        return -1
    if get_type_kind(scrut_ti) != TYP_OPTIONAL:
        return -1
    if pat_node < 0:
        return -1
    pname := istr_get(ast_a(pat_node))
    if str_eq(pname, "Some") != 0:
        return 0
    // `Some(…)` 与裸 `Some` 同判（携带值绑定不参与）
    if str_eq(pname, "None") != 0:
        return 1
    return -1

// 分支下标 -> 覆盖项（与 sh_match_domain_term 的析取支同一构造，两个构造点不同 -> 补集失真）。
fn sh_match_opt_term(scrut_ti: int, part: int) -> int:
    if part == 0:
        return sh_term_of_ti(get_type_data(scrut_ti))
    return sh_null_term()

// Payload item construction for enum variants; the only reader of the payload type-node column.
// The older enum layout stored only a raw TY code (OFF_EV_TYPES), so a payload
// that was not a base type collapsed to 0 = TY_INT. An int payload was then
// indistinguishable from string, named, or generic payloads. OFF_EV_TYPE_NODES
// now stores the payload type node alongside the raw code, following the struct
// field-node pattern.
// This function reads that column. Generic parameters are substituted from the
// generic application row's arguments, one level, following
// sh_struct_field_term.
// Returns the payload item for one payload value; an AK_PRODUCT in declaration
// order for several values; and -1 for a tag-only variant with no payload.
// （语义域外登记：携带值为空 ≠ 携带值 unit，不发明tag 变体 = 单点的项，/6 若需要另裁）。
// -1 = 不可展开（非枚举行 / 无此变体名 / 无携带值 / 携带值节点缺失 / 任一携带值不可译 / 预算耗尽）。
fn sh_variant_payload_at(ea: int, vi: int, i: int, ga: int) -> int:
    pn := ei_variant_type_node(ea, vi, i)
    if pn < 0:
        return -1
    if ast_kind(pn) == EXPR_IDENT:
        pni := ast_int_val(pn)
        gi2 : ., mut = 0
        loop:
            if gi2 >= ei_generic_count(ea):
                break
            if ei_generic_name(ea, gi2) == pni:
                // 泛型形参：泛型应用行的对应实参（缺位 -> 落空到名义，照 sh_struct_field_term）
                if ga >= 0 && get_type_kind(ga) == TYP_GENERIC_APPLY:
                    gstart2 := get_type_extra(ga)
                    gcnt2 := cell_load(g_gen_apply_data, gstart2 * 8)
                    if gi2 < gcnt2:
                        return sh_term_of_ti(cell_load(g_gen_apply_data, (gstart2 + 1 + gi2) * 8))
                break
            gi2 = gi2 + 1
    pti := res_type_node(pn)
    if pti < 0:
        return -1
    return sh_term_of_ti(pti)

fn sh_variant_payload_term(ti: int, name_ni: int) -> int:
    ea := find_enum_row_of(ti)
    if ea < 0:
        return -1
    vi := sh_enum_variant_index(ea, name_ni)
    if vi < 0:
        return -1
    tc := ei_variant_type_count(ea, vi)
    if tc <= 0:
        return -1
    ga : ., mut = -1
    if get_type_kind(ti) == TYP_GENERIC_APPLY:
        ga = ti
    tail : ., mut = tt_nil()
    i : ., mut = tc - 1
    loop:
        if i < 0:
            break
        if tt_step() == -1:
            return -1
        pt := sh_variant_payload_at(ea, vi, i, ga)
        if pt < 0:
            return -1
        tail = tt_cons(pt, tail)
        i = i - 1
    if tc == 1:
        return tt_a(tail)
    // 单携带值：序列首项即携带值项（不套空实义 product）
    return tt_atom(AK_PRODUCT, ti, tail)

// ─── 枚举携带值列入库断言（调试通道 `--verify-evp-nodes`，默认关）───
// Output: `[enum-payload-verify] enums=E variants=V slots=S collapses=C bad=B`.
// Returns bad; a positive value makes the caller return rc 1. The assertion is
// that every payload slot has a type node. A negative node means the parser did
// not write one, which is the gap this check exposes. `collapses` counts slots
// whose raw code says int (TY_INT=0) but whose node is not an int base node.
// That count is information, not a failure. The function only reads and counts;
// it writes no table.
fn sh_evp_verify() -> int:
    bad : ., mut = 0
    slots : ., mut = 0
    collapsed : ., mut = 0
    variants : ., mut = 0
    ei : ., mut = 0
    loop:
        if ei >= g_enum_count:
            break
        vi : ., mut = 0
        loop:
            if vi >= ei_variant_count(ei):
                break
            variants = variants + 1
            tc2 := ei_variant_type_count(ei, vi)
            ti2 : ., mut = 0
            loop:
                if ti2 >= tc2:
                    break
                slots = slots + 1
                code := ei_variant_type(ei, vi, ti2)
                pn2 := ei_variant_type_node(ei, vi, ti2)
                if pn2 < 0:
                    bad = bad + 1
                else if code == TY_INT:
                    if ast_kind(pn2) != 0 || ast_type_val(pn2) != TY_INT:
                        collapsed = collapsed + 1
                ti2 = ti2 + 1
            vi = vi + 1
        ei = ei + 1
    print("[enum-payload-verify] enums=")
    print(int_str(g_enum_count))
    print(" variants=")
    print(int_str(variants))
    print(" slots=")
    print(int_str(slots))
    print(" collapses=")
    print(int_str(collapsed))
    print(" bad=")
    println(int_str(bad))
    return bad
