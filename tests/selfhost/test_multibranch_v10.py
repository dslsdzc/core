#!/usr/bin/env python3
"""v10 multibranch wire tests: IR_MATCH opcode and the CASE segment (tag 9).

CASE is the last v10 segment. Its body is:

    case_count u32
    case_count x 24B {
        value      i64 @0    // signed scrutinee value (kind VALUE/ENUM)
        kind       u32 @8    // 0=value 1=enum 2=string 3=default
        str_index  i32 @12   // STR index, or -1 when unused
        target_nod i32 @16   // NOD id of an IR_LABEL node
        flags      u32 @20   // reserved; zero in v10
    }

The tests below check the physical layout with an independent parser, then
prove the real loader accepts IR_MATCH (54) and nonempty CASE bodies and rejects
out-of-domain case records. Synthetic CASE bodies are installed into a real
`corec` image so the rest of the container stays authoritative.

Runs standalone (`python3 tests/selfhost/test_multibranch_v10.py`) and is also
pytest-discoverable (stdlib only).
"""

import struct
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from ccr_v10_model import (  # noqa: E402
    BODY_START,
    SEG_TAGS,
    encode,
    flags,
    read_segment_table,
    segment,
    validate,
)

BASE = Path(__file__).resolve().parent.parent.parent
COREC = BASE / "build" / "corec"
COREARCH = BASE / "build" / "corearch"

IR_LABEL = 21
IR_MATCH = 54

CCR_CASE_VALUE = 0
CCR_CASE_KIND = 8
CCR_CASE_STR = 12
CCR_CASE_TARGET = 16
CCR_CASE_FLAGS = 20
CCR_CASE_DISK = 24

KIND_VALUE = 0
KIND_ENUM = 1
KIND_STRING = 2
KIND_DEFAULT = 3

CASE_TAG = 9
NOD_TAG = 5

# Two independent ifs give several LABEL nodes and a nonempty STR table, so a
# synthetic CASE can point at real graph labels and a real string.
BRANCH_SOURCE = """fn main() -> int:
    x := 1
    if x == 2:
        return 9
    if x == 3:
        return 8
    return 7
"""

EXPECTED_EXIT = 7


class CaseParseError(ValueError):
    """Raised when a CASE body is not the exact 24B table v10 defines."""


def _run(cmd, timeout=180, cwd=None):
    return subprocess.run(
        [str(part) for part in cmd],
        capture_output=True,
        text=True,
        cwd=str(cwd if cwd is not None else BASE),
        timeout=timeout,
    )


def _build_ccr(tmp, source=BRANCH_SOURCE, name="multibranch", cwd=None):
    src = tmp / f"{name}.cr"
    ccr = tmp / f"{name}.ccr"
    src.write_text(source, encoding="utf-8")
    r = _run([COREC, "ccr", src, "-o", ccr], cwd=cwd)
    assert r.returncode == 0, f"corec ccr failed: {r.stdout}\n{r.stderr}"
    data = ccr.read_bytes()
    validate(data)
    return data


def _split(data):
    bodies = {}
    for tag, offset, size in read_segment_table(data):
        bodies[tag] = data[offset : offset + size]
    return bodies


def _replace_case(data, body):
    bodies = _split(data)
    bodies[CASE_TAG] = body
    out = encode(bodies, flags=flags(data))
    validate(out)
    return out


def _pack_case(records):
    """Pack `(value, kind, str_index, target_nod, flags)` records."""
    body = struct.pack("<I", len(records))
    for value, kind, str_index, target_nod, case_flags in records:
        body += struct.pack("<qiiiI", value, kind, str_index, target_nod, case_flags)
    return body


