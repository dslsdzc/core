// === analysis.cr ===
// Hover and go-to-definition for the LSP: position to token to symbol lookup.
// Queries read the snapshot from the last successful check (g_tokens, g_funcs,
// g_structs, g_enums, g_ast, g_types, g_files, and the main source text).
// They do not run a check or modify frontend state.
//
// Coordinates: entry line and col are LSP 0-based. Tokens, AST nodes, and line
// tables are 1-based; functions convert internally.
//
// Declaration lookup:
// - functions: fi_ast_node gives the EXPR_FN node's line and col.
// - structs and enums: the parser does not create declaration AST nodes, so scan
//   the main token stream and then imported token streams for T_STRUCT or T_ENUM
//   followed by the matching identifier.
// - locals: g_syms is popped after check_all, so scan g_ast for the nearest
//   EXPR_LET, EXPR_PARAM, or EXPR_FOR with the same name before the query.
//
// Cross-file: declaration line to g_line_fileid to the g_files path. Subtract the
// owning SourceManager line base to get the target file's own coordinates.
//
// String building uses literal-initialized accumulators. Do not name a variable
// match: it is reserved in the bootstrap parser and crashes.

// Type names from the read-only snapshot. Do not call res_type_node; it allocates type rows.

// TY_* constant to name
fn analysis_tyname(ty: int) -> string:
    if ty == TY_INT:
        return "int"
    if ty == TY_DEX:
        return "dex"
    if ty == TY_BOOL:
        return "bool"
    if ty == TY_STRING:
        return "string"
    if ty == TY_UNIT:
        return "unit"
    if ty == TY_NEVER:
        return "never"
    if ty == TY_CHAR:
        return "char"
    if ty == TI_DYN:
        return "dyn"
    return "?"

// Type-table index to name for base, named, ref, ptr, slice, array, generic
// application, generic parameter, and tuple rows.
fn analysis_type_name_ti(ti: int) -> string:
    k := get_type_kind(ti)
    if k < 0:
        return "?"
    if k == TYP_BASE:
        return analysis_tyname(get_type_data(ti))
    if k == TYP_NAMED || k == TYP_GENERIC_PARAM:
        return istr_get(get_type_data(ti))
    if k == TYP_REF:
        out : string, mut = "&"
        if get_type_extra(ti) != 0:
            out = out + "mut "
        out = out + analysis_type_name_ti(get_type_data(ti))
        return out
    if k == TYP_PTR:
        out : string, mut = "*"
        out = out + analysis_type_name_ti(get_type_data(ti))
        return out
    if k == TYP_SLICE:
        out : string, mut = "[]"
        out = out + analysis_type_name_ti(get_type_data(ti))
        return out
    if k == TYP_ARRAY:
        out : string, mut = analysis_type_name_ti(get_type_data(ti))
        out = out + "["
        out = out + int_str(get_type_extra(ti))
        out = out + "]"
        return out
    if k == TYP_GENERIC_APPLY:
        return analysis_type_name_ti(get_type_data(ti))
    if k == TYP_TUPLE:
        cnt : ., mut = get_type_data(ti)
        out : string, mut = "("
        e : ., mut = 0
        loop:
            if e >= cnt:
                break
            if e > 0:
                out = out + ", "
            out = out + analysis_type_name_ti(cell_load(g_gen_apply_data, (get_type_extra(ti) + e) * 8))
            e = e + 1
        out = out + ")"
        return out
    return "?"

// AST type node to name. depth bounds recursive chains.
fn analysis_type_node_name(node: int, depth: int) -> string:
    if node < 0 || node >= g_ast_count || depth > 8:
        return "?"
    k := ast_kind(node)
    if k == 0:
        return analysis_tyname(ast_type_val(node))
    if k == EXPR_IDENT:
        return istr_get(ast_int_val(node))
    if k == EXPR_REFTYPE:
        out : string, mut = "&"
        if ast_data(node) != 0:
            out = out + "mut "
        out = out + analysis_type_node_name(ast_a(node), depth + 1)
        return out
    if k == EXPR_PTRTYPE:
        out : string, mut = "*"
        out = out + analysis_type_node_name(ast_a(node), depth + 1)
        return out
    if k == EXPR_OPTIONAL:
        // T? displays the inner name followed by ?.
        out : string, mut = ""
        out = out + analysis_type_node_name(ast_a(node), depth + 1)
        out = out + "?"
        return out
    if k == EXPR_ARRAY:
        out : string, mut = "["
        out = out + analysis_type_node_name(ast_a(node), depth + 1)
        if ast_int_val(node) != 0:
            out = out + ";"
            out = out + int_str(ast_int_val(node))
        out = out + "]"
        return out
    if k == EXPR_GENERIC_APPLY:
        out : string, mut = istr_get(ast_a(node))
        out = out + "<"
        ac : ., mut = 0
        an : ., mut = ast_b(node)
        loop:
            if ac >= ast_c(node):
                break
            if ac > 0:
                out = out + ", "
            out = out + analysis_type_node_name(an, depth + 1)
            ac = ac + 1
            an = an + 1
        out = out + ">"
        return out
    return "?"

// ── 令牌定位 ──

// Find the token covering (line, col), with 0-based line and UTF-16 col.
// Returns the token index, or -1. The lexer records byte columns, so convert to a
// byte position first.
fn analysis_token_at(line: int, col: int) -> int:
    if line < 0 || col < 0:
        return -1
    tl : ., mut = line + 1
    line_start := analysis_line_start(line)
    cursor := analysis_pos_of(line, col)
    tc : ., mut = cursor - line_start + 1
    i : ., mut = 0
    loop:
        if i >= g_token_count:
            return -1
        if cell_load(g_tokens, i * ESZ_TOKEN + OFF_TK_KIND) == T_EOF:
            return -1
        if cell_load(g_tokens, i * ESZ_TOKEN + OFF_TK_LINE) == tl:
            cl := cell_load(g_tokens, i * ESZ_TOKEN + OFF_TK_COL)
            lex := cell_load(g_tokens, i * ESZ_TOKEN + OFF_TK_LEXEME)
            w : ., mut = 1
            if lex >= 0:
                w = str_len(istr_get(lex))
            if tc >= cl && tc < cl + w:
                return i
        i = i + 1

// Return the byte offset of a zero-based source line.
fn analysis_line_start(line: int) -> int:
    if line <= 0:
        return 0
    sl := str_len(g_source)
    current : ., mut = 0
    i : ., mut = 0
    loop:
        if i >= sl:
            return sl
        if load8(g_source, i) == 10:
            current = current + 1
            i = i + 1
            if current >= line:
                return i
        else:
            i = i + 1
    return sl

