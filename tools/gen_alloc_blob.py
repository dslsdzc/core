#!/usr/bin/env python3
"""Generate the raw allocator blob from a restricted Core source.

The allocator body is compiled with the Python bootstrap in raw-int mode.
Internal PC-relative relocations are resolved here.  References to the
allocator's BSS globals and calls to heap_expand/arena_grow_pool are emitted
as relocation tables; corearch fills them in after the final BSS layout is
known.
"""

from __future__ import annotations

import argparse
import json
import struct
import subprocess
import sys
from pathlib import Path

BASE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BASE / "bootstrap"))

from corec.backend.x86_64_stack_asm import X86_64StackAsmGen
from corec.frontend.desugar import MatchDesugarer
from corec.frontend.ir_gen import IRGen
from corec.frontend.lexer import Lexer
from corec.frontend.name_resolver import NameResolver
from corec.frontend.parser import Parser
from corec.frontend.type_checker import TypeChecker
from corec.ir.symbol_table import SymbolKind
from corec.syntax.ast import BaseType, LetDecl

# Globals the body may read or write.  The blob does not carry .bss; every
# symbol in this list is patched to the target program's BSS slot.
EXTERNAL_GLOBALS = {
    "g_heap_ptr",
    "g_heap_end",
    "g_arena_scalars",
    "g_arena_scalars_ready",
    "g_arena_suspend",
    "g_arena_slot",
    "g_arena_slot_cursor",
    "g_arena_slot_next",
    "g_arena_static",
    "g_arena_sizes",
    "g_arena_cursors",
    "g_segment_base",
    "g_class_base",
    "g_class_cursor",
    "g_class_limit",
    "g_class_lookup",
    "g_class_sizes",
    "g_arena_large_head",
    "g_arena_large_count",
    "g_alloc_fail_request",
    "g_alloc_fail_class",
    "g_alloc_fail_cursor",
    "g_alloc_fail_limit",
    "g_alloc_home_idx",
}

EXTERNAL_CALLS = {
    "heap_expand",
    "arena_grow_pool",
}

CELL_HELPERS = """
fn cell_load(buf: string, pos: int) -> int:
    return load64(buf, pos)

fn cell_store(buf: string, pos: int, val: int):
    cur : ., mut = val
    i : ., mut = 0
    loop:
        if i >= 8:
            break
        byte : ., mut = cur % 256
        if byte < 0:
            byte = byte + 256
        store8(buf, pos + i, byte)
        cur = (cur - byte) / 256
        i = i + 1
"""


