#!/usr/bin/env python3
"""TODO #32 回归：`EXPR_LET` 站点**无任何兼容检查**（R2 P5 Task 6 修复）。

背景（RED，修复前实测——(a) 冻结基线 `/tmp/p5t0/base/corec`（pre-P5）；(b) 本批起点
`2342fd03…`；两代二进制同值 ⇒ 预存洞，非本批引入）：
`checker.cr` 的 `EXPR_LET` 分支（`infer_expr`）**只登记符号**：
    `ti := val_ti; if type_node >= 0 { ti = res_type_node(type_node); }`
——不做值/注解比对（该分支无 `type_equal`/`type_compat_strict` 调用；全仓 grep：`EC_TA_DECL`
（TA02）**定义零 raise**）。符号类型取**注解行** ⇒ 后端按注解行发射 = **静默错产物**：
  * `x : int = "s"`                     → check **rc=0**（值 = 字符串指针按 int 读）；
  * `x : [int;3] = s`（s 为切片）        → check **rc=0**；
  * `x : [int;4] = [1,2,3]`（异长常量档）→ check **rc=0**（比切片面更宽）；
  * `x : int? = 5; y : int = x`（可选流进窄槽）→ check **rc=0**（`T? ⊄ T` 的站点级拒绝
    在返回位/赋值位已落，本站点可被绕过）；
  * 全局同形：`g : int = "s";`           → check **rc=0**（全局符号在注册趟即取注解行）。

修复（R2 P5 Task 6）：声明位点加判定 = `type_compat_strict`（身份 + 长度档 + 可选目标注入）
+ `diag_type_incompatible`，码 = **TA02**（`EC_TA_DECL`，error-codes.md 既有槽位「变量声明
类型与初始值不符」——复用而非新码，见报告 §裁决）；参序 =（源 = 初始化值, 目标 = 注解行）。
两个调用点共用 `check_let_annot_compat`：① 局部 `EXPR_LET` 分支；② `check_global_let`
（全局初始化器——同形缺口，本任务**显式划界覆盖**）。豁免四条（各附理由，见该函数头注）：
无注解/auto/无初值 · 注解 dyn · 值 TI_NEVER（底部 + 错误标记=级联抑制）· 注解泛型形参。
硬错门：`EC_TA_DECL` 入 `main.cr` 硬名单 ⇒ `build` 亦拒绝（同 TS01-04/TK02 的「判定继续
= 产出静默错产物」类）。
report-only 开门依据：**全语料（72 档）零命中**（check rc 34×0/38×1 与 pre-P5 基线逐档同 +
诊断正文逐条同 + `check src/compiler` rc=0）——见 `.superpowers/sdd/p5-task6-report.md`。

判据口径（本套件）：拒绝例 = rc≠0 + 定位诊断 needle + **无产物**（bin 与 .ccr）+ 拒绝发生在
**前端**（不进入 `lower to ccr`/`save .ccr`/`generate ELF` 阶段）；正控例 = check rc=0 且
build+运行值正确（防「一律拒绝」的假牙）。
"""

import os
import resource
import subprocess
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"

# 拒绝必须早于这三个阶段（硬名单闸位于 `[4/5] type check` 之后、lower 之前）：
# 越过即 = 静默产物已生成（本检查的失败形态）。
STAGES = ("lower to ccr", "save .ccr", "generate ELF")


def _no_core_dump():
    # core_pattern 为 systemd-coredump 管道时，崩溃的陷阱程序会挂起——禁用 core dump。
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def _write(source: str):
    fd, src = tempfile.mkstemp(suffix=".cr")
    with os.fdopen(fd, "w") as f:
        f.write(source)
    return src


def _cleanup(*paths):
    for p in paths:
        try:
            os.unlink(p)
        except FileNotFoundError:
            pass


def _run(args, **kw):
    return subprocess.run(args, capture_output=True, text=True, cwd=BASE, timeout=180, **kw)


def case_run(name, source, expect_rc):
    """正控：build rc=0 + 运行值 = expect_rc（退出码 = main 返回值低 8 位）。"""
    src = _write(source)
    out = src[:-3]
    try:
        built = _run([str(COREC), "build", src, "-o", out, "--static"])
        if built.returncode != 0:
            print(f"[FAIL] {name}: compile-failed(rc={built.returncode}): {built.stdout}{built.stderr}")
            return False
        r = subprocess.run([out], capture_output=True, text=True, timeout=10,
                           preexec_fn=_no_core_dump)
        if r.returncode != expect_rc:
            print(f"[FAIL] {name}: expected rc {expect_rc}, got {r.returncode}")
            return False
        print(f"[PASS] {name}: rc={r.returncode}")
        return True
    finally:
        _cleanup(src, out, out + ".ccr")