// Decode one UTF-8 sequence from g_source. Invalid bytes occupy one unit.
fn analysis_utf8_next_in(text: string, pos: int, sl: int) -> int:
    if pos < 0 || pos >= sl:
        return 1
    b0 := load8(text, pos)
    if b0 < 128:
        return 1
    if b0 < 224 && pos + 1 < sl:
        b1 := load8(text, pos + 1)
        if b1 >= 128 && b1 < 192:
            return 2
    if b0 < 240 && pos + 2 < sl:
        b1 := load8(text, pos + 1)
        b2 := load8(text, pos + 2)
        if b1 >= 128 && b1 < 192 && b2 >= 128 && b2 < 192:
            return 3
    if b0 >= 240 && b0 < 248 && pos + 3 < sl:
        b1 := load8(text, pos + 1)
        b2 := load8(text, pos + 2)
        b3 := load8(text, pos + 3)
        if b1 >= 128 && b1 < 192 && b2 >= 128 && b2 < 192 && b3 >= 128 && b3 < 192:
            return 4
    return 1

fn analysis_utf8_next(pos: int, sl: int) -> int:
    return analysis_utf8_next_in(g_source, pos, sl)

fn analysis_utf8_cp_in(text: string, pos: int, adv: int) -> int:
    b0 := load8(text, pos)
    if adv == 1:
        return b0
    if adv == 2:
        return (b0 - 192) * 64 + load8(text, pos + 1) - 128
    if adv == 3:
        return (b0 - 224) * 4096 + (load8(text, pos + 1) - 128) * 64 + load8(text, pos + 2) - 128
    return (b0 - 240) * 262144 + (load8(text, pos + 1) - 128) * 4096 + (load8(text, pos + 2) - 128) * 64 + load8(text, pos + 3) - 128

fn analysis_utf8_cp(pos: int, adv: int) -> int:
    return analysis_utf8_cp_in(g_source, pos, adv)

fn analysis_utf16_units_in(text: string, start: int, end: int) -> int:
    sl := str_len(text)
    p : ., mut = start
    units : ., mut = 0
    loop:
        if p >= end || p >= sl:
            break
        adv : ., mut = analysis_utf8_next_in(text, p, sl)
        if p + adv > end:
            adv = 1
        cp := analysis_utf8_cp_in(text, p, adv)
        if cp >= 65536:
            units = units + 2
        else:
            units = units + 1
        p = p + adv
    return units

fn analysis_utf16_units(start: int, end: int) -> int:
    return analysis_utf16_units_in(g_source, start, end)

fn analysis_source_byte(pos: int, sl: int) -> int:
    if pos < 0 || pos >= sl:
        return -1
    return load8(g_source, pos)

// Function hover.

// Parameter type name from an EXPR_PARAM node.
fn analysis_param_type_name(pn: int) -> string:
    tn := ast_data(pn)
    if tn >= 0 && tn < g_ast_count && ast_kind(tn) != 0:
        return analysis_type_node_name(tn, 0)
    return analysis_tyname(ast_type_val(pn))

// Function return type name. The EXPR_FN type_val slot holds the return type node; 0 means use the declaration.
fn analysis_fn_ret_name(fi: int) -> string:
    fn_node := fi_ast_node(fi)
    if fn_node >= 0 && fn_node < g_ast_count:
        tn := ast_type_val(fn_node)
        if tn >= 0 && tn < g_ast_count:
            if ast_kind(tn) != 0:
                return analysis_type_node_name(tn, 0)
            return analysis_tyname(ast_type_val(tn))
    return analysis_tyname(fi_return_type(fi))

// Function signature: fn name(param types...) -> return type.
fn analysis_hover_fn(fi: int) -> string:
    out : string, mut = "fn "
    out = out + istr_get(fi_name(fi))
    out = out + "("
    first_param : ., mut = -1
    param_count : ., mut = 0
    fn_node := fi_ast_node(fi)
    if fn_node >= 0 && fn_node < g_ast_count:
        first_param = ast_b(fn_node)
        param_count = ast_c(fn_node)
    pi : ., mut = 0
    pn : ., mut = first_param
    loop:
        if pi >= param_count:
            break
        if pn < 0 || pn >= g_ast_count:
            break
        if pi > 0:
            out = out + ", "
        if ast_kind(pn) == EXPR_PARAM:
            out = out + analysis_param_type_name(pn)
        pi = pi + 1
        pn = pn + 1
        // Parameter nodes are not contiguous because type nodes sit between them; advance to the next EXPR_PARAM.
        loop:
            if pn >= g_ast_count:
                break
            if ast_kind(pn) == EXPR_PARAM:
                break
            pn = pn + 1
    out = out + ") -> "
    out = out + analysis_fn_ret_name(fi)
    return out

// Struct hover: struct name { field: type, ... }.
fn analysis_hover_struct(si: int) -> string:
    out : string, mut = "struct "
    out = out + istr_get(si_name(si))
    out = out + " {"
    f : ., mut = 0
    loop:
        if f >= si_field_count(si):
            break
        out = out + " "
        out = out + istr_get(si_field_name(si, f))
        out = out + ": "
        tn := si_field_type_node(si, f)
        if tn >= 0 && tn < g_ast_count && ast_kind(tn) != 0:
            out = out + analysis_type_node_name(tn, 0)
        else:
            out = out + analysis_tyname(si_field_type(si, f))
        out = out + ","
        f = f + 1
    out = out + " }"
    return out

// Enum hover: enum name { variant, ... }.
fn analysis_hover_enum(ei: int) -> string:
    out : string, mut = "enum "
    out = out + istr_get(ei_name(ei))
    out = out + " {"
    v : ., mut = 0
    loop:
        if v >= ei_variant_count(ei):
            break
        out = out + " "
        out = out + istr_get(ei_variant_name(ei, v))
        out = out + ","
        v = v + 1
    out = out + " }"
    return out

// Local variables by AST lookup.

// Find the declaration node for name_ni among EXPR_LET, EXPR_PARAM, and
// EXPR_FOR. Take the nearest one at or before the query position. This is an
// approximation of block scope. Returns -1 when absent.
fn analysis_var_decl(name_ni: int, line: int, col: int) -> int:
    tl : ., mut = line + 1
    tc := analysis_pos_of(line, col) - analysis_line_start(line) + 1
    best : ., mut = -1
    bl : ., mut = -1
    bc : ., mut = -1
    i : ., mut = 0
    loop:
        if i >= g_ast_count:
            break
        k := ast_kind(i)
        if k == EXPR_LET || k == EXPR_PARAM || k == EXPR_FOR:
            if ast_a(i) == name_ni:
                ln := ast_line(i)
                cl : ., mut = ast_col(i)
                if ln < tl || (ln == tl && cl <= tc):
                    if ln > bl || (ln == bl && cl > bc):
                        best = i
                        bl = ln
                        bc = cl
        i = i + 1
    return best

// Variable type name from a declaration node.
fn analysis_var_type(vd: int, depth: int) -> string:
    if vd < 0 || depth > 8:
        return "?"
    k := ast_kind(vd)
    if k == EXPR_PARAM:
        return analysis_param_type_name(vd)
    if k == EXPR_FOR:
        return "int"
    if k == EXPR_LET:
        tn := ast_b(vd)
        if tn >= 0 && tn < g_ast_count:
            if ast_kind(tn) != 0:
                return analysis_type_node_name(tn, 0)
            return analysis_tyname(ast_type_val(tn))
        return analysis_type_of_expr(ast_c(vd), depth + 1)
    return "?"

