// === dump.cr ===
// IR/CCR dump formatting helpers and diagnostic output commands.

g_dump_buf : string, mut;
g_dump_pos : int, mut;
g_dump_cap : int, mut;

fn dump_buf_reset() {
    g_dump_cap = 4096;
    g_dump_buf = alloc(g_dump_cap);
    g_dump_pos = 0;
}

fn dump_buf_grow(needed: int) {
    if needed < g_dump_cap { return; }
    nc : ., mut = g_dump_cap * 2;
    loop { if nc > needed { break; } nc = nc * 2; }
    nb := alloc(nc);
    if g_dump_pos > 0 { _dyncpy(g_dump_buf, g_dump_pos, nb); }
    g_dump_buf = nb;
    g_dump_cap = nc;
}

fn dump_buf_append(s: string) {
    sl := str_len(s);
    dump_buf_grow(g_dump_pos + sl + 1);
    i : ., mut = 0;
    loop {
        if i >= sl { break; }
        store8(g_dump_buf, g_dump_pos + i, load8(s, i));
        i = i + 1;
    }
    g_dump_pos = g_dump_pos + sl;
}

fn dump_buf_finish() -> string {
    out := alloc(g_dump_pos + 1);
    if g_dump_pos > 0 { _dyncpy(g_dump_buf, g_dump_pos, out); }
    store8(out, g_dump_pos, 0);
    return out;
}

fn ir_var_str(var_idx: int) -> string {
    if var_idx < 0 { return ""; }
    n := get_ir_var_name(var_idx);
    if str_len(n) > 0 { return n; }
    return int_str(var_idx);
}

fn type_kind_name(tk: int) -> string {
    if tk == 0 { return "int"; }
    if tk == 1 { return "dex"; }
    if tk == 2 { return "bool"; }
    if tk == 3 { return "str"; }
    if tk == 4 { return "unit"; }
    if tk == 5 { return "never"; }
    if tk == 6 { return "char"; }
    if tk == 8 { return "dex"; }  // TI_DEX_S（定点精确形式，数值迁移 Task 4）
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
    if op == 17 { return "+ (ptr)"; }
    if op == 18 { return "- (ptr)"; }
    if op == 19 { return "- (diff)"; }
    return "?";
}

