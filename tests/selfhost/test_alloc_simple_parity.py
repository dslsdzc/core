#!/usr/bin/env python3
"""Simple allocator: Core blob versus a clang-compiled reference."""

from __future__ import annotations

import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
GEN = BASE / "tools" / "gen_alloc_blob.py"
BODY = BASE / "src" / "runtime" / "alloc_body.cr"
STATE = BASE / "tests" / "harness" / "alloc_state.c"
REF = BASE / "tests" / "harness" / "alloc_simple_ref.c"
CLANG = "clang"


def main() -> int:
    for path in (GEN, BODY, STATE, REF):
        if not path.exists():
            print(f"FAIL: missing {path}")
            return 1

    with tempfile.TemporaryDirectory(prefix="alloc_simple_") as td:
        root = Path(td)
        blob = root / "alloc_blob.cr"
        summary = root / "summary.json"
        r = subprocess.run(
            [
                sys.executable,
                str(GEN),
                "--source",
                str(BODY),
                "--out",
                str(blob),
                "--summary-json",
                str(summary),
            ],
            cwd=BASE,
            capture_output=True,
            text=True,
            timeout=300,
        )
        if r.returncode != 0:
            print("FAIL: generator")
            print(r.stdout)
            print(r.stderr)
            return 1
        data = json.loads(summary.read_text(encoding="utf-8"))
        if data.get("simple_off", -1) < 0:
            print(f"FAIL: no alloc_simple offset: {data}")
            return 1
        if data.get("arena_off", -1) != -1:
            print(f"FAIL: arena body unexpectedly present: {data}")
            return 1

        asm = BASE / "build" / "alloc_blob" / "alloc_body.s"
        asm_text = asm.read_text(encoding="utf-8")
        if re.search(r"\bcall\s+alloc\b", asm_text):
            print("FAIL: allocator body calls alloc")
            return 1

        obj = BASE / "build" / "alloc_blob" / "alloc_body.o"
        harness = root / "alloc_simple_harness"
        cc = subprocess.run(
            [
                CLANG,
                "-O2",
                "-no-pie",
                "-o",
                str(harness),
                str(STATE),
                str(REF),
                str(obj),
            ],
            cwd=BASE,
            capture_output=True,
            text=True,
            timeout=300,
        )
        if cc.returncode != 0:
            print("FAIL: clang link")
            print(cc.stdout)
            print(cc.stderr)
            return 1

        run = subprocess.run([str(harness)], cwd=BASE, capture_output=True,
                             text=True, timeout=120)
        sys.stdout.write(run.stdout)
        sys.stderr.write(run.stderr)
        if run.returncode != 0:
            print(f"FAIL: harness rc={run.returncode}")
            return 1

    print("PASS alloc simple parity")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
