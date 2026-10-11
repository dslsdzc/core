// Parser: recursive descent with flat AST output

// Global state for parser (shared globals in globals.cr)
g_token_pos : int, mut

// Buffer for batch declaration overflow (a, b : int = 1, 2)
g_extra_lets : string, mut
g_extra_lets_cap : int, mut
g_extra_let_count : int, mut

// v4（T0 布局规格 §4.5）：原 `g_parse_no_struct_literal` 旗标**已删除** —— 块花括号不存在
// ⇒ `IDENT {` 之后**必**是结构体字面量，歧义（靠「深度 1 的 `;`」判块）随之消失。

fn alloc_node(kind: int, a: int, b: int, c: int, iv: int, tv: int, d: int, line: int, col: int) -> int:
    return ast_alloc(kind, a, b, c, iv, tv, d, line, col)

fn cur_tok() -> int:
    return g_token_pos
fn tok_k(p: int) -> int:
    return r64(g_tokens, p * ESZ_TOKEN + OFF_TK_KIND)
fn tok_lx(p: int) -> string:
    return istr_get(r64(g_tokens, p * ESZ_TOKEN + OFF_TK_LEXEME))
fn tok_iv(p: int) -> int:
    return r64(g_tokens, p * ESZ_TOKEN + OFF_TK_INTVAL)
fn tok_ln(p: int) -> int:
    return r64(g_tokens, p * ESZ_TOKEN + OFF_TK_LINE)
fn tok_cl(p: int) -> int:
    return r64(g_tokens, p * ESZ_TOKEN + OFF_TK_COL)

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

// ── v4 位置语义（T5；逐条等价于 bootstrap/corec/frontend/parser.py 的 `want_value`）──────
// 表达式位（声明/赋值右值、return 的值、实参、下标、括号内、元组/数组元素、字面量字段值）
// ⇒ region 末项**保尾值**；语句位（语句、函数体、if/else 语句体、loop/while/for 体）
// ⇒ 末项裸表达式**包 EXPR_STMT**（等价 v3 带 `;` 的表达式语句）；**例外 = 块状末项**
// （if/match/loop/while/for/unsafe）**保尾值** —— v3 的 `;` 只终止普通表达式语句，
// 控制流语句本来就以 `}` 收尾（本来就是块的尾值）。判据 = v3 逐形等价。
g_want_value : int, mut

// 行边界（`;` 退场后的统一终止面，T0 布局规格 §2.5 + §6.2 的 A/B 两类逐点判定）：
// NEWLINE / DEDENT / EOF 三态；其中 **DEDENT 与 EOF 不消费** —— 它们是 region 收尾信号，
// 由块产生式处理。
// 第三态：**刚吃掉 DEDENT**（= region 收尾）也构成行边界。块产生式消费 DEDENT 后，
// lexer 已把下一行的首 token 接在 DEDENT 之后（token 次序 NEWLINE → DEDENT → 下一行首 token）
// ⇒ 「prev == DEDENT」等价于「站在新一行的行首」。少了这条，`x := unsafe: …` 这类
// **以 region 收尾的声明/表达式**会在 end_decl 处被误判为「同行还有 token」。
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

// 语句/声明的行边界收尾（取代原 `expect(T_SEMI)`）：保留其**严格性** ——
// 少了这条，「同行两条声明」会被静默接受。
fn end_decl():
    if at_line_end() == 0:
        add_error("expected end of line, got '" + tok_lx(cur_tok()) + "'")
    skip_newlines()

// region 头：`T_COLON_BLOCK`（行尾冒号）+ 其后的 NEWLINE + `T_INDENT`。
// token 次序由 lexer 的 layout_break 决定：NEWLINE 先于 INDENT/DEDENT。
// **行内 `:`（T_COLON_DECL）在此被响亮拒绝** —— 正是 T0 布局规格 §2.2 要的
// 「行尾类型标注不是合法文本」的兜住点；形参标注断行（`fn f(a:` ＋ 续行 `int):`）
// 在 lexer 层与头部终结不可区分，正是靠这里兜住。
// 返回 1 = 吃到 `T_INDENT`（region 有 items）；**0 = 空 region**（无 INDENT、无 items）。
// v4 裁定（2026-10-11，**推翻** T0 布局规格 §10.2 的「空 region 无法表达 + 逐处改写」）：
// **region 可以为空** —— `:` 之后下一行**不更深** ⇒ 无 INDENT、无 items，region 值为「无值」。
// 用途实证（T6b 报来、维护者采纳）：`loop { }`（**永不返回**，与 `loop:` + 裸 `return`
// **不等价**）与 `interface Empty { }`（**零方法接口**，合法且有意义）在「逐处改写」下无等价形。
// ⚠ 只放宽「零项」这一格：**行内 `:`（T_COLON_DECL）在 region 头位仍响亮拒绝**（上面那支），
//   非零项 region 的缩进规则一个字不动。
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

// region 收尾：消费 `T_DEDENT`；非 DEDENT（如 EOF）⇒ 响亮报错（不静默吞）。
fn close_region():
    if tok_k(cur_tok()) == T_DEDENT:
        advance_tok()
    else:
        add_error("expected end of region (missing DEDENT)")

// 语句位 region 的**控制流**末项：位置标志为语句位时，控制流类尾项保留为**块的尾值**；
// 其余一律包 EXPR_STMT（等价 v3 带 `;` 的表达式语句）。
//
// ⚠ **本清单两套前端**本来就不一样**，判据锚在语义（v3 逐形等价），**不锚在 kind 名机械一致**
//   —— 见维护者裁定（2026-10-11）：
//   · 自源侧 **`while` 有独立 kind `EXPR_WHILE`**（`parse_while_expr` 直接建它，`checker.cr`/
//     `ir_gen.cr` 都有该分支）⇒ **必须入列**。少了它，`while` 作 region 尾项会被包 `EXPR_STMT`
//     ⇒ `unit`，与 v3（`while c { … }` 不带 `;` ⇒ 本就是块的值）**漂移**。
//   · Python 侧 `while` **desugar 成 `Loop`** ⇒ 那边只需 `Loop`，**不要**去给它补一个 while 项。
//   · `Flow`：Python 侧是表达式节点（入列）；自源侧 **`flow` 只是顶层声明修饰符、不是表达式
//     节点**（`parse_primary` 无 `T_FLOW` 分支）⇒ **不入列**。
//   ⇒ **禁止**为「两边 kind 清单长得一样」而增删本行——那会把语义正确的差异抹平成错。
fn is_block_like(n: int) -> int:
    if n < 0:
        return 0
    k := ast_kind(n)
    if k == EXPR_IF || k == EXPR_MATCH || k == EXPR_LOOP || k == EXPR_WHILE || k == EXPR_FOR || k == EXPR_UNSAFE:
        return 1
    return 0

