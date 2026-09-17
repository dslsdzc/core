#!/usr/bin/env python3
"""`@no_bounds_check` → `@NoBoundsCheck` 更名回归（维护者 2026-09-17 指示）。

语义决定 = **干净重命名，不留别名**：旧名从此**不是内建**——必须**响亮失败**
（rc=1 + 定位诊断 + 零产物），**不得静默**（本仓最忌讳「静默接受/静默误编译」）。

改动面（名分派四处）：
  * `src/compiler/checker.cr`   — EXPR_AT 名分派（`str_eq(name, "NoBoundsCheck")`）
  * `src/compiler/ir_gen.cr`    — 注解发射（同上）
  * `src/compiler/dataflow.cr`  — `.cir` 显示名（`return "NoBoundsCheck"`）
  * `src/lsp/analysis.cr`       — `@` 补全表（has_prefix + citem 两处）

**明确不动**（本套件以钉子固定）：IR 操作码常量 `IR_NO_BOUNDS_CHECK = 35`（内部标识，
非语言面名字，改名 = 无谓 churn）；`tests/suite/at_test.cr.bak`（游离备份文件，非编译单元，
删改需维护者许可）；`docs/superpowers/**` 与 `docs/pseudocode/**`（历史档案 / 生成物）。

判据（14 例）分四腿：
  A 旧名响亮失败（5）— build ×2 形态 + check 定位 ×2 + `run` 面
  B 新名等价正控（5）— 两形态编译运行 + `run` 面 + 两条入仓语料（at_test / at_test_mini7）
  C `.cir` 显示名（2）— 括号形态出现新名 / 语句形态零 IR（F4 既有语义，防改名顺带改语义）
  D 分派点与常量守门（2）— 四处同步（静态，防单点漏改/旧名复活）+ 操作码 35 不变

注：LSP 补全的**行为面**由 `tests/selfhost/test_lsp.py`（未挂 CI，手工判据）覆盖；
本套件 D 腿只做「补全表字符串已同步」的静态守门。
"""

import os
import resource
import subprocess
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"

OLD = "no_bounds_check"
NEW = "NoBoundsCheck"
NEEDLE_OLD = f"unknown @ builtin: {OLD}"
NEEDLE_NEW = f"unknown @ builtin: {NEW}"


def _no_core_dump():
    # core_pattern 为 systemd-coredump 管道时，崩溃的陷阱程序会挂起——禁用 core dump。
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def _write(source: str):
    fd, src = tempfile.mkstemp(suffix=".cr")
    with os.fdopen(fd, "w") as f:
        f.write(source)
    return src


def _cleanup(*paths):
    for p in paths:
        try:
            os.unlink(p)
        except FileNotFoundError:
            pass


def _run(args, timeout=180):
    return subprocess.run(
        [str(COREC)] + args, capture_output=True, text=True, cwd=BASE, timeout=timeout,
    )


def build_source(source: str):
    """临时源 → build；返回 (result, out_path, src_path)。"""
    src = _write(source)
    out = src[:-3]
    r = _run(["build", src, "-o", out, "--static"])
    return r, out, src


def check_source(source: str):
    src = _write(source)
    r = _run(["check", src])
    return r, src


def case_old_rejected(name, source):
    """旧名：build 必须 rc≠0 + 诊断 + **零产物**（.bin 与 .ccr 都不得落盘）。"""
    r, out, src = build_source(source)
    try:
        if r.returncode == 0:
            print(f"[FAIL] {name}: 旧名被静默接受（rc=0）——本仓最忌讳的形态")
            return False
        if NEEDLE_OLD not in (r.stdout + r.stderr):
            print(f"[FAIL] {name}: rc={r.returncode} 但缺诊断 {NEEDLE_OLD!r}: {r.stdout}{r.stderr}")
            return False
        if os.path.exists(out):
            print(f"[FAIL] {name}: 拒绝编译却仍产出二进制 {out}")
            return False
        if os.path.exists(out + ".ccr"):
            print(f"[FAIL] {name}: 拒绝编译却仍产出 .ccr {out}.ccr")
            return False
        print(f"[PASS] {name}: build rc={r.returncode} + 诊断 + 零产物")
        return True
    finally:
        _cleanup(src, out, out + ".ccr")


