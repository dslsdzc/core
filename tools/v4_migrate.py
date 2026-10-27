#!/usr/bin/env python3
"""v4 语法迁移 T4 —— `src/**/*.cr` 语料（92 档）的一次性机械改写工具。

出处（规格）：
  - docs/superpowers/plans/2026-09-24-v4-syntax-migration.md §六（T4）与 §二（判定依据纪律）
  - docs/maintainer/design/v4-layout-spec.md（T0 布局规格：空行/注释行/行尾注释的 anchor 规则）
  - docs/developer/syntax.md（目标语法）

用途：把 v3 写法（`{}` 块 + `;` 分隔）**机械改写成** v4 写法（`:` 结尾 + layout 缩进 + 换行分隔）。
形状只有两类（计划 §6.1）：`{}` → `:` + 缩进、`;` → 换行。**不做任何语义改动**。

⚠ **本工具是一次性迁移工具，不是常设判定依据。**
  迁移收尾后它就该被冻结/删除；不得把它接进 CI，也不得让任何常设门依赖它。
  它自带的三项读数（V1 解析 / V2 token 对拍 / V3 计数 / V4 注释计数）是**当时那一刻**的
  迁移验收读数，不是回归网（回归网见计划 §二 的代 0/代 1/代 2 代表）。

用法：
    python3 tools/v4_migrate.py transform --dry-run FILE.cr      # 只打印改写结果
    python3 tools/v4_migrate.py transform --all-under src        # 原地改写 src/** 全部 92 档
    python3 tools/v4_migrate.py check FILE.cr ...                # V1/V2/V3/V4 读数
    python3 tools/v4_migrate.py check --all-under src --baseline DIR   # 与改前快照对拍

`--baseline DIR`：改前的原文快照目录（同相对路径）。给 `check` 时它做 V2/V3/V4 的对照读数。
"""

import argparse
import os
import re
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)
sys.path.insert(0, os.path.join(os.path.dirname(_HERE), 'bootstrap'))

import v4_migrate_v3lex as V3  # noqa: E402  （vendored v3 扫描器）

# 改写面 = **`src/**` 下全部 `.cr`（92 档）**（协调者 2026-10-11 更正：计划 §6.1 的
# 「七目录面 74 档」会漏掉四棵同样进编译单元的子树 —— `src/lattice`(1) ·
# `src/lsp`(7) · `src/kernel`(9) · `src/scheduler`(1)；逐目录 = compiler 38 ·
# stdlib 19 · kernel 9 · lsp 7 · arch/x86_64 5 · os/linux 3 · format/elf 3 ·
# targets/x86_64/linux/elf 2 · runtime 2 · arch/hit 2 · scheduler 1 · lattice 1）。
# `tests/`·`docs/`·`examples/`·`tools/`·`legacy_asm_backend/` 下的 `.cr` 属 T6，**不动**。
SRC_ROOT = 'src'

# ── token 集合 ────────────────────────────────────────────────────────────────
T = V3.TokenType

# 行尾是这些 ⇒ 下一物理行的首个 token 是本行的续行（必须并成一行，v4 无括号外续行）
BINOP_END = {
    T.PLUS, T.MINUS, T.STAR, T.SLASH, T.PERCENT,
    T.AND_AND, T.PIPE_PIPE, T.EQ_EQ, T.NOT_EQ, T.LT, T.GT, T.LT_EQ, T.GT_EQ,
    T.PIPE, T.AMPERSAND, T.DOT_DOT, T.EQ, T.ARROW, T.FAT_ARROW,
}
# 行首是这些 ⇒ 它是上一条语句的续行（必须并成一行）。
# **不含** MINUS/STAR/AMPERSAND —— 它们能起一条新语句（取负/解引用/取引用）；
# 也不含 LT/GT（泛型尖括号在行首语义不明）。这组取法会在 V1 上被复核。
BINOP_START = {
    T.PLUS, T.SLASH, T.PERCENT, T.AND_AND, T.PIPE_PIPE,
    T.EQ_EQ, T.NOT_EQ, T.LT_EQ, T.GT_EQ, T.PIPE, T.DOT_DOT, T.FAT_ARROW,
}

INDENT_UNIT = '    '


class MigrateError(Exception):
    pass


# ── 分类 ──────────────────────────────────────────────────────────────────────
def _is_struct_lit(toks, brace_pos):
    """**逐字复刻** v3 parser（`/tmp/v3boot/corec/frontend/parser.py:_is_struct_lit`）的启发式。

    brace 后首个 token 是 IDENT 且再下一个是 `=` 或 `:`，且**内部顶层没有 `;`**
    （含空 `{}` ⇒ True）⇒ 字面量。
    """
    pos = brace_pos + 1
    if pos >= len(toks):
        return False
    if toks[pos].type == T.RBRACE:
        return True
    if toks[pos].type != T.IDENT:
        return False
    if pos + 1 >= len(toks):
        return False
    nxt = toks[pos + 1].type
    if nxt != T.EQ and nxt != T.COLON:
        return False
    depth = 1
    limit = min(brace_pos + 100, len(toks))
    for i in range(brace_pos + 1, limit):
        tt = toks[i].type
        if tt == T.LBRACE:
            depth += 1
        elif tt == T.RBRACE:
            depth -= 1
        elif tt in (T.LBRACK, T.LPAREN):
            depth += 1
        elif tt in (T.RBRACK, T.RPAREN):
            depth -= 1
        if depth == 0:
            break
        if tt == T.SEMI and depth == 1:
            return False
    return True


def classify(toks):
    """给每个 token 下标标上：LBRACE/RBRACE 的 kind、SEMI 的 kind。

    返回 `(brace_kind: dict[i]->'block'|'struct', semi_kind: dict[i]->'array'|'stmt', notes)`。
    """
    brace_kind = {}
    semi_kind = {}
    match = {}           # LBRACE 下标 -> 配对 RBRACE 下标
    notes = []
    stack = []           # 未闭合的括号：(下标, 种类)
    decl_brace_pending = False   # `struct`/`enum`/`impl`/`interface` 之后的首个 `{` = 声明体
    for i, tk in enumerate(toks):
        t = tk.type
        if t in (T.STRUCT, T.ENUM, T.IMPL, T.INTERFACE):
            decl_brace_pending = True
        elif t == T.LBRACE:
            prev = toks[i - 1] if i > 0 else None
            is_struct = (not decl_brace_pending
                         and prev is not None and prev.type == T.IDENT
                         and prev.lexeme[:1].isupper()
                         and _is_struct_lit(toks, i))
            decl_brace_pending = False
            if is_struct:
                brace_kind[i] = 'struct'
                stack.append((i, 'struct{'))
            else:
                brace_kind[i] = 'block'
                stack.append((i, 'block{'))
        elif t == T.RBRACE:
            # 与最近的未闭合 `{` 配对
            if not stack or not stack[-1][1].endswith('{'):
                raise MigrateError('unbalanced } at offset %d' % tk.start)
            oi, kind = stack.pop()
            match[oi] = i
            brace_kind[i] = 'struct' if kind == 'struct{' else 'block'
        elif t == T.LPAREN:
            stack.append((i, '('))
        elif t == T.RPAREN:
            if stack and stack[-1][1] == '(':
                stack.pop()
        elif t == T.LBRACK:
            stack.append((i, '['))
        elif t == T.RBRACK:
            if stack and stack[-1][1] == '[':
                stack.pop()
        elif t == T.SEMI:
            semi_kind[i] = 'array' if stack and stack[-1][1] == '[' else 'stmt'
    if stack:
        raise MigrateError('unbalanced brackets at EOF')
    return brace_kind, semi_kind, match, notes


