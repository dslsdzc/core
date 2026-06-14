// Lexer: tokenizes Core source code using string built-ins

// Global compiler state
g_source : string, mut;
g_pos : int, mut;
g_line : int, mut;
g_col : int, mut;

fn add_error(msg: string) {
    mi := str_intern(msg);
    dyn_grow_errors(g_error_count + 1); if 1 {
        w64(g_errors, g_error_count * 8, mi);
        g_error_count = g_error_count + 1;
    }
}

fn cur_char() -> string {
    if g_pos >= __builtin_str_len(g_source) {
        return "\0";
    }
    return __builtin_str_get(g_source, g_pos);
}

fn advance() {
    c := cur_char();
    if c == "\n" {
        g_line = g_line + 1;
        g_col = 1;
    } else {
        g_col = g_col + 1;
    }
    g_pos = g_pos + 1;
}

fn peek() -> string {
    if g_pos + 1 >= __builtin_str_len(g_source) {
        return "\0";
    }
    return __builtin_str_get(g_source, g_pos + 1);
}

fn skip_whitespace() {
    loop {
        c := cur_char();
        if c == " " || c == "\t" || c == "\r" || c == "\n" {
            advance();
        } else {
            break;
        }
    }
}

fn add_token(kind: int) {
    dyn_grow_tokens(g_token_count + 1);
    tp := g_token_count * ESZ_TOKEN;
    w64(g_tokens, tp + OFF_TK_KIND, kind);
    w64(g_tokens, tp + OFF_TK_LEXEME, -1);  // no lexeme
    w64(g_tokens, tp + OFF_TK_INTVAL, 0);
    w64(g_tokens, tp + OFF_TK_LINE, g_line);
    w64(g_tokens, tp + OFF_TK_COL, g_col);
    g_token_count = g_token_count + 1;
}

fn add_token_str(kind: int, lexeme: string) {
    dyn_grow_tokens(g_token_count + 1);
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
    dyn_grow_tokens(g_token_count + 1);
    tp := g_token_count * ESZ_TOKEN;
    w64(g_tokens, tp + OFF_TK_KIND, kind);
    w64(g_tokens, tp + OFF_TK_LEXEME, -1);
    w64(g_tokens, tp + OFF_TK_INTVAL, val);
    w64(g_tokens, tp + OFF_TK_LINE, g_line);
    w64(g_tokens, tp + OFF_TK_COL, g_col);
    g_token_count = g_token_count + 1;
}

fn is_digit(c: string) -> bool {
    c >= "0" && c <= "9"
}

