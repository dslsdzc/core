// === analysis.cr ===
// hover + go-to-definition：位置 → 令牌 → 符号表查询（Task 4）。
//
// 查询基于「最后一次成功检查」的快照（g_tokens / g_funcs / g_structs /
// g_enums / g_ast / g_types / g_files / g_seg_starts / g_seg_fileids /
// g_line_fileid / g_source），不触发检查、不修改前端状态。
//
// ── 坐标约定 ──
//   入口 line/col 为 LSP 0-based；g_tokens / AST 节点 / g_line_fileid 均
//   为 1-based，函数内部转换（+1 / -1）。
//
// ── 声明位置反查（执行时确认的路径）──
//   函数    —— fi_ast_node(fi) → EXPR_FN 节点 line/col（fn 关键字位置）。
//   结构体/枚举 —— g_ast 中【没有】声明节点（parser 的 struct/enum 分支只填
//   g_structs/g_enums 表，不 alloc_node）——brief 的「AST 顶层节点按名字
//   反查」路径不存在，改为扫 g_tokens：T_STRUCT/T_ENUM 关键字后紧跟同名
//   T_IDENT 令牌，取其 line/col。
//   局部变量 —— g_syms 在 check_all 后作用域已弹出（只剩顶层符号），改用
//   扫 g_ast：查同名的 EXPR_LET/EXPR_PARAM/EXPR_FOR 节点，取查询位置之前
//   最近的一个（近似块作用域）。
//
// ── 跨文件 ──
//   声明行 → g_line_fileid（拼接坐标行 → file_id）→ g_files 路径表；
//   行号减所在段的行偏移（g_seg_starts 字节偏移 + g_source 换行计数）还原
//   为目标文件自身坐标。主文件段 0 偏移为 0（LSP 文档行号与令牌行号一致——
//   res_imports 末尾会剥除 _import.cr 前导并重新 tokenize）。
//
// 注意（Python bootstrap 地雷）：所有字符串拼接走字面量初始化的累加器；
// 不引入名为 match 的变量（保留字 SIGSEGV）。

// ── 类型名（快照只读，不调 res_type_node——那会分配类型条目）──

// TY_* 常量 → 名字
fn analysis_tyname(ty: int) -> string {
    if ty == TY_INT { return "int"; }
    if ty == TY_DEX { return "dex"; }
    if ty == TY_BOOL { return "bool"; }
    if ty == TY_STRING { return "string"; }
    if ty == TY_UNIT { return "unit"; }
    if ty == TY_NEVER { return "never"; }
    if ty == TY_CHAR { return "char"; }
    if ty == TI_DYN { return "dyn"; }
    return "?";
}

// 类型表索引 → 名字（TYP_BASE / TYP_NAMED / TYP_REF / TYP_PTR / TYP_SLICE /
// TYP_ARRAY / TYP_GENERIC_APPLY / TYP_GENERIC_PARAM / TYP_TUPLE）
fn analysis_type_name_ti(ti: int) -> string {
    k := get_type_kind(ti);
    if k < 0 { return "?"; }
    if k == TYP_BASE { return analysis_tyname(get_type_data(ti)); }
    if k == TYP_NAMED || k == TYP_GENERIC_PARAM { return istr_get(get_type_data(ti)); }
    if k == TYP_REF {
        out : string, mut = "&";
        if get_type_extra(ti) != 0 { out = out + "mut "; }
        out = out + analysis_type_name_ti(get_type_data(ti));
        return out;
    }
    if k == TYP_PTR {
        out : string, mut = "*";
        out = out + analysis_type_name_ti(get_type_data(ti));
        return out;
    }
    if k == TYP_SLICE {
        out : string, mut = "[]";
        out = out + analysis_type_name_ti(get_type_data(ti));
        return out;
    }
    if k == TYP_ARRAY {
        out : string, mut = analysis_type_name_ti(get_type_data(ti));
        out = out + "[";
        out = out + int_str(get_type_extra(ti));
        out = out + "]";
        return out;
    }
    if k == TYP_GENERIC_APPLY {
        return analysis_type_name_ti(get_type_data(ti));
    }
    if k == TYP_TUPLE {
        cnt := get_type_data(ti);
        out : string, mut = "(";
        e : ., mut = 0;
        loop {
            if e >= cnt { break; }
            if e > 0 { out = out + ", "; }
            out = out + analysis_type_name_ti(r64(g_gen_apply_data, (get_type_extra(ti) + e) * 8));
            e = e + 1;
        }
        out = out + ")";
        return out;
    }
    return "?";
}

// AST 类型节点 → 名字（快照只读；depth 防深链失控）
fn analysis_type_node_name(node: int, depth: int) -> string {
    if node < 0 || node >= g_ast_count || depth > 8 { return "?"; }
    k := ast_kind(node);
    if k == 0 { return analysis_tyname(ast_type_val(node)); }
    if k == EXPR_IDENT { return istr_get(ast_int_val(node)); }
    if k == EXPR_REFTYPE {
        out : string, mut = "&";
        if ast_data(node) != 0 { out = out + "mut "; }
        out = out + analysis_type_node_name(ast_a(node), depth + 1);
        return out;
    }
    if k == EXPR_PTRTYPE {
        out : string, mut = "*";
        out = out + analysis_type_node_name(ast_a(node), depth + 1);
        return out;
    }
    if k == EXPR_OPTIONAL {
        // R2 P3 Task 4：`T?` 的悬停/补全显示（内层名 + "?"）
        out : string, mut = "";
        out = out + analysis_type_node_name(ast_a(node), depth + 1);
        out = out + "?";
        return out;
    }
    if k == EXPR_ARRAY {
        out : string, mut = "[";
        out = out + analysis_type_node_name(ast_a(node), depth + 1);
        if ast_int_val(node) != 0 {
            out = out + ";";
            out = out + int_str(ast_int_val(node));
        }
        out = out + "]";
        return out;
    }
    if k == EXPR_GENERIC_APPLY {
        out : string, mut = istr_get(ast_a(node));
        out = out + "<";
        ac : ., mut = 0;
        an : ., mut = ast_b(node);
        loop {
            if ac >= ast_c(node) { break; }
            if ac > 0 { out = out + ", "; }
            out = out + analysis_type_node_name(an, depth + 1);
            ac = ac + 1;
            an = an + 1;
        }
        out = out + ">";
        return out;
    }
    return "?";
}

// ── 令牌定位 ──

// 扫 g_tokens 找覆盖 (line, col)（0-based，col 为 UTF-16 code units）的令牌，
// 返回令牌索引；无则 -1。源码 lexer 的列按字节记录，定位时先转换回字节。
fn analysis_token_at(line: int, col: int) -> int {
    if line < 0 || col < 0 { return -1; }
    tl : ., mut = line + 1;
    line_start := analysis_line_start(line);
    cursor := analysis_pos_of(line, col);
    tc : ., mut = cursor - line_start + 1;
    i : ., mut = 0;
    loop {
        if i >= g_token_count { return -1; }
        if r64(g_tokens, i * ESZ_TOKEN + OFF_TK_KIND) == T_EOF { return -1; }
        if r64(g_tokens, i * ESZ_TOKEN + OFF_TK_LINE) == tl {
            cl := r64(g_tokens, i * ESZ_TOKEN + OFF_TK_COL);
            lex := r64(g_tokens, i * ESZ_TOKEN + OFF_TK_LEXEME);
            w : ., mut = 1;
            if lex >= 0 { w = str_len(istr_get(lex)); }
            if tc >= cl && tc < cl + w { return i; }
        }
        i = i + 1;
    }
}

