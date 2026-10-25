#!/usr/bin/env python3
"""R2 P2b Task 4/5：接口查表接线的行为回归（checker.cr ← iface_registry 的 ops 列）。

Task 4 接线点（三层门形状，改动前原文逐字等价）：
  · 算术门 `checker.cr:1959`（ANY：至少一侧许可即通过；改动前 = `lt != TI_INT && lt != TI_DEX
    && rt != TI_INT && rt != TI_DEX`）——表的 ADD..MOD 格**只含 int/dex**；
  · 逻辑门 `checker.cr:1969`（ALL：每侧都须许可；改动前 = `(lt≠bool ∧ lt≠int) ∨ (rt≠bool ∧ rt≠int)`）
    ——表的 AND/OR 格恰 {int, bool}（**dex 不在内**）；
  · 条件门 `checker.cr`（ONE / IP_COND）：`if` 与 `while` 都只收 **bool**。

Task 5 接线点（`t5_*` 段；**唯一** = 索引面兜底拒绝 → `IP_INDEX` 查表）：门体即原
`EC_TK_INDEX` 调用（码/文案/位置逐字不变），可达集 = 数组/切片/串三个**结果分支**之后的落空集，
与表的拒绝集逐行相等（selftest `idx.gate_deny_covers_fallback` 全类型行枚举钉死）。字段
（`IP_FIELD`）/转换（`IP_AS`）/dyn（`IP_METHOD`）三面**未接线**：前两面在现状**无任何拒绝路径**
（EXPR_FIELD/EXPR_AS 全形 rc=0，门会退化成恒真空转）；dyn 面的拒绝谓词是**逐具体行的方法表
成员判定**（int/string 候选行今日也发 N08），类级门会抑制它 = 放宽。三者均为 P3 收紧旋钮。

判据口径 = **保语义**（零行为变化）：正控 rc=0 / 负控 rc=1 + 错误码逐字不变 / 登记面（现状
宽松面）断言「不动」。**关键守卫**（本批最易放宽的两条，见计划 Task 4 的「结构事实」）：
把 PTR/STRING 填进算术门的 ADD 格 ⇒ ANY 门下 `permits(PTR,ADD)=1` 足以放行 ⇒ `*T + *T`、
`"a" - "b"` 从 error[TB01] 变静默 —— 本文件的负控段把这两条钉死。

Task 6 段（`t6_*`；`res_type_node`/`res_call_type` 双份 TY→TI 映射合一 → 单表 `ty_code_to_ti`）：
8 个站点的**域逐站不同**（注册链缺 CHAR/NEVER/7、extern 链含 CHAR、形参链缺 NEVER、
iface 返回链值域是 TY_* 码…），且这些域差异是**载荷**的（`fn f() -> char` 在注册链 = unit、
在 extern 链 = char）。本段用「逐条 (码,行号) 多元集」把差异钉死，防后续按「表 + 尾回落」
一刀切（= 静默改判定）；两表**唯一语义差 = NEVER 格**（res_call_type 侧 = unit，探针实测可达）。

登记面（现状宽松 = P3 收紧清单的预备队，本批**不得**顺手改）：
  · 算术门「任一侧数值即可」：`1 + [int;3]` / `"a" * 2` 静默为 int（无诊断）；
  · 一元透传：`!arr` / `-"a"` / `*x`（x: int）原样返回操作数类型，不校验；
  · 比较不校验操作数：`"a" == 1` 恒 TI_BOOL；
  · `as` 恒等透传；字段落空静默（`x.a`，x 非 struct）——后两条属 Task 5 面。
"""

import os
import re
import resource
import subprocess
import tempfile
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
COREC = BASE / "build" / "corec"


def _no_core_dump():
    # core_pattern 为 systemd-coredump 管道时，崩溃/信号相关的子进程会挂起——禁用 core dump。
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def _check(source: str):
    fd, path = tempfile.mkstemp(suffix=".cr", dir="/tmp")
    with os.fdopen(fd, "w") as f:
        f.write(source)
    try:
        return subprocess.run(
            [str(COREC), "check", path], capture_output=True, text=True,
            cwd=BASE, timeout=120, preexec_fn=_no_core_dump,
        )
    finally:
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass


