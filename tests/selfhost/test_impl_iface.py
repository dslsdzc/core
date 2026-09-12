#!/usr/bin/env python3
"""R2 P3b Task 6：impl 契约覆盖集（spec §5.3 要求新建）。

交付面（P3 计划 Task 6）：
  · **Step 1 签名类型项化**：接口方法条目新增**类型节点**槽（`OFF_IFM_PARAM_NODES` /
    `OFF_IFM_RET_NODE` / `OFF_IFM_SELF_MODE`）⇒ 签名首次可按**类型**表达与比较（旧态 = 裸
    `TY_*` 码：非原生类型一律塌缩为码 0 = TY_INT，与 int 不可区分）。
  · **Step 3 满足判定接引擎 + mangling 退役**：方法解析从「`Type.method` 字符串拼接 + `find_func`」
    改为 `g_methods` 表查询（`iface_find_method`）；判定 = 接口形状项（方法集 = product of fn，
    `sh_iface_shape_term`）的**逐成员**签名项比较（`sh_func_sig_term` / `sh_iface_sig_param_term`
    + 引擎结构比较原语 `tt_list_same`）。泛型形参接收者的方法调用在实例化时按具体类型查表解析
    （`CALL_FLAG_IFACE_METHOD` + monomorph 的 EXPR_CALL 克隆分支）。
  · **覆盖集**：正向 / 反向（缺方法·参数数·**参数类型**·**返回类型**·**接收者模式**）/ 多接口 /
    泛型约束交互 / 错误例（未定义接口）/ 固有方法不受影响 / 上限钉子（16 方法 · 8 参数）。

**语义口径（本任务裁决，逐条登记在报告）**：
  ① **用户轴保持结构口径**（方法集包含）；**不**改名义口径（`impl I for T` 声明即满足）——
     采纳名义会翻转既有钉死用例（`test_generic_constr.py::iface_constr_legacy_pass` 等 5+ 例
     正向固有 impl 形态），且属语言设计裁决（spec §0 裁决 6：语义争议停下上报）⇒ 登记 TODO。
  ② **签名身份 = P3a 既有不变量**：N（数组长度）不入签名身份（长度面由常量档承担）；
     命名行按**名义**（同名字同行；引擎不展开 AK_NAMED——P0 未覆盖面②）；泛型应用按
     基名 + 实参链（规范形展开）。
  ③ **接收者模式**（self / &self / &mut self）是判定维度（调用约定，不入类型项面 ⇒ 两侧显式
     比较）。旧态两侧皆写码 0 ⇒ 不可比。

**收紧台账（旧 → 新；「旧」= P3b Task 2 二进制 ./build/corec 的上一版，本文件逐例实测随报告提交）**：
  | 用例 | 旧 | 新 |
  |---|---|---|
  | neg_named_param_type_mismatch | check rc=0 零诊断 | rc=1 + TG02 |
  | neg_apply_arg_mismatch | check rc=0 零诊断 | rc=1 + TG02 |
  | neg_named_ret_vs_native | check rc=0 零诊断（编码面判「满足」） | rc=1 + TG02 |
  | neg_receiver_mode_mismatch | check rc=0 零诊断 | rc=1 + TG02 |
  | pos_generic_body_call 运行面 | build rc=0 + **运行 rc=139**（调用目标悬空） | build rc=0 + 运行 rc=N（正确值） |

**判据口径**：正例三路同证（check rc=0 ∧ ELF rc=N ∧ interp rc=N）；负例走 `check`（rc=1 + 诊断
针）+ 软诊断门形态（build rc=0 + 产物照出，TG02 与既有约束检查同门同码）。**例外（登记）**：
泛型体内方法调用（`pos_generic_body_call`）的解释器路径现状 = `Unexpected token in expression`
（`corec run` 的解析面不支持方法调用语句；**旧二进制同 rc=1**，非本任务引入）⇒ 该例走
check + ELF 两路。
"""

import os
import resource
import subprocess
import tempfile
from pathlib import Path


BASE = Path(__file__).resolve().parents[2]
COREC = Path(os.environ.get("COREC_BIN", BASE / "build" / "corec"))


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


def case_elf(name, source, expect_rc):
    """两路同证（check + ELF；解释器面登记为不覆盖——见文件头注）。"""
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
    print(f"[PASS] {name}: ELF rc={rr.returncode}（check rc=0）")
    return True


