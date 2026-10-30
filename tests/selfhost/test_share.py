#!/usr/bin/env python3
"""V2.3 read-only share regression.

A top-level IF allocates one scalar array into its child slot. When every use
after the IF is a read inside a consumer loop, the child slot is kept live and
reset after the last consumer loop instead of copying the array to the parent
(V2.2 merge).
"""

import os
import subprocess
import tempfile

BASE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def _run(args, timeout=300):
    return subprocess.run(args, capture_output=True, text=True, cwd=BASE, timeout=timeout)


def ccr(src):
    with tempfile.NamedTemporaryFile("w", suffix=".cr", delete=False) as source:
        source.write(src)
        path = source.name
    out = os.path.splitext(path)[0] + ".ccr"
    try:
        return _run(["./build/corec", "ccr", "--dump-region-plan", "--dump-ir-text", path, "-o", out])
    finally:
        for p in (path, out):
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass


def build_run(src, expected):
    with tempfile.NamedTemporaryFile("w", suffix=".cr", delete=False) as source:
        source.write(src)
        path = source.name
    out = os.path.splitext(path)[0] + ".elf"
    try:
        result = _run(["./build/corec", "build", "--static", path, "-o", out])
        diag = result.stdout + result.stderr
        assert result.returncode == 0, f"build failed:\n{diag}"
        run = _run([out], timeout=60)
        assert run.returncode == expected, f"run rc={run.returncode}, expected {expected}"
    finally:
        for p in (path, out):
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass


def has_share(diag):
    return any(ln.startswith("share ") for ln in diag.splitlines())


def has_merge(diag):
    return any(ln.startswith("merge ") for ln in diag.splitlines())


TWO_READERS = """fn main() -> int:
    arr : [int; 2], mut
    arr[0] = 5
    arr[1] = 6
    y : ., mut = 1
    total : ., mut = 0
    if y < 2:
        b : [int; 2], mut
        b[0] = 7
        b[1] = 8
        arr = b
    i : ., mut = 0
    while i < 2:
        total = total + arr[0]
        i = i + 1
    j : ., mut = 0
    while j < 2:
        total = total + arr[1]
        j = j + 1
    big : [int; 2], mut
    big[0] = 3
    big[1] = 4
    return total + big[0] - 33
"""

FALSE_PATH = """fn main() -> int:
    arr : [int; 2], mut
    arr[0] = 5
    arr[1] = 6
    y : ., mut = 3
    total : ., mut = 0
    if y < 2:
        b : [int; 2], mut
        b[0] = 7
        b[1] = 8
        arr = b
    i : ., mut = 0
    while i < 2:
        total = total + arr[0]
        i = i + 1
    return total - 10
"""

ONE_LOOP = """fn main() -> int:
    arr : [int; 2], mut
    arr[0] = 5
    arr[1] = 6
    y : ., mut = 1
    total : ., mut = 0
    if y < 2:
        b : [int; 2], mut
        b[0] = 7
        b[1] = 8
        arr = b
    i : ., mut = 0
    while i < 2:
        total = total + arr[0]
        i = i + 1
    return total - 14
"""

FOR_READER = """fn main() -> int:
    arr : [int; 2], mut
    arr[0] = 5
    arr[1] = 6
    y : ., mut = 1
    total : ., mut = 0
    if y < 2:
        b : [int; 2], mut
        b[0] = 7
        b[1] = 8
        arr = b
    for i in 0..2:
        total = total + arr[0]
    return total - 14
"""

BREAK_READER = """fn main() -> int:
    arr : [int; 2], mut
    arr[0] = 5
    arr[1] = 6
    y : ., mut = 1
    total : ., mut = 0
    if y < 2:
        b : [int; 2], mut
        b[0] = 7
        b[1] = 8
        arr = b
    i : ., mut = 0
    while i < 2:
        total = total + arr[0]
        if i == 0:
            break
        i = i + 1
    return total - 7
"""