# ── 空 region 的逐处裁定表（协调者 2026-10-11 裁定 1；**逐处判定，不扩语法面**）──────
# 键 = (相对路径, `{` 所在行号)；值 = 处理。
#   'delete-if'  —— 无 else、条件无副作用（不含函数调用/赋值）的 `if` ⇒ **整条删掉**；
#                   块内注释**保留**为同位置的独立注释行（V4「注释不得下降」+ 不丢信息）。
#   'return'     —— 函数体只含注释 ⇒ 保留注释，补一条与**声明返回类型**匹配的显式 return。
#                   本表里唯一一例的声明无 `-> T` ⇒ unit ⇒ 裸 `return`。
# ⚠ 表外的空 region ⇒ **fail-closed 中止**（不猜、不静默跳过）。
EMPTY_ACTIONS = {
    # —— 裁定 1 规则 A：无 else + 条件纯局部量比较 ⇒ 删整条 if ——
    ('src/compiler/interp.cr', 337): 'delete-if',   # if op2 == 33 { }        // IR_ARENA_RESET
    ('src/compiler/interp.cr', 394): 'delete-if',   # if op2 == 51 { }        // IR_APPROX
    ('src/compiler/interp.cr', 722): 'delete-if',   # if op == 33 { }         // IR_ARENA_RESET
    ('src/compiler/parser.cr', 1743): 'delete-if',  # if is_flow != 0 { /*2 行注释*/ }
    # —— 协调者 2026-10-11 二裁（7 处全阶段）——
    # 理由行：条件是局部量（tf / cv / then_node / else_node）的纯比较（无调用、无赋值），
    # 链的净效果 = 按序读这些局部量若干次，无可观察行为 ⇒ 整条链删；块内注释逐字保留。
    ('src/compiler/interp.cr', 97): 'delete-if-chain',   # if tf == 1||tf == 3 { } else if tf == 2||tf == 3 { }
    ('src/compiler/interp.cr', 98): 'delete-if-chain',   #   同链第二分支（按 statement 起点去重，只处置一次）
    ('src/compiler/opt.cr', 99): 'delete-if-chain',      # if cv != 0 && then_node >= 0 { } else if cv == 0 && else_node >= 0 { }
    ('src/compiler/opt.cr', 103): 'delete-if-chain',     #   同链第二分支
    # 理由行（协调者实核 `str_len` = `src/stdlib/fmt.cr:4-8` 纯读取：`load64(s,-8)` + 分支，
    # 无写、无调用、无副作用；调用结果未被使用）⇒ 整条删。**已知偏差见报告**：条件里那一次
    # 内存读被一并去掉（良构程序无差异；`source`/`content` 若是无效指针，原式会陷阱而删后不会）。
    ('src/compiler/main.cr', 21): 'delete-if',      # if str_len(source) > 0 { }
    ('src/compiler/module.cr', 172): 'delete-if',   # if str_len(content) > 0 { }
    # 理由行：空 `else { }` 本身是 no-op；其所在 if/else-if 链的**非空分支一律不动** ⇒
    # 只摘掉这截 `else { … }`，2 行注释降为同位置独立注释行。
    ('src/compiler/provenance_verify.cr', 121): 'delete-else',  # } else { /*2 行注释*/ }
    # —— 裁定 1 规则 B：函数体只含注释 ⇒ 补显式 return（声明无 -> T ⇒ unit）——
    ('src/compiler/dyn_arr.cr', 259): 'return',     # fn _grow(...) { /*2 行注释*/ }
}


def _chain_ranges(toks, i, brace_kind, brace_match):
    """`if … { } else if … { } …` 链的删除区间表（**只吃空块分支**）。

    `i` = 链首那个空块的 `{` 下标。返回 `[(start, end), …]`（删 header 的 `… {` 与配对 `}`）。
    若链上遇到**非空**分支 ⇒ 停下抛 `MigrateError`（不猜）。
    """
    s = _statement_start(toks, i)
    if toks[s].type != T.IF:
        raise MigrateError('chain: statement does not start with `if` (offset %d)' % toks[i].start)
    ranges = [(toks[s].start, toks[i].end),                              # `if cond {`
              (toks[brace_match[i]].start, toks[brace_match[i]].end)]     # 配对 `}`
    n = brace_match[i] + 1
    while n < len(toks) and toks[n].type == T.ELSE:
        m = n + 1
        while m < len(toks) and toks[m].type != T.LBRACE:
            m += 1
        if m >= len(toks) or brace_match.get(m) != m + 1:
            raise MigrateError('chain: non-empty branch at offset %d' % toks[n].start)
        cl = brace_match[m]
        ranges.append((toks[n].start, toks[m].end))                      # `else [if cond] {`
        ranges.append((toks[cl].start, toks[cl].end))                    # 配对 `}`
        n = cl + 1
    return ranges

# ── unsafe-in-parens 上提（裁定 2）────────────────────────────────────────────
# 描述性名（不是 t1/t2）：按站点语义给基名；同名冲突再加 `_2`/`_3`。
UNSAFE_TMP_NAMES = {
    ('src/compiler/parser.cr', 921): 'name_str',
    ('src/compiler/parser.cr', 1311): 'name_str',
    ('src/format/elf/ld.cr', 140): 'so_path_str',
    ('src/format/elf/ld.cr', 343): 'plt_name_str',
    ('src/format/elf/ld.cr', 363): 'path_ptr',
    ('src/format/elf/ld.cr', 365): 'name_ptr',
    ('src/format/elf/ld.cr', 454): 'sp_str',
    ('src/format/elf/ld.cr', 455): 'sp_str',
    ('src/stdlib/cli.cr', 305): 'cmd_name_str',
    ('src/stdlib/cli.cr', 328): 'cmd_name_str',
}


def _enclosing_blocks(toks, idx):
    """返回下标 `idx` 的 token 所处的**块 `{`** 下标链（外 → 内）。

    只统计块花括号（结构体字面量的 `{` 不计），故与本工具的 `classify` 同判。
    """
    bk, _sk, _bm, _n = classify(toks)
    stack = []
    for i in range(idx):
        if toks[i].type == T.LBRACE and bk.get(i) == 'block':
            stack.append(i)
        elif toks[i].type == T.RBRACE and bk.get(i) == 'block':
            if stack:
                stack.pop()
    return stack


