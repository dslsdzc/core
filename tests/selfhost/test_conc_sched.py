#!/usr/bin/env python3
"""CP-4: default go/chan on the conc cooperative scheduler."""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"
COREARCH = BASE / "build" / "corearch"

CHANNEL_ARG = """\
import chan
import sched

g_out : string, mut

fn worker(req: string) -> int:
    v := chan_recv(req)
    chan_send(g_out, v + 1)
    return 0

fn main() -> int:
    sched_init()
    req := chan_make(8, 1)
    g_out = chan_make(8, 1)
    h := go worker(req)
    chan_send(req, 41)
    v := chan_recv(g_out)
    if v != 42:
        return 1
    return 0
"""

BLOCKING_SEND = """\
import chan
import sched

g_out : string, mut

fn worker() -> int:
    chan_send(g_out, 1)
    chan_send(g_out, 2)
    return 0

fn main() -> int:
    sched_init()
    g_out = chan_make(8, 1)
    h := go worker()
    a := chan_recv(g_out)
    b := chan_recv(g_out)
    if a != 1:
        return 1
    if b != 2:
        return 2
    return 0
"""

LARGE_CHANNEL = """\
import chan

fn main() -> int:
    ch := chan_make(8, 200000)
    chan_send(ch, 7)
    v := chan_recv(ch)
    if v != 7:
        return 1
    return 0
"""

NO_INIT = """\
import chan

fn work(n: int) -> int:
    return n + 1

fn main() -> int:
    ch := go work(41)
    v := chan_recv(ch)
    if v != 42:
        return 1
    return 0
"""

MANY_GO = """\
import chan
import sched

fn work(n: int) -> int:
    return n + 1

fn main() -> int:
    sched_init()
    i : ., mut = 0
    sum : ., mut = 0
    loop:
        if i >= 1000:
            break
        ch := go work(i)
        sum = sum + chan_recv(ch)
        i = i + 1
    if sum != 500500:
        return 1
    return 0
"""

RANGE_GO = """\
import chan
import sched

fn square(x: int) -> int:
    return x * x

fn main() -> int:
    arr := go i 0..3 square(i)
    if arr[0] + arr[1] + arr[2] != 5:
        return 1
    return 0
"""

RENDEZVOUS = """\
import chan
import sched

g_ch : string, mut

fn sender() -> int:
    chan_send(g_ch, 55)
    return 0

fn main() -> int:
    sched_init()
    g_ch = chan_make(8, 0)
    h := go sender()
    v := chan_recv(g_ch)
    if v != 55:
        return 1
    return 0
"""

MPMC = """\
import chan
import sched

g_ch : string, mut

fn sender(n: int) -> int:
    chan_send(g_ch, n)
    return 0

fn main() -> int:
    sched_init()
    g_ch = chan_make(8, 0)
    a := go sender(1)
    b := go sender(2)
    x := chan_recv(g_ch)
    y := chan_recv(g_ch)
    if x + y != 3:
        return 1
    return 0
"""

TWO_GO = """\
import chan
import sched

fn work(n: int) -> int:
    return n * n

fn main() -> int:
    sched_init()
    a := go work(6)
    b := go work(7)
    x := chan_recv(a)
    y := chan_recv(b)
    if x != 36:
        return 1
    if y != 49:
        return 2
    return 0
"""


PRIORITY = """\
import sched
import chan

g_order : string, mut

fn low(x: int) -> int:
    if cell_load(g_order, 0) == 0:
        cell_store(g_order, 0, 76)
    return 0

fn high(x: int) -> int:
    cell_store(g_order, 0, 72)
    return 0

fn main() -> int:
    sched_init_n(1)
    g_order = alloc(8)
    r1 := chan_make(8, 1)
    r2 := chan_make(8, 1)
    conc_spawn_priority(@addr(low), 0, r1, 0)
    conc_spawn_priority(@addr(high), 0, r2, 7)
    if chan_recv(r1) != 0:
        return 1
    if chan_recv(r2) != 0:
        return 2
    if cell_load(g_order, 0) != 72:
        return 3
    return 0
"""

