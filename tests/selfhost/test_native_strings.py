#!/usr/bin/env python3
"""Native ELF regression tests for string headers and formatting."""

import os
import shutil
import subprocess
from pathlib import Path


BASE = Path(__file__).resolve().parents[2]
BUILD = BASE / "build"
COREC = BUILD / "corec"
TEST_BUILD = BUILD / "test_native_strings"
SOURCE = TEST_BUILD / "native_string_lengths.cr"
BINARY = TEST_BUILD / "native_string_lengths"


def main() -> int:
    if not COREC.exists():
        print("build/corec is missing; run `python3 build_selfhost_native.py` first")
        return 1

    shutil.rmtree(TEST_BUILD, ignore_errors=True)
    TEST_BUILD.mkdir(parents=True)
    (TEST_BUILD / "src").symlink_to(BASE / "src", target_is_directory=True)
    SOURCE.write_text(
        """import fmt
import io

struct Point:
    x: int, y: int

fn main() -> int:
    one := int_str(7)
    if str_eq(one, "7") == 0:
        return 1
    many := int_str(567)
    if str_eq(many, "567") == 0:
        return 2

    joined := "AB" + "CD"
    if str_eq(joined, "ABCD") == 0:
        return 3
    println(joined)

    if str_len("hello") != 5:
        return 4
    fields := @fields(Point)
    if str_len(fields) != 3:
        return 5

    if str_eq(float_str_bits(4614253070214989087), "3.14") == 0:
        return 6
    if str_eq(float_str_bits(4611686016625948053), "2") == 0:
        return 7
    if str_eq(float_str_bits(4621819117363791539), "10") == 0:
        return 8
    if str_eq(float_str_bits(4607182415197137706), "1") == 0:
        return 9
    if str_eq(float_str_bits(4636737291326488790), "100") == 0:
        return 10
    if str_eq(float_str_bits(-4611686020228827755), "-2") == 0:
        return 11
    return 0
""",
        encoding="utf-8",
    )
    try:
        built = subprocess.run(
            [
                "nice",
                "-n",
                "19",
                str(COREC),
                "build",
                str(SOURCE),
                "-o",
                str(BINARY),
                "--static",
                "-O",
                "0",
            ],
            cwd=TEST_BUILD,
            capture_output=True,
            text=True,
            timeout=180,
        )
        if built.returncode != 0:
            print(f"[FAIL] native string build exited {built.returncode}")
            print(built.stdout)
            print(built.stderr)
            return 1
        os.chmod(BINARY, 0o755)
        result = subprocess.run(
            [str(BINARY)],
            cwd=TEST_BUILD,
            capture_output=True,
            text=True,
            timeout=30,
        )
        if result.returncode != 0:
            print(
                f"[FAIL] native string length case returned {result.returncode}"
            )
            print(result.stdout)
            print(result.stderr)
            return 1
        if result.stdout != "ABCD\n":
            print(f"[FAIL] expected concat output 'ABCD', got {result.stdout!r}")
            return 1
        print("[PASS] dynamic and static strings preserve length and content")
        return 0
    finally:
        shutil.rmtree(TEST_BUILD, ignore_errors=True)


if __name__ == "__main__":
    raise SystemExit(main())
