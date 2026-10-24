// === opt.cr ===
// Corec-side semantic optimizations that remain after register allocation moved
// to the backend:
// - AST constant folding in ast_optimize_body;
// - linear IR common-subexpression elimination in pass_cse, called at O1 or
//   higher;
// - optimize_all, a legacy orchestration entry with no callers.


// ------------------------------------------------------------------
// AST constant folding: EXPR_BINARY with two int literals becomes EXPR_INT.
// ------------------------------------------------------------------

fn ast_is_const_int(node: int) -> int:
    if node < 0:
        return 0
    if ast_kind(node) == EXPR_INT:
        return 1
    return 0

fn ast_const_val(node: int) -> int:
    return ast_int_val(node)

fn ast_bool_as_int(value: bool) -> int:
    if value:
        return 1
    return 0

fn ast_fold_binary(node: int) -> int:
    left := ast_a(node)
    right := ast_b(node)
    opc := ast_c(node)
    if !ast_is_const_int(left) || !ast_is_const_int(right):
        return 0
    v1 := ast_const_val(left)
    v2 := ast_const_val(right)
    rv : ., mut = 0
    known : ., mut = 1
    if opc == OP_ADD:
        rv = v1 + v2
    else if opc == OP_SUB:
        rv = v1 - v2
    else if opc == OP_MUL:
        rv = v1 * v2
    else if opc == OP_DIV:
        if v2 == 0:
            return 0
        rv = v1 / v2
    else if opc == OP_MOD:
        if v2 == 0:
            return 0
        rv = v1 % v2
    else if opc == OP_EQ:
        rv = ast_bool_as_int(v1 == v2)
    else if opc == OP_NE:
        rv = ast_bool_as_int(v1 != v2)
    else if opc == OP_LT:
        rv = ast_bool_as_int(v1 < v2)
    else if opc == OP_GT:
        rv = ast_bool_as_int(v1 > v2)
    else if opc == OP_LE:
        rv = ast_bool_as_int(v1 <= v2)
    else if opc == OP_GE:
        rv = ast_bool_as_int(v1 >= v2)
    else if opc == OP_AND:
        rv = ast_bool_as_int(v1 != 0 && v2 != 0)
    else if opc == OP_OR:
        rv = ast_bool_as_int(v1 != 0 || v2 != 0)
    else:
        known = 0
    if known == 0:
        return 0
    // Replace EXPR_BINARY with EXPR_INT in place.
    ast_set_kind(node, EXPR_INT)
    ast_set_a(node, 0)
    ast_set_b(node, 0)
    ast_set_c(node, 0)
    ast_set_int_val(node, rv)
    ast_set_type_val(node, TY_INT)
    return 1

// ------------------------------------------------------------------
// Walk a block's statements and fold expressions.
// ------------------------------------------------------------------

