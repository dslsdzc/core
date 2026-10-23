#!/usr/bin/env python3
"""Task 7: `.ccrb` is an external distribution wrapper around a raw v10 `.ccr`.

The bundle payload is a deterministic PAX tar:

    manifest
    program.ccr
    coi/<target>.coi        (optional, opaque)

One zstd frame wraps the tar. `corearch` never sees the bundle; it only reads
the extracted `program.ccr`, so the runtime has no zstd dependency.

Runs standalone and is also pytest-discoverable (stdlib only).
"""

import hashlib
import io
import json
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parent.parent.parent
COREC = BASE / "build" / "corec"
COREARCH = BASE / "build" / "corearch"
CCRB = BASE / "tools" / "ccrb.py"
ZSTD = shutil.which("zstd") or "/usr/bin/zstd"

DEFAULT_TARGET = "x86_64/linux/elf"
SOURCE = """fn main() -> int:
    return 7
"""


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------


def _run(cmd, timeout=180, input_bytes=None):
    return subprocess.run(
        [str(part) for part in cmd],
        input=input_bytes,
        capture_output=True,
        cwd=str(BASE),
        timeout=timeout,
    )


def _build_ccr(tmp):
    src = tmp / "bundle_probe.cr"
    ccr = tmp / "bundle_probe.ccr"
    src.write_text(SOURCE, encoding="utf-8")
    r = _run([COREC, "ccr", src, "-o", ccr])
    assert r.returncode == 0, f"corec ccr failed: {r.stdout}\n{r.stderr}"
    return ccr.read_bytes()


def _pack(tmp, ccr_path, name, coi=None, target=None):
    out = tmp / name
    cmd = [sys.executable, str(CCRB), "pack", "--ccr", str(ccr_path), "--out", str(out)]
    if coi is not None:
        cmd += ["--coi", str(coi)]
    if target is not None:
        cmd += ["--target", target]
    return _run(cmd), out


def _unpack(bundle, outdir):
    return _run(
        [sys.executable, str(CCRB), "unpack", "--bundle", str(bundle), "--outdir", str(outdir)]
    )


def _decompress(bundle):
    r = subprocess.run(
        [ZSTD, "-q", "-d", "--no-progress", "-c", str(bundle)],
        capture_output=True,
        cwd=str(BASE),
        timeout=120,
    )
    assert r.returncode == 0, f"zstd -d failed: {r.stdout!r}\n{r.stderr!r}"
    return r.stdout


def _compress(payload):
    r = subprocess.run(
        [ZSTD, "-q", "-19", "--no-progress", "-T1", "-c"],
        input=payload,
        capture_output=True,
        cwd=str(BASE),
        timeout=120,
    )
    assert r.returncode == 0, f"zstd failed: {r.stdout!r}\n{r.stderr!r}"
    return r.stdout


def _tar_entries(payload):
    with tarfile.open(fileobj=io.BytesIO(payload), mode="r:") as tf:
        entries = []
        for member in tf.getmembers():
            extracted = tf.extractfile(member)
            assert extracted is not None, f"no data for tar entry {member.name}"
            entries.append((member, extracted.read()))
    return entries


def _write_tar(entries):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as tf:
        for name, data in entries:
            info = tarfile.TarInfo(name)
            info.size = len(data)
            info.mode = 0o644
            info.uid = 0
            info.gid = 0
            info.uname = ""
            info.gname = ""
            info.mtime = 0
            info.pax_headers = {}
            tf.addfile(info, io.BytesIO(data))
    return buf.getvalue()


def _bundle_entries(bundle):
    return [(member.name, data) for member, data in _tar_entries(_decompress(bundle))]


def _rewrite_bundle(bundle, entries):
    bundle.write_bytes(_compress(_write_tar(entries)))


def _manifest(entries):
    return json.loads(entries[0][1].decode("utf-8"))


def _sha256(data):
    return hashlib.sha256(data).hexdigest()


def _text(result):
    return (result.stdout + result.stderr).decode("utf-8", "replace")


