#!/usr/bin/env python3
"""词法对照测试：`_` 分隔符与宽度后缀在两编译器均被拒绝（2026-09-10 语言面收窄 §2）。"""
import sys, os, subprocess
sys.path.insert(0, 'bootstrap')
from corec.frontend.lexer import Lexer

BASE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
COREC = os.path.join(BASE, 'build', 'corec')
BAD = ('1_000', '1_000.5', '0x1_0', '10f32', '1.5f64', '10u8')

def selfhost(src):
    r = subprocess.run(['nice', '-n', '19', COREC, 'run', 'fn main()->int{return %s;}' % src],
                       cwd=BASE, capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr

def test_bootstrap_rejects():
    for bad in BAD:
        try:
            Lexer(bad).tokenize()
            assert False, 'bootstrap accepted %s' % bad
        except SyntaxError:
            pass

def test_selfhost_rejects():
    # 断言必须命中**我们自己的诊断文本**——否则 `return 1_000` 既有的 TF01 会假绿。
    # 注意：lexer 诊断走 src/compiler/lexer.cr add_error，输出前缀是 `error: `，
    # **不是** `error[XX]`（实测 `fn main()->int{return 0xZZ;}` → `error: invalid digit
    # in integer literal`，rc=1）——故只断言消息标记 + 出现 `error`，不断言 `error[`。
    for bad, marker in (('1_000', 'not supported'), ('1_000.5', 'not supported'),
                        ('0x1_0', 'not supported'), ('10f32', 'retired'),
                        ('1.5f64', 'retired'), ('10u8', 'retired')):
        rc, out = selfhost(bad)
        assert 'error' in out and marker in out, (bad, rc, out)

def test_legal_forms_unchanged():
    for src, want in (('0x1f', 31), ('0o17', 15), ('0b1010', 10), ('1000', 232)):
        rc, out = selfhost(src)
        assert 'error[' not in out, (src, out)
        assert rc == want, (src, rc, want)

if __name__ == '__main__':
    for fn in (test_bootstrap_rejects, test_selfhost_rejects, test_legal_forms_unchanged):
        fn(); print('PASS', fn.__name__)
