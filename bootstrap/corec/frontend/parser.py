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
        # `want_value` = **位置语义**标志（v4 权威依据 `docs/developer/syntax.md`
        # §7.4「函数没有 implicit tail return」+ §4.1「region 作声明右值取尾值」）。
        #
        # 起因：v4 无 `;` ⇒ v3 里 `x = 1;` 的 ExprStmt 形态消失，语句末的裸表达式会被
        # parse_block 一律当**尾值**（Block.expr）⇒ 块类型由 unit 变 int ⇒ 函数推断返回
        # 类型漂移 ⇒ checker 刷 `expected return type` / `If branches have different types`。
        #
        # 规则（唯一措辞）：
        #   ① **语句位** region（函数体、if/else 语句体、loop/for/while 体、独立的
        #      `unsafe:`/`flow:` 语句）的末项收尾 = **按节点种类**：
        #        · 控制流类（`If`/`Loop`/`For`/`Match`/`Unsafe`，另含 `Flow`）⇒ **保留
        #          `Block.expr`（尾值）**——v3 里控制流语句本来就不带 `;`（以 `}` 收尾）⇒
        #          本来就是块的尾值；
        #        · 其余（赋值/调用/二元/一元/字面量/`Ident`/索引…）⇒ 包 `ExprStmt`
        #          （等价 v3 带 `;` 的表达式语句），region 视为无值。
        #      判据 = **v3 逐形等价**（维护者四格实测），详见 `_is_block_like` 的 docstring。
        #   ② **表达式位** region（声明/赋值右值、return 值、调用实参、括号内、索引、
        #      二元/一元操作数、match 臂 `=> Expr`）⇒ 一律保留 Block.expr；
        #      ⇒ 收尾最终由 **位置标志 ∧ 节点种类** 两个条件共同决定。
        #   ③ 递归：`if`/`unsafe`/`flow` 的 region 位置 = **该表达式自身**的位置
        #      （`x := if c: a else: b` 两臂在表达式位；语句位 `if c: … else: …` 两臂在语句位）。
        #
        # 机制：表达式位入口置 True（`_want_value_expr()`），语句位入口（`parse_stmt`）置 False；
        # `parse_block` 进入时读该标志决定尾值去留，并把标志复位为 False（嵌套 region 默认语句位），
        # 退出时**恢复**为进入值（同层兄弟 region 位置不变）。
        self.want_value = False

    def _want_value_expr(self) -> Expr:
        """表达式位入口：置 `want_value` 后解析一个表达式（region 在此保尾值）。"""
        self.want_value = True
        return self.parse_expr()

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

        第三态：**刚吃掉 DEDENT**（= region 收尾）也构成行边界。`_expect_region` 的
        反向操作由块产生式完成（`expect(DEDENT)`），此时 lexer 已把下一行的首 token
        接在 DEDENT 之后（token 次序 NEWLINE → DEDENT → 下一行首 token），所以
        「prev == DEDENT」等价于「站在新一行的行首」。少了这条，`x := unsafe: …`
        这类**以 region 收尾的声明/表达式**会在 `_end_decl` 处被误判为「同行还有 token」。
        """
        if self.pos > 0 and self.tokens[self.pos - 1].type == TokenType.DEDENT:
            return True
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
        """吃 region 头：`COLON_BLOCK` 行尾冒号 + 其后的 NEWLINE + （可选）`INDENT`。
        返回 True = 吃到 `INDENT`（region 有 items）；**False = 空 region**（无 INDENT、无 items）。

        token 次序由 lexer 的 `_layout_break` 决定：NEWLINE 先于 INDENT/DEDENT。
        **行内 `:`（`COLON_DECL`）在此被响亮拒绝** —— 这正是 T0 布局规格 §2.2 要的
        「行尾类型标注不是合法文本」的兜住点。

        v4 裁定（2026-10-11，**推翻** T0 布局规格 §10.2 的「空 region 无法表达 + 逐处改写」）：
        **region 可以为空**。用途实证（T6b 报来、维护者采纳）：`loop { }`（**永不返回**，与
        `loop:` + 裸 `return` **不等价**）与 `interface Empty { }`（**零方法接口**，合法且有意义）
        在「逐处改写」下无等价形。**只放宽零项这一格**：非零项 region 的缩进规则一个字不动。
        """
        self.expect(TokenType.COLON_BLOCK)
        self._consume_newlines()
        if self.check(TokenType.INDENT):
            self.advance()
            return True
        return False

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
            values = [self._want_value_expr()]   # 声明右值 = 表达式位（规则 ②）
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
            values.append(self._want_value_expr())   # 声明右值 = 表达式位（规则 ②）
            while self.check(TokenType.COMMA):
                self.advance()
                values.append(self._want_value_expr())
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
        if self.check(TokenType.COLON_DECL):
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
    # v4 文档 §13：**声明前导** `@` 注解的白名单（§13 全量扫描的结果）。
    # §13.5 `@ffi("…")` → `extern fn`；§13.6 `@hotpatch(ver=N)` → `fn`；
    # §13.7 `@preferredDomain(name)` → `fn`、`@executionDomain(name)` → `flow`。
    # 其余 `@` 名（§13.2 的 `@inline`/`@unroll`/`@section`/`@comptime`/`@fast`、
    # §13.3 `@addr`、§13.4 `@NoBoundsCheck`、§13.1 的查询族）在文档里**只作表达式/语句位**
    # 出现（语料同：`tests/suite/at_test.cr:46` 的 `@NoBoundsCheck` 是 region 内语句，
    # 走 parse_stmt→parse_expr）⇒ **不入白名单**（在声明前导位出现即响亮报错）。
    _LEAD_AT_NAMES = ('hotpatch', 'ffi', 'preferredDomain', 'executionDomain')

    def _skip_leading_at_annotations(self):
        """消费顶层声明的**前导 `@` 注解链**（一至多条，各自独占一行；v4 §13 的声明前导形）。

        **语义面 = 接受并跳过**：bootstrap 侧没有 hotpatch 版本表 / FFI 语言槽 / 执行域数据面
        （自源侧的 `@hotpatch` 版本进 `EXPR_FN` 的 iv 槽、`@ffi` 进 `ffi_lang_ni`）⇒ 本侧只保证
        「能词法化、不报错、不影响产物」，与既有 `_skip_spec_annotations` 同口径。
        **不知名名字**与**未闭合括号**一律响亮报错 —— 「放宽 = 吞错」是静默面
        （`@hotpach(ver=1)` 的笔误若不报，注解就被静默丢弃）。
        """
        while self.check(TokenType.AT):
            self.advance()                      # '@'
            if not self.check(TokenType.IDENT):
                self.error("expected annotation name after '@'")
            name = self.advance().lexeme
            if name not in self._LEAD_AT_NAMES:
                self.error(f"Unknown top-level '@{name}' annotation (expected '@hotpatch' / "
                           f"'@ffi' / '@preferredDomain' / '@executionDomain')")
            if self.check(TokenType.LPAREN):
                depth = 1
                self.advance()
                while depth > 0:
                    if self.check(TokenType.EOF):
                        self.error("unterminated '@' annotation: missing ')'")
                    if self.check(TokenType.LPAREN):
                        depth += 1
                    elif self.check(TokenType.RPAREN):
                        depth -= 1
                    self.advance()
            self._consume_newlines()            # 注解之间可换行（文档形）

    def parse_top_level_decl(self):
        self._skip_leading_at_annotations()
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
            return self.parse_type_alias(is_pub)
        elif self.check(TokenType.IDENT) and self._is_var_decl_start():
            return self._parse_new_let_decl()
        self.error(f"Unexpected '{self.cur().lexeme}' at top level")

    def parse_function_decl(self, is_pub, is_flow=False):
        if not is_flow:
            self.expect(TokenType.FN)
        elif self.check(TokenType.FN):
            # v4 文档形（2026-10-11 裁：文档是目标语法 ⇒ 改实现）：
            # `docs/developer/syntax.md` `flow counter(start: int) -> int:`、
            # `:1406` `flow encode(input: Frame) -> Packet:` —— **无 `fn`**。
            # 本侧原先**只**认文档形；此处补收旧形 `flow fn name(...)` 为**兼容**
            # （语料 `src/compiler/purity_selftest.cr:231` 用它；文档不写它、不为它新增用例）。
            # ⇒ 改后与自源**同收两形**（自源原先只认 `flow fn`，同批补齐文档形）。
            self.advance()
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
        # Function tail tags: `fn f(...) -> T, pub:`. Tags are declaration labels,
        # not a prefix modifier. The bootstrap parser only needs the visibility bit;
        # unknown tags fail closed so typos are not silently ignored.
        if self.check(TokenType.COMMA):
            self.advance()
            while not (self.check(TokenType.COLON_BLOCK) or self.check(TokenType.EQ) or self._at_line_end()):
                if self.check(TokenType.PUB):
                    self.advance()
                    is_pub = True
                elif self.check(TokenType.IDENT):
                    tag = self.advance().lexeme
                    self.error(f"unknown function tag '{tag}'")
                else:
                    self.error(f"unknown function tag '{self.cur().lexeme}'")
                if not self.check(TokenType.COMMA):
                    break
                self.advance()
        # 批 6（裁-S7，bounded）：规约标注链 `#check(...)` / `#ensure(...)`——**接受并跳过**。
        # 位置与 self-hosted 侧一一对应（签名之后、body 之前）；**零语义**。
        self._skip_spec_annotations()   # inline 形（兼容）：注解后紧跟 `:`，不要求行尾
        if self.check(TokenType.EQ):
            self.advance()
            body = self._want_value_expr()   # `fn f() = expr` 的值 = 表达式位（规则 ②）
            self._end_decl()
            return FunctionDecl(is_pub, name, generics, params, ret, body)
        # D9/D10（T0 布局规格 §2.2）：有体 ⇒ 行尾 `:`（COLON_BLOCK）开 region；
        # 无体（`extern fn read(fd: int) -> int`）⇒ 行边界，无 `:`。
        if self._at_line_end():
            return FunctionDecl(is_pub, name, generics, params, ret, None)
        # 规则 ①：函数体 region **恒为语句位**（§7.4「函数没有 implicit tail return」）⇒
        # 末项裸表达式包 ExprStmt，块类型 unit ⇒ 返回值只经显式 `return`。
        self.want_value = False
        # v4 文档 §10.1（**文档形**）：规约注解位于函数 layout region 的**开头**（statements 之前）
        # ⇒ 此处自己吃 region 头，先收 `#check`/`#ensure`，再进 statements。
        # inline 形（签名与 `:` 之间，见上方 `_skip_spec_annotations()` 的第 1 个调用点）
        # **保留为兼容**：不在文档里，但 `tests/spec` 的干净档有工具产出。
        if not self._expect_region():
            # 空函数体（§10.2 裁定推翻后合法）：零项 ⇒ 值 = 无值（块类型 unit）。
            body = Block([], None)
        else:
            self._skip_spec_annotations(need_eol=True)   # 文档形：注解独占一行
            body = self.parse_block_items()
        if is_flow:
            body = Flow(body)
        return FunctionDecl(is_pub, name, generics, params, ret, body)

    def _skip_spec_annotations(self, need_eol=False):
        """批 6（裁-S7，bounded）：消费 `#` IDENT `(` … `)` 标注链并**丢弃**（零语义）。

        边界（维护者裁定）：bootstrap 侧**只**保证「能词法化、不报错、不影响产物」——
        不建 VC、不做三态、不做名字域/类型检查（完整 bootstrap 规约面登记后续）。
        消费 = 平衡括号扫描（不解析表达式）⇒ 对内部形态（含 `result` 等 bootstrap 关键字）
        一律容忍；形状错（缺 IDENT/缺括号/未闭合）**响亮报错**（fail-loud，不静默）。
        """
        # 循环**末尾**的 `_consume_newlines()` 让注解链跨行成立（文档形 §10.1：每条独占一行）。
        # ⚠ 只跳「注解之间」，**不跳第一条之前** —— 首条之前若有 NEWLINE（无体声明的收尾），
        #   在循环头吞掉它会让调用点的 `_at_line_end()` 误判「非行边界」（回归面）。
        while self.check(TokenType.HASH):
            self.advance()                      # '#'
            if not self.check(TokenType.IDENT):
                self.error("expected annotation name after '#'")
            an_name = self.advance().lexeme      # check / ensure
            # 名字白名单与自源同判（自源 = `parse_spec_annotations` 的 kind 分派 ⇒ 非此二者
            # 一律 EC_V_BAD_TAG/V02）。**这不是新增限制**：文档 §10.1 只给 `#check`/`#ensure`
            # 两形；而「放宽 = 吞错」是静默面（`#foo(1)` 这类误写若不报，注解被静默丢弃）。
            # 语料实核：`src/**`+`tests/**` 的真代码里 `#` 注解**只有** check/ensure
            # （`#include`/`#tag`/`#x` 全在注释、C 文件或 python f-string 内；唯一例外
            # `tests/spec/t2_neg_unknowntag.cr` 本就是**负例**，期望报错）。
            if an_name not in ('check', 'ensure'):
                self.error(f"Unknown annotation '#{an_name}' (expected '#check' or '#ensure')")
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
            # 文档形：注解必须**独占一行**（v4 行语义 = 一条语句一行）⇒
            # `#check(1 > 0) return 1` 同行是**非法文本**（负例档
            # `tests/spec/t2_neg_inbody.cr` 逐字如此，必须 rc=1）。
            # inline 形那侧（need_eol=False）注解后紧跟 `:` ⇒ 不能要行尾。
            if need_eol and not self._at_line_end():
                self.error(f"Expected end of line after '#{an_name}' annotation")
            self._consume_newlines()            # 注解之间可换行（文档形，见上方注）

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
        # v4：`Self` 不再进关键字表（计划 §一.5 的 `bootstrap − v4` 差集含 `Self`）
        # ⇒ 它以 IDENT 到达；保留「`&Self` 是原生名不是泛型形参」的既有行为
        # （先例：`never` 今天也走这条 base_types 路径）。**若漏掉本格**，
        # `&Self` 会变成 `PathType(['Self'])`，而 type_checker 的 `_is_generic_type`
        # 把「单元素 PathType」当泛型形参 ⇒ 静默错判（不是报错）。
        base_types = {'int','dex','bool','string','char','unit','never','Self'}
        # ⚠ 基本类型**不早退**（2026-10-11 修；出处 = docs/developer/syntax.md §3.2
        #   的两行原文 `parent : User? = none` / `value : int? = 5`）。
        #   修前：本格直接 `return BaseType(...)`，而 `?` 的处理在函数**尾部**、只管 `PathType`
        #   ⇒ `int?` 落到「expected end of line, got '?'」（`Foo?` 却正常）——基本类型与路径类型
        #   **两条不同的收尾路**，两前端在这一格分歧，且卡 T6 语料（`g : dex?, mut = None` /
        #   `struct SOpt { f: dex? }` / `enum EOpt { V(dex?) }` / `empty : int? = none`）。
        #   **选「并入同一条尾部」而不是「在早退前再写一份 `?` 处理」**：后者 = 同一判定两份实现
        #   （本仓 T0 §2.3 明令禁止的形态，必然漂）；前者 `?` 处理**只有一处**，基本类型与路径类型
        #   共用，新增接受面恰好是 `T?`（含 `unit?`/`never?`——自源同收）。
        # `never`/`dyn` 是**关键字令牌**（上方 base_types 那格看不到它们）⇒ 同链并列一格。
        # 自源对 `never?`/`dyn?` 与 `int?` 同判（实测 `fn f(a: never?) -> int` ⇒ rc=0）
        # ⇒ 本侧必须同收，否则留残余分歧。
        # v4 relational type expression `typeof(expr)`: the bootstrap does not
        # model relational types; consume the expression and return None so the
        # let/param checker infers from the initializer (same behavior as `auto`).
        if self.check(TokenType.IDENT) and self.cur().lexeme == 'typeof':
            self.advance()
            self.expect(TokenType.LPAREN)
            self.parse_expr()
            self.expect(TokenType.RPAREN)
            return None
        if self.check(TokenType.NEVER):
            self.advance()
            typ = BaseType('never')
        elif self.check(TokenType.DYN):
            self.advance()
            typ = BaseType('dyn')
        elif self.check(TokenType.IDENT) and self.cur().lexeme in base_types:
            typ = BaseType(self.advance().lexeme)
        elif self.check(TokenType.UNIT):
            self.advance()
            typ = BaseType('unit')
        else:
            typ = PathType(self.parse_path())
            if self.check(TokenType.LBRACK):
                self.advance()
                args = [self.parse_type()]
                while self.check(TokenType.COMMA):
                    self.advance()
                    args.append(self.parse_type())
                self.expect(TokenType.RBRACK)
                typ = GenericApplyType(typ.path, args)
        # `T?` 的唯一处理点（基本类型与路径类型同路）
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
            right = self._want_value_expr()   # 赋值右值 = 表达式位（规则 ②）
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
                        args.append(self._want_value_expr())   # 实参 = 表达式位（规则 ②）
                        while self.check(TokenType.COMMA):
                            self.advance()
                            args.append(self._want_value_expr())
                    self.expect(TokenType.RPAREN)
                    node = EnumConstructor([node.name], args)
                else:
                    self.advance()
                    args = []
                    if not self.check(TokenType.RPAREN):
                        args.append(self._want_value_expr())   # 实参 = 表达式位（规则 ②）
                        while self.check(TokenType.COMMA):
                            self.advance()
                            args.append(self._want_value_expr())
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
                    idx = self._want_value_expr()   # 下标 = 表达式位（规则 ②）
                    self.expect(TokenType.RBRACK)
                    node = Index(node, idx)
                else:
                    # array literal [e1, e2, ...]
                    elements = []
                    if not self.check(TokenType.RBRACK):
                        elements.append(self._want_value_expr())
                        while self.check(TokenType.COMMA):
                            self.advance()
                            elements.append(self._want_value_expr())
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
                    args.append(self._want_value_expr())   # 实参 = 表达式位（规则 ②）
                    while self.check(TokenType.COMMA):
                        self.advance()
                        args.append(self._want_value_expr())
                self.expect(TokenType.RPAREN)
                return Builtin(first, args)
            if self.check(TokenType.IDENT):
                file_id = self.advance().lexeme
                self.expect(TokenType.PATH_SEP)
                symbol = self.expect(TokenType.IDENT).lexeme
                return Ident(f"@{first}.{file_id}::{symbol}")
            return Builtin(first, [])
        if self.check(TokenType.NONE):
            # v4（docs/developer/syntax.md §1.4/§59）：`none` 是 `T?` 的**无值形态**关键字，
            # canonical 变体名 = `None`。归一到 canonical 名（与自源 `parser.cr` 的
            # `T_NONE` → `EXPR_ENUM_CONSTRUCTOR(str_intern("None"))` **同语义**）；零载荷。
            # ⚠ 拼写面归一必须在此**单点**完成：`None`（旧大写）已退役为普通标识符，两者不同判。
            self.advance()
            return EnumConstructor(['None'], [])
        if self.check(TokenType.SELF):
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
                    val = self._want_value_expr()   # 字段值 = 表达式位（规则 ②）
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
            first = self._want_value_expr()   # 数组元素 = 表达式位（规则 ②）
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
                elements.append(self._want_value_expr())
            self.expect(TokenType.RBRACK)
            return ArrayLit(elements)
        if self.check(TokenType.LPAREN):
            self.advance()
            e = self._want_value_expr()   # 括号内 = 表达式位（规则 ②）
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
        """region 头 + 体（**所有** region 的通用入口）。空 region ⇒ `Block([], None)`。"""
        if not self._expect_region():
            want = self.want_value
            self.want_value = want
            return Block([], None)      # 空 region：零 items、无 DEDENT 可吃
        return self.parse_block_items()

    def parse_block_items(self) -> Block:
        """体（**region 头已吃掉**）。拆出本函数只为「函数体 region 的**开头若干项** =
        规约注解」（v4 文档 §10.1，见 `parse_function_decl` 的调用点）——那里必须在
        statements 之前先把 `#check`/`#ensure` 收干净（`parse_block` 那条通用路做不到）。

        尾表达式判定（T0 布局规格 §6.2 A1）：**region 的最后一项 = 该 region 的值**，
        其余各项按语句处理 —— 即原 `parse_block` 的「暂定尾表达式」逻辑原样保留，
        只是「还有下一项」的判据由「不是 `}`」变成「不是 DEDENT」。
        """
        # 位置语义（§7.4 + §4.1，见 `__init__` 的 `want_value`）：本 region 的尾值去留
        # 由**进入时**的标志决定；体内嵌套 region 一律先复位为语句位，退出时恢复。
        want = self.want_value
        self.want_value = False
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
        self.want_value = want
        if not want and expr is not None and not self._is_block_like(expr):
            # 语句位 region + 末项是**普通**裸表达式（赋值/调用/二元/一元/字面量/`Ident`/索引…）
            # ⇒ 包 ExprStmt（等价 v3 的 `expr;`），region 视为无值。
            stmts.append(ExprStmt(expr))
            expr = None
        return Block(stmts, expr)

    @staticmethod
    def _is_block_like(expr: Expr) -> bool:
        """语句位 region 的**控制流**尾项 —— 判据 = **v3 逐形等价**（维护者裁定）。

        口径（唯一措辞）：收尾判定 = **位置标志 ∧ 节点种类**两个条件共同决定 ——
        位置为语句位时，**控制流类**尾项（`If`/`Loop`/`For`/`Match`/`Unsafe`）**保留为
        `Block.expr`（尾值）**；其余一律包 `ExprStmt`。表达式位（`want_value=True`）则一切照旧
        保留尾值（`x := if c: a else: b` 的分支尾值必须是值）。

        依据 = v3 的**实际形态**：v3 里控制流语句本来就不带 `;`（`if`/`loop`/`while`/`for`/
        `match`/`unsafe` 以 `}` 收尾）⇒ 它们在 v3 里**本来就是块的尾值**；真正分叉的只是
        「**带 `;` 的表达式语句**」——那才是 v3 的 `ExprStmt`。`;` 退场后，唯一能复原这层区分
        的判据就是**节点种类**。T4 是机械形状改写（只有 `{}`→缩进、`;`→换行两类）⇒ 它不该、
        也无法改变这层区分。

        维护者四格实测（v3 前端 @ bb8cb3537584 + v3 文本 / v4 前端 + v4 文本）：
            v3: 尾随 `if 1 > 0 { return 1; } else { return 2; }` → **0 条**类型告警
            v3: 尾随 `y = y + 1;`                          → **1 条**（expected int, got unit）
            v4: 尾随 `if …`                                → **0 条**（同上）
            v4: 尾随 `y = y + 1`                           → **1 条**（同上）
        一律包 ExprStmt（不看种类）会打破第一格：尾随 `if` 变 1 条 = **回归**，且
        `tools/v4_frontend_probe.py features` 的 `if / else`、`enum + match`×2、`unsafe region`
        四例立刻转红（实测 94 条里 5 FAIL）。

        `Flow` 一并纳入：同为「开 region、以 `}`/DEDENT 收尾」的块状形，v3 亦不带 `;`。
        （实测 `src/**` 无任何 `flow:` 语句 ⇒ 本项对现行语料零影响，仅为形状自洽。）
        `while` 无独立节点（`parse_while_expr` 直接 desugar 成 `Loop`）⇒ 已被覆盖。
        """
        return isinstance(expr, (If, Match, Loop, For, Unsafe, Flow))

    # 语句前导位 `@` 注解的白名单（与自源 `parser.cr::is_stmt_at_annotation` **逐名一致**）。
    # 实证清单 = 文档或语料在**语句/region 前导位**实际出现过的名字：
    #   §13.7 `preferredDomain` / `executionDomain`、§13.4 `NoBoundsCheck`、
    #   §13.2 `fast` / `unroll` / `section`。
    # **不收** §13.1 查询族 / §13.3 `addr` / §13.2 `inline`（文档里都在**表达式位**）。
    # ⚠ **判据 = 「文档释文 + 语料实证」，不是「章号范围」**（维护者 2026-10-11 采纳；
    #   与自源 `parser.cr::is_stmt_at_annotation` 同口径）。二者冲突时**以后者为准**：
    #   `NoBoundsCheck`(§13.4) / `fast`·`unroll`·`section`(§13.2) 章号属 §13.1–13.4，
    #   但释文与语料都在**语句前导位**用它们 ⇒ 收。**禁止**后人按章号再收窄回去。
    _STMT_AT_NAMES = ('preferredDomain', 'executionDomain', 'NoBoundsCheck',
                      'fast', 'unroll', 'section')

    def _skip_stmt_at_annotations(self):
        """消费语句前导位的 `@` 注解链（各占一行）。**语义面 = 接受并跳过**
        （bootstrap 侧无执行域/安全检查数据面，与顶层前导 `@` 同口径）。

        **未知名不在此列** ⇒ 仍按表达式解析 ⇒ 由既有路径响亮拒绝（不静默）。
        注解**独占一行**：违反即 `self.error`（响亮）。
        """
        while self.check(TokenType.AT):
            nxt = self.tokens[self.pos + 1] if self.pos + 1 < len(self.tokens) else None
            if nxt is None or nxt.type != TokenType.IDENT:
                break
            if nxt.lexeme not in self._STMT_AT_NAMES:
                break
            name = nxt.lexeme
            self.advance()                      # '@'
            self.advance()                      # 名字
            if self.check(TokenType.LPAREN):
                depth = 1
                self.advance()
                while depth > 0:
                    if self.check(TokenType.EOF):
                        self.error("unterminated '@' annotation: missing ')'")
                    if self.check(TokenType.LPAREN):
                        depth += 1
                    elif self.check(TokenType.RPAREN):
                        depth -= 1
                    self.advance()
            if not self._at_line_end():
                self.error(f"Expected end of line after '@{name}' annotation")
            self._consume_newlines()

    def parse_stmt(self):
        # 语句位入口（规则 ①）：本语句整体在语句位 ⇒ 先复位；语句内的表达式位由各入口重
        # 置 True（声明的右值 / return 值 / 实参 / 括号 / 索引 …）。
        self.want_value = False
        # v4 §13.7 第三例 / §13.4：**语句前导位**的 `@` 注解（`@preferredDomain(gpu)` 前导 `loop:`）。
        # 必须在此消费，否则 `@` 落进表达式路（自源侧实测会被 checker 当未知名内建报 N01）。
        self._skip_stmt_at_annotations()
        if self.check(TokenType.IDENT) and self._is_var_decl_start():
            names, tags, typ, values = self._parse_var_decl_names_tags_type()
            self._end_decl()
            return LetStmt(names=names, tags=tags, type_=typ, values=values)
        elif self.check(TokenType.RETURN):
            self.advance()
            val = None
            # A6：关键字之后**同一逻辑行内**无 token ⇒ 无值（行边界取代 `;`/`}`）
            if not self._at_line_end():
                val = self._want_value_expr()   # 表达式位：return 的值（规则 ②）
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
        # 规则 ③：两臂 region 的位置 = **本 if 表达式自身**的位置（进入时捕获，逐臂沿用；
        # `else if` 递归时同样把该位置传下去）。条件恒为表达式位。
        want = self.want_value
        self.expect(TokenType.IF)
        cond = self._want_value_expr()
        self.want_value = want
        then = self.parse_block()
        else_branch = None
        if self.check(TokenType.ELSE):
            self.advance()
            self.want_value = want
            if self.check(TokenType.IF):
                else_branch = self.parse_if_expr()
            else:
                else_branch = self.parse_block()
        self.want_value = want
        return If(cond, then, else_branch)

    def parse_match_expr(self):
        # 被匹配的值与臂体 `=> Expr` 恒为表达式位（规则 ②）；臂体不是 region（此处只吃
        # 单行表达式），故其内嵌 region 按表达式位保留尾值。
        want = self.want_value
        self.expect(TokenType.MATCH)
        expr = self._want_value_expr()
        has_items = self._expect_region()   # False = 空 region（§10.2 裁定推翻后合法）
        arms = []
        while True:
            if not has_items:
                break
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
            # v4 文档 §7.3（逐字）：「需要多行 arm body 时，`=>` 后换行并进入更深 layout」
            # ⇒ `=>` 后**行尾** ⟺ 臂体是一个 layout region；否则单表达式。
            # ⚠ 该 region **没有 `:`**（`=>` 已充当开启符）⇒ 不能走 `_expect_region`。
            # **兼容形 `=>:`**（`=>` 后紧跟 `:`）：文档 §7.3 没有这一形（那里是 `=>` 后直接换行），
            # 但 T6 语料机械改写成了它 ⇒ 按本批先例（`flow fn` 兼容形）收为兼容，与文档形同判。
            # 「臂体是 region」的判据必须在**消费 `:` 之前**定下 —— 消费后再问 `_at_line_end()`
            # 会因为站在 INDENT 上而误判成「非行边界」（实测踩过）。
            is_region = False
            if self.check(TokenType.COLON_BLOCK):
                is_region = True
                self.advance()
            elif self._at_line_end():
                is_region = True
            if is_region:
                self._consume_newlines()
                if self.check(TokenType.INDENT):
                    self.advance()
                    self.want_value = True          # 臂体 = 表达式位 ⇒ region 保尾值
                    body = self.parse_block_items()
                else:
                    body = Block([], None)          # 空 region（形态 D）
            else:
                body = self._want_value_expr()
            arms.append(MatchArm(pat, body))
            if self.check(TokenType.COMMA):
                self.advance()
        if has_items:
            self.expect(TokenType.DEDENT)
        self.want_value = want
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
        # 规则 ①：loop 体恒为**语句位** region（v3 里体末语句必带 `;` ⇒ 块类型 unit；
        # 本解析器无 `break value`，循环亦无值通道）⇒ 末项裸表达式包 ExprStmt。
        # 标志 save/restore：同层兄弟 region（如 `a + <loop> + <unsafe>`）位置不受影响。
        want = self.want_value
        self.expect(TokenType.LOOP)
        self.want_value = False
        blk = self.parse_block()
        self.want_value = want
        return Loop(blk)

    def parse_while_expr(self):
        """Desugar: while cond { body } → loop { if !cond { break; } body }"""
        want = self.want_value
        self.expect(TokenType.WHILE)
        cond = self._want_value_expr()
        self.want_value = False
        body = self.parse_block()
        self.want_value = want
        # Build: if !cond { break; }
        not_cond = UnaryOp("!", cond)
        break_block = Block([BreakStmt()], None)
        if_node = If(not_cond, break_block, None)
        # Prepend to body statements
        new_stmts = [ExprStmt(if_node)] + body.stmts
        new_block = Block(new_stmts, body.expr)
        return Loop(new_block)

    def parse_for_expr(self):
        # 规则 ①：for 体恒为语句位 region；被迭代表达式恒为表达式位。
        want = self.want_value
        self.expect(TokenType.FOR)
        var = self.expect(TokenType.IDENT).lexeme
        self.expect(TokenType.IN)
        iter = self._want_value_expr()
        self.want_value = False
        blk = self.parse_block()
        self.want_value = want
        return For(var, iter, blk)

    def _parse_decl_tail_tags(self, is_pub):
        """Consume declaration tail tags: `struct S, pub:` / `enum E, pub:`.

        Labels are trailing, matching `fn f(...), pub:`; a prefix `pub struct`
        is still accepted by parse_top_level_decl for older sources.
        """
        if not self.check(TokenType.COMMA):
            return is_pub
        self.advance()
        while not (self.check(TokenType.COLON_BLOCK) or self.check(TokenType.EQ)
                   or self.check(TokenType.NEWLINE) or self.check(TokenType.EOF)):
            if self.check(TokenType.PUB):
                self.advance()
                is_pub = True
            elif self.check(TokenType.IDENT):
                self.error(f"unknown declaration tag '{self.cur().lexeme}'")
            else:
                self.error(f"unknown declaration tag '{self.cur().lexeme}'")
            if not self.check(TokenType.COMMA):
                break
            self.advance()
        return is_pub

    def parse_struct_decl(self, is_pub):
        self.expect(TokenType.STRUCT)
        name = self.expect(TokenType.IDENT).lexeme
        generics = self._parse_generics()
        is_pub = self._parse_decl_tail_tags(is_pub)
        has_items = self._expect_region()   # False = 空 region（§10.2 裁定推翻后合法）
        fields = []
        while True:
            if not has_items:
                break
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
                                     TokenType.AUTO, TokenType.INTERFACE, TokenType.CAST):
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
        if has_items:
            self.expect(TokenType.DEDENT)
        return StructDecl(is_pub, name, generics, fields)

    def parse_enum_decl(self, is_pub):
        self.expect(TokenType.ENUM)
        name = self.expect(TokenType.IDENT).lexeme
        generics = self._parse_generics()
        is_pub = self._parse_decl_tail_tags(is_pub)
        has_items = self._expect_region()   # False = 空 region（§10.2 裁定推翻后合法）
        variants = []
        while True:
            if not has_items:
                break
            self._consume_newlines()
            if self.check(TokenType.DEDENT) or self.check(TokenType.EOF):
                break
            # v4 target form allows a leading `|` on each enum variant
            # (`enum Mode:\n | Server`). Match arms already accept it.
            if self.check(TokenType.PIPE):
                self.advance()
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
        if has_items:
            self.expect(TokenType.DEDENT)
        return EnumDecl(is_pub, name, generics, variants)

    def parse_interface_decl(self, is_pub):
        self.expect(TokenType.INTERFACE)
        name = self.expect(TokenType.IDENT).lexeme
        generics = self._parse_generics()
        is_pub = self._parse_decl_tail_tags(is_pub)
        has_items = self._expect_region()   # False = 空 region ⇒ **零方法接口**（合法且有意义）
        methods = []
        while True:
            if not has_items:
                break
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
        if has_items:
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
        has_items = self._expect_region()   # False = 空 region
        methods = []
        while True:
            if not has_items:
                break
            self._consume_newlines()
            if self.check(TokenType.DEDENT) or self.check(TokenType.EOF):
                break
            methods.append(self.parse_function_decl(False))
        if has_items:
            self.expect(TokenType.DEDENT)
        return ImplDecl(generics, trait, for_type, methods)

    def parse_type_alias(self, is_pub=False):
        self.expect(TokenType.TYPE)
        name = self.expect(TokenType.IDENT).lexeme
        self.expect(TokenType.EQ)
        typ = self.parse_type()
        self._parse_decl_tail_tags(is_pub)
        self._end_decl()
        return TypeAliasDecl(name, typ)

    def _parse_new_let_decl(self):
        from corec.syntax.ast import LetDecl
        names, tags, typ, values = self._parse_var_decl_names_tags_type()
        self._end_decl()
        return LetDecl(names=names, tags=tags, type_=typ, values=values)
