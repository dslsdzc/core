// === ccr_types.cr ===
// R2 P4 Task 2/3：TYPE(7)/IFACE(8) 两段的**内容构造**（D18 解耦——本文件 corec-only：
// 装填引用桥接层 sh_term_of_ti/sh_iface_sig_*（corearch 无此层）+ checker 层类型行表 /
// 接口表；ccr_io.cr 同时在 corearch 清单内，保持「共享层符号」纯度，只按段表搬运
// g_ccr_type_seg/g_ccr_iface_seg 缓冲）。corearch 侧的读回（段 → g_types/g_type_terms/
// g_tt_index + g_iface_entries/g_iface_shape_*/g_ifaces/g_impl_for/g_methods 重建）在
// ccr_io.cr 的 load_ccr 内。
//
// 段体字节（D12；小端、offset 相对段首；字段一律 i64 = 8B——与 g_types/
// g_type_terms 的内存槽逐位同源，无截断面）：
//   [row_count u32]
//   [row_count × 24B {kind,data,extra} i64×3]        ← g_types 0..g_type_count-1 原样
//   [term_count u32]
//   [term_count × 40B {tag,a,b,c,d} i64×5]           ← 项 DAG（哈希不落盘，加载侧重算）
// 加载侧不变量（ccr_io.cr 逐条校验，违规 = 拒绝——三态纪律，不得静默当空表）：
//   · 子项引用（UNION/INTER 的 a,b；NOT 的 a；MU 的 b；CONS 的 a,b；ATOM 的 c——含
//     c 链元素，逐行归纳）必须 -1 或 **< 自身行号**（拓扑 = 无环；DAG 由 tt_term
//     追加式构造保证）——**ATOM 的 a（ak）与 b（自类型行号/固定性位/令牌值/mut 标记，
//     可达数千）是标注，不得按「< 行号」校验**（sh_ref_mut_marker/sh_name_token/
//     sh_seq_term 三构造点；tt_var/tt_mu 的 a = 绑定变量、tt_top_k 的 a = k 同理）；
//   · tag ∈ 0..10（TT_*）；a..d ≥ -1；越界/拓扑违规 ⇒ 拒绝。
//
// ── IFACE(8) 段体（R2 P4 Task 3；D14 五小节，各带 count u32；字段宽度见逐小节注）──
//   ① [native_count u32 = IFACE_ENTRY_COUNT] [× 24B {ak i32, ti_row i32, name_ni i32,
//      lit_code i32, ops i64}]                        ← g_iface_entries 原样（16 行）
//   ② [shape_count u32] [× 8B {name_ni i32, term i32}]  ← g_iface_shape_*（名字面 + 形状项）
//   ③ [iface_count u32] [× {name_ni i32, method_count i32, generic_count i32, pad i32}
//      + method_count × 80B {name_ni i32, param_count i32, self_mode i32, ret_term i32,
//                            param_terms[8] i32, param_codes[8] i32}]
//      —— 方法记录的字段序 = 计划 Interfaces 的**逐字段声明行**（{name_ni, param_count,
//         self_mode, ret_term, param_terms[8], param_codes[8]}）；同块末行的尺寸式
//         （…+ param_codes[8] + param_terms[8] = 80B）两数组次序相反 ⇒ **取声明行为准**
//         （登记见 Task 3 报告）；ret_term/param_terms = 类型项索引（-1 = 不可建；
//         写侧 ccr_iface_populate 遇不可建 = **拒绝落盘**——见该函数注）；
//         param_codes = **信息面**裸码（`dyn_arr.cr` 的 param_tis 槽语义不变，
//         S6 消费点不入本段）。
//   ④ [impl_count u32] [× 8B {trait_ni i32, type_ni i32}]      ← g_impl_for（声明元数据）
//   ⑤ [method_count u32] [× 12B {type_ni i32, method_ni i32, mangled_ni i32}] ← g_methods
// 加载侧不变量（ccr_io.cr 逐条校验，违规 = 拒绝）：五小节计数/长度自洽 + 行走完 ==
// seg_end8（无尾随字节）+ native_count == IFACE_ENTRY_COUNT + **跨段引用域**：
// name_ni/type_ni/method_ni/mangled_ni ∈ [0, STR 串数)；ti_row ∈ {-1} ∪ [0, TYPE 行数)；
// term ∈ {-1} ∪ [0, TYPE 项数)（TYPE(7) 段先于 IFACE(8) 解析 ⇒ 域已建立）。

