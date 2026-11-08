#!/usr/bin/env python3
"""Deferred type-variable solving and same-scope propagation.

Judgment basis:
  * an omitted `. ` field starts as a fresh solver variable;
  * a use point binds it (field write, field read, method argument/body relation);
  * the binding is immutable and reaches every alias created by assignment;
  * a scope that ends with a used, unsolved variable is rejected;
  * an unused variable field stays a zero-size witness.

Core has no built-in containers. These tests define a local map-like struct,
the same path an imported standard-library generic type would use.
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
    out = "/tmp/_solver_" + name
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


MAP = """struct MapLike:
    keys: .
    values: .
    cap: int
impl MapLike:
    fn put(self, k: ., v: .) -> int:
        self.keys = k
        self.values = v
        return 1
    fn same(&self, k: .) -> bool:
        return self.keys == k
"""

DIRECT = MAP + """fn main() -> int:
    m := MapLike { cap = 0 }
    m.keys = "a"
    m.values = 7
    n := m
    if n.keys != "a":
        return 1
    if n.values != 7:
        return 2
    return 0
"""

ALIAS_FIRST = MAP + """fn main() -> int:
    m := MapLike { cap = 0 }
    n := m
    m.keys = "a"
    m.values = 7
    if n.keys != "a":
        return 1
    if n.values != 7:
        return 2
    return 0
"""

INDEPENDENT = MAP + """fn main() -> int:
    m := MapLike { cap = 0 }
    q := MapLike { cap = 1 }
    m.keys = "a"
    m.values = 7
    q.keys = 9
    q.values = true
    if m.keys != "a" || m.values != 7:
        return 1
    if q.keys != 9 || q.values != true:
        return 2
    return 0
"""

METHOD = MAP + """fn main() -> int:
    m := MapLike { cap = 0 }
    n := m
    m.put("a", 7)
    if n.keys != "a":
        return 1
    if n.values != 7:
        return 2
    if !m.same("a"):
        return 3
    q := MapLike { cap = 1 }
    q.put(9, true)
    if q.keys != 9 || q.values != true:
        return 4
    return 0
"""

IMMUTABLE = MAP + """fn main() -> int:
    m := MapLike { cap = 0 }
    m.put("a", 1)
    m.put(2, 3)
    return 0
"""

UNBOUND_USED = MAP + """fn main() -> int:
    m := MapLike { cap = 0 }
    n := m
    return n.keys.len()
"""

WITNESS = MAP + """fn main() -> int:
    m := MapLike { cap = 0 }
    if m.cap != 0:
        return 1
    return 0
"""


def main():
    ok = []
    ok.append(build_run("direct", DIRECT, 0))
    ok.append(build_run("alias_first", ALIAS_FIRST, 0))
    ok.append(build_run("independent", INDEPENDENT, 0))
    ok.append(build_run("method", METHOD, 0))
    ok.append(build_run("witness", WITNESS, 0))
    ok.append(rejected("immutable_rebinding", IMMUTABLE))
    ok.append(rejected("unbound_used_field", UNBOUND_USED))
    passed = sum(1 for x in ok if x)
    print(f"{passed}/{len(ok)} passed")
    return 0 if passed == len(ok) else 1


if __name__ == "__main__":
    raise SystemExit(main())