// 块内的「语句类」节点（Python 侧的 Stmt 族）：let / return / break / continue。
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
    // 表示层概念（2026-09-10 语言面收窄裁决 §1）：`[T; N]` 的类型构造器身份已退役——
    // 语义归处 = product（N 元聚合）/ 序列接口 + 长度 where（N 长序列）/ F11 图（长度事实，
    // 可表达依赖长度）。本语法保留为「内联容量存储」表示提示（映射参数层，与 hw-map 同层；
    // 随实例选择生效或退化，非经典范式映射可忽略）。见
    // docs/superpowers/specs/2026-09-10-language-surface-narrowing-design.md §1
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
        // v4（施工计划 §四.1 项 8）：`never` 由**词素比对提升进关键字表** ⇒ 走独立 token 分支
        // （升格后它不再可能是标识符）。语义不变：TY_NEVER。
        advance_tok()
        res = alloc_node(0, 0, 0, 0, 0, TY_NEVER, 0, line, col)
    else if tok_k(t) == T_DYN:
        // 同上：`dyn` 升格为关键字（复用既有 token kind T_DYN=99）。语义不变：TI_DYN。
        advance_tok()
        res = alloc_node(0, 0, 0, 0, 0, TI_DYN, 0, line, col)
    else if tok_k(t) == T_IDENT || tok_k(t) == T_SELF || tok_k(t) == T_UNDERSCORE:
        lex := tok_lx(t)
        advance_tok()
        if lex == "int":
            res = alloc_node(0, 0, 0, 0, 0, TY_INT, 0, line, col)
        // dex = 精确小数（float 类型名已移除——数值迁移 Task 5）
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
        w64(g_diags, g_diag_count * DIAG_REC_SIZE, EC_P_EXPECTED)
        store_str_ptr(g_diags, g_diag_count * DIAG_REC_SIZE + 8, "expected type after '->', got '{' — missing return type?")
        w64(g_diags, g_diag_count * DIAG_REC_SIZE + 16, line)
        w64(g_diags, g_diag_count * DIAG_REC_SIZE + 24, col)
        w64(g_diags, g_diag_count * DIAG_REC_SIZE + 32, diag_fileid_for_line(line))
        g_diag_count = g_diag_count + 1
        res = alloc_node(0, 0, 0, 0, 0, TY_UNIT, 0, line, col)
    else:
        grow_diags(g_diag_count + 1)
        w64(g_diags, g_diag_count * DIAG_REC_SIZE, EC_P_EXPECTED)
        store_str_ptr(g_diags, g_diag_count * DIAG_REC_SIZE + 8, "expected type after '->'")
        w64(g_diags, g_diag_count * DIAG_REC_SIZE + 16, line)
        w64(g_diags, g_diag_count * DIAG_REC_SIZE + 24, col)
        w64(g_diags, g_diag_count * DIAG_REC_SIZE + 32, diag_fileid_for_line(line))
        g_diag_count = g_diag_count + 1
        res = alloc_node(0, 0, 0, 0, 0, TY_UNIT, 0, line, col)
    // R2 P3 Task 4：`T?` 的目标形态 = **EXPR_OPTIONAL**（内层类型节点入 a 槽）。
    // 旧形态（T? → EXPR_GENERIC_APPLY(Option, T)）要求「内建 Option 名」在符号表里被注册，
    // 正是本任务退役的做法（spec §5.4）；且旧形态无法表达 `T? = T ∪ null`（GenericApply 行
    // 在桥接侧是不展开的 AK_NAMED 原子）。新形态**零名字依赖**（不再 str_intern("Option")，
    // 见 test_optional.py 的行数对照用例）。
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
            // 赋值/复合赋值的右值 = 表达式位（bootstrap 侧 `parse_assignment` 同判：
            // `x = <region 收尾>` 的尾值必须保留 —— 见 g_want_value 头注规则 ②）。
            g_want_value = 1
        right := parse_binary(p + 1)
        op := tok2op(k)
        // Compound assignment: += -= *= /=  →  a = a op b
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
    // v4（§一.5）：`move` 已从关键字表退场 ⇒ lexer 不再发射 T_MOVE，本分支一并删除
    // （原 EXPR_MOVE 构造在 v4 下**不可达**；`move x` 现按普通标识符解析并响亮报错，不静默）。
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
    // Handle cast<T>(expr) syntax — same as expr as T
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
                // Path access: Option::Some → EXPR_FIELD(Option, Some, data=1)
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

// ── 字符串插值展开（批 8 裁定 (b)）：词法已把含 `${...}` 的字面量拆成 part 序列 ─────────
// part = T_STRING（字面段）或 T_INTERP（洞；lexeme = 洞内原文）。
// iv 约定（lexer 回填，见 lexer.cr 字符串分支；**用加法不用按位或**——bootstrap 后端不支持 `|`/`&`）：
// +1 = 属含插值的字面量 · +2 = 其后还有 part · 4（仅 T_INTERP）= 洞已闭合 ⇒ 判据 `iv >= 4` / `(iv % 4) >= 2`。⇒ parser 只把**同一字面量**的 part 串成链（`"${x}" "y"` 是两个字面量、
// 不连；裸邻接字符串仍照旧报错），**无洞字面量 iv=0 ⇒ 单 part、节点形态与旧实现逐字相同**（产物零足迹）。
// 洞表达式本体在 parse_all 末尾统一解析（那时 token 流已用毕）；类型转换由 checker 就地改写。
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
// data 槽的洞文本重新词法化 + parse_expr，结果写回 a 槽。**必须在 token 流用毕后调用**（会覆盖 g_tokens）；
// 洞内嵌套插值产生的新 HOLE 节点由本循环自然覆盖（上界 g_ast_count 随扫描增长）。
fn interp_parse_holes():
    i : ., mut = 0
    loop:
        if i >= g_ast_count:
            break
        if ast_kind(i) == EXPR_INTERP_HOLE:
            txt := istr_get(ast_data(i))
            if str_len(txt) > 0:
                // 洞内重入（**全仓唯一的重入点**，T0 布局规格 §5.2/§5.4）：洞是从源里切出的
                // 一小段表达式，**没有 layout 上下文** ⇒ 必须**显式旁路** layout 发射
                // （否则会伪造缩进状态并改写外层缩进栈；嵌套插值还会递归重入）。
                // 规则（规格 §5.2）：调用后 token 流不由 parse_all/parse_expr 消费 ⇒ 必传旁路。
                // 旁路以**显式实参**给出（形参 = `layout_bypass`），使调用点原文即判据载体
                // （J-T0-5 零构建半逐字读本行的 `g_layout_bypass`）。
                g_layout_bypass = 1
                tokenize(txt, g_layout_bypass)
                g_layout_bypass = 0
                g_token_pos = 0
                ast_set_a(i, parse_expr())
                tk2 := cur_tok()                     // ⚠ 不写 `if tok_k(cur_tok()) != T_EOF {`——那会与 A₁ 顶层兜底的
                if tok_k(tk2) != T_EOF:
                    //   突变锚点（tests/harness/test_criteria_mutations.py M9）撞形
                    check_error(EC_P_INTERP_UNCLOSED, "trailing tokens in string interpolation hole", ast_line(i), ast_col(i))
        i = i + 1

