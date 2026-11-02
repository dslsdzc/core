#!/usr/bin/env python3
"""CP-6: plan v2 (MPMC/range/slot/target/transfer/budget/cert) and slots."""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"
COREARCH = BASE / "build" / "corearch"

V2_LOAD = """\
import conc

fn square(x: int) -> int:
    return x * x

fn main() -> int:
    tbl := alloc(8)
    cell_store(tbl, 0, @addr(square))
    text := "v 2\\nentries 1\\ntarget cpu 2 1\\nslot 0 THREAD -1 2\\nslot 1 FIBER 0 4\\nbody 0 PAR 0 16\\nchannel 0 8 0 MPMC\\nrange 0 0 16\\ntransfer 0 MOVE 0 0 16\\nbudget 0 COUNT 100 PROVED\\ncert 0 1 UNKNOWN\\n"
    plan := conc_plan_load(text, tbl)
    if plan < 0:
        return 1
    if conc_plan_version(plan) != 2:
        return 2
    if conc_plan_target_name(plan) != "cpu":
        return 3
    if conc_plan_target_slots(plan) != 2:
        return 4
    if conc_plan_slot_count(plan) != 2:
        return 5
    if conc_plan_slot_kind(plan, 1) != CONC_SLOT_CPU_FIBER:
        return 6
    if conc_plan_slot_parent(plan, 1) != 0:
        return 7
    if conc_plan_range_count(plan) != 1:
        return 8
    if conc_plan_range_start(plan, 0) != 0:
        return 9
    if conc_plan_range_len(plan, 0) != 16:
        return 10
    if conc_plan_transfer_count(plan) != 1:
        return 11
    if conc_plan_transfer_kind(plan, 0) != CONC_TRANSFER_MOVE:
        return 12
    if conc_plan_budget_status(plan, 0) != CONC_STATUS_PROVED:
        return 13
    if conc_plan_cert_status(plan, 0) != CONC_STATUS_UNKNOWN:
        return 14
    if conc_plan_budget_ok(plan) != 1:
        return 23
    if conc_plan_cert_ok(plan) != 0:
        return 24
    if conc_plan_deterministic(plan) != 0:
        return 25
    if conc_plan_validate(plan) != 1:
        return 26
    if str_len(conc_plan_explain(plan)) < 20:
        return 27
    cyc := conc_plan_new()
    conc_plan_add_body(cyc, CONC_BODY_TASK, 1, 0)
    conc_plan_add_body(cyc, CONC_BODY_TASK, 1, 0)
    conc_plan_add_edge(cyc, 0, 1, CONC_EDGE_SPAWN)
    conc_plan_add_edge(cyc, 1, 0, CONC_EDGE_SPAWN)
    if conc_plan_acyclic(cyc) != 0:
        return 28
    if conc_plan_validate(cyc) != 0:
        return 29
    if conc_plan_channel_cap(plan, 0) != 0:
        return 15
    out := alloc(16 * 8)
    if conc_run_range(plan, 0, 0, 16, out) != 0:
        return 16
    sum : ., mut = 0
    i : ., mut = 0
    loop:
        if i >= 16:
            break
        sum = sum + cell_load(out, i * 8)
        i = i + 1
    if sum != 1240:
        return 17
    if conc_plan_load("v 1\\nentries 1\\nchannel 0 8 0 MPMC\\n", tbl) != -1:
        return 18
    if conc_plan_load("v 1\\nentries 1\\nrange 0 0 1\\n", tbl) != -1:
        return 19
    if conc_plan_load("v 2\\nentries 1\\nslot 0 THREAD 0 1\\n", tbl) != -1:
        return 20
    if conc_plan_load("v 2\\nentries 1\\nbudget 0 COUNT 1 BOGUS\\n", tbl) != -1:
        return 21
    if conc_plan_load("v 3\\nentries 1\\n", tbl) != -1:
        return 22
    return 0
"""

PIPE_LOAD = """\
import conc

fn stage() -> int:
    return 7

fn main() -> int:
    tbl := alloc(8)
    cell_store(tbl, 0, @addr(stage))
    plan := conc_plan_load("v 2\\nentries 1\\nbody 0 PIPE 0 0\\n", tbl)
    if plan < 0:
        return 1
    if conc_plan_body_count(plan) != 1:
        return 2
    if conc_run_body(plan, 0, "") != 7:
        return 3
    return 0
"""