def _statement_start(toks, idx):
    """`idx` 所在**语句**的首 token 下标：向前退到最近的语句边界之后。

    边界 = 语句 `;` / 块 `{` / 块 `}`。`else` 起头**不支持**（会响亮报错，不猜）。
    """
    k = idx - 1
    while k >= 0:
        t = toks[k].type
        if t == T.SEMI or t == T.LBRACE or t == T.RBRACE:
            break
        k -= 1
    s = k + 1
    if s < len(toks) and toks[s].type == T.ELSE:
        raise MigrateError('hoist: statement starts with `else` at offset %d' % toks[idx].start)
    return s


# ── T6a：`src/` 之外语料的追加改写（**逐条记进报告**）────────────────────────
# 背景：T4 的改写面是 `src/**`，那份语料**没有** match / enum 臂体块 / 规约标注独立行 /
# `@hotpatch` 独立行，且 struct 字面量全部是 `=` 形（计划 §6.1/§6.2 实核）。`tests/`·`examples/`
# 四条面各有这些形态 ⇒ 需要三条**纯形状**追加规则（都不是语义改动）：
#   E1 struct 字面量分隔符 `:` → `=`：T0 §3.4 裁定 (a)，v4 唯一合法形是 `T { f = v }`；
#   E2 规约标注 `#check`/`#ensure` 独立行 ⇒ 并入签名行尾：v4 `parse_spec_annotations`
#      只在**签名行内**可见（parser.cr:1799 `check(T_HASH)`），独立行会被当顶层 token
#      ⇒ `error[P25]` + `error[V02]`（实测）；
#   E3 `@hotpatch(...)` 独立行 ⇒ 并入其后声明行：`parse_declaration`（parser.cr:1860）
#      要求注解与声明**同行**（`parse_expr()` 之后立刻 `check(T_FN)`），独立行 ⇒ `error[P25]`。
#
# ⚠ 三条都**按行形精确匹配**，命中不了就**原样不动**（负例语料里的错位标注因此不被误改），
#   只有「看起来是要改、但形态不在规则内」才进 `unresolved`（fail-closed）。
_ANNOT_LINE_RE = re.compile(r'^#(check|ensure)\s*\(')
_HOTPATCH_LINE_RE = re.compile(r'^@hotpatch(\(.*\))?$')


def _line_offsets(src):
    offs, p = [], 0
    for ln in src.split('\n'):
        offs.append(p)
        p += len(ln) + 1
    return offs


def _t6_extra_ops(toks, brace_kind, brace_match, src, filename, recs, unresolved, ops):
    """E1/E2/E3 的文本编辑（追加到 `ops`）。arm 块的多语句面另在 E4 里查。"""
    # ── E1：struct 字面量分隔符 `:` → `=` ──
    for i, tk in enumerate(toks):
        if brace_kind.get(i) != 'struct':
            continue
        m = brace_match.get(i)
        if m is None:
            continue
        depth = 0
        for j in range(i + 1, m):
            t = toks[j].type
            if t in (T.LBRACE, T.LPAREN, T.LBRACK):
                depth += 1
            elif t in (T.RBRACE, T.RPAREN, T.RBRACK):
                depth -= 1
            elif t == T.COLON and depth == 0 and j > 0 and toks[j - 1].type == T.IDENT:
                ops.append((toks[j].start, toks[j].end, '='))
                recs.setdefault('struct_lit_eq', []).append('%s:%d' % (filename, tk.line))

    # ── E5：`None` → `none`（v4 关键字拼写；**本次唯一的非形状改写**）──
    # 依据：v4 关键字表（docs/developer/syntax.md）含 `none`，无 `None`；
    # 实测 `z : int? = None` ⇒ `error[N01] Undefined name 'None'`，`= none` ⇒ rc=0。
    # T4 工具头注 R3 明写「`none` ↔ `None` 的关键字化不参与本变换」——那是因为 `src/**`
    # **零处**使用（实核：`grep -n '\bNone\b' src/**/*.cr` 只命中注释），T4 面从不需要它。
    # T6a 面有 2 档使用 ⇒ 必须同阶段改，否则这两档的 `T?` 语义面在 v4 下当场 N01。
    # 只改**裸 IDENT token**（字符串/注释不是 token，天然不误伤）。
    for tk in toks:
        if tk.type in (T.NONE,) or (tk.type == T.IDENT and tk.lexeme == 'None'):
            ops.append((tk.start, tk.end, 'none'))
            recs.setdefault('none_rename', []).append('%s:%d' % (filename, tk.line))

    # ── E2：规约标注独立行 ⇒ 并入签名行尾 ──
    lines = src.split('\n')
    offs = _line_offsets(src)
    i = 1
    while i < len(lines):
        if not _ANNOT_LINE_RE.match(lines[i].strip()):
            i += 1
            continue
        j = i
        anns = []
        while j < len(lines) and _ANNOT_LINE_RE.match(lines[j].strip()):
            anns.append(lines[j].strip())
            j += 1
        prev = lines[i - 1].strip()
        nxt = lines[j].strip() if j < len(lines) else ''
        if prev.startswith('fn ') and nxt == '{':
            ops.append((offs[i - 1] + len(lines[i - 1]), offs[j],
                        ' ' + ' '.join(anns) + ' '))
            recs.setdefault('annot_inline', []).append('%s:%d' % (filename, i))
        i = j

    # ── E3：`@hotpatch(...)` 独立行 ⇒ 并入其后声明行 ──
    for i in range(len(lines) - 1):
        if not _HOTPATCH_LINE_RE.match(lines[i].strip()):
            continue
        if lines[i].strip() == '' or not lines[i + 1].strip():
            continue
        nxt = lines[i + 1].strip()
        if not (nxt.startswith('fn ') or nxt.startswith('pub fn ')):
            unresolved.append('%s:%d (@hotpatch 独立行，后随非 fn 声明)' % (filename, i + 1))
            continue
        ops.append((offs[i] + len(lines[i]), offs[i + 1], ' '))
        recs.setdefault('hotpatch_inline', []).append('%s:%d' % (filename, i + 1))


