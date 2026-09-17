#!/usr/bin/env python3
"""extern 声明含可选（`?`）的拒收面（批 8 条目 3；TODO #2026-09-17-7；自举编译器 build/corec）。

**现象（修复前实测，批 8 预备扫描）**：`extern fn e(x: dex?) -> int;` ⇒ `check` rc=0（零诊断）、
`build` rc=0、运行期垃圾值/139——两条早退路径（checker 对 EXPR_EXTERN 声明整段跳过 + ir_gen 的
`cfn_ext == 0` 守卫）都不报。

**修复（批 8 条目 3，`parser.cr` extern 分支）**：extern 声明的**形参/返回**类型节点若为
`EXPR_OPTIONAL` ⇒ `error[P24]`（`EC_P_EXTERN_OPTIONAL = 1024`）定位硬错 ⇒ check rc=1 + build 零产物。
（落点选 parser 的**签名规则**位：同 P020「形参数上限」先例；返回类型节点在 parser 内可用，
EXPR_EXTERN 节点本身不存返回节点。）

**判据要件（计划 §1 条目 3）**：① 含可选形参 ⇒ rc=1 + 专属诊断 + **零产物**；
② 非可选 extern **逐字节不变**（守卫档 = `tests/selfhost/test_iface_ops.py`（`-> char` / `-> never`）·
`tests/suite/ffi_test.cr` · `tests/probes/p_ffi2.cr`）；③ `dex?` 与 `int?` **同一拒收路径**。

**语料实核（批 8 预备扫描）**：全仓 12 处 `extern fn` 声明中**含 `?` 者 = 0** ⇒ 本硬错零语料代价。

**突变自证（批级留痕）**：撤掉 parser 的 `extern_opt` 检查 ⇒ ①/③ 两例回 `check=0` ⇒ 必红。
"""

import os
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"

# (name, extern 声明行, 是否应拒)
CASES = [
    ("reject_optdex_param", "extern fn e_opt(x: dex?) -> int;", True),
    ("reject_optint_param", "extern fn e_int(x: int?) -> int;", True),
    ("reject_optdex_ret", "extern fn e_ret() -> dex?;", True),
    ("reject_optint_ret", "extern fn e_iret() -> int?;", True),
    ("reject_mixed_params", "extern fn e_mix(a: int, b: dex?) -> int;", True),
    ("reject_optstr_param", "extern fn e_str(s: string?) -> int;", True),
    ("accept_plain_dex", "extern fn f_ok(x: dex) -> dex;", False),
    ("accept_plain_int", "extern fn putchar(c: int) -> int;", False),
    ("accept_plain_never", "extern fn f_nv() -> never;", False),
    ("accept_plain_char", "extern fn f_ch() -> char;", False),
]


def run_case(decl, should_reject):
    """check（rc + 诊断码 + 定位）→ build（rc + 产物）。返回 (ok, detail)。"""
    src = (f"// extopt-{uuid.uuid4()}\n{decl}\n"
           "fn main() -> int { return 0; }\n")
    with tempfile.NamedTemporaryFile("w", suffix=".cr", delete=False) as f:
        f.write(src)
        path = f.name
    out = str(BASE / "build" / f"_extopt_{uuid.uuid4().hex[:8]}")
    try:
        chk = subprocess.run([str(COREC), "check", path], cwd=BASE,
                             capture_output=True, text=True, timeout=180)
        diag = "error[P24]" in chk.stdout
        loc = " --> 2:" in chk.stdout      # 声明在第 2 行（首行 = 唯一注释，避开 .cir 缓存）
        bld = subprocess.run([str(COREC), "build", path, "-o", out, "--static"],
                             cwd=BASE, capture_output=True, text=True, timeout=300)
        has_art = os.path.exists(out)
        if should_reject:
            ok = (chk.returncode == 1 and diag and loc and bld.returncode == 1
                  and not has_art)
            return ok, (f"check={chk.returncode} P24={diag} 定位={loc} "
                        f"build={bld.returncode} 产物={has_art}")
        ok = (chk.returncode == 0 and bld.returncode == 0 and has_art)
        return ok, f"check={chk.returncode} build={bld.returncode} 产物={has_art}"
    finally:
        os.unlink(path)
        if os.path.exists(out):
            os.unlink(out)


def guard_corpora():
    """守卫档：非可选 extern 语料 check 面必须 rc=0（逐字节不变由批级判据承担）。"""
    guards = ["tests/suite/ffi_test.cr", "tests/probes/p_ffi2.cr"]
    outs = []
    for g in guards:
        p = BASE / g
        if not p.exists():
            outs.append((f"guard:{g}", False, "缺文件"))
            continue
        r = subprocess.run([str(COREC), "check", str(p)], cwd=BASE,
                           capture_output=True, text=True, timeout=180)
        outs.append((f"guard:{g}", r.returncode == 0, f"check rc={r.returncode}"))
    return outs


def main():
    ok = 0
    fails = []
    for name, decl, should_reject in CASES:
        passed, detail = run_case(decl, should_reject)
        print(f"[{'PASS' if passed else 'FAIL'}] {name}: {detail}")
        if passed:
            ok += 1
        else:
            fails.append(name)
    for name, passed, detail in guard_corpora():
        print(f"[{'PASS' if passed else 'FAIL'}] {name}: {detail}")
        if passed:
            ok += 1
        else:
            fails.append(name)
    total = len(CASES) + 2
    print(f"\n{ok}/{total} 通过")
    if fails:
        print("失败档：" + ", ".join(fails))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
