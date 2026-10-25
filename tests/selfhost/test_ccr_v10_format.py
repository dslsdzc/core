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
    DEFAULT_FLAGS,
    FLAG_PORTABLE,
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
    assert flags(data) == DEFAULT_FLAGS == FLAG_PORTABLE

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
    # HISTORICAL v9 fixture: 589825 is 0x00090001 (v9.1). Kept only to prove the
    # v10 version gate rejects the old wire format outright.
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


def _defines_fn(text, name):
    return f"fn {name}(" in text


def test_layout_introspection_is_target_owned():
    """@sizeOf/@alignOf/@field are answered by the target descriptor; the
    compiler must not define its own layout evaluator. Their results are
    program constants, so the same source keeps byte-identical v10 output."""
    introspect = (
        "target_introspect_size",
        "target_introspect_align",
        "target_introspect_field_offset",
    )
    desc = (REPO_ROOT / "src/targets/x86_64/linux/elf/frontend_target.cr").read_text(
        encoding="utf-8"
    )
    for name in introspect:
        assert _defines_fn(desc, name), f"target descriptor missing fn {name}"

    ir_gen = (REPO_ROOT / "src/compiler/ir_gen.cr").read_text(encoding="utf-8")
    for name in introspect:
        assert not _defines_fn(ir_gen, name), f"ir_gen must not define fn {name}"


def _fn_body(text, name):
    """Return the source of a top-level function up to the next top-level line."""
    marker = f"fn {name}("
    start = text.index(marker)
    lines = text[start:].splitlines()
    body = [lines[0]]
    for line in lines[1:]:
        if line and not line[0].isspace():
            break
        body.append(line)
    return "\n".join(body)


def _strip_crystal_comments(text):
    """Drop `//` comments so a structural assertion cannot match a comment."""
    out = []
    for line in text.splitlines():
        cut = line.find("//")
        out.append(line[:cut] if cut >= 0 else line)
    return "\n".join(out)


def _guard_block(text, guard):
    """The `if <guard>:` statement plus its body (comment-stripped input)."""
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if guard not in line:
            continue
        indent = _line_indent(line)
        block = [line]
        for cur in lines[i + 1:]:
            if cur.strip():
                ind = _line_indent(cur)
                if ind < indent:
                    break
                if ind == indent and cur.lstrip().startswith("if "):
                    break
            block.append(cur)
        return "\n".join(block)
    return ""


INTERP_LAYOUT_BRANCHES = {    "// IR_ALLOC_ARRAY": "interp_ptr_stride()",
    "// IR_ALLOC_STRUCT": "interp_field_stride()",
    "// IR_ADDR_INDEX": "interp_ptr_stride()",
    "// IR_SLICE": "interp_ptr_stride()",
    "// IR_LOAD_FIELD": "interp_field_stride()",
    "// IR_STORE_FIELD": "interp_field_stride()",
    "// IR_LOAD_INDEX:": "interp_ptr_stride()",
    "// IR_LOAD_INDEX_VAR:": "interp_ptr_stride()",
    "// IR_STORE_INDEX:": "interp_ptr_stride()",
    "// IR_STORE_INDEX_VAR:": "interp_ptr_stride()",
    "// IR_MAKE_ENUM": "interp_field_stride()",
}

# Slot-cell access is the interpreter's own 8-byte value model
# (`cell_load(g_ir_vals, var * 8)`), not target layout. Strip those before
# forbidding hardcoded scales in a layout branch.
INTERP_SLOT_CELL_MUL = re.compile(
    r"\b(?:g_ir_vals|g_label_poses|g_interp_stack|g_ir_func_var_start|"
    r"g_ir_func_var_count|g_ir_func_node_start|g_ir_func_node_count|"
    r"g_ir_func_name_idx|g_loop_region_enter|g_loop_region_exit)"
    r"\s*,\s*[^)\n]*\*\s*8"
)

# A hardcoded scale is a multiply/add by 8 or an assignment of 8, but `== 8`,
# `>= 8`, `<= 8`, `!= 8` are comparisons, not layout constants.
INTERP_HARDCODED_SCALE = re.compile(
    r"(?:(?<![=!<>+\-*/])\*\s*8\b)|(?:(?<![=!<>+\-*/])\+\s*8\b)|(?:(?<![=!<>])=\s*8\b)"
)


def _line_indent(line):
    return len(line) - len(line.lstrip())

