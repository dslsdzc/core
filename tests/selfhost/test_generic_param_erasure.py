#!/usr/bin/env python3
"""(乙) 泛型实例形参擦除 · 判据套件（2026-09-18 修复）

背景（RED 基线 = develop `f57815ec` 态编译器，`/tmp/ge-pre/corec` sha256 `08821a51…`）：
  `monomorph.cr` 的 `EXPR_FN` 克隆**只深克隆函数体 `d`**，`b/c`（首形参/形参数）原样复制
  ⇒ 实例与声明**共用形参节点链** ⇒ 形参序言（`ir_gen.cr:3071`）读 `ast_type_val(pn)` = 0
  ⇒ 槽型恒 `TI_INT`（GP 类）；调用点对齐环（`ir_gen.cr:1984`）按**声明面**判门 ⇒ 泛型形参
  的两个子判据恒假 ⇒ **调用点不发任何转换指令**。后果（改前实测，本套件探针）：
    · bits 源（`d : dex, apx = 7.0`）ELF rc=**21**（正控 `h(d)` 通过、被测 `gp(d)` 失败）
    · scaled 源（`e : dex = 7.0`）ELF=interp=**41**（**两腿一致地错**——按纪律不算通过）
  修复 = A1（实例形参链克隆 + `type_val` 重算）+ A2a（重定向后按实例链复跑对齐环，幂等）。

判据（三态纪律见 `src/ci/run.sh:207-210`：bits 源 interp 腿 **255 = 能力边界 = 期望值**；
出现第三值判红；**不许单腿绿结案**）：
  C1 P1 · bits 源：ELF == 0；interp ∈ {255}；正控失败（=11）⇒ 报「判据无效」而非「修复失败」。
  C2 P1 · scaled 源：ELF == 0 **且** interp == 0（两腿严格）。
  C3 P2 · 槽型直读（`--dump-params`）：T 形态 `slot=8 decl=1`；T? 形态 `slot=8 decl=0`；
       int 实例 `slot=0`（非 dex 不变）；非泛型 dex 形参 `slot=8 decl=1`（既有行为不变）。
  C4 P2b · 调用点机械判据：`call g1[dex](_dxsc)`（转换在场）；scaled 实参 `call g1[dex](e)`
       （无需转换）；`call g2[dex](_dxsc)`（T? 形态）；`gi[int]` 无转换；main 内 `dest=_dxsc` 计 3。
  C5 幂等/不重复转换：`mixed[T](t: T, x: dex)` bits 源 ⇒ 恰 **2** 条 `dest=_dxsc`（每个 dex 族
       实参一次；**4 条 = 两遍各转一次 = 红**）；scaled 源 ⇒ **0** 条（两遍都无操作）。
  C6 rc 中性 + 零产物：带/不带 `--dump-params` ⇒ ELF 与 `.ccr` 逐字节相同、rc 相同。
  C7 三态安全 · check 面：探针 `check` rc=0 且零 `error[`。

突变自证（判据必须能被下列突变变红；配方与「命中目标」断言见计划 §11）：
  M-α 只回退 `type_val` 重算（保留形参链克隆）⇒ C3 的 **T 形态**红（T? 仍绿）
  M-β 只回退类型节点代入 ⇒ C3 的 **T? 形态**红（T 仍绿）
  M-γ 回退 A1 整体 ⇒ C3/C4/C1/C2 全红（= 回到 RED 基线）
  M-δ 只回退 A2a（第二遍）⇒ C3 仍绿（槽型已具体化）而 C4/C1/C2 红 —— **仪器与值判据分工**
  M-ε 让 dump 打 `decl` 当 `slot`（仪器自证）⇒ C3 红 ⇒ 证明 C3 抓的是槽型而非声明面
"""

import hashlib
import os
import resource
import subprocess
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
# 默认 build/corec；`COREC_BIN` 覆盖 = 突变自证通道（在**独立工作区**里变异后构出的二进制，
# 见计划 §11 突变矩阵；CI 不设该变量 ⇒ 判据面恒为仓内构建）。
COREC = Path(os.environ.get("COREC_BIN", str(BASE / "build" / "corec")))

# ── 探针（自包含；dex 两源：bits = `dex, apx` / scaled = `dex`）───────────────────
PROBE_FORMS = """fn h(x: dex) -> int { return 1; }
fn g1[T](x: T) -> int { return 1; }
fn g2[T](x: T?) -> int { return 1; }
fn gi[T](x: T) -> int { return 1; }
fn main() -> int {
    d : dex, apx = 7.0;
    e : dex = 7.0;
    a := h(d);
    b := g1(d);
    c := g1(e);
    f := g2(d);
    k := gi(1);
    return a + b + c + f + k;
}
"""

