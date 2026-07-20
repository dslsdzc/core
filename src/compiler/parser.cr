// Parser: recursive descent with flat AST output

// Global state for parser (shared globals in globals.cr)
g_token_pos : int, mut;

// Buffer for batch declaration overflow (a, b : int = 1, 2)
g_extra_lets : string, mut;    g_extra_lets_cap : int, mut;
g_extra_let_count : int, mut;

// Flag: when set, IDENT { is NOT parsed as struct literal
g_parse_no_struct_literal : int, mut;

fn alloc_node(kind: int, a: int, b: int, c: int, iv: int, tv: int, d: int, line: int, col: int) -> int {
    return ast_alloc(kind, a, b, c, iv, tv, d, line, col);
}

fn cur_tok() -> int { return g_token_pos; }
fn tok_k(p: int) -> int { return r64(g_tokens, p * ESZ_TOKEN + OFF_TK_KIND); }
fn tok_lx(p: int) -> string { return istr_get(r64(g_tokens, p * ESZ_TOKEN + OFF_TK_LEXEME)); }
fn tok_iv(p: int) -> int { return r64(g_tokens, p * ESZ_TOKEN + OFF_TK_INTVAL); }
fn tok_ln(p: int) -> int { return r64(g_tokens, p * ESZ_TOKEN + OFF_TK_LINE); }
fn tok_cl(p: int) -> int { return r64(g_tokens, p * ESZ_TOKEN + OFF_TK_COL); }

fn advance_tok() -> int {
    t := cur_tok();
    if tok_k(t) != T_EOF { g_token_pos = t + 1; }
    return t;
}

fn check(k: int) -> bool {
    if tok_k(cur_tok()) == k { return true; } else { return false; }
}

fn expect(k: int) -> int {
    t := cur_tok();
    if tok_k(t) == k { return advance_tok(); }
    return t;
}

// --- Type parsing ---
fn parse_type() -> int {
    t := cur_tok();
    line := tok_ln(t);
    col := tok_cl(t);
    res : ., mut = 0;
    if tok_k(t) == T_LBRACKET {
        advance_tok();
        inner := parse_type();
        if check(T_SEMI) {
            advance_tok();
            sz := advance_tok();
            advance_tok();
            res = alloc_node(EXPR_ARRAY, inner, 0, 0, tok_iv(sz), 0, 0, line, col);
        } else {
            advance_tok();
            // Slice type [T]
            res = alloc_node(EXPR_ARRAY, inner, 0, 0, 0, 0, 0, line, col);
        }
    } else if tok_k(t) == T_LPAREN {
        advance_tok();
        typ := parse_type();
        advance_tok();
        res = typ;
    } else if tok_k(t) == T_AMPERSAND {
        advance_tok();
        is_mut : ., mut = 0;
        if tok_k(cur_tok()) == T_MUT {
            is_mut = 1;
            advance_tok();
        }
        inner := parse_type();
        res = alloc_node(EXPR_REFTYPE, inner, 0, 0, is_mut, 0, 0, line, col);
    } else if tok_k(t) == T_UNIT {
        advance_tok();
        res = alloc_node(0, 0, 0, 0, 0, TY_UNIT, 0, line, col);
    } else if tok_k(t) == T_IDENT || tok_k(t) == T_SELF || tok_k(t) == T_UNDERSCORE {
        lex := tok_lx(t);
        advance_tok();
        if lex == "int" { res = alloc_node(0, 0, 0, 0, 0, TY_INT, 0, line, col); }
        else if lex == "float" { res = alloc_node(0, 0, 0, 0, 0, TY_FLOAT, 0, line, col); }
        else if lex == "bool" { res = alloc_node(0, 0, 0, 0, 0, TY_BOOL, 0, line, col); }
        else if lex == "string" { res = alloc_node(0, 0, 0, 0, 0, TY_STRING, 0, line, col); }
        else if lex == "char" { res = alloc_node(0, 0, 0, 0, 0, TY_CHAR, 0, line, col); }
        else if lex == "never" { res = alloc_node(0, 0, 0, 0, 0, TY_NEVER, 0, line, col); }
        else {
            ni := str_intern(lex);
            // Check for generic args: Box[int, ...]
            if check(T_LBRACKET) {
                advance_tok();
                first_arg := parse_type();
                arg_count : ., mut = 1;
                loop {
                    if check(T_RBRACKET) { break; }
                    if !check(T_COMMA) { break; }
                    advance_tok();
                    parse_type();
                    arg_count = arg_count + 1;
                }
                advance_tok();
                res = alloc_node(EXPR_GENERIC_APPLY, ni, first_arg, arg_count, 0, 0, 0, line, col);
            } else {
                res = alloc_node(EXPR_IDENT, 0, 0, 0, ni, 0, 0, line, col);
            }
        }
    } else if tok_k(t) == T_LBRACE {
        grow_diags(g_diag_count + 1);
        w64(g_diags, g_diag_count * 32, EC_P_EXPECTED);
        store_str_ptr(g_diags, g_diag_count * 32 + 8, "expected type after '->', got '{' — missing return type?");
        w64(g_diags, g_diag_count * 32 + 16, line);
        w64(g_diags, g_diag_count * 32 + 24, col);
        g_diag_count = g_diag_count + 1;
        res = alloc_node(0, 0, 0, 0, 0, TY_UNIT, 0, line, col);
    } else {
        grow_diags(g_diag_count + 1);
        w64(g_diags, g_diag_count * 32, EC_P_EXPECTED);
        store_str_ptr(g_diags, g_diag_count * 32 + 8, "expected type after '->'");
        w64(g_diags, g_diag_count * 32 + 16, line);
        w64(g_diags, g_diag_count * 32 + 24, col);
        g_diag_count = g_diag_count + 1;
        res = alloc_node(0, 0, 0, 0, 0, TY_UNIT, 0, line, col);
    }
    // Handle T? desugaring → Option[T]
    if check(T_QUESTION) {
        advance_tok();
        option_ni := str_intern("Option");
        res = alloc_node(EXPR_GENERIC_APPLY, option_ni, res, 1, 0, 0, 0, line, col);
    }
    return res;
}

fn unpack_type(typ: int) -> int {
    if ast_kind(typ) == 0 { return ast_type_val(typ); }
    return 0;
}

// --- Expression parsing ---
fn prec(k: int) -> int {
    if k == T_EQ { return 1; }
    if k == T_PLUS_EQ { return 1; }
    if k == T_MINUS_EQ { return 1; }
    if k == T_STAR_EQ { return 1; }
    if k == T_SLASH_EQ { return 1; }
    if k == T_PIPEPIPE { return 2; }
    if k == T_ANDAND { return 3; }
    if k == T_EQEQ || k == T_BANGEQ { return 4; }
    if k == T_LT || k == T_GT || k == T_LTEQ || k == T_GTEQ { return 5; }
    if k == T_PLUS || k == T_MINUS { return 6; }
    if k == T_STAR || k == T_SLASH || k == T_PERCENT { return 7; }
    return -1;
}

fn tok2op(k: int) -> int {
    if k == T_PLUS { return OP_ADD; }
    if k == T_MINUS { return OP_SUB; }
    if k == T_STAR { return OP_MUL; }
    if k == T_SLASH { return OP_DIV; }
    if k == T_PERCENT { return OP_MOD; }
    if k == T_EQEQ { return OP_EQ; }
    if k == T_BANGEQ { return OP_NE; }
    if k == T_LT { return OP_LT; }
    if k == T_GT { return OP_GT; }
    if k == T_LTEQ { return OP_LE; }
    if k == T_GTEQ { return OP_GE; }
    if k == T_ANDAND { return OP_AND; }
    if k == T_PIPEPIPE { return OP_OR; }
    return 0;
}

