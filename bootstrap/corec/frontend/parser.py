import sys
sys.path.insert(0, 'bootstrap')
from corec.syntax.tokens import Token, TokenType
from corec.syntax.ast import *
from corec.ir.coreir import DEX_SCALE


def _str_to_scaled(s: str) -> int:
    """十进制字符串 → 定点缩放整数（S = 10^6，与自举侧 str_to_scaled 同规则）。

    整数部分 × S + 小数 6 位；第 7 位小数起四舍五入（半进）；去下划线/尾缀。
    """
    n = s.replace('_', '')
    # 剥离 alpha 尾缀（f32/f64——apx CPU 位宽标注，本路径忽略）
    i = 0
    while i < len(n) and (n[i].isdigit() or n[i] == '.'):
        i += 1
    n = n[:i]
    neg = False
    if n.startswith('-'):
        neg = True
        n = n[1:]
    ip_s, _, fp_s = n.partition('.')
    ip = int(ip_s) if ip_s else 0
    fp = fp_s[:6].ljust(6, '0')
    fv = int(fp)
    if len(fp_s) > 6 and fp_s[6] >= '5':
        fv += 1
        if fv == DEX_SCALE:
            fv = 0
            ip += 1
    v = ip * DEX_SCALE + fv
    return -v if neg else v

