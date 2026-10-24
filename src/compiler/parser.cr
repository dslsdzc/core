// Parser: recursive descent with flat AST output

// Global state for parser (shared globals in globals.cr)
g_token_pos : int, mut

// Buffer for batch declaration overflow (a, b : int = 1, 2)
g_extra_lets : string, mut
g_extra_lets_cap : int, mut
g_extra_let_count : int, mut

// Struct literals: after an identifier, '{' always starts a struct literal.
// The old ambiguity flag was removed together with brace-delimited blocks.

fn alloc_node(kind: int, a: int, b: int, c: int, iv: int, tv: int, d: int, line: int, col: int) -> int:
    return ast_alloc(kind, a, b, c, iv, tv, d, line, col)

fn cur_tok() -> int:
    return g_token_pos
fn tok_k(p: int) -> int:
    return cell_load(g_tokens, p * ESZ_TOKEN + OFF_TK_KIND)
fn tok_lx(p: int) -> string:
    return istr_get(cell_load(g_tokens, p * ESZ_TOKEN + OFF_TK_LEXEME))
fn tok_iv(p: int) -> int:
    return cell_load(g_tokens, p * ESZ_TOKEN + OFF_TK_INTVAL)
fn tok_ln(p: int) -> int:
    return cell_load(g_tokens, p * ESZ_TOKEN + OFF_TK_LINE)
fn tok_cl(p: int) -> int:
    return cell_load(g_tokens, p * ESZ_TOKEN + OFF_TK_COL)

fn advance_tok() -> int:
    t := cur_tok()
    if tok_k(t) != T_EOF:
        g_token_pos = t + 1
    return t

fn check(k: int) -> bool:
    if tok_k(cur_tok()) == k:
        return true
    else:
        return false

fn expect(k: int) -> int:
    t := cur_tok()
    if tok_k(t) == k:
        return advance_tok()
    return t

// Position semantics for region tails:
// - Expression position: declaration and assignment right-hand sides, return values,
//   arguments, indexes, parenthesized expressions, tuple and array elements, and
//   struct literal field values. The last item keeps its value.
// - Statement position: statements, function bodies, if/else bodies, and
//   loop/while/for bodies. A trailing bare expression is wrapped in EXPR_STMT.
//   Block-like tails (if, match, loop, while, for, unsafe) keep their value because
//   the block itself is the value.
g_want_value : int, mut

// Line boundaries after semicolons were removed:
// NEWLINE, DEDENT, and EOF end a line. DEDENT and EOF are not consumed here; the
// block production consumes them. A line also ends immediately after a DEDENT was
// consumed, because the lexer places the next line's first token after it. Without
// this rule, a declaration or expression ending in a region would be taken as
// having another token on the same line.
fn at_line_end() -> int:
    if g_token_pos > 0 && tok_k(g_token_pos - 1) == T_DEDENT:
        return 1
    k := tok_k(cur_tok())
    if k == T_NEWLINE || k == T_DEDENT || k == T_EOF:
        return 1
    return 0

fn skip_newlines():
    loop:
        if tok_k(cur_tok()) != T_NEWLINE:
            break
        advance_tok()

// Finish a statement or declaration at a line boundary. This keeps the strictness
// of the old expect(T_SEMI): two declarations on one line are rejected.
fn end_decl():
    if at_line_end() == 0:
        add_error("expected end of line, got '" + tok_lx(cur_tok()) + "'")
    skip_newlines()

// Region head: T_COLON_BLOCK (a colon at end of line), then NEWLINE, then T_INDENT.
// The lexer emits NEWLINE before INDENT/DEDENT. An inline colon (T_COLON_DECL) is
// rejected here, which also catches a parameter type annotation broken across lines.
// Returns 1 after consuming T_INDENT, so the region has items. Returns 0 for an
// empty region: the next line is not deeper, so there is no INDENT and no item.
// Empty regions are valid. They are needed for `loop:` with no body and for
// `interface Empty:` with no methods. Only the zero-item case is accepted; an
// inline colon still fails, and indentation for non-empty regions is unchanged.
fn expect_region_head() -> int:
    if tok_k(cur_tok()) == T_COLON_BLOCK:
        advance_tok()
    else:
        add_error("expected ':' to open a region, got '" + tok_lx(cur_tok()) + "'")
        return 0
    skip_newlines()
    if tok_k(cur_tok()) == T_INDENT:
        advance_tok()
        return 1
    return 0

// Close a region by consuming T_DEDENT. Any other token, including EOF, reports an
// error instead of being ignored.
fn close_region():
    if tok_k(cur_tok()) == T_DEDENT:
        advance_tok()
    else:
        add_error("expected end of region (missing DEDENT)")

// Control-flow tails in a statement-position region keep the block value. Other
// tails are wrapped in EXPR_STMT. This list is semantic, not a copy of another
// implementation's kind names:
// - while is included because this parser creates EXPR_WHILE and the checker and
//   IR generator handle it. Wrapping it in EXPR_STMT would turn the tail into unit.
// - flow is not included because flow is a declaration modifier, not an expression
//   node. parse_primary has no T_FLOW branch.
// Do not add or remove entries just to match another frontend's list.
fn is_block_like(n: int) -> int:
    if n < 0:
        return 0
    k := ast_kind(n)
    if k == EXPR_IF || k == EXPR_MATCH || k == EXPR_LOOP || k == EXPR_WHILE || k == EXPR_FOR || k == EXPR_UNSAFE:
        return 1
    return 0

// Statement nodes inside a block: let, return, break, and continue.
fn is_stmt_node(n: int) -> int:
    if n < 0:
        return 1
    k := ast_kind(n)
    if k == EXPR_LET || k == EXPR_RETURN || k == EXPR_BREAK || k == EXPR_CONTINUE:
        return 1
    return 0

// --- Type parsing ---
fn parse_type() -> int:
    t := cur_tok()
    line := tok_ln(t)
    col := tok_cl(t)
    res : ., mut = 0
    // `[T; N]` is kept as an inline capacity hint, not a type constructor. Its
    // semantic uses are product types, sequence interfaces with a length
    // constraint, and length facts in the F11 graph. See
    // See the language surface narrowing design under docs/superpowers/specs,
    // section 1.
    if tok_k(t) == T_LBRACKET:
        advance_tok()
        inner := parse_type()
        if check(T_SEMI):
            advance_tok()
            sz := advance_tok()
            advance_tok()
            res = alloc_node(EXPR_ARRAY, inner, 0, 0, tok_iv(sz), 0, 0, line, col)
        else:
            advance_tok()
            // Slice type [T]
            res = alloc_node(EXPR_ARRAY, inner, 0, 0, 0, 0, 0, line, col)
    else if tok_k(t) == T_LPAREN:
        advance_tok()
        typ := parse_type()
        advance_tok()
        res = typ
    else if tok_k(t) == T_AMPERSAND:
        advance_tok()
        is_mut : ., mut = 0
        if tok_k(cur_tok()) == T_MUT:
            is_mut = 1
            advance_tok()
        inner := parse_type()
        res = alloc_node(EXPR_REFTYPE, inner, 0, 0, is_mut, 0, 0, line, col)
    else if tok_k(t) == T_STAR:
        advance_tok()
        inner := parse_type()
        res = alloc_node(EXPR_PTRTYPE, inner, 0, 0, 0, 0, 0, line, col)
    else if tok_k(t) == T_UNIT:
        advance_tok()
        res = alloc_node(0, 0, 0, 0, 0, TY_UNIT, 0, line, col)
    else if tok_k(t) == T_NEVER:
        // `never` is a keyword, so it has its own token branch and cannot be an
        // identifier. Its type code is TY_NEVER.
        advance_tok()
        res = alloc_node(0, 0, 0, 0, 0, TY_NEVER, 0, line, col)
    else if tok_k(t) == T_DYN:
        // `dyn` is a keyword with token kind T_DYN and type code TI_DYN.
        advance_tok()
        res = alloc_node(0, 0, 0, 0, 0, TI_DYN, 0, line, col)
    else if tok_k(t) == T_IDENT || tok_k(t) == T_SELF || tok_k(t) == T_UNDERSCORE:
        lex := tok_lx(t)
        advance_tok()
        if lex == "int":
            res = alloc_node(0, 0, 0, 0, 0, TY_INT, 0, line, col)
        // dex is the exact decimal type. The old float type name was removed.
        else if lex == "dex":
            res = alloc_node(0, 0, 0, 0, 0, TY_DEX, 0, line, col)
        else if lex == "bool":
            res = alloc_node(0, 0, 0, 0, 0, TY_BOOL, 0, line, col)
        else if lex == "string":
            res = alloc_node(0, 0, 0, 0, 0, TY_STRING, 0, line, col)
        else if lex == "char":
            res = alloc_node(0, 0, 0, 0, 0, TY_CHAR, 0, line, col)
        else:
            ni := str_intern(lex)
            // Check for generic args: Box[int,...] or Box<int,...>
            close_tok : ., mut = 0
            if check(T_LBRACKET):
                close_tok = T_RBRACKET
            else if check(T_LT):
                close_tok = T_GT
            if close_tok > 0:
                advance_tok()
                first_arg := parse_type()
                arg_count : ., mut = 1
                loop:
                    if check(close_tok):
                        break
                    if !check(T_COMMA):
                        break
                    advance_tok()
                    parse_type()
                    arg_count = arg_count + 1
                advance_tok()
                res = alloc_node(EXPR_GENERIC_APPLY, ni, first_arg, arg_count, 0, 0, 0, line, col)
            else:
                res = alloc_node(EXPR_IDENT, 0, 0, 0, ni, 0, 0, line, col)
    else if tok_k(t) == T_LBRACE:
        grow_diags(g_diag_count + 1)
        cell_store(g_diags, g_diag_count * DIAG_REC_SIZE, EC_P_EXPECTED)
        cell_store_str(g_diags, g_diag_count * DIAG_REC_SIZE + 8, "expected type after '->', got '{' — missing return type?")
        cell_store(g_diags, g_diag_count * DIAG_REC_SIZE + 16, line)
        cell_store(g_diags, g_diag_count * DIAG_REC_SIZE + 24, col)
        cell_store(g_diags, g_diag_count * DIAG_REC_SIZE + 32, diag_fileid_for_line(line))
        g_diag_count = g_diag_count + 1
        res = alloc_node(0, 0, 0, 0, 0, TY_UNIT, 0, line, col)
    else:
        grow_diags(g_diag_count + 1)
        cell_store(g_diags, g_diag_count * DIAG_REC_SIZE, EC_P_EXPECTED)
        cell_store_str(g_diags, g_diag_count * DIAG_REC_SIZE + 8, "expected type after '->'")
        cell_store(g_diags, g_diag_count * DIAG_REC_SIZE + 16, line)
        cell_store(g_diags, g_diag_count * DIAG_REC_SIZE + 24, col)
        cell_store(g_diags, g_diag_count * DIAG_REC_SIZE + 32, diag_fileid_for_line(line))
        g_diag_count = g_diag_count + 1
        res = alloc_node(0, 0, 0, 0, 0, TY_UNIT, 0, line, col)
    // `T?` produces EXPR_OPTIONAL with the inner type node in slot a.
    // This shape does not depend on a registered Option name. It also represents
    // `T? = T union null` directly; an Option generic application would be an
    // opaque named atom to the type bridge. See test_optional.py.
    if check(T_QUESTION):
        advance_tok()
        res = alloc_node(EXPR_OPTIONAL, res, 0, 0, 0, 0, 0, line, col)
    return res

fn unpack_type(typ: int) -> int:
    if ast_kind(typ) == 0:
        return ast_type_val(typ)
    return 0

// --- Expression parsing ---
fn prec(k: int) -> int:
    if k == T_EQ:
        return 1
    if k == T_PLUS_EQ:
        return 1
    if k == T_MINUS_EQ:
        return 1
    if k == T_STAR_EQ:
        return 1
    if k == T_SLASH_EQ:
        return 1
    if k == T_PIPEPIPE:
        return 2
    if k == T_ANDAND:
        return 3
    if k == T_EQEQ || k == T_BANGEQ:
        return 4
    if k == T_LT || k == T_GT || k == T_LTEQ || k == T_GTEQ:
        return 5
    if k == T_PLUS || k == T_MINUS:
        return 6
    if k == T_STAR || k == T_SLASH || k == T_PERCENT:
        return 7
    return -1

fn tok2op(k: int) -> int:
    if k == T_PLUS:
        return OP_ADD
    if k == T_MINUS:
        return OP_SUB
    if k == T_STAR:
        return OP_MUL
    if k == T_SLASH:
        return OP_DIV
    if k == T_PERCENT:
        return OP_MOD
    if k == T_EQEQ:
        return OP_EQ
    if k == T_BANGEQ:
        return OP_NE
    if k == T_LT:
        return OP_LT
    if k == T_GT:
        return OP_GT
    if k == T_LTEQ:
        return OP_LE
    if k == T_GTEQ:
        return OP_GE
    if k == T_ANDAND:
        return OP_AND
    if k == T_PIPEPIPE:
        return OP_OR
    return 0

fn parse_expr() -> int:
    left := parse_binary(0)
    if check(T_DOTDOT):
        t := advance_tok()
        right := parse_expr()
        return alloc_node(EXPR_RANGE, left, right, 0, 0, 0, 0, tok_ln(t), tok_cl(t))
    return left

