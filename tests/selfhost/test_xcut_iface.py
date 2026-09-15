#!/usr/bin/env python3
"""R2 P3b Task 2：横切接口接线（序列/可索引形状判定接管 `TYP_*` 直比）的行为覆盖集。

交付面（计划 Task 2 Step 3）：索引兜底门（`EXPR_INDEX` 落空）与切片（range）分支的
**类别判定**从 `get_type_kind == TYP_ARRAY/TYP_SLICE/TI_STR` 直比换位到**横切形状满足判定**
（`iface_satisfies_term` + `sh_shape_*`；形状项见 `iface_registry.cr` 横切形状段）：
  · 索引兜底门 → **可索引**形状（`⊤ₖ(SEQUENCE) ∪ ⊤ₖ(STRING)`；与 IP_INDEX 许可集逐行同集）；
  · range 分支 → **序列**形状（`⊤ₖ(SEQUENCE)`）**∧ 固定性位 ≥ 0**（数组 = 固定长 ⇒ 产视图；
    切片 = 视图 ⇒ 现状 `TI_UNIT`，登记面 A.2 #15 未接线）。
结果分支（arr→元素+F2 / slice→元素 / str→int）**原地保留**（同时决定结果类型；A.2 #16-18）。

**行为保持是本文件的判据**：以下每一例的 check rc / 诊断码 / 诊断文案 / 产物有无，改动前后
**逐例相同**（旧二进制 = P3b Task 0 提交 `9aa1786c` 的构建，见报告 §5 的同源对拍）。本套件同时又
是**新接线的咬合面**：range 分支若丢掉固定性维度（切片 range 改判为可索引），`slice_range_unit_pinned`
转红；索引兜底门若把形状拒绝集换错（如把 STRING 移出可索引形状），`str_index_*` 一族的负控转红。

判据口径：正例三路同证（check rc=0 ∧ ELF rc=N ∧ interp rc=N）；负例 = check rc=1 + 措辞断言
+ `build` **无产物**（收紧面同址）。`COREC_BIN` 环境变量可指向基线二进制做同源对拍（默认
`build/corec`）；临时源文件一律写在仓库根（cwd —— `/tmp` 下探针会触发 import 解析假失败）。
"""

import os
import resource
import subprocess
import tempfile
from pathlib import Path


BASE = Path(__file__).resolve().parents[2]
COREC = Path(os.environ.get("COREC_BIN", str(BASE / "build" / "corec")))


def _no_core_dump():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def _compile(source: str, cmd="check"):
    fd, src = tempfile.mkstemp(suffix=".cr")
    with os.fdopen(fd, "w") as f:
        f.write(source)
    out = src[:-3]
    if cmd == "build":
        args = [str(COREC), "build", src, "-o", out, "--static"]
    else:
        args = [str(COREC), "check", src]
    r = subprocess.run(args, capture_output=True, text=True, cwd=BASE, timeout=180)
    return r, out, src


def _cleanup(*paths):
    for p in paths:
        try:
            os.unlink(p)
        except FileNotFoundError:
            pass


def case_dual(name, source, expect_rc):
    """正例三路同证：check rc=0 ∧ ELF rc=N ∧ interp rc=N（索引/切片语义真的跑到产物）。"""
    rc_chk, outc, srcc = _compile(source, cmd="check")
    try:
        if rc_chk.returncode != 0:
            print(f"[FAIL] {name}: check rc={rc_chk.returncode}（应有零诊断）: {rc_chk.stdout}{rc_chk.stderr}")
            return False
    finally:
        _cleanup(srcc, outc, outc + ".ccr")
    r, out, src = _compile(source, cmd="build")
    try:
        if r.returncode != 0:
            print(f"[FAIL] {name}: build rc={r.returncode}: {r.stdout}{r.stderr}")
            return False
        rr = subprocess.run([out], capture_output=True, text=True, timeout=10,
                            preexec_fn=_no_core_dump)
        if rr.returncode != expect_rc:
            print(f"[FAIL] {name}: ELF expected rc {expect_rc}, got {rr.returncode}")
            return False
    finally:
        _cleanup(src, out, out + ".ccr")
    ri = subprocess.run([str(COREC), "run", source], capture_output=True, text=True,
                        cwd=BASE, timeout=180)
    if ri.returncode != expect_rc:
        print(f"[FAIL] {name}: interp expected rc {expect_rc}, got {ri.returncode}: {ri.stdout}{ri.stderr}")
        return False
    print(f"[PASS] {name}: ELF+interp rc={rr.returncode}")
    return True


