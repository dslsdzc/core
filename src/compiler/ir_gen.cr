// === ir_gen.core ===
// Flat AST to platform-independent IR instruction generation
// (shared IR globals declared in globals.cr)

// (IR globals declared in globals.cr)

fn new_ir_var(name: string, type_idx: int) -> int {
    idx := g_ir_var_count;
    dyn_grow_ir_vars(idx + 1);
    irv_set_name(idx, str_intern(name));
    irv_set_id(idx, idx);
    irv_set_type(idx, type_idx);
    g_ir_var_count = idx + 1;
    return idx;
}

fn emit(opcode: int, dest: int, src1: int, src2: int, src3: int, type_kind: int) {
    // Build linear IR (.ccr) — consumed by x86-64 backend
    idx := g_ir_instr_count;
    dyn_grow_ir_instrs(idx + 1);
    iri_set_op(idx, opcode);
    iri_set_dest(idx, dest);
    iri_set_s1(idx, src1);
    iri_set_s2(idx, src2);
    iri_set_s3(idx, src3);
    iri_set_tk(idx, type_kind);
    g_ir_instr_count = idx + 1;
    // Build dataflow graph (.cir) in parallel
    df_create_node(opcode, dest, src1, src2, src3, type_kind);
}

fn new_label() -> int {
    lbl := g_next_label;
    g_next_label = g_next_label + 1;
    return lbl;
}

fn bind_local(name_idx: int, var_idx: int) {
    dyn_grow_ir_locals(g_ir_local_count + 1);
    w64(g_ir_locals, g_ir_local_count  * 16, name_idx);
    w64(g_ir_locals, g_ir_local_count  * 16 + 8, var_idx);
    g_ir_local_count = g_ir_local_count + 1;
}

fn lookup_local(name_idx: int) -> int {
    i : ., mut = g_ir_local_count - 1;
    loop {
        if i < 0 { return -1; }
        if r64(g_ir_locals, i * 16) == name_idx { return r64(g_ir_locals, i * 16 + 8); }
        i = i - 1;
    }
    return -1;
}

fn lookup_global(name_idx: int) -> int {
    i : ., mut = g_ir_global_count - 1;
    loop {
        if i < 0 { return -1; }
        if r64(g_ir_globals, i * 16) == name_idx { return r64(g_ir_globals, i * 16 + 8); }
        i = i - 1;
    }
    return -1;
}

fn push_ir_scope() {
    dyn_grow_ir_local_scopes(g_ir_local_depth + 1);
    w64(g_ir_local_scopes, g_ir_local_depth * 8, g_ir_local_count);
    g_ir_local_depth = g_ir_local_depth + 1;
}

fn pop_ir_scope() {
    g_ir_local_depth = g_ir_local_depth - 1;
    g_ir_local_count = r64(g_ir_local_scopes, g_ir_local_depth * 8);
}

fn get_ir_var_name(var_idx: int) -> string {
    if var_idx >= 0 && var_idx < g_ir_var_count {
        ni := irv_name(var_idx);
        return str_get(ni);
    }
    return "";
}

// --- Track string constants ---
fn track_str_const(str_idx: int) {
    i : ., mut = 0;
    loop {
        if i >= g_ir_str_const_count { break; }
        if r64(g_ir_str_consts, i * 8) == str_idx { return; }
        i = i + 1;
    }
    dyn_grow_ir_str_consts(g_ir_str_const_count + 1);
    w64(g_ir_str_consts, g_ir_str_const_count * 8, str_idx);
    g_ir_str_const_count = g_ir_str_const_count + 1;
}

// --- Loop label stack ---
fn push_loop_labels(header: int, exit: int) {
    dyn_grow_ir_loop_stacks(g_ir_loop_depth + 1);
    w64(g_ir_loop_header, g_ir_loop_depth * 8, header);
    w64(g_ir_loop_exit, g_ir_loop_depth * 8, exit);
    g_ir_loop_depth = g_ir_loop_depth + 1;
}

fn pop_loop_labels() {
    g_ir_loop_depth = g_ir_loop_depth - 1;
}

