#!/usr/bin/env python3
"""Function tail tags: `fn f(...) -> T, pub:` is parsed and stored."""

import subprocess
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"


def _run(args, **kwargs):
    return subprocess.run(args, capture_output=True, text=True, cwd=str(BASE), timeout=60, **kwargs)


PUB_SOURCE = """fn publicApi(x: int) -> int, pub:
    return x + 1

fn internalApi(x: int) -> int:
    return x + 2

fn noRet(), pub:
    return

fn main() -> int:
    noRet()
    if publicApi(40) != 41:
        return 1
    if internalApi(40) != 42:
        return 2
    return 42
"""

UNKNOWN_TAG_SOURCE = """fn bad(x: int) -> int, private:
    return x
"""


def test_pub_tail_tag_runs():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        interp = _run([str(COREC), "run", PUB_SOURCE])
        assert interp.returncode == 42, interp.stdout + interp.stderr
        src = tmp / "pub_label.cr"
        src.write_text(PUB_SOURCE, encoding="utf-8")
        for opt in (0, 2):
            elf = tmp / f"pub_label_O{opt}.elf"
            built = _run([str(COREC), "build", str(src), "-o", str(elf), "--static", "-O", str(opt)])
            assert built.returncode == 0, built.stdout + built.stderr
            run = _run([str(elf)])
            assert run.returncode == 42, run.stdout + run.stderr


def test_unknown_function_tag_is_rejected():
    run = _run([str(COREC), "run", UNKNOWN_TAG_SOURCE])
    text = run.stdout + run.stderr
    assert run.returncode == 1, text
    assert "error[TA08]" in text, text
    assert "unknown function tag 'private'" in text, text


if __name__ == "__main__":
    test_pub_tail_tag_runs()
    test_unknown_function_tag_is_rejected()
    print("PUB LABEL PASS")
