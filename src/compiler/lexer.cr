// Lexer: tokenizes Core source code using int-based character access.
// Character comparisons use ASCII code constants rather than string allocs.

// Global compiler state
g_source : string, mut
g_source_len : int, mut     // cached str_len(g_source), set in tokenize()
g_pos : int, mut
g_line : int, mut
g_col : int, mut

// ── v4 布局（layout）状态（T5；出处 = 施工计划 §四.1 项 3 + T0 布局规格 §1/§2）──────
// 缩进栈：**空栈起**，由首个非空行的首个 token 建立基准 anchor（规格 §1.1 ①-1 第 3 条）
// —— 基准层不出 INDENT/DEDENT，故它**在栈里占一层**（栈长 >= 1 表示已建基）。
g_indent_stack : string, mut
g_indent_cap : int, mut
g_indent_len : int, mut
// 括号/花括号深度：>0 时**不参与布局**（隐式续行）。`{ }` 一并计入 ⇒
// 结构体字面量内部不产生 layout（规格 §4.1「字面量内部不参与 layout region」）。
g_bracket_depth : int, mut
// 当前逻辑行是否已产出 token（决定换行时是否发 NEWLINE；纯空行/纯注释行不发）。
g_line_has_token : int, mut
// 上一个「属于某个 token」的物理行号——换行判定用（比跨行空白标志更稳）。
g_last_tok_line : int, mut
// 布局旁路旗标（T0 布局规格 §5.2）：0 = 发射 INDENT/DEDENT（默认，fail-closed）；
// 1 = **不发射，且不读不写缩进栈**。凡「调用后 token 流不由 parse_all/parse_expr 消费」
// 的 tokenize() 调用点必须置 1（洞内重入 / 转储 / 自测 / LSP 分析）。
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
    w64(g_errors, g_error_count * 8, mi)
    g_error_count = g_error_count + 1

fn cur_char() -> int:
    // Use str_len(g_source) instead of g_source_len to avoid
    // global variable patching bug in self-hosted ELF backend.
    // g_source_len is stored to a wrong BSS address in tokenize(),
    // causing cur_char() to always see it as 0 (EOF).
    src_len := str_len(g_source)
    if g_pos >= src_len:
        return 0
    return load8(g_source, g_pos)

fn peek() -> int:
    src_len := str_len(g_source)
    if g_pos + 1 >= src_len:
        return 0
    return load8(g_source, g_pos + 1)

fn cur_char_at(src: string, pos: int, max_len: int) -> int:
    if pos >= max_len:
        return 0
    return load8(src, pos)
fn peek_at(src: string, pos: int, max_len: int) -> int:
    if pos + 1 >= max_len:
        return 0
    return load8(src, pos + 1)

fn lookup_keyword(s: string) -> int:
    if s == "fn":
        return T_FN
    if s == "mut":
        return T_MUT
    if s == "return":
        return T_RETURN
    if s == "if":
        return T_IF
    if s == "else":
        return T_ELSE
    if s == "loop":
        return T_LOOP
    if s == "while":
        return T_WHILE
    if s == "for":
        return T_FOR
    if s == "break":
        return T_BREAK
    if s == "continue":
        return T_CONTINUE
    if s == "true":
        return T_TRUE
    if s == "false":
        return T_FALSE
    if s == "struct":
        return T_STRUCT
    if s == "enum":
        return T_ENUM
    if s == "extern":
        return T_EXTERN
    if s == "impl":
        return T_IMPL
    if s == "match":
        return T_MATCH
    if s == "import":
        return T_IMPORT
    if s == "pub":
        return T_PUB
    if s == "go":
        return T_GO
    if s == "await":
        return T_AWAIT
    if s == "unsafe":
        return T_UNSAFE
    if s == "flow":
        return T_FLOW
    if s == "yield":
        return T_YIELD
    if s == "interface":
        return T_INTERFACE
    if s == "type":
        return T_TYPE
    if s == "mod":
        return T_MOD
    if s == "as":
        return T_AS
    if s == "auto":
        return T_AUTO
    if s == "fileid":
        return T_FILEID
    // v4（T5，施工计划 §四.1 项 7/8）：36 → 39。去 `None`/`Some`/`move`
    // （前二者退役为普通标识符——`Some(x)` 仍经 parse_postfix 的「首字母大写 ⇒
    // 枚举构造器」分支解，与 bootstrap 侧同判；`move` 退场），加
    // `catch`/`dyn`/`fail`/`never`/`none`/`spec`。逐元素目标 = bootstrap/corec/syntax/tokens.py 的 KEYWORDS。
    if s == "self":
        return T_SELF
    if s == "in":
        return T_IN
    if s == "unit":
        return T_UNIT
    if s == "none":
        return T_NONE
    if s == "never":
        return T_NEVER
    if s == "dyn":
        return T_DYN
    if s == "catch":
        return T_CATCH
    if s == "fail":
        return T_FAIL
    if s == "spec":
        return T_SPEC
    return T_IDENT

