from corec.syntax.ast import *
from corec.ir.symbol_table import SymbolTable, SymbolKind

class TypeChecker:
    def __init__(self, symtab: SymbolTable):
        self.symtab = symtab
        self.errors = []
        self.struct_fields = {}
        self.methods = {}
        self.enum_variants = {}

    def check(self, ast: CompilationUnit):
        for decl in ast.declarations:
            if isinstance(decl, StructDecl):
                self._declare_struct(decl)
            elif isinstance(decl, EnumDecl):
                self._declare_enum(decl)
            elif isinstance(decl, ImplDecl):
                self._declare_impl(decl)
        for decl in ast.declarations:
            if isinstance(decl, FunctionDecl):
                self._check_function(decl)
        return len(self.errors) == 0

    def _declare_struct(self, decl: StructDecl):
        if not self.symtab.lookup(decl.name, recursive=False):
            self.symtab.define(decl.name, SymbolKind.TYPE, decl=decl)
        self.struct_fields[decl.name] = decl.fields

    def _declare_enum(self, decl: EnumDecl):
        if not self.symtab.lookup(decl.name, recursive=False):
            self.symtab.define(decl.name, SymbolKind.TYPE, decl=decl)
        self.enum_variants[decl.name] = decl.variants
        for vname, types in decl.variants:
            if not self.symtab.lookup(vname, recursive=False):
                param_specs = [(None, t) for t in types]
                self.symtab.define(vname, SymbolKind.FUNCTION,
                                   PathType([decl.name]),
                                   FunctionDecl(False, vname, [], param_specs,
                                                PathType([decl.name]), None))

    def _declare_impl(self, impl: ImplDecl):
        struct_name = impl.for_type[-1]
        for method in impl.methods:
            self.methods[(struct_name, method.name)] = method
            full_name = f"{struct_name}.{method.name}"
            if not self.symtab.lookup(full_name):
                self.symtab.define(full_name, SymbolKind.FUNCTION,
                                   method.return_type, method)

    def _check_function(self, decl: FunctionDecl):
        self.symtab.push_scope()
        for name, typ in decl.params:
            self.symtab.define(name, SymbolKind.PARAM, typ)
        if decl.body:
            inferred = self._infer_expr(decl.body)
            if not self._type_equal(inferred, decl.return_type):
                self.errors.append(f"Function {decl.name}: expected return type {decl.return_type}, got {inferred}")
        self.symtab.pop_scope()

    # --------------------------------------------------------------
    # _infer_expr (完整版)
    # --------------------------------------------------------------
    def _infer_expr(self, expr: Expr) -> Type:
        if isinstance(expr, Literal):
            kind_map = {'int':BaseType('int'),'float':BaseType('float'),'bool':BaseType('bool'),
                       'string':BaseType('string'),'char':BaseType('char'),'unit':BaseType('unit'),
                       'some':BaseType('unit')}
            return kind_map.get(expr.kind, BaseType('unit'))
        elif isinstance(expr, Ident):
            sym = self.symtab.lookup(expr.name)
            if sym is None:
                self.errors.append(f"Undefined name: {expr.name}")
                return BaseType('never')
            return sym.type if sym.type else BaseType('never')
        elif isinstance(expr, BinaryOp):
            if expr.op == '=':
                left_t = self._infer_expr(expr.left)
                right_t = self._infer_expr(expr.right)
                if not self._type_equal(left_t, right_t):
                    self.errors.append(f"Assignment type mismatch: {left_t} = {right_t}")
                return left_t
            left_t = self._infer_expr(expr.left)
            right_t = self._infer_expr(expr.right)
            if expr.op in ('+','-','*','/','%'):
                if left_t.name in ('int','float') and right_t.name in ('int','float'):
                    if left_t.name == 'float' or right_t.name == 'float':
                        return BaseType('float')
                    return BaseType('int')
                elif expr.op == '+' and left_t.name == 'string' and right_t.name == 'string':
                    return BaseType('string')
                else:
                    self.errors.append(f"Arithmetic type error between {left_t.name} and {right_t.name}")
                    return BaseType('never')
            elif expr.op in ('==','!=','<','>','<=','>='):
                if left_t.name not in ('int','float','string') or right_t.name not in ('int','float','string'):
                    self.errors.append(f"Comparison not allowed")
                return BaseType('bool')
            elif expr.op in ('&&','||'):
                if left_t.name == 'bool' and right_t.name == 'bool':
                    return BaseType('bool')
                self.errors.append("Logical ops require bool")
                return BaseType('never')
            else:
                self.errors.append(f"Unknown binary operator {expr.op}")
                return BaseType('never')
        elif isinstance(expr, Call):
            return self._infer_call(expr)
        elif isinstance(expr, EnumConstructor):
            var_name = expr.path[-1]
            sym = self.symtab.lookup(var_name)
            if sym is None or sym.kind != SymbolKind.FUNCTION:
                self.errors.append(f"Undefined enum constructor {var_name}")
                return BaseType('never')
            func_decl = sym.decl_node
            if len(expr.args) != len(func_decl.params):
                self.errors.append(f"Enum constructor {var_name} argument count mismatch")
                return BaseType('never')
            for arg, (_, ptype) in zip(expr.args, func_decl.params):
                arg_t = self._infer_expr(arg)
                if not self._type_equal(arg_t, ptype):
                    self.errors.append("Enum constructor argument type mismatch")
            return func_decl.return_type
        elif isinstance(expr, FieldAccess):
            obj_t = self._infer_expr(expr.object)
            if isinstance(obj_t, PathType):
                name = obj_t.path[-1]
                if name in self.struct_fields:
                    for fname, ftype in self.struct_fields[name]:
                        if fname == expr.field:
                            return ftype
                elif name in self.enum_variants:
                    if expr.field == '__variant':
                        return BaseType('string')
                    if expr.field.startswith('_field_'):
                        return BaseType('int')
            return BaseType('unit')  # 宽松处理
        elif isinstance(expr, StructLit):
            struct_name = expr.path[-1]
            if struct_name not in self.struct_fields:
                self.errors.append(f"Undefined struct {struct_name}")
                return BaseType('never')
            for fname, val in expr.fields:
                matched = [ft for fn, ft in self.struct_fields[struct_name] if fn == fname]
                if not matched:
                    self.errors.append(f"Unknown field {fname}")
                else:
                    val_t = self._infer_expr(val)
                    if not self._type_equal(val_t, matched[0]):
                        self.errors.append("Field type mismatch")
            return PathType(expr.path)
        elif isinstance(expr, ArrayLit):
            if not expr.elements:
                return BaseType('unit')
            first_type = self._infer_expr(expr.elements[0])
            for elem in expr.elements[1:]:
                if not self._type_equal(first_type, self._infer_expr(elem)):
                    self.errors.append("Array elements must have same type")
                    return BaseType('never')
            return BaseType('array')
        elif isinstance(expr, Index):
            arr_t = self._infer_expr(expr.object)
            # 数组的元素类型推断为 int (暂时)
            if arr_t.name == 'array':
                return BaseType('int')
            self.errors.append("Indexing non-array type")
            return BaseType('never')
        elif isinstance(expr, Block):
            self.symtab.push_scope()
            last_type = BaseType('unit')
            for stmt in expr.stmts:
                last_type = self._infer_stmt(stmt)
            if expr.expr:
                last_type = self._infer_expr(expr.expr)
            self.symtab.pop_scope()
            return last_type
        elif isinstance(expr, If):
            cond_t = self._infer_expr(expr.cond)
            if cond_t.name != 'bool':
                self.errors.append("If condition must be bool")
            self.symtab.push_scope()
            then_t = self._infer_expr(expr.then_branch)
            self.symtab.pop_scope()
            if expr.else_branch:
                self.symtab.push_scope()
                else_t = self._infer_expr(expr.else_branch)
                self.symtab.pop_scope()
                if not self._type_equal(then_t, else_t):
                    self.errors.append(f"If branches have different types: {then_t} vs {else_t}")
                    return BaseType('never')
                return then_t
            return BaseType('unit')
        elif isinstance(expr, Loop):
            self._infer_expr(expr.block)
            return BaseType('unit')
        elif isinstance(expr, For):
            self._infer_expr(expr.iter)
            self._infer_expr(expr.block)
            return BaseType('unit')
        elif isinstance(expr, Match):
            match_t = self._infer_expr(expr.expr)
            if not isinstance(match_t, PathType):
                self.errors.append("Match expression must be enum type")
                return BaseType('never')
            enum_name = match_t.path[-1]
            variants = self.enum_variants.get(enum_name, [])
            arm_types = []
            for arm in expr.arms:
                self.symtab.push_scope()
                self._bind_match_pattern(arm.pattern, variants)
                arm_t = self._infer_expr(arm.body)
                arm_types.append(arm_t)
                self.symtab.pop_scope()
            if arm_types:
                first = arm_types[0]
                for t in arm_types[1:]:
                    if not self._type_equal(first, t):
                        self.errors.append("Match arms have different types")
                        return BaseType('never')
                return first
            return BaseType('unit')
        elif isinstance(expr, ReturnStmt):
            if expr.value:
                return self._infer_expr(expr.value)
            return BaseType('unit')
        elif isinstance(expr, ExprStmt):
            return self._infer_expr(expr.expr)
        elif isinstance(expr, LetStmt):
            inferred = None
            if expr.value:
                inferred = self._infer_expr(expr.value)
            typ = expr.type_
            if typ is None:
                if inferred is None:
                    self.errors.append(f"Cannot infer type of variable {expr.name}")
                    return BaseType('never')
                typ = inferred
            else:
                if inferred and not self._type_equal(inferred, typ):
                    self.errors.append(f"Variable {expr.name}: declared type {typ} but initialized with {inferred}")
            self.symtab.define(expr.name, SymbolKind.LOCAL, typ)
            return BaseType('unit')
        elif isinstance(expr, BreakStmt) or isinstance(expr, ContinueStmt):
            return BaseType('unit')
        else:
            self.errors.append(f"Unsupported expression: {type(expr)}")
            return BaseType('never')

    # --------------------------------------------------------------
    # _infer_call (方法体必须存在)
    # --------------------------------------------------------------
    def _infer_call(self, call: Call) -> Type:
        if isinstance(call.func, FieldAccess):
            obj_t = self._infer_expr(call.func.object)
            if isinstance(obj_t, PathType):
                struct_name = obj_t.path[-1]
                method = self.methods.get((struct_name, call.func.field))
                if method is None:
                    self.errors.append(f"Method {call.func.field} not found for type {struct_name}")
                    return BaseType('never')
                params = method.params[1:]  # skip self
                if len(call.args) != len(params):
                    self.errors.append(f"Method {call.func.field} argument count mismatch")
                else:
                    for arg, (_, pt) in zip(call.args, params):
                        arg_t = self._infer_expr(arg)
                        if not self._type_equal(arg_t, pt):
                            self.errors.append("Method argument type mismatch")
                return method.return_type
            else:
                self.errors.append("Method call on non-struct type")
                return BaseType('never')
        else:
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
                self.errors.append(f"Undefined function {func_name}")
                return BaseType('never')
            func_decl = func_sym.decl_node
            if len(call.args) != len(func_decl.params):
                self.errors.append(f"Function {func_name} argument count mismatch")
            else:
                for arg, (_, pt) in zip(call.args, func_decl.params):
                    arg_t = self._infer_expr(arg)
                    if not self._type_equal(arg_t, pt):
                        self.errors.append("Function argument type mismatch")
            return func_decl.return_type

    def _bind_match_pattern(self, pattern, variants):
        if isinstance(pattern, Wildcard):
            pass
        elif isinstance(pattern, IdentPattern):
            self.symtab.define(pattern.name, SymbolKind.LOCAL, None)
        elif isinstance(pattern, EnumPattern):
            vname = pattern.path[-1]
            vtypes = None
            for vn, vts in variants:
                if vn == vname:
                    vtypes = vts
                    break
            if vtypes is None:
                self.errors.append(f"Unknown variant {vname} in match pattern")
                return
            if pattern.args:
                for subpat, vt in zip(pattern.args, vtypes):
                    if isinstance(subpat, IdentPattern):
                        self.symtab.define(subpat.name, SymbolKind.LOCAL, vt)
                    elif isinstance(subpat, Wildcard):
                        pass
        elif isinstance(pattern, LiteralPattern):
            pass
        elif isinstance(pattern, TuplePattern):
            for sub in pattern.patterns:
                self._bind_match_pattern(sub, [])

    def _infer_stmt(self, stmt: Stmt) -> Type:
        return self._infer_expr(stmt)

    def _type_equal(self, t1, t2) -> bool:
        if t1 is None or t2 is None:
            return True
        if type(t1) != type(t2):
            return False
        if isinstance(t1, BaseType):
            return t1.name == t2.name
        if isinstance(t1, PathType):
            return t1.path == t2.path
        return str(t1) == str(t2)
