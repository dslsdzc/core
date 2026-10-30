#!/usr/bin/env python3
"""V2.2 merge-copy regression.

The candidate is a constant-size scalar array, a POD struct, or a POD tuple
stored directly into an outer local slot. One copy runs at the end of each
assigning branch and the outer slot is rebound there, so a non-assigning path
still sees the old value and no merge phi is needed. If/else branches may each
assign the same slot in one IF and share one parent copy.
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


def has_merge(diag):
    return any(ln.startswith("merge ") for ln in diag.splitlines())


def has_split(diag):
    return any(ln.startswith("split ") for ln in diag.splitlines())


BASIC = """fn main() -> int:
    arr : ., mut = [0, 0]
    y : ., mut = 1
    if y < 2:
        arr = [7, 8]
    return arr[0] - 7
"""

FALSE_PATH = """fn main() -> int:
    arr : ., mut = [5, 6]
    y : ., mut = 3
    if y < 2:
        arr = [7, 8]
    return arr[0] - 5
"""

ELSE_BRANCH = """fn main() -> int:
    arr : ., mut = [5, 6]
    y : ., mut = 3
    x : ., mut = 0
    if y < 2:
        x = 1
    else:
        arr = [9, 10]
    return arr[0] - 9 + x
"""

MUTATE = """fn main() -> int:
    arr : ., mut = [0, 0]
    y : ., mut = 1
    if y < 2:
        arr = [7, 8]
        arr[1] = 9
    arr[0] = 3
    return arr[0] + arr[1] - 12
"""

ALIAS = """fn main() -> int:
    arr : ., mut = [0, 0]
    y : ., mut = 1
    q : ., mut = arr
    if y < 2:
        arr = [7, 8]
    return q[0] + arr[0] - 7
"""

SLICE_ESCAPE = """fn main() -> int:
    arr : ., mut = [0, 0]
    y : ., mut = 1
    s : ., mut = arr[0..1]
    if y < 2:
        arr = [7, 8]
        s = arr[0..1]
    return s[0] - 7
"""

GLOBAL_ESCAPE = """g : [int; 2], mut = [0, 0]
fn main() -> int:
    arr : ., mut = [5, 6]
    y : ., mut = 1
    if y < 2:
        arr = [7, 8]
        g = arr
    return g[0] - 7
"""

LOOP_ANCESTOR = """fn main() -> int:
    arr : ., mut = [5, 6]
    i : ., mut = 0
    while i < 2:
        if i == 1:
            arr = [7, 8]
        i = i + 1
    return arr[0] - 7
"""

NESTED_LOOP = """fn main() -> int:
    arr : ., mut = [5, 6]
    y : ., mut = 1
    z : ., mut = 1
    if y < 2:
        i : ., mut = 0
        while i < 1:
            if z < 2:
                arr = [7, 8]
            i = i + 1
    return arr[0] - 7
"""

INNER_LOOP = """fn main() -> int:
    arr : ., mut = [5, 6]
    y : ., mut = 1
    total : ., mut = 0
    if y < 2:
        arr = [7, 8]
        i : ., mut = 0
        while i < 2:
            total = total + arr[0]
            i = i + 1
    return total + arr[0] - 21
"""

BRANCH_RETURN = """fn main() -> int:
    arr : ., mut = [5, 6]
    y : ., mut = 1
    if y < 2:
        arr = [7, 8]
        return arr[0] - 7
    return arr[0] - 5
"""

NESTED_MERGE_OUTER_SPLIT = """fn main() -> int:
    arr : ., mut = [5, 6]
    y : ., mut = 1
    z : ., mut = 1
    total : ., mut = 0
    if y < 2:
        tmp := [1, 2]
        total = tmp[0]
        if z < 2:
            arr = [7, 8]
    return arr[0] + total - 8
"""

NESTED_MERGE_PLAIN = """fn main() -> int:
    arr : ., mut = [5, 6]
    y : ., mut = 1
    z : ., mut = 1
    if y < 2:
        if z < 2:
            arr = [7, 8]
        arr[1] = 9
    return arr[0] + arr[1] - 16
"""

KNOWN_SIZE = """fn main() -> int:
    arr : [int; 2], mut
    arr[0] = 5
    arr[1] = 6
    y : ., mut = 1
    if y < 2:
        b : [int; 2], mut
        b[0] = 7
        b[1] = 8
        arr = b
    return arr[0] - 7
