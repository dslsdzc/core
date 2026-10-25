"""V4 自动约束推断：泛型形参的方法调用反推接口约束。

判据：
  * `fn f(a) -> int: return a.show()` 不写 `[T: Show]`，从方法名推出 Show，
    monomorph 按具体类型解析到 `S.show`。
  * 具体类型未实现该接口 -> `error[TG02]`，构建失败且不产出 ELF。
"""

import os
import subprocess
import sys
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = os.environ.get("COREC_BIN") or str(BASE / "build" / "corec")
BUILD = BASE / "build"

SHOW = """interface Show:
    fn show(self) -> int

struct S:
    a: int

impl S:
    fn show(self: S) -> int:
        return self.a
"""

FOF = """fn f(a) -> int:
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
    out = str(BUILD / ("_v4_auto_constr_" + name))
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


def _build_rejected(name, source, needle):
    fd, path = tempfile.mkstemp(suffix=".cr", dir="/tmp")
    with os.fdopen(fd, "w") as fh:
        fh.write(source)
    out = str(BUILD / ("_v4_auto_constr_" + name))
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
        if os.path.exists(out):
            print(f"[FAIL] {name}: rejection left an output artifact")
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
        "method_infers_show",
        SHOW + FOF + """fn main() -> int:
    return f(S { a = 7 })
""",
        7,
    ))

    # Call site before the generic function body: constraint inference must not
    # depend on source order.
    ok.append(_build_and_run(
        "call_before_def",
        """interface Show:
    fn show(self) -> int

struct S:
    a: int

impl S:
    fn show(self: S) -> int:
        return self.a

fn main() -> int:
    return f(S { a = 7 })

fn f(a) -> int:
    return a.show()
""",
        7,
    ))

    ok.append(_build_rejected(
        "missing_impl_rejected",
        """interface Show:
    fn show(self) -> int

struct T:
    a: int

""" + FOF + """fn main() -> int:
    return f(T { a = 7 })
""",
        "error[TG02]",
    ))

    passed = sum(1 for x in ok if x)
    print(f"{passed}/{len(ok)} passed")
    return 0 if passed == len(ok) else 1


if __name__ == "__main__":
    raise SystemExit(main())
