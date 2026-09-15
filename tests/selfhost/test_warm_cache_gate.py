#!/usr/bin/env python3
"""#60 批 T2：暖缓存「共享面副作用见证」回归（同路径重复编译 = 缺陷真触发场景）。

缺陷（T1 实锤，报告 /tmp/fct4/task1-report.md）：缓存命中跳过 `ir_gen_func` ⇒ **ir_gen 期
`alloc_type` 出的类型行（`TYP_PTR extra=1` 等）不重建** ⇒ 读行内容的判定静默失效
（首例 = `provenance_verify.cr:66` 的 TU03「外部指针解引用需 unsafe」）。
修法（裁-W1 = (b) 先行，**见证式一般化**）：生成期对「快照不载的共享面」有副作用 ⇒ **本条目
不可写**（下次必 miss = 重放全部副作用），见 `main.cr` 的 miss 分支。

判据：
  ① **缺陷面两态一致**：`as *int` + 解引用（load / store）**冷/暖同**（都 rc=1 + TU03）；
  ② **机制钉**：带副作用函数的缓存条目**不存在**（见证生效）；
  ③ **正控（命中不退化）**：普通程序的条目存在 + 二跑**真命中**（条目 size/mtime 不变）；
  ④ **旁面不回归**：TK01（指针越界/宽度）冷/暖同；
  ⑤ `ccr` 面与 `build` 面同判（两面同病 ⇒ 两面同修）。

**定路径是本设计的要点**：同一用例的两次编译必须用**同一路径**（否则缓存键唯一 ⇒ 结构性无暖态，
腿会恒绿而空洞——T1 方法学发现）。用例只增不减。
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


def write(name, src):
    p = TMP / f"{name}.cr"
    p.write_text(src)
    return p


def cold_warm(src, mode="build"):
    """同一路径冷（clean-cache 后首跑）→ 暖（紧接二跑）；返回两态 (rc, codes)。"""
    cc(["clean-cache"])
    if mode == "build":
        a = cc(["build", str(src), "-o", str(TMP / "o1.bin"), "--static"])
        b = cc(["build", str(src), "-o", str(TMP / "o2.bin"), "--static"])
    else:
        a = cc(["ccr", str(src), "-o", str(TMP / "o1.ccr")])
        b = cc(["ccr", str(src), "-o", str(TMP / "o2.ccr")])
    return (a.returncode, codes(a.stdout + a.stderr)), (b.returncode, codes(b.stdout + b.stderr))


# ① 缺陷面：外部指针解引用（load/store）——冷/暖必须一致（修复前：暖 rc=0 静默）
tu_load = write("tu03_load", "fn main() -> int {\n    p := 4096 as *int;\n    return *p;\n}\n")
tu_store = write("tu03_store", "fn main() -> int {\n    p := 4096 as *int;\n    *p = 1;\n    return 0;\n}\n")
for nm, src in (("tu03_load", tu_load), ("tu03_store", tu_store)):
    c, w = cold_warm(src)
    ok(f"defect_{nm}_cold_warm_same",
       c == w and c[0] == 1 and "TU03" in c[1],
       f"冷={c} 暖={w}")

# ② 机制钉：带共享面副作用的函数不得留有缓存条目（见证生效）
cc(["clean-cache"])
cc(["build", str(tu_load), "-o", str(TMP / "m.bin"), "--static"])
key = str(tu_load).replace("/", "_")
ents = [p for p in CACHE.glob("*.cir")] if CACHE.exists() else []
# 注：条目按**命令行源路径**命名（含 rt.cr/stdlib 的函数）⇒ 必须精确查到「该源的那一个函数」。
has_tu = [p for p in ents if p.name.endswith("tu03_load.cr::main.cir")]
has_plain_ctl = [p for p in ents if p.name.endswith("plain.cr::main.cir")]  # 同批对照（应存在）
ok("witness_no_entry_for_side_effect_fn", len(has_tu) == 0,
   f"tu03_load::main 条目={len(has_tu)}（期望 0；同批 plain::main 见正控）")

# ③ 正控：普通程序条目存在 + 二跑真命中（size/mtime 不变）
plain = write("plain", "fn main() -> int {\n    x := 1 + 2;\n    return x;\n}\n")
cc(["clean-cache"])
cc(["build", str(plain), "-o", str(TMP / "p1.bin"), "--static"])
pe = [p for p in CACHE.glob("*.cir") if "warm_gate_" in p.name and "plain" in p.name]
if pe:
    st1 = pe[0].stat()
    cc(["build", str(plain), "-o", str(TMP / "p2.bin"), "--static"])
    st2 = pe[0].stat()
    ok("positive_control_true_hit",
       st1.st_size == st2.st_size and int(st1.st_mtime) == int(st2.st_mtime),
       f"条目={pe[0].name} {st1.st_size}B mtime {int(st1.st_mtime)}→{int(st2.st_mtime)}")
else:
    ok("positive_control_true_hit", False, "普通程序未产生缓存条目")

# ④ 旁面不回归：TK01（指针越界/宽度）冷/暖同
tk = write("tk01_oob", "fn main() -> int {\n    arr := [1];\n    p := &arr[0] + 1;\n    return *p;\n}\n")
c, w = cold_warm(tk)
ok("tk01_cold_warm_same", c == w and "TK01" in c[1], f"冷={c} 暖={w}")

# ⑤ ccr 面同判
c, w = cold_warm(tu_load, mode="ccr")
ok("ccr_face_cold_warm_same", c == w and "TU03" in c[1], f"冷={c} 暖={w}")

print(f"{npass}/{npass + nfail} passed")
import shutil
shutil.rmtree(TMP, ignore_errors=True)
sys.exit(0 if nfail == 0 else 1)
