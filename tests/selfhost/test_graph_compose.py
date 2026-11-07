#!/usr/bin/env python3
"""Graph composition `>|`: pending closures over direct function graphs."""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"


def _run(args, timeout=180):
    return subprocess.run([str(COREC), *args], cwd=BASE, capture_output=True,
                          text=True, timeout=timeout)


def check_ok(name: str, source: str) -> bool:
    with tempfile.TemporaryDirectory(prefix="graph_ok_") as td:
        src = Path(td) / "p.cr"
        src.write_text(source)
        r = _run(["check", str(src)])
        if r.returncode == 0:
            print(f"PASS {name}")
            return True
        print(f"FAIL {name}: rc={r.returncode}\n{r.stdout}\n{r.stderr}")
        return False


def check_rejected(name: str, source: str, needle: str) -> bool:
    with tempfile.TemporaryDirectory(prefix="graph_neg_") as td:
        src = Path(td) / "p.cr"
        src.write_text(source)
        r = _run(["check", str(src)])
        out = r.stdout + r.stderr
        if r.returncode != 0 and needle in out:
            print(f"PASS {name}")
            return True
        print(f"FAIL {name}: rc={r.returncode} needle={needle!r}\n{out}")
        return False


def build_run(name: str, source: str, want_rc: int,
              want_stdout: list[str] | None = None) -> bool:
    with tempfile.TemporaryDirectory(prefix="graph_run_") as td:
        root = Path(td)
        src = root / "p.cr"
        elf = root / "p"
        src.write_text(source)
        built = _run(["build", str(src), "--static", "-O", "0", "-o", str(elf)])
        if built.returncode != 0:
            print(f"FAIL {name}: build rc={built.returncode}\n{built.stdout}\n{built.stderr}")
            return False
        run = subprocess.run([str(elf)], capture_output=True, text=True, timeout=60)
        if run.returncode != want_rc:
            print(f"FAIL {name}: run rc={run.returncode} want={want_rc}\n{run.stdout}\n{run.stderr}")
            return False
        if want_stdout is not None and run.stdout.splitlines() != want_stdout:
            print(f"FAIL {name}: stdout={run.stdout.splitlines()!r}")
            return False
        print(f"PASS {name}")
        return True


NAMED = """\
fn square(x: int) -> int:
    return x * x

fn main() -> int:
    return fn.square(9)
"""

LAMBDA = """\
fn main() -> int:
    double := fn(x: int) => x * 2
    return double(10)
"""

COMPOSE = """\
fn main() -> int:
    double := fn(x: int) => x * 2
    inc := fn(x: int) => x + 1
    h := double >| inc
    return h(10)
"""

ASSOC = """\
fn main() -> int:
    double := fn(x: int) => x * 2
    inc := fn(x: int) => x + 1
    h := double >| inc >| double
    return h(10)
"""

NAMED_COMPOSE = """\
fn square(x: int) -> int:
    return x * x

fn inc(x: int) -> int:
    return x + 1

fn main() -> int:
    h := fn.square >| fn.inc
    return h(5)
"""

BARE_COMPOSE = """\
fn square(x: int) -> int:
    return x * x

fn inc(x: int) -> int:
    return x + 1

fn main() -> int:
    h := square >| inc
    return h(5)
"""

ANNOTATED = """\
fn main() -> int:
    f : fn(int) -> int = fn(x) => x + 2
    return f(40)
"""

BLOCK = """\
fn main() -> int:
    f := fn(x: int) -> int:
        y := x + 1
        return y * 2
    return f(20)
"""

TYPE_ALIAS = """\
type Handler = fn(int) -> int

fn main() -> int:
    f : Handler = fn(x) => x + 5
    return f(37)
"""

LAZY = """\
import io

fn first(x: int) -> int:
    println("first")
    return x + 1

fn second(x: int) -> int:
    println("second")
    return x * 2

fn main() -> int:
    h := fn.first >| fn.second
    println("before")
    r := h(3)
    println("after")
    return r
"""


def main() -> int:
    ok = []
    ok.append(build_run("named_fn_value", NAMED, 81))
    ok.append(build_run("lambda", LAMBDA, 20))
    ok.append(build_run("compose", COMPOSE, 21))
    ok.append(build_run("associativity", ASSOC, 42))
    ok.append(build_run("named_compose", NAMED_COMPOSE, 26))
    ok.append(build_run("bare_named_compose", BARE_COMPOSE, 26))
    ok.append(build_run("annotated_lambda", ANNOTATED, 42))
    ok.append(build_run("block_lambda", BLOCK, 42))
    ok.append(build_run("type_alias", TYPE_ALIAS, 42))
    ok.append(build_run("lazy_compose", LAZY, 8,
                        ["before", "first", "second", "after"]))
    ok.append(check_rejected("type_mismatch", """\
fn main() -> int:
    f := fn(x: int) => x + 1
    g := fn(x: string) => x
    h := f >| g
    return 0
""", "composition type mismatch"))
    ok.append(check_rejected("capture_rejected", """\
fn main() -> int:
    base := 10
    f := fn(x: int) => x + base
    return f(1)
""", "cannot capture"))
    ok.append(check_rejected("undefined_function", """\
fn main() -> int:
    h := fn.nope >| fn.nope
    return 0
""", "Undefined function"))
    ok.append(check_rejected("non_function_compose", """\
fn main() -> int:
    x := 1
    h := x >| x
    return 0
""", "not a graph/function alias"))
    ok.append(check_rejected("missing_lambda_param_type", """\
fn main() -> int:
    f := fn(x) => x * 2
    return 0
""", "Cannot infer lambda parameter type"))
    ok.append(check_rejected("callable_parameter", """\
fn apply(f: fn(int) -> int, x: int) -> int:
    return 0

fn main() -> int:
    return apply(1, 2)
""", "Callable parameters are not supported"))
    ok.append(check_rejected("fnref_is_not_int", """\
fn square(x: int) -> int:
    return x * x

fn main() -> int:
    p : int = fn.square
    return 0
""", "non-function type"))
    ok.append(check_rejected("addr_is_not_callable", """\
fn square(x: int) -> int:
    return x * x

fn main() -> int:
    f : fn(int) -> int = @addr(square)
    return 0
""", "Function type annotation requires"))
    passed = sum(1 for x in ok if x)
    print(f"{passed}/{len(ok)} passed")
    return 0 if passed == len(ok) else 1


if __name__ == "__main__":
    raise SystemExit(main())
