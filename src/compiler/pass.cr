// === pass.cr ===
// IR-level pass dispatcher.
//
// When ir_gen encounters a call to a SYM_SO_FN, dispatch_call
// checks the function's tags and applies the appropriate expansion.
//
// Currently handles: variadic expansion, auto int→str conversion.
//
// Future: these expansions will move out of the compiler into .so plugins.
// dispatch_call will query a handler registry loaded from .so_meta exports.

// ── Dispatch: expand a call according to SYM_SO_FN tags ──
// Called from ir_gen on EXPR_CALL to SO-registered functions.
// Returns IR variable with result, or -1 if no expansion needed
// (caller emits regular IR_CALL instead).
fn dispatch_call(fn_ni: int, ac: int, arg_vars: string) -> int {
    sf := find_so_fn(fn_ni);
    if sf < 0 { return -1; }
    tf := sym_type(sf);
    has_var := (tf == 1 || tf == 3);      // TAG_VARIADIC = bit 0
    has_auto := (tf == 2 || tf == 3);     // TAG_AUTO_STR = bit 1

    // Single arg → no variadic expansion needed (but auto_str may apply)
    if has_var && ac <= 1 { has_var = 0; }

    if !has_var && !has_auto { return -1; }

    // ── Variadic expansion: N args → N individual calls ──
    if has_var {
        last : ., mut = -1;
        ln_str : ., mut = "";
        fn_name := istr_get(fn_ni);
        fnl := str_len(fn_name);
        // Detect "ln" suffix for automatic newline
        if fnl >= 4 {
            if load8(fn_name, fnl-2) == 108 && load8(fn_name, fnl-1) == 110 { ln_str = "\n"; }
        }
        ai : ., mut = 0;
        loop { if ai >= ac { break; }
            arg_v := r64(arg_vars, ai * 8);
            // Auto-convert int → string
            if has_auto && irv_type(arg_v) == TI_INT {
                cv := new_ir_var("conv", TI_STR);
                emit(IR_CALL, cv, arg_v, 1, str_intern("int_str"), 0);
                arg_v = cv;
            }
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

    // ── Single-arg auto_str (e.g. print_i) ──
    if has_auto && ac == 1 {
        arg_v := r64(arg_vars, 0);
        if irv_type(arg_v) == TI_INT {
            cv := new_ir_var("conv", TI_STR);
            emit(IR_CALL, cv, arg_v, 1, str_intern("int_str"), 0);
            pd := new_ir_var("p", TI_UNIT);
            emit(IR_CALL, pd, cv, 1, fn_ni, 0);
            return pd;
        }
    }

    return -1;  // not handled → let caller emit regular IR_CALL
}
