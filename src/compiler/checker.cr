// === checker.cr ===
// Two-pass name resolver and type checker for the flat AST.
// Pass 1 collects function, struct, global, and interface declarations.
// Pass 2 resolves names and checks function bodies.
//
// Type judgment has three results:
//   1: holds
//   0: does not hold
//   -1: cannot decide, because the budget is exhausted or a type rule is not
//       implemented. Callers must not treat -1 as 0 or 1.

// --- Type table ---
// 每条记录 3 个整数：kind、data、extra。每条记录 24 字节。布局常量 ESZ_TYPE_ROW 和
// OFF_TR_* 在 globals.cr 单源，与 TYPE 段序列化和 dump 共用。

fn alloc_type(kind: int, data: int, extra: int) -> int:
    idx : ., mut = g_type_count
    grow_types(idx + 1)
    cell_store(g_types, idx * ESZ_TYPE_ROW + OFF_TR_KIND, kind)
    cell_store(g_types, idx * ESZ_TYPE_ROW + OFF_TR_DATA, data)
    cell_store(g_types, idx * ESZ_TYPE_ROW + OFF_TR_EXTRA, extra)
    g_type_count = idx + 1
    return idx

// ─── 同名 TYP_NAMED 建表去重 ───
// 每个命名类型在表中只有一行。所有生产分配点都走 alloc_named_type；alloc_type 仍是
// 裸分配器，只负责写一行。
//
// 侧表 g_named_dedup 使用 16 字节的 {name_idx, ti} 条目和开放寻址线性探测。键是 name_idx，
// extra 恒为 0，不进入键。读取方通过 get_type_data(ti) 取名字，因此按名字归一行不改变读取。
//
// 三条不变量缺一即可能挂死：
//  1. 装填因子检查在探测前检查：(count + 1) * 2 >= cap 时重建扩容。表满且键不存在时，
//   开放寻址不会遇到空槽。count 只增不减，恒等于占用槽数。
//  2. 重建时重放既有条目，count 随重放重算；重放走 named_dedup_probe，不经过检查，
//   避免重放再次触发扩容。
//  3. 回写前重新探测。探测与回写之间若有插入或扩容，先前槽位即失效。当前路径不可达，
//   保留为契约。
NAMED_DEDUP_INIT_CAP : int = 1024

fn named_dedup_init():
    if g_named_dedup_cap <= 0:
        nc : ., mut = NAMED_DEDUP_INIT_CAP
        nb := alloc(nc * 16)
        i : ., mut = 0
        loop:
            if i >= nc:
                break
            cell_store(nb, i * 16, -1)
            i = i + 1
        g_named_dedup = nb
        g_named_dedup_cap = nc
        g_named_dedup_count = 0

// 类型表重置后，记录编号范围作废，侧表必须一起作废。cap 置 0 后下次使用时惰性重建。
//
// 这不是可选防御。reset_frontend_state 会清 g_type_count，但不碰本侧表；LSP 每个请求都走
// reset_frontend_state -> check_all，而 check_all 首行调用 init_types。字符串表不清，
// 名字下标跨请求稳定，陈旧的 name -> ti 必然命中，返回上一请求的行号。
fn named_dedup_reset():
    g_named_dedup_cap = 0
    g_named_dedup_count = 0

// 无检查探测（只可在扩容检查之后调用；重建重放借道这里，不经检查 = 防递归）：
// 命中 -> 该键所在槽；未命中 -> 空槽（不插入）。形态 = sh_map_find_nogrow（槽位变量
// `slot` + break + 尾 return；函数体不以无 break 的 loop 收尾，自托管 checker 对该形态
// 有 TF01 误报）。
fn named_dedup_probe(name_idx: int) -> int:
    cap := g_named_dedup_cap
    p : ., mut = tt_mod(name_idx, cap)
    slot : ., mut = -1
    loop:
        k := cell_load(g_named_dedup, p * 16)
        if k < 0:
            slot = p
            break
        if k == name_idx:
            slot = p
            break
        p = p + 1
        if p >= cap:
            p = 0
    return slot

// 扩容 = 重建 + 重放既有条目（sh_map_rehash / 引擎 grow_tt_index 同式）；计数随重放重算。
fn named_dedup_rehash():
    old := g_named_dedup
    old_cap := g_named_dedup_cap
    nc : ., mut = old_cap * 2
    if nc < NAMED_DEDUP_INIT_CAP:
        nc = NAMED_DEDUP_INIT_CAP
    nb := alloc(nc * 16)
    i : ., mut = 0
    loop:
        if i >= nc:
            break
        cell_store(nb, i * 16, -1)
        i = i + 1
    g_named_dedup = nb
    g_named_dedup_cap = nc
    g_named_dedup_count = 0
    j : ., mut = 0
    loop:
        if j >= old_cap:
            break
        k := cell_load(old, j * 16)
        if k >= 0:
            s := named_dedup_probe(k)
            cell_store(g_named_dedup, s * 16, k)
            cell_store(g_named_dedup, s * 16 + 8, cell_load(old, j * 16 + 8))
            g_named_dedup_count = g_named_dedup_count + 1
        j = j + 1

// 槽位（含装填因子检查 + 重建重放）：命中 -> 该键所在槽；未命中 -> 空槽（不插入）。
fn named_dedup_slot(name_idx: int) -> int:
    named_dedup_init()
    if (g_named_dedup_count + 1) * 2 >= g_named_dedup_cap:
        named_dedup_rehash()
    return named_dedup_probe(name_idx)

// 同名 TYP_NAMED 归一行。命中返回既有行，未命中时分配并登记。
// 键域契约：name_idx >= 0，-1 是空槽哨兵。负键不进侧表，退化为裸分配；否则负键与空槽
// 同形，会把空槽读成命中并返回未初始化 value 槽的任意 ti。alloc 是 bump 分配且不置零，
// 该值不是固定的，会导致类型错误且不报错。
// 当前生产调用点的实参都是名字下标（str_intern、si_name、ei_name、类型节点的 ast_int_val）
// 且大于等于 0，该分支是防御路径。
fn alloc_named_type(name_idx: int) -> int:
    if name_idx < 0:
        return alloc_type(TYP_NAMED, name_idx, 0)
    slot := named_dedup_slot(name_idx)
    if cell_load(g_named_dedup, slot * 16) == name_idx:
        return cell_load(g_named_dedup, slot * 16 + 8)
    ti : ., mut = alloc_type(TYP_NAMED, name_idx, 0)
    // 回写前重探（见文件头注3）
    slot2 := named_dedup_slot(name_idx)
    if cell_load(g_named_dedup, slot2 * 16) == name_idx:
        // 防御（当前不可达）：既有登记优先 -> 本次刚分配的行成为未引用行（不写侧表、不计数）。
        // 反例写法（无条件写 slot2）会覆盖活跃条目 = 丢登记。
        return cell_load(g_named_dedup, slot2 * 16 + 8)
    cell_store(g_named_dedup, slot2 * 16, name_idx)
    cell_store(g_named_dedup, slot2 * 16 + 8, ti)
    g_named_dedup_count = g_named_dedup_count + 1
    return ti

// 自测用（type_selftest.cr）：该名字当前在类型表里占的记录数（恒 0/1；0 = 尚未分配）。
fn named_dedup_rows(name_idx: int) -> int:
    n : ., mut = 0
    i : ., mut = 0
    loop:
        if i >= g_type_count:
            break
        if get_type_kind(i) == TYP_NAMED && get_type_data(i) == name_idx:
            n = n + 1
        i = i + 1
    return n

// ─── 侧表与 res_type_node 的管线内断言（--verify-named-dedup）───
// 只读检查，不修改类型表、侧表或符号表。返回不一致条数，0 表示全部通过。
//  1. 类型表到侧表：每条 TYP_NAMED 记录按名字查侧表必须命中并回指本条记录。回指不一致说明
//   有生产点绕过侧表，另建了同名行。
//  2. 侧表到类型表：每条登记必须指向 kind=TYP_NAMED 且名字相符的合法行，并且该名字在
//   类型表中恰好一行。
//  3. 读取路径：AST 中每个解析为已注册命名类型的 EXPR_IDENT 节点，res_type_node 的返回值
//   必须等于侧表命中的 ti。该断言覆盖 SYM_TYPE 注册行和惰性 alloc_named_type 两条出口。
// 该函数只在 --verify-named-dedup 下调用，默认路径不执行。第 3 条的 find_gsym 是倒序
// 线性扫描，语料越大越慢。
fn named_dedup_verify() -> int:
    bad : ., mut = 0            // 不一致条数（返回）
    named_rows : ., mut = 0     // 断言 1 覆盖的 TYP_NAMED 记录数
    ident_checked : ., mut = 0  // 断言 3 覆盖的类型名引用节点数
    // 1. 类型表到侧表
    ti : ., mut = 0
    loop:
        if ti >= g_type_count:
            break
        if get_type_kind(ti) == TYP_NAMED:
            named_rows = named_rows + 1
            ni := get_type_data(ti)
            slot := named_dedup_slot(ni)
            if cell_load(g_named_dedup, slot * 16) != ni:
                bad = bad + 1
            else if cell_load(g_named_dedup, slot * 16 + 8) != ti:
                bad = bad + 1
        ti = ti + 1
    // 2. 侧表到类型表，并检查唯一性
    e : ., mut = 0
    loop:
        if e >= g_named_dedup_cap:
            break
        ni2 : ., mut = cell_load(g_named_dedup, e * 16)
        if ni2 >= 0:
            ti2 := cell_load(g_named_dedup, e * 16 + 8)
            if get_type_kind(ti2) != TYP_NAMED:
                bad = bad + 1
            else if get_type_data(ti2) != ni2:
                bad = bad + 1
            if named_dedup_rows(ni2) != 1:
                bad = bad + 1
        e = e + 1
    // 3. 读取路径：EXPR_IDENT 类型名引用的 res_type_node 必须落回侧表同一行
    ai : ., mut = 0
    loop:
        if ai >= g_ast_count:
            break
        if ast_kind(ai) == EXPR_IDENT:
            ni3 := ast_int_val(ai)
            si := find_gsym(ni3)
            if si >= 0 && sym_kind(si) == SYM_TYPE:
                sti := sym_type(si)
                // 泛型形参也 def_sym 为 SYM_TYPE，但其行 kind = TYP_GENERIC_PARAM（不经侧表）
                if get_type_kind(sti) == TYP_NAMED:
                    ident_checked = ident_checked + 1
                    slot3 := named_dedup_slot(ni3)
                    if cell_load(g_named_dedup, slot3 * 16) != ni3:
                        bad = bad + 1
                    else if cell_load(g_named_dedup, slot3 * 16 + 8) != res_type_node(ai):
                        bad = bad + 1
        ai = ai + 1
    print("[named-dedup] named_rows=")
    print(int_str(named_rows))
    print(" ident_checks=")
    print(int_str(ident_checked))
    print(" mismatches=")
    println(int_str(bad))
    return bad

fn init_types():
    g_type_count = 0
    named_dedup_reset()   // 类型表重置 -> 侧表随之作废（陈旧 name->ti 不得跨重置复用）
    // 约束诊断去重侧表同理作废（键含 AST 节点下标：跨编译期复用会漏报/误报）
    gen_constr_seen_reset()
    // 桥接缓存 ti->term 必须一起作废。判定路径无条件调用 sh_term_of_ti，长驻进程
    // （corelsp 每请求 init_types）复用记录编号时会命中陈旧的 ti->term，把两个不同类型判等，
    // 造成漏报且不报错。
    sh_map_reset()
    // 展开层缓存 ti->展开项同理作废。记录编号范围复用后，陈旧命中会把上一请求的类型结构安到
    // 当前记录上。
    sh_unf_map_reset()
    // 判定不可进行时报 ICE04 并终止编译。诊断在产生它的那次编译里出现，不跨请求累积。
    // 单槽化建项失败位与类型表记录编号范围同生命周期，只对当前编译期有意义。
    g_tk_face_fail = 0
    alloc_type(TYP_BASE, TY_INT, 0)     // TI_INT = 0
    alloc_type(TYP_BASE, TY_DEX, 0)   // TI_DEX = 1
    alloc_type(TYP_BASE, TY_BOOL, 0)    // TI_BOOL = 2
    alloc_type(TYP_BASE, TY_STRING, 0)  // TI_STR = 3
    alloc_type(TYP_BASE, TY_UNIT, 0)    // TI_UNIT = 4
    alloc_type(TYP_BASE, TY_NEVER, 0)   // TI_NEVER = 5
    alloc_type(TYP_BASE, TY_CHAR, 0)    // TI_CHAR = 6
    alloc_type(TYP_DYN, 0, 0)           // TI_DYN = 7
    // TI_DEX_S = 8 占位表项：TI_DEX_S 是 dex 定点精确形式（缩放整数）
    // 的 IR 变量类型哨兵，值恰为 8，曾与"首个动态分配类型下标"碰撞，@sizeOf/@alignOf/
    // is_ptr_var 的哨兵检查对首个真实类型误触发。占住下标 8 后用户类型从 9 起，
    // 检查永不再命中真实类型（TI_DEX_S 本身仍不查类型表，见 ir_gen.cr 注释）。
    alloc_type(TYP_BASE, TY_DEX_S, 0)   // TI_DEX_S = 8 占位
    // 本质条目表（iface_registry.cr），静态数据（AK_*/TI_* 常量 + -1/0 +
    // 起的注册名 ni），不 alloc 类型表记录、不缓存本函数刚分配的记录编号，因此重复调用
    // 无副作用（长驻进程每请求一次）。
    // 位置 = 9 行原生 alloc 之后（表内容不依赖类型表，此处仅为随类型表生命周期初始化）。
    iface_registry_init()
    // 六形状名字生产注册表（sequence/sequence_ro/
    // sequence_rw/indexable/iterable/product -> sh_shape_*() 构造点）。无条件调用（幂等：
    // iface_shape_register 同名覆盖；reset_frontend_state 清 count 后由该调用重建），
    // 段内容 = 表本体（生产编译下恰 6 条）。详细边界见 iface_shape_builtin_init 注。
    iface_shape_builtin_init()

// Runtime builtin declarations moved to the target prelude. The checker only
// consumes g_rt_builtin_* through prelude_builtin_init and the shared table.

// Type-row readers live in dyn_arr.cr (shared with corearch so target layout
// helpers can resolve rows without a checker layer).

// ─── 常量档数组长度约束 ───
// N 不参与类型身份，身份令牌序列只含元素项，因此数组长度在 type_equal 之外单独检查。
// 本函数沿两类型的结构对应位置下钻，在数组位置比较 extra：1 = 满足，0 = 违反。
// 下钻位置是数组元素、指针元素、引用元素、切片元素、元组字段和泛型应用实参。
// 异 kind、异元数或非数组构造子不约束长度，返回 1。
// 身份判定仍负责 REF 的 mut 标记、元组元数、泛型基型行号等非长度约束；本函数只比较
// TYP_ARRAY 的 extra，不重复这些检查。
//
// 符号档未实现。动态档由 F11 侧表和 IR_BOUNDS_CHECK 在运行期检查，编译期不放行视图到
// 固定数组的转换。TYP_NAMED、TYP_GENERIC_PARAM、TYP_BASE、TYP_DYN 不下钻，递归深度等于
// 类型嵌套深度。
//
// ─── 方向规则 ───
// [T;N] <: [T]；[T] 不能赋给 [T;N]，除非能证明 len == N。参数顺序为（源，目标）：
//  源 TYP_SLICE 且目标 TYP_ARRAY -> 0，运行期长度不可证；
//  源 TYP_ARRAY 且目标 TYP_SLICE -> 1；
//  其余跨 kind -> 1，长度约束无约束，由身份判定负责。
// 所有判定点的参数顺序统一为（源，目标）。hotpatch 站点两侧都是声明，使用
// type_compat_sym 的对称核。
fn array_len_walk(ti_a: int, ti_b: int, dir: int) -> int:
    ka := get_type_kind(ti_a)
    kb := get_type_kind(ti_b)
    if ka != kb:
        if dir == 1:
            if ka == TYP_SLICE && kb == TYP_ARRAY:
                return 0
        // 视图->固定：不给放行
        return 1
    if ka == TYP_ARRAY:
        if get_type_extra(ti_a) != get_type_extra(ti_b):
            return 0
        return array_len_walk(get_type_data(ti_a), get_type_data(ti_b), dir)
    if ka == TYP_PTR || ka == TYP_REF || ka == TYP_SLICE:
        return array_len_walk(get_type_data(ti_a), get_type_data(ti_b), dir)
    if ka == TYP_TUPLE:
        fc := get_type_data(ti_a)
        if fc != get_type_data(ti_b):
            return 1
        // 字段数不同：身份判定负责
        fs1 := get_type_extra(ti_a)
        fs2 := get_type_extra(ti_b)
        fi : ., mut = 0
        loop:
            if fi >= fc:
                break
            if array_len_walk(cell_load(g_gen_apply_data, (fs1 + fi) * 8), cell_load(g_gen_apply_data, (fs2 + fi) * 8), dir) == 0:
                return 0
            fi = fi + 1
        return 1
    if ka == TYP_GENERIC_APPLY:
        if get_type_data(ti_a) != get_type_data(ti_b):
            return 1
        // 基型不同：身份判定负责
        as1 := get_type_extra(ti_a)
        as2 := get_type_extra(ti_b)
        ac1 := cell_load(g_gen_apply_data, as1 * 8)
        ac2 := cell_load(g_gen_apply_data, as2 * 8)
        if ac1 != ac2:
            return 1
        // 实参数不同：身份判定负责
        ai : ., mut = 0
        loop:
            if ai >= ac1:
                break
            if array_len_walk(cell_load(g_gen_apply_data, (as1 + 1 + ai) * 8), cell_load(g_gen_apply_data, (as2 + 1 + ai) * 8), dir) == 0:
                return 0
            ai = ai + 1
        return 1
    return 1

// 方向规则（有源/目标语义的站点）：见上参序约定注记。
fn array_len_constraint_ok(ti_a: int, ti_b: int) -> int:
    return array_len_walk(ti_a, ti_b, 1)

// 对称核用于没有源/目标方向的站点，例如 hotpatch 一致性检查，两侧都是声明。
// 跨 kind 一律无长度约束。单独保留入口，因为无方向不是有方向的特例；用方向版会让判定
// 结果依赖参数顺序，同一声明换个声明顺序就会改判。
fn array_len_constraint_sym(ti_a: int, ti_b: int) -> int:
    return array_len_walk(ti_a, ti_b, 0)

// 判定点组合：身份判等 + 常量档长度约束 + 方向规则。
// N 不参与身份，因此必须在 type_equal 之外显式检查长度和固定性，否则不匹配会通过且不报错。
// 返回 1 表示兼容；0 表示身份不匹配，使用原诊断措辞；-1 表示长度或方向约束违反，使用专属
// 措辞，错误码不变。TF01、TA01、TC02 的拒绝集合不变，只分列成因。
// 判定点统一调用 type_equal，不就地内联等价比较，避免绕过判定入口。
// 参数顺序为（源，目标），说明见 array_len_walk 上方。
// 错误哨兵。负值文件级常量在自举二进制里会读成 0，因此用函数返回表达式。
fn ti_error() -> int:
    return 0 - 2

// Whether the function currently being checked is a generic template. The
// type-engine selftest calls infer_expr directly (g_func_count may be 0), so the
// raw g_checker_current_fi index must be bounds-checked before fi_generic_count.
fn cur_fn_is_generic() -> int:
    fi : ., mut = g_checker_current_fi
    if fi < 0 || fi >= g_func_count:
        return 0
    return fi_generic_count(fi)

fn type_compat_strict(ti_a: int, ti_b: int) -> int:
    // never 是发散类型，与任何类型相容。以 return、break、continue、fail 收尾的路径，
    // 其类型为 never。分支合一处的 unit 对 never、int 对 never 必须放行，否则
    // 一支赋值、一支 return这类正常语句会被误报 TC02。
    //
    // 错误哨兵 ti_error() 与 TI_NEVER 分开处理：
    //   源侧是 ti_error() 时放行，避免错误值级联出第二条诊断。例如 x : int = nosuchname
    //   只报 N01，不再叠加 TA02。
    //   目标侧是 ti_error() 时不放行，目标类型取不到就是真差异，例如 undef_x = 0 仍报 TA01。
    //   源侧是 TI_NEVER 时放行：never 是底部类型，发散路径可以流入任何槽。
    //   目标侧是 TI_NEVER 时不放行：没有任何值能流入 never。`-> never` 的
    //   `return 1` 必须报 TF01，`never` 形参也不能接收普通值。
    if ti_a == ti_error():
        return 1
    if ti_b == ti_error():
        return 0
    if ti_a == TI_NEVER:
        return 1
    if !type_equal(ti_a, ti_b):
        // 可选目标注入：T? = T ∪ null。裸 T 值和 None 值可以流入 T? 的槽，覆盖返回位、
        // 赋值位、实参位和字段位。type_equal 判断身份等价，不包含 int ⊆ int ∪ null，
        // 因此需要额外的子类型检查，否则 fn g() -> int? { return 5; } 会被拒绝。
        //
        // 注入只在目标 kind 为 TYP_OPTIONAL 时触发。反方向不注入：T? 值进入 T 槽时，
        // ty_sub(union, T) 返回 0，仍然拒绝。引擎返回 0 或 -1 时一律不放行。
        if get_type_kind(ti_b) == TYP_OPTIONAL:
            if ti_subsumes(ti_a, ti_b) == 1:
                return 1
        return 0
    if array_len_constraint_ok(ti_a, ti_b) == 0:
        return -1
    return 1

// ti 级包含判定（源 ⊆ 目标）：桥接后用引擎 ty_sub 取判定结果。只有 1 放行。
// 0 表示确定不包含，-1 表示未知，二者都返回 0。本入口只用于放松可选目标，未知不得放宽。
// 预算前后各复位一次，避免引擎 memo 让结果依赖预算历史。
fn ti_subsumes(src_ti: int, tgt_ti: int) -> int:
    a := sh_term_of_ti(src_ti)
    b := sh_term_of_ti(tgt_ti)
    if a < 0 || b < 0:
        return 0
    ty_budget_reset(200000)
    s := ty_sub(a, b)
    ty_budget_reset(200000)
    if s == 1:
        return 1
    return 0

// 无方向站点的组合（与 type_compat_strict 同构，仅长度约束走对称核）：hotpatch 站（1）用。
fn type_compat_sym(ti_a: int, ti_b: int) -> int:
    if !type_equal(ti_a, ti_b):
        return 0
    if array_len_constraint_sym(ti_a, ti_b) == 0:
        return -1
    return 1

// F2 判定点诊断：verdict ≠ 1 时发码，-1（长度约束违反）用专属措辞，0 用原措辞。
fn diag_type_incompatible(verdict: int, code: int, what: string, line: int, col: int):
    if verdict == -1:
        check_error(code, "Array length constraint not satisfied", line, col)
    else:
        check_error(code, what, line, col)

// ─── 声明位点的值/注解兼容判定 ───
// 检查 let 和全局初始化器的值类型与注解类型。判定调用 type_compat_strict，参数顺序为
// （源 = 初始化值，目标 = 注解行）。局部 let 的 infer_expr 分支和 check_global_let
// 共用本函数。
//
// 豁免：
//   1. 无注解、`: .`、`: auto`，或无初值。没有契约可核。
//   2. 注解是 dyn。dyn 槽按值追踪，值的类型就是该槽的合法类型集。
//   3. 值是 never。never 既是底部类型，也用于表达式错误路径，后者需要抑制诊断级联。
//   4. 注解 kind 是 TYP_GENERIC_PARAM。声明期不可验证。
//
// 不可判（引擎 -1 或桥接缺口）由 type_equal 内部发 ICE04，本函数不回落或近似。
fn check_let_annot_compat(node: int, val_node: int, val_ti: int, ti: int):
    type_node := ast_b(node)                          // EXPR_LET: b = 注解类型节点（-1 = 无）
    if type_node < 0 || val_node < 0:
        return
    if ti == TI_DYN:
        return
    if val_ti == TI_NEVER:
        return
    if get_type_kind(ti) == TYP_GENERIC_PARAM:
        return
    compat := type_compat_strict(val_ti, ti)
    if compat != 1:
        diag_type_incompatible(compat, EC_TA_DECL, "Variable declared as " + type_display(ti) + ", got " + type_display(val_ti), ast_line(node), ast_col(node))

// 判定不可进行时直接报错并终止编译：ICE04。判定约定要求未知不得当作 0 或 1，也不得回落或近似。
// 两个出口：
//  1. 桥接缺口：sh_term_of_ti 返回 -1，该条记录无法译成类型项，例如记录编号越界或桥接未覆盖。
//  2. 引擎返回 -1：预算耗尽或未覆盖情形。
// 判定函数没有 AST 位置，诊断的 line 和 col 为 0；定位由调用点的 TA01、TF01 等诊断承担。
fn ty_indeterminate_report(kind: int, t1: int, t2: int, a: int, b: int, unc: int, exh: int):
    msg : ., mut = ""
    if kind == 0:
        msg = "type judgment indeterminate: no type term for type row " + int_str(t1) + " / " + int_str(t2) + " (bridge gap)"
    else:
        cause : ., mut = "uncovered face"
        if unc == 0 && exh != 0:
            cause = "budget exhausted"
        msg = "type judgment indeterminate: " + tt_display(a) + " vs " + tt_display(b) + " (" + cause + ")"
    check_error(EC_ICE_TY_INDET, msg, 0, 0)

// ─── 判定入口：引擎唯一权威 ───
//  1. 同一条记录快路径：t1 == t2 返回 true。该路径只省一次桥接和引擎查询，不改变结果。
//  2. 桥接：任一侧 sh_term_of_ti 返回 -1 时报 ICE04 并终止编译，判定不可进行。
//  3. 引擎判定结果：1 返回 true；0 返回 false；-1 报 ICE04 并终止编译，同时给出成因和两侧类型项。
//  4. 预算隔离：判定前后各调用一次 ty_budget_reset(200000)。引擎 memo 跨查询命中会让
//   结果依赖预算历史，判定路径不得受前次查询影响。
// 返回 false 是 bool 类型上的保守出口，不因未知放宽；它不等价于确定不等价。确定不等价由
// 引擎的 0 表示，诊断只在未知时发出。
// 本函数不比较 N。桥接的 AK_SEQUENCE 参数列表只含元素项，长度拒绝由
// array_len_constraint_ok 在 type_compat_strict 调用点承担。本函数不得引入数组 extra 比较。
fn type_equal_engine(t1: int, t2: int) -> bool:
    if t1 == t2:
        return true
    // 错误哨兵不进引擎。ti_error() 返回 -2，没有类型表记录；若放它下去，
    // `sh_term_of_ti` 回 -1 会触发 `ty_indeterminate_report`（ICE04，终止编译，fail-closed）
    // 因此任何错误值参与等价判定都会变成新诊断。此处早退 = 等价判否（且不报）。
    if t1 == ti_error() || t2 == ti_error():
        return false
    // 快路径：同一行
    a := sh_term_of_ti(t1)
    b := sh_term_of_ti(t2)
    if a < 0 || b < 0:
        ty_indeterminate_report(0, t1, t2, a, b, 0, 0)
        return false
    ty_budget_reset(200000)
    e : ., mut = ty_equiv(a, b)
    // 成因位须在第二次 reset 之前读（ty_budget_reset 清 g_ty_uncovered/g_ty_exhausted）
    unc := ty_uncovered()
    exh := ty_exhausted()
    ty_budget_reset(200000)                           // 判定后即复位（不影响后续查询）
    if e == 1:
        return true
    if e == 0:
        return false
    // e == -1（未知）：处理方式为不忽略、不回落，直接报错并终止编译，同时附反例。
    ty_indeterminate_report(1, t1, t2, a, b, unc, exh)
    return false

// 判定入口。单独保留函数名，调用不直接依赖引擎实现。
fn type_equal(t1: int, t2: int) -> bool:
    return type_equal_engine(t1, t2)

fn scan_for_yield(node: int) -> int:
    if node < 0:
        return 0
    k := ast_kind(node)
    if k == EXPR_YIELD:
        return 1
    if k == EXPR_BLOCK:
        ss := ast_a(node)
        sc := ast_b(node)
        i : ., mut = 0
        loop:
            if i >= sc:
                break
            sn := cell_load(g_block_stmts, (ss + i) * 8)
            if scan_for_yield(sn) != 0:
                return 1
            i = i + 1
        return 0
    if k == EXPR_LOOP || k == EXPR_WHILE:
        return scan_for_yield(ast_a(node))
    if k == EXPR_IF:
        if scan_for_yield(ast_a(node)) != 0:
            return 1
        if scan_for_yield(ast_b(node)) != 0:
            return 1
        if ast_c(node) >= 0 && scan_for_yield(ast_c(node)) != 0:
            return 1
        return 0
    if k == EXPR_FOR:
        return scan_for_yield(ast_c(node))
    return 0

// ─── 落空分析（TF01）───
// 返回检查把块类型当作末语句类型。以无 break 的 loop 收尾的函数体不会走到函数尾，
// 其 unit 不能作为缺返回值的证据。判定保守：只认确定不能落空的形态，其余返回 0，
// 仍按 TF01 处理。真落空体不能通过，否则会接受错误且不报错。

// 循环体内是否存在直属于本循环的 break（嵌套 loop/while/for 内的 break 归内层，因此
// 在循环节点处截断、不下钻）。返回 1 亦覆盖形态未知（默认后备），未知按可能有
// break处理 = fail-closed：宁可照旧报 TF01，也不误判无 break，因此永不落空。
fn loop_body_has_break(node: int) -> int:
    if node < 0:
        return 0
    k := ast_kind(node)
    if k == EXPR_BREAK:
        return 1
    if k == EXPR_LOOP || k == EXPR_WHILE || k == EXPR_FOR:
        return 0
    if k == EXPR_BLOCK:
        ss := ast_a(node)
        sc := ast_b(node)
        i : ., mut = 0
        loop:
            if i >= sc:
                break
            if loop_body_has_break(cell_load(g_block_stmts, (ss + i) * 8)) != 0:
                return 1
            i = i + 1
        return 0
    if k == EXPR_IF:
        if loop_body_has_break(ast_a(node)) != 0:
            return 1
        if loop_body_has_break(ast_b(node)) != 0:
            return 1
        return loop_body_has_break(ast_c(node))
    if k == EXPR_MATCH:
        // 臂 = EXPR_ARM 列表（parser 以 arm.c 串联，尾 -1），非连续槽，勿按段扫
        if loop_body_has_break(ast_a(node)) != 0:
            return 1
        an : ., mut = ast_b(node)
        loop:
            if an < 0:
                break
            if loop_body_has_break(ast_b(an)) != 0:
                return 1
            an = ast_c(an)
        return 0
    if k == EXPR_ARM || k == EXPR_BINARY || k == EXPR_ASSIGN || k == EXPR_INDEX || k == EXPR_RANGE || k == EXPR_AS || k == EXPR_ARG || k == EXPR_CALL:
        if loop_body_has_break(ast_a(node)) != 0:
            return 1
        return loop_body_has_break(ast_b(node))
    if k == EXPR_ENUM_CONSTRUCTOR || k == EXPR_AT:
        // a = 名 ni（不是节点）：只下钻实参列表（b）
        return loop_body_has_break(ast_b(node))
    if k == EXPR_GO:
        // a 恒 -1、体在 b（range 形态另有 c/data）；a/b 双下钻 = 保守（go 体内 break 不漏判）
        if loop_body_has_break(ast_a(node)) != 0:
            return 1
        return loop_body_has_break(ast_b(node))
    if k == EXPR_LET:
        // a = 名 ni（不是节点）：只下钻类型（b）与值（c）
        if loop_body_has_break(ast_b(node)) != 0:
            return 1
        return loop_body_has_break(ast_c(node))
    if k == EXPR_STRUCT || k == EXPR_STRUCTPAT || k == EXPR_ENUMPAT || k == EXPR_GENERIC_APPLY:
        // 连续子节点段：首 b、个数 c（wrapper.a = 值/子模式，经 EXPR_NONE 分支承接）
        return seg_has_break(ast_b(node), ast_c(node))
    if k == EXPR_ARRAY || k == EXPR_TUPLE || k == EXPR_TUPLEPAT:
        return seg_has_break(ast_a(node), ast_b(node))
    if k == EXPR_NONE:
        // wrapper（a = 值节点）或基类型节点（a = 0）：照 monomorph 的判断依据
        if ast_a(node) >= 0 && ast_a(node) != node:
            return loop_body_has_break(ast_a(node))
        return 0
    if k == EXPR_STMT || k == EXPR_UNSAFE || k == EXPR_RETURN || k == EXPR_YIELD || k == EXPR_AWAIT || k == EXPR_TRY || k == EXPR_UNARY || k == EXPR_FIELD || k == EXPR_OPTIONAL || k == EXPR_REFTYPE || k == EXPR_PTRTYPE:
        return loop_body_has_break(ast_a(node))
    if k == EXPR_INT || k == EXPR_DEX || k == EXPR_BOOL || k == EXPR_STRING || k == EXPR_IDENT || k == EXPR_CHAR || k == EXPR_WILDCARD || k == EXPR_CONTINUE:
        return 0
    // 后备分支（含 EXPR_FN/PARAM/FLOW/EXTERN 等未枚举形态）：按可能有 break保守处理
    return 1

fn seg_has_break(first: int, count: int) -> int:
    if first < 0:
        return 0
    i : ., mut = 0
    loop:
        if i >= count:
            break
        n := first + i
        if n >= 0 && n < g_ast_count:
            if loop_body_has_break(n) != 0:
                return 1
        i = i + 1
    return 0

// 语句是否不能落空（走到本语句之后的代码）：1 = 确定不能，0 = 可能落空（保守默认）。
// 注意 `return` 在此不判 divergence：它虽然不能走完，但带返回值，本分析只服务
// 块末语句类型是否代表函数返回值这一问，而 return 的值类型恰是该问的被检对象（豁免它
// = 洗白真正错误，lits_copy 型）。故只认不产出值的不可落空形态：无直系 break 的 loop、
// 双分支皆不可落空且无 else 的 if、包裹层（STMT/UNSAFE/嵌套 block）。
// 登记数据：非落空体内的 return 值类型本分析不核对（checker 现模型无逐 return 核对；
// 该范围 = 既有范围，本条只把以无 break 的 loop 收尾从 TF01 误报中解放，不新增核对）。
fn stmt_cannot_fall_through(node: int) -> int:
    if node < 0:
        return 0
    k := ast_kind(node)
    if k == EXPR_BLOCK:
        ss := ast_a(node)
        sc := ast_b(node)
        i : ., mut = 0
        loop:
            if i >= sc:
                break
            if stmt_cannot_fall_through(cell_load(g_block_stmts, (ss + i) * 8)) != 0:
                return 1
            i = i + 1
        return 0
    if k == EXPR_LOOP:
        // 无直系 break，因此只可能从体内 return 出（loop_body_has_break 的未知 = 1 保证
        // 此处判 1 只在确定无 break 时成立）
        if loop_body_has_break(ast_a(node)) == 0:
            return 1
        return 0
    if k == EXPR_IF:
        if ast_c(node) < 0:
            return 0
        // 无 else：条件不成立即落空
        if stmt_cannot_fall_through(ast_b(node)) == 0:
            return 0
        return stmt_cannot_fall_through(ast_c(node))
    if k == EXPR_STMT || k == EXPR_UNSAFE:
        return stmt_cannot_fall_through(ast_a(node))
    return 0

// 语句是否确定发散（本层不产出值、不落到后继），含 `return`。
// 仅服务 TC02 的else 支类型是幻影判定（消费点 = infer_expr 的 EXPR_IF 合并点检查）；
// 不得用于 TF01，那里豁免 return 体会洗白真正错误（lits_copy 型），见上一条的头注。
// 保守默认 0（不确定即 0）：只认 return 族 + 包裹层（STMT/UNSAFE）+ 块内任一句确定发散。
// 未覆盖情形：以 break 或 continue 收尾的分支需要循环上下文，当前不判。
fn stmt_diverges(node: int) -> int:
    if node < 0:
        return 0
    k := ast_kind(node)
    if k == EXPR_RETURN:
        return 1
    if k == EXPR_STMT || k == EXPR_UNSAFE:
        return stmt_diverges(ast_a(node))
    if k == EXPR_BLOCK:
        ss := ast_a(node)
        sc := ast_b(node)
        i : ., mut = 0
        loop:
            if i >= sc:
                break
            if stmt_diverges(cell_load(g_block_stmts, (ss + i) * 8)) != 0:
                return 1
            i = i + 1
        return 0
    return 0

// --- Symbol table ---
struct SymEntry:
    name_idx: int,
    kind: int,
    type_idx: int,
    node_idx: int,

fn push_scope():
    grow_scope_bounds(g_scope_depth + 1)
    cell_store(g_scope_bounds, g_scope_depth * 8, g_sym_count)
    g_scope_depth = g_scope_depth + 1

fn pop_scope():
    if g_scope_depth > 0:
        g_scope_depth = g_scope_depth - 1
        g_sym_count = cell_load(g_scope_bounds, g_scope_depth * 8)

