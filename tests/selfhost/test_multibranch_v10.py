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
import time
from concurrent.futures import ThreadPoolExecutor
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


def _assert_compile_rejected(tmp, source, name, needles):
    src = tmp / f"{name}.cr"
    src.write_text(source, encoding="utf-8")
    out = tmp / f"{name}.elf"
    r = _run([COREC, "build", src, "-o", out, "--static"])
    text = r.stdout + r.stderr
    assert r.returncode == 1, f"{name}: expected rc=1, got {r.returncode}: {text}"
    for needle in needles:
        assert needle in text, f"{name}: missing {needle!r}: {text}"
    assert not out.exists(), f"{name}: rejected build still produced {out}"
    return text


def _assert_soft_diagnostic(tmp, source, name, needles):
    src = tmp / f"{name}.cr"
    src.write_text(source, encoding="utf-8")
    out = tmp / f"{name}.elf"
    r = _run([COREC, "build", src, "-o", out, "--static"])
    text = r.stdout + r.stderr
    assert r.returncode == 0, f"{name}: expected rc=0, got {r.returncode}: {text}"
    for needle in needles:
        assert needle in text, f"{name}: missing {needle!r}: {text}"
    assert out.exists(), f"{name}: soft diagnostic produced no artifact"
    return text


# ---------------------------------------------------------------------------
# .cir snapshot fixtures (v25 layout)
# ---------------------------------------------------------------------------
#
# The cache lives under <cwd>/.core/cache/cir and is keyed by source path and
# function name. These helpers parse the v25 per-function snapshot independently
# so the tests can prove the semantic MATCH CASE model round-trips, and can
# tamper with exactly that section.

CIR_VERSION = 25
CIR_CASE_ROW = 24


def _cache_dir(tmp):
    return tmp / ".core" / "cache" / "cir"


def _clean_cache(tmp):
    import shutil

    shutil.rmtree(_cache_dir(tmp), ignore_errors=True)


def _cache_entry(tmp, fn):
    entries = [
        p
        for p in sorted(_cache_dir(tmp).glob("*.cir"))
        if p.name.endswith(f"::{fn}.cir")
    ]
    assert len(entries) == 1, f"{fn}: expected one cache entry, got {entries}"
    return entries[0]


def _entry_stamp(path):
    st = path.stat()
    return (st.st_size, st.st_mtime_ns)


def _cir_snapshot(data):
    """Parse a v25 snapshot. Returns section offsets and CASE model rows."""
    if len(data) < 56:
        raise AssertionError(f"snapshot too short: {len(data)}B")
    magic, ver, cid, fp, sig, name_len = struct.unpack_from("<qqqqqq", data, 0)
    assert ver == CIR_VERSION, f"snapshot version {ver} != {CIR_VERSION}"
    off = 48
    name = data[off : off + name_len]
    off += name_len

    def take_count(record_size):
        nonlocal off
        count_at = off
        count = struct.unpack_from("<q", data, off)[0]
        off += 8
        body = off
        off += count * record_size
        assert off <= len(data), "snapshot section overruns file"
        return count_at, count, body

    var_count_at, var_count, var_p = take_count(24)
    node_count_at, node_count, node_p = take_count(64)
    sg_count_at, sg_count, sg_p = take_count(48)
    edge_count_at, edge_count, edge_p = take_count(24)
    instr_count_at, instr_count, instr_p = take_count(48)

    case_p = off
    match_count = struct.unpack_from("<q", data, off)[0]
    off += 8
    matches = []
    for _ in range(match_count):
        count_off = off
        count = struct.unpack_from("<q", data, off)[0]
        off += 8
        rows_off = off
        rows = []
        for _row in range(count):
            value, kind, str_index, target_label, case_flags = struct.unpack_from(
                "<qiiiI", data, off
            )
            rows.append(
                {
                    "offset": off,
                    "value": value,
                    "kind": kind,
                    "str_index": str_index,
                    "target_label": target_label,
                    "flags": case_flags,
                }
            )
            off += CIR_CASE_ROW
        matches.append({"count_offset": count_off, "rows_offset": rows_off,
                        "count": count, "rows": rows})
    assert off <= len(data), "MATCH CASE section overruns file"

    str_count_at = off
    str_count = struct.unpack_from("<q", data, off)[0]
    off += 8
    str_p = off
    for _ in range(str_count):
        slen = struct.unpack_from("<q", data, off)[0]
        off += 8 + slen
        assert off <= len(data), "string section overruns file"

    journal_p = off
    base = struct.unpack_from("<q", data, off)[0]
    jcount = struct.unpack_from("<q", data, off + 8)[0]
    off += 16
    for _ in range(jcount):
        jlen = struct.unpack_from("<q", data, off)[0]
        off += 8 + jlen
        assert off <= len(data), "journal section overruns file"
    trailer_p = off
    var_start, node_start = struct.unpack_from("<qq", data, off)
    return {
        "version": ver,
        "fp": fp,
        "sig": sig,
        "name": name.decode("utf-8", "replace"),
        "fp_offset": 24,
        "var_count_at": var_count_at,
        "var_count": var_count,
        "node_count_at": node_count_at,
        "node_count": node_count,
        "node_p": node_p,
        "sg_count": sg_count,
        "edge_count": edge_count,
        "instr_count_at": instr_count_at,
        "instr_count": instr_count,
        "instr_p": instr_p,
        "case_p": case_p,
        "match_count": match_count,
        "matches": matches,
        "str_p": str_p,
        "journal_p": journal_p,
        "trailer_p": trailer_p,
        "var_start": var_start,
        "node_start": node_start,
    }


def _write_source(tmp, source, name):
    src = tmp / f"{name}.cr"
    src.write_text(source, encoding="utf-8")
    return src


def _build_source(tmp, src, out_name, cwd):
    """Build a static ELF + .ccr from an existing source path."""
    elf = tmp / f"{out_name}.elf"
    r = _run([COREC, "build", src, "-o", elf, "--static"], cwd=cwd)
    assert r.returncode == 0, f"{out_name}: build failed: {r.stdout}\n{r.stderr}"
    ccr = Path(str(elf) + ".ccr")
    assert ccr.exists(), f"{out_name}: build produced no .ccr"
    return elf, ccr


def _build_static(tmp, source, name, cwd):
    """Write source under tmp and build a static ELF + .ccr. Returns (src, elf, ccr)."""
    src = _write_source(tmp, source, name)
    elf, ccr = _build_source(tmp, src, name, cwd)
    return src, elf, ccr


def _run_elf(elf):
    run = subprocess.run(
        [str(elf)], capture_output=True, text=True, timeout=30, cwd=str(BASE)
    )
    return run.returncode


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


def test_retired_branch_opcode_rejected():
    """Opcode 19 is retired; a .ccr carrying it must be rejected."""
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_ccr(tmp, BRANCH_SOURCE, "retired_branch")
        nodes = _nod_records(data)
        match_idx = _match_nodes(data)[0]
        labels = [nodes[i][2] for i in _label_nodes(data)]
        d = bytearray(data)
        off = _nod_segment_offset(data) + 4 + match_idx * 40
        struct.pack_into("<I", d, off, 19)
        struct.pack_into("<i", d, off + 16, labels[0])
        struct.pack_into("<i", d, off + 20, labels[1])
        _assert_load_rejected(bytes(d), tmp, "retired_branch")


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
        with_match = _replace_case(_strip_matches(data), _pack_case(records))
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
    """A real nonempty MATCH image loads and runs; synthetic load coverage is above."""
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_ccr(tmp, MATCH_INT_SOURCE, "nonempty_case")
        _assert_loads(data, tmp, "nonempty_case")

        ccr = tmp / "nonempty_case.elf.ccr"
        ccr.write_bytes(data)
        elf = tmp / "nonempty_case.elf"
        r = _run([COREARCH, ccr, "--elf", "--static", "-o", elf])
        assert r.returncode == 0, r.stdout + r.stderr
        assert elf.exists()
        run = subprocess.run([str(elf)], capture_output=True, text=True, timeout=10)
        assert run.returncode == 42, (
            f"case probe returned {run.returncode}, expected 42"
        )


def test_condition_only_cases_load():
    """No explicit match, but prelude conditions still produce a valid CASE table."""
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_ccr(tmp)
        assert _pattern_match_nodes(data) == []
        assert _parse_case(segment(data, CASE_TAG)), "condition CASE rows missing"
    with tempfile.TemporaryDirectory() as td:
        _assert_loads(data, Path(td), "condition_only_case")


# ---------------------------------------------------------------------------
# 4. CASE domain checks: count, kind, str, target, default, flags
# ---------------------------------------------------------------------------


def test_malformed_case_records_rejected():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _strip_matches(_build_ccr(tmp))
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
        data = _strip_matches(_build_ccr(tmp))
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

# The checker requires a wildcard/binding arm for literal matches. These two
# sources keep one so they compile; the no-DEFAULT backend shape is produced by
# _drop_match_default on the resulting .ccr image.
MATCH_NO_DEFAULT_SOURCE = """fn pick(n: int) -> int:
    return match n:
        1 => 11,
        2 => 22,
        _ => 5

fn main() -> int:
    return pick(99)
"""

MATCH_NO_DEFAULT_HIT_SOURCE = """fn pick(n: int) -> int:
    return match n:
        1 => 11,
        2 => 22,
        _ => 0

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

# Task 5a: string, char, and ident patterns use the sequential path. None of
# them may become a CASE row (strings are not integers; char/binding rows would
# change evaluation order).
MATCH_STRING_SOURCE = """fn pick(s: string) -> int:
    return match s:
        "a" => 1,
        "b" => 2,
        _ => 3

fn main() -> int:
    if pick("a") != 1:
        return 10
    if pick("b") != 2:
        return 11
    if pick("zzz") != 3:
        return 12
    return 42
"""

MATCH_STRING_LENGTHS_SOURCE = """fn pick(s: string) -> int:
    return match s:
        "a" => 1,
        "bb" => 2,
        "ccc" => 3,
        _ => 4

fn main() -> int:
    if pick("a") != 1:
        return 10
    if pick("bb") != 2:
        return 11
    if pick("ccc") != 3:
        return 12
    if pick("zzzz") != 4:
        return 13
    return 42
"""

MATCH_STRING_FIRST_BYTE_SOURCE = """fn pick(s: string) -> int:
    return match s:
        "aa" => 1,
        "ba" => 2,
        "ca" => 3,
        _ => 4

fn main() -> int:
    if pick("aa") != 1:
        return 10
    if pick("ba") != 2:
        return 11
    if pick("ca") != 3:
        return 12
    if pick("da") != 4:
        return 13
    return 42
"""

MATCH_CHAR_SOURCE = """fn code_a() -> int:
    return 'A' as int

fn pick(c: char) -> int:
    return match c:
        'A' => 1,
        'B' => 2,
        _ => 3

fn main() -> int:
    a := code_a()
    if a == 0:
        return 9
    c := a as char
    if pick(c) != 1:
        return 10
    if pick('B') != 2:
        return 11
    if pick('C') != 3:
        return 12
    return 42
"""

MATCH_IDENT_BIND_SOURCE = """fn inc(n: int) -> int:
    return match n:
        x => x + 1

fn pick(s: string) -> string:
    return match s:
        x => x

fn main() -> int:
    if inc(7) != 8:
        return 1
    if pick("hi") != "hi":
        return 2
    v := match 5:
        1 => 10,
        rest => rest
    if v != 5:
        return 3
    return 42
"""

MATCH_STRING_NO_DEFAULT_SOURCE = """fn pick(s: string) -> int:
    return match s:
        "a" => 1,
        "b" => 2

fn main() -> int:
    return pick("a")
"""

MATCH_CHAR_NO_DEFAULT_SOURCE = """fn pick(c: char) -> int:
    return match c:
        'A' => 1,
        'B' => 2

fn main() -> int:
    return pick('A')
"""

MATCH_INT_NO_DEFAULT_SOURCE = """fn pick(n: int) -> int:
    return match n:
        1 => 1,
        2 => 2

fn main() -> int:
    return pick(1)
"""

MATCH_BOOL_NO_DEFAULT_SOURCE = """fn pick(b: bool) -> int:
    return match b:
        true => 1,
        false => 2

fn main() -> int:
    return pick(true)
"""

MATCH_WILDCARD_ORDER_SOURCE = """fn pick(n: int) -> int:
    return match n:
        _ => 1,
        2 => 2

fn main() -> int:
    return pick(2)
"""

MATCH_IDENT_ORDER_SOURCE = """fn pick(n: int) -> int:
    return match n:
        x => 1,
        2 => 2

fn main() -> int:
    return pick(2)
"""

MATCH_DUPLICATE_STRING_CHAR_SOURCE = """fn picks(s: string) -> int:
    return match s:
        "a" => 1,
        "a" => 2,
        _ => 3

fn pickc(c: char) -> int:
    return match c:
        'A' => 1,
        'A' => 2,
        _ => 3

fn main() -> int:
    return picks("a") + pickc('A')
"""

MATCH_INTERP_PATTERN_SOURCE = """fn pick(x: int) -> int:
    s := "a"
    return match s:
        "a${x}" => 1,
        _ => 2

fn main() -> int:
    return pick(1)
"""

MATCH_NESTED_LITERAL_SOURCE = """enum E:
    A(int), B

fn main() -> int:
    e := A(1)
    return match e:
        A(1) => 1,
        _ => 2
"""

# Composite sub-patterns are allocated before the outer EXPR_ENUMPAT node, so
# they are not contiguous from ast_b. These fixtures pin both orders and a
# deeper nesting; all must be rejected rather than matched as a bare variant.
MATCH_NESTED_SECOND_BYPASS_SOURCE = """enum Inner:
    X(int), Y(int)

enum Outer:
    A(Inner, Inner), B

fn main() -> int:
    o := A(X(1), X(2))
    return match o:
        A(x, X(y)) => 1,
        _ => 2
"""

MATCH_NESTED_FIRST_BYPASS_SOURCE = """enum Inner:
    X(int), Y(int)

enum Outer:
    A(Inner, Inner), B

