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
        while block is not None:
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
                if instr.op == '+': res = left + right
                elif instr.op == '-': res = left - right
                elif instr.op == '*': res = left * right
                elif instr.op == '/':
                    res = left // right if isinstance(left, int) else left / right
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
            elif isinstance(instr, AllocInstr):
                self.vars[id(instr.dest)] = None  # 占位
            elif isinstance(instr, AllocStructInstr):
                # 创建字典表示结构体对象
                self.vars[id(instr.dest)] = {}
            elif isinstance(instr, StoreInstr):
                self.vars[id(instr.addr)] = self.vars[id(instr.value)]
            elif isinstance(instr, LoadInstr):
                self.vars[id(instr.dest)] = self.vars[id(instr.addr)]
            elif isinstance(instr, LoadFieldInstr):
                obj = self.vars[id(instr.struct)]
                if isinstance(obj, dict):
                    self.vars[id(instr.dest)] = obj.get(instr.field, None)
                else:
                    raise RuntimeError(f"LoadField on non-struct object")
            elif isinstance(instr, StoreFieldInstr):
                obj = self.vars[id(instr.struct)]
                if isinstance(obj, dict):
                    obj[instr.field] = self.vars[id(instr.value)]
                else:
                    raise RuntimeError(f"StoreField on non-struct object")
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
