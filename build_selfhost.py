#!/usr/bin/env python3
"""
Build the self-hosted Core compiler.
Concatenates all src/compiler/*.core files in dependency order,
then compiles the result through the Python bootstrap compiler.
"""
import sys, os
sys.path.insert(0, 'bootstrap')

def concat_sources():
    """Concatenate all compiler source files in order."""
    files = [
        'src/compiler/ast.core',
        'src/compiler/ir/nodes.core',
        'src/compiler/lexer.core',
        'src/compiler/parser.core',
        'src/compiler/checker.core',
        'src/compiler/ir_gen.core',
        'src/compiler/backend/x86_64.core',
        'src/compiler/main.core',
    ]
    parts = []
    for f in files:
        path = os.path.join(os.path.dirname(__file__), f)
        if os.path.exists(path):
            with open(path) as fh:
                content = fh.read().strip()
                if content:
                    parts.append(f"// === {f} ===\n{content}")
    return '\n\n'.join(parts)

def compile_and_run(src, entry='main', args=None):
    """Compile Core source and run via interpreter."""
    from corec.frontend.lexer import Lexer
    from corec.frontend.parser import Parser
    from corec.frontend.name_resolver import NameResolver
    from corec.frontend.desugar import MatchDesugarer
    from corec.frontend.type_checker import TypeChecker
    from corec.frontend.ir_gen import IRGen
    from corec.backend.interpreter import Interpreter

    if args is None:
        args = []
    lex = Lexer(src)
    tokens = lex.tokenize()
    ast = Parser(tokens).parse_compilation_unit()
    resolver = NameResolver()
    resolver.resolve(ast)
    desugarer = MatchDesugarer(resolver.symtab)
    ast = desugarer.desugar(ast)
    checker = TypeChecker(resolver.symtab)
    checker.check(ast)
    if resolver.errors:
        print(f"  Name resolution errors: {resolver.errors}")
        return None
    type_errors = checker.errors
    if type_errors:
        print(f"  Type checker warnings ({len(type_errors)}):")
        for e in type_errors[:5]:
            print(f"    {e}")
        if len(type_errors) > 5:
            print(f"    ... and {len(type_errors) - 5} more")
    ir_gen = IRGen(resolver.symtab)
    mod = ir_gen.gen_module(ast)
    interp = Interpreter(mod)
    return interp.run(entry, args)

if __name__ == '__main__':
    src = concat_sources()
    out_path = 'build/selfhost_compiler.core'
    os.makedirs('build', exist_ok=True)
    with open(out_path, 'w') as f:
        f.write(src)
    print(f"Concatenated source -> {out_path} ({len(src)} chars)")

    # Test: basic entry point
    result = compile_and_run(src, 'compiler_entry', [])
    if result is not None:
        print(f"compiler_entry() = {result!r}")
        print("Self-hosted compiler build: SUCCESS")
    else:
        print("Self-hosted compiler build: FAILED")
        sys.exit(1)