// ─── D13 确定性装填 ───
// 段内容必须 = 类型表/接口表的**纯函数**（不得随判定历史漂移）：项 DAG 是惰性填充的
// （sh_term_of_ti 只在判定/装填时建项）⇒ 直接序列化「活表」= 内容随判定次数/顺序变
// （冷/热 .cir 缓存命中 ⇒ 判定次数不同 ⇒ 段不同 = 已登记的冷热分歧类，TODO #5 末条）。
// 重建 = 项层/引擎/桥接复位 → 按**行序**逐行装填（0..g_type_count-1）→ （接口签名项
// 装填归 Task 3）⇒ 项行号 = 行序遍历的构造序（确定），与判定历史无关。
// 调用点前置核查（plan Step 2，逐站点核）：save_ccr 两处调用点（main.cr:612 `ccr`
// / main.cr:636 `build`）之后无类型项消费者——`ccr` 分支随后即 return；`build` 分支
// 其后只拼 corearch 命令行（子进程）并 syscall 执行；sh_finish（影子摘要）在
// run_frontend 之后、本函数之前。
fn ccr_type_populate() -> int {
    // ① 复位：项层（含引擎预算/memo/lits——见 tt_layer_reset 注记）→ 桥接层。
    //    三面都持**旧行号语义**的缓存，少复位任一面 = 陈旧项被当活项（静默）。
    tt_layer_reset();
    sh_map_reset();            // ti→term 桥接缓存（含 entries/hits 计数）
    sh_unf_map_reset();        // ti→展开项缓存
    // ①.5 形状重注册（D13 顺序第 2 步，R2 P4 Task 3 落地）：六形状按 D17 名重注册
    //     （幂等覆盖）——先于行装填 ⇒ 形状项行号 = 构造序前段（确定性；形状表本体
    //     随 IFACE 段 ② 小节落盘）。
    iface_shape_builtin_init();
    // ② 行序装填：0..g_type_count-1（原生 9 行经 sh_native_ak 快路径，不入缓存）。
    //    不可译行 ⇒ 拒绝（-1）：**不得**把缺项的类型行静默写成空/跳过——
    //    段是「信息恒随载体」的兑现面，缺项即载体损坏。
    i : ., mut = 0;
    loop {
        if i >= g_type_count { break; }
        if sh_term_of_ti(i) < 0 {
            print("error: TYPE segment: type row ");
            print(int_str(i));
            println(" is not translatable to a type term (save refused)");
            return -1;
        }
        i = i + 1;
    }
    // ③ 接口签名项装填（D13 第③段，R2 P4 Task 3 落地）：按接口声明序逐方法装填
    //    ret_term/param_terms（写入 g_ifaces 的项槽——与 IFACE 段 ③ 小节同一读点）。
    return ccr_iface_populate();
}

// ─── IFACE 段 ③ 小节：接口签名项装填（corec 侧）───
// 逐接口（声明序）逐方法逐形参调 `sh_iface_sig_ret_term`/`sh_iface_sig_param_term`
// （签名**规范形**建项，见 ty_shadow.cr 的 sh_sig_term_of_ti 注），写入 g_ifaces 的
// OFF_IFM_RET_TERM / OFF_IFM_PARAM_TERMS 槽（未用形参槽 = -1）。
//
// **不可建 ⇒ 拒绝落盘**（-1 + 诊断；计划 Task 3 Step 1-⑩ / Global Constraints）：
// 「信息恒随载体」下签名项缺席即载体损坏。触发面 = 形参/返回类型行不可译进规范形
// （实测唯一可达形态 = `dyn` 位图行：sh_sig_term_of_ti 对 TYP_DYN 回 -1）；
// 接收者槽 = unit 占位项（sh_iface_sig_param_term 的 self 约定），不触发拒绝。
// **先 report-only**：全语料（计划 Global Constraints 的五类）跑过、零命中后才作硬门
// （报告登记；Corpus 实测见 Task 3 报告 §report-only）。
fn ccr_iface_populate() -> int {
    iface_ensure();   // 条目表可能早于 init_types 被查（自测通道）；幂等
    ii : ., mut = 0;
    loop {
        if ii >= g_iface_count { break; }
        mc := r64(g_ifaces, ii * ESZ_IFACEINFO + OFF_IF_METHOD_COUNT);
        if mc < 0 || mc > MAX_IFACE_METHODS {
            print("error: IFACE segment: interface ");
            print(int_str(ii));
            print(" method count "); print(int_str(mc));
            println(" out of range (save refused)");
            return -1;
        }
        mi : ., mut = 0;
        loop {
            if mi >= mc { break; }
            mbase := ii * ESZ_IFACEINFO + OFF_IF_METHODS + mi * ESZ_IFMETHOD;
            pc := r64(g_ifaces, mbase + OFF_IFM_PARAM_COUNT);
            if pc < 0 || pc > MAX_IFACE_METHOD_PARAMS {
                print("error: IFACE segment: method ");
                print(int_str(mi));
                print(" of interface "); print(int_str(ii));
                print(" param count "); print(int_str(pc));
                println(" out of range (save refused)");
                return -1;
            }
            rt := sh_iface_sig_ret_term(ii, mi);
            if rt < 0 {
                print("error: IFACE segment: interface ");
                print(int_str(ii));
                print(" method "); print(int_str(mi));
                println(" return signature is not translatable to a type term (save refused)");
                return -1;
            }
            w64(g_ifaces, mbase + OFF_IFM_RET_TERM, rt);
            pj : ., mut = 0;
            loop {
                if pj >= MAX_IFACE_METHOD_PARAMS { break; }
                w64(g_ifaces, mbase + OFF_IFM_PARAM_TERMS + pj * 8, -1);   // 未用槽 = -1
                pj = pj + 1;
            }
            pk : ., mut = 0;
            loop {
                if pk >= pc { break; }
                pt := sh_iface_sig_param_term(ii, mi, pk);
                if pt < 0 {
                    print("error: IFACE segment: interface ");
                    print(int_str(ii));
                    print(" method "); print_i(mi);
                    print(" param "); print_i(pk);
                    println(" signature is not translatable to a type term (save refused)");
                    return -1;
                }
                w64(g_ifaces, mbase + OFF_IFM_PARAM_TERMS + pk * 8, pt);
                pk = pk + 1;
            }
            mi = mi + 1;
        }
        ii = ii + 1;
    }
    return 0;
}

