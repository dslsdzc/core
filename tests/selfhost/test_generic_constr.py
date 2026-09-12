#!/usr/bin/env python3
"""R2 P3 Task 5：泛型约束（保留 / 实例化判定 / monomorph 实例键类型项化）行为覆盖集。

判据（语义见 docs/superpowers/plans/2026-09-11-r2-p3-capabilities.md Task 5 +
docs/superpowers/specs/2026-09-10-type-interface-unification-design.md §5.2）：

  A. 约束**保留**（本批修）：`struct`/`enum` 泛型约束此前写进 dummy 缓冲后丢弃（`struct Box[T: I]`
     静默无约束）⇒ 本批登记到结构/枚举侧表，并在**实例化点**（`Box[P]` 的类型解析）判定。
  B. 实例化判定（**本质轴**）：约束名解析为原生/已声明类型 ⇒ `ty_sub(实参项, 约束项)` 三态；
     违反 = `error[TG02]`（软诊断：check rc=1 / build rc=0）+ **非空反例文本**。
  C. 用户接口约束（`T: I`，I = `interface` 名）：**P3b Task 0 起 `iface_satisfies` 已交付**
     （P3 计划附录 B.1 阻塞项解除）⇒ 结构/枚举**实例化点真判定**（可证违反 = TG02 软诊断；
     正控 = 方法在位不误报）；函数调用点的接口约束仍走**既有** `check_iface` 名拼接路径
     （措辞/去重/rc 逐字未动；0 → 新措辞的切换归 Task 6 Step 3）。「不判」（-1）仍存在但
     域收窄 = 非命名实参 / 泛型形参实参 / 签名编码不可判面（登记；覆盖集 =
     test_iface_satisfies.py）。
  D. F4（形参链导航，TODO #21）：`infer_gen_call` 的 `pn = pn + 1` 落在**类型节点**上
     （每个形参的类型节点在其形参节点之前分配）⇒ 后续形参的声明类型被绕过、未绑定形参被
     凭空绑定。本批修为「前扫到下一个 EXPR_PARAM」——正控 = 旧态假拒现通过；负控 = 真不适配仍拒。
  E. monomorph 实例键**类型项化**：键由「实参名串（非原生 → "int" 兜底）」改为类型行规范结构名
     （含命名/泛型应用真身份）⇒ 两个**不同结构体**实参不再折叠成一个实例（旧态实测 `f[unit]`
     一份覆盖 A/B 两类型；新态 `f[A]`/`f[B]` 两份）。判据 = `.ccr` 的 SYM/STR 里的实例名。
  F. MAX_GENERICS = 4（本批登记，未解除）：>4 泛型形参现状 = parse 期硬报（P01/TA08，非静默
     截断），全语料最大实参 = 2 ⇒ 解除需改 struct/enum 表布局（ESZ 变更），本批不做（登记）。

判据口径 = 正例**三路同证**（check rc=0 ∧ ELF rc=N ∧ interp rc=N——TF01/TA01/TG02 系为
**软诊断**，只断 build+run 会让判定面失效的突变照样全绿）；负例走 `check`（有诊断即 rc=1）
+ 措辞断言 + 无产物。
"""

import os
import resource
import subprocess
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"


def _no_core_dump():
    # core_pattern 为 systemd-coredump 管道时，崩溃的陷阱程序会挂起——禁用 core dump。
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def _compile(source: str, cmd="build", extra=None):
    """返回 (result, out_path, src_path)；cmd = build（ELF 产物）| check（仅前端）| ccr。"""
    fd, src = tempfile.mkstemp(suffix=".cr")
    with os.fdopen(fd, "w") as f:
        f.write(source)
    out = src[:-3]
    if cmd == "build":
        args = [str(COREC), "build", src, "-o", out, "--static"]
    elif cmd == "ccr":
        args = [str(COREC), "ccr", src, "-o", out + ".ccr"]
    else:
        args = [str(COREC), "check", src]
    if extra:
        args += list(extra)
    r = subprocess.run(args, capture_output=True, text=True, cwd=BASE, timeout=180)
    return r, out, src


