from corec.syntax.ast import *
from corec.ir.symbol_table import SymbolTable, SymbolKind

class NameResolver:
    def __init__(self):
        self.symtab = SymbolTable()
        self.errors = []

    def resolve(self, ast: CompilationUnit):
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
            # ImplDecl 和 TypeAlias 稍后处理

        # 第二遍：处理函数体、impl 等
        for decl in ast.declarations:
            if isinstance(decl, FunctionDecl):
                self._resolve_function(decl)
            # 其他声明暂时不深入

        return len(self.errors) == 0

    def _declare_function(self, decl: FunctionDecl):
        self.symtab.define(decl.name, SymbolKind.FUNCTION, decl.return_type, decl)

    def _declare_type(self, decl):
        self.symtab.define(decl.name, SymbolKind.TYPE, decl=decl)

    def _resolve_function(self, decl: FunctionDecl):
        self.symtab.push_scope()
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
            for stmt in expr.stmts:
                self._resolve_stmt(stmt)
            if expr.expr:
                self._resolve_expr(expr.expr)
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
            self._resolve_expr(expr.value)
            # 变量定义放到当前作用域
            self.symtab.define(expr.name, SymbolKind.LOCAL, expr.type_)
        elif isinstance(expr, Literal):
            pass
        # 其他表达式暂时忽略

    def _resolve_stmt(self, stmt: Stmt):
        if isinstance(stmt, LetStmt):
            self._resolve_expr(stmt.value)
            self.symtab.define(stmt.name, SymbolKind.LOCAL, stmt.type_)
        elif isinstance(stmt, ReturnStmt):
            if stmt.value:
                self._resolve_expr(stmt.value)
        elif isinstance(stmt, ExprStmt):
            self._resolve_expr(stmt.expr)
        elif isinstance(stmt, BreakStmt) or isinstance(stmt, ContinueStmt):
            pass