// ─── 段体构造（D12 布局 → g_ccr_type_seg/g_ccr_type_seg_len）───
// 缓冲 = 完整段体（含首字段 row_count），故 ccr_type_seg_size() ≡ 本长度（单源）。
// 调用前必须已 ccr_type_populate()（段内容 = 装填结果，非惰性活表）。
fn ccr_type_seg_build() -> int {
    rc := g_type_count;
    tc := tt_count();
    need := 4 + rc * ESZ_TYPE_ROW + 4 + tc * ESZ_TYPE_TERM_DISK;
    buf := alloc(need + 64);
    pos : ., mut = 0;
    w32(buf, pos, rc); pos = pos + 4;
    i : ., mut = 0;
    loop {
        if i >= rc { break; }
        w64(buf, pos, r64(g_types, i * ESZ_TYPE_ROW + OFF_TR_KIND)); pos = pos + 8;
        w64(buf, pos, r64(g_types, i * ESZ_TYPE_ROW + OFF_TR_DATA)); pos = pos + 8;
        w64(buf, pos, r64(g_types, i * ESZ_TYPE_ROW + OFF_TR_EXTRA)); pos = pos + 8;
        i = i + 1;
    }
    w32(buf, pos, tc); pos = pos + 4;
    j : ., mut = 0;
    loop {
        if j >= tc { break; }
        w64(buf, pos, tt_tag(j)); pos = pos + 8;
        w64(buf, pos, tt_a(j)); pos = pos + 8;
        w64(buf, pos, tt_b(j)); pos = pos + 8;
        w64(buf, pos, tt_c(j)); pos = pos + 8;
        w64(buf, pos, tt_d(j)); pos = pos + 8;
        j = j + 1;
    }
    g_ccr_type_seg = buf;
    g_ccr_type_seg_len = need;
    return 0;
}