fn parse_binary(mp: int) -> int:
    left : ., mut = parse_unary()
    // If the left expression is a block-ending construct (IF, BLOCK, etc.),
    // don't allow binary operators to extend past it. The next operator
    // belongs to a new expression, not the current one.
    // This prevents `if ... { } *p = 99` from parsing `*` as multiplication.
    lk := ast_kind(left)
    if lk == EXPR_IF || lk == EXPR_BLOCK || lk == EXPR_LOOP || lk == EXPR_WHILE || lk == EXPR_FOR:
        return left
    loop:
        t := cur_tok()
        k := tok_k(t)
        p := prec(k)
        if p < mp:
            break
        advance_tok()
        if p == 1:
            // Assignment and compound-assignment right-hand sides are expression
            // positions. A region tail after `=` keeps its value; see g_want_value.
            g_want_value = 1
        right := parse_binary(p + 1)
        op := tok2op(k)
        // Compound assignment: +=, -=, *=, and /= become a = a op b
        if k == T_PLUS_EQ:
            left = alloc_node(EXPR_ASSIGN, left, alloc_node(EXPR_BINARY, left, right, OP_ADD, 0, 0, 0, tok_ln(t), tok_cl(t)), 0, 0, 0, 0, tok_ln(t), tok_cl(t))
        else if k == T_MINUS_EQ:
            left = alloc_node(EXPR_ASSIGN, left, alloc_node(EXPR_BINARY, left, right, OP_SUB, 0, 0, 0, tok_ln(t), tok_cl(t)), 0, 0, 0, 0, tok_ln(t), tok_cl(t))
        else if k == T_STAR_EQ:
            left = alloc_node(EXPR_ASSIGN, left, alloc_node(EXPR_BINARY, left, right, OP_MUL, 0, 0, 0, tok_ln(t), tok_cl(t)), 0, 0, 0, 0, tok_ln(t), tok_cl(t))
        else if k == T_SLASH_EQ:
            left = alloc_node(EXPR_ASSIGN, left, alloc_node(EXPR_BINARY, left, right, OP_DIV, 0, 0, 0, tok_ln(t), tok_cl(t)), 0, 0, 0, 0, tok_ln(t), tok_cl(t))
        // Convert assignment to EXPR_ASSIGN
        else if k == T_EQ:
            left = alloc_node(EXPR_ASSIGN, left, right, 0, 0, 0, 0, tok_ln(t), tok_cl(t))
        else:
            left = alloc_node(EXPR_BINARY, left, right, op, 0, 0, 0, tok_ln(t), tok_cl(t))
    return left

fn parse_unary() -> int:
    t := cur_tok()
    if tok_k(t) == T_MINUS:
        advance_tok()
        op := parse_unary()
        return alloc_node(EXPR_UNARY, op, 0, UOP_NEG, 0, 0, 0, tok_ln(t), tok_cl(t))
    if tok_k(t) == T_AMPERSAND:
        advance_tok()
        is_mut : ., mut = 0
        if tok_k(cur_tok()) == T_MUT:
            is_mut = 1
            advance_tok()
        op := parse_unary()
        return alloc_node(EXPR_UNARY, op, 0, UOP_REF, is_mut, 0, 0, tok_ln(t), tok_cl(t))
    if tok_k(t) == T_BANG:
        advance_tok()
        op := parse_unary()
        return alloc_node(EXPR_UNARY, op, 0, UOP_NOT, 0, 0, 0, tok_ln(t), tok_cl(t))
    // `move` is no longer a keyword. The lexer does not emit T_MOVE, so this parser
    // has no EXPR_MOVE branch. `move x` parses as an ordinary identifier and then
    // fails with a diagnostic.
    if tok_k(t) == T_STAR:
        advance_tok()
        op := parse_unary()
        return alloc_node(EXPR_UNARY, op, 0, UOP_DEREF, 0, 0, 0, tok_ln(t), tok_cl(t))
    node := parse_postfix()
    // Handle 'as' type cast: expr as Type
    if check(T_AS):
        advance_tok()
        typ := parse_type()
        return alloc_node(EXPR_AS, node, typ, 0, 0, 0, 0, tok_ln(t), tok_cl(t))
    return node

fn parse_postfix() -> int:
    node : ., mut = parse_primary()
    // Handle cast<T>(expr), which has the same meaning as expr as T
    if ast_kind(node) == EXPR_IDENT:
        ni := ast_int_val(node)
        if str_eq(istr_get(ni), "cast") != 0 && tok_k(cur_tok()) == T_LT:
            advance_tok()
            typ := parse_type()
            advance_tok()  // skip T_GT
            if tok_k(cur_tok()) == T_LPAREN:
                advance_tok()
                inner := parse_expr(0)
                advance_tok()  // skip T_RPAREN
                return alloc_node(EXPR_AS, inner, typ, 0, 0, 0, 0, tok_ln(node), tok_cl(node))
    loop:
        t := cur_tok()
        if tok_k(t) == T_LPAREN:
            advance_tok()
            af := -1
            ac : ., mut = 0
            if !check(T_RPAREN):
                // Wrap each argument in EXPR_ARG(a=expr, b=next_arg) linked list
                g_want_value = 1   // 实参 = 表达式位
                first_expr := parse_expr()
                af = alloc_node(EXPR_ARG, first_expr, -1, 0, 0, 0, 0, tok_ln(t), tok_cl(t))
                ac = 1
                prev_arg := af
                loop:
                    if !check(T_COMMA):
                        break
                    advance_tok()
                    g_want_value = 1
                    next_expr := parse_expr()
                    new_arg := alloc_node(EXPR_ARG, next_expr, -1, 0, 0, 0, 0, tok_ln(t), tok_cl(t))
                    ast_set_b(prev_arg, new_arg)
                    prev_arg = new_arg
                    ac = ac + 1
            advance_tok()
            // Check if this is an enum constructor
            // Cases: Some(42) or Option::Some(42)
            is_enum_con : ., mut = 0
            name_idx : ., mut = -1
            if ast_kind(node) == EXPR_IDENT:
                name_idx = ast_int_val(node)
            else if ast_kind(node) == EXPR_FIELD && ast_data(node) != 0:
                // Path access Option::Some produces EXPR_FIELD(Option, Some, data=1)
                name_idx = ast_int_val(node)
            if name_idx >= 0:
                name := istr_get(name_idx)
                c := get_char(name, 0)
                if str_cmp(c, "A") >= 0 && str_cmp(c, "Z") <= 0:
                    is_enum_con = 1
            if is_enum_con == 1:
                node = alloc_node(EXPR_ENUM_CONSTRUCTOR, name_idx, af, ac, 0, 0, 0, tok_ln(t), tok_cl(t))
            else:
                call_func := node
                call_flags : ., mut = 0
                // @inline(fn)(args) is a hinted call, not a call through the
                // value returned by @inline(fn).
                if ast_kind(node) == EXPR_CALL && ast_c(node) == 1:
                    wrapper := ast_a(node)
                    wrapper_arg := ast_b(node)
                    if ast_kind(wrapper) == EXPR_AT && wrapper_arg >= 0:
                        wrapper_name := istr_get(ast_a(wrapper))
                        if str_eq(wrapper_name, "inline") != 0:
                            call_func = ast_a(wrapper_arg)
                            call_flags = CALL_FLAG_INLINE
                node = alloc_node(EXPR_CALL, call_func, af, ac, 0, call_flags, 0, tok_ln(t), tok_cl(t))
            continue
        if tok_k(t) == T_DOT:
            advance_tok()
            f := advance_tok()
            ni := str_intern(tok_lx(f))
            // type_val: for numeric field names, stores index+1 (0 means struct field)
            tv : ., mut = 0
            if tok_k(f) == T_INT:
                tv = tok_iv(f) + 1  // +1 so default 0 means struct field
            node = alloc_node(EXPR_FIELD, node, 0, 0, ni, tv, 0, tok_ln(t), tok_cl(t))
            continue
        if tok_k(t) == T_PATHSEP:
            advance_tok()
            f := advance_tok()
            ni := str_intern(tok_lx(f))
            node = alloc_node(EXPR_FIELD, node, 0, 0, ni, 0, 1, tok_ln(t), tok_cl(t))
            continue
        if tok_k(t) == T_LBRACKET:
            advance_tok()
            g_want_value = 1   // 下标 = 表达式位
            idx := parse_expr()
            advance_tok()
            node = alloc_node(EXPR_INDEX, node, idx, 0, 0, 0, 0, tok_ln(t), tok_cl(t))
            continue
        if tok_k(t) == T_QUESTION:
            advance_tok()
            node = alloc_node(EXPR_TRY, node, 0, 0, 0, 0, 0, tok_ln(t), tok_cl(t))
            continue
        break
    return node

fn is_upper_first(s: string) -> bool:
    c := get_char(s, 0)
    if str_cmp(c, "A") >= 0 && str_cmp(c, "Z") <= 0:
        return true
    return false

// String interpolation expansion. The lexer splits a literal containing `${...}`
// into parts. A part is T_STRING (literal text) or T_INTERP (hole; the lexeme is the
// hole text). The iv field is filled by the lexer:
//   +1: the part belongs to an interpolated literal
//   +2: another part follows
//   4: the hole is closed (T_INTERP only)
// Addition is used instead of bit operations because the bootstrap backend does not
// support `|` or `&`. parser joins parts of the same literal only; adjacent bare
// strings still fail. A literal without holes has iv=0, one part, and the same node
// shape as before. Hole expressions are parsed at the end of parse_all, after the
// token stream is no longer needed.
fn parse_interp_run() -> int:
    t := cur_tok()
    left : ., mut = -1
    loop:
        k := tok_k(t)
        if k != T_STRING && k != T_INTERP:
            break
        iv := tok_iv(t)
        part : ., mut = -1
        if k == T_INTERP:
            txt := tok_lx(t)
            if iv < 4:
                check_error(EC_P_INTERP_UNCLOSED, "unclosed string interpolation: '\${' has no matching '}'", tok_ln(t), tok_cl(t))
            else if str_len(txt) == 0:
                check_error(EC_P_INTERP_UNCLOSED, "empty string interpolation: '\${}'", tok_ln(t), tok_cl(t))
            part = alloc_node(EXPR_INTERP_HOLE, 0, 0, 0, 0, 0, str_intern(txt), tok_ln(t), tok_cl(t))
        else:
            part = alloc_node(EXPR_STRING, 0, 0, 0, str_intern(tok_lx(t)), TY_STRING, 0, tok_ln(t), tok_cl(t))
        if left < 0:
            left = part
        else:
            left = alloc_node(EXPR_BINARY, left, part, OP_ADD, 0, 0, 0, tok_ln(t), tok_cl(t))
        advance_tok()
        if (iv % 4) < 2:
            break
        t = cur_tok()
    return left

// 洞表达式统一解析（parse_all 末尾调用）：线性扫本文件新建 AST，遇 EXPR_INTERP_HOLE 即把
// Re-tokenize the hole text in the data slot, parse it as an expression, and write
// the result to slot a. This must run after the token stream is no longer needed,
// because it overwrites g_tokens.
// 洞内嵌套插值产生的新 HOLE 节点由本循环自然覆盖（上界 g_ast_count 随扫描增长）。
fn interp_parse_holes():
    i : ., mut = 0
    loop:
        if i >= g_ast_count:
            break
        if ast_kind(i) == EXPR_INTERP_HOLE:
            txt := istr_get(ast_data(i))
            if str_len(txt) > 0:
                // This is the only reentry point in the parser. A hole is a small
                // expression cut from the source and has no layout context, so
                // layout emission is bypassed explicitly. Otherwise the hole
                // would invent indentation state and overwrite the outer stack.
                // Nested interpolation reenters recursively. The bypass is an
                // explicit argument so the call site shows the rule.
                g_layout_bypass = 1
                tokenize(txt, g_layout_bypass)
                g_layout_bypass = 0
                g_token_pos = 0
                ast_set_a(i, parse_expr())
                tk2 := cur_tok()                     // Do not write `if tok_k(cur_tok()) != T_EOF {` here. That shape would
                // collide with the top-level fallback
                if tok_k(tk2) != T_EOF:
                    //   突变锚点（tests/harness/test_criteria_mutations.py M9）撞形
                    check_error(EC_P_INTERP_UNCLOSED, "trailing tokens in string interpolation hole", ast_line(i), ast_col(i))
        i = i + 1