fn def_sym(name_idx: int, kind: int, type_idx: int, node_idx: int):
    grow_syms(g_sym_count + 1)
    sym_set_name(g_sym_count, name_idx)
    sym_set_kind(g_sym_count, kind)
    sym_set_type(g_sym_count, type_idx)
    sym_set_node(g_sym_count, node_idx)
    // Defaults: owner unknown (same-library/legacy), not exported. Top-level
    // declaration registrations overwrite both fields.
    sym_set_owner(g_sym_count, -1)
    sym_set_pub(g_sym_count, 0)
    // Parameters, match bindings, loop variables and legacy declarations stay
    // assignable by default. EXPR_LET and top-level globals overwrite this with
    // their declared mut tag.
    sym_set_mut(g_sym_count, 1)
    g_sym_count = g_sym_count + 1

fn def_decl_fn_sym(name_idx: int, ti: int, node: int):
    def_sym(name_idx, SYM_FN, ti, node)
    si := g_sym_count - 1
    sym_set_owner(si, lib_of_node(node))
    sym_set_pub(si, fn_node_is_pub(node))

fn def_decl_variant_sym(name_idx: int, ti: int, enum_name: int, enum_line: int):
    def_sym(name_idx, SYM_FN, ti, -1)
    si := g_sym_count - 1
    owner := lib_of_line(enum_line)
    sym_set_owner(si, owner)
    is_pub : ., mut = 0
    if owner >= 0 && lib_export_find_kind(owner, enum_name, SYM_TYPE) >= 0:
        is_pub = 1
    sym_set_pub(si, is_pub)

fn def_let_sym(name_idx: int, ti: int, is_mut: int):
    def_sym(name_idx, SYM_LOCAL, ti, -1)
    sym_set_mut(g_sym_count - 1, is_mut)

fn def_decl_global_sym(name_idx: int, ti: int, node: int):
    def_sym(name_idx, SYM_GLOBAL, ti, node)
    si : ., mut = g_sym_count - 1
    sym_set_mut(si, ast_data(node))
    owner := lib_of_node(node)
    sym_set_owner(si, owner)
    is_pub : ., mut = 0
    if owner >= 0 && lib_export_find_kind(owner, name_idx, SYM_GLOBAL) >= 0:
        is_pub = 1
    sym_set_pub(si, is_pub)

fn sym_owner(si: int) -> int:
    return sym_owner_field(si)

fn sym_visible(si: int) -> int:
    if g_cur_lib < 0:
        return 1
    k := sym_kind(si)
    if k < SYM_FN || k > SYM_SO_FN:
        return 1
    owner := sym_owner_field(si)
    if owner < 0 || owner == g_cur_lib:
        return 1
    if lib_can_import(g_cur_lib, owner) == 0:
        return 0
    return sym_pub_field(si)

fn func_owner(fi: int) -> int:
    node := fi_ast_node(fi)
    if node < 0:
        return -1
    return lib_of_node(node)

fn func_visible(fi: int) -> int:
    if g_cur_lib < 0:
        return 1
    node : ., mut = fi_ast_node(fi)
    if node < 0:
        return 1
    owner := lib_of_node(node)
    if owner < 0 || owner == g_cur_lib:
        return 1
    if lib_can_import(g_cur_lib, owner) == 0:
        return 0
    return fn_node_is_pub(node)

fn mod_func_visible(target_fni: int, name_ni: int) -> int:
    if g_cur_lib < 0:
        return 1
    owner := lib_lookup_path(file_path_by_fni(target_fni))
    if owner < 0 || owner == g_cur_lib:
        return 1
    if lib_can_import(g_cur_lib, owner) == 0:
        return 0
    return lib_export_find_kind(owner, name_ni, SYM_FN) >= 0

fn register_pub_export(name_ni: int, node: int):
    if node < 0 || fn_node_is_pub(node) == 0:
        return
    lid := lib_of_node(node)
    if lid >= 0:
        lib_export_add(lid, name_ni, SYM_FN, node)

fn find_sym(name_idx: int) -> int:
    // Lexical names always win. Top-level declarations then prefer the current
    // library's own declaration over an imported pub declaration of the same
    // name, independent of registration order.
    i : ., mut = g_sym_count - 1
    loop:
        if i < 0:
            break
        if sym_name(i) == name_idx && (sym_kind(i) == SYM_LOCAL || sym_kind(i) == SYM_PARAM) && sym_visible(i) != 0:
            return i
        i = i - 1
    if g_cur_lib >= 0:
        i = g_sym_count - 1
        loop:
            if i < 0:
                break
            if sym_name(i) == name_idx && sym_kind(i) != SYM_LOCAL && sym_kind(i) != SYM_PARAM && sym_owner_field(i) == g_cur_lib && sym_visible(i) != 0:
                return i
            i = i - 1
    i = g_sym_count - 1
    loop:
        if i < 0:
            return -1
        if sym_name(i) == name_idx && sym_visible(i) != 0:
            return i
        i = i - 1
    return -1

fn find_gsym(name_idx: int) -> int:
    // Prefer the current library's declaration. Without this, a user global or
    // type with the same name as a pub stdlib declaration resolves to the
    // stdlib one purely because it was registered later.
    if g_cur_lib >= 0:
        i : ., mut = g_sym_count - 1
        loop:
            if i < 0:
                break
            if sym_name(i) == name_idx && sym_kind(i) != SYM_LOCAL && sym_kind(i) != SYM_PARAM && sym_owner_field(i) == g_cur_lib && sym_visible(i) != 0:
                return i
            i = i - 1
    i : ., mut = g_sym_count - 1
    loop:
        if i < 0:
            break
        // 主表未命中，因此落到下方侧表回退
        if sym_name(i) == name_idx && sym_kind(i) != SYM_LOCAL && sym_kind(i) != SYM_PARAM && sym_visible(i) != 0:
            return i
        i = i - 1
    // 侧表回退：只有名字被引用且主表没有同名条目时才物化，未引用条目零产物足迹。
    // 同名 `.cr` 声明优先，外部目录里的文件不得改写用户源码声明的含义。
    // 主表和侧表都查不到时返回 -1，由调用点报 Undefined。绝不在此放行，否则报错失败
    // 会退化为值错误且不报错。
    ssi := find_so_side(name_idx)
    if ssi < 0:
        return -1
    return so_materialize(ssi)

fn find_so_fn(name_idx: int) -> int:
    i : ., mut = 0
    loop:
        if i >= g_sym_count:
            break
        if sym_name(i) == name_idx:
            if sym_kind(i) == SYM_SO_FN:
                return i
            // 同名 `.cr` 声明优先，不物化 SO_FN，print 和 println 走声明信息。
            // 物化发生在首次查找，条目追加在表尾；有声明时不物化，因此不存在
            // SO_FN 排在 SYM_FN 之前的顺序假设。
            return -1
        i = i + 1
    ssi := find_so_side(name_idx)
    if ssi < 0:
        return -1
    return so_materialize(ssi)


// --- Error tracking ---
// Uses g_diags, g_diag_count from globals.cr (and ast.cr)
// Old g_check_errors is replaced by structured g_diags.

// ── nail3：逐 `return` 核对返回值 vs 当前函数的声明返回型──
// return 的类型是 never，见 infer_expr 的 EXPR_RETURN 格。
// 因此体类型恒为 never，与声明返回型恒相容，类型通道里不留任何可比信息。
// 故在 `EXPR_RETURN` 处额外取一次当前函数的声明返回型做比对（诊断，不参与节点类型）。
// 承载：save/restore 两个全局（与 `g_unsafe_depth` 同款的显式上下文约定；嵌套函数声明已被
// 已拒绝，因此无需真栈）。`g_cur_fn_ret_checked == 0`，因此不判（flow 函数 / 声明返回型是
// 泛型形参，与既有 TF01 体检查使用同一规则）。
g_cur_fn_ret_ti : int, mut
g_cur_fn_ret_checked : int, mut

// Store one diagnostic. file/lo/hi come from SourceManager; sm_file < 0 means
// the site has no attributable source file and rendering falls back to line/col.
fn check_error_span(code: int, msg: string, line: int, col: int, file: int, lo: int, hi: int):
    grow_diags(g_diag_count + 1)
    cell_store(g_diags, g_diag_count * DIAG_REC_SIZE, code)
    cell_store_str(g_diags, g_diag_count * DIAG_REC_SIZE + 8, msg)
    cell_store(g_diags, g_diag_count * DIAG_REC_SIZE + 16, line)
    cell_store(g_diags, g_diag_count * DIAG_REC_SIZE + 24, col)
    cell_store(g_diags, g_diag_count * DIAG_REC_SIZE + 32, diag_fileid_for_line(line))
    cell_store(g_diags, g_diag_count * DIAG_REC_SIZE + 40, file)
    cell_store(g_diags, g_diag_count * DIAG_REC_SIZE + 48, lo)
    cell_store(g_diags, g_diag_count * DIAG_REC_SIZE + 56, hi)
    g_diag_count = g_diag_count + 1

// Bridge for existing call sites: (line, col) indexes the source most recently
// handed to tokenize(), so its start offset is available through the line table.
// A later slice threads token spans directly into this function.
fn check_error(code: int, msg: string, line: int, col: int):
    file : ., mut = -1
    lo : ., mut = 0
    hi : ., mut = 0
    if line > 0:
        c : ., mut = col
        if c < 1:
            c = 1
        // The line is in the flat SourceManager line space. Resolve it to the
        // owning file instead of the most recently tokenized file: checker
        // diagnostics run after all files have been parsed.
        sm := file_sm_id(diag_fileid_for_line(line))
        if sm >= 0:
            local_line := line - sm_file_line_base(sm)
            file = sm
            lo = sm_line_start(sm, local_line) + c - 1
            hi = lo + 1
    check_error_span(code, msg, line, col, file, lo, hi)

// --- Borrow checking ---


fn find_borrow_entry(var_ni: int) -> int:
    i : ., mut = 0
    loop:
        if i >= g_borrow_count:
            return -1
        if cell_load(g_borrow_vars, i * 8) == var_ni:
            return i
        i = i + 1
    return -1

fn check_borrow(var_ni: int, is_mut: int) -> bool:
    bi := find_borrow_entry(var_ni)
    if bi >= 0:
        if is_mut != 0:
            // &mut x: fail if any borrow exists
            if cell_load(g_borrow_refs, bi * 8) > 0 || cell_load(g_borrow_muts, bi * 8) != 0:
                return false
            cell_store(g_borrow_muts, bi * 8, 1)
            return true
        else:
            // &x: fail if mutable borrow exists
            if cell_load(g_borrow_muts, bi * 8) != 0:
                return false
            cell_store(g_borrow_refs, bi * 8, cell_load(g_borrow_refs, bi * 8) + 1)
            return true
    // First borrow of this variable
    grow_borrow_vars(g_borrow_count + 1)
    cell_store(g_borrow_vars, g_borrow_count * 8, var_ni)
    cell_store(g_borrow_refs, g_borrow_count * 8, 0)
    cell_store(g_borrow_muts, g_borrow_count * 8, 0)
    if is_mut != 0:
        cell_store(g_borrow_muts, g_borrow_count * 8, 1)
    else:
        cell_store(g_borrow_refs, g_borrow_count * 8, 1)
    g_borrow_count = g_borrow_count + 1
    return true

fn check_use(var_ni: int) -> bool:
    bi := find_borrow_entry(var_ni)
    if bi >= 0:
        if cell_load(g_borrow_refs, bi * 8) > 0 || cell_load(g_borrow_muts, bi * 8) != 0:
            return false
    return true

fn push_borrow_scope():
    grow_borrow_markers(g_borrow_scope_depth + 1)
    cell_store(g_borrow_scope_markers, g_borrow_scope_depth * 8, g_holder_count)
    g_borrow_scope_depth = g_borrow_scope_depth + 1

fn pop_borrow_scope():
    if g_borrow_scope_depth > 0:
        g_borrow_scope_depth = g_borrow_scope_depth - 1
        marker := cell_load(g_borrow_scope_markers, g_borrow_scope_depth * 8)
        // Release all borrows held from marker to end
        loop:
            if g_holder_count <= marker:
                break
            g_holder_count = g_holder_count - 1
            borrowed_ni := cell_load(g_holder_borrowed, g_holder_count * 8)
            is_mut := cell_load(g_holder_is_mut, g_holder_count * 8)
            bi := find_borrow_entry(borrowed_ni)
            if bi >= 0:
                if is_mut != 0:
                    cell_store(g_borrow_muts, bi * 8, 0)
                else:
                    if cell_load(g_borrow_refs, bi * 8) > 0:
                        cell_store(g_borrow_refs, bi * 8, cell_load(g_borrow_refs, bi * 8) - 1)
                // Clean up entry if no more borrows
                if cell_load(g_borrow_refs, bi * 8) == 0 && cell_load(g_borrow_muts, bi * 8) == 0:
                    si : ., mut = bi
                    loop:
                        if si + 1 >= g_borrow_count:
                            break
                        cell_store(g_borrow_vars, si * 8, cell_load(g_borrow_vars, (si + 1) * 8))
                        cell_store(g_borrow_refs, si * 8, cell_load(g_borrow_refs, (si + 1) * 8))
                        cell_store(g_borrow_muts, si * 8, cell_load(g_borrow_muts, (si + 1) * 8))
                        si = si + 1
                    g_borrow_count = g_borrow_count - 1

fn push_unsafe_scope():
    g_unsafe_depth = g_unsafe_depth + 1
fn pop_unsafe_scope():
    if g_unsafe_depth > 0:
        g_unsafe_depth = g_unsafe_depth - 1

fn record_borrow_holder(borrower_ni: int, borrowed_ni: int, is_mut: int):
    grow_holder(g_holder_count + 1)
    cell_store(g_holder_borrowers, g_holder_count * 8, borrower_ni)
    cell_store(g_holder_borrowed, g_holder_count * 8, borrowed_ni)
    cell_store(g_holder_is_mut, g_holder_count * 8, is_mut)
    g_holder_count = g_holder_count + 1

fn borrow_var_name(node: int) -> int:
    if node < 0:
        return -1
    if ast_kind(node) == EXPR_IDENT:
        return ast_int_val(node)
    return -1

// --- Type resolution utilities ---

// Resolve `Self` from the function currently being checked. A method's name is
// "Type.method", so the prefix names the impl type. Returns -1 outside a method.
fn self_type_of_current_fn() -> int:
    fi := g_checker_current_fi
    if fi < 0 || fi >= g_func_count:
        return -1
    fn_name := istr_get(fi_name(fi))
    fn_len := str_len(fn_name)
    dot_pos : ., mut = -1
    di : ., mut = 0
    loop:
        if di >= fn_len:
            break
        if cell_load_byte(fn_name, di) == 46:
            dot_pos = di
            break
        di = di + 1
    if dot_pos <= 0:
        return -1
    struct_ni := str_intern(str_sub(fn_name, 0, dot_pos))
    si := find_gsym(struct_ni)
    if si < 0 || sym_kind(si) != SYM_TYPE:
        return -1
    return sym_type(si)

fn res_type_node(node: int) -> int:
    if node < 0:
        return TI_UNIT
    if ast_kind(node) == 0:
        // Base type node: type_val = TY_*
        // 8 条内联分支改为单表 `ty_code_to_ti`（尾部回落显式写出，不藏表里）；
        //  本站点域 = {INT,DEX,BOOL,STRING,UNIT,NEVER,CHAR} ∪ {7 = dyn 码}，与 res_call_type 的
        //  唯一语义差 = NEVER 格（该函数无此格，见其注）。域外（如 TY_DEX_S=8/未知码）落 TI_UNIT。
        tv := ast_type_val(node)
        mapped : ., mut = ty_code_to_ti(tv)
        if mapped < 0:
            mapped = TI_UNIT
        return mapped
    if ast_kind(node) == EXPR_IDENT:
        // Named type: int_val = name string index
        name_idx := ast_int_val(node)
        if str_eq(istr_get(name_idx), "Self") != 0:
            // `Self` is the enclosing impl type. It is derived from the current
            // method's mangled name "Type.method"; there is no separate table.
            self_ti := self_type_of_current_fn()
            if self_ti >= 0:
                return self_ti
            check_error(EC_N_UNDEFINED, "Self is only available inside an impl method", ast_line(node), ast_col(node))
            return ti_error()
        si := find_gsym(name_idx)
        if si >= 0 && sym_kind(si) == SYM_TYPE:
            return sym_type(si)
        // Declaration collection runs with g_cur_lib = -1: forward references
        // are allowed there. Inside a function body an unresolved name means the
        // type is absent or belongs to another library without `pub`.
        if g_cur_lib >= 0:
            check_error(EC_N_UNDEFINED, "Undefined type '" + istr_get(name_idx) + "'", ast_line(node), ast_col(node))
            return ti_error()
        return alloc_named_type(name_idx)
    if ast_kind(node) == EXPR_ARRAY:
        // Representation-layer concept: `[T; N]` has no constructor identity in the
        // type system. Its semantics belong to product (N-ary aggregate), the
        // sequence interface plus length constraints, or F11 length facts. The
        // syntax is kept as an inline-capacity representation hint, at the mapping
        // parameter layer. It takes effect or degrades with the instance selection
        // and can be ignored by non-classic mappings. See
        // See the language surface narrowing design under docs/superpowers/specs,
        // section 1.
        // Array type [T; N] or slice type [T] (size 0)
        elem := res_type_node(ast_a(node))
        sz := ast_int_val(node)
        if sz == 0:
            return alloc_type(TYP_SLICE, elem, 0)
        return alloc_type(TYP_ARRAY, elem, sz)
    if ast_kind(node) == EXPR_REFTYPE:
        // Reference type &T or &mut T
        inner := res_type_node(ast_a(node))
        mut_flag := ast_int_val(node)
        return alloc_type(TYP_REF, inner, mut_flag)
    if ast_kind(node) == EXPR_PTRTYPE:
        // Pointer type *T
        inner := res_type_node(ast_a(node))
        return alloc_type(TYP_PTR, inner, 0)
    if ast_kind(node) == EXPR_OPTIONAL:
        // `T?` = `T ∪ null`（spec 第 5.4 节），行 = TYP_OPTIONAL(data = 内层行)。
        // 语义分三层：1. 桥接把本条类型记录译作 union(内层项, null 原子项)（ty_shadow.cr）；
        // 2. 引擎按普通联合项判定，包含、等价、不相交和穷尽性都走既有 DNF 路径；
        // 3. 判定点（type_compat_strict 等）不变：int 可以进入 int ∪ null，反向不行。
        // 本条记录没有名字，不进入 named_dedup。内容相同的两条记录在引擎侧译成同一个项（DAG 去重），
        // 因此判定等价。
        inner := res_type_node(ast_a(node))
        return alloc_type(TYP_OPTIONAL, inner, 0)
    if ast_kind(node) == EXPR_GENERIC_APPLY:
        // Generic application: Box[int]
        name_idx := ast_a(node)
        first_arg_node := ast_b(node)
        arg_count := ast_c(node)
        si := find_gsym(name_idx)
        if si < 0 || sym_kind(si) != SYM_TYPE:
            check_error(EC_N_GENERIC_TYPE, "Undefined type in generic application", ast_line(node), ast_col(node))
            return TI_UNIT
        base_ti := sym_type(si)
        // 实参类型解析会向 g_gen_apply_data 追加数据，嵌套应用 Box[Box[int]] 的内层携带值
        // 也不例外。因此先解析进暂存，后一次性认领连续块。先认领再逐参解析会让内层 append
        // 冲掉外层的 count 槽和后续携带值槽，导致 Box[Box[int]] 的字段和返回位被误判。
        args : string, mut
        if arg_count > 0:
            args = alloc(arg_count * 8)
            ai : ., mut = 0
            an : ., mut = first_arg_node
            loop:
                if ai >= arg_count:
                    break
                cell_store(args, ai * 8, res_type_node(an))
                ai = ai + 1
                an = an + 1
        // 实例化点的结构/枚举泛型约束检查（`Box[T: I]` 的 `Box[P]`）。
        // 判定 = ty_sub（本质轴）+ 反例诊断；用户接口约束 = -1 零动作。
        gen_inst_constr_check(node, find_struct(name_idx), find_enum(name_idx), args, arg_count)
        // Store args in g_gen_apply_data: [count, arg1, arg2, ...]
        data_start := g_gen_apply_data_count
        grow_gen_apply_data(data_start + 1 + arg_count)
        cell_store(g_gen_apply_data, data_start * 8, arg_count)
        ai2 : ., mut = 0
        loop:
            if ai2 >= arg_count:
                break
            cell_store(g_gen_apply_data, (data_start + 1 + ai2) * 8, cell_load(args, ai2 * 8))
            ai2 = ai2 + 1
        g_gen_apply_data_count = data_start + 1 + arg_count
        return alloc_type(TYP_GENERIC_APPLY, base_ti, data_start)
    return TI_UNIT

fn find_struct(name_idx: int) -> int:
    i : ., mut = 0
    loop:
        if i >= g_struct_count:
            return -1
        if si_name(i) == name_idx:
            return i
        i = i + 1
    return -1

fn find_enum_by_ni(name_idx: int) -> int:
    i : ., mut = 0
    loop:
        if i >= g_enum_count:
            return -1
        if ei_name(i) == name_idx:
            return i
        i = i + 1
    return -1

fn find_enum(name_idx: int) -> int:
    if g_cur_lib < 0:
        return find_enum_by_ni(name_idx)
    rec := decl_map_find_unique(name_idx)
    if rec >= 0:
        if cell_load(g_decl_map, rec * 40 + 8) == DECL_ENUM && cell_load(g_decl_map, rec * 40) != name_idx:
            return find_enum_by_ni(name_idx)
    si := find_gsym(name_idx)
    if si < 0 || sym_kind(si) != SYM_TYPE:
        if g_cur_lib < 0:
            return find_enum_by_ni(name_idx)
        return -1
    ti := sym_type(si)
    if ti >= 0 && ti < g_type_count && get_type_kind(ti) == TYP_NAMED:
        return find_enum_by_ni(get_type_data(ti))
    if g_cur_lib < 0:
        return find_enum_by_ni(name_idx)
    return -1

// Infer the interface constraint for an unconstrained generic parameter from a
// method call. Returns the interface name index when exactly one interface
// declares the method; -1 when none or multiple (ambiguous).
fn infer_iface_for_method(method_ni: int) -> int:
    found : ., mut = -1
    hits : ., mut = 0
    ii : ., mut = 0
    loop:
        if ii >= g_iface_count:
            break
        mc := cell_load(g_ifaces, ii * ESZ_IFACEINFO + OFF_IF_METHOD_COUNT)
        mi : ., mut = 0
        loop:
            if mi >= mc:
                break
            mb := ii * ESZ_IFACEINFO + OFF_IF_METHODS + mi * ESZ_IFMETHOD
            if cell_load(g_ifaces, mb + OFF_IFM_NAME) == method_ni:
                found = cell_load(g_ifaces, ii * ESZ_IFACEINFO + OFF_IF_NAME)
                hits = hits + 1
                break
            mi = mi + 1
        ii = ii + 1
    if hits == 1:
        return found
    return -1

// Ambiguous method name: choose the unique interface whose method return type
// matches the enclosing function's declared/inferred return type. This is the
// V4 disambiguation rule when several interfaces declare the same method name.
fn infer_iface_for_method_ret(method_ni: int, want_ti: int) -> int:
    found : ., mut = -1
    hits : ., mut = 0
    ii : ., mut = 0
    loop:
        if ii >= g_iface_count:
            break
        mc := cell_load(g_ifaces, ii * ESZ_IFACEINFO + OFF_IF_METHOD_COUNT)
        mi : ., mut = 0
        loop:
            if mi >= mc:
                break
            mb := ii * ESZ_IFACEINFO + OFF_IF_METHODS + mi * ESZ_IFMETHOD
            if cell_load(g_ifaces, mb + OFF_IFM_NAME) == method_ni:
                rti := ty_code_to_ti(cell_load(g_ifaces, mb + OFF_IFM_RET_TI))
                if rti >= 0 && rti == want_ti:
                    found = cell_load(g_ifaces, ii * ESZ_IFACEINFO + OFF_IF_NAME)
                    hits = hits + 1
                break
            mi = mi + 1
        ii = ii + 1
    if hits == 1:
        return found
    return -1

fn find_iface_by_ni(name_ni: int) -> int:
    i : ., mut = 0
    loop:
        if i >= g_iface_count:
            return -1
        if cell_load(g_ifaces, i * ESZ_IFACEINFO + OFF_IF_NAME) == name_ni:
            return i
        i = i + 1
    return -1

fn find_iface(name_ni: int) -> int:
    if g_cur_lib < 0:
        return find_iface_by_ni(name_ni)
    rec := decl_map_find_unique(name_ni)
    if rec >= 0:
        if cell_load(g_decl_map, rec * 40 + 8) == DECL_IFACE && cell_load(g_decl_map, rec * 40) != name_ni:
            return find_iface_by_ni(name_ni)
    si := find_gsym(name_ni)
    if si < 0 || sym_kind(si) != SYM_TYPE:
        if g_cur_lib < 0:
            return find_iface_by_ni(name_ni)
        return -1
    ti := sym_type(si)
    if ti >= 0 && ti < g_type_count && get_type_kind(ti) == TYP_NAMED:
        return find_iface_by_ni(get_type_data(ti))
    if g_cur_lib < 0:
        return find_iface_by_ni(name_ni)
    return -1

// ─── 展开层的行 -> 声明入口（名字解析归 checker；展开层只读声明表）───
// ti 接受两种形态（与桥接 sh_term_of_ti 的 TYP_NAMED / TYP_GENERIC_APPLY 两分支同域）：
//  TYP_NAMED（data = 名字 ni）/ TYP_GENERIC_APPLY（data = 基型行；基型须为 TYP_NAMED）。
// -1 = 既非命名行也非泛型应用行 / 基型非命名行。只读（不改类型表、不报诊断、不分配）。
fn decl_name_of_ti(ti: int) -> int:
    if ti < 0:
        return -1
    k := get_type_kind(ti)
    if k == TYP_NAMED:
        return get_type_data(ti)
    if k == TYP_GENERIC_APPLY:
        base := get_type_data(ti)
        if get_type_kind(base) == TYP_NAMED:
            return get_type_data(base)
    return -1

// 命名/泛型应用行 -> struct 声明行（-1 = 非此二形态 / 该名字未声明为 struct）
fn find_struct_row_of(ti: int) -> int:
    ni := decl_name_of_ti(ti)
    if ni < 0:
        return -1
    return find_struct(ni)

// 同上 -> enum 声明行
fn find_enum_row_of(ti: int) -> int:
    ni := decl_name_of_ti(ti)
    if ni < 0:
        return -1
    return find_enum(ni)

fn get_type_name(ti: int) -> int:
    k := get_type_kind(ti)
    if k == TYP_NAMED:
        return get_type_data(ti)
    if k == TYP_BASE:
        d := get_type_data(ti)
        if d == TY_INT:
            return str_intern("int")
        if d == TY_DEX:
            return str_intern("dex")
        if d == TY_BOOL:
            return str_intern("bool")
        if d == TY_STRING:
            return str_intern("string")
        if d == TY_UNIT:
            return str_intern("unit")
        if d == TY_CHAR:
            return str_intern("char")
    if k == TYP_GENERIC_APPLY:
        base := get_type_data(ti)
        if get_type_kind(base) == TYP_NAMED:
            return get_type_data(base)
    return -1

// 方法解析从`Type.method` 字符串拼接 + `find_func`
// 改为表查询（`g_methods` 三元组 {type_ni, method_ni, func_name_ni}，parser 的 impl 分支
// 唯一写点；引擎侧同一入口 iface_find_method）。域等价（同一 impl 声明信息），
// This path does not call str_intern, so a missing method name does not grow the
// .ccr STR segment.
fn type_has_method(type_ni: int, method_ni: int) -> bool:
    if iface_find_method(type_ni, method_ni) < 0:
        return false
    return true

// 接口满足判定（bool 类型；语义 = 引擎轴 C 用户判断条件的同一实现 `iface_user_satisfies_ii`，
// 见 type_engine.cr：方法名表查询 + 接收者模式 + 签名项引擎判定）。保持 bool 返回值的理由 =
// 调用点（泛型约束的函数调用位点）的既有语义不能判定为满足，因此报 TG02逐字不变（措辞/去重/
// 本函数不改变 rc；判定结果由 iface_satisfies 和 iface_user_satisfies 承担。
fn check_iface(type_ni: int, iface_ii: int) -> bool:
    if iface_user_satisfies_ii(type_ni, iface_ii) == 1:
        return true
    return false

// ─── 泛型约束：保留、实例化判定、反例 ───
// fn f[T] 的约束为 ⊤；fn f[T: I] 的约束为类型项 I。结构泛型和枚举泛型同样保存约束。
// 实例化检查使用 ty_sub(实参, 约束)，失败时给出非空反例 tt_witness。
//
// 本质轴（约束项是原生或已声明类型名）由 gen_constr_satisfied 走引擎判定。
// 用户轴（I 是 interface 名）由 iface_satisfies 判定。两个站点的规则不同：
//  函数调用点 gen_constr_satisfied 只接受 1；0 和 -1 走既有 check_iface 名拼接路径，
//  诊断措辞、去重和返回码保持不变。
//  结构/枚举实例化点 gen_inst_constr_satisfied 直接取 iface_satisfies 的布尔结果，0 报 TG02。
//
// 判定约定：-1 一律不判，不得当作 0 或 1。预算隔离与 ti_subsumes 相同。
fn gen_constr_type_ti(c_ni: int) -> int:
    if c_ni < 0:
        return -1
    s := istr_get(c_ni)
    if str_eq(s, "int") != 0:
        return TI_INT
    if str_eq(s, "dex") != 0:
        return TI_DEX
    if str_eq(s, "bool") != 0:
        return TI_BOOL
    if str_eq(s, "string") != 0:
        return TI_STR
    if str_eq(s, "char") != 0:
        return TI_CHAR
    if str_eq(s, "unit") != 0:
        return TI_UNIT
    if str_eq(s, "never") != 0:
        return TI_NEVER
    if str_eq(s, "dyn") != 0:
        return TI_DYN
    si := find_gsym(c_ni)
    if si >= 0 && sym_kind(si) == SYM_TYPE:
        return sym_type(si)
    return -1

// 约束满足判定结果：1 = 满足，0 = 违反，-1 = 不判（名字不是类型或接口，或桥接失败）。
// 1/0/-1 原样返回，不把 -1 折成 0 或 1。
fn gen_constr_satisfied(c_ni: int, arg_ti: int) -> int:
    if c_ni < 0 || arg_ti < 0:
        return -1
    if find_iface(c_ni) >= 0:
        // 用户轴：iface_satisfies 返回 1 时提前返回，省一次名字拼接和查表。0 与 -1 走下方
        // 既有 check_iface 名拼接路径，保持诊断措辞、去重和返回码不变。iface_user_satisfies
        // 与 check_iface 判定同一点，因此两条路径不会给出不同结论。
        s := iface_satisfies(arg_ti, c_ni)
        if s == 1:
            return 1
        return -1
    cti := gen_constr_type_ti(c_ni)
    if cti < 0:
        return -1
    // 非类型名（未定义名等）：不判、不发明诊断
    a := sh_term_of_ti(arg_ti)
    b := sh_term_of_ti(cti)
    if a < 0 || b < 0:
        return -1
    // 桥接缺口，因此不判
    ty_budget_reset(200000)
    s := ty_sub(a, b)
    ty_budget_reset(200000)
    return s                                      // 1/0/-1 直传

// 结构/枚举实例化点的约束判定：用户轴直接取 iface_satisfies 的布尔结果，不回落。函数调用点
// 的消息和去重规则与本函数无关。1/0/-1 原样返回：1 满足，0 违反，-1 不判，调用方在 -1 时不动。
fn gen_inst_constr_satisfied(c_ni: int, arg_ti: int) -> int:
    if c_ni < 0 || arg_ti < 0:
        return -1
    if find_iface(c_ni) >= 0:
        return iface_satisfies(arg_ti, c_ni)
    return gen_constr_satisfied(c_ni, arg_ti)

// 反例文本（诊断用）：`实参 \ 约束` 的具体值。判定结果 -1 / 反例不可得 -> ""（不谎报反例）。
fn gen_constr_witness_str(arg_ti: int, c_ni: int) -> string:
    cti := gen_constr_type_ti(c_ni)
    if cti < 0:
        return ""
    a := sh_term_of_ti(arg_ti)
    b := sh_term_of_ti(cti)
    if a < 0 || b < 0:
        return ""
    ty_budget_reset(200000)
    w := tt_witness(a, b)
    ty_budget_reset(200000)
    if w < 0:
        return ""
    return tt_display(w)

// 诊断发射（措辞分派：既有接口路径的措辞/码不动；本路径 = 约束 + 反例）。码沿用
// EC_TG_BOUND（TG02，软诊断：check rc=1 / build rc=0，与既有约束检查同检查，不新增强制检查）。
fn gen_constr_raise(arg_ti: int, c_ni: int, line: int, col: int):
    // 措辞分派：接口名约束，因此与既有 check_iface 路径同措辞（"does not satisfy interface
    // 'X'"，两站点一致性；接口非类型表记录，因此反例项不可得 = 不附反例，不谎报）；类型名约束，因此
    // 既有措辞 + 反例（措措辞与反例保持不变）。
    if find_iface(c_ni) >= 0:
        msg_i := "Type '" + type_display(arg_ti) + "' does not satisfy interface '" + istr_get(c_ni) + "'"
        check_error(EC_TG_BOUND, msg_i, line, col)
        return
    msg : ., mut = "Type '" + type_display(arg_ti) + "' does not satisfy constraint '" + istr_get(c_ni) + "'"
    w := gen_constr_witness_str(arg_ti, c_ni)
    if str_len(w) > 0:
        msg = msg + " (counterexample: " + w + ")"
    check_error(EC_TG_BOUND, msg, line, col)

// ─── 诊断去重侧表（开放寻址，16B/条 {key, 1}；key = node * MAX_GENERICS + gi）───
// 为何需要：实例化点的判定函数（res_type_node / res_call_type）按语法出现点调用，同一
// AST 节点可被多次解析（字段访问、多次引用同一注解…），且 `check_error` 无去重，因此不去重即
// 同一条约束违反被打印多次。键 = (节点, 形参下标)，同节点不同形参各报一条（信息不丢）。
// 生命周期同 named_dedup（init_types 置 cap=0 -> 惰性重建）；键含 AST 节点下标，因此随编译期作废。
fn gen_constr_seen_init():
    if g_constr_seen_cap > 0:
        return
    nc := 1024
    nb := alloc(nc * 16)
    i : ., mut = 0
    loop:
        if i >= nc:
            break
        cell_store(nb, i * 16, -1)
        i = i + 1
    g_constr_seen = nb
    g_constr_seen_cap = nc
    g_constr_seen_count = 0

fn gen_constr_seen_reset():
    g_constr_seen_cap = 0
    g_constr_seen_count = 0

fn gen_constr_seen_probe(k: int) -> int:
    cap := g_constr_seen_cap
    p : ., mut = tt_mod(k, cap)
    ret : ., mut = -1
    loop:
        kk := cell_load(g_constr_seen, p * 16)
        if kk < 0:
            ret = p
            break
        if kk == k:
            ret = p
            break
        p = p + 1
        if p >= cap:
            p = 0
    return ret

fn gen_constr_seen_rehash():
    old := g_constr_seen
    old_cap := g_constr_seen_cap
    nc : ., mut = old_cap * 2
    nb := alloc(nc * 16)
    i : ., mut = 0
    loop:
        if i >= nc:
            break
        cell_store(nb, i * 16, -1)
        i = i + 1
    g_constr_seen = nb
    g_constr_seen_cap = nc
    g_constr_seen_count = 0
    j : ., mut = 0
    loop:
        if j >= old_cap:
            break
        kk := cell_load(old, j * 16)
        if kk >= 0:
            s := gen_constr_seen_probe(kk)
            cell_store(g_constr_seen, s * 16, kk)
            cell_store(g_constr_seen, s * 16 + 8, 1)
            g_constr_seen_count = g_constr_seen_count + 1
        j = j + 1

// 1 = 首次（调用方报诊断），0 = 已报过（丢弃）。装填因子检查在探测前（表满 + 键不存在
// 因此开放寻址永不退出，照 named_dedup / sh_map 同款同因）。
fn gen_constr_seen_add(k: int) -> int:
    gen_constr_seen_init()
    if (g_constr_seen_count + 1) * 2 >= g_constr_seen_cap:
        gen_constr_seen_rehash()
    s : ., mut = gen_constr_seen_probe(k)
    if cell_load(g_constr_seen, s * 16) == k:
        return 0
    cell_store(g_constr_seen, s * 16, k)
    cell_store(g_constr_seen, s * 16 + 8, 1)
    g_constr_seen_count = g_constr_seen_count + 1
    return 1

// ─── 实例化点检查（结构/枚举泛型：`Box[T: I]` 的 `Box[P]`）───
// 消费点 = res_type_node / res_call_type 的 EXPR_GENERIC_APPLY 分支（实参已解析成 ti 处）。
// sa/ea = struct/enum 声明行（-1 = 该名字不是 struct/enum， 接口泛型/未知名，零动作）。
// 实参缺位不判（不越界读）；arg_ti < 0 不判（未解析）；用户接口约束经
// gen_constr_satisfied 回 -1，因此零动作。
fn gen_inst_constr_check(app_node: int, sa: int, ea: int, args: string, arg_count: int):
    gc : ., mut = 0
    if sa >= 0:
        gc = si_generic_count(sa)
    else if ea >= 0:
        gc = ei_generic_count(ea)
    else:
        return
    i : ., mut = 0
    loop:
        if i >= gc:
            break
        if i >= arg_count:
            break
        c_ni : ., mut = -1
        if sa >= 0:
            c_ni = si_gen_constr(sa, i)
        else:
            c_ni = ei_gen_constr(ea, i)
        if c_ni >= 0:
            arg_ti := cell_load(args, i * 8)
            if arg_ti >= 0:
                if gen_inst_constr_satisfied(c_ni, arg_ti) == 0:
                    if gen_constr_seen_add(app_node * MAX_GENERICS + i) != 0:
                        gen_constr_raise(arg_ti, c_ni, ast_line(app_node), ast_col(app_node))
        i = i + 1