def _parse_case(body):
    """Independent CASE parser; returns rows with their exact byte offsets."""
    if len(body) < 4:
        raise CaseParseError(f"CASE body {len(body)}B is shorter than case_count")
    (count,) = struct.unpack_from("<I", body, 0)
    expected = 4 + count * CCR_CASE_DISK
    if len(body) != expected:
        raise CaseParseError(
            f"CASE body {len(body)}B != 4 + {count}*{CCR_CASE_DISK} = {expected}B"
        )
    rows = []
    for i in range(count):
        base = 4 + i * CCR_CASE_DISK
        value = struct.unpack_from("<q", body, base + CCR_CASE_VALUE)[0]
        kind = struct.unpack_from("<I", body, base + CCR_CASE_KIND)[0]
        str_index = struct.unpack_from("<i", body, base + CCR_CASE_STR)[0]
        target = struct.unpack_from("<i", body, base + CCR_CASE_TARGET)[0]
        case_flags = struct.unpack_from("<I", body, base + CCR_CASE_FLAGS)[0]
        rows.append(
            {
                "offset": base,
                "value": value,
                "kind": kind,
                "str_index": str_index,
                "target_nod": target,
                "flags": case_flags,
            }
        )
    return rows


def _nod_records(data):
    body = segment(data, NOD_TAG)
    (count,) = struct.unpack_from("<I", body, 0)
    assert len(body) == 4 + count * 40, f"NOD body {len(body)} != 4 + {count}*40"
    records = []
    for i in range(count):
        records.append(
            struct.unpack_from("<IiqiiiIII", body, 4 + i * 40)
        )
    return records


def _label_nodes(data):
    return [i for i, rec in enumerate(_nod_records(data)) if rec[0] == IR_LABEL]


def _load_result(data, tmp, name, args=("--dump-nod-types",)):
    ccr = tmp / f"{name}.ccr"
    ccr.write_bytes(data)
    return _run([COREARCH, ccr, *args])


def _assert_loads(data, tmp, name):
    r = _load_result(data, tmp, name)
    assert r.returncode == 0, (
        f"{name}: corearch rejected a valid v10 image: {r.stdout}\n{r.stderr}"
    )
    assert "invalid .ccr file" not in (r.stdout + r.stderr), r.stdout + r.stderr


def _assert_load_rejected(data, tmp, name):
    r = _load_result(data, tmp, name)
    assert r.returncode != 0, f"{name}: malformed CASE was accepted"
    out = r.stdout + r.stderr
    assert "invalid .ccr file" in out, f"{name}: missing loader diagnostic: {out}"


# ---------------------------------------------------------------------------
# 1. CASE record layout, 24B offsets, order, deterministic bytes
# ---------------------------------------------------------------------------


def test_case_segment_24b_layout_and_order():
    with tempfile.TemporaryDirectory() as td:
        data = _build_ccr(Path(td))

    labels = _label_nodes(data)
    assert len(labels) >= 3, f"probe source has only {len(labels)} labels"
    str_count = struct.unpack_from("<I", segment(data, 1), 0)[0]
    assert str_count > 0, "probe source has no strings"

    records = [
        (7, KIND_VALUE, -1, labels[0], 0),
        (2, KIND_ENUM, -1, labels[1], 0),
        (0, KIND_STRING, 0, labels[2], 0),
        (0, KIND_DEFAULT, -1, labels[0], 0),
    ]
    body = _pack_case(records)
    out = _replace_case(data, body)

    assert segment(out, CASE_TAG) == body
    table = read_segment_table(out)
    _tag, case_off, case_size = table[CASE_TAG - 1]
    assert case_size == 4 + len(records) * CCR_CASE_DISK == 4 + 4 * 24
    assert case_off + case_size == len(out), "CASE must be the final segment"

    rows = _parse_case(segment(out, CASE_TAG))
    assert [row["value"] for row in rows] == [7, 2, 0, 0]
    assert [row["kind"] for row in rows] == list(range(4))
    assert [row["str_index"] for row in rows] == [-1, -1, 0, -1]
    assert [row["target_nod"] for row in rows] == [labels[0], labels[1], labels[2], labels[0]]
    assert [row["flags"] for row in rows] == [0, 0, 0, 0]
    # 24B stride and field offsets are the wire contract, not a comment.
    assert [row["offset"] for row in rows] == [4, 28, 52, 76]
    assert rows[0]["offset"] + CCR_CASE_VALUE == 4
    assert rows[0]["offset"] + CCR_CASE_KIND == 12
    assert rows[0]["offset"] + CCR_CASE_STR == 16
    assert rows[0]["offset"] + CCR_CASE_TARGET == 20
    assert rows[0]["offset"] + CCR_CASE_FLAGS == 24

    # Deterministic: re-encoding the split image, twice, reproduces the bytes.
    assert _pack_case(records) == body
    assert encode(_split(out), flags=flags(out)) == out
    assert encode(_split(out), flags=flags(out)) == encode(_split(out), flags=flags(out))


