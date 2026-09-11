#!/usr/bin/env python3
"""R2 P2b Task 4：操作许可查表接线的行为回归（checker.cr 三个门 ← iface_registry 的 ops 列）。

接线点（三层门形状，改动前原文逐字等价）：
  · 算术门 `checker.cr:1959`（ANY：至少一侧许可即通过；改动前 = `lt != TI_INT && lt != TI_DEX
    && rt != TI_INT && rt != TI_DEX`）——表的 ADD..MOD 格**只含 int/dex**；
  · 逻辑门 `checker.cr:1969`（ALL：每侧都须许可；改动前 = `(lt≠bool ∧ lt≠int) ∨ (rt≠bool ∧ rt≠int)`）
    ——表的 AND/OR 格恰 {int, bool}（**dex 不在内**）；
  · 条件门 `checker.cr:2274`（ONE / IP_COND = bool|int）与 `checker.cr:2385`（ONE / IP_COND_BOOL
    = **仅 bool**）——两条规则现状不同，不得合并。

判据口径 = **保语义**（零行为变化）：正控 rc=0 / 负控 rc=1 + 错误码逐字不变 / 登记面（现状
宽松面）断言「不动」。**关键守卫**（本批最易放宽的两条，见计划 Task 4 的「结构事实」）：
把 PTR/STRING 填进算术门的 ADD 格 ⇒ ANY 门下 `permits(PTR,ADD)=1` 足以放行 ⇒ `*T + *T`、
`"a" - "b"` 从 error[TB01] 变静默 —— 本文件的负控段把这两条钉死。

登记面（现状宽松 = P3 收紧清单的预备队，本批**不得**顺手改）：
  · 算术门「任一侧数值即可」：`1 + [int;3]` / `"a" * 2` 静默为 int（无诊断）；
  · 一元透传：`!arr` / `-"a"` / `*x`（x: int）原样返回操作数类型，不校验；
  · 比较不校验操作数：`"a" == 1` 恒 TI_BOOL；
  · `as` 恒等透传；字段落空静默（`x.a`，x 非 struct）——后两条属 Task 5 面。
"""

import os
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

    passed = sum(ok)
    print(f"{passed}/{len(ok)} passed")
    return 0 if passed == len(ok) else 1


if __name__ == "__main__":
    raise SystemExit(main())
