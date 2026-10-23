#!/usr/bin/env python3
"""BigInt runtime smoke test.

Builds tests/runtime/bigint_driver.cr with the existing corec and checks that
the driver exits with 0. The driver covers tagged immediates, object values,
decimal conversion, add/sub/mul/div/mod, negative values, and 2^100.
"""

import subprocess
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"
DRIVER = BASE / "tests" / "runtime" / "bigint_driver.cr"


def main() -> int:
    if not COREC.exists():
        print(f"missing {COREC}; run build_selfhost_native.py first")
        return 1
    with tempfile.TemporaryDirectory(prefix="core-bigint-") as td:
        out = Path(td) / "bigint_driver"
        build = subprocess.run(
            [str(COREC), "build", str(DRIVER), "-o", str(out), "--static", "-O", "0"],
            cwd=str(BASE),
            capture_output=True,
            text=True,
        )
        if build.returncode != 0:
            print(build.stdout)
            print(build.stderr)
            return 1
        run = subprocess.run([str(out)], cwd=str(BASE))
        if run.returncode != 0:
            print(f"driver exit {run.returncode}")
            return 1
    print("PASS bigint runtime")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
