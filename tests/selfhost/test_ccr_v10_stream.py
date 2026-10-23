#!/usr/bin/env python3
"""Task 6: the v10 loader consumes segment bodies in canonical order, forward only.

Wire contract (docs/superpowers/specs/2026-10-23-lattice-ccr-v10-design.md §3):

    STR -> TYPE -> IFACE -> SYM -> NOD -> ENT -> REG -> EDG -> CASE

The segment table may validate boundaries and contiguity, but the parser cursor
starts at the first body and only moves forward. There is no second
random-access entry point in this repository: `load_ccr` in src/compiler/ccr_io.cr
is the only .ccr reader (corearch and the ELF main both call it).

The negative fixtures below are built from a real `.ccr` emitted by `corec`:

  1. canonical image loads and the emitted program still runs;
  2. bodies physically permuted to the legacy dependency order are rejected;
  3. a body truncated while the segment table stays contiguous is rejected;
  4. offsets that are a contiguous partition but place bodies in legacy order
     are rejected (the table is not the parse order).

Runs standalone and is also pytest-discoverable (stdlib only).
"""

import re
import struct
import subprocess
import tempfile
from pathlib import Path

from ccr_v10_model import (
    BODY_START,
    MAGIC,
    SEG_COUNT,
    SEG_TAGS,
    VERSION,
    encode,
    read_segment_table,
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


def _assert_rejected(data, tmp, name):
    r, _out = _elf_result(data, tmp, name)
    assert r.returncode != 0, f"{name}: corearch accepted a non-canonical image"
    assert "invalid" in (r.stdout + r.stderr), f"{name}: missing diagnostic: {r.stdout}{r.stderr}"


def _bodies_in_physical_order(data, order):
    """Re-emit the image with bodies placed in `order`, table tags canonical.

    `encode` always writes table entries 1..9 with ascending contiguous
    offsets, so the result has a canonical table and permuted body content.
    """
    bodies = _split(data)
    # Physical slot i (table tag i+1) carries the body of the i-th name in
    # `order`; sizes follow the body, so the table stays contiguous.
    return encode({tag: bodies[TAG_OF[order[tag - 1]]] for tag in SEG_TAGS})


def _truncated_nod(data, cut=4):
    bodies = _split(data)
    assert len(bodies[TAG_OF["NOD"]]) > cut + 40
    bodies[TAG_OF["NOD"]] = bodies[TAG_OF["NOD"]][:-cut]
    return encode(bodies)


def _permuted_offset_image(data):
    """Legacy body placement with a contiguous partition of offsets.

    Tags stay canonical (1..9), every size is truthful, and the offset set
    covers [124, EOF) with no gap or overlap, but offsets are assigned by body
    location instead of table order. This is the "structurally valid table,
    old body order" shape: a random-access reader could follow it, a forward
    cursor cannot.
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

    header = struct.pack("<IIII", MAGIC, VERSION, SEG_COUNT, 0)
    table = b"".join(
        struct.pack("<III", tag, offsets[tag], len(bodies[tag]))
        for tag in SEG_TAGS
    )
    return header + table + b"".join(placed)


_FN_START = re.compile(r"^fn load_ccr\(", re.MULTILINE)
_NEXT_FN = re.compile(r"^fn ", re.MULTILINE)
_SECTION = re.compile(
    r"^\s*// === (STR|TYPE|IFACE|SYM|NOD|ENT|REG|EDG|CASE)(?:\(|:)", re.MULTILINE
)
_BACKWARD_SEEK = re.compile(r"^\s*pos = seg_off\d", re.MULTILINE)


def _load_ccr_source():
    text = CCR_IO.read_text(encoding="utf-8")
    start = _FN_START.search(text)
    assert start, "fn load_ccr not found in ccr_io.cr"
    rest = text[start.start() :]
    nxt = _NEXT_FN.search(rest, 1)
    assert nxt, "fn load_ccr body has no following top-level function"
    return rest[: nxt.start()]


# ---------------------------------------------------------------------------
# 1. parse order is the canonical order, forward only (source evidence)
# ---------------------------------------------------------------------------


def test_loader_parses_canonical_order_forward_only():
    body = _load_ccr_source()
    order = []
    for name in _SECTION.findall(body):
        if not order or order[-1] != name:
            order.append(name)
    assert order == list(CANONICAL_ORDER), (
        "load_ccr parse order is not canonical: " + " -> ".join(order)
    )
    assert _BACKWARD_SEEK.search(body) is None, (
        "load_ccr still seeks to a segment-table offset: "
        + repr(_BACKWARD_SEEK.search(body).group(0))
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
# 3. non-canonical body order rejected
# ---------------------------------------------------------------------------


def test_legacy_body_order_rejected():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_ccr(tmp)
        bad = _bodies_in_physical_order(data, LEGACY_ORDER)
        assert bad != data, "fixture did not permute any body"
        table = read_segment_table(bad)
        assert [tag for tag, _o, _s in table] == list(SEG_TAGS)
        expected = BODY_START
        for _tag, offset, size in table:
            assert offset == expected, "fixture table is not contiguous"
            expected += size
        assert expected == len(bad)
        _assert_rejected(bad, tmp, "legacy_order")


# ---------------------------------------------------------------------------
# 4. truncated segment body rejected (table stays contiguous)
# ---------------------------------------------------------------------------


def test_truncated_segment_body_rejected():
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
        _assert_rejected(bad, tmp, "truncated_nod")


# ---------------------------------------------------------------------------
# 5. contiguous offsets but legacy body order rejected
# ---------------------------------------------------------------------------


def test_contiguous_offsets_with_legacy_body_order_rejected():
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        data = _build_ccr(tmp)
        bad = _permuted_offset_image(data)

        table = read_segment_table(bad)
        assert [tag for tag, _o, _s in table] == list(SEG_TAGS)
        # Offsets are a contiguous partition of the body area, just not in
        # table order: a tag->offset random reader could walk it.
        spans = sorted((offset, offset + size) for _tag, offset, size in table)
        assert spans[0][0] == BODY_START
        for (start, end), (next_start, _next_end) in zip(spans, spans[1:]):
            assert start < end
            assert end == next_start, "fixture offsets have a gap/overlap"
        assert spans[-1][1] == len(bad)

        _assert_rejected(bad, tmp, "permuted_offsets")


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
