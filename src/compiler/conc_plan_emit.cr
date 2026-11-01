// CP-2 restricted concurrency-plan emitter.
//
// Recognizes one vertical slice: exactly one `sched_go` in `main`, with
// literal `chan_make` arguments in `main`, no nested loop/if around either
// call, and a 0/1-parameter string-typed spawn target. Anything else fails
// closed with no artifact. The emitted plan is target-neutral text; it does
// not enter `.ccr`.

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

fn _conc_emit_error(msg: string) -> int:
    print("error: conc-plan unsupported: ")
    println(msg)
    return 1

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
    go_fn_ni : ., mut = -1
    go_arg_var : ., mut = -1
    go_call_ii : ., mut = -1
    chan_count : ., mut = 0
    i : ., mut = 0
    loop:
        if i >= count:
            break
        ii := start + i
        if iri_op(ii) == IR_CALL:
            name := istr_get(iri_s3(ii))
            if str_eq(name, "sched_go") != 0:
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
                    if iri_s2(ii) != 2:
                        return _conc_emit_error("chan_make arity is not 2")
                    if _conc_emit_in_nested(ii) != 0:
                        return _conc_emit_error("chan_make inside loop/if is not supported")
                    chan_count = chan_count + 1
        i = i + 1

    if go_count != 1:
        return _conc_emit_error("exactly one sched_go in main is supported")
    if chan_count != 1:
        return _conc_emit_error("exactly one chan_make in main is supported")

    target_fi := _conc_emit_find_func(go_fn_ni)
    if target_fi < 0:
        return _conc_emit_error("cannot find go target function")
    go_params := cell_load(g_ir_func_param_count, target_fi * 8)
    if go_params < 0 || go_params > 1:
        return _conc_emit_error("go target must take zero or one parameter")
    if go_params == 1:
        param_var := cell_load(g_ir_func_var_start, target_fi * 8)
        if irv_type(param_var) != TI_STR:
            return _conc_emit_error("go target parameter must be a string/channel")
        if go_arg_var >= 0:
            if _conc_emit_const_before(go_arg_var, go_call_ii, start) != CONC_EMIT_UNKNOWN:
                return _conc_emit_error("literal or missing go argument is not supported")

    out : ., mut = "v 1\n"
    out = out + "entries 2\n"
    out = out + "body 0 TASK 0 0\n"
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
        out = out + "bind 1 0 0\n"
        out = out + "edge 0 1 SEND 0\n"
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
