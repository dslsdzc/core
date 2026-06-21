// === pass.cr ===
// IR-level pass dispatcher.
//
// dispatch_call routes SYM_SO_FN calls to independent handlers
// based on tag_flags. Each handler is a standalone function
// that can later be replaced by a .so plugin hook.
//
// Current handlers:
//   handle_variadic — expand N args → N individual calls
//   handle_auto_str — convert int arg → string via int_str()

// ── Tag checks ──
fn has_variadic(tf: int) -> bool { return tf == 1 || tf == 3; }
fn has_auto_str(tf: int) -> bool { return tf == 2 || tf == 3; }

// ── Variadic handler: N args → N individual IR_CALLs ──
fn handle_variadic(fn_ni: int, ac: int, arg_vars: string) -> int {
    last : ., mut = -1;
    ln_str : ., mut = "";
    fn_name := istr_get(fn_ni);
    fnl := str_len(fn_name);
    // Detect "ln" suffix for automatic newline (println → print + "\n")
    if fnl >= 4 {
        if load8(fn_name, fnl-2) == 108 && load8(fn_name, fnl-1) == 110 { ln_str = "\n"; }
    }
    ai : ., mut = 0;
    loop { if ai >= ac { break; }
        arg_v := r64(arg_vars, ai * 8);
        pd := new_ir_var("p", TI_UNIT);
        emit(IR_CALL, pd, arg_v, 1, fn_ni, 0);
        last = pd;
        ai = ai + 1;
    }
    // Append newline for println variants
    if str_len(ln_str) > 0 {
        nl_ni := str_intern(ln_str);
        track_str(nl_ni);
        nl_v := new_ir_var("nl", TI_STR);
        emit(IR_CONST, nl_v, nl_ni, 0, 0, TI_STR);
        pn := new_ir_var("pn", TI_UNIT);
        emit(IR_CALL, pn, nl_v, 1, str_intern("print"), 0);
        last = pn;
    }
    return last;
}

// ── Auto_str handler: convert int arg to string before call ──
fn handle_auto_str(arg_v: int) -> int {
    if irv_type(arg_v) == TI_INT {
        cv := new_ir_var("conv", TI_STR);
        emit(IR_CALL, cv, arg_v, 1, str_intern("int_str"), 0);
        return cv;
    }
    return arg_v;  // not int → pass through
}

// ── Dispatch: compose handlers according to tags ──
fn dispatch_call(fn_ni: int, ac: int, arg_vars: string) -> int {
    sf := find_so_fn(fn_ni);
    if sf < 0 { return -1; }
    tf := sym_type(sf);
    var := has_variadic(tf);
    as_ := has_auto_str(tf);

    if !var && !as_ { return -1; }

    // Variadic multi-arg: expand, applying auto_str per arg if tagged
    if var && ac > 1 {
        last : ., mut = -1;
        ln_str : ., mut = "";
        fn_name := istr_get(fn_ni);
        fnl := str_len(fn_name);
        if fnl >= 4 {
            if load8(fn_name, fnl-2) == 108 && load8(fn_name, fnl-1) == 110 { ln_str = "\n"; }
        }
        ai : ., mut = 0;
        loop { if ai >= ac { break; }
            arg_v := r64(arg_vars, ai * 8);
            if as_ { arg_v = handle_auto_str(arg_v); }
            pd := new_ir_var("p", TI_UNIT);
            emit(IR_CALL, pd, arg_v, 1, fn_ni, 0);
            last = pd;
            ai = ai + 1;
        }
        if str_len(ln_str) > 0 {
            nl_ni := str_intern(ln_str); track_str(nl_ni);
            nl_v := new_ir_var("nl", TI_STR);
            emit(IR_CONST, nl_v, nl_ni, 0, 0, TI_STR);
            pn := new_ir_var("pn", TI_UNIT);
            emit(IR_CALL, pn, nl_v, 1, str_intern("print"), 0);
            last = pn;
        }
        return last;
    }

    // Single arg: apply auto_str, then emit single call
    if ac == 1 {
        arg_v := r64(arg_vars, 0);
        if as_ { arg_v = handle_auto_str(arg_v); }
        pd := new_ir_var("p", TI_UNIT);
        emit(IR_CALL, pd, arg_v, 1, fn_ni, 0);
        return pd;
    }

    return -1;
}
