#!/usr/bin/env python3
"""Allocator: clang reference parity and structural checks.

The Core blob is compiled by the Python bootstrap (raw semantics).  A clang
reference implements the same simple-bump contract.  The test also checks the
generated assembly frame balance, the absence of a recursive alloc call, and
the ELF trampoline shape.
"""

from __future__ import annotations

import json
import re
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
GEN = BASE / "tools" / "gen_alloc_blob.py"
BODY = BASE / "src" / "runtime" / "alloc_body.cr"
STATE = BASE / "tests" / "harness" / "alloc_state.c"
ASM_CHECK = BASE / "tools" / "asm_check.py"
COREC = BASE / "build" / "corec"
COREARCH = BASE / "build" / "corearch"


def run(cmd: list[str], timeout: int = 300) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=BASE, capture_output=True, text=True,
                          timeout=timeout)


def make_sequences() -> list[list[int]]:
    rows: list[list[int]] = []
    state = 0x12345678
    for _ in range(200):
        row = []
        for _ in range(12):
            state = (state * 1664525 + 1013904223) & 0xFFFFFFFF
            row.append(state % 300000)
        rows.append(row)
    rows.append([0, 1, 7, 8, 15, 16, 3361, 3362, 4088, 4089, 4096, 0])
    rows.append([1048568, 1048576, 1048584, 67108856, 67108864, 67108865,
                 1099511627776, 1099511627777, -1, 0, 0, 0])
    rows.append([33554432, 16777216, 8388608, 4194304, 2097152, 1048576,
                 524288, 262144, 131072, 65536, 32768, 16384])
    return rows


def c_source(rows: list[list[int]]) -> str:
    seq = ",\n".join(
        "    {" + ", ".join(str(v) + "L" for v in row) + "}" for row in rows)
    return f"""
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>

#define HEAP_SIZE (1UL << 30)
#define MAX_REQUEST 67108864L

extern char *alloc_simple(long size, char *heap_start);
extern char *_g_g_heap_ptr;
extern char *_g_g_heap_end;
extern long heap_expand(void);

static char *ref_alloc(long size, char *heap_start) {{
    if (size < 0 || size > MAX_REQUEST)
        return NULL;
    long aligned = (size + 15) / 8 * 8;
    long need = aligned;
    if (aligned >= 4096)
        need = ((aligned + 4095) / 4096) * 4096;
    char *hp = _g_g_heap_ptr;
    if (hp == NULL) {{
        hp = heap_start;
        _g_g_heap_ptr = hp;
        _g_g_heap_end = heap_start + 1073741824L;
    }}
    if (need >= 4096)
        hp = (char *)(((uintptr_t)hp + 4095) & ~(uintptr_t)4095);
    char *newp = hp + need;
    if (newp > _g_g_heap_end) {{
        if (heap_expand() != 0)
            return NULL;
        hp = _g_g_heap_ptr;
        if (need >= 4096)
            hp = (char *)(((uintptr_t)hp + 4095) & ~(uintptr_t)4095);
        newp = hp + need;
        if (newp > _g_g_heap_end)
            return NULL;
    }}
    _g_g_heap_ptr = newp;
    memset(hp, 0, (size_t)need);
    *(long *)hp = size;
    return hp + 8;
}}

static const long seq[][12] = {{
{seq}
}};

static int check_one(long size, char *heap_start) {{
    _g_g_heap_ptr = NULL;
    _g_g_heap_end = NULL;
    char *a = alloc_simple(size, heap_start);
    long a_off = a ? (long)(a - heap_start) : -1;
    long a_hdr = a ? *(long *)(a - 8) : -1;
    unsigned char a_first = (a && size > 0) ? (unsigned char)a[0] : 0;
    unsigned char a_last = (a && size > 0) ? (unsigned char)a[size - 1] : 0;

    _g_g_heap_ptr = NULL;
    _g_g_heap_end = NULL;
    char *b = ref_alloc(size, heap_start);
    long b_off = b ? (long)(b - heap_start) : -1;
    long b_hdr = b ? *(long *)(b - 8) : -1;
    unsigned char b_first = (b && size > 0) ? (unsigned char)b[0] : 0;
    unsigned char b_last = (b && size > 0) ? (unsigned char)b[size - 1] : 0;

    if (a_off != b_off || a_hdr != b_hdr ||
        a_first != b_first || a_last != b_last) {{
        fprintf(stderr,
                "size %ld mismatch: core off=%ld hdr=%ld first=%u last=%u; "
                "ref off=%ld hdr=%ld first=%u last=%u\\n",
                size, a_off, a_hdr, a_first, a_last,
                b_off, b_hdr, b_first, b_last);
        return 1;
    }}
    if (a != NULL && size > 0) {{
        a[0] = (char)0x5a;
        if ((unsigned char)a[0] != 0x5a)
            return 1;
        if (size > 1) {{
            a[size - 1] = (char)0xa5;
            if ((unsigned char)a[size - 1] != 0xa5)
                return 1;
        }}
    }}
    return 0;
}}

int main(void) {{
    char *heap_start = mmap(NULL, HEAP_SIZE, PROT_READ | PROT_WRITE,
                            MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE,
                            -1, 0);
    if (heap_start == MAP_FAILED) {{
        perror("mmap");
        return 1;
    }}
    size_t rows = sizeof(seq) / sizeof(seq[0]);
    for (size_t r = 0; r < rows; r++) {{
        for (size_t c = 0; c < 12; c++) {{
            if (check_one(seq[r][c], heap_start) != 0) {{
                fprintf(stderr, "row %zu col %zu\\n", r, c);
                return 1;
            }}
        }}
    }}
    printf("allocator LLVM parity: %zu rows\\n", rows);
    return 0;
}}
"""


