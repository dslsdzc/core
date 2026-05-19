#!/usr/bin/env python3
"""
Build a native x86-64 binary of the self-hosted Core compiler.

Pipeline (fast path — no interpreter bottleneck, no gcc dependency):
1. Concatenate rt.core + all self-hosted compiler source files
2. Run through bootstrap Lexer → Parser → NameResolver → TypeChecker → IRGen (all Python, fast)
3. Generate x86-64 assembly directly via X86_64StackAsmGen (Python, not interpreted Core)
4. Assemble + link into standalone native binary using as + ld only
"""
import sys, os, subprocess

sys.path.insert(0, 'bootstrap')


def concat_sources():
    # rt.core first to provide all __builtin_* implementations
    files = [
        'src/runtime/rt.core',
        'src/compiler/ast.core',
        'src/compiler/lexer.core',
        'src/compiler/parser.core',
        'src/compiler/checker.core',
        'src/compiler/ir_gen.core',
        'src/compiler/backend/x86_64.core',
        'src/compiler/main.core',
    ]
    parts = []
    base = os.path.dirname(__file__)
    for f in files:
        path = os.path.join(base, f)
        if os.path.exists(path):
            with open(path) as fh:
                content = fh.read().strip()
                if content:
                    parts.append(f"// === {f} ===\n{content}")
    return '\n\n'.join(parts)


def main():
    print("=== Building native self-hosted Core compiler ===\n")

    # Step 1: Concatenate runtime + compiler source
    print("Step 1: Concatenating sources...")
    compiler_src = concat_sources()
    # Add main wrapper that calls compiler_main (rt.s _start calls main)
    compiler_src += '\n\nfn main() -> int { return compiler_main(); }\n'
    print(f"  Total size: {len(compiler_src)} bytes\n")

    # Step 2: Load compiler into bootstrap pipeline (Python-speed)
    print("Step 2: Loading compiler into bootstrap pipeline...")
    from corec.frontend.lexer import Lexer
    from corec.frontend.parser import Parser
    from corec.frontend.name_resolver import NameResolver
    from corec.frontend.desugar import MatchDesugarer
    from corec.frontend.type_checker import TypeChecker
    from corec.frontend.ir_gen import IRGen
    from corec.backend.x86_64_stack_asm import X86_64StackAsmGen
    from corec.utils.module_loader import resolve_imports

    lex = Lexer(compiler_src)
    tokens = lex.tokenize()
    print(f"  Tokens: {len(tokens)}")
    ast = Parser(tokens).parse_compilation_unit()
    resolve_imports(ast)
    resolver = NameResolver()
    resolver.resolve(ast)
    desugarer = MatchDesugarer(resolver.symtab)
    ast = desugarer.desugar(ast)
    checker = TypeChecker(resolver.symtab)
    checker.check(ast)
    if resolver.errors:
        print("  Resolver errors:", resolver.errors)
        sys.exit(1)
    if checker.errors:
        print("  Checker errors:", checker.errors)
        sys.exit(1)
    print("  Type check passed\n")

    # Step 3: Generate IR (Python-speed)
    print("Step 3: Generating IR...")
    ir_gen = IRGen(resolver.symtab)
    mod = ir_gen.gen_module(ast)
    print(f"  Functions: {len(mod.functions)}\n")

    # Step 4: Generate x86-64 assembly directly (Python-speed, not interpreted Core)
    print("Step 4: Generating x86-64 assembly...")
    asm_gen = X86_64StackAsmGen(mod)
    asm_output = asm_gen.generate()
    print(f"  Generated {len(asm_output)} bytes of assembly\n")

    # Step 5: Write assembly
    print("Step 5: Writing assembly...")
    os.makedirs('build', exist_ok=True)
    asm_path = 'build/compiler.s'
    with open(asm_path, 'w') as f:
        f.write(asm_output)
    print(f"  Written to {asm_path}\n")

    # Step 6: Assemble compiler with as
    print("Step 6: Assembling compiler...")
    result = subprocess.run(['as', '-o', 'build/compiler.o', asm_path],
                            capture_output=True, text=True)
    if result.returncode != 0:
        print(f"  Assembly failed: {result.stderr}")
        sys.exit(1)
    print("  OK\n")

    # Step 7: Assemble assembly runtime (rt.s)
    print("Step 7: Assembling runtime (rt.s)...")
    result = subprocess.run(['as', '-o', 'build/runtime.o',
                             'src/runtime/rt.s'],
                            capture_output=True, text=True)
    if result.returncode != 0:
        print(f"  Assembly failed: {result.stderr}")
        sys.exit(1)
    print("  OK\n")

    # Step 8: Link native binary (no gcc!)
    print("Step 8: Linking native binary...")
    result = subprocess.run(['ld', '-o', 'build/corec',
                              'build/compiler.o', 'build/runtime.o'],
                            capture_output=True, text=True)
    if result.returncode != 0:
        print(f"  Linking failed: {result.stderr}")
        sys.exit(1)
    print("  OK\n")

    print("=== BUILD SUCCESS ===")
    print(f"Native compiler binary: build/corec")
    print(f"Usage: ./build/corec <input.core>")
    print(f"  → compiles input.core → output.s")


if __name__ == '__main__':
    main()
