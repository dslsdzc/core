#!/usr/bin/env python3
"""`tests/suite` 腿卫生判据（2026-09-18 suite 清障批；自举编译器 build/corec）。

背景：`suite` 腿（`src/ci/run.sh::run_suite`）**不在 PR 门内**，且它是 `set -euo pipefail` 下的
「逐档 build+run，任一档失败即中止整腿」⇒ 它自己的绿/红不进门。本文件把**本批改动的四处期望**
搬进 `selfhost-tests`（在门内），使「suite 语料的状态」有机械判据，而不是只在派全量层时才可见。

判据：
  H1 **两档正例（本批修好）**：`at_test_mini.cr`（`@sizeOf`）与 `at_test_mini9.cr`（`@fields`）
     ⇒ build rc=0 **且** run rc=0。（改前：前者 `error[N06]` 缺 `import io`；后者运行 rc=1。）
  H2 **两档负例（语言面拒收）**：`at_test_mini4.cr` / `at_test_mini6.cr`（函数体内嵌套 `fn`）
     ⇒ `check` rc≠0 **且**输出含 `error[P21]` **且** `build` **零产物**（`-o` 目标不生成）。
  H3 **正控（断言有辨别力）**：`at_test.cr` ⇒ build+run rc=0 且**无** P21 字样。
  H4 **skip 面静态钉**：解析 `run_suite()` 的 `case` 块 ⇒ 跳过模式**必须是全路径锚定**
     （含 `*/` 前缀；2026-09-18 本批实测坑：写成裸文件名 `at_test_mini4.cr` 不匹配 `tests/suite/…`
     ⇒ 负例漏进正例循环 ⇒ `set -e` 下整腿中止）；且跳过集合 == {`at_test_mini4.cr`,`at_test_mini6.cr`}。
  H5 **0 字节档集合钉**：`tests/suite` 里 0 字节的 `.cr` 必须**恰好**是
     {`test_control_flow.cr`, `test_generics.cr`}（`run_suite` 以 `[ ! -s ]` 跳过；新增空档 ⇒ 红，
     防「空文件静默混入正例循环又被跳过」）。该两档的**处置（删/写）待裁**，见 TODO #2026-09-18-8。

挂点：`selfhost-tests`（`build_selfhost` 之后 ⇒ `build/corec` 必在）。
"""

import os
import re
import subprocess
import sys
import tempfile

BASE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
COREC = os.path.join(BASE, "build", "corec")
SUITE = os.path.join(BASE, "tests", "suite")
RUN_SH = os.path.join(BASE, "src", "ci", "run.sh")

POS = ("at_test_mini.cr", "at_test_mini9.cr")          # H1：本批修好的正例
NEG = ("at_test_mini4.cr", "at_test_mini6.cr")        # H2：负例（P21）
CONTROL = "at_test.cr"                                # H3：正控
EMPTY = {"test_control_flow.cr", "test_generics.cr"}  # H5：0 字节档（待裁，见 TODO）


def _env():
    e = dict(os.environ)
    # core dump 关闭（桌面 core_pattern 管道会让陷阱程序挂起；同 src/ci/run.sh 头注）
    return e


def clean_cache():
    """逐档清 `.cir` 快照：暖态重放今日实测会给出不同 IR（冷 `@fields`="x,y" / 暖取到别的函数的串）
    ⇒ 不清缓存则本判据**依赖上一轮缓存状态**、不可复现。缺陷本体见 TODO 当日段对应条目。"""
    subprocess.run([COREC, "clean-cache"], capture_output=True, text=True, env=_env())


def check(path):
    r = subprocess.run([COREC, "check", path], capture_output=True, text=True, env=_env())
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def build(path, out):
    r = subprocess.run([COREC, "build", path, "-o", out, "--static"],
                       capture_output=True, text=True, env=_env())
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def run_bin(path):
    r = subprocess.run([path], capture_output=True, text=True, env=_env())
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def h1_positives(tmp):
    bad = []
    for name in POS:
        p = os.path.join(SUITE, name)
        out = os.path.join(tmp, name + ".bin")
        clean_cache()
        rc, log = build(p, out)
        if rc != 0 or not os.path.exists(out):
            bad.append(f"H1 红：{name} build rc={rc}（应为 0 且出产物）")
            continue
        os.chmod(out, 0o755)
        rrc, rlog = run_bin(out)
        if rrc != 0:
            bad.append(f"H1 红：{name} run rc={rrc}（应为 0）；输出={rlog.strip()[:120]}")
    return bad


