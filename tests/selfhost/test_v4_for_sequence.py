"""V4 `for x in xs`：数组/切片序列迭代。

判定依据：
  * 具体数组：`for x in [1,2,3]` 累加得元素，而不是拿数组值当上界。
  * 推断形参：同一个 `fn sum(xs)` 接长度 3 和 4 的数组。
  * 切片：同函数内 `xs[0..3]` 迭代。
  * 切片形参：没有运行期长度，必须 `error[TK07]` fail-closed，不能挂起。

运行期用 5 秒超时；修复前 IR 把数组值当循环上界，超时即 RED。
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
    out = str(BUILD / ("_v4_for_" + name))
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
            print(f"[FAIL] {name}: run timed out (sequence iteration is not implemented)")
            return False
        if r.returncode != want_rc:
            print(f"[FAIL] {name}: run rc={r.returncode} want={want_rc}")
            print(r.stdout)
            print(r.stderr)
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
    """Slice parameters have no run-time length; iteration must fail closed."""
    fd, path = tempfile.mkstemp(suffix=".cr", dir="/tmp")
    with os.fdopen(fd, "w") as fh:
        fh.write(source)
    out = str(BUILD / ("_v4_for_" + name))
    try:
        b = _run([COREC, "build", path, "-o", out, "--static"], 120)
        if b is None:
            print(f"[FAIL] {name}: build timed out")
            return False
        text = b.stdout + b.stderr
        if b.returncode == 0:
            print(f"[FAIL] {name}: expected rejection, got rc=0")
            return False
        if needle not in text:
            print(f"[FAIL] {name}: missing {needle!r}")
            print(text)
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
        "concrete_array",
        """fn main() -> int:
    xs := [1, 2, 3]
    total : ., mut = 0
    for x in xs:
        total = total + x
    return total
""",
        6,
    ))

    ok.append(_build_and_run(
        "inferred_param",
        """fn sum(xs) -> int:
    total : ., mut = 0
    for x in xs:
        total = total + x
    return total

fn main() -> int:
    return sum([1, 2, 3]) + sum([1, 2, 3, 4])
""",
        16,
    ))

    ok.append(_build_and_run(
        "slice",
        """fn main() -> int:
    xs := [1, 2, 3, 4]
    s := xs[0..3]
    total : ., mut = 0
    for x in s:
        total = total + x
    return total
""",
        6,
    ))

    # Slice parameters carry the header length across calls.
    ok.append(_build_and_run(
        "slice_param",
        """fn sum(xs) -> int:
    total : ., mut = 0
    for x in xs:
        total = total + x
    return total

fn main() -> int:
    xs := [1, 2, 3]
    s := xs[0..2]
    return sum(s)
""",
        3,
    ))

    passed = sum(1 for x in ok if x)
    print(f"{passed}/{len(ok)} passed")
    return 0 if passed == len(ok) else 1


if __name__ == "__main__":
    raise SystemExit(main())
