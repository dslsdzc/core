// === opt.cr ===
// CFIR optimization passes.
// Reads/writes g_ir_instrs. Only optimizes, never changes semantics.
// Optimizations run after ir_gen_all() and before lower_to_ccr().

g_opt_level : int, mut;

// ------------------------------------------------------------------
// Helpers: find constant definition of an IR var
// ------------------------------------------------------------------

fn find_const_val(var_idx: int) -> int {
    i : ., mut = g_ir_instr_count - 1;
    loop {
        if i < 0 { return -1; }
        if iri_op(i) == IR_CONST && iri_dest(i) == var_idx { return iri_s1(i); }
        i = i - 1;
    }
    return -1;
}

fn find_const_type(var_idx: int) -> int {
    i : ., mut = g_ir_instr_count - 1;
    loop {
        if i < 0 { return -1; }
        if iri_op(i) == IR_CONST && iri_dest(i) == var_idx { return iri_tk(i); }
        i = i - 1;
    }
    return -1;
}

// ------------------------------------------------------------------
// Pass 1: Constant folding
// ------------------------------------------------------------------

fn opt_const_fold() {
    i : ., mut = 0;
    loop {
        if i >= g_ir_instr_count { break; }
        op := iri_op(i);
        if op == IR_BINARY {
            d := iri_dest(i); s1 := iri_s1(i); s2 := iri_s2(i); opc := iri_s3(i); tk := iri_tk(i);
            v1 := find_const_val(s1);
            v2 := find_const_val(s2);
            if v1 >= 0 && v2 >= 0 {
                rv : ., mut = 0;
                if opc == OP_ADD { rv = v1 + v2; }
                else if opc == OP_SUB { rv = v1 - v2; }
                else if opc == OP_MUL { rv = v1 * v2; }
                else if opc == OP_DIV { if v2 != 0 { rv = v1 / v2; } else { i = i + 1; continue; } }
                else if opc == OP_MOD { if v2 != 0 { rv = v1 % v2; } else { i = i + 1; continue; } }
                else if opc == OP_EQ { if v1 == v2 { rv = 1; } }
                else if opc == OP_NE { if v1 != v2 { rv = 1; } }
                else if opc == OP_LT { if v1 < v2 { rv = 1; } }
                else if opc == OP_GT { if v1 > v2 { rv = 1; } }
                else if opc == OP_LE { if v1 <= v2 { rv = 1; } }
                else if opc == OP_GE { if v1 >= v2 { rv = 1; } }
                else if opc == OP_AND { if v1 != 0 && v2 != 0 { rv = 1; } }
                else if opc == OP_OR { if v1 != 0 || v2 != 0 { rv = 1; } }
                iri_set_op(i, IR_CONST);
                iri_set_s1(i, rv);
                iri_set_s2(i, 0);
                iri_set_s3(i, 0);
            }
        }
        i = i + 1;
    }
}

// ------------------------------------------------------------------
// Pass 2: Branch folding
// ------------------------------------------------------------------

fn opt_branch_fold() {
    i : ., mut = 0;
    loop {
        if i >= g_ir_instr_count { break; }
        if iri_op(i) == IR_BRANCH {
            cond_var := iri_s1(i);
            cv := find_const_val(cond_var);
            if cv >= 0 {
                true_lbl := iri_s2(i);
                false_lbl := iri_s3(i);
                if cv != 0 {
                    iri_set_op(i, IR_JUMP);
                    iri_set_s1(i, true_lbl);
                } else {
                    iri_set_op(i, IR_JUMP);
                    iri_set_s1(i, false_lbl);
                }
                iri_set_s2(i, 0);
                iri_set_s3(i, 0);
            }
        }
        i = i + 1;
    }
}

// ------------------------------------------------------------------
// Pass 3: Dead code elimination (CFIR only, DFIR unchanged)
// ------------------------------------------------------------------

fn opt_dce() {
    max_v := g_ir_var_count;
    if max_v <= 0 { return; }
    use_buf := __builtin_alloc(max_v * 8);
    vi : ., mut = 0;
    loop { if vi >= max_v { break; } w64(use_buf, vi * 8, 0); vi = vi + 1; }
    i : ., mut = 0;
    loop {
        if i >= g_ir_instr_count { break; }
        op := iri_op(i); s1 := iri_s1(i); s2 := iri_s2(i);
        if (op == IR_BINARY || op == IR_CALL || op == IR_STORE || op == IR_STORE_FIELD || op == IR_RETURN || op == IR_BRANCH) && s1 >= 0 && s1 < max_v {
            w64(use_buf, s1 * 8, 1); }
        if (op == IR_BINARY || op == IR_CALL || op == IR_STORE_FIELD) && s2 >= 0 && s2 < max_v {
            w64(use_buf, s2 * 8, 1); }
        i = i + 1;
    }
    i = 0;
    loop {
        if i >= g_ir_instr_count { break; }
        op := iri_op(i); d := iri_dest(i);
        if op != IR_CALL && op != IR_STORE && op != IR_STORE_FIELD && d >= 0 && d < max_v {
            used := r64(use_buf, d * 8);
            if used == 0 { iri_set_op(i, IR_NOP); }
        }
        i = i + 1;
    }
}

// ------------------------------------------------------------------
// Main entry
// ------------------------------------------------------------------

fn optimize_ir() {
    if g_opt_level < 1 { return; }
    opt_const_fold();
    opt_branch_fold();
    if g_opt_level >= 2 {
        opt_dce();
    }
}
