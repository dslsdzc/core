import sys; sys.path.insert(0,'bootstrap')
from corec.frontend.lexer import Lexer
from corec.frontend.parser import Parser
from corec.frontend.name_resolver import NameResolver
from corec.frontend.desugar import MatchDesugarer
from corec.frontend.type_checker import TypeChecker

def check_errors(src, desc):
    print(f"Testing: {desc}")
    lex = Lexer(src)
    ast = Parser(lex.tokenize()).parse_compilation_unit()
    resolver = NameResolver()
    resolver.resolve(ast)
    desugarer = MatchDesugarer(resolver.symtab)
    ast = desugarer.desugar(ast)
    checker = TypeChecker(resolver.symtab)
    checker.check(ast)
    if checker.errors:
        print("Errors:", checker.errors)
    else:
        print("No errors")

# 测试1：不可变借用后使用原变量应报错
src1 = '''
fn main() -> int {
    let x = 10;
    let r = &x;
    return x;  // 错误：x 已被借用
}
'''
check_errors(src1, "immutable borrow then use original")

# 测试2：可变借用后读取原变量应报错
src2 = '''
fn main() -> int {
    let mut x = 10;
    let rm = &mut x;
    return x;  // 错误：x 已被可变借用
}
'''
check_errors(src2, "mut borrow then use original")

# 测试3：多次不可变借用允许
src3 = '''
fn main() -> int {
    let x = 10;
    let r1 = &x;
    let r2 = &x;
    return *r1 + *r2;
}
'''
check_errors(src3, "multiple immutable borrows allowed (no use of * yet)")

# 测试4：不可变借用后再可变借用应报错
src4 = '''
fn main() -> int {
    let mut x = 10;
    let r1 = &x;
    let r2 = &mut x;  // 错误：x 已被不可变借用
    return 0;
}
'''
check_errors(src4, "immutable then mutable borrow")
