#!/usr/bin/env python3
"""可选 dex（`dex?`）整族回归套件（TODO #2026-09-16-29 / 原 #91；自举编译器 build/corec）。

覆盖 = 四态对拍（裸/装箱 × bits/scaled）+ 家族面（LET / 赋值 / 取址·INV-1 / 指针写·INV-2 /
形参 / 返回 / 结构体字面量字段 / 字段赋值 / 全局槽 / 枚举载荷 / `?` 解包）+ 编译期拒绝面 + 非回归钉子。

**判据模型（G10，维护者 2026-09-17 裁决——三条纪律都写进断言，缺一不可）**
  ① **主判据 = 四态对拍**：四条同义探针（裸/装箱 × bits/scaled）的 ELF 读数**互等**，且
     **锚定格**（scaled 两格）== 语义值（本档 = 7）——「四格互等」**必须含锚定格**，
     否则「四格一起错」也算互等（假绿）。
  ② **禁第三态**（本档核心）：`kind=="bits"` 的探针，解释器腿必须是 **255**
     （= bits→scaled 转换在场时 `IR_I2F/IR_F2I` 的能力边界拒收；`interp.cr:263-266`/`:704-705`）。
     **255 是期望值**，不是「只要不改就算过」；出现任何第三个值一律判红。
  ③ **不许单腿绿结案**：ELF 绿 ∧ interp 落第三态 ⇒ 仍判红（两腿写进同一条断言）。

**为什么 bits 源的 interp 必须是 255（而不是正确值）**：`dex?` 载荷的规范形式 = **scaled**
（G1 裁决：装箱对象是聚合类载体、无形式位可挂；rep 位 1 比特承载不了 2 位信息）⇒ 任何 bits 源
在写点都要经 `dex_bits_to_scaled`（F2I）转换 ⇒ 解释器**必然**拒收 rc=255。
⇒ `255` 同时是「转换确已发生」的**正据**（apx 审计 §errata E1 的同一用法）。
**若将来实现的转换不产生 F2I，此期望值须重新推导——不得静默放宽。**

**RED 基线（2026-09-17 实测于改前树；本档先红后用）**：`fs_bare_bits` 15 · `assign_bits` 15 ·
`addr_read_bits` 15 · `ptr_write_bits` 15 · `ret_bits` 15 · `field_lit_bits` 15 · `global_bits` 15 ·
`enum_payload_opt_bits` 15 · **`param_bits` ELF 0 / interp 15（双路径分歧）** ·
**`param_branch_bits` ELF 101 / interp 172（分歧）**；四态其余三格与全部 scaled 格已绿。

**三条硬约束（承 apx 套件体例）**
  ① 涉全局探针**必须 `mut`**——不可变 + 字面量初值的全局被 `find_global_const_node` 折叠成
     `IR_CONST`（读点不碰全局行 ⇒ **假绿**）。
  ② apx 源**一律显式形** `d : dex, apx = …`（类型位写 `.` ⇒ `declared_ti` 落 `TI_UNIT` ⇒
     apx 槽压根不建立 ⇒ 假绿）。
  ③ 取址面探针用 **`*p` 形态**（`x : dex? = d; p := &x; match *p`）——原形「`&x` 后直接读 `x`」
     触发**软诊断 B04**（borrow checker 无 NLL 的既有面，`build` 仍 rc=0）；
     **绕开的是软诊断、不是 bug**（G8）。本档 check 面**严格**（出现任何诊断码即判失败）。

期望值一律经 `@raw_int` 锚定（唯一显式形式通道）——不直接比 decimal，否则踩 TODO #2026-09-16-30。
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

ANCHOR = 7          # 语义锚定值（7.0 经 @raw_int / 10^6）
BITS_CONST_MIN = 10 ** 10   # binary64 位模式的量级下界（apx 槽自证用）


def run_corec(args, source):
    """源码写临时文件后跑 `corec <args> FILE`；首行注入唯一注释以避开 .core/cache/cir 缓存。"""
    src = f"// opt-dex-{uuid.uuid4()}\n" + source
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
    """check(严格：任何诊断码 = 失败) → build --static → 跑产物 ⇒ (check_rc, build_rc, elf_rc)。"""
    src = f"// opt-dex-{uuid.uuid4()}\n" + source
    with tempfile.NamedTemporaryFile("w", suffix=".cr", delete=False) as f:
        f.write(src)
        path = f.name
    out = str(BASE / "build" / f"_optdex_{tag}_{uuid.uuid4().hex[:8]}")
    try:
        chk = subprocess.run([str(COREC), "check", path], cwd=BASE,
                             capture_output=True, text=True, timeout=180)
        if chk.returncode != 0:
            return chk.returncode, None, None
        bld = subprocess.run([str(COREC), "build", path, "-o", out, "--static"],
                             cwd=BASE, capture_output=True, text=True, timeout=300)
        if bld.returncode != 0:
            return 0, bld.returncode, None
        os.chmod(out, 0o755)
        run = subprocess.run([out], cwd=BASE, capture_output=True, timeout=120)
        return 0, 0, run.returncode
    finally:
        os.unlink(path)
        if os.path.exists(out):
            os.unlink(out)


def run_interp(source):
    """解释器腿：把源**内联**给 `corec run`（run 的参数是代码字符串，不是文件路径）。"""
    src = f"// opt-dex-{uuid.uuid4()}\n" + source
    p = subprocess.run([str(COREC), "run", src], cwd=BASE,
                       capture_output=True, text=True, timeout=180)
    return p.returncode


MATCH_BODY = """    return match x { Some(v) => { return @raw_int(v) / 1000000; } None => { return 0; } };
"""

# ── 四态对拍四条（仅源形式与是否 Some 不同；主判据的基元）──
FOUR_STATE = {
    "fs_bare_bits":    ("bits",   "    d : dex, apx = 7.0;\n    x : dex? = d;\n"),
    "fs_bare_scaled":  ("scaled", "    e : dex = 7.0;\n    x : dex? = e;\n"),
    "fs_boxed_bits":   ("bits",   "    d : dex, apx = 7.0;\n    x : dex? = Some(d);\n"),
    "fs_boxed_scaled": ("scaled", "    e : dex = 7.0;\n    x : dex? = Some(e);\n"),
}


def _four_state_src(setup):
    return "fn main() -> int {\n" + setup + MATCH_BODY + "}\n"


# ── 家族/钉子探针表：name, source, 期望 ELF rc, kind, 备注 ──
# kind 语义（判据模型 ②③）：
#   "bits"   = 源为 apx 位模式 ⇒ 写点必转换 ⇒ ELF == 期望 ∧ interp == 255（转换在场正据）
#   "scaled" = 源为精确形式 ⇒ 无需转换 ⇒ ELF == 期望 ∧ interp == 期望
#   "int"    = 非 dex 面（对照）⇒ ELF == 期望 ∧ interp == 期望
CASES = [
    # ── 家族写点/边界面（修前 15 的九条 = 本批 RED 主体）──
    ("assign_bits", """
