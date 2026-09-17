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
  J3 **映射完备**：`TODO.md` 迁移对照表覆盖 `#1..#101` 每个号（`#66` 为空号须显式注记），
     表行数 == 新 id 数 == 标题数（**自洽计数，不写死绝对值**——条目会持续新增，
    写死必然过期：2026-09-17 第 4 批新增三条即触发过一次），且新 id 全局唯一。
     **口径换代（2026-09-17 维护者跨批裁定）**：旧号列允许 `—`（= 迁移后新增、**无旧号**）；
     数字列仍受 `#1..#101` 封存上界约束（禁造历史不存在的号）。**行式放松的保护由
     `check_j3_mutations` 三条突变自证钉住**（M-a/M-b/M-c 缺一不可）；旧口径原文与
     「为何放松」留痕于 `j3_problems` 头注。
  J4 **突变自证**：内存内把一处新 id 引用**还原成旧号** ⇒ J1 的判定函数必须转红；
     还原前（真实现状）⇒ 绿。证明 J1 有牙（不是恒绿的空判据）。
  J6 **同日段内 id 唯一**：`### YYYY-MM-DD-N.` 标题中同一 id 不得出现两次
     （2026-09-18 补：两个 PR 各写一个 `2026-09-18-3` 而 J1–J5 全绿 ⇒ 该缺口由本判据机械拦）；
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
EX_DIRS = {".git", ".jj", "build", ".superpowers", "__pycache__", "node_modules",
           # 2026-09-17 批 5 实测补入：`.core/` = 编译器**增量缓存**（`.core/cache/cir/*.cir`
           # 二进制快照；构建后在仓根生成）。原集合漏了它 ⇒ 本判据的 J1/J2 全仓扫描会**逐个读**
           # 这些快照——实测（本工作区 1.4GB / 1657 条）令本判据**卡死 14+ 分钟**（判据进程
           # `rchar` 2.4GB+、CPU 0.7%，`/proc/<pid>/fd` 显示打开 `…/cache/cir/src_compiler_main.cr::dirname.cir`）。
           # **排除是判定中立的**：快照 = 编译产物（二进制），非仓库文本内容；与已排除的 `build/`
           # 同类。**两态对照证据**：排除前后本判据 J1=0 残留 / J2=0 悬空 / 标题 103 / J3 PASS 逐项相同
           # （见 `docs/superpowers/specs/2026-09-17-opt-dex-batch-report.md` §9）。
           ".core"}

OLD_FORM = re.compile(r"TODO\s*#(\d+)(?![\d-])")          # 旧形态：数字后不接 `-MM-DD-`
NEW_FORM = re.compile(r"#(\d{4}-\d{2}-\d{2}-\d+)")
TABLE_ROW = re.compile(r"^\|\s*#(\d+)\s*\|\s*`#(\d{4}-\d{2}-\d{2}-\d+)`")
# 迁移后**新增**条目行（从未有过旧号）：旧号列一律写 `—`（维护者 2026-09-17 跨批裁定；禁止塞数字
# ——那会凭空造出历史不存在的旧号）。行式独立于 TABLE_ROW（后者只认数字列）。
TABLE_ROW_NEW = re.compile(r"^\|\s*—\s*\|\s*`#(\d{4}-\d{2}-\d{2}-\d+)`")
TABLE_HEAD = "## 编号迁移对照表"
SEALED_MAX = 101    # 旧号封存上界（#1..#101 永久封存、不复用；见 TODO.md 头部编号约定）
HEADING = re.compile(r"^### (\d{4}-\d{2}-\d{2}-\d+)\.")


def table_lines(todo_text):
    """对照表区内的数据行（`|` 起始；表 = `## 编号迁移对照表` 到下一个 `## ` 标题之间）。"""
    out, inside = [], False
    for line in todo_text.splitlines():
        if line.startswith("## "):
            inside = line.startswith(TABLE_HEAD)
            continue
        if inside and line.startswith("|"):
            out.append(line)
    return out