// Expression type name by lightweight recovery for literals, calls, identifiers, and references. depth prevents cycles.
fn analysis_type_of_expr(node: int, depth: int) -> string:
    if node < 0 || depth > 8:
        return "?"
    k : ., mut = ast_kind(node)
    if k == EXPR_INT:
        return "int"
    if k == EXPR_DEX:
        return "dex"
    if k == EXPR_BOOL:
        return "bool"
    if k == EXPR_STRING:
        return "string"
    if k == EXPR_CHAR:
        return "char"
    if k == EXPR_CALL:
        f := ast_a(node)
        if f >= 0 && ast_kind(f) == EXPR_IDENT:
            fi := find_func(ast_int_val(f))
            if fi >= 0:
                return analysis_fn_ret_name(fi)
        return "?"
    if k == EXPR_IDENT:
        vd := analysis_var_decl(ast_int_val(node), ast_line(node) - 1, ast_col(node) - 1)
        if vd >= 0:
            return analysis_var_type(vd, depth + 1)
        return "?"
    if k == EXPR_UNARY && ast_c(node) == UOP_REF:
        out : string, mut = "&"
        out = out + analysis_type_of_expr(ast_a(node), depth + 1)
        return out
    return "?"

// Hover.

// Hover content at a position: function signature, variable type, struct field, or enum variant. Empty when absent.
fn analysis_type_visible(name_ni: int) -> int:
    si := find_sym(name_ni)
    if si < 0 || sym_kind(si) != SYM_TYPE:
        return 0
    return sym_visible(si)

fn analysis_hover(line: int, col: int) -> string:
    // Queries run under the document's library so cross-library pub filtering
    // matches the checker.
    g_cur_lib = lib_lookup_path(g_source_name)
    ti := analysis_token_at(line, col)
    if ti < 0:
        return ""
    if cell_load(g_tokens, ti * ESZ_TOKEN + OFF_TK_KIND) != T_IDENT:
        return ""
    name_ni := cell_load(g_tokens, ti * ESZ_TOKEN + OFF_TK_LEXEME)
    // Locals and parameters shadow functions and type names.
    vd := analysis_var_decl(name_ni, line, col)
    if vd >= 0:
        t := analysis_var_type(vd, 0)
        if str_len(t) > 0:
            return t
    // 函数
    fi := find_func(name_ni)
    if fi >= 0:
        return analysis_hover_fn(fi)
    // 结构体
    if analysis_type_visible(name_ni) != 0:
        si := find_struct_by_name(name_ni)
        if si >= 0:
            return analysis_hover_struct(si)
        // 枚举
        ei := find_enum(name_ni)
        if ei >= 0:
            return analysis_hover_enum(ei)
    return ""

// Definition.

// Result of a cross-file declaration scan. The token stream is restored to the
// main file before the caller reads these fields.
g_decl_line : int, mut
g_decl_col : int, mut

fn analysis_restore_main_tokens():
    g_source = sm_file_text(g_main_sm)
    g_source_len = str_len(g_source)
    g_source_file = g_main_sm
    g_line_base = sm_file_line_base(g_main_sm)
    tokenize(g_main_sm, 0)

// Find a struct/enum declaration in the main file or any imported file.
// Struct and enum declarations have no AST node, so this scans token streams.
fn analysis_decl_any(kw: int, name_ni: int) -> int:
    d := analysis_decl_tok(kw, name_ni)
    if d >= 0:
        g_decl_line = cell_load(g_tokens, d * ESZ_TOKEN + OFF_TK_LINE)
        g_decl_col = cell_load(g_tokens, d * ESZ_TOKEN + OFF_TK_COL)
        return 1
    i : ., mut = 0
    loop:
        if i >= g_import_count:
            break
        sm := cell_load(g_import_sm, i * 8)
        if sm != g_main_sm:
            tokenize(sm, 0)
            d2 := analysis_decl_tok(kw, name_ni)
            if d2 >= 0:
                g_decl_line = cell_load(g_tokens, d2 * ESZ_TOKEN + OFF_TK_LINE)
                g_decl_col = cell_load(g_tokens, d2 * ESZ_TOKEN + OFF_TK_COL)
                analysis_restore_main_tokens()
                return 1
        i = i + 1
    analysis_restore_main_tokens()
    return 0

// Scan g_tokens for T_STRUCT or T_ENUM followed by the matching identifier.
// Returns the name token index, or -1. Struct and enum declarations have no AST
// node; see the file header.
fn analysis_decl_tok(kw: int, name_ni: int) -> int:
    i : ., mut = 0
    loop:
        if i + 1 >= g_token_count:
            return -1
        if cell_load(g_tokens, i * ESZ_TOKEN + OFF_TK_KIND) == kw:
            if cell_load(g_tokens, (i + 1) * ESZ_TOKEN + OFF_TK_KIND) == T_IDENT && cell_load(g_tokens, (i + 1) * ESZ_TOKEN + OFF_TK_LEXEME) == name_ni:
                return i + 1
        i = i + 1

// 1-based line to file path through g_line_fileid and g_files; fall back to the main file.
fn analysis_path_for_line(ln1: int) -> string:
    fid : ., mut = -1
    if ln1 >= 1 && ln1 - 1 < g_line_count:
        fid = cell_load(g_line_fileid, (ln1 - 1) * 8)
    if fid < 0 && g_file_count > 0:
        fid = cell_load(g_files, 0)
    i : ., mut = 0
    loop:
        if i >= g_file_count:
            break
        if cell_load(g_files, i * 24) == fid:
            p := load_str_ptr(g_files, i * 24 + 8)

            if str_len(p) > 0:
                return p
        i = i + 1
    return ""

// 1-based line to the owning file's line offset in the flat line space.
// The main file has offset 0; imported files start after the files registered
// before them.
fn analysis_line_offset(ln1: int) -> int:
    fid : ., mut = -1
    if ln1 >= 1 && ln1 - 1 < g_line_count:
        fid = cell_load(g_line_fileid, (ln1 - 1) * 8)
    if fid < 0:
        return 0
    sm := file_sm_id(fid)
    if sm < 0:
        return 0
    return sm_file_line_base(sm)

