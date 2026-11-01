#!/usr/bin/env python3
"""CP-2: compiler plan emitter for the restricted go/channel slice."""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"

FIXTURE = """\
import chan
import sched

fn worker(req: string) -> int:
    v := chan_recv(req)
    return v

fn main() -> int:
    sched_init()
    req := chan_make(8, 1)
    h := go worker(req)
    chan_send(req, 41)
    return chan_recv(h) - 41
"""

EXPECTED = """\
v 1
entries 2
body 0 TASK 0 0
body 1 TASK 1 1
channel 0 8 1 SPSC
edge 0 1 SPAWN -1
"""

ZERO_FIXTURE = """\
import chan
import sched

fn worker() -> int:
    return 41

fn main() -> int:
    sched_init()
    req := chan_make(8, 1)
    h := go worker()
    return chan_recv(h) - 41
"""

ZERO_EXPECTED = """\
v 1
entries 2
body 0 TASK 0 0
body 1 TASK 1 0
channel 0 8 1 SPSC
edge 0 1 SPAWN -1
"""

MULTI_GO = """\
import chan
import sched

fn worker(req: string) -> int:
    return chan_recv(req)

fn main() -> int:
    sched_init()
    a := chan_make(8, 1)
    b := chan_make(8, 1)
    h1 := go worker(a)
    h2 := go worker(b)
    return 0
"""

DYNAMIC_CAP = """\
import chan
import sched

fn worker(req: string) -> int:
    return chan_recv(req)

fn main(cap: int) -> int:
    sched_init()
    req := chan_make(8, cap)
    h := go worker(req)
    return 0
"""


def run(cmd: list[str], timeout: int = 120) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=BASE, capture_output=True, text=True,
                          timeout=timeout)


def emit(name: str, source: str):
    td = tempfile.TemporaryDirectory(prefix=f"conc_emit_{name}_")
    root = Path(td.name)
    src = root / f"{name}.cr"
    plan = root / f"{name}.plan"
    src.write_text(source, encoding="utf-8")
    r = run([str(COREC), "conc-plan", str(src), "-o", str(plan)])
    text = plan.read_text(encoding="utf-8") if plan.exists() else ""
    diag = r.stdout + r.stderr
    return r.returncode, text, diag, plan, td


def main() -> int:
    failures = 0

    code, text, diag, plan, td = emit("fixture", FIXTURE)
    try:
        if code != 0 or not plan.exists():
            print(f"FAIL emitter_fixture: rc={code}")
            failures += 1
        elif text != EXPECTED:
            print("FAIL emitter_fixture: unexpected plan")
            print(text)
            failures += 1
        else:
            print("PASS emitter_fixture")
    finally:
        td.cleanup()

    code, text, diag, plan, td = emit("zero", ZERO_FIXTURE)
    try:
        if code != 0 or not plan.exists() or text != ZERO_EXPECTED:
            print(f"FAIL emitter_zero_arg: rc={code}")
            print(text)
            failures += 1
        else:
            print("PASS emitter_zero_arg")
    finally:
        td.cleanup()

    for name, source, needle in (
        ("multi_go", MULTI_GO, "exactly one sched_go"),
        ("dynamic_cap", DYNAMIC_CAP, "chan_make cap is not a literal"),
    ):
        code, text, diag, plan, td = emit(name, source)
        try:
            if code == 0 or plan.exists() or needle not in diag:
                print(f"FAIL emitter_fail_closed_{name}: rc={code} plan={plan.exists()}")
                failures += 1
            else:
                print(f"PASS emitter_fail_closed_{name}")
        finally:
            td.cleanup()

    print(f"{4 - failures}/4 passed")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
