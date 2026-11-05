#!/usr/bin/env python3
"""Generic constraints: primitive impls, solver/cache identity, ambiguity, Printable."""

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


def cache_identity(name: str, source: str) -> bool:
    with tempfile.TemporaryDirectory(prefix="generic_cache_") as td:
        root = Path(td)
        src = root / f"{name}.cr"
        ccr = root / f"{name}.ccr"
        src.write_text(source)
        built = _run(["ccr", str(src), "-o", str(ccr), "--dump-ir-text"])
        text = built.stdout + built.stderr
        if built.returncode != 0:
            print(f"FAIL {name}: ccr rc={built.returncode}\n{text[-2000:]}")
            return False
        lines = [ln for ln in text.splitlines() if ln.startswith("Function: show[")]
        ints = [ln for ln in lines if "[int," in ln]
        strs = [ln for ln in lines if "[string," in ln]
        if len(lines) != 2 or len(ints) != 1 or len(strs) != 1:
            print(f"FAIL {name}: instances={lines!r}")
            return False
        print(f"PASS {name}")
        return True


def build_rejected(name: str, source: str, needle: str) -> bool:
    with tempfile.TemporaryDirectory(prefix="generic_neg_") as td:
        root = Path(td)
        src = root / f"{name}.cr"
        elf = root / name
        src.write_text(source)
        built = _run(["build", str(src), "--static", "-O", "0", "-o", str(elf)])
        text = built.stdout + built.stderr
        if built.returncode == 0 or needle not in text:
            print(f"FAIL {name}: rc={built.returncode} needle={needle!r}\n{text}")
            return False
        if elf.exists():
            print(f"FAIL {name}: rejection left an output artifact")
            return False
        print(f"PASS {name}")
        return True


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

NESTED_GENERIC = """\
interface P:
    fn r(self) -> string

impl P for int:
    fn r(self) -> string:
        return "int"

impl P for string:
    fn r(self) -> string:
        return "string"

fn inner(v):
    return v.r()

fn outer(v):
    return inner(v)

fn main() -> int:
    if outer(1) != "int":
        return 1
    if outer("x") != "string":
        return 2
    return 0
"""

AMBIGUOUS_METHOD = """\
interface P:
    fn r(self) -> int

interface Q:
    fn r(self) -> int

impl P for int:
    fn r(self) -> int:
        return 1

impl Q for string:
    fn r(self) -> int:
        return 2

fn show(v):
    return v.r()

fn main() -> int:
    return show(1)
"""

DUPLICATE_IMPL = """\
interface P:
    fn r(self) -> string

impl P for int:
    fn r(self) -> string:
        return "a"

impl P for int:
    fn r(self) -> string:
        return "b"

fn main() -> int:
    return 0
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
    ok.append(build_rejected("missing_impl_no_artifact", MISSING_IMPL,
                             "does not satisfy interface"))
    ok.append(build_run("nested_generic_dispatch", NESTED_GENERIC, []))
    ok.append(cache_identity("instance_cache_identity", PRIMITIVE_DISPATCH))
    ok.append(build_rejected("ambiguous_method_rejected", AMBIGUOUS_METHOD,
                             "error[TG03]"))
    ok.append(build_rejected("duplicate_impl_rejected", DUPLICATE_IMPL,
                             "Conflicting impl"))
    ok.append(build_run("generic_print", GENERIC_PRINT,
                        ["55", "ok", "true", "55"]))
    passed = sum(1 for x in ok if x)
    print(f"{passed}/{len(ok)} passed")
    return 0 if passed == len(ok) else 1


if __name__ == "__main__":
    raise SystemExit(main())
