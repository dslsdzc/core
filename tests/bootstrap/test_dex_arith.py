#!/usr/bin/env python3
"""dex 精确运算测试（Python bootstrap 解释器路径）—— 数值迁移 Task 4 同步。

bootstrap 的 dex 表示 = 定点缩放整数（S = 10^6，Dex 类）——与自举侧精确语义
同步：字面量精确解析（十进制 → 缩放整数）、加减乘除比较 = 缩放整数算术、
打印 = 定点 → 十进制（去尾零）。0.1 + 0.2 == 0.3 精确成立（binary64 做不到）。

断言点：
- 0.1+0.2==0.3、3.14+2.86==6.0（精确）
- 1/10 打印 "0.1"（捕获 stdout）
- 乘/除/减/负数、int 参与、dex 变量
"""
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
        print(f"[FAIL] {name}: expected {expected}, got {result}")
        return False
    except Exception as e:
        print(f"[ERROR] {name}: {e}")
        import traceback; traceback.print_exc()
        return False


def main():
    results = [
        run_test('Exact Add 0.1+0.2==0.3', '''
fn main() -> int:
    a := 0.1 + 0.2
    if a == 0.3:
        return 1
    return 0
''', 1),
        run_test('Exact Add 3.14+2.86==6.0', '''
fn main() -> int:
    a := 3.14 + 2.86
    if a == 6.0:
        return 1
    return 0
''', 1),
        run_test('Exact Div 1/10==0.1', '''
fn main() -> int:
    a := 1.0 / 10.0
    if a == 0.1:
        return 1
    return 0
''', 1),
        run_test('Exact Mul 1.5*2.0==3.0', '''
fn main() -> int:
    a := 1.5 * 2.0
    if a == 3.0:
        return 1
    return 0
''', 1),
        run_test('Exact Sub Neg 0.3-1.0==-0.7', '''
fn main() -> int:
    a := 0.3 - 1.0
    if a == -0.7:
        return 1
    return 0
''', 1),
        run_test('Int Participates 1+0.5==1.5', '''
fn main() -> int:
    a := 1 + 0.5
    if a == 1.5:
        return 1
    return 0
''', 1),
        run_test('Dex Var Add', '''
fn main() -> int:
    x : dex = 0.1
    y : dex = 0.2
    if x + y == 0.3:
        return 1
    return 0
''', 1),
        run_test('Fn Dex Boundary', '''
fn add2(a: dex, b: dex) -> dex:
    return a + b
fn main() -> int:
    r := add2(0.1, 0.2)
    if r == 0.3:
        return 1
    return 0
''', 1),
        # 模运算截断恒等式（a - trunc(a/b)·b），含负数
        run_test('Mod Trunc 7.0%2.5==2.0', '''
fn main() -> int:
    a := 7.0 % 2.5
    if a == 2.0:
        return 1
    return 0
''', 1),
        run_test('Mod Trunc -7.0%2.5==-2.0', '''
fn main() -> int:
    a := -7.0 % 2.5
    if a == -2.0:
        return 1
    return 0
''', 1),
        run_test('Mod Trunc 1.0%0.3==0.1', '''
fn main() -> int:
    a := 1.0 % 0.3
    if a == 0.1:
        return 1
    return 0
''', 1),
        run_test('Mod Trunc -1.0%0.3==-0.1', '''
fn main() -> int:
    a := -1.0 % 0.3
    if a == -0.1:
        return 1
    return 0
''', 1),
    ]
    # 打印格式（定点 → 十进制，去尾零）——直接断言格式函数（bootstrap 无 stdlib，
    # 端到端打印路径由自举侧 tests/suite/dex_test.cr 覆盖）
    from corec.backend.interpreter import _dex_str, _trunc_div
    fmt_cases = [
        (3140000, '3.14'),
        (6000000, '6'),
        (100000, '0.1'),
        (-700000, '-0.7'),
        (333333, '0.333333'),
        (0, '0'),
    ]
    for val, want in fmt_cases:
        got = _dex_str(val)
        if got != want:
            print(f'[FAIL] dex_str({val}) -> {got!r}, want {want!r}')
            results.append(False)
            break
    else:
        print('[PASS] dex formatting (fixed-point -> decimal, trailing zeros stripped)')
        results.append(True)
    if _trunc_div(-5, 2) == -2 and _trunc_div(5, -2) == -2 and _trunc_div(1, 3) == 0:
        print('[PASS] truncating division (toward zero)')
        results.append(True)
    else:
        print(f'[FAIL] truncating division: {_trunc_div(-5, 2)}')
        results.append(False)
    print(f"{sum(results)}/{len(results)} passed")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
