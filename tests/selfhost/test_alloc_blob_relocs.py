#!/usr/bin/env python3
"""Allocator blob generator: relocation groups and rejection behavior."""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
GEN = BASE / "tools" / "gen_alloc_blob.py"
BODY = BASE / "src" / "runtime" / "alloc_body.cr"


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
        timeout=300,
    )


def main() -> int:
    if not GEN.exists():
        print(f"FAIL: {GEN} does not exist")
        return 1
    if not BODY.exists():
        print(f"FAIL: {BODY} does not exist")
        return 1

    with tempfile.TemporaryDirectory(prefix="alloc_blob_") as td:
        root = Path(td)
        out = root / "blob.cr"
        summary = root / "summary.json"
        r = run_generator(BODY, out, summary)
        if r.returncode != 0:
            print("FAIL: real body generation failed")
            print(r.stdout)
            print(r.stderr)
            return 1

        data = json.loads(summary.read_text(encoding="utf-8"))
        simple_globals = data.get("simple_globals", [])
        arena_globals = data.get("arena_globals", [])
        simple_calls = data.get("simple_calls", [])
        arena_calls = data.get("arena_calls", [])
        if "g_heap_ptr" not in simple_globals:
            print(f"FAIL: g_heap_ptr missing from simple globals: {simple_globals}")
            return 1
        if "g_heap_ptr" not in arena_globals:
            print(f"FAIL: g_heap_ptr missing from arena globals: {arena_globals}")
            return 1
        if "g_arena_scalars" not in arena_globals:
            print(f"FAIL: g_arena_scalars missing from arena globals: {arena_globals}")
            return 1
        if "g_arena_scalars" in simple_globals:
            print(f"FAIL: arena global in simple group: {simple_globals}")
            return 1
        if "heap_expand" not in simple_calls:
            print(f"FAIL: heap_expand missing from simple calls: {simple_calls}")
            return 1
        if "arena_grow_pool" not in arena_calls:
            print(f"FAIL: arena_grow_pool missing from arena calls: {arena_calls}")
            return 1
        if "arena_grow_pool" in simple_calls:
            print(f"FAIL: arena call in simple group: {simple_calls}")
            return 1
        text = out.read_text(encoding="utf-8")
        if "ALLOC_BLOB_SIZE" not in text:
            print("FAIL: generated file has no ALLOC_BLOB_SIZE")
            return 1

        bad = root / "bad.cr"
        bad.write_text(
            'g_local : int, mut\n'
            'fn alloc_simple(size: int, heap_start: string, heap_end: string) -> string:\n'
            '    return heap_start\n'
            'fn alloc_arena(size: int, heap_start: string, heap_end: string) -> string:\n'
            '    return heap_start\n',
            encoding="utf-8",
        )
        rb = run_generator(bad, root / "bad_blob.cr", root / "bad.json")
        if rb.returncode == 0:
            print("FAIL: local global was accepted")
            return 1
        if "g_local" not in (rb.stdout + rb.stderr):
            print("FAIL: rejection did not name g_local")
            print(rb.stdout)
            print(rb.stderr)
            return 1

        init = root / "init.cr"
        init.write_text(
            'g_heap_ptr : string, mut = "x"\n'
            'fn alloc_simple(size: int, heap_start: string, heap_end: string) -> string:\n'
            '    return heap_start\n'
            'fn alloc_arena(size: int, heap_start: string, heap_end: string) -> string:\n'
            '    return heap_start\n',
            encoding="utf-8",
        )
        ri = run_generator(init, root / "init_blob.cr", root / "init.json")
        if ri.returncode == 0:
            print("FAIL: initialized allocator global was accepted")
            return 1

        rc = subprocess.run(
            [sys.executable, str(GEN), "--check", "--out", str(out)],
            cwd=BASE, capture_output=True, text=True, timeout=300,
        )
        if rc.returncode != 0:
            print("FAIL: --check rejected a freshly generated file")
            print(rc.stdout)
            print(rc.stderr)
            return 1
        out.write_text(text + "\n", encoding="utf-8")
        rc = subprocess.run(
            [sys.executable, str(GEN), "--check", "--out", str(out)],
            cwd=BASE, capture_output=True, text=True, timeout=300,
        )
        if rc.returncode == 0:
            print("FAIL: --check accepted a stale file")
            return 1

    print("PASS alloc blob relocations")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
