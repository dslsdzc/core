#!/usr/bin/env python3
"""R2 P3 Task 4：联合/可选（`T?` = `T ∪ null`；退役内建 Option 注册）行为覆盖集。

判据（语义见 docs/superpowers/plans/2026-09-11-r2-p3-capabilities.md Task 4 +
docs/superpowers/specs/2026-09-10-type-interface-unification-design.md §5.4）：

  正（**解释器 + ELF 双路径同值**）：`T ⊆ T?`（裸值 `return 5` 入 `int?` 返回位）/
      `null ⊆ T?`（`return None`）/ `Some(1)` 入 `int?` / `T?` 形参位 / `?` 解包回 T /
      `Some(x)` 与 `None` 的 match 两臂（运行时 tag 分派）
  负：`T? ⊄ T`（`fn f(x: int?) -> int { return x; }` ⇒ TF01——**方向性**：可选不是 T 的子类型）/
      `Option` 名退役（`Option[int]` 作类型 = 未定义泛型应用 rc=1——退役前该名由内建注册）
  硬门：`T?` 的 match 缺臂 ⇒ TM03 rc=1 + 具体反例名（'None' / 'Some'）+ 无产物
  登记：载荷**类型节点列**（T0 交接 ①）：`--verify-evp-nodes` 断言每槽有节点（bad=0），
      并数出裸码列丢失真实类型的槽数（collapses>0 = 节点列携带的信息量；旧布局裸码把
      非基型塌缩为 0 = TY_INT）
  表示面登记（如实，非本任务面）：`Some`/`None` 的运行时形态 = 枚举对象（IR_MAKE_ENUM +
      tag），裸值入 T? 仍是裸值——两形态在同一次 match 里各自正确（本套件两例分别钉），
      但「T? 值表示统一」不在本任务 Files 面内（未覆盖面，见任务报告）。
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
    """返回 (result, out_path, src_path)；cmd = build（ELF 产物）| check（仅前端）。"""
    fd, src = tempfile.mkstemp(suffix=".cr")
    with os.fdopen(fd, "w") as f:
        f.write(source)
    out = src[:-3]
    if cmd == "build":
        args = [str(COREC), "build", src, "-o", out, "--static"]
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
    """返回 (compile_result, run_result|None)。"""
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
    """解释器路径（共享同一 run_frontend ⇒ 同一判定面）；rc = main 返回值。"""
    return subprocess.run(
        [str(COREC), "run", source], capture_output=True, text=True, cwd=BASE, timeout=180,
    )


def case_dual(name, source, expect_rc):
    """**双路径**（ELF 产物 + 解释器）同值断言——本任务主判据形。

    ⚠️ 附加 `check` rc=0 断言（**必要**，实测教训）：本仓库多数类型诊断（TF01/TA01…）是
    **软诊断**——`build` 路径 rc=0 + 产物照出，仅 `check` 因「有诊断即 rc=1」暴露。只断
    「build+run rc」会让「判定面整体失效」的突变**照样全绿**（M1 实测：注入失效后
    plain_value_into_optional 仍 PASS）。故正例 = 三路同证：check rc=0 ∧ build/run rc=N ∧ interp rc=N。
    """
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


def case_reject(name, source, needles, cmd="build"):
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


def case_evp(name, source, needles):
    """载荷类型节点列**入库断言**（隐藏调试通道 `--verify-evp-nodes`；T0 交接 ① 的判据）。"""
    r, out, src = _compile(source, cmd="check", extra=["--verify-evp-nodes"])
    try:
        if r.returncode != 0:
            print(f"[FAIL] {name}: verify rc={r.returncode}: {r.stdout}{r.stderr}")
            return False
        text = r.stdout + r.stderr
        for n in needles:
            if n not in text:
                print(f"[FAIL] {name}: 缺 {n!r}: {text}")
                return False
        print(f"[PASS] {name}: rc=0 + {needles!r}")
        return True
    finally:
        _cleanup(src, out, out + ".ccr")


# ── 源形 ──────────────────────────────────────────────────────────────

# 裸值入 T?（`int ⊆ int ∪ null`）：判定点注入面（type_compat_strict 的可选目标分支）
PLAIN_INTO_OPT = """fn g() -> int? { return 5; }
fn main() -> int { return 42; }
"""
NONE_INTO_OPT = """fn g() -> int? { return None; }
fn main() -> int { return 42; }
"""
SOME_INTO_OPT = """fn g() -> int? { return Some(1); }
fn main() -> int { return 42; }
"""
# T? 形参位 + `?` 解包（EXPR_TRY 按类型项结构）
UNWRAP_SRC = """fn f(x: int?) -> int { return x?; }
fn main() -> int { return f(3); }
"""
# 运行时两形态：Some 值（枚举对象 + tag）与 None
SOME_FLOW = """fn g() -> int? { return Some(1); }
fn main() -> int { v := g(); return match v { Some(x) => x + 100, None => 0, }; }
"""
NONE_FLOW = """fn g() -> int? { return None; }
fn main() -> int { v := g(); return match v { Some(x) => x + 100, None => 7, }; }
"""


def main():
    ok = [
        # 正：裸值入 T? 返回位（旧判定：TF01 拒绝——joint 语义落地后放行；双路径）
        case_dual("plain_value_into_optional", PLAIN_INTO_OPT, 42),
        # 正：None 入 T? 返回位（`null ⊆ T?`；双路径）
        case_dual("none_into_optional", NONE_INTO_OPT, 42),
        # 正：Some(1) 入 T?（类型项相等；双路径）
        case_dual("some_into_optional", SOME_INTO_OPT, 42),
        # 正：T? 形参位 + `?` 解包回 T（双路径）
        case_dual("unwrap_optional_in_param", UNWRAP_SRC, 3),
        # 正：Some 值流经 match 的 Some 臂（运行时 tag 分派；双路径）
        case_dual("some_flow_some_arm", SOME_FLOW, 101),
        # 正：None 值流经 match 的 None 臂（双路径）
        case_dual("none_flow_none_arm", NONE_FLOW, 7),
        # 负：T? ⊄ T（方向性——可选**不是**裸类型的子类型；钉死 soundness 面）。
        # 口径：TF01 是**软诊断**（本仓库硬门名单只含 R002/TK05-06/TS01-04/TK02/TM03，
        # build 路径 rc=0 + 产物照出）⇒ 判据走 `check`（有诊断即 rc=1）+ 措辞断言。
        case_reject("optional_not_assignable_to_plain",
                    "fn f(x: int?) -> int { return x; }\nfn main() -> int { return f(1); }\n",
                    ["error[TF01]"], cmd="check"),
        # 硬门：T? 的 match 缺 None 臂 ⇒ TM03 + 具体反例名（'None'）+ 无产物
        case_reject("optional_match_missing_none",
                    "fn main() -> int { x: int? = Some(3); return match x { Some(v) => v, }; }\n",
                    ["error[TM03]", "missing variant 'None'"]),
        # 硬门：T? 的 match 缺 Some 臂 ⇒ TM03 + 'Some'
        case_reject("optional_match_missing_some",
                    "fn main() -> int { x: int? = Some(3); return match x { None => 0, }; }\n",
                    ["error[TM03]", "missing variant 'Some'"]),
        # 正：通配臂吸收 ⇒ 穷尽（零诊断）
        case_dual("optional_match_wildcard",
                  "fn main() -> int { x: int? = None; return match x { _ => 9, }; }\n", 9),
        # 负：退役内建 Option 注册——`Option` 不再是语言内建类型名。
        # 旧行为：collect_decls 自动注册命名行 ⇒ `Option[int]` 零诊断通过；新行为：该名未声明
        # ⇒ `Undefined type in generic application`（EC_N_GENERIC_TYPE，**软诊断**：rc 面
        # build 仍 0——故判据走 `check` 的 rc=1 + 措辞）。用户自声明 `enum Option` 时按普通
        # 枚举解析（Task 3 的 p20 语义保持，见 test_match_exhaust.py）。
        case_reject("builtin_option_name_retired",
                    "fn f(x: Option[int]) -> int { return 0; }\nfn main() -> int { return f(0); }\n",
                    ["Undefined type in generic application"], cmd="check"),
        # 登记：载荷类型节点列入库（每槽有节点 = bad=0）+ 裸码列丢失真实类型的信息量
        # （`V(S)` 命名类型载荷与 `Some(T)` 泛型形参载荷在裸码列都塌缩为 0 = TY_INT）
        case_evp("payload_type_nodes_recorded",
                 "struct S { a: int }\nenum E { V(S), W(int) }\nenum Opt[T] { N, Some(T) }\n"
                 "fn main() -> int { return 0; }\n",
                 ["[enum-payload-verify]", "slots=3", "collapses=2", "bad=0"]),
    ]
    passed = sum(1 for x in ok if x is True)
    print(f"{passed}/{len(ok)} passed")
    return 0 if passed == len(ok) else 1


if __name__ == "__main__":
    raise SystemExit(main())
