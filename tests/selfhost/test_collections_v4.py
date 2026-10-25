"""collections.cr V4 迁移：推断形参 + `.len` + 序列迭代。"""

import os
import subprocess
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = os.environ.get("COREC_BIN") or str(BASE / "build" / "corec")
BUILD = BASE / "build"


def main():
    src = """import collections

fn main() -> int:
    a := [3, 1, 2]
    collections.reverse(a)
    if a[0] != 2 || a[1] != 1 || a[2] != 3:
        return 1
    b := [0, 0, 0]
    collections.copy(a, b)
    if !collections.equals(a, b):
        return 2
    if collections.sum(a) != 6:
        return 3
    if !collections.contains(a, 1):
        return 4
    if collections.index_of(a, 1) != 1:
        return 5
    if collections.find(a, 3) != 2:
        return 6
    if collections.count([1, 1, 2], 1) != 2:
        return 7
    collections.fill(b, 7)
    if b[0] + b[1] + b[2] != 21:
        return 8
    if collections.min_element(a) != 1:
        return 9
    if collections.max_element(a) != 3:
        return 10
    if collections.product([2, 3, 4]) != 24:
        return 11
    if collections.slice_sum(a, 0, 2) != 3:
        return 12
    return 42
"""
    fd, path = tempfile.mkstemp(suffix=".cr", dir="/tmp")
    with os.fdopen(fd, "w") as fh:
        fh.write(src)
    out = str(BUILD / "_v4_collections")
    try:
        b = subprocess.run(
            [str(COREC), "build", path, "-o", out, "--static"],
            cwd=BASE, capture_output=True, text=True, timeout=180,
        )
        print(b.stdout)
        print(b.stderr)
        if b.returncode != 0:
            print("build failed", b.returncode)
            return 1
        r = subprocess.run([out], capture_output=True, text=True, timeout=10)
        print("run rc", r.returncode)
        return 0 if r.returncode == 42 else 1
    finally:
        for p in (path, out, out + ".ccr", out + ".cir"):
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass


if __name__ == "__main__":
    raise SystemExit(main())