def _op_guard(lines, marker_index):
    """The `if op...` guard that owns the marker: either directly below the
    marker comment, or the nearest enclosing guard above it."""
    base = _line_indent(lines[marker_index])
    j = marker_index + 1
    while j < len(lines) and (
        not lines[j].strip() or lines[j].lstrip().startswith("//")
    ):
        j += 1
    if (
        j < len(lines)
        and _line_indent(lines[j]) == base
        and lines[j].lstrip().startswith("if ")
    ):
        return j
    k = marker_index - 1
    while k >= 0:
        line = lines[k]
        if line.strip() and _line_indent(line) < base and line.lstrip().startswith("if "):
            return k
        k -= 1
    return None


def _branch_blocks(text, marker):
    """The whole `if op...` branch that contains `marker` (both interpreter paths)."""
    lines = text.splitlines()
    blocks = []
    for i, line in enumerate(lines):
        if marker not in line:
            continue
        g = _op_guard(lines, i)
        if g is None:
            continue
        guard_indent = _line_indent(lines[g])
        block = [lines[g]]
        k = g + 1
        while k < len(lines):
            cur = lines[k]
            if cur.strip():
                ind = _line_indent(cur)
                stripped = cur.lstrip()
                if ind < guard_indent:
                    break
                if ind == guard_indent and (
                    stripped.startswith("if ")
                    or stripped.startswith("// IR_")
                    or stripped.startswith("fn ")
                ):
                    break
            block.append(cur)
            k += 1
        blocks.append("\n".join(block))
    return blocks


def test_interp_has_no_direct_layout_calls():
    """`corec run` executes IR without a projection pass, so every layout branch
    asks a target-owned hook. The check walks the actual ADDR_INDEX / SLICE /
    ALLOC_ARRAY / field / index / enum branches, not just names in the file: a
    reintroduced `* 8` (or `= 8` / `+ 8`) fails even if it is spelled inline."""
    src = (REPO_ROOT / "src/compiler/interp.cr").read_text(encoding="utf-8")
    for name in ("mp_offset", "mp_stride", "mp_extent", "mp_field_offset"):
        assert name not in src, f"src/compiler/interp.cr still calls {name}"

    seen = 0
    for marker, hook in INTERP_LAYOUT_BRANCHES.items():
        blocks = _branch_blocks(src, marker)
        assert blocks, f"interp branch marker not found: {marker}"
        for block in blocks:
            seen += 1
            assert hook in block, f"{marker} must use {hook}"
            cleaned = INTERP_SLOT_CELL_MUL.sub("", block)
            found = INTERP_HARDCODED_SCALE.search(cleaned)
            assert found is None, (
                f"{marker} still hardcodes the x86 layout ({found.group(0)!r}):\n{block}"
            )
    assert seen >= 20, f"expected both interpreter paths, found {seen} branches"

    hooks = (REPO_ROOT / "src/arch/x86_64/x86_mapping.cr").read_text(encoding="utf-8")
    for fname, delegates in (
        ("interp_ptr_offset", "mp_offset("),
        ("interp_ptr_stride", "mp_stride("),
        ("interp_field_stride", "mp_stride("),
    ):
        body = _fn_body(hooks, fname)
        assert delegates in body, f"{fname} must delegate to the target mapping"
        assert "* 8" not in body, f"{fname} hardcodes the x86 scale"


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

    # CASE: 4B count followed by 24B rows. The prelude's condition branches
    # make the table nonempty even for a source with no explicit match.
    case = segment(data, 9)
    (case_count,) = struct.unpack_from("<I", case, 0)
    assert len(case) == 4 + case_count * 24, (len(case), case_count)

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


ALLOC_STRIDE_SOURCE = """fn main() -> int:
    a : [bool; 2]
    a[0] = true
    a[1] = false
    if a[0]:
        return 7
    return 1
"""