fn parse_expr() -> int {
    left := parse_binary(0);
    if check(T_DOTDOT) {
        t := advance_tok();
        right := parse_expr();
        return alloc_node(EXPR_RANGE, left, right, 0, 0, 0, 0, tok_ln(t), tok_cl(t));
    }
    return left;
}

fn parse_binary(mp: int) -> int {
    left : ., mut = parse_unary();
    loop {
        t := cur_tok();
        k := tok_k(t);
        p := prec(k);
        if p < mp { break; }
        advance_tok();
        right := parse_binary(p + 1);
        op := tok2op(k);
        // Compound assignment: += -= *= /=  →  a = a op b
        if k == T_PLUS_EQ {
            left = alloc_node(EXPR_ASSIGN, left, alloc_node(EXPR_BINARY, left, right, OP_ADD, 0, 0, 0, tok_ln(t), tok_cl(t)), 0, 0, 0, 0, tok_ln(t), tok_cl(t));
        } else if k == T_MINUS_EQ {
            left = alloc_node(EXPR_ASSIGN, left, alloc_node(EXPR_BINARY, left, right, OP_SUB, 0, 0, 0, tok_ln(t), tok_cl(t)), 0, 0, 0, 0, tok_ln(t), tok_cl(t));
        } else if k == T_STAR_EQ {
            left = alloc_node(EXPR_ASSIGN, left, alloc_node(EXPR_BINARY, left, right, OP_MUL, 0, 0, 0, tok_ln(t), tok_cl(t)), 0, 0, 0, 0, tok_ln(t), tok_cl(t));
        } else if k == T_SLASH_EQ {
            left = alloc_node(EXPR_ASSIGN, left, alloc_node(EXPR_BINARY, left, right, OP_DIV, 0, 0, 0, tok_ln(t), tok_cl(t)), 0, 0, 0, 0, tok_ln(t), tok_cl(t));
        // Convert assignment to EXPR_ASSIGN
        } else if k == T_EQ {
            left = alloc_node(EXPR_ASSIGN, left, right, 0, 0, 0, 0, tok_ln(t), tok_cl(t));
        } else {
            left = alloc_node(EXPR_BINARY, left, right, op, 0, 0, 0, tok_ln(t), tok_cl(t));
        }
    }
    return left;
}

fn parse_unary() -> int {
    t := cur_tok();
    if tok_k(t) == T_MINUS {
        advance_tok();
        op := parse_unary();
        return alloc_node(EXPR_UNARY, op, 0, UOP_NEG, 0, 0, 0, tok_ln(t), tok_cl(t));
    }
    if tok_k(t) == T_AMPERSAND {
        advance_tok();
        is_mut : ., mut = 0;
        if tok_k(cur_tok()) == T_MUT {
            is_mut = 1;
            advance_tok();
        }
        op := parse_unary();
        return alloc_node(EXPR_UNARY, op, 0, UOP_REF, is_mut, 0, 0, tok_ln(t), tok_cl(t));
    }
    if tok_k(t) == T_BANG {
        advance_tok();
        op := parse_unary();
        return alloc_node(EXPR_UNARY, op, 0, UOP_NOT, 0, 0, 0, tok_ln(t), tok_cl(t));
    }
    if tok_k(t) == T_MOVE {
        advance_tok();
        op := parse_unary();
        return alloc_node(EXPR_MOVE, op, 0, 0, 0, 0, 0, tok_ln(t), tok_cl(t));
    }
    if tok_k(t) == T_STAR {
        advance_tok();
        op := parse_unary();
        return alloc_node(EXPR_UNARY, op, 0, UOP_DEREF, 0, 0, 0, tok_ln(t), tok_cl(t));
    }
    node := parse_postfix();
    // Handle 'as' type cast: expr as Type
    if check(T_AS) {
        advance_tok();
        typ := parse_type();
        return alloc_node(EXPR_AS, node, typ, 0, 0, 0, 0, tok_ln(t), tok_cl(t));
    }
    return node;
}

fn parse_postfix() -> int {
    node : ., mut = parse_primary();
    loop {
        t := cur_tok();
        if tok_k(t) == T_LPAREN {
            advance_tok();
            af := -1;
            ac : ., mut = 0;
            if !check(T_RPAREN) {
                // Wrap each argument in EXPR_ARG(a=expr, b=next_arg) linked list
                first_expr := parse_expr();
                af = alloc_node(EXPR_ARG, first_expr, -1, 0, 0, 0, 0, tok_ln(t), tok_cl(t));
                ac = 1;
                prev_arg := af;
                loop {
                    if !check(T_COMMA) { break; }
                    advance_tok();
                    next_expr := parse_expr();
                    new_arg := alloc_node(EXPR_ARG, next_expr, -1, 0, 0, 0, 0, tok_ln(t), tok_cl(t));
                    ast_set_b(prev_arg, new_arg);
                    prev_arg = new_arg;
                    ac = ac + 1;
                }
            }
            advance_tok();
            // Check if this is an enum constructor
            // Cases: Some(42) or Option::Some(42)
            is_enum_con : ., mut = 0;
            name_idx : ., mut = -1;
            if ast_kind(node) == EXPR_IDENT {
                name_idx = ast_int_val(node);
            } else if ast_kind(node) == EXPR_FIELD && ast_data(node) != 0 {
                // Path access: Option::Some → EXPR_FIELD(Option, Some, data=1)
                name_idx = ast_int_val(node);
            }
            if name_idx >= 0 {
                name := istr_get(name_idx);
                c := get_char(name, 0);
                if str_cmp(c, "A") >= 0 && str_cmp(c, "Z") <= 0 {
                    is_enum_con = 1;
                }
            }
            if is_enum_con == 1 {
                node = alloc_node(EXPR_ENUM_CONSTRUCTOR, name_idx, af, ac, 0, 0, 0, tok_ln(t), tok_cl(t));
            } else {
                node = alloc_node(EXPR_CALL, node, af, ac, 0, 0, 0, tok_ln(t), tok_cl(t));
            }
            continue;
        }
        if tok_k(t) == T_DOT {
            advance_tok();
            f := advance_tok();
            ni := str_intern(tok_lx(f));
            // type_val: for numeric field names, stores index+1 (0 means struct field)
            tv : ., mut = 0;
            if tok_k(f) == T_INT {
                tv = tok_iv(f) + 1;  // +1 so default 0 means struct field
            }
            node = alloc_node(EXPR_FIELD, node, 0, 0, ni, tv, 0, tok_ln(t), tok_cl(t));
            continue;
        }
        if tok_k(t) == T_PATHSEP {
            advance_tok();
            f := advance_tok();
            ni := str_intern(tok_lx(f));
            node = alloc_node(EXPR_FIELD, node, 0, 0, ni, 0, 1, tok_ln(t), tok_cl(t));
            continue;
        }
        if tok_k(t) == T_LBRACKET {
            advance_tok();
            idx := parse_expr();
            advance_tok();
            node = alloc_node(EXPR_INDEX, node, idx, 0, 0, 0, 0, tok_ln(t), tok_cl(t));
            continue;
        }
        if tok_k(t) == T_QUESTION {
            advance_tok();
            node = alloc_node(EXPR_TRY, node, 0, 0, 0, 0, 0, tok_ln(t), tok_cl(t));
            continue;
        }
        break;
    }
    return node;
}

fn is_upper_first(s: string) -> bool {
    c := get_char(s, 0);
    if str_cmp(c, "A") >= 0 && str_cmp(c, "Z") <= 0 { return true; }
    return false;
}