def table_rows(todo_text):
    """→ (num_map: {旧号 → [新 id,…]}, new_only: [新 id,…], malformed: [行,…])。
    malformed = 含反引号新 id 却既不匹配数字行式也不匹配 `—` 行式的行（防「行式悄悄失效」）。"""
    num, new_only, malformed = {}, [], []
    for line in table_lines(todo_text):
        m = TABLE_ROW.match(line)
        if m:
            num.setdefault(int(m.group(1)), []).append(m.group(2))
            continue
        m2 = TABLE_ROW_NEW.match(line)
        if m2:
            new_only.append(m2.group(1))
            continue
        if re.search(r"`#\d{4}-\d{2}-\d{2}-\d+`", line):
            malformed.append(line.strip()[:120])
    return num, new_only, malformed


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


def j3_problems(todo_text):
    """J3 判定函数（**纯函数**——真实现状与三条突变共用同一实现，防两处漂移）。

    口径（**2026-09-17 维护者跨批裁定**）：
      ① **总体性不放松**：表的新 id 集合（含 `—` 行）== 标题集合；
      ② 旧号列 ∈ {数字, `—`}；数字部分仍须 **1..SEALED_MAX 全覆盖**（`#66` 空号例外）；
      ③ 越过 `SEALED_MAX` 的数字 ⇒ 红（迁移后新增条目一律写 `—`，**禁造历史不存在的旧号**）；
      ④ 行数自洽 + 新 id 唯一 + 行式可解析（`malformed` 捕获「行式悄悄失效」）。

    **旧口径原文（留痕，不静默改）**：
      `max_old = max(table)`；`missing = 1..max_old` 缺号；`n_rows == 新 id 数`（n_rows 只数
      `TABLE_ROW` 数字行式）；`set(news) == set(heads)`。
    **为何放松**：其 `n_rows`/`max_old` 两项编码了一个**从未成立的假设**——*每条新 id 都有旧号*。
    迁移后新增条目（如 `#2026-09-17-4`）**从来没有旧号** ⇒ 原式必红，且**无法用合法数据修**
    （往旧号列塞数字 = 凭空造历史不存在的号 = 新的假引用类，被维护者明确否决）。
    ⇒ 放松的**只是行式**（允许 `—`）；**保护未丢**，由 `check_j3_mutations` 的三条突变自证钉住。
    """
    num, new_only, malformed = table_rows(todo_text)
    heads = headings_from_todo(todo_text)
    probs = []
    missing = [n for n in range(1, SEALED_MAX + 1) if n not in num and n != 66]
    if missing:
        probs.append(f"映射缺号（1..{SEALED_MAX}）: {missing[:8]}")
    over = sorted(n for n in num if n > SEALED_MAX)
    if over:
        probs.append(f"旧号列出现越过封存上界 #{SEALED_MAX} 的号 {over}——"
                     f"迁移后新增条目一律写 `—`（禁止造历史不存在的旧号）")
    if 66 in num:
        probs.append("#66 是空号（预留未用），不应出现在映射表")
    elif not re.search(r"#66.*空号|空号.*#66", todo_text):
        probs.append("#66 空号缺显式注记")
    ids = [v for vs in num.values() for v in vs] + new_only
    n_data = len(table_lines(todo_text)) - 2      # 表头行 + 分隔行
    if n_data != len(ids):
        probs.append(f"映射表数据行数 {n_data} != 新 id 数 {len(ids)}（自洽计数）")
    if malformed:
        probs.append(f"不可解析的表行（行式漂移）: {malformed[:2]}")
    dup = [v for v in set(ids) if ids.count(v) > 1]
    if dup:
        probs.append(f"新 id 重复: {dup}")
    if set(ids) != set(heads):
        probs.append(f"映射表新 id 集合 != 标题集合（差 {sorted(set(ids) ^ set(heads))[:5]}）")
    return probs, num, ids, heads


def check_j3(verbose=True):
    """映射完备（口径与留痕见 `j3_problems` 头注）。"""
    probs, num, ids, heads = j3_problems(read(TODO))
    if verbose:
        for p in probs:
            print("  问题:", p)
    n_new_only = len(ids) - len([v for vs in num.values() for v in vs])
    print(f"[{'PASS' if not probs else 'FAIL'}] J3 映射完备：旧号 {len(num)} 个 / 无旧号（`—`）"
          f"{n_new_only} 个 / 新 id {len(ids)} / 标题 {len(heads)}")
    return not probs