def test_alloc_stride_is_element_type_driven():
    """The wire carries no stride. corearch rebuilds it from the destination
    variable's semantic array element type, not from an int-slot assumption.

    TYP_ARRAY == 2 and TI_BOOL == 2 in ast.cr; they are asserted explicitly so
    the test fails loudly if either constant drifts.
    """
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_v10(tmp, ALLOC_STRIDE_SOURCE, "allocstride")
        recs = [r for r in _nod_records(data) if r[0] == 8]
        assert recs, "no IR_ALLOC_ARRAY node in the probe"
        for rec in recs:
            assert rec[3] == 0 and rec[4] == 0, "ALLOC_ARRAY carries a stride on the wire"

        ccr = tmp / "allocstride.ccr"
        ccr.write_bytes(data)
        r = _run([COREARCH, ccr, "--dump-alloc-strides"])
        assert r.returncode == 0, r.stdout + r.stderr
        rows = [ln for ln in r.stdout.splitlines() if ln.startswith("alloc ")]
        assert rows, f"no alloc-stride rows:\n{r.stdout}"
        row = rows[0].split()
        pairs = dict(zip(row[2::2], row[3::2]))
        assert int(pairs["kind"]) == 2, f"dest type is not TYP_ARRAY: {pairs}"
        assert int(pairs["elem"]) == 2, f"element row is not TI_BOOL: {pairs}"
        assert int(pairs["stride"]) == 8, f"unexpected reconstructed stride: {pairs}"

        out = tmp / "allocstride.elf"
        r = _run([COREARCH, ccr, "--elf", "--static", "-o", out])
        assert r.returncode == 0, r.stdout + r.stderr
        run = subprocess.run([str(out)], capture_output=True, text=True, timeout=10)
        assert run.returncode == 7, (
            f"bool-array probe returned {run.returncode}, stdout={run.stdout!r}"
        )


def test_provenance_unknown_type_span_fails_closed():
    """A warm cache may miss the type row a pointer variable refers to. The pass
    must treat that as unknown (span -1) and keep the runtime bounds check even
    with a *constant* offset, never silently assume a one-cell access.

    A runtime fixture is impractical here: the unknown span only arises when the
    variable's TYPE row is outside the loaded table, which a plain source compile
    cannot produce (the frontend allocates the row). provenance_verify runs in
    corec before serialization, so corearch cannot re-run it on a doctored .ccr.
    The condition is therefore pinned structurally on comment-stripped code.
    """
    raw = (REPO_ROOT / "src/compiler/provenance_verify.cr").read_text(encoding="utf-8")
    src = _strip_crystal_comments(raw)
    for fname in ("pv_value_span", "pv_access_span"):
        body = _fn_body(src, fname)
        assert "ti < 0" in body and "ti >= g_type_count" in body, f"{fname} lacks range guard"
        assert "return -1" in body, f"{fname} does not fail closed"

    verify = _fn_body(src, "provenance_verify_func")
    assert "span > 0" in verify, "static proof must require a known span"

    # The runtime trigger must combine a dynamic offset with an unknown span,
    # and must actually set the flag on the next statement.
    vlines = verify.splitlines()
    trigger = None
    for i, line in enumerate(vlines):
        if line.strip().startswith("if ") and ("span <= 0" in line or "span < 0" in line):
            trigger = i
            break
    assert trigger is not None, "missing unknown-span runtime trigger"
    assert "off < 0" in vlines[trigger], "runtime trigger drops the dynamic-offset case"
    assert "||" in vlines[trigger], "runtime trigger must be a disjunction"
    nxt = next(ln.strip() for ln in vlines[trigger + 1:] if ln.strip())
    assert nxt == "needs_runtime = 1", f"runtime trigger does not set the flag: {nxt!r}"

    guards = [ln.strip() for ln in vlines if "runtime_targets" in ln and "if " in ln]
    single = [ln for ln in guards if "runtime_targets == 1" in ln]
    multi = [ln for ln in guards if "runtime_targets > 1" in ln]
    assert len(single) == 1 and len(multi) == 1, guards
    assert "needs_runtime" in single[0], "single-target marker ignores unknown span"
    assert "needs_runtime" in multi[0], "multiple-target error ignores unknown span"
    assert "runtime_targets = runtime_targets + 1" in verify, "runtime fallback was removed"

    # The backend must emit a real bounds check (not only a null check) whenever
    # the frontend marked a runtime bound in s3.
    instr = _strip_crystal_comments(
        (REPO_ROOT / "src/arch/x86_64/instr.cr").read_text(encoding="utf-8")
    )
    for guard in ("if op == IR_DEREF && d >= 0:", "if op == IR_STORE_PTR:"):
        block = _guard_block(instr, guard)
        assert block, f"missing backend branch {guard}"
        assert "s3 != 0" in block, f"{guard} does not emit a bounds check for s3 != 0"


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

        # HISTORICAL v9 fixture: 589825 (v9.1) must stay rejected; it is not a
        # supported conversion input.
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

