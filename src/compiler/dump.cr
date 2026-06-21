// === dump.cr ===
// IR/CCR dump formatting helpers and diagnostic output commands.

fn ir_var_str(var_idx: int) -> string {
    if var_idx < 0 { return ""; }
    n := get_ir_var_name(var_idx);
    if str_len(n) > 0 { return n; }
    return int_str(var_idx);
}

fn type_kind_name(tk: int) -> string {
    if tk == 0 { return "int"; }
    if tk == 1 { return "float"; }
    if tk == 2 { return "bool"; }
    if tk == 3 { return "str"; }
    if tk == 4 { return "unit"; }
    if tk == 5 { return "never"; }
    if tk == 6 { return "char"; }
    return "?";
}

fn binop_name(op: int) -> string {
    if op == 1 { return "+"; }
    if op == 2 { return "-"; }
    if op == 3 { return "*"; }
    if op == 4 { return "/"; }
    if op == 5 { return "%"; }
    if op == 6 { return "=="; }
    if op == 7 { return "!="; }
    if op == 8 { return "<"; }
    if op == 9 { return ">"; }
    if op == 10 { return "<="; }
    if op == 11 { return ">="; }
    if op == 12 { return "&&"; }
    if op == 13 { return "||"; }
    return "?";
}

fn ir_instr_str(instr_idx: int) -> string {
    opname := df_opcode_name(iri_op(instr_idx));
    s : ., mut = "  ";
    s = s + opname;
    pa : ., mut = str_len(opname);
    loop {
        if pa >= 18 { break; }
        s = s + " ";
        pa = pa + 1;
    }

    if iri_op(instr_idx) == IR_CONST {
        s = s + ir_var_str(iri_dest(instr_idx)) + " = " + int_str(iri_s1(instr_idx));
        return s;
    }
    if iri_op(instr_idx) == IR_BINARY {
        s = s + ir_var_str(iri_dest(instr_idx)) + " = " + ir_var_str(iri_s1(instr_idx)) + " " + binop_name(iri_s3(instr_idx)) + " " + ir_var_str(iri_s2(instr_idx));
        return s;
    }
    if iri_op(instr_idx) == IR_UNARY {
        s = s + ir_var_str(iri_dest(instr_idx)) + " = unary(" + ir_var_str(iri_s1(instr_idx)) + ")";
        return s;
    }
    if iri_op(instr_idx) == IR_CALL {
        s = s + ir_var_str(iri_dest(instr_idx)) + " = call " + istr_get(iri_s3(instr_idx)) + "(";
        ai : ., mut = 0;
        a_first : ., mut = 1;
        loop {
            if ai >= iri_s2(instr_idx) { break; }
            if a_first == 0 { s = s + ", "; }
            s = s + ir_var_str(iri_s1(instr_idx) + ai);
            a_first = 0;
            ai = ai + 1;
        }
        s = s + ")";
        return s;
    }
    if iri_op(instr_idx) == IR_RETURN {
        if iri_s1(instr_idx) >= 0 { s = s + ir_var_str(iri_s1(instr_idx)); }
        else { s = s + "void"; }
        return s;
    }
    if iri_op(instr_idx) == IR_ALLOC {
        s = s + ir_var_str(iri_dest(instr_idx)) + " : " + type_kind_name(iri_tk(instr_idx));
        return s;
    }
    if iri_op(instr_idx) == IR_ALLOC_STRUCT {
        s = s + ir_var_str(iri_dest(instr_idx)) + " : struct " + istr_get(iri_s3(instr_idx));
        return s;
    }
    if iri_op(instr_idx) == IR_ALLOC_ARRAY {
        s = s + ir_var_str(iri_dest(instr_idx)) + "[" + int_str(iri_s1(instr_idx)) + "]";
        return s;
    }
    if iri_op(instr_idx) == IR_STORE {
        s = s + ir_var_str(iri_s1(instr_idx)) + " <- " + ir_var_str(iri_s2(instr_idx));
        return s;
    }
    if iri_op(instr_idx) == IR_LOAD {
        s = s + ir_var_str(iri_dest(instr_idx)) + " = " + ir_var_str(iri_s1(instr_idx));
        return s;
    }
    if iri_op(instr_idx) == IR_LOAD_FIELD {
        s = s + ir_var_str(iri_dest(instr_idx)) + " = " + ir_var_str(iri_s1(instr_idx)) + "." + int_str(iri_s3(instr_idx));
        return s;
    }
    if iri_op(instr_idx) == IR_STORE_FIELD {
        s = s + ir_var_str(iri_s1(instr_idx)) + "." + int_str(iri_s3(instr_idx)) + " <- " + ir_var_str(iri_s2(instr_idx));
        return s;
    }
    if iri_op(instr_idx) == IR_LOAD_INDEX {
        s = s + ir_var_str(iri_dest(instr_idx)) + " = " + ir_var_str(iri_s1(instr_idx)) + "[" + int_str(iri_s3(instr_idx)) + "]";
        return s;
    }
    if iri_op(instr_idx) == IR_STORE_INDEX {
        s = s + ir_var_str(iri_s1(instr_idx)) + "[" + int_str(iri_s3(instr_idx)) + "] <- " + ir_var_str(iri_s2(instr_idx));
        return s;
    }
    if iri_op(instr_idx) == IR_LOAD_INDEX_VAR {
        s = s + ir_var_str(iri_dest(instr_idx)) + " = " + ir_var_str(iri_s1(instr_idx)) + "[" + ir_var_str(iri_s2(instr_idx)) + "]";
        return s;
    }
    if iri_op(instr_idx) == IR_STORE_INDEX_VAR {
        s = s + ir_var_str(iri_s1(instr_idx)) + "[" + ir_var_str(iri_s2(instr_idx)) + "] <- " + ir_var_str(iri_dest(instr_idx));
        return s;
    }
    if iri_op(instr_idx) == IR_MAKE_ENUM {
        s = s + ir_var_str(iri_dest(instr_idx)) + " = make_enum(" + istr_get(iri_s1(instr_idx)) + ")";
        return s;
    }
    if iri_op(instr_idx) == IR_REF {
        s = s + ir_var_str(iri_dest(instr_idx)) + " = ref " + ir_var_str(iri_s1(instr_idx));
        return s;
    }
    if iri_op(instr_idx) == IR_DEREF {
        s = s + ir_var_str(iri_dest(instr_idx)) + " = deref " + ir_var_str(iri_s1(instr_idx));
        return s;
    }
    if iri_op(instr_idx) == IR_STORE_PTR {
        s = s + ir_var_str(iri_s1(instr_idx)) + " := " + ir_var_str(iri_s2(instr_idx));
        return s;
    }
    if iri_op(instr_idx) == IR_BRANCH {
        s = s + "if " + ir_var_str(iri_s1(instr_idx)) + " goto label" + int_str(iri_s2(instr_idx)) + " else label" + int_str(iri_s3(instr_idx));
        return s;
    }
    if iri_op(instr_idx) == IR_JUMP {
        s = s + "goto label" + int_str(iri_s1(instr_idx));
        return s;
    }
    if iri_op(instr_idx) == IR_LABEL {
        s = s + "label" + int_str(iri_s1(instr_idx)) + ":";
        return s;
    }
    if iri_op(instr_idx) == IR_PHI {
        s = s + ir_var_str(iri_dest(instr_idx)) + " = phi(";
        pi : ., mut = 0;
        p_first : ., mut = 1;
        loop {
            if pi >= iri_s2(instr_idx) { break; }
            if p_first == 0 { s = s + ", "; }
            s = s + ir_var_str(iri_s1(instr_idx) + pi);
            p_first = 0;
            pi = pi + 1;
        }
        s = s + ")";
        return s;
    }
    if iri_op(instr_idx) == IR_LOAD_ENUM_TAG {
        s = s + ir_var_str(iri_dest(instr_idx)) + " = tag " + ir_var_str(iri_s1(instr_idx));
        return s;
    }
    if iri_op(instr_idx) == IR_SLICE {
        s = s + ir_var_str(iri_dest(instr_idx)) + " = slice " + ir_var_str(iri_s1(instr_idx)) + "[" + ir_var_str(iri_s2(instr_idx)) + ":" + ir_var_str(iri_s3(instr_idx)) + "]";
        return s;
    }

    s = s + "dest=" + ir_var_str(iri_dest(instr_idx)) + " s1=" + int_str(iri_s1(instr_idx)) + " s2=" + int_str(iri_s2(instr_idx)) + " s3=" + int_str(iri_s3(instr_idx));
    return s;
}