NESTED_CONSUMER_LOOP = """fn main() -> int:
    arr : [int; 2], mut
    arr[0] = 5
    arr[1] = 6
    y : ., mut = 1
    total : ., mut = 0
    if y < 2:
        b : [int; 2], mut
        b[0] = 7
        b[1] = 8
        arr = b
    i : ., mut = 0
    while i < 2:
        j : ., mut = 0
        while j < 2:
            total = total + arr[0]
            j = j + 1
        i = i + 1
    return total - 28
"""

READ_AFTER_LOOP = """fn main() -> int:
    arr : [int; 2], mut
    arr[0] = 5
    arr[1] = 6
    y : ., mut = 1
    total : ., mut = 0
    if y < 2:
        b : [int; 2], mut
        b[0] = 7
        b[1] = 8
        arr = b
    i : ., mut = 0
    while i < 2:
        total = total + arr[0]
        i = i + 1
    after := arr[0]
    return total + after - 21
"""

CALL_CONSUMER = """fn id(x: int) -> int:
    return x

fn main() -> int:
    arr : [int; 2], mut
    arr[0] = 5
    arr[1] = 6
    y : ., mut = 1
    total : ., mut = 0
    if y < 2:
        b : [int; 2], mut
        b[0] = 7
        b[1] = 8
        arr = b
    i : ., mut = 0
    while i < 2:
        total = total + id(arr[0])
        i = i + 1
    return total - 14
"""

NESTED_SPLIT_CONSUMER = """fn main() -> int:
    arr : [int; 2], mut
    arr[0] = 5
    arr[1] = 6
    y : ., mut = 1
    z : ., mut = 1
    total : ., mut = 0
    if y < 2:
        b : [int; 2], mut
        b[0] = 7
        b[1] = 8
        arr = b
    i : ., mut = 0
    while i < 2:
        if z < 2:
            a := [1, 2]
            total = total + a[0]
        total = total + arr[0]
        i = i + 1
    return total - 16
"""

SIBLING_BREAK_WINDOW = """fn main() -> int:
    arr : [int; 2], mut
    arr[0] = 5
    arr[1] = 6
    y : ., mut = 1
    total : ., mut = 0
    if y < 2:
        b : [int; 2], mut
        b[0] = 7
        b[1] = 8
        arr = b
    i : ., mut = 0
    while i < 2:
        break
    j : ., mut = 0
    while j < 2:
        total = total + arr[0]
        j = j + 1
    return total - 14
"""

LATER_UNRELATED_LOOP = """fn main() -> int:
    arr : [int; 2], mut
    arr[0] = 5
    arr[1] = 6
    y : ., mut = 1
    total : ., mut = 0
    if y < 2:
        b : [int; 2], mut
        b[0] = 7
        b[1] = 8
        arr = b
    i : ., mut = 0
    while i < 2:
        total = total + arr[0]
        i = i + 1
    other : ., mut = 0
    j : ., mut = 0
    while j < 2:
        other = other + j
        j = j + 1
    return total + other - 15
"""

NESTED_BREAK_CONSUMER = """fn main() -> int:
    arr : [int; 2], mut
    arr[0] = 5
    arr[1] = 6
    y : ., mut = 1
    total : ., mut = 0
    if y < 2:
        b : [int; 2], mut
        b[0] = 7
        b[1] = 8
        arr = b
    i : ., mut = 0
    while i < 2:
        j : ., mut = 0
        while j < 2:
            total = total + arr[0]
            break
        i = i + 1
    return total - 14
"""

IF_CONSUMER = """fn main() -> int:
    arr : [int; 2], mut
    arr[0] = 5
    arr[1] = 6
    y : ., mut = 1
    z : ., mut = 1
    total : ., mut = 0
    if y < 2:
        b : [int; 2], mut
        b[0] = 7
        b[1] = 8
        arr = b
    if z < 2:
        a : [int; 2], mut
        a[0] = 1
        a[1] = 2
        total = total + a[0] + arr[0]
    return total - 8
"""

