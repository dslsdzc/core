"""V4 泛型 enum：payload 用 `.` 推断，构造点绑定类型。

判定依据：
  * `enum Opt: N, S(.)` + `c := S(5)` + match 得 5。
  * 同一 enum 的 int/string 两个实例可共存。
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
    out = str(BUILD / ("_v4_genum_" + name))
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
        "int_payload",
        """enum Opt:
    N
    S(.)

fn main() -> int:
    c := S(5)
    return match c:
        N => 1
        S(x) => x
""",
        5,
    ))

    ok.append(_build_and_run(
        "two_payload_types",
        """import fmt

enum Opt:
    N
    S(.)

fn main() -> int:
    a := S(40)
    b := S("xy")
    x := match a:
        N => 0
        S(v) => v
    s := match b:
        N => ""
        S(v) => v
    return x + str_len(s)
""",
        42,
    ))

    passed = sum(1 for x in ok if x)
    print(f"{passed}/{len(ok)} passed")
    return 0 if passed == len(ok) else 1


if __name__ == "__main__":
    raise SystemExit(main())