fn main() -> int {
    d : dex, apx = 7.0;
    x : dex?, mut = None;
    x = d;
    return match x { Some(v) => { return @raw_int(v) / 1000000; } None => { return 0; } };
}
""", 7, "bits", "赋值写点（修前 15）"),
    ("ptr_write_bits", """
fn main() -> int {
    d : dex, apx = 7.0;
    x : dex?, mut = None;
    p := &x;
    *p = d;
    return match *p { Some(v) => { return @raw_int(v) / 1000000; } None => { return 0; } };
}
""", 7, "bits", "指针写（INV-2；修前 15）"),
    ("addr_read_bits", """
fn main() -> int {
    d : dex, apx = 7.0;
    x : dex? = d;
    p := &x;
    return match *p { Some(v) => { return @raw_int(v) / 1000000; } None => { return 0; } };
}
""", 7, "bits", "取址槽（INV-1 交点；`*p` 形态绕开软诊断 B04；修前 15）"),
    ("ret_bits", """
fn f() -> dex? {
    d : dex, apx = 7.0;
    return d;
}
fn main() -> int {
    x := f();
    return match x { Some(v) => { return @raw_int(v) / 1000000; } None => { return 0; } };
}
""", 7, "bits", "返回面 `-> dex?`（修前 15）"),
    ("param_bits", """
fn g(x: dex?) -> int {
    return match x { Some(v) => { return @raw_int(v) / 1000000; } None => { return 0; } };
}
fn main() -> int {
    d : dex, apx = 7.0;
    return g(d);
}
""", 7, "bits", "形参面 `dex?` ← apx 实参（修前 ELF 0 / interp 15 = 双路径分歧）"),
    ("param_branch_bits", """