CHANNEL_STATUS = """\
import sched
import chan

fn main() -> int:
    sched_init()
    ch := chan_make(8, 0)
    out := alloc(8)
    chan_close(ch)
    if conc_sched_send_int_status(ch, 1) != CONC_CHAN_CLOSED:
        return 1
    if conc_sched_recv_int_status(ch, out) != CONC_CHAN_CLOSED:
        return 2
    bad := alloc(8)
    if conc_sched_send_int_status(bad, 1) != CONC_CHAN_INVALID:
        return 3
    return 0
"""

STATE = """\
import sched

fn main() -> int:
    sched_init_n(2)
    if conc_set_quantum_m(0, 7) != 0:
        return 1
    if conc_get_quantum_m(0) != 7:
        return 2
    if str_len(conc_state_explain()) < 20:
        return 3
    return 0
"""

DEADLOCK = """\
import sched
import chan

fn waiter(ch: string) -> int:
    return chan_recv(ch)

fn main() -> int:
    sched_init_n(1)
    ch := chan_make(8, 0)
    w := go waiter(ch)
    i : ., mut = 0
    loop:
        if i >= 20:
            break
        conc_schedule()
        i = i + 1
    if conc_waiting_count() < 1:
        return 1
    if conc_deadlock_suspect() != 1:
        return 2
    if conc_deadlock_break() == 0:
        return 4
    conc_schedule()
    if conc_deadlock_suspect() != 0:
        return 3
    if conc_sched_is_closed(ch) == 0:
        return 5
    return 0
"""


def run(cmd: list[str], timeout: int = 120) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=BASE, capture_output=True, text=True,
                          timeout=timeout)


def build_run_native(name: str, source: str, timeout: int = 120) -> bool:
    if not COREC.exists() or not COREARCH.exists():
        print("FAIL: missing build/corec or build/corearch")
        return False
    with tempfile.TemporaryDirectory(prefix=f"conc_sched_{name}_") as td:
        root = Path(td)
        src = root / f"{name}.cr"
        elf = root / f"{name}.elf"
        src.write_text(source, encoding="utf-8")
        c = run([str(COREC), "build", str(src), "-o", str(elf), "--static"],
                timeout=timeout)
        if c.returncode != 0:
            print(f"FAIL {name} corec build")
            print(c.stdout[-1600:])
            print(c.stderr[-1600:])
            return False
        r = run([str(elf)], timeout=timeout)
        if r.returncode != 0:
            print(f"FAIL {name} run rc={r.returncode}")
            print(r.stdout[-1600:])
            print(r.stderr[-1600:])
            return False
    print(f"PASS {name}")
    return True


def build_run(name: str, source: str, timeout: int = 60) -> bool:
    if not COREC.exists() or not COREARCH.exists():
        print("FAIL: missing build/corec or build/corearch")
        return False
    with tempfile.TemporaryDirectory(prefix=f"conc_sched_{name}_") as td:
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
        if r.returncode != 0:
            print(f"FAIL {name} run rc={r.returncode}")
            print(r.stdout[-1600:])
            print(r.stderr[-1600:])
            return False
    print(f"PASS {name}")
    return True


def main() -> int:
    cases = [
        ("conc_sched_channel_arg", CHANNEL_ARG, 30),
        ("conc_sched_blocking_send", BLOCKING_SEND, 30),
        ("conc_sched_two_go", TWO_GO, 30),
        ("conc_sched_large_channel", LARGE_CHANNEL, 30),
        ("conc_sched_no_init", NO_INIT, 30),
        ("conc_sched_many_go", MANY_GO, 120),
        ("conc_sched_range_go", RANGE_GO, 30),
        ("conc_sched_rendezvous", RENDEZVOUS, 30),
        ("conc_sched_mpmc", MPMC, 30),
        ("conc_sched_deadlock", DEADLOCK, 30),
        ("conc_sched_channel_status", CHANNEL_STATUS, 30),
        ("conc_sched_priority", PRIORITY, 30),
        ("conc_sched_state", STATE, 30),
    ]
    passed = 0
    for name, source, timeout in cases:
        if build_run(name, source, timeout):
            passed += 1
    if build_run_native("conc_sched_native_build", TWO_GO, 120):
        passed += 1
    total = len(cases) + 1
    print(f"{passed}/{total} passed")
    return 0 if passed == total else 1


if __name__ == "__main__":
    raise SystemExit(main())