// Declaration position in 1-based concatenated coordinates to Location JSON.
// Convert line and column to 0-based and subtract the segment offset. Escape the
// URI with lsp_json_escape_str.
fn analysis_def_json(ln1: int, cl1: int) -> string:
    fid := -1
    if ln1 >= 1 && ln1 - 1 < g_line_count:
        fid = cell_load(g_line_fileid, (ln1 - 1) * 8)
    sm := file_sm_id(fid)
    txt : string, mut = g_source
    local_ln : ., mut = ln1
    line_start : ., mut = analysis_line_start(ln1 - 1)
    if sm >= 0:
        txt = sm_file_text(sm)
        local_ln = ln1 - sm_file_line_base(sm)
        line_start = sm_line_start(sm, local_ln)
    line0 : ., mut = local_ln - 1
    decl_pos := line_start + cl1 - 1
    col0 := analysis_utf16_units_in(txt, line_start, decl_pos)
    uri : string, mut = "file://"
    uri = uri + analysis_path_for_line(ln1)
    out : string, mut = "{\"uri\":"
    out = out + lsp_json_escape_str(uri)
    out = out + ",\"range\":{\"start\":{\"line\":"
    out = out + int_str(line0)
    out = out + ",\"character\":"
    out = out + int_str(col0)
    out = out + "},\"end\":{\"line\":"
    out = out + int_str(line0)
    out = out + ",\"character\":"
    adv := analysis_utf8_next_in(txt, decl_pos, str_len(txt))
    out = out + int_str(analysis_utf16_units_in(txt, line_start, decl_pos + adv))
    out = out + "}}}"
    return out

// Location JSON at a position ({"uri","range"}); empty when absent.
fn analysis_definition(line: int, col: int) -> string:
    g_cur_lib = lib_lookup_path(g_source_name)
    ti := analysis_token_at(line, col)
    if ti < 0:
        return ""
    if cell_load(g_tokens, ti * ESZ_TOKEN + OFF_TK_KIND) != T_IDENT:
        return ""
    name_ni := cell_load(g_tokens, ti * ESZ_TOKEN + OFF_TK_LEXEME)
    // 局部变量/参数
    vd := analysis_var_decl(name_ni, line, col)
    if vd >= 0:
        return analysis_def_json(ast_line(vd), ast_col(vd))
    // 函数：AST 节点携带全局行号，导入文件里的声明也能定位。
    fi := find_func(name_ni)
    if fi >= 0:
        fn_node := fi_ast_node(fi)
        if fn_node >= 0:
            return analysis_def_json(ast_line(fn_node), ast_col(fn_node))
        return ""
    // 结构体 / 枚举（令牌反查声明；主文件找不到时扫描导入文件）
    if analysis_type_visible(name_ni) != 0:
        if find_struct_by_name(name_ni) >= 0:
            if analysis_decl_any(T_STRUCT, name_ni) != 0:
                return analysis_def_json(g_decl_line, g_decl_col)
        if find_enum(name_ni) >= 0:
            if analysis_decl_any(T_ENUM, name_ni) != 0:
                return analysis_def_json(g_decl_line, g_decl_col)
    return ""

// Completion: position to prefix, then filter candidates and emit JSON.
// The prefix is the identifier before the cursor; after @ it selects builtin
// context. Candidate sources are the keyword list in lexer lookup_keyword, the
// @ builtins in checker's EXPR_AT dispatch plus @ffi, g_syms, g_funcs, g_structs,
// and g_enums. kind uses LSP CompletionItemKind values: Keyword=14, Function=3,
// Variable=6, Struct=22, Enum=13.
// Scan the snapshot g_source directly for the prefix; a partial identifier is not
// a token. This uses the same last-successful-check snapshot as hover and
// definition.

// Convert 0-based (line, col) with UTF-16 col to a byte offset in g_source.
// A cursor inside a surrogate pair snaps to the code point start.
fn analysis_pos_of(line: int, col: int) -> int:
    sl := str_len(g_source)
    if line < 0:
        return 0
    start := analysis_line_start(line)
    p : ., mut = start
    units : ., mut = 0
    want : ., mut = col
    if want < 0:
        want = 0
    loop:
        if p >= sl || load8(g_source, p) == 10 || units >= want:
            break
        adv := analysis_utf8_next(p, sl)
        cp := analysis_utf8_cp(p, adv)
        next_units : ., mut = 1
        if cp >= 65536:
            next_units = 2
        if units + next_units > want:
            break
        p = p + adv
        units = units + next_units
    return p

// Start offset of the identifier characters immediately before pos.
fn analysis_prefix_start(pos: int) -> int:
    s : ., mut = pos
    loop:
        if s <= 0:
            break
        if is_ident_char(load8(g_source, s - 1)) == 0:
            break
        s = s - 1
    return s

// Copy a byte range of g_source to a stable heap string.
fn analysis_sub_copy(start: int, end: int) -> string:
    n : ., mut = end - start
    s := alloc(n + 1)
    i : ., mut = 0
    loop:
        if i >= n:
            break
        store8(s, i, load8(g_source, start + i))
        i = i + 1
    store8(s, n, 0)
    return s

// Whether name starts with prefix. An empty prefix matches; comparison is case-insensitive per LSP.
fn analysis_has_prefix(name: string, prefix: string) -> int:
    pl := str_len(prefix)
    if pl == 0:
        return 1
    if str_len(name) < pl:
        return 0
    i : ., mut = 0
    loop:
        if i >= pl:
            break
        nc : ., mut = load8(name, i)
        pc : ., mut = load8(prefix, i)
        if nc >= 65 && nc <= 90:
            nc = nc + 32
        if pc >= 65 && pc <= 90:
            pc = pc + 32
        if nc != pc:
            return 0
        i = i + 1
    return 1

// One completion item: {"label":..., "kind":N}.
fn analysis_citem(name: string, kind: int) -> string:
    out : string, mut = "{\"label\":"
    out = out + lsp_json_escape_str(name)
    out = out + ",\"kind\":"
    out = out + int_str(kind)
    out = out + "}"
    return out

