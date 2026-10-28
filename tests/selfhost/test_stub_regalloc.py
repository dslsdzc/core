#!/usr/bin/env python3
"""Runtime-stub register allocation self test (corec selftest-stub-regalloc).

The stub allocator is the same mapping instance as the compiler's register
allocator, only smaller: virtual registers are entries, the instruction-order
interval is the live interval, interval intersection is coexistence, physical
registers are locations, and spill slots are home slots.

The case table lives in src/compiler/stub_regalloc_selftest.cr. This test only
checks the contract: every case PASS, no FAIL, the count line adds up, rc = 0,
and the number of cases never silently shrinks.
"""

import re
import subprocess
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"

# Lower bound on the case table. Every case pins one obligation:
#   1. disjoint intervals share a register
#   2. overlapping intervals need distinct registers
#   3. register exhaustion spills instead of failing
#   4. spill slots are distinct
#   5. a pinned register is never given to another overlapping entry
#   6. two pins of one entry must agree
#   7. a pin outside the target register file is rejected
#   8. a read-only entry starts at its first use
MIN_CASES = 9


def run_selftest():
    return subprocess.run(
        ["nice", "-n", "19", str(COREC), "selftest-stub-regalloc"],
        cwd=BASE, capture_output=True, text=True, timeout=120,
    )


def test_selftest_stub_regalloc_all_pass():
    r = run_selftest()
    out = r.stdout + r.stderr
    assert "FAIL" not in out, out
    m = re.search(r"(\d+)/(\d+) stub-regalloc cases passed", out)
    assert m, out
    passed, total = int(m.group(1)), int(m.group(2))
    assert passed == total and total >= MIN_CASES, (passed, total, out)
    assert r.returncode == 0, (r.returncode, out)


if __name__ == "__main__":
    test_selftest_stub_regalloc_all_pass()
    print("PASS test_selftest_stub_regalloc_all_pass")
