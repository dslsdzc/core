#!/usr/bin/env python3
"""Native ELF dex 运算回归测试（原 wave-2 float 时代：F7 I2F REX.W + F8 NaN 比较）。

dex 迁移（#2026-09-13-9）后 float 类型与 IEEE-754 NaN/Inf 语义退役（0 除按整数陷阱
SIGFPE）——NaN 用例已删除；保留经 dex 缩放算术仍有效的 i2f/比较/四则用例。
"""
import os
import subprocess
import sys
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
BUILD = BASE / "build"
COREC = BUILD / "corec"

CASES = [
    (
        "i2f_big",
        """
fn main() -> int {
    y := 1099511627776;  // 2^40
    z := 1.5 + y;
    if z > 1000000000000.0 { return 1; }
    return 0;
}
""",
        1,
    ),
    # （nan_eq/nan_ne 已删除：dex 世界 0 除按整数陷阱 SIGFPE，IEEE-754 NaN 语义退役）
    (
        "float_normal_cmp",
        """
fn main() -> int {
    if 1.5 < 2.5 { } else { return 1; }
    if 2.5 > 1.5 { } else { return 2; }
    if 1.5 <= 1.5 { } else { return 3; }
    if 2.5 >= 2.5 { } else { return 4; }
    if 2.5 == 2.5 { } else { return 5; }
    if 1.5 != 2.5 { } else { return 6; }
    return 0;
}
""",
        0,
    ),
    (
        "float_arith",
        """
fn main() -> int {
    x := 1.5;
    y := 2.5;
    if x + y == 4.0 { } else { return 1; }
    if x * y == 3.75 { } else { return 2; }
    if y - x == 1.0 { } else { return 3; }
    if y / x == 5.0 / 3.0 { } else { return 4; }
    return 0;
}
""",
        0,
    ),
]


def run_case(name: str, source: str, expected: int) -> bool:
    src = BUILD / f"native_float_{name}.cr"
    binary = BUILD / f"native_float_{name}"
    ccr = Path(str(binary) + ".ccr")
    src.write_text(source.strip() + "\n", encoding="utf-8")
    try:
        built = subprocess.run(
            ["nice", "-n", "19", str(COREC), "build", str(src), "-o", str(binary), "--static"],
            cwd=BASE, capture_output=True, text=True, timeout=120)
        if built.returncode != 0:
            print(f"[FAIL] {name}: compiler exit {built.returncode}")
            print(built.stdout)
            print(built.stderr)
            return False
        if not binary.exists():
            print(f"[FAIL] {name}: output ELF was not created")
            return False
        os.chmod(binary, 0o755)
        result = subprocess.run([str(binary)], cwd=BASE, capture_output=True, text=True)
        if result.returncode != expected:
            print(f"[FAIL] {name}: expected {expected}, got {result.returncode}")
            return False
        print(f"[PASS] {name}: {result.returncode}")
        return True
    finally:
        for artifact in (src, binary, ccr):
            try:
                artifact.unlink()
            except FileNotFoundError:
                pass


def main() -> int:
    if not COREC.exists():
        print("build/corec is missing; run `python3 build_selfhost_native.py` first")
        return 1
    ok = True
    for name, source, expected in CASES:
        ok = run_case(name, source, expected) and ok
    print("ALL PASS" if ok else "SOME FAILED")
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