// Keyword candidates from lexer lookup_keyword, with kind=14. Matches are joined
// with commas; an empty result means no match.
fn analysis_kw_items(prefix: string) -> string:
    out : string, mut = ""
    first : ., mut = 1
    if analysis_has_prefix("fn", prefix) != 0:
        if first == 0:
            out = out + ","
        out = out + analysis_citem("fn", 14)
        first = 0
    if analysis_has_prefix("mut", prefix) != 0:
        if first == 0:
            out = out + ","
        out = out + analysis_citem("mut", 14)
        first = 0
    if analysis_has_prefix("return", prefix) != 0:
        if first == 0:
            out = out + ","
        out = out + analysis_citem("return", 14)
        first = 0
    if analysis_has_prefix("if", prefix) != 0:
        if first == 0:
            out = out + ","
        out = out + analysis_citem("if", 14)
        first = 0
    if analysis_has_prefix("else", prefix) != 0:
        if first == 0:
            out = out + ","
        out = out + analysis_citem("else", 14)
        first = 0
    if analysis_has_prefix("loop", prefix) != 0:
        if first == 0:
            out = out + ","
        out = out + analysis_citem("loop", 14)
        first = 0
    if analysis_has_prefix("while", prefix) != 0:
        if first == 0:
            out = out + ","
        out = out + analysis_citem("while", 14)
        first = 0
    if analysis_has_prefix("for", prefix) != 0:
        if first == 0:
            out = out + ","
        out = out + analysis_citem("for", 14)
        first = 0
    if analysis_has_prefix("break", prefix) != 0:
        if first == 0:
            out = out + ","
        out = out + analysis_citem("break", 14)
        first = 0
    if analysis_has_prefix("continue", prefix) != 0:
        if first == 0:
            out = out + ","
        out = out + analysis_citem("continue", 14)
        first = 0
    if analysis_has_prefix("true", prefix) != 0:
        if first == 0:
            out = out + ","
        out = out + analysis_citem("true", 14)
        first = 0
    if analysis_has_prefix("false", prefix) != 0:
        if first == 0:
            out = out + ","
        out = out + analysis_citem("false", 14)
        first = 0
    if analysis_has_prefix("struct", prefix) != 0:
        if first == 0:
            out = out + ","
        out = out + analysis_citem("struct", 14)
        first = 0
    if analysis_has_prefix("enum", prefix) != 0:
        if first == 0:
            out = out + ","
        out = out + analysis_citem("enum", 14)
        first = 0
    if analysis_has_prefix("extern", prefix) != 0:
        if first == 0:
            out = out + ","
        out = out + analysis_citem("extern", 14)
        first = 0
    if analysis_has_prefix("impl", prefix) != 0:
        if first == 0:
            out = out + ","
        out = out + analysis_citem("impl", 14)
        first = 0
    if analysis_has_prefix("match", prefix) != 0:
        if first == 0:
            out = out + ","
        out = out + analysis_citem("match", 14)
        first = 0
    if analysis_has_prefix("import", prefix) != 0:
        if first == 0:
            out = out + ","
        out = out + analysis_citem("import", 14)
        first = 0
    if analysis_has_prefix("pub", prefix) != 0:
        if first == 0:
            out = out + ","
        out = out + analysis_citem("pub", 14)
        first = 0
    if analysis_has_prefix("go", prefix) != 0:
        if first == 0:
            out = out + ","
        out = out + analysis_citem("go", 14)
        first = 0
    if analysis_has_prefix("await", prefix) != 0:
        if first == 0:
            out = out + ","
        out = out + analysis_citem("await", 14)
        first = 0
    if analysis_has_prefix("unsafe", prefix) != 0:
        if first == 0:
            out = out + ","
        out = out + analysis_citem("unsafe", 14)
        first = 0
    if analysis_has_prefix("flow", prefix) != 0:
        if first == 0:
            out = out + ","
        out = out + analysis_citem("flow", 14)
        first = 0
    if analysis_has_prefix("yield", prefix) != 0:
        if first == 0:
            out = out + ","
        out = out + analysis_citem("yield", 14)
        first = 0
    if analysis_has_prefix("interface", prefix) != 0:
        if first == 0:
            out = out + ","
        out = out + analysis_citem("interface", 14)
        first = 0
    if analysis_has_prefix("type", prefix) != 0:
        if first == 0:
            out = out + ","
        out = out + analysis_citem("type", 14)
        first = 0
    if analysis_has_prefix("mod", prefix) != 0:
        if first == 0:
            out = out + ","
        out = out + analysis_citem("mod", 14)
        first = 0
    if analysis_has_prefix("as", prefix) != 0:
        if first == 0:
            out = out + ","
        out = out + analysis_citem("as", 14)
        first = 0
    if analysis_has_prefix("auto", prefix) != 0:
        if first == 0:
            out = out + ","
        out = out + analysis_citem("auto", 14)
        first = 0
    if analysis_has_prefix("fileid", prefix) != 0:
        if first == 0:
            out = out + ","
        out = out + analysis_citem("fileid", 14)
        first = 0
    if analysis_has_prefix("in", prefix) != 0:
        if first == 0:
            out = out + ","
        out = out + analysis_citem("in", 14)
        first = 0
    if analysis_has_prefix("None", prefix) != 0:
        if first == 0:
            out = out + ","
        out = out + analysis_citem("None", 14)
        first = 0
    if analysis_has_prefix("Some", prefix) != 0:
        if first == 0:
            out = out + ","
        out = out + analysis_citem("Some", 14)
        first = 0
    if analysis_has_prefix("unit", prefix) != 0:
        if first == 0:
            out = out + ","
        out = out + analysis_citem("unit", 14)
        first = 0
    return out

// @ builtin candidates from checker's EXPR_AT dispatch plus parser's @ffi, with
// kind=3 Function. Labels omit the @.
fn analysis_at_items(prefix: string) -> string:
    out : string, mut = ""
    first : ., mut = 1
    if analysis_has_prefix("sizeOf", prefix) != 0:
        if first == 0:
            out = out + ","
        out = out + analysis_citem("sizeOf", 3)
        first = 0
    if analysis_has_prefix("addr", prefix) != 0:
        if first == 0:
            out = out + ","
        out = out + analysis_citem("addr", 3)
        first = 0
    if analysis_has_prefix("alignOf", prefix) != 0:
        if first == 0:
            out = out + ","
        out = out + analysis_citem("alignOf", 3)
        first = 0
    if analysis_has_prefix("fields", prefix) != 0:
        if first == 0:
            out = out + ","
        out = out + analysis_citem("fields", 3)
        first = 0
    if analysis_has_prefix("hasField", prefix) != 0:
        if first == 0:
            out = out + ","
        out = out + analysis_citem("hasField", 3)
        first = 0
    if analysis_has_prefix("field", prefix) != 0:
        if first == 0:
            out = out + ","
        out = out + analysis_citem("field", 3)
        first = 0
    if analysis_has_prefix("typeInfo", prefix) != 0:
        if first == 0:
            out = out + ","
        out = out + analysis_citem("typeInfo", 3)
        first = 0
    if analysis_has_prefix("raw_int", prefix) != 0:
        if first == 0:
            out = out + ","
        out = out + analysis_citem("raw_int", 3)
        first = 0
    if analysis_has_prefix("comptime", prefix) != 0:
        if first == 0:
            out = out + ","
        out = out + analysis_citem("comptime", 3)
        first = 0
    if analysis_has_prefix("inline", prefix) != 0:
        if first == 0:
            out = out + ","
        out = out + analysis_citem("inline", 3)
        first = 0
    if analysis_has_prefix("NoBoundsCheck", prefix) != 0:
        if first == 0:
            out = out + ","
        out = out + analysis_citem("NoBoundsCheck", 3)
        first = 0
    if analysis_has_prefix("fast", prefix) != 0:
        if first == 0:
            out = out + ","
        out = out + analysis_citem("fast", 3)
        first = 0
    if analysis_has_prefix("unroll", prefix) != 0:
        if first == 0:
            out = out + ","
        out = out + analysis_citem("unroll", 3)
        first = 0
    if analysis_has_prefix("section", prefix) != 0:
        if first == 0:
            out = out + ","
        out = out + analysis_citem("section", 3)
        first = 0
    if analysis_has_prefix("hotpatch", prefix) != 0:
        if first == 0:
            out = out + ","
        out = out + analysis_citem("hotpatch", 3)
        first = 0
    if analysis_has_prefix("ffi", prefix) != 0:
        if first == 0:
            out = out + ","
        out = out + analysis_citem("ffi", 3)
        first = 0
    // @ptr_of and @str_of are view builtins. Any new language builtin must be added
    // to this table in the same change; the bootstrap L1/L2/L3 tests enforce it.
    if analysis_has_prefix("ptr_of", prefix) != 0:
        if first == 0:
            out = out + ","
        out = out + analysis_citem("ptr_of", 3)
        first = 0
    if analysis_has_prefix("ptr_add", prefix) != 0:
        if str_len(out) > 0:
            out = out + ","
        out = out + analysis_citem("ptr_add", 3)
    if analysis_has_prefix("str_of", prefix) != 0:
        if first == 0:
            out = out + ","
        out = out + analysis_citem("str_of", 3)
        first = 0
    return out