fn main() -> int:
    o := A(X(1), X(2))
    return match o:
        A(X(y), x) => 1,
        _ => 2
"""

MATCH_NESTED_DEEP_BYPASS_SOURCE = """enum L3:
    Z(int)

enum L2:
    Y(L3)

enum L1:
    X(L2)

enum Outer:
    A(L1), B

fn f(o: Outer) -> int:
    return match o:
        A(X(Y(z))) => 1,
        _ => 2

fn main() -> int:
    return f(B())
"""

MATCH_MULTI_PAYLOAD_BIND_SOURCE = """enum Pair:
    A(int, int), B

fn sum(p: Pair) -> int:
    return match p:
        A(x, y) => x + y,
        B => 0

fn second(p: Pair) -> int:
    return match p:
        A(_, x) => x,
        B => 0

fn main() -> int:
    if sum(A(3, 4)) != 7:
        return 1
    if sum(B()) != 0:
        return 2
    if second(A(9, 8)) != 8:
        return 3
    if second(B()) != 0:
        return 4
    return 42
"""

# Task 5b1: struct patterns. Field names are bound by name (the pattern below
# reverses the declaration order in the second arm), ident subpatterns bind the
# field value, and a miss must fall to the wildcard instead of the first arm.
MATCH_STRUCT_SOURCE = """struct Point:
    x: int
    y: int

fn pick(p: Point) -> int:
    return match p:
        Point { x = 1, y = yv } => yv,
        Point { y = 9, x = xv } => xv,
        _ => 0

fn main() -> int:
    if pick(Point { x = 1, y = 7 }) != 7:
        return 1
    if pick(Point { x = 4, y = 9 }) != 4:
        return 2
    if pick(Point { x = 2, y = 3 }) != 0:
        return 3
    return 42
"""

# Scalar field kinds: bool/char/string/int literals all compare through the
# sequential path (strings via str_eq, not a CASE row).
MATCH_STRUCT_SCALARS_SOURCE = """struct Rec:
    flag: bool
    ch: char
    name: string
    n: int

fn pick(r: Rec) -> int:
    return match r:
        Rec { n = 3, name = "hi", ch = 'A', flag = true } => 1,
        Rec { flag = false, ch = 'B', name = "yo", n = 4 } => 2,
        _ => 3

fn main() -> int:
    if pick(Rec { flag = true, ch = 'A', name = "hi", n = 3 }) != 1:
        return 1
    if pick(Rec { flag = false, ch = 'B', name = "yo", n = 4 }) != 2:
        return 2
    if pick(Rec { flag = true, ch = 'B', name = "hi", n = 3 }) != 3:
        return 3
    if pick(Rec { flag = true, ch = 'A', name = "no", n = 3 }) != 3:
        return 4
    return 42
"""

# An irrefutable binding arm may close a struct match.
MATCH_STRUCT_IDENT_LAST_SOURCE = """struct Point:
    x: int
    y: int

fn pick(p: Point) -> int:
    return match p:
        Point { x = 1, y = 2 } => 1,
        rest => 2

fn main() -> int:
    if pick(Point { x = 1, y = 2 }) != 1:
        return 1
    if pick(Point { x = 0, y = 0 }) != 2:
        return 2
    return 42
"""

MATCH_STRUCT_UNKNOWN_TYPE_SOURCE = """struct Point:
    x: int
    y: int

fn main() -> int:
    p := Point { x = 1, y = 2 }
    return match p:
        Nope { x = 1 } => 1,
        _ => 0
"""

MATCH_STRUCT_UNKNOWN_FIELD_SOURCE = """struct Point:
    x: int
    y: int

fn main() -> int:
    p := Point { x = 1, y = 2 }
    return match p:
        Point { z = 1 } => 1,
        _ => 0
"""

MATCH_STRUCT_WRONG_FIELD_TYPE_SOURCE = """struct Point:
    x: int
    y: int

fn main() -> int:
    p := Point { x = 1, y = 2 }
    return match p:
        Point { x = true } => 1,
        _ => 0
"""

MATCH_STRUCT_DUP_FIELD_SOURCE = """struct Point:
    x: int
    y: int

fn main() -> int:
    p := Point { x = 1, y = 2 }
    return match p:
        Point { x = 1, x = 2 } => 1,
        _ => 0
"""

MATCH_STRUCT_NESTED_SOURCE = """struct Point:
    x: int
    y: int

struct Outer:
    p: Point

fn main() -> int:
    o := Outer { p = Point { x = 1, y = 2 } }
    return match o:
        Outer { p = Point { x = 1 } } => 1,
        _ => 0
"""

MATCH_STRUCT_NO_WILDCARD_SOURCE = """struct Point:
    x: int
    y: int

fn main() -> int:
    p := Point { x = 1, y = 2 }
    return match p:
        Point { x = 1 } => 1
"""

MATCH_STRUCT_WILDCARD_ORDER_SOURCE = """struct Point:
    x: int
    y: int

fn main() -> int:
    p := Point { x = 1, y = 2 }
    return match p:
        _ => 0,
        Point { x = 1 } => 1
"""

# Runtime-constructed string field: the pattern must compare contents via str_eq,
# not intern indices/pointers. Also exercises partial, reordered fields and a
# non-int ident binding (string).
MATCH_STRUCT_MISC_SOURCE = """struct Point:
    x: int
    y: int

struct R:
    name: string

fn pickp(p: Point) -> int:
    return match p:
        Point { y = 9, x = 5 } => 1,
        Point { x = 2 } => 2,
        _ => 0

fn pickname(r: R) -> string:
    return match r:
        R { name = n } => n,
        _ => ""

fn pickmatch(r: R) -> int:
    return match r:
        R { name = "hi" } => 1,
        _ => 0

fn main() -> int:
    if pickp(Point { x = 5, y = 9 }) != 1:
        return 1
    if pickp(Point { x = 2, y = 3 }) != 2:
        return 2
    if pickp(Point { x = 3, y = 3 }) != 0:
        return 3
    r := R { name = concat("h", "i") }
    if pickname(r) != "hi":
        return 4
    if pickmatch(r) != 1:
        return 5
    return 42
"""



# A concrete generic application inside a generic function still monomorphizes:
# the scrutinee is Pair[Point], so field substitution yields Point and the
# binding pattern is valid. This guards the monomorph revalidation from being
# over-conservative.

# Concrete generic instances reached through locals, field access, call results,
# and a shadowed parameter. The checker resolves the actual scrutinee type; the
# monomorph defensiveness must not fall back to the generic struct declaration.

# Optional generic field: R[string] makes s: T? bind as string?. A literal cannot
# match an optional slot. The nested optional match is a valid operation on the
# bound value and runs through the interpreter (the pre-existing ELF layout for
# optional string struct fields is outside this pattern task).



MATCH_STRUCT_CONCRETE_MISMATCH_SOURCE = """struct Point:
    x: int
    y: int

struct Other:
    a: int

fn main() -> int:
    o := Other { a = 1 }
    return match o:
        Point { x = 1 } => 1,
        _ => 0
"""

# Task 5b2: tuple patterns. Positional wrappers bind elements and test scalar
# literals; `_` skips an element. The literal string is built at runtime inside
# main so the comparison must use str_eq (content), not intern indices.
MATCH_TUPLE_SOURCE = """fn bind(n: int, s: string) -> int:
    t := (n, s)
    return match t:
        (x, y) =>:
            if x == 1:
                if y == "hi":
                    return 1
            return 2
        _ => 3

fn lit(n: int, s: string) -> int:
    t := (n, s)
    return match t:
        (1, "hi") => 1,
        (2, "yo") => 2,
        _ => 0

fn part(n: int, s: string) -> int:
    t := (n, s)
    return match t:
        (a, _) => a,
        _ => 9

fn mixed(flag: bool, ch: char, n: int) -> int:
    t := (flag, ch, n)
    return match t:
        (true, 'A', 7) => 1,
        (false, 'B', 8) => 2,
        _ => 0

fn ident_last(n: int) -> int:
    t := (n, n + 1)
    return match t:
        (1, 2) => 1,
        rest =>:
            if (rest . 0) == n:
                return 2
            return 3

fn main() -> int:
    if bind(1, "hi") != 1:
        return 1
    if bind(2, "hi") != 2:
        return 2
    if lit(1, concat("h", "i")) != 1:
        return 3
    if lit(2, "yo") != 2:
        return 4
    if lit(1, "yo") != 0:
        return 5
    if part(7, "x") != 7:
        return 6
    if mixed(true, 'A', 7) != 1:
        return 7
    if mixed(false, 'B', 8) != 2:
        return 8
    if mixed(false, 'A', 7) != 0:
        return 9
    if ident_last(5) != 2:
        return 10
    if ident_last(1) != 1:
        return 11
    return 42
"""

MATCH_TUPLE_ARITY_SOURCE = """fn main() -> int:
    t := (1, 2)
    return match t:
        (a, b, c) => 1,
        _ => 0
"""

MATCH_TUPLE_NONTUPLE_SOURCE = """fn main() -> int:
    n := 1
    return match n:
        (a, b) => 1,
        _ => 0
"""

MATCH_TUPLE_WRONG_TYPE_SOURCE = """fn main() -> int:
    t := (1, 2)
    return match t:
        (a, "s") => 1,
        _ => 0
"""

MATCH_TUPLE_NESTED_SOURCE = """fn main() -> int:
    t := ((1, 2), 3)
    return match t:
        ((a, b), c) => 1,
        _ => 0
"""

MATCH_TUPLE_NO_WILDCARD_SOURCE = """fn main() -> int:
    t := (1, 2)
    return match t:
        (1, 2) => 1
"""

MATCH_TUPLE_WILDCARD_ORDER_SOURCE = """fn main() -> int:
    t := (1, 2)
    return match t:
        _ => 0,
        (1, 2) => 1
"""

MATCH_TUPLE_GROUPING_SOURCE = """fn main() -> int:
    n := 7
    r := match n:
        (a) => a
    if r != 7:
        return 1
    return 42
"""

MATCH_TUPLE_BAD_LEADING_COMMA_SOURCE = """fn main() -> int:
    n := 1
    return match n:
        (,) => 1,
        _ => 0
"""

MATCH_TUPLE_BAD_PLUS_SOURCE = """fn main() -> int:
    n := 1
    return match n:
        (+) => 1,
        _ => 0
"""

MATCH_TUPLE_BAD_DOUBLE_COMMA_SOURCE = """fn main() -> int:
    t := (1, 2)
    return match t:
        (a, ,) => 1,
        _ => 0
"""

MATCH_TUPLE_BAD_EMPTY_SOURCE = """fn main() -> int:
    n := 1
    return match n:
        () => 1,
        _ => 0
"""

MATCH_TUPLE_BAD_TRAILING_SOURCE = """fn main() -> int:
    n := 1
    return match n:
        (a,) => 1,
        _ => 0
"""


MATCH_TUPLE_ENUM_PAYLOAD_SOURCE = """fn main() -> int:
    v := Some((1, 2))
    return match v:
        Some((a, b)) => 1,
        _ => 0
"""


MATCH_ONE_CASE_SOURCE = """fn pick(n: int) -> int:
    return match n:
        7 => 1,
        _ => 2

fn main() -> int:
    if pick(7) != 1:
        return 1
    if pick(8) != 2:
        return 2
    return 42