// --- First pass: collect all declarations ---

// A named type symbol carries a synthetic declaration node so the symbol's
// owning library is derived from its real declaration line (types have no
// EXPR_* declaration node of their own).
fn def_type_sym(name_idx: int, ti: int, line: int):
    node : ., mut = -1
    if line > 0:
        node = alloc_node(EXPR_NONE, 0, 0, 0, 0, 0, 0, line, 1)
    def_sym(name_idx, SYM_TYPE, ti, node)
    si := g_sym_count - 1
    owner := lib_of_node(node)
    sym_set_owner(si, owner)
    type_pub : ., mut = 0
    if owner >= 0 && lib_export_find_kind(owner, name_idx, SYM_TYPE) >= 0:
        type_pub = 1
    sym_set_pub(si, type_pub)

// `impl I for T` resolves the interface name through the symbol table but the
// parser has no visibility context. Validate each edge from its declaration
// line so a private interface cannot be implemented across libraries.
fn check_impl_visibility():
    i : ., mut = 0
    loop:
        if i >= g_impl_for_count:
            break
        line := cell_load(g_impl_for_line, i * 8)
        if line > 0:
            trait_ni := cell_load(g_impl_for, i * 16)
            ctx := lib_of_line(line)
            towner := decl_owner_for_unique(trait_ni)
            if towner >= 0 && towner != ctx:
                if lib_can_import(ctx, towner) == 0 || lib_export_find_kind(towner, decl_src_for_unique(trait_ni), SYM_TYPE) < 0:
                    check_error(EC_N_UNDEFINED, "Undefined type '" + istr_get(decl_src_for_unique(trait_ni)) + "'", line, 1)
        i = i + 1

// A bare generic struct type in a parameter position (`fn f(b: Box)` where
// `Box` has an inferred field) carries no type argument. Bind each such
// occurrence to fresh function-scoped type variables, then rewrite the node to
// `Box[__bindN, ...]`. The existing monomorph path then unifies the variables
// with the concrete argument at each call site.
fn bind_bare_generic_type(node: int, fi: int) -> int:
    if node < 0 || ast_kind(node) != EXPR_IDENT:
        return node
    name_ni := ast_int_val(node)
    si := find_struct_by_name(name_ni)
    if si < 0:
        return node
    need := si_generic_count(si)
    if need <= 0:
        return node
    gc := fi_generic_count(fi)
    if gc + need > MAX_GENERICS:
        // The language guardrail is four generic parameters per declaration.
        // Leave the node untouched; the field projection will fail closed.
        return node
    ga := alloc_node(EXPR_GENERIC_APPLY, name_ni, -1, need, 0, 0, 0, ast_line(node), ast_col(node))
    first_arg := g_ast_count
    gi : ., mut = 0
    loop:
        if gi >= need:
            break
        bname := str_intern("__bind" + int_str(g_infer_name_seq))
        g_infer_name_seq = g_infer_name_seq + 1
        alloc_node(EXPR_IDENT, 0, 0, 0, bname, 0, 0, ast_line(node), ast_col(node))
        fi_set_generic_name(fi, gc + gi, bname)
        gi = gi + 1
    fi_set_generic_count(fi, gc + need)
    ast_set_b(ga, first_arg)
    return ga

fn bind_bare_generic_params():
    saved_lib := g_cur_lib
    fi : ., mut = 0
    loop:
        if fi >= g_func_count:
            break
        fn_node := fi_ast_node(fi)
        if fn_node >= 0 && ast_kind(fn_node) == EXPR_FN:
            g_cur_lib = lib_of_node(fn_node)
            pc := ast_c(fn_node)
            pn : ., mut = ast_b(fn_node)
            pi : ., mut = 0
            loop:
                if pi >= pc || pn < 0 || pn >= g_ast_count:
                    break
                if ast_kind(pn) == EXPR_PARAM:
                    orig := ast_data(pn)
                    if orig >= 0 && ast_kind(orig) != 0:
                        new_node := bind_bare_generic_type(orig, fi)
                        if new_node != orig:
                            ast_set_data(pn, new_node)
                    pi = pi + 1
                pn = pn + 1
                loop:
                    if pn >= g_ast_count:
                        break
                    if ast_kind(pn) == EXPR_PARAM:
                        break
                    pn = pn + 1
        fi = fi + 1
    g_cur_lib = saved_lib


// Declaration kinds for the library declaration map.

fn decl_map_add(src: int, kind: int, lib: int, unique: int, ti: int):
    grow_decl_map(g_decl_map_count + 1)
    off := g_decl_map_count * 40
    cell_store(g_decl_map, off, src)
    cell_store(g_decl_map, off + 8, kind)
    cell_store(g_decl_map, off + 16, lib)
    cell_store(g_decl_map, off + 24, unique)
    cell_store(g_decl_map, off + 32, ti)
    g_decl_map_count = g_decl_map_count + 1

fn decl_map_find(src: int, kind: int, lib: int) -> int:
    i : ., mut = 0
    loop:
        if i >= g_decl_map_count:
            return -1
        off := i * 40
        if cell_load(g_decl_map, off) == src && cell_load(g_decl_map, off + 8) == kind && cell_load(g_decl_map, off + 16) == lib:
            return i
        i = i + 1
    return -1

fn decl_map_find_unique(unique: int) -> int:
    i : ., mut = 0
    loop:
        if i >= g_decl_map_count:
            return -1
        if cell_load(g_decl_map, i * 40 + 24) == unique:
            return i
        i = i + 1
    return -1

fn decl_src_for_unique(unique: int) -> int:
    rec := decl_map_find_unique(unique)
    if rec < 0:
        return unique
    return cell_load(g_decl_map, rec * 40)

fn decl_owner_for_unique(unique: int) -> int:
    rec := decl_map_find_unique(unique)
    if rec < 0:
        return -1
    return cell_load(g_decl_map, rec * 40 + 16)

fn decl_set_type_ti(src: int, kind: int, lib: int, ti: int):
    rec := decl_map_find(src, kind, lib)
    if rec >= 0:
        cell_store(g_decl_map, rec * 40 + 32, ti)

// Resolve a source-level declaration name to its internal unique name for the
// given library. The exact (source, kind, lib) row wins; otherwise a single
// importable pub declaration is used. -1 = absent or ambiguous.
fn decl_unique_for(src: int, kind: int, lid: int) -> int:
    rec := decl_map_find(src, kind, lid)
    if rec >= 0:
        return cell_load(g_decl_map, rec * 40 + 24)
    if lid < 0:
        return -1
    cand : ., mut = -1
    i : ., mut = 0
    loop:
        if i >= g_decl_map_count:
            break
        off := i * 40
        if cell_load(g_decl_map, off) == src && cell_load(g_decl_map, off + 8) == kind:
            olib := cell_load(g_decl_map, off + 16)
            if olib != lid && lib_can_import(lid, olib) != 0 && lib_export_find_kind(olib, src, SYM_TYPE) >= 0:
                if cand >= 0:
                    return -1
                cand = cell_load(g_decl_map, off + 24)
        i = i + 1
    return cand

// Give same-named type declarations from different libraries distinct internal
// names. Source names stay on the symbols and in exports; the unique name is the
// type identity handed to TYP_NAMED, so library code and user code never share a
// layout or an interface row by accident. Collision detection runs on snapshots
// of the source names: renaming an earlier record must not hide a later
// collision.
DECL_STRUCT : int = 0
DECL_ENUM : int = 1
DECL_IFACE : int = 2
DECL_ALIAS : int = 3

fn decl_collides(srcs: string, libs: string, n: int, i: int) -> int:
    src := cell_load(srcs, i * 8)
    lib := cell_load(libs, i * 8)
    j : ., mut = 0
    loop:
        if j >= n:
            return 0
        if j != i && cell_load(srcs, j * 8) == src && cell_load(libs, j * 8) != lib:
            return 1
        j = j + 1
    return 0

fn unique_type_name(src: int, lib: int, suffix: string, i: int) -> int:
    return str_intern(istr_get(src) + "@" + lib_name(lib) + "#" + suffix + int_str(i))

fn assign_unique_struct_names():
    n := g_struct_count
    srcs := alloc(n * 8)
    libs := alloc(n * 8)
    i : ., mut = 0
    loop:
        if i >= n:
            break
        cell_store(srcs, i * 8, si_name(i))
        cell_store(libs, i * 8, lib_of_line(si_decl_line(i)))
        i = i + 1
    i = 0
    loop:
        if i >= n:
            break
        src := cell_load(srcs, i * 8)
        lib := cell_load(libs, i * 8)
        unique : ., mut = src
        if decl_collides(srcs, libs, n, i) != 0:
            unique = unique_type_name(src, lib, "struct", i)
            cell_store(g_structs, i * ESZ_STRUCTINFO + OFF_SI_NAME, unique)
        decl_map_add(src, DECL_STRUCT, lib, unique, -1)
        i = i + 1

fn assign_unique_enum_names():
    n := g_enum_count
    srcs := alloc(n * 8)
    libs := alloc(n * 8)
    i : ., mut = 0
    loop:
        if i >= n:
            break
        cell_store(srcs, i * 8, ei_name(i))
        cell_store(libs, i * 8, lib_of_line(ei_decl_line(i)))
        i = i + 1
    i = 0
    loop:
        if i >= n:
            return
        src := cell_load(srcs, i * 8)
        lib := cell_load(libs, i * 8)
        unique : ., mut = src
        if decl_collides(srcs, libs, n, i) != 0:
            unique = unique_type_name(src, lib, "enum", i)
            cell_store(g_enums, i * ESZ_ENUMINFO + OFF_EI_NAME, unique)
        decl_map_add(src, DECL_ENUM, lib, unique, -1)
        i = i + 1

fn assign_unique_iface_names():
    n := g_iface_count
    srcs := alloc(n * 8)
    libs := alloc(n * 8)
    i : ., mut = 0
    loop:
        if i >= n:
            break
        cell_store(srcs, i * 8, cell_load(g_ifaces, i * ESZ_IFACEINFO + OFF_IF_NAME))
        cell_store(libs, i * 8, lib_of_line(cell_load(g_ifaces, i * ESZ_IFACEINFO + OFF_IF_DECL_LINE)))
        i = i + 1
    i = 0
    loop:
        if i >= n:
            return
        src := cell_load(srcs, i * 8)
        lib := cell_load(libs, i * 8)
        unique : ., mut = src
        if decl_collides(srcs, libs, n, i) != 0:
            unique = unique_type_name(src, lib, "iface", i)
            cell_store(g_ifaces, i * ESZ_IFACEINFO + OFF_IF_NAME, unique)
        decl_map_add(src, DECL_IFACE, lib, unique, -1)
        i = i + 1

fn assign_unique_alias_names():
    n := g_type_alias_count
    srcs := alloc(n * 8)
    libs := alloc(n * 8)
    i : ., mut = 0
    loop:
        if i >= n:
            break
        cell_store(srcs, i * 8, cell_load(g_type_aliases, i * ESZ_TYPE_ALIAS + OFF_TA_NAME))
        cell_store(libs, i * 8, lib_of_line(cell_load(g_type_aliases, i * ESZ_TYPE_ALIAS + OFF_TA_LINE)))
        i = i + 1
    i = 0
    loop:
        if i >= n:
            return
        src := cell_load(srcs, i * 8)
        lib := cell_load(libs, i * 8)
        unique : ., mut = src
        if decl_collides(srcs, libs, n, i) != 0:
            unique = unique_type_name(src, lib, "alias", i)
            cell_store(g_type_aliases, i * ESZ_TYPE_ALIAS + OFF_TA_NAME, unique)
        decl_map_add(src, DECL_ALIAS, lib, unique, -1)
        i = i + 1

fn remap_method_type_keys():
    mi : ., mut = 0
    loop:
        if mi >= g_method_count:
            return
        type_ni := cell_load(g_methods, mi * 24)
        owner := cell_load(g_method_lib, mi * 8)
        if owner >= 0:
            unique := decl_unique_for(type_ni, DECL_STRUCT, owner)
            if unique >= 0:
                cell_store(g_methods, mi * 24, unique)
        mi = mi + 1

fn remap_impl_pairs():
    i : ., mut = 0
    loop:
        if i >= g_impl_for_count:
            return
        line := cell_load(g_impl_for_line, i * 8)
        if line > 0:
            lid := lib_of_line(line)
            tr := cell_load(g_impl_for, i * 16)
            ty := cell_load(g_impl_for, i * 16 + 8)
            utr : ., mut = decl_unique_for(tr, DECL_IFACE, lid)
            if utr < 0:
                utr = decl_unique_for(tr, DECL_STRUCT, lid)
            uty : ., mut = decl_unique_for(ty, DECL_STRUCT, lid)
            if uty < 0:
                uty = decl_unique_for(ty, DECL_ENUM, lid)
            if utr >= 0:
                cell_store(g_impl_for, i * 16, utr)
            if uty >= 0:
                cell_store(g_impl_for, i * 16 + 8, uty)
        i = i + 1

// Coherence: an impl may be foreign only when at least one side is declared in
// the implementing library, and a (interface, type) pair may be implemented
// only once.
fn type_exposes_hidden(ti: int, owner: int) -> int:
    k := get_type_kind(ti)
    if k == TYP_NAMED:
        unique := get_type_data(ti)
        if decl_owner_for_unique(unique) == owner:
            if lib_export_find_kind(owner, decl_src_for_unique(unique), SYM_TYPE) < 0:
                return 1
        return 0
    if k == TYP_GENERIC_APPLY:
        if type_exposes_hidden(get_type_data(ti), owner) != 0:
            return 1
        start := get_type_extra(ti)
        cnt := cell_load(g_gen_apply_data, start * 8)
        i : ., mut = 0
        loop:
            if i >= cnt:
                break
            if type_exposes_hidden(cell_load(g_gen_apply_data, (start + 1 + i) * 8), owner) != 0:
                return 1
            i = i + 1
        return 0
    if k == TYP_ARRAY || k == TYP_SLICE || k == TYP_REF || k == TYP_PTR || k == TYP_OPTIONAL:
        return type_exposes_hidden(get_type_data(ti), owner)
    return 0

fn node_exposes_hidden(node: int, owner: int) -> int:
    if node < 0:
        return 0
    k := ast_kind(node)
    if k == EXPR_IDENT:
        si := find_gsym(ast_int_val(node))
        if si >= 0 && sym_kind(si) == SYM_TYPE:
            return type_exposes_hidden(sym_type(si), owner)
        return 0
    if k == EXPR_GENERIC_APPLY:
        si := find_gsym(ast_a(node))
        if si >= 0 && sym_kind(si) == SYM_TYPE:
            if type_exposes_hidden(sym_type(si), owner) != 0:
                return 1
        cnt := ast_c(node)
        an : ., mut = ast_b(node)
        i : ., mut = 0
        loop:
            if i >= cnt:
                break
            if node_exposes_hidden(an, owner) != 0:
                return 1
            an = an + 1
            i = i + 1
        return 0
    if k == EXPR_ARRAY || k == EXPR_REFTYPE || k == EXPR_PTRTYPE || k == EXPR_OPTIONAL:
        return node_exposes_hidden(ast_a(node), owner)
    return 0

fn check_public_api_exposure():
    saved_lib := g_cur_lib
    i : ., mut = 0
    loop:
        if i >= g_func_count:
            break
        fn_node := fi_ast_node(i)
        if fn_node >= 0 && fn_node_is_pub(fn_node) != 0:
            owner := func_owner(i)
            if owner >= 0:
                g_cur_lib = owner
                rtn := ast_type_val(fn_node)
                if rtn > 0 && ast_kind(rtn) != 0 && node_exposes_hidden(rtn, owner) != 0:
                    print("warning: public function '")
                    print(istr_get(fi_name(i)))
                    println("' exposes a library-private type")
                pn : ., mut = ast_b(fn_node)
                pc := ast_c(fn_node)
                pi : ., mut = 0
                loop:
                    if pi >= pc || pn < 0:
                        break
                    if ast_kind(pn) == EXPR_PARAM:
                        tn := ast_data(pn)
                        if tn >= 0 && ast_kind(tn) != 0 && node_exposes_hidden(tn, owner) != 0:
                            print("warning: public function '")
                            print(istr_get(fi_name(i)))
                            println("' has a parameter exposing a library-private type")
                        pi = pi + 1
                    pn = pn + 1
                    loop:
                        if pn >= g_ast_count:
                            break
                        if ast_kind(pn) == EXPR_PARAM:
                            break
                        pn = pn + 1
        i = i + 1
    i = 0
    loop:
        if i >= g_global_let_count:
            break
        node := cell_load(g_global_lets, i * 8)
        owner := lib_of_node(node)
        if owner >= 0:
            g_cur_lib = owner
            si := find_gsym(ast_a(node))
            if si >= 0 && sym_kind(si) == SYM_GLOBAL && sym_pub_field(si) != 0:
                tn := ast_b(node)
                if tn >= 0 && node_exposes_hidden(tn, owner) != 0:
                    print("warning: public global '")
                    print(istr_get(ast_a(node)))
                    println("' exposes a library-private type")
        i = i + 1
    g_cur_lib = saved_lib

fn check_impl_coherence():
    i : ., mut = 0
    loop:
        if i >= g_impl_for_count:
            return
        line := cell_load(g_impl_for_line, i * 8)
        if line > 0:
            ctx := lib_of_line(line)
            trait_ni := cell_load(g_impl_for, i * 16)
            type_ni := cell_load(g_impl_for, i * 16 + 8)
            towner := decl_owner_for_unique(trait_ni)
            yowner := decl_owner_for_unique(type_ni)
            if towner >= 0 && towner != ctx:
                if yowner < 0 || yowner != ctx:
                    check_error(EC_N_UNDEFINED, "Orphan impl: interface '" + istr_get(decl_src_for_unique(trait_ni)) + "' and type '" + istr_get(decl_src_for_unique(type_ni)) + "' are both foreign", line, 1)
            j : ., mut = 0
            loop:
                if j >= i:
                    break
                if cell_load(g_impl_for, j * 16) == trait_ni && cell_load(g_impl_for, j * 16 + 8) == type_ni:
                    check_error(EC_N_DUPLICATE, "Conflicting impl for interface '" + istr_get(decl_src_for_unique(trait_ni)) + "' and type '" + istr_get(decl_src_for_unique(type_ni)) + "'", line, 1)
                    break
                j = j + 1
        i = i + 1

fn find_func_owned(name_idx: int, owner: int) -> int:
    i : ., mut = 0
    loop:
        if i >= g_func_count:
            return -1
        if fi_name(i) == name_idx && func_owner(i) == owner:
            return i
        i = i + 1
    return -1

fn func_name_collides(i: int) -> int:
    src := fi_name(i)
    owner := func_owner(i)
    j : ., mut = 0
    loop:
        if j >= g_func_count:
            return 0
        if j != i && fi_name(j) == src && func_owner(j) != owner:
            return 1
        j = j + 1
    return 0

fn assign_unique_func_links():
    i : ., mut = 0
    loop:
        if i >= g_func_count:
            return
        if func_name_collides(i) != 0:
            owner := func_owner(i)
            func_set_link(i, str_intern(istr_get(fi_name(i)) + "@" + lib_name(owner) + "#fn" + int_str(i)))
        i = i + 1

fn find_decl_fn_sym(name_idx: int, owner: int) -> int:
    i : ., mut = g_sym_count - 1
    loop:
        if i < 0:
            return -1
        if sym_name(i) == name_idx && sym_kind(i) == SYM_FN && sym_owner_field(i) == owner:
            return i
        i = i - 1
    return -1

fn collect_decls():
    saved_lib := g_cur_lib
    i : ., mut = 0
    assign_unique_struct_names()
    assign_unique_enum_names()
    assign_unique_iface_names()
    assign_unique_alias_names()
    remap_method_type_keys()
    // First: register all struct types
    loop:
        if i >= g_struct_count:
            break
        unique_name := si_name(i)
        src_name := decl_src_for_unique(unique_name)
        type_idx := alloc_named_type(unique_name)
        def_type_sym(src_name, type_idx, si_decl_line(i))
        decl_set_type_ti(src_name, DECL_STRUCT, lib_of_line(si_decl_line(i)), type_idx)
        i = i + 1
    // Resolve struct field types now that all struct names are registered
    i = 0
    loop:
        if i >= g_struct_count:
            break
        j : ., mut = 0
        loop:
            if j >= si_field_count(i):
                break
            // Field types were stored by parser as unpack_type() results (TY_* or 0)
            // We need to resolve them — but they're stored as ints, not nodes.
            // For now, leave as-is; fields are resolved during type inference.
            j = j + 1
        i = i + 1
    // Register struct generic params for type resolution
    i = 0
    loop:
        if i >= g_struct_count:
            break
        gc := si_generic_count(i)
        if gc > 0:
            gj : ., mut = 0
            loop:
                if gj >= gc:
                    break
                gname_ni := si_generic_name(i, gj)
                g_ti := alloc_type(TYP_GENERIC_PARAM, gname_ni, 0)
                grow_gen_params(g_gen_param_count + 2)
                cell_store(g_gen_params, g_gen_param_count * 8, gname_ni)
                cell_store(g_gen_params, (g_gen_param_count + 1) * 8, g_ti)
                g_gen_param_count = g_gen_param_count + 2
                def_sym(gname_ni, SYM_TYPE, g_ti, -1)
                gj = gj + 1
        i = i + 1
    // Register all interface types
    i = 0
    loop:
        if i >= g_iface_count:
            break
        unique_name := cell_load(g_ifaces, i * ESZ_IFACEINFO + OFF_IF_NAME)
        src_name := decl_src_for_unique(unique_name)
        type_idx := alloc_named_type(unique_name)
        iface_line := cell_load(g_ifaces, i * ESZ_IFACEINFO + OFF_IF_DECL_LINE)
        def_type_sym(src_name, type_idx, iface_line)
        decl_set_type_ti(src_name, DECL_IFACE, lib_of_line(iface_line), type_idx)
        i = i + 1
    // Built-in Option registration is not present. No named type called Option is
    // registered automatically. T? is parsed as EXPR_OPTIONAL, which maps to
    // TYP_OPTIONAL and directly represents T union null.
    // 名字路径会把可选绑在一个用户可重名的标识符上；用户声明 enum Option 时，T? 的含义
    // 会随之改变。退役后 Option 不是语言内建名，用户声明 enum Option 按普通枚举解析。
    // Some 和 None 由 EXPR_ENUM_CONSTRUCTOR 按关键字给 TYP_OPTIONAL 或 TYP_NULL 行，
    // 不依赖该注册。EXPR_TRY 也改为按类型项结构解包，不再比较 Option 或 Result 名字。

    // Register all enum types and their variant constructors
    i = 0
    loop:
        if i >= g_enum_count:
            break
        unique_name := ei_name(i)
        src_name := decl_src_for_unique(unique_name)
        type_idx := alloc_named_type(unique_name)
        def_type_sym(src_name, type_idx, ei_decl_line(i))
        decl_set_type_ti(src_name, DECL_ENUM, lib_of_line(ei_decl_line(i)), type_idx)
        // Register each variant as a function returning the enum type
        vi : ., mut = 0
        loop:
            if vi >= ei_variant_count(i):
                break
            vname_idx := ei_variant_name(i, vi)
            def_decl_variant_sym(vname_idx, type_idx, src_name, ei_decl_line(i))
            vi = vi + 1
        i = i + 1

    // Register enum generic params for type resolution
    i = 0
    loop:
        if i >= g_enum_count:
            break
        gc := ei_generic_count(i)
        if gc > 0:
            gj : ., mut = 0
            loop:
                if gj >= gc:
                    break
                gname_ni := ei_generic_name(i, gj)
                g_ti := alloc_type(TYP_GENERIC_PARAM, gname_ni, 0)
                grow_gen_params(g_gen_param_count + 2)
                cell_store(g_gen_params, g_gen_param_count * 8, gname_ni)
                cell_store(g_gen_params, (g_gen_param_count + 1) * 8, g_ti)
                g_gen_param_count = g_gen_param_count + 2
                def_sym(gname_ni, SYM_TYPE, g_ti, -1)
                gj = gj + 1
        i = i + 1

    // Register type aliases
    i = 0
    loop:
        if i >= g_type_alias_count:
            break
        unique_name := cell_load(g_type_aliases, i * ESZ_TYPE_ALIAS)
        src_name := decl_src_for_unique(unique_name)
        type_node := cell_load(g_type_aliases, i * ESZ_TYPE_ALIAS + OFF_TA_TYPE)
        alias_line := cell_load(g_type_aliases, i * ESZ_TYPE_ALIAS + OFF_TA_LINE)
        g_cur_lib = lib_of_line(alias_line)
        ti := res_type_node(type_node)
        def_type_sym(src_name, ti, alias_line)
        decl_set_type_ti(src_name, DECL_ALIAS, g_cur_lib, ti)
        i = i + 1

    bind_bare_generic_params()

    // Register all functions. Library visibility is always enforced: same
    // library declarations are visible, cross-library ones require `pub`.
    i = 0
    loop:
        if i >= g_func_count:
            break
        name_idx := fi_name(i)
        fn_node := fi_ast_node(i)
        g_cur_lib = lib_of_node(fn_node)
        hotpatch_ver := (ast_int_val(fn_node) % 65536) / 256
        rt := fi_return_type(i)
        rt_ti : ., mut = TI_UNIT
        // For generic functions, skip return type resolution (depends on call site)
        if fi_generic_count(i) > 0:
            rt_ti = TI_UNIT
            // Register function generic params for type resolution
            gj : ., mut = 0
            loop:
                if gj >= fi_generic_count(i):
                    break
                gname_ni := fi_generic_name(i, gj)
                g_ti := alloc_type(TYP_GENERIC_PARAM, gname_ni, 0)
                grow_gen_params(g_gen_param_count + 2)
                cell_store(g_gen_params, g_gen_param_count * 8, gname_ni)
                cell_store(g_gen_params, (g_gen_param_count + 1) * 8, g_ti)
                g_gen_param_count = g_gen_param_count + 2
                def_sym(gname_ni, SYM_TYPE, g_ti, -1)
                gj = gj + 1
        else:
            type_node := ast_type_val(fn_node)
            if type_node > 0 && ast_kind(type_node) != 0:
                rt_ti = res_type_node(type_node)
            else:
                // 值经单表 `ty_code_to_ti`；本站点域 = 现有映射表 {INT,DEX,BOOL,STRING,UNIT}
                //  （无 CHAR/NEVER/7，因此三者与域外码一律保留 `rt_ti` 初值 TI_UNIT，域差异逐站保留，
                //  不得按表 + 尾回落一刀切：站点域差异是携带值的。例如 fn f() -> char 的
                //  非泛型符号类型是 unit，extern 站点同形是 char。
                // CHAR is a first-class scalar row: keep it so the symbol type
                // agrees with check_func's return row and with `-> char` bodies.
                // NEVER stays clamped here; the direct-call path re-reads the raw
                // code for `fn` declarations (E-11) and extern never remains unit
                // by design (pinned by test_iface_ops t6_S3).
                rt_mapped := ty_code_to_ti(rt)
                if rt_mapped >= 0 && rt_mapped != TI_NEVER && rt_mapped != TI_DYN:
                    rt_ti = rt_mapped
        if hotpatch_ver > 0:
            // @hotpatch function: register with mangled name fn_name.vN
            fn_name_str := istr_get(name_idx)
            mangled_name := fn_name_str + ".v" + int_str(hotpatch_ver)
            mangled_ni := str_intern(mangled_name)
            def_decl_fn_sym(mangled_ni, rt_ti, fn_node)
            register_pub_export(mangled_ni, fn_node)

            // Verify signature matches the first version
            fj : ., mut = 0
            loop:
                if fj >= i:
                    break
                if fi_name(fj) == name_idx:
                    first_fn := fi_ast_node(fj)
                    first_rt := fi_return_type(fj)
                    first_rt_ti : ., mut = TI_UNIT
                    type_node2 := ast_type_val(first_fn)
                    if type_node2 > 0 && ast_kind(type_node2) != 0:
                        first_rt_ti = res_type_node(type_node2)
                    else:
                        // 同上一处（本站点 = hotpatch 首版返回，域与上一处逐字相同）
                        first_mapped := ty_code_to_ti(first_rt)
                        if first_mapped >= 0 && first_mapped != TI_NEVER && first_mapped != TI_DYN:
                            first_rt_ti = first_mapped

                    // 本站两侧皆声明（无源/目标之分），因此长度约束走对称核（= 现状语义）
                    compat := type_compat_sym(rt_ti, first_rt_ti)
                    if compat != 1:
                        diag_type_incompatible(compat, EC_TF_RETURN, "Hotpatch return type mismatch for '" + fn_name_str + "'", ast_line(fn_node), ast_col(fn_node))
                    first_pc := fi_param_count(fj)
                    cur_pc := fi_param_count(i)
                    if first_pc != cur_pc:
                        check_error(EC_N_DUPLICATE, "Hotpatch parameter count mismatch for '" + fn_name_str + "'", ast_line(fn_node), ast_col(fn_node))
                    break
                fj = fj + 1

            // Also register original name for call resolution (latest version wins)
            def_decl_fn_sym(name_idx, rt_ti, fn_node)
            register_pub_export(name_idx, fn_node)
        else:
            // Normal function: duplicates are a same-library error. Cross-library
            // same-name declarations are distinguished by their link names.
            existing_si := find_decl_fn_sym(name_idx, lib_of_node(fn_node))
            if existing_si >= 0 && sym_kind(existing_si) == SYM_FN:
                existing_node := sym_node(existing_si)
                existing_is_hotpatch : ., mut = 0
                if existing_node >= 0 && ast_kind(existing_node) == EXPR_FN:
                    existing_is_hotpatch = (ast_int_val(existing_node) % 65536) / 256
                if existing_is_hotpatch == 0:
                    fn_name_str := istr_get(name_idx)
                    check_error(EC_N_DUPLICATE, "Duplicate function definition '" + fn_name_str + "'", ast_line(fn_node), ast_col(fn_node))
            def_decl_fn_sym(name_idx, rt_ti, fn_node)
            register_pub_export(name_idx, fn_node)
        fi_set_ispure(i, 1)  // optimistic: all functions are pure
        i = i + 1
    // Register extern function declarations (EXPR_EXTERN nodes not yet in g_funcs)
    ei : ., mut = 0
    loop:
        if ei >= g_ast_count:
            break
        if ast_kind(ei) == EXPR_EXTERN:
            g_cur_lib = lib_of_node(ei)
            name_ni := ast_a(ei)
            first_param := ast_b(ei)
            param_count := ast_c(ei)
            ret_type := ast_type_val(ei)

            // Resolve return type to type index
            // 值经单表 `ty_code_to_ti`；本站点域 = {INT,DEX,BOOL,STRING,UNIT,CHAR}
            //  （含 CHAR，缺 NEVER 和 7；与上方 hotpatch 注册站点的域不同且携带值：
            //  extern fn f() -> char 的符号类型是 char，而非 extern 同形是 unit）
            rt_ti : ., mut = TI_UNIT
            ext_mapped := ty_code_to_ti(ret_type)
            if ext_mapped >= 0 && ext_mapped != TI_NEVER && ext_mapped != TI_DYN:
                rt_ti = ext_mapped

            // Register in symbol table (skip if duplicate)
            if find_gsym(name_ni) < 0:
                def_decl_fn_sym(name_ni, rt_ti, ei)
                register_pub_export(name_ni, ei)

            // Register in g_funcs for backend codegen and linking
            func_idx := g_func_count
            grow_funcs(func_idx + 1)
            fi_set_name(func_idx, name_ni)
            func_set_link(func_idx, name_ni)
            fi_set_param_count(func_idx, param_count)
            fi_set_return_type(func_idx, ret_type)
            fi_set_ast_node(func_idx, ei)
            fi_set_generic_count(func_idx, 0)
            fi_set_ispure(func_idx, 1)  // optimistic: extern functions are pure
            g_func_count = func_idx + 1
        ei = ei + 1
    // Register all global variables
    i = 0
    loop:
        if i >= g_global_let_count:
            break
        node := cell_load(g_global_lets, i * 8)
        g_cur_lib = lib_of_node(node)
        name_idx := ast_a(node)  // EXPR_LET: a = name idx
        type_node := ast_b(node)  // EXPR_LET: b = type node (-1 if none)
        ti : ., mut = TI_UNIT
        if type_node >= 0:
            ti = res_type_node(type_node)
        def_decl_global_sym(name_idx, ti, node)
        i = i + 1
    // Register module aliases (from imports)
    mi : ., mut = 0
    loop:
        if mi >= g_mod_count:
            break
        alias_ni := cell_load(g_mods, mi * 24)
        fileid_ni := cell_load(g_mods, mi * 24 + 8)
        def_sym(alias_ni, SYM_MODULE, fileid_ni, -1)
        mi = mi + 1
    // Register mod path declarations (mod foo::bar;)
    pi : ., mut = 0
    loop:
        if pi >= g_mod_path_count:
            break
        mpn := cell_load(g_mod_path_names, pi * 8)
        def_sym(mpn, SYM_MODULE, mpn, -1)
        pi = pi + 1
    // Build module function lookup table for qualified access (e.g., mymath.add)
    main_fni : ., mut = 0
    if g_file_count > 0:
        main_fni = cell_load(g_files, 0)
    g_mod_func_count = 0
    g_mod_func_cap = 0
    fi : ., mut = 0
    loop:
        if fi >= g_func_count:
            break
        fn_node := fi_ast_node(fi)
        fn_line := ast_line(fn_node)
        if fn_line > 0 && fn_line <= g_line_count:
            fileid_ni := cell_load(g_line_fileid, (fn_line - 1) * 8)
            if fileid_ni >= 0 && fileid_ni != main_fni && fileid_ni != 0 && g_line_count > 0:
                grow_mod_funcs(g_mod_func_count + 1)
                cell_store(g_mod_func_fileids, g_mod_func_count * 8, fileid_ni)
                cell_store(g_mod_func_names, g_mod_func_count * 8, fi_name(fi))
                fn_si := find_sym(fi_name(fi))
                if fn_si >= 0:
                    cell_store(g_mod_func_tis, g_mod_func_count * 8, sym_type(fn_si))
                g_mod_func_count = g_mod_func_count + 1
        fi = fi + 1
    g_cur_lib = saved_lib

// --- Generic type inference helpers ---

fn is_func_generic(fi: int, name_idx: int) -> bool:
    if fi < 0 || fi >= g_func_count:
        return false
    gi : ., mut = 0
    loop:
        if gi >= fi_generic_count(fi):
            return false
        if cell_load(g_funcs, fi * ESZ_FUNCINFO + OFF_FI_GENERIC_NAMES + gi * 8) == name_idx:
            return true
        gi = gi + 1
    return false

fn find_func(name_idx: int) -> int:
    if g_cur_lib >= 0:
        i : ., mut = 0
        loop:
            if i >= g_func_count:
                break
            if fi_name(i) == name_idx && func_visible(i) != 0 && func_owner(i) == g_cur_lib:
                return i
            i = i + 1
    i : ., mut = 0
    loop:
        if i >= g_func_count:
            break
        if fi_name(i) == name_idx && func_visible(i) != 0:
            return i
        i = i + 1
    i = 0
    loop:
        if i >= g_func_count:
            return -1
        if func_link(i) == name_idx:
            return i
        i = i + 1
    return -1

// Unfiltered lookup for diagnostics: a method-table hit must be able to ask
// "does this method exist but belong to another library without pub?".
fn find_func_raw(name_idx: int) -> int:
    i : ., mut = 0
    loop:
        if i >= g_func_count:
            return -1
        if fi_name(i) == name_idx:
            return i
        i = i + 1
    return -1

// ─── 未完成项 12：struct 字面量的名字绑定 / 类型比对 辅助 ───

// 字段名 idx -> 声明下标（-1 = 该名字不在声明中）。名字 idx 来自 parser 写入的 wrapper.b
// （EXPR_STRUCT 契约，见 ast.cr / parser.cr struct 字面量分支）。
fn struct_field_index_by_name(si: int, name_ni: int) -> int:
    if si < 0 || name_ni < 0:
        return -1
    j : ., mut = 0
    loop:
        if j >= si_field_count(si):
            return -1
        if si_field_name(si, j) == name_ni:
            return j
        j = j + 1
    return -1