fn ast_optimize_body(body: int):
    if body < 0:
        return
    bk := ast_kind(body)

    // EXPR_BLOCK: optimize each statement.
    if bk == EXPR_BLOCK:
        ss := ast_a(body)
        sc := ast_b(body)
        i : ., mut = 0
        loop:
            if i >= sc:
                break
            sn := cell_load(g_block_stmts, (ss + i) * 8)
            ast_optimize_body(sn)
            i = i + 1
        return
    // EXPR_RETURN: optimize the value.
    if bk == EXPR_RETURN:
        if ast_a(body) >= 0:
            ast_optimize_body(ast_a(body))
        return
    // EXPR_IF: optimize the condition, then branch, and else branch.
    if bk == EXPR_IF:
        ast_optimize_body(ast_a(body))  // cond
        ast_optimize_body(ast_b(body))  // then
        if ast_c(body) >= 0:
            ast_optimize_body(ast_c(body))
        // else
        // Constant-condition folding for if is not implemented here.
        cond := ast_a(body)
        if ast_is_const_int(cond):
            cv := ast_const_val(cond)
            then_node := ast_b(body)
            else_node := ast_c(body)

                // Reserved for constant-condition folding. No rewrite is applied.

        return
    // EXPR_BINARY: fold constants.
    if bk == EXPR_BINARY:
        ast_optimize_body(ast_a(body))
        ast_optimize_body(ast_b(body))
        ast_fold_binary(body)
        return
    // EXPR_UNARY: optimize the operand.
    if bk == EXPR_UNARY:
        if ast_a(body) >= 0:
            ast_optimize_body(ast_a(body))
        return
    // EXPR_CALL: optimize arguments.
    if bk == EXPR_CALL:
        if ast_a(body) >= 0:
            ast_optimize_body(ast_a(body))
        an := ast_b(body)
        ac := ast_c(body)
        ai : ., mut = 0
        loop:
            if ai >= ac:
                break
            if an >= 0:
                ast_optimize_body(an)
                an = an + 1
            ai = ai + 1
        return
    // EXPR_STRUCT: a is the type name, b the first consecutive wrapper, and c
    // the field count. wrapper.a holds the field value, so recurse into that
    // value rather than the wrapper node.
    if bk == EXPR_STRUCT:
        fn2 := ast_b(body)
        fc := ast_c(body)
        i : ., mut = 0
        loop:
            if i >= fc:
                break
            if fn2 >= 0:
                vn : ., mut = -1
                if ast_kind(fn2) == EXPR_NONE:
                    vn = ast_a(fn2)
                if vn >= 0:
                    ast_optimize_body(vn)
                fn2 = fn2 + 1
            i = i + 1
        return
    // EXPR_LET: optimize the value expression.
    if bk == EXPR_LET:
        if ast_c(body) >= 0:
            ast_optimize_body(ast_c(body))
        return
    // EXPR_GO: optimize the spawned body.
    if bk == EXPR_GO:
        if ast_b(body) >= 0:
            ast_optimize_body(ast_b(body))
        return
    if bk == EXPR_YIELD:
        if ast_a(body) >= 0:
            ast_optimize_body(ast_a(body))
        return
    // EXPR_LOOP and EXPR_WHILE: optimize the body.
    if bk == EXPR_LOOP || bk == EXPR_WHILE:
        if ast_a(body) >= 0:
            ast_optimize_body(ast_a(body))
        return
    // EXPR_FOR: optimize the iterable and body.
    if bk == EXPR_FOR:
        if ast_b(body) >= 0:
            ast_optimize_body(ast_b(body))
        if ast_c(body) >= 0:
            ast_optimize_body(ast_c(body))
        return
    // EXPR_MATCH: optimize the scrutinee and each arm.
    if bk == EXPR_MATCH:
        if ast_a(body) >= 0:
            ast_optimize_body(ast_a(body))
        an := ast_b(body)
        loop:
            if an < 0:
                break
            if ast_a(an) >= 0:
                ast_optimize_body(ast_a(an))
            if ast_b(an) >= 0:
                ast_optimize_body(ast_b(an))
            an = ast_c(an)
        return
    // EXPR_STMT: optimize the wrapped expression.
    if bk == EXPR_STMT:
        if ast_a(body) >= 0:
            ast_optimize_body(ast_a(body))
        return
    // EXPR_ARRAY: a is the first consecutive wrapper and b the element count.
    // wrapper.a holds the element value, so recurse into that value.
    if bk == EXPR_ARRAY:
        an := ast_a(body)
        ac := ast_b(body)
        i : ., mut = 0
        loop:
            if i >= ac:
                break
            if an >= 0:
                vn : ., mut = -1
                if ast_kind(an) == EXPR_NONE:
                    vn = ast_a(an)
                if vn >= 0:
                    ast_optimize_body(vn)
                an = an + 1
            i = i + 1
        return
    // EXPR_TUPLE: a is the first consecutive wrapper and b the element count.
    // wrapper.a holds the element value.
    if bk == EXPR_TUPLE:
        an := ast_a(body)
        ac := ast_b(body)
        i : ., mut = 0
        loop:
            if i >= ac:
                break
            if an >= 0:
                vn : ., mut = -1
                if ast_kind(an) == EXPR_NONE:
                    vn = ast_a(an)
                if vn >= 0:
                    ast_optimize_body(vn)
                an = an + 1
            i = i + 1
        return
    // EXPR_AS: optimize the operand.
    if bk == EXPR_AS:
        if ast_a(body) >= 0:
            ast_optimize_body(ast_a(body))
        return
    // EXPR_BINARY is handled above. Other kinds need no rewrite here.

