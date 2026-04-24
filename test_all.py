import sys
sys.path.insert(0,'bootstrap')
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

# 1. 算术与函数调用
src1 = '''
fn add(a: int, b: int) -> int { return a + b; }
fn main() -> int { return add(3, 4); }
'''
run_test('Arithmetic & Call', src1, 7)

# 2. 循环求和 + break
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

# 3. 条件分支 if/else
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

# 4. 结构体字段访问
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

# 5. 结构体方法
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

# 6. 嵌套结构体
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

# 7. 逻辑与比较
src7 = '''
fn main() -> int {
    if 2 < 3 && 4 == 4 {
        return 1;
    }
    return 0;
}
'''
run_test('Comparisons', src7, 1)

# 8. 枚举构造与 match (单参数)
src8 = '''
enum Option {
    Some(int),
    None,
}
fn main() -> int {
    let x = Some(42);
    match x {
        Some(val) => val,
        None => 0,
    }
}
'''
run_test('Enum Match Unwrap', src8, 42)

# 9. 枚举多参数与 match (多分支 & 绑定)
src9 = '''
enum Color {
    Red,
    Green(int),
    Blue(int, int),
}
fn main() -> int {
    let c = Blue(1, 2);
    match c {
        Red => 0,
        Green(n) => n,
        Blue(a, b) => a + b,
    }
}
'''
run_test('Enum Multi Args', src9, 3)

print("\nAll tests completed.")

# 测试10: 浮点数运算
src10 = '''
fn main() -> float {
    let a = 3.14;
    let b = 2.86;
    return a + b;
}
'''
run_test('Float Add', src10, 6.0)  # 3.14+2.86 = 6.0

# 测试11: 混合 int/float
src11 = '''
fn main() -> float {
    let a = 2;
    let b = 3.5;
    return a + b;
}
'''
run_test('Int Float Mix', src11, 5.5)

# 测试12: 字符串拼接
src12 = '''
fn main() -> string {
    let a = "Hello, ";
    let b = "World!";
    return a + b;
}
'''
# 字符串返回值无法用 echo $? 获取，解释器中直接比较
lex = Lexer(src12)
ast = Parser(lex.tokenize()).parse_compilation_unit()
resolver = NameResolver()
resolver.resolve(ast)
desugarer = MatchDesugarer(resolver.symtab)
ast = desugarer.desugar(ast)
checker = TypeChecker(resolver.symtab)
checker.check(ast)
ir_gen = IRGen(resolver.symtab)
mod = ir_gen.gen_module(ast)
interp = Interpreter(mod)
result = interp.run('main', [])
if result == "Hello, World!":
    print("[PASS] String Concat: got", result)
else:
    print("[FAIL] String Concat: expected 'Hello, World!', got", result)
