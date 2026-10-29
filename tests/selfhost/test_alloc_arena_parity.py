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
]


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
    print("PASS alloc arena parity")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
