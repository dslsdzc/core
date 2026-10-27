#!/usr/bin/env python3
"""v4 迁移 T6b —— **内嵌 Core 源**的机械改写工具（T4 工具 `tools/v4_migrate.py` 的「内嵌版」）。

存在理由：T4 的 `v4_migrate.py` 处理的是**整档 `.cr`**（整篇就是 Core）。T6b 的语料是
**嵌在别的语言里**的 Core 片段——`.py` 的三引号字符串 / `.md` 的 ``` 围栏块 / `rebuild.sh`
的单引号内联命令。这些宿主文件里**只有那几段**是 Core，其余字节（缩进、引号风格、fence
标记、行尾空白）**必须一字不动**。

转换核心 = `import v4_migrate`（**不复制实现**——两份必然漂）。本文件只负责：
  ① 判定「哪几段是 Core 源」（`is_core`）；
  ② 逐字节安全地抽取/回填（`migrate_py` / `migrate_md`），宿主非 Core 面零改动。

判定依据（双轨，见 T6b 任务书）：
  - 机械轨：每个被改写的段做 V2（与改前**逐 token 相同**）+ V4a/V4b（注释行/空行**不下降**）；
  - 真实轨：`tests/bootstrap/*.py` 必须全绿、`tests/selfhost/*.py` 能跑的必须绿。

用法：
    python3 tools/v4_migrate_inline.py report            # 逐档列出被判定为 Core 的段（不动盘）
    python3 tools/v4_migrate_inline.py apply  FILE...    # 原地改写（.py / .md / .sh）
"""
import argparse
import ast
import os
import re
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)
sys.path.insert(0, os.path.join(os.path.dirname(_HERE), 'bootstrap'))

import v4_migrate as M  # noqa: E402

T = M.T

# ── 「是 Core 源」的判定 ──────────────────────────────────────────────────────
# **不用「改完能 v4 解析」当判定依据**：语料里有大量**故意写坏**的负例夹具（未知标签 /
# 嵌套 fn / 非穷尽 match / 语法错），它们的 v4 解析**本就必须失败**。用解析成功当判定依据
# 会把这一类整阶段漏掉（实测：734 过 / 461 漏，漏的几乎全是负例夹具）。
#
# 改判定依据：**声明头 / 语句形态**正则 + v3 词法可切（`transform_text` 不抛）双条件。
# 前者抓 Core 的形态，后者排除散文（散文的括号/花括号通常不平衡 ⇒ transform 抛）。
CORE_DECL_RE = re.compile(
    r'\bfn\s+(?:[A-Za-z_]\w*\s*[\[\(]|[A-Za-z_]\w*\s*->)'   # fn f(...) / fn f[T](...) / fn f() -> T
    r'|\bstruct\s+[A-Za-z_]\w*'
    r'|\benum\s+[A-Za-z_]\w*'
    r'|\bimpl\s+[A-Za-z_\[]'
    r'|\biface\s+[A-Za-z_]\w*'
    r'|\binterface\s+[A-Za-z_]\w*'
    r'|\bextern\s+fn\s'
    r'|\bimport\s+[A-Za-z_@]'
)
# 语句/表达式**片段**（无声明头）：`x := e;` / `x : T = e;` / `x : T, mut = e;`
CORE_STMT_RE = re.compile(r'^[ \t]*[A-Za-z_]\w*\s*(?::[^=]*)?:=')
CORE_STMT2_RE = re.compile(r'^[ \t]*[A-Za-z_]\w*\s*:[^=;]*=')


def is_core(s):
    """字符串 `s` 是否为内嵌 Core 源（形状判定；不做解析）。"""
    if not s.strip():
        return False
    # **v3 的两个记号必居其一**：v3 Core 的块 `{` 或语句 `;`。这条同时是**散文过滤器**
    # （`"[PASS] import module : alias ..."` 这类散文会被 `import\s+\w` 误抓 ⇒ 此处挡掉）。
    if '{' not in s and ';' not in s:
        return False
    if not (CORE_DECL_RE.search(s) or CORE_STMT_RE.search(s) or CORE_STMT2_RE.search(s)):
        return False
    if s.lstrip().startswith('#'):
        return False                      # Python 注释行（非字符串内容）
    return True


