#!/usr/bin/env python3
"""ELF smoke test for --alloc-blob on a program without arena."""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"
COREARCH = BASE / "build" / "corearch"

SRC = """
fn main() -> int:
    p := alloc(16)
    cell_store(p, 0, 7)
    if cell_load(p, 0) != 7:
        return 1
    if cell_load(p, -8) != 16:
        return 2
    q := alloc(64)
    cell_store(q, 63, 9)
    if cell_load(q, 63) != 9:
        return 3
    if cell_load(q, -8) != 64:
        return 4
    return 0
"""


def run(cmd: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=BASE, capture_output=True, text=True,
                          timeout=300)


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="alloc_elf_") as td:
        root = Path(td)
        src = root / "alloc_elf.cr"
        ccr = root / "alloc_elf.ccr"
        old = root / "alloc_old"
        new = root / "alloc_new"
        src.write_text(SRC, encoding="utf-8")

        r = run([str(COREC), "ccr", "--alloc-blob", str(src), "-o", str(ccr)])
        if r.returncode != 0:
            print("FAIL: corec ccr")
            print(r.stdout)
            print(r.stderr)
            return 1

        r = run([str(COREARCH), str(ccr), "--static", "--raw-int",
                 "--alloc-legacy", "-o", str(old)])
        if r.returncode != 0:
            print("FAIL: legacy corearch")
            print(r.stdout)
            print(r.stderr)
            return 1
        ro = run([str(old)])
        if ro.returncode != 0:
            print(f"FAIL: legacy ELF rc={ro.returncode}")
            return 1

        r = run([str(COREARCH), str(ccr), "--static", "--raw-int",
                 "--alloc-blob", "-o", str(new)])
        if r.returncode != 0:
            print("FAIL: --alloc-blob corearch")
            print(r.stdout)
            print(r.stderr)
            return 1
        rn = run([str(new)])
        if rn.returncode != 0:
            print(f"FAIL: blob ELF rc={rn.returncode}")
            return 1

        if old.stat().st_size == new.stat().st_size:
            print("FAIL: allocator blob did not change the ELF size")
            return 1

        built = root / "alloc_built"
        r = run([str(COREC), "build", "--alloc-blob", str(src),
                 "--static", "-o", str(built)])
        if r.returncode != 0:
            print("FAIL: corec build --alloc-blob")
            print(r.stdout)
            print(r.stderr)
            return 1
        rb = run([str(built)])
        if rb.returncode != 0:
            print(f"FAIL: corec-built blob ELF rc={rb.returncode}")
            return 1

    print("PASS alloc simple ELF")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