// Return the byte offset of a zero-based source line.
fn analysis_line_start(line: int) -> int {
    if line <= 0 { return 0; }
    sl := str_len(g_source);
    current : ., mut = 0;
    i : ., mut = 0;
    loop {
        if i >= sl { return sl; }
        if load8(g_source, i) == 10 {
            current = current + 1;
            i = i + 1;
            if current >= line { return i; }
        } else { i = i + 1; }
    }
    return sl;
}

// Decode one UTF-8 sequence from g_source. Invalid bytes occupy one unit.
fn analysis_utf8_next(pos: int, sl: int) -> int {
    if pos < 0 || pos >= sl { return 1; }
    b0 := load8(g_source, pos);
    if b0 < 128 { return 1; }
    if b0 < 224 && pos + 1 < sl {
        b1 := load8(g_source, pos + 1);
        if b1 >= 128 && b1 < 192 { return 2; }
    }
    if b0 < 240 && pos + 2 < sl {
        b1 := load8(g_source, pos + 1);
        b2 := load8(g_source, pos + 2);
        if b1 >= 128 && b1 < 192 && b2 >= 128 && b2 < 192 { return 3; }
    }
    if b0 >= 240 && b0 < 248 && pos + 3 < sl {
        b1 := load8(g_source, pos + 1);
        b2 := load8(g_source, pos + 2);
        b3 := load8(g_source, pos + 3);
        if b1 >= 128 && b1 < 192 && b2 >= 128 && b2 < 192 && b3 >= 128 && b3 < 192 { return 4; }
    }
    return 1;
}

fn analysis_utf8_cp(pos: int, adv: int) -> int {
    b0 := load8(g_source, pos);
    if adv == 1 { return b0; }
    if adv == 2 { return (b0 - 192) * 64 + load8(g_source, pos + 1) - 128; }
    if adv == 3 { return (b0 - 224) * 4096 + (load8(g_source, pos + 1) - 128) * 64 + load8(g_source, pos + 2) - 128; }
    return (b0 - 240) * 262144 + (load8(g_source, pos + 1) - 128) * 4096 + (load8(g_source, pos + 2) - 128) * 64 + load8(g_source, pos + 3) - 128;
}

fn analysis_utf16_units(start: int, end: int) -> int {
    sl := str_len(g_source);
    p : ., mut = start;
    units : ., mut = 0;
    loop {
        if p >= end || p >= sl { break; }
        adv := analysis_utf8_next(p, sl);
        if p + adv > end { adv = 1; }
        cp := analysis_utf8_cp(p, adv);
        if cp >= 65536 { units = units + 2; } else { units = units + 1; }
        p = p + adv;
    }
    return units;
}

fn analysis_source_byte(pos: int, sl: int) -> int {
    if pos < 0 || pos >= sl { return -1; }
    return load8(g_source, pos);
}

// ── 函数 hover ──

// EXPR_PARAM 节点 → 参数类型名
fn analysis_param_type_name(pn: int) -> string {
    tn := ast_data(pn);
    if tn >= 0 && tn < g_ast_count && ast_kind(tn) != 0 { return analysis_type_node_name(tn, 0); }
    return analysis_tyname(ast_type_val(pn));
}

// 函数返回类型名（EXPR_FN type_val 槽 = 返回类型节点；0 = 无 -> 声明）
fn analysis_fn_ret_name(fi: int) -> string {
    fn_node := fi_ast_node(fi);
    if fn_node >= 0 && fn_node < g_ast_count {
        tn := ast_type_val(fn_node);
        if tn >= 0 && tn < g_ast_count {
            if ast_kind(tn) != 0 { return analysis_type_node_name(tn, 0); }
            return analysis_tyname(ast_type_val(tn));
        }
    }
    return analysis_tyname(fi_return_type(fi));
}

// 函数签名："fn 名(参数类型, ...) -> 返回类型"
fn analysis_hover_fn(fi: int) -> string {
    out : string, mut = "fn ";
    out = out + istr_get(fi_name(fi));
    out = out + "(";
    first_param : ., mut = -1;
    param_count : ., mut = 0;
    fn_node := fi_ast_node(fi);
    if fn_node >= 0 && fn_node < g_ast_count {
        first_param = ast_b(fn_node);
        param_count = ast_c(fn_node);
    }
    pi : ., mut = 0;
    pn : ., mut = first_param;
    loop {
        if pi >= param_count { break; }
        if pn < 0 || pn >= g_ast_count { break; }
        if pi > 0 { out = out + ", "; }
        if ast_kind(pn) == EXPR_PARAM { out = out + analysis_param_type_name(pn); }
        pi = pi + 1;
        pn = pn + 1;
        // 参数节点不连续（类型节点插在中间）——顺延找下一个 EXPR_PARAM
        loop {
            if pn >= g_ast_count { break; }
            if ast_kind(pn) == EXPR_PARAM { break; }
            pn = pn + 1;
        }
    }
    out = out + ") -> ";
    out = out + analysis_fn_ret_name(fi);
    return out;
}

// 结构体 hover："struct 名 { 字段: 类型, ... }"
fn analysis_hover_struct(si: int) -> string {
    out : string, mut = "struct ";
    out = out + istr_get(si_name(si));
    out = out + " {";
    f : ., mut = 0;
    loop {
        if f >= si_field_count(si) { break; }
        out = out + " ";
        out = out + istr_get(si_field_name(si, f));
        out = out + ": ";
        tn := si_field_type_node(si, f);
        if tn >= 0 && tn < g_ast_count && ast_kind(tn) != 0 { out = out + analysis_type_node_name(tn, 0); }
        else { out = out + analysis_tyname(si_field_type(si, f)); }
        out = out + ",";
        f = f + 1;
    }
    out = out + " }";
    return out;
}

// 枚举 hover："enum 名 { 变体, ... }"
fn analysis_hover_enum(ei: int) -> string {
    out : string, mut = "enum ";
    out = out + istr_get(ei_name(ei));
    out = out + " {";
    v : ., mut = 0;
    loop {
        if v >= ei_variant_count(ei) { break; }
        out = out + " ";
        out = out + istr_get(ei_variant_name(ei, v));
        out = out + ",";
        v = v + 1;
    }
    out = out + " }";
    return out;
}

// ── 局部变量（AST 反查）──

// 查声明 name_ni 的 AST 节点：EXPR_LET（a=名）/ EXPR_PARAM（a=名）/
// EXPR_FOR（a=变量名）；取 (line, col) <= 查询位置（0-based 转 1-based）
// 中最近的一个（近似作用域）。无则 -1。
fn analysis_var_decl(name_ni: int, line: int, col: int) -> int {
    tl : ., mut = line + 1;
    tc := analysis_pos_of(line, col) - analysis_line_start(line) + 1;
    best : ., mut = -1;
    bl : ., mut = -1;
    bc : ., mut = -1;
    i : ., mut = 0;
    loop {
        if i >= g_ast_count { break; }
        k := ast_kind(i);
        if k == EXPR_LET || k == EXPR_PARAM || k == EXPR_FOR {
            if ast_a(i) == name_ni {
                ln := ast_line(i);
                cl := ast_col(i);
                if ln < tl || (ln == tl && cl <= tc) {
                    if ln > bl || (ln == bl && cl > bc) {
                        best = i;
                        bl = ln;
                        bc = cl;
                    }
                }
            }
        }
        i = i + 1;
    }
    return best;
}

