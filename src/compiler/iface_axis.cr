// === iface_axis.cr ===
// R2 P4 Task 0（引擎核纯化拆分，链接面纯化）：iface 满足判定簇 + `iface_kind_of` 的 corec-only 宿主。
//
// 迁移面（**逐字搬迁，零语义改动**；出处以搬迁时点行号标注）：
//   · type_engine.cr:613-772 —— `IFACE_SAT_BUDGET` + `iface_satisfies` / `iface_satisfies_term` /
//     `iface_satisfies_ti` / `iface_find_method` / `iface_user_satisfies` / `iface_user_satisfies_ii`
//     （含各段头注与轴分派说明）；
//   · iface_registry.cr:271-293 —— `iface_kind_of`（+ 头注）。
// 原位各留一行指路注释（type_engine.cr 尾 / iface_registry.cr 的 ty_code_to_ti 之后）。
//
// **为何移出**（R2 P4 计划 D16）：type_engine.cr 1-612 行（纯核）零 checker/桥接/注册表引用，
// 本簇是唯一耦合段——找到 iface_satisfies/iface_kind_of 的实现者 = 前端层符号。corearch 链接纯核
// 时若本簇仍在，构建会以未定义符号告终（concat 面 = resolver「Undefined name」；project-mode 面
// = `error[N06]` 静默未定义 + rc=0，B.6 同族）。移出后：type_engine.cr = 纯核（corearch 链接目标），
// iface_registry.cr 除 `sh_shape_seq_ro` 对 ty_shadow 的 `sh_ref_mut_marker` 一处外亦纯。
//
// 本文件**只入 corec/corelsp 清单**（corearch 清单不含本文件）。直取的跨层符号（同 concat 单元内
// 由清单前置文件提供，见 build_selfhost_native.py 与 src/compiler/_import.cr 的相对序）：
//   checker.cr     —— find_iface / find_func / decl_name_of_ti / gen_constr_type_ti / get_type_kind / get_type_data
//   ty_shadow.cr   —— sh_term_of_ti / sh_iface_shape_term / sh_shape_member_at / sh_iface_self_mode /
//                     sh_func_self_mode / sh_func_sig_term
//   iface_registry.cr —— iface_shape_lookup / iface_by_ty_code（后者经 iface_kind_of 的 TYP_BASE 分支）
//   type_engine.cr —— ty_sub / ty_budget_reset / tt_c / tt_list_same（纯核原语，同清单前置）
// ⚠ iface_kind_of 头注内「只见上面 iface_by_ty_code」的「上面」在搬迁后 = iface_registry.cr 的对应
//   函数（跨文件同 concat 单元）——注释文字按「逐字搬迁」原样保留，语义指向不变。

// ─── R2 P3b Task 0：满足判定统一入口（P2b 交接契约 ① 的落地）───
// 语义（spec §2.2/§2.3/§2.5 + P3 计划「与 P2b 的交接面」①）：`iface_satisfies(t_ti, iface_ni)`
// 是**原生/横切/用户三类同入口**的满足判定；三态 1/0/-1（`-1` = 未覆盖/不判，**禁止**被消费
// 方当 0（不满足）或 1（满足）用——P0 三态纪律）。
//
// 轴分派（**顺序 = 形状 → 接口 → 本质轴**，各自不判时逐级下落，绝无静默折算）：
//   A 横切形状名：`iface_shape_lookup(iface_ni)`（Task 2 注册；本批空表 ⇒ 恒未命中）
//     ⇒ 包含判定 `ty_sub(实参项, 形状项)`。形状项由 Task 2 按 spec §2.2 给出（如 `⊤_SEQUENCE`）。
//   B 本质轴（原生/已声明类型名）：= P3a `gen_constr_satisfied` 的引擎面**逐字同口径**
//     （`sh_term_of_ti` 桥接 + `ty_sub` + 预算隔离），本函数即该面的统一入口。
//   C 用户接口名：`find_iface >= 0` ⇒ `iface_user_satisfies`（Task 6 Step 3：形状项 +
//     逐成员签名判定；= `check_iface` 同源，见该函数头注）。
// ⚠ 名字同时命中多轴时按上式**取先命中者**（A > C > B；原生名与接口名同名的撞车面在 C > B
//   处保持 P3a 现状：`find_iface` 命中即走用户轴，不做本质轴判定）。
//
// 预算隔离（照 `type_equal_engine`/`gen_constr_satisfied` 先例）：每次进入引擎前
// `ty_budget_reset`、返回前再复位——memo 跨查询命中会让结果依赖预算历史（P0 终审 Critical 3）。
// 本常量 = 与 `gen_constr_satisfied` 同值（两处同为「一遍桥接 + 一次包含判定」的规模；
// 常量定义在本文件（调用面在其后），`globals.cr` 无 IFACE_* 预算位）。
IFACE_SAT_BUDGET : int = 200000;

