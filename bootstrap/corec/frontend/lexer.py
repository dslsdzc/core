from corec.syntax.tokens import Token, TokenType, KEYWORDS

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
        is_float = False
        while self.current().isdigit() or self.current() == '_':
            n += self.advance()
        if self.current() == '.' and self.peek().isdigit():
            is_float = True
            n += self.advance()
            while self.current().isdigit() or self.current() == '_':
                n += self.advance()
        if self.current().isalpha():
            suffix = ""
            while self.current().isalpha() or self.current().isdigit():
                suffix += self.advance()
            n += suffix
        n = n.replace('_', '')
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
        while self.pos < len(self.source):
            self.skip_whitespace_and_comments()
            if self.pos >= len(self.source):
                break

            ch = self.current()
            start_line, start_col = self.line, self.col

            # 单字符 token
            single_char_map = {
                '+': TokenType.PLUS, '-': TokenType.MINUS,
                '*': TokenType.STAR, '/': TokenType.SLASH,
                '%': TokenType.PERCENT, ',': TokenType.COMMA,
                ';': TokenType.SEMI, ':': TokenType.COLON,
                '(': TokenType.LPAREN, ')': TokenType.RPAREN,
                '[': TokenType.LBRACK, ']': TokenType.RBRACK,
                '{': TokenType.LBRACE, '}': TokenType.RBRACE,
            }

            if ch in single_char_map:
                self.advance()

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
                    self.error("Unexpected '|'")
                continue

            if ch == ':':
                self.advance()
                if self.current() == ':':
                    self.advance()
                    self.tokens.append(Token(TokenType.PATH_SEP, '::', start_line, start_col))
                else:
                    self.tokens.append(Token(TokenType.COLON, ':', start_line, start_col))
                continue

            if ch == '.':
                self.advance()
                if self.current() == '.':
                    self.advance()
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

        self.tokens.append(Token(TokenType.EOF, '', self.line, self.col))
        return self.tokens