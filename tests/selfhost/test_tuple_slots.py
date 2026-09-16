#!/usr/bin/env python3
"""F5（TODO #2026-09-16-2）：EXPR_TUPLE 元素槽位——复合元素元组的类型记录回归。

根因（两处，同属「元组元素类型错录」）：
  ① AST 槽位（parser.cr 元组分支）：曾把「元素在 g_ast 连续」当契约，只记首元素节点 +
     元素个数；复合表达式元素自身子树占多槽 → 后续元素槽位全错位（元素子节点被当元素）。
     修复 = 先解析全部元素值，再**统建连续 wrapper**（kind=EXPR_NONE，a=值节点）；
     EXPR_TUPLE 契约改为 a=首 wrapper（连续）/ b=元素个数，消费点（checker/ir_gen/
     monomorph/opt）经 ast_a(wrapper + i) 解引用。
  ② 类型侧表落盘（checker.cr EXPR_TUPLE 分支）：data_start 曾在元素推断循环**前**取，
     而元素自身的推断会向 g_gen_apply_data 追加数据（嵌套元组 / 泛型应用）→ 后续元素
     落点被顶开、extra 与实际落点错位。修复 = 两趟（先全推、再连续落盘）。

判据（每例双向断言：期望拒绝的必须出现对应码；期望接受的必须 rc=0 且无 error[）：
  异型拒 / 异长拒 / 同型接受 + 反证边界（数组在首位、单节点元素）+ 嵌套元组三例。
"""

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"

# (名称, 源码, 期望) —— 期望："ACCEPT" / "TA01"（赋值类型不合）/"LEN"（长度约束违反）
CASES = [
    (
        "compound elem same type accepted (F5 ①假拒回归)",
        """
fn main() -> int {
    a : [int; 3] = [1, 2, 3];
    x : ., mut = (1, a);
    y : ., mut = (1, [1, 2, 3]);
    x = y;
    return 0;
}
""",
        "ACCEPT",
    ),
    (
        "compound elem diff type rejected (F5 ②soundness)",
        """
fn h() -> int { return 5; }
fn main() -> int {
    x : ., mut = (1, [1, 2, 3]);
    y : ., mut = (1, h());
    x = y;
    return 0;
}
""",
        "TA01",
    ),
    (
        "compound elem length mismatch rejected (F5 ③N 面)",
        """
fn main() -> int {
    x : ., mut = (1, [1, 2, 3]);
    y : ., mut = (1, [1, 2]);
    x = y;
    return 0;
}
""",
        "LEN",
    ),
    (
        "both compound elems same type accepted",
        """
fn main() -> int {
    x : ., mut = (1, [1, 2, 3]);
    y : ., mut = (2, [7, 8, 9]);
    x = y;
    return 0;
}
""",
        "ACCEPT",
    ),
    (
        "both compound elems diff elem type rejected",
        """
fn main() -> int {
    x : ., mut = (1, [1, 2, 3]);
    y : ., mut = (2, ["a", "b", "c"]);
    x = y;
    return 0;
}
""",
        "TA01",
    ),
    (
        "array in first slot accepted (反证边界)",
        """
fn main() -> int {
    a : [int; 3] = [1, 2, 3];
    x : ., mut = (a, 1);
    y : ., mut = ([1, 2, 3], 1);
    x = y;
    return 0;
}
""",
        "ACCEPT",
    ),
    (
        "single-node elems accepted (反证边界)",
        """
fn main() -> int {
    a : [int; 3] = [1, 2, 3];
    x : ., mut = (1, a);
    y : ., mut = (1, a);
    x = y;
    return 0;
}
""",
        "ACCEPT",
    ),
    (
        "single-node elems diff type rejected (反证边界)",
        """
fn main() -> int {
    a : [int; 3] = [1, 2, 3];
    x : ., mut = (1, a);
    y : ., mut = (1, 5);
    x = y;
    return 0;
}
""",
        "TA01",
    ),
    (
        "ident elems length mismatch rejected",
        """
fn main() -> int {
    a : [int; 3] = [1, 2, 3];
    b : [int; 4] = [1, 2, 3, 4];
    x : ., mut = (1, a);
    y : ., mut = (2, b);
    x = y;
    return 0;
}
""",
        "LEN",
    ),
    (
        "nested tuple elems accepted",
        """
fn main() -> int {
    x : ., mut = (1, (2, 3));
    y : ., mut = (1, (2, 3));
    x = y;
    return 0;
}
""",
        "ACCEPT",
    ),
    (
        "nested tuple arity mismatch rejected",
        """
fn main() -> int {
    x : ., mut = (1, (2, 3));
    y : ., mut = (1, (2, 3, 4));
    x = y;
    return 0;
}
""",
        "TA01",
    ),
    (
        "nested tuple vs int rejected",
        """
fn main() -> int {
    x : ., mut = (1, (2, 3));
    y : ., mut = (1, 5);
    x = y;
    return 0;
}
""",
        "TA01",
    ),
    (
        "nested tuple in first slot vs int rejected",
        """
fn main() -> int {
    x : ., mut = ((2, 3), 1);
    y : ., mut = (5, 1);
    x = y;
    return 0;
}
""",
        "TA01",
    ),
]

