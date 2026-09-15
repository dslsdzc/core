#!/usr/bin/env python3
"""TC02 收口：`if` 分支相容判定的**发散豁免**（P3，不对称）。

背景（归因链 = `/tmp/fct1/tc02_attribution.md` / 设计 = `/tmp/fct2/tc02_minibatch.md`）：
`EXPR_RETURN` 的推断 = **所返回值类型**（checker.cr 的 EXPR_RETURN 分支），故 `{ return 1; }`
的块类型 = int；而 `if` 的值类型定义为 **then_ti**（infer_expr 的 EXPR_IF 合并点 `return then_ti`）。
⇒ 当 **else 支确定发散**（return 族收尾、不产出值）时，else 侧的「类型」是幻影 ⇒ 相容判定无对象。

判据（P3 = 不对称）：
  · else 支发散 ⇒ 不报（本批新增豁免；谓词 `stmt_diverges`，**只服务本判定点**）
  · **then 支发散 ⇒ 仍报 TC02**（then_ti 本身即幻影 = 模型面，保留真信号；见 tc02_then_return_kept）
  · 两侧皆不发散的真异型 ⇒ 仍报（tc02_true_mismatch_kept）
  · 既有 NEVER 豁免（loop{} 收尾）与 TF01/TA02 面**零扰动**（各配钉子）
  · TB01 真错（非级联）⇒ 仍报（负控；级联面见 TB01 归因报告 §2）

用例只增不减（本文件 15 例 = 设计稿 §3 全表）。
"""
import os
import subprocess
import sys
import tempfile
from pathlib import Path

BASE = Path(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
COREC = BASE / "build" / "corec"


def _no_core_dump():
    import resource
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def run_corec(args, timeout=120):
    return subprocess.run([str(COREC)] + args, cwd=BASE, capture_output=True,
                          text=True, timeout=timeout, preexec_fn=_no_core_dump)


def check_src(src: str):
    """返回 (rc, output)。"""
    with tempfile.NamedTemporaryFile("w", suffix=".cr", delete=False) as f:
        f.write(src)
        p = f.name
    try:
        r = run_corec(["check", p])
        return r.returncode, r.stdout + r.stderr
    finally:
        os.unlink(p)


# ── 正控：期望**无诊断**（rc=0） ──────────────────────────────────────
CASES_OK = [
    ("tc02_else_return_silenced",
     "fn main() -> int {\n    if 1 < 2 { } else { return 1; }\n    return 0;\n}\n"),
    ("tc02_else_return_after_stmt",
     "fn main() -> int {\n    if 1 < 2 { } else { x := 1; return x; }\n    return 0;\n}\n"),
    ("tc02_loop_control_unchanged",
     "fn main() -> int {\n    if 1 < 2 { } else { loop { } }\n    return 0;\n}\n"),
    ("tc02_bare_return_unchanged",
     "fn main() -> int {\n    if 1 < 2 { } else { return; }\n    return 0;\n}\n"),
    ("tf01_fallthrough_still_exempt",
     "fn f() -> int { loop { } }\nfn main() -> int { return f(); }\n"),
    ("tc02_stmt_position_multi",
     "fn main() -> int {\n" +
     "".join(f"    if 1.5 < 2.5 {{ }} else {{ return {i}; }}\n" for i in range(1, 7)) +
     "    return 0;\n}\n"),
]

# ── 负控/钉子：期望**仍报**（码 + rc=1） ─────────────────────────────
CASES_DIAG = [
    ("tc02_then_return_kept",
     "fn main() -> int {\n    if 1 < 2 { return 1; } else { }\n    return 0;\n}\n", ["TC02"]),
    ("tc02_true_mismatch_kept",
     "fn main() -> int {\n    if 1 < 2 { 1 } else { \"s\" }\n    return 0;\n}\n", ["TC02"]),
    ("tf01_still_reported",
     "fn f() -> int { return \"s\"; }\nfn main() -> int { return f(); }\n", ["TF01"]),
    ("ta02_still_reported",
     "fn main() -> int {\n    x : int = \"s\";\n    return 0;\n}\n", ["TA02"]),
    ("ta02_never_exempt_still",
     "fn main() -> int {\n    x : int = nosuchname;\n    return 0;\n}\n", ["N01"]),
    ("tb01_negative_ptr_add",
     "fn main() -> int {\n    x : ., mut = 1;\n    p := &x;\n    q := &x;\n    return p + q;\n}\n", ["TB01"]),
    ("tb01_negative_str_sub",
     "fn main() -> int {\n    return \"a\" - \"b\";\n}\n", ["TB01"]),
]

# ── 端到端：期望 build 成功 + 运行 rc=0（= test_native_float 两源同形） ──
CASES_RUN = [
    ("tc02_end2end_cmp",
     "fn main() -> int {\n"
     "    if 1.5 < 2.5 { } else { return 1; }\n"
     "    if 2.5 > 1.5 { } else { return 2; }\n"
     "    if 1.5 <= 1.5 { } else { return 3; }\n"
     "    return 0;\n}\n"),
    ("tc02_end2end_arith",
     "fn main() -> int {\n"
     "    x := 1.5;\n"
     "    y := 2.5;\n"
     "    if x + y == 4.0 { } else { return 1; }\n"
     "    if x * y == 3.75 { } else { return 2; }\n"
     "    return 0;\n}\n"),
]


def main() -> int:
    if not COREC.exists():
        print("build/corec is missing; run `python3 build_selfhost_native.py` first")
        return 1
    npass = nfail = 0

    for name, src in CASES_OK:
        rc, out = check_src(src)
        if rc == 0:
            print(f"[PASS] {name}: rc=0")
            npass += 1
        else:
            print(f"[FAIL] {name}: expected rc=0, got {rc}\n{out}")
            nfail += 1

    for name, src, codes in CASES_DIAG:
        rc, out = check_src(src)
        hit = [c for c in codes if f"error[{c}]" in out]
        if rc == 1 and len(hit) == len(codes):
            print(f"[PASS] {name}: rc=1 + {codes}")
            npass += 1
        else:
            print(f"[FAIL] {name}: expected rc=1 + {codes}, got rc={rc} hit={hit}\n{out}")
            nfail += 1

    for name, src in CASES_RUN:
        with tempfile.NamedTemporaryFile("w", suffix=".cr", delete=False) as f:
            f.write(src)
            p = f.name
        b = p[:-3]
        try:
            r = run_corec(["build", p, "-o", b, "--static"])
            if r.returncode != 0:
                print(f"[FAIL] {name}: build rc={r.returncode}\n{r.stdout}\n{r.stderr}")
                nfail += 1
                continue
            os.chmod(b, 0o755)
            rr = subprocess.run([b], capture_output=True, text=True,
                                preexec_fn=_no_core_dump, timeout=30)
            if rr.returncode == 0:
                print(f"[PASS] {name}: build+run rc=0")
                npass += 1
            else:
                print(f"[FAIL] {name}: run rc={rr.returncode}")
                nfail += 1
        finally:
            for art in (p, b, Path(str(b) + ".ccr")):
                try:
                    os.unlink(art)
                except FileNotFoundError:
                    pass

    print(f"{npass}/{npass + nfail} passed")
    return 0 if nfail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
