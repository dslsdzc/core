#!/usr/bin/env python3
"""Generate src/runtime/bigint_blob.cr from src/runtime/bigint.cr.

The BigInt runtime is pure Core.  For the self-hosted backend we need its raw
machine code as a relocatable-free blob: the backend compiles user programs with
tagged integers, but the runtime itself must use raw limbs (otherwise limb
arithmetic would recurse into BigInt operations).

The blob is position independent after this script resolves every relocation
that is relative to another symbol in the blob.  The only external symbol is
`alloc`; corearch patches its four call sites to the allocator it emits into the
same ELF.  The blob is placed in the code segment, which --big-int marks RWX so
the few runtime globals (g_bi_error/g_bi_rem) are writable.
"""

from __future__ import annotations

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


def compile_runtime() -> bytes:
    src = (BASE / "src" / "runtime" / "bigint.cr").read_text(encoding="utf-8")
    ast = Parser(Lexer(src).tokenize()).parse_compilation_unit()
    resolver = NameResolver()
    resolver.resolve(ast)
    ast = MatchDesugarer(resolver.symtab).desugar(ast)
    checker = TypeChecker(resolver.symtab)
    checker.check(ast)
    if resolver.errors or checker.errors:
        raise SystemExit(f"bigint type errors: {resolver.errors + checker.errors}")
    module = IRGen(resolver.symtab, bigint_mode=False).gen_module(ast)
    asm = X86_64StackAsmGen(module, runtime_only=True).generate()
    tmp = BASE / "build" / "bigint_blob"
    tmp.mkdir(exist_ok=True)
    asm_path = tmp / "bigint.s"
    obj_path = tmp / "bigint.o"
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


def build_blob(obj_data: bytes):
    elf = Elf(obj_data)
    text = elf.section_data(".text")
    rodata = elf.section_data(".rodata")
    data = elf.section_data(".data")
    bss = elf.section(".bss")
    if bss["size"] != 0:
        raise SystemExit("unexpected bigint .bss")

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
        elf.by_name[".bss"]: data_base + len(data),
    }
    alloc_calls = []
    for r_offset, sym_idx, r_type, addend in elf.rela(".rela.text"):
        sym = syms[sym_idx]
        if sym["name"] == "alloc" and sym["shndx"] == 0:
            if r_type not in (2, 4):
                raise SystemExit(f"unexpected alloc relocation type {r_type}")
            alloc_calls.append(r_offset)
            # Placeholder; corearch writes the final rel32.
            struct.pack_into("<i", blob, r_offset, 0)
            continue
        if sym["shndx"] not in sec_base:
            raise SystemExit(f"unresolved bigint symbol {sym['name']!r} shndx={sym['shndx']}")
        s = sec_base[sym["shndx"]] + sym["value"]
        if r_type in (2, 4):  # PC32 / PLT32
            value = s + addend - r_offset
            if value < -(1 << 31) or value >= (1 << 31):
                raise SystemExit(f"relocation overflow at {r_offset:#x}: {value}")
            struct.pack_into("<i", blob, r_offset, value)
        elif r_type in (1, 10, 11):  # absolute; should not occur in this object
            raise SystemExit(f"absolute relocation type {r_type} at {r_offset:#x} is unsupported")
        else:
            raise SystemExit(f"unknown relocation type {r_type} at {r_offset:#x}")

    funcs = {}
    for sym in syms:
        if sym["shndx"] == elf.by_name[".text"] and sym["name"].startswith("bi_"):
            funcs[sym["name"]] = sym["value"]
    if "bi_add" not in funcs or "bi_from_dec" not in funcs:
        raise SystemExit("bigint blob missing required symbols")
    return bytes(blob), funcs, alloc_calls, data_base, len(data)


def hex_literal(data: bytes) -> str:
    return data.hex()


def emit_core(blob: bytes, funcs: dict[str, int], alloc_calls: list[int],
              data_base: int, data_len: int) -> str:
    funcs_sorted = sorted(funcs.items())
    lines = []
    lines.append("// === bigint_blob.cr ===")
    lines.append("// Generated by tools/gen_bigint_blob.py from src/runtime/bigint.cr.")
    lines.append("// Do not edit by hand.  The blob is raw-core BigInt machine code plus")
    lines.append("// its read-only and writable data; corearch copies it into the code segment.")
    lines.append("")
    lines.append(f"BIGINT_BLOB_SIZE : int = {len(blob)}")
    lines.append(f"BIGINT_BLOB_DATA_OFF : int = {data_base}")
    lines.append(f"BIGINT_BLOB_DATA_LEN : int = {data_len}")
    lines.append("")
    # Keep the literal on one line.  The Core lexer handles long string literals;
    # it must be returned from a function, not stored in a global: the Python
    # bootstrap emits global string initializers as raw quad words.
    lines.append("fn bigint_blob_hex() -> string:")
    lines.append("    return \"" + hex_literal(blob) + "\"")
    lines.append("")
    lines.append("fn bigint_blob_byte_from_hex(c: int) -> int:")
    lines.append("    if c >= 48 && c <= 57:")
    lines.append("        return c - 48")
    lines.append("    if c >= 97 && c <= 102:")
    lines.append("        return c - 87")
    lines.append("    return c - 55")
    lines.append("")
    lines.append("fn bigint_blob_bytes() -> string:")
    lines.append("    h := bigint_blob_hex()")
    lines.append("    hl := str_len(h)")
    lines.append("    n := hl / 2")
    lines.append("    out := alloc(n + 1)")
    lines.append("    i : ., mut = 0")
    lines.append("    loop:")
    lines.append("        if i >= n:")
    lines.append("            break")
    lines.append("        hi := bigint_blob_byte_from_hex(load8(h, i * 2))")
    lines.append("        lo := bigint_blob_byte_from_hex(load8(h, i * 2 + 1))")
    lines.append("        store8(out, i, hi * 16 + lo)")
    lines.append("        i = i + 1")
    lines.append("    store8(out, n, 0)")
    lines.append("    return out")
    lines.append("")
    lines.append("fn bigint_blob_symbol(name: string) -> int:")
    for name, off in funcs_sorted:
        lines.append(f"    if str_eq(name, \"{name}\") != 0:")
        lines.append(f"        return {off}")
    lines.append("    return -1")
    lines.append("")
    lines.append("fn bigint_blob_symbol_count() -> int:")
    lines.append(f"    return {len(funcs_sorted)}")
    lines.append("")
    lines.append("fn bigint_blob_symbol_name(i: int) -> string:")
    for i, (name, _) in enumerate(funcs_sorted):
        lines.append(f"    if i == {i}:")
        lines.append(f"        return \"{name}\"")
    lines.append("    return \"\"")
    lines.append("")
    lines.append("fn bigint_blob_alloc_count() -> int:")
    lines.append(f"    return {len(alloc_calls)}")
    lines.append("")
    lines.append("fn bigint_blob_alloc_off(i: int) -> int:")
    for i, off in enumerate(alloc_calls):
        lines.append(f"    if i == {i}:")
        lines.append(f"        return {off}")
    lines.append("    return -1")
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    obj = compile_runtime()
    blob, funcs, alloc_calls, data_base, data_len = build_blob(obj)
    out = BASE / "src" / "runtime" / "bigint_blob.cr"
    out.write_text(emit_core(blob, funcs, alloc_calls, data_base, data_len),
                   encoding="utf-8")
    print(f"wrote {out} ({len(blob)} bytes, {len(funcs)} symbols, "
          f"{len(alloc_calls)} alloc calls)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
