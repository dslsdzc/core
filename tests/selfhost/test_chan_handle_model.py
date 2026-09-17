#!/usr/bin/env python3
"""并发 handle 的类型模型对齐（批 8 **A₂**；自举编译器 build/corec）——**自门内 e2e 判据**。

**背景**：`alloc` 的类型模型 = `() -> string`（`checker.cr` 的 `bi_add("alloc", TI_STR)`；
`type_engine.cr` 明文）。而 `src/stdlib/{chan,goroutine,sched}.cr` 把 handle 的返回型写成 `-> int`
⇒ 返回位 `type_compat_strict(string, int) != 1` ⇒ **TF01**（**真类型模型冲突**，非误报；同族先例
`lits_copy` 已被上一批修）。修法 = **(A) 语料/stdlib 向模型对齐**：3 处返回型（`chan_make` · `g_new` ·
透传的 `sched_go`）+ 5 处 handle 形参（`chan_send`/`chan_recv`/`chan_close(ch: string)` ·
`sched_enqueue`/`g_free(g: string)`）。

**为何必须挂在本套件**：5 档并发语料在 `tests/suite/`，而 **`suite` 腿不在 PR 门内**
（台账「PR 门覆盖域陷阱」条：`run_suite` 是 `run.sh` 的 glob 腿、属 `suite` job，仅 `merge_group`（休眠）/
`workflow_dispatch` 可达）⇒ **glob 收编 ≠ 进门**。本套件把「5 档 check 干净 + build + run」编进
`selfhost-tests`（**门内**），使其证据**不悬空**。

**判据**：① 5 档并发语料 `check` rc=0 **且无 `error[TF01]`**（修前 = 各 2 条 TF01、rc=1）；② `build`
rc=0 且产物生成；③ `run` rc=0（行为不变）；④ 对齐后的可见形态自证（`chan_make` 结果可赋 `string`、
`chan_send(ch: string)` 可收）。

**撤条对照**：`diag.cr` 的 TF01 build 豁免**已撤**（旧值 9 条 → 8 条）；「撤条 ≠ 放行」由
`test_diag_gate.py` 的 `neg_type_tf01`（真 TF01 ⇒ rc=1 + 零产物）钉住。
"""

import os
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"
CORPORA = ["chan_test", "conc_test", "go_e2e_test", "go_final_test", "go_parallel_test"]


def run_corec(args, src=None, timeout=300):
    if src is None:
        return subprocess.run([str(COREC)] + args, cwd=BASE, capture_output=True,
                              text=True, timeout=timeout)
    with tempfile.NamedTemporaryFile("w", suffix=".cr", delete=False) as f:
        f.write(f"// chanhandle-{uuid.uuid4()}\n" + src)
        path = f.name
    try:
        return subprocess.run([str(COREC)] + args + [path], cwd=BASE,
                              capture_output=True, text=True, timeout=timeout)
    finally:
        os.unlink(path)


def main():
    ok = 0
    fails = []
    # ── ① 5 档语料：check 干净（无 TF01）──────────────────────────────────
    for name in CORPORA:
        rel = f"tests/suite/{name}.cr"
        r = run_corec(["check", rel])
        bad = "error[TF01]" in (r.stdout + r.stderr)
        if r.returncode == 0 and not bad:
            print(f"[PASS] check_clean_{name}: rc=0 无 TF01")
            ok += 1
        else:
            fails.append(name)
            print(f"[FAIL] check_clean_{name}: rc={r.returncode} TF01={bad}")
    # ── ②③ 5 档语料：build + run（行为不变）──────────────────────────────
    for name in CORPORA:
        rel = f"tests/suite/{name}.cr"
        out = str(BASE / "build" / f"_chanhandle_{name}_{uuid.uuid4().hex[:6]}")
        try:
            b = run_corec(["build", rel, "--static", "-o", out])
            if b.returncode != 0 or not os.path.exists(out):
                fails.append(name)
                print(f"[FAIL] build_{name}: rc={b.returncode}")
                continue
            rc = subprocess.run([out], cwd=BASE, capture_output=True, timeout=180).returncode
            if rc == 0:
                print(f"[PASS] build_run_{name}: build=0 run=0")
                ok += 1
            else:
                fails.append(name)
                print(f"[FAIL] build_run_{name}: run rc={rc}（期望 0）")
        finally:
            for p in (out, out + ".ccr"):
                if os.path.exists(p):
                    os.unlink(p)
    # ── ④ 对齐形态自证（handle 可作 string 流经：赋值 + 传参）──────────────
    probe = ("import chan\n"
             "fn main() -> int {\n"
             "    ch : string = chan_make(8, 1);\n"          # 返回型 = string（模型）
             "    chan_send(ch, 1);\n"                       # 形参 = string
             "    v := chan_recv(ch);\n"
             "    chan_close(ch);\n"
             "    return v - 1;\n"
             "}\n")
    r = run_corec(["check"], probe)
    if r.returncode == 0:
        print("[PASS] aligned_forms: chan_make→string 赋值 + chan_send/recv/close(string) 通过")
        ok += 1
    else:
        fails.append("aligned_forms")
        print(f"[FAIL] aligned_forms: rc={r.returncode} {r.stdout[-200:]}")
    total = len(CORPORA) * 2 + 1
    print(f"\n{ok}/{total} 通过")
    if fails:
        print("失败档：" + ", ".join(sorted(set(fails))))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
