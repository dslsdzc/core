#!/usr/bin/env python3
"""`(i)` 小批：`@raw_int` 放宽接受**指针**——判据（两向钉子 + 值面 + 既有形态不动）。

**改动**（`src/compiler/checker.cr` 的 `@raw_int` 守卫，符号锚 = `str_eq(name, "raw_int")`）：
白名单由「dex / int」扩到「dex / int / **地址型**」，加入标准 = **该类型的原值有语义**
（dex 缩放位 · int 原值 · 地址字）。

**【原文保留 · 已被裁定二取代（2026-09-20，S2）】** 原写：
「白名单由「dex / int」扩到「dex / int / **指针**」，加入标准 = 该类型的原值有语义
（dex 缩放位 · int 原值 · 指针地址字）。`TYP_REF` / `TYP_SLICE` / `TYP_ARRAY` 等**仍拒绝**——
聚合无「原值」概念、`TYP_REF` 语义未实测 ⇒ **没证据就不扩**（与「range 门零命中就不写退出条款」同一条纪律）。」
⇒ **该前提已死**：裁定二把 `&x` 改判 `TYP_REF` ⇒ 「只认指针」这条线站不住（实测：`ptr_ref_first.cr`
由 rc=0 转 rc=1，**TF07×2 + TB01 级联**）⇒ 门重写为「**只认地址型 = `TYP_PTR` ∪ `TYP_REF`**」。
⇒ 本档随之重定：**改前提、不删断言**（旧期望文本逐处保留在注释里）。
⇒ **本门还会第三次改写**：`(i)` 的最终语义已列为与「拆 `string`」批的联合决策。

**类型定名（实测定名，非假设）**：只加 `TYP_PTR` 后正控即绿 ⇒ `&x` 表达式解析到的就是 `TYP_PTR` 行；
补充证据（突变 M2）= 把放宽面扩到 `TYP_REF` 时，`ref_type` 负控（形参 `&int`）**恰好翻红** ⇒
该负控确实钉的是 `TYP_REF`，不是别的东西。

**改动前读数（批基点 `802bd24a` 实测，本档 A 腿即其反向钉子）**：
`tests/suite/ptr_ref_first.cr` check = **rc=1 · TF07×2 · TB01×1**（TF07 级联出 TB01）；
产物 ELF `fdf8cad6…`(28854B) · `.ccr` `3e27595e…`(95571B)。
**改动后**：check = **rc=0 · 零诊断**；产物**逐字节不变**（本档 C 腿在跑时复核一次：重新构建后与锁定值比——
注意产物锁定值的真源是 `tools/baseline/canary_values.tsv`（ELF canary + `.ccr` 四条），本档只做「同源两次构建一致」的确定性钉子）。

**负控的面（教训，2026-09-18 team-lead 纠）**：TF07 是 **build-scope 豁免码**（`diag.cr::diag_gate_exempt`）
⇒ 「build 面零产物」在本批**恒假**（豁免未撤，撤条归 `(甲)` 刀 4）⇒ **负控只写 `check` 面**：
`rc=1` + 恰 1 条 `error[TF07]` + 文案含 **`or address`**（2026-09-20 S2 重定；**旧期望 = 文案含 `or pointer`**，随门文案重写而失效）。
build 面本批仍 rc=0 + 照出产物，**不得当负控**。

**安全面边界（明写；team-lead 2026-09-19 裁）**：`@raw_int` **现状不要求 `unsafe`**——它本就接受
`TI_DEX`（取缩放位原值），**指针只是同一「取原值」类别里的又一个类型** ⇒ **本批不引入新类别**，
也不改变该内建的安全面（本档 B 腿的 `ref_type`/`struct`/…… 负控与安全面无关，钉的是**类型白名单**）。
**「`@raw_int` 是否应要求 `unsafe`」（与 2(a) 视图内建的安全面 (ii) 对齐）是预存的更大问题**，
**不在本小批解决**；若将来裁定要求，该条改动会同时影响 `dex`/`int` 既有形态 ⇒ 属改契约批，须单独立项。

**文案单点**：该码的文案全仓**仅 1 处**（`checker.cr` 的 `@raw_int` 守卫；bootstrap 侧不认识 `raw_int`，
fail-closed、无第二份文案）——本档 B 腿断言文案含 **`or address`**（**S2 重定后**；旧为 `or pointer`），即钉住这个单点。
"""

import os
import subprocess
import sys
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"

POS = BASE / "tests" / "suite" / "ptr_ref_first.cr"

# 负控（check 面 rc=1 + TF07）。
# ⚠ **2026-09-20（S2）重定**：原 `ref_type` 条目**已移出负控**——它的形态是**形参类型位 `&int`**
#   （`EXPR_REFTYPE` ⇒ `TYP_REF`），而 S2 的目标**正是让 `TYP_REF` 被接受**（实测：该源 `check` = **rc=0**）
#   ⇒ 它的前提被**直接推翻**。按「改前提、不删断言」：**同形源码改判为正钉**（见下 `REF_OK`），
#   **并补一个真该被拒的形态填空**（`optional` = `int?`，实测 `rc=1 TF07×1` ✓；`tuple` 亦实测被拒，取一即可）。
NEG = {
    "string": 'fn main() -> int { s := "hi"; return @raw_int(s); }\n',
    "bool": "fn main() -> int { b := true; return @raw_int(b); }\n",
    "array": "fn main() -> int { a := [1,2,3]; return @raw_int(a); }\n",
    "slice": "fn main() -> int { a := [1,2,3]; s := a[0..2]; return @raw_int(s); }\n",
    "optional": "fn main() -> int { x : int? = None; return @raw_int(x); }\n",
    "struct": "struct S { v: int }\n"
              "fn main() -> int { s : ., mut = S { v = 1 }; return @raw_int(s); }\n",
}
# **正钉（S2 新增）**：原 `ref_type` 负控的**同形源码**改判——`TYP_REF` **必须被接受**。
REF_OK = {
    "ref_type": "fn f(r: &int) -> int { return @raw_int(r); }\n"
                "fn main() -> int { x : ., mut = 1; return f(&x); }\n",
}
# 既有被接受形态（放宽不得把它们弄坏；两向钉子）
POS_FORMS = {
    "dex": "fn main() -> int { d : dex, mut = 1.5; return @raw_int(d); }\n",
    "int": "fn main() -> int { n : ., mut = 7; return @raw_int(n); }\n",
}


