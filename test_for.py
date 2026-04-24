import sys; sys.path.insert(0,'bootstrap')
from corec.frontend.lexer import Lexer
from corec.frontend.parser import Parser
from corec.frontend.name_resolver import NameResolver
from corec.frontend.desugar import MatchDesugarer
from corec.frontend.type_checker import TypeChecker
from corec.frontend.ir_gen import IRGen
from corec.backend.interpreter import Interpreter

# 测试1: 范围迭代求和
src1 = '''
fn main() -> int {
    let mut sum = 0;
    for i in 0..10 {
        sum = sum + i;
    }
    return sum;
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
print("Test1 errors:", checker.errors)
ir_gen = IRGen(resolver.symtab)
mod = ir_gen.gen_module(ast)
interp = Interpreter(mod)
result = interp.run('main', [])
print("Test1 sum (expected 45):", result)

# 测试2: 数组迭代
src2 = '''
fn main() -> int {
    let arr = [10, 20, 30];
    let mut s = 0;
    for val in arr {
        s = s + val;
    }
    return s;
}
'''
lex2 = Lexer(src2)
ast2 = Parser(lex2.tokenize()).parse_compilation_unit()
resolver2 = NameResolver()
resolver2.resolve(ast2)
ast2 = desugarer.desugar(ast2)
checker2 = TypeChecker(resolver2.symtab)
checker2.check(ast2)
print("Test2 errors:", checker2.errors)
ir_gen2 = IRGen(resolver2.symtab)
mod2 = ir_gen2.gen_module(ast2)
interp2 = Interpreter(mod2)
result2 = interp2.run('main', [])
print("Test2 sum (expected 60):", result2)
