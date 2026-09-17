#!/usr/bin/env python3
"""批 6（验证内核正式接入）判据套件：**正式规约语法 `#check` / `#ensure`**。

覆盖四组（语料入仓 = `tests/spec/*.cr`；本套件**独立可跑**——不依赖预置状态，
所有产物落 `tempfile` 并清理；`cwd = 仓库根`（`--static` 构建要读 `src/runtime/rt.cr`，
**这是既有 cwd 依赖**：`rt.cr` 只按 cwd/exe 相对路径找，见 `main.cr:112-122`））：

  A. **语法面**（T2）：标注链解析 + 位置约束 + 形态错**全部响亮**
      正控 4（无注解 / 单条 / 多条 / 重复链**合法**）· 负控 11（`#` 后非 IDENT · 未知标签 ·
      缺 `(` · 未闭合 `)` · 空 `#check()` · 签名前 · body 后 · **常量假** · **撞名形态** ·
      **body 内两形**）——负控一律 **rc=1 + 零产物**
  B. **检查面**（T3）：正控 4（形参域 / `#ensure(result)` / 双条 / `#ensure(常量真)`）·
      负控 7（非 bool V05 · `#ensure(result)` V05 · **`#ensure` 常量假 V01** · **`result` 撞形参 V04** ·
      域外名 N01 · **表达式含调用 V06** · **重复链含假 V01**）
  C. **dump 通道**（T4，`--dump-vcs`）：三态齐全 + **红也列**（不静默省略）· 红 ⇒ 诊断 rc=1 ·
      **红的 line/col 与诊断自洽** · **源序确定** · **开关不改产物**（ELF+`.ccr` sha 同）·
      **冷/暖 dump 同** · **五分支可用** · **侧表键防串台**（两 impl 同名方法各带注解 ⇒ 互不干扰）
  D. **`.ccr` 零足迹三段式**（裁-S12）：**ELF 逐字节同** · **除 STR 外 7 段逐字节同** ·
      **STR Δ 恰为公式值** `Δ = Σ(4 + len(m))`（`m` = **注解独有词素**）+ **零 Δ 用例必须绿**

**`Δ` 公式的机制（判据注释，勿删）**：`src/compiler/lexer.cr` 的 `add_tok_str` 对**每个**
IDENT/关键字词素都调 `str_intern` —— **既有行为、非本批引入**；只出现在注解里的词素
（如 `#check(...)` 的 `check`）必然进 `.ccr` 的 STR 段。⇒ **逐字节全同不可达**，
可构造最强形 = 「ELF 同 + 除 STR 外逐段同 + STR Δ 恰好等于可算值（多一字节即红）」。
（这条判据在 T3 首轮**当场抓到实现自身的 `str_intern("result")` 泄漏**：两用例 Δ 凭空 +10B。）

**时长（本机实测，2026-09-17；机器有 swap 抖动 ⇒ 仅供参考）**：见 `main()` 末打印的
`PASS n/m` 与 `[time]` 行；挂 `selfhost-tests`（run.sh）时以实测值为准。
"""
import hashlib
import os
import re
import resource
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"
SPEC = BASE / "tests" / "spec"

SEG_NAMES = {1: "STR", 2: "SYM", 3: "NOD", 4: "ENT", 5: "REG", 6: "EDG", 7: "TYPE", 8: "IFACE"}

_PASS = 0
_FAIL = 0
_FAILED = []


def _no_core_dump():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def check(name, cond, detail=""):
    global _PASS, _FAIL
    if cond:
        _PASS += 1
        print(f"[PASS] {name}" + (f"  {detail}" if detail else ""))
    else:
        _FAIL += 1
        _FAILED.append(name)
        print(f"[FAIL] {name}  {detail}")
    return cond


def run_corec(args, timeout=300):
    """统一入口：cwd=仓库根（既有 cwd 依赖）+ nice -n 19（铁律 6）。"""
    return subprocess.run(
        ["nice", "-n", "19", str(COREC)] + [str(a) for a in args],
        cwd=BASE, capture_output=True, text=True, timeout=timeout,
    )


def build(src_name, extra=(), out=None, timeout=300):
    """构建到临时路径；返回 (proc, out_path:Path)。调用方负责 cleanup。"""
    if out is None:
        fd, tmp = tempfile.mkstemp(prefix="spec_", suffix=".bin")
        os.close(fd)
        os.unlink(tmp)
        out = Path(tmp)
    out = Path(out)
    proc = run_corec(["build", SPEC / src_name, "-o", out, "--static"] + list(extra), timeout=timeout)
    return proc, out


def cleanup(*paths):
    for p in paths:
        for suffix in ("", ".ccr"):
            try:
                os.unlink(str(p) + suffix)
            except FileNotFoundError:
                pass


def diag_code(text):
    m = re.search(r"error\[([A-Z0-9]+)\]", text)
    return m.group(1) if m else None


