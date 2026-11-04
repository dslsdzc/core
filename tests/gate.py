#!/usr/bin/env python3
"""Targeted test gates.

The full selfhost suite contains many negative/fail-closed fixtures that only
need to run when the layer they pin changes.  This entry point maps changed
files to the smallest useful set of tests.

Usage:
    python3 tests/gate.py changed   # default: tests matching the working diff
    python3 tests/gate.py conc      # concurrency happy paths + key failures
    python3 tests/gate.py full      # concurrency + compiler type/purity gates
    python3 tests/gate.py list
"""

from __future__ import annotations

import concurrent.futures
import os
import subprocess
import sys
from pathlib import Path

BASE = Path(__file__).resolve().parents[1]
TESTS = BASE / "tests" / "selfhost"

CONC = [
    "test_conc_runtime.py",
    "test_conc_sched.py",
    "test_multi_m.py",
    "test_conc_flow.py",
    "test_conc_transfer.py",
    "test_conc_preempt.py",
    "test_conc_plan.py",
    "test_conc_plan_emitter.py",
    "test_conc_plan_v2.py",
    "test_conc_autopar.py",
    "test_chan_handle_model.py",
    "test_go_arena.py",
]

COMPILER = [
    "test_ccr_types.py",
    "test_purity.py",
]

SMOKE = ["test_conc_runtime.py"]


def changed_files() -> list[str]:
    for cmd in (["jj", "diff", "--name-only"], ["git", "diff", "--name-only"]):
        try:
            r = subprocess.run(cmd, cwd=BASE, capture_output=True, text=True)
        except FileNotFoundError:
            continue
        if r.returncode == 0:
            return [line.strip() for line in r.stdout.splitlines() if line.strip()]
    return []


def select_changed(files: list[str]) -> list[str]:
    picked: list[str] = []
    for f in files:
        p = f.replace("\\", "/")
        if p.startswith("tests/selfhost/") and p.endswith(".py"):
            name = Path(p).name
            if (TESTS / name).exists():
                picked.append(name)
        if "conc_sched" in p or "conc_cpu" in p or "src/stdlib/sched.cr" in p or "src/stdlib/chan.cr" in p or p.endswith("src/stdlib/conc.cr"):
            picked.extend(CONC)
        if "ir_gen" in p or "conc_plan_emit" in p:
            picked.extend(["test_conc_autopar.py", "test_conc_plan.py",
                           "test_conc_plan_emitter.py",
                           "test_conc_plan_v2.py"])
        if "src/runtime/rt.s" in p or "src/format/elf/elf.cr" in p:
            picked.extend(["test_conc_preempt.py", "test_conc_sched.py"])
        if "src/stdlib/panic.cr" in p:
            picked.extend(SMOKE)
    # Stable de-duplication.
    out: list[str] = []
    for name in picked:
        if name not in out:
            out.append(name)
    return out or SMOKE


def run_one(name: str, env: dict[str, str]) -> tuple[str, int]:
    print(f"== {name}", flush=True)
    r = subprocess.run([sys.executable, str(TESTS / name)], cwd=BASE, env=env)
    return name, r.returncode


def run_tests(names: list[str], jobs: int | None = None) -> int:
    env = os.environ.copy()
    env.setdefault("TMPDIR", "/tmp")
    workers = jobs or min(4, os.cpu_count() or 1)
    failed: list[str] = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as pool:
        futures = [pool.submit(run_one, name, env) for name in names]
        for future in concurrent.futures.as_completed(futures):
            name, rc = future.result()
            if rc != 0:
                failed.append(name)
    print()
    if failed:
        print(f"FAILED: {', '.join(failed)}")
        return 1
    print(f"PASS: {len(names)} test file(s)")
    return 0


def main() -> int:
    arg = sys.argv[1] if len(sys.argv) > 1 else "changed"
    jobs : int | None = None
    if len(sys.argv) > 3 and sys.argv[2] == "--jobs":
        jobs = max(1, int(sys.argv[3]))
    if arg == "list":
        print("conc:", " ".join(CONC))
        print("compiler:", " ".join(COMPILER))
        print("changed:", " ".join(changed_files()) or "(clean)")
        return 0
    if arg == "changed":
        files = changed_files()
        names = select_changed(files)
        print("changed files:", ", ".join(files) if files else "(clean)")
        print("selected:", ", ".join(names))
        return run_tests(names, jobs)
    if arg == "conc":
        return run_tests(CONC, jobs)
    if arg == "full":
        return run_tests(CONC + COMPILER, jobs)
    print(f"unknown gate: {arg}", file=sys.stderr)
    print("use: changed | conc | full | list", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