// 2^k（纯整数，k >= 0）
fn pow2i(k: int) -> int:
    v : int = 1
    i : ., mut = 0
    loop:
        if i >= k:
            break
        v = v * 2
        i = i + 1
    return v

// decimal string → IEEE 754 binary64 位模式（纯整数近似，≤18 位有效数字）
// 实现：value = ip + fp/den → 整数部分位 + 64 位长除小数 → 53 位尾数窗口
// 精度：截断（无舍入），≤18 位有效数字内 ~2ulp
fn str_to_f64_bits(s: string) -> int:
    sl := str_len(s)
    i : ., mut = 0
    neg : int = 0
    if i < sl && load8(s, i) == 45:
        neg = 1
        i = i + 1
    ip : int = 0
    fp : int = 0
    den : int = 1
    sd : int = 0
    ip_digits : ., mut = 0
    fp_digits : ., mut = 0
    too_wide : ., mut = 0
    loop:
        if i >= sl:
            break
        c := load8(s, i)
        if c == 46:
            sd = 1
            i = i + 1
            continue
        if c < 48 || c > 57:
            break
        if sd != 0:
            fp_digits = fp_digits + 1
            if fp_digits <= 18:
                fp = fp * 10 + (c - 48)
                den = den * 10
        else:
            ip_digits = ip_digits + 1
            if ip_digits <= 19:
                digit_ip := c - 48
                if ip > 922337203685477580 || (ip == 922337203685477580 && digit_ip > 7 + neg):
                    too_wide = 1
                else:
                    ip = ip * 10 + digit_ip
            else:
                too_wide = 1
        i = i + 1
    if too_wide != 0:
        add_error("decimal literal integer part is too wide")
        return 0
    if ip == 0 && fp == 0:
        if neg != 0:
            return (-9223372036854775807 - 1)
        return 0
    // 小数 64 位（长除：r=fp，每轮 r×2 vs den）
    frac64 : int = 0
    r : ., mut = fp
    bits : ., mut = 0
    loop:
        if bits >= 64:
            break
        if r >= 4611686018427387904:
            r = r / 2
            den = den / 2
        r = r * 2
        frac64 = frac64 * 2
        if r >= den:
            r = r - den
            frac64 = frac64 + 1
        bits = bits + 1
    // 整数部分位宽
    bi : ., mut = 0
    t2 : ., mut = ip
    loop:
        if t2 == 0:
            break
        t2 = t2 / 2
        bi = bi + 1
    mant : int = 0
    exp : int = 0
    if bi > 0:
        sh := 53 - bi
        if sh >= 0:
            mant = (ip * pow2i(sh)) + (frac64 / pow2i(64 - sh))
        else:
            // Avoid pow2i of a negative value for integer parts wider than
            // the binary64 significand.
            mant = ip / pow2i(0 - sh)
        exp = 1023 + (bi - 1)
    else:
        // 纯小数：frac64 的最高位
        bf : ., mut = 0
        t2 = frac64
        loop:
            if t2 == 0:
                break
            t2 = t2 / 2
            bf = bf + 1
        if bf == 0:
            if neg != 0:
                return (-9223372036854775807 - 1)
            return 0
        sh := 53 - bf
        if sh >= 0:
            mant = frac64 * pow2i(sh)
        else:
            mant = frac64 / pow2i(-sh)
        exp = 1023 + (bf - 65)
    // 组装（mant 截断到 52 位——无舍入）
    bits64 : int = 0
    if exp > 0 && exp < 2047:
        bits64 = (mant % 4503599627370496) + exp * 4503599627370496
    if neg != 0:
        bits64 = bits64 + (-9223372036854775807 - 1)
    return bits64

