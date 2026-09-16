#!/usr/bin/env python3
"""CI 挂点覆盖率机械判据（R2 P7 非构建小批；CI 挂点审计 #2026-09-10-5 的落地）。

背景（审计实证，2026-09-16）：`tests/selfhost/test_backend_bootstrap.py` 长期
「自称已挂」（TODO.md 登记句）而 `src/ci/run.sh` **零命中**——它是唯一能拦
「清单双注册漂移（project-mode `error[N06]` 静默）」的门，且**已致一次真实漏检**
（P3a 期间 `import monomorph` 漏删 ⇒ 33×N06 静默、rc=0 产物照出、跨 5 任务不可见）。
缺口账（TODO #2026-09-11-13）因此长期少算一档。**根因 = 挂点覆盖率只靠人记**。

本套件把「挂点覆盖率」变成机械判据（纯 python、毫秒级、无需编译器——故可挂
`bootstrap-tests` job）：
  ① 枚举 SCOPE 三目录的 `test_*.py`；
  ② 从 `src/ci/run.sh` 提取**可执行挂点**（行首 `python3 <路径>`；**注释行不算**
     ——「注释里自称挂」正是本判据要抓的形态）；
  ③ **差集（枚举 − 挂点）必须逐条**出现在 `ci_hook_allowlist.txt`（每条带理由）；
  ④ **反向**：白名单条目必须仍「未挂 + 文件在」——已挂/已删条目 = 白名单腐烂 ⇒ FAIL
     （防「挂上了但不删条目」与「文件没了条目还在」两种静默）；
  ⑤ 非空转下限（语料/挂点数各设下界，防正则或路径改动导致「空对空」假绿）；
  ⑥ **突变自证（内存内、零副作用）**：拿掉 run.sh 的一条真挂点 ⇒ 差集必须立刻包含
     该文件 ⇒ 判据有牙（真删一行的实跑突变记录见本批报告）。

判据口径（照本仓惯例）：「≥N」皆为**下限**（可增不可减）；「未挂」= 允许，但必须
**显式登记 + 理由**——不得静默。
"""

import os
import re
import sys

BASE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RUN_SH = os.path.join(BASE, "src", "ci", "run.sh")
ALLOWLIST = os.path.join(BASE, "tests", "harness", "ci_hook_allowlist.txt")

# SCOPE：与 run.sh 挂点命名一一对应的三目录（扩展须同步改本常量 + 白名单头注）
SCOPE_DIRS = ("tests/selfhost", "tests/bootstrap", "tests/harness")

# 非空转下限（实测基线 2026-09-16 判据载体化批当场重算：语料 65 · 挂点 38 → 取下界留余量；
# 多 agent 并行在加档 ⇒ 计数持续上漂，下限只须留余量、**不追平**，漂移台账见白名单头注）
MIN_SCOPE = 50
MIN_HOOKED = 30

HOOK_RE = re.compile(r"^python3\s+(tests/(?:selfhost|bootstrap|harness)/[A-Za-z0-9_]+\.py)\b")


def scope_files():
    """SCOPE 三目录下的 test_*.py（相对仓库根、排序）。"""
    out = []
    for d in SCOPE_DIRS:
        full = os.path.join(BASE, d)
        if not os.path.isdir(full):
            continue
        for name in sorted(os.listdir(full)):
            if name.startswith("test_") and name.endswith(".py"):
                out.append(f"{d}/{name}")
    return sorted(out)


def hooked_files(run_sh_text):
    """run.sh 文本 → 可执行挂点集合（行首 `python3 tests/...`；剥尾部续行符与注释）。"""
    hooked = set()
    for raw in run_sh_text.splitlines():
        line = raw.strip()
        if line.startswith("#"):
            continue                      # 注释行不算（「自称已挂」的抓点）
        m = HOOK_RE.match(line)
        if m:
            hooked.add(m.group(1))
    return hooked


def load_allowlist(path):
    """白名单 → {路径: 理由}；`#`/空行忽略；**无理由的条目 = 解析失败**（判据要求带理由）。"""
    entries = {}
    with open(path, encoding="utf-8") as fh:
        for no, raw in enumerate(fh, 1):
            line = raw.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            parts = line.split(None, 1)
            if len(parts) != 2 or not parts[1].strip():
                raise AssertionError(
                    f"白名单第 {no} 行缺理由（格式 = `<路径>\\t<理由>`）：{line!r}")
            entries[parts[0].strip()] = parts[1].strip()
    return entries


def check(run_sh_text, allow, scope):
    """纯函数（突变自证复用）：返回 (unhooked_unregistered, stale_entries)。"""
    hooked = hooked_files(run_sh_text)
    unhooked = [f for f in scope if f not in hooked]
    unregistered = [f for f in unhooked if f not in allow]
    stale = []
    for f in sorted(allow):
        if f not in scope and not os.path.exists(os.path.join(BASE, f)):
            stale.append((f, "文件不存在"))
        elif f in hooked:
            stale.append((f, "已挂但白名单未删"))
    return unregistered, stale


def main():
    with open(RUN_SH, encoding="utf-8") as fh:
        run_sh_text = fh.read()
    allow = load_allowlist(ALLOWLIST)
    scope = scope_files()
    hooked = hooked_files(run_sh_text)

    fails = []

    # ⑤ 非空转下限
    if len(scope) < MIN_SCOPE:
        fails.append(f"非空转：SCOPE 语料只有 {len(scope)} 档（下界 {MIN_SCOPE}）"
                     f"——路径/正则可能已失配")
    if len(hooked) < MIN_HOOKED:
        fails.append(f"非空转：run.sh 只解析出 {len(hooked)} 个挂点（下界 {MIN_HOOKED}）"
                     f"——挂点命名可能已改")

    # ③④ 差集与反向
    unregistered, stale = check(run_sh_text, allow, scope)
    if unregistered:
        fails.append("未挂且未登记（缺白名单条目）：\n    " + "\n    ".join(unregistered))
    if stale:
        fails.append("白名单腐烂：\n    " +
                     "\n    ".join(f"{f}（{why}）" for f, why in stale))

    # ⑥ 突变自证：摘掉一条**真挂点**（且不在白名单里）⇒ 差集必须包含它
    hooked_in_scope = [f for f in scope if f in hooked and f not in allow]
    if not hooked_in_scope:
        fails.append("突变自证无法执行：SCOPE 内没有「已挂且不在白名单」的样本")
    else:
        victim = hooked_in_scope[0]
        mutated = "\n".join(
            ln for ln in run_sh_text.splitlines()
            if not HOOK_RE.match(ln.strip()))
        unreg2, _ = check(mutated, set(), scope)
        if victim not in unreg2:
            fails.append(f"突变自证失败：摘掉挂点 {victim} 后差集未包含它"
                         f"（判据无牙）")

    if fails:
        for f in fails:
            print(f"[FAIL] {f}")
        print(f"[ci-hook-coverage] FAIL — scope={len(scope)} hooked={len(hooked)} "
              f"allowlist={len(allow)}")
        return 1

    print(f"[PASS] ci_hook_coverage: scope={len(scope)} hooked={len(hooked)} "
          f"unhooked(allowlisted)={len(allow)}")
    print(f"       run.sh={os.path.relpath(RUN_SH, BASE)} · allowlist="
          f"{os.path.relpath(ALLOWLIST, BASE)} · 突变自证 = 摘挂点必红（内存内）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
