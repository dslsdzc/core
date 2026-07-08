// Lexer: tokenizes Core source code using int-based character access.
// Character comparisons use ASCII code constants rather than string allocs.

// Global compiler state
g_source : string, mut;
g_source_len : int, mut;     // cached str_len(g_source), set in tokenize()
g_pos : int, mut;
g_line : int, mut;
g_col : int, mut;

// Character constants
C_SP : int = 32; C_TB : int = 9; C_LF : int = 10; C_CR : int = 13;
C_NL : int = 10;
C_SLASH : int = 47; C_STAR : int = 42;
C_BSLASH : int = 92; C_SQUOTE : int = 39; C_DQUOTE : int = 34;
C_LPAREN : int = 40; C_RPAREN : int = 41;
C_LBRACE : int = 123; C_RBRACE : int = 125;
C_LBRACK : int = 91; C_RBRACK : int = 93;
C_COMMA : int = 44; C_SEMI : int = 59; C_COLON : int = 58;
C_DOT : int = 46; C_EQ : int = 61; C_BANG : int = 33;
C_LT : int = 60; C_GT : int = 62; C_PLUS : int = 43;
C_DASH : int = 45; C_PERCENT : int = 37; C_AMP : int = 38;
C_PIPE : int = 124; C_UNDER : int = 95; C_AT : int = 64;
C_QUES : int = 63;

fn is_alpha(c: int) -> int {
    if c >= 65 && c <= 90 { return 1; }
    if c >= 97 && c <= 122 { return 1; }
    if c == 95 { return 1; }
    return 0;
}
fn is_digit(c: int) -> int {
    if c >= 48 && c <= 57 { return 1; }
    return 0;
}
fn is_ident_char(c: int) -> int {
    if is_alpha(c) != 0 { return 1; }
    if is_digit(c) != 0 { return 1; }
    return 0;
}

fn cur_char_at(pos: int) -> int {
    if pos >= str_len(g_source) { return 0; }
    return load8(g_source, pos);
}
fn peek_at(pos: int) -> int {
    if pos + 1 >= str_len(g_source) { return 0; }
    return load8(g_source, pos + 1);
}

fn lookup_keyword(s: string) -> int {
    if s == "fn" { return T_FN; }
    if s == "let" { return T_LET; }
    if s == "mut" { return T_MUT; }
    if s == "return" { return T_RETURN; }
    if s == "if" { return T_IF; }
    if s == "else" { return T_ELSE; }
    if s == "loop" { return T_LOOP; }
    if s == "while" { return T_WHILE; }
    if s == "for" { return T_FOR; }
    if s == "break" { return T_BREAK; }
    if s == "continue" { return T_CONTINUE; }
    if s == "true" { return T_TRUE; }
    if s == "false" { return T_FALSE; }
    if s == "struct" { return T_STRUCT; }
    if s == "enum" { return T_ENUM; }
    if s == "impl" { return T_IMPL; }
    if s == "match" { return T_MATCH; }
    if s == "import" { return T_IMPORT; }
    if s == "pub" { return T_PUB; }
    if s == "int" || s == "i8" || s == "i16" || s == "i32" || s == "i64" { return T_INT_TYPE; }
    if s == "u8" || s == "u16" || s == "u32" || s == "u64" { return T_INT_TYPE; }
    if s == "float" || s == "f32" || s == "f64" { return T_FLOAT_TYPE; }
    if s == "bool" { return T_BOOL_TYPE; }
    if s == "unit" { return T_UNIT_TYPE; }
    if s == "string" || s == "str" { return T_STR_TYPE; }
    if s == "auto" { return T_AUTO_TYPE; }
    if s == "go" { return T_GO; }
    if s == "await" { return T_AWAIT; }
    if s == "ref" { return T_REF; }
    if s == "unsafe" { return T_UNSAFE; }
    return T_IDENT;
}

