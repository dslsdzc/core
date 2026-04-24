import sys; sys.path.insert(0,'bootstrap')
from corec.frontend.lexer import Lexer
from corec.frontend.parser import Parser
from corec.frontend.name_resolver import NameResolver
from corec.frontend.desugar import MatchDesugarer
from corec.frontend.type_checker import TypeChecker
from corec.frontend.ir_gen import IRGen
from corec.backend.interpreter import Interpreter

# 测试1：泛型函数 identity
src1 = '''
fn identity[T](val: T) -> T {
    return val;
}
fn main() -> int {
    let x = identity(42);
    return x;
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
print("Test1 type errors:", checker.errors)
ir_gen = IRGen(resolver.symtab)
mod = ir_gen.gen_module(ast)
interp = Interpreter(mod)
result = interp.run('main', [])
print("Test1 result (expected 42):", result)

# 测试2：泛型结构体 Box
src2 = '''
struct Box[T] {
    value: T,
}
fn get_value[T](b: Box[T]) -> T {
    return b.value;
}
fn main() -> int {
    let boxed = Box { value = 100 };
    return get_value(boxed);
}
'''
lex = Lexer(src2)
ast = Parser(lex.tokenize()).parse_compilation_unit()
resolver = NameResolver()
resolver.resolve(ast)
desugarer = MatchDesugarer(resolver.symtab)
ast = desugarer.desugar(ast)
checker = TypeChecker(resolver.symtab)
checker.check(ast)
print("Test2 type errors:", checker.errors)
ir_gen = IRGen(resolver.symtab)
mod = ir_gen.gen_module(ast)
interp = Interpreter(mod)
result = interp.run('main', [])
print("Test2 result (expected 100):", result)
