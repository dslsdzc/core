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

MUT_CAP = """\
import chan
import sched

fn worker(req: string) -> int:
    return chan_recv(req)

fn main() -> int:
    sched_init()
    cap : ., mut = 1
    req := chan_make(8, cap)
    cap = 2
    h := go worker(req)
    return 0
"""

MUT_CAP_EXPECTED = """\
v 1
entries 2
body 0 TASK 0 0
body 1 TASK 1 1
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

fn get_cap() -> int:
    return 1

fn worker(req: string) -> int:
    return chan_recv(req)

fn main() -> int:
    sched_init()
    cap := get_cap()
    req := chan_make(8, cap)
    h := go worker(req)
    return 0
"""

INT_GO = """\
import chan
import sched

fn worker(x: int) -> int:
    return x

fn main() -> int:
    sched_init()
    req := chan_make(8, 1)
    h := go worker(0)
    return 0
"""

TWO_PARAM_GO = """\
import chan
import sched

fn worker(req: string, x: int) -> int:
    return x

fn main() -> int:
    sched_init()
    req := chan_make(8, 1)
    h := go worker(req, 0)
    return 0
"""

MAIN_PARAM = """\
import chan
import sched

fn worker(req: string) -> int:
    return chan_recv(req)

fn main(x: int) -> int:
    sched_init()
    req := chan_make(8, 1)
    h := go worker(req)
    return 0
"""

GLOBAL_CAP = """\
import chan
import sched

g_cap : int, mut = 1

fn bump():
    g_cap = 2

fn worker(req: string) -> int:
    return chan_recv(req)

fn main() -> int:
    sched_init()
    bump()
    req := chan_make(8, g_cap)
    h := go worker(req)
    return 0
"""

NO_CHAN = """\
import chan
import sched

fn worker() -> int:
    return 41

fn main() -> int:
    sched_init()
    h := go worker()
    return 0
"""

GO_HELPER = """\
import chan
import sched

fn worker(req: string) -> int:
    return chan_recv(req)

fn spawn_one(req: string) -> int:
    h := go worker(req)
    return 0

fn main() -> int:
    sched_init()
    req := chan_make(8, 1)
    return spawn_one(req)
"""

LOOP_GO = """\
import chan
import sched

fn worker(req: string) -> int:
    return chan_recv(req)

fn main() -> int:
    sched_init()
    req := chan_make(8, 1)
    i : ., mut = 0
    loop:
        if i >= 1:
            break
        h := go worker(req)
        i = i + 1
    return 0
"""


def run(cmd: list[str], timeout: int = 120) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=BASE, capture_output=True, text=True,
                          timeout=timeout)


def emit(name: str, source: str, precreate: str | None = None):
    td = tempfile.TemporaryDirectory(prefix=f"conc_emit_{name}_")
    root = Path(td.name)
    src = root / f"{name}.cr"
    plan = root / f"{name}.plan"
    src.write_text(source, encoding="utf-8")
    if precreate is not None:
        plan.write_text(precreate, encoding="utf-8")
    r = run([str(COREC), "conc-plan", str(src), "-o", str(plan)])
    text = plan.read_text(encoding="utf-8") if plan.exists() else ""
    diag = r.stdout + r.stderr
    return r.returncode, text, diag, plan, td


def emit_no_output(name: str, source: str):
    td = tempfile.TemporaryDirectory(prefix=f"conc_emit_{name}_")
    root = Path(td.name)
    src = root / f"{name}.txt"
    src.write_text(source, encoding="utf-8")
    r = run([str(COREC), "conc-plan", str(src)])
    plan = root / f"{name}.txt.plan"
    text = plan.read_text(encoding="utf-8") if plan.exists() else ""
    diag = r.stdout + r.stderr
    return r.returncode, text, diag, src, plan, td


def main() -> int:
    failures = 0
    checks = 0

    positives = [
        ("fixture", FIXTURE, EXPECTED),
        ("zero_arg", ZERO_FIXTURE, ZERO_EXPECTED),
        ("mut_cap_before_call", MUT_CAP, MUT_CAP_EXPECTED),
    ]
    for name, source, expected in positives:
        code, text, diag, plan, td = emit(name, source)
        checks += 1
        try:
            if code != 0 or not plan.exists() or text != expected:
                print(f"FAIL emitter_{name}: rc={code}")
                print(text)
                print(diag[-800:])
                failures += 1
            else:
                print(f"PASS emitter_{name}")
        finally:
            td.cleanup()

    code, text, diag, src, plan, td = emit_no_output("non_cr", FIXTURE)
    checks += 1
    try:
        if code != 0 or not plan.exists() or text != EXPECTED:
            print(f"FAIL emitter_non_cr_default_output: rc={code}")
            print(diag[-800:])
            failures += 1
        elif src.read_text(encoding="utf-8") != FIXTURE:
            print("FAIL emitter_non_cr_default_output: input was modified")
            failures += 1
        else:
            print("PASS emitter_non_cr_default_output")
    finally:
        td.cleanup()

    negatives = [
        ("multi_go", MULTI_GO, "exactly one sched_go", False),
        ("dynamic_cap", DYNAMIC_CAP, "chan_make cap is not a unique literal", False),
        ("int_go", INT_GO, "go target parameter must be a string/channel", False),
        ("two_param_go", TWO_PARAM_GO, "go target must take zero or one parameter", False),
        ("main_param", MAIN_PARAM, "main with parameters", False),
        ("global_cap", GLOBAL_CAP, "chan_make cap is not a unique literal", False),
        ("loop_go", LOOP_GO, "go inside loop/if", False),
        ("no_chan", NO_CHAN, "at least one chan_make", False),
        ("go_helper", GO_HELPER, "exactly one sched_go", False),
        ("preexisting", MULTI_GO, "exactly one sched_go", True),
    ]
    for name, source, needle, precreate in negatives:
        code, text, diag, plan, td = emit(name, source, "OLD\n" if precreate else None)
        checks += 1
        try:
            if code == 0 or plan.exists() or needle not in diag:
                print(f"FAIL emitter_fail_closed_{name}: rc={code} plan={plan.exists()}")
                print(diag[-800:])
                failures += 1
            else:
                print(f"PASS emitter_fail_closed_{name}")
        finally:
            td.cleanup()

    print(f"{checks - failures}/{checks} passed")
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
