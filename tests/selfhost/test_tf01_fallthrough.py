#!/usr/bin/env python3
"""TF01 收口回归：函数体落空分析 + lits_copy 返回型（2026-09-13 修复）。

背景（RED，修复前实测；`check src/compiler` 长期恰 2 条 error[TF01]，被当作
「既有 red 划界」携带多批，同时卡住 check 作业/失败关闭工作流/P4 Task 2 的
corearch 清单）：

  ① 误报面（checker 落空分析缺失）：`fn f() -> int { loop { return 5; } }`
     ⇒ error[TF01]。根因 = 函数体返回检查取「块类型 = 末语句类型」，而 EXPR_LOOP
     推断恒 unit；但**无 break 的 loop 收尾**的体运行时永不走到函数尾（只从体内
     return 出），该 unit 不是缺返回值的证据。自源实测：`ty_memo_slot_no_grow`。
  ② 真错面（类型洗白，非误报）：`fn f() -> int { b := alloc(8); return b; }`
     ⇒ error[TF01]。类型模型里 `alloc` = `() -> string`（checker.cr
     `bi_add("alloc", TI_STR)`），声明 int 是真·类型洗白。自源实测：`lits_copy`。
     修法 = 声明改 string（连同消费面 `lits_contradictory_buf` 形参），
     **不是**放宽模型——本文件负控钉住该形态仍须拒。

修复：
  * checker.cr `stmt_cannot_fall_through`/`loop_body_has_break`/`seg_has_break`：
    落空分析（保守：只认确定**不产出值**的不可落空形态——无直系 break 的 loop /
    双分支皆不可落空且无 else 的 if / STMT·UNSAFE·嵌套 block 包裹；其余回「可落空」。
    `return` 明确**不判** divergence：它带返回值，其值类型正是站点 5 的被检对象，
    豁免它 = 洗白 lits_copy 型真错面。break 扫描在嵌套循环处截断（break 归内层），
    **未知形态按「可能有 break」处理 = fail-closed**，绝不放过真落空体）。
  * type_engine.cr `lits_copy` 返回型 int → string；`lits_contradictory_buf`
    形参 buf int → string（两个调用点传的都是 string：g_ty_lits / lits_copy）。

判据：正控（确定不可走完的体接受 rc=0 无 TF01）+ 负控（可落空的体仍拒
rc=1 恰 1 条 TF01）+ 端到端（接受面编译运行语义不变 rc=42）。
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


def _write(source):
    fd, src = tempfile.mkstemp(suffix=".cr")
    with os.fdopen(fd, "w") as f:
        f.write(source)
    return src


def _check(source):
    """返回 (rc, stdout+stderr)。"""
    src = _write(source)
    try:
        r = subprocess.run(
            [str(COREC), "check", src],
            capture_output=True, text=True, cwd=BASE, timeout=120,
        )
        return r.returncode, r.stdout + r.stderr
    finally:
        try:
            os.unlink(src)
        except FileNotFoundError:
            pass


def case_accept(name, source):
    rc, out = _check(source)
    tf01 = out.count("error[TF01]")
    if rc != 0 or tf01 != 0:
        print(f"[FAIL] {name}: 期望接受（rc=0 无 TF01），实测 rc={rc} TF01×{tf01}\n{out}")
        return False
    print(f"[PASS] {name}: rc=0 无 TF01")
    return True


def case_reject(name, source):
    rc, out = _check(source)
    tf01 = out.count("error[TF01]")
    if rc == 0 or tf01 != 1:
        print(f"[FAIL] {name}: 期望恰 1 条 TF01 拒绝，实测 rc={rc} TF01×{tf01}\n{out}")
        return False
    print(f"[PASS] {name}: rc={rc} TF01×1")
    return True


def case_run(name, source, expect_rc):
    """端到端：接受面编译 + 运行，退出码 = main 返回值低 8 位。"""
    src = _write(source)
    out_path = src[:-3]
    try:
        built = subprocess.run(
            [str(COREC), "build", src, "-o", out_path, "--static"],
            capture_output=True, text=True, cwd=BASE, timeout=180,
        )
        if built.returncode != 0:
            print(f"[FAIL] {name}: 编译失败 rc={built.returncode}\n{built.stdout}{built.stderr}")
            return False
        r = subprocess.run([out_path], capture_output=True, text=True, timeout=10,
                           preexec_fn=_no_core_dump)
        if r.returncode != expect_rc:
            print(f"[FAIL] {name}: 期望运行 rc={expect_rc}，实测 rc={r.returncode}")
            return False
        print(f"[PASS] {name}: 运行 rc={r.returncode}")
        return True
    finally:
        for p in (src, out_path, out_path + ".ccr"):
            try:
                os.unlink(p)
            except FileNotFoundError:
                pass


# ─── 正控：确定不能走完的体（修复前全报 TF01，修复后接受）───

POS_LOOP_IF_RETURN = """
fn f() -> int {
    loop {
        if 1 > 0 { return 5; }
    }
}
"""

POS_LOOP_BARE_RETURN = "fn f() -> int { loop { return 5; } }\n"

# 嵌套 loop：内层 break 归内层 ⇒ 外层无直系 break ⇒ 永不落空
POS_NESTED_LOOP = "fn f() -> int { loop { loop { break; } } }\n"

# if-else 双 diverges（两支皆无 break 的 loop ⇒ 两支类型均 unit ⇒ 修复前 TF01）
POS_IF_ELSE_DIVERGE = """
fn f(c: int) -> int {
    if c > 0 { loop { if c > 100 { return 1; } } }
    else { loop { return 2; } }
}
"""

# 语句包裹（`loop {...};` = EXPR_STMT(EXPR_LOOP)）
POS_STMT_WRAPPED = "fn f() -> int { loop { return 5; }; }\n"

# alloc 的模型一致声明（string）——与本组同族：真错面的「正确写法」
POS_ALLOC_STRING = "fn f() -> string { b := alloc(8); return b; }\n"

# 遍历分支的牙（各自钉住 break 扫描的一个下钻面——删除对应分支即本档转红）：
# · match 臂链（EXPR_ARM 链 ≠ 连续槽）：臂内无 break ⇒ 外 loop 不落空
POS_MATCH_NO_BREAK = """
fn f(x: int) -> int {
    loop {
        match x {
            0 => { return 1; },
            _ => { return 2; }
        }
    }
}
"""

# · 连续 wrapper 段（EXPR_ARRAY）+ LET + 索引
POS_ARRAY_NO_BREAK = """
fn f() -> int {
    loop {
        a := [1, 2, 3];
        if a[0] > 0 { return 1; }
    }
}
"""

# · 调用链（EXPR_CALL）与赋值/比较
POS_LOOP_WITH_CALL = """
fn g(x: int) -> int { return x; }
fn f() -> int {
    loop {
        if g(1) > 0 { return 5; }
    }
}
"""

# 登记边界（**本批显式登记，非静默**）：非落空体内 return 的**值类型**不核对——
# checker 现模型无「逐 return 核对」面（站点 5 只看块末类型），本条只把「无 break 的
# loop 收尾」从 TF01 误报中解放。修复前该形因「末语句类型 = unit」被**误拒**；修复后
# 按新口径接受（loop 永不落空）。若未来引入逐 return 核对，本条期望随之改为拒。
POS_BOUNDARY_NO_RETURN_VALUE_CHECK = "fn f() -> int { loop { return \"x\"; } }\n"

# ─── 负控：可落空的体（修复前报 TF01，修复后**必须仍拒**——静默接受洞的钉子）───

NEG_FALLTHRU = "fn f() -> int { 1 + 1; }\n"

NEG_LOOP_BREAK = "fn f() -> int { loop { if 1 > 0 { break; } } }\n"

NEG_IF_NO_ELSE = "fn f(c: int) -> int { if c > 0 { return 1; } }\n"

# match 臂内 break：臂 = EXPR_ARM 链（非连续槽）——漏检即此处从「拒」变「接受」
NEG_MATCH_BREAK = """
fn f(x: int) -> int {
    loop {
        match x {
            0 => { break; },
            _ => { }
        }
    }
}
"""

# 数组字面量（连续 wrapper 段）后 break——段扫描漏检即此处变「接受」
NEG_ARRAY_BREAK = """
fn f() -> int {
    loop {
        a := [1, 2, 3];
        if a[0] > 0 { break; }
    }
}
"""

# 嵌套 loop 之后仍有**直系** break ⇒ 可退出（截断只对「不下钻」，不得漏扫本层其余语句）
NEG_NESTED_THEN_BREAK = "fn f() -> int { loop { loop { break; } break; } }\n"

# while 保守面：不判 diverging（常量真条件不做分析）⇒ 落空 = 照旧 TF01。
# 条件用 `c == true` 而非裸标识符：`while c {` 会被 parser 当**结构体字面量**
# （parse_while_expr 缺 if 同款的 g_parse_no_struct_literal 守卫——既有面，本批不修，
# 见报告 §登记）。
NEG_WHILE = "fn f(c: bool) -> int { while c == true { break; } }\n"

# 真错面：alloc → int 声明（类型洗白）——修复**不得**把这条一起「修掉」
NEG_ALLOC_INT_WASH = "fn f() -> int { b := alloc(8); return b; }\n"

# ─── 端到端：接受面的语义不受影响 ───

RUN_LOOP_NO_BREAK = """
fn f() -> int {
    i : ., mut = 0;
    loop {
        i = i + 1;
        if i >= 3 { return i * 14; }
    }
}
fn main() -> int { return f(); }
"""


def main():
    ok = [
        case_accept("pos_loop_if_return", POS_LOOP_IF_RETURN),
        case_accept("pos_loop_bare_return", POS_LOOP_BARE_RETURN),
        case_accept("pos_nested_loop_inner_break", POS_NESTED_LOOP),
        case_accept("pos_if_else_diverge", POS_IF_ELSE_DIVERGE),
        case_accept("pos_stmt_wrapped", POS_STMT_WRAPPED),
        case_accept("pos_alloc_string", POS_ALLOC_STRING),
        case_accept("pos_match_no_break", POS_MATCH_NO_BREAK),
        case_accept("pos_array_no_break", POS_ARRAY_NO_BREAK),
        case_accept("pos_loop_with_call", POS_LOOP_WITH_CALL),
        case_accept("pos_boundary_no_return_value_check", POS_BOUNDARY_NO_RETURN_VALUE_CHECK),
        case_reject("neg_fallthru", NEG_FALLTHRU),
        case_reject("neg_loop_break", NEG_LOOP_BREAK),
        case_reject("neg_if_no_else", NEG_IF_NO_ELSE),
        case_reject("neg_match_break", NEG_MATCH_BREAK),
        case_reject("neg_array_break", NEG_ARRAY_BREAK),
        case_reject("neg_nested_then_break", NEG_NESTED_THEN_BREAK),
        case_reject("neg_while_conservative", NEG_WHILE),
        case_reject("neg_alloc_int_wash", NEG_ALLOC_INT_WASH),
        case_run("run_loop_no_break", RUN_LOOP_NO_BREAK, 42),
    ]
    passed = sum(ok)
    print(f"{passed}/{len(ok)} passed")
    return 0 if passed == len(ok) else 1


if __name__ == "__main__":
    raise SystemExit(main())
