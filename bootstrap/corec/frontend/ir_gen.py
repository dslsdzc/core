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
        if decl.body:
            ret_var = self.gen_expr(decl.body)
            if not self.current_block.terminated():
                if ret_var is not None:
                    self.add_instr(ReturnInstr(ret_var))
                else:
                    self.add_instr(ReturnInstr(None))
        else:
            self.add_instr(ReturnInstr(None))

    def gen_expr(self, expr):
        if isinstance(expr, Literal): return self.gen_literal(expr)
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
        if isinstance(expr, Match): return self.gen_match(expr)
        if isinstance(expr, ReturnStmt): return self.gen_return(expr)
        if isinstance(expr, ExprStmt): return self.gen_expr(expr.expr)
        if isinstance(expr, LetStmt): return self.gen_let(expr)
        if isinstance(expr, BreakStmt): return self.gen_break()
        if isinstance(expr, ContinueStmt): return self.gen_continue()
        raise NotImplementedError(type(expr))

    def gen_stmt(self, stmt): self.gen_expr(stmt)

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
                # 获取字段索引
                struct_name = None
                sym = self.symtab.lookup(binop.left.object.name) if isinstance(binop.left.object, Ident) else None
                if sym and sym.type and isinstance(sym.type, PathType):
                    struct_name = sym.type.path[-1]
                field_idx = 0
                if struct_name and struct_name in self.struct_fields:
                    fields = self.struct_fields[struct_name]
                    for i, (fn, ft) in enumerate(fields):
                        if fn == binop.left.field:
                            field_idx = i
                            break
                self.add_instr(StoreFieldInstr(obj, binop.left.field, val, field_index=field_idx))
                return val
        left = self.gen_expr(binop.left)
        right = self.gen_expr(binop.right)
        dest = self.new_temp()
        self.add_instr(BinaryInstr(binop.op, left, right, dest))
        return dest

    def gen_unary(self, unop):
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
                if sym and sym.type and isinstance(sym.type, PathType):
                    struct_name = sym.type.path[-1]
                else:
                    var_ir = self.local_vars.get(obj_expr.name)
                    if var_ir and var_ir.type and isinstance(var_ir.type, PathType):
                        struct_name = var_ir.type.path[-1]
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

    def gen_field_access(self, fa):
        obj = self.gen_expr(fa.object)
        dest = self.new_temp()
        struct_name = None
        if isinstance(fa.object, Ident):
            sym = self.symtab.lookup(fa.object.name)
            if sym and sym.type and isinstance(sym.type, PathType):
                struct_name = sym.type.path[-1]
            else:
                var = self.local_vars.get(fa.object.name)
                if var and var.type and isinstance(var.type, PathType):
                    struct_name = var.type.path[-1]
        # 若无法确定类型，仍然生成 LoadFieldInstr（后端解释器可能忽略）
        field_idx = 0
        if struct_name and struct_name in self.struct_fields:
            fields = self.struct_fields[struct_name]
            for i, (fn, ft) in enumerate(fields):
                if fn == fa.field:
                    field_idx = i
                    break
        # 生成 LoadFieldInstr，field_index 可能不正确，但解释器会处理
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
        last_val = None
        for stmt in block.stmts: last_val = self.gen_stmt(stmt)
        if block.expr: last_val = self.gen_expr(block.expr)
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
        header = self.new_block("for_header")
        body = self.new_block("for_body")
        exit_block = self.new_block("for_exit")
        self.add_instr(JumpInstr(header.name))
        self.current_func.blocks.append(header)
        self.current_block = header
        self.add_instr(JumpInstr(body.name))
        self.current_func.blocks.append(body)
        self.current_block = body
        self.loop_stack.append((header, exit_block))
        self.gen_expr(for_expr.block)
        self.loop_stack.pop()
        if not self.current_block.terminated(): self.add_instr(JumpInstr(header.name))
        self.current_func.blocks.append(exit_block)
        self.current_block = exit_block
        return None

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
        val_ir = self.gen_expr(let.value) if let.value else None
        typ = let.type_
        if typ is None and let.value is not None:
            if isinstance(let.value, StructLit): typ = PathType(let.value.path)
            elif isinstance(let.value, Literal): 
                kind_map = {'int':'int','float':'float','bool':'bool','string':'string','char':'char','unit':'unit'}
                typ = BaseType(kind_map.get(let.value.kind,'unit'))
            else: typ = BaseType('unit')
        var_ir = IRVar(let.name, VarKind.LOCAL, typ)
        if val_ir:
            self.add_instr(AllocInstr(typ, var_ir))
            self.add_instr(StoreInstr(var_ir, val_ir))
        self.local_vars[let.name] = var_ir
        sym = self.symtab.lookup(let.name, recursive=False)
        if sym:
            sym.type = typ
            sym.ir_var = var_ir
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
