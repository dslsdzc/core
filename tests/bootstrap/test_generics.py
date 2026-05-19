#!/usr/bin/env python3
"""Generic function and struct tests through the bootstrap pipeline."""
import sys
sys.path.insert(0, 'bootstrap')

from corec.frontend.lexer import Lexer
from corec.frontend.parser import Parser
from corec.frontend.name_resolver import NameResolver
from corec.frontend.desugar import MatchDesugarer
from corec.frontend.type_checker import TypeChecker
from corec.frontend.ir_gen import IRGen
from corec.backend.interpreter import Interpreter


def run_test(name, src, expected):
    try:
        lex = Lexer(src)
        ast = Parser(lex.tokenize()).parse_compilation_unit()
        resolver = NameResolver()
        resolver.resolve(ast)
        desugarer = MatchDesugarer(resolver.symtab)
        ast = desugarer.desugar(ast)
        checker = TypeChecker(resolver.symtab)
        checker.check(ast)
        if checker.errors:
            print(f"[FAIL] {name}: type errors={checker.errors}")
            return False
        ir_gen = IRGen(resolver.symtab)
        mod = ir_gen.gen_module(ast)
        interp = Interpreter(mod)
        result = interp.run('main', [])
        if result == expected:
            print(f"[PASS] {name}: got {result}")
            return True
        else:
            print(f"[FAIL] {name}: expected {expected}, got {result}")
            return False
    except Exception as e:
        print(f"[ERROR] {name}: {e}")
        import traceback; traceback.print_exc()
        return False


passed = 0
failed = 0

# Generic function
if run_test('Generic Identity', '''
fn identity[T](val: T) -> T { return val; }
fn main() -> int { x := identity(42); return x; }
''', 42):
    passed += 1
else:
    failed += 1

# Generic struct
if run_test('Generic Struct Box', '''
struct Box[T] { value: T }
fn get_value[T](b: Box[T]) -> T { return b.value; }
fn main() -> int {
    boxed := Box { value = 100 };
    return get_value(boxed);
}
''', 100):
    passed += 1
else:
    failed += 1

print(f"\n{passed}/{passed + failed} passed", end="")
if failed > 0:
    print(f", {failed} failed")
    sys.exit(1)
else:
    print()