def test_case_segment_is_last_after_edg():
    with tempfile.TemporaryDirectory() as td:
        data = _build_ccr(Path(td))
    table = read_segment_table(data)
    assert [tag for tag, _o, _s in table] == list(SEG_TAGS)
    assert table[0][1] == BODY_START
    assert table[CASE_TAG - 1][1] + table[CASE_TAG - 1][2] == len(data)


# ---------------------------------------------------------------------------
# 2. IR_MATCH is a known v10 opcode
# ---------------------------------------------------------------------------


def test_ir_match_opcode_is_known_to_loader():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_ccr(tmp)
        labels = _label_nodes(data)
        assert len(labels) >= 3
        nod_off = None
        for tag, offset, _size in read_segment_table(data):
            if tag == NOD_TAG:
                nod_off = offset
                break
        assert nod_off is not None

        # A MATCH node plus three CASE records, as the schema expects them to
        # coexist. s2/s3 carry the CASE range: s2=0, s3=count. Removing
        # IR_MATCH from ccr_nod_src3_semantic would reject s3=3 as a legacy
        # target fact, so this fixture pins the semantic field. The range is
        # homogeneous (all VALUE + DEFAULT); mixed ENUM/VALUE is rejected by the
        # loader rule and is covered separately.
        records = [
            (7, KIND_VALUE, -1, labels[0], 0),
            (2, KIND_VALUE, -1, labels[1], 0),
            (0, KIND_DEFAULT, -1, labels[2], 0),
        ]
        with_match = _replace_case(data, _pack_case(records))
        d = bytearray(with_match)
        struct.pack_into("<I", d, nod_off + 4, IR_MATCH)       # op
        struct.pack_into("<i", d, nod_off + 4 + 16, 0)         # s2 = case start
        struct.pack_into("<i", d, nod_off + 4 + 20, len(records))  # s3 = count
        match_image = bytes(d)
        validate(match_image)
        first = _nod_records(match_image)[0]
        assert first[0] == IR_MATCH and first[3] == 0 and first[4] == len(records)
        assert len(_parse_case(segment(match_image, CASE_TAG))) == 3
        _assert_loads(match_image, tmp, "match_opcode")

        # Negative: the scrutinee cannot be the reserved -1 id.
        d = bytearray(with_match)
        struct.pack_into("<I", d, nod_off + 4, IR_MATCH)
        struct.pack_into("<q", d, nod_off + 4 + 8, -1)
        _assert_load_rejected(bytes(d), tmp, "match_scrutinee_none")

        # Negative: a negative CASE count is not a range.
        d = bytearray(with_match)
        struct.pack_into("<I", d, nod_off + 4, IR_MATCH)
        struct.pack_into("<i", d, nod_off + 4 + 20, -1)
        _assert_load_rejected(bytes(d), tmp, "match_case_count_negative")

        # Smallest reachable proof that the gate is real in this fixture: the
        # same byte patch with an opcode above the table is rejected.
        d = bytearray(data)
        struct.pack_into("<I", d, nod_off + 4, IR_MATCH + 1)
        _assert_load_rejected(bytes(d), tmp, "unknown_opcode")


# ---------------------------------------------------------------------------
# 3. A nonempty CASE table loads through the real corearch
# ---------------------------------------------------------------------------


def test_nonempty_case_loads_and_program_still_runs():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_ccr(tmp)
        labels = _label_nodes(data)
        assert len(labels) >= 3

        records = [
            (7, KIND_VALUE, -1, labels[0], 0),
            (2, KIND_ENUM, -1, labels[1], 0),
            (0, KIND_STRING, 0, labels[2], 0),
            (0, KIND_DEFAULT, -1, labels[0], 0),
        ]
        out = _replace_case(data, _pack_case(records))

        # Container and loader: CASE is consumed, not rejected as an unknown
        # shape.
        _assert_loads(out, tmp, "nonempty_case")

        ccr = tmp / "nonempty_case.elf.ccr"
        ccr.write_bytes(out)
        elf = tmp / "nonempty_case.elf"
        r = _run([COREARCH, ccr, "--elf", "--static", "-o", elf])
        assert r.returncode == 0, r.stdout + r.stderr
        assert elf.exists()
        run = subprocess.run([str(elf)], capture_output=True, text=True, timeout=10)
        assert run.returncode == EXPECTED_EXIT, (
            f"case probe returned {run.returncode}, expected {EXPECTED_EXIT}"
        )


