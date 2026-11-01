#!/usr/bin/env python3
"""0A Task 1: per-thread TLS state and atomic runtime primitives."""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"
COREARCH = BASE / "build" / "corearch"

SOURCE = """\
import arena

g_test_cell : string, mut

fn main() -> int:
    g_test_cell = alloc(8)
    if rt_m_idx() != 0:
        return 1
    rt_atomic_store(g_test_cell, 0, 7)
    if rt_atomic_load(g_test_cell, 0) != 7:
        return 2
    if rt_atomic_xchg(g_test_cell, 0, 9) != 7:
        return 3
    if rt_atomic_load(g_test_cell, 0) != 9:
        return 4
    if rt_atomic_cas(g_test_cell, 0, 9, 11) != 1:
        return 5
    if rt_atomic_load(g_test_cell, 0) != 11:
        return 6
    if rt_atomic_fetch_add(g_test_cell, 0, 5) != 11:
        return 7
    if rt_atomic_load(g_test_cell, 0) != 16:
        return 8
    arena_init(1073741824, 1048576)
    a := arena_new_sized(65536)
    if arena_current_unchecked() != a:
        return 9
    arena_reset(a)
    return 0
"""


def run(cmd: list[str], timeout: int = 120) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=BASE, capture_output=True, text=True,
                          timeout=timeout)


def main() -> int:
    if not COREC.exists() or not COREARCH.exists():
        print("FAIL: missing build/corec or build/corearch")
        return 1
    with tempfile.TemporaryDirectory(prefix="rt_tls_") as td:
        root = Path(td)
        src = root / "rt_tls.cr"
        ccr = root / "rt_tls.ccr"
        elf = root / "rt_tls"
        src.write_text(SOURCE, encoding="utf-8")
        c = run([str(COREC), "ccr", str(src), "-o", str(ccr)])
        if c.returncode != 0:
            print("FAIL corec ccr")
            print(c.stdout[-2000:])
            print(c.stderr[-2000:])
            return 1
        a = run([str(COREARCH), "--raw-int", "--elf", str(ccr),
                 "-o", str(elf)])
        if a.returncode != 0:
            print("FAIL corearch")
            print(a.stdout[-2000:])
            print(a.stderr[-2000:])
            return 1
        r = run([str(elf)], timeout=60)
        if r.returncode != 0:
            print(f"FAIL rt tls run rc={r.returncode}")
            print(r.stdout[-2000:])
            print(r.stderr[-2000:])
            return 1
    print("PASS rt tls")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
