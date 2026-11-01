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
bind 1 0 0
edge 0 1 SEND 0
edge 1 0 RECV 0
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
bind 1 0 0
edge 0 1 SEND 0
edge 1 0 RECV 0
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

DISCARD = """\
import chan
import sched

fn make_ch() -> string:
    return chan_make(8, 2)

fn worker(req: string) -> int:
    return chan_recv(req)

fn main() -> int:
    sched_init()
    chan_make(8, 9)
    req := make_ch()
    h := go worker(req)
    return 0
"""

REASSIGN = """\
import chan
import sched

fn make_ch() -> string:
    return chan_make(8, 2)

fn worker(req: string) -> int:
    return chan_recv(req)

fn main() -> int:
    sched_init()
    a : ., mut = chan_make(8, 1)
    a = make_ch()
    h := go worker(a)
    return 0
"""

MAIN_HELPER_GO = """\
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
    h := go worker(req)
    return 0
"""

LONG_CHAIN = """\
import chan
import sched

fn worker(req: string) -> int:
    a0 := req
    a1 := a0
    a2 := a1
    a3 := a2
    a4 := a3
    a5 := a4
    a6 := a5
    a7 := a6
    a8 := a7
    return chan_recv(a8)

fn main() -> int:
    sched_init()
    req := chan_make(8, 1)
    h := go worker(req)
    return 0
"""

GO_LITERAL = """\
import chan
import sched

fn worker(req: string) -> int:
    return 0

fn main() -> int:
    sched_init()
    req := chan_make(8, 1)
    h := go worker("x")
    return 0
"""

GO_NO_ARG = """\
import chan
import sched

fn worker(req: string) -> int:
    return 0

fn main() -> int:
    sched_init()
    req := chan_make(8, 1)
    h := go worker()
    return 0
"""

BRANCH_CAP = """\
import chan
import sched

fn worker(req: string) -> int:
    return chan_recv(req)

fn main() -> int:
    sched_init()
    cap : int, mut
    if 0 != 0:
        cap = 1
    req := chan_make(8, cap)
    h := go worker(req)
    return 0
"""

LOOP_CAP = """\
import chan
import sched

fn worker(req: string) -> int:
    return chan_recv(req)

fn main() -> int:
    sched_init()
    cap : ., mut = 0
    i : ., mut = 0
    loop:
        if i >= 1:
            break
        cap = 1
        i = i + 1
    req := chan_make(8, cap)
    h := go worker(req)
    return 0
"""

ALIAS_CAP = """\
import chan
import sched

fn bump(p: &int):
    *p = 2

fn worker(req: string) -> int:
    return chan_recv(req)

fn main() -> int:
    sched_init()
    cap : ., mut = 1
    bump(&cap)
    req := chan_make(8, cap)
    h := go worker(req)
    return 0
"""

MULTI_CHAN = """\
import chan
import sched

fn worker(req: string) -> int:
    return chan_recv(req)

fn main() -> int:
    sched_init()
    unused := chan_make(8, 2)
    req := chan_make(8, 1)
    h := go worker(req)
    return 0
"""

MULTI_CHAN_EXPECTED = """\
v 1
entries 2
body 0 TASK 0 0
body 1 TASK 1 1
channel 0 8 2 SPSC
channel 1 8 1 SPSC
bind 1 0 1
edge 0 1 SEND 1
edge 1 0 RECV 1
edge 0 1 SPAWN -1
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
        ("multi_chan", MULTI_CHAN, MULTI_CHAN_EXPECTED),
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

    # Frontend/lowering failure must also remove a pre-existing output.
    td = tempfile.TemporaryDirectory(prefix="conc_emit_frontend_fail_")
    root = Path(td.name)
    bad_src = root / "bad.cr"
    bad_plan = root / "bad.plan"
    bad_src.write_text('fn main() -> int:\n    x := 1 + "s"\n    return 0\n', encoding="utf-8")
    bad_plan.write_text("OLD\n", encoding="utf-8")
    r = run([str(COREC), "conc-plan", str(bad_src), "-o", str(bad_plan)])
    checks += 1
    try:
        if r.returncode == 0 or bad_plan.exists():
            print(f"FAIL emitter_frontend_failure_zero_artifact: rc={r.returncode} plan={bad_plan.exists()}")
            failures += 1
        else:
            print("PASS emitter_frontend_failure_zero_artifact")
    finally:
        td.cleanup()

    negatives = [
        ("multi_go", MULTI_GO, "exactly one go", False),
        ("dynamic_cap", DYNAMIC_CAP, "chan_make cap is not a unique literal", False),
        ("int_go", INT_GO, "go target parameter must be a string/channel", False),
        ("go_literal", GO_LITERAL, "literal or missing go argument", False),
        ("go_no_arg", GO_NO_ARG, "literal or missing go argument", False),
        ("two_param_go", TWO_PARAM_GO, "go target must take zero or one parameter", False),
        ("main_param", MAIN_PARAM, "main with parameters", False),
        ("global_cap", GLOBAL_CAP, "chan_make cap is not a unique literal", False),
        ("loop_go", LOOP_GO, "go inside loop/if", False),
        ("branch_cap", BRANCH_CAP, "chan_make cap is not a unique literal", False),
        ("loop_cap", LOOP_CAP, "chan_make cap is not a unique literal", False),
        ("alias_cap", ALIAS_CAP, "chan_make cap is not a unique literal", False),
        ("no_chan", NO_CHAN, "at least one chan_make", False),
        ("go_helper", GO_HELPER, "exactly one go", False),
        ("discard", DISCARD, "cannot resolve chan_make handle", False),
        ("reassign", REASSIGN, "go argument is not a chan_make handle", False),
        ("main_helper_go", MAIN_HELPER_GO, "go outside main", False),
        ("long_chain", LONG_CHAIN, "worker channel chain is too long", False),
        ("preexisting", MULTI_GO, "exactly one go", True),
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
