#!/usr/bin/env python3
"""Arena allocator suite for the Core blob body.

The independent C reference lives in `test_alloc_arena_llvm.py`. This file
runs the Core programs (lifecycle, boundaries, slot chains, extents, traps).
"""

from __future__ import annotations

import resource
import subprocess
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"
COREARCH = BASE / "build" / "corearch"

SOURCES = [
    BASE / "tests" / "suite" / "arena_test.cr",
    BASE / "tests" / "suite" / "arena_boundary_test.cr",
    BASE / "tests" / "suite" / "arena_alloc_regress.cr",
    BASE / "tests" / "suite" / "arena_extent_test.cr",
]

FAIL_SOURCES = [
    (
        "static overflow",
        "import arena\n"
        "g_current_arena : int, mut = -1\n"
        "g_arena_pool_data : string, mut\n"
        "g_arena_free_list : int, mut = -1\n"
        "fn main() -> int:\n"
        "    arena_init(1048576, 65536)\n"
        "    a := arena_new_sized(1048576)\n"
        "    p := alloc(2097152)\n"
        "    return 0\n",
    ),
    (
        "above 1TB",
        "import arena\n"
        "g_current_arena : int, mut = -1\n"
        "g_arena_pool_data : string, mut\n"
        "g_arena_free_list : int, mut = -1\n"
        "fn main() -> int:\n"
        "    arena_init(1048576, 65536)\n"
        "    a := arena_new()\n"
        "    p := alloc(1099511627777)\n"
        "    return 0\n",
    ),
    (
        "negative size",
        "import arena\n"
        "g_current_arena : int, mut = -1\n"
        "g_arena_pool_data : string, mut\n"
        "g_arena_free_list : int, mut = -1\n"
        "fn main() -> int:\n"
        "    arena_init(1048576, 65536)\n"
        "    a := arena_new()\n"
        "    p := alloc(-1)\n"
        "    return 0\n",
    ),
]

EXTENT_SMALL_SRC = """\
import arena
g_current_arena : int, mut = -1
g_arena_pool_data : string, mut
g_arena_free_list : int, mut = -1
g_arena_large_head : string, mut
g_arena_large_count : string, mut
fn main() -> int:
    arena_init(67108864, 65536)
    a := arena_new()
    p := alloc(2097152)
    if p == 0:
        return 1
    if cell_load(g_arena_large_count, a * 8) != 1:
        return 2
    if cell_load(g_arena_large_head, a * 8) == -1:
        return 3
    cell_store(p, 0, 5)
    cell_store(p, 2097144, 6)
    if cell_load(p, 0) != 5:
        return 4
    if cell_load(p, 2097144) != 6:
        return 5
    // Page-aligned total: aligned(1052648) + 16 = 1052672. The last valid
    // full cell at payload offset size-8 must be mapped.
    q := alloc(1052648)
    if cell_load(q, -8) != 1052648:
        return 6
    cell_store(q, 1052640, 8)
    if cell_load(q, 1052640) != 8:
        return 7
    if cell_load(g_arena_large_count, a * 8) != 2:
        return 8
    arena_reset(a)
    if cell_load(g_arena_large_count, a * 8) != 0:
        return 9
    return 0
"""

CHAIN_SRC = """\
import arena
g_current_arena : int, mut = -1
g_arena_pool_data : string, mut
g_arena_free_list : int, mut = -1
g_arena_slot : string, mut
g_arena_slot_next : string, mut
fn slot_of(ai: int) -> int:
    return cell_load(g_arena_slot, ai * 8)
fn next_of(sl: int) -> int:
    return cell_load(g_arena_slot_next, sl * 8)
fn main() -> int:
    arena_init(67108864, 65536)
    a := arena_new()
    s0 := slot_of(a)
    first := alloc(1044480)
    second := alloc(1048568)
    s1 := slot_of(a)
    if s1 == s0:
        return 1
    if next_of(s1) != s0:
        return 2
    arena_reset(a)
    if g_arena_free_list != s0:
        return 3
    if next_of(s0) != s1:
        return 4
    return 0
"""


