#!/usr/bin/env python3
"""TODO 标识迁移判据（2026-09-17 批；**机械、可复跑**——纯 python、无编译器依赖）。

背景：TODO 编号由「全局单调号 `#NN`」迁移为「日期 + 序号 `#YYYY-MM-DD-N`」
（缘起 = 2026-09-16 一天 5 次编号碰撞；计划与完整映射表见
`docs/superpowers/plans/2026-09-17-todo-id-migration.md`，映射表真源 = `TODO.md` 头部）。

判据（逐条 = 该批的验收条件）：
  J1 **无残留**：全仓不存在「旧形态」`TODO #<数字>`（数字后**不接** `-MM-DD-`）。
     排除面 = 映射表本身 + `（原 #NN）` 留痕注记 + 计划文档（其正文举例含旧号）。
  J2 **无悬空**：每处 `#YYYY-MM-DD-N` 引用都能在 `TODO.md` 找到对应标题（双向：标题集合
     ⊇ 被引集合）；另**报告**「零引用标题」清单（非失败——无人引用 ≠ 悬空）。
  J3 **映射完备**：`TODO.md` 迁移对照表覆盖 `#1..#98` 每个号（`#66` 为空号须显式注记），
     表行数 == 新 id 数 == 标题数（**自洽计数，不写死绝对值**——条目会持续新增，
    写死必然过期：2026-09-17 第 4 批新增三条即触发过一次），且新 id 全局唯一。
  J4 **突变自证**：内存内把一处新 id 引用**还原成旧号** ⇒ J1 的判定函数必须转红；
     还原前（真实现状）⇒ 绿。证明 J1 有牙（不是恒绿的空判据）。
  J5 **零源码语义改动**（静态面）：`.cr` 文件里不出现任何 `TODO #<旧号>` 形态（含于 J1），
     且本判据不依赖编译器 ⇒ 可在最便宜的 CI job 跑。

挂点状态：本文件由迁移批新增，**未挂 CI**（登记于 `tests/harness/ci_hook_allowlist.txt`
带理由）——挂点属 CI 配置变更，须由后续批裁量。
"""

import os
import re
import sys

BASE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TODO = os.path.join(BASE, "TODO.md")
PLAN = os.path.join(BASE, "docs", "superpowers", "plans", "2026-09-17-todo-id-migration.md")
EX_DIRS = {".git", ".jj", "build", ".superpowers", "__pycache__", "node_modules"}

OLD_FORM = re.compile(r"TODO\s*#(\d+)(?![\d-])")          # 旧形态：数字后不接 `-MM-DD-`
NEW_FORM = re.compile(r"#(\d{4}-\d{2}-\d{2}-\d+)")
TABLE_ROW = re.compile(r"^\|\s*#(\d+)\s*\|\s*`#(\d{4}-\d{2}-\d{2}-\d+)`")
HEADING = re.compile(r"^### (\d{4}-\d{2}-\d{2}-\d+)\.")


def repo_files():
    for root, dirs, files in os.walk(BASE):
        dirs[:] = [d for d in dirs if d not in EX_DIRS]
        for fn in files:
            yield os.path.join(root, fn)


