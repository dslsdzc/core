#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""doc_protected_surface.py —— 文档编辑的「非散文面」判据（零构建，纯 stdlib）。

用途：审/改 .md 的散文表达时，钉死不许变的那一面。

抽取的类别（每类一项 = 多重集里的一个条目）：
  FENCE_OPEN      ``` / ~~~ 围栏开标记，含围栏语言标记
  FENCE_CLOSE     围栏闭标记（每档必须成对，奇数 ⇒ fail-closed）
  FENCE_LINE      围栏内的每一行（逐字符）
  INLINE          行内代码（反引号内；只取围栏外的行）
  NUM             数字字面量（全档扫描，含词内数字如 v8 / TI_DYN=7）
  ANCHOR          file:line 形锚
  TODOID          #YYYY-MM-DD-N
  URL             http(s):// 链接
  LINKTARGET      markdown 链接目标 ](...)（技能「链接目标」保护面）
  TROW            表格行（逐字符；只取围栏外的行）
  MARKER          记录标记行（含「原文保留」或「加注」）

判据：改前 / 改后两份多重集逐项相同 ⇒ PASS，否则 RED。

fail-closed：
  - 源头读不到（jj 失败 / 文件不存在 / 目录里一个 .md 都没有）⇒ 立刻 FAIL，不退化成空集
  - 抽取条目数 < 非空转下限 ⇒ 判「抽空」FAIL（不是 PASS）
  - 某档围栏不成对 ⇒ FAIL
  这三条是为了不重演「空语料 0==0 PASS」。

目录参数会被展开成该目录下全部 *.md（按路径排序）逐个抽取。不倚赖
`jj file show <dir>` 的拼接形态——那会把整批并成**一个**伪档，每档下限随之失效
（2026-09-24 实测：`docs/developer/` 目录形 =「2253 items, 1 files」）。

用法：
  doc_protected_surface.py extract --rev <REV> --out M.txt <PATH>...
  doc_protected_surface.py extract --worktree --out M.txt <PATH>...
  doc_protected_surface.py compare --floor N --per-file-floor M A.txt B.txt

下限**必填**（`--floor` / `--per-file-floor`，无默认值）：
  下限是**被审语料**的性质，不是工具的性质。任何写死在文件里的默认数，换一批语料
  就静默偏了——要么正控自己判红（2026-09-24 实测：默认 3200 > 本批 2253），要么
  低到放行抽空。故一律由调用方当场给数，让口径落在命令行上。

  数法（本仓现行）：
    1. 先对**冻结基线**修订跑一次 extract，读 manifest 头部：
         # items: <总数>          # per-file <路径> <档内条目数>
    2. --floor          = 总数 × 0.9 向下取整
       --per-file-floor = **最小**档内条目数 × 0.9 向下取整
    3. 两个数连同命令一起写进批次报告；换语料（增/删档）必须重测重给。
"""

import argparse
import os
import re
import subprocess
import sys
from collections import Counter

# ---------------------------------------------------------------- 非空转下限
# 下限一律由调用方给出（--floor / --per-file-floor 必填，见模块 docstring 的「数法」）。
# 这里**不设默认值**：写死的默认数换一批语料就静默偏掉（偏高 ⇒ 正控自己判红；
# 偏低 ⇒ 放行抽空），两种都不能接受。

FENCE_RE = re.compile(r'^ {0,3}(`{3,}|~{3,})(.*)$')
NUM_RE = re.compile(r'\d+(?:\.\d+)?')
ANCHOR_RE = re.compile(r'[A-Za-z0-9_./\-]*[A-Za-z0-9_\-]\.[A-Za-z][A-Za-z0-9_]*:\d+(?:[-–]\d+)?')
TODOID_RE = re.compile(r'#\d{4}-\d{2}-\d{2}-\d+')
URL_RE = re.compile(r'https?://[^\s)\]>」）、，。；]+')
LINKTARGET_RE = re.compile(r'\]\(([^)\n]+)\)')
INLINE_RE = re.compile(r'(`+)(.+?)\1')
MARKER_RE = re.compile(r'原文保留|加注')


class ExtractError(Exception):
    pass


