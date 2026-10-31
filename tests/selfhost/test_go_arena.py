#!/usr/bin/env python3
"""Per-G arena context switching with raw-int scheduler corpora."""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"
COREARCH = BASE / "build" / "corearch"

SOURCE = """\
import sched
import arena

fn work(n: int) -> int:
    a : [int; 2], mut
    a[0] = n
    a[1] = 2
    if n > 0:
        b : [int; 2], mut
        b[0] = n + 1
        b[1] = 3
        a = b
    return a[0] + a[1]

fn main() -> int:
    sched_init()
    a := arena_new_sized(65536)
    if arena_current_unchecked() != a:
        return 1
    ch := go work(5)
    r := chan_recv(ch)
    if arena_current_unchecked() != a:
        return 2
    arena_reset(a)
    return r - 9
"""


def run(cmd: list[str], timeout: int = 120) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=BASE, capture_output=True, text=True,
                          timeout=timeout)


def main() -> int:
    if not COREC.exists() or not COREARCH.exists():
        print("FAIL: missing build/corec or build/corearch")
        return 1
    with tempfile.TemporaryDirectory(prefix="go_arena_") as td:
        root = Path(td)
        src = root / "go_arena.cr"
        ccr = root / "go_arena.ccr"
        elf = root / "go_arena"
        src.write_text(SOURCE, encoding="utf-8")
        c = run([str(COREC), "ccr", str(src), "-o", str(ccr)])
        if c.returncode != 0:
            print("FAIL corec ccr")
            print(c.stdout)
            print(c.stderr)
            return 1
        a = run([str(COREARCH), "--raw-int", "--elf", str(ccr),
                 "-o", str(elf)])
        if a.returncode != 0:
            print("FAIL corearch")
            print(a.stdout)
            print(a.stderr)
            return 1
        r = run([str(elf)])
        if r.returncode != 0:
            print(f"FAIL go arena run rc={r.returncode}")
            print(r.stdout)
            print(r.stderr)
            return 1
    print("PASS go arena per-G context switch")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
