"""Enum syntax and enum impl coverage.

V4 documents enum variants with a leading `|`. The bootstrap parser accepts
that form, so the self-hosted parser must accept it too. Bare layout variants
stay accepted for existing corpora.
"""

import os
import subprocess
import sys
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = os.environ.get("COREC_BIN") or str(BASE / "build" / "corec")


def run(cmd, timeout=120):
    try:
        return subprocess.run(cmd, cwd=BASE, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return None


def build_run(name, source, want_rc):
    with tempfile.TemporaryDirectory(prefix="core_enum_impl_") as tmp:
        root = Path(tmp)
        src = root / "main.cr"
        src.write_text(source)
        out = root / "a.out"
        b = run([COREC, "build", str(src), "-o", str(out), "--static"], timeout=180)
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
    """Named payload fields are not part of the surface; the error must say so."""
    import tempfile
    from pathlib import Path
    with tempfile.TemporaryDirectory(prefix="core_enum_neg_") as tmp:
        root = Path(tmp)
        src = root / "main.cr"
        src.write_text(source)
        out = root / "a.out"
        b = run([COREC, "build", str(src), "-o", str(out), "--static"], timeout=120)
        text = "" if b is None else b.stdout + b.stderr
        if b is None or b.returncode == 0:
            print(f"[FAIL] {name}: expected rejection")
            return False
        if "named enum payload fields are not supported" not in text:
            print(f"[FAIL] {name}: message missing")
            print(text)
            return False
        print(f"[PASS] {name}: rc={b.returncode}")
        return True


def main():
    ok = []
    ok.append(build_run(
        "pipe_inherent_method",
        """enum Mode:
 | Server
 | Client(int)

impl Mode:
    fn code(self) -> int:
        return match self:
            Server => 1
            Client(v) => v

fn main() -> int:
    m := Client(41)
    return m.code() + 1
""",
        42,
    ))
    ok.append(build_run(
        "pipe_interface_impl",
        """interface Show:
    fn show(self) -> int

enum Mode:
 | A
 | B

impl Show for Mode:
    fn show(self) -> int:
        return 7

fn main() -> int:
    m := B
    return m.show()
""",
        7,
    ))
    ok.append(build_run(
        "pipe_generic_enum_impl",
        """enum Opt:
 | N
 | S(.)

impl Opt:
    fn get(self) -> int:
        return match self:
            N => 0
            S(v) => v

fn main() -> int:
    a := S(7)
    return a.get()
""",
        7,
    ))
    ok.append(build_run(
        "bare_layout_compat",
        """enum Mode:
    A
    B

impl Mode:
    fn code(self) -> int:
        return 2

fn main() -> int:
    return A.code()
""",
        2,
    ))
    ok.append(rejects(
        "named_payload_rejected",
        """enum Shape:
 | Circle(r: int)

fn main() -> int:
    return 0
""",
    ))
    passed = sum(1 for x in ok if x)
    print(f"{passed}/{len(ok)} passed")
    return 0 if all(ok) else 1


if __name__ == "__main__":
    sys.exit(main())
