#!/usr/bin/env python3
"""
Convert a bootstrap IR Module to .ccr binary format,
then compile with build/corearch for a fast native binary.

Usage: python3 tools/module_to_ccr.py <module_pickle> -o <output> --corearch <path>

Or used as a library:
  from tools.module_to_ccr import module_to_ccr
  binary = module_to_ccr(mod)
  with open('out.ccr', 'wb') as f: f.write(binary)
"""

import struct, sys, os

# Opcode constants matching self-hosted ast.cr
IR_NOP, IR_CONST, IR_BINARY, IR_UNARY, IR_CALL, IR_RETURN = range(0, 6)
IR_ALLOC, IR_ALLOC_STRUCT, IR_ALLOC_ARRAY = 6, 7, 8
IR_STORE, IR_LOAD = 9, 10
IR_LOAD_FIELD, IR_STORE_FIELD = 11, 12
IR_LOAD_INDEX, IR_STORE_INDEX = 13, 14
IR_LOAD_INDEX_VAR, IR_STORE_INDEX_VAR = 15, 16
IR_MAKE_ENUM = 17
IR_REF, IR_BRANCH, IR_JUMP, IR_LABEL = 18, 19, 20, 21
IR_PHI, IR_LOAD_ENUM_TAG, IR_SLICE, IR_DEREF, IR_STORE_PTR = 22, 23, 24, 25, 26

OPCODES = {
    'ConstInstr': IR_CONST, 'BinaryInstr': IR_BINARY, 'UnaryInstr': IR_UNARY,
    'CallInstr': IR_CALL, 'ReturnInstr': IR_RETURN,
    'AllocInstr': IR_ALLOC, 'AllocStructInstr': IR_ALLOC_STRUCT, 'AllocArrayInstr': IR_ALLOC_ARRAY,
    'LoadInstr': IR_LOAD, 'StoreInstr': IR_STORE,
    'LoadFieldInstr': IR_LOAD_FIELD, 'StoreFieldInstr': IR_STORE_FIELD,
    'LoadIndexInstr': IR_LOAD_INDEX, 'StoreIndexInstr': IR_STORE_INDEX,
    'LoadIndexVarInstr': IR_LOAD_INDEX_VAR, 'StoreIndexVarInstr': IR_STORE_INDEX_VAR,
    'MakeEnumInstr': IR_MAKE_ENUM,
    'RefInstr': IR_REF, 'BranchInstr': IR_BRANCH, 'JumpInstr': IR_JUMP,
    'LabelInstr': IR_LABEL, 'PhiInstr': IR_PHI,
    'LoadEnumTagInstr': IR_LOAD_ENUM_TAG, 'SliceInstr': IR_SLICE,
    'DerefInstr': IR_DEREF, 'StorePtrInstr': IR_STORE_PTR,
}

# Type kind constants matching self-hosted
TI_INT, TI_FLOAT, TI_BOOL, TI_STR, TI_UNIT, TI_NEVER = 0, 1, 2, 3, 4, 5


def type_to_ti(typ) -> int:
    """Convert a Python bootstrap type to type_kind int."""
    from corec.syntax.ast import BaseType, PathType, ArrayType, RefType
    if isinstance(typ, BaseType):
        m = {'int': TI_INT, 'float': TI_FLOAT, 'bool': TI_BOOL,
             'string': TI_STR, 'unit': TI_UNIT, 'never': TI_NEVER}
        return m.get(typ.name, TI_INT)
    return TI_INT  # default


