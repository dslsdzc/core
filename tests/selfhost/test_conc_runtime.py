#!/usr/bin/env python3
"""CP-1: cross-paradigm runtime substrate tests."""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"
COREARCH = BASE / "build" / "corearch"

REGION = """\
import conc

fn main() -> int:
    r := conc_region_new(4096)
    if r < 0:
        return 1
    p := conc_alloc(r, 64)
    if conc_is_ok(p) == 0:
        return 2
    q := conc_alloc(r, 64)
    if conc_is_ok(q) == 0:
        return 3
    if conc_same(q, p) != 0:
        return 4
    conc_region_reset(r)
    p2 := conc_alloc(r, 64)
    if conc_same(p2, p) == 0:
        return 5
    return 0
"""

CHANNEL = """\
import conc

fn main() -> int:
    r := conc_region_new(8192)
    ch := conc_channel_new(r, 16, 2)
    if conc_is_ok(ch) == 0:
        return 1
    a := conc_alloc(r, 16)
    b := conc_alloc(r, 16)
    cell_store(a, 0, 11)
    cell_store(a, 8, 12)
    cell_store(b, 0, 21)
    cell_store(b, 8, 22)
    if conc_send(ch, a) != 0:
        return 2
    if conc_send(ch, b) != 0:
        return 3
    if conc_channel_len(ch) != 2:
        return 4
    x := conc_recv(ch)
    y := conc_recv(ch)
    if conc_is_ok(x) == 0 || conc_is_ok(y) == 0:
        return 5
    if cell_load(x, 0) != 11 || cell_load(x, 8) != 12:
        return 6
    if cell_load(y, 0) != 21 || cell_load(y, 8) != 22:
        return 7
    z := conc_recv(ch)
    if conc_is_ok(z) != 0:
        return 8
    return 0
"""

PLAN = """\
import conc

fn main() -> int:
    p := conc_plan_new()
    if p < 0:
        return 1
    b0 := conc_plan_add_body(p, CONC_BODY_TASK, 0, 1)
    b1 := conc_plan_add_body(p, CONC_BODY_TASK, 0, 0)
    c := conc_plan_add_channel(p, 8, 1, 1)
    if b0 != 0 || b1 != 1 || c != 0:
        return 2
    if conc_plan_body_count(p) != 2:
        return 3
    if conc_plan_channel_count(p) != 1:
        return 4
    return 0
"""

CPU = """\
import conc

g_out : string, mut

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
    p := conc_plan_new()
    conc_plan_add_body(p, CONC_BODY_TASK, @addr(worker), 1)
    v := conc_alloc(r, 8)
    cell_store(v, 0, 41)
    conc_send(req, v)
    rc := conc_run_cpu(p, req)
    if rc != 0:
        return 2
    out := conc_recv(g_out)
    if conc_is_ok(out) == 0:
        return 3
    if cell_load(out, 0) != 41:
        return 4
    return 0
"""

SIMT = """\
import conc

g_arr : string, mut

fn par(i: int) -> int:
    cell_store(g_arr, i * 8, i * i)
    return 0

fn main() -> int:
    r := conc_region_new(65536)
    g_arr = conc_alloc(r, 8 * 16)
    p := conc_plan_new()
    conc_plan_add_body(p, CONC_BODY_DATA_PARALLEL, @addr(par), 16)
    if conc_run_cpu(p, "") != 0:
        return 1
    i : ., mut = 0
    loop:
        if i >= 16:
            break
        if cell_load(g_arr, i * 8) != i * i:
            return 2
        cell_store(g_arr, i * 8, -1)
        i = i + 1
    if conc_run_simt(p, 0, 16) != 0:
        return 3
    i = 0
    loop:
        if i >= 16:
            break
        if cell_load(g_arr, i * 8) != i * i:
            return 4
        i = i + 1
    return 0
"""

LIFETIME = """\
import conc

fn main() -> int:
    r := conc_region_new(1024)
    ch := conc_channel_new(r, 8, 1)
    v := conc_alloc(r, 8)
    cell_store(v, 0, 7)
    conc_region_reset(r)
    if conc_send(ch, v) == 0:
        return 1
    if conc_recv(ch) != "":
        return 2
    return 0
"""

NEGATIVE = """\
import conc

fn task(i: int) -> int:
    return 0

fn main() -> int:
    r := conc_region_new(4096)
    ch := conc_channel_new(r, 8, 1)
    a := conc_alloc(r, 8)
    b := conc_alloc(r, 8)
    cell_store(a, 0, 1)
    cell_store(b, 0, 2)
    if conc_send(ch, a) != 0:
        return 1
    if conc_send(ch, b) != 1:
        return 2
    x := conc_recv(ch)
    if cell_load(x, 0) != 1:
        return 3
    p := conc_plan_new()
    if conc_plan_add_body(p, 99, 0, 0) != -1:
        return 4
    if conc_plan_add_body(p, CONC_BODY_TASK, @addr(task), 1) != 0:
        return 5
    if conc_run_simt(p, 0, 1) != -1:
        return 6
    return 0
"""


def run(cmd: list[str], timeout: int = 120) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=BASE, capture_output=True, text=True,
                          timeout=timeout)


def build_run(name: str, source: str, timeout: int = 60) -> bool:
    if not COREC.exists() or not COREARCH.exists():
        print("FAIL: missing build/corec or build/corearch")
        return False
    with tempfile.TemporaryDirectory(prefix=f"conc_{name}_") as td:
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


def main() -> int:
    cases = [
        ("conc_region", REGION, 30),
        ("conc_channel", CHANNEL, 30),
        ("conc_plan", PLAN, 30),
        ("conc_cpu", CPU, 30),
        ("conc_simt", SIMT, 30),
        ("conc_lifetime", LIFETIME, 30),
        ("conc_negative", NEGATIVE, 30),
    ]
    passed = 0
    for name, source, timeout in cases:
        if build_run(name, source, timeout):
            passed += 1
    print(f"{passed}/{len(cases)} passed")
    return 0 if passed == len(cases) else 1


if __name__ == "__main__":
    raise SystemExit(main())