fn parse_primary() -> int:
    t := cur_tok()
    if tok_k(t) == T_INT:
        advance_tok()
        return alloc_node(EXPR_INT, 0, 0, 0, tok_iv(t), TY_INT, 0, tok_ln(t), tok_cl(t))
    if tok_k(t) == T_DEX:
        advance_tok()
        // 节点字段（数值迁移 Task 4）：a = binary64 位模式（apx 快路径字面量表示，
        // 由 lexer 存入 token 的 lexeme 槽的数字串还原）；int_val = 定点缩放整数
        // （精确表示，默认路径）。宽度后缀退役（2026-09-10 语言面收窄 §2）：data 槽
        // 不再承载宽度标注，恒 0。
        bits : int = 0
        tl := r64(g_tokens, t * ESZ_TOKEN + OFF_TK_LEXEME)   // 词素串下标（-1 = 无）
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
        // v4（§一.5 + docs/core-language-syntax_v4.md:59/264）：`none` 是**关键字**，
        // 空可选值（`T?` 的无值形态）即此拼写。canonical 变体名仍是 `None`（desugar/checker/
        // ty_shadow 按标签串 `None` 比较，见 ty_shadow.cr:1457）⇒ 此处映射到 canonical 名。
        // ⚠ `None`（大写）已**退役为普通标识符** —— 作值用会走 EXPR_IDENT 的未定义名硬错（响亮），
        //   与「拼写面重命名」的意图一致（不静默改判）。
        advance_tok()
        return alloc_node(EXPR_ENUM_CONSTRUCTOR, str_intern("None"), -1, 0, 0, 0, 0, tok_ln(t), tok_cl(t))
    // `Some` 已退场为关键字（T_SOME 不再由 lexer 发射）：`Some(x)` 走 parse_postfix 的
    // 「IDENT + `(` + 首字母大写 ⇒ EXPR_ENUM_CONSTRUCTOR」分支（与旧 T_SOME 分支同契约：
    // 实参建 EXPR_ARG 链），裸 `Some` 走 EXPR_IDENT。
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
        // v4（T0 布局规格 §4.5）：块花括号不存在 ⇒ `Name {` 之后**必**是字面量，
        // 原 `_is_struct_lit` 消解器与 `g_parse_no_struct_literal` 旗标一并退场（无需前瞻）。
        if check(T_LBRACE):
            advance_tok()
            // 契约（F5 修复，与元组分支同款）：EXPR_STRUCT = a=类型名 idx、b=首 wrapper、c=字段数；
            // wrapper 在 g_ast 中**连续**（kind=EXPR_NONE，wrapper.a=该字段的值节点）→ 消费者
            // 经 EXPR_NONE 前向解引用取值。字段值节点自身对复合表达式（调用 / 字面量 / 嵌套聚合）
            // **不连续**（子树自占多槽），故必须分两趟：先解析全部字段值，再统建连续 wrapper。
            // 旧写法「逐值后随建 wrapper」交错分配：复合值子树夹在相邻 wrapper 之间 ⇒ 第 2 个
            // 起字段槽位整体错位，读到子节点（实测 P{a:11, b:g()} 的 b 静默得 0，rc=0）。
            // TODO #2026-09-11-11 ①：wrapper.b = 字段名 idx（**名字绑定**，-1 = 无名字信息）——旧代码取
            // `fni` 后从未写入 ⇒ 值按声明位序绑定（P{b:11,a:22} 静默得 a=11）。名字随 wrapper
            // 同行（与值并列的平行表，两趟结构不变，仍无交错分配）。
            cap : ., mut = 8
            vals : string, mut = alloc(cap * 8)
            names : string, mut = alloc(cap * 8)
            fc : ., mut = 0
            loop:
                // EOF 护栏（TODO #2026-09-10-12 根因面）：本循环只认 `}`，而 advance_tok 在 EOF 是空操作
                // ⇒ 解析失步至 EOF 后自旋，每轮分配 AST 节点直至 OOM（alloc 失败返回 NULL →
                // grow_ast 向 NULL 拷贝 SIGSEGV）。同族 6 处循环统一补 EOF 退出。
                if check(T_RBRACE) || check(T_EOF):
                    break
                ft := advance_tok()
                fni := str_intern(tok_lx(ft))
                // T0 布局规格 §4.2 写死：**字段分隔符必须是 `=`**（v4 单形语言），未选定的
                // `:` 形**响亮拒绝**（码 P030）。修复前是**盲跳一个 token**（返回值丢弃）⇒
                // `=` 与 `:` 两形都收 = 判据无鉴别力，而 v4 是单形语言。
                if check(T_EQ):
                    advance_tok()
                else:
                    check_error(EC_P_STRUCT_LIT_SEP,
                        "struct literal field separator must be '=' (':' is not valid in v4)",
                        tok_ln(cur_tok()), tok_cl(cur_tok()))
                if fc >= cap:
                    ncap := cap * 2
                    nv := alloc(ncap * 8)
                    _dyncpy(vals, cap * 8, nv)
                    vals = nv
                    nn := alloc(ncap * 8)
                    _dyncpy(names, cap * 8, nn)
                    names = nn
                    cap = ncap
                g_want_value = 1                 // 字段值 = 表达式位
                w64(vals, fc * 8, parse_expr())  // 字段值（子树自占若干槽）
                w64(names, fc * 8, fni)          // 字段名 idx（① 名字绑定）
                fc = fc + 1
                if check(T_COMMA):
                    advance_tok()
            advance_tok()
            ff : ., mut = -1
            fi2 : ., mut = 0
            loop:
                if fi2 >= fc:
                    break
                vn := r64(vals, fi2 * 8)
                ln : ., mut = tok_ln(t)
                cl : ., mut = tok_cl(t)
                if vn >= 0:
                    ln = ast_line(vn)
                    cl = ast_col(vn)
                wl := ast_alloc(EXPR_NONE, vn, r64(names, fi2 * 8), 0, 0, 0, 0, ln, cl)
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
            // 契约（F5 修复）：EXPR_TUPLE = a=首 wrapper、b=元素个数；wrapper 在 g_ast 中
            // **连续**，每个 wrapper（kind=EXPR_NONE）的 a = 该元素的值节点 → 消费者经
            // `ast_a(wrapper + i)` 取元素值节点。元素值节点本身对复合表达式**不连续**
            // （复合元素子树自占多槽），故必须分两趟：先解析全部元素值，再统建连续 wrapper。
            // 注：不得照 struct 字面量分支（本文件 T_IDENT+T_LBRACE 段）的「逐值后随建
            // wrapper」交错顺序——复合值会插在相邻 wrapper 之间致其不连续，同属本根因。
            cap : ., mut = 8
            vals : string, mut = alloc(cap * 8)
            w64(vals, 0, e)
            ec : ., mut = 1
            loop:
                advance_tok()  // consume comma
                if ec >= cap:
                    ncap := cap * 2
                    nv := alloc(ncap * 8)
                    _dyncpy(vals, cap * 8, nv)
                    vals = nv
                    cap = ncap
                g_want_value = 1                 // 元组元素 = 表达式位
                w64(vals, ec * 8, parse_expr())  // 元素值（子树自占若干槽）
                ec = ec + 1
                if !check(T_COMMA):
                    break
            advance_tok()  // consume )
            ef : ., mut = -1
            ei : ., mut = 0
            loop:
                if ei >= ec:
                    break
                vn := r64(vals, ei * 8)
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
        // v4（T0 布局规格 §4.3）：`{ }` **只**作结构体字面量定界符（`{` 的唯一合法位置）；
        // 块结构由 `:` + 缩进取代 ⇒ 表达式位的裸 `{` 无产生式，**响亮报错**（不静默按块解）。
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
        // A7（T0 布局规格 §6.2）：`;`/`}` 的紧跟判定换成**行边界** —— `go` 之后
        // **同一逻辑行内**无 token ⇒ 响亮报错。
        if at_line_end() != 0:
            add_error("Expected expression after `go`")
            return 0
        // go [N] expr  or  go var start end expr → desugared to for loop
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
            // Not range mode — backtrack: regular go
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
        // 契约（F5 修复，与元组/struct 字面量分支同款）：**字面量形** EXPR_ARRAY =
        // a=首 wrapper、b=元素个数；wrapper 在 g_ast 中**连续**（kind=EXPR_NONE，wrapper.a=元素值
        // 节点）→ 消费者经 EXPR_NONE 前向解引用取值。元素值节点自身对复合表达式（嵌套字面量 /
        // 调用 / 下标）**不连续**（子树自占多槽），故必须两趟：先解析全部元素值，再统建 wrapper。
        // 旧交错写法下第 2 个元素起槽位整体错位（实测 [[1,2],[3,4]] 的 a[1] 被读成扁平 3 →
        // a[1][0] SIGSEGV 139；且 [[1,2],[3,4]] 与 [5,6] 类型互赋静默通过 = soundness 漏放）。
        // 区分：**类型形** [T; N] / [T] 由 parse_type 产出（a=内层类型节点、b=0、int_val=尺寸），
        // 不经本分支，不受本契约影响。
        cap : ., mut = 8
        vals : string, mut = alloc(cap * 8)
        ec : ., mut = 0
        if !check(T_RBRACKET):
            g_want_value = 1            // 数组元素 = 表达式位
            w64(vals, 0, parse_expr())  // 元素值（子树自占若干槽）
            ec = 1
            if check(T_SEMI):
                // Repeat array: [value; count] —— 值节点只解析一次，其后仅**共享**同一值节点
                // 追加 wrapper（旧写法浅拷贝根节点 N-1 份；共享值节点语义等价，且不再复制多槽子树）。
                advance_tok()
                ct := advance_tok()
                cnt : ., mut = tok_iv(ct)
                if cnt > cap:
                    nv := alloc(cnt * 8)
                    _dyncpy(vals, cap * 8, nv)
                    vals = nv
                    cap = cnt
                ri : ., mut = 1
                loop:
                    if ri >= cnt:
                        break
                    w64(vals, ri * 8, r64(vals, 0))
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
                        _dyncpy(vals, cap * 8, nv)
                        vals = nv
                        cap = ncap
                    g_want_value = 1                 // 数组元素 = 表达式位
                    w64(vals, ec * 8, parse_expr())  // 元素值（子树自占若干槽）
                    ec = ec + 1
        advance_tok()
        ef : ., mut = -1
        ei2 : ., mut = 0
        loop:
            if ei2 >= ec:
                break
            vn := r64(vals, ei2 * 8)
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

// 块体收集缓冲（局部语句表；每层 region 一段，退出时整体并入 g_block_stmts）。
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
            _dyncpy(g_pb_stmts, g_pb_cap * 8, nv)
        g_pb_stmts = nv
        g_pb_cap = ncap
    w64(g_pb_stmts, g_pb_count * 8, n)
    g_pb_count = g_pb_count + 1

// region 头 + 体（**所有** region 的通用入口）。
fn parse_block() -> int:
    head := cur_tok()
    if expect_region_head() == 0:
        // 空 region：零 items、无 DEDENT 可吃 ⇒ 不进 parse_block_items（其 close_region 会要 DEDENT）。
        return alloc_node(EXPR_BLOCK, g_block_stmt_count, 0, 0, 0, 0, 0, tok_ln(head), tok_cl(head))
    return parse_block_items(head)

