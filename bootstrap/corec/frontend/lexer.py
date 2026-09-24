from corec.syntax.tokens import Token, TokenType, KEYWORDS

class Lexer:
    def __init__(self, source: str, filename: str = "<unknown>"):
        self.source = source
        self.filename = filename
        self.pos = 0
        self.line = 1
        self.col = 1
        self.tokens = []
        # ── v4 布局状态（施工计划 §四.1 项 3；判定出处 = T0 布局规格 §1/§2）──
        # 缩进栈：**空栈起**，由首个非空行的首个 token 建立基准 anchor（规格 §1.1 ①-1 第 3 条）
        # —— 基准层不出 INDENT/DEDENT，故它不在栈里占一层。
        self.indent_stack = []
        # 括号/花括号深度：>0 时**不参与布局**（隐式续行）。`{ }` 一并计入 ⇒
        # 结构体字面量内部不产生 layout（规格 §4.1「字面量内部不参与 layout region」）。
        self.bracket_depth = 0
        # 当前逻辑行是否已产出 token（决定换行时是否发 NEWLINE；纯空行/纯注释行不发）。
        self.line_has_token = False
        # 上一个「属于某个 token」的物理行号 —— 换行判定用（比跨行空白标志更稳）。
        self.last_tok_line = 0

    def current(self) -> str:
        if self.pos < len(self.source):
            return self.source[self.pos]
        return '\0'

    def advance(self):
        ch = self.current()
        self.pos += 1
        if ch == '\n':
            self.line += 1
            self.col = 1
        else:
            self.col += 1
        return ch

    def peek(self, offset: int = 1) -> str:
        idx = self.pos + offset
        if idx < len(self.source):
            return self.source[idx]
        return '\0'

    # ── v4 布局（layout）：共享扫描器 + 发射 ──────────────────────────────
    # 实现约束（T0 布局规格 §2.3，写死）：判定 ① 的 anchor 计算与判定 ② 的
    # 行尾判定**必须共用同一个**注释/字符串感知扫描器——两处各写一份必然漂。
    # ⇒ 本类里注释/空白的跳过**只有** `_scan_blank_comment` 一个实现：
    #    `skip_whitespace_and_comments`（改写 self.pos）与 `_colon_is_line_end`
    #    （只读前瞻，不动状态）都建在它之上。
    def _scan_blank_comment(self, idx: int):
        """从 idx 起跳过空白与注释（`//` 行注释 · `/* */` 块注释，**可跨行**）。

        不识别字符串字面量 —— 字符串是 **token**，两个调用方都在「遇真字符即停」的
        语义下使用本函数，故无需（也不应）在此吞掉字符串。
        返回 `(新下标, 是否跨过至少一个物理行边界)`。**纯函数**：不读不写实例状态。
        """
        src = self.source
        n = len(src)
        saw_nl = False
        while idx < n:
            ch = src[idx]
            if ch in ' \t\r':
                idx += 1
            elif ch == '\n':
                saw_nl = True
                idx += 1
            elif ch == '/' and idx + 1 < n and src[idx + 1] == '/':
                while idx < n and src[idx] != '\n':
                    idx += 1
            elif ch == '/' and idx + 1 < n and src[idx + 1] == '*':
                idx += 2
                while idx < n and not (src[idx] == '*' and idx + 1 < n and src[idx + 1] == '/'):
                    if src[idx] == '\n':
                        saw_nl = True
                    idx += 1
                idx = min(idx + 2, n)
            else:
                break
        return idx, saw_nl

    def skip_whitespace_and_comments(self):
        target, _ = self._scan_blank_comment(self.pos)
        while self.pos < target:
            self.advance()

    def _colon_is_line_end(self) -> bool:
        """裁定 ②（词法位置决定，T0 布局规格 §2.1/§2.3）：

        `:` **是行尾的** ⟺ 该 `:` 之后、到该物理行行尾为止，**不存在任何 token**
        （空白不计 · 注释不计 ⇒ §2.3 的四格：`// note` / `/* note */` / 跨行块注释
        都判**行尾**；`x : int = 5 // note` 判**行内**）。
        调用点保证 `self.pos` 正好在 `:` 之后。
        """
        idx, saw_nl = self._scan_blank_comment(self.pos)
        if saw_nl:
            # 跨过行边界（含跨行块注释）⇒ 本物理行 `:` 之后已无余物
            return True
        # 未跨行 ⇒ 要么撞上真字符（行内），要么到了源尾（行尾）
        return idx >= len(self.source)

    def _layout_break(self):
        """越过物理行边界（且不在括号内）时，发出 NEWLINE 与 INDENT/DEDENT。

        判定出处（T0 布局规格）：§1.1 ①-1/①-2 —— 空行与只含注释的行**不产生 token**、
        不改变 anchor（故本函数只在「上一逻辑行确实产出了 token」时被调用，见 `tokenize`）；
        §1.1 ①-3 —— anchor 列 ≡ 该行**首个 token** 的列（不是注释的列，也不是行首空白宽度）；
        ①-1 第 3 条 —— **首个非空行建立 anchor**（故本层不发 INDENT，基准由首行给定，
        与 `tools/v4_layout_probe.py` 的布局模型逐条同构：栈空 ⇒ 建基）。
        """
        self.tokens.append(Token(TokenType.NEWLINE, '', self.line, self.col))
        self.line_has_token = False
        col = self.col
        top = self.indent_stack[-1]
        if col > top:
            self.indent_stack.append(col)
            self.tokens.append(Token(TokenType.INDENT, '', self.line, col))
        elif col < top:
            while len(self.indent_stack) > 1 and self.indent_stack[-1] > col:
                self.indent_stack.pop()
                self.tokens.append(Token(TokenType.DEDENT, '', self.line, col))
            if self.indent_stack[-1] != col:
                if len(self.indent_stack) == 1:
                    # 「比单元基准锚点更浅」——正是 T0 §6.1 A2 定义的那个 layout 错误
                    self.error("layout anchor %d is shallower than the unit base anchor %d"
                               % (col, self.indent_stack[-1]))
                # 不匹配任何外层列 ⇒ 响亮报错（**不得**静默对齐到最近一层——那是猜）
                self.error("inconsistent dedent: column %d matches no open indent level" % col)

    def _finish_layout(self):
        """源尾收尾：补发最后一个 NEWLINE，并弹出全部未闭合的缩进层（各发一个 DEDENT）。

        基准层（栈底 = 首行 anchor）**不发 DEDENT** —— 它没有对应的 INDENT。
        """
        if self.line_has_token:
            self.tokens.append(Token(TokenType.NEWLINE, '', self.line, self.col))
            self.line_has_token = False
        while len(self.indent_stack) > 1:
            self.indent_stack.pop()
            self.tokens.append(Token(TokenType.DEDENT, '', self.line, self.col))

    def read_string(self, quote: str) -> Token:
        start_line, start_col = self.line, self.col
        self.advance()
        s = ""
        while self.current() != quote and self.current() != '\0':
            if self.current() == '\\':
                self.advance()
                esc = self.advance()
                if esc == 'n': s += '\n'
                elif esc == 't': s += '\t'
                elif esc == 'r': s += '\r'
                elif esc == '0': s += '\0'
                elif esc == '\\': s += '\\'
                elif esc == '"': s += '"'
                elif esc == '\'': s += '\''
                elif esc == 'x':
                    h = self.advance() + self.advance()
                    s += chr(int(h, 16))
                else:
                    s += esc
            else:
                s += self.advance()
        if self.current() == '\0':
            self.error("Unterminated string literal")
        self.advance()
        tok_type = TokenType.STRING_LIT if quote == '"' else TokenType.CHAR_LIT
        return Token(tok_type, s, start_line, start_col)

    def read_number(self, first: str) -> Token:
        start_line, start_col = self.line, self.col
        n = first
        base = 10
        is_prefixed = False
        if first == '0' and self.current() in 'xXoObB':
            prefix = self.advance()
            n += prefix
            base = {'x': 16, 'X': 16, 'o': 8, 'O': 8,
                    'b': 2, 'B': 2}[prefix]
            is_prefixed = True
        is_float = False
        if is_prefixed:
            digits = '0123456789abcdefABCDEF' if base == 16 else (
                '01234567' if base == 8 else '01')
            while self.current() in digits:
                c = self.current()
                if c in digits:
                    n += self.advance()
                else:
                    break
            # 数字词法收窄（2026-09-10 语言面收窄 §2）：'_' 分隔符不支持——响亮报错，
            # 不再消费（与 self-hosted lexer 同款；修复前被静默并入词素）。
            if self.current() == '_':
                self.error("invalid character '_' in numeric literal (digit separators not supported)")
            if n[-1] in 'xXoObB' or not any(c != '_' for c in n[2:]):
                self.error("invalid integer literal")
            if self.current().isalnum() or self.current() == '_':
                self.error("invalid digit in integer literal")
        else:
            while self.current().isdigit():
                n += self.advance()
            if self.current() == '_':
                self.error("invalid character '_' in numeric literal (digit separators not supported)")
            if self.current() == '.' and self.peek().isdigit():
                is_float = True
                n += self.advance()
                while self.current().isdigit():
                    n += self.advance()
                if self.current() == '_':
                    self.error("invalid character '_' in numeric literal (digit separators not supported)")
            if self.current().isalpha():
                # 宽度后缀退役（2026-09-10 语言面收窄 §2）——与 self-hosted lexer 同款
                # 响亮报错；此前后缀被并入词素（'10f32'）→ parser int() 抛 ValueError。
                self.error("invalid suffix on numeric literal (width suffixes retired 2026-09-10)")
        n = n.replace('_', '')
        # 前缀进制（0x/0o/0b）整数字面量超形状拒绝——与 self-hosted lexer 的
        # base 校准守卫一致（P2）。层语义（int-unbounded-semantics 定稿）：
        # 语言 int = 无上限数学整数，本守卫是编码层限制错误（本编译器内部
        # 表示 = 经典 64 位机器字投影；超形状 = 该投影无载体），非语义溢出。
        # 十进制保持原样词法（Python int 任意精度 = 同语义的另一份投影实例）：
        # self-hosted 对十进制幅值边界有既有处理（-9223372036854775808），
        # 不一致处理——两编译器差异 = 各自投影形状差异，非语义分歧。
        if is_prefixed:
            val = int(n[2:], base)
            if val > 9223372036854775807:
                self.error("integer literal overflow")
            return Token(TokenType.INT_LIT, str(val), start_line, start_col)
        if is_float:
            return Token(TokenType.FLOAT_LIT, n, start_line, start_col)
        return Token(TokenType.INT_LIT, n, start_line, start_col)

    def read_ident(self, first: str) -> Token:
        start_line, start_col = self.line, self.col
        ident = first
        while self.current().isalnum() or self.current() == '_' or self.current() == '\'':
            ident += self.advance()
        if ident in KEYWORDS:
            return Token(KEYWORDS[ident], ident, start_line, start_col)
        return Token(TokenType.IDENT, ident, start_line, start_col)

    def error(self, msg: str):
        raise SyntaxError(f"{self.filename}:{self.line}:{self.col}: {msg}")

    def tokenize(self) -> list:
        self.tokens = []
        self.indent_stack = []
        self.bracket_depth = 0
        self.line_has_token = False
        self.last_tok_line = 0
        while self.pos < len(self.source):
            self.skip_whitespace_and_comments()
            if self.pos >= len(self.source):
                break

            # 布局发射（判定出处 = T0 布局规格 §1/§2）：
            #  - 只在括号外（`()`/`[]`/`{}` 内是隐式续行，不参与 layout）；
            #  - 只在「上一逻辑行确实产出过 token」时发 NEWLINE ⇒ 纯空行与纯注释行
            #    天然成为 no-op（规格 ①-1/①-2，**不需要**另写一份「本行是否只有注释」的判定）；
            #  - anchor 列 = 本 token 的列（规格 ①-3），由 `advance()` 的既有列维护给出。
            if self.bracket_depth == 0 and self.line_has_token and self.line != self.last_tok_line:
                self._layout_break()
            self.line_has_token = True
            self.last_tok_line = self.line
            if not self.indent_stack:
                # ①-1 第 3 条：**首个非空行建立 anchor**（该行的首个 token 即基准列）。
                # 基准层不发 INDENT —— 否则顶层代码会整体被多包一层。
                self.indent_stack.append(self.col)

            ch = self.current()
            start_line, start_col = self.line, self.col

            # 单字符 token
            # 批 6（裁-S7，bounded）：`#` = 规约标注 sigil（`#check(...)` / `#ensure(...)`）。
            # 修复前 `#` 走末尾 `self.error("Unexpected character")`（**响亮拒收**）——
            # 而 self-hosted 侧是**静默丢弃**（`lexer.cr` Unknown 分支）⇒ 两前端分歧；
            # 现两侧同判：都产出一个 `#` token，语义面由各自的 parser 消费（**接受并跳过**）。
            # 注：`:287` 的未知字符报错**保留**——`#` 之外仍需它做最后一道响亮防线。
            single_char_map = {
                '+': TokenType.PLUS, '-': TokenType.MINUS,
                '*': TokenType.STAR, '/': TokenType.SLASH,
                '%': TokenType.PERCENT, ',': TokenType.COMMA,
                ';': TokenType.SEMI, '@': TokenType.AT,
                '#': TokenType.HASH,
                '(': TokenType.LPAREN, ')': TokenType.RPAREN,
                '[': TokenType.LBRACK, ']': TokenType.RBRACK,
                '{': TokenType.LBRACE, '}': TokenType.RBRACE,
            }

            if ch in single_char_map:
                self.advance()

                # 括号深度：`{}` 一并计入 ⇒ 结构体字面量内部不产生 layout
                # （规格 §4.1「字面量内部不参与 layout region」）
                if ch in '([{':
                    self.bracket_depth += 1
                elif ch in ')]}':
                    if self.bracket_depth > 0:
                        self.bracket_depth -= 1

                # 检查 ->
                if ch == '-' and self.current() == '>':
                    self.advance()
                    self.tokens.append(Token(TokenType.ARROW, '->', start_line, start_col))
                    continue

                self.tokens.append(Token(single_char_map[ch], ch, start_line, start_col))
                continue

            # 双字符
            if ch == '=':
                self.advance()
                if self.current() == '=':
                    self.advance()
                    self.tokens.append(Token(TokenType.EQ_EQ, '==', start_line, start_col))
                elif self.current() == '>':
                    self.advance()
                    self.tokens.append(Token(TokenType.FAT_ARROW, '=>', start_line, start_col))
                else:
                    self.tokens.append(Token(TokenType.EQ, '=', start_line, start_col))
                continue

            if ch == '!':
                self.advance()
                if self.current() == '=':
                    self.advance()
                    self.tokens.append(Token(TokenType.NOT_EQ, '!=', start_line, start_col))
                else:
                    self.tokens.append(Token(TokenType.BANG, '!', start_line, start_col))
                continue

            if ch == '<':
                self.advance()
                if self.current() == '=':
                    self.advance()
                    self.tokens.append(Token(TokenType.LT_EQ, '<=', start_line, start_col))
                else:
                    self.tokens.append(Token(TokenType.LT, '<', start_line, start_col))
                continue

            if ch == '>':
                self.advance()
                if self.current() == '=':
                    self.advance()
                    self.tokens.append(Token(TokenType.GT_EQ, '>=', start_line, start_col))
                else:
                    self.tokens.append(Token(TokenType.GT, '>', start_line, start_col))
                continue

            if ch == '&':
                self.advance()
                if self.current() == '&':
                    self.advance()
                    self.tokens.append(Token(TokenType.AND_AND, '&&', start_line, start_col))
                else:
                    self.tokens.append(Token(TokenType.AMPERSAND, '&', start_line, start_col))
                continue

            if ch == '|':
                self.advance()
                if self.current() == '|':
                    self.advance()
                    self.tokens.append(Token(TokenType.PIPE_PIPE, '||', start_line, start_col))
                else:
                    self.tokens.append(Token(TokenType.PIPE, '|', start_line, start_col))
                continue

            if ch == ':':
                self.advance()
                if self.current() == '=':
                    self.advance()
                    self.tokens.append(Token(TokenType.COLON_EQ, ':=', start_line, start_col))
                elif self.current() == ':':
                    self.advance()
                    self.tokens.append(Token(TokenType.PATH_SEP, '::', start_line, start_col))
                elif self._colon_is_line_end():
                    # 裁定 ②：行尾 `:` = region 开启（唯一措辞见 T0 布局规格 §2.1）
                    self.tokens.append(Token(TokenType.COLON_BLOCK, ':', start_line, start_col))
                else:
                    # 行内 `:` = 类型标注 / import 别名 / 字段 / 形参分隔符
                    self.tokens.append(Token(TokenType.COLON_DECL, ':', start_line, start_col))
                continue

            if ch == '.':
                self.advance()
                if self.current() == '.':
                    self.advance()
                    if self.current() == '.':
                        self.advance()
                        self.tokens.append(Token(TokenType.DOT_DOT_DOT, '...', start_line, start_col))
                    else:
                        self.tokens.append(Token(TokenType.DOT_DOT, '..', start_line, start_col))
                else:
                    self.tokens.append(Token(TokenType.DOT, '.', start_line, start_col))
                continue

            if ch == '?':
                self.advance()
                self.tokens.append(Token(TokenType.QUESTION, '?', start_line, start_col))
                continue

            # 字符串
            if ch in ('"', '\''):
                self.tokens.append(self.read_string(ch))
                continue

            # 数字
            if ch.isdigit():
                self.tokens.append(self.read_number(self.advance()))
                continue

            # 标识符
            if ch.isalpha() or ch == '_':
                self.tokens.append(self.read_ident(self.advance()))
                continue

            self.error(f"Unexpected character: '{ch}'")

        self._finish_layout()
        self.tokens.append(Token(TokenType.EOF, '', self.line, self.col))
        return self.tokens
