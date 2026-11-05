#!/usr/bin/env python3
"""Generic constraints: primitive impls, inferred method constraints, Printable."""

from __future__ import annotations

import os
import subprocess
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"


def _run(args, timeout=120):
    return subprocess.run([str(COREC), *args], cwd=BASE, capture_output=True,
                          text=True, timeout=timeout)


def check_ok(name: str, source: str) -> bool:
    with tempfile.NamedTemporaryFile("w", suffix=".cr", delete=False) as f:
        f.write(source)
        path = f.name
    try:
        r = _run(["check", path])
    finally:
        os.unlink(path)
    if r.returncode == 0:
        print(f"PASS {name}")
        return True
    print(f"FAIL {name}: rc={r.returncode}\n{r.stdout}\n{r.stderr}")
    return False


def check_rejected(name: str, source: str, needle: str) -> bool:
    with tempfile.NamedTemporaryFile("w", suffix=".cr", delete=False) as f:
        f.write(source)
        path = f.name
    try:
        r = _run(["check", path])
    finally:
        os.unlink(path)
    out = r.stdout + r.stderr
    if r.returncode != 0 and needle in out:
        print(f"PASS {name}")
        return True
    print(f"FAIL {name}: rc={r.returncode} needle={needle!r}\n{out}")
    return False


def build_run(name: str, source: str, expected_stdout: list[str], rc: int = 0) -> bool:
    with tempfile.TemporaryDirectory(prefix="generic_") as td:
        root = Path(td)
        src = root / f"{name}.cr"
        elf = root / name
        src.write_text(source)
        built = _run(["build", str(src), "--static", "-O", "0", "-o", str(elf)])
        if built.returncode != 0:
            print(f"FAIL {name}: build rc={built.returncode}\n{built.stdout}\n{built.stderr}")
            return False
        run = subprocess.run([str(elf)], capture_output=True, text=True, timeout=60)
        lines = run.stdout.splitlines()
        if run.returncode != rc or lines != expected_stdout:
            print(f"FAIL {name}: rc={run.returncode} stdout={lines!r}\n{run.stderr}")
            return False
        print(f"PASS {name}")
        return True


PRIMITIVE_DISPATCH = """\
interface P:
    fn r(self) -> string

impl P for int:
    fn r(self) -> string:
        return "int"

impl P for string:
    fn r(self) -> string:
        return "string"

fn show(v):
    return v.r()

fn main() -> int:
    if show(1) != "int":
        return 1
    if show("x") != "string":
        return 2
    return 0
"""

MISSING_IMPL = """\
interface P:
    fn r(self) -> string

impl P for int:
    fn r(self) -> string:
        return "int"

fn show(v):
    return v.r()

fn main() -> int:
    return show(true)
"""

GENERIC_PRINT = """\
import io

fn fib(n: int) -> int:
    if n < 2:
        return n
    return fib(n - 1) + fib(n - 2)

fn main() -> int:
    println(fib(10))
    println("ok")
    println(true)
    println_i(55)
    return 0
"""


def main() -> int:
    ok = []
    ok.append(check_ok("primitive_impl_dispatch", PRIMITIVE_DISPATCH))
    ok.append(check_rejected("missing_impl_rejected", MISSING_IMPL,
                             "does not satisfy interface"))
    ok.append(build_run("generic_print", GENERIC_PRINT,
                        ["55", "ok", "true", "55"]))
    passed = sum(1 for x in ok if x)
    print(f"{passed}/{len(ok)} passed")
    return 0 if passed == len(ok) else 1


if __name__ == "__main__":
    raise SystemExit(main())
