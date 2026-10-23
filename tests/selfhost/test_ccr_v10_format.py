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
import os
import re
import struct
import subprocess
import tempfile
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
# 12. static: layout belongs to the target projection, not the frontend
# ---------------------------------------------------------------------------

# The semantic frontend must not ask for target byte sizes, alignments, slot
# strides, field byte offsets, or allocation byte extents. corearch
# reconstructs those from the semantic type ids plus the active target layout,
# so the same source produces the same v10 bytes on every target.
REPO_ROOT = Path(__file__).resolve().parent.parent.parent
FRONTEND_LAYOUT_FREE = (
    "src/compiler/ir_gen.cr",
    "src/compiler/ptr_analysis.cr",
    "src/compiler/provenance_verify.cr",
    "src/compiler/ccr_lower.cr",
)
FRONTEND_LAYOUT_CALLS = (
    "mp_size",
    "mp_align",
    "mp_stride",
    "mp_field_offset",
    "mp_extent",
    "mp_offset",
)
# Same target facts under new names are still target facts. The frontend must
# not grow a private copy of the target layout.
FRONTEND_TARGET_FACT_NAMES = ("word_bytes", "slot_size", "offset_bytes", "byte_offset")


def test_frontend_has_no_layout_calls():
    for path in FRONTEND_LAYOUT_FREE:
        src = (REPO_ROOT / path).read_text(encoding="utf-8")
        for name in FRONTEND_LAYOUT_CALLS + FRONTEND_TARGET_FACT_NAMES:
            assert name not in src, f"{path} still calls {name}"


def test_layout_introspection_is_a_target_query():
    """@sizeOf/@alignOf/@field ask the target descriptor; the compiler does not
    evaluate layout itself. Their results are program constants, so the same
    source keeps byte-identical v10 output."""
    ir_gen = (REPO_ROOT / "src/compiler/ir_gen.cr").read_text(encoding="utf-8")
    for name in (
        "target_introspect_size(",
        "target_introspect_align(",
        "target_introspect_field_offset(",
    ):
        assert name in ir_gen, f"ir_gen must ask the target descriptor for {name}"

    desc = (REPO_ROOT / "src/targets/x86_64/linux/elf/frontend_target.cr").read_text(
        encoding="utf-8"
    )
    for name in (
        "fn target_introspect_size(",
        "fn target_introspect_align(",
        "fn target_introspect_field_offset(",
    ):
        assert name in desc, f"target descriptor missing {name}"


def test_interp_has_no_direct_layout_calls():
    """`corec run` executes IR without a projection pass, so it asks a
    target-owned hook for the element scale. It must not reach into the
    compiler mapping interface or inline the x86 scale itself."""
    src = (REPO_ROOT / "src/compiler/interp.cr").read_text(encoding="utf-8")
    for name in ("mp_offset", "mp_stride"):
        assert name not in src, f"src/compiler/interp.cr still calls {name}"

    hook_path = REPO_ROOT / "src/arch/x86_64/x86_mapping.cr"
    hook = hook_path.read_text(encoding="utf-8")
    assert "fn interp_ptr_offset(" in hook, "missing target-owned interp offset hook"
    assert "fn interp_ptr_stride(" in hook, "missing target-owned interp stride hook"
    # The hook is a target-owned delegation, never a hardcoded x86 scale.
    hook_body = hook.split("fn interp_ptr_offset(", 1)[1]
    assert "mp_offset(" in hook_body, "interp layout hook must delegate to the target"
    assert "* 8" not in hook_body, "interp layout hook hardcodes the x86 scale"


# ---------------------------------------------------------------------------
# 13. end-to-end: corec writes v10, corearch rejects v9 and accepts v10
# ---------------------------------------------------------------------------

CORE_BASE = Path(__file__).resolve().parent.parent.parent
COREC = CORE_BASE / "build" / "corec"
COREARCH = CORE_BASE / "build" / "corearch"

# Exercises the target-fact reconstruction paths: ALLOC_ARRAY, BOUNDS_CHECK,
# DEREF, STORE_PTR, ADDR_INDEX.
E2E_SOURCE = """fn main() -> int:
    arr : ., mut = [10, 20, 30]
    i := 1
    arr[i] = 9
    p := &arr[1]
    *p = 11
    return *p + arr[0] + arr[2]
"""


def _run(cmd, **kwargs):
    return subprocess.run(
        [str(part) for part in cmd],
        capture_output=True,
        text=True,
        cwd=str(CORE_BASE),
        timeout=180,
        **kwargs,
    )


def _build_v10(tmp: Path, source: str = E2E_SOURCE, name: str = "e2e"):
    src = tmp / f"{name}.cr"
    ccr = tmp / f"{name}.ccr"
    src.write_text(source, encoding="utf-8")
    r = _run([COREC, "ccr", src, "-o", ccr])
    assert r.returncode == 0, f"corec ccr failed: {r.stdout}\n{r.stderr}"
    return ccr.read_bytes()


