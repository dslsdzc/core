#!/usr/bin/env python3
"""受保护面判据的**牙**：证明 `tools/doc_protected_surface.py` 真的抓得住 9 类受保护面。

被验对象：`tools/doc_protected_surface.py`（文档编辑的「非散文面」抽取 + 多重集对拍判据）。
背景：该脚本自身「PASS」只说明两侧抽取相同——**不能说明它抓得住东西**。一条恒 PASS 的
空判据与一条真的判据在读数上一模一样（本仓已发生过「空壳绿」：析取断言里一腿恒假，
绿全来自另一腿，见 `test_region_check_pointer_escape` 实例）。本档给那条判据装上可复现的牙。

零 jj / 零网络 / 零编译器 / 毫秒级 ⇒ 挂 `bootstrap-tests` job（同 test_block_git /
test_ci_hook_coverage / test_criteria_mutations 的体例与位置）。**刻意不读修订**：
只读文档目录本身 ⇒ CI 浅检出 + 无 jj 也能跑（对比：`tools/baseline/parity_run.sh`
因需 jj + 完整历史而 CI 不可行，登记在 ci_hook_allowlist.txt）。

四层（逐层独立可诊断）：

  E **类别真源双向对账（静态）**：工具**源码**里的类别集（全部 `add('<NAME>'` 调用点）
    ↔ 本档 `COVERED ∪ LEDGER` 双向差集必须为空。防的是本仓一类固定失效形态
    ——**「覆盖为零」：判据不会红、只会悄悄腐烂**。工具新增一类而本档两表皆无 ⇒ 本档
    静默少覆盖一类，**读数完全一样**；故：加进 `COVERED` 打突变，或登记进 `LEDGER` 带理由。
    真源取**源码**不取 manifest 的 `# categories:`——后者只列本语料命中过的类，新增一类
    若在本语料零命中就不会出现，拿它当真源恰好漏掉要防的那种情况。
    反向腿 = **内存内注入一类 ⇒ 对账必失配**（零副作用；只写正向那句则「两边同时漏掉
    一类」恒绿）。
  A 正控：同一份语料抽两次 ⇒ compare 必 PASS（下限按本仓数法当场算：冻结读数 × 0.9）。
  B **反向（本档的核心）**：9 类受保护面**各打一个突变** ⇒ 逐类必须「真红」
    （rc=1 且首行「受保护面有差异」）。
  B2 散文自检：改一处**纯散文** ⇒ 该档切片必须**不变** ⇒ 门不误伤散文编辑
    （这正是工具的用途：散文自由、非散文钉死）。没有这一层，「门永不误伤」与
    「门根本没在工作」读数一样。
  C fail-closed：围栏不成对 ⇒ 必须**拒绝出数**（rc≠0），这是「不出数」不是「红」。
  D 下限闸：语料被削薄 ⇒ 必须被非空转闸拦下（防「空语料 0==0 PASS」重演）。

── 三条落地判定（缺一即**不算证据**；本档据此判定每类是否真的被覆盖）──────────────
  ① **替换真的落地**：`str.replace` + assert 串存在（挡「改成不存在的串」＝打空）。
  ② **突变真的进了受保护面**：该档 manifest 切片必变，且 diff 里**必须含该类**的条目。
     这条专治「文件字节变了、但抽取面没变」的假突变——典型是改到 `# categories:`
     之类的**头行**（头行被 load_manifest 忽略），此时对比会 PASS，看着像「判据漏检」，
     其实是**突变自己打空**。二者在读数上无法区分，只能靠这条判定分开。
  ③ **两侧同一路径串**跑 extract：否则 `set(a_per) != set(b_per)` 会让档清单不同，
     判据因**错因**变红——那是**假红**，不是突变证据。

── 两次实战翻车（比结论值钱，故留在档头）────────────────────────────────────
  · 翻车一（假红）：harness 第一版 A 侧取 `docs/developer/...`、B 侧取
    `/tmp/.../docs/developer/...` ⇒ 首行是「两侧档清单不同」而 rc=1。**rc=1 不等于证据**：
    本档一律判首行文案，不是 rc。
  · 翻车二（把已落地判成没落地）：落地检测最初用 `grep -cF <串>` 数出现次数，遇**前缀命中**
    即失效——实测 `@hasField` 是 `@hasFields` 的前缀，替换后旧串计数不减 ⇒ 判「没落地」。
    故落地检测一律走 **manifest 切片差集**，不走子串计数。
  · 翻车三（同一族的第三次，且栽在 C 层）：C 层最初用 `"```" in text` 选档，命中的是
    errors.md **表格单元格里的行内代码**（该档真围栏数为 0）⇒ 替换它没破坏任何围栏，
    抽取照常 rc=0，**看着像「fail-closed 失效」**，实为突变打空。**子串计数 ≠ 结构计数**：
    围栏一律用工具同款**行首**正则数；C 层的落地判据也因此加了「替换后围栏行数必须变奇」。
  （另一独立陷阱：突变手法若不干净——例如顺手改到别的档——「只有该档变」的伴随损伤检查
    会拦下；见 B 层 COLLATERAL 分支。）

**本档自身的纪律**：C 层的落地判据与 B 层同规格（判定①对每一层都适用）。C 层那次翻车
说明「我写了三条落地判定」不等于「我在每一层都用了它们」——**新增层必须显式过判定①**。

跑法：python3 tests/harness/test_doc_protected_surface.py
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile
from collections import Counter

BASE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TOOL = os.path.join(BASE, "tools", "doc_protected_surface.py")

# 语料 = 本批受审目录（文档风格审查第一批）。目录迁移时须同步改本常量——故下面
# 「目录不存在 / 无 .md」判 FAIL 而非 SKIP：**显式失败**，不静默消失。
TARGET = os.path.join("docs", "developer")

# 非空转下限（照本仓惯例「≥N 皆为下限，可增不可减」；实测基线 2026-09-24 = 2253 项 / 13 档
# ⇒ 取下界留余量，**不追平**，加档只会上漂）。低于此值 ⇒ FAIL（防正则改动/路径改动致空对空）。
MIN_ITEMS = 1000
MIN_FILES = 10
MIN_CATEGORIES = 9

# 覆盖率类别：B 层逐类打突变、逐类必须真红。少一类 ⇒ FAIL（防「某类其实抓不住」静默）。
COVERED = ("ANCHOR", "FENCE_LINE", "FENCE_OPEN", "INLINE", "LINKTARGET",
           "NUM", "TODOID", "TROW", "URL")

# 工具里存在、但**不由 B 层打突变**的类别——每条**必须带理由**。E 层拿本表做双向对账：
# 工具新增一类而两表皆无 ⇒ 必红（防「覆盖为零」：判据不会红、只会悄悄腐烂，**读数完全一样**）。
LEDGER = {
    "FENCE_CLOSE": "走 C 层——缺陷形态是「围栏失衡」而非「改值」，判据是拒绝出数（rc≠0）",
    "MARKER": "本批语料零命中（原文保留/加注 记录标记）；无可突变对象 ⇒ 挂空，见 B 层零命中闸",
}

NUM_RE = re.compile(r"\d+")
ANCHOR_TAIL_RE = re.compile(r":(\d+)(?:[-–](\d+))?$")
TODOID_TAIL_RE = re.compile(r"-\d+$")


# ────────────────────────────────────────────────────────────── 工具封装
def run_tool(args, cwd):
    return subprocess.run([sys.executable, TOOL] + args,
                          cwd=cwd, capture_output=True, text=True)


def extract(tree, out):
    """在 tree 内以 TARGET 相对路径抽取（判定③：两侧同一路径串）。"""
    return run_tool(["extract", "--worktree", "--out", out, TARGET], cwd=tree)


def load_items(manifest):
    items = []
    with open(manifest, encoding="utf-8") as fh:
        for line in fh:
            if line.startswith("#") or not line.strip():
                continue
            parts = line.rstrip("\n").split("\t", 2)
            if len(parts) != 3:
                raise AssertionError("manifest 条目格式错: %r" % line)
            items.append(tuple(parts))
    return items


def slice_of(items, path):
    return Counter(i for i in items if i[1] == path)


def overhead(manifest):
    """读 manifest 头部（条目数 / 档数 / 每档计数），供 A 层算下限 + 非空转检查。"""
    n = files = None
    per = {}
    with open(manifest, encoding="utf-8") as fh:
        for line in fh:
            if line.startswith("# items: "):
                n = int(line.split(":", 1)[1])
            elif line.startswith("# per-file "):
                _, _, path, cnt = line.rstrip("\n").split(" ")
                per[path] = int(cnt)
    files = len(per)
    return n, files, per


def floors(per, total):
    """本仓数法：冻结基线读数 × 0.9 向下取整（见 tools/doc_protected_surface.py docstring）。"""
    return int(total * 0.9), int(min(per.values()) * 0.9) if per else 0


# ────────────────────────────────────────────────────────────── 突变构造
def mutate_value(cat, v):
    """按类给 V' —— 既保持该类仍成立，又只引入字母/数字，不新造别的类。"""
    if cat == "NUM":
        d = "0" if v[-1] == "9" else str(int(v[-1]) + 1)
        return v[:-1] + d
    if cat == "ANCHOR":
        m = ANCHOR_TAIL_RE.search(v)
        if not m:
            return None
        n = int(m.group(2) if m.group(2) else m.group(1)) + 1
        return v[:m.start(2 if m.group(2) else 1)] + str(n)
    if cat == "TODOID":
        m = TODOID_TAIL_RE.search(v)
        return v[:m.start()] + "-" + str(int(m.group(0)[1:]) + 1)
    return v + "x"          # URL / LINKTARGET / INLINE / FENCE_LINE / FENCE_OPEN / TROW