def test_empty_case_stays_empty_and_loads():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_ccr(tmp)
    assert segment(data, CASE_TAG) == struct.pack("<I", 0)
    with tempfile.TemporaryDirectory() as td:
        _assert_loads(data, Path(td), "empty_case")


# ---------------------------------------------------------------------------
# 4. CASE domain checks: count, kind, str, target, default, flags
# ---------------------------------------------------------------------------


def test_malformed_case_records_rejected():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_ccr(tmp)
        labels = _label_nodes(data)
        nod_count = len(_nod_records(data))
        non_label = next(i for i in range(nod_count) if i not in set(labels))
        label = labels[0]

        def install(name, body):
            bad = _replace_case(data, body)
            _assert_load_rejected(bad, tmp, name)

        install("case_bad_kind", _pack_case([(1, 4, -1, label, 0)]))
        install("case_str_oob", _pack_case([(1, KIND_VALUE, 999999, label, 0)]))
        install(
            "case_string_without_str",
            _pack_case([(0, KIND_STRING, -1, label, 0)]),
        )
        install("case_target_oob", _pack_case([(1, KIND_VALUE, -1, nod_count + 10, 0)]))
        install("case_target_negative", _pack_case([(1, KIND_VALUE, -1, -2, 0)]))
        install("case_target_not_label", _pack_case([(1, KIND_VALUE, -1, non_label, 0)]))
        # Two DEFAULT rows inside one MATCH range are invalid. (The table is
        # global, so two different matches may each have one default.)
        two_defaults_body = _pack_case(
            [
                (0, KIND_DEFAULT, -1, label, 0),
                (0, KIND_DEFAULT, -1, labels[1], 0),
            ]
        )
        two_defaults = _replace_case(data, two_defaults_body)
        # Without a MATCH node, the table alone is structurally valid: this
        # pins the rejection below to the loader's per-range rule.
        _assert_loads(two_defaults, tmp, "case_two_defaults_no_range")
        nod_off = next(
            offset for tag, offset, _size in read_segment_table(data) if tag == NOD_TAG
        )
        d = bytearray(two_defaults)
        struct.pack_into("<I", d, nod_off + 4, IR_MATCH)
        struct.pack_into("<i", d, nod_off + 4 + 16, 0)  # s2 = case start
        struct.pack_into("<i", d, nod_off + 4 + 20, 2)  # s3 = case count
        _assert_load_rejected(bytes(d), tmp, "case_two_defaults_loader")
        install("case_flags_reserved", _pack_case([(1, KIND_VALUE, -1, label, 1)]))
        # Count claims two records but only one is present.
        install("case_count_truncated", struct.pack("<I", 2) + _pack_case([(1, 0, -1, label, 0)])[4:])
        # Record area is not a whole number of 24B records.
        install("case_size_partial", struct.pack("<I", 1) + b"\x00" * 20)
        # A correct count followed by a trailing byte.
        install("case_trailing_byte", _pack_case([(1, 0, -1, label, 0)]) + b"\x00")


def test_duplicate_value_cases_are_allowed_by_the_reader():
    """v10 stores order; dedupe/priority is corec's job (plan Task 2)."""
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_ccr(tmp)
        label = _label_nodes(data)[0]
        out = _replace_case(
            data,
            _pack_case(
                [
                    (1, KIND_VALUE, -1, label, 0),
                    (1, KIND_VALUE, -1, label, 0),
                ]
            ),
        )
        _assert_loads(out, tmp, "duplicate_values")