fn g(x: dex?) -> int {
    match x {
        Some(v) => { return 100 + (@raw_int(v) % 100); }
        None => { return 200; }
    }
    return 55;
}
fn main() -> int {
    d : dex, apx = 7.0;
    return g(d);
}
""", 100, "bits", "形参面·分支判别形（修前 ELF 101 / interp 172 = 分歧；100 = 100+0）"),
    ("field_lit_bits", """
struct S { f: dex? }
fn main() -> int {
    d : dex, apx = 7.0;
    s : ., mut = S { f = d };
    return match s.f { Some(v) => { return @raw_int(v) / 1000000; } None => { return 0; } };
}
""", 7, "bits", "结构体字面量字段（装箱序倒置面；修前 15）"),
    ("global_bits", """
g : dex?, mut = None;
fn main() -> int {
    d : dex, apx = 7.0;
    g = d;
    return match g { Some(v) => { return @raw_int(v) / 1000000; } None => { return 0; } };
}
""", 7, "bits", "全局槽（必须 `mut`，见头注 ①；修前 15）"),
    ("enum_payload_opt_bits", """
enum E { V(dex?) }
fn main() -> int {
    d : dex, apx = 7.0;
    e := V(d);
    return match e { V(x) => { return match x { Some(v) => { return @raw_int(v) / 1000000; } None => { return 0; } }; } };
}
""", 7, "bits", "用户枚举的可选 dex 载荷（修前 15）"),
    # ── 已覆盖面/钉子（改法不得改坏）──
    ("field_assign_bits", """
struct S { f: dex? }
fn main() -> int {
    d : dex, apx = 7.0;
    s : ., mut = S { f = None };
    s.f = d;
    return match s.f { Some(v) => { return @raw_int(v) / 1000000; } None => { return 0; } };
}
""", 7, "bits", "字段**赋值**面（`:1498` norm→box 的正确序 ⇒ 修前已绿；钉子）"),
    ("try_unpack_bits", """
fn main() -> int {
    d : dex, apx = 7.0;
    x : dex? = d;
    y := x?;
    return @raw_int(y) / 1000000;
}
""", 7, "bits", "`?` 解包（修前已绿：槽型=bits 自洽；钉住槽型声明化后仍绿）"),
    ("try_to_dex_bits", """
fn main() -> int {
    d : dex, apx = 7.0;
    x : dex? = d;
    y := x?;
    z : dex = y;
    return @raw_int(z) / 1000000;
}
""", 7, "bits", "`?` 解包再入 `dex` 槽（修前已绿；钉子）"),
    ("dexopt_apx_tag", """
fn main() -> int {
    x : dex?, apx = 7.0;
    return match x { Some(v) => { return @raw_int(v) / 1000000; } None => { return 0; } };
}
""", 7, "scaled", "`dex?, apx`：标签**被静默忽略** ⇒ 落精确世界（`TODO #2026-09-17-4` 登记面；钉子）"),
    ("param_scaled", """
fn g(x: dex?) -> int {
    return match x { Some(v) => { return @raw_int(v) / 1000000; } None => { return 0; } };
}
fn main() -> int {
    e : dex = 7.0;
    return g(e);
}
""", 7, "scaled", "形参面·对照（scaled 实参；修前已绿——分歧是 bits 实参特有）"),
    ("param_branch_scaled", """
fn g(x: dex?) -> int {
    match x {
        Some(v) => { return 100 + (@raw_int(v) % 100); }
        None => { return 200; }
    }
    return 55;
}
fn main() -> int {
    e : dex = 7.0;
    return g(e);
}
""", 100, "scaled", "形参面·判别形对照（scaled 实参；修前已绿）"),
    ("ret_scaled", """
fn f() -> dex? {
    e : dex = 7.0;
    return e;
}
fn main() -> int {
    x := f();
    return match x { Some(v) => { return @raw_int(v) / 1000000; } None => { return 0; } };
}
""", 7, "scaled", "返回面·对照（scaled；修前已绿）"),
    ("param_some_bits", """
fn g(x: dex?) -> int {
    return match x { Some(v) => { return @raw_int(v) / 1000000; } None => { return 0; } };
}
fn main() -> int {
    d : dex, apx = 7.0;
    return g(Some(d));
}
""", 7, "bits", "形参面 ← `Some(apx)`（修前 ELF 已绿：枚举构造点漏斗覆盖；钉子）"),
    ("nonopt_direct_bits", """
