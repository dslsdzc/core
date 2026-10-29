#!/usr/bin/env python3
"""V2.1 early-clear regression (conservative straight-line suffix)."""

import os
import subprocess
import tempfile

BASE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def run_ccr(src):
    with tempfile.NamedTemporaryFile("w", suffix=".cr", delete=False) as source:
        source.write(src)
        path = source.name
    out = os.path.splitext(path)[0] + ".ccr"
    try:
        result = subprocess.run(
            ["./build/corec", "ccr", "--dump-region-plan", "--dump-ir-text", path, "-o", out],
            capture_output=True, text=True, cwd=BASE, timeout=300,
        )
        return result
    finally:
        for p in (path, out):
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass


def run_program(src, expected):
    with tempfile.NamedTemporaryFile("w", suffix=".cr", delete=False) as source:
        source.write(src)
        path = source.name
    out = os.path.splitext(path)[0] + ".elf"
    try:
        result = subprocess.run(
            ["./build/corec", "build", "--static", path, "-o", out],
            capture_output=True, text=True, cwd=BASE, timeout=300,
        )
        diag = result.stdout + result.stderr
        assert result.returncode == 0, f"build failed:\n{diag}"
        run = subprocess.run([out], capture_output=True, text=True, cwd=BASE, timeout=60)
        assert run.returncode == expected, f"run rc={run.returncode}, expected {expected}"
    finally:
        for p in (path, out):
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass


POSITIVE = """fn sink(p: &int) -> int:
    return *p
fn main() -> int:
    a := [1, 2]
    x := a[0]
    y : ., mut = 1
    if y < 2:
        z := [3, 4]
        sink(&z[0])
    w := [5, 6]
    return x + w[0] - 6
"""

ESCAPE = """fn sink(p: &int) -> int:
    return *p
fn main() -> int:
    a := [1, 2]
    p : ., mut = &a[0]
    y : ., mut = 1
    if y < 2:
        z := [3, 4]
        sink(&z[0])
    return *p
"""

NO_REUSE = """fn main() -> int:
    a := [1, 2]
    return a[0] - 1
"""

BACKEDGE = """fn main() -> int:
    a := [1, 2]
    i : ., mut = 0
    total : ., mut = 0
    while i < 1:
        x := a[0]
        if x == 1:
            z := [3, 4]
            total = total + z[0]
        i = i + 1
    return total - 3
"""


def test_p1_early_clear_emitted():
    result = run_ccr(POSITIVE)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert any(ln.startswith("clear ") for ln in diag.splitlines()), diag
    assert "arena_clear" in diag, diag
    run_program(POSITIVE, 0)


def test_p2_pointer_used_after_keeps_v1():
    result = run_ccr(ESCAPE)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert not any(ln.startswith("clear ") for ln in diag.splitlines()), diag
    run_program(ESCAPE, 1)


def test_p3_no_later_allocation_no_clear():
    result = run_ccr(NO_REUSE)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert not any(ln.startswith("clear ") for ln in diag.splitlines()), diag
    run_program(NO_REUSE, 0)


def test_p4_loop_backedge_no_clear():
    result = run_ccr(BACKEDGE)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert not any(ln.startswith("clear ") for ln in diag.splitlines()), diag
    run_program(BACKEDGE, 0)


if __name__ == "__main__":
    tests = [
        test_p1_early_clear_emitted,
        test_p2_pointer_used_after_keeps_v1,
        test_p3_no_later_allocation_no_clear,
        test_p4_loop_backedge_no_clear,
    ]
    failures = 0
    for test in tests:
        try:
            test()
            print(f"PASS {test.__name__}")
        except AssertionError as error:
            failures += 1
            print(f"FAIL {test.__name__}: {error}")
        except Exception as error:  # noqa: BLE001
            failures += 1
            print(f"ERROR {test.__name__}: {error!r}")
    print(f"{len(tests) - failures}/{len(tests)} passed")
    raise SystemExit(1 if failures else 0)
