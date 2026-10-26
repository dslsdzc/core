#!/usr/bin/env python3
"""Stdlib bits: fixed-width raw-word operations and byte-order helpers.

The interpreter has a pre-existing load8/alloc boundary (alloc buffers whose
address falls inside the intern table are read as intern indexes), so byte-order
helpers are verified on the ELF path while the pure arithmetic matrix runs on
both paths.
"""

import subprocess
import sys
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"


def _run(args, **kwargs):
    return subprocess.run(args, capture_output=True, text=True, cwd=str(BASE), timeout=60, **kwargs)


def _assert_program(tmp, source, expected, name):
    interp = _run([str(COREC), "run", source])
    assert interp.returncode == expected, (
        f"{name}: interp returned {interp.returncode}, expected {expected}\n"
        f"{interp.stdout}\n{interp.stderr}"
    )
    src = tmp / f"{name}.cr"
    src.write_text(source, encoding="utf-8")
    for opt in (0, 2):
        elf = tmp / f"{name}_O{opt}.elf"
        built = _run([str(COREC), "build", str(src), "-o", str(elf), "--static", "-O", str(opt)])
        assert built.returncode == 0, f"{name}: build -O{opt} failed\n{built.stdout}\n{built.stderr}"
        run = subprocess.run([str(elf)], capture_output=True, text=True, timeout=30)
        assert run.returncode == expected, (
            f"{name}: ELF -O{opt} returned {run.returncode}, expected {expected}\n"
            f"{run.stdout}\n{run.stderr}"
        )


def _assert_elf_only(tmp, source, expected, name):
    src = tmp / f"{name}.cr"
    src.write_text(source, encoding="utf-8")
    for opt in (0, 2):
        elf = tmp / f"{name}_O{opt}.elf"
        built = _run([str(COREC), "build", str(src), "-o", str(elf), "--static", "-O", str(opt)])
        assert built.returncode == 0, f"{name}: build -O{opt} failed\n{built.stdout}\n{built.stderr}"
        run = subprocess.run([str(elf)], capture_output=True, text=True, timeout=30)
        assert run.returncode == expected, (
            f"{name}: ELF -O{opt} returned {run.returncode}, expected {expected}\n"
            f"{run.stdout}\n{run.stderr}"
        )


BITS_SOURCE = """import bits

fn main() -> int:
    if bits32(6).and(bits32(3)).toInt() != 2:
        return 1
    if bits32(6).or(bits32(3)).toInt() != 7:
        return 2
    if bits32(6).xor(bits32(3)).toInt() != 5:
        return 3
    if bits32Max().not().toInt() != 0:
        return 4
    if bits32(0).not().toInt() != 4294967295:
        return 5
    if bits32One().shl(4).toInt() != 16:
        return 6
    if bits32(16).shr(4).toInt() != 1:
        return 7
    if bits32(1).shl(31).toInt() != 2147483648:
        return 8
    if bits32(1).shl(32).toInt() != 1:
        return 9
    if bits32(2147483649).rotl(1).toInt() != 3:
        return 10
    if bits32(3).rotr(1).toInt() != 2147483649:
        return 11
    if bits32(2147483649).rotl(32).toInt() != 2147483649:
        return 12
    if bits32(4294967295).add(bits32One()).toInt() != 0:
        return 13
    if bits32(0).sub(bits32One()).toInt() != 4294967295:
        return 14
    if bits32(4294967295).mul(bits32(4294967295)).toInt() != 1:
        return 15
    if bits32(-1).toInt() != 4294967295:
        return 16
    if bits32(4294967296).toInt() != 0:
        return 17
    if !bits32(5).eq(bits32(5)):
        return 18
    if !bits32(5).lt(bits32(6)):
        return 19
    if !bits32Zero().isZero():
        return 20
    return 42
"""

BITS_BYTES_SOURCE = """import bits

fn main() -> int:
    b := alloc(8)
    bits32StoreBE(b, 0, bits32(16909060))
    if load8(b, 0) != 1:
        return 1
    if load8(b, 1) != 2:
        return 2
    if load8(b, 2) != 3:
        return 3
    if load8(b, 3) != 4:
        return 4
    if bits32LoadBE(b, 0).toInt() != 16909060:
        return 5
    bits32StoreLE(b, 0, bits32(16909060))
    if load8(b, 0) != 4:
        return 6
    if load8(b, 3) != 1:
        return 7
    if bits32LoadLE(b, 0).toInt() != 16909060:
        return 8
    return 42
"""


def test_bits32_arithmetic_matrix():
    with tempfile.TemporaryDirectory() as td:
        _assert_program(Path(td), BITS_SOURCE, 42, "bits32")


def test_bits32_byte_order():
    with tempfile.TemporaryDirectory() as td:
        _assert_elf_only(Path(td), BITS_BYTES_SOURCE, 42, "bits32_bytes")


if __name__ == "__main__":
    test_bits32_arithmetic_matrix()
    test_bits32_byte_order()
    print("BITS PASS")