def compile_source(source: Path) -> bytes:
    src = CELL_HELPERS + source.read_text(encoding="utf-8")
    ast = Parser(Lexer(src).tokenize()).parse_compilation_unit()
    for decl in ast.declarations:
        if isinstance(decl, LetDecl) and not decl.values:
            for name in decl.names:
                if name not in EXTERNAL_GLOBALS:
                    raise SystemExit(
                        f"external global {name!r} is not in the allocator allowlist")
    resolver = NameResolver()
    original_declare = resolver._declare_builtins

    def declare_with_externals():
        original_declare()
        for name in sorted(EXTERNAL_CALLS):
            resolver.symtab.define(name, SymbolKind.FUNCTION, BaseType("int"))

    resolver._declare_builtins = declare_with_externals
    resolver.resolve(ast)
    ast = MatchDesugarer(resolver.symtab).desugar(ast)
    checker = TypeChecker(resolver.symtab)
    checker.check(ast)
    if resolver.errors or checker.errors:
        raise SystemExit(f"allocator type errors: {resolver.errors + checker.errors}")
    module = IRGen(resolver.symtab, bigint_mode=False).gen_module(ast)
    asm = X86_64StackAsmGen(module, runtime_only=True).generate()

    tmp = BASE / "build" / "alloc_blob"
    tmp.mkdir(exist_ok=True)
    asm_path = tmp / "alloc_body.s"
    obj_path = tmp / "alloc_body.o"
    asm_path.write_text(asm + "\n", encoding="utf-8")
    r = subprocess.run(["as", "-o", str(obj_path), str(asm_path)],
                       capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit(r.stderr)
    return obj_path.read_bytes()


class Elf:
    def __init__(self, data: bytes):
        self.data = data
        if data[:4] != b"\x7fELF" or data[4] != 2:
            raise SystemExit("not an ELF64 object")
        self.e_shoff = struct.unpack_from("<Q", data, 40)[0]
        self.e_shentsize = struct.unpack_from("<H", data, 58)[0]
        self.e_shnum = struct.unpack_from("<H", data, 60)[0]
        self.e_shstrndx = struct.unpack_from("<H", data, 62)[0]
        self.sections = []
        for i in range(self.e_shnum):
            off = self.e_shoff + i * self.e_shentsize
            sh = struct.unpack_from("<IIQQQQIIQQ", data, off)
            self.sections.append({
                "name_off": sh[0], "type": sh[1], "flags": sh[2],
                "addr": sh[3], "offset": sh[4], "size": sh[5],
                "link": sh[6], "info": sh[7], "align": sh[8], "entsize": sh[9],
            })
        shstr = self.sections[self.e_shstrndx]
        strtab = data[shstr["offset"]:shstr["offset"] + shstr["size"]]
        for s in self.sections:
            end = strtab.find(b"\0", s["name_off"])
            s["name"] = strtab[s["name_off"]:end].decode("ascii")
        self.by_name = {s["name"]: i for i, s in enumerate(self.sections)}

    def section(self, name: str) -> dict:
        return self.sections[self.by_name[name]]

    def section_data(self, name: str) -> bytes:
        s = self.section(name)
        return self.data[s["offset"]:s["offset"] + s["size"]]

    def symbols(self):
        symtab = self.section(".symtab")
        strtab = self.sections[symtab["link"]]
        strings = self.data[strtab["offset"]:strtab["offset"] + strtab["size"]]
        out = []
        for off in range(symtab["offset"], symtab["offset"] + symtab["size"], 24):
            name_off, info, other, shndx, value, size = struct.unpack_from(
                "<IBBHQQ", self.data, off)
            end = strings.find(b"\0", name_off)
            name = strings[name_off:end].decode("ascii")
            out.append({"name": name, "info": info, "shndx": shndx,
                        "value": value, "size": size})
        return out

    def rela(self, name: str):
        sec = self.section(name)
        out = []
        for off in range(sec["offset"], sec["offset"] + sec["size"], 24):
            r_offset, r_info, r_addend = struct.unpack_from("<QQq", self.data, off)
            out.append((r_offset, r_info >> 32, r_info & 0xFFFFFFFF, r_addend))
        return out


def align_up(n: int, a: int) -> int:
    return (n + a - 1) // a * a


def normalize_global(name: str) -> str:
    if name.startswith("_g_"):
        return name[3:]
    return name


def build_blob(obj_data: bytes):
    elf = Elf(obj_data)
    text = elf.section_data(".text")
    rodata = elf.section_data(".rodata")
    data = elf.section_data(".data")

    ro_base = align_up(len(text), 16)
    data_base = align_up(ro_base + len(rodata), 8)
    total = align_up(data_base + len(data), 16)
    blob = bytearray(total)
    blob[0:len(text)] = text
    blob[ro_base:ro_base + len(rodata)] = rodata
    blob[data_base:data_base + len(data)] = data

    syms = elf.symbols()
    sec_base = {
        elf.by_name[".text"]: 0,
        elf.by_name[".rodata"]: ro_base,
        elf.by_name[".data"]: data_base,
    }
    bss_index = elf.by_name.get(".bss")
    calls = []
    globals_ = []

    for r_offset, sym_idx, r_type, addend in elf.rela(".rela.text"):
        sym = syms[sym_idx]
        if sym["shndx"] == 0:
            name = sym["name"]
            if name not in EXTERNAL_CALLS:
                raise SystemExit(
                    f"external call {name!r} is not in the allocator allowlist")
            if r_type not in (2, 4):
                raise SystemExit(f"unexpected call relocation type {r_type}")
            calls.append({"name": name, "off": r_offset})
            struct.pack_into("<i", blob, r_offset, 0)
            continue
        gname = normalize_global(sym["name"])
        if gname in EXTERNAL_GLOBALS:
            # The bootstrap may place a zero-initialized global in .data.
            # Its blob copy is dead; the relocation is patched to the target
            # program's BSS slot.
            if r_type not in (2, 4):
                raise SystemExit(f"unexpected global relocation type {r_type}")
            globals_.append({"name": gname, "off": r_offset})
            struct.pack_into("<i", blob, r_offset, 0)
            continue
        if bss_index is not None and sym["shndx"] == bss_index:
            raise SystemExit(
                f"external global {gname!r} is not in the allocator allowlist")
        if sym["shndx"] not in sec_base:
            raise SystemExit(
                f"unresolved allocator symbol {sym['name']!r} shndx={sym['shndx']}")
        s = sec_base[sym["shndx"]] + sym["value"]
        if r_type in (2, 4):
            value = s + addend - r_offset
            if value < -(1 << 31) or value >= (1 << 31):
                raise SystemExit(f"relocation overflow at {r_offset:#x}: {value}")
            struct.pack_into("<i", blob, r_offset, value)
        elif r_type in (1, 10, 11):
            raise SystemExit(
                f"absolute relocation type {r_type} at {r_offset:#x} is unsupported")
        else:
            raise SystemExit(f"unknown relocation type {r_type} at {r_offset:#x}")

    funcs = {}
    for sym in syms:
        if sym["shndx"] == elf.by_name[".text"] and sym["name"]:
            funcs[sym["name"]] = sym["value"]

    return bytes(blob), funcs, calls, globals_


def emit_core(blob: bytes, funcs: dict[str, int],
              calls: list[dict], globals_: list[dict], source: Path) -> str:
    simple_off = funcs.get("alloc_simple", -1)
    arena_off = funcs.get("alloc_arena", -1)
    lines = []
    lines.append("// === alloc_blob.cr ===")
    lines.append(f"// Generated by tools/gen_alloc_blob.py from {source}.")
    lines.append("// Do not edit by hand.")
    lines.append("")
    lines.append(f"ALLOC_BLOB_SIZE : int = {len(blob)}")
    lines.append(f"ALLOC_BLOB_SIMPLE_OFF : int = {simple_off}")
    lines.append(f"ALLOC_BLOB_ARENA_OFF : int = {arena_off}")
    lines.append("")
    lines.append("fn alloc_blob_hex() -> string:")
    hx = blob.hex()
    chunk = 256
    first = True
    for i in range(0, len(hx), chunk):
        part = hx[i:i + chunk]
        if first:
            lines.append(f'    h : ., mut = "{part}"')
            first = False
        else:
            lines.append(f'    h = h + "{part}"')
    if first:
        lines.append('    h : ., mut = ""')
    lines.append("    return h")
    lines.append("")
    lines.append("fn alloc_blob_byte_from_hex(c: int) -> int:")
    lines.append("    if c >= 48 && c <= 57:")
    lines.append("        return c - 48")
    lines.append("    if c >= 97 && c <= 102:")
    lines.append("        return c - 87")
    lines.append("    return c - 55")
    lines.append("")
    lines.append("fn alloc_blob_bytes() -> string:")
    lines.append("    h := alloc_blob_hex()")
    lines.append("    hl := str_len(h)")
    lines.append("    n := hl / 2")
    lines.append("    out := alloc(n + 1)")
    lines.append("    i : ., mut = 0")
    lines.append("    loop:")
    lines.append("        if i >= n:")
    lines.append("            break")
    lines.append("        hi := alloc_blob_byte_from_hex(load8(h, i * 2))")
    lines.append("        lo := alloc_blob_byte_from_hex(load8(h, i * 2 + 1))")
    lines.append("        store8(out, i, hi * 16 + lo)")
    lines.append("        i = i + 1")
    lines.append("    store8(out, n, 0)")
    lines.append("    return out")
    lines.append("")
    lines.append("fn alloc_blob_call_count() -> int:")
    lines.append(f"    return {len(calls)}")
    lines.append("")
    lines.append("fn alloc_blob_call_name(i: int) -> string:")
    for i, call in enumerate(calls):
        lines.append(f"    if i == {i}:")
        lines.append(f'        return "{call["name"]}"')
    lines.append('    return ""')
    lines.append("")
    lines.append("fn alloc_blob_call_off(i: int) -> int:")
    for i, call in enumerate(calls):
        lines.append(f"    if i == {i}:")
        lines.append(f"        return {call['off']}")
    lines.append("    return -1")
    lines.append("")
    lines.append("fn alloc_blob_global_count() -> int:")
    lines.append(f"    return {len(globals_)}")
    lines.append("")
    lines.append("fn alloc_blob_global_name(i: int) -> string:")
    for i, gl in enumerate(globals_):
        lines.append(f"    if i == {i}:")
        lines.append(f'        return "{gl["name"]}"')
    lines.append('    return ""')
    lines.append("")
    lines.append("fn alloc_blob_global_off(i: int) -> int:")
    for i, gl in enumerate(globals_):
        lines.append(f"    if i == {i}:")
        lines.append(f"        return {gl['off']}")
    lines.append("    return -1")
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--source", default=str(BASE / "src" / "runtime" / "alloc_body.cr"))
    ap.add_argument("--out", default=str(BASE / "src" / "runtime" / "alloc_blob.cr"))
    ap.add_argument("--summary-json", default="")
    args = ap.parse_args()

    source = Path(args.source)
    if not source.exists():
        raise SystemExit(f"source does not exist: {source}")
    obj = compile_source(source)
    blob, funcs, calls, globals_ = build_blob(obj)
    out = Path(args.out)
    try:
        source_label = source.resolve().relative_to(BASE)
    except ValueError:
        source_label = source
    out.write_text(
        emit_core(blob, funcs, calls, globals_, source_label), encoding="utf-8")
    summary = {
        "blob_size": len(blob),
        "simple_off": funcs.get("alloc_simple", -1),
        "arena_off": funcs.get("alloc_arena", -1),
        "globals": [g["name"] for g in globals_],
        "calls": [c["name"] for c in calls],
    }
    if args.summary_json:
        Path(args.summary_json).write_text(
            json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {out} ({len(blob)} bytes, "
          f"{len(globals_)} globals, {len(calls)} calls)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