"""

KNOWN_SIZE_AFTER = """fn main() -> int:
    arr : [int; 2], mut
    arr[0] = 5
    arr[1] = 6
    y : ., mut = 1
    if y < 2:
        b : [int; 2], mut
        b[0] = 7
        b[1] = 8
        arr = b
    c : [int; 2], mut
    c[0] = 3
    c[1] = 4
    return arr[0] + c[0] - 10
"""

NESTED_ESCAPE_ALLOC = """fn main() -> int:
    out : ., mut = [0, 0]
    q : ., mut = out
    arr : ., mut = [5, 6]
    y : ., mut = 1
    z : ., mut = 1
    if y < 2:
        arr = [7, 8]
        if z < 2:
            out = [9, 10]
    return out[0] + q[0] + arr[0] - 16
"""

NESTED_LOCAL = """fn main() -> int:
    arr : ., mut = [5, 6]
    y : ., mut = 1
    z : ., mut = 1
    total : ., mut = 0
    if y < 2:
        arr = [7, 8]
        if z < 2:
            a := [9, 10]
            total = a[0]
    return arr[0] + total - 16
"""


LEN_ONE = """fn main() -> int:
    a : ., mut = [0]
    y : ., mut = 1
    if y < 2:
        a = [7]
    return a[0] - 7
"""

LEN_64 = """fn main() -> int:
    arr : [int; 64], mut
    i : ., mut = 0
    while i < 64:
        arr[i] = 0
        i = i + 1
    y : ., mut = 1
    if y < 2:
        b : [int; 64], mut
        j : ., mut = 0
        while j < 64:
            b[j] = j
            j = j + 1
        arr = b
    return arr[0] + arr[63] - 63
"""

LEN_65 = """fn main() -> int:
    arr : [int; 65], mut
    i : ., mut = 0
    while i < 65:
        arr[i] = 0
        i = i + 1
    y : ., mut = 1
    if y < 2:
        b : [int; 65], mut
        j : ., mut = 0
        while j < 65:
            b[j] = j
            j = j + 1
        arr = b
    return arr[0] + arr[64] - 64
"""

LEN_ZERO = """fn main() -> int:
    a : [int; 0], mut
    y : ., mut = 1
    if y < 2:
        b : [int; 0], mut
        a = b
    return 0
"""

POD_STRUCT = """struct P:
    x: int, y: bool

fn main() -> int:
    p : P, mut = P { x = 1, y = true }
    c : ., mut = 0
    if c == 0:
        p = P { x = 7, y = false }
    if p.y:
        return p.x - 1
    return p.x - 7
"""

POD_STRUCT_FALSE = """struct P:
    x: int, y: bool

fn main() -> int:
    p : P, mut = P { x = 1, y = true }
    c : ., mut = 3
    if c == 0:
        p = P { x = 7, y = false }
    if p.y:
        return p.x - 1
    return p.x - 7
"""

POD_STRUCT_MUTATE = """struct P:
    x: int, y: bool

fn main() -> int:
    p : P, mut = P { x = 1, y = true }
    c : ., mut = 0
    if c == 0:
        p = P { x = 7, y = false }
        p.x = 9
    return p.x - 9
"""

POD_TUPLE = """fn main() -> int:
    t : ., mut = (1, 2)
    c : ., mut = 0
    if c == 0:
        t = (7, 8)
    return t . 0 + t . 1 - 15
"""

POD_TUPLE_FALSE = """fn main() -> int:
    t : ., mut = (1, 2)
    c : ., mut = 3
    if c == 0:
        t = (7, 8)
    return t . 0 + t . 1 - 3
"""

POD_TUPLE_MUTATE = """fn main() -> int:
    t : ., mut = (1, 2)
    c : ., mut = 0
    if c == 0:
        t = (7, 8)
        t . 0 = 9
    return t . 0 - 9
"""

POD_STRUCT_POINTER_FIELD = """struct H:
    a: [int; 2], b: int

fn main() -> int:
    h : H, mut = H { a = [1, 2], b = 3 }
    c : ., mut = 0
    if c == 0:
        h = H { a = [7, 8], b = 9 }
    return h.a[0] - 7
"""

POD_STRUCT_STRING_FIELD = """struct S:
    s: string, n: int

fn main() -> int:
    x : S, mut = S { s = "a", n = 1 }
    c : ., mut = 0
    if c == 0:
        x = S { s = "b", n = 2 }
    return x.n - 2
"""

POD_TUPLE_POINTER_ELEMENT = """fn main() -> int:
    t : ., mut = ([1, 2], 3)
    c : ., mut = 0
    if c == 0:
        t = ([7, 8], 9)
    return t . 0 [0] - 7
