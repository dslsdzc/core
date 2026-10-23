#!/usr/bin/env python3
"""v10 `.ccr` wire-format oracle.

Implements only the physical carrier (spec §3): a 16-byte header, a fixed
9 x 12-byte segment table, and nine contiguous segment bodies in canonical
order. It deliberately knows nothing about NOD/ENT/EDG semantics.

Wire layout (little-endian throughout):

    offset 0   magic      u32 = 0x31524343 ("CCR1")
    offset 4   version    u32 = 0x000A0000
    offset 8   seg_count  u32 = 9
    offset 12  flags      u32 (bit 3+ reserved, must be 0)
    offset 16  table      9 x {tag u32, offset u32, size u32}
    offset 124 bodies     canonical tag order 1..9

Invariants enforced by `validate`:
  * exact magic/version/seg_count;
  * table tags strictly ascending 1..9 (no unknown/duplicate/missing tags);
  * first body offset == 124 and bodies are contiguous;
  * final body end == file length (no overlap, no out-of-bounds, no trailing
    bytes).
"""

import struct

MAGIC = 0x31524343  # "CCR1" little-endian
VERSION = 0x000A0000
SEG_COUNT = 9

HEADER_SIZE = 16
SEGMENT_ENTRY_SIZE = 12
SEGMENT_TABLE_SIZE = SEG_COUNT * SEGMENT_ENTRY_SIZE
BODY_START = HEADER_SIZE + SEGMENT_TABLE_SIZE  # 124

SEG_TAGS = {
    1: "STR",
    2: "TYPE",
    3: "IFACE",
    4: "SYM",
    5: "NOD",
    6: "ENT",
    7: "REG",
    8: "EDG",
    9: "CASE",
}

FLAGS_KNOWN_MASK = 0x7  # PORTABLE | SYSTEM | CONCURRENT


class CcrV10Error(ValueError):
    """Raised for any malformed v10 `.ccr` wire image."""


def _as_bytes(data):
    if isinstance(data, (bytes, bytearray, memoryview)):
        return bytes(data)
    raise CcrV10Error(f"expected bytes-like input, got {type(data).__name__}")


def _read_u32(data, offset):
    if offset < 0 or offset + 4 > len(data):
        raise CcrV10Error(
            f"read past end: u32 at offset {offset} needs 4 bytes, "
            f"file length {len(data)}"
        )
    return struct.unpack_from("<I", data, offset)[0]


def read_u32(data, offset):
    """Read one little-endian u32, raising `CcrV10Error` when truncated."""
    return _read_u32(_as_bytes(data), offset)


def magic(data):
    return read_u32(data, 0)


def version(data):
    return read_u32(data, 4)


def seg_count(data):
    return read_u32(data, 8)


def flags(data):
    return read_u32(data, 12)


def read_segment_table(data):
    """Return the 9 raw `(tag, offset, size)` triples without validating."""
    data = _as_bytes(data)
    if len(data) < BODY_START:
        raise CcrV10Error(
            f"truncated header/segment table: {len(data)} < {BODY_START} bytes"
        )
    table = []
    for index in range(SEG_COUNT):
        base = HEADER_SIZE + index * SEGMENT_ENTRY_SIZE
        tag, offset, size = struct.unpack_from("<III", data, base)
        table.append((tag, offset, size))
    return table


def _patch_u32(data, offset, value):
    data = bytearray(_as_bytes(data))
    if offset < 0 or offset + 4 > len(data):
        raise CcrV10Error(
            f"patch past end: u32 at offset {offset}, file length {len(data)}"
        )
    if not 0 <= value <= 0xFFFFFFFF:
        raise CcrV10Error(f"u32 value out of range: {value}")
    struct.pack_into("<I", data, offset, value)
    return bytes(data)


def patch_u32(data, offset, value):
    """Return a copy of `data` with the little-endian u32 at `offset` replaced."""
    return _patch_u32(data, offset, value)


def patch_segment_entry(data, index, tag=None, offset=None, size=None):
    """Return a copy with table entry `index` fields overridden.

    Any field left as `None` keeps its current value.
    """
    data = _as_bytes(data)
    if not 0 <= index < SEG_COUNT:
        raise CcrV10Error(f"segment table index out of range: {index}")
    current_tag, current_offset, current_size = read_segment_table(data)[index]

    values = {
        "tag": current_tag if tag is None else tag,
        "offset": current_offset if offset is None else offset,
        "size": current_size if size is None else size,
    }
    patched = data
    for field_index, field_name in enumerate(("tag", "offset", "size")):
        patched = _patch_u32(
            patched,
            HEADER_SIZE + index * SEGMENT_ENTRY_SIZE + field_index * 4,
            values[field_name],
        )
    return patched