WIDER_LABEL = """fn main() -> int:
    arr : [int; 2], mut
    arr[0] = 5
    arr[1] = 6
    y : ., mut = 1
    z : ., mut = 1
    total : ., mut = 0
    if y < 2:
        b : [int; 2], mut
        b[0] = 7
        b[1] = 8
        arr = b
    total = arr[0]
    if z < 2:
        total = total + 1
    return total - 8
"""

MULTI_SHARE = """fn main() -> int:
    a : [int; 2], mut
    a[0] = 5
    a[1] = 6
    b : [int; 2], mut
    b[0] = 5
    b[1] = 6
    y : ., mut = 1
    total : ., mut = 0
    if y < 2:
        ba : [int; 2], mut
        ba[0] = 7
        ba[1] = 8
        a = ba
    i : ., mut = 0
    while i < 2:
        total = total + a[0]
        i = i + 1
    if y < 2:
        bb : [int; 2], mut
        bb[0] = 9
        bb[1] = 10
        b = bb
    j : ., mut = 0
    while j < 2:
        total = total + b[0]
        j = j + 1
    return total - 32
"""

READONLY_CALL = """fn sum(a: [int; 2]) -> int:
    return a[0]

fn main() -> int:
    arr : [int; 2], mut
    arr[0] = 5
    arr[1] = 6
    y : ., mut = 1
    total : ., mut = 0
    if y < 2:
        b : [int; 2], mut
        b[0] = 7
        b[1] = 8
        arr = b
    i : ., mut = 0
    while i < 2:
        total = total + sum(arr)
        i = i + 1
    return total - 14
"""

WRITE_CALLEE = """fn bad(a: [int; 2]) -> int:
    a[0] = 9
    return a[0]

fn main() -> int:
    arr : [int; 2], mut
    arr[0] = 5
    arr[1] = 6
    y : ., mut = 1
    total : ., mut = 0
    if y < 2:
        b : [int; 2], mut
        b[0] = 7
        b[1] = 8
        arr = b
    i : ., mut = 0
    while i < 2:
        total = total + bad(arr)
        i = i + 1
    return total - 18
"""

ESCAPE_CALLEE = """g : [int; 2], mut = [0, 0]
fn save(a: [int; 2]) -> int:
    g = a
    return 0

fn main() -> int:
    arr : [int; 2], mut
    arr[0] = 5
    arr[1] = 6
    y : ., mut = 1
    total : ., mut = 0
    if y < 2:
        b : [int; 2], mut
        b[0] = 7
        b[1] = 8
        arr = b
    i : ., mut = 0
    while i < 2:
        total = total + save(arr)
        i = i + 1
    return total
"""

CURRENT_CALLEE = """import arena
g_current_arena : int, mut = -1
g_arena_pool_data : string, mut
g_arena_free_list : int, mut = -1
fn touch() -> int:
    if g_current_arena < 0:
        return 0
    return 0

fn main() -> int:
    arr : [int; 2], mut
    arr[0] = 5
    arr[1] = 6
    y : ., mut = 1
    total : ., mut = 0
    if y < 2:
        b : [int; 2], mut
        b[0] = 7
        b[1] = 8
        arr = b
    i : ., mut = 0
    while i < 2:
        total = total + arr[0] + touch()
        i = i + 1
    return total - 14
"""

LEAF_NO_ARRAY_CALL = """fn one() -> int:
    return 1

fn main() -> int:
    arr : [int; 2], mut
    arr[0] = 5
    arr[1] = 6
    y : ., mut = 1
    total : ., mut = 0
    if y < 2:
        b : [int; 2], mut
        b[0] = 7
        b[1] = 8
        arr = b
    i : ., mut = 0
    while i < 2:
        total = total + arr[0] + one()
        i = i + 1
    return total - 16
"""

WRITE_CONSUMER = """fn main() -> int:
    arr : ., mut = [5, 6]
    y : ., mut = 1
    total : ., mut = 0
    if y < 2:
        b : [int; 2], mut
        b[0] = 7
        b[1] = 8
        arr = b
    i : ., mut = 0
    while i < 2:
        arr[0] = 9
        total = total + arr[0]
        i = i + 1
    return total - 18
"""

