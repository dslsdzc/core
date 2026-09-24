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
    SELF = auto()
    TRUE = auto()
    FALSE = auto()
    UNIT = auto()
    # v4 新增关键字（目标集 39；出处 = 施工计划 §一.5 的三表差集）。
    # `none` 复用 NONE（v4 是小写 `none`；`None`/`Some` 已退役为普通标识符——
    # `Some(x)` 仍可解，走 `parse_call_or_field` 的「首字母大写 ⇒ EnumConstructor」分支）。
    NONE = auto()
    NEVER = auto()
    DYN = auto()
    CATCH = auto()
    FAIL = auto()
    SPEC = auto()
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
    # v4 裁定 ②（词法位置决定，T0 布局规格 §2.1）：原单个 COLON 由此二者取代，
    # **互斥且穷尽** ⇒ parser 侧零前瞻。
    #   `:` 之后到该物理行行尾**无任何 token**（空白与注释不计，§2.3）⇒ COLON_BLOCK（region 开启）
    #   否则 ⇒ COLON_DECL（类型标注 / import 别名 / 字段 / 形参分隔符）
    # ⚠ 行尾类型标注**不是合法文本**：lexer 必发 COLON_BLOCK，而该位置不是合法 region 头
    #   ⇒ parser 必须响亮拒绝（§2.2），不得静默改判成声明。
    COLON_DECL = auto()
    COLON_BLOCK = auto()
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

    # v4 布局（layout）token —— 施工计划 §四.1 项 2；逐条判定出处 = T0 布局规格 §1/§2。
    # NEWLINE：一个「有 token 的逻辑行」结束时发出（纯空行/纯注释行**不发**，§1.1 ①-1/①-2）。
    # INDENT ：换行后首个 token 的列**深于**缩进栈顶 ⇒ 压栈并发出。
    # DEDENT ：更浅 ⇒ 逐层弹出并各发一个；不匹配任何外层列 ⇒ **响亮报错**（不静默对齐）。
    # 括号 `( ) [ ] { }` 内不参与布局（隐式续行；`{ }` 是字面量定界符，规格 §4.1）。
    NEWLINE = auto()
    INDENT = auto()
    DEDENT = auto()

    EOF = auto()

# v4 关键字表 —— **目标集 39**（施工计划 §四.1 项 1）。
# 出处 = 计划 §一.5 的三表机械差集（脚本算，非目测），逐条：
#   去（bootstrap − v4，7）：`None` `Self` `Some` `ensures` `move` `requires` `result`
#   加（v4 − bootstrap，6）：`catch` `dyn` `fail` `never` `none` `spec`
# ⚠ 本表必须与自源 `src/compiler/lexer.cr` 的 `lookup_keyword` **逐元素相同**
#   （判据 J-T1-2）。自源侧 36 → 39 属 **T5**，本步（T1/T2）只改本侧
#   ⇒ **现阶段两侧预期仍不一致**，差集 = 本侧独有 6（`catch` `dyn` `fail` `never` `none` `spec`）
#   ＋ 自源独有 3（`None` `Some` `move`）；T5 落地后应双双为空。
#   **不得把这条预期红说成绿** —— 实报走 `python3 tools/v4_frontend_probe.py keywords`。
# 计数：40 − 7 + 6 = 39。
KEYWORDS = {
    "fn": TokenType.FN,
    "struct": TokenType.STRUCT,
    "enum": TokenType.ENUM,
    "interface": TokenType.INTERFACE,
    "impl": TokenType.IMPL,
    "type": TokenType.TYPE,
    "mut": TokenType.MUT,
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
    "self": TokenType.SELF,
    "auto": TokenType.AUTO,
    "true": TokenType.TRUE,
    "false": TokenType.FALSE,
    "extern": TokenType.EXTERN,
    "unit": TokenType.UNIT,
    "none": TokenType.NONE,
    "never": TokenType.NEVER,
    "dyn": TokenType.DYN,
    "catch": TokenType.CATCH,
    "fail": TokenType.FAIL,
    "spec": TokenType.SPEC,
}

@dataclass
class Token:
    type: TokenType
    lexeme: str
    line: int
    col: int

    def __repr__(self):
        return f"Token({self.type}, '{self.lexeme}', {self.line}:{self.col})"
