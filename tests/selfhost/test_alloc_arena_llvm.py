#!/usr/bin/env python3
"""Arena class/slot allocator: independent C reference parity."""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
GEN = BASE / "tools" / "gen_alloc_blob.py"
BODY = BASE / "src" / "runtime" / "alloc_body.cr"
REF = BASE / "tests" / "harness" / "alloc_arena_ref.c"


def run(cmd: list[str], timeout: int = 300) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=BASE, capture_output=True, text=True,
                          timeout=timeout)


def main() -> int:
    if shutil.which("clang") is None:
        print("SKIP arena C model: clang not installed")
        return 0
    for path in (GEN, BODY, REF):
        if not path.exists():
            print(f"FAIL: missing {path}")
            return 1

    with tempfile.TemporaryDirectory(prefix="arena_llvm_") as td:
        root = Path(td)
        blob = root / "alloc_blob.cr"
        r = run([sys.executable, str(GEN), "--source", str(BODY),
                 "--out", str(blob)])
        if r.returncode != 0:
            print("FAIL: generator")
            print(r.stdout)
            print(r.stderr)
            return 1
        obj = BASE / "build" / "alloc_blob" / "alloc_body.o"
        harness = root / "arena_ref"
        r = run(["clang", "-O2", "-no-pie", "-o", str(harness),
                 str(REF), str(obj)])
        if r.returncode != 0:
            print("FAIL: clang link")
            print(r.stdout)
            print(r.stderr)
            return 1
        r = run([str(harness)], timeout=120)
        sys.stdout.write(r.stdout)
        sys.stderr.write(r.stderr)
        if r.returncode != 0:
            print(f"FAIL: C model rc={r.returncode}")
            return 1

    print("PASS arena C model")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