def case_reject(name, source, needles):
    """负例：check rc≠0 + 诊断针（软诊断门形态：build 仍 rc=0 + 产物照出）。"""
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
    """登记面：**不判**（-1）⇒ 零诊断 + rc=0。零诊断 = 「不是『不满足』」。"""
    r, out, src = _compile(source, cmd="check")
    try:
        if r.returncode != 0:
            print(f"[FAIL] {name}: 不判面出现诊断（-1 被当 0 用？）rc={r.returncode}: {r.stdout}{r.stderr}")
            return False
        print(f"[PASS] {name}: 零诊断 rc=0（不判）")
        return True
    finally:
        _cleanup(src, out, out + ".ccr")


def case_hard(name, source, needles):
    """硬错误钉子：check rc=1 + 无产物（build rc≠0）。"""
    r, out, src = _compile(source, cmd="check")
    try:
        if r.returncode == 0:
            print(f"[FAIL] {name}: expected hard error, got rc=0")
            return False
        text = r.stdout + r.stderr
        for n in needles:
            if n not in text:
                print(f"[FAIL] {name}: rc={r.returncode} 但缺诊断 {n!r}: {text}")
                return False
    finally:
        _cleanup(src, out, out + ".ccr")
    r2, out2, src2 = _compile(source, cmd="build")
    try:
        if r2.returncode == 0:
            print(f"[FAIL] {name}: 硬错误面 build 竟然 rc=0（产物照出）")
            return False
        print(f"[PASS] {name}: check rc=1 + build rc={r2.returncode}（无产物）")
        return True
    finally:
        _cleanup(src2, out2, out2 + ".ccr")


# ── 源形 ──────────────────────────────────────────────────────────────

