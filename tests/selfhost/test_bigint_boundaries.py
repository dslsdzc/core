#!/usr/bin/env python3
"""Self-hosted BigInt pointer/word/FFI and static --link layout gate."""

import struct
import subprocess
import tempfile
from pathlib import Path
import shutil

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"
COREARCH = BASE / "build" / "corearch"

VALID = r"""
import rawbuf

fn main() -> int:
    buf := alloc(32)
    cell_store(buf, 0, 42)
    if cell_load(buf, 0) != 42:
        return 1

    x := 4611686018427387904
    cell_store(buf, 8, x)
    if cell_load(buf, 8) != x:
        return 2

    rawWrite8(buf, 16, 65)
    if rawRead8(buf, 16) != 65:
        return 3

    pid := syscall3(39, 0, 0, 0)
    if pid <= 0:
        return 4

    s : ., mut = "hi"
    p : ., mut = 0
    q : ., mut = 0
    unsafe:
        p = @ptr_of(s)
        q = @ptr_of(@str_of(p))
    if q != p:
        return 5
    if p <= 0:
        return 6

    addr := @addr(main)
    if addr <= 0:
        return 7

    arr := [x, x + 1, x + 2]
    base := &arr[1]
    next := base + 1
    if *next != x + 2:
        return 8
    diff := next - base
    if diff != 1:
        return 9
    if *(base - 1) != x:
        return 10

    return 0
"""

W64_BIG = r"""
fn main() -> int:
    buf := alloc(8)
    x := 1267650600228229401496703205376
    cell_store(buf, 0, x)
    return 0
"""

STR_OF_BIG = r"""
fn main() -> int:
    x := 1267650600228229401496703205376
    p : ., mut = ""
    unsafe:
        p = @str_of(x)
    return 0
"""

EXTERN = r"""
extern fn big_inc(x: int) -> int
fn main() -> int:
    x := 4611686018427387904
    if big_inc(x) != x + 1:
        return 1
    return 0
"""

EXTERN_BIG = r"""
extern fn big_inc(x: int) -> int
fn main() -> int:
    x := 1267650600228229401496703205376
    return big_inc(x)
"""


def run(args):
    return subprocess.run(args, cwd=str(BASE), capture_output=True, text=True)


def build(src: Path, ccr: Path, exe: Path) -> str:
    r = run([str(COREC), "ccr", str(src), "-o", str(ccr)])
    if r.returncode != 0:
        return r.stdout + r.stderr
    r = run([str(COREARCH), str(ccr), "--big-int", "-o", str(exe)])
    if r.returncode != 0:
        return r.stdout + r.stderr
    return ""


def expect_error(src: Path, ccr: Path, exe: Path, needle: str) -> str:
    err = build(src, ccr, exe)
    if err:
        return "compile: " + err
    r = run([str(exe)])
    if r.returncode == 0:
        return "expected runtime failure"
    if needle not in (r.stdout + r.stderr):
        return f"missing {needle!r}: {r.stdout + r.stderr!r}"
    return ""


def build_link(src: Path, ccr: Path, exe: Path, shim: Path) -> str:
    r = run([str(COREC), "ccr", str(src), "-o", str(ccr)])
    if r.returncode != 0:
        return r.stdout + r.stderr
    r = run([str(COREARCH), str(ccr), "--big-int", "--elf",
             "--link", str(shim), "--static", "-o", str(exe)])
    if r.returncode != 0:
        return r.stdout + r.stderr
    exe.chmod(0o755)
    return ""


def elf_layout(path: Path):
    """Return (entry, PT_LOAD vaddrs) for the two-load user ELF."""
    b = path.read_bytes()
    entry = struct.unpack_from("<Q", b, 24)[0]
    phoff = struct.unpack_from("<Q", b, 32)[0]
    phnum = struct.unpack_from("<H", b, 56)[0]
    loads = []
    for i in range(phnum):
        off = phoff + i * 56
        if struct.unpack_from("<I", b, off)[0] == 1:
            loads.append(struct.unpack_from("<Q", b, off + 16)[0])
    return entry, loads


