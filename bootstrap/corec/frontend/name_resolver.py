from corec.syntax.ast import *
from corec.ir.symbol_table import SymbolTable, SymbolKind

class NameResolver:
    def __init__(self):
        self.symtab = SymbolTable()
        self.errors = []

    def _declare_builtins(self):
        """Register built-in functions so the type checker can find them."""
        from corec.syntax.ast import BaseType
        # str_len(s: string) -> int
        self.symtab.define('__builtin_str_len', SymbolKind.FUNCTION, BaseType('int'))
        # str_get(s: string, index: int) -> string
        self.symtab.define('__builtin_str_get', SymbolKind.FUNCTION, BaseType('string'))
        # str_sub(s: string, start: int, len: int) -> string
        self.symtab.define('__builtin_str_sub', SymbolKind.FUNCTION, BaseType('string'))
        # int_to_str(i: int) -> string
        self.symtab.define('__builtin_int_to_str', SymbolKind.FUNCTION, BaseType('string'))
        # str_push(s: string, c: string) -> string
        self.symtab.define('__builtin_str_push', SymbolKind.FUNCTION, BaseType('string'))
        # str_from_int(i: int) -> string
        self.symtab.define('__builtin_str_from_int', SymbolKind.FUNCTION, BaseType('string'))
        # str_to_int(s: string) -> int
        self.symtab.define('__builtin_str_to_int', SymbolKind.FUNCTION, BaseType('int'))
        # str_eq(a: string, b: string) -> int
        self.symtab.define('__builtin_str_eq', SymbolKind.FUNCTION, BaseType('int'))
        # str_cmp(a: string, b: string) -> int
        self.symtab.define('__builtin_str_cmp', SymbolKind.FUNCTION, BaseType('int'))
        # alloc(size: int) -> string (returns pointer to allocated memory)
        self.symtab.define('__builtin_alloc', SymbolKind.FUNCTION, BaseType('string'))
        # load8(ptr: string, idx: int) -> int  — byte load (inline)
        self.symtab.define('__builtin_load8', SymbolKind.FUNCTION, BaseType('int'))
        # store8(ptr: string, idx: int, val: int) -> int  — byte store (inline)
        self.symtab.define('__builtin_store8', SymbolKind.FUNCTION, BaseType('int'))
        # read_file(path: string) -> string
        self.symtab.define('__builtin_read_file', SymbolKind.FUNCTION, BaseType('string'))
        # write_file(path: string, content: string) -> int
        self.symtab.define('__builtin_write_file', SymbolKind.FUNCTION, BaseType('int'))
        # get_arg(n: int) -> string
        self.symtab.define('__builtin_get_arg', SymbolKind.FUNCTION, BaseType('string'))
        # print(s: string) -> unit
        self.symtab.define('__builtin_print', SymbolKind.FUNCTION, BaseType('unit'))
        # println(s: string) -> unit
        self.symtab.define('__builtin_println', SymbolKind.FUNCTION, BaseType('unit'))
        # syscall3(nr: int, arg1: int, arg2: int, arg3: int) -> int
        self.symtab.define('__builtin_syscall3', SymbolKind.FUNCTION, BaseType('int'))

    def resolve(self, ast: CompilationUnit):
        self._declare_builtins()
        # 第一遍：收集顶层声明（函数、类型等）
        for decl in ast.declarations:
            if isinstance(decl, FunctionDecl):
                self._declare_function(decl)
            elif isinstance(decl, StructDecl):
                self._declare_type(decl)
            elif isinstance(decl, EnumDecl):
                self._declare_type(decl)
            elif isinstance(decl, InterfaceDecl):
                self._declare_type(decl)
            elif isinstance(decl, LetDecl):
                self._declare_let(decl)
            # ImplDecl 和 TypeAlias 稍后处理

        # 第二遍：处理函数体、impl 等
        for decl in ast.declarations:
            if isinstance(decl, FunctionDecl):
                self._resolve_function(decl)
            elif isinstance(decl, LetDecl):
                self._resolve_let(decl)
            # 其他声明暂时不深入

        return len(self.errors) == 0

    def _declare_function(self, decl: FunctionDecl):
        if self.symtab.lookup(decl.name):
            return  # already declared (e.g. builtin)
        self.symtab.define(decl.name, SymbolKind.FUNCTION, decl.return_type, decl)

    def _declare_type(self, decl):
        self.symtab.define(decl.name, SymbolKind.TYPE, decl=decl)

    def _declare_let(self, decl: LetDecl):
        for name in decl.names:
            self.symtab.define(name, SymbolKind.GLOBAL, decl.type_, decl)

    def _resolve_let(self, decl: LetDecl):
        for val in decl.values:
            if val:
                self._resolve_expr(val)

    def _resolve_function(self, decl: FunctionDecl):
        self.symtab.push_scope()
        # 添加泛型参数到作用域（作为类型符号）
        for g in decl.generics:
            self.symtab.define(g, SymbolKind.TYPE, None)
        # 添加参数到作用域
        for param_name, param_type in decl.params:
            self.symtab.define(param_name, SymbolKind.PARAM, param_type)
        # 解析函数体中的表达式
        if decl.body:
            self._resolve_expr(decl.body)
        self.symtab.pop_scope()

    def _resolve_expr(self, expr: Expr):
        if isinstance(expr, Ident):
            sym = self.symtab.lookup(expr.name)
            if sym is None:
                self.errors.append(f"Undefined name: {expr.name}")
            # 这里可以将 Ident 绑定到符号，但先保持简单
        elif isinstance(expr, BinaryOp):
            self._resolve_expr(expr.left)
            self._resolve_expr(expr.right)
        elif isinstance(expr, UnaryOp):
            self._resolve_expr(expr.operand)
        elif isinstance(expr, Call):
            self._resolve_expr(expr.func)
            for arg in expr.args:
                self._resolve_expr(arg)
        elif isinstance(expr, Block):
            self.symtab.push_scope()
            for stmt in expr.stmts:
                self._resolve_stmt(stmt)
            if expr.expr:
                self._resolve_expr(expr.expr)
            self.symtab.pop_scope()
        elif isinstance(expr, If):
            self._resolve_expr(expr.cond)
            self._resolve_expr(expr.then_branch)
            if expr.else_branch:
                self._resolve_expr(expr.else_branch)
        elif isinstance(expr, Loop):
            self._resolve_expr(expr.block)
        elif isinstance(expr, ReturnStmt):
            if expr.value:
                self._resolve_expr(expr.value)
        elif isinstance(expr, ExprStmt):
            self._resolve_expr(expr.expr)
        elif isinstance(expr, LetStmt):
            for val in expr.values:
                if val:
                    self._resolve_expr(val)
            for name in expr.names:
                self.symtab.define(name, SymbolKind.LOCAL, expr.type_)
        elif isinstance(expr, Literal):
            pass
        # 其他表达式暂时忽略

    def _resolve_stmt(self, stmt: Stmt):
        if isinstance(stmt, LetStmt):
            for val in stmt.values:
                if val:
                    self._resolve_expr(val)
            for name in stmt.names:
                self.symtab.define(name, SymbolKind.LOCAL, stmt.type_)
        elif isinstance(stmt, ReturnStmt):
            if stmt.value:
                self._resolve_expr(stmt.value)
        elif isinstance(stmt, ExprStmt):
            self._resolve_expr(stmt.expr)
        elif isinstance(stmt, BreakStmt) or isinstance(stmt, ContinueStmt):
            pass