// Append a candidate, deduplicating by name index; return 0 when already present.
fn analysis_cand_add(cand: string, count: int, ni: int, kind: int) -> int:
    i : ., mut = 0
    loop:
        if i >= count:
            break
        if cell_load(cand, i * 16) == ni:
            return 0
        i = i + 1
    cell_store(cand, count * 16, ni)
    cell_store(cand, count * 16 + 8, kind)
    return 1

// Map SYM_* kinds to CompletionItemKind: functions 3, variables 6, types 22,
// modules 9.
fn analysis_sym_item_kind(sk: int) -> int:
    if sk == SYM_FN || sk == SYM_SO_FN:
        return 3
    if sk == SYM_GLOBAL || sk == SYM_LOCAL || sk == SYM_PARAM:
        return 6
    if sk == SYM_TYPE:
        return 22
    return 9

// Completion JSON {"items":[...]} at a position, using the snapshot without running a check.
fn analysis_completion(line: int, col: int) -> string:
    // Completion runs after check_all, where g_cur_lib is reset to -1. Use the
    // main document's library (@user) so cross-library pub filtering applies to
    // whatever imports the analysis pulled in.
    saved_lib := g_cur_lib
    g_cur_lib = lib_lookup_path(g_source_name)
    pos : ., mut = analysis_pos_of(line, col)
    pstart := analysis_prefix_start(pos)
    at_ctx : ., mut = 0
    if pstart > 0 && load8(g_source, pstart - 1) == 64:
        at_ctx = 1
    prefix := analysis_sub_copy(pstart, pos)
    out : string, mut = "{\"items\":["
    if at_ctx != 0:
        out = out + analysis_at_items(prefix)
    else:
        out = out + analysis_kw_items(prefix)
        // Symbol candidates from g_syms, g_funcs, g_structs, and g_enums. Allocate
        // for the exact total.
        total : ., mut = g_sym_count + g_func_count + g_struct_count + g_enum_count
        if total < 1:
            total = 1
        // Avoid alloc(0).
        cand : string, mut = alloc(total * 16)
        cnt : ., mut = 0
        i : ., mut = 0
        loop:
            if i >= g_sym_count:
                break
            if sym_visible(i) == 0:
                i = i + 1
                continue
            kk : ., mut = analysis_sym_item_kind(sym_kind(i))
            // SYM_TYPE covers structs, enums, and interfaces. Distinguish enums by
            // name and emit Enum=13; otherwise emit Struct=22.
            if sym_kind(i) == SYM_TYPE && find_enum(sym_name(i)) >= 0:
                kk = 13
            cnt = cnt + analysis_cand_add(cand, cnt, sym_name(i), kk)
            i = i + 1
        i = 0
        loop:
            if i >= g_func_count:
                break
            if func_visible(i) == 0:
                i = i + 1
                continue
            cnt = cnt + analysis_cand_add(cand, cnt, fi_name(i), 3)
            i = i + 1
        i = 0
        loop:
            if i >= g_struct_count:
                break
            cnt = cnt + analysis_cand_add(cand, cnt, si_name(i), 22)   // Struct
            i = i + 1
        i = 0
        loop:
            if i >= g_enum_count:
                break
            cnt = cnt + analysis_cand_add(cand, cnt, ei_name(i), 13)   // Enum
            i = i + 1
        j : ., mut = 0
        loop:
            if j >= cnt:
                break
            ni := cell_load(cand, j * 16)
            if analysis_has_prefix(istr_get(ni), prefix) != 0:
                if str_len(out) > 10:
                    out = out + ","
                out = out + analysis_citem(istr_get(ni), cell_load(cand, j * 16 + 8))
            j = j + 1
    out = out + "]}"
    g_cur_lib = saved_lib
    return out

// documentSymbol: top-level symbols as a JSON array.
// g_ast has no STRUCT_DEF or ENUM_DEF nodes. Functions come from g_funcs through
// fi_ast_node; structs and enums use analysis_decl_tok, the same token scan as
// definition. Entries are insertion-sorted by source position. Only symbols in the
// main file (segment offset 0) are included, because the LSP document is the main
// file.

// 1-based (line, col) to LSP range JSON: 0-based line and a range covering one character.
fn analysis_range_json(ln1: int, cl1: int) -> string:
    line_start := analysis_line_start(ln1 - 1)
    start_pos := line_start + cl1 - 1
    start_col := analysis_utf16_units(line_start, start_pos)
    adv := analysis_utf8_next(start_pos, str_len(g_source))
    end_col := analysis_utf16_units(line_start, start_pos + adv)
    out : string, mut = "{\"start\":{\"line\":"
    out = out + int_str(ln1 - 1)
    out = out + ",\"character\":"
    out = out + int_str(start_col)
    out = out + "},\"end\":{\"line\":"
    out = out + int_str(ln1 - 1)
    out = out + ",\"character\":"
    out = out + int_str(end_col)
    out = out + "}}"
    return out

