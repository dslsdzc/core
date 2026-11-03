#!/usr/bin/env python3
"""CP-6: MessageRef layout table, descriptor channels, and transfers."""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"
COREARCH = BASE / "build" / "corearch"

TRANSFER = """\
import conc

fn main() -> int:
    conc_layout_declare(7, 16, 4660)
    if conc_layout_ok(7) == 0:
        return 1
    if conc_layout_size(7) != 16:
        return 2
    if conc_layout_add_field(7, 0, 8) != 0:
        return 23
    if conc_layout_field_count(7) != 1:
        return 25
    if conc_layout_count() < 1:
        return 26
    r0 := conc_region_new(65536)
    r1 := conc_region_new(65536)
    r2 := conc_region_new(65536)
    ref := conc_ref_alloc(r0, 16, 7)
    if conc_ref_ok(ref) == 0:
        return 3
    if conc_ref_layout_check(ref) == 0:
        return 4
    p := conc_ref_payload(ref)
    cell_store(p, 0, 11)
    cell_store(p, 8, 22)
    cs := conc_ref_alloc(r0, 16, 7)
    csp := conc_ref_payload(cs)
    cell_store(csp, 0, 11)
    cell_store(csp, 8, 22)
    csd := conc_ref_copy_set(cs, r1)
    if conc_ref_ok(csd) == 0:
        return 27
    if cell_load(conc_ref_payload(csd), 0) != 11:
        return 28
    if cell_load(conc_ref_payload(csd), 8) != 0:
        return 29
    if conc_ref_ok(cs) == 0:
        return 30
    ms := conc_ref_move_set(cs, r1)
    if conc_ref_ok(ms) == 0:
        return 31
    if conc_ref_ok(cs) != 0:
        return 32
    c := conc_ref_copy(ref, r1)
    if conc_ref_ok(c) == 0:
        return 5
    if cell_load(conc_ref_payload(c), 0) != 11:
        return 6
    if conc_ref_ok(ref) == 0:
        return 7
    m := conc_ref_move(ref, r1)
    if conc_ref_ok(ref) != 0:
        return 8
    if conc_ref_ok(m) == 0:
        return 9
    if cell_load(conc_ref_payload(m), 8) != 22:
        return 10
    ref2 := conc_ref_alloc(r0, 8, 3)
    q := conc_ref_payload(ref2)
    cell_store(q, 0, 1)
    loan := conc_ref_loan(ref2, r2)
    if conc_ref_ok(ref2) != 0:
        return 11
    cell_store(conc_ref_payload(loan), 0, 99)
    if conc_ref_return(ref2, loan) != 0:
        return 12
    if conc_ref_ok(ref2) == 0:
        return 13
    if cell_load(conc_ref_payload(ref2), 0) != 99:
        return 14
    if conc_ref_return(ref2, loan) == 0:
        return 33
    forged := conc_ref_alloc(r0, 8, 3)
    loan2 := conc_ref_loan(ref2, r2)
    if conc_ref_return(ref2, forged) == 0:
        return 34
    if conc_ref_return(ref2, loan2) != 0:
        return 35
    if conc_loan_count() != 0:
        return 36
    if conc_transfer_failures() < 2:
        return 37
    ref3 := conc_ref_alloc(r0, 32, 4)
    sp0 := conc_ref_split_part(ref3, r2, 0, 2)
    sp1 := conc_ref_split_part(ref3, r2, 1, 2)
    if conc_ref_ok(sp0) == 0:
        return 15
    if conc_ref_ok(sp1) == 0:
        return 16
    if conc_ref_ok(ref3) != 0:
        return 17
    f := conc_ref_fill(r2, 8, 5)
    if conc_ref_ok(f) == 0:
        return 18
    ch := conc_channel_new_ref(r1, 2)
    if conc_channel_is_ref(ch) == 0:
        return 19
    rc := conc_ref_alloc(r0, 8, 3)
    rp := conc_ref_payload(rc)
    cell_store(rp, 0, 77)
    if conc_send_ref(ch, rc) != 0:
        return 20
    got := conc_recv_ref(ch)
    if conc_ref_ok(got) == 0:
        return 21
    if cell_load(conc_ref_payload(got), 0) != 77:
        return 22
    return 0
"""

