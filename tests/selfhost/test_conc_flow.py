#!/usr/bin/env python3
"""CP-6: complete coroutine flow (yield as a stage boundary)."""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"
COREARCH = BASE / "build" / "corearch"

STRAIGHT = """\
import sched
import chan

flow fn gen(x: int) -> int:
    yield x + 1
    yield x + 2
    return x + 3

fn main() -> int:
    sched_init()
    out := alloc(16 * 8)
    n := conc_flow_run(@addr(gen), 10, out)
    if n != 2:
        return n
    if cell_load(out, 0) != 11:
        return 2
    if cell_load(out, 8) != 12:
        return 3
    return 0
"""

LOOP = """\
import sched
import chan

flow fn counter(n: int) -> int:
    i : ., mut = 0
    loop:
        if i >= n:
            break
        yield i
        i = i + 1
    return n

fn main() -> int:
    sched_init()
    out := alloc(16 * 8)
    n := conc_flow_run(@addr(counter), 3, out)
    if n != 3:
        return n
    if cell_load(out, 0) != 0:
        return 2
    if cell_load(out, 8) != 1:
        return 3
    if cell_load(out, 16) != 2:
        return 4
    return 0
"""

TIMEOUT = """\
import sched
import chan

g_ch : string, mut

flow fn stuck(x: int) -> int:
    return chan_recv(g_ch)

fn main() -> int:
    sched_init()
    g_ch = chan_make(8, 0)
    out := alloc(64)
    r := conc_flow_run_timeout(@addr(stuck), 0, out, 20)
    if r != CONC_RESULT_TIMEOUT:
        return r
    conc_flow_reset()
    return 0
"""

CANCEL = """\
import sched
import chan

flow fn gen(x: int) -> int:
    i : ., mut = 0
    loop:
        if i >= 1000:
            break
        yield i
        i = i + 1
    return 0

fn canceler(x: int) -> int:
    i : ., mut = 0
    loop:
        if i >= 10000:
            break
        i = i + 1
    conc_flow_cancel()
    return 0

fn main() -> int:
    sched_init_n(2)
    conc_flow_reset()
    c := go canceler(0)
    out := alloc(8192)
    r := conc_flow_run(@addr(gen), 0, out)
    if r != CONC_RESULT_CANCELLED:
        return r
    if conc_flow_cancelled() == 0:
        return 2
    conc_flow_reset()
    return 0
"""

NESTED = """\
import sched
import chan

flow fn f(n: int) -> int:
    acc : ., mut = 0
    i : ., mut = 0
    loop:
        if i >= n:
            break
        if i % 2 == 0:
            acc = acc + i
            yield acc
        i = i + 1
    return acc

fn main() -> int:
    sched_init()
    out := alloc(16 * 8)
    n := conc_flow_run(@addr(f), 6, out)
    if n != 3:
        return n
    if cell_load(out, 0) != 0:
        return 2
    if cell_load(out, 8) != 2:
        return 3
    if cell_load(out, 16) != 6:
        return 4
    return 0
"""


def run(cmd: list[str], timeout: int = 300) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=BASE, capture_output=True, text=True,
                          timeout=timeout)


def build_run(name: str, source: str) -> bool:
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
        r = run([str(elf)], timeout=60)
        if r.returncode != 0:
            print(f"FAIL {name} run rc={r.returncode}")
            print(r.stdout[-1600:])
            print(r.stderr[-1600:])
            return False
    print(f"PASS {name}")
    return True


def main() -> int:
    cases = [
        ("flow_straight", STRAIGHT),
        ("flow_loop", LOOP),
        ("flow_nested", NESTED),
        ("flow_cancel", CANCEL),
        ("flow_timeout", TIMEOUT),
    ]
    ok = True
    for name, source in cases:
        ok = build_run(name, source) and ok
    print(f"{len(cases) if ok else 0}/{len(cases)} passed")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
