#!/usr/bin/env python3
"""判据载体化批（criteria-carrier）T1：canary 载体的**牙**——防「闸门自己也是静默判据」。

被验对象：`tools/baseline/canary_check.sh`（闸门本体）+ `tools/baseline/canary_values.tsv`
（锁定值单一真源）。背景：canary sha 与 `.ccr` 四条锁定值长期只在 docs/ 与 .superpowers/
的文字里，零自动化载体（每个批次靠人/代理手跑引用）——与本仓已发生过一次的
`test_backend_bootstrap.py`「自称已挂 CI 而 run.sh 零命中」同类。

三层（逐层独立可诊断）：
  A 机械（无编译器、毫秒级）：run.sh **真挂**本载体与本测试；值表 5 条、sha 为 64 位小写
    hex、集合与载体 spec **双向**相等。
  B 合成自证（无编译器、毫秒级）：`canary_check.sh --selftest` ⇒ 必须 rc=0
    （S1 绿路可达 + S2–S6 五类必红：同尺寸改内容 / 改尺寸 / 缺产物 / 值表缩水 / 假期望）。
  C **真产物篡改**（需 build/corec）：采集（若 build/canary_artifacts/ 已在则复用 ⇒ 零额外
    编译，因 run.sh 里载体先跑）→ `--verify-only` 必须**绿** → 翻一字节 → `--verify-only`
    必须**红**且**指名**该产物与「期望 vs 实际」；再验缺产物亦红。

口径（照本仓纪律）：
  · C 层需要 compiler ⇒ 本地未构建时 `[SKIP]`（**显式打印**，不静默）；`--require-compiler`
    （CI 用；run.sh 的 selfhost-tests 首行即 build_selfhost）时 ⇒ 缺编译器 = **FAIL**。
  · 判据不符时的唯一正确动作 = 停下上报，**不得**改值表对齐（换代纪律见计划 §6）。

跑法：python3 tests/harness/test_canary_carrier.py [--require-compiler]
"""

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
RUN_SH = os.path.join(ROOT, "src", "ci", "run.sh")
CARRIER = os.path.join(ROOT, "tools", "baseline", "canary_check.sh")
VALUES = os.path.join(ROOT, "tools", "baseline", "canary_values.tsv")
COREC = os.path.join(ROOT, "build", "corec")
ARTIFACT_DIR = os.path.join(ROOT, "build", "canary_artifacts")

# 载体 spec（`canary_check.sh` 的 SPEC_NAMES；两侧集合须**双向**相等 ⇒ 本常量随 spec 同步）
SPEC_NAMES = ["canary_elf", "pa_ccr", "pa_static_ccr", "gt_ccr", "gt_static_ccr"]
# 载体挂点（**可执行行**；注释行不算——「注释里自称挂」正是本判据要抓的形态）
CARRIER_HOOK_RE = re.compile(r"^\s*bash\s+tools/baseline/canary_check\.sh\b")
# 非空转下限：值表条数（防「值表被清空 ⇒ 空对空假绿」）
MIN_VALUES = 5


def hooked_lines(run_sh_text, pattern):
    """run.sh 中的可执行挂点行（剥行首空白；注释行不算）。"""
    return [ln.strip() for ln in run_sh_text.splitlines()
            if ln.strip() and not ln.strip().startswith("#") and pattern.match(ln)]


def load_values(path):
    """值表 → {name: (artifact, sha, size)}；格式非法 ⇒ 抛 AssertionError。"""
    vals = {}
    with open(path, encoding="utf-8") as fh:
        for no, raw in enumerate(fh, 1):
            line = raw.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            cols = line.split("\t")
            if len(cols) != 4:
                raise AssertionError(f"值表第 {no} 行须 4 列 TSV：{line!r}")
            name, art, sha, size = (c.strip() for c in cols)
            if name in vals:
                raise AssertionError(f"值表重复条目：{name}")
            if not re.fullmatch(r"[0-9a-f]{64}", sha):
                raise AssertionError(f"值表 {name}: sha256 非 64 位小写 hex：{sha!r}")
            if not re.fullmatch(r"[0-9]+", size):
                raise AssertionError(f"值表 {name}: size 非十进制：{size!r}")
            vals[name] = (art, sha, int(size))
    return vals