def _assert_fixed_metadata(member):
    assert member.isfile(), f"{member.name}: expected a regular file"
    assert member.uid == 0, f"{member.name}: uid={member.uid}"
    assert member.gid == 0, f"{member.name}: gid={member.gid}"
    assert member.uname == "", f"{member.name}: uname={member.uname!r}"
    assert member.gname == "", f"{member.name}: gname={member.gname!r}"
    assert member.mtime == 0, f"{member.name}: mtime={member.mtime}"
    assert member.mode == 0o644, f"{member.name}: mode={oct(member.mode)}"
    assert member.pax_headers == {}, f"{member.name}: pax_headers={member.pax_headers!r}"


def _assert_pax_format(payload):
    # POSIX ustar header used by tarfile.PAX_FORMAT, with version "00".
    assert payload[257:263] == b"ustar\x00", payload[257:263]
    assert payload[263:265] == b"00", payload[263:265]


def _assert_corearch_loads(ccr_path, tmp, name):
    elf = tmp / f"{name}.elf"
    r = _run([COREARCH, str(ccr_path), "--elf", "--static", "-o", str(elf)])
    assert r.returncode == 0, f"corearch rejected raw .ccr: {r.stdout}\n{r.stderr}"
    assert elf.is_file() and elf.stat().st_size > 0, "corearch produced no ELF"


# ---------------------------------------------------------------------------
# 1. no sidecar: deterministic bytes, fixed layout, round trip
# ---------------------------------------------------------------------------


def test_pack_without_coi_is_deterministic_and_fixed():
    with tempfile.TemporaryDirectory(dir=BASE) as td:
        tmp = Path(td)
        ccr_bytes = _build_ccr(tmp)
        ccr_path = tmp / "bundle_probe.ccr"

        first, first_path = _pack(tmp, ccr_path, "plain-a.ccrb")
        second, second_path = _pack(tmp, ccr_path, "plain-b.ccrb")
        assert first.returncode == 0, f"pack failed: {first.stdout}\n{first.stderr}"
        assert second.returncode == 0, f"pack failed: {second.stdout}\n{second.stderr}"
        assert first_path.read_bytes() == second_path.read_bytes(), (
            "two packs of the same inputs are not byte-identical"
        )

        payload = _decompress(first_path)
        _assert_pax_format(payload)
        entries = _tar_entries(payload)
        assert [member.name for member, _data in entries] == ["manifest", "program.ccr"]
        for member, _data in entries:
            _assert_fixed_metadata(member)

        manifest_bytes = entries[0][1]
        manifest = _manifest([(member, data) for member, data in entries])
        assert set(manifest) == {"bundle_version", "format", "program"}
        assert manifest["bundle_version"] == 1
        assert manifest["format"] == "ccr-v10"
        assert manifest["program"] == {
            "path": "program.ccr",
            "sha256": _sha256(ccr_bytes),
            "size": len(ccr_bytes),
        }
        assert entries[1][1] == ccr_bytes, "packed program.ccr differs from input"

        outdir = tmp / "plain-out"
        r = _unpack(first_path, outdir)
        assert r.returncode == 0, f"unpack failed: {r.stdout}\n{r.stderr}"
        assert (outdir / "program.ccr").read_bytes() == ccr_bytes
        assert (outdir / "manifest").read_bytes() == manifest_bytes
        assert not (outdir / "coi").exists(), "plain bundle produced a coi payload"
        _assert_corearch_loads(outdir / "program.ccr", tmp, "plain")


# ---------------------------------------------------------------------------
# 2. optional sidecar: opaque payload, unchanged program, deletable
# ---------------------------------------------------------------------------


