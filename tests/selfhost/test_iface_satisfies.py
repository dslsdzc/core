#!/usr/bin/env python3
"""R2 P3b Task 0（P2b 交接面回补）：`iface_satisfies` 契约的行为覆盖集。

契约（P3 计划「与 P2b 的交接面」① + 附录 B.1 #1）：`iface_satisfies(t_ti, iface_ni) -> int`
三态（1 = 判定满足 / 0 = 判定违反 / -1 = 不判）——**-1 不得被读成 0/1**。本批交付：
  · 轴分派：A 横切形状名（表由 Task 2 注册；本批空表 ⇒ 恒 -1）→ C 用户接口名 → B 本质轴
    （原生/已声明类型名，= P3a `gen_constr_satisfied` 的窄化口径，逐字保持）；
  · 轴 C 谓词 = **与 `check_iface` 同源**（方法名在位 + 参数计数 + 返回码），三态；域限定
    = 命名行（`TYP_NAMED` / `TYP_GENERIC_APPLY` 基名）——原生/`dyn`/泛型形参/复合行 ⇒ -1；
  · 首个消费者 = `gen_constr_satisfied` 首分支（**1 提前返回**，0/-1 一律回落既有
    `check_iface` 名拼接路径 = 函数调用点措辞/去重/rc 逐字不动，切换归 Task 6 Step 3）；
  · 第二消费者 = 结构/枚举**实例化点**（`gen_inst_constr_satisfied`）——**本批新增判定**。

**三态纪律（本文件的主判据）**：「不判」≠「不满足」。负例段把「违反 ⇒ error[TG02]」钉死；
登记面段把「不判 ⇒ 零诊断」钉死（防后续把 -1 静默折成 0/1）。

**覆盖边界（登记，非漏放）——机制 = 接口签名槽是映射层编码**（parser 的 `unpack_type` /
`fi_set_param_type`：非原生类型节点一律塌缩为码 0 = `TY_INT`，与 `int` 不可区分）
⇒ 逐参数类型不可比（与 `check_iface` 一致），返回码比对语义 = **编码相等**。本条由
`inst_encoding_limit_named_ret_pinned` 钉住现状；解锁 = Task 6 Step 1（签名类型项化）后由
形状项包含判定（`sh_iface_shape_term` 路由）取代，并由 Task 6 Step 3 切换调用点。
另注：接口签名的 `self`/`&self` 槽在两侧均写码 0（parser 约定），故含接收者的方法签名面亦
不参与类型比对——同属上述登记面。

**判据口径**：正例三路同证（check rc=0 ∧ ELF rc=N ∧ interp rc=N）；负例走 `check`
（有诊断即 rc=1）+ 措辞断言 + 无产物。TG02 为**软诊断**（check rc=1 / build rc=0 + 产物
照出——与既有约束检查同门同码，本批未新增硬门，见 P3a 报告 §0-① 的口径）。

**收紧台账（旧 → 新；全语料零命中，见本批报告 §5）**：
  | 用例 | 旧 | 新 |
  |---|---|---|
  | inst_missing_method_rejected          | rc=0 零诊断 | check rc=1 + TG02 |
  | inst_count_mismatch_rejected           | rc=0 零诊断 | check rc=1 + TG02 |
  | inst_ret_code_mismatch_rejected        | rc=0 零诊断 | check rc=1 + TG02 |
  | inst_enum_missing_method_rejected      | rc=0 零诊断 | check rc=1 + TG02 |
  | inst_multi_method_partial_rejected     | rc=0 零诊断 | check rc=1 + TG02 |
  | inst_second_iface_missing_rejected     | rc=0 零诊断 | check rc=1 + TG02 |
  「旧」= 本批前二进制（P3a 收官 `aa54d26a`）；零变化的其余用例 = 逐位同。
"""

import os
import resource
import subprocess
import tempfile
from pathlib import Path


BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"


def _no_core_dump():
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def _compile(source: str, cmd="check"):
    fd, src = tempfile.mkstemp(suffix=".cr")
    with os.fdopen(fd, "w") as f:
        f.write(source)
    out = src[:-3]
    if cmd == "build":
        args = [str(COREC), "build", src, "-o", out, "--static"]
    else:
        args = [str(COREC), "check", src]
    r = subprocess.run(args, capture_output=True, text=True, cwd=BASE, timeout=180)
    return r, out, src


def _cleanup(*paths):
    for p in paths:
        try:
            os.unlink(p)
        except FileNotFoundError:
            pass


def build_and_run(source: str):
    r, out, src = _compile(source, cmd="build")
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


def case_reject(name, source, needles):
    """负例：check rc≠0 + 诊断针 + 同源三态（同措辞在函数调用点与实例化点都成立）。"""
    r, out, src = _compile(source, cmd="check")
    try:
        if r.returncode == 0:
            print(f"[FAIL] {name}: expected rejection, got rc=0（静默通过面复活）")
            return False
        text = r.stdout + r.stderr
        for n in needles:
            if n not in text:
                print(f"[FAIL] {name}: rc={r.returncode} 但缺诊断 {n!r}: {text}")
                return False
        print(f"[PASS] {name}: rc={r.returncode} + {needles!r}")
        return True
    finally:
        _cleanup(src, out, out + ".ccr")


