"""V4 同名接口方法消歧：用当前函数返回型选择唯一接口。"""

import os
import subprocess
import sys
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = os.environ.get("COREC_BIN") or str(BASE / "build" / "corec")
BUILD = BASE / "build"

BASE_SRC = """interface ShowInt:
    fn show(self) -> int

interface ShowStr:
    fn show(self) -> string

struct A:
    a: int

struct B:
    b: string

impl A:
    fn show(self) -> int:
        return self.a

impl B:
    fn show(self) -> string:
        return self.b

fn f(a) -> int:
    return a.show()
"""


def _run(cmd, timeout):
    try:
        return subprocess.run(cmd, cwd=BASE, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return None


def _build_and_run(name, source, want_rc):
    fd, path = tempfile.mkstemp(suffix=".cr", dir="/tmp")
    with os.fdopen(fd, "w") as fh:
        fh.write(source)
    out = str(BUILD / ("_v4_ambig_" + name))
    try:
        b = _run([COREC, "build", path, "-o", out, "--static"], 120)
        if b is None or b.returncode != 0:
            print(f"[FAIL] {name}: build failed/timeout")
            if b is not None:
                print(b.stdout[-1200:])
                print(b.stderr[-800:])
            return False
        r = _run([out], 5)
        if r is None or r.returncode != want_rc:
            print(f"[FAIL] {name}: run rc={None if r is None else r.returncode} want={want_rc}")
            return False
        print(f"[PASS] {name}: run rc={r.returncode}")
        return True
    finally:
        for p in (path, out, out + ".ccr", out + ".cir"):
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass


def _build_rejected(name, source, needle):
    fd, path = tempfile.mkstemp(suffix=".cr", dir="/tmp")
    with os.fdopen(fd, "w") as fh:
        fh.write(source)
    out = str(BUILD / ("_v4_ambig_" + name))
    try:
        b = _run([COREC, "build", path, "-o", out, "--static"], 120)
        if b is None:
            print(f"[FAIL] {name}: build timed out")
            return False
        text = b.stdout + b.stderr
        if b.returncode == 0 or needle not in text:
            print(f"[FAIL] {name}: rc={b.returncode} missing {needle!r}")
            print(text[-1200:])
            return False
        print(f"[PASS] {name}: rc={b.returncode} + {needle}")
        return True
    finally:
        for p in (path, out, out + ".ccr", out + ".cir"):
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass


def main():
    ok = []
    ok.append(_build_and_run(
        "return_type_selects_int",
        BASE_SRC + """fn main() -> int:
    return f(A { a = 7 })
""",
        7,
    ))
    ok.append(_build_rejected(
        "wrong_return_type_rejected",
        BASE_SRC + """fn main() -> int:
    return f(B { b = "x" })
""",
        "error[",
    ))
    passed = sum(1 for x in ok if x)
    print(f"{passed}/{len(ok)} passed")
    return 0 if passed == len(ok) else 1


if __name__ == "__main__":
    raise SystemExit(main())
