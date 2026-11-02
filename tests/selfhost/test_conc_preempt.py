#!/usr/bin/env python3
"""CP-6: preemption at loop backedges and futex park/wake."""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"
COREARCH = BASE / "build" / "corearch"

PREEMPT = """\
import sched
import chan

g_flag : int, mut = 0

fn short() -> int:
    g_flag = 1
    return 7

fn dummy() -> int:
    return 0

fn long() -> int:
    i : ., mut = 0
    loop:
        if i >= 200000:
            break
        if i == 100000:
            if g_flag == 0:
                return 1
        i = i + 1
    return 0

fn main() -> int:
    sched_init_n(2)
    a := go long()
    d := go dummy()
    b := go short()
    x := chan_recv(a)
    y := chan_recv(b)
    z := chan_recv(d)
    if x != 0:
        return x
    if y != 7:
        return 2
    if z != 0:
        return 3
    return 0
"""

PREEMPT_OFF = """\
import sched
import chan

g_flag : int, mut = 0

fn short() -> int:
    g_flag = 1
    return 7

fn dummy() -> int:
    return 0

fn long() -> int:
    i : ., mut = 0
    loop:
        if i >= 200000:
            break
        if i == 100000:
            if g_flag == 0:
                return 1
        i = i + 1
    return 0

fn main() -> int:
    conc_set_signal_preempt(0)
    conc_set_quantum(100000000)
    sched_init_n(2)
    a := go long()
    d := go dummy()
    b := go short()
    x := chan_recv(a)
    y := chan_recv(b)
    z := chan_recv(d)
    if x != 0:
        return x
    if y != 7:
        return 2
    if z != 0:
        return 3
    return 0
"""

PREEMPT_SIGNAL = """\
import sched
import chan

g_flag : int, mut = 0

fn short() -> int:
    g_flag = 1
    return 7

fn dummy() -> int:
    return 0

fn long() -> int:
    i : ., mut = 0
    loop:
        if i >= 50000000:
            break
        if i == 25000000:
            if g_flag == 0:
                return 1
        i = i + 1
    return 0

fn main() -> int:
    conc_set_quantum(100000000)
    sched_init_n(2)
    a := go long()
    d := go dummy()
    b := go short()
    x := chan_recv(a)
    y := chan_recv(b)
    z := chan_recv(d)
    if x != 0:
        return x
    if y != 7:
        return 2
    if z != 0:
        return 3
    return 0
"""


FUTEX_STRESS = """\
import sched
import chan

fn work(n: int) -> int:
    return n + 1

fn main() -> int:
    sched_init_n(4)
    sum : ., mut = 0
    i : ., mut = 0
    loop:
        if i >= 2000:
            break
        ch := go work(i)
        sum = sum + chan_recv(ch)
        i = i + 1
    if sum != 2001000:
        return sum
    return 0
"""

FUTEX_CROSS_M = """\
import sched
import chan

g_ch : string, mut

fn dummy() -> int:
    return 0

fn producer() -> int:
    chan_send(g_ch, 1)
    chan_send(g_ch, 2)
    return 0

fn main() -> int:
    sched_init_n(2)
    g_ch = chan_make(8, 1)
    d := go dummy()
    p := go producer()
    a := chan_recv(g_ch)
    b := chan_recv(g_ch)
    x := chan_recv(d)
    y := chan_recv(p)
    if a != 1:
        return a
    if b != 2:
        return b
    if x != 0:
        return 3
    if y != 0:
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
        ("preempt_same_m", PREEMPT, 60, 0),
        ("preempt_signal_only", PREEMPT_SIGNAL, 90, 0),
        ("preempt_disabled_control", PREEMPT_OFF, 60, 1),
        ("futex_idle_stress", FUTEX_STRESS, 120, 0),
        ("futex_cross_m_blocking_send", FUTEX_CROSS_M, 60, 0),
    ]
    ok = True
    for name, source, timeout, expect in cases:
        ok = build_run(name, source, timeout, expect) and ok
    print(f"{len(cases) if ok else 0}/{len(cases)} passed")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
