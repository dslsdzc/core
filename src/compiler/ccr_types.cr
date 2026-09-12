// === ccr_types.cr ===
// R2 P4 Task 2：TYPE(7) 段的**内容构造**（D18 解耦——本文件 corec-only：
// 装填引用桥接层 sh_term_of_ti（corearch 无此层）+ checker 层类型行表；ccr_io.cr
// 同时在 corearch 清单内，保持「共享层符号」纯度，只按段表搬运 g_ccr_type_seg
// 缓冲）。corearch 侧的读回（段 → g_types/g_type_terms/g_tt_index 重建）在
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
    // ③ 接口签名项装填（D13 第③段）：**Task 3**（IFACE 段内容面）落地——本任务空转。
    //    形状重注册（iface_shape_builtin_init）同归 Task 3：当前形状注册面由
    //    init_types 尾部 iface_registry_init 建立，本任务不动（重置面零变化）。
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

// save 前单入口（main.cr 两处调用点共用：D13 装填 → 段体构造）——-1 = 拒绝落盘。
fn ccr_type_prepare_save() -> int {
    if ccr_type_populate() != 0 { return -1; }
    return ccr_type_seg_build();
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