STRAIGHT_READ = """fn main() -> int:
    arr : ., mut = [5, 6]
    y : ., mut = 1
    if y < 2:
        b : [int; 2], mut
        b[0] = 7
        b[1] = 8
        arr = b
    total := arr[0]
    return total - 7
"""

ALLOC_IN_WINDOW = """fn main() -> int:
    arr : ., mut = [5, 6]
    y : ., mut = 1
    total : ., mut = 0
    if y < 2:
        b : [int; 2], mut
        b[0] = 7
        b[1] = 8
        arr = b
    tmp := [1, 2]
    i : ., mut = 0
    while i < 2:
        total = total + arr[0] + tmp[0]
        i = i + 1
    return total - 16
"""

NESTED_IF = """fn main() -> int:
    arr : ., mut = [5, 6]
    y : ., mut = 1
    z : ., mut = 1
    if y < 2:
        if z < 2:
            arr = [7, 8]
    i : ., mut = 0
    total : ., mut = 0
    while i < 2:
        total = total + arr[0]
        i = i + 1
    return total - 14
"""

UNSAFE_CONSUMER = """fn main() -> int:
    arr : ., mut = [5, 6]
    y : ., mut = 1
    total : ., mut = 0
    if y < 2:
        b : [int; 2], mut
        b[0] = 7
        b[1] = 8
        arr = b
    unsafe:
        i : ., mut = 0
        while i < 2:
            total = total + arr[0]
            i = i + 1
    return total - 14
"""


def test_p1_share_two_readers():
    result = ccr(TWO_READERS)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert has_share(diag), diag
    assert not has_merge(diag), diag
    assert "_merge_copy" not in diag, diag
    assert not any(ln.startswith("clear ") for ln in diag.splitlines()), diag
    main_body = diag.split("Function: main", 1)[1]
    first_arena = next(ln for ln in main_body.splitlines() if "arena_new" in ln)
    assert "s1=48" in first_arena, first_arena
    build_run(TWO_READERS, 0)


def test_p2_write_consumer_blocks_share():
    result = ccr(WRITE_CONSUMER)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert not has_share(diag), diag
    build_run(WRITE_CONSUMER, 0)


def test_p3_straight_line_reader_blocks_share():
    result = ccr(STRAIGHT_READ)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert not has_share(diag), diag
    build_run(STRAIGHT_READ, 0)


def test_p4_parent_allocation_in_window_blocks_share():
    result = ccr(ALLOC_IN_WINDOW)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert not has_share(diag), diag
    build_run(ALLOC_IN_WINDOW, 0)


def test_p5_nested_if_blocks_share():
    result = ccr(NESTED_IF)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert not has_share(diag), diag
    build_run(NESTED_IF, 0)


def test_p6_unsafe_consumer_blocks_share():
    result = ccr(UNSAFE_CONSUMER)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert not has_share(diag), diag
    build_run(UNSAFE_CONSUMER, 0)



def test_p7_false_path_still_resets_share_slot():
    result = ccr(FALSE_PATH)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert has_share(diag), diag
    build_run(FALSE_PATH, 0)


def test_p8_single_consumer_loop():
    result = ccr(ONE_LOOP)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert has_share(diag), diag
    build_run(ONE_LOOP, 0)


def test_p9_for_consumer():
    result = ccr(FOR_READER)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert has_share(diag), diag
    build_run(FOR_READER, 0)


def test_p10_break_in_consumer_blocks_share():
    result = ccr(BREAK_READER)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert not has_share(diag), diag
    build_run(BREAK_READER, 0)


def test_p11_nested_consumer_loop_shares():
    # Nested loops with no non-local exits are now a valid wider window.
    result = ccr(NESTED_CONSUMER_LOOP)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert has_share(diag), diag
    build_run(NESTED_CONSUMER_LOOP, 0)


def test_p12_read_after_consumer_blocks_share():
    result = ccr(READ_AFTER_LOOP)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert not has_share(diag), diag
    build_run(READ_AFTER_LOOP, 0)



