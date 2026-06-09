#!/usr/bin/env python3
"""Bootstrap pipeline tests — Core source → lex → parse → resolve → desugar → typecheck → ir_gen → interpret."""
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
    """Compile Core source through the full bootstrap pipeline and compare interpreter result."""
    try:
        lex = Lexer(src)
        ast = Parser(lex.tokenize()).parse_compilation_unit()
        resolver = NameResolver()
        resolver.resolve(ast)
        desugarer = MatchDesugarer(resolver.symtab)
        ast = desugarer.desugar(ast)
        checker = TypeChecker(resolver.symtab)
        checker.check(ast)
        if resolver.errors or checker.errors:
            print(f"[FAIL] {name}: errors={resolver.errors + checker.errors}")
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


def run_test_raw(name, src, expected):
    """Like run_test but for non-int return types (string, float)."""
    lex = Lexer(src)
    ast = Parser(lex.tokenize()).parse_compilation_unit()
    resolver = NameResolver()
    resolver.resolve(ast)
    desugarer = MatchDesugarer(resolver.symtab)
    ast = desugarer.desugar(ast)
    checker = TypeChecker(resolver.symtab)
    checker.check(ast)
    if resolver.errors or checker.errors:
        print(f"[FAIL] {name}: errors={resolver.errors + checker.errors}")
        return False
    ir_gen = IRGen(resolver.symtab)
    mod = ir_gen.gen_module(ast)
    interp = Interpreter(mod)
    result = interp.run('main', [])
    if result == expected:
        print(f"[PASS] {name}: got {result!r}")
        return True
    else:
        print(f"[FAIL] {name}: expected {expected!r}, got {result!r}")
        return False


passed = 0
failed = 0

def test(name, src, expected):
    global passed, failed
    if run_test(name, src, expected):
        passed += 1
    else:
        failed += 1

def test_raw(name, src, expected):
    global passed, failed
    if run_test_raw(name, src, expected):
        passed += 1
    else:
        failed += 1


# ── Arithmetic & Function Calls ──
test('Arithmetic & Call', '''
fn add(a: int, b: int) -> int { return a + b; }
fn main() -> int { return add(3, 4); }
''', 7)

# ── Loop & Break ──
test('Loop & Break', '''
fn sum(n: int) -> int {
    i : ., mut = 0;
    s : ., mut = 0;
    loop {
        if i >= n { break; }
        s = s + i;
        i = i + 1;
    }
    return s;
}
fn main() -> int { return sum(5); }
''', 10)

# ── If / Else ──
test('If/Else', '''
fn max(a: int, b: int) -> int {
    if a > b { return a; } else { return b; }
}
fn main() -> int { return max(3, 7); }
''', 7)

# ── Struct ──
test('Struct Field Access', '''
struct Point { x: int, y: int }
fn main() -> int {
    p := Point { x = 10, y = 20 };
    return p.x + p.y;
}
''', 30)

test('Method Call', '''
struct Vec { x: int, y: int }
impl Vec {
    fn norm(self: Vec) -> int { return self.x + self.y; }
}
fn main() -> int {
    v := Vec { x = 1, y = 2 };
    return v.norm();
}
''', 3)

test('Nested Structs', '''
struct Inner { a: int }
struct Outer { inner: Inner, b: int }
fn main() -> int {
    inner := Inner { a = 5 };
    outer := Outer { inner = inner, b = 10 };
    return outer.inner.a + outer.b;
}
''', 15)

# ── Comparisons & Logic ──
test('Comparisons', '''
fn main() -> int {
    if 2 < 3 && 4 == 4 { return 1; }
    return 0;
}
''', 1)

# ── Enum & Match ──
test('Enum Match Unwrap', '''
enum Option { Some(int), None }
fn main() -> int {
    x := Some(42);
    match x {
        Some(val) => val,
        None => 0,
    }
}
''', 42)

test('Enum Multi Args', '''
enum Color { Red, Green(int), Blue(int, int) }
fn main() -> int {
    c := Blue(1, 2);
    match c {
        Red => 0,
        Green(n) => n,
        Blue(a, b) => a + b,
    }
}
''', 3)

# ── Float ──
test('Float Add', '''
fn main() -> float {
    a := 3.14;
    b := 2.86;
    return a + b;
}
''', 6.0)

test('Int Float Mix', '''
fn main() -> float {
    a := 2;
    b := 3.5;
    return a + b;
}
''', 5.5)

# ── String ──
test_raw('String Concat', '''
fn main() -> string {
    a := "Hello, ";
    b := "World!";
    return a + b;
}
''', "Hello, World!")

# ── Array ──
test('Array Read', '''
fn main() -> int {
    arr := [10, 20, 30];
    return arr[0] + arr[1] + arr[2];
}
''', 60)

test('Array Mutate', '''
fn main() -> int {
    arr : ., mut = [10, 20, 30];
    arr[1] = 50;
    return arr[0] + arr[1] + arr[2];
}
''', 90)

# ── For Loop ──
test('For Range Sum', '''
fn main() -> int {
    sum : ., mut = 0;
    for i in 0..10 { sum = sum + i; }
    return sum;
}
''', 45)

test('For Array Iter', '''
fn main() -> int {
    arr := [10, 20, 30];
    s : ., mut = 0;
    for val in arr { s = s + val; }
    return s;
}
''', 60)

# ── References ──
test('Ref Deref', '''
fn main() -> int {
    x := 42;
    r := &x;
    return *r;
}
''', 42)

test('Mut Ref Write', '''
fn main() -> int {
    x : ., mut = 10;
    r := &mut x;
    *r = 20;
    return *r;
}
''', 20)

# ── Enum Match (via desugar) ──
test('Enum Match Opt', '''
fn main() -> int {
    opt := Some(99);
    match opt {
        Some(val) => val,
        None => 0,
    }
}
''', 99)

# ── If without else (regression: two-variable comparison) ──
test('If No Else (gt, true)', '''
fn main() -> int {
    a := 10; b := 3;
    if a > b { return 100; }
    return 200;
}
''', 100)

test('If No Else (gt, false)', '''
fn main() -> int {
    a := 3; b := 10;
    if a > b { return 100; }
    return 200;
}
''', 200)

test('If No Else (eq, true)', '''
fn main() -> int {
    a := 5; b := 5;
    if a == b { return 99; }
    return 88;
}
''', 99)

test('If No Else (ne, false)', '''
fn main() -> int {
    a := 5; b := 5;
    if a != b { return 99; }
    return 88;
}
''', 88)

# ── Summary ──
print(f"\n{passed}/{passed + failed} passed", end="")
if failed > 0:
    print(f", {failed} failed")
    sys.exit(1)
else:
    print()