def pre_transform(src, filename):
    """裁定 1/2 的**逐处**预处理（纯文本层），返回 `(new_src, records, unresolved)`。

    - 裁定 1：按 `EMPTY_ACTIONS` 处理空 region（表外 ⇒ 进 `unresolved`，由上层 fail-closed）；
    - 裁定 2：把「括号内 `unsafe { E }`」机械上提为临时量。`E` 必须是**单个表达式**，
      否则进 `unresolved`（不自行判断）。
    """
    toks = [t for t in V3.Lexer(src, filename).tokenize()]
    if toks and toks[-1].type == T.EOF:
        toks[-1].start = len(src)
        toks[-1].end = len(src)
    brace_kind, semi_kind, brace_match, _ = classify(toks)
    recs = {'deleted_if': [], 'deleted_else': [], 'return_filled': [], 'hoisted': [], 'blank_collapsed': []}
    unresolved = []

    # ── 裁定 1：空 region ──
    ops = []            # (start, end, replacement) —— 所有裁定 1/2 的文本编辑统一走这里
    seams = []          # 裁定 1 的**删除缝**起点（供末尾那段「≥2 空行收成 1」定位）
    chain_done = set()  # 链只需处置一次（同一 `if` 的每个空分支都指向同一 statement 起点）
    for i, tk in enumerate(toks):
        if brace_kind.get(i) != 'block' or brace_match.get(i) != i + 1:
            continue
        act = EMPTY_ACTIONS.get((filename, tk.line))
        if act is None:
            unresolved.append('%s:%d (empty region, 无裁定)' % (filename, tk.line))
            continue
        if act in ('delete-if', 'delete-if-chain'):
            if act == 'delete-if-chain':
                # 链的**第二及以后**分支：其 statement 起点落在 `else` 上 ⇒ `_statement_start`
                # 会响亮拒绝。这不是错误，而是「本分支属链的续段、由链首那次处置」的信号。
                # 真出错时链首也处置不了 ⇒ 空 region 残留 ⇒ 发射期 fail-closed 中止（不静默）。
                try:
                    stmt = _statement_start(toks, i)
                except MigrateError:
                    continue
            else:
                try:
                    stmt = _statement_start(toks, i)
                except MigrateError as e:
                    unresolved.append('%s:%d (%s)' % (filename, tk.line, e))
                    continue
            if act == 'delete-if':
                ifs = i - 1
                while ifs >= 0 and toks[ifs].type not in (T.IF, T.ELSE, T.SEMI, T.LBRACE, T.RBRACE):
                    ifs -= 1
                if ifs < 0 or toks[ifs].type != T.IF:
                    unresolved.append('%s:%d (delete-if 找不到起头 `if`)' % (filename, tk.line))
                    continue
                nxt = brace_match[i] + 1
                if nxt < len(toks) and toks[nxt].type == T.ELSE:
                    unresolved.append('%s:%d (delete-if 但语句带 else ⇒ 改判 delete-if-chain)'
                                      % (filename, tk.line))
                    continue
                ops.append((toks[ifs].start, tk.end, ''))             # 删 `if … {`
                ops.append((toks[i + 1].start, toks[i + 1].end, ''))  # 删配对 `}`
                seams.append(toks[ifs].start)
                recs['deleted_if'].append('%s:%d' % (filename, tk.line))
            else:
                if stmt in chain_done:
                    continue                                          # 同链的第二分支：已随首分支处置
                try:
                    rngs = _chain_ranges(toks, i, brace_kind, brace_match)
                except MigrateError as e:
                    unresolved.append('%s:%d (%s)' % (filename, tk.line, e))
                    continue
                chain_done.add(stmt)
                for a, b in rngs:
                    ops.append((a, b, ''))
                seams.append(rngs[0][0])
                recs['deleted_if'].append('%s:%d (整条 if/else-if 链，%d 段)'
                                          % (filename, tk.line, len(rngs)))
        elif act == 'delete-else':
            e = i - 1
            while e >= 0 and toks[e].type not in (T.ELSE, T.IF, T.SEMI, T.LBRACE, T.RBRACE):
                e -= 1
            if e < 0 or toks[e].type != T.ELSE:
                unresolved.append('%s:%d (delete-else 找不到起头 `else`)' % (filename, tk.line))
                continue
            ops.append((toks[e].start, tk.end, ''))                   # 删 `else … {`
            ops.append((toks[i + 1].start, toks[i + 1].end, ''))      # 删配对 `}`
            seams.append(toks[e].start)
            recs.setdefault('deleted_else', []).append('%s:%d' % (filename, tk.line))
        elif act == 'return':
            ops.append((tk.end, tk.end, ' return; '))            # `{` 之后补 `return;`
            recs['return_filled'].append('%s:%d -> `return` (声明无 -> T ⇒ unit)'
                                         % (filename, tk.line))
        else:
            unresolved.append('%s:%d (未知裁定 %r)' % (filename, tk.line, act))

    # ── 裁定 2：括号内 `unsafe { E }` 上提 ──
    used_names = {}          # 块下标 -> 已用名集合（同名冲突判定用）
    for i, tk in enumerate(toks):
        if tk.type != T.UNSAFE:
            continue
        if i + 1 >= len(toks) or toks[i + 1].type != T.LBRACE:
            continue
        if brace_kind.get(i + 1) != 'block':
            continue
        # 是否在**括号内**（`(` 未闭合）—— 用 `_enclosing_blocks` 之外的括号栈判
        stack = []
        for j in range(i):
            t = toks[j].type
            if t in (T.LPAREN, T.LBRACK):
                stack.append(t)
            elif t == T.LBRACE and brace_kind.get(j) != 'struct':
                stack.append(t)
            elif t in (T.RPAREN, T.RBRACK, T.RBRACE):
                if stack:
                    stack.pop()
        if not stack or stack[-1] != T.LPAREN:
            continue          # 不在括号内 ⇒ 正常 region，无需上提
        close = brace_match[i + 1]
        inner = toks[i + 2:close]
        if any(x.type == T.SEMI or x.type == T.LBRACE or x.type == T.RBRACE for x in inner):
            unresolved.append('%s:%d (unsafe 体内非单个表达式)' % (filename, tk.line))
            continue
        # 命名：基名 + 同 scope 冲突则加后缀
        base = UNSAFE_TMP_NAMES.get((filename, tk.line))
        if base is None:
            unresolved.append('%s:%d (unsafe 上提站点无名字表项)' % (filename, tk.line))
            continue
        anc = _enclosing_blocks(toks, i)
        taken = set()
        for b in anc:
            taken |= used_names.get(b, set())
        name, n = base, 1
        while name in taken or re.search(r'\b%s\b' % re.escape(name),
                                         src[toks[_statement_start(toks, i)].start:
                                             toks[close].end]):
            n += 1
            name = '%s_%d' % (base, n)
        used_names.setdefault(anc[-1] if anc else -1, set()).add(name)
        stmt = _statement_start(toks, i)
        inner_txt = src[toks[i + 1].end:toks[close].start]
        ops.append((tk.start, toks[close].end, name))                       # `unsafe {E}` → 名
        ops.append((toks[stmt].start, toks[stmt].start,
                    '%s := unsafe {%s}; ' % (name, inner_txt)))             # 语句前插声明
        recs['hoisted'].append('%s:%d -> `%s`' % (filename, tk.line, name))

    # ── T6a 追加三条规则（E1/E2/E3）与 E4 守卫 ──
    _t6_extra_ops(toks, brace_kind, brace_match, src, filename, recs, unresolved, ops)

    # 统一**降序**下沉：所有替换/插入一次性按起点从大到小落，
    # 保证先落的（更靠后）不会挪动后落的（更靠前）的偏移。
    for start, end, rep in sorted(ops, key=lambda e: -e[0]):
        src = src[:start] + rep + src[end:]

    # ── 收拢「被删整条语句」在**同一 region 内**留下的**连续 ≥2 个空行**（协调者 2026-10-11 答 Q1）──
    # 只收**裁定 1 的删除缝**处那一段；**不做全档「≥2 空行 → 1」的全局收拢**
    # ——语料里本来就有大量「连续 2 空行」的原有写法（实测 11 档：corearch/ast/checker/
    # fmt/frame/regalloc/instr/ld/term_io/elf/opt），全局收拢会**平白吃掉原文的空行**、
    # 让 V4b 假性下降。⇒ 只在删除缝那一处收，且只在缝本身确实≥2 时才收。
    if seams:
        src, collapsed = _collapse_blank_runs_at(
            src, [_map_pos(x, ops) for x in seams])
        recs['blank_collapsed'] = collapsed
    return src, recs, unresolved


