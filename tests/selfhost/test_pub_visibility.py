#!/usr/bin/env python3
"""Library visibility: pub exports, same-library internals, hidden stdlib internals."""

import subprocess
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"


def _run(args, **kwargs):
    return subprocess.run(args, capture_output=True, text=True, cwd=str(BASE), timeout=60, **kwargs)


VISIBLE_SOURCE = """import io

fn exported(x: int) -> int, pub:
    return x + 1

fn internal(x: int) -> int:
    return x + 2

fn main() -> int:
    print("visibility-ok\\n")
    if exported(40) != 41:
        return 1
    if internal(40) != 42:
        return 2
    return 42
"""

HIDDEN_SOURCE = """fn marker(), pub:
    return

fn main() -> int:
    return fpow2i(1)
"""


def test_pub_export_and_same_library_internal():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        interp = _run([str(COREC), "run", VISIBLE_SOURCE])
        assert interp.returncode == 42, interp.stdout + interp.stderr
        src = tmp / "visibility.cr"
        src.write_text(VISIBLE_SOURCE, encoding="utf-8")
        for opt in (0, 2):
            elf = tmp / f"visibility_O{opt}.elf"
            built = _run([str(COREC), "build", str(src), "-o", str(elf), "--static", "-O", str(opt)])
            assert built.returncode == 0, built.stdout + built.stderr
            run = _run([str(elf)])
            assert run.returncode == 42, run.stdout + run.stderr


def test_stdlib_internal_is_hidden():
    run = _run([str(COREC), "run", HIDDEN_SOURCE])
    text = run.stdout + run.stderr
    assert run.returncode == 1, text
    assert "error[N06]" in text, text
    assert "Undefined function 'fpow2i'" in text, text


if __name__ == "__main__":
    test_pub_export_and_same_library_internal()
    test_stdlib_internal_is_hidden()
    print("PUB VISIBILITY PASS")