"""

# >2 non-default values, so these exercise the balanced binary search path.
# The sparse generator keeps a wide spread (step 13) to prove the tree is not
# relying on table-like density. Negative literals are not match patterns in
# this frontend, so the range starts above zero.
SPARSE_STEP = 13
SPARSE_BASE = 3
# Not a power of two, and dense (0..32), so the rodata jump table is selected.
DENSE_WAYS = 33


def _match_values(ways, base, step):
    return [base + i * step for i in range(ways)]


def _match_source(values, with_default=True, checker_default=False):
    """Build an exhaustive checker: every probe must return its arm or the
    default. `main` returns 42 only when all probes pass, so one build per -O
    covers every hit plus out-of-range misses on both sides.

    `checker_default` emits a wildcard arm only to satisfy the checker's literal
    exhaustiveness rule; callers strip the DEFAULT CASE row afterwards when they
    need a no-DEFAULT backend image.
    """
    lines = ["fn pick(n: int) -> int:", "    return match n:"]
    for i, value in enumerate(values):
        lines.append(f"        {value} => {i + 1},")
    if with_default:
        lines.append("        _ => 99")
    elif checker_default:
        lines.append("        _ => 0")
    lines += ["", "fn main() -> int:"]
    # Probe every arm so every tree node is exercised, plus both out-of-range
    # misses when a DEFAULT exists.
    probes = list(values)
    if with_default:
        # -1000 checks the signed jl route through the left spine.
        probes += [values[0] - 1, values[-1] + 1, -1000]
    for i, probe in enumerate(probes):
        expected = values.index(probe) + 1 if probe in values else 99
        lines.append(f"    if pick({probe}) != {expected}:")
        lines.append(f"        return {10 + i}")
    lines.append("    return 42")
    return "\n".join(lines) + "\n"


def _sparse_source(ways):
    return _match_source(_match_values(ways, SPARSE_BASE, SPARSE_STEP))


def _dense_source(ways):
    return _match_source(_match_values(ways, 0, 1))


def _match_plan_full(ccr_path, only_nodes=None):
    """Run the read-only plan channel.

    Returns (one row per IR_MATCH, binary_emits, table_emits). Table emits is the
    verification channel for the dense jump-table path, mirroring binary_emits.
    By default if-derived two-case MATCH rows are filtered out; pass
    ``only_nodes`` to inspect them.
    """
    if only_nodes is None:
        try:
            only_nodes = set(_pattern_match_nodes(Path(ccr_path).read_bytes()))
        except (OSError, ValueError, AssertionError):
            only_nodes = None
    r = _run([COREARCH, ccr_path, "--dump-match-plan"])
    assert r.returncode == 0, f"corearch --dump-match-plan failed: {r.stdout}\n{r.stderr}"
    plans = []
    binary_emits = None
    table_emits = 0
    for line in r.stdout.splitlines():
        if line.startswith("match "):
            parts = line.split()
            assert len(parts) == 8, line
            nod = int(parts[1])
            if only_nodes is not None and nod not in only_nodes:
                continue
            plans.append(
                {
                    "nod": nod,
                    "cases": int(parts[3]),
                    "nondefault": int(parts[5]),
                    "strategy": parts[7],
                }
            )
        elif line.startswith("binary_emits "):
            binary_emits = int(line.split()[1])
        elif line.startswith("table_emits "):
            table_emits = int(line.split()[1])
    assert binary_emits is not None, f"missing binary_emits line: {r.stdout!r}"
    assert "table_emits " in r.stdout, f"missing table_emits line: {r.stdout!r}"
    return plans, binary_emits, table_emits


def _match_plan(ccr_path):
    """Backward-compatible two-value view of the plan channel."""
    plans, binary_emits, _table_emits = _match_plan_full(ccr_path)
    return plans, binary_emits


def _ccr_file(tmp, data, name):
    ccr = tmp / f"{name}.ccr"
    ccr.write_bytes(data)
    return ccr


def _run_corearch_elf(tmp, data, name, opt=2):
    """Build a tagged-mode ELF straight from a .ccr image and return its rc."""
    ccr = _ccr_file(tmp, data, name)
    elf = tmp / f"{name}.elf"
    built = _run(
        [COREARCH, ccr, "--elf", "--static", "-O", str(opt), "-o", elf]
    )
    assert built.returncode == 0, (
        f"corearch --elf failed: {built.stdout}\n{built.stderr}"
    )
    run = subprocess.run(
        [str(elf)], capture_output=True, text=True, timeout=30, cwd=str(BASE)
    )
    return run.returncode


def _build_corearch_elf(tmp, data, name, opt=2, raw=False):
    """Build a static ELF from a .ccr and return (path, bytes)."""
    ccr = _ccr_file(tmp, data, name)
    elf = tmp / f"{name}.elf"
    args = [COREARCH, ccr, "--elf", "--static", "-O", str(opt), "-o", elf]
    if raw:
        args.insert(3, "--raw-int")
    built = _run(args)
    assert built.returncode == 0, (
        f"corearch --elf failed: {built.stdout}\n{built.stderr}"
    )
    return elf, elf.read_bytes()


def _run_opts(tmp, data, name, opts, expected):
    """Build and run each optimization level in parallel.

    The builds are independent processes writing distinct `<name>_O<n>` files;
    serializing them dominated the two no-default trap tests.
    """
    def one(opt):
        elf, _ = _build_corearch_elf(tmp, data, f"{name}_O{opt}", opt=opt)
        run = subprocess.run(
            [str(elf)], capture_output=True, text=True, timeout=30, cwd=str(BASE)
        )
        return opt, run.returncode

    with ThreadPoolExecutor(max_workers=len(opts)) as ex:
        results = list(ex.map(one, opts))
    for opt, rc in results:
        assert rc == expected, f"{name} -O{opt} rc={rc}, expected {expected}"


TABLE_STUB = bytes.fromhex("4b6304934c01d8ffe0")
# lea r11, [rip+disp32] is 4c 8d 1d <disp32>; the dense table stub follows it.
TABLE_LEA_PREFIX = bytes.fromhex("4c8d1d")


def _table_region(data, span):
    """Locate the dense table via its lea/movsxd/add/jmp stub.

    File offsets equal code-buffer positions (the code segment maps at zero
    offset), so table[+entry] is the absolute target position. Returns
    (lea_pos, table_pos, entries) with entries as signed 32-bit offsets.
    """
    stub = data.find(TABLE_STUB)
    assert stub >= 0, "no dense jump-table stub in ELF"
    assert data.find(TABLE_STUB, stub + 1) < 0, "more than one table stub"
    lea = stub - 7
    assert data[lea : lea + 3] == TABLE_LEA_PREFIX, data[lea : lea + 7].hex()
    rel = struct.unpack_from("<i", data, lea + 3)[0]
    table = lea + 7 + rel
    entries = [struct.unpack_from("<i", data, table + 4 * k)[0] for k in range(span)]
    return lea, table, entries


STR_TAG = 1
SYM_TAG = 4
REG_TAG = 7


def _str_table(data):
    body = segment(data, STR_TAG)
    (count,) = struct.unpack_from("<I", body, 0)
    pos = 4
    out = []
    for _ in range(count):
        (slen,) = struct.unpack_from("<I", body, pos)
        pos += 4
        out.append(body[pos:pos + slen].decode("utf-8", "replace"))
        pos += slen
    return out


def _sym_funcs(data):
    body = segment(data, SYM_TAG)
    pos = 0

    def u32():
        nonlocal pos
        value = struct.unpack_from("<I", body, pos)[0]
        pos += 4
        return value

    global_count = u32()
    pos += global_count * 16
    func_count = u32()
    funcs = []
    for _ in range(func_count):
        name, param_count, _ret, root = struct.unpack_from("<IIii", body, pos)
        pos += 24
        pos += param_count * 4
        var_count = u32()
        pos += var_count * 8
        funcs.append({"name": name, "root_region": root})
    return funcs


def _reg_records(data):
    body = segment(data, REG_TAG)
    (count,) = struct.unpack_from("<I", body, 0)
    assert len(body) == 4 + count * 24, f"REG body {len(body)} != 4 + {count}*24"
    return [
        struct.unpack_from("<Iiiiii", body, 4 + i * 24)
        for i in range(count)
    ]


def _function_ranges(data):
    """Return [(name, enter_nod, exit_nod)] using SYM funcs and their REG roots."""
    names = _str_table(data)
    funcs = _sym_funcs(data)
    regs = _reg_records(data)
    out = []
    for func in funcs:
        root = func["root_region"]
        if root < 0 or root >= len(regs):
            continue
        _kind, _parent, enter, exit, _fe, _le = regs[root]
        out.append((names[func["name"]], enter, exit))
    return out


_STDLIB_FUNCS = None


def _stdlib_func_names():
    """Function names declared by the automatic prelude; their MATCH nodes are
    not the fixture's subject once every `if` lowers to MATCH."""
    global _STDLIB_FUNCS
    if _STDLIB_FUNCS is not None:
        return _STDLIB_FUNCS
    import re
    names = set()
    paths = list((BASE / "src" / "stdlib").glob("*.cr"))
    paths += list((BASE / "src" / "runtime").glob("*.cr"))
    prelude = BASE / "src" / "compiler" / "prelude.cr"
    if prelude.exists():
        paths.append(prelude)
    for path in paths:
        for name in re.findall(r"\bfn\s+([A-Za-z_][A-Za-z0-9_]*)", path.read_text(encoding="utf-8")):
            names.add(name)
    _STDLIB_FUNCS = names
    return names


def _user_call_names(data, fn_name):
    names = _str_table(data)
    nodes = _nod_records(data)
    out = set()
    for name, enter, exit in _function_ranges(data):
        if name != fn_name:
            continue
        for i in range(enter, exit):
            rec = nodes[i]
            if rec[0] == 4 and 0 <= rec[4] < len(names):
                out.add(names[rec[4]])
    return out


def _user_op_nodes(data, opcode):
    """Nodes with `opcode` in fixture-defined functions, excluding the prelude."""
    nodes = _nod_records(data)
    ranges = _function_ranges(data)
    if not ranges:
        return [i for i, rec in enumerate(nodes) if rec[0] == opcode]
    stdlib = _stdlib_func_names()
    out = []
    for i, rec in enumerate(nodes):
        if rec[0] != opcode:
            continue
        for name, enter, exit in ranges:
            if enter <= i < exit:
                if name not in stdlib:
                    out.append(i)
                break
    return out


def _match_nodes(data):
    """MATCH nodes in fixture-defined functions, including if-derived ones."""
    return _user_op_nodes(data, IR_MATCH)


def _is_if_match(data, match_idx):
    """An if lowers to exactly VALUE(0) followed by DEFAULT."""
    nodes = _nod_records(data)
    start, count = nodes[match_idx][3], nodes[match_idx][4]
    if count != 2:
        return False
    rows = _match_rows(data, nodes[match_idx])
    return (
        rows[0]["kind"] == KIND_VALUE
        and rows[0]["value"] == 0
        and rows[1]["kind"] == KIND_DEFAULT
    )


def _pattern_match_nodes(data):
    """Explicit match expressions; excludes if-derived two-case MATCH nodes."""
    return [i for i in _match_nodes(data) if not _is_if_match(data, i)]


def _match_rows(data, rec):
    """CASE rows for one MATCH record, sliced from the global wire table."""
    rows = _parse_case(segment(data, CASE_TAG))
    start, count = rec[3], rec[4]
    return rows[start:start + count]


def _single_match(data):
    matches = _pattern_match_nodes(data)
    assert len(matches) == 1, f"expected exactly one MATCH, got {matches}"
    return _nod_records(data)[matches[0]]


def _nod_segment_offset(data):
    return next(
        offset for tag, offset, _size in read_segment_table(data) if tag == NOD_TAG
    )


def _replace_match_range(data, match_idx, records):
    """Replace one MATCH range and shift every later MATCH case_start."""
    nodes = _nod_records(data)
    old_start, old_count = 0, 0
    if 0 <= match_idx < len(nodes) and nodes[match_idx][0] == IR_MATCH:
        old_start, old_count = nodes[match_idx][3], nodes[match_idx][4]
    rows = [
        (row["value"], row["kind"], row["str_index"], row["target_nod"], row["flags"])
        for row in _parse_case(segment(data, CASE_TAG))
    ]
    new_rows = rows[:old_start] + list(records) + rows[old_start + old_count:]
    out = bytearray(_replace_case(data, _pack_case(new_rows)))
    delta = len(records) - old_count
    nod_off = _nod_segment_offset(data)
    for i in range(len(nodes)):
        off = nod_off + 4 + i * 40
        if struct.unpack_from("<I", out, off)[0] != IR_MATCH:
            continue
        s2 = struct.unpack_from("<i", out, off + 16)[0]
        if i == match_idx:
            struct.pack_into("<i", out, off + 16, old_start)
            struct.pack_into("<i", out, off + 20, len(records))
        elif s2 >= old_start + old_count:
            struct.pack_into("<i", out, off + 16, s2 + delta)
    result = bytes(out)
    validate(result)
    return result


def _strip_matches(data, keep=-1):
    """Turn every MATCH except `keep` into IR_NOP for load-only CASE fixtures."""
    nodes = _nod_records(data)
    out = bytearray(data)
    nod_off = _nod_segment_offset(data)
    for i, rec in enumerate(nodes):
        if rec[0] == IR_MATCH and i != keep:
            off = nod_off + 4 + i * 40
            struct.pack_into("<I", out, off, 0)
            struct.pack_into("<i", out, off + 16, 0)
            struct.pack_into("<i", out, off + 20, 0)
    return bytes(out)


def _drop_match_default(data, name="nodefault"):
    """Remove the DEFAULT row from the single explicit-match range."""
    nodes = _nod_records(data)
    matches = _pattern_match_nodes(data)
    assert len(matches) == 1, f"{name}: expected one MATCH, got {matches}"
    match_idx = matches[0]
    rows = _match_rows(data, nodes[match_idx])
    default_pos = None
    for j, row in enumerate(rows):
        if row["kind"] == KIND_DEFAULT:
            default_pos = j
            break
    assert default_pos is not None, f"{name}: MATCH has no DEFAULT row"
    records = [
        (row["value"], row["kind"], row["str_index"], row["target_nod"], row["flags"])
        for row in rows
    ]
    del records[default_pos]
    return _replace_match_range(data, match_idx, records)


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
            [COREC, "build", src, "-o", elf, "--static", "-O", str(opt)],
            cwd=BASE,
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
        rows = _match_rows(data, rec)

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
        rows = _match_rows(data, rec)

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


CONDITION_MATCH_FIXTURES = [
    (
        "if_chain",
        """fn main() -> int:
    x := 2
    if x == 1:
        return 10
    else if x == 2:
        return 20
    else:
        return 30
""",
        20,
        2,
        0,
    ),
    (
        "if_nested",
        """fn main() -> int:
    x := 2
    y := 0
    if x > 0:
        if x == 2:
            y = 20
        else:
            y = 10
    else:
        y = 30
    return y
""",
        20,
        2,
        0,
    ),
    (
        "if_expr_int",
        """fn main() -> int:
    x := if true:
        1
    else:
        2
    if x == 1:
        return 42
    return 0
""",
        42,
        2,
        0,
    ),
    (
        "if_expr_str",
        """fn main() -> int:
    s := if true:
        "a"
    else:
        "b"
    if str_len(s) == 1:
        return 42
    return 0
""",
        42,
        2,
        0,
    ),
    (
        "if_bool_var",
        """fn main() -> int:
    b := true
    if b:
        return 42
    return 0
""",
        42,
        1,
        0,
    ),
    (
        "if_loop",
        """fn main() -> int:
    n : ., mut = 0
    for i in 0..5:
        if i == 3:
            n = n + 1
    return n
""",
        1,
        2,
        0,
    ),
    (
        "if_region",
        """fn main() -> int:
    n : ., mut = 0
    for i in 0..3:
        if i == 1:
            xs := [1, 2, 3]
            n = n + xs[0]
    return n
""",
        1,
        2,
        0,
    ),
    (
        "if_logic",
        """fn main() -> int:
    x := 1
    if x == 1 && true:
        return 42
    return 0
""",
        42,
        2,
        0,
    ),
]