# ---------------------------------------------------------------------------
# 5. corec lowers supported match expressions to one IR_MATCH
# ---------------------------------------------------------------------------
#
# Supported arm patterns in this task: int literal, bool literal, enum variant
# with no sub-patterns, and `_`. Anything else (string/char/struct/tuple/ident
# binding, enum payload binding, optional representation dispatch) keeps the
# existing sequential lowering. These fixtures pin both sides of that boundary.

MATCH_INT_SOURCE = """fn pick(n: int) -> int:
    return match n:
        10 => 1,
        20 => 2,
        30 => 3,
        40 => 4,
        _ => 5

fn main() -> int:
    if pick(10) != 1:
        return 10
    if pick(20) != 2:
        return 20
    if pick(30) != 3:
        return 30
    if pick(40) != 4:
        return 40
    if pick(99) != 5:
        return 99
    return 42
"""

MATCH_BOOL_SOURCE = """fn pickb(b: bool) -> int:
    return match b:
        true => 7,
        false => 8,
        _ => 9

fn main() -> int:
    if pickb(true) != 7:
        return 1
    if pickb(false) != 8:
        return 2
    return 42
"""

MATCH_ENUM_SOURCE = """enum Color:
    Red, Green, Blue

fn pickc(c: Color) -> int:
    return match c:
        Red => 11,
        Green => 22,
        Blue => 33,
        _ => 44

fn main() -> int:
    if pickc(Red()) != 11:
        return 1
    if pickc(Green()) != 22:
        return 2
    if pickc(Blue()) != 33:
        return 3
    return 42
"""

# Every function here has at least one arm outside the supported set, so each
# must keep the old sequential lowering. The programs are not executed: the old
# path's string/struct semantics are Task 4/5 work, and this fixture only pins
# that corec does not encode them as MATCH.
MATCH_UNSUPPORTED_SOURCE = """struct P:
    x: int

fn pickstr(s: string) -> int:
    return match s:
        "a" => 1,
        _ => 2

fn pickid(n: int) -> int:
    return match n:
        x => x + 1

fn pickp(p: P) -> int:
    return match p:
        P { x = _ } => 1,
        _ => 2

fn main() -> int:
    return 0
"""

MATCH_TWO_FUNCS_SOURCE = """fn pick_a(n: int) -> int:
    return match n:
        1 => 10,
        2 => 20,
        _ => 30

fn pick_b(n: int) -> int:
    return match n:
        7 => 70,
        8 => 80,
        9 => 90,
        _ => 99

fn main() -> int:
    if pick_a(2) != 20:
        return 1
    if pick_b(9) != 90:
        return 2
    if pick_b(100) != 99:
        return 3
    return 42
"""


MATCH_MIXED_SOURCE = """enum Color:
    Red, Green, Blue

fn pick(c: Color) -> int:
    return match c:
        Red => 1,
        2 => 2,
        _ => 3

fn main() -> int:
    if pick(Red()) != 1:
        return 1
    if pick(Green()) != 3:
        return 2
    return 42
"""

MATCH_NO_DEFAULT_SOURCE = """fn pick(n: int) -> int:
    return match n:
        1 => 11,
        2 => 22

fn main() -> int:
    return pick(99)
"""

MATCH_NO_DEFAULT_HIT_SOURCE = """fn pick(n: int) -> int:
    return match n:
        1 => 11,
        2 => 22

fn main() -> int:
    return pick(1) + pick(2)
"""

MATCH_LOOP_SOURCE = """fn f() -> int:
    x : int
    sum : int = 0
    i : int = 0
    loop:
        if i >= 5:
            break
        match i:
            0 =>:
                x = 10
            1 =>:
                sum = sum + x
            _ =>:
                sum = sum + x
        i = i + 1
    return sum + 2

fn main() -> int:
    return f()
"""

MATCH_IDENT_FALLBACK_SOURCE = """fn pickid(n: int) -> int:
    return match n:
        x => 42

fn main() -> int:
    return pickid(7)
"""


def _match_nodes(data):
    return [i for i, rec in enumerate(_nod_records(data)) if rec[0] == IR_MATCH]


def _single_match(data):
    matches = _match_nodes(data)
    assert len(matches) == 1, f"expected exactly one MATCH, got {matches}"
    return _nod_records(data)[matches[0]]