def case_accept_check(name, source, expect_rc=0):
    """正控（不运行）：check rc = expect_rc（0 = 不误报）。"""
    src = _write(source)
    try:
        r = _run([str(COREC), "check", src])
        if r.returncode != expect_rc:
            print(f"[FAIL] {name}: expected check rc {expect_rc}, got {r.returncode}: "
                  f"{r.stdout}{r.stderr}")
            return False
        print(f"[PASS] {name}: check rc={r.returncode}")
        return True
    finally:
        _cleanup(src)


def case_reject(name, source, needles, cmd="build", forbid=STAGES, want_no_artifact=True,
                exact_diags=None):
    """拒绝面：rc≠0 + 全部 needle 命中 + 无产物 + 全部 forbid 阶段缺席。

    **必须**同时断言 needle（定位诊断文本）——仅断言 rc≠0 会被兜底式失败误当通过。
    forbid 钉「拒绝发生在**前端**」：护栏若落在读回侧/发射侧，静默面（check rc=0 与
    「按注解行发射的错产物」）并不因此消失。
    exact_diags：给出时 = 断言 `error[` 条数**恰为此数**（级联抑制例用）。
    """
    src = _write(source)
    out = src[:-3]
    try:
        args = ([str(COREC), "build", src, "-o", out, "--static"] if cmd == "build"
                else [str(COREC), "check", src])
        r = _run(args)
        blob = r.stdout + r.stderr
        if r.returncode == 0:
            print(f"[FAIL] {name}: expected rejection, got rc=0（静默面复活）: {blob}")
            return False
        for nd in needles:
            if nd not in blob:
                print(f"[FAIL] {name}: rc={r.returncode} 但缺诊断 {nd!r}: {blob}")
                return False
        for fd in forbid:
            if fd in blob:
                print(f"[FAIL] {name}: 拒绝晚于前端——输出含流水线阶段 {fd!r}")
                return False
        if exact_diags is not None:
            n = blob.count("error[")
            if n != exact_diags:
                print(f"[FAIL] {name}: expected exactly {exact_diags} diagnostics, got {n}: {blob}")
                return False
        if want_no_artifact and cmd == "build":
            for p in (out, out + ".ccr"):
                if os.path.exists(p):
                    print(f"[FAIL] {name}: 拒绝编译却仍产出 {p}")
                    return False
        print(f"[PASS] {name}: rc={r.returncode} + needles + 无产物/前端拒绝")
        return True
    finally:
        _cleanup(src, out, out + ".ccr")


# ─── 语料 ───
SLICE_SRC = ("fn h(s: [int]) -> int { x : [int;3] = s; return 0; }\n"
             "fn main() -> int { return h([1,2,3]); }\n")


