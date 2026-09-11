#!/usr/bin/env python3
"""TODO #29：struct/数组字面量的「名 / 型 / 同质性」三校验（F5 同族剩余面）。

修复前（全部 rc=0 静默，无任何诊断）：
  ① struct 字段名被丢弃 —— parser 取 `fni` 后从未写入，字段值按**声明位序**绑定：
     `P{b: 11, a: 22}` 静默得 a=11, b=22（**静默错值**级）；未知字段 / 重复字段 / 缺字段
     三校验均不存在。
  ② 字段类型不与声明比对 —— `P{a: 1, b: "x"}`（b: int）、`P{a: 1}`（缺 b）、
     `P{a: 1, b: 3}`（b: Q 结构体）全部静默通过。
  ③ 数组元素同质性不检查 —— `[1, "x", 3]` rc=0，且元素类型随**末**元素漂移（soundness 漏放）。

修复（checker 侧补齐 + 消费者按名字绑定）：
  · parser 把字段名 idx 写进 wrapper.b（EXPR_STRUCT 契约，见 ast.cr / parser.cr）；
  · checker：名字 → 声明下标（未知 TS02 / 重复 TS04 / 缺字段 TS01）+ 字段类型 vs 声明
    比对（TS03，走 type_compat_strict 引擎判定）+ 数组元素同质（TK02）；
  · 值**按名字绑定**（与 Python bootstrap 的 gen_struct_lit 同语义）：ir_gen 按 wrapper.b
    解出字段位存储，求值顺序仍为**源序**（c3 = 副作用顺序判据）；
  · 五码入 run_frontend 的**硬错误**名单（与 R002/TK05 同类）——修复前这些错误即便报出也
    照常产出二进制（静默错产物）；现在 rc=1 且不产生产物。
  · 泛型参数**未实例化**时两侧任一含 TYP_GENERIC_PARAM → 跳过类型比对（不假拒：泛型函数体
    内的值类型、泛型结构体字段的声明类型）；字段类型为结构体泛型参数的走绑定路径，结果
    TYP_GENERIC_APPLY 的实参按**参数声明序**取（旧代码按字面量字段序 = 参数序 ≠ 字段序时错位）。

判据：
  值 6 例（build+run，退出码 = main 返回值 & 0xFF）+ 类型 10 例（负 7：各出对应码且 rc≠0
  且**无产物**；正 3：rc=0 且无 error[）。
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
        "struct: 乱序字段按名字绑定（①主判据；修复前静默得 1122）",
        """
struct P { a: int, b: int }
fn main() -> int {
    p := P{b: 11, a: 22};
    return p.a * 100 + p.b;
}
""",
        2211,
    ),
    (
        "struct: 乱序 + 求值顺序 = 源序（副作用判据）",
        """
g : int, mut = 0;
fn nx() -> int { g = g + 1; return g; }
struct P { a: int, b: int }
fn main() -> int {
    p := P{b: nx(), a: nx()};
    return p.a * 100 + p.b;
}
""",
        201,
    ),
    (
        "struct: 三字段逆序（错位累积面）",
        """
struct P { a: int, b: int, c: int }
fn main() -> int {
    p := P{c: 3, b: 2, a: 1};
    return p.a * 100 + p.b * 10 + p.c;
}
""",
        123,
    ),
    (
        "struct: 乱序 + 复合字段值（嵌套字面量）",
        """
struct Q { u: int, v: int }
struct P { a: int, b: Q }
fn main() -> int {
    p := P{b: Q{u: 2, v: 3}, a: 1};
    return p.a * 100 + p.b.u * 10 + p.b.v;
}
""",
        123,
    ),
    (
        "generic struct: 乱序字段 + 泛型参数绑定（Pair[T]）",
        """
struct Pair[T] { left: T, right: T }
fn main() -> int {
    p := Pair { right = 2, left = 1 };
    return p.left * 10 + p.right;
}
""",
        12,
    ),
    (
        "generic struct: 双参数、字段序 ≠ 参数序（实参须按参数声明序）",
        """
struct Sw[A, B] { y: B, x: A }
fn main() -> int {
    s := Sw { x = 1, y = 2 };
    return s.x * 10 + s.y;
}
""",
        12,
    ),
    (
        "generic fn body: 乱序字面量经 monomorph 克隆仍按名字绑定（名字随克隆保留）",
        """
struct P { a: int, b: int }
fn f[T](x: T) -> int {
    p := P{b: 2, a: x};
    return p.a * 10 + p.b;
}
fn main() -> int { return f(1); }
""",
        12,
    ),
    (
        "嵌套泛型应用字段类型 Box[Box[int]]（既存载荷写坏回归——修复前假拒）",
        """
