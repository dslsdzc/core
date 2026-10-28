#!/usr/bin/env python3
"""Library visibility: pub exports, same-library internals, hidden stdlib internals."""

import subprocess
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"


def _run(args, **kwargs):
    return subprocess.run(args, capture_output=True, text=True, cwd=str(BASE), timeout=60, **kwargs)


VISIBLE_SOURCE = """import io

fn exported(x: int) -> int, pub:
    return x + 1

fn internal(x: int) -> int:
    return x + 2

fn main() -> int:
    print("visibility-ok\\n")
    if exported(40) != 41:
        return 1
    if internal(40) != 42:
        return 2
    return 42
"""

HIDDEN_SOURCE = """fn marker(), pub:
    return

fn main() -> int:
    return fpow2i(1)
"""


def test_pub_export_and_same_library_internal():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        interp = _run([str(COREC), "run", VISIBLE_SOURCE])
        assert interp.returncode == 42, interp.stdout + interp.stderr
        src = tmp / "visibility.cr"
        src.write_text(VISIBLE_SOURCE, encoding="utf-8")
        for opt in (0, 2):
            elf = tmp / f"visibility_O{opt}.elf"
            built = _run([str(COREC), "build", str(src), "-o", str(elf), "--static", "-O", str(opt)])
            assert built.returncode == 0, built.stdout + built.stderr
            run = _run([str(elf)])
            assert run.returncode == 42, run.stdout + run.stderr


PUBLIC_API_SOURCE = """import bits
import hashmap

fn main() -> int:
    x : Bits32 = bits32(7)
    if x.toInt() != 7:
        return 1
    if BITS32_MASK != 4294967295:
        return 2
    m := intMap()
    m.put(1, 10)
    if m.get(1) != 10:
        return 3
    return 42
"""

HIDDEN_TYPE_SOURCE = """import os

fn main() -> int:
    x : Argv4 = get_cwd()
    return 0
"""

HIDDEN_METHOD_SOURCE = """import hashmap

fn main() -> int:
    m := intMap()
    return m.findKey(1)
"""

PRIVATE_FIELD_SOURCE = """import bits

fn main() -> int:
    b := bits32(7)
    return b.value
"""

HIDDEN_GLOBAL_SOURCE = """import arena

fn main() -> int:
    return g_current_arena
"""

INTERFACE_SOURCE = """interface Named:
    fn name(&self) -> string

struct P:
    n: string

impl Named for P:
    fn name(&self) -> string:
        return self.n

fn main() -> int:
    p := P { n = "x" }
    if p.name() != "x":
        return 1
    return 42
"""

SHADOW_TYPE_SOURCE = """import hashmap

struct IntMap:
    z: int

fn main() -> int:
    u := IntMap { z = 5 }
    m := intMap()
    m.put(1, 2)
    return u.z + m.get(1) + 35
"""

SHADOW_GLOBAL_SOURCE = """import bits

BITS32_BITS : int = 1

fn main() -> int:
    return BITS32_BITS + 41
"""

SHADOW_FUNCTION_SOURCE = """fn fpow2i(x: int) -> int:
    return x

fn main() -> int:
    return fpow2i(42)
"""

SHADOW_METHOD_SOURCE = """import hashmap

struct IntMap:
    z: int

impl IntMap:
    fn put(self, v: int) -> int:
        return v + 1

fn main() -> int:
    u := IntMap { z = 5 }
    m := intMap()
    m.put(1, 2)
    return u.put(6) + m.get(1) + 33
"""

USER_TYPE_SOURCE = """struct Argv4:
    x: int

fn main() -> int:
    a := Argv4 { x = 1 }
    return a.x + 41
"""


# Cross-library fixture. Written into src/stdlib for the duration of the test so
# the module is owned by @std; removed in a finally block.
FIXTURE = """enum HiddenEnum:
    HA, HB

enum ShownEnum, pub:
    SA, SB

interface HiddenIface:
    fn hiddenPing(&self) -> int

interface ShownIface, pub:
    fn shownPing(&self) -> int

type HiddenAlias = int
type ShownAlias = int, pub

fn makeShownEnum() -> ShownEnum, pub:
    return SA()

fn makeShownAlias() -> ShownAlias, pub:
    return 7

struct StdP:
    n: int

impl ShownIface for StdP:
    fn shownPing(&self) -> int:
        return self.n

fn makeStdP() -> StdP, pub:
    return StdP { n = 2 }

fn callStdPing(p: StdP) -> int, pub:
    return p.shownPing()

struct HiddenStruct:
    x: int

fn makeHiddenStruct() -> HiddenStruct, pub:
    return HiddenStruct { x = 7 }

struct ShownStruct, pub:
    y: int, pub

fn makeShownStruct() -> ShownStruct, pub:
    return ShownStruct { y = 7 }
"""

