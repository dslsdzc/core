"""V3 显式泛型语法已删除：`[T]` / `<T>` / `Box[int]` 必须被 parser 拒绝。

数组/切片/下标不受影响：`[int; 3]`、`[int]`、`arr[0]` 仍是合法 V4。
"""

import os
import subprocess
import sys
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = os.environ.get("COREC_BIN") or str(BASE / "build" / "corec")


def _check(source):
    fd, path = tempfile.mkstemp(suffix=".cr", dir="/tmp")
    with os.fdopen(fd, "w") as fh:
        fh.write(source)
    try:
        return subprocess.run(
            [COREC, "check", path], cwd=BASE, capture_output=True, text=True, timeout=60
        )
    finally:
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass


def _reject(name, source):
    r = _check(source)
    out = r.stdout + r.stderr
    if r.returncode == 0:
        print(f"[FAIL] {name}: expected parse rejection, got rc=0")
        return False
    if "error[" not in out:
        print(f"[FAIL] {name}: rejection without a diagnostic\n{out}")
        return False
    print(f"[PASS] {name}: rc={r.returncode} rejected")
    return True


def _accept(name, source):
    r = _check(source)
    out = r.stdout + r.stderr
    if r.returncode != 0:
        print(f"[FAIL] {name}: expected rc=0, got {r.returncode}\n{out}")
        return False
    print(f"[PASS] {name}: rc=0")
    return True


def main():
    ok = []

    ok.append(_reject(
        "generic_fn_rejected",
        """fn f[T](x: T) -> int:
    return 1

fn main() -> int:
    return f(1)
""",
    ))

    ok.append(_reject(
        "generic_struct_rejected",
        """struct Box[T]:
    val: T

fn main() -> int:
    b := Box { val = 1 }
    return b.val
""",
    ))

    ok.append(_reject(
        "generic_apply_rejected",
        """struct Box:
    val: .

fn f() -> Box[int]:
    return Box { val = 1 }

fn main() -> int:
    return 0
""",
    ))

    ok.append(_reject(
        "generic_interface_rejected",
        """interface Show[T]:
    fn show(self) -> int

fn main() -> int:
    return 0
""",
    ))

    ok.append(_accept(
        "array_and_index_still_work",
        """fn first(xs) -> int:
    return xs[0]

fn main() -> int:
    xs := [7, 8, 9]
    s := xs[0..2]
    return first(xs) + first(s)
""",
    ))

    passed = sum(1 for x in ok if x)
    print(f"{passed}/{len(ok)} passed")
    return 0 if passed == len(ok) else 1


if __name__ == "__main__":
    raise SystemExit(main())
