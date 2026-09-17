#!/usr/bin/env python3
"""apx（dex）形式转换缺口族回归套件（apx 批 T5；自举编译器 build/corec）。

覆盖 = TODO #2026-09-16-17（方法调用实参不转换）· #2026-09-16-18（第 9 个 binary64 栈参）· ⑦a（全局运行期初值）
      + apx 批 T2 新增两活点：**模块限定调用** `m.f(x)` 与**指针写** `*p = d`
      + 聚合四类写点（字段 / 元素 / 元组 / 枚举载荷）+ 比较点声明面查表（L10）

**两条硬约束（写本文件的探针前必读）**
  ① 涉全局的探针**必须 `mut`**——不可变 + 字面量初值的全局被 `find_global_const_node`
     （`ir_gen.cr:592-611`）折叠成 `IR_CONST`，读点不碰全局行 ⇒ **探针假绿**。
  ② **`apx` 探针一律用显式形 `d : dex, apx = …`**——类型位写 `.`（推断）时 `declared_ti`
     落 `TI_UNIT`（`ir_gen.cr:2377-2393`）⇒ **apx 槽压根不建立**，探针退化为普通精确 dex
     ⇒ **全部假绿**（apx 审计 errata E1；本套件 `test_decl_form_selfcheck` 就是这条的机器守卫）。
  ③ **apx 面没有解释器腿**：`corec run` 对 `IR_I2F/IR_F2I` 显式拒收 rc=255（能力边界，
     `interp.cr:263-266`/`:704-705`）⇒ 主判据 = ELF 侧读数；**拒收本身是「apx 槽确已建立」
     的反向自证**（见 `test_apx_slot_present_selfcheck`）。

**判据分工（实测，勿混淆）**：本套件是 apx 面的**载荷判据**。ELF canary + `.ccr` 四条
（`ptr_arith`/`generics_test` 两语料）对 apx 面**零覆盖**——apx 批 T3 突变双向实测：把 apx 面
改坏两次，canary 与 `.ccr` 四条**在两种突变下全部 IDENTICAL**。⇒ **跨面回归必须由该面的判据
承担**，不得以「canary 还绿着」代替（详见 `2026-09-16-criteria-strength-audit.md` §0ter）。

**期望值一律经 `@raw_int` 锚定**（唯一显式形式通道，`ir_gen.cr:1699-1708`）——直接比较
decimal 会踩 `TODO #2026-09-16-30`：apx 字面量走 lexer 位模式（~2ulp 截断），与聚合槽里的精确 scaled
值在 binary64 下**可不相等**。
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

EDGE = "1000000"  # scaled 边界（S = 10^6）


def run_corec(args, source):
    """源码写临时文件后跑 `corec <args> FILE`；首行注入唯一注释以避开 .core/cache/cir 缓存。"""
    src = f"// apx-conv-{uuid.uuid4()}\n" + source
    with tempfile.NamedTemporaryFile("w", suffix=".cr", delete=False) as f:
        f.write(src)
        path = f.name
    try:
        return subprocess.run(
            [str(COREC)] + args + [path], cwd=BASE,
            capture_output=True, text=True, timeout=180,
        )
    finally:
        os.unlink(path)


def build_and_run(source, tag):
    """check(期望 0) → build --static → 跑产物 ⇒ (check_rc, build_rc, elf_rc)。"""
    src = f"// apx-conv-{uuid.uuid4()}\n" + source
    with tempfile.NamedTemporaryFile("w", suffix=".cr", delete=False) as f:
        f.write(src)
        path = f.name
    out = str(BASE / "build" / f"_apx_{tag}_{uuid.uuid4().hex[:8]}")
    try:
        chk = subprocess.run([str(COREC), "check", path], cwd=BASE,
                             capture_output=True, text=True, timeout=180)
        if chk.returncode != 0:
            # 已知**软诊断**容忍（体例照 TODO #2026-09-16-14：把现状固化成判据）：
            #   B04「Cannot use 'x' while it is borrowed」= borrow checker 无 NLL 的既有面，
            #   是**软**诊断（`build` 仍 rc=0、产物照出）⇒ 只容忍「**恰 {B04}**」；
            #   出现任何其它诊断码 ⇒ 仍按失败处理（防它掩盖真回归）。
            codes = set(re.findall(r"error\[([A-Z0-9]+)\]", chk.stdout + chk.stderr))
            if codes != {"B04"}:
                return chk.returncode, None, None
        bld = subprocess.run([str(COREC), "build", path, "-o", out, "--static"],
                             cwd=BASE, capture_output=True, text=True, timeout=300)
        if bld.returncode != 0:
            return chk.returncode, bld.returncode, None
        os.chmod(out, 0o755)
        run = subprocess.run([out], cwd=BASE, capture_output=True, timeout=120)
        return 0, 0, run.returncode
    finally:
        os.unlink(path)
        if os.path.exists(out):
            os.unlink(out)


# ── 探针表：name, source, 期望 ELF rc, 备注 ──
# 期望值 7（或 1）= 该形态「正确」。**期望 15 已退役**（2026-09-17 批 5 重锁：`dex?` 整族修复后
# 无「期望 15」行；旧值留痕见 CASES 中 `relocked_optional_dex_pinch` 上注；退役断言见
# `test_sentinel_annotation_present`）。
CASES = [
    # ── #2026-09-16-17：非直调调用形态 ──
    ("method_arg_apx", """
