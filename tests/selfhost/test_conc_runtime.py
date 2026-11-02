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

REGION_ARENA = """\
import arena
import conc

fn make_region() -> int:
    return conc_region_new(4096)

fn main() -> int:
    arena_init(67108864, 65536)
    before := arena_current_unchecked()
    r := make_region()
    after := arena_current_unchecked()
    if before != after:
        return 1
    a := arena_new_sized(65536)
    p := conc_alloc(r, 64)
    if conc_is_ok(p) == 0:
        return 2
    cell_store(p, 0, 123)
    arena_reset(a)
    if conc_is_ok(p) == 0:
        return 3
    if cell_load(p, 0) != 123:
        return 4
    return 0
"""

REGION_EXHAUST = """\
import conc

fn main() -> int:
    r := conc_region_new(64)
    if r < 0:
        return 1
    p := conc_alloc(r, 64)
    if conc_is_ok(p) != 0:
        return 2
    ch := conc_channel_new(r, 8, 1000)
    if conc_is_ok(ch) != 0:
        return 3
    r2 := conc_region_new(160)
    ch2 := conc_channel_new(r2, 8, 1)
    a := conc_alloc(r2, 8)
    cell_store(a, 0, 7)
    if conc_send(ch2, a) != 0:
        return 4
    if conc_channel_len(ch2) != 1:
        return 5
    x := conc_recv(ch2)
    if conc_is_ok(x) != 0:
        return 6
    if conc_last_error() != CONC_ERR_NOMEM:
        return 7
    if conc_channel_len(ch2) != 1:
        return 8
    if conc_is_ok(conc_alloc(r2, 9223372036854775807)) != 0:
        return 9
    if conc_is_ok(conc_channel_new(r2, 8, 1000000000000)) != 0:
        return 10
    rb := conc_region_new(1024)
    if conc_is_ok(conc_channel_new(rb, 8, 1000)) != 0:
        return 11
    return 0
"""

ALIGNMENT = """\
import conc

fn main() -> int:
    i : ., mut = 0
    loop:
        if i >= 8:
            break
        d := conc_region_new(72)
        if d < 0:
            return 1
        r := conc_region_new(4096)
        p := conc_alloc(r, 16)
        if conc_is_aligned(p, 16) == 0:
            return 1
        i = i + 1
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

CHANNEL_EDGE = """\
import conc

fn main() -> int:
    r := conc_region_new(16384)
    ch := conc_channel_new(r, 12, 2)
    if conc_channel_elemsize(ch) != 12:
        return 1
    a := conc_alloc(r, 12)
    b := conc_alloc(r, 12)
    c := conc_alloc(r, 12)
    cell_store(a, 0, 101)
    cell_store(a, 8, 102)
    cell_store(b, 0, 201)
    cell_store(b, 8, 202)
    cell_store(c, 0, 301)
    cell_store(c, 8, 302)
    if conc_send(ch, a) != 0:
        return 2
    if conc_send(ch, b) != 0:
        return 3
    cell_store(a, 0, 999)
    x := conc_recv(ch)
    if cell_load(x, 0) != 101:
        return 4
    if cell_load(x, 8) != 102:
        return 5
    if conc_send(ch, c) != 0:
        return 6
    y := conc_recv(ch)
    z := conc_recv(ch)
    if cell_load(y, 0) != 201:
        return 7
    if cell_load(y, 8) != 202:
        return 8
    if cell_load(z, 0) != 301:
        return 9
    if cell_load(z, 8) != 302:
        return 10
    if conc_recv(ch) != "":
        return 11
    if conc_last_error() != CONC_ERR_EMPTY:
        return 12
    return 0
"""

PLAN_GROWTH = """\
import conc