// 声明节点 → 变量类型名
fn analysis_var_type(vd: int, depth: int) -> string {
    if vd < 0 || depth > 8 { return "?"; }
    k := ast_kind(vd);
    if k == EXPR_PARAM {
        return analysis_param_type_name(vd);
    }
    if k == EXPR_FOR { return "int"; }
    if k == EXPR_LET {
        tn := ast_b(vd);
        if tn >= 0 && tn < g_ast_count {
            if ast_kind(tn) != 0 { return analysis_type_node_name(tn, 0); }
            return analysis_tyname(ast_type_val(tn));
        }
        return analysis_type_of_expr(ast_c(vd), depth + 1);
    }
    return "?";
}

// 表达式 → 类型名（轻量恢复：字面量/调用/标识符转发/引用；depth 防环）
fn analysis_type_of_expr(node: int, depth: int) -> string {
    if node < 0 || depth > 8 { return "?"; }
    k := ast_kind(node);
    if k == EXPR_INT { return "int"; }
    if k == EXPR_DEX { return "dex"; }
    if k == EXPR_BOOL { return "bool"; }
    if k == EXPR_STRING { return "string"; }
    if k == EXPR_CHAR { return "char"; }
    if k == EXPR_CALL {
        f := ast_a(node);
        if f >= 0 && ast_kind(f) == EXPR_IDENT {
            fi := find_func(ast_int_val(f));
            if fi >= 0 { return analysis_fn_ret_name(fi); }
        }
        return "?";
    }
    if k == EXPR_IDENT {
        vd := analysis_var_decl(ast_int_val(node), ast_line(node) - 1, ast_col(node) - 1);
        if vd >= 0 { return analysis_var_type(vd, depth + 1); }
        return "?";
    }
    if k == EXPR_UNARY && ast_c(node) == UOP_REF {
        out : string, mut = "&";
        out = out + analysis_type_of_expr(ast_a(node), depth + 1);
        return out;
    }
    return "?";
}

// ── hover ──

// 位置 → hover 内容：函数签名 / 变量类型 / 结构体字段 / 枚举变体；无结果空串
fn analysis_hover(line: int, col: int) -> string {
    ti := analysis_token_at(line, col);
    if ti < 0 { return ""; }
    if r64(g_tokens, ti * ESZ_TOKEN + OFF_TK_KIND) != T_IDENT { return ""; }
    name_ni := r64(g_tokens, ti * ESZ_TOKEN + OFF_TK_LEXEME);
    // 局部变量/参数优先（遮蔽函数/类型名）
    vd := analysis_var_decl(name_ni, line, col);
    if vd >= 0 {
        t := analysis_var_type(vd, 0);
        if str_len(t) > 0 { return t; }
    }
    // 函数
    fi := find_func(name_ni);
    if fi >= 0 { return analysis_hover_fn(fi); }
    // 结构体
    si := find_struct_by_name(name_ni);
    if si >= 0 { return analysis_hover_struct(si); }
    // 枚举
    ei := find_enum(name_ni);
    if ei >= 0 { return analysis_hover_enum(ei); }
    return "";
}

// ── definition ──

// 扫 g_tokens 找声明关键字（T_STRUCT/T_ENUM）后紧跟同名 T_IDENT 的令牌；
// 返回该名字令牌索引，无则 -1（g_ast 无结构体/枚举声明节点，见文件头注）
fn analysis_decl_tok(kw: int, name_ni: int) -> int {
    i : ., mut = 0;
    loop {
        if i + 1 >= g_token_count { return -1; }
        if r64(g_tokens, i * ESZ_TOKEN + OFF_TK_KIND) == kw {
            if r64(g_tokens, (i + 1) * ESZ_TOKEN + OFF_TK_KIND) == T_IDENT &&
               r64(g_tokens, (i + 1) * ESZ_TOKEN + OFF_TK_LEXEME) == name_ni {
                return i + 1;
            }
        }
        i = i + 1;
    }
}

// 1-based 行 → 文件路径（g_line_fileid → file_id → g_files）；兜底主文件
fn analysis_path_for_line(ln1: int) -> string {
    fid : ., mut = -1;
    if ln1 >= 1 && ln1 - 1 < g_line_count { fid = r64(g_line_fileid, (ln1 - 1) * 8); }
    if fid < 0 && g_file_count > 0 { fid = r64(g_files, 0); }
    i : ., mut = 0;
    loop {
        if i >= g_file_count { break; }
        if r64(g_files, i * 16) == fid {
            p := load_str_ptr(g_files, i * 16 + 8);
            if str_len(p) > 0 { return p; }
        }
        i = i + 1;
    }
    return "";
}

// 1-based 行 → 所在段在主文件后的行偏移（拼接坐标 → 目标文件自身坐标）
fn analysis_line_offset(ln1: int) -> int {
    fid : ., mut = -1;
    if ln1 >= 1 && ln1 - 1 < g_line_count { fid = r64(g_line_fileid, (ln1 - 1) * 8); }
    if fid < 0 { return 0; }
    i : ., mut = 1;
    loop {
        if i >= g_seg_count { break; }
        if r64(g_seg_fileids, i * 8) == fid {
            limit := r64(g_seg_starts, i * 8);
            off_lines : ., mut = 0;
            pos : ., mut = 0;
            loop {
                if pos >= limit { break; }
                if load8(g_source, pos) == 10 { off_lines = off_lines + 1; }
                pos = pos + 1;
            }
            return off_lines;
        }
        i = i + 1;
    }
    return 0;   // 主文件（段 0）：偏移 0
}

// 声明位置（1-based 拼接坐标）→ Location JSON；行/列转 0-based + 段偏移还原。
// uri 经 lsp_json_escape_str 转义（lsp.cr，同翻译单元——concat 顺序无关）。
fn analysis_def_json(ln1: int, cl1: int) -> string {
    off := analysis_line_offset(ln1);
    line0 : ., mut = ln1 - 1 - off;
    line_start := analysis_line_start(ln1 - 1);
    decl_pos := line_start + cl1 - 1;
    col0 := analysis_utf16_units(line_start, decl_pos);
    uri : string, mut = "file://";
    uri = uri + analysis_path_for_line(ln1);
    out : string, mut = "{\"uri\":";
    out = out + lsp_json_escape_str(uri);
    out = out + ",\"range\":{\"start\":{\"line\":";
    out = out + int_str(line0);
    out = out + ",\"character\":";
    out = out + int_str(col0);
    out = out + "},\"end\":{\"line\":";
    out = out + int_str(line0);
    out = out + ",\"character\":";
    adv := analysis_utf8_next(decl_pos, str_len(g_source));
    out = out + int_str(analysis_utf16_units(line_start, decl_pos + adv));
    out = out + "}}}";
    return out;
}

