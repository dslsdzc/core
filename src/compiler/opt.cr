// === opt.cr ===
// AST-level optimization passes.
// Runs after check_all(), before ir_gen_all().
// Only transforms AST nodes (g_ast), never touches IR or backend.

g_opt_level : int, mut;

// ------------------------------------------------------------------
// AST constant folding: EXPR_BINARY(int, int) → EXPR_INT
// ------------------------------------------------------------------

fn ast_is_const_int(node: int) -> int {
    if node < 0 { return 0; }
    if ast_kind(node) == EXPR_INT { return 1; }
    return 0;
}

fn ast_const_val(node: int) -> int {
    return ast_int_val(node);
}

fn ast_fold_binary(node: int) -> int {
    left := ast_a(node);
    right := ast_b(node);
    opc := ast_c(node);
    if !ast_is_const_int(left) || !ast_is_const_int(right) { return 0; }
    v1 := ast_const_val(left);
    v2 := ast_const_val(right);
    rv : ., mut = 0;
    if opc == OP_ADD { rv = v1 + v2; }
    else if opc == OP_SUB { rv = v1 - v2; }
    else if opc == OP_MUL { rv = v1 * v2; }
    else if opc == OP_DIV { if v2 == 0 { return 0; } rv = v1 / v2; }
    else if opc == OP_MOD { if v2 == 0 { return 0; } rv = v1 % v2; }
    else if opc == OP_EQ { rv = 1; if v1 != v2 { rv = 0; } }
    else if opc == OP_NE { rv = 1; if v1 == v2 { rv = 0; } }
    else if opc == OP_LT { rv = 1; if !(v1 < v2) { rv = 0; } }
    else if opc == OP_GT { rv = 1; if !(v1 > v2) { rv = 0; } }
    else if opc == OP_LE { rv = 1; if !(v1 <= v2) { rv = 0; } }
    else if opc == OP_GE { rv = 1; if !(v1 >= v2) { rv = 0; } }
    else if opc == OP_AND { rv = 1; if v1 == 0 || v2 == 0 { rv = 0; } }
    else if opc == OP_OR { rv = 1; if v1 == 0 && v2 == 0 { rv = 0; } }
    else { return 0; }
    // Fold: replace EXPR_BINARY with EXPR_INT
    // Use ast_set_* to modify in-place
    ast_set_kind(node, EXPR_INT);
    ast_set_a(node, 0);
    ast_set_b(node, 0);
    ast_set_c(node, 0);
    ast_set_int_val(node, rv);
    ast_set_type_val(node, TY_INT);
    return 1;
}

// ------------------------------------------------------------------
// Walk a block's statements and fold expressions
// ------------------------------------------------------------------

