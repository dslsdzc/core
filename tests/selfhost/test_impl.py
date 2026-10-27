#!/usr/bin/env python3
"""Native self-hosted compiler tests for impl blocks and method receivers."""

import os
import subprocess
import sys
import tempfile
from pathlib import Path


BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"


CHECK_CASES = [
    (
        "method returns constant",
        """
struct Vec:
    x: int, y: int
impl Vec:
    fn get_x(self) -> int:
        return 42
fn main() -> int:
    v := Vec { x = 10, y = 20 }
    return v.get_x()
""",
    ),
    (
        "method reads self.x",
        """
struct Vec:
    x: int, y: int
impl Vec:
    fn get_x(self) -> int:
        return self.x
fn main() -> int:
    v := Vec { x = 10, y = 20 }
    return v.get_x()
""",
    ),
    (
        "struct field read",
        """
struct Pos:
    x: int
fn main() -> int:
    p := Pos { x = 42 }
    return p.x
""",
    ),
    (
        "method with self param",
        """
struct Vec:
    x: int, y: int
impl Vec:
    fn sum(self) -> int:
        return self.x + self.y
fn main() -> int:
    v := Vec { x = 10, y = 20 }
    return v.sum()
""",
    ),
    (
        "method returning struct",
        """
struct Point:
    x: int, y: int
impl Point:
    fn double(self) -> Point:
        return Point { x = self.x * 2, y = self.y * 2 }
fn main() -> Point:
    p := Point { x = 5, y = 7 }
    return p.double()
""",
    ),
]


NATIVE_CASES = [
    (
        "self_method",
        """
struct Point:
    x: int, y: int
impl Point:
    fn get_x(&self) -> int:
        return self.x
fn main() -> int:
    p := Point { x = 42, y = 100 }
    return p.get_x()
""",
        42,
    ),
    (
        "nested_self_method",
        """
struct Acc:
    n: int
impl Acc:
    fn inner(&self) -> int:
        return self.n
    fn outer(&self) -> int:
        return self.inner() + 1
fn main() -> int:
    a := Acc { n = 41 }
    return a.outer()
""",
        42,
    ),
    (
        "mut_self_method",
        """
struct Counter:
    val: int
impl Counter:
    fn inc(&mut self):
        self.val = self.val + 1
    fn get(&self) -> int:
        return self.val
fn main() -> int:
    c : ., mut = Counter { val = 5 }
    c.inc()
    c.inc()
    return c.get()
""",
        7,
    ),
]


def run_corec(args, timeout=120):
    return subprocess.run(
        [str(COREC), *args],
        cwd=BASE,
        capture_output=True,
        text=True,
        timeout=timeout,
    )


def check_case(name, source):
    with tempfile.NamedTemporaryFile("w", suffix=".cr", delete=False) as src:
        src.write(source)
        src_path = src.name
    try:
        result = run_corec(["check", src_path])
    finally:
        os.unlink(src_path)
    if result.returncode == 0:
        print(f"[PASS] {name}")
        return True
    print(f"[FAIL] {name}: exit={result.returncode}")
    print(result.stdout)
    print(result.stderr)
    return False


def native_case(name, source, expected_exit):
    with tempfile.TemporaryDirectory(prefix="core_impl_") as tmp:
        src_path = Path(tmp) / f"{name}.cr"
        out_path = Path(tmp) / name
        src_path.write_text(source)
        built = run_corec(
            ["build", str(src_path), "--static", "-O", "0", "-o", str(out_path)]
        )
        if built.returncode != 0:
            print(f"[FAIL] {name}: build exit={built.returncode}")
            print(built.stdout)
            print(built.stderr)
            return False
        os.chmod(out_path, 0o755)
        result = subprocess.run(
            [str(out_path)], capture_output=True, text=True, timeout=30
        )
        if result.returncode == expected_exit:
            print(f"[PASS] {name}: exit={result.returncode}")
            return True
        print(f"[FAIL] {name}: expected {expected_exit}, got {result.returncode}")
        print(result.stdout)
        print(result.stderr)
        return False


def main():
    if not COREC.exists():
        print(f"[FAIL] missing native compiler: {COREC}")
        return 1
    results = [check_case(name, source) for name, source in CHECK_CASES]
    results.extend(
        native_case(name, source, expected)
        for name, source, expected in NATIVE_CASES
    )
    passed = sum(results)
    print(f"{passed}/{len(results)} passed")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
