#!/usr/bin/env python3
"""
Build native x86-64 binaries of the self-hosted Core compiler.

Produces two binaries:
  build/corec      — frontend: .cr → .ccr/.cir
  build/corearch   — backend:  .ccr → binary/asm

Pipeline (fast path — no interpreter bottleneck, no gcc dependency):
1. Concatenate sources for each binary
2. Run through bootstrap Lexer → Parser → NameResolver → TypeChecker → IRGen
3. Generate x86-64 assembly via X86_64StackAsmGen
4. Assemble + link with rt.s using as + ld
"""
import sys, os, subprocess

sys.path.insert(0, 'bootstrap')

BASE = os.path.dirname(__file__)


def concat(files, wrapper_fn=None):
    """Concatenate .cr files, optionally appending a main wrapper."""
    parts = []
    for f in files:
        path = os.path.join(BASE, f)
        if os.path.exists(path):
            with open(path) as fh:
                content = fh.read().strip()
                if content:
                    parts.append(f"// === {f} ===\n{content}")
    src = '\n\n'.join(parts)
    if wrapper_fn:
        src += f'\n\nfn main() -> int {{ return {wrapper_fn}(); }}\n'
    return src


def compile_and_assemble(src, label, out_name):
    """Run full pipeline on src, produce binary at build/{out_name}."""
    from corec.frontend.lexer import Lexer
    from corec.frontend.parser import Parser
    from corec.frontend.name_resolver import NameResolver
    from corec.frontend.desugar import MatchDesugarer
    from corec.frontend.type_checker import TypeChecker
    from corec.frontend.ir_gen import IRGen
    from corec.backend.x86_64_stack_asm import X86_64StackAsmGen
    from corec.utils.module_loader import resolve_imports

    print(f"--- {label} ---")

    lex = Lexer(src)
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
        print("  Errors:", resolver.errors)
        sys.exit(1)
    if checker.errors:
        print("  Checker warnings (non-fatal):", checker.errors)
    print("  Type check passed")

    ir_gen = IRGen(resolver.symtab)
    mod = ir_gen.gen_module(ast)
    print(f"  Functions: {len(mod.functions)}")

    asm_gen = X86_64StackAsmGen(mod)
    asm = asm_gen.generate()
    print(f"  Assembly: {len(asm)} bytes")

    os.makedirs('build', exist_ok=True)
    asm_path = f'build/{out_name}.s'
    with open(asm_path, 'w') as f:
        f.write(asm)

    result = subprocess.run(['as', '-o', f'build/{out_name}.o', asm_path],
                            capture_output=True, text=True)
    if result.returncode != 0:
        print(f"  Assembly failed: {result.stderr}")
        sys.exit(1)

    result = subprocess.run(['ld', '-o', f'build/{out_name}',
                             f'build/{out_name}.o', 'build/runtime.o'],
                            capture_output=True, text=True)
    if result.returncode != 0:
        print(f"  Link failed: {result.stderr}")
        sys.exit(1)

    print(f"  -> build/{out_name}")
    print()


def build_runtime():
    """Build the shared runtime .o once."""
    print("--- Runtime (rt.s) ---")
    result = subprocess.run(['as', '-o', 'build/runtime.o', 'src/runtime/rt.s'],
                            capture_output=True, text=True)
    if result.returncode != 0:
        print(f"  Assembly failed: {result.stderr}")
        sys.exit(1)
    print("  -> build/runtime.o\n")


def main():
    print("=== Building Core native binaries ===\n")

    build_runtime()

    # corec — frontend: .cr → .ccr/.cir
    compile_and_assemble(
        concat([
            'src/runtime/rt.cr',
            'src/stdlib/io.cr',
            'src/stdlib/fmt.cr',
            'src/stdlib/cli.cr',
            'src/compiler/ast.cr',
            'src/compiler/globals.cr',
            'src/compiler/dyn_arr.cr',
            'src/compiler/lexer.cr',
            'src/compiler/parser.cr',
            'src/compiler/checker.cr',
            'src/compiler/opt.cr',
            'src/compiler/diag.cr',
            'src/compiler/ext_mgr.cr',
            'src/compiler/ext_safety.cr',
            'src/compiler/ir_gen.cr',
            'src/compiler/pass.cr',
            'src/compiler/dataflow.cr',
            'src/compiler/ccr_io.cr',
            'src/compiler/module.cr',
            'src/stdlib/toml.cr',
            'src/compiler/project.cr',
            'src/stdlib/os.cr',
            'src/compiler/interp.cr',
            'src/compiler/dump.cr',
            'src/compiler/main.cr',
        ], wrapper_fn='compiler_main'),
        label='corec',
        out_name='corec',
    )

    # corearch — backend: .ccr → binary/asm
    compile_and_assemble(
        concat([
            'src/runtime/rt.cr',
            'src/stdlib/io.cr',
            'src/stdlib/fmt.cr',
            'src/stdlib/cli.cr',
            'src/stdlib/toml.cr',
            'src/compiler/ast.cr',
            'src/compiler/globals.cr',
            'src/compiler/dyn_arr.cr',
            'src/arch/linux/ld/sizes.cr',
            'src/arch/linux/ld/instr.cr',
            'src/arch/linux/ld/elf.cr',
            'src/arch/linux/ld/ld.cr',
            'src/compiler/ccr_io.cr',
            'src/compiler/corearch.cr',
        ], wrapper_fn='corearch_main'),
        label='corearch',
        out_name='corearch',
    )

    print("=== BUILD SUCCESS ===")
    print("  build/corec     — frontend:  .cr → .ccr/.cir")
    print("  build/corearch  — backend:   .ccr → binary")


if __name__ == '__main__':
    main()
