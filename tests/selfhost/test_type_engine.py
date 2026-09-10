#!/usr/bin/env python3
"""R2 P0 判据：类型项引擎自测通道（corec selftest-types）。

引擎 = 集合语义的包含判定（spec docs/superpowers/specs/2026-09-10-type-interface-unification-design.md §3）。
P0 只建层：checker 零改动、产物零变化；判据 = 用例表全 PASS + 零 FAIL + 计数行。
"""

import re
import subprocess
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"

# 用例数下限。P0 Task 1 = 建层，用例表 = 5 例（计划 Step 6 的 P0 最小面：
# bot_sub_int / int_sub_str / int_sub_int / dedup / notnot）；计划 Step 1 原文的
# 下限 20 是 **spec §8 全类**（子类型/等价/不相交/可空/反例/穷尽性/递归/参数化/
# 预算）落地后的目标值——Task 3/4 填表后此常量抬到 20。
MIN_CASES = 5


def run_selftest():
    return subprocess.run(
        ["nice", "-n", "19", str(COREC), "selftest-types"],
        cwd=BASE, capture_output=True, text=True,
    )


def test_selftest_types_all_pass():
    r = run_selftest()
    out = r.stdout + r.stderr
    assert "FAIL" not in out, out
    m = re.search(r"(\d+)/(\d+) type-engine cases passed", out)
    assert m, out
    passed, total = int(m.group(1)), int(m.group(2))
    assert passed == total and total >= MIN_CASES, (passed, total, out)
    assert r.returncode == 0, (r.returncode, out)


if __name__ == "__main__":
    test_selftest_types_all_pass()
    print("PASS test_selftest_types_all_pass")