def test_pack_with_coi_is_deterministic_and_sidecar_is_optional():
    with tempfile.TemporaryDirectory(dir=BASE) as td:
        tmp = Path(td)
        ccr_bytes = _build_ccr(tmp)
        ccr_path = tmp / "bundle_probe.ccr"
        coi_bytes = b"\x00COI\x01" + bytes(range(64)) + b"opaque-sidecar"
        coi_path = tmp / "sidecar.coi"
        coi_path.write_bytes(coi_bytes)

        first, first_path = _pack(tmp, ccr_path, "with-coi-a.ccrb", coi=coi_path)
        second, second_path = _pack(tmp, ccr_path, "with-coi-b.ccrb", coi=coi_path)
        assert first.returncode == 0, f"pack failed: {first.stdout}\n{first.stderr}"
        assert second.returncode == 0, f"pack failed: {second.stdout}\n{second.stderr}"
        assert first_path.read_bytes() == second_path.read_bytes(), (
            "two sidecar packs of the same inputs are not byte-identical"
        )

        entries = _bundle_entries(first_path)
        expected_name = f"coi/{DEFAULT_TARGET}.coi"
        assert [name for name, _data in entries] == ["manifest", "program.ccr", expected_name]
        for member, _data in _tar_entries(_decompress(first_path)):
            _assert_fixed_metadata(member)

        manifest = _manifest(entries)
        assert set(manifest) == {"bundle_version", "format", "program", "coi"}
        assert manifest["coi"] == {
            "target": DEFAULT_TARGET,
            "path": expected_name,
            "sha256": _sha256(coi_bytes),
            "size": len(coi_bytes),
        }
        assert entries[1][1] == ccr_bytes
        assert entries[2][1] == coi_bytes

        outdir = tmp / "with-coi-out"
        r = _unpack(first_path, outdir)
        assert r.returncode == 0, f"unpack failed: {r.stdout}\n{r.stderr}"
        assert (outdir / "program.ccr").read_bytes() == ccr_bytes
        sidecar_out = outdir / manifest["coi"]["path"]
        assert sidecar_out.read_bytes() == coi_bytes

        # Deleting the sidecar after unpack must not touch the raw program.
        sidecar_out.unlink()
        assert (outdir / "program.ccr").read_bytes() == ccr_bytes
        _assert_corearch_loads(outdir / "program.ccr", tmp, "with-coi-deleted")

        # The same raw .ccr packaged without a sidecar stays byte-identical.
        plain, plain_path = _pack(tmp, ccr_path, "with-coi-removed.ccrb")
        assert plain.returncode == 0, f"pack failed: {plain.stdout}\n{plain.stderr}"
        plain_entries = _bundle_entries(plain_path)
        assert [name for name, _data in plain_entries] == ["manifest", "program.ccr"]
        assert plain_entries[1][1] == ccr_bytes
        plain_out = tmp / "with-coi-removed-out"
        r = _unpack(plain_path, plain_out)
        assert r.returncode == 0, f"unpack failed: {r.stdout}\n{r.stderr}"
        assert (plain_out / "program.ccr").read_bytes() == ccr_bytes
        _assert_corearch_loads(plain_out / "program.ccr", tmp, "with-coi-removed")


def test_explicit_target_controls_sidecar_path():
    with tempfile.TemporaryDirectory(dir=BASE) as td:
        tmp = Path(td)
        ccr_bytes = _build_ccr(tmp)
        coi_path = tmp / "sidecar.coi"
        coi_path.write_bytes(b"target-scoped-opaque-bytes")
        target = "aarch64/linux/elf"
        r, bundle = _pack(tmp, tmp / "bundle_probe.ccr", "target.ccrb", coi=coi_path, target=target)
        assert r.returncode == 0, f"pack failed: {r.stdout}\n{r.stderr}"

        entries = _bundle_entries(bundle)
        assert [name for name, _data in entries] == [
            "manifest",
            "program.ccr",
            f"coi/{target}.coi",
        ]
        manifest = _manifest(entries)
        assert manifest["coi"]["target"] == target
        assert manifest["coi"]["path"] == f"coi/{target}.coi"
        assert entries[1][1] == ccr_bytes

        outdir = tmp / "target-out"
        r = _unpack(bundle, outdir)
        assert r.returncode == 0, f"unpack failed: {r.stdout}\n{r.stderr}"
        assert (outdir / f"coi/{target}.coi").read_bytes() == b"target-scoped-opaque-bytes"


# ---------------------------------------------------------------------------
# 3. path traversal targets are rejected before anything is written
# ---------------------------------------------------------------------------


def test_pack_rejects_unsafe_target_names():
    with tempfile.TemporaryDirectory(dir=BASE) as td:
        tmp = Path(td)
        ccr = tmp / "program.ccr"
        ccr.write_bytes(b"raw-ccr-placeholder")
        coi = tmp / "sidecar.coi"
        coi.write_bytes(b"opaque")

        for index, target in enumerate(
            [
                "../evil",
                "../../evil",
                "/absolute/evil",
                "x/../../evil",
                "x//evil",
                "x/./evil",
                ".",
                "",
                "x/",
                "x\\evil",
            ]
        ):
            r, out = _pack(
                tmp,
                ccr,
                f"bad-target-{index}.ccrb",
                coi=coi,
                target=target,
            )
            assert r.returncode != 0, f"unsafe target accepted: {target!r}"
            assert not out.exists(), f"unsafe target wrote a bundle: {target!r}"
            assert "error" in _text(r).lower()


