import sys; sys.path.insert(0,'bootstrap')
from corec.frontend.lexer import Lexer
from corec.frontend.parser import Parser
from corec.frontend.name_resolver import NameResolver
from corec.frontend.desugar import MatchDesugarer
from corec.frontend.type_checker import TypeChecker
from corec.frontend.ir_gen import IRGen
from corec.backend.interpreter import Interpreter

# 测试1: 不可变引用 + 解引用读取
src1 = '''
fn main() -> int {
    let x = 42;
    let r = &x;
    return *r;
}
'''
lex = Lexer(src1)
ast = Parser(lex.tokenize()).parse_compilation_unit()
resolver = NameResolver()
resolver.resolve(ast)
desugarer = MatchDesugarer(resolver.symtab)
ast = desugarer.desugar(ast)
checker = TypeChecker(resolver.symtab)
checker.check(ast)
print("Test1 borrow errors:", checker.errors)
ir_gen = IRGen(resolver.symtab)
mod = ir_gen.gen_module(ast)
interp = Interpreter(mod)
result = interp.run('main', [])
print("Test1 result (expected 42):", result)

# 测试2: 可变引用修改原变量（通过解引用读取验证）
src2 = '''
fn main() -> int {
    let mut x = 10;
    let r = &mut x;
    *r = 20;
    return *r;
}
'''
lex2 = Lexer(src2)
ast2 = Parser(lex2.tokenize()).parse_compilation_unit()
resolver2 = NameResolver()
resolver2.resolve(ast2)
ast2 = desugarer.desugar(ast2)
checker2 = TypeChecker(resolver2.symtab)
checker2.check(ast2)
print("Test2 borrow errors:", checker2.errors)
ir_gen2 = IRGen(resolver2.symtab)
mod2 = ir_gen2.gen_module(ast2)
interp2 = Interpreter(mod2)
result2 = interp2.run('main', [])
print("Test2 result (expected 20):", result2)