fn add_tok(kind: int, lex: int, start_line: int, start_col: int) {
    grow_tokens(g_token_count + 1);
    tp := g_token_count * ESZ_TOKEN;
    w64(g_tokens, tp + OFF_TK_KIND, kind);
    w64(g_tokens, tp + OFF_TK_LEXEME, lex);
    w64(g_tokens, tp + OFF_TK_INTVAL, 0);
    w64(g_tokens, tp + OFF_TK_LINE, start_line);
    w64(g_tokens, tp + OFF_TK_COL, start_col);
    g_token_count = g_token_count + 1;
}

fn add_tok_int(kind: int, ival: int, start_line: int, start_col: int) {
    grow_tokens(g_token_count + 1);
    tp := g_token_count * ESZ_TOKEN;
    w64(g_tokens, tp + OFF_TK_KIND, kind);
    w64(g_tokens, tp + OFF_TK_LEXEME, -1);
    w64(g_tokens, tp + OFF_TK_INTVAL, ival);
    w64(g_tokens, tp + OFF_TK_LINE, start_line);
    w64(g_tokens, tp + OFF_TK_COL, start_col);
    g_token_count = g_token_count + 1;
}

fn add_tok_str(kind: int, s: string, start_line: int, start_col: int) {
    grow_tokens(g_token_count + 1);
    tp := g_token_count * ESZ_TOKEN;
    w64(g_tokens, tp + OFF_TK_KIND, kind);
    si := str_intern(s);
    w64(g_tokens, tp + OFF_TK_LEXEME, si);
    w64(g_tokens, tp + OFF_TK_INTVAL, 0);
    w64(g_tokens, tp + OFF_TK_LINE, start_line);
    w64(g_tokens, tp + OFF_TK_COL, start_col);
    g_token_count = g_token_count + 1;
}

fn skip_ws(pos: int) -> int {
    loop {
        c := cur_char_at(pos);
        if c == C_SP || c == C_TB || c == C_CR || c == C_NL { pos = pos + 1; }
        else { break; }
    }
    return pos;
}

