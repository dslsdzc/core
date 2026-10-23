#!/usr/bin/env python3
"""#2026-09-15-5 批 T3：暖缓存「定路径探针语料」两态回归（语料入仓 = `tests/probes/warm/`）。

**本设计的要点 = 定路径**：同一用例的两次编译必须用**同一路径**。套件既有用例把源写到唯一
temp 路径 ⇒ 缓存键（源路径::函数名）唯一 ⇒ **结构性无暖态** ⇒ 腿恒绿而空洞（T1 方法学发现）。
故本套件**直接编译入仓语料**（路径固定、跨运行跨机器恒定），冷 = `clean-cache` 后首跑，
暖 = 紧接二跑。**语料只增不减**。

缺陷（T1 实锤，`/tmp/fct4/task1-report.md`）：缓存命中跳过 `ir_gen_func` ⇒ ir_gen 期
`alloc_type` 出的类型行（`TYP_PTR extra=1` 等）不重建 ⇒ 读行内容的判定静默失效
（首例 = `provenance_verify.cr:66` 的 TU03「外部指针解引用需 unsafe」）。
修法（裁-W1 = (b) 先行，**共享面副作用见证**）：生成期对「快照不载的共享面」有副作用 ⇒
**本条目不可写** ⇒ 下次必 miss 重放全部副作用（见 `main.cr` miss 分支）。

判据（逐条对应语料文件，期望值表见 `tests/probes/warm/README.md`）：
  ① **缺陷面**：`tu03_load` / `tu03_store` —— 冷/暖**都** rc=1 + TU03（`ccr` 面）；
  ② **缺陷面（`build` 面同判）**：`tu03_load` 冷/暖都 rc=1 + TU03（`--static`）；
  ③ **机制钉**：`alloc_witness`（数组字面量 + 取址 ⇒ 生成期分配复合行）**无自己的条目**
     （`::main.cir` 缺席 = 见证生效）；同批 `plain`（普通程序）**有** ⇒ 抑制是**选择性**的；
  ④ **正控（命中不退化）**：`plain` 二跑**真命中**（条目 size/mtime 不变）——防「腿恒绿」；
  ⑤ **旁面不回归**：`tk01_oob_load` / `tk01_oob_store` / `tk01_width` 冷/暖都 rc=1 + TK01。
"""
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

BASE = Path(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
COREC = BASE / "build" / "corec"
CACHE = BASE / ".core/cache/cir"
CORPUS = BASE / "tests" / "probes" / "warm"
TMP = Path(tempfile.mkdtemp(prefix="warm_gate_"))
npass = nfail = 0


def _nc():
    import resource
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def cc(args, timeout=180):
    return subprocess.run([str(COREC)] + args, cwd=BASE, capture_output=True,
                          text=True, timeout=timeout, preexec_fn=_nc)


def codes(txt):
    return sorted(set(re.findall(r"error\[([A-Z0-9]+)\]", txt)))


def ok(name, cond, detail=""):
    global npass, nfail
    print(("[PASS] " if cond else "[FAIL] ") + name + (" " + detail if detail else ""))
    if cond:
        npass += 1
    else:
        nfail += 1


def src(name):
    """入仓语料路径（**定路径**——不得复制到 temp）。"""
    p = CORPUS / f"{name}.cr"
    assert p.is_file(), f"语料缺失（只增不减）: {p}"
    return p


def cold_warm(name, mode="ccr"):
    """同一入仓路径冷（clean-cache 后首跑）→ 暖（紧接二跑）；返回两态 (rc, codes)。"""
    p = src(name)
    cc(["clean-cache"])
    if mode == "build":
        a = cc(["build", str(p), "-o", str(TMP / "o1.bin"), "--static"])
        b = cc(["build", str(p), "-o", str(TMP / "o2.bin"), "--static"])
    else:
        a = cc(["ccr", str(p), "-o", str(TMP / "o1.ccr")])
        b = cc(["ccr", str(p), "-o", str(TMP / "o2.ccr")])
    return (a.returncode, codes(a.stdout + a.stderr)), (b.returncode, codes(b.stdout + b.stderr))


def entries():
    return sorted(p.name for p in CACHE.glob("*.cir")) if CACHE.exists() else []


# ── 语料清点（非空洞：7 档必须在位；签名面 = 期望值表在 README） ──
WARM_FILES = ["tu03_load", "tu03_store", "tk01_oob_load", "tk01_oob_store",
              "tk01_width", "plain", "alloc_witness"]
ok("corpus_present", all((CORPUS / f"{n}.cr").is_file() for n in WARM_FILES),
   f"{CORPUS} 档数={len(list(CORPUS.glob('*.cr')))}（期望 ≥{len(WARM_FILES)}）")

# ① 缺陷面：外部指针解引用（load/store）——冷/暖必须一致（修复前：暖 rc=0 静默）
for nm in ("tu03_load", "tu03_store"):
    c, w = cold_warm(nm)
    ok(f"defect_{nm}_cold_warm_same", c == w and c[0] == 1 and "TU03" in c[1], f"冷={c} 暖={w}")

# ② build 面同判（两面同病 ⇒ 两面同修）
c, w = cold_warm("tu03_load", mode="build")
ok("defect_tu03_build_face_cold_warm_same", c == w and c[0] == 1 and "TU03" in c[1], f"冷={c} 暖={w}")

# ③ 机制钉：生成期分配共享行的函数无自己的条目；同批普通程序有（选择性）
cc(["clean-cache"])
cc(["ccr", str(src("alloc_witness")), "-o", str(TMP / "w.ccr")])
e_wit = entries()
cc(["clean-cache"])
cc(["ccr", str(src("plain")), "-o", str(TMP / "p.ccr")])
e_plain = entries()
ok("witness_no_own_entry", e_wit and not any(e.endswith("alloc_witness.cr::main.cir") for e in e_wit),
   f"alloc_witness 条目={len(e_wit)} · 含自档 main={any(e.endswith('alloc_witness.cr::main.cir') for e in e_wit)}")
ok("witness_selective_control_has_entry",
   any(e.endswith("plain.cr::main.cir") for e in e_plain),
   f"plain 条目={len(e_plain)}（期望含 plain.cr::main.cir）")

# ④ 正控：普通程序二跑真命中（条目 size/mtime 不变）
pe = [p for p in CACHE.glob("*plain.cr::main.cir")]
if pe:
    st1 = pe[0].stat()
    cc(["ccr", str(src("plain")), "-o", str(TMP / "p2.ccr")])
    st2 = pe[0].stat()
    ok("positive_control_true_hit",
       st1.st_size == st2.st_size and int(st1.st_mtime) == int(st2.st_mtime),
       f"条目={pe[0].name} {st1.st_size}B mtime {int(st1.st_mtime)}→{int(st2.st_mtime)}")
else:
    ok("positive_control_true_hit", False, "普通程序未产生 plain.cr::main.cir 条目")

# ⑤ 旁面不回归：TK01（指针越界/宽度）
for nm in ("tk01_oob_load", "tk01_oob_store", "tk01_width"):
    c, w = cold_warm(nm)
    ok(f"tk01_{nm}_cold_warm_same", c == w and c[0] == 1 and "TK01" in c[1], f"冷={c} 暖={w}")

print(f"{npass}/{npass + nfail} passed")
import shutil
shutil.rmtree(TMP, ignore_errors=True)
sys.exit(0 if nfail == 0 else 1)
