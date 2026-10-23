"""vendored v3 前端扫描器（一次性迁移工具的内部件；非判据）。

出处：develop 版 v3 frontend（`bootstrap/corec/frontend/lexer.py` + `syntax/tokens.py`
的等价副本，2026-09-24 v4 迁移 T4 时点）。**本档不含 v4 布局**（无 INDENT/DEDENT/NEWLINE），
它只做 v3 词法，供 `tools/v4_migrate.py` 取 token 位置与做 V2 对拍。

与本仓 `bootstrap/corec/frontend/lexer.py`（v4）的分工：
  - 本档 = v3 面（`{`/`}`/`;` 仍是 token；`:` 是单一 COLON）；
  - v4 面由 `bootstrap/corec/frontend/lexer.py` 提供。
两档**必须保持各自语义**，不得互改。

对 vendored 源做的唯一改动：每个 token 增记 `start`/`end`（字符偏移）——
`tokenize()` 每轮在 skip_whitespace 之后记 `self._iter_start = self.pos`，
`_emit()` 落 `start=_iter_start, end=self.pos`。**其余逐字保持 vendored 原样。**
（v3 原档的 `line`/`col` 对 ident 与单字符 token 的基准不同一 —— 见 T4 报告 ——
 故偏移只取自 `start`/`end`，不从 line/col 反推。）
"""

from enum import Enum, auto
from dataclasses import dataclass

class TokenType(Enum):
    # 字面量
    INT_LIT = auto()
    FLOAT_LIT = auto()
    STRING_LIT = auto()
    CHAR_LIT = auto()
    BOOL_LIT = auto()
    UNIT_LIT = auto()

    # 标识符
    IDENT = auto()

    # 关键字
    FN = auto()
    STRUCT = auto()
    ENUM = auto()
    INTERFACE = auto()
    IMPL = auto()
    TYPE = auto()
    MUT = auto()
    MOVE = auto()
    GO = auto()
    AWAIT = auto()
    FLOW = auto()
    YIELD = auto()
    IF = auto()
    ELSE = auto()
    MATCH = auto()
    FOR = auto()
    IN = auto()
    LOOP = auto()
    WHILE = auto()
    RETURN = auto()
    BREAK = auto()
    CONTINUE = auto()
    PUB = auto()
    MOD = auto()
    IMPORT = auto()
    FILEID = auto()
    AS = auto()
    AUTO = auto()
    UNSAFE = auto()
    REQUIRES = auto()
    ENSURES = auto()
    RESULT = auto()
    SELF = auto()
    SELF_TYPE = auto()
    TRUE = auto()
    FALSE = auto()
    UNIT = auto()
    NONE = auto()
    SOME = auto()
    EXTERN = auto()

    # 符号
    FAT_ARROW = auto()
    PLUS = auto()
    MINUS = auto()
    STAR = auto()
    SLASH = auto()
    PERCENT = auto()
    EQ_EQ = auto()
    NOT_EQ = auto()
    LT = auto()
    GT = auto()
    LT_EQ = auto()
    GT_EQ = auto()
    AND_AND = auto()
    PIPE = auto()
    PIPE_PIPE = auto()
    BANG = auto()
    EQ = auto()
    ARROW = auto()
    PATH_SEP = auto()
    DOT = auto()
    DOT_DOT = auto()
    DOT_DOT_DOT = auto()
    COMMA = auto()
    SEMI = auto()
    COLON = auto()
    COLON_EQ = auto()
    LPAREN = auto()
    RPAREN = auto()
    LBRACK = auto()
    RBRACK = auto()
    LBRACE = auto()
    RBRACE = auto()
    AMPERSAND = auto()
    AT = auto()
    QUESTION = auto()
    UNDERSCORE = auto()
    # 批 6（裁-S7，bounded）：规约标注 sigil `#`（`#check(...)` / `#ensure(...)`）。
    # bootstrap 侧只做「**接受并跳过**」（零语义）：能词法化、不报错、**不影响产物**；
    # **不**实现 VC/三态（完整 bootstrap 规约面登记后续）。对应 self-hosted 的 `T_HASH = 101`。
    HASH = auto()

    EOF = auto()

KEYWORDS = {
    "fn": TokenType.FN,
    "struct": TokenType.STRUCT,
    "enum": TokenType.ENUM,
    "interface": TokenType.INTERFACE,
    "impl": TokenType.IMPL,
    "type": TokenType.TYPE,
    "mut": TokenType.MUT,
    "move": TokenType.MOVE,
    "go": TokenType.GO,
    "await": TokenType.AWAIT,
    "flow": TokenType.FLOW,
    "yield": TokenType.YIELD,
    "if": TokenType.IF,
    "else": TokenType.ELSE,
    "match": TokenType.MATCH,
    "for": TokenType.FOR,
    "in": TokenType.IN,
    "loop": TokenType.LOOP,
    "while": TokenType.WHILE,
    "return": TokenType.RETURN,
    "break": TokenType.BREAK,
    "continue": TokenType.CONTINUE,
    "pub": TokenType.PUB,
    "mod": TokenType.MOD,
    "import": TokenType.IMPORT,
    "fileid": TokenType.FILEID,
    "as": TokenType.AS,
    "unsafe": TokenType.UNSAFE,
    "requires": TokenType.REQUIRES,
    "ensures": TokenType.ENSURES,
    "result": TokenType.RESULT,
    "self": TokenType.SELF,
    "Self": TokenType.SELF_TYPE,
    "auto": TokenType.AUTO,
    "true": TokenType.TRUE,
    "false": TokenType.FALSE,
    "extern": TokenType.EXTERN,
    "unit": TokenType.UNIT,
    "None": TokenType.NONE,
    "Some": TokenType.SOME,
}

