// === dump.cr ===
// IR/CCR dump formatting helpers and diagnostic output commands.

g_dump_buf : string, mut
g_dump_pos : int, mut
g_dump_cap : int, mut

fn dump_buf_reset():
    g_dump_cap = 4096
    g_dump_buf = alloc(g_dump_cap)
    g_dump_pos = 0

fn dump_buf_grow(needed: int):
    if needed < g_dump_cap:
        return
    nc : ., mut = g_dump_cap * 2
    loop:
        if nc > needed:
            break
        nc = nc * 2
    nb := alloc(nc)
    if g_dump_pos > 0:
        cell_copy(g_dump_buf, g_dump_pos, nb)
    g_dump_buf = nb
    g_dump_cap = nc

fn dump_buf_append(s: string):
    sl := str_len(s)
    dump_buf_grow(g_dump_pos + sl + 1)
    i : ., mut = 0
    loop:
        if i >= sl:
            break
        cell_store_byte(g_dump_buf, g_dump_pos + i, cell_load_byte(s, i))
        i = i + 1
    g_dump_pos = g_dump_pos + sl

fn dump_buf_finish() -> string:
    out := alloc(g_dump_pos + 1)
    if g_dump_pos > 0:
        cell_copy(g_dump_buf, g_dump_pos, out)
    cell_store_byte(out, g_dump_pos, 0)
    return out

fn ir_var_str(var_idx: int) -> string:
    if var_idx < 0:
        return ""
    n := get_ir_var_name(var_idx)
    if str_len(n) > 0:
        return n
    return int_str(var_idx)

fn type_kind_name(tk: int) -> string:
    return match tk:
        0 => "int"
        1 => "dex"
        2 => "bool"
        3 => "str"
        4 => "unit"
        5 => "never"
        6 => "char"
        8 => "dex"   // TI_DEX_S: fixed-point exact form.
        _ => "?"

fn binop_name(op: int) -> string:
    return match op:
        1 => "+"
        2 => "-"
        3 => "*"
        4 => "/"
        5 => "%"
        6 => "=="
        7 => "!="
        8 => "<"
        9 => ">"
        10 => "<="
        11 => ">="
        12 => "&&"
        13 => "||"
        17 => "+ (ptr)"
        18 => "- (ptr)"
        19 => "- (diff)"
        _ => "?"

