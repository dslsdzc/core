#!/usr/bin/env python3
"""TODO #8 回归：≥18 形参静默误编译 + FuncInfo 形参槽区上界（2026-09-11 修复）。

背景（RED，修复前实测）：FuncInfo.param_types 是定长内嵌槽区（原 16 槽 =
OFF_FI_PARAM_TYPES 16 → 16+16×8 = 144 = OFF_FI_RETURN_TYPE），而 parser 的
「Store param types」写入无界 ⇒
  * 第 17 个形参写 OFF_FI_RETURN_TYPE（144）：形参类型值恰为 TY_INT=0 时「误
    打正着」（这正是 N=17 求和探针当时通过的原因）；返回类型非 int 的函数
    （如 -> bool，TY_BOOL=2）则被改写为 0 = TY_INT → 假 TF01 + 返回类型元数据错。
  * 第 18 个形参写 OFF_FI_AST_NODE（152）：TY_INT=0 把 ast_node 写成节点表
    **首项**（实测 = rt.cr:4:13 `g_rt_argc : int, mut;` 的 int 类型节点）⇒
    checker 读 fi_ast_node=0 → body=0 节点 data ⇒
      - `error[TF01] Function return type mismatch` 误归到 rt.cr:4:13；
      - .ccr 中该函数 name_idx=0（= 字符串表首项）/param_count=0、IR 体丢失
        （46 → 28 instrs）；
      - `corec build` 仍 rc=0，产物 SIGSEGV（实测 rc=139）。
修复：槽区扩至 MAX_FN_PARAMS=64（与 ast.cr 的 FuncInfo 镜像 [int; 64] 对齐，
并覆盖 ≥22 = 6 寄存器参 + 16 栈参的 >127B 栈清理形）+ 读写访问器护栏 +
超限签名硬错 P020（rc=1，绝不 rc=0）。

判据：N ∈ {17,18,22,64} 逐形参值全对；N=65 编译拒绝（rc=1 + error[P20]，
且不产出二进制）。
"""

import os
import resource
import subprocess
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"

# 退出码 = main 返回值低 8 位（见 test_slice_bounds.py 头注）；故求和形一律 < 256。


def _no_core_dump():
    # core_pattern 为 systemd-coredump 管道时，崩溃的陷阱程序会挂起——禁用 core dump。
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def _compile(source: str):
    """返回 (build_result, bin_path)；build_result 含 returncode/stdout/stderr。"""
    fd, src = tempfile.mkstemp(suffix=".cr")
    with os.fdopen(fd, "w") as f:
        f.write(source)
    out = src[:-3]
    built = subprocess.run(
        [str(COREC), "build", src, "-o", out, "--static"],
        capture_output=True, text=True, cwd=BASE, timeout=180,
    )
    return built, out, src


def _cleanup(*paths):
    for p in paths:
        try:
            os.unlink(p)
        except FileNotFoundError:
            pass


def build_and_run(source: str):
    built, out, src = _compile(source)
    try:
        if built.returncode != 0:
            return f"compile-failed(rc={built.returncode}): {built.stdout}{built.stderr}"
        return subprocess.run(
            [out], capture_output=True, text=True, timeout=10,
            preexec_fn=_no_core_dump,
        )
    finally:
        _cleanup(src, out, out + ".ccr")


def case_run(name, source, expect_rc):
    r = build_and_run(source)
    if isinstance(r, str):
        print(f"[FAIL] {name}: {r}")
        return False
    if r.returncode != expect_rc:
        print(f"[FAIL] {name}: expected rc {expect_rc}, got {r.returncode}")
        return False
    print(f"[PASS] {name}: rc={r.returncode}")
    return True


def case_reject(name, source, needle):
    built, out, src = _compile(source)
    try:
        if built.returncode == 0:
            print(f"[FAIL] {name}: expected compile rejection, got rc=0（静默误编译面复活）")
            return False
        if needle not in (built.stdout + built.stderr):
            print(f"[FAIL] {name}: rc={built.returncode} 但缺诊断 {needle!r}: {built.stdout}{built.stderr}")
            return False
        if os.path.exists(out):
            print(f"[FAIL] {name}: 拒绝编译却仍产出二进制 {out}")
            return False
        print(f"[PASS] {name}: rc={built.returncode} + {needle!r} + 无产物")
        return True
    finally:
        _cleanup(src, out, out + ".ccr")


def sum_src(n):
    """求和形（值 = 1..n 之和，必须 < 256 才可与退出码比较）。"""
    ps = ", ".join(f"a{i}: int" for i in range(n))
    args = ", ".join(str(i + 1) for i in range(n))
    body = " + ".join(f"a{i}" for i in range(n))
    return f"fn f({ps}) -> int {{\n    return {body};\n}}\nfn main() -> int {{ return f({args}); }}\n"


def per_arg_src(n):
    """逐形参值断言形（求和会掩盖错位/串位；任一错位返回该参数序号）。"""
    ps = ", ".join(f"a{i}: int" for i in range(n))
    args = ", ".join(str(i + 1) for i in range(n))
    checks = "\n".join(f"    if a{i} != {i + 1} {{ return {i + 1}; }}" for i in range(n))
    return f"fn f({ps}) -> int {{\n{checks}\n    return 0;\n}}\nfn main() -> int {{ return f({args}); }}\n"


def main():
    ok = [
        # 修复前 N=17 求和「碰巧通过」（int→int 时第 17 槽写入 TY_INT=0 = 原值）
        case_run("n17_args_pass", sum_src(17), 1 + 2 + 3 + 4 + 5 + 6 + 7 + 8 + 9 + 10 + 11 + 12 + 13 + 14 + 15 + 16 + 17),
        # 修复前 N=18 = 静默误编译（TF01 误归 + rc=0 + SIGSEGV 139）
        case_run("n18_args_pass_issue8", sum_src(18), sum(range(1, 19))),
        # 22 = 6 寄存器参 + 16 栈参（128B 栈清理，>127B 形；波 1 Task 5 Minor 4 收口条件）
        case_run("n22_stack_arg_form", per_arg_src(22), 0),
        # 上界内最大值（MAX_FN_PARAMS）
        case_run("n64_upper_bound", per_arg_src(64), 0),
        # 上界外：硬错 rc=1 + 诊断，绝不静默 rc=0
        case_reject("n65_rejected", per_arg_src(65), "too many parameters"),
    ]
    passed = sum(ok)
    print(f"{passed}/{len(ok)} passed")
    return 0 if passed == len(ok) else 1


if __name__ == "__main__":
    raise SystemExit(main())