// 位置 → Location JSON（{"uri","range"}）；无结果空串
fn analysis_definition(line: int, col: int) -> string {
    ti := analysis_token_at(line, col);
    if ti < 0 { return ""; }
    if r64(g_tokens, ti * ESZ_TOKEN + OFF_TK_KIND) != T_IDENT { return ""; }
    name_ni := r64(g_tokens, ti * ESZ_TOKEN + OFF_TK_LEXEME);
    // 局部变量/参数
    vd := analysis_var_decl(name_ni, line, col);
    if vd >= 0 { return analysis_def_json(ast_line(vd), ast_col(vd)); }
    // 函数
    fi := find_func(name_ni);
    if fi >= 0 {
        dfn := analysis_decl_tok(T_FN, name_ni);
        if dfn >= 0 {
            return analysis_def_json(r64(g_tokens, dfn * ESZ_TOKEN + OFF_TK_LINE),
                                     r64(g_tokens, dfn * ESZ_TOKEN + OFF_TK_COL));
        }
        return "";
    }
    // 结构体 / 枚举（令牌反查声明）
    if find_struct_by_name(name_ni) >= 0 {
        d := analysis_decl_tok(T_STRUCT, name_ni);
        if d >= 0 {
            return analysis_def_json(r64(g_tokens, d * ESZ_TOKEN + OFF_TK_LINE),
                                     r64(g_tokens, d * ESZ_TOKEN + OFF_TK_COL));
        }
    }
    if find_enum(name_ni) >= 0 {
        d := analysis_decl_tok(T_ENUM, name_ni);
        if d >= 0 {
            return analysis_def_json(r64(g_tokens, d * ESZ_TOKEN + OFF_TK_LINE),
                                     r64(g_tokens, d * ESZ_TOKEN + OFF_TK_COL));
        }
    }
    return "";
}

// ── completion（Task 5）──────────────────────────────────────
// 位置 → 前缀（光标前最近标识符；@ 后为 @ 内建上下文）→ 候选过滤 → JSON。
// 候选来源（唯一真源）：lexer.cr lookup_keyword() 关键字、checker.cr
// EXPR_AT 分发 14 个 @ 内建 + parser.cr @ffi、g_syms（函数/全局/类型）、
// g_funcs / g_structs / g_enums。kind 为 LSP CompletionItemKind 规范值
// （1-based）：Keyword=14 / Function=3 / Variable=6 / Struct=22 / Enum=13。
// （Task 5 brief 数字有误——23 实为 Event；终审按规范修正，客户端平移
// -1 得 VS Code 0-based 值。）
//
// 注意：前缀直接回扫快照 g_source（不依赖令牌——半截标识符不成令牌）；
// 与 hover/definition 同为「最后一次成功检查的快照」语义。

// (line, col)（0-based，col 为 UTF-16 code units）→ g_source 字节偏移。
// 光标落在 surrogate pair 中间时钳到该 code point 起点。
fn analysis_pos_of(line: int, col: int) -> int {
    sl := str_len(g_source);
    if line < 0 { return 0; }
    start := analysis_line_start(line);
    p : ., mut = start;
    units : ., mut = 0;
    want : ., mut = col;
    if want < 0 { want = 0; }
    loop {
        if p >= sl || load8(g_source, p) == 10 || units >= want { break; }
        adv := analysis_utf8_next(p, sl);
        cp := analysis_utf8_cp(p, adv);
        next_units : ., mut = 1;
        if cp >= 65536 { next_units = 2; }
        if units + next_units > want { break; }
        p = p + adv;
        units = units + next_units;
    }
    return p;
}

// pos 前连续标识符字符（字母/数字/_）的起点偏移
fn analysis_prefix_start(pos: int) -> int {
    s : ., mut = pos;
    loop {
        if s <= 0 { break; }
        if is_ident_char(load8(g_source, s - 1)) == 0 { break; }
        s = s - 1;
    }
    return s;
}

// g_source 字节段 → 稳定堆字符串（前缀是暂态字节范围，需复制）
fn analysis_sub_copy(start: int, end: int) -> string {
    n := end - start;
    s := alloc(n + 1);
    i : ., mut = 0;
    loop {
        if i >= n { break; }
        store8(s, i, load8(g_source, start + i));
        i = i + 1;
    }
    store8(s, n, 0);
    return s;
}

// name 是否以 prefix 开头（空前缀恒真；大小写不敏感——LSP 惯例）
fn analysis_has_prefix(name: string, prefix: string) -> int {
    pl := str_len(prefix);
    if pl == 0 { return 1; }
    if str_len(name) < pl { return 0; }
    i : ., mut = 0;
    loop {
        if i >= pl { break; }
        nc := load8(name, i);
        pc := load8(prefix, i);
        if nc >= 65 && nc <= 90 { nc = nc + 32; }
        if pc >= 65 && pc <= 90 { pc = pc + 32; }
        if nc != pc { return 0; }
        i = i + 1;
    }
    return 1;
}

// 单条补全项 JSON：{"label":..., "kind":N}
fn analysis_citem(name: string, kind: int) -> string {
    out : string, mut = "{\"label\":";
    out = out + lsp_json_escape_str(name);
    out = out + ",\"kind\":";
    out = out + int_str(kind);
    out = out + "}";
    return out;
}

