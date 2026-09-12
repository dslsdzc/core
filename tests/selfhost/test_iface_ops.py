#!/usr/bin/env python3
"""R2 P2b Task 4/5：接口查表接线的行为回归（checker.cr ← iface_registry 的 ops 列）。

Task 4 接线点（三层门形状，改动前原文逐字等价）：
  · 算术门 `checker.cr:1959`（ANY：至少一侧许可即通过；改动前 = `lt != TI_INT && lt != TI_DEX
    && rt != TI_INT && rt != TI_DEX`）——表的 ADD..MOD 格**只含 int/dex**；
  · 逻辑门 `checker.cr:1969`（ALL：每侧都须许可；改动前 = `(lt≠bool ∧ lt≠int) ∨ (rt≠bool ∧ rt≠int)`）
    ——表的 AND/OR 格恰 {int, bool}（**dex 不在内**）；
  · 条件门 `checker.cr:2274`（ONE / IP_COND = bool|int）与 `checker.cr:2385`（ONE / IP_COND_BOOL
    = **仅 bool**）——两条规则现状不同，不得合并。

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
    ok.append(case_ok("pos_int_add", "fn main() -> int { x := 1 + 2; return x; }\n"))
    ok.append(case_ok("pos_int_mod", "fn main() -> int { x := 7 % 3; return x; }\n"))
    ok.append(case_ok("pos_dex_add", "fn main() -> int { d := 1.5 + 1; return 0; }\n"))
    ok.append(case_ok("pos_dex_dominates", "fn main() -> int { d := 1 + 1.5; return 0; }\n"))
    ok.append(case_ok("pos_str_concat", 'fn main() -> int { s := "a" + "b"; return 0; }\n'))
    ok.append(case_ok("pos_str_concat_right",
                      'fn main() -> int { s := 1 + "b"; return 0; }\n'))
    ok.append(case_ok("pos_ptr_add_int",
                      "fn main() -> int { x : ., mut = 5; p := &x; q := p + 1; return 0; }\n"))
    ok.append(case_ok("pos_int_add_ptr",
                      "fn main() -> int { x : ., mut = 5; p := &x; q := 1 + p; return 0; }\n"))
    ok.append(case_ok("pos_ptr_diff",
                      "fn main() -> int { x : ., mut = 5; p := &x; q := &x; d := p - q; return d; }\n"))
    ok.append(case_ok("pos_str_index", 'fn main() -> int { s := "ab"; c := s[0]; return c; }\n'))
    ok.append(case_ok("pos_tuple_field",
                      "fn main() -> int { t := (1, 2); a := t . 0; return a; }\n"))
    ok.append(case_ok("pos_logic_int", "fn main() -> int { b := 1 && true; return 0; }\n"))
    ok.append(case_ok("pos_logic_bool", "fn main() -> int { b := true && false; return 0; }\n"))
    ok.append(case_ok("pos_cond_if_int", "fn main() -> int { if 1 { return 1; } return 0; }\n"))
    ok.append(case_ok("pos_cond_if_bool", "fn main() -> int { if true { return 1; } return 0; }\n"))
    ok.append(case_ok("pos_cond_while_bool",
                      "fn main() -> int { n : ., mut = 0; while n < 3 { n = n + 1; } return n; }\n"))
    ok.append(case_ok("pos_range_int", "fn main() -> int { b := 1..3; return 0; }\n"))
    # ─── 负控（拒绝面，码逐字不变）───
    # **关键守卫 1**：`*T + *T` —— 门集合若含 PTR（ANY 语义）即静默放行
    ok.append(case_reject("neg_ptr_add_ptr",
                          "fn main() -> int { x : ., mut = 5; p := &x; q := &x; r := p + q; return 0; }\n", "TB01"))
    # **关键守卫 2**：`"a" - "b"` —— 串拼接许可在 :1946 早退（只认 OP_ADD），门集合若含 STRING 即放行
    ok.append(case_reject("neg_str_sub_str",
                          'fn main() -> int { s := "a" - "b"; return 0; }\n', "TB01"))
    ok.append(case_reject("neg_str_mul_str",
                          'fn main() -> int { s := "a" * "b"; return 0; }\n', "TB01"))
    ok.append(case_reject("neg_arr_add_arr",
                          "fn main() -> int { a := [1,2,3]; b := [4,5,6]; c := a + b; return 0; }\n", "TB01"))
    ok.append(case_reject("neg_char_add_char",
                          "fn main() -> int { c := 'a' + 'b'; return 0; }\n", "TB01"))
    ok.append(case_reject("neg_logic_dex",
                          "fn main() -> int { b := 1.5 && true; return 0; }\n", "TC01"))
    ok.append(case_reject("neg_logic_dex_or",
                          "fn main() -> int { b := 1.5 || false; return 0; }\n", "TC01"))
    ok.append(case_reject("neg_logic_str",
                          'fn main() -> int { b := "a" && true; return 0; }\n', "TC01"))
    ok.append(case_reject("neg_cond_if_arr",
                          "fn main() -> int { if [1,2,3] { return 1; } return 0; }\n", "TC01"))
    ok.append(case_reject("neg_cond_if_dex",
                          "fn main() -> int { if 1.5 { return 1; } return 0; }\n", "TC01"))
    # `while` 与 `if` 现状**不同**（IP_COND_BOOL 只收 bool）：int 在 if 收、在 while 拒
    ok.append(case_reject("neg_cond_while_int",
                          "fn main() -> int { while 1 { } return 0; }\n", "TC04"))
    ok.append(case_reject("neg_cond_while_dex",
                          "fn main() -> int { while 1.5 { } return 0; }\n", "TC04"))
    ok.append(case_reject("neg_cond_while_arr",
                          "fn main() -> int { while [1,2,3] { } return 0; }\n", "TC04"))
    ok.append(case_reject("neg_range_str_ends",
                          'fn main() -> int { b := "a".."b"; return 0; }\n', "TB01"))
    # ─── 登记面（现状宽松；本批断言「不动」= 保留为表的全许可格，P3 才收紧）───
    ok.append(case_ok("reg_int_add_arr",
                      "fn main() -> int { a := [1,2,3]; c := 1 + a; return 0; }\n"))
    ok.append(case_ok("reg_str_mul_int", 'fn main() -> int { s := "a" * 2; return 0; }\n'))
    ok.append(case_ok("reg_arr_index_bool",
                      "fn main() -> int { a := [1,2,3]; c := a[true]; return 0; }\n"))
    ok.append(case_ok("reg_not_arr",
                      "fn main() -> int { a := [1,2,3]; b := !a; return 0; }\n"))
    ok.append(case_ok("reg_neg_str", 'fn main() -> int { s := "a"; t := -s; return 0; }\n'))
    ok.append(case_ok("reg_deref_int",
                      "fn main() -> int { x := 5; y := *x; return 0; }\n"))
    ok.append(case_ok("reg_cmp_unchecked",
                      'fn main() -> int { b := "a" == 1; return 0; }\n'))
    ok.append(case_ok("reg_as_identity",
                      'fn main() -> int { s := "a"; x := s as int; return 0; }\n'))

    # ─── R2 P2b Task 5：容器面（**唯一接线点** = 索引兜底拒绝 → IP_INDEX 查表）───
    # 接线口径 = 与改动前**一字等价**：门体即原 `EC_TK_INDEX` 调用；可达集（= 三个结果分支
    # 之后的落空集）与表的拒绝集逐行相等（selftest `idx.gate_deny_covers_fallback` 钉死）。
    # 字段/转换/dyn 三面**未接线**（无拒绝路径 / 谓词不是类级位）——本段以「现状不动」钉住，
    # 防后续把 `IP_FIELD`/`IP_METHOD`/`IP_AS` 硬接成收紧或放宽。
    S5 = "struct S { a: int }\n"
    # 正控：三个结果分支（数组→元素 / 切片→元素 / 数组 range→切片）
    ok.append(case_ok("t5_pos_arr_index",
                      "fn main() -> int { a := [1,2,3]; c := a[1]; return c; }\n"))
    ok.append(case_ok("t5_pos_slice_index",
                      "fn main() -> int { a := [1,2,3]; s := a[0..2]; c := s[1]; return c; }\n"))
    ok.append(case_ok("t5_pos_arr_range",
                      "fn main() -> int { a := [1,2,3]; s := a[1..2]; return 0; }\n"))
    # 负控：非容器行一律 TK01（码/文案逐字不变）——给表的 IP_INDEX 加任一非容器类即静默放行
    ok.append(case_reject("t5_neg_index_int",
                          "fn main() -> int { x := 1; c := x[0]; return 0; }\n", "TK01"))
    ok.append(case_reject("t5_neg_index_bool",
                          "fn main() -> int { x := true; c := x[0]; return 0; }\n", "TK01"))
    ok.append(case_reject("t5_neg_index_dex",
                          "fn main() -> int { x := 1.5; c := x[0]; return 0; }\n", "TK01"))
    ok.append(case_reject("t5_neg_index_char",
                          "fn main() -> int { c := 'a'[0]; return 0; }\n", "TK01"))
    ok.append(case_reject("t5_neg_index_ptr",
                          "fn main() -> int { x : ., mut = 5; p := &x; c := p[0]; return 0; }\n", "TK01"))
    ok.append(case_reject("t5_neg_index_named",
                          S5 + "fn main() -> int { s := S { a: 1 }; c := s[0]; return 0; }\n", "TK01"))
    ok.append(case_reject("t5_neg_index_tuple",
                          "fn main() -> int { t := (1,2); c := t[0]; return 0; }\n", "TK01"))
    ok.append(case_reject("t5_neg_index_dyn",
                          "fn main() -> int { d : dyn = 5; c := d[0]; return 0; }\n", "TK01"))
    # 登记面（现状静默；本批断言「不动」= P3 收紧面）：
    #   range 索引的非数组落空 `return TI_UNIT` 无诊断（表 IP_INDEX_RANGE **未接线**——门恒真空转）
    ok.append(case_ok("t5_reg_str_range",
                      'fn main() -> int { s := "ab"; t := s[0..1]; return 0; }\n'))
    ok.append(case_ok("t5_reg_slice_range",
                      "fn main() -> int { a := [1,2,3]; s := a[0..2]; t := s[0..1]; return 0; }\n"))
    ok.append(case_ok("t5_reg_int_range",
                      "fn main() -> int { x := 1; t := x[0..1]; return 0; }\n"))
    #   字段落空静默（EXPR_FIELD 全形 rc=0：非 struct / 越界元组位 / 指针·数组·dyn 操作数）
    ok.append(case_ok("t5_reg_int_field",
                      "fn main() -> int { x := 1; c := x.a; return 0; }\n"))
    ok.append(case_ok("t5_reg_tuple_field_oob",
                      "fn main() -> int { t := (1,2); c := t . 5; return 0; }\n"))
    ok.append(case_ok("t5_reg_ptr_field",
                      S5 + "fn main() -> int { s := S { a: 1 }; p := &s; c := p.a; return 0; }\n"))
    ok.append(case_ok("t5_reg_dyn_field",
                      "fn main() -> int { d : dyn = 5; c := d.a; return 0; }\n"))
    #   dyn 面：现状**有**拒绝路径（逐具体行的方法表判定）——int/string 候选行也发 N08；
    #   类级 IP_METHOD 门会**抑制**它们（= 放宽）⇒ 本段把现有 N08 钉红
    ok.append(case_reject("t5_dyn_int_method_missing",
                          "fn main() -> int { d : dyn = 5; d.nosuch(); return 0; }\n", "N08"))
    ok.append(case_reject("t5_dyn_str_method_missing",
                          'fn main() -> int { d : dyn = "a"; d.nosuch(); return 0; }\n', "N08"))
    ok.append(case_reject("t5_dyn_struct_method_missing",
                          S5 + "fn main() -> int { s := S { a: 1 }; d : dyn = s; d.nosuch(); return 0; }\n",
                          "N08"))

    # ─── R2 P2b Task 6：res_type_node/res_call_type 双份 TY→TI 映射合一（单表 ty_code_to_ti）───
    # 口径 = **保语义（零行为变化）**：8 个站点的**域逐站不同且载荷**（探针组 F/R/B/A/C，见报告）——
    # 本段把「站点域差异」钉死，防后续按「表 + 尾回落」一刀切（那会把 S1 的 char/never 从 unit
    # 静默改成 char/never、把 S3 的 char 从 char 改成 unit 等）。行号 = 诊断所在行（区分站点）。
    #   ① 两表基型分支（res_type_node / res_call_type）
    ok.append(case_ok("t6_R_dyn_decl",
                      "fn main() -> int { x : dyn = 5; return 0; }\n"))
    # res_type_node 的 7 码格 ⇒ TI_DYN（dyn 方法分派据此走 N08 路径）
    ok.append(case_reject("t6_R_dyn_cell_live",
                          "fn main() -> int { x : dyn = 5; x.nosuch(); return 0; }\n", "N08"))
    ok.append(case_ok("t6_R_char_ret",
                      "fn f() -> char { return 'a'; }\nfn main() -> int { c := f(); return 0; }\n"))
    #   ② **两表唯一差异格 = NEVER**：res_call_type 对调用位点的 `-> never` 返回 unit（现状），
    #      res_type_node 对类型位 `x : never = 1` 映 TI_NEVER——后者由 t6_S1/S3/S4/S6 的排除面互为镜像
    # TF01 收口（2026-09-13）：`fn g[T](a: T) -> never { loop { } }` 体以**无 break 的 loop**
    # 收尾 ⇒ 不落空 ⇒ 站点 5 不再误报 TF01@1（该函数语义上确为 never 函数）。本用例的关注面 =
    # 调用位点（`never` 在调用位点被当 unit ⇒ @raw_int 报 TF07@2），该面**不变**。
    ok.append(case_diag_lines("t6_C_never_call_unit",
                              "fn g[T](a: T) -> never { loop { } }\n"
                              "fn main() -> int { x := g(1); y := @raw_int(x); return 0; }\n",
                              [("TF07", 2)]))
    # 对照（同一调用位点、`-> int`）：:1615 路径确实在判（unit 兜底假设下 @raw_int 必报 TF07）
    ok.append(case_ok("t6_C_int_call_ctrl",
                      "fn g[T](a: T) -> int { return 1; }\n"
                      "fn main() -> int { x := g(1); y := @raw_int(x); return 0; }\n"))
    ok.append(case_ok("t6_C_never_param",
                      "fn f[T](a: T, b: never) -> int { return 1; }\n"
                      "fn main() -> int { return f(1, 2); }\n"))
    #   ③ 同族 6 处内联链：**逐站域**（同一形在不同站点产出不同类型 ⇒ 域差异载荷）
    #      S1（hotpatch/普通注册链，域缺 CHAR/NEVER/7）vs S3（extern 链，域含 CHAR）：同形不同果
    ok.append(case_diag_lines("t6_S1_char_unit",
                              "fn f() -> char { return 'a'; }\n"
                              "fn main() -> char { x := f(); return x; }\n",
                              [("TF01", 2)]))
    ok.append(case_ok("t6_S3_char_covered",
                      "extern fn f() -> char;\nfn main() -> char { x := f(); return x; }\n"))
    # TF01 收口（2026-09-13）：TF01@1 = 同为「无 break 的 loop 收尾」误报面（已修）；
    # 本用例的关注面 = S1 链域（`never` 声明经该链落到 unit ⇒ TF01@2），该面**不变**。
    ok.append(case_diag_lines("t6_S1_never_unit",
                              "fn f() -> never { loop { } }\n"
                              "fn main() -> never { x := f(); return x; }\n",
                              [("TF01", 2)]))
    ok.append(case_diag_lines("t6_S3_never_unit",
                              "extern fn f() -> never;\n"
                              "fn main() -> never { x := f(); return x; }\n",
                              [("TF01", 2)]))
    #      S4（`check_func` 形参链，域缺 NEVER）：形参符号类型 = unit（@raw_int 只收 dex/int/never）
    ok.append(case_diag_lines("t6_S4_param_never_unit",
                              "fn f(b: never) -> int { x := @raw_int(b); return 0; }\n"
                              "fn main() -> int { return 0; }\n",
                              [("TF07", 1)]))
    ok.append(case_ok("t6_S4_param_char",
                      "fn f(b: char) -> int { y : char = b; return 0; }\n"
                      "fn main() -> int { return 0; }\n"))
    #      S5（`check_func` 返回链，域含 NEVER）／S1 的 never 格排除面：`-> never` 声明自身报体检查
    ok.append(case_diag_lines("t6_S5_never_covered",
                              "fn f() -> never { return 1; }\nfn main() -> int { return 0; }\n",
                              [("TF01", 1)]))
    #      S6（iface 返回链，值域 = parser 写入的 TY_* 码；域缺 NEVER/7）——**显式化**撞车比较
    T6_S6 = "struct S { a: int }\n"
    ok.append(case_ok("t6_S6_iface_int",
                      "interface Show { fn show(self) -> int; }\n" + T6_S6 +
                      "impl S { fn show(self: S) -> int { return 1; } }\n"
                      "fn f[T: Show](a: T) -> int { x := a.show(); return x; }\n"
                      "fn main() -> int { s := S { a: 1 }; return f(s); }\n"))
    # TF01 收口（2026-09-13）：TF01@3 = 同为「无 break 的 loop 收尾」误报面（已修）；
    # 本用例的关注面 = S6 iface 返回链（域缺 NEVER ⇒ @raw_int 报 TF07@4），该面**不变**。
    ok.append(case_diag_lines("t6_S6_iface_never_unit",
                              "interface Show { fn show(self) -> never; }\n" + T6_S6 +
                              "impl S { fn show(self: S) -> never { loop { } } }\n"
                              "fn f[T: Show](a: T) -> int { x := a.show(); y := @raw_int(x); return 0; }\n"
                              "fn main() -> int { s := S { a: 1 }; return f(s); }\n",
                              [("TF07", 4)]))
    ok.append(case_ok("t6_S6_iface_char_covered",
                      "interface Show { fn show(self) -> char; }\n" + T6_S6 +
                      "impl S { fn show(self: S) -> char { return 'a'; } }\n"
                      "fn f[T: Show](a: T) -> int { x := a.show(); y : char = x; return 0; }\n"
                      "fn main() -> int { s := S { a: 1 }; return f(s); }\n"))

    passed = sum(ok)
    print(f"{passed}/{len(ok)} passed")
    return 0 if passed == len(ok) else 1


if __name__ == "__main__":
    raise SystemExit(main())
