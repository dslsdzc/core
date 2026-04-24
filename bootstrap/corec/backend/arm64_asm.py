from corec.ir.coreir import *
from corec.ir.base import VarKind

class Arm64AsmGen:
    def __init__(self, module: Module, struct_fields=None):
        self.module = module
        self.output = []
        self.struct_fields = struct_fields if struct_fields else {}
        self.current_func = None
        self.stack_offsets = {}           # var id -> stack offset (from sp)
        self.struct_data_offsets = {}     # struct var id -> data area offset
        self.next_stack_offset = 0
        self.label_count = 0

    def new_label(self, hint="L"):
        self.label_count += 1
        return f"{hint}_{self.label_count}"

    def emit(self, line):
        self.output.append(line)

    def generate(self):
        self.emit(".section .text")
        self.emit(".globl _start")
        self.emit("")
        for func in self.module.functions:
            self.gen_function(func)
        return '\n'.join(self.output)

    def gen_function(self, func):
        self.current_func = func
        if func.name == 'main':
            self.emit("_start:")
        else:
            self.emit(f"{func.name}:")

        self.stack_offsets.clear()
        self.struct_data_offsets.clear()
        self.next_stack_offset = 0

        # 收集需要分配栈空间的变量和结构体
        struct_dests = []  # (dest_var, field_count)
        for blk in func.blocks:
            for instr in blk.instrs:
                if isinstance(instr, AllocStructInstr):
                    struct_dests.append((instr.dest, instr.field_count))
                elif isinstance(instr, AllocInstr):
                    self._alloc_stack(instr.dest, 8)
                # 为所有 dest 变量分配空间（临时变量等）
                if hasattr(instr, 'dest') and instr.dest is not None:
                    if id(instr.dest) not in self.stack_offsets:
                        self._alloc_stack(instr.dest, 8)
        # 为参数分配空间
        for param in func.params:
            if id(param) not in self.stack_offsets:
                self._alloc_stack(param, 8)

        # 为结构体分配指针变量（8字节）和数据区
        for dest_var, fcount in struct_dests:
            self._alloc_stack(dest_var, 8)  # 指针变量
            data_off = self._alloc_data(fcount * 8)
            self.struct_data_offsets[id(dest_var)] = data_off

        total_stack = self.next_stack_offset
        # prologue
        self.emit("    stp x29, x30, [sp, #-16]!")
        self.emit("    mov x29, sp")
        if total_stack > 0:
            aligned = (total_stack + 15) & ~15
            self.emit(f"    sub sp, sp, #{aligned}")

        # 存储参数到栈（从 x0-x7）
        param_regs = ['x0','x1','x2','x3','x4','x5','x6','x7']
        for i, param in enumerate(func.params):
            reg = param_regs[i] if i < len(param_regs) else None
            if reg:
                off = self.stack_offsets[id(param)]
                self.emit(f"    str {reg}, [sp, #{off}]")

        # 输出基本块
        blocks = [func.entry] + [b for b in func.blocks if b != func.entry]
        return_label = self.new_label("return")
        for blk in blocks:
            if blk != func.entry:
                self.emit(f"{blk.name}:")
            for instr in blk.instrs:
                self.gen_instr(instr, return_label)
            # 如果块末尾没有终止指令，添加跳转到 return_label
            if not any(isinstance(i, (BranchInstr, JumpInstr, ReturnInstr)) for i in blk.instrs):
                self.emit(f"    b {return_label}")

        # 统一的返回点
        self.emit(f"{return_label}:")

        # epilogue
        if func.name == 'main':
            self.emit("    // exit syscall")
            self.emit("    mov x8, #93")
            self.emit("    svc #0")
        else:
            if total_stack > 0:
                aligned = (total_stack + 15) & ~15
                self.emit(f"    add sp, sp, #{aligned}")
            self.emit("    ldp x29, x30, [sp], #16")
            self.emit("    ret")

    def _alloc_stack(self, var, size):
        """分配栈槽并返回偏移"""
        if id(var) in self.stack_offsets:
            return self.stack_offsets[id(var)]
        off = self.next_stack_offset
        self.stack_offsets[id(var)] = off
        self.next_stack_offset += size
        return off

    def _alloc_data(self, size):
        """分配数据区，返回起始偏移"""
        off = self.next_stack_offset
        self.next_stack_offset += size
        return off

    def load_var_to_reg(self, var, reg):
        off = self.stack_offsets[id(var)]
        self.emit(f"    ldr {reg}, [sp, #{off}]")

    def store_reg_to_var(self, reg, var):
        off = self.stack_offsets[id(var)]
        self.emit(f"    str {reg}, [sp, #{off}]")

    def gen_instr(self, instr, return_label=None):
        if isinstance(instr, ConstInstr):
            off = self.stack_offsets[id(instr.dest)]
            val = instr.value
            if isinstance(val, bool):
                val = 1 if val else 0
            self.emit(f"    mov x9, #{val}")
            self.emit(f"    str x9, [sp, #{off}]")
        elif isinstance(instr, BinaryInstr):
            self.load_var_to_reg(instr.left, 'x10')
            self.load_var_to_reg(instr.right, 'x11')
            dest_off = self.stack_offsets[id(instr.dest)]
            if instr.op == '+':
                self.emit(f"    add x12, x10, x11")
            elif instr.op == '-':
                self.emit(f"    sub x12, x10, x11")
            elif instr.op == '*':
                self.emit(f"    mul x12, x10, x11")
            elif instr.op == '/':
                self.emit(f"    sdiv x12, x10, x11")
            elif instr.op in ('==','!=','<','>','<=','>='):
                self.emit(f"    cmp x10, x11")
                cond_map = {'==':'eq','!=':'ne','<':'lt','>':'gt','<=':'le','>=':'ge'}
                cond = cond_map.get(instr.op)
                self.emit(f"    cset w12, {cond}")
            else:
                raise NotImplementedError(f"Binary op {instr.op}")
            self.emit(f"    str x12, [sp, #{dest_off}]")
        elif isinstance(instr, CallInstr):
            arg_regs = ['x0','x1','x2','x3','x4','x5','x6','x7']
            for i, arg in enumerate(instr.args):
                if i >= len(arg_regs):
                    break
                self.load_var_to_reg(arg, arg_regs[i])
            self.emit(f"    bl {instr.func}")
            if instr.dest:
                dest_off = self.stack_offsets[id(instr.dest)]
                self.emit(f"    str x0, [sp, #{dest_off}]")
        elif isinstance(instr, AllocInstr):
            pass
        elif isinstance(instr, AllocStructInstr):
            # 将数据区指针写入 dest 变量
            data_off = self.struct_data_offsets[id(instr.dest)]
            ptr_off = self.stack_offsets[id(instr.dest)]
            self.emit(f"    add x9, sp, #{data_off}")
            self.emit(f"    str x9, [sp, #{ptr_off}]")
        elif isinstance(instr, StoreInstr):
            self.load_var_to_reg(instr.value, 'x9')
            self.store_reg_to_var('x9', instr.addr)
        elif isinstance(instr, LoadInstr):
            self.load_var_to_reg(instr.addr, 'x9')
            self.store_reg_to_var('x9', instr.dest)
        elif isinstance(instr, LoadFieldInstr):
            field_idx = instr.field_index
            if field_idx < 0:
                raise RuntimeError("Missing field index")
            # 加载基址指针
            ptr_off = self.stack_offsets[id(instr.struct)]
            self.emit(f"    ldr x9, [sp, #{ptr_off}]")  # x9 = struct base
            if field_idx == 0:
                self.emit(f"    ldr x10, [x9]")
            else:
                self.emit(f"    ldr x10, [x9, #{field_idx * 8}]")
            dest_off = self.stack_offsets[id(instr.dest)]
            self.emit(f"    str x10, [sp, #{dest_off}]")
        elif isinstance(instr, StoreFieldInstr):
            field_idx = instr.field_index
            if field_idx < 0:
                raise RuntimeError("Missing field index")
            # 加载基址指针
            ptr_off = self.stack_offsets[id(instr.struct)]
            self.emit(f"    ldr x9, [sp, #{ptr_off}]")
            # 加载要存储的值
            val_off = self.stack_offsets[id(instr.value)]
            self.emit(f"    ldr x10, [sp, #{val_off}]")
            if field_idx == 0:
                self.emit(f"    str x10, [x9]")
            else:
                self.emit(f"    str x10, [x9, #{field_idx * 8}]")
        elif isinstance(instr, ReturnInstr):
            if instr.value:
                self.load_var_to_reg(instr.value, 'x0')
            if return_label:
                self.emit(f"    b {return_label}")
        elif isinstance(instr, JumpInstr):
            self.emit(f"    b {instr.label}")
        elif isinstance(instr, BranchInstr):
            cond_off = self.stack_offsets[id(instr.cond)]
            self.emit(f"    ldr x9, [sp, #{cond_off}]")
            self.emit(f"    cmp x9, #1")
            self.emit(f"    b.eq {instr.true_label}")
            self.emit(f"    b {instr.false_label}")
        else:
            raise NotImplementedError(f"Instruction {type(instr)}")
