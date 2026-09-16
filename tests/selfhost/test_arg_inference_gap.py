#!/usr/bin/env python3
"""⚠ **RED 语料 —— 修复前预期失败；勿挂 CI**（TODO #93；详见
`docs/superpowers/specs/2026-09-16-arg-inference-gap.md`）。

被测缺陷 = **「已解析直调的实参推断缺失」**（不是「一个 139」）：

  `checker.cr` `infer_expr` 的 EXPR_CALL 直调分支在**被调解析成已注册 Core `fn`** 时
  **提前 `return sym_type(si)`（`:2817`）**，而「推实参（for side effects）」循环在
  **函数尾（`:2833-2839`）** ⇒ 该路径下**实参表达式从不被推断**（该循环只在 `func_ni < 0`
  时可达 ⇒ 对任何**有名**被调都是**死码**）。

两种表现（本套件**两条腿都要**，缺一即「只修了一半」）：
  · **腿 A（响亮面 = 139）**：实参位的内层调用若是 `EXPR_FIELD` 被调（方法调用 / 模块限定调用），
    其 `ast_data`（被调名索引）**只能由 checker 的模块/方法分支回填**（`checker.cr:2584`/`:2645`）
    —— 该分支从没跑 ⇒ 字段保持 parser 初值 **0** ⇒ `ir_gen` 读出 `istr_get(0)` = 文件**首个
    interned 串**（有 `import` 语句时恰为 `"import"`）⇒ 后端查不到 ⇒ 外部位重定位 ⇒ **SIGSEGV 139**。
  · **腿 B（静默面 = 零诊断）**：实参里的**未定义函数**（`g(nosuchfn(1))`）**静默通过**、
    `check` rc=0 —— 比 139 更危险（响亮失败至少有人看得见）。

**修好后本套件应当全绿**：腿 A 各例由 139 → 精确值；腿 B 由「零诊断」→ `error[N06]`。
⇒ **本文件的存在意义 = 把「修复的判据」先钉死**（照 TDD：先红后绿）。当前跑必然失败。

**为何未挂 CI**：见 `tests/harness/ci_hook_allowlist.txt` 的对应条目——它是 **RED 语料**，
修复落地前挂上去只会恒红。**修复批次落地时必须同时**：① 删该白名单条目 ② 在
`src/ci/run.sh` 挂本套件 ③ 本文件头注改为「已修」。

**通用探针纪律**（照 apx 批 §0bis/§0ter）：RED 语料也要写明**覆盖面自证**——本套件的
`OBSERVED` 列即覆盖面证据（见 `--report` 输出）。
"""

import os
import re
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"

# kind:
#   "crash"  = 腿 A：当前 139，修好后应当拿到 expect_rc
#   "silent" = 腿 B：当前零诊断，修好后 check 应当出 {N06}
#   "green"  = 对照：当前即应绿、修后不得变（防「修法把对的搞坏」）
CASES = [
    # ── 腿 A：响亮面（139）──
    ("A1_module_call_as_arg", "crash", 0, """
import fmt
fn main() -> int { if !str_eq(fmt.int_str(7), "7") { return 3; } return 0; }
"""),
    ("A2_two_module_calls_as_args", "crash", 0, """
import fmt
fn main() -> int { if !str_eq(fmt.int_str(7), fmt.int_str(7)) { return 3; } return 0; }
"""),
    ("A3_method_call_as_arg", "crash", 0, """
struct S { f: int }
impl S { fn m(self: S, x: int) -> int { return x + 1; } }
fn m_eq(a: int, b: int) -> int { if a == b { return 1; } return 0; }
fn main() -> int { s : ., mut = S { f = 0 }; if m_eq(s.m(6), 7) == 0 { return 3; } return 0; }
"""),
    ("A4_helper_one_module_call", "crash", 0, """
import fmt
fn one(a: string) -> int { if !str_eq(a, "7") { return 3; } return 0; }
fn main() -> int { return one(fmt.int_str(7)); }
"""),
    ("A5_helper_method_result", "crash", 0, """
struct P { v: int }
impl P { fn get(self: P) -> int { return self.v; } }
fn show(x: int) -> int { return x; }
fn main() -> int { p : ., mut = P { v = 7 }; return show(p.get()); }
"""),
    ("A6_three_arg_outer", "crash", 0, """
import fmt
fn str_neq_3(a: string, b: string, c: int) -> int { if !str_eq(a, b) { return 1; } return 0; }
fn main() -> int { b := str_neq_3(fmt.int_str(7), "7", 1); if !b { return 3; } return 0; }
"""),
    ("A7_module_call_arg_in_let", "crash", 0, """
import fmt
fn main() -> int { b := str_eq(fmt.int_str(7), "7"); if !b { return 3; } return 0; }
"""),
    ("A8_module_call_arg_in_if", "crash", 0, """
import fmt
fn main() -> int { if !str_eq(fmt.int_str(7), "7") { return 3; } return 0; }
"""),
    # ── 腿 B：静默面（零诊断）──
    # 注意：B1 当前**同时**是 check 零诊断（静默面）**且**运行时 139 —— 静默指的正是「无诊断」这一层。
    ("B1_undefined_fn_in_arg_of_resolved_call", "silent", None, """
fn g(x: int) -> int { return x; }
fn main() -> int { return g(nosuchfn(1)); }
"""),
    # ── 对照（当前即绿）──
    ("C1_binding_form", "green", 0, """
import fmt
fn main() -> int { x := fmt.int_str(7); if !str_eq(x, "7") { return 3; } return 0; }
"""),
    ("C2_binding_form_stmt", "green", 0, """
import fmt
fn main() -> int { x := fmt.int_str(7); return 0; }
"""),
    ("C3_module_outer_single_arg", "green", 0, """
import fmt
import io
fn main() -> int { println(fmt.int_str(7)); return 0; }
"""),
    ("C4_direct_nested", "green", 0, """
import fmt
fn main() -> int { if !str_eq(int_str(7), "7") { return 3; } return 0; }
"""),
    ("C5_generic_nested", "green", 0, """
fn idf[T](x: T) -> T { return x; }
fn ieq(a: int, b: int) -> int { if a == b { return 1; } return 0; }
fn main() -> int { if ieq(idf(7), 7) == 0 { return 3; } return 0; }
"""),
    ("C6_direct_in_if", "green", 0, """
import fmt
fn main() -> int { if !str_eq(int_str(7), "7") { return 3; } return 0; }
"""),
    ("C7_module_outer_infers_args", "silent_control", None, """
import fmt
fn main() -> int { x := fmt.int_str(nosuchfn(1)); return 0; }
"""),
    ("C8_position_independence_exact", "green", 7, """
fn seven() -> int { return 7; }
fn main() -> int { return seven(); }
"""),
    ("C9_method_outer_infers_args", "silent_control", None, """
struct S { f: int }
impl S { fn m2(self: S, x: int) -> int { return x; } }
fn main() -> int { s : ., mut = S { f = 0 }; return s.m2(nosuchfn(1)); }
"""),
    ("A9_local_helper_wrapping_io", "crash", 0, """
import fmt
import io
fn main() -> int { log2(fmt.int_str(7)); return 0; }
fn log2(s: string) -> int { println(s); return 0; }
"""),
]


