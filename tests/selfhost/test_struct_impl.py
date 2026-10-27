"""struct / impl conformance: receivers, associated functions, generic fields.

Covers the gaps found in the 2026-10-27 matrix:
  - an inferred (`.`) field read through a method receiver, not only through a
    plain function parameter;
  - `impl Interface for Type` on a struct with an inferred field;
  - associated functions (no `self`) must not receive a hidden receiver
    argument, and must be able to return a struct by value.
"""

import os
import subprocess
import sys
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = os.environ.get("COREC_BIN") or str(BASE / "build" / "corec")


def run(cmd, timeout=180):
    try:
        return subprocess.run(cmd, cwd=BASE, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return None


def build_run(name, source, want_rc):
    with tempfile.TemporaryDirectory(prefix="core_struct_") as tmp:
        root = Path(tmp)
        src = root / "main.cr"
        src.write_text(source)
        out = root / "a.out"
        b = run([COREC, "build", str(src), "-o", str(out), "--static"])
        if b is None or b.returncode != 0:
            print(f"[FAIL] {name}: build failed")
            if b is not None:
                print(b.stdout)
                print(b.stderr)
            return False
        r = run([str(out)], timeout=10)
        if r is None or r.returncode != want_rc:
            got = "timeout" if r is None else r.returncode
            print(f"[FAIL] {name}: run rc={got} want={want_rc}")
            return False
        print(f"[PASS] {name}: run rc={r.returncode}")
        return True


def rejects(name, source):
    """The receiver spelling is part of the surface: no `self: T`, no free `self`."""
    with tempfile.TemporaryDirectory(prefix="core_struct_neg_") as tmp:
        root = Path(tmp)
        src = root / "main.cr"
        src.write_text(source)
        out = root / "a.out"
        b = run([COREC, "build", str(src), "-o", str(out), "--static"])
        if b is None or b.returncode == 0:
            print(f"[FAIL] {name}: expected rejection")
            return False
        if out.exists():
            print(f"[FAIL] {name}: rejected build left an artifact")
            return False
        print(f"[PASS] {name}: rc={b.returncode}")
        return True


def main():
    ok = []

    ok.append(build_run(
        "generic_field_via_function",
        """struct Holder:
    val: .

fn get(b: Holder) -> int:
    return b.val

fn main() -> int:
    b := Holder { val = 7 }
    return get(b)
""",
        7,
    ))

    ok.append(build_run(
        "generic_field_via_method",
        """struct Holder:
    val: .

impl Holder:
    fn get(self) -> int:
        return self.val

fn main() -> int:
    b := Holder { val = 7 }
    return b.get()
""",
        7,
    ))

    ok.append(build_run(
        "generic_field_via_interface_impl",
        """interface Show:
    fn show(self) -> int

struct Holder:
    v: .

impl Show for Holder:
    fn show(self) -> int:
        return self.v

fn main() -> int:
    b := Holder { v = 11 }
    return b.show()
""",
        11,
    ))

    ok.append(build_run(
        "associated_function_returns_struct",
        """struct Point:
    x: int

impl Point:
    fn make(n: int) -> Point:
        return Point { x = n }

fn main() -> int:
    p := Point.make(9)
    return p.x
""",
        9,
    ))

    ok.append(build_run(
        "method_returns_struct",
        """struct Point:
    x: int

impl Point:
    fn double(self) -> Point:
        return Point { x = self.x + self.x }

fn main() -> int:
    p := Point { x = 21 }
    q := p.double()
    return q.x
""",
        42,
    ))

    ok.append(build_run(
        "receiver_by_value_on_plain_struct",
        """struct P:
    x: int

impl P:
    fn get(self) -> int:
        return self.x

fn main() -> int:
    return P { x = 3 }.get()
""",
        3,
    ))

    ok.append(rejects(
        "self_type_annotation_rejected",
        """struct P:
    x: int

impl P:
    fn get(self: P) -> int:
        return self.x

fn main() -> int:
    return P { x = 3 }.get()
""",
    ))

    ok.append(rejects(
        "self_outside_impl_rejected",
        """struct P:
    x: int

fn get(self) -> int:
    return 1

fn main() -> int:
    return 0
""",
    ))

    ok.append(build_run(
        "mut_self_receiver",
        """struct C:
    n: int

impl C:
    fn bump(&mut self):
        self.n = self.n + 1

fn main() -> int:
    c : ., mut = C { n = 40 }
    c.bump()
    c.bump()
    return c.n
""",
        42,
    ))

    passed = sum(1 for x in ok if x)
    print(f"{passed}/{len(ok)} passed")
    return 0 if all(ok) else 1


if __name__ == "__main__":
    sys.exit(main())