def _clean():
    subprocess.run([str(COREC), "clean-cache"], cwd=BASE, capture_output=True, timeout=120)


def _check_src(src: str):
    with tempfile.NamedTemporaryFile("w", suffix=".cr", delete=False) as f:
        f.write(src)
        path = f.name
    try:
        _clean()
        r = subprocess.run([str(COREC), "check", path], cwd=BASE, capture_output=True,
                           text=True, timeout=300)
        diags = [l for l in r.stdout.split("\n") if l.startswith("error[")]
        return r.returncode, diags
    finally:
        os.unlink(path)


def _check_file(path: Path):
    _clean()
    r = subprocess.run([str(COREC), "check", str(path)], cwd=BASE, capture_output=True,
                       text=True, timeout=300)
    diags = [l for l in r.stdout.split("\n") if l.startswith("error[")]
    return r.returncode, diags


def _run(src: str):
    """自托管面 · 解释器腿（`run` 收**内联源码**，传路径会 parse 失败）。"""
    _clean()
    r = subprocess.run([str(COREC), "run", src], cwd=BASE, capture_output=True, text=True, timeout=300)
    return r.returncode


def _build_run(path: Path):
    out = Path(tempfile.mkdtemp()) / "probe"
    _clean()
    rb = subprocess.run([str(COREC), "build", str(path), "-o", str(out), "--static"],
                        cwd=BASE, capture_output=True, text=True, timeout=600)
    if rb.returncode != 0:
        return rb.returncode, None
    rp = subprocess.run([str(out)], capture_output=True, text=True, timeout=60)
    return rp.returncode, out


def main():
    ok = True
    fails = []

    def expect(name, cond, detail=""):
        nonlocal ok
        print(("  PASS  " if cond else "  FAIL  ") + name + ("" if cond else f"  ← {detail}"))
        if not cond:
            ok = False
            fails.append(name)

    # ── A 正控：诊断面 + 值面（两腿） ──
    rc_c, diags = _check_file(POS)
    print(f"[A 正控] ptr_ref_first check rc={rc_c} 诊断={diags}")
    expect("pos_check_clean", rc_c == 0 and not diags, f"rc={rc_c} {diags}")
    rc_native, _ = _build_run(POS)
    rc_interp = _run(POS.read_text(encoding="utf-8"))
    print(f"[A 正控·值面] native rc={rc_native} · 解释器 rc={rc_interp}（期望皆 0）")
    expect("pos_value_native", rc_native == 0, rc_native)
    expect("pos_value_interp", rc_interp == 0, rc_interp)

    # ── B 负控（check 面；build 面因豁免未撤不得当负控） ──
    # ⚠ **文案断言随 S2 重定（改前提、不删断言）**：
    #   旧期望 = `"or pointer" in tf07[0]`（旧文案 `…or pointer expression`）；
    #   S2 把门重写为「只认地址型」⇒ 新文案 = `…or address (pointer/reference) expression`
    #   ⇒ 断言改钉**新文案的单点串** `"or address"`（该码全仓仍仅 1 处，单点性质不变）。
    for name, src in NEG.items():
        rc, d = _check_src(src)
        tf07 = [x for x in d if x.startswith("error[TF07]")]
        print(f"[B 负控·{name}] rc={rc} TF07×{len(tf07)}")
        expect(f"neg_{name}_rejected", rc == 1 and len(tf07) == 1 and len(d) == 1, f"rc={rc} {d}")
        expect(f"neg_{name}_message", bool(tf07) and "or address" in tf07[0], tf07)

    # ── B'' 正钉（S2 新增）：原 `ref_type` 负控**同形源码改判**——`TYP_REF` 必须被接受 ──
    for name, src in REF_OK.items():
        rc, d = _check_src(src)
        print(f"[B'' 地址型接受·{name}] rc={rc} 诊断×{len(d)}")
        expect(f"ok_{name}_accepted", rc == 0 and not d, f"rc={rc} {d}")

    # ── B' 既有形态仍被接受（放宽的两向钉子之一：不得误伤） ──
    for name, src in POS_FORMS.items():
        rc, d = _check_src(src)
        print(f"[B' 既有形态·{name}] rc={rc} 诊断×{len(d)}")
        expect(f"kept_{name}_accepted", rc == 0 and not d, f"rc={rc} {d}")

    # ── C 确定性钉子：同源两次构建产物一致（产物锁定值的真源是 canary 表，本档只钉确定性） ──
    _, o1 = _build_run(POS)
    _, o2 = _build_run(POS)
    import hashlib
    h1 = hashlib.sha256(o1.read_bytes()).hexdigest() if o1 else "n/a"
    h2 = hashlib.sha256(o2.read_bytes()).hexdigest() if o2 else "n/a"
    print(f"[C 确定性] 两次构建 ELF sha={h1[:16]}… / {h2[:16]}…")
    expect("artifact_deterministic", o1 and o2 and h1 == h2, f"{h1} != {h2}")

    print(("RAW_INT PTR " + ("PASS" if ok else "FAIL")) + f" · 失败项 = {fails}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
