from corec.syntax.ast import *
from corec.ir.coreir import *
from corec.ir.base import VarKind
from corec.ir.symbol_table import SymbolTable, SymbolKind

class IRGen:
    def __init__(self, symtab=None):
        self.temp_counter = 0
        self.mod = Module("main")
        self.current_func = None
        self.current_block = None
        self.symtab = symtab if symtab else SymbolTable()
        self.loop_stack = []
        self.local_vars = {}
        self.struct_fields = {}
        self.enum_variants = {}
        self.block_counter = 0

    def new_temp(self, name="t"):
        self.temp_counter += 1
        return IRVar(f"{name}{self.temp_counter}", VarKind.TEMP)

    def new_block(self, name="block"):
        self.block_counter += 1
        return BasicBlock(f"{name}_{self.block_counter}")

    def add_instr(self, instr): self.current_block.instrs.append(instr)

    def gen_module(self, ast: CompilationUnit) -> Module:
        for decl in ast.declarations:
            if isinstance(decl, StructDecl): self.struct_fields[decl.name] = decl.fields
            elif isinstance(decl, EnumDecl): self.enum_variants[decl.name] = decl.variants
        # Pre-compute struct sizes (each field = 8 bytes) for backend use
        self.mod.struct_sizes = {}
        for name, fields in self.struct_fields.items():
            self.mod.struct_sizes[name] = len(fields) * 8
        # First pass: register global let declarations so ir_var is set
        # before function bodies reference them (declaration order may place
        # LetDecls after the functions that use them in concatenated source).
        for decl in ast.declarations:
            if isinstance(decl, LetDecl):
                self.gen_let_decl(decl)
        # Second pass: generate IR for functions
        for decl in ast.declarations:
            if isinstance(decl, FunctionDecl):
                if not self.symtab.lookup(decl.name):
                    self.symtab.define(decl.name, SymbolKind.FUNCTION, decl.return_type, decl)
                self.gen_function(decl)
            elif isinstance(decl, ImplDecl):
                struct_name = decl.for_type[-1]
                for method in decl.methods:
                    full_name = f"{struct_name}.{method.name}"
                    method.name = full_name
                    if not self.symtab.lookup(full_name):
                        self.symtab.define(full_name, SymbolKind.FUNCTION, method.return_type, method)
                    self.gen_function(method)
        return self.mod

    def gen_let_decl(self, decl: LetDecl):
        typ = decl.type_ if decl.type_ else BaseType('int')
        for i, name in enumerate(decl.names):
            var_ir = IRVar(name, VarKind.GLOBAL, typ)
            # Store constant value directly on the IRVar for interpreter initialization
            if i < len(decl.values) and isinstance(decl.values[i], Literal):
                var_ir.constant_value = decl.values[i].value
            sym = self.symtab.lookup(name)
            if sym:
                sym.ir_var = var_ir
            self.mod.globals.append(var_ir)
        return None

    def gen_function(self, decl: FunctionDecl):
        params = [IRVar(name, VarKind.PARAM, typ) for name, typ in decl.params]
        func = FunctionDef(decl.name, params, decl.return_type)
        self.mod.functions.append(func)
        entry = self.new_block("entry")
        func.entry = entry
        func.blocks.append(entry)
        self.current_func = func
        self.current_block = entry
        self.local_vars = {n: p for (n,_), p in zip(decl.params, params)}
        self.symtab.push_scope()
        if decl.body:
            ret_var = self.gen_expr(decl.body)
            if not self.current_block.terminated():
                if ret_var is not None:
                    self.add_instr(ReturnInstr(ret_var))
                else:
                    self.add_instr(ReturnInstr(None))
        else:
            self.add_instr(ReturnInstr(None))
        self.symtab.pop_scope()

    def gen_expr(self, expr):
        if isinstance(expr, Literal): return self.gen_literal(expr)
        if isinstance(expr, Index): return self.gen_index(expr)
        if isinstance(expr, ArrayLit): return self.gen_array_lit(expr)
        if isinstance(expr, Ident): return self.gen_ident(expr)
        if isinstance(expr, BinaryOp): return self.gen_binary(expr)
        if isinstance(expr, UnaryOp): return self.gen_unary(expr)
        if isinstance(expr, Call): return self.gen_call(expr)
        if isinstance(expr, EnumConstructor): return self.gen_enum_constructor(expr)
        if isinstance(expr, FieldAccess): return self.gen_field_access(expr)
        if isinstance(expr, StructLit): return self.gen_struct_lit(expr)
        if isinstance(expr, Block): return self.gen_block(expr)
        if isinstance(expr, If): return self.gen_if(expr)
        if isinstance(expr, Loop): return self.gen_loop(expr)
        if isinstance(expr, For): return self.gen_for(expr)
        if isinstance(expr, RangeExpr):
            self.gen_expr(expr.start)
            return self.gen_expr(expr.end)
        if isinstance(expr, Match): return self.gen_match(expr)
        if isinstance(expr, ReturnStmt): return self.gen_return(expr)
        if isinstance(expr, ExprStmt): return self.gen_expr(expr.expr)
        if isinstance(expr, LetStmt): return self.gen_let(expr)
        if isinstance(expr, BreakStmt): return self.gen_break()
        if isinstance(expr, ContinueStmt): return self.gen_continue()
        raise NotImplementedError(type(expr))

    def gen_stmt(self, stmt): return self.gen_expr(stmt)

    def gen_array_lit(self, arr: ArrayLit):
        # 为每个元素生成表达式，最后生成一个 AllocArrayInstr
        elem_irs = [self.gen_expr(e) for e in arr.elements]
        dest = self.new_temp()
        self.add_instr(AllocArrayInstr(len(arr.elements), dest))
        for i, elem_ir in enumerate(elem_irs):
            self.add_instr(StoreIndexInstr(dest, i, elem_ir))
        return dest

    def gen_index(self, idx: Index):
        arr = self.gen_expr(idx.object)
        if isinstance(idx.index, Literal) and idx.index.kind == 'int':
            index_val = int(idx.index.value)
            dest = self.new_temp()
            self.add_instr(LoadIndexInstr(arr, index_val, dest))
            return dest
        # Variable index
        idx_var = self.gen_expr(idx.index)
        dest = self.new_temp()
        self.add_instr(LoadIndexVarInstr(arr, idx_var, dest))
        return dest

    def gen_literal(self, lit):
        val = lit.value
        if lit.kind == 'int': val = int(val)
        elif lit.kind == 'float': val = float(val)
        v = self.new_temp()
        self.add_instr(ConstInstr(val, lit.kind, v))
        return v

    def gen_ident(self, ident):
        if ident.name in self.local_vars: return self.local_vars[ident.name]
        sym = self.symtab.lookup(ident.name)
        if sym and sym.ir_var: return sym.ir_var
        for p in self.current_func.params:
            if p.name == ident.name: return p
        raise RuntimeError(f"Undefined: {ident.name}")

    def gen_binary(self, binop):
        if binop.op == "=":
            val = self.gen_expr(binop.right)
            if isinstance(binop.left, Ident):
                var = self.gen_ident(binop.left)
                self.add_instr(StoreInstr(var, val))
                return val
            elif isinstance(binop.left, FieldAccess):
                obj = self.gen_expr(binop.left.object)
                # Resolve field index via expression chain (supports chained access)
                struct_name = self._resolve_struct_name(binop.left.object)
                field_idx = 0
                if struct_name and struct_name in self.struct_fields:
                    fields = self.struct_fields[struct_name]
                    for i, (fn, ft) in enumerate(fields):
                        if fn == binop.left.field:
                            field_idx = i
                            break
                self.add_instr(StoreFieldInstr(obj, binop.left.field, val, field_index=field_idx))
                return val
            elif isinstance(binop.left, Index):
                arr = self.gen_expr(binop.left.object)
                if isinstance(binop.left.index, Literal) and binop.left.index.kind == 'int':
                    idx = int(binop.left.index.value)
                    self.add_instr(StoreIndexInstr(arr, idx, val))
                else:
                    idx_var = self.gen_expr(binop.left.index)
                    self.add_instr(StoreIndexVarInstr(arr, idx_var, val))
                return val
            elif isinstance(binop.left, UnaryOp) and binop.left.op == '*':
                ref = self.gen_expr(binop.left.operand)
                self.add_instr(StoreInstr(ref, val))
                return val
        # Fallback for =: emit debug and use StoreInstr
        if binop.op == "=":
            # Try treating left as a general expression and using StoreInstr
            left_var = self.gen_expr(binop.left)
            self.add_instr(StoreInstr(left_var, val))
            return val
        left = self.gen_expr(binop.left)
        right = self.gen_expr(binop.right)
        dest = self.new_temp()
        if binop.op == '+':
            left_is_str = isinstance(left.type, BaseType) and left.type.name == 'string'
            right_is_str = isinstance(right.type, BaseType) and right.type.name == 'string'
            if left_is_str or right_is_str:
                dest.type = BaseType('string')
        self.add_instr(BinaryInstr(binop.op, left, right, dest))
        return dest

    def gen_unary(self, unop):
        if unop.op in ('&', '&mut'):
            # Borrow: emit RefInstr pointing to the operand's IRVar
            if isinstance(unop.operand, Ident):
                var = self.gen_ident(unop.operand)
                dest = self.new_temp()
                self.add_instr(RefInstr(var, dest))
                return dest
            else:
                raise RuntimeError("Can only borrow a named variable")
        if unop.op == '*':
            # Dereference: load value through reference
            ref = self.gen_expr(unop.operand)
            dest = self.new_temp()
            self.add_instr(LoadInstr(ref, dest))
            return dest
        op = self.gen_expr(unop.operand)
        dest = self.new_temp()
        self.add_instr(UnaryInstr(unop.op, op, dest))
        return dest

    def gen_call(self, call):
        if isinstance(call.func, FieldAccess):
            obj_expr = call.func.object
            struct_name = None
            if isinstance(obj_expr, Ident):
                sym = self.symtab.lookup(obj_expr.name)
                if sym and sym.type:
                    typ = sym.type
                    if isinstance(typ, RefType): typ = typ.inner
                    if isinstance(typ, (PathType, GenericApplyType)):
                        struct_name = typ.path[-1]
                else:
                    var_ir = self.local_vars.get(obj_expr.name)
                    if var_ir and var_ir.type:
                        typ = var_ir.type
                        if isinstance(typ, RefType): typ = typ.inner
                        if isinstance(typ, (PathType, GenericApplyType)):
                            struct_name = typ.path[-1]
            if struct_name is None:
                struct_name = self._resolve_struct_name(obj_expr)
            method_name = call.func.field
            if struct_name is None:
                full = method_name
            else:
                full = f"{struct_name}.{method_name}"
            obj = self.gen_expr(obj_expr)
            args = [obj] + [self.gen_expr(a) for a in call.args]
            dest = self.new_temp()
            self.add_instr(CallInstr(full, args, dest))
            return dest
        else:
            func_name = self._get_func_name(call.func)
            args = [self.gen_expr(a) for a in call.args]
            dest = self.new_temp()
            self.add_instr(CallInstr(func_name, args, dest))
            return dest

    def gen_enum_constructor(self, expr):
        variant = expr.path[-1]
        args = [self.gen_expr(a) for a in expr.args]
        dest = self.new_temp()
        self.add_instr(MakeEnumInstr(variant, args, dest))
        return dest

    def _resolve_struct_name(self, expr, depth=0):
        """Walk an expression chain to determine the struct name of its result type."""
        if depth > 10:
            return None
        if isinstance(expr, Ident):
            sym = self.symtab.lookup(expr.name)
            if sym and sym.type:
                typ = sym.type
                if isinstance(typ, RefType):
                    typ = typ.inner
                if isinstance(typ, (PathType, GenericApplyType)):
                    return typ.path[-1]
            var = self.local_vars.get(expr.name)
            if var and var.type and isinstance(var.type, PathType):
                return var.type.path[-1]
            return None
        if isinstance(expr, Index):
            arr_type = self._resolve_expr_type(expr.object)
            if isinstance(arr_type, ArrayType) and isinstance(arr_type.inner, PathType):
                return arr_type.inner.path[-1]
            # Maybe the array variable directly holds a PathType
            arr_sn = self._resolve_struct_name(expr.object, depth + 1)
            if arr_sn and arr_sn in self.struct_fields:
                for fn, ft in self.struct_fields[arr_sn]:
                    if isinstance(ft, (PathType, ArrayType)):
                        return ft.path[-1] if hasattr(ft, 'path') else ft.inner.path[-1]
            return None
        if isinstance(expr, FieldAccess):
            obj_sn = self._resolve_struct_name(expr.object, depth + 1)
            if obj_sn and obj_sn in self.struct_fields:
                for fn, ft in self.struct_fields[obj_sn]:
                    if fn == expr.field:
                        if isinstance(ft, PathType):
                            return ft.path[-1]
                        if isinstance(ft, ArrayType) and isinstance(ft.inner, PathType):
                            return ft.inner.path[-1]
                        return None
            return None
        if isinstance(expr, Call):
            # Resolve the function's return type to track struct returns in method chains
            func_name = None
            if isinstance(expr.func, Ident):
                func_name = expr.func.name
            elif isinstance(expr.func, FieldAccess):
                func_name = expr.func.field
                # Try resolve struct-qualified name
                obj_sn = self._resolve_struct_name(expr.func.object, depth + 1)
                if obj_sn:
                    func_name = f"{obj_sn}.{func_name}"
            if func_name:
                sym = self.symtab.lookup(func_name)
                if sym and sym.type and isinstance(sym.type, PathType):
                    return sym.type.path[-1]
                if sym and sym.return_type and isinstance(sym.return_type, PathType):
                    return sym.return_type.path[-1]
            return None
        return None

    def _resolve_expr_type(self, expr):
        """Resolve the full Type object for an expression, for known cases."""
        if isinstance(expr, Ident):
            sym = self.symtab.lookup(expr.name)
            if sym and sym.type:
                typ = sym.type
                if isinstance(typ, RefType):
                    typ = typ.inner
                return typ
            var = self.local_vars.get(expr.name)
            if var:
                return var.type
            return None
        if isinstance(expr, Index):
            arr_type = self._resolve_expr_type(expr.object)
            if isinstance(arr_type, ArrayType):
                return arr_type.inner
            return None
        if isinstance(expr, FieldAccess):
            obj_sn = self._resolve_struct_name(expr.object)
            if obj_sn and obj_sn in self.struct_fields:
                for fn, ft in self.struct_fields[obj_sn]:
                    if fn == expr.field:
                        return ft
            return None
        return None

    def gen_field_access(self, fa):
        obj = self.gen_expr(fa.object)
        dest = self.new_temp()
        # For rvalue field access: try to resolve field index from expression chain
        struct_name = self._resolve_struct_name(fa.object)
        field_idx = 0
        if struct_name and struct_name in self.struct_fields:
            fields = self.struct_fields[struct_name]
            for i, (fn, ft) in enumerate(fields):
                if fn == fa.field:
                    field_idx = i
                    break
        self.add_instr(LoadFieldInstr(obj, fa.field, dest, field_index=field_idx))
        return dest
    def gen_struct_lit(self, sl):
        struct_name = sl.path[-1]
        field_count = len(self.struct_fields.get(struct_name, []))
        alloc = self.new_temp()
        self.add_instr(AllocStructInstr(struct_name, alloc, field_count=field_count))
        for fname, val in sl.fields:
            v = self.gen_expr(val)
            field_idx = 0
            fields = self.struct_fields.get(struct_name, [])
            for i, (fn, ft) in enumerate(fields):
                if fn == fname:
                    field_idx = i
                    break
            self.add_instr(StoreFieldInstr(alloc, fname, v, field_index=field_idx))
        return alloc

    def gen_block(self, block):
        self.symtab.push_scope()
        last_val = None
        for stmt in block.stmts: last_val = self.gen_stmt(stmt)
        if block.expr: last_val = self.gen_expr(block.expr)
        self.symtab.pop_scope()
        return last_val

    def gen_if(self, ifexpr):
        cond = self.gen_expr(ifexpr.cond)
        then_block = self.new_block("then")
        else_block = self.new_block("else") if ifexpr.else_branch else None
        merge = self.new_block("if_merge")
        if else_block: self.add_instr(BranchInstr(cond, then_block.name, else_block.name))
        else: self.add_instr(BranchInstr(cond, then_block.name, merge.name))
        self.current_func.blocks.append(then_block)
        self.current_block = then_block
        self.gen_expr(ifexpr.then_branch)
        if not self.current_block.terminated(): self.add_instr(JumpInstr(merge.name))
        if else_block:
            self.current_func.blocks.append(else_block)
            self.current_block = else_block
            self.gen_expr(ifexpr.else_branch)
            if not self.current_block.terminated(): self.add_instr(JumpInstr(merge.name))
        self.current_func.blocks.append(merge)
        self.current_block = merge
        return None

    def gen_loop(self, loop):
        header = self.new_block("loop_header")
        body = self.new_block("loop_body")
        exit_block = self.new_block("loop_exit")
        self.add_instr(JumpInstr(header.name))
        self.current_func.blocks.append(header)
        self.current_block = header
        self.add_instr(JumpInstr(body.name))
        self.current_func.blocks.append(body)
        self.current_block = body
        self.loop_stack.append((header, exit_block))
        self.gen_expr(loop.block)
        self.loop_stack.pop()
        if not self.current_block.terminated(): self.add_instr(JumpInstr(header.name))
        self.current_func.blocks.append(exit_block)
        self.current_block = exit_block
        return None

    def gen_for(self, for_expr):
        if isinstance(for_expr.iter, RangeExpr):
            start = self.gen_expr(for_expr.iter.start)
            end = self.gen_expr(for_expr.iter.end)
            i_var = IRVar(for_expr.var, VarKind.LOCAL, BaseType('int'))
            self.local_vars[for_expr.var] = i_var
            self.add_instr(AllocInstr(BaseType('int'), i_var))
            self.add_instr(StoreInstr(i_var, start))
            header = self.new_block("for_header")
            body = self.new_block("for_body")
            exit_block = self.new_block("for_exit")
            self.add_instr(JumpInstr(header.name))
            self.current_func.blocks.append(header)
            self.current_block = header
            i_val = self.new_temp()
            self.add_instr(LoadInstr(i_var, i_val))
            cmp = self.new_temp()
            self.add_instr(BinaryInstr('>=', i_val, end, cmp))
            self.add_instr(BranchInstr(cmp, exit_block.name, body.name))
            self.current_func.blocks.append(body)
            self.current_block = body
            self.loop_stack.append((header, exit_block))
            self.gen_expr(for_expr.block)
            self.loop_stack.pop()
            i_val2 = self.new_temp()
            self.add_instr(LoadInstr(i_var, i_val2))
            one = self.new_temp()
            self.add_instr(ConstInstr(1, 'int', one))
            inc = self.new_temp()
            self.add_instr(BinaryInstr('+', i_val2, one, inc))
            self.add_instr(StoreInstr(i_var, inc))
            if not self.current_block.terminated():
                self.add_instr(JumpInstr(header.name))
            self.current_func.blocks.append(exit_block)
            self.current_block = exit_block
            return None
        elif isinstance(for_expr.iter, Ident):
            arr_var = self.gen_ident(for_expr.iter)
            arr_type = None
            # Check type from local_vars first (IRGen's own tracking)
            lv = self.local_vars.get(for_expr.iter.name)
            if lv and lv.type and isinstance(lv.type, ArrayType):
                arr_type = lv.type
            # Fall back to symtab
            if arr_type is None:
                sym = self.symtab.lookup(for_expr.iter.name)
                if sym and sym.type and isinstance(sym.type, ArrayType):
                    arr_type = sym.type
            if arr_type is None:
                raise RuntimeError(f"Cannot determine array type for '{for_expr.iter.name}'")
            size = arr_type.size
            elem_type = arr_type.inner
            idx_var = IRVar(f'__{for_expr.var}_idx', VarKind.LOCAL, BaseType('int'))
            self.local_vars[f'__{for_expr.var}_idx'] = idx_var
            self.add_instr(AllocInstr(BaseType('int'), idx_var))
            zero = self.new_temp()
            self.add_instr(ConstInstr(0, 'int', zero))
            self.add_instr(StoreInstr(idx_var, zero))
            val_var = IRVar(for_expr.var, VarKind.LOCAL, elem_type)
            self.local_vars[for_expr.var] = val_var
            self.add_instr(AllocInstr(elem_type, val_var))
            header = self.new_block("for_header")
            body = self.new_block("for_body")
            exit_block = self.new_block("for_exit")
            self.add_instr(JumpInstr(header.name))
            self.current_func.blocks.append(header)
            self.current_block = header
            idx_val = self.new_temp()
            self.add_instr(LoadInstr(idx_var, idx_val))
            size_const = self.new_temp()
            self.add_instr(ConstInstr(size, 'int', size_const))
            cmp = self.new_temp()
            self.add_instr(BinaryInstr('>=', idx_val, size_const, cmp))
            self.add_instr(BranchInstr(cmp, exit_block.name, body.name))
            self.current_func.blocks.append(body)
            self.current_block = body
            self.loop_stack.append((header, exit_block))
            idx2 = self.new_temp()
            self.add_instr(LoadInstr(idx_var, idx2))
            elem = self.new_temp()
            self.add_instr(LoadIndexVarInstr(arr_var, idx2, elem))
            self.add_instr(StoreInstr(val_var, elem))
            self.gen_expr(for_expr.block)
            self.loop_stack.pop()
            idx3 = self.new_temp()
            self.add_instr(LoadInstr(idx_var, idx3))
            one = self.new_temp()
            self.add_instr(ConstInstr(1, 'int', one))
            inc = self.new_temp()
            self.add_instr(BinaryInstr('+', idx3, one, inc))
            self.add_instr(StoreInstr(idx_var, inc))
            if not self.current_block.terminated():
                self.add_instr(JumpInstr(header.name))
            self.current_func.blocks.append(exit_block)
            self.current_block = exit_block
            return None
        else:
            raise NotImplementedError(f"for over {type(for_expr.iter)}")

    def gen_match(self, match):
        val = self.gen_expr(match.expr)
        merge = self.new_block("match_merge")
        result_var = self.new_temp()

        for i, arm in enumerate(match.arms):
            next_block = merge if i == len(match.arms)-1 else self.new_block("match_next")
            then_block = self.new_block("match_then")

            if isinstance(arm.pattern, Wildcard):
                self.add_instr(JumpInstr(then_block.name))
            elif isinstance(arm.pattern, EnumPattern):
                variant_name = arm.pattern.path[-1]
                variant_field = self.new_temp()
                self.add_instr(LoadFieldInstr(val, '__variant', variant_field))
                variant_const = self.new_temp()
                self.add_instr(ConstInstr(variant_name, 'string', variant_const))
                cmp = self.new_temp()
                self.add_instr(BinaryInstr('==', variant_field, variant_const, cmp))
                self.add_instr(BranchInstr(cmp, then_block.name, next_block.name))
            else:
                raise NotImplementedError(f"pattern {type(arm.pattern)}")

            self.current_func.blocks.append(then_block)
            self.current_block = then_block

            if isinstance(arm.pattern, EnumPattern) and arm.pattern.args:
                for idx, subpat in enumerate(arm.pattern.args):
                    if isinstance(subpat, IdentPattern):
                        field_dest = self.new_temp()
                        self.add_instr(LoadFieldInstr(val, f'_field_{idx}', field_dest, field_index=idx))
                        self.local_vars[subpat.name] = field_dest
                    elif isinstance(subpat, Wildcard): pass

            body_val = self.gen_expr(arm.body)
            if body_val:
                self.add_instr(StoreInstr(result_var, body_val))
            if not self.current_block.terminated():
                self.add_instr(JumpInstr(merge.name))

            if i < len(match.arms) - 1:
                self.current_func.blocks.append(next_block)
                self.current_block = next_block

        self.current_func.blocks.append(merge)
        self.current_block = merge
        return result_var

    def gen_return(self, ret):
        if ret.value:
            val = self.gen_expr(ret.value)
            self.add_instr(ReturnInstr(val))
        else:
            self.add_instr(ReturnInstr(None))
        return None

    def gen_let(self, let):
        # If batch declaration with multiple names, generate each
        if len(let.names) > 1:
            results = []
            for i, name in enumerate(let.names):
                val = let.values[i] if i < len(let.values) else None
                sub_let = LetStmt(names=[name], tags=let.tags, type_=let.type_, values=[val] if val else [])
                results.append(self.gen_let(sub_let))
            return results[-1] if results else None

        name = let.names[0]
        val_expr = let.values[0] if let.values else None
        val_ir = self.gen_expr(val_expr) if val_expr else None
        typ = let.type_
        if typ is None and val_expr is not None:
            if isinstance(val_expr, StructLit): typ = PathType(val_expr.path)
            elif isinstance(val_expr, ArrayLit):
                if val_expr.elements:
                    first = val_expr.elements[0]
                    if isinstance(first, Literal):
                        kind_map = {'int':'int','float':'float','bool':'bool','string':'string','char':'char','unit':'unit'}
                        elem_t = BaseType(kind_map.get(first.kind, 'unit'))
                    else:
                        elem_t = BaseType('unit')
                else:
                    elem_t = BaseType('unit')
                typ = ArrayType(elem_t, len(val_expr.elements))
            elif isinstance(val_expr, Literal):
                kind_map = {'int':'int','float':'float','bool':'bool','string':'string','char':'char','unit':'unit'}
                typ = BaseType(kind_map.get(val_expr.kind,'unit'))
            elif isinstance(val_expr, Index):
                # Infer type from array element type (e.g., g_ast[node] -> ASTNode)
                arr_obj = val_expr.object
                if isinstance(arr_obj, Ident):
                    arr_sym = self.symtab.lookup(arr_obj.name)
                    if arr_sym and isinstance(arr_sym.type, ArrayType):
                        typ = arr_sym.type.inner
                    elif arr_sym and arr_sym.ir_var and isinstance(arr_sym.ir_var.type, ArrayType):
                        typ = arr_sym.ir_var.type.inner
                if typ is None:
                    typ = BaseType('unit')
            elif isinstance(val_expr, Call):
                # Infer return type from function symbol
                if isinstance(val_expr.func, Ident):
                    func_sym = self.symtab.lookup(val_expr.func.name)
                    if func_sym and func_sym.type:
                        typ = func_sym.type
                if typ is None:
                    typ = BaseType('int')
            else:
                typ = BaseType('unit')
        if typ is None:
            typ = BaseType('unit')
        var_ir = IRVar(name, VarKind.LOCAL, typ)
        self.add_instr(AllocInstr(typ, var_ir))
        if val_ir:
            self.add_instr(StoreInstr(var_ir, val_ir))
        self.local_vars[name] = var_ir
        return var_ir

    def gen_break(self):
        _, exit_block = self.loop_stack[-1]
        self.add_instr(JumpInstr(exit_block.name))
    def gen_continue(self):
        header, _ = self.loop_stack[-1]
        self.add_instr(JumpInstr(header.name))

    def _get_func_name(self, expr):
        if isinstance(expr, Ident): return expr.name
        if isinstance(expr, PathType): return '::'.join(expr.path)
        return 'unknown'