def already_v4(s):
    """判「已经是我形、无可转换」的两条独立依据（取或）：

    ① **形状**：v3 的两个记号（块 `{` / 语句 `;`）都不在 ⇒ 没有可转换的东西。
       这条专门兜住「v4 形但**故意写坏**的负例」（未知标签等）与带 `#check` 契约的行
       ——它们 `v4_parse_ok` 必然 False，却已是我形。
    ② **解析**：`v4_parse_ok(s)`（兜住「v4 形 + 含结构体字面量 `{`」这类混合形，
       例如 `struct Point:` 与 `Point { x = 20 }` 同档）。
    """
    if '{' not in s and ';' not in s:
        return True
    return M.v4_parse_ok(s)[0]


# 两侧词法器的**已知分歧**（非迁移引入，V2 对拍须归一化）：同一个词素在 vendored v3
# 扫描器里是 IDENT、在 v4 前端里是**关键字**（`Some`/`None`/`never`/`dyn`/…）。迁移**从不
# 改词素** ⇒ 对**词素形如标识符**的 token 一律折叠成同一类，词素本身仍逐字比对。
_IDLIKE = re.compile(r'^[A-Za-z_]\w*$')


def _v2_norm(tok):
    t, lx = tok
    if lx == 'None':          # E5：v4 关键字拼写（`None` ⇒ `none`）——**本次唯一的非形状改写**
        lx = 'none'
    return ('ID', lx) if _IDLIKE.match(lx) else (t, lx)


def _v3_tokens(old):
    """v3 侧可对拍 token 序列（`v4_migrate.v2_tokens_v3` 的**本工具版**）。

    差别只有一条：**臂体块的花括号也丢**。`v4_migrate` 只丢 `brace_kind == 'block'` 的，
    而 `classify` 把 `=> {` 标成 `arm`（T6a 追加）⇒ 臂体花括号留在 v3 侧、v4 侧却是
    `=>:` + region ⇒ 每处臂体一个假 V2 差异（实测）。本工具已把臂体改写成文档形
    （`=>:` + region）⇒ v3 侧那对花括号同样是**结构替身**，必须一并丢。
    """
    toks = M.V3.Lexer(old).tokenize()
    bk, sk, _bm, _n = M.classify(toks)
    seq = []
    for i, tk in enumerate(toks):
        if tk.type == M.T.EOF:
            continue
        if tk.type == M.T.SEMI and sk.get(i) == 'stmt':
            continue
        if tk.type in (M.T.LBRACE, M.T.RBRACE) and bk.get(i) in ('block', 'arm'):
            continue
        seq.append((tk.type.name, tk.lexeme))
    return seq


def v2_check(old, new):
    """V2：与改前**逐 token 相同**。返回 diffs（归一化后）。"""
    import difflib
    a = _v3_tokens(old)
    b = M.v2_tokens_v4(new)
    diffs = []
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(a=a, b=b, autojunk=False).get_opcodes():
        if tag != 'equal':
            diffs.append((tag, a[i1:i2], b[j1:j2]))
    norm = []
    for tag, x, y in diffs:
        x = [_v2_norm(t) for t in x]
        y = [_v2_norm(t) for t in y]
        if x != y:
            norm.append((tag, x, y))
    return norm


def _encode_literal(text, quote):
    """把 `text` 重新编成用 `quote` 定界的字面量**体**（保留宿主的转义风格）。"""
    out = []
    for ch in text:
        if ch == '\\':
            out.append('\\\\')
        elif ch == '\n':
            out.append('\n' if len(quote) == 3 else '\\n')
        elif ch == '\r':
            out.append('\\r')
        elif ch == '\t':
            out.append('\\t')
        elif ch in ('"', "'") and quote[0] == ch and len(quote) == 1:
            out.append('\\' + ch)
        else:
            out.append(ch)
    return ''.join(out)


