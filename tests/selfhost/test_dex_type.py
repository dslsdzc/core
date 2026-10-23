#!/usr/bin/env python3
"""dex 类型核心测试（自举编译器 build/corec）—— 数值迁移 Task 3/5。

dex 是精确小数类型（Task 5：float 类型名已移除，不再映射 TY_DEX）：
- `x : dex = 3.14` 合法（check exit 0）
- `fn f() -> dex { return 3.14; }` 合法
- `3.14` 字面量推断为 dex（`x := 3.14` 不报错；cir dump 字面量常量名为 dex）

断言点：
- dex 类型声明/返回通过类型检查（check exit 0）
- 字面量归属 dex：cir dump 中 main 的字面量 IR_CONST 变量名为 dex
  （float 时代为 "float"，见 ir_gen new_ir_var("float", TI_FLOAT)）
- 移除守卫：float 类型名按未知类型报 TF01（不再映射到 dex）
"""

import os
import re
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"


def run_corec(args, source):
    """Write source to a temp file and run `corec <args> FILE.cr`.

    源文件首行注入唯一注释：改变 source hash，避免命中 .core/cache/cir/
    增量缓存（改源码后需 clean-cache 的地雷，见 CLAUDE.md）。
    """
    src = f"// dex-test-{uuid.uuid4()}\n" + source
    with tempfile.NamedTemporaryFile("w", suffix=".cr", delete=False) as f:
        f.write(src)
        path = f.name
    try:
        return subprocess.run(
            [str(COREC)] + args + [path],
            cwd=BASE,
            capture_output=True,
            text=True,
            timeout=120,
        )
    finally:
        os.unlink(path)


def test_dex_type_declares():
    # 1) 变量声明：x : dex = 3.14 → check exit 0
    src = (
        "fn main() -> int:\n    x : dex = 3.14\n    return 1\n"
    )
    r = run_corec(["check"], src)
    if r.returncode != 0:
        print(f"[FAIL] dex var decl: exit={r.returncode}")
        print(r.stdout + r.stderr)
        return False
    print("[PASS] x : dex = 3.14 (check exit 0)")

    # 2) 函数返回类型：fn f() -> dex { return 3.14; } → check exit 0
    src2 = (
        "fn f() -> dex:\n    return 3.14\nfn main() -> int:\n    return 1\n"
    )
    r2 = run_corec(["check"], src2)
    if r2.returncode != 0:
        print(f"[FAIL] dex return type: exit={r2.returncode}")
        print(r2.stdout + r2.stderr)
        return False
    print("[PASS] fn f() -> dex:\n    return 3.14\n(check exit 0)\n")

    # 3) 移除守卫（Task 5）：float 类型名不再映射 TY_DEX——按未知类型名走 lenient
    #    TYP_NAMED 路径（TF01 非致命、check 报诊断；与任何未知名字一致）。
    #    （终审 Minor 2：守卫收紧——断言 TF01 出现且退出码按 F19 契约反映诊断，
    #      防"漏报/误报"双向漂移。第四轮 F19：check 有诊断 rc=1、无诊断 rc=0）
    src3 = (
        "fn f() -> float:\n    return 3.14\nfn main() -> int:\n    return 1\n"
    )
    r3 = run_corec(["check"], src3)
    out3 = r3.stdout + r3.stderr
    if r3.returncode != 1 or "TF01" not in out3:
        print(f"[FAIL] float keyword should be rejected (TF01, F19 diagnostic exit 1): exit={r3.returncode}")
        print(out3)
        return False
    print("[PASS] fn f() -> float:\n    ...\nrejected with TF01, exit 1 (float type name removed, F19)\n")
    return True


def test_dex_literal_type():
    # 1) 字面量推断：x := 3.14 不报错（3.14 推断为 dex——返回 1 走 int 路径）
    src = "fn main() -> int:\n    x := 3.14\n    return 1\n"
    r = run_corec(["check"], src)
    if r.returncode != 0:
        print(f"[FAIL] literal infers dex: exit={r.returncode}")
        print(r.stdout + r.stderr)
        return False
    print("[PASS] x := 3.14 infers a real type (check exit 0)")

    # 2) 字面量归属 dex 的类型层证据：cir dump 中字面量 IR_CONST 变量名为 dex
    #    （float 时代为 "float"，ir_gen new_ir_var("float", TI_FLOAT)）
    rc = run_corec(["cir"], src)
    out = rc.stdout + rc.stderr
    if re.search(r"const\s+dex\s*=", out) is None:
        print("[FAIL] literal const should be 'dex' in cir dump")
        print(out)
        return False
    print("[PASS] cir dump shows literal const 'dex'")
    return True


def test_wide_decimal_literal():
    # A value whose integer part is wider than the 53-bit significand must
    # not call the integer power helper with a negative exponent.
    src = "fn main() -> int:\n    x : dex = 2305843009213693952.0\n    return 1\n"
    r = run_corec(["check"], src)
    if r.returncode != 0:
        print(f"[FAIL] wide decimal literal: exit={r.returncode}")
        print(r.stdout + r.stderr)
        return False
    print("[PASS] wide decimal literal does not overflow lexer conversion")
    return True


def test_static_string_bounds():
    src = 'fn main() -> int:\n    return "abc"[3]\n'
    r = run_corec(["check"], src)
    out = r.stdout + r.stderr
    if r.returncode != 1 or "R02" not in out:
        print(f"[FAIL] static string bounds: exit={r.returncode}")
        print(out)
        return False
    print("[PASS] literal string index at length is rejected with R02")
    return True


def test_decimal_literal_overflow_is_reported():
    src = "fn main() -> int:\n    x : dex = 123456789012345678901.0\n    return 1\n"
    r = run_corec(["check"], src)
    out = r.stdout + r.stderr
    if r.returncode == 0 or "too wide" not in out:
        print(f"[FAIL] wide decimal literal should be rejected: exit={r.returncode}")
        print(out)
        return False
    print("[PASS] over-wide decimal literal is rejected explicitly")
    return True


def main():
    if not COREC.exists():
        print(f"[FAIL] missing native compiler: {COREC}")
        return 1
    results = [test_dex_type_declares(), test_dex_literal_type(), test_wide_decimal_literal(), test_static_string_bounds(), test_decimal_literal_overflow_is_reported()]
    passed = sum(results)
    print(f"{passed}/{len(results)} passed")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