fn parse_primary() -> int {
    t := cur_tok();
    if tok_k(t) == T_INT || (tok_k(t) >= T_INT_I8 && tok_k(t) <= T_INT_U64) {
        advance_tok();
        kn := tok_k(t);
        w : ., mut = 0;
        if kn == T_INT_I8 { w = W_I8; }
        else if kn == T_INT_I16 { w = W_I16; }
        else if kn == T_INT_I32 { w = W_I32; }
        else if kn == T_INT_I64 { w = W_I64; }
        else if kn == T_INT_U8 { w = W_U8; }
        else if kn == T_INT_U16 { w = W_U16; }
        else if kn == T_INT_U32 { w = W_U32; }
        else if kn == T_INT_U64 { w = W_U64; }
        return alloc_node(EXPR_INT, 0, 0, 0, tok_iv(t), TY_INT, w, tok_ln(t), tok_cl(t));
    }
    if tok_k(t) == T_FLOAT || tok_k(t) == T_FLOAT_F32 || tok_k(t) == T_FLOAT_F64 {
        advance_tok();
        kn := tok_k(t);
        w : ., mut = 0;
        if kn == T_FLOAT_F32 { w = W_F32; }
        else if kn == T_FLOAT_F64 { w = W_F64; }
        return alloc_node(EXPR_FLOAT, 0, 0, 0, tok_iv(t), TY_FLOAT, w, tok_ln(t), tok_cl(t));
    }
    if tok_k(t) == T_STRING {
        advance_tok();
        return alloc_node(EXPR_STRING, 0, 0, 0, str_intern(tok_lx(t)), TY_STRING, 0, tok_ln(t), tok_cl(t));
    }
    if tok_k(t) == T_TRUE { advance_tok(); return alloc_node(EXPR_BOOL, 0, 0, 0, 1, TY_BOOL, 0, tok_ln(t), tok_cl(t)); }
    if tok_k(t) == T_FALSE { advance_tok(); return alloc_node(EXPR_BOOL, 0, 0, 0, 0, TY_BOOL, 0, tok_ln(t), tok_cl(t)); }
    if tok_k(t) == T_NONE {
        advance_tok();
        return alloc_node(EXPR_ENUM_CONSTRUCTOR, str_intern("None"), -1, 0, 0, 0, 0, tok_ln(t), tok_cl(t));
    }
    if tok_k(t) == T_SOME {
        advance_tok();
        ni := str_intern("Some");
        if check(T_LPAREN) {
            // Parse Some(expr)
            advance_tok();
            val := parse_expr();
            advance_tok();  // consume )
            return alloc_node(EXPR_ENUM_CONSTRUCTOR, ni, val, 1, 0, 0, 0, tok_ln(t), tok_cl(t));
        }
        // Some without parens → treat as identifier (will be resolved by uppercase → enum constructor)
        return alloc_node(EXPR_IDENT, 0, 0, 0, ni, 0, 0, tok_ln(t), tok_cl(t));
    }
    if tok_k(t) == T_IDENT || tok_k(t) == T_SELF || tok_k(t) == T_UNDERSCORE {
        advance_tok();
        name := tok_lx(t);
        ni := str_intern(name);
        if check(T_LBRACE) && g_parse_no_struct_literal == 0 {
            advance_tok();
            ff := -1;
            fc : ., mut = 0;
            loop {
                if check(T_RBRACE) { break; }
                ft := advance_tok();
                fni := str_intern(tok_lx(ft));
                advance_tok();
                fv := parse_expr();
                ast_alloc(0, fv, 0, 0, 0, 0, 0, tok_ln(ft), tok_cl(ft));
                if fc == 0 { ff = g_ast_count - 1; }
                fc = fc + 1;
                if check(T_COMMA) { advance_tok(); }
            }
            advance_tok();
            return alloc_node(EXPR_STRUCT, ni, ff, fc, 0, 0, 0, tok_ln(t), tok_cl(t));
        }
        return alloc_node(EXPR_IDENT, 0, 0, 0, ni, 0, 0, tok_ln(t), tok_cl(t));
    }
    if tok_k(t) == T_LPAREN {
        advance_tok();
        saved_nsl := g_parse_no_struct_literal;
        g_parse_no_struct_literal = 0;
        e := parse_expr();
        g_parse_no_struct_literal = saved_nsl;
        if check(T_COMMA) {
            // Tuple: (e1, e2, ...)
            ef := e;
            ec : ., mut = 1;
            loop {
                advance_tok();  // consume comma
                parse_expr();   // next element (stored in consecutive g_ast slots)
                ec = ec + 1;
                if !check(T_COMMA) { break; }
            }
            advance_tok();  // consume )
            return alloc_node(EXPR_TUPLE, ef, ec, 0, 0, 0, 0, tok_ln(t), tok_cl(t));
        }
        advance_tok();
        return e;
    }
    if tok_k(t) == T_CHAR {
        advance_tok();
        return alloc_node(EXPR_CHAR, 0, 0, 0, str_intern(tok_lx(t)), TY_CHAR, 0, tok_ln(t), tok_cl(t));
    }
    if tok_k(t) == T_LBRACE { return parse_block(); }
    if tok_k(t) == T_IF { return parse_if_expr(); }
    if tok_k(t) == T_WHILE { return parse_while_expr(); }
    if tok_k(t) == T_LOOP { return parse_loop_expr(); }
    if tok_k(t) == T_FOR { return parse_for_expr(); }
    if tok_k(t) == T_GO {
        t2 := advance_tok();
        if check(T_SEMI) || check(T_RBRACE) || check(T_EOF) {
            add_error("Expected expression after `go`");
            return 0;
        }
        // go [N] expr  or  go var start end expr → desugared to for loop
        count : ., mut = -1;
        iter_var_ni : ., mut = -1;
        range_start : ., mut = -1;
        range_end : ., mut = -1;
        // Check for range syntax: go var start..end expr
        saved_pos : ., mut = g_token_pos;
        if tok_k(cur_tok()) == T_IDENT {
            vn := str_intern(tok_lx(cur_tok()));
            advance_tok();
            if tok_k(cur_tok()) == T_INT {
                iter_var_ni = vn;
                range_start = tok_iv(cur_tok());
                advance_tok();
                if tok_k(cur_tok()) == T_DOTDOT {
                    advance_tok();
                    if tok_k(cur_tok()) == T_INT {
                        range_end = tok_iv(cur_tok());
                        advance_tok();
                    }
                    body := parse_expr();
                    // Range go: keep range info in EXPR_GO for IR gen result collection
                    range_node := alloc_node(EXPR_RANGE, range_start, range_end, 0, 0, 0, 0, tok_ln(t2), tok_cl(t2));
                    return alloc_node(EXPR_GO, -1, body, iter_var_ni, 0, 0, range_node, tok_ln(t2), tok_cl(t2));
                }
            }
            // Not range mode — backtrack: regular go
            g_token_pos = saved_pos;
        }
        // Single: go expr  (no count-based batch)
        body := parse_expr();
        return alloc_node(EXPR_GO, count, body, 0, 0, 0, 0, tok_ln(t2), tok_cl(t2));
    }
    if tok_k(t) == T_AWAIT {
        t2 := advance_tok();
        val := parse_expr();
        return alloc_node(EXPR_AWAIT, val, 0, 0, 0, 0, 0, tok_ln(t2), tok_cl(t2));
    }
    if tok_k(t) == T_MATCH { return parse_match_expr(); }
    if tok_k(t) == T_UNSAFE {
        t2 := advance_tok();
        body := parse_block();
        return alloc_node(EXPR_UNSAFE, body, 0, 0, 0, 0, 0, tok_ln(t2), tok_cl(t2));
    }
    if tok_k(t) == T_LBRACKET {
        advance_tok();
        ef := -1;
        ec : ., mut = 0;
        if !check(T_RBRACKET) {
            ef = parse_expr();
            ec = 1;
            if check(T_SEMI) {
                // Repeat array: [value; count]
                advance_tok();
                ct := advance_tok();
                cnt : ., mut = tok_iv(ct);
                // Replicate element AST nodes
                ri : ., mut = 1;
                loop {
                    if ri >= cnt { break; }
                    ast_alloc(ast_kind(ef), ast_a(ef), ast_b(ef), ast_c(ef), ast_int_val(ef), ast_type_val(ef), ast_data(ef), ast_line(ef), ast_col(ef));
                    ri = ri + 1;
                }
                ec = cnt;
            } else {
                loop {
                    if !check(T_COMMA) { break; }
                    advance_tok();
                    parse_expr();  // parse remaining elements
                    ec = ec + 1;
                }
            }
        }
        advance_tok();
        return alloc_node(EXPR_ARRAY, ef, ec, 0, 0, 0, 0, tok_ln(t), tok_cl(t));
    }
    add_error("Unexpected token in expression");
    advance_tok();  // consume the unexpected token to avoid infinite loop
    return 0;
}

