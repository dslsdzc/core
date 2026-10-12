#!/usr/bin/env python3
"""apx 变量标签机制测试 — Python bootstrap（与自举编译器行为一致）。

断言点：
- `x : int, apx = 42` 解析/检查通过，ir_gen 为每个 apx 变量发射 ApproxInstr
  （纯注解指令，无操作数）
- 未知标签（bogus_tag）解析报错（SyntaxError）
- apx 不改变程序语义：interpreter 运行结果与无 apx 版本一致
  （interpreter 必须跳过 ApproxInstr 不能崩）
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
from corec.ir.coreir import ApproxInstr


def compile_src(src):
    lex = Lexer(src)
    ast = Parser(lex.tokenize()).parse_compilation_unit()
    resolver = NameResolver()
    resolver.resolve(ast)
    desugarer = MatchDesugarer(resolver.symtab)
    ast = desugarer.desugar(ast)
    checker = TypeChecker(resolver.symtab)
    checker.check(ast)
    if resolver.errors or checker.errors:
        raise AssertionError(f"unexpected errors: {resolver.errors + checker.errors}")
    ir_gen = IRGen(resolver.symtab)
    return ir_gen.gen_module(ast)


def count_approx(mod):
    n = 0
    for f in mod.functions:
        for blk in f.blocks:
            for instr in blk.instrs:
                if isinstance(instr, ApproxInstr):
                    n = n + 1
    return n


def run_main(mod, *args):
    interp = Interpreter(mod)
    return interp.run('main', list(args))


# ── 1) apx 标签解析 + 检查 + IR 注解 ──

def test_apx_parses_and_annotates():
    src = '''
fn main() -> int:
    x : int, apx = 42
    y : int = 84
    z : int, apx, mut = 126
    return x + y + z
'''
    mod = compile_src(src)
    n = count_approx(mod)
    if n != 2:
        print(f"[FAIL] apx parses and annotates: expected 2 ApproxInstr, got {n}")
        return False
    print("[PASS] apx parses and annotates (2 ApproxInstr: x, z)")
    return True


def test_plain_has_no_approx():
    src = '''
fn main() -> int:
    x : int = 42
    y : int = 84
    return x + y
'''
    mod = compile_src(src)
    n = count_approx(mod)
    if n != 0:
        print(f"[FAIL] plain program: expected 0 ApproxInstr, got {n}")
        return False
    print("[PASS] plain program has no ApproxInstr")
    return True


def test_batch_apx():
    # 批量声明：apx 标签作用于所有名字（每个名字一条注解）
    src = '''
fn main() -> int:
    a, b : int, apx = 1, 2
    return a + b
'''
    mod = compile_src(src)
    n = count_approx(mod)
    if n != 2:
        print(f"[FAIL] batch apx: expected 2 ApproxInstr (a, b), got {n}")
        return False
    if run_main(mod) != 3:
        print("[FAIL] batch apx: run result != 3")
        return False
    print("[PASS] batch apx (2 ApproxInstr, run = 3)")
    return True


# ── 2) 未知标签报错 ──

def test_unknown_tag_rejected():
    src = '''
fn main() -> int:
    x : int, bogus_tag = 42
    return x
'''
    try:
        compile_src(src)
    except SyntaxError as e:
        print(f"[PASS] unknown tag rejected (SyntaxError: {e})")
        return True
    print("[FAIL] unknown tag not rejected")
    return False


# ── 3) 语义不变（interpreter 跳过 ApproxInstr）──

def test_no_semantic_change():
    plain = '''
fn main() -> int:
    x : int = 42
    y : int = 84
    return x + y
'''
    apx = '''
fn main() -> int:
    x : int, apx = 42
    y : int, apx = 84
    return x + y
'''
    rp = run_main(compile_src(plain))
    ra = run_main(compile_src(apx))
    if rp != ra or rp != 126:
        print(f"[FAIL] semantic change: plain={rp} apx={ra} (expect 126)")
        return False
    print(f"[PASS] no semantic change (both run -> {ra})")
    return True


def main():
    tests = [
        test_apx_parses_and_annotates,
        test_plain_has_no_approx,
        test_batch_apx,
        test_unknown_tag_rejected,
        test_no_semantic_change,
    ]
    results = [t() for t in tests]
    passed = sum(results)
    print(f"{passed}/{len(results)} passed")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
