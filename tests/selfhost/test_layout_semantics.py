#!/usr/bin/env python3
"""size(T) / packed named struct / witness-field / type-variable semantics.

Judgment basis:
  * a named struct is the sum of its field sizes with no padding;
  * `layout(..., align(n))` rounds every field offset and the total size to n;
  * a type-variable field that is never read or written is a witness: size zero
    and omitted at construction;
  * an omitted but used type-variable field is rejected at instantiation;
  * bool/char arrays and tuples use the same packed element layout as structs.
"""

import os
import subprocess
import sys
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = os.environ.get("COREC_BIN") or str(BASE / "build" / "corec")


def run(cmd, timeout=180):
    return subprocess.run(cmd, cwd=BASE, capture_output=True, text=True, timeout=timeout)


def build_run(name, source, want_rc):
    fd, path = tempfile.mkstemp(suffix=".cr", dir="/tmp")
    with os.fdopen(fd, "w") as fh:
        fh.write(source)
    out = "/tmp/_layout_" + name
    try:
        b = run([COREC, "build", path, "-o", out, "--static"])
        if b.returncode != 0:
            print(f"[FAIL] {name}: build failed")
            print(b.stdout[-2000:])
            print(b.stderr[-2000:])
            return False
        r = run([out], 10)
        if r.returncode != want_rc:
            print(f"[FAIL] {name}: run rc={r.returncode} want={want_rc}")
            return False
        print(f"[PASS] {name}: rc={r.returncode}")
        return True
    finally:
        for p in (path, out, out + ".ccr", out + ".cir"):
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass


PACKED = """struct P:
    a: bool
    b: int
fn main() -> int:
    if @sizeOf(P) != 9:
        return 1
    if @alignOf(P) != 8:
        return 2
    if @field(P, "a") != 0:
        return 3
    if @field(P, "b") != 1:
        return 4
    p := P { a = true, b = 42 }
    if p.a != true:
        return 5
    if p.b != 42:
        return 6
    p.b = 7
    if p.b != 7:
        return 7
    return 0
"""

ALIGNED = """struct Q layout(packed, align(4)):
    a: bool
    b: int
fn main() -> int:
    if @sizeOf(Q) != 12:
        return 1
    if @field(Q, "b") != 4:
        return 2
    q := Q { a = true, b = 9 }
    if q.b != 9:
        return 3
    return 0
"""

WITNESS = """struct W:
    a: bool
    payload: .
fn main() -> int:
    if @sizeOf(W) != 1:
        return 1
    w := W { a = true }
    if w.a != true:
        return 2
    return 0
"""

WITNESS_DATA = """struct W:
    a: bool
    payload: .
fn main() -> int:
    if @sizeOf(W) != 9:
        return 1
    w := W { a = true, payload = 5 }
    if w.payload != 5:
        return 2
    return 0
"""

BOOL_ARRAY = """fn main() -> int:
    a := [true, false, true, true]
    if a[2] != true:
        return 1
    a[2] = false
    if a[2] != false:
        return 2
    if a[3] != true:
        return 3
    return 0
"""

CHAR_ARRAY = """fn main() -> int:
    a := ['a', 'b', 'c']
    if a[1] != 'b':
        return 1
    a[1] = 'z'
    if a[1] != 'z':
        return 2
    return 0
"""
ARRAY_SIZE = """fn main() -> int:
    if @sizeOf([bool; 4]) != 4:
        return 1
    if @sizeOf([char; 3]) != 12:
        return 2
    if @sizeOf([int; 2]) != 16:
        return 3
    return 0
"""


TUPLE = """fn main() -> int:
    t := (true, 42)
    if t . 0 != true:
        return 1
    if t . 1 != 42:
        return 2
    return 0
"""

GENERIC_DATA = """struct Holder:
    val: .
fn get(h: Holder) -> int:
    return h.val
fn main() -> int:
    h := Holder { val = 7 }
    return get(h)
"""
ENUM_FIELD = """enum E:
    A(int)
    B
struct H:
    e: E
    n: int
fn main() -> int:
    h := H { e = A(8), n = 3 }
    if h.n != 3:
        return 1
    return match h.e:
        A(v) =>:
            return v
        B =>:
            return 0
"""


UNBOUND = """struct E:
    payload: .
fn main() -> int:
    e := E {}
    return e.payload
"""


def rejected(name, source):
    fd, path = tempfile.mkstemp(suffix=".cr", dir="/tmp")
    with os.fdopen(fd, "w") as fh:
        fh.write(source)
    try:
        b = run([COREC, "check", path])
        if b.returncode == 0:
            print(f"[FAIL] {name}: unexpectedly accepted")
            return False
        print(f"[PASS] {name}: rc={b.returncode}")
        return True
    finally:
        os.unlink(path)


def main():
    ok = []
    ok.append(build_run("packed", PACKED, 0))
    ok.append(build_run("aligned", ALIGNED, 0))
    ok.append(build_run("witness", WITNESS, 0))
    ok.append(build_run("witness_data", WITNESS_DATA, 0))
    ok.append(build_run("bool_array", BOOL_ARRAY, 0))
    ok.append(build_run("char_array", CHAR_ARRAY, 0))
    ok.append(build_run("array_size", ARRAY_SIZE, 0))
    ok.append(build_run("tuple", TUPLE, 0))
    ok.append(build_run("generic_data", GENERIC_DATA, 7))
    ok.append(build_run("enum_field", ENUM_FIELD, 8))
    ok.append(rejected("unbound_type_variable", UNBOUND))
    passed = sum(1 for x in ok if x)
    print(f"{passed}/{len(ok)} passed")
    return 0 if passed == len(ok) else 1


if __name__ == "__main__":
    raise SystemExit(main())