def case_reject(name, source, needles, soft):
    """负例：check rc≠0 + 诊断针 + `build` 面形态与既有诊断门同型（逐例钉住，防静默迁移）。

    `soft=True`：软诊断（`check_error`）= check rc=1 而 **build rc=0 + 产物照出**（与既有
    约束检查同门；TK01 索引门属此类——本套件把它钉住）。`soft=False`：硬错误 = build rc≠0 +
    **无产物**（F2 的字面越界 / F11 的切片界属此类）。两态都必须与改动前逐例相同。"""
    r, out, src = _compile(source, cmd="check")
    try:
        if r.returncode == 0:
            print(f"[FAIL] {name}: expected rejection, got rc=0（静默通过面复活）")
            return False
        text = r.stdout + r.stderr
        for n in needles:
            if n not in text:
                print(f"[FAIL] {name}: rc={r.returncode} 但缺诊断 {n!r}: {text}")
                return False
    finally:
        _cleanup(src, out, out + ".ccr")
    rb, outb, srcb = _compile(source, cmd="build")
    try:
        art = os.path.exists(outb)
        if soft:
            if rb.returncode != 0 or not art:
                print(f"[FAIL] {name}: 软诊断面应为 build rc=0 + 产物，实得 rc={rb.returncode} artifact={art}")
                return False
            tag = "软诊断（build rc=0 + 产物）"
        else:
            if rb.returncode == 0 or art:
                print(f"[FAIL] {name}: 硬错误面应为 build rc≠0 + 无产物，实得 rc={rb.returncode} artifact={art}")
                return False
            tag = "硬错误（无产物）"
        print(f"[PASS] {name}: check rc={r.returncode} + {needles!r} + {tag}")
        return True
    finally:
        _cleanup(srcb, outb, outb + ".ccr")


# ─── 正例（三路同证）：形状接管的三个结果分支 + range 产视图 ───
ARR_INDEX = """
fn main() -> int {
    a := [10, 20, 30];
    return a[1];
}
"""

SLICE_INDEX = """
fn main() -> int {
    a := [10, 20, 30];
    s := a[0..3];
    return s[2];
}
"""

STR_INDEX = """
fn main() -> int {
    s := "AB";
    return s[0];
}
"""

RANGE_ARRAY_SLICE = """
fn main() -> int {
    a := [1, 2, 3, 4];
    s := a[1..3];
    return s[0];
}
"""

RANGE_FULL_ARRAY = """
fn main() -> int {
    a := [7, 8];
    s := a[0..2];
    return s[1];
}
"""

# ─── 负例（收紧面同址；行为保持：改动前后同拒同码）──
INT_INDEX = """
fn main() -> int {
    x := 5;
    return x[0];
}
"""

BOOL_INDEX = """
fn main() -> int {
    b := true;
    return b[0];
}
"""

PTR_INDEX = """
fn main() -> int {
    x := 7;
    p := &x;
    return p[0];
}
"""

STRUCT_INDEX = """
struct S { a: int }
fn main() -> int {
    s := S{a: 1};
    return s[0];
}
"""

# ─── 结果分支/表示面钉子（行为保持：既有诊断与 range 结果形态逐字不变）──
OOB_LITERAL = """
fn main() -> int {
    a := [1, 2];
    return a[5];
}
"""

SLICE_BOUNDS = """
fn main() -> int {
    a := [1, 2, 3];
    s := a[0..5];
    return 0;
}
"""

# range 的**切片**分支现状 = `TI_UNIT`（A.2 #15 登记：IP_INDEX_RANGE 未接线）⇒ 二次切片当下
# 不可索引（TK01）。本钉即 range 分支固定性维度的咬合面：若丢掉固定性（切片 range 改产视图），
# 本例转 rc=0 = 静默放宽 ⇒ 红。
SLICE_RANGE_UNIT = """
fn main() -> int {
    a := [1, 2, 3, 4];
    s := a[0..4];
    t := s[0..2];
    return t[0];
}
"""


def main():
    print(f"[corec] {COREC}")
    ok = [
        # ── 正例：结果分支三态（数组 / 切片 / 字符串）+ range 产视图 ──
        case_dual("arr_index_elem", ARR_INDEX, 20),
        case_dual("slice_index_elem", SLICE_INDEX, 30),
        case_dual("str_index_byte", STR_INDEX, 65),
        case_dual("range_array_view_indexable", RANGE_ARRAY_SLICE, 2),
        case_dual("range_full_array_view", RANGE_FULL_ARRAY, 8),
        # ── 负例：非容器行一律 TK01（形状拒绝集与 IP_INDEX 许可集同集；软诊断 = build 照出）──
        case_reject("int_index_rejected", INT_INDEX, ["error[TK01]", "Cannot index non-array type"], True),
        case_reject("bool_index_rejected", BOOL_INDEX, ["error[TK01]", "Cannot index non-array type"], True),
        case_reject("ptr_index_rejected", PTR_INDEX, ["error[TK01]", "Cannot index non-array type"], True),
        case_reject("struct_index_rejected", STRUCT_INDEX, ["error[TK01]", "Cannot index non-array type"], True),
        # ── 表示面钉子：F2/F11 既有诊断（硬错误）、range 切片分支的 unit 结果（行为保持）──
        case_reject("arr_oob_literal_pinned", OOB_LITERAL, ["index out of bounds: 5 (array length 2)"], False),
        case_reject("slice_bounds_pinned", SLICE_BOUNDS, ["slice out of bounds:"], False),
        case_reject("slice_range_unit_pinned", SLICE_RANGE_UNIT, ["error[TK01]"], True),
    ]

    passed = sum(ok)
    print(f"{passed}/{len(ok)} passed")
    return 0 if passed == len(ok) else 1


if __name__ == "__main__":
    raise SystemExit(main())
