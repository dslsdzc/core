#!/usr/bin/env python3
"""Interpreter/ELF parity gate for tagged BigInt values."""

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

fn main() -> int:
    x := 1267650600228229401496703205376
    y := x + 123
    if y != 1267650600228229401496703205499:
        return 1
    if x * 3 != 3802951800684688204490109616128:
        return 2
    if x / 3 != 422550200076076467165567735125:
        return 3
    if x % 3 != 1:
        return 4
    if -x != -1267650600228229401496703205376:
        return 5

    arr : ., mut = [x, y, x + 2]
    i := 1
    if arr[i] != y:
        return 6
    arr[i] = x + 10
    if arr[1] != x + 10:
        return 7

    p : ., mut = Pair { a = x, b = y }
    if p.a + p.b != x + y:
        return 8

    b := Two(x, y)
    v := match b:
        Empty => 0,
        One(q) => q,
        Two(q, r) => q + r,
    if v != x + y:
        return 9

    s := "hello"
    if str_len(s) != 5:
        return 10
    if s[1] != 101:
        return 11

    f := &arr[1]
    if *(f + 1) != x + 2:
        return 12
    if (f + 1) - f != 1:
        return 13

    if fact(21) != 51090942171709440000:
        return 14
    if g + 1 != 1267650600228229401496703205377:
        return 15

    lo := 1
    hi := 3
    sl := arr[lo..hi]
    if sl[0] != x + 10:
        return 16
    return 0
"""

DIV_ZERO = r"""
fn main() -> int:
    x := 9223372036854775808
    return x / 0
"""


def run(args):
    return subprocess.run(args, cwd=str(BASE), capture_output=True, text=True)


def build_elf(src: Path, ccr: Path, exe: Path) -> str:
    r = run([str(COREC), "ccr", str(src), "-o", str(ccr)])
    if r.returncode != 0:
        return r.stdout + r.stderr
    r = run([str(COREARCH), str(ccr), "--big-int", "-o", str(exe)])
    if r.returncode != 0:
        return r.stdout + r.stderr
    return ""


def main() -> int:
    if not COREC.exists() or not COREARCH.exists():
        print("missing build/corec or build/corearch")
        return 1
    with tempfile.TemporaryDirectory(prefix="core-bigint-interp-") as td:
        d = Path(td)
        src = d / "parity.cr"
        ccr = d / "parity.ccr"
        exe = d / "parity"
        src.write_text(SRC, encoding="utf-8")
        err = build_elf(src, ccr, exe)
        if err:
            print(err)
            return 1
        elf = run([str(exe)])
        interp = run([str(COREC), "run", SRC])
        if elf.returncode != 0:
            print(f"ELF parity exit {elf.returncode}")
            return 1
        if interp.returncode != elf.returncode:
            print(f"interpreter {interp.returncode} != ELF {elf.returncode}")
            print(interp.stdout)
            print(interp.stderr)
            return 1

        zsrc = d / "zero.cr"
        zccr = d / "zero.ccr"
        zexe = d / "zero"
        zsrc.write_text(DIV_ZERO, encoding="utf-8")
        err = build_elf(zsrc, zccr, zexe)
        if err:
            print(err)
            return 1
        ze = run([str(zexe)])
        zi = run([str(COREC), "run", DIV_ZERO])
        if ze.returncode == 0 or zi.returncode == 0:
            print("division by zero did not fail on both faces")
            return 1
        if "division by zero" not in (ze.stdout + ze.stderr):
            print("ELF missing division-by-zero text")
            return 1
        if "division by zero" not in (zi.stdout + zi.stderr):
            print("interpreter missing division-by-zero text")
            return 1

    print("PASS bigint interp")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
