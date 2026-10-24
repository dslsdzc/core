from typing import List

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
            new_vals = [self._desugar_expr(v) if v else None for v in expr.values]
            return LetStmt(names=expr.names, tags=expr.tags, type_=expr.type_, values=new_vals)
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
            new_vals = [self._desugar_expr(v) if v else None for v in stmt.values]
            return LetStmt(names=stmt.names, tags=stmt.tags, type_=stmt.type_, values=new_vals)
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

        let_match = LetStmt(names=[match_val_name], values=[match.expr])

        # 从后往前构建 if-else 链
        else_expr = None
        for arm in reversed(match.arms):
            if isinstance(arm.pattern, Wildcard):
                else_expr = self._arm_to_block(arm, result_name)
                continue
            bindings = []
            cond = self._pattern_cond(arm.pattern, Ident(match_val_name), bindings)
            then_block = self._arm_to_block(arm, result_name, bindings)
            if else_expr is None:
                else_expr = then_block
            else:
                else_expr = If(cond, then_block, else_expr)

        if else_expr is None:
            else_expr = Block(stmts=[], expr=Literal(0, 'int'))

        # 结果变量的零值按第一个表达式 arm 的类型选取。旧实现固定 int 0，
        # 使返回 string 的 match 在 check 期类型不匹配。
        init = Literal(0, 'int')
        for arm in match.arms:
            if isinstance(arm.body, Literal):
                if arm.body.kind == 'string':
                    init = Literal("", 'string')
                elif arm.body.kind == 'bool':
                    init = Literal(False, 'bool')
                elif arm.body.kind == 'dex':
                    init = Literal(0, 'dex')
                break

        let_result = LetStmt(names=[result_name], values=[init])
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

    def _pattern_cond(self, pattern: Pattern, value_expr: Expr, bindings: List[Stmt]) -> Expr:
        """把模式翻译成条件表达式，并收集变量绑定。
        Stage 0 只需要 if-else 形状，不做稠密/稀疏优化。
        """
        if isinstance(pattern, Wildcard):
            return Literal(True, 'bool')
        if isinstance(pattern, IdentPattern):
            bindings.append(LetStmt(names=[pattern.name], values=[value_expr]))
            return Literal(True, 'bool')
        if isinstance(pattern, LiteralPattern):
            lit = pattern.lit
            return BinaryOp(value_expr, '==', Literal(lit.value, lit.kind))
        if isinstance(pattern, EnumPattern):
            variant = pattern.path[-1]
            cond = BinaryOp(
                FieldAccess(value_expr, '__variant'),
                '==',
                Literal(variant, 'string'),
            )
            if pattern.args:
                for idx, subpat in enumerate(pattern.args):
                    sub_cond = self._pattern_cond(
                        subpat, FieldAccess(value_expr, f'_field_{idx}'), bindings
                    )
                    cond = BinaryOp(cond, '&&', sub_cond)
            return cond
        if isinstance(pattern, TuplePattern):
            cond = Literal(True, 'bool')
            for idx, subpat in enumerate(pattern.patterns):
                sub_cond = self._pattern_cond(
                    subpat, FieldAccess(value_expr, f'_field_{idx}'), bindings
                )
                cond = BinaryOp(cond, '&&', sub_cond)
            return cond
        if isinstance(pattern, StructPattern):
            cond = Literal(True, 'bool')
            for fname, subpat in pattern.fields:
                sub_cond = self._pattern_cond(
                    subpat, FieldAccess(value_expr, fname), bindings
                )
                cond = BinaryOp(cond, '&&', sub_cond)
            return cond
        raise NotImplementedError(f"Unsupported pattern {type(pattern)}")

    def _arm_to_block(self, arm: MatchArm, result_name: str, bindings=None) -> Block:
        body_expr = arm.body
        assign_stmt = ExprStmt(BinaryOp(Ident(result_name), '=', body_expr))
        return Block(stmts=(bindings or []) + [assign_stmt], expr=None)