fn parse_primary() -> int:
    t := cur_tok()
    if tok_k(t) == T_INT:
        advance_tok()
        return alloc_node(EXPR_INT, 0, 0, 0, tok_iv(t), TY_INT, 0, tok_ln(t), tok_cl(t))
    if tok_k(t) == T_BIGINT:
        advance_tok()
        tl := cell_load(g_tokens, t * ESZ_TOKEN + OFF_TK_LEXEME)
        return alloc_node(EXPR_BIGINT, tl, 0, 0, 0, TY_INT, 0, tok_ln(t), tok_cl(t))
    if tok_k(t) == T_DEX:
        advance_tok()
        // Node fields: a = binary64 bit pattern, restored from the numeric text in
        // the token lexeme; int_val = fixed-point scaled integer (the exact default
        // path). Width suffixes were removed, so the data slot is always 0.
        bits : int = 0
        tl := cell_load(g_tokens, t * ESZ_TOKEN + OFF_TK_LEXEME)   // 词素串下标（-1 = 无）
        if tl >= 0:
            bits = str_to_f64_bits(istr_get(tl))
        return alloc_node(EXPR_DEX, bits, 0, 0, tok_iv(t), TY_DEX, 0, tok_ln(t), tok_cl(t))
    if tok_k(t) == T_STRING || tok_k(t) == T_INTERP:
        return parse_interp_run()
    if tok_k(t) == T_TRUE:
        advance_tok()
        return alloc_node(EXPR_BOOL, 0, 0, 0, 1, TY_BOOL, 0, tok_ln(t), tok_cl(t))
    if tok_k(t) == T_FALSE:
        advance_tok()
        return alloc_node(EXPR_BOOL, 0, 0, 0, 0, TY_BOOL, 0, tok_ln(t), tok_cl(t))
    if tok_k(t) == T_NONE:
        // `none` is a keyword for the empty optional value. The canonical variant
        // name is still `None`, because desugar, checker, and ty_shadow compare the
        // label `None`, so this maps to that name. `None` with a capital N is an
        // ordinary identifier now; using it as a value reports an undefined name.
        advance_tok()
        return alloc_node(EXPR_ENUM_CONSTRUCTOR, str_intern("None"), -1, 0, 0, 0, 0, tok_ln(t), tok_cl(t))
    // `Some` is no longer a keyword. `Some(x)` reaches the parse_postfix rule:
    // identifier + `(` + uppercase first letter -> EXPR_ENUM_CONSTRUCTOR, with
    // arguments in an EXPR_ARG list. A bare `Some` is an EXPR_IDENT.
    if tok_k(t) == T_AT:
        advance_tok()
        if tok_k(cur_tok()) == T_IDENT:
            name_ni := str_intern(tok_lx(cur_tok()))
            advance_tok()
            // args_node = -1 means no args; parse_postfix will handle (args) as EXPR_CALL
            return alloc_node(EXPR_AT, name_ni, -1, 0, 0, 0, 0, tok_ln(t), tok_cl(t))
        add_error("expected identifier after @")
        return alloc_node(0, 0, 0, 0, 0, TY_UNIT, 0, tok_ln(t), tok_cl(t))
    if tok_k(t) == T_IDENT || tok_k(t) == T_SELF || tok_k(t) == T_UNDERSCORE:
        advance_tok()
        name := tok_lx(t)
        ni := str_intern(name)
        // Braces are not block delimiters, so `Name {` always starts a struct
        // literal. No lookahead resolver or ambiguity flag is needed.
        if check(T_LBRACE):
            advance_tok()
            // EXPR_STRUCT layout: a = type name index, b = first wrapper, c = field
            // count. Wrappers are contiguous in g_ast: kind EXPR_NONE and wrapper.a
            // is the field value node. A field value subtree is not contiguous, so
            // parse in two passes: parse all values, then build the wrappers.
            // wrapper.b stores the field name index, or -1 when absent. Without it,
            // fields would bind by declaration order and a reordered literal would
            // read the wrong value.
            cap : ., mut = 8
            vals : string, mut = alloc(cap * 8)
            names : string, mut = alloc(cap * 8)
            fc : ., mut = 0
            loop:
                // EOF guard: this loop otherwise stops only at '}', and advance_tok
                // does nothing at EOF. After the parser loses sync, the loop would
                // allocate nodes until memory is exhausted. All six loops in this
                // family exit on EOF.
                if check(T_RBRACE) || check(T_EOF):
                    break
                ft := advance_tok()
                fni := str_intern(tok_lx(ft))
                // Struct literal fields use '=' only. A ':' separator reports P030.
                // Accepting both forms would hide the difference between a field and
                // a type annotation.
                if check(T_EQ):
                    advance_tok()
                else:
                    check_error(EC_P_STRUCT_LIT_SEP,
                        "struct literal field separator must be '=' (':' is not valid in v4)",
                        tok_ln(cur_tok()), tok_cl(cur_tok()))
                if fc >= cap:
                    ncap := cap * 2
                    nv := alloc(ncap * 8)
                    cell_copy(vals, cap * 8, nv)
                    vals = nv
                    nn := alloc(ncap * 8)
                    cell_copy(names, cap * 8, nn)
                    names = nn
                    cap = ncap
                g_want_value = 1                 // 字段值 = 表达式位
                cell_store(vals, fc * 8, parse_expr())  // 字段值（子树自占若干槽）
                cell_store(names, fc * 8, fni)          // field name index (name binding)
                fc = fc + 1
                if check(T_COMMA):
                    advance_tok()
            advance_tok()
            ff : ., mut = -1
            fi2 : ., mut = 0
            loop:
                if fi2 >= fc:
                    break
                vn := cell_load(vals, fi2 * 8)
                ln : ., mut = tok_ln(t)
                cl : ., mut = tok_cl(t)
                if vn >= 0:
                    ln = ast_line(vn)
                    cl = ast_col(vn)
                wl := ast_alloc(EXPR_NONE, vn, cell_load(names, fi2 * 8), 0, 0, 0, 0, ln, cl)
                if fi2 == 0:
                    ff = wl
                fi2 = fi2 + 1
            return alloc_node(EXPR_STRUCT, ni, ff, fc, 0, 0, 0, tok_ln(t), tok_cl(t))
        return alloc_node(EXPR_IDENT, 0, 0, 0, ni, 0, 0, tok_ln(t), tok_cl(t))
    if tok_k(t) == T_LPAREN:
        advance_tok()
        g_want_value = 1   // 括号内 = 表达式位
        e := parse_expr()
        if check(T_COMMA):
            // Tuple: (e1, e2, ...)
            // EXPR_TUPLE layout: a = first wrapper, b = element count. Wrappers are
            // contiguous; each wrapper is kind EXPR_NONE with wrapper.a pointing to
            // the element value. Composite values occupy several nodes, so parse all
            // values first, then build the contiguous wrappers.
            cap : ., mut = 8
            vals : string, mut = alloc(cap * 8)
            cell_store(vals, 0, e)
            ec : ., mut = 1
            loop:
                advance_tok()  // consume comma
                if ec >= cap:
                    ncap := cap * 2
                    nv := alloc(ncap * 8)
                    cell_copy(vals, cap * 8, nv)
                    vals = nv
                    cap = ncap
                g_want_value = 1                 // 元组元素 = 表达式位
                cell_store(vals, ec * 8, parse_expr())  // 元素值（子树自占若干槽）
                ec = ec + 1
                if !check(T_COMMA):
                    break
            advance_tok()  // consume )
            ef : ., mut = -1
            ei : ., mut = 0
            loop:
                if ei >= ec:
                    break
                vn := cell_load(vals, ei * 8)
                ln : ., mut = tok_ln(t)
                cl : ., mut = tok_cl(t)
                if vn >= 0:
                    ln = ast_line(vn)
                    cl = ast_col(vn)
                wl := ast_alloc(EXPR_NONE, vn, 0, 0, 0, 0, 0, ln, cl)
                if ei == 0:
                    ef = wl
                ei = ei + 1
            return alloc_node(EXPR_TUPLE, ef, ec, 0, 0, 0, 0, tok_ln(t), tok_cl(t))
        advance_tok()
        return e
    if tok_k(t) == T_CHAR:
        advance_tok()
        return alloc_node(EXPR_CHAR, 0, 0, 0, str_intern(tok_lx(t)), TY_CHAR, 0, tok_ln(t), tok_cl(t))
    if tok_k(t) == T_LBRACE:
        // Braces are only struct literal delimiters. Blocks use ':' plus
        // indentation, so a bare '{' in expression position reports an error rather
        // than being parsed as a block.
        check_error(EC_P_EXPR,
            "'{' is only valid as a struct literal delimiter in v4 (blocks use ':' + indent)",
            tok_ln(t), tok_cl(t))
        advance_tok()
        return alloc_node(0, 0, 0, 0, 0, TY_UNIT, 0, tok_ln(t), tok_cl(t))
    if tok_k(t) == T_IF:
        return parse_if_expr()
    if tok_k(t) == T_WHILE:
        return parse_while_expr()
    if tok_k(t) == T_LOOP:
        return parse_loop_expr()
    if tok_k(t) == T_FOR:
        return parse_for_expr()
    if tok_k(t) == T_GO:
        t2 := advance_tok()
            // A line boundary replaces the old semicolon check. If no token follows
        // `go` on the same logical line, report an error.
        if at_line_end() != 0:
            add_error("Expected expression after `go`")
            return 0
        // go [N] expr, or go var start..end expr, which desugars to a loop
        count : ., mut = -1
        iter_var_ni : ., mut = -1
        range_start : ., mut = -1
        range_end : ., mut = -1
        // Check for range syntax: go var start..end expr
        saved_pos : ., mut = g_token_pos
        if tok_k(cur_tok()) == T_IDENT:
            vn := str_intern(tok_lx(cur_tok()))
            advance_tok()
            if tok_k(cur_tok()) == T_INT:
                iter_var_ni = vn
                range_start = tok_iv(cur_tok())
                advance_tok()
                if tok_k(cur_tok()) == T_DOTDOT:
                    advance_tok()
                    if tok_k(cur_tok()) == T_INT:
                        range_end = tok_iv(cur_tok())
                        advance_tok()
                    body := parse_expr()
                    // Range go: keep range info in EXPR_GO for IR gen result collection
                    range_node := alloc_node(EXPR_RANGE, range_start, range_end, 0, 0, 0, 0, tok_ln(t2), tok_cl(t2))
                    return alloc_node(EXPR_GO, -1, body, iter_var_ni, 0, 0, range_node, tok_ln(t2), tok_cl(t2))
            // Not range mode. Backtrack to a regular go expression.
            g_token_pos = saved_pos
        // Single: go expr  (no count-based batch)
        body := parse_expr()
        return alloc_node(EXPR_GO, count, body, 0, 0, 0, 0, tok_ln(t2), tok_cl(t2))
    if tok_k(t) == T_AWAIT:
        t2 := advance_tok()
        val := parse_expr()
        return alloc_node(EXPR_AWAIT, val, 0, 0, 0, 0, 0, tok_ln(t2), tok_cl(t2))
    if tok_k(t) == T_MATCH:
        return parse_match_expr()
    if tok_k(t) == T_UNSAFE:
        t2 := advance_tok()
        body := parse_block()
        return alloc_node(EXPR_UNSAFE, body, 0, 0, 0, 0, 0, tok_ln(t2), tok_cl(t2))
    if tok_k(t) == T_LBRACKET:
        advance_tok()
        // Literal EXPR_ARRAY layout: a = first wrapper, b = element count. Wrappers
        // are contiguous; each is kind EXPR_NONE with wrapper.a pointing to the
        // element value. Composite elements occupy several nodes, so parse all
        // values first, then build the wrappers. The type form [T; N] or [T] is
        // produced by parse_type with a different layout and does not use this path.
        cap : ., mut = 8
        vals : string, mut = alloc(cap * 8)
        ec : ., mut = 0
        if !check(T_RBRACKET):
            g_want_value = 1            // 数组元素 = 表达式位
            cell_store(vals, 0, parse_expr())  // 元素值（子树自占若干槽）
            ec = 1
            if check(T_SEMI):
                // Repeat array [value; count]: parse the value once, then append
                // wrappers that share the same value node.
                advance_tok()
                ct := advance_tok()
                cnt : ., mut = tok_iv(ct)
                if cnt > cap:
                    nv := alloc(cnt * 8)
                    cell_copy(vals, cap * 8, nv)
                    vals = nv
                    cap = cnt
                ri : ., mut = 1
                loop:
                    if ri >= cnt:
                        break
                    cell_store(vals, ri * 8, cell_load(vals, 0))
                    ri = ri + 1
                ec = cnt
            else:
                loop:
                    if !check(T_COMMA):
                        break
                    advance_tok()
                    if ec >= cap:
                        ncap := cap * 2
                        nv := alloc(ncap * 8)
                        cell_copy(vals, cap * 8, nv)
                        vals = nv
                        cap = ncap
                    g_want_value = 1                 // 数组元素 = 表达式位
                    cell_store(vals, ec * 8, parse_expr())  // 元素值（子树自占若干槽）
                    ec = ec + 1
        advance_tok()
        ef : ., mut = -1
        ei2 : ., mut = 0
        loop:
            if ei2 >= ec:
                break
            vn := cell_load(vals, ei2 * 8)
            ln : ., mut = tok_ln(t)
            cl : ., mut = tok_cl(t)
            if vn >= 0:
                ln = ast_line(vn)
                cl = ast_col(vn)
            wl := ast_alloc(EXPR_NONE, vn, 0, 0, 0, 0, 0, ln, cl)
            if ei2 == 0:
                ef = wl
            ei2 = ei2 + 1
        return alloc_node(EXPR_ARRAY, ef, ec, 0, 0, 0, 0, tok_ln(t), tok_cl(t))
    add_error("Unexpected token in expression")
    advance_tok()  // consume the unexpected token to avoid infinite loop
    return 0

// Block statement buffer. Each region collects its own segment and appends it to
// g_block_stmts when the region closes.
g_pb_stmts : string, mut
g_pb_cap : int, mut
g_pb_count : int, mut

fn block_push(n: int):
    if g_pb_count >= g_pb_cap:
        ncap : ., mut = g_pb_cap * 2
        if ncap < 16:
            ncap = 16
        nv := alloc(ncap * 8)
        if g_pb_cap > 0:
            cell_copy(g_pb_stmts, g_pb_cap * 8, nv)
        g_pb_stmts = nv
        g_pb_cap = ncap
    cell_store(g_pb_stmts, g_pb_count * 8, n)
    g_pb_count = g_pb_count + 1

// Common entry for all regions: head and body.
fn parse_block() -> int:
    head := cur_tok()
    if expect_region_head() == 0:
        // Empty region: no items and no DEDENT. Do not call parse_block_items,
        // because its close_region requires a DEDENT.
        return alloc_node(EXPR_BLOCK, g_block_stmt_count, 0, 0, 0, 0, 0, tok_ln(head), tok_cl(head))
    return parse_block_items(head)

// Region body. The head has already been consumed. This is a separate function
// because a function body may start with spec annotations (#check / #ensure) before
// its statements; parse_body consumes those first.
// A region is T_COLON_BLOCK, NEWLINE, T_INDENT ... T_DEDENT. The last item is the
// region value; earlier items are statements. g_want_value decides whether the tail
// keeps its value. Nested regions reset to statement position and restore the
// caller's value on exit.
fn parse_block_items(head: int) -> int:
    t := head
    want := g_want_value
    g_want_value = 0
    g_pb_stmts = alloc(256 * 8)
    g_pb_cap = 256
    g_pb_count = 0
    have_expr : ., mut = -1
    loop:
        skip_newlines()
        if tok_k(cur_tok()) == T_DEDENT || tok_k(cur_tok()) == T_EOF:
            break
        // Save and restore the collection buffer around parse_stmt, which can enter a
        // nested region and reset these globals. Without restoring this layer's
        // buffer, the inner region overwrites collected statements. Save this
        // layer's state, not the outer layer's.
        my_stmts := g_pb_stmts
        my_cap := g_pb_cap
        my_count := g_pb_count
        st := parse_stmt()
        g_pb_stmts = my_stmts
        g_pb_cap = my_cap
        g_pb_count = my_count
        if is_stmt_node(st) != 0:
                // Statement item: a preceding bare expression is not the tail, so wrap it
            // in EXPR_STMT.
            if have_expr >= 0:
                block_push(alloc_node(EXPR_STMT, have_expr, 0, 0, 0, 0, 0, tok_ln(t), tok_cl(t)))
                have_expr = -1
            block_push(st)
        else:
            // Bare expression: tentatively the region tail. If another item follows,
            // it is wrapped in EXPR_STMT later.
            if have_expr >= 0:
                block_push(alloc_node(EXPR_STMT, have_expr, 0, 0, 0, 0, 0, tok_ln(t), tok_cl(t)))
            have_expr = st
    close_region()
    g_want_value = want
    if want == 0 && have_expr >= 0 && is_block_like(have_expr) == 0:
        // Statement-position region whose tail is an ordinary bare expression:
        // wrap it in EXPR_STMT and treat the region as having no value.
        block_push(alloc_node(EXPR_STMT, have_expr, 0, 0, 0, 0, 0, tok_ln(t), tok_cl(t)))
        have_expr = -1
    if have_expr >= 0:
        block_push(have_expr)
    // Flush to global block_stmts array (isolated from nested blocks)
    si := g_block_stmt_count
    i : ., mut = 0
    loop:
        if i >= g_pb_count:
            break
        grow_block_stmts(g_block_stmt_count + 1)
        cell_store(g_block_stmts, g_block_stmt_count * 8, cell_load(g_pb_stmts, i * 8))
        g_block_stmt_count = g_block_stmt_count + 1
        i = i + 1
    return alloc_node(EXPR_BLOCK, si, g_pb_count, 0, 0, 0, 0, tok_ln(t), tok_cl(t))

