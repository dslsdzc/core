#!/usr/bin/env python3
"""
Self-compilation test: Use the Core self-hosted compiler to compile Core code.
Pipeline:
1. Load self-hosted compiler source (concatenated)
2. Call compile_source() on a test Core program
3. Get back x86-64 assembly
4. Assemble + link into native binary
5. Run the binary
"""
import sys, os, subprocess, tempfile

sys.path.insert(0, 'bootstrap')

def concat_sources():
    files = [
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

def compile_core_source(src_code):
    """Run Core source through the self-hosted compiler's compile_source()."""
    from corec.frontend.lexer import Lexer
    from corec.frontend.parser import Parser
    from corec.frontend.name_resolver import NameResolver
    from corec.frontend.desugar import MatchDesugarer
    from corec.frontend.type_checker import TypeChecker
    from corec.frontend.ir_gen import IRGen
    from corec.backend.interpreter import Interpreter

    compiler_src = concat_sources()

    lex = Lexer(compiler_src)
    tokens = lex.tokenize()
    ast = Parser(tokens).parse_compilation_unit()
    resolver = NameResolver()
    resolver.resolve(ast)
    desugarer = MatchDesugarer(resolver.symtab)
    ast = desugarer.desugar(ast)
    checker = TypeChecker(resolver.symtab)
    checker.check(ast)
    if resolver.errors:
        print("Resolver errors:", resolver.errors)
        return None
    if checker.errors:
        print("Checker errors:", checker.errors)
        return None

    ir_gen = IRGen(resolver.symtab)
    mod = ir_gen.gen_module(ast)
    interp = Interpreter(mod)

    # Call compile_source(test_src) on the self-hosted compiler
    result = interp.run('compile_source', [src_code])
    return result

# === Test: compile a minimal Core program ===
test_program = """
fn main() -> int {
    return 42;
}
"""

print("=== Self-compilation test ===")
print(f"Test program: {test_program.strip()}")

asm_output = compile_core_source(test_program)
if asm_output is None:
    print("FAILED: compile_source returned None")
    sys.exit(1)

print(f"\nGenerated {len(asm_output)} bytes of x86-64 assembly")
print("--- Assembly output ---")
print(asm_output)
print("--- End assembly ---")

# Save, assemble, link, and run
os.makedirs('build', exist_ok=True)
asm_path = 'build/test_output.s'
bin_path = 'build/test_output'
with open(asm_path, 'w') as f:
    f.write(asm_output)

print(f"\nAssembling with as...")
result = subprocess.run(['as', '-o', bin_path + '.o', asm_path], capture_output=True, text=True)
if result.returncode != 0:
    print(f"Assembly failed: {result.stderr}")
    sys.exit(1)

print(f"Linking with ld...")
result = subprocess.run(['ld', '-o', bin_path, bin_path + '.o'], capture_output=True, text=True)
if result.returncode != 0:
    print(f"Linking failed: {result.stderr}")
    sys.exit(1)

print(f"Running binary...")
result = subprocess.run([bin_path], capture_output=True, text=True)
print(f"Binary exit code: {result.returncode}")
print(f"stdout: {result.stdout}")
print(f"stderr: {result.stderr}")

if result.returncode == 42:
    print("\n✓ SELF-COMPILATION SUCCESS: Core compiler compiled Core code to working native binary!")
else:
    print(f"\nBinary returned {result.returncode}, expected 42")
