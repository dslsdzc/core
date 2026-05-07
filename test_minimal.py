#!/usr/bin/env python3
"""Minimal test to find the struct declaration crash."""
import sys; sys.path.insert(0, 'bootstrap')

from corec.frontend.lexer import Lexer
from corec.frontend.parser import Parser
from corec.frontend.name_resolver import NameResolver
from corec.frontend.desugar import MatchDesugarer
from corec.frontend.type_checker import TypeChecker
from corec.frontend.ir_gen import IRGen
from corec.backend.interpreter import Interpreter
import bootstrap.corec.backend.interpreter as interp_mod

# Test: what if we only use the SELF-HOSTED compiler (compiled via bootstrap)
# and instrument the variables

# First, compile the self-hosted compiler
compiler_files = [
    'src/compiler/ast.core', 'src/compiler/lexer.core', 'src/compiler/parser.core',
    'src/compiler/checker.core', 'src/compiler/ir_gen.core',
    'src/compiler/backend/x86_64.core', 'src/compiler/main.core',
]

full_src = ""
for fpath in compiler_files:
    with open(fpath) as f:
        src = f.read()
    full_src += src + "\n"

# Add a function that reads globals and returns them as diagnostic string
diag_fn = '''
fn diag() -> string {
    let s = "g_struct_count=" + __builtin_int_to_str(g_struct_count) +
            " g_func_count=" + __builtin_int_to_str(g_func_count) +
            " g_str_count=" + __builtin_int_to_str(g_str_count) +
            " g_sym_count=" + __builtin_int_to_str(g_sym_count) +
            " g_type_count=" + __builtin_int_to_str(g_type_count);
    return s;
}
'''
full_src += diag_fn

# Parse and compile with bootstrap
lex = Lexer(full_src)
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
    sys.exit(1)
ir_gen = IRGen(resolver.symtab)
mod = ir_gen.gen_module(ast)
interp = Interpreter(mod)

print("Self-hosted compiler compiled OK")

# Test 1: struct + function, check globals after parse_all
test_src = '''
struct One { x: int }
fn main() {}
'''

# Run a custom sequence: set up source, run parse, then read globals
interp.run('diag', [])  # this will init globals and run diag
# But interp.run resets all globals. We need to run stages manually.
# Let's use the debug_compile approach but catch errors earlier

# Add a function that does parts of compile and reports
test_compile_fn = '''
fn test_compile(src: string) -> string {
    g_source = src;
    tokenize();
    parse_all();
    return diag();
}
'''
# We need to recompile with this function
full_src2 = full_src + test_compile_fn
lex2 = Lexer(full_src2)
tokens2 = lex2.tokenize()
ast2 = Parser(tokens2).parse_compilation_unit()
resolver2 = NameResolver()
resolver2.resolve(ast2)
desugarer2 = MatchDesugarer(resolver2.symtab)
ast2 = desugarer2.desugar(ast2)
checker2 = TypeChecker(resolver2.symtab)
checker2.check(ast2)
if resolver2.errors or checker2.errors:
    print(f"Recompile errors: {resolver2.errors + checker2.errors}")
    sys.exit(1)
ir_gen2 = IRGen(resolver2.symtab)
mod2 = ir_gen2.gen_module(ast2)
interp2 = Interpreter(mod2)

print("\nTest parse_all with struct:")
try:
    r = interp2.run('test_compile', [test_src])
    print(f"  Diag after parse_all: {r}")
except Exception as e:
    print(f"  CRASH: {e}")

# Now test check_all
test_compile2_fn = '''
fn test_compile2(src: string) -> string {
    g_source = src;
    tokenize();
    parse_all();
    let d1 = diag();
    check_all();
    let d2 = diag();
    return d1 + " | after_check: " + d2;
}
'''
full_src3 = full_src + test_compile2_fn
lex3 = Lexer(full_src3)
tokens3 = lex3.tokenize()
ast3 = Parser(tokens3).parse_compilation_unit()
resolver3 = NameResolver()
resolver3.resolve(ast3)
desugarer3 = MatchDesugarer(resolver3.symtab)
ast3 = desugarer3.desugar(ast3)
checker3 = TypeChecker(resolver3.symtab)
checker3.check(ast3)
if resolver3.errors or checker3.errors:
    print(f"Recompile errors: {resolver3.errors + checker3.errors}")
    sys.exit(1)
ir_gen3 = IRGen(resolver3.symtab)
mod3 = ir_gen3.gen_module(ast3)
interp3 = Interpreter(mod3)

print("\nTest check_all with struct:")
try:
    r = interp3.run('test_compile2', [test_src])
    print(f"  Result: {r}")
except Exception as e:
    print(f"  CRASH: {e}")
    import traceback; traceback.print_exc()