fn parse_block() -> int {
    t := advance_tok();
    local_stmts : string, mut;    local_stmts_cap : int, mut;
    local_stmts = alloc(256 * 8); local_stmts_cap = 256;
    sc : ., mut = 0;
    loop {
        if check(T_RBRACE) || check(T_EOF) { break; }
        if sc > 1024 { add_error("block too deep"); break; }
        st := parse_stmt();
        if sc < 256 {
            w64(local_stmts, sc * 8, st);
        }
        sc = sc + 1;
    }
    advance_tok();
    // Flush to global block_stmts array (isolated from nested blocks)
    si := g_block_stmt_count;
    i : ., mut = 0;
    loop {
        if i >= sc { break; }
        grow_block_stmts(g_block_stmt_count + 1);
        w64(g_block_stmts, g_block_stmt_count * 8, r64(local_stmts, i * 8));
        g_block_stmt_count = g_block_stmt_count + 1;
        i = i + 1;
    }
    return alloc_node(EXPR_BLOCK, si, sc, 0, 0, 0, 0, tok_ln(t), tok_cl(t));
}

fn is_new_var_decl() -> bool {
    p := cur_tok();
    if tok_k(p) != T_IDENT { return false; }
    // x := expr
    if tok_k(p + 1) == T_COLON_EQ { return true; }
    // x : type ...
    if tok_k(p + 1) == T_COLON { return true; }
    // a, b, ... : type ... or a, b, ... := ... (batch, any count)
    if tok_k(p + 1) == T_COMMA {
        i : ., mut = 2;
        loop {
            if tok_k(p + i) == T_IDENT && tok_k(p + i + 1) == T_COMMA { i = i + 2; continue; }
            if tok_k(p + i) == T_IDENT && (tok_k(p + i + 1) == T_COLON || tok_k(p + i + 1) == T_COLON_EQ) { return true; }
            break;
        }
    }
    return false;
}

fn parse_new_var_decl() -> int {
    t := cur_tok();
    names : string, mut;    names_cap : int, mut;
    names = alloc(64 * 8);
    names_cap = 64;
    nc : ., mut = 0;

    // Parse name list
    nt := advance_tok();
    w64(names, nc * 8, tok_lx(nt));
    nc = nc + 1;
    // Batch: a, b : type = ...
    if check(T_COMMA) {
        loop {
            if !check(T_COMMA) { break; }
            advance_tok(); // ,
            nt2 := advance_tok();
            w64(names, nc * 8, tok_lx(nt2));
            nc = nc + 1;
        }
    }

    typ : ., mut = -1;
    is_mut : ., mut = 0;   is_pub : ., mut = 0;

    values : string, mut;    values_cap : int, mut;
    values = alloc(64 * 8); values_cap = 64;
    vc : ., mut = 0;

    if check(T_COLON_EQ) {
        advance_tok();
        w64(values, vc * 8, parse_expr());
        vc = vc + 1;
        loop {
            if !check(T_COMMA) { break; }
            advance_tok();
            w64(values, vc * 8, parse_expr());
            vc = vc + 1;
        }
    } else {
        // consume ':'
        advance_tok();

        if tok_k(cur_tok()) == T_AUTO || tok_k(cur_tok()) == T_DOT {
            typ = -1;
            advance_tok();
        } else {
            typ = parse_type();
        }

        // Optional tags (built-in + plugin-extensible)
        if check(T_COMMA) {
            advance_tok();
            loop {
                if check(T_EQ) || check(T_SEMI) || check(T_EOF) { break; }
                tag_t := advance_tok();
                tag := tok_lx(tag_t);
                if tag == "mut" { is_mut = 1; }
                else if tag == "pub" { is_pub = 1; }
                else {
                    tni := str_intern(tag);
                    ei := find_plugin_entry(g_plugin_tags, g_plugin_tag_count, tni, -1);
                    if ei >= 0 {
                        pd := r64(g_plugin_tags, ei*24+16);
                        if pd != 0 { is_mut = 1; }
                    }
                }
                if !check(T_COMMA) { break; }
                advance_tok();
            }
        }

        // Parse values
        w64(values, 0 * 8, -1);
    if check(T_EQ) {
            advance_tok();
            w64(values, vc * 8, parse_expr());
            vc = vc + 1;
            loop {
                if !check(T_COMMA) { break; }
                advance_tok();
                w64(values, vc * 8, parse_expr());
                vc = vc + 1;
            }
        }
    }

    if check(T_SEMI) { advance_tok(); } // optional ;

    // Emit LET nodes. First returned directly, extras go to g_extra_lets (dynamic grow).
    first_node : ., mut = -1;
    i : ., mut = 0;
    loop {
        if i >= nc { break; }
        ni := str_intern(r64(names, i * 8));
        nv := r64(values, i * 8);
        node := alloc_node(EXPR_LET, ni, typ, nv, 0, 0, is_mut, tok_ln(t), tok_cl(t));
        if i == 0 {
            first_node = node;
        } else {
            if g_extra_lets_cap == 0 { g_extra_lets = alloc(128); g_extra_lets_cap = 16; }
            if g_extra_let_count < g_extra_lets_cap {
                w64(g_extra_lets, g_extra_let_count * 8, node);
                g_extra_let_count = g_extra_let_count + 1;
            }
        }
        i = i + 1;
    }

    return first_node;
}

fn parse_stmt() -> int {
    // Drain batch extras from previous call
    if g_extra_let_count > 0 {
        g_extra_let_count = g_extra_let_count - 1;
        return r64(g_extra_lets, g_extra_let_count * 8);
    }

    t := cur_tok();
    // New variable declaration syntax
    if tok_k(t) == T_IDENT && is_new_var_decl() {
        return parse_new_var_decl();
    }
    if tok_k(t) == T_RETURN {
        advance_tok();
        val : ., mut = -1;
        if !check(T_SEMI) && !check(T_RBRACE) { val = parse_expr(); }
        if check(T_SEMI) { advance_tok(); }
        return alloc_node(EXPR_RETURN, val, 0, 0, 0, 0, 0, tok_ln(t), tok_cl(t));
    }
    if tok_k(t) == T_YIELD {
        advance_tok();
        val := parse_expr();
        if check(T_SEMI) { advance_tok(); }
        return alloc_node(EXPR_YIELD, val, 0, 0, 0, 0, 0, tok_ln(t), tok_cl(t));
    }
    if tok_k(t) == T_BREAK {
        advance_tok();
        if check(T_SEMI) { advance_tok(); }
        return alloc_node(EXPR_BREAK, 0, 0, 0, 0, 0, 0, tok_ln(t), tok_cl(t));
    }
    if tok_k(t) == T_CONTINUE {
        advance_tok();
        if check(T_SEMI) { advance_tok(); }
        return alloc_node(EXPR_CONTINUE, 0, 0, 0, 0, 0, 0, tok_ln(t), tok_cl(t));
    }
    e := parse_expr();
    if check(T_SEMI) {
        advance_tok();
        return alloc_node(EXPR_STMT, e, 0, 0, 0, 0, 0, tok_ln(t), tok_cl(t));
    }
    return e;
}

