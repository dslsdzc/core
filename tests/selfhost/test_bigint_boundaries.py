#!/usr/bin/env python3
"""Self-hosted BigInt pointer/word/FFI boundary gate (--big-int)."""

import subprocess
import tempfile
from pathlib import Path
import shutil

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"
COREARCH = BASE / "build" / "corearch"

VALID = r"""
fn main() -> int:
    buf := alloc(32)
    cell_store(buf, 0, 42)
    if cell_load(buf, 0) != 42:
        return 1

    x := 4611686018427387904
    cell_store(buf, 8, x)
    if cell_load(buf, 8) != x:
        return 2

    store8(buf, 16, 65)
    if load8(buf, 16) != 65:
        return 3

    pid := syscall3(39, 0, 0, 0)
    if pid <= 0:
        return 4

    s := "hi"
    p : ., mut = 0
    q : ., mut = 0
    unsafe:
        p = @ptr_of(s)
        q = @ptr_of(@str_of(p))
    if q != p:
        return 5
    if p <= 0:
        return 6

    addr := @addr(main)
    if addr <= 0:
        return 7

    arr := [x, x + 1, x + 2]
    base := &arr[1]
    next := base + 1
    if *next != x + 2:
        return 8
    diff := next - base
    if diff != 1:
        return 9
    if *(base - 1) != x:
        return 10

    return 0
"""

W64_BIG = r"""
fn main() -> int:
    buf := alloc(8)
    x := 1267650600228229401496703205376
    cell_store(buf, 0, x)
    return 0
"""

STR_OF_BIG = r"""
fn main() -> int:
    x := 1267650600228229401496703205376
    p : ., mut = ""
    unsafe:
        p = @str_of(x)
    return 0
"""

EXTERN = r"""
extern fn big_inc(x: int) -> int
fn main() -> int:
    x := 4611686018427387904
    if big_inc(x) != x + 1:
        return 1
    return 0
"""

EXTERN_BIG = r"""
extern fn big_inc(x: int) -> int
fn main() -> int:
    x := 1267650600228229401496703205376
    return big_inc(x)
"""


def run(args):
    return subprocess.run(args, cwd=str(BASE), capture_output=True, text=True)


def build(src: Path, ccr: Path, exe: Path) -> str:
    r = run([str(COREC), "ccr", str(src), "-o", str(ccr)])
    if r.returncode != 0:
        return r.stdout + r.stderr
    r = run([str(COREARCH), str(ccr), "--big-int", "-o", str(exe)])
    if r.returncode != 0:
        return r.stdout + r.stderr
    return ""


def expect_error(src: Path, ccr: Path, exe: Path, needle: str) -> str:
    err = build(src, ccr, exe)
    if err:
        return "compile: " + err
    r = run([str(exe)])
    if r.returncode == 0:
        return "expected runtime failure"
    if needle not in (r.stdout + r.stderr):
        return f"missing {needle!r}: {r.stdout + r.stderr!r}"
    return ""


def build_link(src: Path, ccr: Path, exe: Path, shim: Path) -> str:
    r = run([str(COREC), "ccr", str(src), "-o", str(ccr)])
    if r.returncode != 0:
        return r.stdout + r.stderr
    r = run([str(COREARCH), str(ccr), "--big-int", "--elf",
             "--link", str(shim), "--static", "-o", str(exe)])
    if r.returncode != 0:
        return r.stdout + r.stderr
    exe.chmod(0o755)
    return ""


def main() -> int:
    if not COREC.exists() or not COREARCH.exists():
        print("missing build/corec or build/corearch")
        return 1
    with tempfile.TemporaryDirectory(prefix="core-bigint-boundaries-") as td:
        d = Path(td)
        src = d / "valid.cr"
        ccr = d / "valid.ccr"
        exe = d / "valid"
        src.write_text(VALID, encoding="utf-8")
        err = build(src, ccr, exe)
        if err:
            print(err)
            return 1
        r = run([str(exe)])
        if r.returncode != 0:
            print(f"boundaries exit {r.returncode}")
            return 1

        for name, text, needle in (
            ("w64_big", W64_BIG, "machine-word range"),
            ("str_of_big", STR_OF_BIG, "machine-word range"),
        ):
            s = d / f"{name}.cr"
            c = d / f"{name}.ccr"
            e = d / name
            s.write_text(text, encoding="utf-8")
            err = expect_error(s, c, e, needle)
            if err:
                print(f"{name}: {err}")
                return 1

        if shutil.which("gcc"):
            shim_c = d / "int_shim.c"
            shim = d / "int_shim.so"
            shim_c.write_text("long big_inc(long x) { return x + 1; }\n",
                              encoding="utf-8")
            r = run(["gcc", "-shared", "-fPIC", "-O2", str(shim_c),
                     "-o", str(shim)])
            if r.returncode != 0:
                print("shim build failed:\n" + r.stdout + r.stderr)
                return 1
            esrc = d / "extern.cr"
            eccr = d / "extern.ccr"
            eexe = d / "extern"
            esrc.write_text(EXTERN, encoding="utf-8")
            err = build_link(esrc, eccr, eexe, shim)
            if err:
                print("extern link failed:\n" + err)
                return 1
            er = run([str(eexe)])
            if er.returncode != 0:
                print(f"extern valid exit {er.returncode}")
                return 1

            ebsrc = d / "extern_big.cr"
            ebccr = d / "extern_big.ccr"
            ebexe = d / "extern_big"
            ebsrc.write_text(EXTERN_BIG, encoding="utf-8")
            err = build_link(ebsrc, ebccr, ebexe, shim)
            if err:
                print("extern big link failed:\n" + err)
                return 1
            ebr = run([str(ebexe)])
            if ebr.returncode == 0 or "machine-word range" not in (ebr.stdout + ebr.stderr):
                print("extern big argument was not rejected")
                return 1

    print("PASS bigint boundaries")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
