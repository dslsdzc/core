#!/usr/bin/env python3
"""Test impl blocks with methods in the self-hosted compiler."""
import sys, os, subprocess

sys.path.insert(0, 'bootstrap')

def concat_sources():
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
    result = interp.run('compile_source', [src_code])
    return result

def test_impl_basic():
    """Test struct with basic method using &self."""
    print("=== Test: struct with &self method ===")
    src = """
struct Point { x: int, y: int }

impl Point {
    fn get_x(&self) -> int {
        return self.x;
    }
}

fn main() -> int {
    let p = Point { x: 42, y: 100 };
    return p.get_x();
}
"""
    asm = compile_core_source(src)
    if asm is None:
        print("FAIL: compile_source returned None")
        return False
    if "check errors" in asm:
        print("FAIL: compile errors:", asm)
        return False
    print(f"Generated {len(asm)} bytes of assembly")
    # Assemble and run
    os.makedirs('build', exist_ok=True)
    with open('build/test_impl.s', 'w') as f:
        f.write(asm)
    r = subprocess.run(['as', '-o', 'build/test_impl.o', 'build/test_impl.s'],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print(f"Assembly failed: {r.stderr}")
        return False
    r = subprocess.run(['ld', '-o', 'build/test_impl', 'build/test_impl.o'],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print(f"Link failed: {r.stderr}")
        return False
    r = subprocess.run(['build/test_impl'], capture_output=True, text=True)
    print(f"Exit code: {r.returncode}")
    if r.returncode == 42:
        print("PASS: method call returned 42")
        return True
    else:
        print(f"FAIL: expected 42, got {r.returncode}")
        return False

def test_impl_mut_self():
    """Test struct with &mut self method."""
    print("\n=== Test: struct with &mut self method ===")
    src = """
struct Counter { val: int }

impl Counter {
    fn inc(&mut self) {
        self.val = self.val + 1;
    }
    fn get(&self) -> int {
        return self.val;
    }
}

fn main() -> int {
    let mut c = Counter { val: 5 };
    c.inc();
    c.inc();
    return c.get();
}
"""
    asm = compile_core_source(src)
    if asm is None:
        print("FAIL: compile_source returned None")
        return False
    if "check errors" in asm:
        print("FAIL: compile errors:", asm)
        return False
    os.makedirs('build', exist_ok=True)
    with open('build/test_impl2.s', 'w') as f:
        f.write(asm)
    r = subprocess.run(['as', '-o', 'build/test_impl2.o', 'build/test_impl2.s'],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print(f"Assembly failed: {r.stderr}")
        return False
    r = subprocess.run(['ld', '-o', 'build/test_impl2', 'build/test_impl2.o'],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print(f"Link failed: {r.stderr}")
        return False
    r = subprocess.run(['build/test_impl2'], capture_output=True, text=True)
    print(f"Exit code: {r.returncode}")
    if r.returncode == 7:
        print("PASS: &mut self method returned 7")
        return True
    else:
        print(f"FAIL: expected 7, got {r.returncode}")
        return False

# Run tests
results = []
results.append(test_impl_basic())
results.append(test_impl_mut_self())

print("\n=== Results ===")
for i, r in enumerate(results):
    print(f"  Test {i+1}: {'PASS' if r else 'FAIL'}")
print(f"Overall: {sum(results)}/{len(results)} passed")
