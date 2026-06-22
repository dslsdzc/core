// Lexer: tokenizes Core source code using int-based character access.
// Character comparisons use ASCII code constants rather than string allocs.

// Global compiler state
g_source : string, mut;
g_source_len : int, mut;     // cached str_len(g_source), set in tokenize()
g_pos : int, mut;
g_line : int, mut;
g_col : int, mut;

// ── ASCII character constants (for int-based comparisons) ──
C_NL : int = 10;    C_SP : int = 32;    C_TB : int = 9;     C_CR : int = 13;
C_0 : int = 48;     C_9 : int = 57;
C_a : int = 97;     C_z : int = 122;    C_A : int = 65;     C_Z : int = 90;
C_SLASH : int = 47; C_STAR : int = 42;  C_DOT : int = 46;
C_DQUOTE : int = 34; C_SQUOTE : int = 39; C_BSLASH : int = 92;
C_EQ : int = 61;    C_BANG : int = 33;  C_LT : int = 60;    C_GT : int = 62;
C_AMP : int = 38;   C_PIPE : int = 124; C_DASH : int = 45;  C_PLUS : int = 43;
C_COLON : int = 58; C_SEMI : int = 59;  C_UNDER : int = 95; C_AT : int = 64;
C_LPAREN : int = 40; C_RPAREN : int = 41; C_HASH : int = 35;
C_LBRACE : int = 123; C_RBRACE : int = 125;
C_LBRACK : int = 91;  C_RBRACK : int = 93;
C_COMMA : int = 44;  C_PERCENT : int = 37; C_QUES : int = 63;

fn add_error(msg: string) {
    mi := str_intern(msg);
    grow_errors(g_error_count + 1); if 1 {
        w64(g_errors, g_error_count * 8, mi);
        g_error_count = g_error_count + 1;
    }
}

fn cur_char() -> int {
    if g_pos >= g_source_len { return 0; }
    return load8(g_source, g_pos);
}

fn peek() -> int {
    if g_pos + 1 >= g_source_len { return 0; }
    return load8(g_source, g_pos + 1);
}

fn advance() {
    c := cur_char();
    if c == C_NL { g_line = g_line + 1; g_col = 1; }
    else { g_col = g_col + 1; }
    g_pos = g_pos + 1;
}

fn skip_whitespace() {
    loop {
        c := cur_char();
        if c == C_SP || c == C_TB || c == C_CR || c == C_NL { advance(); }
        else { break; }
    }
}

fn add_token(kind: int) {
    grow_tokens(g_token_count + 1);
    tp := g_token_count * ESZ_TOKEN;
    w64(g_tokens, tp + OFF_TK_KIND, kind);
    w64(g_tokens, tp + OFF_TK_LEXEME, -1);
    w64(g_tokens, tp + OFF_TK_INTVAL, 0);
    w64(g_tokens, tp + OFF_TK_LINE, g_line);
    w64(g_tokens, tp + OFF_TK_COL, g_col);
    g_token_count = g_token_count + 1;
}

fn add_token_str(kind: int, lexeme: string) {
    grow_tokens(g_token_count + 1);
    tp := g_token_count * ESZ_TOKEN;
    li := str_intern(lexeme);
    w64(g_tokens, tp + OFF_TK_KIND, kind);
    w64(g_tokens, tp + OFF_TK_LEXEME, li);
    w64(g_tokens, tp + OFF_TK_INTVAL, 0);
    w64(g_tokens, tp + OFF_TK_LINE, g_line);
    w64(g_tokens, tp + OFF_TK_COL, g_col);
    g_token_count = g_token_count + 1;
}

fn add_token_int(kind: int, val: int) {
    grow_tokens(g_token_count + 1);
    tp := g_token_count * ESZ_TOKEN;
    w64(g_tokens, tp + OFF_TK_KIND, kind);
    w64(g_tokens, tp + OFF_TK_LEXEME, -1);
    w64(g_tokens, tp + OFF_TK_INTVAL, val);
    w64(g_tokens, tp + OFF_TK_LINE, g_line);
    w64(g_tokens, tp + OFF_TK_COL, g_col);
    g_token_count = g_token_count + 1;
}

fn is_digit(c: int) -> int {
    if c >= C_0 && c <= C_9 { return 1; }
    return 0;
}