def case_unjudged(name, source):
    """登记面：**不判**（-1）或编码面判定满足（-1 与 1 在实例化点都 = 零动作）⇒ 零诊断 + rc=0。

    三态纪律的正面钉：零诊断 = 「不是『不满足』」，**不得**被读作「已验证满足」。"""
    r, out, src = _compile(source, cmd="check")
    try:
        if r.returncode != 0:
            print(f"[FAIL] {name}: 不判/编码面出现诊断（-1 被当 0 用？）rc={r.returncode}: {r.stdout}{r.stderr}")
            return False
        print(f"[PASS] {name}: 零诊断 rc=0（不判 或 编码面判定满足）")
        return True
    finally:
        _cleanup(src, out, out + ".ccr")


# ── 源形 ──────────────────────────────────────────────────────────────

# 方法在位（固有 impl 形态；P3a 既有语义 = 结构判定，非名义声明）
IFACE_OK = """interface Show { fn show(self) -> int; }
struct S { a: int }
impl S { fn show(self: S) -> int { return 1; } }
struct Box[T: Show] { v: T }
fn g(b: Box[S]) -> int { return b.v.a; }
fn main() -> int { return g(Box { v = S { a = 7 } }); }
"""
# 方法在位（`impl I for T` 形态）
IFACE_IMPL_FOR_OK = """interface Show { fn show(self) -> int; }
struct S { a: int }
impl Show for S { fn show(self: S) -> int { return 2; } }
struct Box[T: Show] { v: T }
fn main() -> int { b := Box { v = S { a = 2 } }; return b.v.a; }
"""
# 方法缺失（**本批新增判定**）
IFACE_MISSING = """interface Show { fn show(self) -> int; }
struct S { a: int }
struct Box[T: Show] { v: T }
fn g(b: Box[S]) -> int { return 0; }
fn main() -> int { return 0; }
"""
# 参数计数不符
IFACE_CNT_MISMATCH = """interface Show { fn show(self) -> int; }
struct S { a: int }
impl S { fn show(self: S, x: int) -> int { return x; } }
struct Box[T: Show] { v: T }
fn g(b: Box[S]) -> int { return 0; }
fn main() -> int { return 0; }
"""
# 返回码不符（iface `-> int` 码 0 vs impl `-> string` 码 3）
IFACE_RET_MISMATCH = """interface Show { fn show(self) -> int; }
struct S { a: int }
impl S { fn show(self: S) -> string { return "x"; } }
struct Box[T: Show] { v: T }
fn g(b: Box[S]) -> int { return 0; }
fn main() -> int { return 0; }
"""
# 同一违反走**函数调用点**（既有路径；措辞应与实例化点同）
IFACE_FUNC_RET_MISMATCH = """interface Show { fn show(self) -> int; }
struct S { a: int }
impl S { fn show(self: S) -> string { return "x"; } }
fn f[T: Show](a: T) -> int { return 0; }
fn main() -> int { s := S { a = 1 }; return f(s); }
"""
# 枚举实例化点（方法缺失）
IFACE_ENUM_MISSING = """interface Show { fn show(self) -> int; }
struct S { a: int }
enum EBox[T: Show] { V(T), N }
fn g(b: EBox[S]) -> int { return 0; }
fn main() -> int { return 0; }
"""
# 多方法接口：实现一半
IFACE_PARTIAL = """interface Pair2 { fn first(self) -> int; fn second(self) -> int; }
struct S { a: int }
impl S { fn first(self: S) -> int { return 1; } }
struct Box[T: Pair2] { v: T }
fn g(b: Box[S]) -> int { return 0; }
fn main() -> int { return 0; }
"""
# 两接口隔离：S 满足 Show、不满足 Name
IFACE_TWO_A = """interface Name { fn name(self) -> int; }
struct S { a: int }
impl S { fn name(self: S) -> int { return 1; } }
struct BoxA[T: Name] { v: T }
fn g(b: BoxA[S]) -> int { return 0; }
fn main() -> int { return 0; }
"""
IFACE_TWO_B = """interface Show { fn show(self) -> int; }
interface Name { fn name(self) -> int; }
struct S { a: int }
impl S { fn show(self: S) -> int { return 1; } }
struct BoxB[T: Name] { v: T }
fn g(b: BoxB[S]) -> int { return 0; }
fn main() -> int { return 0; }
"""
# 泛型形参实参（未实例化）⇒ 不判
IFACE_GP_ARG = """interface Show { fn show(self) -> int; }
struct Box[T: Show] { v: T }
fn f[U: Show](b: Box[U]) -> int { return 0; }
fn main() -> int { return 0; }
"""
# 原生实参 ⇒ 不判（接口方法表只对命名行可查）
IFACE_NATIVE_ARG = """interface Show { fn show(self) -> int; }
struct Box[T: Show] { v: T }
fn g(b: Box[int]) -> int { return 0; }
fn main() -> int { return 0; }
"""
# 编码面登记：命名的返回型（两侧均码 0）⇒ 判定「满足」（**现状口径钉死**，Task 6 解锁）
IFACE_NAMED_RET = """interface Show { fn show(self) -> S2; }
struct S2 { b: int }
struct S { a: int }
impl S { fn show(self: S) -> int { return 1; } }
struct Box[T: Show] { v: T }
fn g(b: Box[S]) -> int { return 0; }
fn main() -> int { return 0; }
"""
# 函数调用点：满足 ⇒ 既有路径放行（正控；P3a 既有语义保持）
IFACE_FUNC_OK = """interface Show { fn show(self) -> int; }
struct S { a: int }
impl S { fn show(self: S) -> int { return 3; } }
fn f[T: Show](a: T) -> int { return 1; }
fn main() -> int { s := S { a = 1 }; return f(s); }
"""
# 函数调用点：违反 ⇒ 既有措辞（**逐字不动**的钉）
IFACE_FUNC_MISSING = """interface Show { fn show(self) -> int; }
struct S { a: int }
fn f[T: Show](a: T) -> int { return 0; }
fn main() -> int { s := S { a = 1 }; return f(s); }
"""
# 空接口（零方法）⇒ 空洞满足（命名行）
IFACE_EMPTY = """interface Empty { }
struct S { a: int }
struct Box[T: Empty] { v: T }
fn g(b: Box[S]) -> int { return b.v.a; }
fn main() -> int { return g(Box { v = S { a = 5 } }); }
"""
# `&self` 接收者形态（计数面）
IFACE_REF_SELF = """interface Show { fn show(&self) -> int; }
struct S { a: int }
impl S { fn show(&self) -> int { return 1; } }
struct Box[T: Show] { v: T }
fn g(b: Box[S]) -> int { return b.v.a; }
fn main() -> int { return g(Box { v = S { a = 4 } }); }
"""


