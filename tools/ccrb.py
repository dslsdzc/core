#!/usr/bin/env python3
"""Pack and unpack `.ccrb` distribution bundles.

`.ccrb` is an external distribution wrapper, not a compiler input format. The
payload is a deterministic POSIX/PAX tar inside one zstd frame:

    manifest                      JSON, UTF-8, sorted keys, compact separators
    program.ccr                   raw v10 `.ccr`, byte-for-byte unchanged
    coi/<target>.coi              optional opaque sidecar

`corearch` never reads a bundle and never needs zstd: it only reads the raw
`program.ccr` extracted from one. `.coi` contents are intentionally opaque here;
their semantics belong to the independent `.coi` plan.

Usage:

    tools/ccrb.py pack --ccr <path> --out <path> [--coi <path>] [--target <name>]
    tools/ccrb.py unpack --bundle <path> --outdir <dir>

The packer uses the system `zstd` CLI and the Python standard library only.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import re
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path, PurePosixPath

MANIFEST_NAME = "manifest"
PROGRAM_NAME = "program.ccr"
COI_DIR = "coi"
DEFAULT_TARGET = "x86_64/linux/elf"
BUNDLE_VERSION = 1
FORMAT = "ccr-v10"
FIXED_MODE = 0o644
ZSTD_LEVEL = "-19"

_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


class BundleError(Exception):
    """Raised for an invalid input, unsafe path, or failed validation."""


# ---------------------------------------------------------------------------
# zstd
# ---------------------------------------------------------------------------


def _zstd_binary():
    exe = shutil.which("zstd")
    if exe is None:
        raise BundleError("zstd CLI not found; tools/ccrb.py requires it for distribution")
    return exe


def _compress(payload):
    """Compress `payload` into a single deterministic zstd frame."""
    cmd = [_zstd_binary(), "-q", ZSTD_LEVEL, "--no-progress", "-T0", "-c"]
    result = subprocess.run(cmd, input=payload, capture_output=True)
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", "replace").strip()
        raise BundleError(f"zstd compression failed: {detail or result.returncode}")
    return result.stdout


def _decompress(bundle_path):
    cmd = [_zstd_binary(), "-q", "-d", "--no-progress", "-c", str(bundle_path)]
    result = subprocess.run(cmd, capture_output=True)
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", "replace").strip()
        raise BundleError(f"zstd decompression failed: {detail or result.returncode}")
    return result.stdout


# ---------------------------------------------------------------------------
# deterministic tar
# ---------------------------------------------------------------------------


def _sha256(data):
    return hashlib.sha256(data).hexdigest()


def _canonical_json(value):
    return json.dumps(
        value,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    ).encode("utf-8")


def _add_tar_entry(tf, name, data):
    info = tarfile.TarInfo(name)
    info.size = len(data)
    info.mode = FIXED_MODE
    info.uid = 0
    info.gid = 0
    info.uname = ""
    info.gname = ""
    info.mtime = 0
    info.type = tarfile.REGTYPE
    info.pax_headers = {}
    tf.addfile(info, io.BytesIO(data))


def _build_tar(manifest_bytes, program_bytes, coi_bytes=None, target=None):
    buf = io.BytesIO()
    with tarfile.open(
        fileobj=buf,
        mode="w",
        format=tarfile.PAX_FORMAT,
        encoding="utf-8",
    ) as tf:
        _add_tar_entry(tf, MANIFEST_NAME, manifest_bytes)
        _add_tar_entry(tf, PROGRAM_NAME, program_bytes)
        if coi_bytes is not None:
            _add_tar_entry(tf, f"{COI_DIR}/{target}.coi", coi_bytes)
    return buf.getvalue()


def _parse_tar(payload):
    try:
        tf = tarfile.open(fileobj=io.BytesIO(payload), mode="r:")
        entries = []
        with tf:
            for member in tf.getmembers():
                _check_member_path(member.name)
                _check_member_metadata(member)
                extracted = tf.extractfile(member)
                if extracted is None:
                    raise BundleError(f"tar entry has no data: {member.name}")
                entries.append((member.name, extracted.read()))
    except BundleError:
        raise
    except (tarfile.TarError, OSError, ValueError, UnicodeError) as exc:
        raise BundleError(f"bundle payload is not a valid tar archive: {exc}") from exc
    if not entries:
        raise BundleError("bundle tar is empty")
    return entries


def _check_member_metadata(member):
    if not member.isfile():
        raise BundleError(f"unsupported tar entry type: {member.name}")
    if member.uid != 0 or member.gid != 0:
        raise BundleError(f"unexpected tar ownership on {member.name}")
    if member.uname != "" or member.gname != "":
        raise BundleError(f"unexpected tar user/group name on {member.name}")
    if member.mtime != 0:
        raise BundleError(f"unexpected tar mtime on {member.name}")
    if member.mode != FIXED_MODE:
        raise BundleError(f"unexpected tar mode on {member.name}")


def _check_member_path(name):
    """Reject absolute and traversal names without trusting tarfile sanitizing."""
    if not name:
        raise BundleError("tar entry has an empty name")
    if name.startswith("/") or "\\" in name or "\x00" in name:
        raise BundleError(f"unsafe tar entry path: {name!r}")
    if any(ord(ch) < 0x20 for ch in name):
        raise BundleError(f"unsafe tar entry path: {name!r}")
    parts = name.split("/")
    if any(part in ("", ".", "..") for part in parts):
        raise BundleError(f"unsafe tar entry path: {name!r}")
    if str(PurePosixPath(name)) != name:
        raise BundleError(f"non-canonical tar entry path: {name!r}")


def _validate_target(target):
    """A target is a safe relative POSIX path such as `x86_64/linux/elf`."""
    if not isinstance(target, str) or not target:
        raise BundleError("coi target must be a non-empty relative path")
    if target.startswith("/") or "\\" in target or "\x00" in target:
        raise BundleError(f"unsafe coi target: {target!r}")
    if any(ord(ch) < 0x20 for ch in target):
        raise BundleError(f"unsafe coi target: {target!r}")
    parts = target.split("/")
    if any(part in ("", ".", "..") for part in parts):
        raise BundleError(f"unsafe coi target: {target!r}")
    if str(PurePosixPath(target)) != target:
        raise BundleError(f"non-canonical coi target: {target!r}")


# ---------------------------------------------------------------------------
# manifest
# ---------------------------------------------------------------------------


def _program_record(program_bytes):
    return {
        "path": PROGRAM_NAME,
        "sha256": _sha256(program_bytes),
        "size": len(program_bytes),
    }


def _coi_record(coi_bytes, target):
    return {
        "target": target,
        "path": f"{COI_DIR}/{target}.coi",
        "sha256": _sha256(coi_bytes),
        "size": len(coi_bytes),
    }


def _parse_manifest(raw):
    try:
        manifest = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise BundleError(f"manifest is not valid UTF-8 JSON: {exc}") from exc

    if not isinstance(manifest, dict):
        raise BundleError("manifest must be a JSON object")

    allowed = {"bundle_version", "format", "program", "coi"}
    unknown = set(manifest) - allowed
    if unknown:
        raise BundleError(f"manifest has unexpected keys: {sorted(unknown)}")
    required = {"bundle_version", "format", "program"}
    missing = required - set(manifest)
    if missing:
        raise BundleError(f"manifest is missing keys: {sorted(missing)}")

    version = manifest["bundle_version"]
    if type(version) is not int or version != BUNDLE_VERSION:
        raise BundleError(f"unsupported bundle_version: {version!r}")
    if manifest["format"] != FORMAT:
        raise BundleError(f"unsupported bundle format: {manifest['format']!r}")

    _check_record(manifest["program"], "program", {"path", "sha256", "size"})
    if manifest["program"]["path"] != PROGRAM_NAME:
        raise BundleError(f"program path must be {PROGRAM_NAME!r}")

    if "coi" in manifest:
        coi = manifest["coi"]
        _check_record(coi, "coi", {"target", "path", "sha256", "size"})
        _validate_target(coi["target"])
        expected = f"{COI_DIR}/{coi['target']}.coi"
        if coi["path"] != expected:
            raise BundleError(f"coi path must be {expected!r}")
    return manifest


def _check_record(record, label, keys):
    if not isinstance(record, dict):
        raise BundleError(f"manifest {label} must be an object")
    if set(record) != keys:
        raise BundleError(f"manifest {label} has unexpected keys: {sorted(record)}")
    size = record["size"]
    if type(size) is not int or size < 0:
        raise BundleError(f"manifest {label} has an invalid size: {size!r}")
    digest = record["sha256"]
    if not isinstance(digest, str) or not _SHA256_RE.fullmatch(digest):
        raise BundleError(f"manifest {label} has an invalid sha256: {digest!r}")


def _verify_payload(label, data, record):
    if len(data) != record["size"]:
        raise BundleError(
            f"{label} size mismatch: manifest says {record['size']}, payload is {len(data)}"
        )
    actual = _sha256(data)
    if actual != record["sha256"]:
        raise BundleError(
            f"{label} sha256 mismatch: manifest says {record['sha256']}, payload is {actual}"
        )


# ---------------------------------------------------------------------------
# pack / unpack
# ---------------------------------------------------------------------------


def pack(args):
    ccr_path = Path(args.ccr)
    program_bytes = ccr_path.read_bytes()

    coi_bytes = None
    target = None
    if args.coi is not None:
        coi_bytes = Path(args.coi).read_bytes()
        target = args.target if args.target is not None else DEFAULT_TARGET
        _validate_target(target)
    elif args.target is not None:
        raise BundleError("--target requires --coi")

    manifest = {
        "bundle_version": BUNDLE_VERSION,
        "format": FORMAT,
        "program": _program_record(program_bytes),
    }
    if coi_bytes is not None:
        manifest["coi"] = _coi_record(coi_bytes, target)

    tar_bytes = _build_tar(
        _canonical_json(manifest),
        program_bytes,
        coi_bytes=coi_bytes,
        target=target,
    )
    bundle = _compress(tar_bytes)

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(bundle)
    return out


def unpack(args):
    bundle_path = Path(args.bundle)
    payload = _decompress(bundle_path)
    entries = _parse_tar(payload)

    if entries[0][0] != MANIFEST_NAME:
        raise BundleError("bundle must start with the manifest entry")
    if len(entries) < 2 or entries[1][0] != PROGRAM_NAME:
        raise BundleError(f"bundle must contain {PROGRAM_NAME!r} after the manifest")

    manifest = _parse_manifest(entries[0][1])
    expected_names = [MANIFEST_NAME, PROGRAM_NAME]
    if "coi" in manifest:
        expected_names.append(manifest["coi"]["path"])
    actual_names = [name for name, _data in entries]
    if actual_names != expected_names:
        raise BundleError(
            f"unexpected bundle entries: expected {expected_names}, got {actual_names}"
        )

    program_bytes = entries[1][1]
    _verify_payload(PROGRAM_NAME, program_bytes, manifest["program"])

    coi_bytes = None
    if "coi" in manifest:
        coi_bytes = entries[2][1]
        _verify_payload(manifest["coi"]["path"], coi_bytes, manifest["coi"])

    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)
    (outdir / MANIFEST_NAME).write_bytes(entries[0][1])
    (outdir / PROGRAM_NAME).write_bytes(program_bytes)
    if coi_bytes is not None:
        coi_out = outdir / manifest["coi"]["path"]
        coi_out.parent.mkdir(parents=True, exist_ok=True)
        coi_out.write_bytes(coi_bytes)
    return outdir


def _parser():
    parser = argparse.ArgumentParser(
        prog="ccrb.py",
        description="Pack or unpack a .ccrb distribution bundle.",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    pack_cmd = sub.add_parser("pack", help="wrap a raw .ccr in a .ccrb bundle")
    pack_cmd.add_argument("--ccr", required=True, help="raw v10 .ccr input")
    pack_cmd.add_argument("--out", required=True, help="bundle output path")
    pack_cmd.add_argument("--coi", help="optional opaque .coi sidecar")
    pack_cmd.add_argument(
        "--target",
        help=f"sidecar target path (default: {DEFAULT_TARGET})",
    )
    pack_cmd.set_defaults(func=pack)

    unpack_cmd = sub.add_parser("unpack", help="extract a .ccrb bundle")
    unpack_cmd.add_argument("--bundle", required=True, help="bundle input path")
    unpack_cmd.add_argument("--outdir", required=True, help="extraction directory")
    unpack_cmd.set_defaults(func=unpack)
    return parser


def main(argv=None):
    args = _parser().parse_args(argv)
    try:
        args.func(args)
    except BundleError as exc:
        print(f"ccrb: error: {exc}", file=sys.stderr)
        return 1
    except OSError as exc:
        print(f"ccrb: error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