// Parse an integer literal after tokenization. Supports decimal separators
// and 0x/0o/0b prefixes; out-of-shape literals are rejected as lexer errors.
// 层语义（int-unbounded-semantics 定稿）：语言 int = 无上限数学整数——本守卫报的
// 「integer literal overflow」是编码层限制错误（编译器内部表示 = 经典 64 位机器字
// 投影，超形状 = 该投影无载体），不是语义溢出事件——语义层无溢出概念。表示升级
// （扩展/多字）为 hw-map/远期事项，见 specs/2026-09-06-int-unbounded-semantics.md。
fn str_int_literal(s: string) -> int:
    sl := str_len(s)
    base : ., mut = 10
    start : ., mut = 0
    if sl >= 2 && load8(s, 0) == 48:
        pfx := load8(s, 1)
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
        c := load8(s, i)
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
        // 溢出守卫按 base 校准：固定 i64max/10 阈值只对十进制有效——base 16
        // 累积值在最后一次 ×16 直接环绕（0x8000000000000000 → i64min 绕开守卫）。
        // 阈值必须 = i64max/base（base 10 的末位 d>7 边界保持）。
        if base == 10:
            if value > 922337203685477580 || (value == 922337203685477580 && d > 7):
                add_error("integer literal overflow")
                return 0
        else if base == 16:
            if value > 576460752303423487:
                add_error("integer literal overflow")
                return 0
        else if base == 8:
            if value > 1152921504606846975:
                add_error("integer literal overflow")
                return 0
        else:
            if value > 4611686018427387903:
                add_error("integer literal overflow")
                return 0
        value = value * base + d
        digits = digits + 1
        i = i + 1
    if digits == 0:
        add_error("integer literal requires digits")
        return 0
    return value

// decimal string → 定点缩放整数（数值迁移 Task 4：dex 精确字面量解析）
// S = 10^6（6 位小数）。整数部分 × S + 小数 6 位；第 7 位小数起四舍五入（半进，
// 与 float_str_bits 的舍入规则一致）。负号直接处理（'-' 前缀）。
// 溢出：|整数部分| ≤ 9.2e12（×S 越界 = 环绕，与 int 溢出一致——文档化限制）。
fn str_to_scaled(s: string) -> int:
    sl := str_len(s)
    i : ., mut = 0
    neg : int = 0
    if i < sl && load8(s, i) == 45:
        neg = 1
        i = i + 1
    ip : int = 0
    fp : int = 0
    nd : int = 0
    sd : int = 0
    round_up : int = 0
    loop:
        if i >= sl:
            break
        c := load8(s, i)
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
    // 小数位补齐到 6 位：fp 是原始数字（如 "3.14" → 14），×10^(6-nd)
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

fn add_tok(kind: int, lex: int, start_line: int, start_col: int):
    grow_tokens(g_token_count + 1)
    tp := g_token_count * ESZ_TOKEN
    w64(g_tokens, tp + OFF_TK_KIND, kind)
    w64(g_tokens, tp + OFF_TK_LEXEME, lex)
    w64(g_tokens, tp + OFF_TK_INTVAL, 0)
    w64(g_tokens, tp + OFF_TK_LINE, start_line)
    w64(g_tokens, tp + OFF_TK_COL, start_col)
    g_token_count = g_token_count + 1

