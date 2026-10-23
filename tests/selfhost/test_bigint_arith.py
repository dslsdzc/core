#!/usr/bin/env python3
"""Self-hosted backend BigInt arithmetic gate (--big-int)."""

import subprocess
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"
COREARCH = BASE / "build" / "corearch"

ARITH = r"""
g: int = 9223372036854775808

fn bump(v: int) -> int:
    return v + 1

fn main() -> int:
    // small fast path and a loop
    total := 0
    i := 0
    loop:
        if i >= 100:
            break
        total = total + i
        i = i + 1
    if total != 4950:
        return 1

    // immediate boundaries
    a := 4611686018427387903
    if a + 1 != 4611686018427387904:
        return 2
    if a + 2 != 4611686018427387905:
        return 3
    c := -4611686018427387904
    if c - 1 != -4611686018427387905:
        return 4
    if -c != 4611686018427387904:
        return 5
    if c * -1 != 4611686018427387904:
        return 6

    // 2^100 arithmetic
    x := 1267650600228229401496703205376
    y := x + 123
    if y != 1267650600228229401496703205499:
        return 7
    if y - x != 123:
        return 8
    if x * 3 != 3802951800684688204490109616128:
        return 9
    if x / 3 != 422550200076076467165567735125:
        return 10
    if x % 3 != 1:
        return 11

    // truncation toward zero and remainder sign follows dividend
    nx := -x
    if nx / 3 != -422550200076076467165567735125:
        return 12
    if nx % 3 != -1:
        return 13
    if !(nx < x):
        return 14
    if !(x < y):
        return 15
    if nx > 0:
        return 16
    if -nx != x:
        return 17

    // decimal/hex/octal/binary literals
    h := 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF
    if h != 340282366920938463463374607431768211455:
        return 18
    o := 0o400000000000000000000000000000000
    if o != 316912650057057350374175801344:
        return 19
    b := 0b10000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
    if b != 1267650600228229401496703205376:
        return 20

    // calls, parameters, returns, and a big global initializer
    if bump(x) != 1267650600228229401496703205377:
        return 21
    if g + 2 != 9223372036854775810:
        return 22

    return 0
"""

SMALL = r"""
fn main() -> int:
    a := 7
    b := 5
    if a + b != 12:
        return 1
    if a - b != 2:
        return 2
    if a * b != 35:
        return 3
    if a / b != 1:
        return 4
    if a % b != 2:
        return 5
    if !(b < a):
        return 6
    return 0
"""


def run(args):
    return subprocess.run(args, cwd=str(BASE), capture_output=True, text=True)


def build(src: Path, ccr: Path) -> str:
    r = run([str(COREC), "ccr", str(src), "-o", str(ccr)])
    if r.returncode != 0:
        return (r.stdout + r.stderr).strip()
    return ""


def emit(ccr: Path, out: Path, big: bool) -> str:
    args = [str(COREARCH), str(ccr), "-o", str(out)]
    if big:
        args.append("--big-int")
    r = run(args)
    if r.returncode != 0:
        return (r.stdout + r.stderr).strip()
    return ""


def main() -> int:
    if not COREC.exists() or not COREARCH.exists():
        print("missing build/corec or build/corearch")
        return 1
    with tempfile.TemporaryDirectory(prefix="core-bigint-arith-") as td:
        d = Path(td)
        src = d / "arith.cr"
        ccr = d / "arith.ccr"
        exe = d / "arith"
        src.write_text(ARITH, encoding="utf-8")
        err = build(src, ccr)
        if err:
            print("frontend failed:\n" + err)
            return 1
        err = emit(ccr, exe, True)
        if err:
            print("backend failed:\n" + err)
            return 1
        r = run([str(exe)])
        if r.returncode != 0:
            print(f"bigint arithmetic exit {r.returncode}")
            return 1

        # Divide-by-zero and an out-of-word main return must reach the shared
        # runtime error path rather than silently producing a tagged pointer.
        for name, source, needle in (
            ("zero", "fn main() -> int:\n    x := 9223372036854775808\n    y := x / 0\n    return 0\n",
             "division by zero"),
            ("word", "fn main() -> int:\n    return 1267650600228229401496703205376\n",
             "machine-word range"),
        ):
            zsrc = d / f"{name}.cr"
            zccr = d / f"{name}.ccr"
            zexe = d / name
            zsrc.write_text(source, encoding="utf-8")
            err = build(zsrc, zccr)
            if err:
                print(f"{name} frontend failed:\n" + err)
                return 1
            err = emit(zccr, zexe, True)
            if err:
                print(f"{name} backend failed:\n" + err)
                return 1
            zr = run([str(zexe)])
            if zr.returncode == 0:
                print(f"{name}: expected runtime failure")
                return 1
            if needle not in (zr.stdout + zr.stderr):
                print(f"{name}: missing error text {needle!r}: {zr.stdout + zr.stderr!r}")
                return 1

        # The same .ccr must keep working on the raw backend for programs whose
        # values stay in machine-word range.
        ssrc = d / "small.cr"
        sccr = d / "small.ccr"
        raw = d / "small_raw"
        bigs = d / "small_big"
        ssrc.write_text(SMALL, encoding="utf-8")
        err = build(ssrc, sccr)
        if err:
            print("small frontend failed:\n" + err)
            return 1
        for out, big in ((raw, False), (bigs, True)):
            err = emit(sccr, out, big)
            if err:
                print("small backend failed:\n" + err)
                return 1
            rr = run([str(out)])
            if rr.returncode != 0:
                print(f"small parity exit {rr.returncode} (big={big})")
                return 1

    print("PASS bigint arithmetic")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