def test_condition_branches_lower_to_match_cases():
    """Every condition branch is one VALUE(0) row plus a DEFAULT row.

    The fixtures cover if, for, and logical conditions; all lower to IR_MATCH.
    """
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        for name, source, expected, expected_matches, _branches_expected in CONDITION_MATCH_FIXTURES:
            data = _build_ccr(tmp, source, name)
            nodes = _nod_records(data)
            matches = _match_nodes(data)
            assert len(matches) == expected_matches, (
                f"{name}: expected {expected_matches} condition MATCH nodes, "
                f"got {matches}"
            )
            rows = _parse_case(segment(data, CASE_TAG))
            for match_idx in matches:
                start, count = nodes[match_idx][3], nodes[match_idx][4]
                assert count == 2, (
                    f"{name}: condition MATCH case count {count}, expected 2"
                )
                part = rows[start:start + count]
                assert [row["kind"] for row in part] == [KIND_VALUE, KIND_DEFAULT], (
                    f"{name}: condition CASE kinds {[row['kind'] for row in part]}"
                )
                assert part[0]["value"] == 0, (
                    f"{name}: false case value {part[0]['value']}, expected 0"
                )
                _assert_targets_are_labels(data, part)
            plan_path = _ccr_file(tmp, data, f"{name}_plan")
            plans, _binary_emits, _table_emits = _match_plan_full(
                plan_path, only_nodes=set(matches)
            )
            assert len(plans) == len(matches), (name, plans)
            assert all(plan["strategy"] == "two-way-zero" for plan in plans), (
                name,
                plans,
            )
            _assert_program(tmp, source, expected, opts=(0, 2), name=name)


COND_BRANCH_FIXTURES = [
    (
        "while_match",
        """fn main() -> int:
    n : ., mut = 0
    while n < 3:
        n = n + 1
    return n
""",
        3,
    ),
    (
        "for_match",
        """fn main() -> int:
    n : ., mut = 0
    for i in 0..3:
        n = n + 1
    return n
""",
        3,
    ),
    (
        "and_match",
        """fn main() -> int:
    a := true
    b := false
    if a && b:
        return 1
    return 42
""",
        42,
    ),
    (
        "or_match",
        """fn main() -> int:
    a := false
    b := true
    if a || b:
        return 42
    return 0
""",
        42,
    ),
]


def test_all_condition_branches_use_match_cases():
    """while/for/&&/|| are the same VALUE(0)+DEFAULT decision node as if."""
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        for name, source, expected in COND_BRANCH_FIXTURES:
            data = _build_ccr(tmp, source, name)
            nodes = _nod_records(data)
            matches = _match_nodes(data)
            assert matches, f"{name}: no MATCH nodes"
            for match_idx in matches:
                part = _match_rows(data, nodes[match_idx])
                assert [row["kind"] for row in part] == [KIND_VALUE, KIND_DEFAULT], (
                    name,
                    [row["kind"] for row in part],
                )
                assert part[0]["value"] == 0, (name, part[0]["value"])
                _assert_targets_are_labels(data, part)
            plan_path = _ccr_file(tmp, data, f"{name}_plan")
            plans, _binary_emits, _table_emits = _match_plan_full(
                plan_path, only_nodes=set(matches)
            )
            assert len(plans) == len(matches), (name, plans)
            assert all(plan["strategy"] == "two-way-zero" for plan in plans), (
                name,
                plans,
            )
            _assert_program(tmp, source, expected, opts=(0, 2), name=name)


IF_TYPE_FIXTURES = [
    (
        "if_bool_result",
        """fn main() -> int:
    b := if true:
        true
    else:
        false
    if b:
        return 42
    return 0
""",
        42,
    ),
    (
        "if_char_result",
        """fn main() -> int:
    c := if true:
        'A'
    else:
        'B'
    if c == 'A':
        return 42
    return 0
""",
        42,
    ),
    (
        "if_dex_result",
        """fn main() -> int:
    d := if true:
        1.0
    else:
        2.0
    if d == 1.0:
        return 42
    return 0
""",
        42,
    ),
    (
        "if_struct_result",
        """struct P:
    x: int
    y: int
fn main() -> int:
    p := if true:
        P { x = 1, y = 2 }
    else:
        P { x = 3, y = 4 }
    return p.x + p.y
""",
        3,
    ),
    (
        "if_tuple_result",
        """fn main() -> int:
    t := if true:
        (1, 2)
    else:
        (3, 4)
    return (t . 0) + (t . 1)
""",
        3,
    ),
    (
        "if_optional_bare_result",
        """fn main() -> int:
    o : int? = if true:
        1
    else:
        2
    x := o?
    return x + 41
""",
        42,
    ),
    (
        "if_optional_some_result",
        """fn main() -> int:
    o : int? = if true:
        Some(1)
    else:
        Some(2)
    x := o?
    return x + 41
""",
        42,
    ),
    (
        "if_return_result",
        """fn main() -> int:
    return if true:
        42
    else:
        0
""",
        42,
    ),
]


def test_if_expression_result_types():
    """if-expression result slots keep bool/char/dex/struct/tuple/optional forms."""
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        for name, source, expected in IF_TYPE_FIXTURES:
            _assert_program(tmp, source, expected, opts=(0, 2), name=name)


def test_enum_match_is_one_match_with_enum_cases():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_ccr(tmp, MATCH_ENUM_SOURCE, "match_enum")
        rec = _single_match(data)
        rows = _match_rows(data, rec)

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
        assert _pattern_match_nodes(data) == [], (
            "string/ident-binding/struct patterns must not become MATCH"
        )


def test_mixed_enum_and_value_arms_fall_back():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_ccr(tmp, MATCH_MIXED_SOURCE, "match_mixed")
        assert _pattern_match_nodes(data) == [], (
            "a match mixing enum variants and value literals must keep the old path"
        )
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
        checked = _build_ccr(tmp, MATCH_NO_DEFAULT_SOURCE, "match_nodefault_checked")
        data = _drop_match_default(checked, "match_nodefault")
        rec = _single_match(data)
        rows = _match_rows(data, rec)
        assert rec[1] == -1
        assert rec[2] >= 0
        assert rec[4] == 2
        assert [row["kind"] for row in rows] == [KIND_VALUE, KIND_VALUE]
        _assert_targets_are_labels(data, rows)

        # The checker now rejects a source-level no-DEFAULT literal match, so the
        # no-DEFAULT image is reached by stripping the wildcard row. A miss must
        # still trap (SIGILL) on both optimization levels.
        elf, _elf_data = _build_corearch_elf(tmp, data, "match_nodefault", opt=2)
        run = subprocess.run(
            [str(elf)], capture_output=True, text=True, timeout=30, cwd=str(BASE)
        )
        assert run.returncode == -4, (
            f"ELF did not trap with SIGILL: rc={run.returncode}"
        )


def test_no_default_match_dispatches_hits():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        checked = _build_ccr(
            tmp, MATCH_NO_DEFAULT_HIT_SOURCE, "match_nodefault_hit_checked"
        )
        data = _drop_match_default(checked, "match_nodefault_hit")
        rec = _single_match(data)
        rows = _match_rows(data, rec)
        assert rec[4] == 2
        assert KIND_DEFAULT not in [row["kind"] for row in rows]
        assert _run_corearch_elf(tmp, data, "match_nodefault_hit", opt=2) == 33


def test_enum_match_raw_int_mode():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_ccr(tmp, MATCH_ENUM_SOURCE, "match_enum_raw")
        assert len(_pattern_match_nodes(data)) == 1
        assert _run_raw_elf(tmp, data, "match_enum_raw") == 42


def test_loop_match_all_opt_levels():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_ccr(tmp, MATCH_LOOP_SOURCE, "match_loop")
        rec = _single_match(data)
        rows = _match_rows(data, rec)
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
        assert _pattern_match_nodes(data) == []
        _assert_program(
            tmp,
            MATCH_IDENT_FALLBACK_SOURCE,
            42,
            name="match_ident_fallback",
        )


def test_string_match_uses_sequential_path():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_ccr(tmp, MATCH_STRING_SOURCE, "match_string")
        assert _pattern_match_nodes(data) == [], "string patterns must not become CASE rows"
        _assert_program(
            tmp, MATCH_STRING_SOURCE, 42, opts=(0, 2), name="match_string"
        )


def test_string_match_uses_length_bucket():
    """The string arm chain computes str_len once before per-arm str_eq calls."""
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_ccr(tmp, MATCH_STRING_LENGTHS_SOURCE, "match_string_lengths")
        assert "str_len" in _user_call_names(data, "pick"), (
            "string match did not emit the length bucket"
        )
        _assert_program(
            tmp,
            MATCH_STRING_LENGTHS_SOURCE,
            42,
            opts=(0, 2),
            name="match_string_lengths",
        )


def test_string_match_uses_first_byte_bucket():
    """Same-length string arms are prefixed by a first-byte load8 comparison."""
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_ccr(
            tmp, MATCH_STRING_FIRST_BYTE_SOURCE, "match_string_first_byte"
        )
        calls = _user_call_names(data, "pick")
        assert "str_len" in calls and "load8" in calls, calls
        _assert_program(
            tmp,
            MATCH_STRING_FIRST_BYTE_SOURCE,
            42,
            opts=(0, 2),
            name="match_string_first_byte",
        )


def test_char_match_uses_interned_char_value():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_ccr(tmp, MATCH_CHAR_SOURCE, "match_char")
        assert _pattern_match_nodes(data) == [], "char patterns must not become CASE rows"
        # The program itself compares the char match against `'A' as int`, i.e.
        # the current intern-index value, not a Unicode codepoint.
        _assert_program(tmp, MATCH_CHAR_SOURCE, 42, opts=(0, 2), name="match_char")


def test_ident_pattern_binds_scrutinee():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_ccr(tmp, MATCH_IDENT_BIND_SOURCE, "match_ident_bind")
        assert _pattern_match_nodes(data) == [], "binding arms must not become CASE rows"
        _assert_program(
            tmp, MATCH_IDENT_BIND_SOURCE, 42, opts=(0, 2), name="match_ident_bind"
        )


def test_literal_match_requires_wildcard():
    cases = [
        ("string", MATCH_STRING_NO_DEFAULT_SOURCE),
        ("char", MATCH_CHAR_NO_DEFAULT_SOURCE),
        ("int", MATCH_INT_NO_DEFAULT_SOURCE),
        ("bool", MATCH_BOOL_NO_DEFAULT_SOURCE),
    ]
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        for name, source in cases:
            _assert_compile_rejected(
                tmp,
                source,
                f"exhaust_{name}",
                ["error[TM03]", "Non-exhaustive match", "add a wildcard or binding arm"],
            )


def test_wildcard_and_ident_must_be_last():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        needles = ["error[TM05]", "must be the last arm"]
        _assert_compile_rejected(
            tmp, MATCH_WILDCARD_ORDER_SOURCE, "order_wildcard", needles
        )
        _assert_compile_rejected(
            tmp, MATCH_IDENT_ORDER_SOURCE, "order_ident", needles
        )


def test_duplicate_literal_patterns_are_redundant():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        text = _assert_soft_diagnostic(
            tmp,
            MATCH_DUPLICATE_STRING_CHAR_SOURCE,
            "duplicate_literals",
            ["error[TM04]", "Redundant match arm"],
        )
        assert text.count("error[TM04]") >= 2, text


def test_interpolated_string_pattern_rejected():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        _assert_compile_rejected(
            tmp,
            MATCH_INTERP_PATTERN_SOURCE,
            "interp_pattern",
            ["error[TM09]", "String interpolation is not supported"],
        )


def test_nested_literal_payload_matches():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        _assert_program(
            tmp,
            MATCH_NESTED_LITERAL_SOURCE,
            1,
            opts=(0, 2),
            name="nested_literal",
        )


def test_nested_composite_payload_bypass_is_rejected():
    cases = [
        ("nested_second", MATCH_NESTED_SECOND_BYPASS_SOURCE),
        ("nested_first", MATCH_NESTED_FIRST_BYPASS_SOURCE),
        ("nested_deep", MATCH_NESTED_DEEP_BYPASS_SOURCE),
    ]
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        needles = ["error[TM09]", "Nested match patterns are not supported"]
        for name, source in cases:
            _assert_compile_rejected(tmp, source, name, needles)
            # `run` shares the same checker; the interpreter must reject the
            # pattern too, not silently return one of the divergent values.
            run = _run([COREC, "run", source], cwd=BASE)
            text = run.stdout + run.stderr
            assert run.returncode == 1, (
                f"{name}: interpreter accepted a nested payload pattern: "
                f"rc={run.returncode}: {text}"
            )
            for needle in needles:
                assert needle in text, f"{name}: interpreter missing {needle!r}: {text}"


def test_multi_payload_ident_bindings_work():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_ccr(
            tmp, MATCH_MULTI_PAYLOAD_BIND_SOURCE, "multi_payload_bind"
        )
        assert _pattern_match_nodes(data) == [], "payload binding keeps the sequential path"
        _assert_program(
            tmp,
            MATCH_MULTI_PAYLOAD_BIND_SOURCE,
            42,
            opts=(0, 2),
            name="multi_payload_bind",
        )


def test_struct_pattern_binds_fields_and_is_refutable():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_ccr(tmp, MATCH_STRUCT_SOURCE, "match_struct")
        assert _pattern_match_nodes(data) == [], "struct patterns must not become MATCH"
        _assert_program(
            tmp, MATCH_STRUCT_SOURCE, 42, opts=(0, 2), name="match_struct"
        )


def test_struct_pattern_scalar_field_kinds():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_ccr(tmp, MATCH_STRUCT_SCALARS_SOURCE, "match_struct_scalars")
        assert _pattern_match_nodes(data) == [], "struct patterns must not become MATCH"
        _assert_program(
            tmp,
            MATCH_STRUCT_SCALARS_SOURCE,
            42,
            opts=(0, 2),
            name="match_struct_scalars",
        )


def test_struct_pattern_ident_last_is_exhaustive():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_ccr(tmp, MATCH_STRUCT_IDENT_LAST_SOURCE, "match_struct_ident")
        assert _pattern_match_nodes(data) == [], "struct patterns must not become MATCH"
        _assert_program(
            tmp,
            MATCH_STRUCT_IDENT_LAST_SOURCE,
            42,
            opts=(0, 2),
            name="match_struct_ident",
        )


def test_struct_pattern_partial_reordered_and_runtime_string():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_ccr(tmp, MATCH_STRUCT_MISC_SOURCE, "match_struct_misc")
        assert _pattern_match_nodes(data) == [], "struct patterns must not become MATCH"
        _assert_program(
            tmp,
            MATCH_STRUCT_MISC_SOURCE,
            42,
            opts=(0, 2),
            name="match_struct_misc",
        )