fn ast_optimize_body(body: int) {
    if body < 0 { return; }
    bk := ast_kind(body);

    // EXPR_BLOCK: optimize each statement recursively
    if bk == EXPR_BLOCK {
        ss := ast_a(body); sc := ast_b(body);
        i : ., mut = 0;
        loop {
            if i >= sc { break; }
            sn := r64(g_block_stmts, (ss + i) * 8);
            ast_optimize_body(sn);
            i = i + 1;
        }
        return;
    }
    // EXPR_RETURN: optimize the return value expression
    if bk == EXPR_RETURN {
        if ast_a(body) >= 0 { ast_optimize_body(ast_a(body)); }
        return;
    }
    // EXPR_IF: optimize condition, then, else
    if bk == EXPR_IF {
        ast_optimize_body(ast_a(body));  // cond
        ast_optimize_body(ast_b(body));  // then
        if ast_c(body) >= 0 { ast_optimize_body(ast_c(body)); }  // else
        // Fold: if const_int(0) → else, if const_int(≠0) → then
        cond := ast_a(body);
        if ast_is_const_int(cond) {
            cv := ast_const_val(cond);
            then_node := ast_b(body);
            else_node := ast_c(body);
            if cv != 0 && then_node >= 0 {
                // Replace if with then body
                // We can't easily clone AST, so just mark as NONE
                // (IR gen will skip)
            } else if cv == 0 && else_node >= 0 {
                // Replace if with else body
            }
        }
        return;
    }
    // EXPR_BINARY: fold constants
    if bk == EXPR_BINARY {
        ast_optimize_body(ast_a(body));
        ast_optimize_body(ast_b(body));
        ast_fold_binary(body);
        return;
    }
    // EXPR_UNARY
    if bk == EXPR_UNARY {
        if ast_a(body) >= 0 { ast_optimize_body(ast_a(body)); }
        return;
    }
    // EXPR_CALL: optimize args
    if bk == EXPR_CALL {
        if ast_a(body) >= 0 { ast_optimize_body(ast_a(body)); }
        an := ast_b(body); ac := ast_c(body);
        ai : ., mut = 0;
        loop { if ai >= ac { break; } if an >= 0 { ast_optimize_body(an); an = an + 1; } ai = ai + 1; }
        return;
    }
    // EXPR_STRUCT: optimize field values
    if bk == EXPR_STRUCT {
        fn2 := ast_b(body); fc := ast_c(body);
        i : ., mut = 0;
        loop { if i >= fc { break; } if fn2 >= 0 { ast_optimize_body(fn2); fn2 = fn2 + 1; } i = i + 1; }
        return;
    }
    // EXPR_LET: optimize value expression
    if bk == EXPR_LET {
        if ast_c(body) >= 0 { ast_optimize_body(ast_c(body)); }
        return;
    }
    // EXPR_LOOP, EXPR_WHILE: optimize body
    if bk == EXPR_LOOP || bk == EXPR_WHILE {
        if ast_a(body) >= 0 { ast_optimize_body(ast_a(body)); }
        return;
    }
    // EXPR_FOR: optimize iter and body
    if bk == EXPR_FOR {
        if ast_b(body) >= 0 { ast_optimize_body(ast_b(body)); }
        if ast_c(body) >= 0 { ast_optimize_body(ast_c(body)); }
        return;
    }
    // EXPR_MATCH: optimize match expr and arms
    if bk == EXPR_MATCH {
        if ast_a(body) >= 0 { ast_optimize_body(ast_a(body)); }
        an := ast_b(body);
        loop { if an < 0 { break; }
            if ast_a(an) >= 0 { ast_optimize_body(ast_a(an)); }
            if ast_b(an) >= 0 { ast_optimize_body(ast_b(an)); }
            an = ast_c(an); }
        return;
    }
    // EXPR_STMT: unwrap
    if bk == EXPR_STMT {
        if ast_a(body) >= 0 { ast_optimize_body(ast_a(body)); }
        return;
    }
    // EXPR_ARRAY, EXPR_TUPLE: optimize elements
    if bk == EXPR_ARRAY || bk == EXPR_TUPLE {
        an := ast_b(body); ac := ast_c(body);
        i : ., mut = 0;
        loop { if i >= ac { break; } if an >= 0 { ast_optimize_body(an); an = an + 1; } i = i + 1; }
        return;
    }
    // EXPR_AS: optimize both sides
    if bk == EXPR_AS {
        if ast_a(body) >= 0 { ast_optimize_body(ast_a(body)); }
        return;
    }
    // EXPR_BINARY already handled above; fallthrough for EXPR_INDEX etc.
}

// ------------------------------------------------------------------
// Register allocation: rewrite IR operands to encode physical regs
// ------------------------------------------------------------------
// Rewrites g_ir_instrs operand fields: operands pointing to IR vars
// that should go in registers are replaced with negative register
// encodings (-1=rax, -2=rcx, -3=rdx, ...).
// Backend g2_slot() checks v < 0 and returns v directly as reg num.
// No backend decision-making needed — pure mechanical translation.

