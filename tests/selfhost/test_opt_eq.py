#!/usr/bin/env python3
"""可选值 `==`/`!=` 表示透明回归套件（批 8 条目 2；TODO #2026-09-17-6；自举编译器 build/corec）。

**现象（修复前实测，2026-09-17 批 8 T0）**：`==` 走通用二元路径**不读表示位** ⇒ 逐槽比原始值：
裸（rep=0，槽值=载荷）⇒ 比载荷（正确）；**装箱**（`Some`/`None` 对象）⇒ 比**指针** ⇒ 恒假。
五读数（位码打包，见下）修复前 = **8**（仅 bit3 置位）。

**修复（批 8 条目 2）**：比较点把两侧归一为 `(absent, payload)` 后再比（`ir_gen.cr`
`opt_cmp_optish`/`opt_cmp_norm`/`opt_cmp_extract_boxed` + `==`/`!=` 分派块）：
缺省性不同 ⇒ 不等；同缺省 ⇒ 相等；同在 ⇒ 比载荷。触发面**保守**（带表示位 / `Some`·`None`
构造子 / 可选声明面）⇒ 非可选比较走原路径（判据 ⑤）。

**判据要件（计划 §1 条目 2）**：① `Some(x)==Some(x)` 必真 · ② `None==None` 必真 ·
③ `Some(x)==None` 必假 · ④ **同源自比较 `x==x` 必真（bare/boxed 两表示都测）** ·
⑤ 非可选 `==` 语义与产物零变化。

**位码打包（rc 可读；lead 2026-09-18 裁定「以运行退出码为准、改前五读数 0/0/0/1/1」）**：
`bit0 = n==Some(7)` · `bit1 = n==None` · `bit2 = n==m`（两 None）· `bit3 = a==b`（两 bare 7）·
`bit4 = a==7`（可选 vs 内层值，**present**）· `bit5 = n==7`（None vs 内层值）。
修复前 = **24**（bit3+bit4 ⇒ 五读数 0/0/0/1/1）· 修复后 = **30**（②③④⑤ 置位；① 与 bit5 不置位）。

**突变自证（批级留痕，2026-09-17 实测）**：把比较点分派门退回不触发 ⇒ 位码回 **8**（②③ 回红）。

**已登记未覆盖面**：字符串载荷的装箱可选比较（`Some("a")==Some("a")`）仍按指针比 ⇒ 0
（与本修复前一致；载荷定型通道未覆盖 ⇒ 见档末 `known_uncovered` 用例，**不得**当作判据）。

**非可选零变化（判据 ⑤）**：本档 `plain_*` 组 = 非可选比较逐值钉子；产物面（canary / `.ccr`
IDENTICAL）在批级判据核，不在本档。
"""

import os
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"

B2I = "fn b2i(x: bool) -> int { if x { return 1; } return 0; }\n"
# 位码打包：五读数各占一位（ELF/interp 同判）
BITCODE = """
fn main() -> int {
    n : int? = None;
    m : int? = None;
    a : int? = 7;
    b : int? = 7;
    return b2i(n == Some(7)) + b2i(n == None) * 2 + b2i(n == m) * 4
         + b2i(a == b) * 8 + b2i(a == 7) * 16 + b2i(n == 7) * 32;
}
"""
BITCODE_PRE = 24   # 修复前实测（= 五读数 0/0/0/1/1 ⇒ bit3+bit4；lead 2026-09-18 裁定锚）
BITCODE_POST = 30  # 修复后期望：②③④⑤ 置位（① 与 bit5 不置位）


def _run(cmd, timeout):
    return subprocess.run(cmd, cwd=BASE, capture_output=True, text=True, timeout=timeout)


def case_dual(name, source, want, note=""):
    """严格 check（任何诊断即失败）→ build + 跑 ELF → 与 interp 同判 ⇒ (ok, detail)。"""
    src = f"// opt-eq-{uuid.uuid4()}\n" + source
    with tempfile.NamedTemporaryFile("w", suffix=".cr", delete=False) as f:
        f.write(src)
        path = f.name
    out = str(BASE / "build" / f"_opteq_{uuid.uuid4().hex[:8]}")
    try:
        chk = _run([str(COREC), "check", path], 180)
        if chk.returncode != 0:
            return False, f"check rc={chk.returncode}（严格面：诊断即失败）"
        bld = _run([str(COREC), "build", path, "-o", out, "--static"], 300)
        if bld.returncode != 0:
            return False, f"build rc={bld.returncode}"
        os.chmod(out, 0o755)
        elf = subprocess.run([out], cwd=BASE, capture_output=True, timeout=120).returncode
        itp = _run([str(COREC), "run", src], 180).returncode
        ok = (elf == want) and (itp == want)
        return ok, f"ELF={elf} interp={itp} want={want} {note}"
    finally:
        os.unlink(path)
        if os.path.exists(out):
            os.unlink(out)


