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
    "arena before new": """\
import arena
g_current_arena : int, mut = -1
g_arena_pool_data : string, mut
g_arena_free_list : int, mut = -1
fn main() -> int:
    a := alloc(67108865)
    pa : ., mut = 0
    unsafe:
        pa = @ptr_of(a)
    if pa == 0:
        return 1
    b := alloc(-1)
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
    pa : ., mut = 0
    pb : ., mut = 0
    unsafe:
        pa = @ptr_of(a)
        pb = @ptr_of(b)
    if pa != 0:
        return 1
    if pb != 0:
        return 2
    return 0
"""


ZERO_SRC = """\
import arena
g_current_arena : int, mut = -1
g_arena_pool_data : string, mut
g_arena_free_list : int, mut = -1

fn check_zero(p: string, n: int) -> int:
    i : ., mut = 0
    loop:
        if i >= n:
            break
        if cell_load(p, i) != 0:
            return 1
        i = i + 8
    return 0

fn main() -> int:
    arena_init(67108864, 65536)
    a := arena_new()
    if a < 0:
        return 10
    big := alloc(1048568)
    if check_zero(big, 1048568) != 0:
        return 11
    cell_store(big, 0, 123)
    cell_store(big, 1048568 - 8, 456)
    small := alloc(64)
    if check_zero(small, 64) != 0:
        return 12
    cell_store(small, 0, 789)
    arena_reset(a)
    b := arena_new()
    if b != a:
        return 13
    big2 := alloc(1048568)
    if check_zero(big2, 1048568) != 0:
        return 14
    small2 := alloc(64)
    if check_zero(small2, 64) != 0:
        return 15
    arena_reset(b)
    return 0
"""

ARENA_RAW_CURRENT_SRC = """\
import arena
fn main() -> int:
    arena_init(67108864, 1048576)
    a := arena_current_unchecked()
    if a != -1:
        return 1
    b := arena_new_sized(65536)
    c := arena_current_unchecked()
    if c != b:
        return 2
    arena_set_current_unchecked(-1)
    d := arena_current_unchecked()
    if d != -1:
        return 3
    return 0
"""

ZERO_ON_RESET_SRC = """\
import arena
g_current_arena : int, mut = -1
g_arena_pool_data : string, mut
g_arena_free_list : int, mut = -1
fn main() -> int:
    arena_init(67108864, 65536)
    a := arena_new_sized(65536)
    p := alloc(65528)
    cell_store(p, 0, 123)
    cell_store(p, 65520, 456)
    arena_set_zero_on_reset(1)
    arena_reset(a)
    if cell_load(p, 0) != 0:
        return 1
    if cell_load(p, 65520) != 0:
        return 2
    return 0
"""

ZERO_RESET_OFF_SRC = """\
import arena
g_current_arena : int, mut = -1
g_arena_pool_data : string, mut
g_arena_free_list : int, mut = -1
fn main() -> int:
    arena_init(67108864, 65536)
    a := arena_new_sized(65536)
    p := alloc(65528)
    cell_store(p, 0, 123)
    cell_store(p, 65520, 456)
    arena_reset(a)
    if cell_load(p, 0) != 123:
        return 1
    if cell_load(p, 65520) != 456:
        return 2
    return 0
"""

ZERO_RESET_FLAG_SRC = """\
import arena
g_current_arena : int, mut = -1
g_arena_pool_data : string, mut
g_arena_free_list : int, mut = -1
fn main() -> int:
    arena_init(67108864, 65536)
    a := arena_new_sized(65536)
    p := alloc(65528)
    cell_store(p, 0, 123)
    cell_store(p, 65520, 456)
    arena_reset(a)
    if cell_load(p, 0) != 0:
        return 1
    if cell_load(p, 65520) != 0:
        return 2
    return 0
"""

PERF_SRC = """\
import arena
g_current_arena : int, mut = -1
g_arena_pool_data : string, mut
g_arena_free_list : int, mut = -1
fn main() -> int:
    arena_init(67108864, 65536)
    a := arena_new()
    i : ., mut = 0
    loop:
        if i >= 32:
            break
        p := alloc(1048568)
        if p == 0:
            return 1
        i = i + 1
    arena_reset(a)
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


def run_pair(root: Path, name: str, source: str, *,
             interp_timeout: int = 300, native_timeout: int = 120,
             corec_flags: list[str] | None = None) -> int:
    """Run one source under corec run and as a static ELF. Returns 0 on pass."""
    flags = corec_flags or []
    interp = run([str(COREC), "run", *flags, source], timeout=interp_timeout)
    if interp.returncode != 0:
        print(f"FAIL interp {name} rc={interp.returncode}")
        print(interp.stdout)
        print(interp.stderr)
        return 1
    src = root / f"{name}.cr"
    src.write_text(source, encoding="utf-8")
    elf = root / name
    build = run([str(COREC), "build", str(src), "--static", *flags, "-o", str(elf)])
    if build.returncode != 0:
        print(f"FAIL build {name}")
        print(build.stdout)
        print(build.stderr)
        return 1
    native = run([str(elf)], timeout=native_timeout)
    if native.returncode != 0:
        print(f"FAIL native {name} rc={native.returncode}")
        return 1
    print(f"PASS {name} (interp and native)")
    return 0


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

        # Allocated cells are zero, including after reset reuses the slot.
        if run_pair(root, "arena_zero_reuse", ZERO_SRC) != 0:
            return 1

        # 32 x 1MiB used to spend minutes in the interpreted per-cell zeroing
        # loop. The 30s cap leaves a wide margin for slower CI hosts while
        # still failing if the interpreter goes back to zeroing per node.
        if run_pair(root, "arena_bulk_zero", PERF_SRC,
                    interp_timeout=30) != 0:
            return 1

        if run_pair(root, "arena_raw_current", ARENA_RAW_CURRENT_SRC) != 0:
            return 1

        if run_pair(root, "arena_zero_on_reset", ZERO_ON_RESET_SRC) != 0:
            return 1
        if run_pair(root, "arena_zero_reset_off", ZERO_RESET_OFF_SRC) != 0:
            return 1
        if run_pair(root, "arena_zero_reset_flag", ZERO_RESET_FLAG_SRC,
                    corec_flags=["--arena-zero-on-reset"]) != 0:
            return 1

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