PROBE_VALUES_BITS = """fn h(x: dex) -> int { if x == 7.0 { return 1; } return 0; }
fn gp[T](x: T) -> int { if x == 7.0 { return 1; } return 0; }
fn main() -> int {
    d : dex, apx = 7.0;
    if gp(d) != 1 { return 21; }
    if h(d) != 1 { return 11; }
    return 0;
}
"""

PROBE_VALUES_SCALED = """fn h(x: dex) -> int { if x == 7.0 { return 1; } return 0; }
fn gp[T](x: T) -> int { if x == 7.0 { return 1; } return 0; }
fn main() -> int {
    e : dex = 7.0;
    if h(e) != 1 { return 31; }
    if gp(e) != 1 { return 41; }
    return 0;
}
"""

PROBE_MIXED_BITS = """fn mixed[T](t: T, x: dex) -> int { if t == x { return 1; } return 0; }
fn main() -> int {
    d : dex, apx = 7.0;
    return mixed(d, d) + 0;
}
"""

PROBE_MIXED_SCALED = """fn mixed[T](t: T, x: dex) -> int { if t == x { return 1; } return 0; }
fn main() -> int {
    e : dex = 7.0;
    return mixed(e, e) + 0;
}
"""


def _no_core_dump():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def _write(src: str, suffix: str = ".cr") -> str:
    fd, path = tempfile.mkstemp(suffix=suffix)
    with os.fdopen(fd, "w") as f:
        f.write(src)
    return path


def _run(args, timeout=300):
    return subprocess.run(
        [str(COREC)] + args, capture_output=True, text=True, cwd=BASE, timeout=timeout
    )


def _clean_cache():
    subprocess.run(["rm", "-rf", str(BASE / ".core" / "cache" / "cir")], check=False)


def _cir_dump(src_path: str, extra=None):
    """`corec cir` 的**文本 dump**（stdout；`-o` 只影响 DOT 文件路径，与本判据无关）。"""
    _clean_cache()
    out = tempfile.mktemp(suffix=".cir")
    r = _run(["cir", src_path, "-o", out] + list(extra or []))
    try:
        os.unlink(out)
    except FileNotFoundError:
        pass
    return r


def _func_section(text: str, fn: str) -> str:
    lines = text.splitlines()
    out, on = [], False
    for ln in lines:
        if ln.startswith("Function: "):
            on = ln.strip() == "Function: " + fn
            continue
        if on:
            out.append(ln)
    return "\n".join(out)


def _params(text: str):
    """解析 `PARAM <fn> p<i> <name> slot=<ti> decl=<tv>` ⇒ {fn: {i: (name, slot, decl)}}"""
    res = {}
    for ln in text.splitlines():
        if not ln.startswith("PARAM "):
            continue
        parts = ln.split()
        if len(parts) < 6 or not parts[2].startswith("p") or not parts[4].startswith("slot="):
            continue
        fn = parts[1]
        idx = int(parts[2][1:])
        res.setdefault(fn, {})[idx] = (
            parts[3],
            int(parts[4].split("=")[1]),
            int(parts[5].split("=")[1]),
        )
    return res