def _cleanup(*paths):
    for p in paths:
        try:
            os.unlink(p)
        except FileNotFoundError:
            pass


def build_and_run(source: str):
    r, out, src = _compile(source)
    try:
        if r.returncode != 0:
            return r, None
        rr = subprocess.run(
            [out], capture_output=True, text=True, timeout=10,
            preexec_fn=_no_core_dump,
        )
        return r, rr
    finally:
        _cleanup(src, out, out + ".ccr")


def run_interp(source: str):
    return subprocess.run(
        [str(COREC), "run", source], capture_output=True, text=True, cwd=BASE, timeout=180,
    )


def case_dual(name, source, expect_rc):
    """正例三路同证：check rc=0 ∧ ELF rc=N ∧ interp rc=N。"""
    rc_chk, outc, srcc = _compile(source, cmd="check")
    try:
        if rc_chk.returncode != 0:
            print(f"[FAIL] {name}: check rc={rc_chk.returncode}（应有零诊断）: {rc_chk.stdout}{rc_chk.stderr}")
            return False
    finally:
        _cleanup(srcc, outc, outc + ".ccr")
    r, rr = build_and_run(source)
    if rr is None:
        print(f"[FAIL] {name}: compile rc={r.returncode}: {r.stdout}{r.stderr}")
        return False
    if rr.returncode != expect_rc:
        print(f"[FAIL] {name}: ELF expected rc {expect_rc}, got {rr.returncode}")
        return False
    ri = run_interp(source)
    if ri.returncode != expect_rc:
        print(f"[FAIL] {name}: interp expected rc {expect_rc}, got {ri.returncode}: {ri.stdout}{ri.stderr}")
        return False
    print(f"[PASS] {name}: ELF+interp rc={rr.returncode}")
    return True


def case_reject(name, source, needles, cmd="check"):
    """负例：rc≠0 + 诊断针 + （build 面）无产物。"""
    r, out, src = _compile(source, cmd)
    try:
        if r.returncode == 0:
            print(f"[FAIL] {name}: expected rejection, got rc=0（静默通过面复活）")
            return False
        text = r.stdout + r.stderr
        for n in needles:
            if n not in text:
                print(f"[FAIL] {name}: rc={r.returncode} 但缺诊断 {n!r}: {text}")
                return False
        if cmd == "build" and os.path.exists(out):
            print(f"[FAIL] {name}: 拒绝编译却仍产出二进制 {out}")
            return False
        print(f"[PASS] {name}: rc={r.returncode} + {needles!r}")
        return True
    finally:
        _cleanup(src, out, out + ".ccr")


def case_ccr_names(name, source, present, absent=()):
    """实例键判据：`.ccr` 的 STR 段里实例名（mangled）的**存在/不存在**断言。

    monomorph 实例的 mangled 名 = `原名[键]`（`gen_create_instance`），落 `.ccr` STR 段；
    SYM 段含函数名（ELF 无符号表 ⇒ 该判据只在 .ccr 面成立）。absent 列表把「旧态的折叠名」
    钉死（防回退）。
    """
    r, out, src = _compile(source, cmd="ccr")
    try:
        if r.returncode != 0:
            print(f"[FAIL] {name}: ccr rc={r.returncode}: {r.stdout}{r.stderr}")
            return False
        blob = open(out + ".ccr", "rb").read()
        for n in present:
            if n.encode() not in blob:
                print(f"[FAIL] {name}: 缺实例名 {n!r}")
                return False
        for n in absent:
            if n.encode() in blob:
                print(f"[FAIL] {name}: 不该出现的实例名 {n!r} 出现了（旧折叠面复活）")
                return False
        print(f"[PASS] {name}: 实例名 {list(present)!r} 在 / {list(absent)!r} 不在")
        return True
    finally:
        _cleanup(src, out, out + ".ccr")


