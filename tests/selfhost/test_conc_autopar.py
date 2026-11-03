#!/usr/bin/env python3
"""CP-6: automatic DATA_PARALLEL for pure arithmetic for-loops."""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"
COREARCH = BASE / "build" / "corearch"

AUTO_PAR = """\
import sched
import chan

fn square(x: int) -> int:
    return x * x

fn main() -> int:
    sched_init()
    arr := alloc(4 * 8)
    for i in 0..4:
        arr[i] = square(i)
    if arr[0] + arr[1] + arr[2] + arr[3] != 14:
        return 1
    return 0
"""

AUTO_REVERSE = """\
import sched
import chan

fn square(x: int) -> int:
    return x * x

fn main() -> int:
    sched_init()
    arr := alloc(4 * 8)
    for i in 0..4:
        arr[3 - i] = square(i)
    if arr[0] + arr[1] + arr[2] + arr[3] != 14:
        return 1
    if arr[0] != 9 || arr[3] != 0:
        return 2
    return 0
"""

AUTO_REDUCTION = """\
import sched
import chan

fn square(x: int) -> int:
    return x * x

fn main() -> int:
    sched_init()
    sum : ., mut = 0
    for i in 0..100:
        sum = sum + square(i)
    if sum != 328350:
        return sum
    return 0
"""

REDUCTION_FALLBACK = """\
import sched
import chan

fn helper(x: int) -> int:
    y := str_len("abcd")
    return x + y

fn main() -> int:
    sched_init()
    sum : ., mut = 0
    for i in 0..10:
        sum = sum + helper(i)
    if sum != 85:
        return sum
    return 0
"""

SERIAL_FALLBACK = """\
import sched
import chan

fn helper(x: int) -> int:
    y := str_len("abcd")
    return x + y

fn main() -> int:
    sched_init()
    arr := alloc(4 * 8)
    for i in 0..4:
        arr[i] = helper(i)
    if arr[0] + arr[1] + arr[2] + arr[3] != 22:
        return 1
    return 0
"""


def run(cmd: list[str], timeout: int = 300) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=BASE, capture_output=True, text=True,
                          timeout=timeout)


def build_run(name: str, source: str, expect: int = 0) -> bool:
    with tempfile.TemporaryDirectory(prefix=f"{name}_") as td:
        root = Path(td)
        src = root / f"{name}.cr"
        ccr = root / f"{name}.ccr"
        elf = root / f"{name}.elf"
        src.write_text(source, encoding="utf-8")
        c = run([str(COREC), "ccr", str(src), "-o", str(ccr)])
        if c.returncode != 0:
            print(f"FAIL {name} corec")
            print(c.stdout[-1600:])
            print(c.stderr[-1600:])
            return False
        a = run([str(COREARCH), "--raw-int", "--elf", str(ccr), "-o", str(elf)])
        if a.returncode != 0:
            print(f"FAIL {name} corearch")
            print(a.stdout[-1600:])
            print(a.stderr[-1600:])
            return False
        r = run([str(elf)], timeout=60)
        if r.returncode != expect:
            print(f"FAIL {name} run rc={r.returncode}, expected {expect}")
            print(r.stdout[-1600:])
            print(r.stderr[-1600:])
            return False
    print(f"PASS {name}")
    return True


def ir_conc_go_count(source: str, name: str) -> int:
    """Count conc_go calls inside the dump's `Function: main` region."""
    with tempfile.TemporaryDirectory(prefix=f"{name}_ir_") as td:
        root = Path(td)
        src = root / f"{name}.cr"
        ccr = root / f"{name}.ccr"
        src.write_text(source, encoding="utf-8")
        r = run([str(COREC), "ccr", str(src), "-o", str(ccr),
                 "--dump-ir-text"])
        text = r.stdout + r.stderr
        start = text.find("Function: main")
        if start < 0:
            return -1
        end = text.find("Function:", start + 1)
        if end < 0:
            end = len(text)
        return text[start:end].count("conc_go")


def main() -> int:
    ok = build_run("autopar_pure_arithmetic", AUTO_PAR, 0)
    ok = build_run("autopar_reverse", AUTO_REVERSE, 0) and ok
    ok = build_run("autopar_reduction", AUTO_REDUCTION, 0) and ok
    ok = build_run("autopar_reduction_fallback", REDUCTION_FALLBACK, 0) and ok
    ok = build_run("autopar_serial_fallback", SERIAL_FALLBACK, 0) and ok
    n = ir_conc_go_count(AUTO_PAR, "autopar_pure")
    rn = ir_conc_go_count(AUTO_REDUCTION, "autopar_reduction")
    rvn = ir_conc_go_count(AUTO_REVERSE, "autopar_reverse")
    m = ir_conc_go_count(SERIAL_FALLBACK, "autopar_serial")
    if n < 1:
        print(f"FAIL auto_par_ir: main conc_go count={n}, expected >=1")
        ok = False
    else:
        print(f"PASS auto_par_ir (main conc_go={n})")
    if rvn < 1:
        print(f"FAIL reverse_ir: main conc_go count={rvn}, expected >=1")
        ok = False
    else:
        print(f"PASS reverse_ir (main conc_go={rvn})")
    if rn < 1:
        print(f"FAIL reduction_ir: main conc_go count={rn}, expected >=1")
        ok = False
    else:
        print(f"PASS reduction_ir (main conc_go={rn})")
    if m != 0:
        print(f"FAIL serial_fallback_ir: main conc_go count={m}, expected 0")
        ok = False
    else:
        print("PASS serial_fallback_ir (no conc_go in main)")
    total = 9
    print(f"{total if ok else 0}/{total} passed")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
