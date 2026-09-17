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

    def __repr__(self):
        return f"Token({self.type}, '{self.lexeme}', {self.line}:{self.col})"