# 正向：固有 impl 形态（结构口径）——**双站点**（实例化点 `Box[S]` 注解 + 函数调用点 `f(s)`）
POS_INHERENT = """interface Show { fn show(self) -> int; }
struct S { a: int }
impl S { fn show(self: S) -> int { return 5; } }
struct Box[T: Show] { v: T }
fn f[T: Show](a: T) -> int { return 0; }
fn g(b: Box[S]) -> int { return b.v.a; }
fn main() -> int { s := S { a = 7 }; z := f(s); return g(Box { v = s }); }
"""
# 正向：`impl I for T` 形态（双站点）
POS_IMPL_FOR = """interface Show { fn show(self) -> int; }
struct S { a: int }
impl Show for S { fn show(self: S) -> int { return 2; } }
struct Box[T: Show] { v: T }
fn f[T: Show](a: T) -> int { return 0; }
fn main() -> int { s := S { a = 2 }; z := f(s); return s.a + z; }
"""
# 正向：命名参数类型 + 命名返回类型（签名类型项化的主要正控——旧态两侧皆码 0；双站点）
POS_NAMED_SIG = """interface Conv { fn conv(self, x: S2) -> S3; }
struct S2 { b: int }
struct S3 { c: int }
struct S { a: int }
impl S { fn conv(self: S, x: S2) -> S3 { return S3 { c = x.b + 3 }; } }
struct Box[T: Conv] { v: T }
fn f[T: Conv](a: T) -> int { return 0; }
fn g(b: Box[S]) -> int { return b.v.a; }
fn main() -> int { s := S { a = 1 }; z := f(s); return g(Box { v = s }); }
"""
# 正向：泛型应用实参（`Pair[int]` 两侧同型；双站点）
POS_APPLY_SIG = """interface Take { fn take(self, x: Pair[int]) -> int; }
struct Pair[T] { v: T }
struct S { a: int }
impl S { fn take(self: S, x: Pair[int]) -> int { return x.v; } }
struct Box[T: Take] { v: T }
fn f[T: Take](a: T) -> int { return 0; }
fn g(b: Box[S]) -> int { return b.v.a; }
fn main() -> int { s := S { a = 9 }; z := f(s); return g(Box { v = s }); }
"""
# 正向：`&self` 接收者（两侧同模式；双站点）
POS_REF_SELF = """interface Show { fn show(&self) -> int; }
struct S { a: int }
impl S { fn show(&self) -> int { return 4; } }
struct Box[T: Show] { v: T }
fn f[T: Show](a: T) -> int { return 0; }
fn g(b: Box[S]) -> int { return b.v.a; }
fn main() -> int { s := S { a = 4 }; z := f(s); return g(Box { v = s }); }
"""
# 泛型体内方法调用（mangling 退役的主用例：旧态**运行 rc=139**）——固有形态
POS_GENERIC_BODY_CALL = """interface Show { fn show(self) -> int; }
struct S { a: int }
impl S { fn show(self: S) -> int { return 7; } }
fn f[T: Show](a: T) -> int { x := a.show(); return x; }
fn main() -> int { s := S { a = 1 }; return f(s); }
"""
# 泛型体内方法调用——`impl I for T` 形态
POS_GENERIC_BODY_CALL_FOR = """interface Show { fn show(self) -> int; }
struct S { a: int }
impl Show for S { fn show(self: S) -> int { return 9; } }
fn f[T: Show](a: T) -> int { x := a.show(); return x; }
fn main() -> int { s := S { a = 1 }; return f(s); }
"""
# 固有方法不受影响（无接口参与）
POS_INHERENT_ONLY = """struct S { a: int }
impl S { fn get(self: S) -> int { return self.a; } fn add(self: S, x: int) -> int { return self.a + x; } }
fn main() -> int { s := S { a = 6 }; return s.add(1); }
"""
# 多接口隔离：S 满足 Show（另一接口 Name 未参与；双站点）
POS_MULTI_IFACE = """interface Show { fn show(self) -> int; }
interface Name { fn name(self) -> int; }
struct S { a: int }
impl S { fn show(self: S) -> int { return 1; } }
impl S { fn name(self: S) -> int { return 2; } }
struct Box[T: Show] { v: T }
fn f[T: Show](a: T) -> int { return 0; }
fn g(b: Box[S]) -> int { return b.v.a; }
fn main() -> int { s := S { a = 3 }; z := f(s); return g(Box { v = s }); }
"""
# 负：缺方法
NEG_MISSING = """interface Show { fn show(self) -> int; }
struct S { a: int }
struct Box[T: Show] { v: T }
fn g(b: Box[S]) -> int { return 0; }
fn main() -> int { return 0; }
"""
# 负：参数计数
NEG_ARITY = """interface Show { fn show(self) -> int; }
struct S { a: int }
impl S { fn show(self: S, x: int) -> int { return x; } }
struct Box[T: Show] { v: T }
fn g(b: Box[S]) -> int { return 0; }
fn main() -> int { return 0; }
"""
# 负：**参数类型**不符（命名型——旧态裸码面不可见）
NEG_NAMED_PARAM = """interface Show { fn m(self, x: S2) -> int; }
struct S2 { b: int }
struct S { a: int }
impl S { fn m(self: S, x: int) -> int { return x; } }
struct Box[T: Show] { v: T }
fn g(b: Box[S]) -> int { return 0; }
fn main() -> int { return 0; }
"""
# 负：**返回类型**不符（命名型 vs 原生——旧态编码面判「满足」）
NEG_NAMED_RET = """interface Show { fn m(self) -> S2; }
struct S2 { b: int }
struct S { a: int }
impl S { fn m(self: S) -> int { return 1; } }
struct Box[T: Show] { v: T }
fn g(b: Box[S]) -> int { return 0; }
fn main() -> int { return 0; }
"""
# 负：泛型应用实参不符（`Pair[string]` ← `Pair[int]`）
NEG_APPLY_ARG = """interface Take { fn take(self, x: Pair[int]) -> int; }
struct Pair[T] { v: T }
struct S { a: int }
impl S { fn take(self: S, x: Pair[string]) -> int { return 1; } }
struct Box[T: Take] { v: T }
fn g(b: Box[S]) -> int { return 0; }
fn main() -> int { return 0; }
"""
# 负：接收者模式不符（iface `&self` vs impl `self`）
NEG_RECV_MODE = """interface Show { fn show(&self) -> int; }
struct S { a: int }
impl S { fn show(self: S) -> int { return 1; } }
struct Box[T: Show] { v: T }
fn g(b: Box[S]) -> int { return 0; }
fn main() -> int { return 0; }
"""
# 负：两接口隔离（S 满足 Show、不满足 Name）
NEG_SECOND_IFACE = """interface Show { fn show(self) -> int; }
interface Name { fn name(self) -> int; }
struct S { a: int }
impl S { fn show(self: S) -> int { return 1; } }
struct BoxB[T: Name] { v: T }
fn g(b: BoxB[S]) -> int { return 0; }
fn main() -> int { return 0; }
"""
# 错误例：未定义接口（`impl I for T` 的声明侧校验）
ERR_UNDEFINED_IFACE = """struct S { a: int }
impl Nope for S { fn show(self: S) -> int { return 1; } }
fn main() -> int { return 0; }
"""
# 登记面：非命名实参（原生）⇒ 不判 ⇒ 零诊断
UNJUDGED_NATIVE = """interface Show { fn show(self) -> int; }
struct Box[T: Show] { v: T }
fn g(b: Box[int]) -> int { return 0; }
fn main() -> int { return 0; }
"""
# 上限钉子：17 方法（> MAX_IFACE_METHODS=16）⇒ 硬错
LIMIT_METHODS = "interface Many {\n" + "\n".join(
    f"    fn m{i}(self) -> int;" for i in range(17)) + "\n}\nfn main() -> int { return 0; }\n"
