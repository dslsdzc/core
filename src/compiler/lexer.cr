// Lexer: tokenizes Core source code using int-based character access.
// Character comparisons use ASCII code constants rather than string allocs.

// Global compiler state
g_source : string, mut
g_source_file : int, mut    // current SourceManager FileId (-1 = none)
g_line_base : int, mut      // first global line belongs to base + 1
g_source_len : int, mut     // cached str_len(g_source), set in tokenize()
g_pos : int, mut
g_line : int, mut
g_col : int, mut

// Layout state.
// The indentation stack starts empty. The first token of the first non-empty line
// establishes the base anchor. The base level emits no INDENT or DEDENT, but it
// occupies one stack slot, so a stack length of at least 1 means the base exists.
g_indent_stack : string, mut
g_indent_cap : int, mut
g_indent_len : int, mut
// Bracket depth. While greater than 0, layout is suspended and lines continue
// implicitly. Braces count too, so struct literal interiors produce no layout.
g_bracket_depth : int, mut
// Whether the current logical line has produced a token. Blank and comment-only
// lines do not emit NEWLINE.
g_line_has_token : int, mut
// Physical line of the last token, used to decide when to emit NEWLINE.
g_last_tok_line : int, mut
// Layout bypass flag. 0 emits INDENT/DEDENT. 1 suppresses them and does not read or
// write the indentation stack. Any tokenize call whose stream is not consumed by
// parse_all or parse_expr must pass 1: hole reentry, dumps, self tests, and LSP
// analysis.
g_layout_bypass : int, mut

// Character constants
C_SP : int = 32
C_TB : int = 9
C_LF : int = 10
C_CR : int = 13
C_NL : int = 10
C_SLASH : int = 47
C_STAR : int = 42
C_BSLASH : int = 92
C_SQUOTE : int = 39
C_DQUOTE : int = 34
C_LPAREN : int = 40
C_RPAREN : int = 41
C_LBRACE : int = 123
C_RBRACE : int = 125
C_LBRACK : int = 91
C_RBRACK : int = 93
C_COMMA : int = 44
C_SEMI : int = 59
C_COLON : int = 58
C_DOT : int = 46
C_EQ : int = 61
C_BANG : int = 33
C_LT : int = 60
C_GT : int = 62
C_PLUS : int = 43
C_DASH : int = 45
C_PERCENT : int = 37
C_AMP : int = 38
C_PIPE : int = 124
C_UNDER : int = 95
C_AT : int = 64
C_QUES : int = 63

fn is_digit(c: int) -> int:
    if c >= 48 && c <= 57:
        return 1
    return 0