# ── 片段的重缩进 ──────────────────────────────────────────────────────────────
# `transform_text` 按 **region 嵌套深度**重算缩进，深度 0 ⇒ 输出一律顶格。这对
# 「整档」是对的，对**片段**（例如插入到函数体里的 `    xv := x0 + 7;`）会**丢掉缩进**。
# ⇒ 取原文非空行的**最小缩进**当基准，改写后逐行补回。
def struct_colon_to_eq(src):
    """**v4 判定 ④**（`v4-layout-spec.md` §4）：struct 字面量的字段分隔符必须是 `=`，
    `:` 形在整个语言里不存在（parser 在分隔符位点响亮拒绝 `P030`）。v3 两形都收
    （`v4_migrate._is_struct_lit`：花括号后首 token 是 IDENT 且再下一个是 `=` **或** `:`）
    ⇒ 这是 T4 的形状改写**没覆盖**的一类（T4 逐字保留字面量内部），本工具补上。

    只动**结构体类的花括号**内、**相对深度 0** 的 `:` token，逐字节安全。
    """
    toks = [t for t in M.V3.Lexer(src).tokenize()]
    if toks and toks[-1].type == T.EOF:
        toks[-1].start = len(src)
        toks[-1].end = len(src)
    # 警告：**不能直接用 `v4_migrate.classify`**：它的 `decl_brace_pending` 假定「`struct`/`enum`/
    # `impl`/`interface` 之后的首个 `{` = 声明体」（v3 事实）。v4 的声明体是 `:` + region、
    # **没有** `{` ⇒ 该标志会一直挂到**后面第一个结构体字面量**上，把它误判成 block
    # （实测：`struct P:` … `P{b: 11}` 的 `{` 被判 block ⇒ 分隔符一处也不改）。
    # ⇒ 本处自带一份：遇到 `:`（v4 声明体的 region 头）即**清掉** pending。
    brace_kind, brace_match = {}, {}
    stack = []
    pending = False
    for i, tk in enumerate(toks):
        t = tk.type
        if t in (T.STRUCT, T.ENUM, T.IMPL, T.INTERFACE):
            pending = True
        elif t == T.COLON:
            pending = False
        elif t == T.LBRACE:
            prev = toks[i - 1] if i > 0 else None
            is_arm = prev is not None and prev.type == T.FAT_ARROW
            is_struct = (not is_arm and not pending and prev is not None
                         and prev.type == T.IDENT and prev.lexeme[:1].isupper()
                         and M._is_struct_lit(toks, i))
            pending = False
            brace_kind[i] = 'struct' if is_struct else ('arm' if is_arm else 'block')
            stack.append(('{', i))
        elif t == T.RBRACE:
            if stack and stack[-1][0] == '{':
                _k, oi = stack.pop()
                brace_match[oi] = i
                brace_kind[i] = brace_kind.get(oi, 'block')
        elif t == T.LPAREN:
            stack.append(('(', i))
        elif t == T.LBRACK:
            stack.append(('[', i))
        elif t == T.RPAREN:
            if stack and stack[-1][0] == '(':
                stack.pop()
        elif t == T.RBRACK:
            if stack and stack[-1][0] == '[':
                stack.pop()
    edits = []
    for i, tk in enumerate(toks):
        if tk.type != T.LBRACE or brace_kind.get(i) != 'struct':
            continue
        m = brace_match.get(i)
        if m is None:
            continue
        depth = 0
        for j in range(i + 1, m):
            t = toks[j].type
            if t in (T.LBRACE, T.LBRACK, T.LPAREN):
                depth += 1
            elif t in (T.RBRACE, T.RBRACK, T.RPAREN):
                depth -= 1
            elif t == T.COLON and depth == 0 and j > i + 1 \
                    and toks[j - 1].type == T.IDENT:
                edits.append((toks[j].start, toks[j].end))
    for a, b in sorted(edits, reverse=True):
        src = src[:a] + '=' + src[b:]
    return src, len(edits)