fn parse_if_expr() -> int {
    t := advance_tok();
    // Disable struct literal parsing in condition context
    saved_nsl := g_parse_no_struct_literal;
    g_parse_no_struct_literal = 1;
    cond := parse_expr();
    g_parse_no_struct_literal = saved_nsl;
    tb := parse_block();
    eb : ., mut = -1;
    if check(T_ELSE) {
        advance_tok();
        if check(T_IF) { eb = parse_if_expr(); }
        else { eb = parse_block(); }
    }
    return alloc_node(EXPR_IF, cond, tb, eb, 0, 0, 0, tok_ln(t), tok_cl(t));
}

fn parse_loop_expr() -> int {
    t := advance_tok();
    body := parse_block();
    return alloc_node(EXPR_LOOP, body, 0, 0, 0, 0, 0, tok_ln(t), tok_cl(t));
}

fn parse_while_expr() -> int {
    t := advance_tok();
    cond := parse_expr();
    body := parse_block();
    return alloc_node(EXPR_WHILE, cond, body, 0, 0, 0, 0, tok_ln(t), tok_cl(t));
}

fn parse_for_expr() -> int {
    t := advance_tok();
    vt := advance_tok();
    vn := str_intern(tok_lx(vt));
    advance_tok();
    iter := parse_expr();
    body : ., mut = -1;
    // Core supports: for var := range_expr { body }
    // C-style (for var := init ; cond ; post) is NOT supported;
    // skip to the first '{' to avoid consuming subsequent statements.
    if !check(T_LBRACE) {
        loop {
            if check(T_LBRACE) { break; }
            if check(T_EOF) { break; }
            advance_tok();
        }
    }
    if check(T_LBRACE) {
        body = parse_block();
    }
    return alloc_node(EXPR_FOR, vn, iter, body, 0, 0, 0, tok_ln(t), tok_cl(t));
}

fn parse_match_expr() -> int {
    t := advance_tok();
    g_parse_no_struct_literal = 1;
    expr := parse_expr();
    g_parse_no_struct_literal = 0;
    advance_tok();
    af := -1;
    al : ., mut = -1;  // last arm index
    ac : ., mut = 0;
    loop {
        if check(T_RBRACE) || check(T_EOF) { break; }
        pat := parse_pattern();
        advance_tok();
        body := parse_expr();
        if check(T_COMMA) { advance_tok(); }
        n := alloc_node(EXPR_ARM, pat, body, -1, 0, 0, 0, tok_ln(t), tok_cl(t));
        if ac == 0 { af = n; }
        if al >= 0 { ast_set_c(al, n); }  // link previous arm to this one
        al = n;
        ac = ac + 1;
    }
    advance_tok();
    return alloc_node(EXPR_MATCH, expr, af, ac, 0, 0, 0, tok_ln(t), tok_cl(t));
}

fn parse_pattern() -> int {
    t := cur_tok();
    if tok_k(t) == T_UNDERSCORE {
        advance_tok();
        return alloc_node(EXPR_WILDCARD, 0, 0, 0, 0, 0, 0, tok_ln(t), tok_cl(t));
    }
    if tok_k(t) == T_INT || (tok_k(t) >= T_INT_I8 && tok_k(t) <= T_INT_U64) {
        advance_tok();
        kn := tok_k(t);
        w : ., mut = 0;
        if kn == T_INT_I8 { w = W_I8; }
        else if kn == T_INT_I16 { w = W_I16; }
        else if kn == T_INT_I32 { w = W_I32; }
        else if kn == T_INT_I64 { w = W_I64; }
        else if kn == T_INT_U8 { w = W_U8; }
        else if kn == T_INT_U16 { w = W_U16; }
        else if kn == T_INT_U32 { w = W_U32; }
        else if kn == T_INT_U64 { w = W_U64; }
        return alloc_node(EXPR_INT, 0, 0, 0, tok_iv(t), TY_INT, w, tok_ln(t), tok_cl(t));
    }
    if tok_k(t) == T_STRING {
        advance_tok();
        return alloc_node(EXPR_STRING, 0, 0, 0, str_intern(tok_lx(t)), TY_STRING, 0, tok_ln(t), tok_cl(t));
    }
    if tok_k(t) == T_CHAR {
        advance_tok();
        return alloc_node(EXPR_CHAR, 0, 0, 0, str_intern(tok_lx(t)), TY_CHAR, 0, tok_ln(t), tok_cl(t));
    }
    if tok_k(t) == T_TRUE {
        advance_tok();
        return alloc_node(EXPR_BOOL, 0, 0, 0, 1, TY_BOOL, 0, tok_ln(t), tok_cl(t));
    }
    if tok_k(t) == T_FALSE {
        advance_tok();
        return alloc_node(EXPR_BOOL, 0, 0, 0, 0, TY_BOOL, 0, tok_ln(t), tok_cl(t));
    }
    if tok_k(t) == T_IDENT || tok_k(t) == T_NONE || tok_k(t) == T_SOME {
        advance_tok();
        name := tok_lx(t);
        ni := str_intern(name);
        // Handle Enum.Variant pattern
        if check(T_DOT) {
            advance_tok();
            vt := advance_tok();
            name = name + "." + tok_lx(vt);
            ni = str_intern(name);
            if check(T_LPAREN) {
                // Enum.Variant(subpat, ...)
                advance_tok();
                sub_first : ., mut = -1;
                ac : ., mut = 0;
                if !check(T_RPAREN) {
                    sub_first = parse_pattern();
                    ac = 1;
                    loop {
                        if !check(T_COMMA) { break; }
                        advance_tok();
                        parse_pattern();
                        ac = ac + 1;
                    }
                }
                advance_tok();
                return alloc_node(EXPR_ENUMPAT, ni, sub_first, ac, 0, 0, 0, tok_ln(t), tok_cl(t));
            }
            return alloc_node(EXPR_ENUMPAT, ni, 0, 0, 0, 0, 0, tok_ln(t), tok_cl(t));
        }
        if check(T_LPAREN) {
            advance_tok();
            sub_first : ., mut = -1;
            ac : ., mut = 0;
            if !check(T_RPAREN) {
                sub_first = parse_pattern();
                ac = 1;
                loop {
                    if !check(T_COMMA) { break; }
                    advance_tok();
                    parse_pattern();
                    ac = ac + 1;
                }
            }
            advance_tok();
            return alloc_node(EXPR_ENUMPAT, ni, sub_first, ac, 0, 0, 0, tok_ln(t), tok_cl(t));
        }
        if check(T_LBRACE) {
            // Struct pattern: Name { field = pat, ... }
            advance_tok();
            ff := -1;
            fc : ., mut = 0;
            loop {
                if check(T_RBRACE) { break; }
                ft := advance_tok();
                fni := str_intern(tok_lx(ft));
                advance_tok(); // =
                fp := parse_pattern();
                ast_alloc(0, fp, 0, 0, 0, 0, 0, tok_ln(ft), tok_cl(ft));
                if fc == 0 { ff = g_ast_count - 1; }
                fc = fc + 1;
                if check(T_COMMA) { advance_tok(); }
            }
            advance_tok();
            return alloc_node(EXPR_STRUCTPAT, ni, ff, fc, 0, 0, 0, tok_ln(t), tok_cl(t));
        }
        if is_upper_first(name) {
            return alloc_node(EXPR_ENUMPAT, ni, 0, 0, 0, 0, 0, tok_ln(t), tok_cl(t));
        }
        return alloc_node(EXPR_IDENT, 0, 0, 0, ni, 0, 0, tok_ln(t), tok_cl(t));
    }
    advance_tok();
    return 0;
}

// --- Top-level declarations ---