def segment(data, tag):
    """Return a segment body by tag, after full validation."""
    data = _as_bytes(data)
    validate(data)
    for entry_tag, offset, size in read_segment_table(data):
        if entry_tag == tag:
            return data[offset : offset + size]
    raise CcrV10Error(f"segment tag not present: {tag}")


def encode(segments):
    """Serialize a complete tag->body mapping into a v10 `.ccr` image.

    All nine tags must be present; bodies may be empty. Missing, unknown, or
    non-bytes entries raise `CcrV10Error`. Output is canonical and deterministic
    regardless of input dict order.
    """
    if not isinstance(segments, dict):
        raise CcrV10Error(f"segments must be a dict, got {type(segments).__name__}")

    unknown = [tag for tag in segments if tag not in SEG_TAGS]
    if unknown:
        raise CcrV10Error(f"unknown segment tag(s): {unknown!r}")
    missing = [tag for tag in SEG_TAGS if tag not in segments]
    if missing:
        raise CcrV10Error(f"missing segment tag(s): {missing!r}")

    bodies = []
    for tag in SEG_TAGS:
        body = segments[tag]
        if not isinstance(body, (bytes, bytearray, memoryview)):
            raise CcrV10Error(
                f"segment {tag} ({SEG_TAGS[tag]}) body must be bytes-like, "
                f"got {type(body).__name__}"
            )
        bodies.append(bytes(body))

    header = struct.pack("<IIII", MAGIC, VERSION, SEG_COUNT, 0)

    table = bytearray()
    offset = BODY_START
    for tag, body in zip(SEG_TAGS, bodies):
        table += struct.pack("<III", tag, offset, len(body))
        offset += len(body)

    return header + bytes(table) + b"".join(bodies)


def validate(data):
    """Check a v10 `.ccr` image end to end; raise `CcrV10Error` on any defect.

    Returns `None` on success.
    """
    data = _as_bytes(data)

    if len(data) < BODY_START:
        raise CcrV10Error(
            f"truncated header/segment table: {len(data)} < {BODY_START} bytes"
        )

    found_magic = _read_u32(data, 0)
    if found_magic != MAGIC:
        raise CcrV10Error(
            f"bad magic: 0x{found_magic:08X}, expected 0x{MAGIC:08X}"
        )

    found_version = _read_u32(data, 4)
    if found_version != VERSION:
        raise CcrV10Error(
            f"unsupported version: 0x{found_version:08X}, expected 0x{VERSION:08X}"
        )

    found_count = _read_u32(data, 8)
    if found_count != SEG_COUNT:
        raise CcrV10Error(
            f"bad segment count: {found_count}, expected {SEG_COUNT}"
        )

    found_flags = _read_u32(data, 12)
    if found_flags & ~FLAGS_KNOWN_MASK:
        raise CcrV10Error(
            f"reserved header flag bits set: 0x{found_flags:08X}"
        )

    table = read_segment_table(data)

    seen = set()
    for index, (tag, _offset, _size) in enumerate(table):
        expected_tag = index + 1
        if tag != expected_tag:
            if tag in seen:
                raise CcrV10Error(
                    f"duplicate segment tag {tag} at table entry {index}"
                )
            if tag not in SEG_TAGS:
                raise CcrV10Error(
                    f"unknown segment tag {tag} at table entry {index}"
                )
            raise CcrV10Error(
                f"missing segment tag {expected_tag} at table entry {index} "
                f"(found {tag})"
            )
        seen.add(tag)

    expected_offset = BODY_START
    for index, (tag, offset, size) in enumerate(table):
        if offset != expected_offset:
            raise CcrV10Error(
                f"segment {tag} ({SEG_TAGS[tag]}) body not contiguous: "
                f"offset {offset}, expected {expected_offset} "
                f"(gap or overlap at table entry {index})"
            )
        expected_offset += size

    if expected_offset > len(data):
        raise CcrV10Error(
            f"segment bodies out of bounds: end {expected_offset} > "
            f"file length {len(data)}"
        )
    if expected_offset < len(data):
        raise CcrV10Error(
            f"trailing bytes after final segment: {len(data) - expected_offset} "
            f"unconsumed"
        )

    return None


def decode(data):
    """Validate and split an image into `{tag: body}` in canonical order."""
    data = _as_bytes(data)
    validate(data)
    segments = {}
    for tag, offset, size in read_segment_table(data):
        segments[tag] = data[offset : offset + size]
    return segments