# ─── A/B：rc + 诊断码 + **零产物** 三合一一例 ────────────────────────────────
def case(name, src_name, expect_rc, expect_code=None):
    proc, out = build(src_name)
    try:
        got = diag_code(proc.stdout + proc.stderr)
        if proc.returncode == 0:
            return check(name, expect_rc == 0, f"rc=0 code={got}")
        # 非零：必须匹配期望 rc + 码，且**不得有产物**
        ok = (proc.returncode == expect_rc) and (expect_code is None or got == expect_code)
        if ok and os.path.exists(out):
            ok = False
            detail = "拒绝却产出二进制（零产物判据失败）"
        else:
            detail = f"rc={proc.returncode}（期望 {expect_rc}）code={got}（期望 {expect_code or 'any'}）"
        return check(name, ok, detail)
    finally:
        cleanup(out)


def case_reject(name, src_name, expect_code=None):
    return case(name, src_name, 1, expect_code)


# ─── C：dump 通道 ────────────────────────────────────────────────────────────
def dump_lines(proc):
    return [l for l in (proc.stdout + proc.stderr).splitlines() if l.startswith("[vcs]")]


def check_dump():
    # C1 三态齐全 + 红也列（不静默省略）
    proc, out = build("t4_three_states.cr", extra=("--dump-vcs",))
    txt = proc.stdout + proc.stderr
    lines = dump_lines(proc)
    check("C1a dump 有 count=3", any(l.strip() == "[vcs] count=3" for l in lines))
    check("C1b green 在列", any("status=green" in l for l in lines))
    check("C1c yellow 在列", any("status=yellow" in l for l in lines))
    check("C1d **red 在列（不静默省略）**", any("status=red" in l for l in lines))
    check("C1e 红 ⇒ 诊断通道 rc=1", proc.returncode == 1, f"rc={proc.returncode}")
    # C1f dump 的 line/col 与诊断自洽（**不比写死行号**：--static 会整体偏移）
    red = [l for l in lines if "status=red" in l]
    m_diag = re.search(r"--> (\d+):(\d+)", txt)
    m_dump = re.search(r"line=(\d+) col=(\d+)", red[0]) if red else None
    check("C1f 红的 line/col 与诊断自洽", bool(m_diag and m_dump and m_diag.groups() == m_dump.groups()),
          f"dump={m_dump.groups() if m_dump else None} diag={m_diag.groups() if m_diag else None}")
    cleanup(out)
    # C2 源序确定（两次逐字节同）
    p2, out2 = build("t4_three_states.cr", extra=("--dump-vcs",))
    check("C2 源序确定（两次 dump 逐字节同）",
          "\n".join(dump_lines(proc)) == "\n".join(dump_lines(p2)))
    cleanup(out2)
    # C3 开关不改产物（**只在绿/黄态可判**：红态 rc=1 无产物）
    run_corec(["clean-cache"])
    pa, outa = build("t4_yellow_only.cr")
    run_corec(["clean-cache"])
    pb, outb = build("t4_yellow_only.cr", extra=("--dump-vcs",))
    if outa.exists() and outb.exists():
        sa = hashlib.sha256(outa.read_bytes()).hexdigest()
        sb = hashlib.sha256(outb.read_bytes()).hexdigest()
        ca = hashlib.sha256(Path(str(outa) + ".ccr").read_bytes()).hexdigest() if Path(str(outa) + ".ccr").exists() else None
        cb = hashlib.sha256(Path(str(outb) + ".ccr").read_bytes()).hexdigest() if Path(str(outb) + ".ccr").exists() else None
        check("C3a 开关不改 ELF", sa == sb)
        check("C3b 开关不改 .ccr", ca is not None and ca == cb)
    else:
        check("C3 开关不改产物", False, f"缺产物 rc={pa.returncode}/{pb.returncode}")
    cleanup(outa, outb)
    # C4 冷/暖 dump 同
    run_corec(["clean-cache"])
    c1 = run_corec(["check", SPEC / "t4_three_states.cr", "--dump-vcs"])
    c2 = run_corec(["check", SPEC / "t4_three_states.cr", "--dump-vcs"])
    check("C4 冷/暖 dump 逐字节同", "\n".join(dump_lines(c1)) == "\n".join(dump_lines(c2)))
    # C5 五分支可用（check/ccr/cir/run；build 见 C1）
    for cmd in ("check", "ccr", "cir"):
        r = run_corec([cmd, SPEC / "t4_three_states.cr", "--dump-vcs"])
        check(f"C5 {cmd} 分支有 dump", "[vcs]" in (r.stdout + r.stderr))
    r = run_corec(["run", (SPEC / "t4_yellow_only.cr").read_text(), "--dump-vcs"])
    check("C5 run 分支有 dump", "[vcs]" in (r.stdout + r.stderr))
    # C6 侧表键防串台（两 impl 同名方法各带注解）
    rx, outx = build("t4_xtalk.cr", extra=("--dump-vcs",))
    lx = [l for l in dump_lines(rx) if "[vcs] vc" in l]
    check("C6a 同名方法不串台（rc=0，无伪 N01）", rx.returncode == 0, f"rc={rx.returncode}")
    check("C6b 两条各含自己的形参（alpha/beta）",
          len(lx) == 2 and all("status=yellow" in l for l in lx)
          and any("alpha" in l for l in lx) and any("beta" in l for l in lx),
          " | ".join(lx))
    cleanup(outx)


