#!/usr/bin/env python3
"""Test the self-hosted compiler written in Core.
This script:
1. Uses the Python bootstrap compiler to compile the Core compiler sources
2. Executes the Core compiler via the interpreter to compile test programs
"""
import sys
sys.path.insert(0, 'bootstrap')

from corec.frontend.lexer import Lexer as PyLexer
from corec.frontend.parser import Parser as PyParser
from corec.frontend.name_resolver import NameResolver
from corec.frontend.desugar import MatchDesugarer
from corec.frontend.type_checker import TypeChecker
from corec.frontend.ir_gen import IRGen
from corec.backend.interpreter import Interpreter
from corec.ir.coreir import *

def compile_core_source(src, name="test"):
    """Compile Core source using the Python bootstrap compiler and return the interpreter."""
    lex = PyLexer(src)
    tokens = lex.tokenize()
    ast = PyParser(tokens).parse_compilation_unit()
    resolver = NameResolver()
    resolver.resolve(ast)
    desugarer = MatchDesugarer(resolver.symtab)
    ast = desugarer.desugar(ast)
    checker = TypeChecker(resolver.symtab)
    checker.check(ast)
    if resolver.errors or checker.errors:
        print(f"  ERRORS: {resolver.errors + checker.errors}")
        return None
    ir_gen = IRGen(resolver.symtab)
    mod = ir_gen.gen_module(ast)
    interp = Interpreter(mod)
    return interp

def test_basic():
    """Basic test: compile and run a simple Core program."""
    src = '''
    fn add(a: int, b: int) -> int { return a + b; }
    fn main() -> int { return add(3, 4); }
    '''
    interp = compile_core_source(src)
    if interp:
        result = interp.run('main', [])
        print(f"  Result: {result}")
        assert result == 7, f"Expected 7, got {result}"
        print("  PASS")
    else:
        print("  FAIL: compilation errors")

def test_lexer_core():
    """Test that the core lexer source compiles."""
    with open('src/compiler/ast.core') as f:
        src = f.read()
    print(f"ast.core: {len(src)} chars")
    interp = compile_core_source(src, "ast.core")
    if interp:
        print("  ast.core compiles OK")
    else:
        print("  ast.core FAILED")

if __name__ == '__main__':
    print("=== Test Basic ===")
    test_basic()
    print("\n=== Test Lexer Core Source ===")
    test_lexer_core()
