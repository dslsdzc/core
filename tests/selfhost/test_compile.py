#!/usr/bin/env python3
"""Self-hosted compiler compilation tests — load compiler source, compile through bootstrap, run via interpreter."""
import sys, os, subprocess
sys.path.insert(0, 'bootstrap')

from corec.frontend.lexer import Lexer
from corec.frontend.parser import Parser
from corec.frontend.name_resolver import NameResolver
from corec.frontend.desugar import MatchDesugarer
from corec.frontend.type_checker import TypeChecker
from corec.frontend.ir_gen import IRGen
from corec.backend.interpreter import Interpreter

BASE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def concat_sources():
    files = [
        'src/stdlib/cli.cr', 'src/stdlib/toml.cr', 'src/compiler/ast.cr', 'src/compiler/globals.cr',
        'src/compiler/lexer.cr', 'src/compiler/parser.cr',
        'src/compiler/checker.cr', 'src/compiler/ir_gen.cr', 'src/compiler/dataflow.cr',
        'src/compiler/backend/x86_64.cr', 'src/compiler/ccr_io.cr', 'src/compiler/project.cr', 'src/compiler/interp.cr', 'src/compiler/main.cr',
    ]
    parts = []
    for f in files:
        path = os.path.join(BASE, f)
        if os.path.exists(path):
            with open(path) as fh:
                content = fh.read().strip()
                if content:
                    parts.append(content)
    return '\n\n'.join(parts)


def compile_selfhost():
    """Load self-hosted compiler source and compile through bootstrap pipeline. Returns Interpreter."""
    src = concat_sources()
    lex = Lexer(src)
    tokens = lex.tokenize()
    ast = Parser(tokens).parse_compilation_unit()
    resolver = NameResolver()
    resolver.resolve(ast)
    desugarer = MatchDesugarer(resolver.symtab)
    ast = desugarer.desugar(ast)
    checker = TypeChecker(resolver.symtab)
    checker.check(ast)
    if resolver.errors or checker.errors:
        print(f"Compiler source errors: {resolver.errors + checker.errors}")
        return None
    ir_gen = IRGen(resolver.symtab)
    mod = ir_gen.gen_module(ast)
    return Interpreter(mod), len(tokens)


# ── Test 1: Basic interpreter run ──
print("=== Test 1: Basic Interpreter Run ===")
src1 = '''
fn add(a: int, b: int) -> int { return a + b; }
fn main() -> int { return add(3, 4); }
'''
lex = Lexer(src1)
ast = Parser(lex.tokenize()).parse_compilation_unit()
resolver = NameResolver()
resolver.resolve(ast)
desugarer = MatchDesugarer(resolver.symtab)
ast = desugarer.desugar(ast)
checker = TypeChecker(resolver.symtab)
checker.check(ast)
ir_gen = IRGen(resolver.symtab)
mod = ir_gen.gen_module(ast)
interp = Interpreter(mod)
result = interp.run('main', [])
print(f"  Result: {result}")
assert result == 7, f"Expected 7, got {result}"
print("  PASS")

# ── Test 2: Compile self-hosted compiler + test lexer source ──
print("\n=== Test 2: Self-Hosted Compiler Lexer Source ===")
with open(os.path.join(BASE, 'src/compiler/ast.cr')) as f:
    ast_src = f.read()
print(f"  ast.cr: {len(ast_src)} chars")
result = compile_selfhost()
if result:
    interp2, tok_count = result
    print(f"  Self-hosted compiler: {tok_count} tokens, compiled OK")
    print("  PASS")
else:
    print("  FAIL")
    sys.exit(1)

# ── Test 3: Full self-compilation (Core compiler compiles Core → native binary) ──
print("\n=== Test 3: Self-Compilation ===")
test_program = "fn main() -> int {\n    return 42;\n}\n"

result = compile_selfhost()
if not result:
    print("FAIL: could not compile self-hosted compiler")
    sys.exit(1)
interp3, _ = result

asm_output = interp3.run('compile_source', [test_program])
if asm_output is None:
    print("FAIL: compile_source returned None")
    sys.exit(1)

print(f"  Generated {len(asm_output)} bytes of assembly")

build_dir = os.path.join(BASE, 'build')
os.makedirs(build_dir, exist_ok=True)
asm_path = os.path.join(build_dir, 'test_self_compile.s')
bin_path = os.path.join(build_dir, 'test_self_compile')

with open(asm_path, 'w') as f:
    f.write(asm_output)

r = subprocess.run(['as', '-o', bin_path + '.o', asm_path], capture_output=True, text=True)
if r.returncode != 0:
    print(f"Assembly failed: {r.stderr}")
    sys.exit(1)

# Assemble runtime and link into binary (provides _start, __builtin_alloc, etc.)
rt_s = os.path.join(BASE, 'src/runtime/rt.s')
rt_o = bin_path + '_rt.o'
r = subprocess.run(['as', '-o', rt_o, rt_s], capture_output=True, text=True)
if r.returncode != 0:
    print(f"Runtime assembly failed: {r.stderr}")
    sys.exit(1)

r = subprocess.run(['ld', '-o', bin_path, bin_path + '.o', rt_o], capture_output=True, text=True)
if r.returncode != 0:
    print(f"Link failed: {r.stderr}")
    sys.exit(1)

r = subprocess.run([bin_path], capture_output=True, text=True)
print(f"  Binary exit code: {r.returncode}")
if r.returncode == 42:
    print("  PASS: Core compiler compiled Core code to working native binary")
else:
    print(f"  FAIL: expected 42, got {r.returncode}")
    sys.exit(1)

print("\nAll selfhost compile tests passed.")
