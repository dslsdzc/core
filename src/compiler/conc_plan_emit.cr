// === conc_plan_emit.cr ===
// CP-2 restricted concurrency-plan emitter.
//
// Recognizes one vertical slice: exactly one `go`/`conc_go` in `main`, with
// `chan_make` arguments that have unique reaching definitions in `main`, no
// nested loop/if around either call, and a 0/1-parameter string-typed spawn
// target. Multiple channels are bound by the handle store after `chan_make`.
// Anything else fails closed with no artifact. The emitted plan is
// target-neutral text; it does not enter `.ccr`.

CONC_EMIT_UNKNOWN : int = -999999

fn _conc_emit_remove(path: string):
    // unlink(2); the artifact command owns its output path.
    r := syscall3(87, path, 0, 0)
    if r < 0:
        return

fn _conc_emit_main_func() -> int:
    i : ., mut = 0
    loop:
        if i >= g_ir_func_count:
            break
        ni := cell_load(g_ir_func_name_idx, i * 8)
        if str_eq(istr_get(ni), "main") != 0:
            return i
        i = i + 1
    return -1

fn _conc_emit_find_func(name_ni: int) -> int:
    i : ., mut = 0
    loop:
        if i >= g_ir_func_count:
            break
        if str_eq(istr_get(cell_load(g_ir_func_name_idx, i * 8)), istr_get(name_ni)) != 0:
            return i
        i = i + 1
    return -1

// Reject go/chan_make inside a loop/if/flow/unsafe subgraph. A static plan
// cannot represent a call that may execute zero or many times.
fn _conc_emit_in_nested(ii: int) -> int:
    i : ., mut = 0
    loop:
        if i >= g_sg_count:
            break
        kind := cell_load(g_sgs, i * ESZ_SG + OFF_SG_KIND)
        if kind != SG_FUNC:
            s := cell_load(g_sgs, i * ESZ_SG + OFF_SG_NSTART)
            n := cell_load(g_sgs, i * ESZ_SG + OFF_SG_NCOUNT)
            if ii >= s && ii < s + n:
                return 1
        i = i + 1
    return 0

// Resolve a variable to a constant through the unique defining instruction
// before call_ii in this function. Multiple definitions, a definition after the
// call, or a non-constant definition return CONC_EMIT_UNKNOWN.
fn _conc_emit_const_before(var: int, call_ii: int, func_start: int) -> int:
    v : ., mut = var
    limit : ., mut = call_ii
    k : ., mut = 0
    loop:
        if k >= 8:
            return CONC_EMIT_UNKNOWN
        i : ., mut = func_start
        defs : ., mut = 0
        def_at : ., mut = -1
        def_val : ., mut = CONC_EMIT_UNKNOWN
        def_src : ., mut = -1
        loop:
            if i >= limit:
                break
            op := iri_op(i)
            if op == IR_REF || op == IR_PTR_OF:
                if iri_s1(i) == v:
                    return CONC_EMIT_UNKNOWN
            if iri_dest(i) == v:
                if op != IR_ALLOC:
                    if _conc_emit_in_nested(i) != 0:
                        return CONC_EMIT_UNKNOWN
                    defs = defs + 1
                    def_at = i
                    if op == IR_CONST:
                        def_val = iri_s1(i)
                    else:
                        def_val = CONC_EMIT_UNKNOWN
            else:
                if op == IR_STORE:
                    if iri_s1(i) == v:
                        if _conc_emit_in_nested(i) != 0:
                            return CONC_EMIT_UNKNOWN
                        defs = defs + 1
                        def_at = i
                        def_val = CONC_EMIT_UNKNOWN
                        def_src = iri_s2(i)
            i = i + 1
        if defs != 1:
            return CONC_EMIT_UNKNOWN
        if def_val != CONC_EMIT_UNKNOWN:
            return def_val
        if def_src < 0:
            return CONC_EMIT_UNKNOWN
        v = def_src
        limit = def_at
        k = k + 1
    return CONC_EMIT_UNKNOWN