// Top-level symbols as a JSON array; "[]" when empty.
fn analysis_document_symbol() -> string:
    total := g_func_count + g_struct_count + g_enum_count
    if total <= 0:
        return "[]"
    // Entry buffer: {name_ni, kind, line, col}, 32 bytes each.
    ent : string, mut = alloc(total * 32)
    cnt : ., mut = 0
    i : ., mut = 0
    loop:
        if i >= g_func_count:
            break
        ni := fi_name(i)
        fn_node := fi_ast_node(i)
        ln : ., mut = 0
        cl : ., mut = 0
        if fn_node >= 0 && fn_node < g_ast_count:
            ln = ast_line(fn_node)
            cl = ast_col(fn_node)
        if ln > 0 && analysis_line_offset(ln) == 0:
            cell_store(ent, cnt * 32, ni)
            cell_store(ent, cnt * 32 + 8, 12)        // SymbolKind.Function = 12
            cell_store(ent, cnt * 32 + 16, ln)
            cell_store(ent, cnt * 32 + 24, cl)
            cnt = cnt + 1
        i = i + 1
    i = 0
    loop:
        if i >= g_struct_count:
            break
        ni := si_name(i)
        d := analysis_decl_tok(T_STRUCT, ni)
        if d >= 0:
            ln := cell_load(g_tokens, d * ESZ_TOKEN + OFF_TK_LINE)
            if analysis_line_offset(ln) == 0:
                cell_store(ent, cnt * 32, ni)
                cell_store(ent, cnt * 32 + 8, 23)    // SymbolKind.Struct = 23
                cell_store(ent, cnt * 32 + 16, ln)
                cell_store(ent, cnt * 32 + 24, cell_load(g_tokens, d * ESZ_TOKEN + OFF_TK_COL))
                cnt = cnt + 1
        i = i + 1
    i = 0
    loop:
        if i >= g_enum_count:
            break
        ni := ei_name(i)
        d := analysis_decl_tok(T_ENUM, ni)
        if d >= 0:
            ln : ., mut = cell_load(g_tokens, d * ESZ_TOKEN + OFF_TK_LINE)
            if analysis_line_offset(ln) == 0:
                cell_store(ent, cnt * 32, ni)
                cell_store(ent, cnt * 32 + 8, 10)    // SymbolKind.Enum = 10
                cell_store(ent, cnt * 32 + 16, ln)
                cell_store(ent, cnt * 32 + 24, cell_load(g_tokens, d * ESZ_TOKEN + OFF_TK_COL))
                cnt = cnt + 1
        i = i + 1
    // Insertion-sort by (line, col) for source order.
    j : ., mut = 1
    loop:
        if j >= cnt:
            break
        key_ni := cell_load(ent, j * 32)
        key_kind := cell_load(ent, j * 32 + 8)
        key_ln := cell_load(ent, j * 32 + 16)
        key_cl := cell_load(ent, j * 32 + 24)
        k : ., mut = j
        loop:
            if k <= 0:
                break
            pln := cell_load(ent, (k - 1) * 32 + 16)
            pcl := cell_load(ent, (k - 1) * 32 + 24)
            if pln < key_ln || (pln == key_ln && pcl <= key_cl):
                break
            cell_store(ent, k * 32, cell_load(ent, (k - 1) * 32))
            cell_store(ent, k * 32 + 8, cell_load(ent, (k - 1) * 32 + 8))
            cell_store(ent, k * 32 + 16, pln)
            cell_store(ent, k * 32 + 24, pcl)
            k = k - 1
        cell_store(ent, k * 32, key_ni)
        cell_store(ent, k * 32 + 8, key_kind)
        cell_store(ent, k * 32 + 16, key_ln)
        cell_store(ent, k * 32 + 24, key_cl)
        j = j + 1
    out : string, mut = "["
    q : ., mut = 0
    loop:
        if q >= cnt:
            break
        if q > 0:
            out = out + ","
        ni := cell_load(ent, q * 32)
        ln1 := cell_load(ent, q * 32 + 16)
        cl1 := cell_load(ent, q * 32 + 24)
        out = out + "{\"name\":"
        out = out + lsp_json_escape_str(istr_get(ni))
        out = out + ",\"kind\":"
        out = out + int_str(cell_load(ent, q * 32 + 8))
        out = out + ",\"range\":"
        out = out + analysis_range_json(ln1, cl1)
        out = out + ",\"selectionRange\":"
        out = out + analysis_range_json(ln1, cl1)
        out = out + ",\"children\":[]}"
        q = q + 1
    out = out + "]"
    return out

// semanticTokens: encode the snapshot g_tokens as LSP semanticTokens/full data.
// Each token emits five integers: deltaLine, deltaStart, length, tokenType, and
// tokenModifiers. The first token is relative to (0, 0). No check is run.
// Only main-file tokens are emitted; segment 1 starts after the main file.
// Length is not the lexeme: operators and numeric literals have lexeme -1, and
// string lexemes are decoded. analysis_tok_span computes the byte span from the
// source by mirroring the lexer's consumption rules.
// Legend indexes: keyword 0, type 1, function 2, variable 3, comment 4 (unused),
// string 5, operator 6, number 7. rpc.cr declares the legend and must match.

// Token kind to legend index. T_IDENT returns -1 because it is classified by name.
fn analysis_kind_type(k: int) -> int:
    if k == T_FN || k == T_MUT || k == T_IF || k == T_ELSE || k == T_LOOP || k == T_WHILE || k == T_FOR || k == T_IN || k == T_RETURN || k == T_BREAK || k == T_CONTINUE || k == T_STRUCT || k == T_ENUM || k == T_IMPL || k == T_PUB || k == T_TRUE || k == T_FALSE || k == T_SELF || k == T_MATCH || k == T_TYPE || k == T_MOD || k == T_IMPORT || k == T_CAST || k == T_GO || k == T_AWAIT || k == T_FLOW || k == T_YIELD || k == T_UNSAFE || k == T_INTERFACE || k == T_AUTO || k == T_FILEID || k == T_NONE || k == T_EXTERN || k == T_CATCH || k == T_FAIL || k == T_SPEC:
        return 0
    if k == T_UNIT || (k >= T_INT_TYPE && k <= T_AUTO_TYPE) || k == T_REF || k == T_DYN || k == T_NEVER:
        return 1
    if k == T_STRING || k == T_CHAR:
        return 5
    if k == T_INT || k == T_DEX:
        return 7
    if k == T_IDENT:
        return -1
    return 6   // 运算符/分隔符：其余全部 kind

// Whether a name is a builtin type name from parser parse_type.
fn analysis_is_builtin_type(ni: int) -> int:
    s := istr_get(ni)
    if str_eq(s, "int") != 0 || str_eq(s, "dex") != 0 || str_eq(s, "bool") != 0 || str_eq(s, "string") != 0 || str_eq(s, "char") != 0 || str_eq(s, "never") != 0 || str_eq(s, "dyn") != 0:
        return 1
    return 0

// Token index to legend index. T_IDENT is classified by symbol table and builtin type names.
fn analysis_token_type(ti: int) -> int:
    k := cell_load(g_tokens, ti * ESZ_TOKEN + OFF_TK_KIND)
    if k != T_IDENT:
        return analysis_kind_type(k)
    ni := cell_load(g_tokens, ti * ESZ_TOKEN + OFF_TK_LEXEME)
    if analysis_is_builtin_type(ni) != 0:
        return 1
    if find_func(ni) >= 0:
        return 2
    if find_struct_by_name(ni) >= 0:
        return 1
    if find_enum(ni) >= 0:
        return 1
    return 3

