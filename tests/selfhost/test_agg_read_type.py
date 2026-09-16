#!/usr/bin/env python3
"""✅ **已修（#78 批 2 T3）—— 本套件已挂 CI**（TODO #78；计划 §11/§12/§13）。

被测缺陷 = **聚合读丢型**：四个读点把结果槽**硬定 `TI_INT`**，而聚合槽的规范存储形式是
**精确（scaled）**（apx 批不变量：「聚合面不存在 apx 形式」）⇒ 「按 IR 值型触发」的下游
在**经聚合读入的值**上全部失明（`dex_store_adjust` / `dex_scale_int` / 二元分流 / extern 边界 /
LET 继承 / 泛型键名串）。

四个读点（`develop 99ae6bdd` 现状坐标）：
  · 结构体字段读 `ir_gen.cr:2590`（`new_ir_var("field", TI_INT)`）+ 发射 `:2597`
  · 数组/切片元素读 `:2655` + 发射 `:2660` / `:2668`
  · match 臂载荷绑定 `:2393` + 发射 `:2395` / `:2412`
  · match 结果槽 `:2299`（**裁-AGG-2 = 登记不纳入本批**）

**判据网（三条腿）**
  · **腿 A（语义值）** = R1–R5：`build --static` 产物的**运行值**（期望 7）。改前实测：
    全部 **1**（静默错值；`check` 0 error）。
  · **腿 B（界面见证，裁-AGG-1 的验收形状：槽型正确 **且** 无重复转换）** —— 用**门控忠实**的
    IR 见证（`.cir` 文本转储），两个方向都要：
      - **反方向（读槽 ≠ `TI_INT`）**：`dex_scale_int`（`ir_gen.cr:1033-1040`）的**唯一产物**是
        `const _dsc = 1000000` + `binary _dxt = <v> * _dsc`，其门 = `irv_type(var) == TI_INT`
        ⇒ **`_dxt` 一旦出现，就证明读槽仍是 int**（R1/R3/R4）。
      - **正方向（读槽 = `TI_DEX_S`）**：`dex_scaled_to_bits`（`:1016-1029`）对**非字面量**的产物是
        `i2f _dxf` + `const _dxsc` + `binary _dxdiv = _dxf / _dxsc`，其门 = `irv_type(var) == TI_DEX_S`
        ⇒ **`_dxdiv` 必须出现**（R5 写回 apx 槽）。
      - **无重复转换**：`_dxt` 计数必须 **0**（不能「槽型对但仍多转一次」）、`_dxdiv` 计数必须 **1**
        （不能漏转、也不能转两遍）。
  · **腿 C（非回归钉子）** = R7（Core 调用实参，**改前已正确**——Core 形参物化 scaled ↔ 读值 scaled
    同形）+ N1（apx 批已转正的「raw 锚定 / 比较点」形）。

**两条钉子为何是钉子而不是 RED**（T1 实测修正）：读码 + 实测双证；R7 今日 rc=7。
**R6（extern 实参）不在此文件**：其运行路径被 `corearch --link` 静态链**既有崩溃**阻塞
（`tests/suite/ffi_test.cr:8-11` 头注明载）⇒ 按先例 `test_dex_arith.py::test_extern_dex_arg_cir`
用 **IR 断言**判定（本文件 `leg_b` 的 B4 即该断言的最小形态）。

**挂点（照 #93 批三件套，T3 已完成）**：`src/ci/run.sh` 的 `selfhost-tests` job 已挂本套件 +
`ci_hook_allowlist.txt` 条目**已删** + 本头注已转正（判据 = `test_ci_hook_coverage.py` PASS）。

**修后实测（T3）**：R1/R2/R3/R5 **elf=7 全绿**（改前全 1）· 腿 B 四条见证**全绿** · 腿 C 钉子在位。
**R4（元组）不在此列**：见下方 `KNOWN_GAP` —— 按**裁-AGG-3**「元组无声明面 ⇒ 登记，不纳入本批」，
本套件对它**只观测、不计入判据**（[GAP] 行），后续批修复时须把它移进 `CASES`。

**探针纪律**（照 apx 批 §0bis/§0ter）：涉全局必须 `mut`；apx 探针**一律显式形**
（`d : dex, apx = 7.0`——类型位写 `.` 会让 apx 槽压根不建立 ⇒ 假绿）。
"""

import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"

R1 = """
struct S { f: dex }
fn main() -> int {
    d : dex, apx = 7.0;
    s : ., mut = S { f = d };
    x := s.f;
    if x * 2.0 != 14.0 { return 1; }
    return 7;
}
"""

