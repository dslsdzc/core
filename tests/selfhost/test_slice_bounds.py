#!/usr/bin/env python3
"""F11 切片边界回归测试——运行时界 slice 的越界守卫（2026-09-05 修复）。

背景：字面量界切片（a[1..3]）长度编译期已知、有越界守卫；运行时界切片
（a[lo..hi]）此前长度丢失——s[k] 越界静默（读到 slice 外、底层数组内的值）。
修复：ir_gen 为运行时界 slice 计算 len = high − low 的长度变量并沿
赋值/LET 传播，解引用处发射 IR_BOUNDS_CHECK（动态上限，ti=1）。

SIGILL = 132；main 正常返回值 = 进程退出码（低 8 位）。
"""

import os
import resource
import subprocess
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"


def _no_core_dump():
    # TODO:125：core_pattern 为 systemd-coredump 管道，陷阱程序（SIGILL）在
    # core dump 写入时会挂起——测试禁用 core dump 让 SIGILL 立即终止。
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def build_and_run(source: str):
    with tempfile.NamedTemporaryFile("w", suffix=".cr", delete=False) as f:
        f.write(source)
        src = f.name
    out = src[:-3]  # strip .cr
    try:
        built = subprocess.run(
            [str(COREC), "build", src, "-o", out, "--static"],
            capture_output=True, text=True, cwd=BASE, timeout=120,
        )
        if built.returncode != 0:
            return f"compile-failed: {built.stdout}{built.stderr}"
        return subprocess.run(
            [out], capture_output=True, text=True, timeout=10,
            preexec_fn=_no_core_dump,
        )
    finally:
        for p in (src, out, out + ".ccr"):
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass


def case(name, source, expect_rc):
    r = build_and_run(source)
    if isinstance(r, str):
        print(f"[FAIL] {name}: {r}")
        return False
    if r.returncode != expect_rc:
        print(f"[FAIL] {name}: expected rc {expect_rc}, got {r.returncode}")
        return False
    print(f"[PASS] {name}: rc={r.returncode}")
    return True


def main() -> int:
    if not COREC.exists():
        print(f"[FAIL] missing native compiler: {COREC}")
        return 1
    # SIGILL（ud2 trap）：shell 显示 132，subprocess returncode = -4（-signum）
    SIGILL = -4
    ok = [
        # 运行时界 slice 越界读/写必须 trap
        case("runtime_bounds_literal_index_oob_traps", """
fn main() -> int:
    a : [int; 5] = [10, 20, 30, 40, 50]
    lo := 1
    hi := 3
    s := a[lo..hi]
    x := s[2]
    return x
""", SIGILL),
        case("runtime_bounds_var_index_oob_traps", """
fn main() -> int:
    a : [int; 5] = [10, 20, 30, 40, 50]
    lo := 1
    hi := 3
    s := a[lo..hi]
    i := 2
    return s[i]
""", SIGILL),
        case("runtime_bounds_store_oob_traps", """
fn main() -> int:
    a : [int; 5] = [10, 20, 30, 40, 50]
    lo := 1
    hi := 3
    s := a[lo..hi]
    s[5] = 99
    return 0
""", SIGILL),
        # 空切片（len=0）任何访问都越界
        case("empty_slice_index_traps", """
fn main() -> int:
    a : [int; 5] = [10, 20, 30, 40, 50]
    lo := 2
    hi := 2
    s := a[lo..hi]
    return s[0]
""", SIGILL),
        # 合法访问不误伤：值必须正确（s[1] == 30）
        case("runtime_bounds_in_bounds_load_ok", """
fn main() -> int:
    a : [int; 5] = [10, 20, 30, 40, 50]
    lo := 1
    hi := 3
    s := a[lo..hi]
    return s[1]
""", 30),
        # 字面量界 slice 的既有守卫不回归
        case("literal_bounds_oob_still_traps", """
fn main() -> int:
    a : [int; 5] = [10, 20, 30, 40, 50]
    s := a[1..3]
    return s[2]
""", SIGILL),
        case("literal_bounds_in_bounds_ok", """
fn main() -> int:
    a : [int; 5] = [10, 20, 30, 40, 50]
    s := a[1..3]
    return s[1]
""", 30),
    ]
    passed = sum(ok)
    print(f"{passed}/{len(ok)} passed")
    return 0 if passed == len(ok) else 1


if __name__ == "__main__":
    raise SystemExit(main())
