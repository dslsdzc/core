#!/usr/bin/env python3
"""批 8（甲）批 1 · 刀 1 —— `unify_types` 的 `T?` 规则 · 判据套件（2026-09-18）

背景（RED 基线 = `develop@origin` `965052b5` 态编译器）：
  `checker.cr` 的 `unify_types` 只有三条规则（`pattern == concrete` / `TYP_GENERIC_PARAM` /
  `TYP_GENERIC_APPLY`），`T?`（`TYP_OPTIONAL`，内层泛型参数）落**兜底**
  `type_compat_strict(concrete, pattern)` ⇒ **内层不代入、不绑定、恒假**。
  后果（**改前实测 = 本套件同一批探针在「变异体」（= 当前基点删回本分支重建）上的读数**）：
  泛型调用里 `T?` 形参的实参**既不绑定也不校验** ⇒ ① `[S1-ARG]` report-only 打点对 `T?` **恒报**；
  ② **更重**：`T?` 形参的单泛型调用（`g2(d)` / `g2(x:int)` / `g2(Some(3))` / `return g2(x)` / `f := g2(x); return f`）
  **在**当前基点 `965052b5` 上**本就是硬错 `error[TF01]`（rc=1）**——根因同一条：`unify` 不绑定 ⇒
  调用结果型解不出 ⇒ 调用者被判「返回型不符」。（旧基点 `41a51d8d` 上它们是 rc=0 + 1 条打点 ⇒
  **2(a) 合并后升级成硬错**；本刀同时修掉这两层。）
  ⚠ 本刀**只动诊断/绑定面**：产物面零足迹由批次判据另行钉（canary 五值逐字节同改前 + 六套件全绿）。

修复 = **只加分支、不改既有三条规则的语义**：
  `pk == TYP_OPTIONAL` ⇒ ① concrete 亦 optional ⇒ 内层对内层递归；② 否则（裸值入 `T?`）⇒ 内层对 concrete 递归。

判据（**两向钉子**：只写 C1 会被「一律不报」满足；只写 C2 会被「一律报」满足）：
  C1 正例（5 例）：`check rc=0` **且 `[S1-ARG]` 行数 == 0**（改前各 **1**）——合法调用不再误报。
  C2 真错仍报（1 例）：`g(1, d)`（apx）⇒ `check rc=0` 且 `[S1-ARG]` 行数 == **1**（改前 1）——
     该实例由首实参定 `int`、第二实参 `dex` 与 `int?` 不符 ⇒ **该报的还得报**（本批不修 (甲) 主体）。
  C3 实例键不变（机械腿）：`cir` 文本含 `g[dex]` / `g2[int]` / `call g2[dex](_dxsc)`。
  C4 零足迹（对照）：非泛型直调 `g12(1, d)` ⇒ `[S1-ARG]` == 0（改前 0）——改动未波及非泛型面。
  C5 槽型直读（`--dump-params`）：`g[dex]` 的 `p1 x` = `slot=8`；`g[int]` 的 `p1 x` = `slot=0`。
  C7 同族 TF01 三例（T0 登记「未定位根因」者）：`g2(Some(3))` / `f := g2(x); return f` / `return g2(x)`
     ⇒ 修复后 `check rc=0`（**变异体 rc=1 · `error[TF01]`** = 本批的前置读数）；对照 `f := g2(x); return 0`
     两态皆 rc=0（说明该错只在**返回位**暴露）。

突变自证（配方，独立工作区）：把 `checker.cr` 的 `T?` 分支整块删回原状 → 重建 →
  `COREC_BIN=<变异二进制> python3 tests/selfhost/test_topt_pattern.py` ⇒ **C1 五例全红**（误报复现）+ **C7 三例红**（TF01 复现），
  且 C2/C3/C4/C5 仍绿（= 判据分工：C1 咬绑定/打点面，C3/C4 咬产物与波及面）。
"""