fn is_alpha(c: int) -> int {
    if (c >= C_a && c <= C_z) || (c >= C_A && c <= C_Z) || c == C_UNDER { return 1; }
    return 0;
}

fn is_ident_char(c: int) -> int {
    if is_alpha(c) != 0 || is_digit(c) != 0 { return 1; }
    return 0;
}

fn lookup_keyword(ident: string) -> int {
    if ident == "fn" { return T_FN; }
    if ident == "mut" { return T_MUT; }
    if ident == "if" { return T_IF; }
    if ident == "else" { return T_ELSE; }
    if ident == "loop" { return T_LOOP; }
    if ident == "for" { return T_FOR; }
    if ident == "in" { return T_IN; }
    if ident == "return" { return T_RETURN; }
    if ident == "break" { return T_BREAK; }
    if ident == "continue" { return T_CONTINUE; }
    if ident == "struct" { return T_STRUCT; }
    if ident == "enum" { return T_ENUM; }
    if ident == "impl" { return T_IMPL; }
    if ident == "pub" { return T_PUB; }
    if ident == "true" { return T_TRUE; }
    if ident == "false" { return T_FALSE; }
    if ident == "match" { return T_MATCH; }
    if ident == "move" { return T_MOVE; }
    if ident == "self" { return T_SELF; }
    if ident == "unit" { return T_UNIT; }
    if ident == "char" { return T_CHAR; }
    if ident == "while" { return T_WHILE; }
    if ident == "import" { return T_IMPORT; }
    if ident == "mod" { return T_MOD; }
    if ident == "type" { return T_TYPE; }
    if ident == "as" { return T_AS; }
    if ident == "go" { return T_GO; }
    if ident == "await" { return T_AWAIT; }
    if ident == "unsafe" { return T_UNSAFE; }
    if ident == "interface" { return T_INTERFACE; }
    if ident == "auto" { return T_AUTO; }
    if ident == "fileid" { return T_FILEID; }
    if ident == "None" { return T_NONE; }
    if ident == "Some" { return T_SOME; }
    return T_IDENT;
}

