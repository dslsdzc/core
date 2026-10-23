#!/usr/bin/env python3
"""apx 变量标签机制测试（自举编译器 build/corec）—— 数值迁移 Task 2。

apx 是纯注解标签：`x : int, apx = 42` 语法合法、checker 认可、类型信息携带
apx 位、ir_gen 在 apx 变量声明处发射 IR_APPROX（无操作数，无运算语义）。

断言点：
- apx 标签编译通过（check exit 0）
- 未知标签（bogus_tag）报错（check exit != 0，TA08 非法标签）
- apx 不改变程序语义：run 返回值与无 apx 版本一致（interp 跳过 IR_APPROX）
- cir dump 中每声明一个 apx 变量恰出现一条 `approx` 指令；无 apx 则没有
"""

import os
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
    src = f"// apx-test-{uuid.uuid4()}\n" + source
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


def run_inline(source):
    """`corec run '<code>'` —— 内联解释执行，exit code = main 返回值。"""
    return subprocess.run(
        [str(COREC), "run", source],
        cwd=BASE,
        capture_output=True,
        text=True,
        timeout=120,
    )


def test_apx_tag_parses():
    # 1) apx 标签合法：check 通过（exit 0）
    src = (
        "fn main() -> int:\n    x : int, apx = 42\n    y : int, apx, mut = 84\n    return x + y\n"
    )
    r = run_corec(["check"], src)
    if r.returncode != 0:
        print(f"[FAIL] apx tag accepted: exit={r.returncode}")
        print(r.stdout + r.stderr)
        return False
    print("[PASS] apx tag accepted (check exit 0)")

    # 2) 未知标签非法：check 报错（exit != 0，TA08）
    src2 = (
        "fn main() -> int:\n    x : int, bogus_tag = 42\n    return x\n"
    )
    r2 = run_corec(["check"], src2)
    output2 = r2.stdout + r2.stderr
    if r2.returncode == 0:
        print(f"[FAIL] bogus tag rejected: exit={r2.returncode}")
        print(output2)
        return False
    if "TA08" not in output2:
        print(f"[FAIL] bogus tag rejected: no TA08 diagnostic in output")
        print(output2)
        return False
    print("[PASS] unknown tag rejected (TA08, exit != 0)")
    return True


def test_apx_tag_no_semantic_change():
    # 1) 语义不变：带/不带 apx 的同一程序 run 返回值一致（interp 跳过 IR_APPROX）
    plain_src = "fn main() -> int:\n    x : int = 42\n    y : int = 84\n    return x + y\n"
    apx_src = "fn main() -> int:\n    x : int, apx = 42\n    y : int, apx = 84\n    return x + y\n"
    rp = run_inline(plain_src)
    ra = run_inline(apx_src)
    if rp.returncode != ra.returncode or rp.returncode != 126:
        print(f"[FAIL] semantic change: plain={rp.returncode} apx={ra.returncode} (expect 126)")
        print("plain:", rp.stdout + rp.stderr)
        print("apx:", ra.stdout + ra.stderr)
        return False
    print(f"[PASS] no semantic change (both run -> {ra.returncode})")

    # 2) IR 差异：仅 apx 变量处多 IR_APPROX（cir dump 每变量恰一条 `approx`）
    plain_file = (
        "fn main() -> int:\n    x : int = 42\n    y : int = 84\n    return x + y\n"
    )
    apx_file = (
        "fn main() -> int:\n    x : int, apx = 42\n    y : int = 84\n    z : int, apx = 126\n    return x + y + z\n"
    )
    rc = run_corec(["cir"], plain_file)
    out_plain = rc.stdout + rc.stderr
    if "approx" in out_plain:
        print(f"[FAIL] plain program should not contain 'approx':\n{out_plain}")
        return False
    print("[PASS] plain program: no 'approx' in cir dump")

    rc2 = run_corec(["cir"], apx_file)
    out_apx = rc2.stdout + rc2.stderr
    n_approx = out_apx.count("approx")
    if n_approx != 2:  # x 与 z 各一条，y 没有
        print(f"[FAIL] apx program: expected 2 'approx', got {n_approx}:\n{out_apx}")
        return False
    print("[PASS] apx program: exactly 2 'approx' instructions in cir dump (x, z)")
    return True


def main():
    if not COREC.exists():
        print(f"[FAIL] missing native compiler: {COREC}")
        return 1
    results = [test_apx_tag_parses(), test_apx_tag_no_semantic_change()]
    passed = sum(results)
    print(f"{passed}/{len(results)} passed")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
