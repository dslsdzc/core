#!/usr/bin/env python3
"""fail-closed 判据线（FC 批 T2）：闸门反转 = 默认阻断 + 豁免登记表。

判据面（源 = `src/compiler/diag.cr::diag_gate_exempt`；消费点 = `main.cr` 的硬判定循环）：
  · 正控（8）：表内 **5** 条 build 面豁免码（TF07/TB01/TM04/TK01/B04）⇒ 仍放行（build rc=0 + 产物）；
    **TF07/TB01 的夹具于 2026-09-19（(i) 小批）更换**：原 `ptr_ref_first.cr` 因 `@raw_int` 放宽接受指针而
    **不再产这两个码** ⇒ 改用仍被拒的串实参级联夹具（同形），原夹具另钉「放宽后干净通过」
    （**拆两条**：`check` 面断言**无** TF07/TB01 + `build` 面 `build_ok` —— 仅 build 面**恒过**，
    因 TF07 是 build-scope 豁免码；见该处注释）；
    **TF01 已于 2026-09-18（批 8 A₂）撤条**——原「chan_test 产 TF01 且被豁免」的**正控改为**：
    ① 根因正控 = 5 档并发语料**干净构建**（rc=0 + 产物 + **无 TF01**）；② **负控** = 真 TF01（string 值返
    int 声明）**仍阻断**（rc=1 + 零产物）——即「撤条 ≠ 放行」。
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


# ── TF01（A₂ 撤条；2026-09-18）：根因正控 + 负控（「撤条 ≠ 放行」）────────────
clean()
_r = cc(["check", "tests/suite/chan_test.cr"])
t.ok("pos_tf01_root_fixed",
     _r.returncode == 0 and "error[TF01]" not in (_r.stdout + _r.stderr),
     f"check rc={_r.returncode} TF01={'error[TF01]' in (_r.stdout + _r.stderr)}")
build_ok("tf01_build_clean", "tests/suite/chan_test.cr")
# (i) 小批（2026-09-19）：`@raw_int` 放宽接受**指针** ⇒ **原夹具 ptr_ref_first.cr 不再产 TF07/TB01**。
# 本正控**换夹具、意图不变**（「build 面豁免码仍放行（rc=0 + 产物）**且仍被报出**」）：改用**仍被拒**的
# 串实参级联（2×TF07 → 两侧 TI_NEVER → 1×TB01，与旧夹具**同形**）；
# 原夹具另钉 (i) 的**新语义**——⚠ 拆成**两条**（照上方 tf01 先例，team-lead 2026-09-19 复核退回）：
#   · **`check` 面**断言**缺席**（`rc=0` 且无 TF07/TB01）——**只有 check 面有意义**：`check` 不在
#     build-scope 豁免内；**build 面 TF07 被豁免 ⇒ `build_ok`（rc=0 + 产物）无论如何都过**，
#     两条合起来才是「放宽后指针形态干净通过」这句话；
#   · **`build` 面**保留 `build_ok`（钉「能过 + 有产物」那一半）。
# 实测（本批基点）：级联夹具 check rc=1 · TF07×2 · TB01×1；build rc=0 · 产物 ✓ · TF07×2 · TB01×1。
build_ok("tf07_tb01", write("tf07_tb01_cascade",
                            'fn main() -> int { s := "a"; t := "b"; return @raw_int(s) - @raw_int(t); }\n'),
         ("TF07", "TB01"))
clean()
_r = cc(["check", "tests/suite/ptr_ref_first.cr"])
t.ok("pos_tf07_tb01_ptr_check_clean",
     _r.returncode == 0 and "error[TF07]" not in (_r.stdout + _r.stderr)
     and "error[TB01]" not in (_r.stdout + _r.stderr),
     f"check rc={_r.returncode} TF07={'error[TF07]' in (_r.stdout + _r.stderr)} "
     f"TB01={'error[TB01]' in (_r.stdout + _r.stderr)}")
build_ok("tf07_tb01_ptr_clean", "tests/suite/ptr_ref_first.cr")

# ── S2 钉子（2026-09-20）：`@raw_int` 门按「**只认地址型**」重写（PTR 与 REF 皆收）──────
# 背景：S1 把 `&x` 改判 `TYP_REF` ⇒ 原谓词（只认 `TYP_PTR`）把 `@raw_int(&x)` 判成 TF07
#   （实测：`ptr_ref_first.cr` 由 rc=0 转 rc=1）⇒ 与「`&x` 与 `&T` 同 kind」的裁定二目标冲突。
# **三向钉（缺一不算）**：正（`&x` 受）· 反（**四类各一颗**仍拒，断言到码）· 对照（int/dex 受）。
# ⚠ **面选 `check`**：TF07 在 **build scope 被豁免**（`diag.cr`）⇒ build 面恒 rc=0
#   ⇒ 反钉写在 build 面会**恒绿**（本仓「面 × 豁免表」纪律：负控须写 `check` 面 rc=1 + 含码）。
def neg_check(name, src_path, want_code):
    clean()
    r = cc(["check", str(src_path)])
    txt = r.stdout + r.stderr
    hit = f"error[{want_code}]" in txt
    t.ok(f"neg_{name}", r.returncode == 1 and hit,
         f"check rc={r.returncode} 含码={hit}")


# 正钉：`@raw_int(&x)`（**传 REF**）必须受 —— 这条是 S1 落地后转红、S2 修好的那一处
# ⚠ 探针形态：**直接把 `@raw_int(...)` 当返回值**（`int` 函数）。写成 `@raw_int(x) != 0` 会得到
#   `bool` ⇒ 与 `-> int` 冲突 ⇒ **TF01**（我第一版就这么写，三条正/对照钉全红——**是探针错，不是门错**）。
_s2_addr = write("s2_addr_ok",
                 "fn main() -> int {\n    x : ., mut = 7;\n    return @raw_int(&x);\n}\n")
clean()
_r = cc(["check", str(_s2_addr)])
t.ok("s2_raw_int_ref_accepted", _r.returncode == 0,
     f"check rc={_r.returncode}（正钉：地址型 = PTR ∪ REF ⇒ REF 必须受）")

# 反钉（防漏放）：**四类各一颗**，逐类断言 `error[TF07]` + rc=1（不是只断 rc）
neg_check("s2_raw_int_string", write("s2_str", 'fn main() -> int { s := "a"; return @raw_int(s); }\n'), "TF07")
neg_check("s2_raw_int_bool", write("s2_bool", "fn main() -> int { b := true; return @raw_int(b); }\n"), "TF07")
neg_check("s2_raw_int_array", write("s2_arr", "fn main() -> int { a := [1, 2, 3]; return @raw_int(a); }\n"), "TF07")
neg_check("s2_raw_int_slice", write("s2_slice", "fn main() -> int { a := [1, 2, 3]; s := a[0..2]; return @raw_int(s); }\n"), "TF07")

# 对照钉（防「一律放」）：int / dex 仍受
_s2_int = write("s2_int_ok", "fn main() -> int { n := 5; return @raw_int(n); }\n")
clean()
_r = cc(["check", str(_s2_int)])
t.ok("s2_raw_int_int_ok", _r.returncode == 0, f"check rc={_r.returncode}")
_s2_dex = write("s2_dex_ok", 'fn main() -> int { d : dex, apx = 7.0; return @raw_int(d); }\n')
clean()
_r = cc(["check", str(_s2_dex)])
t.ok("s2_raw_int_dex_ok", _r.returncode == 0, f"check rc={_r.returncode}")
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
# TF01 撤条后的**负控**（A₂）：真 TF01（string 值返 int 声明）⇒ 仍阻断（rc=1 + 零产物）——「撤条 ≠ 放行」
neg("type_tf01", write("tf01", 'fn main() -> int {\n    s := "x";\n    return s;\n}\n'), "TF01")

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
