with open('bootstrap/corec/frontend/ir_gen.py', 'r') as f:
    content = f.read()

# 在 gen_binary 中，处理数组索引赋值：arr[i] = value
old_assign = """    def gen_binary(self, binop):
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
                return val"""

new_assign = """    def gen_binary(self, binop):
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
            elif isinstance(binop.left, Index):
                # 数组索引赋值：arr[i] = val
                arr = self.gen_expr(binop.left.object)
                if isinstance(binop.left.index, Literal) and binop.left.index.kind == 'int':
                    idx = int(binop.left.index.value)
                else:
                    raise RuntimeError("Index must be a constant integer literal for now")
                self.add_instr(StoreIndexInstr(arr, idx, val))
                return val"""

if old_assign in content:
    content = content.replace(old_assign, new_assign)
    with open('bootstrap/corec/frontend/ir_gen.py', 'w') as f:
        f.write(content)
    print('IRGen array assignment support added')
else:
    print('Old assignment block not found, checking alternative...')
    # 如果旧版不匹配，尝试直接替换 gen_binary 中的赋值部分
    start = content.find('    def gen_binary(self, binop):')
    if start != -1:
        end = content.find('    def gen_unary', start)
        if end == -1:
            end = len(content)
        # 用新代码替换整个方法
        new_method = """    def gen_binary(self, binop):
        if binop.op == "=":
            val = self.gen_expr(binop.right)
            if isinstance(binop.left, Ident):
                var = self.gen_ident(binop.left)
                self.add_instr(StoreInstr(var, val))
                return val
            elif isinstance(binop.left, FieldAccess):
                obj = self.gen_expr(binop.left.object)
                self.add_instr(StoreFieldInstr(obj, binop.left.field, val, field_index=-1))
                return val
            elif isinstance(binop.left, Index):
                arr = self.gen_expr(binop.left.object)
                if isinstance(binop.left.index, Literal) and binop.left.index.kind == 'int':
                    idx = int(binop.left.index.value)
                else:
                    raise RuntimeError("Index must be a constant integer literal for now")
                self.add_instr(StoreIndexInstr(arr, idx, val))
                return val
        left = self.gen_expr(binop.left)
        right = self.gen_expr(binop.right)
        dest = self.new_temp()
        self.add_instr(BinaryInstr(binop.op, left, right, dest))
        return dest"""
        content = content[:start] + new_method + content[end:]
        with open('bootstrap/corec/frontend/ir_gen.py', 'w') as f:
            f.write(content)
        print('gen_binary replaced with array assignment support')
