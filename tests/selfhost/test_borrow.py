#!/usr/bin/env python3
"""Native self-hosted borrow checker regression tests."""

import os
import subprocess
import sys
import tempfile
from pathlib import Path


BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"


CASES = [
    (
        "immutable borrow then use original",
        """
fn main() -> int:
    x := 42
    r := &x
    y := x
    return y
""",
        True,
    ),
    (
        "mutable borrow then use original",
        """
fn main() -> int:
    x : ., mut = 42
    r := &mut x
    y := x
    return y
""",
        True,
    ),
    (
        "multiple immutable borrows allowed",
        """
fn main() -> int:
    x := 42
    r1 := &x
    r2 := &x
    return 0
""",
        False,
    ),
    (
        "immutable then mutable borrow",
        """
fn main() -> int:
    x : ., mut = 42
    r1 := &x
    r2 := &mut x
    return 0
""",
        True,
    ),
    (
        "borrow released after block scope exit",
        """
fn main() -> int:
    x := 42:
        r := &x
    y := x
    return y
""",
        False,
    ),
    (
        "normal copy use",
        """
fn main() -> int:
    x := 42
    y := x
    return y
""",
        False,
    ),
    (
        "mutable then immutable borrow",
        """
fn main() -> int:
    x : ., mut = 42
    r1 := &mut x
    r2 := &x
    return 0
""",
        True,
    ),
]


def run_case(name, source, expect_borrow_error):
    with tempfile.NamedTemporaryFile("w", suffix=".cr", delete=False) as src:
        src.write(source)
        src_path = src.name
    try:
        result = subprocess.run(
            [str(COREC), "check", src_path],
            cwd=BASE,
            capture_output=True,
            text=True,
            timeout=60,
        )
    finally:
        os.unlink(src_path)

    output = result.stdout + result.stderr
    has_borrow_error = "error[B" in output or "Cannot borrow" in output or "while it is borrowed" in output
    # F19（compcert-r4 波 3）：corec check 对诊断返回 1（修复前诊断后恒 0——
    # 与 check 命令「诊断即失败」的语义相悖）。断言随新契约更新：
    # 期望诊断的用例 → rc=1；无诊断用例 → rc=0。
    if result.returncode == (1 if expect_borrow_error else 0) and has_borrow_error == expect_borrow_error:
        state = "borrow error" if has_borrow_error else "no borrow error"
        print(f"[PASS] {name}: {state}")
        return True

    print(
        f"[FAIL] {name}: expected_borrow_error={expect_borrow_error}, "
        f"exit={result.returncode}"
    )
    print(output)
    return False


def main():
    if not COREC.exists():
        print(f"[FAIL] missing native compiler: {COREC}")
        return 1
    results = [run_case(*case) for case in CASES]
    passed = sum(results)
    print(f"{passed}/{len(results)} passed")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