def locate(text, cat, v):
    """带上下文定位 ⇒ 保证改的**就是**该类的那处，而不是同串的别处。
    返回 (needle, replacement) 或 None。"""
    v2 = mutate_value(cat, v)
    if v2 is None or v2 == v:
        return None
    if cat == "INLINE":
        needle = "`" + v + "`"
        return (needle, "`" + v2 + "`") if needle in text else None
    if cat == "FENCE_OPEN":
        needle = "```" + v
        return (needle, "```" + v2) if needle in text else None
    if cat in ("FENCE_LINE", "TROW"):
        # 整行类：既不能在行首（会变成围栏标记 ⇒ 围栏失衡），也不能本身是围栏标记
        if v.lstrip().startswith(("```", "~~~")) or not v.strip():
            return None
        needle = "\n" + v + "\n"
        return (needle, "\n" + v2 + "\n") if needle in text else None
    if cat == "LINKTARGET":
        needle = "](" + v + ")"
        return (needle, "](" + v2 + ")") if needle in text else None
    return (v, v2) if v in text else None


def pick(items, cat, text):
    """从该档的该类条目里挑一个能干净定位的（先挑行首/长串，降低同串碰撞概率）。"""
    cands = [i for i in items if i[0] == cat]
    cands.sort(key=lambda i: -len(i[2]))
    for _, _, v in cands:
        loc = locate(text, cat, v)
        if loc:
            return v, loc
    return None, None


