#!/usr/bin/env python3
"""Bootstrap frontend support for arbitrary precision integer literals."""

import sys

sys.path.insert(0, "bootstrap")

from corec.frontend.desugar import MatchDesugarer
from corec.frontend.ir_gen import IRGen
from corec.frontend.lexer import Lexer
from corec.frontend.name_resolver import NameResolver
from corec.frontend.parser import Parser
from corec.frontend.type_checker import TypeChecker
from corec.ir.coreir import ConstInstr
from corec.syntax.tokens import TokenType


def compile_and_run(src: str):
    tokens = Lexer(src).tokenize()
    ast = Parser(tokens).parse_compilation_unit()
    resolver = NameResolver()
    resolver.resolve(ast)
    ast = MatchDesugarer(resolver.symtab).desugar(ast)
    checker = TypeChecker(resolver.symtab)
    checker.check(ast)
    if resolver.errors or checker.errors:
        raise AssertionError(resolver.errors + checker.errors)
    mod = IRGen(resolver.symtab).gen_module(ast)
    consts = [
        instr
        for fn in mod.functions
        for block in fn.blocks
        for instr in block.instrs
        if isinstance(instr, ConstInstr) and instr.type == "int"
    ]
    return mod, consts


def main() -> int:
    cases = [
        ("0xFFFFFFFFFFFFFFFF", 2**64 - 1),
        ("0x10000000000000000", 2**64),
        ("0o2000000000000000000000", 2**64),
        ("0b1" + "0" * 64, 2**64),
        ("9223372036854775808", 2**63),
    ]
    for literal, expected in cases:
        tokens = Lexer(literal).tokenize()
        int_tokens = [t for t in tokens if t.type == TokenType.INT_LIT]
        if not int_tokens:
            print(f"FAIL lexer did not produce INT_LIT for {literal}")
            return 1
        if int(int_tokens[0].lexeme) != expected:
            print(f"FAIL lexer value {literal}: {int_tokens[0].lexeme}")
            return 1

        src = f"fn main() -> int:\n    return {literal}\n"
        mod, consts = compile_and_run(src)
        values = [instr.value for instr in consts]
        if expected not in values:
            print(f"FAIL IR constant {literal}: {values}")
            return 1

    print("PASS bigint frontend")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