struct S1 { v: int }
impl S1 { fn m(self: S1, x: dex) -> int { return @raw_int(x) / 1000000; } }
fn main() -> int { d : dex, apx = 7.0; s : ., mut = S1 { v = 0 }; return s.m(d); }
""", 7, "方法调用实参（#2026-09-16-17 原形）"),
    ("method_arg_self_offset", """
struct S2 { v: int }
impl S2 { fn m(self: S2, k: int, x: dex) -> int { return @raw_int(x) / 1000000; } }
fn main() -> int { d : dex, apx = 7.0; s : ., mut = S2 { v = 0 }; return s.m(1, d); }
""", 7, "方法调用 + self/形参偏移（接收者占 arg_vars[0]）"),
    ("module_qualified_call", """
import dex
fn main() -> int {
    d : dex, apx = 7.0;
    a := dex_str(d);
    if !str_eq(a, "7") { return 3; }
    b := dex.dex_str(d);
    if !str_eq(b, "7") { return 4; }
    return 7;
}
""", 7, "模块限定调用 m.f(x)（apx 批 T2 新增活点；rc=4 即该形态未转换）"),
    # ── #2026-09-16-18：第 9 个 binary64 栈参（= #2026-09-16-17 同一修复）──
    ("stack_arg_9th_method", """
struct S9 { v: int }
impl S9 {
    fn m(self: S9, a: dex, b: dex, c: dex, e: dex, f: dex, g: dex, h: dex, i: dex, x: dex) -> int {
        return @raw_int(x) / 1000000;
    }
}
fn main() -> int {
    s : ., mut = S9 { v = 0 };
    a1 : dex, apx = 1.0;
    a2 : dex, apx = 2.0;
    a3 : dex, apx = 3.0;
    a4 : dex, apx = 4.0;
    a5 : dex, apx = 5.0;
    a6 : dex, apx = 6.0;
    a7 : dex, apx = 7.0;
    a8 : dex, apx = 8.0;
    lx : dex, apx = 7.0;
    return s.m(a1, a2, a3, a4, a5, a6, a7, a8, lx);
}
""", 7, "#2026-09-16-18 第 9 个 binary64 栈参（方法形）"),
    ("stack_arg_9th_direct", """
fn f9(a: dex, b: dex, c: dex, e: dex, f: dex, g: dex, h: dex, i: dex, x: dex) -> int {
    return @raw_int(x) / 1000000;
}
fn main() -> int {
    a1 : dex, apx = 1.0;
    a2 : dex, apx = 2.0;
    a3 : dex, apx = 3.0;
    a4 : dex, apx = 4.0;
    a5 : dex, apx = 5.0;
    a6 : dex, apx = 6.0;
    a7 : dex, apx = 7.0;
    a8 : dex, apx = 8.0;
    lx : dex, apx = 7.0;
    return f9(a1, a2, a3, a4, a5, a6, a7, a8, lx);
}
""", 7, "直调同形对照（#2026-09-16-18 机理裁定用：同形只差调用形态）"),
    # ── 聚合四类写点 ──
    ("struct_literal_field", """
struct S3 { f: dex }
fn main() -> int { d : dex, apx = 7.0; s : ., mut = S3 { f = d }; return @raw_int(s.f) / 1000000; }
""", 7, "结构体字面量字段写点"),
    ("struct_field_assign", """
struct S3 { f: dex }
fn main() -> int { d : dex, apx = 7.0; s : ., mut = S3 { f = 1.0 }; s.f = d; return @raw_int(s.f) / 1000000; }
""", 7, "字段赋值写点"),
    ("array_literal_elem", """