def test_struct_pattern_errors_are_hard():
    cases = [
        (
            "struct_unknown_type",
            MATCH_STRUCT_UNKNOWN_TYPE_SOURCE,
            ["error[N01]", "Unknown struct type"],
        ),
        (
            "struct_unknown_field",
            MATCH_STRUCT_UNKNOWN_FIELD_SOURCE,
            ["error[TS02]", "Unknown field 'z'"],
        ),
        (
            "struct_wrong_field_type",
            MATCH_STRUCT_WRONG_FIELD_TYPE_SOURCE,
            ["error[TS03]", "expected int, got bool"],
        ),
        (
            "struct_dup_field",
            MATCH_STRUCT_DUP_FIELD_SOURCE,
            ["error[TS04]", "matched more than once"],
        ),
        (
            "struct_concrete_mismatch",
            MATCH_STRUCT_CONCRETE_MISMATCH_SOURCE,
            ["error[TS03]", "does not match scrutinee type"],
        ),
    ]
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        for name, source, needles in cases:
            _assert_compile_rejected(tmp, source, name, needles)


def test_nested_struct_pattern_matches():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        _assert_program(
            tmp,
            MATCH_STRUCT_NESTED_SOURCE,
            1,
            opts=(0, 2),
            name="struct_nested",
        )


def test_struct_pattern_exhaustiveness_and_order():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        _assert_compile_rejected(
            tmp,
            MATCH_STRUCT_NO_WILDCARD_SOURCE,
            "struct_no_wildcard",
            ["error[TM03]", "Non-exhaustive match", "add a wildcard or binding arm"],
        )
        _assert_compile_rejected(
            tmp,
            MATCH_STRUCT_WILDCARD_ORDER_SOURCE,
            "struct_wildcard_order",
            ["error[TM05]", "must be the last arm"],
        )


def test_tuple_pattern_binds_literals_and_partial():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_ccr(tmp, MATCH_TUPLE_SOURCE, "match_tuple")
        assert _pattern_match_nodes(data) == [], "tuple patterns must not become MATCH"
        _assert_program(
            tmp, MATCH_TUPLE_SOURCE, 42, opts=(0, 2), name="match_tuple"
        )


def test_tuple_pattern_errors_are_hard():
    cases = [
        (
            "tuple_arity",
            MATCH_TUPLE_ARITY_SOURCE,
            ["error[TA07]", "has 3 elements", "scrutinee has 2"],
        ),
        (
            "tuple_nontuple",
            MATCH_TUPLE_NONTUPLE_SOURCE,
            ["error[TS03]", "Tuple pattern requires a tuple scrutinee"],
        ),
        (
            "tuple_wrong_type",
            MATCH_TUPLE_WRONG_TYPE_SOURCE,
            ["error[TS03]", "expected int, got string"],
        ),
    ]
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        for name, source, needles in cases:
            _assert_compile_rejected(tmp, source, name, needles)


def test_tuple_pattern_exhaustiveness_and_order():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        _assert_compile_rejected(
            tmp,
            MATCH_TUPLE_NO_WILDCARD_SOURCE,
            "tuple_no_wildcard",
            ["error[TM03]", "Non-exhaustive match", "add a wildcard or binding arm"],
        )
        _assert_compile_rejected(
            tmp,
            MATCH_TUPLE_WILDCARD_ORDER_SOURCE,
            "tuple_wildcard_order",
            ["error[TM05]", "must be the last arm"],
        )


def test_tuple_pattern_parenthesized_binding_is_transparent():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_ccr(tmp, MATCH_TUPLE_GROUPING_SOURCE, "match_tuple_group")
        assert _pattern_match_nodes(data) == [], "grouped binding must not become MATCH"
        _assert_program(
            tmp,
            MATCH_TUPLE_GROUPING_SOURCE,
            42,
            opts=(0, 2),
            name="match_tuple_group",
        )


def test_tuple_pattern_malformed_is_hard_p005():
    cases = [
        ("tuple_leading_comma", MATCH_TUPLE_BAD_LEADING_COMMA_SOURCE),
        ("tuple_plus", MATCH_TUPLE_BAD_PLUS_SOURCE),
        ("tuple_double_comma", MATCH_TUPLE_BAD_DOUBLE_COMMA_SOURCE),
        ("tuple_empty", MATCH_TUPLE_BAD_EMPTY_SOURCE),
        ("tuple_trailing", MATCH_TUPLE_BAD_TRAILING_SOURCE),
    ]
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        for name, source in cases:
            needles = ["error[P05]"]
            if name in ("tuple_leading_comma", "tuple_plus", "tuple_double_comma"):
                needles.append("Unexpected token in pattern")
            _assert_compile_rejected(tmp, source, name, needles)




def test_tuple_pattern_enum_payload_rejected_tm09():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        needles = ["error[TM09]", "Nested match patterns are not supported"]
        _assert_compile_rejected(
            tmp, MATCH_TUPLE_ENUM_PAYLOAD_SOURCE, "tuple_enum_payload", needles
        )