def module_to_ccr(mod) -> bytes:
    """Convert a bootstrap Module to .ccr binary format."""
    # ── Step 1: Collect all strings ──
    str_table = {}
    str_list = []

    def intern(s: str) -> int:
        if s not in str_table:
            str_table[s] = len(str_list)
            str_list.append(s)
        return str_table[s]

    # ── Step 2: Collect all IR variables ──
    var_map = {}  # id(var) → index
    var_list = []

    def get_var_idx(var) -> int:
        if var is None:
            return -1
        vid = id(var)
        if vid not in var_map:
            var_map[vid] = len(var_list)
            var_list.append(var)
        return var_map[vid]

    # Pass 1: intern all strings and register all vars
    for func in mod.functions:
        intern(func.name)
        for p in func.params:
            intern(p.name)
            get_var_idx(p)
        for blk in func.blocks:
            intern(blk.name)
            for instr in blk.instrs:
                for attr in ['dest', 'value', 'addr', 'left', 'right', 'operand',
                             'cond', 'struct', 'array', 'index_var']:
                    val = getattr(instr, attr, None)
                    from corec.ir.base import IRVar
                    if isinstance(val, IRVar):
                        get_var_idx(val)
                if hasattr(instr, 'args') and instr.args:
                    for a in instr.args:
                        if isinstance(a, IRVar):
                            get_var_idx(a)
                if hasattr(instr, 'choices') and instr.choices:
                    for cv, _ in instr.choices:
                        if isinstance(cv, IRVar):
                            get_var_idx(cv)

    # ── Step 3: Build instruction list and compute per-function boundaries ──
    all_instrs = []  # list of (opcode, dest_idx, src1, src2, src3, type_kind)
    func_meta = []   # (name_idx, param_count, ret_type, instr_start, instr_count, var_start, var_count)

    for func in mod.functions:
        nidx = intern(func.name)
        param_count = len(func.params)
        ret_type = TI_INT
        # Determine return type from function's return annotation
        if hasattr(func, 'return_type'):
            from corec.syntax.ast import BaseType
            rt = func.return_type
            if isinstance(rt, BaseType):
                ret_type = type_to_ti(rt)
            elif rt is not None and hasattr(rt, 'name'):
                ret_type = TI_INT if rt.name in ('int', 'Int') else TI_INT

        var_start = len(var_list)  # first var index for this function
        for p in func.params:
            get_var_idx(p)  # ensure params are in var_list in order
        for blk in func.blocks:
            for instr in blk.instrs:
                for attr in ['dest', 'value', 'addr', 'left', 'right', 'operand',
                             'cond', 'struct', 'array', 'index_var']:
                    val = getattr(instr, attr, None)
                    from corec.ir.base import IRVar
                    if isinstance(val, IRVar):
                        get_var_idx(val)
                if hasattr(instr, 'args') and instr.args:
                    for a in instr.args:
                        if isinstance(a, IRVar):
                            get_var_idx(a)
        var_count = len(var_list) - var_start

        instr_start = len(all_instrs)
        instr_count = 0

        # Process blocks in order (entry first)
        blocks = [func.entry] if func.entry else []
        for blk in func.blocks:
            if blk != func.entry:
                blocks.append(blk)

        for bi, blk in enumerate(blocks):
            # Label instruction for each block after entry (self-hosted emits IR_LABEL)
            if bi > 0:
                lbl_idx = intern(blk.name)
                all_instrs.append((IR_LABEL, -1, lbl_idx, 0, 0, 0))
                instr_count += 1

            for instr in blk.instrs:
                clsname = type(instr).__name__
                op = OPCODES.get(clsname, IR_NOP)
                dest_idx = -1
                s1, s2, s3, tk = -1, 0, 0, TI_INT

                if hasattr(instr, 'dest') and instr.dest is not None:
                    dest_idx = get_var_idx(instr.dest)
                    tk = type_to_ti(instr.dest.type) if hasattr(instr.dest, 'type') else TI_INT

                if clsname == 'ConstInstr':
                    val = instr.value
                    if isinstance(val, bool): s1 = int(val)
                    elif isinstance(val, str): s1 = intern(val); tk = TI_STR
                    elif isinstance(val, float): s1 = int(val); tk = TI_FLOAT
                    else: s1 = int(val)
                elif clsname == 'BinaryInstr':
                    s1 = get_var_idx(instr.left)
                    s2 = get_var_idx(instr.right)
                    s3 = {'+': 0, '-': 1, '*': 2, '/': 3, '%': 4,
                          '==': 10, '!=': 11, '<': 12, '>': 13, '<=': 14, '>=': 15,
                          'and': 20, '&&': 20, 'or': 21, '||': 21, '=': 30}.get(instr.op, 0)
                elif clsname == 'UnaryInstr':
                    s1 = get_var_idx(instr.operand)
                    s3 = {'-': 0, 'not': 1, '!': 1}.get(instr.op, 0)
                elif clsname == 'CallInstr':
                    s1 = get_var_idx(instr.args[0]) if instr.args else -1
                    s2 = len(instr.args)
                    s3 = intern(instr.func) if instr.func else -1
                elif clsname == 'ReturnInstr':
                    if instr.value is not None: s1 = get_var_idx(instr.value)
                elif clsname in ('LoadInstr',):
                    s1 = get_var_idx(instr.addr)
                elif clsname == 'StoreInstr':
                    s1 = get_var_idx(instr.addr)
                    s2 = get_var_idx(instr.value) if hasattr(instr, 'value') else -1
                elif clsname == 'BranchInstr':
                    s1 = get_var_idx(instr.cond)
                    s2 = intern(instr.true_label)
                    s3 = intern(instr.false_label)
                elif clsname == 'JumpInstr':
                    s1 = intern(instr.label)
                elif clsname == 'AllocStructInstr':
                    s3 = intern(instr.struct_name) if instr.struct_name else -1
                elif clsname == 'AllocArrayInstr':
                    s1 = instr.size
                else:
                    pass  # NOP or other instructions

                all_instrs.append((op, dest_idx, s1, s2, s3, tk))
                instr_count += 1

        func_meta.append((nidx, param_count, ret_type, instr_start, instr_count, var_start, var_count))

    # ── Step 4: Collect global variables ──
    global_vars = [(intern(g.name), g) for g in mod.globals
                   if hasattr(g, 'kind') and str(g.kind) == 'VarKind.GLOBAL']

    # ── Step 5: Write binary ──
    out = bytearray()
    def w32(v): out.extend(struct.pack('<i', v))
    def wu32(v): out.extend(struct.pack('<I', v & 0xFFFFFFFF))

    # Header
    out.extend(b'CCR1')       # magic
    wu32(1)                   # version
    wu32(len(func_meta))      # func_count
    wu32(len(all_instrs))     # instr_count
    wu32(len(var_list))       # var_count
    wu32(len(str_list))       # str_count
    wu32(len(global_vars))    # str_const_count
    wu32(0)                   # struct_count (not needed for corearch)
    wu32(0)                   # enum_count

    # Strings
    for s in str_list:
        b = s.encode('utf-8')
        wu32(len(b))
        out.extend(b)

    # Function metadata: each entry 7 x u32 = 28 bytes
    for nm, pc, rt, istart, icnt, vstart, vcnt in func_meta:
        wu32(nm); wu32(pc); wu32(rt)
        wu32(istart); wu32(icnt)
        wu32(vstart); wu32(vcnt)

    # Instructions: each entry 6 x i32 = 24 bytes
    for op, dest, src1, src2, src3, tk in all_instrs:
        w32(op); w32(dest if dest >= 0 else -1)
        w32(src1 if src1 >= 0 else -1)
        w32(src2); w32(src3 if src3 >= 0 else -1)
        w32(tk)

    # Variables: each entry 3 x u32 = 12 bytes
    for var in var_list:
        name = var.name if hasattr(var, 'name') and var.name else ''
        wu32(intern(name))
        wu32(get_var_idx(var))  # id
        wu32(type_to_ti(var.type) if hasattr(var, 'type') else TI_INT)

    # String consts: each entry 1 x u32
    for ni, g in global_vars:
        wu32(ni)

    # Structs (approximate)
    for sname, sz in getattr(mod, 'struct_sizes', {}).items():
        wu32(intern(sname))
        wu32(sz // 8)  # field count

    return bytes(out)


def main():
    import argparse
    parser = argparse.ArgumentParser(description='Convert Module to .ccr')
    parser.add_argument('src', help='Core source file (.cr)')
    parser.add_argument('-o', '--output', default='out.ccr')
    parser.add_argument('--corearch', default='build/corearch',
                        help='Path to corearch backend')
    args = parser.parse_args()

    sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'bootstrap'))

    from corec.frontend.lexer import Lexer
    from corec.frontend.parser import Parser
    from corec.frontend.name_resolver import NameResolver
    from corec.frontend.desugar import MatchDesugarer
    from corec.frontend.type_checker import TypeChecker
    from corec.frontend.ir_gen import IRGen
    from corec.utils.module_loader import resolve_imports

    with open(args.src) as f:
        src = f.read()

    print(f"Tokenizing...")
    lex = Lexer(src)
    tokens = lex.tokenize()
    print(f"  {len(tokens)} tokens")

    print(f"Parsing...")
    ast = Parser(tokens).parse_compilation_unit()
    resolve_imports(ast)
    resolver = NameResolver()
    resolver.resolve(ast)
    desugarer = MatchDesugarer(resolver.symtab)
    ast = desugarer.desugar(ast)
    checker = TypeChecker(resolver.symtab)
    checker.check(ast)

    print(f"Generating IR...")
    ir_gen = IRGen(resolver.symtab)
    mod = ir_gen.gen_module(ast)
    print(f"  {len(mod.functions)} functions")

    print(f"Writing .ccr...")
    data = module_to_ccr(mod)
    with open(args.output, 'wb') as f:
        f.write(data)
    print(f"  {args.output}: {len(data)} bytes")

    if os.path.exists(args.corearch):
        print(f"Running corearch...")
        import subprocess
        result = subprocess.run([args.corearch, args.output], capture_output=True, text=True)
        print(result.stdout)
        if result.returncode != 0:
            print(f"corearch error: {result.stderr}")
            sys.exit(1)


if __name__ == '__main__':
    main()