def _assert_targets_are_labels(data, rows):
    nodes = _nod_records(data)
    for row in rows:
        target = row["target_nod"]
        assert 0 <= target < len(nodes), f"case target {target} out of range"
        assert nodes[target][0] == IR_LABEL, (
            f"case target {target} is op {nodes[target][0]}, expected IR_LABEL"
        )


def _assert_program(tmp, source, expected, opts=(0, 2), name="match_program"):
    """Run the fixture through the interpreter and static ELFs at each -O."""
    interp = _run([COREC, "run", source], cwd=BASE)
    assert interp.returncode == expected, (
        f"interp returned {interp.returncode}, expected {expected}: "
        f"{interp.stdout}\n{interp.stderr}"
    )
    src = tmp / f"{name}.cr"
    src.write_text(source, encoding="utf-8")
    for opt in opts:
        elf = tmp / f"{name}_O{opt}.elf"
        built = _run(
            [COREC, "build", src, "-o", elf, "--static", "-O", str(opt)], cwd=BASE
        )
        assert built.returncode == 0, (
            f"corec build -O {opt} failed: {built.stdout}\n{built.stderr}"
        )
        assert elf.exists(), f"corec build -O {opt} produced no ELF"
        run = subprocess.run(
            [str(elf)], capture_output=True, text=True, timeout=30, cwd=str(BASE)
        )
        assert run.returncode == expected, (
            f"ELF -O {opt} returned {run.returncode}, expected {expected}: "
            f"{run.stdout}\n{run.stderr}"
        )


def test_int_match_is_one_match_with_default_case():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_ccr(tmp, MATCH_INT_SOURCE, "match_int")
        rec = _single_match(data)
        rows = _parse_case(segment(data, CASE_TAG))

        assert rec[1] == -1, f"MATCH dest is {rec[1]}, expected -1"
        assert rec[2] >= 0, f"MATCH scrutinee is {rec[2]}, expected a var"
        assert rec[3] == 0, f"MATCH case start is {rec[3]}, expected 0"
        assert rec[4] == 5, f"MATCH case count is {rec[4]}, expected 5"
        assert len(rows) == 5, f"CASE has {len(rows)} rows, expected 5"
        assert [row["kind"] for row in rows] == [
            KIND_VALUE,
            KIND_VALUE,
            KIND_VALUE,
            KIND_VALUE,
            KIND_DEFAULT,
        ]
        assert [row["value"] for row in rows] == [10, 20, 30, 40, 0]
        assert [row["str_index"] for row in rows] == [-1, -1, -1, -1, -1]
        assert [row["flags"] for row in rows] == [0, 0, 0, 0, 0]
        _assert_targets_are_labels(data, rows)
        assert len({row["target_nod"] for row in rows}) == 5, (
            "distinct arms must target distinct body labels"
        )
        _assert_program(tmp, MATCH_INT_SOURCE, 42)


def test_bool_match_is_one_match_with_value_cases():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_ccr(tmp, MATCH_BOOL_SOURCE, "match_bool")
        rec = _single_match(data)
        rows = _parse_case(segment(data, CASE_TAG))

        assert rec[1] == -1
        assert rec[2] >= 0
        assert rec[3] == 0
        assert rec[4] == 3
        assert [row["kind"] for row in rows] == [
            KIND_VALUE,
            KIND_VALUE,
            KIND_DEFAULT,
        ]
        assert [row["value"] for row in rows] == [1, 0, 0]
        _assert_targets_are_labels(data, rows)
        _assert_program(tmp, MATCH_BOOL_SOURCE, 42)


def test_enum_match_is_one_match_with_enum_cases():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_ccr(tmp, MATCH_ENUM_SOURCE, "match_enum")
        rec = _single_match(data)
        rows = _parse_case(segment(data, CASE_TAG))

        assert rec[1] == -1
        assert rec[2] >= 0
        assert rec[3] == 0
        assert rec[4] == 4
        assert [row["kind"] for row in rows] == [
            KIND_ENUM,
            KIND_ENUM,
            KIND_ENUM,
            KIND_DEFAULT,
        ]
        enum_values = [row["value"] for row in rows[:3]]
        assert all(value > 0 for value in enum_values), enum_values
        assert len(set(enum_values)) == 3, enum_values
        assert rows[3]["value"] == 0
        _assert_targets_are_labels(data, rows)
        _assert_program(tmp, MATCH_ENUM_SOURCE, 42)


