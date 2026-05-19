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
    IF = auto()
    ELSE = auto()
    MATCH = auto()
    FOR = auto()
    IN = auto()
    LOOP = auto()
    RETURN = auto()
    BREAK = auto()
    CONTINUE = auto()
    PUB = auto()
    MOD = auto()
    IMPORT = auto()
    AS = auto()
    AUTO = auto()
    UNSAFE = auto()
    REQUIRES = auto()
    ENSURES = auto()
    OLD = auto()
    RESULT = auto()
    SELF = auto()
    SELF_TYPE = auto()
    TRUE = auto()
    FALSE = auto()
    UNIT = auto()
    NONE = auto()
    SOME = auto()

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
    PIPE_PIPE = auto()
    BANG = auto()
    EQ = auto()
    ARROW = auto()
    PATH_SEP = auto()
    DOT = auto()
    DOT_DOT = auto()
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
    QUESTION = auto()
    UNDERSCORE = auto()

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
    "if": TokenType.IF,
    "else": TokenType.ELSE,
    "match": TokenType.MATCH,
    "for": TokenType.FOR,
    "in": TokenType.IN,
    "loop": TokenType.LOOP,
    "return": TokenType.RETURN,
    "break": TokenType.BREAK,
    "continue": TokenType.CONTINUE,
    "pub": TokenType.PUB,
    "mod": TokenType.MOD,
    "import": TokenType.IMPORT,
    "as": TokenType.AS,
    "unsafe": TokenType.UNSAFE,
    "requires": TokenType.REQUIRES,
    "ensures": TokenType.ENSURES,
    "old": TokenType.OLD,
    "result": TokenType.RESULT,
    "self": TokenType.SELF,
    "Self": TokenType.SELF_TYPE,
    "auto": TokenType.AUTO,
    "true": TokenType.TRUE,
    "false": TokenType.FALSE,
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