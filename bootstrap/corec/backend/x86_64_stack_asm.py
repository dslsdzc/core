"""
Stack-based x86-64 assembly generator for Core IR.

Produces GAS .intel_syntax noprefix assembly compatible with the self-hosted
compiler's x86_64 backend. Uses stack slots for local variables and .data
section for global variables, matching the self-hosted compiler's data model.

This runs at Python speed (not interpreted Core) so it's fast enough to
compile the full compiler source (~4000 lines).
"""

import struct

from corec.ir.coreir import *
from corec.ir.base import IRVar, VarKind
from corec.syntax.ast import ArrayType, BaseType, PathType


class X86_64StackAsmGen:
    def __init__(self, module: Module):
        self.module = module
        self.lines = []
        self.str_labels = []      # [(label_id, string_value)]
        self.str_map = {}         # string_value -> label_id
        # Per-function state
        self.var_offsets = {}     # var_id -> stack offset (negative from rbp)
        self.stack_size = 0

    def _elem_size(self, typ) -> int:
        """Compute the element size (in bytes) for an array element type."""
        if isinstance(typ, BaseType):
            return 8  # all base types are 8 bytes (int, string ptr, etc.)
        if isinstance(typ, PathType):
            name = typ.path[-1]
            return self.module.struct_sizes.get(name, 8)
        return 8  # default (refs, other types)

    def is_global(self, var: IRVar) -> bool:
        return var.kind == VarKind.GLOBAL

    def _is_string_var(self, var: IRVar) -> bool:
        """Check if an IRVar is a string type (requires byte-level indexing)."""
        return isinstance(var.type, BaseType) and var.type.name == 'string'

    # ------------------------------------------------------------------
    # Memory reference helpers
    # ------------------------------------------------------------------

    def _get_stack_off(self, var: IRVar) -> int:
        """Get or allocate a stack offset for a local variable.

        Uses Python's id() as the dict key because IRVar.id is always 0
        (the bootstrap IRGen never sets it, so all IRVars share id=0).
        """
        key = id(var)
        if key not in self.var_offsets:
            idx = len(self.var_offsets)
            off = -(idx + 1) * 8
            self.var_offsets[key] = off
            self.stack_size = (idx + 1) * 8
        return self.var_offsets[key]

    def _global_label(self, name: str) -> str:
        """Return a GAS-safe label for a global variable (prefix to avoid register name conflicts)."""
        return f"_g_{name}"

    def _ref(self, var: IRVar) -> str:
        """Return an x86-64 memory reference string for a variable."""
        if self.is_global(var):
            return f"[rip+{self._global_label(var.name)}]"
        off = self._get_stack_off(var)
        if off >= 0:
            return f"[rbp+{off}]"
        return f"[rbp{off}]"

    def track_str(self, value: str) -> int:
        if value not in self.str_map:
            idx = len(self.str_labels)
            self.str_labels.append((idx, value))
            self.str_map[value] = idx
            return idx
        return self.str_map[value]

    def emit(self, line: str = ""):
        self.lines.append(line)

    def load_to_r10(self, var: IRVar):
        self.emit(f"    mov r10, {self._ref(var)}")

    def store_from_r10(self, var: IRVar):
        self.emit(f"    mov {self._ref(var)}, r10")

    # ------------------------------------------------------------------
    # Instruction codegen
    # ------------------------------------------------------------------

    def gen_constant(self, instr: ConstInstr):
        ref = self._ref(instr.dest)
        if instr.type == 'string':
            instr.dest.type = BaseType('string')
            lid = self.track_str(instr.value)
            self.emit(f"    lea r10, .LC{lid}[rip]")
            self.emit(f"    mov {ref}, r10")
        else:
            val = instr.value
            if isinstance(val, float):
                val = struct.unpack('<q', struct.pack('<d', val))[0]
            elif isinstance(val, bool):
                val = int(val)
            if val >= -(2**31) and val < 2**31:
                self.emit(f"    mov qword ptr {ref}, {val}")
            else:
                self.emit(f"    mov r10, {val}")
                self.emit(f"    mov {ref}, r10")

    def gen_binary(self, instr: BinaryInstr):
        self.load_to_r10(instr.left)
        self.emit(f"    mov r11, {self._ref(instr.right)}")
        op = instr.op
        # String comparison: emit __builtin_str_eq or __builtin_str_cmp call
        if op in ('==', '!=', '<', '>', '<=', '>=') and (self._is_string_var(instr.left) or self._is_string_var(instr.right)):
            if op in ('==', '!='):
                self.emit(f"    mov rdi, r10")
                self.emit(f"    mov rsi, r11")
                self.emit("    call __builtin_str_eq")
                if op == '==':
                    self.emit(f"    mov {self._ref(instr.dest)}, rax")
                else:
                    self.emit("    cmp rax, 1")
                    self.emit("    setne al\n    movzx r10, al")
                    self.store_from_r10(instr.dest)
            else:
                # Ordering comparisons via strcmp
                self.emit(f"    mov rdi, r10")
                self.emit(f"    mov rsi, r11")
                self.emit("    call __builtin_str_cmp")
                self.emit("    cmp rax, 0")
                if op == '<': self.emit("    setl al\n    movzx r10, al")
                elif op == '>': self.emit("    setg al\n    movzx r10, al")
                elif op == '<=': self.emit("    setle al\n    movzx r10, al")
                elif op == '>=': self.emit("    setge al\n    movzx r10, al")
                self.store_from_r10(instr.dest)
            return
        elif op == '+':
            if self._is_string_var(instr.left) or self._is_string_var(instr.right):
                self.emit(f"    mov rdi, r10")
                self.emit(f"    mov rsi, r11")
                self.emit("    call __builtin_str_push")
                self.emit("    mov r10, rax")
                self.store_from_r10(instr.dest)
            else:
                self.emit("    add r10, r11")
        elif op == '-': self.emit("    sub r10, r11")
        elif op == '*': self.emit("    imul r10, r11")
        elif op == '/':
            self.emit("    mov rax, r10")
            self.emit("    cqo")
            self.emit("    idiv r11")
            self.emit("    mov r10, rax")
        elif op == '%':
            self.emit("    mov rax, r10")
            self.emit("    cqo")
            self.emit("    idiv r11")
            self.emit("    mov r10, rdx")
        elif op == '==':
            self.emit("    cmp r10, r11")
            self.emit("    sete al\n    movzx r10, al")
        elif op == '!=':
            self.emit("    cmp r10, r11")
            self.emit("    setne al\n    movzx r10, al")
        elif op == '<':
            self.emit("    cmp r10, r11")
            self.emit("    setl al\n    movzx r10, al")
        elif op == '>':
            self.emit("    cmp r10, r11")
            self.emit("    setg al\n    movzx r10, al")
        elif op == '<=':
            self.emit("    cmp r10, r11")
            self.emit("    setle al\n    movzx r10, al")
        elif op == '>=':
            self.emit("    cmp r10, r11")
            self.emit("    setge al\n    movzx r10, al")
        elif op == 'and' or op == '&&':
            self.emit("    and r10, r11")
        elif op == 'or' or op == '||':
            self.emit("    or r10, r11")
        else:
            raise NotImplementedError(f"Binary op {op}")
        self.store_from_r10(instr.dest)

    def gen_unary(self, instr: UnaryInstr):
        self.load_to_r10(instr.operand)
        if instr.op == '-':
            self.emit("    neg r10")
        elif instr.op == 'not' or instr.op == '!':
            self.emit("    cmp r10, 0")
            self.emit("    sete al\n    movzx r10, al")
        self.store_from_r10(instr.dest)

    def gen_call(self, instr: CallInstr):
        arg_regs = ['rdi', 'rsi', 'rdx', 'rcx', 'r8', 'r9']
        stack_args = 0
        for i, arg in enumerate(instr.args):
            if i < 6:
                self.emit(f"    mov {arg_regs[i]}, {self._ref(arg)}")
            else:
                stack_args += 1
        # Push 7th+ args on stack in reverse order (rightmost first)
        for i in reversed(range(6, len(instr.args))):
            self.emit(f"    push {self._ref(instr.args[i])}")
        if instr.func == '__builtin_syscall3':
            # Inline syscall: after arg setup rdi=nr, rsi=arg1, rdx=arg2, rcx=arg3
            # Need: rax=nr, rdi=arg1, rsi=arg2, rdx=arg3
            self.emit("    mov rax, rdi")
            self.emit("    mov rdi, rsi")
            self.emit("    mov rsi, rdx")
            self.emit("    mov rdx, rcx")
            self.emit("    syscall")
            if stack_args > 0:
                self.emit(f"    add rsp, {stack_args * 8}")
            if instr.dest:
                self.emit(f"    mov {self._ref(instr.dest)}, rax")
        elif instr.func == '__builtin_load8':
            # load8(string_ptr, idx) → byte at ptr+idx (zero-extended)
            self.emit("    movzx rax, BYTE PTR [rdi + rsi]")
            if stack_args > 0:
                self.emit(f"    add rsp, {stack_args * 8}")
            if instr.dest:
                self.emit(f"    mov qword ptr {self._ref(instr.dest)}, rax")
        elif instr.func == '__builtin_store8':
            # store8(string_ptr, idx, val) → store low byte of val at ptr+idx
            self.emit("    mov BYTE PTR [rdi + rsi], dl")
            if stack_args > 0:
                self.emit(f"    add rsp, {stack_args * 8}")
            if instr.dest:
                self.emit(f"    mov qword ptr {self._ref(instr.dest)}, 0")
        elif instr.func:
            self.emit(f"    call {instr.func}")
            if stack_args > 0:
                self.emit(f"    add rsp, {stack_args * 8}")
            if instr.dest:
                self.emit(f"    mov {self._ref(instr.dest)}, rax")

    def gen_return(self, instr: ReturnInstr):
        if instr.value:
            self.emit(f"    mov rax, {self._ref(instr.value)}")

    def gen_alloc(self, instr: AllocInstr):
        if not self.is_global(instr.dest):
            self._get_stack_off(instr.dest)
        # Heap-allocate if it's an array type (local variable like `let x: [int; N]`)
        if isinstance(instr.type, ArrayType) and instr.type.size > 0:
            size = instr.type.size * 8
            self.emit(f"    mov edi, {size}")
            self.emit("    call __builtin_alloc")
            self.emit(f"    mov {self._ref(instr.dest)}, rax")

    def gen_alloc_struct(self, instr: AllocStructInstr):
        if not self.is_global(instr.dest):
            self._get_stack_off(instr.dest)
        if instr.field_count > 0:
            self.emit(f"    mov edi, {instr.field_count * 8}")
            self.emit("    call __builtin_alloc")
            self.emit(f"    mov {self._ref(instr.dest)}, rax")

    def gen_alloc_array(self, instr: AllocArrayInstr):
        if not self.is_global(instr.dest):
            self._get_stack_off(instr.dest)
        if instr.size > 0:
            self.emit(f"    mov edi, {instr.size * 8}")
            self.emit("    call __builtin_alloc")
            self.emit(f"    mov {self._ref(instr.dest)}, rax")

    def gen_load(self, instr: LoadInstr):
        self.load_to_r10(instr.addr)
        self.store_from_r10(instr.dest)

    def gen_store(self, instr: StoreInstr):
        self.load_to_r10(instr.value)
        self.store_from_r10(instr.addr)

    def gen_load_field(self, instr: LoadFieldInstr):
        self.load_to_r10(instr.struct)
        fi = instr.field_index if instr.field_index >= 0 else 0
        self.emit(f"    mov r11, [r10 + {fi * 8}]")
        self.emit(f"    mov {self._ref(instr.dest)}, r11")

    def gen_store_field(self, instr: StoreFieldInstr):
        self.load_to_r10(instr.struct)
        self.emit(f"    mov r11, {self._ref(instr.value)}")
        fi = instr.field_index if instr.field_index >= 0 else 0
        self.emit(f"    mov [r10 + {fi * 8}], r11")

    def gen_load_index(self, instr: LoadIndexInstr):
        self.load_to_r10(instr.array)
        if self._is_string_var(instr.array):
            self.emit(f"    movzx r11, byte ptr [r10 + {instr.index}]")
        else:
            self.emit(f"    mov r11, [r10 + {instr.index * 8}]")
        self.emit(f"    mov {self._ref(instr.dest)}, r11")

    def gen_store_index(self, instr: StoreIndexInstr):
        self.load_to_r10(instr.array)
        self.emit(f"    mov r11, {self._ref(instr.value)}")
        if self._is_string_var(instr.array):
            self.emit(f"    mov [r10 + {instr.index}], r11b")
        else:
            self.emit(f"    mov [r10 + {instr.index * 8}], r11")

    def gen_load_index_var(self, instr: LoadIndexVarInstr):
        self.load_to_r10(instr.array)
        self.emit(f"    mov r11, {self._ref(instr.index_var)}")
        if self._is_string_var(instr.array):
            self.emit("    movzx r12, byte ptr [r10 + r11]")
        else:
            self.emit("    mov r12, [r10 + r11 * 8]")
        self.emit(f"    mov {self._ref(instr.dest)}, r12")

    def gen_store_index_var(self, instr: StoreIndexVarInstr):
        self.load_to_r10(instr.array)
        self.emit(f"    mov r11, {self._ref(instr.index_var)}")
        self.emit(f"    mov r12, {self._ref(instr.value)}")
        if self._is_string_var(instr.array):
            self.emit("    mov [r10 + r11], r12b")
        else:
            self.emit("    mov [r10 + r11 * 8], r12")

    def gen_branch(self, instr: BranchInstr):
        self.load_to_r10(instr.cond)
        self.emit("    cmp r10, 1")
        self.emit(f"    je  {instr.true_label}")
        self.emit(f"    jmp {instr.false_label}")

    def gen_jump(self, instr: JumpInstr):
        self.emit(f"    jmp {instr.label}")

    def gen_label(self, instr: LabelInstr):
        self.emit(f"{instr.label}:")

    def gen_make_enum(self, instr: MakeEnumInstr):
        if not self.is_global(instr.dest):
            self._get_stack_off(instr.dest)

    def gen_ref(self, instr: RefInstr):
        pass  # NOP for now

    def gen_phi(self, instr: PhiInstr):
        pass  # NOP for now

    # ------------------------------------------------------------------
    # Per-function codegen
    # ------------------------------------------------------------------

    def gen_function(self, func: FunctionDef):
        self.var_offsets = {}
        self.stack_size = 0

        # Function label
        if func.name == 'main':
            self.emit(".globl main")
            self.emit("main:")
        else:
            self.emit(f".globl {func.name}")
            self.emit(f"{func.name}:")

        # Prologue
        self.emit("    push rbp")
        self.emit("    mov rbp, rsp")

        # Collect ALL vars used in the function (excluding globals).
        # Use id(var) as key since IRVar.id is always 0 (bootstrap IRGen never sets it).
        local_vars: dict[int, IRVar] = {}
        for p in func.params:
            if not self.is_global(p):
                local_vars[id(p)] = p
        for blk in func.blocks:
            for instr in blk.instrs:
                for field_name in ['dest', 'value', 'addr', 'left', 'right', 'operand',
                                    'cond', 'struct', 'array', 'index_var']:
                    val = getattr(instr, field_name, None)
                    if isinstance(val, IRVar) and not self.is_global(val):
                        local_vars[id(val)] = val
                if hasattr(instr, 'args') and instr.args:
                    for a in instr.args:
                        if not self.is_global(a):
                            local_vars[id(a)] = a
                if hasattr(instr, 'choices') and instr.choices:
                    for choice_val, _ in instr.choices:
                        if isinstance(choice_val, IRVar) and not self.is_global(choice_val):
                            local_vars[id(choice_val)] = choice_val

        # Allocate params first, then remaining locals
        for p in func.params:
            if not self.is_global(p):
                self._get_stack_off(p)
        for v in local_vars.values():
            self._get_stack_off(v)

        if self.stack_size > 0:
            self.emit(f"    sub rsp, {self.stack_size}")

        # Save params from registers/stack to local variable slots
        param_regs = ['rdi', 'rsi', 'rdx', 'rcx', 'r8', 'r9']
        for i, p in enumerate(func.params):
            if i < 6:
                src = param_regs[i]
                self.emit(f"    mov {self._ref(p)}, {src}")
            else:
                # System V AMD64: 7th+ args are at [rbp + 16 + (i-6)*8]
                stack_off = 16 + (i - 6) * 8
                self.emit(f"    mov r10, [rbp + {stack_off}]")
                self.emit(f"    mov {self._ref(p)}, r10")

        # Generate code for all blocks (entry first, then others)
        blocks = [func.entry] if func.entry else []
        for blk in func.blocks:
            if blk != func.entry:
                blocks.append(blk)

        last_block_had_return = False
        for blk in blocks:
            if blk != func.entry:
                self.emit(f"{blk.name}:")
            for instr in blk.instrs:
                self.gen_instr(instr)
            # If block ends with a ReturnInstr, emit epilogue immediately
            # (otherwise execution would fall through to the next block)
            last_block_had_return = self._block_ends_with_return(blk)
            if last_block_had_return:
                self._emit_epilogue(func.name)

        # Only emit final epilogue if the last block didn't already return
        if not last_block_had_return:
            self._emit_epilogue(func.name)

        self.emit()

    def _emit_epilogue(self, func_name: str):
        if func_name == 'main':
            self.emit("    mov edi, eax")
            self.emit("    mov eax, 60")
            self.emit("    syscall")
        else:
            if self.stack_size > 0:
                self.emit(f"    add rsp, {self.stack_size}")
            self.emit("    pop rbp")
            self.emit("    ret")

    def _block_ends_with_return(self, blk: BasicBlock) -> bool:
        if not blk.instrs:
            return False
        return isinstance(blk.instrs[-1], ReturnInstr)

    def gen_instr(self, instr):
        if isinstance(instr, ConstInstr): self.gen_constant(instr)
        elif isinstance(instr, BinaryInstr): self.gen_binary(instr)
        elif isinstance(instr, UnaryInstr): self.gen_unary(instr)
        elif isinstance(instr, CallInstr): self.gen_call(instr)
        elif isinstance(instr, ReturnInstr): self.gen_return(instr)
        elif isinstance(instr, AllocInstr): self.gen_alloc(instr)
        elif isinstance(instr, AllocStructInstr): self.gen_alloc_struct(instr)
        elif isinstance(instr, AllocArrayInstr): self.gen_alloc_array(instr)
        elif isinstance(instr, LoadInstr): self.gen_load(instr)
        elif isinstance(instr, StoreInstr): self.gen_store(instr)
        elif isinstance(instr, LoadFieldInstr): self.gen_load_field(instr)
        elif isinstance(instr, StoreFieldInstr): self.gen_store_field(instr)
        elif isinstance(instr, LoadIndexInstr): self.gen_load_index(instr)
        elif isinstance(instr, StoreIndexInstr): self.gen_store_index(instr)
        elif isinstance(instr, LoadIndexVarInstr): self.gen_load_index_var(instr)
        elif isinstance(instr, StoreIndexVarInstr): self.gen_store_index_var(instr)
        elif isinstance(instr, BranchInstr): self.gen_branch(instr)
        elif isinstance(instr, JumpInstr): self.gen_jump(instr)
        elif isinstance(instr, LabelInstr): self.gen_label(instr)
        elif isinstance(instr, MakeEnumInstr): self.gen_make_enum(instr)
        elif isinstance(instr, RefInstr): self.gen_ref(instr)
        elif isinstance(instr, PhiInstr): self.gen_phi(instr)
        else:
            raise NotImplementedError(f"Unknown instruction: {type(instr)}")

    # ------------------------------------------------------------------
    # Main entry
    # ------------------------------------------------------------------

    def generate(self) -> str:
        self.lines = []
        self.str_labels = []
        self.str_map = {}

        self.emit(".intel_syntax noprefix")
        self.emit(".text")
        self.emit(".globl _start")
        self.emit()

        # Generate all functions
        for func in self.module.functions:
            self.gen_function(func)

        # String constants
        if self.str_labels:
            self.emit(".section .rodata")
            for lid, sval in self.str_labels:
                escaped = (sval
                           .replace('\\', '\\\\')
                           .replace('"', '\\"')
                           .replace('\n', '\\n')
                           .replace('\t', '\\t')
                           .replace('\0', '\\0'))
                self.emit(f'.LC{lid}: .asciz "{escaped}"')

        # Global variables in .data section
        # Collect unique global IRVars from the module
        global_vars: dict[str, IRVar] = {}
        for g in self.module.globals:
            if g.kind == VarKind.GLOBAL:
                global_vars[g.name] = g
        if global_vars:
            self.emit()
            self.emit(".section .data")
            for name, g in global_vars.items():
                lbl = self._global_label(name)
                cv = getattr(g, 'constant_value', None)
                if cv is not None:
                    self.emit(f"{lbl}: .quad {cv}")
                else:
                    self.emit(f"{lbl}: .quad 0")

        # Global initialization function — allocate heap memory for global arrays
        # (g_tokens, g_ir_vars, etc.) so they're not NULL when code accesses them.
        global_arrays = [g for g in self.module.globals
                         if g.kind == VarKind.GLOBAL and isinstance(g.type, ArrayType) and g.type.size]
        if global_arrays:
            self.emit()
            self.emit(".text")
            self.emit(".globl _init_globals")
            self.emit("_init_globals:")
            self.emit("    push rbp")
            self.emit("    mov rbp, rsp")
            for g in global_arrays:
                elem_size = self._elem_size(g.type.inner)
                size = g.type.size * elem_size
                self.emit(f"    mov edi, {size}")
                self.emit("    call __builtin_alloc")
                self.emit(f"    mov [rip+{self._global_label(g.name)}], rax")
            self.emit("    pop rbp")
            self.emit("    ret")
            self.emit()

        return '\n'.join(self.lines)