FIXTURE_NAME = "zz_pub_visibility_fixture.cr"

HIDDEN_IMPL_SOURCE = """import zz_pub_visibility_fixture

struct P:
    n: int

impl HiddenIface for P:
    fn hiddenPing(&self) -> int:
        return self.n

fn main() -> int:
    return 0
"""

SHOWN_IMPL_SOURCE = """import zz_pub_visibility_fixture

struct P:
    n: int

impl ShownIface for P:
    fn shownPing(&self) -> int:
        return self.n + 41

fn main() -> int:
    p := P { n = 1 }
    return p.shownPing()
"""

ORPHAN_IMPL_SOURCE = """import zz_pub_visibility_fixture

impl ShownIface for ShownStruct:
    fn shownPing(&self) -> int:
        return self.y

fn main() -> int:
    return 0
"""

DOUBLE_IMPL_SOURCE = """import zz_pub_visibility_fixture

struct P:
    n: int

impl ShownIface for P:
    fn shownPing(&self) -> int:
        return 1

impl ShownIface for P:
    fn shownPing(&self) -> int:
        return 2

fn main() -> int:
    return 0
"""

SAME_NAME_TYPES_SOURCE = """import zz_pub_visibility_fixture

enum ShownEnum:
    UA, UB

type ShownAlias = string

interface ShownIface:
    fn userPing(&self) -> int

struct U:
    n: int

impl ShownIface for U:
    fn userPing(&self) -> int:
        return self.n + 1

fn main() -> int:
    ue := UA()
    ok : ., mut = 0
    match ue:
        UA => ok = 1, UB => ok = 2,
    se := makeShownEnum()
    match se:
        SA => ok = ok + 10, SB => ok = 0,
    x : ShownAlias = "ok"
    if str_len(x) != 2:
        return 3
    if makeShownAlias() != 7:
        return 4
    u := U { n = 1 }
    if u.userPing() != 2:
        return 5
    p := makeStdP()
    if callStdPing(p) != 2:
        return 6
    return 42
"""

HIDDEN_ALIAS_SOURCE = """import zz_pub_visibility_fixture

fn main() -> int:
    x : HiddenAlias = 1
    return x
"""

SHOWN_ALIAS_SOURCE = """import zz_pub_visibility_fixture

fn main() -> int:
    x : ShownAlias = 41
    return x + 1
"""


def _build(tmp, name, source):
    src = tmp / f"{name}.cr"
    src.write_text(source, encoding="utf-8")
    elf = tmp / f"{name}.elf"
    built = _run([str(COREC), "build", str(src), "-o", str(elf), "--static"])
    return built, elf


def test_public_types_methods_and_globals():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        built, elf = _build(tmp, "public_api", PUBLIC_API_SOURCE)
        assert built.returncode == 0, built.stdout + built.stderr
        run = _run([str(elf)])
        assert run.returncode == 42, run.stdout + run.stderr

        # A user declaration with the same source name as a loaded library
        # declaration keeps a distinct identity. The library's own code continues
        # to bind its declaration; the user code binds its own.
        for name, source in (("shadow_type", SHADOW_TYPE_SOURCE), ("shadow_global", SHADOW_GLOBAL_SOURCE),
                              ("shadow_function", SHADOW_FUNCTION_SOURCE), ("shadow_method", SHADOW_METHOD_SOURCE)):
            built, elf = _build(tmp, name, source)
            assert built.returncode == 0, (name, built.stdout + built.stderr)
            run = _run([str(elf)])
            assert run.returncode == 42, (name, run.stdout + run.stderr)

        built, _ = _build(tmp, "user_type", USER_TYPE_SOURCE)
        assert built.returncode == 0, built.stdout + built.stderr

        built, elf = _build(tmp, "interface", INTERFACE_SOURCE)
        assert built.returncode == 0, built.stdout + built.stderr
        assert _run([str(elf)]).returncode == 42