fn is_new_var_decl() -> bool:
    p := cur_tok()
    if tok_k(p) != T_IDENT:
        return false
    // x := expr
    if tok_k(p + 1) == T_COLON_EQ:
        return true
    // x : type ... uses T_COLON_DECL. The two colon kinds are disjoint, so a
    // T_COLON_BLOCK cannot enter the declaration branch; at statement position it
    // is handled by expect_region_head and reported. `:=` uses T_COLON_EQ and batch
    // declarations use T_COMMA. This resolver needs no lookahead.
    if tok_k(p + 1) == T_COLON_DECL:
        return true
    // a, b, ... : type ... or a, b, ... := ... (batch, any count)
    if tok_k(p + 1) == T_COMMA:
        i : ., mut = 2
        loop:
            if tok_k(p + i) == T_IDENT && tok_k(p + i + 1) == T_COMMA:
                i = i + 2
                continue
            if tok_k(p + i) == T_IDENT && (tok_k(p + i + 1) == T_COLON_DECL || tok_k(p + i + 1) == T_COLON_EQ):
                return true
            break
    return false

fn parse_new_var_decl() -> int:
    t := cur_tok()
    names : string, mut
    names_cap : int, mut
    names = alloc(64 * 8)
    names_cap = 64
    nc : ., mut = 0

    // Parse name list
    nt := advance_tok()
    unsafe:
        cell_store(names, nc * 8, @ptr_of(tok_lx(nt)))
    // 2(a)：串字入裸字表
    nc = nc + 1
    // Batch: a, b : type = ...
    if check(T_COMMA):
        loop:
            if !check(T_COMMA):
                break
            advance_tok() // ,
            nt2 := advance_tok()
            unsafe:
                cell_store(names, nc * 8, @ptr_of(tok_lx(nt2)))
            nc = nc + 1

    typ : ., mut = -1
    is_mut : ., mut = 0
    is_pub : ., mut = 0
    is_apx : ., mut = 0

    values : string, mut
    values_cap : int, mut
    values = alloc(64 * 8)
    values_cap = 64
    vc : ., mut = 0

    if check(T_COLON_EQ):
        advance_tok()
        g_want_value = 1   // 声明右值 = 表达式位
        cell_store(values, vc * 8, parse_expr())
        vc = vc + 1
        loop:
            if !check(T_COMMA):
                break
            advance_tok()
            g_want_value = 1
            cell_store(values, vc * 8, parse_expr())
            vc = vc + 1
    else:
        // consume ':'
        advance_tok()

        if tok_k(cur_tok()) == T_AUTO || tok_k(cur_tok()) == T_DOT:
            typ = -1
            advance_tok()
        else:
            typ = parse_type()

        // Optional tags (built-in + plugin-extensible)
        if check(T_COMMA):
            advance_tok()
            loop:
                // A tag list ends at a line boundary or at '='. The '=' form
                // `x : int, mut, pub = e` is still accepted.
                if check(T_EQ) || at_line_end() != 0:
                    break
                tag_t := advance_tok()
                tag := tok_lx(tag_t)
                if tag == "mut":
                    is_mut = 1
                else if tag == "pub":
                    is_pub = 1
                else if tag == "apx":
                    is_apx = 1
                else:
                    tni := str_intern(tag)
                    ei := find_plugin_entry(g_plugin_tags, g_plugin_tag_count, tni, -1)
                    if ei >= 0:
                        pd := cell_load(g_plugin_tags, ei*24+16)
                        if pd != 0:
                            is_mut = 1
                    else:
                        // 未知标签：TA08（已知标签 = mut/pub/apx + 插件注册标签）
                        grow_diags(g_diag_count + 1)
                        cell_store(g_diags, g_diag_count * DIAG_REC_SIZE, EC_TA_UNKNOWN_TAG)
                        cell_store_str(g_diags, g_diag_count * DIAG_REC_SIZE + 8, "unknown declaration tag '" + tag + "'")
                        cell_store(g_diags, g_diag_count * DIAG_REC_SIZE + 16, tok_ln(tag_t))
                        cell_store(g_diags, g_diag_count * DIAG_REC_SIZE + 24, tok_cl(tag_t))
                        cell_store(g_diags, g_diag_count * DIAG_REC_SIZE + 32, diag_fileid_for_line(tok_ln(tag_t)))
                        g_diag_count = g_diag_count + 1
                if !check(T_COMMA):
                    break
                advance_tok()

        // Parse values
        cell_store(values, 0 * 8, -1)
        if check(T_EQ):
            advance_tok()
            g_want_value = 1   // 声明右值 = 表达式位
            cell_store(values, vc * 8, parse_expr())
            vc = vc + 1
            loop:
                if !check(T_COMMA):
                    break
                advance_tok()
                g_want_value = 1
                cell_store(values, vc * 8, parse_expr())
                vc = vc + 1

    // A trailing semicolon is optional; end_decl finishes the statement at a line
    // boundary.

    // Emit LET nodes. First returned directly, extras go to g_extra_lets (dynamic grow).
    first_node : ., mut = -1
    i : ., mut = 0
    loop:
        if i >= nc:
            break
        name_str := unsafe:
            @str_of(cell_load(names, i * 8))
        ni := str_intern(name_str)   // 2(a)：裸字读出按串用
        nv := cell_load(values, i * 8)
        // `apx` is valid only on an explicit `dex` or `int` declaration. Other
        // forms have no representation path and would carry the tag without the
        // approximation semantics. Reject them with P26 and produce no output.
        // The bootstrap parser still validates only the tag name, not its
        // applicability, so the two frontends currently differ here. Convergence
        // requires the same check in the bootstrap parser.
        if is_apx != 0:
            apx_ok : ., mut = 0
            if typ >= 0 && ast_kind(typ) == 0:
                tv := ast_type_val(typ)
                if tv == TY_DEX || tv == TY_INT:
                    apx_ok = 1
            if apx_ok == 0:
                check_error(EC_P_APX_TAG,
                    "'apx' tag is only allowed on an explicit 'dex' or 'int' declaration",
                    tok_ln(t), tok_cl(t))
        node := alloc_node(EXPR_LET, ni, typ, nv, is_apx, 0, is_mut, tok_ln(t), tok_cl(t))
        if i == 0:
            first_node = node
        else:
            if g_extra_lets_cap == 0:
                g_extra_lets = alloc(128)
                g_extra_lets_cap = 16
            if g_extra_let_count < g_extra_lets_cap:
                cell_store(g_extra_lets, g_extra_let_count * 8, node)
                g_extra_let_count = g_extra_let_count + 1
        i = i + 1

    return first_node

// Skip a nested function declaration after P021 is reported. This is error
// recovery only. The skipped form starts with fn (or pub fn) and ends at a line
// boundary, or after `= expr`. Indentation depth tracks the nested region.
fn skip_nested_fn():
    // Both body forms end at a line boundary: a `:` region with INDENT/DEDENT, or
    // an inline `= expr` body. Indentation depth replaces brace matching.
    depth : ., mut = 0
    loop:
        k := tok_k(cur_tok())
        if k == T_EOF:
            return
        if depth == 0:
            if k == T_NEWLINE:
                advance_tok()
                return
            if k == T_COLON_BLOCK:
                advance_tok()
                skip_newlines()
                if tok_k(cur_tok()) == T_INDENT:
                    depth = 1
                    advance_tok()
                else:
                    return
                continue
            advance_tok()
            continue
        if k == T_INDENT:
            depth = depth + 1
        else if k == T_DEDENT:
            depth = depth - 1
        advance_tok()
        if depth == 0:
            return

// Whitelist for `@` annotations in statement position. These names are used before
// a statement or region in the documentation or corpus:
//   @preferredDomain(gpu), @executionDomain(name)
//   @NoBoundsCheck
//   @fast, @unroll(4), @section("text.hot")
// Query annotations, @addr, and @inline are not included because they appear in
// expression position. Unknown names are not consumed here; they stay expressions
// and the checker rejects them.
// The list is based on documented and tested usage, not chapter numbers. Do not
// narrow it by chapter number; that would reject names with real uses.
fn is_stmt_at_annotation(name: string) -> int:
    if str_eq(name, "preferredDomain") != 0:
        return 1
    if str_eq(name, "executionDomain") != 0:
        return 1
    if str_eq(name, "NoBoundsCheck") != 0:
        return 1
    if str_eq(name, "fast") != 0:
        return 1
    if str_eq(name, "unroll") != 0:
        return 1
    if str_eq(name, "section") != 0:
        return 1
    return 0

// Consume one or more statement-leading @ annotations, one per line. Returns the count.
fn skip_stmt_at_annotations() -> int:
    cnt : ., mut = 0
    loop:
        if tok_k(cur_tok()) != T_AT:
            break
        nxt := cur_tok() + 1
        if tok_k(nxt) != T_IDENT:
            break
        an := tok_lx(nxt)
        if is_stmt_at_annotation(an) == 0:
            break
        at_line := tok_ln(cur_tok())
        at_col := tok_cl(cur_tok())
        advance_tok()   // '@'
        advance_tok()   // 名字
        if check(T_LPAREN):
            depth : ., mut = 1
            advance_tok()
            loop:
                if depth <= 0:
                    break
                k := tok_k(cur_tok())
                if k == T_EOF:
                    break
                if k == T_LPAREN:
                    depth = depth + 1
                else if k == T_RPAREN:
                    depth = depth - 1
                advance_tok()
        // An annotation must be alone on its line. Report a coded V03 diagnostic;
        // an uncoded message would be hidden
        // `run_frontend` 的 `g_diag_count > 0` 早退挡在 `print_parse_errors()` 之前（报不出来）。
        if at_line_end() == 0:
            check_error(EC_V_ANN_SYNTAX,
                "Expected end of line after '@" + an + "' annotation", at_line, at_col)
            return cnt
        skip_newlines()
        cnt = cnt + 1
    return cnt

fn parse_stmt() -> int:
    // Statement entry. Reset to statement position first. Expression positions inside
    // the statement set g_want_value back to 1.
    g_want_value = 0
    // Consume statement-leading @ annotations here. Otherwise @ falls into the
    // expression path and the checker reports it as an unknown builtin (N01).
    skip_stmt_at_annotations()
    // Drain batch extras from previous call
    if g_extra_let_count > 0:
        g_extra_let_count = g_extra_let_count - 1
        return cell_load(g_extra_lets, g_extra_let_count * 8)

    t := cur_tok()
    // Nested fn and flow declarations are not statements. Function declarations are
    // top-level only. Report P021 at the declaration and skip the whole declaration,
    // so the following statements parse normally. The old fallback consumed one
    // token, lost sync, and could spin in the struct literal loop until OOM.
    if tok_k(t) == T_FN || tok_k(t) == T_FLOW || (tok_k(t) == T_PUB && (tok_k(t + 1) == T_FN || tok_k(t + 1) == T_FLOW)):
        fnt : ., mut = t
        if tok_k(fnt) == T_PUB:
            fnt = fnt + 1
        msg : ., mut = "Nested function declaration is not supported; declare it at top level"
        if tok_k(fnt + 1) == T_IDENT:
            msg = "Nested function declaration '" + tok_lx(fnt + 1) + "' is not supported; declare it at top level"
        check_error(EC_P_NESTED_FN, msg, tok_ln(fnt), tok_cl(fnt))
        skip_nested_fn()
        return 0
    // New variable declaration syntax
    if tok_k(t) == T_IDENT && is_new_var_decl():
        return parse_new_var_decl()
    if tok_k(t) == T_RETURN:
        advance_tok()
        val : ., mut = -1
        // If no token follows the keyword on the same logical line, the value is
        // absent. A line boundary replaces the old semicolon check.
        if at_line_end() == 0:
            g_want_value = 1   // return 的值 = 表达式位
            val = parse_expr()
        skip_newlines()
        return alloc_node(EXPR_RETURN, val, 0, 0, 0, 0, 0, tok_ln(t), tok_cl(t))
    if tok_k(t) == T_YIELD:
        advance_tok()
        val : ., mut = -1
        if at_line_end() == 0:
            g_want_value = 1
            val = parse_expr()
        skip_newlines()
        return alloc_node(EXPR_YIELD, val, 0, 0, 0, 0, 0, tok_ln(t), tok_cl(t))
    if tok_k(t) == T_BREAK:
        advance_tok()
        skip_newlines()   // B5：语句末可选 `;` 退场
        return alloc_node(EXPR_BREAK, 0, 0, 0, 0, 0, 0, tok_ln(t), tok_cl(t))
    if tok_k(t) == T_CONTINUE:
        advance_tok()
        skip_newlines()
        return alloc_node(EXPR_CONTINUE, 0, 0, 0, 0, 0, 0, tok_ln(t), tok_cl(t))
    // A bare expression is tentatively the region tail. The block loop wraps it in
    // EXPR_STMT if another item follows.
    return parse_expr()

fn parse_if_expr() -> int:
    t := advance_tok()
    want := g_want_value
    g_want_value = 1   // 条件恒为表达式位
    cond := parse_expr()
    g_want_value = want
    tb := parse_block()   // 两臂 region 的位置 = 本 if 表达式自身的位置
    eb : ., mut = -1
    if check(T_ELSE):
        advance_tok()
        g_want_value = want
        if check(T_IF):
            eb = parse_if_expr()
        else:
            eb = parse_block()
    g_want_value = want
    return alloc_node(EXPR_IF, cond, tb, eb, 0, 0, 0, tok_ln(t), tok_cl(t))