def none_rename(src):
    """v4 关键字拼写：`None` ⇒ `none`（`docs/developer/syntax.md` 关键字表含
    `none`、无 `None`；实测 `x : int? = None` ⇒ `error[N01] Undefined name 'None'`）。

    主路径由 `v4_migrate._t6_extra_ops` 的 E5 负责；此处的副本只服务**短路路径**
    （「已是 v4 形、只差 struct 字面量分隔符」的段——那条路不走 `transform_text`）。
    """
    toks = [t for t in M.V3.Lexer(src).tokenize()]
    edits = [(t.start, t.end) for t in toks
             if src[t.start:t.end] == 'None'
             and (t.type == T.NONE or t.type == T.IDENT)]
    for a, b in sorted(edits, reverse=True):
        src = src[:a] + 'none' + src[b:]
    return src, len(edits)


# 空 region 的**目标形**（维护者 2026-10-11 裁定「规格化」：region 可为空 ⇒ `:` 后不跟 items）。
# 实现法：先给每个空块塞一个**哨兵语句**让 `v4_migrate` 的改写走通（它对空 region fail-closed
# 中止），产物里哨兵会单独占一行 ⇒ 逐行删掉 ⇒ 得 `:` 后无 items 的目标形。
# 这**不是绕过**：产物就是裁定要求的形；哨兵只活在改写过程里，不落盘。
_EMPTY_SENTINEL = '__V4_EMPTY_REGION__'


def _fill_empty_regions(src):
    """把 `{ }` / `{\\n}` 这类**空块**填成 `{ __V4_EMPTY_REGION__; }`；返回 `(新文本, 处数)`。"""
    toks = [t for t in M.V3.Lexer(src).tokenize()]
    if toks and toks[-1].type == T.EOF:
        toks[-1].start = len(src)
        toks[-1].end = len(src)
    try:
        bk, _sk, bm, _n = M.classify(toks)
    except M.MigrateError:
        return src, 0
    spots = [i for i, t in enumerate(toks)
             if t.type == T.LBRACE and bk.get(i) == 'block' and bm.get(i) == i + 1]
    for i in sorted(spots, reverse=True):
        # `{` 的 end 与 `}` 的 start 之间就是空块体（可能含空白/注释）
        pos = toks[i].end
        src = src[:pos] + ' %s;' % _EMPTY_SENTINEL + src[pos:]
    return src, len(spots)


def _strip_sentinels(text):
    keep = [ln for ln in text.split('\n') if ln.strip() != _EMPTY_SENTINEL]
    return '\n'.join(keep)


# ── 臂体块 → **文档形**（`Pat => { BODY }` ⇒ `Pat =>` + region）──────────────────
# 维护者 2026-10-11 裁定（协调者转述）：v4 的臂体 region 形 = `=>` 后接 region（T5 第 4(b)
# 项，`P02` 缺口即此）；**`=> return E` 不是文档形，不得用「消 `return`」绕**。
#
# 实现：`v4_migrate.classify` 把 `=> {` 标成 `arm`（整对花括号抹掉 ⇒ 单行 `=> stmt`），
# 那不是文档形。⇒ 在调用它之前，把一个**良性占位 token** 插进 `=>` 与 `{` 之间，
# 让 `{` 的前驱不再是 `=>` ⇒ 回落成 **block** 分支 ⇒ 得 `=>` + `:` + region。
# 产物里再把占位去掉 ⇒ **`Pat =>:` + region**。
# 警告：只在 `=>` **紧跟** `{` 时插入：那种 `{` 恒是臂体块（结构体字面量须写成 `Foo {`）。
_ARM_BLOCK_RE = re.compile(r'=>([ \t]*)\{')
_ARM_PLACEHOLDER = '(0)'


def arm_block_to_region_src(src):
    return _ARM_BLOCK_RE.sub(lambda m: '=> %s {%s' % (_ARM_PLACEHOLDER, m.group(1)), src)


def arm_region_post(out):
    return out.replace('=> %s:' % _ARM_PLACEHOLDER, '=>:')


