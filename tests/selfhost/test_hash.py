#!/usr/bin/env python3
"""stdlib hash surface: CRC-32, SHA-256, HMAC, HKDF, PBKDF2.

The oracle is Python's hashlib/hmac plus a literal CRC-32 implementation, so
the fixtures keep a second implementation of every algorithm rather than
hard-coding one result per case.
"""

import hashlib
import hmac
import subprocess
import tempfile
import zlib
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"

SOURCE = r"""import io
import fmt
import hash

fn repeatByte(b: int, n: int) -> string:
    s : ., mut = ""
    i : ., mut = 0
    loop:
        if i >= n:
            break
        s = s + chr(b)
        i = i + 1
    return s

fn rangeBytes(start: int, n: int) -> string:
    s : ., mut = ""
    i : ., mut = 0
    loop:
        if i >= n:
            break
        s = s + chr(start + i)
        i = i + 1
    return s

fn main() -> int:
    println(crc32Hex(""))
    println(crc32Hex("123456789"))
    println_i(crc32With("123456789", 0, 3988292384))
    println_i(crc32With("123456789", 4294967295, 2197175160))
    s : ., mut = crc32Init(4294967295)
    s = crc32Update(s, "1234", 3988292384)
    s = crc32Update(s, "56789", 3988292384)
    println_i(crc32Final(s))
    println(sha256Hex(""))
    println(sha256Hex("abc"))
    println(sha256Hex(repeatByte(97, 200)))
    println(hmacSha256Hex("key", "The quick brown fox jumps over the lazy dog"))
    println(hmacSha256Hex(repeatByte(11, 20), "Hi There"))
    println(hmacSha256Hex("Jefe", "what do ya want for nothing?"))
    println(hkdfSha256Hex(repeatByte(11, 22), rangeBytes(0, 13), rangeBytes(240, 10), 42))
    println(hkdfSha256Hex("password", "salt", "context", 64))
    println(pbkdf2Sha256Hex("password", "salt", 1, 32))
    println(pbkdf2Sha256Hex("password", "salt", 2, 32))
    println(pbkdf2Sha256Hex("password", "salt", 8, 20))
    return 42
"""


def crc32_ref(data, init, poly):
    c = init
    for b in data:
        c ^= b
        for _ in range(8):
            if c & 1:
                c = (c >> 1) ^ poly
            else:
                c >>= 1
    return c & 0xFFFFFFFF


def hkdf_ref(ikm, salt, info, length):
    prk = hmac.new(salt, ikm, hashlib.sha256).digest()
    out = b""
    t = b""
    counter = 1
    while len(out) < length:
        t = hmac.new(prk, t + info + bytes([counter]), hashlib.sha256).digest()
        out += t
        counter += 1
    return out[:length]


def expected_lines():
    data = b"123456789"
    init_std = 0xFFFFFFFF
    poly_std = 0xEDB88320
    poly_c = 0x82F63B78
    lines = [
        zlib.crc32(b"").to_bytes(4, "big").hex(),
        zlib.crc32(data).to_bytes(4, "big").hex(),
        str(crc32_ref(data, 0, poly_std) ^ 0xFFFFFFFF),
        str(crc32_ref(data, init_std, poly_c) ^ 0xFFFFFFFF),
        str(zlib.crc32(data) & 0xFFFFFFFF),
        hashlib.sha256(b"").hexdigest(),
        hashlib.sha256(b"abc").hexdigest(),
        hashlib.sha256(b"a" * 200).hexdigest(),
        hmac.new(b"key", b"The quick brown fox jumps over the lazy dog", hashlib.sha256).hexdigest(),
        hmac.new(b"\x0b" * 20, b"Hi There", hashlib.sha256).hexdigest(),
        hmac.new(b"Jefe", b"what do ya want for nothing?", hashlib.sha256).hexdigest(),
        hkdf_ref(b"\x0b" * 22, bytes(range(13)), bytes(range(240, 250)), 42).hex(),
        hkdf_ref(b"password", b"salt", b"context", 64).hex(),
        hashlib.pbkdf2_hmac("sha256", b"password", b"salt", 1, 32).hex(),
        hashlib.pbkdf2_hmac("sha256", b"password", b"salt", 2, 32).hex(),
        hashlib.pbkdf2_hmac("sha256", b"password", b"salt", 8, 20).hex(),
    ]
    return lines


def main():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        src = tmp / "hash_vectors.cr"
        src.write_text(SOURCE, encoding="utf-8")
        elf = tmp / "hash_vectors"
        built = subprocess.run(
            [str(COREC), "build", str(src), "-o", str(elf), "--static"],
            capture_output=True, text=True, cwd=str(BASE), timeout=120,
        )
        assert built.returncode == 0, built.stdout + built.stderr
        run = subprocess.run([str(elf)], capture_output=True, text=True, cwd=str(BASE), timeout=120)
        assert run.returncode == 42, run.stdout + run.stderr
        got = run.stdout.splitlines()
        want = expected_lines()
        assert len(got) == len(want), (len(got), len(want), got, want)
        for i, (g, w) in enumerate(zip(got, want)):
            assert g == w, f"line {i}: got {g!r} want {w!r}"
    print("HASH PASS")


if __name__ == "__main__":
    main()
