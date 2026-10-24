#!/usr/bin/env python3
"""Task 6: the v10 loader consumes segment bodies in canonical order, forward only.

Wire contract (docs/superpowers/specs/2026-10-23-lattice-ccr-v10-design.md §3):

    STR -> TYPE -> IFACE -> SYM -> NOD -> ENT -> REG -> EDG -> CASE

The segment table may validate boundaries and contiguity, but the parser cursor
starts at the first body and only moves forward. There is no second
random-access entry point in this repository: `load_ccr` in src/compiler/ccr_io.cr
is the only .ccr reader (corearch and the ELF main both call it).

The negative fixtures below are built from a real `.ccr` emitted by `corec`, but
they test different layers:

  1. canonical image loads and the emitted program still runs;
  2. a wire-valid table whose slot contents are permuted is rejected during body
     parsing (tag/content mismatch);
  3. a body truncated while the segment table stays contiguous is rejected during
     body parsing;
  4. offsets that are a contiguous partition but not in table order are rejected
     by the pre-existing table monotonicity check, before any body is parsed.

None of 2-4 can distinguish a random-access reader from a forward-only reader.
Under the v10 table rule (tags in canonical order, offsets contiguous and
ascending) the physical body order is forced to be canonical, so an image that
preserves the table rule cannot express legacy body order at all. A permuted
table bypasses the rule but is rejected before parsing. The discriminating gate
is therefore structural: `test_loader_parse_structure_is_canonical_forward_only`
checks the actual cursor reads (segment-end order, every `pos` assignment
advances, and every read uses the cursor), not comments.

Runs standalone and is also pytest-discoverable (stdlib only).
"""

import re
import struct
import subprocess
import tempfile
from pathlib import Path

from ccr_v10_model import (
    BODY_START,
    CcrV10Error,
    FLAG_PORTABLE,
    FLAG_SYSTEM,
    MAGIC,
    SEG_COUNT,
    SEG_TAGS,
    VERSION,
    encode,
    flags,
    magic,
    read_segment_table,
    seg_count,
    validate,
    version,
)

BASE = Path(__file__).resolve().parent.parent.parent
COREC = BASE / "build" / "corec"
COREARCH = BASE / "build" / "corearch"
CCR_IO = BASE / "src" / "compiler" / "ccr_io.cr"

CANONICAL_ORDER = ("STR", "TYPE", "IFACE", "SYM", "NOD", "ENT", "REG", "EDG", "CASE")
# Pre-v10 loader dependency order (the order this task removes).
LEGACY_ORDER = ("STR", "SYM", "REG", "NOD", "ENT", "EDG", "TYPE", "IFACE", "CASE")

TAG_OF = {name: tag for tag, name in SEG_TAGS.items()}

# Exercises globals, function calls, arrays, and pointer ops so every segment
# body is non-trivial and distinguishable.
SOURCE = """fn add(a: int, b: int) -> int:
    return a + b

fn main() -> int:
    arr : ., mut = [10, 20, 30]
    i := 1
    arr[i] = 9
    p := &arr[1]
    *p = 11
    return add(*p + arr[0] + arr[2], 0)
"""

EXPECTED_EXIT = 51  # add(11 + 10 + 30, 0)


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------


def _run(cmd, timeout=180):
    return subprocess.run(
        [str(part) for part in cmd],
        capture_output=True,
        text=True,
        cwd=str(BASE),
        timeout=timeout,
    )


def _build_ccr(tmp):
    src = tmp / "stream_probe.cr"
    ccr = tmp / "stream_probe.ccr"
    src.write_text(SOURCE, encoding="utf-8")
    r = _run([COREC, "ccr", src, "-o", ccr])
    assert r.returncode == 0, f"corec ccr failed: {r.stdout}\n{r.stderr}"
    return ccr.read_bytes()


def _split(data):
    bodies = {}
    for tag, offset, size in read_segment_table(data):
        bodies[tag] = data[offset : offset + size]
    return bodies


