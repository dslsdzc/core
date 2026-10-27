"""`cast` operator: spelling, whitelist, and conversion semantics.

The operator replaced `as`. `cast<T>(expr)` was a V3 leftover and is gone.
Anything outside the whitelist is `error[TA09]`, not a silent bit copy.
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
    with tempfile.TemporaryDirectory(prefix="core_cast_") as tmp:
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


def check_rejects(name, source, code, exact=True, want_artifact=False):
    with tempfile.TemporaryDirectory(prefix="core_cast_neg_") as tmp:
        root = Path(tmp)
        src = root / "main.cr"
        src.write_text(source)
        out = root / "a.out"
        b = run([COREC, "build", str(src), "-o", str(out), "--static"], timeout=120)
        text = "" if b is None else b.stdout + b.stderr
        if b is None or b.returncode == 0:
            print(f"[FAIL] {name}: expected rejection, got rc={'timeout' if b is None else b.returncode}")
            print(text)
            return False
        hit = True
        if code is not None:
            hit = ("error[" + code + "]") in text if exact else ("error[" + code) in text
        if not hit:
            print(f"[FAIL] {name}: rc={b.returncode} but no error[{code}]")
            print(text)
            return False
        if not want_artifact and out.exists():
            print(f"[FAIL] {name}: rejected build left an artifact")
            return False
        print(f"[PASS] {name}: rc={b.returncode} + error[{code}]" if code else f"[PASS] {name}: rc={b.returncode}")
        return True


def main():
    ok = []

    ok.append(build_run(
        "int_to_dex_is_exact",
        """fn main() -> int:
    d : dex = 7 cast dex
    raw := @raw_int(d)
    if raw != 7000000:
        return 1
    return 42
""",
        42,
    ))

    ok.append(build_run(
        "dex_to_int_truncates",
        """fn main() -> int:
    return 1.5 cast int
""",
        1,
    ))

    ok.append(build_run(
        "dex_to_int_truncates_negative",
        """fn main() -> int:
    return (0.0 - 1.5) cast int
""",
        255,
    ))

    ok.append(build_run(
        "identity_cast",
        """fn main() -> int:
    x := 7
    y := x cast int
    return y
""",
        7,
    ))

    ok.append(build_run(
        "char_round_trip",
        """fn main() -> int:
    c := 'A' cast int
    d := c cast char
    if d != 'A':
        return 2
    return 42
""",
        42,
    ))

    ok.append(check_rejects(
        "pointer_to_int_not_offered",
        """fn main() -> int:
    unsafe:
        p := 4096 cast *int
        n := p cast int
        return n % 256
""",
        "TA09",
    ))

    ok.append(check_rejects(
        "string_to_int_rejected",
        """fn main() -> int:
    s := "a"
    return s cast int
""",
        "TA09",
    ))

    ok.append(check_rejects(
        "bool_to_int_rejected",
        """fn main() -> int:
    b := true
    return b cast int
""",
        "TA09",
    ))

    ok.append(build_run(
        "pointer_cast_is_not_the_gate",
        """fn main() -> int:
    p := 4096 cast *int
    q := p cast *int
    return 42
""",
        42,
    ))

    ok.append(check_rejects(
        "external_deref_still_needs_unsafe",
        """fn main() -> int:
    p := 4096 cast *int
    return *p
""",
        "TU03",
    ))

    ok.append(check_rejects(
        "as_keyword_removed",
        """fn main() -> int:
    return 1.5 as int
""",
        None,
    ))

    ok.append(check_rejects(
        "angle_bracket_cast_removed",
        """fn main() -> int:
    return cast<int>(1)
""",
        None,
    ))

    passed = sum(1 for x in ok if x)
    print(f"{passed}/{len(ok)} passed")
    return 0 if all(ok) else 1


if __name__ == "__main__":
    sys.exit(main())