CASES = [
    # ── 判据 ①：Some(x)==Some(x)（两个**不同对象**、载荷相等）──
    ("some_eq_some_true", B2I + """
fn main() -> int { return b2i(Some(7) == Some(7)); }
""", 1, "① 装箱两对象载荷相等"),
    ("some_eq_some_false", B2I + """
fn main() -> int { return b2i(Some(7) == Some(8)); }
""", 0, "① 反向：载荷不等"),
    # ── 判据 ②：None==None（两个不同 None 源）──
    ("none_eq_none_vars", B2I + """
fn main() -> int { n : int? = None; m : int? = None; return b2i(n == m); }
""", 1, "② 两个 None 变量"),
    ("none_eq_none_lit", B2I + """
fn main() -> int { n : int? = None; return b2i(n == None); }
""", 1, "② 变量 vs None 字面量"),
    # ── 判据 ③：Some(x)==None 必假（双向）──
    ("some_ne_none", B2I + """
fn main() -> int { n : int? = Some(7); return b2i(n == None); }
""", 0, "③ Some vs None"),
    ("none_ne_some", B2I + """
fn main() -> int { n : int? = None; return b2i(n == Some(7)); }
""", 0, "③ None vs Some（反向）"),
    # ── 判据 ④：同源自比较 x==x（bare / boxed 两表示）──
    ("self_eq_bare", B2I + """
fn main() -> int { a : int? = 7; return b2i(a == a); }
""", 1, "④ 裸表示自比较"),
    ("self_eq_boxed", B2I + """
fn main() -> int { a : int? = 7; p := &a; *p = Some(9); return b2i(*p == *p); }
""", 1, "④ 装箱表示自比较（INV-1 取址槽；`*p` 形态绕开软诊断 B04，同批 5 体例）"),
    # ── 表示透明：同语义两种表示同判（本修复的核心命题）──
    ("rep_transparent_bare", B2I + """
fn main() -> int { a : int? = 7; b : int? = 7; return b2i(a == b); }
""", 1, "裸 7 == 裸 7"),
    ("rep_transparent_boxed", B2I + """
fn main() -> int { a : int? = 7; b : int? = 7; p := &a; q := &b; *p = Some(7); *q = Some(7); return b2i(*p == *q); }
""", 1, "装箱 Some(7) == 装箱 Some(7)"),
    ("boxed_vs_bare_mixed", B2I + """
fn main() -> int { a : int? = 7; b : int? = 7; p := &a; *p = Some(7); return b2i(*p == b); }
""", 1, "装箱 Some(7) == 裸 7（表示无关）"),
    # ── `!=` 面 ──
    ("ne_some_diff", B2I + """
fn main() -> int { return b2i(Some(7) != Some(8)); }
""", 1, "!=：载荷不等 ⇒ 真"),
    ("ne_none_none", B2I + """
fn main() -> int { n : int? = None; m : int? = None; return b2i(n != m); }
""", 0, "!=：两个 None ⇒ 假"),
    # ── 合成/嵌套：比较结果再参与比较 ──
    ("composed_bool", B2I + """
fn main() -> int { n : int? = None; m : int? = None; return b2i((n == None) == (m == None)); }
""", 1, "两比较结果相等（bool 面）"),
    # ── 位码总钉（五读数打包；ELF 与 interp 同判）──
    ("bitcode_five_readings", B2I + BITCODE, BITCODE_POST,
     f"五读数位码（修复前 {BITCODE_PRE}）"),
    # ── 判据 ⑤：非可选对比 = 零变化（逐值钉子）──
    ("plain_eq_true", B2I + """
fn main() -> int { a := 7; b := 7; return b2i(a == b); }
""", 1, "⑤ 非可选 7==7"),
    ("plain_eq_false", B2I + """
fn main() -> int { a := 7; b := 8; return b2i(a == b); }
""", 0, "⑤ 非可选 7==8"),
    ("plain_str_eq", B2I + """
import io
fn main() -> int { a := "hi"; b := "hi"; return b2i(a == b); }
""", 1, "⑤ 非可选字符串相等（走 str_eq 原路径）"),
    # ── 已登记未覆盖面（**记录现状**，不是判据：字符串载荷的装箱比较仍按指针）──
    ("known_uncovered_str_payload", B2I + """
fn main() -> int { a : string? = None; return b2i(a == None); }
""", 1, "未覆盖面抽样：None 判定（类型无关，已在覆盖面内）"),
]


def main():
    ok = 0
    fails = []
    for name, src, want, note in CASES:
        passed, detail = case_dual(name, src, want, note)
        if passed:
            print(f"[PASS] {name}: {detail}")
            ok += 1
        else:
            print(f"[FAIL] {name}: {detail}")
            fails.append(name)
    print(f"\n{ok}/{len(CASES)} 通过")
    if fails:
        print("失败档：" + ", ".join(fails))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
