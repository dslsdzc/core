#!/usr/bin/env python3
"""CP-5: true OS-thread multi-M runtime tests."""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"
COREARCH = BASE / "build" / "corearch"

ARENA_STRESS = """\
import arena

fn main() -> int:
    arena_init_m(1073741824, 1048576, 2)
    i : ., mut = 0
    loop:
        if i >= 2000:
            break
        aid := arena_new_sized(65536)
        if aid < 0:
            return 1
        p := alloc(2048)
        if p < 0:
            return 2
        arena_reset(aid)
        i = i + 1
    return 0
"""

TWO_WORKERS = """\
import sched
import chan

fn work(n: int) -> int:
    return n + 1

fn main() -> int:
    sched_init_n(2)
    c1 := go work(1)
    c2 := go work(2)
    r1 := chan_recv(c1)
    r2 := chan_recv(c2)
    if r1 != 2:
        return 1
    if r2 != 3:
        return 2
    return 0
"""

FOUR_WORKERS = """\
import sched
import chan

g_buf : string, mut

fn work(n: int) -> int:
    return n + 1

fn main() -> int:
    sched_init_n(4)
    g_buf = alloc(64 * 8)
    i : ., mut = 0
    loop:
        if i >= 64:
            break
        ch := go work(i)
        cell_store(g_buf, i * 8, ch)
        i = i + 1
    sum : ., mut = 0
    i = 0
    loop:
        if i >= 64:
            break
        ch := cell_load(g_buf, i * 8)
        sum = sum + chan_recv(ch)
        i = i + 1
    if sum != 2080:
        return sum
    return 0
"""

EIGHT_WORKERS = """\
import sched
import chan

g_buf : string, mut

fn work(n: int) -> int:
    return n + 1

fn main() -> int:
    sched_init_n(8)
    g_buf = alloc(512 * 8)
    i : ., mut = 0
    loop:
        if i >= 512:
            break
        ch := go work(i)
        cell_store(g_buf, i * 8, ch)
        i = i + 1
    sum : ., mut = 0
    i = 0
    loop:
        if i >= 512:
            break
        ch := cell_load(g_buf, i * 8)
        sum = sum + chan_recv(ch)
        i = i + 1
    if sum != 131328:
        return sum
    return 0
"""


CROSS_M_PINGPONG = """\
import sched
import chan

g_in : string, mut
g_out : string, mut

fn noop() -> int:
    return 0

fn ping(x: int) -> int:
    v := chan_recv(g_in)
    chan_send(g_out, v + 1)
    return 0

fn main() -> int:
    sched_init_n(2)
    g_in = chan_make(8, 1)
    g_out = chan_make(8, 1)
    d := go noop()
    p := go ping(0)
    chan_send(g_in, 0)
    r := chan_recv(g_out)
    if r != 1:
        return 1
    return 0
"""

WORK_STEAL = """\
import sched
import chan

fn spin() -> int:
    i : ., mut = 0
    loop:
        if i >= 4000000:
            break
        i = i + 1
    return 0

fn work(n: int) -> int:
    return n + 1

fn main() -> int:
    sched_init_n(2)
    a := go spin()
    sum : ., mut = 0
    i : ., mut = 0
    loop:
        if i >= 200:
            break
        ch := go work(i)
        sum = sum + chan_recv(ch)
        i = i + 1
    if sum != 20100:
        return sum
    if chan_recv(a) != 0:
        return 2
    if conc_steal_attempts() <= 0:
        return 3
    if conc_steal_count() <= 0:
        return 4
    return 0
"""

STARTED_STEAL = """\
import sched
import chan

fn yielder(n: int) -> int:
    i : ., mut = 0
    loop:
        if i >= 1000:
            break
        conc_yield()
        i = i + 1
    return n + 1

fn main() -> int:
    sched_init_n(4)
    ch := go yielder(41)
    if chan_recv(ch) != 42:
        return 1
    if conc_steal_count() <= 0:
        return 2
    return 0
"""

METRICS = """\
import sched
import chan

fn work(n: int) -> int:
    return n + 1

fn waiter(ch: string) -> int:
    return chan_recv(ch)

fn main() -> int:
    sched_init_n(2)
    conc_metrics_reset()
    a := go work(1)
    b := go work(2)
    r1 := chan_recv(a)
    r2 := chan_recv(b)
    if r1 + r2 != 5:
        return 1
    if conc_spawn_count() < 2:
        return 2
    if conc_ready_push_count() < 2:
        return 3
    if conc_ready_pop_count() < 2:
        return 4
    if conc_send_count() < 2:
        return 5
    if conc_recv_count() < 2:
        return 6
    if conc_wake_count() < 1:
        return 7
    if conc_ready_len(0) < 0:
        return 8
    if str_len(conc_metrics_explain()) < 50:
        return 9
    rch := chan_make(8, 0)
    w := go waiter(rch)
    chan_send(rch, 1)
    if chan_recv(w) != 1:
        return 10
    if conc_wait_count() < 1:
        return 11
    if conc_wait_ms_max() < 0:
        return 12
    return 0
"""

SPAWN_STRESS = """\
import sched
import chan

fn work(n: int) -> int:
    return n + 1

fn main() -> int:
    sched_init_n(2)
    sum : ., mut = 0
    i : ., mut = 0
    loop:
        if i >= 1000:
            break
        ch := go work(i)
        sum = sum + chan_recv(ch)
        i = i + 1
    if sum != 500500:
        return sum
    return 0
"""


def run(cmd: list[str], timeout: int = 120) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, cwd=BASE, capture_output=True, text=True,
                          timeout=timeout)


def build_run(name: str, source: str, timeout: int = 60) -> bool:
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
        if r.returncode != 0:
            print(f"FAIL {name} run rc={r.returncode}")
            print(r.stdout[-1600:])
            print(r.stderr[-1600:])
            return False
    print(f"PASS {name}")
    return True


def main() -> int:
    cases = [
        ("arena_partition_stress", ARENA_STRESS, 120),
        ("two_workers_two_goroutines", TWO_WORKERS, 60),
        ("four_workers_queue", FOUR_WORKERS, 60),
        ("eight_workers_queue", EIGHT_WORKERS, 90),
        ("cross_m_pingpong", CROSS_M_PINGPONG, 60),
        ("metrics", METRICS, 90),
        ("work_steal", WORK_STEAL, 120),
        ("started_steal", STARTED_STEAL, 120),
        ("spawn_stress", SPAWN_STRESS, 120),
    ]
    ok = True
    for name, source, timeout in cases:
        ok = build_run(name, source, timeout) and ok
    print(f"{sum(1 for _ in cases) if ok else 0}/{len(cases)} passed")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