fn ir_instr_str(instr_idx: int) -> string {
    opname := df_opcode_name(iri_op(instr_idx), iri_s3(instr_idx));
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
    g_error_count = 0;  // 会话起点（tokenize 多轮累积词法错误，见 lexer.cr）
    tokenize(g_source);
    g_str_count = 0;
    res_imports();
    parse_all();
    check_all();
    if g_diag_count > 0 { print_diagnostics(); return 1; }
    if g_error_count > 0 { print_parse_errors(); return 1; }
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

// Text dump of the linear CFG: "Function: name" + per-function region list
// (SG_IF/SG_LOOP/SG_FOR/SG_FLOW/SG_UNSAFE) + "Block: labelN" blocks.
// Shared by cmd_cir (writes to file) and main.cr's `cir` command (stdout).
fn cir_text_dump() -> string {
    dump_buf_reset();
    fi : ., mut = 0;
    loop {
        if fi >= g_ir_func_count { break; }
        name_ni := r64(g_ir_func_name_idx, fi * 8);
        dump_buf_append("Function: "); dump_buf_append(istr_get(name_ni)); dump_buf_append("\n");
        start := r64(g_ir_func_instr_start, fi * 8);
        count := r64(g_ir_func_instr_count, fi * 8);
        // Region list for this function (regions whose DFNode start falls in
        // this function's instruction range)
        ri : ., mut = 0;
        loop {
            if ri >= g_sg_count { break; }
            rkind := r64(g_sgs, ri * ESZ_SG + OFF_SG_KIND);
            rstart := r64(g_sgs, ri * ESZ_SG + OFF_SG_NSTART);
            rend := r64(g_sgs, ri * ESZ_SG + OFF_SG_EXIT);
            if rstart >= start && rstart < start + count {
                rend := r64(g_sgs, ri * ESZ_SG + OFF_SG_EXIT);
                if rend >= 0 {  // skip unclosed (EXIT<0) regions
                    rname : ., mut = "?";
                    if rkind == SG_FUNC   { rname = "func"; }
                    if rkind == SG_IF     { rname = "if"; }
                    if rkind == SG_LOOP   { rname = "loop"; }
                    if rkind == SG_FOR    { rname = "for"; }
                    if rkind == SG_FLOW   { rname = "flow"; }
                    if rkind == SG_UNSAFE { rname = "unsafe"; }
                    dump_buf_append("  Region: "); dump_buf_append(rname);
                    dump_buf_append(" nodes "); dump_buf_append(int_str(rstart));
                    dump_buf_append(".."); dump_buf_append(int_str(rend)); dump_buf_append("\n");
                }
            }
            ri = ri + 1;
        }
        in_block : ., mut = 0;
        ii : ., mut = 0;
        loop {
            if ii >= count { break; }
            if iri_op(start + ii) == IR_LABEL {
                if in_block != 0 { dump_buf_append("\n"); }
                dump_buf_append("  Block: label"); dump_buf_append(int_str(iri_s1(start + ii))); dump_buf_append("\n");
                in_block = 1;
            } else {
                dump_buf_append("    "); dump_buf_append(ir_instr_str(start + ii)); dump_buf_append("\n");
            }
            ii = ii + 1;
        }
        dump_buf_append("\n");
        fi = fi + 1;
    }

    // VSDG state edges: side-effect chain + loop termination dependencies
    dump_buf_append("State edges:\n");
    ei : ., mut = 0;
    loop {
        if ei >= g_df_edge_count { break; }
        if r64(g_df_edges, ei * ESZ_DFEDGE + OFF_DFE_KIND) != 0 {
            e_from := r64(g_df_edges, ei * ESZ_DFEDGE + OFF_DFE_FROM);
            e_to := r64(g_df_edges, ei * ESZ_DFEDGE + OFF_DFE_TO);
            dump_buf_append("  state: n"); dump_buf_append(int_str(e_from));
            dump_buf_append(" -> n"); dump_buf_append(int_str(e_to)); dump_buf_append("\n");
        }
        ei = ei + 1;
    }
    return dump_buf_finish();
}

// ─── R2 P5 Task 2 测试通道（corec 侧 hidden flag `cir --dump-tk-terms`）───
// 用途 = 单槽化的**逐节点**观察面：两槽（OFF_DF_TK = 类型项引用、OFF_DF_AUX = 辅码）
// + **派生码**（sh_dfn_code_of_slots——与 iri_tk / .ccr NOD / .cir 盘记录同源）+ 项结构
// （tag/a/b/c，直读 g_type_terms）——冷路径（emit 填槽）与暖路径（`.cir` 快照读回 +
// 重派生）两态用同一通道 dump 后逐行对拍。`tk` 列 = 派生码 ⇒ 与单槽化前同名通道的
// `tk` 列**逐字节可比**（D22-① 的直方图判据就建在这上面）。
// 只读：不改任何全局、不产产物（与 --dump-types/--dump-ifaces 同纪律）。
// 行格式（制表分隔；头行含计数与越界项计数）：
//   [df-tk-terms] nodes=N with_term=M bad_term=B aux_nonzero=A face_fail=F terms=K rows=R mint=1,2,4,6,10,49,50
//   <node>\t<opcode>\t<tk>\t<term>\t<tag>\t<a>\t<b>\t<c>\t<aux>
// term < 0（无项）或项行号越出项表（bad_term，跨进程索引空间分歧的暴露面——不得
// 静默读越界内存）：tag/a/b/c 一律 -1。aux_nonzero = 辅码非零节点数（互斥不变量
// D22-② 的观察面）；face_fail = D23 建项失败计数（0 = 全语料无不可译类型面行）；
// rows = 当前进程类型表行数（冷/暖比对用：暖态可小于冷态——见 sh_tk_split_load 注）。
fn df_tk_term_dump() -> string {
    dump_buf_reset();
    total := g_df_node_count;
    with_term : ., mut = 0;
    bad_term : ., mut = 0;
    auxn : ., mut = 0;
    n0 : ., mut = 0;
    loop {
        if n0 >= total { break; }
        t0 := r64(g_df_nodes, n0 * ESZ_DFNODE + OFF_DF_TK);
        if t0 >= 0 { with_term = with_term + 1; }
        if t0 >= tt_count() { bad_term = bad_term + 1; }
        if r64(g_df_nodes, n0 * ESZ_DFNODE + OFF_DF_AUX) != 0 { auxn = auxn + 1; }
        n0 = n0 + 1;
    }
    dump_buf_append("[df-tk-terms] nodes=");
    dump_buf_append(int_str(total));
    dump_buf_append(" with_term=");
    dump_buf_append(int_str(with_term));
    dump_buf_append(" bad_term=");
    dump_buf_append(int_str(bad_term));
    dump_buf_append(" aux_nonzero=");
    dump_buf_append(int_str(auxn));
    dump_buf_append(" face_fail=");
    dump_buf_append(int_str(g_tk_face_fail));
    dump_buf_append(" terms=");
    dump_buf_append(int_str(tt_count()));
    dump_buf_append(" rows=");
    dump_buf_append(int_str(g_type_count));
    dump_buf_append(" mint=");
    dump_buf_append(int_str(IR_CONST));
    dump_buf_append(",");
    dump_buf_append(int_str(IR_BINARY));
    dump_buf_append(",");
    dump_buf_append(int_str(IR_ALLOC));
    dump_buf_append(",");
    dump_buf_append(int_str(IR_CALL));
    dump_buf_append(",");
    dump_buf_append(int_str(IR_LOAD));
    dump_buf_append(",");
    dump_buf_append(int_str(IR_I2F));
    dump_buf_append(",");
    dump_buf_append(int_str(IR_F2I));
    dump_buf_append("\n");
    n : ., mut = 0;
    loop {
        if n >= total { break; }
        op := r64(g_df_nodes, n * ESZ_DFNODE + OFF_DF_OPCODE);
        t := r64(g_df_nodes, n * ESZ_DFNODE + OFF_DF_TK);
        ax := r64(g_df_nodes, n * ESZ_DFNODE + OFF_DF_AUX);
        tk := sh_dfn_code_of_slots(t, ax);
        dump_buf_append(int_str(n));
        dump_buf_append("\t");
        dump_buf_append(int_str(op));
        dump_buf_append("\t");
        dump_buf_append(int_str(tk));
        dump_buf_append("\t");
        dump_buf_append(int_str(t));
        dump_buf_append("\t");
        if t >= 0 && t < tt_count() {
            dump_buf_append(int_str(tt_tag(t)));
            dump_buf_append("\t");
            dump_buf_append(int_str(tt_a(t)));
            dump_buf_append("\t");
            dump_buf_append(int_str(tt_b(t)));
            dump_buf_append("\t");
            dump_buf_append(int_str(tt_c(t)));
        } else {
            dump_buf_append("-1\t-1\t-1\t-1");
        }
        dump_buf_append("\t");
        dump_buf_append(int_str(ax));
        dump_buf_append("\n");
        n = n + 1;
    }
    return dump_buf_finish();
}

fn cmd_cir(src_path: string) -> int {
    g_source = read_file(src_path);
    if str_len(g_source) == 0 {
        print("error: cannot read ");
        println(src_path);
        return 1;
    }
    g_source_dir = dirname(src_path);
    g_error_count = 0;  // 会话起点（tokenize 多轮累积词法错误，见 lexer.cr）
    tokenize(g_source);
    g_str_count = 0;
    res_imports();
    parse_all();
    check_all();
    if g_diag_count > 0 { print_diagnostics(); return 1; }
    if g_error_count > 0 { print_parse_errors(); return 1; }
    ir_gen_all();
    lower_to_ccr();

    ccr : ., mut = cir_text_dump();

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

// ─── 批 6（T4）：规约标注的 VC 清单 dump（`--dump-vcs`）──────────────────────────
// 表达式**规范化文本**（只服务 dump；**不参与判定**——判定面在 checker.cr 的 spec_check_all/spec_check_func）。
// C1 子集：int/bool 字面量 · 标识符 · 一元 `-`/`!` · 二元（算术/比较/逻辑）· 括号（显式加括号 ⇒ 无歧义）。
// 子集外节点形 ⇒ `(?)` 兜底（由 V05/V06 在检查面拦截，不在此处判）。
fn spec_expr_text(e: int) -> string {
    if e < 0 { return "?"; }
    k := ast_kind(e);
    if k == EXPR_INT { return int_str(ast_int_val(e)); }
    if k == EXPR_BOOL { if ast_int_val(e) != 0 { return "true"; } return "false"; }
    if k == EXPR_IDENT { return istr_get(ast_int_val(e)); }
    if k == EXPR_UNARY {
        op := ast_c(e);
        if op == UOP_NEG { return "(-" + spec_expr_text(ast_a(e)) + ")"; }
        if op == UOP_NOT { return "!" + spec_expr_text(ast_a(e)); }
        return "(?)";
    }
    if k == EXPR_BINARY {
        return "(" + spec_expr_text(ast_a(e)) + " " + binop_name(ast_c(e)) + " " + spec_expr_text(ast_b(e)) + ")";
    }
    return "(?)";
}

// VC 清单 dump（隐藏通道 `--dump-vcs`；维护者 2026-09-17 四点钉死）：
//   ① **stdout、零新产物**；开关**不改 rc/产物**（只打印）。
//   ② 三态**分流**：红走诊断通道（V01/V04/V05/V06 ⇒ rc=1 + 定位），绿/黄进本通道。
//   ③ **红也列**（`status=red`）——「**没列出来**」与「**列出来是红的**」必须可区分，**不得静默省略**；
//      且本 dump 打印点位于 `main.cr::run_frontend` 的 **fail-closed 闸门之前** ⇒ 红态下也照样列出。
//   ④ **只读侧表**（`g_spec_*`，与判定同源）——不另起一份状态，杜绝「dump 与判定分叉」（第二真源）。
// 序 = 侧表序 = **源序**（构造性确定）；且与 `.cir` 缓存状态**无关**（dump 全在 parse/check 期算）⇒ 冷/暖恒同。
fn vcs_dump() -> string {
    dump_buf_reset();
    dump_buf_append("[vcs] count=");
    dump_buf_append(int_str(g_spec_count));
    dump_buf_append("\n");
    i : ., mut = 0;
    loop {
        if i >= g_spec_count { break; }
        st : ., mut = "yellow";
        s := spec_status(i);
        if s == SPEC_ST_GREEN { st = "green"; }
        else if s == SPEC_ST_RED { st = "red"; }
        kn : ., mut = "check";
        if spec_kind(i) == 1 { kn = "ensure"; }
        dump_buf_append("[vcs] vc ");
        dump_buf_append(int_str(i));
        dump_buf_append(" fn=");
        dump_buf_append(istr_get(spec_fn(i)));
        dump_buf_append(" kind=");
        dump_buf_append(kn);
        dump_buf_append(" status=");
        dump_buf_append(st);
        dump_buf_append(" line=");
        dump_buf_append(int_str(spec_line(i)));
        dump_buf_append(" col=");
        dump_buf_append(int_str(spec_col(i)));
        dump_buf_append(" expr=");
        dump_buf_append(spec_expr_text(spec_expr(i)));
        dump_buf_append("\n");
        i = i + 1;
    }
    return dump_buf_finish();
}