fn main() -> int { d : dex, apx = 7.0; a : [dex; 2] = [d, 1.0]; return @raw_int(a[0]) / 1000000; }
""", 7, "数组字面量元素写点"),
    ("index_assign_dynamic", """
fn main() -> int { d : dex, apx = 7.0; a : [dex; 2] = [1.0, 1.0]; i : ., mut = 0; a[i] = d; return @raw_int(a[i]) / 1000000; }
""", 7, "动态下标赋值写点"),
    ("slice_elem_assign", """
fn main() -> int { d : dex, apx = 7.0; a : [dex; 3] = [1.0, 1.0, 1.0]; s := a[0..2]; s[1] = d; return @raw_int(s[1]) / 1000000; }
""", 7, "切片元素写点"),
    ("tuple_elem", """
fn main() -> int { d : dex, apx = 7.0; t := (d, 1.0); return @raw_int(t . 0) / 1000000; }
""", 7, "元组元素写点（数字下标须写 `t . 0`，带空格——`t.0` 会被词法器读成 dex 字面量）"),
    ("enum_payload", """
enum E1 { V(dex) }
fn main() -> int { d : dex, apx = 7.0; e := V(d); return match e { V(x) => { return @raw_int(x) / 1000000; } }; }
""", 7, "枚举载荷写点"),
    ("pointer_write", """
fn main() -> int {
    d : dex, apx = 7.0;
    x : dex, mut = 1.0;
    p := &x;
    *p = d;
    return @raw_int(x) / 1000000;
}
""", 7, "指针写 `*p = d`（apx 批 T2 新增活点；check 另发 B04 软诊断 = TODO #2026-09-16-14 既有面）"),
    # ── ⑦a：全局运行期初值 ──
    ("global_runtime_init_apx", """
fn sc() -> dex { return 7.0; }
g11 : dex, apx, mut = sc();
fn main() -> int { return @raw_int(g11) / 1000000; }
""", 7, "⑦a 全局运行期初值（apx 全局，mut 必写）"),
    ("global_apx_as_method_arg", """
struct S1 { v: int }
impl S1 { fn m(self: S1, x: dex) -> int { return @raw_int(x) / 1000000; } }
g13 : dex, apx, mut = 7.0;
fn main() -> int { s : ., mut = S1 { v = 0 }; return s.m(g13); }
""", 7, "apx 全局作方法实参（全局 vs 局部同形对拍）"),
    # ── 比较点声明面查表（L10）──
    ("compare_agg_read_vs_exact", """
struct S3 { f: dex }
fn main() -> int {
    e : dex = 1.5;
    s : ., mut = S3 { f = 1.5 };
    if s.f == e { return 1; }
    return 0;
}
""", 1, "聚合读 vs 精确值比较（L10；无声明面查表 ⇒ 0）"),
    # ── 非回归（修法不得改坏已覆盖面）──
    ("nonreg_direct_call", """
fn g(x: dex) -> int { return @raw_int(x) / 1000000; }
fn main() -> int { d : dex, apx = 7.0; return g(d); }
""", 7, "直调实参（已覆盖面）"),
    ("nonreg_return_site", """
fn f() -> dex { d : dex, apx = 7.0; return d; }
fn main() -> int { v := f(); return @raw_int(v) / 1000000; }
""", 7, "返回点（已覆盖面；apx 审计 ②a「恒不触发」已被证伪）"),
    ("nonreg_generic_dex_param", """
fn g12[T](t: T, x: dex) -> int { return @raw_int(x) / 1000000; }
fn main() -> int { d : dex, apx = 7.0; return g12(1, d); }
""", 7, "泛型实例化后 dex 形参（非回归钉）"),
    ("nonreg_exact_struct", """
struct S3 { f: dex }
fn main() -> int { d : dex = 7.0; s : ., mut = S3 { f = d }; return @raw_int(s.f) / 1000000; }
""", 7, "精确形对照（结构体字段）"),
    ("nonreg_exact_array", """
fn main() -> int { d : dex = 7.0; a : [dex; 2] = [d, 1.0]; return @raw_int(a[0]) / 1000000; }
""", 7, "精确形对照（数组元素）"),
    ("nonreg_exact_enum", """
