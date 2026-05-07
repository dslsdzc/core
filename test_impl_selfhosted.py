#!/usr/bin/env python3
"""Test impl blocks through self-hosted compiler pipeline."""
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

# Wrapper that runs the full compiler pipeline
wrapper = '''
fn compile_and_check(source: string) -> string {
    g_source = source;
    tokenize();
    parse_all();
    check_all();
    if g_check_error_count > 0 {
        let mut err_msg = "check errors:";
        let mut ei = 0;
        loop {
            if ei >= g_check_error_count { break; }
            err_msg = err_msg + " " + g_check_errors[ei];
            ei = ei + 1;
        }
        return err_msg;
    }
    ir_gen_all();
    return x86_64_generate();
}

fn compile_ir(source: string) -> string {
    g_source = source;
    tokenize();
    parse_all();
    check_all();
    if g_check_error_count > 0 {
        let mut err_msg = "check errors:";
        let mut ei = 0;
        loop {
            if ei >= g_check_error_count { break; }
            err_msg = err_msg + " " + g_check_errors[ei];
            ei = ei + 1;
        }
        return err_msg;
    }
    ir_gen_all();
    return "ir_gen_ok";
}
'''
full_src += wrapper

# Check diag function
diag_fn = '''
fn diag() -> string {
    let s = "structs=" + __builtin_int_to_str(g_struct_count) +
            " funcs=" + __builtin_int_to_str(g_func_count) +
            " methods=" + __builtin_int_to_str(g_method_count);
    return s;
}
'''
full_src += diag_fn

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
    print(f"Errors compiling compiler: {resolver.errors + checker.errors}")
    sys.exit(1)
ir_gen = IRGen(resolver.symtab)
mod = ir_gen.gen_module(ast)
interp = Interpreter(mod)

print("Self-hosted compiler compiled OK")

# Test 1: impl with method
test1 = '''
struct Vec { x: int, y: int }

impl Vec {
    fn sum(self: Vec) -> int {
        return self.x + self.y;
    }
}

fn main() -> int {
    let v = Vec { x = 10, y = 20 };
    return v.sum();
}
'''
print("\n--- Test 1: impl block with method call ---")
try:
    r = interp.run('compile_and_check', [test1])
    if r and r.startswith("check errors"):
        print(f"  FAIL: {r}")
    else:
        print(f"  PASS: generated x86-64 asm ({len(r)} chars)")
        print(f"  First 200 chars: {r[:200]}")
except Exception as e:
    print(f"  CRASH: {e}")

# Test 2: struct literal + method
test2 = '''
struct Point { x: int, y: int }

impl Point {
    fn double(self: Point) -> Point {
        return Point { x = self.x * 2, y = self.y * 2 };
    }
}

fn main() -> Point {
    let p = Point { x = 5, y = 7 };
    return p.double();
}
'''
print("\n--- Test 2: method returning struct literal ---")
try:
    r = interp.run('compile_and_check', [test2])
    if r and r.startswith("check errors"):
        print(f"  FAIL: {r}")
    else:
        print(f"  PASS: generated x86-64 asm ({len(r)} chars)")
except Exception as e:
    print(f"  CRASH: {e}")
