// === purity_selftest.cr ===
// 效应/纯度修正 Task 1（P0 插队批）：真纯度计算自测通道（`corec selftest-purity`）。
//
// 判据：每例一行 PASS/FAIL，末行 "N/M purity cases passed"，rc=0 = 全过。
//
// 与 type_selftest.cr 的差别：纯度是**跨函数**事实（IR 体扫描 + 调用图不动点），
// 必须走完整前端 + IR 生成 ⇒ 本通道自建最小管线（不读文件、不产产物），且断言
// 的是 IR 生成后由 compute_all_purity 写回的值（时点见 checker.cr 头注）。
// 语言面注意：本语言无三元运算符。

fn ps_check(name: string, got: int, want: int) -> int {
    if got == want {
        print("PASS "); println(name);
        return 0;
    }
    print("FAIL "); print(name);
    print(": got "); print(int_str(got));
    print(" want "); println(int_str(want));
    return 1;
}

// 单次完整前端 + IR 生成（自测用；与 main.cr 的 run 路径同序，无文件缓存）。
fn ps_compile(src: string) -> int {
    reset_frontend_state();
    g_source = src;
    g_error_count = 0;
    g_source_dir = "";
    tokenize(g_source);
    res_imports();
    parse_all();
    if g_error_count > 0 { print_parse_errors(); return 1; }
    if g_diag_count > 0 { print_diagnostics(); return 1; }
    check_all();
    if g_diag_count > 0 { print_diagnostics(); return 1; }
    ir_gen_all();
    return 0;
}

// 按名查纯度（-1 = 无此函数——与 0/1 区分，防「查不到」被当「不纯」混过）
fn ps_purity(name: string) -> int {
    return fi_ispure_of(str_intern(name));
}

// ── state 链面（Task 1 的落点：纯度是手段，「调用进链」才是目的）──────────
// 链 = kind=1 的 DF 边（dataflow.cr df_replay_state_chain 重放产出）。以下三条
// 是 Task 1 的**行为级**判据：不检查实现细节，只检查成品图的边集语义——
// ① 效应调用必须被链穿过（前 store → call → 后 store）；② 可证纯调用必须
// 不被链触及；③ 循环终止依赖必须存在（重放复刻 sg_pop 规则的守门——该规则
// 从「生成期即时连接」迁到「生成后重放」，判据不可省）。

// 源函数名 → IR 函数序号（-1 = 无）。IR 表名 = 源函数名（monomorph 实例为
// 改写名，本通道只用非泛型函数名）。
fn ps_ir_index_of(name: string) -> int {
    ni := str_intern(name);
    irf : ., mut = 0;
    loop {
        if irf >= g_ir_func_count { return -1; }
        if r64(g_ir_func_name_idx, irf * 8) == ni { return irf; }
        irf = irf + 1;
    }
    return -1;
}

// 函数 irf 体内「调 callee」的 DF 节点序号（-1 = 无）
fn ps_call_node(irf: int, callee: string) -> int {
    cni := str_intern(callee);
    start := r64(g_df_func_node_start, irf * 8);
    cnt := r64(g_df_func_node_count, irf * 8);
    n : ., mut = start;
    loop {
        if n >= start + cnt { return -1; }
        if r64(g_df_nodes, n * ESZ_DFNODE + OFF_DF_OPCODE) == IR_CALL {
            if r64(g_df_nodes, n * ESZ_DFNODE + OFF_DF_S3) == cni { return n; }
        }
        n = n + 1;
    }
    return -1;
}

// 节点 nid 被 kind=1 边触及的面：+1 = 有入边，+2 = 有出边（返回 0..3）
fn ps_state_touch(nid: int) -> int {
    if nid < 0 { return -1; }
    r : ., mut = 0;
    e : ., mut = 0;
    loop {
        if e >= g_df_edge_count { break; }
        if r64(g_df_edges, e * ESZ_DFEDGE + OFF_DFE_KIND) == 1 {
            if r64(g_df_edges, e * ESZ_DFEDGE + OFF_DFE_TO) == nid { r = r + 1; }
            if r64(g_df_edges, e * ESZ_DFEDGE + OFF_DFE_FROM) == nid { r = r + 2; }
        }
        e = e + 1;
    }
    return r;
}