# Direct raw ABI call: the graph must make this SYSTEM even though no extern or
# raw-int build mode is involved.
RAW_CALL_SOURCE = """fn main() -> int:
    b := alloc(16)
    cell_store(b, 0, 7)
    return cell_load(b, 0)
"""


def test_header_flags_minimal_program_is_system():
    """Every compiled program is SYSTEM while raw stdlib/runtime ABI remains.

    The compiler injects runtime functions that call raw builtins (load8/store8/
    cell_load/...), so a minimal user program is not an isolated graph. PORTABLE
    cannot be truthfully produced by the current e2e pipeline; the graph-level
    classifier (not this test) decides the header.
    """
    with tempfile.TemporaryDirectory() as td:
        data = _build_v10(Path(td), PORTABLE_SOURCE, "portable")
    f = flags(data)
    assert f & ~0x7 == 0, f"reserved header bits set: {f:#x}"
    assert f & 2 != 0, f"raw runtime injection did not mark SYSTEM: {f:#x}"
    assert f & 1 == 0, f"SYSTEM program also claims PORTABLE: {f:#x}"


def test_header_flags_system_artifact():
    with tempfile.TemporaryDirectory() as td:
        data = _build_v10(Path(td), SYSTEM_SOURCE, "system")
    f = flags(data)
    assert f & 2 != 0, f"extern/ABI program missing SYSTEM: {f:#x}"
    assert f & 1 == 0, f"SYSTEM program also claims PORTABLE: {f:#x}"


def test_header_flags_raw_abi_call_is_system():
    """A direct raw ABI call is a SYSTEM boundary at graph level.

    cell_store/cell_load are retained SYSTEM runtime builtins. The header must
    say SYSTEM (bit 2), not PORTABLE (bit 1), even without extern/raw-int mode.
    """
    with tempfile.TemporaryDirectory() as td:
        data = _build_v10(Path(td), RAW_CALL_SOURCE, "rawcall")
    f = flags(data)
    assert f & 2 != 0, f"raw ABI call missing SYSTEM: {f:#x}"
    assert f & 1 == 0, f"raw ABI call also claims PORTABLE: {f:#x}"


def test_portable_header_with_raw_abi_call_rejected():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_v10(tmp, RAW_CALL_SOURCE, "rawcallportable")
        bad = tmp / "rawcallportable.ccr"
        # Downgrade the truthful SYSTEM header to PORTABLE. The loader's graph
        # classifier must reject it, not trust the header word.
        bad.write_bytes(patch_u32(data, 12, 1))
        r = _run([COREARCH, bad, "--elf", "--static", "-o", tmp / "rawcallportable.elf"])
        assert r.returncode != 0, "PORTABLE header with a raw ABI call accepted"
        assert "invalid" in (r.stdout + r.stderr)


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


def _reject_mutated(data, tmp, name):
    bad = tmp / f"{name}.ccr"
    bad.write_bytes(data)
    out = tmp / f"{name}.elf"
    r = _run([COREARCH, bad, "--elf", "--static", "-o", out])
    assert r.returncode != 0, f"{name}: mutated file accepted"
    assert r.returncode > 0, f"{name}: corearch died by signal ({r.returncode})"
    assert "invalid" in (r.stdout + r.stderr), f"{name}: missing loader diagnostic"
    assert not out.exists(), f"{name}: emitted an ELF for a rejected file"


def test_untrusted_nod_operands_rejected_not_emitted():
    """Critical 2: the loader owns opcode/operand domains.

    Each mutation must produce `load_ccr == -1` (rc 1, no SIGSEGV, no ELF):
    a huge DEREF src1, an unknown opcode, a dangling branch/jump label, and a
    CONST_BIG string index outside STR.
    """
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_v10(tmp)
        off, _rec = _first_node_offset(data, 25)      # IR_DEREF
        d = bytearray(data)
        struct.pack_into("<q", d, off + 8, 2147483647)
        _reject_mutated(bytes(d), tmp, "deref_huge_var")

        # Unknown opcode in the first record.
        d = bytearray(data)
        first = _segment_offset(data, 5) + 4
        struct.pack_into("<I", d, first, 200)
        _reject_mutated(bytes(d), tmp, "unknown_opcode")

        # Branch/jump target must name a LABEL node in the same graph.
        branch_src = """fn main() -> int:
    x := 1
    if x == 1:
        return 7
    return 0
"""
        bdata = _build_v10(tmp, branch_src, "branch")
        off, _rec = _first_node_offset(bdata, 20)     # IR_JUMP
        d = bytearray(bdata)
        struct.pack_into("<q", d, off + 8, 999999)
        _reject_mutated(bytes(d), tmp, "jump_bad_label")

        # CONST_BIG src1 is a STR index.
        big_src = """fn main() -> int:
    x := 100000000000000000000
    return 0
"""
        cdata = _build_v10(tmp, big_src, "constbig")
        off, _rec = _first_node_offset(cdata, 40)
        d = bytearray(cdata)
        struct.pack_into("<q", d, off + 8, 2147483647)
        _reject_mutated(bytes(d), tmp, "constbig_bad_str")


