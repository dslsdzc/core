#!/usr/bin/env python3
"""Regression tests for pointer provenance, bounds, and unsafe boundaries."""

import os
import resource
import subprocess
import tempfile


BASE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def _no_core_dump():
    # TODO:125：core_pattern 为 systemd-coredump 管道，陷阱程序（SIGILL）在
    # core dump 写入时会挂起——trap 测试禁用 core dump 让信号立即终止
    # （临时处理；根治方向见 TODO：图推导边界判定 pass）。
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def compile_ccr(src: str):
    with tempfile.NamedTemporaryFile("w", suffix=".cr", delete=False) as source:
        source.write(src)
        source_path = source.name
    output_path = os.path.splitext(source_path)[0] + ".ccr"
    try:
        result = subprocess.run(
            ["./build/corec", "ccr", source_path, "-o", output_path],
            capture_output=True,
            text=True,
            cwd=BASE,
            timeout=60,
        )
        return result
    finally:
        for path in (source_path, output_path):
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass


def build_and_run(src: str):
    with tempfile.NamedTemporaryFile("w", suffix=".cr", delete=False) as source:
        source.write(src)
        source_path = source.name
    output_path = os.path.splitext(source_path)[0]
    try:
        build = subprocess.run(
            ["./build/corec", "build", source_path, "-o", output_path, "--static"],
            capture_output=True,
            text=True,
            cwd=BASE,
            timeout=120,
        )
        assert build.returncode == 0, (
            f"native build failed with {build.returncode}:\n"
            f"{build.stdout}{build.stderr}"
        )
        os.chmod(output_path, 0o755)
        return subprocess.run(
            [output_path], capture_output=True, text=True, cwd=BASE, timeout=10,
            preexec_fn=_no_core_dump,
        )
    finally:
        for path in (source_path, output_path, output_path + ".ccr"):
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass


def assert_rejected(src: str, message: str):
    result = compile_ccr(src)
    output = result.stdout + result.stderr
    assert result.returncode != 0, f"expected rejection, got success:\n{output}"
    assert message in output, f"expected {message!r} in diagnostic:\n{output}"


def assert_accepted(src: str):
    result = compile_ccr(src)
    output = result.stdout + result.stderr
    assert result.returncode == 0, f"expected success, got {result.returncode}:\n{output}"


def test_out_of_bounds_load_is_rejected():
    assert_rejected(
        "fn main() -> int:\n    arr := [1]\n    p := &arr[0] + 1\n    return *p\n",
        "TK01",
    )


def test_out_of_bounds_store_is_rejected():
    assert_rejected(
        "fn main() -> int:\n    arr := [1]\n    p := &arr[0] + 1\n    *p = 2\n    return 0\n",
        "TK01",
    )


def test_deref_width_cannot_cross_allocation_end():
    assert_rejected(
        "fn main() -> int:\n    arr := [1, 2]\n    p := (&arr[1]) cast *[int; 2]\n    wide := *p\n    return 0\n",
        "TK01",
    )


def test_in_bounds_type_pun_is_accepted():
    assert_accepted(
        "fn main() -> int:\n    arr := [1, 2]\n    p := (&arr[0]) cast *[int; 2]\n    wide := *p\n    return 0\n"
    )


def test_external_pointer_requires_unsafe_for_load():
    assert_rejected(
        "fn main() -> int:\n    p := 4096 cast *int\n    return *p\n",
        "external pointer dereference requires unsafe",
    )


def test_external_pointer_requires_unsafe_for_store():
    assert_rejected(
        "fn main() -> int:\n    p := 4096 cast *int\n    *p = 1\n    return 0\n",
        "external pointer dereference requires unsafe",
    )


def test_indirect_external_pointer_requires_unsafe():
    assert_rejected(
        "fn main() -> int:\n    address := 4096\n    p := address cast *int\n    return *p\n",
        "external pointer dereference requires unsafe",
    )


def test_external_pointer_arithmetic_preserves_address_space():
    assert_rejected(
        "fn main() -> int:\n    p := (4096 cast *int) + 1\n    return *p\n",
        "external pointer dereference requires unsafe",
    )


def test_alloc_buffer_cast_remains_tracked():
    assert_accepted(
        "fn main() -> int:\n    raw := alloc(8)\n    p := raw cast *int\n    value := *p\n    return 0\n"
    )


def test_deref_loaded_int_is_not_pointer_escape():
    """A dereference result with integer type must not trigger pointer escape checks."""
    assert_accepted(
        "fn main() -> int:\n    value := 42\n    pointer := &value\n    loaded := *pointer\n    return loaded\n"
    )


def test_external_pointer_is_accepted_inside_unsafe():
    assert_accepted(
        "fn main() -> int:\n    unsafe:\n        p := 4096 cast *int\n        value := *p\n    return 0\n"
    )


def test_dynamic_in_bounds_load_runs():
    result = build_and_run(
        "fn main() -> int:\n    arr := [10, 20]\n    i := 1\n    p := &arr[i]\n    return *p - 20\n"
    )
    assert result.returncode == 0, (
        f"in-bounds pointer load trapped: {result.returncode} "
        f"stdout={result.stdout!r} stderr={result.stderr!r}"
    )


def test_dynamic_in_bounds_store_runs():
    result = build_and_run(
        "fn main() -> int:\n    arr := [10, 20]\n    i := 1\n    p := &arr[i]\n    *p = 21\n    return *p - 21\n"
    )
    assert result.returncode == 0, (
        f"in-bounds pointer access trapped: {result.returncode} "
        f"stdout={result.stdout!r} stderr={result.stderr!r}"
    )


def test_dynamic_out_of_bounds_load_traps():
    result = build_and_run(
        "fn main() -> int:\n    arr := [10, 20]\n    i := 2\n    p := &arr[i]\n    return *p\n"
    )
    assert result.returncode != 0, "out-of-bounds load executed successfully"


def test_dynamic_out_of_bounds_store_traps():
    result = build_and_run(
        "fn main() -> int:\n    arr := [10, 20]\n    i := 2\n    p := &arr[i]\n    *p = 30\n    return 0\n"
    )
    assert result.returncode != 0, "out-of-bounds store executed successfully"


def test_dynamic_multi_target_pointer_is_rejected():
    assert_rejected(
        "fn main() -> int:\n    left := [10, 20]\n    right := [30, 40]\n    i := 1\n    p : ., mut = &left[i]\n    p = &right[i]\n    return *p\n",
        "multiple allocation targets",
    )


if __name__ == "__main__":
    tests = [
        test_out_of_bounds_load_is_rejected,
        test_out_of_bounds_store_is_rejected,
        test_deref_width_cannot_cross_allocation_end,
        test_in_bounds_type_pun_is_accepted,
        test_external_pointer_requires_unsafe_for_load,
        test_external_pointer_requires_unsafe_for_store,
        test_indirect_external_pointer_requires_unsafe,
        test_external_pointer_arithmetic_preserves_address_space,
        test_alloc_buffer_cast_remains_tracked,
        test_deref_loaded_int_is_not_pointer_escape,
        test_external_pointer_is_accepted_inside_unsafe,
        test_dynamic_in_bounds_load_runs,
        test_dynamic_in_bounds_store_runs,
        test_dynamic_out_of_bounds_load_traps,
        test_dynamic_out_of_bounds_store_traps,
        test_dynamic_multi_target_pointer_is_rejected,
    ]
    failures = 0
    for test in tests:
        try:
            test()
            print(f"PASS {test.__name__}")
        except AssertionError as error:
            failures += 1
            print(f"FAIL {test.__name__}: {error}")
    raise SystemExit(1 if failures else 0)
