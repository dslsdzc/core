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

ALLOC_ESCAPE = """g_arr : [int; 2], mut = [0, 0]

fn leak() -> int:
    a : [int; 2], mut
    a[0] = 1
    a[1] = 2
    g_arr = a
    return 7 / (1 - 1)
""" + """
fn main() -> int:
    v := leak()
    c : ., mut = 0
    if c == 1:
        return v
    return 0
"""

LOOP_MEMO = """fn boom(x: int) -> int:
    return 7 / (x - 1)
""" + """
fn main() -> int:
    x : ., mut = 1
    i : ., mut = 0
    total : ., mut = 0
    while i < 2:
        v := boom(x)
        if i == 99:
            total = total + v
        i = i + 1
    return total
"""

LOOP_MEMO_TRUE = """fn boom(x: int) -> int:
    return 7 / (x - 1)
""" + """
fn main() -> int:
    x : ., mut = 1
    i : ., mut = 0
    while i < 2:
        v := boom(x)
        if i == 1:
            return v
        i = i + 1
    return 0
"""

LOOP_MEMO_MUTATED = """fn boom(x: int) -> int:
    return 7 / (x - 1)
""" + """
fn main() -> int:
    x : ., mut = 1
    i : ., mut = 0
    while i < 2:
        v := boom(x)
        x = 2
        if i == 99:
            return v
        i = i + 1
    return 0
"""

MULTI_USE_TRUE = BOOM + """
fn main() -> int:
    v := boom()
    c : ., mut = 1
    if c == 1:
        return v
    if c == 1:
        return v
    return 0
"""

SITE_MEMO_SUM = """fn bump(x: int) -> int:
    return x + 1
""" + """
fn main() -> int:
    total : ., mut = 0
    v := bump(1)
    c : ., mut = 1
    if c == 1:
        total = total + v
    if c == 1:
        total = total + v
    return total - 4
"""

SITE_MEMO_ARG = """fn ident(x: int) -> int:
    return x
""" + """
fn main() -> int:
    x : ., mut = 1
    v := ident(x)
    x = 2
    c : ., mut = 1
    if c == 1:
        return v
    if c == 1:
        return v
    return 0
"""

SITE_MEMO_POINTER = """fn read(p: *int) -> int:
    return *p
""" + """
fn main() -> int:
    arr := [5, 6]
    v := read(&arr[0])
    c : ., mut = 1
    if c == 1:
        return v
    if c == 1:
        return v
    return 0
"""

SITE_MEMO_POINTER_MUTATED = """fn read(p: *int) -> int:
    return *p
""" + """
fn main() -> int:
    arr := [5, 6]
    v := read(&arr[0])
    arr[0] = 9
    c : ., mut = 1
    if c == 1:
        return v
    if c == 1:
        return v
    return 0
"""

LOOP_SITE_MEMO = """fn ident(x: int) -> int:
    return x
""" + """
fn main() -> int:
    i : ., mut = 0
    total : ., mut = 0
    while i < 2:
        x : ., mut = i
        v := ident(x)
        if i == 1:
            total = total + v
        if i == 1:
            total = total + v
        i = i + 1
    return total - 2
"""

DOUBLE_ASSIGN = """fn bump(x: int) -> int:
    return x + 1
""" + """
fn main() -> int:
    v : ., mut = 0
    v = bump(1)
    v = bump(2)
    return v - 3
"""

LOOP_GLOBAL_MUTATED = """g : int, mut = 0

fn read(x: int) -> int:
    return x

fn bumpg():
    g = g + 1
""" + """
fn main() -> int:
    i : ., mut = 0
    total : ., mut = 0
    while i < 2:
        v := read(g)
        bumpg()
        if i == 1:
            total = total + v
        if i == 1:
            total = total + v
        i = i + 1
    return total - 2
"""

GLOBAL_READER = """g : int, mut = 0

fn cur() -> int:
    return g

fn bumpg():
    g = g + 1
""" + """
fn main() -> int:
    i : ., mut = 0
    total : ., mut = 0
    while i < 2:
        v := cur()
        bumpg()
        if i == 1:
            total = total + v
        if i == 1:
            total = total + v
        i = i + 1
    return total - 2
"""

POINTER_READ = """fn read(p: *int) -> int:
    return *p
""" + """
fn main() -> int:
    arr := [5, 6]
    v := read(&arr[0])
    c : ., mut = 0
    if c == 1:
        return v
    return 0
"""

POINTER_READ_TRUE = """fn read(p: *int) -> int:
    return *p
""" + """
fn main() -> int:
    arr := [5, 6]
    v := read(&arr[0])
    c : ., mut = 1
    if c == 1:
        return v
    return 0
"""

POINTER_READ_MUTATED = """fn read(p: *int) -> int:
    return *p
""" + """
fn main() -> int:
    arr := [5, 6]
    v := read(&arr[0])
    arr[0] = 9
    c : ., mut = 1
    if c == 1:
        return v
    return 0
"""