fn parse_generics() -> int {
    if check(T_LBRACKET) {
        advance_tok(); // [
        gc := 0;
        loop {
            if check(T_RBRACKET) { break; }
            if gc >= MAX_GENERICS { break; }
            gt := advance_tok();
            // Store generic param name — caller copies into its own array
            // We just consume and count; caller uses get_tok_text
            gc = gc + 1;
            if !check(T_COMMA) { break; }
            advance_tok();
        }
        advance_tok(); // ]
        return gc;
    }
    return 0;
}

fn parse_generics_into(names: string, constrs: string) -> int {
    // Initialize constraints to -1 (no constraint)
    ci : ., mut = 0;
    loop { if ci >= 4 { break; } w64(constrs, ci * 8, -1); ci = ci + 1; }
    if check(T_LBRACKET) {
        advance_tok(); // [
        gc : ., mut = 0;
        loop {
            if check(T_RBRACKET) { break; }
            if gc >= MAX_GENERICS { break; }
            gt := advance_tok();
            w64(names, gc * 8, tok_lx(gt));
            // Check for constraint: T: Interface
            w64(constrs, gc * 8, -1);
            if check(T_COLON) {
                advance_tok();
                ct := advance_tok();
                w64(constrs, gc * 8, str_intern(tok_lx(ct)));
            }
            gc = gc + 1;
            if !check(T_COMMA) { break; }
            advance_tok();
        }
        advance_tok(); // ]
        return gc;
    }
    return 0;
}

fn save_func_generics(fi: int, names: string, count: int) {
    fi_set_generic_count(fi, count);
    gi : ., mut = 0;
    loop {
        if gi >= count { break; }
        ni := str_intern(r64(names, gi * 8));
        fi_set_generic_name(fi, gi, ni);
        gi = gi + 1;
    }
}

fn save_func_gen_constrs(fi: int, constrs: string, count: int) {
    gi : ., mut = 0;
    loop {
        if gi >= count { break; }
        if r64(constrs, gi * 8) >= 0 {
            idx := fi * MAX_GENERICS + gi;
            grow_gen_constr(idx + 1);
            w64(g_generic_constr, idx * 8, r64(constrs, gi * 8));
            if idx + 1 > g_generic_constr_count { g_generic_constr_count = idx + 1; }
        }
        gi = gi + 1;
    }
}

fn add_func(name: string, pc: int, rt: int, an: int) -> int {
    idx := g_func_count;
    grow_funcs(idx + 1);
    ni := str_intern(name);
    fi_set_name(idx, ni);
    fi_set_param_count(idx, pc);
    fi_set_return_type(idx, rt);
    fi_set_ast_node(idx, an);
    g_func_count = idx + 1;
    return idx;
}

fn add_struct(name: string) -> int {
    idx := g_struct_count;
    grow_structs(idx + 1);
    ni := str_intern(name);
    base := idx * ESZ_STRUCTINFO;
    // Zero the entire struct entry
    zi : ., mut = 0;
    loop {
        if zi >= ESZ_STRUCTINFO { break; }
        w8(g_structs, base + zi, 0);
        zi = zi + 1;
    }
    w64(g_structs, base + OFF_SI_NAME, ni);
    g_struct_count = idx + 1;
    return idx;
}

fn add_enum(name: string) -> int {
    idx := g_enum_count;
    grow_enums(idx + 1);
    ni := str_intern(name);
    base := idx * ESZ_ENUMINFO;
    // Zero the entire enum entry
    zi : ., mut = 0;
    loop {
        if zi >= ESZ_ENUMINFO { break; }
        w8(g_enums, base + zi, 0);
        zi = zi + 1;
    }
    w64(g_enums, base + OFF_EI_NAME, ni);
    g_enum_count = idx + 1;
    return idx;
}

fn parse_body(fn_name: string, fn_ni: int, fn_line: int, fn_col: int) {
    gnames : string, mut;    gnames_cap : int, mut;
    gconstrs : string, mut;    gconstrs_cap : int, mut;
    gconstrs = alloc(64 * 8); gconstrs_cap = 64;
    gc := parse_generics_into(gnames, gconstrs);

    advance_tok(); // (
    pf : ., mut = -1;
    pc : ., mut = 0;
    if !check(T_RPAREN) {
        loop {
            // Handle self/&self/&mut self params
            if tok_k(cur_tok()) == T_SELF {
                pt := advance_tok();
                if pf < 0 { pf = g_ast_count; }
                alloc_node(EXPR_PARAM, str_intern("self"), 0, 0, 1, 0, 0, tok_ln(pt), tok_cl(pt));
                pc = pc + 1;
                if check(T_COLON) { advance_tok(); parse_type(); }
                if !check(T_COMMA) { break; }
                advance_tok();
                continue;
            }
            if tok_k(cur_tok()) == T_AMPERSAND && tok_k(cur_tok()+1) == T_MUT && tok_k(cur_tok()+2) == T_SELF {
                pt := advance_tok();
                advance_tok();
                advance_tok();
                if pf < 0 { pf = g_ast_count; }
                alloc_node(EXPR_PARAM, str_intern("self"), 0, 0, 3, 0, 0, tok_ln(pt), tok_cl(pt));
                pc = pc + 1;
                if check(T_COLON) { advance_tok(); parse_type(); }
                if !check(T_COMMA) { break; }
                advance_tok();
                continue;
            }
            if tok_k(cur_tok()) == T_AMPERSAND && tok_k(cur_tok()+1) == T_SELF {
                pt := advance_tok();
                advance_tok();
                if pf < 0 { pf = g_ast_count; }
                alloc_node(EXPR_PARAM, str_intern("self"), 0, 0, 2, 0, 0, tok_ln(pt), tok_cl(pt));
                pc = pc + 1;
                if check(T_COLON) { advance_tok(); parse_type(); }
                if !check(T_COMMA) { break; }
                advance_tok();
                continue;
            }
            // Variadic: ...name:type
            if check(T_DOTDOTDOT) {
                advance_tok(); vt := advance_tok();
                vn := str_intern(tok_lx(vt)); advance_tok();
                vty := parse_type();
                if pf < 0 { pf = g_ast_count; }
                alloc_node(EXPR_PARAM, vn, 0, 0, -1, 0, vty, tok_ln(vt), tok_cl(vt));
                pc = pc + 1;
                if !check(T_COMMA) { break; } advance_tok(); continue;
            }
            pt := advance_tok();
            pn := str_intern(tok_lx(pt));
            advance_tok();
            pty := parse_type();
            if pf < 0 { pf = g_ast_count; }
            alloc_node(EXPR_PARAM, pn, 0, 0, 0, unpack_type(pty), pty, tok_ln(pt), tok_cl(pt));
            pc = pc + 1;
            if !check(T_COMMA) { break; }
            advance_tok();
        }
    }
    advance_tok(); // )
    rt : ., mut = 0;
    rtv : ., mut = TY_UNIT;
    if check(T_ARROW) {
        advance_tok(); // ->
        rt = parse_type();
        rtv = unpack_type(rt);
    }

    body : ., mut = -1;
    if check(T_LBRACE) {
        body = parse_block();
    } else {
        advance_tok(); // =
        body = parse_expr();
        advance_tok(); // ;
    }

    fn_node := alloc_node(EXPR_FN, fn_ni, pf, pc, rtv, rt, body, fn_line, fn_col);
    fi := add_func(fn_name, pc, rtv, fn_node);
    if fi >= 0 && gc > 0 { save_func_generics(fi, gnames, gc); save_func_gen_constrs(fi, gconstrs, gc); }
    // Store param types in FuncInfo
    if fi >= 0 { pstore_i : ., mut = 0; pstore_n : ., mut = pf;
        loop { if pstore_i >= pc { break; } if pstore_n < 0 { break; }
            if ast_kind(pstore_n) == EXPR_PARAM {
                fi_set_param_type(fi, pstore_i, ast_type_val(pstore_n));
                pstore_i = pstore_i + 1; }
            pstore_n = pstore_n + 1; } }
}