def case_ok(name, source):
    """正控 / 登记面：rc=0 且零 error[...] 诊断。"""
    r = _check(source)
    out = r.stdout + r.stderr
    if r.returncode != 0 or "error[" in out:
        print(f"[FAIL] {name}: expected rc=0 + no diagnostics, got rc={r.returncode}\n{out}")
        return False
    print(f"[PASS] {name}: rc=0")
    return True


def case_reject(name, source, code):
    """负控：rc=1 + 诊断码逐字不变（码 = 改动前的码，接线不得改判定/文案路径）。"""
    r = _check(source)
    out = r.stdout + r.stderr
    if r.returncode == 0:
        print(f"[FAIL] {name}: expected rejection, got rc=0（静默放行 = 放宽面复活）\n{out}")
        return False
    if ("error[" + code + "]") not in out:
        print(f"[FAIL] {name}: rc={r.returncode} 但缺 error[{code}]\n{out}")
        return False
    print(f"[PASS] {name}: rc={r.returncode} + error[{code}]")
    return True


def case_diag_lines(name, source, expect):
    """Task 6 站点域判据：rc + **逐条 (码, 行号)** 多元集相等。

    为什么需要行号：TY→TI 的 8 个站点里有 6 处是**内联链**（注册/形参/返回/iface 返回），
    它们对同一份源码可能各报一条同码诊断——「报了几条、报在哪一行」正是区分「哪一站点产出了
    什么类型」的观测量（只数码会两说）。
    """
    r = _check(source)
    out = r.stdout + r.stderr
    got = sorted(re.findall(r"error\[([A-Z0-9]+)\]:[^\n]*\n --> (\d+):", out))
    want = sorted((c, str(l)) for c, l in expect)
    if r.returncode != 1 or got != want:
        print(f"[FAIL] {name}: rc={r.returncode} got={got} want={want}\n{out}")
        return False
    print(f"[PASS] {name}: rc=1 + {got}")
    return True