fn is_alpha(c: string) -> bool {
    (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || c == "_"
}

fn is_ident_char(c: string) -> bool {
    is_alpha(c) || is_digit(c)
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
    g_token_count = 0;
    g_pos = 0;
    g_line = 1;
    g_col = 1;
    g_error_count = 0;

    skip_whitespace();

    loop {
        if g_pos >= __builtin_str_len(g_source) { break; }
        c := cur_char();

        // Single-line comment //
        if c == "/" && peek() == "/" {
            loop {
                advance();
                if g_pos >= __builtin_str_len(g_source) { break; }
                if cur_char() == "\n" {
                    advance();
                    break;
                }
            }
            skip_whitespace();
            continue;
        }

        // Block comment /* */
        if c == "/" && peek() == "*" {
            advance(); advance();
            loop {
                if g_pos >= __builtin_str_len(g_source) { break; }
                if cur_char() == "*" && peek() == "/" {
                    advance(); advance();
                    break;
                }
                advance();
            }
            skip_whitespace();
            continue;
        }

        start_line := g_line;
        start_col := g_col;

        // Identifier or keyword
        if is_alpha(c) {
            start := g_pos;
            advance();
            loop {
                c2 := cur_char();
                if is_ident_char(c2) { advance(); } else { break; }
            }
            ident := __builtin_str_sub(g_source, start, g_pos - start);
            kind := lookup_keyword(ident);
            add_token_str(kind, ident);
            skip_whitespace();
            continue;
        }

        // Number literal
        if is_digit(c) {
            start := g_pos;
            advance();
            kind : ., mut = T_INT;
            loop {
                c2 := cur_char();
                if is_digit(c2) || c2 == "_" { advance(); }
                else if c2 == "." {
                    // Peek ahead: if next char is not digit, don't treat as float
                    nxt := peek();
                    if !is_digit(nxt) && nxt != "_" { break; }
                    kind = T_FLOAT;
                    advance();
                    // Accept more digits after decimal
                    loop {
                        c3 := cur_char();
                        if is_digit(c3) || c3 == "_" { advance(); }
                        else { break; }
                    }
                } else { break; }
            }
            // Check for integer suffix (i8, i16, i32, i64, u8, u16, u32, u64)
            // or float suffix (f32, f64)
            suffix : ., mut = "";
            if is_alpha(cur_char()) || cur_char() == "i" || cur_char() == "u" || cur_char() == "f" {
                loop {
                    c4 := cur_char();
                    if is_alpha(c4) || is_digit(c4) { suffix = suffix + c4; advance(); }
                    else { break; }
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
            num_str := __builtin_str_sub(g_source, start, g_pos - start - __builtin_str_len(suffix));
            // Strip _ separators before conversion
            clean : ., mut = "";
            ni : ., mut = 0;
            loop {
                if ni >= __builtin_str_len(num_str) { break; }
                nc := __builtin_str_get(num_str, ni);
                if nc != "_" { clean = clean + nc; }
                ni = ni + 1;
            }
            val := __builtin_str_to_int(clean);
            add_token_int(kind, val);
            skip_whitespace();
            continue;
        }

        // String literal
        if c == "\"" {
            advance();
            str_val : ., mut = "";
            loop {
                if g_pos >= __builtin_str_len(g_source) { break; }
                if cur_char() == "\"" { break; }
                if cur_char() == "\\" {
                    advance();
                    if g_pos < __builtin_str_len(g_source) {
                        esc := cur_char();
                        if esc == "n" { str_val = str_val + "\n"; }
                        else if esc == "t" { str_val = str_val + "\t"; }
                        else if esc == "r" { str_val = str_val + "\r"; }
                        else if esc == "0" { str_val = str_val + "\0"; }
                        else if esc == "\\" { str_val = str_val + "\\"; }
                        else if esc == "\"" { str_val = str_val + "\""; }
                        else if esc == "x" {
                            advance();
                            hi := cur_char();
                            advance();
                            lo := cur_char();
                            hex_str := hi + lo;
                            // Simple: convert known hex values
                            if hex_str == "00" { str_val = str_val + "\0"; }
                            else if hex_str == "0a" || hex_str == "0A" { str_val = str_val + "\n"; }
                            else { str_val = str_val + "?"; }
                        }
                        else { str_val = str_val + esc; }
                        advance();
                    }
                } else {
                    str_val = str_val + cur_char();
                    advance();
                }
            }
            advance();
            add_token_str(T_STRING, str_val);
            skip_whitespace();
            continue;
        }

        // Char literal
        if c == "'" {
            advance();
            ch : ., mut = "\0";
            if cur_char() == "\\" {
                advance();
                esc := cur_char();
                if esc == "n" { ch = "\n"; }
                else if esc == "t" { ch = "\t"; }
                else if esc == "r" { ch = "\r"; }
                else if esc == "0" { ch = "\0"; }
                else if esc == "'" { ch = "'"; }
                else if esc == "\\" { ch = "\\"; }
                else if esc == "\"" { ch = "\""; }
                else if esc == "x" {
                    advance();
                    hi := cur_char();
                    advance();
                    lo := cur_char();
                    hex_str := hi + lo;
                    if hex_str == "00" { ch = "\0"; }
                    else if hex_str == "0a" || hex_str == "0A" { ch = "\n"; }
                    else { ch = "?"; }
                }
                else { ch = esc; }
                advance();
            } else {
                ch = cur_char();
                advance();
            }
            if cur_char() == "'" { advance(); }
            add_token_str(T_CHAR, ch);
            skip_whitespace();
            continue;
        }

        // Multi-character operators
        if c == "=" && peek() == "=" { advance(); advance(); add_token(T_EQEQ); skip_whitespace(); continue; }
        if c == "!" && peek() == "=" { advance(); advance(); add_token(T_BANGEQ); skip_whitespace(); continue; }
        if c == "<" && peek() == "=" { advance(); advance(); add_token(T_LTEQ); skip_whitespace(); continue; }
        if c == ">" && peek() == "=" { advance(); advance(); add_token(T_GTEQ); skip_whitespace(); continue; }
        if c == "&" && peek() == "&" { advance(); advance(); add_token(T_ANDAND); skip_whitespace(); continue; }
        if c == "|" && peek() == "|" { advance(); advance(); add_token(T_PIPEPIPE); skip_whitespace(); continue; }
        if c == "-" && peek() == ">" { advance(); advance(); add_token(T_ARROW); skip_whitespace(); continue; }
        if c == "=" && peek() == ">" { advance(); advance(); add_token(T_FATARROW); skip_whitespace(); continue; }
        if c == ":" && peek() == "=" { advance(); advance(); add_token(T_COLON_EQ); skip_whitespace(); continue; }
        if c == ":" && peek() == ":" { advance(); advance(); add_token(T_PATHSEP); skip_whitespace(); continue; }
        if c == "." && peek() == "." { advance(); advance(); add_token(T_DOTDOT); skip_whitespace(); continue; }

        // Compound assignment operators
        if c == "+" && peek() == "=" { advance(); advance(); add_token(T_PLUS_EQ); skip_whitespace(); continue; }
        if c == "-" && peek() == "=" { advance(); advance(); add_token(T_MINUS_EQ); skip_whitespace(); continue; }
        if c == "*" && peek() == "=" { advance(); advance(); add_token(T_STAR_EQ); skip_whitespace(); continue; }
        if c == "/" && peek() == "=" { advance(); advance(); add_token(T_SLASH_EQ); skip_whitespace(); continue; }

        // Single-character tokens
        if c == "(" { advance()); add_token(T_LPAREN); skip_whitespace(); continue; }
        if c == ")" { advance(); add_token(T_RPAREN); skip_whitespace(); continue; }
        if c == "{" { advance(); add_token(T_LBRACE); skip_whitespace(); continue; }
        if c == "}" { advance(); add_token(T_RBRACE); skip_whitespace(); continue; }
        if c == "[" { advance(); add_token(T_LBRACKET); skip_whitespace(); continue; }
        if c == "]" { advance(); add_token(T_RBRACKET); skip_whitespace(); continue; }
        if c == "," { advance(); add_token(T_COMMA); skip_whitespace(); continue; }
        if c == ";" { advance(); add_token(T_SEMI); skip_whitespace(); continue; }
        if c == ":" { advance(); add_token(T_COLON); skip_whitespace(); continue; }
        if c == "." { advance(); add_token(T_DOT); skip_whitespace(); continue; }
        if c == "=" { advance(); add_token(T_EQ); skip_whitespace(); continue; }
        if c == "!" { advance(); add_token(T_BANG); skip_whitespace(); continue; }
        if c == "<" { advance(); add_token(T_LT); skip_whitespace(); continue; }
        if c == ">" { advance(); add_token(T_GT); skip_whitespace(); continue; }
        if c == "+" { advance(); add_token(T_PLUS); skip_whitespace(); continue; }
        if c == "-" { advance(); add_token(T_MINUS); skip_whitespace(); continue; }
        if c == "*" { advance(); add_token(T_STAR); skip_whitespace(); continue; }
        if c == "/" { advance(); add_token(T_SLASH); skip_whitespace(); continue; }
        if c == "%" { advance(); add_token(T_PERCENT); skip_whitespace(); continue; }
        if c == "&" { advance(); add_token(T_AMPERSAND); skip_whitespace(); continue; }
        if c == "_" { advance(); add_token(T_UNDERSCORE); skip_whitespace(); continue; }
        if c == "@" { advance(); add_token(T_AT); skip_whitespace(); continue; }
        if c == "?" { advance(); add_token(T_QUESTION); skip_whitespace(); continue; }

        // Unknown character
        advance();
        skip_whitespace();
    }

    add_token(T_EOF);
}
