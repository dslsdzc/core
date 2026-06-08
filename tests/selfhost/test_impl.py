#!/usr/bin/env python3
"""Self-hosted compiler impl/method tests — exercised through both interpreter and native binary."""
import sys, os, subprocess
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
        'src/compiler/checker.cr', 'src/compiler/diag.cr', 'src/compiler/ir_gen.cr', 'src/compiler/dataflow.cr',
        'src/compiler/backend/x86_64.cr', 'src/compiler/module.cr', 'src/compiler/ccr_io.cr', 'src/compiler/dump.cr',
        'src/compiler/project.cr', 'src/compiler/interp.cr', 'src/compiler/main.cr',
    ]
    parts = []
    for f in files:
        path = os.path.join(BASE, f)
        with open(path) as fh:
            content = fh.read().strip()
            if content:
                parts.append(content)
    return '\n\n'.join(parts)


def load_selfhost_interp(extra_fns=""):
    """Compile self-hosted compiler + optional extra functions, return Interpreter."""
    src = concat_sources() + "\n" + extra_fns
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
        print(f"  Bootstrap errors: {resolver.errors + checker.errors}")
        return None
    ir_gen = IRGen(resolver.symtab)
    mod = ir_gen.gen_module(ast)
    return Interpreter(mod)


def assert_pred(cond, msg):
    if not cond:
        print(f"  FAIL: {msg}")
        return False
    return True


passed = 0
failed = 0

def check(name, success):
    global passed, failed
    if success:
        print(f"  PASS: {name}")
        passed += 1
    else:
        print(f"  FAIL: {name}")
        failed += 1

# ═══════════════════════════════════════════
# Part A: Interpreter-based tests (method calls, struct field access)
# ═══════════════════════════════════════════

print("=== Part A: Interpreter-based impl tests ===\n")

wrapper = '''
fn compile_and_check(source: string) -> string {
    g_source = source;
    tokenize();
    parse_all();
    check_all();
    if g_diag_count > 0 {
        err_msg : ., mut = "check errors:";
        ei : ., mut = 0;
        loop {
            if ei >= g_diag_count { break; }
            err_msg = err_msg + " " + g_diags[ei].msg;
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
    if g_diag_count > 0 {
        err_msg : ., mut = "check errors:";
        ei : ., mut = 0;
        loop {
            if ei >= g_diag_count { break; }
            err_msg = err_msg + " " + g_diags[ei].msg;
            ei = ei + 1;
        }
        return err_msg;
    }
    ir_gen_all();
    return "ir_gen_ok";
}
fn test_check(src: string) -> string {
    g_source = src;
    tokenize();
    parse_all();
    check_all();
    if g_diag_count > 0 {
        err_msg : ., mut = "error:";
        ei : ., mut = 0;
        loop {
            if ei >= g_diag_count { break; }
            err_msg = err_msg + " [" + g_diags[ei].msg + "]";
            ei = ei + 1;
        }
        return err_msg;
    }
    return "check_ok";
}
'''

interp = load_selfhost_interp(wrapper)
if not interp:
    print("FAILED to load self-hosted compiler")
    sys.exit(1)

# A1: struct + impl with simple method (returns constant)
print("--- A1: struct + impl, method returns constant ---")
r = interp.run('test_check', ['''
struct Vec { x: int, y: int }
impl Vec { fn get_x(self: Vec) -> int { return 42; } }
fn main() -> int { v := Vec { x = 10, y = 20 }; return v.get_x(); }
'''])
check("method returns constant", r == "check_ok")

# A2: struct + impl with field access
print("\n--- A2: struct + impl, method reads self.x ---")
r = interp.run('test_check', ['''
struct Vec { x: int, y: int }
impl Vec { fn get_x(self: Vec) -> int { return self.x; } }
fn main() -> int { v := Vec { x = 10, y = 20 }; return v.get_x(); }
'''])
check("method reads self.x", r == "check_ok")

# A3: struct literal field access
print("\n--- A3: struct field read ---")
r = interp.run('test_check', ['''
struct Pos { x: int }
fn main() -> int { p := Pos { x = 42 }; return p.x; }
'''])
check("struct field read", r == "check_ok")