def _run_raw_elf(tmp, data, name):
    """Build an ELF through corearch in raw-int mode and return its exit code."""
    ccr = tmp / f"{name}.ccr"
    ccr.write_bytes(data)
    elf = tmp / f"{name}.elf"
    built = _run([COREARCH, ccr, "--elf", "--static", "--raw-int", "-o", elf])
    assert built.returncode == 0, (
        f"corearch --raw-int failed: {built.stdout}\n{built.stderr}"
    )
    assert elf.exists(), "corearch --raw-int produced no ELF"
    run = subprocess.run(
        [str(elf)], capture_output=True, text=True, timeout=30, cwd=str(BASE)
    )
    return run.returncode


def test_unsupported_patterns_keep_sequential_lowering():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_ccr(tmp, MATCH_UNSUPPORTED_SOURCE, "match_unsupported")
        assert _match_nodes(data) == [], (
            "string/ident-binding/struct patterns must not become MATCH"
        )
        assert segment(data, CASE_TAG) == struct.pack("<I", 0)


def test_mixed_enum_and_value_arms_fall_back():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_ccr(tmp, MATCH_MIXED_SOURCE, "match_mixed")
        assert _match_nodes(data) == [], (
            "a match mixing enum variants and value literals must keep the old path"
        )
        assert segment(data, CASE_TAG) == struct.pack("<I", 0)
        _assert_program(tmp, MATCH_MIXED_SOURCE, 42, name="match_mixed")


def test_mixed_kind_case_range_rejected_by_loader():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_ccr(tmp, MATCH_ENUM_SOURCE, "match_enum_mixed")
        rows = _parse_case(segment(data, CASE_TAG))
        records = [
            (rows[0]["value"], KIND_VALUE, -1, rows[0]["target_nod"], 0)
        ]
        for row in rows[1:]:
            records.append(
                (
                    row["value"],
                    row["kind"],
                    row["str_index"],
                    row["target_nod"],
                    row["flags"],
                )
            )
        bad = _replace_case(data, _pack_case(records))
        _assert_load_rejected(bad, tmp, "case_mixed_kinds")


def test_no_default_match_traps_on_miss():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_ccr(tmp, MATCH_NO_DEFAULT_SOURCE, "match_nodefault")
        rec = _single_match(data)
        rows = _parse_case(segment(data, CASE_TAG))
        assert rec[1] == -1
        assert rec[2] >= 0
        assert rec[4] == 2
        assert [row["kind"] for row in rows] == [KIND_VALUE, KIND_VALUE]
        _assert_targets_are_labels(data, rows)

        interp = _run([COREC, "run", MATCH_NO_DEFAULT_SOURCE], cwd=BASE)
        assert interp.returncode != 0, (
            "a MATCH miss with no DEFAULT must abort the interpreter"
        )
        assert interp.returncode not in (11, 22), (
            f"interp fell into an arm: rc={interp.returncode}"
        )

        src = tmp / "match_nodefault.cr"
        src.write_text(MATCH_NO_DEFAULT_SOURCE, encoding="utf-8")
        elf = tmp / "match_nodefault.elf"
        built = _run([COREC, "build", src, "-o", elf, "--static", "-O", "2"])
        assert built.returncode == 0, built.stdout + built.stderr
        run = subprocess.run(
            [str(elf)], capture_output=True, text=True, timeout=30, cwd=str(BASE)
        )
        assert run.returncode == -4, (
            f"ELF did not trap with SIGILL: rc={run.returncode}"
        )


def test_no_default_match_dispatches_hits():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_ccr(tmp, MATCH_NO_DEFAULT_HIT_SOURCE, "match_nodefault_hit")
        rec = _single_match(data)
        rows = _parse_case(segment(data, CASE_TAG))
        assert rec[4] == 2
        assert KIND_DEFAULT not in [row["kind"] for row in rows]
        _assert_program(
            tmp, MATCH_NO_DEFAULT_HIT_SOURCE, 33, name="match_nodefault_hit"
        )