# IR 路径冒烟：复合元素元组必须能过 ir_gen（wrapper 解引用 + 数组元素构造）
IR_SMOKE = """
fn g() -> int { return 33; }
fn main() -> int {
    t := (g() + 1, [10, 20, 30]);
    return 0;
}
"""


def run_case(name, source, expect):
    with tempfile.NamedTemporaryFile("w", suffix=".cr", delete=False) as src:
        src.write(source)
        src_path = src.name
    try:
        result = subprocess.run(
            ["nice", "-n", "19", str(COREC), "check", src_path],
            cwd=BASE,
            capture_output=True,
            text=True,
            timeout=60,
        )
    finally:
        os.unlink(src_path)

    output = result.stdout + result.stderr
    if expect == "ACCEPT":
        ok = result.returncode == 0 and "error[" not in output
    elif expect == "TA01":
        ok = result.returncode == 1 and "error[TA01]" in output and "Assignment type mismatch" in output
    elif expect == "LEN":
        ok = result.returncode == 1 and "error[TA01]" in output and "Array length constraint" in output
    else:
        ok = False

    if ok:
        print(f"[PASS] {name}: {expect}")
        return True
    print(f"[FAIL] {name}: expect={expect} rc={result.returncode}")
    print(output)
    return False


def run_ir_smoke():
    """复合元素元组的 IR 生成 + ELF 冒烟（check 不过 ir_gen，此例专门覆盖 wrapper 解引用）。"""
    src_dir = tempfile.mkdtemp(prefix="f5_tuple_")
    src_path = os.path.join(src_dir, "t.cr")
    out_path = os.path.join(src_dir, "t.bin")
    with open(src_path, "w") as f:
        f.write(IR_SMOKE)
    try:
        result = subprocess.run(
            ["nice", "-n", "19", str(COREC), "build", src_path, "-o", out_path, "--static"],
            cwd=BASE,
            capture_output=True,
            text=True,
            timeout=300,
        )
        output = result.stdout + result.stderr
        if result.returncode != 0 or "error[" in output:
            print("[FAIL] compound tuple IR smoke: build failed")
            print(output)
            return False
        run = subprocess.run([out_path], capture_output=True, text=True, timeout=60)
        if run.returncode != 0:
            print(f"[FAIL] compound tuple IR smoke: exit={run.returncode}")
            return False
        print("[PASS] compound tuple IR smoke: build+run")
        return True
    finally:
        shutil.rmtree(src_dir, ignore_errors=True)


def main():
    if not COREC.exists():
        print(f"[FAIL] missing native compiler: {COREC}")
        return 1
    results = [run_case(*case) for case in CASES]
    results.append(run_ir_smoke())
    passed = sum(results)
    print(f"{passed}/{len(results)} passed")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