fn ir_instr_str(instr_idx: int) -> string:
    opname := df_opcode_name(iri_op(instr_idx), iri_s3(instr_idx))
    s : ., mut = "  "
    s = s + opname
    pa : ., mut = str_len(opname)
    loop:
        if pa >= 18:
            break
        s = s + " "
        pa = pa + 1

    if iri_op(instr_idx) == IR_CONST:
        s = s + ir_var_str(iri_dest(instr_idx)) + " = " + int_str(iri_s1(instr_idx))
        return s
    if iri_op(instr_idx) == IR_BINARY:
        s = s + ir_var_str(iri_dest(instr_idx)) + " = " + ir_var_str(iri_s1(instr_idx)) + " " + binop_name(iri_s3(instr_idx)) + " " + ir_var_str(iri_s2(instr_idx))
        return s
    if iri_op(instr_idx) == IR_UNARY:
        s = s + ir_var_str(iri_dest(instr_idx)) + " = unary(" + ir_var_str(iri_s1(instr_idx)) + ")"
        return s
    if iri_op(instr_idx) == IR_CALL:
        s = s + ir_var_str(iri_dest(instr_idx)) + " = call " + istr_get(iri_s3(instr_idx)) + "("
        ai : ., mut = 0
        a_first : ., mut = 1
        loop:
            if ai >= iri_s2(instr_idx):
                break
            if a_first == 0:
                s = s + ", "
            s = s + ir_var_str(iri_s1(instr_idx) + ai)
            a_first = 0
            ai = ai + 1
        s = s + ")"
        return s
    if iri_op(instr_idx) == IR_RETURN:
        if iri_s1(instr_idx) >= 0:
            s = s + ir_var_str(iri_s1(instr_idx))
        else:
            s = s + "void"
        return s
    if iri_op(instr_idx) == IR_ALLOC:
        s = s + ir_var_str(iri_dest(instr_idx)) + " : " + type_kind_name(iri_tk(instr_idx))
        return s
    if iri_op(instr_idx) == IR_ALLOC_STRUCT:
        s = s + ir_var_str(iri_dest(instr_idx)) + " : struct " + istr_get(iri_s3(instr_idx))
        return s
    if iri_op(instr_idx) == IR_ALLOC_ARRAY:
        s = s + ir_var_str(iri_dest(instr_idx)) + "[" + int_str(iri_s1(instr_idx)) + "]"
        return s
    if iri_op(instr_idx) == IR_STORE:
        s = s + ir_var_str(iri_s1(instr_idx)) + " <- " + ir_var_str(iri_s2(instr_idx))
        return s
    if iri_op(instr_idx) == IR_LOAD:
        s = s + ir_var_str(iri_dest(instr_idx)) + " = " + ir_var_str(iri_s1(instr_idx))
        return s
    if iri_op(instr_idx) == IR_LOAD_FIELD:
        s = s + ir_var_str(iri_dest(instr_idx)) + " = " + ir_var_str(iri_s1(instr_idx)) + "." + int_str(iri_s3(instr_idx))
        return s
    if iri_op(instr_idx) == IR_STORE_FIELD:
        s = s + ir_var_str(iri_s1(instr_idx)) + "." + int_str(iri_s3(instr_idx)) + " <- " + ir_var_str(iri_s2(instr_idx))
        return s
    if iri_op(instr_idx) == IR_LOAD_INDEX:
        s = s + ir_var_str(iri_dest(instr_idx)) + " = " + ir_var_str(iri_s1(instr_idx)) + "[" + int_str(iri_s3(instr_idx)) + "]"
        return s
    if iri_op(instr_idx) == IR_STORE_INDEX:
        s = s + ir_var_str(iri_s1(instr_idx)) + "[" + int_str(iri_s3(instr_idx)) + "] <- " + ir_var_str(iri_s2(instr_idx))
        return s
    if iri_op(instr_idx) == IR_LOAD_INDEX_VAR:
        s = s + ir_var_str(iri_dest(instr_idx)) + " = " + ir_var_str(iri_s1(instr_idx)) + "[" + ir_var_str(iri_s2(instr_idx)) + "]"
        return s
    if iri_op(instr_idx) == IR_STORE_INDEX_VAR:
        s = s + ir_var_str(iri_s1(instr_idx)) + "[" + ir_var_str(iri_s2(instr_idx)) + "] <- " + ir_var_str(iri_dest(instr_idx))
        return s
    if iri_op(instr_idx) == IR_MAKE_ENUM:
        s = s + ir_var_str(iri_dest(instr_idx)) + " = make_enum(" + istr_get(iri_s1(instr_idx)) + ")"
        return s
    if iri_op(instr_idx) == IR_REF:
        s = s + ir_var_str(iri_dest(instr_idx)) + " = ref " + ir_var_str(iri_s1(instr_idx))
        return s
    if iri_op(instr_idx) == IR_DEREF:
        s = s + ir_var_str(iri_dest(instr_idx)) + " = deref " + ir_var_str(iri_s1(instr_idx))
        return s
    if iri_op(instr_idx) == IR_STORE_PTR:
        s = s + ir_var_str(iri_s1(instr_idx)) + " := " + ir_var_str(iri_s2(instr_idx))
        return s
    if iri_op(instr_idx) == IR_BRANCH:
        s = s + "if " + ir_var_str(iri_s1(instr_idx)) + " goto label" + int_str(iri_s2(instr_idx)) + " else label" + int_str(iri_s3(instr_idx))
        return s
    if iri_op(instr_idx) == IR_MATCH:
        // CASE rows live in the global table; print the range so the cir dump
        // and --dump-objects agree on which rows belong to this node.
        s = s + "match " + ir_var_str(iri_s1(instr_idx)) + " cases " + int_str(iri_s2(instr_idx)) + ".." + int_str(iri_s2(instr_idx) + iri_s3(instr_idx))
        return s
    if iri_op(instr_idx) == IR_JUMP:
        s = s + "goto label" + int_str(iri_s1(instr_idx))
        return s
    if iri_op(instr_idx) == IR_LABEL:
        s = s + "label" + int_str(iri_s1(instr_idx)) + ":"
        return s
    if iri_op(instr_idx) == IR_PHI:
        s = s + ir_var_str(iri_dest(instr_idx)) + " = phi("
        pi : ., mut = 0
        p_first : ., mut = 1
        loop:
            if pi >= iri_s2(instr_idx):
                break
            if p_first == 0:
                s = s + ", "
            s = s + ir_var_str(iri_s1(instr_idx) + pi)
            p_first = 0
            pi = pi + 1
        s = s + ")"
        return s
    if iri_op(instr_idx) == IR_LOAD_ENUM_TAG:
        s = s + ir_var_str(iri_dest(instr_idx)) + " = tag " + ir_var_str(iri_s1(instr_idx))
        return s
    if iri_op(instr_idx) == IR_SLICE:
        s = s + ir_var_str(iri_dest(instr_idx)) + " = slice " + ir_var_str(iri_s1(instr_idx)) + "[" + ir_var_str(iri_s2(instr_idx)) + ":" + ir_var_str(iri_s3(instr_idx)) + "]"
        return s

    s = s + "dest=" + ir_var_str(iri_dest(instr_idx)) + " s1=" + int_str(iri_s1(instr_idx)) + " s2=" + int_str(iri_s2(instr_idx)) + " s3=" + int_str(iri_s3(instr_idx))
    return s