fn parse_declaration() {
    ip : ., mut = 0;
    if check(T_PUB) { ip = 1; advance_tok(); }

    // fn / flow
    if check(T_FN) || check(T_FLOW) {
        is_flow : ., mut = 0;
        if check(T_FLOW) { is_flow = 1; }
        t := advance_tok();
        nt := advance_tok();
        name := tok_lx(nt);
        ni := str_intern(name);
        parse_body(name, ni, tok_ln(t), tok_cl(t));
        if is_flow != 0 {
            // Flow function — checker detects yield statements in body
            // to skip return type check (yield != return)
        }
        return;
    }

    // struct
    if check(T_STRUCT) {
        t := advance_tok();
        nt := advance_tok();
        name := tok_lx(nt);
        sg_names : string, mut;    sg_names_cap : int, mut;
    sg_names = alloc(64 * 8); sg_names_cap = 64;
        sg_dummy : string, mut;    sg_dummy_cap : int, mut;
    sg_dummy = alloc(64 * 8); sg_dummy_cap = 64;
        sg_count := parse_generics_into(sg_names, sg_dummy);
        advance_tok(); // {

        si := add_struct(name);
        if si >= 0 {
            if sg_count > 0 {
                w64(g_structs, si * ESZ_STRUCTINFO + OFF_SI_GENERIC_COUNT, sg_count);
                sgi : ., mut = 0;
                loop {
                    if sgi >= sg_count { break; }
                    w64(g_structs, si * ESZ_STRUCTINFO + OFF_SI_GENERIC_NAMES + sgi * 8, str_intern(r64(sg_names, sgi * 8)));
                    sgi = sgi + 1;
                }
            }
            fc : ., mut = 0;
            loop {
                if check(T_RBRACE) { break; }
                ft := advance_tok();
                fn2 := tok_lx(ft);
                w64(g_structs, si * ESZ_STRUCTINFO + OFF_SI_FIELD_NAMES + fc * 8, str_intern(fn2));
                advance_tok();
                fty := parse_type();
                w64(g_structs, si * ESZ_STRUCTINFO + OFF_SI_FIELD_TYPES + fc * 8, unpack_type(fty));
                w64(g_structs, si * ESZ_STRUCTINFO + OFF_SI_FIELD_TYPE_NODES + fc * 8, fty);
                fc = fc + 1;
                if check(T_COMMA) { advance_tok(); }
            }
            w64(g_structs, si * ESZ_STRUCTINFO + OFF_SI_FIELD_COUNT, fc);
        }
        advance_tok();
        return;
    }

    // enum
    if check(T_ENUM) {
        t := advance_tok();
        nt := advance_tok();
        name := tok_lx(nt);
        eg_names : string, mut;    eg_names_cap : int, mut;
    eg_names = alloc(64 * 8); eg_names_cap = 64;
        eg_dummy : string, mut;    eg_dummy_cap : int, mut;
    eg_dummy = alloc(64 * 8); eg_dummy_cap = 64;
        eg_count := parse_generics_into(eg_names, eg_dummy);
        advance_tok();

        ei := add_enum(name);
        if ei >= 0 {
            if eg_count > 0 {
                w64(g_enums, ei * ESZ_ENUMINFO + OFF_EI_GENERIC_COUNT, eg_count);
                egi : ., mut = 0;
                loop {
                    if egi >= eg_count { break; }
                    w64(g_enums, ei * ESZ_ENUMINFO + OFF_EI_GENERIC_NAMES + egi * 8, str_intern(r64(eg_names, egi * 8)));
                    egi = egi + 1;
                }
            }
            vc : ., mut = 0;
            loop {
                if check(T_RBRACE) { break; }
                vt := advance_tok();
                vname := tok_lx(vt);
                w64(g_enums, ei * ESZ_ENUMINFO + OFF_EI_VARIANTS + vc * OFF_EV_SIZE + OFF_EV_NAME, str_intern(vname));
                tc : ., mut = 0;
                if check(T_LPAREN) {
                    advance_tok();
                    loop {
                        if check(T_RPAREN) { break; }
                        fty := parse_type();
                        w64(g_enums, ei * ESZ_ENUMINFO + OFF_EI_VARIANTS + vc * OFF_EV_SIZE + OFF_EV_TYPES + tc * 8, unpack_type(fty));
                        tc = tc + 1;
                        if !check(T_COMMA) { break; }
                        advance_tok();
                    }
                    advance_tok();
                }
                w64(g_enums, ei * ESZ_ENUMINFO + OFF_EI_VARIANTS + vc * OFF_EV_SIZE + OFF_EV_TYPE_COUNT, tc);
                vc = vc + 1;
                if check(T_COMMA) { advance_tok(); }
            }
            w64(g_enums, ei * ESZ_ENUMINFO + OFF_EI_VARIANT_COUNT, vc);
        }
        advance_tok();
        return;
    }

    // interface declaration
    if check(T_INTERFACE) {
        t := advance_tok();
        nt := advance_tok();
        iface_name := tok_lx(nt);
        iface_ni := str_intern(iface_name);
        ig_names : string, mut;    ig_names_cap : int, mut;
    ig_names = alloc(64 * 8); ig_names_cap = 64;
        ig_dummy : string, mut;    ig_dummy_cap : int, mut;
    ig_dummy = alloc(64 * 8); ig_dummy_cap = 64;
        ig_count := parse_generics_into(ig_names, ig_dummy);
        advance_tok(); // {

        // Allocate interface entry
        grow_ifaces(g_iface_count + 1);
        iface_base := g_iface_count * ESZ_IFACEINFO;
        // Zero it out
        zi : ., mut = 0;
        loop { if zi >= ESZ_IFACEINFO { break; } w8(g_ifaces, iface_base + zi, 0); zi = zi + 1; }
        w64(g_ifaces, iface_base + OFF_IF_NAME, iface_ni);
        w64(g_ifaces, iface_base + OFF_IF_GENERIC_COUNT, ig_count);
        method_count : ., mut = 0;

        loop {
            if check(T_RBRACE) { break; }
            if check(T_FN) {
                advance_tok(); // fn
                mt := advance_tok(); // method name
                method_ni := str_intern(tok_lx(mt));
                advance_tok(); // (

                // Parse params with types (handle self, &self, &mut self, name: Type)
                pc : ., mut = 0;
                param_tis : string, mut;    param_tis_cap : int, mut;
    param_tis = alloc(128 * 8); param_tis_cap = 128;
                pi2 : ., mut = 0;
                loop { if pi2 >= 8 { break; } w64(param_tis, pi2 * 8, TY_UNIT); pi2 = pi2 + 1; }
                if !check(T_RPAREN) {
                    loop {
                        fst := cur_tok();
                        // Handle &self / &mut self / self
                        if tok_k(fst) == T_AMPERSAND || tok_k(fst) == T_SELF {
                            if tok_k(fst) == T_AMPERSAND {
                                advance_tok(); // &
                                if check(T_MUT) { advance_tok(); } // mut
                            }
                            nt2 := advance_tok(); // self
                            if pc < 8 { w64(param_tis, pc * 8, 0); }  // match function's default for &self
                            pc = pc + 1;
                        } else {
                            advance_tok(); // param name
                            advance_tok(); // :
                            ptype := parse_type();
                            if pc < 8 { w64(param_tis, pc * 8, unpack_type(ptype)); }
                            pc = pc + 1;
                        }
                        if !check(T_COMMA) { break; }
                        advance_tok();
                    }
                }
                advance_tok(); // )

                // Parse return type
                ret_ti : ., mut = TY_UNIT;
                if check(T_ARROW) {
                    advance_tok();
                    ret_node := parse_type();
                    ret_ti = unpack_type(ret_node);
                }
                advance_tok(); // ;

                // Store method in interface entry (with overflow checks)
                if method_count >= 16 {
                    grow_diags(g_diag_count + 1);
                    w64(g_diags, g_diag_count * 32, EC_P_FIELD_SYNTAX);
                    store_str_ptr(g_diags, g_diag_count * 32 + 8, "interface '" + iface_name + "' exceeds max 16 methods");
                    w64(g_diags, g_diag_count * 32 + 16, tok_ln(t)); w64(g_diags, g_diag_count * 32 + 24, tok_cl(t));
                    g_diag_count = g_diag_count + 1;
                } else {
                    mbase := iface_base + OFF_IF_METHODS + method_count * ESZ_IFMETHOD;
                    w64(g_ifaces, mbase + OFF_IFM_NAME, method_ni);
                    w64(g_ifaces, mbase + OFF_IFM_PARAM_COUNT, pc);
                    w64(g_ifaces, mbase + OFF_IFM_RET_TI, ret_ti);
                    pj : ., mut = 0;
                    loop { if pj >= 8 || pj >= pc { break; }
                        w64(g_ifaces, mbase + OFF_IFM_PARAM_TYPES + pj * 8, r64(param_tis, pj * 8));
                        pj = pj + 1; }
                    if pc > 8 {
                        grow_diags(g_diag_count + 1);
                        w64(g_diags, g_diag_count * 32, EC_P_PARAM_TYPE);
                        store_str_ptr(g_diags, g_diag_count * 32 + 8, "method '" + istr_get(method_ni) + "' in interface exceeds max 8 params");
                        w64(g_diags, g_diag_count * 32 + 16, tok_ln(t)); w64(g_diags, g_diag_count * 32 + 24, tok_cl(t));
                        g_diag_count = g_diag_count + 1;
                    }
                }
                method_count = method_count + 1;
            } else { advance_tok(); }
        }
        w64(g_ifaces, iface_base + OFF_IF_METHOD_COUNT, method_count);
        g_iface_count = g_iface_count + 1;
        advance_tok(); // }
        return;
    }

    // impl block (impl Type { ... } or impl Interface for Type { ... })
    if check(T_IMPL) {
        t := advance_tok();
        first_nt := advance_tok();
        first_name := tok_lx(first_nt);
        first_ni := str_intern(first_name);
        trait_ni : ., mut = -1;
        type_ni : ., mut = first_ni;
        type_name : ., mut = first_name;
        if check(T_FOR) {
            advance_tok();
            trait_ni = first_ni;
            type_nt := advance_tok();
            type_name = tok_lx(type_nt);
            type_ni = str_intern(type_name);
        }
        advance_tok(); // {
        loop {
            if check(T_RBRACE) { break; }
            if check(T_FN) {
                ft := advance_tok();
                method_nt := advance_tok();
                method_name := tok_lx(method_nt);
                method_ni := str_intern(method_name);
                mangled := type_name + "." + method_name;
                mangled_ni := str_intern(mangled);
                parse_body(mangled, mangled_ni, tok_ln(ft), tok_cl(ft));
                // Register in method lookup table
                grow_methods(g_method_count + 1);
                w64(g_methods, g_method_count * 24, type_ni);
                w64(g_methods, g_method_count * 24 + 8, method_ni);
                w64(g_methods, g_method_count * 24 + 16, mangled_ni);
                g_method_count = g_method_count + 1;
            } else {
                advance_tok();
            }
        }
        advance_tok(); // }
        // Store impl-for relationship after processing all methods
        if trait_ni >= 0 {
            grow_impl_for(g_impl_for_count + 1);
            w64(g_impl_for, g_impl_for_count * 16, trait_ni);
            w64(g_impl_for, g_impl_for_count * 16 + 8, type_ni);
            g_impl_for_count = g_impl_for_count + 1;
        }
        return;
    }

    // type alias
    if check(T_TYPE) {
        advance_tok();
        nt := advance_tok();
        name_idx := str_intern(tok_lx(nt));
        advance_tok();
        type_node := parse_type();
        advance_tok(); // ;
        grow_type_aliases(g_type_alias_count + 1);
        w64(g_type_aliases, g_type_alias_count * 16, name_idx);
        w64(g_type_aliases, g_type_alias_count * 16 + 8, type_node);
        g_type_alias_count = g_type_alias_count + 1;
        return;
    }

    // mod declaration: mod name; or mod path::name; or mod name { ... }
    if check(T_MOD) {
        t := advance_tok();
        nt := advance_tok();
        path_name := tok_lx(nt);
        // Collect full path: mod a::b::c;
        loop {
            if check(T_PATHSEP) {
                advance_tok();
                nt2 := advance_tok();
                path_name = path_name + "::" + tok_lx(nt2);
            } else { break; }
        }
        mod_ni := str_intern(path_name);
        // Store mod path for checker registration
        grow_mod_paths(g_mod_path_count + 1);
        w64(g_mod_path_names, g_mod_path_count * 8, mod_ni);
        g_mod_path_count = g_mod_path_count + 1;
        if check(T_LBRACE) {
            // mod name { ... } — consume block contents
            push_scope();
            advance_tok();
            depth : ., mut = 1;
            loop {
                if depth <= 0 { break; }
                tk := advance_tok();
                if tok_k(tk) == T_RBRACE { depth = depth - 1; }
                else if tok_k(tk) == T_LBRACE { depth = depth + 1; }
                else if tok_k(tk) == T_EOF { break; }
            }
        } else {
            if check(T_SEMI) { advance_tok(); }
        }
        return;
    }

    // import/fileid declarations are already skipped in parse_all() loop.
    // If we reach here, the token was NOT T_IMPORT/T_FILEID.

    // New syntax global variable declaration
    if check(T_IDENT) && is_new_var_decl() {
        node := parse_new_var_decl();
        grow_global_lets(g_global_let_count + 1);
        w64(g_global_lets, g_global_let_count * 8, node);
        g_global_let_count = g_global_let_count + 1;
        // Drain batch extras to globals
        _drained : ., mut = 0;
        loop {
            if g_extra_let_count <= 0 { break; }
            g_extra_let_count = g_extra_let_count - 1;
            grow_global_lets(g_global_let_count + 1);
            w64(g_global_lets, g_global_let_count * 8, r64(g_extra_lets, g_extra_let_count * 8));
            g_global_let_count = g_global_let_count + 1;
            _drained = _drained + 1;
        }
        return;
    }

    advance_tok();
}