def prose_probe(text):
    """找一处能干净改的纯散文：围栏外、非表格行、非行内代码内的中文串。
    返回 (needle, replacement) 或 None。"""
    infence = False
    for line in text.split("\n"):
        if re.match(r"^ {0,3}(`{3,}|~{3,})", line):
            infence = not infence
            continue
        if infence:
            continue
        s = line.strip()
        if not s or s.startswith(("|", "#", ">")):
            continue
        blanked = re.sub(r"`[^`]*`", lambda m: " " * len(m.group(0)), line)
        for m in re.finditer(r"[一-鿿]{5,}", blanked):
            w = m.group(0)
            repl = "迅速" if w.endswith("快速") else None
            if repl:
                return (w, repl)
            # 通用兜底：末字换成另一个汉字（该串不在任何受保护类里）
            alt = "末" if w[-1] != "末" else "尾"
            cand = w[:-1] + alt
            if cand != w:
                return (w, cand)
    return None


# ────────────────────────────────────────────────────────────── E 层：类别真源双向对账
def tool_categories(src_text):
    """工具**源码**里的类别集 = 全部 `add('<NAME>'` 调用点。
    从源码取（不是从 manifest 的 `# categories:` 取）：后者只列**本语料命中过**的类，
    新增一类若在本语料零命中就不会出现 ⇒ 拿它当真源会漏掉正是要防的那种情况。"""
    return set(re.findall(r"add\('([A-Z_]+)'", src_text))


