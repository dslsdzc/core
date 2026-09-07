// === opt.cr ===
// AST-level optimization passes.
// Runs after check_all(), before ir_gen_all().
// Only transforms AST nodes (g_ast), never touches IR or backend.


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

fn ast_bool_as_int(value: bool) -> int {
    if value { return 1; }
    return 0;
}

fn ast_fold_binary(node: int) -> int {
    left := ast_a(node);
    right := ast_b(node);
    opc := ast_c(node);
    if !ast_is_const_int(left) || !ast_is_const_int(right) { return 0; }
    v1 := ast_const_val(left);
    v2 := ast_const_val(right);
    rv : ., mut = 0;
    known : ., mut = 1;
    if opc == OP_ADD { rv = v1 + v2; }
    else if opc == OP_SUB { rv = v1 - v2; }
    else if opc == OP_MUL { rv = v1 * v2; }
    else if opc == OP_DIV { if v2 == 0 { return 0; } rv = v1 / v2; }
    else if opc == OP_MOD { if v2 == 0 { return 0; } rv = v1 % v2; }
    else if opc == OP_EQ { rv = ast_bool_as_int(v1 == v2); }
    else if opc == OP_NE { rv = ast_bool_as_int(v1 != v2); }
    else if opc == OP_LT { rv = ast_bool_as_int(v1 < v2); }
    else if opc == OP_GT { rv = ast_bool_as_int(v1 > v2); }
    else if opc == OP_LE { rv = ast_bool_as_int(v1 <= v2); }
    else if opc == OP_GE { rv = ast_bool_as_int(v1 >= v2); }
    else if opc == OP_AND { rv = ast_bool_as_int(v1 != 0 && v2 != 0); }
    else if opc == OP_OR { rv = ast_bool_as_int(v1 != 0 || v2 != 0); }
    else { known = 0; }
    if known == 0 { return 0; }
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
    // EXPR_GO: optimize spawned body
    if bk == EXPR_GO {
        if ast_b(body) >= 0 { ast_optimize_body(ast_b(body)); }
        return;
    }
    if bk == EXPR_YIELD {
        if ast_a(body) >= 0 { ast_optimize_body(ast_a(body)); }
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

        // CSE: track seen (op, s1, s2) → dest_var mapping
        // Simple linear scan — sufficient for O1
        seen_count : ., mut = 0;
        // Flat array: each entry = (op:8, s1:8, s2:8, dest:8) = 32 bytes
        seen : string, mut = alloc(ic * 32);
        // Replacement map: var → canonical var (8 bytes each)
        replace_map : string, mut = alloc(ic * 8);
        replace_count : ., mut = 0;

        ii : ., mut = 0;
        loop {
            if ii >= ic { break; }
            inst := ist + ii;
            op := iri_op(inst);
            d := iri_dest(inst);
            s1 := iri_s1(inst);
            s2 := iri_s2(inst);

            // Skip arena opcodes — side-effecting, not optimizable
            if op == IR_ARENA_NEW { ii = ii + 1; continue; }
            if op == IR_ARENA_RESET { ii = ii + 1; continue; }
            if op == IR_INLINE { ii = ii + 1; continue; }
            if op == IR_NO_BOUNDS_CHECK { ii = ii + 1; continue; }
            if op == IR_FAST { ii = ii + 1; continue; }
            if op == IR_UNROLL { ii = ii + 1; continue; }
            if op == IR_APPROX { ii = ii + 1; continue; }
            if op == IR_SECTION { ii = ii + 1; continue; }
            if op == IR_HOTPATCH_ROUTE { ii = ii + 1; continue; }
            if op == IR_DYN_TAG { ii = ii + 1; continue; }
            if op == IR_DYN_VAL { ii = ii + 1; continue; }
            if op == IR_DYN_PACK { ii = ii + 1; continue; }
            if op == IR_DYN_DISPATCH { ii = ii + 1; continue; }
            if op == IR_CALL_EXTERN { ii = ii + 1; continue; }
            if op == IR_LAZY_THUNK { ii = ii + 1; continue; }
            if op == IR_LAZY_FORCE { ii = ii + 1; continue; }
            if op == IR_FNADDR { ii = ii + 1; continue; }

            // Only CSE for pure computations: BINARY, UNARY
            if (op == IR_BINARY || op == IR_UNARY) && d >= 0 {
                // Check if we've seen this expression
                found : ., mut = -1;
                sj : ., mut = 0;
                loop {
                    if sj >= seen_count { break; }
                    so := sj * 32;
                    if r64(seen, so) == op && r64(seen, so+8) == s1 && r64(seen, so+16) == s2 {
                        found = sj; break;
                    }
                    sj = sj + 1;
                }
                if found >= 0 {
                    // Duplicate — record replacement: d → canonical dest
                    canonical := r64(seen, found * 32 + 24);
                    w64(replace_map, replace_count * 8, d);
                    w64(replace_map, replace_count * 8 + 8, canonical);
                    replace_count = replace_count + 1;
                    // NOP this instruction
                    iri_set_op(inst, IR_NOP);
                } else {
                    // New expression — record it
                    so := seen_count * 32;
                    w64(seen, so, op);
                    w64(seen, so+8, s1);
                    w64(seen, so+16, s2);
                    w64(seen, so+24, d);
                    seen_count = seen_count + 1;
                }
            }

            // Apply replacements to operands of ALL instructions
            if replace_count > 0 {
                rj : ., mut = 0;
                loop {
                    if rj >= replace_count { break; }
                    old_v := r64(replace_map, rj * 8);
                    new_v := r64(replace_map, rj * 8 + 8);
                    if iri_s1(inst) == old_v { iri_set_s1(inst, new_v); }
                    if iri_s2(inst) == old_v { iri_set_s2(inst, new_v); }
                    if iri_s3(inst) == old_v { iri_set_s3(inst, new_v); }
                    rj = rj + 1;
                }
            }

            ii = ii + 1;
        }
        fi = fi + 1;
    }
}

fn optimize_all() {
    // Pointer analysis (always runs, even at opt_level 0)
    ptr_analysis_all();
    // RegionCheck: verify DEREF targets are in live subgraphs
    region_check_all();
    // ProvenanceVerify: check DEREF offsets against allocation sizes
    provenance_verify_all();
    if g_opt_level < 1 { return; }
    fi : ., mut = 0;
    loop {
        if fi >= g_func_count { break; }
        fn_node := fi_ast_node(fi);
        body := ast_data(fn_node);  // function body
        ast_optimize_body(body);
        fi = fi + 1;
    }
    // 注（2026-09-07 regalloc 移后端）：alloc_registers/pass_stack_share 已迁
    // corearch（src/arch/linux/ld/regalloc.cr——.ccr 不再传 REG_ASSIGN/ENT）。
    // 本函数无调用者（main.cr 直调各 pass），保留为历史编排入口。
    if g_opt_level >= 2 {
        pass_cse();
    }
}