def main():
    ok = [
        # ── 拒绝面（RED 三形态 + 同族扩展）──
        case_reject("let_int_string_build_rejected", 'fn main() -> int { x : int = "s"; return 0; }\n',
                    ["error[TA02]", "Variable declared as int, got string"]),
        case_reject("let_int_string_check_rejected", 'fn main() -> int { x : int = "s"; return 0; }\n',
                    ["error[TA02]"], cmd="check"),
        case_reject("let_slice_to_fixed_rejected", SLICE_SRC,
                    ["error[TA02]", "Array length constraint not satisfied"], cmd="check"),
        case_reject("let_arr_len_literal_rejected",
                    "fn main() -> int { x : [int;4] = [1,2,3]; return 0; }\n",
                    ["error[TA02]", "Array length constraint not satisfied"]),
        case_reject("let_optional_narrow_rejected",
                    "fn main() -> int { x : int? = 5; y : int = x; return y; }\n",
                    ["error[TA02]", "Variable declared as int, got int?"]),
        case_reject("let_int_from_struct_rejected",
                    "struct P { a: int }\nfn main() -> int { p := P { a: 1 }; i : int = p; return i; }\n",
                    ["error[TA02]"], cmd="check"),
        case_reject("let_struct_from_int_rejected",
                    "struct P { a: int }\nfn main() -> int { p : P = 5; return 0; }\n",
                    ["error[TA02]", "Variable declared as P, got int"], cmd="check"),
        # 全局声明面（同形缺口：注册趟即取注解行）——本任务显式划界覆盖
        case_reject("let_global_rejected", 'g : int = "s";\nfn main() -> int { return 0; }\n',
                    ["error[TA02]", "Variable declared as int, got string"]),
        # 批量声明（`a, b : int = ...`——每个名字一个 LET 节点，逐名判）
        case_reject("let_batch_rejected", 'fn main() -> int { a, b : int = 1, "s"; return a; }\n',
                    ["error[TA02]", "Variable declared as int, got string"], cmd="check"),
        # 丢弃名（`_ : int = ...`）同样受判
        case_reject("let_discard_rejected", 'fn main() -> int { _ : int = "s"; return 0; }\n',
                    ["error[TA02]"], cmd="check"),
        # ── 级联抑制（值 = TI_NEVER 错误标记）：只发原诊断，不叠 TA02 ──
        case_reject("let_error_marker_no_cascade_ident",
                    "fn main() -> int { x : int = nosuchname; return 0; }\n",
                    ["error[N01]"], cmd="check", forbid=(), exact_diags=1),
        case_reject("let_error_marker_no_cascade_call",
                    "fn main() -> int { x : int = nosuchfn(); return 0; }\n",
                    ["error[N06]"], cmd="check", forbid=(), exact_diags=1),
        # ── 正控：合法注解 / 无注解 / auto / 泛型 / 可选注入 / 无初值 / 索引形态 ──
        case_run("let_exact_ok", "fn main() -> int { x : int = 5; return x; }\n", 5),
        case_run("let_no_annot_ok",
                 "fn main() -> int { x := 5; y : . = 6; z : auto = 7; return x + y + z; }\n", 18),
        case_run("let_generic_param_ok",
                 "fn f[T](v: T) -> T { x : T = v; return x; }\n"
                 "fn main() -> int { return f(3); }\n", 3),
        case_run("let_generic_array_ok",
                 "fn f[T](v: T) -> T { x : [T; 2] = [v, v]; return x[0]; }\n"
                 "fn main() -> int { return f(4); }\n", 4),
        case_run("let_optional_target_injection_ok",
                 "fn main() -> int { x : int? = 5; y : int? = None; return 0; }\n", 0),
        case_accept_check("let_dyn_annotation_ok", "fn main() -> int { x : dyn = 5; return 0; }\n"),
        case_accept_check("let_no_init_ok", "fn main() -> int { x : int; return 0; }\n"),
        case_run("let_slice_ann_from_literal_ok",
                 "fn f(s: [int]) -> int { x : [int] = [1,2,3]; return x[0]; }\n"
                 "fn main() -> int { return f([1]); }\n", 1),
        case_run("let_fixed_ann_exact_literal_ok",
                 "fn f(s: [int]) -> int { x : [int;3] = [1,2,3]; return s[0]; }\n"
                 "fn main() -> int { return f([7]); }\n", 7),
        case_run("let_named_and_string_ok",
                 'struct P { a: int }\n'
                 'fn main() -> int { p := P { a: 1 }; q : P = p; s := "hi"; t : string = s; return q.a; }\n',
                 1),
        case_accept_check("let_generic_element_param_ok",
                          "fn f[T](v: T) -> T { x : [T] = [v]; return x[0]; }\n"
                          "fn main() -> int { return f(2); }\n", expect_rc=0),
        # 泛型形参注解**不判**（豁免④）——与返回位点既有策略同款同证：`return 5` 在
        # `-> T` 函数体内今天即 rc=0（返回位点的 TYP_GENERIC_PARAM 豁免）⇒ 声明位点同策略。
        case_accept_check("let_generic_param_annotation_not_judged",
                          "fn f[T](v: T) -> T { return 5; }\n"          # 返回位点（既有策略）
                          "fn g[T](v: T) -> T { x : T = 5; return x; }\n"  # 声明位点（本检查同策略）
                          "fn main() -> int { return 0; }\n", expect_rc=0),
    ]
    passed = sum(ok)
    print(f"{passed}/{len(ok)} passed")
    return 0 if passed == len(ok) else 1


if __name__ == "__main__":
    raise SystemExit(main())
