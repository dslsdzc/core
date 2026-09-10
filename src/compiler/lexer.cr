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

fn is_digit(c: int) -> int {
    if c >= 48 && c <= 57 { return 1; }
    return 0;
}
fn is_alpha(c: int) -> int {
    if (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 { return 1; }
    return 0;
}
fn is_ident_char(c: int) -> int {
    if is_alpha(c) != 0 || is_digit(c) != 0 { return 1; }
    return 0;
}

fn add_error(msg: string) {
    mi := str_intern(msg);
    grow_errors(g_error_count + 1);
    w64(g_errors, g_error_count * 8, mi);
    g_error_count = g_error_count + 1;
}

fn cur_char() -> int {
    // Use str_len(g_source) instead of g_source_len to avoid
    // global variable patching bug in self-hosted ELF backend.
    // g_source_len is stored to a wrong BSS address in tokenize(),
    // causing cur_char() to always see it as 0 (EOF).
    src_len := str_len(g_source);
    if g_pos >= src_len { return 0; }
    return load8(g_source, g_pos);
}

fn peek() -> int {
    src_len := str_len(g_source);
    if g_pos + 1 >= src_len { return 0; }
    return load8(g_source, g_pos + 1);
}

fn cur_char_at(src: string, pos: int, max_len: int) -> int {
    if pos >= max_len { return 0; }
    return load8(src, pos);
}
fn peek_at(src: string, pos: int, max_len: int) -> int {
    if pos + 1 >= max_len { return 0; }
    return load8(src, pos + 1);
}

fn lookup_keyword(s: string) -> int {
    if s == "fn" { return T_FN; }
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
    if s == "extern" { return T_EXTERN; }
    if s == "impl" { return T_IMPL; }
    if s == "match" { return T_MATCH; }
    if s == "import" { return T_IMPORT; }
    if s == "pub" { return T_PUB; }
    if s == "go" { return T_GO; }
    if s == "await" { return T_AWAIT; }
    if s == "unsafe" { return T_UNSAFE; }
    if s == "flow" { return T_FLOW; }
    if s == "yield" { return T_YIELD; }
    if s == "interface" { return T_INTERFACE; }
    if s == "type" { return T_TYPE; }
    if s == "mod" { return T_MOD; }
    if s == "as" { return T_AS; }
    if s == "auto" { return T_AUTO; }
    if s == "fileid" { return T_FILEID; }
    if s == "move" { return T_MOVE; }
    if s == "self" { return T_SELF; }
    if s == "in" { return T_IN; }
    if s == "None" { return T_NONE; }
    if s == "Some" { return T_SOME; }
    if s == "unit" { return T_UNIT; }
    return T_IDENT;
}

// 2^k（纯整数，k >= 0）
fn pow2i(k: int) -> int {
    v : int = 1; i : ., mut = 0;
    loop { if i >= k { break; } v = v * 2; i = i + 1; }
    return v;
}

// decimal string → IEEE 754 binary64 位模式（纯整数近似，≤18 位有效数字）
// 实现：value = ip + fp/den → 整数部分位 + 64 位长除小数 → 53 位尾数窗口
// 精度：截断（无舍入），≤18 位有效数字内 ~2ulp
fn str_to_f64_bits(s: string) -> int {
    sl := str_len(s);
    i : ., mut = 0;
    neg : int = 0;
    if i < sl && load8(s, i) == 45 { neg = 1; i = i + 1; }
    ip : int = 0; fp : int = 0; den : int = 1; sd : int = 0;
    ip_digits : ., mut = 0; fp_digits : ., mut = 0;
    too_wide : ., mut = 0;
    loop { if i >= sl { break; }
        c := load8(s, i);
        if c == 46 { sd = 1; i = i + 1; continue; }
        if c < 48 || c > 57 { break; }
        if sd != 0 {
            fp_digits = fp_digits + 1;
            if fp_digits <= 18 { fp = fp * 10 + (c - 48); den = den * 10; }
        } else {
            ip_digits = ip_digits + 1;
            if ip_digits <= 19 {
                digit_ip := c - 48;
                if ip > 922337203685477580 ||
                   (ip == 922337203685477580 && digit_ip > 7 + neg) {
                    too_wide = 1;
                } else { ip = ip * 10 + digit_ip; }
            } else { too_wide = 1; }
        }
        i = i + 1; }
    if too_wide != 0 { add_error("decimal literal integer part is too wide"); return 0; }
    if ip == 0 && fp == 0 {
        if neg != 0 { return (-9223372036854775807 - 1); }
        return 0;
    }
    // 小数 64 位（长除：r=fp，每轮 r×2 vs den）
    frac64 : int = 0;
    r : ., mut = fp;
    bits : ., mut = 0;
    loop { if bits >= 64 { break; }
        if r >= 4611686018427387904 { r = r / 2; den = den / 2; }
        r = r * 2;
        frac64 = frac64 * 2;
        if r >= den { r = r - den; frac64 = frac64 + 1; }
        bits = bits + 1; }
    // 整数部分位宽
    bi : ., mut = 0; t2 : ., mut = ip;
    loop { if t2 == 0 { break; } t2 = t2 / 2; bi = bi + 1; }
    mant : int = 0;
    exp : int = 0;
    if bi > 0 {
        sh := 53 - bi;
        if sh >= 0 {
            mant = (ip * pow2i(sh)) + (frac64 / pow2i(64 - sh));
        } else {
            // Avoid pow2i of a negative value for integer parts wider than
            // the binary64 significand.
            mant = ip / pow2i(0 - sh);
        }
        exp = 1023 + (bi - 1);
    } else {
        // 纯小数：frac64 的最高位
        bf : ., mut = 0; t2 = frac64;
        loop { if t2 == 0 { break; } t2 = t2 / 2; bf = bf + 1; }
        if bf == 0 {
            if neg != 0 { return (-9223372036854775807 - 1); }
            return 0;
        }
        sh := 53 - bf;
        if sh >= 0 { mant = frac64 * pow2i(sh); }
        else { mant = frac64 / pow2i(-sh); }
        exp = 1023 + (bf - 65);
    }
    // 组装（mant 截断到 52 位——无舍入）
    bits64 : int = 0;
    if exp > 0 && exp < 2047 {
        bits64 = (mant % 4503599627370496) + exp * 4503599627370496;
    }
    if neg != 0 { bits64 = bits64 + (-9223372036854775807 - 1); }
    return bits64;
}

// Parse an integer literal after tokenization. Supports decimal separators
// and 0x/0o/0b prefixes; out-of-shape literals are rejected as lexer errors.
// 层语义（int-unbounded-semantics 定稿）：语言 int = 无上限数学整数——本守卫报的
// 「integer literal overflow」是编码层限制错误（编译器内部表示 = 经典 64 位机器字
// 投影，超形状 = 该投影无载体），不是语义溢出事件——语义层无溢出概念。表示升级
// （扩展/多字）为 hw-map/远期事项，见 specs/2026-09-06-int-unbounded-semantics.md。
fn str_int_literal(s: string) -> int {
    sl := str_len(s);
    base : ., mut = 10;
    start : ., mut = 0;
    if sl >= 2 && load8(s, 0) == 48 {
        pfx := load8(s, 1);
        if pfx == 120 || pfx == 88 { base = 16; start = 2; }
        else if pfx == 111 || pfx == 79 { base = 8; start = 2; }
        else if pfx == 98 || pfx == 66 { base = 2; start = 2; }
    }
    value : ., mut = 0;
    digits : ., mut = 0;
    i : ., mut = start;
    loop {
        if i >= sl { break; }
        c := load8(s, i);
        if c == 95 { i = i + 1; continue; }
        d : ., mut = -1;
        if c >= 48 && c <= 57 { d = c - 48; }
        else if c >= 65 && c <= 70 { d = c - 55; }
        else if c >= 97 && c <= 102 { d = c - 87; }
        if d < 0 || d >= base { add_error("invalid integer literal"); return 0; }
        // 溢出守卫按 base 校准：固定 i64max/10 阈值只对十进制有效——base 16
        // 累积值在最后一次 ×16 直接环绕（0x8000000000000000 → i64min 绕开守卫）。
        // 阈值必须 = i64max/base（base 10 的末位 d>7 边界保持）。
        if base == 10 {
            if value > 922337203685477580 ||
               (value == 922337203685477580 && d > 7) {
                add_error("integer literal overflow"); return 0;
            }
        } else if base == 16 {
            if value > 576460752303423487 { add_error("integer literal overflow"); return 0; }
        } else if base == 8 {
            if value > 1152921504606846975 { add_error("integer literal overflow"); return 0; }
        } else {
            if value > 4611686018427387903 { add_error("integer literal overflow"); return 0; }
        }
        value = value * base + d;
        digits = digits + 1;
        i = i + 1;
    }
    if digits == 0 { add_error("integer literal requires digits"); return 0; }
    return value;
}

// decimal string → 定点缩放整数（数值迁移 Task 4：dex 精确字面量解析）
// S = 10^6（6 位小数）。整数部分 × S + 小数 6 位；第 7 位小数起四舍五入（半进，
// 与 float_str_bits 的舍入规则一致）。负号直接处理（'-' 前缀）。
// 溢出：|整数部分| ≤ 9.2e12（×S 越界 = 环绕，与 int 溢出一致——文档化限制）。
fn str_to_scaled(s: string) -> int {
    sl := str_len(s);
    i : ., mut = 0;
    neg : int = 0;
    if i < sl && load8(s, i) == 45 { neg = 1; i = i + 1; }
    ip : int = 0; fp : int = 0; nd : int = 0; sd : int = 0; round_up : int = 0;
    loop {
        if i >= sl { break; }
        c := load8(s, i);
        if c == 46 { sd = 1; i = i + 1; continue; }
        if c < 48 || c > 57 { break; }
        if sd != 0 {
            nd = nd + 1;
            if nd <= 6 { fp = fp * 10 + (c - 48); }
            else if nd == 7 { if c >= 53 { round_up = 1; } }
        } else {
            ip = ip * 10 + (c - 48);
        }
        i = i + 1;
    }
    if round_up != 0 {
        fp = fp + 1;
        if fp >= 1000000 { fp = 0; ip = ip + 1; }
    }
    // 小数位补齐到 6 位：fp 是原始数字（如 "3.14" → 14），×10^(6-nd)
    if nd < 6 {
        pad : ., mut = 6 - nd;
        loop {
            if pad <= 0 { break; }
            fp = fp * 10;
            pad = pad - 1;
        }
    }
    v := ip * 1000000 + fp;
    if neg != 0 { return 0 - v; }
    return v;
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

// int_val + lexeme 双载令牌（dex 字面量用：int_val = 缩放整数，lexeme = 原数字串）
fn add_tok_int_lex(kind: int, ival: int, lexeme_ni: int, start_line: int, start_col: int) {
    grow_tokens(g_token_count + 1);
    tp := g_token_count * ESZ_TOKEN;
    w64(g_tokens, tp + OFF_TK_KIND, kind);
    w64(g_tokens, tp + OFF_TK_LEXEME, lexeme_ni);
    w64(g_tokens, tp + OFF_TK_INTVAL, ival);
    w64(g_tokens, tp + OFF_TK_LINE, start_line);
    w64(g_tokens, tp + OFF_TK_COL, start_col);
    g_token_count = g_token_count + 1;
}

fn skip_ws(src: string, pos: int, max_len: int) -> int {
    // Account for the token/comment consumed since the previous call, then
    // consume whitespace. g_pos is the last byte reflected in line/column.
    tracked : ., mut = g_pos;
    loop {
        if tracked >= pos { break; }
        c0 := cur_char_at(src, tracked, max_len);
        if c0 == 10 { g_line = g_line + 1; g_col = 1; }
        else { g_col = g_col + 1; }
        tracked = tracked + 1;
    }
    loop {
        c := cur_char_at(src, pos, max_len);
        if c == 32 || c == 9 || c == 13 || c == 10 {
            if c == 10 { g_line = g_line + 1; g_col = 1; }
            else { g_col = g_col + 1; }
            pos = pos + 1;
        }
        else { break; }
    }
    g_pos = pos;
    return pos;
}

fn tokenize(_src: string) {
    g_token_count = 0;
    // 注意：不再清零 g_error_count——res_imports 会重 tokenize（拼接 import
    // 前后两轮），清零会把首轮词法守卫错误（整数字面量溢出等）吞掉。错误
    // 清理由 run_frontend 会话起点负责（错误累积跨多轮 tokenize）。
    _pos : ., mut = 0;
    g_pos = 0;
    g_line = 1;
    g_col = 1;
    _slen : ., mut = str_len(_src);
    _pos = skip_ws(_src, _pos, _slen);

    loop {
        if _pos >= _slen { break; }
        c := cur_char_at(_src, _pos, _slen);
        start_line : ., mut = g_line;
        start_col : ., mut = g_col;

        // Comments
        if c == 47 && peek_at(_src, _pos, _slen) == 47 {
            _pos = _pos + 2;
            loop {
                if _pos >= _slen { break; }
                if cur_char_at(_src, _pos, _slen) == 10 { _pos = _pos + 1; break; }
                _pos = _pos + 1;
            }
            _pos = skip_ws(_src, _pos, _slen);
            continue;
        }
        if c == 47 && peek_at(_src, _pos, _slen) == 42 {
            _pos = _pos + 2;
            loop {
                if _pos >= _slen { break; }
                if cur_char_at(_src, _pos, _slen) == 42 && peek_at(_src, _pos, _slen) == 47 { _pos = _pos + 2; break; }
                _pos = _pos + 1;
            }
            _pos = skip_ws(_src, _pos, _slen);
            continue;
        }

        // Identifier
        if is_alpha(c) != 0 {
            start := _pos;
            _pos = _pos + 1;
            loop {
                c2 := cur_char_at(_src, _pos, _slen);
                if is_ident_char(c2) != 0 { _pos = _pos + 1; } else { break; }
            }
            ident := str_sub(_src, start, _pos - start);
            kind := lookup_keyword(ident);
            add_tok_str(kind, ident, start_line, start_col);
            _pos = skip_ws(_src, _pos, _slen);
            continue;
        }

        // Number
        if is_digit(c) != 0 || (c == 46 && is_digit(peek_at(_src, _pos, _slen)) != 0) {
            start := _pos;
            if c == 46 { _pos = _pos + 1; c = cur_char_at(_src, _pos, _slen); }
            loop {
                if is_digit(cur_char_at(_src, _pos, _slen)) != 0 { _pos = _pos + 1; }
                else { break; }
            }
            // Hex/octal/binary prefix
            if c == 48 && _pos - start == 1 {
                nx := cur_char_at(_src, _pos, _slen);
                // 三条进制前缀循环均**不再接受** '_'（2026-09-10 语言面收窄 §2）：
                // 遗留 '_' 由下方后缀段落统一响亮报错（不静默消费）。
                if nx == 120 || nx == 88 { _pos = _pos + 1; loop { hc := cur_char_at(_src, _pos, _slen); if is_digit(hc) != 0 || (hc >= 65 && hc <= 70) || (hc >= 97 && hc <= 102) { _pos = _pos + 1; } else { break; } } }
                else if nx == 111 || nx == 79 { _pos = _pos + 1; loop { oc := cur_char_at(_src, _pos, _slen); if (oc >= 48 && oc <= 55) { _pos = _pos + 1; } else { break; } } }
                else if nx == 98 || nx == 66 { _pos = _pos + 1; loop { bc := cur_char_at(_src, _pos, _slen); if bc == 48 || bc == 49 { _pos = _pos + 1; } else { break; } } }
                bad_prefix_digit : ., mut = 0;
                badc := cur_char_at(_src, _pos, _slen);
                if is_ident_char(badc) != 0 { bad_prefix_digit = 1; }
                if bad_prefix_digit != 0 { add_error("invalid digit in integer literal"); }
            }
            // Float: only consume the '.' when it does not start a '..'
            // range operator (otherwise `0..4` lexes as `0.` `.4` and the
            // range is silently lost — the for-loop body never executes).
            has_dot : ., mut = 0;
            if cur_char_at(_src, _pos, _slen) == 46 && peek_at(_src, _pos, _slen) != 46 {
                _pos = _pos + 1;
                has_dot = 1;
                loop { if is_digit(cur_char_at(_src, _pos, _slen)) != 0 { _pos = _pos + 1; } else { break; } }
            }
            // 数字词法收窄（2026-09-10 用户裁决，语言面收窄 §2）：`_` 分隔符与宽度后缀
            // （f32/f64/i8..u64）**均不支持**——一律响亮报错且**不消费**残余字符
            // （按标识符继续 tokenize，使后续解析给出第二重信号，不静默、不猜）。
            // 修复前：`_` 被 is_alpha(95) 当后缀静默消费 → T_INT 取「无值」= 0
            // （`x := 1_000` 静默成 0 = 实质误编译）；宽度后缀同样静默丢弃。
            sx := cur_char_at(_src, _pos, _slen);
            if sx == 95 {
                add_error("invalid character '_' in numeric literal (digit separators not supported)");
            } else if is_alpha(sx) != 0 {
                add_error("invalid suffix on numeric literal (width suffixes retired 2026-09-10)");
            }
            num_str := str_sub(_src, start, _pos - start);
            // dex 字面量（含小数点）：int_val = 定点缩放整数（精确解析，数值迁移
            // Task 4——十进制 → 缩放整数，非二进制近似）；lexeme 槽 = 原数字串
            // （parser 在 apx 场景需要 binary64 位模式：str_to_f64_bits(num_str)）。
            if has_dot != 0 {
                add_tok_int_lex(T_DEX, str_to_scaled(num_str), str_intern(num_str), start_line, start_col);
            } else {
                add_tok_int(T_INT, str_int_literal(num_str), start_line, start_col);
            }
            _pos = skip_ws(_src, _pos, _slen);
            continue;
        }

        // String interpolation
        if c == 34 {
            _pos = _pos + 1;
            str_val : ., mut = "";
            loop {
                cc := cur_char_at(_src, _pos, _slen);
                if cc == 0 || cc == 10 { break; }
                if cc == 34 { _pos = _pos + 1; break; }
                if cc == 92 {
                    _pos = _pos + 1;
                    esc := cur_char_at(_src, _pos, _slen);
                    if esc == 110 { str_val = str_val + chr(10); }
                    else if esc == 116 { str_val = str_val + chr(9); }
                    else if esc == 114 { str_val = str_val + chr(13); }
                    else if esc == 48 { str_val = str_val + chr(0); }
                    else if esc == 39 { str_val = str_val + "'"; }
                    else if esc == 92 { str_val = str_val + chr(92); }
                    else if esc == 34 { str_val = str_val + chr(34); }
                    else if esc == 120 {
                        _pos = _pos + 1; hi := cur_char_at(_src, _pos, _slen); _pos = _pos + 1; lo := cur_char_at(_src, _pos, _slen);
                        hex_str := chr(hi) + chr(lo);
                        if hex_str == "00" { str_val = str_val + chr(0); }
                        else if hex_str == "0a" || hex_str == "0A" { str_val = str_val + chr(10); }
                        else { str_val = str_val + "?"; }
                    }
                    else { str_val = str_val + chr(esc); }
                } else if cc == 36 && peek_at(_src, _pos, _slen) == 123 {
                    // Interpolation: skip for now
                    _pos = _pos + 2;
                    loop { if cur_char_at(_src, _pos, _slen) == 125 { _pos = _pos + 1; break; } _pos = _pos + 1; }
                } else {
                    str_val = str_val + chr(cc);
                }
                _pos = _pos + 1;
            }
            add_tok_str(T_STRING, str_val, start_line, start_col);
            _pos = skip_ws(_src, _pos, _slen);
            continue;
        }

        // Char literal
        if c == 39 {
            _pos = _pos + 1;
            ch : ., mut = chr(0);
            if cur_char_at(_src, _pos, _slen) == 92 {
                _pos = _pos + 1;
                esc2 := cur_char_at(_src, _pos, _slen);
                if esc2 == 110 { ch = chr(10); }
                else if esc2 == 116 { ch = chr(9); }
                else if esc2 == 114 { ch = chr(13); }
                else if esc2 == 48 { ch = chr(0); }
                else if esc2 == 39 { ch = "'"; }
                else if esc2 == 92 { ch = chr(92); }
                else if esc2 == 34 { ch = chr(34); }
                else if esc2 == 120 {
                    _pos = _pos + 1; hi2 := cur_char_at(_src, _pos, _slen); _pos = _pos + 1; lo2 := cur_char_at(_src, _pos, _slen);
                    if chr(hi2) + chr(lo2) == "00" { ch = chr(0); }
                    else { ch = "?"; }
                }
                else { ch = chr(esc2); }
                _pos = _pos + 1;
            } else {
                ch = chr(cur_char_at(_src, _pos, _slen));
                _pos = _pos + 1;
            }
            if cur_char_at(_src, _pos, _slen) == 39 { _pos = _pos + 1; }
            add_tok_str(T_CHAR, ch, start_line, start_col);
            _pos = skip_ws(_src, _pos, _slen);
            continue;
        }

        // Multi-char operators
        if c == 61    && peek_at(_src, _pos, _slen) == 61   { _pos = _pos + 2; add_tok(T_EQEQ, -1, start_line, start_col); _pos = skip_ws(_src, _pos, _slen); continue; }
        if c == 33  && peek_at(_src, _pos, _slen) == 61   { _pos = _pos + 2; add_tok(T_BANGEQ, -1, start_line, start_col); _pos = skip_ws(_src, _pos, _slen); continue; }
        if c == 60    && peek_at(_src, _pos, _slen) == 61   { _pos = _pos + 2; add_tok(T_LTEQ, -1, start_line, start_col); _pos = skip_ws(_src, _pos, _slen); continue; }
        if c == 62    && peek_at(_src, _pos, _slen) == 61   { _pos = _pos + 2; add_tok(T_GTEQ, -1, start_line, start_col); _pos = skip_ws(_src, _pos, _slen); continue; }
        if c == 38   && peek_at(_src, _pos, _slen) == 38  { _pos = _pos + 2; add_tok(T_ANDAND, -1, start_line, start_col); _pos = skip_ws(_src, _pos, _slen); continue; }
        if c == 124  && peek_at(_src, _pos, _slen) == 124 { _pos = _pos + 2; add_tok(T_PIPEPIPE, -1, start_line, start_col); _pos = skip_ws(_src, _pos, _slen); continue; }
        if c == 45  && peek_at(_src, _pos, _slen) == 62   { _pos = _pos + 2; add_tok(T_ARROW, -1, start_line, start_col); _pos = skip_ws(_src, _pos, _slen); continue; }
        if c == 61    && peek_at(_src, _pos, _slen) == 62   { _pos = _pos + 2; add_tok(T_FATARROW, -1, start_line, start_col); _pos = skip_ws(_src, _pos, _slen); continue; }
        if c == 58 && peek_at(_src, _pos, _slen) == 61   { _pos = _pos + 2; add_tok(T_COLON_EQ, -1, start_line, start_col); _pos = skip_ws(_src, _pos, _slen); continue; }
        if c == 58 && peek_at(_src, _pos, _slen) == 58{ _pos = _pos + 2; add_tok(T_PATHSEP, -1, start_line, start_col); _pos = skip_ws(_src, _pos, _slen); continue; }
        if c == 46   && peek_at(_src, _pos, _slen) == 46 {
            _pos = _pos + 2;
            if cur_char_at(_src, _pos, _slen) == 46 { _pos = _pos + 1; add_tok(T_DOTDOTDOT, -1, start_line, start_col); }
            else { add_tok(T_DOTDOT, -1, start_line, start_col); }
            _pos = skip_ws(_src, _pos, _slen); continue; }

        // Compound assignment operators
        if c == 43  && peek_at(_src, _pos, _slen) == 61 { _pos = _pos + 2; add_tok(T_PLUS_EQ, -1, start_line, start_col); _pos = skip_ws(_src, _pos, _slen); continue; }
        if c == 45  && peek_at(_src, _pos, _slen) == 61 { _pos = _pos + 2; add_tok(T_MINUS_EQ, -1, start_line, start_col); _pos = skip_ws(_src, _pos, _slen); continue; }
        if c == 42  && peek_at(_src, _pos, _slen) == 61 { _pos = _pos + 2; add_tok(T_STAR_EQ, -1, start_line, start_col); _pos = skip_ws(_src, _pos, _slen); continue; }
        if c == 47 && peek_at(_src, _pos, _slen) == 61 { _pos = _pos + 2; add_tok(T_SLASH_EQ, -1, start_line, start_col); _pos = skip_ws(_src, _pos, _slen); continue; }

        // Single-char tokens
        if c == 40  { _pos = _pos + 1; add_tok(T_LPAREN, -1, start_line, start_col); _pos = skip_ws(_src, _pos, _slen); continue; }
        if c == 41  { _pos = _pos + 1; add_tok(T_RPAREN, -1, start_line, start_col); _pos = skip_ws(_src, _pos, _slen); continue; }
        if c == 123  { _pos = _pos + 1; add_tok(T_LBRACE, -1, start_line, start_col); _pos = skip_ws(_src, _pos, _slen); continue; }
        if c == 125  { _pos = _pos + 1; add_tok(T_RBRACE, -1, start_line, start_col); _pos = skip_ws(_src, _pos, _slen); continue; }
        if c == 91  { _pos = _pos + 1; add_tok(T_LBRACKET, -1, start_line, start_col); _pos = skip_ws(_src, _pos, _slen); continue; }
        if c == 93  { _pos = _pos + 1; add_tok(T_RBRACKET, -1, start_line, start_col); _pos = skip_ws(_src, _pos, _slen); continue; }
        if c == 44   { _pos = _pos + 1; add_tok(T_COMMA, -1, start_line, start_col); _pos = skip_ws(_src, _pos, _slen); continue; }
        if c == 59    { _pos = _pos + 1; add_tok(T_SEMI, -1, start_line, start_col); _pos = skip_ws(_src, _pos, _slen); continue; }
        if c == 58   { _pos = _pos + 1; add_tok(T_COLON, -1, start_line, start_col); _pos = skip_ws(_src, _pos, _slen); continue; }
        if c == 46     { _pos = _pos + 1; add_tok(T_DOT, -1, start_line, start_col); _pos = skip_ws(_src, _pos, _slen); continue; }
        if c == 61      { _pos = _pos + 1; add_tok(T_EQ, -1, start_line, start_col); _pos = skip_ws(_src, _pos, _slen); continue; }
        if c == 33    { _pos = _pos + 1; add_tok(T_BANG, -1, start_line, start_col); _pos = skip_ws(_src, _pos, _slen); continue; }
        if c == 60      { _pos = _pos + 1; add_tok(T_LT, -1, start_line, start_col); _pos = skip_ws(_src, _pos, _slen); continue; }
        if c == 62      { _pos = _pos + 1; add_tok(T_GT, -1, start_line, start_col); _pos = skip_ws(_src, _pos, _slen); continue; }
        if c == 43    { _pos = _pos + 1; add_tok(T_PLUS, -1, start_line, start_col); _pos = skip_ws(_src, _pos, _slen); continue; }
        if c == 45    { _pos = _pos + 1; add_tok(T_MINUS, -1, start_line, start_col); _pos = skip_ws(_src, _pos, _slen); continue; }
        if c == 42    { _pos = _pos + 1; add_tok(T_STAR, -1, start_line, start_col); _pos = skip_ws(_src, _pos, _slen); continue; }
        if c == 47   { _pos = _pos + 1; add_tok(T_SLASH, -1, start_line, start_col); _pos = skip_ws(_src, _pos, _slen); continue; }
        if c == 37 { _pos = _pos + 1; add_tok(T_PERCENT, -1, start_line, start_col); _pos = skip_ws(_src, _pos, _slen); continue; }
        if c == 38     { _pos = _pos + 1; add_tok(T_AMPERSAND, -1, start_line, start_col); _pos = skip_ws(_src, _pos, _slen); continue; }
        if c == 95   { _pos = _pos + 1; add_tok(T_UNDERSCORE, -1, start_line, start_col); _pos = skip_ws(_src, _pos, _slen); continue; }
        if c == 64      { _pos = _pos + 1; add_tok(T_AT, -1, start_line, start_col); _pos = skip_ws(_src, _pos, _slen); continue; }
        if c == 63    { _pos = _pos + 1; add_tok(T_QUESTION, -1, start_line, start_col); _pos = skip_ws(_src, _pos, _slen); continue; }

        // Unknown
        _pos = _pos + 1;
        _pos = skip_ws(_src, _pos, _slen);
    }

    add_tok(T_EOF, -1, g_line, g_col);
    // Sync back globals
    g_pos = _pos;
    g_source_len = _slen;
}