fn cmd_ir(src_path: string) -> int:
    g_source = read_file(src_path)
    if str_len(g_source) == 0:
        print("error: cannot read ")
        println(src_path)
        return 1
    g_source_dir = dirname(src_path)
    g_error_count = 0  // reset before a new tokenize pass; lexical errors accumulate across passes
    sm_reset()
    source_file := sm_add_file(src_path, g_source)
    tokenize(source_file, 0)
    g_str_count = 0
    res_imports()
    parse_all()
    check_all()
    if g_diag_count > 0:
        print_diagnostics()
        return 1
    if g_error_count > 0:
        print_parse_errors()
        return 1
    ir_gen_all()
    dot := df_graph_to_dot()

    cir_path : ., mut = src_path
    slen := str_len(src_path)
    if slen > 3:
        ext := str_sub(src_path, slen - 3, 3)
        if str_eq(ext, ".cr") != 0:
            cir_path = str_sub(src_path, 0, slen - 3) + ".cir"

    written := write_file(cir_path, dot)
    if written < 0:
        print("error: could not write ")
        println(cir_path)
        return 1
    print(" -> ")
    print(cir_path)
    print(" (")
    print(int_str(g_df_node_count))
    print(" nodes, ")
    print(int_str(g_df_edge_count))
    println(" edges)")
    return 0

// Text dump of the linear control-flow graph: a function header, its regions
// (SG_IF, SG_LOOP, SG_FOR, SG_FLOW, SG_UNSAFE), and label blocks. Used by
// main.cr's cir command, which writes stdout.
fn cir_text_dump() -> string:
    dump_buf_reset()
    fi : ., mut = 0
    loop:
        if fi >= g_ir_func_count:
            break
        name_ni := cell_load(g_ir_func_name_idx, fi * 8)
        dump_buf_append("Function: ")
        dump_buf_append(istr_get(name_ni))
        dump_buf_append("\n")
        start := cell_load(g_ir_func_instr_start, fi * 8)
        count := cell_load(g_ir_func_instr_count, fi * 8)
        // Region list for this function (regions whose DFNode start falls in
        // this function's instruction range)
        ri : ., mut = 0
        loop:
            if ri >= g_sg_count:
                break
            rkind := cell_load(g_sgs, ri * ESZ_SG + OFF_SG_KIND)
            rstart := cell_load(g_sgs, ri * ESZ_SG + OFF_SG_NSTART)
            rend := cell_load(g_sgs, ri * ESZ_SG + OFF_SG_EXIT)
            if rstart >= start && rstart < start + count:
                rend := cell_load(g_sgs, ri * ESZ_SG + OFF_SG_EXIT)
                if rend >= 0:
                    // skip unclosed (EXIT<0) regions
                    rname : ., mut = "?"
                    if rkind == SG_FUNC:
                        rname = "func"
                    if rkind == SG_IF:
                        rname = "if"
                    if rkind == SG_LOOP:
                        rname = "loop"
                    if rkind == SG_FOR:
                        rname = "for"
                    if rkind == SG_FLOW:
                        rname = "flow"
                    if rkind == SG_UNSAFE:
                        rname = "unsafe"
                    dump_buf_append("  Region: ")
                    dump_buf_append(rname)
                    dump_buf_append(" nodes ")
                    dump_buf_append(int_str(rstart))
                    dump_buf_append("..")
                    dump_buf_append(int_str(rend))
                    dump_buf_append("\n")
            ri = ri + 1
        in_block : ., mut = 0
        ii : ., mut = 0
        loop:
            if ii >= count:
                break
            if iri_op(start + ii) == IR_LABEL:
                if in_block != 0:
                    dump_buf_append("\n")
                dump_buf_append("  Block: label")
                dump_buf_append(int_str(iri_s1(start + ii)))
                dump_buf_append("\n")
                in_block = 1
            else:
                dump_buf_append("    ")
                dump_buf_append(ir_instr_str(start + ii))
                dump_buf_append("\n")
            ii = ii + 1
        dump_buf_append("\n")
        fi = fi + 1

    // VSDG state edges: side-effect chain + loop termination dependencies
    dump_buf_append("State edges:\n")
    ei : ., mut = 0
    loop:
        if ei >= g_df_edge_count:
            break
        if cell_load(g_df_edges, ei * ESZ_DFEDGE + OFF_DFE_KIND) != 0:
            e_from := cell_load(g_df_edges, ei * ESZ_DFEDGE + OFF_DFE_FROM)
            e_to := cell_load(g_df_edges, ei * ESZ_DFEDGE + OFF_DFE_TO)
            dump_buf_append("  state: n")
            dump_buf_append(int_str(e_from))
            dump_buf_append(" -> n")
            dump_buf_append(int_str(e_to))
            dump_buf_append("\n")
        ei = ei + 1
    return dump_buf_finish()

