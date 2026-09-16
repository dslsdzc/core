#!/usr/bin/env python3
"""F5 同族（TODO #2026-09-16-2 姊妹条目）：EXPR_STRUCT / EXPR_STRUCTPAT / EXPR_ARRAY 聚合字面量槽位。

根因（与已修的 EXPR_TUPLE 同源——一处槽契约、三处分支实例）：
  parser 的 struct 字面量 / struct 模式 / 数组字面量三分支曾把「字段值（元素）节点在 g_ast
  连续」当契约，只记首个值节点 + 个数，且**逐值后随建 wrapper 交错分配**（`fv := parse_expr();
  ast_alloc(0, fv, ...)`）。值节点是复合表达式（调用 / 嵌套字面量 / 下标）时其子树自占多槽，
  夹在相邻 wrapper 之间 ⇒ 第 2 个起槽位整体错位，消费者读到值节点的**子节点**：
    ① 静默错误值（rc=0）：P{a:11, b:g()} 的 b 得 0；[1, g(), 3] 的 a[1] 得 0；
    ② 崩溃：[[1,2],[3,4]] 的 a[1] 被读成扁平 int 3 → a[1][0] SIGSEGV 139；
    ③ soundness 漏放：[[1,2],[3,4]] 与 [5,6] 元素类型被错录为 int，类型互赋静默通过。
  修复 = 三分支统一两趟（先解析全部值进暂存表、后统建连续 wrapper）。契约：
  EXPR_STRUCT/EXPR_STRUCTPAT/EXPR_ARRAY(字面量形) = a=首 wrapper、b=个数；
  wrapper（kind=EXPR_NONE）在 g_ast 中连续、wrapper.a=值节点。消费点 5 处逐 wrapper 解引用：
  checker（infer_expr 前向）/ ir_gen gen_expr 与 ast_patch_node / monomorph 克隆（改「先克隆
  值、后统建 wrapper」）/ opt（折叠）。注意类型形 [T; N] / [T] 由 parse_type 产出
  （a=内层类型节点、b=0、int_val=尺寸），不经字面量分支、不受本契约影响。

判据（值判据两向非空：含单槽元素反证边界与泛型实例体克隆路径；类型判据双向：期望拒的必出
      对应码，期望收的必 rc=0 且无 error[）：
  值 9 例（build+run，退出码 = main 返回值 & 0xFF）+ 类型 4 例（check）。
"""

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"

# ---- 值判据：(名称, 源码, main 期望返回值) ----
VALUE_CASES = [
    (
        "struct: compound value in last field (F5 ①主判据)",
        """
struct P { a: int, b: int }
fn g() -> int { return 3; }
fn main() -> int {
    p := P{a: 11, b: g()};
    return p.a * 100 + p.b;
}
""",
        1103,
    ),
    (
        "struct: both fields compound (F5 ①主判据)",
        """
struct P { a: int, b: int }
fn g() -> int { return 3; }
fn h() -> int { return 4; }
fn main() -> int {
    p := P{a: g(), b: h()};
    return p.a * 10 + p.b;
}
""",
        34,
    ),
    (
        "struct: 3 fields, compound in middle (错位累积面)",
        """
struct P { a: int, b: int, c: int }
fn g() -> int { return 5; }
fn main() -> int {
    p := P{a: 1, b: g(), c: 2};
    return p.a * 100 + p.b * 10 + p.c;
}
""",
        152,
    ),
    (
        "struct: nested struct literal as field value",
        """
struct Q { u: int, v: int }
struct P { a: int, b: Q }
fn main() -> int {
    p := P{a: 1, b: Q{u: 2, v: 3}};
    return p.a * 100 + p.b.u * 10 + p.b.v;
}
""",
        123,
    ),
    (
        "struct: single-slot fields only (反证边界——旧交错顺序下此形本已正确)",
        """
struct P { a: int, b: int }
fn main() -> int {
    p := P{a: 11, b: 22};
    return p.a * 100 + p.b;
}
""",
        1122,
    ),
    (
        "generic fn body: struct literal cloned by monomorph",
        """
struct P { a: int, b: int }
fn f[T](x: T) -> int {
    p := P{a: 1, b: x};
    return p.a * 100 + p.b;
}
fn main() -> int {
    return f(7);
}
""",
        107,
    ),
    (
        "array: compound element in middle (F5 ③主判据)",
        """
fn g() -> int { return 7; }
fn main() -> int {
    a := [1, g(), 3];
    return a[0] * 10 + a[1];
}
""",
        17,
    ),
    (
        "array: nested array element read (修复前 a[1][0] SIGSEGV)",
        """
fn main() -> int {
    a := [[1, 2], [3, 4]];
    return a[0][0] * 10 + a[1][1];
}
""",
        14,
    ),
    (
        "array: repeat form [value; N] 共享值节点",
        """
fn g() -> int { return 4; }
fn main() -> int {
    a := [g() + 1; 3];
    return a[0] + a[1] + a[2];
}
""",
        15,
    ),
]

