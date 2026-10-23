#!/usr/bin/env python3
"""v10 `.ccr` wire format oracle tests (Task 1: header/segment table/segment bodies).

Wire contract (docs/superpowers/specs/2026-10-23-lattice-ccr-v10-design.md §3):

    Header 16B
      magic      4B = 0x31524343 ("CCR1", little-endian)
      version    4B = 0x000A0000
      seg_count  4B = 9
      flags      4B (bit 3+ reserved, must be zero)
    Segment table 9 x 12B
      tag        4B (1..9, ascending, canonical order)
      offset     4B (contiguous, first == 124)
      size       4B
    Segment bodies, canonical order:
      1 STR / 2 TYPE / 3 IFACE / 4 SYM / 5 NOD / 6 ENT / 7 REG / 8 EDG / 9 CASE

Scope: wire level only. The oracle does not interpret NOD/ENT/... business
fields; those belong to later v10 tasks.

Runs standalone (`python3 tests/selfhost/test_ccr_v10_format.py`) and is also
pytest-discoverable (plain `test_*` functions, stdlib only).
"""

import contextlib
import re
from pathlib import Path

from ccr_v10_model import (
    BODY_START,
    CcrV10Error,
    MAGIC,
    SEG_COUNT,
    SEG_TAGS,
    VERSION,
    decode,
    encode,
    flags,
    magic,
    patch_segment_entry,
    patch_u32,
    read_segment_table,
    seg_count,
    segment,
    validate,
    version,
)


# ---------------------------------------------------------------------------
# local raises() so the file stays stdlib-only and works under `python3 file.py`
# ---------------------------------------------------------------------------


class _Raises:
    value = None


@contextlib.contextmanager
def raises(exc_type):
    holder = _Raises()
    try:
        yield holder
    except exc_type as exc:
        holder.value = exc
    else:
        raise AssertionError(f"expected {exc_type.__name__}, nothing raised")


def _sample_body(tag):
    return bytes([tag, tag + 1, tag + 2])


def _sample_segments():
    return {tag: _sample_body(tag) for tag in SEG_TAGS}


def _all_empty():
    return {tag: b"" for tag in SEG_TAGS}


# ---------------------------------------------------------------------------
# 1. header fields and canonical order
# ---------------------------------------------------------------------------


def test_header_and_canonical_segment_order():
    data = encode({tag: b"\x00\x00\x00\x00" for tag in SEG_TAGS})

    assert data[:4] == b"CCR1"
    assert magic(data) == MAGIC == 0x31524343
    assert version(data) == VERSION == 0x000A0000
    assert seg_count(data) == SEG_COUNT == 9
    assert flags(data) == 0

    assert read_segment_table(data) == [
        (1, 124, 4),
        (2, 128, 4),
        (3, 132, 4),
        (4, 136, 4),
        (5, 140, 4),
        (6, 144, 4),
        (7, 148, 4),
        (8, 152, 4),
        (9, 156, 4),
    ]
    assert list(decode(data)) == [1, 2, 3, 4, 5, 6, 7, 8, 9]
    assert len(data) == 160
    assert validate(data) is None


def test_data_starts_at_124_and_last_end_is_file_length():
    data = encode(_sample_segments())
    table = read_segment_table(data)
    assert table[0][1] == BODY_START == 124

    expected = BODY_START
    for tag, offset, size in table:
        assert offset == expected, f"tag {tag}: offset {offset} != {expected}"
        expected += size
    assert expected == len(data)


# ---------------------------------------------------------------------------
# 2..10. negative fixtures: every malformed shape must be rejected
# ---------------------------------------------------------------------------


def test_rejects_v9_version():
    data = encode(_sample_segments())
    assert 589825 == 0x00090001  # v9.1
    with raises(CcrV10Error):
        validate(patch_u32(data, 4, 589825))


def test_rejects_wrong_magic():
    data = encode(_sample_segments())
    with raises(CcrV10Error):
        validate(patch_u32(data, 0, 0x31524344))  # "DCR1"


def test_rejects_seg_count_not_nine():
    data = encode(_sample_segments())
    with raises(CcrV10Error):
        validate(patch_u32(data, 8, 8))


def test_rejects_duplicate_tag():
    data = encode(_sample_segments())
    # Entry 1 claims tag 1 again; tag 2 is now absent.
    bad = patch_segment_entry(data, 1, tag=1)
    with raises(CcrV10Error) as caught:
        validate(bad)
    assert "duplicate" in str(caught.value)


def test_rejects_missing_tag():
    data = encode(_sample_segments())
    # Entry 1 jumps from tag 1 to tag 3: tag 2 is missing.
    bad = patch_segment_entry(data, 1, tag=3)
    with raises(CcrV10Error) as caught:
        validate(bad)
    assert "missing" in str(caught.value)


def test_rejects_non_contiguous_offset():
    data = encode(_sample_segments())
    # TYPE must start at 124 + size(STR); shift it one byte later.
    bad = patch_segment_entry(data, 1, offset=read_segment_table(data)[1][1] + 1)
    with raises(CcrV10Error) as caught:
        validate(bad)
    assert "contiguous" in str(caught.value)


def test_rejects_overlapping_segment():
    data = encode(_sample_segments())
    # Inflate STR so it runs past the start of TYPE.
    bad = patch_segment_entry(data, 0, size=read_segment_table(data)[0][2] + 1)
    with raises(CcrV10Error) as caught:
        validate(bad)
    assert "contiguous" in str(caught.value)


def test_rejects_out_of_bounds_segment():
    data = encode(_sample_segments())
    # Grow only the last segment: table stays contiguous, end passes EOF.
    bad = patch_segment_entry(data, 8, size=read_segment_table(data)[8][2] + 1)
    with raises(CcrV10Error) as caught:
        validate(bad)
    assert "out of bounds" in str(caught.value)


