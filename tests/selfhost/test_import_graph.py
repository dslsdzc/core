"""Import graph: each source file keeps its own identity.

Oracle:
  * a sibling import parses into the same program and runs;
  * a diagnostic in an imported file names that file and its file-local line;
  * two files can fail on the same line and each diagnostic keeps its own file;
  * editing only an imported file invalidates the build cache;
  * `_import.cr` contributes import edges, never declarations;
  * nested imports are discovered without concatenating source text.
"""

import os
import subprocess
import sys
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = os.environ.get("COREC_BIN") or str(BASE / "build" / "corec")


def run(cmd, timeout=120):
    try:
        return subprocess.run(cmd, cwd=BASE, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return None


def write(path, text):
    Path(path).write_text(text)


def check(name, tmp, main_text, files, want_rc, want_text=(), reject_text=()):
    root = Path(tmp) / name
    root.mkdir()
    for rel, text in files.items():
        p = root / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        write(p, text)
    main = root / "main.cr"
    write(main, main_text)
    r = run([COREC, "check", str(main)])
    if r is None:
        print(f"[FAIL] {name}: timeout")
        return False
    out = r.stdout + r.stderr
    if (r.returncode == 0) != (want_rc == 0):
        print(f"[FAIL] {name}: rc={r.returncode} want={want_rc}\n{out}")
        return False
    for needle in want_text:
        if needle not in out:
            print(f"[FAIL] {name}: missing {needle!r}\n{out}")
            return False
    for needle in reject_text:
        if needle in out:
            print(f"[FAIL] {name}: unexpected {needle!r}\n{out}")
            return False
    print(f"[PASS] {name}")
    return True


def build_and_run(name, tmp, main_text, files, want_rc):
    root = Path(tmp) / name
    root.mkdir()
    for rel, text in files.items():
        write(root / rel, text)
    main = root / "main.cr"
    write(main, main_text)
    out = root / "a.out"
    b = run([COREC, "build", str(main), "-o", str(out), "--static"], timeout=180)
    if b is None or b.returncode != 0:
        print(f"[FAIL] {name}: build failed")
        if b is not None:
            print(b.stdout + b.stderr)
        return False
    r = run([str(out)], timeout=10)
    if r is None or r.returncode != want_rc:
        got = "timeout" if r is None else r.returncode
        print(f"[FAIL] {name}: run rc={got} want={want_rc}")
        return False
    print(f"[PASS] {name}: run rc={r.returncode}")
    return True


def cache_invalidation(tmp):
    root = Path(tmp) / "cache"
    root.mkdir()
    write(root / "main.cr", "import lib\nfn main() -> int:\n    return answer()\n")
    write(root / "lib.cr", "fn answer() -> int:\n    return 42\n")
    out = root / "a.out"

    def build_run():
        b = run([COREC, "build", str(root / "main.cr"), "-o", str(out), "--static"], timeout=180)
        if b is None or b.returncode != 0:
            return None
        r = run([str(out)], timeout=10)
        return None if r is None else r.returncode

    run([COREC, "clean-cache"])
    first = build_run()
    write(root / "lib.cr", "fn answer() -> int:\n    return 7\n")
    second = build_run()
    if first != 42 or second != 7:
        print(f"[FAIL] cache_invalidation: first={first} second={second}")
        return False
    print("[PASS] cache_invalidation: imported edit rebuilds")
    return True


def main():
    ok = []
    with tempfile.TemporaryDirectory(prefix="core_import_") as tmp:
        ok.append(build_and_run(
            "two_files",
            tmp,
            "import lib\nfn main() -> int:\n    return answer()\n",
            {"lib.cr": "fn answer() -> int:\n    return 42\n"},
            42,
        ))
        ok.append(build_and_run(
            "nested_import",
            tmp,
            "import a\nfn main() -> int:\n    return a_entry()\n",
            {
                "a.cr": "import b\nfn a_entry() -> int:\n    return b_value()\n",
                "b.cr": "fn b_value() -> int:\n    return 42\n",
            },
            42,
        ))
        ok.append(check(
            "imported_diagnostic",
            tmp,
            "import bad\nfn main() -> int:\n    return bad()\n",
            {"bad.cr": "fn bad() -> int:\n    return \"s\"\n"},
            1,
            want_text=("bad.cr:2:5",),
            reject_text=("<combined>",),
        ))
        ok.append(check(
            "same_line_two_files",
            tmp,
            "import one\nimport two\nfn main() -> int:\n    return one() + two()\n",
            {
                "one.cr": "fn one() -> int:\n    return \"a\"\n",
                "two.cr": "fn two() -> int:\n    return \"b\"\n",
            },
            1,
            want_text=("one.cr:2:5", "two.cr:2:5"),
            reject_text=("<combined>",),
        ))
        ok.append(check(
            "manifest_is_not_code",
            tmp,
            "fn main() -> int:\n    return ghost()\n",
            {
                "_import.cr": "import lib\nfn ghost() -> int:\n    return 1\n",
                "lib.cr": "fn lib() -> int:\n    return 0\n",
            },
            1,
            want_text=("ghost",),
        ))
        ok.append(cache_invalidation(tmp))
    print("import graph: %d/%d" % (sum(1 for x in ok if x), len(ok)))
    return 0 if all(ok) else 1


if __name__ == "__main__":
    sys.exit(main())