def main() -> int:
    if not COREC.exists() or not COREARCH.exists():
        print("missing build/corec or build/corearch")
        return 1
    with tempfile.TemporaryDirectory(prefix="core-bigint-boundaries-") as td:
        d = Path(td)
        src = d / "valid.cr"
        ccr = d / "valid.ccr"
        exe = d / "valid"
        src.write_text(VALID, encoding="utf-8")
        err = build(src, ccr, exe)
        if err:
            print(err)
            return 1
        r = run([str(exe)])
        if r.returncode != 0:
            print(f"boundaries exit {r.returncode}")
            return 1

        for name, text, needle in (
            ("w64_big", W64_BIG, "machine-word range"),
            ("str_of_big", STR_OF_BIG, "machine-word range"),
        ):
            s = d / f"{name}.cr"
            c = d / f"{name}.ccr"
            e = d / name
            s.write_text(text, encoding="utf-8")
            err = expect_error(s, c, e, needle)
            if err:
                print(f"{name}: {err}")
                return 1

        if shutil.which("gcc"):
            shim_c = d / "int_shim.c"
            shim = d / "int_shim.so"
            shim_c.write_text("long big_inc(long x) { return x + 1; }\n",
                              encoding="utf-8")
            r = run(["gcc", "-shared", "-fPIC", "-O2", str(shim_c),
                     "-o", str(shim)])
            if r.returncode != 0:
                print("shim build failed:\n" + r.stdout + r.stderr)
                return 1
            esrc = d / "extern.cr"
            eccr = d / "extern.ccr"
            eexe = d / "extern"
            esrc.write_text(EXTERN, encoding="utf-8")
            err = build_link(esrc, eccr, eexe, shim)
            if err:
                print("extern link failed:\n" + err)
                return 1
            er = run([str(eexe)])
            if er.returncode != 0:
                print(f"extern valid exit {er.returncode}")
                return 1

            ebsrc = d / "extern_big.cr"
            ebccr = d / "extern_big.ccr"
            ebexe = d / "extern_big"
            ebsrc.write_text(EXTERN_BIG, encoding="utf-8")
            err = build_link(ebsrc, ebccr, ebexe, shim)
            if err:
                print("extern big link failed:\n" + err)
                return 1
            ebr = run([str(ebexe)])
            if ebr.returncode == 0 or "machine-word range" not in (ebr.stdout + ebr.stderr):
                print("extern big argument was not rejected")
                return 1

            # The static linker must keep the BSS page and entry that elf_gen
            # patched into the user code. bss_init is emitted after bss_va, so
            # images whose size is 1..22 bytes past a page used to move the
            # linked BSS one page up and fault on the first global write.
            pad_n = 3904
            pad_src = d / "paged.cr"
            pad_ccr = d / "paged.ccr"
            pad_un = d / "paged_unlinked"
            pad_ok = False
            for _ in range(6):
                pad_src.write_text(
                    "extern fn big_inc(x: int) -> int\n"
                    "g : int, mut = 5\n"
                    "fn main() -> int:\n"
                    "    s := \"" + ("a" * pad_n) + "\"\n"
                    "    g = big_inc(g)\n"
                    "    if g != 6:\n"
                    "        return 1\n"
                    "    if str_len(s) != " + str(pad_n) + ":\n"
                    "        return 2\n"
                    "    return 0\n",
                    encoding="utf-8")
                r = run([str(COREC), "ccr", str(pad_src), "-o", str(pad_ccr)])
                if r.returncode != 0:
                    print("paged ccr failed:\n" + r.stdout + r.stderr)
                    return 1
                r = run([str(COREARCH), str(pad_ccr), "--big-int", "--elf",
                         "-o", str(pad_un)])
                if r.returncode != 0:
                    print("paged unlinked build failed:\n" + r.stdout + r.stderr)
                    return 1
                rem = pad_un.stat().st_size % 4096
                if 1 <= rem <= 22:
                    pad_ok = True
                    break
                pad_n += (1 - rem) % 4096
                if pad_n < 1:
                    pad_n += 4096
            if not pad_ok:
                print("could not hit a page-boundary image size")
                return 1
            pad_lk = d / "paged_linked"
            err = build_link(pad_src, pad_ccr, pad_lk, shim)
            if err:
                print("paged linked build failed:\n" + err)
                return 1
            un_entry, un_loads = elf_layout(pad_un)
            lk_entry, lk_loads = elf_layout(pad_lk)
            if un_entry != lk_entry or un_loads != lk_loads:
                print("linked layout differs: "
                      f"entry {hex(un_entry)}/{hex(lk_entry)} "
                      f"loads {[hex(x) for x in un_loads]}/"
                      f"{[hex(x) for x in lk_loads]}")
                return 1
            r = run([str(pad_lk)])
            if r.returncode != 0:
                print(f"paged linked run failed: {r.returncode}")
                return 1
            print(f"PASS paged linked layout at size%4096={pad_un.stat().st_size % 4096}")

            # The linked .so .text must fit between the user code and the BSS
            # page. Larger shims are rejected loudly; they must not silently
            # overwrite the writable heap.
            big_c = d / "big_shim.c"
            big_so = d / "big_shim.so"
            big_c.write_text(
                'long big_inc(long x) { return x + 1; }\n'
                '__asm__(".rept 12000\\n nop\\n .endr");\n',
                encoding="utf-8")
            r = run(["gcc", "-shared", "-fPIC", "-O2", str(big_c),
                     "-o", str(big_so)])
            if r.returncode != 0:
                print("big shim build failed:\n" + r.stdout + r.stderr)
                return 1
            big_ccr = d / "big_extern.ccr"
            big_exe = d / "big_extern"
            r = run([str(COREC), "ccr", str(d / "extern.cr"),
                     "-o", str(big_ccr)])
            if r.returncode != 0:
                print("big shim ccr failed:\n" + r.stdout + r.stderr)
                return 1
            r = run([str(COREARCH), str(big_ccr), "--big-int", "--elf",
                     "--link", str(big_so), "--static", "-o", str(big_exe)])
            text = r.stdout + r.stderr
            if r.returncode == 0:
                print("large .so was accepted; expected a loud rejection")
                return 1
            if "超过用户代码与 BSS 之间的间隙" not in text:
                print("large .so rejection has no layout diagnostic:\n" + text)
                return 1
            if big_exe.exists():
                print("large .so rejection left an output file")
                return 1

    print("PASS bigint boundaries")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
