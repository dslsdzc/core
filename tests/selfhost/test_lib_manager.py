#!/usr/bin/env python3
"""LibManager: library identity, path ownership, dependency direction, exports."""

import subprocess
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"


def test_lib_manager_selftest():
    run = subprocess.run(
        [str(COREC), "selftest-lib"], capture_output=True, text=True, cwd=str(BASE), timeout=30
    )
    assert run.returncode == 0, run.stdout + run.stderr
    assert "lib: 14/14 ok" in run.stdout, run.stdout + run.stderr


if __name__ == "__main__":
    test_lib_manager_selftest()
    print("LIB MANAGER PASS")