import os
import resource
import subprocess
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = Path(os.environ.get("COREC_BIN", str(BASE / "build" / "corec")))

PROBE_C6 = """fn g[T](t: T, x: T?) -> int { return 1; }
fn main() -> int { d : dex, apx = 7.0; return g(d, d); }
"""

PROBE_C7 = """fn g2[T](x: T?) -> int { return 1; }
fn main() -> int { d : dex, apx = 7.0; return g2(d); }
"""

PROBE_J = """fn g[T](x: T?, t: T) -> int { return 1; }
fn main() -> int { d : dex, apx = 7.0; return g(d, d); }
"""

PROBE_K = """fn g[T](x: T?, t: T) -> int { return 1; }
fn main() -> int { d : dex, apx = 7.0; return g(Some(d), d); }
"""

PROBE_M = """fn g2[T](x: T?) -> int { return 1; }
fn main() -> int { x : int = 3; return g2(x); }
"""

PROBE_P0 = """fn g[T](t: T, x: T?) -> int {
    return match x { Some(v) => { return @raw_int(v) / 1000000; } None => { return 0; } };
}
fn main() -> int { d : dex, apx = 7.0; return g(1, d); }
"""

PROBE_G12 = """fn g12[T](t: T, x: dex) -> int { return @raw_int(x) / 1000000; }
fn main() -> int { d : dex, apx = 7.0; return g12(1, d); }
"""

# C7：T0 登记的同族 TF01 三例（根因 = 本刀；变异体 rc=1）
PROBE_L = """fn g2[T](x: T?) -> int { return 1; }
fn main() -> int { return g2(Some(3)); }
"""

PROBE_B = """fn g2[T](x: T?) -> int { return 1; }
fn main() -> int { x : int = 3; f := g2(x); return f; }
"""

PROBE_E = """fn g2[T](x: T?) -> int { return 1; }
fn main() -> int { x : int = 3; return g2(x); }
"""

PROBE_F2 = """fn g2[T](x: T?) -> int { return 1; }
fn main() -> int { x : int = 3; f := g2(x); return 0; }
"""

# 实例键机械腿：C6 与 M 合用一档（`g[dex]` + `g2[int]`）；C7 单档（`g2[dex]` + `_dxsc`）
PROBE_KEYS = """fn g[T](t: T, x: T?) -> int { return 1; }
fn g2[T](x: T?) -> int { return 1; }
fn main() -> int {
    d : dex, apx = 7.0;
    a := g(d, d);
    b := g2(d);
    return a + b;
}
"""


def _no_core_dump():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def _write(src: str) -> str:
    fd, path = tempfile.mkstemp(suffix=".cr")
    with os.fdopen(fd, "w") as f:
        f.write(src)
    return path


def _clean_cache():
    subprocess.run(["rm", "-rf", str(BASE / ".core" / "cache" / "cir")], check=False)


def _run(args, timeout=300):
    return subprocess.run(
        [str(COREC)] + args, capture_output=True, text=True, cwd=BASE, timeout=timeout
    )


def s1_lines(src_path: str):
    """`check` 的 stdout 里 `[S1-ARG]` 行（**只认行首**，防源码回显假阳）。"""
    r = _run(["check", src_path])
    return r.returncode, [ln for ln in r.stdout.splitlines() if ln.startswith("[S1-ARG]")]


def params_of(src_path: str):
    _clean_cache()
    out = tempfile.mktemp(suffix=".cir")
    r = _run(["cir", src_path, "-o", out, "--dump-params"])
    try:
        os.unlink(out)
    except FileNotFoundError:
        pass
    res = {}
    for ln in r.stdout.splitlines():
        if not ln.startswith("PARAM "):
            continue
        parts = ln.split()
        if len(parts) < 6 or not parts[2].startswith("p") or not parts[4].startswith("slot="):
            continue
        res.setdefault(parts[1], {})[int(parts[2][1:])] = (
            parts[3], int(parts[4].split("=")[1]), int(parts[5].split("=")[1]),
        )
    return res