fn g(x: dex) -> int { return @raw_int(x) / 1000000; }
fn main() -> int { d : dex, apx = 7.0; return g(d); }
""", 7, "bits", "非可选 dex 直调（apx 批已覆盖面；非回归钉）"),
    # ── 非 dex 对照（零足迹面：不得被本批改动）──
    ("int_opt_lit", """
fn g(x: int?) -> int {
    return match x { Some(v) => { return v; } None => { return 0; } };
}
fn main() -> int { return g(7); }
""", 7, "int", "`int?` 字面量（对照：非 dex 面不受影响）"),
    ("int_opt_var", """
fn g(x: int?) -> int {
    return match x { Some(v) => { return v; } None => { return 0; } };
}
fn main() -> int { n := 7; return g(n); }
""", 7, "int", "`int?` 变量实参（对照）"),
    ("int_opt_some", """
fn g(x: int?) -> int {
    return match x { Some(v) => { return v; } None => { return 0; } };
}
fn main() -> int { return g(Some(7)); }
""", 7, "int", "`int?` ← `Some(7)`（对照）"),
    ("int_opt_none", """
fn g(x: int?) -> int {
    return match x { Some(v) => { return v; } None => { return 0; } };
}
fn main() -> int { return g(None); }
""", 0, "int", "`int?` ← `None`（对照；0 = None 分支）"),
]

# 四态四条统一进 CASES 列表（kind 由 FOUR_STATE 给出；期望 = ANCHOR）
for _n, (_k, _setup) in FOUR_STATE.items():
    CASES.insert(0, (_n, _four_state_src(_setup), ANCHOR, _k, f"四态对拍：{_n}"))

# 编译期拒绝面（响亮，非静默）：`[dex?; N]` 字面量元素类型推断未接可选面
REJECT_SRC = """
fn main() -> int {
    d : dex, apx = 7.0;
    a : [dex?; 2] = [d, None];
    return match a[0] { Some(v) => { return @raw_int(v) / 1000000; } None => { return 0; } };
}
"""


def test_four_state_parity():
    """① 主判据：四态 ELF 互等 **且** 锚定格 == 语义值；② 每格按 kind 过 interp 纪律。"""
    fails = []
    got = {}
    for name in FOUR_STATE:
        kind, _setup = FOUR_STATE[name]
        src = _four_state_src(_setup)
        chk, bld, elf = build_and_run(src, name)
        if chk != 0 or bld != 0 or elf is None:
            fails.append(f"{name}: check={chk} build={bld} elf={elf}")
            got[name] = None
            continue
        got[name] = elf
    vals = [v for v in got.values() if v is not None]
    if len(vals) == 4:
        if len(set(vals)) != 1:
            fails.append(f"四态**互等**失败：{got}")
        elif got["fs_bare_scaled"] != ANCHOR or got["fs_boxed_scaled"] != ANCHOR:
            fails.append(f"锚定格 != {ANCHOR}：{got}（锚定格必须钉住语义值，否则四格一起错也算互等）")
        else:
            print(f"[PASS] 四态对拍：{got} —— 四格互等 = {ANCHOR}（含锚定格）")
    # interp 纪律（逐格；与 ELF 同判，禁「单腿绿结案」）
    for name in FOUR_STATE:
        kind, _setup = FOUR_STATE[name]
        src = _four_state_src(_setup)
        rc = run_interp(src)
        want_set = {255} if kind == "bits" else {ANCHOR}
        if rc not in want_set:
            fails.append(f"{name}: interp={rc} 期望 ∈ {sorted(want_set)}（第三态 = 静默）")
        else:
            print(f"[PASS] {name}: interp={rc}（kind={kind}）")
    return fails


def test_cases():
    """家族面逐例：check/build 严格 + ELF == 期望 + interp 按 kind 的纪律（禁第三态）。"""
    fails = []
    for name, src, want, kind, note in CASES:
        chk, bld, elf = build_and_run(src, name)
        if chk != 0:
            fails.append(f"{name}: check rc={chk}（期望 0；任何诊断码 = 失败——{note}）")
            print(f"[FAIL] {name}: check rc={chk} — {note}")
            continue
        if bld != 0:
            fails.append(f"{name}: build rc={bld} — {note}")
            print(f"[FAIL] {name}: build rc={bld} — {note}")
            continue
        rc = run_interp(src)
        want_set = {255} if kind == "bits" else {want}
        if elf != want:
            fails.append(f"{name}: ELF rc={elf} 期望 {want} — {note}")
            print(f"[FAIL] {name}: ELF rc={elf} 期望 {want}（interp={rc}）— {note}")
        elif rc not in want_set:
            fails.append(f"{name}: interp rc={rc} 期望 ∈ {sorted(want_set)}（第三态 = 静默；ELF 已绿也算红）— {note}")
            print(f"[FAIL] {name}: interp rc={rc} 期望 ∈ {sorted(want_set)}（禁第三态）— {note}")
        else:
            print(f"[PASS] {name}: ELF={elf} interp={rc}（kind={kind}）— {note}")
    return fails


def test_apx_slot_witness():
    """「探针不触发」守卫（照 apx 套件 `test_decl_form_selfcheck` 体例）：
    kind=="bits" 的探针源**必须**真的建立 apx 槽——判据 = `.cir` 出现 binary64 位模式常量
    （`const dex = <大整数>`）；scaled 源**不得**出现（否则分类错了 ⇒ 判据面被污染）。"""
    bad = 0
    for name, src, _want, kind, _note in CASES:
        if kind == "int":
            continue
        r = run_corec(["cir"], src)
        vals = [int(m) for m in re.findall(r"const\s+dex\s*=\s*(\d+)", r.stdout + r.stderr)]
        mx = max(vals) if vals else -1
        if kind == "bits" and mx < BITS_CONST_MIN:
            print(f"[FAIL] {name}: bits 源未建立 apx 槽（.cir 最大 dex 常量 = {mx}）⇒ 假绿面")
            bad += 1
        if kind == "scaled" and mx >= BITS_CONST_MIN:
            print(f"[FAIL] {name}: scaled 源竟含 bits 常量（{mx}）⇒ 分类/前提变了，须重审")
            bad += 1
    if bad == 0:
        print("[PASS] apx 槽自证：bits 源全部建立 bits 常量 · scaled 源全部无 bits 常量")
    return bad


def test_array_opt_rejected():
    """编译期拒绝面（响亮、零产物）：`[dex?; 2] = [d, None]` ⇒ TK02 + TA02，check/build 双 rc=1。"""
    src = f"// opt-dex-{uuid.uuid4()}\n" + REJECT_SRC
    with tempfile.NamedTemporaryFile("w", suffix=".cr", delete=False) as f:
        f.write(src)
        path = f.name
    out = str(BASE / "build" / f"_optdex_reject_{uuid.uuid4().hex[:8]}")
    try:
        chk = subprocess.run([str(COREC), "check", path], cwd=BASE,
                             capture_output=True, text=True, timeout=180)
        codes = set(re.findall(r"error\[([A-Z0-9]+)\]", chk.stdout + chk.stderr))
        bld = subprocess.run([str(COREC), "build", path, "-o", out, "--static"],
                             cwd=BASE, capture_output=True, text=True, timeout=180)
        if chk.returncode != 1:
            print(f"[FAIL] 数组可选面：check rc={chk.returncode}（期望 1）")
            return 1
        if not {"TK02", "TA02"}.issubset(codes):
            print(f"[FAIL] 数组可选面：诊断码 {sorted(codes)} 缺 TK02/TA02")
            return 1
        if bld.returncode != 1:
            print(f"[FAIL] 数组可选面：build rc={bld.returncode}（期望 1；拒绝面不得出产物）")
            return 1
        if os.path.exists(out):
            print("[FAIL] 数组可选面：拒绝面竟产出文件")
            return 1
        print(f"[PASS] 数组可选面：check/build 双 rc=1 + {sorted(codes)} + 零产物（响亮拒绝；TODO #2026-09-16-29 §9 U6 登记面）")
        return 0
    finally:
        os.unlink(path)
        if os.path.exists(out):
            os.unlink(out)


def main():
    fails = []
    fails += test_four_state_parity()
    fails += test_cases()
    if test_apx_slot_witness() != 0:
        fails.append("apx_slot_witness")
    if test_array_opt_rejected() != 0:
        fails.append("array_opt_rejected")
    print()
    if fails:
        print(f"[FAIL] {len(fails)} 项：")
        for f in fails:
            print("   ", f)
        sys.exit(1)
    print(f"[PASS] 可选 dex 族套件全绿（四态对拍 + {len(CASES)} 例 + 槽自证 + 拒绝面）")


if __name__ == "__main__":
    main()