enum E1 { V(dex) }
fn main() -> int { d : dex = 7.0; e := V(d); return match e { V(x) => { return @raw_int(x) / 1000000; } }; }
""", 7, "精确形对照（枚举载荷）"),
    # ══════════════════════════════════════════════════════════════════════════
    # ✅ **已重锁（2026-09-17 批 5 / opt-dex；TODO #2026-09-16-29 = 原 #91）—— 旧值 15 留痕**
    #   · **旧值（留痕，不得复活）**：本行原期望 **15**（= `4619567317775286272 / 10⁶` 低 8 位），
    #     作为「`dex?` 整族未被形式转换覆盖」的**零足迹绊线**存在于 apx 批（#2026-09-16-29 段）。
    #   · **归因（显式）**：批 5 把 `dex?` 的写点门/槽型/形参槽/返回门/读点定型一律改为
    #     **按声明面定形式**（G1 裁决 = scaled；`ir_gen.cr` 的 `dex_opt_type_node`/`dex_opt_slot_ti`）
    #     ⇒ LET 写点不再把 bits 原样入槽 ⇒ 本行**必然变值**（15 → 7）。
    #   · **重锁（同批）**：期望值改为 **7**（= 7000000 / 10⁶）；改名 `relocked_optional_dex_pinch`
    #     （原 `SENTINEL_optional_dex_pinch`——「哨兵」语义已随修复退役，名字留痕在注释里）。
    #   · ⛔ **不得把 15 抄回来**（本仓已两次栽在「抄错形/抄错值」上）；判据网侧另设
    #     `test_sentinel_annotation_present` 的**退役断言**（无「期望 15」行）双保险。
    #   · 覆盖面（本批新增的完整判据网）见 `tests/selfhost/test_opt_dex.py`（30 例 + 四态对拍）。
    # ══════════════════════════════════════════════════════════════════════════
    ("relocked_optional_dex_pinch", """
fn main() -> int {
    d : dex, apx = 7.0;
    x : dex? = d;
    return match x { Some(v) => { return @raw_int(v) / 1000000; } None => { return 0; } };
}
""", 7, "重锁（批 5 · 原哨兵值 15 已退役；留痕见上注）"),
]


def test_cases():
    """逐例：check rc=0 + 产物 rc == 期望。"""
    fails = []
    for name, src, want, note in CASES:
        chk, bld, got = build_and_run(src, name)
        if chk != 0:
            fails.append(f"{name}: check rc={chk}")
            print(f"[FAIL] {name}: check rc={chk} — {note}")
            continue
        if bld != 0:
            fails.append(f"{name}: build rc={bld}")
            print(f"[FAIL] {name}: build rc={bld} — {note}")
            continue
        if got != want:
            fails.append(f"{name}: ELF rc={got} want={want}")
            print(f"[FAIL] {name}: ELF rc={got} 期望 {want} — {note}")
        else:
            print(f"[PASS] {name}: ELF rc={got} — {note}")
    return fails


def test_sentinel_annotation_present():
    """哨兵判据（**两态口径**，2026-09-17 批 5 重锁后更新）：
      · 若存在「期望 15」的行 ⇒ 必须带 SENTINEL 标记（旧规则保留：将来某面若再需绊线仍适用）；
      · **本档现状**（`dex?` 已修）⇒ 断言「**无任何期望 15 的行**」= 绊线已退役。
        若有人把 15 抄回来（或把修复回退）⇒ 本断言红 + 用例读数红（双保险）。"""
    for name, _s, want, note in CASES:
        if want == 15:
            assert note == "SENTINEL", f"{name} 期望 15 但未标 SENTINEL"
            print("[PASS] sentinel 标注在位（期望 15 的行必须带 SENTINEL 标记）")
            return 0
    assert all(w != 15 for _n, _s, w, _nt in CASES), "仍有「期望 15」行"
    print("[PASS] 零足迹哨兵**已退役**（批 5：`dex?` 修复后无「期望 15」行；旧值 15 留痕于 CASES 上注）")
    return 0


def test_decl_form_selfcheck():
    """**覆盖面自证（防「探针不触发」假绿）**：显式形建立 apx 槽、推断形不建立。
    判别法 = `.cir` 里是否出现 binary64 位模式常量（`const dex = <大整数>`）。"""
    explicit = ("// x\nfn main() -> int { d : dex, apx = 7.0; return @raw_int(d) / 1000000; }\n")
    inferred = ("// x\nfn main() -> int { d : ., apx = 7.0; return @raw_int(d) / 1000000; }\n")
    r1 = run_corec(["cir"], explicit)
    import re
    def max_const(txt):
        vals = [int(m) for m in re.findall(r"const\s+dex\s*=\s*(\d+)", txt)]
        return max(vals) if vals else -1
    v1 = max_const(r1.stdout + r1.stderr)
    if v1 < 10**10:
        print(f"[FAIL] 显式形未建立 apx 槽（.cir 无 bits 常量；最大 dex 常量 = {v1}）")
        return 1
    # ── 推断形（`.` + apx）：**批 8 条目 5（裁定 (B)）后转硬错**（`error[P26]` + 零产物）──
    # **旧值留痕（本套件原判据）**：`check` rc=0 且 `.cir` **无** bits 常量（推断形不建立 apx 槽 ⇒ 探针退化）。
    # 该「无 bits 常量」的判据在硬错下**不再可达**（源根本不编译）⇒ 按「显式归因 + 同批重锁 + 旧值留痕」重锁为**拒收断言**。
    chk_inf = run_corec(["check"], inferred)
    bld_inf = run_corec(["build", "--static", "-o", "/tmp/_apx_conv_inf.bin"], inferred)
    art_inf = os.path.exists("/tmp/_apx_conv_inf.bin") or os.path.exists("/tmp/_apx_conv_inf.bin.ccr")
    if art_inf:
        os.unlink("/tmp/_apx_conv_inf.bin") if os.path.exists("/tmp/_apx_conv_inf.bin") else None
    if chk_inf.returncode != 1 or "error[P26]" not in chk_inf.stdout or bld_inf.returncode != 1 or art_inf:
        print(f"[FAIL] 推断形 `. + apx` 未按条目 5 拒收：check={chk_inf.returncode} "
              f"P26={'error[P26]' in chk_inf.stdout} build={bld_inf.returncode} 产物={art_inf}")
        return 1
    v2 = -1
    # 反向自证：显式形在解释器下必被拒收（IR_F2I 无 binary64 语义）
    it = subprocess.run([str(COREC), "run",
                         "fn main() -> int { d : dex, apx = 7.0; return @raw_int(d) / 1000000; }"],
                        cwd=BASE, capture_output=True, text=True, timeout=120)
    if it.returncode != 255:
        print(f"[FAIL] 显式形解释器未拒收（rc={it.returncode}，期望 255）")
        return 1
    print(f"[PASS] 声明形自证：显式形 bits 常量 {v1} / 推断形最大 {v2} / 解释器拒收 rc=255")
    return 0


def test_double_form_parity():
    """C1 双形对拍（通用腿）：同一形态的 **apx 形 vs 精确形** 结果必须一致。"""
    pairs = [
        ("field", """