def test_reg_cycles_and_parent_bounds_rejected():
    """Important 6: every REG record has a checked parent domain and no cycle."""
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_v10(tmp)
        reg_off = _segment_offset(data, 7)
        # First REG record is a function root: parent = -1. Self-parent it.
        d = bytearray(data)
        struct.pack_into("<i", d, reg_off + 4 + 4, 0)
        _reject_mutated(bytes(d), tmp, "reg_self_parent")
        # Parent outside [ -1, reg_count ).
        d = bytearray(data)
        (cnt,) = struct.unpack_from("<I", data, reg_off)
        struct.pack_into("<i", d, reg_off + 4 + 4, cnt + 5)
        _reject_mutated(bytes(d), tmp, "reg_parent_oob")
        # enter/exit are NOD coordinates.
        d = bytearray(data)
        (nods,) = struct.unpack_from("<I", data, _segment_offset(data, 5))
        struct.pack_into("<i", d, reg_off + 4 + 8, nods + 1)
        _reject_mutated(bytes(d), tmp, "reg_enter_oob")


def test_sym_cross_refs_rejected():
    """Important 6: SYM names/types resolve against STR/TYPE."""
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_v10(tmp)
        sym_off = _segment_offset(data, 4)
        (gc,) = struct.unpack_from("<I", data, sym_off)
        if gc > 0:
            name_off = sym_off + 4
        else:
            # globals count + no globals + func count -> first function header.
            name_off = sym_off + 8
        d = bytearray(data)
        struct.pack_into("<i", d, name_off, 2147483647)
        _reject_mutated(bytes(d), tmp, "sym_name_oob")


def test_sym_opt_meta_nonzero_rejected():
    """Critical 1: v10 SYM carries only a zero opt_meta placeholder.

    A wire-valid image that adds a REG_ASSIGN record (count=1 plus a payload)
    must be rejected by load_ccr, never loaded into g_opt_meta. The positive
    control in the same fixture proves the base image emits normally.
    """
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_v10(tmp)
        table = read_segment_table(data)
        _tag, sym_off, sym_size = table[3]                # SYM
        d = bytearray(data)
        struct.pack_into("<I", d, sym_off + sym_size - 4, 1)
        # {key=REG_ASSIGN(0), len=4, data=count(1)} appended to SYM.
        rec = struct.pack("<III", 0, 4, 1)
        bad = _append_to_segment(bytes(d), 4, rec)
        assert validate(bad) is None, "fixture must stay wire-valid"
        _reject_mutated(bad, tmp, "opt_meta_regassign")


def test_direct_runtime_abi_call_is_system():
    """Important 9: the graph-level classifier recognizes runtime/OS ABI names
    even when the call is written as an ordinary direct call."""
    abi_src = """fn main() -> int:
    return sched_call_0()
"""
    with tempfile.TemporaryDirectory() as td:
        data = _build_v10(Path(td), abi_src, "abicall")
    f = flags(data)
    assert f & 2 != 0, f"direct runtime ABI call missing SYSTEM: {f:#x}"
    assert f & 1 == 0, f"direct runtime ABI call also claims PORTABLE: {f:#x}"


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
# residual v9 surface / runtime-only entry home / raw ABI boundary
# ---------------------------------------------------------------------------


def test_ccr_io_has_no_v9_wire_surface():
    """The v10 reader/writer must not keep a v9 wire constant on any path.

    Historical v9 bytes are only valid as negative fixtures in the test suite;
    the production serializer has no v9 branch and no stale v9 version literal.
    """
    ccr_io = (REPO_ROOT / "src/compiler/ccr_io.cr").read_text(encoding="utf-8")
    code = _strip_crystal_comments(ccr_io)
    assert "589825" not in code, "ccr_io still carries the v9 wire version"
    assert "589825" not in ccr_io, "ccr_io still documents the v9 wire version"
    assert not re.search(r"ESZ_ENTRY_DISK\s*:\s*int\s*=\s*28", code), (
        "ccr_io still defines the v9 28B ENT disk record"
    )