def main():
    ok = []
    # ─── 正控（许可面）：三个门各自的许可路径 ───
    ok.append(case_ok("pos_int_add", "fn main() -> int:\n    x := 1 + 2\n    return x\n"))
    ok.append(case_ok("pos_int_mod", "fn main() -> int:\n    x := 7 % 3\n    return x\n"))
    ok.append(case_ok("pos_dex_add", "fn main() -> int:\n    d := 1.5 + 1\n    return 0\n"))
    ok.append(case_ok("pos_dex_dominates", "fn main() -> int:\n    d := 1 + 1.5\n    return 0\n"))
    ok.append(case_ok("pos_str_concat", 'fn main() -> int:\n    s := "a" + "b"\n    return 0\n'))
    ok.append(case_ok("pos_str_concat_right",
                      'fn main() -> int:\n    s := 1 + "b"\n    return 0\n'))
    ok.append(case_ok("pos_ptr_add_int",
                      "fn main() -> int:\n    x : ., mut = 5\n    p := &x\n    q := p + 1\n    return 0\n"))
    ok.append(case_ok("pos_int_add_ptr",
                      "fn main() -> int:\n    x : ., mut = 5\n    p := &x\n    q := 1 + p\n    return 0\n"))
    ok.append(case_ok("pos_ptr_diff",
                      "fn main() -> int:\n    x : ., mut = 5\n    p := &x\n    q := &x\n    d := p - q\n    return d\n"))
    ok.append(case_ok("pos_str_index", 'fn main() -> int:\n    s := "ab"\n    c := s[0]\n    return c\n'))
    ok.append(case_ok("pos_tuple_field",
                      "fn main() -> int:\n    t := (1, 2)\n    a := t . 0\n    return a\n"))
    ok.append(case_ok("pos_logic_int", "fn main() -> int:\n    b := 1 && true\n    return 0\n"))
    ok.append(case_ok("pos_logic_bool", "fn main() -> int:\n    b := true && false\n    return 0\n"))
    ok.append(case_ok("pos_cond_if_bool", "fn main() -> int:\n    if true:\n        return 1\n    return 0\n"))
    ok.append(case_ok("pos_cond_if_not_str_eq",
                      'fn main() -> int:\n    if !str_eq("a", "b"):\n        return 1\n    return 0\n'))
    ok.append(case_ok("pos_cond_while_bool",
                      "fn main() -> int:\n    n : ., mut = 0\n    while n < 3:\n        n = n + 1\n    return n\n"))
    ok.append(case_ok("pos_range_int", "fn main() -> int:\n    b := 1..3\n    return 0\n"))
    # ─── 负控（拒绝面，码逐字不变）───
    # **关键守卫 1**：`*T + *T` —— 门集合若含 PTR（ANY 语义）即静默放行
    ok.append(case_reject("neg_ptr_add_ptr",
                          "fn main() -> int:\n    x : ., mut = 5\n    p := &x\n    q := &x\n    r := p + q\n    return 0\n", "TB01"))
    # **关键守卫 2**：`"a" - "b"` —— 串拼接许可在 :1946 早退（只认 OP_ADD），门集合若含 STRING 即放行
    ok.append(case_reject("neg_str_sub_str",
                          'fn main() -> int:\n    s := "a" - "b"\n    return 0\n', "TB01"))
    ok.append(case_reject("neg_str_mul_str",
                          'fn main() -> int:\n    s := "a" * "b"\n    return 0\n', "TB01"))
    ok.append(case_reject("neg_arr_add_arr",
                          "fn main() -> int:\n    a := [1,2,3]\n    b := [4,5,6]\n    c := a + b\n    return 0\n", "TB01"))
    ok.append(case_reject("neg_char_add_char",
                          "fn main() -> int:\n    c := 'a' + 'b'\n    return 0\n", "TB01"))
    ok.append(case_reject("neg_logic_dex",
                          "fn main() -> int:\n    b := 1.5 && true\n    return 0\n", "TC01"))
    ok.append(case_reject("neg_logic_dex_or",
                          "fn main() -> int:\n    b := 1.5 || false\n    return 0\n", "TC01"))
    ok.append(case_reject("neg_logic_str",
                          'fn main() -> int:\n    b := "a" && true\n    return 0\n', "TC01"))
    ok.append(case_reject("neg_cond_if_arr",
                          "fn main() -> int:\n    if [1,2,3]:\n        return 1\n    return 0\n", "TC01"))
    ok.append(case_reject("neg_cond_if_dex",
                          "fn main() -> int:\n    if 1.5:\n        return 1\n    return 0\n", "TC01"))
    ok.append(case_reject("neg_cond_if_int",
                          "fn main() -> int:\n    if 1:\n        return 1\n    return 0\n", "TC01"))
    ok.append(case_reject("neg_cond_if_int_var",
                          "fn main() -> int:\n    x := 1\n    if x:\n        return 1\n    return 0\n", "TC01"))
    # `if` 与 `while` 现在同一条 bool-only 规则；while 仍用 TC04。
    ok.append(case_reject("neg_cond_while_int",
                          "fn main() -> int:\n    while 1:\n    return 0\n", "TC04"))
    ok.append(case_reject("neg_cond_while_dex",
                          "fn main() -> int:\n    while 1.5:\n    return 0\n", "TC04"))
    ok.append(case_reject("neg_cond_while_arr",
                          "fn main() -> int:\n    while [1,2,3]:\n    return 0\n", "TC04"))
    ok.append(case_reject("neg_range_str_ends",
                          'fn main() -> int:\n    b := "a".."b"\n    return 0\n', "TB01"))
    # ─── 登记面（现状宽松；本批断言「不动」= 保留为表的全许可格，P3 才收紧）───
    ok.append(case_ok("reg_int_add_arr",
                      "fn main() -> int:\n    a := [1,2,3]\n    c := 1 + a\n    return 0\n"))
    ok.append(case_ok("reg_str_mul_int", 'fn main() -> int:\n    s := "a" * 2\n    return 0\n'))
    ok.append(case_ok("reg_arr_index_bool",
                      "fn main() -> int:\n    a := [1,2,3]\n    c := a[true]\n    return 0\n"))
    ok.append(case_ok("reg_not_arr",
                      "fn main() -> int:\n    a := [1,2,3]\n    b := !a\n    return 0\n"))
    ok.append(case_ok("reg_neg_str", 'fn main() -> int:\n    s := "a"\n    t := -s\n    return 0\n'))
    ok.append(case_ok("reg_deref_int",
                      "fn main() -> int:\n    x := 5\n    y := *x\n    return 0\n"))
    ok.append(case_ok("reg_cmp_unchecked",
                      'fn main() -> int:\n    b := "a" == 1\n    return 0\n'))
    ok.append(case_ok("reg_as_identity",
                      'fn main() -> int:\n    s := "a"\n    x := s as int\n    return 0\n'))

    # ─── R2 P2b Task 5：容器面（**唯一接线点** = 索引兜底拒绝 → IP_INDEX 查表）───
    # 接线口径 = 与改动前**一字等价**：门体即原 `EC_TK_INDEX` 调用；可达集（= 三个结果分支
    # 之后的落空集）与表的拒绝集逐行相等（selftest `idx.gate_deny_covers_fallback` 钉死）。
    # 字段/转换/dyn 三面**未接线**（无拒绝路径 / 谓词不是类级位）——本段以「现状不动」钉住，
    # 防后续把 `IP_FIELD`/`IP_METHOD`/`IP_AS` 硬接成收紧或放宽。
    S5 = "struct S:\n    a: int\n"
    # 正控：三个结果分支（数组→元素 / 切片→元素 / 数组 range→切片）
    ok.append(case_ok("t5_pos_arr_index",
                      "fn main() -> int:\n    a := [1,2,3]\n    c := a[1]\n    return c\n"))
    ok.append(case_ok("t5_pos_slice_index",
                      "fn main() -> int:\n    a := [1,2,3]\n    s := a[0..2]\n    c := s[1]\n    return c\n"))
    ok.append(case_ok("t5_pos_arr_range",
                      "fn main() -> int:\n    a := [1,2,3]\n    s := a[1..2]\n    return 0\n"))
    # 负控：非容器行一律 TK01（码/文案逐字不变）——给表的 IP_INDEX 加任一非容器类即静默放行
    ok.append(case_reject("t5_neg_index_int",
                          "fn main() -> int:\n    x := 1\n    c := x[0]\n    return 0\n", "TK01"))
    ok.append(case_reject("t5_neg_index_bool",
                          "fn main() -> int:\n    x := true\n    c := x[0]\n    return 0\n", "TK01"))
    ok.append(case_reject("t5_neg_index_dex",
                          "fn main() -> int:\n    x := 1.5\n    c := x[0]\n    return 0\n", "TK01"))
    ok.append(case_reject("t5_neg_index_char",
                          "fn main() -> int:\n    c := 'a'[0]\n    return 0\n", "TK01"))
    ok.append(case_reject("t5_neg_index_ptr",
                          "fn main() -> int:\n    x : ., mut = 5\n    p := &x\n    c := p[0]\n    return 0\n", "TK01"))
    ok.append(case_reject("t5_neg_index_named",
                          S5 + "fn main() -> int:\n    s := S { a= 1 }\n    c := s[0]\n    return 0\n", "TK01"))
    ok.append(case_reject("t5_neg_index_tuple",
                          "fn main() -> int:\n    t := (1,2)\n    c := t[0]\n    return 0\n", "TK01"))
    ok.append(case_reject("t5_neg_index_dyn",
                          "fn main() -> int:\n    d : dyn = 5\n    c := d[0]\n    return 0\n", "TK01"))
    # 登记面（现状静默；本批断言「不动」= P3 收紧面）：
    #   range 索引的非数组落空 `return TI_UNIT` 无诊断（表 IP_INDEX_RANGE **未接线**——门恒真空转）
    ok.append(case_ok("t5_reg_str_range",
                      'fn main() -> int:\n    s := "ab"\n    t := s[0..1]\n    return 0\n'))
    ok.append(case_ok("t5_reg_slice_range",
                      "fn main() -> int:\n    a := [1,2,3]\n    s := a[0..2]\n    t := s[0..1]\n    return 0\n"))
    ok.append(case_ok("t5_reg_int_range",
                      "fn main() -> int:\n    x := 1\n    t := x[0..1]\n    return 0\n"))
    #   字段落空静默（EXPR_FIELD 全形 rc=0：非 struct / 越界元组位 / 指针·数组·dyn 操作数）
    ok.append(case_ok("t5_reg_int_field",
                      "fn main() -> int:\n    x := 1\n    c := x.a\n    return 0\n"))
    ok.append(case_ok("t5_reg_tuple_field_oob",
                      "fn main() -> int:\n    t := (1,2)\n    c := t . 5\n    return 0\n"))
    ok.append(case_ok("t5_reg_ptr_field",
                      S5 + "fn main() -> int:\n    s := S { a= 1 }\n    p := &s\n    c := p.a\n    return 0\n"))
    ok.append(case_ok("t5_reg_dyn_field",
                      "fn main() -> int:\n    d : dyn = 5\n    c := d.a\n    return 0\n"))
    #   dyn 面：现状**有**拒绝路径（逐具体行的方法表判定）——int/string 候选行也发 N08；
    #   类级 IP_METHOD 门会**抑制**它们（= 放宽）⇒ 本段把现有 N08 钉红
    ok.append(case_reject("t5_dyn_int_method_missing",
                          "fn main() -> int:\n    d : dyn = 5\n    d.nosuch()\n    return 0\n", "N08"))
    ok.append(case_reject("t5_dyn_str_method_missing",
                          'fn main() -> int:\n    d : dyn = "a"\n    d.nosuch()\n    return 0\n', "N08"))
    ok.append(case_reject("t5_dyn_struct_method_missing",
                          S5 + "fn main() -> int:\n    s := S { a= 1 }\n    d : dyn = s\n    d.nosuch()\n    return 0\n",
                          "N08"))

    # ─── R2 P2b Task 6：res_type_node/res_call_type 双份 TY→TI 映射合一（单表 ty_code_to_ti）───
    # 口径 = **保语义（零行为变化）**：8 个站点的**域逐站不同且载荷**（探针组 F/R/B/A/C，见报告）——
    # 本段把「站点域差异」钉死，防后续按「表 + 尾回落」一刀切（那会把 S1 的 char/never 从 unit
    # 静默改成 char/never、把 S3 的 char 从 char 改成 unit 等）。行号 = 诊断所在行（区分站点）。
    #   ① 两表基型分支（res_type_node / res_call_type）
    ok.append(case_ok("t6_R_dyn_decl",
                      "fn main() -> int:\n    x : dyn = 5\n    return 0\n"))
    # res_type_node 的 7 码格 ⇒ TI_DYN（dyn 方法分派据此走 N08 路径）
    ok.append(case_reject("t6_R_dyn_cell_live",
                          "fn main() -> int:\n    x : dyn = 5\n    x.nosuch()\n    return 0\n", "N08"))
    ok.append(case_ok("t6_R_char_ret",
                      "fn f() -> char:\n    return 'a'\nfn main() -> int:\n    c := f()\n    return 0\n"))
    #   ② **两表唯一差异格 = NEVER**：res_call_type 对调用位点的 `-> never` 返回 unit（现状），
    #      res_type_node 对类型位 `x : never = 1` 映 TI_NEVER——后者由 t6_S1/S3/S4/S6 的排除面互为镜像
    # TF01 收口（2026-09-13）：`fn g[T](a: T) -> never { loop { } }` 体以**无 break 的 loop**
    # 收尾 ⇒ 不落空 ⇒ 站点 5 不再误报 TF01@1（该函数语义上确为 never 函数）。本用例的关注面 =
    # 调用位点（`never` 在调用位点被当 unit ⇒ @raw_int 报 TF07@2），该面**不变**。
    #   ③ 同族 6 处内联链：**逐站域**（同一形在不同站点产出不同类型 ⇒ 域差异载荷）
    #      V4 统一：普通注册链保留 CHAR（与 check_func 的返回行一致），因此
    #      `fn f() -> char` 的调用点不再退化成 unit。旧的「S1 缺 CHAR ⇒
    #      f 的 return 'a' 报 TF01@2」钉子由本正控取代；NEVER 仍按站域保留，
    #      证据面 = t6_S1_never_unit / S3 / S4 / S5。
    ok.append(case_ok("t6_S1_char_covered",
                      "fn f() -> char:\n    return 'a'\nfn main() -> char:\n    x := f()\n    return x\n"))
    ok.append(case_ok("t6_S3_char_covered",
                      "extern fn f() -> char\nfn main() -> char:\n    x := f()\n    return x\n"))
    # TF01 收口（2026-09-13）：TF01@1 = 同为「无 break 的 loop 收尾」误报面（已修）。
    # R2 P6 Task 4a（E-11）**重钉**（2026-09-14）：本用例改前钉的是**误报**——`f()` 的
    #   调用推断此前回 unit（S1 注册链把 NEVER 钳成 unit，checker.cr:1491）⇒ `x` = unit ⇒
    #   `main`（`-> never`）体检查在返回位报 TF01@2。E-11 落地后调用推断 = never（直调
    #   站点守卫）⇒ `x` = never ⇒ 返回位豁免（checker.cr:2234）⇒ **诊断消失、rc=0**。
    #   改前 = 误报在册 / 改后 = 正确行为在册（RED 实跑：改前 rc=1 + TF01@2；改后 rc=0）。
    #   **S1 链的域差异**（`:1491` 挡 NEVER）**仍然成立**，其证据面改由 t6_S3/S4/S5/S6 四钉子
    #   + `type_selftest` 的 `t6.never_cell_diff` 承担，不在本用例。
    ok.append(case_ok("t6_S1_never_unit",
                      "fn f() -> never:\n    loop:\nfn main() -> never:\n    x := f()\n    return x\n"))
    # 诊断打点已收窄到具体返回位（`return x` = 第 4 行），不再是函数节点行。
    ok.append(case_diag_lines("t6_S3_never_unit",
                              "extern fn f() -> never\nfn main() -> never:\n    x := f()\n    return x\n",
                              [("TF01", 4)]))
    # R2 P6 Task 4a（E-11，裁②并入）：方法调用站点的 never 透传（姊妹站点 checker.cr:2694）。
    #   改前：`s.m()` 推断 = unit（mangled "S.m" 经同一注册链钳位 :1491）⇒ 误发 TA02；
    #   改后：rc=0（守卫含 `fi_generic_count(fi_m) == 0` + `sym_type == unit` + 裸码 never）。
    ok.append(case_ok("t4a_method_never_call",
                      "struct S:\n    a: int\nimpl S:\n    fn m(self: S) -> never:\n        loop:\nfn main() -> int:\n    s := S { a= 1 }\n    x : int = s.m()\n    return 0\n"))
    #      S4（`check_func` 形参链，域缺 NEVER）：形参符号类型 = unit（@raw_int 只收 dex/int/never）
    # 诊断打点 = `@raw_int(b)` 调用行（第 2 行），不是函数声明行。
    ok.append(case_diag_lines("t6_S4_param_never_unit",
                              "fn f(b: never) -> int:\n    x := @raw_int(b)\n    return 0\nfn main() -> int:\n    return 0\n",
                              [("TF07", 2)]))
    ok.append(case_ok("t6_S4_param_char",
                      "fn f(b: char) -> int:\n    y : char = b\n    return 0\nfn main() -> int:\n    return 0\n"))
    #      S5（`check_func` 返回链，域含 NEVER）／S1 的 never 格排除面：`-> never` 声明自身报体检查
    # 诊断打点 = `return 1` 行（第 2 行），不是函数声明行。
    ok.append(case_diag_lines("t6_S5_never_covered",
                              "fn f() -> never:\n    return 1\nfn main() -> int:\n    return 0\n",
                              [("TF01", 2)]))
    passed = sum(ok)
    print(f"{passed}/{len(ok)} passed")
    return 0 if passed == len(ok) else 1


if __name__ == "__main__":
    raise SystemExit(main())