def check_j3_mutations():
    """**三条突变自证**（维护者 2026-09-17 裁定：放松行式后必须证明「旧的保护没丢」；
    三条**缺一不可**——任一条不红 ⇒ 停、上报）：
      M-a 删掉一行**已迁移**条目（有旧号）        ⇒ 必红（总体性 + 覆盖）
      M-b 把一个已迁移条目的旧号列改成 `—`        ⇒ 必红（1..SEALED_MAX 覆盖不完备）
      M-c 给 `—` 行塞一个封存上界外的旧号        ⇒ 必红（数字列受 `SEALED_MAX` 约束）
    正控 = 真实现状（由 `check_j3` 用**同一实现**跑，零问题）。"""
    lines = read(TODO).splitlines()
    ia = next(i for i, l in enumerate(lines) if TABLE_ROW.match(l))
    lns_b = list(lines)
    lns_b[ia] = re.sub(r"^\|\s*#\d+\s*\|", "| — |", lns_b[ia], count=1)
    ic = next(i for i, l in enumerate(lines) if TABLE_ROW_NEW.match(l))
    lns_c = list(lines)
    lns_c[ic] = re.sub(r"^\|\s*—\s*\|", f"| #{SEALED_MAX + 1} |", lns_c[ic], count=1)
    muts = [
        ("M-a 删已迁移条目行", "\n".join(lines[:ia] + lines[ia + 1:])),
        ("M-b 已迁移行旧号改 `—`", "\n".join(lns_b)),
        (f"M-c 造封存上界外的旧号 #{SEALED_MAX + 1}", "\n".join(lns_c)),
    ]
    bad = 0
    for name, txt in muts:
        probs, _n, _i, _h = j3_problems(txt)
        if probs:
            print(f"[PASS] {name} ⇒ J3 红（{probs[0][:64]}…）")
        else:
            print(f"[FAIL] {name} ⇒ J3 未红（口径放松后保护丢失）")
            bad += 1
    return bad == 0


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


def j6_duplicates(todo_text):
    """同日段内重复标题 id（`### YYYY-MM-DD-N.`）：返回 {id: 次数>1}。"""
    counts = {}
    for m in re.finditer(r"(?m)^### (\d{4}-\d{2}-\d{2}-\d+)\.", todo_text):
        counts[m.group(1)] = counts.get(m.group(1), 0) + 1
    return {k: v for k, v in counts.items() if v > 1}


def check_j6(verbose=True):
    """J6 同日段内 id 唯一（2026-09-18 补：本条缺口由两个 PR 各写一个 `2026-09-18-3` 而 J1–J5 全绿暴露）。

    为何需要：同一 id 出现两次 ⇒ J2 的「引用 ↔ 标题」双向匹配退化为多对一（引用指向哪一个不可判），
    且落地后必与《编号约定》「N 按标题行行号升序、当日最大 +1」冲突 ⇒ 属结构性可机械拦的一类。
    判据 = 标题集合内不得有重复；含**突变自证**（内存内复制一条标题 ⇒ 必红；真实现状 ⇒ 绿）。
    """
    txt = read(TODO)
    dup = j6_duplicates(txt)
    m = re.search(r"(?m)^### (\d{4}-\d{2}-\d{2}-\d+)\.", txt)
    nid = m.group(1) if m else "2026-01-01-1"
    mutated = txt + f"\n### {nid}. 突变体（内存内复制，不入盘）\n"
    red_mut = len(j6_duplicates(mutated)) > 0
    green_real = not dup
    ok = red_mut and green_real
    if verbose:
        print(f"  突变样本 = 复制 `### {nid}.` ⇒ 真实现状绿={green_real} · 突变后红={red_mut}")
    extra = f"（重复 = {sorted(dup)}）" if dup else ""
    print(f"[{'PASS' if not dup else 'FAIL'}] J6 同日段内 id 唯一：重复 {len(dup)} 个{extra}")
    return ok


def main():
    print("=== TODO 标识迁移判据（J1-J6）===")
    results = [check_j1(), check_j2(), check_j3(), check_j3_mutations(), check_j4(), check_j6()]
    print(f"{sum(results)}/{len(results)} 通过")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