fn parse_loop_expr() -> int:
    // A loop body is always a statement-position region, so its type is unit.
    t := advance_tok()
    want := g_want_value
    g_want_value = 0
    body := parse_block()
    g_want_value = want
    return alloc_node(EXPR_LOOP, body, 0, 0, 0, 0, 0, tok_ln(t), tok_cl(t))

fn parse_while_expr() -> int:
    // 条件恒为表达式位；体恒为语句位 region。
    t := advance_tok()
    want := g_want_value
    g_want_value = 1
    cond := parse_expr()
    g_want_value = 0
    body := parse_block()
    g_want_value = want
    return alloc_node(EXPR_WHILE, cond, body, 0, 0, 0, 0, tok_ln(t), tok_cl(t))

fn parse_for_expr() -> int:
    // for var in iter: <region>。被迭代表达式恒为表达式位；体恒为语句位 region。
    // C 风格 `for a; b; c` 不支持（`;` 在 v4 只活在 `[T; N]`）。
    t := advance_tok()
    vt := advance_tok()
    vn := str_intern(tok_lx(vt))
    advance_tok()   // in
    want := g_want_value
    g_want_value = 1
    iter := parse_expr()
    g_want_value = 0
    body := parse_block()
    g_want_value = want
    return alloc_node(EXPR_FOR, vn, iter, body, 0, 0, 0, tok_ln(t), tok_cl(t))

fn parse_match_expr() -> int:
    // 被匹配的值恒为表达式位；臂体 `=> Expr` 恒为表达式位（单行，不是 region）。
    t := advance_tok()
    want := g_want_value
    g_want_value = 1
    expr := parse_expr()
    g_want_value = 0
    // An empty region is valid: if no deeper line follows `match c:`, there are no
    // arms. has_items == 0 skips the loop and there is no DEDENT to consume.
    has_items := expect_region_head()
    af := -1
    al : ., mut = -1  // last arm index
    ac : ., mut = 0
    loop:
        if has_items == 0:
            break
        skip_newlines()
        if tok_k(cur_tok()) == T_DEDENT || tok_k(cur_tok()) == T_EOF:
            break
        // Both arm forms are accepted: with a leading `|` and without it. Accepting
        // `|` is additive; programs that parsed before keep the same meaning.
        if check(T_PIPE):
            advance_tok()
        pat := parse_pattern()
        if check(T_FATARROW):
            advance_tok()
        else:
            add_error("expected '=>' in match arm")
        // If `=>` ends the line, the arm body is an indented region; otherwise it is
        // a single expression. The region has no `:`, because `=>` already opens it,
        // so expect_region_head cannot be used.
        body : ., mut = -1
        // `=>:` is accepted as a compatibility form. It has the same meaning as `=>`
        // followed by a newline and an indented region. Whether the body is a region
        // must be decided before consuming `:`, because after consuming it
        // at_line_end would see INDENT and return false.
        is_region : ., mut = 0
        if check(T_COLON_BLOCK):
            is_region = 1
            advance_tok()
        else if at_line_end() != 0:
            is_region = 1
        if is_region != 0:
            head := cur_tok()
            skip_newlines()
            if tok_k(cur_tok()) == T_INDENT:
                advance_tok()
                g_want_value = 1                 // Arm body is an expression position, so the region keeps its tail value.
                body = parse_block_items(head)
            else:
                // Empty region: `| _ =>` with no deeper line has no value.
                body = alloc_node(EXPR_BLOCK, g_block_stmt_count, 0, 0, 0, 0, 0, tok_ln(head), tok_cl(head))
        else:
            g_want_value = 1
            body = parse_expr()
        if check(T_COMMA):
            advance_tok()
        n := alloc_node(EXPR_ARM, pat, body, -1, 0, 0, 0, tok_ln(t), tok_cl(t))
        if ac == 0:
            af = n
        if al >= 0:
            ast_set_c(al, n)
        // link previous arm to this one
        al = n
        ac = ac + 1
    if has_items != 0:
        close_region()
    g_want_value = want
    return alloc_node(EXPR_MATCH, expr, af, ac, 0, 0, 0, tok_ln(t), tok_cl(t))

fn parse_pattern() -> int:
    t := cur_tok()
    if tok_k(t) == T_UNDERSCORE:
        advance_tok()
        return alloc_node(EXPR_WILDCARD, 0, 0, 0, 0, 0, 0, tok_ln(t), tok_cl(t))
    if tok_k(t) == T_INT:
        advance_tok()
        return alloc_node(EXPR_INT, 0, 0, 0, tok_iv(t), TY_INT, 0, tok_ln(t), tok_cl(t))
    if tok_k(t) == T_BIGINT:
        advance_tok()
        tl := cell_load(g_tokens, t * ESZ_TOKEN + OFF_TK_LEXEME)
        return alloc_node(EXPR_BIGINT, tl, 0, 0, 0, TY_INT, 0, tok_ln(t), tok_cl(t))
    if tok_k(t) == T_LPAREN:
        // Tuple pattern: (pat, pat, ...). EXPR_TUPLEPAT layout: a = first wrapper
        // (consecutive), b = element count. wrapper.a = subpattern, wrapper.b =
        // element index (0-based). The contract is the same as EXPR_STRUCTPAT,
        // except the second wrapper slot is positional instead of a field name.
        // Composite subpatterns occupy several nodes, so parse all subpatterns
        // first, then build contiguous wrappers. `(pat)` is grouping, exactly like
        // a parenthesized expression. Empty `()` and trailing commas are rejected
        // with a parser diagnostic instead of being silently accepted.
        advance_tok()
        if check(T_RPAREN):
            check_error(EC_P_PATTERN,
                "Empty tuple pattern is not supported; use '_'",
                tok_ln(cur_tok()), tok_cl(cur_tok()))
            advance_tok()
            return alloc_node(EXPR_TUPLEPAT, -1, 0, 0, 0, 0, 0, tok_ln(t), tok_cl(t))
        cap : ., mut = 8
        vals : string, mut = alloc(cap * 8)
        cell_store(vals, 0, parse_pattern())
        pc : ., mut = 1
        loop:
            if !check(T_COMMA):
                break
            advance_tok()  // consume comma
            if check(T_RPAREN):
                check_error(EC_P_PATTERN,
                    "Trailing comma is not supported in a tuple pattern",
                    tok_ln(cur_tok()), tok_cl(cur_tok()))
                break
            if pc >= cap:
                ncap := cap * 2
                nv := alloc(ncap * 8)
                cell_copy(vals, cap * 8, nv)
                vals = nv
                cap = ncap
            cell_store(vals, pc * 8, parse_pattern())
            pc = pc + 1
        advance_tok()  // consume )
        if pc == 1:
            // Parenthesized pattern: transparent grouping, same as `(expr)`.
            return cell_load(vals, 0)
        pf : ., mut = -1
        pi : ., mut = 0
        loop:
            if pi >= pc:
                break
            vn := cell_load(vals, pi * 8)
            ln : ., mut = tok_ln(t)
            cl : ., mut = tok_cl(t)
            if vn >= 0:
                ln = ast_line(vn)
                cl = ast_col(vn)
            wl := ast_alloc(EXPR_NONE, vn, pi, 0, 0, 0, 0, ln, cl)
            if pi == 0:
                pf = wl
            pi = pi + 1
        return alloc_node(EXPR_TUPLEPAT, pf, pc, 0, 0, 0, 0, tok_ln(t), tok_cl(t))
    if tok_k(t) == T_STRING || tok_k(t) == T_INTERP:
        return parse_interp_run()
    if tok_k(t) == T_CHAR:
        advance_tok()
        return alloc_node(EXPR_CHAR, 0, 0, 0, str_intern(tok_lx(t)), TY_CHAR, 0, tok_ln(t), tok_cl(t))
    if tok_k(t) == T_TRUE:
        advance_tok()
        return alloc_node(EXPR_BOOL, 0, 0, 0, 1, TY_BOOL, 0, tok_ln(t), tok_cl(t))
    if tok_k(t) == T_FALSE:
        advance_tok()
        return alloc_node(EXPR_BOOL, 0, 0, 0, 0, TY_BOOL, 0, tok_ln(t), tok_cl(t))
    if tok_k(t) == T_NONE:
        // Lowercase `none` is a keyword and maps to the canonical variant name `None`.
        // Without this branch it would fall into the identifier case and become a
        // variable binding, which always matches. `Some` is an ordinary identifier
        // and takes the uppercase identifier branch below.
        advance_tok()
        return alloc_node(EXPR_ENUMPAT, str_intern("None"), 0, 0, 0, 0, 0, tok_ln(t), tok_cl(t))
    if tok_k(t) == T_IDENT:
        advance_tok()
        name := tok_lx(t)
        ni := str_intern(name)
        // Handle Enum.Variant pattern
        if check(T_DOT):
            advance_tok()
            vt := advance_tok()
            name = name + "." + tok_lx(vt)
            ni = str_intern(name)
            if check(T_LPAREN):
                // Enum.Variant(subpat, ...)
                advance_tok()
                sub_first : ., mut = -1
                ac : ., mut = 0
                if !check(T_RPAREN):
                    sub_first = parse_pattern()
                    ac = 1
                    loop:
                        if !check(T_COMMA):
                            break
                        advance_tok()
                        parse_pattern()
                        ac = ac + 1
                advance_tok()
                return alloc_node(EXPR_ENUMPAT, ni, sub_first, ac, 0, 0, 0, tok_ln(t), tok_cl(t))
            return alloc_node(EXPR_ENUMPAT, ni, 0, 0, 0, 0, 0, tok_ln(t), tok_cl(t))
        if check(T_LPAREN):
            advance_tok()
            sub_first : ., mut = -1
            ac : ., mut = 0
            if !check(T_RPAREN):
                sub_first = parse_pattern()
                ac = 1
                loop:
                    if !check(T_COMMA):
                        break
                    advance_tok()
                    parse_pattern()
                    ac = ac + 1
            advance_tok()
            return alloc_node(EXPR_ENUMPAT, ni, sub_first, ac, 0, 0, 0, tok_ln(t), tok_cl(t))
        if check(T_LBRACE):
            // Struct pattern: Name { field = pat, ... }
            // EXPR_STRUCTPAT layout: a = name index, b = first wrapper, c = field
            // count. Wrappers are contiguous; wrapper.a points to the subpattern and
            // wrapper.b is the field name index (same contract as struct literals).
            // Composite subpatterns occupy several nodes, so parse all subpatterns
            // first, then build the wrappers.
            advance_tok()
            cap : ., mut = 8
            vals : string, mut = alloc(cap * 8)
            names : string, mut = alloc(cap * 8)
            fc : ., mut = 0
            loop:
                if check(T_RBRACE) || check(T_EOF):
                    break
                ft := advance_tok()
                fni := str_intern(tok_lx(ft))
                // Struct patterns also use '=' as the field separator.
                if check(T_EQ):
                    advance_tok()
                else:
                    check_error(EC_P_STRUCT_LIT_SEP,
                        "struct pattern field separator must be '='",
                        tok_ln(cur_tok()), tok_cl(cur_tok()))
                if fc >= cap:
                    ncap := cap * 2
                    nv := alloc(ncap * 8)
                    cell_copy(vals, cap * 8, nv)
                    vals = nv
                    nn := alloc(ncap * 8)
                    cell_copy(names, cap * 8, nn)
                    names = nn
                    cap = ncap
                cell_store(vals, fc * 8, parse_pattern())
                cell_store(names, fc * 8, fni)
                fc = fc + 1
                if check(T_COMMA):
                    advance_tok()
            advance_tok()
            ff : ., mut = -1
            fi2 : ., mut = 0
            loop:
                if fi2 >= fc:
                    break
                vn := cell_load(vals, fi2 * 8)
                ln : ., mut = tok_ln(t)
                cl : ., mut = tok_cl(t)
                if vn >= 0:
                    ln = ast_line(vn)
                    cl = ast_col(vn)
                wl := ast_alloc(EXPR_NONE, vn, cell_load(names, fi2 * 8), 0, 0, 0, 0, ln, cl)
                if fi2 == 0:
                    ff = wl
                fi2 = fi2 + 1
            return alloc_node(EXPR_STRUCTPAT, ni, ff, fc, 0, 0, 0, tok_ln(t), tok_cl(t))
        if is_upper_first(name):
            return alloc_node(EXPR_ENUMPAT, ni, 0, 0, 0, 0, 0, tok_ln(t), tok_cl(t))
        return alloc_node(EXPR_IDENT, 0, 0, 0, ni, 0, 0, tok_ln(t), tok_cl(t))
    advance_tok()
    return 0

// --- Top-level declarations ---

fn parse_generics() -> int:
    open_tok : ., mut = 0
    close_tok : ., mut = 0
    if check(T_LBRACKET):
        open_tok = T_LBRACKET
        close_tok = T_RBRACKET
    else if check(T_LT):
        open_tok = T_LT
        close_tok = T_GT
    if open_tok > 0:
        advance_tok() // [ or <
        gc : ., mut = 0
        loop:
            if check(close_tok):
                break
            if gc >= MAX_GENERICS:
                break
            advance_tok()
            gc = gc + 1
            if !check(T_COMMA):
                break
            advance_tok()
        advance_tok() // ] or >
        return gc
    return 0

fn parse_generics_into(names: string, constrs: string) -> int:
    // Initialize constraints to -1 (no constraint)
    ci : ., mut = 0
    loop:
        if ci >= 4:
            break
        cell_store(constrs, ci * 8, -1)
        ci = ci + 1
    open_tok : ., mut = 0
    close_tok : ., mut = 0
    if check(T_LBRACKET):
        open_tok = T_LBRACKET
        close_tok = T_RBRACKET
    else if check(T_LT):
        open_tok = T_LT
        close_tok = T_GT
    if open_tok > 0:
        advance_tok() // [ or <
        gc : ., mut = 0
        loop:
            if check(close_tok):
                break
            if gc >= MAX_GENERICS:
                break
            gt := advance_tok()
            unsafe:
                cell_store(names, gc * 8, @ptr_of(tok_lx(gt)))
            // Check for constraint: T: Interface
            cell_store(constrs, gc * 8, -1)
            if check(T_COLON_DECL):
                advance_tok()
                ct := advance_tok()
                cell_store(constrs, gc * 8, str_intern(tok_lx(ct)))
            gc = gc + 1
            if !check(T_COMMA):
                break
            advance_tok()
        advance_tok() // ] or >
        return gc
    return 0