fn iface_satisfies(t_ti: int, iface_ni: int) -> int {
    if t_ti < 0 { return -1; }
    if iface_ni < 0 { return -1; }
    // ── 轴 A：横切形状名（空表 ⇒ 未命中，落下方轴）──
    st := iface_shape_lookup(iface_ni);
    if st >= 0 { return iface_satisfies_term(t_ti, st); }
    // ── 轴 C：用户接口（`find_iface` 命中 ⇒ 用户轴；不得再落本质轴）──
    if find_iface(iface_ni) >= 0 {
        // 形状项路由（R2 P3b Task 6 Step 1/3 已落地）：形状项 = 接口方法集（product of fn，
        // 建项见 ty_shadow.cr 的 sh_iface_shape_term），判定 = **逐成员包含**（下述
        // iface_user_satisfies：方法名经 impl 方法表查表 + 成员 fn 项经引擎 ty_sub）。
        // **不是** `iface_satisfies_term(t_ti, shp)`（整形状 ty_sub）——两条实测理由：
        //   ① 引擎对 AK_NAMED 不展开（P0 未覆盖面②）⇒ 命名行实参与 product 形状的 `ty_sub`
        //      恒 -1（全部负例会静默降级为「不判」= 静默通过面复活）；
        //   ② product 的引擎比较是**不变槽链结构相等**而非子集包含 ⇒ 方法集 ⊇ 形状集
        //      （实现方带额外方法，常态）会被误拒。
        // ⇒ 整形状 ty_sub 路由**不可用**（登记为未覆盖面）；形状项作为签名载体由逐成员判定消费。
        return iface_user_satisfies(t_ti, iface_ni);
    }
    // ── 轴 B：本质轴（原生/已声明类型名；非类型名 ⇒ -1 = 不判，不发明诊断）──
    cti := gen_constr_type_ti(iface_ni);
    if cti < 0 { return -1; }
    return iface_satisfies_ti(t_ti, cti);
}

// ─── 引擎面原语（Task 2 的无名字消费点可直接用 `iface_satisfies_term`）───
// `实参行 <: 形状项`：桥接失败（行不可译）⇒ -1；否则 `ty_sub` 三态**直传**（-1 上抛）。
fn iface_satisfies_term(t_ti: int, shape: int) -> int {
    if t_ti < 0 { return -1; }
    if shape < 0 { return -1; }
    a := sh_term_of_ti(t_ti);
    if a < 0 { return -1; }
    ty_budget_reset(IFACE_SAT_BUDGET);
    s := ty_sub(a, shape);
    ty_budget_reset(IFACE_SAT_BUDGET);
    return s;
}

// `实参行 <: 约束行`（本质轴；= gen_constr_satisfied 的引擎面）
fn iface_satisfies_ti(t_ti: int, cti: int) -> int {
    if t_ti < 0 { return -1; }
    if cti < 0 { return -1; }
    a := sh_term_of_ti(t_ti);
    b := sh_term_of_ti(cti);
    if a < 0 || b < 0 { return -1; }
    ty_budget_reset(IFACE_SAT_BUDGET);
    s := ty_sub(a, b);
    ty_budget_reset(IFACE_SAT_BUDGET);
    return s;
}

// 方法行查找：`(类型名 ni, 方法名 ni) → mangled 函数名 ni`（-1 = 无此方法）。
// 数据面 = parser 在 impl 块登记的 `g_methods`（24B/条 {type_ni, method_ni, mangled_ni}，
// parser.cr 的 impl 分支**唯一**写点）——与 `type_has_method`（`find_func(str_intern("T.m"))`）
// **同域**：两者判的都是「impl 块声明过 `Type.method`」这一面（等价性守门 = selftest
// `isat.predicate_same_as_check_iface` 全表对拍 + 行为探针）。
// ⚠ 本函数**零 str_intern**：查名走表、不构造串——方法缺失（= 判定 0 的路径）不得往 g_strs
// 追加新串（.ccr STR 段硬判据；`type_has_method` 的 str_intern 只对**已存在**方法名幂等，
// 对缺失方法名会增长驻留表——本层刻意避开该形态）。
fn iface_find_method(type_ni: int, method_ni: int) -> int {
    if type_ni < 0 { return -1; }
    if method_ni < 0 { return -1; }
    i : ., mut = 0;
    loop {
        if i >= g_method_count { return -1; }
        if r64(g_methods, i * 24) == type_ni {
            if r64(g_methods, i * 24 + 8) == method_ni { return r64(g_methods, i * 24 + 16); }
        }
        i = i + 1;
    }
    return -1;
}