// Hidden test channel: cir --dump-tk-terms.
// It gives a per-node view of the single-slot type encoding: OFF_DF_TK holds the
// type-term reference, OFF_DF_AUX holds the auxiliary code, and
// sh_dfn_code_of_slots derives the code used by iri_tk and the .ccr NOD records.
// The term structure (tag, a, b, c) is read directly from g_type_terms. Cold and
// warm paths dump through the same channel for line-by-line comparison.
// The channel is read-only and produces no artifact, like --dump-types and
// --dump-ifaces.
// Format: a header line, then tab-separated rows.
//   [df-tk-terms] nodes=N with_term=M bad_term=B aux_nonzero=A face_fail=F terms=K rows=R mint=...
//   <node> <opcode> <tk> <term> <tag> <a> <b> <c> <aux>
// A negative term, or a term index outside the term table, prints tag, a, b, and
// c as -1. aux_nonzero counts nodes with a non-zero auxiliary code. face_fail
// counts type-face construction failures. rows is the current type-table size;
// a warm table can be smaller than a cold table.
fn df_tk_term_dump() -> string:
    dump_buf_reset()
    total := g_df_node_count
    with_term : ., mut = 0
    bad_term : ., mut = 0
    auxn : ., mut = 0
    n0 : ., mut = 0
    loop:
        if n0 >= total:
            break
        t0 := cell_load(g_df_nodes, n0 * ESZ_DFNODE + OFF_DF_TK)
        if t0 >= 0:
            with_term = with_term + 1
        if t0 >= tt_count():
            bad_term = bad_term + 1
        if cell_load(g_df_nodes, n0 * ESZ_DFNODE + OFF_DF_AUX) != 0:
            auxn = auxn + 1
        n0 = n0 + 1
    dump_buf_append("[df-tk-terms] nodes=")
    dump_buf_append(int_str(total))
    dump_buf_append(" with_term=")
    dump_buf_append(int_str(with_term))
    dump_buf_append(" bad_term=")
    dump_buf_append(int_str(bad_term))
    dump_buf_append(" aux_nonzero=")
    dump_buf_append(int_str(auxn))
    dump_buf_append(" face_fail=")
    dump_buf_append(int_str(g_tk_face_fail))
    dump_buf_append(" terms=")
    dump_buf_append(int_str(tt_count()))
    dump_buf_append(" rows=")
    dump_buf_append(int_str(g_type_count))
    dump_buf_append(" mint=")
    dump_buf_append(int_str(IR_CONST))
    dump_buf_append(",")
    dump_buf_append(int_str(IR_BINARY))
    dump_buf_append(",")
    dump_buf_append(int_str(IR_ALLOC))
    dump_buf_append(",")
    dump_buf_append(int_str(IR_CALL))
    dump_buf_append(",")
    dump_buf_append(int_str(IR_LOAD))
    dump_buf_append(",")
    dump_buf_append(int_str(IR_I2F))
    dump_buf_append(",")
    dump_buf_append(int_str(IR_F2I))
    dump_buf_append("\n")
    n : ., mut = 0
    loop:
        if n >= total:
            break
        op := cell_load(g_df_nodes, n * ESZ_DFNODE + OFF_DF_OPCODE)
        t := cell_load(g_df_nodes, n * ESZ_DFNODE + OFF_DF_TK)
        ax := cell_load(g_df_nodes, n * ESZ_DFNODE + OFF_DF_AUX)
        tk := sh_dfn_code_of_slots(t, ax)
        dump_buf_append(int_str(n))
        dump_buf_append("\t")
        dump_buf_append(int_str(op))
        dump_buf_append("\t")
        dump_buf_append(int_str(tk))
        dump_buf_append("\t")
        dump_buf_append(int_str(t))
        dump_buf_append("\t")
        if t >= 0 && t < tt_count():
            dump_buf_append(int_str(tt_tag(t)))
            dump_buf_append("\t")
            dump_buf_append(int_str(tt_a(t)))
            dump_buf_append("\t")
            dump_buf_append(int_str(tt_b(t)))
            dump_buf_append("\t")
            dump_buf_append(int_str(tt_c(t)))
        else:
            dump_buf_append("-1\t-1\t-1\t-1")
        dump_buf_append("\t")
        dump_buf_append(int_str(ax))
        dump_buf_append("\n")
        n = n + 1
    return dump_buf_finish()