def test_nested_tuple_pattern_matches():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        _assert_program(
            tmp,
            MATCH_TUPLE_NESTED_SOURCE,
            1,
            opts=(0, 2),
            name="tuple_nested",
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
        nodes = _nod_records(data)
        pattern_match = _pattern_match_nodes(data)
        assert len(pattern_match) == 1, pattern_match
        match_lines = [
            line for line in lines
            if line.startswith(f"nod {pattern_match[0]} ") and " op 54 " in line
        ]
        assert len(match_lines) == 1, match_lines
        start, count = nodes[pattern_match[0]][3], nodes[pattern_match[0]][4]
        assert " s2 0 " in match_lines[0], match_lines[0]
        assert " s3 5 " in match_lines[0], match_lines[0]
        cases = [line for line in lines if line.startswith("case ")]
        part = cases[start:start + count]
        assert len(part) == 5, part
        assert " value 10 " in part[0], part[0]
        assert " kind 0 " in part[0], part[0]
        assert " kind 3 " in part[4], part[4]
        target = int(part[0].split("target ")[1].split()[0])
        assert nodes[target][0] == IR_LABEL


def test_case_ranges_are_disjoint_across_functions():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_ccr(tmp, MATCH_TWO_FUNCS_SOURCE, "match_two")
        matches = _pattern_match_nodes(data)
        assert len(matches) == 2, f"expected two MATCH nodes, got {matches}"
        nodes = _nod_records(data)
        ranges = sorted((nodes[m][3], nodes[m][3] + nodes[m][4]) for m in matches)
        total = sum(nodes[m][4] for m in matches)
        assert ranges[0][0] == 0, ranges
        assert ranges[0][1] == ranges[1][0], ranges
        assert ranges[-1][1] == total, (ranges, total)
        assert total == 3 + 4, total
        for match_idx in matches:
            _assert_targets_are_labels(data, _match_rows(data, nodes[match_idx]))
        _assert_program(tmp, MATCH_TWO_FUNCS_SOURCE, 42)


MATCH_NESTED_CASE_SOURCE = """fn pick(n: int, m: int) -> int:
    return match n:
        1 => match m:
            10 => 100,
            _ => 101,
        2 => 2,
        _ => 3

fn main() -> int:
    if pick(1, 10) != 100:
        return 1
    if pick(1, 7) != 101:
        return 2
    if pick(2, 0) != 2:
        return 3
    if pick(9, 0) != 3:
        return 4
    return 42
"""

# Same function body on both sides; only the earlier pad function changes. The
# extra `x = x` adds one node but no variable, so pick_b's var baseline is
# unchanged while its node/instruction baseline shifts by one.
SHIFT_PAD_V1 = """fn pad(b: bool) -> int:
    x := 1
    x = x
    if b:
        return 1
    return 0
"""

SHIFT_PAD_V2 = """fn pad(b: bool) -> int:
    x := 1
    x = x
    x = x
    if b:
        return 1
    return 0
"""

SHIFT_PICK = """fn pick_b(n: int) -> int:
    return match n:
        7 => 70,
        8 => 80,
        9 => 90,
        _ => 99
"""

SHIFT_MAIN = """fn main() -> int:
    if pick_b(9) != 90:
        return 2
    return 42
"""


def _snapshot_labels(snap, data):
    """Label numbers carried by this snapshot's IR_LABEL nodes."""
    labels = set()
    for i in range(snap["node_count"]):
        off = snap["node_p"] + i * 64
        if struct.unpack_from("<q", data, off)[0] == IR_LABEL:
            labels.add(struct.unpack_from("<q", data, off + 16)[0])
    return labels


def _assert_snapshot_case_section(snap, data, counts):
    """Validate one snapshot's semantic CASE model and its target labels."""
    assert snap["match_count"] == len(counts), snap["match_count"]
    labels = _snapshot_labels(snap, data)
    for match, count in zip(snap["matches"], counts):
        assert match["count"] == count, (match["count"], count)
        for row in match["rows"]:
            label = row["target_label"]
            assert label >= 0, f"CASE model target label {label} is unresolved"
            assert label in labels, (
                f"CASE model target label {label} is not an IR_LABEL in this function"
            )


def _snapshot_match_nod(data, snap, ordinal=0):
    """Return (local index, record offset, s2, s3) for a MATCH NOD record."""
    seen = 0
    for i in range(snap["node_count"]):
        off = snap["node_p"] + i * 64
        if struct.unpack_from("<q", data, off)[0] == IR_MATCH:
            if seen == ordinal:
                s2, s3 = struct.unpack_from("<qq", data, off + 24)
                return i, off, s2, s3
            seen += 1
    raise AssertionError(f"no MATCH NOD ordinal {ordinal}")


def _snapshot_match_instr(data, snap, ordinal=0):
    """Return (local index, record offset, s2, s3) for a MATCH instruction."""
    seen = 0
    for i in range(snap["instr_count"]):
        off = snap["instr_p"] + i * 48
        if struct.unpack_from("<q", data, off)[0] == IR_MATCH:
            if seen == ordinal:
                s2, s3 = struct.unpack_from("<qq", data, off + 24)
                return i, off, s2, s3
            seen += 1
    raise AssertionError(f"no MATCH instruction ordinal {ordinal}")


def _assert_tampered_rebuild(tmp, src, entry, data, tag, base_elf, base_ccr,
                             counts=(5,), expected=42):
    """Write a corrupt snapshot; the next build must miss, rebuild, and match baseline."""
    entry.write_bytes(data)
    stamp = _entry_stamp(entry)
    time.sleep(0.02)
    out_elf, out_ccr = _build_source(tmp, src, f"tampered_{tag}", tmp)
    assert out_elf.read_bytes() == base_elf, f"{tag}: partial/incorrect ELF"
    assert out_ccr.read_bytes() == base_ccr, f"{tag}: partial .ccr"
    assert _entry_stamp(entry) != stamp, f"{tag}: cache was not rebuilt"
    fixed = _cir_snapshot(entry.read_bytes())
    _assert_snapshot_case_section(fixed, entry.read_bytes(), list(counts))
    assert _run_elf(out_elf) == expected, tag


def _assert_match_cold_warm(tmp, source, base, expected, fns,
                            include_if=False):
    """Cold and warm static builds must match exactly and every entry must hit.

    `fns` maps function name -> expected per-MATCH case counts. With
    `include_if`, if-derived MATCHes are part of the expected count.
    """
    _clean_cache(tmp)
    src = _write_source(tmp, source, base)
    cold_elf, cold_ccr = _build_source(tmp, src, "cold", tmp)
    entries = {fn: _cache_entry(tmp, fn) for fn in fns}
    before = {fn: entry.read_bytes() for fn, entry in entries.items()}
    stamps = {fn: _entry_stamp(entry) for fn, entry in entries.items()}
    snaps = {}
    for fn, counts in fns.items():
        snaps[fn] = _cir_snapshot(before[fn])
        assert snaps[fn]["name"] == fn, (snaps[fn]["name"], fn)
        _assert_snapshot_case_section(snaps[fn], before[fn], counts)
    cold_data = cold_ccr.read_bytes()
    cold_nodes = _nod_records(cold_data)
    pattern_nodes = _match_nodes(cold_data) if include_if else _pattern_match_nodes(cold_data)
    assert sum(cold_nodes[m][4] for m in pattern_nodes) == sum(
        sum(c) for c in fns.values()
    )
    for match_idx in pattern_nodes:
        _assert_targets_are_labels(cold_data, _match_rows(cold_data, cold_nodes[match_idx]))

    time.sleep(0.02)
    warm_elf, warm_ccr = _build_source(tmp, src, "warm", tmp)
    for fn in fns:
        assert _entry_stamp(entries[fn]) == stamps[fn], (
            f"{fn}: warm build did not hit the cache"
        )
        assert entries[fn].read_bytes() == before[fn], f"{fn}: hit rewrote the entry"
    assert cold_elf.read_bytes() == warm_elf.read_bytes(), "cold/warm ELF differ"
    assert cold_ccr.read_bytes() == warm_ccr.read_bytes(), "cold/warm .ccr differ"
    assert _run_elf(warm_elf) == expected, "warm ELF returned the wrong status"
    return snaps


def _case_model_counts(stdout):
    """Parse the hidden --dump-case-model lines into (before, after) dicts."""
    before = {}
    after = {}
    for line in stdout.splitlines():
        parts = line.split()
        if len(parts) != 3:
            continue
        if parts[0] == "case_model_before":
            before = {"model": int(parts[1]), "wire": int(parts[2])}
        elif parts[0] == "case_model_after":
            after = {"model": int(parts[1]), "wire": int(parts[2])}
    return before, after


def test_case_model_is_semantic_before_lower():
    """ir_gen fills only the semantic model; ccr_lower derives the wire table.

    The hidden channel reports both counts around lower_to_ccr. Before lowering
    the wire table must be empty while the model has rows; afterwards the wire
    count must equal the model count and every MATCH range must index that wire
    table. The warm run proves a restored model is also not pre-expanded to wire.
    """
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        _clean_cache(tmp)
        src = _write_source(tmp, MATCH_INT_SOURCE, "case_model_contract")
        ccr = tmp / "case_model_contract.ccr"
        r = _run(
            [COREC, "ccr", src, "-o", ccr, "--dump-case-model"],
            cwd=tmp,
        )
        assert r.returncode == 0, f"corec ccr failed: {r.stdout}\n{r.stderr}"
        before, after = _case_model_counts(r.stdout)
        assert before, f"missing case_model_before: {r.stdout!r}"
        assert after, f"missing case_model_after: {r.stdout!r}"
        assert before["model"] > 0, before
        assert before["wire"] == 0, before
        assert after["model"] == before["model"], (before, after)
        assert after["wire"] == before["model"], (before, after)

        data = ccr.read_bytes()
        validate(data)
        nodes = _nod_records(data)
        matches = [rec for rec in nodes if rec[0] == IR_MATCH]
        assert matches, "expected at least one IR_MATCH"
        for rec in matches:
            start, count = rec[3], rec[4]
            assert count > 0, rec
            assert 0 <= start < after["wire"], (start, after)
            assert start + count <= after["wire"], (start, count, after)
        rows = _parse_case(segment(data, CASE_TAG))
        assert len(rows) == after["wire"], (len(rows), after)
        _assert_targets_are_labels(data, rows)

        # Warm run: the cache restores the semantic model, not the wire. The
        # entries must hit, the pre-lower wire count must stay zero, and the
        # derived .ccr must be byte-identical.
        entries = [_cache_entry(tmp, fn) for fn in ("pick", "main")]
        stamps = [_entry_stamp(entry) for entry in entries]
        warm_ccr = tmp / "case_model_contract_warm.ccr"
        time.sleep(0.02)
        rw = _run(
            [COREC, "ccr", src, "-o", warm_ccr, "--dump-case-model"],
            cwd=tmp,
        )
        assert rw.returncode == 0, f"warm corec ccr failed: {rw.stdout}\n{rw.stderr}"
        warm_before, warm_after = _case_model_counts(rw.stdout)
        assert warm_before, f"missing warm case_model_before: {rw.stdout!r}"
        assert warm_after, f"missing warm case_model_after: {rw.stdout!r}"
        for entry, stamp in zip(entries, stamps):
            assert _entry_stamp(entry) == stamp, (
                f"{entry.name}: warm run did not hit the cache"
            )
        assert warm_before["model"] == before["model"], (before, warm_before)
        assert warm_before["wire"] == 0, warm_before
        assert warm_after["wire"] == warm_before["model"], (warm_before, warm_after)
        assert warm_ccr.read_bytes() == ccr.read_bytes(), "cold/warm .ccr differ"


def test_cir_cache_restores_match_cases_cold_warm():
    """MATCH functions are saved, hit on the warm path, and rebuild byte-identically."""
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        snaps = _assert_match_cold_warm(
            tmp, MATCH_INT_SOURCE, "match_cache", 42, {"pick": [5]}
        )
        # The old rejection path would never save this entry at all.
        assert snaps["pick"]["instr_count"] > 0


def test_cir_cache_restores_if_cases_cold_warm():
    """If-derived CASE ranges survive the warm CIR cache and stay MATCH."""
    source = """fn main() -> int:
    x := 2
    if x == 1:
        return 10
    if x == 2:
        return 20
    return 30
"""
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        snaps = _assert_match_cold_warm(
            tmp,
            source,
            "if_cache",
            20,
            {"main": [2, 2]},
            include_if=True,
        )
        assert snaps["main"]["instr_count"] > 0
        assert snaps["main"]["match_count"] == 2


def test_cir_cache_two_match_functions_disjoint_ranges():
    """Two cached MATCH functions keep disjoint CASE ranges after restore."""
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        snaps = _assert_match_cold_warm(
            tmp,
            MATCH_TWO_FUNCS_SOURCE,
            "match_two_cache",
            42,
            {"pick_a": [3], "pick_b": [4]},
        )
        warm_data = Path(str(tmp / "warm.elf") + ".ccr").read_bytes()
        nodes = _nod_records(warm_data)
        match_nodes = _pattern_match_nodes(warm_data)
        assert len(match_nodes) == 2, match_nodes
        ranges = sorted(
            (nodes[m][3], nodes[m][3] + nodes[m][4]) for m in match_nodes
        )
        assert ranges[0] == (0, 3), ranges
        assert ranges[1] == (3, 7), ranges
        assert snaps["pick_a"]["match_count"] == 1
        assert snaps["pick_b"]["match_count"] == 1


def test_cir_cache_nested_match_case_order():
    """Nested matches append their range after the enclosing one on both paths."""
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        snaps = _assert_match_cold_warm(
            tmp,
            MATCH_NESTED_CASE_SOURCE,
            "match_nested_cache",
            42,
            {"pick": [3, 2]},
        )
        nested = snaps["pick"]["matches"]
        assert [m["count"] for m in nested] == [3, 2]
        warm_data = Path(str(tmp / "warm.elf") + ".ccr").read_bytes()
        warm_nodes = _nod_records(warm_data)
        assert [
            len(_match_rows(warm_data, warm_nodes[i]))
            for i in _pattern_match_nodes(warm_data)
        ] == [3, 2]


def test_cir_cache_warm_restore_remaps_shifted_case_targets():
    """A hit with a shifted node/instruction baseline rebuilds CASE labels.

    The fingerprints hash the whole source, so a normal warm build cannot shift
    a cached function's baseline. This fixture constructs the shift explicitly:
    the pad function gains one node (no variables), and the cached pick_b/main
    v1 snapshots are re-labelled with their v2 fingerprints. The model stores
    body label numbers, which are unchanged by the shift; ccr_lower must resolve
    them to the new NOD ids so the warm wire matches the cold wire.
    """
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)

        # Baseline: normal cold v2 build in its own directory.
        base_dir = root / "base"
        base_dir.mkdir()
        v2_source = SHIFT_PAD_V2 + "\n" + SHIFT_PICK + "\n" + SHIFT_MAIN
        base_src = _write_source(base_dir, v2_source, "shift")
        base_elf, base_ccr = _build_source(base_dir, base_src, "baseline", base_dir)
        base_pick = _cache_entry(base_dir, "pick_b")
        base_snap = _cir_snapshot(base_pick.read_bytes())
        base_main = _cache_entry(base_dir, "main")
        base_main_snap = _cir_snapshot(base_main.read_bytes())

        # v1: smaller pad, snapshot pick_b at node_start 15.
        work = root / "work"
        work.mkdir()
        v1_source = SHIFT_PAD_V1 + "\n" + SHIFT_PICK + "\n" + SHIFT_MAIN
        work_src = _write_source(work, v1_source, "shift")
        _build_source(work, work_src, "v1", work)
        v1_pick = _cache_entry(work, "pick_b")
        v1_bytes = bytearray(v1_pick.read_bytes())
        v1_snap = _cir_snapshot(bytes(v1_bytes))
        assert v1_snap["node_start"] + 1 == base_snap["node_start"], (
            v1_snap["node_start"],
            base_snap["node_start"],
        )
        assert v1_snap["var_start"] == base_snap["var_start"], (
            v1_snap["var_start"],
            base_snap["var_start"],
        )
        v1_main = _cache_entry(work, "main")
        v1_main_bytes = bytearray(v1_main.read_bytes())
        v1_main_snap = _cir_snapshot(bytes(v1_main_bytes))
        assert v1_main_snap["node_start"] + 1 == base_main_snap["node_start"]
        assert v1_main_snap["var_start"] == base_main_snap["var_start"]

        # Rewrite v2's source and seed pick_b/main with the shifted v1 snapshots
        # plus the v2 fingerprints. pad misses and is regenerated. Keeping main a
        # hit isolates the CASE remap from the separate cache-hit label-counter
        # issue (a regenerated function after a label-using hit starts at 1).
        work_src.write_text(v2_source, encoding="utf-8")
        for entry, old_snap, new_snap in (
            (v1_pick, v1_snap, base_snap),
            (v1_main, v1_main_snap, base_main_snap),
        ):
            data = bytearray(entry.read_bytes())
            struct.pack_into("<q", data, old_snap["fp_offset"], new_snap["fp"])
            struct.pack_into("<q", data, old_snap["fp_offset"] + 8, new_snap["sig"])
            entry.write_bytes(bytes(data))
        stamps = {p.name: _entry_stamp(p) for p in (v1_pick, v1_main)}
        time.sleep(0.02)
        warm_elf, warm_ccr = _build_source(work, work_src, "warm", work)
        for entry in (v1_pick, v1_main):
            assert _entry_stamp(entry) == stamps[entry.name], (
                f"{entry.name}: shifted snapshot did not hit"
            )
        assert warm_elf.read_bytes() == base_elf.read_bytes(), (
            "shifted warm ELF differs from cold"
        )
        assert warm_ccr.read_bytes() == base_ccr.read_bytes(), (
            "shifted warm .ccr differs from cold"
        )
        assert _run_elf(warm_elf) == 42
        _assert_targets_are_labels(
            warm_ccr.read_bytes(), _parse_case(segment(warm_ccr.read_bytes(), CASE_TAG))
        )


def test_cir_cache_tampered_case_section_is_a_miss():
    """Truncated/corrupt CASE payloads rebuild instead of restoring partially."""
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        _clean_cache(tmp)
        src = _write_source(tmp, MATCH_INT_SOURCE, "match_tamper")
        base_elf, base_ccr = _build_source(tmp, src, "baseline", tmp)
        base_bytes = base_elf.read_bytes()
        base_ccr_bytes = base_ccr.read_bytes()
        entry = _cache_entry(tmp, "pick")
        clean = entry.read_bytes()
        snap = _cir_snapshot(clean)
        assert snap["match_count"] == 1 and snap["matches"][0]["count"] == 5
        first_row = snap["matches"][0]["rows"][0]["offset"]

        tampered = []
        # 1. Truncated inside the CASE rows (the trailer is gone).
        tampered.append(("truncated", clean[: first_row + 8]))
        # 2. Invalid target label: no IR_LABEL node in this function carries it.
        bad_target = bytearray(clean)
        struct.pack_into("<i", bad_target, first_row + 16, 0x7FFFFF00)
        tampered.append(("bad_target", bytes(bad_target)))
        # 3. Wrong per-MATCH case count (snapshot disagrees with instruction s3).
        bad_count = bytearray(clean)
        struct.pack_into("<q", bad_count, snap["matches"][0]["count_offset"], 6)
        tampered.append(("wrong_count", bytes(bad_count)))

        for name, data in tampered:
            entry.write_bytes(data)
            stamp = _entry_stamp(entry)
            time.sleep(0.02)
            out_elf, out_ccr = _build_source(tmp, src, f"tampered_{name}", tmp)
            text = f"{name}"
            assert out_elf.read_bytes() == base_bytes, f"{text}: partial/incorrect ELF"
            assert out_ccr.read_bytes() == base_ccr_bytes, f"{text}: partial .ccr"
            assert _entry_stamp(entry) != stamp, f"{text}: cache was not rebuilt"
            fixed = _cir_snapshot(entry.read_bytes())
            _assert_snapshot_case_section(fixed, entry.read_bytes(), [5])
            assert _run_elf(out_elf) == 42, text


def _nod_tamper_fixture(tmp):
    _clean_cache(tmp)
    src = _write_source(tmp, MATCH_INT_SOURCE, "match_nod_tamper")
    base_elf, base_ccr = _build_source(tmp, src, "baseline", tmp)
    entry = _cache_entry(tmp, "pick")
    clean = entry.read_bytes()
    snap = _cir_snapshot(clean)
    _index, nod_off, nod_s2, nod_s3 = _snapshot_match_nod(clean, snap)
    _instr_index, instr_off, instr_s2, instr_s3 = _snapshot_match_instr(clean, snap)
    assert (nod_s2, nod_s3) == (instr_s2, instr_s3) == (0, 5)
    return src, entry, clean, nod_off, base_elf.read_bytes(), base_ccr.read_bytes()


def test_cir_cache_tampered_nod_match_s2_is_a_miss():
    """A NOD s2 that disagrees with the MATCH instruction must be a miss.

    lower_to_ccr rebuilds from NOD, so accepting the tampered mirror would change
    the warm CASE start and the emitted ELF.
    """
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        src, entry, clean, nod_off, base_elf, base_ccr = _nod_tamper_fixture(tmp)
        data = bytearray(clean)
        struct.pack_into("<q", data, nod_off + 24, 1)
        _assert_tampered_rebuild(
            tmp, src, entry, bytes(data), "nod_s2", base_elf, base_ccr
        )


def test_cir_cache_tampered_nod_match_s3_is_a_miss():
    """A NOD s3 that disagrees with the instruction/case count must be a miss."""
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        src, entry, clean, nod_off, base_elf, base_ccr = _nod_tamper_fixture(tmp)
        data = bytearray(clean)
        struct.pack_into("<q", data, nod_off + 32, 4)   # clean count is 5
        _assert_tampered_rebuild(
            tmp, src, entry, bytes(data), "nod_s3", base_elf, base_ccr
        )