// ─── 轴 C：用户接口的满足谓词（**与 check_iface 同源**；R2 P3b Task 6 Step 3 重写）───
// 语义（spec §2.3）：`interface I` 的形状类型项 = 方法集（product of fn，建项 =
// `sh_iface_shape_term`）；判定 = **逐成员包含**：对 I 的每个方法 m——
//   ① T 的方法表含 m（表查询 `iface_find_method`，**mangling 已退役**：不再拼 "T.m" 串）；
//   ② 接收者模式相等（调用约定维度；两侧显式比较，见 `sh_iface_sig_param_term` 注）；
//   ③ 签名包含：成员 fn 项与 impl 函数行的 fn 项做引擎 `ty_sub`——项为**身份规范形**
//      （N 不入项 / 泛型应用展开 / 命名行按名规范，见 ty_shadow.cr 的 sh_sig_term_of_ti 注）
//      ⇒ 判定 = 逐参类型 + 返回类型（**类型项等价**，取代旧态的裸码比较）。
// 三态：
//   · 1 = 全部方法在位且签名相符（含**零方法接口**的空洞满足）；
//   · 0 = 方法名不在位 / 接收者模式不同 / 参数数不符（链长不同）/ 签名项不同（**可证违反**）；
//   · -1 = T 非命名行（原生/`dyn`/泛型形参/复合构造子——无方法表 ⇒ **不判**）；方法表登记了
//         名字但函数行缺失（表内不一致）；接口形状项不可建（签名节点缺失 / 域外参数数）；
//         函数行签名项不可建（变参/未知 kind）。**-1 绝不因「查不到」而报 0**。
// 覆盖边界（登记面，非漏放）：签名含**泛型形参行**的匹配只在同一声明内成立（行号身份）——
// 接口侧不产生该形态（`interface I[T]` 的形参被 parser 丢弃，登记）；`dyn` 位图行不参与
// 规范形 ⇒ 含 dyn 的签名 = -1 不判。
// 预算隔离：每次引擎查询前后 `ty_budget_reset`（照本文件其它入口同款）。
fn iface_user_satisfies(t_ti: int, iface_ni: int) -> int {
    ii := find_iface(iface_ni);
    if ii < 0 { return -1; }
    // 域限定：仅命名行（TYP_NAMED / TYP_GENERIC_APPLY 的基名）有方法表身份；其余 ⇒ 不判。
    // 用 decl_name_of_ti（展开层的行→声明入口）而非 get_type_name：后者对 TYP_BASE 行会
    // str_intern 基类型名（本层禁止驻留表增长，见 iface_find_method 注）。
    tname_ni := decl_name_of_ti(t_ti);
    if tname_ni < 0 { return -1; }
    return iface_user_satisfies_ii(tname_ni, ii);
}

// 名字面核心（`iface_user_satisfies` 与 checker 的 `check_iface` 的**共同实现**——两侧
// 同源由构造保证，selftest `isat.predicate_same_as_check_iface` 仍逐例对拍）。
fn iface_user_satisfies_ii(tname_ni: int, ii: int) -> int {
    if tname_ni < 0 || ii < 0 { return -1; }
    mc := r64(g_ifaces, ii * ESZ_IFACEINFO + OFF_IF_METHOD_COUNT);
    if mc < 0 || mc > MAX_IFACE_METHODS { return -1; }
    shp := sh_iface_shape_term(r64(g_ifaces, ii * ESZ_IFACEINFO + OFF_IF_NAME));
    if shp < 0 { return -1; }
    mi : ., mut = 0;
    loop {
        if mi >= mc { return 1; }
        mbase := ii * ESZ_IFACEINFO + OFF_IF_METHODS + mi * ESZ_IFMETHOD;
        m_ni := r64(g_ifaces, mbase + OFF_IFM_NAME);
        f_ni := iface_find_method(tname_ni, m_ni);
        if f_ni < 0 { return 0; }                    // 无此方法 = 可证违反（名字面忠实）
        fi := find_func(f_ni);
        if fi < 0 { return -1; }                     // 表内不一致 ⇒ 不判（不发明违反）
        if sh_iface_self_mode(ii, mi) != sh_func_self_mode(fi) { return 0; }   // 接收者模式

        ifm := sh_shape_member_at(shp, mi);
        if ifm < 0 { return -1; }                    // 形状项与方法表失同步 ⇒ 不判
        implf := sh_func_sig_term(fi);
        if implf < 0 { return -1; }                  // impl 侧签名项不可建 ⇒ 不判
        // 判定 = 引擎的**不变槽结构比较原语** `tt_list_same`（0/1 **全域**）——**不是**
        // 直接 `ty_sub`：引擎在不变槽上把「确定不同」上抛为 -1（type_engine 的
        // tt_list_variance_at 分支：`tt_type_elem_same != 1 → g_ty_uncovered = 1; return -1`，
        // 「确定不等 ⇒ 0」的加强仍是登记面）⇒ 用 ty_sub 会让签名不符退化成「不判」=
        // 静默通过面复活（实测：isat.axis_c_ret_code 得 -1）。项为**规范形**（见 ty_shadow.cr
        // 的 sh_sig_term_of_ti 注）⇒ 同型恒同节点、异型恒异节点 ⇒ 节点同一性就是签名相等的
        // 正确判据。**比的是 fn 项的链**（`tt_c`）：fn 原子的 b 槽 = 方法名（接口侧标注；
        // impl 侧为 -1）是元数据不入签名——整项同一是 `tt_list_same` 的「非 CONS ⇒ 节点同一」
        // 规则下的假不等（实测命中）。本原语不计步（不动预算/memo）⇒ 无需预算隔离。
        if tt_list_same(tt_c(implf), tt_c(ifm)) != 1 { return 0; }
        mi = mi + 1;
    }
    return 1;
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