def _restore_leading_blank(s, out):
    """把**首行空行**补回来（`transform_text` 的行模型必然丢一条：首行的换行被读作
    「转到下一行」而不是「产出一个空行」）。⇒ 原文以 `\\n` 起头而产物不以 ⇒ 补一个。"""
    if s.startswith('\n') and not out.startswith('\n'):
        return '\n' + out
    return out


def _min_indent(s):
    best = None
    for ln in s.split('\n'):
        if not ln.strip():
            continue
        n = len(ln) - len(ln.lstrip(' \t'))
        best = n if best is None else min(best, n)
    return best or 0


def _reindent(text, prefix):
    if prefix == '':
        return text
    out = []
    for ln in text.split('\n'):
        out.append(prefix + ln if ln.strip() else ln)
    return '\n'.join(out)


# ── 单段改写 ──────────────────────────────────────────────────────────────────
def migrate_segment(s, label):
    """Core 段 `s` → v4。返回 `(new, rec)`；`new is None` ⇒ 未改写（`rec['skip']` 有理由）。"""
    rec = {'label': label, 'skip': None, 'changed': False}
    if already_v4(s):
        rec['skip'] = 'already-v4'
        return None, rec
    # 先做**与形状无关**的那一步（struct 字面量分隔符 `:` → `=`）；若这一步之后就已是
    # 合法 v4 ⇒ 本段只需该步（语料里大量「已迁移的 v4 + 遗留 `P{a: 1}`」正是此类）。
    try:
        s2, ncolon = struct_colon_to_eq(s)
    except Exception as e:
        rec['skip'] = 'colonfix-error: %s' % e
        return None, rec
    rec['colon_fixed'] = ncolon
    if ncolon:
        s3, nnone = none_rename(s2)
        rec['none_renamed'] = nnone
        if M.v4_parse_ok(s3)[0]:
            rec['changed'] = s3 != s
            rec['v4_parses'] = True
            return s3, rec
    # 警告：必须用 `table` 策略：`skip` 会**整段跳过 `pre_transform`**，而 T6a 在 `pre_transform`
    # 的 `_t6_extra_ops` 里实现的三件改写（E1 struct 字面量 `:`→`=` · E5 `None`→`none` ·
    # E6 `return match` 臂体块去内层 `return`）**都挂在那里**（实测教训：用 `skip` 跑出来的
    # 臂体是 `Pat =>: ` + region —— 两个前端**都不吃**，见 parser.cr `parse_match_expr`：
    # 臂体恒为 `parse_expr()`）。
    # 空 region：`EMPTY_ACTIONS` 的键是 `(文件路径, 行号)`，内嵌段的行号与宿主文件不同 ⇒
    # 永不命中表 ⇒ 一律进 `unresolved` ⇒ 本工具按「停下上报」处置（正是 T4 规则要的）。
    # 臂体块 ⇒ 文档形（`Pat =>:` + region）。先做，再进 `transform_text`：
    # 否则 `v4_migrate.classify` 把它当 `arm` ⇒ 单行 `=> return E`（非文档形）。
    arm_in = arm_block_to_region_src(s2)
    arm_hit = arm_in != s2
    filled = None
    try:
        out, rep = M.transform_text(arm_in if arm_hit else s2, label, 'table')
    except Exception as e:
        rec['skip'] = 'transform-error: %s' % e
        return None, rec
    if out is None and 'empty region' in str(rep.get('aborted', '')):
        # 空 region ⇒ 走**目标形**路径（`:` 后不跟 items；维护者 2026-10-11 规格化裁定）
        filled, nspots = _fill_empty_regions(s2)
        if not nspots:
            rec['skip'] = 'empty-region: %s' % rep.get('aborted', '')
            return None, rec
        try:
            out, rep = M.transform_text(filled, label, 'skip')
        except Exception as e:
            rec['skip'] = 'empty-region+transform-error: %s' % e
            return None, rec
        if out is None:
            rec['skip'] = 'empty-region: %s' % rep.get('aborted', '')
            return None, rec
        out = _strip_sentinels(out)
        rec['empty_regions_kept'] = nspots
    elif out is None:
        rec['skip'] = 'empty-region: %s' % rep.get('aborted', '')
        return None, rec
    if arm_hit:
        out = arm_region_post(out)
    prefix = ' ' * _min_indent(s2)
    out = _reindent(out, prefix)
    out = _restore_leading_blank(s2, out)
    # 机械轨：V2 + V4a + V4b
    try:
        diffs = v2_check(s2, out)
    except Exception as e:
        rec['skip'] = 'v2-error: %s' % e
        return None, rec
    if diffs:
        rec['skip'] = 'V2DIFF(%d)' % len(diffs)
        rec['v2diffs'] = diffs
        return None, rec
    ob, nb = M.comment_counts(s2), M.comment_counts(out)
    if nb['comment_lines'] + nb['block_comments'] < ob['comment_lines'] + ob['block_comments']:
        rec['skip'] = 'V4a-drop'
        return None, rec
    if M.file_metrics(out)['blank_lines'] < M.file_metrics(s2)['blank_lines']:
        rec['skip'] = 'V4b-drop'
        return None, rec
    rec['changed'] = out != s
    rec['v4_parses'] = M.v4_parse_ok(out)[0]
    rec['v3_parsed'] = M.v4_parse_ok(s)[0]
    return out, rec


