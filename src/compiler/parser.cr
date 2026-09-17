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
    // 表示层概念（2026-09-10 语言面收窄裁决 §1）：`[T; N]` 的类型构造器身份已退役——
    // 语义归处 = product（N 元聚合）/ 序列接口 + 长度 where（N 长序列）/ F11 图（长度事实，
    // 可表达依赖长度）。本语法保留为「内联容量存储」表示提示（映射参数层，与 hw-map 同层；
    // 随实例选择生效或退化，非经典范式映射可忽略）。见
    // docs/superpowers/specs/2026-09-10-language-surface-narrowing-design.md §1
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
    } else if tok_k(t) == T_STAR {
        advance_tok();
        inner := parse_type();
        res = alloc_node(EXPR_PTRTYPE, inner, 0, 0, 0, 0, 0, line, col);
    } else if tok_k(t) == T_UNIT {
        advance_tok();
        res = alloc_node(0, 0, 0, 0, 0, TY_UNIT, 0, line, col);
    } else if tok_k(t) == T_IDENT || tok_k(t) == T_SELF || tok_k(t) == T_UNDERSCORE {
        lex := tok_lx(t);
        advance_tok();
        if lex == "int" { res = alloc_node(0, 0, 0, 0, 0, TY_INT, 0, line, col); }
        // dex = 精确小数（float 类型名已移除——数值迁移 Task 5）
        else if lex == "dex" { res = alloc_node(0, 0, 0, 0, 0, TY_DEX, 0, line, col); }
        else if lex == "bool" { res = alloc_node(0, 0, 0, 0, 0, TY_BOOL, 0, line, col); }
        else if lex == "string" { res = alloc_node(0, 0, 0, 0, 0, TY_STRING, 0, line, col); }
        else if lex == "char" { res = alloc_node(0, 0, 0, 0, 0, TY_CHAR, 0, line, col); }
        else if lex == "never" { res = alloc_node(0, 0, 0, 0, 0, TY_NEVER, 0, line, col); }
        else if lex == "dyn" { res = alloc_node(0, 0, 0, 0, 0, TI_DYN, 0, line, col); }
        else {
            ni := str_intern(lex);
            // Check for generic args: Box[int,...] or Box<int,...>
            close_tok : ., mut = 0;
            if check(T_LBRACKET) { close_tok = T_RBRACKET; }
            else if check(T_LT) { close_tok = T_GT; }
            if close_tok > 0 {
                advance_tok();
                first_arg := parse_type();
                arg_count : ., mut = 1;
                loop {
                    if check(close_tok) { break; }
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
        w64(g_diags, g_diag_count * DIAG_REC_SIZE, EC_P_EXPECTED);
        store_str_ptr(g_diags, g_diag_count * DIAG_REC_SIZE + 8, "expected type after '->', got '{' — missing return type?");
        w64(g_diags, g_diag_count * DIAG_REC_SIZE + 16, line);
        w64(g_diags, g_diag_count * DIAG_REC_SIZE + 24, col);
        w64(g_diags, g_diag_count * DIAG_REC_SIZE + 32, diag_fileid_for_line(line));
        g_diag_count = g_diag_count + 1;
        res = alloc_node(0, 0, 0, 0, 0, TY_UNIT, 0, line, col);
    } else {
        grow_diags(g_diag_count + 1);
        w64(g_diags, g_diag_count * DIAG_REC_SIZE, EC_P_EXPECTED);
        store_str_ptr(g_diags, g_diag_count * DIAG_REC_SIZE + 8, "expected type after '->'");
        w64(g_diags, g_diag_count * DIAG_REC_SIZE + 16, line);
        w64(g_diags, g_diag_count * DIAG_REC_SIZE + 24, col);
        w64(g_diags, g_diag_count * DIAG_REC_SIZE + 32, diag_fileid_for_line(line));
        g_diag_count = g_diag_count + 1;
        res = alloc_node(0, 0, 0, 0, 0, TY_UNIT, 0, line, col);
    }
    // R2 P3 Task 4：`T?` 的目标形态 = **EXPR_OPTIONAL**（内层类型节点入 a 槽）。
    // 旧形态（T? → EXPR_GENERIC_APPLY(Option, T)）要求「内建 Option 名」在符号表里被注册，
    // 正是本任务退役的做法（spec §5.4）；且旧形态无法表达 `T? = T ∪ null`（GenericApply 行
    // 在桥接侧是不展开的 AK_NAMED 原子）。新形态**零名字依赖**（不再 str_intern("Option")，
    // 见 test_optional.py 的行数对照用例）。
    if check(T_QUESTION) {
        advance_tok();
        res = alloc_node(EXPR_OPTIONAL, res, 0, 0, 0, 0, 0, line, col);
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
    // If the left expression is a block-ending construct (IF, BLOCK, etc.),
    // don't allow binary operators to extend past it. The next operator
    // belongs to a new expression, not the current one.
    // This prevents `if ... { } *p = 99` from parsing `*` as multiplication.
    lk := ast_kind(left);
    if lk == EXPR_IF || lk == EXPR_BLOCK || lk == EXPR_LOOP || lk == EXPR_WHILE || lk == EXPR_FOR {
        return left;
    }
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
    // Handle cast<T>(expr) syntax — same as expr as T
    if ast_kind(node) == EXPR_IDENT {
        ni := ast_int_val(node);
        if str_eq(istr_get(ni), "cast") != 0 && tok_k(cur_tok()) == T_LT {
            advance_tok();
            typ := parse_type();
            advance_tok();  // skip T_GT
            if tok_k(cur_tok()) == T_LPAREN {
                advance_tok();
                inner := parse_expr(0);
                advance_tok();  // skip T_RPAREN
                return alloc_node(EXPR_AS, inner, typ, 0, 0, 0, 0, tok_ln(node), tok_cl(node));
            }
        }
    }
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
                call_func := node;
                call_flags : ., mut = 0;
                // @inline(fn)(args) is a hinted call, not a call through the
                // value returned by @inline(fn).
                if ast_kind(node) == EXPR_CALL && ast_c(node) == 1 {
                    wrapper := ast_a(node);
                    wrapper_arg := ast_b(node);
                    if ast_kind(wrapper) == EXPR_AT && wrapper_arg >= 0 {
                        wrapper_name := istr_get(ast_a(wrapper));
                        if str_eq(wrapper_name, "inline") != 0 {
                            call_func = ast_a(wrapper_arg);
                            call_flags = CALL_FLAG_INLINE;
                        }
                    }
                }
                node = alloc_node(EXPR_CALL, call_func, af, ac, 0, call_flags, 0, tok_ln(t), tok_cl(t));
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
    if tok_k(t) == T_INT {
        advance_tok();
        return alloc_node(EXPR_INT, 0, 0, 0, tok_iv(t), TY_INT, 0, tok_ln(t), tok_cl(t));
    }
    if tok_k(t) == T_DEX {
        advance_tok();
        // 节点字段（数值迁移 Task 4）：a = binary64 位模式（apx 快路径字面量表示，
        // 由 lexer 存入 token 的 lexeme 槽的数字串还原）；int_val = 定点缩放整数
        // （精确表示，默认路径）。宽度后缀退役（2026-09-10 语言面收窄 §2）：data 槽
        // 不再承载宽度标注，恒 0。
        bits : int = 0;
        tl := r64(g_tokens, t * ESZ_TOKEN + OFF_TK_LEXEME);   // 词素串下标（-1 = 无）
        if tl >= 0 { bits = str_to_f64_bits(istr_get(tl)); }
        return alloc_node(EXPR_DEX, bits, 0, 0, tok_iv(t), TY_DEX, 0, tok_ln(t), tok_cl(t));
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
            // Parse Some(expr[, expr…]) —— R2 P3 Task 4 修复：**实参须照通用枚举构造器分支
            // （下方 parse_postfix 的路径）建 EXPR_ARG 链**。旧实现把值节点直接放 b 槽，
            // 而 checker/ir_gen 的 EXPR_ENUM_CONSTRUCTOR 消费点按 EXPR_ARG 链走
            // （`an := ast_b(node); ast_a(an); an = ast_b(an)`）⇒ 旧形态令该链读进值节点自身
            // 的 a/b 槽（节点 0 当实参、按 ast_b 前行）——实测（本任务开工前）：
            // `enum Option[T] { None, Some(T) }` + `x: int? = Some(5)` **checker 死循环**
            // （`corec check` rc=124 超时）。链一修，消费点契约恢复（parser.cr:300-312 同款）。
            advance_tok();
            af : ., mut = -1;
            ac : ., mut = 0;
            if !check(T_RPAREN) {
                first_expr := parse_expr();
                af = alloc_node(EXPR_ARG, first_expr, -1, 0, 0, 0, 0, tok_ln(t), tok_cl(t));
                ac = 1;
                prev_arg : ., mut = af;
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
            advance_tok();  // consume )
            return alloc_node(EXPR_ENUM_CONSTRUCTOR, ni, af, ac, 0, 0, 0, tok_ln(t), tok_cl(t));
        }
        // Some without parens → treat as identifier (will be resolved by uppercase → enum constructor)
        return alloc_node(EXPR_IDENT, 0, 0, 0, ni, 0, 0, tok_ln(t), tok_cl(t));
    }
    if tok_k(t) == T_AT {
        advance_tok();
        if tok_k(cur_tok()) == T_IDENT {
            name_ni := str_intern(tok_lx(cur_tok()));
            advance_tok();
            // args_node = -1 means no args; parse_postfix will handle (args) as EXPR_CALL
            return alloc_node(EXPR_AT, name_ni, -1, 0, 0, 0, 0, tok_ln(t), tok_cl(t));
        }
        add_error("expected identifier after @");
        return alloc_node(0, 0, 0, 0, 0, TY_UNIT, 0, tok_ln(t), tok_cl(t));
    }
    if tok_k(t) == T_IDENT || tok_k(t) == T_SELF || tok_k(t) == T_UNDERSCORE {
        advance_tok();
        name := tok_lx(t);
        ni := str_intern(name);
        if check(T_LBRACE) && g_parse_no_struct_literal == 0 {
            advance_tok();
            // 契约（F5 修复，与元组分支同款）：EXPR_STRUCT = a=类型名 idx、b=首 wrapper、c=字段数；
            // wrapper 在 g_ast 中**连续**（kind=EXPR_NONE，wrapper.a=该字段的值节点）→ 消费者
            // 经 EXPR_NONE 前向解引用取值。字段值节点自身对复合表达式（调用 / 字面量 / 嵌套聚合）
            // **不连续**（子树自占多槽），故必须分两趟：先解析全部字段值，再统建连续 wrapper。
            // 旧写法「逐值后随建 wrapper」交错分配：复合值子树夹在相邻 wrapper 之间 ⇒ 第 2 个
            // 起字段槽位整体错位，读到子节点（实测 P{a:11, b:g()} 的 b 静默得 0，rc=0）。
            // TODO #2026-09-11-11 ①：wrapper.b = 字段名 idx（**名字绑定**，-1 = 无名字信息）——旧代码取
            // `fni` 后从未写入 ⇒ 值按声明位序绑定（P{b:11,a:22} 静默得 a=11）。名字随 wrapper
            // 同行（与值并列的平行表，两趟结构不变，仍无交错分配）。
            cap : ., mut = 8;
            vals : string, mut = alloc(cap * 8);
            names : string, mut = alloc(cap * 8);
            fc : ., mut = 0;
            loop {
                // EOF 护栏（TODO #2026-09-10-12 根因面）：本循环只认 `}`，而 advance_tok 在 EOF 是空操作
                // ⇒ 解析失步至 EOF 后自旋，每轮分配 AST 节点直至 OOM（alloc 失败返回 NULL →
                // grow_ast 向 NULL 拷贝 SIGSEGV）。同族 6 处循环统一补 EOF 退出。
                if check(T_RBRACE) || check(T_EOF) { break; }
                ft := advance_tok();
                fni := str_intern(tok_lx(ft));
                advance_tok();
                if fc >= cap {
                    ncap := cap * 2;
                    nv := alloc(ncap * 8);
                    _dyncpy(vals, cap * 8, nv);
                    vals = nv;
                    nn := alloc(ncap * 8);
                    _dyncpy(names, cap * 8, nn);
                    names = nn;
                    cap = ncap;
                }
                w64(vals, fc * 8, parse_expr());  // 字段值（子树自占若干槽）
                w64(names, fc * 8, fni);          // 字段名 idx（① 名字绑定）
                fc = fc + 1;
                if check(T_COMMA) { advance_tok(); }
            }
            advance_tok();
            ff : ., mut = -1;
            fi2 : ., mut = 0;
            loop {
                if fi2 >= fc { break; }
                vn := r64(vals, fi2 * 8);
                ln : ., mut = tok_ln(t);
                cl : ., mut = tok_cl(t);
                if vn >= 0 { ln = ast_line(vn); cl = ast_col(vn); }
                wl := ast_alloc(EXPR_NONE, vn, r64(names, fi2 * 8), 0, 0, 0, 0, ln, cl);
                if fi2 == 0 { ff = wl; }
                fi2 = fi2 + 1;
            }
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
            // 契约（F5 修复）：EXPR_TUPLE = a=首 wrapper、b=元素个数；wrapper 在 g_ast 中
            // **连续**，每个 wrapper（kind=EXPR_NONE）的 a = 该元素的值节点 → 消费者经
            // `ast_a(wrapper + i)` 取元素值节点。元素值节点本身对复合表达式**不连续**
            // （复合元素子树自占多槽），故必须分两趟：先解析全部元素值，再统建连续 wrapper。
            // 注：不得照 struct 字面量分支（本文件 T_IDENT+T_LBRACE 段）的「逐值后随建
            // wrapper」交错顺序——复合值会插在相邻 wrapper 之间致其不连续，同属本根因。
            cap : ., mut = 8;
            vals : string, mut = alloc(cap * 8);
            w64(vals, 0, e);
            ec : ., mut = 1;
            loop {
                advance_tok();  // consume comma
                if ec >= cap {
                    ncap := cap * 2;
                    nv := alloc(ncap * 8);
                    _dyncpy(vals, cap * 8, nv);
                    vals = nv;
                    cap = ncap;
                }
                w64(vals, ec * 8, parse_expr());  // 元素值（子树自占若干槽）
                ec = ec + 1;
                if !check(T_COMMA) { break; }
            }
            advance_tok();  // consume )
            ef : ., mut = -1;
            ei : ., mut = 0;
            loop {
                if ei >= ec { break; }
                vn := r64(vals, ei * 8);
                ln : ., mut = tok_ln(t);
                cl : ., mut = tok_cl(t);
                if vn >= 0 { ln = ast_line(vn); cl = ast_col(vn); }
                wl := ast_alloc(EXPR_NONE, vn, 0, 0, 0, 0, 0, ln, cl);
                if ei == 0 { ef = wl; }
                ei = ei + 1;
            }
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
        // 契约（F5 修复，与元组/struct 字面量分支同款）：**字面量形** EXPR_ARRAY =
        // a=首 wrapper、b=元素个数；wrapper 在 g_ast 中**连续**（kind=EXPR_NONE，wrapper.a=元素值
        // 节点）→ 消费者经 EXPR_NONE 前向解引用取值。元素值节点自身对复合表达式（嵌套字面量 /
        // 调用 / 下标）**不连续**（子树自占多槽），故必须两趟：先解析全部元素值，再统建 wrapper。
        // 旧交错写法下第 2 个元素起槽位整体错位（实测 [[1,2],[3,4]] 的 a[1] 被读成扁平 3 →
        // a[1][0] SIGSEGV 139；且 [[1,2],[3,4]] 与 [5,6] 类型互赋静默通过 = soundness 漏放）。
        // 区分：**类型形** [T; N] / [T] 由 parse_type 产出（a=内层类型节点、b=0、int_val=尺寸），
        // 不经本分支，不受本契约影响。
        cap : ., mut = 8;
        vals : string, mut = alloc(cap * 8);
        ec : ., mut = 0;
        if !check(T_RBRACKET) {
            w64(vals, 0, parse_expr());  // 元素值（子树自占若干槽）
            ec = 1;
            if check(T_SEMI) {
                // Repeat array: [value; count] —— 值节点只解析一次，其后仅**共享**同一值节点
                // 追加 wrapper（旧写法浅拷贝根节点 N-1 份；共享值节点语义等价，且不再复制多槽子树）。
                advance_tok();
                ct := advance_tok();
                cnt : ., mut = tok_iv(ct);
                if cnt > cap {
                    nv := alloc(cnt * 8);
                    _dyncpy(vals, cap * 8, nv);
                    vals = nv;
                    cap = cnt;
                }
                ri : ., mut = 1;
                loop {
                    if ri >= cnt { break; }
                    w64(vals, ri * 8, r64(vals, 0));
                    ri = ri + 1;
                }
                ec = cnt;
            } else {
                loop {
                    if !check(T_COMMA) { break; }
                    advance_tok();
                    if ec >= cap {
                        ncap := cap * 2;
                        nv := alloc(ncap * 8);
                        _dyncpy(vals, cap * 8, nv);
                        vals = nv;
                        cap = ncap;
                    }
                    w64(vals, ec * 8, parse_expr());  // 元素值（子树自占若干槽）
                    ec = ec + 1;
                }
            }
        }
        advance_tok();
        ef : ., mut = -1;
        ei2 : ., mut = 0;
        loop {
            if ei2 >= ec { break; }
            vn := r64(vals, ei2 * 8);
            ln : ., mut = tok_ln(t);
            cl : ., mut = tok_cl(t);
            if vn >= 0 { ln = ast_line(vn); cl = ast_col(vn); }
            wl := ast_alloc(EXPR_NONE, vn, 0, 0, 0, 0, 0, ln, cl);
            if ei2 == 0 { ef = wl; }
            ei2 = ei2 + 1;
        }
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
        st := parse_stmt();
        if sc >= local_stmts_cap {
            new_cap := local_stmts_cap * 2;
            new_stmts := alloc(new_cap * 8);
            _dyncpy(local_stmts, local_stmts_cap * 8, new_stmts);
            local_stmts = new_stmts;
            local_stmts_cap = new_cap;
        }
        w64(local_stmts, sc * 8, st);
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
    is_mut : ., mut = 0;   is_pub : ., mut = 0;   is_apx : ., mut = 0;

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
                else if tag == "apx" { is_apx = 1; }
                else {
                    tni := str_intern(tag);
                    ei := find_plugin_entry(g_plugin_tags, g_plugin_tag_count, tni, -1);
                    if ei >= 0 {
                        pd := r64(g_plugin_tags, ei*24+16);
                        if pd != 0 { is_mut = 1; }
                    } else {
                        // 未知标签：TA08（已知标签 = mut/pub/apx + 插件注册标签）
                        grow_diags(g_diag_count + 1);
                        w64(g_diags, g_diag_count * DIAG_REC_SIZE, EC_TA_UNKNOWN_TAG);
                        store_str_ptr(g_diags, g_diag_count * DIAG_REC_SIZE + 8, "unknown declaration tag '" + tag + "'");
                        w64(g_diags, g_diag_count * DIAG_REC_SIZE + 16, tok_ln(tag_t));
                        w64(g_diags, g_diag_count * DIAG_REC_SIZE + 24, tok_cl(tag_t));
                        w64(g_diags, g_diag_count * DIAG_REC_SIZE + 32, diag_fileid_for_line(tok_ln(tag_t)));
                        g_diag_count = g_diag_count + 1;
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
        node := alloc_node(EXPR_LET, ni, typ, nv, is_apx, 0, is_mut, tok_ln(t), tok_cl(t));
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

// 跳过整段嵌套函数声明（P021 已报错，仅错误恢复路径）：`fn name(params) -> T {body}`
// 按花括号配平跳过整段；`= expr;` 形式（含 extern 无体形式）遇分号收尾。起始 token 可为
// `pub`。花括号配平从函数体的 `{` 起算（depth 0→1），体内嵌套块/struct 字面量的花括号
// 成对计入，不会在 depth 归零前误判结束。
fn skip_nested_fn() {
    depth : ., mut = 0;
    seen_brace : ., mut = 0;
    loop {
        k := tok_k(cur_tok());
        if k == T_EOF { return; }
        if k == T_LBRACE { depth = depth + 1; seen_brace = 1; advance_tok(); continue; }
        if k == T_RBRACE {
            advance_tok();
            depth = depth - 1;
            if depth <= 0 { return; }
            continue;
        }
        if k == T_SEMI && seen_brace == 0 { advance_tok(); return; }
        advance_tok();
    }
}

fn parse_stmt() -> int {
    // Drain batch extras from previous call
    if g_extra_let_count > 0 {
        g_extra_let_count = g_extra_let_count - 1;
        return r64(g_extra_lets, g_extra_let_count * 8);
    }

    t := cur_tok();
    // 嵌套 `fn`/`flow` 声明不属语言面——grammar/core.ebnf 的 Statement 不含 FunctionDecl
    // （函数声明仅顶层 TopLevelDecl），bootstrap 参考实现亦以 positioned error 拒绝。
    // 修复前此处落回 parse_primary 的「Unexpected token in expression」通用兜底：只消费
    // `fn` 一个 token，解析失步后 `IDENT {` 进入 struct 字面量循环并把外层 `}` 当字段吃掉，
    // 至 EOF 后因该循环只认 `}` 且 advance_tok 在 EOF 是空操作而自旋——每轮分配 AST 节点，
    // 直到 bump allocator 耗尽返回 NULL、grow_ast 向 NULL 拷贝（rc=139 SIGSEGV，TODO #2026-09-10-12）。
    // 现显式报 P021 并整段跳过该声明：错误定位到声明处，且后续语句恢复正常解析。
    if tok_k(t) == T_FN || tok_k(t) == T_FLOW
       || (tok_k(t) == T_PUB && (tok_k(t + 1) == T_FN || tok_k(t + 1) == T_FLOW)) {
        fnt : ., mut = t;
        if tok_k(fnt) == T_PUB { fnt = fnt + 1; }
        msg : ., mut = "Nested function declaration is not supported; declare it at top level";
        if tok_k(fnt + 1) == T_IDENT {
            msg = "Nested function declaration '" + tok_lx(fnt + 1) + "' is not supported; declare it at top level";
        }
        check_error(EC_P_NESTED_FN, msg, tok_ln(fnt), tok_cl(fnt));
        skip_nested_fn();
        return 0;
    }
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
        val : ., mut = -1;
        if !check(T_SEMI) && !check(T_RBRACE) { val = parse_expr(); }
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
    if tok_k(t) == T_INT {
        advance_tok();
        return alloc_node(EXPR_INT, 0, 0, 0, tok_iv(t), TY_INT, 0, tok_ln(t), tok_cl(t));
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
            // 契约（F5 修复，与 struct 字面量分支同款）：EXPR_STRUCTPAT = a=名字 idx、b=首 wrapper、
            // c=字段数；wrapper 在 g_ast 中**连续**（kind=EXPR_NONE，wrapper.a=子模式节点）。
            // 复合子模式（嵌套 struct/enum/tuple 模式）子树占多槽，故两趟：先全部解析、后统建 wrapper。
            advance_tok();
            cap : ., mut = 8;
            vals : string, mut = alloc(cap * 8);
            fc : ., mut = 0;
            loop {
                if check(T_RBRACE) || check(T_EOF) { break; }
                ft := advance_tok();
                fni := str_intern(tok_lx(ft));
                advance_tok(); // =
                if fc >= cap {
                    ncap := cap * 2;
                    nv := alloc(ncap * 8);
                    _dyncpy(vals, cap * 8, nv);
                    vals = nv;
                    cap = ncap;
                }
                w64(vals, fc * 8, parse_pattern());
                fc = fc + 1;
                if check(T_COMMA) { advance_tok(); }
            }
            advance_tok();
            ff : ., mut = -1;
            fi2 : ., mut = 0;
            loop {
                if fi2 >= fc { break; }
                vn := r64(vals, fi2 * 8);
                ln : ., mut = tok_ln(t);
                cl : ., mut = tok_cl(t);
                if vn >= 0 { ln = ast_line(vn); cl = ast_col(vn); }
                wl := ast_alloc(EXPR_NONE, vn, 0, 0, 0, 0, 0, ln, cl);
                if fi2 == 0 { ff = wl; }
                fi2 = fi2 + 1;
            }
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
    open_tok : ., mut = 0;
    close_tok : ., mut = 0;
    if check(T_LBRACKET) { open_tok = T_LBRACKET; close_tok = T_RBRACKET; }
    else if check(T_LT) { open_tok = T_LT; close_tok = T_GT; }
    if open_tok > 0 {
        advance_tok(); // [ or <
        gc : ., mut = 0;
        loop {
            if check(close_tok) { break; }
            if gc >= MAX_GENERICS { break; }
            advance_tok();
            gc = gc + 1;
            if !check(T_COMMA) { break; }
            advance_tok();
        }
        advance_tok(); // ] or >
        return gc;
    }
    return 0;
}

fn parse_generics_into(names: string, constrs: string) -> int {
    // Initialize constraints to -1 (no constraint)
    ci : ., mut = 0;
    loop { if ci >= 4 { break; } w64(constrs, ci * 8, -1); ci = ci + 1; }
    open_tok : ., mut = 0;
    close_tok : ., mut = 0;
    if check(T_LBRACKET) { open_tok = T_LBRACKET; close_tok = T_RBRACKET; }
    else if check(T_LT) { open_tok = T_LT; close_tok = T_GT; }
    if open_tok > 0 {
        advance_tok(); // [ or <
        gc : ., mut = 0;
        loop {
            if check(close_tok) { break; }
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
        advance_tok(); // ] or >
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

// ─── R2 P3 Task 5（Step 2）：结构/枚举泛型约束登记（**索引空间分家** —— 键 = row*MAX_GENERICS+gi，
// 与函数侧 g_generic_constr 不同缓冲；见 globals.cr 表注）───
// **空槽预填 -1**（本批实测缺陷修复）：表是**稀疏**填的（只写有约束的槽），而缓冲零初值 ⇒
// 高水位区内的「本行未写过的槽」读出 0——0 是**合法的名字 ni**（首个驻留串）⇒ 读取方
// `c_ni >= 0` 会把空槽当有效约束名（把首个驻留串当接口/类型名查表）＝ 凭空约束。
// 故本三函数一律先整行（MAX_GENERICS 槽）写 -1 再覆盖有约束的槽——行的语义 = 「本行全部
// 形参位都有明确值」。读取器的越界闸（idx ≥ count）仍保留（整行未登记时的兜底）。
fn save_struct_gen_constrs(si: int, constrs: string, count: int) {
    grow_sgen_constr(si * MAX_GENERICS + MAX_GENERICS);
    if si * MAX_GENERICS + MAX_GENERICS > g_sgen_constr_count { g_sgen_constr_count = si * MAX_GENERICS + MAX_GENERICS; }
    zi : ., mut = 0;
    loop {
        if zi >= MAX_GENERICS { break; }
        w64(g_sgen_constr, (si * MAX_GENERICS + zi) * 8, -1);
        zi = zi + 1;
    }
    gi : ., mut = 0;
    loop {
        if gi >= count { break; }
        if gi >= MAX_GENERICS { break; }
        if r64(constrs, gi * 8) >= 0 {
            w64(g_sgen_constr, (si * MAX_GENERICS + gi) * 8, r64(constrs, gi * 8));
        }
        gi = gi + 1;
    }
}

fn save_enum_gen_constrs(ei: int, constrs: string, count: int) {
    grow_egen_constr(ei * MAX_GENERICS + MAX_GENERICS);
    if ei * MAX_GENERICS + MAX_GENERICS > g_egen_constr_count { g_egen_constr_count = ei * MAX_GENERICS + MAX_GENERICS; }
    zi : ., mut = 0;
    loop {
        if zi >= MAX_GENERICS { break; }
        w64(g_egen_constr, (ei * MAX_GENERICS + zi) * 8, -1);
        zi = zi + 1;
    }
    gi : ., mut = 0;
    loop {
        if gi >= count { break; }
        if gi >= MAX_GENERICS { break; }
        if r64(constrs, gi * 8) >= 0 {
            w64(g_egen_constr, (ei * MAX_GENERICS + gi) * 8, r64(constrs, gi * 8));
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
    // 容量批 T3：字段区基址 = 侧表高水位（字段写入点按 base + 下标寻址；体尾 si_commit_fields 提交）
    si_set_field_base(idx, g_si_f_used);
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
    // 容量批 T3：变体区基址 = 侧表高水位（体尾 ei_commit_variants 提交）
    ei_set_variant_base(idx, g_ei_v_used);
    g_enum_count = idx + 1;
    return idx;
}

fn extract_hotpatch_ver(args_node: int) -> int {
    if args_node < 0 { return -1; }
    arg := args_node;
    loop {
        if arg < 0 { break; }
        expr := ast_a(arg);
        k := ast_kind(expr);
        if k == EXPR_ASSIGN {
            name_ni := ast_a(expr);
            name := istr_get(name_ni);
            val_node := ast_b(expr);
            if str_eq(name, "ver") != 0 {
                return ast_int_val(val_node);
            }
        }
        arg = ast_b(arg);
    }
    return -1;
}

fn parse_body(fn_name: string, fn_ni: int, fn_line: int, fn_col: int, hotpatch_ver: int) {
    gnames : string, mut;    gnames_cap : int, mut;
    gnames = alloc(64 * 8); gnames_cap = 64;
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

    // 批 6（T2，裁-S2）：规约标注链——**签名之后、body 之前**（spec-design §四）。
    // T3：记录起点，`alloc_node(EXPR_FN, …)` 之后把本函数的标注行回填为 **fn_node 索引**
    //（唯一键——按函数名会串台：同名方法/多 impl）。
    spec_start := g_spec_count;
    parse_spec_annotations(fn_ni);

    body : ., mut = -1;
    if check(T_LBRACE) {
        body = parse_block();
    } else {
        advance_tok(); // =
        body = parse_expr();
        advance_tok(); // ;
    }
    fn_node := alloc_node(EXPR_FN, fn_ni, pf, pc, rtv + hotpatch_ver * 256, rt, body, fn_line, fn_col);
    // T3：标注行回填 fn_node（本函数新增的行 = [spec_start, g_spec_count)）
    spec_patch : ., mut = spec_start;
    loop { if spec_patch >= g_spec_count { break; } spec_set_fnode(spec_patch, fn_node); spec_patch = spec_patch + 1; }
    // 形参上限硬错（防御面，TODO #2026-09-10-4）：FuncInfo.param_types 是定长内嵌槽区
    // （MAX_FN_PARAMS 槽），超限签名无法表示 ⇒ 拒绝编译（rc=1）而非截断/越界写。
    // 形参表容纳不下时**必须**在这条路径上停住：静默越界写曾踩 ast_node 致
    // name_idx/param_count 归零 + TF01 误归 + rc=0 产物崩。
    if pc > MAX_FN_PARAMS {
        check_error(EC_P_TOO_MANY_PARAMS,
            "Function has too many parameters (" + int_str(pc) + " > " + int_str(MAX_FN_PARAMS) + ")",
            fn_line, fn_col);
    }
    fi := add_func(fn_name, pc, rtv, fn_node);
    if fi >= 0 && gc > 0 { save_func_generics(fi, gnames, gc); save_func_gen_constrs(fi, gconstrs, gc); }
    // Store param types in FuncInfo（pc > MAX_FN_PARAMS 已被上方硬错拒绝；
    // 此处再显式跳过 + fi_set_param_type 内槽区护栏 = 双保险，未来新调用点亦不越过界）
    if fi >= 0 && pc <= MAX_FN_PARAMS { pstore_i : ., mut = 0; pstore_n : ., mut = pf;
        loop { if pstore_i >= pc { break; } if pstore_n < 0 { break; }
            if ast_kind(pstore_n) == EXPR_PARAM {
                fi_set_param_type(fi, pstore_i, ast_type_val(pstore_n));
                pstore_i = pstore_i + 1; }
            pstore_n = pstore_n + 1; } }
}

// 批 6（T2，裁-S1/S2）：规约标注链 `#check(expr)` / `#ensure(expr)` —— **签名与 body 之间**。
// 位置真源 = docs/maintainer/design/spec-design.md §四（`fn f(...) -> T` 之后、body 之前）。
//
// **`check`/`ensure` 不是关键字**（裁-S1，判据性证据）：本仓已有 `fn check`（parser.cr:30）
// 与 CLI 子命令 `"check"`（main.cr:235）⇒ 若做成关键字，自源当场语法错。故只按**词素**比对，
// `#` 后一律走 `T_IDENT`。
//
// 表达式复用 `parse_expr` ⇒ 节点落 `g_ast`，但**不被 body 引用**（不进 EXPR_FN 的 a/b/c 槽，
// 也不进 `g_block_stmts`）⇒ ir_gen 走不到它 ⇒ **发射面零足迹**（裁-S4：本批不编图）。
// 记录落**侧表**（`spec_add`）供 checker（T3）/dump（T4）消费。
//
// 形态错一律**响亮**（EC_V_*：17xxx 家族，fail-closed 默认阻断 ⇒ rc=1 + 零产物；
// 照「未知字符不得静默」的既有口径）。错误后**不消费残余**、直接返回 ⇒ 由外层继续解析并
// 给出第二重信号（不静默、不猜）。
fn parse_spec_annotations(fn_ni: int) {
    loop {
        if !check(T_HASH) { break; }
        at_line := tok_ln(cur_tok());
        at_col := tok_cl(cur_tok());
        advance_tok();  // '#'
        if tok_k(cur_tok()) != T_IDENT {
            check_error(EC_V_BAD_TAG, "Expected annotation name after '#'", at_line, at_col);
            return;
        }
        an_name := tok_lx(cur_tok());
        kind : ., mut = -1;
        if str_eq(an_name, "check") != 0 { kind = 0; }
        else if str_eq(an_name, "ensure") != 0 { kind = 1; }
        if kind < 0 {
            check_error(EC_V_BAD_TAG,
                "Unknown annotation '#" + an_name + "' (expected '#check' or '#ensure')", at_line, at_col);
            return;
        }
        advance_tok();  // 标注名
        if !check(T_LPAREN) {
            check_error(EC_V_ANN_SYNTAX, "Expected '(' after '#" + an_name + "'", at_line, at_col);
            return;
        }
        advance_tok();  // '('
        expr := parse_expr();
        if !check(T_RPAREN) {
            check_error(EC_V_ANN_SYNTAX,
                "Expected ')' to close '#" + an_name + "' annotation", at_line, at_col);
            return;
        }
        advance_tok();  // ')'
        spec_add(fn_ni, kind, expr, at_line, at_col);
    }
}

fn parse_ffi_annotation() -> int {
    // Current token is T_AT; consume it and parse @ffi("lang")
    advance_tok(); // skip @
    if tok_k(cur_tok()) != T_IDENT { add_error("expected ffi"); return -1; }
    lex := tok_lx(cur_tok());
    if str_eq(lex, "ffi") == 0 { add_error("expected ffi"); return -1; }
    advance_tok();
    // Expect ( "lang_name" )
    if tok_k(cur_tok()) != T_LPAREN { add_error("expected ("); return -1; }
    advance_tok();
    if tok_k(cur_tok()) != T_STRING { add_error("expected string literal for FFI language"); return -1; }
    lang_ni := str_intern(tok_lx(cur_tok()));
    advance_tok();
    if tok_k(cur_tok()) != T_RPAREN { add_error("expected )"); return -1; }
    advance_tok();
    return lang_ni;
}

fn parse_declaration() {
    hotpatch_ver : ., mut = 0;

    // Handle @hotpatch(ver=N) annotation before function declarations
    if check(T_AT) {
        saved_ast := g_ast_count;
        annotation := parse_expr();
        if check(T_FN) || check(T_FLOW) || check(T_PUB) || check(T_EXTERN) {
            k := ast_kind(annotation);
            if k == EXPR_CALL {
                callee := ast_a(annotation);
                if ast_kind(callee) == EXPR_AT {
                    name_ni := ast_a(callee);
                    name := istr_get(name_ni);
                    if str_eq(name, "hotpatch") != 0 {
                        hv := extract_hotpatch_ver(ast_b(annotation));
                        if hv >= 0 { hotpatch_ver = hv; } else { hotpatch_ver = 1; }
                    }
                }
            } else if k == EXPR_AT {
                name_ni := ast_a(annotation);
                name := istr_get(name_ni);
                if str_eq(name, "hotpatch") != 0 {
                    hotpatch_ver = 1;
                }
            }
            g_ast_count = saved_ast;
        }
    }

    ip : ., mut = 0;
    if check(T_PUB) { ip = 1; advance_tok(); }

    // extern fn declaration (FFI)
    if check(T_EXTERN) {
        t := cur_tok();
        advance_tok();
        ffi_lang_ni : ., mut = -1;
        // Check for @ffi("...")
        if check(T_AT) {
            ffi_lang_ni = parse_ffi_annotation();
        }
        // Expect fn keyword
        if tok_k(cur_tok()) != T_FN {
            add_error("expected 'fn' after extern");
            return;
        }
        advance_tok();
        // Parse function name
        nt := advance_tok();
        name := tok_lx(nt);
        fn_name_ni := str_intern(name);
        // Parse param list: (name: type, ...)
        advance_tok(); // (
        first_param : ., mut = -1;
        param_count : ., mut = 0;
        // 批 8（静默面收口 · 条目 3）：C ABI 无可选表示 ⇒ extern 声明的**形参/返回不得为可选**
        // （修复前 checker 对 extern 声明整段早退（`checker.cr` EXPR_EXTERN 分支）⇒ `extern fn e(x: int?)`
        //  check=0/build=0、运行期垃圾值；两条早退路径都不报）。判据 = rc=1 + 定位 + 零产物（P024）；
        // **非可选 extern 不受影响**（判据 ②，守卫档 = test_iface_ops.py / ffi_test.cr / p_ffi2.cr）。
        extern_opt : ., mut = 0;
        if !check(T_RPAREN) {
            loop {
                pt := advance_tok();
                pn := str_intern(tok_lx(pt));
                advance_tok(); // :
                pty := parse_type();
                if pty >= 0 && ast_kind(pty) == EXPR_OPTIONAL { extern_opt = 1; }
                if first_param < 0 { first_param = g_ast_count; }
                alloc_node(EXPR_PARAM, pn, 0, 0, 0, unpack_type(pty), pty, tok_ln(pt), tok_cl(pt));
                param_count = param_count + 1;
                if !check(T_COMMA) { break; }
                advance_tok();
            }
        }
        advance_tok(); // )
        // Parse return type (optional, defaults to unit)
        ret_type : ., mut = TY_UNIT;
        if check(T_ARROW) {
            advance_tok();
            ret_node := parse_type();
            if ret_node >= 0 && ast_kind(ret_node) == EXPR_OPTIONAL { extern_opt = 1; }
            ret_type = unpack_type(ret_node);
        }
        if extern_opt != 0 {
            check_error(EC_P_EXTERN_OPTIONAL, "extern declaration cannot use optional type ('?') - no C ABI representation", tok_ln(t), tok_cl(t));
        }
        // Create EXPR_EXTERN node (no body)
        node : ., mut = alloc_node(EXPR_EXTERN, fn_name_ni, first_param, param_count, 0, ret_type, ffi_lang_ni, tok_ln(t), tok_cl(t));
        // Consume semicolon
        if check(T_SEMI) { advance_tok(); }
        return;
    }

    // fn / flow fn
    if check(T_FN) || check(T_FLOW) {
        is_flow : ., mut = 0;
        // F5c：`flow fn name()` 语法——修复前消费 T_FLOW 后直接 advance_tok()
        // 把 T_FN 当函数名（name="fn"），flow 函数构造不可达（P01 乱报）。
        if check(T_FLOW) {
            is_flow = 1;
            advance_tok();  // 消费 'flow'
            if !check(T_FN) {
                add_error("expected 'fn' after flow");
                return;
            }
        }
        t := advance_tok();
        nt := advance_tok();
        name := tok_lx(nt);
        ni := str_intern(name);
        parse_body(name, ni, tok_ln(t), tok_cl(t), hotpatch_ver);
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
        sg_constrs : string, mut;    sg_constrs_cap : int, mut;
    sg_constrs = alloc(64 * 8); sg_constrs_cap = 64;
        sg_count := parse_generics_into(sg_names, sg_constrs);
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
                // R2 P3 Task 5（Step 2）：约束**不再丢弃**（旧态 = 写进 dummy 缓冲后随作用域
                // 消失 ⇒ `struct Box[T: I]` 静默无约束）。登记到 struct 侧表，实例化点
                // （res_type_node 的 EXPR_GENERIC_APPLY 分支）消费。
                save_struct_gen_constrs(si, sg_constrs, sg_count);
            }
            fc : ., mut = 0;
            loop {
                if check(T_RBRACE) || check(T_EOF) { break; }
                ft := advance_tok();
                fn2 := tok_lx(ft);
                fni := str_intern(fn2);
                // 容量批 T3（裁-CAP-2 (a)）：字段**无硬上限**（侧表；第 17 字段起照常写入）
                // ⇒ 旧 P023 闸与槽上限分支一并删除（不再存在越界写对象）。
                si_set_field_name(si, fc, fni);
                advance_tok();
                fty := parse_type();
                si_set_field_type(si, fc, unpack_type(fty));
                si_set_field_type_node(si, fc, fty);
                fc = fc + 1;
                if check(T_COMMA) { advance_tok(); }
            }
            w64(g_structs, si * ESZ_STRUCTINFO + OFF_SI_FIELD_COUNT, fc);
            si_commit_fields(si, fc);   // 提交字段区（高水位 = base + fc）
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
        eg_constrs : string, mut;    eg_constrs_cap : int, mut;
    eg_constrs = alloc(64 * 8); eg_constrs_cap = 64;
        eg_count := parse_generics_into(eg_names, eg_constrs);
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
                // R2 P3 Task 5（Step 2）：同 struct 分支——枚举泛型约束登记（旧态同款丢弃）
                save_enum_gen_constrs(ei, eg_constrs, eg_count);
            }
            vc : ., mut = 0;
            loop {
                if check(T_RBRACE) || check(T_EOF) { break; }
                vt := advance_tok();
                vname := tok_lx(vt);
                vni := str_intern(vname);
                // 容量批 T3（裁-CAP-2 (a)）：变体**无硬上限**（侧表）⇒ 旧 P022 闸与槽上限
                // 分支一并删除（不再存在越界写对象）
                ei_set_variant_name(ei, vc, vni);
                tc : ., mut = 0;
                if check(T_LPAREN) {
                    advance_tok();
                    loop {
                        if check(T_RPAREN) { break; }
                        fty := parse_type();
                        ei_set_variant_type(ei, vc, tc, unpack_type(fty));
                        // R2 P3 Task 4（T0 交接 ①）：载荷类型**节点**随裸码同写（照 struct 的
                        // OFF_SI_FIELD_TYPE_NODES 先例）——裸码把非基型载荷塌缩成 0 = TY_INT，
                        // 节点是载荷面（泛型形参代入 / 满足判定）的唯一忠实来源。
                        ei_set_variant_type_node(ei, vc, tc, fty);
                        tc = tc + 1;
                        if !check(T_COMMA) { break; }
                        advance_tok();
                    }
                    advance_tok();
                }
                ei_set_variant_type_count(ei, vc, tc);
                vc = vc + 1;
                if check(T_COMMA) { advance_tok(); }
            }
            w64(g_enums, ei * ESZ_ENUMINFO + OFF_EI_VARIANT_COUNT, vc);
            ei_commit_variants(ei, vc);   // 提交变体区（高水位 = base + vc）
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
            if check(T_RBRACE) || check(T_EOF) { break; }
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
                // R2 P3b Task 6（Step 1）：签名**类型节点**槽（与裸码槽并行写，照 struct/enum
                // 的 code+node 双写先例）。self 接收者槽恒无节点（两侧同约定，见 OFF_IFM_SELF_MODE）。
                param_nodes : string, mut;    param_nodes_cap : int, mut;
    param_nodes = alloc(128 * 8); param_nodes_cap = 128;
                pni2 : ., mut = 0;
                loop { if pni2 >= 8 { break; } w64(param_nodes, pni2 * 8, -1); pni2 = pni2 + 1; }
                self_mode : ., mut = 0;
                if !check(T_RPAREN) {
                    loop {
                        fst := cur_tok();
                        // Handle &self / &mut self / self
                        if tok_k(fst) == T_AMPERSAND || tok_k(fst) == T_SELF {
                            self_mode_t : ., mut = 1;                 // self
                            if tok_k(fst) == T_AMPERSAND {
                                advance_tok(); // &
                                self_mode_t = 2;                       // &self
                                if check(T_MUT) { advance_tok(); self_mode_t = 3; } // &mut self
                            }
                            nt2 := advance_tok(); // self
                            if pc < 8 { w64(param_tis, pc * 8, 0); }  // match function's default for &self
                            if pc == 0 { self_mode = self_mode_t; }   // 首参 = 接收者才记模式
                            pc = pc + 1;
                        } else {
                            advance_tok(); // param name
                            advance_tok(); // :
                            ptype := parse_type();
                            if pc < 8 {
                                w64(param_tis, pc * 8, unpack_type(ptype));
                                w64(param_nodes, pc * 8, ptype);
                            }
                            pc = pc + 1;
                        }
                        if !check(T_COMMA) { break; }
                        advance_tok();
                    }
                }
                advance_tok(); // )

                // Parse return type
                ret_ti : ., mut = TY_UNIT;
                ret_node : ., mut = -1;
                if check(T_ARROW) {
                    advance_tok();
                    rn2 := parse_type();
                    ret_node = rn2;
                    ret_ti = unpack_type(rn2);
                }
                advance_tok(); // ;

                // Store method in interface entry (with overflow checks)
                // R2 P3b Task 6（Step 1）：上限**显式登记保留**（单源常量 MAX_IFACE_METHODS）——
                // 超限 = 硬错 rc=1（非静默截断），解除面（侧表迁移）见 dyn_arr.cr 常量注。
                if method_count >= MAX_IFACE_METHODS {
                    grow_diags(g_diag_count + 1);
                    w64(g_diags, g_diag_count * DIAG_REC_SIZE, EC_P_FIELD_SYNTAX);
                    store_str_ptr(g_diags, g_diag_count * DIAG_REC_SIZE + 8, "interface '" + iface_name + "' exceeds max 16 methods");
                    w64(g_diags, g_diag_count * DIAG_REC_SIZE + 16, tok_ln(t)); w64(g_diags, g_diag_count * DIAG_REC_SIZE + 24, tok_cl(t));
                    w64(g_diags, g_diag_count * DIAG_REC_SIZE + 32, diag_fileid_for_line(tok_ln(t)));
                    g_diag_count = g_diag_count + 1;
                } else {
                    mbase := iface_base + OFF_IF_METHODS + method_count * ESZ_IFMETHOD;
                    w64(g_ifaces, mbase + OFF_IFM_NAME, method_ni);
                    w64(g_ifaces, mbase + OFF_IFM_PARAM_COUNT, pc);
                    w64(g_ifaces, mbase + OFF_IFM_RET_TI, ret_ti);
                    w64(g_ifaces, mbase + OFF_IFM_RET_NODE, ret_node);
                    w64(g_ifaces, mbase + OFF_IFM_SELF_MODE, self_mode);
                    pj : ., mut = 0;
                    loop { if pj >= 8 || pj >= pc { break; }
                        w64(g_ifaces, mbase + OFF_IFM_PARAM_TYPES + pj * 8, r64(param_tis, pj * 8));
                        w64(g_ifaces, mbase + OFF_IFM_PARAM_NODES + pj * 8, r64(param_nodes, pj * 8));
                        pj = pj + 1; }
                    if pc > 8 {
                        grow_diags(g_diag_count + 1);
                        w64(g_diags, g_diag_count * DIAG_REC_SIZE, EC_P_PARAM_TYPE);
                        store_str_ptr(g_diags, g_diag_count * DIAG_REC_SIZE + 8, "method '" + istr_get(method_ni) + "' in interface exceeds max 8 params");
                        w64(g_diags, g_diag_count * DIAG_REC_SIZE + 16, tok_ln(t)); w64(g_diags, g_diag_count * DIAG_REC_SIZE + 24, tok_cl(t));
                        w64(g_diags, g_diag_count * DIAG_REC_SIZE + 32, diag_fileid_for_line(tok_ln(t)));
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
            if check(T_RBRACE) || check(T_EOF) { break; }
            if check(T_FN) {
                ft := advance_tok();
                method_nt := advance_tok();
                method_name := tok_lx(method_nt);
                method_ni := str_intern(method_name);
                mangled := type_name + "." + method_name;
                mangled_ni := str_intern(mangled);
                parse_body(mangled, mangled_ni, tok_ln(ft), tok_cl(ft), 0);
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

    // 批 6（T2）：`#` 出现在**非标注位置**（声明之前 / body 之后 / 顶层任意处）⇒ **响亮拒绝**。
    // 本仓的顶层兜底 = 下方 `advance_tok()`（**静默丢弃一个 token、不报错**）——`#` 走它
    // 就会被逐 token 吞净（T2 首轮实测：`#check(1>0) fn f()…` 与 `… } #check(1>0)` 均 rc=0 +
    // 产物照出）。这与 T0 §10.2 的静默误编译**同源**（`#` 被静默丢弃），必须此点转响亮。
    // 合法位置**唯一** = 签名与 body 之间（parse_spec_annotations，spec-design §四）。
    if check(T_HASH) {
        check_error(EC_V_BAD_TAG,
            "'#' annotation is only allowed between the function signature and its body",
            tok_ln(cur_tok()), tok_cl(cur_tok()));
        advance_tok();   // 吞掉 `#` 本身，避免 parse_all 空转；残余由后续解析按既有规则处理
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
    // 注意：不再清零 g_error_count——tokenize 阶段（词法守卫，如整数字面量
    // 溢出）已用 add_error 累积错误；parse_all 清零会把它们一并吞掉，
    // 造成「静默越界/静默环绕」类错误永远不报（run_frontend 在 parse_all
    // 之后才检查 g_error_count）。parse 自身的语法错误继续 add_error 追加。
    g_mod_path_count = 0; g_mod_path_cap = 0;
    g_iface_count = 0; g_iface_cap = 0;
    g_impl_for_count = 0; g_impl_for_cap = 0;
    g_generic_constr_count = 0; g_generic_constr_cap = 0;
    g_gen_param_count = 0; g_gen_param_cap = 0;

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
        parse_declaration();
        if tok_k(cur_tok()) == T_EOF { break; }
        ci = ci + 1;
    }
}