// Token index to source byte span. Start at st and mirror the lexer consumption rules for the kind.
fn analysis_tok_span(ti: int, st: int, sl: int) -> int:
    k := cell_load(g_tokens, ti * ESZ_TOKEN + OFF_TK_KIND)
    // String and char spans mirror the lexer after interpolation splitting:
    // T_STRING is a literal segment, ending at the closing quote, the next `${`,
    // or a newline. T_INTERP is a hole from `${` to its matching }, with nesting.
    // An unclosed string's trailing backslash stops at the end of the source and
    // never extends the span past the buffer.
    if k == T_STRING || k == T_CHAR:
        q := analysis_source_byte(st, sl)
        p : ., mut = st + 1
        loop:
            if p >= sl:
                break
            c := analysis_source_byte(p, sl)
            if c == 92:
                if p + 1 >= sl:
                    p = sl
                    break
                p = p + 2
            else if c == q:
                p = p + 1
                break
            else if c == 10:
                break
            else if c == 36 && analysis_source_byte(p + 1, sl) == 123:
                break
            // A segment ends at `${`.
            else:
                p = p + 1
        return p - st
    if k == T_INTERP:
        // Hole span: `${` through the matching }, skipping string literals and escapes inside.
        p : ., mut = st + 2
        depth : ., mut = 1
        loop:
            if p >= sl:
                break
            c := analysis_source_byte(p, sl)
            if c == 10:
                break
            if c == 34:
                p = p + 1
                loop:
                    if p >= sl:
                        break
                    sc := analysis_source_byte(p, sl)
                    if sc == 10:
                        break
                    if sc == 92:
                        p = p + 2
                        continue
                    p = p + 1
                    if sc == 34:
                        break
                continue
            if c == 123:
                depth = depth + 1
            if c == 125:
                depth = depth - 1
                if depth == 0:
                    p = p + 1
                    break
            p = p + 1
        return p - st
    // Number span mirrors the lexer: leading dot, base prefix, fraction, and letter suffix.
    if k == T_INT || k == T_DEX:
        p : ., mut = st
        if analysis_source_byte(p, sl) == 46 && is_digit(analysis_source_byte(p + 1, sl)) != 0:
            p = p + 1
        loop:
            if is_digit(analysis_source_byte(p, sl)) != 0:
                p = p + 1
            else:
                break
        if p - st == 1 && load8(g_source, st) == 48:
            nx := analysis_source_byte(p, sl)
            if nx == 120 || nx == 88:
                p = p + 1
                loop:
                    hc := analysis_source_byte(p, sl)
                    if is_digit(hc) != 0 || (hc >= 65 && hc <= 70) || (hc >= 97 && hc <= 102):
                        p = p + 1
                    else:
                        break
            else if nx == 111 || nx == 79:
                p = p + 1
                loop:
                    oc := analysis_source_byte(p, sl)
                    if oc >= 48 && oc <= 55:
                        p = p + 1
                    else:
                        break
            else if nx == 98 || nx == 66:
                p = p + 1
                loop:
                    bc := analysis_source_byte(p, sl)
                    if bc == 48 || bc == 49:
                        p = p + 1
                    else:
                        break
        if analysis_source_byte(p, sl) == 46 && analysis_source_byte(p + 1, sl) != 46:
            p = p + 1
            loop:
                if is_digit(analysis_source_byte(p, sl)) != 0:
                    p = p + 1
                else:
                    break
        loop:
            if is_alpha(analysis_source_byte(p, sl)) != 0:
                p = p + 1
            else:
                break
        return p - st
    // Identifiers, keywords, and type keywords: the lexeme is the source text.
    lex := cell_load(g_tokens, ti * ESZ_TOKEN + OFF_TK_LEXEME)
    if lex >= 0:
        return str_len(istr_get(lex))
    // Operators and separators have lexeme -1; use the fixed length table, defaulting to one byte.
    if k == T_EQEQ || k == T_BANGEQ || k == T_LTEQ || k == T_GTEQ || k == T_ANDAND || k == T_PIPEPIPE || k == T_ARROW || k == T_FATARROW || k == T_COLON_EQ || k == T_PATHSEP || k == T_PLUS_EQ || k == T_MINUS_EQ || k == T_STAR_EQ || k == T_SLASH_EQ || k == T_DOTDOT:
        return 2
    if k == T_DOTDOTDOT:
        return 3
    return 1

// Token stream up to T_EOF to differential JSON {"data":[...]}; empty when there are no tokens.
fn analysis_semantic_tokens() -> string:
    // Count tokens before T_EOF.
    n : ., mut = 0
    loop:
        if n >= g_token_count:
            break
        if cell_load(g_tokens, n * ESZ_TOKEN + OFF_TK_KIND) == T_EOF:
            break
        n = n + 1
    if n == 0:
        return "{\"data\":[]}"
    // Pass 1: token start byte offsets, scanning g_source once with byte columns like the lexer.
    offs : string, mut = alloc(n * 8)
    pos : ., mut = 0
    ln : ., mut = 1
    cl : ., mut = 1
    sl := str_len(g_source)
    i : ., mut = 0
    loop:
        if i >= n:
            break
        tline := cell_load(g_tokens, i * ESZ_TOKEN + OFF_TK_LINE)
        tcol := cell_load(g_tokens, i * ESZ_TOKEN + OFF_TK_COL)
        loop:
            // 跨行到 tline
            if ln >= tline:
                break
            if pos >= sl:
                break
            if load8(g_source, pos) == 10:
                ln = ln + 1
                cl = 1
            else:
                cl = cl + 1
            pos = pos + 1
        loop:
            // 行内前进到 tcol
            if cl >= tcol:
                break
            if pos >= sl:
                break
            pos = pos + 1
            cl = cl + 1
        cell_store(offs, i * 8, pos)
        i = i + 1
    // Pass 2: differential encoding relative to the previous token; the first is
    // relative to (0, 0), and modifiers are always 0. lsp_check_file restores the
    // main file's token stream before analysis, so every token here is main-file.
    main_limit : ., mut = sl
    out : string, mut = "{\"data\":["
    prev_line : ., mut = 0
    prev_col : ., mut = 0
    first : ., mut = 1
    j : ., mut = 0
    loop:
        if j >= n:
            break
        st := cell_load(offs, j * 8)
        if st < main_limit:
            line0 : ., mut = cell_load(g_tokens, j * ESZ_TOKEN + OFF_TK_LINE) - 1
            token_line_start := analysis_line_start(line0)
            col0 := analysis_utf16_units(token_line_start, st)
            if first == 0:
                out = out + ","
            if line0 > prev_line:
                // When deltaLine > 0, deltaStartChar is an absolute column, not a
                // difference. Emitting col0 - prev_col across lines would produce a
                // negative delta and an invalid column.
                out = out + int_str(line0 - prev_line)
                out = out + ","
                out = out + int_str(col0)
            else:
                out = out + "0"
                out = out + ","
                out = out + int_str(col0 - prev_col)
            out = out + ","
            out = out + int_str(analysis_utf16_units(st, st + analysis_tok_span(j, st, sl)))
            out = out + ","
            out = out + int_str(analysis_token_type(j))
            out = out + ",0"
            prev_line = line0
            prev_col = col0
            first = 0
        j = j + 1
    out = out + "]}"
    return out