fn main() -> int:
    p := conc_plan_new()
    i : ., mut = 0
    loop:
        if i >= 20:
            break
        if conc_plan_add_body(p, CONC_BODY_TASK, 0, 0) != i:
            return 1
        if conc_plan_add_channel(p, 8, 1, CONC_PC_SPSC) != i:
            return 2
        i = i + 1
    if conc_plan_body_count(p) != 20:
        return 3
    if conc_plan_channel_count(p) != 20:
        return 4
    if conc_plan_add_edge(p, 0, 1, CONC_EDGE_SPAWN) != 0:
        return 5
    if conc_plan_add_edge(p, 1, 2, CONC_EDGE_SEND) != 1:
        return 6
    if conc_plan_add_edge(p, 2, 3, CONC_EDGE_JOIN) != 2:
        return 7
    if conc_plan_edge_count(p) != 3:
        return 8
    j : ., mut = 0
    loop:
        if j >= 12:
            break
        if conc_plan_add_edge(p, j, j + 1, CONC_EDGE_SPAWN) != j + 3:
            return 14
        j = j + 1
    if conc_plan_edge_count(p) != 15:
        return 15
    if conc_plan_add_edge(p, 0, 20, CONC_EDGE_SPAWN) != -1:
        return 9
    if conc_plan_add_body(p, CONC_BODY_TASK, -1, 0) != -1:
        return 10
    if conc_plan_add_body(p, CONC_BODY_TASK, 1, 2) != -1:
        return 11
    if conc_plan_add_channel(p, 8, 0, CONC_PC_SPSC) != -1:
        return 12
    if conc_plan_add_channel(p, 8, 1, 2) != -1:
        return 13
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

CPU0 = """\
import conc

g_hit : int, mut = 0

fn zero() -> int:
    g_hit = 1
    return 0

fn main() -> int:
    p := conc_plan_new()
    conc_plan_add_body(p, CONC_BODY_TASK, @addr(zero), 0)
    if conc_run_cpu(p, "") != 0:
        return 1
    if g_hit != 1:
        return 2
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
    i = 0
    loop:
        if i >= 16:
            break
        cell_store(g_arr, i * 8, -1)
        i = i + 1
    if conc_run_simt(p, 4, 8) != 0:
        return 5
    i = 0
    loop:
        if i >= 16:
            break
        v := cell_load(g_arr, i * 8)
        if i >= 4:
            if i < 8:
                if v != i * i:
                    return 6
            else:
                if v != -1:
                    return 7
        else:
            if v != -1:
                return 7
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
    if conc_is_ok("hello") != 0:
        return 1
    conc_region_reset(r)
    if conc_is_ok(v) != 0:
        return 2
    if conc_send(ch, v) == 0:
        return 3
    if conc_recv(ch) != "":
        return 4
    return 0
"""

REF = """\
import conc

fn main() -> int:
    r := conc_region_new(4096)
    ref := conc_ref_alloc(r, 8, 7)
    if conc_ref_ok(ref) == 0:
        return 1
    p := conc_ref_payload(ref)
    cell_store(p, 0, 123)
    off := conc_ref_offset(ref)
    conc_region_reset(r)
    if conc_ref_ok(ref) != 0:
        return 2
    if conc_ref_payload(ref) != "":
        return 3
    ref2 := conc_ref_alloc(r, 8, 7)
    if conc_ref_ok(ref2) == 0:
        return 4
    if conc_ref_offset(ref2) != off:
        return 5
    if conc_ref_layout(ref2) != 7:
        return 6
    p2 := conc_ref_payload(ref2)
    cell_store(p2, 0, 456)
    if cell_load(p2, 0) != 456:
        return 7
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
    bad := alloc(8)
    cell_store(a, 0, 1)
    cell_store(b, 0, 2)
    if conc_send(ch, a) != 0:
        return 1
    if conc_send(ch, b) != 1:
        return 2
    if conc_last_error() != CONC_ERR_FULL:
        return 7
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
    if conc_channel_len(bad) != -1:
        return 8
    if conc_channel_elemsize(bad) != -1:
        return 9
    if conc_send(bad, a) != CONC_ERR_INVALID:
        return 10
    if conc_last_error() != CONC_ERR_INVALID:
        return 11
    if conc_recv(bad) != "":
        return 12
    if conc_last_error() != CONC_ERR_INVALID:
        return 13
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
        ("conc_region_arena", REGION_ARENA, 60),
        ("conc_region_exhaust", REGION_EXHAUST, 30),
        ("conc_alignment", ALIGNMENT, 30),
        ("conc_channel", CHANNEL, 30),
        ("conc_channel_edge", CHANNEL_EDGE, 30),
        ("conc_plan", PLAN, 30),
        ("conc_plan_growth", PLAN_GROWTH, 30),
        ("conc_cpu", CPU, 30),
        ("conc_cpu0", CPU0, 30),
        ("conc_simt", SIMT, 30),
        ("conc_lifetime", LIFETIME, 30),
        ("conc_ref", REF, 30),
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
