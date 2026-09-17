#!/usr/bin/env python3
"""`IR_REF` 发射点形状绊线（2026-09-18 判据接线批；纯 python、无编译器依赖）。

背景：`TODO #2026-09-16-15` 登记「`IR_REF` 的目标侧是否可能为全局」= **未实测断言**。
**语义版**判据（全语料 IR dump 里 `IR_REF` 的 dest 无全局索引）**需构建**，且还缺一条通道——
判「IR var 是否全局」的 `g_x86_is_global` 今日**只被后端**（`src/arch/x86_64/instr.cr`）消费、
**无任何 dump 打印它**（2026-09-18 实核）⇒ 成本高一量级，另批。
本文件是**廉价版**：只断言**源码形状**，作为「该条要盯的时刻」的绊线。

判据：
  R1 **发射点恒 1 处**：`src/compiler/ir_gen.cr` 里 `emit(IR_REF,` 的出现次数 == 1（多/少都红）。
  R2 **dest 是紧邻局部**：该行 dest 实参由**紧前 5 行内**的 `new_ir_var(` 定义
     （今日 = `v := new_ir_var("ref", …)` ⇒ 不可能同时是全局）。
  R3 **非真空控制**：抽到 1 行且 dest 非空（防正则失效 ⇒ 恒绿）。
  R4 **突变自证（内存内）**：① 造第 2 处发射点 ⇒ R1 必红；② dest 改成非 `new_ir_var` 来源 ⇒ R2 必红；
     正控（未突变）绿。

**声明（明写，防误读）**：R1/R2 转红 = **源码形状变了**（有人新增/改动了 `IR_REF` 发射点）——
**不等于**语义已被破坏；语义层结论须等构建版判据。本文件**不声明**「无全局 dest」为已证。

挂点：`src/ci/run.sh` 的 `bootstrap-tests` job（不构建）。
"""

import os
import re
import sys

BASE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
IR_GEN = os.path.join(BASE, "src", "compiler", "ir_gen.cr")

EMIT = re.compile(r"emit\(IR_REF,\s*([A-Za-z_]\w*)")
NEW_VAR = re.compile(r"^\s*([A-Za-z_]\w*)\s*:=\s*new_ir_var\(")
LOOKBACK = 5


def scan(text):
    """返回 (sites, oks, 明细)：sites = 命中行号+dest；oks = 每处 dest 是否由紧邻 new_ir_var 定义。"""
    lines = text.split("\n")
    sites, oks = [], []
    for i, l in enumerate(lines):
        m = EMIT.search(l)
        if not m:
            continue
        dest = m.group(1)
        sites.append((i + 1, dest))
        local = False
        for j in range(max(0, i - LOOKBACK), i):
            mv = NEW_VAR.match(lines[j])
            if mv and mv.group(1) == dest:
                local = True
                break
        oks.append(local)
    return sites, oks


def judge(text):
    """返回 (ok, msgs)。"""
    msgs = []
    bad = False
    sites, oks = scan(text)

    if len(sites) != 1:
        bad = True
        msgs.append("R1 红：`emit(IR_REF,` 命中 %d 处（应恒 1）⇒ %s；"
                    "**新增/改动发射点 = 语义版断言必须重估**" % (len(sites), [s for s in sites]))
    if sites and not all(oks):
        bad = True
        msgs.append("R2 红：dest 不是紧邻 `new_ir_var` 局部（前 %d 行内未找到定义）⇒ %s；"
                    "**全局 dest 的风险面出现，语义版判据需上**" % (LOOKBACK, sites))
    if not sites or not all(sites[i][1] for i in range(len(sites))):
        bad = True
        msgs.append("R3 红：抽取为空 ⇒ 判据正则失效，拒绝恒绿")
    if not bad:
        msgs.append("读数：`IR_REF` 发射点 1 处（L%d，dest=`%s`，紧邻 `new_ir_var` 局部）"
                    % (sites[0][0], sites[0][1]))
    return (not bad), msgs


def report(tag, ok, msgs):
    print("[%s] %s%s" % ("PASS" if ok else "FAIL", tag, ("；" + "；".join(msgs)) if msgs else ""))


def selftest(text):
    ok0, _ = judge(text)
    report("R4 正控（未突变 ⇒ 绿）", ok0, [])

    # ① 造第 2 处发射点
    m = EMIT.search(text)
    fake = m.group(0)
    t1 = text.replace(fake, fake, 1) + "\n            emit(IR_REF, w, op_var, 0, 0, 0);\n"
    ok1, _ = judge(t1)
    report("R4-① 两处发射点 ⇒ R1 必红", not ok1, [])

    # ② dest 改成非 new_ir_var 来源
    t2 = text.replace(fake, 'emit(IR_REF, g_some_global, op_var, 0, 0, 0)', 1)
    ok2, _ = judge(t2)
    report("R4-② dest 非紧邻局部 ⇒ R2 必红", not ok2, [])

    return ok0 and (not ok1) and (not ok2)


def main():
    if not os.path.exists(IR_GEN):
        print("[FAIL] 缺文件：%s" % IR_GEN)
        return 1
    text = open(IR_GEN, encoding="utf-8").read()
    ok, msgs = judge(text)
    report("R1/R2/R3（发射点计数 · dest 局部性 · 非真空）", ok, msgs)
    ok_self = selftest(text)
    all_ok = ok and ok_self
    print("%s（R1–R4）" % ("4/4 通过" if all_ok else "存在失败项"))
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