def _sha(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def _build(src: str, out: str, extra=None):
    _clean_cache()
    return _run(["build", src, "--static", "-o", out] + list(extra or []))


def _interp_rc(src_path: str) -> int:
    """`corec run <内联源>` 的 rc（= main 返回值低 8 位 / 255 = 能力边界）。"""
    _clean_cache()
    code = Path(src_path).read_text()
    return _run(["run", code]).returncode


def main() -> int:
    _no_core_dump()
    fails = []

    def check(cond: bool, msg: str):
        if cond:
            print("PASS " + msg)
        else:
            print("FAIL " + msg)
            fails.append(msg)

    tmp = []

    # ── C1/C2：值判据（bits 三态 / scaled 两腿严格）──────────────────────────────
    for name, probe, want_elf, want_interp, ctrl_code in (
        # **顺序敏感（M-δ 实测）**：被测调用必须排在正控**之前**——否则正控的 bits→scaled
        # 转换会把 7000000 留在某个 GP 寄存器里，失配的被测读点**靠寄存器残留**读到正确值
        # ⇒ 值判据假绿（「只回退 A2a」突变实测：正控在前 ⇒ C1 绿；被测在前 ⇒ C1 红）。
        ("C1 values_bits", PROBE_VALUES_BITS, 0, 255, 11),
        ("C2 values_scaled", PROBE_VALUES_SCALED, 0, 0, 31),
    ):
        src = _write(probe)
        tmp.append(src)
        elf = src[:-3]
        chk = _run(["check", src])
        check(chk.returncode == 0 and "error[" not in chk.stdout, name + " · check rc=0 且零诊断")
        b = _build(src, elf)
        check(b.returncode == 0, name + " · build rc=0")
        rc_elf = subprocess.run([elf], capture_output=True, text=True).returncode
        if rc_elf == ctrl_code:
            check(False, name + " · **判据无效**：正控（非泛型 dex 形参）失败 rc=%d ⇒ 探针本身不可信" % ctrl_code)
        else:
            check(rc_elf == want_elf, name + " · ELF rc=%d（期望 %d；RED 基线 21/41）" % (rc_elf, want_elf))
        rc_i = _interp_rc(src)
        if name.startswith("C1"):
            check(rc_i == want_interp, name + " · interp rc=%d（bits 源 255 = 能力边界 = 期望值；第三值判红）" % rc_i)
        else:
            check(rc_i == want_interp, name + " · interp rc=%d（scaled 源两腿严格）" % rc_i)

    # ── C3/C4：槽型直读 + 调用点机械判据 ────────────────────────────────────────
    src_forms = _write(PROBE_FORMS)
    tmp.append(src_forms)
    dump = _cir_dump(src_forms, extra=["--dump-params"])
    check(dump.returncode == 0, "C3/C4 · cir rc=0")
    text = dump.stdout
    ps = _params(text)
    check(ps.get("h", {}).get(0) == ("x", 8, 1), "C3 · 非泛型 dex 形参 slot=8 decl=1（既有行为不变）")
    check(ps.get("g1[dex]", {}).get(0) == ("x", 8, 1), "C3 · T 形态实例 g1[dex] slot=8 decl=1（RED 基线 slot=0）")
    check(ps.get("g2[dex]", {}).get(0) == ("x", 8, 0), "C3 · T? 形态实例 g2[dex] slot=8 decl=0（靠类型节点代入）")
    check(ps.get("gi[int]", {}).get(0) == ("x", 0, 0), "C3 · int 实例 gi[int] slot=0（非 dex 不变）")

    main_sec = _func_section(text, "main")
    check("call g1[dex](_dxsc)" in main_sec, "C4 · bits 实参：call g1[dex](_dxsc)（转换在场）")
    check("call g1[dex](e)" in main_sec, "C4 · scaled 实参：call g1[dex](e)（无需转换，第一遍不空转）")
    check("call g2[dex](_dxsc)" in main_sec, "C4 · T? 形态：call g2[dex](_dxsc)")
    check(("gi[int](" in main_sec) and ("gi[int](_dxsc" not in main_sec), "C4 · int 实例调用无转换")
    n_conv = main_sec.count("dest=_dxsc")
    check(n_conv == 3, "C4 · main 内 dest=_dxsc 计 %d（期望 3 = h + g1[dex]bits + g2[dex]bits）" % n_conv)

    # ── C5：幂等/不重复转换（bits 恰 2 / scaled 恰 0）───────────────────────────
    for name, probe, want in (
        ("C5 mixed_bits", PROBE_MIXED_BITS, 2),
        ("C5 mixed_scaled", PROBE_MIXED_SCALED, 0),
    ):
        src = _write(probe)
        tmp.append(src)
        d = _cir_dump(src)
        sec = _func_section(d.stdout, "main")
        got = sec.count("dest=_dxsc")
        check(got == want, "%s · dest=_dxsc 计 %d（期望 %d；4 = 两遍各转一次 = 红）" % (name, got, want))

    # ── C6：rc 中性 + 零产物（带/不带 --dump-params）────────────────────────────
    elf_a, elf_b = tempfile.mktemp(), tempfile.mktemp()
    ccr_a, ccr_b = elf_a + ".ccr", elf_b + ".ccr"
    b1 = _build(src_forms, elf_a)
    b2 = _build(src_forms, elf_b, extra=["--dump-params"])
    check(b1.returncode == b2.returncode == 0, "C6 · 两态 build rc=0")
    check(_sha(elf_a) == _sha(elf_b), "C6 · ELF 逐字节相同（--dump-params rc 中性 + 零产物）")
    check(_sha(ccr_a) == _sha(ccr_b), "C6 · .ccr 逐字节相同")
    r1 = subprocess.run([elf_a], capture_output=True).returncode
    r2 = subprocess.run([elf_b], capture_output=True).returncode
    # 本探针 main 返回 a+b+c+f+k = 5（五个 1）——断言「两态相同」+ 锚定值 5（防两态一致地错）
    check(r1 == r2 and r1 == 5, "C6 · 两态运行 rc 相同且 == 5（锚定值；实得 %d/%d）" % (r1, r2))

    for p in tmp + [elf_a, elf_b, ccr_a, ccr_b] + [t[:-3] for t in tmp]:
        try:
            os.unlink(p)
        except FileNotFoundError:
            pass

    print("")
    if fails:
        print("FAILED %d 项：%s" % (len(fails), "; ".join(fails)))
        return 1
    print("ALL PASS (C1–C7)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