fn get_variant_name_idx(qualified_ni: int) -> int {
    s := str_get(qualified_ni);
    slen := __builtin_str_len(s);
    dot_pos : ., mut = -1;
    i : ., mut = 0;
    loop {
        if i >= slen { break; }
        c := __builtin_str_get(s, i);
        if __builtin_str_eq(c, ".") != 0 { dot_pos = i; }
        i = i + 1;
    }
    if dot_pos >= 0 {
        variant_name := __builtin_str_sub(s, dot_pos + 1, slen - dot_pos - 1);
        return str_intern(variant_name);
    }
    return qualified_ni;
}

// --- IR generation for expressions ---
// Returns the IR variable index holding the result

fn ir_gen_expr(node: int) -> int {
    if node < 0 { return -1; }

    if ast_kind(node) == EXPR_NONE {
        // Wrapper node: forward to inner expression (used in struct literals)
        if ast_a(node) >= 0 { return ir_gen_expr(ast_a(node)); }
        return -1;
    }

    // Literals
    if ast_kind(node) == EXPR_INT {
        v := new_ir_var("int", TI_INT);
        emit(IR_CONST, v, ast_int_val(node), 0, 0, TI_INT);
        return v;
    }
    if ast_kind(node) == EXPR_FLOAT {
        v := new_ir_var("float", TI_FLOAT);
        emit(IR_CONST, v, ast_int_val(node), 0, 0, TI_FLOAT);
        return v;
    }
    if ast_kind(node) == EXPR_BOOL {
        v := new_ir_var("bool", TI_BOOL);
        emit(IR_CONST, v, ast_int_val(node), 0, 0, TI_BOOL);
        return v;
    }
    if ast_kind(node) == EXPR_STRING {
        v := new_ir_var("str", TI_STR);
        str_idx := ast_int_val(node);
        track_str_const(str_idx);
        emit(IR_CONST, v, str_idx, 0, 0, TI_STR);
        return v;
    }
    if ast_kind(node) == EXPR_CHAR {
        v := new_ir_var("char", TI_CHAR);
        str_idx := ast_int_val(node);
        track_str_const(str_idx);
        emit(IR_CONST, v, str_idx, 0, 0, TI_CHAR);
        return v;
    }

    // Identifier: local or global variable
    if ast_kind(node) == EXPR_IDENT {
        name_idx := ast_int_val(node);
        lv := lookup_local(name_idx);
        if lv >= 0 { return lv; }
        gv := lookup_global(name_idx);
        if gv >= 0 { return gv; }
        // Could be a function name being used as a value - return dummy
        v := new_ir_var("unresolved", TI_UNIT);
        return v;
    }

    // Binary operation
    if ast_kind(node) == EXPR_BINARY {
        left := ast_a(node);
        right := ast_b(node);
        op := ast_c(node);

        // Assignment
        if op == OP_ASSIGN {
            val_var := ir_gen_expr(right);
            // Determine lhs kind
            if ast_kind(left) == EXPR_IDENT {
                name_idx := ast_int_val(left);
                target := lookup_local(name_idx);
                if target >= 0 {
                    emit(IR_STORE, -1, target, val_var, 0, 0);
                } else {
                    gtarget := lookup_global(name_idx);
                    if gtarget >= 0 {
                        emit(IR_STORE, -1, gtarget, val_var, 0, 0);
                    }
                }
                return val_var;
            }
            if ast_kind(left) == EXPR_FIELD {
                obj_var := ir_gen_expr(ast_a(left));
                field_ni := ast_int_val(left);
                fi := ast_data(left);  // field index stored by checker
                emit(IR_STORE_FIELD, -1, obj_var, val_var, fi, 0);
                return val_var;
            }
            if ast_kind(left) == EXPR_INDEX {
                arr_var := ir_gen_expr(ast_a(left));
                idx_node := ast_b(left);
                idx_kind := ast_kind(idx_node);
                if idx_kind == EXPR_INT {
                    emit(IR_STORE_INDEX, -1, arr_var, val_var, ast_int_val(idx_node), 0);
                } else {
                    idx_var := ir_gen_expr(idx_node);
                    emit(IR_STORE_INDEX_VAR, val_var, arr_var, idx_var, 0, 0);
                }
                return val_var;
            }
            return val_var;
        }

        // Regular binary
        left_var := ir_gen_expr(left);
        right_var := ir_gen_expr(right);
        v := new_ir_var("bin", TI_INT);
        emit(IR_BINARY, v, left_var, right_var, op, 0);
        return v;
    }

    // Assignment
    if ast_kind(node) == EXPR_ASSIGN {
        target := ast_a(node);
        val_node := ast_b(node);
        val_var := ir_gen_expr(val_node);
        if ast_kind(target) == EXPR_IDENT {
            name_idx := ast_int_val(target);
            lv := lookup_local(name_idx);
            if lv >= 0 {
                emit(IR_STORE, -1, lv, val_var, 0, 0);
            } else {
                gv := lookup_global(name_idx);
                if gv >= 0 { emit(IR_STORE, -1, gv, val_var, 0, 0); }
            }
            return val_var;
        }
        if ast_kind(target) == EXPR_FIELD {
            obj_var := ir_gen_expr(ast_a(target));
            fi := ast_data(target);
            emit(IR_STORE_FIELD, -1, obj_var, val_var, fi, 0);
            return val_var;
        }
        if ast_kind(target) == EXPR_INDEX {
            arr_var := ir_gen_expr(ast_a(target));
            idx_node := ast_b(target);
            if ast_kind(idx_node) == EXPR_INT {
                emit(IR_STORE_INDEX, -1, arr_var, val_var, ast_int_val(idx_node), 0);
            } else {
                idx_var := ir_gen_expr(idx_node);
                emit(IR_STORE_INDEX_VAR, val_var, arr_var, idx_var, 0, 0);
            }
            return val_var;
        }
        if ast_kind(target) == EXPR_UNARY && ast_c(target) == UOP_DEREF {
            ptr_var := ir_gen_expr(ast_a(target));
            emit(IR_STORE_PTR, -1, ptr_var, val_var, 0, 0);
            return val_var;
        }
        return val_var;
    }

    // Unary operation
    if ast_kind(node) == EXPR_UNARY {
        op := ast_c(node);
        op_var := ir_gen_expr(ast_a(node));
        if op == UOP_REF {
            v := new_ir_var("ref", TI_UNIT);
            emit(IR_REF, v, op_var, ast_int_val(node), 0, 0);
            return v;
        }
        if op == UOP_DEREF {
            inner_var := ir_gen_expr(ast_a(node));
            dv := new_ir_var("deref", TI_UNIT);
            emit(IR_DEREF, dv, inner_var, 0, 0, 0);
            return dv;
        }
        v := new_ir_var("un", TI_INT);
        emit(IR_UNARY, v, op_var, 0, op, 0);
        return v;
    }

    // Function call
    if ast_kind(node) == EXPR_CALL {
        func_node := ast_a(node);
        first_arg := ast_b(node);
        arg_count := ast_c(node);
        arg_vars : [int; 16], mut;
        ac : ., mut = 0;
        func_ni : ., mut = -1;

        // Module or method call: obj.method(args)
        if ast_kind(func_node) == EXPR_FIELD {
            func_ni = ast_data(node); // function name (set by checker for module calls)
            if ast_type_val(node) != 1 {
                // Method call: self is first arg
                obj_node := ast_a(func_node);
                arg_vars[ac] = ir_gen_expr(obj_node);
                ac = ac + 1;
            }
        } else if ast_kind(func_node) == EXPR_IDENT {
            func_ni = ast_int_val(func_node);
        }

        // Generate remaining args
        an : ., mut = first_arg;
        i : ., mut = 0;
        loop {
            if i >= arg_count { break; }
            if an >= 0 {
                arg_vars[ac] = ir_gen_expr(an);
                ac = ac + 1;
                an = an + 1;
            }
            i = i + 1;
        }
        dest := new_ir_var("call", TI_UNIT);
        first_arg_var := -1;
        if ac > 0 { first_arg_var = arg_vars[0]; }
        emit(IR_CALL, dest, first_arg_var, ac, func_ni, 0);
        return dest;
    }

    // Block
    if ast_kind(node) == EXPR_BLOCK {
        stmt_start := ast_a(node);
        stmt_count := ast_b(node);
        last : ., mut = -1;
        push_ir_scope();
        i : ., mut = 0;
        loop {
            if i >= stmt_count { break; }
            sn := r64(g_block_stmts, (stmt_start + i) * 8);
            last = ir_gen_expr(sn);
            i = i + 1;
        }
        pop_ir_scope();
        return last;
    }

    // If expression
    if ast_kind(node) == EXPR_IF {
        cond := ast_a(node);
        then_node := ast_b(node);
        else_node := ast_c(node);
        cond_var := ir_gen_expr(cond);
        then_lbl := new_label();
        else_lbl := new_label();
        merge_lbl := new_label();
        if else_node >= 0 {
            emit(IR_BRANCH, -1, cond_var, then_lbl, else_lbl, 0);
        } else {
            emit(IR_BRANCH, -1, cond_var, then_lbl, merge_lbl, 0);
        }
        emit(IR_LABEL, -1, then_lbl, 0, 0, 0);
        ir_gen_expr(then_node);
        emit(IR_JUMP, -1, merge_lbl, 0, 0, 0);
        if else_node >= 0 {
            emit(IR_LABEL, -1, else_lbl, 0, 0, 0);
            ir_gen_expr(else_node);
            emit(IR_JUMP, -1, merge_lbl, 0, 0, 0);
        }
        emit(IR_LABEL, -1, merge_lbl, 0, 0, 0);
        return -1;
    }

    // Loop
    if ast_kind(node) == EXPR_LOOP {
        header_lbl := new_label();
        body_lbl := new_label();
        exit_lbl := new_label();
        emit(IR_JUMP, -1, header_lbl, 0, 0, 0);
        emit(IR_LABEL, -1, header_lbl, 0, 0, 0);
        emit(IR_JUMP, -1, body_lbl, 0, 0, 0);
        emit(IR_LABEL, -1, body_lbl, 0, 0, 0);
        push_ir_scope();
        push_loop_labels(header_lbl, exit_lbl);
        ir_gen_expr(ast_a(node));
        pop_loop_labels();
        pop_ir_scope();
        emit(IR_JUMP, -1, header_lbl, 0, 0, 0);
        emit(IR_LABEL, -1, exit_lbl, 0, 0, 0);
        return -1;
    }

    // While loop
    if ast_kind(node) == EXPR_WHILE {
        cond := ast_a(node);
        body := ast_b(node);
        header_lbl := new_label();
        body_lbl := new_label();
        exit_lbl := new_label();
        emit(IR_LABEL, -1, header_lbl, 0, 0, 0);
        cond_var := ir_gen_expr(cond);
        emit(IR_BRANCH, -1, cond_var, body_lbl, exit_lbl, 0);
        emit(IR_LABEL, -1, body_lbl, 0, 0, 0);
        push_ir_scope();
        push_loop_labels(header_lbl, exit_lbl);
        ir_gen_expr(body);
        pop_loop_labels();
        pop_ir_scope();
        emit(IR_JUMP, -1, header_lbl, 0, 0, 0);
        emit(IR_LABEL, -1, exit_lbl, 0, 0, 0);
        return -1;
    }

    // For loop: for var in start..end { body }
    if ast_kind(node) == EXPR_FOR {
        var_ni := ast_a(node);
        iter := ast_b(node);
        body := ast_c(node);
        start_var := -1;
        end_var := -1;
        if ast_kind(iter) == EXPR_RANGE {
            start_var = ir_gen_expr(ast_a(iter));
            end_var = ir_gen_expr(ast_b(iter));
        } else {
            // Non-range iterable: evaluate and use 0..iter
            s := new_ir_var("start", TI_INT);
            emit(IR_CONST, s, 0, 0, 0, TI_INT);
            start_var = s;
            end_var = ir_gen_expr(iter);
        }
        // Create loop variable, init to start
        ivar := new_ir_var("for_i", TI_INT);
        emit(IR_ALLOC, ivar, 0, 0, 0, TI_INT);
        emit(IR_STORE, -1, ivar, start_var, 0, 0);
        bind_local(var_ni, ivar);
        header_lbl := new_label();
        body_lbl := new_label();
        exit_lbl := new_label();
        // Header: check ivar < end, branch to exit if false
        emit(IR_LABEL, -1, header_lbl, 0, 0, 0);
        cond_var := new_ir_var("for_cond", TI_INT);
        emit(IR_BINARY, cond_var, ivar, end_var, OP_LT, 0);
        emit(IR_BRANCH, -1, cond_var, body_lbl, exit_lbl, 0);
        // Body
        emit(IR_LABEL, -1, body_lbl, 0, 0, 0);
        push_ir_scope();
        push_loop_labels(header_lbl, exit_lbl);
        ir_gen_expr(body);
        pop_loop_labels();
        pop_ir_scope();
        // Increment ivar and jump to header
        one_var := new_ir_var("one", TI_INT);
        emit(IR_CONST, one_var, 1, 0, 0, TI_INT);
        inc_var := new_ir_var("inc", TI_INT);
        emit(IR_BINARY, inc_var, ivar, one_var, OP_ADD, 0);
        emit(IR_STORE, -1, ivar, inc_var, 0, 0);
        emit(IR_JUMP, -1, header_lbl, 0, 0, 0);
        // Exit
        emit(IR_LABEL, -1, exit_lbl, 0, 0, 0);
        return -1;
    }

    // Match expression
    if ast_kind(node) == EXPR_MATCH {
        match_expr := ast_a(node);
        first_arm := ast_b(node);
        match_val := ir_gen_expr(match_expr);
        // Allocate a result variable for the match expression value
        result_var := new_ir_var("match_res", TI_INT);
        emit(IR_ALLOC, result_var, 0, 0, 0, TI_INT);
        merge_lbl := new_label();
        an : ., mut = first_arm;
        loop {
            if an < 0 { break; }
            arm_pat := ast_a(an);
            arm_body := ast_b(an);
            pat_kind := -1;
            if arm_pat >= 0 { pat_kind = ast_kind(arm_pat); }
            is_wildcard := 0;
            if pat_kind == EXPR_WILDCARD { is_wildcard = 1; }
            body_lbl := new_label();
            fall_lbl : ., mut = merge_lbl;
            has_next := 0;
            if ast_c(an) >= 0 { has_next = 1; }
            if is_wildcard == 1 {
                emit(IR_JUMP, -1, body_lbl, 0, 0, 0);
            } else if pat_kind == EXPR_ENUMPAT {
                variant_ni := get_variant_name_idx(ast_a(arm_pat));
                tag_var := new_ir_var("tag", TI_INT);
                emit(IR_LOAD_ENUM_TAG, tag_var, match_val, 0, 0, 0);
                vtag := new_ir_var("vtag", TI_INT);
                emit(IR_CONST, vtag, variant_ni, 0, 0, TI_INT);
                cmp_var := new_ir_var("cmp", TI_INT);
                emit(IR_BINARY, cmp_var, tag_var, vtag, OP_EQ, 0);
                if has_next == 1 { fall_lbl = new_label(); }
                emit(IR_BRANCH, -1, cmp_var, body_lbl, fall_lbl, 0);
            } else if pat_kind == EXPR_INT {
                pat_val := new_ir_var("pval", TI_INT);
                emit(IR_CONST, pat_val, ast_int_val(arm_pat), 0, 0, TI_INT);
                cmp_var := new_ir_var("cmp", TI_INT);
                emit(IR_BINARY, cmp_var, match_val, pat_val, OP_EQ, 0);
                if has_next == 1 { fall_lbl = new_label(); }
                emit(IR_BRANCH, -1, cmp_var, body_lbl, fall_lbl, 0);
            } else if pat_kind == EXPR_BOOL {
                pat_val := new_ir_var("pval", TI_INT);
                pat_bool : ., mut = 0;
                if ast_int_val(arm_pat) != 0 { pat_bool = 1; }
                emit(IR_CONST, pat_val, pat_bool, 0, 0, TI_INT);
                cmp_var := new_ir_var("cmp", TI_INT);
                emit(IR_BINARY, cmp_var, match_val, pat_val, OP_EQ, 0);
                if has_next == 1 { fall_lbl = new_label(); }
                emit(IR_BRANCH, -1, cmp_var, body_lbl, fall_lbl, 0);
            }
            emit(IR_LABEL, -1, body_lbl, 0, 0, 0);
            push_ir_scope();
            if pat_kind == EXPR_ENUMPAT {
                sub_count := ast_c(arm_pat);
                fi : ., mut = 0;
                loop {
                    if fi >= sub_count { break; }
                    fv := new_ir_var("fld", TI_INT);
                    emit(IR_LOAD_FIELD, fv, match_val, 0, fi, 0);
                    spn := ast_b(arm_pat) + fi;
                    if spn >= 0 && ast_kind(spn) == EXPR_IDENT {
                        bind_local(ast_int_val(spn), fv);
                    }
                    fi = fi + 1;
                }
            }
            body_val := ir_gen_expr(arm_body);
            if body_val >= 0 {
                emit(IR_STORE, -1, result_var, body_val, 0, 0);
            }
            pop_ir_scope();
            emit(IR_JUMP, -1, merge_lbl, 0, 0, 0);
            if is_wildcard == 0 {
                if has_next == 1 {
                    emit(IR_LABEL, -1, fall_lbl, 0, 0, 0);
                }
            }
            an = ast_c(an);
        }
        emit(IR_LABEL, -1, merge_lbl, 0, 0, 0);
        return result_var;
    }

    // Let binding
    if ast_kind(node) == EXPR_LET {
        var_ni := ast_a(node);
        type_node := ast_b(node);
        val_node := ast_c(node);
        var := new_ir_var(str_get(var_ni), TI_UNIT);
        is_arr : ., mut = 0;
        if type_node >= 0 && val_node < 0 {
            if ast_kind(type_node) == 19 {
                sz := ast_int_val(type_node);
                if sz > 0 { emit(IR_ALLOC_ARRAY, var, sz, 8, 0, 0); is_arr = 1; }
            }
        }
        if is_arr == 0 { emit(IR_ALLOC, var, 0, 0, 0, TI_UNIT); }
        if val_node >= 0 {
            val_var := ir_gen_expr(val_node);
            emit(IR_STORE, -1, var, val_var, 0, 0);
        }
        bind_local(var_ni, var);
        return var;
    }

    // Return
    if ast_kind(node) == EXPR_RETURN {
        if ast_a(node) >= 0 {
            val_var := ir_gen_expr(ast_a(node));
            emit(IR_RETURN, -1, val_var, 0, 0, 0);
        } else {
            emit(IR_RETURN, -1, -1, 0, 0, 0);
        }
        return -1;
    }

    // Field access
    if ast_kind(node) == EXPR_FIELD {
        obj_var := ir_gen_expr(ast_a(node));
        v := new_ir_var("field", TI_INT);
        fi : ., mut = ast_type_val(node);
        if fi > 0 {
            fi = fi - 1;  // numeric tuple index (parser stored +1)
        } else {
            fi = ast_data(node);   // struct field index (from checker)
        }
        emit(IR_LOAD_FIELD, v, obj_var, 0, fi, 0);
        return v;
    }

    // Index
    if ast_kind(node) == EXPR_INDEX {
        arr_var := ir_gen_expr(ast_a(node));
        idx_node := ast_b(node);
        idx_kind := ast_kind(idx_node);
        // Range index: arr[low..high] → slice (pointer to arr[low])
        if idx_kind == EXPR_RANGE {
            low_node := ast_a(idx_node);
            high_node := ast_b(idx_node);
            low_var := ir_gen_expr(low_node);
            high_var := ir_gen_expr(high_node);
            v := new_ir_var("slice", TI_INT);
            emit(IR_SLICE, v, arr_var, low_var, high_var, 0);
            return v;
        }
        v := new_ir_var("elem", TI_INT);
        if idx_kind == EXPR_INT {
            emit(IR_LOAD_INDEX, v, arr_var, 0, ast_int_val(idx_node), 0);
        } else {
            idx_var := ir_gen_expr(idx_node);
            emit(IR_LOAD_INDEX_VAR, v, arr_var, idx_var, 0, 0);
        }
        return v;
    }

    // Enum constructor
    if ast_kind(node) == EXPR_ENUM_CONSTRUCTOR {
        name_idx := ast_a(node);
        s := new_ir_var("enum", TI_UNIT);
        emit(IR_MAKE_ENUM, s, name_idx, ast_c(node), 0, 0);
        ai : ., mut = 0;
        an : ., mut = ast_b(node);
        loop {
            if ai >= ast_c(node) { break; }
            if an >= 0 {
                val_var := ir_gen_expr(an);
                emit(IR_STORE_FIELD, -1, s, val_var, ai, 0);
                an = an + 1;
            }
            ai = ai + 1;
        }
        return s;
    }

    // Struct literal
    if ast_kind(node) == EXPR_STRUCT {
        name_ni := ast_a(node);
        s := new_ir_var("struct", TI_UNIT);
        emit(IR_ALLOC_STRUCT, s, 0, 0, name_ni, 0);
        fi : ., mut = 0;
        fn2 : ., mut = ast_b(node);
        loop {
            if fi >= ast_c(node) { break; }
            if fn2 >= 0 {
                // fn2 = wrapper node (kind=0, a=value expr)
                val_var := ir_gen_expr(fn2);
                field_idx := fi;
                emit(IR_STORE_FIELD, -1, s, val_var, field_idx, 0);
                fn2 = fn2 + 1;
            }
            fi = fi + 1;
        }
        return s;
    }

    // Array literal
    if ast_kind(node) == EXPR_ARRAY {
        v := new_ir_var("arr", TI_UNIT);
        emit(IR_ALLOC_ARRAY, v, ast_b(node), 0, 0, 0);
        ei : ., mut = 0;
        en : ., mut = ast_a(node);
        loop {
            if ei >= ast_b(node) { break; }
            if en >= 0 {
                e_var := ir_gen_expr(en);
                emit(IR_STORE_INDEX, -1, v, e_var, ei, 0);
                en = en + 1;
            }
            ei = ei + 1;
        }
        return v;
    }

    // Range expression (evaluates both ends, returns end)
    if ast_kind(node) == EXPR_RANGE {
        start_var := ir_gen_expr(ast_a(node));
        end_var := ir_gen_expr(ast_b(node));
        return end_var;
    }

    // Break / Continue
    if ast_kind(node) == EXPR_BREAK {
        if g_ir_loop_depth > 0 {
            emit(IR_JUMP, -1, r64(g_ir_loop_exit, (g_ir_loop_depth - 1) * 8), 0, 0, 0);
        }
        return -1;
    }
    if ast_kind(node) == EXPR_CONTINUE {
        if g_ir_loop_depth > 0 {
            emit(IR_JUMP, -1, r64(g_ir_loop_header, (g_ir_loop_depth - 1) * 8), 0, 0, 0);
        }
        return -1;
    }

    if ast_kind(node) == EXPR_WILDCARD { return -1; }
    if ast_kind(node) == EXPR_ENUMPAT { return -1; }
    if ast_kind(node) == EXPR_MOVE {
        return ir_gen_expr(ast_a(node));
    }
    if ast_kind(node) == EXPR_UNSAFE {
        return ir_gen_expr(ast_a(node));
    }
    if ast_kind(node) == EXPR_AS {
        // Type cast: emit inner expr, result type handled by checker
        return ir_gen_expr(ast_a(node));
    }
    if ast_kind(node) == EXPR_TRY {
        // Try: unwrap Result/Option, just emit the inner expr for now
        return ir_gen_expr(ast_a(node));
    }
    if ast_kind(node) == EXPR_STRUCTPAT {
        return -1;
    }
    if ast_kind(node) == EXPR_STMT {
        ir_gen_expr(ast_a(node));
        return -1;
    }
    if ast_kind(node) == EXPR_TUPLE {
        // Tuple: allocate array for N elements, store each
        elem_idx := ast_a(node);
        ec : ., mut = ast_b(node);
        tv := new_ir_var("tuple", TI_INT);
        emit(IR_ALLOC_ARRAY, tv, ec, 0, 8, 0);  // alloc N * 8 bytes
        // Store each element at its offset
        e : ., mut = 0;
        loop {
            if e >= ec { break; }
            elem_var := ir_gen_expr(elem_idx + e);
            emit(IR_STORE_FIELD, -1, tv, elem_var, e, 0);
            e = e + 1;
        }
        return tv;
    }

    return -1;
}

