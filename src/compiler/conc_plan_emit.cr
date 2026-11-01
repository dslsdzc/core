// CP-2 restricted concurrency-plan emitter.
//
// This pass is deliberately conservative. It recognizes the first vertical
// slice: exactly one `sched_go` in `main`, with constant `chan_make` calls in
// `main`. Anything else fails closed with no artifact. The emitted plan is
// target-neutral text; it does not enter `.ccr`.

CONC_EMIT_UNKNOWN : int = -999999

// Resolve a variable to an integer literal through IR_CONST / IR_STORE chains.
// Returns CONC_EMIT_UNKNOWN when the value is not a compile-time constant.
fn _conc_emit_const(var: int) -> int:
    v : ., mut = var
    k : ., mut = 0
    loop:
        if k >= 8:
            break
        i : ., mut = 0
        next : ., mut = -1
        loop:
            if i >= g_ir_instr_count:
                break
            op := iri_op(i)
            if op == IR_CONST:
                if iri_dest(i) == v:
                    return iri_s1(i)
            else:
                if op == IR_STORE:
                    if iri_s1(i) == v:
                        next = iri_s2(i)
            i = i + 1
        if next < 0:
            return CONC_EMIT_UNKNOWN
        v = next
        k = k + 1
    return CONC_EMIT_UNKNOWN

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

fn _conc_emit_error(msg: string) -> int:
    print("error: conc-plan unsupported: ")
    println(msg)
    return 1

fn conc_plan_emit_write(path: string) -> int:
    fi := _conc_emit_main_func()
    if fi < 0:
        return _conc_emit_error("no main function")
    start := cell_load(g_ir_func_instr_start, fi * 8)
    count := cell_load(g_ir_func_instr_count, fi * 8)

    go_count : ., mut = 0
    go_arg : ., mut = -1
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
                go_count = go_count + 1
                go_arg = iri_s1(ii) + 1
            else:
                if str_eq(name, "chan_make") != 0:
                    if iri_s2(ii) != 2:
                        return _conc_emit_error("chan_make arity is not 2")
                    chan_count = chan_count + 1
        i = i + 1

    if go_count != 1:
        return _conc_emit_error("exactly one sched_go in main is supported")
    if chan_count < 1:
        return _conc_emit_error("at least one chan_make in main is required")

    go_params : ., mut = 1
    if go_arg >= 0:
        if _conc_emit_const(go_arg) == 0:
            go_params = 0

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
                elem := _conc_emit_const(a0)
                cap := _conc_emit_const(a1)
                if elem == CONC_EMIT_UNKNOWN:
                    return _conc_emit_error("chan_make elem_size is not a literal")
                if cap == CONC_EMIT_UNKNOWN:
                    return _conc_emit_error("chan_make cap is not a literal")
                if elem <= 0 || cap <= 0:
                    return _conc_emit_error("chan_make elem_size/cap must be positive")
                out = out + "channel " + int_str(cid) + " "
                out = out + int_str(elem) + " " + int_str(cap) + " SPSC\n"
                cid = cid + 1
        i = i + 1

    if cid != chan_count:
        return _conc_emit_error("chan_make scan lost a channel")

    out = out + "edge 0 1 SPAWN -1\n"
    if write_file(path, out) < 0:
        print("error: could not write ")
        println(path)
        return 1
    print(" -> ")
    println(path)
    return 0