def _elf_result(data, tmp, name):
    ccr = tmp / f"{name}.ccr"
    out = tmp / f"{name}.elf"
    ccr.write_bytes(data)
    return _run([COREARCH, ccr, "--elf", "--static", "-o", out]), out


def _assert_header_valid(data, name):
    """Every negative fixture must clear the header gate it is not testing."""
    assert magic(data) == MAGIC, f"{name}: bad magic in fixture"
    assert version(data) == VERSION, f"{name}: bad version in fixture"
    assert seg_count(data) == SEG_COUNT, f"{name}: bad seg_count in fixture"
    f = flags(data)
    assert f & ~0x7 == 0, f"{name}: reserved header bits set: {f:#x}"
    assert (f & 0x3) in (FLAG_PORTABLE, FLAG_SYSTEM), \
        f"{name}: fixture does not set exactly one of PORTABLE/SYSTEM: {f:#x}"
    assert not (f & 0x4) or (f & FLAG_SYSTEM), \
        f"{name}: CONCURRENT without SYSTEM: {f:#x}"


def _assert_rejected(data, tmp, name, wire_valid):
    """Assert rejection at the expected layer.

    `wire_valid` means the v10 table itself is well formed (canonical tags,
    contiguous ascending offsets, exact file length), so the rejection must come
    from body parsing. Otherwise the wire table check must reject before parse.
    """
    _assert_header_valid(data, name)
    if wire_valid:
        validate(data)
    else:
        try:
            validate(data)
        except CcrV10Error:
            pass
        else:
            raise AssertionError(f"{name}: expected the wire table check to reject")

    r, _out = _elf_result(data, tmp, name)
    out = r.stdout + r.stderr
    assert r.returncode != 0, f"{name}: corearch accepted a non-canonical image"
    # corearch prints this exact text when load_ccr returns -1; the size gate
    # prints a different message and would mean the fixture never reached it.
    assert "error: invalid .ccr file" in out, f"{name}: missing loader diagnostic: {out}"


def _tag_content_mismatch_image(data, order):
    """Wire-valid table, slot contents permuted to `order`.

    The table says slot 2 is TYPE but the bytes there are another segment body.
    This is a tag/content mismatch: a random-access reader that seeks to the
    slot also rejects it. It is retained as structural validation, not as proof
    of forward consumption.
    """
    bodies = _split(data)
    # Physical slot i (table tag i+1) carries the body of the i-th name in
    # `order`; sizes follow the body, so the table stays contiguous.
    return encode(
        {tag: bodies[TAG_OF[order[tag - 1]]] for tag in SEG_TAGS},
        flags=flags(data),
    )


def _truncated_nod(data, cut=4):
    bodies = _split(data)
    assert len(bodies[TAG_OF["NOD"]]) > cut + 40
    bodies[TAG_OF["NOD"]] = bodies[TAG_OF["NOD"]][:-cut]
    return encode(bodies, flags=flags(data))


def _permuted_offset_image(data):
    """Legacy body placement with offsets that form a contiguous partition.

    Tags stay canonical (1..9), every size is truthful, and the offset set
    covers [124, EOF) with no gap or overlap, but offsets are not ascending in
    table order. The loader's pre-existing `soff != cursor` check rejects this
    image before any body is parsed, so it is not evidence for the streaming
    cursor. Under the v10 table rule an ascending table forces canonical body
    order, so no wire-valid legacy-order image exists.
    """
    bodies = _split(data)
    placed = []
    offset = BODY_START
    offsets = {}
    for name in LEGACY_ORDER:
        tag = TAG_OF[name]
        offsets[tag] = offset
        placed.append(bodies[tag])
        offset += len(bodies[tag])

    header = struct.pack("<IIII", MAGIC, VERSION, SEG_COUNT, flags(data))
    table = b"".join(
        struct.pack("<III", tag, offsets[tag], len(bodies[tag]))
        for tag in SEG_TAGS
    )
    return header + table + b"".join(placed)