def case_old_check(name, source, lineno, colno):
    """旧名：check 面 rc≠0 + 诊断 + **文件:行:列定位**指向注解本身。"""
    r, src = check_source(source)
    log = r.stdout + r.stderr
    try:
        if r.returncode == 0:
            print(f"[FAIL] {name}: check 面旧名被静默接受（rc=0）")
            return False
        if NEEDLE_OLD not in log:
            print(f"[FAIL] {name}: rc={r.returncode} 但缺诊断 {NEEDLE_OLD!r}: {log}")
            return False
        loc = f" --> {lineno}:{colno}"
        if loc not in log:
            print(f"[FAIL] {name}: 诊断未定位到 {loc.strip()!r}: {log}")
            return False
        print(f"[PASS] {name}: check rc={r.returncode} + 定位 {lineno}:{colno}")
        return True
    finally:
        _cleanup(src)


def case_run_face(name, snippet, expect_rc, needle=None):
    """`run`（解释器面）同判：期望 rc + （可选）诊断文本。"""
    r = _run(["run", f"fn main() -> int {{ {snippet} return 7; }}"])
    log = r.stdout + r.stderr
    if r.returncode != expect_rc:
        print(f"[FAIL] {name}: expected rc {expect_rc}, got {r.returncode}: {log}")
        return False
    if needle is not None and needle not in log:
        print(f"[FAIL] {name}: rc={r.returncode} 但缺诊断 {needle!r}: {log}")
        return False
    print(f"[PASS] {name}: run rc={r.returncode}")
    return True


def case_new_ok(name, source, expect_rc=7):
    r, out, src = build_source(source)
    try:
        if r.returncode != 0:
            print(f"[FAIL] {name}: 新名编译失败 rc={r.returncode}: {r.stdout}{r.stderr}")
            return False
        os.chmod(out, 0o755)
        ran = subprocess.run([out], capture_output=True, text=True, timeout=10,
                             preexec_fn=_no_core_dump)
        if ran.returncode != expect_rc:
            print(f"[FAIL] {name}: 运行 rc={ran.returncode} != 期望 {expect_rc}")
            return False
        print(f"[PASS] {name}: build rc=0 + run rc={ran.returncode}")
        return True
    finally:
        _cleanup(src, out, out + ".ccr")


def case_corpus(name, relpath, expect_rc=0):
    out = tempfile.mktemp(suffix=".bin")
    r = _run(["build", relpath, "-o", out, "--static"])
    try:
        if r.returncode != 0:
            print(f"[FAIL] {name}: {relpath} 编译失败 rc={r.returncode}: {r.stdout}{r.stderr}")
            return False
        os.chmod(out, 0o755)
        ran = subprocess.run([out], capture_output=True, text=True, timeout=10,
                             preexec_fn=_no_core_dump)
        if ran.returncode != expect_rc:
            print(f"[FAIL] {name}: {relpath} 运行 rc={ran.returncode} != {expect_rc}: {ran.stdout}")
            return False
        print(f"[PASS] {name}: {relpath} build rc=0 + run rc={ran.returncode}")
        return True
    finally:
        _cleanup(out, out + ".ccr")


def _cir_dump(source: str):
    # `cir` 除 stdout 文本 dump 外**还落盘 DOT**：无 `-o` 时写到源文件旁的 `<stem>.cir`
    # （src/compiler/main.cr:588-593 实读）⇒ 显式给 `-o` 指向同目录临时名并随源一并清理，
    # 免在语料目录/临时目录留产物。
    src = _write(source)
    dot = src[:-3] + ".cir"
    try:
        d = _run(["cir", src, "-o", dot])
        return d.stdout + d.stderr, d.returncode
    finally:
        _cleanup(src, dot)


