#!/usr/bin/env python3
"""Self-hosted BigInt container/call/global gate (--big-int)."""

import subprocess
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"
COREARCH = BASE / "build" / "corearch"

SRC = r"""
struct Pair:
    a: int
    b: int

enum Box:
    Empty
    One(int)
    Two(int, int)

g: int = 1267650600228229401496703205376

fn fact(n: int) -> int:
    if n <= 1:
        return 1
    return n * fact(n - 1)

fn add(a: int, b: int) -> int:
    return a + b

fn main() -> int:
    x := 9223372036854775808
    y := x + 1

    arr : ., mut = [x, y, x + 2]
    i := 1
    if arr[i] != y:
        return 1
    arr[i] = x + 10
    if arr[1] != x + 10:
        return 2
    if arr[0] + arr[i] != 2 * x + 10:
        return 3

    p : ., mut = Pair { a = x, b = y }
    if p.a + p.b != 2 * x + 1:
        return 4
    p.a = x + 3
    if p.a != x + 3:
        return 5

    t := (x, y)
    if t . 0 + t . 1 != 2 * x + 1:
        return 6

    b := Two(x, y)
    v := match b:
        Empty => 0,
        One(q) => q,
        Two(q, r) => q + r,
    if v != 2 * x + 1:
        return 7

    lo := 1
    hi := 3
    s := arr[lo..hi]
    if s[0] != x + 10:
        return 8
    j := 1
    if s[j] != x + 2:
        return 9

    if add(x, y) != 2 * x + 1:
        return 10
    if fact(21) != 51090942171709440000:
        return 11
    if g + 1 != 1267650600228229401496703205377:
        return 12
    return 0
"""

OOB = r"""
fn main() -> int:
    arr := [1, 2, 3]
    i := 3
    return arr[i]
"""


def run(args):
    return subprocess.run(args, cwd=str(BASE), capture_output=True, text=True)


def compile_and_emit(src: Path, ccr: Path, exe: Path, opt: int = 0) -> str:
    r = run([str(COREC), "ccr", str(src), "-o", str(ccr)])
    if r.returncode != 0:
        return r.stdout + r.stderr
    r = run([str(COREARCH), str(ccr), "--big-int", "-O", str(opt), "-o", str(exe)])
    if r.returncode != 0:
        return r.stdout + r.stderr
    return ""


def main() -> int:
    if not COREC.exists() or not COREARCH.exists():
        print("missing build/corec or build/corearch")
        return 1
    with tempfile.TemporaryDirectory(prefix="core-bigint-containers-") as td:
        d = Path(td)
        src = d / "containers.cr"
        ccr = d / "containers.ccr"
        src.write_text(SRC, encoding="utf-8")
        for opt in (0, 2):
            exe = d / f"containers_o{opt}"
            err = compile_and_emit(src, ccr, exe, opt)
            if err:
                print(err)
                return 1
            r = run([str(exe)])
            if r.returncode != 0:
                print(f"containers O{opt} exit {r.returncode}")
                return 1

        osrc = d / "oob.cr"
        occr = d / "oob.ccr"
        oexe = d / "oob"
        osrc.write_text(OOB, encoding="utf-8")
        err = compile_and_emit(osrc, occr, oexe)
        if err:
            print(err)
            return 1
        orc = run([str(oexe)])
        if orc.returncode == 0:
            print("out-of-bounds index unexpectedly succeeded")
            return 1

    print("PASS bigint containers")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