// 关键字候选 JSON（lexer.cr lookup_keyword() 字面量清单，唯一真源；kind=14）。
// 命中的项以逗号连接（无命中返回空串——调用方拼进 items 数组）。
fn analysis_kw_items(prefix: string) -> string {
    out : string, mut = "";
    first : ., mut = 1;
    if analysis_has_prefix("fn", prefix) != 0 { if first == 0 { out = out + ","; } out = out + analysis_citem("fn", 14); first = 0; }
    if analysis_has_prefix("mut", prefix) != 0 { if first == 0 { out = out + ","; } out = out + analysis_citem("mut", 14); first = 0; }
    if analysis_has_prefix("return", prefix) != 0 { if first == 0 { out = out + ","; } out = out + analysis_citem("return", 14); first = 0; }
    if analysis_has_prefix("if", prefix) != 0 { if first == 0 { out = out + ","; } out = out + analysis_citem("if", 14); first = 0; }
    if analysis_has_prefix("else", prefix) != 0 { if first == 0 { out = out + ","; } out = out + analysis_citem("else", 14); first = 0; }
    if analysis_has_prefix("loop", prefix) != 0 { if first == 0 { out = out + ","; } out = out + analysis_citem("loop", 14); first = 0; }
    if analysis_has_prefix("while", prefix) != 0 { if first == 0 { out = out + ","; } out = out + analysis_citem("while", 14); first = 0; }
    if analysis_has_prefix("for", prefix) != 0 { if first == 0 { out = out + ","; } out = out + analysis_citem("for", 14); first = 0; }
    if analysis_has_prefix("break", prefix) != 0 { if first == 0 { out = out + ","; } out = out + analysis_citem("break", 14); first = 0; }
    if analysis_has_prefix("continue", prefix) != 0 { if first == 0 { out = out + ","; } out = out + analysis_citem("continue", 14); first = 0; }
    if analysis_has_prefix("true", prefix) != 0 { if first == 0 { out = out + ","; } out = out + analysis_citem("true", 14); first = 0; }
    if analysis_has_prefix("false", prefix) != 0 { if first == 0 { out = out + ","; } out = out + analysis_citem("false", 14); first = 0; }
    if analysis_has_prefix("struct", prefix) != 0 { if first == 0 { out = out + ","; } out = out + analysis_citem("struct", 14); first = 0; }
    if analysis_has_prefix("enum", prefix) != 0 { if first == 0 { out = out + ","; } out = out + analysis_citem("enum", 14); first = 0; }
    if analysis_has_prefix("extern", prefix) != 0 { if first == 0 { out = out + ","; } out = out + analysis_citem("extern", 14); first = 0; }
    if analysis_has_prefix("impl", prefix) != 0 { if first == 0 { out = out + ","; } out = out + analysis_citem("impl", 14); first = 0; }
    if analysis_has_prefix("match", prefix) != 0 { if first == 0 { out = out + ","; } out = out + analysis_citem("match", 14); first = 0; }
    if analysis_has_prefix("import", prefix) != 0 { if first == 0 { out = out + ","; } out = out + analysis_citem("import", 14); first = 0; }
    if analysis_has_prefix("pub", prefix) != 0 { if first == 0 { out = out + ","; } out = out + analysis_citem("pub", 14); first = 0; }
    if analysis_has_prefix("go", prefix) != 0 { if first == 0 { out = out + ","; } out = out + analysis_citem("go", 14); first = 0; }
    if analysis_has_prefix("await", prefix) != 0 { if first == 0 { out = out + ","; } out = out + analysis_citem("await", 14); first = 0; }
    if analysis_has_prefix("unsafe", prefix) != 0 { if first == 0 { out = out + ","; } out = out + analysis_citem("unsafe", 14); first = 0; }
    if analysis_has_prefix("flow", prefix) != 0 { if first == 0 { out = out + ","; } out = out + analysis_citem("flow", 14); first = 0; }
    if analysis_has_prefix("yield", prefix) != 0 { if first == 0 { out = out + ","; } out = out + analysis_citem("yield", 14); first = 0; }
    if analysis_has_prefix("interface", prefix) != 0 { if first == 0 { out = out + ","; } out = out + analysis_citem("interface", 14); first = 0; }
    if analysis_has_prefix("type", prefix) != 0 { if first == 0 { out = out + ","; } out = out + analysis_citem("type", 14); first = 0; }
    if analysis_has_prefix("mod", prefix) != 0 { if first == 0 { out = out + ","; } out = out + analysis_citem("mod", 14); first = 0; }
    if analysis_has_prefix("as", prefix) != 0 { if first == 0 { out = out + ","; } out = out + analysis_citem("as", 14); first = 0; }
    if analysis_has_prefix("auto", prefix) != 0 { if first == 0 { out = out + ","; } out = out + analysis_citem("auto", 14); first = 0; }
    if analysis_has_prefix("fileid", prefix) != 0 { if first == 0 { out = out + ","; } out = out + analysis_citem("fileid", 14); first = 0; }
    if analysis_has_prefix("move", prefix) != 0 { if first == 0 { out = out + ","; } out = out + analysis_citem("move", 14); first = 0; }
    if analysis_has_prefix("in", prefix) != 0 { if first == 0 { out = out + ","; } out = out + analysis_citem("in", 14); first = 0; }
    if analysis_has_prefix("None", prefix) != 0 { if first == 0 { out = out + ","; } out = out + analysis_citem("None", 14); first = 0; }
    if analysis_has_prefix("Some", prefix) != 0 { if first == 0 { out = out + ","; } out = out + analysis_citem("Some", 14); first = 0; }
    if analysis_has_prefix("unit", prefix) != 0 { if first == 0 { out = out + ","; } out = out + analysis_citem("unit", 14); first = 0; }
    return out;
}

// @ 内建候选 JSON（checker.cr EXPR_AT 分发 14 个 + parser.cr @ffi，唯一真源；
// kind=3 Function——均以内建函数方式调用）。label 不含 '@'。
fn analysis_at_items(prefix: string) -> string {
    out : string, mut = "";
    first : ., mut = 1;
    if analysis_has_prefix("sizeOf", prefix) != 0 { if first == 0 { out = out + ","; } out = out + analysis_citem("sizeOf", 3); first = 0; }
    if analysis_has_prefix("addr", prefix) != 0 { if first == 0 { out = out + ","; } out = out + analysis_citem("addr", 3); first = 0; }
    if analysis_has_prefix("alignOf", prefix) != 0 { if first == 0 { out = out + ","; } out = out + analysis_citem("alignOf", 3); first = 0; }
    if analysis_has_prefix("fields", prefix) != 0 { if first == 0 { out = out + ","; } out = out + analysis_citem("fields", 3); first = 0; }
    if analysis_has_prefix("hasField", prefix) != 0 { if first == 0 { out = out + ","; } out = out + analysis_citem("hasField", 3); first = 0; }
    if analysis_has_prefix("field", prefix) != 0 { if first == 0 { out = out + ","; } out = out + analysis_citem("field", 3); first = 0; }
    if analysis_has_prefix("typeInfo", prefix) != 0 { if first == 0 { out = out + ","; } out = out + analysis_citem("typeInfo", 3); first = 0; }
    if analysis_has_prefix("raw_int", prefix) != 0 { if first == 0 { out = out + ","; } out = out + analysis_citem("raw_int", 3); first = 0; }
    if analysis_has_prefix("comptime", prefix) != 0 { if first == 0 { out = out + ","; } out = out + analysis_citem("comptime", 3); first = 0; }
    if analysis_has_prefix("inline", prefix) != 0 { if first == 0 { out = out + ","; } out = out + analysis_citem("inline", 3); first = 0; }
    if analysis_has_prefix("NoBoundsCheck", prefix) != 0 { if first == 0 { out = out + ","; } out = out + analysis_citem("NoBoundsCheck", 3); first = 0; }
    if analysis_has_prefix("fast", prefix) != 0 { if first == 0 { out = out + ","; } out = out + analysis_citem("fast", 3); first = 0; }
    if analysis_has_prefix("unroll", prefix) != 0 { if first == 0 { out = out + ","; } out = out + analysis_citem("unroll", 3); first = 0; }
    if analysis_has_prefix("section", prefix) != 0 { if first == 0 { out = out + ","; } out = out + analysis_citem("section", 3); first = 0; }
    if analysis_has_prefix("hotpatch", prefix) != 0 { if first == 0 { out = out + ","; } out = out + analysis_citem("hotpatch", 3); first = 0; }
    if analysis_has_prefix("ffi", prefix) != 0 { if first == 0 { out = out + ","; } out = out + analysis_citem("ffi", 3); first = 0; }
    return out;
}

// 候选缓冲追加（去重：str_intern 保证同名同 name_ni）；已存在返回 0
fn analysis_cand_add(cand: string, count: int, ni: int, kind: int) -> int {
    i : ., mut = 0;
    loop {
        if i >= count { break; }
        if r64(cand, i * 16) == ni { return 0; }
        i = i + 1;
    }
    w64(cand, count * 16, ni);
    w64(cand, count * 16 + 8, kind);
    return 1;
}

// SYM_* 种类 → CompletionItemKind 规范值（FN/SO_FN→3 函数、
// GLOBAL/LOCAL/PARAM→6 变量、TYPE→22 结构体、MODULE→9 模块）
fn analysis_sym_item_kind(sk: int) -> int {
    if sk == SYM_FN || sk == SYM_SO_FN { return 3; }
    if sk == SYM_GLOBAL || sk == SYM_LOCAL || sk == SYM_PARAM { return 6; }
    if sk == SYM_TYPE { return 22; }
    return 9;
}

