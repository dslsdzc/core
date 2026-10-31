// === purity_selftest.cr ===
// Self-test for effect and purity analysis (corec selftest-purity).
//
// Each case prints PASS or FAIL. The last line is "N/M purity cases passed", and
// return code 0 means every case passed.
//
// Purity is a cross-function property computed from IR bodies and a call-graph
// fixed point. This test runs the full frontend and IR generation, then checks
// the values written back by compute_all_purity. It reads no input file and
// produces no output artifact. The language has no ternary operator.

fn ps_check(name: string, got: int, want: int) -> int:
    if got == want:
        print("PASS ")
        println(name)
        return 0
    print("FAIL ")
    print(name)
    print(": got ")
    print(int_str(got))
    print(" want ")
    println(int_str(want))
    return 1

// Boolean version of the check, used by the purity cases.
fn ps_check_b(name: string, got: bool, want: bool) -> int:
    if got == want:
        print("PASS ")
        println(name)
        return 0
    print("FAIL ")
    print(name)
    print(": got ")
    print(bool_str(got))
    print(" want ")
    println(bool_str(want))
    return 1

// Run one full frontend pass and IR generation. The order matches main.cr run, without the file cache.
fn ps_compile(src: string) -> int:
    reset_frontend_state()
    g_source = src
    g_error_count = 0
    g_source_dir = ""
    sm_reset()
    g_source_path = "<purity_selftest>"
    source_file := sm_add_virtual("<purity_selftest>", src)
    tokenize(source_file, 0)
    res_imports()
    parse_all_files()
    if g_error_count > 0:
        print_parse_errors()
        return 1
    if g_diag_count > 0:
        print_diagnostics()
        return 1
    check_all()
    if g_diag_count > 0:
        print_diagnostics()
        return 1
    ir_gen_all()
    return 0

// Look up purity by function name. -1 means the function is absent, distinct from 0 and 1 so a missing lookup is not treated as impure.
fn ps_purity(name: string) -> int:
    return fi_ispure_of(str_intern(name))

// State dependency checks. A state edge is a DF edge with kind 1, produced by
// df_replay_state_chain in dataflow.cr. These checks are behavioral and inspect
// the finished graph's edge set:
// 1. an effectful call must have state edges before and after it;
// 2. a provably pure call must not touch a state edge;
// 3. a loop exit must have a state dependency on the last side effect in the
//    loop body.
// The last rule mirrors sg_pop during graph replay rather than graph construction.

// Source function name to IR function index. -1 means absent. IR table names
// equal source names; monomorph instances use rewritten names, and this test uses
// only non-generic names.
fn ps_ir_index_of(name: string) -> int:
    ni := str_intern(name)
    irf : ., mut = 0
    loop:
        if irf >= g_ir_func_count:
            return -1
        if cell_load(g_ir_func_name_idx, irf * 8) == ni:
            return irf
        irf = irf + 1
    return -1

// Index of the first DF node in function irf that calls callee. -1 means none.
fn ps_call_node(irf: int, callee: string) -> int:
    cni := str_intern(callee)
    start := cell_load(g_df_func_node_start, irf * 8)
    cnt := cell_load(g_df_func_node_count, irf * 8)
    n : ., mut = start
    loop:
        if n >= start + cnt:
            return -1
        if cell_load(g_df_nodes, n * ESZ_DFNODE + OFF_DF_OPCODE) == IR_CALL:
            if cell_load(g_df_nodes, n * ESZ_DFNODE + OFF_DF_S3) == cni:
                return n
        n = n + 1
    return -1

// Number of DF nodes in function irf that call callee. The non-empty assertion
// prevents a missing lookup from making a zero count look valid.
fn ps_count_call_nodes(irf: int, callee: string) -> int:
    if irf < 0:
        return -1
    cni := str_intern(callee)
    start := cell_load(g_df_func_node_start, irf * 8)
    cnt := cell_load(g_df_func_node_count, irf * 8)
    r : ., mut = 0
    n : ., mut = start
    loop:
        if n >= start + cnt:
            return r
        if cell_load(g_df_nodes, n * ESZ_DFNODE + OFF_DF_OPCODE) == IR_CALL:
            if cell_load(g_df_nodes, n * ESZ_DFNODE + OFF_DF_S3) == cni:
                r = r + 1
        n = n + 1
    return r