# A4: impl with method call (self param)
print("\n--- A4: impl block with method call (self param) ---")
r = interp.run('compile_and_check', ['''
struct Vec { x: int, y: int }
impl Vec { fn sum(self: Vec) -> int { return self.x + self.y; } }
fn main() -> int { v := Vec { x = 10, y = 20 }; return v.sum(); }
'''])
check("method with self param", r and not r.startswith("check errors"))

# A5: method returning struct literal
print("\n--- A5: method returning struct literal ---")
r = interp.run('compile_and_check', ['''
struct Point { x: int, y: int }
impl Point {
    fn double(self: Point) -> Point { return Point { x = self.x * 2, y = self.y * 2 }; }
}
fn main() -> Point { p := Point { x = 5, y = 7 }; return p.double(); }
'''])
check("method returning struct", r and not r.startswith("check errors"))

# ═══════════════════════════════════════════
# Part B: Native binary tests (compile → asm → ld → run)
# ═══════════════════════════════════════════

print("\n=== Part B: Native binary impl tests ===\n")

interp2 = load_selfhost_interp()
if not interp2:
    print("FAILED to load compiler for native tests")
    sys.exit(1)


def native_test(name, src, expected_exit_code):
    """Compile Core source through self-hosted compiler, assemble, link, run, check exit code."""
    try:
        asm = interp2.run('compile_source', [src])
    except Exception as e:
        print(f"  FAIL [{name}]: compile_source crashed: {e}")
        return False

    if asm is None:
        print(f"  FAIL [{name}]: compile_source returned None")
        return False
    if "check errors" in str(asm):
        print(f"  FAIL [{name}]: compile errors: {asm}")
        return False

    build_dir = os.path.join(BASE, 'build')
    os.makedirs(build_dir, exist_ok=True)
    slug = name.replace(' ', '_').replace('&', 'and')
    test_dir = os.path.dirname(os.path.abspath(__file__))
    rt_s = os.path.join(test_dir, 'minimal_rt.s')
    asm_path = os.path.join(build_dir, f'test_impl_{slug}.s')
    bin_path = os.path.join(build_dir, f'test_impl_{slug}')

    with open(asm_path, 'w') as f:
        f.write(asm)

    r = subprocess.run(['as', '-o', bin_path + '.o', asm_path], capture_output=True, text=True)
    if r.returncode != 0:
        print(f"  FAIL [{name}]: assembly failed: {r.stderr}")
        return False
    r = subprocess.run(['as', '-o', bin_path + '_rt.o', rt_s], capture_output=True, text=True)
    if r.returncode != 0:
        print(f"  FAIL [{name}]: runtime assembly failed: {r.stderr}")
        return False
    r = subprocess.run(['ld', '-o', bin_path, bin_path + '.o', bin_path + '_rt.o'],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print(f"  FAIL [{name}]: link failed: {r.stderr}")
        return False
    r = subprocess.run([bin_path], capture_output=True, text=True)
    if r.returncode == expected_exit_code:
        print(f"  PASS [{name}]: exit code {r.returncode}")
        return True
    else:
        print(f"  FAIL [{name}]: expected {expected_exit_code}, got {r.returncode}")
        return False


# B1: &self method
check("&self method call",
      native_test("self_method", '''
struct Point { x: int, y: int }
impl Point { fn get_x(&self) -> int { return self.x; } }
fn main() -> int { p := Point { x = 42, y = 100 }; return p.get_x(); }
''', 42))

# B2: &mut self method
check("&mut self method",
      native_test("mut_self_method", '''
struct Counter { val: int }
impl Counter {
    fn inc(&mut self) { self.val = self.val + 1; }
    fn get(&self) -> int { return self.val; }
}
fn main() -> int {
    c : ., mut = Counter { val = 5 };
    c.inc(); c.inc();
    return c.get();
}
''', 7))

# ── Summary ──
print(f"\n{passed}/{passed + failed} passed", end="")
if failed > 0:
    print(f", {failed} failed")
    sys.exit(1)
else:
    print()