"""

BOTH_BRANCHES = """fn main() -> int:
    arr : ., mut = [5, 6]
    y : ., mut = 1
    if y < 2:
        arr = [7, 8]
    else:
        arr = [9, 10]
    return arr[0] - 7
"""

BOTH_BRANCHES_FALSE = """fn main() -> int:
    arr : ., mut = [5, 6]
    y : ., mut = 3
    if y < 2:
        arr = [7, 8]
    else:
        arr = [9, 10]
    return arr[0] - 9
"""

BOTH_BRANCH_MUTATE = """fn main() -> int:
    arr : [int; 2], mut
    arr[0] = 5
    arr[1] = 6
    y : ., mut = 1
    if y < 2:
        a : [int; 2], mut
        a[0] = 7
        a[1] = 8
        a[1] = a[0] + 1
        arr = a
    else:
        b : [int; 2], mut
        b[0] = 9
        b[1] = 10
        b[1] = b[0] + 1
        arr = b
    i : ., mut = 0
    total : ., mut = 0
    while i < 2:
        total = total + arr[1]
        i = i + 1
    return total - 16
"""

MULTI_MERGE = """fn main() -> int:
    a : ., mut = [0]
    b : ., mut = [0]
    y : ., mut = 1
    if y < 2:
        a = [1]
    if y < 2:
        b = [2]
    return a[0] + b[0] - 3
"""

DYN_INDEX = """fn main() -> int:
    arr : ., mut = [5, 6]
    y : ., mut = 1
    i : ., mut = 1
    if y < 2:
        arr = [7, 8]
        arr[i] = 9
    return arr[0] + arr[i] - 16
"""

PRE_USE = """fn main() -> int:
    arr : ., mut = [5, 6]
    y : ., mut = 1
    x : ., mut = 0
    if arr[0] == 5:
        x = arr[0]
        arr = [7, 8]
    return x + arr[0] - 12
"""

BOOL_ARRAY = """fn main() -> int:
    a : ., mut = [true, false]
    y : ., mut = 1
    if y < 2:
        a = [false, true]
    if a[1]:
        return 0
    return 1
"""

CHAR_ARRAY = """fn main() -> int:
    a : ., mut = ['x', 'y']
    y : ., mut = 1
    if y < 2:
        a = ['p', 'q']
    if a[0] == 'p':
        return 0
    return 1
"""

LOOP_AFTER = """fn main() -> int:
    arr : ., mut = [5, 6]
    y : ., mut = 1
    total : ., mut = 0
    if y < 2:
        arr = [7, 8]
    i : ., mut = 0
    while i < 2:
        total = total + arr[0]
        i = i + 1
    return total + arr[0] - 21
"""

STRING_ARRAY = """fn main() -> int:
    a : ., mut = ["x", "y"]
    y : ., mut = 1
    if y < 2:
        a = ["p", "q"]
    if a[0] == "p":
        return 0
    return 1
"""

NO_ESCAPE = """fn main() -> int:
    y : ., mut = 1
    total : ., mut = 0
    if y < 2:
        a := [7, 8]
        total = a[0]
    return total - 7