# ---------------------------------------------------------------------------
# 4. tampered manifest/body and unsafe bundle paths are rejected
# ---------------------------------------------------------------------------


def test_unpack_rejects_tampered_body_and_manifest():
    with tempfile.TemporaryDirectory(dir=BASE) as td:
        tmp = Path(td)
        ccr_bytes = _build_ccr(tmp)
        coi_bytes = b"opaque-coi-bytes"
        coi_path = tmp / "sidecar.coi"
        coi_path.write_bytes(coi_bytes)
        r, bundle = _pack(tmp, tmp / "bundle_probe.ccr", "tamper.ccrb", coi=coi_path)
        assert r.returncode == 0, f"pack failed: {r.stdout}\n{r.stderr}"
        good_entries = _bundle_entries(bundle)

        # Body bit flip: same size, different sha256.
        bad_body = list(good_entries)
        corrupted = bytearray(bad_body[1][1])
        corrupted[-1] ^= 0xFF
        bad_body[1] = ("program.ccr", bytes(corrupted))
        _rewrite_bundle(bundle, bad_body)
        outdir = tmp / "bad-body-out"
        r = _unpack(bundle, outdir)
        assert r.returncode != 0, "tampered program body was accepted"
        combined = _text(r).lower()
        assert "sha256" in combined or "hash" in combined, combined
        assert not (outdir / "program.ccr").exists(), "failed unpack wrote program.ccr"

        # Manifest hash mismatch: body untouched, manifest lies.
        manifest = _manifest(good_entries)
        manifest["program"]["sha256"] = "0" * 64
        bad_manifest = list(good_entries)
        bad_manifest[0] = (
            "manifest",
            json.dumps(manifest, sort_keys=True, separators=(",", ":")).encode("utf-8"),
        )
        _rewrite_bundle(bundle, bad_manifest)
        r = _unpack(bundle, tmp / "bad-manifest-out")
        assert r.returncode != 0, "tampered manifest hash was accepted"
        combined = _text(r).lower()
        assert "sha256" in combined or "hash" in combined, combined

        # Declared sidecar removed from the tar: manifest is no longer satisfied.
        _rewrite_bundle(bundle, list(good_entries[:2]))
        r = _unpack(bundle, tmp / "missing-coi-out")
        assert r.returncode != 0, "manifest-declared coi was allowed to disappear"
        assert not (tmp / "missing-coi-out" / "program.ccr").exists()

        # A null sidecar record is malformed rather than an absent sidecar.
        null_coi = _manifest(good_entries)
        null_coi["coi"] = None
        null_entries = list(good_entries)
        null_entries[0] = (
            "manifest",
            json.dumps(null_coi, sort_keys=True, separators=(",", ":")).encode("utf-8"),
        )
        _rewrite_bundle(bundle, null_entries)
        r = _unpack(bundle, tmp / "null-coi-out")
        assert r.returncode != 0, "null coi record was accepted"
        assert not (tmp / "null-coi-out" / "program.ccr").exists()

        # Unsafe sidecar path in both the manifest and the tar entry.
        traversal_manifest = _manifest(good_entries)
        traversal_manifest["coi"]["target"] = "../evil"
        traversal_manifest["coi"]["path"] = "coi/../evil.coi"
        traversal_entries = [
            (
                "manifest",
                json.dumps(traversal_manifest, sort_keys=True, separators=(",", ":")).encode(
                    "utf-8"
                ),
            ),
            ("program.ccr", ccr_bytes),
            ("coi/../evil.coi", coi_bytes),
        ]
        _rewrite_bundle(bundle, traversal_entries)
        r = _unpack(bundle, tmp / "traversal-out")
        assert r.returncode != 0, "path-traversal bundle was accepted"
        assert not (tmp / "traversal-out" / "program.ccr").exists()


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