// --- Generate IR for one function ---

fn ir_gen_func(fi: int) {
    fn_node := fi_ast_node(fi);
    name_idx := ast_a(fn_node);
    first_param := ast_b(fn_node);
    param_count := ast_c(fn_node);
    ret_ti := ast_type_val(fn_node);
    body := ast_data(fn_node);

    // Record function metadata
    func_idx := g_ir_func_count;
    dyn_grow_ir_func_meta(func_idx + 1);
    w64(g_ir_func_name_idx, func_idx * 8, name_idx);
    w64(g_ir_func_ret_type, func_idx * 8, ret_ti);
    w64(g_ir_func_instr_start, func_idx * 8, g_ir_instr_count);
    w64(g_ir_func_var_start, func_idx * 8, g_ir_var_count);
    w64(g_ir_func_param_count, func_idx * 8, param_count);

    // Create IR vars for params
    pi : ., mut = 0;
    pn : ., mut = first_param;
    loop {
        if pi >= param_count { break; }
        if pn < 0 { break; }
        pname_idx := ast_a(pn);
        pname := str_get(pname_idx);
        pvar := new_ir_var(pname, TI_INT);
        // Bind param name
        bind_local(pname_idx, pvar);
        pi = pi + 1;
        // Scan past type nodes to next EXPR_PARAM
        pn = pn + 1;
        loop {
            if pn >= g_ast_count { break; }
            if ast_kind(pn) == EXPR_PARAM { break; }
            pn = pn + 1;
        }
    }

    // Generate body
    if body >= 0 {
        ir_gen_expr(body);
    }

    // Add return at end if not already terminated
    emit(IR_RETURN, -1, -1, 0, 0, 0);

    w64(g_ir_func_instr_count, func_idx * 8, g_ir_instr_count - r64(g_ir_func_instr_start, func_idx * 8));
    w64(g_ir_func_var_count, func_idx * 8, g_ir_var_count - r64(g_ir_func_var_start, func_idx * 8));
    g_ir_func_count = func_idx + 1;
}

