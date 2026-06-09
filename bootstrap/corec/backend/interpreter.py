from corec.ir.coreir import *
from corec.syntax.ast import ArrayType, PathType, BaseType

class Interpreter:
    def __init__(self, module):
        self.module = module
        self.funcs = {f.name: f for f in module.functions}
        self.vars = {}
        # Initialize global constants
        for g in module.globals:
            val = getattr(g, 'constant_value', None)
            if val is not None:
                self.vars[id(g)] = val
            else:
                typ = g.type
                if isinstance(typ, ArrayType):
                    self.vars[id(g)] = [None] * typ.size
                elif isinstance(typ, PathType):
                    self.vars[id(g)] = {}
                else:
                    self.vars[id(g)] = self._default_for_type(typ)

    @staticmethod
    def _default_for_type(typ):
        from corec.syntax.ast import BaseType
        if isinstance(typ, BaseType):
            if typ.name == 'int': return 0
            if typ.name == 'float': return 0.0
            if typ.name == 'bool': return False
            if typ.name == 'string': return ''
            if typ.name == 'char': return '\x00'
        return None

    # Built-in functions that are handled directly in Python
    builtins = {}

    def run(self, entry_func, args):
        func = self.funcs[entry_func]
        self.vars.clear()
        # Re-initialize globals with type awareness
        for g in self.module.globals:
            val = getattr(g, 'constant_value', None)
            if val is not None:
                self.vars[id(g)] = val
            else:
                typ = g.type
                if isinstance(typ, ArrayType):
                    sz = typ.size if typ.size is not None else 0
                    self.vars[id(g)] = [None] * sz
                elif isinstance(typ, PathType):
                    self.vars[id(g)] = {}
                else:
                    self.vars[id(g)] = self._default_for_type(typ)
        for i, param in enumerate(func.params):
            self.vars[id(param)] = args[i]
        return self.run_func(func)

    def run_func(self, func):
        self.current_func_name = func.name
        block = func.entry
        max_steps = 1000000
        step = 0
        while block is not None and step < max_steps:
            step += 1
            result = self.exec_block(block)
            if isinstance(result, tuple):
                block_name, ret_val = result
                if block_name is None:
                    return ret_val
                block = next((b for b in func.blocks if b.name == block_name), None)
                if block is None:
                    raise RuntimeError(f"Block {block_name} not found")
            else:
                break
        if step >= max_steps:
            raise RuntimeError(f"Max steps exceeded in {func.name} ({step} steps)")
        return None

    def exec_block(self, block):
        for instr in block.instrs:
            result = self._exec_one(instr)
            if result is not None:
                return result
        return None

    def _exec_one(self, instr):
        if isinstance(instr, ConstInstr):
            val = instr.value
            if instr.type == 'int':
                val = int(val) if isinstance(val, str) else val
            elif instr.type == 'float':
                val = float(val) if isinstance(val, str) else val
            # string, char, bool: keep original value
            self.vars[id(instr.dest)] = val
        elif isinstance(instr, BinaryInstr):
            left_raw = self.vars.get(id(instr.left))
            right_raw = self.vars.get(id(instr.right))
            if instr.op == '+':
                if isinstance(left_raw, str) or isinstance(right_raw, str):
                    res = str(left_raw) + str(right_raw)
                    self.vars[id(instr.dest)] = res
                    return
            left = self._to_value(left_raw)
            right = self._to_value(right_raw)
            if instr.op == '+': res = left + right
            elif instr.op == '-': res = left - right
            elif instr.op == '*': res = left * right
            elif instr.op == '/':
                if isinstance(left, int) and isinstance(right, int):
                    res = left // right
                else:
                    res = left / right
            elif instr.op == '>': res = left > right
            elif instr.op == '<': res = left < right
            elif instr.op == '>=': res = left >= right
            elif instr.op == '<=': res = left <= right
            elif instr.op == '==': res = left == right
            elif instr.op == '!=': res = left != right
            elif instr.op == '&&': res = left and right
            elif instr.op == '||': res = left or right
            elif instr.op == '%': res = left % right
            else: raise NotImplementedError(f"op {instr.op}")
            self.vars[id(instr.dest)] = res
        elif isinstance(instr, UnaryInstr):
            op_val = self.vars.get(id(instr.operand))
            if instr.op == '-': res = -op_val
            elif instr.op == '!': res = not op_val
            else: raise NotImplementedError(f"unary op {instr.op}")
            self.vars[id(instr.dest)] = res
        elif isinstance(instr, CallInstr):
            # Handle built-in functions
            if instr.func == '__builtin_str_len':
                s = self.vars.get(id(instr.args[0]), '')
                if instr.dest:
                    self.vars[id(instr.dest)] = len(s)
                return
            if instr.func == '__builtin_str_get':
                s = self.vars.get(id(instr.args[0]), '')
                idx = self.vars.get(id(instr.args[1]), 0)
                if instr.dest:
                    ch = s[idx] if 0 <= idx < len(s) else '\x00'
                    self.vars[id(instr.dest)] = ch
                return
            if instr.func == '__builtin_str_sub':
                s = self.vars.get(id(instr.args[0]), '')
                start = self.vars.get(id(instr.args[1]), 0)
                length = self.vars.get(id(instr.args[2]), 0)
                if instr.dest:
                    self.vars[id(instr.dest)] = s[start:start+length]
                return
            if instr.func == '__builtin_int_to_str':
                i = self.vars.get(id(instr.args[0]), 0)
                if instr.dest:
                    self.vars[id(instr.dest)] = str(i)
                return
            if instr.func == '__builtin_str_push':
                s = self.vars.get(id(instr.args[0]), '')
                c = self.vars.get(id(instr.args[1]), '')
                if instr.dest:
                    self.vars[id(instr.dest)] = s + c
                return
            if instr.func == '__builtin_str_from_int':
                i = self.vars.get(id(instr.args[0]), 0)
                if instr.dest:
                    self.vars[id(instr.dest)] = str(i)
                return
            if instr.func == '__builtin_str_to_int':
                s = self.vars.get(id(instr.args[0]), '0')
                if instr.dest:
                    try:
                        self.vars[id(instr.dest)] = int(s)
                    except:
                        self.vars[id(instr.dest)] = 0
                return
            if instr.func == '__builtin_str_eq':
                a = self.vars.get(id(instr.args[0]), '')
                b = self.vars.get(id(instr.args[1]), '')
                if instr.dest:
                    self.vars[id(instr.dest)] = 1 if a == b else 0
                return
            if instr.func == '__builtin_str_cmp':
                a = self.vars.get(id(instr.args[0]), '')
                b = self.vars.get(id(instr.args[1]), '')
                if instr.dest:
                    if a < b: self.vars[id(instr.dest)] = -1
                    elif a > b: self.vars[id(instr.dest)] = 1
                    else: self.vars[id(instr.dest)] = 0
                return
            if instr.func == '__builtin_print':
                s = self.vars.get(id(instr.args[0]), '')
                print(s, end='')
                return
            if instr.func == '__builtin_println':
                s = self.vars.get(id(instr.args[0]), '')
                print(s)
                return
            if instr.func == '__builtin_get_arg':
                import os
                n = self.vars.get(id(instr.args[0]), 0)
                if instr.dest:
                    argv = getattr(self, '_argv', [])
                    self.vars[id(instr.dest)] = argv[n] if 0 <= n < len(argv) else ''
                return
            if instr.func == '__builtin_read_file':
                path = self.vars.get(id(instr.args[0]), '')
                if instr.dest:
                    try:
                        with open(path, 'r') as f:
                            self.vars[id(instr.dest)] = f.read()
                    except:
                        self.vars[id(instr.dest)] = ''
                return
            if instr.func == '__builtin_write_file':
                path = self.vars.get(id(instr.args[0]), '')
                content = self.vars.get(id(instr.args[1]), '')
                if instr.dest:
                    try:
                        with open(path, 'w') as f:
                            self.vars[id(instr.dest)] = f.write(content)
                    except:
                        self.vars[id(instr.dest)] = -1
                return
            if instr.func == '__builtin_syscall3':
                nr = self.vars.get(id(instr.args[0]), 0)
                a1 = self.vars.get(id(instr.args[1]), 0)
                a2 = self.vars.get(id(instr.args[2]), 0)
                a3 = self.vars.get(id(instr.args[3])) if len(instr.args) > 3 else 0
                import os
                result = -1
                if nr == 2:  # sys_open(path, flags, mode)
                    # a1=path (string), a2=flags (int), a3=mode (int)
                    try:
                        result = os.open(a1, a2, a3)
                    except OSError:
                        result = -1
                elif nr == 1:  # sys_write(fd, buf, count)
                    # a1=fd (int), a2=buf (list of byte values), a3=count (int)
                    fd = a1
                    if isinstance(a2, list):
                        buf_bytes = bytes(a2[:a3])
                    elif isinstance(a2, str):
                        buf_bytes = a2[:a3].encode()
                    elif isinstance(a2, bytes):
                        buf_bytes = a2[:a3]
                    else:
                        buf_bytes = bytes([a2 & 0xFF])[:a3]
                    try:
                        result = os.write(fd, buf_bytes)
                    except OSError:
                        result = -1
                elif nr == 3:  # sys_close(fd)
                    # a1=fd (int)
                    try:
                        os.close(a1)
                        result = 0
                    except OSError:
                        result = -1
                if instr.dest:
                    self.vars[id(instr.dest)] = result
                return
            if instr.func == '__builtin_load8':
                s = self.vars.get(id(instr.args[0]))
                idx = self.vars.get(id(instr.args[1]), 0)
                if instr.dest and s is not None and idx >= 0 and idx < len(s):
                    self.vars[id(instr.dest)] = ord(s[idx]) if isinstance(s, str) else (s[idx] & 0xFF)
                elif instr.dest:
                    self.vars[id(instr.dest)] = 0
                return
            if instr.func == '__builtin_store8':
                s = self.vars.get(id(instr.args[0]))
                idx = self.vars.get(id(instr.args[1]), 0)
                val = self.vars.get(id(instr.args[2]), 0)
                if s is not None and idx >= 0 and idx < len(s):
                    if isinstance(s, bytearray) or isinstance(s, list):
                        s[idx] = val & 0xFF
                if instr.dest:
                    self.vars[id(instr.dest)] = 0
                return
            if instr.func == '__builtin_alloc':
                size = self.vars.get(id(instr.args[0]), 0)
                if instr.dest:
                    self.vars[id(instr.dest)] = [0] * ((size + 7) // 8)
                return
            func = self.funcs[instr.func]
            arg_vals = [self.vars.get(id(a)) for a in instr.args]
            old_vars = self.vars
            # New scope inherits globals so functions see module-level variables
            self.vars = {id(g): old_vars.get(id(g)) for g in self.module.globals}
            for i, p in enumerate(func.params):
                self.vars[id(p)] = arg_vals[i]
            result = self.run_func(func)
            # Sync modified globals back to caller scope
            for g in self.module.globals:
                gid = id(g)
                old_vars[gid] = self.vars.get(gid, old_vars.get(gid))
            self.vars = old_vars
            if instr.dest:
                self.vars[id(instr.dest)] = result
        elif isinstance(instr, RefInstr):
            # Store the id of the referenced variable slot
            self.vars[id(instr.dest)] = id(instr.variable)
        elif isinstance(instr, AllocInstr):
            typ = instr.type
            if isinstance(typ, ArrayType):
                self.vars[id(instr.dest)] = [None] * typ.size
            elif isinstance(typ, PathType):
                self.vars[id(instr.dest)] = {}
            else:
                self.vars[id(instr.dest)] = None
        elif isinstance(instr, AllocStructInstr):
            self.vars[id(instr.dest)] = {}
        elif isinstance(instr, AllocArrayInstr):
            self.vars[id(instr.dest)] = [None] * instr.size
        elif isinstance(instr, StoreInstr):
            dest = self.vars.get(id(instr.addr))
            if isinstance(dest, int) and dest in self.vars:
                # addr is a reference — store to the pointed-to variable
                val = self.vars.get(id(instr.value))
                if isinstance(val, int) and val in self.vars:
                    val = self.vars.get(val)
                self.vars[dest] = val
            else:
                val = self.vars.get(id(instr.value))
                if isinstance(val, int) and val in self.vars:
                    val = self.vars.get(val)
                self.vars[id(instr.addr)] = val
        elif isinstance(instr, LoadInstr):
            src = self.vars.get(id(instr.addr))
            if isinstance(src, int) and src in self.vars:
                # addr is a reference — load through it
                self.vars[id(instr.dest)] = self.vars.get(src)
            else:
                self.vars[id(instr.dest)] = src
        elif isinstance(instr, LoadFieldInstr):
            obj = self.vars.get(id(instr.struct))
            if isinstance(obj, int) and obj in self.vars:
                obj = self.vars.get(obj)  # follow reference
            if isinstance(obj, dict):
                self.vars[id(instr.dest)] = obj.get(instr.field)
            else:
                raise RuntimeError(f"LoadField on non-struct: {obj}")
        elif isinstance(instr, StoreFieldInstr):
            obj = self.vars.get(id(instr.struct))
            if isinstance(obj, int) and obj in self.vars:
                obj = self.vars.get(obj)  # follow reference
            val = self.vars.get(id(instr.value))
            if isinstance(obj, dict):
                obj[instr.field] = val
            else:
                raise RuntimeError("StoreField on non-struct")
        elif isinstance(instr, StoreIndexInstr):
            arr = self.vars.get(id(instr.array))
            if isinstance(arr, int) and arr in self.vars:
                arr = self.vars.get(arr)
            arr[instr.index] = self.vars.get(id(instr.value))
        elif isinstance(instr, LoadIndexInstr):
            arr = self.vars.get(id(instr.array))
            if isinstance(arr, int) and arr in self.vars:
                arr = self.vars.get(arr)
            self.vars[id(instr.dest)] = arr[instr.index]
        elif isinstance(instr, LoadIndexVarInstr):
            arr = self.vars.get(id(instr.array))
            if isinstance(arr, int) and arr in self.vars:
                arr = self.vars.get(arr)
            idx = self.vars.get(id(instr.index_var))
            self.vars[id(instr.dest)] = arr[idx]
        elif isinstance(instr, StoreIndexVarInstr):
            arr = self.vars.get(id(instr.array))
            if isinstance(arr, int) and arr in self.vars:
                arr = self.vars.get(arr)
            idx = self.vars.get(id(instr.index_var))
            arr[idx] = self.vars.get(id(instr.value))
        elif isinstance(instr, LoadEnumTagInstr):
            obj = self.vars.get(id(instr.enum_var))
            if isinstance(obj, int) and obj in self.vars:
                obj = self.vars.get(obj)
            if isinstance(obj, dict):
                tag = obj.get('__variant', 0)
                self.vars[id(instr.dest)] = tag
            else:
                self.vars[id(instr.dest)] = 0
        elif isinstance(instr, MakeEnumInstr):
            args = [self.vars.get(id(a)) for a in instr.args]
            obj = {'__variant': instr.variant}
            for i, arg in enumerate(args):
                if isinstance(arg, int) and arg in self.vars:
                    arg = self.vars.get(arg)  # follow reference
                obj[f'_field_{i}'] = arg
            self.vars[id(instr.dest)] = obj
        elif isinstance(instr, BranchInstr):
            cond = self.vars[id(instr.cond)]
            if cond:
                return (instr.true_label, None)
            else:
                return (instr.false_label, None)
        elif isinstance(instr, JumpInstr):
            return (instr.label, None)
        elif isinstance(instr, ReturnInstr):
            if instr.value:
                val = self.vars.get(id(instr.value))
                return (None, val)
            return (None, None)
        elif isinstance(instr, LabelInstr):
            pass
        else:
            raise NotImplementedError(f"instr {type(instr)}")
        return None

    def _to_value(self, v):
        return v