# ── 源形 ──────────────────────────────────────────────────────────────

# A/B：本质轴约束（函数侧 + 结构侧 + 枚举侧）
# 返回型 = T（**既有语义约束**：泛型体内 `return a`（a: T）对**具体**返回型会 TF01——实测
# 新旧一致，非本批面）；调用点 int 返回 T 实例化的结果
FUNC_INT_CONSTR = """fn f[T: int](a: T) -> T { return a; }
fn main() -> int { return f(1); }
"""
FUNC_INT_CONSTR_BAD = """fn f[T: int](a: T) -> T { return a; }
fn main() -> int { return f("s"); }
"""
STRUCT_INT_CONSTR = """struct Box[T: int] { v: T }
fn g(b: Box[int]) -> int { return b.v; }
fn main() -> int { return g(Box { v: 7 }); }
"""
STRUCT_INT_CONSTR_BAD = """struct Box[T: int] { v: T }
struct S { a: int }
fn g(b: Box[S]) -> int { return 0; }
fn main() -> int { return 0; }
"""
STRUCT_INT_CONSTR_STR_BAD = """struct Box[T: int] { v: T }
fn g(b: Box[string]) -> int { return 0; }
fn main() -> int { return 0; }
"""
ENUM_INT_CONSTR_BAD = """enum EBox[T: int] { V(T), N }
fn g(b: EBox[string]) -> int { return 0; }
fn main() -> int { return 0; }
"""
# 无约束泛型（对照：约束面落地不得波及无约束声明）
STRUCT_NO_CONSTR = """struct Wrap[T] { v: T }
struct S { a: int }
fn g(b: Wrap[S]) -> int { return b.v.a; }
fn main() -> int { return g(Wrap { v: S { a: 3 } }); }
"""
# C：用户接口约束 = P3b 边界（零诊断；函数侧走既有 check_iface，结构侧 = 不判）
IFACE_LEGACY_OK = """interface Show { fn show(self) -> int; }
struct S { a: int }
impl S { fn show(self: S) -> int { return 1; } }
fn f[T: Show](a: T) -> int { return 0; }
fn main() -> int { s := S { a: 1 }; return f(s); }
"""
IFACE_LEGACY_BAD = """interface Show { fn show(self) -> int; }
struct S { a: int }
fn f[T: Show](a: T) -> int { return 0; }
fn main() -> int { s := S { a: 1 }; return f(s); }
"""
STRUCT_IFACE_REJECT = """interface Show { fn show(self) -> int; }
struct Box[T: Show] { v: T }
struct S { a: int }
fn g(b: Box[S]) -> int { return 0; }
fn main() -> int { return 0; }
"""
# 结构侧正控：方法在位 ⇒ 满足（P3b Task 0 起实例化点**真判定**——本常量 = 新判定不误报的守门）
STRUCT_IFACE_ACCEPT = """interface Show { fn show(self) -> int; }
struct Box[T: Show] { v: T }
struct S { a: int }
impl S { fn show(self: S) -> int { return 1; } }
fn g(b: Box[S]) -> int { return b.v.a; }
fn main() -> int { return g(Box { v = S { a = 7 } }); }
"""
UNKNOWN_CONSTR_NAME = """fn f[T: NoSuchThing](a: T) -> int { return 0; }
fn main() -> int { return f(1); }
"""
# D：F4 形参链（旧态：后续形参的声明类型被绕过 → T 未绑定 → 假拒 TF01）
F4_LATER_PARAM = """fn foo(s: string) -> string { return s; }
fn take[T](n: int, a: T) -> T { return a; }
fn main() -> int { return take(1, 2); }
"""
F4_LATER_PARAM_BAD = """fn foo(s: string) -> string { return s; }
fn take[T](n: int, a: T) -> T { return a; }
fn main() -> int { return take(1, "s"); }
"""
# E：实例键（两个不同结构体实参）
TWO_STRUCTS = """struct A { a: int }
struct B { b: int, c: int }
fn f[T](x: T) -> int { return 1; }
fn main() -> int { p := A { a: 1 }; q := B { b: 2, c: 3 }; return f(p) + f(q); }
"""