fn save_func_generics(fi: int, names: string, count: int):
    fi_set_generic_count(fi, count)
    gi : ., mut = 0
    loop:
        if gi >= count:
            break
        name_str := unsafe:
            @str_of(cell_load(names, gi * 8))
        ni := str_intern(name_str)
        fi_set_generic_name(fi, gi, ni)
        gi = gi + 1

fn save_func_gen_constrs(fi: int, constrs: string, count: int):
    gi : ., mut = 0
    loop:
        if gi >= count:
            break
        if cell_load(constrs, gi * 8) >= 0:
            idx := fi * MAX_GENERICS + gi
            grow_gen_constr(idx + 1)
            cell_store(g_generic_constr, idx * 8, cell_load(constrs, gi * 8))
            if idx + 1 > g_generic_constr_count:
                g_generic_constr_count = idx + 1
        gi = gi + 1

// Struct and enum generic constraints use a separate index space:
// row * MAX_GENERICS + gi. This is a different buffer from the function-side
// g_generic_constr table.
// The table is sparse, so every slot in a row is first filled with -1. Otherwise
// an unwritten slot reads 0, which is a valid name index and would be treated as a
// real constraint. Each row then means "all parameter positions have known
// values". The reader still rejects idx >= count.
fn save_struct_gen_constrs(si: int, constrs: string, count: int):
    grow_sgen_constr(si * MAX_GENERICS + MAX_GENERICS)
    if si * MAX_GENERICS + MAX_GENERICS > g_sgen_constr_count:
        g_sgen_constr_count = si * MAX_GENERICS + MAX_GENERICS
    zi : ., mut = 0
    loop:
        if zi >= MAX_GENERICS:
            break
        cell_store(g_sgen_constr, (si * MAX_GENERICS + zi) * 8, -1)
        zi = zi + 1
    gi : ., mut = 0
    loop:
        if gi >= count:
            break
        if gi >= MAX_GENERICS:
            break
        if cell_load(constrs, gi * 8) >= 0:
            cell_store(g_sgen_constr, (si * MAX_GENERICS + gi) * 8, cell_load(constrs, gi * 8))
        gi = gi + 1

fn save_enum_gen_constrs(ei: int, constrs: string, count: int):
    grow_egen_constr(ei * MAX_GENERICS + MAX_GENERICS)
    if ei * MAX_GENERICS + MAX_GENERICS > g_egen_constr_count:
        g_egen_constr_count = ei * MAX_GENERICS + MAX_GENERICS
    zi : ., mut = 0
    loop:
        if zi >= MAX_GENERICS:
            break
        cell_store(g_egen_constr, (ei * MAX_GENERICS + zi) * 8, -1)
        zi = zi + 1
    gi : ., mut = 0
    loop:
        if gi >= count:
            break
        if gi >= MAX_GENERICS:
            break
        if cell_load(constrs, gi * 8) >= 0:
            cell_store(g_egen_constr, (ei * MAX_GENERICS + gi) * 8, cell_load(constrs, gi * 8))
        gi = gi + 1

fn add_func(name: string, pc: int, rt: int, an: int) -> int:
    idx := g_func_count
    grow_funcs(idx + 1)
    ni := str_intern(name)
    fi_set_name(idx, ni)
    fi_set_param_count(idx, pc)
    fi_set_return_type(idx, rt)
    fi_set_ast_node(idx, an)
    g_func_count = idx + 1
    return idx

fn add_struct(name: string) -> int:
    idx := g_struct_count
    grow_structs(idx + 1)
    ni := str_intern(name)
    base := idx * ESZ_STRUCTINFO
    // Zero the entire struct entry
    zi : ., mut = 0
    loop:
        if zi >= ESZ_STRUCTINFO:
            break
        cell_store8(g_structs, base + zi, 0)
        zi = zi + 1
    cell_store(g_structs, base + OFF_SI_NAME, ni)
    // Field storage starts at the side table high-water mark. Writes use base +
    // index; si_commit_fields commits the range at the end of the body.
    si_set_field_base(idx, g_si_f_used)
    g_struct_count = idx + 1
    return idx

fn add_enum(name: string) -> int:
    idx := g_enum_count
    grow_enums(idx + 1)
    ni := str_intern(name)
    base := idx * ESZ_ENUMINFO
    // Zero the entire enum entry
    zi : ., mut = 0
    loop:
        if zi >= ESZ_ENUMINFO:
            break
        cell_store8(g_enums, base + zi, 0)
        zi = zi + 1
    cell_store(g_enums, base + OFF_EI_NAME, ni)
    // Variant storage starts at the side table high-water mark. Writes use base +
    // index; ei_commit_variants commits the range at the end of the body.
    ei_set_variant_base(idx, g_ei_v_used)
    g_enum_count = idx + 1
    return idx

fn extract_hotpatch_ver(args_node: int) -> int:
    if args_node < 0:
        return -1
    arg := args_node
    loop:
        if arg < 0:
            break
        expr := ast_a(arg)
        k := ast_kind(expr)
        if k == EXPR_ASSIGN:
            name_ni := ast_a(expr)
            name := istr_get(name_ni)
            val_node := ast_b(expr)
            if str_eq(name, "ver") != 0:
                return ast_int_val(val_node)
        arg = ast_b(arg)
    return -1

fn parse_body(fn_name: string, fn_ni: int, fn_line: int, fn_col: int, hotpatch_ver: int):
    gnames : string, mut
    gnames_cap : int, mut
    gnames = alloc(64 * 8)
    gnames_cap = 64
    gconstrs : string, mut
    gconstrs_cap : int, mut
    gconstrs = alloc(64 * 8)
    gconstrs_cap = 64
    gc := parse_generics_into(gnames, gconstrs)

    advance_tok() // (
    pf : ., mut = -1
    pc : ., mut = 0
    if !check(T_RPAREN):
        loop:
            // Handle self/&self/&mut self params
            if tok_k(cur_tok()) == T_SELF:
                pt := advance_tok()
                if pf < 0:
                    pf = g_ast_count
                alloc_node(EXPR_PARAM, str_intern("self"), 0, 0, 1, 0, 0, tok_ln(pt), tok_cl(pt))
                pc = pc + 1
                if check(T_COLON_DECL):
                    advance_tok()
                    parse_type()
                if !check(T_COMMA):
                    break
                advance_tok()
                continue
            if tok_k(cur_tok()) == T_AMPERSAND && tok_k(cur_tok()+1) == T_MUT && tok_k(cur_tok()+2) == T_SELF:
                pt := advance_tok()
                advance_tok()
                advance_tok()
                if pf < 0:
                    pf = g_ast_count
                alloc_node(EXPR_PARAM, str_intern("self"), 0, 0, 3, 0, 0, tok_ln(pt), tok_cl(pt))
                pc = pc + 1
                if check(T_COLON_DECL):
                    advance_tok()
                    parse_type()
                if !check(T_COMMA):
                    break
                advance_tok()
                continue
            if tok_k(cur_tok()) == T_AMPERSAND && tok_k(cur_tok()+1) == T_SELF:
                pt := advance_tok()
                advance_tok()
                if pf < 0:
                    pf = g_ast_count
                alloc_node(EXPR_PARAM, str_intern("self"), 0, 0, 2, 0, 0, tok_ln(pt), tok_cl(pt))
                pc = pc + 1
                if check(T_COLON_DECL):
                    advance_tok()
                    parse_type()
                if !check(T_COMMA):
                    break
                advance_tok()
                continue
            // Variadic: ...name:type
            if check(T_DOTDOTDOT):
                advance_tok()
                vt := advance_tok()
                vn := str_intern(tok_lx(vt))
                advance_tok()
                vty := parse_type()
                if pf < 0:
                    pf = g_ast_count
                alloc_node(EXPR_PARAM, vn, 0, 0, -1, 0, vty, tok_ln(vt), tok_cl(vt))
                pc = pc + 1
                if !check(T_COMMA):
                    break
                advance_tok()
                continue
            pt := advance_tok()
            pn := str_intern(tok_lx(pt))
            advance_tok()
            pty := parse_type()
            if pf < 0:
                pf = g_ast_count
            alloc_node(EXPR_PARAM, pn, 0, 0, 0, unpack_type(pty), pty, tok_ln(pt), tok_cl(pt))
            pc = pc + 1
            if !check(T_COMMA):
                break
            advance_tok()
    advance_tok() // )
    rt : ., mut = 0
    rtv : ., mut = TY_UNIT
    if check(T_ARROW):
        advance_tok() // ->
        rt = parse_type()
        rtv = unpack_type(rt)

    // Spec annotations (#check / #ensure) appear between the signature and the body.
    // Record their start index, then backfill each row with the fn_node index after
    // the function node is allocated. The node index is unique; a function name is
    // not, because methods and multiple impls can share names.
    spec_start := g_spec_count
    parse_spec_annotations(fn_ni, 0)   // inline 形（兼容）：注解后紧跟 `:`，不要求行尾

    body : ., mut = -1
    // A body starts with a trailing colon (T_COLON_BLOCK) and a region. A
    // declaration without a body, such as an extern function, ends at a line
    // boundary. A function body is always in statement position, so a trailing bare
    // expression is wrapped in EXPR_STMT and the block type is unit. Values leave a
    // function only through an explicit return.
    if at_line_end() != 0:
        body = -1
    else if check(T_EQ):
        // `fn f() = expr` is an expression body; the right-hand side is an
        // expression position.
        advance_tok()
        g_want_value = 1
        body = parse_expr()
    else:
        g_want_value = 0
        // Spec annotations may appear at the start of the function region, before
        // the statements. Consume the region head here, read #check / #ensure, then
        // parse the statements. parse_block cannot do this because it starts after
        // the annotations. The inline form, with annotations between the signature
        // and the colon, is kept for compatibility with tests/spec.
        head := cur_tok()
        if expect_region_head() == 0:
            // Empty function body: no items, no value, block type unit.
            body = alloc_node(EXPR_BLOCK, g_block_stmt_count, 0, 0, 0, 0, 0, tok_ln(head), tok_cl(head))
        else:
            parse_spec_annotations(fn_ni, 1)   // 文档形：注解独占一行
            body = parse_block_items(head)
    fn_node := alloc_node(EXPR_FN, fn_ni, pf, pc, rtv + hotpatch_ver * 256, rt, body, fn_line, fn_col)
    // Backfill this function's annotation rows with fn_node.
    spec_patch : ., mut = spec_start
    loop:
        if spec_patch >= g_spec_count:
            break
        spec_set_fnode(spec_patch, fn_node)
        spec_patch = spec_patch + 1
    // FuncInfo.param_types is a fixed inline slot array of MAX_FN_PARAMS entries.
    // A larger signature cannot be represented, so reject it instead of truncating
    // or writing past the end. An out-of-bounds write previously corrupted ast_node
    // and produced TF01 with a broken binary.
    if pc > MAX_FN_PARAMS:
        check_error(EC_P_TOO_MANY_PARAMS,
            "Function has too many parameters (" + int_str(pc) + " > " + int_str(MAX_FN_PARAMS) + ")",
            fn_line, fn_col)
    fi := add_func(fn_name, pc, rtv, fn_node)
    if fi >= 0 && gc > 0:
        save_func_generics(fi, gnames, gc)
        save_func_gen_constrs(fi, gconstrs, gc)
    // Store parameter types in FuncInfo. pc > MAX_FN_PARAMS was rejected above;
    // the explicit skip here and the bounds check in fi_set_param_type are a second
    // guard.
    if fi >= 0 && pc <= MAX_FN_PARAMS:
        pstore_i : ., mut = 0
        pstore_n : ., mut = pf
        loop:
            if pstore_i >= pc:
                break
            if pstore_n < 0:
                break
            if ast_kind(pstore_n) == EXPR_PARAM:
                fi_set_param_type(fi, pstore_i, ast_type_val(pstore_n))
                pstore_i = pstore_i + 1
            pstore_n = pstore_n + 1

// Spec annotations #check(expr) and #ensure(expr) appear between a function
// signature and its body. See docs/maintainer/design/spec-design.md section 4.
// check and ensure are not keywords: the repository already has `fn check` and the
// CLI subcommand "check". Both are compared as lexemes, and the token after # is
// T_IDENT.
// Expressions use parse_expr and land in g_ast, but the body does not reference
// them and they do not enter g_block_stmts, so IR generation never reaches them
// and the emitted image is unchanged. Rows go to the spec_add side table for the
// checker and dump.
// Malformed forms report EC_V_* errors and stop without consuming the rest; the
// outer parser then reports a second signal. The function serves two positions:
//   inline: between the signature and ':', annotations on the same line,
//           need_eol=0 because the next token is T_COLON_BLOCK;
//   documented: at the start of the function region, one annotation per line,
//           need_eol=1. skip_newlines at the loop end allows a multi-line chain.
fn parse_spec_annotations(fn_ni: int, need_eol: int):
    loop:
        if !check(T_HASH):
            break
        at_line := tok_ln(cur_tok())
        at_col := tok_cl(cur_tok())
        advance_tok()  // '#'
        if tok_k(cur_tok()) != T_IDENT:
            check_error(EC_V_BAD_TAG, "Expected annotation name after '#'", at_line, at_col)
            return
        an_name := tok_lx(cur_tok())
        kind : ., mut = -1
        if str_eq(an_name, "check") != 0:
            kind = 0
        else if str_eq(an_name, "ensure") != 0:
            kind = 1
        if kind < 0:
            check_error(EC_V_BAD_TAG,
                "Unknown annotation '#" + an_name + "' (expected '#check' or '#ensure')", at_line, at_col)
            return
        advance_tok()  // 标注名
        if !check(T_LPAREN):
            check_error(EC_V_ANN_SYNTAX, "Expected '(' after '#" + an_name + "'", at_line, at_col)
            return
        advance_tok()  // '('
        expr := parse_expr()
        if !check(T_RPAREN):
            check_error(EC_V_ANN_SYNTAX,
                "Expected ')' to close '#" + an_name + "' annotation", at_line, at_col)
            return
        advance_tok()  // ')'
        // A documented annotation must be alone on its line. Report a coded V03
        // diagnostic, not add_error: an uncoded message is hidden by
        // run_frontend's early return on g_diag_count > 0 and never reaches the
        // user. tests/spec/t2_neg_inbody.cr is the negative case.
        if need_eol != 0 && at_line_end() == 0:
            check_error(EC_V_ANN_SYNTAX,
                "Expected end of line after '#" + an_name + "' annotation", at_line, at_col)
            return
        spec_add(fn_ni, kind, expr, at_line, at_col)
        // Skip newlines between annotations only. A NEWLINE before the first
        // annotation belongs to the preceding body-less declaration; consuming it
        // here would make the caller see a non-boundary.
        skip_newlines()