def _map_pos(x, ops):
    """把**编辑前**的偏移 `x` 映射到**编辑后**的偏移（`ops` = 全部 (start,end,rep)）。"""
    shift = 0
    for s, e, r in sorted(ops, key=lambda o: o[0]):
        if s >= x:
            break
        if e <= x:
            shift += len(r) - (e - s)
    return x + shift


def _collapse_blank_runs_at(text, positions):
    """把 `positions` 各自所在的那一段**连续空行**（长度 ≥2 时）收成 1 行。

    返回 `(新文本, 收拢点行号表)`。**只在这些位置收**——不动别处的原有空行。
    """
    lines = text.split('\n')
    sentinel = len(lines) - 1 if lines and lines[-1] == '' else len(lines)
    starts, pos = [], 0
    for l in lines:
        starts.append(pos)
        pos += len(l) + 1
    import bisect
    touched, drop = set(), set()
    for p in positions:
        i = bisect.bisect_right(starts, p) - 1
        j = i
        if not (0 <= j < sentinel) or lines[j].strip():
            j = i - 1                      # 缝落在非空行上 ⇒ 看它前面那一行
        if not (0 <= j < sentinel) or lines[j].strip():
            continue
        a = j
        while a > 0 and a - 1 < sentinel and not lines[a - 1].strip():
            a -= 1
        b = j
        while b + 1 < sentinel and not lines[b + 1].strip():
            b += 1
        if b in touched:
            continue
        for k in range(a, b + 1):
            touched.add(k)
        if b - a + 1 >= 2:                 # ≥2 才收；孤立的 1 行不动
            for k in range(a + 1, b + 1):
                drop.add(k)
    kept = [l for k, l in enumerate(lines) if k not in drop]
    return '\n'.join(kept), ['line %d' % (k + 1) for k in sorted(drop)]


# ── 改写 ──────────────────────────────────────────────────────────────────────
def transform_text(src, filename='<unknown>', empty_policy='table'):
    """v3 文本 → v4 文本。返回 `(out, report)`；不可机械改写时抛 `MigrateError`。"""
    report = {'file': filename, 'notes': [], 'merges': [], 'aborted': None}
    if empty_policy == 'table':
        src, recs, unresolved = pre_transform(src, filename)
        for k, v in recs.items():
            report[k] = v
        if unresolved:
            report['aborted'] = 'unresolved: ' + '; '.join(unresolved)
            return None, report

    toks = [t for t in V3.Lexer(src, filename).tokenize()]
    if toks and toks[-1].type == T.EOF:
        toks[-1].start = len(src)
        toks[-1].end = len(src)
    brace_kind, semi_kind, brace_match, notes = classify(toks)
    report['notes'] = notes

    # 空 region 是 v4 的表达盲区（region 不能为空：`if x:` 之后必须有一个更深列的真 token）。
    # 注意：**只含注释的 region 与真空 region 在 token 面上不可区分**（注释不是 token）
    # ⇒ 两者由同一条判定抓住（`brace_match[i] == i+1`）。
    # `table` 策略下这一轮应已由 `pre_transform` 清空；仍有残留 ⇒ fail-closed 中止。
    empty_braces = set()
    for i, tk in enumerate(toks):
        if brace_kind.get(i) == 'block' and brace_match.get(i) == i + 1:
            empty_braces.add(i)
            report.setdefault('empty_regions', []).append(
                'offset %d (line %d)' % (tk.start, tk.line))
    if empty_braces and empty_policy != 'unit':
        report['aborted'] = ('empty region(s): %s' % '; '.join(report['empty_regions']))
        return None, report

    out = []
    cur = ''
    indent = 0
    depth = 0            # 括号/结构体字面量深度（>0 ⇒ 隐式续行，layout 关闭）
    line_base = 0        # **本行起始时**的 bracket depth —— 见 flush() 的注释
    region_stack = []
    split_pending = False
    prev_end = 0
    prev_tok = None

    def flush():
        nonlocal line_base
        # 行的缩进取「**本行起始时**的 bracket depth」（`line_base`），不是 flush 时的 `depth`。
        # 理由（实测撞出的真缺陷）：`foo(a,\n  b)` 这类括号内续行的**首行**，
        # 若按 flush 时的 depth 缩进，会得到比语句基准更深的列；而 v4 lexer 在**该行首个
        # token** 处 bracket_depth 还是 0 ⇒ 它会发一个 INDENT ⇒ parser 在表达式位看到 INDENT
        # 而响亮报错（hit.cr:1103 就是这样红的）。续行的第二行起，lexer 的 bracket_depth>0
        # ⇒ 不发 layout，缩进深浅无所谓；把它排在更深列只为可读性。
        nonlocal cur
        if cur.strip():
            out.append(INDENT_UNIT * (indent + line_base) + cur.strip())
        cur = ''
        line_base = depth

    def emit_gap(gap, force, merge):
        nonlocal cur
        if merge:
            i1 = gap.index('\n')
            if '//' in gap[:i1] or '/*' in gap[:i1]:
                report['merges'].append(
                    'COMMENT-BLOCKED merge at offset ~%d: %r' % (prev_end, gap[:i1]))
                # 不并（保留行断），V1 会把它抓出来
                _plain_gap(gap, force)
                return
            cur += ' '
            report['merges'].append('merged continuation near offset %d' % prev_end)
            return
        _plain_gap(gap, force)

    def _plain_gap(gap, force):
        nonlocal cur, line_base
        if '\n' not in gap:
            cur += gap
            if force:
                flush()
            return
        # **按物理行拆，不按「首尾换行下标之间的切片」拆**。
        # 修复前的写法 `mid = gap[i1+1:ilast]` + `if mid:` 在**连续换行**时把空行吞掉：
        # gap == '\n\n'（= 一个空行）时 mid == '' ⇒ 不产出任何行 ⇒ 空行消失。
        # 后果实测：`}` 行被删除后、其后那个空行一起没了 ⇒ 全语料「函数紧贴函数」
        # （`src/stdlib/fmt.cr` 空行 18 → 7，协调者抽检抓到）。
        # 正确拆法：`gap.split('\n')` 的 `[1:-1]` 恰是「夹在首尾换行之间的整行」，
        # k 个换行 ⇒ k-1 个整行（空行按原样留成空串）。T0 §1.1 ①-1：空行不参与 layout ⇒ 保留零风险。
        parts = gap.split('\n')
        cur += parts[0]
        flush()
        out.extend(parts[1:-1])
        tail = parts[-1]
        if tail.strip():
            # 收尾那截（下一个 token 所在行的行首缩进）里**可能有块注释**（`/* … */ fn`）：
            # 有内容就不能丢，降为独立行；纯空白则丢弃（缩进由本工具自算）。
            out.append(tail)
        cur = ''
        line_base = depth

    for idx, tk in enumerate(toks):
        if tk.type == T.EOF:
            emit_gap(src[prev_end:tk.start], force=split_pending, merge=False)
            flush()
            break
        gap = src[prev_end:tk.start]
        force = split_pending
        split_pending = False
        merge = False
        if '\n' in gap and depth == 0 and not force:
            if prev_tok is not None and prev_tok.type in BINOP_END:
                merge = True
            elif tk.type in BINOP_START and prev_tok is not None \
                    and prev_tok.type not in (T.SEMI, T.LBRACE, T.RBRACE):
                merge = True
        emit_gap(gap, force, merge)

        t = tk.type
        if t == T.SEMI:
            if semi_kind.get(idx) == 'array':
                cur += ';'
            else:
                split_pending = True
        elif t == T.LBRACE:
            if brace_kind[idx] == 'block':
                # ── Allman 形（块 `{` 独占行首）修复（协调者 2026-10-11 裁定 2）──────────
                # 修复前：`cur` 为空时也 `cur = '' + ':'` ⇒ 发射出一行**孤零零的 `:`**，
                # 该行既不接上文、也不开 region（实测 `tests/spec/t2_pos_check.cr` 等 9 档
                # 变成 `fn f() -> int` / `#check(1 >= 0)` / `:` 三行 ⇒ 自源报 {P02,P25,V02}）。
                # 修复后：`{` 独占行首 ⇒ `:` 落到**上一个非空输出行**末尾（该行本就是它
                # 逻辑上的头部行），`{` 那一行随之消失。纯 layout、零 token 变更。
                # ⚠ 边界：若该行是注释行，追加 `:` 会被注释吞掉 ⇒ 不追加，退化为独立 `:` 行，
                #    并**响亮登记**（不静默）。
                if cur.strip():
                    cur = cur.rstrip() + ':'
                    flush()
                else:
                    j = len(out) - 1
                    while j >= 0 and not out[j].strip():
                        j -= 1
                    if j >= 0 and not out[j].lstrip().startswith('//') \
                            and '//' not in out[j]:
                        out[j] = out[j].rstrip() + ':'
                        report.setdefault('allman_join', []).append('line %d' % tk.line)
                    else:
                        out.append(':')
                        report.setdefault('allman_orphan_colon', []).append('line %d' % tk.line)
                region_stack.append(indent)
                indent += 1
                if idx in empty_braces:
                    # 策略 `unit`：空 region 里补一个 `unit` 表达式（v4 唯一的空值字面量；
                    # **`()` 在 v4 前端不可用**——`parse_primary` 的 LPAREN 分支不容空括号）。
                    # ⚠ 这是**唯一会新增 token 的改写**，逐处登记在报告的 `unit_filled` 里。
                    cur = 'unit'
                    split_pending = True
                    report.setdefault('unit_filled', []).append('line %d' % tk.line)
            else:
                cur += '{'
                depth += 1
        elif t == T.RBRACE:
            if brace_kind[idx] == 'block':
                flush()
                indent = region_stack.pop()
            else:
                depth -= 1
                cur += '}'
        elif t == T.LPAREN:
            cur += '('
            depth += 1
        elif t == T.RPAREN:
            depth = max(0, depth - 1)
            cur += ')'
        elif t == T.LBRACK:
            cur += '['
            depth += 1
        elif t == T.RBRACK:
            depth = max(0, depth - 1)
            cur += ']'
        else:
            # **原文切片**，不用 `tk.lexeme` —— 字符串/字符字面量的 lexeme 是**解码后**的
            # 内容（`""` 会变成空串、`"\n"` 会变成真换行），十六进制整数字面量的 lexeme
            # 是十进制值。取源切片才能逐字保留。
            cur += src[tk.start:tk.end]
        prev_end = tk.end
        prev_tok = tk
        if split_pending and t != T.SEMI:
            # 兜底：非 `;` 的 token 也可能置位（不会发生），保守清掉
            pass

    # 行尾空白清理：注释行/空行是**逐字搬运**的，被删掉的 `if … {` 会留下「只有空格」的行；
    # 统一 `rstrip` 每行（行尾空白对任何判定依据都无意义）⇒ 产物 = `transform(基线)` 的确定函数。
    #
    # 末尾换行**恒补一个**（`'\n'.join(out) + '\n'`）：`out` 的每一项是「一行」，
    # 于是 `out = […, 'X', '']` 必须落成 `…X\n\n`（= X 之后**一个空行**），
    # 而 `'\n'.join` 单独用只会落成 `…X\n`（空行被 join 吃掉）——实测后果：
    # 语料里以 `}\n\n` 收尾的档会少掉 EOF 那个空行（`src/kernel/term_io.cr` 因此 V4b 降 1）。
    text = ('\n'.join(l.rstrip() for l in out) + '\n') if out else ''
    return text, report