def test_rejects_trailing_byte():
    data = encode(_sample_segments())
    with raises(CcrV10Error) as caught:
        validate(data + b"\x00")
    assert "trailing" in str(caught.value)


def test_rejects_truncated_file():
    data = encode(_sample_segments())
    with raises(CcrV10Error):
        validate(data[:-1])


def test_rejects_reserved_flag_bits():
    data = encode(_sample_segments())
    with raises(CcrV10Error):
        validate(patch_u32(data, 12, 0x8))  # bit 3 is reserved


# ---------------------------------------------------------------------------
# 9..10. round trip, empty segments, determinism
# ---------------------------------------------------------------------------


def test_empty_segments_roundtrip():
    data = encode(_all_empty())
    assert len(data) == 124
    assert validate(data) is None
    assert decode(data) == _all_empty()
    assert list(decode(data)) == list(SEG_TAGS)


def test_encode_decode_round_trip():
    segments = {
        1: b"str\x00table",
        2: b"",
        3: b"iface",
        4: b"\xff\x00\x7f",
        5: bytes(range(40)),
        6: b"",
        7: b"reg" * 5,
        8: b"edg\x01\x02",
        9: b"case",
    }
    data = encode(segments)
    assert validate(data) is None
    assert decode(data) == segments
    assert list(decode(data)) == [1, 2, 3, 4, 5, 6, 7, 8, 9]
    assert segment(data, 5) == segments[5]
    assert segment(data, 6) == b""
    assert encode(decode(data)) == data


def test_deterministic_output():
    segments = _sample_segments()
    reversed_segments = {tag: segments[tag] for tag in reversed(list(SEG_TAGS))}

    first = encode(segments)
    second = encode(segments)
    assert first == second
    assert encode(reversed_segments) == first


def test_encode_rejects_missing_and_unknown_tags():
    with raises(CcrV10Error):
        encode({tag: b"" for tag in SEG_TAGS if tag != 9})
    with raises(CcrV10Error):
        encode({**{tag: b"" for tag in SEG_TAGS}, 10: b""})


def test_encode_rejects_non_bytes_body():
    segments = {tag: b"" for tag in SEG_TAGS}
    segments[5] = "not-bytes"
    with raises(CcrV10Error):
        encode(segments)


# ---------------------------------------------------------------------------
# 11. Core schema constants (static drift guard against the Python oracle)
# ---------------------------------------------------------------------------

SCHEMA_PATH = (
    Path(__file__).resolve().parent.parent.parent / "src" / "compiler" / "ccr_schema.cr"
)

# Values are the wire contract from spec §3; they must match ccr_v10_model.py.
EXPECTED_V10_CONSTANTS = {
    "CCR_V10_VERSION": 655360,  # 0x000A0000
    "CCR_V10_SEG_COUNT": 9,
    "CCR_V10_SEG_STR": 1,
    "CCR_V10_SEG_TYPE": 2,
    "CCR_V10_SEG_IFACE": 3,
    "CCR_V10_SEG_SYM": 4,
    "CCR_V10_SEG_NOD": 5,
    "CCR_V10_SEG_ENT": 6,
    "CCR_V10_SEG_REG": 7,
    "CCR_V10_SEG_EDG": 8,
    "CCR_V10_SEG_CASE": 9,
    "CCR_V10_NOD_DISK": 40,
    "CCR_V10_ENT_DISK": 24,
    "CCR_V10_REG_DISK": 24,
    "CCR_V10_EDG_DISK": 8,
    "CCR_V10_CASE_DISK": 24,
}

# `Name : int = <decimal>` — the Core constant form used in the schema file.
_SCHEMA_CONST_RE = re.compile(
    r"^\s*(CCR_V10_[A-Z0-9_]+)\s*:\s*int\s*=\s*(\d+)\s*(?://.*)?$", re.MULTILINE
)

SEGMENT_NAMES = ("STR", "TYPE", "IFACE", "SYM", "NOD", "ENT", "REG", "EDG", "CASE")


def _schema_text():
    assert SCHEMA_PATH.is_file(), f"ccr_schema.cr does not exist: {SCHEMA_PATH}"
    return SCHEMA_PATH.read_text(encoding="utf-8")


def _schema_constants(text):
    found = {}
    for name, value in _SCHEMA_CONST_RE.findall(text):
        assert name not in found, f"{name} is defined more than once"
        found[name] = int(value)
    return found


def test_schema_v10_constants_exact():
    found = _schema_constants(_schema_text())

    missing = sorted(set(EXPECTED_V10_CONSTANTS) - set(found))
    assert not missing, f"missing v10 constants: {missing}"

    for name, expected in EXPECTED_V10_CONSTANTS.items():
        assert found[name] == expected, f"{name} = {found[name]}, expected {expected}"

    extra = sorted(set(found) - set(EXPECTED_V10_CONSTANTS))
    assert not extra, f"unexpected v10 constants: {extra}"


def test_schema_v10_matches_python_oracle():
    found = _schema_constants(_schema_text())

    assert found["CCR_V10_VERSION"] == VERSION
    assert found["CCR_V10_SEG_COUNT"] == SEG_COUNT == len(SEG_TAGS)

    tags = [found[f"CCR_V10_SEG_{name}"] for name in SEGMENT_NAMES]
    assert tuple(tags) == tuple(SEG_TAGS) == tuple(range(1, 10))


def test_schema_has_no_target_layout_words():
    text = _schema_text()

    for word in ("mp_", "ABI", "align", "stride", "offset"):
        assert word not in text, f"ccr_schema.cr must not mention {word!r}"


# ---------------------------------------------------------------------------
# standalone runner
# ---------------------------------------------------------------------------


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