// Recursively replace struct generic-parameter rows with the concrete arguments
// supplied by a TYP_GENERIC_APPLY scrutinee. Unknown/absent arguments stay as
// TYP_GENERIC_PARAM so the caller can reject/fail closed.
fn structpat_subst_ti(si: int, ti: int, scrut_ti: int) -> int:
    k := get_type_kind(ti)
    if k < 0:
        return ti
    if k == TYP_GENERIC_PARAM:
        pni := get_type_data(ti)
        if get_type_kind(scrut_ti) == TYP_GENERIC_APPLY:
            ga_start := get_type_extra(scrut_ti)
            ga_count := cell_load(g_gen_apply_data, ga_start * 8)
            gpi : ., mut = 0
            loop:
                if gpi >= si_generic_count(si):
                    break
                if si_generic_name(si, gpi) == pni:
                    if gpi < ga_count:
                        return cell_load(g_gen_apply_data, (ga_start + 1 + gpi) * 8)
                    break
                gpi = gpi + 1
        return ti
    if k == TYP_ARRAY:
        return alloc_type(TYP_ARRAY, structpat_subst_ti(si, get_type_data(ti), scrut_ti), get_type_extra(ti))
    if k == TYP_SLICE:
        return alloc_type(TYP_SLICE, structpat_subst_ti(si, get_type_data(ti), scrut_ti), 0)
    if k == TYP_PTR:
        return alloc_type(TYP_PTR, structpat_subst_ti(si, get_type_data(ti), scrut_ti), get_type_extra(ti))
    if k == TYP_REF:
        return alloc_type(TYP_REF, structpat_subst_ti(si, get_type_data(ti), scrut_ti), get_type_extra(ti))
    if k == TYP_OPTIONAL:
        return alloc_type(TYP_OPTIONAL, structpat_subst_ti(si, get_type_data(ti), scrut_ti), 0)
    if k == TYP_TUPLE:
        cnt := get_type_data(ti)
        st := get_type_extra(ti)
        subs : string, mut
        if cnt > 0:
            subs = alloc(cnt * 8)
            i : ., mut = 0
            loop:
                if i >= cnt:
                    break
                cell_store(subs, i * 8, structpat_subst_ti(si, cell_load(g_gen_apply_data, (st + i) * 8), scrut_ti))
                i = i + 1
        ns := g_gen_apply_data_count
        grow_gen_apply_data(ns + cnt)
        i2 : ., mut = 0
        loop:
            if i2 >= cnt:
                break
            cell_store(g_gen_apply_data, (ns + i2) * 8, cell_load(subs, i2 * 8))
            i2 = i2 + 1
        g_gen_apply_data_count = ns + cnt
        return alloc_type(TYP_TUPLE, cnt, ns)
    if k == TYP_GENERIC_APPLY:
        st2 := get_type_extra(ti)
        cnt2 := cell_load(g_gen_apply_data, st2 * 8)
        subs2 : string, mut
        if cnt2 > 0:
            subs2 = alloc(cnt2 * 8)
            i3 : ., mut = 0
            loop:
                if i3 >= cnt2:
                    break
                cell_store(subs2, i3 * 8, structpat_subst_ti(si, cell_load(g_gen_apply_data, (st2 + 1 + i3) * 8), scrut_ti))
                i3 = i3 + 1
        ns2 := g_gen_apply_data_count
        grow_gen_apply_data(ns2 + 1 + cnt2)
        cell_store(g_gen_apply_data, ns2 * 8, cnt2)
        i4 : ., mut = 0
        loop:
            if i4 >= cnt2:
                break
            cell_store(g_gen_apply_data, (ns2 + 1 + i4) * 8, cell_load(subs2, i4 * 8))
            i4 = i4 + 1
        g_gen_apply_data_count = ns2 + 1 + cnt2
        return alloc_type(TYP_GENERIC_APPLY, get_type_data(ti), ns2)
    return ti

// Resolve a struct field type for a pattern scrutinee. Concrete fields are
// returned unchanged; generic fields are substituted structurally (including
// optional, array, tuple, and nested generic applications). The caller rejects
// any remaining generic row for non-`_` subpatterns.
fn structpat_field_ti(si: int, jdi: int, scrut_ti: int) -> int:
    if si < 0 || jdi < 0:
        return -1
    ft : ., mut = res_type_node(si_field_type_node(si, jdi))
    if ft < 0:
        return -1
    if ti_has_generic_param(ft) == 0:
        return ft
    return structpat_subst_ti(si, ft, scrut_ti)

// ─── Enum payload sub-patterns ───
// Validate literal/composite sub-patterns of an enum variant pattern against the
// variant's declared payload types. Nested enum patterns recurse; struct/tuple
// patterns are fully validated by their own checkers. Unsupported/unknown shapes
// are rejected with TM09 (fail closed) instead of matching only the outer tag.
// Malformed/foreign variant names are left to the coverage logic (which reports
// the variant mismatch); this function returns 0 for them.
fn check_enum_payload_patterns(match_ti: int, pat: int) -> int:
    if pat < 0 || ast_kind(pat) != EXPR_ENUMPAT:
        return 0
    c := ast_c(pat)
    if c <= 0:
        return 0
    ea := find_enum_row_of(match_ti)
    vi : ., mut = -1
    if ea >= 0:
        vi = sh_match_pat_variant(match_ti, pat)
    opt_inner : ., mut = -1
    if vi < 0 && get_type_kind(match_ti) == TYP_OPTIONAL:
        if sh_match_opt_pat(match_ti, pat) == 0:
            opt_inner = get_type_data(match_ti)
    if vi < 0 && opt_inner < 0:
        return 0
    vcount : ., mut = 0
    if vi >= 0:
        vcount = ei_variant_type_count(ea, vi)
    else:
        vcount = 1
    bad : ., mut = 0
    i : ., mut = 0
    loop:
        if i >= c:
            return bad
        sub : ., mut = sh_match_payload_root(pat, i)
        if sub < 0:
            check_error(EC_TM_NESTED,
                "Nested match patterns are not supported yet",
                ast_line(pat), ast_col(pat))
            return 1
        k := ast_kind(sub)
        if k == EXPR_IDENT || k == EXPR_WILDCARD:
            i = i + 1
            continue
        ft : ., mut = -1
        if i < vcount:
            if vi >= 0:
                tn := ei_variant_type_node(ea, vi, i)
                if tn >= 0:
                    ft = res_type_node(tn)
            else:
                ft = opt_inner
        if ft < 0:
            check_error(EC_TS_FIELD_TYPE,
                "Match pattern has more payload sub-patterns than the variant declares",
                ast_line(sub), ast_col(sub))
            bad = 1
            i = i + 1
            continue
        if ti_has_generic_param(ft) != 0:
            check_error(EC_TS_FIELD_TYPE,
                "Enum payload has an unresolved generic type; use a wildcard or binding arm",
                ast_line(sub), ast_col(sub))
            bad = 1
            i = i + 1
            continue
        if opt_inner >= 0 && (k == EXPR_STRUCTPAT || k == EXPR_TUPLEPAT || k == EXPR_ENUMPAT):
            // Nested optional payloads still need representation-aware lowering;
            // keep composite sub-patterns rejected until that path exists.
            check_error(EC_TM_NESTED,
                "Nested match patterns are not supported yet",
                ast_line(sub), ast_col(sub))
            bad = 1
        else if k == EXPR_STRUCTPAT:
            if check_struct_pattern(sub, ft) != 0:
                bad = 1
        else if k == EXPR_TUPLEPAT:
            if check_tuple_pattern(sub, ft) != 0:
                bad = 1
        else if k == EXPR_ENUMPAT:
            if find_enum_row_of(ft) < 0:
                check_error(EC_TS_FIELD_TYPE,
                    "Nested enum pattern requires an enum payload, got " + type_display(ft),
                    ast_line(sub), ast_col(sub))
                bad = 1
            else if check_enum_payload_patterns(ft, sub) != 0:
                bad = 1
        else if k == EXPR_INT || k == EXPR_BOOL || k == EXPR_CHAR || k == EXPR_STRING:
            if get_type_kind(ft) == TYP_OPTIONAL:
                check_error(EC_TS_FIELD_TYPE,
                    "Enum payload has an optional type; use a wildcard or binding arm",
                    ast_line(sub), ast_col(sub))
                bad = 1
            else:
                st := infer_expr(sub)
                verdict := type_compat_strict(st, ft)
                if verdict != 1:
                    diag_type_incompatible(verdict, EC_TS_FIELD_TYPE,
                        "Enum payload pattern: expected " + type_display(ft) + ", got " + type_display(st),
                        ast_line(sub), ast_col(sub))
                    bad = 1
        else:
            check_error(EC_TM_NESTED,
                "Nested match patterns are not supported yet",
                ast_line(sub), ast_col(sub))
            bad = 1
        i = i + 1
    return bad

// ─── Struct match pattern（Task 5b1）───
// EXPR_STRUCTPAT layout: a = struct name ni, b = first wrapper, c = field count.
// wrapper.a = subpattern, wrapper.b = field name ni. Validate the pattern against
// the struct row: unknown type/field, duplicate field, and literal field type
// mismatches are hard diagnostics. Nested struct/enum/tuple subpatterns are
// rejected with TM09 rather than silently treated as irrefutable. Returns
// 0 when the pattern is usable, 1 when a diagnostic was reported.
fn check_struct_pattern(pat: int, scrut_ti: int) -> int:
    if pat < 0:
        return 1
    name_ni := ast_a(pat)
    si := find_struct_by_name(name_ni)
    if si < 0:
        check_error(EC_N_UNDEFINED,
            "Unknown struct type '" + istr_get(name_ni) + "' in struct pattern",
            ast_line(pat), ast_col(pat))
        return 1
    // A struct pattern needs a concrete scrutinee shape. An unresolved generic
    // parameter could later instantiate to a different struct (or a non-struct),
    // and monomorphization would then emit field loads against the wrong object.
    // Reject it here; callers must use a concrete struct type or `_`/binding.
    if ti_has_generic_param(scrut_ti) != 0:
        check_error(EC_TS_FIELD_TYPE,
            "Struct pattern '" + istr_get(name_ni) + "' requires a concrete struct type; use a wildcard or binding arm",
            ast_line(pat), ast_col(pat))
        return 1
    // Generic field types cannot be validated/bound soundly unless the scrutinee
    // supplies concrete generic arguments. The per-field loop below substitutes
    // direct generic parameters from the scrutinee and rejects remaining generic
    // forms (except `_`, which performs no comparison or binding).
    // The scrutinee must be this struct whenever its shape is statically known.
    sk := get_type_kind(scrut_ti)
    if sk == TYP_NAMED || sk == TYP_GENERIC_APPLY:
        sni := decl_name_of_ti(scrut_ti)
        if sni >= 0 && sni != name_ni:
            check_error(EC_TS_FIELD_TYPE,
                "Struct pattern '" + istr_get(name_ni) + "' does not match scrutinee type '" + istr_get(sni) + "'",
                ast_line(pat), ast_col(pat))
            return 1
    else if sk != TYP_GENERIC_PARAM:
        check_error(EC_TS_FIELD_TYPE,
            "Struct pattern '" + istr_get(name_ni) + "' requires a struct scrutinee",
            ast_line(pat), ast_col(pat))
        return 1
    c := ast_c(pat)
    w0 := ast_b(pat)
    if c > 0 && w0 < 0:
        return 1
    fc := si_field_count(si)
    used : string, mut = alloc((fc + 1) * 8)
    j : ., mut = 0
    loop:
        if j >= fc:
            break
        cell_store(used, j * 8, 0)
        j = j + 1
    bad : ., mut = 0
    i : ., mut = 0
    loop:
        if i >= c:
            return bad
        w := w0 + i
        sub : ., mut = -1
        fni : ., mut = -1
        if w >= 0:
            sub = ast_a(w)
            fni = ast_b(w)
        jdi := struct_field_index_by_name(si, fni)
        if jdi < 0:
            check_error(EC_TS_UNKNOWN_FIELD,
                "Unknown field '" + istr_get(fni) + "' in struct pattern " + istr_get(name_ni),
                ast_line(w), ast_col(w))
            bad = 1
            i = i + 1
            continue
        if cell_load(used, jdi * 8) != 0:
            check_error(EC_TS_FIELD_DUP,
                "Field '" + istr_get(fni) + "' matched more than once in struct pattern " + istr_get(name_ni),
                ast_line(w), ast_col(w))
            bad = 1
        cell_store(used, jdi * 8, 1)
        if sub >= 0:
            k := ast_kind(sub)
            if k == EXPR_IDENT || k == EXPR_WILDCARD || k == EXPR_INT || k == EXPR_BOOL || k == EXPR_CHAR || k == EXPR_STRING:
                ft := structpat_field_ti(si, jdi, scrut_ti)
                if ft >= 0:
                    // Cache the checker-resolved (already substituted) field type
                    // on the wrapper for IR gen and monomorph clones. +1 keeps 0
                    // as the "absent" sentinel because TI_INT itself is 0.
                    ast_set_data(w, ft + 1)
                if ti_has_generic_param(ft) != 0:
                    if k == EXPR_IDENT:
                        check_error(EC_TS_FIELD_TYPE,
                            "Field '" + istr_get(fni) + "' in struct pattern " + istr_get(name_ni) +
                            " has an unresolved generic type; use a wildcard",
                            ast_line(sub), ast_col(sub))
                        bad = 1
                    else if k != EXPR_WILDCARD:
                        check_error(EC_TS_FIELD_TYPE,
                            "Field '" + istr_get(fni) + "' in struct pattern " + istr_get(name_ni) +
                            " has an unresolved generic type; literal patterns are not supported",
                            ast_line(sub), ast_col(sub))
                        bad = 1
                else if k != EXPR_IDENT && k != EXPR_WILDCARD:
                    if get_type_kind(ft) == TYP_OPTIONAL:
                        check_error(EC_TS_FIELD_TYPE,
                            "Field '" + istr_get(fni) + "' in struct pattern " + istr_get(name_ni) +
                            " has an optional type; use a wildcard or binding arm",
                            ast_line(sub), ast_col(sub))
                        bad = 1
                    else:
                        st := infer_expr(sub)
                        verdict := type_compat_strict(st, ft)
                        if verdict != 1:
                            diag_type_incompatible(verdict, EC_TS_FIELD_TYPE,
                                "Field '" + istr_get(fni) + "' in struct pattern " + istr_get(name_ni) +
                                ": expected " + type_display(ft) + ", got " + type_display(st),
                                ast_line(sub), ast_col(sub))
                            bad = 1
            else:
                ft : ., mut = structpat_field_ti(si, jdi, scrut_ti)
                if ft >= 0:
                    ast_set_data(w, ft + 1)
                if k == EXPR_STRUCTPAT:
                    if check_struct_pattern(sub, ft) != 0:
                        bad = 1
                else if k == EXPR_TUPLEPAT:
                    if check_tuple_pattern(sub, ft) != 0:
                        bad = 1
                else if k == EXPR_ENUMPAT:
                    if find_enum_row_of(ft) < 0:
                        check_error(EC_TS_FIELD_TYPE,
                            "Field '" + istr_get(fni) + "' in struct pattern " + istr_get(name_ni) +
                            " is not an enum; nested enum pattern is not valid",
                            ast_line(sub), ast_col(sub))
                        bad = 1
                    else if check_enum_payload_patterns(ft, sub) != 0:
                        bad = 1
                else:
                    check_error(EC_TM_NESTED,
                        "Nested match patterns are not supported yet",
                        ast_line(sub), ast_col(sub))
                    bad = 1
        i = i + 1
    return bad

// Bind ident subpatterns inside an enum payload. Each binding gets the declared
// payload type; composite sub-patterns recurse. Foreign variants are ignored
// (coverage already diagnosed them).
fn bind_enum_pattern_idents(pat: int, scrut_ti: int):
    if pat < 0:
        return
    c := ast_c(pat)
    if c <= 0:
        return
    ea := find_enum_row_of(scrut_ti)
    vi : ., mut = -1
    if ea >= 0:
        vi = sh_match_pat_variant(scrut_ti, pat)
    opt_inner : ., mut = -1
    if vi < 0 && get_type_kind(scrut_ti) == TYP_OPTIONAL:
        if sh_match_opt_pat(scrut_ti, pat) == 0:
            opt_inner = get_type_data(scrut_ti)
    // 无法解析枚举/可选行时仍绑定顶层 ident（旧行为）：scrutinee 类型可能因
    // 别的错误（如切片下标 TK01）不可用，但绑定臂体不应额外制造 N01。
    resolved : ., mut = 1
    if vi < 0 && opt_inner < 0:
        resolved = 0
    i : ., mut = 0
    loop:
        if i >= c:
            break
        sub := sh_match_payload_root(pat, i)
        if sub < 0:
            break
        ft : ., mut = -1
        if resolved == 0:
            ft = TI_INT
        else if vi >= 0:
            tn := ei_variant_type_node(ea, vi, i)
            if tn >= 0:
                ft = res_type_node(tn)
        else:
            ft = opt_inner
        k := ast_kind(sub)
        if k == EXPR_IDENT:
            nn := ast_int_val(sub)
            if str_eq(istr_get(nn), "_") == 0:
                def_sym(nn, SYM_LOCAL, ft, -1)
        else if k == EXPR_STRUCTPAT:
            bind_struct_pattern_idents(sub, ft)
        else if k == EXPR_TUPLEPAT:
            bind_tuple_pattern_idents(sub, ft)
        else if k == EXPR_ENUMPAT:
            bind_enum_pattern_idents(sub, ft)
        i = i + 1

// Bind the ident subpatterns of a validated struct pattern. Each binding gets
// the declared type of its field. `_` and literal subpatterns bind nothing.
fn bind_struct_pattern_idents(pat: int, scrut_ti: int):
    if pat < 0:
        return
    name_ni := ast_a(pat)
    si := find_struct_by_name(name_ni)
    c := ast_c(pat)
    w0 := ast_b(pat)
    if si < 0 || (c > 0 && w0 < 0):
        return
    i : ., mut = 0
    loop:
        if i >= c:
            break
        w := w0 + i
        if w >= 0:
            sub : ., mut = ast_a(w)
            if sub >= 0:
                jdi := struct_field_index_by_name(si, ast_b(w))
                ft : ., mut = TI_INT
                if jdi >= 0:
                    ft = structpat_field_ti(si, jdi, scrut_ti)
                k := ast_kind(sub)
                if k == EXPR_IDENT:
                    nn := ast_int_val(sub)
                    if str_eq(istr_get(nn), "_") == 0:
                        def_sym(nn, SYM_LOCAL, ft, -1)
                else if k == EXPR_STRUCTPAT:
                    bind_struct_pattern_idents(sub, ft)
                else if k == EXPR_TUPLEPAT:
                    bind_tuple_pattern_idents(sub, ft)
                else if k == EXPR_ENUMPAT:
                    bind_enum_pattern_idents(sub, ft)
        i = i + 1

// ─── Tuple match pattern（Task 5b2）───
// EXPR_TUPLEPAT layout: a = first wrapper, b = element count. wrapper.a =
// subpattern, wrapper.b = element index (0-based). The scrutinee must be a
// concrete TYP_TUPLE with the same arity. Each element is validated against the
// actual tuple element type (g_gen_apply_data at extra+i): scalar literals are
// compared strictly, ident/wildcard bind, and nested composite patterns are
// rejected with TM09 rather than silently treated as irrefutable. Returns 0 when
// the pattern is usable, 1 when a diagnostic was reported.
fn check_tuple_pattern(pat: int, scrut_ti: int) -> int:
    if pat < 0:
        return 1
    c := ast_b(pat)
    w0 := ast_a(pat)
    if c <= 0 || w0 < 0:
        check_error(EC_P_PATTERN, "Malformed tuple pattern",
            ast_line(pat), ast_col(pat))
        return 1
    if get_type_kind(scrut_ti) != TYP_TUPLE:
        check_error(EC_TS_FIELD_TYPE,
            "Tuple pattern requires a tuple scrutinee",
            ast_line(pat), ast_col(pat))
        return 1
    arity := get_type_data(scrut_ti)
    if c != arity:
        check_error(EC_TA_TUPLE_ARITY,
            "Tuple pattern has " + int_str(c) + " elements, but the scrutinee has " + int_str(arity),
            ast_line(pat), ast_col(pat))
        return 1
    // A generic element has no concrete load form at codegen time. Keep the same
    // conservative rule as struct patterns: require a fully concrete tuple.
    if ti_has_generic_param(scrut_ti) != 0:
        check_error(EC_TS_FIELD_TYPE,
            "Tuple pattern requires a concrete tuple type; use a wildcard or binding arm",
            ast_line(pat), ast_col(pat))
        return 1
    start := get_type_extra(scrut_ti)
    bad : ., mut = 0
    i : ., mut = 0
    loop:
        if i >= c:
            return bad
        w := w0 + i
        sub : ., mut = -1
        idx : ., mut = -1
        if w >= 0:
            sub = ast_a(w)
            idx = ast_b(w)
        if w < 0 || idx != i:
            check_error(EC_P_PATTERN, "Malformed tuple pattern element index",
                ast_line(pat), ast_col(pat))
            bad = 1
            i = i + 1
            continue
        ft : ., mut = -1
        if start >= 0:
            ft = cell_load(g_gen_apply_data, (start + i) * 8)
        if ft >= 0:
            // Cache the element type on the wrapper for IR lowering and monomorph
            // clones. +1 keeps 0 as the "absent" sentinel because TI_INT is 0.
            ast_set_data(w, ft + 1)
        if sub < 0:
            bad = 1
            i = i + 1
            continue
        k := ast_kind(sub)
        if k == EXPR_IDENT || k == EXPR_WILDCARD:
            i = i + 1
            continue
        if k == EXPR_INT || k == EXPR_BOOL || k == EXPR_CHAR || k == EXPR_STRING:
            if ft < 0:
                check_error(EC_TS_FIELD_TYPE,
                    "Tuple pattern element " + int_str(i) + " has no resolvable type",
                    ast_line(sub), ast_col(sub))
                bad = 1
            else if ti_has_generic_param(ft) != 0:
                check_error(EC_TS_FIELD_TYPE,
                    "Tuple pattern element " + int_str(i) + " has an unresolved generic type; literal patterns are not supported",
                    ast_line(sub), ast_col(sub))
                bad = 1
            else if get_type_kind(ft) == TYP_OPTIONAL:
                check_error(EC_TS_FIELD_TYPE,
                    "Tuple pattern element " + int_str(i) + " has an optional type; use a wildcard or binding arm",
                    ast_line(sub), ast_col(sub))
                bad = 1
            else:
                st := infer_expr(sub)
                verdict := type_compat_strict(st, ft)
                if verdict != 1:
                    diag_type_incompatible(verdict, EC_TS_FIELD_TYPE,
                        "Tuple pattern element " + int_str(i) + ": expected " + type_display(ft) + ", got " + type_display(st),
                        ast_line(sub), ast_col(sub))
                    bad = 1
        else:
            if k == EXPR_STRUCTPAT:
                if check_struct_pattern(sub, ft) != 0:
                    bad = 1
            else if k == EXPR_TUPLEPAT:
                if check_tuple_pattern(sub, ft) != 0:
                    bad = 1
            else if k == EXPR_ENUMPAT:
                if find_enum_row_of(ft) < 0:
                    check_error(EC_TS_FIELD_TYPE,
                        "Tuple pattern element " + int_str(i) + " is not an enum; nested enum pattern is not valid",
                        ast_line(sub), ast_col(sub))
                    bad = 1
                else if check_enum_payload_patterns(ft, sub) != 0:
                    bad = 1
            else:
                check_error(EC_TM_NESTED,
                    "Nested match patterns are not supported yet",
                    ast_line(sub), ast_col(sub))
                bad = 1
        i = i + 1
    return bad

// Bind the ident subpatterns of a validated tuple pattern. Each binding gets the
// actual tuple element type. `_` and literal subpatterns bind nothing.
fn bind_tuple_pattern_idents(pat: int, scrut_ti: int):
    if pat < 0 || get_type_kind(scrut_ti) != TYP_TUPLE:
        return
    c := ast_b(pat)
    w0 := ast_a(pat)
    arity := get_type_data(scrut_ti)
    start := get_type_extra(scrut_ti)
    if w0 < 0:
        return
    i : ., mut = 0
    loop:
        if i >= c:
            break
        w := w0 + i
        if w >= 0:
            sub := ast_a(w)
            if sub >= 0:
                et : ., mut = TI_INT
                if start >= 0 && i < arity:
                    et = cell_load(g_gen_apply_data, (start + i) * 8)
                k := ast_kind(sub)
                if k == EXPR_IDENT:
                    nn := ast_int_val(sub)
                    if str_eq(istr_get(nn), "_") == 0:
                        def_sym(nn, SYM_LOCAL, et, -1)
                else if k == EXPR_STRUCTPAT:
                    bind_struct_pattern_idents(sub, et)
                else if k == EXPR_TUPLEPAT:
                    bind_tuple_pattern_idents(sub, et)
                else if k == EXPR_ENUMPAT:
                    bind_enum_pattern_idents(sub, et)
        i = i + 1

// 类型里是否仍含未实例化的泛型参数（TYP_GENERIC_PARAM，可嵌套在数组 / 指针 / 引用 /
// 切片 / 元组 / 泛型应用内）。字面量的字段类型 vs 声明元素同质性判定在任一侧
// 含未实例化参数时跳过，参数未实例化时比较不成立，强行比较会假拒（泛型函数体
// `fn f[T](x: T) { p := P{a: 1, b: x}; }`：x 的类型是 T，与声明的 int 比较必假）。参数实例化
// 由 monomorph 负责，此判定不越权。
fn ti_has_generic_param(ti: int) -> int:
    k := get_type_kind(ti)
    if k < 0:
        return 0
    if k == TYP_GENERIC_PARAM:
        return 1
    if k == TYP_ARRAY || k == TYP_PTR || k == TYP_REF || k == TYP_SLICE:
        return ti_has_generic_param(get_type_data(ti))
    if k == TYP_OPTIONAL:
        return ti_has_generic_param(get_type_data(ti))
    if k == TYP_TUPLE:
        cnt := get_type_data(ti)
        st := get_type_extra(ti)
        i : ., mut = 0
        loop:
            if i >= cnt:
                break
            if ti_has_generic_param(cell_load(g_gen_apply_data, (st + i) * 8)) != 0:
                return 1
            i = i + 1
        return 0
    if k == TYP_GENERIC_APPLY:
        st := get_type_extra(ti)
        cnt := cell_load(g_gen_apply_data, st * 8)
        i : ., mut = 0
        loop:
            if i >= cnt:
                break
            if ti_has_generic_param(cell_load(g_gen_apply_data, (st + 1 + i) * 8)) != 0:
                return 1
            i = i + 1
        return 0
    return 0

// 字段声明类型节点是否提及本结构体的泛型参数（`T` / `[T; 3]` / `Box[T]` …）。提及 =
// 该字段的声明类型在字面量处无法静态解析：结构体泛型参数在字面量作用域不在名字表里，
// res_type_node 会把 `T` 误解析成名为 "T" 的具名类型 -> 与实参比较必假（假拒）。故这些字段
// 的类型比对跳过；参数本身走绑定路径（is_struct_generic 判定，见 EXPR_STRUCT 分支）。
fn type_node_mentions_struct_param(si: int, tn: int) -> int:
    if tn < 0 || si < 0:
        return 0
    k := ast_kind(tn)
    if k == EXPR_IDENT:
        if is_struct_generic(si, ast_int_val(tn)):
            return 1
        return 0
    if k == EXPR_ARRAY || k == EXPR_REFTYPE || k == EXPR_PTRTYPE || k == EXPR_OPTIONAL:
        // EXPR_OPTIONAL：内层提及形参（`T?` 字段），因此同上跳过字面量处的静态比对。
        return type_node_mentions_struct_param(si, ast_a(tn))
    if k == EXPR_GENERIC_APPLY:
        if is_struct_generic(si, ast_a(tn)):
            return 1
        cnt := ast_c(tn)
        an : ., mut = ast_b(tn)
        i : ., mut = 0
        loop:
            if i >= cnt:
                break
            if an >= 0:
                if type_node_mentions_struct_param(si, an) != 0:
                    return 1
            an = an + 1
            i = i + 1
        return 0
    return 0

// 类型展示名（诊断措辞用）：具名/基型/泛型应用基名走 get_type_name，其余构造子递归拼装。
// 未识别 -> "?"（不伪造名字）。
fn type_display(ti: int) -> string:
    k := get_type_kind(ti)
    // 泛型应用先于 get_type_name 捷径处理：后者对
    // TYP_GENERIC_APPLY 只返回基名，因此实参全丢（expected Box, got Box，
    // 真正不匹配的那个类型实参恰是读者最需要的），且使本函数下方的实参分支
    // 成死码。此处展开成 `Box[int]` / `Pair[Box[int], string]` 形式。
    if k == TYP_GENERIC_APPLY:
        base := get_type_data(ti)
        s : string, mut
        s = type_display(base)
        s = s + "["
        start := get_type_extra(ti)
        cnt : ., mut = cell_load(g_gen_apply_data, start * 8)
        i : ., mut = 0
        loop:
            if i >= cnt:
                break
            if i > 0:
                s = s + ", "
            s = s + type_display(cell_load(g_gen_apply_data, (start + 1 + i) * 8))
            i = i + 1
        s = s + "]"
        return s
    ni := get_type_name(ti)
    if ni >= 0:
        return istr_get(ni)
    if k == TYP_ARRAY:
        return "[" + type_display(get_type_data(ti)) + "; " + int_str(get_type_extra(ti)) + "]"
    if k == TYP_SLICE:
        return "[" + type_display(get_type_data(ti)) + "]"
    if k == TYP_PTR:
        return "*" + type_display(get_type_data(ti))
    if k == TYP_REF:
        return "&" + type_display(get_type_data(ti))
    if k == TYP_GENERIC_PARAM:
        return istr_get(decl_src_for_unique(get_type_data(ti)))
    if k == TYP_DYN:
        return "dyn"
    // `T?` 显示为 `T?`、null 单点类型显示为 "null"（诊断措辞；未识别仍 "?"）
    if k == TYP_OPTIONAL:
        return type_display(get_type_data(ti)) + "?"
    if k == TYP_NULL:
        return "null"
    return "?"

fn is_struct_generic(si: int, name_idx: int) -> bool:
    if si < 0 || si >= g_struct_count:
        return false
    gi : ., mut = 0
    loop:
        if gi >= si_generic_count(si):
            return false
        if si_generic_name(si, gi) == name_idx:
            return true
        gi = gi + 1
    return false

fn find_struct_by_name(name_idx: int) -> int:
    if g_cur_lib < 0:
        return find_struct(name_idx)
    rec := decl_map_find_unique(name_idx)
    if rec >= 0:
        if cell_load(g_decl_map, rec * 40 + 8) == DECL_STRUCT && cell_load(g_decl_map, rec * 40) != name_idx:
            return find_struct(name_idx)
    si := find_gsym(name_idx)
    if si < 0 || sym_kind(si) != SYM_TYPE:
        if g_cur_lib < 0:
            return find_struct(name_idx)
        return -1
    ti := sym_type(si)
    if ti >= 0 && ti < g_type_count && get_type_kind(ti) == TYP_NAMED:
        return find_struct(get_type_data(ti))
    if g_cur_lib < 0:
        return find_struct(name_idx)
    return -1

fn res_call_type(node: int, func_fi: int) -> int:
    // Resolve a type node for call inference, treating generic params as TYP_GENERIC_PARAM
    if node < 0:
        return TI_UNIT
    if ast_kind(node) == 0:
        // 单表 ty_code_to_ti。本站点与 res_type_node 的唯一差别是 NEVER：ty_code_to_ti 没有
        // TY_NEVER 分支时落到 TI_UNIT。该差异显式保留：never 在调用位点按 unit 处理。
        tv := ast_type_val(node)
        mapped : ., mut = ty_code_to_ti(tv)
        if mapped < 0 || tv == TY_NEVER:
            mapped = TI_UNIT
        return mapped
    if ast_kind(node) == EXPR_IDENT:
        name_idx := ast_int_val(node)
        if is_func_generic(func_fi, name_idx):
            return alloc_type(TYP_GENERIC_PARAM, name_idx, 0)
        // Regular named type
        si := find_gsym(name_idx)
        if si >= 0 && sym_kind(si) == SYM_TYPE:
            return sym_type(si)
        return alloc_named_type(name_idx)
    if ast_kind(node) == EXPR_GENERIC_APPLY:
        name_idx := ast_a(node)
        first_an := ast_b(node)
        ac := ast_c(node)
        si := find_gsym(name_idx)
        if si < 0 || sym_kind(si) != SYM_TYPE:
            return TI_UNIT
        base_ti := sym_type(si)
        // 两趟（同 res_type_node 的泛型应用分支：实参解析会追加嵌套应用携带值）
        args : string, mut
        if ac > 0:
            args = alloc(ac * 8)
            ai : ., mut = 0
            an : ., mut = first_an
            loop:
                if ai >= ac:
                    break
                cell_store(args, ai * 8, res_call_type(an, func_fi))
                ai = ai + 1
                an = an + 1
        // 调用位点的实例化检查（与 res_type_node 同源；本节的存在理由
        // = 调用位点的类型语法（形参/返回/字段）两侧都要覆盖，见 res_call_type 头注的域差）。
        gen_inst_constr_check(node, find_struct(name_idx), find_enum(name_idx), args, ac)
        ds := g_gen_apply_data_count
        grow_gen_apply_data(ds + 1 + ac)
        cell_store(g_gen_apply_data, ds * 8, ac)
        ai2 : ., mut = 0
        loop:
            if ai2 >= ac:
                break
            cell_store(g_gen_apply_data, (ds + 1 + ai2) * 8, cell_load(args, ai2 * 8))
            ai2 = ai2 + 1
        g_gen_apply_data_count = ds + 1 + ac
        return alloc_type(TYP_GENERIC_APPLY, base_ti, ds)
    if ast_kind(node) == EXPR_REFTYPE:
        inner := res_call_type(ast_a(node), func_fi)
        mf := ast_int_val(node)
        return alloc_type(TYP_REF, inner, mf)
    if ast_kind(node) == EXPR_OPTIONAL:
        // `T?` 在调用位点的解析（与 res_type_node 同语义；本函数只多一条
        // 泛型形参分支的差异，见函数头注，optional 分支两侧一致）。
        inner := res_call_type(ast_a(node), func_fi)
        return alloc_type(TYP_OPTIONAL, inner, 0)
    return TI_UNIT

fn unify_types(pattern: int, concrete: int) -> bool:
    if pattern == concrete:
        return true
    pk := get_type_kind(pattern)
    ck := get_type_kind(concrete)
    if pk < 0 || ck < 0:
        return false
    // ─── T? 模式（TYP_OPTIONAL）分支 ───
    // T? 模式不能走通用后备路径，否则内层泛型参数不替换、不绑定，判定恒假。泛型调用中的 T?
    // 形参必须在这里绑定或校验；否则实例键会由其他实参决定，合法调用也会被判失败。
    // 可选目标的统一规则与 type_compat_strict 的可选目标分支一致：裸值可以进入 T?。
    //  1. concrete 也是 optional 时，内层对内层递归；
    //  2. 否则内层 pattern 对 concrete 递归。
    // 内层是泛型参数时，由下方 TYP_GENERIC_PARAM 分支绑定（未绑定）或比对（已绑定）。
    if pk == TYP_OPTIONAL:
        inner_p := get_type_data(pattern)
        if inner_p < 0:
            return false
        if ck == TYP_OPTIONAL:
            inner_c := get_type_data(concrete)
            if inner_c < 0:
                return false
            return unify_types(inner_p, inner_c)
        return unify_types(inner_p, concrete)
    if pk == TYP_GENERIC_PARAM:
        name_idx := get_type_data(pattern)
        mi : ., mut = 0
        loop:
            if mi >= g_gen_map_count:
                break
            if cell_load(g_gen_map_names, mi * 8) == name_idx:
                // 参序归一：源 = concrete（实参），目标 = 已绑定项
                return type_compat_strict(concrete, cell_load(g_gen_map_types, mi * 8)) == 1
            mi = mi + 1
        grow_gen_map(g_gen_map_count + 1)
        cell_store(g_gen_map_names, g_gen_map_count * 8, name_idx)
        cell_store(g_gen_map_types, g_gen_map_count * 8, concrete)
        g_gen_map_count = g_gen_map_count + 1
        return true
        return false
    if pk == TYP_GENERIC_APPLY && ck == TYP_GENERIC_APPLY:
        // 参序归一：源 = concrete 基型，目标 = pattern 基型（两侧恒 TYP_NAMED，因此方向规则不可达）
        if type_compat_strict(get_type_data(concrete), get_type_data(pattern)) != 1:
            return false
        ps := get_type_extra(pattern)
        cs := get_type_extra(concrete)
        pc := cell_load(g_gen_apply_data, ps * 8)
        cc := cell_load(g_gen_apply_data, cs * 8)
        if pc != cc:
            return false
        ai : ., mut = 0
        loop:
            if ai >= pc:
                break
            if !unify_types(cell_load(g_gen_apply_data, (ps + 1 + ai) * 8), cell_load(g_gen_apply_data, (cs + 1 + ai) * 8)):
                return false
            ai = ai + 1
        return true
    // 参序归一：源 = concrete（实参），目标 = pattern（声明）
    return type_compat_strict(concrete, pattern) == 1

