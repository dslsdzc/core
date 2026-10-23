#!/usr/bin/env python3
"""Bootstrap BigInt pipeline: tagged user code plus a raw Core BigInt runtime."""

import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, "bootstrap")

from corec.backend.x86_64_stack_asm import X86_64StackAsmGen
from corec.frontend.desugar import MatchDesugarer
from corec.frontend.ir_gen import IRGen
from corec.frontend.lexer import Lexer
from corec.frontend.name_resolver import NameResolver
from corec.frontend.parser import Parser
from corec.frontend.type_checker import TypeChecker
from corec.ir.coreir import Module

BASE = Path(__file__).resolve().parents[2]
RUNTIME = BASE / "src" / "runtime" / "bigint.cr"

SRC = """fn main() -> int:
    x := 9223372036854775808
    y := x + 1
    if y == 9223372036854775809:
        return 0
    return 1
"""


def compile_module(src: str) -> Module:
    ast = Parser(Lexer(src).tokenize()).parse_compilation_unit()
    resolver = NameResolver()
    resolver.resolve(ast)
    ast = MatchDesugarer(resolver.symtab).desugar(ast)
    checker = TypeChecker(resolver.symtab)
    checker.check(ast)
    if resolver.errors or checker.errors:
        raise AssertionError(resolver.errors + checker.errors)
    return IRGen(resolver.symtab).gen_module(ast)


def build_object(module: Module, path: Path, **kwargs) -> None:
    asm = X86_64StackAsmGen(module, **kwargs).generate()
    asm_path = path.with_suffix(".s")
    asm_path.write_text(asm, encoding="utf-8")
    r = subprocess.run(["as", "-o", str(path), str(asm_path)], capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(r.stderr)


def main() -> int:
    raw_mod = compile_module(RUNTIME.read_text(encoding="utf-8"))
    user_mod = compile_module(SRC)
    with tempfile.TemporaryDirectory(prefix="core-bigint-pipeline-") as td:
        d = Path(td)
        raw_obj = d / "bigint.o"
        user_obj = d / "p.o"
        out = d / "p"
        build_object(raw_mod, raw_obj, runtime_only=True)
        build_object(user_mod, user_obj, bigint_mode=True)
        r = subprocess.run(
            ["ld", "--unresolved-symbols=ignore-all", "-o", str(out),
             str(user_obj), str(raw_obj), str(BASE / "build" / "runtime.o")],
            capture_output=True,
            text=True,
        )
        if r.returncode != 0:
            print(r.stderr)
            return 1
        run = subprocess.run([str(out)])
        if run.returncode != 0:
            print(f"pipeline exit {run.returncode}")
            return 1
    print("PASS bigint pipeline")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