def main():
    stmt_old = "fn f() -> int {\n    @no_bounds_check;\n    return 7;\n}\nfn main() -> int { return f(); }\n"
    paren_old = "fn f() -> int {\n    @no_bounds_check();\n    return 7;\n}\nfn main() -> int { return f(); }\n"
    stmt_new = "fn f() -> int {\n    @NoBoundsCheck;\n    return 7;\n}\nfn main() -> int { return f(); }\n"
    paren_new = "fn f() -> int {\n    @NoBoundsCheck();\n    return 7;\n}\nfn main() -> int { return f(); }\n"

    ok = [
        # ── A. 旧名响亮失败 ──
        case_old_rejected("old_stmt_build_rejected", stmt_old),
        case_old_rejected("old_paren_build_rejected", paren_old),
        case_old_check("old_stmt_check_location", stmt_old, 2, 5),
        case_old_check("old_paren_check_location", paren_old, 2, 5),
        case_run_face("old_run_rejected", "@no_bounds_check();", 1, NEEDLE_OLD),
        # ── B. 新名等价（正控）──
        case_new_ok("new_stmt_ok", stmt_new),
        case_new_ok("new_paren_ok", paren_new),
        case_run_face("new_run_ok", "@NoBoundsCheck();", 7),
        case_corpus("corpus_at_test", "tests/suite/at_test.cr"),
        case_corpus("corpus_at_test_mini7", "tests/suite/at_test_mini7.cr"),
        # ── C. .cir 显示名（括号形态有行 / 语句形态零 IR = F4 既有语义）──
        cir_name_case(_cir_dump(paren_new), new_present=True),
        cir_name_case(_cir_dump(stmt_new), new_present=False),
        # ── D. 分派点与常量守门（静态）──
        dispatch_sites_case(),
        opcode_constant_case(),
    ]
    passed = sum(ok)
    print(f"{passed}/{len(ok)} passed")
    return 0 if passed == len(ok) else 1


def cir_name_case(dump, new_present):
    """`.cir` 显示名面：括号形态（唯一可达形态）出现 `NoBoundsCheck` 行；旧名文本零残留。

    语句形态（`@NoBoundsCheck;`）按 F4 既有语义**零 IR**（改名前实测同形）——本判据钉住
    「改名未顺带改形态语义」。
    """
    name = "cir_paren_display_name" if new_present else "cir_stmt_zero_ir"
    log, rc = dump
    if rc != 0:
        print(f"[FAIL] {name}: cir rc={rc}: {log}")
        return False
    if OLD in log:
        print(f"[FAIL] {name}: .cir 仍含旧显示名 {OLD!r}")
        return False
    if new_present:
        if not any(line.strip().startswith(NEW) and "dest=" in line for line in log.splitlines()):
            print(f"[FAIL] {name}: .cir 缺 {NEW} 注解行: {log}")
            return False
        print(f"[PASS] {name}: .cir 显示名 = {NEW}")
    else:
        if any(line.strip().startswith(NEW) for line in log.splitlines()):
            print(f"[FAIL] {name}: 语句形态本应零 IR（F4），却出现 {NEW} 行: {log}")
            return False
        print(f"[PASS] {name}: 语句形态零 IR（F4 语义保持）")
    return True


def _read(rel):
    return (BASE / rel).read_text(encoding="utf-8")


def dispatch_sites_case():
    """名分派四处同步：每处只认新名（旧名 literal 零残留）。

    静态守门——防「单点漏改」或「旧名以别名形式复活」（本批决定的语义 = 不留别名，
    故旧名 literal 在四处**任何一处**出现都判红）。
    """
    sites = {
        "src/compiler/checker.cr": ['str_eq(name, "%s")' % NEW],
        "src/compiler/ir_gen.cr": ['str_eq(name, "%s")' % NEW],
        "src/lsp/analysis.cr": ['analysis_has_prefix("%s", prefix)' % NEW,
                                'analysis_citem("%s", 3)' % NEW],
        "src/compiler/dataflow.cr": ['return "%s";' % NEW],
    }
    for rel, needles in sites.items():
        text = _read(rel)
        for n in needles:
            if n not in text:
                print(f"[FAIL] dispatch_sites: {rel} 缺新名分派 {n!r}")
                return False
        if f'"{OLD}"' in text:
            print(f"[FAIL] dispatch_sites: {rel} 仍含旧名 literal \"{OLD}\"（别名复活/漏改）")
            return False
    print("[PASS] dispatch_sites: 四处分派点全部只认新名 + 旧名 literal 零残留")
    return True


def opcode_constant_case():
    """IR 操作码常量**不改**（内部标识，非语言面名字）——钉住本批的取舍。"""
    text = _read("src/compiler/ast.cr")
    needle = "IR_NO_BOUNDS_CHECK   : int = 35;"
    if needle not in text:
        print(f"[FAIL] opcode_constant: ast.cr 缺 {needle!r}（内部常量被误改？）")
        return False
    print("[PASS] opcode_constant: IR_NO_BOUNDS_CHECK = 35 不变")
    return True


if __name__ == "__main__":
    raise SystemExit(main())