struct Box[T] { val: T }
struct Holder { b: Box[Box[int]] }
fn main() -> int {
    h := Holder{b: Box{val: Box{val: 7}}};
    return h.b.val.val;
}
""",
        7,
    ),
]

# ---- 类型判据：(名称, 源码, 期望码 / "ACCEPT") ----
CHECK_CASES = [
    # 负控：各出对应码、rc≠0、且不产生产物（硬错误门）
    (
        "① 未知字段 + 缺字段（TS02 + TS01）",
        """
struct P { a: int, b: int }
fn main() -> int {
    p := P{c: 1, a: 2};
    return 0;
}
""",
        "TS02",
    ),
    (
        "① 重复字段（TS04）",
        """
struct P { a: int, b: int }
fn main() -> int {
    p := P{a: 1, a: 2, b: 3};
    return 0;
}
""",
        "TS04",
    ),
    (
        "① 缺字段（TS01）",
        """
struct P { a: int, b: int }
fn main() -> int {
    p := P{a: 1};
    return 0;
}
""",
        "TS01",
    ),
    (
        "② 字段类型与声明不符（TS03；b: int 收 string）",
        """
struct P { a: int, b: int }
fn main() -> int {
    p := P{a: 1, b: "x"};
    return 0;
}
""",
        "TS03",
    ),
    (
        "② 嵌套结构体字段错型（TS03；b: Q 收 int）",
        """
struct Q { u: int, v: int }
struct P { a: int, b: Q }
fn main() -> int {
    p := P{a: 1, b: 3};
    return 0;
}
""",
        "TS03",
    ),
    (
        "③ 数组元素异质（TK02）",
        """
fn main() -> int {
    a := [1, "x", 3];
    return 0;
}
""",
        "TK02",
    ),
    (
        "③ 数组元素异质：嵌套 vs 扁平（TK02）",
        """
fn main() -> int {
    a := [[1, 2], 3];
    return 0;
}
""",
        "TK02",
    ),
    # 正控：合法写法 rc=0 且无 error[
    (
        "正控：乱序但名/型/完整性全对 → 接受",
        """
struct P { a: int, b: int }
fn main() -> int {
    p := P{b: 11, a: 22};
    return p.a * 100 + p.b;
}
""",
        "ACCEPT",
    ),
    (
        "正控：泛型函数体内泛型参数值赋给确定类型字段（不得假拒）",
        """
struct P { a: int, b: int }
fn f[T](x: T) -> int {
    p := P{a: 1, b: x};
    return p.a * 100 + p.b;
}
fn main() -> int { return f(7); }
""",
        "ACCEPT",
    ),
    (
        "正控：同质数组 + 嵌套同形数组 → 接受",
        """
fn main() -> int {
    a := [1, 2, 3];
    b := [[1, 2], [3, 4]];
    return a[0] + b[1][1];
}
""",
        "ACCEPT",
    ),
    (
        "正控：嵌套泛型应用在**返回位**（既存载荷写坏回归——修复前假拒 TF01）",
        """
struct Box[T] { val: T }
fn mk() -> Box[Box[int]] { return Box{val: Box{val: 1}}; }
fn main() -> int { b := mk(); return b.val.val; }
""",
        "ACCEPT",
    ),
    (
        "负控：嵌套泛型应用**错型**仍拒（两趟修复不得引入假阴性——评审 Important #1 的反面）",
        """
struct Box[T] { val: T }
struct P { b: Box[Box[int]] }
fn main() -> int { p := P{b: Box{val: Box{val: "s"}}}; return 0; }
""",
        "TS03",
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
    d, src_path = _write_tmp(source, "f29_v_")
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
    """负控：`build` 必须 rc≠0、报出期望码、且**不产生产物**（硬错误门 = 非静默）；
    正控：rc=0 且无任何 error[。"""
    d, src_path = _write_tmp(source, "f29_c_")
    bin_path = os.path.join(d, "t.bin")
    try:
        r = subprocess.run(
            ["nice", "-n", "19", str(COREC), "build", src_path, "-o", bin_path, "--static"],
            cwd=BASE, capture_output=True, text=True, timeout=300,
        )
        produced = os.path.exists(bin_path)
    finally:
        shutil.rmtree(d, ignore_errors=True)

    out = r.stdout + r.stderr
    if expect == "ACCEPT":
        ok = r.returncode == 0 and "error[" not in out
    else:
        ok = (
            r.returncode != 0
            and f"error[{expect}]" in out
            and not produced          # 硬错误：绝不产出静默错产物
            and " --> " in out        # 定位诊断（行:列）
        )
    if ok:
        print(f"[PASS] {name}: {expect}")
        return True
    print(f"[FAIL] {name}: expect={expect} rc={r.returncode} produced={produced}")
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
