#!/usr/bin/env python3
"""Generate the raw allocator blob from a restricted Core source.

The allocator body is compiled with the Python bootstrap in raw-int mode.
Internal PC-relative relocations are resolved here. References to the
allocator's BSS globals and calls to heap_expand/arena_grow_pool are emitted
as relocation tables; corearch fills them in after the final BSS layout is
known.

Relocations are grouped by the entry body that can reach them. A program
without arena imports patches only the simple group, so the arena-only globals
do not have to exist. A relocation that is unreachable from either entry is a
generator error.
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

# Globals the body may read or write. The blob does not carry .bss; every
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
    "g_alloc_fail_request",
    "g_alloc_fail_class",
    "g_alloc_fail_cursor",
    "g_alloc_fail_limit",
}

EXTERNAL_CALLS = {
    "heap_expand",
    "arena_grow_pool",
}

GROUP_SIMPLE = 0
GROUP_ARENA = 1

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
        if isinstance(decl, LetDecl):
            for name in decl.names:
                if name not in EXTERNAL_GLOBALS:
                    raise SystemExit(
                        f"external global {name!r} is not in the allocator allowlist")
            if decl.values:
                raise SystemExit(
                    "allocator globals must be zero-initialized; "
                    f"{decl.names[0]!r} has an initializer")
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

    def has_section(self, name: str) -> bool:
        return name in self.by_name

    def section(self, name: str) -> dict:
        return self.sections[self.by_name[name]]

    def section_data(self, name: str) -> bytes:
        if name not in self.by_name:
            return b""
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
        if name not in self.by_name:
            return []
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


def function_symbols(elf: Elf, syms: list[dict]) -> list[tuple[int, str]]:
    text_idx = elf.by_name[".text"]
    out = []
    for sym in syms:
        if sym["shndx"] != text_idx or not sym["name"]:
            continue
        if sym["name"].startswith("_g_"):
            continue
        if (sym["info"] >> 4) != 1:  # STB_GLOBAL
            continue
        out.append((sym["value"], sym["name"]))
    out.sort()
    return out


def enclosing_function(funcs: list[tuple[int, str]], off: int) -> str:
    found = ""
    for value, name in funcs:
        if value <= off:
            found = name
        else:
            break
    return found


def reachable_functions(edges: dict[str, set[str]], start: str) -> set[str]:
    seen: set[str] = set()
    stack = [start]
    while stack:
        name = stack.pop()
        if name in seen:
            continue
        seen.add(name)
        stack.extend(edges.get(name, ()))
    return seen


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
    text_idx = elf.by_name[".text"]
    funcs = function_symbols(elf, syms)
    func_offsets = {name: value for value, name in funcs}

    # The bootstrap places zero-initialized globals in .data. Every symbol in
    # that section must be an allowlisted external global whose real storage
    # is the target program's BSS. Any local .data object would be copied into
    # the read-only code segment and patched by ignored .rela.data entries.
    for sym in syms:
        if sym["shndx"] == elf.by_name.get(".data") and sym["name"]:
            gname = normalize_global(sym["name"])
            if gname not in EXTERNAL_GLOBALS:
                raise SystemExit(
                    f"local .data symbol {sym['name']!r} is not allowed "
                    "in the allocator blob")
    if elf.has_section(".rela.data") and elf.section(".rela.data")["size"] > 0:
        raise SystemExit(".rela.data is not supported in the allocator blob")
    if elf.has_section(".rela.rodata") and elf.section(".rela.rodata")["size"] > 0:
        raise SystemExit(".rela.rodata is not supported in the allocator blob")

    # Zero the dead .data copy of the external globals.
    if data:
        blob[data_base:data_base + len(data)] = bytes(len(data))

    relocs = elf.rela(".rela.text")

    # Call graph over internal .text symbols, used to decide which entry body
    # reaches each relocation.
    edges: dict[str, set[str]] = {}
    for r_offset, sym_idx, _r_type, _addend in relocs:
        sym = syms[sym_idx]
        if sym["shndx"] != text_idx:
            continue
        callee = sym["name"]
        if callee not in func_offsets:
            continue
        caller = enclosing_function(funcs, r_offset)
        if not caller:
            raise SystemExit(f"relocation at {r_offset:#x} has no enclosing function")
        edges.setdefault(caller, set()).add(callee)

    simple_reach = reachable_functions(edges, "alloc_simple")
    arena_reach = reachable_functions(edges, "alloc_arena")
    if "alloc_simple" not in func_offsets:
        raise SystemExit("alloc_simple is missing from the allocator blob")
    if "alloc_arena" not in func_offsets:
        raise SystemExit("alloc_arena is missing from the allocator blob")

    sec_base = {
        text_idx: 0,
        elf.by_name[".rodata"]: ro_base,
        elf.by_name[".data"]: data_base,
    }
    bss_index = elf.by_name.get(".bss")
    groups = {
        GROUP_SIMPLE: {"globals": [], "calls": []},
        GROUP_ARENA: {"globals": [], "calls": []},
    }

    def add_grouped(kind: str, name: str, off: int):
        caller = enclosing_function(funcs, off)
        if not caller:
            raise SystemExit(f"relocation at {off:#x} has no enclosing function")
        hit = False
        if caller in simple_reach:
            groups[GROUP_SIMPLE][kind].append({"name": name, "off": off})
            hit = True
        if caller in arena_reach:
            groups[GROUP_ARENA][kind].append({"name": name, "off": off})
            hit = True
        if not hit:
            raise SystemExit(
                f"relocation {name!r} at {off:#x} in {caller} is unreachable "
                "from alloc_simple and alloc_arena")

    for r_offset, sym_idx, r_type, addend in relocs:
        sym = syms[sym_idx]
        if sym["shndx"] == 0:
            name = sym["name"]
            if name not in EXTERNAL_CALLS:
                raise SystemExit(
                    f"external call {name!r} is not in the allocator allowlist")
            if r_type not in (2, 4):
                raise SystemExit(f"unexpected call relocation type {r_type}")
            add_grouped("calls", name, r_offset)
            struct.pack_into("<i", blob, r_offset, 0)
            continue
        gname = normalize_global(sym["name"])
        if gname in EXTERNAL_GLOBALS:
            if r_type not in (2, 4):
                raise SystemExit(f"unexpected global relocation type {r_type}")
            add_grouped("globals", gname, r_offset)
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

    return bytes(blob), func_offsets, groups


def emit_reloc_table(lines: list[str], kind: str, groups: dict) -> None:
    key = kind + "s"
    lines.append(f"fn alloc_blob_{kind}_count(group: int) -> int:")
    for g in (GROUP_SIMPLE, GROUP_ARENA):
        lines.append(f"    if group == {g}:")
        lines.append(f"        return {len(groups[g][key])}")
    lines.append("    return 0")
    lines.append("")
    lines.append(f"fn alloc_blob_{kind}_name(group: int, i: int) -> string:")
    for g in (GROUP_SIMPLE, GROUP_ARENA):
        lines.append(f"    if group == {g}:")
        for i, entry in enumerate(groups[g][key]):
            lines.append(f"        if i == {i}:")
            lines.append(f'            return "{entry["name"]}"')
    lines.append('    return ""')
    lines.append("")
    lines.append(f"fn alloc_blob_{kind}_off(group: int, i: int) -> int:")
    for g in (GROUP_SIMPLE, GROUP_ARENA):
        lines.append(f"    if group == {g}:")
        for i, entry in enumerate(groups[g][key]):
            lines.append(f"        if i == {i}:")
            lines.append(f"            return {entry['off']}")
    lines.append("    return -1")
    lines.append("")


def emit_core(blob: bytes, funcs: dict[str, int], groups: dict,
              source: Path) -> str:
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
    emit_reloc_table(lines, "call", groups)
    emit_reloc_table(lines, "global", groups)
    return "\n".join(lines)


def generate(source: Path) -> tuple[str, dict]:
    obj = compile_source(source)
    blob, funcs, groups = build_blob(obj)
    try:
        source_label = source.resolve().relative_to(BASE)
    except ValueError:
        source_label = source
    text = emit_core(blob, funcs, groups, source_label)
    summary = {
        "blob_size": len(blob),
        "simple_off": funcs.get("alloc_simple", -1),
        "arena_off": funcs.get("alloc_arena", -1),
        "simple_globals": [g["name"] for g in groups[GROUP_SIMPLE]["globals"]],
        "arena_globals": [g["name"] for g in groups[GROUP_ARENA]["globals"]],
        "simple_calls": [c["name"] for c in groups[GROUP_SIMPLE]["calls"]],
        "arena_calls": [c["name"] for c in groups[GROUP_ARENA]["calls"]],
    }
    return text, summary


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--source", default=str(BASE / "src" / "runtime" / "alloc_body.cr"))
    ap.add_argument("--out", default=str(BASE / "src" / "runtime" / "alloc_blob.cr"))
    ap.add_argument("--summary-json", default="")
    ap.add_argument("--check", action="store_true",
                    help="fail if --out does not match the generated blob")
    args = ap.parse_args()

    source = Path(args.source)
    if not source.exists():
        raise SystemExit(f"source does not exist: {source}")
    text, summary = generate(source)
    out = Path(args.out)
    if args.check:
        if not out.exists():
            print(f"FAIL: {out} does not exist")
            return 1
        if out.read_text(encoding="utf-8") != text:
            print(f"FAIL: {out} is stale; run tools/gen_alloc_blob.py")
            return 1
        print(f"up to date: {out} ({summary['blob_size']} bytes)")
    else:
        out.write_text(text, encoding="utf-8")
        print(f"wrote {out} ({summary['blob_size']} bytes, "
              f"{len(summary['simple_globals'])} simple globals, "
              f"{len(summary['arena_globals'])} arena globals, "
              f"{len(summary['simple_calls'])} simple calls, "
              f"{len(summary['arena_calls'])} arena calls)")
    if args.summary_json:
        Path(args.summary_json).write_text(
            json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