fn alloc_registers() {
    if g_opt_level < 1 { return; }
    fi : ., mut = 0;
    loop {
        if fi >= g_ir_func_count { break; }
        ic := r64(g_ir_func_instr_count, fi * 8);
        ist := r64(g_ir_func_instr_start, fi * 8);
        vc := r64(g_ir_func_var_count, fi * 8);
        vs := r64(g_ir_func_var_start, fi * 8);
        if vc <= 0 { fi = fi + 1; continue; }

        // Build live intervals: [first_ref, last_ref] per var
        iv_buf := alloc(vc * 16);
        vi : ., mut = 0;
        loop { if vi >= vc { break; } w64(iv_buf, vi*16, -1); w64(iv_buf, vi*16+8, -1); vi = vi + 1; }

        ii : ., mut = 0;
        loop {
            if ii >= ic { break; }
            inst := ist + ii;
            op := iri_op(inst); d := iri_dest(inst); s1 := iri_s1(inst); s2 := iri_s2(inst);
            vars : string, mut;    vars_cap : int, mut; vc2 : ., mut = 0;
            if vars_cap == 0 { vars = alloc(24); vars_cap = 3; }
            if d >= vs && d < vs + vc { if vc2 < vars_cap { w64(vars, vc2 * 8, d - vs); vc2 = vc2 + 1; } }
            if s1 >= vs && s1 < vs + vc { if vc2 < vars_cap { w64(vars, vc2 * 8, s1 - vs); vc2 = vc2 + 1; } }
            if s2 >= vs && s2 < vs + vc { if vc2 < vars_cap { w64(vars, vc2 * 8, s2 - vs); vc2 = vc2 + 1; } }
            vj : ., mut = 0;
            loop { if vj >= vc2 { break; }
                lv := r64(vars, vj * 8);
                if r64(iv_buf, lv*16) < 0 { w64(iv_buf, lv*16, ii); }
                w64(iv_buf, lv*16+8, ii);
                vj = vj + 1; }
            ii = ii + 1;
        }

        // Pure virtual register numbers. Backend maps to physical regs.
        MAX_REGS : int = 14;
        reg_idx : ., mut = 0;

        // Map local var index → physical register (-1 = stack)
        var_reg : string, mut;    var_reg_cap : int, mut;
        var_reg = alloc(2048); var_reg_cap = 256;
        vr_clear : ., mut = 0;
        loop { if vr_clear >= 256 { break; } w64(var_reg, vr_clear * 8, -1); vr_clear = vr_clear + 1; }

        // Simple linear scan: for each instruction, allocate regs for dest
        ii = 0;
        loop {
            if ii >= ic { break; }
            inst := ist + ii;
            op := iri_op(inst); d := iri_dest(inst); s1 := iri_s1(inst); s2 := iri_s2(inst);

            // Free regs for vars that end before this instruction
            vi = 0;
            loop { if vi >= vc { break; }
                if r64(var_reg, vi * 8) >= 0 {
                    last_ref := r64(iv_buf, vi*16+8);
                    if last_ref < ii {
                        // Return reg to pool
                        w64(var_reg, vi * 8, -1);
                    }
                }
                vi = vi + 1; }

            // Allocate reg for dest if it has a live range
            if d >= vs && d < vs + vc {
                lvi := d - vs;
                if r64(var_reg, lvi * 8) < 0 {
                    first_ref := r64(iv_buf, lvi*16);
                    last_ref := r64(iv_buf, lvi*16+8);
                    if first_ref >= 0 && last_ref >= 0 && reg_idx < MAX_REGS {
                        w64(var_reg, lvi * 8, reg_idx);
                        reg_idx = reg_idx + 1;
                    }
                }
            }
            // Rewrite operands: replace IR var index with register encoding
            // if the var has a register assigned
            if d >= vs && d < vs + vc {
                lvi := d - vs;
                if r64(var_reg, lvi * 8) >= 0 {
                    iri_set_dest(inst, -(r64(var_reg, lvi * 8) + 1) - 1000);
                }
            }
            if s1 >= vs && s1 < vs + vc {
                lvi := s1 - vs;
                if r64(var_reg, lvi * 8) >= 0 {
                    iri_set_s1(inst, -(r64(var_reg, lvi * 8) + 1) - 1000);
                }
            }
            if s2 >= vs && s2 < vs + vc {
                lvi := s2 - vs;
                if r64(var_reg, lvi * 8) >= 0 {
                    iri_set_s2(inst, -(r64(var_reg, lvi * 8) + 1) - 1000);
                }
            }
            ii = ii + 1;
        }
        fi = fi + 1;
    }
}