// 体（**头已吃掉**）。拆出本函数只为「函数体 region 的开头若干项 = 规约注解」
// （v4 文档 §10.1，见 parse_body 的调用点）——那里必须在 statements 之前先吃 `#check`/`#ensure`。
// v4 region：`T_COLON_BLOCK` + NEWLINE + `T_INDENT` … `T_DEDENT`（取代原 `{` … `}`）。
// 尾表达式判定（T0 布局规格 §6.2 A1）：**region 的最后一项 = 该 region 的值**，
// 其余各项按语句处理 —— 「还有下一项」的判据由「不是 `}`」变成「不是 DEDENT」。
// 位置语义见 g_want_value 的头注：进入时读标志决定尾值去留，**体内嵌套 region 一律
// 先复位为语句位**（parse_stmt / 各 region 产生式各自复位），退出时恢复为进入值。
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
        // 收集缓冲的 save/restore：`parse_stmt` 会递归进入嵌套 region（**每个 region 各自
        // 重置本组全局**）⇒ 不复原本层已收集的语句会被内层覆盖（静默丢语句）。
        // 保存/恢复的必须是**本层**的状态（不是外层）——否则语句会被推给外层缓冲。
        my_stmts := g_pb_stmts
        my_cap := g_pb_cap
        my_count := g_pb_count
        st := parse_stmt()
        g_pb_stmts = my_stmts
        g_pb_cap = my_cap
        g_pb_count = my_count
        if is_stmt_node(st) != 0:
            // 语句类项：其前的裸表达式不是末项 ⇒ 包 EXPR_STMT（等价 v3 带 `;`）
            if have_expr >= 0:
                block_push(alloc_node(EXPR_STMT, have_expr, 0, 0, 0, 0, 0, tok_ln(t), tok_cl(t)))
                have_expr = -1
            block_push(st)
        else:
            // 裸表达式：**暂定**为 region 尾值（后面还有一项时再包成 EXPR_STMT）
            if have_expr >= 0:
                block_push(alloc_node(EXPR_STMT, have_expr, 0, 0, 0, 0, 0, tok_ln(t), tok_cl(t)))
            have_expr = st
    close_region()
    g_want_value = want
    if want == 0 && have_expr >= 0 && is_block_like(have_expr) == 0:
        // 语句位 region + 末项是**普通**裸表达式（赋值/调用/二元/一元/字面量/标识符/下标…）
        // ⇒ 包 EXPR_STMT（等价 v3 的 `expr;`），region 视为无值。
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
        w64(g_block_stmts, g_block_stmt_count * 8, r64(g_pb_stmts, i * 8))
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
    // x : type ...（T0 布局规格 §6.2 A3：改判 T_COLON_DECL —— 裁定 (b) 使两种 `:` 互斥且
    // 穷尽 ⇒ `T_COLON_BLOCK` 不进声明分支（进不去 ⇒ 在语句位由 expect_region_head 响亮报错）。
    // `:=` 仍走 T_COLON_EQ，批量仍走 T_COMMA ⇒ 本消解器零前瞻、比 `;` 时代更简单）
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
        w64(names, nc * 8, @ptr_of(tok_lx(nt)))
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
                w64(names, nc * 8, @ptr_of(tok_lx(nt2)))
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
        w64(values, vc * 8, parse_expr())
        vc = vc + 1
        loop:
            if !check(T_COMMA):
                break
            advance_tok()
            g_want_value = 1
            w64(values, vc * 8, parse_expr())
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
                // 标签表终止面（T0 布局规格 §6.2 A8 + A9 的对齐目标）：**行边界** + `EQ`
                // （`x : int, mut, pub = e` 的 `=` 仍保留）。A9：与 bootstrap 侧取同一形。
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
                        pd := r64(g_plugin_tags, ei*24+16)
                        if pd != 0:
                            is_mut = 1
                    else:
                        // 未知标签：TA08（已知标签 = mut/pub/apx + 插件注册标签）
                        grow_diags(g_diag_count + 1)
                        w64(g_diags, g_diag_count * DIAG_REC_SIZE, EC_TA_UNKNOWN_TAG)
                        store_str_ptr(g_diags, g_diag_count * DIAG_REC_SIZE + 8, "unknown declaration tag '" + tag + "'")
                        w64(g_diags, g_diag_count * DIAG_REC_SIZE + 16, tok_ln(tag_t))
                        w64(g_diags, g_diag_count * DIAG_REC_SIZE + 24, tok_cl(tag_t))
                        w64(g_diags, g_diag_count * DIAG_REC_SIZE + 32, diag_fileid_for_line(tok_ln(tag_t)))
                        g_diag_count = g_diag_count + 1
                if !check(T_COMMA):
                    break
                advance_tok()

        // Parse values
        w64(values, 0 * 8, -1)
        if check(T_EQ):
            advance_tok()
            g_want_value = 1   // 声明右值 = 表达式位
            w64(values, vc * 8, parse_expr())
            vc = vc + 1
            loop:
                if !check(T_COMMA):
                    break
                advance_tok()
                g_want_value = 1
                w64(values, vc * 8, parse_expr())
                vc = vc + 1

    // v4：语句末可选 `;` 退场（T0 布局规格 §6.2 B1）——收尾统一由 end_decl 的行边界完成。

    // Emit LET nodes. First returned directly, extras go to g_extra_lets (dynamic grow).
    first_node : ., mut = -1
    i : ., mut = 0
    loop:
        if i >= nc:
            break
        name_str := unsafe:
            @str_of(r64(names, i * 8))
        ni := str_intern(name_str)   // 2(a)：裸字读出按串用
        nv := r64(values, i * 8)
        // 批 8（静默面收口 · 条目 5；lead 2026-09-18 裁 **(B) 白名单**）：`apx` 仅适用于
        // **显式 `dex`**（有表示路径）与 **显式 `int`**（既有契约的纯注解：`tests/selfhost/test_apx_tag.py`
        // 钉「语法合法 + 语义不变 + `.cir` 携 `approx`」，`tests/bootstrap/test_apx_tag.py` 同向 ApproxInstr
        // ⇒ 两前端对齐）。**其余一律硬错**：`dex?` · `.`（推断）· `auto` · `string`/`bool`/… ——
        // 这三形「零文档 / 零测试 / **值面无路**」：用户要 apx 表示而实现无路可走（`.cir` 仍多一条
        // `IR_APPROX` ⇒ **只带标签不给表示** = 语义谎）。判据 = rc=1 + 定位 + build 零产物。
        // ⛔ 裁 (A)（连 `int, apx` 一并拒）已否：那会**改契约**（须重定 test_apx_tag + 登记两前端接受集
        // 分歧），而 `int, apx` **不是静默面**。判据原则：「**有契约 ⇒ 有意设计；无契约 ⇒ 静默谎**」。
        // ⚠ **（B）的残留两前端分歧（2026-09-18 复核指出；纠 lead 先前「(B) 下无需登记」之判断）**：
        // `bootstrap/corec/frontend/parser.py` 的标签白名单**只查标签名**（`mut`/`pub`/`apx`）、
        // **无适用性校验** ⇒ 本检查落地后 `dex?, apx` · `. + apx` · `auto + apx` · `string`/`bool + apx`
        // 在 **bootstrap 侧仍被接受**、self-hosted 侧**拒**（`error[P26]`）⇒ **接受集分歧**（同族
        // `TODO #2026-09-17-10` 的两前端分歧家族）。**形态为预存**（bootstrap 从未校验适用性），
        // 但**分歧面因 (B) 而显性化**；收敛方向 = bootstrap 侧补同款白名单（另批，不在本 PR 范围）。
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
                w64(g_extra_lets, g_extra_let_count * 8, node)
                g_extra_let_count = g_extra_let_count + 1
        i = i + 1

    return first_node

// 跳过整段嵌套函数声明（P021 已报错，仅错误恢复路径）：`fn name(params) -> T {body}`
// 按花括号配平跳过整段；`= expr;` 形式（含 extern 无体形式）遇分号收尾。起始 token 可为
// `pub`。花括号配平从函数体的 `{` 起算（depth 0→1），体内嵌套块/struct 字面量的花括号
// 成对计入，不会在 depth 归零前误判结束。
fn skip_nested_fn():
    // v4：体的两种形态都以**行边界**收尾 —— `:` + INDENT…DEDENT 的 region，或 `= expr` 行内体。
    // 花括号配平换成缩进配平（T0 布局规格 §6.2 A5：原 `;` 收尾 ⇒ region 收尾）。
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

// 语句前导位 `@` 注解的白名单（v4 §13 的**实证**清单 —— 文档或语料在**语句/region 前导位**
// 实际出现过的名字）：
//   §13.7 `@preferredDomain(gpu)` 前导 `loop:`（文档第三例，逐字）
//   §13.7 `@executionDomain(name)`（同族硬约束；其文档例的目标是顶层 `flow`，此处置同名同判）
//   §13.4 `@NoBoundsCheck`（文档：只用于「调用方承担边界安全责任的**低层区域**」；
//          语料 `tests/suite/at_test.cr:46` 就是语句位用法）
//   §13.2 `@fast` / `@unroll(4)` / `@section("text.hot")`（语料 `tests/probes/p_annots.cr:5-7` 语句位）
// **不收** §13.1 查询族 / §13.3 `@addr` / §13.2 `@inline` —— 文档里它们都在**表达式位**
// （语料同证：`sz := @sizeOf(P3)`、`r := @inline(add)(3, 4)`）⇒ 走既有表达式路。
// **未知名**不在此列 ⇒ 仍是表达式 ⇒ 由 checker 以 `EC_N_*` 响亮拒绝（不静默）。
//
// ⚠ **本清单的判据 = 「文档释文 + 语料实证」，不是「章号范围」**（维护者 2026-10-11 采纳）。
//   二者会冲突，且本处**以后者为准**：`NoBoundsCheck`（§13.4）/ `fast`·`unroll`·`section`（§13.2）
//   章号上属「§13.1–13.4」，但那四条的**释文/语料**都把它们用在**语句前导位**（见上逐条出处）
//   ⇒ 收。**禁止**后人按章号把它们再收窄回去——那会把有实证支持的名字重新判成非法。
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