# 上限钉子：9 参数（> MAX_IFACE_METHOD_PARAMS=8）⇒ 硬错
LIMIT_PARAMS = ("interface Wide { fn m(self, " + ", ".join(f"p{i}: int" for i in range(9)) +
                ") -> int; }\nfn main() -> int { return 0; }\n")


def main():
    ok = [
        # ── 正向（三路同证 / 两路同证）──
        case_dual("pos_inherent_impl_accepted", POS_INHERENT, 7),
        case_dual("pos_impl_for_accepted", POS_IMPL_FOR, 2),
        case_dual("pos_named_signature_accepted", POS_NAMED_SIG, 1),
        case_dual("pos_apply_signature_accepted", POS_APPLY_SIG, 9),
        case_dual("pos_ref_self_accepted", POS_REF_SELF, 4),
        case_dual("pos_inherent_methods_unaffected", POS_INHERENT_ONLY, 7),
        case_dual("pos_multi_iface_isolation", POS_MULTI_IFACE, 3),
        # 泛型体内方法调用：**运行面**（mangling 退役的收益——旧态 rc=139）
        case_elf("pos_generic_body_call_inherent", POS_GENERIC_BODY_CALL, 7),
        case_elf("pos_generic_body_call_impl_for", POS_GENERIC_BODY_CALL_FOR, 9),
        # ── 反向（收紧面：签名类型项化 / 接收者模式）──
        case_reject("neg_missing_method", NEG_MISSING,
                    ["error[TG02]", "does not satisfy interface 'Show'"]),
        case_reject("neg_param_count", NEG_ARITY,
                    ["error[TG02]", "does not satisfy interface 'Show'"]),
        case_reject("neg_named_param_type_mismatch", NEG_NAMED_PARAM,
                    ["error[TG02]", "does not satisfy interface 'Show'"]),
        case_reject("neg_named_ret_vs_native", NEG_NAMED_RET,
                    ["error[TG02]", "does not satisfy interface 'Show'"]),
        case_reject("neg_apply_arg_mismatch", NEG_APPLY_ARG,
                    ["error[TG02]", "does not satisfy interface 'Take'"]),
        case_reject("neg_receiver_mode_mismatch", NEG_RECV_MODE,
                    ["error[TG02]", "does not satisfy interface 'Show'"]),
        case_reject("neg_second_iface_missing", NEG_SECOND_IFACE,
                    ["error[TG02]", "does not satisfy interface 'Name'"]),
        # ── 错误例 / 登记面 / 上限钉子 ──
        case_reject("err_undefined_interface", ERR_UNDEFINED_IFACE,
                    ["error[N01]", "Undefined interface 'Nope'"]),
        case_unjudged("unjudged_native_arg", UNJUDGED_NATIVE),
        case_hard("limit_17_methods_rejected", LIMIT_METHODS,
                  ["exceeds max 16 methods"]),
        case_hard("limit_9_params_rejected", LIMIT_PARAMS,
                  ["exceeds max 8 params"]),
    ]

    passed = sum(ok)
    print(f"{passed}/{len(ok)} passed")
    return 0 if passed == len(ok) else 1


if __name__ == "__main__":
    raise SystemExit(main())