def read_file(path, rev):
    """读一份档。rev 非 None 时走 jj（判据真源 = 修订，不是手边检出）。"""
    if rev is None:
        try:
            with open(path, 'r', encoding='utf-8') as fh:
                return fh.read()
        except OSError as exc:
            raise ExtractError('读不到工作副本 %s: %s' % (path, exc))
    proc = subprocess.run(
        ['jj', 'file', 'show', '-r', rev, path],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if proc.returncode != 0:
        raise ExtractError('jj file show -r %s %s 失败 (rc=%d): %s'
                           % (rev, path, proc.returncode,
                              proc.stderr.decode('utf-8', 'replace').strip()))
    return proc.stdout.decode('utf-8')


def extract(text, path):
    """返回 [(cat, file, value), ...]。"""
    items = []
    lines = text.replace('\r\n', '\n').replace('\r', '\n').split('\n')

    def add(cat, value):
        items.append((cat, path, value))

    # ---- 数字字面量：全档扫描（含围栏内、词内），是最强的一层网
    for m in NUM_RE.finditer(text):
        add('NUM', m.group(0))

    # ---- 逐行扫描
    fence_marker = None      # 当前围栏的字符（``` 或 ~~~）
    fence_lang = None
    fence_open_count = 0
    in_fence = False
    for line in lines:
        fm = FENCE_RE.match(line)
        if fm:
            marker, rest = fm.group(1), fm.group(2).strip()
            if not in_fence:
                in_fence = True
                fence_marker = marker[0] * 3
                fence_lang = rest
                fence_open_count += 1
                add('FENCE_OPEN', rest)
                continue
            # 闭围栏：同种字符且 rest 为空或只有语言标记
            if marker[0] == fence_marker[0] and rest == '':
                in_fence = False
                fence_marker = None
                fence_lang = None
                add('FENCE_CLOSE', '')
                continue
            # 围栏内的 ``` 行（比如嵌套示例）按内容行处理
        if in_fence:
            add('FENCE_LINE', line)
            continue
        # ---- 围栏外
        for m in INLINE_RE.finditer(line):
            add('INLINE', m.group(2))
        if line.lstrip().startswith('|'):
            add('TROW', line.rstrip())
        if MARKER_RE.search(line):
            add('MARKER', line.rstrip())
    if in_fence:
        raise ExtractError('%s: 围栏未闭合（开了 %d 个）' % (path, fence_open_count))

    # ---- 锚 / TODO id / URL / 链接目标：全档扫描（跨行也安全）
    for m in ANCHOR_RE.finditer(text):
        add('ANCHOR', m.group(0))
    for m in TODOID_RE.finditer(text):
        add('TODOID', m.group(0))
    for m in URL_RE.finditer(text):
        add('URL', m.group(0))
    for m in LINKTARGET_RE.finditer(text):
        add('LINKTARGET', m.group(1))
    return items


def render(items, source_note):
    out = ['# doc_protected_surface manifest v1',
           '# source: %s' % source_note,
           '# items: %d' % len(items)]
    per_file = Counter(f for _, f, _ in items)
    for f in sorted(per_file):
        out.append('# per-file %s %d' % (f, per_file[f]))
    out.append('# categories: ' + ' '.join(
        '%s=%d' % (c, n) for c, n in sorted(Counter(c for c, _, _ in items).items())))
    body = sorted('%s\t%s\t%s' % t for t in items)
    return '\n'.join(out + body) + '\n'


def expand_paths(paths):
    """目录展开成其下全部 *.md（按路径排序）。不展开 ⇒ 每档下限会静默失效。"""
    out = []
    for path in paths:
        if os.path.isdir(path):
            found = []
            for root, dirs, files in os.walk(path):
                dirs.sort()
                for name in sorted(files):
                    if name.endswith('.md'):
                        found.append(os.path.join(root, name))
            if not found:
                raise ExtractError('目录 %s 下没有任何 .md（抽空，fail-closed）' % path)
            out.extend(sorted(found))
        else:
            out.append(path)
    return out


def cmd_extract(args):
    if args.rev is None and not args.worktree:
        raise ExtractError('必须给 --rev <REV> 或 --worktree（不猜源）')
    rev = None if args.worktree else args.rev
    items = []
    for path in expand_paths(args.paths):
        items.extend(extract(read_file(path, rev), path))
    note = 'worktree' if rev is None else 'jj rev %s' % rev
    text = render(items, note)
    if args.out:
        with open(args.out, 'w', encoding='utf-8') as fh:
            fh.write(text)
        print('%s: %d items, %d files'
              % (args.out, len(items), len(set(f for _, f, _ in items))))
    else:
        sys.stdout.write(text)
    return 0


def load_manifest(path):
    try:
        with open(path, 'r', encoding='utf-8') as fh:
            raw = fh.read()
    except OSError as exc:
        raise ExtractError('读不到 manifest %s: %s' % (path, exc))
    lines = [l for l in raw.split('\n') if l and not l.startswith('#')]
    per_file = Counter()
    for l in lines:
        parts = l.split('\t', 2)
        if len(parts) != 3:
            raise ExtractError('manifest %s 条目格式错: %r' % (path, l))
        per_file[parts[1]] += 1
    return lines, per_file


def cmd_compare(args):
    a, a_per = load_manifest(args.a)
    b, b_per = load_manifest(args.b)
    floor = args.floor
    pff = args.per_file_floor

    # ---- 非空转闸（先于相等判定：抽空不叫 PASS）
    problems = []
    if len(a) < floor:
        problems.append('A 抽取条目 %d < 下限 %d（抽空）' % (len(a), floor))
    if len(b) < floor:
        problems.append('B 抽取条目 %d < 下限 %d（抽空）' % (len(b), floor))
    for name, per in (('A', a_per), ('B', b_per)):
        for f, n in sorted(per.items()):
            if n < pff:
                problems.append('%s 档 %s 条目 %d < 每档下限 %d（抽空）'
                                % (name, f, n, pff))
    if set(a_per) != set(b_per):
        problems.append('两侧档清单不同: A 少 %s / B 少 %s'
                        % (sorted(set(b_per) - set(a_per)),
                           sorted(set(a_per) - set(b_per))))
    if problems:
        print('FAIL（非空转闸；floor=%d per-file-floor=%d）' % (floor, pff))
        for p in problems:
            print('  - ' + p)
        return 1

    ca, cb = Counter(a), Counter(b)
    removed = sorted((ca - cb).elements())
    added = sorted((cb - ca).elements())
    if not removed and not added:
        print('PASS  两侧多重集逐项相同（%d 项，%d 档；floor=%d per-file-floor=%d）'
              % (len(a), len(a_per), floor, pff))
        return 0
    print('FAIL  受保护面有差异：- %d 项 / + %d 项' % (len(removed), len(added)))
    for prefix, items in (('-', removed), ('+', added)):
        for it in items[:args.max_show]:
            cat, f, v = it.split('\t', 2)
            print('  %s %-12s %s | %s' % (prefix, cat, f, v[:160]))
        if len(items) > args.max_show:
            print('  %s ...（另有 %d 项，--max-show 调大）'
                  % (prefix, len(items) - args.max_show))
    return 1


def main(argv):
    ap = argparse.ArgumentParser(
        description='文档非散文面抽取 / 对拍判据（fail-closed）')
    sub = ap.add_subparsers(dest='cmd', required=True)

    e = sub.add_parser('extract', help='抽一份或多份 .md 的非散文面')
    e.add_argument('paths', nargs='+')
    e.add_argument('--rev', help='jj 修订（判据真源）；不给则必须给 --worktree')
    e.add_argument('--worktree', action='store_true', help='读工作副本')
    e.add_argument('--out', help='写 manifest 到这个文件')
    e.set_defaults(func=cmd_extract)

    c = sub.add_parser('compare', help='对拍两份 manifest')
    c.add_argument('a')
    c.add_argument('b')
    c.add_argument('--floor', type=int, required=True,
                   help='总条目非空转下限（必填；数法见模块 docstring）')
    c.add_argument('--per-file-floor', type=int, required=True,
                   help='每档条目非空转下限（必填；取最小档内条目数 × 0.9）')
    c.add_argument('--max-show', type=int, default=40)
    c.set_defaults(func=cmd_compare)

    args = ap.parse_args(argv)
    try:
        return args.func(args)
    except ExtractError as exc:
        print('FAIL（读源失败，fail-closed）: %s' % exc, file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