def main():
    ok = [
        # ── 正例（三路同证；含新判定不误报的守门）──
        case_dual("inst_method_present_accepted", IFACE_OK, 7),
        case_dual("inst_impl_for_form_accepted", IFACE_IMPL_FOR_OK, 2),
        case_dual("inst_empty_iface_vacuous", IFACE_EMPTY, 5),
        case_dual("inst_ref_self_accepted", IFACE_REF_SELF, 4),
        case_dual("inst_first_iface_accepted", IFACE_TWO_A, 0),
        case_dual("func_site_pass_unchanged", IFACE_FUNC_OK, 1),
        # ── 负例（收紧面：实例化点新判定）──
        case_reject("inst_missing_method_rejected", IFACE_MISSING,
                    ["error[TG02]", "does not satisfy interface 'Show'"]),
        case_reject("inst_count_mismatch_rejected", IFACE_CNT_MISMATCH,
                    ["error[TG02]", "does not satisfy interface 'Show'"]),
        case_reject("inst_ret_code_mismatch_rejected", IFACE_RET_MISMATCH,
                    ["error[TG02]", "does not satisfy interface 'Show'"]),
        case_reject("inst_enum_missing_method_rejected", IFACE_ENUM_MISSING,
                    ["error[TG02]", "does not satisfy interface 'Show'"]),
        case_reject("inst_multi_method_partial_rejected", IFACE_PARTIAL,
                    ["error[TG02]", "does not satisfy interface 'Pair2'"]),
        case_reject("inst_second_iface_missing_rejected", IFACE_TWO_B,
                    ["error[TG02]", "does not satisfy interface 'Name'"]),
        # 站点一致性：同一违反在**函数调用点**（既有路径）与实例化点**同措辞**报出
        case_reject("func_site_ret_mismatch_also_rejected", IFACE_FUNC_RET_MISMATCH,
                    ["error[TG02]", "does not satisfy interface 'Show'"]),
        case_reject("func_site_missing_method_unchanged", IFACE_FUNC_MISSING,
                    ["error[TG02]", "does not satisfy interface 'Show'"]),
        # ── 登记面（不判 ⇒ 零诊断；三态纪律的正面钉——零动作而非「已验证满足」）──
        case_unjudged("inst_generic_param_arg_unjudged", IFACE_GP_ARG),
        case_unjudged("inst_native_arg_unjudged", IFACE_NATIVE_ARG),
        # 编码面登记：命名返回型 vs int 返回 ⇒ **判定满足（1）**（映射层编码口径；Task 6 Step 1 解锁）
        case_unjudged("inst_encoding_limit_named_ret_pinned", IFACE_NAMED_RET),
    ]

    passed = sum(ok)
    print(f"{passed}/{len(ok)} passed")
    return 0 if passed == len(ok) else 1


if __name__ == "__main__":
    raise SystemExit(main())