// Text form of a specification expression for --dump-vcs. It is display-only and
// does not participate in checking; spec_check_all and spec_check_func in
// checker.cr decide validity.
// Supported forms are int and bool literals, identifiers, unary - and !, binary
// arithmetic, comparison, and logical operators, and explicit parentheses.
// Other node kinds print (?) and are rejected by V05 or V06 in the checker.
fn spec_expr_text(e: int) -> string:
    if e < 0:
        return "?"
    k := ast_kind(e)
    if k == EXPR_INT:
        return int_str(ast_int_val(e))
    if k == EXPR_BOOL:
        if ast_int_val(e) != 0:
            return "true"
        return "false"
    if k == EXPR_IDENT:
        return istr_get(ast_int_val(e))
    if k == EXPR_UNARY:
        op := ast_c(e)
        if op == UOP_NEG:
            return "(-" + spec_expr_text(ast_a(e)) + ")"
        if op == UOP_NOT:
            return "!" + spec_expr_text(ast_a(e))
        return "(?)"
    if k == EXPR_BINARY:
        return "(" + spec_expr_text(ast_a(e)) + " " + binop_name(ast_c(e)) + " " + spec_expr_text(ast_b(e)) + ")"
    return "(?)"

// VC list dump for the hidden --dump-vcs channel.
// It writes to stdout, creates no artifact, and does not change the return code.
// Red VCs (V01, V04, V05, V06) go through diagnostics with a location and rc 1;
// green and yellow VCs go through this dump. Red VCs are also listed as
// status=red, so omission is distinguishable from a red result. The dump runs
// before main.cr's fail-closed gate, so red cases still appear.
// It reads only the g_spec_* side tables used by checking, which keeps dump and
// check results consistent. Order is source order and is independent of the .cir
// cache; cold and warm runs produce the same output.
fn vcs_dump() -> string:
    dump_buf_reset()
    dump_buf_append("[vcs] count=")
    dump_buf_append(int_str(g_spec_count))
    dump_buf_append("\n")
    i : ., mut = 0
    loop:
        if i >= g_spec_count:
            break
        st : ., mut = "yellow"
        s := spec_status(i)
        if s == SPEC_ST_GREEN:
            st = "green"
        else if s == SPEC_ST_RED:
            st = "red"
        kn : ., mut = "check"
        if spec_kind(i) == 1:
            kn = "ensure"
        dump_buf_append("[vcs] vc ")
        dump_buf_append(int_str(i))
        dump_buf_append(" fn=")
        dump_buf_append(istr_get(spec_fn(i)))
        dump_buf_append(" kind=")
        dump_buf_append(kn)
        dump_buf_append(" status=")
        dump_buf_append(st)
        dump_buf_append(" line=")
        dump_buf_append(int_str(spec_line(i)))
        dump_buf_append(" col=")
        dump_buf_append(int_str(spec_col(i)))
        dump_buf_append(" expr=")
        dump_buf_append(spec_expr_text(spec_expr(i)))
        dump_buf_append("\n")
        i = i + 1
    return dump_buf_finish()
