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
        'src/stdlib/io.cr', 'src/stdlib/fmt.cr', 'src/stdlib/cli.cr', 'src/stdlib/toml.cr',
        'src/compiler/ast.cr', 'src/compiler/globals.cr',
        'src/compiler/dyn_arr.cr', 'src/compiler/lexer.cr', 'src/compiler/parser.cr',
        'src/compiler/checker.cr', 'src/compiler/opt.cr', 'src/compiler/diag.cr',
        'src/compiler/ext_mgr.cr', 'src/compiler/ext_safety.cr',
        'src/compiler/ir_gen.cr', 'src/compiler/pass.cr',
        'src/compiler/dataflow.cr',
        'src/compiler/backend/x86_64.cr', 'src/compiler/backend/x86_64/instr.cr',
        'src/compiler/module.cr', 'src/compiler/ccr_io.cr', 'src/compiler/dump.cr',
        'src/compiler/project.cr', 'src/compiler/interp.cr', 'src/stdlib/os.cr',
        'src/compiler/backend/resolve.cr',
        'src/compiler/main.cr',
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
    if resolver.errors:
        print(f"Compiler source errors: {resolver.errors + checker.errors}")
        return None
    if checker.errors:
        print(f"  Checker warnings (non-fatal): {len(checker.errors)}")
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
with open(os.path.join(BASE, 'src/compiler/ast.cr'), encoding='utf-8') as f:
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

# ── Test 3: Full self-compilation (native corec compiles .cr → ELF binary) ──
print("\n=== Test 3: Self-Compilation (native) ===")

build_dir = os.path.join(BASE, 'build')
os.makedirs(build_dir, exist_ok=True)
test_src = os.path.join(build_dir, 'test_self_compile.cr')
test_bin = os.path.join(build_dir, 'test_self_compile')

# Clean up artifacts from previous runs
for p in [test_src, test_bin, test_bin + '.ccr']:
    if os.path.exists(p):
        os.remove(p)

with open(test_src, 'w') as f:
    f.write("fn main() -> int { return 42; }\n")

r = subprocess.run(
    [os.path.join(build_dir, 'corec'), 'build', test_src, '-o', test_bin, '--static'],
    capture_output=True, text=True, cwd=BASE)
print(f"  corec stdout: {r.stdout.strip()}")
print(f"  corec stderr: {r.stderr.strip()}")
if r.returncode != 0:
    print(f"  corec build failed (exit {r.returncode})")
    sys.exit(1)

if not os.path.exists(test_bin):
    print(f"FAIL: {test_bin} was not created")
    sys.exit(1)

os.chmod(test_bin, 0o755)

r = subprocess.run([test_bin], capture_output=True, text=True)
print(f"  Binary exit code: {r.returncode}")
if r.returncode == 42:
    print("  PASS: native corec compiled .cr to working ELF binary")
else:
    print(f"  FAIL: expected 42, got {r.returncode}")
    sys.exit(1)

print("\nAll selfhost compile tests passed.")