"""


def test_p1_merge_copy_value():
    result = ccr(BASIC)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert has_merge(diag), diag
    assert "_merge_copy" in diag, diag
    build_run(BASIC, 0)


def test_p2_false_path_keeps_old_array():
    result = ccr(FALSE_PATH)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert has_merge(diag), diag
    build_run(FALSE_PATH, 0)


def test_p3_else_branch_copy():
    result = ccr(ELSE_BRANCH)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert has_merge(diag), diag
    build_run(ELSE_BRANCH, 0)


def test_p4_copy_sees_branch_mutations():
    result = ccr(MUTATE)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert has_merge(diag), diag
    build_run(MUTATE, 0)


def test_p5_alias_blocks_merge():
    result = ccr(ALIAS)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert not has_merge(diag), diag
    build_run(ALIAS, 0)


def test_p6_slice_escape_blocks_merge():
    result = ccr(SLICE_ESCAPE)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert not has_merge(diag), diag
    build_run(SLICE_ESCAPE, 0)


def test_p7_global_store_blocks_merge():
    result = ccr(GLOBAL_ESCAPE)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert not has_merge(diag), diag
    build_run(GLOBAL_ESCAPE, 0)


def test_p8_loop_ancestor_blocks_merge():
    result = ccr(LOOP_ANCESTOR)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert not has_merge(diag), diag
    build_run(LOOP_ANCESTOR, 0)


def test_p9_nested_loop_alloc_blocks_merge():
    result = ccr(NESTED_LOOP)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert not has_merge(diag), diag
    build_run(NESTED_LOOP, 0)


def test_p10_inner_loop_after_store_merges():
    result = ccr(INNER_LOOP)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert has_merge(diag), diag
    build_run(INNER_LOOP, 0)


def test_p11_branch_return_blocks_merge():
    result = ccr(BRANCH_RETURN)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert not has_merge(diag), diag
    build_run(BRANCH_RETURN, 0)


def test_p12_no_escape_uses_split_not_merge():
    result = ccr(NO_ESCAPE)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert has_split(diag), diag
    assert not has_merge(diag), diag
    build_run(NO_ESCAPE, 0)


def test_p13_nested_merge_blocks_outer_split():
    # The inner merge copy would land in the outer IF arena; the outer split
    # must back off so the copy survives the outer merge.
    result = ccr(NESTED_MERGE_OUTER_SPLIT)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert has_merge(diag), diag
    assert not has_split(diag), diag
    build_run(NESTED_MERGE_OUTER_SPLIT, 0)
def test_p14_nested_merge_without_outer_arena():
    result = ccr(NESTED_MERGE_PLAIN)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert has_merge(diag), diag
    assert not has_split(diag), diag
    build_run(NESTED_MERGE_PLAIN, 0)
def test_p15_parent_arena_includes_copy():
    # No array literal, so the function arena size is a known static budget.
    # The parent copy must be charged to it: arr 24 B + copy 24 B = 48 B.
    result = ccr(KNOWN_SIZE)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert has_merge(diag), diag
    main_body = diag.split("Function: main", 1)[1]
    first_arena = next(ln for ln in main_body.splitlines() if "arena_new" in ln)
    assert "s1=48" in first_arena, first_arena
    build_run(KNOWN_SIZE, 0)
def test_p16_post_if_allocation_charged_to_parent():
    # The IF child arena is independent; arr, the copy, and c all live in the
    # function arena, so its budget is 3 * 24 B = 72 B.
    result = ccr(KNOWN_SIZE_AFTER)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert has_merge(diag), diag
    main_body = diag.split("Function: main", 1)[1]
    first_arena = next(ln for ln in main_body.splitlines() if "arena_new" in ln)
    assert "s1=72" in first_arena, first_arena
    build_run(KNOWN_SIZE_AFTER, 0)
def test_p17_other_nested_escape_blocks_merge():
    # The nested IF allocates into the same outer arena and escapes to `out`.
    # Copying only `arr` would leave `out` dangling after the merge reset.
    result = ccr(NESTED_ESCAPE_ALLOC)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert not has_merge(diag), diag
    build_run(NESTED_ESCAPE_ALLOC, 0)
def test_p18_nested_local_allocation_does_not_block_merge():
    result = ccr(NESTED_LOCAL)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert has_merge(diag), diag
    assert has_split(diag), diag
    build_run(NESTED_LOCAL, 0)



def test_p19_length_one():
    result = ccr(LEN_ONE)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert has_merge(diag), diag
    assert "_merge_copy[1]" in diag, diag
    build_run(LEN_ONE, 0)


def test_p20_length_64_and_parent_budget():
    # `b[j] = j` also covers the STORE_INDEX_VAR dataflow mapping: the value is
    # dest, the array is s1, and the index is s2; s3 is a literal zero.
    result = ccr(LEN_64)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert has_merge(diag), diag
    assert "_merge_copy[64]" in diag, diag
    main_body = diag.split("Function: main", 1)[1]
    first_arena = next(ln for ln in main_body.splitlines() if "arena_new" in ln)
    assert "s1=1040" in first_arena, first_arena
    build_run(LEN_64, 0)


def test_p21_length_65_blocks_merge():
    result = ccr(LEN_65)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert not has_merge(diag), diag
    assert not has_split(diag), diag
    build_run(LEN_65, 0)


def test_p22_length_zero_blocks_merge():
    result = ccr(LEN_ZERO)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert not has_merge(diag), diag
    build_run(LEN_ZERO, 0)


def test_p23_both_branches_allocate_share_one_copy():
    result = ccr(BOTH_BRANCHES)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert has_merge(diag), diag
    assert diag.count("_merge_copy") >= 1, diag
    build_run(BOTH_BRANCHES, 0)
    build_run(BOTH_BRANCHES_FALSE, 0)


def test_p30_both_branch_mutations_copied():
    result = ccr(BOTH_BRANCH_MUTATE)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert has_merge(diag), diag
    build_run(BOTH_BRANCH_MUTATE, 0)


def test_p24_two_merges_in_one_function():
    result = ccr(MULTI_MERGE)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    merges = [ln for ln in diag.splitlines() if ln.startswith("merge ")]
    assert len(merges) == 2, merges
    build_run(MULTI_MERGE, 0)


def test_p25_dynamic_index_read_write():
    result = ccr(DYN_INDEX)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert has_merge(diag), diag
    build_run(DYN_INDEX, 0)


def test_p26_pre_assignment_use_and_condition_read():
    result = ccr(PRE_USE)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert has_merge(diag), diag
    build_run(PRE_USE, 0)


def test_p27_bool_and_char_elements():
    for src in (BOOL_ARRAY, CHAR_ARRAY):
        result = ccr(src)
        diag = result.stdout + result.stderr
        assert result.returncode == 0, diag
        assert has_merge(diag), diag
        build_run(src, 0)


def test_p28_loop_after_merge_uses_copy():
    result = ccr(LOOP_AFTER)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert has_merge(diag), diag
    build_run(LOOP_AFTER, 0)


def test_p29_string_array_blocks_merge():
    result = ccr(STRING_ARRAY)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert not has_merge(diag), diag
    build_run(STRING_ARRAY, 0)


def test_p31_pod_struct_merges():
    for src in (POD_STRUCT, POD_STRUCT_FALSE):
        result = ccr(src)
        diag = result.stdout + result.stderr
        assert result.returncode == 0, diag
        assert has_merge(diag), diag
        build_run(src, 0)


def test_p32_pod_struct_mutation_before_copy():
    result = ccr(POD_STRUCT_MUTATE)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert has_merge(diag), diag
    build_run(POD_STRUCT_MUTATE, 0)


def test_p33_pod_tuple_merges():
    for src in (POD_TUPLE, POD_TUPLE_FALSE, POD_TUPLE_MUTATE):
        result = ccr(src)
        diag = result.stdout + result.stderr
        assert result.returncode == 0, diag
        assert has_merge(diag), diag
        build_run(src, 0)


def test_p34_pointer_fields_block_pod_merge():
    for src in (POD_STRUCT_POINTER_FIELD, POD_TUPLE_POINTER_ELEMENT):
        result = ccr(src)
        diag = result.stdout + result.stderr
        assert result.returncode == 0, diag
        assert not has_merge(diag), diag
        build_run(src, 0)


def test_p35_string_field_blocks_pod_merge():
    result = ccr(POD_STRUCT_STRING_FIELD)
    diag = result.stdout + result.stderr
    assert result.returncode == 0, diag
    assert not has_merge(diag), diag
    build_run(POD_STRUCT_STRING_FIELD, 0)


if __name__ == "__main__":
    tests = [
        test_p1_merge_copy_value,
        test_p2_false_path_keeps_old_array,
        test_p3_else_branch_copy,
        test_p4_copy_sees_branch_mutations,
        test_p5_alias_blocks_merge,
        test_p6_slice_escape_blocks_merge,
        test_p7_global_store_blocks_merge,
        test_p8_loop_ancestor_blocks_merge,
        test_p9_nested_loop_alloc_blocks_merge,
        test_p10_inner_loop_after_store_merges,
        test_p11_branch_return_blocks_merge,
        test_p12_no_escape_uses_split_not_merge,
        test_p13_nested_merge_blocks_outer_split,
        test_p14_nested_merge_without_outer_arena,
        test_p15_parent_arena_includes_copy,
        test_p16_post_if_allocation_charged_to_parent,
        test_p17_other_nested_escape_blocks_merge,
        test_p18_nested_local_allocation_does_not_block_merge,
        test_p19_length_one,
        test_p20_length_64_and_parent_budget,
        test_p21_length_65_blocks_merge,
        test_p22_length_zero_blocks_merge,
        test_p23_both_branches_allocate_share_one_copy,
        test_p24_two_merges_in_one_function,
        test_p25_dynamic_index_read_write,
        test_p26_pre_assignment_use_and_condition_read,
        test_p27_bool_and_char_elements,
        test_p28_loop_after_merge_uses_copy,
        test_p29_string_array_blocks_merge,
        test_p30_both_branch_mutations_copied,
        test_p31_pod_struct_merges,
        test_p32_pod_struct_mutation_before_copy,
        test_p33_pod_tuple_merges,
        test_p34_pointer_fields_block_pod_merge,
        test_p35_string_field_blocks_pod_merge,
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