def run(cmd: list[str], timeout: int = 300) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=BASE, capture_output=True, text=True,
                          timeout=timeout)


def build_and_run(src: Path, root: Path, tag: str, limit_as: int = 0):
    ccr = root / f"{tag}.ccr"
    elf = root / tag
    r = run([str(COREC), "ccr", str(src), "-o", str(ccr)])
    if r.returncode != 0:
        return None, f"corec ccr failed: {r.stdout}\n{r.stderr}"
    r = run([str(COREARCH), str(ccr), "--static", "-o", str(elf)])
    if r.returncode != 0:
        return None, f"corearch failed: {r.stdout}\n{r.stderr}"
    if limit_as > 0:
        def limit():
            resource.setrlimit(resource.RLIMIT_AS, (limit_as, limit_as))
        r = subprocess.run([str(elf)], cwd=BASE, capture_output=True,
                           text=True, timeout=120, preexec_fn=limit)
    else:
        r = run([str(elf)], timeout=120)
    return r, None


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="alloc_arena_") as td:
        root = Path(td)
        for src in SOURCES:
            if not src.exists():
                print(f"FAIL: missing {src}")
                return 1
            r, err = build_and_run(src, root, src.stem)
            if err:
                print(f"FAIL {src}: {err}")
                return 1
            if r.returncode != 0:
                print(f"FAIL {src} rc={r.returncode}")
                print(r.stdout)
                return 1
            print(f"PASS arena {src.name}")

        for label, source in FAIL_SOURCES:
            tag = label.replace(" ", "_")
            src = root / (tag + ".cr")
            src.write_text(source, encoding="utf-8")
            r, err = build_and_run(src, root, tag)
            if err:
                print(f"FAIL {label}: {err}")
                return 1
            if r.returncode != 132:
                print(f"FAIL {label} rc={r.returncode}, expected 132")
                return 1
            print(f"PASS trap {label}")

        chain = root / "arena_chain.cr"
        chain.write_text(CHAIN_SRC, encoding="utf-8")
        r, err = build_and_run(chain, root, "arena_chain")
        if err:
            print(f"FAIL chain test: {err}")
            return 1
        if r.returncode != 0:
            print(f"FAIL chain test rc={r.returncode}")
            print(r.stdout)
            return 1
        print("PASS arena chain reset")

        extent = root / "arena_extent_small.cr"
        extent.write_text(EXTENT_SMALL_SRC, encoding="utf-8")
        r, err = build_and_run(extent, root, "arena_extent_small")
        if err:
            print(f"FAIL blob 2MB extent: {err}")
            return 1
        if r.returncode != 0:
            print(f"FAIL blob 2MB extent rc={r.returncode}")
            print(r.stdout)
            return 1
        print("PASS arena 2MB extent")

        # mmap failure path: the ELF's 1GiB data segment needs more than
        # 1.5GiB of address space, but a 512MiB extent cannot fit under the
        # limit. The allocator traps with class -2 in the witness.
        huge = root / "arena_mmap_fail.cr"
        huge.write_text(
            "import arena\n"
            "g_current_arena : int, mut = -1\n"
            "g_arena_pool_data : string, mut\n"
            "g_arena_free_list : int, mut = -1\n"
            "fn main() -> int:\n"
            "    arena_init(67108864, 65536)\n"
            "    a := arena_new()\n"
            "    p := alloc(536870912)\n"
            "    return 0\n",
            encoding="utf-8",
        )
        r, err = build_and_run(huge, root, "mmap_fail",
                               limit_as=1536 * 1024 * 1024)
        if err:
            print(f"FAIL mmap failure: {err}")
            return 1
        if r.returncode != 132:
            print(f"FAIL mmap failure rc={r.returncode}")
            return 1
        print("PASS arena mmap failure trap")

    print("PASS alloc arena")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
