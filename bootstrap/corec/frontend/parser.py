import sys
sys.path.insert(0, 'bootstrap')
from corec.syntax.tokens import Token, TokenType
from corec.syntax.ast import *

class Parser:
    def __init__(self, tokens: list):
        self.tokens = tokens
        self.pos = 0
        self.const_values = {}

    def _scan_constants(self):
        """Pre-scan for 'let NAME: TYPE = VALUE;' declarations to resolve array sizes."""
        save = self.pos
        while not self.check(TokenType.EOF):
            if (self.check(TokenType.LET) and
                self._check_seq([TokenType.LET, TokenType.IDENT, TokenType.COLON,
                                 TokenType.IDENT, TokenType.EQ, TokenType.INT_LIT,
                                 TokenType.SEMI])):
                self.advance()  # let
                name = self.advance().lexeme  # NAME
                self.advance()  # :
                type_name = self.advance().lexeme  # int/float/bool
                self.advance()  # =
                val = int(self.advance().lexeme)  # VALUE
                self.const_values[name] = val
                self.advance()  # ; (skip to keep pos consistent)
            else:
                self.advance()
        self.pos = save

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

    # ─── 顶层 ───
    def parse_compilation_unit(self) -> CompilationUnit:
        self._scan_constants()
        modules, imports = self._parse_module_and_imports()
        declarations = []
        while not self.check(TokenType.EOF):
            declarations.append(self.parse_top_level_decl())
        return CompilationUnit(modules, imports, declarations)

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
        self.expect(TokenType.SEMI)
        return ModuleDecl(path)

    def parse_import_decl(self):
        self.expect(TokenType.IMPORT)
        path = self.parse_path()
        alias = None
        if self.check(TokenType.AS):
            self.advance()
            alias = self.expect(TokenType.IDENT).lexeme
        self.expect(TokenType.SEMI)
        return ImportDecl(path, alias)

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
        elif self.check(TokenType.LET):
            return self.parse_let_decl()
        self.error(f"Unexpected '{self.cur().lexeme}' at top level")

    def parse_function_decl(self, is_pub):
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
        if self.check(TokenType.EQ):
            self.advance()
            body = self.parse_expr()
            self.expect(TokenType.SEMI)
            return FunctionDecl(is_pub, name, generics, params, ret, body)
        body = self.parse_block()
        return FunctionDecl(is_pub, name, generics, params, ret, body)

    def _parse_generics(self):
        if self.check(TokenType.LBRACK):
            self.advance()
            names = [self.expect(TokenType.IDENT).lexeme]
            while self.check(TokenType.COMMA):
                self.advance()
                names.append(self.expect(TokenType.IDENT).lexeme)
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
        if self.check(TokenType.SELF):
            name = self.advance().lexeme
            typ = None
            if self.check(TokenType.COLON):
                self.advance()
                typ = self.parse_type()
            return (name, typ)
        name = self.expect(TokenType.IDENT).lexeme
        self.expect(TokenType.COLON)
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
        base_types = {'int','float','bool','string','char','unit','never'}
        if self.check(TokenType.SELF_TYPE):
            self.advance()
            return BaseType('Self')
        if self.check(TokenType.IDENT) and self.cur().lexeme in base_types:
            return BaseType(self.advance().lexeme)
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
        if self.check(TokenType.LET):
            self.advance()
            mutable = False
            if self.check(TokenType.MUT):
                mutable = True
                self.advance()
            name = self.expect(TokenType.IDENT).lexeme
            typ = None
            if self.check(TokenType.COLON):
                self.advance()
                typ = self.parse_type()
            self.expect(TokenType.EQ)
            val = self.parse_expr()
            return LetStmt(mutable, name, typ, val)
        if self.check(TokenType.MOVE):
            self.advance()
            name = self.expect(TokenType.IDENT).lexeme
            self.expect(TokenType.EQ)
            val = self.parse_expr()
            return Move(name, val)
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
        left = self.parse_equality()
        while self.check(TokenType.AND_AND):
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
        if self.check(TokenType.SOME) or self.check(TokenType.NONE) or self.check(TokenType.SELF):
            return Ident(self.advance().lexeme)
        if self.check(TokenType.INT_LIT):
            return Literal(int(self.advance().lexeme), 'int')
        if self.check(TokenType.FLOAT_LIT):
            return Literal(float(self.advance().lexeme), 'float')
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
            if ident_name[0].isupper() and self.check(TokenType.LBRACE) and self._is_struct_lit(self.pos):
                self.advance()  # consume {
                fields = []
                while not self.check(TokenType.RBRACE):
                    fname = self.expect(TokenType.IDENT).lexeme
                    if self.check(TokenType.EQ):
                        self.advance()
                    elif self.check(TokenType.COLON):
                        self.advance()
                    else:
                        self.expect(TokenType.EQ)
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
            return self.parse_block()
        if self.check(TokenType.IF):
            return self.parse_if_expr()
        if self.check(TokenType.MATCH):
            return self.parse_match_expr()
        if self.check(TokenType.LOOP):
            return self.parse_loop_expr()
        if self.check(TokenType.FOR):
            return self.parse_for_expr()
        if self.check(TokenType.GO):
            self.advance(); return Go(self.parse_expr())
        if self.check(TokenType.AWAIT):
            self.advance(); return Await(self.parse_expr())
        if self.check(TokenType.UNSAFE):
            self.advance(); return Unsafe(self.parse_block())
        self.error(f"Unexpected token: {self.cur().lexeme}")

    def _is_struct_lit(self, brace_pos):
        """Check if at brace_pos we have a struct literal rather than a block.

        Scans for ';' inside the braces — a semicolon at depth 1 means block,
        not struct literal. Also requires first field to start with IDENT =/:."""
        pos = brace_pos + 1
        if pos >= len(self.tokens):
            return False
        # Empty braces {}
        if self.tokens[pos].type == TokenType.RBRACE:
            return True
        # Must start with IDENT = or IDENT :
        if self.tokens[pos].type != TokenType.IDENT:
            return False
        if pos + 1 >= len(self.tokens):
            return False
        nxt = self.tokens[pos + 1].type
        if nxt != TokenType.EQ and nxt != TokenType.COLON:
            return False
        # Scan for ; at depth 1 (top level), tracking all bracket types
        depth = 1
        limit = min(brace_pos + 100, len(self.tokens))
        for i in range(brace_pos + 1, limit):
            tt = self.tokens[i].type
            if tt in (TokenType.LBRACE,): depth += 1
            elif tt in (TokenType.RBRACE,): depth -= 1
            elif tt in (TokenType.LBRACK, TokenType.LPAREN): depth += 1
            elif tt in (TokenType.RBRACK, TokenType.RPAREN): depth -= 1
            if depth == 0:
                break
            if tt == TokenType.SEMI and depth == 1:
                return False  # ; at top level -> block
        return True

    def parse_block(self) -> Block:
        self.expect(TokenType.LBRACE)
        stmts = []
        expr = None
        while not self.check(TokenType.RBRACE) and not self.check(TokenType.EOF):
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
        self.expect(TokenType.RBRACE)
        return Block(stmts, expr)

    def parse_stmt(self):
        if self.check(TokenType.LET):
            self.advance()
            mut = False
            if self.check(TokenType.MUT):
                mut = True
                self.advance()
            name = self.expect(TokenType.IDENT).lexeme
            typ = None
            if self.check(TokenType.COLON):
                self.advance()
                typ = self.parse_type()
            val = None
            if self.check(TokenType.EQ):
                self.advance()
                val = self.parse_expr()
            self.expect(TokenType.SEMI)
            return LetStmt(mut, name, typ, val)
        elif self.check(TokenType.RETURN):
            self.advance()
            val = None
            if not self.check(TokenType.SEMI) and not self.check(TokenType.RBRACE):
                val = self.parse_expr()
            if self.check(TokenType.SEMI):
                self.advance()
            return ReturnStmt(val)
        elif self.check(TokenType.BREAK):
            self.advance()
            if self.check(TokenType.SEMI):
                self.advance()
            return BreakStmt()
        elif self.check(TokenType.CONTINUE):
            self.advance()
            if self.check(TokenType.SEMI):
                self.advance()
            return ContinueStmt()
        else:
            e = self.parse_expr()
            if self.check(TokenType.SEMI):
                self.advance()
                return ExprStmt(e)
            return e

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
        self.expect(TokenType.LBRACE)
        arms = []
        while not self.check(TokenType.RBRACE) and not self.check(TokenType.EOF):
            pat = self.parse_pattern()
            self.expect(TokenType.FAT_ARROW)   # 使用 =>
            body = self.parse_expr()
            arms.append(MatchArm(pat, body))
            if self.check(TokenType.COMMA):
                self.advance()
        self.expect(TokenType.RBRACE)
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
        # 标识符或关键字作为模式
        if self.check(TokenType.IDENT) or self.check(TokenType.SOME) or self.check(TokenType.NONE):
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
        self.expect(TokenType.LBRACE)
        fields = []
        while not self.check(TokenType.RBRACE):
            fname = self.expect(TokenType.IDENT).lexeme
            self.expect(TokenType.COLON)
            ftype = self.parse_type()
            fields.append((fname, ftype))
            if self.check(TokenType.COMMA):
                self.advance()
        self.expect(TokenType.RBRACE)
        return StructDecl(is_pub, name, generics, fields)

    def parse_enum_decl(self, is_pub):
        self.expect(TokenType.ENUM)
        name = self.expect(TokenType.IDENT).lexeme
        generics = self._parse_generics()
        self.expect(TokenType.LBRACE)
        variants = []
        while not self.check(TokenType.RBRACE):
            vname = None
            if self.check(TokenType.SOME) or self.check(TokenType.NONE):
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
        self.expect(TokenType.RBRACE)
        return EnumDecl(is_pub, name, generics, variants)

    def parse_interface_decl(self, is_pub):
        self.expect(TokenType.INTERFACE)
        name = self.expect(TokenType.IDENT).lexeme
        generics = self._parse_generics()
        self.expect(TokenType.LBRACE)
        methods = []
        while not self.check(TokenType.RBRACE):
            self.expect(TokenType.FN)
            mname = self.expect(TokenType.IDENT).lexeme
            self.expect(TokenType.LPAREN)
            params = self._parse_param_list()
            self.expect(TokenType.RPAREN)
            self.expect(TokenType.ARROW)
            ret = self.parse_type()
            self.expect(TokenType.SEMI)
            methods.append((mname, params, ret))
        self.expect(TokenType.RBRACE)
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
        self.expect(TokenType.LBRACE)
        methods = []
        while not self.check(TokenType.RBRACE):
            methods.append(self.parse_function_decl(False))
        self.expect(TokenType.RBRACE)
        return ImplDecl(generics, trait, for_type, methods)

    def parse_type_alias(self):
        self.expect(TokenType.TYPE)
        name = self.expect(TokenType.IDENT).lexeme
        self.expect(TokenType.EQ)
        typ = self.parse_type()
        self.expect(TokenType.SEMI)
        return TypeAliasDecl(name, typ)

    def parse_let_decl(self):
        from corec.syntax.ast import LetDecl
        self.expect(TokenType.LET)
        mut = False
        if self.check(TokenType.MUT):
            mut = True
            self.advance()
        name = self.expect(TokenType.IDENT).lexeme
        typ = None
        if self.check(TokenType.COLON):
            self.advance()
            typ = self.parse_type()
        val = None
        if self.check(TokenType.EQ):
            self.advance()
            val = self.parse_expr()
        self.expect(TokenType.SEMI)
        return LetDecl(mut, name, typ, val)