def run(cmd, **kw):
    return subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, **kw)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--require-compiler", action="store_true",
                    help="缺 build/corec ⇒ FAIL（CI 用；本地默认 ⇒ 显式 SKIP）")
    args = ap.parse_args()

    fails, passes = [], []
    skipped = []

    # ── A. 机械层 ──
    with open(RUN_SH, encoding="utf-8") as fh:
        run_sh_text = fh.read()

    if not hooked_lines(run_sh_text, CARRIER_HOOK_RE):
        fails.append("A1 run.sh **未真挂**载体（`bash tools/baseline/canary_check.sh` "
                     "可执行行零命中）——闸门形同虚设")
    else:
        passes.append("A1 run.sh 真挂载体")

    self_rel = "tests/harness/test_canary_carrier.py"
    if not hooked_lines(run_sh_text, re.compile(r"^\s*python3\s+" + re.escape(self_rel) + r"\b")):
        fails.append(f"A2 run.sh **未真挂**本测试（{self_rel}）——牙本身会静默")
    else:
        passes.append("A2 run.sh 真挂本测试")

    try:
        vals = load_values(VALUES)
    except AssertionError as exc:
        fails.append(f"A3 值表格式非法：{exc}")
        vals = {}
    if vals:
        if len(vals) < MIN_VALUES:
            fails.append(f"A3 值表只有 {len(vals)} 条（下界 {MIN_VALUES}）——非空转下限")
        missing = [n for n in SPEC_NAMES if n not in vals]
        extra = [n for n in vals if n not in SPEC_NAMES]
        if missing:
            fails.append(f"A3 值表缺 spec 条目：{missing}（断言面缩水）")
        if extra:
            fails.append(f"A3 值表含 spec 之外条目：{extra}")
        if not missing and not extra:
            passes.append(f"A3 值表 {len(vals)} 条 ↔ spec 双向相等")

    # ── B. 合成自证 ──
    r = run(["bash", CARRIER, "--selftest"])
    if r.returncode != 0:
        fails.append(f"B --selftest rc={r.returncode}（期望 0）——闸门自证失败\n"
                     + "\n".join("    " + ln for ln in (r.stdout + r.stderr).splitlines()[-8:]))
    else:
        sub = (r.stdout + r.stderr).count("[PASS] selftest")
        if sub < 6:
            fails.append(f"B --selftest 只报 {sub} 个子检（期望 6）——自证面缩水")
        else:
            passes.append(f"B 合成自证 {sub}/6（绿路可达 + 5 类必红）")

    # ── C. 真产物篡改（需编译器） ──
    if not os.path.exists(COREC):
        if args.require_compiler:
            fails.append("C 需要 build/corec（--require-compiler）而它不存在——"
                         "fail-closed：不得静默跳过真牙腿")
        else:
            skipped.append("C 真产物篡改腿 [SKIP]：build/corec 不存在（本地未构建；"
                           "CI selfhost-tests 首行 build_selfhost ⇒ 该腿必跑）")
    else:
        if not (os.path.isdir(ARTIFACT_DIR) and os.path.exists(os.path.join(ARTIFACT_DIR, "pa.ccr"))):
            rc = run(["bash", CARRIER]).returncode
            if rc != 0:
                fails.append(f"C 采集（载体默认模式）rc={rc}——真判据未过 ⇒ 见上方载体输出")
        if os.path.isdir(ARTIFACT_DIR):
            base = run(["bash", CARRIER, "--verify-only", ARTIFACT_DIR])
            if base.returncode != 0:
                fails.append(f"C 采集目录 --verify-only rc={base.returncode}（期望 0）")
            else:
                passes.append("C 真产物 --verify-only 绿（5/5）")
                # 篡改副本（不动采集目录本身）
                tmp = tempfile.mkdtemp(prefix="canary_teeth_")
                try:
                    dst = os.path.join(tmp, "arts")
                    shutil.copytree(ARTIFACT_DIR, dst)
                    victim = os.path.join(dst, "pa.ccr")
                    blob = bytearray(open(victim, "rb").read())
                    blob[len(blob) // 2] ^= 0xFF          # 同尺寸翻转一字节
                    open(victim, "wb").write(bytes(blob))
                    r2 = run(["bash", CARRIER, "--verify-only", dst])
                    out2 = r2.stdout + r2.stderr
                    if r2.returncode == 0:
                        fails.append("C 篡改 pa.ccr 一字节后 --verify-only **仍绿** —— "
                                     "闸门无牙（值不符未变红）")
                    elif "pa_ccr" not in out2 or "expected=" not in out2 or "actual=" not in out2:
                        fails.append("C 篡改后虽红但未指名产物/未打印「期望 vs 实际」——"
                                     "红不可诊断；输出尾部：\n"
                                     + "\n".join("    " + ln for ln in out2.splitlines()[-5:]))
                    else:
                        passes.append("C 篡改一字节 ⇒ 必红且指名 pa_ccr（期望 vs 实际）")
                    # 缺产物 ⇒ 必红
                    os.remove(os.path.join(dst, "gt_st.bin.ccr"))
                    r3 = run(["bash", CARRIER, "--verify-only", dst])
                    if r3.returncode == 0:
                        fails.append("C 缺产物后 --verify-only **仍绿** —— 缺件未变红")
                    else:
                        passes.append("C 缺产物 ⇒ 必红")
                finally:
                    shutil.rmtree(tmp, ignore_errors=True)
            # 缺 sha256sum 场景不可在 CI 内安全构造 ⇒ 以 B 层 S1–S6 覆盖判据函数面

    # ── 汇总 ──
    for s in skipped:
        print(f"[SKIP] {s}")
    for p in passes:
        print(f"[PASS] {p}")
    for f in fails:
        print(f"[FAIL] {f}")
    if fails:
        print(f"[canary-carrier] FAIL — pass={len(passes)} fail={len(fails)} skip={len(skipped)}")
        return 1
    print(f"[canary-carrier] PASS — pass={len(passes)} skip={len(skipped)} "
          f"（值表={os.path.relpath(VALUES, ROOT)} · 载体={os.path.relpath(CARRIER, ROOT)}）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