def test_cir_cache_rebases_stale_case_start_with_nod_rewrite():
    """A cached MATCH after another cached MATCH is rebased to the reader's table.

    The seeded pick_b snapshot carries a stale writer-side s2 (0) while pick_a
    already restored three rows. The loader must ignore the stale start, rewrite
    both the instruction and the NOD mirror to 3, and still hit. Without the NOD
    rewrite, lower_to_ccr would emit CASE range (0,4) instead of (3,4).
    """
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        _clean_cache(tmp)
        src = _write_source(tmp, MATCH_TWO_FUNCS_SOURCE, "match_case_rebase")
        base_elf, base_ccr = _build_source(tmp, src, "baseline", tmp)
        base_elf_bytes = base_elf.read_bytes()
        base_ccr_bytes = base_ccr.read_bytes()

        entry = _cache_entry(tmp, "pick_b")
        clean = entry.read_bytes()
        snap = _cir_snapshot(clean)
        _ni, nod_off, nod_s2, nod_s3 = _snapshot_match_nod(clean, snap)
        _ii, instr_off, instr_s2, instr_s3 = _snapshot_match_instr(clean, snap)
        assert nod_s2 == instr_s2 == 3, (nod_s2, instr_s2)
        assert nod_s3 == instr_s3 == 4, (nod_s3, instr_s3)

        data = bytearray(clean)
        struct.pack_into("<q", data, nod_off + 24, 0)
        struct.pack_into("<q", data, instr_off + 24, 0)
        entry.write_bytes(bytes(data))
        stamp = _entry_stamp(entry)
        time.sleep(0.02)
        warm_elf, warm_ccr = _build_source(tmp, src, "warm", tmp)
        assert _entry_stamp(entry) == stamp, "stale-s2 snapshot did not hit"
        assert warm_elf.read_bytes() == base_elf_bytes, "warm ELF differs from cold"
        assert warm_ccr.read_bytes() == base_ccr_bytes, "warm .ccr differs from cold"
        assert _run_elf(warm_elf) == 42

        warm_data = warm_ccr.read_bytes()
        nodes = _nod_records(warm_data)
        match_nodes = _pattern_match_nodes(warm_data)
        assert len(match_nodes) == 2, match_nodes
        assert nodes[match_nodes[0]][3] == 0, nodes[match_nodes[0]]
        assert nodes[match_nodes[1]][3] == 3, nodes[match_nodes[1]]
        assert nodes[match_nodes[1]][4] == 4, nodes[match_nodes[1]]



# ---------------------------------------------------------------------------
# 6. Sparse MATCH uses a balanced binary search; dense MATCH uses rodata tables
# ---------------------------------------------------------------------------


def test_sparse_16way_match_is_binary_and_correct():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        source = _sparse_source(16)
        data = _build_ccr(tmp, source, "match_sparse16")
        rec = _single_match(data)
        assert rec[4] == 17, f"MATCH case count {rec[4]} != 16 values + default"
        plans, binary_emits = _match_plan(
            _ccr_file(tmp, data, "match_sparse16_plan")
        )
        assert len(plans) == 1, plans
        assert plans[0]["cases"] == 17, plans
        assert plans[0]["nondefault"] == 16, plans
        assert plans[0]["strategy"] == "binary", plans
        assert binary_emits == 1, f"binary emitter ran {binary_emits} times"
        _assert_program(
            tmp, source, 42, opts=(0, 2, 3), name="match_sparse16"
        )


def test_sparse_64way_match_is_binary_and_correct():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        source = _sparse_source(64)
        data = _build_ccr(tmp, source, "match_sparse64")
        rec = _single_match(data)
        assert rec[4] == 65, f"MATCH case count {rec[4]} != 64 values + default"
        plans, binary_emits = _match_plan(
            _ccr_file(tmp, data, "match_sparse64_plan")
        )
        assert len(plans) == 1, plans
        assert plans[0]["cases"] == 65, plans
        assert plans[0]["nondefault"] == 64, plans
        assert plans[0]["strategy"] == "binary", plans
        assert binary_emits == 1, f"binary emitter ran {binary_emits} times"
        _assert_program(
            tmp, source, 42, opts=(0, 2, 3), name="match_sparse64"
        )


def test_dense_33way_match_is_table_and_correct():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        source = _dense_source(DENSE_WAYS)
        data = _build_ccr(tmp, source, "match_dense")
        rec = _single_match(data)
        assert rec[4] == DENSE_WAYS + 1, rec[4]
        plans, binary_emits, table_emits = _match_plan_full(
            _ccr_file(tmp, data, "match_dense_plan")
        )
        assert len(plans) == 1, plans
        assert plans[0]["nondefault"] == DENSE_WAYS, plans
        assert plans[0]["strategy"] == "table", plans
        assert binary_emits == 0, f"table path also ran binary emitter {binary_emits}x"
        assert table_emits == 1, f"table emitter ran {table_emits} times"
        _assert_program(tmp, source, 42, opts=(0, 2, 3), name="match_dense")

        # Table slots are relative to the table base and resolve to the arm body.
        _elf, elf_data = _build_corearch_elf(tmp, data, "match_dense_elf", opt=2)
        lea, table, entries = _table_region(elf_data, DENSE_WAYS)
        assert table > lea, (lea, table)
        assert table % 4 == 0, table
        assert len(set(entries)) == DENSE_WAYS, entries
        for k, entry in enumerate(entries):
            target = table + entry
            assert 0 <= target < table, (k, entry, target, table)
            assert abs(entry) < table, (k, entry)
            assert elf_data[target : target + 2] == b"\x49\xba", (
                k,
                target,
                elf_data[target : target + 8].hex(),
            )
            imm = struct.unpack_from("<q", elf_data, target + 2)[0]
            assert imm == (k + 1) * 2, (k, imm)


def test_dense_64way_match_is_table_and_correct():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        source = _match_source(list(range(64)))
        data = _build_ccr(tmp, source, "match_dense64")
        rec = _single_match(data)
        assert rec[4] == 65, rec[4]
        plans, binary_emits, table_emits = _match_plan_full(
            _ccr_file(tmp, data, "match_dense64_plan")
        )
        assert plans[0]["nondefault"] == 64, plans
        assert plans[0]["strategy"] == "table", plans
        assert binary_emits == 0, binary_emits
        assert table_emits == 1, table_emits
        _assert_program(tmp, source, 42, opts=(0, 2, 3), name="match_dense64")

        _elf, elf_data = _build_corearch_elf(tmp, data, "match_dense64_elf", opt=2)
        _lea, table, entries = _table_region(elf_data, 64)
        assert len(entries) == 64
        assert len(set(entries)) == 64
        assert all(abs(entry) < table for entry in entries)


def test_two_dense_tables_resolve_global_labels():
    lines = ["fn pick_a(n: int) -> int:", "    return match n:"]
    for value in range(8):
        lines.append(f"        {value} => {value + 1},")
    lines += ["        _ => 99", "", "fn pick_b(n: int) -> int:", "    return match n:"]
    for value in range(100, 116):
        lines.append(f"        {value} => {value - 99},")
    lines += ["        _ => 98", "", "fn main() -> int:"]
    for value in range(8):
        lines.append(f"    if pick_a({value}) != {value + 1}:")
        lines.append(f"        return {10 + value}")
    for value in range(100, 116):
        lines.append(f"    if pick_b({value}) != {value - 99}:")
        lines.append(f"        return {30 + value - 100}")
    lines += ["    if pick_a(50) != 99:", "        return 70"]
    lines += ["    if pick_b(50) != 98:", "        return 71"]
    lines += ["    return 42"]
    source = "\n".join(lines) + "\n"
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_ccr(tmp, source, "match_two_dense")
        assert len(_pattern_match_nodes(data)) == 2
        plans, binary_emits, table_emits = _match_plan_full(
            _ccr_file(tmp, data, "match_two_dense_plan")
        )
        assert [p["strategy"] for p in plans] == ["table", "table"], plans
        assert [p["nondefault"] for p in plans] == [8, 16], plans
        assert binary_emits == 0
        assert table_emits == 2, table_emits
        _assert_program(tmp, source, 42, opts=(0, 2, 3), name="match_two_dense")

        _elf, elf_data = _build_corearch_elf(
            tmp, data, "match_two_dense_elf", opt=2
        )
        stubs = []
        pos = elf_data.find(TABLE_STUB)
        while pos >= 0:
            stubs.append(pos)
            pos = elf_data.find(TABLE_STUB, pos + 1)
        assert len(stubs) == 2, stubs
        for stub, span in zip(stubs, (8, 16)):
            lea = stub - 7
            assert elf_data[lea : lea + 3] == TABLE_LEA_PREFIX
            rel = struct.unpack_from("<i", elf_data, lea + 3)[0]
            table = lea + 7 + rel
            entries = [
                struct.unpack_from("<i", elf_data, table + 4 * k)[0]
                for k in range(span)
            ]
            assert len(set(entries)) == span
            for entry in entries:
                target = table + entry
                assert 0 <= target < table, (table, entry, target)
                assert elf_data[target : target + 2] == b"\x49\xba"


def test_dense_holey_range_uses_default_slots():
    values = [0, 1, 2, 4, 5, 6, 8, 9]
    source = _match_source(values)
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_ccr(tmp, source, "match_holes")
        plans, binary_emits, table_emits = _match_plan_full(
            _ccr_file(tmp, data, "match_holes_plan")
        )
        assert plans[0]["nondefault"] == 8, plans
        assert plans[0]["strategy"] == "table", plans
        assert binary_emits == 0
        assert table_emits == 1
        _assert_program(tmp, source, 42, opts=(0, 2, 3), name="match_holes")

        _elf, elf_data = _build_corearch_elf(tmp, data, "match_holes_elf", opt=2)
        _lea, table, entries = _table_region(elf_data, 10)
        # Holes at 3 and 7 share the DEFAULT target, distinct from every arm.
        assert entries[3] == entries[7], entries
        assert entries[3] not in (entries[0], entries[1], entries[2]), entries
        assert entries[3] not in (entries[4], entries[5], entries[6]), entries
        assert entries[3] not in (entries[8], entries[9]), entries
        default_target = table + entries[3]
        assert elf_data[default_target : default_target + 2] == b"\x49\xba"
        assert struct.unpack_from("<q", elf_data, default_target + 2)[0] == 99 * 2


def test_dense_negative_values_raw_int_table():
    # Negative patterns are not parseable, so build a positive fixture and shift
    # every CASE value down; main probes the shifted values through subtraction.
    patterns = list(range(8, 16))
    lines = ["fn pick(n: int) -> int:", "    return match n:"]
    for i, value in enumerate(patterns):
        lines.append(f"        {value} => {i + 1},")
    lines.append("        _ => 99")
    lines += ["", "fn main() -> int:"]
    for i, value in enumerate(patterns):
        lines.append(f"    if pick({value} - 16) != {i + 1}:")
        lines.append(f"        return {10 + i}")
    lines += [
        "    if pick(0 - 9) != 99:",
        "        return 30",
        "    if pick(0) != 99:",
        "        return 31",
        "    if pick(0 - 1000) != 99:",
        "        return 32",
        "    return 42",
    ]
    source = "\n".join(lines) + "\n"
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_ccr(tmp, source, "match_negative")
        nodes = _nod_records(data)
        match_idx = _pattern_match_nodes(data)[0]
        rows = _match_rows(data, nodes[match_idx])
        shifted = [
            (
                row["value"] - 16,
                row["kind"],
                row["str_index"],
                row["target_nod"],
                row["flags"],
            )
            for row in rows
        ]
        neg = _replace_match_range(data, match_idx, shifted)
        plans, binary_emits, table_emits = _match_plan_full(
            _ccr_file(tmp, neg, "match_negative_plan")
        )
        assert plans[0]["nondefault"] == 8, plans
        assert plans[0]["strategy"] == "table", plans
        assert binary_emits == 0
        assert table_emits == 1
        # Tagged mode represents negative ints as BigInt pointers, so the dense
        # signed range is exercised in raw-int mode (the mode that stores signed
        # machine words directly).
        for opt in (0, 2, 3):
            elf, _elf_data = _build_corearch_elf(
                tmp, neg, f"match_negative_O{opt}", opt=opt, raw=True
            )
            run = subprocess.run(
                [str(elf)], capture_output=True, text=True, timeout=30
            )
            assert run.returncode == 42, (
                f"raw-int negative table -O{opt} returned {run.returncode}"
            )


def test_dense_enum_tagged_and_raw_int_table():
    variants = [f"V{i}" for i in range(10)]
    lines = ["enum E:", "    " + ", ".join(variants), "", "fn pick(e: E) -> int:",
             "    return match e:"]
    for i, variant in enumerate(variants):
        lines.append(f"        {variant} => {i + 1},")
    lines.append("        _ => 99")
    lines += ["", "fn main() -> int:"]
    for i, variant in enumerate(variants):
        lines.append(f"    if pick({variant}()) != {i + 1}:")
        lines.append(f"        return {10 + i}")
    lines.append("    return 42")
    source = "\n".join(lines) + "\n"
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_ccr(tmp, source, "match_enum10")
        rec = _single_match(data)
        assert rec[4] == 11, rec[4]
        plans, binary_emits, table_emits = _match_plan_full(
            _ccr_file(tmp, data, "match_enum10_plan")
        )
        assert plans[0]["nondefault"] == 10, plans
        assert plans[0]["strategy"] == "table", plans
        assert binary_emits == 0
        assert table_emits == 1
        for opt in (0, 2, 3):
            elf, _elf_data = _build_corearch_elf(
                tmp, data, f"match_enum10_O{opt}", opt=opt
            )
            run = subprocess.run([str(elf)], capture_output=True, text=True, timeout=30)
            assert run.returncode == 42, (
                f"tagged enum table -O{opt} returned {run.returncode}"
            )
        raw_elf, _raw_data = _build_corearch_elf(
            tmp, data, "match_enum10_raw", opt=2, raw=True
        )
        run = subprocess.run([str(raw_elf)], capture_output=True, text=True, timeout=30)
        assert run.returncode == 42, f"raw-int enum table returned {run.returncode}"


