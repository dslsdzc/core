#!/usr/bin/env python3
"""LSP `@` 内建补全表 ↔ 语言面真源 一致性判据（2026-09-18 判据接线批；纯 python、无编译器依赖）。

背景：`src/lsp/analysis.cr::analysis_at_items()` 的候选表是**字面量镜像**——它必须等于语言面
「`@` 名字」的**并集**（两个真源）：

  真源① **表达式内建** = `src/compiler/checker.cr` 的 `EXPR_AT` 分派（`str_eq(name, "…")`）；
  真源② **`@` 面注解**   = `src/compiler/parser.cr` 的 `@` 注解解析器
                           （今日 = `parse_ffi_annotation` ⇒ `ffi`，调用点 `parser.cr:1589`）。

**必须排除** `#` 面注解解析器（今日 = `parse_spec_annotations` ⇒ `check`/`ensure`；走 `#` 语法，
不属 `@` 补全表）——排除是**显式分类**，不是「忽略」。

判据：
  L1 **真源枚举守卫（防第三真源静默失效）**：`parser.cr` 里 `fn parse_*annotation*` 的集合必须
     == 已分类集合 {`parse_ffi_annotation`（@ 面）· `parse_spec_annotations`（# 面，显式排除）}；
     **多一个就红** ⇒ 强制新增注解被分类（否则将来加注解时本守卫静默变瞎 = 本仓最忌类）。
  L2 **双向差集为空**：LSP 表 == 真源① ∪ 真源②（左独有 / 右独有都必须为空，逐名打印）。
  L3 **非真空控制**：三个抽取结果都非空（防正则失效 ⇒ 「空 == 空」恒绿）。
  L4 **突变自证（内存内、双向 + 真源面）**：① 删 LSP 表一名 ⇒ L2 必红；② 删 checker 分派一名 ⇒ L2 必红；
     ③ 删 parser 的 `@` 注解名 ⇒ L2 必红；④ 造一个新注解解析器 ⇒ L1 必红；正控（未突变）绿。

挂点：`src/ci/run.sh` 的 `bootstrap-tests` job（不构建 ⇒ 毫秒级、可在最便宜的档跑）。
"""

import os
import re
import sys

BASE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CHECKER = os.path.join(BASE, "src", "compiler", "checker.cr")
PARSER = os.path.join(BASE, "src", "compiler", "parser.cr")
LSP = os.path.join(BASE, "src", "lsp", "analysis.cr")

# 已分类的注解解析器（L1 的真源）：@ 面进 `@` 表；# 面显式排除（附理由）
AT_FACE_PARSERS = {"parse_ffi_annotation"}        # @ffi("lang")
HASH_FACE_PARSERS = {"parse_spec_annotations"}    # #check / #ensure（`#` 语法，不进 `@` 表）
KNOWN_PARSERS = AT_FACE_PARSERS | HASH_FACE_PARSERS

EXPR_AT_OPEN = "ast_kind(node) == EXPR_AT"
EXPR_AT_CLOSE = "unknown @ builtin"
STR_EQ_NAME = re.compile(r'str_eq\(name, "([^"]+)"\)')
STR_EQ_ANY = re.compile(r'str_eq\((\w+), "([^"]+)"\)')
CITEM = re.compile(r'analysis_citem\("([^"]+)", 3\)')
ANN_FN = re.compile(r"^fn (parse_\w*annotation\w*)\(")


def checker_expr_at_names(text):
    """真源①：checker.cr 的 EXPR_AT 分派块内的 `str_eq(name, "X")` 名字集合。"""
    lines = text.split("\n")
    start = next((i for i, l in enumerate(lines) if EXPR_AT_OPEN in l), None)
    if start is None:
        return None
    end = next((j for j in range(start, len(lines)) if EXPR_AT_CLOSE in lines[j]), None)
    if end is None:
        return None
    return {m.group(1) for l in lines[start:end] for m in STR_EQ_NAME.finditer(l)}


def annotation_parsers(text):
    """parser.cr 里全部 `fn parse_*annotation*` 的函数名（L1 的枚举面）。"""
    return {m.group(1) for l in text.split("\n") for m in [ANN_FN.match(l)] if m}


def annotation_names(text, fn_name):
    """某注解解析器函数体内被期望的注解名（`str_eq(<tok>, "X")` 的 X 集合）。

    体边界 = `fn <name>(` 行 → 之后首个顶格 `}` 行。
    """
    lines = text.split("\n")
    start = next((i for i, l in enumerate(lines) if l.startswith("fn %s(" % fn_name)), None)
    if start is None:
        return None
    end = next((j for j in range(start + 1, len(lines)) if lines[j] == "}"), None)
    if end is None:
        return None
    return {m.group(2) for l in lines[start:end + 1] for m in STR_EQ_ANY.finditer(l)}


def lsp_at_names(text):
    """LSP 侧：`analysis_at_items()` 体内的 `analysis_citem("X", 3)` 名字集合。"""
    lines = text.split("\n")
    start = next((i for i, l in enumerate(lines) if l.startswith("fn analysis_at_items(")), None)
    if start is None:
        return None
    end = next((j for j in range(start + 1, len(lines)) if lines[j].strip() == "return out;"), None)
    if end is None:
        return None
    return {m.group(1) for l in lines[start:end + 1] for m in CITEM.finditer(l)}


def truth_set(ck_text, pp_text):
    """真源① ∪ 真源②（`@` 面）。返回 (集合, 解析器集合) 或 (None, 解析器集合)。"""
    parsers = annotation_parsers(pp_text)
    ck = checker_expr_at_names(ck_text)
    if ck is None:
        return None, parsers
    out = set(ck)
    for fn in sorted(parsers & AT_FACE_PARSERS):
        names = annotation_names(pp_text, fn)
        if names is None:
            return None, parsers
        out |= names
    return out, parsers