_FN_START = re.compile(r"^fn load_ccr\(", re.MULTILINE)
_NEXT_FN = re.compile(r"^fn ", re.MULTILINE)
# A body read bound at segment N: ccr_has_bytes(pos, ..., seg_endN).
_BODY_CHECK = re.compile(r"ccr_has_bytes\(\s*pos\s*,[^)]*?seg_end([1-9])\)")
_POS_ASSIGN = re.compile(r"^\s*pos = (.+)$", re.MULTILINE)
_READ_POS = re.compile(
    r"\b(?:buf_read_u32|buf_read_i32|buf_read_i64|cell_load_byte)\(data,\s*([^)\n]+)\)"
)
_CCR_HAS_POS = re.compile(r"ccr_has_bytes\(\s*([^,\n]+),")
_TEMP_FROM_BOUND = re.compile(
    r"^\s*(?!pos\b)([A-Za-z_]\w*)\s*(?::[^=\n]+)?=\s*seg_(?:off|end)[1-9]\b",
    re.MULTILINE,
)
_COMMENT = re.compile(r"//.*$")


def _load_ccr_source():
    text = CCR_IO.read_text(encoding="utf-8")
    start = _FN_START.search(text)
    assert start, "fn load_ccr not found in ccr_io.cr"
    rest = text[start.start() :]
    nxt = _NEXT_FN.search(rest, 1)
    assert nxt, "fn load_ccr body has no following top-level function"
    return rest[: nxt.start()]


# ---------------------------------------------------------------------------
# 1. parse structure: canonical segment-end order, one forward cursor
# ---------------------------------------------------------------------------


def test_loader_parse_structure_is_canonical_forward_only():
    body = _load_ccr_source()

    # 1. The first body read bound at each seg_endN must appear in canonical
    #    order. This inspects real ccr_has_bytes guards, not comments.
    first_seen = {}
    for match in _BODY_CHECK.finditer(body):
        first_seen.setdefault(int(match.group(1)), match.start())
    assert sorted(first_seen) == list(range(1, 10)), (
        f"load_ccr does not guard all nine segment bodies: {sorted(first_seen)}"
    )
    read_order = [
        seg for seg, _pos in sorted(first_seen.items(), key=lambda item: item[1])
    ]
    assert read_order == list(range(1, 10)), (
        "load_ccr first reads segment ends out of canonical order: "
        + " -> ".join(f"seg_end{n}" for n in read_order)
    )

    # 2. Every cursor assignment must advance from the cursor itself. The only
    #    non-advancing value allowed is an initial zero before the first body;
    #    the current function declares `pos : ., mut = 0` and has no such
    #    assignment, so any bare `pos = 0`, `pos = seg_offN`, `pos = seg_endN`,
    #    or `pos = tmp` is rejected.
    first_body = body.index("ccr_has_bytes(pos,")
    assignments = 0
    for match in _POS_ASSIGN.finditer(body):
        rhs = _COMMENT.sub("", match.group(1)).strip()
        if rhs == "0" and match.start() < first_body:
            continue
        assert re.fullmatch(r"pos \+ .+", rhs), (
            f"load_ccr assigns pos without advancing the cursor: {rhs!r}"
        )
        assignments += 1
    assert assignments > 0, "no cursor assignments found in load_ccr"

    # 3. Every byte read and bound check must use the cursor. A temporary
    #    variable seek would read from something other than `pos`.
    for match in _READ_POS.finditer(body):
        expr = _COMMENT.sub("", match.group(1)).strip()
        assert expr == "pos", f"load_ccr reads from a non-cursor offset: {expr!r}"
    for match in _CCR_HAS_POS.finditer(body):
        expr = match.group(1).strip()
        assert expr == "pos", f"load_ccr bounds a read at a non-cursor offset: {expr!r}"

    # 4. Segment-table offsets may only feed bound math of the same segment,
    #    never a parse position, and no temp may capture a segment bound.
    for line in body.splitlines():
        stripped = line.strip()
        if "seg_off" not in stripped:
            continue
        ok = (
            re.fullmatch(r"seg_off[1-9] : \., mut = 0", stripped)
            or re.fullmatch(r"seg_off[1-9] = soff", stripped)
            or re.fullmatch(
                r".*\(seg_end([1-9]) - seg_off\1\) / .*", stripped
            )
        )
        assert ok, f"load_ccr uses a segment-table offset outside bound math: {stripped}"
    assert _TEMP_FROM_BOUND.search(body) is None, (
        "load_ccr captures a segment bound in a temporary: "
        + repr(_TEMP_FROM_BOUND.search(body).group(0))
    )


