#!/usr/bin/env python3
"""fail-closed 判据线（FC 批 T2）：闸门反转 = 默认阻断 + 豁免登记表。

判据面（源 = `src/compiler/diag.cr::diag_gate_exempt`；消费点 = `main.cr` 的硬判定循环）：
  · 正控（9）：表内 6 条 build 面豁免码（TF01/TF07/TB01/TM04/TK01/B04）⇒ 仍放行（build rc=0 + 产物）；
    `scope=check` 3 条（N01/N06/N11）⇒ **check 面 rc=1 不变**（(C) 终局：本表对 check 面惰性）。
  · 负控（6）：三类面各覆盖——语法面 P21 · 类型面 TA02/R002/TM03/TK05 · 安全检查面 TU03
    ⇒ 仍阻断（rc=1 **且零产物**）。
  · 零产物（3）：前端失败无半成品 · corearch 失败删**本次** `.ccr`（stub corearch 仿真）·
    既有旧哨兵（ELF/.ccr）在失败后**原样仍在**（裁-FC-6：只删本次写下者）。

注：安全面用例（TU03）须 `clean-cache` 后测——`.cir` 暖缓存下该诊断会消失（**预存缺陷**，
另案登记，与本套件判据无关）。用例只增不减。
"""
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

BASE = Path(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
COREC = BASE / "build" / "corec"
TMP = Path(tempfile.mkdtemp(prefix="diag_gate_"))


def _no_core_dump():
    import resource
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def cc(args, ccbin=None, timeout=180):
    return subprocess.run([str(ccbin or COREC)] + args, cwd=BASE, capture_output=True,
                          text=True, timeout=timeout, preexec_fn=_no_core_dump)


def clean():
    cc(["clean-cache"])


def write(name, src):
    p = TMP / f"{name}.cr"
    p.write_text(src)
    return p


class Tally:
    def __init__(self):
        self.pass_ = 0
        self.fail = 0

    def ok(self, name, cond, detail=""):
        if cond:
            print(f"[PASS] {name} {detail}")
            self.pass_ += 1
        else:
            print(f"[FAIL] {name} {detail}")
            self.fail += 1


t = Tally()

# ── 正控 1-6：build 面豁免码仍放行 ──────────────────────────────────────
def build_ok(name, src_path, want_codes=()):
    out = TMP / f"{name}.bin"
    for f in (out, Path(str(out) + ".ccr")):
        if f.exists():
            f.unlink()
    clean()
    r = cc(["build", str(src_path), "-o", str(out), "--static"])
    txt = r.stdout + r.stderr
    okc = all(f"error[{c}]" in txt for c in want_codes) if want_codes else True
    t.ok(f"pos_{name}", r.returncode == 0 and out.exists() and okc,
         f"rc={r.returncode} art={out.exists()} codes={[c for c in want_codes]}")


build_ok("tf01", "tests/suite/chan_test.cr", ("TF01",))
build_ok("tf07_tb01", "tests/suite/ptr_ref_first.cr", ("TF07", "TB01"))
tm04 = write("tm04", "enum Color { Red, Green, Blue }\n"
                     "fn main() -> int { c := Red(); "
                     "return match c { Red => 1, Red => 2, Green => 3, Blue => 4, }; }\n")
build_ok("tm04", tm04, ("TM04",))
tk01 = write("tk01", "\nfn main() -> int {\n    x := 5;\n    return x[0];\n}\n")
build_ok("tk01", tk01, ("TK01",))
build_ok("b04", "tests/suite/ptr_arith.cr")

# ── 正控 7-9：scope=check 三条 check 面不变（rc=1） ─────────────────────
for nm, f in (("n01", "src/stdlib/collections.cr"), ("n06", "src/stdlib/trace.cr"),
              ("n11", "src/stdlib/fmt.cr")):
    clean()
    r = cc(["check", f])
    t.ok(f"pos_scope_check_{nm}", r.returncode == 1, f"check rc={r.returncode}（不变）")

# ── 负控 1-6：三类面仍阻断 + 零产物 ─────────────────────────────────────
def neg(name, src_path, want_code):
    out = TMP / f"{name}.bin"
    for f in (out, Path(str(out) + ".ccr")):
        if f.exists():
            f.unlink()
    clean()
    r = cc(["build", str(src_path), "-o", str(out), "--static"])
    txt = r.stdout + r.stderr
    t.ok(f"neg_{name}",
         r.returncode == 1 and not out.exists() and not Path(str(out) + ".ccr").exists()
         and f"error[{want_code}]" in txt,
         f"rc={r.returncode} ELF={out.exists()} ccr={Path(str(out)+'.ccr').exists()}")


neg("syntax_p21", BASE / "tests/suite/at_test_mini4.cr", "P21")
neg("type_ta02", write("ta02", 'fn main() -> int {\n    x : int = "s";\n    return 0;\n}\n'), "TA02")
neg("type_r02", write("r02", "fn main() -> int {\n    arr := [1, 2, 3];\n    return arr[5];\n}\n"), "R02")
neg("type_tm03", write("tm03", "enum E { A, B }\nfn main() -> int { e := A(); "
                               "return match e { A => 1, }; }\n"), "TM03")
neg("type_tk05", write("tk05", "fn main() -> int {\n    arr := [1, 2, 3];\n"
                               "    s := arr[0..5];\n    return 0;\n}\n"), "TK05")
neg("safety_tu03", write("tu03", "fn main() -> int {\n    p := 4096 as *int;\n"
                                 "    return *p;\n}\n"), "TU03")

# ── 零产物 1：前端失败（P21）⇒ 无 ELF / 无 .ccr（并入 neg_syntax_p21 断言）──
# ── 零产物 2：corearch 失败（stub）⇒ 本次 .ccr 被删 ─────────────────────
sim = TMP / "sim"
(sim / "build").mkdir(parents=True, exist_ok=True)
shutil.copy(COREC, sim / "build" / "corec")
(sim / "build" / "corearch").write_text("#!/bin/sh\necho 'error: simulated backend failure' >&2\nexit 1\n")
(sim / "build" / "corearch").chmod(0o755)
ok_src = write("ok_src", "fn main() -> int { return 0; }\n")
out2 = TMP / "c2.bin"
for f in (out2, Path(str(out2) + ".ccr")):
    if f.exists():
        f.unlink()
clean()
r = cc(["build", str(ok_src), "-o", str(out2), "--static"], ccbin=sim / "build" / "corec")
t.ok("zero_corearch_fail_deletes_new_ccr",
     r.returncode == 1 and not out2.exists() and not Path(str(out2) + ".ccr").exists(),
     f"rc={r.returncode} ELF={out2.exists()} ccr={Path(str(out2)+'.ccr').exists()}")

# ── 零产物 3a/3b：既有旧哨兵在失败后原样仍在 ────────────────────────────
out3 = TMP / "c3.bin"
out3.write_text("SENTINEL-ELF")
Path(str(out3) + ".ccr").write_text("SENTINEL-CCR")
clean()
r = cc(["build", str(TMP / "ta02.cr"), "-o", str(out3), "--static"])
t.ok("zero_frontend_fail_keeps_sentinels",
     r.returncode == 1 and out3.read_text() == "SENTINEL-ELF"
     and Path(str(out3) + ".ccr").read_text() == "SENTINEL-CCR", f"rc={r.returncode}")

out4 = TMP / "c4.bin"
out4.write_text("SENTINEL-ELF2")
clean()
r = cc(["build", str(ok_src), "-o", str(out4), "--static"], ccbin=sim / "build" / "corec")
t.ok("zero_corearch_fail_keeps_old_elf_sentinel",
     r.returncode == 1 and out4.read_text() == "SENTINEL-ELF2", f"rc={r.returncode}")

print(f"{t.pass_}/{t.pass_ + t.fail} passed")
shutil.rmtree(TMP, ignore_errors=True)
sys.exit(0 if t.fail == 0 else 1)