R2 = """
enum E { V(dex) }
fn main() -> int {
    d : dex, apx = 7.0;
    e : ., mut = V(d);
    return match e { V(x) => { if x * 2.0 != 14.0 { return 1; } return 7; } };
}
"""

R3 = """
fn main() -> int {
    d : dex, apx = 7.0;
    a : [dex; 2] = [d, 1.0];
    if a[0] * 2.0 != 14.0 { return 1; }
    return 7;
}
"""

R4 = """
fn main() -> int {
    d : dex, apx = 7.0;
    t := (d, 1.0);
    if (t . 0) * 2.0 != 14.0 { return 1; }
    return 7;
}
"""

R5 = """
g : dex, apx, mut = 1.0;
struct S { f: dex }
fn main() -> int {
    d : dex, apx = 7.0;
    s : ., mut = S { f = d };
    g = s.f;
    if g != 7.0 { return 1; }
    return 7;
}
"""

# R6：extern 实参——**仅作 cir 断言载体**（运行路径既有崩溃，见头注）
R6 = """
struct S { f: dex }
extern fn dex_agg_arg_check(d: dex) -> int;
fn main() -> int {
    d : dex, apx = 7.0;
    s : ., mut = S { f = d };
    r := dex_agg_arg_check(s.f);
    return r;
}
"""

# ── 腿 C：非回归钉子（改前即绿，修后必须仍绿）──
R7 = """
struct S { f: dex }
fn dbl(x: dex) -> dex { return x * 2.0; }
fn main() -> int {
    d : dex, apx = 7.0;
    s : ., mut = S { f = d };
    y := dbl(s.f);
    if y != 14.0 { return 1; }
    return 7;
}
"""

N1 = """
struct S { f: dex }
fn main() -> int {
    d : dex, apx = 7.0;
    s : ., mut = S { f = d };
    if @raw_int(s.f) / 1000000 != 7 { return 1; }
    if s.f != 7.0 { return 2; }
    return 7;
}
"""

# (name, expect_rc, src, kind)
#   kind: "red"  = 本批目标（改前必红）
#         "nail" = 非回归钉子（改前应绿、修后仍绿）
CASES = [
    ("R1_let_relay", 7, R1, "red"),
    ("R2_match_payload", 7, R2, "red"),
    ("R3_local_arr_elem", 7, R3, "red"),
    ("R5_write_apx_slot", 7, R5, "red"),
    ("R7_core_arg_nail", 7, R7, "nail"),
    ("N1_apx_batch_green_nail", 7, N1, "nail"),
]

# **已知未覆盖面（裁-AGG-3：登记，不在本批）**——元组数字下标（`t . 0`）。
# 元组**无声明面**（`ir_gen.cr` 的 EXPR_TUPLE 分支给元组 var 定型 `TI_INT`，不携带元素 ti；
# `agg_field_read_form` 对 `ast_type_val > 0` 的数字下标形态显式返回 `TI_INT`）⇒ 本批的
# 「声明面形式」通道取不到它 ⇒ **期望值不变**（仍是错值）。**本组只观测、不计入判据**：
# 它在此是为了「不静默」——后续批要修时，这里的观测值就是起点（并且届时须把它移进 CASES）。
KNOWN_GAP = [
    ("R4_tuple_elem", 7, R4, "gap"),
]


def _workdir(src):
    d = tempfile.mkdtemp(prefix="agg_read_type_")
    p = os.path.join(d, "main.cr")
    with open(p, "w", encoding="utf-8") as f:
        f.write(src)
    return d, p


def run_corec(args, src):
    """跑 corec（**cwd = 仓库根**——否则 `cannot locate src/runtime/rt.cr`，判据假红）。"""
    d, p = _workdir(src)
    r = subprocess.run(
        [str(COREC)] + args, cwd=str(BASE),
        capture_output=True, text=True, timeout=600,
    )
    return r, d, p


def compile_and_run(src, tag):
    """check（诊断码集）+ build --static + 运行值。返回 (check_rc, codes, build_rc, elf_rc)。"""
    d, p = _workdir(src)
    chk = subprocess.run([str(COREC), "check", p], cwd=str(BASE),
                         capture_output=True, text=True, timeout=600)
    codes = sorted(set(re.findall(r"error\[([A-Z0-9]+)\]", chk.stdout + chk.stderr)))
    out_bin = os.path.join(d, "out.bin")
    bld = subprocess.run([str(COREC), "build", p, "-o", out_bin, "--static"],
                         cwd=str(BASE), capture_output=True, text=True, timeout=900)
    elf = None
    if bld.returncode == 0 and os.path.exists(out_bin):
        os.chmod(out_bin, 0o755)
        run = subprocess.run([out_bin], capture_output=True, text=True, timeout=120)
        elf = run.returncode
    return chk.returncode, codes, bld.returncode, elf


