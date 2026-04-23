import sys
sys.path.insert(0, 'bootstrap')
from corec.frontend.lexer import Lexer
from corec.frontend.parser import Parser
from corec.frontend.name_resolver import NameResolver
from corec.frontend.type_checker import TypeChecker
from corec.frontend.ir_gen import IRGen
from corec.backend.interpreter import Interpreter

def run_test(name, src, expected):
    try:
        lex = Lexer(src)
        ast = Parser(lex.tokenize()).parse_compilation_unit()
        resolver = NameResolver()
        resolver.resolve(ast)
        checker = TypeChecker(resolver.symtab)
        checker.check(ast)
        if resolver.errors or checker.errors:
            print(f"[FAIL] {name}: errors={resolver.errors+checker.errors}")
            return
        ir_gen = IRGen(resolver.symtab)
        mod = ir_gen.gen_module(ast)
        interp = Interpreter(mod)
        result = interp.run('main', [])
        if result == expected:
            print(f"[PASS] {name}: got {result}")
        else:
            print(f"[FAIL] {name}: expected {expected}, got {result}")
    except Exception as e:
        print(f"[ERROR] {name}: {e}")

src1 = '''
fn add(a: int, b: int) -> int { return a + b; }
fn main() -> int { return add(3, 4); }
'''
run_test('Arithmetic & Call', src1, 7)

src2 = '''
fn sum(n: int) -> int {
    let mut i = 0;
    let mut s = 0;
    loop {
        if i >= n { break; }
        s = s + i;
        i = i + 1;
    }
    return s;
}
fn main() -> int { return sum(5); }
'''
run_test('Loop & Break', src2, 10)

src3 = '''
fn max(a: int, b: int) -> int {
    if a > b {
        return a;
    } else {
        return b;
    }
}
fn main() -> int { return max(3, 7); }
'''
run_test('If/Else', src3, 7)

src4 = '''
struct Point {
    x: int,
    y: int,
}
fn main() -> int {
    let p = Point { x = 10, y = 20 };
    return p.x + p.y;
}
'''
run_test('Struct Field Access', src4, 30)

src5 = '''
struct Vec {
    x: int,
    y: int,
}
impl Vec {
    fn norm(self: Vec) -> int {
        return self.x + self.y;
    }
}
fn main() -> int {
    let v = Vec { x = 1, y = 2 };
    return v.norm();
}
'''
run_test('Method Call', src5, 3)

src6 = '''
struct Inner { a: int }
struct Outer { inner: Inner, b: int }
fn main() -> int {
    let inner = Inner { a = 5 };
    let outer = Outer { inner = inner, b = 10 };
    return outer.inner.a + outer.b;
}
'''
run_test('Nested Structs', src6, 15)

src7 = '''
fn main() -> int {
    if 2 < 3 && 4 == 4 {
        return 1;
    }
    return 0;
}
'''
run_test('Comparisons', src7, 1)

print("\nAll tests completed.")