// 消费语句前导位的 `@` 注解链（一至多条，各占一行）。返回被消费的条数。
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
        // 注解**独占一行**（与规约注解同口径）。带码（V03）—— 不带码的消息会被
        // `run_frontend` 的 `g_diag_count > 0` 早退挡在 `print_parse_errors()` 之前（报不出来）。
        if at_line_end() == 0:
            check_error(EC_V_ANN_SYNTAX,
                "Expected end of line after '@" + an + "' annotation", at_line, at_col)
            return cnt
        skip_newlines()
        cnt = cnt + 1
    return cnt

fn parse_stmt() -> int:
    // 语句位入口（位置语义规则 ①）：本语句整体在语句位 ⇒ 先复位；语句内的表达式位由
    // 各入口重置为 1（声明/赋值右值、return 值、实参、下标、括号内、字面量字段值…）。
    g_want_value = 0
    // v4 §13.7 第三例 / §13.4：**语句前导位**的 `@` 注解（如 `@preferredDomain(gpu)` 前导
    // `loop:`）。必须在此消费 —— 否则 `@` 会落进表达式路，被 checker 当**未知名内建**报 N01
    // （实测：`@preferredDomain(gpu)` + `loop:` ⇒ `error[N01]`）。
    skip_stmt_at_annotations()
    // Drain batch extras from previous call
    if g_extra_let_count > 0:
        g_extra_let_count = g_extra_let_count - 1
        return r64(g_extra_lets, g_extra_let_count * 8)

    t := cur_tok()
    // 嵌套 `fn`/`flow` 声明不属语言面——grammar/core.ebnf 的 Statement 不含 FunctionDecl
    // （函数声明仅顶层 TopLevelDecl），bootstrap 参考实现亦以 positioned error 拒绝。
    // 修复前此处落回 parse_primary 的「Unexpected token in expression」通用兜底：只消费
    // `fn` 一个 token，解析失步后 `IDENT {` 进入 struct 字面量循环并把外层 `}` 当字段吃掉，
    // 至 EOF 后因该循环只认 `}` 且 advance_tok 在 EOF 是空操作而自旋——每轮分配 AST 节点，
    // 直到 bump allocator 耗尽返回 NULL、grow_ast 向 NULL 拷贝（rc=139 SIGSEGV，TODO #2026-09-10-12）。
    // 现显式报 P021 并整段跳过该声明：错误定位到声明处，且后续语句恢复正常解析。
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
        // A6（T0 布局规格 §6.2）：关键字之后**同一逻辑行内**无 token ⇒ 无值（行边界取代 `;`）
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
    // A1：裸表达式**暂定**为 region 尾值；块循环在「后面还有一项」时再包成 EXPR_STMT。
    // v4 无 `;` ⇒ 不再有「显式语句」形态（原 `if check(T_SEMI): return EXPR_STMT(e)` 分支淘汰）。
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
    // 规则 ①：loop 体恒为**语句位** region（v3 里体末语句必带 `;` ⇒ 块类型 unit）。
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
    // 空 region（§10.2 裁定推翻后合法）：`match c:` 后无可达更深的行 ⇒ 零臂。
    // `has_items == 0` 时下面的循环一次不进、也不吃 DEDENT（没有）。
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
        // 臂前缀 `|`（v4 目标形）——与 bootstrap 侧同判：**有 `|` 与无 `|` 两形都收**。
        // 改前 `|` 在臂首是解析错误 ⇒ 本放宽不改变任何既有可解析程序的含义（纯增量）。
        if check(T_PIPE):
            advance_tok()
        pat := parse_pattern()
        if check(T_FATARROW):
            advance_tok()
        else:
            add_error("expected '=>' in match arm")
        // v4 文档 §7.3（逐字）：「需要多行 arm body 时，`=>` 后换行并进入更深 layout」
        //   match cmd:
        //    | "start" =>
        //       prepare()
        //       start_server()
        //    | _ => println("unknown command")
        // ⇒ `=>` 后**行尾** ⟺ 臂体是一个 layout region；否则单表达式。
        // ⚠ 该 region **没有 `:`**（`=>` 已充当开启符）⇒ **不能**走 expect_region_head。
        body : ., mut = -1
        // **兼容形 `=>:`**（`=>` 后紧跟 `:`）：文档 §7.3 **没有**这一形（那里是 `=>` 后直接换行），
        // 但 T6 的语料（`tests/selfhost/test_optional.py` 等 ~167 处）机械改写成了它
        // ⇒ 按本批既有先例（`flow fn` 兼容形）**收为兼容**：与文档形**同判**（其后仍是
        // 换行 + 更深 layout 的 region）。文档不写它、不为它新增用例；**不改变**文档形的判定。
        // 「臂体是 region」的判据必须在**消费 `:` 之前**定下 —— 消费后再问 at_line_end()
        // 会因为站在 INDENT 上而误判成「非行边界」（实测踩过）。
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
                g_want_value = 1                 // 臂体 = 表达式位 ⇒ region 保尾值
                body = parse_block_items(head)
            else:
                // 空 region（形态 D：`| _ =>` 后无更深行）：值 = 无值
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
        // v4（bootstrap parse_pattern 同判）：小写 `none` 是关键字，映射到 **canonical 变体名
        // `None`**（EnumPattern 的 path[-1] 会被当**标签串**比较，见 desugar/ty_shadow:1457）。
        // **漏掉本格** ⇒ `none` 掉进下方 `is_upper_first` 为假的 EXPR_IDENT（那是**变量绑定**，
        // 不是匹配）⇒ 模式永远命中 = 语义静默改变。`Some` 已退场为普通 IDENT，
        // 走下方 IDENT 分支的「首字母大写 ⇒ EXPR_ENUMPAT」（与旧 T_SOME 同形）。
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
            // 契约（F5 修复，与 struct 字面量分支同款）：EXPR_STRUCTPAT = a=名字 idx、b=首 wrapper、
            // c=字段数；wrapper 在 g_ast 中**连续**（kind=EXPR_NONE，wrapper.a=子模式节点）。
            // 复合子模式（嵌套 struct/enum/tuple 模式）子树占多槽，故两趟：先全部解析、后统建 wrapper。
            advance_tok()
            cap : ., mut = 8
            vals : string, mut = alloc(cap * 8)
            fc : ., mut = 0
            loop:
                if check(T_RBRACE) || check(T_EOF):
                    break
                ft := advance_tok()
                fni := str_intern(tok_lx(ft))
                // 同 struct 字面量的字段分隔符守卫（T0 布局规格 §4.2）：struct **模式**取单形 `=`。
                if check(T_EQ):
                    advance_tok()
                else:
                    check_error(EC_P_STRUCT_LIT_SEP,
                        "struct pattern field separator must be '='",
                        tok_ln(cur_tok()), tok_cl(cur_tok()))
                if fc >= cap:
                    ncap := cap * 2
                    nv := alloc(ncap * 8)
                    _dyncpy(vals, cap * 8, nv)
                    vals = nv
                    cap = ncap
                w64(vals, fc * 8, parse_pattern())
                fc = fc + 1
                if check(T_COMMA):
                    advance_tok()
            advance_tok()
            ff : ., mut = -1
            fi2 : ., mut = 0
            loop:
                if fi2 >= fc:
                    break
                vn := r64(vals, fi2 * 8)
                ln : ., mut = tok_ln(t)
                cl : ., mut = tok_cl(t)
                if vn >= 0:
                    ln = ast_line(vn)
                    cl = ast_col(vn)
                wl := ast_alloc(EXPR_NONE, vn, 0, 0, 0, 0, 0, ln, cl)
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
        w64(constrs, ci * 8, -1)
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
                w64(names, gc * 8, @ptr_of(tok_lx(gt)))
            // Check for constraint: T: Interface
            w64(constrs, gc * 8, -1)
            if check(T_COLON_DECL):
                advance_tok()
                ct := advance_tok()
                w64(constrs, gc * 8, str_intern(tok_lx(ct)))
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
            @str_of(r64(names, gi * 8))
        ni := str_intern(name_str)
        fi_set_generic_name(fi, gi, ni)
        gi = gi + 1