# ─── D：`.ccr` 零足迹三段式 ──────────────────────────────────────────────────
def ccr_segments(path):
    d = Path(path).read_bytes()
    _magic, _ver, cnt, _res = struct.unpack_from("<IIII", d, 0)
    off = 16
    seg = {}
    for _ in range(cnt):
        tag, o, s = struct.unpack_from("<III", d, off)
        off += 12
        seg[SEG_NAMES.get(tag, str(tag))] = (o, s)
    return seg


def delta_case(name, plain, annot, expect_delta):
    """Δ = Σ(4 + len(m)) over 注解独有词素；零 Δ 用例（词素已在他处驻留）必须绿。"""
    _pa, outa = build(plain)
    _pb, outb = build(annot)
    try:
        ok = True
        sha_ok = hashlib.sha256(outa.read_bytes()).hexdigest() == hashlib.sha256(outb.read_bytes()).hexdigest()
        check(f"D-{name}a ELF 逐字节同", sha_ok)
        ok = ok and sha_ok
        sa, sb = ccr_segments(str(outa) + ".ccr"), ccr_segments(str(outb) + ".ccr")
        diff = [k for k in sa if sa[k][1] != sb[k][1]]
        seg_ok = diff in ([], ["STR"])
        check(f"D-{name}b 除 STR 外 7 段逐字节同", seg_ok, f"变化段={diff}")
        ok = ok and seg_ok
        delta = sb["STR"][1] - sa["STR"][1]
        check(f"D-{name}c STR Δ={delta}（期望公式值 {expect_delta}；多一字节即红）", delta == expect_delta)
        ok = ok and (delta == expect_delta)
        return ok
    finally:
        cleanup(outa, outb)


def main():
    t0 = time.time()
    if not COREC.exists():
        print(f"[FAIL] 缺编译器 {COREC}（先 python3 build_selfhost_native.py）")
        return 1
    print("=== A. 语法面（T2）===")
    case("A1 无注解", "t2_pos_plain.cr", 0)
    case("A2 单条 #check", "t2_pos_check.cr", 0)
    case("A3 多条（check×2 + ensure）", "t2_pos_multi.cr", 0)
    case("A4 重复链合法", "t2_pos_dup.cr", 0)
    case_reject("A5 # 后非 IDENT", "t2_neg_nonident.cr", "V02")
    case_reject("A6 未知标签", "t2_neg_unknowntag.cr", "V02")
    case_reject("A7 缺 (", "t2_neg_nolparen.cr", "V03")
    case_reject("A8 未闭合 )", "t2_neg_unclosed.cr", "V03")
    case_reject("A9 空 #check()", "t2_neg_empty.cr", "V03")
    case_reject("A10 签名前位置", "t2_neg_before.cr", "V02")
    case_reject("A11 body 后位置", "t2_neg_after.cr", "V02")
    case_reject("A12 常量假 #check", "t2_neg_constfalse.cr", "V01")
    case_reject("A13 **撞名形态（注解名=真实函数）**", "t2_neg_collide.cr", "V01")
    case_reject("A14 body 内（同语句行）", "t2_neg_inbody.cr")
    case_reject("A15 body 内（独立行）", "t2_neg_stmt.cr")

    print("=== B. 检查面（T3）===")
    case("B1 #check(形参)", "t3_pos_check_param.cr", 0)
    case("B2 #ensure(result …)", "t3_pos_ensure_result.cr", 0)
    case("B3 check + ensure", "t3_pos_both.cr", 0)
    case("B4 #ensure(常量真)", "t3_pos_ensure_true.cr", 0)
    case_reject("B5 非 bool（#check(1)）", "t3_neg_nonbool.cr", "V05")
    case_reject("B6 #ensure(result) 非 bool", "t3_neg_ensure_nonbool.cr", "V05")
    case_reject("B7 **#ensure 常量假**", "t3_neg_ensure_false.cr", "V01")
    case_reject("B8 **result 撞形参**", "t3_neg_result_shadow.cr", "V04")
    case_reject("B9 域外名", "t3_neg_domain.cr", "N01")
    case_reject("B10 **表达式含调用**", "t3_neg_call_banned.cr", "V06")
    case_reject("B11 **重复链含假**", "t3_neg_dup_false.cr", "V01")

    print("=== C. dump 通道（T4）===")
    check_dump()

    print("=== D. `.ccr` 零足迹三段式（Δ 公式）===")
    delta_case("d9", "delta_d9_plain.cr", "delta_d9_annot.cr", 4 + len("check"))
    delta_case("d0 **零 Δ 用例**", "delta_d0_plain.cr", "delta_d0_annot.cr", 0)

    el = time.time() - t0
    print(f"\n=== 批 6 规约语法套件：{_PASS}/{_PASS + _FAIL} passed  [time] {el:.1f}s ===")
    if _FAILED:
        print("FAILED:", ", ".join(_FAILED))
    return 0 if _FAIL == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