def cir_of(src):
    d, p = _workdir(src)
    r = subprocess.run([str(COREC), "cir", p], cwd=str(BASE),
                       capture_output=True, text=True, timeout=600)
    return r.stdout + r.stderr


def leg_b_interface():
    """界面见证（门控忠实；两个方向 + 无重复转换）。返回失败项列表。"""
    fails = []

    # B1 反方向：R1 的精确路径**不得**再出现 dex_scale_int 的产物 `_dxt`
    #    （其门 = irv_type(var) == TI_INT ⇒ 出现即证明读槽仍是 int）
    cir1 = cir_of(R1)
    n_dxt1 = len(re.findall(r"binary\s+_dxt = ", cir1))
    if n_dxt1 != 0:
        fails.append(f"B1 反方向：R1 出现 `_dxt` x{n_dxt1}（读槽仍是 TI_INT ⇒ 二次缩放）")
    else:
        print("[PASS] B1 反方向：R1 无 `_dxt`（读槽已非 TI_INT，无重复转换）")

    # B2 反方向：R3（局部数组元素）同判
    cir3 = cir_of(R3)
    n_dxt3 = len(re.findall(r"binary\s+_dxt = ", cir3))
    if n_dxt3 != 0:
        fails.append(f"B2 反方向：R3 出现 `_dxt` x{n_dxt3}")
    else:
        print("[PASS] B2 反方向：R3 无 `_dxt`")

    # B3 正方向：R5 写回 apx 槽**必须**出现 dex_scaled_to_bits 的非字面量产物 `_dxdiv`
    #    （其门 = irv_type(var) == TI_DEX_S ⇒ 出现即证明读槽已是 TI_DEX_S），且**恰好一次**
    cir5 = cir_of(R5)
    n_div5 = len(re.findall(r"binary\s+_dxdiv = ", cir5))
    if n_div5 != 1:
        fails.append(f"B3 正方向：R5 的 `_dxdiv` 计数 = {n_div5}（期望恰好 1：既证槽型，又证不重复转换）")
    else:
        print("[PASS] B3 正方向：R5 `_dxdiv` 恰好 1（读槽 = TI_DEX_S 且转换不重复）")

    # B4 R6：`load_field` 与 `call_extern` 之间**必须**有转换（改前为空序列 ⇒ RED）
    cir6 = cir_of(R6)
    m = re.search(r"load_field\s+field = [^\n]*\n((?:.*\n)*?)\s*call_extern", cir6)
    if m is None:
        fails.append("B4：R6 的 cir 里没找到 `load_field … call_extern` 序列（探针/转储形态变化？）")
    else:
        between = m.group(1)
        if re.search(r"_dxdiv|i2f|_dxf", between):
            print("[PASS] B4：R6 `load_field` → `call_extern` 之间有转换（ABI 规范化）")
        else:
            fails.append("B4：R6 `load_field` → `call_extern` 之间**无转换**（extern 契约破坏）")
    return fails


def main():
    report = "--report" in sys.argv
    fails = []
    print("=" * 78)
    print("聚合读丢型（TODO #78）—— RED 语料（批 2 T2；修复后应转绿）")
    print("=" * 78)
    for name, expect, src, kind in CASES:
        chk, codes, bld, elf = compile_and_run(src, name)
        ok = (elf == expect)
        if not ok:
            fails.append(f"{name}: elf={elf}（期望 {expect}）check={chk} codes={codes}")
        tag = "PASS" if ok else "FAIL"
        print(f"[{tag}] {name:<26} kind={kind:<4} 观测: check={chk} codes={codes} "
              f"build={bld} elf={elf}  | 期望 elf={expect}")
    print()
    for name, expect, src, _kind in KNOWN_GAP:
        chk, codes, bld, elf = compile_and_run(src, name)
        print(f"[GAP ] {name:<26} kind=gap  观测: check={chk} codes={codes} "
              f"build={bld} elf={elf}  | 期望（修复后）elf={expect} "
              f"【裁-AGG-3 登记未覆盖：元组无声明面 ⇒ 本批不改；不计入判据】")
    print()
    bfails = leg_b_interface()
    fails.extend(bfails)
    print()
    if report:
        print("（--report：只观测不改判据）")
        return 0
    if fails:
        print(f"[FAIL] 未达判据 {len(fails)} 项：")
        for f in fails:
            print("   ", f)
        return 1
    print(f"[PASS] 聚合读丢型套件全绿（{len(CASES)} 例 + 腿 B）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