// ------------------------------------------------------------------
// Common subexpression elimination over the linear IR.
// ------------------------------------------------------------------
fn pass_cse():
    if g_ir_func_count <= 0:
        return
    fi : ., mut = 0
    loop:
        if fi >= g_ir_func_count:
            break
        ic := cell_load(g_ir_func_instr_count, fi * 8)
        ist := cell_load(g_ir_func_instr_start, fi * 8)
        if ic <= 0:
            fi = fi + 1
            continue

        // Track seen (op, s1, s2, dest) expressions. A linear scan is sufficient
        // at O1.
        seen_count : ., mut = 0
        // Flat array: each entry is {op, s1, s2, dest}, 32 bytes.
        seen : string, mut = alloc(ic * 32)
        // Flat buffer of old-to-canonical replacement pairs.
        replace_map : string, mut = alloc(ic * 8)
        replace_count : ., mut = 0

        ii : ., mut = 0
        loop:
            if ii >= ic:
                break
            inst := ist + ii
            op := iri_op(inst)
            d := iri_dest(inst)
            s1 := iri_s1(inst)
            s2 := iri_s2(inst)

            // Skip side-effecting and annotation opcodes.
            if op == IR_ARENA_NEW:
                ii = ii + 1
                continue
            if op == IR_ARENA_RESET:
                ii = ii + 1
                continue
            if op == IR_INLINE:
                ii = ii + 1
                continue
            if op == IR_NO_BOUNDS_CHECK:
                ii = ii + 1
                continue
            if op == IR_FAST:
                ii = ii + 1
                continue
            if op == IR_UNROLL:
                ii = ii + 1
                continue
            if op == IR_APPROX:
                ii = ii + 1
                continue
            if op == IR_SECTION:
                ii = ii + 1
                continue
            if op == IR_HOTPATCH_ROUTE:
                ii = ii + 1
                continue
            if op == IR_DYN_TAG:
                ii = ii + 1
                continue
            if op == IR_DYN_VAL:
                ii = ii + 1
                continue
            if op == IR_DYN_PACK:
                ii = ii + 1
                continue
            if op == IR_DYN_DISPATCH:
                ii = ii + 1
                continue
            if op == IR_CALL_EXTERN:
                ii = ii + 1
                continue
            if op == IR_LAZY_THUNK:
                ii = ii + 1
                continue
            if op == IR_LAZY_FORCE:
                ii = ii + 1
                continue
            if op == IR_FNADDR:
                ii = ii + 1
                continue

            // Eliminate only pure computations: binary and unary operations.
            if (op == IR_BINARY || op == IR_UNARY) && d >= 0:
                // Check whether the expression was already seen.
                found : ., mut = -1
                sj : ., mut = 0
                loop:
                    if sj >= seen_count:
                        break
                    so := sj * 32
                    if cell_load(seen, so) == op && cell_load(seen, so+8) == s1 && cell_load(seen, so+16) == s2:
                        found = sj
                        break
                    sj = sj + 1
                if found >= 0:
                    // Duplicate: map d to the canonical destination and replace
                    // this instruction with a no-op.
                    canonical := cell_load(seen, found * 32 + 24)
                    cell_store(replace_map, replace_count * 8, d)
                    cell_store(replace_map, replace_count * 8 + 8, canonical)
                    replace_count = replace_count + 1
                    // Replace the instruction with a no-op.
                    iri_set_op(inst, IR_NOP)
                else:
                    // New expression: record it.
                    so := seen_count * 32
                    cell_store(seen, so, op)
                    cell_store(seen, so+8, s1)
                    cell_store(seen, so+16, s2)
                    cell_store(seen, so+24, d)
                    seen_count = seen_count + 1

            // Apply replacements to the operands of every instruction.
            if replace_count > 0:
                rj : ., mut = 0
                loop:
                    if rj >= replace_count:
                        break
                    old_v := cell_load(replace_map, rj * 8)
                    new_v := cell_load(replace_map, rj * 8 + 8)
                    if iri_s1(inst) == old_v:
                        iri_set_s1(inst, new_v)
                    if iri_s2(inst) == old_v:
                        iri_set_s2(inst, new_v)
                    if iri_s3(inst) == old_v:
                        iri_set_s3(inst, new_v)
                    rj = rj + 1

            ii = ii + 1
        fi = fi + 1

fn optimize_all():
    // Pointer analysis always runs, even at optimization level 0.
    ptr_analysis_all()
    // RegionCheck: verify that DEREF targets are in live subgraphs.
    region_check_all()
    // ProvenanceVerify: check DEREF offsets against allocation sizes.
    provenance_verify_all()
    if g_opt_level < 1:
        return
    fi : ., mut = 0
    loop:
        if fi >= g_func_count:
            break
        fn_node := fi_ast_node(fi)
        body := ast_data(fn_node)  // function body
        ast_optimize_body(body)
        fi = fi + 1
    // Register allocation and stack sharing live in corearch now
    // (src/arch/x86_64/regalloc.cr). This function has no callers; main.cr calls
    // the passes directly.
    if g_opt_level >= 2:
        pass_cse()
