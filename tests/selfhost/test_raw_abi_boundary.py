#!/usr/bin/env python3
"""Raw ABI boundary: load8/store8 and friends are not user symbols.

User code must get N06 for the raw memory builtins. The standard library
reaches them through its own library context, and the public rawbuf wrapper
(which is a pub stdlib API) still works end to end in an ELF binary.
"""

import subprocess
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"

RAW_NAMES = [
    ("load8", 'return load8("x", 0)'),
    ("store8", 'store8("xxxxxxxx", 0, 1)\n    return 0'),
    ("load64", 'return load64("x", -8)'),
    ("w32", 'w32("xxxxxxxx", 0, 1)\n    return 0'),
    ("_dyncpy", 'b := alloc(16)\n    _dyncpy(b, 0, b)\n    return 0'),
    ("load_str_ptr", 'return 0'),
    ("store_str_ptr", 'return 0'),
]

RAW_CALLS = {
    "load_str_ptr": 's := load_str_ptr("x")\n    return 0',
    "store_str_ptr": 'store_str_ptr("x", 1)\n    return 0',
}

WRAPPER_SOURCE = """import rawbuf

fn main() -> int:
    b := alloc(16)
    rawWrite8(b, 0, 65)
    rawWrite8(b, 1, 0)
    if rawRead8(b, 0) != 65:
        return 1
    rawWriteU32BE(b, 4, 16909060)
    if rawReadU32BE(b, 4) != 16909060:
        return 2
    rawWriteU32LE(b, 8, 16909060)
    if rawReadU32LE(b, 8) != 16909060:
        return 3
    return 42
"""

PUBLIC_ABI_SOURCE = """fn main() -> int:
    b := alloc(16)
    cell_store(b, 0, 65)
    if cell_load(b, 0) != 65:
        return 1
    return 42
"""


def _run(args, **kwargs):
    return subprocess.run(args, capture_output=True, text=True, cwd=str(BASE), timeout=60, **kwargs)


def test_raw_names_are_undefined():
    for name, body in RAW_NAMES:
        call = RAW_CALLS.get(name, body)
        src = f"fn main() -> int:\n    {call}\n"
        run = _run([str(COREC), "run", src])
        text = run.stdout + run.stderr
        assert run.returncode == 1, (name, text)
        assert "error[N06]" in text, (name, text)
        assert f"Undefined function '{name}'" in text, (name, text)


def test_stdlib_wrapper_and_public_abi():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        for label, source, expected in (
            ("wrapper", WRAPPER_SOURCE, 42),
            ("public_abi", PUBLIC_ABI_SOURCE, 42),
        ):
            src = tmp / f"{label}.cr"
            src.write_text(source, encoding="utf-8")
            elf = tmp / f"{label}.elf"
            built = _run([str(COREC), "build", str(src), "-o", str(elf), "--static"])
            assert built.returncode == 0, built.stdout + built.stderr
            run = _run([str(elf)])
            assert run.returncode == expected, (label, run.stdout + run.stderr)


if __name__ == "__main__":
    test_raw_names_are_undefined()
    test_stdlib_wrapper_and_public_abi()
    print("RAW ABI BOUNDARY PASS")
