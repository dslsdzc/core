#!/usr/bin/env python3
"""BytePermission 验证器侧回归（B012）。

权限状态只有两个独立位（readable / writable），只允许下降。当前推断来源：
字符串字面量只读、不可变全局只读、Core 分配可读写、未知值默认可读写。
检查面 = `ccr`/`build`（`check` 面不生成 IR，pass 不运行）。

正向固定用例必须命中具体错误码 B012 与消息；反向对照必须 rc=0。
"""

import os
import subprocess
import tempfile

BASE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def compile_ccr(src: str):
    with tempfile.NamedTemporaryFile("w", suffix=".cr", delete=False) as source:
        source.write(src)
        source_path = source.name
    output_path = os.path.splitext(source_path)[0] + ".ccr"
    try:
        result = subprocess.run(
            ["./build/corec", "ccr", source_path, "-o", output_path],
            capture_output=True, text=True, cwd=BASE, timeout=60,
        )
        return result, os.path.exists(output_path)
    finally:
        for path in (source_path, output_path):
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass


def assert_rejected(src: str, code: str, needle: str):
    result, artifact = compile_ccr(src)
    assert result.returncode != 0, f"expected rejection, got rc=0\n{result.stdout}\n{result.stderr}"
    diagnostic = result.stdout + result.stderr
    assert code in diagnostic, f"expected {code!r} in diagnostic:\n{diagnostic}"
    assert needle in diagnostic, f"expected {needle!r} in diagnostic:\n{diagnostic}"
    assert not artifact, "rejected compile must not leave an artifact"


def assert_accepted(src: str):
    result, artifact = compile_ccr(src)
    diagnostic = result.stdout + result.stderr
    assert result.returncode == 0, f"expected rc=0, got {result.returncode}\n{diagnostic}"
    assert artifact, "accepted compile must produce an artifact"


# ── 正向固定：只读字节被写入 ──────────────────────────────────────────────


def test_p1_direct_literal_write():
    """P1 字面量直接写入：`cell_store("abc", 0, 65)` ⇒ B012。"""
    assert_rejected(
        'fn main() -> int:\n    cell_store("abc", 0, 65)\n    return 0\n',
        "error[B12]", "read-only string",
    )


def test_p2_local_literal_copy_write():
    """P2 字面量经局部复制：`s := "abc"; t := s; cell_store(t, ...)` ⇒ B012。"""
    assert_rejected(
        'fn main() -> int:\n    s := "abc"\n    t := s\n    cell_store(t, 1, 66)\n    return 0\n',
        "error[B12]", "read-only string",
    )


def test_p3_wrapper_literal_write():
    """P3 形参摘要：被调函数写形参，调用点传字面量 ⇒ B012。"""
    assert_rejected(
        "fn put(s: string):\n    cell_store(s, 0, 65)\nfn main() -> int:\n    put(\"abc\")\n    return 0\n",
        "error[B12]", "writing parameter",
    )


def test_p4_transitive_wrapper_literal_write():
    """P4 摘要沿调用图传递：outer → inner 写形参，字面量实参仍报。"""
    assert_rejected(
        "fn inner(s: string):\n    cell_store(s, 0, 65)\nfn outer(s: string):\n    inner(s)\nfn main() -> int:\n    outer(\"abc\")\n    return 0\n",
        "error[B12]", "writing parameter",
    )


def test_p5_immutable_global_string_write():
    """P5 不可变全局字符串：`g : string = "abc"` 的字节写入 ⇒ B012。"""
    assert_rejected(
        'g : string = "abc"\nfn main() -> int:\n    cell_store(g, 0, 65)\n    return 0\n',
        "error[B12]", "read-only",
    )


def test_p6_mutable_global_literal_value_write():
    """P6 可变绑定但值仍是字面量：`g : string, mut = "abc"` 写的是字面量字节
    ⇒ 仍报 B012；可重新赋值为可写缓冲区后才允许写（R2）。"""
    assert_rejected(
        'g : string, mut = "abc"\nfn main() -> int:\n    cell_store(g, 0, 65)\n    return 0\n',
        "error[B12]", "read-only string",
    )


# ── 反向对照：必须 rc=0 ──────────────────────────────────────────────────


def test_r1_alloc_buffer_write():
    """R1 alloc 缓冲区可读写：写入后读回。"""
    assert_accepted(
        "fn main() -> int:\n    b := alloc(8)\n    cell_store(b, 0, 65)\n    return cell_load(b, 0) - 65\n"
    )


def test_r2_mutable_global_reassigned_to_buffer():
    """R2 可变全局重新赋值为 alloc 缓冲区后再写 ⇒ 接受。"""
    assert_accepted(
        'g : string, mut = "abc"\nfn main() -> int:\n    g = alloc(8)\n    cell_store(g, 0, 65)\n    return cell_load(g, 0) - 65\n'
    )


def test_r3_unsafe_literal_write():
    """R3 unsafe 是图边界：字面量写入在 unsafe 域内不检查。"""
    assert_accepted(
        'fn main() -> int:\n    s := "abc"\n    unsafe:\n        cell_store(s, 0, 65)\n    return 0\n'
    )


def test_r4_wrapper_alloc_buffer():
    """R4 写形参的被调函数接收 alloc 缓冲区 ⇒ 接受。"""
    assert_accepted(
        "fn put(s: string):\n    cell_store(s, 0, 65)\nfn main() -> int:\n    b := alloc(8)\n    put(b)\n    return cell_load(b, 0) - 65\n"
    )


def test_r5_read_literal():
    """R5 只读字节可读：`cell_load` 字面量 ⇒ 接受。"""
    assert_accepted(
        'fn main() -> int:\n    s := "abc"\n    return cell_load(s, 0) - 97\n'
    )


def test_r7_optional_global_pointer_write():
    """R7 全局槽字节可写：`mut` 只限制按名赋值，`&g` 后经指针写入仍接受
    （与 optional 槽既有语义一致；check 面保留既有软诊断 B04）。"""
    assert_accepted(
        "g : int? = Some(1)\nfn main() -> int:\n    p := &g\n    *p = none\n    return match g:\n        Some(v) =>:\n            return v\n        none =>:\n            return 4\n"
    )


def test_r6_transitive_wrapper_alloc_buffer():
    """R6 两层包装接收 alloc 缓冲区 ⇒ 接受。"""
    assert_accepted(
        "fn inner(s: string):\n    cell_store(s, 0, 65)\nfn outer(s: string):\n    inner(s)\nfn main() -> int:\n    b := alloc(8)\n    outer(b)\n    return cell_load(b, 0) - 65\n"
    )


if __name__ == "__main__":
    tests = [
        test_p1_direct_literal_write,
        test_p2_local_literal_copy_write,
        test_p3_wrapper_literal_write,
        test_p4_transitive_wrapper_literal_write,
        test_p5_immutable_global_string_write,
        test_p6_mutable_global_literal_value_write,
        test_r1_alloc_buffer_write,
        test_r2_mutable_global_reassigned_to_buffer,
        test_r3_unsafe_literal_write,
        test_r4_wrapper_alloc_buffer,
        test_r5_read_literal,
        test_r6_transitive_wrapper_alloc_buffer,
        test_r7_optional_global_pointer_write,
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
