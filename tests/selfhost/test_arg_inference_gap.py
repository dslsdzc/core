#!/usr/bin/env python3
"""✅ **已修（#2026-09-16-31 批 T3）—— 本套件已挂 CI**（TODO #2026-09-16-31；详见
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

**本套件现状（修复后）**：腿 A 各例由 139 → 精确值；腿 B 由「零诊断」→ `error[N06]`；**腿 D（裁-ARG-8 H4）** 实参位泛型得精确键。
⇒ 本文件 = 「修复的判据」（TDD：先红后绿，2026-09-16 已转绿）。

**挂点（裁-ARG-7 三件套已完成）**：`src/ci/run.sh` 的 `selfhost-tests` job 已挂本套件；
`tests/harness/ci_hook_allowlist.txt` 的 RED 条目**已删**（判据 = `test_ci_hook_coverage.py` PASS）。

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
fn main() -> int { p : ., mut = P { v = 0 }; return show(p.get()); }
"""),
    ("A6_three_arg_outer", "crash", 0, """
import fmt
fn str_neq_3(a: string, b: string, c: int) -> int { if !str_eq(a, b) { return 1; } return 0; }
fn main() -> int { return str_neq_3(fmt.int_str(7), "7", 1); }
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


def test_leg_e_range_go_iter_var():
    """腿 E（**维护者硬条件 2**：`go` 迭代变量要有**自己的钉子**，不能只靠碰巧覆盖它的
    两个载体）：`go i a..b f(i)` 的**直接判据**三则 ——
      E1 body 引用迭代变量 ⇒ **check rc=0 + 运行值正确**（`square(i)` 的 0+1+4 = 5）；
      E2 迭代变量**不得泄漏到 body 之外** ⇒ 外层引用 `i` **必须** rc=1 + `error[N01]`
         （证明作用域严格限 body，硬条件 1）；
      E3 **单发形** `go square(21)`（`ast_c(node) <= 0`）**完全不受影响** ⇒ check rc=0。
    背景：本条 = **修实参推断顺带暴露的 checker `go` 绑定缺口**（`parser.cr:617` 只记名、
    `checker.cr:2981-3000` 原先不 bind）—— 这是本批**第二个**顺带修复的既有缺陷。"""
    e1 = """
fn square(x: int) -> int { return x * x; }
fn main() -> int {
    arr := go i 0..3 square(i);
    return arr[0] + arr[1] + arr[2];
}
"""
    e2 = """
fn square(x: int) -> int { return x * x; }
fn main() -> int {
    arr := go i 0..3 square(i);
    return i;
}
"""
    e3 = """
fn square(x: int) -> int { return x * x; }
fn main() -> int { ch := go square(21); return 0; }
"""
    bad = 0
    chk, codes, bld, elf = observe(e1)
    if chk == 0 and elf == 5:
        print("[PASS] 腿 E · E1 range-go body 引用迭代变量: check rc=0 · ELF rc=5（0+1+4）")
    else:
        print(f"[FAIL] 腿 E · E1: check={chk} codes={sorted(codes)} elf={elf}（期望 check=0 elf=5）")
        bad += 1
    chk2, codes2, _b2, _e2 = observe(e2)
    if chk2 != 0 and "N01" in codes2:
        print("[PASS] 腿 E · E2 迭代变量不泄漏（body 外引用 ⇒ rc=1 + N01）")
    else:
        print(f"[FAIL] 腿 E · E2: check={chk2} codes={sorted(codes2)}（期望 rc=1 且 N01 —— 作用域须严格限 body）")
        bad += 1
    chk3, codes3, _b3, _e3 = observe(e3)
    if chk3 == 0:
        print("[PASS] 腿 E · E3 单发形 go（ast_c<=0）不受影响: check rc=0")
    else:
        print(f"[FAIL] 腿 E · E3: check={chk3} codes={sorted(codes3)}（期望 rc=0）")
        bad += 1
    return bad


def cir_of(src):
    """跑 `corec cir <file>` ⇒ 输出文本（腿 D 用）。"""
    s = f"// arg-inf-gap-{uuid.uuid4()}\n" + src
    with tempfile.NamedTemporaryFile("w", suffix=".cr", delete=False) as f:
        f.write(s)
        path = f.name
    try:
        r = subprocess.run([str(COREC), "cir", path], cwd=BASE,
                           capture_output=True, text=True, timeout=180)
        return r.stdout + r.stderr
    finally:
        os.unlink(path)


def test_leg_d_generic_instance_key():
    """腿 D（裁-ARG-8 H4）：同一泛型调用在**实参位**必须得**精确键**（`idf[P]`），
    不得是退化键（`idf[unit]`）—— **TODO #2026-09-16-33 的既有缺陷 = 本批附带修复**。
    与腿 B 同性质：**「修好了」的正据**（改前实参位必得 `idf[unit]`）。"""
    let_src = """
struct P { v: int }
fn idf[T](x: T) -> int { return 7; }
fn main() -> int { p : ., mut = P { v = 1 }; r := idf(p); return r; }
"""
    arg_src = """
struct P { v: int }
fn idf[T](x: T) -> int { return 7; }
fn ieq(a: int, b: int) -> int { if a == b { return 1; } return 0; }
fn main() -> int { p : ., mut = P { v = 1 }; return ieq(idf(p), 7); }
"""
    bad = 0
    for tag, src in (("LET 位", let_src), ("实参位", arg_src)):
        txt = cir_of(src)
        precise = "idf[P]" in txt
        degraded = "idf[unit]" in txt
        if precise and not degraded:
            print(f"[PASS] 腿 D · {tag}: 精确键 idf[P] 在场 · 退化键不在场")
        else:
            print(f"[FAIL] 腿 D · {tag}: 精确键在场={precise} 退化键在场={degraded}")
            bad += 1
    return bad


def main():
    report = "--report" in sys.argv
    fails = []
    print("=== #2026-09-16-31 实参推断缺失 —— RED 语料现状观测（修复后应全绿）===")
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
    nd = test_leg_d_generic_instance_key()
    if nd:
        fails.append(f"leg_d_generic_instance_key x{nd}")
    ne = test_leg_e_range_go_iter_var()
    if ne:
        fails.append(f"leg_e_range_go_iter_var x{ne}")
    print()
    if report:
        print("（--report：只观测不改判据）")
        return 0
    if fails:
        print(f"[FAIL] 未达判据 {len(fails)}/{len(CASES)} 项（+腿 D）：")
        for f in fails:
            print("   ", f)
        return 1
    print(f"[PASS] 实参推断缺失套件全绿（{len(CASES)} 例 + 腿 D + 腿 E）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