def read(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except (OSError, UnicodeDecodeError):
        return ""


def old_form_hits(text, skip_notes=True):
    """旧形态 `TODO #N` 命中 → [(行号, 数字, 行文本)]；`（原 #N）` 留痕注记不算。"""
    out = []
    for i, line in enumerate(text.splitlines(), 1):
        for m in OLD_FORM.finditer(line):
            if skip_notes and line[max(0, m.start() - 3):m.start()] in ("（原 ", "（原"):
                continue
            out.append((i, int(m.group(1)), line.strip()[:100]))
    return out


def mapping_from_todo(todo_text):
    """TODO.md 头部对照表 → {旧号: 新 id}（同号 6/7 保留列表）。"""
    table = {}
    for line in todo_text.splitlines():
        m = TABLE_ROW.match(line)
        if m:
            table.setdefault(int(m.group(1)), []).append(m.group(2))
    return table


def headings_from_todo(todo_text):
    return [m.group(1) for m in (HEADING.match(l) for l in todo_text.splitlines()) if m]


def check_j1(verbose=True):
    """全仓旧形态残留（排除映射表行 / 留痕注记 / 计划文档）。"""
    hits = []
    for path in repo_files():
        rel = os.path.relpath(path, BASE)
        if rel == os.path.relpath(PLAN, BASE):
            continue
        txt = read(path)
        if not txt:
            continue
        for i, line in enumerate(txt.splitlines(), 1):
            if rel == "TODO.md" and line.startswith("|"):
                continue                      # 映射表行（旧号列）豁免
            for m in OLD_FORM.finditer(line):
                if line[max(0, m.start() - 3):m.start()] in ("（原 ", "（原"):
                    continue                  # 留痕注记
                hits.append(f"{rel}:{i}: {line.strip()[:90]}")
    if verbose:
        for h in hits[:20]:
            print("  残留:", h)
    print(f"[{'PASS' if not hits else 'FAIL'}] J1 无残留：旧形态 `TODO #N` = {len(hits)}")
    return not hits


def check_j2(verbose=True):
    """新格式引用 ↔ 标题（无悬空）+ 零引用标题报告。"""
    todo_text = read(TODO)
    heads = set(headings_from_todo(todo_text))
    dangling, cited = [], set()
    for path in repo_files():
        rel = os.path.relpath(path, BASE)
        txt = read(path)
        if not txt:
            continue
        in_table = False
        for i, line in enumerate(txt.splitlines(), 1):
            if rel == "TODO.md":
                if line.startswith("## 编号迁移对照表"):
                    in_table = True
                    continue
                if in_table:
                    if line.startswith("|"):
                        continue
                    in_table = False
            for m in NEW_FORM.finditer(line):
                nid = m.group(1)
                if nid not in heads:
                    dangling.append(f"{rel}:{i}: #{nid}")
                elif not (rel == "TODO.md" and line.startswith("### ")):
                    cited.add(nid)
    if verbose:
        for d in dangling[:20]:
            print("  悬空:", d)
    print(f"[{'PASS' if not dangling else 'FAIL'}] J2 无悬空：悬空引用 = {len(dangling)}"
          f"（标题 {len(heads)} 个 / 被引用 {len(cited)} 个）")
    uncited = sorted(heads - cited)
    if uncited and verbose:
        print(f"  [info] 零引用标题 {len(uncited)} 个（非失败；无人引用 ≠ 悬空）："
              f"{', '.join(uncited[:6])}{' …' if len(uncited) > 6 else ''}")
    return not dangling


def check_j3(verbose=True):
    """映射完备：覆盖 1..max（#66 空号注记，max 由表自派生）+ 行数自洽 + 新 id 唯一。"""
    todo_text = read(TODO)
    table = mapping_from_todo(todo_text)
    heads = headings_from_todo(todo_text)
    probs = []
    max_old = max(table) if table else 0
    missing = [n for n in range(1, max_old + 1) if n not in table and n != 66]
    if missing:
        probs.append(f"映射缺号: {missing}")
    if 66 in table:
        probs.append("#66 是空号（预留未用），不应出现在映射表")
    elif not re.search(r"#66.*空号|空号.*#66", todo_text):
        probs.append("#66 空号缺显式注记")
    n_rows = sum(1 for l in todo_text.splitlines() if TABLE_ROW.match(l))
    news_early = [v for vs in table.values() for v in vs]
    if n_rows != len(news_early):
        probs.append(f"映射表行数 {n_rows} != 新 id 数 {len(news_early)}（自洽计数）")
    news = [v for vs in table.values() for v in vs]
    dup = [v for v in set(news) if news.count(v) > 1]
    if dup:
        probs.append(f"新 id 重复: {dup}")
    if set(news) != set(heads):
        probs.append(f"映射表新 id 集合 != 标题集合（差 {sorted(set(news) ^ set(heads))[:5]}）")
    for p in probs:
        print("  问题:", p)
    print(f"[{'PASS' if not probs else 'FAIL'}] J3 映射完备：旧号 {len(table)} 个 / 新 id {len(news)}"
          f" / 标题 {len(heads)}")
    return not probs


def check_j4(verbose=True):
    """突变自证：新 id 引用还原为旧号 ⇒ J1 转红（J1 有牙）。"""
    table = mapping_from_todo(read(TODO))
    # 找一个含新 id 引用的源文件（排除计划文档与 TODO.md 的表格）
    victim = None
    for path in repo_files():
        rel = os.path.relpath(path, BASE)
        if rel.startswith("docs/superpowers/") or rel.endswith(".py"):
            continue
        txt = read(path)
        m = NEW_FORM.search(txt)
        if m and not rel.endswith("TODO.md"):
            victim = (rel, txt, m.group(0))
            break
    if not victim:
        print("[FAIL] J4 突变自证：找不到含新 id 引用的样本")
        return False
    rel, txt, nid = victim
    new_to_old = {v: k for k, vs in table.items() for v in vs}
    old = f"TODO #{new_to_old.get(nid.lstrip('#'))}"
    if old == "TODO #None":
        print(f"[FAIL] J4 突变自证：{nid} 反查不到旧号")
        return False
    mutated = txt.replace(nid, nid, 1).replace(f"TODO {nid}", old, 1) if f"TODO {nid}" in txt \
        else txt.replace(nid, old.split("#")[1], 1)
    red_mut = len(old_form_hits(mutated)) > 0
    green_real = len(old_form_hits(txt)) == 0
    ok = red_mut and green_real
    if verbose:
        print(f"  突变样本 = {rel}（{nid} → {old}）：真实现状绿={green_real} · 突变后红={red_mut}")
    print(f"[{'PASS' if ok else 'FAIL'}] J4 突变自证：还原一处引用 ⇒ J1 必红")
    return ok


def main():
    print("=== TODO 标识迁移判据（J1-J5）===")
    results = [check_j1(), check_j2(), check_j3(), check_j4()]
    print(f"{sum(results)}/{len(results)} 通过")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