// Resolve the function-name index of the `@addr(f)` argument used by
// sched_go. Same unique-definition discipline as _conc_emit_const_before.
fn _conc_emit_fnaddr_before(var: int, call_ii: int, func_start: int) -> int:
    v : ., mut = var
    limit : ., mut = call_ii
    k : ., mut = 0
    loop:
        if k >= 8:
            return -1
        i : ., mut = func_start
        defs : ., mut = 0
        def_at : ., mut = -1
        fn_ni : ., mut = -1
        src : ., mut = -1
        loop:
            if i >= limit:
                break
            op := iri_op(i)
            if op == IR_FNADDR:
                if iri_dest(i) == v:
                    if op != IR_ALLOC:
                        if _conc_emit_in_nested(i) != 0:
                            return -1
                        defs = defs + 1
                        def_at = i
                        fn_ni = iri_s1(i)
            else:
                if op == IR_STORE:
                    if iri_s1(i) == v:
                        if _conc_emit_in_nested(i) != 0:
                            return -1
                        defs = defs + 1
                        def_at = i
                        src = iri_s2(i)
            i = i + 1
        if defs != 1:
            return -1
        if fn_ni >= 0:
            return fn_ni
        if src < 0:
            return -1
        v = src
        limit = def_at
        k = k + 1
    return -1

// Classify a call argument against the spawn target's parameter variable.
// Returns 1 when the argument resolves to that parameter through stores,
// 2 when the resolution chain exceeds 8 steps, and 0 otherwise.
fn _conc_emit_uses_param(arg: int, param_var: int, call_ii: int, func_start: int) -> int:
    if arg == param_var:
        return 1
    v : ., mut = arg
    limit : ., mut = call_ii
    k : ., mut = 0
    loop:
        if k >= 8:
            return 2
        i : ., mut = func_start
        defs : ., mut = 0
        def_at : ., mut = -1
        src : ., mut = -1
        bad : ., mut = 0
        loop:
            if i >= limit:
                break
            op := iri_op(i)
            if op == IR_REF || op == IR_PTR_OF:
                if iri_s1(i) == v:
                    return 0
            if iri_dest(i) == v:
                if op != IR_ALLOC:
                    defs = defs + 1
                    def_at = i
                    bad = 1
            else:
                if op == IR_STORE:
                    if iri_s1(i) == v:
                        defs = defs + 1
                        def_at = i
                        src = iri_s2(i)
            i = i + 1
        if defs != 1 || bad != 0:
            return 0
        if src == param_var:
            return 1
        if src < 0:
            return 0
        v = src
        limit = def_at
        k = k + 1
    return 0

// Find the store that binds a chan_make result to its handle. The store must
// follow the call and precede the next call or 8 instructions; returns the
// instruction index, or -1 when the handle cannot be identified.
fn _conc_emit_handle_after(call_ii: int, end: int) -> int:
    j : ., mut = call_ii + 1
    k : ., mut = 0
    loop:
        if j >= end:
            return -1
        if k >= 8:
            return -1
        if iri_op(j) == IR_CALL:
            return -1
        if iri_op(j) == IR_STORE:
            if iri_s1(j) >= 0:
                return j
        j = j + 1
        k = k + 1
    return -1

// Locate the single non-alloc definition of `var` before `call_ii` and reject
// references taken from it or definitions inside a nested region. Returns the
// defining instruction index, or -1 when the definition is not unique.
fn _conc_emit_unique_def(var: int, call_ii: int, func_start: int) -> int:
    i : ., mut = func_start
    defs : ., mut = 0
    def_at : ., mut = -1
    loop:
        if i >= call_ii:
            break
        op := iri_op(i)
        if op == IR_REF || op == IR_PTR_OF:
            if iri_s1(i) == var:
                return -1
        if iri_dest(i) == var:
            if op != IR_ALLOC:
                defs = defs + 1
                def_at = i
        else:
            if op == IR_STORE:
                if iri_s1(i) == var:
                    defs = defs + 1
                    def_at = i
        i = i + 1
    if defs != 1:
        return -1
    if _conc_emit_in_nested(def_at) != 0:
        return -1
    return def_at

