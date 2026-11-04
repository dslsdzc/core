#!/usr/bin/env python3
"""ALLOC_AT 声明式固定地址放置回归。

v1 约束：地址、大小、对齐必须是编译期整数字面量；返回 `*int`；大小为字节且
必须是 8 的倍数（IR 边界以 8 字节 cell 计）；解释器不支持固定地址访问，必须
响亮失败而不是伪造宿主指针。
"""

import os
import subprocess
import tempfile

BASE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def _run(args, src):
    with tempfile.NamedTemporaryFile("w", suffix=".cr", delete=False) as source:
        source.write(src)
        source_path = source.name
    output_path = os.path.splitext(source_path)[0] + ".ccr"
    try:
        result = subprocess.run(
            ["./build/corec", *args, source_path, "-o", output_path],
            capture_output=True, text=True, cwd=BASE, timeout=120,
        )
        return result, output_path, os.path.exists(output_path)
    finally:
        pass


def compile_ccr(src: str):
    result, output_path, artifact = _run(["ccr"], src)
    try:
        os.unlink(output_path)
    except FileNotFoundError:
        pass
    return result, artifact


def build_static(src: str):
    with tempfile.NamedTemporaryFile("w", suffix=".cr", delete=False) as source:
        source.write(src)
        source_path = source.name
    binary = os.path.splitext(source_path)[0] + ".elf"
    try:
        result = subprocess.run(
            ["./build/corec", "build", "--static", source_path, "-o", binary],
            capture_output=True, text=True, cwd=BASE, timeout=300,
        )
        return result, os.path.exists(binary)
    finally:
        for path in (source_path, binary):
            try:
                os.unlink(path)
            except FileNotFoundError:
                pass


def dump_cir(src: str):
    with tempfile.NamedTemporaryFile("w", suffix=".cr", delete=False) as source:
        source.write(src)
        source_path = source.name
    try:
        return subprocess.run(
            ["./build/corec", "cir", source_path],
            capture_output=True, text=True, cwd=BASE, timeout=120,
        )
    finally:
        os.unlink(source_path)


def assert_rejected(src: str, code: str, needle: str):
    result, artifact = compile_ccr(src)
    diagnostic = result.stdout + result.stderr
    assert result.returncode != 0, f"expected rejection, got rc=0\n{diagnostic}"
    assert code in diagnostic, f"expected {code!r}:\n{diagnostic}"
    assert needle in diagnostic, f"expected {needle!r}:\n{diagnostic}"
    assert not artifact, "rejected compile must not leave an artifact"


def assert_accepted(src: str):
    result, artifact = compile_ccr(src)
    diagnostic = result.stdout + result.stderr
    assert result.returncode == 0, f"expected rc=0, got {result.returncode}\n{diagnostic}"
    assert artifact, "accepted compile must produce an artifact"


BASIC = """fn main() -> int:
    mmio := alloc_at(0x7fff0000, 4096, align(4096))
    *mmio = 42
    return *mmio
"""


def test_p1_basic_placement():
    """P1 基本声明式放置：固定地址、大小、对齐进入 IR 并生成产物。"""
    assert_accepted(BASIC)


def test_p2_cir_has_alloc_at_node():
    """P2 IR 面：`.cir` 必须出现 alloc_at 节点，而不是普通 alloc 调用。"""
    result = dump_cir(BASIC)
    diagnostic = result.stdout + result.stderr
    assert result.returncode == 0, diagnostic
    assert "alloc_at" in diagnostic, diagnostic
    assert "alloc(2147418112" not in diagnostic, diagnostic


def test_p3_static_bounds_reject():
    """P3 边界：4096 字节 = 512 个 *int cell；偏移 512 起解引用 ⇒ TK01。"""
    assert_rejected(
        """fn main() -> int:
    mmio := alloc_at(0x7fff0000, 4096, align(4096))
    p := mmio + 512
    return *p
""",
        "error[TK01]", "out of bounds",
    )


