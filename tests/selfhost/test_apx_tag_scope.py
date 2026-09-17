#!/usr/bin/env python3
"""`apx` 标签**适用性白名单**（批 8 条目 5；TODO #2026-09-17-4；自举编译器 build/corec）。

**现象（修复前实测）**：`apx` 标签在**任意**声明上都被静默接受（`check=0`）——`dex?` · `.`（推断）·
`auto` · `string` · … 五形 `.cir` 均照发一条 `IR_APPROX`，但**只有显式 `dex` 有表示路径**
⇒ 其余三形「**只带标签、不给表示**」= 语义谎（用户要 apx 表示，实现无路可走）。

**裁定（lead 2026-09-18 = (B) 白名单）**：合法 = **显式 `dex`**（表示路径）+ **显式 `int`**
（既有契约的**纯注解**：`tests/selfhost/test_apx_tag.py` 钉「语法合法 + 语义不变 + `.cir` 携 `approx`」，
`tests/bootstrap/test_apx_tag.py` 同向 ApproxInstr ⇒ **两前端对齐**）；**其余一律硬错**（`error[P26]`，
`EC_P_APX_TAG = 1026`）。⛔ 裁 (A)（连 `int, apx` 一并拒）**已否**：那会**改契约**（须重定 test_apx_tag +
登记两前端接受集分歧），而 `int, apx` 不是静默面。判据原则 =「**有契约 ⇒ 有意设计；无契约 ⇒ 静默谎**」。

**判据要件**：① 非白名单形 ⇒ `check` rc=1 + `error[P26]` + 定位 + **`build` rc=1 且零产物**；
② 白名单两形（`dex, apx` / `int, apx`）**逐字节不变**（本档以 check+build+run + `.cir` `approx` 机制钉承担；
   批级另有「前态二进制 vs 本链」产物对拍）；
**突变自证（批级留痕）**：撤掉该检查 ⇒ 拒收组 4 例回 `check=0`。
"""

import os
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"

REJECTS = [
    ("optdex_apx", "x : dex?, apx = None;", "可选 dex（无表示路径）"),
    ("inferred_dot_apx", "x : ., apx = 1.0;", "推断形（`.`）——errata 记载：declared_ti 落 TI_UNIT，apx 槽压根不建立"),
    ("auto_apx", "x : auto, apx = 1.0;", "auto（推断）"),
    ("string_apx", 'x : string, apx = "s";', "string 声明"),
    ("bool_apx", "x : bool, apx = true;", "bool 声明"),
]

ACCEPTS = [
    ("dex_apx", "x : dex, apx = 7.0;", 0, "白名单：表示路径（合法形，逐字节不变面）"),
    ("int_apx", "x : int, apx = 42;", 0, "白名单：既有契约的纯注解（test_apx_tag 钉）"),
]


def run_case(name, decl, expect_reject):
    src = (f"// apxscope-{uuid.uuid4()}\n"
           f"fn main() -> int {{ {decl} return 0; }}\n")
    with tempfile.NamedTemporaryFile("w", suffix=".cr", delete=False) as f:
        f.write(src)
        path = f.name
    out = str(BASE / "build" / f"_apxscope_{uuid.uuid4().hex[:8]}")
    try:
        chk = subprocess.run([str(COREC), "check", path], cwd=BASE,
                             capture_output=True, text=True, timeout=180)
        if expect_reject:
            diag = "error[P26]" in chk.stdout
            loc = " --> 2:" in chk.stdout
            bld = subprocess.run([str(COREC), "build", path, "-o", out, "--static"],
                                 cwd=BASE, capture_output=True, text=True, timeout=300)
            art = os.path.exists(out) or os.path.exists(out + ".ccr")
            ok = chk.returncode == 1 and diag and loc and bld.returncode == 1 and not art
            return ok, f"check={chk.returncode} P26={diag} 定位={loc} build={bld.returncode} 产物={art}"
        bld = subprocess.run([str(COREC), "build", path, "-o", out, "--static"],
                             cwd=BASE, capture_output=True, text=True, timeout=300)
        if chk.returncode != 0 or bld.returncode != 0:
            return False, f"check={chk.returncode} build={bld.returncode}"
        rr = subprocess.run([out], cwd=BASE, capture_output=True, timeout=120).returncode
        # 机制钉：白名单形仍应携带 apx 标签（`.cir` 恰一条 `approx`）
        cir = subprocess.run([str(COREC), "cir", path], cwd=BASE,
                             capture_output=True, text=True, timeout=180)
        n_approx = sum(1 for l in cir.stdout.split("\n") if "approx" in l)
        ok = rr == 0 and n_approx == 1
        return ok, f"check=0 build=0 run={rr} approx={n_approx}"
    finally:
        os.unlink(path)
        for p in (out, out + ".ccr"):
            if os.path.exists(p):
                os.unlink(p)


def main():
    ok = 0
    fails = []
    for name, decl, note in REJECTS:
        passed, detail = run_case(name, decl, True)
        print(f"[{'PASS' if passed else 'FAIL'}] {name}: {detail}  # {note}")
        if passed:
            ok += 1
        else:
            fails.append(name)
    for name, decl, _want, note in ACCEPTS:
        passed, detail = run_case(name, decl, False)
        print(f"[{'PASS' if passed else 'FAIL'}] {name}: {detail}  # {note}")
        if passed:
            ok += 1
        else:
            fails.append(name)
    total = len(REJECTS) + len(ACCEPTS)
    print(f"\n{ok}/{total} 通过")
    if fails:
        print("失败档：" + ", ".join(fails))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
