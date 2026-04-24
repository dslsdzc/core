from corec.syntax.ast import *
from corec.ir.symbol_table import SymbolTable

class MatchDesugarer:
    def __init__(self, symtab: SymbolTable):
        self.symtab = symtab
        self.temp_counter = 0

    def new_temp(self):
        self.temp_counter += 1
        return f"__match_tmp_{self.temp_counter}"

    def desugar(self, ast: CompilationUnit):
        for decl in ast.declarations:
            if isinstance(decl, FunctionDecl):
                decl.body = self._desugar_expr(decl.body)
        return ast

    def _desugar_expr(self, expr):
        if expr is None:
            return None
        if isinstance(expr, Match):
            return self._desugar_match(expr)
        if isinstance(expr, Block):
            new_stmts = [self._desugar_stmt(s) for s in expr.stmts]
            new_expr = self._desugar_expr(expr.expr) if expr.expr else None
            return Block(new_stmts, new_expr)
        if isinstance(expr, If):
            new_cond = self._desugar_expr(expr.cond)
            new_then = self._desugar_expr(expr.then_branch)
            new_else = self._desugar_expr(expr.else_branch) if expr.else_branch else None
            return If(new_cond, new_then, new_else)
        if isinstance(expr, Loop):
            return Loop(self._desugar_expr(expr.block))
        if isinstance(expr, For):
            return For(expr.var, self._desugar_expr(expr.iter), self._desugar_expr(expr.block))
        if isinstance(expr, ExprStmt):
            return ExprStmt(self._desugar_expr(expr.expr))
        if isinstance(expr, ReturnStmt):
            if expr.value:
                return ReturnStmt(self._desugar_expr(expr.value))
            return expr
        if isinstance(expr, LetStmt):
            new_val = self._desugar_expr(expr.value) if expr.value else None
            return LetStmt(expr.mutable, expr.name, expr.type_, new_val)
        if isinstance(expr, BinaryOp):
            return BinaryOp(self._desugar_expr(expr.left), expr.op, self._desugar_expr(expr.right))
        if isinstance(expr, Call):
            new_func = self._desugar_expr(expr.func)
            new_args = [self._desugar_expr(a) for a in expr.args]
            return Call(new_func, new_args)
        if isinstance(expr, FieldAccess):
            return FieldAccess(self._desugar_expr(expr.object), expr.field)
        if isinstance(expr, StructLit):
            return StructLit(expr.path, [(f, self._desugar_expr(v)) for f, v in expr.fields])
        if isinstance(expr, EnumConstructor):
            return EnumConstructor(expr.path, [self._desugar_expr(a) for a in expr.args])
        return expr

    def _desugar_stmt(self, stmt):
        if isinstance(stmt, ExprStmt):
            return ExprStmt(self._desugar_expr(stmt.expr))
        if isinstance(stmt, LetStmt):
            new_val = self._desugar_expr(stmt.value) if stmt.value else None
            return LetStmt(stmt.mutable, stmt.name, stmt.type_, new_val)
        if isinstance(stmt, ReturnStmt):
            if stmt.value:
                return ReturnStmt(self._desugar_expr(stmt.value))
            return stmt
        if isinstance(stmt, BreakStmt) or isinstance(stmt, ContinueStmt):
            return stmt
        return stmt

    def _desugar_match(self, match: Match) -> Expr:
        match_val_name = self.new_temp()
        result_name = self.new_temp()

        let_match = LetStmt(False, match_val_name, None, match.expr)

        # 从后往前构建 if-else 链
        else_expr = None
        for arm in reversed(match.arms):
            if isinstance(arm.pattern, Wildcard):
                else_expr = self._arm_to_block(arm, result_name)
                continue
            elif isinstance(arm.pattern, EnumPattern):
                variant = arm.pattern.path[-1]
                cond = BinaryOp(
                    FieldAccess(Ident(match_val_name), '__variant'),
                    '==',
                    Literal(variant, 'string')
                )
                then_block = self._arm_to_block(arm, result_name, match_val_name)
                if else_expr is None:
                    else_expr = then_block
                else:
                    else_expr = If(cond, then_block, else_expr)
            else:
                raise NotImplementedError(f"Unsupported pattern {type(arm.pattern)}")

        if else_expr is None:
            else_expr = Block(stmts=[], expr=Literal(0, 'int'))

        let_result = LetStmt(False, result_name, None, Literal(0, 'int'))
        # 关键：最终用 return 语句返回结果变量
        return_stmt = ReturnStmt(Ident(result_name))
        return Block(
            stmts=[
                let_match,
                let_result,
                ExprStmt(else_expr),
                return_stmt
            ],
            expr=None  # 不再依赖尾表达式
        )

    def _arm_to_block(self, arm: MatchArm, result_name: str, enum_var_name: str = None) -> Block:
        bindings = []
        if isinstance(arm.pattern, EnumPattern) and arm.pattern.args:
            for idx, subpat in enumerate(arm.pattern.args):
                if isinstance(subpat, IdentPattern):
                    field_expr = FieldAccess(Ident(enum_var_name), f'_field_{idx}')
                    bindings.append(LetStmt(False, subpat.name, None, field_expr))
                elif isinstance(subpat, Wildcard):
                    pass
        body_expr = arm.body
        assign_stmt = ExprStmt(BinaryOp(Ident(result_name), '=', body_expr))
        return Block(stmts=bindings + [assign_stmt], expr=None)