fn add_tok_int(kind: int, ival: int, start_line: int, start_col: int):
    grow_tokens(g_token_count + 1)
    tp := g_token_count * ESZ_TOKEN
    w64(g_tokens, tp + OFF_TK_KIND, kind)
    w64(g_tokens, tp + OFF_TK_LEXEME, -1)
    w64(g_tokens, tp + OFF_TK_INTVAL, ival)
    w64(g_tokens, tp + OFF_TK_LINE, start_line)
    w64(g_tokens, tp + OFF_TK_COL, start_col)
    g_token_count = g_token_count + 1

fn add_tok_str(kind: int, s: string, start_line: int, start_col: int):
    grow_tokens(g_token_count + 1)
    tp := g_token_count * ESZ_TOKEN
    w64(g_tokens, tp + OFF_TK_KIND, kind)
    si := str_intern(s)
    w64(g_tokens, tp + OFF_TK_LEXEME, si)
    w64(g_tokens, tp + OFF_TK_INTVAL, 0)
    w64(g_tokens, tp + OFF_TK_LINE, start_line)
    w64(g_tokens, tp + OFF_TK_COL, start_col)
    g_token_count = g_token_count + 1

// int_val + lexeme 双载令牌（dex 字面量用：int_val = 缩放整数，lexeme = 原数字串）
fn add_tok_int_lex(kind: int, ival: int, lexeme_ni: int, start_line: int, start_col: int):
    grow_tokens(g_token_count + 1)
    tp := g_token_count * ESZ_TOKEN
    w64(g_tokens, tp + OFF_TK_KIND, kind)
    w64(g_tokens, tp + OFF_TK_LEXEME, lexeme_ni)
    w64(g_tokens, tp + OFF_TK_INTVAL, ival)
    w64(g_tokens, tp + OFF_TK_LINE, start_line)
    w64(g_tokens, tp + OFF_TK_COL, start_col)
    g_token_count = g_token_count + 1

// ── v4 布局（layout）机件（T5；判定出处 = T0 布局规格 §1/§2）──────────────────────
// 实现约束（规格 §2.3，写死）：判定 ① 的 anchor 计算与判定 ② 的行尾判定**必须共用同一个**
// 注释/字符串感知扫描器——两处各写一份必然漂。故本区**只有** `layout_skip_blank` 一份
// 「跳过空白与注释」的实现：`colon_at_line_end`（只读前瞻）建在它之上。

// 从 idx 起跳过空白与注释（`//` 行注释 · 可跨行 `/* */` 块注释）。
// 返回 (新下标, 是否跨过至少一个物理行边界) —— 二元返回用 out 参数编码：
// 返回值为新下标，跨行标志写进 g_layout_saw_nl（**调用方须在读前清零**，同款先例 = 仓内
// 「一次调用一次用」的临时全局；不引入元组类型）。
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

// 裁定 ②（词法位置决定，T0 布局规格 §2.1/§2.3）：`:` **是行尾的** ⟺ 该 `:` 之后、
// 到该**物理行行尾**为止，**不存在任何 token**（空白不计 · 注释不计 ⇒ §2.3 的四格：
// `// note` / `/* note */` / 跨行块注释都判**行尾**；`x : int = 5 // note` 判**行内**）。
// 调用点保证 pos 正好在 `:` **之后**。
fn colon_at_line_end(src: string, pos: int, max_len: int) -> int:
    i := layout_skip_blank(src, pos, max_len)
    if g_layout_saw_nl != 0:
        // 跨过行边界（含跨行块注释）⇒ 本物理行 `:` 之后已无余物
        return 1
    if i >= max_len:
        return 1
    return 0

fn ind_top() -> int:
    return r64(g_indent_stack, (g_indent_len - 1) * 8)

fn ind_push(col: int):
    if g_indent_len >= g_indent_cap:
        ncap : ., mut = g_indent_cap * 2
        if ncap < 16:
            ncap = 16
        nv := alloc(ncap * 8)
        if g_indent_cap > 0:
            _dyncpy(g_indent_stack, g_indent_cap * 8, nv)
        g_indent_stack = nv
        g_indent_cap = ncap
    w64(g_indent_stack, g_indent_len * 8, col)
    g_indent_len = g_indent_len + 1