ARRAY_READ = """fn first(a: [int; 2]) -> int:
    return a[0]
""" + """
fn main() -> int:
    arr : [int; 2], mut = [1, 2]
    v := first(arr)
    c : ., mut = 0
    if c == 1:
        return v
    return 0
"""

ARRAY_READ_TRUE = """fn first(a: [int; 2]) -> int:
    return a[0]
""" + """
fn main() -> int:
    arr : [int; 2], mut = [1, 2]
    v := first(arr)
    c : ., mut = 1
    if c == 1:
        return v
    return 0
"""

ARRAY_READ_MUTATED = """fn first(a: [int; 2]) -> int:
    return a[0]
""" + """
fn main() -> int:
    arr : [int; 2], mut = [1, 2]
    v := first(arr)
    arr[0] = 9
    c : ., mut = 1
    if c == 1:
        return v
    return 0
"""

LOOP_POINTER_MEMO = """fn read(p: *int) -> int:
    return *p
""" + """
fn main() -> int:
    arr := [5, 6]
    p := &arr[0]
    i : ., mut = 0
    total : ., mut = 0
    while i < 2:
        v := read(p)
        if i == 5:
            total = total + v
        i = i + 1
    return total
"""

LOOP_POINTER_MEMO_MUTATED = """fn read(p: *int) -> int:
    return *p
""" + """
fn main() -> int:
    arr := [5, 6]
    p := &arr[0]
    i : ., mut = 0
    while i < 2:
        v := read(p)
        arr[0] = i
        if i == 1:
            return v
        i = i + 1
    return 0
"""

SCALAR_POINTER_READ = """fn read(p: *int) -> int:
    return *p
""" + """
fn main() -> int:
    x : ., mut = 5
    v := read(&x)
    c : ., mut = 0
    if c == 1:
        return v
    return 0
"""