fn tokenize() {
    g_token_count = 0;
    g_error_count = 0;
    _pos : ., mut = 0;
    _line : ., mut = 1;
    _col : ., mut = 1;
    _slen : ., mut = str_len(g_source);

    _pos = skip_ws(_pos);

    loop {
        if _pos >= _slen { break; }
        c := cur_char_at(_pos);
        start_line : ., mut = _line;
        start_col : ., mut = _col;

        // Comments
        if c == C_SLASH && peek_at(_pos) == C_SLASH {
            _pos = _pos + 2;
            loop {
                if _pos >= _slen { break; }
                if cur_char_at(_pos) == C_NL { _pos = _pos + 1; break; }
                _pos = _pos + 1;
            }
            _pos = skip_ws(_pos);
            continue;
        }
        if c == C_SLASH && peek_at(_pos) == C_STAR {
            _pos = _pos + 2;
            loop {
                if _pos >= _slen { break; }
                if cur_char_at(_pos) == C_STAR && peek_at(_pos) == C_SLASH { _pos = _pos + 2; break; }
                _pos = _pos + 1;
            }
            _pos = skip_ws(_pos);
            continue;
        }

        // Identifier
        if is_alpha(c) != 0 {
            start := _pos;
            _pos = _pos + 1;
            loop {
                c2 := cur_char_at(_pos);
                if is_ident_char(c2) != 0 { _pos = _pos + 1; } else { break; }
            }
            ident := str_sub(g_source, start, _pos - start);
            kind := lookup_keyword(ident);
            add_tok_str(kind, ident, start_line, start_col);
            _pos = skip_ws(_pos);
            continue;
        }

        // Number
        if is_digit(c) != 0 || (c == C_DOT && is_digit(peek_at(_pos)) != 0) {
            start := _pos;
            if c == C_DOT { _pos = _pos + 1; c = cur_char_at(_pos); }
            loop {
                if is_digit(cur_char_at(_pos)) != 0 { _pos = _pos + 1; }
                else { break; }
            }
            // Hex/octal/binary prefix
            if c == 48 && _pos - start == 1 {
                nx := cur_char_at(_pos);
                if nx == 120 || nx == 88 { _pos = _pos + 1; loop { hc := cur_char_at(_pos); if is_digit(hc) != 0 || (hc >= 65 && hc <= 70) || (hc >= 97 && hc <= 102) { _pos = _pos + 1; } else { break; } } }
                else if nx == 111 || nx == 79 { _pos = _pos + 1; loop { oc := cur_char_at(_pos); if oc >= 48 && oc <= 55 { _pos = _pos + 1; } else { break; } } }
                else if nx == 98 || nx == 66 { _pos = _pos + 1; loop { bc := cur_char_at(_pos); if bc == 48 || bc == 49 { _pos = _pos + 1; } else { break; } } }
            }
            // Float
            if cur_char_at(_pos) == C_DOT {
                _pos = _pos + 1;
                loop { if is_digit(cur_char_at(_pos)) != 0 { _pos = _pos + 1; } else { break; } }
            }
            // Suffix
            suffix : ., mut = "";
            sx := cur_char_at(_pos);
            if is_alpha(sx) != 0 {
                ss := _pos;
                loop {
                    if is_alpha(cur_char_at(_pos)) != 0 { _pos = _pos + 1; } else { break; }
                }
                suffix = str_sub(g_source, ss, _pos - ss);
            }
            num_str := str_sub(g_source, start, _pos - start - str_len(suffix));
            ival : ., mut = str_int(num_str);
            if suffix == "u8" || suffix == "u16" || suffix == "u32" || suffix == "u64" { }
            else if suffix == "i8" || suffix == "i16" || suffix == "i32" || suffix == "i64" { }
            else if suffix == "f32" || suffix == "f64" { }
            else if str_len(suffix) > 0 { }
            if str_len(suffix) > 0 { add_tok(T_INT, -1, start_line, start_col); }
            else { add_tok_int(T_INT, ival, start_line, start_col); }
            _pos = skip_ws(_pos);
            continue;
        }

        // String interpolation
        if c == C_DQUOTE {
            _pos = _pos + 1;
            str_val : ., mut = "";
            loop {
                cc := cur_char_at(_pos);
                if cc == 0 || cc == C_NL { break; }
                if cc == C_DQUOTE { _pos = _pos + 1; break; }
                if cc == C_BSLASH {
                    _pos = _pos + 1;
                    esc := cur_char_at(_pos);
                    if esc == 110 { str_val = str_val + chr(10); }
                    else if esc == 116 { str_val = str_val + chr(9); }
                    else if esc == 114 { str_val = str_val + chr(13); }
                    else if esc == 48 { str_val = str_val + chr(0); }
                    else if esc == C_SQUOTE { str_val = str_val + "'"; }
                    else if esc == C_BSLASH { str_val = str_val + chr(92); }
                    else if esc == C_DQUOTE { str_val = str_val + chr(34); }
                    else if esc == 120 {
                        _pos = _pos + 1; hi := cur_char_at(_pos); _pos = _pos + 1; lo := cur_char_at(_pos);
                        hex_str := chr(hi) + chr(lo);
                        if hex_str == "00" { str_val = str_val + chr(0); }
                        else if hex_str == "0a" || hex_str == "0A" { str_val = str_val + chr(10); }
                        else { str_val = str_val + "?"; }
                    }
                    else { str_val = str_val + chr(esc); }
                } else if cc == 36 && peek_at(_pos) == C_LBRACE {
                    // Interpolation: skip for now
                    _pos = _pos + 2;
                    loop { if cur_char_at(_pos) == C_RBRACE { _pos = _pos + 1; break; } _pos = _pos + 1; }
                } else {
                    str_val = str_val + chr(cc);
                }
                _pos = _pos + 1;
            }
            add_tok_str(T_STRING, str_val, start_line, start_col);
            _pos = skip_ws(_pos);
            continue;
        }

        // Char literal
        if c == C_SQUOTE {
            _pos = _pos + 1;
            ch : ., mut = chr(0);
            if cur_char_at(_pos) == C_BSLASH {
                _pos = _pos + 1;
                esc2 := cur_char_at(_pos);
                if esc2 == 110 { ch = chr(10); }
                else if esc2 == 116 { ch = chr(9); }
                else if esc2 == 114 { ch = chr(13); }
                else if esc2 == 48 { ch = chr(0); }
                else if esc2 == C_SQUOTE { ch = "'"; }
                else if esc2 == C_BSLASH { ch = chr(92); }
                else if esc2 == C_DQUOTE { ch = chr(34); }
                else if esc2 == 120 {
                    _pos = _pos + 1; hi2 := cur_char_at(_pos); _pos = _pos + 1; lo2 := cur_char_at(_pos);
                    if chr(hi2) + chr(lo2) == "00" { ch = chr(0); }
                    else { ch = "?"; }
                }
                else { ch = chr(esc2); }
                _pos = _pos + 1;
            } else {
                ch = chr(cur_char_at(_pos));
                _pos = _pos + 1;
            }
            if cur_char_at(_pos) == C_SQUOTE { _pos = _pos + 1; }
            add_tok_str(T_CHAR, ch, start_line, start_col);
            _pos = skip_ws(_pos);
            continue;
        }

        // Multi-char operators
        if c == C_EQ    && peek_at(_pos) == C_EQ   { _pos = _pos + 2; add_tok(T_EQEQ, -1, start_line, start_col); _pos = skip_ws(_pos); continue; }
        if c == C_BANG  && peek_at(_pos) == C_EQ   { _pos = _pos + 2; add_tok(T_BANGEQ, -1, start_line, start_col); _pos = skip_ws(_pos); continue; }
        if c == C_LT    && peek_at(_pos) == C_EQ   { _pos = _pos + 2; add_tok(T_LTEQ, -1, start_line, start_col); _pos = skip_ws(_pos); continue; }
        if c == C_GT    && peek_at(_pos) == C_EQ   { _pos = _pos + 2; add_tok(T_GTEQ, -1, start_line, start_col); _pos = skip_ws(_pos); continue; }
        if c == C_AMP   && peek_at(_pos) == C_AMP  { _pos = _pos + 2; add_tok(T_ANDAND, -1, start_line, start_col); _pos = skip_ws(_pos); continue; }
        if c == C_PIPE  && peek_at(_pos) == C_PIPE { _pos = _pos + 2; add_tok(T_PIPEPIPE, -1, start_line, start_col); _pos = skip_ws(_pos); continue; }
        if c == C_DASH  && peek_at(_pos) == C_GT   { _pos = _pos + 2; add_tok(T_ARROW, -1, start_line, start_col); _pos = skip_ws(_pos); continue; }
        if c == C_EQ    && peek_at(_pos) == C_GT   { _pos = _pos + 2; add_tok(T_FATARROW, -1, start_line, start_col); _pos = skip_ws(_pos); continue; }
        if c == C_COLON && peek_at(_pos) == C_EQ   { _pos = _pos + 2; add_tok(T_COLON_EQ, -1, start_line, start_col); _pos = skip_ws(_pos); continue; }
        if c == C_COLON && peek_at(_pos) == C_COLON{ _pos = _pos + 2; add_tok(T_PATHSEP, -1, start_line, start_col); _pos = skip_ws(_pos); continue; }
        if c == C_DOT   && peek_at(_pos) == C_DOT {
            _pos = _pos + 2;
            if cur_char_at(_pos) == C_DOT { _pos = _pos + 1; add_tok(T_DOTDOTDOT, -1, start_line, start_col); }
            else { add_tok(T_DOTDOT, -1, start_line, start_col); }
            _pos = skip_ws(_pos); continue; }

        // Compound assignment operators
        if c == C_PLUS  && peek_at(_pos) == C_EQ { _pos = _pos + 2; add_tok(T_PLUS_EQ, -1, start_line, start_col); _pos = skip_ws(_pos); continue; }
        if c == C_DASH  && peek_at(_pos) == C_EQ { _pos = _pos + 2; add_tok(T_MINUS_EQ, -1, start_line, start_col); _pos = skip_ws(_pos); continue; }
        if c == C_STAR  && peek_at(_pos) == C_EQ { _pos = _pos + 2; add_tok(T_STAR_EQ, -1, start_line, start_col); _pos = skip_ws(_pos); continue; }
        if c == C_SLASH && peek_at(_pos) == C_EQ { _pos = _pos + 2; add_tok(T_SLASH_EQ, -1, start_line, start_col); _pos = skip_ws(_pos); continue; }

        // Single-char tokens
        if c == C_LPAREN  { _pos = _pos + 1; add_tok(T_LPAREN, -1, start_line, start_col); _pos = skip_ws(_pos); continue; }
        if c == C_RPAREN  { _pos = _pos + 1; add_tok(T_RPAREN, -1, start_line, start_col); _pos = skip_ws(_pos); continue; }
        if c == C_LBRACE  { _pos = _pos + 1; add_tok(T_LBRACE, -1, start_line, start_col); _pos = skip_ws(_pos); continue; }
        if c == C_RBRACE  { _pos = _pos + 1; add_tok(T_RBRACE, -1, start_line, start_col); _pos = skip_ws(_pos); continue; }
        if c == C_LBRACK  { _pos = _pos + 1; add_tok(T_LBRACKET, -1, start_line, start_col); _pos = skip_ws(_pos); continue; }
        if c == C_RBRACK  { _pos = _pos + 1; add_tok(T_RBRACKET, -1, start_line, start_col); _pos = skip_ws(_pos); continue; }
        if c == C_COMMA   { _pos = _pos + 1; add_tok(T_COMMA, -1, start_line, start_col); _pos = skip_ws(_pos); continue; }
        if c == C_SEMI    { _pos = _pos + 1; add_tok(T_SEMI, -1, start_line, start_col); _pos = skip_ws(_pos); continue; }
        if c == C_COLON   { _pos = _pos + 1; add_tok(T_COLON, -1, start_line, start_col); _pos = skip_ws(_pos); continue; }
        if c == C_DOT     { _pos = _pos + 1; add_tok(T_DOT, -1, start_line, start_col); _pos = skip_ws(_pos); continue; }
        if c == C_EQ      { _pos = _pos + 1; add_tok(T_EQ, -1, start_line, start_col); _pos = skip_ws(_pos); continue; }
        if c == C_BANG    { _pos = _pos + 1; add_tok(T_BANG, -1, start_line, start_col); _pos = skip_ws(_pos); continue; }
        if c == C_LT      { _pos = _pos + 1; add_tok(T_LT, -1, start_line, start_col); _pos = skip_ws(_pos); continue; }
        if c == C_GT      { _pos = _pos + 1; add_tok(T_GT, -1, start_line, start_col); _pos = skip_ws(_pos); continue; }
        if c == C_PLUS    { _pos = _pos + 1; add_tok(T_PLUS, -1, start_line, start_col); _pos = skip_ws(_pos); continue; }
        if c == C_DASH    { _pos = _pos + 1; add_tok(T_MINUS, -1, start_line, start_col); _pos = skip_ws(_pos); continue; }
        if c == C_STAR    { _pos = _pos + 1; add_tok(T_STAR, -1, start_line, start_col); _pos = skip_ws(_pos); continue; }
        if c == C_SLASH   { _pos = _pos + 1; add_tok(T_SLASH, -1, start_line, start_col); _pos = skip_ws(_pos); continue; }
        if c == C_PERCENT { _pos = _pos + 1; add_tok(T_PERCENT, -1, start_line, start_col); _pos = skip_ws(_pos); continue; }
        if c == C_AMP     { _pos = _pos + 1; add_tok(T_AMPERSAND, -1, start_line, start_col); _pos = skip_ws(_pos); continue; }
        if c == C_UNDER   { _pos = _pos + 1; add_tok(T_UNDERSCORE, -1, start_line, start_col); _pos = skip_ws(_pos); continue; }
        if c == C_AT      { _pos = _pos + 1; add_tok(T_AT, -1, start_line, start_col); _pos = skip_ws(_pos); continue; }
        if c == C_QUES    { _pos = _pos + 1; add_tok(T_QUESTION, -1, start_line, start_col); _pos = skip_ws(_pos); continue; }

        // Unknown
        _pos = _pos + 1;
        _pos = skip_ws(_pos);
    }

    add_tok(T_EOF, -1, _line, _col);
    // Sync back globals
    g_pos = _pos;
    g_line = _line;
    g_col = _col;
    g_source_len = _slen;
}