fn cmd_ir(src_path: string) -> int {
    g_source = read_file(src_path);
    if str_len(g_source) == 0 {
        print("error: cannot read ");
        println(src_path);
        return 1;
    }
    g_source_dir = dirname(src_path);
    tokenize();
    g_str_count = 0;
    res_imports();
    parse_all();
    check_all();
    if g_diag_count > 0 { print_diagnostics(); return 1; }
    ir_gen_all();
    dot := df_graph_to_dot();

    cir_path : ., mut = src_path;
    slen := str_len(src_path);
    if slen > 3 {
        ext := str_sub(src_path, slen - 3, 3);
        if str_eq(ext, ".cr") != 0 {
            cir_path = str_sub(src_path, 0, slen - 3) + ".cir";
        }
    }

    written := write_file(cir_path, dot);
    if written < 0 {
        print("error: could not write ");
        println(cir_path);
        return 1;
    }
    print(" -> ");
    print(cir_path);
    print(" (");
    print(int_str(g_df_node_count));
    print(" nodes, ");
    print(int_str(g_df_edge_count));
    println(" edges)");
    return 0;
}

fn cmd_cir(src_path: string) -> int {
    g_source = read_file(src_path);
    if str_len(g_source) == 0 {
        print("error: cannot read ");
        println(src_path);
        return 1;
    }
    g_source_dir = dirname(src_path);
    tokenize();
    g_str_count = 0;
    res_imports();
    parse_all();
    check_all();
    if g_diag_count > 0 { print_diagnostics(); return 1; }
    ir_gen_all();
    lower_to_ccr();

    ccr : ., mut = "";
    fi : ., mut = 0;
    loop {
        if fi >= g_ir_func_count { break; }
        name_ni := r64(g_ir_func_name_idx, fi * 8);
        ccr = ccr + "Function: " + istr_get(name_ni) + "\n";
        start := r64(g_ir_func_instr_start, fi * 8);
        count := r64(g_ir_func_instr_count, fi * 8);
        in_block : ., mut = 0;
        ii : ., mut = 0;
        loop {
            if ii >= count { break; }
            if iri_op(start + ii) == IR_LABEL {
                if in_block != 0 { ccr = ccr + "\n"; }
                ccr = ccr + "  Block: label" + int_str(iri_s1(start + ii) + "\n");
                in_block = 1;
            } else {
                ccr = ccr + "    " + ir_instr_str(start + ii) + "\n";
            }
            ii = ii + 1;
        }
        ccr = ccr + "\n";
        fi = fi + 1;
    }

    ccr_path : ., mut = src_path;
    slen := str_len(src_path);
    if slen > 3 {
        ext := str_sub(src_path, slen - 3, 3);
        if str_eq(ext, ".cr") != 0 {
            ccr_path = str_sub(src_path, 0, slen - 3) + ".ccr";
        }
    }

    written := write_file(ccr_path, ccr);
    if written < 0 {
        print("error: could not write ");
        println(ccr_path);
        return 1;
    }
    print(" -> ");
    print(ccr_path);
    print(" (");
    print(int_str(g_ir_func_count));
    print(" functions, ");
    print(int_str(g_ir_instr_count));
    println(" instrs)");
    return 0;
}