# ── `.py` 宿主 ────────────────────────────────────────────────────────────────
def _offsets(src):
    lines = src.splitlines(keepends=True)
    starts = []
    p = 0
    for l in lines:
        starts.append(p)
        p += len(l)
    starts.append(p)

    def off(lineno, col):
        return starts[lineno - 1] + col
    return off


_LIT_RE = re.compile(r'^(?P<pre>[A-Za-z]*)'
                     r'(?P<q>"""|\'\'\'|"|\')')


def py_segments(path):
    """列出 `.py` 里**判定为 Core** 的字符串字面量：`(offset_start, offset_end, content, label)`。"""
    src = open(path, encoding='utf-8').read()
    off = _offsets(src)
    tree = ast.parse(src)
    # **文档字符串不是 Core 源**（哪怕它引用了 `fn f(...)` 形态）——整棵文档串节点排除。
    docstrings = set()
    for n in ast.walk(tree):
        if isinstance(n, (ast.Module, ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            if n.body and isinstance(n.body[0], ast.Expr) \
                    and isinstance(n.body[0].value, ast.Constant) \
                    and isinstance(n.body[0].value.value, str):
                docstrings.add(id(n.body[0].value))
    out = []
    for n in ast.walk(tree):
        if not (isinstance(n, ast.Constant) and isinstance(n.value, str)):
            continue
        if id(n) in docstrings:
            continue
        if not is_core(n.value):
            continue
        a, b = off(n.lineno, n.col_offset), off(n.end_lineno, n.end_col_offset)
        raw = src[a:b]
        m = _LIT_RE.match(raw)
        if not m:
            out.append((a, b, n.value, 'line %d' % n.lineno, '', '', 'unsupported'))
            continue
        q = m.group('q')
        inner = raw[len(m.group('pre')) + len(q):-len(q)]
        style = 'esc' if inner != n.value else 'plain'
        out.append((a, b, n.value, 'line %d' % n.lineno, m.group('pre'), q, style))
    return out


def migrate_py(path, apply=False):
    src = open(path, encoding='utf-8').read()
    segs = py_segments(path)
    edits = []
    recs = []
    for a, b, content, label, pre, q, style in segs:
        if style == 'unsupported':
            recs.append({'label': label, 'skip': 'unparsed-literal-form'})
            continue
        new, rec = migrate_segment(content, label)
        recs.append(rec)
        if new is None or not rec['changed']:
            continue
        # 单引号形（`"…"` / `'…'`）**必须保持单行** ⇒ 产物里的真换行要编成 `\n`。
        # 三引号形只有当原文本身用了转义时才重编（否则逐字保留，避免无谓 diff）。
        if style == 'plain' and len(q) == 3:
            body = new
        else:
            body = _encode_literal(new, q)
        edits.append((a, b, pre + q + body + q))
    if apply and edits:
        for a, b, rep in sorted(edits, key=lambda e: -e[0]):
            src = src[:a] + rep + src[b:]
        open(path, 'w', encoding='utf-8').write(src)
    return recs, len(edits)


# ── `.md` 宿主 ────────────────────────────────────────────────────────────────
_FENCE_RE = re.compile(r'^(?P<ind>[ \t]*)(?P<f>```+|~~~+)(?P<info>[^\n]*)$')


def md_segments(path):
    """列出 `.md` 里**判定为 Core** 的围栏块：`(start, end, content, label)`。

    `start/end` = 块体在文件里的**字符偏移**（不含围栏行本身）。
    """
    text = open(path, encoding='utf-8').read()
    lines = text.split('\n')
    starts, pos = [], 0
    for l in lines:
        starts.append(pos)
        pos += len(l) + 1
    segs = []
    i = 0
    while i < len(lines):
        m = _FENCE_RE.match(lines[i])
        if not m:
            i += 1
            continue
        fence = m.group('f')
        info = m.group('info').strip()
        j = i + 1
        while j < len(lines):
            m2 = _FENCE_RE.match(lines[j])
            if m2 and m2.group('f')[0] == fence[0] and len(m2.group('f')) >= len(fence) \
                    and m2.group('info').strip() == '':
                break
            j += 1
        body_start = starts[i] + len(lines[i]) + 1 if i + 1 < len(lines) else len(text)
        body_end = starts[j] if j < len(lines) else len(text)
        content = text[body_start:body_end]
        label = 'lines %d-%d (info=%r)' % (i + 2, j, info)
        # `core` 标记者恒收；**无标记**的围栏仅当块体带 Core 声明形（`fn`/`struct`/…）
        # 且确有 v3 记号（`is_core` 已含此闸）时收——否则散文块会被误判。
        if (info.startswith('core') or (not info and CORE_DECL_RE.search(content))) \
                and is_core(content):
            segs.append((body_start, body_end, content, label))
        i = j + 1
    return segs


def _iter_string_spans(path):
    """`(start, end, value, kind)`：文件里**全部**字符串常量与 f-string 字面块的源跨度。"""
    src = open(path, encoding='utf-8').read()
    off = _offsets(src)
    tree = ast.parse(src)
    out = []
    for n in ast.walk(tree):
        if isinstance(n, ast.JoinedStr):
            for v in n.values:
                if isinstance(v, ast.Constant) and isinstance(v.value, str):
                    out.append((off(v.lineno, v.col_offset),
                                off(v.end_lineno, v.end_col_offset), v.value, 'fstr'))
        elif isinstance(n, ast.Constant) and isinstance(n.value, str):
            out.append((off(n.lineno, n.col_offset),
                        off(n.end_lineno, n.end_col_offset), n.value, 'str'))
    return src, out


def none_rename_py(path, apply=False):
    """把**所有 Core 形字符串**里的 `None` 改成 `none`（v4 关键字拼写）。

    单独成一步的理由：`is_core` 要求 v3 的两个记号（`{` / `;`）之一，而**已是 v4 形**的
    片段（`fn g() -> int?:` + `return None`）一个都没有 ⇒ 那些片段会漏过主流程的 E5。
    """
    src, spans = _iter_string_spans(path)
    edits = []
    for a, b, v, kind in spans:
        if 'None' not in v:
            continue
        if not (CORE_DECL_RE.search(v) or is_core(v)):
            continue
        if v.lstrip().startswith('#'):
            continue
        raw = src[a:b]
        # 只动**字面量体**：跳过前缀与引号
        m = _LIT_RE.match(raw) if kind == 'str' else None
        if m:
            head = len(m.group('pre')) + len(m.group('q'))
            body = raw[head:-len(m.group('q'))]
        else:
            body = raw
        new_body = re.sub(r'\bNone\b', 'none', body)
        if new_body == body:
            continue
        edits.append((a, b, raw.replace(body, new_body, 1)))
    if apply and edits:
        for a, b, rep in sorted(edits, key=lambda e: -e[0]):
            src = src[:a] + rep + src[b:]
        open(path, 'w', encoding='utf-8').write(src)
    return len(edits)


def cr_segments(path):
    """列出 `.cr` 里**判定为 Core** 的字符串字面量：`(start, end, value, label, line)`。

    宿主是 Core 源（不是 Python）⇒ 用 vendored v3 扫描器切 `STRING_LIT`。
    **额外闸**（吸取实测假阳）：正文形态的字面量必须含换行或行尾 `;` ——
    否则形如 `'{' is only valid as a struct literal delimiter …'` 的诊断文案会被
    `\\bstruct\\s+\\w`（"struct literal"）误抓。
    """
    src = open(path, encoding='utf-8').read()
    toks = [t for t in M.V3.Lexer(src, path).tokenize()]
    out = []
    for t in toks:
        if t.type.name != 'STRING_LIT':
            continue
        v = t.lexeme
        if '\n' not in v and not v.rstrip().endswith(';'):
            continue
        if not is_core(v):
            continue
        out.append((t.start, t.end, v, 'line %d' % t.line, t.line))
    return src, out


def migrate_cr(path, apply=False):
    src, segs = cr_segments(path)
    edits, recs = [], []
    for a, b, content, label, _ln in segs:
        if already_v4(content):
            recs.append({'label': label, 'skip': 'already-v4'})
            continue
        new, rec = migrate_segment(content, label)
        recs.append(rec)
        if new is None or not rec['changed']:
            continue
        raw = src[a:b]
        q = raw[0] if raw[:1] in ('"', "'") else '"'
        edits.append((a, b, q + _encode_literal(new, q * 1) + q))
    if apply and edits:
        for a, b, rep in sorted(edits, key=lambda e: -e[0]):
            src = src[:a] + rep + src[b:]
        open(path, 'w', encoding='utf-8').write(src)
    return recs, len(edits)


def migrate_md(path, apply=False):
    text = open(path, encoding='utf-8').read()
    segs = md_segments(path)
    edits, recs = [], []
    for a, b, content, label in segs:
        new, rec = migrate_segment(content, label)
        recs.append(rec)
        if new is None or not rec['changed']:
            continue
        edits.append((a, b, new))
    if apply and edits:
        for a, b, rep in sorted(edits, key=lambda e: -e[0]):
            text = text[:a] + rep + text[b:]
        open(path, 'w', encoding='utf-8').write(text)
    return recs, len(edits)


# ── CLI ───────────────────────────────────────────────────────────────────────
def do_file(path, apply):
    if path.endswith('.py'):
        return migrate_py(path, apply)
    if path.endswith('.md'):
        return migrate_md(path, apply)
    if path.endswith('.cr'):
        return migrate_cr(path, apply)
    raise SystemExit('unsupported host: %s' % path)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest='cmd', required=True)
    r = sub.add_parser('report')
    r.add_argument('files', nargs='+')
    a = sub.add_parser('apply')
    a.add_argument('files', nargs='+')
    n = sub.add_parser('none-rename')
    n.add_argument('files', nargs='+')
    args = ap.parse_args()
    if args.cmd == 'none-rename':
        tot = 0
        for p in args.files:
            k = none_rename_py(p, apply=True)
            if k:
                print('%-60s None->none = %d' % (p, k))
            tot += k
        print('TOTAL None->none: %d (in %d files)' % (tot, len(args.files)))
        return 0
    apply = args.cmd == 'apply'
    nch = nskip = 0
    for p in args.files:
        recs, n = do_file(p, apply)
        nch += n
        print('=== %s' % p)
        for rec in recs:
            if rec.get('skip'):
                nskip += 1
                print('   [skip] %-28s %s' % (rec['label'], rec['skip']))
            else:
                print('   [%s] %-28s v4parse=%s wasv4parse=%s' %
                      ('EDIT' if rec['changed'] else 'same', rec['label'],
                       rec.get('v4_parses'), rec.get('v3_parsed')))
        print('   -> %d segment(s) %s' % (n, 'rewritten' if apply else 'rewritable'))
    print('TOTAL: %d rewritten, %d skipped' % (nch, nskip))
    return 0


if __name__ == '__main__':
    sys.exit(main())