# ---- 类型判据：(名称, 源码, 期望)："ACCEPT" / "TA01" ----
CHECK_CASES = [
    (
        "soundness: nested vs flat array literal rejected (F5 ③)",
        """
fn main() -> int {
    x : ., mut = [[1, 2], [3, 4]];
    y : ., mut = [5, 6];
    x = y;
    return 0;
}
""",
        "TA01",
    ),
    (
        "array element count mismatch rejected",
        """
fn main() -> int {
    x : ., mut = [1, 2, 3];
    y : ., mut = [5, 6];
    x = y;
    return 0;
}
""",
        "LEN",
    ),
    (
        "same-shape nested arrays accepted (反证边界)",
        """
fn main() -> int {
    x : ., mut = [[1, 2], [3, 4]];
    y : ., mut = [[5, 6], [7, 8]];
    x = y;
    return 0;
}
""",
        "ACCEPT",
    ),
    (
        "array type form [T; N] + literal accepted (类型形不受字面量契约影响)",
        """
fn main() -> int {
    a : [int; 3] = [1, 2, 3];
    return a[2];
}
""",
        "ACCEPT",
    ),
]


def _write_tmp(src, prefix):
    d = tempfile.mkdtemp(prefix=prefix)
    path = os.path.join(d, "t.cr")
    with open(path, "w") as f:
        f.write(src)
    return d, path


def run_value_case(name, source, expect):
    """build → run，退出码须等于 expect & 0xFF（main 返回值即进程退出码的低 8 位）。"""
    d, src_path = _write_tmp(source, "f5agg_v_")
    bin_path = os.path.join(d, "t.bin")
    try:
        b = subprocess.run(
            ["nice", "-n", "19", str(COREC), "build", src_path, "-o", bin_path, "--static"],
            cwd=BASE, capture_output=True, text=True, timeout=300,
        )
        out = b.stdout + b.stderr
        if b.returncode != 0 or not os.path.exists(bin_path):
            print(f"[FAIL] {name}: build rc={b.returncode} (expect value {expect})")
            print(out)
            return False
        r = subprocess.run([bin_path], capture_output=True, text=True, timeout=60)
        want = expect & 0xFF
        if r.returncode == want:
            print(f"[PASS] {name}: rc={r.returncode} == {expect}")
            return True
        print(f"[FAIL] {name}: rc={r.returncode} want={want} (value {expect})")
        return False
    finally:
        shutil.rmtree(d, ignore_errors=True)


def run_check_case(name, source, expect):
    d, src_path = _write_tmp(source, "f5agg_c_")
    try:
        r = subprocess.run(
            ["nice", "-n", "19", str(COREC), "check", src_path],
            cwd=BASE, capture_output=True, text=True, timeout=120,
        )
    finally:
        shutil.rmtree(d, ignore_errors=True)

    out = r.stdout + r.stderr
    if expect == "ACCEPT":
        ok = r.returncode == 0 and "error[" not in out
    elif expect == "TA01":
        ok = r.returncode == 1 and "error[TA01]" in out and "Assignment type mismatch" in out
    elif expect == "LEN":
        ok = r.returncode == 1 and "error[TA01]" in out and "Array length constraint" in out
    else:
        ok = False
    if ok:
        print(f"[PASS] {name}: {expect}")
        return True
    print(f"[FAIL] {name}: expect={expect} rc={r.returncode}")
    print(out)
    return False


def main():
    if not COREC.exists():
        print(f"[FAIL] missing native compiler: {COREC}")
        return 1
    results = [run_value_case(*c) for c in VALUE_CASES]
    results += [run_check_case(*c) for c in CHECK_CASES]
    passed = sum(results)
    print(f"{passed}/{len(results)} passed")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