// 位置 → completion JSON {"items":[...]}（快照查询，不触发检查）
fn analysis_completion(line: int, col: int) -> string {
    pos := analysis_pos_of(line, col);
    pstart := analysis_prefix_start(pos);
    at_ctx : ., mut = 0;
    if pstart > 0 && load8(g_source, pstart - 1) == 64 { at_ctx = 1; }
    prefix := analysis_sub_copy(pstart, pos);
    out : string, mut = "{\"items\":[";
    if at_ctx != 0 {
        out = out + analysis_at_items(prefix);
    } else {
        out = out + analysis_kw_items(prefix);
        // 符号候选：g_syms（check_all 后剩顶层：函数/全局/类型/内建）
        // + g_funcs + g_structs + g_enums（按候选总数精确分配，无需扩容）
        total := g_sym_count + g_func_count + g_struct_count + g_enum_count;
        if total < 1 { total = 1; }   // 防 alloc(0)
        cand : string, mut = alloc(total * 16);
        cnt : ., mut = 0;
        i : ., mut = 0;
        loop {
            if i >= g_sym_count { break; }
            kk : ., mut = analysis_sym_item_kind(sym_kind(i));
            // SYM_TYPE 混装结构体/枚举/接口（collect_decls 统一注册）——
            // 枚举按名字区分（g_enums 快照），发 Enum=13；否则按结构体 22
            if sym_kind(i) == SYM_TYPE && find_enum(sym_name(i)) >= 0 { kk = 13; }
            cnt = cnt + analysis_cand_add(cand, cnt, sym_name(i), kk);
            i = i + 1;
        }
        i = 0;
        loop {
            if i >= g_func_count { break; }
            cnt = cnt + analysis_cand_add(cand, cnt, fi_name(i), 3);
            i = i + 1;
        }
        i = 0;
        loop {
            if i >= g_struct_count { break; }
            cnt = cnt + analysis_cand_add(cand, cnt, si_name(i), 22);   // Struct
            i = i + 1;
        }
        i = 0;
        loop {
            if i >= g_enum_count { break; }
            cnt = cnt + analysis_cand_add(cand, cnt, ei_name(i), 13);   // Enum
            i = i + 1;
        }
        j : ., mut = 0;
        loop {
            if j >= cnt { break; }
            ni := r64(cand, j * 16);
            if analysis_has_prefix(istr_get(ni), prefix) != 0 {
                if str_len(out) > 10 { out = out + ","; }
                out = out + analysis_citem(istr_get(ni), r64(cand, j * 16 + 8));
            }
            j = j + 1;
        }
    }
    out = out + "]}";
    return out;
}

// ── documentSymbol（Task 5）────────────────────────────────────
// 顶层符号 JSON 数组。g_ast 无 STRUCT_DEF/ENUM_DEF 声明节点（Task 4 已确认），
// 故：函数经 g_funcs → fi_ast_node（EXPR_FN/EXPR_EXTERN 节点 line/col）；
// 结构体/枚举经 g_structs/g_enums → 令牌反查 T_STRUCT/T_ENUM 声明
// （analysis_decl_tok，与 definition 同路径）。条目按 (line,col) 源顺序
// 插入排序输出。跨文件：仅主文件（段偏移 0）符号——LSP 文档即主文件。

// 1-based (line,col) → LSP range JSON（0-based 减 1，起点到名字后一字符）
fn analysis_range_json(ln1: int, cl1: int) -> string {
    line_start := analysis_line_start(ln1 - 1);
    start_pos := line_start + cl1 - 1;
    start_col := analysis_utf16_units(line_start, start_pos);
    adv := analysis_utf8_next(start_pos, str_len(g_source));
    end_col := analysis_utf16_units(line_start, start_pos + adv);
    out : string, mut = "{\"start\":{\"line\":";
    out = out + int_str(ln1 - 1);
    out = out + ",\"character\":";
    out = out + int_str(start_col);
    out = out + "},\"end\":{\"line\":";
    out = out + int_str(ln1 - 1);
    out = out + ",\"character\":";
    out = out + int_str(end_col);
    out = out + "}}";
    return out;
}

// 顶层符号 → JSON 数组（无符号 → "[]"）
fn analysis_document_symbol() -> string {
    total := g_func_count + g_struct_count + g_enum_count;
    if total <= 0 { return "[]"; }
    // 条目缓冲：{name_ni, kind, line(1-based), col(1-based)} = 32 字节
    ent : string, mut = alloc(total * 32);
    cnt : ., mut = 0;
    i : ., mut = 0;
    loop {
        if i >= g_func_count { break; }
        ni := fi_name(i);
        fn_node := fi_ast_node(i);
        ln : ., mut = 0; cl : ., mut = 0;
        if fn_node >= 0 && fn_node < g_ast_count { ln = ast_line(fn_node); cl = ast_col(fn_node); }
        if ln > 0 && analysis_line_offset(ln) == 0 {
            w64(ent, cnt * 32, ni);
            w64(ent, cnt * 32 + 8, 12);        // SymbolKind.Function = 12
            w64(ent, cnt * 32 + 16, ln);
            w64(ent, cnt * 32 + 24, cl);
            cnt = cnt + 1;
        }
        i = i + 1;
    }
    i = 0;
    loop {
        if i >= g_struct_count { break; }
        ni := si_name(i);
        d := analysis_decl_tok(T_STRUCT, ni);
        if d >= 0 {
            ln := r64(g_tokens, d * ESZ_TOKEN + OFF_TK_LINE);
            if analysis_line_offset(ln) == 0 {
                w64(ent, cnt * 32, ni);
                w64(ent, cnt * 32 + 8, 23);    // SymbolKind.Struct = 23
                w64(ent, cnt * 32 + 16, ln);
                w64(ent, cnt * 32 + 24, r64(g_tokens, d * ESZ_TOKEN + OFF_TK_COL));
                cnt = cnt + 1;
            }
        }
        i = i + 1;
    }
    i = 0;
    loop {
        if i >= g_enum_count { break; }
        ni := ei_name(i);
        d := analysis_decl_tok(T_ENUM, ni);
        if d >= 0 {
            ln := r64(g_tokens, d * ESZ_TOKEN + OFF_TK_LINE);
            if analysis_line_offset(ln) == 0 {
                w64(ent, cnt * 32, ni);
                w64(ent, cnt * 32 + 8, 10);    // SymbolKind.Enum = 10（LSP 规范；
                                               // Task 5 brief 误为 23）
                w64(ent, cnt * 32 + 16, ln);
                w64(ent, cnt * 32 + 24, r64(g_tokens, d * ESZ_TOKEN + OFF_TK_COL));
                cnt = cnt + 1;
            }
        }
        i = i + 1;
    }
    // 按 (line, col) 升序插入排序（源顺序输出）
    j : ., mut = 1;
    loop {
        if j >= cnt { break; }
        key_ni := r64(ent, j * 32);
        key_kind := r64(ent, j * 32 + 8);
        key_ln := r64(ent, j * 32 + 16);
        key_cl := r64(ent, j * 32 + 24);
        k : ., mut = j;
        loop {
            if k <= 0 { break; }
            pln := r64(ent, (k - 1) * 32 + 16);
            pcl := r64(ent, (k - 1) * 32 + 24);
            if pln < key_ln || (pln == key_ln && pcl <= key_cl) { break; }
            w64(ent, k * 32, r64(ent, (k - 1) * 32));
            w64(ent, k * 32 + 8, r64(ent, (k - 1) * 32 + 8));
            w64(ent, k * 32 + 16, pln);
            w64(ent, k * 32 + 24, pcl);
            k = k - 1;
        }
        w64(ent, k * 32, key_ni);
        w64(ent, k * 32 + 8, key_kind);
        w64(ent, k * 32 + 16, key_ln);
        w64(ent, k * 32 + 24, key_cl);
        j = j + 1;
    }
    out : string, mut = "[";
    q : ., mut = 0;
    loop {
        if q >= cnt { break; }
        if q > 0 { out = out + ","; }
        ni := r64(ent, q * 32);
        ln1 := r64(ent, q * 32 + 16);
        cl1 := r64(ent, q * 32 + 24);
        out = out + "{\"name\":";
        out = out + lsp_json_escape_str(istr_get(ni));
        out = out + ",\"kind\":";
        out = out + int_str(r64(ent, q * 32 + 8));
        out = out + ",\"range\":";
        out = out + analysis_range_json(ln1, cl1);
        out = out + ",\"selectionRange\":";
        out = out + analysis_range_json(ln1, cl1);
        out = out + ",\"children\":[]}";
        q = q + 1;
    }
    out = out + "]";
    return out;
}