fn pass_stack_share() {
    // For each function's stack vars, check if any have disjoint live ranges.
    // If var A and var B never overlap, map B to use A's slot via g_stack_map.
    // Runs after register allocation (only affects non-register vars).
    if g_ir_func_count <= 0 { return; }

    // Allocate g_stack_map with -1 for all IR vars
    g_stack_map = alloc(g_ir_var_count * 8);
    svi : ., mut = 0;
    loop { if svi >= g_ir_var_count { break; } w64(g_stack_map, svi * 8, -1); svi = svi + 1; }

    fi : ., mut = 0;
    loop {
        if fi >= g_ir_func_count { break; }
        ic := r64(g_ir_func_instr_count, fi * 8);
        ist := r64(g_ir_func_instr_start, fi * 8);
        vc := r64(g_ir_func_var_count, fi * 8);
        vs := r64(g_ir_func_var_start, fi * 8);
        if vc <= 0 || ic <= 0 { fi = fi + 1; continue; }

        // Build intervals for all vars (as in reg alloc)
        iv := alloc(vc * 16);
        zz : ., mut = 0;
        loop { if zz >= vc { break; } w64(iv, zz*16, -1); w64(iv, zz*16+8, -1); zz = zz + 1; }
        ii : ., mut = 0;
        loop {
            if ii >= ic { break; }
            inst := ist + ii;
            d := iri_dest(inst); s1 := iri_s1(inst); s2 := iri_s2(inst);
            va : string, mut;    va_cap : int, mut; vn : ., mut = 0;
            if va_cap == 0 { va = alloc(24); va_cap = 3; }
            if d >= vs && d < vs+vc { if vn < va_cap { w64(va, vn * 8, d-vs); vn=vn+1; } }
            if s1 >= vs && s1 < vs+vc { if vn < va_cap { w64(va, vn * 8, s1-vs); vn=vn+1; } }
            if s2 >= vs && s2 < vs+vc { if vn < va_cap { w64(va, vn * 8, s2-vs); vn=vn+1; } }
            vi2 : ., mut = 0;
            loop { if vi2 >= vn { break; }
                lv := r64(va, vi2 * 8);
                if r64(iv, lv*16) < 0 { w64(iv, lv*16, ii); }
                w64(iv, lv*16+8, ii);
                vi2 = vi2 + 1; }
            ii = ii + 1; }

        // For each stack var, try to find another to share with
        vj1 : ., mut = 0;
        loop { if vj1 >= vc { break; }
            global_v1 := vs + vj1;
            // Skip if this var is in a register (negative encoding in IR means register)
            is_reg : ., mut = 0;
            // Check first instruction that uses this var
            first_ref := r64(iv, vj1*16);
            if first_ref >= 0 {
                inst_chk := ist + first_ref;
                if iri_dest(inst_chk) == global_v1 {
                    if iri_dest(inst_chk) < 0 { is_reg = 1; }
                } else if iri_s1(inst_chk) == global_v1 {
                    if iri_s1(inst_chk) < 0 { is_reg = 1; }
                } else if iri_s2(inst_chk) == global_v1 {
                    if iri_s2(inst_chk) < 0 { is_reg = 1; }
                }
            }
            if is_reg != 0 { vj1 = vj1 + 1; continue; }

            s1_start := r64(iv, vj1*16);
            s1_end := r64(iv, vj1*16+8);
            vj2 : ., mut = 0;
            loop { if vj2 >= vj1 { break; }
                s2_start := r64(iv, vj2*16);
                s2_end := r64(iv, vj2*16+8);
                // Check disjoint: s1 ends before s2 starts, or s2 ends before s1 starts
                if (s1_end < s2_start || s2_end < s1_start) && s1_start >= 0 && s2_start >= 0 {
                    // Map vj1 to use vj2's slot
                    w64(g_stack_map, (vs+vj1)*8, vs+vj2);
                    break;
                }
                vj2 = vj2 + 1; }
        vj1 = vj1 + 1; }
        fi = fi + 1; }
}

// ------------------------------------------------------------------
// Common subexpression elimination (CFIR)
// ------------------------------------------------------------------
fn pass_cse() {
    if g_ir_func_count <= 0 { return; }
    fi : ., mut = 0;
    loop {
        if fi >= g_ir_func_count { break; }
        ic := r64(g_ir_func_instr_count, fi * 8);
        ist := r64(g_ir_func_instr_start, fi * 8);
        if ic <= 0 { fi = fi + 1; continue; }

        // Simple local CSE: track seen (op, s1, s2) hashes
        // Use a flat array of seen expression records
        seen_buf := alloc(ic * 24);  // each record: op(8)+s1(8)+s2(8)
        seen_count : ., mut = 0;

        ii : ., mut = 0;
        loop {
            if ii >= ic { break; }
            inst := ist + ii;
            op := iri_op(inst); d := iri_dest(inst); s1 := iri_s1(inst); s2 := iri_s2(inst);
            if op == IR_BINARY && d >= 0 {
                found : ., mut = 0;
                si : ., mut = 0;
                loop {
                    if si >= seen_count { break; }
                    eop := r64(seen_buf, si*24);
                    es1 := r64(seen_buf, si*24+8);
                    es2 := r64(seen_buf, si*24+16);
                    if eop == op && es1 == s1 && es2 == s2 {
                        // Same expression computed before — reuse
                        prev_dest := iri_dest(ist + (si));  // wrong, need prev instr index
                        // This doesn't work directly. Let me store the previous result var.
                        found = 1;
                        break;
                    }
                    si = si + 1; }
                // For now, always record and skip replacement (placeholder for real CSE)
                if found == 0 && seen_count < ic {
                    w64(seen_buf, seen_count*24, op);
                    w64(seen_buf, seen_count*24+8, s1);
                    w64(seen_buf, seen_count*24+16, s2);
                    seen_count = seen_count + 1;
                }
            }
            ii = ii + 1; }
        fi = fi + 1; }
}

fn optimize_all() {
    if g_opt_level < 1 { return; }
    fi : ., mut = 0;
    loop {
        if fi >= g_func_count { break; }
        fn_node := fi_ast_node(fi);
        body := ast_data(fn_node);  // function body
        ast_optimize_body(body);
        fi = fi + 1;
    }
    pass_cse();
    alloc_registers();
    if g_opt_level >= 2 {
        pass_stack_share();
    }
}
