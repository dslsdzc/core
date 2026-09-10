#!/usr/bin/env python3
"""效应/纯度修正 Task 1 判据：真纯度计算自测通道（corec selftest-purity）。

语义 = plans/2026-08-08-region-cfg.md:484（非纯调用才进 state 链；find_func
不可得保守进链）+ 本批 plan Task 1（docs/superpowers/plans/2026-09-11-effect-purity-fix.md）：
纯 ⟺ 体无 store 族 / 无 IO·FFI·并发效应 opcode / 传递闭包内被调者全纯（不可解析
不纯）/ 递归·SCC 保守不纯；泛型实例与源同值。

判据 = 用例表全 PASS + 零 FAIL + 计数行 + rc=0。用例表本身在
src/compiler/purity_selftest.cr（正控 2 + 负控①-⑥ 含 SCC 互递归与有效应泛型）。
"""

import re
import subprocess
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"

# 用例数下限：本批用例表 = 17 例＝纯度 13（正控2 + ①store + ②传递 + ③extern +
# ④不可解析 + ⑤自递归 + ⑤b互递归x2 + ⑥泛型实例x2 + ⑥b有效应泛型x2）+ state 链
# 4（效应调用被链穿过 / 纯调用不被触及 / 循环终止依赖 / 无循环无 label 边负控）。
# 低于此数 = 用例被静默删减（判据空转），故设下限而非仅断言相等。
MIN_CASES = 17


def run_selftest():
    return subprocess.run(
        ["nice", "-n", "19", str(COREC), "selftest-purity"],
        cwd=BASE, capture_output=True, text=True,
    )


def test_selftest_purity_all_pass():
    r = run_selftest()
    out = r.stdout + r.stderr
    assert "FAIL" not in out, out
    m = re.search(r"(\d+)/(\d+) purity cases passed", out)
    assert m, out
    passed, total = int(m.group(1)), int(m.group(2))
    assert passed == total and total >= MIN_CASES, (passed, total, out)
    assert r.returncode == 0, (r.returncode, out)


if __name__ == "__main__":
    test_selftest_purity_all_pass()
    print("PASS test_selftest_purity_all_pass")