def test_p13_leaf_call_in_consumer_shares():
    # id(arr[0]) passes a scalar, not the shared pointer; the leaf callee is
    # clean, so the wider call proof allows share.
    result = ccr(CALL_CONSUMER)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert has_share(diag), diag
    build_run(CALL_CONSUMER, 0)


def test_p14_nested_split_consumer_allows_share():
    result = ccr(NESTED_SPLIT_CONSUMER)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert has_share(diag), diag
    assert not has_merge(diag), diag
    build_run(NESTED_SPLIT_CONSUMER, 0)



def test_p15_sibling_break_in_window_blocks_share():
    result = ccr(SIBLING_BREAK_WINDOW)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert not has_share(diag), diag
    build_run(SIBLING_BREAK_WINDOW, 0)



def test_p16_share_reset_before_later_unrelated_loop():
    result = ccr(LATER_UNRELATED_LOOP)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert has_share(diag), diag
    build_run(LATER_UNRELATED_LOOP, 0)



def test_p17_nested_break_in_consumer_window_blocks_share():
    result = ccr(NESTED_BREAK_CONSUMER)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert not has_share(diag), diag
    build_run(NESTED_BREAK_CONSUMER, 0)



def test_p18_split_if_consumer_shares():
    result = ccr(IF_CONSUMER)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert has_share(diag), diag
    build_run(IF_CONSUMER, 0)


def test_p19_wider_label_lcpd():
    result = ccr(WIDER_LABEL)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert has_share(diag), diag
    build_run(WIDER_LABEL, 0)


def test_p20_multiple_sequential_shares():
    result = ccr(MULTI_SHARE)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    shares = [ln for ln in diag.splitlines() if ln.startswith("share ")]
    assert len(shares) == 2, shares
    build_run(MULTI_SHARE, 0)



def test_p21_readonly_array_callee_shares():
    result = ccr(READONLY_CALL)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert has_share(diag), diag
    build_run(READONLY_CALL, 0)


def test_p22_writing_callee_blocks_share():
    result = ccr(WRITE_CALLEE)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert not has_share(diag), diag
    build_run(WRITE_CALLEE, 0)


def test_p23_escaping_callee_blocks_share():
    result = ccr(ESCAPE_CALLEE)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert not has_share(diag), diag
    build_run(ESCAPE_CALLEE, 0)


def test_p24_current_arena_callee_blocks_share():
    result = ccr(CURRENT_CALLEE)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert not has_share(diag), diag
    build_run(CURRENT_CALLEE, 0)


def test_p25_leaf_call_without_array_shares():
    result = ccr(LEAF_NO_ARRAY_CALL)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert has_share(diag), diag
    build_run(LEAF_NO_ARRAY_CALL, 0)


if __name__ == "__main__":
    tests = [
        test_p1_share_two_readers,
        test_p2_write_consumer_blocks_share,
        test_p3_straight_line_reader_blocks_share,
        test_p4_parent_allocation_in_window_blocks_share,
        test_p5_nested_if_blocks_share,
        test_p6_unsafe_consumer_blocks_share,
        test_p7_false_path_still_resets_share_slot,
        test_p8_single_consumer_loop,
        test_p9_for_consumer,
        test_p10_break_in_consumer_blocks_share,
        test_p11_nested_consumer_loop_shares,
        test_p12_read_after_consumer_blocks_share,
        test_p13_leaf_call_in_consumer_shares,
        test_p14_nested_split_consumer_allows_share,
        test_p15_sibling_break_in_window_blocks_share,
        test_p16_share_reset_before_later_unrelated_loop,
        test_p17_nested_break_in_consumer_window_blocks_share,
        test_p18_split_if_consumer_shares,
        test_p19_wider_label_lcpd,
        test_p20_multiple_sequential_shares,
        test_p21_readonly_array_callee_shares,
        test_p22_writing_callee_blocks_share,
        test_p23_escaping_callee_blocks_share,
        test_p24_current_arena_callee_blocks_share,
        test_p25_leaf_call_without_array_shares,
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