fn parse_all() {
    g_ast_count = 0;
    g_token_pos = 0;
    g_global_let_count = 0;
    g_global_lets_cap = 0;
    g_func_count = 0;
    g_struct_count = 0;
    g_enum_count = 0;
    g_type_alias_count = 0; g_type_alias_cap = 0;
    g_method_count = 0; g_method_cap = 0;
    g_loop_depth = 0; g_loop_stack_cap = 0;
    g_extra_let_count = 0;
    g_block_stmt_count = 0;
    g_error_count = 0;
    g_mod_path_count = 0; g_mod_path_cap = 0;
    g_iface_count = 0; g_iface_cap = 0;
    g_impl_for_count = 0; g_impl_for_cap = 0;
    g_generic_constr_count = 0; g_generic_constr_cap = 0;

    ci : ., mut = 0;
    loop {
        // Skip import/fileid tokens
        loop {
            tk := tok_k(cur_tok());
            if tk == T_EOF { return; }
            if tk != T_IMPORT && tk != T_FILEID { break; }
            advance_tok();
        }
        t_cur := cur_tok();
        t_kind := tok_k(t_cur);
        if t_kind == T_EOF { break; }
        if ci > 5 { ci = 0; }
        prev_ast := g_ast_count;
        parse_declaration();
        if tok_k(cur_tok()) == T_EOF { break; }
        ast_grown := g_ast_count - prev_ast;
        if ast_grown > 10000 { break; }
        ci = ci + 1;
    }
}
