#!/usr/bin/env python3
"""Control-flow lazy sinking: pure zero-arg calls move to their unique use."""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"

BOOM = """fn boom() -> int:
    z : ., mut = 0
    return 1 / z
"""

IF_FALSE = BOOM + """
fn main() -> int:
    v := boom()
    c : ., mut = 0
    if c == 1:
        return v
    return 0
"""

IF_TRUE = BOOM + """
fn main() -> int:
    v := boom()
    c : ., mut = 1
    if c == 1:
        return v
    return 0
"""

LOOP_FALSE = BOOM + """
fn main() -> int:
    i : ., mut = 0
    total : ., mut = 0
    while i < 2:
        v := boom()
        if i == 99:
            total = total + v
        i = i + 1
    return total
"""

MULTI_USE = BOOM + """
fn main() -> int:
    v := boom()
    c : ., mut = 0
    if c == 1:
        return v
    if c == 2:
        return v
    return 0
"""

STRAIGHT = BOOM + """
fn main() -> int:
    v := boom()
    return v
"""

ARG_CONST = """fn boom(x: int) -> int:
    return 7 / (x - 1)
""" + """
fn main() -> int:
    v := boom(1)
    c : ., mut = 0
    if c == 1:
        return v
    return 0
"""

ARG_TRUE = """fn boom(x: int) -> int:
    return 7 / (x - 1)
""" + """
fn main() -> int:
    v := boom(1)
    c : ., mut = 1
    if c == 1:
        return v
    return 0
"""

ARG_MUTATED = """fn boom(x: int) -> int:
    return 7 / (x - 1)
""" + """
fn main() -> int:
    x : ., mut = 1
    v := boom(x)
    x = 2
    c : ., mut = 0
    if c == 1:
        return v
    return 0
"""

BINARY_USE = BOOM + """
fn main() -> int:
    v := boom()
    c : ., mut = 0
    if c == 1:
        return v + 1
    return 0
"""

FOR_LOOP = BOOM + """
fn main() -> int:
    total : ., mut = 0
    for i in 0..2:
        v := boom()
        if i == 99:
            total = total + v
    return total
"""

IMPURE_GLOBAL = """g_effect : int, mut = 0

fn effect() -> int:
    g_effect = 1
    return 7 / (1 - 1)
""" + """
fn main() -> int:
    v := effect()
    c : ., mut = 0
    if c == 1:
        return v
    return 0
"""

ALLOC_CALLEE = """fn make() -> int:
    a : [int; 2], mut
    a[0] = 1
    a[1] = 2
    return a[0]
""" + """
fn main() -> int:
    v := make()
    c : ., mut = 0
    if c == 1:
        return v
    return 0
"""


def run(cmd: list[str], timeout: int = 300) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=BASE, capture_output=True, text=True,
                          timeout=timeout)


def ccr(src: str) -> subprocess.CompletedProcess:
    with tempfile.NamedTemporaryFile("w", suffix=".cr", delete=False) as source:
        source.write(src)
        path = source.name
    out = Path(path).with_suffix(".ccr")
    try:
        return run([str(COREC), "ccr", "--dump-ir-text", path,
                    "-o", str(out)])
    finally:
        for p in (Path(path), out):
            try:
                p.unlink()
            except FileNotFoundError:
                pass


def build_run(src: str, expected: int) -> None:
    with tempfile.NamedTemporaryFile("w", suffix=".cr", delete=False) as source:
        source.write(src)
        path = source.name
    out = Path(path).with_suffix(".elf")
    try:
        result = run([str(COREC), "build", "--static", path, "-o", str(out)])
        diag = result.stdout + result.stderr
        assert result.returncode == 0, f"build failed:\n{diag}"
        native = run([str(out)], timeout=60)
        assert native.returncode == expected, (
            f"run rc={native.returncode}, expected {expected}\n"
            + native.stdout + native.stderr)
    finally:
        for p in (Path(path), out):
            try:
                p.unlink()
            except FileNotFoundError:
                pass


def main_section(diag: str) -> str:
    if "Function: main" not in diag:
        return ""
    return diag.split("Function: main", 1)[1].split("Function: ", 1)[0]


def call_is_in_block(diag: str, name: str) -> bool:
    body = main_section(diag)
    seen_block = False
    for line in body.splitlines():
        if line.startswith("  Block:"):
            seen_block = True
        if "call" in line and name in line:
            return seen_block
    return False


def test_if_false_sinks_and_returns():
    result = ccr(IF_FALSE)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert call_is_in_block(diag, "boom"), diag
    build_run(IF_FALSE, 0)


def test_if_true_executes_at_use():
    result = ccr(IF_TRUE)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert call_is_in_block(diag, "boom"), diag
    build_run(IF_TRUE, 1)


def test_loop_conditional_sinks():
    result = ccr(LOOP_FALSE)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert call_is_in_block(diag, "boom"), diag
    build_run(LOOP_FALSE, 0)


def test_multi_use_stays_eager():
    result = ccr(MULTI_USE)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert not call_is_in_block(diag, "boom"), diag
    build_run(MULTI_USE, 1)


def test_straight_line_stays_eager():
    result = ccr(STRAIGHT)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert not call_is_in_block(diag, "boom"), diag
    build_run(STRAIGHT, 1)


def test_allocating_callee_stays_eager():
    result = ccr(ALLOC_CALLEE)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert not call_is_in_block(diag, "make"), diag
    build_run(ALLOC_CALLEE, 0)


def test_binary_use_sinks():
    result = ccr(BINARY_USE)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert call_is_in_block(diag, "boom"), diag
    build_run(BINARY_USE, 0)


def test_for_conditional_sinks():
    result = ccr(FOR_LOOP)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert call_is_in_block(diag, "boom"), diag
    build_run(FOR_LOOP, 0)


def test_impure_callee_stays_eager():
    result = ccr(IMPURE_GLOBAL)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert not call_is_in_block(diag, "effect"), diag
    build_run(IMPURE_GLOBAL, 1)


def test_constant_argument_sinks():
    result = ccr(ARG_CONST)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert call_is_in_block(diag, "boom"), diag
    build_run(ARG_CONST, 0)


def test_constant_argument_true_path_runs():
    result = ccr(ARG_TRUE)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert call_is_in_block(diag, "boom"), diag
    build_run(ARG_TRUE, 1)


def test_mutated_argument_stays_eager():
    result = ccr(ARG_MUTATED)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert not call_is_in_block(diag, "boom"), diag
    build_run(ARG_MUTATED, 1)


if __name__ == "__main__":
    tests = [
        test_if_false_sinks_and_returns,
        test_if_true_executes_at_use,
        test_loop_conditional_sinks,
        test_multi_use_stays_eager,
        test_straight_line_stays_eager,
        test_allocating_callee_stays_eager,
        test_binary_use_sinks,
        test_for_conditional_sinks,
        test_impure_callee_stays_eager,
        test_constant_argument_sinks,
        test_constant_argument_true_path_runs,
        test_mutated_argument_stays_eager,
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
