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
    sched_init_n(1)
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


YIELD_SWITCH = """\
import sched
import chan

g_seq : string, mut

fn a() -> int:
    cell_store(g_seq, 0, 1)
    yield 0
    if cell_load(g_seq, 16) != 2:
        return 1
    cell_store(g_seq, 8, 3)
    return 0

fn b() -> int:
    cell_store(g_seq, 16, 2)
    return 0

fn main() -> int:
    sched_init_n(1)
    g_seq = alloc(24)
    x := go a()
    y := go b()
    r1 := chan_recv(x)
    r2 := chan_recv(y)
    if r1 != 0:
        return r1
    if r2 != 0:
        return r2
    if cell_load(g_seq, 0) != 1:
        return 2
    if cell_load(g_seq, 8) != 3:
        return 3
    return 0
"""


CLOSE_CROSS = """\
import sched
import chan

fn dummy() -> int:
    return 0

fn waiter(ch: string) -> int:
    v := chan_recv(ch)
    return v + 1

fn main() -> int:
    sched_init_n(2)
    ch := chan_make(8, 0)
    d := go dummy()
    w := go waiter(ch)
    chan_close(ch)
    r := chan_recv(w)
    if r != 1:
        return r
    if chan_recv(d) != 0:
        return 2
    return 0
"""


SHUTDOWN = """\
import sched
import chan

fn work() -> int:
    return 0

fn main() -> int:
    sched_init_n(2)
    if conc_worker_failures() != 0:
        return 5
    ch := go work()
    if chan_recv(ch) != 0:
        return 1
    conc_shutdown()
    i : ., mut = 0
    loop:
        if i >= 100000000:
            return 2
        if conc_workers_done() >= 1:
            return 0
        i = i + 1
    return 3
"""


PI_LOCK = """\
import sched
import chan

g_word : string, mut
g_count : int, mut = 0

fn worker() -> int:
    if conc_pi_lock(g_word) != 0:
        return 1
    g_count = g_count + 1
    if conc_pi_unlock(g_word) != 0:
        return 2
    return 0

fn main() -> int:
    sched_init_n(2)
    g_word = alloc(8)
    cell_store(g_word, 0, 0)
    a := go worker()
    b := go worker()
    if chan_recv(a) != 0:
        return 3
    if chan_recv(b) != 0:
        return 4
    if g_count != 2:
        return 5
    return 0
"""


_straight_stmts = "\n".join(f"    x = x + {i % 3 + 1}" for i in range(400))
STRAIGHT = f"""\
import sched
import chan

g_flag : int, mut = 0

fn short() -> int:
    g_flag = 1
    return 7

fn dummy() -> int:
    return 0

fn long() -> int:
    x : ., mut = 0
{_straight_stmts}
    if g_flag == 0:
        return 1
    return 0

fn main() -> int:
    conc_set_quantum(1)
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
        return 3
    if z != 0:
        return 4
    return 0
"""

STRAIGHT_OFF = STRAIGHT.replace(
    "    conc_set_quantum(1)",
    "    conc_set_signal_preempt(0)\n    conc_set_quantum(100000000)",
)


PREEMPT_DISABLE = """\
import sched
import chan

g_b_ran : int, mut = 0

fn b() -> int:
    g_b_ran = 1
    return 0

fn a() -> int:
    conc_preempt_disable()
    if conc_preempt_depth() < 1:
        return 1
    i : ., mut = 0
    loop:
        if i >= 200000:
            break
        i = i + 1
    if g_b_ran != 0:
        return 2
    conc_preempt_enable()
    if conc_preempt_depth() != 0:
        return 3
    yield 0
    if g_b_ran != 1:
        return 4
    return 0

fn main() -> int:
    conc_set_quantum(1)
    sched_init_n(1)
    x := go a()
    y := go b()
    r1 := chan_recv(x)
    r2 := chan_recv(y)
    if r1 != 0:
        return r1
    if r2 != 0:
        return r2
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
        ("preempt_disable_depth", PREEMPT_DISABLE, 60, 0),
        ("yield_switches", YIELD_SWITCH, 60, 0),
        ("futex_idle_stress", FUTEX_STRESS, 120, 0),
        ("futex_cross_m_blocking_send", FUTEX_CROSS_M, 60, 0),
        ("close_wakes_cross_m", CLOSE_CROSS, 60, 0),
        ("shutdown_cancels_workers", SHUTDOWN, 60, 0),
        ("futex_pi_lock", PI_LOCK, 60, 0),
        ("straight_line_preempt", STRAIGHT, 120, 0),
        ("straight_line_control", STRAIGHT_OFF, 120, 1),
    ]
    ok = True
    for name, source, timeout, expect in cases:
        ok = build_run(name, source, timeout, expect) and ok
    print(f"{len(cases) if ok else 0}/{len(cases)} passed")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
