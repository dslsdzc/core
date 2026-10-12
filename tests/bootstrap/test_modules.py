#!/usr/bin/env python3
"""Bootstrap import alias regression tests."""

import os
import sys
import tempfile

sys.path.insert(0, "bootstrap")

from corec.backend.interpreter import Interpreter
from corec.frontend.desugar import MatchDesugarer
from corec.frontend.ir_gen import IRGen
from corec.frontend.lexer import Lexer
from corec.frontend.name_resolver import NameResolver
from corec.frontend.parser import Parser
from corec.frontend.type_checker import TypeChecker
from corec.utils.module_loader import resolve_imports


def main() -> int:
    with tempfile.TemporaryDirectory() as directory:
        helper = os.path.join(directory, "helper.cr")
        main_path = os.path.join(directory, "main.cr")
        with open(helper, "w", encoding="utf-8") as file:
            file.write("fn value() -> int:\n    return 42\n")
        with open(main_path, "w", encoding="utf-8") as file:
            file.write("import helper : h\nfn main() -> int:\n    return h.value()\n")

        with open(main_path, encoding="utf-8") as file:
            source = file.read()
        ast = Parser(Lexer(source).tokenize()).parse_compilation_unit()
        errors = []
        resolve_imports(ast, source_path=main_path, search_paths=[directory], errors=errors)
        resolver = NameResolver()
        resolver.resolve(ast)
        ast = MatchDesugarer(resolver.symtab).desugar(ast)
        checker = TypeChecker(resolver.symtab)
        checker.check(ast)
        if errors or resolver.errors or checker.errors:
            print("[FAIL] import alias:", errors + resolver.errors + checker.errors)
            return 1
        result = Interpreter(IRGen(resolver.symtab).gen_module(ast)).run("main", [])
        if result != 42:
            print(f"[FAIL] import alias: expected 42, got {result}")
            return 1
        print("[PASS] import module : alias resolves qualified function calls")
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
