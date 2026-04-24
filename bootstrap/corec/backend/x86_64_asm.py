from corec.ir.coreir import *
from corec.ir.base import VarKind

class X86_64AsmGen:
    def __init__(self, module: Module):
        self.module = module
        self.output = []
        self.reg_pool = ['rax', 'rbx', 'rcx', 'rdx', 'rsi', 'rdi', 'r8', 'r9', 'r10', 'r11']
        self.var_to_reg = {}
        self.reg_in_use = set()

    def emit(self, line):
        self.output.append(line)

    def alloc_reg(self, var):
        if id(var) in self.var_to_reg:
            return self.var_to_reg[id(var)]
        for reg in self.reg_pool:
            if reg not in self.reg_in_use:
                self.reg_in_use.add(reg)
                self.var_to_reg[id(var)] = reg
                return reg
        raise RuntimeError("Out of registers")

    def free_reg(self, var):
        reg = self.var_to_reg.pop(id(var), None)
        if reg:
            self.reg_in_use.discard(reg)

    def get_reg(self, var):
        return self.var_to_reg.get(id(var))

    def generate(self):
        self.emit("section .text")
        self.emit("global _start")
        self.emit("")
        for func in self.module.functions:
            self.gen_function(func)
        return '\n'.join(self.output)

    def gen_function(self, func):
        # 用函数名作为标签，main 对应 _start
        if func.name == 'main':
            self.emit("_start:")
        else:
            self.emit(f"{func.name}:")
        # prologue
        self.emit("    push rbp")
        self.emit("    mov rbp, rsp")
        # 清空寄存器映射
        self.var_to_reg.clear()
        self.reg_in_use.clear()
        # 参数寄存器：x86-64 System V 调用约定 (rdi, rsi, rdx, rcx, r8, r9)
        param_regs = ['rdi', 'rsi', 'rdx', 'rcx', 'r8', 'r9']
        for i, param in enumerate(func.params):
            reg = param_regs[i] if i < len(param_regs) else None
            if reg:
                self.var_to_reg[id(param)] = reg
                self.reg_in_use.add(reg)
        # 按顺序输出基本块（entry 最先，其余按顺序）
        blocks = [func.entry] + [b for b in func.blocks if b != func.entry]
        for blk in blocks:
            self.emit(f"    ; block {blk.name}")
            for instr in blk.instrs:
                self.gen_instr(instr, func)
        # epilogue
        if func.name == 'main':
            # 退出系统调用
            self.emit("    ; exit syscall")
            self.emit("    mov eax, 60")
            self.emit("    xor edi, edi")
            self.emit("    syscall")
        else:
            self.emit("    pop rbp")
            self.emit("    ret")

    def gen_instr(self, instr, func):
        if isinstance(instr, ConstInstr):
            reg = self.alloc_reg(instr.dest)
            val = instr.value
            if isinstance(val, bool):
                val = 1 if val else 0
            self.emit(f"    mov {reg}, {val}")
        elif isinstance(instr, BinaryInstr):
            left_reg = self.get_reg(instr.left)
            right_reg = self.get_reg(instr.right)
            dest_reg = self.alloc_reg(instr.dest)
            if left_reg is None or right_reg is None:
                raise RuntimeError("Operand not in register (memory not supported)")
            if instr.op == '+':
                self.emit(f"    mov {dest_reg}, {left_reg}")
                self.emit(f"    add {dest_reg}, {right_reg}")
            elif instr.op == '-':
                self.emit(f"    mov {dest_reg}, {left_reg}")
                self.emit(f"    sub {dest_reg}, {right_reg}")
            elif instr.op == '*':
                self.emit(f"    mov rax, {left_reg}")
                self.emit(f"    imul {right_reg}")
                self.emit(f"    mov {dest_reg}, rax")
            elif instr.op == '/':
                self.emit(f"    mov rax, {left_reg}")
                self.emit(f"    cqo")
                self.emit(f"    idiv {right_reg}")
                self.emit(f"    mov {dest_reg}, rax")
            else:
                raise NotImplementedError(f"Binary op {instr.op}")
        elif isinstance(instr, CallInstr):
            # 传递参数
            arg_regs = ['rdi', 'rsi', 'rdx', 'rcx', 'r8', 'r9']
            for i, arg in enumerate(instr.args):
                if i >= len(arg_regs):
                    break
                arg_val_reg = self.get_reg(arg)
                if arg_val_reg:
                    self.emit(f"    mov {arg_regs[i]}, {arg_val_reg}")
                else:
                    # 如果参数是常量，但 IR 中应已加载到 reg
                    raise RuntimeError("Call arg not in register")
            self.emit(f"    call {instr.func}")
            if instr.dest:
                dest_reg = self.alloc_reg(instr.dest)
                self.emit(f"    mov {dest_reg}, rax")
        elif isinstance(instr, ReturnInstr):
            if instr.value:
                val_reg = self.get_reg(instr.value)
                if val_reg:
                    self.emit(f"    mov rax, {val_reg}")
                else:
                    # 可能是常量
                    self.emit(f"    mov rax, {instr.value.value}")
        elif isinstance(instr, JumpInstr):
            self.emit(f"    jmp {instr.label}")
        elif isinstance(instr, BranchInstr):
            cond_reg = self.get_reg(instr.cond)
            if cond_reg:
                self.emit(f"    cmp {cond_reg}, 1")
                self.emit(f"    je {instr.true_label}")
                self.emit(f"    jmp {instr.false_label}")
        else:
            raise NotImplementedError(f"Instruction {type(instr)}")
