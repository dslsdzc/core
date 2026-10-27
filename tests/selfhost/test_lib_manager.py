#!/usr/bin/env python3
"""LibManager: library identity, path ownership, dependency direction, exports."""

import subprocess
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"


def test_lib_manager_selftest():
    run = subprocess.run(
        [str(COREC), "selftest-lib"], capture_output=True, text=True, cwd=str(BASE), timeout=30
    )
    assert run.returncode == 0, run.stdout + run.stderr
    assert "lib: 18/18 ok" in run.stdout, run.stdout + run.stderr


def test_import_direction_is_enforced():
    # A user unit cannot load a @core module even with an explicit path.
    with tempfile.TemporaryDirectory() as td:
        src = Path(td) / "u.cr"
        src.write_text("import src::compiler::lib_manager\nfn main() -> int:\n    return 0\n")
        run = subprocess.run(
            [str(COREC), "check", str(src)], capture_output=True, text=True,
            cwd=str(BASE), timeout=60,
        )
        text = run.stdout + run.stderr
        assert run.returncode == 1, text
        assert "@user -> @core" in text, text

    # @std is likewise a leaf with respect to @core.
    fixture = BASE / "src" / "stdlib" / "zz_dep_direction_probe.cr"
    fixture.write_text("import src::compiler::lib_manager\nfn probe() -> int:\n    return 1\n")
    try:
        run = subprocess.run(
            [str(COREC), "check", str(fixture)], capture_output=True, text=True,
            cwd=str(BASE), timeout=60,
        )
        text = run.stdout + run.stderr
        assert run.returncode == 1, text
        assert "@std -> @core" in text, text
    finally:
        fixture.unlink(missing_ok=True)


def test_import_graph_identity():
    with tempfile.TemporaryDirectory() as td:
        d = Path(td)
        (d / "b.cr").write_text("import a\nfn fb() -> int:\n    return 2\n")
        (d / "a.cr").write_text("import b\nfn fa() -> int:\n    return 1\nfn main() -> int:\n    return fa() + fb()\n")
        run = subprocess.run(
            [str(COREC), "check", str(d / "a.cr")], capture_output=True, text=True,
            cwd=str(BASE), timeout=60,
        )
        text = run.stdout + run.stderr
        assert run.returncode == 1, text
        assert "import cycle" in text, text

    with tempfile.TemporaryDirectory() as td:
        d = Path(td)
        (d / "b.cr").write_text("import d\nfn bval() -> int:\n    return dval()\n")
        (d / "c.cr").write_text("import d\nfn cval() -> int:\n    return dval()\n")
        (d / "d.cr").write_text("fn dval() -> int:\n    return 14\n")
        src = d / "main.cr"
        src.write_text("import b\nimport c\nfn main() -> int:\n    return bval() + cval() + dval()\n")
        elf = d / "main.elf"
        built = subprocess.run(
            [str(COREC), "build", str(src), "-o", str(elf), "--static"],
            capture_output=True, text=True, cwd=str(BASE), timeout=120,
        )
        assert built.returncode == 0, built.stdout + built.stderr
        run = subprocess.run([str(elf)], capture_output=True, text=True, timeout=5)
        assert run.returncode == 42, run.stdout + run.stderr


if __name__ == "__main__":
    test_lib_manager_selftest()
    test_import_direction_is_enforced()
    test_import_graph_identity()
    print("LIB MANAGER PASS")
