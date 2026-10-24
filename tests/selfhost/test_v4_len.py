"""V4 `.len`：数组、字符串、同函数切片的长度。

切片形参没有运行期长度，仍应 fail-closed；本测试只覆盖有静态长度的形态。
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
    out = str(BUILD / ("_v4_len_" + name))
    try:
        b = _run([COREC, "build", path, "-o", out, "--static"], 120)
        if b is None or b.returncode != 0:
            print(f"[FAIL] {name}: build failed/timeout")
            if b is not None:
                print(b.stdout)
                print(b.stderr)
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


def main():
    ok = []

    ok.append(_build_and_run(
        "array_len",
        """fn main() -> int:
    xs := [1, 2, 3]
    return xs.len
""",
        3,
    ))

    ok.append(_build_and_run(
        "string_len",
        """fn main() -> int:
    s := "hello"
    return s.len
""",
        5,
    ))

    ok.append(_build_and_run(
        "slice_len",
        """fn main() -> int:
    xs := [1, 2, 3, 4]
    s := xs[0..3]
    return s.len
""",
        3,
    ))

    ok.append(_build_and_run(
        "array_param_len",
        """fn count(xs) -> int:
    return xs.len

fn main() -> int:
    return count([1, 2, 3, 4])
""",
        4,
    ))

    ok.append(_build_and_run(
        "slice_param_len",
        """fn count(xs) -> int:
    return xs.len

fn main() -> int:
    xs := [1, 2, 3, 4]
    s := xs[0..3]
    return count(s)
""",
        3,
    ))

    ok.append(_build_and_run(
        "runtime_slice_len",
        """fn main() -> int:
    xs := [1, 2, 3, 4]
    lo : ., mut = 1
    hi : ., mut = 3
    s := xs[lo..hi]
    return s.len
""",
        2,
    ))

    ok.append(_build_and_run(
        "array_arg_to_slice_param",
        """fn count(xs) -> int:
    return xs.len

fn main() -> int:
    return count([1, 2, 3]) + count([1, 2])
""",
        5,
    ))

    passed = sum(1 for x in ok if x)
    print(f"{passed}/{len(ok)} passed")
    return 0 if passed == len(ok) else 1


if __name__ == "__main__":
    raise SystemExit(main())