def judge(ck_text, pp_text, lsp_text):
    """返回 (ok, msgs)。ok=False ⇒ 判据红；msgs 为逐条明细（红=原因 / 绿=读数）。"""
    msgs = []
    bad = False
    truth, parsers = truth_set(ck_text, pp_text)
    lsp = lsp_at_names(lsp_text)
    ck = checker_expr_at_names(ck_text)

    # L1 真源枚举守卫（防第三真源）
    if parsers != KNOWN_PARSERS:
        bad = True
        new = sorted(parsers - KNOWN_PARSERS)
        gone = sorted(KNOWN_PARSERS - parsers)
        msgs.append("L1 红：注解解析器集合变了 ⇒ 新增 %s / 消失 %s；**必须分类（@ 面 / # 面）并更新本判据**"
                    % (new or "无", gone or "无"))

    # L3 非真空控制
    if not ck or not lsp or truth is None:
        msgs.append("L3 红：抽取为空（checker=%s lsp=%s truth=%s）⇒ 判据正则失效，拒绝恒绿"
                    % (len(ck or ()), len(lsp or ()), "None" if truth is None else len(truth)))
        return False, msgs

    # L2 双向差集
    left_only = sorted(truth - lsp)    # 语言面有、LSP 表缺
    right_only = sorted(lsp - truth)   # LSP 表有、语言面无
    if left_only:
        bad = True
        msgs.append("L2 红：语言面有而 LSP 表缺 ⇒ %s" % left_only)
    if right_only:
        bad = True
        msgs.append("L2 红：LSP 表有而语言面无 ⇒ %s" % right_only)

    at_face = {f: sorted(annotation_names(pp_text, f) or []) for f in sorted(AT_FACE_PARSERS)}
    msgs.append("读数：真源①(checker EXPR_AT) %d 名 · 真源②(@面注解) %s · LSP 表 %d 名"
                % (len(ck), at_face, len(lsp)))
    return (not bad), msgs


def report(tag, ok, msgs):
    print("[%s] %s%s" % ("PASS" if ok else "FAIL", tag,
                         ("；" + "；".join(msgs)) if msgs else ""))


def mutate_first_in_block(text):
    """把 EXPR_AT **块内**首个 `str_eq(name, "X")` 改成永不匹配名（块外同名形态不得误伤）。"""
    lines = text.split("\n")
    start = next(i for i, l in enumerate(lines) if EXPR_AT_OPEN in l)
    end = next(j for j in range(start, len(lines)) if EXPR_AT_CLOSE in lines[j])
    for i in range(start, end):
        if STR_EQ_NAME.search(lines[i]):
            lines[i] = STR_EQ_NAME.sub('str_eq(name, "__removed__")', lines[i], count=1)
            return "\n".join(lines)
    raise AssertionError("EXPR_AT 块内未找到可突变点（判据抽取口径可能已漂移）")


def selftest(ck, pp, lsp):
    """L4 突变自证：内存内改文本，断言判据必红（双向 + 真源面）；未突变必绿。"""
    ok0, _ = judge(ck, pp, lsp)
    report("L4 正控（未突变 ⇒ 绿）", ok0, [])
    # ① 删 LSP 表一名
    m = CITEM.search(lsp)
    name = m.group(1)
    lsp1 = lsp.replace(m.group(0), 'analysis_citem("__removed__", 3)', 1)
    ok1, _ = judge(ck, pp, lsp1)
    report("L4-① 删 LSP 表 `%s` ⇒ 必红" % name, not ok1, [])
    # ② 删 checker 分派一名（**必须落在 EXPR_AT 块内**——块外也有同名形态，误改则突变打空）
    ck2 = mutate_first_in_block(ck)
    ok2, _ = judge(ck2, pp, lsp)
    report("L4-② 删 checker 分派一名（块内）⇒ 必红", not ok2, [])
    # ③ 删 parser 的 @ 注解名（ffi）
    pp3 = pp.replace('str_eq(lex, "ffi")', 'str_eq(lex, "__removed__")', 1)
    ok3, _ = judge(ck, pp3, lsp)
    report("L4-③ 删 parser `@` 注解名 ⇒ 必红", not ok3, [])
    # ④ 造第三个注解解析器 ⇒ L1 必红
    pp4 = pp + "\nfn parse_demo_annotation() -> int {\n    if str_eq(lex, \"demo\") == 0 { return -1; }\n    return 0;\n}\n"
    ok4, _ = judge(ck, pp4, lsp)
    report("L4-④ 新增注解解析器 ⇒ L1 必红（防第三真源）", not ok4, [])
    return ok0 and (not ok1) and (not ok2) and (not ok3) and (not ok4)


def main():
    for p in (CHECKER, PARSER, LSP):
        if not os.path.exists(p):
            print("[FAIL] 缺文件：%s" % p)
            return 1
    ck = open(CHECKER, encoding="utf-8").read()
    pp = open(PARSER, encoding="utf-8").read()
    lsp = open(LSP, encoding="utf-8").read()

    ok, msgs = judge(ck, pp, lsp)
    report("L1/L2/L3（真源枚举 · 双向差集 · 非真空）", ok, msgs)
    ok_self = selftest(ck, pp, lsp)
    all_ok = ok and ok_self
    print("%s（L1–L4）" % ("4/4 通过" if all_ok else "存在失败项"))
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main())