// ─── IFACE 段体构造（D14 五小节 → g_ccr_iface_seg/g_ccr_iface_seg_len）───
// 缓冲 = 完整段体（含首字段 native_count），故 ccr_iface_seg_size() ≡ 本长度（单源）。
// 调用前必须已 ccr_type_populate()（③ 小节项槽 = 装填结果）。
// 尺寸 = 4 + 16×24（①）+ [4 + sc×8]（②）+ [4 + Σ(16 + mc×80)]（③）+ [4 + ic×8]（④）
//        + [4 + gc×12]（⑤）——与写侧逐字节一致（calc 侧读同一函数）。
fn ccr_iface_seg_build() -> int {
    need : ., mut = 4 + IFACE_ENTRY_COUNT * 24;
    need = need + 4 + g_iface_shape_count * 8;
    need = need + 4;
    ii : ., mut = 0;
    loop {
        if ii >= g_iface_count { break; }
        mc := r64(g_ifaces, ii * ESZ_IFACEINFO + OFF_IF_METHOD_COUNT);
        need = need + 16 + mc * 80;
        ii = ii + 1;
    }
    need = need + 4 + g_impl_for_count * 8;
    need = need + 4 + g_method_count * 12;
    buf := alloc(need + 64);
    pos : ., mut = 0;
    // ① 原生条目（IFACE_ENTRY_COUNT 行——写侧段 = 内存表原样；计数 = 常量而非
    //    g_iface_entry_count：表内容恒为常量表，计数漂移 = 程序错误 ⇒ 用常量让
    //    loader 的 == IFACE_ENTRY_COUNT 闸两侧同源）
    w32(buf, pos, IFACE_ENTRY_COUNT); pos = pos + 4;
    ei : ., mut = 0;
    loop {
        if ei >= IFACE_ENTRY_COUNT { break; }
        eo := ei * ESZ_IFACE_ENTRY;
        buf_write_i32(buf, pos, r64(g_iface_entries, eo + OFF_IE_AK)); pos = pos + 4;
        buf_write_i32(buf, pos, r64(g_iface_entries, eo + OFF_IE_TI)); pos = pos + 4;
        buf_write_i32(buf, pos, r64(g_iface_entries, eo + OFF_IE_NAME)); pos = pos + 4;
        buf_write_i32(buf, pos, r64(g_iface_entries, eo + OFF_IE_LIT)); pos = pos + 4;
        buf_write_i64(buf, pos, r64(g_iface_entries, eo + OFF_IE_OPS)); pos = pos + 8;
        ei = ei + 1;
    }
    // ② 横切形状（名 ni + 形状项）
    w32(buf, pos, g_iface_shape_count); pos = pos + 4;
    si : ., mut = 0;
    loop {
        if si >= g_iface_shape_count { break; }
        buf_write_i32(buf, pos, r64(g_iface_shape_names, si * 8)); pos = pos + 4;
        buf_write_i32(buf, pos, r64(g_iface_shape_terms, si * 8)); pos = pos + 4;
        si = si + 1;
    }
    // ③ 用户接口（头 16B + 方法 80B × method_count）
    w32(buf, pos, g_iface_count); pos = pos + 4;
    fi : ., mut = 0;
    loop {
        if fi >= g_iface_count { break; }
        fo := fi * ESZ_IFACEINFO;
        buf_write_i32(buf, pos, r64(g_ifaces, fo + OFF_IF_NAME)); pos = pos + 4;
        buf_write_i32(buf, pos, r64(g_ifaces, fo + OFF_IF_METHOD_COUNT)); pos = pos + 4;
        buf_write_i32(buf, pos, r64(g_ifaces, fo + OFF_IF_GENERIC_COUNT)); pos = pos + 4;
        buf_write_i32(buf, pos, 0); pos = pos + 4;   // pad（对齐/预留）
        mc2 := r64(g_ifaces, fo + OFF_IF_METHOD_COUNT);
        mj : ., mut = 0;
        loop {
            if mj >= mc2 { break; }
            mo := fo + OFF_IF_METHODS + mj * ESZ_IFMETHOD;
            buf_write_i32(buf, pos, r64(g_ifaces, mo + OFF_IFM_NAME)); pos = pos + 4;
            buf_write_i32(buf, pos, r64(g_ifaces, mo + OFF_IFM_PARAM_COUNT)); pos = pos + 4;
            buf_write_i32(buf, pos, r64(g_ifaces, mo + OFF_IFM_SELF_MODE)); pos = pos + 4;
            buf_write_i32(buf, pos, r64(g_ifaces, mo + OFF_IFM_RET_TERM)); pos = pos + 4;
            pk2 : ., mut = 0;
            loop {
                if pk2 >= MAX_IFACE_METHOD_PARAMS { break; }
                buf_write_i32(buf, pos, r64(g_ifaces, mo + OFF_IFM_PARAM_TERMS + pk2 * 8)); pos = pos + 4;
                pk2 = pk2 + 1;
            }
            pq : ., mut = 0;
            loop {
                if pq >= MAX_IFACE_METHOD_PARAMS { break; }
                buf_write_i32(buf, pos, r64(g_ifaces, mo + OFF_IFM_PARAM_TYPES + pq * 8)); pos = pos + 4;
                pq = pq + 1;
            }
            mj = mj + 1;
        }
        fi = fi + 1;
    }
    // ④ impl 边（g_impl_for：{trait_ni, type_ni}——声明元数据，裁决 2 不入判定）
    w32(buf, pos, g_impl_for_count); pos = pos + 4;
    gi2 : ., mut = 0;
    loop {
        if gi2 >= g_impl_for_count { break; }
        buf_write_i32(buf, pos, r64(g_impl_for, gi2 * 16)); pos = pos + 4;
        buf_write_i32(buf, pos, r64(g_impl_for, gi2 * 16 + 8)); pos = pos + 4;
        gi2 = gi2 + 1;
    }
    // ⑤ 方法表（g_methods：{type_ni, method_ni, mangled_ni}——iface_find_method 的唯一数据面）
    w32(buf, pos, g_method_count); pos = pos + 4;
    mi2 : ., mut = 0;
    loop {
        if mi2 >= g_method_count { break; }
        buf_write_i32(buf, pos, r64(g_methods, mi2 * 24)); pos = pos + 4;
        buf_write_i32(buf, pos, r64(g_methods, mi2 * 24 + 8)); pos = pos + 4;
        buf_write_i32(buf, pos, r64(g_methods, mi2 * 24 + 16)); pos = pos + 4;
        mi2 = mi2 + 1;
    }
    g_ccr_iface_seg = buf;
    g_ccr_iface_seg_len = need;
    return 0;
}