fn parse_ffi_annotation() -> int:
    // Current token is T_AT; consume it and parse @ffi("lang")
    advance_tok() // skip @
    if tok_k(cur_tok()) != T_IDENT:
        add_error("expected ffi")
        return -1
    lex := tok_lx(cur_tok())
    if str_eq(lex, "ffi") == 0:
        add_error("expected ffi")
        return -1
    advance_tok()
    // Expect ( "lang_name" )
    if tok_k(cur_tok()) != T_LPAREN:
        add_error("expected (")
        return -1
    advance_tok()
    if tok_k(cur_tok()) != T_STRING:
        add_error("expected string literal for FFI language")
        return -1
    lang_ni := str_intern(tok_lx(cur_tok()))
    advance_tok()
    if tok_k(cur_tok()) != T_RPAREN:
        add_error("expected )")
        return -1
    advance_tok()
    return lang_ni

fn parse_declaration():
    hotpatch_ver : ., mut = 0
    lead_ffi_ni : ., mut = -1

    // Top-level declarations may have leading @ annotations, one or more, each on
    // its own line. The allowed forms are:
    //   @ffi("Python") or @ffi("Java") before extern fn
    //   @hotpatch(ver=1) or @hotpatch(ver=2) before fn
    //   @preferredDomain(gpu) before fn
    //   @executionDomain(fpgaA) before flow
    // Any other name reports V02 here. A typo such as @hotpach must not be silently
    // dropped. @inline, @section, @fast, @NoBoundsCheck, @addr, and @sizeOf are
    // expression or statement annotations and do not belong in this position.
    loop:
        if !check(T_AT):
            break
        at_line := tok_ln(cur_tok())
        at_col := tok_cl(cur_tok())
        saved_ast := g_ast_count
        annotation := parse_expr()
        k := ast_kind(annotation)
        an_name_ni : ., mut = -1
        an_args : ., mut = -1
        if k == EXPR_CALL:
            callee := ast_a(annotation)
            if ast_kind(callee) == EXPR_AT:
                an_name_ni = ast_a(callee)
                an_args = ast_b(annotation)
        else if k == EXPR_AT:
            an_name_ni = ast_a(annotation)
        an_name : ., mut = ""
        if an_name_ni >= 0:
            an_name = istr_get(an_name_ni)
        // Merge known and unknown annotations through a flag. An empty else-if
        // branch is not expressible in a region.
        known : ., mut = 0
        if str_eq(an_name, "hotpatch") != 0:
            known = 1
            hv := extract_hotpatch_ver(an_args)
            if hv >= 0:
                hotpatch_ver = hv
            else:
                hotpatch_ver = 1
        else if str_eq(an_name, "ffi") != 0:
            known = 1
            // @ffi("lang") before extern fn: the language name is the first string
            // argument.
            if an_args >= 0 && ast_kind(an_args) == EXPR_ARG:
                s := ast_a(an_args)
                if s >= 0 && ast_kind(s) == EXPR_STRING:
                    lead_ffi_ni = ast_int_val(s)
        else if str_eq(an_name, "preferredDomain") != 0:
            known = 1
        else if str_eq(an_name, "executionDomain") != 0:
            known = 1
        if known == 0:
            check_error(EC_V_BAD_TAG,
                "Unknown top-level '@" + an_name + "' annotation (expected '@hotpatch' / '@ffi' / '@preferredDomain' / '@executionDomain')",
                at_line, at_col)
        g_ast_count = saved_ast
        skip_newlines()

    ip : ., mut = 0
    if check(T_PUB):
        ip = 1
        advance_tok()

    // extern fn declaration (FFI)
    if check(T_EXTERN):
        t := cur_tok()
        advance_tok()
        ffi_lang_ni : ., mut = lead_ffi_ni   // 前导 `@ffi("…")`（§13.5 文档形）
        // 兼容旧形（注解夹在 `extern` 与 `fn` 之间）
        if check(T_AT):
            ffi_lang_ni = parse_ffi_annotation()
        // Expect fn keyword
        if tok_k(cur_tok()) != T_FN:
            add_error("expected 'fn' after extern")
            return
        advance_tok()
        // Parse function name
        nt := advance_tok()
        name := tok_lx(nt)
        fn_name_ni := str_intern(name)
        // Parse param list: (name: type, ...)
        advance_tok() // (
        first_param : ., mut = -1
        param_count : ., mut = 0
        // The C ABI has no optional representation, so extern parameters and return
        // types cannot be optional. Reject them with P024 and produce no output.
        // Non-optional extern declarations are unchanged.
        extern_opt : ., mut = 0
        if !check(T_RPAREN):
            loop:
                pt := advance_tok()
                pn := str_intern(tok_lx(pt))
                advance_tok() // :
                pty := parse_type()
                if pty >= 0 && ast_kind(pty) == EXPR_OPTIONAL:
                    extern_opt = 1
                if first_param < 0:
                    first_param = g_ast_count
                alloc_node(EXPR_PARAM, pn, 0, 0, 0, unpack_type(pty), pty, tok_ln(pt), tok_cl(pt))
                param_count = param_count + 1
                if !check(T_COMMA):
                    break
                advance_tok()
        advance_tok() // )
        // Parse return type (optional, defaults to unit)
        ret_type : ., mut = TY_UNIT
        if check(T_ARROW):
            advance_tok()
            ret_node := parse_type()
            if ret_node >= 0 && ast_kind(ret_node) == EXPR_OPTIONAL:
                extern_opt = 1
            ret_type = unpack_type(ret_node)
        if extern_opt != 0:
            check_error(EC_P_EXTERN_OPTIONAL, "extern declaration cannot use optional type ('?') - no C ABI representation", tok_ln(t), tok_cl(t))
        // Create EXPR_EXTERN node (no body)
        node : ., mut = alloc_node(EXPR_EXTERN, fn_name_ni, first_param, param_count, 0, ret_type, ffi_lang_ni, tok_ln(t), tok_cl(t))
        // An extern declaration ends at a line boundary. A trailing semicolon is
        // optional.
        end_decl()
        return

    // fn / flow
    if check(T_FN) || check(T_FLOW):
        is_flow : ., mut = 0
        // Both `flow name(...)` and `flow fn name(...)` are accepted. The documented
        // form omits fn; the fn form is kept for compatibility with existing corpus
        // files. The old code consumed T_FLOW and then treated T_FN as the function
        // name, which made flow functions unreachable.
        t : ., mut = cur_tok()
        if check(T_FLOW):
            is_flow = 1
            advance_tok()  // 消费 'flow'
            if check(T_FN):
                t = advance_tok()  // 兼容形：定位令牌取 `fn`
        else:
            advance_tok()  // 消费 'fn'
        nt := advance_tok()
        name := tok_lx(nt)
        ni := str_intern(name)
        parse_body(name, ni, tok_ln(t), tok_cl(t), hotpatch_ver)

        // A flow function may contain yield. The checker detects yield and skips
        // the return type check.

        return

    // struct
    if check(T_STRUCT):
        t := advance_tok()
        nt := advance_tok()
        name := tok_lx(nt)
        sg_names : string, mut
        sg_names_cap : int, mut
        sg_names = alloc(64 * 8)
        sg_names_cap = 64
        sg_constrs : string, mut
        sg_constrs_cap : int, mut
        sg_constrs = alloc(64 * 8)
        sg_constrs_cap = 64
        sg_count := parse_generics_into(sg_names, sg_constrs)
        has_items := expect_region_head()   // 0 = 空 region（如 `struct S:` 后无可达更深的行）

        si := add_struct(name)
        if si >= 0:
            if sg_count > 0:
                cell_store(g_structs, si * ESZ_STRUCTINFO + OFF_SI_GENERIC_COUNT, sg_count)
                sgi : ., mut = 0
                loop:
                    if sgi >= sg_count:
                        break
                    unsafe:
                        cell_store(g_structs, si * ESZ_STRUCTINFO + OFF_SI_GENERIC_NAMES + sgi * 8, str_intern(@str_of(cell_load(sg_names, sgi * 8))))
                    sgi = sgi + 1
                // Register struct generic constraints in the struct side table.
                // The old code wrote them to a dummy buffer and dropped them, so
                // `struct Box[T: I]` had no constraint. The instantiation point in
                // res_type_node reads this table.
                save_struct_gen_constrs(si, sg_constrs, sg_count)
            fc : ., mut = 0
            loop:
                if has_items == 0:
                    break
                skip_newlines()
                if tok_k(cur_tok()) == T_DEDENT || tok_k(cur_tok()) == T_EOF:
                    break
                ft := advance_tok()
                fn2 := tok_lx(ft)
                fni := str_intern(fn2)
                // Fields have no hard limit; they live in a side table. Writes past
                // the old 16-field limit are valid and cannot overflow the struct
                // record.
                si_set_field_name(si, fc, fni)
                if check(T_COLON_DECL):
                    advance_tok()
                else:
                    add_error("expected ':' after struct field name")
                fty := parse_type()
                si_set_field_type(si, fc, unpack_type(fty))
                si_set_field_type_node(si, fc, fty)
                fc = fc + 1
                if check(T_COMMA):
                    advance_tok()
            cell_store(g_structs, si * ESZ_STRUCTINFO + OFF_SI_FIELD_COUNT, fc)
            si_commit_fields(si, fc)   // 提交字段区（高水位 = base + fc）
        if has_items != 0:
            close_region()
        return

    // enum
    if check(T_ENUM):
        t := advance_tok()
        nt := advance_tok()
        name := tok_lx(nt)
        eg_names : string, mut
        eg_names_cap : int, mut
        eg_names = alloc(64 * 8)
        eg_names_cap = 64
        eg_constrs : string, mut
        eg_constrs_cap : int, mut
        eg_constrs = alloc(64 * 8)
        eg_constrs_cap = 64
        eg_count := parse_generics_into(eg_names, eg_constrs)
        has_items := expect_region_head()   // 0 = 空 region

        ei := add_enum(name)
        if ei >= 0:
            if eg_count > 0:
                cell_store(g_enums, ei * ESZ_ENUMINFO + OFF_EI_GENERIC_COUNT, eg_count)
                egi : ., mut = 0
                loop:
                    if egi >= eg_count:
                        break
                    unsafe:
                        cell_store(g_enums, ei * ESZ_ENUMINFO + OFF_EI_GENERIC_NAMES + egi * 8, str_intern(@str_of(cell_load(eg_names, egi * 8))))
                    egi = egi + 1
                // Enum generic constraints are registered the same way as struct
                // constraints.
                save_enum_gen_constrs(ei, eg_constrs, eg_count)
            vc : ., mut = 0
            loop:
                if has_items == 0:
                    break
                skip_newlines()
                if tok_k(cur_tok()) == T_DEDENT || tok_k(cur_tok()) == T_EOF:
                    break
                vt := advance_tok()
                vname := tok_lx(vt)
                vni := str_intern(vname)
                // Variants have no hard limit; they live in a side table. The old
                // overflow check and slot limit were removed.
                ei_set_variant_name(ei, vc, vni)
                tc : ., mut = 0
                if check(T_LPAREN):
                    advance_tok()
                    loop:
                        if check(T_RPAREN):
                            break
                        fty := parse_type()
                        ei_set_variant_type(ei, vc, tc, unpack_type(fty))
                        // Write the payload type node together with the raw code, as
                        // struct fields do. The raw code collapses non-base payloads
                        // to 0 (TY_INT); the node is the faithful type for generic
                        // substitution and satisfaction checks.
                        ei_set_variant_type_node(ei, vc, tc, fty)
                        tc = tc + 1
                        if !check(T_COMMA):
                            break
                        advance_tok()
                    advance_tok()
                ei_set_variant_type_count(ei, vc, tc)
                vc = vc + 1
                if check(T_COMMA):
                    advance_tok()
            cell_store(g_enums, ei * ESZ_ENUMINFO + OFF_EI_VARIANT_COUNT, vc)
            ei_commit_variants(ei, vc)   // 提交变体区（高水位 = base + vc）
        if has_items != 0:
            close_region()
        return

    // interface declaration
    if check(T_INTERFACE):
        t := advance_tok()
        nt := advance_tok()
        iface_name := tok_lx(nt)
        iface_ni := str_intern(iface_name)
        ig_names : string, mut
        ig_names_cap : int, mut
        ig_names = alloc(64 * 8)
        ig_names_cap = 64
        ig_dummy : string, mut
        ig_dummy_cap : int, mut
        ig_dummy = alloc(64 * 8)
        ig_dummy_cap = 64
        ig_count := parse_generics_into(ig_names, ig_dummy)
        has_items := expect_region_head()   // 0 = empty region: a zero-method interface

        // Allocate interface entry
        grow_ifaces(g_iface_count + 1)
        iface_base := g_iface_count * ESZ_IFACEINFO
        // Zero it out
        zi : ., mut = 0
        loop:
            if zi >= ESZ_IFACEINFO:
                break
            cell_store8(g_ifaces, iface_base + zi, 0)
            zi = zi + 1
        cell_store(g_ifaces, iface_base + OFF_IF_NAME, iface_ni)
        cell_store(g_ifaces, iface_base + OFF_IF_GENERIC_COUNT, ig_count)
        method_count : ., mut = 0

        loop:
            if has_items == 0:
                break
            skip_newlines()
            if tok_k(cur_tok()) == T_DEDENT || tok_k(cur_tok()) == T_EOF:
                break
            if check(T_FN):
                advance_tok() // fn
                mt := advance_tok() // method name
                method_ni := str_intern(tok_lx(mt))
                advance_tok() // (

                // Parse params with types (handle self, &self, &mut self, name: Type)
                pc : ., mut = 0
                param_tis : string, mut
                param_tis_cap : int, mut
                param_tis = alloc(128 * 8)
                param_tis_cap = 128
                pi2 : ., mut = 0
                loop:
                    if pi2 >= 8:
                        break
                    cell_store(param_tis, pi2 * 8, TY_UNIT)
                    pi2 = pi2 + 1
                // Signature type-node slots are written next to the raw code slots,
                // as struct and enum fields are. The self receiver slot has no node;
                // both frontends share that convention.
                param_nodes : string, mut
                param_nodes_cap : int, mut
                param_nodes = alloc(128 * 8)
                param_nodes_cap = 128
                pni2 : ., mut = 0
                loop:
                    if pni2 >= 8:
                        break
                    cell_store(param_nodes, pni2 * 8, -1)
                    pni2 = pni2 + 1
                self_mode : ., mut = 0
                if !check(T_RPAREN):
                    loop:
                        fst := cur_tok()
                        // Handle &self / &mut self / self
                        if tok_k(fst) == T_AMPERSAND || tok_k(fst) == T_SELF:
                            self_mode_t : ., mut = 1                 // self
                            if tok_k(fst) == T_AMPERSAND:
                                advance_tok() // &
                                self_mode_t = 2                       // &self
                                if check(T_MUT):
                                    advance_tok()
                                    self_mode_t = 3
                                // &mut self
                            nt2 := advance_tok() // self
                            if pc < 8:
                                cell_store(param_tis, pc * 8, 0)
                            // match function's default for &self
                            if pc == 0:
                                self_mode = self_mode_t
                            // 首参 = 接收者才记模式
                            pc = pc + 1
                        else:
                            advance_tok() // param name
                            advance_tok() // :
                            ptype := parse_type()
                            if pc < 8:
                                cell_store(param_tis, pc * 8, unpack_type(ptype))
                                cell_store(param_nodes, pc * 8, ptype)
                            pc = pc + 1
                        if !check(T_COMMA):
                            break
                        advance_tok()
                advance_tok() // )

                // Parse return type
                ret_ti : ., mut = TY_UNIT
                ret_node : ., mut = -1
                if check(T_ARROW):
                    advance_tok()
                    rn2 := parse_type()
                    ret_node = rn2
                    ret_ti = unpack_type(rn2)
                // Interface methods have no body and no colon. They end at a line
                // boundary.
                end_decl()

                // Store method in interface entry (with overflow checks)
                // The method limit is MAX_IFACE_METHODS. Exceeding it is a hard error,
                // not a silent truncation. A side-table migration is described in the
                // dyn_arr.cr constant comment.
                if method_count >= MAX_IFACE_METHODS:
                    grow_diags(g_diag_count + 1)
                    cell_store(g_diags, g_diag_count * DIAG_REC_SIZE, EC_P_FIELD_SYNTAX)
                    cell_store_str(g_diags, g_diag_count * DIAG_REC_SIZE + 8, "interface '" + iface_name + "' exceeds max 16 methods")
                    cell_store(g_diags, g_diag_count * DIAG_REC_SIZE + 16, tok_ln(t))
                    cell_store(g_diags, g_diag_count * DIAG_REC_SIZE + 24, tok_cl(t))
                    cell_store(g_diags, g_diag_count * DIAG_REC_SIZE + 32, diag_fileid_for_line(tok_ln(t)))
                    g_diag_count = g_diag_count + 1
                else:
                    mbase := iface_base + OFF_IF_METHODS + method_count * ESZ_IFMETHOD
                    cell_store(g_ifaces, mbase + OFF_IFM_NAME, method_ni)
                    cell_store(g_ifaces, mbase + OFF_IFM_PARAM_COUNT, pc)
                    cell_store(g_ifaces, mbase + OFF_IFM_RET_TI, ret_ti)
                    cell_store(g_ifaces, mbase + OFF_IFM_RET_NODE, ret_node)
                    cell_store(g_ifaces, mbase + OFF_IFM_SELF_MODE, self_mode)
                    pj : ., mut = 0
                    loop:
                        if pj >= 8 || pj >= pc:
                            break
                        cell_store(g_ifaces, mbase + OFF_IFM_PARAM_TYPES + pj * 8, cell_load(param_tis, pj * 8))
                        cell_store(g_ifaces, mbase + OFF_IFM_PARAM_NODES + pj * 8, cell_load(param_nodes, pj * 8))
                        pj = pj + 1
                    if pc > 8:
                        grow_diags(g_diag_count + 1)
                        cell_store(g_diags, g_diag_count * DIAG_REC_SIZE, EC_P_PARAM_TYPE)
                        cell_store_str(g_diags, g_diag_count * DIAG_REC_SIZE + 8, "method '" + istr_get(method_ni) + "' in interface exceeds max 8 params")
                        cell_store(g_diags, g_diag_count * DIAG_REC_SIZE + 16, tok_ln(t))
                        cell_store(g_diags, g_diag_count * DIAG_REC_SIZE + 24, tok_cl(t))
                        cell_store(g_diags, g_diag_count * DIAG_REC_SIZE + 32, diag_fileid_for_line(tok_ln(t)))
                        g_diag_count = g_diag_count + 1
                method_count = method_count + 1
            else:
                advance_tok()
        cell_store(g_ifaces, iface_base + OFF_IF_METHOD_COUNT, method_count)
        g_iface_count = g_iface_count + 1
        if has_items != 0:
            close_region()
        return

    // impl block (impl Type: ... or impl Interface for Type: ...)
    if check(T_IMPL):
        t := advance_tok()
        first_nt := advance_tok()
        first_name := tok_lx(first_nt)
        first_ni := str_intern(first_name)
        trait_ni : ., mut = -1
        type_ni : ., mut = first_ni
        type_name : ., mut = first_name
        if check(T_FOR):
            advance_tok()
            trait_ni = first_ni
            type_nt := advance_tok()
            type_name = tok_lx(type_nt)
            type_ni = str_intern(type_name)
        has_items := expect_region_head()   // 0 = 空 region
        loop:
            if has_items == 0:
                break
            skip_newlines()
            if tok_k(cur_tok()) == T_DEDENT || tok_k(cur_tok()) == T_EOF:
                break
            if check(T_FN):
                ft := advance_tok()
                method_nt := advance_tok()
                method_name := tok_lx(method_nt)
                method_ni := str_intern(method_name)
                mangled := type_name + "." + method_name
                mangled_ni := str_intern(mangled)
                parse_body(mangled, mangled_ni, tok_ln(ft), tok_cl(ft), 0)
                // Register in method lookup table
                grow_methods(g_method_count + 1)
                cell_store(g_methods, g_method_count * 24, type_ni)
                cell_store(g_methods, g_method_count * 24 + 8, method_ni)
                cell_store(g_methods, g_method_count * 24 + 16, mangled_ni)
                g_method_count = g_method_count + 1
            else:
                advance_tok()
        if has_items != 0:
            close_region()
        // Store impl-for relationship after processing all methods
        if trait_ni >= 0:
            grow_impl_for(g_impl_for_count + 1)
            cell_store(g_impl_for, g_impl_for_count * 16, trait_ni)
            cell_store(g_impl_for, g_impl_for_count * 16 + 8, type_ni)
            g_impl_for_count = g_impl_for_count + 1
        return

    // type alias
    if check(T_TYPE):
        advance_tok()
        nt := advance_tok()
        name_idx := str_intern(tok_lx(nt))
        if check(T_EQ):
            advance_tok()
        else:
            add_error("expected '=' in type alias")
        type_node := parse_type()
        end_decl()
        grow_type_aliases(g_type_alias_count + 1)
        cell_store(g_type_aliases, g_type_alias_count * 16, name_idx)
        cell_store(g_type_aliases, g_type_alias_count * 16 + 8, type_node)
        g_type_alias_count = g_type_alias_count + 1
        return

    // mod declaration: mod name; or mod path::name; or mod name { ... }
    if check(T_MOD):
        t := advance_tok()
        nt := advance_tok()
        path_name := tok_lx(nt)
        // Collect full path: mod a::b::c;
        loop:
            if check(T_PATHSEP):
                advance_tok()
                nt2 := advance_tok()
                path_name = path_name + "::" + tok_lx(nt2)
            else:
                break
        mod_ni := str_intern(path_name)
        // Store mod path for checker registration
        grow_mod_paths(g_mod_path_count + 1)
        cell_store(g_mod_path_names, g_mod_path_count * 8, mod_ni)
        g_mod_path_count = g_mod_path_count + 1
        // `mod path` ends at a line boundary. `mod path:` with a region skips the
        // whole region body.
        if tok_k(cur_tok()) == T_COLON_BLOCK:
            advance_tok()
            skip_newlines()
        else:
            end_decl()
        if tok_k(cur_tok()) == T_INDENT:
            push_scope()
            depth : ., mut = 1
            advance_tok()
            loop:
                if depth <= 0:
                    break
                tk := tok_k(cur_tok())
                if tk == T_EOF:
                    break
                if tk == T_DEDENT:
                    depth = depth - 1
                else if tk == T_INDENT:
                    depth = depth + 1
                advance_tok()
        return

    // import/fileid declarations are already skipped in parse_all() loop.
    // If we reach here, the token was NOT T_IMPORT/T_FILEID.

    // New syntax global variable declaration
    if check(T_IDENT) && is_new_var_decl():
        node := parse_new_var_decl()
        grow_global_lets(g_global_let_count + 1)
        cell_store(g_global_lets, g_global_let_count * 8, node)
        g_global_let_count = g_global_let_count + 1
        // Drain batch extras to globals
        _drained : ., mut = 0
        loop:
            if g_extra_let_count <= 0:
                break
            g_extra_let_count = g_extra_let_count - 1
            grow_global_lets(g_global_let_count + 1)
            cell_store(g_global_lets, g_global_let_count * 8, cell_load(g_extra_lets, g_extra_let_count * 8))
            g_global_let_count = g_global_let_count + 1
            _drained = _drained + 1
        end_decl()   // v4：全局声明以行边界收尾（原可选 `;` 退场）
        return

    // A '#' outside the function signature/body position is rejected. The old
    // top-level fallback consumed tokens without a diagnostic, so misplaced spec
    // annotations disappeared and compilation continued. The only valid position is
    // between a function signature and its body; see parse_spec_annotations.
    if check(T_HASH):
        check_error(EC_V_BAD_TAG,
            "'#' annotation is only allowed between the function signature and its body",
            tok_ln(cur_tok()), tok_cl(cur_tok()))
        advance_tok()   // consume '#' so parse_all makes progress
        return
    // The top-level fallback reports an unexpected token instead of consuming it
    // silently. A typo such as `stuct`, an extra '}', or a stray token is diagnosed
    // with its position, and the following declarations keep their own errors. EOF
    // is not reported because parse_all checks it first. One token is always
    // consumed for error recovery.
    if tok_k(cur_tok()) != T_EOF:
        check_error(EC_P_TOPLEVEL_TOKEN,
            "unexpected top-level token '" + tok_lx(cur_tok()) + "'",
            tok_ln(cur_tok()), tok_cl(cur_tok()))
        advance_tok()

