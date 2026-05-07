#!/usr/bin/env python3
"""Test impl blocks through self-hosted compiler - incremental complexity."""
import sys; sys.path.insert(0, 'bootstrap')

from corec.frontend.lexer import Lexer
from corec.frontend.parser import Parser
from corec.frontend.name_resolver import NameResolver
from corec.frontend.desugar import MatchDesugarer
from corec.frontend.type_checker import TypeChecker
from corec.frontend.ir_gen import IRGen
from corec.backend.interpreter import Interpreter

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

test_fns = '''
fn test_check(src: string) -> string {
    g_source = src;
    tokenize();
    parse_all();
    check_all();
    if g_check_error_count > 0 {
        let mut err_msg = "error:";
        let mut ei = 0;
        loop {
            if ei >= g_check_error_count { break; }
            err_msg = err_msg + " [" + g_check_errors[ei] + "]";
            ei = ei + 1;
        }
        return err_msg;
    }
    return "check_ok";
}
'''
full_src += test_fns

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
    print(f"Bootstrap errors: {resolver.errors + checker.errors}")
    sys.exit(1)
ir_gen = IRGen(resolver.symtab)
mod = ir_gen.gen_module(ast)
interp = Interpreter(mod)

tests = [
    ("struct + impl with simple method", '''
struct Vec { x: int, y: int }
impl Vec {
    fn get_x(self: Vec) -> int { return 42; }
}
fn main() -> int {
    let v = Vec { x = 10, y = 20 };
    return v.get_x();
}
'''),
    ("struct + impl with field access", '''
struct Vec { x: int, y: int }
impl Vec {
    fn get_x(self: Vec) -> int { return self.x; }
}
fn main() -> int {
    let v = Vec { x = 10, y = 20 };
    return v.get_x();
}
'''),
    ("struct + impl with field read self.x", '''
struct Pos { x: int }
fn main() -> int {
    let p = Pos { x = 42 };
    return p.x;
}
'''),
]

for name, src in tests:
    print(f"\n=== {name} ===")
    try:
        r = interp.run('test_check', [src])
        print(f"  Result: {r}")
    except Exception as e:
        print(f"  CRASH: {type(e).__name__}: {e}")