SPACE_TRANSFER = """\
import conc

fn main() -> int:
    h := conc_space_create(CONC_SPACE_HOST, 1048576)
    d := conc_space_create(CONC_SPACE_DEVICE, 1048576)
    if h < 0 || d < 0:
        return 1
    conc_layout_declare(7, 16, 4660)
    if conc_layout_add_field(7, 0, 8) != 0:
        return 16
    r := conc_ref_alloc_space(h, 16, 7)
    if conc_ref_space(r) != h:
        return 2
    p := conc_ref_payload(r)
    cell_store(p, 0, 11)
    cell_store(p, 8, 22)
    m := conc_space_move(r, d)
    if conc_ref_ok(r) != 0:
        return 3
    if conc_ref_ok(m) == 0:
        return 4
    if conc_ref_space(m) != d:
        return 5
    if conc_transfer_bytes() != 16:
        return 6
    if conc_space_bytes(d) != 16:
        return 7
    c := conc_space_copy(m, h)
    if conc_ref_ok(c) == 0:
        return 8
    if conc_transfer_bytes() != 32:
        return 9
    cs := conc_space_copy_set(m, h)
    if conc_ref_ok(cs) == 0:
        return 17
    if cell_load(conc_ref_payload(cs), 0) != 11:
        return 18
    if cell_load(conc_ref_payload(cs), 8) != 0:
        return 19
    if conc_transfer_bytes() != 40:
        return 20
    ms := conc_space_move_set(cs, d)
    if conc_ref_ok(cs) != 0:
        return 21
    if conc_ref_ok(ms) == 0:
        return 22
    if conc_transfer_bytes() != 48:
        return 23
    l := conc_space_loan(c, d)
    if conc_ref_ok(c) != 0:
        return 10
    if conc_ref_ok(l) == 0:
        return 24
    forged := conc_ref_alloc(h, 16, 7)
    if conc_ref_ok(forged) == 0:
        return 25
    if conc_space_return(c, forged) == 0:
        return 26
    cell_store(conc_ref_payload(l), 0, 99)
    if conc_space_return(c, l) != 0:
        return 11
    if cell_load(conc_ref_payload(c), 0) != 99:
        return 12
    if conc_space_return(c, l) == 0:
        return 27
    if conc_loan_count() != 0:
        return 28
    s0 := conc_space_split_part(c, d, 0, 2)
    s1 := conc_space_split_part(c, d, 1, 2)
    if conc_ref_ok(s0) == 0 || conc_ref_ok(s1) == 0:
        return 13
    f := conc_space_fill(d, 8, 7)
    if conc_ref_ok(f) == 0:
        return 14
    if conc_space_used(d) <= 0:
        return 15
    if conc_xfer_move_bytes() < 24:
        return 29
    if conc_xfer_copy_bytes() < 24:
        return 30
    if conc_xfer_loan_bytes() < 32:
        return 31
    if conc_xfer_split_bytes() < 16:
        return 32
    if conc_transfer_failures() < 2:
        return 33
    if conc_space_in(d) <= 0 || conc_space_out(h) <= 0:
        return 34
    return 0
"""


REF_EPOCH = """\
import conc

fn main() -> int:
    r0 := conc_region_new(65536)
    r1 := conc_region_new(65536)
    ch := conc_channel_new_ref(r1, 2)
    ref := conc_ref_alloc(r0, 8, 3)
    cell_store(conc_ref_payload(ref), 0, 5)
    if conc_send_ref(ch, ref) != 0:
        return 1
    if conc_region_reset(r0) != 0:
        return 2
    got := conc_recv_ref(ch)
    if str_len(got) != 0:
        return 3
    if conc_send_ref(ch, ref) != -1:
        return 4
    return 0
"""


def run(cmd: list[str], timeout: int = 120) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=BASE, capture_output=True, text=True,
                          timeout=timeout)


def build_run(name: str, source: str, timeout: int = 60,
              expect: int = 0) -> bool:
    if not COREC.exists() or not COREARCH.exists():
        print("FAIL: missing build/corec or build/corearch")
        return False
    with tempfile.TemporaryDirectory(prefix=f"{name}_") as td:
        root = Path(td)
        src = root / f"{name}.cr"
        ccr = root / f"{name}.ccr"
        elf = root / f"{name}.elf"
        src.write_text(source, encoding="utf-8")
        c = run([str(COREC), "ccr", str(src), "-o", str(ccr)])
        if c.returncode != 0:
            print(f"FAIL {name} corec")
            print(c.stdout[-1600:])
            print(c.stderr[-1600:])
            return False
        a = run([str(COREARCH), "--raw-int", "--elf", str(ccr), "-o", str(elf)])
        if a.returncode != 0:
            print(f"FAIL {name} corearch")
            print(a.stdout[-1600:])
            print(a.stderr[-1600:])
            return False
        r = run([str(elf)], timeout=timeout)
        if r.returncode != expect:
            print(f"FAIL {name} run rc={r.returncode}, expected {expect}")
            print(r.stdout[-1600:])
            print(r.stderr[-1600:])
            return False
    print(f"PASS {name}")
    return True


def main() -> int:
    cases = [
        ("ref_transfer", TRANSFER, 60, 0),
        ("ref_channel_epoch", REF_EPOCH, 60, 0),
        ("space_transfer", SPACE_TRANSFER, 60, 0),
    ]
    ok = True
    for name, source, timeout, expect in cases:
        ok = build_run(name, source, timeout, expect) and ok
    print(f"{len(cases) if ok else 0}/{len(cases)} passed")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