MEMO_USE = BOOM + """
fn main() -> int:
    v := boom()
    c : ., mut = 0
    if c == 1:
        return v + v
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


def test_multi_use_memoizes():
    result = ccr(MULTI_USE)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert call_is_in_block(diag, "boom"), diag
    assert "_lazy_flag" in diag, diag
    build_run(MULTI_USE, 0)


def test_multi_use_true_path_executes():
    result = ccr(MULTI_USE_TRUE)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert "_lazy_flag" in diag, diag
    build_run(MULTI_USE_TRUE, 1)


def test_site_memo_reads_once_in_both_branches():
    result = ccr(SITE_MEMO_SUM)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert "_lazy_flag" in diag, diag
    build_run(SITE_MEMO_SUM, 0)


def test_site_memo_captures_argument():
    result = ccr(SITE_MEMO_ARG)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert "_lazy_flag" in diag, diag
    build_run(SITE_MEMO_ARG, 1)


def test_site_memo_pointer_argument():
    result = ccr(SITE_MEMO_POINTER)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert "_lazy_flag" in diag, diag
    build_run(SITE_MEMO_POINTER, 5)


def test_site_memo_pointer_mutation_rejected():
    result = ccr(SITE_MEMO_POINTER_MUTATED)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert "_lazy_flag" not in diag, diag
    build_run(SITE_MEMO_POINTER_MUTATED, 5)


def test_loop_site_memo_per_iteration():
    result = ccr(LOOP_SITE_MEMO)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert "_lazy_flag" in diag, diag
    build_run(LOOP_SITE_MEMO, 0)


def test_straight_line_stays_eager():
    result = ccr(STRAIGHT)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert not call_is_in_block(diag, "boom"), diag
    build_run(STRAIGHT, 1)


def test_local_allocating_callee_sinks():
    result = ccr(ALLOC_CALLEE)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert call_is_in_block(diag, "make"), diag
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


def test_mutated_argument_is_captured():
    result = ccr(ARG_MUTATED)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert call_is_in_block(diag, "boom"), diag
    build_run(ARG_MUTATED, 0)


def test_same_block_multi_use_memoizes():
    result = ccr(MEMO_USE)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert call_is_in_block(diag, "boom"), diag
    body = main_section(diag)
    assert body.count("call boom()") == 1, body
    build_run(MEMO_USE, 0)


def test_escaping_allocation_callee_stays_eager():
    result = ccr(ALLOC_ESCAPE)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert not call_is_in_block(diag, "leak"), diag
    build_run(ALLOC_ESCAPE, 1)


def test_loop_invariant_memoizes():
    result = ccr(LOOP_MEMO)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert "_lazy_flag" in diag, diag
    assert call_is_in_block(diag, "boom"), diag
    build_run(LOOP_MEMO, 0)


def test_loop_memo_true_path_executes_once():
    result = ccr(LOOP_MEMO_TRUE)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert "_lazy_flag" in diag, diag
    build_run(LOOP_MEMO_TRUE, 1)


def test_loop_memo_mutated_arg_rejected():
    result = ccr(LOOP_MEMO_MUTATED)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert "_lazy_flag" not in diag, diag
    build_run(LOOP_MEMO_MUTATED, 0)


def test_pointer_argument_sinks():
    result = ccr(POINTER_READ)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert call_is_in_block(diag, "read"), diag
    build_run(POINTER_READ, 0)


def test_pointer_argument_true_path_reads_original_value():
    result = ccr(POINTER_READ_TRUE)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert call_is_in_block(diag, "read"), diag
    build_run(POINTER_READ_TRUE, 5)


def test_pointer_argument_mutation_keeps_eager_value():
    result = ccr(POINTER_READ_MUTATED)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert not call_is_in_block(diag, "read"), diag
    build_run(POINTER_READ_MUTATED, 5)


def test_array_argument_sinks():
    result = ccr(ARRAY_READ)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert call_is_in_block(diag, "first"), diag
    build_run(ARRAY_READ, 0)


def test_array_argument_true_path_reads_original_value():
    result = ccr(ARRAY_READ_TRUE)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert call_is_in_block(diag, "first"), diag
    build_run(ARRAY_READ_TRUE, 1)


def test_array_argument_mutation_keeps_eager_value():
    result = ccr(ARRAY_READ_MUTATED)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert not call_is_in_block(diag, "first"), diag
    build_run(ARRAY_READ_MUTATED, 1)


def test_loop_pointer_argument_memoizes():
    result = ccr(LOOP_POINTER_MEMO)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert "_lazy_flag" in diag, diag
    build_run(LOOP_POINTER_MEMO, 0)


def test_loop_pointer_argument_mutation_rejected():
    result = ccr(LOOP_POINTER_MEMO_MUTATED)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert "_lazy_flag" not in diag, diag
    build_run(LOOP_POINTER_MEMO_MUTATED, 0)


def test_untracked_scalar_pointer_stays_eager():
    result = ccr(SCALAR_POINTER_READ)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert not call_is_in_block(diag, "read"), diag
    build_run(SCALAR_POINTER_READ, 0)


def test_double_assignment_keeps_latest_def():
    result = ccr(DOUBLE_ASSIGN)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    body = main_section(diag)
    assert body.count("call bump(") == 2, body
    build_run(DOUBLE_ASSIGN, 0)


def test_loop_global_argument_uses_site_value():
    result = ccr(LOOP_GLOBAL_MUTATED)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    # The global may change across iterations, so it cannot be hoisted with
    # the loop memo. A site memo captures the value at each call site.
    assert "_lazy_flag" in diag, diag
    build_run(LOOP_GLOBAL_MUTATED, 0)


def test_global_reading_callee_stays_eager():
    result = ccr(GLOBAL_READER)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert "_lazy_flag" not in diag, diag
    body = main_section(diag)
    # The eager call stays at the loop body head, before bumpg(); sinking it
    # into the if would move it after bumpg().
    assert body.index("call cur(") < body.index("call bumpg("), body
    build_run(GLOBAL_READER, 0)


if __name__ == "__main__":
    tests = [
        test_if_false_sinks_and_returns,
        test_if_true_executes_at_use,
        test_loop_conditional_sinks,
        test_multi_use_memoizes,
        test_multi_use_true_path_executes,
        test_site_memo_reads_once_in_both_branches,
        test_site_memo_captures_argument,
        test_site_memo_pointer_argument,
        test_site_memo_pointer_mutation_rejected,
        test_loop_site_memo_per_iteration,
        test_double_assignment_keeps_latest_def,
        test_loop_global_argument_uses_site_value,
        test_global_reading_callee_stays_eager,
        test_straight_line_stays_eager,
        test_local_allocating_callee_sinks,
        test_binary_use_sinks,
        test_for_conditional_sinks,
        test_impure_callee_stays_eager,
        test_constant_argument_sinks,
        test_constant_argument_true_path_runs,
        test_mutated_argument_is_captured,
        test_same_block_multi_use_memoizes,
        test_escaping_allocation_callee_stays_eager,
        test_loop_invariant_memoizes,
        test_loop_memo_true_path_executes_once,
        test_loop_memo_mutated_arg_rejected,
        test_pointer_argument_sinks,
        test_pointer_argument_true_path_reads_original_value,
        test_pointer_argument_mutation_keeps_eager_value,
        test_array_argument_sinks,
        test_array_argument_true_path_reads_original_value,
        test_array_argument_mutation_keeps_eager_value,
        test_loop_pointer_argument_memoizes,
        test_loop_pointer_argument_mutation_rejected,
        test_untracked_scalar_pointer_stays_eager,
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
