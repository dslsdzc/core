"""V4 返回类型推断：省略 `-> T` 时由函数体推出。

判定依据：
  * `fn identity(x): return x` 同型返回 int/string。
  * `fn first(xs): return xs[0]` 由索引推出 int。
  * `fn answer(): return 42` 无参函数推出 int。
"""

import os
import subprocess
import sys
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = os.environ.get("COREC_BIN") or str(BASE / "build" / "corec")
BUILD = BASE / "build"


def _run(cmd, timeout):
    try:
        return subprocess.run(cmd, cwd=BASE, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return None


def _build_and_run(name, source, want_rc):
    fd, path = tempfile.mkstemp(suffix=".cr", dir="/tmp")
    with os.fdopen(fd, "w") as fh:
        fh.write(source)
    out = str(BUILD / ("_v4_ret_" + name))
    try:
        b = _run([COREC, "build", path, "-o", out, "--static"], 120)
        if b is None or b.returncode != 0:
            print(f"[FAIL] {name}: build failed/timeout")
            if b is not None:
                print(b.stdout)
                print(b.stderr)
            return False
        r = _run([out], 5)
        if r is None:
            print(f"[FAIL] {name}: run timed out")
            return False
        if r.returncode != want_rc:
            print(f"[FAIL] {name}: run rc={r.returncode} want={want_rc}")
            return False
        print(f"[PASS] {name}: run rc={r.returncode}")
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
        "identity_int",
        """fn identity(x):
    return x

fn main() -> int:
    return identity(42)
""",
        42,
    ))

    ok.append(_build_and_run(
        "identity_str_len",
        """import fmt

fn identity(x):
    return x

fn main() -> int:
    return str_len(identity("hello"))
""",
        5,
    ))

    ok.append(_build_and_run(
        "first_index",
        """fn first(xs):
    return xs[0]

fn main() -> int:
    xs := [7, 8, 9]
    s := xs[0..2]
    return first(xs) + first(s)
""",
        14,
    ))

    ok.append(_build_and_run(
        "no_args",
        """fn answer():
    return 42

fn main() -> int:
    return answer()
""",
        42,
    ))

    passed = sum(1 for x in ok if x)
    print(f"{passed}/{len(ok)} passed")
    return 0 if passed == len(ok) else 1


if __name__ == "__main__":
    raise SystemExit(main())