// Index of the first node with the given opcode in function irf. -1 means none.
fn ps_op_node(irf: int, opcode: int) -> int:
    if irf < 0:
        return -1
    start := cell_load(g_df_func_node_start, irf * 8)
    cnt := cell_load(g_df_func_node_count, irf * 8)
    n : ., mut = start
    loop:
        if n >= start + cnt:
            return -1
        if cell_load(g_df_nodes, n * ESZ_DFNODE + OFF_DF_OPCODE) == opcode:
            return n
        n = n + 1
    return -1

// Whether a kind-1 edge enters node nid: 1 yes, 0 no, -1 no such node.
fn ps_has_state_in(nid: int) -> int:
    if nid < 0:
        return -1
    t := ps_state_touch(nid)
    return t - (t / 2) * 2   // incoming-edge bit; no bitwise and, and t >= 0 makes modulo non-negative

// Whether a kind-1 edge leaves node nid: 1 yes, 0 no, -1 no such node.
fn ps_has_state_out(nid: int) -> int:
    if nid < 0:
        return -1
    t := ps_state_touch(nid)
    return t / 2 - (t / 4) * 2

// Number of call nodes in function irf that call callee and have an incoming
// state edge. If the same callee is called twice, both calls must count. A pure
// call with the same shape counts 0.
fn ps_calls_in_chain(irf: int, callee: string) -> int:
    if irf < 0:
        return -1
    cni := str_intern(callee)
    start := cell_load(g_df_func_node_start, irf * 8)
    cnt := cell_load(g_df_func_node_count, irf * 8)
    r : ., mut = 0
    n : ., mut = start
    loop:
        if n >= start + cnt:
            return r
        if cell_load(g_df_nodes, n * ESZ_DFNODE + OFF_DF_OPCODE) == IR_CALL:
            if cell_load(g_df_nodes, n * ESZ_DFNODE + OFF_DF_S3) == cni:
                if ps_has_state_in(n) == 1:
                    r = r + 1
        n = n + 1
    return r

// State edges touching node nid: +1 for an incoming edge, +2 for an outgoing edge. The result is 0..3.
fn ps_state_touch(nid: int) -> int:
    if nid < 0:
        return -1
    r : ., mut = 0
    e : ., mut = 0
    loop:
        if e >= g_df_edge_count:
            break
        if cell_load(g_df_edges, e * ESZ_DFEDGE + OFF_DFE_KIND) == 1:
            if cell_load(g_df_edges, e * ESZ_DFEDGE + OFF_DFE_TO) == nid:
                r = r + 1
            if cell_load(g_df_edges, e * ESZ_DFEDGE + OFF_DFE_FROM) == nid:
                r = r + 2
        e = e + 1
    return r

// Whether function irf has a kind-1 edge to a label node. A loop exit must
// depend on the last side effect in the loop body.
fn ps_has_label_state_target(irf: int) -> int:
    start := cell_load(g_df_func_node_start, irf * 8)
    cnt := cell_load(g_df_func_node_count, irf * 8)
    e : ., mut = 0
    loop:
        if e >= g_df_edge_count:
            break
        if cell_load(g_df_edges, e * ESZ_DFEDGE + OFF_DFE_KIND) == 1:
            tgt := cell_load(g_df_edges, e * ESZ_DFEDGE + OFF_DFE_TO)
            if tgt >= start && tgt < start + cnt:
                if cell_load(g_df_nodes, tgt * ESZ_DFNODE + OFF_DF_OPCODE) == IR_LABEL:
                    return 1
        e = e + 1
    return 0

