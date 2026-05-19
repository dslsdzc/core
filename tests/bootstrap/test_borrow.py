#!/usr/bin/env python3
"""Borrow checker tests — verifies that the type checker rejects invalid borrow patterns."""
import sys
sys.path.insert(0, 'bootstrap')

from corec.frontend.lexer import Lexer
from corec.frontend.parser import Parser
from corec.frontend.name_resolver import NameResolver
from corec.frontend.desugar import MatchDesugarer
from corec.frontend.type_checker import TypeChecker


def check_errors(src, desc, expect_errors):
    """Run source through type checker and verify borrow error count."""
    lex = Lexer(src)
    ast = Parser(lex.tokenize()).parse_compilation_unit()
    resolver = NameResolver()
    resolver.resolve(ast)
    desugarer = MatchDesugarer(resolver.symtab)
    ast = desugarer.desugar(ast)
    checker = TypeChecker(resolver.symtab)
    checker.check(ast)
    has_errors = len(checker.errors) > 0
    if has_errors == expect_errors:
        print(f"[PASS] {desc}")
        return True
    else:
        print(f"[FAIL] {desc}: expected_errors={expect_errors}, got {checker.errors}")
        return False


passed = 0
failed = 0

def test(src, desc, expect_errors):
    global passed, failed
    if check_errors(src, desc, expect_errors):
        passed += 1
    else:
        failed += 1


# Immutable borrow should prevent use of original
test('''
fn main() -> int {
    x := 10;
    r := &x;
    return x;
}
''', 'immutable borrow then use original', True)

# Mutable borrow should prevent use of original
test('''
fn main() -> int {
    x : ., mut = 10;
    rm := &mut x;
    return x;
}
''', 'mut borrow then use original', True)

# Multiple immutable borrows are allowed
test('''
fn main() -> int {
    x := 10;
    r1 := &x;
    r2 := &x;
    return *r1 + *r2;
}
''', 'multiple immutable borrows allowed', False)

# Immutable borrow then mutable borrow should fail
test('''
fn main() -> int {
    x : ., mut = 10;
    r1 := &x;
    r2 := &mut x;
    return 0;
}
''', 'immutable then mutable borrow forbidden', True)

print(f"\n{passed}/{passed + failed} passed", end="")
if failed > 0:
    print(f", {failed} failed")
    sys.exit(1)
else:
    print()