fn tokenize() {
    g_source_len = str_len(g_source);
    g_token_count = 0;
    g_pos = 0;
    g_line = 1;
    g_col = 1;
    g_error_count = 0;

    skip_whitespace();

    loop {
        if g_pos >= g_source_len { break; }
        c := cur_char();

        // Single-line comment //
        if c == C_SLASH && peek() == C_SLASH {
            loop {
                advance();
                if g_pos >= g_source_len { break; }
                if cur_char() == C_NL { advance(); break; }
            }
            skip_whitespace();
            continue;
        }

        // Block comment /* */
        if c == C_SLASH && peek() == C_STAR {
            advance(); advance();
            loop {
                if g_pos >= g_source_len { break; }
                if cur_char() == C_STAR && peek() == C_SLASH { advance(); advance(); break; }
                advance();
            }
            skip_whitespace();
            continue;
        }

        start_line := g_line;
        start_col := g_col;

        // Identifier or keyword
        if is_alpha(c) != 0 {
            start := g_pos;
            advance();
            loop {
                c2 := cur_char();
                if is_ident_char(c2) != 0 { advance(); } else { break; }
            }
            ident := str_sub(g_source, start, g_pos - start);
            kind := lookup_keyword(ident);
            add_token_str(kind, ident);
            skip_whitespace();
            continue;
        }

        // Number literal
        if is_digit(c) != 0 {
            start := g_pos;
            advance();
            kind : ., mut = T_INT;
            loop {
                c2 := cur_char();
                if is_digit(c2) != 0 || c2 == C_UNDER { advance(); }
                else if c2 == C_DOT {
                    nxt := peek();
                    if is_digit(nxt) == 0 && nxt != C_UNDER { break; }
                    kind = T_FLOAT;
                    advance();
                    loop {
                        c3 := cur_char();
                        if is_digit(c3) != 0 || c3 == C_UNDER { advance(); }
                        else { break; }
                    }
                } else { break; }
            }
            // Check for integer/float suffix
            suffix : ., mut = "";
            if is_alpha(cur_char()) != 0 || cur_char() == 105/*i*/ || cur_char() == 117/*u*/ || cur_char() == 102/*f*/ {
                loop {
                    c4 := cur_char();
                    if is_alpha(c4) != 0 || is_digit(c4) != 0 {
                        suffix = suffix + chr(c4);
                        advance();
                    } else { break; }
                }
                if suffix == "i8" { kind = T_INT_I8; }
                else if suffix == "i16" { kind = T_INT_I16; }
                else if suffix == "i32" { kind = T_INT_I32; }
                else if suffix == "i64" { kind = T_INT_I64; }
                else if suffix == "u8" { kind = T_INT_U8; }
                else if suffix == "u16" { kind = T_INT_U16; }
                else if suffix == "u32" { kind = T_INT_U32; }
                else if suffix == "u64" { kind = T_INT_U64; }
                else if suffix == "f32" { kind = T_FLOAT_F32; }
                else if suffix == "f64" { kind = T_FLOAT_F64; }
            }
            num_str := str_sub(g_source, start, g_pos - start - str_len(suffix));
            // Strip _ separators before conversion
            clean : ., mut = "";
            ni : ., mut = 0;
            nsl := str_len(num_str);
            loop {
                if ni >= nsl { break; }
                nc := load8(num_str, ni);
                if nc != C_UNDER { clean = clean + chr(nc); }
                ni = ni + 1;
            }
            val := str_int(clean);
            add_token_int(kind, val);
            skip_whitespace();
            continue;
        }

        // String literal
        if c == C_DQUOTE {
            advance();
            str_val : ., mut = "";
            loop {
                if g_pos >= g_source_len { break; }
                cc := cur_char(); if cc == C_DQUOTE { break; }
                if cc == C_BSLASH {
                    advance();
                    if g_pos < g_source_len {
                        esc := cur_char();
                        if esc == 110/*n*/ { str_val = str_val + "\n"; }
                        else if esc == 116/*t*/ { str_val = str_val + "\t"; }
                        else if esc == 114/*r*/ { str_val = str_val + "\r"; }
                        else if esc == 48/*0*/ { str_val = str_val + "\0"; }
                        else if esc == C_BSLASH { str_val = str_val + "\\"; }
                        else if esc == C_DQUOTE { str_val = str_val + "\""; }
                        else if esc == 120/*x*/ {
                            advance(); hi := cur_char(); advance(); lo := cur_char();
                            hex_str := chr(hi) + chr(lo);
                            if hex_str == "00" { str_val = str_val + "\0"; }
                            else if hex_str == "0a" || hex_str == "0A" { str_val = str_val + "\n"; }
                            else { str_val = str_val + "?"; }
                        }
                        else { str_val = str_val + chr(esc); }
                        advance();
                    }
                } else {
                    str_val = str_val + chr(cc);
                    advance();
                }
            }
            advance();
            add_token_str(T_STRING, str_val);
            skip_whitespace();
            continue;
        }

        // Char literal
        if c == C_SQUOTE {
            advance();
            ch : ., mut = "\0";
            if cur_char() == C_BSLASH {
                advance();
                esc := cur_char();
                if esc == 110/*n*/ { ch = "\n"; }
                else if esc == 116/*t*/ { ch = "\t"; }
                else if esc == 114/*r*/ { ch = "\r"; }
                else if esc == 48/*0*/ { ch = "\0"; }
                else if esc == C_SQUOTE { ch = "'"; }
                else if esc == C_BSLASH { ch = "\\"; }
                else if esc == C_DQUOTE { ch = "\""; }
                else if esc == 120/*x*/ {
                    advance(); hi := cur_char(); advance(); lo := cur_char();
                    hex_str := chr(hi) + chr(lo);
                    if hex_str == "00" { ch = "\0"; }
                    else if hex_str == "0a" || hex_str == "0A" { ch = "\n"; }
                    else { ch = "?"; }
                }
                else { ch = chr(esc); }
                advance();
            } else {
                ch = chr(cur_char());
                advance();
            }
            if cur_char() == C_SQUOTE { advance(); }
            add_token_str(T_CHAR, ch);
            skip_whitespace();
            continue;
        }

        // Multi-character operators
        if c == C_EQ    && peek() == C_EQ   { advance(); advance(); add_token(T_EQEQ); skip_whitespace(); continue; }
        if c == C_BANG  && peek() == C_EQ   { advance(); advance(); add_token(T_BANGEQ); skip_whitespace(); continue; }
        if c == C_LT    && peek() == C_EQ   { advance(); advance(); add_token(T_LTEQ); skip_whitespace(); continue; }
        if c == C_GT    && peek() == C_EQ   { advance(); advance(); add_token(T_GTEQ); skip_whitespace(); continue; }
        if c == C_AMP   && peek() == C_AMP  { advance(); advance(); add_token(T_ANDAND); skip_whitespace(); continue; }
        if c == C_PIPE  && peek() == C_PIPE { advance(); advance(); add_token(T_PIPEPIPE); skip_whitespace(); continue; }
        if c == C_DASH  && peek() == C_GT   { advance(); advance(); add_token(T_ARROW); skip_whitespace(); continue; }
        if c == C_EQ    && peek() == C_GT   { advance(); advance(); add_token(T_FATARROW); skip_whitespace(); continue; }
        if c == C_COLON && peek() == C_EQ   { advance(); advance(); add_token(T_COLON_EQ); skip_whitespace(); continue; }
        if c == C_COLON && peek() == C_COLON{ advance(); advance(); add_token(T_PATHSEP); skip_whitespace(); continue; }
        if c == C_DOT   && peek() == C_DOT {
            advance(); advance();
            if cur_char() == C_DOT { advance(); add_token(T_DOTDOTDOT); }
            else { add_token(T_DOTDOT); }
            skip_whitespace(); continue; }

        // Compound assignment operators
        if c == C_PLUS  && peek() == C_EQ { advance(); advance(); add_token(T_PLUS_EQ); skip_whitespace(); continue; }
        if c == C_DASH  && peek() == C_EQ { advance(); advance(); add_token(T_MINUS_EQ); skip_whitespace(); continue; }
        if c == C_STAR  && peek() == C_EQ { advance(); advance(); add_token(T_STAR_EQ); skip_whitespace(); continue; }
        if c == C_SLASH && peek() == C_EQ { advance(); advance(); add_token(T_SLASH_EQ); skip_whitespace(); continue; }

        // Single-character tokens
        if c == C_LPAREN  { advance(); add_token(T_LPAREN); skip_whitespace(); continue; }
        if c == C_RPAREN  { advance(); add_token(T_RPAREN); skip_whitespace(); continue; }
        if c == C_LBRACE  { advance(); add_token(T_LBRACE); skip_whitespace(); continue; }
        if c == C_RBRACE  { advance(); add_token(T_RBRACE); skip_whitespace(); continue; }
        if c == C_LBRACK  { advance(); add_token(T_LBRACKET); skip_whitespace(); continue; }
        if c == C_RBRACK  { advance(); add_token(T_RBRACKET); skip_whitespace(); continue; }
        if c == C_COMMA   { advance(); add_token(T_COMMA); skip_whitespace(); continue; }
        if c == C_SEMI    { advance(); add_token(T_SEMI); skip_whitespace(); continue; }
        if c == C_COLON   { advance(); add_token(T_COLON); skip_whitespace(); continue; }
        if c == C_DOT     { advance(); add_token(T_DOT); skip_whitespace(); continue; }
        if c == C_EQ      { advance(); add_token(T_EQ); skip_whitespace(); continue; }
        if c == C_BANG    { advance(); add_token(T_BANG); skip_whitespace(); continue; }
        if c == C_LT      { advance(); add_token(T_LT); skip_whitespace(); continue; }
        if c == C_GT      { advance(); add_token(T_GT); skip_whitespace(); continue; }
        if c == C_PLUS    { advance(); add_token(T_PLUS); skip_whitespace(); continue; }
        if c == C_DASH    { advance(); add_token(T_MINUS); skip_whitespace(); continue; }
        if c == C_STAR    { advance(); add_token(T_STAR); skip_whitespace(); continue; }
        if c == C_SLASH   { advance(); add_token(T_SLASH); skip_whitespace(); continue; }
        if c == C_PERCENT { advance(); add_token(T_PERCENT); skip_whitespace(); continue; }
        if c == C_AMP     { advance(); add_token(T_AMPERSAND); skip_whitespace(); continue; }
        if c == C_UNDER   { advance(); add_token(T_UNDERSCORE); skip_whitespace(); continue; }
        if c == C_AT      { advance(); add_token(T_AT); skip_whitespace(); continue; }
        if c == C_QUES    { advance(); add_token(T_QUESTION); skip_whitespace(); continue; }

        // Unknown character
        advance();
        skip_whitespace();
    }

    add_token(T_EOF);
}