def test_v10_ccr_io_never_reads_or_writes_home():
    """ENT.home was a v9 wire field. v10 stores 24B without it.

    The in-memory record keeps a runtime/instance slot, but the serializer must
    not consume a byte for it and no accessor may present it as a wire field.
    """
    ccr_io = (REPO_ROOT / "src/compiler/ccr_io.cr").read_text(encoding="utf-8")
    code = _strip_crystal_comments(ccr_io)
    assert "ccr_ent_home" not in code, "stale home accessor still present"

    writer = _fn_body(code, "save_ccr")
    assert "HOME" not in writer.upper(), "v10 writer still touches the home slot"

    loader = _fn_body(code, "load_ccr")
    home_lines = [ln for ln in loader.splitlines() if "HOME" in ln.upper()]
    # The only allowed mention is the runtime-only slot reset to "unassigned".
    assert len(home_lines) <= 1, f"v10 loader has home wire reads: {home_lines}"
    for line in home_lines:
        assert "-1" in line, f"v10 loader reads home from disk: {line}"


def test_entry_home_is_runtime_only():
    """The entry slot survives only as an instance-side allocator field."""
    dyn = (REPO_ROOT / "src/compiler/dyn_arr.cr").read_text(encoding="utf-8")
    dyn_code = _strip_crystal_comments(dyn)
    assert "OFF_ENTRY_RUNTIME_HOME : int = 16" in dyn_code, (
        "runtime entry-home slot missing or renamed unexpectedly"
    )
    assert not re.search(r"\bOFF_ENTRY_HOME\b", dyn_code), (
        "dyn_arr still exposes the wire-shaped OFF_ENTRY_HOME name"
    )
    compact = " ".join(dyn.replace("//", " ").split()).lower()
    assert "never serialized into `.ccr`" in compact, (
        "dyn_arr does not mark the home slot as runtime/instance only"
    )

    for path in (
        "src/compiler/ccr_io.cr",
        "src/lattice/ent_kernel.cr",
        "src/arch/x86_64/regalloc.cr",
    ):
        src = _strip_crystal_comments(
            (REPO_ROOT / path).read_text(encoding="utf-8")
        )
        assert not re.search(r"\bOFF_ENTRY_HOME\b", src), (
            f"{path} still uses the wire-shaped OFF_ENTRY_HOME name"
        )

    globals_src = (REPO_ROOT / "src/compiler/globals.cr").read_text(encoding="utf-8")
    compact_globals = " ".join(globals_src.replace("//", " ").split()).lower()
    assert "never serialized into `.ccr`" in compact_globals, (
        "globals.cr does not mark the home slot as runtime/instance only"
    )


# Raw byte builtins are a SYSTEM/runtime ABI, not ordinary language API. They
# stay because the stdlib scheduler/arena still uses them; the fixed-width
# aliases w64/r64 are retired.
RAW_RUNTIME_BUILTINS = (
    "cell_store",
    "cell_load",
    "load8",
    "store8",
    "load64",
    "w32",
    "load_str_ptr",
    "store_str_ptr",
    "_dyncpy",
)


def test_frontend_registers_no_w64_r64():
    src = (REPO_ROOT / "src/arch/x86_64/x86_frontend_abi.cr").read_text(
        encoding="utf-8"
    )
    code = _strip_crystal_comments(src)
    for retired in ("w64", "r64"):
        assert f'prelude_builtin_add("{retired}"' not in code, (
            f"retired raw builtin {retired} is still registered"
        )


def test_frontend_raw_builtins_are_system_runtime_abi():
    src = (REPO_ROOT / "src/arch/x86_64/x86_frontend_abi.cr").read_text(
        encoding="utf-8"
    )
    code = _strip_crystal_comments(src)
    for name in RAW_RUNTIME_BUILTINS:
        assert f'prelude_builtin_add("{name}"' in code, f"missing raw builtin {name}"

    marker = src[: src.index("fn x86_frontend_builtin_register")]
    assert "SYSTEM" in marker, "raw builtins are not marked as SYSTEM ABI"
    lowered = marker.lower()
    assert "raw" in lowered and "runtime" in lowered, (
        "raw builtins lack the explicit runtime/raw boundary note"
    )


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