// --- Initialize global IR vars from global lets ---

fn ir_gen_globals() {
    i : ., mut = 0;
    loop {
        if i >= g_global_let_count { break; }
        node := r64(g_global_lets, i * 8);
        name_idx := ast_a(node);
        name := str_get(name_idx);
        gvar := new_ir_var(name, TI_INT);
        dyn_grow_ir_globals(g_ir_global_count + 1);
        w64(g_ir_globals, g_ir_global_count  * 16, name_idx);
        w64(g_ir_globals, g_ir_global_count  * 16 + 8, gvar);
        g_ir_global_count = g_ir_global_count + 1;
        i = i + 1;
    }
}

// --- Main entry ---

fn ir_gen_all() {
    g_ir_var_count = 0;
    g_ir_instr_count = 0;
    g_ir_func_count = 0;
    g_ir_local_count = 0;
    g_ir_local_depth = 0;
    g_ir_global_count = 0;
    g_next_label = 1;
    g_ir_loop_depth = 0;
    g_ir_str_const_count = 0;

    // Initialize dataflow graph
    init_df();

    // Initialize globals
    ir_gen_globals();

    // Generate IR for each function
    i : ., mut = 0;
    loop {
        if i >= g_func_count { break; }
        df_begin_func(i);
        ir_gen_func(i);
        df_end_func(i);
        i = i + 1;
    }
}
