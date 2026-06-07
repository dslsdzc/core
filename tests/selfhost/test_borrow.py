#!/usr/bin/env python3
"""Self-hosted borrow checker tests — runs checker.cr borrow logic through the interpreter."""
import sys, os
sys.path.insert(0, 'bootstrap')

BASE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from corec.frontend.lexer import Lexer
from corec.frontend.parser import Parser
from corec.frontend.name_resolver import NameResolver
from corec.frontend.desugar import MatchDesugarer
from corec.frontend.type_checker import TypeChecker
from corec.frontend.ir_gen import IRGen
from corec.backend.interpreter import Interpreter


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
        with open(path) as fh:
            content = fh.read().strip()
            if content:
                parts.append(content)
    return '\n\n'.join(parts)


print("Loading self-hosted compiler...")
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
if checker.errors:
    print(f"Self-hosted compiler source has type errors: {checker.errors}")
    sys.exit(1)
print(f"  {len(tokens)} tokens, {len(checker.errors)} errors")

ir_gen = IRGen(resolver.symtab)
mod = ir_gen.gen_module(ast)
interp = Interpreter(mod)


def compile_and_check(source, expect_error, description):
    try:
        result = interp.run('compile_source', [source])
        has_error = result and "check errors" in str(result)
    except Exception as e:
        has_error = True

    matched = (has_error == expect_error)
    status = "[PASS]" if matched else "[FAIL]"
    detail = "error" if has_error else "no errors"
    print(f"  {status} {description}: {detail}")
    return matched


tests = [
    # Note: borrow checking is not yet active in the self-hosted checker.
    # These tests validate current checker behavior; expected_error is False
    # for all until borrow rules are enforced.

    ('''
fn test() -> int {
    x := 42; r := &x; y := x; return y;
}
''', False, "immutable borrow then use original (not yet enforced)"),

    ('''
fn test() -> int {
    x := 42; r := &mut x; y := x; return y;
}
''', False, "mut borrow then use original (not yet enforced)"),

    ('''
fn test() -> int {
    x := 42; r1 := &x; r2 := &x;
    __builtin_str_len(""); return 0;
}
''', False, "multiple immutable borrows allowed"),

    ('''
fn test() -> int {
    x := 42; r1 := &x; r2 := &mut x;
    __builtin_str_len(""); return 0;
}
''', False, "immutable then mutable borrow (not yet enforced)"),

    ('''
fn test() -> int {
    x := 42;
    { r := &x; __builtin_str_len(""); }
    y := x; return y;
}
''', False, "borrow released after block scope exit"),

    ('''
fn test() -> int { x := 42; y := x; return y; }
''', False, "normal copy use (no borrow)"),

    ('''
fn test() -> int {
    x : ., mut = 42; r1 := &mut x; r2 := &x;
    __builtin_str_len(""); return 0;
}
''', False, "mutable then immutable borrow (not yet enforced)"),
]

print("\nSelf-hosted Borrow Checker Tests")
print("=" * 60)

passed = 0
failed = 0
for source, expect_error, desc in tests:
    if compile_and_check(source, expect_error, desc):
        passed += 1
    else:
        failed += 1

print(f"\n{passed}/{passed + failed} passed", end="")
if failed > 0:
    print(f", {failed} failed")
    sys.exit(1)
else:
    print()
