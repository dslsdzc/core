#!/usr/bin/env python3
"""ent_kernel.cr 中立性静态 guard（内核完备计划 2026-09-10 全量中立化——用户
原则：内核零经典概念——寄存器/栈/调度/内存布局/指令任一概念不得出现）。

文本扫描 src/lattice/ent_kernel.cr：剥注释（// 与 /* */）与字符串字面量
后按 identifier token 查禁。禁止 token 分组注记（守卫入回归面——A 组 Task 2
绿、B 组 Task 3 绿）：

  A 组（线性流——Task 2 范围）：g_ir_instrs / g_ir_instr_count /
     g_ir_instr_cap / iri_*（iri_op/iri_dest/iri_s1/iri_s2/iri_s3/iri_tk）
     Task 2 前红：4 使用点 10 token——compute_live_ranges(:99 iri_dest/s1/s2)、
     compute_entries(:227-233 iri_op/s1/dest)、dump_entries_summary(:367
     iri_op)、rl_rule2_func(:677-680 iri_op/s1/s2)。中立化 = 对象面 nod_*
     同 index 机械替换（F5：v7 NOD 节点序 = 指令序 index-aligned）→ 本组绿。
  B 组（实例 meta / 位置编码——Task 3 范围）：g_opt_meta 族（g_opt_meta/
     g_opt_meta_count）/ OPT_*（OPT_META_STRIDE/OPT_KEY_REG_ASSIGN）/
     LOC_HOME_BASE / E2_* / g_x86_* / x86 寄存器名
     Task 3 前红：meta_reg_for_var 直读 g_opt_meta（实例私有输出布局）+
     LOC_HOME_BASE 位置编码 seam（常量 + rl_print_loc/verify 合成引用）→
     Task 3 登记表通道切换 + 移除后转绿。**本组 Task 2 收官 = 预期红**
     （中间态——A 绿 B 红在报告中记录，Task 3 绿 B）。

结构性守卫注记：ent_kernel.cr 双 concat 共享（corec concat 无 regalloc/
instr/elf/hit/corearch.cr）→ 引用实例独有文件的符号 = corec 编译失败；文本
guard 真正防的 = 共享声明文件里的实例符号（g_opt_meta/opt 常量 = globals.cr/
ast.cr，双 concat 都有 → 结构守卫拦不住）——正是本静态 guard 的必要性。

实现注：必须先剥注释再扫 identifier——rl_print_loc 的 x86 寄存器注记（"3=rbx,
12-15=r12-r15"）在注释层，不剥则误报。字符串字面量一并剥离（非代码标识符，
扫串内文本会误报 "home slot"/"reg" 等输出措辞）。

NOD/EDG/ENT/REG = 文件格式语义名不拦（§4.3 例外——载体语义名非实例符号）。
"""

import re
import sys
from pathlib import Path

BASE = Path(__file__).resolve().parents[2]
KERNEL = BASE / "src" / "lattice" / "ent_kernel.cr"

# --- 排除集（分组） ---

# A 组：线性流（调度产物 = 实例侧；内核零线性流代码引用——Task 2）
A_LITERAL = {"g_ir_instrs", "g_ir_instr_count", "g_ir_instr_cap"}
A_PREFIX = ("iri_",)

# B 组：实例符号 / 位置编码（Task 3 范围）
B_LITERAL = {"LOC_HOME_BASE"}
B_PREFIX = ("g_opt_meta", "OPT_", "E2_", "g_x86_")
B_REGNAMES = {  # x86 寄存器枚举名（注释层已有 "3=rbx, 12-15=r12-r15" 记录）
    "rax", "rbx", "rcx", "rdx", "rsi", "rdi", "rbp", "rsp", "rip",
    "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15",
    "eax", "ebx", "ecx", "edx", "esi", "edi", "ebp", "esp", "eip",
}

TOKEN_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def strip_comments_and_strings(src: str) -> str:
    """剥 // 行注释、/* */ 块注释与 "..." 字符串字面量（内容以空格替位，
    保持 token 边界语义——邻接 identifier 不得因剥离而并字）。"""
    out = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == "/" and i + 1 < n and src[i + 1] == "/":
            j = src.find("\n", i)
            out.append(" ")
            i = j if j >= 0 else n
            continue
        if c == "/" and i + 1 < n and src[i + 1] == "*":
            j = src.find("*/", i + 2)
            out.append(" ")
            i = (j + 2) if j >= 0 else n
            continue
        if c == '"':
            j = i + 1
            while j < n:
                if src[j] == "\\":
                    j += 1
                elif src[j] == '"':
                    break
                j += 1
            out.append(" ")
            i = j + 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


def scan() -> tuple:
    """扫描 ent_kernel.cr 代码面。返回 ({A 组 token: count}, {B 组 token:
    count})——均为空 = 中立。"""
    src = KERNEL.read_text(encoding="utf-8")
    code = strip_comments_and_strings(src)
    found_a, found_b = {}, {}
    for tok in TOKEN_RE.findall(code):
        if tok in A_LITERAL or tok.startswith(A_PREFIX):
            found_a[tok] = found_a.get(tok, 0) + 1
        elif (tok in B_LITERAL or tok.startswith(B_PREFIX)
              or tok in B_REGNAMES):
            found_b[tok] = found_b.get(tok, 0) + 1
    return found_a, found_b


def main() -> int:
    if not KERNEL.exists():
        print(f"[FAIL] missing kernel file {KERNEL}")
        return 1
    a, b = scan()

    def fmt(inv: dict) -> str:
        return " ".join(f"{t}×{c}" for t, c in sorted(inv.items())) or "clean"

    if not a:
        print("[PASS] neutrality A (linear-stream g_ir_instrs/iri_*): clean")
    else:
        print(f"[FAIL] neutrality A (linear-stream g_ir_instrs/iri_*): {fmt(a)}"
              f"  ← Task 2 目标（对象面 nod_* 同 index 替换）")
    if not b:
        print("[PASS] neutrality B (meta/LOC/OPT/E2/g_x86_*/regnames): clean")
    else:
        print(f"[FAIL] neutrality B (meta/LOC/OPT/E2/g_x86_*/regnames): {fmt(b)}"
              f"  ← Task 3 目标（登记表通道 + LOC_HOME_BASE 移除；Task 2 收官预期红）")
    ok = not a and not b
    print(f"{'PASS' if ok else 'FAIL'} (A clean = Task 2 gate; "
          f"A+B clean = full neutrality)")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