def test_no_default_dense_match_stays_binary_and_traps():
    values = list(range(16))
    hit_source = _match_source(values, with_default=False, checker_default=True)
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        checked = _build_ccr(tmp, hit_source, "match_dense_nodefault_checked")
        data = _drop_match_default(checked, "match_dense_nodefault")
        rec = _single_match(data)
        assert rec[4] == 16, rec[4]
        plans, binary_emits, table_emits = _match_plan_full(
            _ccr_file(tmp, data, "match_dense_nodefault_plan")
        )
        assert plans[0]["nondefault"] == 16, plans
        # A dense range without DEFAULT must not select a table: holes/misses
        # have no target. Binary keeps the ud2 trap.
        assert plans[0]["strategy"] == "binary", plans
        assert binary_emits == 1, binary_emits
        assert table_emits == 0, table_emits
        _run_opts(tmp, data, "match_dense_nodefault", (0, 2, 3), 42)

        miss_lines = ["fn pick(n: int) -> int:", "    return match n:"]
        for i, value in enumerate(values):
            miss_lines.append(f"        {value} => {i + 1},")
        miss_lines += ["        _ => 0", "", "fn main() -> int:", "    return pick(99)"]
        miss_source = "\n".join(miss_lines) + "\n"
        miss_checked = _build_ccr(
            tmp, miss_source, "match_dense_nodefault_miss_checked"
        )
        miss_data = _drop_match_default(miss_checked, "match_dense_nodefault_miss")
        miss_plans, miss_binary, miss_tables = _match_plan_full(
            _ccr_file(tmp, miss_data, "match_dense_nodefault_miss_plan")
        )
        assert miss_plans[0]["strategy"] == "binary", miss_plans
        assert miss_binary == 1
        assert miss_tables == 0
        _run_opts(tmp, miss_data, "match_dense_nodefault_miss", (0, 2, 3), -4)


def test_dense_threshold_boundary():
    # 8 unique values, span exactly 16 -> table. One wider value makes span 17,
    # which must fall back to the binary tree.
    table_values = list(range(7)) + [15]
    binary_values = list(range(7)) + [16]
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        table_source = _match_source(table_values)
        table_data = _build_ccr(tmp, table_source, "match_boundary_table")
        plans, binary_emits, table_emits = _match_plan_full(
            _ccr_file(tmp, table_data, "match_boundary_table_plan")
        )
        assert plans[0]["nondefault"] == 8, plans
        assert plans[0]["strategy"] == "table", plans
        assert binary_emits == 0
        assert table_emits == 1
        _assert_program(
            tmp, table_source, 42, opts=(0, 2, 3), name="match_boundary_table"
        )

        binary_source = _match_source(binary_values)
        binary_data = _build_ccr(tmp, binary_source, "match_boundary_binary")
        plans, binary_emits, table_emits = _match_plan_full(
            _ccr_file(tmp, binary_data, "match_boundary_binary_plan")
        )
        assert plans[0]["nondefault"] == 8, plans
        assert plans[0]["strategy"] == "binary", plans
        assert binary_emits == 1, binary_emits
        assert table_emits == 0, table_emits
        _assert_program(
            tmp, binary_source, 42, opts=(0, 2, 3), name="match_boundary_binary"
        )


def test_dense_table_with_bigint_string_interning():
    # Regression: IR_CONST_BIG interns a decimal string during Phase 3 via
    # g2_str_off. A g2_rodata_sz()-derived table offset recorded during code
    # emission then pointed into the string area and the table jump crashed.
    source = """fn pick(n: int) -> int:
    return match n:
        0 => 1,
        1 => 2,
        2 => 3,
        3 => 4,
        4 => 5,
        5 => 6,
        6 => 7,
        7 => 8,
        _ => 99

fn main() -> int:
    big := 1180591620717411303424
    if big == 0:
        return 1
    if pick(0) != 1:
        return 10
    if pick(7) != 8:
        return 11
    if pick(9) != 99:
        return 12
    return 42
"""
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_ccr(tmp, source, "match_bigint_string")
        plans, binary_emits, table_emits = _match_plan_full(
            _ccr_file(tmp, data, "match_bigint_string_plan")
        )
        assert plans[0]["nondefault"] == 8, plans
        assert plans[0]["strategy"] == "table", plans
        assert binary_emits == 0
        assert table_emits == 1
        _assert_program(
            tmp, source, 42, opts=(0, 2, 3), name="match_bigint_string"
        )

        # Same-function ordering: the MATCH is emitted before the BigInt literal
        # is interned, so the LEA must still be patched later.
        same_source = """fn same(n: int) -> int:
    r := match n:
        0 => 1,
        1 => 2,
        2 => 3,
        3 => 4,
        4 => 5,
        5 => 6,
        6 => 7,
        7 => 8,
        _ => 99
    big := 1180591620717411303424
    if big == 0:
        return 1
    return r

fn main() -> int:
    if same(0) != 1:
        return 10
    if same(7) != 8:
        return 11
    if same(9) != 99:
        return 12
    return 42
"""
        same_data = _build_ccr(tmp, same_source, "match_bigint_same_fn")
        same_plans, same_binary, same_tables = _match_plan_full(
            _ccr_file(tmp, same_data, "match_bigint_same_fn_plan")
        )
        assert same_plans[0]["strategy"] == "table", same_plans
        assert same_binary == 0
        assert same_tables == 1
        _assert_program(
            tmp,
            same_source,
            42,
            opts=(0, 2, 3),
            name="match_bigint_same_fn",
        )


def test_table_follows_strings_in_rodata():
    values = list(range(8))
    lines = ["fn pick(n: int) -> int:", "    return match n:"]
    for i, value in enumerate(values):
        lines.append(f"        {value} => {i + 1},")
    lines.append("        _ => 99")
    lines += [
        "",
        "fn main() -> int:",
        '    s := "DENSETABLESTRING"',
        '    if s == "SECONDRODATASTRING":',
        "        return 1",
    ]
    for i, value in enumerate(values):
        lines.append(f"    if pick({value}) != {i + 1}:")
        lines.append(f"        return {10 + i}")
    lines.append("    return 42")
    source = "\n".join(lines) + "\n"
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_ccr(tmp, source, "match_strings")
        plans, _binary_emits, table_emits = _match_plan_full(
            _ccr_file(tmp, data, "match_strings_plan")
        )
        assert plans[0]["strategy"] == "table", plans
        assert table_emits == 1
        _elf, elf_data = _build_corearch_elf(tmp, data, "match_strings_elf", opt=2)
        _lea, table, entries = _table_region(elf_data, 8)
        assert len(entries) == 8
        # Tables are written after every string. Confirm both string bodies end
        # before the table base, and the table does not run past the file (the
        # HIT pool, when present, is appended after the tables).
        for text in (b"DENSETABLESTRING", b"SECONDRODATASTRING"):
            pos = elf_data.find(text)
            assert pos >= 0, text
            end = ((pos + len(text) + 1 + 7) // 8) * 8
            assert table >= end, (text, table, end)
        assert table + 8 * 4 <= len(elf_data), (table, len(elf_data))


def test_project_mode_rejects_match_plan_channel():
    # The project-mode entry (.ccr -> ELF only) must keep rejecting the
    # dump-match-plan debug channel; the concat entry owns it.
    text = (
        BASE / "src/targets/x86_64/linux/elf/main.cr"
    ).read_text(encoding="utf-8")
    start = text.index("fn backend_has_extended_flags")
    end = text.index("fn corearch_main")
    guard = text[start:end]
    assert 'cli_has("dump-match-plan")' in guard, guard
    assert "ELF emission only" in text


def test_match_plan_threshold_keeps_1_and_2_case_linear():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        one = _build_ccr(tmp, MATCH_ONE_CASE_SOURCE, "match_one")
        one_plans, one_emits = _match_plan(
            _ccr_file(tmp, one, "match_one_plan")
        )
        assert len(one_plans) == 1, one_plans
        assert one_plans[0]["nondefault"] == 1, one_plans
        assert one_plans[0]["strategy"] == "linear", one_plans
        assert one_emits == 0, f"linear 1-case match ran binary emitter {one_emits}x"

        two = _build_ccr(tmp, MATCH_NO_DEFAULT_HIT_SOURCE, "match_two_values")
        two_plans, two_emits = _match_plan(
            _ccr_file(tmp, two, "match_two_values_plan")
        )
        assert len(two_plans) == 1, two_plans
        assert two_plans[0]["nondefault"] == 2, two_plans
        assert two_plans[0]["strategy"] == "linear", two_plans
        assert two_emits == 0, f"linear 2-case match ran binary emitter {two_emits}x"

        # One source, two functions: 2 values stays linear, 3 goes binary.
        mixed = _build_ccr(tmp, MATCH_TWO_FUNCS_SOURCE, "match_threshold")
        mixed_plans, mixed_emits = _match_plan(
            _ccr_file(tmp, mixed, "match_threshold_plan")
        )
        assert [p["nondefault"] for p in mixed_plans] == [2, 3], mixed_plans
        assert [p["strategy"] for p in mixed_plans] == ["linear", "binary"], mixed_plans
        assert mixed_emits == 1, f"binary emitter ran {mixed_emits} times"

        _assert_program(tmp, MATCH_ONE_CASE_SOURCE, 42, name="match_one")


def test_enum_match_uses_binary_plan():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_ccr(tmp, MATCH_ENUM_SOURCE, "match_enum_plan")
        plans, binary_emits = _match_plan(
            _ccr_file(tmp, data, "match_enum_plan")
        )
        assert len(plans) == 1, plans
        assert plans[0]["nondefault"] == 3, plans
        assert plans[0]["strategy"] == "binary", plans
        assert binary_emits == 1, f"binary emitter ran {binary_emits} times"
        _assert_program(
            tmp, MATCH_ENUM_SOURCE, 42, opts=(0, 2, 3), name="match_enum_plan_run"
        )


def test_sparse_no_default_binary_match_traps_on_miss():
    values = _match_values(16, SPARSE_BASE, SPARSE_STEP)
    hit_source = _match_source(values, with_default=False, checker_default=True)
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        checked = _build_ccr(tmp, hit_source, "match_sparse_nodefault_checked")
        data = _drop_match_default(checked, "match_sparse_nodefault")
        rec = _single_match(data)
        assert rec[4] == 16, rec[4]
        plans, binary_emits = _match_plan(
            _ccr_file(tmp, data, "match_sparse_nodefault_plan")
        )
        assert plans[0]["nondefault"] == 16, plans
        assert plans[0]["strategy"] == "binary", plans
        assert binary_emits == 1, f"binary emitter ran {binary_emits} times"
        _run_opts(tmp, data, "match_sparse_nodefault_hit", (0, 2, 3), 42)

        # The generated checker only probes arm hits; build a single-miss main
        # (with a checker-satisfying wildcard) so the stripped binary tree's miss
        # edge must reach ud2.
        miss_lines = ["fn pick(n: int) -> int:", "    return match n:"]
        for i, value in enumerate(values):
            miss_lines.append(f"        {value} => {i + 1},")
        miss_lines += [
            "        _ => 0",
            "",
            "fn main() -> int:",
            f"    return pick({values[-1] + 7})",
        ]
        miss_source = "\n".join(miss_lines) + "\n"
        miss_checked = _build_ccr(
            tmp, miss_source, "match_sparse_nodefault_miss_checked"
        )
        miss_data = _drop_match_default(
            miss_checked, "match_sparse_nodefault_miss"
        )
        plans, binary_emits = _match_plan(
            _ccr_file(tmp, miss_data, "match_sparse_nodefault_miss_plan")
        )
        assert plans[0]["strategy"] == "binary", plans
        assert binary_emits == 1, f"binary emitter ran {binary_emits} times"
        _run_opts(tmp, miss_data, "match_sparse_nodefault_miss", (0, 2, 3), -4)


def test_duplicate_value_binary_match_keeps_first_case():
    source = """fn pick(n: int) -> int:
    return match n:
        10 => 1,
        20 => 2,
        30 => 3,
        40 => 4,
        _ => 5

fn main() -> int:
    if pick(10) != 1:
        return 10
    if pick(40) != 5:
        return 40
    if pick(20) != 2:
        return 20
    if pick(99) != 5:
        return 99
    return 42
"""
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_ccr(tmp, source, "match_dup")
        rows = _parse_case(segment(data, CASE_TAG))
        records = [
            (row["value"], row["kind"], row["str_index"], row["target_nod"], row["flags"])
            for row in rows
        ]
        # Turn the 40 arm into a duplicate of 10. First-case semantics keep the
        # 10 arm's target, so pick(10) must stay 1 and pick(40) falls through to
        # the default. A last-wins dedupe would return 4 for pick(10).
        records[3] = (
            records[0][0],
            records[3][1],
            records[3][2],
            records[3][3],
            records[3][4],
        )
        dup = _replace_case(data, _pack_case(records))
        plans, binary_emits = _match_plan(
            _ccr_file(tmp, dup, "match_dup_plan")
        )
        assert len(plans) == 1, plans
        assert plans[0]["nondefault"] == 4, plans
        assert plans[0]["strategy"] == "binary", plans
        assert binary_emits == 1, f"binary emitter ran {binary_emits} times"
        for opt in (0, 2, 3):
            assert _run_corearch_elf(tmp, dup, f"match_dup_O{opt}", opt) == 42


# 日常迭代用的代表性子集：覆盖 int/enum/dense/sparse/struct/tuple/string/
# cache/no-default-hit/dump/bigint/loop。三个 no-default trap 测试最慢，留给全量。
FAST_TESTS = {
    "test_int_match_is_one_match_with_default_case",
    "test_enum_match_is_one_match_with_enum_cases",
    "test_dense_33way_match_is_table_and_correct",
    "test_sparse_16way_match_is_binary_and_correct",
    "test_struct_pattern_binds_fields_and_is_refutable",
    "test_tuple_pattern_binds_literals_and_partial",
    "test_string_match_uses_sequential_path",
    "test_cir_cache_restores_match_cases_cold_warm",
    "test_no_default_match_dispatches_hits",
    "test_dump_objects_prints_match_cases",
    "test_dense_table_with_bigint_string_interning",
    "test_loop_match_all_opt_levels",
}


def main():
    tests = [
        value
        for name, value in sorted(globals().items())
        if name.startswith("test_") and callable(value)
    ]
    fast = "--fast" in sys.argv[1:]
    if fast:
        tests = [t for t in tests if t.__name__ in FAST_TESTS]
    failed = 0
    for test in tests:
        try:
            test()
        except Exception as exc:  # noqa: BLE001 - report every failure shape
            failed += 1
            print(f"FAIL {test.__name__}: {exc!r}")
        else:
            print(f"PASS {test.__name__}")
    suffix = " (fast)" if fast else ""
    print(f"{len(tests) - failed}/{len(tests)} passed{suffix}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
