from corec.syntax.ast import *
from corec.ir.symbol_table import SymbolTable, SymbolKind

class TypeChecker:
    def __init__(self, symtab: SymbolTable):
        self.symtab = symtab
        self.errors = []
        self.struct_fields = {}
        self.methods = {}
        self.enum_variants = {}
        self.generic_decls = {}  # name -> [param_names]
        self.generic_scopes = []  # stack of sets of generic param names in scope
        self.borrow_state = {}       # borrowed_var -> {ref_count, mut_ref}
        self.borrow_holders = {}     # borrower_var -> [(borrowed_var, is_mut)]
        self.borrow_scope_stack = []  # stack of sets of borrower vars in each scope

    # --------------------------------------------------------------
    # Borrow checking helpers
    # --------------------------------------------------------------
    def _borrow_var_name(self, expr) -> str:
        """Extract the base variable name from a borrow expression (&x or &p.x)."""
        if isinstance(expr, Ident):
            return expr.name
        if isinstance(expr, FieldAccess):
            return self._borrow_var_name(expr.object)
        return None

    def _check_borrow_expr(self, expr, is_mut: bool):
        """Check whether a borrow expression (&x or &p.x) is legal."""
        var_name = self._borrow_var_name(expr)
        if var_name is None:
            return True  # non-variable, skip
        return self._check_borrow(var_name, is_mut)

    def _check_borrow(self, var_name: str, is_mut: bool):
        """Check whether var_name can be borrowed."""
        state = self.borrow_state.get(var_name)
        if state is None:
            state = {'ref_count': 0, 'mut_ref': False}
            self.borrow_state[var_name] = state
        if is_mut:
            if state['ref_count'] > 0 or state['mut_ref']:
                self.errors.append(f"Cannot borrow '{var_name}' as mutable, already borrowed")
                return False
            state['mut_ref'] = True
        else:
            if state['mut_ref']:
                self.errors.append(f"Cannot borrow '{var_name}' as immutable, already mutably borrowed")
                return False
            state['ref_count'] += 1
        return True

    def _check_use(self, var_name: str):
        """Check whether var_name can be read/written directly (not through a reference)."""
        state = self.borrow_state.get(var_name)
        if state and (state['ref_count'] > 0 or state['mut_ref']):
            self.errors.append(f"Cannot use '{var_name}' while it is borrowed")
            return False
        return True

    def _record_borrow_holder(self, borrower: str, borrowed: str, is_mut: bool):
        """Record that 'borrower' holds a borrow on 'borrowed'."""
        self.borrow_holders.setdefault(borrower, []).append((borrowed, is_mut))
        if self.borrow_scope_stack:
            self.borrow_scope_stack[-1].add(borrower)

    def _release_holder_borrows(self, borrower: str):
        """Release all borrows held by 'borrower'."""
        for borrowed, is_mut in self.borrow_holders.get(borrower, []):
            state = self.borrow_state.get(borrowed)
            if state:
                if is_mut:
                    state['mut_ref'] = False
                else:
                    state['ref_count'] -= 1
                    if state['ref_count'] < 0:
                        state['ref_count'] = 0
        self.borrow_holders.pop(borrower, None)

    def _push_borrow_scope(self):
        self.borrow_scope_stack.append(set())

    def _pop_borrow_scope(self):
        for borrower in self.borrow_scope_stack.pop():
            self._release_holder_borrows(borrower)

    # --------------------------------------------------------------
    # Built-in types
    # --------------------------------------------------------------
    def _declare_builtins(self):
        """Register built-in generic types Option[T] and Result[T, E]."""
        if not self.symtab.lookup('Option'):
            opt = EnumDecl(True, 'Option', ['T'],
                           [('Some', [PathType(['T'])]), ('None', [])])
            self._declare_enum(opt)
        if not self.symtab.lookup('Result'):
            res = EnumDecl(True, 'Result', ['T', 'E'],
                           [('Ok', [PathType(['T'])]), ('Err', [PathType(['E'])])])
            self._declare_enum(res)

    def check(self, ast: CompilationUnit):
        self._declare_builtins()
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
            elif isinstance(decl, LetDecl):
                self._check_let_decl(decl)
        return len(self.errors) == 0

    def _declare_struct(self, decl: StructDecl):
        if not self.symtab.lookup(decl.name, recursive=False):
            self.symtab.define(decl.name, SymbolKind.TYPE, decl=decl)
        self.struct_fields[decl.name] = decl.fields
        if decl.generics:
            self.generic_decls[decl.name] = decl.generics

    def _declare_enum(self, decl: EnumDecl):
        if not self.symtab.lookup(decl.name, recursive=False):
            self.symtab.define(decl.name, SymbolKind.TYPE, decl=decl)
        self.enum_variants[decl.name] = decl.variants
        if decl.generics:
            self.generic_decls[decl.name] = decl.generics
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

    def _check_let_decl(self, decl: LetDecl):
        # Infer types from all initializer values
        inferred_types = []
        for val in decl.values:
            if val:
                inferred_types.append(self._infer_expr(val))
            else:
                inferred_types.append(None)
        typ = decl.type_
        for i, name in enumerate(decl.names):
            inferred = inferred_types[i] if i < len(inferred_types) else None
            var_type = typ
            if var_type is None:
                if inferred is None:
                    self.errors.append(f"Cannot infer type of global {name}")
                    continue
                var_type = inferred
            else:
                if inferred and not self._type_equal(inferred, var_type):
                    self.errors.append(f"Global {name}: declared type {var_type} but initialized with {inferred}")
            # Update the symbol's type
            sym = self.symtab.lookup(name, recursive=False)
            if sym:
                sym.type = var_type
            if i < len(decl.values) and decl.values[i] and isinstance(decl.values[i], UnaryOp) and decl.values[i].op in ('&', '&mut'):
                borrowed_name = self._borrow_var_name(decl.values[i].operand)
                if borrowed_name:
                    self._record_borrow_holder(name, borrowed_name, decl.values[i].op == '&mut')

    def _check_function(self, decl: FunctionDecl):
        self._cur_fn = decl.name
        self.symtab.push_scope()
        self.generic_scopes.append(set(decl.generics))
        self.borrow_state.clear()
        self.borrow_holders.clear()
        self.borrow_scope_stack = [set()]
        for name, typ in decl.params:
            self.symtab.define(name, SymbolKind.PARAM, typ)
        if decl.body:
            inferred = self._infer_expr(decl.body)
            if not self._type_equal(inferred, decl.return_type):
                # Relaxed check: try to unify unresolved generic params
                if not self._unify_return_type(inferred, decl.return_type):
                    self.errors.append(f"Function {decl.name}: expected return type {decl.return_type}, got {inferred}")
        self.generic_scopes.pop()
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
            self._check_use(expr.name)
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
            elif expr.op in ('|', '&'):
                if left_t.name == 'int' and right_t.name == 'int':
                    return BaseType('int')
                self.errors.append(f"Bitwise ops require int")
                return BaseType('never')
            elif expr.op in ('&&','||'):
                if left_t.name == 'bool' and right_t.name == 'bool':
                    return BaseType('bool')
                self.errors.append("Logical ops require bool")
                return BaseType('never')
            else:
                self.errors.append(f"Unknown binary operator {expr.op}")
                return BaseType('never')
        elif isinstance(expr, UnaryOp):
            if expr.op in ('&', '&mut'):
                # &/&mut: borrow the variable — don't trigger _check_use on the operand
                self._check_borrow_expr(expr.operand, expr.op == '&mut')
                if isinstance(expr.operand, Ident):
                    var_name = expr.operand.name
                    sym = self.symtab.lookup(var_name)
                    op_type = sym.type if sym else BaseType('never')
                else:
                    op_type = self._infer_expr(expr.operand)
                return RefType(expr.op == '&mut', op_type)
            operand_type = self._infer_expr(expr.operand)
            if expr.op == '-':
                return operand_type
            if expr.op == '*':
                # Dereference: extract inner type from RefType
                if isinstance(operand_type, RefType):
                    return operand_type.inner
                self.errors.append("Cannot dereference non-reference type")
                return BaseType('never')
            if expr.op == '!':
                if operand_type.name != 'bool':
                    self.errors.append("Unary ! requires bool")
                    return BaseType('never')
                return BaseType('bool')
            self.errors.append(f"Unary operator {expr.op} not supported")
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
            # Infer generic args if the parent enum has generics
            enum_name = func_decl.return_type.path[-1] if isinstance(func_decl.return_type, PathType) else None
            enum_generics = self.generic_decls.get(enum_name, []) if enum_name else []
            inferred = {}
            for arg, (_, ptype) in zip(expr.args, func_decl.params):
                arg_t = self._infer_expr(arg)
                if enum_generics:
                    sub = self._unify_types(ptype, arg_t, set(enum_generics))
                    if sub is not None:
                        inferred.update(sub)
                        continue
                if not self._type_equal(arg_t, ptype):
                    self.errors.append("Enum constructor argument type mismatch")
            if inferred and enum_name:
                concrete_args = [self._substitute_type(PathType([g]), inferred) for g in enum_generics]
                return GenericApplyType([enum_name], concrete_args)
            return func_decl.return_type
        elif isinstance(expr, FieldAccess):
            obj_t = self._infer_expr(expr.object)
            # Unwrap RefType for field access through references
            if isinstance(obj_t, RefType):
                obj_t = obj_t.inner
            name = obj_t.path[-1] if isinstance(obj_t, (PathType, GenericApplyType)) else None
            if name and name in self.struct_fields:
                for fname, ftype in self.struct_fields[name]:
                    if fname == expr.field:
                        # If the object type has concrete generic args, substitute
                        if isinstance(obj_t, GenericApplyType) and name in self.generic_decls:
                            mapping = dict(zip(self.generic_decls[name], obj_t.args))
                            return self._substitute_type(ftype, mapping)
                        return ftype
            if name and name in self.enum_variants:
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
            generics_list = self.generic_decls.get(struct_name, [])
            generic_names = set(generics_list)
            inferred = {}
            for fname, val in expr.fields:
                matched = [ft for fn, ft in self.struct_fields[struct_name] if fn == fname]
                if not matched:
                    self.errors.append(f"Unknown field {fname}")
                else:
                    val_t = self._infer_expr(val)
                    field_t = matched[0]
                    if generic_names:
                        sub = self._unify_types(field_t, val_t, generic_names)
                        if sub is not None:
                            inferred.update(sub)
                            substituted = self._substitute_type(field_t, {**inferred})
                            if not self._type_equal(val_t, substituted):
                                self.errors.append("Field type mismatch")
                        else:
                            self.errors.append("Field type mismatch")
                    elif not self._type_equal(val_t, field_t):
                        self.errors.append("Field type mismatch")
            if generics_list and inferred:
                concrete_args = [self._substitute_type(PathType([g]), inferred) for g in generics_list]
                return GenericApplyType(expr.path, concrete_args)
            return PathType(expr.path)
        elif isinstance(expr, ArrayLit):
            if not expr.elements:
                return BaseType('unit')
            first_type = self._infer_expr(expr.elements[0])
            for elem in expr.elements[1:]:
                if not self._type_equal(first_type, self._infer_expr(elem)):
                    self.errors.append("Array elements must have same type")
                    return BaseType('never')
            return ArrayType(first_type, len(expr.elements))
        elif isinstance(expr, Index):
            arr_t = self._infer_expr(expr.object)
            if isinstance(arr_t, ArrayType):
                return arr_t.inner  # return actual element type
            if hasattr(arr_t, 'name') and arr_t.name == 'array':
                return BaseType('int')
            self.errors.append("Indexing non-array type")
            return BaseType('never')
        elif isinstance(expr, Block):
            self.symtab.push_scope()
            self._push_borrow_scope()
            last_type = BaseType('unit')
            for stmt in expr.stmts:
                last_type = self._infer_stmt(stmt)
            if expr.expr:
                last_type = self._infer_expr(expr.expr)
            self._pop_borrow_scope()
            self.symtab.pop_scope()
            return last_type
        elif isinstance(expr, If):
            cond_t = self._infer_expr(expr.cond)
            if cond_t.name != 'bool':
                self.errors.append("If condition must be bool")
            self.symtab.push_scope()
            self._push_borrow_scope()
            then_t = self._infer_expr(expr.then_branch)
            self._pop_borrow_scope()
            self.symtab.pop_scope()
            if expr.else_branch:
                self.symtab.push_scope()
                self._push_borrow_scope()
                else_t = self._infer_expr(expr.else_branch)
                self._pop_borrow_scope()
                self.symtab.pop_scope()
                if not self._type_equal(then_t, else_t):
                    self.errors.append(f"If branches have different types: {then_t} vs {else_t}")
                    return BaseType('never')
                return then_t
            return BaseType('unit')
        elif isinstance(expr, RangeExpr):
            start_t = self._infer_expr(expr.start)
            end_t = self._infer_expr(expr.end)
            if not self._type_equal(start_t, BaseType('int')):
                self.errors.append("Range start must be int")
            if not self._type_equal(end_t, BaseType('int')):
                self.errors.append("Range end must be int")
            return BaseType('range')
        elif isinstance(expr, Loop):
            self._infer_expr(expr.block)
            return BaseType('unit')
        elif isinstance(expr, For):
            iter_t = self._infer_expr(expr.iter)
            self._push_borrow_scope()
            if isinstance(iter_t, ArrayType):
                self.symtab.define(expr.var, SymbolKind.LOCAL, iter_t.inner)
            else:
                self.symtab.define(expr.var, SymbolKind.LOCAL, BaseType('int'))
            body_t = self._infer_expr(expr.block)
            self._pop_borrow_scope()
            return body_t if body_t else BaseType('unit')
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
            self._infer_expr(expr.expr)  # check for side effects
            return BaseType('unit')
        elif isinstance(expr, LetStmt):
            inferred_types = []
            for val in expr.values:
                if val:
                    inferred_types.append(self._infer_expr(val))
                else:
                    inferred_types.append(None)
            typ = expr.type_
            for i, name in enumerate(expr.names):
                inferred = inferred_types[i] if i < len(inferred_types) else None
                var_type = typ
                if var_type is None:
                    if inferred is None:
                        self.errors.append(f"Cannot infer type of variable {name}")
                        continue
                    var_type = inferred
                else:
                    if inferred and not self._type_equal(inferred, var_type):
                        self.errors.append(f"Variable {name}: declared type {var_type} but initialized with {inferred}")
                self.symtab.define(name, SymbolKind.LOCAL, var_type)
                # If the value is a borrow (&x or &mut x), record the holder
                if i < len(expr.values) and expr.values[i] and isinstance(expr.values[i], UnaryOp) and expr.values[i].op in ('&', '&mut'):
                    borrowed_name = self._borrow_var_name(expr.values[i].operand)
                    if borrowed_name:
                        self._record_borrow_holder(name, borrowed_name, expr.values[i].op == '&mut')
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
        # Handle runtime functions (defined in rt.s, no decl node)
        rt_funcs = {'alloc', 'get_arg', 'syscall3', 'load8', 'store8',
                    'load_str_ptr', 'store_str_ptr'}
        if isinstance(call.func, Ident) and call.func.name in rt_funcs:
            sym = self.symtab.lookup(call.func.name)
            if sym and sym.type:
                return sym.type
            return BaseType('int')
        # Track which function we're checking (set by _check_function)
        self._current_checking_func = getattr(self, '_current_checking_func', '?')
        if isinstance(call.func, FieldAccess):
            obj_t = self._infer_expr(call.func.object)
            if isinstance(obj_t, RefType):
                obj_t = obj_t.inner
            struct_name = obj_t.path[-1] if isinstance(obj_t, (PathType, GenericApplyType)) else None
            if struct_name:
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
            # Pre-declared without full definition — return known type
            if func_decl is None:
                return func_sym.type if func_sym.type else BaseType('int')
            # Generic function: infer type args from arguments
            if func_decl.generics:
                generic_names = set(func_decl.generics)
                inferred = {}
                if len(call.args) == len(func_decl.params):
                    for arg, (_, pt) in zip(call.args, func_decl.params):
                        arg_t = self._infer_expr(arg)
                        sub = self._unify_types(pt, arg_t, generic_names)
                        if sub is not None:
                            inferred.update(sub)
                        elif not self._type_equal(arg_t, pt):
                            self.errors.append("Function argument type mismatch")
                if inferred:
                    return self._substitute_type(func_decl.return_type, inferred)
                # Fall through if inference failed
            if len(call.args) != len(func_decl.params):
                self.errors.append(f"Function {func_name} argument count mismatch")
            else:
                for i, (arg, (_, pt)) in enumerate(zip(call.args, func_decl.params)):
                    arg_t = self._infer_expr(arg)
                    if not self._type_equal(arg_t, pt):
                        cur_fn = getattr(self, '_cur_fn', '?')
                        self.errors.append(f"Function {func_name} arg{i+1}: expected {pt}, got {arg_t} (in {cur_fn})")
                        break
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

    def _unify_return_type(self, inferred: Type, declared: Type) -> bool:
        """Relaxed check: allow inferred types with unresolved generic params to match declared."""
        if isinstance(inferred, GenericApplyType) and isinstance(declared, GenericApplyType):
            if inferred.path != declared.path or len(inferred.args) != len(declared.args):
                return False
            for a, b in zip(inferred.args, declared.args):
                if isinstance(a, PathType) and len(a.path) == 1 and a.path[0][0].isupper():
                    continue  # unresolved generic param — accept
                if not self._type_equal(a, b):
                    return False
            return True
        return False

    def _unify_types(self, pattern: Type, concrete: Type, generic_names: set) -> dict:
        """Match a pattern (possibly containing generic params) against a concrete type.
        Returns dict {param_name: concrete_type} or {} if no generic params, or None on mismatch."""
        if isinstance(pattern, PathType) and pattern.path[-1] in generic_names:
            return {pattern.path[-1]: concrete}
        if isinstance(pattern, GenericApplyType) and isinstance(concrete, GenericApplyType):
            if pattern.path != concrete.path or len(pattern.args) != len(concrete.args):
                return None
            result = {}
            for p, c in zip(pattern.args, concrete.args):
                sub = self._unify_types(p, c, generic_names)
                if sub is None:
                    return None
                result.update(sub)
            return result
        if type(pattern) != type(concrete):
            return None
        if self._type_equal(pattern, concrete):
            return {}
        return None

    def _substitute_type(self, typ: Type, mapping: dict) -> Type:
        """Replace generic type params with concrete types using mapping dict."""
        if isinstance(typ, PathType):
            name = typ.path[-1]
            if name in mapping:
                return mapping[name]
            return typ
        if isinstance(typ, GenericApplyType):
            args = [self._substitute_type(a, mapping) for a in typ.args]
            return GenericApplyType(typ.path, args)
        return typ

    def _type_equal(self, t1, t2) -> bool:
        if t1 is None or t2 is None:
            return True
        if type(t1) != type(t2):
            return False
        if isinstance(t1, BaseType):
            return t1.name == t2.name
        if isinstance(t1, PathType):
            return t1.path == t2.path
        if isinstance(t1, GenericApplyType):
            if t1.path != t2.path:
                return False
            if len(t1.args) != len(t2.args):
                return False
            return all(self._type_equal(a1, a2) for a1, a2 in zip(t1.args, t2.args))
        if isinstance(t1, ArrayType):
            return t1.size == t2.size and self._type_equal(t1.inner, t2.inner)
        return str(t1) == str(t2)
