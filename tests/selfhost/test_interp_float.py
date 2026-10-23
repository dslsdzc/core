#!/usr/bin/env python3
"""Interpreter (corec run) dex/enum/dyn/pointer regression tests.

原为 wave-2 float 时代测试（F9 interp TI_FLOAT 分派 + IEEE binary64 软件实现、
F7 I2F REX.W、F8 NaN 比较）。dex 迁移（#2026-09-13-9）后 float 类型与 IEEE-754 NaN/Inf
语义退役（0/0 按整数除法陷阱 SIGFPE，不再产生 NaN/Inf）——相关用例已删除，
保留经 dex 缩放算术仍有效的运算用例与 F12 (STORE_PTR)/F13 (枚举 payload)/
BC11 (dyn 双槽/ADDR_INDEX) 部分。
"""
import subprocess
import sys
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"

# (名称, 源码, 期望退出码) —— corec run 的退出码 = main() 返回值
CASES = [
    # ── F9: interp TI_FLOAT 分派（IEEE 754 软件实现）──
    ("float_add", "fn main() -> int:\n    x := 1.5\n    y := 2.5\n    z := x + y\n    if z == 4.0:\n        return 1\n    return 0\n", 1),
    ("float_add_pow2", "fn main() -> int:\n    x := 2.5\n    y := 2.5\n    z := x + y\n    if z == 5.0:\n        return 1\n    return 0\n", 1),
    ("float_sub", "fn main() -> int:\n    x := 3.5\n    y := 1.0\n    z := x - y\n    if z == 2.5:\n        return 1\n    return 0\n", 1),
    ("float_mul", "fn main() -> int:\n    x := 1.5\n    y := 2.0\n    z := x * y\n    if z == 3.0:\n        return 1\n    return 0\n", 1),
    ("float_div", "fn main() -> int:\n    x := 7.0\n    y := 2.0\n    z := x / y\n    if z == 3.5:\n        return 1\n    return 0\n", 1),
    ("float_cmp", "fn main() -> int:\n    x := 1.5\n    y := 2.5\n    if x < y:\n        if y > x:\n            return 1\n    return 0\n", 1),
    ("float_i2f", "fn main() -> int:\n    y := 1099511627776\n    z := 1.5 + y\n    if z > 1000000000000.0:\n        return 1\n    return 0\n", 1),
    # （NaN/Inf 用例已删除：dex 世界 0 除按整数陷阱 SIGFPE，IEEE-754 语义退役）
    ("float_int_mix", "fn main() -> int:\n    f : dex = 2.0\n    i := 3\n    r := f + i\n    if r == 5.0:\n        return 0\n    return 1\n", 0),
    # ── F12: STORE_PTR 操作数（*p = v 写穿）──
    ("storeptr", "fn main() -> int:\n    x := 5\n    p := &x\n    *p = 42\n    return x\n", 42),
    ("deref_read", "fn main() -> int:\n    x : ., mut = 42\n    q := &x\n    if *q != 42:\n        return 1\n    return 0\n", 0),
    ("ptr_arith", "fn main() -> int:\n    arr := [10, 20, 30]\n    p := &arr[2]\n    if *p != 30:\n        return 1\n    return 0\n", 0),
    # ── F13: 枚举 payload（堆镜像布局 [tag][payload]）──
    ("enum_payload", "enum Choice:\n    First(int), Second(int), Third(int)\nfn main() -> int:\n    c := Third(33)\n    value := match c:\n        First(v) => v, Second(v) => v, Third(v) => v,\n    return value\n", 33),
    ("enum_tag_only", "enum Color:\n    Red, Green, Blue\nfn main() -> int:\n    c := Green()\n    t := match c:\n        Red => 1, Green => 2, Blue => 3,\n    return t\n", 2),
    # ── BC11: dyn 双槽 / ADDR_INDEX ──
    ("dyn_basic", "fn main() -> int:\n    x : dyn = 42\n    if x != 42:\n        return 1\n    return 0\n", 0),
    ("addr_index", "fn main() -> int:\n    a := [10, 20, 30]\n    p := &a[1]\n    if p == 0:\n        return 1\n    return 0\n", 0),
    # ── 纯 int 回归 ──
    ("int_arith", "fn main() -> int:\n    a := -7\n    b := 3\n    c := a / b\n    d := a % b\n    if c == -2 && d == -1:\n        return 1\n    return 0\n", 1),
    # ── BC-CONST: interpreter string values remain intern indices ──
    ("interp_strings", "fn main() -> int:\n    s := \"abc\"\n    t := \"ab\" + \"c\"\n    if str_len(s) != 3:\n        return 1\n    if str_eq(s, t) == 0:\n        return 2\n    i := 1\n    if s[i] != 98:\n        return 3\n    return 0\n", 0),
]


def run_case(name, src, expected):
    r = subprocess.run([str(COREC), 'run', src], capture_output=True, text=True,
                       cwd=str(BASE), timeout=60)
    if r.returncode != expected:
        print(f"[FAIL] {name}: expected {expected}, got {r.returncode}")
        print(f"       stderr={r.stderr!r}")
        return False
    print(f"[PASS] {name}: rc={r.returncode}")
    return True


def main():
    if not COREC.exists():
        print("build/corec is missing; run `python3 build_selfhost_native.py` first")
        return 1
    ok = True
    for name, src, expected in CASES:
        ok = run_case(name, src, expected) and ok
    print("ALL PASS" if ok else "SOME FAILED")
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
