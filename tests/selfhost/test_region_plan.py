#!/usr/bin/env python3
"""V2.0 IF split regression.

Positive: an IF whose direct allocations stay inside gets `IR_ARENA_NEW`/`RESET`
and still produces the same runtime value. Negative: escape, return, call,
unsafe and nested-loop cases keep the v1 IR and value.
"""

import os
import subprocess
import tempfile

BASE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def _run(args, src, suffix):
    with tempfile.NamedTemporaryFile("w", suffix=".cr", delete=False) as source:
        source.write(src)
        source_path = source.name
    output_path = os.path.splitext(source_path)[0] + suffix
    try:
        result = subprocess.run(
            ["./build/corec", *args, source_path, "-o", output_path],
            capture_output=True, text=True, cwd=BASE, timeout=300,
        )
        return result, output_path, os.path.exists(output_path)
    finally:
        pass


def ccr(src):
    result, output_path, artifact = _run(["ccr", "--dump-region-plan", "--dump-ir-text"], src, ".ccr")
    try:
        os.unlink(output_path)
    except FileNotFoundError:
        pass
    return result, artifact


def build_run(src):
    result, binary, artifact = _run(["build", "--static"], src, ".elf")
    if result.returncode != 0 or not artifact:
        try:
            os.unlink(binary)
        except FileNotFoundError:
            pass
        return result, None
    run = subprocess.run([binary], capture_output=True, text=True, cwd=BASE, timeout=60)
    try:
        os.unlink(binary)
    except FileNotFoundError:
        pass
    return result, run.returncode


def assert_split(src, count):
    result, artifact = ccr(src)
    diagnostic = result.stdout + result.stderr
    assert result.returncode == 0, f"ccr failed:\n{diagnostic}"
    assert artifact, "ccr must produce an artifact"
    lines = [ln for ln in diagnostic.splitlines() if ln.startswith("split ")]
    assert len(lines) == count, f"expected {count} split lines, got {lines}\n{diagnostic}"
    return diagnostic


def assert_no_split(src):
    return assert_split(src, 0)


def assert_value(src, expected):
    result, rc = build_run(src)
    diagnostic = result.stdout + result.stderr
    assert result.returncode == 0, f"build failed:\n{diagnostic}"
    assert rc == expected, f"run rc={rc}, expected {expected}"


BASIC = """fn main() -> int:
    x : ., mut = 1
    total : ., mut = 0
    if x < 2:
        arr := [7, 8]
        total = arr[0]
    return total - 7
"""

ESCAPE = """fn main() -> int:
    seed := 0
    p : ., mut = &seed
    x : ., mut = 1
    if x < 2:
        arr := [7, 8]
        p = &arr[0]
    return *p - 7
"""

RETURN = """fn main() -> int:
    x : ., mut = 1
    if x < 2:
        arr := [7, 8]
        return arr[0] - 7
    return 0
"""

CALL = """fn sink(p: &int) -> int:
    return *p
fn main() -> int:
    x : ., mut = 1
    if x < 2:
        arr := [7, 8]
        sink(&arr[0])
    return 0
"""

UNSAFE = """fn main() -> int:
    x : ., mut = 1
    if x < 2:
        unsafe:
            arr := [7, 8]
            x = arr[0]
    return x - 7
"""

NESTED_LOOP = """fn main() -> int:
    x : ., mut = 1
    if x < 2:
        i : ., mut = 0
        while i < 1:
            arr := [7, 8]
            x = arr[0]
            i = i + 1
    return x - 7
"""

TWO_IFS = """fn main() -> int:
    x : ., mut = 1
    total : ., mut = 0
    if x < 2:
        a := [7, 8]
        total = total + a[0]
    if x < 2:
        b := [9, 10]
        total = total + b[0]
    return total - 16
"""


def test_p1_if_local_allocation_splits():
    diagnostic = assert_split(BASIC, 1)
    assert "arena_new" in diagnostic, diagnostic
    assert_value(BASIC, 0)


def test_p2_two_sequential_ifs_split():
    diagnostic = assert_split(TWO_IFS, 2)
    assert_value(TWO_IFS, 0)


def test_p3_escape_keeps_v1():
    assert_no_split(ESCAPE)
    assert_value(ESCAPE, 0)


def test_p4_return_keeps_v1():
    assert_no_split(RETURN)
    assert_value(RETURN, 0)


def test_p5_call_keeps_v1():
    assert_no_split(CALL)
    assert_value(CALL, 0)


def test_p6_unsafe_keeps_v1():
    assert_no_split(UNSAFE)
    assert_value(UNSAFE, 0)


def test_p7_nested_loop_keeps_v1():
    assert_no_split(NESTED_LOOP)
    assert_value(NESTED_LOOP, 0)


def test_p8_no_plan_program_unchanged():
    src = "fn main() -> int:\n    return 7\n"
    assert_no_split(src)
    assert_value(src, 7)


if __name__ == "__main__":
    tests = [
        test_p1_if_local_allocation_splits,
        test_p2_two_sequential_ifs_split,
        test_p3_escape_keeps_v1,
        test_p4_return_keeps_v1,
        test_p5_call_keeps_v1,
        test_p6_unsafe_keeps_v1,
        test_p7_nested_loop_keeps_v1,
        test_p8_no_plan_program_unchanged,
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
