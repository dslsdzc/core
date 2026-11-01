#!/usr/bin/env python3
"""CP-2: runtime loader for compiler-emitted concurrency plan text."""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"
COREARCH = BASE / "build" / "corearch"

LOAD_RUN = """\
import conc

g_out : string, mut

fn entry_main() -> int:
    return 0

fn worker(req: string) -> int:
    v := conc_recv(req)
    if conc_is_ok(v) == 0:
        return 1
    conc_send(g_out, v)
    return 0

fn main() -> int:
    r := conc_region_new(65536)
    req := conc_channel_new(r, 8, 1)
    g_out = conc_channel_new(r, 8, 1)
    tbl := alloc(16)
    cell_store(tbl, 0, @addr(entry_main))
    cell_store(tbl, 8, @addr(worker))
    plan := "v 1\\nentries 2\\nbody 0 TASK 0 0\\nbody 1 TASK 1 1\\nchannel 0 8 1 SPSC\\nedge 0 1 SPAWN -1\\n"
    p := conc_plan_load(plan, tbl)
    if p < 0:
        return 1
    if conc_plan_body_count(p) != 2:
        return 2
    if conc_plan_channel_count(p) != 1:
        return 3
    if conc_plan_edge_count(p) != 1:
        return 4
    if conc_plan_edge_channel(p, 0) != -1:
        return 5
    msg := conc_alloc(r, 8)
    cell_store(msg, 0, 41)
    if conc_send(req, msg) != 0:
        return 6
    if conc_run_body(p, 1, req) != 0:
        return 7
    out := conc_recv(g_out)
    if conc_is_ok(out) == 0:
        return 8
    if cell_load(out, 0) != 41:
        return 9
    return 0
"""

EMITTER_FIXTURE = """\
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

E2E_TEMPLATE = """\
import conc

g_out : string, mut

fn entry_main() -> int:
    return 0

fn worker(req: string) -> int:
    v := conc_recv(req)
    if conc_is_ok(v) == 0:
        return 1
    conc_send(g_out, v)
    return 0

fn main() -> int:
    r := conc_region_new(65536)
    req := conc_channel_new(r, 8, 1)
    g_out = conc_channel_new(r, 8, 1)
    tbl := alloc(16)
    cell_store(tbl, 0, @addr(entry_main))
    cell_store(tbl, 8, @addr(worker))
    plan := "%s"
    p := conc_plan_load(plan, tbl)
    if p < 0:
        return 1
    msg := conc_alloc(r, 8)
    cell_store(msg, 0, 41)
    if conc_send(req, msg) != 0:
        return 2
    if conc_run_body(p, 1, req) != 0:
        return 3
    out := conc_recv(g_out)
    if conc_is_ok(out) == 0:
        return 4
    if cell_load(out, 0) != 41:
        return 5
    return 0
"""

LOAD_SIMT = """\
import conc

g_arr : string, mut

fn par(i: int) -> int:
    cell_store(g_arr, i * 8, i * i)
    return 0

fn main() -> int:
    r := conc_region_new(65536)
    g_arr = conc_alloc(r, 8 * 8)
    tbl := alloc(8)
    cell_store(tbl, 0, @addr(par))
    p := conc_plan_load("v 1\\nentries 1\\nbody 0 PAR 0 8\\n", tbl)
    if p < 0:
        return 1
    if conc_run_cpu(p, "") != 0:
        return 2
    i : ., mut = 0
    loop:
        if i >= 8:
            break
        if cell_load(g_arr, i * 8) != i * i:
            return 3
        cell_store(g_arr, i * 8, -1)
        i = i + 1
    if conc_run_simt(p, 0, 8) != 0:
        return 4
    i = 0
    loop:
        if i >= 8:
            break
        if cell_load(g_arr, i * 8) != i * i:
            return 5
        i = i + 1
    return 0
"""

LOAD_NEGATIVE = """\
import conc

fn main() -> int:
    r := conc_region_new(4096)
    tbl := alloc(8)
    cell_store(tbl, 0, @addr(main))
    if conc_plan_load("v 1\\nentries 1\\nbody 0 TASK 5 0\\n", tbl) != -1:
        return 1
    if conc_plan_load("v 1\\nentries 1\\nbogus\\n", tbl) != -1:
        return 2
    if conc_plan_load("v 1\\nentries 1\\nchannel 0 8 1 MPMC\\n", tbl) != -1:
        return 3
    if conc_plan_load("v 2\\nentries 0\\n", tbl) != -1:
        return 4
    return 0
"""


def run(cmd: list[str], timeout: int = 120) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=BASE, capture_output=True, text=True,
                          timeout=timeout)


def build_run(name: str, source: str, timeout: int = 60) -> bool:
    if not COREC.exists() or not COREARCH.exists():
        print("FAIL: missing build/corec or build/corearch")
        return False
    with tempfile.TemporaryDirectory(prefix=f"conc_plan_{name}_") as td:
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
        if r.returncode != 0:
            print(f"FAIL {name} run rc={r.returncode}")
            print(r.stdout[-1600:])
            print(r.stderr[-1600:])
            return False
    print(f"PASS {name}")
    return True


def e2e_case(name: str, timeout: int = 60) -> bool:
    with tempfile.TemporaryDirectory(prefix="conc_plan_e2e_") as td:
        root = Path(td)
        src = root / "fixture.cr"
        plan = root / "fixture.plan"
        src.write_text(EMITTER_FIXTURE, encoding="utf-8")
        r = run([str(COREC), "conc-plan", str(src), "-o", str(plan)])
        if r.returncode != 0 or not plan.exists():
            print(f"FAIL {name}: emitter rc={r.returncode}")
            print((r.stdout + r.stderr)[-1600:])
            return False
        text = plan.read_text(encoding="utf-8")
        escaped = text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
        generated = E2E_TEMPLATE % escaped
        return build_run(name, generated, timeout)


def main() -> int:
    cases = [
        ("conc_plan_load", LOAD_RUN, 30),
        ("conc_plan_simt", LOAD_SIMT, 30),
        ("conc_plan_negative", LOAD_NEGATIVE, 30),
    ]
    passed = 0
    for name, source, timeout in cases:
        if build_run(name, source, timeout):
            passed += 1
    if e2e_case("conc_plan_e2e"):
        passed += 1
    total = len(cases) + 1
    print(f"{passed}/{total} passed")
    return 0 if passed == total else 1


if __name__ == "__main__":
    raise SystemExit(main())