def codes_of(text):
    return set(re.findall(r"error\[([A-Z0-9]+)\]", text))


def observe(src):
    """⇒ (check_rc, codes, build_rc, elf_rc)。"""
    s = f"// arg-inf-gap-{uuid.uuid4()}\n" + src
    with tempfile.NamedTemporaryFile("w", suffix=".cr", delete=False) as f:
        f.write(s)
        path = f.name
    out = str(BASE / "build" / f"_arginf_{uuid.uuid4().hex[:8]}")
    try:
        chk = subprocess.run([str(COREC), "check", path], cwd=BASE,
                             capture_output=True, text=True, timeout=180)
        codes = codes_of(chk.stdout + chk.stderr)
        bld = subprocess.run([str(COREC), "build", path, "-o", out, "--static"],
                             cwd=BASE, capture_output=True, text=True, timeout=300)
        elf = None
        if bld.returncode == 0 and os.path.exists(out):
            os.chmod(out, 0o755)
            r = subprocess.run([out], cwd=BASE, capture_output=True, timeout=120)
            # Python 把信号死报成 -N；统一成本仓惯例 rc = 128 + N（SIGSEGV ⇒ 139）
            elf = 128 + (-r.returncode) if r.returncode < 0 else r.returncode
        return chk.returncode, codes, bld.returncode, elf
    finally:
        os.unlink(path)
        if os.path.exists(out):
            os.unlink(out)


def main():
    report = "--report" in sys.argv
    fails = []
    print("=== #93 实参推断缺失 —— RED 语料现状观测（修复后应全绿）===")
    for name, kind, want, src in CASES:
        chk, codes, bld, elf = observe(src)
        if kind == "crash":
            ok = (elf == want and chk == 0)
            expect = f"ELF rc={want}（腿 A：当前预期 139）"
        elif kind == "silent":
            ok = (chk != 0 and "N06" in codes)
            expect = "check rc=1 且 code=error[N06]（腿 B：当前预期零诊断）"
        elif kind == "silent_control":
            ok = ("N06" in codes)
            expect = "code=error[N06]（对照：外层能推实参 ⇒ 当前即应报）"
        else:
            ok = (elf == want)
            expect = f"ELF rc={want}（对照：当前即应绿、修后不得变）"
        tag = "PASS" if ok else ("RED " if kind in ("crash", "silent") else "FAIL")
        if not ok:
            fails.append(name)
        print(f"[{tag}] {name:<42} 观测: check={chk} codes={sorted(codes)} build={bld} elf={elf}"
              f"  | 期望({expect})")
    print()
    if report:
        print("（--report：只观测不改判据）")
        return 0
    # RED 语料：今天必然失败。**修复批次落地后**本块应当反过来——届时删白名单条目 + 挂 run.sh + 改头注。
    print(f"RED 语料：{len(fails)}/{len(CASES)} 未达「修复后」判据（**当前预期如此**，见文件头注）")
    print("未达项：" + ", ".join(fails))
    return 1


if __name__ == "__main__":
    sys.exit(main())
