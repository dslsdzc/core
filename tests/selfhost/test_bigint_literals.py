#!/usr/bin/env python3
"""Core frontend support for arbitrary precision integer literals."""

import subprocess
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"


def run(args):
    return subprocess.run(args, cwd=str(BASE), capture_output=True, text=True)


def main() -> int:
    if not COREC.exists():
        print("missing build/corec")
        return 1
    with tempfile.TemporaryDirectory(prefix="core-biglit-") as td:
        d = Path(td)
        src = d / "big.cr"
        out = d / "big.ccr"
        src.write_text(
            "fn main() -> int:\n"
            "    a := 9223372036854775808\n"
            "    b := 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF\n"
            "    if a < b:\n"
            "        return 0\n"
            "    return 1\n",
            encoding="utf-8",
        )
        r = run([str(COREC), "check", str(src)])
        if r.returncode != 0:
            print(r.stdout)
            print(r.stderr)
            return 1
        cir = d / "big.cir"
        r = run([str(COREC), "cir", str(src), "-o", str(cir)])
        if r.returncode != 0:
            print(r.stdout)
            print(r.stderr)
            return 1
        text = cir.read_text(encoding="utf-8", errors="replace")
        if "const_big" not in text:
            print("cir missing const_big node")
            return 1
        r = run([str(COREC), "ccr", str(src), "-o", str(out)])
        if r.returncode != 0:
            print(r.stdout)
            print(r.stderr)
            return 1
        if out.stat().st_size == 0:
            print("empty ccr")
            return 1
    print("PASS bigint literals")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