// 函数 irf 区间内是否存在「指向 label 节点的 kind=1 边」（循环终止依赖：
// 循环退出节点必须依赖循环体内最后一个副作用——spec region-cfg §4.2）
fn ps_has_label_state_target(irf: int) -> int {
    start := r64(g_df_func_node_start, irf * 8);
    cnt := r64(g_df_func_node_count, irf * 8);
    e : ., mut = 0;
    loop {
        if e >= g_df_edge_count { break; }
        if r64(g_df_edges, e * ESZ_DFEDGE + OFF_DFE_KIND) == 1 {
            tgt := r64(g_df_edges, e * ESZ_DFEDGE + OFF_DFE_TO);
            if tgt >= start && tgt < start + cnt {
                if r64(g_df_nodes, tgt * ESZ_DFNODE + OFF_DF_OPCODE) == IR_LABEL { return 1; }
            }
        }
        e = e + 1;
    }
    return 0;
}

fn purity_selftest_run() -> int {
    fails : ., mut = 0;
    total : ., mut = 0;

    // 用例程序：正控（含传递正控）+ 负控①-⑥（含 SCC 互递归 + 有效应泛型）
    src := "fn pure_add(a: int, b: int) -> int { return a + b; }\n";
    src = src + "fn pure_caller(a: int, b: int) -> int { return pure_add(a, b); }\n";
    src = src + "fn effect() { st : ., mut = 0; st = 1; }\n";
    src = src + "fn call_effect() { effect(); }\n";
    src = src + "extern fn ext_probe(x: int) -> int;\n";
    src = src + "fn call_extern(x: int) -> int { return ext_probe(x); }\n";
    src = src + "fn call_builtin(x: int) -> int { return load64(x); }\n";
    src = src + "fn self_rec(n: int) -> int { if n <= 0 { return 0; } return self_rec(n - 1); }\n";
    src = src + "fn mut_rec_a(n: int) -> int { if n <= 0 { return 0; } return mut_rec_b(n - 1); }\n";
    src = src + "fn mut_rec_b(n: int) -> int { if n <= 0 { return 0; } return mut_rec_a(n - 1); }\n";
    src = src + "fn id[T](x: T) -> T { return x; }\n";
    src = src + "fn use_id(x: int) -> int { return id(x); }\n";
    src = src + "fn gid[T](x: T) -> T { gst : ., mut = 0; gst = 1; return x; }\n";
    src = src + "fn use_gid(x: int) -> int { return gid(x); }\n";
    // state 链面用例（行为级）：效应调用夹在两 store 之间 / 纯调用同形 / 循环
    src = src + "fn chain_effect() -> int { a : ., mut = 0; a = 1; effect(); a = 2; return a; }\n";
    src = src + "fn chain_pure() -> int { a : ., mut = 0; a = 1; b := pure_add(a, 1); a = 2; return a + b; }\n";
    src = src + "fn chain_loop() -> int { acc : ., mut = 0; i : ., mut = 0; loop { if i >= 3 { break; } acc = acc + 1; i = i + 1; } return acc; }\n";
    src = src + "fn main() -> int { return 0; }\n";

    if ps_compile(src) != 0 {
        print("FAIL "); println("purity.selftest_compile");
        return 1;
    }

    // ── 正控：无 store、无调用（及经纯函数的传递调用）⇒ 1 ──
    total = total + 1; fails = fails + ps_check("purity.pure_add", ps_purity("pure_add"), 1);
    total = total + 1; fails = fails + ps_check("purity.pure_caller", ps_purity("pure_caller"), 1);

    // ── 负控① store ──
    total = total + 1; fails = fails + ps_check("purity.effect_store", ps_purity("effect"), 0);
    // ── 负控② 传递：被调者不纯 ⇒ 调用者不纯 ──
    total = total + 1; fails = fails + ps_check("purity.call_effect", ps_purity("call_effect"), 0);
    // ── 负控③ extern 调用（IR_CALL_EXTERN 出现即不纯）──
    total = total + 1; fails = fails + ps_check("purity.call_extern", ps_purity("call_extern"), 0);
    // ── 负控④ 不可解析调用（runtime builtin：load64 无 FuncInfo）──
    total = total + 1; fails = fails + ps_check("purity.call_builtin", ps_purity("call_builtin"), 0);
    // ── 负控⑤ 自递归（保守不纯：不动点永等不到自己被证明纯）──
    total = total + 1; fails = fails + ps_check("purity.self_rec", ps_purity("self_rec"), 0);
    // ── 负控⑤b 互递归（SCC 保守；两成员都要钉）──
    total = total + 1; fails = fails + ps_check("purity.mut_rec_a", ps_purity("mut_rec_a"), 0);
    total = total + 1; fails = fails + ps_check("purity.mut_rec_b", ps_purity("mut_rec_b"), 0);

    // ── 负控⑥ 泛型实例：与源函数同值。纯源：**两断**（同值 + 实例值 = 1）——
    //    只断同值会被「两侧同为不纯」的退化实现假绿；只断实例值则漏掉源值。
    inst_p := ps_purity("id[int]");
    src_p := ps_purity("id");
    total = total + 1; fails = fails + ps_check("purity.generic_instance_pure", inst_p, 1);
    total = total + 1; fails = fails + ps_check("purity.generic_instance_eq_source", (inst_p == src_p), 1);
    // 负控⑥b 有效应泛型（体内有 store）：实例与源同为 0（反向：防「实例恒纯」）
    g_inst := ps_purity("gid[int]");
    total = total + 1; fails = fails + ps_check("purity.generic_effect_instance", g_inst, 0);
    total = total + 1; fails = fails + ps_check("purity.generic_effect_eq_source", (g_inst == ps_purity("gid")), 1);

    // ── state 链面（Task 1 目的：效应调用重新进链；纯调用不入链；循环终止依赖）──
    // ① 效应调用被链穿过：调用节点既要有入边（前 store → call）又要有出边
    //    （call → 后 store）——touch == 3。
    irf_ce := ps_ir_index_of("chain_effect");
    n_ce := ps_call_node(irf_ce, "effect");
    total = total + 1; fails = fails + ps_check("chain.impure_call_pierced", ps_state_touch(n_ce), 3);
    // ② 可证纯调用不被链触及：同形（store / call / store）下 touch == 0——
    //    与 ① 只差被调者纯度 ⇒ 两条合起来把「按真纯度入链」钉死（退化实现
    //    「全入链」挂②、「全不入链」挂①）。
    irf_cp := ps_ir_index_of("chain_pure");
    n_cp := ps_call_node(irf_cp, "pure_add");
    total = total + 1; fails = fails + ps_check("chain.pure_call_untouched", ps_state_touch(n_cp), 0);
    // ③ 循环终止依赖：链重放复刻 sg_pop 规则（regcfg §4.2）——循环体内的最后
    //    副作用必须有边指向循环退出节点（label）。该规则随本次迁移从生成期移到
    //    重放，缺判据则回归无感。
    irf_cl := ps_ir_index_of("chain_loop");
    total = total + 1; fails = fails + ps_check("chain.loop_exit_termination", ps_has_label_state_target(irf_cl), 1);
    // ③' 负控：无循环的函数区间内不得出现指向 label 的链边（防「恒真」实现）
    total = total + 1; fails = fails + ps_check("chain.no_label_edge_without_loop",
        ps_has_label_state_target(irf_cp), 0);

    print(int_str(total - fails)); print("/"); print(int_str(total)); println(" purity cases passed");
    if fails != 0 { return 1; }
    return 0;
}