def test_p4_static_bounds_last_cell_accept():
    """P4 边界反向对照：偏移 511 是最后一个 *int cell ⇒ 接受。"""
    assert_accepted(
        """fn main() -> int:
    mmio := alloc_at(0x7fff0000, 4096, align(4096))
    p := mmio + 511
    return *p
"""
    )


def test_p5_dynamic_arguments_rejected():
    """P5 声明期约束：大小来自运行时变量 ⇒ 编译期拒绝（不猜部署值）。"""
    assert_rejected(
        """fn main() -> int:
    n := 4096
    p := alloc_at(0x7fff0000, n, align(4096))
    return 0
""",
        "error[TK03]", "compile-time integer",
    )


def test_p6_bad_size_rejected():
    """P6 大小必须是正的 8 字节倍数。"""
    assert_rejected(
        """fn main() -> int:
    p := alloc_at(0x7fff0000, 100, align(4096))
    return 0
""",
        "error[TK03]", "multiple of 8",
    )


def test_p7_static_elf_build():
    """P7 后端：alloc_at 必须能生成静态 ELF（不在测试中运行，固定地址未必映射）。"""
    result, artifact = build_static(BASIC)
    diagnostic = result.stdout + result.stderr
    assert result.returncode == 0, f"expected rc=0\n{diagnostic}"
    assert artifact, "build must produce an ELF artifact"


def test_p8_dynamic_offset_gets_runtime_bound():
    """P8 动态偏移：编译期不能证明时保留运行时边界；alloc_at 的地址作为
    运行时基址、声明大小作为界。"""
    result, artifact = build_static(
        """fn idx() -> int:
    return 0
fn main() -> int:
    mmio := alloc_at(0x7fff0000, 4096, align(4096))
    p := mmio + idx()
    *p = 1
    return 0
"""
    )
    diagnostic = result.stdout + result.stderr
    assert result.returncode == 0, f"expected rc=0\n{diagnostic}"
    assert artifact, "build must produce an ELF artifact"


def test_p9_interpreter_rejects_fixed_address():
    """P9 解释器不伪造宿主指针：alloc_at 程序必须响亮失败。"""
    result = subprocess.run(
        ["./build/corec", "run", BASIC],
        capture_output=True, text=True, cwd=BASE, timeout=120,
    )
    diagnostic = result.stdout + result.stderr
    assert result.returncode != 0, f"expected interpreter rejection\n{diagnostic}"
    assert "IR_ALLOC_AT" in diagnostic, diagnostic


def test_r1_fixed_address_is_program_lifetime():
    """R1 固定地址是程序寿命：循环内声明、循环后存全局/返回 ⇒ 不误报区域逃逸。"""
    assert_accepted(
        """gp : *int, mut
fn make() -> *int:
    i : ., mut = 0
    while i < 1:
        p := alloc_at(0x7fff0000, 4096, align(4096))
        return p
    return alloc_at(0x7fff0000, 4096, align(4096))
fn main() -> int:
    i : ., mut = 0
    while i < 1:
        q := alloc_at(0x7fff0000, 4096, align(4096))
        gp = q
        i = i + 1
    return 0
"""
    )


def test_r2_align_only_in_placement():
    """R2 align 是声明期恒等：放在 alloc_at 内不影响其它计算。"""
    assert_accepted(
        """fn main() -> int:
    p := alloc_at(0x7fff0000, 4096, align(4096))
    return 0
"""
    )


if __name__ == "__main__":
    tests = [
        test_p1_basic_placement,
        test_p2_cir_has_alloc_at_node,
        test_p3_static_bounds_reject,
        test_p4_static_bounds_last_cell_accept,
        test_p5_dynamic_arguments_rejected,
        test_p6_bad_size_rejected,
        test_p7_static_elf_build,
        test_p8_dynamic_offset_gets_runtime_bound,
        test_p9_interpreter_rejects_fixed_address,
        test_r1_fixed_address_is_program_lifetime,
        test_r2_align_only_in_placement,
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
