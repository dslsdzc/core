"""V4 类型位推断：无 [] 的形参与字段。

判据：
  * `fn first(xs) -> int` 不写形参类型，数组和切片在调用点绑定；
    同一个函数同时接 `[int; 3]` 与切片。
  * `struct Event: payload: .` 不写字段类型，构造点绑定；
    同一个 struct 同时接 int 和 string。

类型位的 [] 在这里不应出现；[] 只保留给字面量和下标。

注意：`for x in xs`（序列迭代）还没有 IR 实现，不能放进本测试；
它会把数组值当循环上界，导致运行期死循环。见 v4 序列迭代的独立切片。
"""

import os
import subprocess
import sys
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = os.environ.get("COREC_BIN") or str(BASE / "build" / "corec")
BUILD = BASE / "build"


def _run(cmd, timeout=120):
    return subprocess.run(cmd, cwd=BASE, capture_output=True, text=True, timeout=timeout)


def _build_and_run(name, source, want_rc):
    fd, path = tempfile.mkstemp(suffix=".cr", dir="/tmp")
    with os.fdopen(fd, "w") as fh:
        fh.write(source)
    out = str(BUILD / ("_v4_infer_" + name))
    try:
        b = _run([COREC, "build", path, "-o", out, "--static"])
        if b.returncode != 0:
            print(f"[FAIL] {name}: build rc={b.returncode}\n{b.stdout}\n{b.stderr}")
            return False
        r = _run([out])
        if r.returncode != want_rc:
            print(f"[FAIL] {name}: run rc={r.returncode} want={want_rc}\n{r.stdout}\n{r.stderr}")
            return False
        print(f"[PASS] {name}: run rc={r.returncode}")
        return True
    finally:
        for p in (path, out, out + ".ccr", out + ".cir"):
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass


def main():
    ok = []

    ok.append(_build_and_run(
        "param_array_and_slice",
        """fn first(xs) -> int:
    return xs[0]

fn main() -> int:
    xs := [7, 8, 9]
    s := xs[0..2]
    return first(xs) + first(s)
""",
        14,
    ))

    ok.append(_build_and_run(
        "struct_field_int",
        """struct Event:
    name: string
    payload: .

fn main() -> int:
    e := Event { name = "a", payload = 42 }
    return e.payload
""",
        42,
    ))

    ok.append(_build_and_run(
        "struct_field_two_types",
        """import fmt

struct Event:
    name: string
    payload: .

fn main() -> int:
    a := Event { name = "a", payload = 40 }
    b := Event { name = "b", payload = "xy" }
    return a.payload + str_len(b.payload)
""",
        42,
    ))

    passed = sum(1 for x in ok if x)
    print(f"{passed}/{len(ok)} passed")
    return 0 if passed == len(ok) else 1


if __name__ == "__main__":
    raise SystemExit(main())
