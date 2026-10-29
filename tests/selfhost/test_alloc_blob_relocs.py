#!/usr/bin/env python3
"""Allocator blob generator: external global and call relocation metadata."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
GEN = BASE / "tools" / "gen_alloc_blob.py"


def run_generator(source: Path, out: Path, summary: Path) -> subprocess.CompletedProcess:
    return subprocess.run(
        [
            sys.executable,
            str(GEN),
            "--source",
            str(source),
            "--out",
            str(out),
            "--summary-json",
            str(summary),
        ],
        cwd=BASE,
        capture_output=True,
        text=True,
        timeout=180,
    )


def main() -> int:
    if not GEN.exists():
        print(f"FAIL: {GEN} does not exist")
        return 1

    with tempfile.TemporaryDirectory(prefix="alloc_blob_") as td:
        root = Path(td)
        probe = root / "probe.cr"
        probe.write_text(
            'g_heap_ptr : string, mut\n'
            'fn probe(x: int) -> int:\n'
            '    g_heap_ptr = ""\n'
            '    return heap_expand()\n',
            encoding="utf-8",
        )
        out = root / "probe_blob.cr"
        summary = root / "probe.json"
        r = run_generator(probe, out, summary)
        if r.returncode != 0:
            print("FAIL: probe generation failed")
            print(r.stdout)
            print(r.stderr)
            return 1

        data = json.loads(summary.read_text(encoding="utf-8"))
        globals_ = data.get("globals", [])
        calls = data.get("calls", [])
        if "g_heap_ptr" not in globals_:
            print(f"FAIL: g_heap_ptr missing from globals: {globals_}")
            return 1
        if "heap_expand" not in calls:
            print(f"FAIL: heap_expand missing from calls: {calls}")
            return 1
        text = out.read_text(encoding="utf-8")
        if "ALLOC_BLOB_SIZE" not in text:
            print("FAIL: generated file has no ALLOC_BLOB_SIZE")
            return 1

        bad = root / "bad.cr"
        bad.write_text(
            'g_local : int, mut\n'
            'fn probe() -> int:\n'
            '    return 0\n',
            encoding="utf-8",
        )
        bad_out = root / "bad_blob.cr"
        bad_summary = root / "bad.json"
        rb = run_generator(bad, bad_out, bad_summary)
        if rb.returncode == 0:
            print("FAIL: local .bss global was accepted")
            return 1
        if "g_local" not in (rb.stdout + rb.stderr):
            print("FAIL: rejection did not name g_local")
            print(rb.stdout)
            print(rb.stderr)
            return 1

    print("PASS alloc blob relocations")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