fn substitute_return_type(ti: int) -> int:
    // Substitute generic params using g_gen_map
    if g_gen_map_count == 0:
        return ti
    k : ., mut = get_type_kind(ti)
    if k == TYP_GENERIC_PARAM:
        name_idx := get_type_data(ti)
        mi : ., mut = 0
        loop:
            if mi >= g_gen_map_count:
                break
            if cell_load(g_gen_map_names, mi * 8) == name_idx:
                return cell_load(g_gen_map_types, mi * 8)
            mi = mi + 1
        return ti
    if k == TYP_GENERIC_APPLY:
        base := get_type_data(ti)
        start : ., mut = get_type_extra(ti)
        count := cell_load(g_gen_apply_data, start * 8)
        // 两趟（同 res_type_node：递归代换会追加嵌套应用携带值，因此先算进暂存再认领块）
        subs : string, mut
        if count > 0:
            subs = alloc(count * 8)
            ai : ., mut = 0
            loop:
                if ai >= count:
                    break
                cell_store(subs, ai * 8, substitute_return_type(cell_load(g_gen_apply_data, (start + 1 + ai) * 8)))
                ai = ai + 1
        new_start := g_gen_apply_data_count
        grow_gen_apply_data(new_start + 1 + count)
        cell_store(g_gen_apply_data, new_start * 8, count)
        ai2 : ., mut = 0
        loop:
            if ai2 >= count:
                break
            cell_store(g_gen_apply_data, (new_start + 1 + ai2) * 8, cell_load(subs, ai2 * 8))
            ai2 = ai2 + 1
        g_gen_apply_data_count = new_start + 1 + count
        return alloc_type(TYP_GENERIC_APPLY, base, new_start)
    return ti

fn infer_gen_call(fi: int, call_node: int, first_arg: int, arg_count: int) -> int:
    return infer_gen_call_recv(fi, call_node, first_arg, arg_count, -1)

// `recv_ti >= 0` means this is a method call: the receiver is bound against the
// first parameter and the argument list starts at the second one. Direct calls
// pass -1 and keep the 1:1 mapping. Before this, a method on a generic struct
// had no binding at all (its argument list excludes the receiver), so the
// instance fell back to unit.
fn infer_gen_call_recv(fi: int, call_node: int, first_arg: int, arg_count: int, recv_ti: int) -> int:
    // Infer concrete types for a generic function call
    fn_node := fi_ast_node(fi)
    first_param := ast_b(fn_node)
    param_count := ast_c(fn_node)
    ret_type_node := ast_type_val(fn_node)

    g_gen_map_count = 0
    g_gen_map_cap = 0

    // First pass: infer arg types and build mapping
    pi : ., mut = 0
    pn : ., mut = first_param
    an : ., mut = first_arg
    if recv_ti >= 0 && pn >= 0:
        orig_recv_node := ast_data(pn)
        if orig_recv_node >= 0:
            recv_pattern := res_call_type(orig_recv_node, fi)
            if !unify_types(recv_pattern, recv_ti):
                println("[S1-RECV] line=" + int_str(ast_line(call_node)) + " p=" + type_display(recv_pattern)
                    + " r=" + type_display(recv_ti))
        pn = pn + 1
        loop:
            if pn >= g_ast_count:
                pn = -1
                break
            if ast_kind(pn) == EXPR_PARAM:
                break
            pn = pn + 1
        pi = 1
    loop:
        if pi >= param_count || pi >= arg_count:
            break
        if pn < 0 || an < 0:
            break

        orig_type_node := ast_data(pn)  // original param type node

        if orig_type_node >= 0:
            pattern_ti := res_call_type(orig_type_node, fi)
            concrete_ti : ., mut = infer_expr(ast_a(an))
            // This path records the discarded result but does not block. It skips
            // two false-positive shapes: an integer literal passed to a numeric
            // parameter (literal polymorphism, where unify_types rejects int to dex
            // or int?), and an unresolved TI_UNIT form. Generic T to T and None to
            // T? are handled by unify_types. Method receiver offsets and variadic
            // arguments are out of scope. All decisions go through unify_types.
            s1_skip : ., mut = 0
            if ast_kind(ast_a(an)) == EXPR_INT:
                s1_skip = 1
            if concrete_ti == TI_UNIT:
                s1_skip = 1
            if !unify_types(pattern_ti, concrete_ti):
                if s1_skip == 0:
                    println("[S1-ARG] line=" + int_str(ast_line(ast_a(an))) + " col=" + int_str(ast_col(ast_a(an)))
                        + " pi=" + int_str(pi) + " p=" + type_display(pattern_ti)
                        + " a=" + type_display(concrete_ti))
        else:
            infer_expr(ast_a(an))

        pi = pi + 1
        // ─── 参数列表导航 ───
        // parser 先分配形参的类型节点，再分配形参节点，每个类型都占一个节点，因此
        // EXPR_PARAM 在 AST 中不连续，pn + 1 不一定是下一个形参。游标必须扫到下一个
        // EXPR_PARAM；否则会落到类型节点上，读出错误的声明类型。
        // 非泛型形参的声明类型约束在调用推断中会被绕过，gparam(T) 分支会给未绑定的形参
        // 绑定 T，例如 fn take[T](n: int, a: T)。因此前扫到下一个 EXPR_PARAM；扫到表尾时
        // 置 -1 并退出外循环。
        pn = pn + 1
        loop:
            if pn >= g_ast_count:
                pn = -1
                break
            if ast_kind(pn) == EXPR_PARAM:
                break
            pn = pn + 1
        an = ast_b(an)  // next EXPR_ARG

    // Check generic constraints (if any)
    gc := fi_generic_count(fi)
    if gc > 0:
        gci : ., mut = 0
        loop:
            if gci >= gc:
                break
            constr_idx := fi * MAX_GENERICS + gci
            if constr_idx < g_generic_constr_count:
                iface_ni := cell_load(g_generic_constr, constr_idx * 8)
                if iface_ni >= 0:
                    pname_ni := fi_generic_name(fi, gci)
                    concrete_ti : ., mut = -1
                    hmi : ., mut = 0
                    loop:
                        if hmi >= g_gen_map_count:
                            break
                        if cell_load(g_gen_map_names, hmi * 8) == pname_ni:
                            concrete_ti = cell_load(g_gen_map_types, hmi * 8)
                            break
                        hmi = hmi + 1
                    if concrete_ti >= 0:
                        // 先走本质轴引擎判定（约束名 = 原生/已声明
                        // 类型名时 `ty_sub(实参项, 约束项)` + 反例）；用户接口名，因此0 不在此直取
                        // (1 returns early; 0/-1 falls through to the existing
                        // check_iface path, keeping its wording and deduplication.
                        // New diagnostic wording is handled in gen_constr_satisfied.)
                        if gen_constr_satisfied(iface_ni, concrete_ti) == 0:
                            if gen_constr_seen_add(call_node * MAX_GENERICS + gci) != 0:
                                gen_constr_raise(concrete_ti, iface_ni, ast_line(call_node), ast_col(call_node))
                        else:
                            type_ni := get_type_name(concrete_ti)
                            if type_ni >= 0:
                                ii := find_iface(iface_ni)
                                if ii >= 0:
                                    if !check_iface(type_ni, ii):
                                        check_error(EC_TG_BOUND, "Type '" + istr_get(type_ni) + "' does not satisfy interface '" + istr_get(iface_ni) + "'", ast_line(call_node), ast_col(call_node))
            gci = gci + 1

    // ─── 调用点泛型绑定登记（monomorph 实例键类型项化）───
    // 按被调方泛型形参声明序登记 ti 段，块格式为 [count, ti...]。节点 int_val 是块起始 + 1，
    // 0 表示没有绑定；parser 创建 EXPR_CALL 时 int_val 初值为 0。ir_gen 据此生成规范实例键
    // inst_key_of_ti，并用 ti 型替换具体类型（monomorph.cr）。
    // 绑定全缺（g_gen_map_count == 0，如 T 只出现在返回型），因此不写（0 = 回落旧名字路径）。
    if g_gen_map_count > 0:
        gc_b := fi_generic_count(fi)
        if gc_b > 0:
            bstart := g_gen_binds_count
            grow_gen_binds(bstart + 1 + gc_b)
            cell_store(g_gen_binds, bstart * 8, gc_b)
            gi_b : ., mut = 0
            loop:
                if gi_b >= gc_b:
                    break
                pname_b := fi_generic_name(fi, gi_b)
                tv_b : ., mut = -1
                hmi_b : ., mut = 0
                loop:
                    if hmi_b >= g_gen_map_count:
                        break
                    if cell_load(g_gen_map_names, hmi_b * 8) == pname_b:
                        tv_b = cell_load(g_gen_map_types, hmi_b * 8)
                        break
                    hmi_b = hmi_b + 1
                // `__ret` is a synthesized output parameter, not an argument.
                // Fill it from the inferred return row (substituted with the
                // current argument bindings) so the bind block stays concrete;
                // otherwise IR generics fall back to `int`.
                if tv_b < 0:
                    pname_str := istr_get(pname_b)
                    if str_len(pname_str) >= 5:
                        if str_sub(pname_str, 0, 5) == "__ret":
                            rr : ., mut = -2
                            if fi >= 0 && fi < g_func_ret_count:
                                rr = cell_load(g_func_ret_ti, fi * 8)
                            if rr == -2:
                                rr = ty_code_to_ti(fi_return_type(fi))
                            if rr >= 0:
                                tv_b = substitute_return_type(rr)
                cell_store(g_gen_binds, (bstart + 1 + gi_b) * 8, tv_b)
                gi_b = gi_b + 1
            g_gen_binds_count = bstart + 1 + gc_b
            ast_set_int_val(call_node, bstart + 1)

    // Inferred return: the checker stored the body-derived row. Substitute the
    // current call's generic bindings before the explicit return-node path.
    if fi >= 0 && fi < g_func_ret_count:
        rt_row := cell_load(g_func_ret_ti, fi * 8)
        if rt_row != -2:
            return substitute_return_type(rt_row)

    // Substitute return type
    if g_gen_map_count > 0 && ret_type_node >= 0:
        resolved_ret := res_call_type(ret_type_node, fi)
        return substitute_return_type(resolved_ret)

    // Fallback: look up from symbol table
    func_ni : ., mut = ast_a(fn_node)
    si := find_gsym(func_ni)
    if si >= 0 && sym_kind(si) == SYM_FN:
        return sym_type(si)
    return TI_UNIT

// --- check_func with generic param scope ---

fn check_func(fi: int):
    g_checker_current_fi = fi
    // Reset per-function borrow state
    g_borrow_count = 0
    g_borrow_cap = 0
    g_holder_count = 0
    g_holder_cap = 0
    g_borrow_scope_depth = 0
    g_borrow_scope_markers_cap = 0
    fn_node := fi_ast_node(fi)
    saved_lib := g_cur_lib
    g_cur_lib = lib_of_node(fn_node)
    // Extern functions have no body to check — skip
    if ast_kind(fn_node) == EXPR_EXTERN:
        return
    name_idx := ast_a(fn_node)  // EXPR_FN: a = name idx
    first_param := ast_b(fn_node)  // EXPR_FN: b = first param node
    param_count := ast_c(fn_node)  // EXPR_FN: c = param count
    return_type := fi_return_type(fi)  // EXPR_FN: raw return TY_*, safe from hotpatch encoding
    body := ast_data(fn_node)  // EXPR_FN: data = body node

    push_scope()
    // Register generic params if any
    if fi_generic_count(fi) > 0:
        gi : ., mut = 0
        loop:
            if gi >= fi_generic_count(fi):
                break
            gname_idx := cell_load(g_funcs, fi * ESZ_FUNCINFO + OFF_FI_GENERIC_NAMES + gi * 8)
            g_ti := alloc_type(TYP_GENERIC_PARAM, gname_idx, 0)
            def_sym(gname_idx, SYM_TYPE, g_ti, -1)
            gi = gi + 1
    // Add params to scope
    pi : ., mut = 0
    pn : ., mut = first_param
    loop:
        if pi >= param_count:
            break
        if pn < 0:
            break
        pname_idx := ast_a(pn)  // EXPR_PARAM: a = name idx
        self_mode := ast_int_val(pn)  // EXPR_PARAM: int_val = self mode (0=normal, 1=self, 2=&self, 3=&mut self, -1=variadic)
        if self_mode == -1:
            pi = pi + 1
            pn = pn + 1
            continue
        ti : ., mut = TI_UNIT
        if self_mode == 0:
            // Regular param: resolve using original type node if it's non-base (named/generic)
            orig_type_node := ast_data(pn)
            if orig_type_node >= 0 && ast_kind(orig_type_node) != 0:
                ti = res_type_node(orig_type_node)
            else:
                // Base type: switch on type_val (TY_*)
                // 值经单表 `ty_code_to_ti`；本站点域 = {INT,DEX,BOOL,STRING,CHAR}
                //  （缺 UNIT/NEVER/7，UNIT 缺不等于行为差：映射值 = 初值 TI_UNIT；NEVER 差异携带值，
                //  fn f(b: never) 的形参符号类型是 unit，@raw_int 会报 TF07。
                ptype := ast_type_val(pn)
                ptype_mapped := ty_code_to_ti(ptype)
                if ptype_mapped >= 0 && ptype_mapped != TI_NEVER && ptype_mapped != TI_DYN:
                    ti = ptype_mapped
        else:
            fn_name := istr_get(fi_name(fi))
            fn_len := str_len(fn_name)
            dot_pos : ., mut = -1
            di : ., mut = 0
            loop:
                if di >= fn_len:
                    break
                if cell_load_byte(fn_name, di) == 46:
                    dot_pos = di
                    break
                // '.' = 46
                di = di + 1
            if dot_pos > 0:
                struct_name := str_sub(fn_name, 0, dot_pos)
                struct_ni := str_intern(struct_name)
                si := find_gsym(struct_ni)
                if si >= 0 && sym_kind(si) == SYM_TYPE:
                    // Resolve through a type node, not sym_type: a generic struct
                    // written as a bare name becomes a generic apply there, which
                    // is what lets `self.field` substitute an inferred field type.
                    tnode := alloc_node(EXPR_IDENT, 0, 0, 0, struct_ni, 0, 0, 0, 0)
                    struct_ti := res_type_node(tnode)
                    if self_mode == 1:
                        // self by value
                        ti = struct_ti
                    else:
                        // &self (mode 2) or &mut self (mode 3)
                        mut_flag : ., mut = 0
                        if self_mode == 3:
                            mut_flag = 1
                        ti = alloc_type(TYP_REF, struct_ti, mut_flag)
            // A receiver may carry an explicit annotation (`self: Box`). It wins
            // over the mangled name: a free function has no "Struct.method" name
            // to derive from, and a method on a generic struct needs the same
            // generic-apply path a normal parameter takes.
            ann_node := ast_data(pn)
            if ann_node >= 0 && ast_kind(ann_node) != 0:
                base_ti := res_type_node(ann_node)
                if self_mode == 1:
                    ti = base_ti
                else:
                    ann_mut : ., mut = 0
                    if self_mode == 3:
                        ann_mut = 1
                    ti = alloc_type(TYP_REF, base_ti, ann_mut)
        def_sym(pname_idx, SYM_PARAM, ti, -1)
        pi = pi + 1
        // Params are not contiguous — type nodes are allocated between them
        pn = pn + 1
        loop:
            if pn >= g_ast_count:
                break
            if ast_kind(pn) == EXPR_PARAM:
                break
            pn = pn + 1
    // Check body
    if body >= 0:
        ret_ti : ., mut = TI_UNIT
        // First check for named type via the stored type node (kind != 0)
        type_node := ast_type_val(fn_node)
        if type_node > 0 && ast_kind(type_node) != 0:
            ret_ti = res_type_node(type_node)
        else:
            // 值经单表 `ty_code_to_ti`；本站点域 = {INT..CHAR}（含 NEVER；缺 7，
            //  fn f() -> dyn 的体检查用 unit 作为后备，与 never 格互不干扰。
            ret_ti_mapped := ty_code_to_ti(return_type)
            if ret_ti_mapped >= 0 && ret_ti_mapped != TI_DYN:
                ret_ti = ret_ti_mapped
        // The parser synthesizes `__ret` when `->` is omitted. Record that this
        // function needs body-derived return inference.
        ret_inferred : ., mut = 0
        if get_type_kind(ret_ti) == TYP_GENERIC_PARAM:
            rn := istr_get(get_type_data(ret_ti))
            if str_len(rn) >= 5:
                if str_sub(rn, 0, 5) == "__ret":
                    ret_inferred = 1
        // nail3：先算 ret_ti / flow 检查，再推体， 逐 `return` 核对需要这两个值在手。
        //  次序改动是安全的：`res_type_node`/`ty_code_to_ti`/`scan_for_yield` 都只看
        //  声明与 AST，不依赖 `infer_expr(body)` 的结果。
        is_flow_fn : ., mut = 0
        if scan_for_yield(body) != 0:
            is_flow_fn = 1
        saved_ret_ti := g_cur_fn_ret_ti
        saved_ret_ok := g_cur_fn_ret_checked
        g_cur_fn_ret_ti = ret_ti
        g_cur_fn_ret_checked = 0
        if is_flow_fn == 0 && get_type_kind(ret_ti) != TYP_GENERIC_PARAM && fi_generic_count(fi) == 0:
            g_cur_fn_ret_checked = 1
        g_infer_ret_active = ret_inferred
        g_infer_ret_ti = -2
        body_ti := infer_expr(body)
        if ret_inferred != 0:
            iti : ., mut = g_infer_ret_ti
            if iti == -2:
                iti = body_ti
            cell_store(g_func_ret_ti, fi * 8, iti)
        g_infer_ret_active = 0
        g_cur_fn_ret_ti = saved_ret_ti
        g_cur_fn_ret_checked = saved_ret_ok
        compat := type_compat_strict(body_ti, ret_ti)
        // 落空分析（TF01 统一处理，见 stmt_cannot_fall_through 头注）：体确定不能落空（如以
        // 无 break 的 loop 收尾），因此块类型 = 末语句类型推出的 unit 不是缺返回值的证据，
        // 等价于 never 格（与下行既有 TI_NEVER 豁免同路）。
        if compat != 1 && body_ti != TI_NEVER && stmt_cannot_fall_through(body) == 0:
            // Generic templates defer body/return compatibility to the
            // monomorphized instance, where parameter types are concrete. The
            // instance is revalidated by check_func in gen_create_instance.
            // Skip check for flow functions (yield instead of return).
            if !is_flow_fn && get_type_kind(ret_ti) != TYP_GENERIC_PARAM && fi_generic_count(fi) == 0:
                diag_type_incompatible(compat, EC_TF_RETURN, "Function return type mismatch", ast_line(fn_node), ast_col(fn_node))
    // 规约标注，在 pop_scope 之前（形参仍在作用域内，`#check(a > 0)` 才能定型）
    spec_check_func(fn_node, return_type)
    pop_scope()
    g_cur_lib = saved_lib

// 每函数标注检查， bool 型 + `#ensure` 的 `result` 域 + C1 子集（禁调用）。
// 时点 = `check_func` 尾部（形参已入作用域）；`result` 用嵌套作用域绑定，因此不泄进函数体。
// 判定约定：`infer_expr` 给不出 bool（含未覆盖情形），因此一律报 V05 并终止编译（不得未知当通过）。
// 域检查的第二重来源 = `infer_expr` 对未定义名的既有诊断（N06/N01，build 路径非豁免，因此阻断）。
fn spec_check_func(fn_node: int, return_type: int):
    if g_spec_count == 0:
        return
    hit : ., mut = 0
    i : ., mut = 0
    loop:
        if i >= g_spec_count:
            break
        if spec_fnode(i) == fn_node:
            hit = 1
            break
        i = i + 1
    if hit == 0:
        return
    push_scope()
    // #ensure 的 result 绑定：与既有作用域名冲突时报错并终止编译，不任选一个，也不遮蔽。
    // result 只在确需绑定时调用 str_intern；无条件调用会让 STR 段凭空增加 10 字节。
    ri : ., mut = -1
    j : ., mut = 0
    loop:
        if j >= g_spec_count:
            break
        if spec_fnode(j) == fn_node && spec_kind(j) == 1:
            ri = j
            break
        j = j + 1
    if ri >= 0:
        res_ni := str_intern("result")
        if find_sym(res_ni) >= 0:
            spec_set_status(ri, SPEC_ST_RED)
            check_error(EC_V_RESULT_SHADOW,
                "'result' is already bound in this scope (#ensure binding would shadow it)",
                spec_line(ri), spec_col(ri))
        else:
            def_sym(res_ni, SYM_LOCAL, ty_code_to_ti(return_type), -1)
    // 逐条检查：1. 表达式不得包含调用，按 C1 子集处理；纯度时序问题尚未解决，当前只绕开。
    // 2. 表达式必须恰为 bool。
    k : ., mut = 0
    loop:
        if k >= g_spec_count:
            break
        if spec_fnode(k) == fn_node:
            if spec_has_call(spec_expr(k)) != 0:
                spec_set_status(k, SPEC_ST_RED)
                check_error(EC_V_CALL_BANNED,
                    "annotation expression must not contain calls (C1 subset)",
                    spec_line(k), spec_col(k))
            else:
                t := infer_expr(spec_expr(k))
                if t != TI_BOOL:
                    spec_set_status(k, SPEC_ST_RED)
                    check_error(EC_V_NOT_BOOL, "annotation expression must be bool",
                        spec_line(k), spec_col(k))
        k = k + 1
    pop_scope()

// 标注表达式的调用扫描（C1 子集：禁调用）。只走 C1 允许的节点形（字面量/标识符/一元/二元），
// 遇到调用即返回 1；未知节点形 = 不判定（返回 0，由 bool 型那一关兜住）。
fn spec_has_call(e: int) -> int:
    if e < 0:
        return 0
    k : ., mut = ast_kind(e)
    if k == EXPR_CALL:
        return 1
    if k == EXPR_BINARY:
        if spec_has_call(ast_a(e)) != 0:
            return 1
        return spec_has_call(ast_b(e))
    if k == EXPR_UNARY:
        return spec_has_call(ast_a(e))
    return 0

fn check_impl_for():
    pi : ., mut = 0
    loop:
        if pi >= g_impl_for_count:
            break
        iface_ni := cell_load(g_impl_for, pi * 16)
        type_ni := cell_load(g_impl_for, pi * 16 + 8)
        // Find interface by name
        ii := find_iface(iface_ni)
        if ii < 0:
            iface_name := istr_get(iface_ni)
            check_error(EC_N_UNDEFINED, "Undefined interface '" + iface_name + "'", 0, 0)
            pi = pi + 1
            continue
        method_count := cell_load(g_ifaces, ii * ESZ_IFACEINFO + OFF_IF_METHOD_COUNT)
        mi : ., mut = 0
        loop:
            if mi >= method_count:
                break
            mbase := ii * ESZ_IFACEINFO + OFF_IF_METHODS + mi * ESZ_IFMETHOD
            method_ni := cell_load(g_ifaces, mbase + OFF_IFM_NAME)
            method_pc := cell_load(g_ifaces, mbase + OFF_IFM_PARAM_COUNT)
            method_name := istr_get(method_ni)
            iface_name2 := istr_get(iface_ni)

            // 方法解析 = 表查询
            // （`g_methods` 三元组 -> 函数名 ni -> 函数行），不再拼 "Type.method" 串。
            func_ni : ., mut = iface_find_method(type_ni, method_ni)
            fi : ., mut = -1
            if func_ni >= 0:
                fi = find_func(func_ni)
            if fi < 0:
                check_error(EC_TF_METHOD_NOT_FOUND, "Impl missing method '" + method_name + "' for interface '" + iface_name2 + "'", 0, 0)
                mi = mi + 1
                continue
            // 接收者模式属于调用约定维度。两侧都是码 0 时不可比，因此显式比较 self mode。
            if sh_iface_self_mode(ii, mi) != sh_func_self_mode(fi):
                check_error(EC_TF_METHOD_ARG_TYP, "Param 1 type mismatch for method '" + method_name + "' in interface '" + iface_name2 + "'", 0, 0)
            // 参数计数
            actual_pc := fi_param_count(fi)
            if actual_pc != method_pc:
                check_error(EC_TF_METHOD_ARG_CNT, "Param count mismatch for method '" + method_name + "': expected " + int_str(method_pc) + " got " + int_str(actual_pc), 0, 0)
            // 逐参类型（签名项比较：N 不入项 / 泛型应用展开 / 命名行按名， 取代旧裸码相等）
            pti : ., mut = 0
            loop:
                if pti >= method_pc || pti >= MAX_IFACE_METHOD_PARAMS:
                    break
                apt := sh_func_sig_param_term(fi, pti)
                ept := sh_iface_sig_param_term(ii, mi, pti)
                if apt >= 0 && ept >= 0:
                    // 判定 = 引擎的不变槽结构比较原语（0/1 全域；理由见 type_engine.cr 的
                    // iface_user_satisfies_ii 注，ty_sub 会把确定不同上抛为 -1 = 未覆盖情形）
                    if tt_list_same(apt, ept) != 1:
                        pnum_str := int_str(pti + 1)
                        check_error(EC_TF_METHOD_ARG_TYP, "Param " + pnum_str + " type mismatch for method '" + method_name + "' in interface '" + iface_name2 + "'", 0, 0)
                pti = pti + 1
            // 返回类型（签名项比较；同上）
            art := sh_func_sig_ret_term(fi)
            ert := sh_iface_sig_ret_term(ii, mi)
            if art >= 0 && ert >= 0:
                if tt_list_same(art, ert) != 1:
                    check_error(EC_TF_RETURN, "Return type mismatch for method '" + method_name + "' in interface '" + iface_name2 + "'", 0, 0)
            mi = mi + 1
        pi = pi + 1

fn check_global_let(node: int):
    saved_lib := g_cur_lib
    g_cur_lib = lib_of_node(node)
    val_node := ast_c(node)  // EXPR_LET: c = value
    type_node := ast_b(node) // EXPR_LET: b = 注解类型节点（-1 = 无）
    val_ti : ., mut = TI_UNIT
    if val_node >= 0:
        val_ti = infer_expr(val_node)
    // 全局初始化器的值/注解兼容检查，与局部站点共用本函数。全局符号类型在注册趟
    // check_global_lets 就取注解行，不检查同样会产生错误产物。
    ti : ., mut = val_ti
    if type_node >= 0:
        ti = res_type_node(type_node)
    check_let_annot_compat(node, val_node, val_ti, ti)
    g_cur_lib = saved_lib

// --- Dynamic type set tracking ---

fn grow_dyn_type_sets(needed: int):
    if needed < g_dyn_type_set_cap:
        return
    nc : ., mut = g_dyn_type_set_cap * 2
    if nc < 64:
        nc = 64
    if nc < needed:
        nc = needed + 64
    nb := alloc(nc * 8)
    cell_copy(g_dyn_type_sets, g_dyn_type_set_cap * 8, nb)
    g_dyn_type_sets = nb
    g_dyn_type_set_cap = nc

fn dyn_set_type(var_idx: int, ti: int):
    grow_dyn_type_sets(var_idx + 1)
    old_bits := cell_load(g_dyn_type_sets, var_idx * 8)
    bit : ., mut = 1
    if ti >= 0 && ti < 64:
        bit = 1
        shl : ., mut = ti
        loop:
            if shl <= 0:
                break
            bit = bit * 2
            shl = shl - 1
    cell_store(g_dyn_type_sets, var_idx * 8, old_bits + bit)
    if var_idx >= g_dyn_type_set_count:
        g_dyn_type_set_count = var_idx + 1

fn dyn_has_type(var_idx: int, ti: int) -> int:
    if var_idx < 0 || var_idx >= g_dyn_type_set_count:
        return 0
    set := cell_load(g_dyn_type_sets, var_idx * 8)
    bit : ., mut = 1
    if ti >= 0 && ti < 64:
        bit = 1
        shl : ., mut = ti
        loop:
            if shl <= 0:
                break
            bit = bit * 2
            shl = shl - 1
    if (set / bit) % 2 != 0:
        return 1
    return 0

fn union_bitmaps(a: int, b: int) -> int:
    r : ., mut = 0
    pos : ., mut = 0
    loop:
        if pos >= 64:
            break
        bit : ., mut = 1
        shl : ., mut = pos
        loop:
            if shl <= 0:
                break
            bit = bit * 2
            shl = shl - 1
        if (a / bit) % 2 != 0 || (b / bit) % 2 != 0:
            r = r + bit
        pos = pos + 1
    return r

fn validate_dyn_method(si: int, method_ni: int, line: int, col: int):
    if si < 0 || si >= g_dyn_type_set_count:
        return
    set := cell_load(g_dyn_type_sets, si * 8)
    if set == 0:
        return
    ti : ., mut = 0
    loop:
        if ti >= g_type_count:
            break
        if ti >= 64:
            break
        bit : ., mut = 1
        shl : ., mut = ti
        loop:
            if shl <= 0:
                break
            bit = bit * 2
            shl = shl - 1
        if (set / bit) % 2 != 0:
            type_ni := get_type_name(ti)
            if type_ni >= 0:
                if !type_has_method(type_ni, method_ni):
                    tname := istr_get(type_ni)
                    mname := istr_get(method_ni)
                    check_error(EC_N_METHOD, "dyn: method '" + mname + "' not found on type '" + tname + "'", line, col)
        ti = ti + 1

// --- Type inference ---

// 推实参：EXPR_CALL 的所有已解析
// 所有 return 路径在返回前必须调用本函数，否则实参表达式完全不被类型检查。后果有两重：
//   1. 方法或模块限定的调用，ast_data 只能由 infer_expr 的对应分支回填。未回填时 ir_gen
//      会读出错误函数名，后端查不到并崩溃。
//   2. 实参里的未定义函数、变量和常量越界会通过且不报错。
// 调用点共 4 处；函数尾的 func_ni < 0 路径也调用本函数。泛型直调由 infer_gen_call 内部
// 推断实参，不在这里重复。
fn infer_call_args(first_arg: int):
    an : ., mut = first_arg
    loop:
        if an < 0:
            break
        anode := ast_a(an)
        infer_expr(anode)
        // fail-closed 护栏：实参位的调用若是 EXPR_FIELD，且 ast_data 仍为 0，说明被调名
        // 从未回填。ir_gen 会读出错误函数名，后端按名解析失败后触发外部位重定向并崩溃。
        // 此处报错并终止编译，由 check_all 之后的 fail-closed 检查阻断，不产生错误产物。
        // 正常路径不会触发：已解析路径都会推实参，dyn 方法调用的名字由 dyn 分支回填。
        // 该护栏用于防止同类回归。
        if anode >= 0:
            if ast_kind(anode) == EXPR_CALL:
                fnode := ast_a(anode)
                if fnode >= 0:
                    if ast_kind(fnode) == EXPR_FIELD:
                        if ast_data(anode) <= 0:
                            check_error(EC_N_FUNC, "Unresolved module/method call in argument position", ast_line(anode), ast_col(anode))
        an = ast_b(an)

// bool 洞的转换节点：改写为 `bool_str(x)` 调用（`fmt.cr`）。抽成函数是为了让 `infer_expr` 的
// 分支保持单行、便于审计（转换表：string 恒等 · int->int_str · bool->bool_str · 其它 P028）。
fn interp_bool_node(node: int, inner: int) -> int:
    callee := alloc_node(EXPR_IDENT, 0, 0, 0, str_intern("bool_str"), 0, 0, ast_line(node), ast_col(node))
    wrapper := alloc_node(EXPR_NONE, inner, -1, 0, 0, 0, 0, ast_line(node), ast_col(node))
    ast_set_kind(node, EXPR_CALL)
    ast_set_a(node, callee)
    ast_set_b(node, wrapper)
    ast_set_c(node, 1)
    ast_set_data(node, -1)
    ast_set_type_val(node, TY_STRING)
    return TI_STR

// S1P 测量辅助（只在 CORE_S1P=1 路径被调用）：取全局行 line 所属文件的前 48 字符。
// 目的 = 把 S1P 的流行号映射回真实源文本。只用于测量：默认位不被调用，因此产物
// 零足迹不受影响；`sm_line_text` 走 alloc（不 intern），不向 STR 段写入额外数据。
fn s1p_src_frag(line: int) -> string:
    sm : ., mut = file_sm_id(diag_fileid_for_line(line))
    if sm < 0:
        sm = sm_for_line(line)
    if sm < 0:
        return ""
    local := line - sm_file_line_base(sm)
    txt := sm_line_text(sm, local)
    if str_len(txt) > 48:
        return str_sub(txt, 0, 48)
    return txt

// ─── S1P 台账三件：检查、单实参判定、枚举环，与 s1p_arg_ring 同一契约 ───
// 检查：进程启动时由 prelude_init 读取 `CORE_S1P`。所有类型引擎调用都必须在
// 检查后（默认位一步不执行 = 零足迹）。
fn s1p_gate() -> int:
    if g_s1p_seen == 0:
        prelude_init()
    return g_s1p_on

// 单实参：跳过规则（2`None`->`T?` / 3字面量多态 / 形参型不可得 / 未推断出形），因此否则 `unify_types`
//  判定，因此失配则只打数值台账一行（格式见 `s1p_arg_ring`；`call_ni` = 被调名 intern 下标）。
fn s1p_arg_one(arg_n: int, pi2: int, pti: int, ati: int, is_ext: int, call_ni: int):
    skip : ., mut = 0
    if pti < 0:
        skip = 1
    // 形参型不可得
    if ati == TI_UNIT:
        skip = 1
    // 未推断出形
    if ast_kind(arg_n) == EXPR_INT || ast_kind(arg_n) == EXPR_DEX:
        skip = 1
    // 3. 字面量多态
    // ─── 哨兵/不可判定值族：未知 ≠ 异型 ───────────────────────
    // 三条同族但分属两个空间的判定， 不得互换（见下）：
    //  · `ati == TI_NEVER`， 判实参类型项下标：类型不可得（未解析名等），因此不是不匹配；
    //  · `ati == TI_DYN`， 判下标：`dyn` = ⊤，与一切相容；
    //  · `get_type_kind(ati) == TYP_GENERIC_PARAM`， 判kind：泛型形参声明期不可验证，因此不判。
    //  索引空间 vs kind 空间：`TI_DYN`(下标常量 = 7) 与 `TYP_GENERIC_PARAM`(kind 码 = 7)
    //   数值相同、空间不同，因此把 `ati == TI_DYN` 写成 `ati == TYP_GENERIC_PARAM`（或把 kind 判定
    //   写成 `get_type_kind(ati) == TI_DYN`）能编过、且可能蒙对一部分用例（两条 skip 在同一屏、
    //   都让同一批输入不再报），因此判断依据必须能区分空间写错与规则缺一条：见
    //   `tests/selfhost/test_s1p_sentinel_skips.py` 的逐条突变自证（本刀强制要求）。
    if ati == TI_NEVER:
        skip = 1
    // 错误哨兵（未定义名、上游类型错误）：未知 ≠ 异型。不跳过会让一条
    // N01/N06 再叠一条 9917 台账行，且该行不携带任何可判定的类型信息。
    if ati == ti_error():
        skip = 1
    // 类型不可得，因此未知 ≠ 异型
    if ati == TI_DYN:
        skip = 1
    // dyn = ⊤
    // 前缀条 `ati > TI_DEX_S` 必需：类型表下标 0..8 = 标量/占位，因此直接查表会读到占位行的 kind
    //  （假阳性来源；同 `@raw_int` 分支 `:4217-4218` 同款护栏）。泛型形参行下标 ≥ 10。
    if ati > TI_DEX_S && get_type_kind(ati) == TYP_GENERIC_PARAM:
        skip = 1
    // 泛型形参：声明期不可验证
    if ast_kind(arg_n) == EXPR_ENUM_CONSTRUCTOR:
        nm2 := istr_get(ast_a(arg_n))
        if str_eq(nm2, "None") != 0:
            // 2. None->T?（不用 `ti_is_optional`：该符号不在 corelsp 单元，因此本文件为
            //  corec+corelsp 共享单元，只能用两侧皆有的符号）
            if pti >= 0 && get_type_kind(pti) == TYP_OPTIONAL:
                skip = 1
    if skip == 0:
        if !unify_types(pti, ati):
            println(int_str(9917 + is_ext) + " " + int_str(ast_line(arg_n))
                + " " + int_str(ast_col(arg_n))
                + " " + int_str(pi2)
                + " " + int_str(pti) + " " + int_str(ati)
                + " " + istr_get(call_ni)
                + " @@ " + s1p_src_frag(ast_line(arg_n)))

// 枚举构造器环：形参型来自枚举声明的变体携带值（变体不注册 FuncInfo，因此不能用 `s1p_arg_ring`）。
//  携带值类型节点 = `ei_variant_type_node(enum_i, vi, k)`，因此`res_type_node` 取类型项（检查通过后执行）。
fn s1p_enum_ring(name_idx: int, first_arg: int, arg_count: int):
    if name_idx < 0:
        return
    if s1p_gate() == 0:
        return
    i : ., mut = 0
    loop:
        if i >= g_enum_count:
            break
        vi : ., mut = 0
        loop:
            if vi >= ei_variant_count(i):
                break
            if ei_variant_name(i, vi) == name_idx:
                tc := ei_variant_type_count(i, vi)
                if arg_count == tc:
                    an2 : ., mut = first_arg
                    k2 : ., mut = 0
                    loop:
                        if an2 < 0:
                            break
                        if k2 >= tc:
                            break
                        arg_n := ast_a(an2)
                        ati := infer_expr(arg_n)
                        tn := ei_variant_type_node(i, vi, k2)
                        pti : ., mut = -1
                        if tn >= 0:
                            pti = res_type_node(tn)
                        s1p_arg_one(arg_n, k2, pti, ati, 0, name_idx)
                        k2 = k2 + 1
                        an2 = ast_b(an2)
                return
            vi = vi + 1
        i = i + 1