MPMC_RUN = """\
import conc
import sched
import chan

fn producer(ch: string) -> int:
    chan_send(ch, 1)
    return 0

fn consumer(ch: string) -> int:
    return chan_recv(ch)

fn main() -> int:
    sched_init()
    p := conc_plan_new()
    if p < 0:
        return 1
    if conc_plan_set_version(p, 2) != 0:
        return 2
    if conc_plan_add_channel(p, 8, 4, CONC_PC_MPMC) != 0:
        return 3
    if conc_plan_add_body(p, CONC_BODY_TASK, @addr(producer), 0) != 0:
        return 4
    if conc_plan_add_body(p, CONC_BODY_TASK, @addr(producer), 1) != 1:
        return 5
    if conc_plan_add_body(p, CONC_BODY_TASK, @addr(producer), 1) != 2:
        return 6
    if conc_plan_add_body(p, CONC_BODY_TASK, @addr(consumer), 1) != 3:
        return 7
    if conc_plan_add_body(p, CONC_BODY_TASK, @addr(consumer), 1) != 4:
        return 8
    if conc_plan_bind_param(p, 1, 0, 0) < 0:
        return 9
    if conc_plan_bind_param(p, 2, 0, 0) < 0:
        return 10
    if conc_plan_bind_param(p, 3, 0, 0) < 0:
        return 11
    if conc_plan_bind_param(p, 4, 0, 0) < 0:
        return 12
    if conc_plan_add_edge(p, 0, 1, CONC_EDGE_SPAWN) != 0:
        return 13
    if conc_plan_add_edge(p, 0, 2, CONC_EDGE_SPAWN) != 1:
        return 14
    if conc_plan_add_edge(p, 0, 3, CONC_EDGE_SPAWN) != 2:
        return 15
    if conc_plan_add_edge(p, 0, 4, CONC_EDGE_SPAWN) != 3:
        return 16
    if conc_plan_validate(p) != 1:
        return 17
    ch := chan_make(8, 4)
    cht := alloc(8)
    cell_store(cht, 0, ch)
    if conc_plan_run(p, 0, cht) != 2:
        return 18
    return 0
"""


SLOTS = """\
import sched
import chan

fn slotid() -> int:
    return conc_current_slot()

fn main() -> int:
    sched_init_slots(2, 3)
    sum : ., mut = 0
    i : ., mut = 0
    loop:
        if i >= 6:
            break
        ch := go slotid()
        sum = sum + chan_recv(ch)
        i = i + 1
    if sum != 15:
        return sum
    return 0
"""

RANGE_SRC = """\
import sched
import chan

fn square(x: int) -> int:
    return x * x

fn main() -> int:
    sched_init()
    arr := go i 0..4 square(i)
    s : ., mut = 0
    j : ., mut = 0
    loop:
        if j >= 4:
            break
        s = s + arr[j]
        j = j + 1
    if s != 14:
        return s
    return 0
"""


def run(cmd: list[str], timeout: int = 120) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=BASE, capture_output=True, text=True,
                          timeout=timeout)


def build_run(name: str, source: str, timeout: int = 60,
              expect: int = 0) -> bool:
    if not COREC.exists() or not COREARCH.exists():
        print("FAIL: missing build/corec or build/corearch")
        return False
    with tempfile.TemporaryDirectory(prefix=f"{name}_") as td:
        root = Path(td)
        src = root / f"{name}.cr"
        ccr = root / f"{name}.ccr"
        elf = root / f"{name}.elf"
        src.write_text(source, encoding="utf-8")
        c = run([str(COREC), "ccr", str(src), "-o", str(ccr)])
        if c.returncode != 0:
            print(f"FAIL {name} corec")
            print(c.stdout[-1600:])
            print(c.stderr[-1600:])
            return False
        a = run([str(COREARCH), "--raw-int", "--elf", str(ccr), "-o", str(elf)])
        if a.returncode != 0:
            print(f"FAIL {name} corearch")
            print(a.stdout[-1600:])
            print(a.stderr[-1600:])
            return False
        r = run([str(elf)], timeout=timeout)
        if r.returncode != expect:
            print(f"FAIL {name} run rc={r.returncode}, expected {expect}")
            print(r.stdout[-1600:])
            print(r.stderr[-1600:])
            return False
    print(f"PASS {name}")
    return True