// 越过物理行边界（且不在括号内）时，发出 NEWLINE 与 INDENT/DEDENT。
// 判定出处：§1.1 ①-1/①-2（空行与只含注释的行**不产生 token**、不改变 anchor，
// 故调用点只在「上一逻辑行确实产出过 token」时才进来）；①-3（anchor 列 ≡ 该行
// **首个 token** 的列，由 advance 的既有列维护给出）；①-1 第 3 条（首个非空行建基）。
fn layout_break():
    add_tok(T_NEWLINE, -1, g_line, g_col)
    g_line_has_token = 0
    col := g_col
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
                // 「比单元基准锚点更浅」——T0 §6.1 A2 定义的那个 layout 错误
                add_error("layout anchor " + int_str(col) + " is shallower than the unit base anchor " + int_str(ind_top()))
            else:
                // 不匹配任何外层列 ⇒ 响亮报错（**不得**静默对齐到最近一层——那是猜）
                add_error("inconsistent dedent: column " + int_str(col) + " matches no open indent level")

// 源尾收尾：补发最后一个 NEWLINE，并弹出全部未闭合的缩进层（各发一个 DEDENT）。
// 基准层（栈底 = 首行 anchor）**不发 DEDENT**——它没有对应的 INDENT。
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

// 第二形参 = 布局旁路旗标（T0 布局规格 §5.2）：0 = 发射 INDENT/DEDENT（默认，fail-closed）；
// 1 = **不发射，且不读不写缩进栈**。**显式形参**而非纯全局：判据 J-T0-5 的零构建半读
// call site 原文，要求旁路在**调用点可见**（隐含全局会被读成「视情况」）。
// 规则（可机械判定）：一个调用点必须传 1 ⟺ 该调用之后、在同一控制流里该 token 流**不由**
// `parse_all` / `parse_expr` 消费（⟺ 只做转储、重扫、自测、LSP 分析，或是重入路径）。
fn tokenize(_src: string, layout_bypass: int):
    g_layout_bypass = layout_bypass
    g_token_count = 0
    // 注意：不再清零 g_error_count——res_imports 会重 tokenize（拼接 import
    // 前后两轮），清零会把首轮词法守卫错误（整数字面量溢出等）吞掉。错误
    // 清理由 run_frontend 会话起点负责（错误累积跨多轮 tokenize）。
    _pos : ., mut = 0
    g_pos = 0
    g_line = 1
    g_col = 1
    // v4 布局状态复位（T0 布局规格 §5.2）：旁路时不读不写缩进栈 —— 只清零记账量。
    g_indent_len = 0
    g_bracket_depth = 0
    g_line_has_token = 0
    g_last_tok_line = 0
    _slen : ., mut = str_len(_src)
    _pos = skip_ws(_src, _pos, _slen)

    loop:
        // 先吃掉**注释与其后的空白/空行**，使下面的「行首」判定落在**真 token** 上。
        // 为什么必须先吃（判定 ①-2 的机械实现）：纯空行与纯注释行是 no-op（不产生 token、
        // 不改变 anchor）。若在注释字符处判行首，会把**注释的列**当 anchor ⇒ 一行行尾注释
        // 后接一行缩进注释就会伪造 INDENT（实测：本仓 ast.cr 的 `TY_DEX_S : int = 8  // …`
        // 续行注释触发 INDENT(22)）。bootstrap 的 `skip_whitespace_and_comments` 把注释
        // 收在其内部，故天然没有这一格 ⇒ 本循环照同一语义重组（**不是**另写一份判定）。
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
        // 布局发射（判定出处 = T0 布局规格 §1/§2）：
        //  - 只在括号外（`()`/`[]`/`{}` 内是隐式续行，不参与 layout）；
        //  - 只在「上一逻辑行确实产出过 token」时发 NEWLINE ⇒ 纯空行与纯注释行天然成为
        //    no-op（规格 ①-1/①-2）；
        //  - anchor 列 = 本 token 的列（规格 ①-3），由 skip_ws 的既有列维护给出；
        //  - 旁路旗标（g_layout_bypass）置位时整段跳过（洞内重入 / 转储 / 自测 / LSP）。
        if g_layout_bypass == 0:
            if g_bracket_depth == 0 && g_line_has_token != 0 && g_line != g_last_tok_line:
                layout_break()
            g_line_has_token = 1
            g_last_tok_line = g_line
            if g_indent_len == 0:
                // ①-1 第 3 条：**首个非空行建立 anchor**（该行的首个 token 即基准列）。
                // 基准层不发 INDENT —— 否则顶层代码会整体被多包一层。
                ind_push(g_col)
        c := cur_char_at(_src, _pos, _slen)
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
                // 三条进制前缀循环均**不再接受** '_'（2026-09-10 语言面收窄 §2）：
                // 遗留 '_' 由下方后缀段落统一响亮报错（不静默消费）。
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
            // Float: only consume the '.' when it does not start a '..'
            // range operator (otherwise `0..4` lexes as `0.` `.4` and the
            // range is silently lost — the for-loop body never executes).
            has_dot : ., mut = 0
            if cur_char_at(_src, _pos, _slen) == 46 && peek_at(_src, _pos, _slen) != 46:
                _pos = _pos + 1
                has_dot = 1
                loop:
                    if is_digit(cur_char_at(_src, _pos, _slen)) != 0:
                        _pos = _pos + 1
                    else:
                        break
            // 数字词法收窄（2026-09-10 用户裁决，语言面收窄 §2）：`_` 分隔符与宽度后缀
            // （f32/f64/i8..u64）**均不支持**——一律响亮报错且**不消费**残余字符
            // （按标识符继续 tokenize，使后续解析给出第二重信号，不静默、不猜）。
            // 修复前：`_` 被 is_alpha(95) 当后缀静默消费 → T_INT 取「无值」= 0
            // （`x := 1_000` 静默成 0 = 实质误编译）；宽度后缀同样静默丢弃。
            sx := cur_char_at(_src, _pos, _slen)
            if sx == 95:
                add_error("invalid character '_' in numeric literal (digit separators not supported)")
            else if is_alpha(sx) != 0:
                add_error("invalid suffix on numeric literal (width suffixes retired 2026-09-10)")
            num_str := str_sub(_src, start, _pos - start)
            // dex 字面量（含小数点）：int_val = 定点缩放整数（精确解析，数值迁移
            // Task 4——十进制 → 缩放整数，非二进制近似）；lexeme 槽 = 原数字串
            // （parser 在 apx 场景需要 binary64 位模式：str_to_f64_bits(num_str)）。
            if has_dot != 0:
                add_tok_int_lex(T_DEX, str_to_scaled(num_str), str_intern(num_str), start_line, start_col)
            else:
                add_tok_int(T_INT, str_int_literal(num_str), start_line, start_col)
            _pos = skip_ws(_src, _pos, _slen)
            continue

        // 字符串字面量（含 `${...}` 插值）。含插值的字面量**分段发 token**：段 = T_STRING、洞 = T_INTERP，
        // 由 parser 组装为 `seg + conv(hole)` 链、checker 按洞类型就地改写转换（见 ast.cr EXPR_INTERP_HOLE）。
        // **无洞字面量与旧实现逐字相同**（单个 T_STRING、同 line/col、iv=0）⇒ 产物零足迹。
        if c == 34:
            _pos = _pos + 1
            sp : ., mut = _pos                     // 串内容起点（同行内换算列；串内不跨行）
            seg_pos : ., mut = sp                  // 当前段起点
            run_start : ., mut = g_token_count     // 本字面量首 token（末尾回填 iv）
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
                    // ── 插值洞 `${...}` ────────────────────────────────────────────
                    // 扫描 = **花括号配平**（`${S{f=1}}` 取到配对 `}`；旧「跳至首个 `}`」规则会截断），
                    // 洞内字符串字面量（含转义）整体跳过；换行/EOF 终止 ⇒ 未闭合由 parser 报 P027。
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
                        // 洞内 **char 字面量** 整体跳过（`'{'` 里的 `{` 不得参与配平——对抗复核点名的漏点①）
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
                        // 洞内 **行注释** 整体跳过（漏点②）
                        if hc == 47 && cur_char_at(_src, hp + 1, _slen) == 47:
                            loop:
                                cc3 := cur_char_at(_src, hp, _slen)
                                if cc3 == 0 || cc3 == 10:
                                    break
                                hp = hp + 1
                            continue
                        // 洞内 **块注释** 整体跳过（漏点③）
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
                    w64(g_tokens, ti * ESZ_TOKEN + OFF_TK_INTVAL, cflag)
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
                // 回填 run 内各 part 的 iv：+1 = 属插值字面量 · +2 = 其后还有 part（洞闭合位 4 保留）。
                // ⚠ 用加法不用按位或：**bootstrap 后端不支持 `|`/`&`**（`NotImplementedError: Binary op |`，实测）。
                // 目的：parser 只把**同一字面量**的 part 连成一条链（`"${x}" "y"` 是两个字面量，不连）。
                ri : ., mut = run_start
                loop:
                    if ri >= g_token_count:
                        break
                    iv : ., mut = r64(g_tokens, ri * ESZ_TOKEN + OFF_TK_INTVAL)
                    iv = iv + 1
                    if ri + 1 < g_token_count:
                        iv = iv + 2
                    w64(g_tokens, ri * ESZ_TOKEN + OFF_TK_INTVAL, iv)
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
        // v4 单竖线（T5）：原代码**无此分支** ⇒ 裸 `|` 落 Unknown 分支被静默丢弃。
        // v4 的 match 臂前缀 = `|`（docs/core-language-syntax_v4.md 的 match 例）⇒ 显式收下。
        // 零足迹依据：全仓 `src/**` 的裸 `|` **零处**（注释/字符串内的 `|` 不达本行）。
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
        // 括号深度（T0 布局规格 §4.1）：`( ) [ ] { }` **都计入** ⇒ 括号内是隐式续行、
        // 不发 layout；`{ }` 一并计入 ⇒ 结构体字面量内部不产生 layout region。
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
            // 裁定 ②（词法位置决定，T0 布局规格 §2.1）：行尾 `:` ⇒ T_COLON_BLOCK（region 开启）；
            // 行内 `:` ⇒ T_COLON_DECL（类型标注 / import 别名 / 字段 / 形参 / 泛型约束分隔符）。
            // 二者互斥且穷尽 ⇒ parser 侧零前瞻。`:=` / `::` 已在上方多字符分支消费，**不受影响**。
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
        // 批 6（T1 词法面）：`#` = 规约标注 sigil（`#check(expr)` / `#ensure(expr)` 的首字符）。
        // **有意的行为变更**：修复前 `#` 走下方 Unknown 分支被**静默丢弃**（本函数尾），
        // 带标注的源会被 parse_body 误解析成静默错产物（T0 §10.2 实测：build rc=0 + 运行返回错值）。
        // 零足迹依据（T0 实测）：全仓 182 个 .cr 的**裸 `#` = 0**（注释/字符串内的 `#` 不达本行）
        // ⇒ 本分支对既有语料**构造性零扰动**。后随字符由 parser 校验（必须 IDENT）。
        if c == 35:
            _pos = _pos + 1
            add_tok(T_HASH, -1, start_line, start_col)
            _pos = skip_ws(_src, _pos, _slen)
            continue

        // Unknown
        _pos = _pos + 1
        _pos = skip_ws(_src, _pos, _slen)

    // 源尾收尾（T0 布局规格 §1）：补发末行 NEWLINE + 弹出全部未闭合缩进层（各一个 DEDENT）。
    // 旁路时同样不发射（不读不写缩进栈）。
    if g_layout_bypass == 0:
        finish_layout()
    add_tok(T_EOF, -1, g_line, g_col)
    // Sync back globals
    g_pos = _pos
    g_source_len = _slen