// Resolve a spawn argument to an index in cvars/cstores by following stores
// back to a chan_make handle. The handle's unique definition must equal the
// store recorded for that channel; returns the channel index or -1.
fn _conc_emit_arg_channel(var: int, call_ii: int, func_start: int, cvars: string, cstores: string, nchan: int) -> int:
    v : ., mut = var
    limit : ., mut = call_ii
    k : ., mut = 0
    loop:
        if k >= 8:
            return -1
        i : ., mut = func_start
        defs : ., mut = 0
        def_at : ., mut = -1
        src : ., mut = -1
        bad : ., mut = 0
        loop:
            if i >= limit:
                break
            op := iri_op(i)
            if op == IR_REF || op == IR_PTR_OF:
                if iri_s1(i) == v:
                    return -1
            if iri_dest(i) == v:
                if op != IR_ALLOC:
                    defs = defs + 1
                    def_at = i
                    bad = 1
            else:
                if op == IR_STORE:
                    if iri_s1(i) == v:
                        defs = defs + 1
                        def_at = i
                        src = iri_s2(i)
            i = i + 1
        if defs != 1 || bad != 0:
            return -1
        if src < 0:
            return -1
        ci : ., mut = 0
        loop:
            if ci >= nchan:
                break
            if cell_load(cvars, ci * 8) == src:
                hd := _conc_emit_unique_def(src, call_ii, func_start)
                if hd != cell_load(cstores, ci * 8):
                    return -1
                return ci
            ci = ci + 1
        v = src
        limit = def_at
        k = k + 1
    return -1

fn _conc_emit_error(msg: string) -> int:
    print("error: conc-plan unsupported: ")
    println(msg)
    return 1