def main():
    ok = [
        # ── A/B 正：本质轴约束满足（函数侧 / 结构侧）──
        case_dual("func_essence_constr_pass", FUNC_INT_CONSTR, 1),
        case_dual("struct_essence_constr_pass", STRUCT_INT_CONSTR, 7),
        case_dual("unconstrained_generic_unaffected", STRUCT_NO_CONSTR, 3),
        # ── A/B 负：约束违反（软诊断 TG02 + 反例文本）──
        # 函数调用点：实参 string 不满足 `T: int`
        case_reject("func_essence_constr_violated", FUNC_INT_CONSTR_BAD,
                    ["error[TG02]", "does not satisfy constraint 'int'", "counterexample"]),
        # 结构实例化点：`Box[string]` 违反 `T: int`
        case_reject("struct_inst_constr_violated", STRUCT_INT_CONSTR_STR_BAD,
                    ["error[TG02]", "does not satisfy constraint 'int'", "counterexample"]),
        # 结构实例化点：命名类型实参（S）——引擎对 AK_NAMED 不展开 ⇒ **不判**（三态纪律：
        # 未知不得当违反；这是**登记面**，不是漏放——同族「命名实参 vs 原生约束」见报告 §登记）
        case_dual("struct_inst_named_arg_unjudged", STRUCT_INT_CONSTR_BAD, 0),
        # 枚举实例化点
        case_reject("enum_inst_constr_violated", ENUM_INT_CONSTR_BAD,
                    ["error[TG02]", "does not satisfy constraint 'int'"]),
        # ── C：用户接口约束（P3b 边界）──
        # 函数侧：既有 check_iface 路径（满足 → 过）
        case_dual("iface_constr_legacy_pass", IFACE_LEGACY_OK, 0),
        # 函数侧：既有路径拒绝（措辞 = interface，与本质轴路径区分）
        case_reject("iface_constr_legacy_reject", IFACE_LEGACY_BAD,
                    ["error[TG02]", "does not satisfy interface 'Show'"]),
        # 结构侧：**P3b Task 0 起真判定**（`iface_satisfies` 已交付 ⇒ 可证违反 = TG02）。
        # 本用例原为「不判」钉（P3a 边界，rc=0 零诊断）——**台账：旧 rc=0 → 新 check rc=1 +
        # error[TG02] + "does not satisfy interface 'Show'"**（收紧，全语料零命中；同族
        # 覆盖集 = tests/selfhost/test_iface_satisfies.py 17 例）
        case_reject("struct_iface_constr_violated", STRUCT_IFACE_REJECT,
                    ["error[TG02]", "does not satisfy interface 'Show'"]),
        # 结构侧正控：方法在位 ⇒ 满足（新判定不误报；三路同证）
        case_dual("struct_iface_constr_present_accepted", STRUCT_IFACE_ACCEPT, 7),
        # 约束名不是任何类型/接口 ⇒ 不判（不发明诊断）
        case_dual("unknown_constr_name_unjudged", UNKNOWN_CONSTR_NAME, 0),
        # ── D：F4 形参链（正控 = 修复后绑定正确；负控 = 真不适配仍拒）──
        case_dual("f4_later_param_binds_correctly", F4_LATER_PARAM, 2),
        case_reject("f4_later_param_type_mismatch", F4_LATER_PARAM_BAD, ["error[TF01]"], cmd="check"),
        # ── E：实例键类型项化（异型异构体 → 两实例；旧态折叠为 f[unit]）──
        case_ccr_names("mono_two_struct_instances", TWO_STRUCTS,
                       present=["f[A]", "f[B]"], absent=["f[unit]"]),
    ]

    passed = sum(ok)
    print(f"{passed}/{len(ok)} passed")
    return 0 if passed == len(ok) else 1


if __name__ == "__main__":
    raise SystemExit(main())
