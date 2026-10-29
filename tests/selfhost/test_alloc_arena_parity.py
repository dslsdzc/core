#!/usr/bin/env python3
"""Arena allocator: legacy hand-written body versus the Core blob body.

The legacy body is the behavioral reference for the class/slot/reset paths.
The independent C/LLVM reference is added by the allocator LLVM parity test.
"""

from __future__ import annotations

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
    // The blob links the new head to the old slot so arena_reset can walk
    // both. The legacy body links the other way and is excluded from this
    // check; the parity test still runs it for the other invariants.
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


def build_and_run(src: Path, root: Path, tag: str, blob: bool):
    ccr = root / f"{tag}.ccr"
    elf = root / tag
    ccr_cmd = [str(COREC), "ccr"]
    if blob:
        ccr_cmd.append("--alloc-blob")
    else:
        ccr_cmd.append("--alloc-legacy")
    ccr_cmd += [str(src), "-o", str(ccr)]
    r = run(ccr_cmd)
    if r.returncode != 0:
        return None, f"corec ccr failed: {r.stdout}\n{r.stderr}"
    arch_cmd = [str(COREARCH), str(ccr), "--static"]
    if blob:
        arch_cmd.append("--alloc-blob")
    else:
        arch_cmd.append("--alloc-legacy")
    arch_cmd += ["-o", str(elf)]
    r = run(arch_cmd)
    if r.returncode != 0:
        return None, f"corearch failed: {r.stdout}\n{r.stderr}"
    r = run([str(elf)], timeout=120)
    return r, None


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="alloc_arena_") as td:
        root = Path(td)
        for src in SOURCES:
            if not src.exists():
                print(f"FAIL: missing {src}")
                return 1
            old, err = build_and_run(src, root, src.stem + "_old", blob=False)
            if err:
                print(f"FAIL legacy {src}: {err}")
                return 1
            new, err = build_and_run(src, root, src.stem + "_new", blob=True)
            if err:
                print(f"FAIL blob {src}: {err}")
                return 1
            if old.returncode != 0:
                print(f"FAIL legacy {src} rc={old.returncode}")
                print(old.stdout)
                return 1
            if new.returncode != 0:
                print(f"FAIL blob {src} rc={new.returncode}")
                print(new.stdout)
                return 1
            if old.stdout != new.stdout:
                print(f"FAIL stdout mismatch {src}")
                print("legacy:", old.stdout)
                print("blob:", new.stdout)
                return 1
            old_elf = root / (src.stem + "_old")
            new_elf = root / (src.stem + "_new")
            if old_elf.stat().st_size == new_elf.stat().st_size:
                print(f"FAIL blob path not selected for {src}")
                return 1
            print(f"PASS arena parity {src.name}")

        for label, source in FAIL_SOURCES:
            src = root / (label.replace(" ", "_") + ".cr")
            src.write_text(source, encoding="utf-8")
            old, err = build_and_run(src, root, label.replace(" ", "_") + "_old",
                                     blob=False)
            if err:
                print(f"FAIL legacy {label}: {err}")
                return 1
            new, err = build_and_run(src, root, label.replace(" ", "_") + "_new",
                                     blob=True)
            if err:
                print(f"FAIL blob {label}: {err}")
                return 1
            if old.returncode not in (-4, 132):
                print(f"FAIL legacy {label} rc={old.returncode}, expected trap")
                return 1
            if new.returncode != 132:
                print(f"FAIL blob {label} rc={new.returncode}, expected 132")
                return 1
            print(f"PASS trap parity {label}")

        chain = root / "arena_chain.cr"
        chain.write_text(CHAIN_SRC, encoding="utf-8")
        r, err = build_and_run(chain, root, "arena_chain", blob=True)
        if err:
            print(f"FAIL blob chain test: {err}")
            return 1
        if r.returncode != 0:
            print(f"FAIL blob chain test rc={r.returncode}")
            print(r.stdout)
            return 1
        print("PASS arena chain reset")

    print("PASS alloc arena parity")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