def _nod_records(data):
    body = segment(data, 5)
    (count,) = struct.unpack_from("<I", body, 0)
    assert len(body) == 4 + count * 40, f"NOD body {len(body)} != 4 + {count}*40"
    out = []
    for i in range(count):
        out.append(struct.unpack_from("<Ii q iii III".replace(" ", ""), body, 4 + i * 40))
    return out


def test_v10_end_to_end():
    """corec emits the v10 lattice container with canonical segment order."""
    with tempfile.TemporaryDirectory() as td:
        data = _build_v10(Path(td))

    assert magic(data) == MAGIC
    assert version(data) == VERSION == 0x000A0000
    assert seg_count(data) == SEG_COUNT == 9
    assert flags(data) & ~0x7 == 0
    assert validate(data) is None

    table = read_segment_table(data)
    assert [tag for tag, _, _ in table] == [1, 2, 3, 4, 5, 6, 7, 8, 9]
    assert table[0][1] == BODY_START == 124
    expected = BODY_START
    for tag, offset, size in table:
        assert offset == expected, f"tag {tag}: offset {offset} != {expected}"
        expected += size
    assert expected == len(data)

    # CASE is the empty table: 4B case_count = 0.
    assert segment(data, 9) == struct.pack("<I", 0)

    # ENT is 24B per record and carries no home field.
    ent = segment(data, 6)
    (ent_count,) = struct.unpack_from("<I", ent, 0)
    assert len(ent) == 4 + ent_count * 24, f"ENT body {len(ent)} != 4 + n*24"
    for i in range(ent_count):
        var_id, ver, def_nod, live_start, live_end, ent_flags = struct.unpack_from(
            "<iIiIII", ent, 4 + i * 24
        )
        assert ver >= 1
        assert live_start < live_end
        assert def_nod < 0 or def_nod == live_start
        assert ent_flags <= 0x7

    # NOD is 40B: op/dest/src1/src2/src3/type_id/flags/first_edge/edge_count.
    recs = _nod_records(data)
    assert recs
    for (op, dest, s1, s2, s3, type_id, nod_flags, fe, ec) in recs:
        assert -1 <= type_id
        assert nod_flags <= 0x7
        # No target facts in src2/src3 for the width/stride carriers.
        if op == 8:  # IR_ALLOC_ARRAY
            assert s2 == 0 and s3 == 0, f"ALLOC_ARRAY carries target facts: {s2},{s3}"
        if op in (25, 26):  # IR_DEREF / IR_STORE_PTR
            assert s3 == 0, "pointer op carries a byte extent in src3"
            if nod_flags & 4:
                base = s2 if op == 25 else dest
                assert base >= 0, "runtime pointer bound has no base reference"
        if op == 31:  # IR_ADDR_INDEX
            assert s3 == 0, "ADDR_INDEX carries a scale in src3"


def test_corearch_accepts_v10_and_rejects_v9():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_v10(tmp)
        good = tmp / "good.ccr"
        good.write_bytes(data)
        out = tmp / "good.elf"
        r = _run([COREARCH, good, "--elf", "--static", "-o", out])
        assert r.returncode == 0, f"corearch rejected v10: {r.stdout}\n{r.stderr}"
        assert out.exists()

        # A structurally coherent v9 image (8 segments, version 589825) must be
        # rejected outright, not read as a v10 file with missing segments.
        tags = list(range(1, 9))
        bodies = [struct.pack("<I", 0) for _ in tags]
        table = bytearray()
        offset = 16 + 8 * 12
        for tag, body in zip(tags, bodies):
            table += struct.pack("<III", tag, offset, len(body))
            offset += len(body)
        v9 = struct.pack("<IIII", MAGIC, 589825, 8, 0) + bytes(table) + b"".join(bodies)
        v9_path = tmp / "v9.ccr"
        v9_path.write_bytes(v9)
        r = _run([COREARCH, v9_path, "--elf", "--static", "-o", tmp / "v9.elf"])
        assert r.returncode != 0, "corearch accepted a v9 file"
        assert "invalid" in (r.stdout + r.stderr)

        # seg_count 8 on an otherwise v10 image is rejected too.
        bad = tmp / "eight.ccr"
        bad.write_bytes(patch_u32(data, 8, 8))
        r = _run([COREARCH, bad, "--elf", "--static", "-o", tmp / "eight.elf"])
        assert r.returncode != 0, "corearch accepted seg_count 8"


def _append_to_segment(data, tag, extra):
    table = read_segment_table(data)
    idx = tag - 1
    _tag, off, size = table[idx]
    d = bytearray(data)
    d[off + size:off + size] = extra
    out = bytes(d)
    out = patch_segment_entry(out, idx, size=size + len(extra))
    for j in range(idx + 1, SEG_COUNT):
        old_offset = table[j][1]
        out = patch_segment_entry(out, j, offset=old_offset + len(extra))
    return out


def _segment_offset(data, tag):
    for t, off, _size in read_segment_table(data):
        if t == tag:
            return off
    raise AssertionError(f"tag {tag} missing")