// Emit a target-neutral concurrency plan for the restricted slice recognized
// in `main`. Fails closed: any unsupported shape returns 1 without an artifact,
// so a plan exists only when every check passes.
fn conc_plan_emit_write(path: string) -> int:
    _conc_emit_remove(path)

    fi := _conc_emit_main_func()
    if fi < 0:
        return _conc_emit_error("no main function")
    if cell_load(g_ir_func_param_count, fi * 8) != 0:
        return _conc_emit_error("main with parameters is not supported")
    start := cell_load(g_ir_func_instr_start, fi * 8)
    count := cell_load(g_ir_func_instr_count, fi * 8)

    go_count : ., mut = 0
    range_mode : ., mut = 0
    range_fn_ni : ., mut = -1
    range_start : ., mut = -1
    range_count : ., mut = -1
    go_fn_ni : ., mut = -1
    go_arg_var : ., mut = -1
    go_call_ii : ., mut = -1
    chan_count : ., mut = 0
    cvars := alloc(64 * 8)
    cstores := alloc(64 * 8)
    i : ., mut = 0
    loop:
        if i >= count:
            break
        ii := start + i
        if iri_op(ii) == IR_CALL:
            name := istr_get(iri_s3(ii))
            if str_eq(name, "conc_plan_mark_range") != 0:
                if iri_s2(ii) != 3:
                    return _conc_emit_error("range marker arity is not 3")
                if range_mode != 0:
                    return _conc_emit_error("multiple range-go sites are not supported")
                range_mode = 1
                range_fn_ni = _conc_emit_fnaddr_before(iri_s1(ii), ii, start)
                range_start = _conc_emit_const_before(iri_s1(ii) + 1, ii, start)
                range_count = _conc_emit_const_before(iri_s1(ii) + 2, ii, start)
            else:
                if str_eq(name, "sched_go") != 0 || str_eq(name, "conc_go") != 0:
                    if range_mode != 0:
                        // Part of the lowered range-go loop; the range record
                        // already describes it.
                        i = i + 1
                        continue
                    if iri_s2(ii) != 2:
                        return _conc_emit_error("sched_go arity is not 2")
                    if _conc_emit_in_nested(ii) != 0:
                        return _conc_emit_error("go inside loop/if is not supported")
                    go_count = go_count + 1
                    go_call_ii = ii
                    go_arg_var = iri_s1(ii) + 1
                    go_fn_ni = _conc_emit_fnaddr_before(iri_s1(ii), ii, start)
                    if go_fn_ni < 0:
                        return _conc_emit_error("cannot resolve go target")
                else:
                    if str_eq(name, "chan_make") != 0:
                        if range_mode != 0:
                            i = i + 1
                            continue
                        if iri_s2(ii) != 2:
                            return _conc_emit_error("chan_make arity is not 2")
                        if _conc_emit_in_nested(ii) != 0:
                            return _conc_emit_error("chan_make inside loop/if is not supported")
                        if chan_count >= 64:
                            return _conc_emit_error("too many chan_make sites")
                        hstore := _conc_emit_handle_after(ii, start + count)
                        if hstore < 0:
                            return _conc_emit_error("cannot resolve chan_make handle")
                        cell_store(cvars, chan_count * 8, iri_s1(hstore))
                        cell_store(cstores, chan_count * 8, hstore)
                        chan_count = chan_count + 1
        i = i + 1

    if range_mode != 0:
        if go_count != 0:
            return _conc_emit_error("range-go plan cannot mix with single go")
        if range_fn_ni < 0:
            return _conc_emit_error("cannot resolve range target")
        if range_start == CONC_EMIT_UNKNOWN || range_count == CONC_EMIT_UNKNOWN:
            return _conc_emit_error("range bounds are not constants")
        if range_start < 0 || range_count <= 0:
            return _conc_emit_error("range bounds are invalid")
        target_fi := _conc_emit_find_func(range_fn_ni)
        if target_fi < 0:
            return _conc_emit_error("cannot find range target function")
        if cell_load(g_ir_func_param_count, target_fi * 8) != 1:
            return _conc_emit_error("range target must take one int parameter")
        // Range-go plan: body/target/slot records describe one parallel body
        // over [range_start, range_start + range_count), followed by budget,
        // obligation, cert, and edge records.
        out2 : ., mut = "v 2\n"
        out2 = out2 + "entries 2\n"
        out2 = out2 + "body 0 TASK 0 0\n"
        out2 = out2 + "target cpu 1 1\n"
        out2 = out2 + "slot 0 THREAD -1 1\n"
        out2 = out2 + "body 1 PAR 1 " + int_str(range_count) + "\n"
        out2 = out2 + "range 1 " + int_str(range_start) + " " + int_str(range_count) + "\n"
        out2 = out2 + "budget 0 PROGRESSIVE 0 UNKNOWN\n"
        out2 = out2 + "budget 1 COUNT " + int_str(range_count) + " PROVED\n"
        out2 = out2 + "budget 2 WAIT " + int_str(range_count) + " UNKNOWN\n"
        out2 = out2 + "obligation 3 COUNT " + int_str(range_count) + " PROVED 1\n"
        out2 = out2 + "obligation 4 WAIT " + int_str(range_count) + " UNKNOWN 1\n"
        out2 = out2 + "cert 0 1 UNKNOWN\n"
        out2 = out2 + "cert 1 2 UNKNOWN\n"
        out2 = out2 + "edge 0 1 SPAWN -1\n"
        nwritten2 := write_file(path, out2)
        if nwritten2 != str_len(out2):
            _conc_emit_remove(path)
            print("error: could not write ")
            println(path)
            return 1
        print(" -> ")
        return 0

    if go_count != 1:
        return _conc_emit_error("exactly one go in main is supported")
    if chan_count < 1:
        return _conc_emit_error("at least one chan_make in main is required")

    fj : ., mut = 0
    loop:
        if fj >= g_ir_func_count:
            break
        if fj != fi:
            fname := istr_get(cell_load(g_ir_func_name_idx, fj * 8))
            if str_eq(fname, "sched_go") == 0 && str_eq(fname, "conc_go") == 0:
                // Runtime helpers (e.g. conc_plan_run) legitimately call
                // conc_go; only user functions are part of the plan surface.
                owner := func_owner(fj)
                if owner < 0 || lib_kind(owner) == LIB_KIND_USER:
                    fs := cell_load(g_ir_func_instr_start, fj * 8)
                    fc := cell_load(g_ir_func_instr_count, fj * 8)
                    fi2 : ., mut = 0
                    loop:
                        if fi2 >= fc:
                            break
                        ii2 := fs + fi2
                        if iri_op(ii2) == IR_CALL:
                            nm2 := istr_get(iri_s3(ii2))
                            if str_eq(nm2, "conc_go") != 0 || str_eq(nm2, "sched_go") != 0:
                                return _conc_emit_error("go outside main is not supported")
                        fi2 = fi2 + 1
        fj = fj + 1

    target_fi := _conc_emit_find_func(go_fn_ni)
    if target_fi < 0:
        return _conc_emit_error("cannot find go target function")
    go_params := cell_load(g_ir_func_param_count, target_fi * 8)
    if go_params < 0 || go_params > 1:
        return _conc_emit_error("go target must take zero or one parameter")
    bind_ch : ., mut = -1
    if go_params == 1:
        param_var := cell_load(g_ir_func_var_start, target_fi * 8)
        if irv_type(param_var) != TI_STR:
            return _conc_emit_error("go target parameter must be a string/channel")
        if go_arg_var >= 0:
            if _conc_emit_const_before(go_arg_var, go_call_ii, start) != CONC_EMIT_UNKNOWN:
                return _conc_emit_error("literal or missing go argument is not supported")
            bind_ch = _conc_emit_arg_channel(go_arg_var, go_call_ii, start, cvars, cstores, chan_count)
            if bind_ch < 0:
                return _conc_emit_error("go argument is not a chan_make handle")

    pipe_mode : ., mut = 0
    pstart := cell_load(g_ir_func_instr_start, target_fi * 8)
    pcount := cell_load(g_ir_func_instr_count, target_fi * 8)
    pi : ., mut = 0
    loop:
        if pi >= pcount:
            break
        if iri_op(pstart + pi) == IR_YIELD:
            pipe_mode = 1
            break
        pi = pi + 1
    // A spawning worker that yields is a pipeline stage (v 2, PIPE body); one
    // without IR_YIELD is a single task (v 1, TASK body).
    out : ., mut = "v 1\n"
    if pipe_mode != 0:
        out = "v 2\n"
    out = out + "entries 2\n"
    out = out + "body 0 TASK 0 0\n"
    if pipe_mode != 0:
        out = out + "body 1 PIPE 1 " + int_str(go_params) + "\n"
    else:
        out = out + "body 1 TASK 1 " + int_str(go_params) + "\n"

    cid : ., mut = 0
    i = 0
    loop:
        if i >= count:
            break
        ii := start + i
        if iri_op(ii) == IR_CALL:
            if str_eq(istr_get(iri_s3(ii)), "chan_make") != 0:
                a0 := iri_s1(ii)
                a1 := a0 + 1
                elem := _conc_emit_const_before(a0, ii, start)
                cap := _conc_emit_const_before(a1, ii, start)
                if elem == CONC_EMIT_UNKNOWN:
                    return _conc_emit_error("chan_make elem_size is not a unique literal")
                if cap == CONC_EMIT_UNKNOWN:
                    return _conc_emit_error("chan_make cap is not a unique literal")
                if elem <= 0 || cap <= 0:
                    return _conc_emit_error("chan_make elem_size/cap must be positive")
                out = out + "channel " + int_str(cid) + " "
                out = out + int_str(elem) + " " + int_str(cap) + " SPSC\n"
                cid = cid + 1
        i = i + 1

    if cid != chan_count:
        return _conc_emit_error("chan_make scan lost a channel")

    if go_params == 1:
        out = out + "bind 1 0 " + int_str(bind_ch) + "\n"
        out = out + "edge 0 1 SEND " + int_str(bind_ch) + "\n"
        tstart := cell_load(g_ir_func_instr_start, target_fi * 8)
        tcount := cell_load(g_ir_func_instr_count, target_fi * 8)
        param_var := cell_load(g_ir_func_var_start, target_fi * 8)
        ti : ., mut = 0
        loop:
            if ti >= tcount:
                break
            tii := tstart + ti
            if iri_op(tii) == IR_CALL:
                tn := istr_get(iri_s3(tii))
                if str_eq(tn, "chan_recv") != 0:
                    if iri_s2(tii) == 1:
                        wu := _conc_emit_uses_param(iri_s1(tii), param_var, tii, tstart)
                        if wu == 2:
                            return _conc_emit_error("worker channel chain is too long")
                        if wu == 1:
                            out = out + "edge 1 0 RECV " + int_str(bind_ch) + "\n"
                else:
                    if str_eq(tn, "chan_send") != 0:
                        if iri_s2(tii) == 2:
                            wu2 := _conc_emit_uses_param(iri_s1(tii), param_var, tii, tstart)
                            if wu2 == 2:
                                return _conc_emit_error("worker channel chain is too long")
                            if wu2 == 1:
                                out = out + "edge 1 0 SEND " + int_str(bind_ch) + "\n"
            ti = ti + 1
    out = out + "edge 0 1 SPAWN -1\n"
    nwritten := write_file(path, out)
    if nwritten != str_len(out):
        _conc_emit_remove(path)
        print("error: could not write ")
        println(path)
        return 1
    print(" -> ")
    println(path)
    return 0
