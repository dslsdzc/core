from corec.syntax.ast import *
from corec.ir.symbol_table import SymbolTable, SymbolKind

class TypeChecker:
    def __init__(self, symtab: SymbolTable):
        self.symtab = symtab
        self.errors = []
        self.struct_fields = {}   # name -> list of (field, type)
        self.methods = {}         # (struct_name, method_name) -> FunctionDecl

    def check(self, ast: CompilationUnit):
        # 第一遍：注册类型定义
        for decl in ast.declarations:
            if isinstance(decl, StructDecl):
                self._declare_struct(decl)
            elif isinstance(decl, EnumDecl):
                self.symtab.define(decl.name, SymbolKind.TYPE, decl=decl)
            elif isinstance(decl, ImplDecl):
                self._declare_impl(decl)
        # 第二遍：检查函数体
        for decl in ast.declarations:
            if isinstance(decl, FunctionDecl):
                self._check_function(decl)
        return len(self.errors) == 0

    def _declare_struct(self, decl: StructDecl):
        if not self.symtab.lookup(decl.name, recursive=False):
            self.symtab.define(decl.name, SymbolKind.TYPE, decl=decl)
        self.struct_fields[decl.name] = decl.fields

    def _declare_impl(self, impl: ImplDecl):
        struct_name = impl.for_type[-1]
        for method in impl.methods:
            self.methods[(struct_name, method.name)] = method
            full_name = f"{struct_name}.{method.name}"
            if not self.symtab.lookup(full_name):
                self.symtab.define(full_name, SymbolKind.FUNCTION, method.return_type, method)

    def _check_function(self, decl: FunctionDecl):
        self.symtab.push_scope()
        for name, typ in decl.params:
            self.symtab.define(name, SymbolKind.PARAM, typ)
        if decl.body:
            inferred = self._infer_expr(decl.body)
            if not self._type_equal(inferred, decl.return_type):
                self.errors.append(f"Function {decl.name}: expected return type {decl.return_type}, got {inferred}")
        self.symtab.pop_scope()

    def _infer_expr(self, expr: Expr) -> Type:
        if isinstance(expr, Literal):
            kind_map = {
                'int': BaseType('int'), 'float': BaseType('float'),
                'bool': BaseType('bool'), 'string': BaseType('string'),
                'char': BaseType('char'), 'unit': BaseType('unit')
            }
            return kind_map.get(expr.kind, BaseType('unit'))
        elif isinstance(expr, Ident):
            sym = self.symtab.lookup(expr.name)
            if sym is None:
                self.errors.append(f"Undefined name: {expr.name}")
                return BaseType('never')
            if sym.type:
                return sym.type
            self.errors.append(f"Variable {expr.name} has no type")
            return BaseType('never')
        elif isinstance(expr, BinaryOp):
            if expr.op == '=':
                left_t = self._infer_expr(expr.left)
                right_t = self._infer_expr(expr.right)
                if not self._type_equal(left_t, right_t):
                    self.errors.append(f"Assignment type mismatch: {left_t} = {right_t}")
                return left_t
            left_t = self._infer_expr(expr.left)
            right_t = self._infer_expr(expr.right)
            if expr.op in ('+', '-', '*', '/', '%'):
                if left_t.name == 'int' and right_t.name == 'int':
                    return BaseType('int')
                elif left_t.name == 'float' or right_t.name == 'float':
                    return BaseType('float')
                else:
                    self.errors.append(f"Arithmetic {expr.op} not allowed between {left_t} and {right_t}")
                    return BaseType('never')
            elif expr.op in ('==', '!=', '<', '>', '<=', '>='):
                return BaseType('bool')
            elif expr.op in ('&&', '||'):
                if left_t.name == 'bool' and right_t.name == 'bool':
                    return BaseType('bool')
                self.errors.append(f"Logical {expr.op} requires bool operands")
                return BaseType('never')
            else:
                self.errors.append(f"Unknown binary operator {expr.op}")
                return BaseType('never')
        elif isinstance(expr, Call):
            return self._infer_call(expr)
        elif isinstance(expr, FieldAccess):
            obj_t = self._infer_expr(expr.object)
            if isinstance(obj_t, PathType):
                struct_name = obj_t.path[-1]
                if struct_name in self.struct_fields:
                    fields = self.struct_fields[struct_name]
                    for fname, ftype in fields:
                        if fname == expr.field:
                            return ftype
                    self.errors.append(f"Struct {struct_name} has no field {expr.field}")
                    return BaseType('never')
            self.errors.append(f"Field access on non-struct type {obj_t}")
            return BaseType('never')
        elif isinstance(expr, StructLit):
            struct_name = expr.path[-1]
            if struct_name not in self.struct_fields:
                self.errors.append(f"Undefined struct {struct_name}")
                return BaseType('never')
            defined_fields = self.struct_fields[struct_name]
            # 检查字段是否都在定义中且类型匹配
            for fname, val in expr.fields:
                found = False
                for dfname, dftype in defined_fields:
                    if dfname == fname:
                        found = True
                        val_t = self._infer_expr(val)
                        if not self._type_equal(val_t, dftype):
                            self.errors.append(f"Struct field {fname} type mismatch: expected {dftype}, got {val_t}")
                        break
                if not found:
                    self.errors.append(f"Struct {struct_name} has no field {fname}")
            return PathType(expr.path)
        elif isinstance(expr, Block):
            last_type = BaseType('unit')
            for stmt in expr.stmts:
                last_type = self._infer_stmt(stmt)
            if expr.expr:
                last_type = self._infer_expr(expr.expr)
            return last_type
        elif isinstance(expr, If):
            cond_t = self._infer_expr(expr.cond)
            if cond_t.name != 'bool':
                self.errors.append(f"If condition must be bool, got {cond_t}")
            then_t = self._infer_expr(expr.then_branch)
            else_t = self._infer_expr(expr.else_branch) if expr.else_branch else BaseType('unit')
            if expr.else_branch:
                if self._type_equal(then_t, else_t):
                    return then_t
                else:
                    self.errors.append(f"If branches have different types: {then_t} vs {else_t}")
                    return BaseType('never')
            else:
                # 无 else 的 if 作为语句，返回 unit
                return BaseType('unit')
        elif isinstance(expr, Loop):
            self._infer_expr(expr.block)
            return BaseType('unit')
        elif isinstance(expr, For):
            self._infer_expr(expr.iter)
            self._infer_expr(expr.block)
            return BaseType('unit')
        elif isinstance(expr, Match):
            # 暂省略
            return BaseType('unit')
        elif isinstance(expr, ReturnStmt):
            if expr.value:
                return self._infer_expr(expr.value)
            return BaseType('unit')
        elif isinstance(expr, ExprStmt):
            return self._infer_expr(expr.expr)
        elif isinstance(expr, LetStmt):
            inferred = self._infer_expr(expr.value) if expr.value else None
            if expr.type_ is None:
                if inferred is None:
                    self.errors.append(f"Variable {expr.name} has no type")
                    return BaseType('never')
                typ = inferred
            else:
                typ = expr.type_
                if inferred and not self._type_equal(inferred, typ):
                    self.errors.append(f"Variable {expr.name} type mismatch: declared {typ}, initializer {inferred}")
            self.symtab.define(expr.name, SymbolKind.LOCAL, typ)
            return BaseType('unit')
        elif isinstance(expr, BreakStmt):
            return BaseType('unit')
        elif isinstance(expr, ContinueStmt):
            return BaseType('unit')
        else:
            self.errors.append(f"Unsupported expression: {type(expr)}")
            return BaseType('never')

    def _infer_call(self, call: Call) -> Type:
        # 分两种情况：普通函数调用 和 方法调用 (FieldAccess -> Call)
        if isinstance(call.func, FieldAccess):
            # 方法调用 obj.method(args)
            obj_t = self._infer_expr(call.func.object)
            if not isinstance(obj_t, PathType):
                self.errors.append(f"Method call on non-struct type {obj_t}")
                return BaseType('never')
            struct_name = obj_t.path[-1]
            method_name = call.func.field
            method = self.methods.get((struct_name, method_name))
            if method is None:
                self.errors.append(f"Struct {struct_name} has no method {method_name}")
                return BaseType('never')
            # 检查参数（排除 self）
            params = method.params[1:]  # 跳过 self
            if len(call.args) != len(params):
                self.errors.append(f"Method {method_name} expects {len(params)} args, got {len(call.args)}")
            else:
                for arg, (pname, ptype) in zip(call.args, params):
                    arg_t = self._infer_expr(arg)
                    if not self._type_equal(arg_t, ptype):
                        self.errors.append(f"Method {method_name} arg type mismatch")
            return method.return_type
        else:
            # 普通函数
            func_name = None
            if isinstance(call.func, Ident):
                func_name = call.func.name
            elif isinstance(call.func, PathType):
                func_name = '::'.join(call.func.path)
            if func_name is None:
                self.errors.append("Invalid function call")
                return BaseType('never')
            func_sym = self.symtab.lookup(func_name)
            if func_sym is None or func_sym.kind != SymbolKind.FUNCTION:
                self.errors.append(f"Undefined function: {func_name}")
                return BaseType('never')
            func_decl = func_sym.decl_node
            if len(call.args) != len(func_decl.params):
                self.errors.append(f"Function {func_name} expects {len(func_decl.params)} args, got {len(call.args)}")
            else:
                for arg, (pname, ptype) in zip(call.args, func_decl.params):
                    arg_t = self._infer_expr(arg)
                    if not self._type_equal(arg_t, ptype):
                        self.errors.append(f"Function {func_name} arg type mismatch")
            return func_decl.return_type

    def _infer_stmt(self, stmt: Stmt) -> Type:
        return self._infer_expr(stmt)

    def _type_equal(self, t1, t2) -> bool:
        if t1 is None or t2 is None:
            return True
        if isinstance(t1, BaseType) and isinstance(t2, BaseType):
            return t1.name == t2.name
        if isinstance(t1, PathType) and isinstance(t2, PathType):
            return t1.path == t2.path
        return str(t1) == str(t2)