def range_plan_case() -> bool:
    with tempfile.TemporaryDirectory(prefix="range_plan_") as td:
        root = Path(td)
        src = root / "range_plan.cr"
        plan = root / "range_plan.plan"
        src.write_text(RANGE_SRC, encoding="utf-8")
        r = run([str(COREC), "conc-plan", str(src), "-o", str(plan)])
        if r.returncode != 0 or not plan.exists():
            print(f"FAIL range_plan_emit rc={r.returncode}")
            print(r.stdout[-1600:])
            return False
        text = plan.read_text(encoding="utf-8")
        for line in ["v 2", "target cpu", "slot 0 THREAD", "body 1 PAR 1 4",
                     "range 1 0 4", "budget 0 PROGRESSIVE 0 UNKNOWN",
                     "budget 1 COUNT 4 PROVED", "cert 0 1 UNKNOWN",
                     "edge 0 1 SPAWN -1"]:
            if line not in text:
                print(f"FAIL range_plan_emit missing {line!r}")
                print(text)
                return False
        # Load the emitted artifact in a real Core program and execute the
        # range body through the v2 executor.
        escaped = text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
        loader = f'''import conc
fn square(x: int) -> int:
    return x * x
fn main() -> int:
    tbl := alloc(16)
    cell_store(tbl, 0, @addr(square))
    cell_store(tbl, 8, @addr(square))
    plan := conc_plan_load("{escaped}", tbl)
    if plan < 0:
        return 1
    if conc_plan_version(plan) != 2:
        return 2
    if conc_plan_range_len(plan, 0) != 4:
        return 3
    if conc_plan_budget_count(plan) != 3:
        return 6
    if conc_plan_budget_ok(plan) != 0:
        return 7
    if conc_plan_cert_ok(plan) != 0:
        return 8
    if conc_plan_deterministic(plan) != 1:
        return 9
    out := alloc(4 * 8)
    if conc_run_range(plan, 1, 0, 4, out) != 0:
        return 4
    s : ., mut = 0
    i : ., mut = 0
    loop:
        if i >= 4:
            break
        s = s + cell_load(out, i * 8)
        i = i + 1
    if s != 14:
        return 5
    return 0
'''
        return build_run("range_plan_exec", loader, 60, 0)


PIPE_SRC = """\
import sched
import chan

flow fn pipe(ch: string) -> int:
    v := chan_recv(ch)
    yield v
    return v + 1

fn main() -> int:
    sched_init()
    g_in := chan_make(8, 1)
    h := go pipe(g_in)
    chan_send(g_in, 5)
    r := chan_recv(h)
    if r != 6:
        return r
    return 0
"""


def pipe_plan_case() -> bool:
    with tempfile.TemporaryDirectory(prefix="pipe_plan_") as td:
        root = Path(td)
        src = root / "pipe_plan.cr"
        plan = root / "pipe_plan.plan"
        src.write_text(PIPE_SRC, encoding="utf-8")
        r = run([str(COREC), "conc-plan", str(src), "-o", str(plan)])
        if r.returncode != 0 or not plan.exists():
            print(f"FAIL pipe_plan_emit rc={r.returncode}")
            print(r.stdout[-1600:])
            return False
        text = plan.read_text(encoding="utf-8")
        for line in ["v 2", "body 1 PIPE 1 1", "bind 1 0 0",
                     "edge 0 1 SPAWN -1"]:
            if line not in text:
                print(f"FAIL pipe_plan_emit missing {line!r}")
                print(text)
                return False
        escaped = text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
        loader = f'''import conc
import sched
import chan
fn stage(ch: string) -> int:
    v := chan_recv(ch)
    yield v
    return v + 1
fn main() -> int:
    sched_init()
    tbl := alloc(16)
    cell_store(tbl, 0, @addr(stage))
    cell_store(tbl, 8, @addr(stage))
    plan := conc_plan_load("{escaped}", tbl)
    if plan < 0:
        return 1
    ch := chan_make(8, 1)
    channels := alloc(8)
    cell_store(channels, 0, ch)
    chan_send(ch, 5)
    if conc_run_body_bound(plan, 1, channels) != 6:
        return 2
    return 0
'''
        return build_run("pipe_plan_exec", loader, 60, 0)


def main() -> int:
    cases = [
        ("plan_v2_load", V2_LOAD, 60, 0),
        ("pipe_body_load", PIPE_LOAD, 60, 0),
        ("mpmc_plan_run", MPMC_RUN, 60, 0),
        ("slot_runtime", SLOTS, 60, 0),
    ]
    ok = True
    for name, source, timeout, expect in cases:
        ok = build_run(name, source, timeout, expect) and ok
    ok = range_plan_case() and ok
    ok = pipe_plan_case() and ok
    total = len(cases) + 2
    print(f"{total if ok else 0}/{total} passed")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