// ─── S1P 台账环，四调用形态共用一份，结构参照 dex_align_call_args ───
// 契约：
// · 只在 `CORE_S1P=1` 路径被调用：检查 `g_s1p_on != 0` 在环内，因此默认位一步不执行（零足迹，
//  判断依据见 `tests/selfhost/test_s1p_liveness.py` 的对偶用例 + 本刀的逐字节对拍）；
// · 不改产物：只 println 数值、不新增 intern（`istr_get(fi_name(fi))` 只读既有串，
//  台账注释见调用点：字符串与 `type_display` 会把新串写进 `.ccr` 的 STR 段）；
// · 格式继承：`9917|9918 <line> <col> <param_idx> <param_ti> <arg_ti> <call> @@ <片段>`
//  字段序/数量/前缀一律照旧（参考套件 = `tests/selfhost/test_s1p_liveness.py`；扩字段须同批重锁该套件）。
// 参数：
// · `fi` = 被调 FuncInfo（参数列表来源）；`is_ext` = extern/C ABI，因此单列前缀 `9918`；
// · `first_arg`/`arg_count` = EXPR_ARG 列表首项/列表长度，列表中不含接收者（parser 实证：接收者属
//  `EXPR_FIELD` 的被调对象位），因此`param_skip` 指明参数列表首需跳过的接收者位数：
//  直调/extern/模块限定 = 0（参数列表无 self）· 方法 = 1（参数列表含 self，与实参列表对应时跳过）。
// 元数规则：arg_count + param_skip 不等于 fi_param_count(fi) 时跳过且不报错，不打点，
// 也不据此判定。
fn s1p_arg_ring(fi: int, first_arg: int, arg_count: int, param_skip: int, is_ext: int):
    if fi < 0:
        return
    fnode := fi_ast_node(fi)
    if fnode < 0:
        return
    fn_kind : ., mut = 0
    if ast_kind(fnode) == EXPR_FN:
        fn_kind = 1
    if fn_kind == 0 && is_ext == 0:
        return
    pc := fi_param_count(fi)
    if arg_count + param_skip != pc:
        return
    pn2 : ., mut = ast_b(fnode)
    // 跳过参数列表首的接收者位。parser 先分配形参的类型子树，再分配形参节点，因此形参在
    // AST 中不连续；游标要扫到下一个 EXPR_PARAM。
    k : ., mut = 0
    loop:
        if k >= param_skip:
            break
        if pn2 < 0:
            return
        pn2 = pn2 + 1
        loop:
            if pn2 >= g_ast_count:
                pn2 = -1
                break
            if ast_kind(pn2) == EXPR_PARAM:
                break
            pn2 = pn2 + 1
        k = k + 1
    pi2 : ., mut = param_skip
    an2 : ., mut = first_arg
    loop:
        if an2 < 0:
            break
        if pn2 < 0:
            break
        if pi2 >= pc:
            break
        if g_s1p_seen == 0:
            prelude_init()
        //  整块纳入检查：仅把 print 纳入检查不够，本块里的类型引擎调用
        //  （`infer_expr`/`res_call_type`/`unify_types`）会向 TYPE(7) 段的项表里留项（memo）
        // 因此输出 `.ccr` 的段 7 变长（例如检查只覆盖 print 时 `opt_dex_test.cr` 的 `.ccr`
        //  187029->187053 +24B、ELF 同；其余 36/37 档零差）。故默认位下本块一步都不执行。
        if g_s1p_on != 0:
            arg_n := ast_a(an2)
            ati := infer_expr(arg_n)
            ptn := ast_data(pn2)
            pti : ., mut = -1
            if ptn >= 0:
                pti = res_call_type(ptn, fi)
            // 单实参判定与打点（跳过规则 23 + `unify_types` + 只打数值台账），三件共用
            s1p_arg_one(arg_n, pi2, pti, ati, is_ext, fi_name(fi))
        pi2 = pi2 + 1
        an2 = ast_b(an2)
        pn2 = pn2 + 1
        loop:
            if pn2 >= g_ast_count:
                pn2 = -1
                break
            if ast_kind(pn2) == EXPR_PARAM:
                break
            pn2 = pn2 + 1