// ── semanticTokens（Task 6）──────────────────────────────────
// 快照 g_tokens → LSP semanticTokens/full 的 data 差分编码（相对上一令牌
// 的 delta_line / delta_start / length / tokenType / tokenModifiers，每组 5
// 个整数，首令牌相对 (0,0)）。不触发检查（同 hover/definition 快照语义）。
//
// 范围：仅主文件（LSP 文档即主文件，与 documentSymbol 同约定）。res_imports
// 会把 stdlib/import 的文件拼接进 g_source（段 1 起），故用令牌起始字节偏移
// < g_seg_starts[1]（首段 = 主文件，段偏移即拼接坐标下的字节偏移）过滤。
//
// 令牌长度：不能取 lexeme——运算符与 int/float 字面量令牌的 lexeme = -1
// （lexer add_tok/add_tok_int），字符串令牌的 lexeme 是解码后的值（转义使
// 源长度 ≠ 词素长度）。正确长度 = 按 kind 从源文本扫描出的字节跨度
// （analysis_tok_span，逐一镜像 lexer 各分支的消耗规则——含运算符定长表）。
//
// 定位：单遍扫 g_source 求每个令牌的起始字节偏移（列按字节计——与 lexer
// skip_ws 的 g_col 口径一致；令牌按源顺序，跨行推进）。
//
// tokenType 映射表（token kind → legend 下标；legend 在 rpc.cr
// rpc_send_initialize 声明，顺序必须与这里一致）：
//   keyword  (0): T_FN T_MUT T_IF T_ELSE T_LOOP T_WHILE T_FOR T_IN
//                 T_RETURN T_BREAK T_CONTINUE T_STRUCT T_ENUM T_IMPL T_PUB
//                 T_TRUE T_FALSE T_MOVE T_SELF T_MATCH T_TYPE T_MOD
//                 T_IMPORT T_AS T_GO T_AWAIT T_FLOW T_YIELD T_UNSAFE
//                 T_INTERFACE T_AUTO T_FILEID T_NONE T_SOME T_EXTERN
//   type     (1): T_UNIT（unit 关键字令牌——parser 产 TY_UNIT）
//                 T_INT_TYPE..T_AUTO_TYPE
//                 T_REF T_DYN；以及 T_IDENT 且（内置类型名 int/float/
//                 bool/string/char/never/dyn——parser.cr parse_type
//                 T_IDENT 分支字面量清单，唯一真源——或 find_struct_by_
//                 name / find_enum 命中的结构体/枚举名）
//   function (2): T_IDENT 且 find_func 命中（g_funcs 快照）
//   variable (3): T_IDENT 兜底（局部/全局/参数/未知标识符）
//   comment  (4): 无令牌——lexer 完全跳过 // 与 /* */ 注释，该类保留仅
//                 为对齐 LSP legend（客户端按 legend 建主题）
//   string   (5): T_STRING T_CHAR
//   operator (6): T_LPAREN T_RPAREN T_LBRACE T_RBRACE T_COMMA T_SEMI
//                 T_COLON T_DOT T_ARROW T_EQ T_EQEQ T_BANG T_BANGEQ
//                 T_LT T_GT T_LTEQ T_GTEQ T_PLUS T_MINUS T_STAR
//                 T_SLASH T_ANDAND T_PIPEPIPE T_AMPERSAND T_UNDERSCORE
//                 T_PATHSEP T_LBRACKET T_RBRACKET T_FATARROW T_PERCENT
//                 T_DOTDOT T_DOTDOTDOT T_COLON_EQ T_AT T_QUESTION
//                 T_PLUS_EQ T_MINUS_EQ T_STAR_EQ T_SLASH_EQ
//   number   (7): T_INT T_DEX（字面量令牌）

// kind → legend 下标；T_IDENT 返回 -1（需按名字分类，见 analysis_token_type）
fn analysis_kind_type(k: int) -> int {
    if k == T_FN || k == T_MUT || k == T_IF || k == T_ELSE || k == T_LOOP ||
       k == T_WHILE || k == T_FOR || k == T_IN || k == T_RETURN ||
       k == T_BREAK ||
       k == T_CONTINUE || k == T_STRUCT || k == T_ENUM || k == T_IMPL ||
       k == T_PUB || k == T_TRUE || k == T_FALSE || k == T_MOVE ||
       k == T_SELF || k == T_MATCH || k == T_TYPE || k == T_MOD ||
       k == T_IMPORT || k == T_AS || k == T_GO || k == T_AWAIT ||
       k == T_FLOW || k == T_YIELD || k == T_UNSAFE || k == T_INTERFACE ||
       k == T_AUTO || k == T_FILEID || k == T_NONE || k == T_SOME ||
       k == T_EXTERN { return 0; }
    if k == T_UNIT || (k >= T_INT_TYPE && k <= T_AUTO_TYPE) ||
        k == T_REF || k == T_DYN {
        return 1;
    }
    if k == T_STRING || k == T_CHAR { return 5; }
    if k == T_INT || k == T_DEX { return 7; }
    if k == T_IDENT { return -1; }
    return 6;   // 运算符/分隔符：其余全部 kind
}

// 名字是否为内置类型名（parser.cr parse_type 的 T_IDENT 分支字面量清单）
fn analysis_is_builtin_type(ni: int) -> int {
    s := istr_get(ni);
    if str_eq(s, "int") != 0 || str_eq(s, "dex") != 0 ||
       str_eq(s, "bool") != 0 || str_eq(s, "string") != 0 ||
       str_eq(s, "char") != 0 || str_eq(s, "never") != 0 ||
       str_eq(s, "dyn") != 0 { return 1; }
    return 0;
}

// 令牌索引 → legend 下标（T_IDENT 按符号表/内置类型名分类）
fn analysis_token_type(ti: int) -> int {
    k := r64(g_tokens, ti * ESZ_TOKEN + OFF_TK_KIND);
    if k != T_IDENT { return analysis_kind_type(k); }
    ni := r64(g_tokens, ti * ESZ_TOKEN + OFF_TK_LEXEME);
    if analysis_is_builtin_type(ni) != 0 { return 1; }
    if find_func(ni) >= 0 { return 2; }
    if find_struct_by_name(ni) >= 0 { return 1; }
    if find_enum(ni) >= 0 { return 1; }
    return 3;
}

