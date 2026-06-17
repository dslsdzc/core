#!/usr/bin/env python3
"""
Build Core standard library as a shared library (.so).
Output: ~/.core/lib/core_rt.so

Pipeline: concatenate rt.cr + stdlib/*.cr, compile through bootstrap,
emit as position-independent shared library.
"""
import sys, os, subprocess

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', 'bootstrap'))
BASE = os.path.dirname(os.path.dirname(__file__))

def concat_stdlib():
    """Concatenate runtime + stdlib into a single compilation unit."""
    parts = []
    files = [
        'src/runtime/rt.cr',
        'src/stdlib/io.cr',
        'src/stdlib/math.cr',
        'src/stdlib/collections.cr',
        'src/runtime/rt.cr',  # dummy to keep concat_fast happy
    ]
    for f in files:
        path = os.path.join(BASE, f)
        if os.path.exists(path):
            with open(path) as fh:
                c = fh.read().strip()
                if c:
                    parts.append(f'// === {f} ===\n{c}')
    return '\n\n'.join(parts)

def main():
    from corec.frontend.lexer import Lexer
    from corec.frontend.parser import Parser
    from corec.frontend.name_resolver import NameResolver
    from corec.frontend.desugar import MatchDesugarer
    from corec.frontend.type_checker import TypeChecker
    from corec.frontend.ir_gen import IRGen
    from corec.backend.x86_64_stack_asm import X86_64StackAsmGen
    from corec.utils.module_loader import resolve_imports

    src = concat_stdlib()
    print(f"stdlib: {len(src)} bytes")

    lex = Lexer(src)
    tokens = lex.tokenize()
    print(f"  tokens: {len(tokens)}")

    ast = Parser(tokens).parse_compilation_unit()
    resolver = NameResolver()
    resolver.resolve(ast)
    desugarer = MatchDesugarer(resolver.symtab)
    ast = desugarer.desugar(ast)
    checker = TypeChecker(resolver.symtab)
    checker.check(ast)
    if checker.errors:
        print(f"  warnings: {len(checker.errors)}")

    ir_gen = IRGen(resolver.symtab)
    mod = ir_gen.gen_module(ast)
    print(f"  functions: {len(mod.functions)}")

    asm_gen = X86_64StackAsmGen(mod)
    asm = asm_gen.generate()
    print(f"  assembly: {len(asm)} bytes")

    # Assemble .s → .o → .so
    os.makedirs(os.path.join(BASE, 'build'), exist_ok=True)
    asm_path = os.path.join(BASE, 'build', 'core_rt.s')
    obj_path = asm_path.replace('.s', '.o')
    so_path = os.path.join(BASE, 'build', 'core_rt.so')

    with open(asm_path, 'w') as f:
        f.write(asm)

    # Assemble
    r = subprocess.run(['as', '-o', obj_path, asm_path], capture_output=True, text=True)
    if r.returncode != 0:
        print(f"  assembly failed: {r.stderr}")
        sys.exit(1)

    # Link as shared library
    r = subprocess.run(['ld', '-shared', '-o', so_path, obj_path], capture_output=True, text=True)
    if r.returncode != 0:
        print(f"  link failed: {r.stderr}")
        sys.exit(1)

    # Install to ~/.core/lib/
    lib_dir = os.path.expanduser('~/.core/lib')
    os.makedirs(lib_dir, exist_ok=True)
    import shutil
    shutil.copy2(so_path, os.path.join(lib_dir, 'core_rt.so'))

    print(f"  -> {lib_dir}/core_rt.so")
    print("done")

if __name__ == '__main__':
    main()
