from corec.syntax.ast import *
from corec.ir.coreir import *
from corec.ir.base import VarKind
from corec.ir.symbol_table import SymbolTable, SymbolKind

class IRGen:
    def __init__(self, symtab: SymbolTable = None):
        self.temp_counter = 0
        self.mod = Module("main")
        self.current_func = None
        self.current_block = None
        self.symtab = symtab if symtab else SymbolTable()
        self.loop_stack = []
        self.local_vars = {}
        # 记录结构体字段信息，用于生成访问指令
        self.struct_fields = {}

    def new_temp(self, name="t") -> IRVar:
        self.temp_counter += 1
        return IRVar(f"{name}{self.temp_counter}", VarKind.TEMP)

    def new_block(self, name="block") -> BasicBlock:
        return BasicBlock(name)

    def add_instr(self, instr):
        self.current_block.instrs.append(instr)

    def gen_module(self, ast: CompilationUnit) -> Module:
        # 注册结构体字段信息（从符号表或其他方式获取，这里先空）
        # 为简单，我们让 IRGen 自身从 symtab 获取？但符号表目前没有存字段细节。
        # 我们直接从 ast 收集结构体定义。
        for decl in ast.declarations:
            if isinstance(decl, StructDecl):
                self.struct_fields[decl.name] = decl.fields
        # 注册函数和生成函数
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
        params = []
        for name, typ in decl.params:
            param_ir = IRVar(name, VarKind.PARAM, typ)
            params.append(param_ir)
        func = FunctionDef(decl.name, params, decl.return_type)
        self.mod.functions.append(func)
        entry = self.new_block("entry")
        func.blocks.append(entry)
        func.entry = entry
        self.current_func = func
        self.current_block = entry
        self.local_vars = {n: p for n, p in zip([p[0] for p in decl.params], params)}
        if decl.body:
            self.gen_expr(decl.body)
            if not self.current_block.terminated():
                self.add_instr(ReturnInstr(None))
        else:
            self.add_instr(ReturnInstr(None))

    def gen_expr(self, expr: Expr):
        if isinstance(expr, Literal):
            return self.gen_literal(expr)
        elif isinstance(expr, Ident):
            return self.gen_ident(expr)
        elif isinstance(expr, BinaryOp):
            return self.gen_binary(expr)
        elif isinstance(expr, UnaryOp):
            return self.gen_unary(expr)
        elif isinstance(expr, Call):
            return self.gen_call(expr)
        elif isinstance(expr, FieldAccess):
            return self.gen_field_access(expr)
        elif isinstance(expr, StructLit):
            return self.gen_struct_lit(expr)
        elif isinstance(expr, Block):
            return self.gen_block(expr)
        elif isinstance(expr, If):
            return self.gen_if(expr)
        elif isinstance(expr, Loop):
            return self.gen_loop(expr)
        elif isinstance(expr, For):
            return self.gen_for(expr)
        elif isinstance(expr, Match):
            return self.gen_match(expr)
        elif isinstance(expr, ReturnStmt):
            return self.gen_return(expr)
        elif isinstance(expr, ExprStmt):
            return self.gen_expr(expr.expr)
        elif isinstance(expr, LetStmt):
            return self.gen_let(expr)
        elif isinstance(expr, BreakStmt):
            return self.gen_break()
        elif isinstance(expr, ContinueStmt):
            return self.gen_continue()
        else:
            raise NotImplementedError(f"IRGen: unsupported {type(expr)}")

    def gen_stmt(self, stmt):
        self.gen_expr(stmt)

    # ─── 简单节点 ───
    def gen_literal(self, lit: Literal) -> IRVar:
        val = lit.value
        if lit.kind == 'int': val = int(val)
        elif lit.kind == 'float': val = float(val)
        v = self.new_temp()
        self.add_instr(ConstInstr(val, lit.kind, v))
        return v

    def gen_ident(self, ident: Ident) -> IRVar:
        if ident.name in self.local_vars:
            return self.local_vars[ident.name]
        sym = self.symtab.lookup(ident.name)
        if sym and sym.ir_var:
            return sym.ir_var
        raise RuntimeError(f"Undefined variable: {ident.name}")

    def gen_binary(self, binop: BinaryOp) -> IRVar:
        if binop.op == "=":
            val = self.gen_expr(binop.right)
            if isinstance(binop.left, Ident):
                var = self.gen_ident(binop.left)
                self.add_instr(StoreInstr(var, val))
                return val
            elif isinstance(binop.left, FieldAccess):
                # 字段赋值: obj.field = val
                obj = self.gen_expr(binop.left.object)
                # 需要知道字段偏移，暂代：生成 FieldStore 指令（新指令）
                self.add_instr(StoreFieldInstr(obj, binop.left.field, val))
                return val
            else:
                raise NotImplementedError("Assignment to non-ident/non-field")
        left = self.gen_expr(binop.left)
        right = self.gen_expr(binop.right)
        dest = self.new_temp()
        self.add_instr(BinaryInstr(binop.op, left, right, dest))
        return dest

    def gen_unary(self, unop: UnaryOp) -> IRVar:
        operand = self.gen_expr(unop.operand)
        dest = self.new_temp()
        self.add_instr(UnaryInstr(unop.op, operand, dest))
        return dest

    def gen_call(self, call: Call) -> IRVar:
        if isinstance(call.func, FieldAccess):
            obj_expr = call.func.object
            # 从 local_vars 获取类型
            struct_name = None
            if isinstance(obj_expr, Ident):
                var_ir = self.local_vars.get(obj_expr.name)
                if var_ir and var_ir.type and isinstance(var_ir.type, PathType):
                    struct_name = var_ir.type.path[-1]
                else:
                    # fallback: try symbol table
                    sym = self.symtab.lookup(obj_expr.name)
                    if sym and sym.type and isinstance(sym.type, PathType):
                        struct_name = sym.type.path[-1]
                    else:
                        raise RuntimeError(f"Cannot determine type of {obj_expr.name}")
            else:
                raise NotImplementedError("Method call on non-ident object")
            method_name = call.func.field
            full_func_name = f"{struct_name}.{method_name}"
            obj = self.gen_expr(obj_expr)
            args = [obj] + [self.gen_expr(a) for a in call.args]
            dest = self.new_temp()
            self.add_instr(CallInstr(full_func_name, args, dest))
            return dest
        else:
            func_name = self._get_func_name(call.func)
            args = [self.gen_expr(a) for a in call.args]
            dest = self.new_temp()
            self.add_instr(CallInstr(func_name, args, dest))
            return dest

    def gen_field_access(self, fa: FieldAccess) -> IRVar:
        obj = self.gen_expr(fa.object)
        dest = self.new_temp()
        self.add_instr(LoadFieldInstr(obj, fa.field, dest))
        return dest

    def gen_struct_lit(self, sl: StructLit) -> IRVar:
        struct_name = sl.path[-1]
        # 分配结构体内存，逐个存储字段
        alloc = self.new_temp()
        self.add_instr(AllocStructInstr(struct_name, alloc))
        for fname, val in sl.fields:
            v = self.gen_expr(val)
            self.add_instr(StoreFieldInstr(alloc, fname, v))
        return alloc

    def gen_block(self, block: Block):
        last_val = None
        for stmt in block.stmts:
            last_val = self.gen_stmt(stmt)
        if block.expr:
            last_val = self.gen_expr(block.expr)
        return last_val

    def gen_if(self, ifexpr: If):
        cond = self.gen_expr(ifexpr.cond)
        then_block = self.new_block("then")
        else_block = self.new_block("else") if ifexpr.else_branch else None
        merge_block = self.new_block("if_merge")
        if else_block:
            self.add_instr(BranchInstr(cond, then_block.name, else_block.name))
        else:
            self.add_instr(BranchInstr(cond, then_block.name, merge_block.name))
        self.current_func.blocks.append(then_block)
        self.current_block = then_block
        self.gen_expr(ifexpr.then_branch)
        if not self.current_block.terminated():
            self.add_instr(JumpInstr(merge_block.name))
        if else_block:
            self.current_func.blocks.append(else_block)
            self.current_block = else_block
            self.gen_expr(ifexpr.else_branch)
            if not self.current_block.terminated():
                self.add_instr(JumpInstr(merge_block.name))
        self.current_func.blocks.append(merge_block)
        self.current_block = merge_block
        return None

    def gen_loop(self, loop: Loop):
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
        if not self.current_block.terminated():
            self.add_instr(JumpInstr(header.name))
        self.current_func.blocks.append(exit_block)
        self.current_block = exit_block
        return None

    def gen_for(self, for_expr: For):
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
        if not self.current_block.terminated():
            self.add_instr(JumpInstr(header.name))
        self.current_func.blocks.append(exit_block)
        self.current_block = exit_block
        return None

    def gen_match(self, match: Match):
        val = self.gen_expr(match.expr)
        merge = self.new_block("match_merge")
        for i, arm in enumerate(match.arms):
            if i < len(match.arms) - 1:
                next_block = self.new_block("match_next")
            else:
                next_block = merge
            dest = self.new_temp()
            self.add_instr(BinaryInstr('==', val, self._gen_pattern(arm.pattern), dest))
            then_block = self.new_block("match_then")
            self.add_instr(BranchInstr(dest, then_block.name, next_block.name))
            self.current_func.blocks.append(then_block)
            self.current_block = then_block
            self.gen_expr(arm.body)
            if not self.current_block.terminated():
                self.add_instr(JumpInstr(merge.name))
            self.current_func.blocks.append(next_block)
            self.current_block = next_block
        self.current_func.blocks.append(merge)
        self.current_block = merge
        return None

    def _gen_pattern(self, pat):
        if isinstance(pat, LiteralPattern):
            return self.gen_literal(pat.lit)
        return self.new_temp()  # wildcard 返回临时值

    def gen_return(self, ret: ReturnStmt):
        if ret.value:
            val = self.gen_expr(ret.value)
            self.add_instr(ReturnInstr(val))
        else:
            self.add_instr(ReturnInstr(None))
        return None

    def gen_let(self, let: LetStmt):
        val_ir = self.gen_expr(let.value) if let.value else None
        # 推断类型
        typ = let.type_
        if typ is None and let.value is not None:
            if isinstance(let.value, StructLit):
                typ = PathType(let.value.path)
            elif isinstance(let.value, Literal):
                kind_map = {'int': 'int', 'float': 'float', 'bool': 'bool', 'string': 'string', 'char': 'char', 'unit': 'unit'}
                typ = BaseType(kind_map.get(let.value.kind, 'unit'))
            else:
                typ = BaseType('unit')  # 保守
        var_ir = IRVar(let.name, VarKind.LOCAL, typ)
        if val_ir:
            self.add_instr(AllocInstr(typ, var_ir))
            self.add_instr(StoreInstr(var_ir, val_ir))
        self.local_vars[let.name] = var_ir
        # 更新符号表
        sym = self.symtab.lookup(let.name, recursive=False)
        if sym:
            sym.type = typ
            sym.ir_var = var_ir
        return var_ir

    def gen_break(self):
        if not self.loop_stack:
            raise RuntimeError("break outside loop")
        _, exit_block = self.loop_stack[-1]
        self.add_instr(JumpInstr(exit_block.name))
        return None

    def gen_continue(self):
        if not self.loop_stack:
            raise RuntimeError("continue outside loop")
        header, _ = self.loop_stack[-1]
        self.add_instr(JumpInstr(header.name))
        return None

    def _get_func_name(self, expr) -> str:
        if isinstance(expr, Ident):
            return expr.name
        elif isinstance(expr, PathType):
            return '::'.join(expr.path)
        return 'unknown'
