#!/usr/bin/env python3
"""Integer hash map: construction parameters, growth, tombstones and probing.

The oracle is a Python dict driven by the same deterministic LCG, plus explicit
capacity/lookup assertions for the configurable constructor.
"""

import subprocess
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"

SOURCE = r"""import hashmap
import io

fn main() -> int:
    m := intMap()
    m.put(1, 10)
    m.put(2, 20)
    m.put(1, 11)
    println_i(m.size())
    println_i(m.capacity())
    println_i(m.get(1))
    println_i(m.get(2))
    println_i(m.get(3))
    m.remove(1)
    if m.has(1):
        println_i(1)
    else:
        println_i(0)
    m.put(1, 12)
    println_i(m.get(1))
    println_i(m.size())

    c : ., mut = intMapWith(4, 3, 2, 1, 1, 123, 0)
    i : ., mut = 0
    loop:
        if i >= 50:
            break
        c.put(i, i * 2)
        i = i + 1
    println_i(c.size())
    println_i(c.capacity())
    println_i(c.get(49))

    r := intMapWith(4, 3, 2, 3, 4, 12345, 3)
    state : ., mut = 1
    i = 0
    loop:
        if i >= 500:
            break
        state = (state * 1103515245 + 12345) % 2147483648
        key : ., mut = state % 100
        op : ., mut = state % 3
        if op == 0:
            r.put(key, key * 7 + i)
        else:
            if op == 1:
                r.remove(key)
            else:
                v := r.get(key)
        i = i + 1
    println_i(r.size())
    println_i(r.capacity())
    k : ., mut = 0
    loop:
        if k >= 100:
            break
        println_i(r.get(k))
        k = k + 1
    return 42
"""


def next_pow2(n):
    c = 1
    while c < n:
        c *= 2
    return c


def main():
    ref = {}
    state = 1
    cap = 4
    for i in range(500):
        state = (state * 1103515245 + 12345) % 2147483648
        key = state % 100
        op = state % 3
        if op == 0:
            if (len(ref) + 1) * 4 > cap * 3:
                nxt = cap * 3 // 2
                if nxt <= cap:
                    nxt = cap * 2
                cap = next_pow2(nxt)
            ref[key] = key * 7 + i
        elif op == 1:
            ref.pop(key, None)
    want = ["2", "16", "11", "20", "0", "0", "12", "2", "50", "64", "98", str(len(ref)), str(cap)]
    want += [str(ref.get(k, 0)) for k in range(100)]

    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        src = tmp / "map_vectors.cr"
        src.write_text(SOURCE, encoding="utf-8")
        elf = tmp / "map_vectors"
        built = subprocess.run(
            [str(COREC), "build", str(src), "-o", str(elf), "--static"],
            capture_output=True, text=True, cwd=str(BASE), timeout=120,
        )
        assert built.returncode == 0, built.stdout + built.stderr
        run = subprocess.run([str(elf)], capture_output=True, text=True, cwd=str(BASE), timeout=120)
        assert run.returncode == 42, run.stdout + run.stderr
        got = run.stdout.splitlines()
        assert len(got) == len(want), (len(got), len(want), got)
        for i, (g, w) in enumerate(zip(got, want)):
            assert g == w, f"line {i}: got {g!r} want {w!r}"
    print("INTMAP PASS")


if __name__ == "__main__":
    main()
