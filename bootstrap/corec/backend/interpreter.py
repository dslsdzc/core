from corec.ir.coreir import *

class Interpreter:
    def __init__(self, module):
        self.module = module
        self.funcs = {f.name: f for f in module.functions}
        self.vars = {}

    def run(self, entry_func, args):
        func = self.funcs[entry_func]
        self.vars.clear()
        for i, param in enumerate(func.params):
            self.vars[id(param)] = args[i]
        return self.run_func(func)

    def run_func(self, func):
        block = func.entry
        max_steps = 50000
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
            raise RuntimeError("Max steps exceeded")
        return None

    def exec_block(self, block):
        for instr in block.instrs:
            if isinstance(instr, ConstInstr):
                val = instr.value
                if isinstance(val, str):
                    if val.isdigit():
                        val = int(val)
                    else:
                        try: val = float(val)
                        except: pass
                self.vars[id(instr.dest)] = val
            elif isinstance(instr, BinaryInstr):
                left = self._to_value(self.vars[id(instr.left)])
                right = self._to_value(self.vars[id(instr.right)])
                if instr.op == '+':
                    if isinstance(left, str) or isinstance(right, str):
                        res = str(left) + str(right)
                    else:
                        res = left + right
                elif instr.op == '-': res = left - right
                elif instr.op == '*': res = left * right
                elif instr.op == '/':
                    res = left / right
                    if isinstance(res, float) and res.is_integer():
                        res = int(res)
                elif instr.op == '>': res = left > right
                elif instr.op == '<': res = left < right
                elif instr.op == '>=': res = left >= right
                elif instr.op == '<=': res = left <= right
                elif instr.op == '==': res = left == right
                elif instr.op == '!=': res = left != right
                elif instr.op == '&&': res = left and right
                elif instr.op == '||': res = left or right
                else: raise NotImplementedError(f"op {instr.op}")
                self.vars[id(instr.dest)] = res
            elif isinstance(instr, UnaryInstr):
                op_val = self.vars.get(id(instr.operand))
                if instr.op == '-': res = -op_val
                elif instr.op == '!': res = not op_val
                else: raise NotImplementedError(f"unary op {instr.op}")
                self.vars[id(instr.dest)] = res
            elif isinstance(instr, CallInstr):
                func = self.funcs[instr.func]
                arg_vals = [self.vars[id(a)] for a in instr.args]
                old_vars = self.vars
                self.vars = dict()
                for i, p in enumerate(func.params):
                    self.vars[id(p)] = arg_vals[i]
                result = self.run_func(func)
                self.vars = old_vars
                if instr.dest:
                    self.vars[id(instr.dest)] = result
            elif isinstance(instr, RefInstr):
                # Store the id of the referenced variable slot
                self.vars[id(instr.dest)] = id(instr.variable)
            elif isinstance(instr, AllocInstr):
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
                    return (None, self.vars[id(instr.value)])
                return (None, None)
            elif isinstance(instr, LabelInstr):
                pass
            else:
                raise NotImplementedError(f"instr {type(instr)}")
        return None

    def _to_value(self, v):
        if isinstance(v, str):
            if v.isdigit():
                return int(v)
            try: return float(v)
            except: pass
        return v
