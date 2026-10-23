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


def _run(cmd, timeout=180):
    return subprocess.run(
        [str(part) for part in cmd],
        capture_output=True,
        text=True,
        cwd=str(BASE),
        timeout=timeout,
    )


def _build_ccr(tmp, source=BRANCH_SOURCE, name="multibranch"):
    src = tmp / f"{name}.cr"
    ccr = tmp / f"{name}.ccr"
    src.write_text(source, encoding="utf-8")
    r = _run([COREC, "ccr", src, "-o", ccr])
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
        # target fact, so this fixture pins the semantic field.
        records = [
            (7, KIND_VALUE, -1, labels[0], 0),
            (2, KIND_ENUM, -1, labels[1], 0),
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
        install(
            "case_two_defaults",
            _pack_case(
                [
                    (0, KIND_DEFAULT, -1, label, 0),
                    (0, KIND_DEFAULT, -1, labels[1], 0),
                ]
            ),
        )
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