def category_audit(src_text):
    """返回 (forward 问题, reverse 问题)。forward = 工具 ⊇ COVERED∪LEDGER；
    reverse = COVERED∪LEDGER 里有没有工具已经不存在的（防表腐烂）。双向都要空才 PASS。"""
    have = tool_categories(src_text)
    want = set(COVERED) | set(LEDGER)
    forward = sorted(have - want)      # 工具里多出来的 ⇒ 本档静默少覆盖一类（腐烂方向）
    reverse = sorted(want - have)      # 表里有、工具里没了 ⇒ 表腐烂
    return forward, reverse


# ────────────────────────────────────────────────────────────── 主流程
def main():
    if not os.path.isfile(TOOL):
        print("FAIL  判据脚本不在: %s" % TOOL)
        return 1
    src = os.path.join(BASE, TARGET)
    if not os.path.isdir(src):
        print("FAIL  语料目录不在: %s（目录迁移须同步改本档 TARGET 常量）" % src)
        return 1

    tmp = tempfile.mkdtemp(prefix="docprot_")
    fails, notes = [], []
    try:
        base = os.path.join(tmp, "base")
        os.makedirs(os.path.join(base, os.path.dirname(TARGET)), exist_ok=True)
        shutil.copytree(src, os.path.join(base, TARGET))
        base_manifest = os.path.join(tmp, "base.txt")
        p = extract(base, base_manifest)
        if p.returncode != 0:
            print("FAIL  正控抽取失败 rc=%d\n%s" % (p.returncode, p.stdout + p.stderr))
            return 1
        items = load_items(base_manifest)
        total, nfiles, per = overhead(base_manifest)

        # ── 非空转闸（本档自己的；先于一切判定）
        if total < MIN_ITEMS:
            fails.append("语料条目 %d < 下限 %d（抽空）" % (total, MIN_ITEMS))
        if nfiles < MIN_FILES:
            fails.append("语料档数 %d < 下限 %d（抽空）" % (nfiles, MIN_FILES))
        cats = Counter(i[0] for i in items)
        missing = [c for c in COVERED if cats.get(c, 0) < 1]
        if missing:
            fails.append("这些受保护类在语料里零命中 ⇒ B 层无法覆盖: %s" % missing)
        if len([c for c in COVERED if cats.get(c, 0) >= 1]) < MIN_CATEGORIES:
            fails.append("可覆盖类别 < %d" % MIN_CATEGORIES)

        fl, pff = floors(per, total)
        print("语料: %d 项 / %d 档；类别 %s；下限 floor=%d per-file-floor=%d"
              % (total, nfiles,
                 " ".join("%s=%d" % (c, cats[c]) for c in sorted(cats)), fl, pff))

        # ── E 类别真源双向对账（静态；防「覆盖为零」——新增一类而本档静默少覆盖）
        src_text = open(TOOL, encoding="utf-8").read()
        fwd, rev = category_audit(src_text)
        if fwd:
            fails.append("[E 类别真源] 工具里有本档既未打突变、也未登记的类 %s ⇒ 覆盖为零"
                         "（判据不会红、只会悄悄腐烂）。二选一：加进 COVERED 打突变，"
                         "或登记进 LEDGER 带理由" % fwd)
        if rev:
            fails.append("[E 类别真源] 本档表里有、工具源码里已不存在的类 %s ⇒ 表腐烂"
                         "（该类被删/改名，本档在为一个不存在的目标打突变）" % rev)
        if not fwd and not rev:
            # ── E 的反向自证：**往工具里多加一类但不改本档** ⇒ 对账必须立刻失配
            #    （内存内突变，零副作用；正控「对账通过」与「对账根本没在看」读数一样，
            #     故必须有这一腿才能证明 E 有牙）
            injected = src_text.replace("def extract(", "add('SYNTHETIC_PROBE', '')\n\n\ndef extract(", 1)
            if injected == src_text:
                fails.append("[E 自证] 注入点失效（工具源码结构已变）⇒ E 的反向腿未覆盖")
            else:
                f2, r2 = category_audit(injected)
                if "SYNTHETIC_PROBE" in f2:
                    print("[E 类别真源] OK  %d 类双向对账通过；反向自证：注入一类 ⇒ 必红"
                          % len(set(COVERED) | set(LEDGER)))
                else:
                    fails.append("[E 自证] 注入一类后对账**未**失配（fwd=%s）⇒ E 无牙" % f2)

        # ── A 正控
        p2 = extract(base, os.path.join(tmp, "base2.txt"))
        a = run_tool(["compare", "--floor", str(fl), "--per-file-floor", str(pff),
                      base_manifest, os.path.join(tmp, "base2.txt")], cwd=BASE)
        if a.returncode == 0 and a.stdout.startswith("PASS"):
            print("[A 正控] PASS  %s" % a.stdout.strip())
        else:
            fails.append("A 正控应 PASS 而 rc=%d: %s" % (a.returncode, a.stdout.strip()))

        # ── B 反向：逐类突变必真红 + B2 散文自检
        for cat in COVERED:
            mut = os.path.join(tmp, "mut_" + cat)
            if os.path.exists(mut):
                shutil.rmtree(mut)
            os.makedirs(os.path.join(mut, os.path.dirname(TARGET)), exist_ok=True)
            shutil.copytree(src, os.path.join(mut, TARGET))
            # 选档：优先条目多的档（更可能含可定位的该类条目）
            order = sorted(per, key=lambda f: -per[f])
            done = None
            for path in order:
                text = open(os.path.join(mut, path), encoding="utf-8").read()
                v, loc = pick([i for i in items if i[1] == path], cat, text)
                if not v:
                    continue
                needle, repl = loc
                new = text.replace(needle, repl, 1)
                if new == text:                     # 判定①
                    continue
                open(os.path.join(mut, path), "w", encoding="utf-8").write(new)
                done = (path, v)
                break
            if not done:
                fails.append("[B %s] 无法构造干净突变（判定① 未过）⇒ 该类未被覆盖" % cat)
                continue
            path, v = done

            mm = os.path.join(mut, "m.txt")
            pe = extract(mut, mm)
            if pe.returncode != 0:
                fails.append("[B %s] 突变后抽取失败（该突变破坏了文档结构）rc=%d: %s"
                             % (cat, pe.returncode, (pe.stdout + pe.stderr).strip()[:200]))
                continue
            mitems = load_items(mm)
            # 判定②：该档切片必变，且 diff 必含**该类**条目
            b_slice, m_slice = slice_of(items, path), slice_of(mitems, path)
            d_removed, d_added = b_slice - m_slice, m_slice - b_slice
            if not (d_removed or d_added):
                fails.append("[B %s] 突变未进受保护面（该档切片未变 ⇒ 判定② 未过，"
                             "改的是头行/散文之类，本次不算证据）" % cat)
                continue
            if not any(c == cat for c, _, _ in list(d_removed.elements())
                       + list(d_added.elements())):
                fails.append("[B %s] 切片变了但没有**该类**条目变化 ⇒ 判定② 未过" % cat)
                continue
            # 伴随损伤：其余档切片必须逐项相同（手法干净）
            other_b = Counter(i for i in items if i[1] != path)
            other_m = Counter(i for i in mitems if i[1] != path)
            if other_b != other_m:
                fails.append("[B %s] COLLATERAL：除目标档外还有别的档变了 ⇒ 手法不干净" % cat)
                continue

            c = run_tool(["compare", "--floor", str(fl), "--per-file-floor", str(pff),
                          base_manifest, mm], cwd=BASE)
            head = c.stdout.strip().split("\n")[0] if c.stdout.strip() else ""
            # 判定③：首行必须是「受保护面有差异」——rc=1 但错因是档清单/非空转闸 = 假红
            if c.returncode == 1 and head.startswith("FAIL  受保护面有差异"):
                print("[B %-11s] 真红 OK  %s（%s: %s→%s）"
                      % (cat, head, os.path.basename(path), v[:28], mutate_value(cat, v)[:28]))
            elif c.returncode == 1:
                fails.append("[B %s] rc=1 但**错因不是受保护面**（假红）: %s" % (cat, head))
            else:
                fails.append("[B %s] **假绿**：切片变了、compare 仍 rc=0 ⇒ 判据漏检" % cat)

        # ── B2 散文自检：改散文 ⇒ 切片必须不变，且 compare 仍 PASS
        mut = os.path.join(tmp, "mut_PROSE")
        os.makedirs(os.path.join(mut, os.path.dirname(TARGET)), exist_ok=True)
        shutil.copytree(src, os.path.join(mut, TARGET))
        pr = None
        for path in sorted(per, key=lambda f: -per[f]):
            text = open(os.path.join(mut, path), encoding="utf-8").read()
            loc = prose_probe(text)
            if loc and loc[0] in text:
                open(os.path.join(mut, path), "w", encoding="utf-8").write(
                    text.replace(loc[0], loc[1], 1))
                pr = (path, loc)
                break
        if not pr:
            fails.append("[B2 散文自检] 找不到可改的纯散文 ⇒ 该层未被覆盖")
        else:
            path, loc = pr
            mm = os.path.join(mut, "m.txt")
            pe = extract(mut, mm)
            if pe.returncode != 0:
                fails.append("[B2 散文自检] 抽取失败 rc=%d" % pe.returncode)
            else:
                mitems = load_items(mm)
                if slice_of(items, path) != slice_of(mitems, path):
                    fails.append("[B2 散文自检] 改散文却动了受保护面（%s: %s→%s）"
                                 % (path, loc[0][:20], loc[1][:20]))
                else:
                    print("[B2 散文自检  ] OK  散文改动不入受保护面（%s: %s→%s）"
                          % (os.path.basename(path), loc[0][:16], loc[1][:16]))

        # ── C fail-closed：围栏不成对 ⇒ 拒绝出数
        # 选档/落地一律用**工具同款的行首正则**数围栏，不用 `"```" in text`——后者在
        # errors.md 命中的是表格单元格里的行内代码（```continue` outside of loop`），
        # 该档真围栏数为 0 ⇒ 替换它什么也没破坏，抽取照常 rc=0，看着像「fail-closed 失效」。
        # 这是**突变自己打空**，不是判据缺陷（实战翻车三，见档头）。
        mut = os.path.join(tmp, "mut_FENCE")
        os.makedirs(os.path.join(mut, os.path.dirname(TARGET)), exist_ok=True)
        shutil.copytree(src, os.path.join(mut, TARGET))
        broke, detail = False, ""
        for path in sorted(per, key=lambda f: -per[f]):
            fp = os.path.join(mut, path)
            text = open(fp, encoding="utf-8").read()
            lines = text.split("\n")
            idx = [i for i, l in enumerate(lines) if re.match(r"^ {0,3}(`{3,}|~{3,})", l)]
            if len(idx) < 2 or len(idx) % 2 != 0:
                continue
            last = idx[-1]
            lines[last] = "``"                    # 打掉**最后一个**真围栏行
            new = "\n".join(lines)
            now = [i for i, l in enumerate(new.split("\n"))
                   if re.match(r"^ {0,3}(`{3,}|~{3,})", l)]
            if new == text or len(now) % 2 == 0:  # 判定①：真落地 + 真的失衡了
                continue
            open(fp, "w", encoding="utf-8").write(new)
            broke = True
            detail = "%s（围栏行 %d→%d）" % (os.path.basename(path), len(idx), len(now))
            break
        if not broke:
            fails.append("[C fail-closed] 找不到可安全打破的围栏 ⇒ 该层未被覆盖")
        else:
            pe = extract(mut, os.path.join(mut, "m.txt"))
            if pe.returncode != 0 and "fail-closed" in (pe.stdout + pe.stderr):
                print("[C fail-closed] OK  围栏不成对 ⇒ 拒绝出数（rc=%d；%s）"
                      % (pe.returncode, detail))
            else:
                fails.append("[C fail-closed] 围栏不成对却出了数（rc=%d；%s）⇒ fail-closed 失效"
                             % (pe.returncode, detail))

        # ── D 下限闸：语料削薄 ⇒ 必被非空转闸拦下
        thin = os.path.join(tmp, "thin.txt")
        with open(thin, "w", encoding="utf-8") as fh:
            fh.write("".join(open(base_manifest, encoding="utf-8").readlines()[:5]))
        d = run_tool(["compare", "--floor", str(fl), "--per-file-floor", str(pff),
                      base_manifest, thin], cwd=BASE)
        if d.returncode == 1 and "非空转闸" in d.stdout:
            print("[D 下限闸     ] OK  削薄语料被非空转闸拦下")
        else:
            fails.append("[D 下限闸] 削薄语料未被拦下（rc=%d）" % d.returncode)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    if fails:
        print("\nFAIL（%d 项）" % len(fails))
        for f in fails:
            print("  - " + f)
        return 1
    print("\nPASS  E 真源对账 + A/B(%d 类)/B2/C/D 全绿" % len(COVERED))
    return 0


if __name__ == "__main__":
    sys.exit(main())
