#!/usr/bin/env python3
"""Optional concurrency throughput probe (not part of the default gate)."""
from __future__ import annotations
import os
import subprocess
import sys
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"
COREARCH = BASE / "build" / "corearch"

SRC = """\
import sched
import chan

fn work(n: int) -> int:
    return n

fn main() -> int:
    sched_init_n(4)
    t0 := conc_now_ms()
    sum : ., mut = 0
    i : ., mut = 0
    loop:
        if i >= 2000:
            break
        ch := go work(i)
        sum = sum + chan_recv(ch)
        i = i + 1
    t1 := conc_now_ms()
    if sum != 1999000:
        return 1
    println_i(t1 - t0)
    return 0
"""


def main() -> int:
    env = os.environ.copy()
    env.setdefault("TMPDIR", "/tmp")
    with tempfile.TemporaryDirectory(prefix="conc_bench_") as td:
        root = Path(td)
        src = root / "bench.cr"
        ccr = root / "bench.ccr"
        elf = root / "bench.elf"
        src.write_text(SRC)
        for cmd in (
            [str(COREC), "ccr", str(src), "-o", str(ccr)],
            [str(COREARCH), "--raw-int", "--elf", str(ccr), "-o", str(elf)],
        ):
            r = subprocess.run(cmd, cwd=BASE, env=env, capture_output=True, text=True)
            if r.returncode != 0:
                print(r.stdout[-1000:])
                print(r.stderr[-1000:])
                return 1
        r = subprocess.run([str(elf)], cwd=BASE, env=env, capture_output=True, text=True)
        if r.returncode != 0:
            return r.returncode
    ms = max(int(r.stdout.strip() or "0"), 1)
    print(f"2000 spawn+join in {ms} ms ({2000000 // ms} ops/s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