PORTABLE_SOURCE = """fn main() -> int:
    return 42
"""

SYSTEM_SOURCE = """extern fn putchar(c: int) -> int
fn main() -> int:
    return putchar(65)
"""

RUNTIME_BOUND_SOURCE = """fn main() -> int:
    a := [1, 2, 3, 4]
    i := 2
    p := &a[i]
    return *p
"""


def test_header_flags_portable_user_program():
    with tempfile.TemporaryDirectory() as td:
        data = _build_v10(Path(td), PORTABLE_SOURCE, "portable")
    f = flags(data)
    assert f & ~0x7 == 0, f"reserved header bits set: {f:#x}"
    assert f & 2 == 0, f"portable user program marked SYSTEM: {f:#x}"
    assert f in (0, 1), f"unexpected portable flags {f:#x}"


def test_header_flags_system_artifact():
    with tempfile.TemporaryDirectory() as td:
        data = _build_v10(Path(td), SYSTEM_SOURCE, "system")
    f = flags(data)
    assert f & 2 != 0, f"extern/ABI program missing SYSTEM: {f:#x}"
    assert f & 1 == 0, f"SYSTEM program also claims PORTABLE: {f:#x}"


def test_portable_system_flags_rejected():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_v10(tmp, PORTABLE_SOURCE, "flagbad")
        bad = tmp / "flagbad.ccr"
        bad.write_bytes(patch_u32(data, 12, 1 | 2))
        r = _run([COREARCH, bad, "--elf", "--static", "-o", tmp / "flagbad.elf"])
        assert r.returncode != 0, "PORTABLE+SYSTEM header accepted"
        assert "invalid" in (r.stdout + r.stderr)


def _first_node_offset(data, opcode, predicate=None):
    body = segment(data, 5)
    (count,) = struct.unpack_from("<I", body, 0)
    off = _segment_offset(data, 5) + 4
    for i in range(count):
        rec = struct.unpack_from("<Ii q iiiIII".replace(" ", ""), body, 4 + i * 40)
        if rec[0] == opcode and (predicate is None or predicate(rec)):
            return off + i * 40, rec
    raise AssertionError(f"no node with op {opcode}")


def test_old_target_facts_in_src2_src3_rejected():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_v10(tmp)
        cases = []
        off, _rec = _first_node_offset(data, 8)                 # ALLOC_ARRAY
        cases.append(("alloc_src2", off + 16, 8))
        cases.append(("alloc_src3", off + 20, 8))
        off, _rec = _first_node_offset(data, 31)                # ADDR_INDEX
        cases.append(("addr_scale", off + 20, 3))
        off, _rec = _first_node_offset(data, 25)                # DEREF
        cases.append(("deref_width", off + 20, 8))
        off, _rec = _first_node_offset(data, 26)                # STORE_PTR
        cases.append(("store_width", off + 20, 8))
        for name, field_off, value in cases:
            d = bytearray(data)
            struct.pack_into("<i", d, field_off, value)
            bad = tmp / f"{name}.ccr"
            bad.write_bytes(bytes(d))
            r = _run([COREARCH, bad, "--elf", "--static", "-o", tmp / f"{name}.elf"])
            assert r.returncode != 0, f"{name}: old target fact accepted"
            assert "invalid" in (r.stdout + r.stderr), f"{name}: missing diagnostic"


def test_ent_reserved_flags_and_trailing_rejected():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_v10(tmp)
        ent_off = _segment_offset(data, 6)
        bad_flags = bytearray(data)
        struct.pack_into("<I", bad_flags, ent_off + 4 + 20, 0x10)  # first record flags
        p1 = tmp / "entflags.ccr"
        p1.write_bytes(bytes(bad_flags))
        r = _run([COREARCH, p1, "--elf", "--static", "-o", tmp / "entflags.elf"])
        assert r.returncode != 0, "ENT reserved flag bit accepted"

        p2 = tmp / "enttrail.ccr"
        p2.write_bytes(_append_to_segment(data, 6, b"\x00"))
        r = _run([COREARCH, p2, "--elf", "--static", "-o", tmp / "enttrail.elf"])
        assert r.returncode != 0, "ENT trailing byte accepted"


def test_runtime_bound_unresolvable_rejected():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_v10(tmp, RUNTIME_BOUND_SOURCE, "rtbound")

        def has_flag(rec):
            return rec[6] & 4 != 0

        rec_off, rec = _first_node_offset(data, 25, has_flag)
        assert rec[0] == 25
        # Break the base reference so no ALLOC_ARRAY/ALLOC_STRUCT defines it.
        d = bytearray(data)
        struct.pack_into("<i", d, rec_off + 16, 999999)
        bad = tmp / "rtbound.ccr"
        bad.write_bytes(bytes(d))
        r = _run([COREARCH, bad, "--elf", "--static", "-o", tmp / "rtbound.elf"])
        assert r.returncode != 0, "unresolvable runtime bound emitted a null-only check"
        assert "invalid" in (r.stdout + r.stderr)


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
