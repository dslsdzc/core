// === dump.cr ===
// IR/CCR dump formatting helpers and diagnostic output commands.

fn ir_var_str(var_idx: int) -> string {
    if var_idx < 0 { return ""; }
    n := get_ir_var_name(var_idx);
    if __builtin_str_len(n) > 0 { return n; }
    return __builtin_int_to_str(var_idx);
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

fn ir_instr_str(instr: IRInstr) -> string {
    opname := df_opcode_name(instr.opcode);
    s : ., mut = "  ";
    s = s + opname;
    pa : ., mut = __builtin_str_len(opname);
    loop {
        if pa >= 18 { break; }
        s = s + " ";
        pa = pa + 1;
    }

    if instr.opcode == IR_CONST {
        s = s + ir_var_str(instr.dest) + " = " + __builtin_int_to_str(instr.src1);
        return s;
    }
    if instr.opcode == IR_BINARY {
        s = s + ir_var_str(instr.dest) + " = " + ir_var_str(instr.src1) + " " + binop_name(instr.src3) + " " + ir_var_str(instr.src2);
        return s;
    }
    if instr.opcode == IR_UNARY {
        s = s + ir_var_str(instr.dest) + " = unary(" + ir_var_str(instr.src1) + ")";
        return s;
    }
    if instr.opcode == IR_CALL {
        s = s + ir_var_str(instr.dest) + " = call " + g_strs[instr.src3] + "(";
        ai : ., mut = 0;
        a_first : ., mut = 1;
        loop {
            if ai >= instr.src2 { break; }
            if a_first == 0 { s = s + ", "; }
            s = s + ir_var_str(instr.src1 + ai);
            a_first = 0;
            ai = ai + 1;
        }
        s = s + ")";
        return s;
    }
    if instr.opcode == IR_RETURN {
        if instr.src1 >= 0 { s = s + ir_var_str(instr.src1); }
        else { s = s + "void"; }
        return s;
    }
    if instr.opcode == IR_ALLOC {
        s = s + ir_var_str(instr.dest) + " : " + type_kind_name(instr.type_kind);
        return s;
    }
    if instr.opcode == IR_ALLOC_STRUCT {
        s = s + ir_var_str(instr.dest) + " : struct " + g_strs[instr.src3];
        return s;
    }
    if instr.opcode == IR_ALLOC_ARRAY {
        s = s + ir_var_str(instr.dest) + "[" + __builtin_int_to_str(instr.src1) + "]";
        return s;
    }
    if instr.opcode == IR_STORE {
        s = s + ir_var_str(instr.src1) + " <- " + ir_var_str(instr.src2);
        return s;
    }
    if instr.opcode == IR_LOAD {
        s = s + ir_var_str(instr.dest) + " = " + ir_var_str(instr.src1);
        return s;
    }
    if instr.opcode == IR_LOAD_FIELD {
        s = s + ir_var_str(instr.dest) + " = " + ir_var_str(instr.src1) + "." + __builtin_int_to_str(instr.src3);
        return s;
    }
    if instr.opcode == IR_STORE_FIELD {
        s = s + ir_var_str(instr.src1) + "." + __builtin_int_to_str(instr.src3) + " <- " + ir_var_str(instr.src2);
        return s;
    }
    if instr.opcode == IR_LOAD_INDEX {
        s = s + ir_var_str(instr.dest) + " = " + ir_var_str(instr.src1) + "[" + __builtin_int_to_str(instr.src3) + "]";
        return s;
    }
    if instr.opcode == IR_STORE_INDEX {
        s = s + ir_var_str(instr.src1) + "[" + __builtin_int_to_str(instr.src3) + "] <- " + ir_var_str(instr.src2);
        return s;
    }
    if instr.opcode == IR_LOAD_INDEX_VAR {
        s = s + ir_var_str(instr.dest) + " = " + ir_var_str(instr.src1) + "[" + ir_var_str(instr.src2) + "]";
        return s;
    }
    if instr.opcode == IR_STORE_INDEX_VAR {
        s = s + ir_var_str(instr.src1) + "[" + ir_var_str(instr.src2) + "] <- " + ir_var_str(instr.dest);
        return s;
    }
    if instr.opcode == IR_MAKE_ENUM {
        s = s + ir_var_str(instr.dest) + " = make_enum(" + g_strs[instr.src1] + ")";
        return s;
    }
    if instr.opcode == IR_REF {
        s = s + ir_var_str(instr.dest) + " = ref " + ir_var_str(instr.src1);
        return s;
    }
    if instr.opcode == IR_DEREF {
        s = s + ir_var_str(instr.dest) + " = deref " + ir_var_str(instr.src1);
        return s;
    }
    if instr.opcode == IR_STORE_PTR {
        s = s + ir_var_str(instr.src1) + " := " + ir_var_str(instr.src2);
        return s;
    }
    if instr.opcode == IR_BRANCH {
        s = s + "if " + ir_var_str(instr.src1) + " goto label" + __builtin_int_to_str(instr.src2) + " else label" + __builtin_int_to_str(instr.src3);
        return s;
    }
    if instr.opcode == IR_JUMP {
        s = s + "goto label" + __builtin_int_to_str(instr.src1);
        return s;
    }
    if instr.opcode == IR_LABEL {
        s = s + "label" + __builtin_int_to_str(instr.src1) + ":";
        return s;
    }
    if instr.opcode == IR_PHI {
        s = s + ir_var_str(instr.dest) + " = phi(";
        pi : ., mut = 0;
        p_first : ., mut = 1;
        loop {
            if pi >= instr.src2 { break; }
            if p_first == 0 { s = s + ", "; }
            s = s + ir_var_str(instr.src1 + pi);
            p_first = 0;
            pi = pi + 1;
        }
        s = s + ")";
        return s;
    }
    if instr.opcode == IR_LOAD_ENUM_TAG {
        s = s + ir_var_str(instr.dest) + " = tag " + ir_var_str(instr.src1);
        return s;
    }
    if instr.opcode == IR_SLICE {
        s = s + ir_var_str(instr.dest) + " = slice " + ir_var_str(instr.src1) + "[" + ir_var_str(instr.src2) + ":" + ir_var_str(instr.src3) + "]";
        return s;
    }

    s = s + "dest=" + ir_var_str(instr.dest) + " s1=" + __builtin_int_to_str(instr.src1) + " s2=" + __builtin_int_to_str(instr.src2) + " s3=" + __builtin_int_to_str(instr.src3);
    return s;
}

fn cmd_ir(src_path: string) -> int {
    g_source = __builtin_read_file(src_path);
    if __builtin_str_len(g_source) == 0 {
        __builtin_print("error: cannot read ");
        __builtin_println(src_path);
        return 1;
    }
    g_source_dir = dirname(src_path);
    tokenize();
    g_str_count = 0;
    resolve_imports();
    parse_all();
    check_all();
    if g_diag_count > 0 { print_diagnostics(); return 1; }
    ir_gen_all();
    dot := df_graph_to_dot();

    cir_path : ., mut = src_path;
    slen := __builtin_str_len(src_path);
    if slen > 3 {
        ext := __builtin_str_sub(src_path, slen - 3, 3);
        if __builtin_str_eq(ext, ".cr") != 0 {
            cir_path = __builtin_str_sub(src_path, 0, slen - 3) + ".cir";
        }
    }

    written := __builtin_write_file(cir_path, dot);
    if written < 0 {
        __builtin_print("error: could not write ");
        __builtin_println(cir_path);
        return 1;
    }
    __builtin_print(" -> ");
    __builtin_print(cir_path);
    __builtin_print(" (");
    __builtin_print(__builtin_int_to_str(g_df_node_count));
    __builtin_print(" nodes, ");
    __builtin_print(__builtin_int_to_str(g_df_edge_count));
    __builtin_println(" edges)");
    return 0;
}

fn cmd_cir(src_path: string) -> int {
    g_source = __builtin_read_file(src_path);
    if __builtin_str_len(g_source) == 0 {
        __builtin_print("error: cannot read ");
        __builtin_println(src_path);
        return 1;
    }
    g_source_dir = dirname(src_path);
    tokenize();
    g_str_count = 0;
    resolve_imports();
    parse_all();
    check_all();
    if g_diag_count > 0 { print_diagnostics(); return 1; }
    ir_gen_all();
    lower_to_ccr();

    ccr : ., mut = "";
    fi : ., mut = 0;
    loop {
        if fi >= g_ir_func_count { break; }
        name_ni := g_ir_func_name_idx[fi];
        ccr = ccr + "Function: " + g_strs[name_ni] + "\n";
        start := g_ir_func_instr_start[fi];
        count := g_ir_func_instr_count[fi];
        in_block : ., mut = 0;
        ii : ., mut = 0;
        loop {
            if ii >= count { break; }
            instr := g_ir_instrs[start + ii];
            if instr.opcode == IR_LABEL {
                if in_block != 0 { ccr = ccr + "\n"; }
                ccr = ccr + "  Block: label" + __builtin_int_to_str(instr.src1) + "\n";
                in_block = 1;
            } else {
                ccr = ccr + "    " + ir_instr_str(instr) + "\n";
            }
            ii = ii + 1;
        }
        ccr = ccr + "\n";
        fi = fi + 1;
    }

    ccr_path : ., mut = src_path;
    slen := __builtin_str_len(src_path);
    if slen > 3 {
        ext := __builtin_str_sub(src_path, slen - 3, 3);
        if __builtin_str_eq(ext, ".cr") != 0 {
            ccr_path = __builtin_str_sub(src_path, 0, slen - 3) + ".ccr";
        }
    }

    written := __builtin_write_file(ccr_path, ccr);
    if written < 0 {
        __builtin_print("error: could not write ");
        __builtin_println(ccr_path);
        return 1;
    }
    __builtin_print(" -> ");
    __builtin_print(ccr_path);
    __builtin_print(" (");
    __builtin_print(__builtin_int_to_str(g_ir_func_count));
    __builtin_print(" functions, ");
    __builtin_print(__builtin_int_to_str(g_ir_instr_count));
    __builtin_println(" instrs)");
    return 0;
}