def main() -> int:
    _no_core_dump()
    fails = []
    tmp = []

    def check(cond, msg):
        if cond:
            print("PASS " + msg)
        else:
            print("FAIL " + msg)
            fails.append(msg)

    # ── C1 正例组：合法调用不再误报（改前各 1 条）────────────────────────────
    for name, src in (("C6 g(d,d)", PROBE_C6), ("C7 g2(d)", PROBE_C7), ("J g(d,d) T?首", PROBE_J),
                      ("K g(Some(d),d)", PROBE_K), ("M g2(int)", PROBE_M)):
        p = _write(src)
        tmp.append(p)
        rc, lines = s1_lines(p)
        check(rc == 0 and len(lines) == 0,
              f"C1 · {name}: check rc={rc} · [S1-ARG] 行数={len(lines)}（期望 0；改前 1）")

    # ── C2 真错仍报（两向钉子的另一向）──────────────────────────────────────
    p = _write(PROBE_P0)
    tmp.append(p)
    rc, lines = s1_lines(p)
    check(rc == 0 and len(lines) == 1,
          f"C2 · P0 g(1,d): check rc={rc} · [S1-ARG] 行数={len(lines)}（期望 1：真错未被吞）")

    # ── C3 实例键/转换机械腿（不影响产物语义）──────────────────────────────
    p = _write(PROBE_KEYS)
    tmp.append(p)
    _clean_cache()
    out = tempfile.mktemp(suffix=".cir")
    r = _run(["cir", p, "-o", out])
    try:
        os.unlink(out)
    except FileNotFoundError:
        pass
    txt = r.stdout
    check("g[dex]" in txt, "C3 · 实例 g[dex] 在场（T? 绑定未改实例键）")
    check("g2[dex]" in txt, "C3 · 实例 g2[dex] 在场（T? 实参绑定 T=dex）")
    check("call g2[dex](_dxsc)" in txt, "C3 · 调用点转换 call g2[dex](_dxsc) 仍在场")

    ps = params_of(p)
    check(ps.get("g[dex]", {}).get(1, ("", -1, -1))[1] == 8, "C5 · g[dex] 的 p1 x slot=8（dex 槽）")
    check(ps.get("g2[dex]", {}).get(0, ("", -1, -1))[1] == 8, "C5 · g2[dex] 的 p0 x slot=8")

    # ── C7 同族 TF01 三例（本刀即其根因；变异体 rc=1）─────────────────────
    for name, src in (("L g2(Some(3))", PROBE_L), ("B f:=g2(x);return f", PROBE_B),
                      ("E return g2(x)", PROBE_E)):
        p = _write(src)
        tmp.append(p)
        rc, lines = s1_lines(p)
        check(rc == 0, f"C7 · {name}: check rc={rc}（期望 0；变异体 rc=1 · error[TF01]）")
    p = _write(PROBE_F2)
    tmp.append(p)
    rc, _ = s1_lines(p)
    check(rc == 0, f"C7 对照 · f:=g2(x);return 0: check rc={rc}（期望 0——该错只在返回位暴露）")

    # ── C4 零足迹对照：非泛型面不受影响 ────────────────────────────────────
    p = _write(PROBE_G12)
    tmp.append(p)
    rc, lines = s1_lines(p)
    check(rc == 0 and len(lines) == 0,
          f"C4 · g12(1,d) 非泛型 dex 形参: check rc={rc} · [S1-ARG] 行数={len(lines)}（期望 0，改前 0）")

    for t in tmp:
        try:
            os.unlink(t)
        except FileNotFoundError:
            pass

    print("")
    if fails:
        print(f"FAILED {len(fails)} 项：" + "; ".join(fails))
        return 1
    print("ALL PASS (C1–C7)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