class Parser:
    def __init__(self, tokens: list):
        self.tokens = tokens
        self.pos = 0
        self.const_values = {}

    def _scan_constants(self):
        """Pre-scan for 'NAME: TYPE = VALUE' declarations to resolve array sizes.

        v4 改判（T0 布局规格 §6.2 A4）：终止元由 `;` 改为**行边界** ⇒ 六元组收为五元组。
        ⚠ **漏改即静默错答案**：具名长度会落到 `parse_type` 的 `.get(name, 0)` 兜底
        （解成 0），既不报错也不可辨。⇒ 判据必须含**正控**（真取到非 0 的值）。
        """
        save = self.pos
        while not self.check(TokenType.EOF):
            matched = False
            # v4: NAME : TYPE = VALUE 〈行边界〉
            if (self.check(TokenType.IDENT) and
                  self._check_seq([TokenType.IDENT, TokenType.COLON_DECL,
                                   TokenType.IDENT, TokenType.EQ, TokenType.INT_LIT])):
                name = self.advance().lexeme  # NAME
                self.advance()  # :
                self.advance()  # TYPE name (int/dex/bool)
                self.advance()  # =
                val = int(self.advance().lexeme)  # VALUE
                if self._at_line_end():
                    self.const_values[name] = val
                matched = True
            if not matched:
                self.advance()
        self.pos = save

    # ── v4 行边界（`;` 退场后的统一终止面）──────────────────────────────
    # 出处 = T0 布局规格 §2.5（`;` 只在 `[T; N]` / `[v; N]` 存活）+ §6.2 的 A/B 两类逐点判定。
    def _at_line_end(self):
        """当前位置是否处于行边界：NEWLINE / DEDENT / EOF。

        `DEDENT` 与 `EOF` **不消费**——它们是 region 收尾信号，由块产生式处理。
        """
        return (self.check(TokenType.NEWLINE) or self.check(TokenType.DEDENT)
                or self.check(TokenType.EOF))

    def _consume_newlines(self):
        while self.check(TokenType.NEWLINE):
            self.advance()

    def _end_decl(self):
        """消费语句/声明的行边界；**非行边界即响亮报错**。

        本函数取代原 `expect(SEMI)`（T0 布局规格 §6.2 B 类 8 处）——保留其**严格性**：
        少了这条，「同行两条声明」会被静默接受（与 `;` 时代行为不一致）。
        """
        if not self._at_line_end():
            self.error(f"expected end of line, got '{self.cur().lexeme}'")
        self._consume_newlines()

    def _expect_region(self):
        """吃 region 头：`COLON_BLOCK` 行尾冒号 + 其后的 NEWLINE + `INDENT`。

        token 次序由 lexer 的 `_layout_break` 决定：NEWLINE 先于 INDENT/DEDENT。
        **行内 `:`（`COLON_DECL`）在此被响亮拒绝** —— 这正是 T0 布局规格 §2.2 要的
        「行尾类型标注不是合法文本」的兜住点。
        """
        self.expect(TokenType.COLON_BLOCK)
        self._consume_newlines()
        self.expect(TokenType.INDENT)

    def _check_seq(self, types):
        """Check if the next tokens match the given type sequence."""
        if self.pos + len(types) > len(self.tokens):
            return False
        for i, t in enumerate(types):
            if self.tokens[self.pos + i].type != t:
                return False
        return True

    def cur(self) -> Token:
        return self.tokens[self.pos]

    def peek(self) -> Token:
        return self.tokens[self.pos + 1]

    def advance(self) -> Token:
        t = self.cur()
        self.pos += 1
        return t

    def expect(self, typ: TokenType) -> Token:
        if self.cur().type == typ:
            return self.advance()
        self.error(f"Expected {typ}, got {self.cur().type} '{self.cur().lexeme}'")

    def error(self, msg: str):
        t = self.cur()
        raise SyntaxError(f"{t.line}:{t.col}: {msg}")

    def check(self, typ: TokenType) -> bool:
        return self.cur().type == typ

    def _is_var_decl_start(self):
        """Check if current position starts a new-style variable declaration (no 'let' keyword).

        v4 改判（T0 布局规格 §6.2 A3）：本消解器**不读 `;`**（今天也不读），但 `:` 改判
        `COLON_DECL`——裁定 ② 使两种 `:` 互斥且穷尽 ⇒ 本处**零前瞻**，
        `COLON_BLOCK` 不进声明分支（进不去 ⇒ 在语句位会响亮报错，正是 §2.2 要的）。
        """
        if not self.check(TokenType.IDENT):
            return False
        save = self.pos
        self.advance()  # consume first IDENT
        result = False
        if self.check(TokenType.COMMA):
            # a, b : ... — batch declaration
            self.advance()
            if self.check(TokenType.IDENT):
                self.advance()
                if self.check(TokenType.COLON_DECL):
                    result = True
        elif self.check(TokenType.COLON_EQ):
            result = True
        elif self.check(TokenType.COLON_DECL):
            result = True  # x : type ... — commit to declaration
        self.pos = save
        return result

    def _parse_var_decl_names_tags_type(self):
        """Parse common prefix of new var decl: names ':' type [',' tags] [= values]
        Returns (names, tags, typ, values). Type is None for auto deduction."""
        names = [self.expect(TokenType.IDENT).lexeme]
        while self.check(TokenType.COMMA):
            self.advance()
            names.append(self.expect(TokenType.IDENT).lexeme)
        tags = []
        if self.check(TokenType.COLON_EQ):
            # x := expr  →  x : auto = expr
            self.advance()
            values = [self.parse_expr()]
            return names, tags, None, values
        self.expect(TokenType.COLON_DECL)
        if self.check(TokenType.AUTO) or self.check(TokenType.DOT):
            typ = None  # auto-deduced
            self.advance()
        else:
            typ = self.parse_type()
        if self.check(TokenType.COMMA):
            self.advance()
            # 标签表终止面（T0 布局规格 §6.2 A8 + A9 的对齐目标）：
            # **行边界** + `EQ`（`x : int, mut, pub = e` 的 `=` 仍保留）。
            # ⚠ A9：自源 `parser.cr:871` 今天的终止符集 = EQ/SEMI/EOF，
            #   而本侧曾是 EQ/SEMI/COMMA/COLON/EOF —— **两套前端此处不同形**。
            #   v4 下两侧一律取「行边界 + EQ」⇒ 本步把 COMMA/COLON 从终止符集移除
            #   （COMMA 仍是标签**分隔符**，见下方 advance；收进终止符集是过去的兜底）。
            while not self._at_line_end() and not self.check(TokenType.EQ):
                tag = self.advance().lexeme
                # 已知标签：mut / pub / apx（与自举编译器一致，未知标签报错）
                if tag not in ('mut', 'pub', 'apx'):
                    self.error(f"unknown declaration tag '{tag}'")
                tags.append(tag)
                if self.check(TokenType.COMMA):
                    self.advance()
                else:
                    break
        values = []
        if self.check(TokenType.EQ):
            self.advance()
            values.append(self.parse_expr())
            while self.check(TokenType.COMMA):
                self.advance()
                values.append(self.parse_expr())
        return names, tags, typ, values

    # ─── 顶层 ───
    def parse_compilation_unit(self) -> CompilationUnit:
        self._scan_constants()
        fileid = self._parse_fileid()
        modules, imports = self._parse_module_and_imports()
        declarations = []
        while not self.check(TokenType.EOF):
            self._consume_newlines()
            if self.check(TokenType.EOF):
                break
            if self.check(TokenType.DEDENT):
                self.error("unexpected dedent at top level")
            declarations.append(self.parse_top_level_decl())
        return CompilationUnit(modules, imports, declarations, fileid)

    def _parse_fileid(self):
        if self.check(TokenType.FILEID):
            self.advance()
            name = self.expect(TokenType.STRING_LIT).lexeme
            self._end_decl()
            return name
        return None

    def _parse_module_and_imports(self):
        modules, imports = [], []
        while self.check(TokenType.MOD) or self.check(TokenType.IMPORT):
            if self.check(TokenType.MOD):
                modules.append(self.parse_module_decl())
            else:
                imports.append(self.parse_import_decl())
        return modules, imports

    def parse_module_decl(self):
        self.expect(TokenType.MOD)
        path = self.parse_path()
        self._end_decl()
        return ModuleDecl(path)

    def parse_import_decl(self):
        self.expect(TokenType.IMPORT)
        project = None
        if self.check(TokenType.AT):
            self.advance()
            project = self.expect(TokenType.IDENT).lexeme
        file_id = self.expect(TokenType.IDENT).lexeme
        alias = None
        # D7（T0 布局规格 §2.2）：`import math : m` 的别名 `:` 后**必有**后继 token ⇒ COLON_DECL
        if self.check(TokenType.AS) or self.check(TokenType.COLON_DECL):
            self.advance()
            alias = self.expect(TokenType.IDENT).lexeme
        self._end_decl()
        return ImportDecl([file_id], alias, project)

    def parse_path(self):
        parts = [self.expect(TokenType.IDENT).lexeme]
        while self.check(TokenType.PATH_SEP):
            self.advance()
            parts.append(self.expect(TokenType.IDENT).lexeme)
        return parts

    # ─── 顶层声明 ───
    def parse_top_level_decl(self):
        is_pub = False
        if self.check(TokenType.PUB):
            is_pub = True
            self.advance()
        if self.check(TokenType.FN):
            return self.parse_function_decl(is_pub)
        elif self.check(TokenType.FLOW):
            self.advance()
            return self.parse_function_decl(is_pub, is_flow=True)
        elif self.check(TokenType.STRUCT):
            return self.parse_struct_decl(is_pub)
        elif self.check(TokenType.ENUM):
            return self.parse_enum_decl(is_pub)
        elif self.check(TokenType.INTERFACE):
            return self.parse_interface_decl(is_pub)
        elif self.check(TokenType.IMPL):
            return self.parse_impl_decl()
        elif self.check(TokenType.TYPE):
            return self.parse_type_alias()
        elif self.check(TokenType.IDENT) and self._is_var_decl_start():
            return self._parse_new_let_decl()
        self.error(f"Unexpected '{self.cur().lexeme}' at top level")

    def parse_function_decl(self, is_pub, is_flow=False):
        if not is_flow:
            self.expect(TokenType.FN)
        name = self.expect(TokenType.IDENT).lexeme
        generics = self._parse_generics()
        self.expect(TokenType.LPAREN)
        params = self._parse_param_list()
        self.expect(TokenType.RPAREN)
        if self.check(TokenType.ARROW):
            self.advance()
            ret = self.parse_type()
        else:
            ret = BaseType('unit')
        # 批 6（裁-S7，bounded）：规约标注链 `#check(...)` / `#ensure(...)`——**接受并跳过**。
        # 位置与 self-hosted 侧一一对应（签名之后、body 之前）；**零语义**。
        self._skip_spec_annotations()
        if self.check(TokenType.EQ):
            self.advance()
            body = self.parse_expr()
            self._end_decl()
            return FunctionDecl(is_pub, name, generics, params, ret, body)
        # D9/D10（T0 布局规格 §2.2）：有体 ⇒ 行尾 `:`（COLON_BLOCK）开 region；
        # 无体（`extern fn read(fd: int) -> int`）⇒ 行边界，无 `:`。
        if self._at_line_end():
            return FunctionDecl(is_pub, name, generics, params, ret, None)
        body = self.parse_block()
        if is_flow:
            body = Flow(body)
        return FunctionDecl(is_pub, name, generics, params, ret, body)

    def _skip_spec_annotations(self):
        """批 6（裁-S7，bounded）：消费 `#` IDENT `(` … `)` 标注链并**丢弃**（零语义）。

        边界（维护者裁定）：bootstrap 侧**只**保证「能词法化、不报错、不影响产物」——
        不建 VC、不做三态、不做名字域/类型检查（完整 bootstrap 规约面登记后续）。
        消费 = 平衡括号扫描（不解析表达式）⇒ 对内部形态（含 `result` 等 bootstrap 关键字）
        一律容忍；形状错（缺 IDENT/缺括号/未闭合）**响亮报错**（fail-loud，不静默）。
        """
        while self.check(TokenType.HASH):
            self.advance()                      # '#'
            if not self.check(TokenType.IDENT):
                self.error("expected annotation name after '#'")
            self.advance()                      # check / ensure
            self.expect(TokenType.LPAREN)
            depth = 1
            while depth > 0:
                if self.check(TokenType.EOF):
                    self.error("unterminated annotation: missing ')'")
                if self.check(TokenType.LPAREN):
                    depth += 1
                elif self.check(TokenType.RPAREN):
                    depth -= 1
                self.advance()

    def _parse_generics(self):
        if self.check(TokenType.LBRACK):
            self.advance()
            names = []
            first = True
            while not self.check(TokenType.RBRACK):
                if not first:
                    self.expect(TokenType.COMMA)
                first = False
                names.append(self.expect(TokenType.IDENT).lexeme)
                if self.check(TokenType.COLON_DECL):
                    self.advance()  # :
                    self.expect(TokenType.IDENT)  # constraint name (skip)
            self.expect(TokenType.RBRACK)
            return names
        return []

    def _parse_param_list(self):
        params = []
        if not self.check(TokenType.RPAREN):
            params.append(self._parse_param())
            while self.check(TokenType.COMMA):
                self.advance()
                params.append(self._parse_param())
        return params

    def _parse_param(self):
        # &self or &mut self
        if self.check(TokenType.AMPERSAND):
            self.advance()
            is_mut = False
            if self.check(TokenType.MUT):
                self.advance()
                is_mut = True
            name = self.expect(TokenType.SELF).lexeme
            typ = "&mut self" if is_mut else "&self"
            return (name, typ)
        if self.check(TokenType.SELF):
            name = self.advance().lexeme
            typ = None
            if self.check(TokenType.COLON_DECL):
                self.advance()
                typ = self.parse_type()
            return (name, typ)
        # Variadic parameter: ...name:type
        if self.check(TokenType.DOT_DOT_DOT):
            self.advance()
            name = self.expect(TokenType.IDENT).lexeme
            self.expect(TokenType.COLON_DECL)
            typ = self.parse_type()
            return (name, typ)
        name = self.expect(TokenType.IDENT).lexeme
        self.expect(TokenType.COLON_DECL)
        typ = self.parse_type()
        return (name, typ)

    def parse_type(self):
        if self.check(TokenType.LBRACK):
            self.advance()
            inner = self.parse_type()
            if self.check(TokenType.SEMI):
                self.advance()
                if self.check(TokenType.INT_LIT):
                    sz = int(self.expect(TokenType.INT_LIT).lexeme)
                elif self.check(TokenType.IDENT):
                    name = self.expect(TokenType.IDENT).lexeme
                    sz = self.const_values.get(name, 0)
                    # Handle CONST * N  (e.g. MAX_TYPES * 3)
                    if self.check(TokenType.STAR):
                        self.advance()
                        rhs = int(self.expect(TokenType.INT_LIT).lexeme)
                        sz = sz * rhs
                else:
                    self.error("Expected integer literal or constant name for array size")
                self.expect(TokenType.RBRACK)
                return ArrayType(inner, sz)
            self.expect(TokenType.RBRACK)
            return SliceType(inner)
        if self.check(TokenType.LPAREN):
            self.advance()
            types = []
            if not self.check(TokenType.RPAREN):
                types.append(self.parse_type())
                while self.check(TokenType.COMMA):
                    self.advance()
                    types.append(self.parse_type())
            self.expect(TokenType.RPAREN)
            if len(types) == 1:
                return types[0]
            return TupleType(types)
        if self.check(TokenType.AMPERSAND):
            self.advance()
            mut = False
            if self.check(TokenType.MUT):
                mut = True
                self.advance()
            return RefType(mut, self.parse_type())
        # dex = 精确小数（数值迁移 Task 5：float 类型名已移除，与自举侧同步）
        # v4：`never` / `dyn` 从「词素比对」**提升为关键字**（计划 §一.5 注 1 / §7.1 项 8）
        # ⇒ 必须在此显式收下，否则它们会掉进 `parse_path()` 的 `expect(IDENT)` 而响亮报错。
        # 语义与自源原生名表一致（`checker.cr:1186` 的 8 个基类型名含 never/dyn ⇒ TY_NEVER / TI_DYN）。
        if self.check(TokenType.NEVER):
            self.advance()
            return BaseType('never')
        if self.check(TokenType.DYN):
            self.advance()
            return BaseType('dyn')
        # v4：`Self` 不再进关键字表（计划 §一.5 的 `bootstrap − v4` 差集含 `Self`）
        # ⇒ 它以 IDENT 到达；保留「`&Self` 是原生名不是泛型形参」的既有行为
        # （先例：`never` 今天也走这条 base_types 路径）。**若漏掉本格**，
        # `&Self` 会变成 `PathType(['Self'])`，而 type_checker 的 `_is_generic_type`
        # 把「单元素 PathType」当泛型形参 ⇒ 静默错判（不是报错）。
        base_types = {'int','dex','bool','string','char','unit','never','Self'}
        if self.check(TokenType.IDENT) and self.cur().lexeme in base_types:
            return BaseType(self.advance().lexeme)
        if self.check(TokenType.UNIT):
            self.advance()
            return BaseType('unit')
        typ = PathType(self.parse_path())
        if self.check(TokenType.LBRACK):
            self.advance()
            args = [self.parse_type()]
            while self.check(TokenType.COMMA):
                self.advance()
                args.append(self.parse_type())
            self.expect(TokenType.RBRACK)
            return GenericApplyType(typ.path, args)
        if self.check(TokenType.QUESTION):
            self.advance()
            return OptionalType(typ)
        return typ

    # ─── 表达式 ───
    def parse_expr(self):
        left = self.parse_assignment()
        if self.check(TokenType.DOT_DOT):
            self.advance()
            right = self.parse_expr()
            return RangeExpr(left, right)
        return left

    def parse_assignment(self):
        # `move` 已退役（计划 §一.5：bootstrap − v4 差集含 `move`）⇒ 原 MOVE 分支删除。
        # v4 下 `move x = e` 会响亮报错（`move` 落 T_IDENT ⇒ 变成两条语句/未知名），不静默。
        left = self.parse_logical_or()
        if self.check(TokenType.EQ):
            self.advance()
            right = self.parse_assignment()
            return BinaryOp(left, "=", right)
        return left

    def parse_logical_or(self):
        left = self.parse_logical_and()
        while self.check(TokenType.PIPE_PIPE):
            op = self.advance().lexeme
            left = BinaryOp(left, op, self.parse_logical_and())
        return left

    def parse_logical_and(self):
        left = self.parse_bitwise_or()
        while self.check(TokenType.AND_AND):
            op = self.advance().lexeme
            left = BinaryOp(left, op, self.parse_bitwise_or())
        return left

    def parse_bitwise_or(self):
        left = self.parse_bitwise_and()
        while self.check(TokenType.PIPE):
            op = self.advance().lexeme
            left = BinaryOp(left, op, self.parse_bitwise_and())
        return left

    def parse_bitwise_and(self):
        left = self.parse_equality()
        while self.check(TokenType.AMPERSAND):
            op = self.advance().lexeme
            left = BinaryOp(left, op, self.parse_equality())
        return left

    def parse_equality(self):
        left = self.parse_comparison()
        while self.check(TokenType.EQ_EQ) or self.check(TokenType.NOT_EQ):
            op = self.advance().lexeme
            left = BinaryOp(left, op, self.parse_comparison())
        return left

    def parse_comparison(self):
        left = self.parse_addition()
        while self.check(TokenType.LT) or self.check(TokenType.GT) or self.check(TokenType.LT_EQ) or self.check(TokenType.GT_EQ):
            op = self.advance().lexeme
            left = BinaryOp(left, op, self.parse_addition())
        return left

    def parse_addition(self):
        left = self.parse_multiplication()
        while self.check(TokenType.PLUS) or self.check(TokenType.MINUS):
            op = self.advance().lexeme
            left = BinaryOp(left, op, self.parse_multiplication())
        return left

    def parse_multiplication(self):
        left = self.parse_unary()
        while self.check(TokenType.STAR) or self.check(TokenType.SLASH) or self.check(TokenType.PERCENT):
            op = self.advance().lexeme
            left = BinaryOp(left, op, self.parse_unary())
        return left

    def parse_unary(self):
        if self.check(TokenType.MINUS) or self.check(TokenType.BANG) or self.check(TokenType.STAR):
            op = self.advance().lexeme
            return UnaryOp(op, self.parse_unary())
        if self.check(TokenType.AMPERSAND):
            self.advance()
            mut = False
            if self.check(TokenType.MUT):
                mut = True
                self.advance()
            return UnaryOp('&mut' if mut else '&', self.parse_unary())
        return self.parse_call_or_field()

    def parse_call_or_field(self) -> Expr:
        node = self.parse_primary()
        while True:
            if self.check(TokenType.LPAREN):
                if isinstance(node, Ident) and node.name[0].isupper():
                    self.advance()
                    args = []
                    if not self.check(TokenType.RPAREN):
                        args.append(self.parse_expr())
                        while self.check(TokenType.COMMA):
                            self.advance()
                            args.append(self.parse_expr())
                    self.expect(TokenType.RPAREN)
                    node = EnumConstructor([node.name], args)
                else:
                    self.advance()
                    args = []
                    if not self.check(TokenType.RPAREN):
                        args.append(self.parse_expr())
                        while self.check(TokenType.COMMA):
                            self.advance()
                            args.append(self.parse_expr())
                    self.expect(TokenType.RPAREN)
                    node = Call(node, args)
            elif self.check(TokenType.DOT):
                self.advance()
                field = self.expect(TokenType.IDENT).lexeme
                node = FieldAccess(node, field)
            elif self.check(TokenType.LBRACK):
                self.advance()
                # Distinguish between index expression and array literal
                if self.check(TokenType.RBRACK) or (self.cur().type in (TokenType.INT_LIT, TokenType.STRING_LIT, TokenType.IDENT, TokenType.LPAREN, TokenType.MINUS, TokenType.BANG)):
                    # index expression: node[idx]
                    idx = self.parse_expr()
                    self.expect(TokenType.RBRACK)
                    node = Index(node, idx)
                else:
                    # array literal [e1, e2, ...]
                    elements = []
                    if not self.check(TokenType.RBRACK):
                        elements.append(self.parse_expr())
                        while self.check(TokenType.COMMA):
                            self.advance()
                            elements.append(self.parse_expr())
                    self.expect(TokenType.RBRACK)
                    node = ArrayLit(elements)
            elif self.check(TokenType.QUESTION):
                self.advance()
                node = Try(node)
            else:
                break
        return node

    def parse_primary(self) -> Expr:
        if self.check(TokenType.AT):
            # 三种形态（按下一 token 判，互不吞并）：
            #   `@name(args)` / `@name`  → 内建（Builtin；2(a) 视图内建批新增）
            #   `@project file::symbol` → ProjectAccess（原样保留）
            # 注意：`@name(` 与 `@name name` 的判据是**紧随的 token 类型**，不是名字内容——
            # 名字内容留给 type_checker 的 **fail-closed** 白名单（未知名 ⇒ 报错，不静默）。
            self.advance()
            first = self.expect(TokenType.IDENT).lexeme
            if self.check(TokenType.LPAREN):
                self.advance()
                args: List[Expr] = []
                if not self.check(TokenType.RPAREN):
                    args.append(self.parse_expr())
                    while self.check(TokenType.COMMA):
                        self.advance()
                        args.append(self.parse_expr())
                self.expect(TokenType.RPAREN)
                return Builtin(first, args)
            if self.check(TokenType.IDENT):
                file_id = self.advance().lexeme
                self.expect(TokenType.PATH_SEP)
                symbol = self.expect(TokenType.IDENT).lexeme
                return Ident(f"@{first}.{file_id}::{symbol}")
            return Builtin(first, [])
        if self.check(TokenType.NONE) or self.check(TokenType.SELF):
            return Ident(self.advance().lexeme)
        if self.check(TokenType.INT_LIT):
            return Literal(int(self.advance().lexeme), 'int')
        if self.check(TokenType.FLOAT_LIT):
            # 3.14 字面量 → dex（数值迁移 Task 3/4）——精确解析：十进制 → 定点缩放整数
            # （S = 10^6，第 7 位小数起四舍五入；非二进制近似——0.1+0.2==0.3 精确成立）
            return Literal(_str_to_scaled(self.advance().lexeme), 'dex')
        if self.check(TokenType.STRING_LIT):
            return Literal(self.advance().lexeme, 'string')
        if self.check(TokenType.CHAR_LIT):
            return Literal(self.advance().lexeme, 'char')
        if self.check(TokenType.TRUE):
            self.advance(); return Literal(True, 'bool')
        if self.check(TokenType.FALSE):
            self.advance(); return Literal(False, 'bool')
        if self.check(TokenType.UNIT):
            self.advance(); return Literal(None, 'unit')
        if self.check(TokenType.IDENT):
            ident_name = self.advance().lexeme
            # v4（T0 布局规格 §4.5）：块花括号不存在 ⇒ `Name {` 之后**必**是字面量，
            # 原 `_is_struct_lit` 消解器整体退场（它靠「深度 1 的 `;`」判块）。
            if ident_name[0].isupper() and self.check(TokenType.LBRACE):
                self.advance()  # consume {
                fields = []
                while not self.check(TokenType.RBRACE):
                    fname = self.expect(TokenType.IDENT).lexeme
                    # §4.2 写死：分隔符必须是 `=`；未选定的 `:` 形**响亮拒绝**（码 P030）。
                    # 修复前是**盲跳**（`elif check(COLON): advance()`）⇒ 两形同收 = 判据无鉴别力。
                    if not self.check(TokenType.EQ):
                        self.error("struct literal field separator must be '=' [P030]")
                    self.advance()
                    val = self.parse_expr()
                    fields.append((fname, val))
                    if self.check(TokenType.COMMA):
                        self.advance()
                self.expect(TokenType.RBRACE)
                return StructLit([ident_name], fields)
            return Ident(ident_name)
        if self.check(TokenType.LBRACK):
            self.advance()
            if self.check(TokenType.RBRACK):
                self.advance()
                return ArrayLit([])
            first = self.parse_expr()
            if self.check(TokenType.SEMI):
                # [value; count] — repeated array
                self.advance()
                count = self.expect(TokenType.INT_LIT)
                elements = [first] * int(count.lexeme)
                self.expect(TokenType.RBRACK)
                return ArrayLit(elements)
            elements = [first]
            while self.check(TokenType.COMMA):
                self.advance()
                elements.append(self.parse_expr())
            self.expect(TokenType.RBRACK)
            return ArrayLit(elements)
        if self.check(TokenType.LPAREN):
            self.advance()
            e = self.parse_expr()
            self.expect(TokenType.RPAREN)
            return e
        if self.check(TokenType.LBRACE):
            # v4：`{ }` 只作结构体字面量定界符（`{` 的唯一合法位置，T0 布局规格 §4.3），
            # 块结构由 `:` + 缩进取代 ⇒ 表达式位的裸 `{` 无产生式，响亮报错。
            self.error("'{' is only valid as a struct literal delimiter in v4 (blocks use ':' + indent)")
        if self.check(TokenType.IF):
            return self.parse_if_expr()
        if self.check(TokenType.MATCH):
            return self.parse_match_expr()
        if self.check(TokenType.LOOP):
            return self.parse_loop_expr()
        if self.check(TokenType.WHILE):
            return self.parse_while_expr()
        if self.check(TokenType.FOR):
            return self.parse_for_expr()
        if self.check(TokenType.GO):
            self.advance()
            # go [N] expr  or  go var start end expr
            save = self.pos
            if self.check(TokenType.IDENT):
                var_tok = self.advance()
                if self.check(TokenType.INT_LIT):
                    start_tok = self.advance()
                    if self.check(TokenType.INT_LIT):
                        end_tok = self.advance()
                        body = Go(self.parse_expr())
                        # Desugar: go i 1 8 f(i) → for i in 1..8 { go f(i); }
                        range_node = RangeExpr(
                            Literal(int(start_tok.lexeme), 'int'),
                            Literal(int(end_tok.lexeme), 'int'))
                        return For(var_tok.lexeme, range_node, Block([body]))
            # Not range mode — backtrack
            self.pos = save
            return Go(self.parse_expr())
        if self.check(TokenType.AWAIT):
            self.advance(); return Await(self.parse_expr())
        if self.check(TokenType.FLOW):
            self.advance(); return Flow(self.parse_block())
        if self.check(TokenType.YIELD):
            self.advance(); return Yield(self.parse_expr())
        if self.check(TokenType.UNSAFE):
            self.advance(); return Unsafe(self.parse_block())
        self.error(f"Unexpected token: {self.cur().lexeme}")

    def parse_block(self) -> Block:
        """v4 region：吃 `INDENT` … `DEDENT`（取代原 `{` … `}`）。

        尾表达式判定（T0 布局规格 §6.2 A1）：**region 的最后一项 = 该 region 的值**，
        其余各项按语句处理 —— 即原 `parse_block` 的「暂定尾表达式」逻辑原样保留，
        只是「还有下一项」的判据由「不是 `}`」变成「不是 DEDENT」。
        """
        self._expect_region()
        stmts = []
        expr = None
        while True:
            self._consume_newlines()
            if self.check(TokenType.DEDENT) or self.check(TokenType.EOF):
                break
            item = self.parse_stmt()
            if isinstance(item, Stmt):
                if expr is not None:
                    # previous bare expression wasn't last — push as stmt
                    stmts.append(ExprStmt(expr))
                    expr = None
                stmts.append(item)
            else:
                # bare expression — tentatively the trailing expr
                if expr is not None:
                    stmts.append(ExprStmt(expr))
                expr = item
        self.expect(TokenType.DEDENT)
        return Block(stmts, expr)

    def parse_stmt(self):
        if self.check(TokenType.IDENT) and self._is_var_decl_start():
            names, tags, typ, values = self._parse_var_decl_names_tags_type()
            self._end_decl()
            return LetStmt(names=names, tags=tags, type_=typ, values=values)
        elif self.check(TokenType.RETURN):
            self.advance()
            val = None
            # A6：关键字之后**同一逻辑行内**无 token ⇒ 无值（行边界取代 `;`/`}`）
            if not self._at_line_end():
                val = self.parse_expr()
            self._consume_newlines()
            return ReturnStmt(val)
        elif self.check(TokenType.BREAK):
            self.advance()
            self._consume_newlines()
            return BreakStmt()
        elif self.check(TokenType.CONTINUE):
            self.advance()
            self._consume_newlines()
            return ContinueStmt()
        else:
            # A1：裸表达式**暂定**为 region 尾值；块循环在「后面还有一项」时再包成 ExprStmt。
            # v4 无 `;` ⇒ 不再有「显式语句」形态（原 `if check(SEMI): return ExprStmt(e)` 分支淘汰）。
            return self.parse_expr()

    def parse_if_expr(self):
        self.expect(TokenType.IF)
        cond = self.parse_expr()
        then = self.parse_block()
        else_branch = None
        if self.check(TokenType.ELSE):
            self.advance()
            if self.check(TokenType.IF):
                else_branch = self.parse_if_expr()
            else:
                else_branch = self.parse_block()
        return If(cond, then, else_branch)

    def parse_match_expr(self):
        self.expect(TokenType.MATCH)
        expr = self.parse_expr()
        self._expect_region()
        arms = []
        while True:
            self._consume_newlines()
            if self.check(TokenType.DEDENT) or self.check(TokenType.EOF):
                break
            # 臂前缀 `|`（v4 目标形，维护者原话 `/tmp/briefs/v4-syntax-raw.md:81,119-138`：
            # `|` = alternative / pattern arm，且同组臂必须**列对齐**）。
            # **本侧接受「有 `|`」与「无 `|`」两形**，理由写实（不是偷懒）：
            #   ① v3 语料的臂**没有** `|`（`tests/suite/apx_conversion_test.cr:89`
            #      逐字 `match e { V(x) => …, None => … }`），而 T4 是**机械改写**
            #      （计划 §六.1：形状只有 `{}`→缩进、`;`→换行两类）⇒ 它**不会**补 `|`
            #      ⇒ 本批自己的产物必须仍可解析；
            #   ② v4 目标形有 `|` ⇒ 不收它就解析不了维护者原话里的 match 例。
            # ⚠ 二者**不是「两形都收」的静默歧义**：改前 `|` 在臂首是**解析错误**，
            #   故本放宽**不改变任何既有可解析程序的含义**（纯增量）。
            #   「`|` 是否**强制**」留待 T5 决定（先例：struct 字面量分隔符守卫，T0 §4.2）。
            if self.check(TokenType.PIPE):
                self.advance()
            pat = self.parse_pattern()
            self.expect(TokenType.FAT_ARROW)   # 使用 =>
            body = self.parse_expr()
            arms.append(MatchArm(pat, body))
            if self.check(TokenType.COMMA):
                self.advance()
        self.expect(TokenType.DEDENT)
        return Match(expr, arms)
    def parse_pattern(self) -> Pattern:
        if self.check(TokenType.UNDERSCORE) or self.cur().lexeme == '_':
            self.advance(); return Wildcard()
        if self.check(TokenType.INT_LIT):
            return LiteralPattern(Literal(int(self.advance().lexeme), 'int'))
        if self.check(TokenType.STRING_LIT):
            return LiteralPattern(Literal(self.advance().lexeme, 'string'))
        if self.check(TokenType.LPAREN):
            self.advance()
            pats = []
            if not self.check(TokenType.RPAREN):
                pats.append(self.parse_pattern())
                while self.check(TokenType.COMMA):
                    self.advance()
                    pats.append(self.parse_pattern())
            self.expect(TokenType.RPAREN)
            return TuplePattern(pats)
        # v4 的 `none`（小写，v4 关键字）与既有 canonical 变体名 `None` 指**同一个**变体。
        # ⚠ canonical 名此处仍写 `None`：改它 = 全局重命名，属 **T5** 的 `None`→`none` 语义面
        #   （计划 §2.3 R3 逐字「`none` ↔ `None` … 是语义面，见 T1/T5」），
        #   与 T4 的机械形状改写不同批。`EnumPattern` 的 path[-1] 会被 desugar 直接当
        #   `__variant` 的**标签串**比较（`desugar.py:86-92`）⇒ 必须与枚举声明的变体名一致。
        #   **漏掉本格** ⇒ 小写 `none` 会掉进下方的 IdentPattern（那是**变量绑定**，不是匹配）
        #   ⇒ 语义静默改变（模式永远命中）——正是要防的形态。
        if self.check(TokenType.NONE):
            self.advance()
            return EnumPattern(['None'], None)
        # 标识符或关键字作为模式（v4：`Some` 已是普通 IDENT，走下行）
        if self.check(TokenType.IDENT):
            name = self.advance().lexeme
            path = [name]
            if self.check(TokenType.LPAREN):
                self.advance()
                args = []
                if not self.check(TokenType.RPAREN):
                    args.append(self.parse_pattern())
                    while self.check(TokenType.COMMA):
                        self.advance()
                        args.append(self.parse_pattern())
                self.expect(TokenType.RPAREN)
                return EnumPattern(path, args)
            if self.check(TokenType.LBRACE):
                self.advance()
                fields = []
                while not self.check(TokenType.RBRACE):
                    fname = self.expect(TokenType.IDENT).lexeme
                    self.expect(TokenType.EQ)
                    fpat = self.parse_pattern()
                    fields.append((fname, fpat))
                    if self.check(TokenType.COMMA):
                        self.advance()
                self.expect(TokenType.RBRACE)
                return StructPattern(path, fields)
            # 无括号和花括号：根据首字母大小写决定
            if name[0].isupper():
                return EnumPattern(path, None)   # 枚举变体
            else:
                return IdentPattern(name)        # 变量绑定
        self.error(f"Unexpected token in pattern: {self.cur().lexeme}")
    def parse_loop_expr(self):
        self.expect(TokenType.LOOP)
        return Loop(self.parse_block())

    def parse_while_expr(self):
        """Desugar: while cond { body } → loop { if !cond { break; } body }"""
        self.expect(TokenType.WHILE)
        cond = self.parse_expr()
        body = self.parse_block()
        # Build: if !cond { break; }
        not_cond = UnaryOp("!", cond)
        break_block = Block([BreakStmt()], None)
        if_node = If(not_cond, break_block, None)
        # Prepend to body statements
        new_stmts = [ExprStmt(if_node)] + body.stmts
        new_block = Block(new_stmts, body.expr)
        return Loop(new_block)

    def parse_for_expr(self):
        self.expect(TokenType.FOR)
        var = self.expect(TokenType.IDENT).lexeme
        self.expect(TokenType.IN)
        iter = self.parse_expr()
        return For(var, iter, self.parse_block())

    def parse_struct_decl(self, is_pub):
        self.expect(TokenType.STRUCT)
        name = self.expect(TokenType.IDENT).lexeme
        generics = self._parse_generics()
        self._expect_region()
        fields = []
        while True:
            self._consume_newlines()
            if self.check(TokenType.DEDENT) or self.check(TokenType.EOF):
                break
            fname = None
            if self.check(TokenType.IDENT):
                fname = self.advance().lexeme
            elif self.cur().type in (TokenType.TYPE, TokenType.MUT, TokenType.PUB, TokenType.MOD,
                                     TokenType.STRUCT, TokenType.ENUM,
                                     TokenType.IMPL, TokenType.SELF,
                                     TokenType.MATCH, TokenType.FOR, TokenType.LOOP,
                                     TokenType.WHILE, TokenType.IF, TokenType.ELSE,
                                     TokenType.RETURN, TokenType.BREAK, TokenType.CONTINUE,
                                     TokenType.GO, TokenType.AWAIT,
                                     TokenType.TRUE, TokenType.FALSE, TokenType.UNIT,
                                     TokenType.AUTO, TokenType.INTERFACE, TokenType.AS):
                fname = self.advance().lexeme  # keyword as field name
            else:
                fname = self.expect(TokenType.IDENT).lexeme
            # D4（T0 布局规格 §2.2）：字段形 `id: int` 的 `:` 后必有类型 ⇒ COLON_DECL
            self.expect(TokenType.COLON_DECL)
            ftype = self.parse_type()
            # field tags: consume optional tags like `, mut`, `, pub` after type
            while self.check(TokenType.COMMA) and self.peek().type in (TokenType.MUT, TokenType.PUB):
                self.advance()  # skip comma
                self.advance()  # skip tag
            fields.append((fname, ftype))
            if self.check(TokenType.COMMA):
                self.advance()
        self.expect(TokenType.DEDENT)
        return StructDecl(is_pub, name, generics, fields)

    def parse_enum_decl(self, is_pub):
        self.expect(TokenType.ENUM)
        name = self.expect(TokenType.IDENT).lexeme
        generics = self._parse_generics()
        self._expect_region()
        variants = []
        while True:
            self._consume_newlines()
            if self.check(TokenType.DEDENT) or self.check(TokenType.EOF):
                break
            # `None` ⇒ `none` 是关键字 ⇒ 变体名仍收 NONE（保留今日「以 None 为变体名」的接受面）；
            # `Some` 已退休成 IDENT ⇒ 走 expect(IDENT)。
            if self.check(TokenType.NONE):
                vname = self.advance().lexeme
            else:
                vname = self.expect(TokenType.IDENT).lexeme
            types = []
            if self.check(TokenType.LPAREN):
                self.advance()
                if not self.check(TokenType.RPAREN):
                    types.append(self.parse_type())
                    while self.check(TokenType.COMMA):
                        self.advance()
                        types.append(self.parse_type())
                self.expect(TokenType.RPAREN)
            variants.append((vname, types))
            if self.check(TokenType.COMMA):
                self.advance()
        self.expect(TokenType.DEDENT)
        return EnumDecl(is_pub, name, generics, variants)

    def parse_interface_decl(self, is_pub):
        self.expect(TokenType.INTERFACE)
        name = self.expect(TokenType.IDENT).lexeme
        generics = self._parse_generics()
        self._expect_region()
        methods = []
        while True:
            self._consume_newlines()
            if self.check(TokenType.DEDENT) or self.check(TokenType.EOF):
                break
            self.expect(TokenType.FN)
            mname = self.expect(TokenType.IDENT).lexeme
            self.expect(TokenType.LPAREN)
            params = self._parse_param_list()
            self.expect(TokenType.RPAREN)
            self.expect(TokenType.ARROW)
            ret = self.parse_type()
            # D11（T0 布局规格 §2.2）：接口方法**无 `:`** ⇒ 行边界收尾。
            # ⚠ 带默认体的接口方法**本批不支持**：它要在 `InterfaceDecl.methods` 的
            #   三元组里加一个 body 槽 ⇒ 动 `ast.py` ⇒ 违 J-T1-1 冻结。此处**响亮报错**（不静默吞体）。
            self._end_decl()
            methods.append((mname, params, ret))
        self.expect(TokenType.DEDENT)
        return InterfaceDecl(is_pub, name, generics, methods)

    def parse_impl_decl(self):
        self.expect(TokenType.IMPL)
        generics = self._parse_generics()
        trait = None
        for_type = self.parse_path()
        if self.check(TokenType.FOR):
            self.advance()
            trait = for_type
            for_type = self.parse_path()
        self._expect_region()
        methods = []
        while True:
            self._consume_newlines()
            if self.check(TokenType.DEDENT) or self.check(TokenType.EOF):
                break
            methods.append(self.parse_function_decl(False))
        self.expect(TokenType.DEDENT)
        return ImplDecl(generics, trait, for_type, methods)

    def parse_type_alias(self):
        self.expect(TokenType.TYPE)
        name = self.expect(TokenType.IDENT).lexeme
        self.expect(TokenType.EQ)
        typ = self.parse_type()
        self._end_decl()
        return TypeAliasDecl(name, typ)

    def _parse_new_let_decl(self):
        from corec.syntax.ast import LetDecl
        names, tags, typ, values = self._parse_var_decl_names_tags_type()
        self._end_decl()
        return LetDecl(names=names, tags=tags, type_=typ, values=values)