fn parse_all():
    g_ast_count = 0
    g_token_pos = 0
    g_global_let_count = 0
    g_global_lets_cap = 0
    g_func_count = 0
    g_struct_count = 0
    g_enum_count = 0
    g_type_alias_count = 0
    g_type_alias_cap = 0
    g_method_count = 0
    g_method_cap = 0
    g_loop_depth = 0
    g_loop_stack_cap = 0
    g_extra_let_count = 0
    g_block_stmt_count = 0
    // Do not clear g_error_count. The tokenizer already accumulated errors such as
    // integer literal overflow, and run_frontend checks the count after parse_all.
    // Clearing it here would hide those errors. Parse errors append to the same
    // count.
    g_mod_path_count = 0
    g_mod_path_cap = 0
    g_iface_count = 0
    g_iface_cap = 0
    g_impl_for_count = 0
    g_impl_for_cap = 0
    g_generic_constr_count = 0
    g_generic_constr_cap = 0
    g_gen_param_count = 0
    g_gen_param_cap = 0

    g_want_value = 0
    ci : ., mut = 0
    loop:
        // Top-level line boundaries: NEWLINE is a no-op. A DEDENT at top level means
        // broken indentation; the lexer already reported it, and this adds a second
        // positioned signal. This skip must run after every import, because imports
        // end at a line boundary. It is also the loop head for the import loop;
        // without it, a NEWLINE after an import would reach the top-level fallback
        // and produce a false P25.
        loop:
            skip_newlines()
            tk := tok_k(cur_tok())
            if tk == T_EOF:
                return
            if tk == T_DEDENT:
                check_error(EC_P_TOPLEVEL, "unexpected dedent at top level",
                    tok_ln(cur_tok()), tok_cl(cur_tok()))
                advance_tok()
                continue
            if tk != T_IMPORT && tk != T_FILEID:
                break
            is_fileid := tk == T_FILEID
            advance_tok()
            // Consume the whole import statement. The old code consumed only the
            // `import` keyword, leaving the path and alias tokens to the top-level
            // fallback and making every valid import look like an unexpected token.
            // The shape matches module.cr res_imports:
            // [@proj] [a(::b)*] [: alias] [;].
            // Do not widen this to "consume until semicolon" or "consume any
            // identifier": that would also consume the next declaration.
            if check(T_AT):
                advance_tok()
                if check(T_IDENT):
                    advance_tok()
            if check(T_IDENT):
                advance_tok()
                loop:
                    if check(T_PATHSEP):
                        advance_tok()
                        if check(T_IDENT):
                            advance_tok()
                        continue
                    break
            if check(T_COLON_DECL):
                advance_tok()
                if check(T_IDENT):
                    advance_tok()
            if is_fileid && check(T_INT):
                advance_tok()
            // Import and fileid declarations end at a line boundary. An optional
            // trailing semicolon is still accepted.
        t_cur := cur_tok()
        t_kind := tok_k(t_cur)
        if t_kind == T_EOF:
            break
        if ci > 5:
            ci = 0
        parse_declaration()
        if tok_k(cur_tok()) == T_EOF:
            break
        ci = ci + 1
    // Parse interpolation hole expressions after the token stream is no longer
    // needed. Re-tokenizing is safe here; see interp_parse_holes.
    interp_parse_holes()