// 令牌索引 → 源文本字节跨度（从起始偏移 st 起按 kind 镜像 lexer 消耗规则）
fn analysis_tok_span(ti: int, st: int, sl: int) -> int {
    k := r64(g_tokens, ti * ESZ_TOKEN + OFF_TK_KIND);
    // 字符串/字符：开引号 → 未转义闭合引号（镜像 lexer：\x 转义 4 字节、
    // 插值 ${...} 跳至 '}' 并多吃一字节、换行终止未闭合串）。未闭合
    // 字符串末尾的反斜杠只能覆盖到源末，不能把 span 推出源缓冲区。
    if k == T_STRING || k == T_CHAR {
        q := analysis_source_byte(st, sl);
        p : ., mut = st + 1;
        loop {
            if p >= sl { break; }
            c := analysis_source_byte(p, sl);
            if c == 92 {
                if p + 1 >= sl { p = sl; break; }
                p = p + 2;
            }
            else if c == q { p = p + 1; break; }
            else if c == 10 { break; }
            else if c == 36 && analysis_source_byte(p + 1, sl) == 123 {
                p = p + 2;
                loop {
                    if p >= sl { break; }
                    if analysis_source_byte(p, sl) == 125 { p = p + 1; break; }
                    p = p + 1;
                }
                if p < sl { p = p + 1; }   // 镜像 lexer 循环尾 _pos+1
            }
            else { p = p + 1; }
        }
        return p - st;
    }
    // 数字：镜像 lexer 数字分支（'.' 起始、hex/oct/bin 前缀、小数、字母后缀）
    if k == T_INT || k == T_DEX {
        p : ., mut = st;
        if analysis_source_byte(p, sl) == 46 && is_digit(analysis_source_byte(p + 1, sl)) != 0 { p = p + 1; }
        loop { if is_digit(analysis_source_byte(p, sl)) != 0 { p = p + 1; } else { break; } }
        if p - st == 1 && load8(g_source, st) == 48 {
            nx := analysis_source_byte(p, sl);
            if nx == 120 || nx == 88 {
                p = p + 1;
                loop { hc := analysis_source_byte(p, sl); if is_digit(hc) != 0 || (hc >= 65 && hc <= 70) || (hc >= 97 && hc <= 102) { p = p + 1; } else { break; } }
            } else if nx == 111 || nx == 79 {
                p = p + 1;
                loop { oc := analysis_source_byte(p, sl); if oc >= 48 && oc <= 55 { p = p + 1; } else { break; } }
            } else if nx == 98 || nx == 66 {
                p = p + 1;
                loop { bc := analysis_source_byte(p, sl); if bc == 48 || bc == 49 { p = p + 1; } else { break; } }
            }
        }
        if analysis_source_byte(p, sl) == 46 && analysis_source_byte(p + 1, sl) != 46 {
            p = p + 1;
            loop { if is_digit(analysis_source_byte(p, sl)) != 0 { p = p + 1; } else { break; } }
        }
        loop { if is_alpha(analysis_source_byte(p, sl)) != 0 { p = p + 1; } else { break; } }
        return p - st;
    }
    // 标识符/关键字/类型关键字：lexeme 即源文本（add_tok_str）
    lex := r64(g_tokens, ti * ESZ_TOKEN + OFF_TK_LEXEME);
    if lex >= 0 { return str_len(istr_get(lex)); }
    // 运算符/分隔符（lexeme = -1）：lexer 定长表（其余单字符）
    if k == T_EQEQ || k == T_BANGEQ || k == T_LTEQ || k == T_GTEQ ||
       k == T_ANDAND || k == T_PIPEPIPE || k == T_ARROW || k == T_FATARROW ||
       k == T_COLON_EQ || k == T_PATHSEP || k == T_PLUS_EQ || k == T_MINUS_EQ ||
       k == T_STAR_EQ || k == T_SLASH_EQ || k == T_DOTDOT { return 2; }
    if k == T_DOTDOTDOT { return 3; }
    return 1;
}

// 令牌流（至 T_EOF 止）→ {"data":[...]} 差分编码 JSON；无令牌 → 空数组
fn analysis_semantic_tokens() -> string {
    // 实际令牌数（T_EOF 前）
    n : ., mut = 0;
    loop {
        if n >= g_token_count { break; }
        if r64(g_tokens, n * ESZ_TOKEN + OFF_TK_KIND) == T_EOF { break; }
        n = n + 1;
    }
    if n == 0 { return "{\"data\":[]}"; }
    // pass 1：令牌起始字节偏移（单遍扫 g_source；列按字节计，与 lexer 一致）
    offs : string, mut = alloc(n * 8);
    pos : ., mut = 0;
    ln : ., mut = 1;
    cl : ., mut = 1;
    sl := str_len(g_source);
    i : ., mut = 0;
    loop {
        if i >= n { break; }
        tline := r64(g_tokens, i * ESZ_TOKEN + OFF_TK_LINE);
        tcol := r64(g_tokens, i * ESZ_TOKEN + OFF_TK_COL);
        loop {   // 跨行到 tline
            if ln >= tline { break; }
            if pos >= sl { break; }
            if load8(g_source, pos) == 10 { ln = ln + 1; cl = 1; }
            else { cl = cl + 1; }
            pos = pos + 1;
        }
        loop {   // 行内前进到 tcol
            if cl >= tcol { break; }
            if pos >= sl { break; }
            pos = pos + 1;
            cl = cl + 1;
        }
        w64(offs, i * 8, pos);
        i = i + 1;
    }
    // pass 2：差分编码（相对上一令牌；首令牌相对 (0,0)；modifiers 恒 0）。
    // 仅主文件令牌（起始偏移 < 段 1 偏移；无导入时 g_seg_count == 1 → 全源）
    main_limit : ., mut = sl;
    if g_seg_count > 1 { main_limit = r64(g_seg_starts, 8); }
    out : string, mut = "{\"data\":[";
    prev_line : ., mut = 0;
    prev_col : ., mut = 0;
    first : ., mut = 1;
    j : ., mut = 0;
    loop {
        if j >= n { break; }
        st := r64(offs, j * 8);
        if st < main_limit {
            line0 : ., mut = r64(g_tokens, j * ESZ_TOKEN + OFF_TK_LINE) - 1;
            token_line_start := analysis_line_start(line0);
            col0 := analysis_utf16_units(token_line_start, st);
            if first == 0 { out = out + ","; }
            if line0 > prev_line {
                // 跨行令牌：deltaStartChar 为绝对列（LSP 差分编码规范——
                // deltaLine > 0 时列非相对差）。旧实现恒输出 col0 - prev_col，
                // 跨行令牌产生负 deltaStartChar，客户端解码得到非法列。
                // （Task 6 测试用单行源码，跨行路径未被覆盖——Task 8 客户端
                // 冒烟测试暴露，已补多行用例。）
                out = out + int_str(line0 - prev_line);
                out = out + ",";
                out = out + int_str(col0);
            } else {
                out = out + "0";
                out = out + ",";
                out = out + int_str(col0 - prev_col);
            }
            out = out + ",";
            out = out + int_str(analysis_utf16_units(st, st + analysis_tok_span(j, st, sl)));
            out = out + ",";
            out = out + int_str(analysis_token_type(j));
            out = out + ",0";
            prev_line = line0;
            prev_col = col0;
            first = 0;
        }
        j = j + 1;
    }
    out = out + "]}";
    return out;
}
