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


PUBLIC_API_SOURCE = """import bits
import hashmap

fn main() -> int:
    x : Bits32 = bits32(7)
    if x.toInt() != 7:
        return 1
    if BITS32_MASK != 4294967295:
        return 2
    m := intMap()
    m.put(1, 10)
    if m.get(1) != 10:
        return 3
    return 42
"""

HIDDEN_TYPE_SOURCE = """import os

fn main() -> int:
    x : Argv4 = get_cwd()
    return 0
"""

HIDDEN_METHOD_SOURCE = """import hashmap

fn main() -> int:
    m := intMap()
    return m.findKey(1)
"""

HIDDEN_GLOBAL_SOURCE = """import arena

fn main() -> int:
    return g_current_arena
"""

USER_TYPE_SOURCE = """struct Argv4:
    x: int

fn main() -> int:
    a := Argv4 { x = 1 }
    return a.x + 41
"""


def _build(tmp, name, source):
    src = tmp / f"{name}.cr"
    src.write_text(source, encoding="utf-8")
    elf = tmp / f"{name}.elf"
    built = _run([str(COREC), "build", str(src), "-o", str(elf), "--static"])
    return built, elf


def test_public_types_methods_and_globals():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        built, elf = _build(tmp, "public_api", PUBLIC_API_SOURCE)
        assert built.returncode == 0, built.stdout + built.stderr
        run = _run([str(elf)])
        assert run.returncode == 42, run.stdout + run.stderr

        built, _ = _build(tmp, "user_type", USER_TYPE_SOURCE)
        assert built.returncode == 0, built.stdout + built.stderr


def test_hidden_types_methods_and_globals():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        for name, source, want in (
            ("hidden_type", HIDDEN_TYPE_SOURCE, "error[N01]"),
            ("hidden_method", HIDDEN_METHOD_SOURCE, "error[N08]"),
            ("hidden_global", HIDDEN_GLOBAL_SOURCE, "error[N01]"),
        ):
            built, _ = _build(tmp, name, source)
            text = built.stdout + built.stderr
            assert built.returncode == 1, (name, text)
            assert want in text, (name, text)


def test_stdlib_internal_is_hidden():
    run = _run([str(COREC), "run", HIDDEN_SOURCE])
    text = run.stdout + run.stderr
    assert run.returncode == 1, text
    assert "error[N06]" in text, text
    assert "Undefined function 'fpow2i'" in text, text


if __name__ == "__main__":
    test_pub_export_and_same_library_internal()
    test_public_types_methods_and_globals()
    test_hidden_types_methods_and_globals()
    test_stdlib_internal_is_hidden()
    print("PUB VISIBILITY PASS")
