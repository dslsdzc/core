#!/usr/bin/env python3
"""Interpreter arena parity: `corec run` versus the native ELF."""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"
SUITE = BASE / "tests" / "suite"

SOURCES = [
    SUITE / "arena_test.cr",
    SUITE / "arena_boundary_test.cr",
    SUITE / "arena_alloc_regress.cr",
    SUITE / "arena_extent_test.cr",
]

FAIL_SOURCES = {
    "static overflow": """\
import arena
g_current_arena : int, mut = -1
g_arena_pool_data : string, mut
g_arena_free_list : int, mut = -1
fn main() -> int:
    arena_init(1048576, 65536)
    a := arena_new_sized(1048576)
    p := alloc(2097152)
    return 0
""",
    "above 1TB": """\
import arena
g_current_arena : int, mut = -1
g_arena_pool_data : string, mut
g_arena_free_list : int, mut = -1
fn main() -> int:
    arena_init(1048576, 65536)
    a := arena_new()
    p := alloc(1099511627777)
    return 0
""",
    "pool limit": """\
import arena
g_current_arena : int, mut = -1
g_arena_pool_data : string, mut
g_arena_free_list : int, mut = -1
g_arena_scalars : string, mut
fn main() -> int:
    arena_init(67108864, 65536)
    a := arena_new()
    cell_store(g_arena_scalars, 32, 64)
    cell_store(g_arena_scalars, 16, 64)
    p := alloc(1048568)
    q := alloc(16)
    return 0
""",
}

NONARENA_SRC = """\
fn main() -> int:
    a := alloc(-1)
    b := alloc(67108865)
    return 0
"""


PARITY_SRC = """\
import arena
g_current_arena : int, mut = -1
g_arena_pool_data : string, mut
g_arena_free_list : int, mut = -1
fn main() -> int:
    arena_init(67108864, 65536)
    a := arena_new()
    p := alloc(2097152)
    if cell_load(p, -8) != 2097152:
        return 1
    cell_store(p, 0, 7)
    if cell_load(p, 0) != 7:
        return 2
    q := alloc(104857600)
    if cell_load(q, -8) != 104857600:
        return 3
    cell_store(q, 0, 8)
    if cell_load(q, 0) != 8:
        return 4
    arena_reset(a)
    return 0
"""


def run(cmd: list[str], timeout: int = 300) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=BASE, capture_output=True, text=True,
                          timeout=timeout)


def main() -> int:
    if not COREC.exists():
        print(f"FAIL: missing {COREC}")
        return 1
    with tempfile.TemporaryDirectory(prefix="arena_interp_") as td:
        root = Path(td)
        for src in SOURCES:
            if not src.exists():
                print(f"FAIL: missing {src}")
                return 1
            text = src.read_text(encoding="utf-8")
            interp = run([str(COREC), "run", text])
            if interp.returncode != 0:
                print(f"FAIL interp {src.name} rc={interp.returncode}")
                print(interp.stdout)
                print(interp.stderr)
                return 1
            elf = root / src.stem
            build = run([str(COREC), "build", str(src), "--static",
                         "-o", str(elf)])
            if build.returncode != 0:
                print(f"FAIL build {src.name}")
                print(build.stdout)
                print(build.stderr)
                return 1
            native = run([str(elf)], timeout=120)
            if native.returncode != 0:
                print(f"FAIL native {src.name} rc={native.returncode}")
                return 1
            print(f"PASS arena interp {src.name}")

        parity = root / "arena_interp_parity.cr"
        parity.write_text(PARITY_SRC, encoding="utf-8")
        interp = run([str(COREC), "run", PARITY_SRC])
        if interp.returncode != 0:
            print(f"FAIL interp 2MB/100MB rc={interp.returncode}")
            print(interp.stdout)
            print(interp.stderr)
            return 1
        elf = root / "arena_interp_parity"
        build = run([str(COREC), "build", str(parity), "--static",
                     "-o", str(elf)])
        if build.returncode != 0:
            print("FAIL build 2MB/100MB")
            print(build.stdout)
            print(build.stderr)
            return 1
        native = run([str(elf)], timeout=120)
        if native.returncode != 0:
            print(f"FAIL native 2MB/100MB rc={native.returncode}")
            return 1
        print("PASS arena interp 2MB/100MB")

        # Non-arena alloc keeps native alloc_simple semantics: negative and
        # above-64MiB requests return 0 instead of aborting.
        non = root / "nonarena_alloc.cr"
        non.write_text(NONARENA_SRC, encoding="utf-8")
        interp = run([str(COREC), "run", NONARENA_SRC])
        if interp.returncode != 0:
            print(f"FAIL interp non-arena alloc rc={interp.returncode}")
            print(interp.stdout)
            print(interp.stderr)
            return 1
        elf = root / "nonarena_alloc"
        build = run([str(COREC), "build", str(non), "--static",
                     "-o", str(elf)])
        if build.returncode != 0:
            print("FAIL build non-arena alloc")
            print(build.stdout)
            print(build.stderr)
            return 1
        native = run([str(elf)], timeout=120)
        if native.returncode != 0:
            print(f"FAIL native non-arena alloc rc={native.returncode}")
            return 1
        print("PASS non-arena alloc parity")

        for idx, (label, source) in enumerate(FAIL_SOURCES.items()):
            r = run([str(COREC), "run", source])
            if r.returncode == 0:
                print(f"FAIL interpreter accepted {label}")
                return 1
            if "arena allocation failed" not in (r.stdout + r.stderr):
                print(f"FAIL {label} produced no interpreter diagnostic")
                print(r.stdout)
                print(r.stderr)
                return 1
            src = root / f"fail_{idx}.cr"
            src.write_text(source, encoding="utf-8")
            elf = root / f"fail_{idx}"
            build = run([str(COREC), "build", str(src), "--static",
                         "-o", str(elf)])
            if build.returncode != 0:
                print(f"FAIL native build {label}")
                print(build.stdout)
                print(build.stderr)
                return 1
            native = run([str(elf)], timeout=120)
            if native.returncode not in (-4, 132):
                print(f"FAIL native {label} rc={native.returncode}")
                return 1
            print(f"PASS arena trap {label} (interp and native)")

    print("PASS arena interpreter parity")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