def h2_negatives(tmp):
    bad = []
    for name in NEG:
        p = os.path.join(SUITE, name)
        clean_cache()
        rc, log = check(p)
        if rc == 0:
            bad.append(f"H2 红：{name} check rc=0（应拒收：嵌套 fn 不属语言面）")
        elif "error[P21]" not in log:
            bad.append(f"H2 红：{name} 拒收了但诊断不含 error[P21]：{log.strip()[:120]}")
        out = os.path.join(tmp, name + ".bin")
        clean_cache()
        brc, blog = build(p, out)
        if os.path.exists(out):
            bad.append(f"H2 红：{name} 构建失败却**留下了产物**（零产物面被破）")
            os.unlink(out)
        elif brc == 0:
            bad.append(f"H2 红：{name} build rc=0（应失败）")
    return bad


def h3_control(tmp):
    bad = []
    p = os.path.join(SUITE, CONTROL)
    out = os.path.join(tmp, CONTROL + ".bin")
    clean_cache()
    rc, log = build(p, out)
    if rc != 0 or not os.path.exists(out):
        return [f"H3 红：正控 {CONTROL} build rc={rc}（应为 0）"]
    if "P21" in log:
        bad.append(f"H3 红：正控 {CONTROL} 输出出现 P21 字样 ⇒ H2 的断言无辨别力")
    os.chmod(out, 0o755)
    rrc, rlog = run_bin(out)
    if rrc != 0:
        bad.append(f"H3 红：正控 {CONTROL} run rc={rrc}（应为 0）")
    return bad


def h4_skip_patterns():
    src = open(RUN_SH, encoding="utf-8").read()
    m = re.search(r"run_suite\(\)\s*\{.*?case \"\$f\" in(.*?)esac", src, re.S)
    if not m:
        return ["H4 红：未能在 run.sh 里定位 run_suite() 的 case 块（判据需同步更新）"]
    body = m.group(1)
    pats = []
    for ln in body.split("\n"):
        s = ln.strip()
        if s.startswith("#") or not s:
            continue
        mm = re.match(r"(.+?)\)\s*continue\s*;;", s)
        if mm:
            pats += [p.strip() for p in mm.group(1).split("|")]
    bad = []
    names = {p.split("/")[-1] for p in pats}          # 模式 → 档名（模式可含 `*/` 前缀）
    if names != set(NEG):
        bad.append(f"H4 红：run_suite 跳过集合 = {sorted(names)}（应恰为 {sorted(NEG)}）")
    for p in pats:
        if not p.startswith("*/"):
            bad.append(f"H4 红：跳过模式 `{p}` 未锚定全路径（`$f` 形如 `tests/suite/<name>`；"
                       f"裸文件名不匹配 ⇒ 负例漏进正例循环 ⇒ set -e 下整腿中止）")
    return bad


def h5_empty_set():
    empties = {n for n in os.listdir(SUITE)
               if n.endswith(".cr") and os.path.getsize(os.path.join(SUITE, n)) == 0}
    if empties != EMPTY:
        return [f"H5 红：0 字节档集合 = {sorted(empties)}（应恰为 {sorted(EMPTY)}；"
                f"新增空档须同批处置并更新本判据 + TODO #2026-09-18-8）"]
    return []


def main():
    if not os.path.exists(COREC):
        print("[FAIL] 缺 build/corec（本判据需先 build_selfhost；CI 的 selfhost-tests 档已保证）")
        return 1
    bad = []
    with tempfile.TemporaryDirectory() as tmp:
        bad += h1_positives(tmp)
        bad += h2_negatives(tmp)
        bad += h3_control(tmp)
    bad += h4_skip_patterns()
    bad += h5_empty_set()
    for b in bad:
        print("[FAIL]", b)
    total = len(POS) + len(NEG) + 1 + 1 + 1
    if bad:
        print(f"存在失败项（H1–H5 · {total} 组）")
        return 1
    print(f"[PASS] H1 两档正例 build+run rc=0（{', '.join(POS)}）")
    print(f"[PASS] H2 两档负例 check rc≠0 + error[P21] + 零产物（{', '.join(NEG)}）")
    print(f"[PASS] H3 正控 {CONTROL} rc=0 且无 P21（断言有辨别力）")
    print("[PASS] H4 run_suite 跳过集合 = 两档负例 且模式全路径锚定")
    print(f"[PASS] H5 0 字节档集合 == {sorted(EMPTY)}（待裁，见 TODO #2026-09-18-8）")
    print(f"5/5 通过（H1–H5）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
