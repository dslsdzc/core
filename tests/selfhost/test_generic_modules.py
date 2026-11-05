#!/usr/bin/env python3
"""Cross-module generic constraints and fail-closed FFI boundaries."""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"

GOOD_MAIN = """\
import lib
import p

fn main() -> int:
    if show(1) != "int":
        return 1
    return 0
"""

BAD_MAIN = """\
import lib
import p

fn main() -> int:
    return show(true)
"""


def _run(args, timeout=180):
    return subprocess.run([str(COREC), *args], cwd=BASE, capture_output=True,
                          text=True, timeout=timeout)


def _write_fixture(root: Path):
    (root / "p.cr").write_text("""\
interface P, pub:
    fn r(self) -> string

impl P for int:
    fn r(self) -> string:
        return "int"
""")
    (root / "lib.cr").write_text("""\
import p

fn show(v), pub:
    return v.r()
""")


def build_ok(name: str, main_src: str, want_rc: int) -> bool:
    with tempfile.TemporaryDirectory(prefix="generic_mod_") as td:
        root = Path(td)
        _write_fixture(root)
        src = root / "main.cr"
        elf = root / "main.elf"
        src.write_text(main_src)
        built = _run(["build", str(src), "--static", "-O", "0", "-o", str(elf)])
        if built.returncode != 0:
            print(f"FAIL {name}: build rc={built.returncode}\n{built.stdout}\n{built.stderr}")
            return False
        run = subprocess.run([str(elf)], capture_output=True, text=True, timeout=30)
        if run.returncode != want_rc:
            print(f"FAIL {name}: run rc={run.returncode} want={want_rc}\n{run.stdout}\n{run.stderr}")
            return False
        print(f"PASS {name}")
        return True


def build_rejected(name: str, main_src: str, needle: str) -> bool:
    with tempfile.TemporaryDirectory(prefix="generic_mod_neg_") as td:
        root = Path(td)
        _write_fixture(root)
        src = root / "main.cr"
        elf = root / "main.elf"
        src.write_text(main_src)
        built = _run(["build", str(src), "--static", "-O", "0", "-o", str(elf)])
        text = built.stdout + built.stderr
        if built.returncode == 0 or needle not in text:
            print(f"FAIL {name}: rc={built.returncode} needle={needle!r}\n{text}")
            return False
        if elf.exists():
            print(f"FAIL {name}: rejection left an output artifact")
            return False
        print(f"PASS {name}")
        return True


def ffi_extern_rejected(name: str) -> bool:
    with tempfile.TemporaryDirectory(prefix="generic_ffi_") as td:
        root = Path(td)
        src = root / "ffi.cr"
        src.write_text("""\
extern fn show(v) -> int

fn main() -> int:
    return 0
""")
        r = _run(["check", str(src)])
        if r.returncode == 0:
            print(f"FAIL {name}: inferred generic extern was accepted")
            return False
        print(f"PASS {name}")
        return True


def main() -> int:
    ok = []
    ok.append(build_ok("exported_generic_instantiated", GOOD_MAIN, 0))
    ok.append(build_rejected("missing_impl_across_module", BAD_MAIN, "error[TG02]"))
    ok.append(ffi_extern_rejected("extern_generic_requires_types"))
    passed = sum(1 for x in ok if x)
    print(f"{passed}/{len(ok)} passed")
    return 0 if passed == len(ok) else 1


if __name__ == "__main__":
    raise SystemExit(main())
