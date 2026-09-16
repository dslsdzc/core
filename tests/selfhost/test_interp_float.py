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
    ("float_add", "fn main() -> int { x := 1.5; y := 2.5; z := x + y; if z == 4.0 { return 1; } return 0; }", 1),
    ("float_add_pow2", "fn main() -> int { x := 2.5; y := 2.5; z := x + y; if z == 5.0 { return 1; } return 0; }", 1),
    ("float_sub", "fn main() -> int { x := 3.5; y := 1.0; z := x - y; if z == 2.5 { return 1; } return 0; }", 1),
    ("float_mul", "fn main() -> int { x := 1.5; y := 2.0; z := x * y; if z == 3.0 { return 1; } return 0; }", 1),
    ("float_div", "fn main() -> int { x := 7.0; y := 2.0; z := x / y; if z == 3.5 { return 1; } return 0; }", 1),
    ("float_cmp", "fn main() -> int { x := 1.5; y := 2.5; if x < y { if y > x { return 1; } } return 0; }", 1),
    ("float_i2f", "fn main() -> int { y := 1099511627776; z := 1.5 + y; if z > 1000000000000.0 { return 1; } return 0; }", 1),
    # （NaN/Inf 用例已删除：dex 世界 0 除按整数陷阱 SIGFPE，IEEE-754 语义退役）
    ("float_int_mix", "fn main() -> int { f : dex = 2.0; i := 3; r := f + i; if r == 5.0 { return 0; } return 1; }", 0),
    # ── F12: STORE_PTR 操作数（*p = v 写穿）──
    ("storeptr", "fn main() -> int { x := 5; p := &x; *p = 42; return x; }", 42),
    ("deref_read", "fn main() -> int { x : ., mut = 42; q := &x; if *q != 42 { return 1; } return 0; }", 0),
    ("ptr_arith", "fn main() -> int { arr := [10, 20, 30]; p := &arr[2]; if *p != 30 { return 1; } return 0; }", 0),
    # ── F13: 枚举 payload（堆镜像布局 [tag][payload]）──
    ("enum_payload", "enum Choice { First(int), Second(int), Third(int) } fn main() -> int { c := Third(33); value := match c { First(v) => v, Second(v) => v, Third(v) => v, }; return value; }", 33),
    ("enum_tag_only", "enum Color { Red, Green, Blue } fn main() -> int { c := Green(); t := match c { Red => 1, Green => 2, Blue => 3, }; return t; }", 2),
    # ── BC11: dyn 双槽 / ADDR_INDEX ──
    ("dyn_basic", "fn main() -> int { x : dyn = 42; if x != 42 { return 1; } return 0; }", 0),
    ("addr_index", "fn main() -> int { a := [10, 20, 30]; p := &a[1]; if p == 0 { return 1; } return 0; }", 0),
    # ── 纯 int 回归 ──
    ("int_arith", "fn main() -> int { a := -7; b := 3; c := a / b; d := a % b; if c == -2 && d == -1 { return 1; } return 0; }", 1),
    # ── BC-CONST: interpreter string values remain intern indices ──
    ("interp_strings", "fn main() -> int { s := \"abc\"; t := \"ab\" + \"c\"; if str_len(s) != 3 { return 1; } if str_eq(s, t) == 0 { return 2; } i := 1; if s[i] != 98 { return 3; } return 0; }", 0),
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
