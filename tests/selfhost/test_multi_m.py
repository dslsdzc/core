#!/usr/bin/env python3
"""0A: multi-M runtime tests. Extended in Task 5; starts with arena partition."""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"
COREARCH = BASE / "build" / "corearch"

ARENA_STRESS = """\
import arena

fn main() -> int:
    arena_init_m(1073741824, 1048576, 2)
    i : ., mut = 0
    loop:
        if i >= 2000:
            break
        aid := arena_new_sized(65536)
        if aid < 0:
            return 1
        p := alloc(2048)
        if p < 0:
            return 2
        arena_reset(aid)
        i = i + 1
    return 0
"""


def run(cmd: list[str], timeout: int = 120) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=BASE, capture_output=True, text=True,
                          timeout=timeout)


def build_run(name: str, source: str, timeout: int = 60) -> bool:
    if not COREC.exists() or not COREARCH.exists():
        print("FAIL: missing build/corec or build/corearch")
        return False
    with tempfile.TemporaryDirectory(prefix=f"{name}_") as td:
        root = Path(td)
        src = root / f"{name}.cr"
        ccr = root / f"{name}.ccr"
        elf = root / f"{name}.elf"
        src.write_text(source, encoding="utf-8")
        c = run([str(COREC), "ccr", str(src), "-o", str(ccr)])
        if c.returncode != 0:
            print(f"FAIL {name} corec")
            print(c.stdout[-1200:])
            print(c.stderr[-1200:])
            return False
        a = run([str(COREARCH), "--raw-int", "--elf", str(ccr), "-o", str(elf)])
        if a.returncode != 0:
            print(f"FAIL {name} corearch")
            print(a.stdout[-1200:])
            print(a.stderr[-1200:])
            return False
        r = run([str(elf)], timeout=timeout)
        if r.returncode != 0:
            print(f"FAIL {name} run rc={r.returncode}")
            print(r.stdout[-1200:])
            print(r.stderr[-1200:])
            return False
    print(f"PASS {name}")
    return True


def main() -> int:
    ok = True
    ok = build_run("arena_partition_stress", ARENA_STRESS) and ok
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