fn infer_expr(node: int) -> int:
    if node < 0:
        return TI_UNIT


    // 字面量定型 -> 本质条目表查表（唯一真源 = iface_registry.cr 的 lit_code 列）。
    // 改动前 = 本处 5 条内联 if（`return TI_INT/TI_DEX/TI_STR/TI_BOOL/TI_CHAR`，计划时点
    // checker.cr:1892-1897 -> 现址 :1896-1901，偏移 +4）逐格转录进表；5 个 kind 的判断
    // 顺序与短路行为逐字保持，EXPR_NONE 转发行仍夹在 EXPR_INT 与 EXPR_DEX 之间，
    // 不得重排、不得合并成先取 kind 再查的循环（那会改短路路径）。
    if ast_kind(node) == EXPR_INT:
        return iface_lit_ti(EXPR_INT)
    if ast_kind(node) == EXPR_BIGINT:
        return TI_INT
    if ast_kind(node) == EXPR_NONE && ast_a(node) >= 0 && ast_a(node) != node:
        return infer_expr(ast_a(node))
    if ast_kind(node) == EXPR_DEX:
        return iface_lit_ti(EXPR_DEX)
    if ast_kind(node) == EXPR_STRING:
        return iface_lit_ti(EXPR_STRING)
    if ast_kind(node) == EXPR_BOOL:
        return iface_lit_ti(EXPR_BOOL)
    if ast_kind(node) == EXPR_CHAR:
        return iface_lit_ti(EXPR_CHAR)

    if ast_kind(node) == EXPR_IDENT:
        name_idx := ast_int_val(node)
        // Borrow check: can't use variable while it's borrowed
        if !check_use(name_idx):
            name := istr_get(name_idx)
            check_error(EC_B_USE_WHILE_BORROWED, "Cannot use '" + name + "' while it is borrowed", ast_line(node), ast_col(node))
        si := find_sym(name_idx)
        if si >= 0:
            return sym_type(si)
        name := istr_get(name_idx)
        check_error(EC_N_UNDEFINED, "Undefined name '" + name + "'", ast_line(node), ast_col(node))
        return ti_error()
    if ast_kind(node) == EXPR_INTERP_HOLE:
        // 字符串插值洞：就地改写本节点为带类型转换的表达式，父节点只存索引
        // 因此无需父指针（扁平 AST 的天然便利）。转换表（维护者签字）：string 恒等 · int->`int_str` ·
        // char->chr，bool->if b {"true"} else {"false"}，不经过 int，保持 bool 不隐式转 int；
        // 其它类型（含 dex 两形态）报 P028 并终止编译（fail-closed；dex 见下方说明）。洞表达式由 parser
        // 末尾统一解析到 a 槽；解析失败（a<0），因此退化为空串（错误已由 parser 报过，不级联）。
        inner : ., mut = ast_a(node)
        if inner < 0 || inner == node:
            ast_set_kind(node, EXPR_STRING)
            ast_set_a(node, 0)
            ast_set_b(node, 0)
            ast_set_c(node, 0)
            ast_set_data(node, str_intern(""))
            ast_set_type_val(node, TY_STRING)
            return TI_STR
        hti := infer_expr(inner)
        // 两条约束：
        //  1. bool 洞不合成 if 表达式：分支需要 EXPR_BLOCK，且 rc=139，因此改走 stdlib
        //   bool_str(b)（fmt.cr），不经过 int，返回 "true" 或 "false"。
        //  2. char 暂不放开（见下方 P028 注）：签名表原写 char->chr，但 char 的运行期值是
        //   字符串（`ir_gen` EXPR_CHAR 发串常量），`chr(char)` 把串指针当码点，因此输出空；改走恒等则
        //   触发预存缺口 `string + char` = rc=139（`"c=" + ch` 独立复现），因此须先修那条，属另案。
        if hti == TI_STR:
            // 恒等：把本节点改写成内层表达式的字段副本（父只存索引，因此副本即等价）
            ast_set_kind(node, ast_kind(inner))
            ast_set_a(node, ast_a(inner))
            ast_set_b(node, ast_b(inner))
            ast_set_c(node, ast_c(inner))
            ast_set_int_val(node, ast_int_val(inner))
            ast_set_type_val(node, ast_type_val(inner))
            ast_set_data(node, ast_data(inner))
            return infer_expr(node)
        if hti == TI_BOOL:
            return interp_bool_node(node, inner)
        if hti == TI_INT:
            cname := "int_str"
            callee := alloc_node(EXPR_IDENT, 0, 0, 0, str_intern(cname), 0, 0, ast_line(node), ast_col(node))
            wrapper := alloc_node(EXPR_NONE, inner, -1, 0, 0, 0, 0, ast_line(node), ast_col(node))
            ast_set_kind(node, EXPR_CALL)
            ast_set_a(node, callee)
            ast_set_b(node, wrapper)
            ast_set_c(node, 1)
            ast_set_data(node, -1)
            ast_set_type_val(node, TY_STRING)
            return TI_STR
        // 不可插值类型（当前 fail-closed）：
        //  · `dex`（TI_DEX / TI_DEX_S）：本仓 dex 有 bits 与 scaled 两表示，`dex_str` 只按其一工作，因此不猜；
        //  · char：运行期值虽然是字符串，但 string + char 会 rc=139（"c=" + ch 可独立复现），
        //   洞路径会踩同一个问题，因此暂不放开；
        //  · 其它（struct/enum/optional/array/函数…）本就不该插值。
        check_error(EC_P_INTERP_TYPE, "string interpolation supports string/int/bool here; for dex/char or other types convert explicitly (dex: int_str(@raw_int(d)); char: pre-existing 'string + char' defect, separately registered)", ast_line(node), ast_col(node))
        ast_set_kind(node, EXPR_STRING)
        ast_set_a(node, 0)
        ast_set_b(node, 0)
        ast_set_c(node, 0)
        ast_set_data(node, str_intern(""))
        ast_set_type_val(node, TY_STRING)
        return TI_STR

    if ast_kind(node) == EXPR_NONE:
        // Wrapper node in struct literal: forward to inner expression
        if ast_a(node) >= 0 && ast_a(node) != node:
            return infer_expr(ast_a(node))
        return TI_UNIT

    if ast_kind(node) == EXPR_BINARY:
        left := ast_a(node)
        right := ast_b(node)
        op := ast_c(node)
        // `EXPR_BINARY + OP_ASSIGN` 分支已删（站点 6 随之退役，
        // 其挂点在本分支内）。不可达三种情形证明：1 `tok2op`（parser.cr）不产 OP_ASSIGN；
        // 2 `T_EQ` -> `EXPR_ASSIGN`（parser.cr）；3 `+=` 族显式构造 `EXPR_ASSIGN` 包裹的
        // `EXPR_BINARY` 且 op ∈ {ADD,SUB,MUL,DIV}，因此全仓无生产者（含 opt/pass 路径）。
        // 实证：全语料 shadow 站点直方图 `assign-binary=0`（32988 次判定）。赋值判定点
        // = 站点 8（EXPR_ASSIGN，见 infer_expr 的 EXPR_ASSIGN 分支），逐字保留。
        lt := infer_expr(left)
        rt := infer_expr(right)
        if op == OP_ADD || op == OP_SUB || op == OP_MUL || op == OP_DIV || op == OP_MOD:
            // String concatenation for OP_ADD
            if op == OP_ADD && (lt == TI_STR || rt == TI_STR):
                return TI_STR
            // 指针算术接受 TYP_REF，结果保持操作数 kind：REF 进 REF 出。如果把结果降级成
            // PTR，引用性会在算术后丢失且不报错。
            // Pointer arithmetic: *T + n or n + *T -> *T（PTR/REF 皆可，结果随左/右操作数）
            if (op == OP_ADD || op == OP_SUB) && ((get_type_kind(lt) == TYP_PTR || get_type_kind(lt) == TYP_REF) && rt == TI_INT):
                return lt  // return the address type unchanged（PTR 进 PTR 出 · REF 进 REF 出）
            if (op == OP_ADD || op == OP_SUB) && (lt == TI_INT && (get_type_kind(rt) == TYP_PTR || get_type_kind(rt) == TYP_REF)):
                return rt
            // Pointer difference: *T - *T -> int（PTR/REF 皆可；两侧不必同 kind，与既有宽松范围一致）
            if op == OP_SUB && (get_type_kind(lt) == TYP_PTR || get_type_kind(lt) == TYP_REF) && (get_type_kind(rt) == TYP_PTR || get_type_kind(rt) == TYP_REF):
                return TI_INT
            // 算术运算检查使用 ANY 检查：至少一侧许可即通过，与改动前的 && 形状等价。
            // 表的 ADD..MOD 格只含 int 和 dex；PTR、STRING 由早退分支的结果规则处理，不进本检查。
            // 负控：*T + *T 和 "a" - "b" 仍报 TB01。
            if iface_permits(iface_kind_of(lt), op) == 0 && iface_permits(iface_kind_of(rt), op) == 0:
                check_error(EC_TB_ADD, "Arithmetic operation requires int or dex", ast_line(node), ast_col(node))
            if lt == TI_DEX || rt == TI_DEX:
                return TI_DEX
            return TI_INT
        if op == OP_EQ || op == OP_NE || op == OP_LT || op == OP_GT || op == OP_LE || op == OP_GE:
            return TI_BOOL
        if op == OP_AND || op == OP_OR:
            // 查表（检查条件 = ALL每侧都须许可）。转录依据 = 本处改动前的
            // `lt != TI_BOOL && lt != TI_INT || rt != TI_BOOL && rt != TI_INT`（= 某侧非 bool 且
            // 非 int即报错）；判断条件写 OP_AND（不另设 IP_LOGIC，OP_AND/OP_OR 在表中同步置位，
            // 且现状 :1969 对两个 op 一字不分）。表的 AND/OR 格恰 {int, bool}，dex 不在内
            // 例如 1.5 && true 报 TC01。
            if iface_permits(iface_kind_of(lt), OP_AND) == 0 || iface_permits(iface_kind_of(rt), OP_AND) == 0:
                check_error(EC_TC_IF_COND, "Logical operator requires bool or int operands", ast_line(node), ast_col(node))
            return TI_BOOL
        return TI_INT

    if ast_kind(node) == EXPR_UNARY:
        op := ast_c(node)
        if op == UOP_NEG:
            return infer_expr(ast_a(node))
        if op == UOP_NOT:
            infer_expr(ast_a(node))
            return TI_BOOL
        if op == UOP_REF:
            operand := ast_a(node)
            is_mut := ast_int_val(node)
            inner : ., mut = TI_UNIT
            if ast_kind(operand) == EXPR_IDENT:
                vi := ast_int_val(operand)
                if !check_borrow(vi, is_mut):
                    name := istr_get(vi)
                    if is_mut != 0:
                        check_error(EC_B_BORROW_MUT, "Cannot borrow '" + name + "' as mutable, already borrowed", ast_line(node), ast_col(node))
                    else:
                        check_error(EC_B_BORROW_IMMUT, "Cannot borrow '" + name + "' as immutable, already mutably borrowed", ast_line(node), ast_col(node))
                si := find_sym(vi)
                if si >= 0:
                    inner = sym_type(si)
            else:
                inner = infer_expr(operand)
            // UOP_REF produces TYP_REF with extra = is_mut. The kind and extra
            // must be set together: TYP_REF with extra 0 would disagree with the
            // engine's AK_REF slot 0 (mut, part of identity).
            return alloc_type(TYP_REF, inner, is_mut)
        if op == UOP_DEREF:
            inner := infer_expr(ast_a(node))
            if get_type_kind(inner) == TYP_REF:
                return get_type_data(inner)
            if get_type_kind(inner) == TYP_PTR:
                return get_type_data(inner)
            if get_type_kind(inner) == TYP_GENERIC_PARAM:
                return inner
            return inner
        return infer_expr(ast_a(node))

    if ast_kind(node) == EXPR_CALL:
        func_node := ast_a(node)
        first_arg := ast_b(node)
        arg_count := ast_c(node)
        func_ni : ., mut = -1

        // Method call: obj.method(args) or module.func(args)
        if ast_kind(func_node) == EXPR_FIELD:
            obj := ast_a(func_node)
            method_ni := ast_int_val(func_node)

            // Module-qualified call: module.func(args)
            mod_call_done : ., mut = 0
            mod_found_mfi : ., mut = -1
            mod_found_hidden : ., mut = 0
            if ast_kind(obj) == EXPR_IDENT:
                mod_name_ni := ast_int_val(obj)
                si := find_sym(mod_name_ni)
                if si >= 0 && sym_kind(si) == SYM_MODULE:
                    fileid_ni := sym_type(si)
                    // Look up (fileid, method) in module function table
                    mfi : ., mut = 0
                    loop:
                        if mfi >= g_mod_func_count:
                            break
                        if cell_load(g_mod_func_fileids, mfi * 8) == fileid_ni && cell_load(g_mod_func_names, mfi * 8) == method_ni:
                            if mod_func_visible(fileid_ni, method_ni) == 0:
                                mod_found_hidden = 1
                                break
                            func_ni = cell_load(g_mod_func_names, mfi * 8)
                            ast_set_data(node, func_ni)
                            call_flags := ast_type_val(node)
                            if call_flags == CALL_FLAG_INLINE:
                                ast_set_type_val(node, CALL_FLAG_MODULE + CALL_FLAG_INLINE)
                            else:
                                ast_set_type_val(node, CALL_FLAG_MODULE)
                            mod_call_done = 1
                            mod_found_mfi = mfi
                            break
                        mfi = mfi + 1
            if mod_found_hidden != 0:
                check_error(EC_N_UNDEFINED, "Undefined function '" + istr_get(method_ni) + "'", ast_line(node), ast_col(node))
                return ti_error()
            if mod_call_done == 1:
                // Infer arg types
                an : ., mut = first_arg
                loop:
                    if an < 0:
                        break
                    infer_expr(ast_a(an))
                    an = ast_b(an)
                // 模块限定调用接入 S1P 台账。本分支同样会早退，需要在这里记录。
                //  `param_skip = 0`：参数列表无 self（模块函数是普通 fn）。
                fi_mod := find_func(func_ni)
                s1p_arg_ring(fi_mod, first_arg, arg_count, 0, 0)
                if fi_mod >= 0 && fi_generic_count(fi_mod) > 0:
                    return infer_gen_call(fi_mod, node, first_arg, arg_count)
                if mod_found_mfi >= 0:
                    return cell_load(g_mod_func_tis, mod_found_mfi * 8)
                return TI_UNIT

            obj_ti := infer_expr(obj)
            // --- Dyn method validation ---
            if obj_ti == TI_DYN:
                // Dynamic dispatch carries the method name, not a resolved
                // function link; the receiver type is only known at run time.
                ast_set_data(node, method_ni)
                if ast_kind(obj) == EXPR_IDENT:
                    obj_ni := ast_int_val(obj)
                    obj_si := find_sym(obj_ni)
                    if obj_si >= 0:
                        validate_dyn_method(obj_si, method_ni, ast_line(node), ast_col(node))
                // Infer arg types (for side effects)
                an_dyn : ., mut = first_arg
                loop:
                    if an_dyn < 0:
                        break
                    infer_expr(ast_a(an_dyn))
                    an_dyn = ast_b(an_dyn)
                return TI_UNIT
            lookup_ti : ., mut = obj_ti
            // A `&self` / `&mut self` receiver has type TYP_REF(struct); the
            // method table is keyed by the named struct, so dereference first.
            if lookup_ti >= 0 && lookup_ti < g_type_count && get_type_kind(lookup_ti) == TYP_REF:
                lookup_ti = get_type_data(lookup_ti)
            // Unwrap generic apply to base type
            if lookup_ti >= 0 && lookup_ti < g_type_count && get_type_kind(lookup_ti) == TYP_GENERIC_APPLY:
                lookup_ti = get_type_data(lookup_ti)
            if lookup_ti >= 0 && lookup_ti < g_type_count && get_type_kind(lookup_ti) == TYP_NAMED:
                struct_ni := get_type_data(lookup_ti)
                // Look up method in method table
                mi : ., mut = 0
                loop:
                    if mi >= g_method_count:
                        break
                    if cell_load(g_methods, mi * 24) == struct_ni && cell_load(g_methods, mi * 24 + 8) == method_ni:
                        cand_ni := cell_load(g_methods, mi * 24 + 16)
                        cand_fi := find_func_owned(cand_ni, decl_owner_for_unique(struct_ni))
                        if cand_fi >= 0:
                            cand_node := fi_ast_node(cand_fi)
                            cand_owner := lib_of_node(cand_node)
                            if cand_owner >= 0 && cand_owner != g_cur_lib && (lib_can_import(g_cur_lib, cand_owner) == 0 || lib_export_find_kind(cand_owner, cand_ni, SYM_FN) < 0):
                                check_error(EC_N_METHOD, "Undefined method '" + istr_get(method_ni) + "'", ast_line(node), ast_col(node))
                                break
                        func_ni = cand_ni
                        if cand_fi >= 0:
                            ast_set_data(node, func_link(cand_fi))
                        else:
                            ast_set_data(node, func_ni)
                        break
                    mi = mi + 1
            // Generic param method call resolution
            if func_ni < 0 && get_type_kind(lookup_ti) == TYP_GENERIC_PARAM:
                // Auto-constraint inference is sound only when the receiver is
                // the generic parameter itself (`a.show()`). A field projection
                // (`e.payload.show()`) has a different type that is unknown at
                // template time; defer it to the monomorphized instance check.
                direct_recv : ., mut = 0
                if ast_kind(node) == EXPR_CALL:
                    callee := ast_a(node)
                    if ast_kind(callee) == EXPR_FIELD:
                        recv := ast_a(callee)
                        if ast_kind(recv) == EXPR_IDENT:
                            direct_recv = 1
                if direct_recv == 0:
                    return TI_UNIT
                gen_ni := get_type_data(lookup_ti)
                gc2 := cur_fn_is_generic()
                gci2 : ., mut = 0
                loop:
                    if gci2 >= gc2:
                        break
                    gname_idx2 := cell_load(g_funcs, g_checker_current_fi * ESZ_FUNCINFO + OFF_FI_GENERIC_NAMES + gci2 * 8)
                    if gname_idx2 == gen_ni:
                        constr_idx2 := g_checker_current_fi * MAX_GENERICS + gci2
                        iface_ni2 : ., mut = -1
                        if constr_idx2 < g_generic_constr_count:
                            iface_ni2 = cell_load(g_generic_constr, constr_idx2 * 8)
                        // V4 automatic constraint inference: an unconstrained
                        // parameter calling `a.m()` adopts the unique interface
                        // that declares `m`. Ambiguous matches stay unresolved
                        // and fail through the normal return-type check.
                        if iface_ni2 < 0:
                            iface_ni2 = infer_iface_for_method(method_ni)
                            if iface_ni2 < 0 && g_cur_fn_ret_ti >= 0:
                                iface_ni2 = infer_iface_for_method_ret(method_ni, g_cur_fn_ret_ti)
                            if iface_ni2 >= 0:
                                grow_gen_constr(constr_idx2 + 1)
                                cell_store(g_generic_constr, constr_idx2 * 8, iface_ni2)
                                if constr_idx2 + 1 > g_generic_constr_count:
                                    g_generic_constr_count = constr_idx2 + 1
                        if iface_ni2 >= 0:
                                ii2 := find_iface(iface_ni2)
                                if ii2 >= 0:
                                    imc2 := cell_load(g_ifaces, ii2 * ESZ_IFACEINFO + OFF_IF_METHOD_COUNT)
                                    imi2 : ., mut = 0
                                    loop:
                                        if imi2 >= imc2:
                                            break
                                        imbase2 := ii2 * ESZ_IFACEINFO + OFF_IF_METHODS + imi2 * ESZ_IFMETHOD
                                        if cell_load(g_ifaces, imbase2 + OFF_IFM_NAME) == method_ni:
                                            // 调用点记录泛型形参名 ni 和标记位，实例化时由
                                            // monomorph 按具体类型查方法表，解析为真实函数名。
                                            // 不再合成 "T.m" 字符串；名字拼接和克隆期文本替换会让
                                            // 实例体内的调用目标悬空。
                                            ast_set_data(node, gen_ni)
                                            ast_set_type_val(node, CALL_FLAG_IFACE_METHOD)
                                            iface_ret2 := cell_load(g_ifaces, imbase2 + OFF_IFM_RET_TI)
                                            // 值经单表 `ty_code_to_ti`；本站点值域 = parser 写入的
                                            //  `unpack_type(返回型节点)`（parser.cr:1701，即 TY_* 码）；域 = {INT..CHAR}
                                            //  （缺 NEVER/7，因此落尾 TI_UNIT）。显式化：现状 6 行用的是 `iface_ret2 == TY_*`
                                            //  而值域是 TI_*，靠TY_INT==TI_INT==0 … TY_CHAR==TI_CHAR==6的数值撞车成立，
                                            //  合一后按语义查表。例如 -> never 的 iface 方法在调用点
                                            //  是 unit，-> char 是 char。
                                            iface_ret_ti := ty_code_to_ti(iface_ret2)
                                            if iface_ret_ti >= 0 && iface_ret_ti != TI_NEVER && iface_ret_ti != TI_DYN:
                                                func_ni = gen_ni
                                                return iface_ret_ti
                                            func_ni = gen_ni
                                            return TI_UNIT
                                        imi2 = imi2 + 1
                        break
                    gci2 = gci2 + 1
            // Infer arg types (walk EXPR_ARG chain)
            an : ., mut = first_arg
            loop:
                if an < 0:
                    break
                infer_expr(ast_a(an))
                an = ast_b(an)
            if func_ni >= 0:
                si := find_gsym(func_ni)
                if si >= 0 && sym_kind(si) == SYM_FN:
                    // a（E-11，姊妹站点）：与直调站点检查同形，
                    //  `func_ni` = parser impl 分支写入的 mangled ni（"S.m"，
                    //  parser.cr:1887-1894），因此与直调同一张 g_funcs/符号表，
                    //  `fi_return_type`/`sym_type` 语义逐位同。差异一处（显式对应）：
                    //  本尾无泛型早退（直调走 `infer_gen_call`），因此补
                    //  `fi_generic_count == 0` 检查，使泛型两站点一致不动
                    //  （参数化方法的返回型依实例化）。本范围恒无 extern（impl 分支
                    //  只认 `fn`，parser.cr:1864-1899），因此不需 EXPR_FN 限定
                    //  （行为等价，非逐字镜像）。嵌套 if 同直调站点（`&&` 不短路 +
                    //  表读无护栏）。
                    fi_m := find_func(func_ni)
                    // 方法调用接入 S1P 台账。本分支在 S1P 块之前早退，方法实参位原本是盲区。
                    // param_skip = 1：实参列表不含接收者，参数列表含 self；跳过 self 后形参与实参
                    // 一一对应，元数规则为 arg_count + 1 == pc。
                    s1p_arg_ring(fi_m, first_arg, arg_count, 1, 0)
                    if fi_m >= 0:
                        if fi_generic_count(fi_m) > 0:
                            return infer_gen_call_recv(fi_m, node, first_arg, arg_count, obj_ti)
                        if fi_generic_count(fi_m) == 0:
                            if sym_type(si) == TI_UNIT:
                                if fi_return_type(fi_m) == TY_NEVER:
                                    return ti_error()
                    return sym_type(si)
            return TI_UNIT

        // Determine function name and return type
        if ast_kind(func_node) == EXPR_IDENT:
            func_ni = ast_int_val(func_node)
            fi_direct := find_func(func_ni)
            if fi_direct >= 0:
                ast_set_data(node, func_link(fi_direct))
        // @builtin(args) — transfer args from EXPR_CALL to EXPR_AT, then delegate
        if ast_kind(func_node) == EXPR_AT:
            ast_set_b(func_node, first_arg)
            return infer_expr(func_node)
        // Check prelude builtins (syscall3/syscall4 public OS ABI, raw memory
        // ABI restricted to @std/@core — no .cr body). Arguments are inferred
        // here as well: the symbol-table path is gone for internal builtins.
        prelude_ti := prelude_builtin_return_ti(func_ni)
        if prelude_ti >= 0:
            infer_call_args(first_arg)
            return prelude_ti
        // Check for SYM_SO_FN (.so extension registered)
        so_fn_fi : ., mut = -1
        if func_ni >= 0:
            si := find_gsym(func_ni)
            if si >= 0 && sym_kind(si) == SYM_SO_FN:
                so_fn_fi = si
                tag_flags2 := sym_type(si)  // stores tag_flags
                type_enc2 := sym_node(si)   // stores type encoding

                // Infer arg types (walk EXPR_ARG chain)
                an : ., mut = first_arg
                loop:
                    if an < 0:
                        break
                    infer_expr(ast_a(an))
                    an = ast_b(an)

                // Decode return type (type_enc2 % 100)
                ret_code2 : ., mut = type_enc2 - (type_enc2 / 100) * 100
                // Map back to TI_*
                if ret_code2 == 0:
                    return TI_INT
                if ret_code2 == 1:
                    return TI_STR
                if ret_code2 == 2:
                    return TI_UNIT
                if ret_code2 == 3:
                    return TI_DEX
                if ret_code2 == 4:
                    return TI_BOOL
                return TI_UNIT
        // Look up function
        if func_ni >= 0 && so_fn_fi < 0:
            si := find_gsym(func_ni)
            if si >= 0 && sym_kind(si) == SYM_FN:
                // Check if generic function
                fi : ., mut = find_func(func_ni)
                if fi >= 0 && fi_generic_count(fi) > 0:
                    return infer_gen_call(fi, node, first_arg, arg_count)
                // a（E-11）：被调非泛型 `fn` 声明的返回行 = `never`
                // 因此调用推断 `never`。声明注册趟把 NEVER 钳成 unit（collect_decls 的
                //  域检查 :1491：`rt_mapped != TI_NEVER`），因此此处按裸码 `fi_return_type`
                //  复读一次；两处下游检查随之生效：声明位 `check_let_annot_compat` 豁免3
                //  （:526）/ 返回位（:2234）。只改推断结果：`sym_type(si)` 值不动
                // 因此发射路径零耦合（ir_gen 的调用结果型经 sym_type，见 ir_gen.cr:1662）。
                //  检查四条：1 泛型已由上方早退排除；2 仍是被钳的 unit 格；3 裸码 =
                //  TY_NEVER；4 = `fn` 声明（extern 路径按裁4 不动）。
                //  嵌套 if：bootstrap 构建的 corec 对 `&&` 两侧无条件求值
                //  （bootstrap/corec/frontend/ir_gen.py:226-235），且 `fi_return_type`
                //  （dyn_arr.cr:459）与 `ast_kind`（dyn_arr.cr:370）均无护栏，因此不得写
                //  `guard && 表读`。
                if fi >= 0:
                    if sym_type(si) == TI_UNIT:
                        if fi_return_type(fi) == TY_NEVER:
                            fnd := fi_ast_node(fi)
                            if fnd >= 0:
                                if ast_kind(fnd) == EXPR_FN:
                                    infer_call_args(first_arg)   // 未完成项：实参必须被推断（本 return 路径原先跳过）
                                    return ti_error()
                infer_call_args(first_arg)   // 未完成项：实参必须被推断（本 return 路径原先跳过）
                // ── S1P 实参类型打点（report-only）──
                // 目的：测量非泛型直调和方法调用的实参类型不校验。打点不写入 g_diags 或
                // g_errors，rc 和产物不变。判定统一经类型引擎 unify_types。
                // 六类跳过规则：
                //   1. 泛型 T↔T：本点 callee 非泛型，泛型已由上方早退排除。
                //   2. None->T?：实参是 None 构造子且形参可选。
                //   3. 整型或小数字面量到数值形参，按字面量多态处理。
                //   4. 方法接收者：EXPR_ARG 列表不含接收者，参数列表含 self（第 0 位），因此形参
                //      游标偏移 +1，不是实参偏移 +1。
                //   5. extern/C ABI：callee 是 EXPR_EXTERN，单列台账前缀 9918，不进主桶 9917。
                //   6. 元数不齐（含变参）：有效实参数不等于形参数时跳过，不打点，不据此判定。
                // 台账格式只认行首：`9917|9918 <line> <col> <param_idx> <param_ti> <arg_ti> <call>`。
                // 不要只 grep 9917 裸串，会命中源码回显。
                if fi >= 0:
                    fnode := fi_ast_node(fi)
                    is_ext2 : ., mut = 0
                    if fnode >= 0 && ast_kind(fnode) == EXPR_EXTERN:
                        is_ext2 = 1
                    s1p_arg_ring(fi, first_arg, arg_count, 0, is_ext2)
                return sym_type(si)  // return type
            // Builtins were already resolved by prelude_builtin_return_ti
            // above, with the visibility filter applied. Reaching this point
            // means neither a symbol nor a visible ABI name matched.
            // Not found in symbol table or builtins — report error
            name := istr_get(func_ni)
            check_error(EC_N_FUNC, "Undefined function '" + name + "'", ast_line(node), ast_col(node))
            infer_call_args(first_arg)   // 未完成项：实参必须被推断（本 return 路径原先跳过）
            return ti_error()
        infer_call_args(first_arg)   // 单一真源（与上述 4 处同一函数）
        return TI_INT  // external/unknown functions

    if ast_kind(node) == EXPR_BLOCK:
        stmt_start := ast_a(node)
        stmt_count := ast_b(node)
        res : ., mut = TI_UNIT
        push_borrow_scope()
        i : ., mut = 0
        loop:
            if i >= stmt_count:
                break
            sn := cell_load(g_block_stmts, (stmt_start + i) * 8)
            res = infer_expr(sn)
            i = i + 1
        // Track the last-statement type for debugging
        // (no operation needed — res is already the last type)
        pop_borrow_scope()
        return res

    if ast_kind(node) == EXPR_IF:
        cond := ast_a(node)
        then_node := ast_b(node)
        else_node := ast_c(node)
        cond_ti := infer_expr(cond)
        // if and while share the same bool-only condition gate.
        // 查表使用 ONE 检查，单操作数。IP_COND 格只含 bool；int/dex 等被拒，例如 if 1 报 TC01。
        if cur_fn_is_generic() == 0:
            if iface_permits(iface_kind_of(cond_ti), IP_COND) == 0:
                check_error(EC_TC_IF_COND, "If condition must be bool", ast_line(node), ast_col(node))
        // --- Dyn type set merge: save pre-if state ---
        pre_dyn_count : ., mut = g_dyn_type_set_count
        pre_dyn_save : string, mut = ""
        if pre_dyn_count > 0:
            pre_dyn_save = alloc(pre_dyn_count * 8)
            cell_copy(g_dyn_type_sets, pre_dyn_count * 8, pre_dyn_save)
        // --- Process then branch ---
        push_borrow_scope()
        then_ti := infer_expr(then_node)
        pop_borrow_scope()
        // --- Save then-branch dyn state ---
        then_dyn_count : ., mut = g_dyn_type_set_count
        then_dyn_save : string, mut = ""
        if then_dyn_count > 0:
            then_dyn_save = alloc(then_dyn_count * 8)
            cell_copy(g_dyn_type_sets, then_dyn_count * 8, then_dyn_save)
        // --- Restore pre-if state (zero stale entries beyond pre_dyn_count) ---
        g_dyn_type_set_count = pre_dyn_count
        if pre_dyn_count > 0:
            cell_copy(pre_dyn_save, pre_dyn_count * 8, g_dyn_type_sets)
        iz : ., mut = pre_dyn_count
        loop:
            if iz >= then_dyn_count:
                break
            cell_store(g_dyn_type_sets, iz * 8, 0)
            iz = iz + 1
        // --- Process else branch (if any) ---
        if else_node >= 0:
            push_borrow_scope()
            else_ti := infer_expr(else_node)
            pop_borrow_scope()
            // --- Merge dyn type sets from both branches ---
            merge_count : ., mut = then_dyn_count
            if g_dyn_type_set_count > merge_count:
                merge_count = g_dyn_type_set_count
            grow_dyn_type_sets(merge_count)
            g_dyn_type_set_count = merge_count
            mi : ., mut = 0
            loop:
                if mi >= merge_count:
                    break
                then_bits : ., mut = 0
                if mi < then_dyn_count:
                    then_bits = cell_load(then_dyn_save, mi * 8)
                else_bits : ., mut = 0
                if mi < g_dyn_type_set_count:
                    else_bits = cell_load(g_dyn_type_sets, mi * 8)
                merged := union_bitmaps(then_bits, else_bits)
                cell_store(g_dyn_type_sets, mi * 8, merged)
                mi = mi + 1
            g_dyn_type_set_count = merge_count
            // 参序归一：合并结果类型 = then_ti（下方 return then_ti），因此源 = else 侧，
            // 目标 = then 侧（长度约束更弱者放前面会被这里拦住 = 与结果类型一致；反之亦然）
            compat := type_compat_strict(else_ti, then_ti)
            // TC02 统一处理：if 的值类型定义为 then_ti（下方 return then_ti），因此当 else 支
            // 确定发散（`return` 族收尾、不产出值）时，else 侧的类型是幻影（EXPR_RETURN 推断
            // = 所返回值类型），因此相容判定无对象，因此不报。
            // 不对称是有意的：then 支发散时 then_ti 本身即幻影（模型，另案），因此该形态继续报
            // TC02（保留真信号）。判断条件 = stmt_diverges（头注：只服务本判定点）。
            // 错误哨兵单独用 ti_error() 表示。then 支有错时也要豁免，否则会叠加一条 TC02。
            if compat != 1 && then_ti != TI_NEVER && else_ti != TI_NEVER && then_ti != ti_error() && else_ti != ti_error():
                if stmt_diverges(else_node) == 0:
                    diag_type_incompatible(compat, EC_TC_IF_BRANCH, "If branches have different types", ast_line(node), ast_col(node))
            else if then_ti == TI_NEVER && ast_kind(else_node) == EXPR_BLOCK && ast_b(else_node) == 0:
                // ── nail1 判别式──────────────────────────
                // then 支发散（`never`）+ else 支是零项 region，因此报 TC02（保留真信号）。
                // 为什么必须用非类型维度：本形与 `src/compiler/main.cr` 的 if#2
                // （`else if c2b == 58:` 那层）在位置规则和 never 规则下类型逐格相同
                // （then_ti, else_ti）都是（never, unit），类型通道没有可分之处。
                // 唯一可分者是 else 的节点形态：本形的 else 是 `EXPR_BLOCK` 且 items 数 `b == 0`
                // （5region 可为空新引入的合法形）；if#2 的 else 是 `EXPR_IF`，判断条件恒假
                // 因此 构造性地不改变它的诊断集（强制检查可直接验证）。
                // 语义依据：零项 region 是能执行到终点、产出 unit 的路径（只是没有语句），
                // `return` 支是执行不到终点的路径，因此两者值语义不同，因此保留真信号。
                // 非对称是刻意的：不加镜像（then 零项、else 发散时也报错），否则正常用例
                // 会被误报。现有检查保持同一方向。
                diag_type_incompatible(compat, EC_TC_IF_BRANCH, "If branches have different types", ast_line(node), ast_col(node))
            return then_ti
        return TI_UNIT

    if ast_kind(node) == EXPR_GO:
        // a=-1, b=body; c=iter_ni (>=0 for range mode)
        body := ast_b(node)
        // range-go 迭代变量绑定：go i a..b body 绑定 int 局部 i，ir_gen 侧按 EXPR_GO.c
        // 使用该名。作用域严格限制在 body 内，进入前绑定，退出后恢复。绑定语义与 for 同源，
        // 与 ir_gen 的 iter_var_ni 用法一致。ast_c(node) <= 0 的单发形 go f(x) 不绑定。
        iter_ni := ast_c(node)
        scoped : ., mut = 0
        push_borrow_scope()
        if iter_ni > 0:
            push_scope()
            def_sym(iter_ni, SYM_LOCAL, TI_INT, -1)
            scoped = 1
        body_ti := infer_expr(body)
        if scoped != 0:
            pop_scope()
        pop_borrow_scope()
        rn := ast_data(node)
        if rn <= 0:
            return body_ti  // single go: future of body type
        // Range go: returns array of body type (size from data=range_node)
        range_node := ast_data(node)
        rng_count := ast_b(range_node) - ast_a(range_node)
        // `[T; N]` is an inline storage representation hint, not a type
        // constructor. Its semantics belong to product types, sequence types with
        // length constraints, or F11 length facts. See the full note at
        // res_type_node's EXPR_ARRAY branch.
        return alloc_type(TYP_ARRAY, body_ti, rng_count)

    if ast_kind(node) == EXPR_YIELD:
        val := ast_a(node)
        val_ti : ., mut = TI_UNIT
        if val >= 0:
            val_ti = infer_expr(val)
        // In a flow, the yield type is the flow's result type; return the value type
        return val_ti  // yield's type is the yielded value's type

    if ast_kind(node) == EXPR_AWAIT:
        val := ast_a(node)
        val_ti := infer_expr(val)
        // If awaiting an array of T, return array element type T
        // If awaiting a single future, return the type directly
        if get_type_kind(val_ti) == TYP_ARRAY:
            return get_type_data(val_ti)  // await [Future<T>] -> T
        return val_ti

    if ast_kind(node) == EXPR_LOOP:
        push_borrow_scope()
        infer_expr(ast_a(node))
        pop_borrow_scope()
        return TI_UNIT

    if ast_kind(node) == EXPR_WHILE:
        cond := ast_a(node)
        body := ast_b(node)
        cond_ti := infer_expr(cond)
        // 查表（检查条件 = ONE）。IP_COND 格只含 bool，例如 while 1 报 TC04。
        if iface_permits(iface_kind_of(cond_ti), IP_COND) == 0:
            check_error(EC_TC_WHILE_COND, "While condition must be bool", ast_line(node), ast_col(node))
        push_borrow_scope()
        infer_expr(body)
        pop_borrow_scope()
        return TI_UNIT

    if ast_kind(node) == EXPR_FOR:
        var_ni := ast_a(node)
        iter := ast_b(node)
        body := ast_c(node)
        iter_ti := infer_expr(iter)
        elem_ti : ., mut = TI_INT
        k_iter := get_type_kind(iter_ti)
        if k_iter == TYP_ARRAY || k_iter == TYP_SLICE:
            elem_ti = get_type_data(iter_ti)
        push_scope()
        push_borrow_scope()
        def_sym(var_ni, SYM_LOCAL, elem_ti, -1)
        infer_expr(body)
        pop_borrow_scope()
        pop_scope()
        return TI_UNIT

    if ast_kind(node) == EXPR_RANGE:
        st := infer_expr(ast_a(node))
        et := infer_expr(ast_b(node))
        // Generic templates defer range operand typing to the instance.
        if cur_fn_is_generic() == 0:
            if st != TI_INT:
                check_error(EC_TB_ADD, "Range start must be int", ast_line(node), ast_col(node))
            if et != TI_INT:
                check_error(EC_TB_ADD, "Range end must be int", ast_line(node), ast_col(node))
        return TI_INT

    if ast_kind(node) == EXPR_MATCH:
        match_expr := ast_a(node)
        first_arm := ast_b(node)
        match_ti := infer_expr(match_expr)
        res : ., mut = TI_UNIT
        ai : ., mut = 0
        an : ., mut = first_arm
        // 穷穷尽性判定（补集空性 + 具体变体反例）。收集与臂体推断同趟：
        // 模式类别/归属 -> 模式项 CONS 列表（m_pats）+ 覆盖位（m_cover）+ 不可映射标记
        // （m_unmappable）；臂体推断后统一判（判断逻辑本体与消费点封装见 ty_shadow.cr 末段）。
        m_pats : ., mut = tt_nil()
        mc_save := mc_begin()     // 覆盖位图入栈，容量无界
        m_unmappable : ., mut = 0
        m_wild : ., mut = 0      // 通配/绑定已见（冗余臂判断用；非穷尽性判断本体）
        m_literal : ., mut = 0   // 任一 int/bool/string/char 字面量臂已见（无限域 -> 需 irrefutable 臂）
        m_order_rep : ., mut = 0 // 通配/绑定后仍有臂（TM05 只报一次）
        m_dup : ., mut = -1      // 首个冗余臂模式节点（-1 = 无）
        loop:
            if an < 0:
                break
            arm_pat := ast_a(an)  // EXPR_ARM: a = pattern
            arm_body := ast_b(an)  // EXPR_ARM: b = body
            if arm_pat >= 0:
                pk := sh_match_pat_kind(arm_pat)
                // 通配/绑定模式吞掉后续所有臂：后续臂不可达，报 TM05。
                if m_wild != 0 && m_order_rep == 0:
                    check_error(EC_TM_WILDCARD_ORDER,
                        "Wildcard or binding pattern must be the last arm",
                        ast_line(arm_pat), ast_col(arm_pat))
                    m_order_rep = 1
                if pk == 1:
                    if m_wild != 0:
                        if m_dup < 0:
                            m_dup = arm_pat
                    m_wild = 1
                    m_pats = tt_cons(tt_top(), m_pats)
                else if pk == 2:
                    // 嵌套子模式按载荷声明类型递归校验。子模式根不能靠 ast_b+i
                    // 取得（parser 只存首个子模式，复合子模式的后代又先分配），
                    // 用 ty_shadow 的 payload 根恢复；不可恢复/不支持的形态 fail closed。
                    if check_enum_payload_patterns(match_ti, arm_pat) != 0:
                        m_unmappable = 1
                    vi := sh_match_pat_variant(match_ti, arm_pat)
                    vt : ., mut = -1
                    if vi >= 0:
                        vt = sh_match_variant_term(match_ti, vi)
                    // 可选域（`T?`），枚举归属不成立时试 `Some`/`None` 两分支
                    // （sh_match_opt_pat 对非可选 scrutinee 恒 -1，因此既有枚举/非枚举零变化）。
                    oi : ., mut = -1
                    if vi < 0:
                        oi = sh_match_opt_pat(match_ti, arm_pat)
                        if oi >= 0:
                            vt = sh_match_opt_term(match_ti, oi)
                    if vt < 0:
                        m_unmappable = 1      // 非本枚举/非本域/未声明变体名，因此不判（不得当 ∅/⊤）
                    else:
                        ci : ., mut = vi
                        if vi < 0:
                            ci = oi
                        // 可选域：覆盖位 0 = 有值 / 1 = null
                        if m_wild != 0:
                            if m_dup < 0:
                                m_dup = arm_pat
                        if mc_has(ci) != 0:
                            if m_dup < 0:
                                m_dup = arm_pat
                        mc_add(ci)
                        m_pats = tt_cons(vt, m_pats)
                else if ast_kind(arm_pat) == EXPR_STRUCTPAT:
                    // Struct patterns are refutable: like literals, they need an
                    // irrefutable arm. Field syntax/type errors are diagnosed by
                    // check_struct_pattern; TM09 covers nested subpatterns.
                    m_literal = 1
                    if check_struct_pattern(arm_pat, match_ti) != 0:
                        m_unmappable = 1
                else if ast_kind(arm_pat) == EXPR_TUPLEPAT:
                    // Tuple patterns are refutable as well: arity/scrutinee/type
                    // errors are diagnosed by check_tuple_pattern, nested composites
                    // as TM09. An irrefutable arm is still required.
                    m_literal = 1
                    if check_tuple_pattern(arm_pat, match_ti) != 0:
                        m_unmappable = 1
                else:
                    lit_k := sh_match_lit_kind(arm_pat)
                    if lit_k >= 0:
                        m_literal = 1
                        if sh_match_lit_seen(first_arm, an, lit_k, ast_int_val(arm_pat)) != 0:
                            if m_dup < 0:
                                m_dup = arm_pat
                    else:
                        // 插值字符串 pattern 不是字面量：parser 产出 EXPR_BINARY/
                        // EXPR_INTERP_HOLE。它既不能按值比较，也不得当成“任意串匹配”。
                        ak0 := ast_kind(arm_pat)
                        if ak0 == EXPR_BINARY || ak0 == EXPR_INTERP_HOLE:
                            check_error(EC_TM_NESTED,
                                "String interpolation is not supported in a match pattern; use a literal",
                                ast_line(arm_pat), ast_col(arm_pat))
                        m_unmappable = 1      // struct / 插值 / EXPR_BIGINT 等，不判穷尽
            // Bind pattern variables in new scope
            push_scope()
            if arm_pat >= 0:
                if ast_kind(arm_pat) == EXPR_ENUMPAT:
                    // Enum variant payload bindings, including nested enum/struct/
                    // tuple sub-patterns. Each binding gets its declared payload type.
                    bind_enum_pattern_idents(arm_pat, match_ti)
                if ast_kind(arm_pat) == EXPR_STRUCTPAT:
                    // Struct pattern field bindings: each ident subpattern gets the
                    // declared field type (Task 5b1).
                    bind_struct_pattern_idents(arm_pat, match_ti)
                if ast_kind(arm_pat) == EXPR_TUPLEPAT:
                    // Tuple pattern element bindings: each ident subpattern gets the
                    // actual tuple element type (Task 5b2).
                    bind_tuple_pattern_idents(arm_pat, match_ti)
                if ast_kind(arm_pat) == EXPR_IDENT:
                    // 绑定臂的值就是 scrutinee：类型取 scrutinee 类型（旧实现
                    // 一律 TI_INT，字符串/char/bool  scrutinee 会错型）。
                    def_sym(ast_int_val(arm_pat), SYM_LOCAL, match_ti, -1)
            push_borrow_scope()
            arm_ti := infer_expr(arm_body)
            pop_borrow_scope()
            if ai == 0:
                res = arm_ti
            pop_scope()
            an = ast_c(an)  // next arm via linked list
            ai = ai + 1
        // 穷尽性判定：引擎补集空性（预算前后隔离照 type_equal_engine 的窗口规则）。
        // 判定结果：0 = 不穷尽（诊断 + 具体反例变体名）；1 = 穷尽；-1 = 不判（非枚举域/不可映射
        // 模式/引擎未知），零诊断（判定约定：未知不得当不穷尽，也不得当穷尽）。
        ty_budget_reset(200000)
        m_verdict : ., mut = -1
        if m_unmappable == 0 && m_literal != 0:
            // 字面量域（int/string/char）无限；bool 也按设计要求显式列出 `_`/绑定臂。
            // 没有 irrefutable 臂 -> 不穷尽，不再静默放行。
            if m_wild != 0:
                m_verdict = 1
            else:
                m_verdict = 0
        else:
            m_verdict = sh_match_exhaustive(match_ti, m_pats, m_unmappable)
        ty_budget_reset(200000)
        if m_verdict == 0:
            mi : ., mut = -1
            msg : ., mut = "Non-exhaustive match"
            if m_literal != 0:
                // 字面量域没有具体变体可命名；保持与枚举反例同一诊断码。
                msg = msg + ": add a wildcard or binding arm"
            else if get_type_kind(match_ti) == TYP_OPTIONAL:
                // `T?` 两分支反例命名：0 = 有值（Some）/ 1 = null（None）
                mi = mc_first_missing(2)
                if mi == 0:
                    msg = msg + ": missing variant 'Some'"
                if mi == 1:
                    msg = msg + ": missing variant 'None'"
            else:
                ea := find_enum_row_of(match_ti)
                if ea >= 0:
                    mi = mc_first_missing(ei_variant_count(ea))
                if mi >= 0:
                    msg = msg + ": missing variant '" + istr_get(ei_variant_name(ea, mi)) + "'"
            check_error(EC_TM_EXHAUST, msg, ast_line(node), ast_col(node))
        if m_dup >= 0:
            check_error(EC_TM_REDUNDANT, "Redundant match arm", ast_line(m_dup), ast_col(m_dup))
        mc_end(mc_save)   // 容量批 T3：覆盖位图出栈（清零本层位 + 回退长度）
        // Cache the inferred scrutinee type on the MATCH node for IR lowering.
        // +1 keeps 0 as the "absent" sentinel because TI_INT itself is 0.
        ast_set_data(node, match_ti + 1)
        return res

    if ast_kind(node) == EXPR_LET:
        var_ni := ast_a(node)
        type_node := ast_b(node)
        val_node := ast_c(node)
        val_ti : ., mut = TI_UNIT
        if val_node >= 0:
            val_ti = infer_expr(val_node)
            // Check if value is a borrow (&x or &mut x), record the holder
            if ast_kind(val_node) == EXPR_UNARY && ast_c(val_node) == UOP_REF:
                borrowed_ni := borrow_var_name(ast_a(val_node))
                if borrowed_ni >= 0:
                    mut_flag := ast_int_val(val_node)
                    record_borrow_holder(var_ni, borrowed_ni, mut_flag)
        ti : ., mut = val_ti
        if type_node >= 0:
            ti = res_type_node(type_node)
        // 值/注解兼容检查（豁免范围见 check_let_annot_compat 头注）
        check_let_annot_compat(node, val_node, val_ti, ti)
        if istr_get(var_ni) != "_":
            def_let_sym(var_ni, ti, ast_data(node))
            if ti == TI_DYN && val_node >= 0:
                grow_dyn_type_sets(g_sym_count)
                cell_store(g_dyn_type_sets, (g_sym_count - 1) * 8, 0)
                dyn_set_type(g_sym_count - 1, val_ti)
        return TI_UNIT

    if ast_kind(node) == EXPR_RETURN:
        // 以发散语句收尾的路径，其类型是 never，不再是所返回值的类型。值仍必须推断，
        // 否则 return foo() 里的未定义名和类型错误诊断会消失；推断结果不参与本节点类型。
        if ast_a(node) >= 0:
            vt := infer_expr(ast_a(node))
            if g_infer_ret_active != 0 && g_infer_ret_ti == -2:
                g_infer_ret_ti = vt
            // nail3：逐 `return` 核对返回值 vs 当前函数的声明返回型（新通道，见全局注释）。
            // 码 = TF01（`EC_TF_RETURN`，与体检查同码，措辞区分成因）。
            // 三个假红风险：
            // 1. 泛型返回：g_cur_fn_ret_checked == 0 时不判，声明返回型是泛型形参。
            // 2. 错误传播：值侧是 ti_error() 时 type_compat_strict 源侧放行，不叠加第二条诊断。
            // 3. never 值侧，例如 return boom()：never 作源，放行。
            // 4. 既存语料的 bool 和 int 惯用法：比较表达式的类型是 bool，而声明返回型写 int。
            //    自源中存在这类代码。本检查的目标是类型族不匹配，例如 string 对 int，不覆盖
            //    0/1 惯用法，因此显式豁免 bool 和 int 互判。豁免只限这一对，不放宽其它组合。
            bool_int_idiom : ., mut = 0
            if (vt == TI_BOOL && g_cur_fn_ret_ti == TI_INT) || (vt == TI_INT && g_cur_fn_ret_ti == TI_BOOL):
                bool_int_idiom = 1
            if g_cur_fn_ret_checked != 0 && bool_int_idiom == 0:
                c := type_compat_strict(vt, g_cur_fn_ret_ti)
                if c != 1:
                    // A struct with an inferred (`.`) field is a family, not a
                    // single type: the body fixes the instantiation. Naming the
                    // bare struct in `-> T` cannot match it, so point at the
                    // form that does work.
                    family_hint : ., mut = 0
                    if get_type_kind(vt) == TYP_GENERIC_APPLY:
                        // TYP_GENERIC_APPLY stores the base type row in `data`,
                        // and the base row is TYP_NAMED, whose `data` is the name.
                        base_ti := get_type_data(vt)
                        if get_type_kind(base_ti) == TYP_NAMED && get_type_kind(g_cur_fn_ret_ti) == TYP_NAMED:
                            if get_type_data(base_ti) == get_type_data(g_cur_fn_ret_ti):
                                family_hint = 1
                    else if get_type_kind(vt) == TYP_NAMED && get_type_kind(g_cur_fn_ret_ti) == TYP_NAMED:
                        if get_type_data(vt) == get_type_data(g_cur_fn_ret_ti):
                            sfi := find_struct(get_type_data(vt))
                            if sfi >= 0 && si_generic_count(sfi) > 0:
                                family_hint = 1
                    if family_hint != 0:
                        check_error(EC_TF_RETURN,
                            "Returned an instantiation of this struct, but the declared return type names the family; omit the return type to infer it from the body",
                            ast_line(node), ast_col(node))
                    else:
                        diag_type_incompatible(c, EC_TF_RETURN,
                            "Returned value type does not match the function's declared return type (" + type_display(vt) + " vs " + type_display(g_cur_fn_ret_ti) + ")",
                            ast_line(node), ast_col(node))
        return TI_NEVER

    if ast_kind(node) == EXPR_ENUM_CONSTRUCTOR:
        name_idx := ast_a(node)
        first_arg := ast_b(node)
        arg_count := ast_c(node)
        si := find_gsym(name_idx)
        if si >= 0 && sym_kind(si) == SYM_FN:
            // Infer arg types (walk EXPR_ARG chain)
            an : ., mut = first_arg
            loop:
                if an < 0:
                    break
                infer_expr(ast_a(an))
                an = ast_b(an)
            // 枚举构造器接入 S1P 台账。本分支同样会早退，需要在这里记录。
            //  变体不注册 FuncInfo，因此形参型取自枚举声明的变体携带值（`s1p_enum_ring`）。
            s1p_enum_ring(name_idx, first_arg, arg_count)
            return sym_type(si) // enum type
        name := istr_get(name_idx)
        // ─── 内建可选构造器（退役内建 Option 注册后的解析路径）───
        // `Some`/`None` 是关键字（lexer.cr 的 T_SOME/T_NONE 仅由这两个词产出），因此本分派是
        // 关键字名分派，不是类型名分派：用户声明同名变体时上面的 SYM_FN 命中优先
        // （p20 语义保持：用户 `enum Option[T] { None, Some(T) }` 时 Some/None 仍是它的变体）。
        // 类型信息：`None` = TYP_NULL（null 单点类型，`T ∪ null` 里的 null）；`Some(x)` =
        // TYP_OPTIONAL(携带值行)，因此`Some(1)` 的类型 = `int?`（计划用例Some(1) 满足 int?）。
        // 表示方式：运行时形态沿用 EXPR_ENUM_CONSTRUCTOR 路径，ir_gen 生成 IR_MAKE_ENUM 和
        // 字段存；EXPR_TRY 的 IR 是内层表达式。本层只落实类型层的联合和可选语义，运行期
        // 表示统一（Some 值对裸值）尚未覆盖。
        if str_eq(name, "Some") != 0:
            at : ., mut = TI_UNIT
            if arg_count == 1 && first_arg >= 0:
                at = infer_expr(ast_a(first_arg))
            else if arg_count > 1:
                // 多携带值（`Some(a, b)`）：携带值行 = TYP_TUPLE（两趟落盘，照 EXPR_TUPLE 契约，
                // 元素推断自身可向 g_gen_apply_data 追加数据，不得边推边写；见该分支注记）。
                tis : string, mut = alloc(arg_count * 8)
                ai : ., mut = 0
                an2 : ., mut = first_arg
                loop:
                    if ai >= arg_count:
                        break
                    ev : ., mut = TI_UNIT
                    if an2 >= 0:
                        ev = infer_expr(ast_a(an2))
                        an2 = ast_b(an2)
                    cell_store(tis, ai * 8, ev)
                    ai = ai + 1
                ds := g_gen_apply_data_count
                grow_gen_apply_data(ds + arg_count)
                ai = 0
                loop:
                    if ai >= arg_count:
                        break
                    cell_store(g_gen_apply_data, (ds + ai) * 8, cell_load(tis, ai * 8))
                    ai = ai + 1
                g_gen_apply_data_count = ds + arg_count
                at = alloc_type(TYP_TUPLE, arg_count, ds)
            return alloc_type(TYP_OPTIONAL, at, 0)
        if str_eq(name, "None") != 0:
            return alloc_type(TYP_NULL, 0, 0)
        check_error(EC_N_UNDEFINED, "Undefined enum constructor '" + name + "'", ast_line(node), ast_col(node))
        return TI_UNIT

    if ast_kind(node) == EXPR_FIELD:
        obj := ast_a(node)
        field_ni := ast_int_val(node)
        obj_ti := infer_expr(obj)
        // Auto-deref: if obj is a reference type, unwrap to inner type
        actual_ti : ., mut = obj_ti
        if actual_ti >= 0 && actual_ti < g_type_count && get_type_kind(actual_ti) == TYP_REF:
            actual_ti = get_type_data(actual_ti)
        // V4 `.len` on sequences. Named structs with a real `len` field fall
        // through to the normal field lookup; the builtin only claims
        // array/slice/string and unresolved generic receivers.
        fnm := istr_get(field_ni)
        if str_eq(fnm, "len") != 0:
            klen := get_type_kind(actual_ti)
            if actual_ti == TI_STR || klen == TYP_ARRAY || klen == TYP_SLICE || klen == TYP_GENERIC_PARAM:
                ast_set_data(node, -1)
                ast_set_type_val(node, 0)
                ast_set_c(node, -1)
                return TI_INT
        // Handle generic apply: unwrap to base named type for struct lookup.
        // `apply_ti` keeps the generic apply row: field substitution needs the
        // arguments, and a `&self` receiver only becomes an apply after the
        // auto-deref above.
        apply_ti : ., mut = actual_ti
        if actual_ti >= 0 && actual_ti < g_type_count && get_type_kind(actual_ti) == TYP_GENERIC_APPLY:
            actual_ti = get_type_data(actual_ti)
        if actual_ti >= 0 && actual_ti < g_type_count && get_type_kind(actual_ti) == TYP_NAMED:
            struct_ni := get_type_data(actual_ti)
            si := find_struct(struct_ni)
            if si >= 0:
                // A hidden struct type can still flow across libraries through a
                // pub function's return value. Field access must not expose its
                // layout in that case.
                if g_cur_lib >= 0:
                    towner := decl_owner_for_unique(struct_ni)
                    if towner >= 0 && towner != g_cur_lib:
                        if lib_can_import(g_cur_lib, towner) == 0 || lib_export_find_kind(towner, decl_src_for_unique(struct_ni), SYM_TYPE) < 0:
                            check_error(EC_N_FIELD, "Undefined field '" + istr_get(field_ni) + "'", ast_line(node), ast_col(node))
                            return ti_error()
                fi : ., mut = 0
                loop:
                    if fi >= si_field_count(si):
                        break
                    if si_field_name(si, fi) == field_ni:
                        if g_cur_lib >= 0:
                            fowner := decl_owner_for_unique(struct_ni)
                            if fowner >= 0 && fowner != g_cur_lib && si_field_pub(si, fi) == 0:
                                check_error(EC_N_FIELD, "Undefined field '" + istr_get(field_ni) + "'", ast_line(node), ast_col(node))
                                return ti_error()
                        ast_set_data(node, fi)  // store field index for ir_gen
                        ast_set_c(node, struct_ni)  // store struct name for ELF backend
                        // Resolve field type, substituting generic params if needed
                        ft_node := si_field_type_node(si, fi)
                        if ft_node >= 0:
                            if ast_kind(ft_node) == EXPR_IDENT:
                                ft_name_idx := ast_int_val(ft_node)
                                // Check if this field type is a generic param (substitute if we have a generic apply)
                                if is_struct_generic(si, ft_name_idx) && get_type_kind(apply_ti) == TYP_GENERIC_APPLY:
                                    base_ti := get_type_data(apply_ti)
                                    ga_start := get_type_extra(apply_ti)
                                    ga_count := cell_load(g_gen_apply_data, ga_start * 8)
                                        // Find which generic param index
                                    gpi : ., mut = 0
                                    loop:
                                        if gpi >= si_generic_count(si):
                                            break
                                        if si_generic_name(si, gpi) == ft_name_idx:
                                                // Use the corresponding arg from the generic apply
                                            if gpi < ga_count:
                                                return cell_load(g_gen_apply_data, (ga_start + 1 + gpi) * 8)
                                            break
                                        gpi = gpi + 1
                            return res_type_node(ft_node)
                        return si_field_type(si, fi)
                    fi = fi + 1
        // Tuple field access: t.0, t.1
        if actual_ti >= 0 && actual_ti < g_type_count && get_type_kind(actual_ti) == TYP_TUPLE:
            field_name := istr_get(field_ni)
            idx := str_int(field_name)
            tc := get_type_data(actual_ti)
            if idx >= 0 && idx < tc:
                data_start := get_type_extra(actual_ti)
                if ast_data(node) != idx:
                    ast_set_data(node, idx)
                elem_ti := cell_load(g_gen_apply_data, (data_start + idx) * 8)
                // Numeric tuple indices reuse ast_c to carry the element type
                // row to ir_gen. Tuple elements are stored in exact form, so a
                // dex element must be read as TI_DEX_S: reading it as TI_INT
                // would make the tagged-int path untag a raw scaled word.
                ast_set_c(node, elem_ti)
                return elem_ti
        return TI_UNIT

    if ast_kind(node) == EXPR_INDEX:
        arr_ti := infer_expr(ast_a(node))
        idx_ti := infer_expr(ast_b(node))
        arr_kind := get_type_kind(arr_ti)
        // Range index: arr[low..high] -> slice type
        if ast_kind(ast_b(node)) == EXPR_RANGE:
            // 类别判定换位到序列形状（数组/切片同属 AK_SEQUENCE；
            // sh_shape_seq = ⊤ₖ(AK_SEQUENCE)，见 iface_registry.cr 的横切形状段）。
            // 固定性维度（N vs 视图）取自序列项的 b 槽（sh_seq_fixed_len_of_ti，表示层提示，
            // 语义判定不看 N：spec 第 5.1 节 + T1 的固定性位登记）。行为保持：仅固定长序列
            // （数组）在 range 下产视图；切片/非序列现状 = TI_UNIT（IP_INDEX_RANGE 未接线，
            // 登记数据 A.2 #15）。判定约定：形状 -1（不可译行）不折算，回落旧 kind 直比
            // （该处改动前由 `arr_kind == TYP_ARRAY` 独判，因此回落后逐条记录结论相同）。
            seq_ok : ., mut = iface_satisfies_term(arr_ti, sh_shape_seq())
            if seq_ok == -1 && arr_kind == TYP_ARRAY:
                seq_ok = 1
            if seq_ok == 1 && sh_seq_fixed_len_of_ti(arr_ti) >= 0:
                // F11：字面量切片界编译期验证（TK05/06 既有错误码）
                arr_len : ., mut = get_type_extra(arr_ti)
                rn := ast_b(node)
                if arr_len > 0 && ast_kind(ast_a(rn)) == EXPR_INT && ast_kind(ast_b(rn)) == EXPR_INT:
                    lo := ast_int_val(ast_a(rn))
                    hi := ast_int_val(ast_b(rn))
                    if lo < 0 || hi > arr_len:
                        check_error(EC_TK_SLICE_BOUNDS, "slice out of bounds: [" + int_str(lo) + ".." + int_str(hi) + "] (array length " + int_str(arr_len) + ")", ast_line(node), ast_col(node))
                    else if lo > hi:
                        check_error(EC_TK_SLICE_LEN, "slice length negative: [" + int_str(lo) + ".." + int_str(hi) + "]", ast_line(node), ast_col(node))
                return alloc_type(TYP_SLICE, get_type_data(arr_ti), 0)
            return TI_UNIT
        // Regular index: arr[i] or slice[i] -> element type
        if arr_kind == TYP_ARRAY:
            // F2：字面量索引编译期越界检查（数组长度编译期可知时）
            if ast_kind(ast_b(node)) == EXPR_INT:
                idx_val := ast_int_val(ast_b(node))
                arr_len : ., mut = get_type_extra(arr_ti)
                if arr_len > 0 && (idx_val < 0 || idx_val >= arr_len):
                    check_error(EC_R_OOB, "index out of bounds: " + int_str(idx_val) + " (array length " + int_str(arr_len) + ")", ast_line(node), ast_col(node))
            return get_type_data(arr_ti)
        if arr_kind == TYP_SLICE:
            return get_type_data(arr_ti)  // slice[i] -> element type
        if arr_ti == TI_STR:
            // A string is a byte sequence. Reject a statically known invalid
            // index instead of allowing a silent read past its terminator.
            if ast_kind(ast_a(node)) == EXPR_STRING && ast_kind(ast_b(node)) == EXPR_INT:
                string_len := istr_len(ast_int_val(ast_a(node)))
                string_idx := ast_int_val(ast_b(node))
                if string_idx < 0 || string_idx >= string_len:
                    check_error(EC_R_OOB,
                        "string index out of bounds: " + int_str(string_idx) +
                        " (length " + int_str(string_len) + ")",
                        ast_line(node), ast_col(node))
            return TI_INT  // string[i] -> byte value
        // 后备检查使用横切形状满足判定：可索引形状为 ⊤ₖ(SEQUENCE) ∪ ⊤ₖ(STRING)，
        // 定义在 iface_registry.cr 的横切形状段。可达集是上方三个结果分支
        // （arr->elem+F2、slice->elem、str->int）之后的落空集；形状的拒绝集与该可达集逐条记录
        // 相等，由 selftest x2.indexable_matches_ops 和 idx.gate_deny_covers_fallback 检查。
        // 形状返回 -1 表示不可判，例如不可译行；此时不折算成 0 或 1，而是回落既有许可表，
        // 结论与改动前逐条记录相同。
        // A generic parameter's sequence shape is only known after
        // instantiation. The template body must not emit TK01 here: the
        // monomorphized instance carries the real array/slice type. Keep the
        // existing int fallback so int-element templates type-check; non-int
        // element bodies are resolved on the specialized AST.
        if get_type_kind(arr_ti) == TYP_GENERIC_PARAM:
            return TI_INT
        idx_ok : ., mut = iface_satisfies_term(arr_ti, sh_shape_indexable())
        if idx_ok == -1:
            idx_ok = iface_permits(iface_kind_of(arr_ti), IP_INDEX)
        if idx_ok != 1:
            check_error(EC_TK_INDEX, "Cannot index non-array type", ast_line(node), ast_col(node))
        return TI_INT

    if ast_kind(node) == EXPR_ASSIGN:
        target := ast_a(node)
        val := ast_b(node)
        // Immutable bindings: `:=` and un-tagged `: T =` are not assignable.
        // Parameters, match bindings and loop variables carry the compatible
        // default (mutable); only EXPR_LET/global declarations set mut = 0.
        if ast_kind(target) == EXPR_IDENT:
            tsi := find_sym(ast_int_val(target))
            if tsi >= 0 && sym_mut_field(tsi) == 0:
                check_error(EC_TA_IMMUTABLE, "Cannot assign to immutable variable '" + istr_get(ast_int_val(target)) + "'", ast_line(node), ast_col(node))
        tt := infer_expr(target)
        vt := infer_expr(val)
        if tt == TI_DYN:
            // dyn assignment: track the RHS type, skip strict type check
            if ast_kind(target) == EXPR_IDENT:
                target_ni := ast_int_val(target)
                target_si := find_sym(target_ni)
                if target_si >= 0:
                    dyn_set_type(target_si, vt)
        else:
            // Generic templates defer assignment compatibility to the
            // monomorphized instance, where element/field types are concrete.
            if cur_fn_is_generic() == 0:
                // 参序归一：赋值 = 目标(tt) ← 值(vt)，因此源 = vt，目标 = tt
                compat := type_compat_strict(vt, tt)
                if compat != 1:
                    diag_type_incompatible(compat, EC_TA_ASSIGN, "Assignment type mismatch", ast_line(node), ast_col(node))
        return vt

    if ast_kind(node) == EXPR_STRUCT:
        // Struct literal: a = name idx, b = first field wrapper, c = field count.
        // wrapper 在 g_ast 中连续，wrapper.a 是字段值节点。不能按偏移取下一个节点当字段值：
        // 复合字段值（调用或字面量）占多个槽，会整体错位并产生值错误且不报错。
        // wrapper.b 是字段名 idx，parser 写入，-1 表示没有名字信息。名字齐备时校验未知字段
        // TS02、重复字段 TS04、缺字段 TS01，并用 type_compat_strict 比对字段类型 TS03。
        // 值按名字绑定到声明下标，ir_gen 也按名字取字段位。名字缺失时回落位序，不做名字类校验。
        name_ni := ast_a(node)
        si : ., mut = find_struct_by_name(name_ni)
        ast_set_data(node, si)
        if si < 0:
            check_error(EC_N_UNDEFINED, "Undefined type '" + istr_get(name_ni) + "'", ast_line(node), ast_col(node))
        c := ast_c(node)
        w0 := ast_b(node)
        // 名字信息齐备？（parser 恒写；克隆体丢名字 -> 回落位序、不做名字类校验）
        named : ., mut = 0
        if w0 >= 0 && c > 0:
            named = 1
            ni2 : ., mut = 0
            loop:
                if ni2 >= c:
                    break
                if ast_b(w0 + ni2) < 0:
                    named = 0
                    break
                ni2 = ni2 + 1
        // didx[i] = 字面量第 i 个字段 -> 声明字段下标（默认位序 = 无名字信息时的既有语义）
        didx : string, mut = alloc((c + 1) * 8)
        i : ., mut = 0
        loop:
            if i >= c:
                break
            cell_store(didx, i * 8, i)
            i = i + 1
        if si >= 0 && (named != 0 || c == 0):
            // ── 名字 -> 声明下标：未知字段 / 重复字段 / 缺字段 ──
            fc := si_field_count(si)
            used : string, mut = alloc((fc + 1) * 8)
            j : ., mut = 0
            loop:
                if j >= fc:
                    break
                cell_store(used, j * 8, 0)
                j = j + 1
            if named != 0:
                i = 0
                loop:
                    if i >= c:
                        break
                    nn := ast_b(w0 + i)
                    jdi : ., mut = struct_field_index_by_name(si, nn)
                    if jdi >= 0 && g_cur_lib >= 0:
                        sowner := decl_owner_for_unique(si_name(si))
                        if sowner >= 0 && sowner != g_cur_lib && si_field_pub(si, jdi) == 0:
                            check_error(EC_TS_UNKNOWN_FIELD, "Unknown field '" + istr_get(nn) + "' in struct literal " + istr_get(name_ni), ast_line(w0 + i), ast_col(w0 + i))
                            cell_store(used, jdi * 8, 1)
                            jdi = -1
                    if jdi < 0:
                        check_error(EC_TS_UNKNOWN_FIELD, "Unknown field '" + istr_get(nn) + "' in struct literal " + istr_get(name_ni), ast_line(w0 + i), ast_col(w0 + i))
                    else:
                        if cell_load(used, jdi * 8) != 0:
                            check_error(EC_TS_FIELD_DUP, "Field '" + istr_get(nn) + "' initialized more than once", ast_line(w0 + i), ast_col(w0 + i))
                        cell_store(used, jdi * 8, 1)
                        cell_store(didx, i * 8, jdi)
                    i = i + 1
            j = 0
            loop:
                if j >= fc:
                    break
                if cell_load(used, j * 8) == 0:
                    // 只报第一个缺字段（同一程序员错误不刷屏）
                    check_error(EC_TS_MISSING_FIELD, "Missing field '" + istr_get(si_field_name(si, j)) + "' in struct literal " + istr_get(name_ni), ast_line(node), ast_col(node))
                    break
                j = j + 1
        // ── 值类型逐个推断（一次/字段：infer_expr 有副作用，勿重复推断；结构体名未找到时
        //  也要推断，嵌套诊断和 dyn 记录等副作用在此，不能丢弃）──
        vts : string, mut = alloc((c + 1) * 8)
        i = 0
        loop:
            if i >= c:
                break
            if w0 >= 0:
                cell_store(vts, i * 8, infer_expr(w0 + i))
            i = i + 1
        if si >= 0:
            gc := si_generic_count(si)
            if gc > 0:
                // ── 泛型结构体：字段类型 = 泛型参数 -> 绑定（重复绑定走 unify 已绑定路径比对）──
                g_gen_map_count = 0
                g_gen_map_cap = 0
                i = 0
                loop:
                    if i >= c:
                        break
                    jdi := cell_load(didx, i * 8)
                    if jdi >= 0 && jdi < si_field_count(si):
                        dtn := si_field_type_node(si, jdi)
                        if dtn >= 0 && ast_kind(dtn) == EXPR_IDENT && is_struct_generic(si, ast_int_val(dtn)):
                            pt := alloc_type(TYP_GENERIC_PARAM, ast_int_val(dtn), 0)
                            if !unify_types(pt, cell_load(vts, i * 8)):
                                check_error(EC_TS_FIELD_TYPE, "Field '" + istr_get(si_field_name(si, jdi)) + "': expected " + istr_get(ast_int_val(dtn)) + ", got " + type_display(cell_load(vts, i * 8)), ast_line(w0 + i), ast_col(w0 + i))
                    i = i + 1
            // ── 非参数声明类型：值类型 vs 声明类型比对（两侧任一含未实例化泛型参数 -> 跳过）──
            i = 0
            loop:
                if i >= c:
                    break
                jdi := cell_load(didx, i * 8)
                if jdi >= 0 && jdi < si_field_count(si):
                    dtn := si_field_type_node(si, jdi)
                    is_param : ., mut = 0
                    if dtn >= 0 && ast_kind(dtn) == EXPR_IDENT && is_struct_generic(si, ast_int_val(dtn)):
                        is_param = 1
                    if is_param == 0 && type_node_mentions_struct_param(si, dtn) == 0:
                        vt := cell_load(vts, i * 8)
                        if ti_has_generic_param(vt) == 0:
                            dt := res_type_node(dtn)
                            if ti_has_generic_param(dt) == 0:
                                // 参序归一：源 = 值类型(vt)，目标 = 声明类型(dt)
                                verdict := type_compat_strict(vt, dt)
                                if verdict != 1:
                                    diag_type_incompatible(verdict, EC_TS_FIELD_TYPE, "Field '" + istr_get(si_field_name(si, jdi)) + "': expected " + type_display(dt) + ", got " + type_display(vt), ast_line(w0 + i), ast_col(w0 + i))
                i = i + 1
            if gc > 0:
                // 结果类型 TYP_GENERIC_APPLY：实参按参数声明序取映射。按字面量字段序写映射
                // 会在参数序和字段序不同时造成实参错位。
                base_ti := alloc_named_type(si_name(si))
                ds := g_gen_apply_data_count
                grow_gen_apply_data(ds + 1 + gc)
                g_gen_apply_data_count = ds + 1
                found : ., mut = 0
                g : ., mut = 0
                loop:
                    if g >= gc:
                        break
                    pni := si_generic_name(si, g)
                    bind : ., mut = -1
                    mi : ., mut = 0
                    loop:
                        if mi >= g_gen_map_count:
                            break
                        if cell_load(g_gen_map_names, mi * 8) == pni:
                            bind = cell_load(g_gen_map_types, mi * 8)
                            break
                        mi = mi + 1
                    if bind >= 0:
                        cell_store(g_gen_apply_data, (ds + 1 + found) * 8, bind)
                        found = found + 1
                    g = g + 1
                cell_store(g_gen_apply_data, ds * 8, found)
                g_gen_apply_data_count = ds + 1 + found
                return alloc_type(TYP_GENERIC_APPLY, base_ti, ds)
            return alloc_named_type(si_name(si))
        // 结构体名未找到：既有行为（不在此报错，返回具名类型）
        return alloc_named_type(name_ni)

    if ast_kind(node) == EXPR_ARRAY:
        // Array literal: a = first wrapper（连续）, b = elem count. wrapper.a 是元素值节点。
        // 不能按偏移取相邻节点当元素：复合元素子树占多个槽，会整体错位并产生类型或值错误。
        // 首元素类型作为元素类型（空字面量沿用 int），后续元素逐个与首元素比对，错误码 TK02。
        // 这样异质字面量不会通过，也不会让元素类型随最后一个元素漂移。
        elem_ti : ., mut = TI_INT   // 空字面量 []：沿用旧默认
        ei : ., mut = 0
        en : ., mut = ast_a(node)
        loop:
            if ei >= ast_b(node):
                break
            if en >= 0:
                eti := infer_expr(en)
                if ei == 0:
                    elem_ti = eti
                else:
                    // 两侧任一含未实例化泛型参数 -> 跳过（不假拒，见 ti_has_generic_param）
                    if ti_has_generic_param(elem_ti) == 0 && ti_has_generic_param(eti) == 0:
                        // 参序归一：源 = 本元素(eti)，目标 = 首元素定下的元素类型(elem_ti)
                        verdict := type_compat_strict(eti, elem_ti)
                        if verdict != 1:
                            diag_type_incompatible(verdict, EC_TK_ELEM_TYPE, "Expected array element type " + type_display(elem_ti) + ", got " + type_display(eti), ast_line(en), ast_col(en))
                en = en + 1
            ei = ei + 1
        // `[T; N]` is an inline storage representation hint, not a type
        // constructor. Its semantics belong to product types, sequence types with
        // length constraints, or F11 length facts. See the full note at
        // res_type_node's EXPR_ARRAY branch.
        return alloc_type(TYP_ARRAY, elem_ti, ast_b(node))

    if ast_kind(node) == EXPR_BREAK:
        return TI_NEVER   // 发散出口，类型为 never
    if ast_kind(node) == EXPR_CONTINUE:
        return TI_NEVER   // 同上
    if ast_kind(node) == EXPR_WILDCARD:
        return TI_UNIT
    if ast_kind(node) == EXPR_UNSAFE:
        push_unsafe_scope()
        ret := infer_expr(ast_a(node))
        pop_unsafe_scope()
        return ret
    if ast_kind(node) == EXPR_TRY:
        // ? 解包按类型项结构处理，不按基名字符串判断。语义：T? = T ∪ null，
        // 解包取非 null 的析取支。记录数据有两种承载：
        //   TYP_OPTIONAL（data = 内层行）-> 返回内层 T；
        //   TYP_NULL（null 单点类型，无值可取）-> 不解包，返回原行。解包 null 的结果是空类型，
        //   但本层的 never 和 ⊥ 行在引擎侧不是真 ⊥（AK_NEVER 仍按原子类判包含），判 never
        //   会引入新的拒绝路径，因此保守不动。None? 的类型仍是 null 自身。
        // 其余命名行、泛型应用行和原生行一律不解包。用户枚举不按名字猜语义。
        inner_ti := infer_expr(ast_a(node))
        if get_type_kind(inner_ti) == TYP_OPTIONAL:
            return get_type_data(inner_ti)
        return inner_ti
    if ast_kind(node) == EXPR_STRUCTPAT:
        // Patterns are not value expressions. Match-arm validation/binding lives
        // in the EXPR_MATCH branch (check_struct_pattern / bind_struct_pattern_idents).
        return TI_UNIT
    if ast_kind(node) == EXPR_TUPLEPAT:
        // Tuple patterns are not value expressions either. Match-arm
        // validation/binding lives in EXPR_MATCH (check_tuple_pattern /
        // bind_tuple_pattern_idents).
        return TI_UNIT
    if ast_kind(node) == EXPR_AS:
        // `expr cast Type`: whitelist only. The old behavior accepted every
        // type pair and copied the bits, which is silent reinterpretation
        // (`1.5 as int` returned 96), not a conversion.
        inner_ti := infer_expr(ast_a(node))
        type_node := ast_b(node)
        target_ti := res_type_node(type_node)
        if inner_ti < 0 || target_ti < 0:
            return ti_error()
        if inner_ti == TI_NEVER:
            return target_ti
        if inner_ti == target_ti:
            return target_ti
        inner_kind := get_type_kind(inner_ti)
        target_kind := get_type_kind(target_ti)
        // int <-> dex. The conversion is exact by construction; the generator
        // emits I2F/F2I.
        if inner_ti == TI_INT && target_ti == TI_DEX:
            return TI_DEX
        if inner_ti == TI_DEX && target_ti == TI_INT:
            return TI_INT
        // int <-> char. Temporary: the runtime value of char is the intern
        // index, not a code point. Kept because match compares character
        // literals through this conversion; see the 2026-10-27 cast plan.
        if inner_ti == TI_INT && target_ti == TI_CHAR:
            return TI_CHAR
        if inner_ti == TI_CHAR && target_ti == TI_INT:
            return TI_INT
        // Pointer family. The cast itself is not the safety boundary: an
        // external address may be formed anywhere, and the dereference check
        // (TU03) requires `unsafe`. This keeps the existing pointer model.
        if target_kind == TYP_PTR:
            asp : ., mut = 1
            if inner_kind == TYP_PTR:
                asp = get_type_extra(inner_ti)
            else if inner_kind == TYP_REF:
                asp = 0
            else if inner_ti == TI_STR:
                // alloc() returns a string buffer; viewing it as a pointer is
                // the tracked-pointer path, not an external address.
                asp = 0
            else if inner_ti != TI_INT:
                check_error(EC_TA_CAST, "cast from " + type_display(inner_ti) + " to " + type_display(target_ti) + " is not allowed", ast_line(node), ast_col(node))
                return ti_error()
            return alloc_type(TYP_PTR, get_type_data(target_ti), asp)
        check_error(EC_TA_CAST, "cast from " + type_display(inner_ti) + " to " + type_display(target_ti) + " is not allowed", ast_line(node), ast_col(node))
        return ti_error()
    if ast_kind(node) == EXPR_STMT:
        infer_expr(ast_a(node))
        return TI_UNIT
    if ast_kind(node) == EXPR_TUPLE:
        // Tuple: create a TYP_TUPLE type with element types
        // F5 契约：a=首 wrapper（g_ast 中连续）、b=元素个数；wrapper.a = 元素值节点。
        // 复合元素（如 [1,2,3]）的值节点自身不连续，必须经 wrapper 解引用，
        // 直读 `elem_idx + e` 会把元素子节点当元素（类型错录 -> 假拒 + soundness 漏放）。
        elem_idx := ast_a(node)
        ec : ., mut = ast_b(node)
        // 元素类型分两趟记录。先逐个推断；元素推断可能向 g_gen_apply_data 追加数据，
        // 例如嵌套元组、泛型应用和泛型结构字面量的 g_gen_map 段。推断完再一次性连续落盘。
        // 在循环前取 data_start 边推边写会让前面的元素追加的数据顶开后续元素的位置，
        // extra 和实际位置错位。例如 ((2,3),1) 的元素表会被读成内层元组的字段。
        tis : string, mut = alloc(ec * 8)
        e : ., mut = 0
        loop:
            if e >= ec:
                break
            wn : ., mut = -1
            if elem_idx >= 0:
                wn = ast_a(elem_idx + e)
            cell_store(tis, e * 8, infer_expr(wn))
            e = e + 1
        data_start := g_gen_apply_data_count
        grow_gen_apply_data(data_start + ec)
        e = 0
        loop:
            if e >= ec:
                break
            cell_store(g_gen_apply_data, (data_start + e) * 8, cell_load(tis, e * 8))
            e = e + 1
        g_gen_apply_data_count = data_start + ec
        return alloc_type(TYP_TUPLE, ec, data_start)

    if ast_kind(node) == EXPR_AT:
        name_ni := ast_a(node)
        name := istr_get(name_ni)
        args := ast_b(node)

        // @sizeOf(T) — 1 type argument
        if str_eq(name, "sizeOf") != 0:
            if args < 0:
                check_error(EC_N_UNDEFINED, "@sizeOf requires a type argument", ast_line(node), ast_col(node))
                return ti_error()
            ti := res_type_node(args)
            if ti < 0:
                check_error(EC_N_UNDEFINED, "@sizeOf: unknown type", ast_line(node), ast_col(node))
                return ti_error()
            return TI_INT

        // @addr(fn) — function address, type int
        if str_eq(name, "addr") != 0:
            ast_set_type_val(node, TI_INT)  // function address is an int
            return TI_INT

        // @alignOf(T) — 1 type argument
        if str_eq(name, "alignOf") != 0:
            if args < 0:
                check_error(EC_N_UNDEFINED, "@alignOf requires a type argument", ast_line(node), ast_col(node))
                return ti_error()
            ti := res_type_node(args)
            if ti < 0:
                check_error(EC_N_UNDEFINED, "@alignOf: unknown type", ast_line(node), ast_col(node))
                return ti_error()
            return TI_INT

        // @fields(T) — 1 type argument, returns []string
        if str_eq(name, "fields") != 0:
            if args < 0:
                check_error(EC_N_UNDEFINED, "@fields requires a type argument", ast_line(node), ast_col(node))
                return ti_error()
            ti := res_type_node(args)
            return TI_STR

        // @hasField(T, name) — type + string
        if str_eq(name, "hasField") != 0:
            if args < 0 || ast_b(args) < 0:
                check_error(EC_N_UNDEFINED, "@hasField requires 2 args", ast_line(node), ast_col(node))
                return ti_error()
            ti := res_type_node(ast_a(args))
            return TI_BOOL

        // @field(T, name) — type + string, returns FieldInfo
        if str_eq(name, "field") != 0:
            if args < 0 || ast_b(args) < 0:
                check_error(EC_N_UNDEFINED, "@field requires 2 args", ast_line(node), ast_col(node))
                return ti_error()
            ti := res_type_node(ast_a(args))
            return TI_INT

        // @typeInfo(T) — returns TypeInfo
        if str_eq(name, "typeInfo") != 0:
            if args < 0:
                check_error(EC_N_UNDEFINED, "@typeInfo requires a type argument", ast_line(node), ast_col(node))
                return ti_error()
            ti := res_type_node(args)
            // 返回类型是类型名串，与 ir_gen 的发射路径一致：该分支构造 "int"、"bool" 等，
            // 或返回命名行的名字。消费点例如 str_len(@typeInfo(X)) 和 println(@typeInfo(X))
            // 按 string 使用该结果。
            return TI_STR

        // @raw_int(expr), dex 表达式 -> 缩放整数原值（显式转换）
        if str_eq(name, "raw_int") != 0:
            if args < 0:
                check_error(EC_N_UNDEFINED, "@raw_int requires an expression", ast_line(node), ast_col(node))
                return ti_error()
            av := infer_expr(ast_a(args))
            // 参数校验：具有原值语义的类型才可以取原值。
            //   dex：缩放位原值。
            //   int：原值即缩放值。
            //   地址型：TYP_PTR 和 TYP_REF 都接受。二者都是地址字，@raw_int 的语义相同。
            // TYP_SLICE、TYP_ARRAY 等聚合类型仍拒绝，它们没有统一的原值概念。
            // 类型表下标 0..8 是标量和占位行（TI_INT..TI_DEX_S），只有 av > TI_DEX_S 时才查表，
            // 避免用标量下标读到占位行的 kind。
            if av != TI_DEX && av != TI_INT && av != TI_NEVER:
                if !(av > TI_DEX_S && (get_type_kind(av) == TYP_PTR || get_type_kind(av) == TYP_REF)):
                    check_error(EC_TF_ARG_TYPE, "@raw_int requires a dex (or int) or address (pointer/reference) expression", ast_line(node), ast_col(node))
                    return ti_error()
            return TI_INT

        // @comptime(expr) — force compile-time eval
        if str_eq(name, "comptime") != 0:
            if args < 0:
                check_error(EC_N_UNDEFINED, "@comptime requires an expression", ast_line(node), ast_col(node))
                return ti_error()
            v := infer_expr(ast_a(args))
            ast_set_type_val(node, v)
            return v

        // @inline(fn) — inline hint
        if str_eq(name, "inline") != 0:
            if args < 0:
                check_error(EC_N_UNDEFINED, "@inline requires a function argument", ast_line(node), ast_col(node))
                return ti_error()
            v := infer_expr(ast_a(args))
            ast_set_type_val(node, v)
            return v

        // @NoBoundsCheck — no args, unit
        if str_eq(name, "NoBoundsCheck") != 0:
            return TI_UNIT

        // @fast — no args, unit
        if str_eq(name, "fast") != 0:
            return TI_UNIT

        // @unroll(n) — requires integer argument
        if str_eq(name, "unroll") != 0:
            if args < 0:
                check_error(EC_N_UNDEFINED, "@unroll requires an integer argument", ast_line(node), ast_col(node))
                return TI_UNIT
            return TI_UNIT

        // @section(name) — requires string argument
        if str_eq(name, "section") != 0:
            if args < 0:
                check_error(EC_N_UNDEFINED, "@section requires a string argument", ast_line(node), ast_col(node))
                return TI_UNIT
            return TI_UNIT

        // @hotpatch — function annotation, not an expression
        if str_eq(name, "hotpatch") != 0:
            return TI_UNIT

        // SYSTEM raw pointer add: both args are mathematical ints; the result is
        // a raw address word. Used by the scheduler to advance G pointers that
        // are stored in int slots.
        if str_eq(name, "ptr_add") != 0:
            if args < 0:
                check_error(EC_N_UNDEFINED, "@ptr_add requires 2 arguments", ast_line(node), ast_col(node))
                return ti_error()
            a2 := ast_b(args)
            if a2 < 0:
                check_error(EC_N_UNDEFINED, "@ptr_add requires 2 arguments", ast_line(node), ast_col(node))
                return ti_error()
            infer_expr(ast_a(args))
            infer_expr(ast_a(a2))
            return TI_INT

        // ── 2(a) 视图内建：同一个 64 位字的两种看法（零转换、零拷贝、零运行期动作）──
        //  `@ptr_of(s: string) -> int` · `@str_of(p: int) -> string`
        //  语义：不改那个字，只改它在本语言里的看法（原生 ELF 路径下 string 值 = 指针；
        //  解释器路径下 string 值 = intern 索引，因此视图对两条路径都是恒等， 见 2(a) 计划 第 2.2 节bis/第 2.2 节ter）。
        //  安全（team-lead 裁 (ii)）：必须出现在 `unsafe` 块内；块外，因此报错并终止编译（不做软约束，
        //  没有自动检查的约定会失效）。`g_unsafe_depth` 由 EXPR_UNSAFE 分支压栈维护。
        //  未知名仍走文件末尾的 fail-closed（EC_N_UNDEFINED），不得忽略。
        if str_eq(name, "ptr_of") != 0 || str_eq(name, "str_of") != 0:
            if g_unsafe_depth == 0:
                check_error(EC_N_UNDEFINED, "@" + name + " must appear inside an `unsafe` block", ast_line(node), ast_col(node))
                return ti_error()
            if args < 0:
                check_error(EC_N_UNDEFINED, "@" + name + " requires exactly 1 argument", ast_line(node), ast_col(node))
                return ti_error()
            av := infer_expr(ast_a(args))
            if str_eq(name, "ptr_of") != 0:
                if av != TI_STR && av != TI_NEVER:
                    check_error(EC_TF_ARG_TYPE, "@ptr_of requires a string expression", ast_line(node), ast_col(node))
                    return ti_error()
                return TI_INT
            if av != TI_INT && av != TI_NEVER:
                check_error(EC_TF_ARG_TYPE, "@str_of requires an int expression", ast_line(node), ast_col(node))
                return ti_error()
            return TI_STR

        check_error(EC_N_UNDEFINED, "unknown @ builtin: " + name, ast_line(node), ast_col(node))
        return TI_UNIT

    return TI_UNIT

