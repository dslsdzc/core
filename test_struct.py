import sys; sys.path.insert(0,'bootstrap')
from corec.frontend.lexer import Lexer
from corec.frontend.parser import Parser
from corec.frontend.name_resolver import NameResolver
from corec.frontend.type_checker import TypeChecker
from corec.frontend.ir_gen import IRGen
from corec.backend.interpreter import Interpreter

src = '''
struct Point {
    x: int,
    y: int,
}

impl Point {
    fn norm(self: Point) -> int {
        return self.x + self.y;
    }
}

fn main() -> int {
    let p = Point { x = 3, y = 4 };
    return p.norm();
}
'''
lex = Lexer(src)
ast = Parser(lex.tokenize()).parse_compilation_unit()

resolver = NameResolver()
resolver.resolve(ast)
checker = TypeChecker(resolver.symtab)
checker.check(ast)

print("Name errors:", resolver.errors)
print("Type errors:", checker.errors)

ir_gen = IRGen(resolver.symtab)
mod = ir_gen.gen_module(ast)
interp = Interpreter(mod)
result = interp.run('main', [])
print("Result:", result)
