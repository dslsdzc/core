import sys; sys.path.insert(0,'bootstrap')
from corec.frontend.lexer import Lexer
from corec.frontend.parser import Parser
from corec.frontend.name_resolver import NameResolver
from corec.frontend.desugar import MatchDesugarer
from corec.frontend.type_checker import TypeChecker
from corec.frontend.ir_gen import IRGen
from corec.backend.interpreter import Interpreter

src = '''
fn main() -> int {
    let mut arr = [10, 20, 30];
    arr[1] = 50;
    return arr[0] + arr[1] + arr[2];
}
'''
lex = Lexer(src)
ast = Parser(lex.tokenize()).parse_compilation_unit()
resolver = NameResolver()
resolver.resolve(ast)
desugarer = MatchDesugarer(resolver.symtab)
ast = desugarer.desugar(ast)
checker = TypeChecker(resolver.symtab)
checker.check(ast)
if resolver.errors or checker.errors:
    print("Errors:", resolver.errors+checker.errors)
else:
    ir_gen = IRGen(resolver.symtab)
    mod = ir_gen.gen_module(ast)
    interp = Interpreter(mod)
    result = interp.run('main', [])
    print('Result:', result)  # 10 + 50 + 30 = 90
