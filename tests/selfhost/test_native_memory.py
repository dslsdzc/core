#!/usr/bin/env python3
"""Native ELF regression tests for aggregate memory addressing."""

import os
import subprocess
import sys
from pathlib import Path


BASE = Path(__file__).resolve().parents[2]
BUILD = BASE / "build"
COREC = BUILD / "corec"

CASES = [
    (
        "struct_fields",
        """
struct Pair { x: int, y: int }
fn main() -> int {
    p : ., mut = Pair { x = 10, y = 20 };
    p.x = 7;
    return p.x + p.y;
}
""",
        27,
        0,
    ),
    (
        "array_constant_index",
        """
fn main() -> int {
    arr : ., mut = [10, 20, 30];
    arr[1] = 9;
    return arr[0] + arr[1] + arr[2];
}
""",
        49,
        0,
    ),
    (
        "array_variable_index",
        """
fn main() -> int {
    arr : ., mut = [10, 20, 30];
    i := 1;
    arr[i] = 9;
    return arr[0] + arr[i] + arr[2];
}
""",
        49,
        0,
    ),
    (
        "enum_tag",
        """
enum Choice { First(int), Second(int), Third(int) }
fn main() -> int {
    c := Third(33);
    value := match c {
        First(v) => v,
        Second(v) => v,
        Third(v) => v,
    };
    return value;
}
""",
        33,
        0,
    ),
    (
        "aggregate_o1",
        """
struct Pair { x: int, y: int }
fn main() -> int {
    p := Pair { x = 7, y = 20 };
    arr : ., mut = [3, 4, 5];
    i := 1;
    arr[i] = 9;
    return p.x + p.y + arr[0] + arr[i] + arr[2];
}
""",
        44,
        1,
    ),
]


def run_case(name: str, source: str, expected: int, opt_level: int) -> bool:
    src = BUILD / f"native_memory_{name}.cr"
    binary = BUILD / f"native_memory_{name}"
    ccr = Path(str(binary) + ".ccr")
    src.write_text(source.strip() + "\n", encoding="utf-8")
    try:
        command = [
            "nice",
            "-n",
            "19",
            str(COREC),
            "build",
            str(src),
            "-o",
            str(binary),
            "--static",
            "-O",
            str(opt_level),
        ]
        built = subprocess.run(command, cwd=BASE, capture_output=True, text=True)
        if built.returncode != 0:
            print(f"[FAIL] {name}: compiler exit {built.returncode}")
            print(built.stdout)
            print(built.stderr)
            return False
        if not binary.exists():
            print(f"[FAIL] {name}: output ELF was not created")
            return False
        os.chmod(binary, 0o755)
        result = subprocess.run([str(binary)], cwd=BASE, capture_output=True, text=True)
        if result.returncode != expected:
            print(f"[FAIL] {name}: expected {expected}, got {result.returncode}")
            return False
        print(f"[PASS] {name}: {result.returncode}")
        return True
    finally:
        for artifact in (src, binary, ccr):
            try:
                artifact.unlink()
            except FileNotFoundError:
                pass


def main() -> int:
    if not COREC.exists():
        print("build/corec is missing; run `python3 build_selfhost_native.py` first")
        return 1
    BUILD.mkdir(exist_ok=True)
    passed = sum(run_case(*case) for case in CASES)
    print(f"{passed}/{len(CASES)} native aggregate tests passed")
    return 0 if passed == len(CASES) else 1


if __name__ == "__main__":
    raise SystemExit(main())