// --- Main entry ---

fn check_all():
    init_types()
    // SYM_SO_FN entries are not moved before the reset. Materialization happens
    // after g_sym_count is reset, on the first lookup during checking. There is no
    // fixed-size preserve buffer, so a large symbol table cannot overflow a fixed
    // alloc(128 * 8).
    g_sym_count = 0
    // Unknown requester during declaration collection: visibility filtering
    // starts when a function body is checked and g_cur_lib is resolved.
    g_cur_lib = -1
    g_scope_depth = 0
    g_scope_bounds_cap = 0
    g_diag_count = 0
    g_diag_cap = 0
    g_gen_map_count = 0
    g_gen_map_cap = 0
    g_gen_apply_data_count = 0
    g_gen_apply_data_cap = 0
    g_gen_param_count = 0
    g_gen_param_cap = 0
    g_dyn_type_set_count = 0
    g_dyn_type_set_cap = 0
    g_dyn_type_sets = ""

    // First pass: collect declarations
    collect_decls()
    assign_unique_func_links()
    remap_impl_pairs()
    check_impl_visibility()
    check_impl_coherence()
    check_public_api_exposure()
    prelude_builtin_init()

    // SYM_SO_FN is materialized by the side-table fallback in find_gsym and
    // find_so_fn on first reference, which naturally happens after the reset.

    // Register public ABI builtins as proper SYM_FN (no .cr body, implemented
    // in rt.s). Raw/system builtins stay out of the symbol table: user code
    // cannot name them, and @std/@core reach them through the prelude query.
    // These must come after collect_decls so user-defined funcs take priority.
    ri2 : ., mut = 0
    loop:
        if ri2 >= g_rt_builtin_count:
            break
        ni2 := cell_load(g_rt_builtin_names, ri2 * 8)
        ti2 := cell_load(g_rt_builtin_ret_types, ri2 * 8)
        vis2 := cell_load(g_rt_builtin_vis, ri2 * 8)
        if vis2 == BUILTIN_VIS_PUBLIC && find_gsym(ni2) < 0:
            // skip if already defined by user
            si2 := g_sym_count
            grow_syms(si2 + 1)
            sym_set_name(si2, ni2)
            sym_set_kind(si2, SYM_FN)
            sym_set_type(si2, ti2)
            sym_set_node(si2, -1)
            g_sym_count = si2 + 1
        ri2 = ri2 + 1

    // Second pass: check function bodies
    i : ., mut = 0
    loop:
        if i >= g_func_count:
            break
        check_func(i)
        i = i + 1

    // Check global let initializers
    i = 0
    loop:
        if i >= g_global_let_count:
            break
        check_global_let(cell_load(g_global_lets, i * 8))
        i = i + 1

    // Check impl-for relationships
    check_impl_for()

    // 规约标注检查（形态 + 常量折叠的唯一判定点）。见 spec_check_all 头注。
    spec_check_all()

// ─── 规约标注（`#check` / `#ensure`）────────────────────────────────────
// 约束检查边界：
//   1. 判定逻辑只做常量折叠。唯一的红是 #check(常量假)，其余情况记为未证，不报错。
//   2. 未证不走诊断通道，只进入 --dump-vcs；否则 fail-closed 检查会把未证变成 rc=1。
//   3. 表达式子集不允许调用，纯度项为无效果。纯度时序问题尚未解决，当前只绕开：
//      生成期 fi_ispure 是乐观默认值。
//   4. 折叠器是纯函数式，不改 AST、不建 IR、不写图和表，零足迹。

// 折叠结果侧信道：`g_spec_fold_ok` = 0 表示本次折叠不可用（含子表达式不可折叠）。
// 显式侧信道而非哨兵值（int 全域都是合法值，因此哨兵必然歧义）。
g_spec_fold_ok : int, mut

// 常量折叠（int/bool 域；不可折叠，因此g_spec_fold_ok = 0）。
// 覆盖 = C1 子集里字面量闭合的形态：int/bool 字面量 · 一元 `-`/`!` · 二元 算术/比较/逻辑。
// 不做代数化简（如 `x*0`），只折字面量，避免把未证误升为已证。
fn spec_fold_val(e: int) -> int:
    g_spec_fold_ok = 0
    if e < 0:
        return 0
    k := ast_kind(e)
    if k == EXPR_INT:
        g_spec_fold_ok = 1
        return ast_int_val(e)
    if k == EXPR_BOOL:
        g_spec_fold_ok = 1
        return ast_int_val(e)
    if k == EXPR_UNARY:
        op := ast_c(e)
        v := spec_fold_val(ast_a(e))
        if g_spec_fold_ok == 0:
            return 0
        if op == UOP_NEG:
            g_spec_fold_ok = 1
            return 0 - v
        if op == UOP_NOT:
            g_spec_fold_ok = 1
            if v == 0:
                return 1
            return 0
        g_spec_fold_ok = 0
        return 0
    if k == EXPR_BINARY:
        op := ast_c(e)
        l := spec_fold_val(ast_a(e))
        if g_spec_fold_ok == 0:
            return 0
        r := spec_fold_val(ast_b(e))
        if g_spec_fold_ok == 0:
            return 0
        if op == OP_ADD:
            g_spec_fold_ok = 1
            return l + r
        if op == OP_SUB:
            g_spec_fold_ok = 1
            return l - r
        if op == OP_MUL:
            g_spec_fold_ok = 1
            return l * r
        if op == OP_DIV:
            if r == 0:
                g_spec_fold_ok = 0
                return 0
            g_spec_fold_ok = 1
            return l / r
        if op == OP_MOD:
            if r == 0:
                g_spec_fold_ok = 0
                return 0
            g_spec_fold_ok = 1
            return l % r
        if op == OP_EQ:
            g_spec_fold_ok = 1
            if l == r:
                return 1
            return 0
        if op == OP_NE:
            g_spec_fold_ok = 1
            if l != r:
                return 1
            return 0
        if op == OP_LT:
            g_spec_fold_ok = 1
            if l < r:
                return 1
            return 0
        if op == OP_GT:
            g_spec_fold_ok = 1
            if l > r:
                return 1
            return 0
        if op == OP_LE:
            g_spec_fold_ok = 1
            if l <= r:
                return 1
            return 0
        if op == OP_GE:
            g_spec_fold_ok = 1
            if l >= r:
                return 1
            return 0
        if op == OP_AND:
            g_spec_fold_ok = 1
            if l != 0 && r != 0:
                return 1
            return 0
        if op == OP_OR:
            g_spec_fold_ok = 1
            if l != 0 || r != 0:
                return 1
            return 0
        g_spec_fold_ok = 0
        return 0
    return 0   // 变量 / 调用 / 字段 / 下标 / 字面量外一切，因此未证

// 规约标注检查：逐条走侧表。唯一的编译失败条件是 #check(常量假)，错误码 V01。
// #ensure 的常量假同样可以判定且必然错误，与 #check 同判。
fn spec_check_all():
    i : ., mut = 0
    loop:
        if i >= g_spec_count:
            break
        // T3：`#ensure` 的常量假同样可判定且必错，因此与 `#check` 同判（T2 只判了 #check）。
        ex := spec_expr(i)
        v := spec_fold_val(ex)
        if g_spec_fold_ok != 0:
            if v == 0:
                spec_set_status(i, SPEC_ST_RED)
                nm : ., mut = "#check(...)"
                if spec_kind(i) == 1:
                    nm = "#ensure(...)"
                check_error(EC_V_CHECK_FALSE, nm + " is statically false", spec_line(i), spec_col(i))
            else:
                spec_set_status(i, SPEC_ST_GREEN)
        i = i + 1

// True purity computation.
// An impure call adds a state dependency. External functions that cannot be
// resolved are conservatively treated as impure.
//
// Pure (1) means all of the following hold. All judgments use IR and DF data and
// are conservative:
//  1. 体无 store 族：IR_STORE / IR_STORE_FIELD / IR_STORE_INDEX /
//   IR_STORE_INDEX_VAR / IR_STORE_PTR（裸指针写同为效应）；无 unsafe 区
//   （IR 无 unsafe 专用 opcode，按 SG_UNSAFE 区的归属函数判定）。
//  2. 体无 IO/FFI/并发效应 opcode：IR_CALL_EXTERN / IR_HOTPATCH_ROUTE /
//   IR_DYN_DISPATCH / IR_SPAWN / IR_YIELD / IR_AWAIT / IR_INLINE 见 3。
//  3. 传递闭包内被调者全纯：IR_CALL 的 s3 = 名 ni 经 find_func 解析（不可解析 =
//   runtime builtin，因此不纯）；IR_INLINE 亦按 s1 经 find_func 解析，但 s1 的
//   含义依发射点分两形：调用旗标形（ir_gen.cr:1523）s1 = 函数名 ni；
//   @inline(expr) 形（ir_gen.cr:1373）s1 = 变量索引，该形必然解析失败，被保守判不纯。
//   误差方向是安全的。
//  4. 递归/SCC，因此保守不纯：不动点从全不纯起点升纯，自环/互环永远等不到
//   被调者已纯，因此自动留在不纯，无需显式 SCC 检测。
// 泛型源函数（无 IR 体、永不被调用，调用点解析到实例）：纯度 = 实例的合取
// （无实例 = 0），故实例与源同值恒成立。
//
// 时点：IR 生成结束之后（唯一入口 = df_state_finalize，见 dataflow.cr）。
// IR 体是纯度的唯一权威来源，而 IR 体逐函数生成（调用者先于被调者、含递归与
// 前向引用），因此check_all 尾部（声明就绪但 IR 体尚未生成）与 collect_decls 期
// （调用图未闭合）都不可用；状态依赖关系的消费者（df_connect_state）相应后移到同一时点
// （df_replay_state_chain），否则状态依赖关系只能读到生成期的乐观默认值。
//
// 默认值冻结注记：checker.cr 注册函数时 fi_set_ispure(..., 1) 是乐观默认值，有意保留。
// IR 生成期它的唯一消费者是 ir_gen.cr 的 lazy 判定；删除默认值会让 lazy 全部不发射，
// 发射路径逐字节改变。真纯度在 IR 生成后由本函数覆盖写回。

fn purity_op_effect(op: int) -> int:
    if op == IR_STORE:
        return 1
    if op == IR_STORE_FIELD:
        return 1
    if op == IR_STORE_INDEX:
        return 1
    if op == IR_STORE_INDEX_VAR:
        return 1
    if op == IR_STORE_PTR:
        return 1
    if op == IR_CALL_EXTERN:
        return 1
    if op == IR_HOTPATCH_ROUTE:
        return 1
    if op == IR_DYN_DISPATCH:
        return 1
    if op == IR_SPAWN:
        return 1
    if op == IR_YIELD:
        return 1
    if op == IR_AWAIT:
        return 1
    return 0

// IR 函数序号（g_ir_func_* 表下标）-> 源 FuncInfo 下标；-1 = 越界（不可达防御）。
// 依据：IR 生成循环按源序跳过泛型函数发 IR；monomorph 实例只追加到 g_funcs
// 末尾（唯一创建点 = ir_gen.cr 的调用点），因此IR 序 = 源序非泛型子序列 ++ 实例创建序，
// 与本函数按源序跳过泛型的重放一致。调用方另按 g_ir_func_name_idx 复核名字，
// 复核失败即保守判不纯，防止映射漂移导致错误标记。
fn src_func_of_ir(irf: int) -> int:
    cnt : ., mut = 0
    i : ., mut = 0
    loop:
        if i >= g_func_count:
            return -1
        if fi_generic_count(i) == 0:
            if cnt == irf:
                return i
            cnt = cnt + 1
        i = i + 1
    return -1

// DF 节点序号 -> 所属 IR 函数序号（-1 = 无）。g_df_func_node_start 单调，因此线性
// 取下界即上界；unsafe 区稀少，不值得为它引二分。
fn df_func_of_node(pos: int) -> int:
    best : ., mut = -1
    irf : ., mut = 0
    loop:
        if irf >= g_ir_func_count:
            break
        if cell_load(g_df_func_node_start, irf * 8) <= pos:
            best = irf
        irf = irf + 1
    return best

fn compute_all_purity():
    fcount := g_func_count
    if fcount <= 0:
        return
    if g_ir_func_count <= 0:
        return
    // 无 IR 体（check-only 路径），因此不覆盖默认值

    // 侧表（本函数自持）：local = 局部效应/硬不纯位；pure = 当前纯度工作值；
    // callee = 每条 IR 指令的可解析被调 fi（-1 = 非调用；不可解析记在 local 位）。
    // alloc 不保证清零（rt.s bump 分配器），因此三表全部显式初始化。
    local := alloc(fcount * 8)
    pure := alloc(fcount * 8)
    callee := alloc(g_ir_instr_count * 8)
    z : ., mut = 0
    loop:
        if z >= fcount:
            break
        cell_store(local, z * 8, 0)
        cell_store(pure, z * 8, 0)
        z = z + 1
    z = 0
    loop:
        if z >= g_ir_instr_count:
            break
        cell_store(callee, z * 8, -1)
        z = z + 1

    // ── 1) 逐 IR 函数扫体：局部效应位 + 调用边解析 ──
    irf : ., mut = 0
    loop:
        if irf >= g_ir_func_count:
            break
        sfi := src_func_of_ir(irf)
        map_ok : ., mut = 1
        if sfi < 0:
            map_ok = 0
        else if cell_load(g_ir_func_name_idx, irf * 8) != fi_name(sfi):
            map_ok = 0
        else if ast_kind(fi_ast_node(sfi)) == EXPR_EXTERN:
            map_ok = 0
        if map_ok == 0:
            // 映射漂移/extern 声明体（无可生成的体）：保守判不纯
            if sfi >= 0:
                cell_store(local, sfi * 8, 1)
            irf = irf + 1
            continue
        istart := cell_load(g_ir_func_instr_start, irf * 8)
        icnt := cell_load(g_ir_func_instr_count, irf * 8)
        ii : ., mut = istart
        loop:
            if ii >= istart + icnt:
                break
            op := iri_op(ii)
            if purity_op_effect(op) != 0:
                cell_store(local, sfi * 8, 1)
            if op == IR_CALL:
                cf := find_func(iri_s3(ii))
                if cf < 0:
                    cell_store(local, sfi * 8, 1)
                // 不可解析（runtime builtin），因此不纯
                else:
                    cell_store(callee, ii * 8, cf)
            if op == IR_INLINE:
                cf2 := find_func(iri_s1(ii))
                if cf2 < 0:
                    cell_store(local, sfi * 8, 1)
                else:
                    cell_store(callee, ii * 8, cf2)
            ii = ii + 1
        irf = irf + 1

    // ── 2) unsafe 区，因此归属函数不纯（IR 无 unsafe opcode：效应藏在块内裸操作里；
    //   归属 = 区起始节点落在哪个函数的节点区间）──
    si : ., mut = 0
    loop:
        if si >= g_sg_count:
            break
        if cell_load(g_sgs, si * ESZ_SG + OFF_SG_KIND) == SG_UNSAFE:
            uf := df_func_of_node(cell_load(g_sgs, si * ESZ_SG + OFF_SG_NSTART))
            if uf >= 0:
                usf := src_func_of_ir(uf)
                if usf >= 0:
                    cell_store(local, usf * 8, 1)
        si = si + 1

    // ── 3) 不动点：全不纯起点升纯（保守单调，语义见头注 4）──
    changed : ., mut = 1
    loop:
        if changed == 0:
            break
        changed = 0
        irf = 0
        loop:
            if irf >= g_ir_func_count:
                break
            sf := src_func_of_ir(irf)
            if sf >= 0:
                if cell_load(local, sf * 8) == 0:
                    if cell_load(pure, sf * 8) == 0:
                        ist2 := cell_load(g_ir_func_instr_start, irf * 8)
                        ic2 := cell_load(g_ir_func_instr_count, irf * 8)
                        allpure : ., mut = 1
                        ii2 : ., mut = ist2
                        loop:
                            if ii2 >= ist2 + ic2:
                                break
                            c := cell_load(callee, ii2 * 8)
                            if c >= 0:
                                if cell_load(pure, c * 8) == 0:
                                    allpure = 0
                                    break
                            ii2 = ii2 + 1
                        if allpure != 0:
                            cell_store(pure, sf * 8, 1)
                            changed = 1
            irf = irf + 1

    // ── 4) 泛型源（无 IR 体）回填：源纯度 = 实例合取（无实例 = 0）──
    fi : ., mut = 0
    loop:
        if fi >= fcount:
            break
        if fi_generic_count(fi) > 0:
            ninst : ., mut = 0
            allp : ., mut = 1
            gi : ., mut = 0
            loop:
                if gi >= g_purity_inst_count:
                    break
                if cell_load(g_purity_inst, gi * 24) == fi:
                    ninst = ninst + 1
                    nf := cell_load(g_purity_inst, gi * 24 + 16)
                    if nf >= 0 && nf < fcount:
                        if cell_load(pure, nf * 8) == 0:
                            allp = 0
                    else:
                        allp = 0
                gi = gi + 1
            if ninst > 0 && allp != 0:
                cell_store(pure, fi * 8, 1)
        fi = fi + 1

    // ── 5) 写回 ──
    fi = 0
    loop:
        if fi >= fcount:
            break
        fi_set_ispure(fi, cell_load(pure, fi * 8))
        fi = fi + 1

// 自测辅助：按名查纯度（-1 = 无此函数，与 0/1 区分，防查不到被当不纯）。
fn fi_ispure_of(name_ni: int) -> int:
    fi := find_func(name_ni)
    if fi < 0:
        return -1
    return fi_ispure(fi)