def check_trampoline(elf_path: Path) -> bool:
    data = elf_path.read_bytes()
    for i in range(len(data) - 15):
        if data[i] == 0x48 and data[i + 1] == 0xBE and data[i + 10] == 0xE9:
            heap = struct.unpack_from("<Q", data, i + 2)[0]
            if not (0x400000 <= heap <= 0x44000000):
                continue
            rel = struct.unpack_from("<i", data, i + 11)[0]
            target = i + 0x400000 + 11 + 4 + rel
            if 0x400000 <= target < heap:
                return True
    return False


def main() -> int:
    if shutil.which("clang") is None:
        print("SKIP allocator LLVM parity: clang not installed")
        return 0
    for path in (GEN, BODY, STATE, ASM_CHECK):
        if not path.exists():
            print(f"FAIL: missing {path}")
            return 1

    with tempfile.TemporaryDirectory(prefix="alloc_llvm_") as td:
        root = Path(td)
        blob = root / "alloc_blob.cr"
        summary = root / "summary.json"
        r = run([sys.executable, str(GEN), "--source", str(BODY),
                 "--out", str(blob), "--summary-json", str(summary)])
        if r.returncode != 0:
            print("FAIL: generator")
            print(r.stdout)
            print(r.stderr)
            return 1
        data = json.loads(summary.read_text(encoding="utf-8"))
        if data.get("simple_off", -1) < 0 or data.get("arena_off", -1) < 0:
            print(f"FAIL: missing allocator body: {data}")
            return 1

        asm = BASE / "build" / "alloc_blob" / "alloc_body.s"
        text = asm.read_text(encoding="utf-8")
        if re.search(r"\bcall\s+alloc\b", text):
            print("FAIL: allocator body calls alloc")
            return 1
        r = run([sys.executable, str(ASM_CHECK), str(asm)])
        if r.returncode != 0:
            print("FAIL: asm_check")
            print(r.stdout)
            return 1

        c_path = root / "alloc_llvm.c"
        c_path.write_text(c_source(make_sequences()), encoding="utf-8")
        obj = BASE / "build" / "alloc_blob" / "alloc_body.o"
        harness = root / "alloc_llvm_harness"
        cc = run(["clang", "-O2", "-no-pie", "-o", str(harness),
                  str(STATE), str(c_path), str(obj)])
        if cc.returncode != 0:
            print("FAIL: clang link")
            print(cc.stdout)
            print(cc.stderr)
            return 1
        hr = run([str(harness)], timeout=300)
        sys.stdout.write(hr.stdout)
        sys.stderr.write(hr.stderr)
        if hr.returncode != 0:
            print(f"FAIL: harness rc={hr.returncode}")
            return 1

        src = root / "tramp.cr"
        ccr = root / "tramp.ccr"
        elf = root / "tramp"
        src.write_text("fn main() -> int:\n    p := alloc(16)\n    return 0\n",
                       encoding="utf-8")
        r = run([str(COREC), "ccr", "--alloc-blob", str(src), "-o", str(ccr)])
        if r.returncode != 0:
            print("FAIL: corec ccr for trampoline")
            print(r.stdout)
            print(r.stderr)
            return 1
        r = run([str(COREARCH), str(ccr), "--static", "--alloc-blob",
                 "-o", str(elf)])
        if r.returncode != 0:
            print("FAIL: corearch for trampoline")
            print(r.stdout)
            print(r.stderr)
            return 1
        if not check_trampoline(elf):
            print("FAIL: allocator trampoline shape")
            return 1

    print("PASS allocator LLVM parity")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