# ---------------------------------------------------------------------------
# 2. canonical file loads and behaves exactly as before
# ---------------------------------------------------------------------------


def test_canonical_file_loads():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_ccr(tmp)
        r, out = _elf_result(data, tmp, "canonical")
        assert r.returncode == 0, f"canonical v10 rejected: {r.stdout}\n{r.stderr}"
        assert out.exists(), "corearch produced no ELF"

        run = subprocess.run([str(out)], capture_output=True, text=True, timeout=10)
        assert run.returncode == EXPECTED_EXIT, (
            f"canonical ELF returned {run.returncode}, expected {EXPECTED_EXIT}"
        )


# ---------------------------------------------------------------------------
# 3. tag/content mismatch (wire-valid table, body parse rejects)
# ---------------------------------------------------------------------------


def test_tag_content_mismatch_rejected():
    """Slot contents are permuted, so a slot's tag disagrees with its bytes.

    The table is wire-valid (canonical tags, ascending contiguous offsets), so
    rejection happens in body parsing. This is not proof of forward-only
    consumption: a random-access reader that seeks to the slot sees the same
    mismatch. Forward order is proven by the structural test above.
    """
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_ccr(tmp)
        bad = _tag_content_mismatch_image(data, LEGACY_ORDER)
        assert bad != data, "fixture did not permute any body"
        table = read_segment_table(bad)
        assert [tag for tag, _o, _s in table] == list(SEG_TAGS)
        expected = BODY_START
        for _tag, offset, size in table:
            assert offset == expected, "fixture table is not contiguous"
            expected += size
        assert expected == len(bad)
        _assert_rejected(bad, tmp, "tag_content_mismatch", wire_valid=True)


# ---------------------------------------------------------------------------
# 4. truncated segment body rejected (table stays contiguous)
# ---------------------------------------------------------------------------


def test_truncated_segment_body_rejected():
    """Wire-valid table, short body: rejection comes from body parsing."""
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_ccr(tmp)
        bad = _truncated_nod(data)
        table = read_segment_table(bad)
        expected = BODY_START
        for _tag, offset, size in table:
            assert offset == expected, "fixture table is not contiguous"
            expected += size
        assert expected == len(bad)
        _assert_rejected(bad, tmp, "truncated_nod", wire_valid=True)


# ---------------------------------------------------------------------------
# 5. permuted table offsets (rejected by the table check before body parse)
# ---------------------------------------------------------------------------


def test_permuted_offsets_rejected_before_body_parse():
    """Offsets are a contiguous partition but not ascending in table order.

    The loader's `soff != cursor` check rejects this image during table
    validation, before any body is parsed. It documents why a legacy-order
    image cannot also keep a valid v10 table; it is not streaming evidence.
    """
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_ccr(tmp)
        bad = _permuted_offset_image(data)

        table = read_segment_table(bad)
        assert [tag for tag, _o, _s in table] == list(SEG_TAGS)
        # Offsets are a contiguous partition of the body area, just not in
        # table order.
        spans = sorted((offset, offset + size) for _tag, offset, size in table)
        assert spans[0][0] == BODY_START
        for (start, end), (next_start, _next_end) in zip(spans, spans[1:]):
            assert start < end
            assert end == next_start, "fixture offsets have a gap/overlap"
        assert spans[-1][1] == len(bad)

        _assert_rejected(
            bad, tmp, "permuted_offsets", wire_valid=False
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