fn purity_selftest_run() -> int:
    fails : ., mut = 0
    total : ., mut = 0

    // Test program: positive controls plus negative cases 1 through 6, including an SCC and an effectful generic.
    src : ., mut = "g_test : int, mut = 0\nfn pure_add(a: int, b: int) -> int:\n    return a + b\n"
    src = src + "fn pure_caller(a: int, b: int) -> int:\n    return pure_add(a, b)\n"
    src = src + "fn effect():\n    g_test = 1\n"
    src = src + "fn call_effect():\n    effect()\n"
    src = src + "extern fn ext_probe(x: int) -> int\n"
    src = src + "fn call_extern(x: int) -> int:\n    return ext_probe(x)\n"
    src = src + "fn call_builtin(s: string) -> int:\n    return cell_load(s, 0)\n"
    src = src + "fn self_rec(n: int) -> int:\n    if n <= 0:\n        return 0\n    return self_rec(n - 1)\n"
    src = src + "fn mut_rec_a(n: int) -> int:\n    if n <= 0:\n        return 0\n    return mut_rec_b(n - 1)\n"
    src = src + "fn mut_rec_b(n: int) -> int:\n    if n <= 0:\n        return 0\n    return mut_rec_a(n - 1)\n"
    // Inferred parameter type: calling these with int creates the `id[int]` /
    // `gid[int]` monomorph instances the purity fixed-point checks below use.
    src = src + "fn id(x) -> int:\n    return x\n"
    src = src + "fn use_id(x: int) -> int:\n    return id(x)\n"
    src = src + "fn gid(x) -> int:\n    g_test = 1\n    return x\n"
    src = src + "fn use_gid(x: int) -> int:\n    return gid(x)\n"
    // State dependency cases: an effectful call between stores, a pure call with
    // the same shape, and a loop.
    src = src + "fn chain_effect() -> int:\n    g_test = 1\n    effect()\n    g_test = 2\n    return g_test\n"
    src = src + "fn chain_pure() -> int:\n    a : ., mut = 0\n    a = 1\n    b := pure_add(a, 1)\n    a = 2\n    return a + b\n"
    src = src + "fn chain_loop() -> int:\n    acc : ., mut = 0\n    i : ., mut = 0\n    loop:\n        if i >= 3:\n            break\n        g_test = g_test + 1\n        acc = acc + 1\n        i = i + 1\n    return acc\n"
    // Two calls to an effectful function, a pure call with the same shape, and the
    // IR_CALL_EXTERN, IR_SPAWN, and IR_YIELD opcodes. Each case has a store before
    // and after, so the expected touch value is 3.
    src = src + "fn chain_two() -> int:\n    a : ., mut = 0\n    g_test = 1\n    effect()\n    effect()\n    b := pure_add(a, 1)\n    g_test = 2\n    return g_test + b\n"
    src = src + "fn chain_extern_op(x: int) -> int:\n    a : ., mut = 0\n    g_test = 1\n    r := ext_probe(a)\n    g_test = 2\n    return g_test + r\n"
    src = src + "fn spawnee(x: int) -> int:\n    return x + 1\n"
    src = src + "fn chain_spawn_op() -> int:\n    a : ., mut = 0\n    g_test = 1\n    r := go i 0..2 spawnee(i)\n    g_test = 2\n    return g_test\n"
    src = src + "flow fn chain_yield_op(n: int) -> int:\n    a : ., mut = 0\n    g_test = 1\n    yield n\n    g_test = 2\n    return g_test\n"
    src = src + "fn main() -> int:\n    return 0\n"

    if ps_compile(src) != 0:
        print("FAIL ")
        println("purity.selftest_compile")
        return 1

    // Positive control: no store and no call, plus a transitive call through a pure function.
    total = total + 1
    fails = fails + ps_check("purity.pure_add", ps_purity("pure_add"), 1)
    total = total + 1
    fails = fails + ps_check("purity.pure_caller", ps_purity("pure_caller"), 1)

    // Negative case 1: a store makes the function impure.
    total = total + 1
    fails = fails + ps_check("purity.effect_store", ps_purity("effect"), 0)
    // Negative case 2: a call to an impure function makes the caller impure.
    total = total + 1
    fails = fails + ps_check("purity.call_effect", ps_purity("call_effect"), 0)
    // Negative case 3: an IR_CALL_EXTERN makes the function impure.
    total = total + 1
    fails = fails + ps_check("purity.call_extern", ps_purity("call_extern"), 0)
    // Negative case 4: an unresolvable call to the public runtime builtin
    // cell_load, which has no FuncInfo. Raw load64 is not in user symbols.
    total = total + 1
    fails = fails + ps_check("purity.call_builtin", ps_purity("call_builtin"), 0)
    // Negative case 5: self-recursion is conservatively impure because the fixed point never proves the function pure.
    total = total + 1
    fails = fails + ps_check("purity.self_rec", ps_purity("self_rec"), 0)
    // Negative case 5b: mutual recursion in an SCC. Check both members.
    total = total + 1
    fails = fails + ps_check("purity.mut_rec_a", ps_purity("mut_rec_a"), 0)
    total = total + 1
    fails = fails + ps_check("purity.mut_rec_b", ps_purity("mut_rec_b"), 0)

    // Negative case 6: a generic instance and its source must agree. A pure
    // source is checked twice: the instance is 1 and equals the source. Checking
    // only equality could pass when both sides are impure; checking only the
    // instance would miss the source.
    inst_p := ps_purity("id[int]")
    src_p := ps_purity("id")
    total = total + 1
    fails = fails + ps_check("purity.generic_instance_pure", inst_p, 1)
    total = total + 1
    fails = fails + ps_check_b("purity.generic_instance_eq_source", (inst_p == src_p), true)
    // Negative case 6b: an effectful generic with a store in its body. Both the
    // instance and the source are 0, which also rules out an implementation that
    // always marks instances pure.
    g_inst := ps_purity("gid[int]")
    total = total + 1
    fails = fails + ps_check("purity.generic_effect_instance", g_inst, 0)
    total = total + 1
    fails = fails + ps_check_b("purity.generic_effect_eq_source", (g_inst == ps_purity("gid")), true)

    // State dependency checks: effectful calls take part, pure calls do not, and
    // loop exits depend on the body's last side effect.
    // An effectful call has an incoming edge from the store before it and an
    // outgoing edge to the store after it, so touch is 3.
    irf_ce := ps_ir_index_of("chain_effect")
    n_ce := ps_call_node(irf_ce, "effect")
    total = total + 1
    fails = fails + ps_check("chain.impure_call_pierced", ps_state_touch(n_ce), 3)
    // A provably pure call with the same store, call, and store shape has touch
    // 0. Together with the previous case, this distinguishes a purity-based
    // decision from an implementation that always connects or never connects.
    irf_cp := ps_ir_index_of("chain_pure")
    n_cp := ps_call_node(irf_cp, "pure_add")
    total = total + 1
    fails = fails + ps_check("chain.pure_call_untouched", ps_state_touch(n_cp), 0)
    // Loop termination: the last side effect in the loop body must have an edge
    // to the exit label. Replay applies the same rule as sg_pop.
    irf_cl := ps_ir_index_of("chain_loop")
    total = total + 1
    fails = fails + ps_check("chain.loop_exit_termination", ps_has_label_state_target(irf_cl), 1)
    // Negative control: a function without a loop must not have a state edge to a label.
    total = total + 1
    fails = fails + ps_check("chain.no_label_edge_without_loop",
        ps_has_label_state_target(irf_cp), 0)

    // Effect opcode coverage. purity_op_effect is the single source of truth.
    // Two calls to effect must both take part in the state dependency; a pure
    // call with the same shape counts 0.
    irf_tw := ps_ir_index_of("chain_two")
    total = total + 1
    fails = fails + ps_check("chain.two_calls_exist",
        ps_count_call_nodes(irf_tw, "effect"), 2)          // non-empty assertion
    total = total + 1
    fails = fails + ps_check("chain.two_impure_calls_in_chain",
        ps_calls_in_chain(irf_tw, "effect"), 2)
    total = total + 1
    fails = fails + ps_check("chain.two_pure_call_untouched",
        ps_calls_in_chain(irf_tw, "pure_add"), 0)
    // IR_CALL_EXTERN takes part in the state dependency; stores before and after
    // give touch 3.
    irf_ex := ps_ir_index_of("chain_extern_op")
    n_ex := ps_op_node(irf_ex, IR_CALL_EXTERN)
    total = total + 1
    fails = fails + ps_check_b("chain.extern_op_exists", (n_ex >= 0), true)
    total = total + 1
    fails = fails + ps_check("chain.extern_op_pierced", ps_state_touch(n_ex), 3)
    // IR_SPAWN, emitted for each range-go iteration, takes part in the state dependency.
    irf_sp := ps_ir_index_of("chain_spawn_op")
    n_sp := ps_op_node(irf_sp, IR_SPAWN)
    total = total + 1
    fails = fails + ps_check_b("chain.spawn_op_exists", (n_sp >= 0), true)
    total = total + 1
    fails = fails + ps_check("chain.spawn_op_in_chain", ps_has_state_in(n_sp), 1)
    // IR_YIELD in a flow function body takes part in the state dependency.
    irf_yl := ps_ir_index_of("chain_yield_op")
    n_yl := ps_op_node(irf_yl, IR_YIELD)
    total = total + 1
    fails = fails + ps_check_b("chain.yield_op_exists", (n_yl >= 0), true)
    total = total + 1
    fails = fails + ps_check("chain.yield_op_pierced", ps_state_touch(n_yl), 3)

    print(int_str(total - fails))
    print("/")
    print(int_str(total))
    println(" purity cases passed")
    if fails != 0:
        return 1
    return 0