@dataclass
class Token:
    type: TokenType
    lexeme: str
    line: int
    col: int
    start: int = -1
    end: int = -1

    def __repr__(self):
        return f"Token({self.type}, '{self.lexeme}', {self.line}:{self.col})"



class Lexer:
    def __init__(self, source: str, filename: str = "<unknown>"):
        self.source = source
        self.filename = filename
        self.pos = 0
        self.line = 1
        self.col = 1
        self.tokens = []

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

    def skip_whitespace_and_comments(self):
        while self.pos < len(self.source):
            ch = self.current()
            if ch in ' \t\n\r':
                self.advance()
            elif ch == '/' and self.peek() == '/':
                while self.current() != '\n' and self.current() != '\0':
                    self.advance()
            elif ch == '/' and self.peek() == '*':
                self.advance(); self.advance()
                while not (self.current() == '*' and self.peek() == '/') and self.current() != '\0':
                    self.advance()
                self.advance(); self.advance()
            else:
                break

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

    def _emit(self, tok: Token):
        tok.start = self._iter_start
        tok.end = self.pos
        self.tokens.append(tok)

    def error(self, msg: str):
        raise SyntaxError(f"{self.filename}:{self.line}:{self.col}: {msg}")

    def tokenize(self) -> list:
        self.tokens = []
        self._iter_start = 0
        while self.pos < len(self.source):
            self.skip_whitespace_and_comments()
            if self.pos >= len(self.source):
                break
            self._iter_start = self.pos

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

                # 检查 ->
                if ch == '-' and self.current() == '>':
                    self.advance()
                    self._emit(Token(TokenType.ARROW, '->', start_line, start_col))
                    continue

                self._emit(Token(single_char_map[ch], ch, start_line, start_col))
                continue

            # 双字符
            if ch == '=':
                self.advance()
                if self.current() == '=':
                    self.advance()
                    self._emit(Token(TokenType.EQ_EQ, '==', start_line, start_col))
                elif self.current() == '>':
                    self.advance()
                    self._emit(Token(TokenType.FAT_ARROW, '=>', start_line, start_col))
                else:
                    self._emit(Token(TokenType.EQ, '=', start_line, start_col))
                continue

            if ch == '!':
                self.advance()
                if self.current() == '=':
                    self.advance()
                    self._emit(Token(TokenType.NOT_EQ, '!=', start_line, start_col))
                else:
                    self._emit(Token(TokenType.BANG, '!', start_line, start_col))
                continue

            if ch == '<':
                self.advance()
                if self.current() == '=':
                    self.advance()
                    self._emit(Token(TokenType.LT_EQ, '<=', start_line, start_col))
                else:
                    self._emit(Token(TokenType.LT, '<', start_line, start_col))
                continue

            if ch == '>':
                self.advance()
                if self.current() == '=':
                    self.advance()
                    self._emit(Token(TokenType.GT_EQ, '>=', start_line, start_col))
                else:
                    self._emit(Token(TokenType.GT, '>', start_line, start_col))
                continue

            if ch == '&':
                self.advance()
                if self.current() == '&':
                    self.advance()
                    self._emit(Token(TokenType.AND_AND, '&&', start_line, start_col))
                else:
                    self._emit(Token(TokenType.AMPERSAND, '&', start_line, start_col))
                continue

            if ch == '|':
                self.advance()
                if self.current() == '|':
                    self.advance()
                    self._emit(Token(TokenType.PIPE_PIPE, '||', start_line, start_col))
                else:
                    self._emit(Token(TokenType.PIPE, '|', start_line, start_col))
                continue

            if ch == ':':
                self.advance()
                if self.current() == '=':
                    self.advance()
                    self._emit(Token(TokenType.COLON_EQ, ':=', start_line, start_col))
                elif self.current() == ':':
                    self.advance()
                    self._emit(Token(TokenType.PATH_SEP, '::', start_line, start_col))
                else:
                    self._emit(Token(TokenType.COLON, ':', start_line, start_col))
                continue

            if ch == '.':
                self.advance()
                if self.current() == '.':
                    self.advance()
                    if self.current() == '.':
                        self.advance()
                        self._emit(Token(TokenType.DOT_DOT_DOT, '...', start_line, start_col))
                    else:
                        self._emit(Token(TokenType.DOT_DOT, '..', start_line, start_col))
                else:
                    self._emit(Token(TokenType.DOT, '.', start_line, start_col))
                continue

            if ch == '?':
                self.advance()
                self._emit(Token(TokenType.QUESTION, '?', start_line, start_col))
                continue

            # 字符串
            if ch in ('"', '\''):
                self._emit(self.read_string(ch))
                continue

            # 数字
            if ch.isdigit():
                self._emit(self.read_number(self.advance()))
                continue

            # 标识符
            if ch.isalpha() or ch == '_':
                self._emit(self.read_ident(self.advance()))
                continue

            self.error(f"Unexpected character: '{ch}'")

        self._emit(Token(TokenType.EOF, '', self.line, self.col))
        return self.tokens