def test_enum_match_raw_int_mode():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_ccr(tmp, MATCH_ENUM_SOURCE, "match_enum_raw")
        assert len(_match_nodes(data)) == 1
        assert _run_raw_elf(tmp, data, "match_enum_raw") == 42


def test_loop_match_all_opt_levels():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_ccr(tmp, MATCH_LOOP_SOURCE, "match_loop")
        rec = _single_match(data)
        rows = _parse_case(segment(data, CASE_TAG))
        assert rec[4] == 3
        assert [row["kind"] for row in rows] == [
            KIND_VALUE,
            KIND_VALUE,
            KIND_DEFAULT,
        ]
        _assert_program(
            tmp, MATCH_LOOP_SOURCE, 42, opts=(0, 2, 3), name="match_loop"
        )


def test_ident_fallback_executes_old_path():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_ccr(tmp, MATCH_IDENT_FALLBACK_SOURCE, "match_ident_fallback")
        assert _match_nodes(data) == []
        assert segment(data, CASE_TAG) == struct.pack("<I", 0)
        _assert_program(
            tmp,
            MATCH_IDENT_FALLBACK_SOURCE,
            42,
            name="match_ident_fallback",
        )


def test_dump_objects_prints_match_cases():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_ccr(tmp, MATCH_INT_SOURCE, "match_dump")
        ccr = tmp / "match_dump.ccr"
        ccr.write_bytes(data)
        r = _run([COREARCH, ccr, "--dump-objects"])
        assert r.returncode == 0, r.stdout + r.stderr
        lines = r.stdout.splitlines()
        match_lines = [
            line for line in lines if line.startswith("nod ") and " op 54 " in line
        ]
        assert len(match_lines) == 1, match_lines
        assert " s2 0 " in match_lines[0], match_lines[0]
        assert " s3 5 " in match_lines[0], match_lines[0]
        cases = [line for line in lines if line.startswith("case ")]
        assert len(cases) == 5, cases
        assert " value 10 " in cases[0], cases[0]
        assert " kind 0 " in cases[0], cases[0]
        assert " kind 3 " in cases[4], cases[4]
        target = int(cases[0].split("target ")[1].split()[0])
        assert _nod_records(data)[target][0] == IR_LABEL


def test_case_ranges_are_disjoint_across_functions():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_ccr(tmp, MATCH_TWO_FUNCS_SOURCE, "match_two")
        matches = _match_nodes(data)
        assert len(matches) == 2, f"expected two MATCH nodes, got {matches}"
        nodes = _nod_records(data)
        rows = _parse_case(segment(data, CASE_TAG))
        ranges = sorted((nodes[m][3], nodes[m][3] + nodes[m][4]) for m in matches)
        assert ranges[0][0] == 0, ranges
        assert ranges[0][1] == ranges[1][0], ranges
        assert ranges[-1][1] == len(rows), (ranges, len(rows))
        assert len(rows) == 3 + 4, rows
        _assert_targets_are_labels(data, rows)
        _assert_program(tmp, MATCH_TWO_FUNCS_SOURCE, 42)


def test_cir_cache_does_not_restore_match_without_cases():
    """A warm build must rebuild a MATCH function, not reuse a case-less .cir."""
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        first = _build_ccr(tmp, MATCH_INT_SOURCE, "warm", cwd=tmp)
        second = _build_ccr(tmp, MATCH_INT_SOURCE, "warm", cwd=tmp)
        assert segment(first, CASE_TAG) == segment(second, CASE_TAG)
        rows = _parse_case(segment(second, CASE_TAG))
        assert len(rows) == 5, rows
        assert _single_match(second)[4] == 5


def main():
    tests = [
        value
        for name, value in sorted(globals().items())
        if name.startswith("test_") and callable(value)
    ]
    failed = 0
    for test in tests:
        try:
            test()
        except Exception as exc:  # noqa: BLE001 - report every failure shape
            failed += 1
            print(f"FAIL {test.__name__}: {exc!r}")
        else:
            print(f"PASS {test.__name__}")
    print(f"{len(tests) - failed}/{len(tests)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