// save 前单入口（main.cr 两处调用点共用：D13 装填 → 两段体构造）——-1 = 拒绝落盘。
// R2 P4 Task 3：原 ccr_type_prepare_save 更名（IFACE 段同批入缓冲；调用点三处同步）。
fn ccr_seg_prepare_save() -> int {
    if ccr_type_populate() != 0 { return -1; }
    if ccr_type_seg_build() != 0 { return -1; }
    return ccr_iface_seg_build();
}

// ─── 自测/对拍通道（corec 侧 `ccr --dump-types`）───
// 共享面 dump（ccr_io.cr 的 ccr_type_surface_dump——与 corearch 侧 --dump-types
// **同一条打印路径**，跨进程行格式零分歧）+ corec-only 的「行 → 项」映射节
// （corearch 无桥接层故无此节；测试按 "rowterms:" 标记切分两侧输出）。
// 行格式契约见 tests/selfhost/test_ccr_types.py:parse_type_dump。
fn ccr_type_selftest_dump() {
    ccr_type_surface_dump();
    print("rowterms: "); print_i(g_type_count); println("");
    i : ., mut = 0;
    loop {
        if i >= g_type_count { break; }
        print("rowterm "); print_i(i); print(" ");
        println(int_str(sh_term_of_ti(i)));
        i = i + 1;
    }
}

// ─── 自测/对拍通道（corec 侧 `ccr --dump-ifaces`）───
// 共享面 dump（ccr_io.cr 的 ccr_iface_surface_dump——与 corearch 侧 --dump-ifaces
// **同一条打印路径**，跨进程行格式零分歧）+ corec-only 的「签名项**活算**」节：
// 段体缓冲构造**之后**重算 sh_iface_sig_ret_term/sh_iface_sig_param_term（独立读点，
// 与 ccr_iface_populate 的写入路径分离）——测试据此断言「落盘值 == 活算值」，
// 即装填与签名来源零漂移（若 populate 写错槽/写旧值，本节与文件/共享转储不一致）。
// 行格式契约见 tests/selfhost/test_ccr_types.py:parse_iface_dump（"ifacesig:" 标记切分）。
fn ccr_iface_selftest_dump() {
    ccr_iface_surface_dump();
    print("ifacesig: "); print_i(g_iface_count); println("");
    ii : ., mut = 0;
    loop {
        if ii >= g_iface_count { break; }
        mc := r64(g_ifaces, ii * ESZ_IFACEINFO + OFF_IF_METHOD_COUNT);
        mi : ., mut = 0;
        loop {
            if mi >= mc { break; }
            mbase := ii * ESZ_IFACEINFO + OFF_IF_METHODS + mi * ESZ_IFMETHOD;
            pc := r64(g_ifaces, mbase + OFF_IFM_PARAM_COUNT);
            print("ifacesig "); print_i(ii); print(" "); print_i(mi);
            print(" ret "); print_i(sh_iface_sig_ret_term(ii, mi));
            print(" pc "); print_i(pc); println("");
            pj : ., mut = 0;
            loop {
                if pj >= pc { break; }
                print("ifacesigp "); print_i(ii); print(" "); print_i(mi);
                print(" "); print_i(pj); print(" ");
                println(int_str(sh_iface_sig_param_term(ii, mi, pj)));
                pj = pj + 1;
            }
            mi = mi + 1;
        }
        ii = ii + 1;
    }
}
