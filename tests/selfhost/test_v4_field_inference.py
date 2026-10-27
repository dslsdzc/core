"""V4 字段投影推断：模板宽松，monomorph 实例严格重查。

判据：
  * `struct Event: payload: .` + `e.payload.show()` 在实例化后解析到具体类型。
  * 字段类型没有该方法 -> 构建失败并零产物。
  * 实参不是含该字段的 struct -> 构建失败。
"""

import os
import subprocess
import sys
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = os.environ.get("COREC_BIN") or str(BASE / "build" / "corec")
BUILD = BASE / "build"

POS = """interface Show:
    fn show(self) -> int

struct S:
    a: int

impl S:
    fn show(self) -> int:
        return self.a

struct Event:
    payload: .

fn f(e) -> int:
    return e.payload.show()

fn main() -> int:
    return f(Event { payload = S { a = 7 } })
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
    out = str(BUILD / ("_v4_field_" + name))
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


def _build_rejected(name, source, needle):
    fd, path = tempfile.mkstemp(suffix=".cr", dir="/tmp")
    with os.fdopen(fd, "w") as fh:
        fh.write(source)
    out = str(BUILD / ("_v4_field_" + name))
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
            print(text[-1500:])
            return False
        if os.path.exists(out):
            print(f"[FAIL] {name}: rejection left an artifact")
            return False
        print(f"[PASS] {name}: rc={b.returncode} + {needle}")
        return True
    finally:
        for p in (path, out, out + ".ccr", out + ".cir"):
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass


ANNOTATED_PARAM = """struct Box:
    val: .

fn get(b: Box) -> int:
    return b.val

fn main() -> int:
    b := Box { val = 7 }
    return get(b)
"""


def main():
    ok = []
    ok.append(_build_and_run("projected_method", POS, 7))

    # A bare generic struct in a parameter annotation binds fresh function
    # variables; the call site unifies them with the argument.
    ok.append(_build_and_run("annotated_generic_param", ANNOTATED_PARAM, 7))

    ok.append(_build_rejected(
        "annotated_generic_param_mismatch",
        ANNOTATED_PARAM.replace('Box { val = 7 }', 'Box { val = "x" }'),
        "error[",
    ))

    ok.append(_build_rejected(
        "missing_method_rejected",
        """struct S:
    a: int

struct Event:
    payload: .

fn f(e) -> int:
    return e.payload.nosuch()

fn main() -> int:
    return f(Event { payload = S { a = 7 } })
""",
        "error[",
    ))

    ok.append(_build_rejected(
        "wrong_struct_rejected",
        POS.replace(
            "fn main() -> int:\n    return f(Event { payload = S { a = 7 } })\n",
            "fn main() -> int:\n    return f(S { a = 7 })\n",
        ),
        "error[",
    ))

    passed = sum(1 for x in ok if x)
    print(f"{passed}/{len(ok)} passed")
    return 0 if passed == len(ok) else 1


if __name__ == "__main__":
    raise SystemExit(main())