struct S3 { f: dex }
fn main() -> int { d : D = DVAL; s : ., mut = S3 { f = d }; return @raw_int(s.f) / 1000000; }
"""),
        ("elem", """
fn main() -> int { d : D = DVAL; a : [dex; 2] = [d, 1.0]; return @raw_int(a[0]) / 1000000; }
"""),
        ("tuple", """
fn main() -> int { d : D = DVAL; t := (d, 1.0); return @raw_int(t . 0) / 1000000; }
"""),
    ]
    bad = 0
    for tag, tpl in pairs:
        apx = tpl.replace("DVAL", "7.0").replace(": D ", ": dex, apx ")
        exa = tpl.replace("DVAL", "7.0").replace(": D ", ": dex ")
        _c1, _b1, r1 = build_and_run(apx, f"c1a_{tag}")
        _c2, _b2, r2 = build_and_run(exa, f"c1e_{tag}")
        if r1 != r2 or r1 != 7:
            print(f"[FAIL] 双形对拍 {tag}: apx={r1} exact={r2}（均应 7）")
            bad += 1
        else:
            print(f"[PASS] 双形对拍 {tag}: apx=exact={r1}")
    return bad


def main():
    fails = []
    fails += test_cases()
    if test_sentinel_annotation_present() != 0:
        fails.append("sentinel_annotation")
    rc = test_decl_form_selfcheck()
    if rc != 0:
        fails.append("decl_form_selfcheck")
    n = test_double_form_parity()
    if n:
        fails.append(f"double_form_parity x{n}")
    print()
    if fails:
        print(f"[FAIL] {len(fails)} 项：")
        for f in fails:
            print("   ", f)
        sys.exit(1)
    print(f"[PASS] apx 形式转换套件全绿（{len(CASES)} 例 + 自证 + 双形对拍）")


if __name__ == "__main__":
    main()