fn is_alpha(c: int) -> int:
    if (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95:
        return 1
    return 0
fn is_ident_char(c: int) -> int:
    if is_alpha(c) != 0 || is_digit(c) != 0:
        return 1
    return 0

fn add_error(msg: string):
    mi := str_intern(msg)
    grow_errors(g_error_count + 1)
    cell_store(g_errors, g_error_count * 8, mi)
    g_error_count = g_error_count + 1

fn cur_char() -> int:
    // Use str_len(g_source) instead of g_source_len to avoid
    // global variable patching bug in self-hosted ELF backend.
    // g_source_len is stored to a wrong BSS address in tokenize(),
    // causing cur_char() to always see it as 0 (EOF).
    src_len := str_len(g_source)
    if g_pos >= src_len:
        return 0
    return cell_load_byte(g_source, g_pos)

fn peek() -> int:
    src_len := str_len(g_source)
    if g_pos + 1 >= src_len:
        return 0
    return cell_load_byte(g_source, g_pos + 1)

fn cur_char_at(src: string, pos: int, max_len: int) -> int:
    if pos >= max_len:
        return 0
    return cell_load_byte(src, pos)
fn peek_at(src: string, pos: int, max_len: int) -> int:
    if pos + 1 >= max_len:
        return 0
    return cell_load_byte(src, pos + 1)

fn lookup_keyword(s: string) -> int:
    // None, Some, and move are no longer keywords. Some(x) still parses as an enum
    // constructor through the uppercase identifier rule. catch, dyn, fail, never,
    // none, and spec are keywords.
    return match s:
        "fn" => T_FN
        "mut" => T_MUT
        "return" => T_RETURN
        "if" => T_IF
        "else" => T_ELSE
        "loop" => T_LOOP
        "while" => T_WHILE
        "for" => T_FOR
        "break" => T_BREAK
        "continue" => T_CONTINUE
        "true" => T_TRUE
        "false" => T_FALSE
        "struct" => T_STRUCT
        "enum" => T_ENUM
        "extern" => T_EXTERN
        "impl" => T_IMPL
        "match" => T_MATCH
        "import" => T_IMPORT
        "pub" => T_PUB
        "go" => T_GO
        "await" => T_AWAIT
        "unsafe" => T_UNSAFE
        "flow" => T_FLOW
        "yield" => T_YIELD
        "interface" => T_INTERFACE
        "type" => T_TYPE
        "mod" => T_MOD
        "cast" => T_CAST
        "auto" => T_AUTO
        "fileid" => T_FILEID
        "self" => T_SELF
        "in" => T_IN
        "unit" => T_UNIT
        "none" => T_NONE
        "never" => T_NEVER
        "dyn" => T_DYN
        "catch" => T_CATCH
        "fail" => T_FAIL
        "spec" => T_SPEC
        _ => T_IDENT

// Parse an integer literal. Supports digit separators and 0x/0o/0b prefixes;
// malformed literals are lexer errors.
// Language int is an unbounded mathematical integer. The overflow guard reports an
// encoding limit of the current token payload: a decimal value wider than 64 bits
// has no carrier in this interface. It is not a semantic overflow. Wider
// representations are future work.
fn str_int_literal(s: string) -> int:
    g_int_big = 0
    sl := str_len(s)
    base : ., mut = 10
    start : ., mut = 0
    if sl >= 2 && cell_load_byte(s, 0) == 48:
        pfx := cell_load_byte(s, 1)
        if pfx == 120 || pfx == 88:
            base = 16
            start = 2
        else if pfx == 111 || pfx == 79:
            base = 8
            start = 2
        else if pfx == 98 || pfx == 66:
            base = 2
            start = 2
    value : ., mut = 0
    digits : ., mut = 0
    i : ., mut = start
    loop:
        if i >= sl:
            break
        c := cell_load_byte(s, i)
        if c == 95:
            i = i + 1
            continue
        d : ., mut = -1
        if c >= 48 && c <= 57:
            d = c - 48
        else if c >= 65 && c <= 70:
            d = c - 55
        else if c >= 97 && c <= 102:
            d = c - 87
        if d < 0 || d >= base:
            add_error("invalid integer literal")
            return 0
        // The overflow threshold depends on the base. A fixed i64max/10 threshold
        // works only for decimal; in base 16 the final multiply can wrap past
        // i64min. Use i64max/base, with the decimal digit boundary handled below.
        if base == 10:
            if value > 922337203685477580 || (value == 922337203685477580 && d > 7):
                g_int_big = 1
                return 0
        else if base == 16:
            if value > 576460752303423487:
                g_int_big = 1
                return 0
        else if base == 8:
            if value > 1152921504606846975:
                g_int_big = 1
                return 0
        else:
            if value > 4611686018427387903:
                g_int_big = 1
                return 0
        value = value * base + d
        digits = digits + 1
        i = i + 1
    if digits == 0:
        add_error("integer literal requires digits")
        return 0
    return value

// Convert a decimal string to a fixed-point scaled integer for dex literals.
// Scale is 10^6. Value = integer part * S + first six fractional digits, with
// round-half-up from the seventh digit. A leading minus is handled directly.
// The integer part must be at most about 9.2e12; larger values wrap, matching the
// documented int limit.
fn str_to_scaled(s: string) -> int:
    sl := str_len(s)
    i : ., mut = 0
    neg : int, mut = 0
    if i < sl && cell_load_byte(s, i) == 45:
        neg = 1
        i = i + 1
    ip : int, mut = 0
    fp : int, mut = 0
    nd : int, mut = 0
    sd : int, mut = 0
    round_up : int, mut = 0
    loop:
        if i >= sl:
            break
        c := cell_load_byte(s, i)
        if c == 46:
            sd = 1
            i = i + 1
            continue
        if c < 48 || c > 57:
            break
        if sd != 0:
            nd = nd + 1
            if nd <= 6:
                fp = fp * 10 + (c - 48)
            else if nd == 7:
                if c >= 53:
                    round_up = 1
        else:
            ip = ip * 10 + (c - 48)
        i = i + 1
    if round_up != 0:
        fp = fp + 1
        if fp >= 1000000:
            fp = 0
            ip = ip + 1
    // Pad the fraction to six digits: fp holds the raw digits (3.14 -> 14).
    if nd < 6:
        pad : ., mut = 6 - nd
        loop:
            if pad <= 0:
                break
            fp = fp * 10
            pad = pad - 1
    v := ip * 1000000 + fp
    if neg != 0:
        return 0 - v
    return v

fn token_start_offset(start_line: int, start_col: int) -> int:
    if g_source_file < 0:
        return 0
    // Token lines are in the flat SourceManager line space; spans are file-local.
    local_line := start_line - g_line_base
    return sm_line_start(g_source_file, local_line) + start_col - 1

fn write_tok_span(tp: int, lo: int, tlen: int):
    // Token offsets are global byte offsets: the file's byte_base plus the local
    // offset. Nothing reads them yet; the AST span migration is the first
    // consumer. Before this, the offsets were file-local.
    bb : ., mut = 0
    if g_source_file >= 0 && g_source_file < g_sm_file_count:
        bb = cell_load(g_sm_files, g_source_file * ESZ_SM_FILE + OFF_SMF_BYTE_BASE)
    cell_store(g_tokens, tp + OFF_TK_FILE, g_source_file)
    cell_store(g_tokens, tp + OFF_TK_LO, bb + lo + 1)
    cell_store(g_tokens, tp + OFF_TK_HI, bb + lo + tlen + 1)

fn add_tok(kind: int, lex: int, start_line: int, start_col: int):
    grow_tokens(g_token_count + 1)
    tp := g_token_count * ESZ_TOKEN
    tlen : ., mut = 1
    if lex >= 0:
        tlen = str_len(istr_get(lex))
        if tlen < 1:
            tlen = 1
    cell_store(g_tokens, tp + OFF_TK_KIND, kind)
    cell_store(g_tokens, tp + OFF_TK_LEXEME, lex)
    cell_store(g_tokens, tp + OFF_TK_INTVAL, 0)
    cell_store(g_tokens, tp + OFF_TK_LINE, start_line)
    cell_store(g_tokens, tp + OFF_TK_COL, start_col)
    write_tok_span(tp, token_start_offset(start_line, start_col), tlen)
    g_token_count = g_token_count + 1

fn add_tok_int(kind: int, ival: int, start_line: int, start_col: int):
    grow_tokens(g_token_count + 1)
    tp := g_token_count * ESZ_TOKEN
    cell_store(g_tokens, tp + OFF_TK_KIND, kind)
    cell_store(g_tokens, tp + OFF_TK_LEXEME, -1)
    cell_store(g_tokens, tp + OFF_TK_INTVAL, ival)
    cell_store(g_tokens, tp + OFF_TK_LINE, start_line)
    cell_store(g_tokens, tp + OFF_TK_COL, start_col)
    write_tok_span(tp, token_start_offset(start_line, start_col), 1)
    g_token_count = g_token_count + 1

fn add_tok_str(kind: int, s: string, start_line: int, start_col: int):
    grow_tokens(g_token_count + 1)
    tp := g_token_count * ESZ_TOKEN
    tlen : ., mut = str_len(s)
    if tlen < 1:
        tlen = 1
    cell_store(g_tokens, tp + OFF_TK_KIND, kind)
    si := str_intern(s)
    cell_store(g_tokens, tp + OFF_TK_LEXEME, si)
    cell_store(g_tokens, tp + OFF_TK_INTVAL, 0)
    cell_store(g_tokens, tp + OFF_TK_LINE, start_line)
    cell_store(g_tokens, tp + OFF_TK_COL, start_col)
    write_tok_span(tp, token_start_offset(start_line, start_col), tlen)
    g_token_count = g_token_count + 1

// Token with both int_val and lexeme, used for dex literals: int_val is the scaled integer and lexeme is the source digits.
fn add_tok_int_lex(kind: int, ival: int, lexeme_ni: int, start_line: int, start_col: int):
    grow_tokens(g_token_count + 1)
    tp := g_token_count * ESZ_TOKEN
    tlen : ., mut = str_len(istr_get(lexeme_ni))
    if tlen < 1:
        tlen = 1
    cell_store(g_tokens, tp + OFF_TK_KIND, kind)
    cell_store(g_tokens, tp + OFF_TK_LEXEME, lexeme_ni)
    cell_store(g_tokens, tp + OFF_TK_INTVAL, ival)
    cell_store(g_tokens, tp + OFF_TK_LINE, start_line)
    cell_store(g_tokens, tp + OFF_TK_COL, start_col)
    write_tok_span(tp, token_start_offset(start_line, start_col), tlen)
    g_token_count = g_token_count + 1

// Layout helpers. Anchor computation and the colon end-of-line check must share
// one comment- and string-aware scanner. layout_skip_blank is that single
// implementation; colon_at_line_end is a read-only lookahead built on it.

// Skip whitespace and comments from idx, including // comments and multi-line
// /* */ comments. Returns the new index. Whether a physical line boundary was
// crossed is written to g_layout_saw_nl; the caller must clear it before reading.
// The language has no tuple return, so an out global carries the second value.
g_layout_saw_nl : int, mut

fn layout_skip_blank(src: string, idx: int, max_len: int) -> int:
    i : ., mut = idx
    g_layout_saw_nl = 0
    loop:
        if i >= max_len:
            break
        c := cur_char_at(src, i, max_len)
        if c == 32 || c == 9 || c == 13:
            i = i + 1
            continue
        if c == 10:
            g_layout_saw_nl = 1
            i = i + 1
            continue
        if c == 47 && cur_char_at(src, i + 1, max_len) == 47:
            loop:
                if i >= max_len:
                    break
                if cur_char_at(src, i, max_len) == 10:
                    break
                i = i + 1
            continue
        if c == 47 && cur_char_at(src, i + 1, max_len) == 42:
            i = i + 2
            loop:
                if i >= max_len:
                    break
                if cur_char_at(src, i, max_len) == 10:
                    g_layout_saw_nl = 1
                if cur_char_at(src, i, max_len) == 42 && cur_char_at(src, i + 1, max_len) == 47:
                    i = i + 2
                    break
                i = i + 1
            continue
        break
    return i

// A colon is at end of line when no token follows it on the same physical line.
// Whitespace and comments do not count: a line comment, a block comment, or a
// multi-line block comment still leaves the colon at line end. `x : int = 5 // note`
// is an inline colon. The caller passes pos just after the colon.
fn colon_at_line_end(src: string, pos: int, max_len: int) -> int:
    i := layout_skip_blank(src, pos, max_len)
    if g_layout_saw_nl != 0:
        // A line boundary was crossed, so no token follows the colon on this line.
        return 1
    if i >= max_len:
        return 1
    return 0

fn ind_top() -> int:
    return cell_load(g_indent_stack, (g_indent_len - 1) * 8)

fn ind_push(col: int):
    if g_indent_len >= g_indent_cap:
        ncap : ., mut = g_indent_cap * 2
        if ncap < 16:
            ncap = 16
        nv := alloc(ncap * 8)
        if g_indent_cap > 0:
            cell_copy(g_indent_stack, g_indent_cap * 8, nv)
        g_indent_stack = nv
        g_indent_cap = ncap
    cell_store(g_indent_stack, g_indent_len * 8, col)
    g_indent_len = g_indent_len + 1

// Emit NEWLINE and any INDENT/DEDENT when crossing a physical line outside
// brackets. Blank and comment-only lines produce no token and do not change the
// anchor, so this is called only after a line that produced a token. The anchor
// column is the first token's column. The first non-empty line establishes the
// base.
fn layout_break():
    add_tok(T_NEWLINE, -1, g_line, g_col)
    g_line_has_token = 0
    col : ., mut = g_col
    top := ind_top()
    if col > top:
        ind_push(col)
        add_tok(T_INDENT, -1, g_line, col)
    else if col < top:
        loop:
            if g_indent_len <= 1:
                break
            if ind_top() <= col:
                break
            g_indent_len = g_indent_len - 1
            add_tok(T_DEDENT, -1, g_line, col)
        if ind_top() != col:
            if g_indent_len == 1:
                // Shallower than the unit base anchor.
                add_error("layout anchor " + int_str(col) + " is shallower than the unit base anchor " + int_str(ind_top()))
            else:
                // The column matches no open level. Report an error instead of
                // aligning to the nearest level.
                add_error("inconsistent dedent: column " + int_str(col) + " matches no open indent level")

// End of source: emit the final NEWLINE and pop every open indentation level,
// emitting one DEDENT each. The base level has no INDENT, so it emits no DEDENT.
fn finish_layout():
    if g_line_has_token != 0:
        add_tok(T_NEWLINE, -1, g_line, g_col)
        g_line_has_token = 0
    loop:
        if g_indent_len <= 1:
            break
        g_indent_len = g_indent_len - 1
        add_tok(T_DEDENT, -1, g_line, g_col)

fn skip_ws(src: string, pos: int, max_len: int) -> int:
    // Account for the token/comment consumed since the previous call, then
    // consume whitespace. g_pos is the last byte reflected in line/column.
    tracked : ., mut = g_pos
    loop:
        if tracked >= pos:
            break
        c0 := cur_char_at(src, tracked, max_len)
        if c0 == 10:
            g_line = g_line + 1
            g_col = 1
        else:
            g_col = g_col + 1
        tracked = tracked + 1
    loop:
        c := cur_char_at(src, pos, max_len)
        if c == 32 || c == 9 || c == 13 || c == 10:
            if c == 10:
                g_line = g_line + 1
                g_col = 1
            else:
                g_col = g_col + 1
            pos = pos + 1
        else:
            break
    g_pos = pos
    return pos

// The second parameter is the layout bypass flag. 0 emits INDENT/DEDENT. 1
// suppresses them and does not read or write the indentation stack. It is an
// explicit parameter so the bypass is visible at each call site.
// A call site must pass 1 exactly when its token stream is not consumed by
// parse_all or parse_expr: dumps, rescans, self tests, LSP analysis, or reentry.
fn tokenize(file_id: int, layout_bypass: int):
    g_source = sm_file_text(file_id)
    g_source_file = file_id
    g_line_base = sm_file_line_base(file_id)
    tokenize_impl(g_source, layout_bypass)

// Source-only entry for rescans that do not carry a FileId. Spans are marked
// unattributed (-1) rather than inheriting the previous file.
fn tokenize_source(_src: string, layout_bypass: int):
    g_source_file = -1
    g_line_base = 0
    tokenize_impl(_src, layout_bypass)

fn tokenize_impl(_src: string, layout_bypass: int):
    g_layout_bypass = layout_bypass
    g_token_count = 0
    // Do not clear g_error_count. res_imports tokenizes twice while joining
    // imports, and clearing here would drop lexer errors from the first pass.
    // run_frontend clears errors at the start of a session.
    _pos : ., mut = 0
    g_pos = 0
    g_line = g_line_base + 1
    g_col = 1
    // Reset layout bookkeeping. With bypass set, the indentation stack is neither
    // read nor written; only the counters are cleared.
    g_indent_len = 0
    g_bracket_depth = 0
    g_line_has_token = 0
    g_last_tok_line = 0
    _slen : ., mut = str_len(_src)
    _pos = skip_ws(_src, _pos, _slen)

    loop:
        // Consume comments and following whitespace first, so the line-start check
        // sees a real token. Blank and comment-only lines are no-ops: they produce
        // no token and do not change the anchor. If the comment column were used as
        // the anchor, a trailing comment followed by an indented comment could
        // invent an INDENT.
        loop:
            _pos = skip_ws(_src, _pos, _slen)
            if _pos >= _slen:
                break
            cc := cur_char_at(_src, _pos, _slen)
            if cc == 47 && cur_char_at(_src, _pos + 1, _slen) == 47:
                _pos = _pos + 2
                loop:
                    if _pos >= _slen:
                        break
                    if cur_char_at(_src, _pos, _slen) == 10:
                        _pos = _pos + 1
                        break
                    _pos = _pos + 1
                continue
            if cc == 47 && cur_char_at(_src, _pos + 1, _slen) == 42:
                _pos = _pos + 2
                loop:
                    if _pos >= _slen:
                        break
                    if cur_char_at(_src, _pos, _slen) == 42 && cur_char_at(_src, _pos + 1, _slen) == 47:
                        _pos = _pos + 2
                        break
                    _pos = _pos + 1
                continue
            break
        if _pos >= _slen:
            break
        // Layout emission:
        //  - only outside brackets; lines inside ()/[]/{} continue implicitly;
        //  - emit NEWLINE only after a line that produced a token, so blank and
        //    comment-only lines are no-ops;
        //  - the anchor column is this token's column;
        //  - skip everything when the layout bypass flag is set.
        if g_layout_bypass == 0:
            if g_bracket_depth == 0 && g_line_has_token != 0 && g_line != g_last_tok_line:
                layout_break()
            g_line_has_token = 1
            g_last_tok_line = g_line
            if g_indent_len == 0:
                // The first non-empty line establishes the anchor. The base level
                // emits no INDENT; otherwise top-level code would be wrapped.
                ind_push(g_col)
        c : ., mut = cur_char_at(_src, _pos, _slen)
        start_line : ., mut = g_line
        start_col : ., mut = g_col

        // Identifier
        if is_alpha(c) != 0:
            start := _pos
            _pos = _pos + 1
            loop:
                c2 := cur_char_at(_src, _pos, _slen)
                if is_ident_char(c2) != 0:
                    _pos = _pos + 1
                else:
                    break
            ident := str_sub(_src, start, _pos - start)
            kind := lookup_keyword(ident)
            add_tok_str(kind, ident, start_line, start_col)
            _pos = skip_ws(_src, _pos, _slen)
            continue

        // Number
        if is_digit(c) != 0 || (c == 46 && is_digit(peek_at(_src, _pos, _slen)) != 0):
            start := _pos
            if c == 46:
                _pos = _pos + 1
                c = cur_char_at(_src, _pos, _slen)
            loop:
                if is_digit(cur_char_at(_src, _pos, _slen)) != 0:
                    _pos = _pos + 1
                else:
                    break
            // Hex/octal/binary prefix
            if c == 48 && _pos - start == 1:
                nx := cur_char_at(_src, _pos, _slen)
                // The three base-prefix loops do not accept '_'. A leftover '_' is
                // rejected by the suffix check below.
                if nx == 120 || nx == 88:
                    _pos = _pos + 1
                    loop:
                        hc := cur_char_at(_src, _pos, _slen)
                        if is_digit(hc) != 0 || (hc >= 65 && hc <= 70) || (hc >= 97 && hc <= 102):
                            _pos = _pos + 1
                        else:
                            break
                else if nx == 111 || nx == 79:
                    _pos = _pos + 1
                    loop:
                        oc := cur_char_at(_src, _pos, _slen)
                        if (oc >= 48 && oc <= 55):
                            _pos = _pos + 1
                        else:
                            break
                else if nx == 98 || nx == 66:
                    _pos = _pos + 1
                    loop:
                        bc := cur_char_at(_src, _pos, _slen)
                        if bc == 48 || bc == 49:
                            _pos = _pos + 1
                        else:
                            break
                bad_prefix_digit : ., mut = 0
                badc := cur_char_at(_src, _pos, _slen)
                if is_ident_char(badc) != 0:
                    bad_prefix_digit = 1
                if bad_prefix_digit != 0:
                    add_error("invalid digit in integer literal")
            // Consume '.' only when it does not start a '..' range operator.
            // Otherwise `0..4` would lex as `0.` and `.4`, and the range would be
            // lost.
            has_dot : ., mut = 0
            if cur_char_at(_src, _pos, _slen) == 46 && peek_at(_src, _pos, _slen) != 46:
                _pos = _pos + 1
                has_dot = 1
                loop:
                    if is_digit(cur_char_at(_src, _pos, _slen)) != 0:
                        _pos = _pos + 1
                    else:
                        break
            // Digit separators and width suffixes (f32/f64/i8..u64) are not
            // supported. Report an error and leave the remaining characters to be
            // tokenized as an identifier, so the parser can add a second signal.
            sx := cur_char_at(_src, _pos, _slen)
            if sx == 95:
                add_error("invalid character '_' in numeric literal (digit separators not supported)")
            else if is_alpha(sx) != 0:
                add_error("invalid suffix on numeric literal (width suffixes retired 2026-09-10)")
            num_str := str_sub(_src, start, _pos - start)
            // A dex literal with a decimal point stores the scaled integer in
            // int_val and the original text in the lexeme slot. The parser can
            // derive binary64 bits with str_to_f64_bits when needed.
            if has_dot != 0:
                add_tok_int_lex(T_DEX, str_to_scaled(num_str), str_intern(num_str), start_line, start_col)
            else:
                iv : ., mut = str_int_literal(num_str)
                if g_int_big != 0:
                    add_tok_str(T_BIGINT, big_lit_decimal(num_str), start_line, start_col)
                else:
                    add_tok_int(T_INT, iv, start_line, start_col)
            _pos = skip_ws(_src, _pos, _slen)
            continue

        // String literals, including `${...}` interpolation. An interpolated literal
        // is emitted in parts: T_STRING for text and T_INTERP for a hole. The parser
        // assembles seg + conv(hole), and the checker rewrites the conversion in
        // place. A literal without holes is a single T_STRING with iv=0.
        if c == 34:
            _pos = _pos + 1
            sp : ., mut = _pos                     // 串内容起点（同行内换算列；串内不跨行）
            seg_pos : ., mut = sp                  // 当前段起点
            run_start : ., mut = g_token_count     // first token of this literal; iv is backfilled at the end
            str_val : ., mut = ""
            has_hole : ., mut = 0
            loop:
                cc := cur_char_at(_src, _pos, _slen)
                if cc == 0 || cc == 10:
                    break
                if cc == 34:
                    _pos = _pos + 1
                    break
                if cc == 92:
                    _pos = _pos + 1
                    esc := cur_char_at(_src, _pos, _slen)
                    if esc == 110:
                        str_val = str_val + chr(10)
                    else if esc == 116:
                        str_val = str_val + chr(9)
                    else if esc == 114:
                        str_val = str_val + chr(13)
                    else if esc == 48:
                        str_val = str_val + chr(0)
                    else if esc == 39:
                        str_val = str_val + "'"
                    else if esc == 92:
                        str_val = str_val + chr(92)
                    else if esc == 34:
                        str_val = str_val + chr(34)
                    else if esc == 120:
                        _pos = _pos + 1
                        hi := cur_char_at(_src, _pos, _slen)
                        _pos = _pos + 1
                        lo := cur_char_at(_src, _pos, _slen)
                        hex_str := chr(hi) + chr(lo)
                        if hex_str == "00":
                            str_val = str_val + chr(0)
                        else if hex_str == "0a" || hex_str == "0A":
                            str_val = str_val + chr(10)
                        else:
                            str_val = str_val + "?"
                    else:
                        str_val = str_val + chr(esc)
                else if cc == 36 && peek_at(_src, _pos, _slen) == 123:
                    // Interpolation hole `${...}`. Scan with brace matching, so
                    // `${S{f=1}}` takes the matching }. String literals and escapes
                    // inside the hole are skipped as a unit. A newline or EOF ends the
                    // hole; the parser reports P027 if it is unclosed.
                    if str_len(str_val) > 0:
                        col : ., mut = start_col
                        if seg_pos != sp:
                            col = start_col + 1 + (seg_pos - sp)
                        add_tok_str(T_STRING, str_val, start_line, col)
                    str_val = ""
                    has_hole = 1
                    hs : ., mut = _pos + 2
                    hp : ., mut = hs
                    depth : ., mut = 1
                    loop:
                        hc := cur_char_at(_src, hp, _slen)
                        if hc == 0 || hc == 10:
                            break
                        if hc == 34:
                            hp = hp + 1
                            loop:
                                sc := cur_char_at(_src, hp, _slen)
                                if sc == 0 || sc == 10:
                                    break
                                if sc == 92:
                                    hp = hp + 2
                                    continue
                                hp = hp + 1
                                if sc == 34:
                                    break
                            continue
                        // Skip a char literal in the hole; a { inside quotes must not
                        // affect brace depth.
                        if hc == 39:
                            hp = hp + 1
                            loop:
                                cc2 := cur_char_at(_src, hp, _slen)
                                if cc2 == 0 || cc2 == 10:
                                    break
                                if cc2 == 92:
                                    hp = hp + 2
                                    continue
                                hp = hp + 1
                                if cc2 == 39:
                                    break
                            continue
                        // Skip a line comment in the hole.
                        if hc == 47 && cur_char_at(_src, hp + 1, _slen) == 47:
                            loop:
                                cc3 := cur_char_at(_src, hp, _slen)
                                if cc3 == 0 || cc3 == 10:
                                    break
                                hp = hp + 1
                            continue
                        // Skip a block comment in the hole.
                        if hc == 47 && cur_char_at(_src, hp + 1, _slen) == 42:
                            hp = hp + 2
                            loop:
                                cc4 := cur_char_at(_src, hp, _slen)
                                if cc4 == 0:
                                    break
                                if cc4 == 42 && cur_char_at(_src, hp + 1, _slen) == 47:
                                    hp = hp + 2
                                    break
                                hp = hp + 1
                            continue
                        if hc == 123:
                            depth = depth + 1
                        if hc == 125:
                            depth = depth - 1
                            if depth == 0:
                                break
                        hp = hp + 1
                    cflag : ., mut = 4                          // iv bit2 = 洞已闭合
                    if cur_char_at(_src, hp, _slen) != 125:
                        cflag = 0
                    ti := g_token_count
                    add_tok_str(T_INTERP, str_sub(_src, hs, hp - hs), start_line, start_col + 1 + (hs - sp))
                    cell_store(g_tokens, ti * ESZ_TOKEN + OFF_TK_INTVAL, cflag)
                    _pos = hp
                    if cflag != 0:
                        _pos = _pos + 1
                    seg_pos = _pos
                    continue
                else:
                    str_val = str_val + chr(cc)
                _pos = _pos + 1
            if str_len(str_val) > 0 || has_hole == 0:
                col2 : ., mut = start_col
                if seg_pos != sp:
                    col2 = start_col + 1 + (seg_pos - sp)
                add_tok_str(T_STRING, str_val, start_line, col2)
            if has_hole != 0:
                // Fill iv for each part: +1 means it belongs to an interpolated
                // literal; +2 means another part follows. Bit 2 (4) marks a closed
                // hole. Use addition, not bitwise or: the bootstrap backend does not
                // support `|` or `&`. This lets the parser join only parts of the same
                // literal; `"${x}" "y"` stays two literals.
                ri : ., mut = run_start
                loop:
                    if ri >= g_token_count:
                        break
                    iv : ., mut = cell_load(g_tokens, ri * ESZ_TOKEN + OFF_TK_INTVAL)
                    iv = iv + 1
                    if ri + 1 < g_token_count:
                        iv = iv + 2
                    cell_store(g_tokens, ri * ESZ_TOKEN + OFF_TK_INTVAL, iv)
                    ri = ri + 1
            _pos = skip_ws(_src, _pos, _slen)
            continue

        // Char literal
        if c == 39:
            _pos = _pos + 1
            ch : ., mut = chr(0)
            if cur_char_at(_src, _pos, _slen) == 92:
                _pos = _pos + 1
                esc2 := cur_char_at(_src, _pos, _slen)
                if esc2 == 110:
                    ch = chr(10)
                else if esc2 == 116:
                    ch = chr(9)
                else if esc2 == 114:
                    ch = chr(13)
                else if esc2 == 48:
                    ch = chr(0)
                else if esc2 == 39:
                    ch = "'"
                else if esc2 == 92:
                    ch = chr(92)
                else if esc2 == 34:
                    ch = chr(34)
                else if esc2 == 120:
                    _pos = _pos + 1
                    hi2 := cur_char_at(_src, _pos, _slen)
                    _pos = _pos + 1
                    lo2 := cur_char_at(_src, _pos, _slen)
                    if chr(hi2) + chr(lo2) == "00":
                        ch = chr(0)
                    else:
                        ch = "?"
                else:
                    ch = chr(esc2)
                _pos = _pos + 1
            else:
                ch = chr(cur_char_at(_src, _pos, _slen))
                _pos = _pos + 1
            if cur_char_at(_src, _pos, _slen) == 39:
                _pos = _pos + 1
            add_tok_str(T_CHAR, ch, start_line, start_col)
            _pos = skip_ws(_src, _pos, _slen)
            continue

        // Multi-char operators
        if c == 61    && peek_at(_src, _pos, _slen) == 61:
            _pos = _pos + 2
            add_tok(T_EQEQ, -1, start_line, start_col)
            _pos = skip_ws(_src, _pos, _slen)
            continue
        if c == 33  && peek_at(_src, _pos, _slen) == 61:
            _pos = _pos + 2
            add_tok(T_BANGEQ, -1, start_line, start_col)
            _pos = skip_ws(_src, _pos, _slen)
            continue
        if c == 60    && peek_at(_src, _pos, _slen) == 61:
            _pos = _pos + 2
            add_tok(T_LTEQ, -1, start_line, start_col)
            _pos = skip_ws(_src, _pos, _slen)
            continue
        if c == 62    && peek_at(_src, _pos, _slen) == 61:
            _pos = _pos + 2
            add_tok(T_GTEQ, -1, start_line, start_col)
            _pos = skip_ws(_src, _pos, _slen)
            continue
        if c == 38   && peek_at(_src, _pos, _slen) == 38:
            _pos = _pos + 2
            add_tok(T_ANDAND, -1, start_line, start_col)
            _pos = skip_ws(_src, _pos, _slen)
            continue
        if c == 124  && peek_at(_src, _pos, _slen) == 124:
            _pos = _pos + 2
            add_tok(T_PIPEPIPE, -1, start_line, start_col)
            _pos = skip_ws(_src, _pos, _slen)
            continue
        // Single vertical bar, used as a match arm prefix. It is a real token so
        // it is not lost through the unknown-token path. `||` uses T_PIPEPIPE.
        if c == 124:
            _pos = _pos + 1
            add_tok(T_PIPE, -1, start_line, start_col)
            _pos = skip_ws(_src, _pos, _slen)
            continue
        if c == 45  && peek_at(_src, _pos, _slen) == 62:
            _pos = _pos + 2
            add_tok(T_ARROW, -1, start_line, start_col)
            _pos = skip_ws(_src, _pos, _slen)
            continue
        if c == 61    && peek_at(_src, _pos, _slen) == 62:
            _pos = _pos + 2
            add_tok(T_FATARROW, -1, start_line, start_col)
            _pos = skip_ws(_src, _pos, _slen)
            continue
        if c == 58 && peek_at(_src, _pos, _slen) == 61:
            _pos = _pos + 2
            add_tok(T_COLON_EQ, -1, start_line, start_col)
            _pos = skip_ws(_src, _pos, _slen)
            continue
        if c == 58 && peek_at(_src, _pos, _slen) == 58:
            _pos = _pos + 2
            add_tok(T_PATHSEP, -1, start_line, start_col)
            _pos = skip_ws(_src, _pos, _slen)
            continue
        if c == 46   && peek_at(_src, _pos, _slen) == 46:
            _pos = _pos + 2
            if cur_char_at(_src, _pos, _slen) == 46:
                _pos = _pos + 1
                add_tok(T_DOTDOTDOT, -1, start_line, start_col)
            else:
                add_tok(T_DOTDOT, -1, start_line, start_col)
            _pos = skip_ws(_src, _pos, _slen)
            continue

        // Compound assignment operators
        if c == 43  && peek_at(_src, _pos, _slen) == 61:
            _pos = _pos + 2
            add_tok(T_PLUS_EQ, -1, start_line, start_col)
            _pos = skip_ws(_src, _pos, _slen)
            continue
        if c == 45  && peek_at(_src, _pos, _slen) == 61:
            _pos = _pos + 2
            add_tok(T_MINUS_EQ, -1, start_line, start_col)
            _pos = skip_ws(_src, _pos, _slen)
            continue
        if c == 42  && peek_at(_src, _pos, _slen) == 61:
            _pos = _pos + 2
            add_tok(T_STAR_EQ, -1, start_line, start_col)
            _pos = skip_ws(_src, _pos, _slen)
            continue
        if c == 47 && peek_at(_src, _pos, _slen) == 61:
            _pos = _pos + 2
            add_tok(T_SLASH_EQ, -1, start_line, start_col)
            _pos = skip_ws(_src, _pos, _slen)
            continue

        // Single-char tokens
        // Bracket depth counts ( ) [ ] { }. Layout is suspended inside brackets, so
        // struct literal interiors produce no layout regions.
        if c == 40:
            _pos = _pos + 1
            g_bracket_depth = g_bracket_depth + 1
            add_tok(T_LPAREN, -1, start_line, start_col)
            _pos = skip_ws(_src, _pos, _slen)
            continue
        if c == 41:
            _pos = _pos + 1
            if g_bracket_depth > 0:
                g_bracket_depth = g_bracket_depth - 1
            add_tok(T_RPAREN, -1, start_line, start_col)
            _pos = skip_ws(_src, _pos, _slen)
            continue
        if c == 123:
            _pos = _pos + 1
            g_bracket_depth = g_bracket_depth + 1
            add_tok(T_LBRACE, -1, start_line, start_col)
            _pos = skip_ws(_src, _pos, _slen)
            continue
        if c == 125:
            _pos = _pos + 1
            if g_bracket_depth > 0:
                g_bracket_depth = g_bracket_depth - 1
            add_tok(T_RBRACE, -1, start_line, start_col)
            _pos = skip_ws(_src, _pos, _slen)
            continue
        if c == 91:
            _pos = _pos + 1
            g_bracket_depth = g_bracket_depth + 1
            add_tok(T_LBRACKET, -1, start_line, start_col)
            _pos = skip_ws(_src, _pos, _slen)
            continue
        if c == 93:
            _pos = _pos + 1
            if g_bracket_depth > 0:
                g_bracket_depth = g_bracket_depth - 1
            add_tok(T_RBRACKET, -1, start_line, start_col)
            _pos = skip_ws(_src, _pos, _slen)
            continue
        if c == 44:
            _pos = _pos + 1
            add_tok(T_COMMA, -1, start_line, start_col)
            _pos = skip_ws(_src, _pos, _slen)
            continue
        if c == 59:
            _pos = _pos + 1
            add_tok(T_SEMI, -1, start_line, start_col)
            _pos = skip_ws(_src, _pos, _slen)
            continue
        if c == 58:
            // A colon at end of line opens a region (T_COLON_BLOCK). An inline colon
            // is a declaration separator (T_COLON_DECL). The two cases are disjoint,
            // so the parser needs no lookahead. `:=` and `::` are consumed earlier.
            le := colon_at_line_end(_src, _pos + 1, _slen)
            _pos = _pos + 1
            if le != 0:
                add_tok(T_COLON_BLOCK, -1, start_line, start_col)
            else:
                add_tok(T_COLON_DECL, -1, start_line, start_col)
            _pos = skip_ws(_src, _pos, _slen)
            continue
        if c == 46:
            _pos = _pos + 1
            add_tok(T_DOT, -1, start_line, start_col)
            _pos = skip_ws(_src, _pos, _slen)
            continue
        if c == 61:
            _pos = _pos + 1
            add_tok(T_EQ, -1, start_line, start_col)
            _pos = skip_ws(_src, _pos, _slen)
            continue
        if c == 33:
            _pos = _pos + 1
            add_tok(T_BANG, -1, start_line, start_col)
            _pos = skip_ws(_src, _pos, _slen)
            continue
        if c == 60:
            _pos = _pos + 1
            add_tok(T_LT, -1, start_line, start_col)
            _pos = skip_ws(_src, _pos, _slen)
            continue
        if c == 62:
            _pos = _pos + 1
            add_tok(T_GT, -1, start_line, start_col)
            _pos = skip_ws(_src, _pos, _slen)
            continue
        if c == 43:
            _pos = _pos + 1
            add_tok(T_PLUS, -1, start_line, start_col)
            _pos = skip_ws(_src, _pos, _slen)
            continue
        if c == 45:
            _pos = _pos + 1
            add_tok(T_MINUS, -1, start_line, start_col)
            _pos = skip_ws(_src, _pos, _slen)
            continue
        if c == 42:
            _pos = _pos + 1
            add_tok(T_STAR, -1, start_line, start_col)
            _pos = skip_ws(_src, _pos, _slen)
            continue
        if c == 47:
            _pos = _pos + 1
            add_tok(T_SLASH, -1, start_line, start_col)
            _pos = skip_ws(_src, _pos, _slen)
            continue
        if c == 37:
            _pos = _pos + 1
            add_tok(T_PERCENT, -1, start_line, start_col)
            _pos = skip_ws(_src, _pos, _slen)
            continue
        if c == 38:
            _pos = _pos + 1
            add_tok(T_AMPERSAND, -1, start_line, start_col)
            _pos = skip_ws(_src, _pos, _slen)
            continue
        if c == 95:
            _pos = _pos + 1
            add_tok(T_UNDERSCORE, -1, start_line, start_col)
            _pos = skip_ws(_src, _pos, _slen)
            continue
        if c == 64:
            _pos = _pos + 1
            add_tok(T_AT, -1, start_line, start_col)
            _pos = skip_ws(_src, _pos, _slen)
            continue
        if c == 63:
            _pos = _pos + 1
            add_tok(T_QUESTION, -1, start_line, start_col)
            _pos = skip_ws(_src, _pos, _slen)
            continue
        // `#` starts a spec annotation such as #check(expr) or #ensure(expr).
        // The parser requires an identifier after it. Previously `#` fell into the
        // unknown-token path and was dropped, so annotated source produced a wrong
        // result with rc=0.
        if c == 35:
            _pos = _pos + 1
            add_tok(T_HASH, -1, start_line, start_col)
            _pos = skip_ws(_src, _pos, _slen)
            continue

        // Unknown
        _pos = _pos + 1
        _pos = skip_ws(_src, _pos, _slen)

    // End of source: emit the final NEWLINE and pop every open indentation level,
    // one DEDENT each. The bypass mode emits nothing and does not touch the stack.
    if g_layout_bypass == 0:
        finish_layout()
    add_tok(T_EOF, -1, g_line, g_col)
    // Sync back globals
    g_pos = _pos
    g_source_len = _slen