fn save_func_gen_constrs(fi: int, constrs: string, count: int):
    gi : ., mut = 0
    loop:
        if gi >= count:
            break
        if r64(constrs, gi * 8) >= 0:
            idx := fi * MAX_GENERICS + gi
            grow_gen_constr(idx + 1)
            w64(g_generic_constr, idx * 8, r64(constrs, gi * 8))
            if idx + 1 > g_generic_constr_count:
                g_generic_constr_count = idx + 1
        gi = gi + 1

// ─── R2 P3 Task 5（Step 2）：结构/枚举泛型约束登记（**索引空间分家** —— 键 = row*MAX_GENERICS+gi，
// 与函数侧 g_generic_constr 不同缓冲；见 globals.cr 表注）───
// **空槽预填 -1**（本批实测缺陷修复）：表是**稀疏**填的（只写有约束的槽），而缓冲零初值 ⇒
// 高水位区内的「本行未写过的槽」读出 0——0 是**合法的名字 ni**（首个驻留串）⇒ 读取方
// `c_ni >= 0` 会把空槽当有效约束名（把首个驻留串当接口/类型名查表）＝ 凭空约束。
// 故本三函数一律先整行（MAX_GENERICS 槽）写 -1 再覆盖有约束的槽——行的语义 = 「本行全部
// 形参位都有明确值」。读取器的越界闸（idx ≥ count）仍保留（整行未登记时的兜底）。
fn save_struct_gen_constrs(si: int, constrs: string, count: int):
    grow_sgen_constr(si * MAX_GENERICS + MAX_GENERICS)
    if si * MAX_GENERICS + MAX_GENERICS > g_sgen_constr_count:
        g_sgen_constr_count = si * MAX_GENERICS + MAX_GENERICS
    zi : ., mut = 0
    loop:
        if zi >= MAX_GENERICS:
            break
        w64(g_sgen_constr, (si * MAX_GENERICS + zi) * 8, -1)
        zi = zi + 1
    gi : ., mut = 0
    loop:
        if gi >= count:
            break
        if gi >= MAX_GENERICS:
            break
        if r64(constrs, gi * 8) >= 0:
            w64(g_sgen_constr, (si * MAX_GENERICS + gi) * 8, r64(constrs, gi * 8))
        gi = gi + 1