# ── V1：v4 前端解析 ───────────────────────────────────────────────────────────
V1_ENGINE = 'py'      # 由 --v1-engine 覆盖（T6a 追加，见下）
REPO_ROOT = os.path.dirname(_HERE)


def _v4_parse_ok_native(text, filename):
    """用**本仓自源编译器**（`build/corec check`）做 v4 解析读数。

    T6a 追加的理由（实测，逐条可复现）：`bootstrap/` 的 Python 前端**落后于**自源前端，
    在本次语料上至少四处误报（自源 rc=0 而 Python 前端语法错）：
      · 语句位 `as` 转换（`n := d as int`）——Python 前端「expected end of line, got 'as'」；
      · `extern fn` 顶层声明；· `go i 0..3 f(i)`（并行 for）；· `*T` 作结构体字段类型 / 元组类型。
    ⇒ 对 `src/` 之外这阶段语料，**判定依据的目标前端是自源编译器**（T5 已落地）；Python 前端只作补充。
    临时落盘路径保留相对路径（import 解析靠文件所在目录），cwd = 仓根（prelude 取自 `src/stdlib/`）。
    """
    import subprocess
    import shutil
    rel = filename if not os.path.isabs(filename) else os.path.basename(filename)
    tmp = os.path.join('/tmp/v4_migrate_v1', rel)
    os.makedirs(os.path.dirname(tmp), exist_ok=True)
    with open(tmp, 'w', encoding='utf-8') as fh:
        fh.write(text)
    cc = os.path.join(REPO_ROOT, 'build', 'corec')
    if not os.path.exists(cc):
        return None, 'native engine unavailable (no build/corec)'
    p = subprocess.run(['nice', '-n', '19', cc, 'check', tmp],
                       cwd=REPO_ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    out = p.stdout.decode('utf-8', 'replace')
    if p.returncode == 0:
        return True, None
    # **只把 parse 相（[3/5] 与 [4/5] 之间）的 error 算 V1 失败**。
    # 理由：本次一半语料是**负例**（probes/spec/suite 的 rc=1 是**预期**），`check` 的 rc
    # 把「解析失败」与「语义/负例报错」混在一个数里 ⇒ 直接拿 rc 当 V1 会把负例全部误判。
    # 空文件（`cannot read`，出现在 [1/5] 之前）不计失败（T6a 面有 4 档 0 字节档）。
    lines = out.splitlines()
    i0 = next((k for k, l in enumerate(lines) if l.startswith('[3/5]')), len(lines))
    i1 = next((k for k, l in enumerate(lines) if l.startswith('[4/5]')), len(lines))
    errs = [l for l in lines[i0:i1] if l.startswith('error')]
    if errs:
        return False, ('native parse error (rc=%d): %s' % (p.returncode, '; '.join(errs[:3])))
    return True, None


def v4_parse_ok(text, filename='<in-memory>'):
    eng = V1_ENGINE
    if eng in ('both', 'native'):
        ok, err = _v4_parse_ok_native(text, filename)
        if err is not None and err.startswith('native engine unavailable'):
            if eng == 'native':
                return ok, err
        elif ok:
            return True, None
        elif eng == 'native':
            return False, err
    from corec.frontend.lexer import Lexer
    from corec.frontend.parser import Parser
    try:
        Parser(Lexer(text, filename).tokenize()).parse_compilation_unit()
        return True, None
    except Exception as e:  # SyntaxError / 其它
        return False, '%s: %s' % (type(e).__name__, e)


# ── V2：token 序列对拍 ────────────────────────────────────────────────────────
_V3_DROP = {T.SEMI, T.LBRACE, T.RBRACE}
# v4 面：NEWLINE/INDENT/DEDENT 是 layout 发射；COLON_BLOCK 是 `{` 的**结构替身**
# （v3 的 LBRACE 已被丢弃 ⇒ COLON_BLOCK 也必须丢，否则每一处块开都成假差异）。
_V4_DROP = {'NEWLINE', 'INDENT', 'DEDENT', 'COLON_BLOCK'}
_V4_RENAME = {'COLON_DECL': 'COLON'}


def v2_tokens_v3(src):
    """v3 侧可对拍 token 序列。

    丢弃面**按分类**取，不是按 token 种类一把抓：
      - `SEMI`：只丢**语句分隔**的（`stmt`），**数组形的 `;`（`[T; N]` / `[v; N]`）保留**；
      - `LBRACE`/`RBRACE`：只丢**块**的，**结构体字面量的花括号保留**（v4 里它们是原形）。
    若一把抓全丢，则 `[N; 4]` 与 `MemLayout { … }` 会与 v4 侧错位（首轮实测：collections.cr
    差 701 项、toml.cr 差 38 项 —— 全是这个错位的后果）。
    """
    toks = V3.Lexer(src).tokenize()
    brace_kind, semi_kind, _bm, _n = classify(toks)
    seq = []
    for i, tk in enumerate(toks):
        if tk.type == T.EOF:
            continue
        if tk.type == T.SEMI and semi_kind.get(i) == 'stmt':
            continue
        if tk.type in (T.LBRACE, T.RBRACE) and brace_kind.get(i) == 'block':
            continue
        seq.append((tk.type.name, tk.lexeme))
    return seq


def v2_tokens_v4(text):
    from corec.frontend.lexer import Lexer
    seq = []
    for tk in Lexer(text).tokenize():
        name = tk.type.name
        if name in _V4_DROP or name == 'EOF':
            continue
        seq.append((_V4_RENAME.get(name, name), tk.lexeme))
    return seq


def v2_diff(old_src, new_text):
    """按**最长公共子序列**对齐两侧 token，返回真正的增删项。

    位置对齐（`a[i] != b[i]`）在**有一处增删**时会把其后全部标成差异（相位错位）
    —— 那不可读也不可审。⇒ 用 `difflib.SequenceMatcher` 取 edit script。
    """
    import difflib
    a = v2_tokens_v3(old_src)
    b = v2_tokens_v4(new_text)
    sm = difflib.SequenceMatcher(a=a, b=b, autojunk=False)
    diffs = []
    for tag, i1, i2, j1, j2 in sm.get_opcodes():
        if tag == 'equal':
            continue
        diffs.append((tag, a[i1:i2], b[j1:j2]))
    return a, b, diffs


# ── V3 / V4 计数 ──────────────────────────────────────────────────────────────
def brace_counts(text):
    """(裸字符花括号计数, 代码面花括号 token 计数)。"""
    raw_open = text.count('{')
    raw_close = text.count('}')
    return raw_open, raw_close


def comment_counts(text):
    """粗算注释条数：`//` 行数与 `/* */` 块数（够用于「不得下降」的判定依据）。"""
    line_c = 0
    for ln in text.split('\n'):
        s = ln.lstrip()
        if s.startswith('//'):
            line_c += 1
    line_c += len(re.findall(r'(?<!:)//', text)) - line_c if False else 0
    inline = len(re.findall(r'\S[ \t]*//', text))
    block = len(re.findall(r'/\*', text))
    return {'comment_lines': line_c + len(re.findall(r'\S[ \t]*//', text)),
            'block_comments': block}


def _lines(text):
    """物理行表（去掉「以 `\n` 收尾」产生的那个尾空元素 ⇒ 与 `grep -c '^$'` 同规则）。"""
    ls = text.split('\n')
    if ls and ls[-1] == '':
        ls.pop()
    return ls


def file_metrics(text):
    """逐档读数：花括号（裸）、`;`（裸）、注释、空行。

    **V4 是双读数**（协调者 2026-10-11 补判定依据缺口）：
      - V4a `comment_lines` = `//` 起首的行数（**不得下降**）；
      - V4b `blank_lines`   = 空行数（**不得下降**）。
    只查 V4a 会漏掉「`}` 行消失时把相邻空行一起吞掉」这类格式回归——
    实测过：`src/stdlib/fmt.cr` 空行 17 → 6（`}` 行与其后空行一起没了 ⇒ 函数紧贴函数）。
    """
    ls = _lines(text)
    return {
        'brace_open': text.count('{'),
        'brace_close': text.count('}'),
        'semi': text.count(';'),
        'comment_lines': sum(1 for l in ls if l.lstrip().startswith('//')),
        'blank_lines': sum(1 for l in ls if not l.strip()),
        'block_comment_open': text.count('/*'),
    }


# V4b 的**合法下降**例外：被裁定删掉的整条 `if … { }` / 空 `else { }` 会带走它内部的空行。
# 其余任何档的下降 ⇒ FAIL。
V4B_BLANK_DROP_EXEMPT = {
    'src/compiler/interp.cr', 'src/compiler/main.cr', 'src/compiler/module.cr',
    'src/compiler/opt.cr', 'src/compiler/provenance_verify.cr',
}


def _has_v3_markers(src):
    """输入里是否还有 v3 专属形状（**块** `{}` / **语句** `;`）。

    T6a 追加（协调者第 2 条裁定）：本工具是**一次性 v3→v4** 工具。对**已经是 v4 的文本**
    再跑一次，vendored v3 词法器会把它当 v3 读，发射器产出错形——实测重跑
    `tests/spec/t2_pos_check.cr`（已是 v4）得到 `fn f() -> int #check(1 >= 0):` +
    **缩进被吃的** `return 1`。⇒ **无 v3 形状标记却会改动文本 ⇒ 拒写**（fail-closed）。
    `[T; N]` 的 `;` 与 struct 字面量的 `{}` **不算标记**（它们 v3/v4 同形）。
    """
    try:
        toks = [t for t in V3.Lexer(src, '<probe>').tokenize()]
        bk, sk, _bm, _n = classify(toks)
    except MigrateError:
        return True                      # 读不动 ⇒ 交正常路径响亮报错
    return any(v == 'block' for v in bk.values()) or any(v == 'stmt' for v in sk.values())


# ── CLI ───────────────────────────────────────────────────────────────────────
def gather(paths, all_under):
    out = []
    for p in paths:
        out.append(p)
    for d in all_under or []:
        for root, _, fs in os.walk(d):
            for f in fs:
                if f.endswith('.cr'):
                    out.append(os.path.join(root, f))
    return sorted(set(out))


def cmd_transform(args):
    files = gather(args.files, args.all_under)
    if not files:
        print('no files', file=sys.stderr)
        return 2
    n_ok = n_abort = n_fail = n_forced = n_refuse = 0
    for p in files:
        src = open(p, encoding='utf-8').read()
        try:
            out, rep = transform_text(src, p, args.empty_policy)
        except MigrateError as e:
            print('ABORT  %-45s %s' % (p, e))
            n_fail += 1
            continue
        if out is None:
            print('SKIP   %-45s %s' % (p, rep['aborted']))
            n_abort += 1
            continue
        ok, err = v4_parse_ok(out, p)
        if out != src and not _has_v3_markers(src):
            print('REFUSE %-45s 输入无 v3 形状标记（已是 v4？）⇒ 拒写；重跑本工具会 mangle' % p)
            n_refuse += 1
            continue
        if not ok and not args.force:
            print('V1FAIL %-45s %s' % (p, err))
            n_fail += 1
            if args.dry_run:
                print(out)
            continue
        if not ok:
            print('V1FAIL(force) %-45s %s' % (p, err))
            n_forced += 1
        if args.dry_run:
            sys.stdout.write(out)
            print('--- %s OK ---' % p, file=sys.stderr)
        else:
            with open(p, 'w', encoding='utf-8') as fh:
                fh.write(out)
            extra = ''
            for k in ('deleted_if', 'return_filled', 'hoisted'):
                if rep.get(k):
                    extra += ' | %s=%s' % (k, ','.join(rep[k]))
            print('OK     %-45s%s' % (p, extra))
        n_ok += 1
    print('=== transform: ok=%d skip=%d fail=%d forced=%d refuse=%d ==='
          % (n_ok, n_abort, n_fail, n_forced, n_refuse))
    return 1 if n_fail else 0


def cmd_check(args):
    files = gather(args.files, args.all_under)
    tot = {'brace_open': 0, 'brace_close': 0, 'semi': 0,
           'comment_lines': 0, 'blank_lines': 0}
    v1_fail = v2_fail = v4a_fail = v4b_fail = 0
    print('%-40s %5s %5s %6s | %-13s | %-13s | %s' %
          ('file', '{', '}', ';', 'V4a // b->a', 'V4b blank b->a', 'V1/V2'))
    for p in files:
        new = open(p, encoding='utf-8').read()
        m = file_metrics(new)
        for k in tot:
            tot[k] += m[k]
        bp = os.path.join(args.baseline, p) if args.baseline else None
        old = open(bp, encoding='utf-8').read() if (bp and os.path.exists(bp)) else None
        # 与基线**逐字节相同** ⇒ 本档未迁移（不是「迁移失败」）。它的 V1 仍会红
        # （还是 v3 文本），V2 也会「差」（v3 侧块花括号被丢、v4 侧没丢）。
        # ⇒ 显式标 UNCHANGED 且**不计入失败**，否则报告把「跳过」读成「改坏」。
        if old is not None and old == new:
            print('%-40s %5d %5d %6d | %-13s | %-13s | UNCHANGED (未迁移)' %
                  (p, m['brace_open'], m['brace_close'], m['semi'], '-', '-'))
            continue
        ok, err = v4_parse_ok(new, p)
        v1s = 'V1ok' if ok else 'V1FAIL'
        if not ok:
            v1_fail += 1
        v2s = v4as = v4bs = ''
        if old is not None:
            om = file_metrics(old)
            v4as = '%d->%d' % (om['comment_lines'], m['comment_lines'])
            v4bs = '%d->%d' % (om['blank_lines'], m['blank_lines'])
            if m['comment_lines'] < om['comment_lines']:
                v4a_fail += 1
                v4as += ' FAIL'
            if m['blank_lines'] < om['blank_lines']:
                if p in V4B_BLANK_DROP_EXEMPT:
                    v4bs += ' DROP(裁定删语句·已归因)'
                else:
                    v4b_fail += 1
                    v4bs += ' FAIL'
            try:
                a, b, diffs = v2_diff(old, new)
                if diffs:
                    v2_fail += 1
                    v2s = 'V2DIFF(%d)' % len(diffs)
                else:
                    v2s = 'V2ok'
            except MigrateError as e:
                v2s = 'V2skip(%s)' % e
        print('%-40s %5d %5d %6d | %-13s | %-13s | %s %s %s' %
              (p, m['brace_open'], m['brace_close'], m['semi'],
               v4as, v4bs, v1s, v2s, (err or '')[:40]))
    print('%-40s %5d %5d %6d | %-13s | %-13s' %
          ('TOTAL', tot['brace_open'], tot['brace_close'], tot['semi'],
           str(tot['comment_lines']), str(tot['blank_lines'])))
    print('V1 failures: %d | V2 mismatching files: %d | V4a (comment) drops: %d | V4b (blank) drops: %d'
          % (v1_fail, v2_fail, v4a_fail, v4b_fail))
    return 1 if (v1_fail or v4a_fail or v4b_fail) else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)

    t = sub.add_parser('transform')
    t.add_argument('files', nargs='*')
    t.add_argument('--all-under', nargs='*', default=None)
    t.add_argument('--dry-run', action='store_true')
    t.add_argument('--force', action='store_true',
                   help='T6a 追加：V1 失败仍写盘。**只对「解析失败是预期结果」的负例语料用**'
                        '（tests/spec/t2_neg_* 等）；正例档用它是掩盖回归，不得使用。')
    t.add_argument('--v1-engine', default='py', choices=['py', 'native', 'both'],
                   help='V1 解析读数用哪个前端（T6a 追加）：py=bootstrap Python 前端（原行为）· '
                        'native=本仓 build/corec · both=优先 native')
    t.add_argument('--empty-policy', default='table',
                   choices=['table', 'skip', 'unit'],
                   help='空 region 的处置：table=逐处裁定表(默认) · skip=中止 · unit=补 unit 占位(调试用)')
    t.set_defaults(func=cmd_transform)

    c = sub.add_parser('check')
    c.add_argument('files', nargs='*')
    c.add_argument('--all-under', nargs='*', default=None)
    c.add_argument('--v1-engine', default='py', choices=['py', 'native', 'both'])
    c.add_argument('--baseline', default=None,
                   help='改前原文快照目录（同相对路径）')
    c.set_defaults(func=cmd_check)

    args = ap.parse_args()
    global V1_ENGINE
    V1_ENGINE = getattr(args, 'v1_engine', 'py')
    return args.func(args)


if __name__ == '__main__':
    sys.exit(main())