def test_hidden_types_methods_and_globals():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        for name, source, want in (
            ("hidden_type", HIDDEN_TYPE_SOURCE, "error[N01]"),
            ("hidden_method", HIDDEN_METHOD_SOURCE, "error[N08]"),
            ("hidden_global", HIDDEN_GLOBAL_SOURCE, "error[N01]"),
            ("private_field", PRIVATE_FIELD_SOURCE, "error[N03]"),
        ):
            built, _ = _build(tmp, name, source)
            text = built.stdout + built.stderr
            assert built.returncode == 1, (name, text)
            assert want in text, (name, text)


def test_cross_library_enum_interface_alias():
    fixture = BASE / "src" / "stdlib" / FIXTURE_NAME
    fixture.write_text(FIXTURE, encoding="utf-8")
    try:
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            # Hidden constructs fail at name resolution.
            for name, source, want in (
                ("hidden_enum", "import zz_pub_visibility_fixture\nfn main() -> int:\n    x : HiddenEnum = HA()\n    return 0\n", "error[N01]"),
                ("hidden_impl", HIDDEN_IMPL_SOURCE, "error[N01]"),
                ("hidden_alias", HIDDEN_ALIAS_SOURCE, "error[N01]"),
            ):
                built, _ = _build(tmp, name, source)
                text = built.stdout + built.stderr
                assert built.returncode == 1, (name, text)
                assert want in text, (name, text)
            # A hidden struct can flow through a pub function's return value, but
            # its fields must not become readable or writable across libraries.
            for name, source, want in (
                ("orphan_impl", ORPHAN_IMPL_SOURCE, "Orphan impl"),
                ("double_impl", DOUBLE_IMPL_SOURCE, "Conflicting impl"),
            ):
                built, _ = _build(tmp, name, source)
                text = built.stdout + built.stderr
                assert built.returncode == 1, (name, text)
                assert want in text, (name, text)
            built, _ = _build(tmp, "api_warning", "import zz_pub_visibility_fixture\nfn main() -> int:\n    return 0\n")
            assert "warning: public function 'makeHiddenStruct'" in (built.stdout + built.stderr), built.stdout + built.stderr
            for name, source in (
                ("hidden_field_read", "import zz_pub_visibility_fixture\nfn main() -> int:\n    h := makeHiddenStruct()\n    return h.x\n"),
                ("hidden_field_write", "import zz_pub_visibility_fixture\nfn main() -> int:\n    h := makeHiddenStruct()\n    h.x = 5\n    return 0\n"),
            ):
                built, _ = _build(tmp, name, source)
                text = built.stdout + built.stderr
                assert built.returncode == 1, (name, text)
                assert "error[N03]" in text, (name, text)
            # Public constructs remain usable across libraries.
            for name, source in (
                ("shown_enum", "import zz_pub_visibility_fixture\nfn main() -> int:\n    x : ShownEnum = SA()\n    return 42\n"),
                ("shown_impl", SHOWN_IMPL_SOURCE),
                ("shown_alias", SHOWN_ALIAS_SOURCE),
                ("shown_field", "import zz_pub_visibility_fixture\nfn main() -> int:\n    s := makeShownStruct()\n    return s.y + 35\n"),
                ("same_name_types", SAME_NAME_TYPES_SOURCE),
            ):
                built, elf = _build(tmp, name, source)
                assert built.returncode == 0, (name, built.stdout + built.stderr)
                assert _run([str(elf)]).returncode == 42, name
    finally:
        fixture.unlink(missing_ok=True)


def test_stdlib_internal_is_hidden():
    run = _run([str(COREC), "run", HIDDEN_SOURCE])
    text = run.stdout + run.stderr
    assert run.returncode == 1, text
    assert "error[N06]" in text, text
    assert "Undefined function 'fpow2i'" in text, text


if __name__ == "__main__":
    test_pub_export_and_same_library_internal()
    test_public_types_methods_and_globals()
    test_hidden_types_methods_and_globals()
    test_cross_library_enum_interface_alias()
    test_stdlib_internal_is_hidden()
    print("PUB VISIBILITY PASS")