fn save_enum_gen_constrs(ei: int, constrs: string, count: int):
    grow_egen_constr(ei * MAX_GENERICS + MAX_GENERICS)
    if ei * MAX_GENERICS + MAX_GENERICS > g_egen_constr_count:
        g_egen_constr_count = ei * MAX_GENERICS + MAX_GENERICS
    zi : ., mut = 0
    loop:
        if zi >= MAX_GENERICS:
            break
        w64(g_egen_constr, (ei * MAX_GENERICS + zi) * 8, -1)
        zi = zi + 1
    gi : ., mut = 0
    loop:
        if gi >= count:
            break
        if gi >= MAX_GENERICS:
            break
        if r64(constrs, gi * 8) >= 0:
            w64(g_egen_constr, (ei * MAX_GENERICS + gi) * 8, r64(constrs, gi * 8))
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
        w8(g_structs, base + zi, 0)
        zi = zi + 1
    w64(g_structs, base + OFF_SI_NAME, ni)
    // 容量批 T3：字段区基址 = 侧表高水位（字段写入点按 base + 下标寻址；体尾 si_commit_fields 提交）
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
        w8(g_enums, base + zi, 0)
        zi = zi + 1
    w64(g_enums, base + OFF_EI_NAME, ni)
    // 容量批 T3：变体区基址 = 侧表高水位（体尾 ei_commit_variants 提交）
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

    // 批 6（T2，裁-S2）：规约标注链——**签名之后、body 之前**（spec-design §四）。
    // T3：记录起点，`alloc_node(EXPR_FN, …)` 之后把本函数的标注行回填为 **fn_node 索引**
    //（唯一键——按函数名会串台：同名方法/多 impl）。
    spec_start := g_spec_count
    parse_spec_annotations(fn_ni, 0)   // inline 形（兼容）：注解后紧跟 `:`，不要求行尾

    body : ., mut = -1
    // D9/D10（T0 布局规格 §2.2）：有体 ⇒ 行尾 `:`（T_COLON_BLOCK）开 region；
    // 无体（`extern fn read(fd: int) -> int`）⇒ 行边界，无 `:`。
    // 规则 ①：函数体 region **恒为语句位** ⇒ 末项裸表达式包 EXPR_STMT，块类型 unit
    // ⇒ 返回值只经显式 `return`（v4 §7.4「函数没有 implicit tail return」）。
    if at_line_end() != 0:
        body = -1
    else if check(T_EQ):
        // `fn f() = expr`（表达式体）——声明右值 = 表达式位
        advance_tok()
        g_want_value = 1
        body = parse_expr()
    else:
        g_want_value = 0
        // v4 文档 §10.1（**文档形**）：规约注解位于函数 layout region 的**开头**——
        // 「在 statements 之前」的若干项。故此处**自己吃掉 region 头**，先把 `#check`/`#ensure`
        // 收干净，再进 statements（`parse_block` 那条通用路做不到这一步）。
        // inline 形（注解夹在签名与 `:` 之间，见上方 1737-1738 行）**保留为兼容**：
        // 它不在文档里，但 `tests/spec` 的干净档有工具产出，删掉会牵动 T6 的修复路径。
        head := cur_tok()
        if expect_region_head() == 0:
            // 空函数体（§10.2 裁定推翻后合法）：零项 ⇒ 值 = 无值（块类型 unit）。
            body = alloc_node(EXPR_BLOCK, g_block_stmt_count, 0, 0, 0, 0, 0, tok_ln(head), tok_cl(head))
        else:
            parse_spec_annotations(fn_ni, 1)   // 文档形：注解独占一行
            body = parse_block_items(head)
    fn_node := alloc_node(EXPR_FN, fn_ni, pf, pc, rtv + hotpatch_ver * 256, rt, body, fn_line, fn_col)
    // T3：标注行回填 fn_node（本函数新增的行 = [spec_start, g_spec_count)）
    spec_patch : ., mut = spec_start
    loop:
        if spec_patch >= g_spec_count:
            break
        spec_set_fnode(spec_patch, fn_node)
        spec_patch = spec_patch + 1
    // 形参上限硬错（防御面，TODO #2026-09-10-4）：FuncInfo.param_types 是定长内嵌槽区
    // （MAX_FN_PARAMS 槽），超限签名无法表示 ⇒ 拒绝编译（rc=1）而非截断/越界写。
    // 形参表容纳不下时**必须**在这条路径上停住：静默越界写曾踩 ast_node 致
    // name_idx/param_count 归零 + TF01 误归 + rc=0 产物崩。
    if pc > MAX_FN_PARAMS:
        check_error(EC_P_TOO_MANY_PARAMS,
            "Function has too many parameters (" + int_str(pc) + " > " + int_str(MAX_FN_PARAMS) + ")",
            fn_line, fn_col)
    fi := add_func(fn_name, pc, rtv, fn_node)
    if fi >= 0 && gc > 0:
        save_func_generics(fi, gnames, gc)
        save_func_gen_constrs(fi, gconstrs, gc)
    // Store param types in FuncInfo（pc > MAX_FN_PARAMS 已被上方硬错拒绝；
    // 此处再显式跳过 + fi_set_param_type 内槽区护栏 = 双保险，未来新调用点亦不越过界）
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
// 两个位置共用本函数；`need_eol` 区分二者：
//   ① **inline 形**（兼容，非文档）——签名与 `:` 之间，各条注解同行 ⇒ need_eol=0
//      （其后紧跟的是 `T_COLON_BLOCK`，不是行边界，故**不能**要行尾）；
//   ② **文档形**（v4 §10.1）——函数 region 的**开头若干项**，每条注解**独占一行** ⇒ need_eol=1
//      （v4 的行语义 = 一条语句一行；`#check(1 > 0) return 1` 同行是**非法文本**）。
//      循环尾 `skip_newlines()` 让注解链跨行成立（① 那侧无 NEWLINE，是 no-op）。
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
        // 文档形：注解必须**独占一行**。**带码**（V03）而非 `add_error` —— 不带码的
        // 消息会被 `run_frontend` 的 `g_diag_count > 0` 早退挡在 `print_parse_errors()`
        // 之前（见 `main.cr:133-137`），也就是**报不出来**（同 `flow` 那处的先例）。
        // 判据（负例档 `tests/spec/t2_neg_inbody.cr` 逐字 `#check(1 > 0) return 1`）：
        // 该档是**负例**，必须 rc=1；漏了本条会把它变成静默接受（实测确曾如此）。
        if need_eol != 0 && at_line_end() == 0:
            check_error(EC_V_ANN_SYNTAX,
                "Expected end of line after '#" + an_name + "' annotation", at_line, at_col)
            return
        spec_add(fn_ni, kind, expr, at_line, at_col)
        // 注解之间的换行（文档形 §10.1：每条独占一行）。**只跳注解之间**——
        // 首条之前若有 NEWLINE（无体声明的收尾），在此吞掉会让调用点的 at_line_end()
        // 误判「非行边界」（回归面）。
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

    // ── v4 文档 §13：顶层声明可带**前导 `@` 注解**（一至多条，各自独占一行）──
    // 文档里**声明前导**的形共四个（§13 全量扫描，见本次交付的清单）：
    //   §13.5 `@ffi("Python")` / `@ffi("Java")`        ← 前导 `extern fn`
    //   §13.6 `@hotpatch(ver=1)` / `@hotpatch(ver=2)`  ← 前导 `fn`
    //   §13.7 `@preferredDomain(gpu)`                  ← 前导 `fn`
    //   §13.7 `@executionDomain(fpgaA)`                ← 前导 `flow`
    // 本循环 = **一至多条**（`skip_newlines()` 使「注解独占一行」的文档形成立；
    // 同行的旧形 `@hotpatch(ver=1) fn …`（`tests/suite/hotpatch_test.cr` 的用法）不受影响）。
    // ⚠ 白名单**只收这四个**，其余名字在此位置**响亮报错**（V02）——「放宽 = 吞错」是静默面：
    //   `@hotpach(ver=1)` 这种笔误若不报，注解就被静默丢弃。§13.2/.3/.4 的
    //   `@inline`/`@section`/`@fast`/`@NoBoundsCheck`/`@addr`/`@sizeOf`… 在文档里
    //   **只作表达式/语句位**出现（语料同：`tests/suite/at_test.cr:46` 的 `@NoBoundsCheck`
    //   是 region 内的语句，走 parse_stmt→parse_expr），**未**出现于声明前导位 ⇒ 不入白名单。
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
        // 已知/未知用**标志位**汇合（不用「空 else-if 分支」——region 内无语句在 v4 不可表达，T0 §10.2）。
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
            // §13.5：`@ffi("lang")` 前导 `extern fn` —— 语言名从**位置实参**取（第一个字符串）
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
        // 批 8（静默面收口 · 条目 3）：C ABI 无可选表示 ⇒ extern 声明的**形参/返回不得为可选**
        // （修复前 checker 对 extern 声明整段早退（`checker.cr` EXPR_EXTERN 分支）⇒ `extern fn e(x: int?)`
        //  check=0/build=0、运行期垃圾值；两条早退路径都不报）。判据 = rc=1 + 定位 + 零产物（P024）；
        // **非可选 extern 不受影响**（判据 ②，守卫档 = test_iface_ops.py / ffi_test.cr / p_ffi2.cr）。
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
        // v4（T0 布局规格 §6.2 B2）：extern 声明末的可选 `;` 退场 ⇒ 收尾 = 行边界。
        end_decl()
        return

    // fn / flow
    if check(T_FN) || check(T_FLOW):
        is_flow : ., mut = 0
        // F5c：`flow fn name()` 语法——修复前消费 T_FLOW 后直接 advance_tok()
        // 把 T_FN 当函数名（name="fn"），flow 函数构造不可达（P01 乱报）。
        // v4 文档形（2026-10-11 裁：文档是目标语法 ⇒ 改实现）：
        //   `docs/core-language-syntax_v4.md:1232` 逐字 `flow counter(start: int) -> int:`、
        //   `:1406` 逐字 `flow encode(input: Frame) -> Packet:` —— **无 `fn`**。
        // ⇒ 两形都收：文档形 `flow name(...)`（主），旧形 `flow fn name(...)`（**兼容**，
        //   语料 `purity_selftest.cr:231` 用它；文档不写它、也不为它新增用例）。
        // ⚠ 修前此处是 `if !check(T_FN): add_error(...); return` —— 该 `add_error` **不带码**，
        //   而 `run_frontend` 先在 `g_diag_count > 0` 处 `return 1`（main.cr:133-137），
        //   ⇒ 这条理由**永不落到用户眼前**，用户只看到后续的 P25 串（实测 grep 命中 0）。
        //   改动后该分支不存在，问题随之消失（记录在案：那是一次「诊断没到眼前」）。
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

            // Flow function — checker detects yield statements in body
            // to skip return type check (yield != return)

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
                w64(g_structs, si * ESZ_STRUCTINFO + OFF_SI_GENERIC_COUNT, sg_count)
                sgi : ., mut = 0
                loop:
                    if sgi >= sg_count:
                        break
                    unsafe:
                        w64(g_structs, si * ESZ_STRUCTINFO + OFF_SI_GENERIC_NAMES + sgi * 8, str_intern(@str_of(r64(sg_names, sgi * 8))))
                    sgi = sgi + 1
                // R2 P3 Task 5（Step 2）：约束**不再丢弃**（旧态 = 写进 dummy 缓冲后随作用域
                // 消失 ⇒ `struct Box[T: I]` 静默无约束）。登记到 struct 侧表，实例化点
                // （res_type_node 的 EXPR_GENERIC_APPLY 分支）消费。
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
                // 容量批 T3（裁-CAP-2 (a)）：字段**无硬上限**（侧表；第 17 字段起照常写入）
                // ⇒ 旧 P023 闸与槽上限分支一并删除（不再存在越界写对象）。
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
            w64(g_structs, si * ESZ_STRUCTINFO + OFF_SI_FIELD_COUNT, fc)
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
                w64(g_enums, ei * ESZ_ENUMINFO + OFF_EI_GENERIC_COUNT, eg_count)
                egi : ., mut = 0
                loop:
                    if egi >= eg_count:
                        break
                    unsafe:
                        w64(g_enums, ei * ESZ_ENUMINFO + OFF_EI_GENERIC_NAMES + egi * 8, str_intern(@str_of(r64(eg_names, egi * 8))))
                    egi = egi + 1
                // R2 P3 Task 5（Step 2）：同 struct 分支——枚举泛型约束登记（旧态同款丢弃）
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
                // 容量批 T3（裁-CAP-2 (a)）：变体**无硬上限**（侧表）⇒ 旧 P022 闸与槽上限
                // 分支一并删除（不再存在越界写对象）
                ei_set_variant_name(ei, vc, vni)
                tc : ., mut = 0
                if check(T_LPAREN):
                    advance_tok()
                    loop:
                        if check(T_RPAREN):
                            break
                        fty := parse_type()
                        ei_set_variant_type(ei, vc, tc, unpack_type(fty))
                        // R2 P3 Task 4（T0 交接 ①）：载荷类型**节点**随裸码同写（照 struct 的
                        // OFF_SI_FIELD_TYPE_NODES 先例）——裸码把非基型载荷塌缩成 0 = TY_INT，
                        // 节点是载荷面（泛型形参代入 / 满足判定）的唯一忠实来源。
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
            w64(g_enums, ei * ESZ_ENUMINFO + OFF_EI_VARIANT_COUNT, vc)
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
        has_items := expect_region_head()   // 0 = 空 region ⇒ **零方法接口**（合法且有意义）

        // Allocate interface entry
        grow_ifaces(g_iface_count + 1)
        iface_base := g_iface_count * ESZ_IFACEINFO
        // Zero it out
        zi : ., mut = 0
        loop:
            if zi >= ESZ_IFACEINFO:
                break
            w8(g_ifaces, iface_base + zi, 0)
            zi = zi + 1
        w64(g_ifaces, iface_base + OFF_IF_NAME, iface_ni)
        w64(g_ifaces, iface_base + OFF_IF_GENERIC_COUNT, ig_count)
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
                    w64(param_tis, pi2 * 8, TY_UNIT)
                    pi2 = pi2 + 1
                // R2 P3b Task 6（Step 1）：签名**类型节点**槽（与裸码槽并行写，照 struct/enum
                // 的 code+node 双写先例）。self 接收者槽恒无节点（两侧同约定，见 OFF_IFM_SELF_MODE）。
                param_nodes : string, mut
                param_nodes_cap : int, mut
                param_nodes = alloc(128 * 8)
                param_nodes_cap = 128
                pni2 : ., mut = 0
                loop:
                    if pni2 >= 8:
                        break
                    w64(param_nodes, pni2 * 8, -1)
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
                                w64(param_tis, pc * 8, 0)
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
                                w64(param_tis, pc * 8, unpack_type(ptype))
                                w64(param_nodes, pc * 8, ptype)
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
                // D11（T0 布局规格 §2.2）：接口方法**无体**、**无 `:`** ⇒ 收尾 = 行边界（原 `;`）。
                end_decl()

                // Store method in interface entry (with overflow checks)
                // R2 P3b Task 6（Step 1）：上限**显式登记保留**（单源常量 MAX_IFACE_METHODS）——
                // 超限 = 硬错 rc=1（非静默截断），解除面（侧表迁移）见 dyn_arr.cr 常量注。
                if method_count >= MAX_IFACE_METHODS:
                    grow_diags(g_diag_count + 1)
                    w64(g_diags, g_diag_count * DIAG_REC_SIZE, EC_P_FIELD_SYNTAX)
                    store_str_ptr(g_diags, g_diag_count * DIAG_REC_SIZE + 8, "interface '" + iface_name + "' exceeds max 16 methods")
                    w64(g_diags, g_diag_count * DIAG_REC_SIZE + 16, tok_ln(t))
                    w64(g_diags, g_diag_count * DIAG_REC_SIZE + 24, tok_cl(t))
                    w64(g_diags, g_diag_count * DIAG_REC_SIZE + 32, diag_fileid_for_line(tok_ln(t)))
                    g_diag_count = g_diag_count + 1
                else:
                    mbase := iface_base + OFF_IF_METHODS + method_count * ESZ_IFMETHOD
                    w64(g_ifaces, mbase + OFF_IFM_NAME, method_ni)
                    w64(g_ifaces, mbase + OFF_IFM_PARAM_COUNT, pc)
                    w64(g_ifaces, mbase + OFF_IFM_RET_TI, ret_ti)
                    w64(g_ifaces, mbase + OFF_IFM_RET_NODE, ret_node)
                    w64(g_ifaces, mbase + OFF_IFM_SELF_MODE, self_mode)
                    pj : ., mut = 0
                    loop:
                        if pj >= 8 || pj >= pc:
                            break
                        w64(g_ifaces, mbase + OFF_IFM_PARAM_TYPES + pj * 8, r64(param_tis, pj * 8))
                        w64(g_ifaces, mbase + OFF_IFM_PARAM_NODES + pj * 8, r64(param_nodes, pj * 8))
                        pj = pj + 1
                    if pc > 8:
                        grow_diags(g_diag_count + 1)
                        w64(g_diags, g_diag_count * DIAG_REC_SIZE, EC_P_PARAM_TYPE)
                        store_str_ptr(g_diags, g_diag_count * DIAG_REC_SIZE + 8, "method '" + istr_get(method_ni) + "' in interface exceeds max 8 params")
                        w64(g_diags, g_diag_count * DIAG_REC_SIZE + 16, tok_ln(t))
                        w64(g_diags, g_diag_count * DIAG_REC_SIZE + 24, tok_cl(t))
                        w64(g_diags, g_diag_count * DIAG_REC_SIZE + 32, diag_fileid_for_line(tok_ln(t)))
                        g_diag_count = g_diag_count + 1
                method_count = method_count + 1
            else:
                advance_tok()
        w64(g_ifaces, iface_base + OFF_IF_METHOD_COUNT, method_count)
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
                w64(g_methods, g_method_count * 24, type_ni)
                w64(g_methods, g_method_count * 24 + 8, method_ni)
                w64(g_methods, g_method_count * 24 + 16, mangled_ni)
                g_method_count = g_method_count + 1
            else:
                advance_tok()
        if has_items != 0:
            close_region()
        // Store impl-for relationship after processing all methods
        if trait_ni >= 0:
            grow_impl_for(g_impl_for_count + 1)
            w64(g_impl_for, g_impl_for_count * 16, trait_ni)
            w64(g_impl_for, g_impl_for_count * 16 + 8, type_ni)
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
        w64(g_type_aliases, g_type_alias_count * 16, name_idx)
        w64(g_type_aliases, g_type_alias_count * 16 + 8, type_node)
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
        w64(g_mod_path_names, g_mod_path_count * 8, mod_ni)
        g_mod_path_count = g_mod_path_count + 1
        // v4：`mod path` 以行边界收尾；`mod path:` + region 形式**跳过**整段 region 内容。
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
        w64(g_global_lets, g_global_let_count * 8, node)
        g_global_let_count = g_global_let_count + 1
        // Drain batch extras to globals
        _drained : ., mut = 0
        loop:
            if g_extra_let_count <= 0:
                break
            g_extra_let_count = g_extra_let_count - 1
            grow_global_lets(g_global_let_count + 1)
            w64(g_global_lets, g_global_let_count * 8, r64(g_extra_lets, g_extra_let_count * 8))
            g_global_let_count = g_global_let_count + 1
            _drained = _drained + 1
        end_decl()   // v4：全局声明以行边界收尾（原可选 `;` 退场）
        return

    // 批 6（T2）：`#` 出现在**非标注位置**（声明之前 / body 之后 / 顶层任意处）⇒ **响亮拒绝**。
    // 本仓的顶层兜底 = 下方 `advance_tok()`（**静默丢弃一个 token、不报错**）——`#` 走它
    // 就会被逐 token 吞净（T2 首轮实测：`#check(1>0) fn f()…` 与 `… } #check(1>0)` 均 rc=0 +
    // 产物照出）。这与 T0 §10.2 的静默误编译**同源**（`#` 被静默丢弃），必须此点转响亮。
    // 合法位置**唯一** = 签名与 body 之间（parse_spec_annotations，spec-design §四）。
    if check(T_HASH):
        check_error(EC_V_BAD_TAG,
            "'#' annotation is only allowed between the function signature and its body",
            tok_ln(cur_tok()), tok_cl(cur_tok()))
        advance_tok()   // 吞掉 `#` 本身，避免 parse_all 空转；残余由后续解析按既有规则处理
        return
    // 批 8（静默面收口 · 条目 4）：**顶层兜底不再静默吞 token**——修复前此处为裸 `advance_tok()`：
    // 无法识别的顶层 token（typo 的 `stuct` / 多余 `}` / 游离 token）被**无声消费**，既不诊断也不定位；
    // 紧随其后的声明会被误归（计划 §1 条目 4 现象③「静默丢弃 ⇒ 后续 TF01 误报」与条目 6 同族）。
    // 全语料实核（批 8 预备扫描；括号深度感知）：179 档 `.cr` 顶层非法首 token = **0** ⇒ 零语料代价。
    // 先例 = 批 6 T2 的 `#` 非标注位在同一兜底点转响亮（上方 `EC_V_BAD_TAG`）。
    // EOF 不报（`parse_all` 已先判；此处仅为防御），且**必定推进**一个 token（错误恢复）。
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
    // 注意：不再清零 g_error_count——tokenize 阶段（词法守卫，如整数字面量
    // 溢出）已用 add_error 累积错误；parse_all 清零会把它们一并吞掉，
    // 造成「静默越界/静默环绕」类错误永远不报（run_frontend 在 parse_all
    // 之后才检查 g_error_count）。parse 自身的语法错误继续 add_error 追加。
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
        // 顶层行边界（v4，T0 布局规格 §1）：NEWLINE 是 no-op；DEDENT 出现在顶层 = 缩进失衡
        // （lexer 的 layout_break 已报错），此处再给一重带位置的响亮信号，**不静默吞**。
        // ⚠ 本跳过必须出现在**每次** import 消费之后（v4 的 import 声明以行边界收尾，`;` 已退场）
        //   ⇒ 故它同时是下面 import 循环的循环头（否则 import 之后残留的 NEWLINE 会直达
        //   `parse_declaration` 的顶层兜底 = 假 P25 硬错）。
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
            // 批 8（静默面收口 · 条目 4 前置）：**消费整条 import 语句**。
            // 修复前只吞 `import` 关键字本身，其后的路径/别名 token 落进 `parse_declaration` 尾部兜底被
            // **静默吞**——全语料（含 `_import.cr` 与注入的运行时源）普遍如此 ⇒ 条目 4 的顶层硬错若
            // 不先补这里，会把**每一条合法 import** 判成「意外顶层 token」（实测：`import io` 的 `io`）。
            // 形状与 `module.cr` res_imports 的扫描**逐字一致**：`[@proj] [a(::b)*] [: alias] [;]`。
            // ⚠ **不得**放宽成「吞到分号」或「吞任意 IDENT」：那会把紧随其后的下一条声明头也吃掉
            // （本轮实测：`import arena_globals` 后无分号 ⇒ 误吞 `g_rt_argc : int` ⇒ 余下 `mut` 触发 P25）。
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
            // v4：import/fileid 声明末的可选 `;` 退场（T0 布局规格 §6.2 B4）⇒ 收尾 = 行边界。
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
    // 插值洞表达式统一解析（token 流已用毕 ⇒ 可安全重新 tokenize；见 interp_parse_holes）
    interp_parse_holes()
